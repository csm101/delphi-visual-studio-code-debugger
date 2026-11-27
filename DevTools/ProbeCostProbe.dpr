program ProbeCostProbe;

// Measures what the profiler and the code coverage would pay per event, before
// either is built (docs\PROFILER_COVERAGE_PLAN.md, increment 0).
//
//   -hits    the cost of a line probe that goes through a debug event
//   -walk    the cost of one raw stack capture at a stop
//   -suspend the cost of suspending a RUNNING thread and reading its context
//   -cycles  whether a thread's cycle counter moves while the thread runs
//
// Nothing here is tied to one binary: every target, source line and count comes
// from the command line.
//
//   ProbeCostProbe -hits [-keeprwx] [-n <reps>] [-timeout <s>] [-maskdigits]
//                  [-inroutine] [-skip <rva,rva,...>] [-bisect] [-floodlimit <n>]
//                  [-showoutput] [-trace] <exe> [args...]
//     Raw Windows debug loop (no engine: the engine has no probe table yet).
//     Reads the main module's TD32 line records through TTD32FileReader, plants a
//     $CC on every one at the first breakpoint event, and on each hit restores
//     the byte, rewinds the program counter and continues. Every repetition also
//     runs the target WITHOUT planting, under the same loop, as the baseline.
//     -keeprwx    leaves the patched pages PAGE_EXECUTE_READWRITE, so a hit is
//                 one plain WriteProcessMemory instead of the engine's
//                 protect/write/protect/flush.
//     -maskdigits also compares the two outputs with every number masked, for a
//                 target that prints timings.
//     -inroutine  leaves out the records the TD32 reader attributes to no routine.
//     -skip       leaves out the listed records (hexadecimal RVAs).
//     -bisect     measures nothing: finds the records whose $CC alone makes the
//                 target end differently, and says what they are.
//     -floodlimit ends a run after that many exceptions that were not probes
//                 (default 20000): a probe on something that was not an
//                 instruction can make a program fault for ever.
//
//   ProbeCostProbe -walk [-n <walks>] [-rounds <r>] [-maxframes <m>] [-hit <k>]
//                  [-frames] <exe> <source:line|source:MARKER> [args...]
//     Drives a real TDebugSession to a breakpoint (MARKER is the text inside a
//     `{BP:...}` tag of the source file) and times raw stack walks of the stopped
//     thread: the engine's own WalkRawFrames, which bypasses the per-stop frame
//     cache, and the bare alternatives it could be replaced with.
//
//   ProbeCostProbe -suspend [-n <samples>] [-warmup <ms>] [-timeout <s>]
//                  [-nativesuspend] <exe> [args...]
//     Runs the target under the raw debug loop and, between events, times
//     SuspendThread + GetThreadContext + ResumeThread on its busiest thread and
//     on one that does not run. -nativesuspend uses SuspendThread on a 32-bit
//     target as well, instead of Wow64SuspendThread.
//
//   ProbeCostProbe -cycles [-seconds <s>] [-mycore <n>] [-spincore <n>] [-finetick <us>]
//     Needs no target: starts a child copy of itself that spins on one core and
//     reads that thread's cycle counter and thread times from another core.
//
// The tool is also its own fixture, so that a deep stack and a busy thread can be
// arranged on both bitnesses without touching the test targets:
//
//   ProbeCostProbe -recurse <depth>           recurse, then return
//   ProbeCostProbe -spin <maskhex> <seconds>  one spinning thread, one blocked
//
// Built with dcc32 (build_one32.bat) only those two modes exist: the 32-bit build
// is a debuggee, never a debugger.

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils
{$IFDEF CPUX64}
  ,
  System.Classes,
  System.Math,
  System.TypInfo,
  System.IOUtils,
  System.Generics.Collections,
  System.Win.Registry,
  Winapi.MMSystem,
  DebugInfoTypes,
  TD32FileReader,
  DebugTarget,
  DebugSessionTypes,
  DebugSession,
  WinDebuggerBase
{$ENDIF}
  ;

{ ------------------------------------------- the built-in targets (x86 + x64) -- }

// Both routines must keep a frame of their own whatever the build flags are: the
// 32-bit walk under test follows the EBP chain.
{$OPTIMIZATION OFF}
{$STACKFRAMES ON}

var
  GRecurseBottoms: Integer = 0;
  GSpinSink:       UInt64  = 0;

function Descend(Depth: Integer): Integer;
begin
  if Depth <= 0 then begin
    Inc(GRecurseBottoms);   // {BP:RECURSE_BOTTOM}
    Exit(1);
  end;
  Result := Descend(Depth - 1) + 1;
end;

function SleeperThread(Parameter: Pointer): Integer;
begin
  Sleep(INFINITE);
  Result := 0;
end;

// One thread that never leaves user mode and one that never runs. Their ids go
// to stdout so that a parent can open them.
procedure RunSpinTarget(AffinityMask: NativeUInt; Seconds: Integer);
begin
  var SleeperId: TThreadID;
  BeginThread(nil, 0, SleeperThread, nil, 0, SleeperId);
  if AffinityMask <> 0 then
    SetThreadAffinityMask(GetCurrentThread, AffinityMask);
  Writeln(Format('spin=%d sleep=%d', [GetCurrentThreadId, SleeperId]));
  Flush(Output);
  var Deadline := GetTickCount64 + UInt64(Seconds) * 1000;
  var Counter: UInt64 := 0;
  while True do begin
    Inc(Counter);
    // GetTickCount64 reads shared memory: the loop makes no system call.
    if ((Counter and $FFFFF) = 0) and (GetTickCount64 >= Deadline) then
      Break;
  end;
  GSpinSink := Counter;
end;

function RunBuiltInTarget: Boolean;
begin
  Result := True;
  if SameText(ParamStr(1), '-spin') then
    RunSpinTarget(NativeUInt(StrToInt64Def('$' + ParamStr(2), 0)), StrToIntDef(ParamStr(3), 30))
  else if SameText(ParamStr(1), '-recurse') then
    Writeln('frames below the main block: ', Descend(StrToIntDef(ParamStr(2), 10)))
  else
    Result := False;
end;

{$IFDEF CPUX64}
{$OPTIMIZATION ON}
{$STACKFRAMES OFF}

{ ----------------------------------------------------------------- bindings -- }

const
  STATUS_WX86_BREAKPOINT = DWORD($4000001F);
  HANDLE_LIST_ATTRIBUTE  = $00020002;   // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
  HIGH_RESOLUTION_TIMER  = $00000002;   // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
  TIMER_FULL_ACCESS      = $001F0003;
  THREAD_QUERY_ACCESS    = $0040;       // THREAD_QUERY_INFORMATION
  MACHINE_I386           = $014C;
  MACHINE_AMD64          = $8664;
  ADDRESS_MODE_FLAT      = 3;
  PAGE_BYTES             = 4096;
  EXECUTABLE_PROTECTIONS = PAGE_EXECUTE or PAGE_EXECUTE_READ or PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_WRITECOPY;
  TIMEOUT_EXIT_CODE      = $DEAD;
  RUNAWAY_STALE_HITS     = 1000000;

type
  TStartupInfoWithAttributes = record
    StartupInfo:   TStartupInfo;
    AttributeList: PProcThreadAttributeList;
  end;

  // C ADDRESS64 and STACKFRAME64, as dbghelp expects them on x64.
  TWalkAddress = record
    Offset:  UInt64;
    Segment: Word;
    Mode:    DWORD;
  end;

  TWalkFrame = record
    AddrPC, AddrReturn, AddrFrame, AddrStack, AddrBStore: TWalkAddress;
    FuncTableEntry: Pointer;
    Params:         array[0..3] of UInt64;
    IsFar:          BOOL;
    IsVirtual:      BOOL;
    Reserved:       array[0..2] of UInt64;
    KdHelp:         array[0..111] of Byte;
  end;

function StackWalk64(MachineType: DWORD; hProcess, hThread: THandle; var StackFrame: TWalkFrame;
  ContextRecord: Pointer; ReadMemoryRoutine, FunctionTableAccessRoutine, GetModuleBaseRoutine,
  TranslateAddressRoutine: Pointer): BOOL; stdcall; external 'dbghelp.dll';
function SymFunctionTableAccess64(hProcess: THandle; AddrBase: UInt64): Pointer; stdcall; external 'dbghelp.dll';
function SymGetModuleBase64(hProcess: THandle; qwAddr: UInt64): UInt64; stdcall; external 'dbghelp.dll';
function OpenThreadById(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwThreadId: DWORD): THandle; stdcall;
  external kernel32 name 'OpenThread';

{ -------------------------------------------------------------------- timing -- }

var
  GQpcFrequency: Int64;

function QpcNow: Int64; inline;
begin
  QueryPerformanceCounter(Result);
end;

function TicksToUs(Ticks: Int64): Double; inline;
begin
  Result := Ticks * 1e6 / GQpcFrequency;
end;

type
  TSpread = record
    Count: Integer;
    Min, P10, Median, P90, Max, Mean: Double;
    class function From(const Values: TArray<Double>; Used: Integer = -1): TSpread; static;
  end;

class function TSpread.From(const Values: TArray<Double>; Used: Integer): TSpread;
begin
  Result := Default(TSpread);
  if Used < 0 then
    Used := Length(Values);
  if Used = 0 then
    Exit;
  var Sorted := Copy(Values, 0, Used);
  TArray.Sort<Double>(Sorted);
  Result.Count  := Used;
  Result.Min    := Sorted[0];
  Result.Max    := Sorted[Used - 1];
  Result.P10    := Sorted[(Used - 1) div 10];
  Result.Median := Sorted[(Used - 1) div 2];
  Result.P90    := Sorted[((Used - 1) * 9) div 10];
  Result.Mean   := Sum(Sorted) / Used;
end;

{ ------------------------------------------------------------------- machine -- }

function PhysicalCoreCount: Integer;
begin
  Result := 0;
  var Needed: DWORD := 0;
  GetLogicalProcessorInformation(nil, Needed);
  if Needed = 0 then
    Exit;
  var Buffer: TBytes;
  SetLength(Buffer, Needed);
  if not GetLogicalProcessorInformation(PSystemLogicalProcessorInformation(@Buffer[0]), Needed) then
    Exit;
  var Entry := PSystemLogicalProcessorInformation(@Buffer[0]);
  for var I := 1 to Integer(Needed div SizeOf(TSystemLogicalProcessorInformation)) do begin
    if Entry^.Relationship = RelationProcessorCore then
      Inc(Result);
    Inc(Entry);
  end;
end;

