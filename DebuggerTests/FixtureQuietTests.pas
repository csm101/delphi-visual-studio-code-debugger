unit FixtureQuietTests;

// A fixture never opens a dialog and never takes the focus (CLAUDE.md, "A test
// never opens a dialog and never takes the focus"; docs/TRAPS.md, "Fixture
// design"). The suite runs on the machine somebody is working on, and fixtures
// crash on purpose. Two guards:
//
//   * STATIC. Every program under DebuggerTests\TestTarget\, DebuggerTests\
//     TestHost\ and DevTools\Fixtures\ uses the quiet unit, and the right one:
//     FixtureQuiet when it links System.SysUtils, FixtureQuietNoSysUtils when it
//     does not -- FixtureQuiet would link System.SysUtils into a binary that
//     exists to be without it.
//   * DYNAMIC. The QuietFail* fixtures fail on purpose WITHOUT a debugger -- an
//     unhandled exception, a run-time error, a fault with no handler -- as GUI
//     and console programs, with and without System.SysUtils, on both
//     bitnesses. Each run must end by itself, with the RTL's own exit code,
//     having written the failure. A process still alive at the timeout is the
//     failure: a dialog is waiting for a click.
//
// The dynamic runs start each fixture with CREATE_DEFAULT_ERROR_MODE, so the
// error mode this runner sets for its children (RunTests.dpr) cannot stand in
// for the fixture's own, and on a desktop of their own, so that a regression
// shows its box THERE -- the test reads the box's text into its message -- and
// not on the screen of whoever is working at the machine.
//
// Tests that run several binaries COLLECT their failures: the executables of
// both bitnesses carry the same name, and a first-failure abort would hide the
// other one (docs/TRAPS.md).

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  [TestFixture]
  TFixtureQuietTests = class
  private
    FProblems: TList<string>;
    procedure Check(Condition: Boolean; const Problem: string);
    procedure AssertNoProblems;
    procedure CheckFixtureProgram(const Path, Shown, Code: string);
    procedure CheckQuietFailFixture(const Name: string; LinksSysUtils: Boolean);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // Every fixture program uses FixtureQuiet or FixtureQuietNoSysUtils, the one
    // that matches whether it links System.SysUtils. Libraries and packages are
    // exempt: they cannot carry it, their host program does.
    [Test] procedure EveryFixtureProgram_UsesTheRightQuietUnit;

    // QuietFailGui / QuietFailConsole (FixtureQuiet), Win32 and Win64.
    [Test] procedure GuiFixture_FailsInWriting_NeverInADialog;
    [Test] procedure ConsoleFixture_FailsInWriting_NeverInADialog;
    // QuietFailNoSysUtilsGui / ...Console (FixtureQuietNoSysUtils), Win32 and Win64.
    [Test] procedure GuiFixtureWithoutSysUtils_FailsInWriting_NeverInADialog;
    [Test] procedure ConsoleFixtureWithoutSysUtils_FailsInWriting_NeverInADialog;
  end;

implementation

uses
  System.IOUtils, System.RegularExpressions, System.Types, Winapi.Windows;

const
  QUIET_UNIT              = 'FixtureQuiet';
  QUIET_UNIT_NO_SYSUTILS  = 'FixtureQuietNoSysUtils';

  // Where fixture programs live, relative to the repository root.
  FIXTURE_ROOTS: array[0..2] of string = (
    'DebuggerTests\TestTarget', 'DebuggerTests\TestHost', 'DevTools\Fixtures');

  // RTL units known NOT to link System.SysUtils. Any other unit that is not a
  // source file of the fixture is assumed to link it: wrongly assuming so only
  // asks for FixtureQuiet, which a program linking any such unit can take.
  SYSUTILS_FREE_RTL_UNITS: array[0..5] of string = (
    'Winapi.Windows', 'Windows', 'Winapi.Messages', 'Messages', 'System.Types', 'Types');

  // What QuietFailCore.pas does, mirrored here because the test cannot use a
  // fixture unit.
  QUIET_FAIL_RUNTIME_ERROR = 204;
  QUIET_FAIL_MESSAGE       = 'quiet-fail-raise';

  // A quiet failure ends in milliseconds; a box waits for ever.
  QUIET_EXIT_TIMEOUT_MS = 5000;
  // RTL exit codes: an unhandled exception after System.SysUtils' handler (and
  // FixtureQuiet's), an unhandled exception without any ExceptProc of the RTL's.
  EXIT_UNHANDLED_EXCEPTION     = 1;
  EXIT_RUNTIME_ERROR_UNHANDLED = 217;
  STATUS_ACCESS_VIOLATION_CODE = DWORD($C0000005);

  PROC_THREAD_ATTRIBUTE_HANDLE_LIST = $00020002;

