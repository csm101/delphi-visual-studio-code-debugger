program Wow64RegWriteProbe;

{
  Wow64RegWriteProbe -- does a NATIVE SetThreadContext register write reach the
  guest-visible x86 register on a WOW64 (32-bit) target?

  TWinDebugger.SetRegisterByName (WinDebuggerBase.pas) is the ONLY named-register
  WRITE path in the engine and it always uses the NATIVE GetThreadContext /
  SetThreadContext pair (CONTEXT_FULL, TContext), never the WOW64 variant. Every
  other register accessor in the thread-context funnel has a WOW64 override in
  WinDebuggerX86.pas; this one method does not.

  This probe reproduces exactly what SetRegisterByName does -- read the native
  context, mutate one field (Rax), write it back with native SetThreadContext --
  and then asks Wow64GetThreadContext whether the guest-visible EAX changed.

  Usage:
    Wow64RegWriteProbe <exe> [-step] [-rva <hex>]

    -step      after the native write, single-step the thread once and take
               one more Wow64GetThreadContext reading, to see whether
               anything resyncs/overwrites across a resume.
    -rva <hex> plant an INT3 at ImageBase+RVA and run the experiment THERE
               instead of at the process's initial loader breakpoint. The
               loader breakpoint on a WOW64 target fires before the 32-bit
               environment is fully set up (native Rax reads back as literal
               zero there -- not a normal running-code value), so it is not
               representative of a real user breakpoint deep in application
               code. Use this to settle whether the defect is real at a
               genuine stop or an artifact of that early state.

  The SAME code path serves both architectures; only the machine classification
  differs. Run it against TestTarget.exe Win32 (the case under test) AND
  TestTarget.exe Win64 (control: native GetThreadContext/SetThreadContext is
  the CORRECT path there, so before/after must show the sentinel took effect --
  this validates the probe's own methodology before its 32-bit answer is
  believed), same idiom as Wow64StackProbe.dpr.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.Generics.Collections;

const
  MachineAmd64 = DWORD($8664);
  MachineI386  = DWORD($014C);
  // A 64-bit debugger attached to a WOW64 target does NOT receive a 32-bit INT3
  // as EXCEPTION_BREAKPOINT ($80000003): the WOW64 layer reports it under its
  // own codes (see Wow64StackProbe.dpr).
  STATUS_WX86_SINGLE_STEP = DWORD($4000001E);
  STATUS_WX86_BREAKPOINT  = DWORD($4000001F);
  SentinelValue: UInt64 = $1122334455667788;

type
  TIsWow64Process2 = function(hProcess: THandle;
    out ProcessMachine: USHORT; out NativeMachine: USHORT): BOOL; stdcall;

var
  GProcess:       THandle = 0;
  GIsWow64:       Boolean = False;
  GStepAfter:     Boolean = False;

{ ------------------------------------------------------------------ utils -- }

function IsBreakpointException(Code: DWORD): Boolean;
begin
  Result := (Code = DWORD(EXCEPTION_BREAKPOINT)) or (Code = STATUS_WX86_BREAKPOINT);
end;

function IsSingleStepException(Code: DWORD): Boolean;
begin
  Result := (Code = DWORD(EXCEPTION_SINGLE_STEP)) or (Code = STATUS_WX86_SINGLE_STEP);
end;

function Hex32(Value: UInt64): string;
begin
  Result := '$' + IntToHex(Value and $FFFFFFFF, 8);
end;

function Hex64(Value: UInt64): string;
begin
  Result := '$' + IntToHex(Value, 16);
end;

procedure Say(const Line: string);
begin
  Writeln(Line);
  Flush(Output);
end;

procedure ClassifyTarget;
begin
  var Fn: TIsWow64Process2 := GetProcAddress(GetModuleHandle('kernel32.dll'), 'IsWow64Process2');
  if not Assigned(Fn) then begin
    Say('IsWow64Process2 not available on this host -- assuming native x64');
    GIsWow64 := False;
    Exit;
  end;
  var ProcMachine: USHORT := 0;
  var NativeMachine: USHORT := 0;
  if not Fn(GProcess, ProcMachine, NativeMachine) then begin
    Say(Format('IsWow64Process2 FAILED err=%d', [GetLastError]));
    Exit;
  end;
  GIsWow64 := ProcMachine = USHORT(MachineI386);
  Say(Format('IsWow64Process2: ProcessMachine=%s NativeMachine=%s -> %s target',
    [Hex32(ProcMachine), Hex32(NativeMachine), IfThen(GIsWow64, 'WOW64/x86', 'native x64')]));
end;

{ ------------------------------------------------------------- experiment -- }

// Reproduces TWinDebugger.SetRegisterByName verbatim: NATIVE GetThreadContext,
// mutate ONLY Rax, NATIVE SetThreadContext. Returns whether SetThreadContext
// reported success.
function NativeWriteRax(ThreadHandle: THandle; Value: UInt64;
  out BeforeRax: UInt64; out AfterRax: UInt64): Boolean;
var
  Ctx: TContext;
begin
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(ThreadHandle, Ctx) then begin
    Say(Format('  NATIVE GetThreadContext FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  BeforeRax := Ctx.Rax;
  Ctx.Rax := Value;
  Result := SetThreadContext(ThreadHandle, Ctx);
  if not Result then begin
    Say(Format('  NATIVE SetThreadContext FAILED err=%d', [GetLastError]));
    AfterRax := 0;
    Exit;
  end;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if GetThreadContext(ThreadHandle, Ctx) then
    AfterRax := Ctx.Rax
  else begin
    Say(Format('  post-write NATIVE GetThreadContext FAILED err=%d', [GetLastError]));
    AfterRax := 0;
  end;
end;

function ReadWow64Eax(ThreadHandle: THandle; out Eax: DWORD): Boolean;
var
  Ctx: TWow64Context;
begin
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_ALL;
  Result := Wow64GetThreadContext(ThreadHandle, Ctx);
  if Result then
    Eax := Ctx.Eax
  else begin
    Say(Format('  Wow64GetThreadContext FAILED err=%d', [GetLastError]));
    Eax := 0;
  end;
end;

function ReadWow64Ebp(ThreadHandle: THandle; out Ebp: DWORD): Boolean;
var
  Ctx: TWow64Context;
begin
  Ctx := Default(TWow64Context);
  Ctx.ContextFlags := WOW64_CONTEXT_ALL;
  Result := Wow64GetThreadContext(ThreadHandle, Ctx);
  if Result then
    Ebp := Ctx.Ebp
  else begin
    Say(Format('  Wow64GetThreadContext FAILED err=%d', [GetLastError]));
    Ebp := 0;
  end;
end;

// Same shape as NativeWriteRax, but mutates Rbp -- the field the docs
// specifically called out as reading back garbage from a context the WOW64
// path never wrote. RIP/RSP/RBP are exactly the fields CompareAllFields
// would show DIVERGE at a real stop (the native view is the OS's own
// exception-dispatch trampoline while the thread is parked at a breakpoint),
// unlike the general-purpose data registers.
function NativeWriteRbp(ThreadHandle: THandle; Value: UInt64;
  out BeforeRbp: UInt64; out AfterRbp: UInt64): Boolean;
var
  Ctx: TContext;
begin
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(ThreadHandle, Ctx) then begin
    Say(Format('  NATIVE GetThreadContext FAILED err=%d', [GetLastError]));
    Exit(False);
  end;
  BeforeRbp := Ctx.Rbp;
  Ctx.Rbp := Value;
  Result := SetThreadContext(ThreadHandle, Ctx);
  if not Result then begin
    Say(Format('  NATIVE SetThreadContext FAILED err=%d', [GetLastError]));
    AfterRbp := 0;
    Exit;
  end;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if GetThreadContext(ThreadHandle, Ctx) then
    AfterRbp := Ctx.Rbp
  else begin
    Say(Format('  post-write NATIVE GetThreadContext FAILED err=%d', [GetLastError]));
    AfterRbp := 0;
  end;
end;

// Sets EFLAGS.TF via whichever context is appropriate for the target bitness,
// so -step can observe what happens to the guest register across a resume.
function ArmSingleStep(ThreadHandle: THandle): Boolean;
const
  TRAP_FLAG = $100;
var
  Ctx32: TWow64Context;
  Ctx64: TContext;
begin
  if GIsWow64 then begin
    Ctx32 := Default(TWow64Context);
    Ctx32.ContextFlags := WOW64_CONTEXT_ALL;
    if not Wow64GetThreadContext(ThreadHandle, Ctx32) then
      Exit(False);
    Ctx32.EFlags := Ctx32.EFlags or TRAP_FLAG;
    Result := Wow64SetThreadContext(ThreadHandle, Ctx32);
  end else begin
    Ctx64 := Default(TContext);
    Ctx64.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(ThreadHandle, Ctx64) then
      Exit(False);
    Ctx64.EFlags := Ctx64.EFlags or TRAP_FLAG;
    Result := SetThreadContext(ThreadHandle, Ctx64);
  end;
end;

// Dumps every role register both ways at the SAME stop, unmodified, to see
// which fields the native CONTEXT genuinely aliases with the guest WOW64
// context and which it does not -- Rip/Rsp/Rbp point at the OS's own
// exception-dispatch trampoline in the native view while the thread is
// stopped (a real, different address from the guest EIP/ESP/EBP), while the
// general-purpose data registers may be the same physical storage.
procedure CompareAllFields(ThreadHandle: THandle);
var
  Native: TContext;
  Wow:    TWow64Context;
begin
  Native := Default(TContext);
  Native.ContextFlags := CONTEXT_FULL;
  if not GetThreadContext(ThreadHandle, Native) then begin
    Say('  CompareAllFields: native GetThreadContext FAILED');
    Exit;
  end;
  Wow := Default(TWow64Context);
  Wow.ContextFlags := WOW64_CONTEXT_FULL;
  if not Wow64GetThreadContext(ThreadHandle, Wow) then begin
    Say('  CompareAllFields: Wow64GetThreadContext FAILED');
    Exit;
  end;
  Say('');
  Say('=== FIELD-BY-FIELD: native (low 32) vs WOW64, same stop, unmodified ===');
  var Pairs: TArray<TPair<string, TPair<UInt64, DWORD>>> := [
    TPair<string, TPair<UInt64, DWORD>>.Create('rip/eip', TPair<UInt64, DWORD>.Create(Native.Rip, Wow.Eip)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rsp/esp', TPair<UInt64, DWORD>.Create(Native.Rsp, Wow.Esp)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rbp/ebp', TPair<UInt64, DWORD>.Create(Native.Rbp, Wow.Ebp)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rax/eax', TPair<UInt64, DWORD>.Create(Native.Rax, Wow.Eax)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rbx/ebx', TPair<UInt64, DWORD>.Create(Native.Rbx, Wow.Ebx)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rcx/ecx', TPair<UInt64, DWORD>.Create(Native.Rcx, Wow.Ecx)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rdx/edx', TPair<UInt64, DWORD>.Create(Native.Rdx, Wow.Edx)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rsi/esi', TPair<UInt64, DWORD>.Create(Native.Rsi, Wow.Esi)),
    TPair<string, TPair<UInt64, DWORD>>.Create('rdi/edi', TPair<UInt64, DWORD>.Create(Native.Rdi, Wow.Edi))];
  for var P in Pairs do begin
    var NativeLow32 := DWORD(P.Value.Key and $FFFFFFFF);
    var Alias := NativeLow32 = P.Value.Value;
    Say(Format('  %-8s native=%s  wow64=%s  %s',
      [P.Key, Hex64(P.Value.Key), Hex32(P.Value.Value),
       IfThen(Alias, 'ALIASED (same value)', 'DIFFERENT -- native does not reflect the guest register')]));
  end;
end;

procedure RunExperiment(ThreadHandle: THandle);
var
  BeforeWow64Eax, AfterWow64Eax: DWORD;
  BeforeNativeRax, AfterNativeRax: UInt64;
  BeforeWow64Ebp, AfterWow64Ebp: DWORD;
  BeforeNativeRbp, AfterNativeRbp, RestoreDummy: UInt64;
  WriteOk: Boolean;
begin
  if GIsWow64 then
    CompareAllFields(ThreadHandle);

  Say('');
  Say('=== EXPERIMENT: native SetThreadContext write of Rax on this thread ===');

  if GIsWow64 then begin
    if not ReadWow64Eax(ThreadHandle, BeforeWow64Eax) then
      Exit;
    Say(Format('  before-WOW64  Eax (Wow64GetThreadContext) = %s', [Hex32(BeforeWow64Eax)]));
  end;

  WriteOk := NativeWriteRax(ThreadHandle, SentinelValue, BeforeNativeRax, AfterNativeRax);
  Say(Format('  before-native Rax (GetThreadContext)       = %s', [Hex64(BeforeNativeRax)]));
  Say(Format('  sentinel written                           = %s', [Hex64(SentinelValue)]));
  Say(Format('  SetThreadContext returned                  = %s', [BoolToStr(WriteOk, True)]));
  Say(Format('  after-native  Rax (GetThreadContext)       = %s', [Hex64(AfterNativeRax)]));

  if GIsWow64 then begin
    if not ReadWow64Eax(ThreadHandle, AfterWow64Eax) then
      Exit;
    Say(Format('  after-WOW64   Eax (Wow64GetThreadContext)  = %s', [Hex32(AfterWow64Eax)]));
    Say('');
    if AfterWow64Eax = DWORD(SentinelValue and $FFFFFFFF) then
      Say('  VERDICT: native write DID reach the guest-visible x86 EAX.')
    else if AfterWow64Eax = BeforeWow64Eax then
      Say('  VERDICT: native write did NOT reach the guest-visible x86 EAX -- '
        + 'Wow64GetThreadContext still reports the pre-write value. DEFECT CONFIRMED.')
    else
      Say(Format('  VERDICT: native write did NOT land on the sentinel''s low 32 bits '
        + '(guest EAX changed to %s, unrelated to sentinel). DEFECT CONFIRMED, different symptom.',
        [Hex32(AfterWow64Eax)]));
  end else begin
    Say('');
    if AfterNativeRax = SentinelValue then
      Say('  VERDICT (control, native target): native write took effect, as expected.')
    else
      Say('  VERDICT (control, native target): native write did NOT take effect -- '
        + 'the probe''s own methodology is broken; do not trust the WOW64 answer.');
  end;

  // The docs specifically called out Rbp reading back garbage from a context
  // the WOW64 path never wrote. RIP/RSP/RBP are the fields CompareAllFields
  // showed diverge at a real stop (native = the OS exception-dispatch
  // trampoline; WOW64 = the guest's real frame pointer), so test the SAME
  // native-write-then-WOW64-read shape as the Rax experiment, but on Rbp,
  // and restore the original value afterward (best effort) so the frame
  // pointer is not left corrupted.
  if GIsWow64 then begin
    Say('');
    Say('=== EXPERIMENT: native SetThreadContext write of Rbp (the field the docs flagged) ===');
    if not ReadWow64Ebp(ThreadHandle, BeforeWow64Ebp) then
      Exit;
    Say(Format('  before-WOW64  Ebp (Wow64GetThreadContext) = %s', [Hex32(BeforeWow64Ebp)]));

    WriteOk := NativeWriteRbp(ThreadHandle, SentinelValue, BeforeNativeRbp, AfterNativeRbp);
    Say(Format('  before-native Rbp (GetThreadContext)      = %s', [Hex64(BeforeNativeRbp)]));
    Say(Format('  sentinel written                          = %s', [Hex64(SentinelValue)]));
    Say(Format('  SetThreadContext returned                 = %s', [BoolToStr(WriteOk, True)]));
    Say(Format('  after-native  Rbp (GetThreadContext)      = %s', [Hex64(AfterNativeRbp)]));

    if not ReadWow64Ebp(ThreadHandle, AfterWow64Ebp) then
      Exit;
    Say(Format('  after-WOW64   Ebp (Wow64GetThreadContext) = %s', [Hex32(AfterWow64Ebp)]));
    Say('');
    if AfterWow64Ebp = DWORD(SentinelValue and $FFFFFFFF) then
      Say('  VERDICT: native write DID reach the guest-visible x86 EBP.')
    else if AfterWow64Ebp = BeforeWow64Ebp then
      Say('  VERDICT: native write did NOT reach the guest-visible x86 EBP -- '
        + 'Wow64GetThreadContext still reports the pre-write value. DEFECT CONFIRMED for EBP.')
    else
      Say(Format('  VERDICT: native write did NOT land on the sentinel''s low 32 bits '
        + '(guest EBP changed to %s, unrelated to sentinel). DEFECT CONFIRMED, different symptom.',
        [Hex32(AfterWow64Ebp)]));

    // Best-effort restore -- ignore failure, the process is terminated right after.
    NativeWriteRbp(ThreadHandle, BeforeNativeRbp, RestoreDummy, RestoreDummy);
  end;

  if GStepAfter then begin
    Say('');
    Say('  -step: arming single step to observe post-resume state...');
    if not ArmSingleStep(ThreadHandle) then begin
      Say('  ArmSingleStep FAILED');
      Exit;
    end;
    // The caller resumes the target and waits for the resulting exception;
    // the post-step reading happens there once the step is confirmed.
  end;
end;

procedure ReportPostStepState(ThreadHandle: THandle);
var
  Wow64Eax: DWORD;
  NativeRax: UInt64;
  Ctx: TContext;
begin
  Say('');
  Say('=== POST-STEP STATE (after resuming once with the sentinel already written) ===');
  if GIsWow64 then begin
    if ReadWow64Eax(ThreadHandle, Wow64Eax) then
      Say(Format('  post-step WOW64  Eax = %s', [Hex32(Wow64Eax)]));
  end;
  Ctx := Default(TContext);
  Ctx.ContextFlags := CONTEXT_FULL;
  if GetThreadContext(ThreadHandle, Ctx) then begin
    NativeRax := Ctx.Rax;
    Say(Format('  post-step native Rax = %s', [Hex64(NativeRax)]));
  end;
end;

{ ------------------------------------------------------ optional INT3 plant - }

function PlantInt3(Addr: UInt64; out SavedByte: Byte): Boolean;
var
  Written: NativeUInt;
  Int3:    Byte;
  Old:     DWORD;
begin
  Result := False;
  SavedByte := 0;
  if not ReadProcessMemory(GProcess, Pointer(Addr), @SavedByte, 1, Written) then
    Exit;
  Old := 0;
  VirtualProtectEx(GProcess, Pointer(Addr), 1, PAGE_EXECUTE_READWRITE, Old);
  Int3 := $CC;
  Result := WriteProcessMemory(GProcess, Pointer(Addr), @Int3, 1, Written);
  VirtualProtectEx(GProcess, Pointer(Addr), 1, Old, Old);
  FlushInstructionCache(GProcess, Pointer(Addr), 1);
end;

procedure RestoreByte(Addr: UInt64; Value: Byte);
var
  Written: NativeUInt;
  Old:     DWORD;
begin
  Old := 0;
  VirtualProtectEx(GProcess, Pointer(Addr), 1, PAGE_EXECUTE_READWRITE, Old);
  WriteProcessMemory(GProcess, Pointer(Addr), @Value, 1, Written);
  VirtualProtectEx(GProcess, Pointer(Addr), 1, Old, Old);
  FlushInstructionCache(GProcess, Pointer(Addr), 1);
end;

procedure RewindEip(ThreadHandle: THandle; Addr: UInt64);
var
  Ctx32: TWow64Context;
  Ctx64: TContext;
begin
  if GIsWow64 then begin
    Ctx32 := Default(TWow64Context);
    Ctx32.ContextFlags := WOW64_CONTEXT_CONTROL;
    if not Wow64GetThreadContext(ThreadHandle, Ctx32) then
      Exit;
    Ctx32.Eip := DWORD(Addr);
    Wow64SetThreadContext(ThreadHandle, Ctx32);
  end else begin
    Ctx64 := Default(TContext);
    Ctx64.ContextFlags := CONTEXT_CONTROL;
    if not GetThreadContext(ThreadHandle, Ctx64) then
      Exit;
    Ctx64.Rip := Addr;
    SetThreadContext(ThreadHandle, Ctx64);
  end;
end;

{ ------------------------------------------------------------------- main -- }

procedure Run(const ExePath: string; UserRva: UInt64);
var
  Ev:           TDebugEvent;
  Si:           TStartupInfo;
  Pi:           TProcessInformation;
  CmdLine:      string;
  MainThread:   THandle;
  StoppedOnce:  Boolean;
  StepArmed:    Boolean;
  ImageBase:    UInt64;
  UserBpAddr:   UInt64;
  UserBpSaved:  Byte;
  UserBpPlanted: Boolean;
begin
  Si := Default(TStartupInfo);
  Si.cb := SizeOf(Si);
  Pi := Default(TProcessInformation);
  CmdLine := ExePath;
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False,
      DEBUG_ONLY_THIS_PROCESS or CREATE_NEW_CONSOLE, nil,
      PChar(ExtractFilePath(ExePath)), Si, Pi) then begin
    Say(Format('CreateProcess FAILED err=%d', [GetLastError]));
    Exit;
  end;
  Say(Format('launched "%s" pid=%d', [ExePath, Pi.dwProcessId]));

  MainThread := 0;
  StoppedOnce := False;
  StepArmed := False;
  ImageBase := 0;
  UserBpAddr := 0;
  UserBpSaved := 0;
  UserBpPlanted := False;

  while WaitForDebugEvent(Ev, 15000) do begin
    var ContinueStatus: DWORD := DBG_CONTINUE;

    case Ev.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT:
        begin
          GProcess := Ev.CreateProcessInfo.hProcess;
          MainThread := Ev.CreateProcessInfo.hThread;
          ImageBase := UInt64(Ev.CreateProcessInfo.lpBaseOfImage);
          Say(Format('CREATE_PROCESS: tid=%d imagebase=%s', [Ev.dwThreadId, Hex64(ImageBase)]));
          ClassifyTarget;
          if (UserRva <> 0) and not UserBpPlanted then begin
            UserBpAddr := ImageBase + UserRva;
            if PlantInt3(UserBpAddr, UserBpSaved) then begin
              UserBpPlanted := True;
              Say(Format('  planted INT3 at %s (a real application-code address, not the loader break)',
                [Hex64(UserBpAddr)]));
            end else
              Say(Format('  PlantInt3 FAILED err=%d', [GetLastError]));
          end;
        end;

      EXIT_PROCESS_DEBUG_EVENT:
        begin
          Say('EXIT_PROCESS reached before the experiment finished');
          Break;
        end;

      EXCEPTION_DEBUG_EVENT:
        begin
          var Code := Ev.Exception.ExceptionRecord.ExceptionCode;
          var ExAddr := UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress);
          Say(Format('EXCEPTION code=%s addr=%s firstChance=%d tid=%d',
            [Hex32(Code), Hex64(ExAddr), Ev.Exception.dwFirstChance, Ev.dwThreadId]));

          if StepArmed and (IsSingleStepException(Code) or IsBreakpointException(Code)) then begin
            ReportPostStepState(MainThread);
            Say('');
            Say('done -- terminating target');
            TerminateProcess(GProcess, 0);
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Break;
          end;

          // With -rva, ignore every breakpoint except the user one (skips the
          // WOW64 loader breakpoint, which fires before the 32-bit environment
          // is fully live). Without -rva, the first breakpoint IS the stop.
          var IsTheStop := IsBreakpointException(Code) and
            ((UserRva = 0) or (UserBpPlanted and (ExAddr = UserBpAddr)));

          if (not StoppedOnce) and IsTheStop then begin
            StoppedOnce := True;
            if UserBpPlanted and (ExAddr = UserBpAddr) then begin
              RestoreByte(UserBpAddr, UserBpSaved);
              RewindEip(MainThread, UserBpAddr);
            end;
            RunExperiment(MainThread);
            if GStepAfter then begin
              StepArmed := True;
              // fall through: resume with the step armed and wait for the trap.
            end else begin
              Say('');
              Say('done -- terminating target');
              TerminateProcess(GProcess, 0);
              ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
              Break;
            end;
          end else if not IsBreakpointException(Code) then
            ContinueStatus := DWORD(DBG_EXCEPTION_NOT_HANDLED);
        end;
    end;

    ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, ContinueStatus);
  end;

  TerminateProcess(Pi.hProcess, 0);
  CloseHandle(Pi.hThread);
  CloseHandle(Pi.hProcess);
end;

function ParseArgs(out ExePath: string; out Rva: UInt64): Boolean;
begin
  ExePath := '';
  Rva := 0;
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    if SameText(Arg, '-step') then
      GStepAfter := True
    else if SameText(Arg, '-rva') and (I < ParamCount) then begin
      Inc(I);
      Rva := UInt64(StrToInt64Def('$' + ParamStr(I).Replace('$', '').Replace('0x', ''), 0));
    end
    else if ExePath = '' then
      ExePath := Arg;
    Inc(I);
  end;
  Result := (ExePath <> '') and FileExists(ExePath);
  if not Result then begin
    Say('usage: Wow64RegWriteProbe <exe> [-step] [-rva <hex>]');
    Say('  -step      after the native write, single-step once and report post-step state');
    Say('  -rva <hex> run the experiment at ImageBase+RVA instead of the loader breakpoint');
  end;
end;

var
  ExePath: string;
  Rva:     UInt64;
begin
  try
    if not ParseArgs(ExePath, Rva) then
      Halt(1);
    Say(Format('probe host is %d-bit', [SizeOf(Pointer) * 8]));
    Run(ExePath, Rva);
  except
    on E: Exception do
      Say(E.ClassName + ': ' + E.Message);
  end;
end.