function MachineDescription: string;
begin
  var Cpu: string := '?';
  var Build: string := '?';
  var Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_LOCAL_MACHINE;
    if Registry.OpenKeyReadOnly('HARDWARE\DESCRIPTION\System\CentralProcessor\0') then begin
      Cpu := Trim(Registry.ReadString('ProcessorNameString'));
      Registry.CloseKey;
    end;
    if Registry.OpenKeyReadOnly('SOFTWARE\Microsoft\Windows NT\CurrentVersion') then begin
      Build := Registry.ReadString('CurrentBuild');
      if Registry.ValueExists('UBR') then
        Build := Build + '.' + IntToStr(Registry.ReadInteger('UBR'));
      if Registry.ValueExists('DisplayVersion') then
        Build := Build + ' (' + Registry.ReadString('DisplayVersion') + ')';
      Registry.CloseKey;
    end;
  finally
    Registry.Free;
  end;
  Result := Format('%s, %d cores / %d logical, Windows build %s', [Cpu, PhysicalCoreCount, CPUCount, Build]);
end;

{ ------------------------------------------------------------- command lines -- }

function QuoteArgument(const Value: string): string;
begin
  if (Value <> '') and (Value.IndexOfAny([' ', #9, '"']) < 0) then
    Exit(Value);
  // A backslash run before the closing quote would escape it.
  var Trailing := 0;
  while (Trailing < Value.Length) and (Value[Value.Length - Trailing] = '\') do
    Inc(Trailing);
  Result := '"' + Value.Replace('"', '\"') + StringOfChar('\', Trailing) + '"';
end;

function BuildCommandLine(const Exe: string; const Args: TArray<string>): string;
begin
  Result := QuoteArgument(Exe);
  for var Arg in Args do
    Result := Result + ' ' + QuoteArgument(Arg);
end;

function JoinArguments(const Args: TArray<string>): string;
begin
  Result := '';
  for var Arg in Args do begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + QuoteArgument(Arg);
  end;
end;

// Options of this tool come first; the first word that is not one of them is
// the target, and everything after it belongs to the target.
function TakeOptions(var Index: Integer; const WithValue, Flags: array of string): TDictionary<string, string>;

  function IsOneOf(const Name: string; const Names: array of string): Boolean;
  begin
    for var Candidate in Names do
      if SameText(Candidate, Name) then
        Exit(True);
    Result := False;
  end;

begin
  Result := TDictionary<string, string>.Create;
  while Index <= ParamCount do begin
    var Name := LowerCase(ParamStr(Index));
    if IsOneOf(Name, Flags) then begin
      Result.AddOrSetValue(Name, '1');
      Inc(Index);
    end
    else if IsOneOf(Name, WithValue) then begin
      Result.AddOrSetValue(Name, ParamStr(Index + 1));
      Inc(Index, 2);
    end
    else
      Break;
  end;
end;

function RemainingArguments(Index: Integer): TArray<string>;
begin
  Result := nil;
  for var I := Index to ParamCount do
    Result := Result + [ParamStr(I)];
end;

function OptionInt(Options: TDictionary<string, string>; const Name: string; Default: Integer): Integer;
begin
  var Text: string;
  if Options.TryGetValue(Name, Text) then
    Result := StrToIntDef(Text, Default)
  else
    Result := Default;
end;

function PeMachine(const Path: string): Word;
begin
  var Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    var HeaderOffset: Integer;
    Stream.Position := $3C;
    Stream.ReadBuffer(HeaderOffset, SizeOf(HeaderOffset));
    var Signature: Cardinal;
    Stream.Position := HeaderOffset;
    Stream.ReadBuffer(Signature, SizeOf(Signature));
    if Signature <> $00004550 then
      raise Exception.Create('not a PE image: ' + Path);
    Stream.ReadBuffer(Result, SizeOf(Result));
  finally
    Stream.Free;
  end;
end;

function BitnessName(IsWow64: Boolean): string;
begin
  if IsWow64 then
    Result := 'x86 under WOW64'
  else
    Result := 'x64';
end;

{ ------------------------------------------------------------ child processes -- }

function InheritableSecurity: TSecurityAttributes;
begin
  Result := Default(TSecurityAttributes);
  Result.nLength        := SizeOf(Result);
  Result.bInheritHandle := True;
end;

function OpenNulForChild: THandle;
begin
  var Security := InheritableSecurity;
  Result := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @Security, OPEN_EXISTING, 0, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

function CreateChildOutputFile(const Path: string): THandle;
begin
  var Security := InheritableSecurity;
  Result := CreateFile(PChar(Path), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    @Security, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

// A child never inherits this tool's standard handles: it gets StdInput and
// StdOutput (stderr shares the latter) and nothing else, the way
// TWinDebugger.LaunchWithCapturedStdio starts a console debuggee.
function LaunchWithStdHandles(const CommandLine: string; StdInput, StdOutput: THandle;
  CreationFlags: DWORD): TProcessInformation;
begin
  var ListSize: NativeUInt := 0;
  InitializeProcThreadAttributeList(nil, 1, 0, ListSize);
  var ListBuffer: TBytes;
  SetLength(ListBuffer, ListSize);
  var List := PProcThreadAttributeList(@ListBuffer[0]);
  if not InitializeProcThreadAttributeList(List, 1, 0, ListSize) then
    RaiseLastOSError;
  try
    var Inherited_: array[0..1] of THandle;
    Inherited_[0] := StdInput;
    Inherited_[1] := StdOutput;
    if not UpdateProcThreadAttribute(List, 0, HANDLE_LIST_ATTRIBUTE, @Inherited_[0], SizeOf(Inherited_), nil,
         PNativeUInt(nil)^) then
      RaiseLastOSError;
    var Startup := Default(TStartupInfoWithAttributes);
    Startup.StartupInfo.cb         := SizeOf(Startup);
    Startup.StartupInfo.dwFlags    := STARTF_USESTDHANDLES;
    Startup.StartupInfo.hStdInput  := StdInput;
    Startup.StartupInfo.hStdOutput := StdOutput;
    Startup.StartupInfo.hStdError  := StdOutput;
    Startup.AttributeList          := List;
    var Writable := CommandLine;
    UniqueString(Writable);
    if not CreateProcess(nil, PChar(Writable), nil, nil, True, CreationFlags or EXTENDED_STARTUPINFO_PRESENT,
         nil, nil, Startup.StartupInfo, Result) then
      RaiseLastOSError;
  finally
    DeleteProcThreadAttributeList(List);
  end;
end;

{ ------------------------------------------------------------ raw debug loop -- }

type
  TPatchedPage = record
    VA:          UInt64;
    First, Last: Integer;   // probe indexes that live on this page
    Original:    TBytes;
  end;

  // One launch of a target under DEBUG_ONLY_THIS_PROCESS, with or without a $CC
  // on every line record. The same loop serves the baseline, so the difference
  // between the two wall times is the probes and nothing else.
  TRawDebugRun = class
  private
    FThreads:    TDictionary<DWORD, THandle>;
    FProbeIndex: TDictionary<UInt64, Integer>;
    FProbeVA:    TArray<UInt64>;
    FOriginal:   TArray<Byte>;
    FPlanted:    TArray<Boolean>;
    FFired:      TArray<Boolean>;
    FPages:      TArray<TPatchedPage>;
    FGaps:       TArray<Double>;
    FGapCount:   Integer;
    FLastHit:    Int64;
    FSeenNativeLoaderBreak, FSeenWowLoaderBreak, FStopRequested: Boolean;
    procedure PumpUntilExit(Started: Int64);
    function  HandleException(const Event: TDebugEvent): DWORD;
    procedure PlantAll;
    procedure PlantPage(PageVA: UInt64; First, Last: Integer);
    procedure RestoreOriginalByte(Index: Integer);
    procedure RewindProgramCounter(ThreadId: DWORD; Address: UInt64);
    procedure VerifyPatchedPages;
  public
    // Configuration.
    Rvas:         TArray<UInt64>;
    Plant:        Boolean;
    KeepWritable: Boolean;
    IsWow64:      Boolean;
    TimeoutMs:    Cardinal;
    WaitMs:       Cardinal;
    OnIdle:       TProc;
    // Results.
    Process:      THandle;
    ImageBase:    UInt64;
    ExitCode:     DWORD;
    TimedOut:     Boolean;
    Flooded:      Boolean;
    FloodLimit:   Integer;
    WallMs:       Double;
    PlantMs:      Double;
    HandlerTicks: Int64;
    Planted, PagesTouched, SkippedNotExecutable, SkippedAlreadyInt3: Integer;
    Events, TracedExceptions: Integer;
    Trace:        Boolean;
    RestoreTicks: Int64;
    RewindTicks:  Int64;
    ContextReadTicks: Int64;
    Hits, StaleHits, OtherExceptions, ContextFailures, WriteFailures, MaxThreads: Integer;
    VerifyDone:       Boolean;
    VerifyMismatches: Integer;
    Output:           TBytes;
    constructor Create;
    destructor  Destroy; override;
    procedure Execute(const CommandLine: string);
    procedure RequestStop;
    function  LoaderBreakSeen: Boolean;
    function  GapsUs: TArray<Double>;
    property  Threads: TDictionary<DWORD, THandle> read FThreads;
  end;

var
  GOutputFileSerial: Integer = 0;

constructor TRawDebugRun.Create;
begin
  inherited Create;
  FThreads    := TDictionary<DWORD, THandle>.Create;
  FProbeIndex := TDictionary<UInt64, Integer>.Create;
  TimeoutMs   := 120000;
  WaitMs      := 100;
  FloodLimit  := 20000;
end;

destructor TRawDebugRun.Destroy;
begin
  FProbeIndex.Free;
  FThreads.Free;
  inherited;
end;

function TRawDebugRun.LoaderBreakSeen: Boolean;
begin
  Result := FSeenNativeLoaderBreak or FSeenWowLoaderBreak;
end;

function TRawDebugRun.GapsUs: TArray<Double>;
begin
  Result := Copy(FGaps, 0, FGapCount);
end;

procedure TRawDebugRun.RequestStop;
begin
  if FStopRequested then
    Exit;
  FStopRequested := True;
  TerminateProcess(Process, 0);
end;

procedure TRawDebugRun.Execute(const CommandLine: string);
begin
  Inc(GOutputFileSerial);
  var OutputPath := TPath.Combine(TPath.GetTempPath,
    Format('ProbeCostProbe_%d_%d.out', [GetCurrentProcessId, GOutputFileSerial]));
  var NulInput := OpenNulForChild;
  var OutputFile := CreateChildOutputFile(OutputPath);
  try
    var Started := QpcNow;
    var Info := LaunchWithStdHandles(CommandLine, NulInput, OutputFile, DEBUG_ONLY_THIS_PROCESS);
    CloseHandle(Info.hThread);
    Process := Info.hProcess;
    try
      PumpUntilExit(Started);
    finally
      // A no-op once the target has exited; after an error it is what keeps a
      // debuggee from outliving the run.
      TerminateProcess(Process, TIMEOUT_EXIT_CODE);
      // The image stays mapped until the process object goes: wait for it before
      // anything is deleted.
      WaitForSingleObject(Process, 10000);
      CloseHandle(Process);
    end;
  finally
    CloseHandle(NulInput);
    CloseHandle(OutputFile);
    if TFile.Exists(OutputPath) then begin
      Output := TFile.ReadAllBytes(OutputPath);
      TFile.Delete(OutputPath);
    end;
  end;
end;

procedure TRawDebugRun.PumpUntilExit(Started: Int64);
var
  Event: TDebugEvent;
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while True do begin
    // Checked on every turn, not only on an idle one: a target that floods the
    // loop with events never lets the wait time out.
    if (not TimedOut) and (GetTickCount64 > Deadline) then begin
      TimedOut := True;
      TerminateProcess(Process, TIMEOUT_EXIT_CODE);
    end;
    if not WaitForDebugEvent(Event, WaitMs) then begin
      if Assigned(OnIdle) and not (FStopRequested or TimedOut) then
        OnIdle();
      Continue;
    end;
    Inc(Events);
    var Status: DWORD := DBG_CONTINUE;
    case Event.dwDebugEventCode of
      CREATE_PROCESS_DEBUG_EVENT: begin
        ImageBase := UInt64(NativeUInt(Event.CreateProcessInfo.lpBaseOfImage));
        FThreads.AddOrSetValue(Event.dwThreadId, Event.CreateProcessInfo.hThread);
        if Event.CreateProcessInfo.hFile <> 0 then
          CloseHandle(Event.CreateProcessInfo.hFile);
      end;
      CREATE_THREAD_DEBUG_EVENT:
        FThreads.AddOrSetValue(Event.dwThreadId, Event.CreateThread.hThread);
      EXIT_THREAD_DEBUG_EVENT:
        FThreads.Remove(Event.dwThreadId);
      LOAD_DLL_DEBUG_EVENT:
        if Event.LoadDll.hFile <> 0 then
          CloseHandle(Event.LoadDll.hFile);
      EXCEPTION_DEBUG_EVENT:
        Status := HandleException(Event);
      EXIT_PROCESS_DEBUG_EVENT: begin
        WallMs   := TicksToUs(QpcNow - Started) / 1000;
        ExitCode := Event.ExitProcess.dwExitCode;
        // The address space is still there at this event, which is the last
        // moment the patched pages can be compared with what was planted.
        if Plant then
          VerifyPatchedPages;
        ContinueDebugEvent(Event.dwProcessId, Event.dwThreadId, DBG_CONTINUE);
        Exit;
      end;
    end;
    if FThreads.Count > MaxThreads then
      MaxThreads := FThreads.Count;
    ContinueDebugEvent(Event.dwProcessId, Event.dwThreadId, Status);
  end;
end;

function TRawDebugRun.HandleException(const Event: TDebugEvent): DWORD;
begin
  var Code := DWORD(Event.Exception.ExceptionRecord.ExceptionCode);
  if Trace and (TracedExceptions < 60) then begin
    Inc(TracedExceptions);
    Writeln(Format('      exception %s at %s, thread %d, first chance %d', [IntToHex(Code, 8),
      IntToHex(UInt64(NativeUInt(Event.Exception.ExceptionRecord.ExceptionAddress)), 8), Event.dwThreadId,
      Event.Exception.dwFirstChance]));
  end;
  var IsWowBreak := Code = STATUS_WX86_BREAKPOINT;
  if (Code <> DWORD(EXCEPTION_BREAKPOINT)) and not IsWowBreak then begin
    Inc(OtherExceptions);
    // A program that faults for ever (a probe that landed on something that was
    // not an instruction can do that) would otherwise run until the timeout.
    if (OtherExceptions > FloodLimit) and not Flooded then begin
      Flooded := True;
      RequestStop;
    end;
    Exit(DBG_EXCEPTION_NOT_HANDLED);
  end;

  var Arrived := QpcNow;
  var Address := UInt64(NativeUInt(Event.Exception.ExceptionRecord.ExceptionAddress));
  var Index: Integer;
  if FProbeIndex.TryGetValue(Address, Index) then begin
    if FFired[Index] then
      // Another thread ran into the same $CC before it was taken out. Its trap
      // was already queued; it only has to be sent back to the instruction.
      Inc(StaleHits)
    else begin
      RestoreOriginalByte(Index);
      FFired[Index] := True;
      if Hits > 0 then begin
        FGaps[FGapCount] := TicksToUs(Arrived - FLastHit);
        Inc(FGapCount);
      end;
      FLastHit := Arrived;
      Inc(Hits);
    end;
    var Restored := QpcNow;
    RewindProgramCounter(Event.dwThreadId, Address);
    var Rewound := QpcNow;
    Inc(RestoreTicks, Restored - Arrived);
    Inc(RewindTicks, Rewound - Restored);
    Inc(HandlerTicks, Rewound - Arrived);
    if StaleHits > RUNAWAY_STALE_HITS then
      RequestStop;
    Exit(DBG_CONTINUE);
  end;

  // The loader's own breakpoint: one for a native target; a WOW64 target reports
  // a native one and then a 32-bit one. Probes go in at the first of them.
  var IsLoaderBreak := (IsWowBreak and not FSeenWowLoaderBreak) or ((not IsWowBreak) and not FSeenNativeLoaderBreak);
  if IsLoaderBreak then begin
    var IsFirst := not LoaderBreakSeen;
    if IsWowBreak then
      FSeenWowLoaderBreak := True
    else
      FSeenNativeLoaderBreak := True;
    if IsFirst and Plant then
      PlantAll;
    Exit(DBG_CONTINUE);
  end;

  Inc(OtherExceptions);
  Result := DBG_EXCEPTION_NOT_HANDLED;
end;

procedure TRawDebugRun.PlantAll;
begin
  var Started := QpcNow;
  var Sorted := Copy(Rvas);
  TArray.Sort<UInt64>(Sorted);
  SetLength(FProbeVA, Length(Sorted));
  var Count := 0;
  for var I := 0 to High(Sorted) do begin
    if (I > 0) and (Sorted[I] = Sorted[I - 1]) then
      Continue;
    FProbeVA[Count] := ImageBase + Sorted[I];
    Inc(Count);
  end;
  SetLength(FProbeVA, Count);
  SetLength(FOriginal, Count);
  SetLength(FPlanted, Count);
  SetLength(FFired, Count);
  SetLength(FGaps, Count);

  // One read and one write per page, whatever the number of records on it.
  var First := 0;
  while First < Count do begin
    var PageVA := FProbeVA[First] and not UInt64(PAGE_BYTES - 1);
    var Last := First;
    while (Last + 1 < Count) and (FProbeVA[Last + 1] < PageVA + PAGE_BYTES) do
      Inc(Last);
    PlantPage(PageVA, First, Last);
    First := Last + 1;
  end;
  FlushInstructionCache(Process, nil, 0);
  PlantMs := TicksToUs(QpcNow - Started) / 1000;
end;

procedure TRawDebugRun.PlantPage(PageVA: UInt64; First, Last: Integer);
var
  Info:   TMemoryBasicInformation;
  Buffer: array[0..PAGE_BYTES - 1] of Byte;
  Done:   NativeUInt;
  OldProtect, Ignored: DWORD;
begin
  var IsCode := (VirtualQueryEx(Process, Pointer(PageVA), Info, SizeOf(Info)) <> 0) and
    (Info.State = MEM_COMMIT) and ((Info.Protect and EXECUTABLE_PROTECTIONS) <> 0);
  if not IsCode then begin
    Inc(SkippedNotExecutable, Last - First + 1);
    Exit;
  end;
  if not ReadProcessMemory(Process, Pointer(PageVA), @Buffer, PAGE_BYTES, Done) or (Done <> PAGE_BYTES) then begin
    Inc(WriteFailures, Last - First + 1);
    Exit;
  end;

  var Page: TPatchedPage;
  Page.VA    := PageVA;
  Page.First := First;
  Page.Last  := Last;
  SetLength(Page.Original, PAGE_BYTES);
  Move(Buffer, Page.Original[0], PAGE_BYTES);

  var PlantedHere := 0;
  for var I := First to Last do begin
    var Offset := FProbeVA[I] - PageVA;
    FOriginal[I] := Buffer[Offset];
    // A record that already sits on an int3 cannot carry a one-shot: restoring
    // the "original" would leave a trap that reads as a stale hit for ever.
    if Buffer[Offset] = $CC then begin
      Inc(SkippedAlreadyInt3);
      Continue;
    end;
    Buffer[Offset] := $CC;
    FPlanted[I] := True;
    Inc(PlantedHere);
  end;
  if PlantedHere = 0 then
    Exit;

  VirtualProtectEx(Process, Pointer(PageVA), PAGE_BYTES, PAGE_EXECUTE_READWRITE, OldProtect);
  var Written := WriteProcessMemory(Process, Pointer(PageVA), @Buffer, PAGE_BYTES, Done) and (Done = PAGE_BYTES);
  if not KeepWritable then
    VirtualProtectEx(Process, Pointer(PageVA), PAGE_BYTES, OldProtect, Ignored);
  if not Written then begin
    for var I := First to Last do
      FPlanted[I] := False;
    Inc(WriteFailures, PlantedHere);
    Exit;
  end;

  for var I := First to Last do
    if FPlanted[I] then
      FProbeIndex.Add(FProbeVA[I], I);
  Inc(Planted, PlantedHere);
  Inc(PagesTouched);
  FPages := FPages + [Page];
end;

procedure TRawDebugRun.RestoreOriginalByte(Index: Integer);
var
  Done: NativeUInt;
  OldProtect, Ignored: DWORD;
begin
  var Target := Pointer(FProbeVA[Index]);
  if KeepWritable then begin
    if not WriteProcessMemory(Process, Target, @FOriginal[Index], 1, Done) then
      Inc(WriteFailures);
    Exit;
  end;
  // The engine's own sequence for one byte (TWinDebugger.WriteByte).
  VirtualProtectEx(Process, Target, 1, PAGE_EXECUTE_READWRITE, OldProtect);
  if not WriteProcessMemory(Process, Target, @FOriginal[Index], 1, Done) then
    Inc(WriteFailures);
  VirtualProtectEx(Process, Target, 1, OldProtect, Ignored);
  FlushInstructionCache(Process, Target, 1);
end;

procedure TRawDebugRun.RewindProgramCounter(ThreadId: DWORD; Address: UInt64);
var
  Context:    TContext;
  WowContext: TWow64Context;
begin
  var Thread: THandle;
  if not FThreads.TryGetValue(ThreadId, Thread) then begin
    Inc(ContextFailures);
    Exit;
  end;
  var Done: Boolean;
  var Started := QpcNow;
  if IsWow64 then begin
    WowContext.ContextFlags := WOW64_CONTEXT_CONTROL;
    Done := Wow64GetThreadContext(Thread, WowContext);
    Inc(ContextReadTicks, QpcNow - Started);
    if Done then begin
      WowContext.Eip := DWORD(Address);
      Done := Wow64SetThreadContext(Thread, WowContext);
    end;
  end
  else begin
    Context.ContextFlags := CONTEXT_CONTROL;
    Done := GetThreadContext(Thread, Context);
    Inc(ContextReadTicks, QpcNow - Started);
    if Done then begin
      Context.Rip := Address;
      Done := SetThreadContext(Thread, Context);
    end;
  end;
  if not Done then
    Inc(ContextFailures);
end;

// Every patched page must read as it did before planting, except for a $CC on
// each record that never fired.
procedure TRawDebugRun.VerifyPatchedPages;
var
  Buffer: array[0..PAGE_BYTES - 1] of Byte;
  Done:   NativeUInt;
begin
  for var Page in FPages do begin
    if not ReadProcessMemory(Process, Pointer(Page.VA), @Buffer, PAGE_BYTES, Done) or (Done <> PAGE_BYTES) then
      Exit;
    var Expected := Copy(Page.Original);
    for var I := Page.First to Page.Last do
      if FPlanted[I] and not FFired[I] then
        Expected[FProbeVA[I] - Page.VA] := $CC;
    for var Offset := 0 to PAGE_BYTES - 1 do
      if Buffer[Offset] <> Expected[Offset] then
        Inc(VerifyMismatches);
  end;
  VerifyDone := True;
end;

{ --------------------------------------------------------------------- -hits -- }

function LoadLineRvas(const ExePath: string; InRoutineOnly: Boolean; out OutsideRoutines: Integer): TArray<UInt64>;
begin
  OutsideRoutines := 0;
  // The reader keeps the image mapped while it lives, so it is gone before the
  // target is launched.
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ExePath);
    if not Reader.Loaded then
      Exit(nil);
    Result := nil;
    for var Rva in Reader.SortedRvas do begin
      var RoutineRva: UInt64;
      var InRoutine := Reader.RvaToFunctionStart(Rva, RoutineRva);
      if not InRoutine then
        Inc(OutsideRoutines);
      if InRoutine or not InRoutineOnly then
        Result := Result + [Rva];
    end;
  finally
    Reader.Free;
  end;
end;

// Replaces every number by one '#', together with the blanks around it: a
// right-aligned timing changes its padding with its width.
function MaskDigitRuns(const Bytes: TBytes): TBytes;
begin
  SetLength(Result, Length(Bytes));
  var Count := 0;
  var Index := 0;
  while Index < Length(Bytes) do begin
    var RunEnd := Index;
    var HasDigit := False;
    while (RunEnd < Length(Bytes)) and ((Bytes[RunEnd] = Ord(' ')) or (Bytes[RunEnd] in [Ord('0')..Ord('9')])) do begin
      HasDigit := HasDigit or (Bytes[RunEnd] <> Ord(' '));
      Inc(RunEnd);
    end;
    if HasDigit then begin
      Result[Count] := Ord('#');
      Inc(Count);
      Index := RunEnd;
      Continue;
    end;
    // Blanks only (kept as they are), or an ordinary byte.
    if RunEnd = Index then
      RunEnd := Index + 1;
    while Index < RunEnd do begin
      Result[Count] := Bytes[Index];
      Inc(Count);
      Inc(Index);
    end;
  end;
  SetLength(Result, Count);
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

// Rvas without the ones listed in Skipped (hexadecimal, comma separated).
function WithoutRvas(const Rvas: TArray<UInt64>; const Skipped: string): TArray<UInt64>;
begin
  var Unwanted := TDictionary<UInt64, Boolean>.Create;
  try
    for var Part in Skipped.Split([',']) do
      Unwanted.AddOrSetValue(UInt64(StrToInt64Def('$' + Trim(Part), -1)), True);
    Result := nil;
    for var Rva in Rvas do
      if not Unwanted.ContainsKey(Rva) then
        Result := Result + [Rva];
  finally
    Unwanted.Free;
  end;
end;

// Finds, one at a time, the line records whose $CC alone makes the target end
// differently from the unprobed run: a record that is not an instruction
// boundary, or that points at data.
procedure BisectBreakingRecords(const Exe: string; const Rvas: TArray<UInt64>;
  const Breaks: TFunc<TArray<UInt64>, Boolean>);
const
  MAX_CULPRITS = 32;
begin
  var Remaining := Copy(Rvas);
  TArray.Sort<UInt64>(Remaining);
  var Culprits: TArray<UInt64>;
  var Runs := 0;
  while Length(Culprits) < MAX_CULPRITS do begin
    Inc(Runs);
    if not Breaks(Remaining) then
      Break;
    var Low := 0;
    var High := Length(Remaining) - 1;
    while Low < High do begin
      var Middle := (Low + High) div 2;
      Inc(Runs);
      if Breaks(Copy(Remaining, Low, Middle - Low + 1)) then
        High := Middle
      else
        Low := Middle + 1;
    end;
    Inc(Runs);
    if not Breaks([Remaining[Low]]) then begin
      Writeln(Format('record %s does not break the target alone: the failure needs several records together',
        [IntToHex(Remaining[Low], 1)]));
      Break;
    end;
    Culprits := Culprits + [Remaining[Low]];
    Writeln(Format('breaking record found: rva %s', [IntToHex(Remaining[Low], 1)]));
    Delete(Remaining, Low, 1);
  end;

  Writeln;
  Writeln(Format('%d probed runs; %d of %d records break the target when probed alone:',
    [Runs, Length(Culprits), Length(Rvas)]));
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(Exe);
    var List := '';
    for var Rva in Culprits do begin
      var Location: TSourceLocation;
      var Where := '<no source line>';
      if Reader.RvaToSourceLine(Rva, Location) then
        Where := Format('%s:%d', [ExtractFileName(Location.SourceFile), Location.Line]);
      var Routine: string;
      if not Reader.RvaToFunctionName(Rva, Routine) then
        Routine := '<no routine>';
      var RoutineRva: UInt64 := 0;
      Reader.RvaToFunctionStart(Rva, RoutineRva);
      Writeln(Format('  rva %s  %s  in %s (routine starts at %s)',
        [IntToHex(Rva, 1), Where, Routine, IntToHex(RoutineRva, 1)]));
      if List <> '' then
        List := List + ',';
      List := List + IntToHex(Rva, 1);
    end;
    if List <> '' then
      Writeln('rerun the measurement with: -skip ', List);
  finally
    Reader.Free;
  end;
end;

procedure RunHitsMode;
begin
  var Index := 2;
  var Options := TakeOptions(Index, ['-n', '-timeout', '-skip', '-floodlimit'],
    ['-keeprwx', '-maskdigits', '-trace', '-bisect', '-inroutine', '-showoutput']);
  try
    if Index > ParamCount then
      raise Exception.Create('usage: -hits [-keeprwx] [-n <reps>] [-timeout <s>] [-maskdigits] [-inroutine] ' +
        '[-skip <rva,...>] [-bisect] [-floodlimit <n>] [-showoutput] [-trace] <exe> [args...]');
    var Exe := ExpandFileName(ParamStr(Index));
    var Args := RemainingArguments(Index + 1);
    var Repetitions := OptionInt(Options, '-n', 5);
    var KeepWritable := Options.ContainsKey('-keeprwx');
    var MaskDigits := Options.ContainsKey('-maskdigits');
    var IsWow64 := PeMachine(Exe) = MACHINE_I386;
    var CommandLine := BuildCommandLine(Exe, Args);

    var OutsideRoutines: Integer;
    var Rvas := LoadLineRvas(Exe, Options.ContainsKey('-inroutine'), OutsideRoutines);
    Writeln('ProbeCostProbe -hits');
    Writeln('machine : ', MachineDescription);
    Writeln('target  : ', Exe, '  (', BitnessName(IsWow64), ')');
    Writeln('args    : ', JoinArguments(Args));
    if KeepWritable then
      Writeln('variant : pages left PAGE_EXECUTE_READWRITE, one WriteProcessMemory per hit')
    else
      Writeln('variant : protect + write + protect + flush per hit (the engine''s WriteByte)');
    Writeln('line records (TD32, main module): ', Length(Rvas));
    if Options.ContainsKey('-inroutine') then
      Writeln('  left out, in no routine the TD32 reader knows: ', OutsideRoutines)
    else
      Writeln('  of which in no routine the TD32 reader knows: ', OutsideRoutines);
    if Length(Rvas) = 0 then
      raise Exception.Create('the target carries no TD32 line records; build it with -V');
    Writeln;

    var Skipped: string;
    if Options.TryGetValue('-skip', Skipped) then begin
      Rvas := WithoutRvas(Rvas, Skipped);
      Writeln('records left after -skip        : ', Length(Rvas));
    end;

    var RunWith: TFunc<Boolean, TArray<UInt64>, TRawDebugRun> :=
      function(Plant: Boolean; Records: TArray<UInt64>): TRawDebugRun
      begin
        Result := TRawDebugRun.Create;
        Result.Rvas         := Records;
        Result.Plant        := Plant;
        Result.KeepWritable := KeepWritable;
        Result.IsWow64      := IsWow64;
        Result.Trace        := Options.ContainsKey('-trace');
        Result.TimeoutMs    := Cardinal(OptionInt(Options, '-timeout', 120)) * 1000;
        Result.FloodLimit   := OptionInt(Options, '-floodlimit', Result.FloodLimit);
        Result.Execute(CommandLine);
      end;
    var Run: TFunc<Boolean, TRawDebugRun> := function(Plant: Boolean): TRawDebugRun
      begin
        Result := RunWith(Plant, Rvas);
      end;

    if Options.ContainsKey('-bisect') then begin
      var Reference := Run(False);
      var ReferenceExit := Reference.ExitCode;
      Reference.Free;
      BisectBreakingRecords(Exe, Rvas, function(Records: TArray<UInt64>): Boolean
        begin
          var Probed := RunWith(True, Records);
          try
            Result := Probed.TimedOut or Probed.Flooded or (Probed.ExitCode <> ReferenceExit);
          finally
            Probed.Free;
          end;
        end);
      Exit;
    end;

    // Not measured: it pays for the cold file cache.
    Run(False).Free;

    var BaselineMs, ProbedMs, PlantMs, HitCounts, PerHitUs, HandlerUs, RestoreUs, RewindUs, ContextReadUs, AllGaps: TArray<Double>;
    var ExitCodesAgree := True;
    var OutputsAgree := True;
    var MaskedOutputsAgree := True;
    var MemoryVerified := True;
    var Trouble := 0;
    Writeln(' rep  baseline ms  probed ms  plant ms  planted  pages    hits  stale  thr  exit base/probed  output   memory');
    for var Rep := 1 to Repetitions do begin
      var Baseline := Run(False);
      var Probed := Run(True);
      try
        var SameExit := (Baseline.ExitCode = Probed.ExitCode) and not (Baseline.TimedOut or Probed.TimedOut);
        var SameOutput := SameBytes(Baseline.Output, Probed.Output);
        var SameMasked := SameBytes(MaskDigitRuns(Baseline.Output), MaskDigitRuns(Probed.Output));
        var MemoryOk := Probed.VerifyDone and (Probed.VerifyMismatches = 0);
        ExitCodesAgree     := ExitCodesAgree and SameExit;
        OutputsAgree       := OutputsAgree and SameOutput;
        MaskedOutputsAgree := MaskedOutputsAgree and SameMasked;
        MemoryVerified     := MemoryVerified and MemoryOk;
        Inc(Trouble, Probed.ContextFailures + Probed.WriteFailures);

        var OutputNote := 'DIFFERS';
        if SameOutput then
          OutputNote := 'same'
        else if MaskDigits and SameMasked then
          OutputNote := 'same#';
        var MemoryNote := 'ok';
        if not Probed.VerifyDone then
          MemoryNote := 'unread'
        else if Probed.VerifyMismatches > 0 then
          MemoryNote := Format('%d BAD', [Probed.VerifyMismatches]);
        Writeln(Format('%4d  %11.2f  %9.2f  %8.2f  %7d  %5d  %6d  %5d  %3d  %6d / %-6d   %-7s  %s',
          [Rep, Baseline.WallMs, Probed.WallMs, Probed.PlantMs, Probed.Planted, Probed.PagesTouched, Probed.Hits,
           Probed.StaleHits, Probed.MaxThreads, Baseline.ExitCode, Probed.ExitCode, OutputNote, MemoryNote]));
        if Rep = 1 then begin
          Writeln(Format('      not planted: %d on a non-executable page, %d already an int3; ' +
            'other exceptions passed on: baseline %d, probed %d; output %d / %d bytes',
            [Probed.SkippedNotExecutable, Probed.SkippedAlreadyInt3, Baseline.OtherExceptions,
             Probed.OtherExceptions, Length(Baseline.Output), Length(Probed.Output)]));
        end;

        if (Rep = 1) and Options.ContainsKey('-showoutput') then begin
          Writeln('----- baseline output');
          Writeln(TEncoding.Default.GetString(Baseline.Output));
          Writeln('----- probed output');
          Writeln(TEncoding.Default.GetString(Probed.Output));
          Writeln('-----');
        end;
        BaselineMs := BaselineMs + [Baseline.WallMs];
        ProbedMs   := ProbedMs + [Probed.WallMs];
        PlantMs    := PlantMs + [Probed.PlantMs];
        HitCounts  := HitCounts + [Probed.Hits * 1.0];
        if Probed.Hits > 0 then begin
          PerHitUs  := PerHitUs + [(Probed.WallMs - Baseline.WallMs) * 1000 / Probed.Hits];
          HandlerUs := HandlerUs + [TicksToUs(Probed.HandlerTicks) / (Probed.Hits + Probed.StaleHits)];
          RestoreUs := RestoreUs + [TicksToUs(Probed.RestoreTicks) / (Probed.Hits + Probed.StaleHits)];
          RewindUs  := RewindUs + [TicksToUs(Probed.RewindTicks) / (Probed.Hits + Probed.StaleHits)];
          ContextReadUs := ContextReadUs + [TicksToUs(Probed.ContextReadTicks) / (Probed.Hits + Probed.StaleHits)];
        end;
        AllGaps := AllGaps + Probed.GapsUs;
      finally
        Baseline.Free;
        Probed.Free;
      end;
    end;

    var B := TSpread.From(BaselineMs);
    var P := TSpread.From(ProbedMs);
    var Planting := TSpread.From(PlantMs);
    var H := TSpread.From(HitCounts);
    var Cost := TSpread.From(PerHitUs);
    var Handler := TSpread.From(HandlerUs);
    var Gaps := TSpread.From(AllGaps);
    Writeln;
    Writeln(Format('baseline wall : median %.2f ms  (%.2f .. %.2f over %d repetitions)', [B.Median, B.Min, B.Max, B.Count]));
    Writeln(Format('probed wall   : median %.2f ms  (%.2f .. %.2f)', [P.Median, P.Min, P.Max]));
    Writeln(Format('planting      : median %.2f ms  (%.2f .. %.2f), included in the probed wall time', [Planting.Median, Planting.Min, Planting.Max]));
    Writeln(Format('hits          : median %.0f  (%.0f .. %.0f)', [H.Median, H.Min, H.Max]));
    if H.Median > 0 then begin
      Writeln(Format('(probed - baseline) / hits            : median %.1f us  (%.1f .. %.1f per repetition)',
        [Cost.Median, Cost.Min, Cost.Max]));
      Writeln(Format('(probed - planting - baseline) / hits : %.1f us  (from the medians)',
        [(P.Median - Planting.Median - B.Median) * 1000 / H.Median]));
      Writeln(Format('time between consecutive hits         : p10 %.1f us, median %.1f us, p90 %.1f us  (%d gaps)',
        [Gaps.P10, Gaps.Median, Gaps.P90, Gaps.Count]));
      Writeln(Format('  of which inside this tool''s handler : mean %.1f us per hit  (%.1f .. %.1f)',
        [Handler.Median, Handler.Min, Handler.Max]));
      Writeln(Format('    restoring the byte                : mean %.1f us per hit', [TSpread.From(RestoreUs).Median]));
      Writeln(Format('    rewinding the program counter     : mean %.1f us per hit, of which %.1f us reading the context',
        [TSpread.From(RewindUs).Median, TSpread.From(ContextReadUs).Median]));
    end;
    Writeln;
    Writeln('exit codes equal in every repetition    : ', BoolToStr(ExitCodesAgree, True));
    Writeln('output identical in every repetition    : ', BoolToStr(OutputsAgree, True));
    if MaskDigits then
      Writeln('output identical with digit runs masked : ', BoolToStr(MaskedOutputsAgree, True));
    Writeln('patched pages back to the original bytes: ', BoolToStr(MemoryVerified, True));
    Writeln('failed context or memory writes         : ', Trouble);
    if not (ExitCodesAgree and MemoryVerified and (Trouble = 0)) then
      ExitCode := 3;
  finally
    Options.Free;
  end;
end;

{ ------------------------------------------------------------------ -suspend -- }

type
  TSuspendSeries = record
    SuspendUs, ContextUs, ResumeUs, TotalUs, CycleDeltas: TArray<Double>;
    Count, Failures, RanBetween, PcChanged: Integer;
    LastCycles, LastPc: UInt64;
    LastThread: DWORD;
    procedure Add(Suspend, Context, Resume: Double);
  end;

  // Samples one busy and one idle thread of a running debuggee, from the debug
  // loop's own thread and between its events: where a sampler on the pump thread
  // would do it.
  TSuspendSampler = class
  private
    FRun:         TRawDebugRun;
    FContext:     PContext;
    FLastCycles:  TDictionary<DWORD, UInt64>;
    FBusyThread:  DWORD;
    FIdleThread:  DWORD;
    FLastPick:    UInt64;
    FWarmupUntil: UInt64;
    procedure PickThreads(Now: UInt64);
    procedure SampleThread(ThreadId: DWORD; var Series: TSuspendSeries);
  public
    Wanted:   Integer;
    WarmupMs: Cardinal;
    // SuspendThread instead of Wow64SuspendThread on a 32-bit target.
    NativeSuspend: Boolean;
    Busy:     TSuspendSeries;
    Idle:     TSuspendSeries;
    constructor Create(Run: TRawDebugRun);
    destructor  Destroy; override;
    procedure Tick;
  end;

procedure TSuspendSeries.Add(Suspend, Context, Resume: Double);
begin
  SuspendUs := SuspendUs + [Suspend];
  ContextUs := ContextUs + [Context];
  ResumeUs  := ResumeUs + [Resume];
  TotalUs   := TotalUs + [Suspend + Context + Resume];
  Inc(Count);
end;

constructor TSuspendSampler.Create(Run: TRawDebugRun);
begin
  inherited Create;
  FRun        := Run;
  FLastCycles := TDictionary<DWORD, UInt64>.Create;
  // A page of its own: GetThreadContext refuses a CONTEXT that is not 16-byte aligned.
  FContext    := VirtualAlloc(nil, SizeOf(TContext), MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
end;

destructor TSuspendSampler.Destroy;
begin
  VirtualFree(FContext, 0, MEM_RELEASE);
  FLastCycles.Free;
  inherited;
end;

procedure TSuspendSampler.PickThreads(Now: UInt64);
begin
  var BestDelta: UInt64 := 0;
  var Best: DWORD := 0;
  var Quiet: DWORD := 0;
  for var Pair in FRun.Threads do begin
    var Cycles: UInt64;
    if not QueryThreadCycleTime(Pair.Value, Cycles) then
      Continue;
    var Previous: UInt64;
    if FLastCycles.TryGetValue(Pair.Key, Previous) then begin
      var Delta := Cycles - Previous;
      if Delta > BestDelta then begin
        BestDelta := Delta;
        Best := Pair.Key;
      end;
      if Delta = 0 then
        Quiet := Pair.Key;
    end;
    FLastCycles.AddOrSetValue(Pair.Key, Cycles);
  end;
  if Best <> 0 then
    FBusyThread := Best;
  // Kept once chosen: its cycle counter is compared from one sample to the next.
  if (FIdleThread = 0) or not FRun.Threads.ContainsKey(FIdleThread) then
    FIdleThread := Quiet;
  FLastPick := Now;
end;

procedure TSuspendSampler.SampleThread(ThreadId: DWORD; var Series: TSuspendSeries);
var
  WowContext: TWow64Context;
begin
  var Thread := FRun.Threads[ThreadId];
  var Cycles: UInt64 := 0;
  QueryThreadCycleTime(Thread, Cycles);

  var T0 := QpcNow;
  var Previous: DWORD;
  if FRun.IsWow64 and not NativeSuspend then
    Previous := Wow64SuspendThread(Thread)
  else
    Previous := SuspendThread(Thread);
  var T1 := QpcNow;
  if Previous = DWORD(-1) then begin
    Inc(Series.Failures);
    Exit;
  end;
  var Read: Boolean;
  var Pc: UInt64;
  if FRun.IsWow64 then begin
    WowContext.ContextFlags := WOW64_CONTEXT_CONTROL or WOW64_CONTEXT_INTEGER;
    Read := Wow64GetThreadContext(Thread, WowContext);
    Pc := WowContext.Eip;
  end
  else begin
    FContext^.ContextFlags := CONTEXT_CONTROL or CONTEXT_INTEGER;
    Read := GetThreadContext(Thread, FContext^);
    Pc := FContext^.Rip;
  end;
  var T2 := QpcNow;
  ResumeThread(Thread);
  var T3 := QpcNow;
  if not Read then begin
    Inc(Series.Failures);
    Exit;
  end;

  // Compared only with the previous sample of the SAME thread.
  if (Series.Count > 0) and (Series.LastThread = ThreadId) then begin
    Series.CycleDeltas := Series.CycleDeltas + [(Cycles - Series.LastCycles) * 1.0];
    if Cycles <> Series.LastCycles then
      Inc(Series.RanBetween);
    if Pc <> Series.LastPc then
      Inc(Series.PcChanged);
  end;
  Series.LastCycles := Cycles;
  Series.LastPc := Pc;
  Series.LastThread := ThreadId;
  Series.Add(TicksToUs(T1 - T0), TicksToUs(T2 - T1), TicksToUs(T3 - T2));
end;

procedure TSuspendSampler.Tick;
begin
  if not FRun.LoaderBreakSeen then
    Exit;
  var Now := GetTickCount64;
  if FWarmupUntil = 0 then
    FWarmupUntil := Now + WarmupMs;
  if Now < FWarmupUntil then
    Exit;
  if Busy.Count >= Wanted then begin
    FRun.RequestStop;
    Exit;
  end;
  if (FBusyThread = 0) or (not FRun.Threads.ContainsKey(FBusyThread)) or (Now - FLastPick >= 100) then
    PickThreads(Now);
  if (FBusyThread = 0) or not FRun.Threads.ContainsKey(FBusyThread) then
    Exit;
  SampleThread(FBusyThread, Busy);
  if (FIdleThread <> 0) and (FIdleThread <> FBusyThread) and FRun.Threads.ContainsKey(FIdleThread) then
    SampleThread(FIdleThread, Idle);
end;

procedure ReportSuspendSeries(const Name: string; const Series: TSuspendSeries);
begin
  if Series.Count = 0 then begin
    Writeln(Format('%-12s no samples (failures: %d)', [Name, Series.Failures]));
    Exit;
  end;
  var S := TSpread.From(Series.SuspendUs);
  var C := TSpread.From(Series.ContextUs);
  var R := TSpread.From(Series.ResumeUs);
  var T := TSpread.From(Series.TotalUs);
  Writeln(Format('%-12s %5d samples, %d failed; ran since the previous sample: %d, PC changed: %d',
    [Name, Series.Count, Series.Failures, Series.RanBetween, Series.PcChanged]));
  Writeln(Format('  suspend    median %7.2f us   p10 %7.2f   p90 %7.2f   max %8.2f', [S.Median, S.P10, S.P90, S.Max]));
  Writeln(Format('  context    median %7.2f us   p10 %7.2f   p90 %7.2f   max %8.2f', [C.Median, C.P10, C.P90, C.Max]));
  Writeln(Format('  resume     median %7.2f us   p10 %7.2f   p90 %7.2f   max %8.2f', [R.Median, R.P10, R.P90, R.Max]));
  Writeln(Format('  all three  median %7.2f us   p10 %7.2f   p90 %7.2f   max %8.2f   mean %.2f',
    [T.Median, T.P10, T.P90, T.Max, T.Mean]));
  var D := TSpread.From(Series.CycleDeltas);
  Writeln(Format('  cycle counter since the previous sample: min %.0f, p10 %.0f, median %.0f, p90 %.0f, max %.0f cycles',
    [D.Min, D.P10, D.Median, D.P90, D.Max]));
end;

procedure RunSuspendMode;
begin
  var Index := 2;
  var Options := TakeOptions(Index, ['-n', '-warmup', '-timeout'], ['-nativesuspend']);
  try
    if Index > ParamCount then
      raise Exception.Create('usage: -suspend [-n <samples>] [-warmup <ms>] [-timeout <s>] [-nativesuspend] <exe> [args...]');
    var Exe := ExpandFileName(ParamStr(Index));
    var Args := RemainingArguments(Index + 1);
    Writeln('ProbeCostProbe -suspend');
    Writeln('machine : ', MachineDescription);

    var Run := TRawDebugRun.Create;
    var Sampler := TSuspendSampler.Create(Run);
    try
      Run.IsWow64   := PeMachine(Exe) = MACHINE_I386;
      Run.WaitMs    := 1;
      Run.TimeoutMs := Cardinal(OptionInt(Options, '-timeout', 60)) * 1000;
      Run.OnIdle    := Sampler.Tick;
      Sampler.Wanted   := OptionInt(Options, '-n', 1000);
      Sampler.WarmupMs := OptionInt(Options, '-warmup', 300);
      Sampler.NativeSuspend := Options.ContainsKey('-nativesuspend');
      if Run.IsWow64 and Sampler.NativeSuspend then
        Writeln('variant : SuspendThread instead of Wow64SuspendThread');
      Writeln('target  : ', Exe, '  (', BitnessName(Run.IsWow64), ')');
      Writeln('args    : ', JoinArguments(Args));
      Writeln;
      // Without it the 1 ms wait of the debug loop returns on 15.6 ms ticks.
      timeBeginPeriod(1);
      try
        Run.Execute(BuildCommandLine(Exe, Args));
      finally
        timeEndPeriod(1);
      end;
      Writeln(Format('target ran %.0f ms under the debug loop, %d threads at most', [Run.WallMs, Run.MaxThreads]));
      if Sampler.Busy.Count < Sampler.Wanted then
        Writeln('NOTE: the target ended before the requested number of samples');
      ReportSuspendSeries('busy thread', Sampler.Busy);
      ReportSuspendSeries('idle thread', Sampler.Idle);
    finally
      Sampler.Free;
      Run.Free;
    end;
  finally
    Options.Free;
  end;
end;

{ --------------------------------------------------------------------- -walk -- }

type
  // Reaches the engine's protected walk primitives without changing the engine.
  TEngineAccess = class(TWinDebugger);

var
  // A snapshot of the stopped thread's stack, read in one call, and the read
  // routine dbghelp is handed to walk it.
  GSnapshot:        TBytes;
  GSnapshotBase:    UInt64;
  GSnapshotLength:  UInt64;
  GReadCalls:       Integer;
  GReadsElsewhere:  Integer;
  GReadBytes:       Int64;
  GPageCache:       TDictionary<UInt64, TBytes>;

// Written without an addition that can wrap: the i386 walk asks for addresses a
// few bytes below 2^64.
function InSnapshot(Address: UInt64; Size: DWORD): Boolean;
begin
  if (Address < GSnapshotBase) or (Address - GSnapshotBase > GSnapshotLength) then
    Exit(False);
  Result := Size <= GSnapshotLength - (Address - GSnapshotBase);
end;

function SnapshotReadRoutine(hProcess: THandle; BaseAddress: UInt64; Buffer: Pointer; Size: DWORD;
  BytesRead: PDWORD): BOOL; stdcall;
begin
  Inc(GReadCalls);
  Inc(GReadBytes, Size);
  if InSnapshot(BaseAddress, Size) then begin
    Move(GSnapshot[BaseAddress - GSnapshotBase], Buffer^, Size);
    if BytesRead <> nil then
      BytesRead^ := Size;
    Exit(True);
  end;
  Inc(GReadsElsewhere);
  var Done: NativeUInt := 0;
  Result := ReadProcessMemory(hProcess, Pointer(BaseAddress), Buffer, Size, Done);
  if BytesRead <> nil then
    BytesRead^ := DWORD(Done);
end;

// As SnapshotReadRoutine, and what lies outside the stack (code, unwind data) is
// read a page at a time and kept: what is left is dbghelp's own work, with no
// system call per read.
function CachedReadRoutine(hProcess: THandle; BaseAddress: UInt64; Buffer: Pointer; Size: DWORD;
  BytesRead: PDWORD): BOOL; stdcall;
begin
  if InSnapshot(BaseAddress, Size) then begin
    Move(GSnapshot[BaseAddress - GSnapshotBase], Buffer^, Size);
    if BytesRead <> nil then
      BytesRead^ := Size;
    Exit(True);
  end;
  var Copied: DWORD := 0;
  while Copied < Size do begin
    var Address := BaseAddress + Copied;
    var PageVA := Address and not UInt64(PAGE_BYTES - 1);
    var Page: TBytes;
    if not GPageCache.TryGetValue(PageVA, Page) then begin
      SetLength(Page, PAGE_BYTES);
      var Done: NativeUInt := 0;
      if not ReadProcessMemory(hProcess, Pointer(PageVA), @Page[0], PAGE_BYTES, Done) or (Done <> PAGE_BYTES) then
        Page := nil;
      GPageCache.Add(PageVA, Page);
    end;
    if Page = nil then
      Break;
    var Chunk := DWORD(PageVA + PAGE_BYTES - Address);
    if Chunk > Size - Copied then
      Chunk := Size - Copied;
    Move(Page[Address - PageVA], (PByte(Buffer) + Copied)^, Chunk);
    Inc(Copied, Chunk);
  end;
  if BytesRead <> nil then
    BytesRead^ := Copied;
  Result := Copied = Size;
end;

// From the stack pointer to the end of the committed region it lies in, which is
// the base of the stack.
procedure SnapshotStack(Process: THandle; StackPointer: UInt64);
var
  Info: TMemoryBasicInformation;
  Done: NativeUInt;
begin
  GSnapshotLength := 0;
  if VirtualQueryEx(Process, Pointer(StackPointer), Info, SizeOf(Info)) = 0 then
    Exit;
  var Wanted := UInt64(NativeUInt(Info.BaseAddress)) + Info.RegionSize - StackPointer;
  if Wanted > UInt64(Length(GSnapshot)) then
    Wanted := Length(GSnapshot);
  if not ReadProcessMemory(Process, Pointer(StackPointer), @GSnapshot[0], Wanted, Done) then
    Exit;
  GSnapshotBase := StackPointer;
  GSnapshotLength := Done;
end;

function DirectStackWalk(Machine: DWORD; Process, Thread: THandle; Context: Pointer; Pc, Sp, Fp: UInt64;
  ReadRoutine: Pointer; MaxFrames: Integer): Integer;
var
  Frame: TWalkFrame;
begin
  Frame := Default(TWalkFrame);
  Frame.AddrPC.Offset    := Pc;
  Frame.AddrPC.Mode      := ADDRESS_MODE_FLAT;
  Frame.AddrFrame.Offset := Fp;
  Frame.AddrFrame.Mode   := ADDRESS_MODE_FLAT;
  Frame.AddrStack.Offset := Sp;
  Frame.AddrStack.Mode   := ADDRESS_MODE_FLAT;
  Result := 0;
  while StackWalk64(Machine, Process, Thread, Frame, Context, ReadRoutine, @SymFunctionTableAccess64,
      @SymGetModuleBase64, nil) do begin
    if Frame.AddrPC.Offset = 0 then
      Break;
    Inc(Result);
    if Result >= MaxFrames then
      Break;
  end;
end;

// The saved-EBP chain and nothing else: frame 0 is the thread's own PC, every
// further frame is one (saved EBP, return address) pair.
function BareEbpWalk(Process: THandle; Fp: UInt64; MaxFrames: Integer): Integer;
var
  Link: array[0..1] of UInt32;
  Done: NativeUInt;
begin
  Result := 1;
  var Current := Fp;
  while Result < MaxFrames do begin
    if not ReadProcessMemory(Process, Pointer(Current), @Link, SizeOf(Link), Done) or (Done <> SizeOf(Link)) then
      Break;
    if Link[1] = 0 then
      Break;
    Inc(Result);
    if (Link[0] <= Current) or ((Link[0] and 3) <> 0) then
      Break;
    Current := Link[0];
  end;
end;

function BareEbpWalkOverSnapshot(Fp: UInt64; MaxFrames: Integer): Integer;
begin
  Result := 1;
  var Current := Fp;
  while Result < MaxFrames do begin
    if (Current < GSnapshotBase) or (Current + 8 > GSnapshotBase + GSnapshotLength) then
      Break;
    var Link := PCardinal(@GSnapshot[Current - GSnapshotBase]);
    var Next: UInt64 := Link^;
    Inc(Link);
    if Link^ = 0 then
      Break;
    Inc(Result);
    if (Next <= Current) or ((Next and 3) <> 0) then
      Break;
    Current := Next;
  end;
end;

procedure ResolveLineSpec(const Spec: string; out SourcePath: string; out Line: Integer);
begin
  var Colon := Spec.LastIndexOf(':');
  if Colon <= 1 then
    raise Exception.Create('expected <source file>:<line or marker>, got ' + Spec);
  SourcePath := ExpandFileName(Spec.Substring(0, Colon));
  var Tail := Spec.Substring(Colon + 1);
  Line := StrToIntDef(Tail, 0);
  if Line > 0 then
    Exit;
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var Tag := '{BP:' + Tail + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then begin
        Line := I + 1;
        Exit;
      end;
  finally
    Lines.Free;
  end;
  raise Exception.CreateFmt('marker {BP:%s} not found in %s', [Tail, SourcePath]);
end;

procedure MeasureWalksAtStop(Session: TDebugSession; Walks, Rounds, MaxFrames: Integer; ShowFrames: Boolean);
begin
  // The engine's public answer first: it also initialises dbghelp for the process.
  var PublicFrames := Session.GetCallStack;
  var Engine := TEngineAccess(Session.Debugger as TObject);
  var Process := Engine.ProcessHandle;
  var Thread := Engine.ThreadHandle(Session.GetStoppedThreadId);
  var Is64 := Engine.TargetLayout.Is64Bit;
  var Machine: DWORD := MACHINE_AMD64;
  if not Is64 then
    Machine := MACHINE_I386;
  // A page of its own: a context captured by the closures below would otherwise
  // live in a heap frame whose alignment nobody guarantees.
  var Context := PContext(VirtualAlloc(nil, SizeOf(TContext), MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE));
  try
    var Pc, Sp, Fp: UInt64;
    if not Engine.FillStackWalkContext(Thread, Context^, Pc, Sp, Fp) then
      raise Exception.Create('the stopped thread''s context could not be read');
    SetLength(GSnapshot, 1024 * 1024);

    var Raw := Engine.WalkRawFrames(Thread, Pc, Sp, Fp, MaxFrames);
    var Origins := TDictionary<string, Integer>.Create;
    try
      for var Frame in Raw do begin
        var Name := GetEnumName(TypeInfo(TFrameOrigin), Ord(Frame.Origin));
        var Seen := 0;
        Origins.TryGetValue(Name, Seen);
        Origins.AddOrSetValue(Name, Seen + 1);
      end;
      Write(Format('raw depth %d frames (engine WalkRawFrames, MaxFrames %d); by origin:', [Length(Raw), MaxFrames]));
      for var Pair in Origins do
        Write(Format(' %s=%d', [Pair.Key, Pair.Value]));
      Writeln;
    finally
      Origins.Free;
    end;
    Writeln(Format('public GetCallStack: %d frames (capped by the engine, cached per stop)', [Length(PublicFrames)]));
    SnapshotStack(Process, Sp);
    Writeln(Format('stack in use: %d bytes from the stack pointer to the stack base', [GSnapshotLength]));
    if ShowFrames then
      for var I := 0 to High(Raw) do
        Writeln(Format('    #%-3d pc=%s fp=%s %s', [I, IntToHex(Raw[I].PC, 16), IntToHex(Raw[I].FramePtr, 16),
          GetEnumName(TypeInfo(TFrameOrigin), Ord(Raw[I].Origin))]));
    Writeln;

    var Measure: TProc<string, TFunc<Integer>> := procedure(Name: string; Body: TFunc<Integer>)
      begin
        var Frames := Body();
        var PerWalk: TArray<Double>;
        SetLength(PerWalk, Rounds);
        for var Round := 0 to Rounds - 1 do begin
          var Started := QpcNow;
          for var I := 1 to Walks do
            Body();
          PerWalk[Round] := TicksToUs(QpcNow - Started) / Walks;
        end;
        var S := TSpread.From(PerWalk);
        Writeln(Format('  %-50s %4d frames  %9.2f us/walk  (%.2f .. %.2f over %d rounds of %d)',
          [Name, Frames, S.Median, S.Min, S.Max, Rounds, Walks]));
      end;

    var ReadContext: TFunc<Integer> := function: Integer
      begin
        var P, S, F: UInt64;
        Engine.FillStackWalkContext(Thread, Context^, P, S, F);
        Result := 0;
      end;

    Measure('thread context only', ReadContext);
    Measure('engine WalkRawFrames', function: Integer
      begin
        Result := Length(Engine.WalkRawFrames(Thread, Pc, Sp, Fp, MaxFrames));
      end);
    Measure('StackWalk64 called directly, dbghelp reads', function: Integer
      begin
        ReadContext();
        Result := DirectStackWalk(Machine, Process, Thread, Context, Pc, Sp, Fp, nil, MaxFrames);
      end);
    Measure('StackWalk64 called directly, stack read once', function: Integer
      begin
        ReadContext();
        SnapshotStack(Process, Sp);
        Result := DirectStackWalk(Machine, Process, Thread, Context, Pc, Sp, Fp, @SnapshotReadRoutine, MaxFrames);
      end);
    GPageCache := TDictionary<UInt64, TBytes>.Create;
    try
      Measure('StackWalk64, stack read once, other pages cached', function: Integer
        begin
          ReadContext();
          SnapshotStack(Process, Sp);
          Result := DirectStackWalk(Machine, Process, Thread, Context, Pc, Sp, Fp, @CachedReadRoutine, MaxFrames);
        end);
      Writeln(Format('    (%d pages outside the stack were read once and kept)', [GPageCache.Count]));
    finally
      FreeAndNil(GPageCache);
    end;
    if not Is64 then begin
      Measure('bare EBP chain, one read per frame', function: Integer
        begin
          ReadContext();
          Result := BareEbpWalk(Process, Fp, MaxFrames);
        end);
      Measure('bare EBP chain, stack read once', function: Integer
        begin
          ReadContext();
          SnapshotStack(Process, Sp);
          Result := BareEbpWalkOverSnapshot(Fp, MaxFrames);
        end);
    end;

    // How many reads one dbghelp walk makes, and how many of them the single
    // stack read would have served.
    ReadContext();
    SnapshotStack(Process, Sp);
    GReadCalls := 0;
    GReadsElsewhere := 0;
    GReadBytes := 0;
    DirectStackWalk(Machine, Process, Thread, Context, Pc, Sp, Fp, @SnapshotReadRoutine, MaxFrames);
    Writeln(Format('  one dbghelp walk asks for memory %d times (%d bytes): %d inside the stack, %d elsewhere',
      [GReadCalls, GReadBytes, GReadCalls - GReadsElsewhere, GReadsElsewhere]));
  finally
    VirtualFree(Context, 0, MEM_RELEASE);
  end;
end;

procedure RunWalkMode;
begin
  var Index := 2;
  var Options := TakeOptions(Index, ['-n', '-rounds', '-maxframes', '-hit'], ['-frames']);
  try
    if Index + 1 > ParamCount then
      raise Exception.Create('usage: -walk [-n <walks>] [-rounds <r>] [-maxframes <m>] [-hit <k>] [-frames] ' +
        '<exe> <source:line|source:MARKER> [args...]');
    var Exe := ExpandFileName(ParamStr(Index));
    var SourcePath: string;
    var Line: Integer;
    ResolveLineSpec(ParamStr(Index + 1), SourcePath, Line);
    var Args := RemainingArguments(Index + 2);

    Writeln('ProbeCostProbe -walk');
    Writeln('machine : ', MachineDescription);
    Writeln('target  : ', Exe, '  (', BitnessName(PeMachine(Exe) = MACHINE_I386), ')');
    Writeln('args    : ', JoinArguments(Args));
    Writeln(Format('stop at : %s:%d', [SourcePath, Line]));

    var Session := TDebugSession.Create;
    try
      var Launch := Default(TLaunchOptions);
      Launch.ExePath    := Exe;
      Launch.SourceRoot := ExtractFileDir(SourcePath);
      Launch.Args       := JoinArguments(Args);
      if FileExists(ChangeFileExt(Exe, '.map')) then
        Launch.MapPath := ChangeFileExt(Exe, '.map');
      if FileExists(ChangeFileExt(Exe, '.rsm')) then
        Launch.RsmPath := ChangeFileExt(Exe, '.rsm');
      if not Session.Launch(Launch) then
        raise Exception.Create('launch failed');
      try
        var Spec := Default(TBpLineSpec);
        Spec.Line := Line;
        for var Bound in Session.SetBreakpoints(ExtractFileName(SourcePath), [Spec]) do
          Writeln(Format('breakpoint line %d verified=%s', [Bound.Line, BoolToStr(Bound.Verified, True)]));

        for var Stop := 1 to OptionInt(Options, '-hit', 1) do begin
          var Deadline := GetTickCount64 + 60000;
          if Stop > 1 then begin
            Session.ContinueExecution;
            // The state may still read dsStopped until the pump has run once.
            while (Session.State = dsStopped) and (not Session.HasExited) and (GetTickCount64 < Deadline) do
              Session.Pump;
          end;
          while (Session.State <> dsStopped) and (not Session.HasExited) and (GetTickCount64 < Deadline) do
            Session.Pump;
          if Session.HasExited or (Session.State <> dsStopped) then
            raise Exception.Create('the target did not stop at the breakpoint');
        end;

        var FunctionName, SourceFile: string;
        var StopLine: Integer;
        if Session.GetCurrentLocation(FunctionName, SourceFile, StopLine) then
          Writeln(Format('stopped in %s at %s:%d', [FunctionName, ExtractFileName(SourceFile), StopLine]));
        MeasureWalksAtStop(Session, OptionInt(Options, '-n', 1000), OptionInt(Options, '-rounds', 5),
          OptionInt(Options, '-maxframes', 512), Options.ContainsKey('-frames'));
      finally
        if not Session.HasExited then
          Session.Terminate;
      end;
    finally
      Session.Free;
    end;
  finally
    Options.Free;
  end;
end;

{ ------------------------------------------------------------------- -cycles -- }

type
  TTickSource = (tsHighResolutionTimer, tsDefaultSleep, tsDefaultBusyWait);
  TCounterColumn = (ccSpinCycles, ccSpinTimes, ccSleepCycles, ccSleepTimes);

  TCounterSample = record
    Tick:                    Int64;
    SpinCycles, SleepCycles: UInt64;
    SpinTimes, SleepTimes:   UInt64;   // kernel + user time, 100 ns units
  end;

function ThreadTimes(Thread: THandle): UInt64;
var
  Created, Exited, Kernel, User: TFileTime;
begin
  if not GetThreadTimes(Thread, Created, Exited, Kernel, User) then
    Exit(0);
  Result := UInt64(Kernel) + UInt64(User);
end;

function CollectCounterSamples(Spinner, Sleeper: THandle; Source: TTickSource; Seconds: Integer;
  BusyTickUs: Integer = 1000): TArray<TCounterSample>;
begin
  SetLength(Result, Seconds * 1200 + 1000);
  if Source = tsDefaultBusyWait then
    SetLength(Result, Int64(Seconds) * 1200000 div BusyTickUs + 1000);
  var Count := 0;
  var Timer: THandle := 0;
  if Source = tsHighResolutionTimer then begin
    timeBeginPeriod(1);
    Timer := CreateWaitableTimerEx(nil, nil, HIGH_RESOLUTION_TIMER, TIMER_FULL_ACCESS);
    if Timer = 0 then
      Timer := CreateWaitableTimer(nil, True, nil);
  end;
  try
    var TickLength := GQpcFrequency * BusyTickUs div 1000000;
    var Started := QpcNow;
    var Finish := Started + Int64(Seconds) * GQpcFrequency;
    var NextTick := Started;
    while (QpcNow < Finish) and (Count < Length(Result)) do begin
      case Source of
        tsHighResolutionTimer: begin
          var Due: TLargeInteger := -10000;   // 1 ms, relative
          SetWaitableTimer(Timer, Due, 0, nil, nil, False);
          WaitForSingleObject(Timer, INFINITE);
        end;
        tsDefaultSleep:
          Sleep(1);
        tsDefaultBusyWait: begin
          Inc(NextTick, TickLength);
          while QpcNow < NextTick do
            ;
        end;
      end;
      Result[Count].Tick := QpcNow;
      QueryThreadCycleTime(Spinner, Result[Count].SpinCycles);
      QueryThreadCycleTime(Sleeper, Result[Count].SleepCycles);
      Result[Count].SpinTimes  := ThreadTimes(Spinner);
      Result[Count].SleepTimes := ThreadTimes(Sleeper);
      Inc(Count);
    end;
  finally
    if Timer <> 0 then
      CloseHandle(Timer);
    if Source = tsHighResolutionTimer then
      timeEndPeriod(1);
  end;
  SetLength(Result, Count);
end;

// One counter read at every tick: how often it did not move, and by how much it
// moved when it did.
procedure ReportCounter(const Name: string; const Values: TArray<UInt64>; const IntervalsUs: TArray<Double>;
  const UnitName: string);
begin
  var Unchanged := 0;
  var LongestRun := 0;
  var Run := 0;
  var Deltas, Rates: TArray<Double>;
  SetLength(Deltas, Length(Values) - 1);
  SetLength(Rates, Length(Values) - 1);
  for var I := 1 to High(Values) do begin
    var Delta := Values[I] - Values[I - 1];
    Deltas[I - 1] := Delta;
    Rates[I - 1] := Delta / IntervalsUs[I - 1];
    if Delta = 0 then begin
      Inc(Unchanged);
      Inc(Run);
      if Run > LongestRun then
        LongestRun := Run;
    end
    else
      Run := 0;
  end;
  var D := TSpread.From(Deltas);
  var R := TSpread.From(Rates);
  Writeln(Format('  %-26s unchanged %5d of %5d readings (longest run %4d)   delta min %.0f  p10 %.0f  median %.0f  ' +
    'p90 %.0f  max %.0f %s   per us: p10 %.1f  median %.1f  p90 %.1f',
    [Name, Unchanged, Length(Deltas), LongestRun, D.Min, D.P10, D.Median, D.P90, D.Max, UnitName,
     R.P10, R.Median, R.P90]));
end;

function CounterColumn(const Samples: TArray<TCounterSample>; Column: TCounterColumn): TArray<UInt64>;
begin
  SetLength(Result, Length(Samples));
  for var I := 0 to High(Samples) do
    case Column of
      ccSpinCycles:  Result[I] := Samples[I].SpinCycles;
      ccSpinTimes:   Result[I] := Samples[I].SpinTimes;
      ccSleepCycles: Result[I] := Samples[I].SleepCycles;
      ccSleepTimes:  Result[I] := Samples[I].SleepTimes;
    end;
end;

procedure ReportCounterSamples(const Title: string; const Samples: TArray<TCounterSample>);
begin
  if Length(Samples) < 3 then begin
    Writeln(Title, ': too few samples');
    Exit;
  end;
  var Intervals: TArray<Double>;
  SetLength(Intervals, Length(Samples) - 1);
  for var I := 1 to High(Samples) do
    Intervals[I - 1] := TicksToUs(Samples[I].Tick - Samples[I - 1].Tick);
  var Interval := TSpread.From(Intervals);
  Writeln(Format('%s: %d readings, interval mean %.0f us, median %.0f us (min %.0f, p90 %.0f, max %.0f)',
    [Title, Length(Samples), Interval.Mean, Interval.Median, Interval.Min, Interval.P90, Interval.Max]));

  ReportCounter('spinning, cycle counter', CounterColumn(Samples, ccSpinCycles), Intervals, 'cycles');
  ReportCounter('spinning, GetThreadTimes', CounterColumn(Samples, ccSpinTimes), Intervals, 'x100ns');
  ReportCounter('blocked, cycle counter', CounterColumn(Samples, ccSleepCycles), Intervals, 'cycles');
  ReportCounter('blocked, GetThreadTimes', CounterColumn(Samples, ccSleepTimes), Intervals, 'x100ns');
  Writeln;
end;

function ReadLineFromPipe(Pipe: THandle): string;
begin
  Result := '';
  while True do begin
    var Ch: AnsiChar;
    var Done: DWORD := 0;
    if not ReadFile(Pipe, Ch, 1, Done, nil) or (Done = 0) or (Ch = #10) then
      Exit;
    if Ch <> #13 then
      Result := Result + Char(Ch);
  end;
end;

function FieldOf(const Line, Name: string): DWORD;
begin
  Result := 0;
  for var Part in Line.Split([' ']) do
    if Part.StartsWith(Name + '=') then
      Result := DWORD(StrToInt64Def(Part.Substring(Length(Name) + 1), 0));
end;

procedure RunCyclesMode;
begin
  var Index := 2;
  var Options := TakeOptions(Index, ['-seconds', '-mycore', '-spincore', '-finetick'], []);
  try
    var Seconds := OptionInt(Options, '-seconds', 3);
    var DefaultMine := 0;
    var DefaultSpin := CPUCount - 1;
    if CPUCount >= 8 then begin
      // Two logical processors apart: not the two halves of one core.
      DefaultMine := 2;
      DefaultSpin := 6;
    end;
    var MyCore := OptionInt(Options, '-mycore', DefaultMine);
    var SpinCore := OptionInt(Options, '-spincore', DefaultSpin);
    Writeln('ProbeCostProbe -cycles');
    Writeln('machine : ', MachineDescription);
    Writeln(Format('reader pinned to logical processor %d, spinning thread to %d, %d s per series', [MyCore, SpinCore, Seconds]));
    Writeln;

    var Security := InheritableSecurity;
    var PipeRead, PipeWrite: THandle;
    if not CreatePipe(PipeRead, PipeWrite, @Security, 0) then
      RaiseLastOSError;
    SetHandleInformation(PipeRead, HANDLE_FLAG_INHERIT, 0);
    var NulInput := OpenNulForChild;
    var Child: TProcessInformation;
    try
      Child := LaunchWithStdHandles(BuildCommandLine(ParamStr(0),
        ['-spin', IntToHex(UInt64(1) shl SpinCore, 1), IntToStr(Seconds * 4 + 30)]), NulInput, PipeWrite, 0);
    finally
      CloseHandle(PipeWrite);
      CloseHandle(NulInput);
    end;
    try
      CloseHandle(Child.hThread);
      var Hello := ReadLineFromPipe(PipeRead);
      var Spinner := OpenThreadById(THREAD_QUERY_ACCESS, False, FieldOf(Hello, 'spin'));
      var Sleeper := OpenThreadById(THREAD_QUERY_ACCESS, False, FieldOf(Hello, 'sleep'));
      if (Spinner = 0) or (Sleeper = 0) then
        raise Exception.Create('the child''s threads could not be opened: "' + Hello + '"');
      try
        SetThreadAffinityMask(GetCurrentThread, NativeUInt(1) shl MyCore);
        Sleep(300);
        ReportCounterSamples('1 ms high-resolution timer, timeBeginPeriod(1)',
          CollectCounterSamples(Spinner, Sleeper, tsHighResolutionTimer, Seconds));
        Sleep(300);
        ReportCounterSamples('default timer resolution, Sleep(1)',
          CollectCounterSamples(Spinner, Sleeper, tsDefaultSleep, Seconds));
        ReportCounterSamples('default timer resolution, 1 ms busy wait',
          CollectCounterSamples(Spinner, Sleeper, tsDefaultBusyWait, Seconds));
        // Far below any clock interrupt period: a counter that only moved at interrupts
        // would show runs of unchanged readings here.
        var FineTickUs := OptionInt(Options, '-finetick', 50);
        ReportCounterSamples(Format('default timer resolution, %d us busy wait', [FineTickUs]),
          CollectCounterSamples(Spinner, Sleeper, tsDefaultBusyWait, Seconds, FineTickUs));
      finally
        CloseHandle(Spinner);
        CloseHandle(Sleeper);
      end;
    finally
      TerminateProcess(Child.hProcess, 0);
      WaitForSingleObject(Child.hProcess, 10000);
      CloseHandle(Child.hProcess);
      CloseHandle(PipeRead);
    end;
  finally
    Options.Free;
  end;
end;

procedure RunProbe;
begin
  QueryPerformanceFrequency(GQpcFrequency);
  // The figures are pasted into documents: one decimal separator on every machine.
  FormatSettings.DecimalSeparator := '.';
  var Mode := LowerCase(ParamStr(1));
  if Mode = '-hits' then
    RunHitsMode
  else if Mode = '-walk' then
    RunWalkMode
  else if Mode = '-suspend' then
    RunSuspendMode
  else if Mode = '-cycles' then
    RunCyclesMode
  else begin
    Writeln('usage:');
    Writeln('  ProbeCostProbe -hits [-keeprwx] [-n <reps>] [-timeout <s>] [-maskdigits] [-inroutine] [-skip <rva,...>]');
    Writeln('                 [-bisect] [-floodlimit <n>] [-showoutput] [-trace] <exe> [args...]');
    Writeln('  ProbeCostProbe -walk [-n <walks>] [-rounds <r>] [-maxframes <m>] [-hit <k>] [-frames]');
    Writeln('                 <exe> <source:line|source:MARKER> [args...]');
    Writeln('  ProbeCostProbe -suspend [-n <samples>] [-warmup <ms>] [-timeout <s>] [-nativesuspend] <exe> [args...]');
    Writeln('  ProbeCostProbe -cycles [-seconds <s>] [-mycore <n>] [-spincore <n>] [-finetick <us>]');
    Writeln('  ProbeCostProbe -recurse <depth> | -spin <maskhex> <seconds>     (the built-in targets)');
    ExitCode := 2;
  end;
end;
{$ENDIF}

begin
  if RunBuiltInTarget then
    Exit;
{$IFDEF CPUX64}
  try
    RunProbe;
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 9;
    end;
  end;
{$ELSE}
  Writeln('The 32-bit build of ProbeCostProbe is a debuggee only: -recurse <depth> | -spin <maskhex> <seconds>');
  ExitCode := 2;
{$ENDIF}
end.
