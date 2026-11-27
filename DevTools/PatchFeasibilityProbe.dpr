program PatchFeasibilityProbe;

// Hand-built code patches in a live debuggee, to settle whether the line probes
// of docs\PROFILER_COVERAGE_PLAN.md are feasible as designed ("Increment 1",
// assumptions 6, 7, 14 and 16). No engine: a raw Windows debug loop, memory
// allocated in the target with VirtualAllocEx and trampolines written by hand.
//
// Every experiment runs the fixture PLAIN first, under the same debug loop, and
// records its transcript (the fixture's "PF: ..." OutputDebugString lines and
// its exit code). A patched run "behaves as plain" exactly when its transcript
// and exit code are equal to that reference. A run that crashes or loops is an
// expected outcome of some experiments: every run has a timeout and a limit on
// the number of exceptions, the debuggee is killed and waited for, and the
// events that led there are printed.
//
//   E1  a patch AT a return address, the callee raising (assumption 14, shape 1)
//   E2  a patch in an epilogue that starts at a return address (shape 2)
//   E3  a fault in a trampoline sent back to the original instruction, and a
//       fault in the payload sent back to the site (assumption 6)
//   E4  a direct call retargeted through a counting trampoline (assumption 7);
//       as a contrast, a trampoline that CALLS the callee instead of jumping to it
//   E5  a six-byte indirect call re-encoded as a five-byte call and a nop, in
//       both orders
//   E6  dbghelp's StackWalk64 over a patched return address (a jump, the call
//       form, a $CC), with no read routine, with one that serves memory as it
//       is, and with one that serves the original bytes (assumption 16)
//   E7  the program hooks its own routine after it was patched
//
// The forms, as written here:
//
//   jump       site: E9 rel32 (+ 90 padding)
//              trampoline: lock inc [counter]; displaced instructions; jmp back
//   call form  site: E8 rel32 (+ 90 padding)
//              trampoline: mov [rsp], <next instruction>; ret; lock inc [counter];
//              displaced instructions; jmp back. The pushed address is consumed
//              by a ret, so calls and returns stay paired for the processor's
//              return prediction; no register and no flag is touched.
//   one-shot   site: CC; on the hit the byte is restored and the thread rewound
//
// A displaced instruction is copied; on x64 one that has a RIP-relative operand
// gets its displacement rewritten, and the result is accepted only when Zydis
// decodes it, at its new address, to the text of the original. A relative
// branch in a span is refused (the fixture has none).
//
// A fault whose address is in a trampoline is "sent back" when the variant asks
// for it: the site gets its bytes back (compared first), the thread's program
// counter is set to the address the faulting instruction was compiled at, or to
// the site when the payload faulted (with the stack pointer the payload found),
// and the event is continued with DBG_CONTINUE.
//
// The addresses come from the fixture's TD32 line table through the {BP:NAME}
// markers of its source, read with the engine's own TTD32FileReader; the code at
// each of them is decoded with Zydis out of the live process and an experiment
// REFUSES to run, saying why, when the bytes are not the shape it needs. The
// marker names are those of DevTools\Fixtures\TrampolineFixture.dpr, which was
// written for these experiments; every path comes from the command line.
//
// Usage:
//   PatchFeasibilityProbe [-only e1,e3,...] [-timeout <s>] [-floodlimit <n>]
//                         [-src <fixture.dpr>] [-zydisdll <path>]
//                         <fixture.exe> [<fixture.exe> ...]
//
//   -only        run the listed experiments only (e1 .. e7)
//   -timeout     seconds one launch may take before it is killed (default 15)
//   -floodlimit  exceptions one launch may produce before it is killed (default 300)
//   -src         the fixture's source; default: <exe name>.dpr in the directory
//                of the executable or one of its three parents
//
// Each fixture given is driven in turn, whatever its bitness; the tables at the
// end have one row per experiment variant and bitness.

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

uses
  System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, System.Math,
  System.Generics.Collections, System.Win.Registry,
  Winapi.Windows,
  ZydisApi       in '..\DebuggerCore\ZydisApi.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas';

{ ----------------------------------------------------------------- bindings -- }

const
  STATUS_WX86_BREAKPOINT  = DWORD($4000001F);
  STATUS_WX86_SINGLE_STEP = DWORD($4000001E);
  DELPHI_EXCEPTION_CODE   = DWORD($0EEDFADE);
  HANDLE_LIST_ATTRIBUTE   = $00020002;   // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
  MACHINE_I386            = $014C;
  MACHINE_AMD64           = $8664;
  ADDRESS_MODE_FLAT       = 3;
  SYMOPT_DEFERRED_LOADS   = $00000004;
  SYMOPT_FAIL_CRITICAL    = $00000200;
  SYMOPT_NO_PROMPTS       = $00080000;
  EXECUTABLE_PROTECTIONS  = PAGE_EXECUTE or PAGE_EXECUTE_READ or PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_WRITECOPY;
  KILLED_EXIT_CODE        = $DEAD;
  ARENA_BYTES             = $10000;
  ARENA_DATA_OFFSET       = $8000;       // counters live in the second half of the arena
  NEAR_REACH              = $70000000;   // how far from the image a rel32 is trusted to reach
  MAX_WALK_FRAMES         = 40;

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
function SymInitializeW(hProcess: THandle; UserSearchPath: PWideChar; fInvadeProcess: BOOL): BOOL; stdcall;
  external 'dbghelp.dll';
function SymCleanup(hProcess: THandle): BOOL; stdcall; external 'dbghelp.dll';
function SymSetOptions(SymOptions: DWORD): DWORD; stdcall; external 'dbghelp.dll';

{ ------------------------------------------------------------------ helpers -- }

type
  // The compiled bytes are not the shape an experiment needs. Never a failure of
  // the probe: the variant is reported as not run, with this message.
  ERefused = class(Exception);

function HexBytes(const Bytes: TBytes): string;
begin
  Result := '';
  for var I := 0 to High(Bytes) do begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + IntToHex(Bytes[I], 2);
  end;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function Mnemonic(const Text: string): string;
begin
  var Space := Text.IndexOf(' ');
  if Space < 0 then
    Result := Text
  else
    Result := Text.Substring(0, Space);
end;

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
  Result := Format('%s, %d logical processors, Windows build %s', [Cpu, CPUCount, Build]);
end;

function ResolveZydisDll(const OverridePath: string): string;
begin
  if OverridePath <> '' then
    Exit(OverridePath);
  var Dir := ExtractFileDir(ParamStr(0));
  Result := TPath.Combine(Dir, 'Zydis.dll');
  if FileExists(Result) then
    Exit;
  for var Up := 1 to 6 do begin
    Dir := ExtractFileDir(Dir);
    if Dir = '' then
      Break;
    Result := TPath.Combine(Dir, 'ThirdParty\Zydis\bin\x64\Zydis.dll');
    if FileExists(Result) then
      Exit;
  end;
  Result := '';
end;

{ ------------------------------------------------------------ child processes -- }

