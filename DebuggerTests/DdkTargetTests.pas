unit DdkTargetTests;

// The delphi-devkit (DDK) debug target as the MCP server consumes it
// (MCPDebugger\DdkTarget.pas): parsing the `debug-target --json` reply, mapping
// it onto TLaunchOptions / TAttachOptions, the argument joining, locating
// ddk.exe, and running a stand-in ddk (a .cmd that prints a fixture) through
// the real process plumbing. The fixture is the reply shape DDK documents, for
// a program and for a package with a Host Application - the same cases the
// extension's JS tests cover, so the two consumers cannot drift apart.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TDdkTargetTests = class
  private
    function ScratchDir: string;
    function StubDdk(const Body: string): string;
  public
    [Test] procedure Parse_Program_ReadsEveryFieldAndNativePaths;
    [Test] procedure Parse_Package_HostApplicationAndModules;
    [Test] procedure Parse_NotJson_Refused;
    [Test] procedure Launch_Program_MapsExecutableSymbolsSourcesArgs;
    [Test] procedure Launch_Package_LaunchesHostAndPrebindsBuiltModulesOnly;
    [Test] procedure Launch_MissingSymbols_DefaultNextToExecutable;
    [Test] procedure Launch_NullBitness_RefusedWithWarningText;
    [Test] procedure Launch_NoExecutable_Refused;
    [Test] procedure Attach_ProcessNameIsExecutableBasename;
    [Test] procedure JoinArgs_QuotesWhatNeedsQuoting;
    [Test] procedure Locate_OverrideThenEnvThenPath;
    [Test] procedure Run_StubDdk_ReturnsItsStdout;
    [Test] procedure Run_StubDdkFailing_ReturnsItsStderrVerbatim;
    [Test] procedure Fetch_NoDdkAnywhere_NamesWhatToInstall;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Classes, Winapi.Windows,
  DdkTarget, DebugSessionTypes;

const
  PROGRAM_TARGET =
    '{' +
    '  "project_id": 869, "project": "CVSTreeGraph",' +
    '  "project_file": "c:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/CVSTreeGraph.dproj",' +
    '  "main_source": "C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/CVSTreeGraph.dpr",' +
    '  "kind": "program",' +
    '  "executable": "C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/Win64/Debug/CVSTreeGraph.exe",' +
    '  "host_application": null,' +
    '  "compiler": "Delphi 12.0 Athens", "config": "Debug", "platform": "Win64", "bitness": 64,' +
    '  "symbols": {' +
    '    "map": "C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/Win64/Debug/CVSTreeGraph.map",' +
    '    "rsm": "C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/Win64/Debug/CVSTreeGraph.rsm"' +
    '  },' +
    '  "source_root": "c:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources",' +
    '  "source_search_paths": [' +
    '    "c:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources",' +
    '    "C:/Program Files (x86)/Embarcadero/Studio/23.0/source/rtl/common"' +
    '  ],' +
    '  "modules": [],' +
    '  "args": ["-verbose", "C:/data/input file.txt"],' +
    '  "warnings": []' +
    '}';

  PACKAGE_TARGET =
    '{' +
    '  "project_id": 596, "project": "libAboutD29",' +
    '  "project_file": "c:/Athens/hydra_2/About/libAboutD29.dproj",' +
    '  "main_source": "C:/Athens/hydra_2/About/libAboutD29.dpk",' +
    '  "kind": "package",' +
    '  "executable": "c:/Athens/hydra_2/Win64/Debug/Hydra2.exe",' +
    '  "host_application": "c:/Athens/hydra_2/Win64/Debug/Hydra2.exe",' +
    '  "compiler": "Delphi 12.0 Athens", "config": "Debug", "platform": "Win64", "bitness": 64,' +
    '  "symbols": { "map": "c:/Athens/hydra_2/Win64/Debug/Hydra2.map", "rsm": "c:/Athens/hydra_2/Win64/Debug/Hydra2.rsm" },' +
    '  "source_root": "c:/Athens/hydra_2/About",' +
    '  "source_search_paths": ["c:/Athens/hydra_2/About"],' +
    '  "modules": [' +
    '    { "name": "libAboutD29.bpl",' +
    '      "binary": "C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.bpl",' +
    '      "map": "C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.map",' +
    '      "rsm": "C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.rsm",' +
    '      "dcp": "C:/Users/Public/Documents/Embarcadero/Studio/23.0/Dcp/Win64/libAboutD29.dcp" },' +
    '    { "name": "libNotBuilt.bpl", "binary": null, "map": null, "rsm": null, "dcp": null },' +
    '    { "name": "libNoSidecars.bpl",' +
    '      "binary": "C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libNoSidecars.bpl",' +
    '      "map": null, "rsm": null, "dcp": null }' +
    '  ],' +
    '  "args": [],' +
    '  "warnings": ["libNotBuilt.bpl was not found; build the package first."]' +
    '}';

