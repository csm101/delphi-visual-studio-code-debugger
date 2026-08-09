unit ExceptionStepTests;

// Stepping at a FIRST-CHANCE EXCEPTION stop.
//
// The defect these cover: HandleException parks the stop with
// FPendingContinueStatus = DBG_EXCEPTION_NOT_HANDLED so the program's own
// handler still runs, and the three step command handlers then overwrote it
// with DBG_CONTINUE before resuming. Continue therefore delivered the exception
// correctly while every STEP swallowed it and re-executed the faulting
// instruction -- which raised it again, forever.
//
// The fix is not merely "deliver the exception". At an exception there is no
// next source line, so a step of ANY kind means: run to the first `except` or
// `finally` block up the stack that actually receives it, and land in the
// user's own source. Where that block cannot be PROVEN, refuse and say what is
// missing. See DAP_DEBUGGER_ARCHITECTURE.md ("Stepping at an exception stop")
// and EH_FORMAT_NOTES.md for the layouts.
//
// Debuggee: DevTools\Fixtures\ExcNestFixture.dpr, built for both bitnesses by
// DevTools\build_exc_fixture.bat. It is reused rather than extended into
// TestTarget on purpose -- adding scenarios there shifts RSM import indices and
// marker ordering (TRAPS.md).
//
// Every test is BITNESS-PARAMETERISED and COLLECTS its failures rather than
// asserting per case: both executables are called ExcNestFixture.exe, so a
// message built from the file name cannot identify the bitness, and a
// first-failure abort would hide the x86 case entirely (TRAPS.md).

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TExceptionStepTests = class
  public
    // --- x64: every construct is provable, and the step lands in it ----------
    // The intervening try/finally receives the exception FIRST, so that -- not
    // the outer except -- is where a step must land.
    [Test] procedure Win64_Step_LandsInTheFinallyThatRunsFirst;
    [Test] procedure Win64_Step_LandsInTheOnClauseBlock;
    [Test] procedure Win64_Step_LandsInTheBareExceptBlock;
    // Two `on` clauses of which the FIRST does not match: taking clause 0 would
    // plant in a block that never executes.
    [Test] procedure Win64_Step_LandsInTheMATCHINGClauseOfTwo;
    // An access violation is a hardware fault, not a Delphi raise: no exception
    // object, a different code, and frame 0 IS the faulting instruction.
    [Test] procedure Win64_Step_AccessViolation_LandsInTheFinally;
    // All three kinds mean the same thing here.
    [Test] procedure Win64_StepIntoAndStepOut_LandWhereStepOverDoes;
    // The reported symptom: the same exception, forever.
    [Test] procedure Win64_Step_DoesNotRefireTheSameException;

    // --- x86: only `except` WITH `on` clauses is provable ---------------------
    [Test] procedure Win32_Step_LandsInTheOnClauseBlock;
    [Test] procedure Win32_Step_LandsInTheMATCHINGClauseOfTwo;
    // The negative half, and it is deliberate: the fs:[0] record of a
    // try/finally or a bare `except` carries no table, so the block address is
    // not derivable -- only the dispatch stub, and a hit there is the SEH
    // SEARCH pass rather than the block running.
    [Test] procedure Win32_Step_TryFinally_RefusesAndNamesTheConstruct;
    [Test] procedure Win32_Step_BareExcept_RefusesAndNamesTheConstruct;

    // --- surface -------------------------------------------------------------
    // An ordinary (non-exception) stop must keep behaving exactly as before.
    [Test] procedure Step_AtAnOrdinaryStop_IsStillFireAndForget;
  end;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.StrUtils,
  DebugSession, DebugSessionTypes, DebugTarget, DebugInfoTypes;

type
  TStepKind = (skOver, skInto, skOut);

  // What one scenario observed, so an assertion can talk about all of it at
  // once instead of aborting on the first surprise.
  TStepOutcome = record
    Launched:        Boolean;
    ReachedStop:     Boolean;   // the first-chance exception stop was reached
    StepAccepted:    Boolean;
    RefusalReason:   string;
    LandedFile:      string;
    LandedLine:      Integer;
    LandedReason:    TStopReason;
    ExceptionStops:  Integer;   // srException stops seen AFTER the step
    Note:            string;    // Session.LastStepNote at the end
    Diagnostic:      string;    // why the scenario could not run at all
  end;

