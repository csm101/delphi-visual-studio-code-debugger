unit ProjectExceptionRulesTests;

// Project-scoped exception rules, over the DAP wire against a real adapter and a
// real debuggee.
//
// A launch/attach configuration may name the Delphi project it debugs
// (`delphiProjectFile`). When it does, two rule files sitting NEXT TO THAT
// PROJECT join the precedence chain ahead of everything that already existed:
//
//   1. <Project>.ExceptionSettings.local.json   personal, gitignored
//   2. <Project>.ExceptionSettings.json         the project's own, committed
//   3. the launch configuration's `exceptionRules`
//   4. the machine-wide shared file
//
// First match wins across the whole chain, so each tier is proved BOTH ways
// round: it must be able to break where a wider tier ignores, and to ignore
// where a wider tier breaks. Proving only one direction would pass just as well
// if the tiers were concatenated in any order at all.
//
// Every test here runs with the `unhandled` filter only, so a first-chance
// Delphi exception does NOT stop unless a rule says `break`. That makes both
// outcomes observable and fast: a stopped event, or the target running to
// completion.

interface

uses
  DUnitX.TestFramework, System.JSON, DapClient;

type
  [TestFixture]
  TProjectExceptionRulesTests = class
  private
    FClient:      TDapClient;
    FScratch:     string;
    FProjectFile: string;   // <scratch>\ScopedFixture.dpr -- never has to exist
    // Writes one of the two sidecars next to FProjectFile. `Rules` is the JSON
    // text of the file, so a test can pass an object, a bare array or garbage.
    procedure WriteSharedSidecar(const FileText: string);
    procedure WriteLocalSidecar(const FileText: string);
    // The adapter up to (but not including) `launch`, with only the `unhandled`
    // filter armed.
    procedure StartAdapter;
    // `--run-exception-test` raises and catches one Exception('exc-test').
    procedure LaunchExceptionTarget;
    procedure LaunchExceptionTargetWithConfigRules(const RulesJson: string);
    procedure LaunchExceptionTargetWithGlobalFile(const GlobalPath: string);
    procedure AssertStoppedOnExcTest(const Context: string);
    procedure AssertRanToCompletion(const Context: string);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // The feature itself: a rule that lives only in the project's shared sidecar
    // decides what the exception filters would not have stopped on.
    [Test] procedure SharedSidecar_BreaksWhereTheFiltersWouldNot;
    // ...and the same file left unnamed changes nothing. This is what protects
    // every existing user whose launch.json predates `delphiProjectFile`.
    [Test] procedure WithoutDelphiProjectFile_TheSidecarsAreNotRead;
    // A macro that nobody expanded is not a directory; deriving sidecar paths
    // from the literal text would look for rules in a folder called "${...}".
    [Test] procedure UnresolvedMacroInTheProjectPath_IsIgnored;

    // Tier 1 vs tier 2, both directions.
    [Test] procedure LocalSidecar_IgnoresWhereTheSharedSidecarBreaks;
    [Test] procedure LocalSidecar_BreaksWhereTheSharedSidecarIgnores;
    // Tier 2 vs tier 3, both directions.
    [Test] procedure SharedSidecar_IgnoresWhereTheLaunchConfigurationBreaks;
    [Test] procedure SharedSidecar_BreaksWhereTheLaunchConfigurationIgnores;
    // Tier 3 still decides everything the sidecars do not match: the new tiers
    // are inserted ahead of it, they do not replace it.
    [Test] procedure LaunchConfigurationStillDecidesWhatNoSidecarMatches;
    // Tier 2 vs tier 4.
    [Test] procedure SharedSidecar_BreaksWhereTheMachineWideFileIgnores;

    // Same two file shapes the machine-wide file accepts.
    [Test] procedure SidecarAsBareArray_IsAccepted;
    // A rules file the user broke must cost them the rules, not the session.
    [Test] procedure MalformedSidecar_LeavesDebuggingWorking;

    // Editing a sidecar while stopped applies on resume, exactly as editing the
    // machine-wide file already did.
    [Test] procedure SharedSidecar_HotReloadsOnResume;
    // A sidecar that did not exist when the session started is picked up when it
    // appears, because "absent" is a state the reload can see change.
    [Test] procedure SidecarCreatedMidSession_IsPickedUpOnResume;

    // The attach path reads the same chain the launch path does.
    [Test] procedure Attach_HonoursTheSharedSidecar;
  end;

  // The package case, which is what the feature exists for: rules that belong to
  // a .dpk and follow it into whatever host process happens to load it.
  [TestFixture]
  TPackageExceptionRulesTests = class
  private
    FClient:  TDapClient;
    FSidecar: string;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure PackageSidecar_AppliesInsideAHostThatKnowsNothingAboutIt;
    // The repository's own worked example, which is also the one a reader copies.
    [Test] procedure TheDebugmeSampleSidecar_IsAFileTheAdapterCanActuallyRead;
  end;

