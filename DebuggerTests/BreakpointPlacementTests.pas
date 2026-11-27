unit BreakpointPlacementTests;

// Where a source breakpoint is planted, and what happens to the byte when
// breakpoint records share an address (docs/DAP_DEBUGGER_ARCHITECTURE.md,
// "Breakpoints"). Six things are pinned here:
//
//   1. THE ANALYSIS DECIDES. A source breakpoint is refused only on an address
//      the routine analysis shows to be something else than the start of an
//      instruction; an address it merely cannot confirm is planted (the body
//      of an anonymous method on x86 without a MAP).
//   2. ONE BYTE, SEVERAL RECORDS. Removing a breakpoint leaves the $CC in
//      place while another record at the same address needs it.
//   3. COPIES. On x64 a line inside a `finally` block has its code twice,
//      inline and in a funclet; the breakpoint sits in both. A `for` line has
//      two records as well and still stops once per entry into the loop.
//   4. THE BYTE UNDER A RUNNING THREAD. The $CC is taken away for ONE thread
//      and ONE instruction and goes back on that thread's own single step:
//      with several threads, when the address is planted again under a parked
//      thread, when a thread is resumed from a planted address, during a
//      function call made at a stop, and at a detach.
//   5. WHEN THE ANALYSIS HAS TO WAIT. An index still being built is not
//      waited for, a module relocated after its load event is judged again at
//      its entry point, and providers that arrive later are used.
//   6. A UNIT'S FINAL END. Its line record points past the unit's last
//      routine; where the bytes there happen to decode it is refused as what
//      it is, and nothing else is.
//
// Protocol-free: every test drives TDebugSession directly. The fixture is
// DebuggerTests\TestTarget\BreakpointSample.dpr, plus AnalysisSample.dpr for a
// line record inside a jump table, plus the ordinary TestTarget / TestHost pair
// wherever the same thing has to hold in a package.
//
// Tests that run on several binaries COLLECT their failures instead of
// asserting per binary: the executables of both bitnesses carry the same name,
// and a first-failure abort would hide the other one (docs/TRAPS.md).

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  [TestFixture]
  TBreakpointPlacementTests = class
  private
    FProblems: TList<string>;
    procedure Check(Condition: Boolean; const Problem: string);
    procedure AssertNoProblems;
    procedure CheckTheProgramComputedTheSame(const Caption: string; Is64: Boolean);
  private
    // The prefetch test: what the load hook saw of the package.
    FHookSession:   TObject;
    FHookProbeVA:   UInt64;
    FHookProviders: Integer;
    FHookNote:      string;
    procedure LoadMapOfThePackageAndAsk(const Name, Path: string; Base, ImageSize: UInt64);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // --- 1. the analysis decides ---
    [Test] procedure LineInsideAJumpTable_IsRefusedWithThatReason_AndTheProgramRuns;
    [Test] procedure DecisionFunction_RefusesInsideAnInstruction_AndPlantsOnABoundary;
    [Test] procedure Bpl_EndOfThePackageSource_IsRefusedThroughTheAnalysis;
    [Test] procedure AnonymousMethodBody_BindsAndFires_WithAndWithoutAMap;

    // --- 2. one byte, several records ---
    [Test] procedure SharedAddress_AddressBreakpointRemoved_TheSourceBreakpointStillFires;
    [Test] procedure SharedAddress_SourceBreakpointRemoved_TheAddressBreakpointStillFires;
    [Test] procedure SharedAddress_AddressSetReposted_DoesNotSilenceTheSourceBreakpoint;
    [Test] procedure SharedAddress_TwoSourceLines_StopOncePerPassOnEveryPass;
    [Test] procedure SharedAddress_TwoLogpoints_BothLogEveryPass;
    [Test] procedure SharedAddress_AddedWhileStoppedOnTheAddress_BothKeepFiring;
    [Test] procedure SharedAddress_InAPackageAndInTheExecutable_TheSurvivorFires;

    // --- 3. copies ---
    [Test] procedure Win64_FinallyBlock_StopsOnThePlainPathAndOnTheExceptionPath;
    [Test] procedure Win64_FinallyBlock_SetBeforeTheProcess_StopsOnBothPaths;
    [Test] procedure Win32_FinallyBlock_StopsOnBothPathsAtOneAddress;
    [Test] procedure FinallyBlocks_NestedAndLeftByExit_StopOncePerPass;
    [Test] procedure ForLine_StopsOncePerEntryIntoTheLoop;
    [Test] procedure FinallyBlockRunOnlyByAnException_Stops_InTheExecutableAndInAPackage;
    [Test] procedure HitCondition_OnALineWithACopy_CountsPassesThroughTheLine;
    [Test] procedure SecondProviderNamingTheCopy_DoesNotGiveTheLineASecondRecord;

    // --- 4. the byte under a running thread ---
    [Test] procedure Rearm_TwoLogpointsOnTwoThreads_BothLogEveryPass;
    [Test] procedure Rearm_BreakpointOnTheLineAThreadResumesFrom_StopsTheNextPass;
    [Test] procedure Rearm_StepOutToTheAddressTheThreadIsAt_LandsInTheCaller;
    [Test] procedure Rearm_BreakpointRecreatedUnderAParkedThread_ThenAnotherThreadStepped;
    [Test] procedure Rearm_HitQueuedBehindAStop_SurvivesAFunctionCallAtThatStop;
    [Test] procedure Rearm_CleanDetach_ClearsTheTrapFlagOfEveryThreadThatOwesOne;
    [Test] procedure Rearm_InstructionUnderTheBreakpointFaults_TheBreakpointStopsTheNextPass;
    [Test] procedure Rearm_ExceptionStopOnAPlantedAddress_DoesNotLoseTheBreakpoint;

    // --- 5. when the analysis has to wait ---
    [Test] procedure Analysis_ProviderStillIndexing_IsNotWaitedForAndNotKept;
    [Test] procedure Analysis_ProvidersPublishedByThePrefetcher_AreUsedAtTheNextQuestion;
    [Test] procedure ModuleRelocatedAfterItsLoadEvent_IsJudgedAgainAtItsEntryPoint;

    // --- 6. a unit's final end. ---
    [Test] procedure FinalEndOfAUnit_OnBytesThatDecode_IsRefused;
    [Test] procedure FinalEndOfAUnit_Synthetic_OnlyTheLastLineOfTheUnitsOwnFileOutsideEveryRoutine;
  end;

implementation

uses
  Winapi.Windows, System.IOUtils,
  DebugTarget, DebugInfoTypes, DebugSessionTypes, DebugSession, ModuleSymbolLoader,
  TD32FileReader, CodeMap, Disassembler, ZydisDisassembler, PeImageFile,
  RoutineAnalysis, LiveCodeAnalysis;

const
  // The numbers BreakpointSample.dpr runs its switched scenarios with.
  TWO_PASSES    = 150;
  SPIN_PASSES   = 5;
  LOOP_PASSES   = 5;
  FAULT_PASSES  = 4;
  FAULT_MARKER: array[Boolean] of string = ('BS_FAULT_LINE_32', 'BS_FAULT_LINE_64');
  LIB_PREFERRED_BASE = UInt64($3A000000);
  LIB_SOURCE    = 'BreakpointSampleLib.dpr';

type
  // A provider whose index is "still being built" for as long as the test says
  // so, in front of a real one: it counts how often its tables are asked for.
  TIndexingProvider = class(TInterfacedObject, ILineRecordProvider, IRoutineRangeProvider,
    IBackgroundIndexProvider)
  public
    Inner:      TTD32FileReader;
    Pending:    Boolean;
    Complete:   Boolean;
    TableCalls: Integer;
    function LineRecordTable(out AComplete: Boolean): TLineRecordTable;
    function RoutineRanges(out AComplete: Boolean): TArray<TRoutineRange>;
    function BackgroundIndexingPending: Boolean;
  end;

  // Hand-built line records and routine ranges, for the cases no fixture has.
  TTablesProvider = class(TInterfacedObject, ILineRecordProvider, IRoutineRangeProvider)
  public
    Table:  TLineRecordTable;
    Ranges: TArray<TRoutineRange>;
    function LineRecordTable(out AComplete: Boolean): TLineRecordTable;
    function RoutineRanges(out AComplete: Boolean): TArray<TRoutineRange>;
  end;

  // A line-table provider that knows ONE line and answers with an address the
  // test chose: the shape of a MAP that names the funclet copy of a line where
  // TD32 names the inline one.
  TOneLineProvider = class(TInterfacedObject, ISourceLineProvider)
  public
    FileName: string;
    Line:     Integer;
    Rva:      UInt64;
    function RvaToSourceLine(ARva: UInt64; out Loc: TSourceLocation): Boolean;
    function SourceLineToRva(const AFileName: string; ALine: Integer; out ARva: UInt64): Boolean;
    function SortedRvas: TArray<UInt64>;
  end;

function TTablesProvider.LineRecordTable(out AComplete: Boolean): TLineRecordTable;
begin
  AComplete := True;
  Result := Table;
  Result.Records := Copy(Table.Records);
end;

function TTablesProvider.RoutineRanges(out AComplete: Boolean): TArray<TRoutineRange>;
begin
  AComplete := True;
  Result := Copy(Ranges);
end;

function TIndexingProvider.LineRecordTable(out AComplete: Boolean): TLineRecordTable;
begin
  Inc(TableCalls);
  Result := Inner.LineRecordTable(AComplete);
  AComplete := Complete and not Pending;
end;

function TIndexingProvider.RoutineRanges(out AComplete: Boolean): TArray<TRoutineRange>;
begin
  Inc(TableCalls);
  Result := Inner.RoutineRanges(AComplete);
  AComplete := Complete and not Pending;
end;

function TIndexingProvider.BackgroundIndexingPending: Boolean;
begin
  Result := Pending;
end;

function TOneLineProvider.RvaToSourceLine(ARva: UInt64; out Loc: TSourceLocation): Boolean;
begin
  Loc := Default(TSourceLocation);
  Result := False;
end;

function TOneLineProvider.SourceLineToRva(const AFileName: string; ALine: Integer;
  out ARva: UInt64): Boolean;
begin
  ARva := Rva;
  Result := (ALine = Line) and SameText(ExtractFileName(AFileName), FileName);
end;

function TOneLineProvider.SortedRvas: TArray<UInt64>;
begin
  Result := nil;
end;

const
  SAMPLE_SOURCE   = 'BreakpointSample.dpr';
  ANALYSIS_SOURCE = 'AnalysisSample.dpr';
  STOP_TIMEOUT_MS = 30000;
  // More stops than any scenario here produces: a breakpoint that fires for
  // ever ends the run with a message instead of a hung worker.
  MAX_STOPS       = 64;

type
  // One fixture binary and what a session needs to open it.
  TTargetBinary = record
    Caption:    string;
    Exe:        string;
    Map:        string;
    Rsm:        string;
    SourceRoot: string;
    Is64:       Boolean;
  end;

  // One stop of a run.
  TStop = record
    Line:   Integer;
    IP:     UInt64;
    Module: string;
  end;

  // Receives the exit code of the program under test. "The process is gone"
  // does not tell a program that ran to its end from one that crashed on a
  // breakpoint byte written into its data, and with every exception filter off
  // a crash is silent; the exit code tells them apart.
  TExitWatcher = class
  public
    Exited: Boolean;
    Code:   Integer;
    // Stops of the session by reason, for the tests in which a breakpoint stop
    // and an exception stop share a line.
    BreakpointStops: Integer;
    ExceptionStops:  Integer;
    procedure Reset;
    procedure Handle(ExitCode: Integer);
    procedure HandleStop(const Info: TStopInfo);
  end;

