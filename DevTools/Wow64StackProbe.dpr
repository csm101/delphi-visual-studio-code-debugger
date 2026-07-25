program Wow64StackProbe;

{
  Wow64StackProbe -- can a 64-bit debugger unwind a 32-bit (WOW64) target with
  dbghelp StackWalk64?

  Launches the given executable under the Windows debug API
  (DEBUG_ONLY_THIS_PROCESS), stops it, classifies the target with
  IsWow64Process2 and walks the stopped thread's stack.

  The SAME code path serves both architectures; only the machine type and the
  context record differ:

    WOW64 target  -> IMAGE_FILE_MACHINE_I386  + TWow64Context (Wow64GetThreadContext)
    native target -> IMAGE_FILE_MACHINE_AMD64 + TContext      (GetThreadContext)

  So running it against a known-good 64-bit executable validates the harness
  itself before its 32-bit answer is believed.

  Each stop is walked three ways, to separate "StackWalk64 cannot do this" from
  "dbghelp was not told about the modules":

    A  SymInitialize(invade=True) only
    B  plus explicit SymLoadModuleExW for every module in the target
    C  no dbghelp callbacks at all (nil) -- pure frame-pointer chain fallback

  Usage:
    Wow64StackProbe <exe> [-rva <hex>] [-maxstops <n>]

    -rva      plant an INT3 at ImageBase+RVA and walk the stack there, which
              gives a deep application-code stack instead of the loader's.
    -maxstops how many breakpoint stops to walk before terminating when no -rva
              is given (default 2: a WOW64 target reports both a native and a
              32-bit initial break).
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils;

{ ---------------------------------------------------------------- dbghelp -- }

type
  // C ADDRESS64: Offset(8) + Segment(2) + pad(2) + Mode(4) = 16 bytes
  TDbgAddress64 = record
    Offset:  UInt64;
    Segment: Word;
    Mode:    DWORD;
  end;

  // C STACKFRAME64 (264 bytes on x64)
  TDbgStackFrame64 = record
    AddrPC:         TDbgAddress64;
    AddrReturn:     TDbgAddress64;
    AddrFrame:      TDbgAddress64;
    AddrStack:      TDbgAddress64;
    AddrBStore:     TDbgAddress64;
    FuncTableEntry: Pointer;
    Params:         array[0..3] of UInt64;
    Far_:           BOOL;
    Virtual_:       BOOL;
    Reserved:       array[0..2] of UInt64;
    KdHelp:         array[0..111] of Byte;
  end;

const
  AddrModeFlat               = DWORD(3);
  MachineAmd64               = DWORD($8664);
  MachineI386                = DWORD($014C);
  ListModulesAll             = DWORD($03);
  MaxFramesToPrint           = 40;
  MaxTrackedThreads          = 256;
  // A 64-bit debugger attached to a WOW64 target does NOT receive a 32-bit INT3
  // as EXCEPTION_BREAKPOINT ($80000003): the WOW64 layer reports it under its
  // own codes. A debug loop that only tests $80000003 never sees a user
  // breakpoint in 32-bit code and keeps re-dispatching it to the target.
  STATUS_WX86_SINGLE_STEP    = DWORD($4000001E);
  STATUS_WX86_BREAKPOINT     = DWORD($4000001F);

function SymInitialize(hProcess: THandle; UserSearchPath: PAnsiChar;
  fInvadeProcess: BOOL): BOOL; stdcall; external 'dbghelp.dll';
function SymCleanup(hProcess: THandle): BOOL; stdcall; external 'dbghelp.dll';
function StackWalk64(MachineType: DWORD; hProcess, hThread: THandle;
  var StackFrame: TDbgStackFrame64; ContextRecord: Pointer;
  ReadMemoryRoutine, FunctionTableAccessRoutine,
  GetModuleBaseRoutine, TranslateAddressRoutine: Pointer): BOOL;
  stdcall; external 'dbghelp.dll';
function SymFunctionTableAccess64(hProcess: THandle; AddrBase: UInt64): Pointer;
  stdcall; external 'dbghelp.dll';
function SymGetModuleBase64(hProcess: THandle; qwAddr: UInt64): UInt64;
  stdcall; external 'dbghelp.dll';
function SymLoadModuleExW(hProcess, hFile: THandle;
  ImageName, ModuleName: PWideChar; BaseOfDll: UInt64; DllSize: DWORD;
  Data: Pointer; Flags: DWORD): UInt64; stdcall; external 'dbghelp.dll';

function EnumProcessModulesEx(hProcess: THandle; lphModule: PHandle;
  cb: DWORD; var lpcbNeeded: DWORD; dwFilterFlag: DWORD): BOOL; stdcall;
  external 'psapi.dll' name 'EnumProcessModulesEx';
function GetModuleFileNameExW(hProcess: THandle; hModule: HMODULE;
  lpFilename: PWideChar; nSize: DWORD): DWORD; stdcall;
  external 'psapi.dll' name 'GetModuleFileNameExW';

type
  TIsWow64Process2 = function(hProcess: THandle;
    out ProcessMachine: USHORT; out NativeMachine: USHORT): BOOL; stdcall;

  TModuleInfo = record
    Base: UInt64;
    Size: UInt64;
    Name: string;
  end;

  TThreadSlot = record
    TID:    DWORD;
    Handle: THandle;
  end;

  TWalkMode = (wmInvadeOnly, wmExplicitModules, wmNoCallbacks);

var
  GProcess:       THandle = 0;
  GModules:       TArray<TModuleInfo>;
  GTargetMachine: DWORD = 0;
  GIsWow64:       Boolean = False;
  // -nopatch: walk with the INT3 still planted and EIP left one byte past it,
  // which is the state the shipping adapter is actually in at a stop. If
  // StackWalk64's just-entered-frame handling inspects the prolog byte rather
  // than blindly taking [ESP], the $CC makes it read a different frame 0.
  GNoPatch:       Boolean = False;
  // -step: after the user breakpoint, set EFLAGS.TF and continue, to observe
  // which exception code a single step in 32-bit code actually reports.
  GStepAfterBp:   Boolean = False;

{ ------------------------------------------------------------------ utils -- }

function IsBreakpointException(Code: DWORD): Boolean;
begin
  Result := (Code = DWORD(EXCEPTION_BREAKPOINT)) or (Code = STATUS_WX86_BREAKPOINT);
end;

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

procedure RefreshModuleList;
var
  Handles: array[0..511] of THandle;
  Needed:  DWORD;
  Mbi:     TMemoryBasicInformation;
begin
  SetLength(GModules, 0);
  Needed := 0;
  if not EnumProcessModulesEx(GProcess, @Handles[0], SizeOf(Handles), Needed, ListModulesAll) then begin
    Say(Format('  EnumProcessModulesEx FAILED err=%d', [GetLastError]));
    Exit;
  end;
  var Count := Integer(Needed div SizeOf(THandle));
  if Count > Length(Handles) then
    Count := Length(Handles);
  for var I := 0 to Count - 1 do begin
    var NameBuf: array[0..MAX_PATH] of WideChar;
    NameBuf[0] := #0;
    GetModuleFileNameExW(GProcess, Handles[I], @NameBuf[0], Length(NameBuf));
    var Mi: TModuleInfo;
    Mi.Base := UInt64(Handles[I]);
    Mi.Name := string(NameBuf);
    Mi.Size := 0;
    // Sum the contiguous regions that share this image's allocation base.
    var Probe := Mi.Base;
    while VirtualQueryEx(GProcess, Pointer(Probe), Mbi, SizeOf(Mbi)) = SizeOf(Mbi) do begin
      if UInt64(Mbi.AllocationBase) <> Mi.Base then
        Break;
      Inc(Mi.Size, Mbi.RegionSize);
      Probe := UInt64(Mbi.BaseAddress) + Mbi.RegionSize;
    end;
    GModules := GModules + [Mi];
  end;
end;

function ModuleNameForAddress(Addr: UInt64): string;
begin
  for var Mi in GModules do
    if (Addr >= Mi.Base) and (Addr < Mi.Base + Mi.Size) then
      Exit(Format('%s+%s', [ExtractFileName(Mi.Name), Hex(Addr - Mi.Base)]));
  Result := '<unknown module>';
end;

procedure RegisterModulesWithDbgHelp;
begin
  var Registered := 0;
  for var Mi in GModules do begin
    SetLastError(0);
    var Loaded := SymLoadModuleExW(GProcess, 0, PWideChar(Mi.Name), nil, Mi.Base, DWORD(Mi.Size), nil, 0);
    if (Loaded <> 0) or (GetLastError = ERROR_SUCCESS) then
      Inc(Registered);
  end;
  Say(Format('  explicit SymLoadModuleExW: %d/%d modules accepted', [Registered, Length(GModules)]));
end;

{ ------------------------------------------------------------------- walk -- }

// Runs one StackWalk64 pass and prints every frame. SeedCtx is a private copy:
// StackWalk64 mutates the context record as it unwinds.
function WalkStack(ThreadHandle: THandle; SeedCtx: Pointer; PC, Frame, Stack: UInt64;
  Mode: TWalkMode; const Caption: string): Integer;
var
  SF: TDbgStackFrame64;
begin
  var FnTable: Pointer := @SymFunctionTableAccess64;
  var ModBase: Pointer := @SymGetModuleBase64;
  if Mode = wmNoCallbacks then begin
    FnTable := nil;
    ModBase := nil;
  end;

  SF := Default(TDbgStackFrame64);
  SF.AddrPC.Offset    := PC;
  SF.AddrPC.Mode      := AddrModeFlat;
  SF.AddrFrame.Offset := Frame;
  SF.AddrFrame.Mode   := AddrModeFlat;
  SF.AddrStack.Offset := Stack;
  SF.AddrStack.Mode   := AddrModeFlat;

  Result := 0;
  while StackWalk64(GTargetMachine, GProcess, ThreadHandle, SF, SeedCtx,
      nil, FnTable, ModBase, nil) do begin
    if SF.AddrPC.Offset = 0 then
      Break;
    Inc(Result);
    Say(Format('    #%-2d PC=%s  Frame=%s  Stack=%s  Ret=%s  FTE=%s  %s',
      [Result - 1, Hex(SF.AddrPC.Offset), Hex(SF.AddrFrame.Offset),
       Hex(SF.AddrStack.Offset), Hex(SF.AddrReturn.Offset),
       Hex(UInt64(SF.FuncTableEntry)), ModuleNameForAddress(SF.AddrPC.Offset)]));
    if Result >= MaxFramesToPrint then begin
      Say('    ... truncated');
      Break;
    end;
  end;
  if Result = 0 then
    Say(Format('    (no frames; StackWalk64 err=%d)', [GetLastError]));
  Say(Format('  [%s] => %d frames', [Caption, Result]));
end;

// Walks the stopped thread three ways: dbghelp-invade only, dbghelp with every
// module explicitly registered, and with no dbghelp callbacks at all.
procedure WalkStoppedThread(ThreadHandle: THandle; const StopLabel: string);
var
  NativeCtx: TContext;
  Wow64Ctx:  TWow64Context;
  Copy32:    TWow64Context;
  Copy64:    TContext;
  PC, Frame, Stack: UInt64;

  procedure RunOneWalk(Mode: TWalkMode; const Suffix: string);
  begin
    if GIsWow64 then begin
      Copy32 := Wow64Ctx;
      WalkStack(ThreadHandle, @Copy32, PC, Frame, Stack, Mode, StopLabel + Suffix);
    end else begin
      Copy64 := NativeCtx;
      WalkStack(ThreadHandle, @Copy64, PC, Frame, Stack, Mode, StopLabel + Suffix);
    end;
  end;

begin
  NativeCtx := Default(TContext);
  Wow64Ctx := Default(TWow64Context);

  if GIsWow64 then begin
    Wow64Ctx.ContextFlags := WOW64_CONTEXT_ALL;
    if not Wow64GetThreadContext(ThreadHandle, Wow64Ctx) then begin
      Say(Format('  Wow64GetThreadContext FAILED err=%d', [GetLastError]));
      Exit;
    end;
    PC := Wow64Ctx.Eip;
    Frame := Wow64Ctx.Ebp;
    Stack := Wow64Ctx.Esp;
    Say(Format('  WOW64 ctx: EIP=%s EBP=%s ESP=%s  (%s)',
      [Hex(PC), Hex(Frame), Hex(Stack), ModuleNameForAddress(PC)]));
  end else begin
    NativeCtx.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(ThreadHandle, NativeCtx) then begin
      Say(Format('  GetThreadContext FAILED err=%d', [GetLastError]));
      Exit;
    end;
    PC := NativeCtx.Rip;
    Frame := NativeCtx.Rbp;
    Stack := NativeCtx.Rsp;
    Say(Format('  native ctx: RIP=%s RBP=%s RSP=%s  (%s)',
      [Hex(PC), Hex(Frame), Hex(Stack), ModuleNameForAddress(PC)]));
  end;

  RunOneWalk(wmInvadeOnly, '/A invade-only');
  RegisterModulesWithDbgHelp;
  RunOneWalk(wmExplicitModules, '/B explicit-modules');
  RunOneWalk(wmNoCallbacks, '/C no-callbacks');
end;

{ ------------------------------------------------------------ target setup -- }

procedure ClassifyTarget;
begin
  var Fn: TIsWow64Process2 := GetProcAddress(GetModuleHandle('kernel32.dll'), 'IsWow64Process2');
  if not Assigned(Fn) then begin
    Say('IsWow64Process2 not available on this host -- assuming native x64');
    GIsWow64 := False;
    GTargetMachine := MachineAmd64;
    Exit;
  end;
  var ProcMachine: USHORT := 0;
  var NativeMachine: USHORT := 0;
  if not Fn(GProcess, ProcMachine, NativeMachine) then begin
    Say(Format('IsWow64Process2 FAILED err=%d', [GetLastError]));
    Exit;
  end;
  GIsWow64 := ProcMachine = USHORT(MachineI386);
  if GIsWow64 then
    GTargetMachine := MachineI386
  else
    GTargetMachine := MachineAmd64;
  Say(Format('IsWow64Process2: ProcessMachine=%s NativeMachine=%s -> %s target; StackWalk64 machine=%s',
    [Hex(ProcMachine), Hex(NativeMachine), IfThen(GIsWow64, 'WOW64/x86', 'native x64'), Hex(GTargetMachine)]));
end;

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

// Rewinds the instruction pointer over the INT3 just reported, so the walk sees
// the function's real state rather than one byte past the trap.
procedure RewindToBreakpoint(ThreadHandle: THandle; Addr: UInt64);
var
  Ctx32: TWow64Context;
  Ctx64: TContext;
begin
  if GIsWow64 then begin
    Ctx32 := Default(TWow64Context);
    Ctx32.ContextFlags := WOW64_CONTEXT_ALL;
    if not Wow64GetThreadContext(ThreadHandle, Ctx32) then
      Exit;
    Ctx32.Eip := DWORD(Addr);
    Wow64SetThreadContext(ThreadHandle, Ctx32);
  end else begin
    Ctx64 := Default(TContext);
    Ctx64.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(ThreadHandle, Ctx64) then
      Exit;
    Ctx64.Rip := Addr;
    SetThreadContext(ThreadHandle, Ctx64);
  end;
end;

// Sets EFLAGS.TF so the next instruction raises a single-step trap. Returns the
// EFLAGS value actually written back, so the caller can prove the bit stuck.
function SetTrapFlag(ThreadHandle: THandle; out NewFlags: DWORD): Boolean;
const
  TRAP_FLAG = $100;
var
  Ctx32: TWow64Context;
  Ctx64: TContext;
begin
  NewFlags := 0;
  if GIsWow64 then begin
    Ctx32 := Default(TWow64Context);
    Ctx32.ContextFlags := WOW64_CONTEXT_ALL;
    if not Wow64GetThreadContext(ThreadHandle, Ctx32) then
      Exit(False);
    Ctx32.EFlags := Ctx32.EFlags or TRAP_FLAG;
    NewFlags := Ctx32.EFlags;
    Result := Wow64SetThreadContext(ThreadHandle, Ctx32);
  end else begin
    Ctx64 := Default(TContext);
    Ctx64.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(ThreadHandle, Ctx64) then
      Exit(False);
    Ctx64.EFlags := Ctx64.EFlags or TRAP_FLAG;
    NewFlags := Ctx64.EFlags;
    Result := SetThreadContext(ThreadHandle, Ctx64);
  end;
end;

{ ------------------------------------------------------------------- main -- }

procedure Run(const ExePath: string; UserRva: UInt64; MaxStops: Integer);
var
  Ev:           TDebugEvent;
  Si:           TStartupInfo;
  Pi:           TProcessInformation;
  CmdLine:      string;
  Threads:      array[0..MaxTrackedThreads - 1] of TThreadSlot;
  ThreadCount:  Integer;
  ImageBase:    UInt64;
  UserBpAddr:   UInt64;
  UserBpSaved:  Byte;
  UserBpPlanted: Boolean;
  UserBpHit:    Boolean;
  SymDone:      Boolean;
  StopCount:    Integer;
  ExceptionCount: Integer;
  StepArmed:    Boolean;

  procedure TrackThread(TID: DWORD; H: THandle);
  begin
    if ThreadCount >= MaxTrackedThreads then
      Exit;
    Threads[ThreadCount].TID := TID;
    Threads[ThreadCount].Handle := H;
    Inc(ThreadCount);
  end;

  function HandleOfThread(TID: DWORD): THandle;
  begin
    for var I := 0 to ThreadCount - 1 do
      if Threads[I].TID = TID then
        Exit(Threads[I].Handle);
    Result := 0;
  end;

  procedure PlantUserBreakpointOnce;
  begin
    if (UserRva = 0) or UserBpPlanted then
      Exit;
    UserBpAddr := ImageBase + UserRva;
    if PlantInt3(UserBpAddr, UserBpSaved) then begin
      UserBpPlanted := True;
      Say(Format('  planted INT3 at %s (imagebase %s + rva %s); original byte %s',
        [Hex(UserBpAddr), Hex(ImageBase), Hex(UserRva), Hex(UserBpSaved)]));
    end else
      Say(Format('  PlantInt3 FAILED err=%d', [GetLastError]));
  end;

  // -step deliverable: name the exception code a single step in the target's
  // own bitness actually reports, so the debug loop can be written against a
  // measured constant instead of an assumed one.
  procedure ReportStepOutcome(Code: DWORD; Addr: UInt64);
  begin
    Say('');
    Say(Format('=== SINGLE-STEP RESULT  code=%s  addr=%s ===', [Hex(Code), Hex(Addr)]));
    if Code = STATUS_WX86_SINGLE_STEP then
      Say('  STATUS_WX86_SINGLE_STEP ($4000001E) -- the WOW64 layer reports the step '
        + 'under its own code, exactly as it does for breakpoints. The debug loop '
        + 'must accept it alongside EXCEPTION_SINGLE_STEP.')
    else if Code = DWORD(EXCEPTION_SINGLE_STEP) then
      Say('  EXCEPTION_SINGLE_STEP ($80000004) -- the native code, NOT the WX86 one. '
        + 'Stepping needs no new constant; only breakpoints do.')
    else if IsBreakpointException(Code) then
      Say('  a BREAKPOINT code, not a step: the trap flag did not take effect and the '
        + 'target ran on to another INT3. Inconclusive -- investigate before trusting.')
    else
      Say('  UNEXPECTED code: neither a single-step nor a breakpoint. The step did not '
        + 'do what was intended; treat the stepping design as still unmeasured.');
  end;

  // Returns True when the walk work is finished and the target may be killed.
  function HandleBreakpointStop: Boolean;
  begin
    var TH := HandleOfThread(Ev.dwThreadId);
    var Addr := UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress);
    RefreshModuleList;

    if not SymDone then begin
      if SymInitialize(GProcess, nil, True) then
        Say('SymInitialize(nil search path, invade=True) ok')
      else
        Say(Format('SymInitialize FAILED err=%d', [GetLastError]));
      SymDone := True;
    end;

    var IsUserBp := UserBpPlanted and (Addr = UserBpAddr);
    if IsUserBp then begin
      if GNoPatch then
        Say('  -nopatch: leaving the INT3 planted and EIP one byte past it')
      else begin
        RestoreByte(UserBpAddr, UserBpSaved);
        RewindToBreakpoint(TH, UserBpAddr);
      end;
      UserBpHit := True;
    end;

    Inc(StopCount);
    Say('');
    Say(Format('=== STOP %d  tid=%d  addr=%s  %s ===',
      [StopCount, Ev.dwThreadId, Hex(Addr),
       IfThen(IsUserBp, 'USER BP (-rva)', 'loader/initial breakpoint')]));
    Say(Format('  modules mapped in target: %d', [Length(GModules)]));
    WalkStoppedThread(TH, Format('stop%d', [StopCount]));

    PlantUserBreakpointOnce;

    // -step: arm a single step instead of finishing here, so the next exception
    // reveals which code a 32-bit single step actually reports.
    if IsUserBp and GStepAfterBp and not StepArmed then begin
      var Flags: DWORD := 0;
      if SetTrapFlag(TH, Flags) then begin
        StepArmed := True;
        Say(Format('  -step: trap flag set (EFLAGS now %s); continuing one instruction',
          [Hex(Flags)]));
        Exit(False);
      end;
      Say(Format('  -step: SetTrapFlag FAILED err=%d', [GetLastError]));
    end;

    Result := UserBpHit or ((UserRva = 0) and (StopCount >= MaxStops));
  end;

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

  ThreadCount := 0;
  ImageBase := 0;
  UserBpAddr := 0;
  UserBpSaved := 0;
  UserBpPlanted := False;
  UserBpHit := False;
  SymDone := False;
  StopCount := 0;
  ExceptionCount := 0;
  StepArmed := False;

  while WaitForDebugEvent(Ev, 15000) do begin
    var ContinueStatus: DWORD := DBG_CONTINUE;

    case Ev.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT:
        begin
          GProcess := Ev.CreateProcessInfo.hProcess;
          ImageBase := UInt64(Ev.CreateProcessInfo.lpBaseOfImage);
          TrackThread(Ev.dwThreadId, Ev.CreateProcessInfo.hThread);
          Say(Format('CREATE_PROCESS: imagebase=%s tid=%d', [Hex(ImageBase), Ev.dwThreadId]));
          ClassifyTarget;
        end;

      CREATE_THREAD_DEBUG_EVENT:
        TrackThread(Ev.dwThreadId, Ev.CreateThread.hThread);

      EXIT_PROCESS_DEBUG_EVENT:
        begin
          Say('EXIT_PROCESS reached before the walk finished');
          Break;
        end;

      EXCEPTION_DEBUG_EVENT:
        begin
          Inc(ExceptionCount);
          var Code := Ev.Exception.ExceptionRecord.ExceptionCode;
          var ExAddr := UInt64(Ev.Exception.ExceptionRecord.ExceptionAddress);
          if ExceptionCount <= 20 then
            Say(Format('EXCEPTION code=%s addr=%s firstChance=%d tid=%d',
              [Hex(Code), Hex(ExAddr), Ev.Exception.dwFirstChance, Ev.dwThreadId]));

          // Whatever arrives first after the trap flag was set IS the answer,
          // recognised code or not -- that is the whole point of -step.
          if StepArmed then begin
            ReportStepOutcome(Code, ExAddr);
            Say('');
            Say('done -- terminating target');
            TerminateProcess(GProcess, 0);
            ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
            Break;
          end;

          if IsBreakpointException(Code) then begin
            if HandleBreakpointStop then begin
              Say('');
              Say('done -- terminating target');
              TerminateProcess(GProcess, 0);
              ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, DBG_CONTINUE);
              Break;
            end;
          end else
            ContinueStatus := DWORD(DBG_EXCEPTION_NOT_HANDLED);
        end;
    end;

    ContinueDebugEvent(Ev.dwProcessId, Ev.dwThreadId, ContinueStatus);
  end;

  if GProcess <> 0 then
    SymCleanup(GProcess);
  TerminateProcess(Pi.hProcess, 0);
  CloseHandle(Pi.hThread);
  CloseHandle(Pi.hProcess);
