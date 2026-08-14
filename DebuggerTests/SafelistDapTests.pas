unit SafelistDapTests;

// The safe-getter flow over the DAP wire, end to end: a getter-backed property
// defers, an "always evaluate" decision makes it render its VALUE on the next
// look, a deny puts the deferral back -- all against a real adapter process
// and a real debuggee, with the user file redirected to a scratch directory
// (DELPHI_DEBUGGER_SAFELIST_DIR) so these tests never touch the real one.
//
// The subject is TWidget.Score, `property Score: Integer read DoCalcScore`:
// getter-backed with no backing field, so it is exactly the row that renders
// "(expand to evaluate)" today. DoCalcScore = FValue * 2 = 84 at EVAL_BODY.

interface

uses
  DUnitX.TestFramework, System.JSON, DapClient;

type
  [TestFixture]
  TSafelistDapTests = class
  private
    FClient:   TDapClient;
    FScratch:  string;
    // A property row of W, walked fresh each call (caller frees): expansion
    // handles are minted per request, so a re-walk sees the CURRENT rendering.
    function  PropertiesRef: Integer;
    function  PropRow(const PropName: string): TJSONObject;
    function  ScoreRow: TJSONObject;
    // Writes a safelist decision the way the context menu does -- by expression.
    procedure Safelist(const Expression, Verdict: string);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure DeferredGetter_CarriesItsSafelistKey;
    [Test] procedure Allow_EvaluatesTheGetterOnTheNextLook_DenyDefersAgain;
    // The reported bug: an "always evaluate" driven by the property EXPRESSION
    // (which is all VS Code hands a context-menu command -- it drops custom
    // fields like delphiSafelistKey) must land, persist, and take effect.
    [Test] procedure AllowByExpression_LikeTheContextMenu_TakesEffect;
    // A denied getter is refused even in a WATCH, where calls are otherwise
    // allowed because the user typed the expression.
    [Test] procedure DenyByExpression_BlocksTheGetterInAWatch;
    // An authorised getter that BLOCKS must not hold the panel for its own
    // sake: the burst has one time budget, and a getter that overruns it is
    // deferred rather than rendered as a cancellation.
    [Test] procedure AnAuthorisedGetterThatHangs_DefersInsteadOfHoldingThePanel;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, Winapi.Windows, TestTempDirs;

const
  EVAL_SOURCE = 'TestTargetCore.pas';
  EVAL_MARKER = 'EVAL_BODY';

function RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

procedure TSafelistDapTests.Setup;
begin
  PurgeLeftoverTempDirs('SafelistDap_');
  FScratch := MakeTestScratchDir('SafelistDap_');
  // The adapter is a CHILD process: it inherits this, and SafeCallPolicy reads
  // it as the user dir. The real user.safelist.json is never touched.
  SetEnvironmentVariable('DELPHI_DEBUGGER_SAFELIST_DIR', PChar(FScratch));

  var Line := FindBpLine(TargetDir + EVAL_SOURCE, EVAL_MARKER);
  Assert.IsTrue(Line > 0, EVAL_MARKER + ' marker not found');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'no initialized event');
  FClient.SetBreakpoints(TargetDir + EVAL_SOURCE, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetDir + 'Win64\Debug\TestTarget.exe',
                 TargetDir + 'Win64\Debug\TestTarget.map',
                 TargetDir + 'Win64\Debug\TestTarget.rsm', TargetDir).Free;
  FClient.ConfigDone.Free;
  var Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;
end;

procedure TSafelistDapTests.TearDown;
begin
  SetEnvironmentVariable('DELPHI_DEBUGGER_SAFELIST_DIR', nil);
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

function TSafelistDapTests.ScoreRow: TJSONObject;
begin
  Result := PropRow('Score');
end;

procedure TSafelistDapTests.Safelist(const Expression, Verdict: string);
begin
  var Seq := FClient.SendRequest('delphiSafelistAdd',
    Format('{"expression":"%s","verdict":"%s"}', [Expression, Verdict]));
  var Resp := FClient.WaitRawResponse(Seq);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False),
      Format('safelist %s of %s failed: %s', [Verdict, Expression, Resp.ToJSON]));
  finally
    Resp.Free;
  end;
end;