function TDdkTargetTests.ScratchDir: string;
begin
  // Pid-scoped: several RunTests workers run at once.
  Result := TPath.Combine(TPath.GetTempPath, Format('ddk_target_tests_%d', [GetCurrentProcessId]));
  TDirectory.CreateDirectory(Result);
end;

function TDdkTargetTests.StubDdk(const Body: string): string;
begin
  Result := TPath.Combine(ScratchDir, 'ddk.cmd');
  TFile.WriteAllText(Result, '@echo off' + sLineBreak + Body + sLineBreak);
end;

procedure TDdkTargetTests.Parse_Program_ReadsEveryFieldAndNativePaths;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(PROGRAM_TARGET, T, Err), Err);
  Assert.AreEqual(869, T.ProjectId);
  Assert.AreEqual('CVSTreeGraph', T.Project);
  Assert.AreEqual('program', T.Kind);
  Assert.AreEqual('c:\Athens\GitHub\CVSTreeGraph\CVSTreeGraphSources\CVSTreeGraph.dproj', T.ProjectFile,
    'forward slashes become native separators');
  Assert.AreEqual('C:\Athens\GitHub\CVSTreeGraph\CVSTreeGraphSources\Win64\Debug\CVSTreeGraph.exe', T.Executable);
  Assert.AreEqual('', T.HostApplication, 'null reads as empty');
  Assert.AreEqual(64, T.Bitness);
  Assert.AreEqual('C:\Athens\GitHub\CVSTreeGraph\CVSTreeGraphSources\Win64\Debug\CVSTreeGraph.map', T.MapPath);
  Assert.AreEqual('C:\Athens\GitHub\CVSTreeGraph\CVSTreeGraphSources\Win64\Debug\CVSTreeGraph.rsm', T.RsmPath);
  Assert.AreEqual('c:\Athens\GitHub\CVSTreeGraph\CVSTreeGraphSources', T.SourceRoot);
  Assert.AreEqual(2, Integer(Length(T.SourceSearchPaths)));
  Assert.AreEqual('C:\Program Files (x86)\Embarcadero\Studio\23.0\source\rtl\common', T.SourceSearchPaths[1]);
  Assert.AreEqual(0, Integer(Length(T.Modules)));
  Assert.AreEqual(2, Integer(Length(T.Args)));
  Assert.AreEqual('C:/data/input file.txt', T.Args[1], 'arguments are not paths and stay as written');
  Assert.AreEqual(0, Integer(Length(T.Warnings)));
end;

procedure TDdkTargetTests.Parse_Package_HostApplicationAndModules;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(PACKAGE_TARGET, T, Err), Err);
  Assert.AreEqual('package', T.Kind);
  Assert.AreEqual('c:\Athens\hydra_2\Win64\Debug\Hydra2.exe', T.Executable, 'the host application is the executable');
  Assert.AreEqual(T.Executable, T.HostApplication);
  Assert.AreEqual(3, Integer(Length(T.Modules)), 'every module is parsed; the mapping decides what to drop');
  Assert.AreEqual('libAboutD29.bpl', T.Modules[0].Name);
  Assert.AreEqual('C:\Users\Public\Documents\Embarcadero\Studio\23.0\Dcp\Win64\libAboutD29.dcp', T.Modules[0].DcpPath);
  Assert.AreEqual('', T.Modules[1].Binary);
  Assert.AreEqual(1, Integer(Length(T.Warnings)));
end;

procedure TDdkTargetTests.Parse_NotJson_Refused;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsFalse(ParseDebugTarget('Error: No project matches "x".', T, Err));
  Assert.Contains(Err, 'not a debug target');
  Assert.IsFalse(ParseDebugTarget('{"projects": []}', T, Err));
  Assert.Contains(Err, '"executable"');
end;

procedure TDdkTargetTests.Launch_Program_MapsExecutableSymbolsSourcesArgs;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(PROGRAM_TARGET, T, Err), Err);
  var Opts: TLaunchOptions;
  Assert.IsTrue(LaunchOptionsFromTarget(T, Opts, Err), Err);
  Assert.AreEqual(T.Executable, Opts.ExePath);
  Assert.AreEqual(T.MapPath, Opts.MapPath);
  Assert.AreEqual(T.RsmPath, Opts.RsmPath);
  Assert.AreEqual(T.SourceRoot, Opts.SourceRoot);
  Assert.AreEqual(2, Integer(Length(Opts.ExtraSourcePaths)));
  Assert.AreEqual('-verbose "C:/data/input file.txt"', Opts.Args, 'the argument with a space is quoted');
  Assert.AreEqual(0, Integer(Length(Opts.Modules)));
  Assert.IsFalse(Opts.StopAtEntry, 'the caller decides that, as launch_from_config does');
