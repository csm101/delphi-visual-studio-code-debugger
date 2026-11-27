unit CodePatchTests;

// The patch map and the one-shot form (docs/PROFILER_COVERAGE_PLAN.md,
// increment 5; docs/DAP_DEBUGGER_ARCHITECTURE.md, "Code patches"). A one-shot
// probe is a $CC on the first byte of a line record that the debugger takes
// away at its first hit and records by (module, RVA), without reporting a
// stop. What is pinned here:
//
//   1. THE MAP ITSELF, without a process: runs instead of single bytes, the
//      overlay, compare-before-restore, the purge at unload, the program's own
//      `int 3`.
//   2. THE PROBES AGREE WITH THE PROGRAM. ProfilerSample keeps its own record
//      of which marked lines ran; the probes must say the same for every one of
//      them, the lines that ran and the ones that did not -- and the program
//      must compute what it computes undisturbed.
//   3. ONE ADDRESS, TWO OWNERS. A breakpoint and a probe on one address, in
//      both orders; either one taken away leaves the other working and no byte
//      of the debugger behind.
//   4. STEPPING across lines whose probes have not fired lands where it lands
//      without probes; a step at an exception stop reads the handler stub as
//      code; and a re-arm single step of ANOTHER thread does not drive the
//      step in flight.
//   5. RACES. Several threads through lines that never ran, so that two of
//      them meet at every probe; a trap that arrives after its probe was taken
//      away.
//   6. MODULES. A package loaded, unloaded and loaded again; a module the
//      loader relocates after its load event; the main executable asked for
//      before the process exists.
//   7. THE DEBUGGER'S OWN CALLS run through probes without recording them.
//   8. ATTACH AND DETACH. Refused on a process that would survive a dead
//      debugger, unless accepted; a clean detach leaves a program that runs on
//      through lines that were armed, with the traps that were queued put
//      back.
//   9. READERS OF CODE see the program under an armed probe; a memory WRITE
//      over a probe makes the byte the program's, for the map as well.
//  10. THE REQUESTS. Armed while the MAP that names the bodies of anonymous
//      methods is still indexing, a request gets those bodies once it is
//      ready (x86; no process, the engine is a recording fake).
//
// Protocol-free: every test drives TDebugSession directly. The fixture is
// DebuggerTests\TestTarget\ProfilerSample.dpr, with the existing
// TestPackage.bpl and BreakpointSampleLib.dll for the module scenarios.
//
// Tests that run on both bitnesses COLLECT their failures instead of asserting
// per binary: the executables carry the same name, and a first-failure abort
// would hide the other one (docs/TRAPS.md).

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  [TestFixture]
  TCodePatchTests = class
  private
    FProblems: TList<string>;
    procedure Check(Condition: Boolean; const Problem: string);
    procedure AssertNoProblems;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // --- 1. the map, without a process ---
    [Test] procedure Map_ArmsInRunsNotByteByByte_AndTheOverlayShowsTheProgram;
    [Test] procedure Map_RestoreComparesFirst_AByteTheProgramChangedIsLeftAlone;
    [Test] procedure Map_UnloadDropsWithoutWriting_KeepsTheHits_AndDoesNotArmThemAgain;
    [Test] procedure Map_TheProgramsOwnBreakpointInstruction_IsRefused;
    [Test] procedure Map_AByteABreakpointHolds_IsSharedNotWritten;
    [Test] procedure Map_AWriteThatFailsPartWay_TracksTheBytesItWrote;

    // --- 2. the probes agree with the program ---
    [Test] procedure Probes_AgreeWithTheProgramsOwnRecord_LineForLine;
    [Test] procedure MainExecutable_AskedForBeforeTheProcess_IsArmedBeforeItsCodeRuns;
    [Test] procedure ProgramsOwnInt3_IsNeverArmed_AndIsAnnouncedOnlyWhileProbesAreArmed;

    // --- 3. one address, two owners ---
    [Test] procedure ProbeThenBreakpoint_BothGetTheHit_AndRemovingTheBreakpointLeavesNoByte;
    [Test] procedure BreakpointThenProbe_TheProbeSharesTheByte_AndBothGetTheHit;
    [Test] procedure BreakpointRemovedBeforeTheProbeFires_TheProbeKeepsTheByteAndFires;
    [Test] procedure ProbeTakenAwayUnderABreakpoint_TheBreakpointKeepsStopping;
    [Test] procedure ResumedFromALineWithBreakpointAndProbe_TheLineRunsOnceAndBothWork;
    [Test] procedure ParkedOnAProbeAnotherThreadGaveBack_TheThreadRunsTheInstructionOnce;

    // --- 4. stepping ---
    [Test] procedure Steps_AcrossLinesThatHaveNotFired_LandWhereTheyLandWithoutProbes;
    [Test] procedure StepAtAnExceptionStop_WithAProbeOnTheHandlerStub_LandsInTheHandler;
    [Test] procedure StepOver_WhileAnotherThreadRunsThroughALogpoint_LandsOnItsOwnThread;

    // --- 5. races ---
    [Test] procedure SeveralThreadsThroughLinesNeverExecuted_EveryThreadRunsEveryLineOnce;
    [Test] procedure TrapQueuedBeforeTheProbesAreTakenAway_IsRewoundNotHandedToTheProgram;

    // --- 6. modules ---
    [Test] procedure Package_LoadedUnloadedLoadedAgain_IsArmedAtEachLoadAndKeepsItsHits;
    [Test] procedure ModuleRelocatedAfterItsLoadEvent_IsArmedAtItsEntryPoint;
    [Test] procedure Package_UnloadedByAnEvaluationThenReloaded_IsArmedAgain;

    // --- 7. the debugger's own calls ---
    [Test] procedure Evaluation_ThatRunsProbedLines_LeavesThemUnrecordedAndArmed;

    // --- 8. attach and detach ---
    [Test] procedure AttachArmDetach_RefusedWithoutAcceptance_ThenTheProgramRunsOnThroughArmedLines;
    [Test] procedure Detach_WithTrapsQueued_PutsEveryThreadBackOnItsInstruction;
    [Test] procedure Detach_AtAPauseStop_ReleasesTheHeldEvent_AndTheQueuedTrapsAreRewound;
    [Test] procedure Terminate_AtAPauseStop_EndsTheProcessWithoutWaiting;
    [Test] procedure Detach_WithASoftwareBreakpointExceptionQueued_HandsItToTheProgram;

    // --- 9. readers and writers of code ---
    [Test] procedure CodeReaders_SeeTheProgramUnderAnArmedProbe;
    [Test] procedure MemoryWrittenOverAProbe_IsTheProgramsAndABreakpointPlantedThereFires;
    [Test] procedure ProgramRewritesAProbedByte_ReadersShowItsByte_AndABreakpointThereFires;

    // --- 10. the requests (x86 only: the second routine provider) ---
    [Test] procedure Request_ArmedWhileTheMapIndexes_ArmsTheAnonymousBodiesOnceItIsReady;
  end;

implementation

uses
  Winapi.Windows, System.IOUtils,
  DebugTarget, DebugInfoTypes, DebugSessionTypes, DebugSession,
  TD32FileReader, MapFileReader, CodeMap, Disassembler, ZydisDisassembler, PeImageFile, RoutineAnalysis,
  LiveCodeAnalysis, CodePatchMap, LineProbes, TestTempDirs;

const
  SAMPLE_NAME     = 'ProfilerSample';
  SAMPLE_SOURCE   = 'ProfilerSample.dpr';
  PACKAGE_NAME    = 'TestPackage.bpl';
  PACKAGE_SOURCE  = 'TestPkgUnit.pas';
  LIB_NAME        = 'BreakpointSampleLib.dll';
  LIB_SOURCE      = 'BreakpointSampleLib.dpr';
  STOP_TIMEOUT_MS = 30000;
  MAX_STOPS       = 64;
  SCRATCH_PREFIX  = 'codepatch';
  INT3            = $CC;
  // The numbers ProfilerSample.dpr runs with.
  MAX_MARK        = 127;
  LONG_RUN_LINES  = 160;
  LAYER_PASSES    = 5;
  STEP_RACE_TICKS = 20;
  // What the engine says in its notice about a breakpoint instruction it did
  // not plant.
  FOREIGN_INT3_NOTICE = 'was not planted by the debugger';
  THREAD_SUSPEND_RESUME = $0002;

function OpenThread(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwThreadId: DWORD): THandle;
  stdcall; external kernel32 name 'OpenThread';


type
  TTargetBinary = record
    Caption:    string;
    Exe:        string;
    Map:        string;
    Rsm:        string;
    SourceRoot: string;
    Is64:       Boolean;
  end;

  // Receives the exit code of the program under test and the last stop. "The
  // process is gone" does not tell a program that ran to its end from one that
  // died on a breakpoint byte nobody took back; the exit code does.
  TSessionWatcher = class
  public
    Exited:     Boolean;
    Code:       Integer;
    LastReason: TStopReason;
    LastTid:    Cardinal;
    procedure Reset;
    procedure HandleExit(ExitCode: Integer);
    procedure HandleStop(const Info: TStopInfo);
  end;

  // A module read as a FILE: where the records of each source line are, and the
  // program's own bytes. Module-relative addresses, so the same numbers hold
  // for the live module wherever it is loaded.
  TModuleFile = class
  private
    FImage: TPeImageFile;
    FKeep:  IInterface;
    FMap:   TModuleCodeMap;
    FFiles: TArray<Integer>;
  public
    constructor Create(const ModulePath, SourceName: string);
    destructor Destroy; override;
    function RvasOfLine(Line: Integer): TArray<Cardinal>;
    function LineOfRva(Rva: Cardinal): Integer;
    function ProgramByte(Rva: Cardinal): Byte;
    function RoutineNamed(const NamePart: string): Integer;
    property Map: TModuleCodeMap read FMap;
    property Image: TPeImageFile read FImage;
  end;

  // What ProfilerSample wrote about itself.
  TProgramRecord = record
    Valid: Boolean;
    Sink:  string;
    Ran:   array[0..MAX_MARK] of Boolean;
  end;

  // A fake target for the tests of the map alone: one module of bytes, every
  // read and write counted.
  TFakeMemory = class
  public
    Base:       UInt64;
    Bytes:      TArray<Byte>;
    Mapped:     Boolean;
    Reads:      Integer;
    Writes:     Integer;
    BytesWritten: Integer;
    // When >= 0: a write puts at most this many bytes and then fails, as
    // WriteProcessMemory does at the first page it cannot write.
    WriteLimit: Integer;
    constructor Create(ABase: UInt64; Size: Integer);
    function Access: TCodePatchMemory;
  end;

var
  // The tests of this unit run one session at a time, on one thread.
  GWatch: TSessionWatcher;
  // What an undisturbed run of the default scenario writes, per bitness.
  GReference: array[Boolean] of TProgramRecord;

{ TSessionWatcher }

procedure TSessionWatcher.Reset;
begin
  Exited     := False;
  Code       := 0;
  LastReason := srEntry;
  LastTid    := 0;
end;

procedure TSessionWatcher.HandleExit(ExitCode: Integer);
begin
  Exited := True;
  Code   := ExitCode;
end;

procedure TSessionWatcher.HandleStop(const Info: TStopInfo);
begin
  LastReason := Info.Reason;
  LastTid    := Info.OsThreadId;
end;

{ TFakeMemory }

constructor TFakeMemory.Create(ABase: UInt64; Size: Integer);
begin
  inherited Create;
  Base   := ABase;
  Mapped := True;
  WriteLimit := -1;
  SetLength(Bytes, Size);
  // Nothing that looks like a breakpoint instruction.
  for var I := 0 to Size - 1 do
    Bytes[I] := Byte($10 + (I mod 97));
end;

function TFakeMemory.Access: TCodePatchMemory;
begin
  Result.Read :=
    function(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean
    begin
      Inc(Reads);
      if (not Mapped) or (VA < Base) or (VA - Base + Size > UInt64(Length(Bytes))) then
        Exit(False);
      Move(Bytes[VA - Base], Buf^, Size);
      Result := True;
    end;
  Result.Write :=
    function(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean
    begin
      Inc(Writes);
      if (not Mapped) or (VA < Base) or (VA - Base + Size > UInt64(Length(Bytes))) then
        Exit(False);
      if (WriteLimit >= 0) and (Size > NativeUInt(WriteLimit)) then begin
        Move(Buf^, Bytes[VA - Base], WriteLimit);
        Inc(BytesWritten, WriteLimit);
        Exit(False);
      end;
      Inc(BytesWritten, Integer(Size));
      Move(Buf^, Bytes[VA - Base], Size);
      Result := True;
    end;
  Result.Query :=
    function(VA: UInt64; out Region: TCodePatchRegion): Boolean
    begin
      Region := Default(TCodePatchRegion);
      Region.Base := Base;
      Region.Size := UInt64(Length(Bytes));
      Region.Accessible := Mapped and (VA >= Base) and (VA - Base < UInt64(Length(Bytes)));
      Result := True;
    end;
end;

{ TModuleFile }

constructor TModuleFile.Create(const ModulePath, SourceName: string);
begin
  inherited Create;
  Assert.IsTrue(FileExists(ModulePath), 'fixture missing at ' + ModulePath + ' -- run build_and_run.bat');
  FImage := TPeImageFile.Create(ModulePath);
  var Reader := TTD32FileReader.Create;
  FKeep := Reader;
  Reader.LoadFromFile(ModulePath);
  var LineProvider: ILineRecordProvider;
  var RoutineProvider: IRoutineRangeProvider;
  Assert.IsTrue(TModuleCodeMap.PickProviders([FKeep], LineProvider, RoutineProvider),
    ModulePath + ': no line records with routine ranges in its debug information');
  FMap := TModuleCodeMap.Build(ExtractFileName(ModulePath), LineProvider, RoutineProvider, 0,
    FImage.SizeOfImage);
  FFiles := FMap.FindFiles(SourceName);
  Assert.IsTrue(Length(FFiles) > 0, ModulePath + ': no line records of ' + SourceName);
end;

destructor TModuleFile.Destroy;
begin
  FMap.Free;
  FKeep := nil;
  FImage.Free;
  inherited;
end;

function TModuleFile.RvasOfLine(Line: Integer): TArray<Cardinal>;
begin
  Result := nil;
  for var FileIndex in FFiles do
    for var Index in FMap.LinesAt(FileIndex, Line) do
      Result := Result + [FMap.Lines[Index].Rva];
end;

function TModuleFile.LineOfRva(Rva: Cardinal): Integer;
begin
  Result := 0;
  var Index := FMap.FindLine(Rva);
  if Index < 0 then
    Exit;
  for var FileIndex in FFiles do
    if FMap.Lines[Index].FileIndex = FileIndex then
      Exit(FMap.Lines[Index].Line);
end;

function TModuleFile.ProgramByte(Rva: Cardinal): Byte;
begin
  Result := 0;
  Assert.AreEqual(1, FImage.Read(FImage.ImageBase + Rva, @Result, 1),
    Format('the byte at RVA $%x of the image file could not be read', [Rva]));
end;

function TModuleFile.RoutineNamed(const NamePart: string): Integer;
begin
  for var I := 0 to High(FMap.Routines) do
    if FMap.Routines[I].Name.Contains(NamePart) then
      Exit(I);
  Result := -1;
end;

{ helpers }

function RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function BitnessDir(Is64: Boolean): string;
begin
  Result := 'Win32';
  if Is64 then
    Result := 'Win64';
end;

function SampleBinary(Is64: Boolean): TTargetBinary;
begin
  Result := Default(TTargetBinary);
  Result.Caption    := SAMPLE_NAME + ' ' + BitnessDir(Is64);
  Result.Exe        := TargetDir + BitnessDir(Is64) + '\Debug\' + SAMPLE_NAME + '.exe';
  Result.Map        := ChangeFileExt(Result.Exe, '.map');
  Result.Rsm        := ChangeFileExt(Result.Exe, '.rsm');
  Result.SourceRoot := TargetDir;
  Result.Is64       := Is64;
end;

function ModuleKey(const Binary: TTargetBinary): string;
begin
  Result := LowerCase(ExtractFileName(Binary.Exe));
end;

// 1-based number of the first line of a file that contains Fragment, or 0.
function LineContaining(const SourcePath, Fragment: string): Integer;
begin
  Result := 0;
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Fragment) then
        Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

function MarkerLineIn(const SourcePath, Marker: string): Integer;
begin
  Result := LineContaining(SourcePath, '{BP:' + Marker + '}');
  Assert.IsTrue(Result > 0, Format('marker %s not found in %s', [Marker, SourcePath]));
end;

function MarkerLine(const Marker: string): Integer;
begin
  Result := MarkerLineIn(TargetDir + SAMPLE_SOURCE, Marker);
end;

// Source line of every `Ran(n)` / `RanByAThread(n)` statement of the fixture,
// by n; 0 where there is none. Each stands alone on its line.
function MarkLines: TArray<Integer>;
begin
  SetLength(Result, MAX_MARK + 1);
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(TargetDir + SAMPLE_SOURCE);
    for var I := 0 to Lines.Count - 1 do begin
      var Text := Lines[I].Trim;
      var Rest := '';
      if Text.StartsWith('Ran(') then
        Rest := Text.Substring(4)
      else if Text.StartsWith('RanByAThread(') then
        Rest := Text.Substring(13)
      else
        Continue;
      var Close := Rest.IndexOf(')');
      var Mark := StrToIntDef(Rest.Substring(0, Close), -1);
      if (Mark < 0) or (Mark > MAX_MARK) then
        Continue;
      Assert.AreEqual(0, Result[Mark], Format('mark %d appears twice in %s', [Mark, SAMPLE_SOURCE]));
      Result[Mark] := I + 1;
    end;
  finally
    Lines.Free;
  end;
end;

function LineSpecs(const Lines: array of Integer): TArray<TBpLineSpec>;
begin
  SetLength(Result, Length(Lines));
  for var I := 0 to High(Lines) do begin
    Result[I] := Default(TBpLineSpec);
    Result[I].Line := Lines[I];
  end;
end;

function ReadProgramRecord(const Path: string): TProgramRecord;
begin
  Result := Default(TProgramRecord);
  if not FileExists(Path) then
    Exit;
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    for var Line in Lines do begin
      var Split := Line.IndexOf('=');
      if Split < 0 then
        Continue;
      var Name := Line.Substring(0, Split);
      var Value := Line.Substring(Split + 1);
      if Name = 'sink' then begin
        Result.Sink  := Value;
        Result.Valid := True;
        Continue;
      end;
      var Mark := StrToIntDef(Name, -1);
      if (Mark >= 0) and (Mark <= MAX_MARK) then
        Result.Ran[Mark] := Value = '1';
    end;
  finally
    Lines.Free;
  end;
end;

// Starts the fixture with NO debugger and waits for it.
function RunUndebugged(const Binary: TTargetBinary; const Args: string; out ExitCode: DWORD): Boolean;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  ExitCode := DWORD(-1);
  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  var CmdLine := '"' + Binary.Exe + '" ' + Args;
  UniqueString(CmdLine);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, PI) then
    Exit(False);
  CloseHandle(PI.hThread);
  try
    Result := WaitForSingleObject(PI.hProcess, 30000) = WAIT_OBJECT_0;
    if Result then
      GetExitCodeProcess(PI.hProcess, ExitCode)
    else
      TerminateProcess(PI.hProcess, 9);
  finally
    CloseHandle(PI.hProcess);
  end;