var
  // The tests of this unit run one session at a time, on one thread.
  GExit: TExitWatcher;
  // BreakpointSample folds everything it does into the global GSink. When a
  // run carries a breakpoint on the program's last statement (GSinkLine), the
  // stop there is not counted: GSink is read instead. A breakpoint that makes
  // the engine run an instruction twice, skip it, or resume one byte into it
  // changes that value even when the program then ends normally -- measured:
  // resuming one byte into `mov eax, [GSink]` decodes as a harmless
  // `add eax, imm32` of the same length, and nothing else notices.
  GSinkLine:  Integer;
  GSinkSeen:  Boolean;
  GSinkValue: string;
  // What an undisturbed run computes, per bitness; '' until measured.
  GReferenceSink: array[Boolean] of string;

procedure TExitWatcher.Reset;
begin
  Exited := False;
  Code   := 0;
  BreakpointStops := 0;
  ExceptionStops  := 0;
end;

procedure TExitWatcher.HandleStop(const Info: TStopInfo);
begin
  case Info.Reason of
    srBreakpoint: Inc(BreakpointStops);
    srException:  Inc(ExceptionStops);
  end;
end;

procedure TExitWatcher.Handle(ExitCode: Integer);
begin
  Exited := True;
  Code   := ExitCode;
end;

function RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function SampleBinary(const Name: string; Is64: Boolean): TTargetBinary;
begin
  var Bitness := 'Win32';
  if Is64 then
    Bitness := 'Win64';
  Result := Default(TTargetBinary);
  Result.Caption    := Name + ' ' + Bitness;
  Result.Exe        := TargetDir + Bitness + '\Debug\' + Name + '.exe';
  Result.Map        := ChangeFileExt(Result.Exe, '.map');
  Result.Rsm        := ChangeFileExt(Result.Exe, '.rsm');
  Result.SourceRoot := TargetDir;
  Result.Is64       := Is64;
end;

// The package fixture: TestHost.exe loads TestSubject.bpl, which contains the
// same units as TestTarget.exe.
function HostBinary(Is64: Boolean): TTargetBinary;
begin
  var Bitness := 'Win32';
  if Is64 then
    Bitness := 'Win64';
  Result := Default(TTargetBinary);
  Result.Caption    := 'package ' + Bitness;
  Result.Exe        := RepoRoot + 'DebuggerTests\TestHost\' + Bitness + '\Debug\TestHost.exe';
  Result.Map        := ChangeFileExt(Result.Exe, '.map');
  Result.Rsm        := ChangeFileExt(Result.Exe, '.rsm');
  Result.SourceRoot := TargetDir;
  Result.Is64       := Is64;
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

function MarkerLine(const SourceBaseName, Marker: string): Integer;
begin
  Result := LineContaining(TargetDir + SourceBaseName, '{BP:' + Marker + '}');
  Assert.IsTrue(Result > 0, Format('marker %s not found in %s', [Marker, SourceBaseName]));
end;

function LineSpecs(const Lines: array of Integer): TArray<TBpLineSpec>;
begin
  SetLength(Result, Length(Lines));
  for var I := 0 to High(Lines) do begin
    Result[I] := Default(TBpLineSpec);
    Result[I].Line := Lines[I];
  end;
end;

// Launches a fixture with every exception filter off: the scenarios raise on
// purpose, and with the default filters the session would stop on the raise
// before any breakpoint got its turn. WithMap False names a MAP that does not
// exist, which is how a session runs without one.
function LaunchTarget(const Binary: TTargetBinary; StopAtEntry: Boolean;
  const Args: string = ''; WithMap: Boolean = True): TDebugSession;
begin
  Assert.IsTrue(FileExists(Binary.Exe),
    Binary.Caption + ': fixture missing at ' + Binary.Exe + ' -- run build_and_run.bat');
  Result := TDebugSession.Create;
  try
    GExit.Reset;
    GSinkLine  := 0;
    GSinkSeen  := False;
    GSinkValue := '';
    Result.OnSessionExited := GExit.Handle;
    Result.OnSessionStopped := GExit.HandleStop;
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
    Assert.IsTrue(Result.Launch(Opts), Binary.Caption + ': Launch returned False');
  except
    Result.Free;
    raise;
  end;
end;

procedure PumpUntilStoppedOrExited(Session: TDebugSession; TimeoutMs: Cardinal);
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while (Session.State <> dsStopped) and (not Session.HasExited) and
        (GetTickCount64 < Deadline) do
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

function CurrentStop(Session: TDebugSession): TStop;
begin
  Result := Default(TStop);
  var FnName, SrcFile: string;
  Session.GetCurrentLocation(FnName, SrcFile, Result.Line);
  var Frames := Session.GetCallStack;
  if Length(Frames) > 0 then begin
    Result.IP     := Frames[0].IP;
    Result.Module := LowerCase(Frames[0].ModuleName);
  end;
end;

// Runs a session that is stopped (or was just launched) to the end of the
// program and returns every stop on the way. Ended is True only when the
// program ran to its END: it is False when the program was still alive after
// MAX_STOPS stops or the timeout, and when it died with a non-zero exit code.
function RunToTheEnd(Session: TDebugSession; out Ended: Boolean): TArray<TStop>;
begin
  Result := nil;
  Ended := False;
  for var Round := 0 to MAX_STOPS do begin
    if Session.State = dsStopped then
      Session.ContinueExecution;
    PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
    if Session.HasExited then begin
      Ended := GExit.Exited and (GExit.Code = 0);
      Exit;
    end;
    if Session.State <> dsStopped then
      Exit;   // timed out while running
    var Stop := CurrentStop(Session);
    if (GSinkLine > 0) and (Stop.Line = GSinkLine) then begin
      var Sink := Session.Evaluate('GSink');
      GSinkSeen  := True;
      GSinkValue := Sink.Value;
      if not Sink.Success then
        GSinkValue := '<' + Sink.ErrorText + '>';
      Continue;
    end;
    Result := Result + [Stop];
  end;
end;

// What became of the program, for a failure message.
function HowItEnded: string;
begin
  if not GExit.Exited then
    Exit('it was still running');
  Result := Format('it exited with code %d ($%x)', [GExit.Code, Cardinal(GExit.Code)]);
end;

function CountOnLine(const Stops: TArray<TStop>; Line: Integer): Integer;
begin
  Result := 0;
  for var Stop in Stops do
    if Stop.Line = Line then
      Inc(Result);
end;

function DescribeStops(const Stops: TArray<TStop>): string;
begin
  Result := '';
  for var Stop in Stops do
    Result := Result + Format('%d@$%x ', [Stop.Line, Stop.IP]);
  if Result = '' then
    Result := '(none)';
  Result := Result.Trim;
end;

// The lines a session is given breakpoints on: the caller's, plus -- in
// BreakpointSample -- the program's last statement, where GSink is read.
function WithTheSinkLine(const SourceFile: string; const Lines: array of Integer): TArray<TBpLineSpec>;
begin
  var All: TArray<Integer> := nil;
  for var Line in Lines do
    All := All + [Line];
  if SameText(SourceFile, SAMPLE_SOURCE) then begin
    GSinkLine := MarkerLine(SAMPLE_SOURCE, 'BS_MAIN_LAST');
    All := All + [GSinkLine];
  end;
  Result := LineSpecs(All);
end;

// A session stopped at entry with source breakpoints on the given lines.
function StoppedAtEntryWith(const Binary: TTargetBinary; const SourceFile: string;
  const Lines: array of Integer; const Args: string = ''; WithMap: Boolean = True): TDebugSession;
begin
  Result := LaunchTarget(Binary, True, Args, WithMap);
  try
    PumpUntilStoppedOrExited(Result, STOP_TIMEOUT_MS);
    Assert.AreEqual(Ord(dsStopped), Ord(Result.State), Binary.Caption + ': did not stop at entry');
    Result.SetBreakpoints(SourceFile, WithTheSinkLine(SourceFile, Lines));
  except
    EndSession(Result);
    raise;
  end;
end;

// Every stop of a whole run with source breakpoints on the given lines.
function StopsOfARun(const Binary: TTargetBinary; const SourceFile: string;
  const Lines: array of Integer; out Ended: Boolean; SetBeforeTheProcess: Boolean = False;
  const Args: string = ''; WithMap: Boolean = True): TArray<TStop>;
begin
  var Session: TDebugSession;
  if SetBeforeTheProcess then begin
    // Launched and not yet pumped: the engine has no image base, so the
    // breakpoints are only registered and are planted at the startup break.
    Session := LaunchTarget(Binary, False, Args, WithMap);
    Session.SetBreakpoints(SourceFile, WithTheSinkLine(SourceFile, Lines));
  end else
    Session := StoppedAtEntryWith(Binary, SourceFile, Lines, Args, WithMap);
  try
    Result := RunToTheEnd(Session, Ended);
  finally
    EndSession(Session);
  end;
end;

// GSink at the end of a run of BreakpointSample that no breakpoint disturbed
// but the one it is read at. Measured once per bitness.
function ReferenceSink(Is64: Boolean): string;
begin
  if GReferenceSink[Is64] <> '' then
    Exit(GReferenceSink[Is64]);
  var Ended: Boolean;
  var Stops := StopsOfARun(SampleBinary('BreakpointSample', Is64), SAMPLE_SOURCE, [], Ended);
  Assert.IsTrue(Ended and GSinkSeen and (Length(Stops) = 0),
    'the reference run of BreakpointSample did not reach its last statement and end');
  GReferenceSink[Is64] := GSinkValue;
  Result := GSinkValue;
end;

{ TBreakpointPlacementTests }

procedure TBreakpointPlacementTests.Setup;
begin
  FProblems := TList<string>.Create;
end;

procedure TBreakpointPlacementTests.TearDown;
begin
  FreeAndNil(FProblems);
end;

procedure TBreakpointPlacementTests.Check(Condition: Boolean; const Problem: string);
begin
  if not Condition then
    FProblems.Add(Problem);
end;

procedure TBreakpointPlacementTests.AssertNoProblems;
begin
  if FProblems.Count = 0 then
    Exit;
  Assert.Fail(Format('%d problem(s): ', [FProblems.Count]) + string.Join(' | ', FProblems.ToArray));
end;

procedure TBreakpointPlacementTests.CheckTheProgramComputedTheSame(const Caption: string;
  Is64: Boolean);
// To be called right after a run of BreakpointSample, before the next launch.
begin
  var Seen := GSinkSeen;
  var Value := GSinkValue;
  var Expected := ReferenceSink(Is64);
  Check(Seen, Caption + ': the program never reached its last statement');
  if Seen then
    Check(Value = Expected, Format('%s: the program computed GSink = %s, an undisturbed run computes %s: ' +
      'an instruction under a breakpoint was not executed exactly once', [Caption, Value, Expected]));
end;

{ 1. the analysis decides }