const
  FIXTURE_SOURCE = 'ExcNestFixture.dpr';

function RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function FixtureDir: string;
begin
  Result := RepoRoot + 'DevTools\Fixtures\';
end;

function FixtureExe(const Bitness: string): string;
begin
  Result := FixtureDir + Bitness + '\Debug\ExcNestFixture.exe';
end;

// 1-based line carrying `{BP:<Marker>}`-style trailing comment markers. The
// fixture uses plain `// MARKER` comments (it predates the {BP:} convention and
// is shared with ExcHandlerProbe), so the marker is matched as a comment tail.
function MarkerLine(const Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureDir + FIXTURE_SOURCE);
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains('// ' + Marker) then
        Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

// The line the fixture's `on <Class> do` clause header sits on. A clause block's
// first instruction is attributed to the `on` line, not to the statement inside
// it, so that is the line a landing in it reports.
function OnClauseLine(const Marker: string): Integer;
begin
  // Every clause marker in the fixture tags the STATEMENT; the clause header is
  // the line above it.
  Result := MarkerLine(Marker) - 1;
end;

// Runs one scenario end to end: launch the fixture, pump to the first-chance
// exception stop, take one step of the requested kind, and pump for the
// landing. Never asserts -- the caller decides what the observation means.
function RunExceptionStep(const Bitness, Args: string; Kind: TStepKind;
  Filters: TExceptionFilters): TStepOutcome;
var
  Session: TDebugSession;
begin
  Result := Default(TStepOutcome);
  var Exe := FixtureExe(Bitness);
  if not FileExists(Exe) then begin
    Result.Diagnostic := Format('%s is missing -- run DevTools\build_exc_fixture.bat',
      [Exe]);
    Exit;
  end;

  Session := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath             := Exe;
    Opts.MapPath             := ChangeFileExt(Exe, '.map');
    Opts.RsmPath             := ChangeFileExt(Exe, '.rsm');
    Opts.SourceRoot          := FixtureDir;
    Opts.Args                := Args;
    Opts.StopAtEntry         := False;
    Opts.ExceptionFilters    := Filters;
    Opts.ExceptionFiltersSet := True;
    Result.Launched := Session.Launch(Opts);
    if not Result.Launched then begin
      Result.Diagnostic := 'Launch returned False';
      Exit;
    end;

    var Deadline := GetTickCount64 + 60000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    if Session.State <> dsStopped then begin
      Result.Diagnostic := 'the fixture never stopped on its first-chance exception';
      Exit;
    end;
    if not Session.StoppedOnUndeliveredException then begin
      Result.Diagnostic := 'the stop was not an undelivered-exception stop';
      Exit;
    end;
    Result.ReachedStop := True;

    var Reason: string;
    case Kind of
      skOver: Result.StepAccepted := Session.StepOver(0, Reason);
      skInto: Result.StepAccepted := Session.StepInto(0, Reason);
      skOut:  Result.StepAccepted := Session.StepOut(0, Reason);
    end;
    Result.RefusalReason := Reason;
    if not Result.StepAccepted then
      Exit;

    Deadline := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    if Session.State <> dsStopped then begin
      Result.Diagnostic := 'the step never produced a stop';
      Exit;
    end;

    Result.LandedReason := Session.StopReason;
    if Result.LandedReason = srException then
      Inc(Result.ExceptionStops);
    Result.Note := Session.LastStepNote;
    var FnName: string;
    Session.GetCurrentLocation(FnName, Result.LandedFile, Result.LandedLine);
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

// One landing assertion, for every bitness the scenario is expected to work on.
procedure CheckLanding(const Bitness, Args: string; Kind: TStepKind;
  ExpectedLine: Integer; Filters: TExceptionFilters; var Problems: string);
begin
  var O := RunExceptionStep(Bitness, Args, Kind, Filters);
  var Prefix := Format('[%s "%s"] ', [Bitness, Args]);
  if O.Diagnostic <> '' then begin
    Problems := Problems + Prefix + O.Diagnostic + sLineBreak;
    Exit;
  end;
  if not O.StepAccepted then begin
    Problems := Problems + Prefix + 'the step was REFUSED: ' + O.RefusalReason + sLineBreak;
    Exit;
  end;
  if O.LandedReason <> srStep then begin
    Problems := Problems + Prefix + Format(
      'the step did not report a step stop (reason %d) at %s:%d; note=%s',
      [Ord(O.LandedReason), ExtractFileName(O.LandedFile), O.LandedLine, O.Note]) + sLineBreak;
    Exit;
  end;
  if not SameText(ExtractFileName(O.LandedFile), FIXTURE_SOURCE) then
    Problems := Problems + Prefix + 'landed outside the fixture source: ' +
      O.LandedFile + sLineBreak
  else if O.LandedLine <> ExpectedLine then
    Problems := Problems + Prefix + Format('landed on line %d, expected %d',
      [O.LandedLine, ExpectedLine]) + sLineBreak;
