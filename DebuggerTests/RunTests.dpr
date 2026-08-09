program RunTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Filters,
  DUnitX.Extensibility,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.NUnit,
  DebuggerTests   in 'DebuggerTests.pas',
  BugRegressionTests in 'BugRegressionTests.pas',
  DapClient       in 'DapClient.pas',
  RsmReaderTests  in 'RsmReaderTests.pas',
  TD32ReaderTests in 'TD32ReaderTests.pas',
  JclDebugReaderTests in 'JclDebugReaderTests.pas',
  MapReaderTests  in 'MapReaderTests.pas',
  X86DecodeTests  in 'X86DecodeTests.pas',
  RttiRobustnessTests in 'RttiRobustnessTests.pas',
  ExceptionRulesTests in 'ExceptionRulesTests.pas',
  ProcessListJsonTests in 'ProcessListJsonTests.pas',
  ProcessEnum     in '..\DebuggerCore\ProcessEnum.pas',
  ProcessListJson in '..\DebuggerCore\ProcessListJson.pas',
  DapProtocol     in '..\DebuggerCore\DapProtocol.pas',
  ExceptionRules  in '..\DebuggerCore\ExceptionRules.pas',
  RsmTags         in '..\DebuggerCore\RsmTags.pas',
  RsmDecoders     in '..\DebuggerCore\RsmDecoders.pas',
  RsmFileReader   in '..\DebuggerCore\RsmFileReader.pas',
  MapFileReader   in '..\DebuggerCore\MapFileReader.pas',
  TD32FileReader  in '..\DebuggerCore\TD32FileReader.pas',
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  DebugInfoSet    in '..\DebuggerCore\DebugInfoSet.pas',
  DebugTarget     in '..\DebuggerCore\DebugTarget.pas',
  DelphiRtti      in '..\DebuggerCore\DelphiRtti.pas',
  DelphiValueReaders in '..\DebuggerCore\DelphiValueReaders.pas',
  ExprEval        in '..\DebuggerCore\ExprEval.pas',
  X86Decode       in '..\DebuggerCore\X86Decode.pas',
  WinDebuggerBase in '..\DebuggerCore\WinDebuggerBase.pas',
  DebugSessionTypes in '..\DebuggerCore\DebugSessionTypes.pas',
  SourceResolver  in '..\DebuggerCore\SourceResolver.pas',
  DebugSession    in '..\DebuggerCore\DebugSession.pas',
  LaunchConfig    in '..\MCPDebugger\LaunchConfig.pas',
  DebugSessionTests in 'DebugSessionTests.pas',
  McpE2ETests     in 'McpE2ETests.pas',
  ValueReaderTests in 'ValueReaderTests.pas',
  Disassembler    in '..\DebuggerCore\Disassembler.pas',
  ZydisApi        in '..\DebuggerCore\ZydisApi.pas',
  ZydisDisassembler in '..\DebuggerCore\ZydisDisassembler.pas',
  DisassemblerTests in 'DisassemblerTests.pas',
  InstructionStepTests in 'InstructionStepTests.pas',
  InstructionStepDapTests in 'InstructionStepDapTests.pas',
  MemoryDapTests  in 'MemoryDapTests.pas',
  RegisterWriteDapTests in 'RegisterWriteDapTests.pas',
  PlaceholderDisassemblyTests in 'PlaceholderDisassemblyTests.pas';

const
  // Tests that cannot run while another RunTests worker is executing, because
  // they reach for a process by NAME rather than by handle or pid and would
  // therefore pick up a sibling worker's debuggee. RunTestsParallel excludes
  // them from the parallel shards and runs them alone afterwards. Keep the list
  // as short as the evidence justifies: everything else in the suite addresses
  // its own processes and its own pid-scoped temp files.
  NOT_PARALLEL_SAFE: array[0..1] of string = (
    // Attaches to a process found by NAME: with siblings running it can pick up
    // another worker's debuggee.
    'test_attach_byprocessname',
    // Asserts that TestTarget.exe can be opened EXCLUSIVELY once the session
    // released its symbol mappings. Any sibling worker with a live session on
    // the same exe holds that lock, and the exclusive open would in turn make a
    // sibling's CreateProcess fail. Shared-resource by nature.
    'terminate_releasessymbolfilelock'
  );

type
  // Test selection driven by the environment, so the same binary serves the full
  // suite, a targeted dev iteration and one worker of a parallel run.
  //
  //   RUNTESTS_ONLY=<substring>   only tests whose full name contains it
  //                               (case-insensitive). The long-standing fast
  //                               path for day-to-day work; unchanged.
  //   RUNTESTS_SHARD=<i>/<n>      run only shard i of n. Assignment is a stable
  //                               hash of the test's full name, so a shard is
  //                               reproducible from its number alone and does
  //                               not depend on discovery order.
  //   RUNTESTS_SERIAL=exclude     skip the NOT_PARALLEL_SAFE tests (shards)
  //   RUNTESTS_SERIAL=only        run ONLY those tests (the serial tail)
  //   RUNTESTS_NAMES=a;b;c        run only tests whose full name contains one of
  //                               the `;`-separated needles. Used by the
  //                               sequential re-check of a parallel run's
  //                               failures, which needs to name an arbitrary SET
  //                               of tests in one pass. It overrides sharding and
  //                               the serial split, because a re-check must be
  //                               able to reach a NOT_PARALLEL_SAFE test too.
  //
  // With none of them set the filter is empty and every test runs, which is
  // exactly the committed sequential behaviour.
  TSelectionFilter = class(TInterfacedObject, ITestFilter)
  private
    FNeedle:      string;
    FNames:       TArray<string>;
    FShardIndex:  Integer;
    FShardCount:  Integer;
    FSerialMode:  string;
    function IsNotParallelSafe(const AFullName: string): Boolean;
    function MatchesAnyName(const AFullName: string): Boolean;
  public
    constructor Create(const ANeedle, ANames: string;
      AShardIndex, AShardCount: Integer; const ASerialMode: string);
    function IsEmpty: Boolean;
    function Match(const Test: ITest): Boolean;
  end;