procedure TBreakpointPlacementTests.LineInsideAJumpTable_IsRefusedWithThatReason_AndTheProgramRuns;
// AsmTable ends with a hand-written table of code addresses (`DD` / `DQ`), and
// that source line has a line record: the address of the table. The bytes there
// are a non-zero address, so the zero-byte test of 0.9.3 let the breakpoint
// through, and the $CC changed the first entry the routine jumps through.
const
  TABLE_LINE: array[Boolean] of string = ('DD      @@zero', 'DQ      @@zero');
  REASON = 'inside a jump table';
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('AnalysisSample', Is64);
    var Line := LineContaining(TargetDir + ANALYSIS_SOURCE, TABLE_LINE[Is64]);
    Assert.IsTrue(Line > 0, 'the table line of AsmTable was not found in ' + ANALYSIS_SOURCE);
    var Session := LaunchTarget(Binary, True);
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      var Bps := Session.SetBreakpoints(ANALYSIS_SOURCE, LineSpecs([Line]));
      Check((Length(Bps) = 1) and not Bps[0].Verified,
        Format('%s: line %d, which is a table and not code, was reported verified', [Binary.Caption, Line]));

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(Length(Stops) = 0, Format('%s: the session stopped at %s although the only breakpoint is on a table',
        [Binary.Caption, DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded +
        ': the breakpoint was planted into the jump table');

      // Not vacuous: the refusal must have been announced, with the reason the
      // analysis gives. If the fixture stops producing that record the test
      // fails instead of passing on a breakpoint that never resolved.
      var Announced := '';
      for var Text in Session.DrainDebuggerOutput do
        if Text.Contains('was not set') then
          Announced := Text;
      Check(Announced.Contains(REASON), Format('%s: no refusal naming "%s" was announced (got "%s")',
        [Binary.Caption, REASON, Announced]));
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.DecisionFunction_RefusesInsideAnInstruction_AndPlantsOnABoundary;
// No fixture has a line record in the middle of an instruction (a large real
// image has hundreds), so the decision is tested where it is taken: the
// function the engine asks, over a fixture read as a file. Every address
// strictly inside a proven instruction must be refused with that reason, and
// the instruction's own first byte must not be.
const
  WANTED_TEXT = 'inside an instruction';
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    Assert.IsTrue(FileExists(Binary.Exe), Binary.Caption + ': fixture missing');
    var Image := TPeImageFile.Create(Binary.Exe);
    var Reader := TTD32FileReader.Create;
    var Keep: IInterface := Reader;
    Reader.LoadFromFile(Binary.Exe);
    var Providers: TArray<IInterface> := [Keep];
    var Base := Image.ImageBase;
    var Size: UInt64 := Image.SizeOfImage;
    var Analysis := TLiveCodeAnalysis.Create(Image.Read,
      function(VA: UInt64; out Info: TLiveModuleInfo): Boolean
      begin
        Info := Default(TLiveModuleInfo);
        Result := (VA >= Base) and (VA - Base < Size);
        if not Result then
          Exit;
        Info.Name      := 'BreakpointSample.exe';
        Info.Base      := Base;
        Info.Size      := Size;
        Info.Providers := Providers;
      end);
    try
      Analysis.ZydisDllPath := ResolveZydisDllPathForThisExe;
      var Line := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_FIRST');
      var Rva: UInt64;
      Assert.IsTrue(Reader.SourceLineToRva(SAMPLE_SOURCE, Line, Rva),
        Binary.Caption + ': BS_SHARED_FIRST has no address');

      var Verdict: TRoutineLine;
      Assert.IsTrue(Analysis.TryAnalyzeAddress(Base + Rva, Verdict), Binary.Caption + ': no analysis of the fixture');
      Check(Verdict.Verdict = lvConfirmed, Binary.Caption + ': the statement''s own record is not confirmed: ' +
        LineVerdictReasonText(Verdict.Reason));
      var Reason: string;
      Check(Analysis.JudgeAddress(Base + Rva, Reason) = pvPlant,
        Binary.Caption + ': the start of a statement was not judged plantable: ' + Reason);

      // The statement's first block is several instructions; every byte of it
      // that is not the first byte of one must be refused.
      var Inside := 0;
      var Boundaries := 0;
      for var At := Rva + 1 to Verdict.BlockEndRva - 1 do begin
        var Middle: TRoutineLine;
        if not Analysis.TryAnalyzeAddress(Base + At, Middle) then
          Continue;
        var Answer := Analysis.JudgeAddress(Base + At, Reason);
        if Middle.Reason = lvrBoundary then begin
          Inc(Boundaries);
          Check(Answer = pvPlant, Format('%s: boundary $%x was refused: %s', [Binary.Caption, At, Reason]));
          Continue;
        end;
        Inc(Inside);
        Check(Middle.Reason = lvrInsideInstruction, Format('%s: $%x is neither a boundary nor inside an instruction: %s',
          [Binary.Caption, At, LineVerdictReasonText(Middle.Reason)]));
        Check((Answer = pvRefuse) and Reason.Contains(WANTED_TEXT),
          Format('%s: $%x, inside an instruction, was not refused with that reason (verdict %d, "%s")',
            [Binary.Caption, At, Ord(Answer), Reason]));
      end;
      Check(Inside >= 3, Format('%s: only %d addresses inside an instruction were tried', [Binary.Caption, Inside]));
      Check(Boundaries >= 1, Binary.Caption + ': the block has no second instruction: the test tried nothing');

      // An address in no module at all: nothing is known, and that is the answer.
      Check(Analysis.JudgeAddress(Base + Size + $1000, Reason) = pvNoAnalysis,
        Binary.Caption + ': an address outside every module got a verdict');

      // What was built is dropped with the module and built again on the next
      // question: the loader maps, unmaps and maps again at one address.
      var Built := Analysis.Stats;
      Check((Length(Built) = 1) and (Built[0].VerdictCount > 1) and Built[0].DecoderAvailable,
        Binary.Caption + ': one module with its verdicts was expected to be held');
      Analysis.ForgetModule(Base + $1000);
      Check(Length(Analysis.Stats) = 1, Binary.Caption + ': forgetting another address dropped the module');
      Analysis.ForgetModule(Base);
      Check(Length(Analysis.Stats) = 0, Binary.Caption + ': the module was not dropped');
      Check(Analysis.JudgeAddress(Base + Rva, Reason) = pvPlant,
        Binary.Caption + ': the module was not analysed again after it was dropped');
      Built := Analysis.Stats;
      Check((Length(Built) = 1) and (Built[0].VerdictCount = 1),
        Binary.Caption + ': the verdicts of the dropped module survived it');
    finally
      Analysis.Free;
      Keep := nil;
      Image.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Bpl_EndOfThePackageSource_IsRefusedThroughTheAnalysis;
// The 64-bit package has one line record on data: the final `end.` of its own
// .dpk. The module is loaded by the host at run time, so this is the refusal
// with the analysis of a module that is NOT the main executable: its code map
// is built through a shifted provider and its bytes are read at its load base.
const
  PACKAGE_SOURCE = 'TestSubject.dpk';
  REASON         = 'no instruction leads there';
begin
  var Binary := HostBinary(True);
  var Line := LineContaining(RepoRoot + 'DebuggerTests\TestHost\' + PACKAGE_SOURCE, 'end.');
  Assert.IsTrue(Line > 0, 'no "end." line in ' + PACKAGE_SOURCE);
  var Session := LaunchTarget(Binary, False);
  try
    Session.SetBreakpoints(PACKAGE_SOURCE, LineSpecs([Line]));
    var Ended: Boolean;
    var Stops := RunToTheEnd(Session, Ended);
    Assert.AreEqual<NativeInt>(0, Length(Stops),
      'the session stopped although the only breakpoint is on data: ' + DescribeStops(Stops));
    Assert.IsTrue(Ended, 'the host did not run to its end: ' + HowItEnded);

    var Announced := '';
    for var Text in Session.DrainDebuggerOutput do
      if Text.Contains('was not set') then
        Announced := Text;
    Assert.IsTrue(Announced.Contains(REASON),
      Format('the refusal was not announced with the reason of the analysis ("%s"); got "%s". ' +
        'Either the package no longer has that record, or the refusal came from the zero-byte fallback',
        [REASON, Announced]));
    Assert.IsTrue(Announced.Contains('holds data, not code'), 'the notice lost its wording: ' + Announced);
    for var Bp in Session.ListBreakpoints do
      if Bp.Line = Line then
        Assert.IsFalse(Bp.Verified, 'the refused breakpoint is listed as verified');
  finally
    EndSession(Session);
  end;
end;

procedure TBreakpointPlacementTests.AnonymousMethodBody_BindsAndFires_WithAndWithoutAMap;
// The body of an anonymous method has no TD32 procedure record. On x64 .pdata
// gives its entry and the record is confirmed. On x86 only a MAP names the
// body: with one the record is confirmed, without one it is UNCONFIRMED -- and
// planted all the same, because unconfirmed is not "shown to be something
// else". The breakpoint must fire for both calls in all three cases.
type
  TCase = record
    Is64, WithMap: Boolean;
    Expected: TLineVerdict;
    Caption: string;
  end;
const
  CASES: array[0..2] of TCase = (
    (Is64: False; WithMap: False; Expected: lvUnconfirmed; Caption: 'x86 without a MAP'),
    (Is64: False; WithMap: True;  Expected: lvConfirmed;   Caption: 'x86 with a MAP'),
    (Is64: True;  WithMap: False; Expected: lvConfirmed;   Caption: 'x64'));
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_ANON_BODY');
  for var Item in CASES do begin
    var Binary := SampleBinary('BreakpointSample', Item.Is64);
    var Session := LaunchTarget(Binary, True, '', Item.WithMap);
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Item.Caption + ': did not stop at entry');
      // The MAP's publics are indexed on a background thread, and the code map
      // is built without them while that runs. Wait, so that this test sees the
      // case it names.
      var Deadline := GetTickCount64 + 10000;
      while (Session.Loader.MainSymbolAvailability = saIndexing) and (GetTickCount64 < Deadline) do
        Sleep(5);
      var Bps := Session.SetBreakpoints(SAMPLE_SOURCE, WithTheSinkLine(SAMPLE_SOURCE, [Line]));
      Check((Length(Bps) = 2) and Bps[0].Verified, Item.Caption + ': the breakpoint did not bind');

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Line) = 2, Format('%s: %d stops in the anonymous method''s body, expected 2 (%s)',
        [Item.Caption, CountOnLine(Stops, Line), DescribeStops(Stops)]));
      Check(Length(Stops) = 2, Format('%s: stops elsewhere: %s', [Item.Caption, DescribeStops(Stops)]));
      Check(Ended, Item.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
    CheckTheProgramComputedTheSame(Item.Caption, Item.Is64);

    // What the analysis says about that record, in a second session: asked at
    // a stop on the line, while the process is alive.
    Session := StoppedAtEntryWith(Binary, SAMPLE_SOURCE, [], '', Item.WithMap);
    try
      var Deadline := GetTickCount64 + 10000;
      while (Session.Loader.MainSymbolAvailability = saIndexing) and (GetTickCount64 < Deadline) do
        Sleep(5);
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
      Session.ContinueExecution;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Item.Caption + ': did not stop in the body');
      var Verdict: TRoutineLine;
      var Known := Session.CodeAnalysis.TryAnalyzeAddress(CurrentStop(Session).IP, Verdict);
      Check(Known and (Verdict.Verdict = Item.Expected),
        Format('%s: the record of the body is %s, expected verdict %d', [Item.Caption,
          LineVerdictReasonText(Verdict.Reason), Ord(Item.Expected)]));
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

{ 2. one byte, several records }

// A session stopped at entry with a source breakpoint on BS_SHARED_FIRST and
// an address breakpoint on the same address. Neither has fired, and the thread
// is nowhere near the address: both records are planted.
function SourceAndAddressOnOneAddress(const Binary: TTargetBinary; out Line: Integer;
  out VA: UInt64; out AddressBp: TSessionBreakpoint): TDebugSession;
begin
  Line := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_FIRST');
  Result := StoppedAtEntryWith(Binary, SAMPLE_SOURCE, [Line]);
  try
    Assert.IsTrue(Result.GetGotoTargetVA(SAMPLE_SOURCE, Line, VA),
      Binary.Caption + ': BS_SHARED_FIRST has no address');
    AddressBp := Result.SetAddressBreakpoint(VA, '', '', '');
    Assert.IsTrue(AddressBp.Verified, Binary.Caption + ': the address breakpoint did not resolve: ' + AddressBp.Message);
  except
    EndSession(Result);
    raise;
  end;
end;

const
  // TwoLinesOneAddress is called six times.
  SHARED_PASSES = 6;