end;

// What the default scenario writes when nothing touches the program. Measured
// once per bitness, with no debugger at all.
function ReferenceRecord(Is64: Boolean): TProgramRecord;
begin
  if GReference[Is64].Valid then
    Exit(GReference[Is64]);
  var Binary := SampleBinary(Is64);
  Assert.IsTrue(FileExists(Binary.Exe), Binary.Caption + ': fixture missing at ' + Binary.Exe);
  var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
  try
    var OutFile := Dir + '\reference.txt';
    var ExitCode: DWORD;
    Assert.IsTrue(RunUndebugged(Binary, '-out "' + OutFile + '"', ExitCode) and (ExitCode = 0),
      Format('%s: the undebugged reference run did not end normally (exit code %d)',
        [Binary.Caption, Integer(ExitCode)]));
    GReference[Is64] := ReadProgramRecord(OutFile);
    Assert.IsTrue(GReference[Is64].Valid, Binary.Caption + ': the reference run wrote no record');
  finally
    DeleteTempDirWithRetry(Dir);
  end;
  Result := GReference[Is64];
end;

// Launches the fixture with every exception filter off: the scenarios raise on
// purpose. IsolationMs is the step isolation (MaxInt leaves the default).
function LaunchSample(const Binary: TTargetBinary; StopAtEntry: Boolean; const Args: string = '';
  WithMap: Boolean = True; IsolationMs: Integer = MaxInt): TDebugSession;
begin
  Assert.IsTrue(FileExists(Binary.Exe),
    Binary.Caption + ': fixture missing at ' + Binary.Exe + ' -- run build_and_run.bat');
  Result := TDebugSession.Create;
  try
    GWatch.Reset;
    Result.OnSessionExited  := GWatch.HandleExit;
    Result.OnSessionStopped := GWatch.HandleStop;
    var Opts := Default(TLaunchOptions);
    Opts.ExePath    := Binary.Exe;
    Opts.MapPath    := Binary.Map;
    if not WithMap then
      Opts.MapPath  := ChangeFileExt(Binary.Exe, '.no-such-map');
    Opts.RsmPath    := Binary.Rsm;
    Opts.SourceRoot := Binary.SourceRoot;
    Opts.Args       := Args;
    Opts.StopAtEntry         := StopAtEntry;
    Opts.ExceptionFilters    := Default(TExceptionFilters);
    Opts.ExceptionFiltersSet := True;
    if IsolationMs <> MaxInt then begin
      Opts.StepIsolationSet       := True;
      Opts.StepIsolationReleaseMs := IsolationMs;
    end;
    Assert.IsTrue(Result.Launch(Opts), Binary.Caption + ': Launch returned False');
  except
    Result.Free;
    raise;
  end;
end;

procedure PumpUntilStoppedOrExited(Session: TDebugSession; TimeoutMs: Cardinal = STOP_TIMEOUT_MS);
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while (Session.State <> dsStopped) and (not Session.HasExited) and (GetTickCount64 < Deadline) do
    Session.Pump;
end;

procedure PumpFor(Session: TDebugSession; Milliseconds: Cardinal);
begin
  var Deadline := GetTickCount64 + Milliseconds;
  while (not Session.HasExited) and (GetTickCount64 < Deadline) do
    Session.Pump;
end;

procedure EndSession(var Session: TDebugSession);
begin
  if Session = nil then
    Exit;
  try
    if not Session.HasExited then
      Session.Terminate;
  finally
    FreeAndNil(Session);
  end;
end;

function StoppedAtEntry(const Binary: TTargetBinary; const Args: string = ''; WithMap: Boolean = True;
  IsolationMs: Integer = MaxInt): TDebugSession;
begin
  Result := LaunchSample(Binary, True, Args, WithMap, IsolationMs);
  try
    PumpUntilStoppedOrExited(Result);
    Assert.AreEqual(Ord(dsStopped), Ord(Result.State), Binary.Caption + ': did not stop at entry');
  except
    EndSession(Result);
    raise;
  end;
end;

// Source breakpoints of the fixture. The session only POSTS them; at a stop
// one turn of the pump has the engine write (or take back) the bytes, which is
// what a test that looks at the bytes needs to have happened.
procedure SetLines(Session: TDebugSession; const Specs: TArray<TBpLineSpec>);
begin
  Session.SetBreakpoints(SAMPLE_SOURCE, Specs);
  if Session.State = dsStopped then
    Session.Pump;
end;

function CurrentLine(Session: TDebugSession): Integer;
begin
  var FnName, SrcFile: string;
  Result := 0;
  Session.GetCurrentLocation(FnName, SrcFile, Result);
end;

// Continues to the next stop; False when the program ended or nothing came.
function RunToNextStop(Session: TDebugSession): Boolean;
begin
  if Session.State = dsStopped then
    Session.ContinueExecution;
  PumpUntilStoppedOrExited(Session);
  Result := (not Session.HasExited) and (Session.State = dsStopped);
end;

// Runs a session to the end of the program, returning the line of every stop
// on the way. Ended is True only when the program exited with code 0.
function RunToTheEnd(Session: TDebugSession; out Ended: Boolean): TArray<Integer>;
begin
  Result := nil;
  Ended := False;
  for var Round := 0 to MAX_STOPS do begin
    if not RunToNextStop(Session) then begin
      Ended := Session.HasExited and GWatch.Exited and (GWatch.Code = 0);
      Exit;
    end;
    Result := Result + [CurrentLine(Session)];
  end;
end;

function HowItEnded: string;
begin
  if not GWatch.Exited then
    Exit('it was still running');
  Result := Format('it exited with code %d ($%x)', [GWatch.Code, Cardinal(GWatch.Code)]);
end;

function CountOf(const Lines: TArray<Integer>; Line: Integer): Integer;
begin
  Result := 0;
  for var Item in Lines do
    if Item = Line then
      Inc(Result);
end;

function LinesText(const Lines: TArray<Integer>): string;
begin
  Result := '';
  for var Line in Lines do
    Result := Result + IntToStr(Line) + ' ';
  Result := Result.Trim;
  if Result = '' then
    Result := '(none)';
end;

function Contains(const Rvas: TArray<Cardinal>; Rva: Cardinal): Boolean;
begin
  var Index: NativeInt;
  Result := TArray.BinarySearch<Cardinal>(Rvas, Rva, Index);
end;

function AnyOf(const Wanted, Sorted: TArray<Cardinal>): Boolean;
begin
  for var Rva in Wanted do
    if Contains(Sorted, Rva) then
      Exit(True);
  Result := False;
end;

// Both sorted or not: the two sets as one sorted array.
function SortedUnion(const A, B: TArray<Cardinal>): TArray<Cardinal>;
begin
  Result := A + B;
  TArray.Sort<Cardinal>(Result);
end;

function PatchTarget(Session: TDebugSession): ICodePatchTarget;
begin
  Assert.IsTrue(Supports(Session.Debugger, ICodePatchTarget, Result),
    'the engine does not implement ICodePatchTarget');
end;

// The byte in the target as it IS, read past the engine; -1 when it cannot be
// read (the process is gone). Not an assertion: a test that collects its
// problems must still report the ones it found before the process died.
function RawByte(Session: TDebugSession; VA: UInt64): Integer;
var
  Got: SIZE_T;
begin
  var Value: Byte := 0;
  if (Session.Debugger = nil) or
     not (ReadProcessMemory(Session.Debugger.ProcessHandle, Pointer(VA), @Value, 1, Got) and (Got = 1)) then
    Exit(-1);
  Result := Value;
end;

// A request for every line record of a module. An index still being built is
// waited for first (bounded): on x86 the body of an anonymous method is
// confirmed only once the MAP names it.
function ArmWholeModule(Session: TDebugSession; const ModuleName: string;
  out Report: TLineProbeReport; Accept: Boolean = False): Boolean;
begin
  var Deadline := GetTickCount64 + 15000;
  while Session.DebugInfo.AnyBackgroundIndexingPending and (GetTickCount64 < Deadline) do
    Sleep(5);
  var Request := Default(TLineProbeRequest);
  Request.ModuleName  := ModuleName;
  Request.WholeModule := True;
  Request.AcceptBreakpointBytesLeftBehindIfTheDebuggerDies := Accept;
  Result := Session.LineProbes.Arm(Request, Report);
end;

function DescribeReport(const Report: TLineProbeReport): string;
begin
  Result := Format('state %d, armed at "%s", %d confirmed, %d armed, note "%s"',
    [Ord(Report.State), Report.ArmedAt, Report.Tally.Confirmed, Report.Outcome.Armed, Report.Note]);
end;

{ TCodePatchTests }

procedure TCodePatchTests.Setup;
begin
  FProblems := TList<string>.Create;
  PurgeLeftoverTempDirs(SCRATCH_PREFIX);
end;

procedure TCodePatchTests.TearDown;
begin
  FreeAndNil(FProblems);
end;

procedure TCodePatchTests.Check(Condition: Boolean; const Problem: string);
begin
  if not Condition then
    FProblems.Add(Problem);
end;

procedure TCodePatchTests.AssertNoProblems;
begin
  if FProblems.Count = 0 then
    Exit;
  Assert.Fail(Format('%d problem(s): ', [FProblems.Count]) + string.Join(' | ', FProblems.ToArray));
end;

{ 1. the map, without a process }

procedure TCodePatchTests.Map_ArmsInRunsNotByteByByte_AndTheOverlayShowsTheProgram;
// 3 000 probes eight bytes apart cover 24 KB: one run, so one read and one
// write, not 3 000. A second group a megabyte further on is a run of its own:
// the bytes between two runs are never rewritten.
const
  BASE       = UInt64($140000000);
  NEAR_COUNT = 3000;
  FAR_AT     = $100000;
begin
  var Memory := TFakeMemory.Create(BASE, $110000);
  var Map := TCodePatchMap.Create(Memory.Access);
  try
    var Program_ := Copy(Memory.Bytes);
    var Rvas: TArray<Cardinal>;
    SetLength(Rvas, NEAR_COUNT + 2);
    for var I := 0 to NEAR_COUNT - 1 do
      Rvas[I] := Cardinal($1000 + I * 8);
    Rvas[NEAR_COUNT]     := FAR_AT;
    Rvas[NEAR_COUNT + 1] := FAR_AT + 5;
    var Outcome: TCodePatchArmOutcome;
    Map.Arm('m', BASE, UInt64(Length(Memory.Bytes)), Rvas, nil, Outcome);
    Assert.AreEqual(NEAR_COUNT + 2, Outcome.Armed, 'probes armed');
    Assert.AreEqual(2, Outcome.Runs, 'runs');
    Assert.AreEqual(2, Outcome.WriteCalls, 'calls that wrote into the target');
    Assert.AreEqual(2, Memory.Writes, 'writes the fake target saw');
    Assert.IsTrue(Memory.BytesWritten < $8000, Format('%d bytes were written for 24 KB of probes: ' +
      'the megabyte between the two runs was rewritten', [Memory.BytesWritten]));
    for var Rva in Rvas do
      Assert.AreEqual(INT3, Integer(Memory.Bytes[Rva]), Format('the byte at $%x is not a probe', [Rva]));
    Assert.AreEqual(Integer(Program_[$1001]), Integer(Memory.Bytes[$1001]), 'a byte between two probes changed');

    // The overlay gives the program's bytes for any window, also one that
    // starts or ends in the middle of the run.
    var Window: TArray<Byte>;
    SetLength(Window, $3000);
    Move(Memory.Bytes[$0FF0], Window[0], Length(Window));
    Map.Overlay(BASE + $0FF0, @Window[0], Length(Window));
    for var I := 0 to High(Window) do
      if Window[I] <> Program_[$0FF0 + I] then
        Assert.Fail(Format('the overlay left a foreign byte at offset $%x of the window', [I]));

    // A hit takes ONE byte back and leaves the others.
    Assert.AreEqual(Ord(cptArmed), Ord(Map.TrapAt(BASE + $1008)), 'an armed address');
    Map.Fire(BASE + $1008, True);
    Assert.AreEqual(Integer(Program_[$1008]), Integer(Memory.Bytes[$1008]), 'the byte of the probe that fired');
    Assert.AreEqual(INT3, Integer(Memory.Bytes[$1010]), 'the next probe');
    Assert.AreEqual(Ord(cptSpent), Ord(Map.TrapAt(BASE + $1008)), 'a fired address is remembered');
    Assert.AreEqual(Ord(cptNone), Ord(Map.TrapAt(BASE + $1009)), 'an address the map never patched');
    var Hits := Map.Hits('m');
    Assert.AreEqual(1, Integer(Length(Hits)), 'hits');
    Assert.AreEqual(Cardinal($1008), Hits[0], 'the hit');
  finally
    Map.Free;
    Memory.Free;
  end;
end;

procedure TCodePatchTests.Map_RestoreComparesFirst_AByteTheProgramChangedIsLeftAlone;
// A program that hooks a routine overwrites its first bytes -- our $CC with
// them. From then on the byte is the program's: neither a hit nor taking the
// probes away may write the old byte back over it.
const
  BASE = UInt64($400000);
begin
  var Memory := TFakeMemory.Create(BASE, $4000);
  var Map := TCodePatchMap.Create(Memory.Access);
  try
    var Outcome: TCodePatchArmOutcome;
    Map.Arm('m', BASE, $4000, [$1000, $1010, $1020], nil, Outcome);
    Assert.AreEqual(3, Outcome.Armed, 'probes armed');
    var ProgramAt1020 := Byte($10 + ($1020 mod 97));
    // The program writes its own bytes over two of them.
    Memory.Bytes[$1000] := $E9;
    Memory.Bytes[$1010] := $E9;
    Map.Fire(BASE + $1000, True);
    Assert.AreEqual($E9, Integer(Memory.Bytes[$1000]), 'a hit wrote over a byte the program had changed');
    var Gone := Map.Disarm(0, nil);
    Assert.AreEqual($E9, Integer(Memory.Bytes[$1010]), 'the disarm wrote over a byte the program had changed');
    Assert.AreEqual(Integer(ProgramAt1020), Integer(Memory.Bytes[$1020]), 'the byte that was still ours');
    Assert.AreEqual(1, Gone.Restored, 'restored');
    Assert.AreEqual(1, Gone.Lost, 'no longer ours');
    Assert.AreEqual(2, Map.Stats.Lost, 'lost in all');
    Assert.AreEqual(0, Map.ArmedCount, 'nothing is armed after the disarm');
    // Still remembered: a trap raised before the disarm arrives after it.
    Assert.AreEqual(Ord(cptSpent), Ord(Map.TrapAt(BASE + $1020)), 'the tombstone of a withdrawn probe');
  finally
    Map.Free;
    Memory.Free;
  end;