implementation

uses
  System.SysUtils, System.StrUtils, System.IOUtils, Winapi.Windows, TestTempDirs;

const
  // The exception `--run-exception-test` raises and catches.
  EXC_MESSAGE = 'exc-test';
  // Long enough for a launch + symbol load on a loaded machine.
  STOP_TIMEOUT_MS = 20000;
  RUN_TIMEOUT_MS  = 20000;

function RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

function TargetMap: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

function TargetRsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

// A rules file naming one exception and what to do about it.
function RuleFile(const Action: string): string;
begin
  Result := Format('{ "exceptionRules": [ {"message": "%s", "action": "%s"} ] }',
    [EXC_MESSAGE, Action]);
end;

{ TProjectExceptionRulesTests }

procedure TProjectExceptionRulesTests.Setup;
begin
  PurgeLeftoverTempDirs('ProjectExcRules_');
  FScratch     := MakeTestScratchDir('ProjectExcRules_');
  // The project file itself is never opened: only its directory and base name
  // decide where the sidecars live, which is what lets a .dproj name them just
  // as well as a .dpr or a .dpk.
  FProjectFile := TPath.Combine(FScratch, 'ScopedFixture.dpr');
end;

procedure TProjectExceptionRulesTests.TearDown;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect.Free;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
  DeleteTempDirWithRetry(FScratch);
end;

procedure TProjectExceptionRulesTests.WriteSharedSidecar(const FileText: string);
begin
  TFile.WriteAllText(ChangeFileExt(FProjectFile, '.ExceptionSettings.json'), FileText);
end;

procedure TProjectExceptionRulesTests.WriteLocalSidecar(const FileText: string);
begin
  TFile.WriteAllText(ChangeFileExt(FProjectFile, '.ExceptionSettings.local.json'), FileText);
end;

procedure TProjectExceptionRulesTests.StartAdapter;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized');
  // No `delphi` filter: a first-chance Delphi exception stops ONLY if a rule
  // says so, which is what makes "break" and "ignore" tell each other apart.
  FClient.SetExceptionBreakpoints(['unhandled']).Free;
end;

procedure TProjectExceptionRulesTests.LaunchExceptionTarget;
begin
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False,
    ['--run-exception-test']).Free;
  FClient.ConfigDone.Free;
end;

procedure TProjectExceptionRulesTests.LaunchExceptionTargetWithConfigRules(
  const RulesJson: string);
begin
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-exception-test'], RulesJson).Free;
  FClient.ConfigDone.Free;
end;

procedure TProjectExceptionRulesTests.LaunchExceptionTargetWithGlobalFile(
  const GlobalPath: string);
begin
  FClient.LaunchWithGlobalRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-exception-test'], GlobalPath).Free;
  FClient.ConfigDone.Free;
end;

procedure TProjectExceptionRulesTests.AssertStoppedOnExcTest(const Context: string);
var
  Stopped: TJSONObject;