procedure TBreakpointPlacementTests.SharedAddress_AddressBreakpointRemoved_TheSourceBreakpointStillFires;
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Line: Integer;
    var VA: UInt64;
    var AddressBp: TSessionBreakpoint;
    var Session := SourceAndAddressOnOneAddress(Binary, Line, VA, AddressBp);
    try
      Assert.IsTrue(Session.RemoveAddressBreakpoint(AddressBp.Id), 'RemoveAddressBreakpoint returned False');
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Line) = SHARED_PASSES,
        Format('%s: after the address breakpoint sharing its address was removed, the source breakpoint ' +
          'stopped %d times, expected %d (%s)', [Binary.Caption, CountOnLine(Stops, Line), SHARED_PASSES,
          DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SharedAddress_SourceBreakpointRemoved_TheAddressBreakpointStillFires;
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Line: Integer;
    var VA: UInt64;
    var AddressBp: TSessionBreakpoint;
    var Session := SourceAndAddressOnOneAddress(Binary, Line, VA, AddressBp);
    try
      // The file's set without the line: only the last statement's stays.
      Session.SetBreakpoints(SAMPLE_SOURCE, WithTheSinkLine(SAMPLE_SOURCE, []));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      var AtAddress := 0;
      for var Stop in Stops do
        if Stop.IP = VA then
          Inc(AtAddress);
      Check(AtAddress = SHARED_PASSES,
        Format('%s: after the source breakpoint sharing its address was removed, the address breakpoint ' +
          'stopped %d times, expected %d (%s)', [Binary.Caption, AtAddress, SHARED_PASSES, DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SharedAddress_AddressSetReposted_DoesNotSilenceTheSourceBreakpoint;
// Every SetAddressBreakpoint re-posts the module's whole address set: the
// engine removes the address breakpoints it has and plants the new list. The
// removal used to put the program's byte back although the source breakpoint
// on the same address still needed the $CC, and the re-plant then "adopted" a
// byte that was no longer there.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Line: Integer;
    var VA: UInt64;
    var AddressBp: TSessionBreakpoint;
    var Session := SourceAndAddressOnOneAddress(Binary, Line, VA, AddressBp);
    try
      // ForLoop is called twice, after everything TwoLinesOneAddress does.
      var LastLine := MarkerLine(SAMPLE_SOURCE, 'BS_FOR_AFTER');
      var LastVA: UInt64;
      Assert.IsTrue(Session.GetGotoTargetVA(SAMPLE_SOURCE, LastLine, LastVA), 'BS_FOR_AFTER has no address');
      var Second := Session.SetAddressBreakpoint(LastVA, '', '', '');
      Assert.IsTrue(Second.Verified, 'the second address breakpoint did not resolve: ' + Second.Message);

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      // One stop per pass, although two records sit on the address.
      Check(CountOnLine(Stops, Line) = SHARED_PASSES,
        Format('%s: with an address breakpoint on its address and the address set posted again, the source ' +
          'breakpoint stopped %d times, expected %d (%s)', [Binary.Caption, CountOnLine(Stops, Line),
          SHARED_PASSES, DescribeStops(Stops)]));
      Check(CountOnLine(Stops, LastLine) = 2, Format('%s: the second address breakpoint stopped %d times, expected 2',
        [Binary.Caption, CountOnLine(Stops, LastLine)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SharedAddress_TwoSourceLines_StopOncePerPassOnEveryPass;
// A breakpoint on `begin` is moved to the routine's first statement, so with a
// breakpoint on that statement as well two records sit on one address. After
// the first hit the re-arm used to find the second record still flagged
// "planted", adopt its byte and skip the write: the pair fired exactly once.
begin
  var BeginLine := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_BEGIN');
  var FirstLine := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_FIRST');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Ended: Boolean;
    var Stops := StopsOfARun(Binary, SAMPLE_SOURCE, [BeginLine, FirstLine], Ended);
    Check(Length(Stops) = SHARED_PASSES,
      Format('%s: breakpoints on "begin" and on the first statement stopped %d times in %d passes (%s)',
        [Binary.Caption, Length(Stops), SHARED_PASSES, DescribeStops(Stops)]));
    for var Stop in Stops do
      Check(Stop.IP = Stops[0].IP, Format('%s: the two lines do not share one address: %s',
        [Binary.Caption, DescribeStops(Stops)]));
    Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SharedAddress_TwoLogpoints_BothLogEveryPass;
// The same pair as LOGPOINTS: no hit stops, so nothing but the hit path and
// the single step that follows it touches the byte. A stop hides a hit path
// that suspends one record of the two, because resuming from the stop suspends
// the address again and sets the flags right; a run that never stops does not.
const
  TEXT_BEGIN = 'BS-SHARED-BEGIN';
  TEXT_FIRST = 'BS-SHARED-FIRST';
begin
  var BeginLine := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_BEGIN');
  var FirstLine := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_FIRST');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True);
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      var OnBegin := Default(TBpLineSpec);
      OnBegin.Line       := BeginLine;
      OnBegin.LogMessage := TEXT_BEGIN;
      var OnFirst := Default(TBpLineSpec);
      OnFirst.Line       := FirstLine;
      OnFirst.LogMessage := TEXT_FIRST;
      // And a plain breakpoint on the program's last statement, where GSink is read.
      Session.SetBreakpoints(SAMPLE_SOURCE, [OnBegin, OnFirst] + WithTheSinkLine(SAMPLE_SOURCE, []));
      Session.DrainDebuggerOutput;
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      var LoggedBegin := 0;
      var LoggedFirst := 0;
      for var Text in Session.DrainDebuggerOutput do begin
        if Text.Contains(TEXT_BEGIN) then
          Inc(LoggedBegin);
        if Text.Contains(TEXT_FIRST) then
          Inc(LoggedFirst);
      end;
      Check((LoggedBegin = SHARED_PASSES) and (LoggedFirst = SHARED_PASSES),
        Format('%s: two logpoints on one address logged %d and %d times in %d passes',
          [Binary.Caption, LoggedBegin, LoggedFirst, SHARED_PASSES]));
      Check(Length(Stops) = 0, Binary.Caption + ': a logpoint stopped: ' + DescribeStops(Stops));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
      CheckTheProgramComputedTheSame(Binary.Caption, Is64);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SharedAddress_AddedWhileStoppedOnTheAddress_BothKeepFiring;
// The thread is parked ON the address: the hit took the $CC away so that the
// instruction can run. A breakpoint added there now is planted at once, while
// the one that stopped the thread is still suspended. Resuming used to look at
// that suspended record only, leave the new $CC in place and run the thread
// onto it -- and the re-arm branch then continued one byte into the instruction.
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_FIRST');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := StoppedAtEntryWith(Binary, SAMPLE_SOURCE, [Line]);
    try
      Session.ContinueExecution;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the source breakpoint did not fire');
      var First := CurrentStop(Session);
      var AddressBp := Session.SetAddressBreakpoint(First.IP, '', '', '');
      Assert.IsTrue(AddressBp.Verified, 'the address breakpoint did not resolve: ' + AddressBp.Message);

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Line) = SHARED_PASSES - 1,
        Format('%s: after an address breakpoint was added on the address the thread was stopped at, the ' +
          'line stopped %d more times, expected %d (%s)', [Binary.Caption, CountOnLine(Stops, Line),
          SHARED_PASSES - 1, DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end (it ran onto the new breakpoint), ' + HowItEnded);
    finally
      EndSession(Session);
    end;
    // The instruction under the breakpoint adds to GSink. Run from its second
    // byte it still "works" on both bitnesses, with another result.
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SharedAddress_InAPackageAndInTheExecutable_TheSurvivorFires;
// The same two removals on the ordinary fixtures, where the address is in the
// executable and where it is in a package loaded at run time (its address is
// known only after the package is mapped, so the pair is formed at a stop).
// CTOR_BODY is reached more than once: stop on the first pass, step off the
// address so that the breakpoint is planted again, form the pair, remove one
// of the two, and the other must stop the second pass.
const
  CORE_SOURCE = 'TestTargetCore.pas';

  procedure Run(const Binary: TTargetBinary; RemoveTheSourceBreakpoint: Boolean);
  begin
    var Line := MarkerLine(CORE_SOURCE, 'CTOR_BODY');
    var Removed := 'address';
    if RemoveTheSourceBreakpoint then
      Removed := 'source';
    var Caption := Format('%s, %s breakpoint removed', [Binary.Caption, Removed]);
    var Session := LaunchTarget(Binary, False);
    try
      Session.SetBreakpoints(CORE_SOURCE, LineSpecs([Line]));
      PumpUntilStoppedOrExited(Session, 60000);
      if Session.State <> dsStopped then begin
        Check(False, Caption + ': CTOR_BODY was never reached');
        Exit;
      end;
      var First := CurrentStop(Session);
      // Off the address: the breakpoint is planted again by the time the step lands.
      Session.StepOver;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      if Session.State <> dsStopped then begin
        Check(False, Caption + ': the step off the breakpoint did not land');
        Exit;
      end;
      var AddressBp := Session.SetAddressBreakpoint(First.IP, '', '', '');
      Check(AddressBp.Verified, Caption + ': the address breakpoint did not resolve: ' + AddressBp.Message);
      if RemoveTheSourceBreakpoint then
        Session.SetBreakpoints(CORE_SOURCE, [])
      else
        Session.RemoveAddressBreakpoint(AddressBp.Id);

      Session.ContinueExecution;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      if Session.State <> dsStopped then begin
        Check(False, Caption + ': the surviving breakpoint did not fire on the next pass');
        Exit;
      end;
      var Second := CurrentStop(Session);
      Check(Second.IP = First.IP, Format('%s: stopped at $%x, expected the shared address $%x',
        [Caption, Second.IP, First.IP]));
      Check(Second.Module = First.Module, Caption + ': stopped in another module');
    finally
      EndSession(Session);
    end;
  end;

begin
  for var Is64 in [False, True] do
    for var RemoveSource in [False, True] do begin
      Run(SampleBinary('TestTarget', Is64), RemoveSource);
      Run(HostBinary(Is64), RemoveSource);
    end;
  AssertNoProblems;
end;

{ 3. copies }

procedure TBreakpointPlacementTests.Win64_FinallyBlock_StopsOnThePlainPathAndOnTheExceptionPath;
// FinallyBothWays runs its finally block twice: by falling into it, and
// because an exception passes through. dcc64 emits the block twice, and the
// two stops are at two different addresses of the same line.
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_FINALLY_BLOCK');
  var Ended: Boolean;
  var Stops := StopsOfARun(SampleBinary('BreakpointSample', True), SAMPLE_SOURCE, [Line], Ended);
  Assert.AreEqual(2, CountOnLine(Stops, Line),
    'a breakpoint in a finally block must stop once on the plain path and once when an exception ' +
    'runs the block; stops: ' + DescribeStops(Stops));
  Assert.AreEqual<NativeInt>(2, Length(Stops), 'stops elsewhere: ' + DescribeStops(Stops));
  Assert.AreNotEqual(Stops[0].IP, Stops[1].IP,
    'both stops are at one address: the exception path did not go through the funclet copy, ' +
    'so this test no longer shows what it is named after');
  Assert.IsTrue(Ended, 'the program did not run to its end: ' + HowItEnded);
  CheckTheProgramComputedTheSame('BreakpointSample Win64', True);
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Win64_FinallyBlock_SetBeforeTheProcess_StopsOnBothPaths;
// The same breakpoint registered before the engine knows the image base: the
// copy cannot be found then (the analysis reads the live image) and is added
// when the breakpoints are planted at the startup break.
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_FINALLY_BLOCK');
  var Ended: Boolean;
  var Stops := StopsOfARun(SampleBinary('BreakpointSample', True), SAMPLE_SOURCE, [Line], Ended, True);
  Assert.AreEqual(2, CountOnLine(Stops, Line),
    'a breakpoint in a finally block, set before the process existed, must stop on both paths; stops: ' +
    DescribeStops(Stops));
  Assert.IsTrue(Ended, 'the program did not run to its end: ' + HowItEnded);
  CheckTheProgramComputedTheSame('BreakpointSample Win64', True);
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Win32_FinallyBlock_StopsOnBothPathsAtOneAddress;
// dcc32 emits a finally block ONCE: the plain path falls into it and the RTL's
// handler calls the same code. One address, two stops -- which is why the
// 32-bit engine never had the defect, and why no copy may be invented there.
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_FINALLY_BLOCK');
  var Ended: Boolean;
  var Stops := StopsOfARun(SampleBinary('BreakpointSample', False), SAMPLE_SOURCE, [Line], Ended);
  Assert.AreEqual(2, CountOnLine(Stops, Line), 'stops: ' + DescribeStops(Stops));
  Assert.AreEqual<NativeInt>(2, Length(Stops), 'stops elsewhere: ' + DescribeStops(Stops));
  Assert.AreEqual(Stops[0].IP, Stops[1].IP,
    'on x86 the finally block is not duplicated: both stops must be at the same address');
  Assert.IsTrue(Ended, 'the program did not run to its end: ' + HowItEnded);
  CheckTheProgramComputedTheSame('BreakpointSample Win32', False);
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.FinallyBlocks_NestedAndLeftByExit_StopOncePerPass;
// Each of these blocks is run twice by the fixture, once plainly and once by
// an exception (or, for the last, once by falling into it and once by Exit).
// However many copies the compiler made, a breakpoint stops once per pass.
const
  MARKERS: array[0..3] of string = ('BS_NESTED_INNER', 'BS_NESTED_OUTER',
    'BS_FINALLY_IN_FINALLY', 'BS_EXIT_FINALLY');
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Lines: TArray<Integer> := nil;
    for var Marker in MARKERS do
      Lines := Lines + [MarkerLine(SAMPLE_SOURCE, Marker)];
    var Ended: Boolean;
    var Stops := StopsOfARun(Binary, SAMPLE_SOURCE, Lines, Ended);
    for var I := 0 to High(MARKERS) do
      Check(CountOnLine(Stops, Lines[I]) = 2, Format('%s: %s stopped %d times, expected 2 (%s)',
        [Binary.Caption, MARKERS[I], CountOnLine(Stops, Lines[I]), DescribeStops(Stops)]));
    Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.ForLine_StopsOncePerEntryIntoTheLoop;
// A `for` line has two line records too: the initialisation and the loop-back
// test. They are in the SAME piece of the routine, so neither is a copy of the
// other, and the breakpoint stops once per entry into the loop -- not once per
// iteration. ForLoop is entered twice (3 and 2 iterations); the loop inside a
// finally block is entered twice as well, once in each copy of the block.
begin
  var ForLine := MarkerLine(SAMPLE_SOURCE, 'BS_FOR_LINE');
  var InFinally := MarkerLine(SAMPLE_SOURCE, 'BS_FOR_IN_FINALLY');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Ended: Boolean;
    var Stops := StopsOfARun(Binary, SAMPLE_SOURCE, [ForLine, InFinally], Ended);
    Check(CountOnLine(Stops, ForLine) = 2, Format('%s: the for line stopped %d times for 2 entries (%s)',
      [Binary.Caption, CountOnLine(Stops, ForLine), DescribeStops(Stops)]));
    Check(CountOnLine(Stops, InFinally) = 2,
      Format('%s: the for line inside a finally block stopped %d times for 2 entries (%s)',
        [Binary.Caption, CountOnLine(Stops, InFinally), DescribeStops(Stops)]));
    Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    CheckTheProgramComputedTheSame(Binary.Caption, Is64);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.FinallyBlockRunOnlyByAnException_Stops_InTheExecutableAndInAPackage;
// RunExcHandlerFlow (TestTargetFlow.pas) has a finally block that only ever
// runs because RaiseInner raised. On x64 the line-table provider answers with
// the inline copy, which never executes there: before the funclet copy was
// planted this breakpoint was reported verified and never fired.
const
  FLOW_SOURCE = 'TestTargetFlow.pas';
  FRAGMENT    = 'nested try/finally inner cleanup';
  ARGS        = '--run-exc-flow';
begin
  var Line := LineContaining(TargetDir + FLOW_SOURCE, FRAGMENT);
  Assert.IsTrue(Line > 0, 'the finally line of RunExcHandlerFlow was not found');
  for var Is64 in [False, True] do
    for var InPackage in [False, True] do begin
      var Binary := SampleBinary('TestTarget', Is64);
      if InPackage then
        Binary := HostBinary(Is64);
      var Ended: Boolean;
      // Set before the process: in the package case the module is not loaded
      // yet, and the copy is added when its symbols bind the breakpoint.
      var Stops := StopsOfARun(Binary, FLOW_SOURCE, [Line], Ended, True, ARGS);
      Check(CountOnLine(Stops, Line) = 1,
        Format('%s: a breakpoint in a finally block that only an exception runs stopped %d times, ' +
          'expected 1 (%s)', [Binary.Caption, CountOnLine(Stops, Line), DescribeStops(Stops)]));
      if InPackage and (Length(Stops) > 0) then
        Check(Stops[0].Module = 'testsubject.bpl', Binary.Caption + ': stopped in ' + Stops[0].Module);
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.HitCondition_OnALineWithACopy_CountsPassesThroughTheLine;
// The finally block of FinallyBothWays is passed twice. On x64 the two passes
// run two different records, the inline block and its funclet copy. A hit
// condition is about passes through the LINE: `>= 2` must stop the second
// one. Counted per record, each copy saw one hit and the breakpoint never
// stopped.
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_FINALLY_BLOCK');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True);
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      var Spec := Default(TBpLineSpec);
      Spec.Line         := Line;
      Spec.HitCondition := '>=2';
      Session.SetBreakpoints(SAMPLE_SOURCE, [Spec]);
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Line) = 1,
        Format('%s: a breakpoint with the hit condition ">=2" on a line passed twice stopped %d times, ' +
          'expected 1 (%s)', [Binary.Caption, CountOnLine(Stops, Line), DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.SecondProviderNamingTheCopy_DoesNotGiveTheLineASecondRecord;
// A line reaches the engine as one address per line-table provider. When one
// provider names the inline block and another the funclet, the second
// candidate is the very record that was just registered as the first one's
// copy. A second record there counted every hit twice and logged every
// logpoint twice. A provider that names the funclet is put in front of the
// engine here, and a logpoint must still log once per pass.
const
  MESSAGE_TEXT = 'BS-FINALLY-LOGPOINT';
begin
  var Binary := SampleBinary('BreakpointSample', True);
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_FINALLY_BLOCK');

  // Where the funclet copy is: the second stop of a plain run.
  var FuncletRva: UInt64 := 0;
  var Session := StoppedAtEntryWith(Binary, SAMPLE_SOURCE, [Line]);
  try
    var Ended: Boolean;
    var Base := Session.Debugger.ImageBase;
    var Stops := RunToTheEnd(Session, Ended);
    Assert.IsTrue((Length(Stops) = 2) and (Stops[0].IP <> Stops[1].IP),
      'the plain run did not stop in both copies of the block: ' + DescribeStops(Stops));
    FuncletRva := Stops[1].IP - Base;
  finally
    EndSession(Session);
  end;

  Session := LaunchTarget(Binary, True);
  try
    PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at entry');
    var Fake := TOneLineProvider.Create;
    var FakeRef: IInterface := Fake;
    Fake.FileName := SAMPLE_SOURCE;
    Fake.Line     := Line;
    Fake.Rva      := FuncletRva;
    Session.DebugInfo.AddProvider(FakeRef);
    Assert.IsTrue(Length(Session.DebugInfo.SourceLineToRvaCandidates(SAMPLE_SOURCE, Line)) >= 2,
      'the line does not reach the engine as two candidates: the test would show nothing');

    var Spec := Default(TBpLineSpec);
    Spec.Line       := Line;
    Spec.LogMessage := MESSAGE_TEXT;
    Session.SetBreakpoints(SAMPLE_SOURCE, [Spec]);
    Session.DrainDebuggerOutput;
    var Ended: Boolean;
    var Stops := RunToTheEnd(Session, Ended);
    var Logged := 0;
    for var Text in Session.DrainDebuggerOutput do
      if Text.Contains(MESSAGE_TEXT) then
        Inc(Logged);
    Assert.AreEqual(2, Logged,
      'a logpoint on a line passed twice must log twice; a second record on the funclet copy logs the ' +
      'exception pass a second time');
    Assert.AreEqual<NativeInt>(0, Length(Stops), 'a logpoint stopped: ' + DescribeStops(Stops));
    Assert.IsTrue(Ended, 'the program did not run to its end: ' + HowItEnded);
  finally
    EndSession(Session);
  end;
end;

{ 4. the byte under a running thread }

procedure TBreakpointPlacementTests.Rearm_TwoLogpointsOnTwoThreads_BothLogEveryPass;
// Two threads, each through a line of its own, each line a logpoint. A hit
// takes the $CC away and the thread's single step puts it back. There was ONE
// pending re-arm for the whole process: the second thread's hit overwrote the
// first one's, whose single step then re-armed nothing, and that line stopped
// logging for good.
const
  TEXT_A = 'BS-TWO-A';
  TEXT_B = 'BS-TWO-B';
begin
  var LineA := MarkerLine(SAMPLE_SOURCE, 'BS_TWO_A');
  var LineB := MarkerLine(SAMPLE_SOURCE, 'BS_TWO_B');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True, '-two');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      var SpecA := Default(TBpLineSpec);
      SpecA.Line       := LineA;
      SpecA.LogMessage := TEXT_A;
      var SpecB := Default(TBpLineSpec);
      SpecB.Line       := LineB;
      SpecB.LogMessage := TEXT_B;
      Session.SetBreakpoints(SAMPLE_SOURCE, [SpecA, SpecB]);
      Session.DrainDebuggerOutput;
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      var LoggedA := 0;
      var LoggedB := 0;
      for var Text in Session.DrainDebuggerOutput do begin
        if Text.Contains(TEXT_A) then
          Inc(LoggedA);
        if Text.Contains(TEXT_B) then
          Inc(LoggedB);
      end;
      Check((LoggedA = TWO_PASSES) and (LoggedB = TWO_PASSES),
        Format('%s: two logpoints on two threads logged %d and %d times for %d passes each: a line whose ' +
          're-arm was overwritten by the other thread''s hit stops logging', [Binary.Caption, LoggedA,
          LoggedB, TWO_PASSES]));
      Check(Length(Stops) = 0, Binary.Caption + ': a logpoint stopped: ' + DescribeStops(Stops));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Rearm_BreakpointOnTheLineAThreadResumesFrom_StopsTheNextPass;
// The thread is brought onto a line of a loop by a STEP, and a breakpoint is
// then set on that line: it is planted under the thread, which has no re-arm
// pending (it did not hit anything). Resuming takes the byte away so that the
// instruction can run. It used to come back only at the next reported stop --
// and here there is none: the remaining passes ran straight through.
begin
  var First := MarkerLine(SAMPLE_SOURCE, 'BS_LOOP_FIRST');
  var Second := MarkerLine(SAMPLE_SOURCE, 'BS_LOOP_SECOND');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True, '-loop');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([First]));
      Session.ContinueExecution;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the first line did not stop');
      Session.StepOver;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the step did not land');
      Assert.AreEqual(Second, CurrentStop(Session).Line, Binary.Caption + ': the step landed elsewhere');

      // Only this line from now on, and the thread is standing on it.
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Second]));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Second) = LOOP_PASSES - 1,
        Format('%s: a breakpoint set on the line the thread was resumed from stopped %d of the %d ' +
          'remaining passes (%s)', [Binary.Caption, CountOnLine(Stops, Second), LOOP_PASSES - 1,
          DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

// How many frames of the stopped thread are in the routine Recurse. The depth
// of the recursion is read off the call stack and not off the parameter: on
// x64 the routine has no frame pointer, and its parameter is not evaluated
// correctly at its first line.
function RecurseFrames(Session: TDebugSession): Integer;
begin
  Result := 0;
  for var Frame in Session.GetCallStack do
    if SameText(Frame.FunctionName, 'Recurse') or Frame.FunctionName.EndsWith('.Recurse', True) then
      Inc(Result);
end;

procedure TBreakpointPlacementTests.Rearm_StepOutToTheAddressTheThreadIsAt_LandsInTheCaller;
// Recurse calls itself as the last instruction of a line, so every call
// returns to the first instruction of the next line. With the thread standing
// on that instruction in the innermost call, and a breakpoint on it, a
// step-out has the breakpoint's own address for a target. No one-shot is
// planted there -- the breakpoint owns the address -- and the breakpoint had
// just been taken away for the resume, until the next stop. The step never
// landed and the program ran to its end.
const
  INNERMOST_FRAMES = 4;   // RECURSE_DEPTH + 1 in the fixture
begin
  var IfLine := MarkerLine(SAMPLE_SOURCE, 'BS_RECURSE_IF');
  var After := MarkerLine(SAMPLE_SOURCE, 'BS_RECURSE_AFTER');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True, '-recurse');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([IfLine]));
      // Down to the innermost call: Depth 3, 2, 1, 0 -- four frames.
      for var Round := 1 to INNERMOST_FRAMES do begin
        Session.ContinueExecution;
        PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
        Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the recursion did not stop');
      end;
      Assert.AreEqual(INNERMOST_FRAMES, RecurseFrames(Session), Binary.Caption + ': not in the innermost call');
      Session.StepOver;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the step did not land');
      var Here := CurrentStop(Session);
      Assert.AreEqual(After, Here.Line, Binary.Caption + ': the step landed elsewhere');

      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([After]));
      Session.StepOut;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      if Session.State <> dsStopped then begin
        Check(False, Binary.Caption + ': a step-out to the address the thread was already at never landed (' +
          HowItEnded + ')');
        Continue;
      end;
      var Landed := CurrentStop(Session);
      Check(Landed.IP = Here.IP, Format('%s: the caller resumes at $%x, not at the address the thread was at ' +
        '($%x): this fixture no longer builds the case', [Binary.Caption, Landed.IP, Here.IP]));
      Check(RecurseFrames(Session) = INNERMOST_FRAMES - 1,
        Format('%s: the step-out did not land in the caller: %d frames of Recurse, expected %d',
          [Binary.Caption, RecurseFrames(Session), INNERMOST_FRAMES - 1]));
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

// The thread of the session whose innermost frame is in the given routine; 0
// when there is none.
function ThreadIn(Session: TDebugSession; const RoutineName: string): Cardinal;
begin
  for var Thread in Session.GetThreads do begin
    var Frames := Session.GetCallStack(Thread.OsThreadId);
    if (Length(Frames) > 0) and Frames[0].FunctionName.Contains(RoutineName) then
      Exit(Thread.OsThreadId);
  end;
  Result := 0;
end;

procedure TBreakpointPlacementTests.Rearm_BreakpointRecreatedUnderAParkedThread_ThenAnotherThreadStepped;
// The main thread stops on a breakpoint: the byte is away and its re-arm is
// pending. Setting the file's breakpoints again deletes the record and plants
// a new one -- under the thread. Stepping ANOTHER thread and then continuing
// never looks at the main thread's address again, so it runs onto the $CC with
// its re-arm still pending. That used to be continued as "the re-arm step
// came in" -- one byte into the instruction.
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_SPIN_LINE');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True, '-spin');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
      Session.ContinueExecution;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the line did not stop');
      Assert.AreEqual(Line, CurrentStop(Session).Line, Binary.Caption + ': stopped elsewhere');
      var MainTid := Session.GetStoppedThreadId;

      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
      var SpinnerTid := ThreadIn(Session, 'Spinner');
      Assert.IsTrue((SpinnerTid <> 0) and (SpinnerTid <> MainTid), Binary.Caption + ': no spinner thread to step');
      Session.StepOver(SpinnerTid);
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the step of the other thread did not land');
      Assert.AreEqual(SpinnerTid, Session.GetStoppedThreadId, Binary.Caption + ': the step landed on another thread');

      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Line) = SPIN_PASSES - 1,
        Format('%s: the line stopped %d of the %d remaining passes (%s)', [Binary.Caption,
          CountOnLine(Stops, Line), SPIN_PASSES - 1, DescribeStops(Stops)]));
      // The program checks its own sum and exits with 3 when the instruction
      // under the breakpoint did not run exactly once.
      Check(Ended, Binary.Caption + ': the thread ran onto the breakpoint planted under it and did not ' +
        'execute its instruction: ' + HowItEnded);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Rearm_HitQueuedBehindAStop_SurvivesAFunctionCallAtThatStop;