end;

procedure TCodePatchTests.Map_UnloadDropsWithoutWriting_KeepsTheHits_AndDoesNotArmThemAgain;
const
  BASE_ONE = UInt64($50000000);
  BASE_TWO = UInt64($51000000);
begin
  var Memory := TFakeMemory.Create(BASE_ONE, $4000);
  var Map := TCodePatchMap.Create(Memory.Access);
  try
    var Outcome: TCodePatchArmOutcome;
    Map.Arm('pkg', BASE_ONE, $4000, [$100, $200, $300], nil, Outcome);
    Map.Fire(BASE_ONE + $100, True);
    // The module goes: its memory is gone, and nothing may be written.
    Memory.Mapped := False;
    var WritesBefore := Memory.Writes;
    Map.ModuleUnloaded(BASE_ONE);
    Assert.AreEqual(WritesBefore, Memory.Writes, 'the unload wrote into memory that is gone');
    Assert.AreEqual(0, Map.ArmedCount, 'armed after the unload');
    Assert.IsFalse(Map.Active, 'the map still claims addresses of a mapping that is gone');
    Assert.AreEqual(Ord(cptNone), Ord(Map.TrapAt(BASE_ONE + $200)), 'an address of the old mapping');
    Assert.AreEqual(1, Integer(Length(Map.Hits('pkg'))), 'the hit must survive the unload');

    // It comes back somewhere else: patched afresh, minus what already ran.
    Memory.Base   := BASE_TWO;
    Memory.Mapped := True;
    Memory.Bytes[$200] := Byte($10 + ($200 mod 97));
    Memory.Bytes[$300] := Byte($10 + ($300 mod 97));
    Map.Arm('pkg', BASE_TWO, $4000, [$100, $200, $300], nil, Outcome);
    Assert.AreEqual(2, Outcome.Armed, 'armed in the second mapping');
    Assert.AreEqual(1, Outcome.AlreadyHit, 'the address that already ran must not be armed again');
    Assert.AreNotEqual(INT3, Integer(Memory.Bytes[$100]), 'a probe was written on a line that already ran');
    Map.Fire(BASE_TWO + $300, True);
    var Hits := Map.Hits('pkg');
    Assert.AreEqual(2, Integer(Length(Hits)), 'hits of both mappings');
    Assert.AreEqual(Cardinal($100), Hits[0], 'first hit');
    Assert.AreEqual(Cardinal($300), Hits[1], 'second hit');
    Map.ProcessGone;
    Assert.AreEqual(2, Integer(Length(Map.Hits('pkg'))), 'the hits must survive the process');
  finally
    Map.Free;
    Memory.Free;
  end;
end;

procedure TCodePatchTests.Map_TheProgramsOwnBreakpointInstruction_IsRefused;
const
  BASE = UInt64($400000);
begin
  var Memory := TFakeMemory.Create(BASE, $2000);
  var Map := TCodePatchMap.Create(Memory.Access);
  try
    Memory.Bytes[$500] := INT3;
    var Outcome: TCodePatchArmOutcome;
    Map.Arm('m', BASE, $2000, [$4F0, $500, $510], nil, Outcome);
    Assert.AreEqual(2, Outcome.Armed, 'armed');
    Assert.AreEqual(1, Outcome.OwnBreakpointInstruction, 'refused as the program''s own breakpoint instruction');
    Assert.AreEqual(1, Integer(Length(Outcome.OwnBreakpointRvas)), 'the refused addresses');
    Assert.AreEqual(Cardinal($500), Outcome.OwnBreakpointRvas[0], 'the refused address');
    Assert.AreEqual(Ord(cptNone), Ord(Map.TrapAt(BASE + $500)),
      'the program''s own int 3 must not be an address the map claims');
  finally
    Map.Free;
    Memory.Free;
  end;
end;

procedure TCodePatchTests.Map_AByteABreakpointHolds_IsSharedNotWritten;
// A breakpoint is planted at $100: the byte there is $CC and the breakpoint
// saved the program's $55. The probe takes the program's byte from the
// breakpoint, writes nothing there, and when it fires leaves the $CC alone.
const
  BASE = UInt64($400000);
begin
  var Memory := TFakeMemory.Create(BASE, $2000);
  var Map := TCodePatchMap.Create(Memory.Access);
  try
    Memory.Bytes[$100] := INT3;
    var Foreign: TCodePatchForeignByte;
    Foreign.VA := BASE + $100;
    Foreign.ProgramByte := $55;
    var Outcome: TCodePatchArmOutcome;
    Map.Arm('m', BASE, $2000, [$100], [Foreign], Outcome);
    Assert.AreEqual(1, Outcome.Armed, 'armed');
    Assert.AreEqual(1, Outcome.SharedWithBreakpoint, 'shared with the breakpoint');
    Assert.AreEqual(0, Outcome.WriteCalls, 'nothing is written where a breakpoint holds the byte');
    var ProgramByte: Byte;
    Assert.IsTrue(Map.HoldsInt3At(BASE + $100, ProgramByte), 'the probe holds the byte');
    Assert.AreEqual($55, Integer(ProgramByte), 'the program''s byte, as the breakpoint saved it');
    // The breakpoint is still planted when the probe fires: the byte stays.
    Map.Fire(BASE + $100, False);
    Assert.AreEqual(INT3, Integer(Memory.Bytes[$100]), 'the breakpoint''s byte was taken away by the probe');
    Assert.IsFalse(Map.HoldsInt3At(BASE + $100, ProgramByte), 'a fired probe holds nothing');
  finally
    Map.Free;
    Memory.Free;
  end;
end;

procedure TCodePatchTests.Map_AWriteThatFailsPartWay_TracksTheBytesItWrote;
// Three probes in one run; the write puts the first $100 bytes and fails, as
// WriteProcessMemory does at the first page it cannot write. The first probe
// IS in the target now: it must be tracked (and come back at a disarm), the
// other two were never written.
const
  BASE = UInt64($400000);
begin
  var Memory := TFakeMemory.Create(BASE, $2000);
  var Map := TCodePatchMap.Create(Memory.Access);
  try
    var Program_ := Copy(Memory.Bytes);
    Memory.WriteLimit := $100;
    var Outcome: TCodePatchArmOutcome;
    Map.Arm('m', BASE, $2000, [$1000, $1200, $1300], nil, Outcome);
    Assert.AreEqual(INT3, Integer(Memory.Bytes[$1000]), 'the fake target did not take the first probe');
    Assert.AreEqual(1, Outcome.Armed, 'probes the failed write did put in the target');
    Assert.AreEqual(2, Outcome.WriteFailed, 'probes the failed write did not put in the target');
    Assert.AreEqual(Ord(cptArmed), Ord(Map.TrapAt(BASE + $1000)), 'a $CC in the target that the map does not know');
    Assert.AreEqual(Ord(cptNone), Ord(Map.TrapAt(BASE + $1200)), 'a probe that was never written is listed');
    Memory.WriteLimit := -1;
    Map.Disarm(0, nil);
    for var I := 0 to High(Program_) do
      if Memory.Bytes[I] <> Program_[I] then
        Assert.Fail(Format('after the disarm the byte at $%x is $%x, the program has $%x',
          [I, Memory.Bytes[I], Program_[I]]));
  finally
    Map.Free;
    Memory.Free;
  end;
end;

{ 2. the probes agree with the program }

// Compares what the probes recorded with the program's own record, mark by
// mark, and the program's result with an undisturbed run. Armed is what
// carried a probe right after arming; a mark none of whose records was armed
// is returned in NotArmed instead of being compared.
procedure CompareWithTheProgram(Fixture: TCodePatchTests; const Caption: string;
  const Binary: TTargetBinary; Sample: TModuleFile; const Armed, Hits: TArray<Cardinal>;
  const Written: TProgramRecord; out NotArmed: TArray<Integer>);
begin
  NotArmed := nil;
  Fixture.Check(Written.Valid, Caption + ': the program wrote no record');
  if not Written.Valid then
    Exit;
  var Reference := ReferenceRecord(Binary.Is64);
  Fixture.Check(Written.Sink = Reference.Sink, Format('%s: the program computed %s, an undisturbed run ' +
    'computes %s: an instruction under a probe was not executed exactly once',
    [Caption, Written.Sink, Reference.Sink]));
  var Lines := MarkLines;
  var Compared := 0;
  for var Mark := 0 to MAX_MARK do begin
    if Lines[Mark] = 0 then
      Continue;
    Fixture.Check(Written.Ran[Mark] = Reference.Ran[Mark], Format('%s: the program says mark %d %s, ' +
      'an undisturbed run says the opposite', [Caption, Mark, BoolToStr(Written.Ran[Mark], True)]));
    var Rvas := Sample.RvasOfLine(Lines[Mark]);
    if not AnyOf(Rvas, Armed) then begin
      NotArmed := NotArmed + [Mark];
      Continue;
    end;
    Inc(Compared);
    var Hit := AnyOf(Rvas, Hits);
    if Hit and not Written.Ran[Mark] then
      Fixture.Check(False, Format('%s: the probes say line %d (mark %d) ran, the program says it did not',
        [Caption, Lines[Mark], Mark]));
    if Written.Ran[Mark] and not Hit then
      Fixture.Check(False, Format('%s: the program ran line %d (mark %d), no probe of it was hit',
        [Caption, Lines[Mark], Mark]));
  end;
  Fixture.Check(Compared >= 40, Format('%s: only %d marks were compared: the test exercised nothing',
    [Caption, Compared]));
  for var Rva in Hits do
    Fixture.Check(Contains(Armed, Rva), Format('%s: $%x is recorded as hit and was never armed', [Caption, Rva]));
end;

function MarksText(const Marks: TArray<Integer>): string;
begin
  Result := LinesText(Marks);
end;

procedure TCodePatchTests.Probes_AgreeWithTheProgramsOwnRecord_LineForLine;
// Every line record of the executable the analysis confirms gets a probe at
// the entry stop, before any of its code has run. With a MAP every mark has
// one. Without a MAP nothing proves the entry of an anonymous method's body
// on x86, so its line (mark 29) is unconfirmed and carries none: the one
// accepted hole, and it must be exactly that one.
const
  ANONYMOUS_BODY_MARK = 29;
begin
  for var Is64 in [False, True] do
    for var WithMap in [True, False] do begin
      var Binary := SampleBinary(Is64);
      var Caption := Binary.Caption;
      if not WithMap then
        Caption := Caption + ' without a MAP';
      var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
      var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
      var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"', WithMap);
      try
        var Report: TLineProbeReport;
        Assert.IsTrue(ArmWholeModule(Session, ExtractFileName(Binary.Exe), Report),
          Caption + ': the request was refused: ' + Report.Note);
        Check(Report.State = lpsArmed, Caption + ': not armed at the entry stop: ' + DescribeReport(Report));
        Check(Report.ArmedAt = 'the request', Caption + ': armed at "' + Report.ArmedAt + '"');
        Check(Report.Outcome.Armed > LONG_RUN_LINES, Format('%s: only %d probes armed', [Caption, Report.Outcome.Armed]));
        // Runs, not bytes: a few writes for hundreds of probes.
        Check(Report.Outcome.WriteCalls * 10 < Report.Outcome.Armed,
          Format('%s: %d writes for %d probes', [Caption, Report.Outcome.WriteCalls, Report.Outcome.Armed]));
        var Armed := PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase);

        var Ended: Boolean;
        var Stops := RunToTheEnd(Session, Ended);
        Check(Length(Stops) = 0, Caption + ': a probe hit was reported as a stop at line(s) ' + LinesText(Stops));
        Check(Ended, Caption + ': the program did not run to its end with every line probed: ' + HowItEnded);

        // Read AFTER the process has ended.
        var Hits := Session.LineProbes.Hits(ExtractFileName(Binary.Exe));
        var NotArmed: TArray<Integer>;
        CompareWithTheProgram(Self, Caption, Binary, Sample, Armed, Hits,
          ReadProgramRecord(Dir + '\record.txt'), NotArmed);
        var Expected: TArray<Integer> := nil;
        if (not Is64) and (not WithMap) then
          Expected := [ANONYMOUS_BODY_MARK];
        Check(MarksText(NotArmed) = MarksText(Expected), Format('%s: the marks without a probe are %s, expected %s',
          [Caption, MarksText(NotArmed), MarksText(Expected)]));
      finally
        EndSession(Session);
        Sample.Free;
        DeleteTempDirWithRetry(Dir);
      end;
    end;
  AssertNoProblems;
end;

procedure TCodePatchTests.MainExecutable_AskedForBeforeTheProcess_IsArmedBeforeItsCodeRuns;
// The request is made right after Launch, before one debug event has been
// read: there is no process handle yet. It stands, and is armed at the first
// module event of the process -- when the executable is mapped and none of its
// code has run. The proof is the first line of the program: its mark must be
// recorded. (No MAP here, so that what is confirmable does not depend on how
// far a background index has got at that moment.)
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := LaunchSample(Binary, False, '-out "' + Dir + '\record.txt"', False);
    try
      var Request := Default(TLineProbeRequest);
      Request.ModuleName  := ExtractFileName(Binary.Exe);
      Request.WholeModule := True;
      var Report: TLineProbeReport;
      Assert.IsTrue(Session.LineProbes.Arm(Request, Report), Binary.Caption + ': refused: ' + Report.Note);
      Check(Report.State = lpsNotLoaded, Binary.Caption + ': before the first debug event the request ' +
        'cannot be armed: ' + DescribeReport(Report));
      var LastLine := MarkerLine('PS_MAIN_LAST');
      SetLines(Session, LineSpecs([LastLine]));
      PumpUntilStoppedOrExited(Session);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the last line did not stop: ' + HowItEnded);
      Check(Session.LineProbes.TryGetReport(Request.ModuleName, Report) and (Report.State = lpsArmed),
        Binary.Caption + ': the standing request was never armed: ' + DescribeReport(Report));
      Check(Report.ArmedAt = 'the load event of another module',
        Binary.Caption + ': armed at "' + Report.ArmedAt + '", expected the first module event');
      var Armed := PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase);
      var Hits := Session.LineProbes.Hits(Request.ModuleName);
      var First := Sample.RvasOfLine(MarkerLine('PS_MAIN_FIRST'));
      Check(AnyOf(First, Hits), Binary.Caption + ': the first line of the program is not recorded: the ' +
        'executable was armed after its code had started to run');
      // The entry point itself is a line record: the probe there and the
      // engine's own breakpoints must not have cost the program anything.
      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
      var NotArmed: TArray<Integer>;
      // Everything that was armed at the stop is still in Armed or has fired.
      CompareWithTheProgram(Self, Binary.Caption, Binary, Sample, SortedUnion(Armed, Hits),
        Session.LineProbes.Hits(Request.ModuleName), ReadProgramRecord(Dir + '\record.txt'), NotArmed);
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.ProgramsOwnInt3_IsNeverArmed_AndIsAnnouncedOnlyWhileProbesAreArmed;
// OwnBreakpoint's second line IS an `int 3`: a line record whose first byte is
// $CC in the program, and an instruction boundary the analysis confirms. A
// probe there would save $CC as "the program's byte", and after the first hit
// the rewound thread would execute the program's own breakpoint. It is refused
// by what the byte is. The program then executes its `int 3`, which is handed
// to it as before (it catches the exception); while probes are armed the
// debugger says so once, and never when none are.
begin
  for var Is64 in [False, True] do
    for var WithProbes in [True, False] do begin
      var Binary := SampleBinary(Is64);
      var Caption := Binary.Caption;
      if not WithProbes then
        Caption := Caption + ' without probes';
      var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
      var Session := StoppedAtEntry(Binary);
      try
        var Marker := 'PS_OWN_INT3_32';
        if Is64 then
          Marker := 'PS_OWN_INT3_64';
        var Own := Sample.RvasOfLine(MarkerLine(Marker));
        Assert.AreEqual(1, Integer(Length(Own)), Caption + ': the int 3 line should have one record');
        Assert.AreEqual(INT3, Integer(Sample.ProgramByte(Own[0])), Caption + ': the fixture''s int 3 line does not start with $CC');
        if WithProbes then begin
          var Report: TLineProbeReport;
          Assert.IsTrue(ArmWholeModule(Session, ExtractFileName(Binary.Exe), Report), Caption + ': refused: ' + Report.Note);
          Check(Report.Outcome.OwnBreakpointInstruction = 1, Format('%s: %d record(s) refused as the program''s ' +
            'own breakpoint instruction, expected the one int 3 line', [Caption, Report.Outcome.OwnBreakpointInstruction]));
          Check((Length(Report.Outcome.OwnBreakpointRvas) = 1) and (Report.Outcome.OwnBreakpointRvas[0] = Own[0]),
            Caption + ': the refused record is not the int 3 line');
          var Armed := PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase);
          Check(not Contains(Armed, Own[0]), Caption + ': the record at the program''s own int 3 was armed');
        end;
        var Ended: Boolean;
        RunToTheEnd(Session, Ended);
        Check(Ended, Caption + ': the program did not end normally after its own int 3: ' + HowItEnded);
        var Notices := 0;
        for var Text in Session.DrainDebuggerOutput do
          if Text.Contains(FOREIGN_INT3_NOTICE) then
            Inc(Notices);
        if WithProbes then
          Check(Notices = 1, Format('%s: %d notice(s) about a breakpoint instruction the debugger did not plant, ' +
            'expected one', [Caption, Notices]))
        else
          Check(Notices = 0, Format('%s: %d notice(s) although no probe was armed', [Caption, Notices]));
        if WithProbes then
          Check(not Contains(Session.LineProbes.Hits(ExtractFileName(Binary.Exe)), Own[0]),
            Caption + ': the program''s own int 3 was recorded as a probe hit');
      finally
        EndSession(Session);
        Sample.Free;
      end;
    end;
  AssertNoProblems;