begin
  Stopped := FClient.WaitForStopped(STOP_TIMEOUT_MS);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''), Context);
    Assert.IsTrue(Stopped.GetValue<string>('description', '').Contains(EXC_MESSAGE),
      Context + ' -- stopped on the wrong exception: '
      + Stopped.GetValue<string>('description', ''));
  finally
    Stopped.Free;
  end;
end;

procedure TProjectExceptionRulesTests.AssertRanToCompletion(const Context: string);
begin
  Assert.IsTrue(FClient.WaitForTerminated(RUN_TIMEOUT_MS), Context);
end;

procedure TProjectExceptionRulesTests.SharedSidecar_BreaksWhereTheFiltersWouldNot;
begin
  WriteSharedSidecar(RuleFile('break'));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTarget;
  AssertStoppedOnExcTest(
    'a rule in <Project>.ExceptionSettings.json must break where the filters would not');
end;

procedure TProjectExceptionRulesTests.WithoutDelphiProjectFile_TheSidecarsAreNotRead;
begin
  // Both sidecars are on disk and both say break. The configuration does not
  // name the project, so neither may be found: resolution has to be what it was
  // before the sidecars existed.
  WriteSharedSidecar(RuleFile('break'));
  WriteLocalSidecar(RuleFile('break'));
  StartAdapter;
  LaunchExceptionTarget;
  AssertRanToCompletion(
    'with no delphiProjectFile the sidecars must not be looked for, so nothing may break');
end;

procedure TProjectExceptionRulesTests.UnresolvedMacroInTheProjectPath_IsIgnored;
begin
  WriteSharedSidecar(RuleFile('break'));
  StartAdapter;
  FClient.DelphiProjectFile := '${workspaceFolder}/ScopedFixture.dpr';
  LaunchExceptionTarget;
  AssertRanToCompletion(
    'an unexpanded ${...} cannot name a project directory and must be ignored, not used literally');
end;

procedure TProjectExceptionRulesTests.LocalSidecar_IgnoresWhereTheSharedSidecarBreaks;
begin
  WriteSharedSidecar(RuleFile('break'));
  WriteLocalSidecar(RuleFile('ignore'));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTarget;
  AssertRanToCompletion('the local sidecar must win over the shared one');
end;

procedure TProjectExceptionRulesTests.LocalSidecar_BreaksWhereTheSharedSidecarIgnores;
begin
  WriteSharedSidecar(RuleFile('ignore'));
  WriteLocalSidecar(RuleFile('break'));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTarget;
  AssertStoppedOnExcTest('the local sidecar must win over the shared one in this direction too');
end;

procedure TProjectExceptionRulesTests.SharedSidecar_IgnoresWhereTheLaunchConfigurationBreaks;
begin
  WriteSharedSidecar(RuleFile('ignore'));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTargetWithConfigRules(
    Format('[{"message":"%s","action":"break"}]', [EXC_MESSAGE]));
  AssertRanToCompletion('the project sidecar must win over the launch configuration');
end;

procedure TProjectExceptionRulesTests.SharedSidecar_BreaksWhereTheLaunchConfigurationIgnores;
begin
  WriteSharedSidecar(RuleFile('break'));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTargetWithConfigRules(
    Format('[{"message":"%s","action":"ignore"}]', [EXC_MESSAGE]));
  AssertStoppedOnExcTest('the project sidecar must win over the launch configuration');
end;

procedure TProjectExceptionRulesTests.LaunchConfigurationStillDecidesWhatNoSidecarMatches;
begin
  // The sidecar names an exception this run never raises, so it matches nothing
  // and the launch configuration's own rule is what decides.
  WriteSharedSidecar('{ "exceptionRules": [ {"message": "some-other-exception", "action": "ignore"} ] }');
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTargetWithConfigRules(
    Format('[{"message":"%s","action":"break"}]', [EXC_MESSAGE]));
  AssertStoppedOnExcTest(
    'a non-matching sidecar rule must not shadow the launch configuration''s rules');
end;

procedure TProjectExceptionRulesTests.SharedSidecar_BreaksWhereTheMachineWideFileIgnores;
var
  GlobalFile: string;