function OpenNulForChild: THandle;
begin
  var Security := Default(TSecurityAttributes);
  Security.nLength        := SizeOf(Security);
  Security.bInheritHandle := True;
  Result := CreateFile('NUL', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, @Security,
    OPEN_EXISTING, 0, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

// A child never inherits this tool's standard handles: it gets the one handle
// passed here for all three and nothing else.
function LaunchDebuggee(const CommandLine: string; StdHandle: THandle): TProcessInformation;
begin
  var ListSize: NativeUInt := 0;
  InitializeProcThreadAttributeList(nil, 1, 0, ListSize);
  var ListBuffer: TBytes;
  SetLength(ListBuffer, ListSize);
  var List := PProcThreadAttributeList(@ListBuffer[0]);
  if not InitializeProcThreadAttributeList(List, 1, 0, ListSize) then
    RaiseLastOSError;
  try
    var Inherited_: array[0..0] of THandle;
    Inherited_[0] := StdHandle;
    if not UpdateProcThreadAttribute(List, 0, HANDLE_LIST_ATTRIBUTE, @Inherited_[0], SizeOf(Inherited_), nil,
         PNativeUInt(nil)^) then
      RaiseLastOSError;
    var Startup := Default(TStartupInfoWithAttributes);
    Startup.StartupInfo.cb         := SizeOf(Startup);
    Startup.StartupInfo.dwFlags    := STARTF_USESTDHANDLES;
    Startup.StartupInfo.hStdInput  := StdHandle;
    Startup.StartupInfo.hStdOutput := StdHandle;
    Startup.StartupInfo.hStdError  := StdHandle;
    Startup.AttributeList          := List;
    var Writable := CommandLine;
    UniqueString(Writable);
    if not CreateProcess(nil, PChar(Writable), nil, nil, True,
         DEBUG_ONLY_THIS_PROCESS or EXTENDED_STARTUPINFO_PRESENT, nil, nil, Startup.StartupInfo, Result) then
      RaiseLastOSError;
  finally
    DeleteProcThreadAttributeList(List);
  end;
end;

{ ------------------------------------------------------------------ fixture -- }

type
  // One fixture executable: its line table and the addresses of its markers.
  TFixture = class
  private
    FReader:  TTD32FileReader;
    FMarkers: TDictionary<string, UInt64>;
    procedure LoadMarkers;
  public
    ExePath:    string;
    SourcePath: string;
    IsWow64:    Boolean;
    constructor Create(const AExePath, ASourcePath: string);
    destructor  Destroy; override;
    function Marker(const Name: string): UInt64;
    function Bitness: string;
    function FunctionAt(Rva: UInt64): string;
  end;

constructor TFixture.Create(const AExePath, ASourcePath: string);
begin
  inherited Create;
  ExePath := ExpandFileName(AExePath);
  if not FileExists(ExePath) then
    raise Exception.Create('fixture not found: ' + ExePath);
  var Machine := PeMachine(ExePath);
  if (Machine <> MACHINE_I386) and (Machine <> MACHINE_AMD64) then
    raise Exception.CreateFmt('unsupported machine $%x: %s', [Machine, ExePath]);
  IsWow64 := Machine = MACHINE_I386;

  SourcePath := ASourcePath;
  if SourcePath = '' then begin
    var Dir := ExtractFileDir(ExePath);
    var Name := ChangeFileExt(ExtractFileName(ExePath), '.dpr');
    for var Up := 0 to 3 do begin
      if FileExists(TPath.Combine(Dir, Name)) then begin
        SourcePath := TPath.Combine(Dir, Name);
        Break;
      end;
      Dir := ExtractFileDir(Dir);
    end;
  end;
  if (SourcePath = '') or not FileExists(SourcePath) then
    raise Exception.Create('source of the fixture not found (use -src): ' + ExePath);

  FReader := TTD32FileReader.Create;
  FReader.LoadFromFile(ExePath);
  if not FReader.Loaded then
    raise Exception.Create('no TD32 debug information in ' + ExePath);
  FMarkers := TDictionary<string, UInt64>.Create;
  LoadMarkers;
end;

destructor TFixture.Destroy;
begin
  FMarkers.Free;
  FReader.Free;
  inherited;
end;

procedure TFixture.LoadMarkers;
begin
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var SourceName := ExtractFileName(SourcePath);
    for var I := 0 to Lines.Count - 1 do begin
      var Open := Lines[I].IndexOf('{BP:');
      if Open < 0 then
        Continue;
      var Close := Lines[I].IndexOf('}', Open);
      if Close < 0 then
        Continue;
      var Name := Lines[I].Substring(Open + 4, Close - Open - 4);
      var Rva: UInt64;
      if FReader.SourceLineToRva(SourceName, I + 1, Rva) then
        FMarkers.AddOrSetValue(Name, Rva);
    end;
  finally
    Lines.Free;
  end;
end;

function TFixture.Marker(const Name: string): UInt64;
begin
  if not FMarkers.TryGetValue(Name, Result) then
    raise ERefused.CreateFmt('marker {BP:%s} has no line record in %s', [Name, ExtractFileName(ExePath)]);
end;

function TFixture.Bitness: string;
begin
  if IsWow64 then
    Result := 'x86'
  else
    Result := 'x64';
end;

function TFixture.FunctionAt(Rva: UInt64): string;
begin
  var Name: string;
  var Start: UInt64;
  if not FReader.RvaToFunctionName(Rva, Name) or not FReader.RvaToFunctionStart(Rva, Start) then
    Exit('');
  Result := Format('%s+%x', [Name, Rva - Start]);
end;

{ ------------------------------------------------------------------ session -- }

type
  TInsn = record
    Address: UInt64;
    Bytes:   TBytes;
    Text:    string;
    function Size: Integer;
    function NextAddress: UInt64;
    function IsDirectCall: Boolean;
    function IsIndirectCallThroughMemory: Boolean;
    function IsReturn: Boolean;
    function TransfersControl: Boolean;
  end;

  TRelocatedInsn = record
    Offset:   Integer;   // in the trampoline
    Size:     Integer;
    Original: UInt64;    // address the instruction was compiled at
    Text:     string;
  end;

  TPayload = (pkCount, pkFaultThenCount);

  // Everything written into the target for one probe.
  TPatch = class
    Name:           string;
    Form:           string;
    Site:           UInt64;
    Original:       TBytes;
    Patched:        TBytes;
    AtExit:         TBytes;     // the site's bytes when the process ended
    Trampoline:     UInt64;
    TrampolineSize: Integer;
    PayloadStart:   Integer;    // trampoline offsets
    PayloadEnd:     Integer;
    FlagsPushedFrom, FlagsPushedTo: Integer;   // offsets at which the payload has the flags on the stack
    Relocated:      TArray<TRelocatedInsn>;
    Counter:        UInt64;
    CounterAtExit:  Int64;
    Withdrawn:      Boolean;
    constructor Create;
  end;

  TBreakKind = (bkOneShot, bkStop);

  TBreakpoint = class
    Name:     string;
    Address:  UInt64;
    Original: Byte;
    Kind:     TBreakKind;
    Hits:     Integer;
    AtExit:   Byte;
    OnStop:   TProc<DWORD>;
  end;

  TModule = record
    Base, Size: UInt64;
    Name:       string;
  end;

  TControlRegisters = record
    Pc, Sp, Flags: UInt64;
  end;

  TFaultPolicy = (fpPassOn, fpSendBack);

  // One launch of the fixture under DEBUG_ONLY_THIS_PROCESS.
  TSession = class
  private
    FThreads:      TDictionary<DWORD, THandle>;
    FModules:      TList<TModule>;
    FBreaks:       TObjectDictionary<UInt64, TBreakpoint>;
    FArena:        UInt64;
    FArenaNext:    UInt64;
    FCounterNext:  UInt64;
    FNativeLoaderBreakSeen, FWowLoaderBreakSeen, FAttached, FKilled: Boolean;
    FExceptions:   Integer;
    function  HandleException(const Event: TDebugEvent): DWORD;
    function  HandleBreakpoint(ThreadId: DWORD; Address: UInt64; IsWowBreak: Boolean): DWORD;
    procedure HandleDebugString(const Event: TDebugEvent);
    procedure NoteModule(Base: UInt64; FileHandle: THandle; const Fallback: string);
    procedure SnapshotAtExit;
    function  TrySendBack(ThreadId: DWORD; FaultAddress: UInt64): Boolean;
    function  FindPatchByTrampoline(Address: UInt64): TPatch;
    procedure EnsureArena;
    function  NewCounter: UInt64;
    procedure EmitPayload(var Code: TBytes; Base: UInt64; Patch: TPatch; Payload: TPayload);
    procedure EmitRelocated(var Code: TBytes; Base: UInt64; Patch: TPatch; const Insn: TInsn);
    procedure EmitJump(var Code: TBytes; Base, Target: UInt64);
    function  PlaceTrampoline(const Code: TBytes): UInt64;
    function  RegionDescription(Address: UInt64): string;
  public
    Fixture:      TFixture;
    Args:         TArray<string>;
    TimeoutMs:    Cardinal;
    FloodLimit:   Integer;
    FaultPolicy:  TFaultPolicy;
    OnAttach:     TProc;
    // Results.
    Process:      THandle;
    ImageBase:    UInt64;
    ImageSize:    UInt64;
    Transcript:   TStringList;   // "PF: " lines, the reference for "behaves as plain"
    Info:         TStringList;   // "PFI: " lines
    Log:          TStringList;   // every event, in order
    Notes:        TStringList;   // what was patched, with bytes
    Patches:      TObjectList<TPatch>;
    ExitCode:     DWORD;
    Exited, TimedOut, Flooded, SecondChance: Boolean;
    SecondChanceText, Refusal, KillReason: string;
    ForeignBreakpoints: Integer;
    constructor Create(AFixture: TFixture; const AArgs: TArray<string>);
    destructor  Destroy; override;
    procedure Run;
    procedure Kill(const Reason: string);
    function  EndedNormally: Boolean;
    function  Outcome: string;
    // Memory and code.
    function  IsWow64: Boolean;
    function  PointerBytes: Integer;
    function  ReadBytes(Address: UInt64; Count: Integer): TBytes;
    function  TryReadBytes(Address: UInt64; Count: Integer; out Bytes: TBytes): Boolean;
    procedure WriteCode(Address: UInt64; const Bytes: TBytes);
    function  Decode(Address: UInt64): TInsn;
    function  DecodeBytesAt(Address: UInt64; const Bytes: TBytes; Offset: Integer): TInsn;
    function  DecodeSpan(Site: UInt64; MinBytes: Integer; ThroughReturn: Boolean): TArray<TInsn>;
    function  Listing(Address: UInt64; Count: Integer): TArray<string>;
    function  Describe(Address: UInt64): string;
    function  Va(Rva: UInt64): UInt64;
    function  ReturnAddressOfCallOnLine(const CallMarker: string; out Call: TInsn): UInt64;
    function  FirstInsnOnLine(const LineMarker: string; Matches: TFunc<TInsn, Boolean>; const What: string): TInsn;
    // Threads.
    function  ThreadHandle(ThreadId: DWORD): THandle;
    function  ReadControl(ThreadId: DWORD; out Registers: TControlRegisters): Boolean;
    function  WriteControl(ThreadId: DWORD; const Registers: TControlRegisters): Boolean;
    // Patches.
    function  InstallJump(const Name: string; Site: UInt64; Payload: TPayload; ThroughReturn: Boolean): TPatch;
    function  InstallCallForm(const Name: string; Site: UInt64; ThroughReturn: Boolean): TPatch;
    function  RetargetCall(const Name: string; const Call: TInsn; CallThrough: Boolean): TPatch;
    function  ReencodeIndirectCall(const Name: string; const Call: TInsn; NopFirst: Boolean): TPatch;
    function  InstallBreakpoint(const Name: string; Address: UInt64; Kind: TBreakKind; OnStop: TProc<DWORD>): TBreakpoint;
    function  Breakpoints: TArray<TBreakpoint>;
  end;

{ TInsn }

function TInsn.Size: Integer;
begin
  Result := Length(Bytes);
end;

function TInsn.NextAddress: UInt64;
begin
  Result := Address + UInt64(Length(Bytes));
end;

function TInsn.IsDirectCall: Boolean;
begin
  Result := (Length(Bytes) = 5) and (Bytes[0] = $E8);
end;

function TInsn.IsIndirectCallThroughMemory: Boolean;
begin
  Result := (Length(Bytes) = 6) and (Bytes[0] = $FF) and (Bytes[1] = $15);
end;

function TInsn.IsReturn: Boolean;
begin
  Result := Mnemonic(Text) = 'ret';
end;

function TInsn.TransfersControl: Boolean;
begin
  var Name := Mnemonic(Text);
  Result := (Name = 'call') or (Name = 'ret') or (Name = 'int3') or Name.StartsWith('j') or Name.StartsWith('loop');
end;

{ TPatch }

constructor TPatch.Create;
begin
  inherited Create;
  PayloadStart    := -1;
  PayloadEnd      := -1;
  FlagsPushedFrom := -1;
  FlagsPushedTo   := -1;
  CounterAtExit   := -1;
end;

{ TSession }

constructor TSession.Create(AFixture: TFixture; const AArgs: TArray<string>);
begin
  inherited Create;
  Fixture    := AFixture;
  Args       := AArgs;
  TimeoutMs  := 15000;
  FloodLimit := 300;
  FThreads   := TDictionary<DWORD, THandle>.Create;
  FModules   := TList<TModule>.Create;
  FBreaks    := TObjectDictionary<UInt64, TBreakpoint>.Create([doOwnsValues]);
  Transcript := TStringList.Create;
  Info       := TStringList.Create;
  Log        := TStringList.Create;
  Notes      := TStringList.Create;
  Patches    := TObjectList<TPatch>.Create(True);
end;

destructor TSession.Destroy;
begin
  Patches.Free;
  Notes.Free;
  Log.Free;
  Info.Free;
  Transcript.Free;
  FBreaks.Free;
  FModules.Free;
  FThreads.Free;
  inherited;
end;

function TSession.IsWow64: Boolean;
begin
  Result := Fixture.IsWow64;
end;

function TSession.PointerBytes: Integer;
begin
  if IsWow64 then
    Result := 4
  else
    Result := 8;
end;

function TSession.Va(Rva: UInt64): UInt64;
begin
  Result := ImageBase + Rva;
end;

function TSession.EndedNormally: Boolean;
begin
  Result := Exited and not (TimedOut or Flooded or SecondChance or FKilled) and (Refusal = '');
end;

function TSession.Outcome: string;
begin
  if Refusal <> '' then
    Exit('not run: ' + Refusal);
  if SecondChance then
    Exit('process killed by an unhandled exception: ' + SecondChanceText);
  if TimedOut then
    Exit(Format('KILLED by the probe: still running after %d s', [TimeoutMs div 1000]));
  if Flooded then
    Exit(Format('KILLED by the probe: more than %d exceptions', [FloodLimit]));
  if FKilled then
    Exit('ended by the probe: ' + KillReason);
  if not Exited then
    Exit('no exit event');
  Result := Format('exit code %d', [ExitCode]);
end;

procedure TSession.Kill(const Reason: string);
begin
  if FKilled then
    Exit;
  FKilled    := True;
  KillReason := Reason;
  TerminateProcess(Process, KILLED_EXIT_CODE);
end;

procedure TSession.Run;
var
  Event: TDebugEvent;
begin
  var Nul := OpenNulForChild;
  try
    var ProcessInfo := LaunchDebuggee(BuildCommandLine(Fixture.ExePath, Args), Nul);
    CloseHandle(ProcessInfo.hThread);
    Process := ProcessInfo.hProcess;
    try
      var Deadline := GetTickCount64 + TimeoutMs;
      while True do begin
        // Checked on every turn: a target that floods the loop with events never
        // lets the wait time out.
        if (not TimedOut) and (GetTickCount64 > Deadline) then begin
          TimedOut := True;
          Log.Add('probe: timeout, terminating the debuggee');
          TerminateProcess(Process, KILLED_EXIT_CODE);
        end;
        if not WaitForDebugEvent(Event, 100) then
          Continue;
        var Status: DWORD := DBG_CONTINUE;
        case Event.dwDebugEventCode of
          CREATE_PROCESS_DEBUG_EVENT: begin
            ImageBase := UInt64(NativeUInt(Event.CreateProcessInfo.lpBaseOfImage));
            FThreads.AddOrSetValue(Event.dwThreadId, Event.CreateProcessInfo.hThread);
            NoteModule(ImageBase, Event.CreateProcessInfo.hFile, ExtractFileName(Fixture.ExePath));
            ImageSize := FModules.Last.Size;
          end;
          CREATE_THREAD_DEBUG_EVENT:
            FThreads.AddOrSetValue(Event.dwThreadId, Event.CreateThread.hThread);
          EXIT_THREAD_DEBUG_EVENT:
            FThreads.Remove(Event.dwThreadId);
          LOAD_DLL_DEBUG_EVENT:
            NoteModule(UInt64(NativeUInt(Event.LoadDll.lpBaseOfDll)), Event.LoadDll.hFile, '');
          OUTPUT_DEBUG_STRING_EVENT:
            HandleDebugString(Event);
          EXCEPTION_DEBUG_EVENT:
            Status := HandleException(Event);
          EXIT_PROCESS_DEBUG_EVENT: begin
            Exited   := True;
            ExitCode := Event.ExitProcess.dwExitCode;
            // The address space is still there at this event: the last moment the
            // counters and the patched sites can be read.
            SnapshotAtExit;
            ContinueDebugEvent(Event.dwProcessId, Event.dwThreadId, DBG_CONTINUE);
            Break;
          end;
        end;
        ContinueDebugEvent(Event.dwProcessId, Event.dwThreadId, Status);
      end;
    finally
      // A no-op once the target has exited; after an error it is what keeps a
      // debuggee from outliving the run.
      TerminateProcess(Process, KILLED_EXIT_CODE);
      WaitForSingleObject(Process, 10000);
      CloseHandle(Process);
    end;
  finally
    CloseHandle(Nul);
  end;
end;

procedure TSession.NoteModule(Base: UInt64; FileHandle: THandle; const Fallback: string);
var
  Path: array[0..MAX_PATH * 2] of Char;
begin
  var Module: TModule;
  Module.Base := Base;
  Module.Name := Fallback;
  if (FileHandle <> 0) and (FileHandle <> INVALID_HANDLE_VALUE) then begin
    if Module.Name = '' then begin
      var PathChars := GetFinalPathNameByHandle(FileHandle, @Path[0], Length(Path) - 1, 0);
      if (PathChars > 0) and (PathChars < DWORD(Length(Path))) then
        Module.Name := ExtractFileName(string(Path));
    end;
    CloseHandle(FileHandle);
  end;
  if Module.Name = '' then
    Module.Name := Format('module@%x', [Base]);
  Module.Size := 0;
  var Header: TBytes;
  if TryReadBytes(Base, $400, Header) then begin
    var NtOffset := PInteger(@Header[$3C])^;
    if (NtOffset > 0) and (NtOffset + $54 <= Length(Header)) then
      Module.Size := PCardinal(@Header[NtOffset + $50])^;
  end;
  FModules.Add(Module);
end;

procedure TSession.HandleDebugString(const Event: TDebugEvent);
begin
  var Count := Event.DebugString.nDebugStringLength;
  if Count = 0 then
    Exit;
  var Text: string;
  var Raw: TBytes;
  if Event.DebugString.fUnicode <> 0 then begin
    if not TryReadBytes(UInt64(NativeUInt(Event.DebugString.lpDebugStringData)), Count * 2, Raw) then
      Exit;
    Text := TEncoding.Unicode.GetString(Raw);
  end
  else begin
    if not TryReadBytes(UInt64(NativeUInt(Event.DebugString.lpDebugStringData)), Count, Raw) then
      Exit;
    Text := TEncoding.ANSI.GetString(Raw);
  end;
  var Terminator := Text.IndexOf(#0);
  if Terminator >= 0 then
    Text := Text.Substring(0, Terminator);
  Text := Text.TrimRight([#13, #10]);
  if Text.StartsWith('PF: ') then begin
    Transcript.Add(Text.Substring(4));
    Log.Add('  > ' + Text.Substring(4));
  end
  else if Text.StartsWith('PFI: ') then begin
    Info.Add(Text.Substring(5));
    Log.Add('  i ' + Text.Substring(5));
  end;
end;

function ExceptionName(Code: DWORD): string;
begin
  case Code of
    DWORD(EXCEPTION_ACCESS_VIOLATION):     Result := 'access violation';
    DWORD(EXCEPTION_BREAKPOINT):           Result := 'breakpoint';
    DWORD(EXCEPTION_SINGLE_STEP):          Result := 'single step';
    STATUS_WX86_BREAKPOINT:                Result := 'breakpoint (WOW64)';
    STATUS_WX86_SINGLE_STEP:               Result := 'single step (WOW64)';
    DELPHI_EXCEPTION_CODE:                 Result := 'Delphi exception';
    DWORD(EXCEPTION_ILLEGAL_INSTRUCTION):  Result := 'illegal instruction';
    DWORD(EXCEPTION_PRIV_INSTRUCTION):     Result := 'privileged instruction';
    DWORD(EXCEPTION_STACK_OVERFLOW):       Result := 'stack overflow';
    DWORD($C0000409):                      Result := 'fail fast / stack buffer overrun';
    DWORD($C0000028):                      Result := 'bad stack';
    DWORD($C0000026):                      Result := 'invalid disposition';
    DWORD($C0000025):                      Result := 'noncontinuable exception';
    DWORD($C0000029):                      Result := 'invalid unwind target';
  else
    Result := 'exception';
  end;
end;

function TSession.HandleException(const Event: TDebugEvent): DWORD;
begin
  var Code := DWORD(Event.Exception.ExceptionRecord.ExceptionCode);
  var Address := UInt64(NativeUInt(Event.Exception.ExceptionRecord.ExceptionAddress));
  var FirstChance := Event.Exception.dwFirstChance <> 0;
  var IsWowBreak := Code = STATUS_WX86_BREAKPOINT;
  if FirstChance and ((Code = DWORD(EXCEPTION_BREAKPOINT)) or IsWowBreak) then
    Exit(HandleBreakpoint(Event.dwThreadId, Address, IsWowBreak));

  Inc(FExceptions);
  var Line := Format('%s %.8x (%s) at %s', [IfThen(FirstChance, 'first-chance', 'SECOND-CHANCE'), Code,
    ExceptionName(Code), Describe(Address)]);
  var Parameters := Event.Exception.ExceptionRecord.NumberParameters;
  if (Code = DWORD(EXCEPTION_ACCESS_VIOLATION)) and (Parameters >= 2) then begin
    var Kind := 'read';
    case Event.Exception.ExceptionRecord.ExceptionInformation[0] of
      1: Kind := 'write';
      8: Kind := 'execute';
    end;
    Line := Line + Format(', %s of $%x', [Kind, UInt64(Event.Exception.ExceptionRecord.ExceptionInformation[1])]);
  end
  else if (Code = DELPHI_EXCEPTION_CODE) and (Parameters >= 1) then
    Line := Line + ', raised at ' + Describe(UInt64(Event.Exception.ExceptionRecord.ExceptionInformation[0]));
  Log.Add(Line);

  if (FExceptions > FloodLimit) and not Flooded then begin
    Flooded := True;
    Log.Add('probe: exception flood, terminating the debuggee');
    TerminateProcess(Process, KILLED_EXIT_CODE);
    Exit(DBG_EXCEPTION_NOT_HANDLED);
  end;

  if not FirstChance then begin
    // Nobody handled it: passing it on once more ends the process.
    if not SecondChance then begin
      SecondChance     := True;
      SecondChanceText := Format('second-chance %.8x (%s) at %s', [Code, ExceptionName(Code), Describe(Address)]);
    end;
    TerminateProcess(Process, Code);
    Exit(DBG_EXCEPTION_NOT_HANDLED);
  end;

  if (FaultPolicy = fpSendBack) and (FindPatchByTrampoline(Address) <> nil) and TrySendBack(Event.dwThreadId, Address) then
    Exit(DBG_CONTINUE);
  Result := DBG_EXCEPTION_NOT_HANDLED;
end;

function TSession.HandleBreakpoint(ThreadId: DWORD; Address: UInt64; IsWowBreak: Boolean): DWORD;
begin
  // The loader's own breakpoint: one for a native target; a WOW64 target reports
  // a native one and then a 32-bit one. Patches go in when the 32-bit side
  // exists: at the only one of a native target, at the second of a WOW64 one.
  if (IsWowBreak and not FWowLoaderBreakSeen) or ((not IsWowBreak) and not FNativeLoaderBreakSeen) then begin
    if IsWowBreak then
      FWowLoaderBreakSeen := True
    else
      FNativeLoaderBreakSeen := True;
    if (IsWowBreak = IsWow64) and not FAttached then begin
      FAttached := True;
      if Assigned(OnAttach) then
        try
          OnAttach();
        except
          on E: ERefused do begin
            Refusal := E.Message;
            TerminateProcess(Process, KILLED_EXIT_CODE);
          end;
        end;
    end;
    Exit(DBG_CONTINUE);
  end;

  var Planted: TBreakpoint;
  if FBreaks.TryGetValue(Address, Planted) then begin
    Inc(Planted.Hits);
    if Planted.Hits = 1 then begin
      // Compare before restoring: a byte that is no longer ours was overwritten
      // by the program and is left alone.
      var Current := ReadBytes(Address, 1);
      if Current[0] = $CC then
        WriteCode(Address, [Planted.Original])
      else
        Log.Add(Format('probe: the byte at %s is %.2x, no longer our $CC; left alone', [Describe(Address), Current[0]]));
    end;
    var Registers: TControlRegisters;
    if ReadControl(ThreadId, Registers) then begin
      Registers.Pc := Address;
      WriteControl(ThreadId, Registers);
    end;
    Log.Add(Format('probe: breakpoint "%s" hit at %s (hit %d): byte restored, thread rewound', [Planted.Name,
      Describe(Address), Planted.Hits]));
    if (Planted.Kind = bkStop) and (Planted.Hits = 1) and Assigned(Planted.OnStop) then
      try
        Planted.OnStop(ThreadId);
      except
        on E: ERefused do begin
          Refusal := E.Message;
          TerminateProcess(Process, KILLED_EXIT_CODE);
        end;
      end;
    Exit(DBG_CONTINUE);
  end;

  Inc(ForeignBreakpoints);
  Inc(FExceptions);
  var Bytes: TBytes;
  var ByteText := '??';
  if TryReadBytes(Address, 1, Bytes) then
    ByteText := IntToHex(Bytes[0], 2);
  Log.Add(Format('first-chance breakpoint at %s, an address the probe never patched (byte there: %s); passed on',
    [Describe(Address), ByteText]));
  if (FExceptions > FloodLimit) and not Flooded then begin
    Flooded := True;
    TerminateProcess(Process, KILLED_EXIT_CODE);
  end;
  Result := DBG_EXCEPTION_NOT_HANDLED;
end;

procedure TSession.SnapshotAtExit;
begin
  for var Patch in Patches do begin
    TryReadBytes(Patch.Site, Length(Patch.Patched), Patch.AtExit);
    var Raw: TBytes;
    if (Patch.Counter <> 0) and TryReadBytes(Patch.Counter, 4, Raw) then
      Patch.CounterAtExit := PCardinal(@Raw[0])^;
  end;
  for var Planted in FBreaks.Values do begin
    var Raw: TBytes;
    if TryReadBytes(Planted.Address, 1, Raw) then
      Planted.AtExit := Raw[0];
  end;
end;

function TSession.Breakpoints: TArray<TBreakpoint>;
begin
  Result := FBreaks.Values.ToArray;
end;

{ memory }

function TSession.TryReadBytes(Address: UInt64; Count: Integer; out Bytes: TBytes): Boolean;
begin
  SetLength(Bytes, Count);
  if Count = 0 then
    Exit(True);
  var Done: NativeUInt := 0;
  Result := ReadProcessMemory(Process, Pointer(Address), @Bytes[0], Count, Done) and (Done = NativeUInt(Count));
  if not Result then
    Bytes := nil;
end;

function TSession.ReadBytes(Address: UInt64; Count: Integer): TBytes;
begin
  if not TryReadBytes(Address, Count, Result) then
    raise Exception.CreateFmt('cannot read %d bytes at $%x', [Count, Address]);
end;

procedure TSession.WriteCode(Address: UInt64; const Bytes: TBytes);
var
  OldProtect, Ignored: DWORD;
  Done: NativeUInt;
begin
  if not VirtualProtectEx(Process, Pointer(Address), Length(Bytes), PAGE_EXECUTE_READWRITE, OldProtect) then
    raise Exception.CreateFmt('VirtualProtectEx failed at $%x: %s', [Address, SysErrorMessage(GetLastError)]);
  var Written := WriteProcessMemory(Process, Pointer(Address), @Bytes[0], Length(Bytes), Done) and
    (Done = NativeUInt(Length(Bytes)));
  VirtualProtectEx(Process, Pointer(Address), Length(Bytes), OldProtect, Ignored);
  FlushInstructionCache(Process, Pointer(Address), Length(Bytes));
  if not Written then
    raise Exception.CreateFmt('WriteProcessMemory failed at $%x', [Address]);
end;

function TSession.DecodeBytesAt(Address: UInt64; const Bytes: TBytes; Offset: Integer): TInsn;
var
  Decoded: TZydisInstruction;
begin
  var Mode := zmmLong64;
  if IsWow64 then
    Mode := zmmLegacy32;
  var Available := Min(15, Length(Bytes) - Offset);
  if (Available <= 0) or not ZydisDecodeOne(Mode, Address, Bytes[Offset], Available, Decoded) then
    raise ERefused.CreateFmt('the bytes at %s do not decode as an instruction', [Describe(Address)]);
  Result.Address := Address;
  Result.Bytes   := Copy(Bytes, Offset, Decoded.Length);
  Result.Text    := Decoded.Text;
end;

function TSession.Decode(Address: UInt64): TInsn;
begin
  var Raw: TBytes;
  var Count := 15;
  while (Count > 0) and not TryReadBytes(Address, Count, Raw) do
    Dec(Count);
  if Count = 0 then
    raise ERefused.CreateFmt('cannot read code at $%x', [Address]);
  Result := DecodeBytesAt(Address, Raw, 0);
end;

// The instructions from Site that a patch of MinBytes displaces. Nothing that
// transfers control may be among them, except a `ret` that ends the span.
function TSession.DecodeSpan(Site: UInt64; MinBytes: Integer; ThroughReturn: Boolean): TArray<TInsn>;
begin
  Result := nil;
  var Address := Site;
  var Total := 0;
  while True do begin
    var Insn := Decode(Address);
    Result := Result + [Insn];
    Inc(Total, Insn.Size);
    Address := Insn.NextAddress;
    if Insn.IsReturn then begin
      if Total < MinBytes then
        raise ERefused.CreateFmt('only %d bytes from %s to the ret, %d needed', [Total, Describe(Site), MinBytes]);
      Exit;
    end;
    if Insn.TransfersControl then
      raise ERefused.CreateFmt('the span from %s would displace "%s"', [Describe(Site), Insn.Text]);
    if (Total >= MinBytes) and not ThroughReturn then
      Exit;
    if Length(Result) > 24 then
      raise ERefused.CreateFmt('no ret within 24 instructions of %s', [Describe(Site)]);
  end;
end;

function TSession.Listing(Address: UInt64; Count: Integer): TArray<string>;
begin
  Result := nil;
  for var I := 1 to Count do begin
    var Insn: TInsn;
    try
      Insn := Decode(Address);
    except
      on ERefused do begin
        Result := Result + [Format('    %s  (undecodable)', [Describe(Address)])];
        Exit;
      end;
    end;
    Result := Result + [Format('    %-34s %-30s %s', [Describe(Address), HexBytes(Insn.Bytes), Insn.Text])];
    Address := Insn.NextAddress;
  end;
end;

function TSession.RegionDescription(Address: UInt64): string;
var
  Region: TMemoryBasicInformation;
begin
  if VirtualQueryEx(Process, Pointer(Address), Region, SizeOf(Region)) = 0 then
    Exit('no such address');
  if Region.State = MEM_FREE then
    Exit('free');
  if Region.State = MEM_RESERVE then
    Exit('reserved, not committed');
  case Region.Type_9 of
    MEM_IMAGE:   Result := 'image';
    MEM_MAPPED:  Result := 'mapped';
    MEM_PRIVATE: Result := 'private';
  else
    Result := 'memory';
  end;
  case Region.Protect and $FF of
    PAGE_EXECUTE_READWRITE: Result := Result + ' RWX';
    PAGE_EXECUTE_READ:      Result := Result + ' RX';
    PAGE_EXECUTE:           Result := Result + ' X';
    PAGE_READWRITE:         Result := Result + ' RW';
    PAGE_READONLY:          Result := Result + ' R';
    PAGE_NOACCESS:          Result := Result + ' no access';
  else
    Result := Result + Format(' protect $%x', [Region.Protect]);
  end;
end;

function TSession.Describe(Address: UInt64): string;
begin
  if (ImageBase <> 0) and (Address >= ImageBase) and (Address - ImageBase < ImageSize) then begin
    Result := Format('fixture+%x', [Address - ImageBase]);
    var Name := Fixture.FunctionAt(Address - ImageBase);
    if Name <> '' then
      Result := Result + ' (' + Name + ')';
    Exit;
  end;
  if (FArena <> 0) and (Address >= FArena) and (Address - FArena < ARENA_BYTES) then begin
    var Patch := FindPatchByTrampoline(Address);
    if Patch <> nil then
      Exit(Format('trampoline[%s]+%x', [Patch.Name, Address - Patch.Trampoline]));
    Exit(Format('arena+%x', [Address - FArena]));
  end;
  for var Module in FModules do
    if (Address >= Module.Base) and (Address - Module.Base < Module.Size) then
      Exit(Format('%s+%x', [Module.Name, Address - Module.Base]));
  Result := Format('$%x (%s)', [Address, RegionDescription(Address)]);
end;

// The direct call on a source line and the address it returns to.
function TSession.FirstInsnOnLine(const LineMarker: string; Matches: TFunc<TInsn, Boolean>; const What: string): TInsn;
begin
  var Address := Va(Fixture.Marker(LineMarker));
  for var I := 1 to 12 do begin
    Result := Decode(Address);
    if Matches(Result) then
      Exit;
    if Result.TransfersControl then
      Break;
    Address := Result.NextAddress;
  end;
  raise ERefused.CreateFmt('no %s in the first block of line {BP:%s}', [What, LineMarker]);
end;

function TSession.ReturnAddressOfCallOnLine(const CallMarker: string; out Call: TInsn): UInt64;
begin
  Call := FirstInsnOnLine(CallMarker,
    function(Insn: TInsn): Boolean
    begin
      Result := Insn.IsDirectCall;
    end, 'direct call');
  Result := Call.NextAddress;
end;

{ threads }

function TSession.ThreadHandle(ThreadId: DWORD): THandle;
begin
  if not FThreads.TryGetValue(ThreadId, Result) then
    Result := 0;
end;

function TSession.ReadControl(ThreadId: DWORD; out Registers: TControlRegisters): Boolean;
var
  Context:    TContext;
  WowContext: TWow64Context;
begin
  Registers := Default(TControlRegisters);
  var Thread := ThreadHandle(ThreadId);
  if Thread = 0 then
    Exit(False);
  if IsWow64 then begin
    WowContext.ContextFlags := WOW64_CONTEXT_CONTROL;
    Result := Wow64GetThreadContext(Thread, WowContext);
    if Result then begin
      Registers.Pc    := WowContext.Eip;
      Registers.Sp    := WowContext.Esp;
      Registers.Flags := WowContext.EFlags;
    end;
  end
  else begin
    Context.ContextFlags := CONTEXT_CONTROL;
    Result := GetThreadContext(Thread, Context);
    if Result then begin
      Registers.Pc    := Context.Rip;
      Registers.Sp    := Context.Rsp;
      Registers.Flags := Context.EFlags;
    end;
  end;
end;

function TSession.WriteControl(ThreadId: DWORD; const Registers: TControlRegisters): Boolean;
var
  Context:    TContext;
  WowContext: TWow64Context;
begin
  var Thread := ThreadHandle(ThreadId);
  if Thread = 0 then
    Exit(False);
  if IsWow64 then begin
    WowContext.ContextFlags := WOW64_CONTEXT_CONTROL;
    Result := Wow64GetThreadContext(Thread, WowContext);
    if not Result then
      Exit;
    WowContext.Eip    := DWORD(Registers.Pc);
    WowContext.Esp    := DWORD(Registers.Sp);
    WowContext.EFlags := DWORD(Registers.Flags);
    Result := Wow64SetThreadContext(Thread, WowContext);
  end
  else begin
    Context.ContextFlags := CONTEXT_CONTROL;
    Result := GetThreadContext(Thread, Context);
    if not Result then
      Exit;
    Context.Rip    := Registers.Pc;
    Context.Rsp    := Registers.Sp;
    Context.EFlags := DWORD(Registers.Flags);
    Result := SetThreadContext(Thread, Context);
  end;
  if not Result then
    Log.Add('probe: could not write the thread context: ' + SysErrorMessage(GetLastError));
end;

{ trampolines }

procedure Append(var Code: TBytes; const Data: array of Byte);
begin
  var Start := Length(Code);
  SetLength(Code, Start + Length(Data));
  for var I := 0 to High(Data) do
    Code[Start + I] := Data[I];
end;

procedure AppendU32(var Code: TBytes; Value: Cardinal);
begin
  Append(Code, [Byte(Value), Byte(Value shr 8), Byte(Value shr 16), Byte(Value shr 24)]);
end;

// A rel32 field whose last byte is the last byte of its instruction.
procedure AppendRel32(var Code: TBytes; Base, Target: UInt64);
begin
  var Next := Base + UInt64(Length(Code)) + 4;
  var Distance := Int64(Target) - Int64(Next);
  if (Distance > High(Integer)) or (Distance < Low(Integer)) then
    raise ERefused.CreateFmt('$%x is out of rel32 reach of $%x', [Target, Next]);
  AppendU32(Code, Cardinal(Integer(Distance)));
end;

// A five-byte call or jump that will stand at InstructionAddress.
function Rel32Bytes(Opcode: Byte; InstructionAddress, Target: UInt64): TBytes;
begin
  Result := nil;
  Append(Result, [Opcode]);
  AppendRel32(Result, InstructionAddress, Target);
end;

procedure TSession.EnsureArena;
var
  Region: TMemoryBasicInformation;
begin
  if FArena <> 0 then
    Exit;
  var Allocated: Pointer := nil;
  if IsWow64 then
    Allocated := VirtualAllocEx(Process, nil, ARENA_BYTES, MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE)
  else begin
    // Within rel32 reach of the image: the first free region above it, then
    // the ones below.
    var LowestAddress := UInt64(0);
    if ImageBase > NEAR_REACH then
      LowestAddress := ImageBase - NEAR_REACH;
    var Address := (ImageBase + ImageSize + $FFFF) and not UInt64($FFFF);
    var SearchingAbove := True;
    while Allocated = nil do begin
      if SearchingAbove and (Address >= ImageBase + NEAR_REACH) then begin
        SearchingAbove := False;
        Address := (LowestAddress + $FFFF) and not UInt64($FFFF);
      end;
      if (not SearchingAbove) and (Address >= ImageBase) then
        Break;
      if VirtualQueryEx(Process, Pointer(Address), Region, SizeOf(Region)) = 0 then
        Break;
      var RegionEnd := UInt64(NativeUInt(Region.BaseAddress)) + Region.RegionSize;
      if (Region.State = MEM_FREE) and (RegionEnd - Address >= ARENA_BYTES) then
        Allocated := VirtualAllocEx(Process, Pointer(Address), ARENA_BYTES, MEM_COMMIT or MEM_RESERVE,
          PAGE_EXECUTE_READWRITE);
      if Allocated = nil then
        Address := (RegionEnd + $FFFF) and not UInt64($FFFF);
    end;
  end;
  if Allocated = nil then
    raise ERefused.Create('no executable memory could be allocated within rel32 reach of the image');
  FArena       := UInt64(NativeUInt(Allocated));
  FArenaNext   := FArena;
  FCounterNext := FArena + ARENA_DATA_OFFSET;
  Notes.Add(Format('arena: %d bytes RWX at $%x, %s the image by %.1f MB', [ARENA_BYTES, FArena,
    IfThen(FArena > ImageBase, 'above', 'below'), Abs(Int64(FArena) - Int64(ImageBase)) / (1024 * 1024)],
    TFormatSettings.Invariant));
end;

function TSession.NewCounter: UInt64;
begin
  EnsureArena;
  Result := FCounterNext;
  Inc(FCounterNext, 8);
end;

function TSession.PlaceTrampoline(const Code: TBytes): UInt64;
var
  Done: NativeUInt;
begin
  Result := FArenaNext;
  if not WriteProcessMemory(Process, Pointer(Result), @Code[0], Length(Code), Done) then
    raise Exception.Create('cannot write the trampoline');
  FlushInstructionCache(Process, Pointer(Result), Length(Code));
  FArenaNext := (FArenaNext + UInt64(Length(Code)) + 15) and not UInt64(15);
end;

function TSession.FindPatchByTrampoline(Address: UInt64): TPatch;
begin
  for var Patch in Patches do
    if (Patch.Trampoline <> 0) and (Address >= Patch.Trampoline) and (Address - Patch.Trampoline < UInt64(Patch.TrampolineSize)) then
      Exit(Patch);
  Result := nil;
end;

// lock inc dword ptr [counter]. With pkFaultThenCount it is preceded by a
// payload that saves the flags and then writes to address 0, so that the fault
// happens with something of the payload's on the stack.
procedure TSession.EmitPayload(var Code: TBytes; Base: UInt64; Patch: TPatch; Payload: TPayload);
begin
  Patch.PayloadStart := Length(Code);
  if Payload = pkFaultThenCount then begin
    Append(Code, [$9C]);                                   // pushf
    Patch.FlagsPushedFrom := Length(Code);
    if IsWow64 then
      Append(Code, [$F0, $FF, $05, 0, 0, 0, 0])            // lock inc dword ptr [0]
    else
      Append(Code, [$F0, $FF, $04, $25, 0, 0, 0, 0]);      // lock inc dword ptr [abs 0]
    Patch.FlagsPushedTo := Length(Code);
    Append(Code, [$9D]);                                   // popf
  end;
  Append(Code, [$F0, $FF, $05]);
  if IsWow64 then
    AppendU32(Code, Cardinal(Patch.Counter))
  else
    AppendRel32(Code, Base, Patch.Counter);
  Patch.PayloadEnd := Length(Code);
end;

// Copies one displaced instruction. On x64 an instruction whose text depends on
// where it stands (a RIP-relative operand) gets its one displacement field
// rewritten; the field is found by asking the decoder which rewrite gives back
// the original instruction, so no opcode table is involved. A relative branch
// is refused: the fixture has none in a span.
procedure TSession.EmitRelocated(var Code: TBytes; Base: UInt64; Patch: TPatch; const Insn: TInsn);
begin
  var NewAddress := Base + UInt64(Length(Code));
  var Copy_ := Copy(Insn.Bytes);
  var Moved := DecodeBytesAt(NewAddress, Copy_, 0);
  if Moved.Text <> Insn.Text then begin
    if Insn.TransfersControl then
      raise ERefused.CreateFmt('"%s" is a relative branch; relocating it is not implemented', [Insn.Text]);
    var Delta := Int64(Insn.Address) - Int64(NewAddress);
    var Found := False;
    for var Offset := Insn.Size - 4 downto 1 do begin
      var Candidate := Copy(Insn.Bytes);
      var Field := Int64(PInteger(@Candidate[Offset])^) + Delta;
      if (Field > High(Integer)) or (Field < Low(Integer)) then
        Continue;
      PInteger(@Candidate[Offset])^ := Integer(Field);
      var Check: TInsn;
      try
        Check := DecodeBytesAt(NewAddress, Candidate, 0);
      except
        on ERefused do
          Continue;
      end;
      if (Check.Size = Insn.Size) and (Check.Text = Insn.Text) then begin
        Copy_ := Candidate;
        Found := True;
        Break;
      end;
    end;
    if not Found then
      raise ERefused.CreateFmt('"%s" cannot be re-based to $%x', [Insn.Text, NewAddress]);
  end;
  var Entry: TRelocatedInsn;
  Entry.Offset   := Length(Code);
  Entry.Size     := Insn.Size;
  Entry.Original := Insn.Address;
  Entry.Text     := Insn.Text;
  Patch.Relocated := Patch.Relocated + [Entry];
  Append(Code, Copy_);
end;

procedure TSession.EmitJump(var Code: TBytes; Base, Target: UInt64);
begin
  Append(Code, [$E9]);
  AppendRel32(Code, Base, Target);
end;

procedure NotePatch(Session: TSession; Patch: TPatch);
begin
  Session.Notes.Add(Format('%s "%s" at %s', [Patch.Form, Patch.Name, Session.Describe(Patch.Site)]));
  Session.Notes.Add(Format('    site before: %s', [HexBytes(Patch.Original)]));
  Session.Notes.Add(Format('    site after:  %s', [HexBytes(Patch.Patched)]));
  if Patch.Trampoline <> 0 then begin
    Session.Notes.Add(Format('    trampoline at $%x, %d bytes:', [Patch.Trampoline, Patch.TrampolineSize]));
    var Address := Patch.Trampoline;
    while Address < Patch.Trampoline + UInt64(Patch.TrampolineSize) do begin
      var Insn := Session.Decode(Address);
      var Remark := '';
      for var Entry in Patch.Relocated do
        if Patch.Trampoline + UInt64(Entry.Offset) = Address then
          Remark := '   ; relocated from ' + Session.Describe(Entry.Original);
      Session.Notes.Add(Format('      +%.2x  %-32s %s%s', [Address - Patch.Trampoline, HexBytes(Insn.Bytes), Insn.Text, Remark]));
      Address := Insn.NextAddress;
    end;
  end;
end;

// The jump form: E9 to a trampoline that counts, runs the displaced
// instructions and jumps back.
function TSession.InstallJump(const Name: string; Site: UInt64; Payload: TPayload; ThroughReturn: Boolean): TPatch;
begin
  var Span := DecodeSpan(Site, 5, ThroughReturn);
  var SpanBytes := Integer(Span[High(Span)].NextAddress - Site);
  EnsureArena;
  Result := TPatch.Create;
  Patches.Add(Result);
  Result.Name     := Name;
  Result.Form     := 'jump';
  Result.Site     := Site;
  Result.Original := ReadBytes(Site, SpanBytes);
  Result.Counter  := NewCounter;

  var Base := FArenaNext;
  var Code: TBytes := nil;
  EmitPayload(Code, Base, Result, Payload);
  for var Insn in Span do
    EmitRelocated(Code, Base, Result, Insn);
  if not Span[High(Span)].IsReturn then
    EmitJump(Code, Base, Site + UInt64(SpanBytes));
  Result.Trampoline     := PlaceTrampoline(Code);
  Result.TrampolineSize := Length(Code);

  Result.Patched := Rel32Bytes($E9, Site, Result.Trampoline);
  while Length(Result.Patched) < SpanBytes do
    Append(Result.Patched, [$90]);
  WriteCode(Site, Result.Patched);
  NotePatch(Self, Result);
end;

// The call form: E8 to a trampoline. Its first act removes the address the call
// pushed by overwriting it with the address of the trampoline's own next
// instruction and returning to it: one call, one ret, so the processor's return
// prediction stays paired (that ret is the mispredicted one), and the stack
// pointer is back where the site had it. No register and no flag is touched.
function TSession.InstallCallForm(const Name: string; Site: UInt64; ThroughReturn: Boolean): TPatch;
begin
  var Span := DecodeSpan(Site, 5, ThroughReturn);
  var SpanBytes := Integer(Span[High(Span)].NextAddress - Site);
  EnsureArena;
  Result := TPatch.Create;
  Patches.Add(Result);
  Result.Name     := Name;
  Result.Form     := 'call form';
  Result.Site     := Site;
  Result.Original := ReadBytes(Site, SpanBytes);
  Result.Counter  := NewCounter;

  var Base := FArenaNext;
  var Code: TBytes := nil;
  if IsWow64 then begin
    var Continuation := Base + 8;
    Append(Code, [$C7, $04, $24]);                         // mov dword ptr [esp], continuation
    AppendU32(Code, Cardinal(Continuation));
    Append(Code, [$C3]);                                   // ret
  end
  else begin
    var Continuation := Base + 16;
    Append(Code, [$C7, $04, $24]);                         // mov dword ptr [rsp], low half
    AppendU32(Code, Cardinal(Continuation));
    Append(Code, [$C7, $44, $24, $04]);                    // mov dword ptr [rsp+4], high half
    AppendU32(Code, Cardinal(Continuation shr 32));
    Append(Code, [$C3]);                                   // ret
  end;
  EmitPayload(Code, Base, Result, pkCount);
  for var Insn in Span do
    EmitRelocated(Code, Base, Result, Insn);
  if not Span[High(Span)].IsReturn then
    EmitJump(Code, Base, Site + UInt64(SpanBytes));
  Result.Trampoline     := PlaceTrampoline(Code);
  Result.TrampolineSize := Length(Code);

  Result.Patched := Rel32Bytes($E8, Site, Result.Trampoline);
  while Length(Result.Patched) < SpanBytes do
    Append(Result.Patched, [$90]);
  WriteCode(Site, Result.Patched);
  NotePatch(Self, Result);
end;

// A direct call keeps its five bytes; only the rel32 changes, to a trampoline
// that counts and jumps on to the real callee.
//
// CallThrough is the contrast, not a line probe: the trampoline CALLS the
// callee and returns, as a payload that enters a runtime would, so an address
// inside the trampoline is on the stack while the callee runs.
function TSession.RetargetCall(const Name: string; const Call: TInsn; CallThrough: Boolean): TPatch;
begin
  if not Call.IsDirectCall then
    raise ERefused.CreateFmt('"%s" is not a direct call', [Call.Text]);
  EnsureArena;
  Result := TPatch.Create;
  Patches.Add(Result);
  Result.Name     := Name;
  Result.Form     := IfThen(CallThrough, 'retargeted call, trampoline calls the callee', 'retargeted call');
  Result.Site     := Call.Address;
  Result.Original := Copy(Call.Bytes);
  Result.Counter  := NewCounter;
  var Callee := UInt64(Int64(Call.NextAddress) + PInteger(@Call.Bytes[1])^);
  if IsWow64 then
    Callee := Callee and $FFFFFFFF;

  var Base := FArenaNext;
  var Code: TBytes := nil;
  EmitPayload(Code, Base, Result, pkCount);
  if not CallThrough then
    EmitJump(Code, Base, Callee)
  else begin
    // x64: the callee's home space, and the stack back on a 16-byte boundary.
    if not IsWow64 then
      Append(Code, [$48, $83, $EC, $28]);                  // sub rsp, 28h
    Append(Code, [$E8]);
    AppendRel32(Code, Base, Callee);
    if not IsWow64 then
      Append(Code, [$48, $83, $C4, $28]);                  // add rsp, 28h
    Append(Code, [$C3]);
  end;
  Result.Trampoline     := PlaceTrampoline(Code);
  Result.TrampolineSize := Length(Code);

  Result.Patched := Rel32Bytes($E8, Call.Address, Result.Trampoline);
  WriteCode(Call.Address, Result.Patched);
  NotePatch(Self, Result);
end;

// FF 15 <operand> becomes E8 rel32 + 90 (the return address moves one byte
// back) or 90 + E8 rel32 (it stays where it was). The trampoline counts and
// jumps through the same memory operand.
function TSession.ReencodeIndirectCall(const Name: string; const Call: TInsn; NopFirst: Boolean): TPatch;
begin
  if not Call.IsIndirectCallThroughMemory then
    raise ERefused.CreateFmt('"%s" (%s) is not a six-byte call through memory', [Call.Text, HexBytes(Call.Bytes)]);
  EnsureArena;
  Result := TPatch.Create;
  Patches.Add(Result);
  Result.Name     := Name;
  Result.Form     := IfThen(NopFirst, 're-encoded indirect call (nop, call)', 're-encoded indirect call (call, nop)');
  Result.Site     := Call.Address;
  Result.Original := Copy(Call.Bytes);
  Result.Counter  := NewCounter;

  var Base := FArenaNext;
  var Code: TBytes := nil;
  EmitPayload(Code, Base, Result, pkCount);
  Append(Code, [$FF, $25]);                                // jmp [same operand]
  if IsWow64 then
    AppendU32(Code, PCardinal(@Call.Bytes[2])^)
  else
    AppendRel32(Code, Base, UInt64(Int64(Call.NextAddress) + PInteger(@Call.Bytes[2])^));
  Result.Trampoline     := PlaceTrampoline(Code);
  Result.TrampolineSize := Length(Code);

  if NopFirst then begin
    Result.Patched := [$90];
    Append(Result.Patched, Rel32Bytes($E8, Call.Address + 1, Result.Trampoline));
  end
  else begin
    Result.Patched := Rel32Bytes($E8, Call.Address, Result.Trampoline);
    Append(Result.Patched, [$90]);
  end;
  WriteCode(Call.Address, Result.Patched);
  NotePatch(Self, Result);
end;

function TSession.InstallBreakpoint(const Name: string; Address: UInt64; Kind: TBreakKind; OnStop: TProc<DWORD>): TBreakpoint;
begin
  var Current := ReadBytes(Address, 1);
  if Current[0] = $CC then
    raise ERefused.CreateFmt('the byte at %s is already $CC', [Describe(Address)]);
  Result := TBreakpoint.Create;
  Result.Name     := Name;
  Result.Address  := Address;
  Result.Original := Current[0];
  Result.Kind     := Kind;
  Result.OnStop   := OnStop;
  FBreaks.Add(Address, Result);
  WriteCode(Address, [$CC]);
  Notes.Add(Format('%s $CC "%s" at %s (original byte %.2x)', [IfThen(Kind = bkOneShot, 'one-shot', 'stop'), Name,
    Describe(Address), Current[0]]));
end;

// "A fault in a trampoline is sent back": the site gets its bytes back and the
// thread is put where the program expects it. For a relocated instruction that
// is the address it was compiled at; for the payload it is the site, with the
// stack pointer the payload found.
function TSession.TrySendBack(ThreadId: DWORD; FaultAddress: UInt64): Boolean;
begin
  Result := False;
  var Patch := FindPatchByTrampoline(FaultAddress);
  if Patch = nil then
    Exit;
  var Offset := Integer(FaultAddress - Patch.Trampoline);
  var Registers: TControlRegisters;
  if not ReadControl(ThreadId, Registers) then
    Exit;
  var SpAtFault := Registers.Sp;
  var Target: UInt64 := 0;
  var What := '';
  if (Offset >= Patch.PayloadStart) and (Offset < Patch.PayloadEnd) then begin
    Target := Patch.Site;
    What := 'the payload';
    if (Offset >= Patch.FlagsPushedFrom) and (Offset < Patch.FlagsPushedTo) then begin
      // The payload had saved the flags: take them back and drop the slot.
      var Saved := ReadBytes(Registers.Sp, PointerBytes);
      Registers.Flags := PCardinal(@Saved[0])^;
      Inc(Registers.Sp, PointerBytes);
      What := 'the payload, flags on the stack';
    end;
  end
  else
    for var Entry in Patch.Relocated do
      if Offset = Entry.Offset then begin
        Target := Entry.Original;
        What := 'the relocated "' + Entry.Text + '"';
      end;
  if Target = 0 then begin
    Log.Add(Format('probe: fault at %s is in no instruction the probe can map back', [Describe(FaultAddress)]));
    Exit;
  end;

  // Compare before restoring.
  var Current := ReadBytes(Patch.Site, Length(Patch.Patched));
  if SameBytes(Current, Patch.Patched) then begin
    WriteCode(Patch.Site, Patch.Original);
    Patch.Withdrawn := True;
  end
  else
    Log.Add(Format('probe: the site %s no longer holds our bytes (%s); left alone', [Describe(Patch.Site), HexBytes(Current)]));
  Registers.Pc := Target;
  if not WriteControl(ThreadId, Registers) then
    Exit;
  var StackText := 'stack pointer unchanged';
  if SpAtFault <> Registers.Sp then
    StackText := Format('stack pointer +%d, flags restored from the slot', [Registers.Sp - SpAtFault]);
  Log.Add(Format('probe: fault in %s: site withdrawn, thread sent to %s (%s), DBG_CONTINUE', [What, Describe(Target),
    StackText]));
  Result := True;
end;

{ ---------------------------------------------------------- report and rows -- }

type
  TExpectation = (exSame, exBreaks, exOpen);

  TRow = record
    Bitness, Experiment, Variant, Expected, Observed, Verdict: string;
  end;

var
  GRows:       TList<TRow>;
  GTimeoutMs:  Cardinal = 15000;
  GFloodLimit: Integer = 300;
  GOnly:       TArray<string>;

procedure AddRow(Fixture: TFixture; const Experiment, Variant, Expected, Observed, Verdict: string);
begin
  var Row: TRow;
  Row.Bitness    := Fixture.Bitness;
  Row.Experiment := Experiment;
  Row.Variant    := Variant;
  Row.Expected   := Expected;
  Row.Observed   := Observed;
  Row.Verdict    := Verdict;
  GRows.Add(Row);
end;

procedure PrintLines(const Indent: string; Lines: TStrings; MaxLines: Integer);
begin
  if Lines.Count <= MaxLines then begin
    for var Line in Lines do
      Writeln(Indent, Line);
    Exit;
  end;
  var Head := MaxLines div 2;
  for var I := 0 to Head - 1 do
    Writeln(Indent, Lines[I]);
  Writeln(Indent, Format('... %d lines left out ...', [Lines.Count - MaxLines]));
  for var I := Lines.Count - (MaxLines - Head) to Lines.Count - 1 do
    Writeln(Indent, Lines[I]);
end;

function NewSession(Fixture: TFixture; const Args: TArray<string>): TSession;
begin
  Result := TSession.Create(Fixture, Args);
  Result.TimeoutMs  := GTimeoutMs;
  Result.FloodLimit := GFloodLimit;
end;

// The reference run: same loop, nothing written into the target.
function RunPlain(Fixture: TFixture; const Title: string; const Args: TArray<string>): TSession;
begin
  Result := NewSession(Fixture, Args);
  Result.Run;
  Writeln;
  Writeln(Format('=== %s [%s]  fixture arguments: %s', [Title, Fixture.Bitness, string.Join(' ', Args)]));
  Writeln('  plain run: ', Result.Outcome);
  PrintLines('    ', Result.Log, 40);
  if not Result.EndedNormally then
    Writeln('  WARNING: the plain run did not end normally; every comparison below is against a broken reference');
end;

function SameAsPlain(Plain, Patched: TSession): Boolean;
begin
  Result := Plain.EndedNormally and Patched.EndedNormally and (Plain.ExitCode = Patched.ExitCode) and
    (Plain.Transcript.Text = Patched.Transcript.Text);
end;

function DifferenceSummary(Plain, Patched: TSession): string;
begin
  Result := Patched.Outcome;
  if Patched.EndedNormally and (Patched.ExitCode <> Plain.ExitCode) then
    Result := Result + Format(' (plain: %d)', [Plain.ExitCode]);
  var Differing := 0;
  var First := '';
  for var I := 0 to Max(Plain.Transcript.Count, Patched.Transcript.Count) - 1 do begin
    var A := '(nothing)';
    var B := '(nothing)';
    if I < Plain.Transcript.Count then
      A := Plain.Transcript[I];
    if I < Patched.Transcript.Count then
      B := Patched.Transcript[I];
    if A = B then
      Continue;
    Inc(Differing);
    if First = '' then
      First := Format('line %d: plain "%s" / patched "%s"', [I + 1, A, B]);
  end;
  if Differing = 0 then
    Result := Result + '; transcript identical'
  else
    Result := Result + Format('; %d transcript line(s) differ, first %s', [Differing, First]);
end;

function PatchFacts(Session: TSession): string;
begin
  Result := '';
  for var Patch in Session.Patches do begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Format('%s "%s" ran %d time(s)', [Patch.Form, Patch.Name, Patch.CounterAtExit]);
    if Patch.Withdrawn then
      Result := Result + ' and was withdrawn';
  end;
  for var Planted in Session.Breakpoints do begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Format('$CC "%s" hit %d time(s)', [Planted.Name, Planted.Hits]);
  end;
end;

procedure PrintPatched(const Experiment, Variant: string; Fixture: TFixture; Plain, Patched: TSession);
begin
  Writeln;
  Writeln(Format('--- %s %s [%s]', [Experiment, Variant, Fixture.Bitness]));
  PrintLines('  ', Patched.Notes, 80);
  Writeln('  outcome: ', Patched.Outcome);
  if Patched.Refusal <> '' then
    Exit;
  if SameAsPlain(Plain, Patched) then
    Writeln('  transcript and exit code: identical to the plain run')
  else
    Writeln('  DIFFERS from the plain run: ', DifferenceSummary(Plain, Patched));
  var Facts := PatchFacts(Patched);
  if Facts <> '' then
    Writeln('  ', Facts);
  Writeln('  events:');
  PrintLines('    ', Patched.Log, 44);
end;

// Runs one patched variant against its plain reference and files the row.
function RunVariant(Fixture: TFixture; const Experiment, Variant: string; Expectation: TExpectation;
  const Expected: string; Plain: TSession; Policy: TFaultPolicy; Setup: TProc<TSession>;
  const ExtraObserved: TFunc<TSession, string> = nil): Boolean;
begin
  var Session := NewSession(Fixture, Plain.Args);
  try
    Session.FaultPolicy := Policy;
    Session.OnAttach :=
      procedure
      begin
        Setup(Session);
      end;
    Session.Run;
    PrintPatched(Experiment, Variant, Fixture, Plain, Session);
    Result := SameAsPlain(Plain, Session);
    var Observed, Verdict: string;
    if Session.Refusal <> '' then begin
      Observed := 'not run: ' + Session.Refusal;
      Verdict  := 'n/a';
      Result   := False;
    end
    else begin
      if Result then
        Observed := 'as plain'
      else
        Observed := 'DIFFERENT: ' + DifferenceSummary(Plain, Session);
      var Facts := PatchFacts(Session);
      if Facts <> '' then
        Observed := Observed + ' [' + Facts + ']';
      if Assigned(ExtraObserved) then begin
        var Extra := ExtraObserved(Session);
        if Extra <> '' then begin
          Observed := Observed + ' ' + Extra;
          Writeln('  ', Extra);
        end;
      end;
      case Expectation of
        exSame:   Verdict := IfThen(Result, 'confirmed', 'REFUTED');
        exBreaks: Verdict := IfThen(Result, 'REFUTED (nothing broke)', 'confirmed');
      else
        Verdict := 'measured';
      end;
      // Nothing can be concluded from a comparison against a broken reference.
      if not Plain.EndedNormally then
        Verdict := 'n/a: the plain run did not end normally';
    end;
    AddRow(Fixture, Experiment, Variant, Expected, Observed, Verdict);
  finally
    Session.Free;
  end;
end;

function Wanted(const Experiment: string): Boolean;
begin
  if Length(GOnly) = 0 then
    Exit(True);
  for var Name in GOnly do
    if SameText(Name, Experiment) then
      Exit(True);
  Result := False;
end;

{ ----------------------------------------------------------------------- E1 -- }

// A patch AT a return address R, with the callee raising: the first instruction
// of the statement that follows a call.
procedure RunE1(Fixture: TFixture; const Title, Switch, Prefix: string);
begin
  var Plain := RunPlain(Fixture, Title, [Switch]);
  try
    var JumpExpectation := exBreaks;
    var JumpExpected := 'breaks: the unwinder takes the jmp for a tail call';
    if Fixture.IsWow64 then begin
      JumpExpectation := exSame;
      JumpExpected := 'as plain (no table unwinder on x86: the control)';
    end;
    var ReturnAddress: TFunc<TSession, UInt64> :=
      function(Session: TSession): UInt64
      begin
        var Call: TInsn;
        Result := Session.ReturnAddressOfCallOnLine(Prefix + '_CALL', Call);
        if Result <> Session.Va(Fixture.Marker(Prefix + '_NEXT')) then
          raise ERefused.Create('the statement after the call does not start at the return address');
        Session.Notes.Add(Format('call %s returns to R = %s; code at R:', [Session.Describe(Call.Address), Session.Describe(Result)]));
        Session.Notes.AddStrings(Session.Listing(Result, 3));
      end;

    RunVariant(Fixture, Title, '(a) jmp rel32 at R', JumpExpectation, JumpExpected, Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallJump('R', ReturnAddress(Session), pkCount, False);
      end);
    RunVariant(Fixture, Title, '(b) one-shot $CC at R', exSame, 'as plain', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallBreakpoint('R', ReturnAddress(Session), bkOneShot, nil);
      end);
    RunVariant(Fixture, Title, '(c) call form at R', exSame, 'as plain', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallCallForm('R', ReturnAddress(Session), False);
      end);
    RunVariant(Fixture, Title, '(d) jmp rel32 on the second instruction after R', exSame, 'as plain', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        var First := Session.Decode(ReturnAddress(Session));
        Session.InstallJump('R+' + IntToStr(First.Size), First.NextAddress, pkCount, False);
      end);
  finally
    Plain.Free;
  end;
end;

{ ----------------------------------------------------------------------- E2 -- }

type
  TEpilogue = record
    Start: UInt64;
    Insns: TArray<TInsn>;
    function Size: Integer;
    function HasStackAdjustment: Boolean;
    function Text: string;
  end;

function TEpilogue.Size: Integer;
begin
  Result := Integer(Insns[High(Insns)].NextAddress - Start);
end;

function TEpilogue.HasStackAdjustment: Boolean;
begin
  var Name := Mnemonic(Insns[0].Text);
  Result := ((Name = 'lea') or (Name = 'add') or (Name = 'mov')) and
    (Insns[0].Text.Contains('rsp') or Insns[0].Text.Contains('esp'));
end;

function TEpilogue.Text: string;
begin
  Result := '';
  for var Insn in Insns do begin
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + Insn.Text;
  end;
end;

// The epilogue that starts at the return address of the last call of a routine.
function EpilogueAfterCall(Session: TSession; const CallMarker, EndMarker: string): TEpilogue;
begin
  var Call: TInsn;
  Result.Start := Session.ReturnAddressOfCallOnLine(CallMarker, Call);
  if Result.Start <> Session.Va(Session.Fixture.Marker(EndMarker)) then
    raise ERefused.Create('the line of `end` does not start at the return address of the last call');
  Result.Insns := nil;
  var Address := Result.Start;
  while True do begin
    var Insn := Session.Decode(Address);
    var Name := Mnemonic(Insn.Text);
    if not ((Name = 'lea') or (Name = 'add') or (Name = 'mov') or (Name = 'pop') or (Name = 'ret')) then
      raise ERefused.CreateFmt('"%s" at the return address is not part of an epilogue', [Insn.Text]);
    Result.Insns := Result.Insns + [Insn];
    if Insn.IsReturn then
      Break;
    Address := Insn.NextAddress;
  end;
  var Bytes := Session.ReadBytes(Result.Start, Result.Size);
  Session.Notes.Add(Format('epilogue at R = %s, %d bytes: %s', [Session.Describe(Result.Start), Result.Size, HexBytes(Bytes)]));
  Session.Notes.Add('    ' + Result.Text);
end;

// The part of an epilogue behind its stack adjustment: where the plan puts the
// patch "over pop ...; ret".
function AfterStackAdjustment(const Epilogue: TEpilogue): UInt64;
begin
  if not Epilogue.HasStackAdjustment then
    raise ERefused.Create('the epilogue has no stack adjustment in front of its pops');
  Result := Epilogue.Insns[0].NextAddress;
end;

// The last instructions of an epilogue that end with its ret and cover five bytes.
function TailOfEpilogue(const Epilogue: TEpilogue): UInt64;
begin
  var Finish := Epilogue.Insns[High(Epilogue.Insns)].NextAddress;
  for var I := High(Epilogue.Insns) downto 0 do
    if Finish - Epilogue.Insns[I].Address >= 5 then
      Exit(Epilogue.Insns[I].Address);
  raise ERefused.CreateFmt('the whole epilogue is %d bytes', [Epilogue.Size]);
end;

procedure RunE2(Fixture: TFixture; const Title, Switch, Prefix: string);
begin
  var Plain := RunPlain(Fixture, Title, [Switch]);
  try
    var JumpExpectation := exBreaks;
    var JumpExpected := 'breaks: the unwinder takes the frame for one in its epilogue';
    if Fixture.IsWow64 then begin
      JumpExpectation := exSame;
      JumpExpected := 'as plain (no table unwinder on x86: the control)';
    end;
    var CallMarker := Prefix + '_CALL';
    var EndMarker := Prefix + '_END';

    RunVariant(Fixture, Title, '(a) jmp rel32 behind the stack adjustment, over the pops', JumpExpectation,
      JumpExpected, Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallJump('pops', AfterStackAdjustment(EpilogueAfterCall(Session, CallMarker, EndMarker)), pkCount, False);
      end);
    RunVariant(Fixture, Title, '(a2) jmp rel32 over the last pops and the ret', JumpExpectation, JumpExpected, Plain,
      fpPassOn,
      procedure(Session: TSession)
      begin
        var Epilogue := EpilogueAfterCall(Session, CallMarker, EndMarker);
        var Site := TailOfEpilogue(Epilogue);
        if Site = Epilogue.Start then
          raise ERefused.Create('the tail that covers five bytes is the whole epilogue: same as (a3)');
        Session.InstallJump('tail', Site, pkCount, True);
      end);
    RunVariant(Fixture, Title, '(a3) jmp rel32 at R, the whole epilogue displaced', JumpExpectation, JumpExpected,
      Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallJump('R', EpilogueAfterCall(Session, CallMarker, EndMarker).Start, pkCount, True);
      end);
    RunVariant(Fixture, Title, '(b) the patch of (a) as a call', exSame, 'as plain', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallCallForm('pops', AfterStackAdjustment(EpilogueAfterCall(Session, CallMarker, EndMarker)), False);
      end);
    RunVariant(Fixture, Title, '(c) call form at R, the whole epilogue displaced', exSame, 'as plain', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallCallForm('R', EpilogueAfterCall(Session, CallMarker, EndMarker).Start, True);
      end);
    RunVariant(Fixture, Title, '(d) one-shot $CC at R', exSame, 'as plain', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.InstallBreakpoint('R', EpilogueAfterCall(Session, CallMarker, EndMarker).Start, bkOneShot, nil);
      end);
  finally
    Plain.Free;
  end;
end;

{ ----------------------------------------------------------------------- E3 -- }

procedure NoteFaultSite(Session: TSession; const Marker: string);
begin
  var Site := Session.Va(Session.Fixture.Marker(Marker));
  Session.Notes.Add(Format('statement {BP:%s} at %s:', [Marker, Session.Describe(Site)]));
  Session.Notes.AddStrings(Session.Listing(Site, 3));
end;

procedure RunE3(Fixture: TFixture; const Title, Switch, Marker: string; ProgramFaults: Boolean);
begin
  var Plain := RunPlain(Fixture, Title, [Switch]);
  try
    var Site: TFunc<TSession, UInt64> :=
      function(Session: TSession): UInt64
      begin
        NoteFaultSite(Session, Marker);
        Result := Session.Va(Fixture.Marker(Marker));
      end;
    if ProgramFaults then begin
      RunVariant(Fixture, Title, '(1) jmp patch, fault in the relocated instruction SENT BACK', exSame, 'as plain',
        Plain, fpSendBack,
        procedure(Session: TSession)
        begin
          Session.InstallJump('site', Site(Session), pkCount, False);
        end);
      var ControlExpected := 'breaks: the trampoline has no unwind data';
      if Fixture.IsWow64 then
        ControlExpected := 'differs: handled, but at the trampoline''s address';
      RunVariant(Fixture, Title, '(2) the same, fault PASSED ON (negative control)', exBreaks, ControlExpected, Plain,
        fpPassOn,
        procedure(Session: TSession)
        begin
          Session.InstallJump('site', Site(Session), pkCount, False);
        end);
    end;
    RunVariant(Fixture, Title, '(3) jmp patch whose PAYLOAD faults, sent back to the site', exSame, 'as plain', Plain,
      fpSendBack,
      procedure(Session: TSession)
      begin
        Session.InstallJump('site', Site(Session), pkFaultThenCount, False);
      end);
  finally
    Plain.Free;
  end;
end;

{ ----------------------------------------------------------------- E4 and E5 -- }

procedure RunE4(Fixture: TFixture);
const
  TITLE = 'E4 retargeted direct call';
begin
  var Plain := RunPlain(Fixture, TITLE, ['e4']);
  try
    RunVariant(Fixture, TITLE, 'rel32 of the call changed to a counting trampoline', exSame,
      'as plain: same handler, same stack as seen by the callee, counter = calls', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        var Call: TInsn;
        Session.ReturnAddressOfCallOnLine('E4_CALL', Call);
        Session.Notes.Add('call site:');
        Session.Notes.AddStrings(Session.Listing(Call.Address, 2));
        Session.RetargetCall('E4_CALL', Call, False);
      end);
    var ContrastExpected := 'breaks: an address without unwind data is on the stack when the callee raises';
    if Fixture.IsWow64 then
      ContrastExpected := 'differs: the program''s tracer sees the trampoline instead of the call site';
    RunVariant(Fixture, TITLE, 'contrast, not a line probe: the trampoline CALLS the callee and returns', exBreaks,
      ContrastExpected, Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        var Call: TInsn;
        Session.ReturnAddressOfCallOnLine('E4_CALL', Call);
        Session.RetargetCall('E4_CALL', Call, True);
      end);
  finally
    Plain.Free;
  end;
end;

// x64: the scope table of the routine that contains Address, to show where the
// protected range ends relative to a call.
procedure NoteScopeTable(Session: TSession; Address: UInt64);
begin
  if Session.IsWow64 then
    Exit;
  var Header := Session.ReadBytes(Session.ImageBase, $400);
  var Nt := PInteger(@Header[$3C])^;
  var DirectoryRva := PCardinal(@Header[Nt + $18 + $70 + 3 * 8])^;
  var DirectorySize := PCardinal(@Header[Nt + $18 + $70 + 3 * 8 + 4])^;
  if (DirectoryRva = 0) or (DirectorySize = 0) then
    Exit;
  var Table := Session.ReadBytes(Session.ImageBase + DirectoryRva, DirectorySize);
  var Rva := Cardinal(Address - Session.ImageBase);
  for var I := 0 to Integer(DirectorySize div 12) - 1 do begin
    var BeginRva := PCardinal(@Table[I * 12])^;
    var EndRva := PCardinal(@Table[I * 12 + 4])^;
    if (Rva < BeginRva) or (Rva >= EndRva) then
      Continue;
    var UnwindRva := PCardinal(@Table[I * 12 + 8])^;
    var Unwind := Session.ReadBytes(Session.ImageBase + UnwindRva, 4);
    var Flags := Unwind[0] shr 3;
    var Codes := Unwind[2];
    if (Flags and 3) = 0 then begin
      Session.Notes.Add('scope table: the routine has no language handler');
      Exit;
    end;
    var Offset := UnwindRva + 4 + ((Cardinal(Codes) + 1) and not Cardinal(1)) * 2 + 4;
    var CountBytes := Session.ReadBytes(Session.ImageBase + Offset, 4);
    var Count := PCardinal(@CountBytes[0])^;
    if Count > 32 then
      Exit;
    var Entries := Session.ReadBytes(Session.ImageBase + Offset + 4, Count * 16);
    for var K := 0 to Integer(Count) - 1 do
      Session.Notes.Add(Format('scope[%d]: Begin=+%x End=+%x Handler=%x Target=%x', [K, PCardinal(@Entries[K * 16])^,
        PCardinal(@Entries[K * 16 + 4])^, PCardinal(@Entries[K * 16 + 8])^, PCardinal(@Entries[K * 16 + 12])^]));
    Exit;
  end;
end;

procedure RunE5(Fixture: TFixture; const Title, Switch, Marker: string);
begin
  var Plain := RunPlain(Fixture, Title, [Switch]);
  try
    var IndirectCall: TFunc<TSession, TInsn> :=
      function(Session: TSession): TInsn
      begin
        Result := Session.FirstInsnOnLine(Marker,
          function(Insn: TInsn): Boolean
          begin
            Result := Mnemonic(Insn.Text) = 'call';
          end, 'call');
        Session.Notes.Add(Format('indirect call as compiled: %s  %s; code from it:', [HexBytes(Result.Bytes), Result.Text]));
        Session.Notes.AddStrings(Session.Listing(Result.Address, 3));
        NoteScopeTable(Session, Result.Address);
      end;
    RunVariant(Fixture, Title, '(1) FF 15 -> E8 rel32, 90: return address one byte earlier', exOpen,
      'open: dispatch may or may not notice', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.ReencodeIndirectCall(Marker, IndirectCall(Session), False);
      end);
    RunVariant(Fixture, Title, '(2) FF 15 -> 90, E8 rel32: return address unchanged', exOpen,
      'not in the plan: the nop first', Plain, fpPassOn,
      procedure(Session: TSession)
      begin
        Session.ReencodeIndirectCall(Marker, IndirectCall(Session), True);
      end);
  finally
    Plain.Free;
  end;
end;

{ ----------------------------------------------------------------------- E6 -- }

type
  TWalkReads = record
    Calls, OnStack, FixtureCode, FixtureOther, Elsewhere, TouchingPatch, Failed: Integer;
    CodeAddresses: TArray<UInt64>;   // distinct addresses of fixture code that were read, in order
    CodeCounts:    TArray<Integer>;
    CodeBytes:     TArray<Integer>;
  end;

var
  GWalkSession:  TSession;
  GWalkSite:     UInt64;
  GWalkOriginal: TBytes;           // the bytes of the program at GWalkSite
  GWalkOverlay:  Boolean;
  GWalkReads:    TWalkReads;
  GWalkStackLow, GWalkStackHigh: UInt64;

procedure NoteCodeRead(Address: UInt64; Size: Integer);
begin
  for var I := 0 to High(GWalkReads.CodeAddresses) do
    if GWalkReads.CodeAddresses[I] = Address then begin
      Inc(GWalkReads.CodeCounts[I]);
      Inc(GWalkReads.CodeBytes[I], Size);
      Exit;
    end;
  GWalkReads.CodeAddresses := GWalkReads.CodeAddresses + [Address];
  GWalkReads.CodeCounts    := GWalkReads.CodeCounts + [1];
  GWalkReads.CodeBytes     := GWalkReads.CodeBytes + [Size];
end;

function WalkReadRoutine(hProcess: THandle; BaseAddress: UInt64; Buffer: Pointer; Size: DWORD;
  BytesRead: PDWORD): BOOL; stdcall;
var
  Region: TMemoryBasicInformation;
begin
  Inc(GWalkReads.Calls);
  var Done: NativeUInt := 0;
  Result := ReadProcessMemory(hProcess, Pointer(BaseAddress), Buffer, Size, Done);
  if BytesRead <> nil then
    BytesRead^ := DWORD(Done);
  if not Result then
    Inc(GWalkReads.Failed);

  var Session := GWalkSession;
  if (BaseAddress >= GWalkStackLow) and (BaseAddress < GWalkStackHigh) then
    Inc(GWalkReads.OnStack)
  else if (BaseAddress >= Session.ImageBase) and (BaseAddress - Session.ImageBase < Session.ImageSize) then begin
    var IsCode := (VirtualQueryEx(hProcess, Pointer(BaseAddress), Region, SizeOf(Region)) <> 0) and
      ((Region.Protect and EXECUTABLE_PROTECTIONS) <> 0);
    if IsCode then begin
      Inc(GWalkReads.FixtureCode);
      NoteCodeRead(BaseAddress, Size);
    end
    else
      Inc(GWalkReads.FixtureOther);
  end
  else
    Inc(GWalkReads.Elsewhere);

  // Does the read see the patched site, and should it see the program's bytes?
  var SiteEnd := GWalkSite + UInt64(Length(GWalkOriginal));
  if (BaseAddress < SiteEnd) and (BaseAddress + Size > GWalkSite) then begin
    Inc(GWalkReads.TouchingPatch);
    if GWalkOverlay and Result then
      for var I := 0 to High(GWalkOriginal) do begin
        var Address := GWalkSite + UInt64(I);
        if (Address >= BaseAddress) and (Address < BaseAddress + Done) then
          (PByte(Buffer) + (Address - BaseAddress))^ := GWalkOriginal[I];
      end;
  end;
end;

function WalkStack(Session: TSession; ThreadId: DWORD; ReadRoutine: Pointer): TArray<UInt64>;
var
  Frame: TWalkFrame;
begin
  Result := nil;
  var Thread := Session.ThreadHandle(ThreadId);
  // A CONTEXT has to be 16-byte aligned; a page is.
  var Memory := VirtualAlloc(nil, 8192, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  try
    Frame := Default(TWalkFrame);
    Frame.AddrPC.Mode    := ADDRESS_MODE_FLAT;
    Frame.AddrFrame.Mode := ADDRESS_MODE_FLAT;
    Frame.AddrStack.Mode := ADDRESS_MODE_FLAT;
    var Machine: DWORD;
    if Session.IsWow64 then begin
      var Context := PWow64Context(Memory);
      Context^.ContextFlags := WOW64_CONTEXT_FULL;
      if not Wow64GetThreadContext(Thread, Context^) then
        Exit;
      Machine := MACHINE_I386;
      Frame.AddrPC.Offset    := Context^.Eip;
      Frame.AddrFrame.Offset := Context^.Ebp;
      Frame.AddrStack.Offset := Context^.Esp;
    end
    else begin
      var Context := PContext(Memory);
      Context^.ContextFlags := CONTEXT_FULL;
      if not GetThreadContext(Thread, Context^) then
        Exit;
      Machine := MACHINE_AMD64;
      Frame.AddrPC.Offset    := Context^.Rip;
      Frame.AddrFrame.Offset := Context^.Rbp;
      Frame.AddrStack.Offset := Context^.Rsp;
    end;
    while StackWalk64(Machine, Session.Process, Thread, Frame, Memory, ReadRoutine, @SymFunctionTableAccess64,
        @SymGetModuleBase64, nil) do begin
      if Frame.AddrPC.Offset = 0 then
        Break;
      Result := Result + [Frame.AddrPC.Offset];
      if Length(Result) >= MAX_WALK_FRAMES then
        Break;
    end;
  finally
    VirtualFree(Memory, 0, MEM_RELEASE);
  end;
end;

function SameFrames(const A, B: TArray<UInt64>): Boolean;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for var I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

procedure PrintFrames(Session: TSession; const Title: string; const Frames: TArray<UInt64>);
begin
  Writeln(Format('  %s: %d frame(s)', [Title, Length(Frames)]));
  for var I := 0 to High(Frames) do
    Writeln(Format('    #%-2d %s', [I, Session.Describe(Frames[I])]));
end;

procedure PrintReads(const Title: string; const Reads: TWalkReads);
begin
  Writeln(Format('  %s, reads through the routine: %d (stack %d, fixture code %d, fixture data %d, elsewhere %d, ' +
    'failed %d); %d of them covered the patched site', [Title, Reads.Calls, Reads.OnStack, Reads.FixtureCode,
    Reads.FixtureOther, Reads.Elsewhere, Reads.Failed, Reads.TouchingPatch]));
end;

// Which code of the fixture a walk read: consecutive addresses are merged into
// one range, so a byte-by-byte scan shows as one line.
procedure PrintCodeReads(Session: TSession; const Title: string; const Reads: TWalkReads);
begin
  Writeln(Format('  code of the fixture read through the routine (%s):', [Title]));
  var Index := 0;
  var Printed := 0;
  while (Index <= High(Reads.CodeAddresses)) and (Printed < 40) do begin
    var First := Index;
    var Calls := Reads.CodeCounts[Index];
    var Bytes := Reads.CodeBytes[Index];
    while (Index < High(Reads.CodeAddresses)) and (Reads.CodeAddresses[Index + 1] > Reads.CodeAddresses[Index]) and
        (Reads.CodeAddresses[Index + 1] - Reads.CodeAddresses[Index] <= 8) do begin
      Inc(Index);
      Inc(Calls, Reads.CodeCounts[Index]);
      Inc(Bytes, Reads.CodeBytes[Index]);
    end;
    Writeln(Format('    %s .. +%d: %d read(s), %d byte(s) in all', [Session.Describe(Reads.CodeAddresses[First]),
      Reads.CodeAddresses[Index] - Reads.CodeAddresses[First], Calls, Bytes]));
    Inc(Index);
    Inc(Printed);
  end;
end;

type
  TSiteForm = (sfJump, sfCallForm, sfBreakpoint);

const
  SITE_FORM_NAMES: array[TSiteForm] of string = ('jmp rel32', 'call form', 'one-shot $CC');

procedure RunE6(Fixture: TFixture; Form: TSiteForm);
const
  TITLE = 'E6 dbghelp StackWalk64 over a patched return address';
begin
  var Observed := '';
  var Session := NewSession(Fixture, ['e1']);
  try
    Session.OnAttach :=
      procedure
      begin
        var Call: TInsn;
        var ReturnAddress := Session.ReturnAddressOfCallOnLine('E1_CALL', Call);
        GWalkSite := ReturnAddress;
        case Form of
          sfJump:       GWalkOriginal := Session.InstallJump('R', ReturnAddress, pkCount, False).Original;
          sfCallForm:   GWalkOriginal := Session.InstallCallForm('R', ReturnAddress, False).Original;
          sfBreakpoint: GWalkOriginal := [Session.InstallBreakpoint('R', ReturnAddress, bkOneShot, nil).Original];
        end;
        Session.InstallBreakpoint('E1_CALLEE', Session.Va(Fixture.Marker('E1_CALLEE')), bkStop,
          procedure(ThreadId: DWORD)
          var
            Region: TMemoryBasicInformation;
          begin
            var Registers: TControlRegisters;
            Session.ReadControl(ThreadId, Registers);
            if VirtualQueryEx(Session.Process, Pointer(Registers.Sp), Region, SizeOf(Region)) <> 0 then begin
              GWalkStackLow  := UInt64(NativeUInt(Region.AllocationBase));
              GWalkStackHigh := UInt64(NativeUInt(Region.BaseAddress)) + Region.RegionSize;
            end;
            GWalkSession := Session;
            SymSetOptions(SYMOPT_DEFERRED_LOADS or SYMOPT_FAIL_CRITICAL or SYMOPT_NO_PROMPTS);
            if not SymInitializeW(Session.Process, nil, True) then
              raise ERefused.Create('SymInitialize failed: ' + SysErrorMessage(GetLastError));
            try
              Writeln;
              Writeln(Format('=== %s, %s at R [%s]', [TITLE, SITE_FORM_NAMES[Form], Fixture.Bitness]));
              Writeln(Format('  stopped at %s, before the raise; %s at R = %s', [Session.Describe(Registers.Pc),
                SITE_FORM_NAMES[Form], Session.Describe(ReturnAddress)]));
              PrintLines('  ', Session.Notes, 40);

              var NoRoutine := WalkStack(Session, ThreadId, nil);
              GWalkOverlay := False;
              GWalkReads   := Default(TWalkReads);
              var AsIs := WalkStack(Session, ThreadId, @WalkReadRoutine);
              var AsIsReads := GWalkReads;
              GWalkOverlay := True;
              GWalkReads   := Default(TWalkReads);
              var Original := WalkStack(Session, ThreadId, @WalkReadRoutine);
              var OriginalReads := GWalkReads;

              PrintFrames(Session, 'read routine nil', NoRoutine);
              PrintFrames(Session, 'read routine serving memory as it is', AsIs);
              PrintFrames(Session, 'read routine serving the original bytes at the site', Original);
              PrintReads('as-is walk', AsIsReads);
              PrintReads('original-bytes walk', OriginalReads);
              PrintCodeReads(Session, 'as-is walk', AsIsReads);
              PrintCodeReads(Session, 'original-bytes walk', OriginalReads);

              Observed := Format('nil %s as-is; as-is %s original bytes; %d frames nil / %d as-is / %d original; ' +
                '%d of %d reads were code of the fixture, %d covered the patched site', [
                IfThen(SameFrames(NoRoutine, AsIs), '=', '<>'), IfThen(SameFrames(AsIs, Original), '=', '<>'),
                Length(NoRoutine), Length(AsIs), Length(Original), AsIsReads.FixtureCode, AsIsReads.Calls,
                AsIsReads.TouchingPatch]);
            finally
              SymCleanup(Session.Process);
            end;
            Session.Kill('the walks are done');
          end);
      end;
    Session.Run;
    if Session.Refusal <> '' then
      Observed := 'not run: ' + Session.Refusal
    else if Observed = '' then
      Observed := 'the stop was never reached: ' + Session.Outcome;
    var Expected := 'the three walks agree: not an epilogue pattern';
    if Form = sfJump then
      Expected := 'dbghelp reads the code at return addresses through the routine: only the walk served original bytes is right';
    if Fixture.IsWow64 then
      Expected := 'x86: no epilogue test, the three walks agree';
    AddRow(Fixture, TITLE, SITE_FORM_NAMES[Form] + ' at R of E1, stop in the callee', Expected, Observed, 'measured');
  finally
    Session.Free;
  end;
end;

{ ----------------------------------------------------------------------- E7 -- }

// The bytes of the routine's entry and the number of them a hook has to move:
// whole instructions covering five bytes, none of which depends on its address.
function EntryBytesToMove(Fixture: TFixture; out EntryText: string): Integer;
begin
  var Count := 0;
  var Text := '';
  var Refusal := '';
  var Session := NewSession(Fixture, ['none']);
  try
    Session.OnAttach :=
      procedure
      begin
        try
          var Entry := Session.Va(Fixture.Marker('E7_BEGIN'));
          var Span := Session.DecodeSpan(Entry, 5, False);
          for var Insn in Span do begin
            var Elsewhere := Session.DecodeBytesAt(Insn.Address + $1000, Insn.Bytes, 0);
            if Elsewhere.Text <> Insn.Text then
              raise ERefused.CreateFmt('"%s" in the prologue depends on its address', [Insn.Text]);
            Inc(Count, Insn.Size);
            Text := Text + IfThen(Text <> '', '; ') + Insn.Text;
          end;
          Text := HexBytes(Session.ReadBytes(Entry, Count)) + '  ' + Text;
        except
          on E: ERefused do
            Refusal := E.Message;
        end;
        Session.Kill('prologue read');
      end;
    Session.Run;
  finally
    Session.Free;
  end;
  if Refusal <> '' then
    raise ERefused.Create(Refusal);
  if Count = 0 then
    raise ERefused.Create('the prologue could not be read');
  EntryText := Text;
  Result := Count;
end;

function SiteAtExit(Session: TSession): string;
begin
  Result := '';
  for var Patch in Session.Patches do
    Result := Result + Format('site at exit: %s; ours was %s; the program''s own %s -> compare-before-restore %s',
      [HexBytes(Patch.AtExit), HexBytes(Patch.Patched), HexBytes(Patch.Original),
       IfThen(SameBytes(Patch.AtExit, Patch.Patched), 'would RESTORE (bytes still ours)', 'sees them changed and leaves them')]);
  for var Planted in Session.Breakpoints do
    Result := Result + Format('byte at the site at exit: %.2x; ours was CC over %.2x -> compare-before-restore %s',
      [Planted.AtExit, Planted.Original, IfThen(Planted.AtExit = $CC, 'would RESTORE', 'sees it changed and leaves it')]);
  var Gateway := '';
  for var Line in Session.Info do
    if Line.StartsWith('E7 gateway=') then
      Gateway := Line;
  if Gateway <> '' then
    Result := Result + '; fixture: ' + Gateway;
end;

procedure RunE7(Fixture: TFixture);
const
  TITLE = 'E7 the program hooks its own routine';
begin
  var EntryText: string;
  var Count: Integer;
  try
    Count := EntryBytesToMove(Fixture, EntryText);
  except
    on E: ERefused do begin
      AddRow(Fixture, TITLE, 'all', '', 'not run: ' + E.Message, 'n/a');
      Exit;
    end;
  end;
  Writeln;
  Writeln(Format('E7 [%s]: the routine starts with %s; the fixture is told to move %d bytes', [Fixture.Bitness,
    EntryText, Count]));

  for var Relocating in [False, True] do begin
    var Args: TArray<string> := ['e7', IntToStr(Count)];
    var Flavour := 'copies the bytes as they are';
    if Relocating then begin
      Args := Args + ['reloc'];
      Flavour := 're-bases a leading jmp rel32, as a hooking library does';
    end;
    var Plain := RunPlain(Fixture, TITLE + ', hook ' + Flavour, Args);
    try
      var Expectation := exBreaks;
      var Expected := 'breaks: the copied jmp rel32 points nowhere';
      if Relocating then begin
        Expectation := exOpen;
        Expected := 'open';
      end;
      RunVariant(Fixture, TITLE, 'A: our jmp on the first line before the hook; hook ' + Flavour, Expectation, Expected,
        Plain, fpPassOn,
        procedure(Session: TSession)
        begin
          Session.InstallJump('entry', Session.Va(Fixture.Marker('E7_BEGIN')), pkCount, False);
        end, SiteAtExit);
      if not Relocating then
        RunVariant(Fixture, TITLE, 'B: an armed one-shot $CC on the first byte when the hook copies it', exBreaks,
          'breaks: the copy traps at an address nobody can map back', Plain, fpPassOn,
          procedure(Session: TSession)
          begin
            Session.InstallBreakpoint('entry', Session.Va(Fixture.Marker('E7_BEGIN')), bkOneShot, nil);
          end,
          function(Session: TSession): string
          begin
            Result := Format('%d breakpoint event(s) at addresses the probe never patched; ', [Session.ForeignBreakpoints]) +
              SiteAtExit(Session);
          end);
    finally
      Plain.Free;
    end;
  end;
end;

{ --------------------------------------------------------------------- main -- }

// One experiment that fails in the probe itself must not take the others with it.
procedure Attempt(Fixture: TFixture; const Experiment, Title: string; Body: TProc);
begin
  if not Wanted(Experiment) then
    Exit;
  try
    Body();
  except
    on E: Exception do begin
      Writeln(Format('  PROBE ERROR in %s: %s: %s', [Title, E.ClassName, E.Message]));
      AddRow(Fixture, Title, 'all', '', 'probe error: ' + E.Message, 'n/a');
    end;
  end;
end;

procedure RunFixture(Fixture: TFixture);
type
  TCase = record
    Experiment, Title, Switch, Marker: string;
  end;
const
  E1_CASES: array[0..2] of TCase = (
    (Experiment: 'e1'; Title: 'E1 patch at a return address, raise in the callee'; Switch: 'e1'; Marker: 'E1'),
    (Experiment: 'e1'; Title: 'E1 deep: the raise two calls below the patched frame'; Switch: 'e1deep'; Marker: 'E1D'),
    (Experiment: 'e1'; Title: 'E1 through: the patched frame has no handler of its own'; Switch: 'e1thru'; Marker: 'E1T'));
  E2_CASES: array[0..2] of TCase = (
    (Experiment: 'e2'; Title: 'E2 epilogue at a return address, unoptimised routine'; Switch: 'e2p'; Marker: 'E2P'),
    (Experiment: 'e2'; Title: 'E2 epilogue at a return address, routine that saves registers'; Switch: 'e2r'; Marker: 'E2R'),
    (Experiment: 'e2'; Title: 'E2 epilogue at a return address, optimised routine without a frame pointer'; Switch: 'e2l'; Marker: 'E2L'));
  E3_CASES: array[0..3] of TCase = (
    (Experiment: 'e3'; Title: 'E3 fault inside try..except'; Switch: 'e3x'; Marker: 'E3X_FAULT'),
    (Experiment: 'e3'; Title: 'E3 fault inside try..finally, outer handler'; Switch: 'e3f'; Marker: 'E3F_FAULT'),
    (Experiment: 'e3'; Title: 'E3 fault on the first instruction of the statement (optimised leaf)'; Switch: 'e3r'; Marker: 'E3R_FAULT'),
    (Experiment: 'e3'; Title: 'E3 the same statement, no fault in the program'; Switch: 'e3ok'; Marker: 'E3X_FAULT'));
  E5_CASES: array[0..2] of TCase = (
    (Experiment: 'e5'; Title: 'E5 indirect call, last instruction of the try body'; Switch: 'e5e'; Marker: 'E5E_CALL'),
    (Experiment: 'e5'; Title: 'E5 indirect call in the middle of the try body'; Switch: 'e5m'; Marker: 'E5M_CALL'),
    (Experiment: 'e5'; Title: 'E5 indirect call, last instruction before the try body'; Switch: 'e5b'; Marker: 'E5B_CALL'));
begin
  Writeln;
  Writeln(StringOfChar('#', 100));
  Writeln(Format('# %s  (%s), source %s', [Fixture.ExePath, Fixture.Bitness, Fixture.SourcePath]));
  Writeln(StringOfChar('#', 100));
  for var Item in E1_CASES do begin
    var This := Item;
    Attempt(Fixture, This.Experiment, This.Title,
      procedure
      begin
        RunE1(Fixture, This.Title, This.Switch, This.Marker);
      end);
  end;
  for var Item in E2_CASES do begin
    var This := Item;
    Attempt(Fixture, This.Experiment, This.Title,
      procedure
      begin
        RunE2(Fixture, This.Title, This.Switch, This.Marker);
      end);
  end;
  for var Item in E3_CASES do begin
    var This := Item;
    Attempt(Fixture, This.Experiment, This.Title,
      procedure
      begin
        RunE3(Fixture, This.Title, This.Switch, This.Marker, This.Switch <> 'e3ok');
      end);
  end;
  Attempt(Fixture, 'e4', 'E4',
    procedure
    begin
      RunE4(Fixture);
    end);
  for var Item in E5_CASES do begin
    var This := Item;
    Attempt(Fixture, This.Experiment, This.Title,
      procedure
      begin
        RunE5(Fixture, This.Title, This.Switch, This.Marker);
      end);
  end;
  for var Form := Low(TSiteForm) to High(TSiteForm) do begin
    var ThisForm := Form;
    Attempt(Fixture, 'e6', 'E6',
      procedure
      begin
        RunE6(Fixture, ThisForm);
      end);
  end;
  Attempt(Fixture, 'e7', 'E7',
    procedure
    begin
      RunE7(Fixture);
    end);
end;

procedure PrintTables;
begin
  for var Bitness in ['x64', 'x86'] do begin
    var Any := False;
    for var Row in GRows do
      if Row.Bitness = Bitness then
        Any := True;
    if not Any then
      Continue;
    Writeln;
    Writeln(Format('## %s', [Bitness]));
    Writeln;
    Writeln('| experiment | variant | expected by the plan | observed | verdict |');
    Writeln('|---|---|---|---|---|');
    for var Row in GRows do
      if Row.Bitness = Bitness then
        Writeln(Format('| %s | %s | %s | %s | %s |', [Row.Experiment, Row.Variant, Row.Expected, Row.Observed, Row.Verdict]));
  end;
end;

procedure Main;
begin
  var SourcePath := '';
  var ZydisDll := '';
  var Fixtures: TArray<string> := nil;
  var Index := 1;
  while Index <= ParamCount do begin
    var Argument := ParamStr(Index);
    if SameText(Argument, '-only') then begin
      GOnly := ParamStr(Index + 1).Split([',']);
      Inc(Index);
    end
    else if SameText(Argument, '-timeout') then begin
      GTimeoutMs := Cardinal(StrToIntDef(ParamStr(Index + 1), 15)) * 1000;
      Inc(Index);
    end
    else if SameText(Argument, '-floodlimit') then begin
      GFloodLimit := StrToIntDef(ParamStr(Index + 1), 300);
      Inc(Index);
    end
    else if SameText(Argument, '-src') then begin
      SourcePath := ParamStr(Index + 1);
      Inc(Index);
    end
    else if SameText(Argument, '-zydisdll') then begin
      ZydisDll := ParamStr(Index + 1);
      Inc(Index);
    end
    else
      Fixtures := Fixtures + [Argument];
    Inc(Index);
  end;
  if Length(Fixtures) = 0 then begin
    Writeln('usage: PatchFeasibilityProbe [-only e1,e3,...] [-timeout <s>] [-floodlimit <n>] [-src <fixture.dpr>]');
    Writeln('                             [-zydisdll <path>] <fixture.exe> [<fixture.exe> ...]');
    ExitCode := 2;
    Exit;
  end;
  if not ZydisTryLoad(ResolveZydisDll(ZydisDll)) then
    raise Exception.Create(ZydisStatusText);

  Writeln('PatchFeasibilityProbe: ', MachineDescription);
  Writeln(ZydisStatusText);
  GRows := TList<TRow>.Create;
  try
    for var Path in Fixtures do begin
      var Fixture := TFixture.Create(Path, SourcePath);
      try
        RunFixture(Fixture);
      finally
        Fixture.Free;
      end;
    end;
    PrintTables;
  finally
    GRows.Free;
  end;
end;

begin
  // Inherited by every target this probe starts: no Windows error box and no
  // Error Reporting dialog from a fixture (docs/TRAPS.md).
  SetErrorMode(GetErrorMode or SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX);
  try
    Main;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