end;

{ 3. one address, two owners }

type
  // The two lines of LayerLoop, which the program runs LAYER_PASSES times.
  TLayerSite = record
    LineA, LineB, LineBefore: Integer;
    RvaA, RvaB: Cardinal;
    VaA, VaB:   UInt64;
    ByteA, ByteB: Byte;
  end;

function LayerSite(Session: TDebugSession; Sample: TModuleFile): TLayerSite;
begin
  Result := Default(TLayerSite);
  Result.LineA      := MarkerLine('PS_LAYER_A');
  Result.LineB      := MarkerLine('PS_LAYER_B');
  Result.LineBefore := MarkerLine('PS_LAYER_BEFORE');
  var A := Sample.RvasOfLine(Result.LineA);
  var B := Sample.RvasOfLine(Result.LineB);
  Assert.IsTrue((Length(A) = 1) and (Length(B) = 1), 'the two lines of LayerLoop should have one record each');
  Result.RvaA  := A[0];
  Result.RvaB  := B[0];
  Result.VaA   := Session.Debugger.ImageBase + A[0];
  Result.VaB   := Session.Debugger.ImageBase + B[0];
  Result.ByteA := Sample.ProgramByte(A[0]);
  Result.ByteB := Sample.ProgramByte(B[0]);
end;

// The code at an address as the engine shows it; -1 when it cannot be read.
function CodeByte(Session: TDebugSession; VA: UInt64): Integer;
begin
  var Value: Byte := 0;
  if (Session.Debugger = nil) or (Session.Debugger.ReadCodeMemoryAt(VA, @Value, 1) <> 1) then
    Exit(-1);
  Result := Value;
end;

procedure TCodePatchTests.ProbeThenBreakpoint_BothGetTheHit_AndRemovingTheBreakpointLeavesNoByte;
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"');
    try
      var Site := LayerSite(Session, Sample);
      var Key := ExtractFileName(Binary.Exe);
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      Check(RawByte(Session, Site.VaA) = INT3, Binary.Caption + ': no probe on the line');
      SetLines(Session, LineSpecs([Site.LineA]));
      Check(RawByte(Session, Site.VaA) = INT3, Binary.Caption + ': the byte under probe and breakpoint is not $CC');
      // The breakpoint saved the PROGRAM's byte, not the probe's.
      Check(CodeByte(Session, Site.VaA) = Site.ByteA, Format('%s: a reader of code sees $%x under the two, ' +
        'the program has $%x', [Binary.Caption, CodeByte(Session, Site.VaA), Site.ByteA]));

      // A second breakpoint one line further, so that the session can look at
      // the first address while no thread stands on it.
      SetLines(Session, LineSpecs([Site.LineA, Site.LineB]));

      // First pass: one event, both owners.
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Site.LineA) and (GWatch.LastReason = srBreakpoint),
        Format('%s: the breakpoint under a probe did not stop (line %d): %s',
          [Binary.Caption, CurrentLine(Session), HowItEnded]));
      Check(Contains(Session.LineProbes.Hits(Key), Site.RvaA), Binary.Caption + ': the probe under a breakpoint was not recorded');
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Site.LineB),
        Binary.Caption + ': the next line did not stop');
      // The probe has fired and the thread has left the address: the byte
      // there is the breakpoint's alone now.
      Check(RawByte(Session, Site.VaA) = INT3, Binary.Caption + ': after the probe fired the breakpoint on its ' +
        'address is not planted');
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Site.LineA),
        Binary.Caption + ': the breakpoint did not stop on the second pass');
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Site.LineB),
        Binary.Caption + ': the next line did not stop on the second pass');
      // The breakpoint goes AFTER the probe fired: nothing of ours may stay.
      SetLines(Session, LineSpecs([Site.LineB]));
      Check(RawByte(Session, Site.VaA) = Site.ByteA, Format('%s: with the probe fired and the breakpoint ' +
        'removed the byte is $%x, the program has $%x', [Binary.Caption, RawByte(Session, Site.VaA), Site.ByteA]));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check((CountOf(Stops, Site.LineA) = 0) and (CountOf(Stops, Site.LineB) = LAYER_PASSES - 2) and Ended,
        Format('%s: after the breakpoint was removed: stops %s, %s', [Binary.Caption, LinesText(Stops), HowItEnded]));
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the program did not compute what an undisturbed run computes');
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.BreakpointThenProbe_TheProbeSharesTheByte_AndBothGetTheHit;
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"');
    try
      var Site := LayerSite(Session, Sample);
      var Key := ExtractFileName(Binary.Exe);
      SetLines(Session, LineSpecs([Site.LineA]));
      Check(RawByte(Session, Site.VaA) = INT3, Binary.Caption + ': the breakpoint is not planted');
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      Check(Report.Outcome.SharedWithBreakpoint >= 1, Binary.Caption + ': no probe was armed on a byte a breakpoint holds');
      Check(Contains(PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase), Site.RvaA),
        Binary.Caption + ': the line under the breakpoint carries no probe');
      Check(CodeByte(Session, Site.VaA) = Site.ByteA, Binary.Caption + ': a reader of code does not see the program''s byte');

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOf(Stops, Site.LineA) = LAYER_PASSES, Format('%s: the breakpoint stopped %d time(s) on %d passes (%s): ' +
        'arming a probe on its address disturbed it', [Binary.Caption, CountOf(Stops, Site.LineA), LAYER_PASSES, LinesText(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
      Check(Contains(Session.LineProbes.Hits(Key), Site.RvaA), Binary.Caption + ': the probe on the breakpoint''s address was not recorded');
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the program did not compute what an undisturbed run computes');
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.BreakpointRemovedBeforeTheProbeFires_TheProbeKeepsTheByteAndFires;
// Deleting a breakpoint puts the program's byte back -- unless something else
// still needs the $CC. A probe that has not fired does.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"');
    try
      var Site := LayerSite(Session, Sample);
      var Key := ExtractFileName(Binary.Exe);
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      SetLines(Session, LineSpecs([Site.LineBefore, Site.LineA]));
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Site.LineBefore),
        Binary.Caption + ': did not stop before the loop');
      Check(not Contains(Session.LineProbes.Hits(Key), Site.RvaA), Binary.Caption + ': the line is recorded before it ran');
      SetLines(Session, nil);
      Check(RawByte(Session, Site.VaA) = INT3, Format('%s: removing the breakpoint took the probe''s byte away ' +
        '(the byte is $%x)', [Binary.Caption, RawByte(Session, Site.VaA)]));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check((Length(Stops) = 0) and Ended, Format('%s: stops %s, %s', [Binary.Caption, LinesText(Stops), HowItEnded]));
      Check(Contains(Session.LineProbes.Hits(Key), Site.RvaA), Binary.Caption + ': the probe did not fire after ' +
        'the breakpoint on its address was removed');
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the program did not compute what an undisturbed run computes');
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.ProbeTakenAwayUnderABreakpoint_TheBreakpointKeepsStopping;
// The other direction: the probes are withdrawn while a breakpoint sits on one
// of their addresses. That byte stays $CC, every other one goes back.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"');
    try
      var Site := LayerSite(Session, Sample);
      var Key := ExtractFileName(Binary.Exe);
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      SetLines(Session, LineSpecs([Site.LineBefore, Site.LineA]));
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Site.LineBefore),
        Binary.Caption + ': did not stop before the loop');
      Session.LineProbes.Disarm;
      Check(PatchTarget(Session).CodePatchStats.Armed = 0, Binary.Caption + ': probes are still armed after the disarm');
      Check(RawByte(Session, Site.VaA) = INT3, Format('%s: taking the probes away took the breakpoint''s byte ' +
        '(the byte is $%x)', [Binary.Caption, RawByte(Session, Site.VaA)]));
      Check(RawByte(Session, Site.VaB) = Site.ByteB, Format('%s: a withdrawn probe left $%x where the program has $%x',
        [Binary.Caption, RawByte(Session, Site.VaB), Site.ByteB]));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOf(Stops, Site.LineA) = LAYER_PASSES, Format('%s: the breakpoint stopped %d time(s) on %d passes (%s)',
        [Binary.Caption, CountOf(Stops, Site.LineA), LAYER_PASSES, LinesText(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
      Check(not Contains(Session.LineProbes.Hits(Key), Site.RvaA), Binary.Caption + ': a withdrawn probe recorded a hit');
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the program did not compute what an undisturbed run computes');
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.ResumedFromALineWithBreakpointAndProbe_TheLineRunsOnceAndBothWork;
// Two consecutive lines of StepArea, neither of which calls anything, with a
// breakpoint on each and probes everywhere. The stop on the first is followed
// by a step: the thread LANDS on the second by a single step, without
// executing its $CC, so that line's probe has not fired and its breakpoint is
// planted. Resuming from there takes the breakpoint away for one instruction
// -- and must not take the probe's byte with it, or the line would run
// unrecorded under a probe that still believes its byte is in place. The
// thread traps once more, for the probe; runs the real instruction; and the
// breakpoint's byte goes back on its single step.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"');
    try
      var Key := ExtractFileName(Binary.Exe);
      var FirstLine  := MarkerLine('PS_STEP_RELEASE');
      var SecondLine := MarkerLine('PS_STEP_SECOND');
      var LastLine   := MarkerLine('PS_STEP_LAST');
      var Second := Sample.RvasOfLine(SecondLine);
      Assert.AreEqual(1, Integer(Length(Second)), Binary.Caption + ': the second line should have one record');
      var SecondVA := Session.Debugger.ImageBase + Second[0];
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      SetLines(Session, LineSpecs([FirstLine, SecondLine, LastLine]));
      Check(RunToNextStop(Session) and (CurrentLine(Session) = FirstLine), Binary.Caption + ': the first line did not stop');
      Session.StepOver;
      PumpUntilStoppedOrExited(Session);
      Check((Session.State = dsStopped) and (CurrentLine(Session) = SecondLine) and (GWatch.LastReason = srStep),
        Format('%s: the step did not land on the second line (line %d, reason %d)',
          [Binary.Caption, CurrentLine(Session), Ord(GWatch.LastReason)]));
      Check(not Contains(Session.LineProbes.Hits(Key), Second[0]), Binary.Caption + ': the second line is recorded ' +
        'although the thread only stands on it');
      Check(RawByte(Session, SecondVA) = INT3, Binary.Caption + ': the byte under breakpoint and probe is not $CC');

      Check(RunToNextStop(Session) and (CurrentLine(Session) = LastLine),
        Format('%s: resumed from the line with breakpoint and probe, the next stop is line %d: %s',
          [Binary.Caption, CurrentLine(Session), HowItEnded]));
      Check(Contains(Session.LineProbes.Hits(Key), Second[0]), Binary.Caption + ': the line the thread was resumed ' +
        'from ran without its probe recording it');
      Check(RawByte(Session, SecondVA) = INT3, Format('%s: after the thread left the line its breakpoint is not ' +
        'planted any more (the byte is $%x)', [Binary.Caption, RawByte(Session, SecondVA)]));
      SetLines(Session, nil);
      Check(RawByte(Session, SecondVA) = Sample.ProgramByte(Second[0]), Format('%s: with the probe fired and the ' +
        'breakpoint removed the byte is $%x, the program has $%x',
        [Binary.Caption, RawByte(Session, SecondVA), Sample.ProgramByte(Second[0])]));
      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the program did not compute what an undisturbed run computes: the line the thread was resumed ' +
        'from did not run exactly once');
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.ParkedOnAProbeAnotherThreadGaveBack_TheThreadRunsTheInstructionOnce;
// The race worker stops at the breakpoint on the first line of LongRun: its
// byte is suspended and the thread owes the breakpoint a re-arm. A probe is
// armed on that very address now, so the $CC under the parked thread is the
// probe's. The thread executes it; its trap is queued; and before the
// debugger reads it the probe's byte goes back -- here because the probes are
// taken away (the same happens when a second thread's trap on the same probe
// is read first). The trap then arrives on an address whose breakpoint is not
// planted and whose byte is no longer $CC. Taken for the program's own
// `int 3`, the thread resumed one byte into the instruction. LongRun checks
// its own sum.
//
// Deterministic: the thread is held (SuspendThread) across the continue, and
// let go only once the debugger has stopped reading events.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-race 1');
    var Parked: THandle := 0;
    try
      var First := MarkerLine('PS_LONG_FIRST');
      var Rvas := Sample.RvasOfLine(First);
      Assert.AreEqual(1, Integer(Length(Rvas)), Binary.Caption + ': the first line of LongRun should have one record');
      SetLines(Session, LineSpecs([First]));
      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = First),
        Binary.Caption + ': the first line of LongRun did not stop: ' + HowItEnded);
      var VA := Session.Debugger.ImageBase + Rvas[0];
      var Request := Default(TCodePatchArmRequest);
      Request.ModuleBase := Session.Debugger.ImageBase;
      Request.ResultKey  := LowerCase(ExtractFileName(Binary.Exe));
      Request.Rvas       := Rvas;
      var Outcome: TCodePatchArmOutcome;
      var Refusal: string;
      var Target := PatchTarget(Session);
      Assert.IsTrue(Target.ArmOneShotProbes(Request, Outcome, Refusal), Binary.Caption + ': ' + Refusal);
      Check(RawByte(Session, VA) = INT3, Binary.Caption + ': no probe under the parked thread');

      Parked := OpenThread(THREAD_SUSPEND_RESUME, False, Session.GetStoppedThreadId);
      Assert.IsTrue(Parked <> 0, Binary.Caption + ': the parked thread could not be opened');
      Assert.AreNotEqual(DWORD(-1), SuspendThread(Parked), Binary.Caption + ': the parked thread could not be held');
      Session.ContinueExecution;
      PumpFor(Session, 100);
      // Not pumping from here: the thread runs into the probe and its trap waits.
      ResumeThread(Parked);
      Sleep(50);
      var Before := Target.CodePatchStats.LateTraps;
      Target.DisarmProbes(Session.Debugger.ImageBase);
      Check(RawByte(Session, VA) <> INT3, Binary.Caption + ': the probe''s byte did not go back');

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(Ended, Format('%s: the thread parked on the probe did not run the instruction exactly once: %s',
        [Binary.Caption, HowItEnded]));
      // The only thread through that line has stopped there once already.
      Check(CountOf(Stops, First) = 0, Format('%s: the parked thread stopped again on the line it had stopped on ' +
        '(stops: %s): its re-arm was dropped and the breakpoint planted under it', [Binary.Caption, LinesText(Stops)]));
      Check(Target.CodePatchStats.LateTraps > Before, Binary.Caption + ': the parked thread''s trap did not arrive ' +
        'after the byte went back: the test exercised nothing');
    finally
      if Parked <> 0 then
        CloseHandle(Parked);
      EndSession(Session);
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

{ 4. stepping }

// The stops of a fixed sequence of steps from the first line of StepArea:
// over, over, over, into the callee, out of it, over, over.
function StepSequence(Fixture: TCodePatchTests; const Caption: string; Session: TDebugSession): string;
const
  STEPS = 'oooiuoo';
begin
  Result := '';
  var Tid := Session.GetStoppedThreadId;
  for var Step in STEPS do begin
    case Step of
      'o': Session.StepOver;
      'i': Session.StepInto;
      'u': Session.StepOut;
    end;
    PumpUntilStoppedOrExited(Session);
    if Session.State <> dsStopped then begin
      Fixture.Check(False, Format('%s: step "%s" after "%s" did not land: %s', [Caption, Step, Result, HowItEnded]));
      Exit;
    end;
    var FnName, SrcFile: string;
    var Line := 0;
    Session.GetCurrentLocation(FnName, SrcFile, Line);
    Fixture.Check(GWatch.LastReason = srStep, Format('%s: step "%s" ended with reason %d', [Caption, Step, Ord(GWatch.LastReason)]));
    Fixture.Check(Session.GetStoppedThreadId = Tid, Format('%s: step "%s" landed on another thread', [Caption, Step]));
    Result := Result + Format('%s:%d ', [FnName, Line]);
  end;
  Result := Result.Trim;