// Four threads run through one line, released together. When one stops there
// the others have executed the same $CC within microseconds: their events are
// queued, with the thread one byte into the instruction. A function called at
// the stop (a watch, a hover, a condition) pumps those events. The address is
// suspended by then, so they were taken for "not ours" and continued where
// they stood. The program checks every thread's sum.
//
// Honest about its nature: this is a race. With four threads in a loop of a
// few instructions it is hit on practically every stop on a multi-core
// machine, and the test makes dozens of stops; on a single core it may show
// nothing.
const
  MIN_STOPS = 10;
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_RACE_LINE');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Session := LaunchTarget(Binary, True, '-race');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
      var StopCount := 0;
      var Called := 0;
      for var Round := 1 to 2000 do begin
        Session.ContinueExecution;
        PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
        if Session.State <> dsStopped then
          Break;
        Inc(StopCount);
        if Session.Evaluate('RaceProbe()').Success then
          Inc(Called);
      end;
      Check(Session.HasExited and GExit.Exited and (GExit.Code = 0),
        Format('%s: after %d stops with a function called at each, a thread whose hit was queued behind ' +
          'a stop did not execute its instruction: %s', [Binary.Caption, StopCount, HowItEnded]));
      Check((StopCount >= MIN_STOPS) and (Called >= MIN_STOPS),
        Format('%s: only %d stops and %d calls: the test exercised nothing', [Binary.Caption, StopCount, Called]));
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Rearm_CleanDetach_ClearsTheTrapFlagOfEveryThreadThatOwesOne;
// The main thread hits a breakpoint: trap flag set, re-arm pending. ANOTHER
// thread is then stepped, so the stop the session ends on belongs to that
// one. A clean detach used to clear the trap flag of the stopped thread only;
// the main thread kept its own and raised a single-step exception one
// instruction after nobody was debugging it any more.
var
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_SPIN_LINE');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    SI := Default(TStartupInfo);
    SI.cb := SizeOf(SI);
    var CmdLine := '"' + Binary.Exe + '" -spin -wait-debugger';
    UniqueString(CmdLine);
    Assert.IsTrue(CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, PI),
      Binary.Caption + ': CreateProcess failed');
    CloseHandle(PI.hThread);
    try
      var Session := TDebugSession.Create;
      try
        var Opts := Default(TAttachOptions);
        Opts.ProgramPath := Binary.Exe;
        Opts.MapPath     := Binary.Map;
        Opts.RsmPath     := Binary.Rsm;
        Opts.SourceRoot  := Binary.SourceRoot;
        Opts.ExceptionFilters    := Default(TExceptionFilters);
        Opts.ExceptionFiltersSet := True;
        Session.Attach(PI.dwProcessId, False, Opts);   // killOnDetach = False: a clean detach
        Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
        PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
        Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the line did not stop');
        var MainTid := Session.GetStoppedThreadId;
        var SpinnerTid := ThreadIn(Session, 'Spinner');
        Assert.IsTrue((SpinnerTid <> 0) and (SpinnerTid <> MainTid), Binary.Caption + ': no spinner thread to step');
        Session.StepOver(SpinnerTid);
        PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
        Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': the step of the other thread did not land');
        Assert.AreEqual(SpinnerTid, Session.GetStoppedThreadId, Binary.Caption + ': the step landed on another thread');
        Session.Terminate;
      finally
        Session.Free;
      end;
      var Waited := WaitForSingleObject(PI.hProcess, 15000);
      var ExitCode: DWORD := 0;
      GetExitCodeProcess(PI.hProcess, ExitCode);
      Check(Waited = WAIT_OBJECT_0, Binary.Caption + ': the detached program did not end: a thread that still ' +
        'had the trap flag set raised a single-step exception nobody handles');
      if Waited = WAIT_OBJECT_0 then
        Check(ExitCode = 0, Format('%s: the detached program ended with code %d ($%x)',
          [Binary.Caption, Integer(ExitCode), ExitCode]));
    finally
      // A program that sits in an error box must not outlive the test.
      if WaitForSingleObject(PI.hProcess, 0) <> WAIT_OBJECT_0 then begin
        TerminateProcess(PI.hProcess, 9);
        WaitForSingleObject(PI.hProcess, 5000);
      end;
      CloseHandle(PI.hProcess);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Rearm_InstructionUnderTheBreakpointFaults_TheBreakpointStopsTheNextPass;