end;

procedure CheckRefusal(const Bitness, Args: string; const MustMention: array of string;
  Filters: TExceptionFilters; var Problems: string);
begin
  var O := RunExceptionStep(Bitness, Args, skOver, Filters);
  var Prefix := Format('[%s "%s"] ', [Bitness, Args]);
  if O.Diagnostic <> '' then begin
    Problems := Problems + Prefix + O.Diagnostic + sLineBreak;
    Exit;
  end;
  if O.StepAccepted then begin
    Problems := Problems + Prefix + Format('the step was ACCEPTED and landed at %s:%d ' +
      '-- it was expected to refuse, because the block address is not derivable here',
      [ExtractFileName(O.LandedFile), O.LandedLine]) + sLineBreak;
    Exit;
  end;
  for var Needle in MustMention do
    if not ContainsText(O.RefusalReason, Needle) then
      Problems := Problems + Prefix + Format('the refusal does not mention "%s": %s',
        [Needle, O.RefusalReason]) + sLineBreak;
end;

procedure Verify(const Problems: string);
begin
  Assert.IsTrue(Problems = '', sLineBreak + Problems);
end;

{ ------------------------------------------------------------------ x64 ---- }

procedure TExceptionStepTests.Win64_Step_LandsInTheFinallyThatRunsFirst;
begin
  var Problems := '';
  // No -nofinally: Level2Finally's try/finally is between the raise and the
  // outer except, so IT is the handler the exception reaches first.
  CheckLanding('Win64', '', skOver, MarkerLine('FINALLY_BLOCK'), [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win64_Step_LandsInTheOnClauseBlock;
begin
  var Problems := '';
  CheckLanding('Win64', '-nofinally', skOver, OnClauseLine('EXCEPT_BLOCK'),
    [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win64_Step_LandsInTheBareExceptBlock;
begin
  var Problems := '';
  // A bare `except` has no clause table: the scope entry's Handler field is the
  // flag 2 and its Target IS the block. The compiler attributes that address to
  // the `try` body's last line, which is what a landing there reports.
  CheckLanding('Win64', '-nofinally -bare', skOver, MarkerLine('BARE_EXCEPT_BLOCK') - 2,
    [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win64_Step_LandsInTheMATCHINGClauseOfTwo;
begin
  var Problems := '';
  // Clause 0 is `on E: EAccessViolation`, which a Delphi raise of Exception does
  // NOT match. Landing there would mean the debugger took entry 0 of the table.
  CheckLanding('Win64', '-nofinally -two', skOver, OnClauseLine('EXC_CLAUSE'),
    [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win64_Step_AccessViolation_LandsInTheFinally;
begin
  var Problems := '';
  CheckLanding('Win64', '-av', skOver, MarkerLine('FINALLY_BLOCK'),
    [efAccessViolation], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win64_StepIntoAndStepOut_LandWhereStepOverDoes;
begin
  var Problems := '';
  CheckLanding('Win64', '-nofinally', skInto, OnClauseLine('EXCEPT_BLOCK'),
    [efDelphi], Problems);
  CheckLanding('Win64', '-nofinally', skOut, OnClauseLine('EXCEPT_BLOCK'),
    [efDelphi], Problems);
  Verify(Problems);
end;

// The reported failure, stated as a property: after ONE step the next stop must
// be the step's landing, not the same exception again.
//
// An ACCESS VIOLATION is what makes the loop, and it has to be an access
// violation: with the defect present (the step handler forcing DBG_CONTINUE)
// the exception is swallowed and the FAULTING INSTRUCTION RE-EXECUTES, which
// faults again -- forever. A Delphi `raise` is a software RaiseException call,
// so swallowing it merely lets the call return and the step wanders off into
// the RTL instead of looping; that is a different (also wrong) outcome and the
// other tests cover it.
procedure TExceptionStepTests.Win64_Step_DoesNotRefireTheSameException;
begin
  var O := RunExceptionStep('Win64', '-av', skOver, [efAccessViolation]);
  Assert.AreEqual('', O.Diagnostic, O.Diagnostic);
  Assert.IsTrue(O.StepAccepted, 'the step was refused: ' + O.RefusalReason);
  Assert.AreEqual(0, O.ExceptionStops,
    Format('the step produced another EXCEPTION stop at %s:%d instead of a landing ' +
      '(the exception was swallowed and the faulting instruction re-executed); note=%s',
      [ExtractFileName(O.LandedFile), O.LandedLine, O.Note]));
  Assert.AreEqual('', O.Note,
    'the step abandoned itself rather than reaching the handler: ' + O.Note);
end;

{ ------------------------------------------------------------------ x86 ---- }

procedure TExceptionStepTests.Win32_Step_LandsInTheOnClauseBlock;
begin
  var Problems := '';
  CheckLanding('Win32', '-nofinally', skOver, OnClauseLine('EXCEPT_BLOCK'),
    [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win32_Step_LandsInTheMATCHINGClauseOfTwo;
begin
  var Problems := '';
  CheckLanding('Win32', '-nofinally -two', skOver, OnClauseLine('EXC_CLAUSE'),
    [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win32_Step_TryFinally_RefusesAndNamesTheConstruct;
begin
  var Problems := '';
  CheckRefusal('Win32', '', ['try/FINALLY', 'HandleFinally', 'not derivable'],
    [efDelphi], Problems);
  Verify(Problems);
end;

procedure TExceptionStepTests.Win32_Step_BareExcept_RefusesAndNamesTheConstruct;
begin
  var Problems := '';
  CheckRefusal('Win32', '-nofinally -bare',
    ['bare `except`', 'HandleAnyException', 'not derivable'], [efDelphi], Problems);
  Verify(Problems);
end;

{ -------------------------------------------------------------- surface ---- }

// The routing must be invisible at an ordinary stop: a source-level step there
// still posts its command and never refuses, on either bitness.
procedure TExceptionStepTests.Step_AtAnOrdinaryStop_IsStillFireAndForget;
begin
  var Problems := '';
  for var Bitness in TArray<string>.Create('Win64', 'Win32') do begin
    var Exe := FixtureExe(Bitness);
    if not FileExists(Exe) then begin
      Problems := Problems + Exe + ' is missing -- run DevTools\build_exc_fixture.bat' +
        sLineBreak;
      Continue;
    end;
    var Session := TDebugSession.Create;
    try
      var Opts := Default(TLaunchOptions);
      Opts.ExePath             := Exe;
      Opts.MapPath             := ChangeFileExt(Exe, '.map');
      Opts.RsmPath             := ChangeFileExt(Exe, '.rsm');
      Opts.SourceRoot          := FixtureDir;
      Opts.StopAtEntry         := False;
      Opts.ExceptionFilters    := [];   // never break on the raise
      Opts.ExceptionFiltersSet := True;
      if not Session.Launch(Opts) then begin
        Problems := Problems + Bitness + ': Launch returned False' + sLineBreak;
        Continue;
      end;
      var LineSpec := Default(TBpLineSpec);
      LineSpec.Line := MarkerLine('RAISE_SITE');
      Session.SetBreakpoints(FIXTURE_SOURCE, [LineSpec]);
      var Deadline := GetTickCount64 + 60000;
      while (Session.State <> dsStopped) and (not Session.HasExited) and
            (GetTickCount64 < Deadline) do
        Session.Pump;
      if Session.State <> dsStopped then begin
        Problems := Problems + Bitness + ': the breakpoint never hit' + sLineBreak;
        Continue;
      end;
      if Session.StoppedOnUndeliveredException then begin
        Problems := Problems + Bitness +
          ': a plain breakpoint stop was reported as an undelivered-exception stop' +
          sLineBreak;
        Continue;
      end;
      var Reason: string;
      if not Session.StepOver(0, Reason) then
        Problems := Problems + Bitness +
          ': a step at an ORDINARY stop was refused: ' + Reason + sLineBreak;
    finally
      Session.Terminate;
      Session.Free;
    end;
  end;
  Verify(Problems);
end;

initialization
  TDUnitX.RegisterTestFixture(TExceptionStepTests);

end.