type
  // STARTUPINFOEXW: Winapi.Windows declares the attribute-list functions but not
  // the record they go in.
  TStartupInfoExW = record
    StartupInfo:     TStartupInfo;
    lpAttributeList: PProcThreadAttributeList;
  end;

  TQuietRun = record
    Started:       Boolean;
    StartError:    string;
    EndedByItself: Boolean;
    ExitCode:      DWORD;
    StdOut:        string;
    StdErr:        string;
    // What was on the private desktop when the process had to be killed.
    Windows:       string;
  end;

  TScenario = record
    Argument:    string;
    ExitCode:    DWORD;
    StdErrMust:  TArray<string>;
    StdOutMust:  TArray<string>;
  end;

  PWindowScan = ^TWindowScan;
  TWindowScan = record
    ProcessId: DWORD;
    Found:     TStringList;
  end;

function RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

{ ---------------------------------------------------------------- static -- }

// Source text with every comment replaced by a blank. String literals stay:
// they hold the `in` paths.
function WithoutComments(const Source: string): string;
begin
  var Output := TStringBuilder.Create(Length(Source));
  try
    var I := 1;
    while I <= Length(Source) do begin
      var C := Source[I];
      if C = '''' then begin
        var Close := I + 1;
        while (Close <= Length(Source)) and (Source[Close] <> '''') do
          Inc(Close);
        Output.Append(Copy(Source, I, Close - I + 1));
        I := Close + 1;
      end else if C = '{' then begin
        var Close := Pos('}', Source, I + 1);
        if Close = 0 then
          Break;
        Output.Append(' ');
        I := Close + 1;
      end else if (C = '(') and (I < Length(Source)) and (Source[I + 1] = '*') then begin
        var Close := Pos('*)', Source, I + 2);
        if Close = 0 then
          Break;
        Output.Append(' ');
        I := Close + 2;
      end else if (C = '/') and (I < Length(Source)) and (Source[I + 1] = '/') then begin
        while (I <= Length(Source)) and not CharInSet(Source[I], [#10, #13]) do
          Inc(I);
      end else begin
        Output.Append(C);
        Inc(I);
      end;
    end;
    Result := Output.ToString;
  finally
    Output.Free;
  end;
end;

type
  TUsedUnit = record
    Name:   string;
    InPath: string;
  end;

// Every unit named by every `uses` clause of the source (comments removed). A
// clause is recognised only where one can stand -- after the `;` of the header,
// or after `interface` / `implementation` -- so a string that happens to contain
// the word does not count.
function UsedUnits(const Code: string): TArray<TUsedUnit>;
const
  USES_CLAUSE = '(?:^|;|\binterface\b|\bimplementation\b)\s*uses\b(.*?);';
  USES_ENTRY  = '^\s*([A-Za-z_][\w.]*)\s*(?:in\s*''([^'']*)'')?\s*$';
begin
  Result := [];
  for var Clause in TRegEx.Matches(Code, USES_CLAUSE, [roIgnoreCase, roSingleLine]) do
    for var Entry in Clause.Groups[1].Value.Split([',']) do begin
      var Parsed := TRegEx.Match(Entry, USES_ENTRY, [roIgnoreCase]);
      if not Parsed.Success then
        Continue;
      var Used := Default(TUsedUnit);
      Used.Name := Parsed.Groups[1].Value;
      if (Parsed.Groups.Count > 2) and Parsed.Groups[2].Success then
        Used.InPath := Parsed.Groups[2].Value;
      Result := Result + [Used];
    end;
end;

function ProgramKind(const Code: string): string;
begin
  // A byte-order mark the reader left in place must not hide the header.
  var Header := TRegEx.Match(Code.TrimLeft([#$FEFF]), '^\s*(program|library|package|unit)\b', [roIgnoreCase]);
  if not Header.Success then
    Exit('');
  Result := LowerCase(Header.Groups[1].Value);
end;

function IsQuietUnit(const Name: string): Boolean;
begin
  Result := SameText(Name, QUIET_UNIT) or SameText(Name, QUIET_UNIT_NO_SYSUTILS);
end;

function IsSysUtilsFreeRtlUnit(const Name: string): Boolean;
begin
  for var Known in SYSUTILS_FREE_RTL_UNITS do
    if SameText(Name, Known) then
      Exit(True);
  Result := False;
end;

// The source file of a unit the fixture compiles itself, or '' for an RTL or
// library unit.
function LocalSourceOf(const Used: TUsedUnit; const SearchDirs: TArray<string>): string;
begin
  if Used.InPath <> '' then
    Exit(ExpandFileName(TPath.Combine(SearchDirs[0], Used.InPath)));
  for var Dir in SearchDirs do begin
    var Candidate := TPath.Combine(Dir, Used.Name + '.pas');
    if TFile.Exists(Candidate) then
      Exit(Candidate);
  end;
  Result := '';
end;

// Whether linking these units links System.SysUtils, following the fixture's
// own source files. The quiet units are left out: FixtureQuiet links it by
// construction, and the question is what the program needs.
function LinksSysUtils(const Units: TArray<TUsedUnit>; const SearchDirs: TArray<string>;
  Visited: TStrings): Boolean;
begin
  for var Used in Units do begin
    if IsQuietUnit(Used.Name) then
      Continue;
    if SameText(Used.Name, 'System.SysUtils') or SameText(Used.Name, 'SysUtils') then
      Exit(True);
    var Source := LocalSourceOf(Used, SearchDirs);
    if Source = '' then begin
      if not IsSysUtilsFreeRtlUnit(Used.Name) then
        Exit(True);
      Continue;
    end;
    if Visited.IndexOf(Source) >= 0 then
      Continue;
    Visited.Add(Source);
    if not TFile.Exists(Source) then
      Continue;
    var UnitDirs := [ExtractFileDir(Source)] + SearchDirs;
    if LinksSysUtils(UsedUnits(WithoutComments(TFile.ReadAllText(Source))), UnitDirs, Visited) then
      Exit(True);
  end;
  Result := False;
end;

function UsesUnit(const Units: TArray<TUsedUnit>; const Name: string): Boolean;
begin
  for var Used in Units do
    if SameText(Used.Name, Name) then
      Exit(True);
  Result := False;
end;

{ --------------------------------------------------------------- dynamic -- }

function CollectChildText(Wnd: HWND; Param: LPARAM): BOOL; stdcall;
begin
  var Text: array[0..1023] of Char;
  if GetWindowText(Wnd, Text, Length(Text)) > 0 then
    PWindowScan(Param)^.Found.Add('    "' + string(Text).Replace(#13, ' ').Replace(#10, ' ').Trim + '"');
  Result := True;
end;

function CollectDesktopWindow(Wnd: HWND; Param: LPARAM): BOOL; stdcall;
begin
  Result := True;
  if not IsWindowVisible(Wnd) then
    Exit;
  var Scan := PWindowScan(Param);
  var Owner: DWORD := 0;
  GetWindowThreadProcessId(Wnd, Owner);
  var ClassName: array[0..255] of Char;
  var Title: array[0..1023] of Char;
  GetClassName(Wnd, ClassName, Length(ClassName));
  GetWindowText(Wnd, Title, Length(Title));
  var Whose := 'another process';
  if Owner = Scan^.ProcessId then
    Whose := 'the fixture';
  Scan^.Found.Add(Format('  window of %s (pid %d), class %s, title "%s"', [Whose, Owner, string(ClassName), string(Title)]));
  EnumChildWindows(Wnd, @CollectChildText, Param);
end;

function VisibleWindowsOn(Desktop: HDESK; ProcessId: DWORD): string;
begin
  var Scan := Default(TWindowScan);
  Scan.ProcessId := ProcessId;
  Scan.Found := TStringList.Create;
  try
    if Desktop <> 0 then
      EnumDesktopWindows(Desktop, @CollectDesktopWindow, LPARAM(@Scan));
    Result := Scan.Found.Text.Trim;
  finally
    Scan.Found.Free;
  end;
end;

// Appends what the pipe holds now, without blocking.
procedure DrainPipe(Pipe: THandle; var Bytes: TBytes);
begin
  var Available: DWORD := 0;
  while PeekNamedPipe(Pipe, nil, 0, nil, @Available, nil) and (Available > 0) do begin
    var Chunk: TBytes;
    SetLength(Chunk, Available);
    var Got: DWORD := 0;
    if not ReadFile(Pipe, Chunk[0], Available, Got, nil) then
      Exit;
    Bytes := Bytes + Copy(Chunk, 0, Got);
  end;
end;

// CreateProcess with stdout and stderr on the given pipes, inheriting those two
// handles and nothing else of this runner.
function StartWithOwnStdHandles(const CommandLine, Desktop: string; StdOut, StdErr: THandle;
  out Info: TProcessInformation): Boolean;
begin
  var ListSize: NativeUInt := 0;
  // Sizing call: fails by design and reports the size the list needs.
  InitializeProcThreadAttributeList(nil, 1, 0, ListSize);
  var ListBuffer: TBytes;
  SetLength(ListBuffer, ListSize);
  var List := PProcThreadAttributeList(@ListBuffer[0]);
  if not InitializeProcThreadAttributeList(List, 1, 0, ListSize) then
    Exit(False);
  try
    var InheritedHandles: array[0..1] of THandle;
    InheritedHandles[0] := StdOut;
    InheritedHandles[1] := StdErr;
    // lpReturnSize is reserved and must be NULL; the RTL declares it as a var parameter.
    if not UpdateProcThreadAttribute(List, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
         @InheritedHandles[0], SizeOf(InheritedHandles), nil, PNativeUInt(nil)^) then
      Exit(False);
    var StartupEx := Default(TStartupInfoExW);
    StartupEx.StartupInfo.cb         := SizeOf(StartupEx);
    StartupEx.StartupInfo.dwFlags    := STARTF_USESTDHANDLES;
    StartupEx.StartupInfo.hStdOutput := StdOut;
    StartupEx.StartupInfo.hStdError  := StdErr;
    if Desktop <> '' then
      StartupEx.StartupInfo.lpDesktop := PChar(Desktop);
    StartupEx.lpAttributeList := List;
    var Writable := CommandLine;
    UniqueString(Writable);
    // CREATE_DEFAULT_ERROR_MODE: the fixture must be quiet on its own, not
    // because this runner's error mode was handed down to it.
    Result := CreateProcess(nil, PChar(Writable), nil, nil, True,
      CREATE_DEFAULT_ERROR_MODE or CREATE_NO_WINDOW or EXTENDED_STARTUPINFO_PRESENT,
      nil, nil, StartupEx.StartupInfo, Info);
  finally
    DeleteProcThreadAttributeList(List);
  end;
end;

var
  GDesktopCounter: Integer = 0;

// Runs the program WITHOUT a debugger on a desktop of its own and waits for it
// to end by itself. One still running at the timeout has its windows read and
// is killed.
function RunWithoutDebugger(const Exe, Argument: string): TQuietRun;
begin
  Result := Default(TQuietRun);
  var DesktopName := Format('FixtureQuietTests-%d-%d', [GetCurrentProcessId, AtomicIncrement(GDesktopCounter)]);
  var Desktop := CreateDesktop(PChar(DesktopName), nil, nil, 0, GENERIC_ALL, nil);
  var DesktopPath := '';
  if Desktop <> 0 then
    DesktopPath := 'WinSta0\' + DesktopName;
  var Inheritable := Default(TSecurityAttributes);
  Inheritable.nLength := SizeOf(Inheritable);
  Inheritable.bInheritHandle := True;
  var OutRead, OutWrite, ErrRead, ErrWrite: THandle;
  CreatePipe(OutRead, OutWrite, @Inheritable, 65536);
  CreatePipe(ErrRead, ErrWrite, @Inheritable, 65536);
  SetHandleInformation(OutRead, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(ErrRead, HANDLE_FLAG_INHERIT, 0);
  try
    var Info: TProcessInformation;
    Result.Started := StartWithOwnStdHandles(Format('"%s" %s', [Exe, Argument]), DesktopPath,
      OutWrite, ErrWrite, Info);
    // The child has its own copies; ours would keep the pipes from ever ending.
    CloseHandle(OutWrite);
    CloseHandle(ErrWrite);
    if not Result.Started then begin
      Result.StartError := SysErrorMessage(GetLastError);
      Exit;
    end;
    var OutBytes, ErrBytes: TBytes;
    var Deadline := GetTickCount64 + QUIET_EXIT_TIMEOUT_MS;
    repeat
      Result.EndedByItself := WaitForSingleObject(Info.hProcess, 50) = WAIT_OBJECT_0;
      DrainPipe(OutRead, OutBytes);
      DrainPipe(ErrRead, ErrBytes);
    until Result.EndedByItself or (GetTickCount64 >= Deadline);
    if not Result.EndedByItself then begin
      Result.Windows := VisibleWindowsOn(Desktop, Info.dwProcessId);
      TerminateProcess(Info.hProcess, 1);
      WaitForSingleObject(Info.hProcess, QUIET_EXIT_TIMEOUT_MS);
    end else
      GetExitCodeProcess(Info.hProcess, Result.ExitCode);
    DrainPipe(OutRead, OutBytes);
    DrainPipe(ErrRead, ErrBytes);
    Result.StdOut := TEncoding.ANSI.GetString(OutBytes).Trim;
    Result.StdErr := TEncoding.ANSI.GetString(ErrBytes).Trim;
    CloseHandle(Info.hThread);
    CloseHandle(Info.hProcess);
  finally
    CloseHandle(OutRead);
    CloseHandle(ErrRead);
    if Desktop <> 0 then
      CloseDesktop(Desktop);
  end;
end;

function Scenario(const Argument: string; ExitCode: DWORD; const StdErrMust, StdOutMust: TArray<string>): TScenario;
begin
  Result.Argument   := Argument;
  Result.ExitCode   := ExitCode;
  Result.StdErrMust := StdErrMust;
  Result.StdOutMust := StdOutMust;
end;

// What each QuietFail* fixture must do: the exit code the RTL gives that failure
// anyway, and the text that replaces the box. A run-time error is written by the
// RTL itself, to STANDARD OUTPUT (FixtureQuiet.inc says why).
function ExpectedScenarios(LinksSysUtils: Boolean): TArray<TScenario>;
begin
  var RuntimeError := Format('Runtime error %d at ', [QUIET_FAIL_RUNTIME_ERROR]);
  var Fault := Scenario('-fault', STATUS_ACCESS_VIOLATION_CODE, ['unhandled OS exception $C0000005 at $'], []);
  var EndsOnRuntimeError := Scenario('-runerror', QUIET_FAIL_RUNTIME_ERROR, [], [RuntimeError]);
  if LinksSysUtils then begin
    var Raised := Scenario('-raise', EXIT_UNHANDLED_EXCEPTION,
      ['unhandled exception Exception at $', QUIET_FAIL_MESSAGE], []);
    Result := [Raised, EndsOnRuntimeError, Fault];
    Exit;
  end;
  var Raised := Scenario('-raise', EXIT_RUNTIME_ERROR_UNHANDLED, ['unhandled exception EQuietFailNoSysUtils at $'],
    [Format('Runtime error %d at ', [EXIT_RUNTIME_ERROR_UNHANDLED])]);
  Result := [Raised, EndsOnRuntimeError, Fault];
end;

{ TFixtureQuietTests }

procedure TFixtureQuietTests.Setup;
begin
  FProblems := TList<string>.Create;
end;

procedure TFixtureQuietTests.TearDown;
begin
  FProblems.Free;
end;

procedure TFixtureQuietTests.Check(Condition: Boolean; const Problem: string);
begin
  if not Condition then
    FProblems.Add(Problem);
end;

procedure TFixtureQuietTests.AssertNoProblems;
begin
  if FProblems.Count > 0 then
    Assert.Fail(sLineBreak + string.Join(sLineBreak, FProblems.ToArray));
end;

procedure TFixtureQuietTests.CheckFixtureProgram(const Path, Shown, Code: string);
begin
  var Units := UsedUnits(Code);
  var Visited := TStringList.Create;
  try
    if LinksSysUtils(Units, [ExtractFileDir(Path)], Visited) then begin
      Check(UsesUnit(Units, QUIET_UNIT), Shown + ': links System.SysUtils, so it must use ' + QUIET_UNIT);
      Exit;
    end;
  finally
    Visited.Free;
  end;
  Check(UsesUnit(Units, QUIET_UNIT_NO_SYSUTILS),
    Shown + ': does not link System.SysUtils, so it must use ' + QUIET_UNIT_NO_SYSUTILS);
  Check(not UsesUnit(Units, QUIET_UNIT),
    Shown + ': does not link System.SysUtils, and ' + QUIET_UNIT + ' would link it; use ' + QUIET_UNIT_NO_SYSUTILS);
end;

procedure TFixtureQuietTests.EveryFixtureProgram_UsesTheRightQuietUnit;
begin
  var Root := RepoRoot;
  var Examined := TStringList.Create;
  try
    for var FixtureRoot in FIXTURE_ROOTS do
      for var Path in TDirectory.GetFiles(Root + FixtureRoot, '*.dpr', TSearchOption.soAllDirectories) do begin
        var Code := WithoutComments(TFile.ReadAllText(Path));
        // A library cannot carry the quiet unit: ExceptProc, NoErrMsg and
        // IsConsole belong to the RTL of the module that holds them, and it is
        // the process that loads the library that shows a box or does not. Its
        // host program carries it. (Packages are .dpk files and not scanned.)
        if ProgramKind(Code) <> 'program' then
          Continue;
        Examined.Add(ExtractFileName(Path));
        CheckFixtureProgram(Path, ExtractRelativePath(Root, Path), Code);
      end;
    // Proves each root was actually scanned (one known program from each), and
    // that a source saved with a byte-order mark is recognised as a program.
    for var Known in ['TestTarget.dpr', 'TestHost.dpr', 'ExcNestFixture.dpr', 'QuietFailGui.dpr'] do
      Check(Examined.IndexOf(Known) >= 0, 'the scan never reached ' + Known + ': have the fixture roots moved?');
  finally
    Examined.Free;
  end;
  AssertNoProblems;
end;

procedure TFixtureQuietTests.CheckQuietFailFixture(const Name: string; LinksSysUtils: Boolean);
begin
  for var Bitness in ['Win32', 'Win64'] do begin
    var Exe := Format('%sDebuggerTests\TestTarget\%s\Debug\%s.exe', [RepoRoot, Bitness, Name]);
    var Caption := Name + ' ' + Bitness;
    if not TFile.Exists(Exe) then begin
      Check(False, Caption + ': not built (' + Exe + ') -- run build_and_run.bat');
      Continue;
    end;
    for var Expected in ExpectedScenarios(LinksSysUtils) do begin
      var Run := RunWithoutDebugger(Exe, Expected.Argument);
      var What := Caption + ' ' + Expected.Argument;
      if not Run.Started then begin
        Check(False, What + ': could not be started: ' + Run.StartError);
        Continue;
      end;
      if not Run.EndedByItself then begin
        Check(False, Format('%s: still running after %d ms -- a dialog is waiting for a click; killed it. '
          + 'On its desktop:%s%s', [What, QUIET_EXIT_TIMEOUT_MS, sLineBreak, Run.Windows]));
        Continue;
      end;
      Check(Run.ExitCode = Expected.ExitCode,
        Format('%s: exit code $%x, expected $%x', [What, Run.ExitCode, Expected.ExitCode]));
      for var Text in Expected.StdErrMust do
        Check(Run.StdErr.Contains(Text), Format('%s: "%s" missing from stderr [%s]', [What, Text, Run.StdErr]));
      for var Text in Expected.StdOutMust do
        Check(Run.StdOut.Contains(Text), Format('%s: "%s" missing from stdout [%s]', [What, Text, Run.StdOut]));
    end;
  end;
  AssertNoProblems;
end;

procedure TFixtureQuietTests.GuiFixture_FailsInWriting_NeverInADialog;
begin
  CheckQuietFailFixture('QuietFailGui', True);
end;

procedure TFixtureQuietTests.ConsoleFixture_FailsInWriting_NeverInADialog;
begin
  CheckQuietFailFixture('QuietFailConsole', True);
end;

procedure TFixtureQuietTests.GuiFixtureWithoutSysUtils_FailsInWriting_NeverInADialog;
begin
  CheckQuietFailFixture('QuietFailNoSysUtilsGui', False);
end;

procedure TFixtureQuietTests.ConsoleFixtureWithoutSysUtils_FailsInWriting_NeverInADialog;
begin
  CheckQuietFailFixture('QuietFailNoSysUtilsConsole', False);
end;

initialization
  TDUnitX.RegisterTestFixture(TFixtureQuietTests);

end.