end;

procedure TCodePatchTests.Steps_AcrossLinesThatHaveNotFired_LandWhereTheyLandWithoutProbes;
// The same seven steps twice: without probes, and with a probe on every line
// of the executable. They must land on the same lines. Each way with the
// default step isolation (the other thread is frozen during a step) and with
// none: then the second thread is released by the second step and runs through
// 160 lines that have never executed WHILE the main thread is being stepped,
// so its probe hits arrive in the middle of the steps.
const
  ISOLATIONS: array[0..1] of Integer = (MaxInt, -1);
begin
  for var Is64 in [False, True] do
    for var Isolation in ISOLATIONS do begin
      var Binary := SampleBinary(Is64);
      var Caption := Binary.Caption;
      if Isolation = -1 then
        Caption := Caption + ' without step isolation';
      var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
      var Landings: array[Boolean] of string;
      try
        for var WithProbes in [False, True] do begin
          var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
          var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"', True, Isolation);
          try
            var Key := ExtractFileName(Binary.Exe);
            var Armed: TArray<Cardinal> := nil;
            if WithProbes then begin
              var Report: TLineProbeReport;
              Assert.IsTrue(ArmWholeModule(Session, Key, Report), Caption + ': refused: ' + Report.Note);
              Armed := PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase);
            end;
            SetLines(Session, LineSpecs([MarkerLine('PS_STEP_FIRST')]));
            Assert.IsTrue(RunToNextStop(Session), Caption + ': the first line of StepArea did not stop: ' + HowItEnded);
            SetLines(Session, nil);
            Landings[WithProbes] := StepSequence(Self, Caption, Session);
            var Ended: Boolean;
            RunToTheEnd(Session, Ended);
            Check(Ended, Format('%s (probes %s): the program did not end normally after the steps: %s',
              [Caption, BoolToStr(WithProbes, True), HowItEnded]));
            var Written := ReadProgramRecord(Dir + '\record.txt');
            if WithProbes then begin
              var NotArmed: TArray<Integer>;
              CompareWithTheProgram(Self, Caption + ' after the steps', Binary, Sample, Armed,
                Session.LineProbes.Hits(Key), Written, NotArmed);
            end else
              Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink),
                Caption + ': the stepped program did not compute what an undisturbed run computes');
          finally
            EndSession(Session);
            DeleteTempDirWithRetry(Dir);
          end;
        end;
        Check(Landings[False] <> '', Caption + ': the steps without probes landed nowhere');
        Check(Landings[True] = Landings[False], Format('%s: with probes the steps landed at [%s], without at [%s]',
          [Caption, Landings[True], Landings[False]]));
      finally
        Sample.Free;
      end;
    end;
  AssertNoProblems;
end;

// The handler stubs of a routine of the fixture, from the routine analysis of
// the FILE (x86: the `jmp` to an RTL handler that fs:[0] points at).
function HandlerStubsOf(Sample: TModuleFile; const RoutineName: string): TArray<Cardinal>;
begin
  Result := nil;
  var Routine := Sample.RoutineNamed(RoutineName);
  Assert.IsTrue(Routine >= 0, 'routine ' + RoutineName + ' not found in the fixture');
  var Input := Default(TRoutineAnalysisInput);
  Input.Mode := dmmLegacy32;
  if Sample.Image.Is64 then
    Input.Mode := dmmLong64;
  Input.Reader       := Sample.Image.Read;
  Input.ImageBase    := Sample.Image.ImageBase;
  Input.CodeMap      := Sample.Map;
  Input.ZydisDllPath := ResolveZydisDllPathForThisExe;
  var Analyzer := TRoutineAnalyzer.Create(Input);
  try
    for var Entry in Analyzer.Analyze(Routine).HandlerEntries do
      if Entry.Kind = rhkStub then
        Result := Result + [Entry.Rva];
  finally
    Analyzer.Free;
  end;
end;

procedure TCodePatchTests.StepAtAnExceptionStop_WithAProbeOnTheHandlerStub_LandsInTheHandler;
// A step at a first-chance exception stop runs to the handler that receives
// the exception. With a probe on every line the landing must be the same.
//
// On x86 the planner reads the code the fs:[0] record points at and refuses
// anything that is not a `jmp rel32` to an RTL handler. A probe written ON
// that stub must not be what it reads; and the stub is then EXECUTED by the
// exception dispatch, in the middle of which its probe fires and is taken
// away. A stub is not a line record, so the probe is put there through the
// engine directly.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Landings: array[Boolean] of Integer;
    Landings[False] := 0;
    Landings[True]  := 0;
    try
      for var WithProbes in [False, True] do begin
        var Session := StoppedAtEntry(Binary);
        try
          var Key := ExtractFileName(Binary.Exe);
          var Stubs: TArray<Cardinal> := nil;
          if WithProbes then begin
            var Report: TLineProbeReport;
            Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
          end;
          Session.SetExceptionFilters(['delphi'], 'EProgrammerNotFound');
          Assert.IsTrue(RunToNextStop(Session) and (GWatch.LastReason = srException),
            Binary.Caption + ': the raise in RaiseForStep did not stop: ' + HowItEnded);
          if WithProbes and not Is64 then begin
            Stubs := HandlerStubsOf(Sample, 'RaiseForStep');
            Assert.IsTrue(Length(Stubs) > 0, Binary.Caption + ': the analysis found no handler stub in RaiseForStep');
            var Request := Default(TCodePatchArmRequest);
            Request.ModuleBase := Session.Debugger.ImageBase;
            Request.ResultKey  := LowerCase(Key);
            Request.Rvas       := Stubs;
            var Outcome: TCodePatchArmOutcome;
            var Refusal: string;
            Assert.IsTrue(PatchTarget(Session).ArmOneShotProbes(Request, Outcome, Refusal), Binary.Caption + ': ' + Refusal);
            for var Stub in Stubs do begin
              Check(RawByte(Session, Session.Debugger.ImageBase + Stub) = INT3,
                Format('%s: no probe on the handler stub at $%x', [Binary.Caption, Stub]));
              Check(Sample.ProgramByte(Stub) = $E9, Format('%s: the stub at $%x does not start with a jmp', [Binary.Caption, Stub]));
            end;
          end;
          var Refusal: string;
          var Stepped := Session.StepOver(0, Refusal);
          Check(Stepped, Format('%s (probes %s): the step at the exception stop was refused: %s',
            [Binary.Caption, BoolToStr(WithProbes, True), Refusal]));
          if Stepped then begin
            PumpUntilStoppedOrExited(Session);
            Check(Session.State = dsStopped, Binary.Caption + ': the step to the handler did not land: ' + HowItEnded);
            Landings[WithProbes] := CurrentLine(Session);
          end;
          if Length(Stubs) > 0 then begin
            // The dispatch ran through at least one stub; whichever it ran
            // through has its byte back and is recorded.
            var Ran := 0;
            for var Stub in Stubs do
              if Contains(Session.LineProbes.Hits(Key), Stub) then begin
                Inc(Ran);
                Check(RawByte(Session, Session.Debugger.ImageBase + Stub) = $E9,
                  Format('%s: the stub at $%x fired and its byte is not back', [Binary.Caption, Stub]));
              end;
            Check(Ran > 0, Binary.Caption + ': the exception was dispatched and no probe on a handler stub fired');
          end;
          var Ended: Boolean;
          RunToTheEnd(Session, Ended);
          Check(Ended, Format('%s (probes %s): the program did not end normally: %s',
            [Binary.Caption, BoolToStr(WithProbes, True), HowItEnded]));
        finally
          EndSession(Session);
        end;
      end;
      // The clause (`on E: ... do`) or its statement, whichever the planner names.
      var Handler := MarkerLine('PS_EXC_HANDLER');
      Check((Landings[False] = Handler) or (Landings[False] = Handler - 1), Format('%s: without probes the step ' +
        'landed on line %d, the handler is on line %d', [Binary.Caption, Landings[False], Handler]));
      Check(Landings[True] = Landings[False], Format('%s: with probes the step landed on line %d, without on line %d',
        [Binary.Caption, Landings[True], Landings[False]]));
    finally
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.StepOver_WhileAnotherThreadRunsThroughALogpoint_LandsOnItsOwnThread;
// The main thread steps over a call that cannot return before a second thread
// has run; that thread runs STEP_RACE_TICKS times through a line carrying a
// logpoint. Each of its hits is followed by the single step that puts the
// logpoint's byte back -- on a thread the step in flight does not belong to.
// That trap used to be handed to the step machinery, which compared the second
// thread's stack pointer with the stepper's and ended the step on it.
//
// Both ways the other thread can be running during a step: an isolation that
// is released when the stepped call is found waiting, and no isolation.
const
  ISOLATIONS: array[0..1] of Integer = (200, -1);
begin
  for var Is64 in [False, True] do
    for var Isolation in ISOLATIONS do begin
      var Binary := SampleBinary(Is64);
      var Caption := Format('%s, isolation %d', [Binary.Caption, Isolation]);
      var Session := StoppedAtEntry(Binary, '-steprace', True, Isolation);
      try
        var CallLine  := MarkerLine('PS_SR_CALL');
        var AfterLine := MarkerLine('PS_SR_AFTER');
        var Specs := LineSpecs([CallLine, MarkerLine('PS_SR_TICK')]);
        Specs[1].LogMessage := 'tick';
        SetLines(Session, Specs);
        Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = CallLine),
          Caption + ': the call line did not stop: ' + HowItEnded);
        var MainTid := Session.GetStoppedThreadId;
        Session.StepOver;
        PumpUntilStoppedOrExited(Session);
        Check(Session.State = dsStopped, Caption + ': the step over the call did not land: ' + HowItEnded);
        if Session.State = dsStopped then begin
          Check(GWatch.LastReason = srStep, Format('%s: the stop after the step has reason %d', [Caption, Ord(GWatch.LastReason)]));
          Check(Session.GetStoppedThreadId = MainTid, Format('%s: the step landed on thread %d, the stepped thread is %d: ' +
            'another thread''s re-arm step drove the step', [Caption, Session.GetStoppedThreadId, MainTid]));
          Check(CurrentLine(Session) = AfterLine, Format('%s: the step landed on line %d, the line after the call is %d',
            [Caption, CurrentLine(Session), AfterLine]));
        end;
        var Ticks := 0;
        for var Text in Session.DrainDebuggerOutput do
          if Text.Contains('tick') then
            Inc(Ticks);
        var Ended: Boolean;
        RunToTheEnd(Session, Ended);
        for var Text in Session.DrainDebuggerOutput do
          if Text.Contains('tick') then
            Inc(Ticks);
        Check(Ended, Caption + ': the program did not end normally: ' + HowItEnded);
        Check(Ticks = STEP_RACE_TICKS, Format('%s: the logpoint logged %d time(s) on %d passes: the test exercised ' +
          'nothing, or a logpoint was lost', [Caption, Ticks, STEP_RACE_TICKS]));
      finally
        EndSession(Session);
      end;
    end;
  AssertNoProblems;
end;

{ 5. races }

// The records of LongRun's statements: LONG_RUN_LINES lines after its first.
function LongRunRvas(Sample: TModuleFile): TArray<Cardinal>;
begin
  Result := nil;
  var First := MarkerLine('PS_LONG_FIRST');
  for var Line := First to First + LONG_RUN_LINES do
    Result := Result + Sample.RvasOfLine(Line);
end;

procedure TCodePatchTests.SeveralThreadsThroughLinesNeverExecuted_EveryThreadRunsEveryLineOnce;
// Four threads, released together, through 160 lines that have never run. At
// every line the first thread to arrive takes the trap; the others have
// executed the same $CC within microseconds, and their events are read after
// the byte has gone back. Each of them stands one byte into an instruction
// whose first byte is the program's again: it must be rewound, not handed to
// the program as a breakpoint exception at an address that holds none. Every
// thread keeps its own total, so an instruction run twice or not at all shows
// in the exit code.
//
// A race, honestly: with four threads through 160 fresh lines it happens
// dozens of times per run on a multi-core machine, and the test says so when
// it did not happen at all.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-race');
    try
      var Key := ExtractFileName(Binary.Exe);
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(Length(Stops) = 0, Binary.Caption + ': a probe hit was reported as a stop');
      Check(Ended, Binary.Caption + ': a thread did not run every line exactly once, or the program died on a ' +
        'breakpoint instruction: ' + HowItEnded);
      var Hits := Session.LineProbes.Hits(Key);
      var Missing := 0;
      for var Rva in LongRunRvas(Sample) do
        if not Contains(Hits, Rva) then
          Inc(Missing);
      Check(Missing = 0, Format('%s: %d line record(s) of LongRun were executed and not recorded', [Binary.Caption, Missing]));
      var Stats := PatchTarget(Session).CodePatchStats;
      Check(Stats.LateTraps > 0, Binary.Caption + ': no trap arrived after its byte had gone back: the threads never ' +
        'met at a probe, and the test exercised nothing');
      Check(Stats.Lost = 0, Format('%s: %d restore(s) found a byte that was no longer the probe''s', [Binary.Caption, Stats.Lost]));
    finally
      EndSession(Session);
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

// Pumps until the program is inside LongRun and has not left it: its first
// line is recorded, its last is not.
function PumpIntoTheLongRun(Session: TDebugSession; Sample: TModuleFile; const Key: string): Boolean;
begin
  var First := Sample.RvasOfLine(MarkerLine('PS_LONG_FIRST'));
  var Last  := Sample.RvasOfLine(MarkerLine('PS_LONG_FIRST') + LONG_RUN_LINES);
  var Deadline := GetTickCount64 + STOP_TIMEOUT_MS;
  while (not Session.HasExited) and (GetTickCount64 < Deadline) do begin
    Session.Pump;
    var Hits := Session.LineProbes.Hits(Key);
    if AnyOf(First, Hits) then
      Exit(not AnyOf(Last, Hits));
  end;
  Result := False;
end;

procedure TCodePatchTests.TrapQueuedBeforeTheProbesAreTakenAway_IsRewoundNotHandedToTheProgram;
// One thread in the middle of a run of probed lines. The debugger stops
// reading events for a moment: the thread reaches the next probe within
// microseconds, traps, and its event waits in the queue. THEN the probes are
// taken away, every byte restored -- that one included. The event is read
// afterwards: a breakpoint trap at an address that holds no breakpoint and
// that no table lists as armed. Without the map remembering the address it is
// "not ours" and the program dies on it.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-race 1');
    try
      var Key := ExtractFileName(Binary.Exe);
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      Session.ContinueExecution;
      Assert.IsTrue(PumpIntoTheLongRun(Session, Sample, Key),
        Binary.Caption + ': the program was never seen inside LongRun: ' + HowItEnded);
      // Not pumping: the thread traps on its next line and the event queues.
      Sleep(50);
      var Target := PatchTarget(Session);
      var Before := Target.CodePatchStats;
      Session.LineProbes.Disarm;
      var HitsAtTheDisarm := Length(Session.LineProbes.Hits(Key));
      Check(Target.CodePatchStats.Armed = 0, Binary.Caption + ': probes are still armed after the disarm');
      PumpUntilStoppedOrExited(Session);
      Check(Session.HasExited and GWatch.Exited and (GWatch.Code = 0), Binary.Caption + ': the trap that was queued ' +
        'when the probes were taken away reached the program: ' + HowItEnded);
      var After := Target.CodePatchStats;
      Check(After.LateTraps > Before.LateTraps, Binary.Caption + ': no late trap was seen: nothing was queued, ' +
        'and the test exercised nothing');
      Check(Length(Session.LineProbes.Hits(Key)) = HitsAtTheDisarm, Binary.Caption + ': a hit was recorded after ' +
        'the probes had been taken away');
    finally
      EndSession(Session);
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

{ 6. modules }