begin
  GlobalFile := TPath.Combine(FScratch, 'machineWideRules.json');
  TFile.WriteAllText(GlobalFile, RuleFile('ignore'));
  WriteSharedSidecar(RuleFile('break'));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTargetWithGlobalFile(GlobalFile);
  AssertStoppedOnExcTest('the project sidecar must win over the machine-wide file');
end;

procedure TProjectExceptionRulesTests.SidecarAsBareArray_IsAccepted;
begin
  WriteSharedSidecar(Format('[ {"message": "%s", "action": "break"} ]', [EXC_MESSAGE]));
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTarget;
  AssertStoppedOnExcTest('a sidecar written as a bare array must be read like the object form');
end;

procedure TProjectExceptionRulesTests.MalformedSidecar_LeavesDebuggingWorking;
begin
  WriteSharedSidecar('{ this is not json at all');
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  LaunchExceptionTarget;
  AssertRanToCompletion(
    'a broken sidecar must cost the user their rules, not their debug session');
end;

procedure TProjectExceptionRulesTests.SharedSidecar_HotReloadsOnResume;
var
  Stopped: TJSONObject;
begin
  // `--run-reraise` raises twice. The sidecar breaks on the first raise; while
  // stopped it is rewritten to ignore, and the resume must apply that.
  WriteSharedSidecar('{ "exceptionRules": [ {"message": "reraise-orig", "action": "break"} ] }');
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False, ['--run-reraise']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(STOP_TIMEOUT_MS);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'the first raise should break on the sidecar rule');
  finally
    Stopped.Free;
  end;

  WriteSharedSidecar('{ "exceptionRules": [ {"message": "reraise-orig", "action": "ignore"} ] }');
  FClient.Continue_(1).Free;
  AssertRanToCompletion('a sidecar edited while stopped must take effect on resume');
end;

procedure TProjectExceptionRulesTests.SidecarCreatedMidSession_IsPickedUpOnResume;
var
  Stopped: TJSONObject;
begin
  // No sidecar at all when the session starts; the launch configuration breaks
  // on the first raise. The sidecar is then created and must win on resume.
  StartAdapter;
  FClient.DelphiProjectFile := FProjectFile;
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-reraise'], '[{"message":"reraise-orig","action":"break"}]').Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(STOP_TIMEOUT_MS);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'the first raise should break on the launch configuration rule');
  finally
    Stopped.Free;
  end;

  WriteSharedSidecar('{ "exceptionRules": [ {"message": "reraise-orig", "action": "ignore"} ] }');
  FClient.Continue_(1).Free;
  AssertRanToCompletion(
    'a sidecar that appears mid-session must be picked up, and must outrank the launch configuration');
end;

procedure TProjectExceptionRulesTests.Attach_HonoursTheSharedSidecar;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  // `--attach-raise-loop` keeps raising a caught exception, so the attach does
  // not have to win a race against a single raise at startup.
  WriteSharedSidecar('{ "exceptionRules": [ {"message": "attach-exc", "action": "break"} ] }');
  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  var CmdLine := '"' + TargetExe + '" --attach-raise-loop';
  Assert.IsTrue(CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI),
    'CreateProcess for the attach test failed: ' + IntToStr(GetLastError));
  CloseHandle(PI.hThread);
  try
    StartAdapter;
    FClient.DelphiProjectFile := FProjectFile;
    FClient.Attach(PI.dwProcessId, TargetExe, TargetMap, TargetRsm, TargetDir, True).Free;
    FClient.ConfigDone.Free;
    var Stopped := FClient.WaitForStopped(STOP_TIMEOUT_MS);
    try
      Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
        'the attach path must read the project sidecar too');
      Assert.IsTrue(Stopped.GetValue<string>('description', '').Contains('attach-exc'),
        'stopped on the wrong exception: ' + Stopped.GetValue<string>('description', ''));
    finally
      Stopped.Free;
    end;
  finally
    TerminateProcess(PI.hProcess, 0);
    CloseHandle(PI.hProcess);
  end;
end;

{ TPackageExceptionRulesTests }