end;

function ParseArgs(out ExePath: string; out Rva: UInt64; out MaxStops: Integer): Boolean;
begin
  ExePath := '';
  Rva := 0;
  MaxStops := 2;
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    if SameText(Arg, '-rva') and (I < ParamCount) then begin
      Inc(I);
      Rva := UInt64(StrToInt64Def('$' + ParamStr(I).Replace('$', '').Replace('0x', ''), 0));
    end else if SameText(Arg, '-maxstops') and (I < ParamCount) then begin
      Inc(I);
      MaxStops := StrToIntDef(ParamStr(I), 2);
    end else if SameText(Arg, '-nopatch') then
      GNoPatch := True
    else if SameText(Arg, '-step') then
      GStepAfterBp := True
    else if ExePath = '' then
      ExePath := Arg;
    Inc(I);
  end;
  Result := (ExePath <> '') and FileExists(ExePath);
  if not Result then begin
    Say('usage: Wow64StackProbe <exe> [-rva <hex>] [-maxstops <n>] [-nopatch] [-step]');
    Say('  -rva <hex>   plant an INT3 at this RVA and walk the stack there');
    Say('  -maxstops N  when no -rva is given, walk the first N stops');
    Say('  -nopatch     walk with the INT3 still planted and EIP one past it,');
    Say('               which is the state the shipping adapter is in at a stop.');
    Say('               Compare frame 0 against a normal run to see whether');
    Say('               StackWalk64''s just-entered-frame handling reads the');
    Say('               prolog byte or blindly takes [ESP].');
    Say('  -step        after the user breakpoint, set EFLAGS.TF and continue,');
    Say('               to observe which exception code a single step reports.');
  end;
end;

var
  ExePath:  string;
  Rva:      UInt64;
  MaxStops: Integer;
begin
  try
    if not ParseArgs(ExePath, Rva, MaxStops) then
      Halt(1);
    Say(Format('probe host is %d-bit', [SizeOf(Pointer) * 8]));
    Run(ExePath, Rva, MaxStops);
  except
    on E: Exception do
      Say(E.ClassName + ': ' + E.Message);
  end;
end.