procedure TCodePatchTests.Package_LoadedUnloadedLoadedAgain_IsArmedAtEachLoadAndKeepsItsHits;
// The request names a package that is not loaded yet. It is armed when the
// package is mapped, before its initialization runs; dropped without a write
// when it is unloaded, with what it recorded kept; and armed afresh at the
// second load, minus the lines that already ran. One routine of the package is
// called in the second mapping only, so its line can only be recorded if the
// second mapping was armed.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var PackagePath := ExtractFilePath(Binary.Exe) + PACKAGE_NAME;
    var PackageSource := RepoRoot + 'DebuggerTests\TestPackage\' + PACKAGE_SOURCE;
    var Package := TModuleFile.Create(PackagePath, PACKAGE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-pkg');
    try
      var InitLine := Package.RvasOfLine(MarkerLineIn(PackageSource, 'PKG_BP'));
      var LateLine := Package.RvasOfLine(LineContaining(PackageSource, 'persistent-pkg-widget'));
      Assert.IsTrue((Length(InitLine) > 0) and (Length(LateLine) > 0), Binary.Caption + ': the package lines have no records');

      var Request := Default(TLineProbeRequest);
      Request.ModuleName  := PACKAGE_NAME;
      Request.WholeModule := True;
      var Report: TLineProbeReport;
      Assert.IsTrue(Session.LineProbes.Arm(Request, Report), Binary.Caption + ': refused: ' + Report.Note);
      Check(Report.State = lpsNotLoaded, Binary.Caption + ': a module that is not loaded cannot be armed: ' + DescribeReport(Report));
      SetLines(Session, LineSpecs([MarkerLine('PS_PKG_LOADED'),
        MarkerLine('PS_PKG_UNLOADED'), MarkerLine('PS_PKG_RELOADED')]));

      // --- first mapping ---
      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = MarkerLine('PS_PKG_LOADED')),
        Binary.Caption + ': did not stop after the first load: ' + HowItEnded);
      Session.LineProbes.TryGetReport(PACKAGE_NAME, Report);
      Check((Report.State = lpsArmed) and (Report.Loads = 1), Binary.Caption + ': the first mapping was not armed: ' +
        DescribeReport(Report));
      Check((Report.ArmedAt = 'its load event') or (Report.ArmedAt = 'its entry point'),
        Binary.Caption + ': the package was armed at "' + Report.ArmedAt + '"');
      var FirstHits := Session.LineProbes.Hits(PACKAGE_NAME);
      Check(AnyOf(InitLine, FirstHits), Binary.Caption + ': the line the package''s initialization runs is not ' +
        'recorded: the package was armed after its code had started to run');
      Check(not AnyOf(LateLine, FirstHits), Binary.Caption + ': a line only the second mapping runs is recorded already');
      var FirstBase := Report.ModuleBase;

      // --- unloaded ---
      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = MarkerLine('PS_PKG_UNLOADED')),
        Binary.Caption + ': did not stop after the unload: ' + HowItEnded);
      Session.LineProbes.TryGetReport(PACKAGE_NAME, Report);
      Check(Report.State = lpsNotLoaded, Binary.Caption + ': after the unload the request should wait: ' + DescribeReport(Report));
      Check(Length(PatchTarget(Session).ArmedProbes(FirstBase)) = 0, Binary.Caption + ': the map still lists probes ' +
        'of a mapping that is gone');
      // (The unload itself runs lines of the package -- its finalization --
      // so there can be MORE hits now; none may be lost.)
      var KeptHits := Session.LineProbes.Hits(PACKAGE_NAME);
      for var Rva in FirstHits do
        Check(Contains(KeptHits, Rva), Format('%s: the hit at $%x was lost when the package was unloaded',
          [Binary.Caption, Rva]));
      FirstHits := KeptHits;

      // --- second mapping ---
      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = MarkerLine('PS_PKG_RELOADED')),
        Binary.Caption + ': did not stop after the second load: ' + HowItEnded);
      Session.LineProbes.TryGetReport(PACKAGE_NAME, Report);
      Check((Report.State = lpsArmed) and (Report.Loads = 2), Binary.Caption + ': the second mapping was not armed: ' +
        DescribeReport(Report));
      Check(Report.Outcome.AlreadyHit >= Length(FirstHits), Format('%s: %d line(s) had already run, %d were left ' +
        'unarmed in the second mapping', [Binary.Caption, Length(FirstHits), Report.Outcome.AlreadyHit]));
      var SecondHits := Session.LineProbes.Hits(PACKAGE_NAME);
      Check(AnyOf(LateLine, SecondHits), Binary.Caption + ': the line only the second mapping runs is not recorded: ' +
        'the package was not armed afresh');
      for var Rva in FirstHits do
        Check(Contains(SecondHits, Rva), Format('%s: the hit at $%x of the first mapping was lost', [Binary.Caption, Rva]));

      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
      Check(Length(Session.LineProbes.Hits(PACKAGE_NAME)) >= Length(SecondHits),
        Binary.Caption + ': hits were lost when the process ended');
    finally
      EndSession(Session);
      Package.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.ModuleRelocatedAfterItsLoadEvent_IsArmedAtItsEntryPoint;
// BreakpointSampleLib has a fixed base that the program has taken: the loader
// maps it elsewhere and relocates it AFTER the load event. A $CC could be
// written at the load event, but the analysis that says where a probe may go
// reads absolute addresses out of the code (the entries of its jump table),
// and those are only right once the loader is done. The request waits for the
// module's entry point: relocated, and none of its code has run.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var LibPath := ExtractFilePath(Binary.Exe) + LIB_NAME;
    var LibSource := TargetDir + LIB_SOURCE;
    var Lib := TModuleFile.Create(LibPath, LIB_SOURCE);
    var Session := StoppedAtEntry(Binary, '-lib');
    try
      var Request := Default(TLineProbeRequest);
      Request.ModuleName  := LIB_NAME;
      Request.WholeModule := True;
      var Report: TLineProbeReport;
      Assert.IsTrue(Session.LineProbes.Arm(Request, Report), Binary.Caption + ': refused: ' + Report.Note);
      SetLines(Session, LineSpecs([MarkerLine('PS_LIB_CALL')]));
      Assert.IsTrue(RunToNextStop(Session), Binary.Caption + ': did not stop before the call into the library: ' + HowItEnded);
      Session.LineProbes.TryGetReport(LIB_NAME, Report);
      Check(Report.State = lpsArmed, Binary.Caption + ': the relocated module was not armed: ' + DescribeReport(Report));
      Check(Report.ArmedAt = 'its entry point', Binary.Caption + ': armed at "' + Report.ArmedAt +
        '", expected its entry point (was the library mapped at its preferred base?)');
      var Armed := PatchTarget(Session).ArmedProbes(Report.ModuleBase);
      var TableLine := LineContaining(LibSource, 'DQ      @@zero');
      if not Is64 then
        TableLine := LineContaining(LibSource, 'DD      @@zero');
      Check(not AnyOf(Lib.RvasOfLine(TableLine), Armed), Binary.Caption + ': the line record on the jump table carries a probe');
      var RunFirst := Lib.RvasOfLine(MarkerLineIn(LibSource, 'BSL_RUN_FIRST'));
      Check(AnyOf(RunFirst, Armed), Binary.Caption + ': the first line of LibRun carries no probe');

      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the library did not compute its sum with every line probed: ' + HowItEnded);
      var Hits := Session.LineProbes.Hits(LIB_NAME);
      for var Marker in ['BSL_RUN_FIRST', 'BSL_FINALLY_BEFORE', 'BSL_FINALLY_BLOCK'] do
        Check(AnyOf(Lib.RvasOfLine(MarkerLineIn(LibSource, Marker)), Hits),
          Format('%s: line %s of the library ran and is not recorded', [Binary.Caption, Marker]));
    finally
      EndSession(Session);
      Lib.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.Package_UnloadedByAnEvaluationThenReloaded_IsArmedAgain;
// The debugger's own call unloads the package (an evaluation of
// DropPackageForEval). That unload is seen by the pump of the synthetic call,
// not by the main loop. The program then loads the package again and runs a
// routine of it the first mapping never ran; its line must be recorded.
//
// Twice per bitness. With -pkgmove the address of the first mapping is taken
// before the reload, so the second mapping is somewhere else: a session that
// was never told of the unload kept the first mapping's module record, found
// it first by name, and tried to arm at an address nothing was mapped at. (The
// test first ran without -pkgmove only, assuming the loader puts the package
// back where it was. It usually does -- not when other processes on the
// machine have the same image mapped: under the parallel suite it moved, and
// the test failed as load-sensitive.) Without it the reload usually lands at
// the same address, where a request that still believes in its old mapping
// would skip the arming.
begin
  for var Run := 0 to 3 do begin
    var Is64 := Run >= 2;
    var Moved := Odd(Run);
    var Binary := SampleBinary(Is64);
    var Caption := Binary.Caption;
    var Args := '-pkgeval';
    if Moved then begin
      Caption := Caption + ' -pkgmove';
      Args := Args + ' -pkgmove';
    end;
    var PackagePath := ExtractFilePath(Binary.Exe) + PACKAGE_NAME;
    var PackageSource := RepoRoot + 'DebuggerTests\TestPackage\' + PACKAGE_SOURCE;
    var Package := TModuleFile.Create(PackagePath, PACKAGE_SOURCE);
    var Session := StoppedAtEntry(Binary, Args);
    try
      var LateLine := Package.RvasOfLine(LineContaining(PackageSource, 'persistent-pkg-widget'));
      Assert.IsTrue(Length(LateLine) > 0, Caption + ': the package line has no record');
      var Request := Default(TLineProbeRequest);
      Request.ModuleName  := PACKAGE_NAME;
      Request.WholeModule := True;
      var Report: TLineProbeReport;
      Assert.IsTrue(Session.LineProbes.Arm(Request, Report), Caption + ': refused: ' + Report.Note);
      SetLines(Session, LineSpecs([MarkerLine('PS_PKGEVAL_LOADED'), MarkerLine('PS_PKGEVAL_DONE')]));
      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = MarkerLine('PS_PKGEVAL_LOADED')),
        Caption + ': did not stop after the load: ' + HowItEnded);
      Session.LineProbes.TryGetReport(PACKAGE_NAME, Report);
      Check(Report.State = lpsArmed, Caption + ': the package was not armed: ' + DescribeReport(Report));
      var FirstBase := Report.ModuleBase;
      Check(not AnyOf(LateLine, Session.LineProbes.Hits(PACKAGE_NAME)), Caption +
        ': the routine the second mapping runs is recorded already');

      var Value := Session.Evaluate('DropPackageForEval()');
      Check(Value.Success and Value.Value.StartsWith('7 '), Format('%s: DropPackageForEval() evaluated to "%s" (%s)',
        [Caption, Value.Value, Value.ErrorText]));
      Check(not PatchTarget(Session).ModuleIsArmed(FirstBase), Caption + ': the engine still holds the ' +
        'mapping the evaluation unloaded');

      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = MarkerLine('PS_PKGEVAL_DONE')),
        Caption + ': did not stop after the reload: ' + HowItEnded);
      // The session's module list must name the package once, at the address
      // of the second mapping -- not keep a record of the first.
      var Listed := 0;
      var NewBase: UInt64 := 0;
      for var Module in Session.GetModules do
        if SameText(Module.Name, PACKAGE_NAME) then begin
          Inc(Listed);
          NewBase := Module.Base;
        end;
      Check(Listed = 1, Format('%s: the session lists %s %d time(s) after the reload: a record of the mapping the ' +
        'evaluation unloaded was kept', [Caption, PACKAGE_NAME, Listed]));
      if Moved then
        Check(NewBase <> FirstBase, Format('%s: the package came back at $%x although that address was taken: the ' +
          'test exercised nothing', [Caption, NewBase]));
      Session.LineProbes.TryGetReport(PACKAGE_NAME, Report);
      Check((Report.State = lpsArmed) and (Report.ModuleBase = NewBase), Format('%s: the request is not armed in the ' +
        'second mapping at $%x: %s', [Caption, NewBase, DescribeReport(Report)]));
      Check(AnyOf(LateLine, Session.LineProbes.Hits(PACKAGE_NAME)), Caption + ': the routine the second ' +
        'mapping ran is not recorded: the reloaded package was not armed (' + DescribeReport(Report) + ')');
      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Caption + ': the program did not end normally: ' + HowItEnded);
    finally
      EndSession(Session);
      Package.Free;
    end;
  end;
  AssertNoProblems;
end;

{ 7. the debugger's own calls }

procedure TCodePatchTests.Evaluation_ThatRunsProbedLines_LeavesThemUnrecordedAndArmed;
// Twice has not run when the session stops; the debugger then calls it (a
// watch, a condition). Its lines carry probes: the call traps on each. That is
// not the program executing those lines, so nothing is recorded, and the
// probes are back when the call ends -- which the program's own call, later,
// proves by being recorded.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-out "' + Dir + '\record.txt"');
    try
      var Key := ExtractFileName(Binary.Exe);
      var Body := Sample.RvasOfLine(MarkerLine('PS_TWICE_BODY'));
      Assert.IsTrue(Length(Body) > 0, Binary.Caption + ': the body of Twice has no record');
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      SetLines(Session, LineSpecs([MarkerLine('PS_BEFORE_TWICE')]));
      Assert.IsTrue(RunToNextStop(Session), Binary.Caption + ': did not stop before the call of Twice: ' + HowItEnded);
      SetLines(Session, nil);
      var Target := PatchTarget(Session);
      var Before := Target.CodePatchStats;
      Check(not AnyOf(Body, Session.LineProbes.Hits(Key)), Binary.Caption + ': Twice is recorded before anything ran it');

      var Value := Session.Evaluate('Twice()');
      Check(Value.Success and Value.Value.StartsWith('6 '), Format('%s: Twice() evaluated to "%s" (%s), expected 6',
        [Binary.Caption, Value.Value, Value.ErrorText]));
      var Ran := Session.Evaluate('GEval');
      Check(Ran.Success and Ran.Value.StartsWith('1 '), Format('%s: GEval is "%s": the call did not run the body of Twice',
        [Binary.Caption, Ran.Value]));
      var After := Target.CodePatchStats;
      Check(After.HitsBySyntheticCall > Before.HitsBySyntheticCall, Binary.Caption + ': the call met no probe: ' +
        'the test exercised nothing');
      Check(After.HitsRecorded = Before.HitsRecorded, Format('%s: the evaluation recorded %d hit(s)',
        [Binary.Caption, After.HitsRecorded - Before.HitsRecorded]));
      Check(not AnyOf(Body, Session.LineProbes.Hits(Key)), Binary.Caption + ': a line the debugger''s own call ran ' +
        'is recorded as executed by the program');
      Check(After.Armed = Before.Armed, Format('%s: %d probe(s) armed before the call, %d after it',
        [Binary.Caption, Before.Armed, After.Armed]));
      for var Rva in Body do
        Check(RawByte(Session, Session.Debugger.ImageBase + Rva) = INT3,
          Format('%s: the probe at $%x was not put back after the call', [Binary.Caption, Rva]));

      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
      Check(AnyOf(Body, Session.LineProbes.Hits(Key)), Binary.Caption + ': the program''s own call of Twice was not recorded');
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the program did not compute what an undisturbed run computes');
    finally
      EndSession(Session);
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

{ 8. attach and detach }

type
  // A fixture started WITHOUT a debugger, waiting for one.
  TWaitingProcess = record
    Info: TProcessInformation;
    function Start(const Binary: TTargetBinary; const Args: string): Boolean;
    // Waits for the process to end by itself; kills it when it does not.
    function WaitForTheEnd(out ExitCode: DWORD): Boolean;
    procedure Close;
  end;

function TWaitingProcess.Start(const Binary: TTargetBinary; const Args: string): Boolean;
var
  SI: TStartupInfo;
begin
  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  var CmdLine := '"' + Binary.Exe + '" -wait-debugger ' + Args;
  UniqueString(CmdLine);
  Result := CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, Info);
  if Result then
    CloseHandle(Info.hThread);
end;

function TWaitingProcess.WaitForTheEnd(out ExitCode: DWORD): Boolean;
begin
  ExitCode := DWORD(-1);
  Result := WaitForSingleObject(Info.hProcess, 20000) = WAIT_OBJECT_0;
  if Result then
    GetExitCodeProcess(Info.hProcess, ExitCode);
end;

procedure TWaitingProcess.Close;
begin
  // A program that sits in an error box must not outlive the test.
  if WaitForSingleObject(Info.hProcess, 0) <> WAIT_OBJECT_0 then begin
    TerminateProcess(Info.hProcess, 9);
    WaitForSingleObject(Info.hProcess, 5000);
  end;
  CloseHandle(Info.hProcess);
end;

function AttachTo(const Binary: TTargetBinary; Pid: DWORD): TDebugSession;
begin
  Result := TDebugSession.Create;
  try
    GWatch.Reset;
    Result.OnSessionExited  := GWatch.HandleExit;
    Result.OnSessionStopped := GWatch.HandleStop;
    var Opts := Default(TAttachOptions);
    Opts.ProgramPath := Binary.Exe;
    Opts.MapPath     := Binary.Map;
    Opts.RsmPath     := Binary.Rsm;
    Opts.SourceRoot  := Binary.SourceRoot;
    Opts.ExceptionFilters    := Default(TExceptionFilters);
    Opts.ExceptionFiltersSet := True;
    Result.Attach(Pid, False, Opts);   // killOnDetach = False: a clean detach
    // The attach is complete once its events have been read.
    PumpFor(Result, 150);
  except
    Result.Free;
    raise;
  end;
end;