end;

procedure TDdkTargetTests.Launch_Package_LaunchesHostAndPrebindsBuiltModulesOnly;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(PACKAGE_TARGET, T, Err), Err);
  var Opts: TLaunchOptions;
  Assert.IsTrue(LaunchOptionsFromTarget(T, Opts, Err), Err);
  Assert.AreEqual('c:\Athens\hydra_2\Win64\Debug\Hydra2.exe', Opts.ExePath);
  Assert.AreEqual('c:\Athens\hydra_2\Win64\Debug\Hydra2.map', Opts.MapPath);
  Assert.AreEqual('', Opts.Args, 'an empty argument list is an empty command-line tail');
  Assert.AreEqual(2, Integer(Length(Opts.Modules)), 'the module without a binary is dropped');
  Assert.AreEqual('libAboutD29.bpl', Opts.Modules[0].Name);
  Assert.AreEqual('C:\Users\Public\Documents\Embarcadero\Studio\23.0\Bpl\Win64\libAboutD29.rsm', Opts.Modules[0].RsmPath);
  Assert.AreEqual('C:\Users\Public\Documents\Embarcadero\Studio\23.0\Dcp\Win64\libAboutD29.dcp', Opts.Modules[0].DcpPath);
  Assert.AreEqual('libNoSidecars.bpl', Opts.Modules[1].Name);
  Assert.AreEqual('', Opts.Modules[1].MapPath, 'null sidecars stay empty, so the session probes next to the module');
end;

procedure TDdkTargetTests.Launch_MissingSymbols_DefaultNextToExecutable;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(
    '{"project":"P","executable":"C:/b/App.exe","bitness":32,"symbols":{"map":null,"rsm":null}}', T, Err), Err);
  var Opts: TLaunchOptions;
  Assert.IsTrue(LaunchOptionsFromTarget(T, Opts, Err), Err);
  Assert.AreEqual('C:\b\App.map', Opts.MapPath);
  Assert.AreEqual('C:\b\App.rsm', Opts.RsmPath);
end;

procedure TDdkTargetTests.Launch_NullBitness_RefusedWithWarningText;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(
    '{"project":"P","executable":"/home/me/app","platform":"Linux64","bitness":null,' +
    '"warnings":["Platform \"Linux64\" is not a Windows platform; this project cannot be debugged here."]}', T, Err), Err);
  var Opts: TLaunchOptions;
  Assert.IsFalse(LaunchOptionsFromTarget(T, Opts, Err));
  Assert.AreEqual('Platform "Linux64" is not a Windows platform; this project cannot be debugged here.', Err);
  // Without a warning to quote, the refusal still names the platform.
  T.Warnings := nil;
  Assert.IsFalse(LaunchOptionsFromTarget(T, Opts, Err));
  Assert.Contains(Err, 'Linux64');
end;

procedure TDdkTargetTests.Launch_NoExecutable_Refused;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(
    '{"project":"P","executable":null,"bitness":64,"warnings":["P.exe was not found; compile first."]}', T, Err), Err);
  var Opts: TLaunchOptions;
  Assert.IsFalse(LaunchOptionsFromTarget(T, Opts, Err));
  Assert.Contains(Err, 'no executable');
  Assert.Contains(Err, 'compile first');
end;

procedure TDdkTargetTests.Attach_ProcessNameIsExecutableBasename;
begin
  var T: TDdkDebugTarget;
  var Err: string;
  Assert.IsTrue(ParseDebugTarget(PACKAGE_TARGET, T, Err), Err);
  var Opts: TAttachOptions;
  var PName: string;
  Assert.IsTrue(AttachOptionsFromTarget(T, Opts, PName, Err), Err);
  Assert.AreEqual('Hydra2.exe', PName);
  Assert.AreEqual('c:\Athens\hydra_2\Win64\Debug\Hydra2.exe', Opts.ProgramPath);
  Assert.AreEqual('c:\Athens\hydra_2\Win64\Debug\Hydra2.rsm', Opts.RsmPath);
  Assert.AreEqual('c:\Athens\hydra_2\About', Opts.SourceRoot);
  Assert.AreEqual(2, Integer(Length(Opts.Modules)));
end;

procedure TDdkTargetTests.JoinArgs_QuotesWhatNeedsQuoting;
begin
  Assert.AreEqual('', JoinCommandLineArgs(nil));
  Assert.AreEqual('u=dev p=dev', JoinCommandLineArgs(['u=dev', 'p=dev']));
  Assert.AreEqual('"C:\a b\x.txt" -q ""', JoinCommandLineArgs(['C:\a b\x.txt', '-q', '']));
  Assert.AreEqual('"say \"hi\""', JoinCommandLineArgs(['say "hi"']));