// The instruction under the breakpoint raises an access violation, on every
// one of four passes, and the program catches it. After a hit the byte is
// away until the thread's single step -- which does not come when the
// instruction faults: the dispatch of the exception discards the trap flag.
// The re-arm stayed pending and the breakpoint without its byte: one stop,
// then never again. An exception on a thread that owes a re-arm completes it
// at once.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Line := MarkerLine(SAMPLE_SOURCE, FAULT_MARKER[Is64]);
    var Session := LaunchTarget(Binary, True, '-fault');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(CountOnLine(Stops, Line) = FAULT_PASSES,
        Format('%s: a breakpoint on an instruction that faults stopped %d of %d passes (%s)',
          [Binary.Caption, CountOnLine(Stops, Line), FAULT_PASSES, DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.Rearm_ExceptionStopOnAPlantedAddress_DoesNotLoseTheBreakpoint;
// The same program with first-chance access violations reported: each pass
// stops twice on the faulting instruction, at the breakpoint and then at the
// exception -- with the breakpoint planted again under the thread by then.
// Resuming from an exception stop delivers the exception; the thread does NOT
// execute the instruction at its PC. Taking the byte away there "for one
// instruction", as a resume from a breakpoint must, leaves it away: the single
// step that would bring it back is lost in the dispatch.
begin
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var Line := MarkerLine(SAMPLE_SOURCE, FAULT_MARKER[Is64]);
    var Session := LaunchTarget(Binary, True, '-fault');
    try
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      Assert.IsTrue(Session.SetExceptionFilters(['av'], ''), 'the exception filters were not set');
      Session.SetBreakpoints(SAMPLE_SOURCE, LineSpecs([Line]));
      GExit.BreakpointStops := 0;
      GExit.ExceptionStops  := 0;
      var Ended: Boolean;
      var Stops := RunToTheEnd(Session, Ended);
      Check(GExit.ExceptionStops = FAULT_PASSES,
        Format('%s: %d exception stops for %d access violations: the test did not build its case (%s)',
          [Binary.Caption, GExit.ExceptionStops, FAULT_PASSES, DescribeStops(Stops)]));
      Check(GExit.BreakpointStops = FAULT_PASSES,
        Format('%s: the breakpoint stopped %d of %d passes when each pass also stops on the exception ' +
          'at the same address (%s)', [Binary.Caption, GExit.BreakpointStops, FAULT_PASSES, DescribeStops(Stops)]));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded);
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

{ 5. when the analysis has to wait }

procedure TBreakpointPlacementTests.Analysis_ProviderStillIndexing_IsNotWaitedForAndNotKept;
// A module whose only provider of line records and routine ranges is still
// building its index. A real MAP asked for its tables in that state waits up
// to fifteen seconds for the indexer -- on the thread that dispatches debug
// events. The analysis must not ask at all: no verdict now, nothing kept, and
// a verdict as soon as the index is ready.
begin
  var Binary := SampleBinary('BreakpointSample', True);
  Assert.IsTrue(FileExists(Binary.Exe), 'fixture missing');
  var Image := TPeImageFile.Create(Binary.Exe);
  var Reader := TTD32FileReader.Create;
  var KeepReader: IInterface := Reader;
  Reader.LoadFromFile(Binary.Exe);
  var Provider := TIndexingProvider.Create;
  var KeepProvider: IInterface := Provider;
  Provider.Inner    := Reader;
  Provider.Pending  := True;
  Provider.Complete := True;
  var Providers: TArray<IInterface> := [KeepProvider];
  var Base := Image.ImageBase;
  var Size: UInt64 := Image.SizeOfImage;
  var Lookup: TLiveModuleLookup :=
    function(VA: UInt64; out Info: TLiveModuleInfo): Boolean
    begin
      Info := Default(TLiveModuleInfo);
      Result := (VA >= Base) and (VA - Base < Size);
      if not Result then
        Exit;
      Info.Name      := 'BreakpointSample.exe';
      Info.Base      := Base;
      Info.Size      := Size;
      Info.Providers := Providers;
    end;
  var Line := MarkerLine(SAMPLE_SOURCE, 'BS_SHARED_FIRST');
  var Rva: UInt64;
  Assert.IsTrue(Reader.SourceLineToRva(SAMPLE_SOURCE, Line, Rva), 'BS_SHARED_FIRST has no address');

  var Analysis := TLiveCodeAnalysis.Create(Image.Read, Lookup);
  try
    Analysis.ZydisDllPath := ResolveZydisDllPathForThisExe;
    var Reason: string;
    Assert.IsTrue(Analysis.JudgeAddress(Base + Rva, Reason) = pvNoAnalysis,
      'a verdict was given from a provider that is still indexing');
    Assert.AreEqual(0, Provider.TableCalls,
      'the tables of a provider that is still indexing were asked for: a MAP would have made the ' +
      'dispatch thread wait up to 15 s here');
    Assert.AreEqual<NativeInt>(0, Length(Analysis.Stats), 'something was kept for the module');
    Assert.AreEqual(1, Analysis.DeferredCount, 'the module is not remembered as waiting');
    Assert.IsFalse(Analysis.TakeModulesThatBecameReady, 'reported ready while still indexing');

    Provider.Pending := False;
    Assert.IsTrue(Analysis.TakeModulesThatBecameReady, 'not reported ready once the index was');
    Assert.IsFalse(Analysis.TakeModulesThatBecameReady, 'reported ready a second time');
    Assert.IsTrue(Analysis.JudgeAddress(Base + Rva, Reason) = pvPlant,
      'no verdict although the index is ready: ' + Reason);
    Assert.AreEqual<NativeInt>(1, Length(Analysis.Stats), 'the module was not analysed');
  finally
    Analysis.Free;
  end;

  // A provider that is NOT indexing and still cannot enumerate everything: its
  // tables are not a code map. No verdict, no map kept -- and the question is
  // not worked out again for every breakpoint.
  Provider.Pending    := False;
  Provider.Complete   := False;
  Provider.TableCalls := 0;
  Analysis := TLiveCodeAnalysis.Create(Image.Read, Lookup);
  try
    Analysis.ZydisDllPath := ResolveZydisDllPathForThisExe;
    var Reason: string;
    Assert.IsTrue(Analysis.JudgeAddress(Base + Rva, Reason) = pvNoAnalysis,
      'a verdict was given from tables their provider calls incomplete');
    Assert.AreEqual<NativeInt>(0, Length(Analysis.Stats), 'an incomplete code map was kept');
    var CallsAfterTheFirst := Provider.TableCalls;
    Assert.IsTrue(CallsAfterTheFirst > 0, 'the provider was never asked: the test shows nothing');
    Analysis.JudgeAddress(Base + Rva, Reason);
    Assert.AreEqual(CallsAfterTheFirst, Provider.TableCalls, 'the incomplete tables were read again for the same module');
  finally
    Analysis.Free;
    KeepProvider := nil;
    KeepReader := nil;
    Image.Free;
  end;
end;

procedure TBreakpointPlacementTests.LoadMapOfThePackageAndAsk(const Name, Path: string;
  Base, ImageSize: UInt64);
// What a front end's own eager probe does at a load event: read the package's
// MAP at once. The background prefetcher is given the module right after this
// hook and brings its TD32 later.
begin
  if not SameText(Name, 'testsubject.bpl') then
    Exit;
  var Session := TDebugSession(FHookSession);
  for var Module in Session.Loader.Modules do begin
    if Module.Base <> Base then
      Continue;
    Session.Loader.EnsureModuleMap(Module);
    if Module.MapIface = nil then begin
      FHookNote := 'the MAP of the package did not load';
      Exit;
    end;
    var Background: IBackgroundIndexProvider;
    var Deadline := GetTickCount64 + 10000;
    while Supports(Module.MapIface, IBackgroundIndexProvider, Background) and
          Background.BackgroundIndexingPending and (GetTickCount64 < Deadline) do
      Sleep(5);
    var Lines: ISourceLineProvider;
    var Rva: UInt64;
    if not (Supports(Module.MapIface, ISourceLineProvider, Lines) and
            Lines.SourceLineToRva('TestTargetCore.pas', MarkerLine('TestTargetCore.pas', 'CTOR_BODY'), Rva)) then begin
      FHookNote := 'the MAP of the package has no address for CTOR_BODY';
      Exit;
    end;
    {$Q-}
    FHookProbeVA := Session.Debugger.ImageBase + Rva;
    {$Q+}
    var Verdict: TRoutineLine;
    if not Session.CodeAnalysis.TryAnalyzeAddress(FHookProbeVA, Verdict) then begin
      FHookNote := 'the analysis had nothing to say about the package from its MAP';
      Exit;
    end;
    for var Item in Session.CodeAnalysis.Stats do
      if Item.Base = Base then
        FHookProviders := Item.ProviderCount;
    FHookNote := 'asked';
  end;
end;

procedure TBreakpointPlacementTests.Analysis_ProvidersPublishedByThePrefetcher_AreUsedAtTheNextQuestion;
// The analysis of a module is built from the providers the module has at that
// moment, and a verdict it has given is answered again without looking. When
// the background prefetcher then registers the module's TD32, the old map --
// built from the MAP alone -- kept answering. The package's MAP is read at
// its load event here, the analysis asked, and the prefetcher left to bring
// the rest.
begin
  for var Is64 in [False, True] do begin
    var Binary := HostBinary(Is64);
    FHookProbeVA   := 0;
    FHookProviders := 0;
    FHookNote      := 'the load hook never saw the package';
    var Session := LaunchTarget(Binary, True);
    try
      FHookSession := Session;
      Session.OnDllLoadedHook := LoadMapOfThePackageAndAsk;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop at entry');
      // An ADDRESS breakpoint in the host, after the package is loaded: with a
      // source breakpoint pending, the session would read the package's
      // symbols itself at the load event and the prefetcher would have nothing
      // to bring.
      var HostLine := LineContaining(RepoRoot + 'DebuggerTests\TestHost\TestHost.dpr', 'GetProcAddress(H,');
      Assert.IsTrue(HostLine > 0, 'the line after LoadPackage was not found in TestHost.dpr');
      var HostVA: UInt64;
      Assert.IsTrue(Session.GetGotoTargetVA('TestHost.dpr', HostLine, HostVA), 'that line has no address');
      Assert.IsTrue(Session.SetAddressBreakpoint(HostVA, '', '', '').Verified, 'the address breakpoint did not resolve');
      Session.ContinueExecution;
      PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
      Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Binary.Caption + ': did not stop after LoadPackage');
      Assert.AreEqual('asked', FHookNote, Binary.Caption + ': the test did not get to ask at the load event');
      Assert.AreEqual(1, FHookProviders, Binary.Caption + ': the first analysis was not built from the MAP alone');

      // Publication happens in the pump, while stopped.
      var Package: TModuleSymbols := nil;
      for var Module in Session.Loader.Modules do
        if SameText(Module.Name, 'testsubject.bpl') then
          Package := Module;
      Assert.IsNotNull(Package, Binary.Caption + ': the package is not registered');
      var Deadline := GetTickCount64 + 20000;
      while (Package.Td32Iface = nil) and (GetTickCount64 < Deadline) do begin
        Session.Pump;
        Sleep(5);
      end;
      if Package.Td32Iface = nil then begin
        Check(False, Binary.Caption + ': the prefetcher never published the package''s TD32 (prefetch off?): ' +
          'the test shows nothing');
        Continue;
      end;

      var Verdict: TRoutineLine;
      Check(Session.CodeAnalysis.TryAnalyzeAddress(FHookProbeVA, Verdict),
        Binary.Caption + ': no analysis of the package after its symbols arrived');
      var ProvidersNow := 0;
      for var Item in Session.CodeAnalysis.Stats do
        if Item.Base = Package.Base then
          ProvidersNow := Item.ProviderCount;
      Check(ProvidersNow = Length(Session.Loader.CodeMapProviders(Package)),
        Format('%s: the analysis of the package still rests on %d provider(s) although the module has %d ' +
          'now: what the prefetcher published is not used', [Binary.Caption, ProvidersNow,
          Length(Session.Loader.CodeMapProviders(Package))]));
    finally
      EndSession(Session);
      FHookSession := nil;
    end;
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.ModuleRelocatedAfterItsLoadEvent_IsJudgedAgainAtItsEntryPoint;
// BreakpointSampleLib.dll has a fixed base, and the program takes that address
// before loading it: the loader maps the DLL elsewhere and relocates it AFTER
// the load event. At that event the breakpoints are planted and the image
// cannot be analysed yet, so they get what the fallback gives: no copy in the
// funclet, and no refusal of a line record that sits in a table of addresses
// (its bytes are not zero). The DLL's entry point is the first moment the
// analysis can read it, and the breakpoints are judged again there.
const
  TABLE_LINE: array[Boolean] of string = ('DD      @@zero', 'DQ      @@zero');
  REASON = 'inside a jump table';
  LIB_EXTENT = UInt64($200000);   // more than the DLL's image, less than the gap to anything else
begin
  var LibSource := TargetDir + LIB_SOURCE;
  var FinallyLine := LineContaining(LibSource, '{BP:BSL_FINALLY_BLOCK}');
  Assert.IsTrue(FinallyLine > 0, 'BSL_FINALLY_BLOCK not found');
  for var Is64 in [False, True] do begin
    var Binary := SampleBinary('BreakpointSample', Is64);
    var TableLine := LineContaining(LibSource, TABLE_LINE[Is64]);
    Assert.IsTrue(TableLine > 0, 'the table line of LibTable was not found');
    var Session := LaunchTarget(Binary, False, '-lib');
    try
      Session.SetBreakpoints(LIB_SOURCE, LineSpecs([FinallyLine, TableLine]));
      var Ended := False;
      var Stops: TArray<TStop> := nil;
      var LibBase: UInt64 := 0;
      // The stops are told apart by ADDRESS, not by line: where the loader
      // puts the DLL varies, and a stop in a module mapped below the main
      // image is reported without a line (docs/TRAPS.md).
      var TableVA: UInt64 := 0;
      var InTheBlock: TArray<UInt64> := nil;
      for var Round := 0 to MAX_STOPS do begin
        if Session.State = dsStopped then
          Session.ContinueExecution;
        PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
        if Session.HasExited then begin
          Ended := GExit.Exited and (GExit.Code = 0);
          Break;
        end;
        if Session.State <> dsStopped then
          Break;
        Stops := Stops + [CurrentStop(Session)];
        for var Module in Session.GetModules do
          if SameText(Module.Name, 'breakpointsamplelib.dll') then
            LibBase := Module.Base;
        if LibBase <> 0 then begin
          Session.GetGotoTargetVA(LIB_SOURCE, TableLine, TableVA);
          if (Stops[High(Stops)].IP >= LibBase) and (Stops[High(Stops)].IP - LibBase < LIB_EXTENT) and
             (Stops[High(Stops)].IP <> TableVA) then
            InTheBlock := InTheBlock + [Stops[High(Stops)].IP];
        end;
      end;

      Check(Length(InTheBlock) = 2,
        Format('%s: the finally block of the relocated DLL stopped %d times for two passes (%s)',
          [Binary.Caption, Length(InTheBlock), DescribeStops(Stops)]));
      if Length(InTheBlock) = 2 then
        // One address on x86, where the block is emitted once; two on x64.
        Check((InTheBlock[0] <> InTheBlock[1]) = Is64, Format('%s: the two passes stopped at $%x and $%x',
          [Binary.Caption, InTheBlock[0], InTheBlock[1]]));
      Check(Length(Stops) = Length(InTheBlock), Binary.Caption + ': stopped elsewhere as well, the table line ' +
        'included: ' + DescribeStops(Stops));
      Check(Ended, Binary.Caption + ': the program did not run to its end, ' + HowItEnded +
        ': the breakpoint stayed in the table of the relocated DLL');
      // The scenario is the one it is named after: the DLL was moved.
      Check((LibBase <> 0) and (LibBase <> LIB_PREFERRED_BASE),
        Format('%s: the DLL is at $%x: it was not moved off its preferred base, so nothing was relocated',
          [Binary.Caption, LibBase]));
      var Announced := '';
      for var Text in Session.DrainDebuggerOutput do
        if Text.Contains('was not set') then
          Announced := Text;
      Check(Announced.Contains(REASON), Format('%s: the table line was not refused with "%s" once the DLL ' +
        'could be analysed (got "%s")', [Binary.Caption, REASON, Announced]));
    finally
      EndSession(Session);
    end;
  end;
  AssertNoProblems;
end;

{ 6. a unit's final end. }

procedure TBreakpointPlacementTests.FinalEndOfAUnit_OnBytesThatDecode_IsRefused;
// On a 32-bit image the record of a unit's final `end.` points past the unit's
// last routine. A third of them land on bytes that happen to decode (`4F`,
// dec edi), which says nothing: the record is unconfirmed, and was planted.
// It is recognised for what it is instead: the last line of its unit's own
// file, outside every routine. The fixture's `end.` records all land on a zero
// byte, so the byte is changed here -- in the reader for the decision function,
// in the live process for the session -- and nothing else.
const
  UNIT_FILE = 'TestTargetUsesA.pas';
  WANTED    = 'final "end."';
  DECODES: Byte = $4F;
begin
  var Binary := SampleBinary('TestTarget', False);
  Assert.IsTrue(FileExists(Binary.Exe), 'fixture missing');
  var EndLine := 0;
  var Source := TStringList.Create;
  try
    Source.LoadFromFile(TargetDir + UNIT_FILE);
    for var I := Source.Count - 1 downto 0 do
      if SameText(Source[I].Trim, 'end.') then begin
        EndLine := I + 1;
        Break;
      end;
  finally
    Source.Free;
  end;
  Assert.IsTrue(EndLine > 0, 'no final "end." in ' + UNIT_FILE);

  // --- the decision function, over the file ---
  var Image := TPeImageFile.Create(Binary.Exe);
  var Reader := TTD32FileReader.Create;
  var Keep: IInterface := Reader;
  Reader.LoadFromFile(Binary.Exe);
  var Providers: TArray<IInterface> := [Keep];
  var Base := Image.ImageBase;
  var Size: UInt64 := Image.SizeOfImage;
  var EndRva: UInt64;
  Assert.IsTrue(Reader.SourceLineToRva(UNIT_FILE, EndLine, EndRva), 'the "end." line has no address');
  var Patched := False;
  var ByteReader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; BufSize: Integer): Integer
    begin
      Result := Image.Read(VA, Buf, BufSize);
      if Patched and (Base + EndRva >= VA) and (Base + EndRva - VA < UInt64(Result)) then
        PByte(NativeUInt(Buf) + NativeUInt(Base + EndRva - VA))^ := DECODES;
    end;
  for var WithTheByteChanged in [False, True] do begin
    Patched := WithTheByteChanged;
    var Analysis := TLiveCodeAnalysis.Create(ByteReader,
      function(VA: UInt64; out Info: TLiveModuleInfo): Boolean
      begin
        Info := Default(TLiveModuleInfo);
        Result := (VA >= Base) and (VA - Base < Size);
        if not Result then
          Exit;
        Info.Name      := 'TestTarget.exe';
        Info.Base      := Base;
        Info.Size      := Size;
        Info.Providers := Providers;
      end);
    try
      Analysis.ZydisDllPath := ResolveZydisDllPathForThisExe;
      var Verdict: TRoutineLine;
      Assert.IsTrue(Analysis.TryAnalyzeAddress(Base + EndRva, Verdict), 'no analysis of the fixture');
      var Reason: string;
      var Answer := Analysis.JudgeAddress(Base + EndRva, Reason);
      if WithTheByteChanged then begin
        Check(Verdict.Reason = lvrFinalEndOfUnit, 'a final "end." on a byte that decodes is: ' +
          LineVerdictReasonText(Verdict.Reason));
        Check((Answer = pvRefuse) and Reason.Contains(WANTED),
          Format('a final "end." on a byte that decodes was not refused as one (verdict %d, "%s")',
            [Ord(Answer), Reason]));
      end else
        Check(Verdict.Reason = lvrZeroByte, 'the fixture''s "end." record is no longer on a zero byte: ' +
          LineVerdictReasonText(Verdict.Reason));
    finally
      Analysis.Free;
    end;
  end;
  Keep := nil;
  Image.Free;

  // --- the session, with the byte changed in the live process ---
  var Session := LaunchTarget(Binary, True);
  try
    PumpUntilStoppedOrExited(Session, STOP_TIMEOUT_MS);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), 'did not stop at entry');
    var VA: UInt64;
    Assert.IsTrue(Session.GetGotoTargetVA(UNIT_FILE, EndLine, VA), 'the "end." line has no address in the session');
    var Original: Byte := $FF;
    Assert.IsTrue(Session.Debugger.ReadProcessMemoryAt(VA, @Original, 1) and (Original = 0),
      'the live "end." record is not on a zero byte');
    var NewByte := DECODES;
    Assert.IsTrue(Session.Debugger.WriteMemoryAt(VA, @NewByte, 1), 'could not change the byte');
    var Bps := Session.SetBreakpoints(UNIT_FILE, LineSpecs([EndLine]));
    Check((Length(Bps) = 1) and not Bps[0].Verified,
      'a breakpoint on a final "end." whose byte decodes was reported verified');
    var Ended: Boolean;
    var Stops := RunToTheEnd(Session, Ended);
    Check(Length(Stops) = 0, 'the session stopped: ' + DescribeStops(Stops));
    Check(Ended, 'the program did not run to its end, ' + HowItEnded);
    var Announced := '';
    for var Text in Session.DrainDebuggerOutput do
      if Text.Contains('was not set') then
        Announced := Text;
    Check(Announced.Contains(WANTED), 'the refusal does not say what the line is: "' + Announced + '"');
  finally
    EndSession(Session);
  end;
  AssertNoProblems;