procedure TCodePatchTests.AttachArmDetach_RefusedWithoutAcceptance_ThenTheProgramRunsOnThroughArmedLines;
// The process was attached to with killOnDetach false: Windows lets it live if
// the debugger dies, and a dead debugger takes no byte back. Arming is refused
// until the request says that this is accepted.
//
// Then the clean case: the program runs the first half of its work under the
// probes and waits until no debugger is attached. The detach restores every
// byte; the second half runs through lines that WERE armed, with nobody
// listening, and the program writes its record and ends normally.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Dir := MakeTestScratchDir(SCRATCH_PREFIX);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Process: TWaitingProcess;
    Assert.IsTrue(Process.Start(Binary, '-wait-detach -out "' + Dir + '\record.txt"'), Binary.Caption + ': CreateProcess failed');
    try
      var Key := ExtractFileName(Binary.Exe);
      var HitsBefore: TArray<Cardinal> := nil;
      var Second := Sample.RvasOfLine(MarkerLine('PS_LAYER_BEFORE'));
      var Session := AttachTo(Binary, Process.Info.dwProcessId);
      try
        var Report: TLineProbeReport;
        var Accepted := ArmWholeModule(Session, Key, Report, False);
        Check(not Accepted, Binary.Caption + ': arming was accepted on a process that would survive a dead debugger');
        Check(Report.Note.Contains('killOnDetach'), Binary.Caption + ': the refusal does not say why: "' + Report.Note + '"');
        Check(PatchTarget(Session).CodePatchStats.Armed = 0, Binary.Caption + ': a refused request armed something');

        Assert.IsTrue(ArmWholeModule(Session, Key, Report, True), Binary.Caption + ': refused although accepted: ' + Report.Note);
        Check((Report.State = lpsArmed) and (Report.ArmedAt = 'the request'), Binary.Caption + ': ' + DescribeReport(Report));
        // The first half: until no new line has been recorded for a while.
        var Last := -1;
        var QuietSince := GetTickCount64;
        var Deadline := GetTickCount64 + STOP_TIMEOUT_MS;
        while (GetTickCount64 < Deadline) and (not Session.HasExited) do begin
          Session.Pump;
          var Now := PatchTarget(Session).CodePatchStats.HitsRecorded;
          if Now <> Last then begin
            Last := Now;
            QuietSince := GetTickCount64;
          end;
          var Quiet := GetTickCount64 - QuietSince;
          if ((Last > 20) and (Quiet > 400)) or (Quiet > 4000) then
            Break;
        end;
        Check(not Session.HasExited, Binary.Caption + ': the program ended before the detach: ' + HowItEnded);
        HitsBefore := Session.LineProbes.Hits(Key);
        Check(AnyOf(Second, PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase)),
          Binary.Caption + ': the first line of the second half is not armed at the detach');
        Session.Detach;
        Check(Length(Session.LineProbes.Hits(Key)) = Length(HitsBefore), Binary.Caption + ': the hits are not readable after the detach');
      finally
        Session.Free;
      end;

      var ExitCode: DWORD;
      var Ended := Process.WaitForTheEnd(ExitCode);
      Check(Ended, Binary.Caption + ': the detached program did not end: it sits on a breakpoint byte nobody took back');
      if Ended then
        Check(ExitCode = 0, Format('%s: the detached program ended with code %d ($%x)', [Binary.Caption, Integer(ExitCode), ExitCode]));
      var Written := ReadProgramRecord(Dir + '\record.txt');
      Check(Written.Valid and (Written.Sink = ReferenceRecord(Is64).Sink), Binary.Caption +
        ': the detached program did not compute what an undisturbed run computes');
      // Not vacuous: the second half ran, and after the detach.
      Check(Written.Ran[45], Binary.Caption + ': the second half of the program did not run');
      Check(not AnyOf(Second, HitsBefore), Binary.Caption + ': the second half had already run at the detach');
      var Lines := MarkLines;
      for var Mark := 0 to MAX_MARK do
        if (Lines[Mark] > 0) and AnyOf(Sample.RvasOfLine(Lines[Mark]), HitsBefore) then
          Check(Written.Ran[Mark], Format('%s: mark %d is recorded as hit and the program says it did not run',
            [Binary.Caption, Mark]));
    finally
      Process.Close;
      Sample.Free;
      DeleteTempDirWithRetry(Dir);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.Detach_WithTrapsQueued_PutsEveryThreadBackOnItsInstruction;
// Four threads are racing through probed lines when the debugger stops
// reading events and detaches. At least one of them has trapped and its event
// is in the queue; the detach completes such an event as "not handled", and
// the thread stands one byte into an instruction whose first byte is back. It
// must be found in the queue and rewound first. Every thread checks its own
// sum.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Process: TWaitingProcess;
    Assert.IsTrue(Process.Start(Binary, '-race'), Binary.Caption + ': CreateProcess failed');
    try
      var Key := ExtractFileName(Binary.Exe);
      var Session := AttachTo(Binary, Process.Info.dwProcessId);
      try
        var Report: TLineProbeReport;
        Assert.IsTrue(ArmWholeModule(Session, Key, Report, True), Binary.Caption + ': refused: ' + Report.Note);
        Assert.IsTrue(PumpIntoTheLongRun(Session, Sample, Key),
          Binary.Caption + ': the threads were never seen inside LongRun: ' + HowItEnded);
        // Not pumping: every thread traps on its next line and the events queue.
        Sleep(50);
        Session.Detach;
      finally
        Session.Free;
      end;
      var ExitCode: DWORD;
      var Ended := Process.WaitForTheEnd(ExitCode);
      Check(Ended, Binary.Caption + ': the detached program did not end');
      if Ended then
        Check(ExitCode = 0, Format('%s: the detached program ended with code %d ($%x): a thread whose trap was ' +
          'queued at the detach was not put back on its instruction', [Binary.Caption, Integer(ExitCode), ExitCode]));
    finally
      Process.Close;
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.Detach_AtAPauseStop_ReleasesTheHeldEvent_AndTheQueuedTrapsAreRewound;
// Four threads round one line that carries a logpoint: at most moments some
// of them have a trap queued. A Pause stops the process -- on the event of the
// thread Windows injects for the break-in, while the thread REPORTED is the
// main one -- and the debugger detaches from there. The held event is the
// injected thread's: continued under the reported thread's id, the call fails,
// the event stays outstanding, nothing more is delivered, the queued traps are
// never read, and they reach the detached program as breakpoint exceptions one
// byte into an instruction.
//
// A race: a trap is queued behind the pause or it is not (measured with the
// release under the wrong id: two runs of three failed). Three attempts per
// bitness.
const
  LOGGED_PASSES = 50;
  ATTEMPTS      = 3;
begin
  for var Run := 0 to 2 * ATTEMPTS - 1 do begin
    var Is64 := Run >= ATTEMPTS;
    var Attempt := Run mod ATTEMPTS + 1;
    var Binary := SampleBinary(Is64);
    var Process: TWaitingProcess;
    Assert.IsTrue(Process.Start(Binary, '-hot'), Binary.Caption + ': CreateProcess failed');
    try
      var Session := AttachTo(Binary, Process.Info.dwProcessId);
      try
        // A logpoint: it never stops, and its lines say that the threads are
        // round the line (the program waits a second after the attach).
        var Spec := Default(TBpLineSpec);
        Spec.Line       := MarkerLine('PS_HOT_LINE');
        Spec.LogMessage := 'hot';
        SetLines(Session, [Spec]);
        var Logged := 0;
        var Deadline := GetTickCount64 + STOP_TIMEOUT_MS;
        while (Logged < LOGGED_PASSES) and (not Session.HasExited) and (GetTickCount64 < Deadline) do begin
          Session.Pump;
          for var Text in Session.DrainDebuggerOutput do
            if Text.Contains('hot') then
              Inc(Logged);
        end;
        Check(Logged >= LOGGED_PASSES, Format('%s: the logpoint logged %d time(s): the threads never ran round ' +
          'the line, and the test exercised nothing', [Binary.Caption, Logged]));
        Session.Pause;
        PumpUntilStoppedOrExited(Session, 10000);
        Check((Session.State = dsStopped) and (GWatch.LastReason = srPause),
          Format('%s: the pause did not stop the program (state %d, reason %d)',
            [Binary.Caption, Ord(Session.State), Ord(GWatch.LastReason)]));
        Session.Detach;
      finally
        Session.Free;
      end;
      var ExitCode: DWORD;
      var Ended := Process.WaitForTheEnd(ExitCode);
      Check(Ended, Binary.Caption + ': the detached program did not end');
      if Ended then
        Check(ExitCode = 0, Format('%s, attempt %d: the program detached at a pause stop ended with code %d ($%x): ' +
          'a trap queued behind the stop reached it', [Binary.Caption, Attempt, Integer(ExitCode), ExitCode]));
    finally
      Process.Close;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.Terminate_AtAPauseStop_EndsTheProcessWithoutWaiting;
