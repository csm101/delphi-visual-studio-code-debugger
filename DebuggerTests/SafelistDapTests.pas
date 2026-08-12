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
    // The Score row, walked fresh each call (caller frees): expansion handles
    // are minted per request, so a re-walk sees the CURRENT rendering.
    function  ScoreRow: TJSONObject;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure DeferredGetter_CarriesItsSafelistKey;
    [Test] procedure Allow_EvaluatesTheGetterOnTheNextLook_DenyDefersAgain;
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

  Result := FClient.FindVar(PropsRef, 'Score');
  Assert.IsTrue(Result <> nil, 'Score not among the properties');
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

initialization
  TDUnitX.RegisterTestFixture(TSafelistDapTests);

end.