function TSafelistDapTests.PropertiesRef: Integer;
begin
  var LocalsRef := FClient.GetLocalsRef(FClient.GetFrameId);
  var WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsTrue(WVar <> nil, 'W not in locals');
  var WRef := 0;
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
  finally
    WVar.Free;
  end;
  Assert.IsTrue(WRef > 0, 'W not expandable');

  var Groups := FClient.FindVar(WRef, 'properties');
  Assert.IsTrue(Groups <> nil, 'no properties group under W');
  var PropsRef := 0;
  try
    PropsRef := Groups.GetValue<Integer>('variablesReference', 0);
  finally
    Groups.Free;
  end;
  Assert.IsTrue(PropsRef > 0, 'properties group not expandable');
  Result := PropsRef;
end;

function TSafelistDapTests.PropRow(const PropName: string): TJSONObject;
begin
  Result := FClient.FindVar(PropertiesRef, PropName);
  Assert.IsTrue(Result <> nil, PropName + ' not among the properties');
end;

procedure TSafelistDapTests.DeferredGetter_CarriesItsSafelistKey;
begin
  var Row := ScoreRow;
  try
    Assert.AreEqual('(expand to evaluate)', Row.GetValue<string>('value', ''),
      'precondition: with no safelist the getter defers');
    var Key := Row.GetValue<string>('delphiSafelistKey', '');
    Assert.IsTrue(Key <> '',
      'a deferred getter row must NAME the safelist entry an action would write: ' + Row.ToJSON);
    Assert.IsTrue(Key.Contains('.'),
      'the key is class.member, got: ' + Key);
  finally
    Row.Free;
  end;
end;

procedure TSafelistDapTests.Allow_EvaluatesTheGetterOnTheNextLook_DenyDefersAgain;
begin
  var Key := '';
  var Row := ScoreRow;
  try
    Key := Row.GetValue<string>('delphiSafelistKey', '');
  finally
    Row.Free;
  end;
  Assert.IsTrue(Key <> '', 'no safelist key on the deferred row');

  // The user says "always evaluate this": the adapter writes the user file and
  // the SAME walk now shows the value -- 84, FValue*2, proving the getter RAN.
  var Seq := FClient.SendRequest('delphiSafelistAdd',
    Format('{"key":"%s","verdict":"allow"}', [Key]));
  var Resp := FClient.WaitRawResponse(Seq);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False), 'add failed: ' + Resp.ToJSON);
  finally
    Resp.Free;
  end;

  var Row2 := ScoreRow;
  try
    Assert.IsTrue(Row2.GetValue<string>('value', '').Contains('84'),
      'an allowed getter must render its value without being clicked, got: ' +
      Row2.GetValue<string>('value', ''));
    Assert.AreEqual(Key, Row2.GetValue<string>('delphiSafelistKey', ''),
      'the evaluated row keeps its key, or "never" could not name it');
  finally
    Row2.Free;
  end;

  // The file the decision landed in is the scratch one -- the redirection
  // worked and the entry is where the user could hand-correct it.
  var UserFile := TPath.Combine(FScratch, 'user.safelist.json');
  Assert.IsTrue(TFile.Exists(UserFile), 'user file not written: ' + UserFile);
  Assert.IsTrue(TFile.ReadAllText(UserFile).ToLower.Contains(Key.ToLower),
    'the key must appear in the user file');

  // And the user changes their mind: deny defers it again, immediately.
  Seq := FClient.SendRequest('delphiSafelistAdd',
    Format('{"key":"%s","verdict":"deny"}', [Key]));
  Resp := FClient.WaitRawResponse(Seq);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False), 'deny failed');
  finally
    Resp.Free;
  end;

  var Row3 := ScoreRow;
  try
    Assert.AreEqual('(expand to evaluate)', Row3.GetValue<string>('value', ''),
      'a denied getter must defer again');
  finally
    Row3.Free;
  end;
end;

