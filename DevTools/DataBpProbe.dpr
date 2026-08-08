program DataBpProbe;

{
  DataBpProbe -- do hardware debug registers (DR0..DR3/DR7) set through
  Wow64Get/SetThreadContext with WOW64_CONTEXT_DEBUG_REGISTERS survive on a
  WOW64 (32-bit) target, and do they survive across a running interval where
  the OS reschedules the thread? Compared against the native x64 path
  (GetThreadContext/SetThreadContext, CONTEXT_DEBUG_REGISTERS).

  Launches the given exe under DEBUG_ONLY_THIS_PROCESS. At CREATE_PROCESS,
  classifies WOW64 vs native via IsWow64Process2, reads the initial thread
  context, and arms DR0 for a 4-byte WRITE watch just below the current
  stack pointer (SP-4, 4-aligned) -- a slot the loader's own CALL/RET
  traffic is guaranteed to write almost immediately, and typically reuses
  repeatedly as nested calls unwind, so multiple hits over one run are
  expected if DR7 truly persists.

  Between arming and the first hit, the target runs the real loader (import
  resolution, TLS callbacks, and for WOW64 the extra wow64cpu/wow64win
  layers) -- substantial CPU time during which the OS scheduler is free to
  preempt and resume the thread. A trap that still arrives correctly after
  that, with DR6 correctly naming the slot, is evidence DR7 survived at
  least one real context switch. Repeated hits (MaxHits) each re-verify
  DR7 read back unchanged, which is the direct persistence check.

  On every SINGLE_STEP-class event: reads DR6 (native or Wow64), reports
  which B0..B3 bits are set, reads the watched dword via ReadProcessMemory
  to compare against the pre-arm snapshot (a HW write breakpoint traps
  AFTER the store completes, so the new value should already be visible),
  clears DR6, re-reads DR7 to confirm it was not reset by the emulation
  layer, and continues.

  Second question, added for increment 2 (DR6 disambiguation in the event
  pump): a watchpoint hit and a completed single step arrive as the SAME
  exception, so the pump must tell them apart from DR6 alone. B0..B3 name the
  slot that fired; BS (bit 14) says the trap flag caused this trap. Whether the
  WOW64 emulation layer reports BS at all is not documented anywhere we trust,
  and the answer decides whether the pump can be stateless. `-tfstep` sets the
  trap flag once after arming and reports the DR6 of the resulting step, so the
  two cases can be compared side by side on both bitnesses.

  Usage:
    DataBpProbe <exe> [-maxhits <n>] [-tfstep]

    -maxhits  how many DR6 hits to observe before terminating (default 3)
    -tfstep   also set the trap flag once after arming, and report the DR6 of
              the single step it produces (measures whether BS is reported)
    -tfwalk n keep the trap flag armed for up to n consecutive single steps and
              report the DR6 of each. This is the COMBINED case: sooner or later
              one stepped instruction also writes the watched cell, and the
              question is whether DR6 then reports BS *and* the slot bit, or
              only BS -- i.e. whether a watchpoint hit can hide inside a step.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils;

const
  STATUS_WX86_SINGLE_STEP = DWORD($4000001E);
  STATUS_WX86_BREAKPOINT  = DWORD($4000001F);
  MachineI386             = DWORD($014C);
  DR7_L0                  = DWORD($00000001);
  DR7_RW0_WRITE           = DWORD($00010000); // bits 16-17 = 01
  DR7_LEN0_4BYTE          = DWORD($000C0000); // bits 18-19 = 11
  DR6_BS                  = DWORD($00004000); // single step caused this #DB
  TRAP_FLAG               = DWORD($00000100);

function IsSingleStepException(Code: DWORD): Boolean;
begin
  Result := (Code = DWORD(EXCEPTION_SINGLE_STEP)) or (Code = STATUS_WX86_SINGLE_STEP);
end;

function Hex(Value: UInt64): string;
begin
  Result := '$' + IntToHex(Value, 8);
end;

procedure Say(const Line: string);
begin
  Writeln(Line);
  Flush(Output);
end;

type
  TIsWow64Process2 = function(hProcess: THandle;
    out ProcessMachine: USHORT; out NativeMachine: USHORT): BOOL; stdcall;

var
  GProcess:    THandle = 0;
  GIsWow64:    Boolean = False;
  GMaxHits:    Integer = 3;
  GTfStep:     Boolean = False;
  GTfWalk:     Integer = 0;
  // Walking with the trap flag armed produces one event per instruction, so the
  // per-event report is silenced while it runs and replaced by a summary.
  GVerbose:    Boolean = True;

function ClassifyWow64(hProcess: THandle): Boolean;
begin
  var Fn: TIsWow64Process2 := GetProcAddress(GetModuleHandle('kernel32.dll'), 'IsWow64Process2');
  if not Assigned(Fn) then begin
    Say('IsWow64Process2 not available -- assuming native x64');
    Exit(False);
  end;
  var ProcMachine: USHORT := 0;
  var NativeMachine: USHORT := 0;
  if not Fn(hProcess, ProcMachine, NativeMachine) then begin
    Say(Format('IsWow64Process2 FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  Result := ProcMachine = USHORT(MachineI386);
  Say(Format('IsWow64Process2: ProcessMachine=%s NativeMachine=%s -> %s',
    [Hex(ProcMachine), Hex(NativeMachine), IfThen(Result, 'WOW64/x86', 'native x64')]));
end;

function ReportDr6Bits(Dr6: DWORD): string;
begin
  Result := '';
  if (Dr6 and $1) <> 0 then Result := Result + 'B0 ';
  if (Dr6 and $2) <> 0 then Result := Result + 'B1 ';
  if (Dr6 and $4) <> 0 then Result := Result + 'B2 ';
  if (Dr6 and $8) <> 0 then Result := Result + 'B3 ';
  if (Dr6 and DR6_BS) <> 0 then Result := Result + 'BS ';
  if Result = '' then
    Result := '(none)';
end;

// Sets the trap flag on the target's main thread, whichever bitness it is.
// Returns False and says why on failure, so a missing measurement is never
// mistaken for a measured absence.
function SetTrapFlagOnMain(hThread: THandle): Boolean;
begin
  if GIsWow64 then begin
    var Ctx := Default(TWow64Context);
    Ctx.ContextFlags := WOW64_CONTEXT_CONTROL;
    if not Wow64GetThreadContext(hThread, Ctx) then begin
      Say(Format('  Wow64GetThreadContext (TF) FAILED err=%d', [GetLastError]));
      Exit(False);
    end;
    Ctx.EFlags := Ctx.EFlags or TRAP_FLAG;
    Result := Wow64SetThreadContext(hThread, Ctx);
  end else begin
    var Ctx := Default(TContext);
    Ctx.ContextFlags := CONTEXT_CONTROL;
    if not GetThreadContext(hThread, Ctx) then begin
      Say(Format('  GetThreadContext (TF) FAILED err=%d', [GetLastError]));
      Exit(False);
    end;
    Ctx.EFlags := Ctx.EFlags or TRAP_FLAG;
    Result := SetThreadContext(hThread, Ctx);
  end;
  if not Result then
    Say(Format('  SetThreadContext (TF) FAILED err=%d', [GetLastError]));
end;

{ ---------------------------------------------------------- native (x64) -- }

function ArmNative(hThread: THandle; WatchAddr: UInt64; out BeforeVal: DWORD): Boolean;
var
  Ctx: TContext;
  Read: NativeUInt;
begin
  ReadProcessMemory(GProcess, Pointer(WatchAddr), @BeforeVal, 4, Read);
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_DEBUG_REGISTERS;
  if not GetThreadContext(hThread, Ctx) then begin
    Say(Format('  GetThreadContext FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  Ctx.Dr0 := WatchAddr;
  Ctx.Dr7 := (Ctx.Dr7 and not DWORD64($F0000)) or DR7_L0 or DR7_RW0_WRITE or DR7_LEN0_4BYTE;
  Result := SetThreadContext(hThread, Ctx);
  if not Result then
    Say(Format('  SetThreadContext FAILED err=%d', [GetLastError]));
end;

// Returns the DR6 value, clears it, reports whether DR7 read back unchanged,
// and reports the after-write memory value.
function HandleHitNative(hThread: THandle; WatchAddr: UInt64; ExpectDr7: UInt64;
  BeforeVal: DWORD; out Dr6Out: DWORD): Boolean;
var
  Ctx: TContext;
  AfterVal: DWORD;
  Read: NativeUInt;
begin
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_DEBUG_REGISTERS;
  if not GetThreadContext(hThread, Ctx) then begin
    Say(Format('  GetThreadContext (hit) FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  Dr6Out := DWORD(Ctx.Dr6);
  AfterVal := 0;
  ReadProcessMemory(GProcess, Pointer(WatchAddr), @AfterVal, 4, Read);
  if GVerbose then
    Say(Format('  DR6=%s bits=[%s]  DR7=%s (expected %s, %s)  watched dword before=%s after=%s (%s)',
    [Hex(Dr6Out), ReportDr6Bits(Dr6Out), Hex(Ctx.Dr7), Hex(ExpectDr7),
     IfThen(UInt64(Ctx.Dr7) = ExpectDr7, 'UNCHANGED', 'CHANGED!'),
     Hex(BeforeVal), Hex(AfterVal), IfThen(BeforeVal <> AfterVal, 'write visible', 'write NOT visible')]));
  Ctx.Dr6 := 0;
  Result := SetThreadContext(hThread, Ctx);
  if not Result then
    Say(Format('  SetThreadContext (clear DR6) FAILED err=%d', [GetLastError]));
end;

{ ------------------------------------------------------------- WOW64/x86 -- }

function ArmWow64(hThread: THandle; WatchAddr: UInt64; out BeforeVal: DWORD): Boolean;
var
  Ctx: TWow64Context;
  Read: NativeUInt;
begin
  ReadProcessMemory(GProcess, Pointer(WatchAddr), @BeforeVal, 4, Read);
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_DEBUG_REGISTERS;
  if not Wow64GetThreadContext(hThread, Ctx) then begin
    Say(Format('  Wow64GetThreadContext FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  Ctx.Dr0 := DWORD(WatchAddr);
  Ctx.Dr7 := (Ctx.Dr7 and not DR7_LEN0_4BYTE and not $30000) or DR7_L0 or DR7_RW0_WRITE or DR7_LEN0_4BYTE;
  Result := Wow64SetThreadContext(hThread, Ctx);
  if not Result then
    Say(Format('  Wow64SetThreadContext FAILED err=%d', [GetLastError]));
end;

function HandleHitWow64(hThread: THandle; WatchAddr: UInt64; ExpectDr7: DWORD;
  BeforeVal: DWORD; out Dr6Out: DWORD): Boolean;
var
  Ctx: TWow64Context;
  AfterVal: DWORD;
  Read: NativeUInt;
begin
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_DEBUG_REGISTERS;
  if not Wow64GetThreadContext(hThread, Ctx) then begin
    Say(Format('  Wow64GetThreadContext (hit) FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  Dr6Out := Ctx.Dr6;
  AfterVal := 0;
  ReadProcessMemory(GProcess, Pointer(WatchAddr), @AfterVal, 4, Read);
  if GVerbose then
    Say(Format('  DR6=%s bits=[%s]  DR7=%s (expected %s, %s)  watched dword before=%s after=%s (%s)',
    [Hex(Dr6Out), ReportDr6Bits(Dr6Out), Hex(Ctx.Dr7), Hex(ExpectDr7),
     IfThen(Ctx.Dr7 = ExpectDr7, 'UNCHANGED', 'CHANGED!'),
     Hex(BeforeVal), Hex(AfterVal), IfThen(BeforeVal <> AfterVal, 'write visible', 'write NOT visible')]));
  Ctx.Dr6 := 0;
  Result := Wow64SetThreadContext(hThread, Ctx);
  if not Result then
    Say(Format('  Wow64SetThreadContext (clear DR6) FAILED err=%d', [GetLastError]));
end;

{ ------------------------------------------------------------------- main -- }

procedure Run(const ExePath: string);
var
  Ev:  TDebugEvent;
  Si:  TStartupInfo;
  Pi:  TProcessInformation;
  MainThread:  THandle;
  WatchAddr:   UInt64;
  BeforeVal:   DWORD;
  ExpectDr7Native: UInt64;
  ExpectDr7Wow:    DWORD;
  Armed:       Boolean;
  HitCount:    Integer;
  StepSeenNoBits: Integer;
  Done:        Boolean;
  SeenInitialBp: Boolean;
  TfStepPending: Boolean;
  WalkSteps:     Integer;

  // Arming at CREATE_PROCESS_DEBUG_EVENT does not work reliably: the initial
  // thread has not run any user code yet, and a watchpoint set that early
  // never fires (measured). Arm instead right after the loader's own initial
  // system breakpoint, once the thread is genuinely running.
  procedure ArmNow;
  begin
    if GIsWow64 then begin
      var Ctx := Default(TWow64Context);
      Ctx.ContextFlags := WOW64_CONTEXT_INTEGER or WOW64_CONTEXT_CONTROL;
      if not Wow64GetThreadContext(MainThread, Ctx) then begin
        Say(Format('  Wow64GetThreadContext (initial) FAILED err=%d', [GetLastError]));
        Exit;
      end;
      WatchAddr := (UInt64(Ctx.Esp) - 4) and not UInt64(3);
      Say(Format('  WOW64 ESP=%s -> watch addr=%s', [Hex(Ctx.Esp), Hex(WatchAddr)]));
      if not ArmWow64(MainThread, WatchAddr, BeforeVal) then
        Exit;
      Armed := True;
      var Verify := Default(TWow64Context);
      Verify.ContextFlags := WOW64_CONTEXT_DEBUG_REGISTERS;
      Wow64GetThreadContext(MainThread, Verify);
      ExpectDr7Wow := Verify.Dr7;
      Say(Format('  armed: DR0=%s DR7=%s (readback) before-val=%s',
        [Hex(Verify.Dr0), Hex(Verify.Dr7), Hex(BeforeVal)]));
    end else begin
      var Ctx := Default(TContext);
      Ctx.ContextFlags := CONTEXT_INTEGER or CONTEXT_CONTROL;
      if not GetThreadContext(MainThread, Ctx) then begin
        Say(Format('  GetThreadContext (initial) FAILED err=%d', [GetLastError]));
        Exit;
      end;
      WatchAddr := (UInt64(Ctx.Rsp) - 8) and not UInt64(3);
      Say(Format('  native RSP=%s -> watch addr=%s', [Hex(Ctx.Rsp), Hex(WatchAddr)]));
      if not ArmNative(MainThread, WatchAddr, BeforeVal) then
        Exit;
      Armed := True;
      var Verify := Default(TContext);
      Verify.ContextFlags := CONTEXT_DEBUG_REGISTERS;
      GetThreadContext(MainThread, Verify);
      ExpectDr7Native := UInt64(Verify.Dr7);
      Say(Format('  armed: DR0=%s DR7=%s (readback) before-val=%s',
        [Hex(Verify.Dr0), Hex(Verify.Dr7), Hex(BeforeVal)]));
    end;
  end;

begin
  Si := Default(TStartupInfo);
  Si.cb := SizeOf(Si);
  Pi := Default(TProcessInformation);
  if not CreateProcess(nil, PChar(ExePath), nil, nil, False,
      DEBUG_ONLY_THIS_PROCESS or CREATE_NEW_CONSOLE, nil,
      PChar(ExtractFilePath(ExePath)), Si, Pi) then begin
    Say(Format('CreateProcess FAILED err=%d', [GetLastError]));
    Exit;
  end;
  Say(Format('launched "%s" pid=%d', [ExePath, Pi.dwProcessId]));

  MainThread := 0;
  WatchAddr := 0;
  BeforeVal := 0;
  ExpectDr7Native := 0;
  ExpectDr7Wow := 0;
  Armed := False;
  HitCount := 0;
  StepSeenNoBits := 0;
  Done := False;
  SeenInitialBp := False;
  TfStepPending := False;
  WalkSteps     := 0;

  while (not Done) and WaitForDebugEvent(Ev, 20000) do begin
    var ContinueStatus: DWORD := DBG_CONTINUE;

    case Ev.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT:
        begin
          GProcess := Ev.CreateProcessInfo.hProcess;
          MainThread := Ev.CreateProcessInfo.hThread;
          GIsWow64 := ClassifyWow64(GProcess);
        end;

      EXIT_PROCESS_DEBUG_EVENT:
        begin
          Say(Format('EXIT_PROCESS reached; hits observed=%d, armed=%s', [HitCount, BoolToStr(Armed, True)]));
          Done := True;
        end;

      EXCEPTION_DEBUG_EVENT:
        begin
          var Code := Ev.Exception.ExceptionRecord.ExceptionCode;
          if GVerbose then
            Say(Format('  exception code=%s firstChance=%d tid=%d', [Hex(Code), Ev.Exception.dwFirstChance, Ev.dwThreadId]));

          // For a WOW64 target the native ntdll breakpoint ($80000003) fires
          // BEFORE the thread switches into 32-bit execution; arm on the
          // x86-level system breakpoint (STATUS_WX86_BREAKPOINT) instead, so
          // ESP/EIP are read once the WOW64 CPU emulation is genuinely live.
          var IsExpectedInitialBp := (not GIsWow64 and (Code = DWORD(EXCEPTION_BREAKPOINT)))
            or (GIsWow64 and (Code = STATUS_WX86_BREAKPOINT));
          if (not SeenInitialBp) and IsExpectedInitialBp then begin
            SeenInitialBp := True;
            Say('  initial system breakpoint (own bitness) reached -- arming watchpoint now');
            ArmNow;
            if Armed and (GTfStep or (GTfWalk > 0)) then begin
              TfStepPending := SetTrapFlagOnMain(MainThread);
              if TfStepPending then
                Say('  trap flag set -- the next single step should be a TF step, not a watchpoint hit');
            end;
          end;

          if Armed and IsSingleStepException(Code) then begin
            var Dr6: DWORD := 0;
            var Ok: Boolean;
            if GIsWow64 then
              Ok := HandleHitWow64(MainThread, WatchAddr, ExpectDr7Wow, BeforeVal, Dr6)
            else
              Ok := HandleHitNative(MainThread, WatchAddr, ExpectDr7Native, BeforeVal, Dr6);
            var WasTfStep := TfStepPending;
            // Trap-flag WALK: keep stepping and classify every step. The result
            // that matters is the first step whose own instruction writes the
            // watched cell -- does DR6 then carry BS *and* the slot bit?
            if Ok and (GTfWalk > 0) then begin
              Inc(WalkSteps);
              if (Dr6 and $F) <> 0 then begin
                GVerbose := True;
                Say(Format('=== COMBINED === after %d trap-flag steps: DR6=%s bits=[%s] -- ' +
                  'the stepped instruction wrote the watched cell and DR6 reports %s',
                  [WalkSteps, Hex(Dr6), ReportDr6Bits(Dr6),
                   IfThen(Dr6 and DR6_BS <> 0, 'BOTH BS and the slot bit',
                     'ONLY the slot bit (BS absent)')]));
                GTfWalk := 0;
              end else if WalkSteps >= GTfWalk then begin
                GVerbose := True;
                Say(Format('=== WALK ENDED === %d trap-flag steps, none of them wrote the ' +
                  'watched cell (BS-only every time) -- the combined case did not occur',
                  [WalkSteps]));
                GTfWalk := 0;
              end else begin
                GVerbose := False;
                TfStepPending := SetTrapFlagOnMain(MainThread);
                ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
                Continue;
              end;
            end;
            if Ok then begin
              if TfStepPending then begin
                TfStepPending := False;
                Say(Format('=== TF STEP === DR6=%s bits=[%s]  slot bits %s, BS %s',
                  [Hex(Dr6), ReportDr6Bits(Dr6),
                   IfThen(Dr6 and $F <> 0, 'SET (a step would look like a hit!)', 'clear (as required)'),
                   IfThen(Dr6 and DR6_BS <> 0, 'SET (stateless disambiguation possible)',
                                               'NOT reported (pump needs its own trap-flag record)')]));
              end;
              if Dr6 and $F <> 0 then begin
                Inc(HitCount);
                Say(Format('=== HIT %d/%d ===', [HitCount, GMaxHits]));
                // refresh baseline for the next comparison
                var Read: NativeUInt;
                ReadProcessMemory(GProcess, Pointer(WatchAddr), @BeforeVal, 4, Read);
                if HitCount >= GMaxHits then begin
                  Say('  max hits reached -- terminating target');
                  TerminateProcess(GProcess, 0);
                  Done := True;
                end;
              end else if not WasTfStep then begin
                Inc(StepSeenNoBits);
                Say('  single-step with NO DR6 bits set (unexpected -- not a watchpoint hit)');
              end;
            end;
          end else if (Code <> DWORD(EXCEPTION_BREAKPOINT)) and (Code <> STATUS_WX86_BREAKPOINT)
              and not IsSingleStepException(Code) then
            ContinueStatus := DWORD(DBG_EXCEPTION_NOT_HANDLED);
        end;
    end;

    if not Done then
      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, ContinueStatus)
    else
      ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, ContinueStatus);
  end;

  Say(Format('SUMMARY: bitness=%s armed=%s hits=%d spuriousSteps=%d',
    [IfThen(GIsWow64, 'WOW64/x86', 'native x64'), BoolToStr(Armed, True), HitCount, StepSeenNoBits]));

  if GProcess <> 0 then
    TerminateProcess(GProcess, 0);
  CloseHandle(Pi.hThread);
  CloseHandle(Pi.hProcess);
end;

function ParseArgs(out ExePath: string): Boolean;
begin
  ExePath := '';
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    if SameText(Arg, '-maxhits') and (I < ParamCount) then begin
      Inc(I);
      GMaxHits := StrToIntDef(ParamStr(I), 3);
    end else if SameText(Arg, '-tfwalk') and (I < ParamCount) then begin
      Inc(I);
      GTfWalk := StrToIntDef(ParamStr(I), 200);
    end else if SameText(Arg, '-tfstep') then
      GTfStep := True
    else if ExePath = '' then
      ExePath := Arg;
    Inc(I);
  end;
  Result := (ExePath <> '') and FileExists(ExePath);
  if not Result then
    Say('usage: DataBpProbe <exe> [-maxhits <n>] [-tfstep]');
end;

var
  ExePath: string;
begin
  try
    if not ParseArgs(ExePath) then
      Halt(1);
    Say(Format('probe host is %d-bit', [SizeOf(Pointer) * 8]));
    Run(ExePath);
  except
    on E: Exception do
      Say(E.ClassName + ': ' + E.Message);
  end;
end.