end;

procedure TBreakpointPlacementTests.FinalEndOfAUnit_Synthetic_OnlyTheLastLineOfTheUnitsOwnFileOutsideEveryRoutine;
// The rule has three conditions, and the large images show why each is there
// (docs/DAP_DEBUGGER_ARCHITECTURE.md, "A unit's final end."). No fixture has
// the cases that must NOT be refused, so the tables are written by hand: every
// byte decodes (`4F`), and only the record that is the last line of its unit's
// own file, outside every routine, may be called the final `end.`.
const
  IMAGE_SIZE = $1000;
  BASE       = UInt64($400000);
  FILE_A = 0;
  FILE_B = 1;
  FILE_C = 2;
  UNIT_A = 0;
  UNIT_C = 1;
  FINAL_END        = 220;
  EARLIER_LINE     = 210;
  OTHER_UNITS_FILE = 300;
  SHARES_ITS_LINE  = 600;

  function Line(Rva: UInt64; LineNumber, FileIndex, UnitIndex: Integer): TLineRecord;
  begin
    Result.Rva       := Rva;
    Result.FileIndex := FileIndex;
    Result.Line      := LineNumber;
    Result.UnitIndex := UnitIndex;
  end;

  function Routine(StartRva, EndRva: UInt64; const Name, UnitName: string): TRoutineRange;
  begin
    Result := Default(TRoutineRange);
    Result.StartRva := StartRva;
    Result.EndRva   := EndRva;
    Result.Name     := Name;
    Result.UnitName := UnitName;
  end;