end;

procedure TDdkTargetTests.Locate_OverrideThenEnvThenPath;
begin
  var Dir := ScratchDir;
  var OverrideExe := TPath.Combine(Dir, 'override-ddk.exe');
  var EnvExe := TPath.Combine(Dir, 'env-ddk.exe');
  TFile.WriteAllText(OverrideExe, 'x');
  TFile.WriteAllText(EnvExe, 'x');
  var SavedEnv := GetEnvironmentVariable('DDK_EXE');
  try
    SetEnvironmentVariable('DDK_EXE', PChar(EnvExe));
    Assert.AreEqual(OverrideExe, LocateDdkExe(OverrideExe), 'the switch wins');
    Assert.AreEqual(EnvExe, LocateDdkExe(''), 'then the environment variable');
    Assert.AreEqual(EnvExe, LocateDdkExe(TPath.Combine(Dir, 'missing.exe')),
      'an override that does not exist does not win');
    SetEnvironmentVariable('DDK_EXE', nil);
    // Whatever PATH / the packaged extension yield is a real ddk.exe or nothing;
    // either way it is not one of the scratch files.
    var Found := LocateDdkExe('');
    Assert.IsTrue((Found = '') or TFile.Exists(Found), 'a located ddk.exe exists: ' + Found);
    Assert.AreNotEqual(EnvExe, Found);
  finally
    if SavedEnv = '' then
      SetEnvironmentVariable('DDK_EXE', nil)
    else
      SetEnvironmentVariable('DDK_EXE', PChar(SavedEnv));
    TFile.Delete(OverrideExe);
    TFile.Delete(EnvExe);
  end;
end;

procedure TDdkTargetTests.Run_StubDdk_ReturnsItsStdout;
begin
  var Fixture := TPath.Combine(ScratchDir, 'target.json');
  TFile.WriteAllText(Fixture, PROGRAM_TARGET);
  // The stub echoes its arguments to stderr (so the command line is verifiable)
  // and the fixture to stdout, exactly the way ddk.exe answers.
  var Stub := StubDdk('echo %* 1>&2' + sLineBreak + 'type "' + Fixture + '"');
  var Json, Err: string;
  Assert.IsTrue(RunDdkDebugTarget(Stub, 'CVSTreeGraph', '', Json, Err), Err);
  var T: TDdkDebugTarget;
  Assert.IsTrue(ParseDebugTarget(Json, T, Err), Err);
  Assert.AreEqual('CVSTreeGraph', T.Project);

  // The whole step, through the override.
  Assert.IsTrue(FetchDebugTarget(Stub, 'CVSTreeGraph', 'Delphi 12', T, Err), Err);
  Assert.AreEqual(869, T.ProjectId);
end;

procedure TDdkTargetTests.Run_StubDdkFailing_ReturnsItsStderrVerbatim;
begin
  var Stub := StubDdk('echo Error: No project matches "%~2". Use `list` to see available projects. 1>&2' + sLineBreak + 'exit /b 1');
  var Json, Err: string;
  Assert.IsFalse(RunDdkDebugTarget(Stub, 'Nope', '', Json, Err));
  Assert.AreEqual('Error: No project matches "Nope". Use `list` to see available projects.', Err);
end;

procedure TDdkTargetTests.Fetch_NoDdkAnywhere_NamesWhatToInstall;
begin
  var SavedEnv := GetEnvironmentVariable('DDK_EXE');
  var SavedPath := GetEnvironmentVariable('PATH');
  var SavedProfile := GetEnvironmentVariable('USERPROFILE');
  try
    SetEnvironmentVariable('DDK_EXE', nil);
    SetEnvironmentVariable('PATH', PChar(ScratchDir));
    SetEnvironmentVariable('USERPROFILE', PChar(ScratchDir));
    var T: TDdkDebugTarget;
    var Err: string;
    Assert.IsFalse(FetchDebugTarget('', 'Anything', '', T, Err));
    Assert.AreEqual(DDK_NOT_FOUND_MESSAGE, Err);
    Assert.Contains(Err, 'Snowcaloid.delphi-devkit');
    Assert.Contains(Err, '--ddk-exe');
  finally
    if SavedEnv = '' then
      SetEnvironmentVariable('DDK_EXE', nil)
    else
      SetEnvironmentVariable('DDK_EXE', PChar(SavedEnv));
    SetEnvironmentVariable('PATH', PChar(SavedPath));
    SetEnvironmentVariable('USERPROFILE', PChar(SavedProfile));
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDdkTargetTests);

end.