// The kill branch of the engine's Terminate continues the held event before it
// reads the kill's events. At a pause stop the held event is the injected
// thread's; continued under the reported thread's id the call failed, nothing
// more was delivered -- the exit event included -- and the end waited out the
// whole three-second drain.
const
  PROMPT_MS = 2000;
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Session := LaunchSample(Binary, False, '-hot');
    try
      PumpFor(Session, 300);
      Session.Pause;
      PumpUntilStoppedOrExited(Session, 10000);
      Check((Session.State = dsStopped) and (GWatch.LastReason = srPause),
        Format('%s: the pause did not stop the program (state %d, reason %d)',
          [Binary.Caption, Ord(Session.State), Ord(GWatch.LastReason)]));
      var Started := GetTickCount64;
      Session.Terminate;
      var Took := GetTickCount64 - Started;
      Check(Took < PROMPT_MS, Format('%s: ending the session at a pause stop took %d ms: the exit event was not ' +
        'delivered', [Binary.Caption, Took]));
    finally
      FreeAndNil(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.Detach_WithASoftwareBreakpointExceptionQueued_HandsItToTheProgram;
// A thread raises EXCEPTION_BREAKPOINT through RaiseException, over and over,
// and catches it. The debugger stops reading events for a moment, so that one
// of those is queued, and detaches. The drain at the detach puts a thread back
// on its instruction only when it trapped on a byte of OURS: this exception is
// the program's, reported at an address inside RaiseException where the byte
// is not $CC, and it must reach the program's handler. Rewound and continued
// instead, it was swallowed: the program counts what it raised and caught.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Process: TWaitingProcess;
    Assert.IsTrue(Process.Start(Binary, '-softbreak'), Binary.Caption + ': CreateProcess failed');
    try
      var Session := AttachTo(Binary, Process.Info.dwProcessId);
      try
        // The program waits a second after the attach before it starts
        // raising; then a few hundred milliseconds of exceptions.
        PumpFor(Session, 1600);
        Check(not Session.HasExited, Binary.Caption + ': the program ended before the detach: ' + HowItEnded);
        // Not pumping: the thread raises again and its event waits.
        Sleep(50);
        Session.Detach;
      finally
        Session.Free;
      end;
      var ExitCode: DWORD;
      var Ended := Process.WaitForTheEnd(ExitCode);
      Check(Ended, Binary.Caption + ': the detached program did not end');
      if Ended then
        Check(ExitCode = 0, Format('%s: the detached program ended with code %d ($%x): a breakpoint exception it ' +
          'raised itself did not reach its handler', [Binary.Caption, Integer(ExitCode), ExitCode]));
    finally
      Process.Close;
    end;
  end;
  AssertNoProblems;
end;

{ 9. readers of code }

// The direct calls from one routine of the fixture into another, from the
// routine analysis of the FILE: module-relative addresses of the `call`.
function CallSitesInto(Sample: TModuleFile; const CallerName, CalleeName: string): TArray<Cardinal>;
begin
  Result := nil;
  var Caller := Sample.RoutineNamed(CallerName);
  var Callee := Sample.RoutineNamed(CalleeName);
  Assert.IsTrue((Caller >= 0) and (Callee >= 0), 'routine ' + CallerName + ' or ' + CalleeName + ' not found');
  var Input := Default(TRoutineAnalysisInput);
  Input.Mode := dmmLegacy32;
  if Sample.Image.Is64 then
    Input.Mode := dmmLong64;
  Input.Reader       := Sample.Image.Read;
  Input.ImageBase    := Sample.Image.ImageBase;
  Input.CodeMap      := Sample.Map;
  Input.ZydisDllPath := ResolveZydisDllPathForThisExe;
  var Analyzer := TRoutineAnalyzer.Create(Input);
  try
    for var Site in Analyzer.Analyze(Caller).CallSites do
      if Site.TargetRva = Int64(Sample.Map.Routines[Callee].StartRva) then
        Result := Result + [Site.CallRva];
  finally
    Analyzer.Free;
  end;
end;

function StackNames(Session: TDebugSession): string;
begin
  Result := '';
  for var Frame in Session.GetCallStack do
    Result := Result + Frame.FunctionName + '@' + IntToStr(Frame.SourceLine) + ' ';
  Result := Result.Trim;
end;

// The raw stack scan: every stack word that is a return address, and whether
// the call in front of it was decoded (x86 only; on x64 every hit is unproven).
function RawScanText(Session: TDebugSession): string;
begin
  Result := '';
  for var Frame in Session.GetRawStackScan do
    Result := Result + Format('%s@%d:%d ', [Frame.FunctionName, Frame.SourceLine, Ord(Frame.Origin)]);
  Result := Result.Trim;
end;

procedure TCodePatchTests.CodeReaders_SeeTheProgramUnderAnArmedProbe;
// Stopped inside StepCallee, probes are put on the ENTRIES of the routines on
// the stack -- the `push ebp` / `push rbp` the prologue decoder looks for --
// and on the `call` in StepArea that the stopped frame returns to, through the
// engine directly, since those lines have already run. Everything that reads
// code must go on seeing the program: the code reader, the plain memory
// reader, the stack walk (on x86 it proves a return address by the call in
// front of it), and the locals, which on x86 depend on the prologue being
// recognised.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary);
    try
      var Key := ExtractFileName(Binary.Exe);
      SetLines(Session, LineSpecs([MarkerLine('PS_STEP_CALLEE')]));
      Assert.IsTrue(RunToNextStop(Session), Binary.Caption + ': the callee did not stop: ' + HowItEnded);
      SetLines(Session, nil);
      var StackBefore := StackNames(Session);
      var RawBefore := RawScanText(Session);
      // The program's own bytes, read before anything is written over them.
      // (Not the file's: the loader has relocated the operands.)
      var ProgramCode: TArray<Byte>;
      var ValueBefore := Session.Evaluate('X');
      Assert.IsTrue(ValueBefore.Success, Binary.Caption + ': the parameter X does not evaluate without probes: ' + ValueBefore.ErrorText);

      var Entries: TArray<Cardinal> := nil;
      for var Name in ['StepCallee', 'StepArea'] do begin
        var Routine := Sample.RoutineNamed(Name);
        Assert.IsTrue(Routine >= 0, Binary.Caption + ': routine ' + Name + ' not found');
        Entries := Entries + [Sample.Map.Routines[Routine].StartRva];
      end;
      var Calls := CallSitesInto(Sample, 'StepArea', 'StepCallee');
      Assert.AreEqual(1, Integer(Length(Calls)), Binary.Caption + ': StepArea should call StepCallee once');
      Assert.AreEqual($E8, Integer(Sample.ProgramByte(Calls[0])), Binary.Caption + ': the call is not a direct call');
      Entries := Entries + Calls;
      // A window that starts before the first entry and ends after the last.
      var Lo := Entries[0];
      var Hi := Entries[0];
      for var Rva in Entries do begin
        if Rva < Lo then
          Lo := Rva;
        if Rva > Hi then
          Hi := Rva;
      end;
      Dec(Lo, 8);
      SetLength(ProgramCode, Hi - Lo + 16);
      var Got: SIZE_T;
      Assert.IsTrue(ReadProcessMemory(Session.Debugger.ProcessHandle, Pointer(Session.Debugger.ImageBase + Lo),
        @ProgramCode[0], Length(ProgramCode), Got) and (Got = SIZE_T(Length(ProgramCode))),
        Binary.Caption + ': the code of the two routines could not be read');
      for var Rva in Entries do
        Assert.AreNotEqual(INT3, Integer(ProgramCode[Rva - Lo]), Binary.Caption + ': a routine entry holds a $CC before anything was armed');

      var Request := Default(TCodePatchArmRequest);
      Request.ModuleBase := Session.Debugger.ImageBase;
      Request.ResultKey  := LowerCase(Key);
      Request.Rvas       := Entries;
      var Outcome: TCodePatchArmOutcome;
      var Refusal: string;
      Assert.IsTrue(PatchTarget(Session).ArmOneShotProbes(Request, Outcome, Refusal), Binary.Caption + ': ' + Refusal);
      Assert.AreEqual(Integer(Length(Entries)), Outcome.Armed, Binary.Caption + ': probes armed on the routine entries');

      for var Rva in Entries do begin
        var VA := Session.Debugger.ImageBase + Rva;
        var Program_ := Sample.ProgramByte(Rva);
        Check(RawByte(Session, VA) = INT3, Format('%s: no probe at $%x', [Binary.Caption, Rva]));
        Check(CodeByte(Session, VA) = Program_, Format('%s: the code reader sees $%x at $%x, the program has $%x',
          [Binary.Caption, CodeByte(Session, VA), Rva, Program_]));
        var Plain: Byte := 0;
        Check(Session.Debugger.ReadProcessMemoryAt(VA, @Plain, 1) and (Plain = Program_),
          Format('%s: the memory reader sees $%x at $%x, the program has $%x', [Binary.Caption, Plain, Rva, Program_]));
      end;
      // The whole window, through the code reader and through the plain one.
      var Window: TArray<Byte>;
      SetLength(Window, Length(ProgramCode));
      Assert.AreEqual(NativeUInt(Length(Window)), Session.Debugger.ReadCodeMemoryAt(Session.Debugger.ImageBase + Lo,
        @Window[0], Length(Window)), Binary.Caption + ': the window could not be read');
      for var I := 0 to High(Window) do
        if Window[I] <> ProgramCode[I] then begin
          Check(False, Format('%s: the code reader''s window differs from the program at $%x', [Binary.Caption, Lo + Cardinal(I)]));
          Break;
        end;
      Assert.IsTrue(Session.Debugger.ReadProcessMemoryAt(Session.Debugger.ImageBase + Lo, @Window[0], Length(Window)),
        Binary.Caption + ': the window could not be read as memory');
      for var I := 0 to High(Window) do
        if Window[I] <> ProgramCode[I] then begin
          Check(False, Format('%s: the memory reader''s window differs from the program at $%x', [Binary.Caption, Lo + Cardinal(I)]));
          Break;
        end;

      Check(StackNames(Session) = StackBefore, Format('%s: the call stack is [%s] with probes on the routine entries, ' +
        '[%s] without', [Binary.Caption, StackNames(Session), StackBefore]));
      Check(RawScanText(Session) = RawBefore, Format('%s: the raw stack scan is [%s] with a probe on the call, [%s] ' +
        'without', [Binary.Caption, RawScanText(Session), RawBefore]));
      var ValueAfter := Session.Evaluate('X');
      Check(ValueAfter.Success and (ValueAfter.Value = ValueBefore.Value), Format('%s: X evaluates to "%s" (%s) with a ' +
        'probe on the routine''s entry, "%s" without', [Binary.Caption, ValueAfter.Value, ValueAfter.ErrorText, ValueBefore.Value]));

      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
    finally
      EndSession(Session);
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.MemoryWrittenOverAProbe_IsTheProgramsAndABreakpointPlantedThereFires;
// A memory write (a user's memory editor, DAP writeMemory) over an armed probe
// replaces the probe's byte. From then on the byte is the program's, and the
// map must say so: a breakpoint planted there later would otherwise take the
// probe for the holder of a $CC that is not in the target, write nothing, and
// never fire.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary);
    try
      var Site := LayerSite(Session, Sample);
      var Key := ExtractFileName(Binary.Exe);
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, Key, Report), Binary.Caption + ': refused: ' + Report.Note);
      Check(RawByte(Session, Site.VaA) = INT3, Binary.Caption + ': no probe on the line');
      var ProgramByte := Site.ByteA;
      Check(Session.Debugger.WriteMemoryAt(Site.VaA, @ProgramByte, 1), Binary.Caption + ': the memory write failed');
      Check(RawByte(Session, Site.VaA) = Site.ByteA, Binary.Caption + ': the byte written is not in the target');
      Check(not Contains(PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase), Site.RvaA),
        Binary.Caption + ': the map still lists a probe whose byte a memory write replaced');
      SetLines(Session, LineSpecs([Site.LineA]));
      Check(RawByte(Session, Site.VaA) = INT3, Format('%s: the breakpoint on the written byte is not planted (the ' +
        'byte is $%x)', [Binary.Caption, RawByte(Session, Site.VaA)]));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOf(Stops, Site.LineA) = LAYER_PASSES, Format('%s: the breakpoint stopped %d time(s) on %d passes (%s)',
        [Binary.Caption, CountOf(Stops, Site.LineA), LAYER_PASSES, LinesText(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
    finally
      EndSession(Session);
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodePatchTests.ProgramRewritesAProbedByte_ReadersShowItsByte_AndABreakpointThereFires;
// The program writes over two bytes of its own code after the probes were
// armed -- the CLC of Rewritable1 and of Rewritable2 become STC -- the way a
// hooking library writes over a routine's first bytes. Only the debugger's own
// writes tell the patch map, so the map still believes its $CC is there.
//
//   * Rewritable1: a breakpoint is planted on the rewritten line BEFORE
//     anything reads that code. It must not adopt the probe (the byte is no
//     longer $CC), and it must fire.
//   * Rewritable2: the code readers must show the PROGRAM's new byte, not the
//     byte the probe had saved.
//
// Kept apart because each fix would hide the other's absence: a read gives
// the stale probe up, after which the breakpoint plants normally.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary(Is64);
    var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
    var Session := StoppedAtEntry(Binary, '-rewrite');
    try
      var Suffix := '_32';
      if Is64 then
        Suffix := '_64';
      var Line1 := MarkerLine('PS_REWRITE1' + Suffix);
      var Line2 := MarkerLine('PS_REWRITE2' + Suffix);
      var Rva1 := Sample.RvasOfLine(Line1);
      var Rva2 := Sample.RvasOfLine(Line2);
      Assert.IsTrue((Length(Rva1) = 1) and (Length(Rva2) = 1), Binary.Caption + ': the CLC lines should have one record each');
      Assert.AreEqual($F8, Integer(Sample.ProgramByte(Rva1[0])), Binary.Caption + ': the first rewritten line is not a CLC');
      Assert.AreEqual($F8, Integer(Sample.ProgramByte(Rva2[0])), Binary.Caption + ': the second rewritten line is not a CLC');
      var VA1 := Session.Debugger.ImageBase + Rva1[0];
      var VA2 := Session.Debugger.ImageBase + Rva2[0];
      var Report: TLineProbeReport;
      Assert.IsTrue(ArmWholeModule(Session, ExtractFileName(Binary.Exe), Report), Binary.Caption + ': refused: ' + Report.Note);
      Check((RawByte(Session, VA1) = INT3) and (RawByte(Session, VA2) = INT3), Binary.Caption + ': the CLC lines carry no probe');
      var DoneLine := MarkerLine('PS_REWRITE_DONE');
      SetLines(Session, LineSpecs([DoneLine]));
      Assert.IsTrue(RunToNextStop(Session) and (CurrentLine(Session) = DoneLine),
        Binary.Caption + ': did not stop after the rewrite: ' + HowItEnded);
      Check((RawByte(Session, VA1) = $F9) and (RawByte(Session, VA2) = $F9), Binary.Caption + ': the program did not ' +
        'write its bytes');

      // Rewritable1: a breakpoint, before anything reads that code. An ADDRESS
      // breakpoint: a source breakpoint is judged by the routine analysis
      // first, whose read of the code gives the stale probe up on its own.
      var AddrBp := Session.SetAddressBreakpoint(VA1, '', '', '');
      Session.Pump;
      Check(AddrBp.Verified, Binary.Caption + ': the address breakpoint on the rewritten byte is not verified');
      Check(RawByte(Session, VA1) = INT3, Format('%s: the breakpoint on the rewritten byte is not planted (the byte ' +
        'is $%x): it adopted a probe whose byte the program had replaced', [Binary.Caption, RawByte(Session, VA1)]));
      Check(RunToNextStop(Session) and (CurrentLine(Session) = Line1), Format('%s: the breakpoint on the rewritten ' +
        'byte did not stop (line %d): %s', [Binary.Caption, CurrentLine(Session), HowItEnded]));
      Session.RemoveAddressBreakpoint(AddrBp.Id);

      // Rewritable2: the readers.
      Check(CodeByte(Session, VA2) = $F9, Format('%s: the code reader shows $%x on the rewritten byte, the program ' +
        'has $F9', [Binary.Caption, CodeByte(Session, VA2)]));
      var Plain: Byte := 0;
      Check(Session.Debugger.ReadProcessMemoryAt(VA2, @Plain, 1) and (Plain = $F9), Format('%s: the memory reader ' +
        'shows $%x on the rewritten byte, the program has $F9', [Binary.Caption, Plain]));
      Check(not Contains(PatchTarget(Session).ArmedProbes(Session.Debugger.ImageBase), Rva2[0]),
        Binary.Caption + ': the map still lists a probe whose byte the program replaced');

      SetLines(Session, nil);
      var Ended: Boolean;
      RunToTheEnd(Session, Ended);
      Check(Ended, Binary.Caption + ': the program did not end normally: ' + HowItEnded);
    finally
      EndSession(Session);
      Sample.Free;
    end;
  end;
  AssertNoProblems;
end;

{ 10. the requests }

type
  // A second routine provider whose index the test says is still building.
  TGatedRoutineProvider = class(TInterfacedObject, IRoutineRangeProvider, IBackgroundIndexProvider)
  private
    FInner: IRoutineRangeProvider;
  public
    Pending: Boolean;
    constructor Create(const Inner: IRoutineRangeProvider);
    function RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
    function BackgroundIndexingPending: Boolean;
  end;

  // An engine that records what it was asked to arm.
  TRecordingPatchTarget = class(TInterfacedObject, ICodePatchTarget)
  public
    Armed: TList<Cardinal>;
    ArmCalls: Integer;
    constructor Create;
    destructor Destroy; override;
    function ArmOneShotProbes(const Request: TCodePatchArmRequest;
      out Outcome: TCodePatchArmOutcome; out Refusal: string): Boolean;
    function DisarmProbes(ModuleBase: UInt64): TCodePatchDisarmOutcome;
    function ProbeHits(const ResultKey: string): TArray<Cardinal>;
    function ArmedProbes(ModuleBase: UInt64): TArray<Cardinal>;
    function ModuleIsArmed(ModuleBase: UInt64): Boolean;
    procedure ClearProbeHits;
    function CodePatchStats: TCodePatchStats;
  end;

constructor TGatedRoutineProvider.Create(const Inner: IRoutineRangeProvider);
begin
  inherited Create;
  FInner := Inner;
end;

function TGatedRoutineProvider.RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
begin
  Result := FInner.RoutineRanges(Complete);
end;

function TGatedRoutineProvider.BackgroundIndexingPending: Boolean;
begin
  Result := Pending;
end;

constructor TRecordingPatchTarget.Create;
begin
  inherited Create;
  Armed := TList<Cardinal>.Create;
end;

destructor TRecordingPatchTarget.Destroy;
begin
  Armed.Free;
  inherited;
end;

function TRecordingPatchTarget.ArmOneShotProbes(const Request: TCodePatchArmRequest;
  out Outcome: TCodePatchArmOutcome; out Refusal: string): Boolean;
begin
  Outcome := Default(TCodePatchArmOutcome);
  Refusal := '';
  Inc(ArmCalls);
  Outcome.Requested := Length(Request.Rvas);
  for var Rva in Request.Rvas do
    if Armed.Contains(Rva) then
      Inc(Outcome.AlreadyPresent)
    else begin
      Armed.Add(Rva);
      Inc(Outcome.Armed);
    end;
  Result := True;
end;

function TRecordingPatchTarget.DisarmProbes(ModuleBase: UInt64): TCodePatchDisarmOutcome;
begin
  Result := Default(TCodePatchDisarmOutcome);
  Result.Restored := Armed.Count;
  Armed.Clear;
end;

function TRecordingPatchTarget.ProbeHits(const ResultKey: string): TArray<Cardinal>;
begin
  Result := nil;
end;

function TRecordingPatchTarget.ArmedProbes(ModuleBase: UInt64): TArray<Cardinal>;
begin
  Result := Armed.ToArray;
  TArray.Sort<Cardinal>(Result);
end;

function TRecordingPatchTarget.ModuleIsArmed(ModuleBase: UInt64): Boolean;
begin
  Result := ArmCalls > 0;
end;

procedure TRecordingPatchTarget.ClearProbeHits;
begin
end;

function TRecordingPatchTarget.CodePatchStats: TCodePatchStats;
begin
  Result := Default(TCodePatchStats);
  Result.Armed := Armed.Count;
end;

procedure TCodePatchTests.Request_ArmedWhileTheMapIndexes_ArmsTheAnonymousBodiesOnceItIsReady;
// On x86 TD32 has no procedure record for the body of an anonymous method; a
// MAP names it, and indexes its publics on a thread of its own. A request armed
// before that index is ready is armed for everything else and says it is
// partial. The retry does nothing (and analyses nothing) while the index is
// still building, and arms the bodies as soon as it is ready -- here without a
// process, over the 32-bit fixture read as a file.
const
  ANONYMOUS_BODY_MARK = 29;
begin
  var Binary := SampleBinary(False);
  var Sample := TModuleFile.Create(Binary.Exe, SAMPLE_SOURCE);
  var Image := TPeImageFile.Create(Binary.Exe);
  try
    var Reader := TTD32FileReader.Create;
    var ReaderRef: IInterface := Reader;
    Reader.LoadFromFile(Binary.Exe);
    var MapReader := TMapFile.Create;
    var MapRef: IInterface := MapReader;
    MapReader.LoadFromFile(Binary.Map, ReadPEPreferredBase(Binary.Exe));
    var Deadline := GetTickCount64 + 30000;
    while MapReader.BackgroundIndexingPending and (GetTickCount64 < Deadline) do
      Sleep(5);
    Assert.IsFalse(MapReader.BackgroundIndexingPending, 'the MAP of the fixture did not finish indexing');
    var MapRoutines: IRoutineRangeProvider;
    Assert.IsTrue(Supports(MapRef, IRoutineRangeProvider, MapRoutines), 'the MAP reader gives no routine ranges');
    var Gate := TGatedRoutineProvider.Create(MapRoutines);
    var GateRef: IInterface := Gate;
    Gate.Pending := True;

    var Base := Image.ImageBase;
    var Size: UInt64 := Image.SizeOfImage;
    var ModuleName := ExtractFileName(Binary.Exe);
    var Providers: TArray<IInterface> := [ReaderRef, GateRef];
    var Analysis := TLiveCodeAnalysis.Create(Image.Read,
      function(VA: UInt64; out Info: TLiveModuleInfo): Boolean
      begin
        Info := Default(TLiveModuleInfo);
        Result := (VA >= Base) and (VA - Base < Size);
        if not Result then
          Exit;
        Info.Name      := ModuleName;
        Info.Base      := Base;
        Info.Size      := Size;
        Info.Providers := Providers;
      end);
    var Engine := TRecordingPatchTarget.Create;
    var EngineRef: ICodePatchTarget := Engine;
    var Host: TLineProbeHost := nil;
    try
      Analysis.ZydisDllPath := ResolveZydisDllPathForThisExe;
      Host := TLineProbeHost.Create(Analysis,
        function: ICodePatchTarget
        begin
          Result := EngineRef;
        end,
        function(const Name: string; out ModuleBase: UInt64): Boolean
        begin
          ModuleBase := Base;
          Result := SameText(Name, ModuleName);
        end);

      var Lines := MarkLines;
      var Body := Sample.RvasOfLine(Lines[ANONYMOUS_BODY_MARK]);
      Assert.IsTrue(Length(Body) > 0, 'the anonymous method''s line has no record');
      var Request := Default(TLineProbeRequest);
      Request.ModuleName  := ModuleName;
      Request.WholeModule := True;
      var Report: TLineProbeReport;
      Assert.IsTrue(Host.Arm(Request, Report), 'refused: ' + Report.Note);
      Check((Report.State = lpsArmed) and Report.Partial, 'armed while the MAP indexes: ' + DescribeReport(Report));
      Check(not AnyOf(Body, Engine.ArmedProbes(Base)), 'the anonymous body was armed without the MAP that proves it');
      Check(Host.HasWaiting, 'a partial request does not wait for the rest');
      var FirstCount := Engine.Armed.Count;

      // Still indexing: the retry neither analyses nor arms.
      var CallsBefore := Engine.ArmCalls;
      Host.RetryWaiting;
      Check(Engine.ArmCalls = CallsBefore, 'the retry armed again while the MAP was still indexing');

      Gate.Pending := False;
      Host.RetryWaiting;
      Host.TryGetReport(ModuleName, Report);
      Check((Report.State = lpsArmed) and not Report.Partial, 'after the MAP was ready: ' + DescribeReport(Report));
      Check(AnyOf(Body, Engine.ArmedProbes(Base)), 'the anonymous body was not armed once the MAP was ready');
      Check(Engine.Armed.Count > FirstCount, 'nothing was added once the MAP was ready');
      Check(not Host.HasWaiting, 'the request still waits after it was armed in full');
    finally
      Host.Free;
      EngineRef := nil;
      Analysis.Free;
    end;
  finally
    Image.Free;
    Sample.Free;
  end;
  AssertNoProblems;
end;

initialization
  GWatch := TSessionWatcher.Create;
  TDUnitX.RegisterTestFixture(TCodePatchTests);

finalization
  GWatch.Free;

end.