begin
  var Tables := TTablesProvider.Create;
  var Keep: IInterface := Tables;
  Tables.Table.Files := [Default(TLineRecordFile), Default(TLineRecordFile), Default(TLineRecordFile)];
  Tables.Table.Files[FILE_A].Name := 'UnitA.pas';
  Tables.Table.Files[FILE_B].Name := 'UnitB.pas';
  Tables.Table.Files[FILE_C].Name := 'UnitC.pas';
  Tables.Table.Units := ['UnitA', 'UnitC'];
  Tables.Ranges := [Routine(100, 200, 'A', 'UnitA'), Routine(400, 500, 'C', 'UnitC')];
  Tables.Table.Records := [
    Line(100, 10, FILE_A, UNIT_A),                // inside A
    Line(EARLIER_LINE, 40, FILE_A, UNIT_A),       // outside, not the last line of its file
    Line(FINAL_END, 50, FILE_A, UNIT_A),          // outside, the last line of UnitA.pas
    // Code of UnitA recorded under ANOTHER unit's file, with a line number
    // beyond anything else in it: an instantiated generic, whose synthesised
    // code the compiler numbers past the end of the file.
    Line(OTHER_UNITS_FILE, 900, FILE_B, UNIT_A),
    Line(400, 77, FILE_C, UNIT_C),                // inside C
    Line(SHARES_ITS_LINE, 77, FILE_C, UNIT_C)];   // outside, on a line that also has code in a routine

  var ZeroAtTheEnd := False;
  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; BufSize: Integer): Integer
    begin
      FillChar(Buf^, BufSize, $4F);
      if ZeroAtTheEnd and (BASE + FINAL_END >= VA) and (BASE + FINAL_END - VA < UInt64(BufSize)) then
        PByte(NativeUInt(Buf) + NativeUInt(BASE + FINAL_END - VA))^ := 0;
      Result := BufSize;
    end;

  var Map := TModuleCodeMap.Build('fake', Tables, Tables, 0, IMAGE_SIZE);
  try
    Assert.AreEqual(50, Map.LastLineOutsideRoutines(FILE_A), 'the last line of UnitA.pas has no code in a routine');
    Assert.AreEqual(900, Map.LastLineOutsideRoutines(FILE_B));
    Assert.AreEqual(-1, Map.LastLineOutsideRoutines(FILE_C),
      'the last line of UnitC.pas has a record inside a routine: it is not an "end."');
    Assert.AreEqual(-1, Map.LastLineOutsideRoutines(99), 'a file that does not exist');

    var Input := Default(TRoutineAnalysisInput);
    Input.Mode         := dmmLegacy32;
    Input.Reader       := Reader;
    Input.ImageBase    := BASE;
    Input.CodeMap      := Map;
    Input.ZydisDllPath := ResolveZydisDllPathForThisExe;
    var Analyzer := TRoutineAnalyzer.Create(Input);
    try
      Assert.IsTrue(Analyzer.Available, 'no decoder: ' + Analyzer.StatusText);
      var Final := Analyzer.AnalyzeAddress(FINAL_END);
      Assert.IsTrue((Final.Reason = lvrFinalEndOfUnit) and (Final.Verdict = lvNotCode),
        'the last line of the unit''s own file, outside every routine, on a byte that decodes: ' +
        LineVerdictReasonText(Final.Reason));
      for var Rva in [EARLIER_LINE, OTHER_UNITS_FILE, SHARES_ITS_LINE] do begin
        var Other := Analyzer.AnalyzeAddress(Rva);
        Assert.IsTrue(Other.Verdict = lvUnconfirmed,
          Format('the record at %d must stay unconfirmed, it is: %s', [Rva, LineVerdictReasonText(Other.Reason)]));
      end;
    finally
      Analyzer.Free;
    end;

    // A zero byte there is said to be a zero byte, as before: the more
    // specific observation comes first.
    ZeroAtTheEnd := True;
    Analyzer := TRoutineAnalyzer.Create(Input);
    try
      Assert.IsTrue(Analyzer.AnalyzeAddress(FINAL_END).Reason = lvrZeroByte, 'a zero byte is reported as one');
    finally
      Analyzer.Free;
    end;
  finally
    Map.Free;
  end;
end;

initialization
  GExit := TExitWatcher.Create;
  TDUnitX.RegisterTestFixture(TBreakpointPlacementTests);

finalization
  GExit.Free;

end.