procedure TSafelistDapTests.AllowByExpression_LikeTheContextMenu_TakesEffect;
begin
  // What the reported bug hit: the frontend has only the expression (VS Code
  // drops the row's custom key), and the getter's name (DoCalcScore) differs
  // from the property (Score), so the key MUST be rebuilt from `W.Score` and
  // land on `twidget.score` -- the spelling the expansion looks up. If those
  // two disagree, the allow is written but never found, and the row stays
  // deferred forever, exactly as reported for Application.ComponentCount.
  var Seq := FClient.SendRequest('delphiSafelistAdd',
    '{"expression":"W.Score","verdict":"allow"}');
  var Resp := FClient.WaitRawResponse(Seq);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False), 'add failed: ' + Resp.ToJSON);
    var Body := Resp.GetValue('body') as TJSONObject;
    Assert.IsFalse(Body.GetValue<Boolean>('applicable', True) = False,
      'W.Score is a getter-backed property; it must be applicable: ' + Resp.ToJSON);
  finally
    Resp.Free;
  end;

  var Row := ScoreRow;
  try
    Assert.IsTrue(Row.GetValue<string>('value', '').Contains('84'),
      'allowing by expression must make the getter render its value: ' +
      Row.GetValue<string>('value', ''));
  finally
    Row.Free;
  end;
end;

procedure TSafelistDapTests.DenyByExpression_BlocksTheGetterInAWatch;
begin
  // A watch normally runs a getter without asking -- the user typed it. A DENY
  // is the one exception, and it must bite HERE too, not only in the expansion
  // tree. Precondition: the watch works before the deny.
  var Before := FClient.Evaluate('W.Score', FClient.GetFrameId, 'watch');
  try
    Assert.IsTrue(Before.GetValue<string>('result', '').Contains('84'),
      'precondition: W.Score evaluates in a watch: ' + Before.ToJSON);
  finally
    Before.Free;
  end;

  var Seq := FClient.SendRequest('delphiSafelistAdd',
    '{"expression":"W.Score","verdict":"deny"}');
  FClient.WaitRawResponse(Seq).Free;

  var After := FClient.Evaluate('W.Score', FClient.GetFrameId, 'watch');
  try
    Assert.IsFalse(After.GetValue<string>('result', '').Contains('84'),
      'a denied getter must NOT run in a watch: ' + After.ToJSON);
    Assert.IsTrue(After.GetValue<string>('result', '').ToLower.Contains('denied'),
      'the watch must say WHY it did not evaluate: ' + After.ToJSON);
  finally
    After.Free;
  end;
end;

procedure TSafelistDapTests.AnAuthorisedGetterThatHangs_DefersInsteadOfHoldingThePanel;
begin
  // Both are authorised. Score answers at once; SlowScore sleeps five seconds --
  // longer than any budget, and long enough that waiting for it would be
  // unmistakable in the elapsed time.
  for var Expr in ['W.Score', 'W.SlowScore'] do
    Safelist(Expr, 'allow');

  // ONE walk, and both rows read out of it. It has to be one: a getter cut
  // short leaves the debuggee thread inside the blocking call it was making
  // (here a 5 s Sleep), so nothing else can be called on that thread until the
  // block ends -- a later walk would see EVERY authorised getter fail, which
  // says nothing about the budget.
  var Started := GetTickCount64;
  var Fast, Slow: string;
  var Resp := FClient.Variables(PropertiesRef);
  var Elapsed := GetTickCount64 - Started;
  try
    for var Row in (Resp.GetValue('variables') as TJSONArray) do begin
      var V := Row as TJSONObject;
      if SameText(V.GetValue<string>('name', ''), 'Score')     then Fast := V.GetValue<string>('value', '');
      if SameText(V.GetValue<string>('name', ''), 'SlowScore') then Slow := V.GetValue<string>('value', '');
    end;
  finally
    Resp.Free;
  end;

  // Score is reached while the budget is intact, so it answers.
  Assert.IsTrue(Fast.Contains('84'),
    'an authorised getter reached with budget left must render its value, got: ' + Fast);
  // SlowScore is cut short -- and a cut-short call is not an answer. Rendering
  // the cancellation as its value would hide the click that still evaluates it
  // on the full explicit budget.
  Assert.AreEqual('(expand to evaluate)', Slow,
    'a getter the watchdog cut short must DEFER, got: ' + Slow);
  // The getter sleeps 5 s, so anything below that proves the panel was not held
  // waiting for it. Deliberately loose: the assertions above carry the meaning,
  // this one only separates "cut short" from "waited it out".
  Assert.IsTrue(Elapsed < 4500,
    Format('the group took %d ms; the budget must cut the hung getter short', [Elapsed]));
end;

initialization
  TDUnitX.RegisterTestFixture(TSafelistDapTests);

end.