// The sidecar for this fixture is written next to the REAL TestPackage.dpk,
// because "next to the project" is the whole claim being tested. It is removed
// again in TearDown and is gitignored, so a crashed run leaves nothing behind
// that could be committed.
function PackageDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage\';
end;

procedure TPackageExceptionRulesTests.Setup;
begin
  FSidecar := PackageDir + 'TestPackage.ExceptionSettings.json';
end;

procedure TPackageExceptionRulesTests.TearDown;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect.Free;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
  if TFile.Exists(FSidecar) then
    TFile.Delete(FSidecar);
end;

procedure TPackageExceptionRulesTests.PackageSidecar_AppliesInsideAHostThatKnowsNothingAboutIt;
var
  Stopped: TJSONObject;
begin
  // EPkgError is declared inside TestPackage.bpl. TestTarget.exe -- the host --
  // has never heard of it, names no rule about it, and is not the project the
  // configuration points at: the rule reaches the session purely because the
  // package's own sidecar sits next to TestPackage.dpk.
  TFile.WriteAllText(FSidecar,
    '{ "exceptionRules": [ {"class": "EPkgError", "action": "break"} ] }');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized');
  FClient.SetExceptionBreakpoints(['unhandled']).Free;   // nothing first-chance breaks by itself
  FClient.DelphiProjectFile := PackageDir + 'TestPackage.dpk';
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False,
    ['--load-package', '--pkg-raise'],
    [['TestPackage.bpl',
      PackageDir + 'Win64\Debug\TestPackage.map',
      PackageDir + 'Win64\Debug\TestPackage.rsm',
      PackageDir + 'Win64\Debug\TestPackage.dcp']]).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(STOP_TIMEOUT_MS);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'the package''s own sidecar must decide, whichever host loaded the package');
    Assert.IsTrue(Stopped.GetValue<string>('description', '').Contains('EPkgError'),
      'stopped on the wrong exception: ' + Stopped.GetValue<string>('description', ''));
  finally
    Stopped.Free;
  end;
end;

// A rules file the adapter cannot parse is IGNORED, deliberately -- a broken
// file must not stop anyone debugging. That makes a broken one invisible, so the
// sample committed in this repository, which is what a reader copies, is checked
// here rather than left to be discovered as "the rule does nothing".
procedure TPackageExceptionRulesTests.TheDebugmeSampleSidecar_IsAFileTheAdapterCanActuallyRead;
begin
  const SampleProject = 'Debugme.dpr';
  if not TFile.Exists(RepoRoot + SampleProject) then
    Assert.Pass('SKIP: ' + SampleProject + ' is not present in this clone');

  const Sidecar = RepoRoot + 'Debugme.ExceptionSettings.json';
  Assert.IsTrue(TFile.Exists(Sidecar),
    SampleProject + ' has no ' + ExtractFileName(Sidecar) + ' beside it');

  var Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Sidecar, TEncoding.UTF8));
  Assert.IsNotNull(Root, ExtractFileName(Sidecar) +
    ' is not strict JSON -- these files are not JSONC, so a comment or a trailing comma makes them do nothing');
  try
    var Rules: TJSONArray := nil;
    if Root is TJSONArray then
      Rules := TJSONArray(Root)
    else if Root is TJSONObject then
      Rules := TJSONObject(Root).FindValue('exceptionRules') as TJSONArray;
    Assert.IsNotNull(Rules, ExtractFileName(Sidecar) +
      ' must be a bare array or an object with an "exceptionRules" array');
    Assert.IsTrue(Rules.Count > 0, ExtractFileName(Sidecar) + ' declares no rules at all');
    for var Item in Rules do begin
      var Action := (Item as TJSONObject).GetValue<string>('action', '');
      Assert.IsTrue(MatchStr(Action, ['ignore', 'log', 'logStack', 'break']),
        'rule with an action the engine does not know: "' + Action + '"');
    end;
  finally
    Root.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TProjectExceptionRulesTests);
  TDUnitX.RegisterTestFixture(TPackageExceptionRulesTests);

end.