constructor TSelectionFilter.Create(const ANeedle, ANames: string;
  AShardIndex, AShardCount: Integer; const ASerialMode: string);
begin
  inherited Create;
  FNeedle     := LowerCase(ANeedle);
  FShardIndex := AShardIndex;
  FShardCount := AShardCount;
  FSerialMode := LowerCase(ASerialMode);

  FNames := [];
  for var Part in LowerCase(ANames).Split([';']) do
    if Part.Trim <> '' then
      FNames := FNames + [Part.Trim];
end;

function TSelectionFilter.IsEmpty: Boolean;
begin
  Result := (FNeedle = '') and (Length(FNames) = 0) and (FShardCount <= 1) and
            (FSerialMode = '');
end;

function TSelectionFilter.MatchesAnyName(const AFullName: string): Boolean;
begin
  for var Name in FNames do
    if Pos(Name, AFullName) > 0 then
      Exit(True);
  Result := False;
end;

function TSelectionFilter.IsNotParallelSafe(const AFullName: string): Boolean;
begin
  for var Name in NOT_PARALLEL_SAFE do
    if Pos(Name, AFullName) > 0 then
      Exit(True);
  Result := False;
end;

// FNV-1a. Any stable hash would do; what matters is that shard membership is a
// pure function of the name, so re-running "shard 3 of 8" reruns the same tests
// even if discovery order changes.
function StableHash(const S: string): Cardinal;
begin
  Result := 2166136261;
  for var I := 1 to Length(S) do begin
    Result := Result xor Ord(S[I]);
    Result := Result * 16777619;
  end;
end;

function TSelectionFilter.Match(const Test: ITest): Boolean;
begin
  var FullName := LowerCase(Test.FullName);

  if (FNeedle <> '') and (Pos(FNeedle, FullName) = 0) then
    Exit(False);

  // An explicit name set answers on its own: no shard, no serial split. This is
  // the re-check pass, and it must be able to select exactly the tests that
  // failed wherever they ran.
  if Length(FNames) > 0 then
    Exit(MatchesAnyName(FullName));

  if FSerialMode = 'only' then
    Exit(IsNotParallelSafe(FullName));

  if (FSerialMode = 'exclude') and IsNotParallelSafe(FullName) then
    Exit(False);

  if FShardCount > 1 then
    Exit(Integer(StableHash(FullName) mod Cardinal(FShardCount)) = FShardIndex);

  Result := True;
end;

// Parses "i/n" into its two parts. Anything malformed leaves sharding off.
procedure ParseShardSpec(const Spec: string; out AIndex, ACount: Integer);
begin
  AIndex := 0;
  ACount := 0;
  var Slash := Pos('/', Spec);
  if Slash <= 1 then
    Exit;
  AIndex := StrToIntDef(Copy(Spec, 1, Slash - 1), -1);
  ACount := StrToIntDef(Copy(Spec, Slash + 1, MaxInt), 0);
  if (ACount < 1) or (AIndex < 0) or (AIndex >= ACount) then begin
    AIndex := 0;
    ACount := 0;
  end;
end;

var
  Runner:  ITestRunner;
  Results: IRunResults;
  Logger:  ITestLogger;
  XmlLog:  ITestLogger;
  OnlyNeedle: string;
  NameSet:    string;
  ShardIndex, ShardCount: Integer;
  SerialMode: string;
  Selection:  ITestFilter;
begin
  try
    TDUnitX.CheckCommandLine;
    Runner  := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;

    Logger := TDUnitXConsoleLogger.Create(True);
    Runner.AddLogger(Logger);

    XmlLog := TDUnitXXMLNUnitFileLogger.Create(
      TDUnitX.Options.XMLOutputFile);
    Runner.AddLogger(XmlLog);

    OnlyNeedle := GetEnvironmentVariable('RUNTESTS_ONLY');
    NameSet    := GetEnvironmentVariable('RUNTESTS_NAMES');
    SerialMode := LowerCase(GetEnvironmentVariable('RUNTESTS_SERIAL'));
    ParseShardSpec(GetEnvironmentVariable('RUNTESTS_SHARD'), ShardIndex, ShardCount);

    Selection := TSelectionFilter.Create(OnlyNeedle, NameSet, ShardIndex,
      ShardCount, SerialMode);
    if not Selection.IsEmpty then begin
      TDUnitX.Filter := Selection;
      if OnlyNeedle <> '' then
        Writeln('FILTER: only tests matching "', OnlyNeedle, '"');
      if NameSet <> '' then
        Writeln('FILTER: named tests "', NameSet, '"');
      if ShardCount > 1 then
        Writeln(Format('FILTER: shard %d of %d', [ShardIndex, ShardCount]));
      if SerialMode <> '' then
        Writeln('FILTER: serial-set mode "', SerialMode, '"');
    end;

    Results := Runner.Execute;

    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.Message);
      System.ExitCode := EXIT_ERRORS;
    end;
  end;
end.
