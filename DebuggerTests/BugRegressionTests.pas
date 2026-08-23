unit BugRegressionTests;
// Regression tests for the bugs found in the 2026-06 code review.
// Each test reproduces one bug through the public DAP surface (or, for
// TDebugInfoSet, through the unit API). They are written test-first: every
// test fails on the pre-fix adapter and passes after the fix.

interface

uses
  DUnitX.TestFramework,
  DapClient;

type
  [TestFixture]
  TBugRegressionTests = class
  private
    FClient: TDapClient;
    FBpSourceFile: string;

    class function RepoRoot: string; static;
    class function AdapterExe: string; static;
    class function TargetDir: string; static;
    class function TargetExe: string; static;
    class function TargetMap: string; static;
    class function TargetRsm: string; static;
    class function TargetSrc: string; static;

    function  Bp(const Marker: string): Integer;
    // Full session up to the first stop at the given BP marker.
    procedure OpenSessionAt(const BpMarker: string; out FrameId, LocalsRef: Integer;
      const Args: TArray<string> = nil);
    function  EvalResult(const Expr: string; FrameId: Integer): string;
  public
    [TearDown]
    procedure TearDown;

    // Bug 1: RunRemoteCallEx (property-getter path) lacked the abort-on-raise
    // and EXIT_PROCESS handling of RunMethodCall. A published property whose
    // getter raises hung the adapter forever.
    [Test]
    procedure Test_Bug1_RaisingPropertyGetter_DoesNotHangAdapter;

    // Bug 2: RunMethodCall wrote stacked arguments (5th and later) at
    // [RSP+32+...], inside the callee's register home area, instead of
    // [RSP+40+...]. Sum5's D/E arrived clobbered/garbage.
    [Test]
    procedure Test_Bug2_MethodCall_StackArgs_FifthAndSixth;

    // Bug 3: the stopAtEntry breakpoint record left Rva uninitialized;
    // ApplyAllBreakpoints then recomputed VA from the garbage Rva and the
    // entry stop was lost (INT3 planted at a random address).
    [Test]
    procedure Test_Bug3_StopAtEntry_StopsAtEntry;

    // Bug 4: setVariable with a NUMERIC value on an enum-typed field fell
    // into the unknown-type fallback and wrote 8 bytes, clobbering the
    // neighbouring fields.
    [Test]
    procedure Test_Bug4_SetVariable_EnumNumeric_DoesNotClobberNeighbours;

    // Bug 5: launch responded success immediately and reported errors as a
    // SECOND response for the same request (or not at all when CreateProcess
    // raised), leaving VS Code with a zombie session.
    [Test]
    procedure Test_Bug5_Launch_MissingProgram_FailureResponse;
    [Test]
    procedure Test_Bug5_Launch_NonexistentExe_FailureResponse;

    // Bug 6: an exception inside a request handler was logged but the request
    // was never answered (setBreakpoints without `arguments` AVs in the
    // handler). The client must receive a failure response.
    [Test]
    procedure Test_Bug6_MalformedSetBreakpoints_GetsErrorResponse;

    // Bug 7: a watch that invokes a method while the debuggee is stopped on a
    // first-chance exception consumed the exception event with DBG_CONTINUE,
    // swallowing the raise and corrupting the continue status. After the
    // eval, Continue must still deliver the exception to the program's
    // except handler.
    [Test]
    procedure Test_Bug7_EvalMethodCall_AtExceptionStop_PreservesExceptionFlow;

    // Bug 8: OUTPUT_DEBUG_STRING ANSI events were read and decoded at twice
    // their byte length, producing an embedded #0 plus garbage tail.
    [Test]
    procedure Test_Bug8_OutputDebugStringA_TextArrivesClean;

    // Bug 9: gotoTargets resolved the line through the MAP reader only;
    // with no MAP on disk a TD32-resolvable line returned no targets.
    [Test]
    procedure Test_Bug9_GotoTargets_ResolvesWithoutMapFile;

    // Bug 10: the VarArray expansion's overflow row reported the number of
    // DIMENSIONS instead of the true element count.
    [Test]
    procedure Test_Bug10_VarArrayCapMessage_ShowsTrueTotal;

    // Bug 16: a planted user breakpoint inside the callee of a synthetic
    // (watch-invoked) call was continued with plain DBG_CONTINUE -- RIP at
    // VA+1 with the 0xCC still in place, so the patched-out instruction
    // never executed and the call corrupted. The pump must skip the BP
    // transparently (restore byte, rewind, single-step, re-plant) and the
    // BP must still fire later on the normal execution path.
    [Test]
    procedure Test_Bug16_UserBpInsideSyntheticCallee_SkippedAndRearmed;

    // Bug 17: setVariable with a NUMERIC bitmask on a SET-typed field fell
    // into the 8-byte unknown-type fallback (same family as Bug 4, which
    // only covered enums), clobbering the fields after the 1-byte set slot.
    [Test]
    procedure Test_Bug17_SetVariable_SetNumeric_DoesNotClobberNeighbours;

    // Bug 18: Set Next Statement (DAP goto). First coverage for the feature;
    // also pins that the jump actually moves execution (the skipped
    // assignment must not run) and that the post-goto frame state is fresh
    // (a local read right after the jump resolves against the new location).
    [Test]
    procedure Test_Bug18_Goto_MovesExecution_AndRefreshesFrame;

    // Bug 19: an empty dynamic-array local (nil) rendered as `0 (0x0)` /
    // nil instead of the Pascal empty-array literal `[]`. A populated one
    // should read back as an array, not a bare pointer.
    [Test]
    procedure Test_Bug19_EmptyDynArray_DisplaysAsBrackets;

    // An unknown DAP command used to be answered with an EMPTY SUCCESS
    // response, to avoid leaving the client waiting. The constraint is right
    // and the answer was not: a client that acts on that success sees a silent
    // no-op -- the user presses something and nothing happens, with no error
    // anywhere. An error response unblocks the client just as well and is true.
    [Test]
    procedure UnknownCommand_IsRefused_NotSilentlySucceeded;
    // ...with one deliberate exception: `cancel` really is a harmless no-op.
    [Test]
    procedure CancelCommand_IsToleratedAsANoOp;
  end;

  // Bug 11: TDebugInfoSet.SortedRvas concatenated each provider's sorted
  // array; with two providers (TD32 + MAP, always both loaded) the result was
  // not globally sorted, breaking the binary search in PlantInFuncStepBps.
  [TestFixture]
  TDebugInfoSetTests = class
  public
    [Test]
    procedure Test_Bug11_SortedRvas_GloballySortedAcrossProviders;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.JSON,
  DebugInfoTypes, DebugInfoSet;

{ Path helpers (mirror TDebuggerTests; RunTests.exe sits in
  <repo>\DebuggerTests\Win64\Debug\) }

class function TBugRegressionTests.RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

class function TBugRegressionTests.AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

class function TBugRegressionTests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

class function TBugRegressionTests.TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

class function TBugRegressionTests.TargetMap: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

class function TBugRegressionTests.TargetRsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

class function TBugRegressionTests.TargetSrc: string;
begin
  Result := TargetDir + 'TestTarget.dpr';
end;

function TBugRegressionTests.Bp(const Marker: string): Integer;
begin
  // The 3 MAIN_* markers live in TestTarget.dpr's program main block; every
  // other subject marker was relocated into the shared TestTargetCore unit.
  Result := FindBpLine(TargetSrc, Marker);
  FBpSourceFile := TargetSrc;
  if Result > 0 then Exit;
  var CoreSrc := TargetDir + 'TestTargetCore.pas';
  Result := FindBpLine(CoreSrc, Marker);
  if Result > 0 then begin
    FBpSourceFile := CoreSrc;
    Exit;
  end;
  Assert.IsTrue(Result > 0, 'BP marker not found: ' + Marker);
end;

procedure TBugRegressionTests.TearDown;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

procedure TBugRegressionTests.OpenSessionAt(const BpMarker: string;
  out FrameId, LocalsRef: Integer; const Args: TArray<string>);
var
  Stopped: TJSONObject;
begin
  var BpLine := Bp(BpMarker);
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False, Args).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'stopped reason is not breakpoint');
  finally
    Stopped.Free;
  end;
  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0, 'no Locals scope found');
end;

function TBugRegressionTests.EvalResult(const Expr: string; FrameId: Integer): string;
var
  Resp: TJSONObject;
begin
  Resp := FClient.Evaluate(Expr, FrameId);
  try
    Result := Resp.GetValue<string>('result', '');
  finally
    Resp.Free;
  end;
end;

// Strip display suffix like "  (0x2A)" from debugger-formatted values.
function DisplayValue(const S: string): string;
begin
  var P := Pos('  (', S);
  if P <= 0 then
    P := Pos(' (', S);
  if P > 0 then
    Result := Copy(S, 1, P - 1)
  else
    Result := S;
end;

{ TBugRegressionTests }

procedure TBugRegressionTests.Test_Bug1_RaisingPropertyGetter_DoesNotHangAdapter;
var
  FrameId, LocalsRef: Integer;
begin
  OpenSessionAt('MAIN_GCOUNTER', FrameId, LocalsRef);
  // AsAvBoom is a published Integer property whose getter access-violates.
  // The TPropInfo getter path used to pass the AV through with DBG_CONTINUE:
  // the faulting instruction re-executed forever (event livelock) and the
  // evaluate never answered. The synthetic call must ABORT on the AV.
  var Seq := FClient.SendRequest('evaluate',
    Format('{"expression":"TheWidget.AsAvBoom","frameId":%d,"context":"watch"}',
      [FrameId]));
  var Resp := FClient.WaitRawResponse(Seq, 20000); // raises EDapError on timeout
  Resp.Free;
  // A Delphi-raise getter must come back too (covers the raise-abort branch).
  Seq := FClient.SendRequest('evaluate',
    Format('{"expression":"TheWidget.AsBoom","frameId":%d,"context":"watch"}',
      [FrameId]));
  Resp := FClient.WaitRawResponse(Seq, 20000);
  Resp.Free;
  // The adapter (and the stopped session) must still be usable afterwards.
  Assert.AreEqual('2', DisplayValue(EvalResult('1 + 1', FrameId)),
    'session must survive a faulting property getter');
end;

procedure TBugRegressionTests.Test_Bug2_MethodCall_StackArgs_FifthAndSixth;
var
  FrameId, LocalsRef: Integer;
begin
  OpenSessionAt('EVAL_BODY', FrameId, LocalsRef);
  // Self + 5 integer args = 6 slots: D and E travel on the stack. Positional
  // weights expose any stacked-argument misplacement.
  var Display := EvalResult('W.Sum5(1, 2, 3, 4, 5)', FrameId);
  Assert.AreEqual('12345', DisplayValue(Display),
    'Sum5(1,2,3,4,5) must be 12345; stacked args D/E corrupted, got: ' + Display);
end;

procedure TBugRegressionTests.Test_Bug3_StopAtEntry_StopsAtEntry;
var
  Stopped: TJSONObject;
begin
  var BpLine := Bp('MAIN_FIRST_LINE');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, {StopAtEntry=}True, nil).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('entry', Stopped.GetValue<string>('reason', ''),
      'first stop must be the entry stop');
  finally
    Stopped.Free;
  end;

  // After the entry stop, normal execution resumes and the first-line BP fires.
  FClient.Continue_.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'continue after entry stop must reach the first-line breakpoint');
  finally
    Stopped.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug4_SetVariable_EnumNumeric_DoesNotClobberNeighbours;
var
  FrameId, LocalsRef: Integer;
  EP: TJSONObject;
begin
  OpenSessionAt('ENUM_PACK_BODY', FrameId, LocalsRef);
  EP := FClient.FindVar(LocalsRef, 'EP');
  Assert.IsNotNull(EP, 'EP local not found');
  var EpRef: Integer;
  try
    EpRef := EP.GetValue<Integer>('variablesReference', 0);
  finally
    EP.Free;
  end;
  Assert.IsTrue(EpRef > 0, 'EP must be expandable');

  // Numeric assignment to the 1-byte enum field FGap (2 = wmPaused).
  FClient.SetVariable(EpRef, 'FGap', '2').Free;

  Assert.AreEqual('wmPaused', DisplayValue(FClient.VarValue(EpRef, 'FGap')),
    'FGap must read back wmPaused after numeric write');
  Assert.AreEqual('77', DisplayValue(FClient.VarValue(EpRef, 'FMark')),
    'FMark (adjacent byte) clobbered by the enum write');
  Assert.AreEqual('999', DisplayValue(FClient.VarValue(EpRef, 'FAfter')),
    'FAfter (next field) clobbered by the enum write');
end;

procedure TBugRegressionTests.Test_Bug5_Launch_MissingProgram_FailureResponse;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  var Seq := FClient.SendRequest('launch', '{"program":""}');
  var Resp := FClient.WaitRawResponse(Seq, 8000);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'launch without program must FAIL (the first and only response)');
  finally
    Resp.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug5_Launch_NonexistentExe_FailureResponse;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  var Seq := FClient.SendRequest('launch',
    '{"program":"C:\\nonexistent_zzz_12345\\no_such_target.exe"}');
  var Resp := FClient.WaitRawResponse(Seq, 8000);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'launch of a nonexistent exe must FAIL cleanly');
  finally
    Resp.Free;
  end;
  // The adapter must survive the failed launch.
  var Th := FClient.Threads;
  try
    Assert.IsNotNull(Th.GetValue('threads'), 'adapter died after failed launch');
  finally
    Th.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug6_MalformedSetBreakpoints_GetsErrorResponse;
const
  RawSeq = 990077;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // No `arguments` member at all: the handler used to AV and the request was
  // never answered.
  FClient.SendRawJson(
    '{"seq":' + IntToStr(RawSeq) + ',"type":"request","command":"setBreakpoints"}');
  var Resp := FClient.WaitRawResponse(RawSeq, 5000); // raises EDapError on timeout
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'malformed setBreakpoints must produce a FAILURE response');
  finally
    Resp.Free;
  end;
  var Th := FClient.Threads;
  try
    Assert.IsNotNull(Th.GetValue('threads'), 'adapter died on malformed request');
  finally
    Th.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug7_EvalMethodCall_AtExceptionStop_PreservesExceptionFlow;
var
  Stopped: TJSONObject;
begin
  var HandlerLine := Bp('EXC_HANDLER');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [HandlerLine]).Free;
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False,
    ['--run-exception-handler']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(30000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'expected the first-chance exception stop');
  finally
    Stopped.Free;
  end;

  // Function call evaluated WHILE stopped on the exception. Whether it runs
  // or is refused, it must return a response and must NOT swallow the
  // pending exception.
  var FrameId := FClient.GetFrameId;
  var R := FClient.Evaluate('FreeAdd(40, 2)', FrameId);
  Assert.IsNotNull(R, 'evaluate at exception stop must answer');
  R.Free;

  // Continue: the exception must reach the program's except handler, where
  // our breakpoint fires.
  FClient.Continue_.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'after eval-at-exception-stop, continue must land in the except handler');
  finally
    Stopped.Free;
  end;
  var Msg := EvalResult('E.Message', FClient.GetFrameId);
  Assert.IsTrue(Msg.Contains('exc-test-probe'),
    'handler must see the original exception, got: ' + Msg);
end;

procedure TBugRegressionTests.Test_Bug8_OutputDebugStringA_TextArrivesClean;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False,
    ['--run-ods']).Free;
  FClient.ConfigDone.Free;

  var S := FClient.WaitForOutputContaining('ods-ansi', 15000);
  Assert.AreEqual('ods-ansi-clean', S,
    'ANSI OutputDebugString text must arrive verbatim, got: ' + S.Replace(#0, '<NUL>'));
  Assert.IsTrue(FClient.WaitForTerminated(30000), 'target did not terminate');
end;

procedure TBugRegressionTests.Test_Bug9_GotoTargets_ResolvesWithoutMapFile;
var
  Stopped: TJSONObject;
begin
  var BpLine := Bp('MAIN_GCOUNTER');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  // Deliberately missing MAP: line resolution must work via TD32 alone.
  FClient.Launch(TargetExe, TargetDir + 'Win64\Debug\no_such_file.map',
    TargetRsm, TargetDir, False, nil).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'breakpoint must resolve via TD32 without a MAP');
  finally
    Stopped.Free;
  end;

  var Resp := FClient.GotoTargets(TargetSrc, Bp('MAIN_AFTER_NESTED'));
  try
    var Targets := Resp.GetValue('targets') as TJSONArray;
    Assert.IsNotNull(Targets, 'gotoTargets returned no body');
    Assert.IsTrue(Targets.Count > 0,
      'gotoTargets must resolve a TD32-known line even with no MAP file');
  finally
    Resp.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug10_VarArrayCapMessage_ShowsTrueTotal;
var
  FrameId, LocalsRef: Integer;
  BigVar: TJSONObject;
begin
  OpenSessionAt('BIG_VARARRAY_BODY', FrameId, LocalsRef);
  BigVar := FClient.FindVar(LocalsRef, 'Big');
  Assert.IsNotNull(BigVar, 'Big local not found');
  var Ref: Integer;
  try
    Ref := BigVar.GetValue<Integer>('variablesReference', 0);
  finally
    BigVar.Free;
  end;
  Assert.IsTrue(Ref > 0, 'Big (1500-element VarArray) must be expandable');

  var Resp := FClient.Variables(Ref);
  try
    var Arr := Resp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'no variables in VarArray expansion');
    var CapRow := '';
    for var I := 0 to Arr.Count - 1 do begin
      var V := Arr[I] as TJSONObject;
      if V.GetValue<string>('name', '') = '...' then
        CapRow := V.GetValue<string>('value', '');
    end;
    Assert.IsTrue(CapRow <> '', 'expected a "..." overflow row');
    Assert.IsTrue(CapRow.Contains('1500'),
      'overflow row must report the true element count (1500), got: ' + CapRow);
  finally
    Resp.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug17_SetVariable_SetNumeric_DoesNotClobberNeighbours;
var
  FrameId, LocalsRef: Integer;
  EP: TJSONObject;
begin
  OpenSessionAt('ENUM_PACK_BODY', FrameId, LocalsRef);
  EP := FClient.FindVar(LocalsRef, 'EP');
  Assert.IsNotNull(EP, 'EP local not found');
  var EpRef: Integer;
  try
    EpRef := EP.GetValue<Integer>('variablesReference', 0);
  finally
    EP.Free;
  end;
  Assert.IsTrue(EpRef > 0, 'EP must be expandable');

  // Numeric bitmask on the 1-byte set field FModes:
  // 6 = bit1 or bit2 = [wmRunning, wmPaused].
  FClient.SetVariable(EpRef, 'FModes', '6').Free;

  var Modes := FClient.VarValue(EpRef, 'FModes');
  Assert.IsTrue(Modes.Contains('wmRunning') and Modes.Contains('wmPaused'),
    'FModes must read back [wmRunning, wmPaused], got: ' + Modes);
  Assert.AreEqual('88', DisplayValue(FClient.VarValue(EpRef, 'FMark2')),
    'FMark2 (adjacent byte) clobbered by the set write');
  Assert.AreEqual('777', DisplayValue(FClient.VarValue(EpRef, 'FAfter2')),
    'FAfter2 (next field) clobbered by the set write');
end;

procedure TBugRegressionTests.Test_Bug16_UserBpInsideSyntheticCallee_SkippedAndRearmed;
var
  Stopped: TJSONObject;
begin
  if GetEnvironmentVariable('NO_RSM') = '1' then
    Assert.Pass('SKIP[no-rsm]: anchored on the .dpr program-main-block (TheStuff via MAIN_GCOUNTER); program-main-block locals are RSM-format-only and absent from TD32');
  // Two BPs in DIFFERENT files now: the stop anchor (MAIN_GCOUNTER, in the
  // program main block of TestTarget.dpr) and a line INSIDE TStuff.PubBump --
  // the method the watch below invokes -- which lives in the relocated
  // TestTargetCore unit. Each BP is set against its own source file.
  var AnchorLine := Bp('MAIN_GCOUNTER');
  var AnchorSrc  := FBpSourceFile;
  var CalleeLine := Bp('STUFF_PUBBUMP');
  var CalleeSrc  := FBpSourceFile;

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');
  FClient.SetBreakpoints(AnchorSrc, [AnchorLine]).Free;
  FClient.SetBreakpoints(CalleeSrc, [CalleeLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False, nil).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;
  var FrameId := FClient.GetFrameId;

  // PubBump is pure (Result := FCount + 1, FCount = 7). The planted BP on
  // its body line must be skipped: correct value, no nested stop, twice in
  // a row (proves the INT3 is re-planted after each skip).
  Assert.AreEqual('8', DisplayValue(EvalResult('TheStuff.PubBump()', FrameId)),
    'watch through a BP-carrying callee must return the real value');
  Assert.AreEqual('8', DisplayValue(EvalResult('TheStuff.PubBump()', FrameId)),
    'second invocation must work too (INT3 re-planted after the skip)');

  // The breakpoint must still fire on the NORMAL execution path: main calls
  // TheStuff.PubBump after the anchor line.
  FClient.Continue_.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'user BP inside the callee must still fire on normal execution');
    Assert.AreEqual(CalleeLine, Stopped.GetValue<Integer>('line', 0),
      'stop must be on the PubBump body line');
  finally
    Stopped.Free;
  end;
end;

procedure TBugRegressionTests.Test_Bug18_Goto_MovesExecution_AndRefreshesFrame;
var
  Stopped: TJSONObject;
begin
  var StartLine := Bp('GOTO_START');
  var LandLine  := Bp('GOTO_LAND');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');
  FClient.SetBreakpoints(FBpSourceFile, [StartLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False, ['--run-goto']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;

  // Populate the frame cache (the stale-cache path the fix guards).
  FClient.GetFrameId;

  // Resolve and jump to GOTO_LAND, skipping the `A := 2` assignment.
  var Targets := FClient.GotoTargets(FBpSourceFile, LandLine);
  var TargetId: Int64;
  try
    var Arr := Targets.GetValue('targets') as TJSONArray;
    Assert.IsNotNull(Arr, 'gotoTargets returned no targets');
    Assert.IsTrue(Arr.Count > 0, 'gotoTargets must resolve GOTO_LAND');
    TargetId := (Arr[0] as TJSONObject).GetValue<Int64>('id', 0);
  finally
    Targets.Free;
  end;
  Assert.IsTrue(TargetId <> 0, 'goto target id is zero');

  FClient.Goto_(1, TargetId).Free;

  // The goto produces its own stopped event at the landing line.
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('goto', Stopped.GetValue<string>('reason', ''),
      'goto must emit a stopped event with reason goto');
  finally
    Stopped.Free;
  end;

  // Fresh frame state: a local read right after the jump must resolve against
  // the new top frame. A reads back 1 -- the skipped `A := 2` never ran.
  var FrameId := FClient.GetFrameId;
  Assert.AreEqual('1', DisplayValue(EvalResult('A', FrameId)),
    'execution must have jumped over A := 2 (A stays 1)');
end;

procedure TBugRegressionTests.Test_Bug19_EmptyDynArray_DisplaysAsBrackets;
var
  FrameId, LocalsRef: Integer;
begin
  OpenSessionAt('DYNARR_DISPLAY_BODY', FrameId, LocalsRef);

  // Empty (nil) dynamic array must show the Pascal empty-array literal.
  var EmptyVal := FClient.VarValue(LocalsRef, 'EmptyDyn');
  Assert.AreEqual('[]', EmptyVal,
    'empty dynamic array must display as [], got: ' + EmptyVal);

  // A populated dynamic array must NOT render as a bare pointer/integer.
  var FullVal := FClient.VarValue(LocalsRef, 'FullDyn');
  Assert.IsFalse(FullVal.StartsWith('0x') or (FullVal = '0  (0x0)'),
    'populated dynamic array must not render as a bare pointer, got: ' + FullVal);
  Assert.IsTrue(FullVal.Contains('['),
    'populated dynamic array should render with array notation, got: ' + FullVal);
end;

{ TDebugInfoSetTests }

type
  TFakeLineProvider = class(TInterfacedObject, ISourceLineProvider)
  private
    FRvas: TArray<UInt64>;
  public
    constructor Create(const Rvas: TArray<UInt64>);
    function RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
    function SourceLineToRva(const FileName: string; Line: Integer;
      out Rva: UInt64): Boolean;
    function SortedRvas: TArray<UInt64>;
  end;

constructor TFakeLineProvider.Create(const Rvas: TArray<UInt64>);
begin
  inherited Create;
  FRvas := Rvas;
end;

function TFakeLineProvider.RvaToSourceLine(Rva: UInt64;
  out Loc: TSourceLocation): Boolean;
begin
  Result := False;
end;

function TFakeLineProvider.SourceLineToRva(const FileName: string;
  Line: Integer; out Rva: UInt64): Boolean;
begin
  Rva    := 0;
  Result := False;
end;

function TFakeLineProvider.SortedRvas: TArray<UInt64>;
begin
  Result := FRvas;
end;

procedure TDebugInfoSetTests.Test_Bug11_SortedRvas_GloballySortedAcrossProviders;
var
  InfoSet: TDebugInfoSet;
begin
  InfoSet := TDebugInfoSet.Create;
  try
    // Two providers with interleaved (each individually sorted) RVA ranges --
    // the TD32 + MAP shape every real session has.
    InfoSet.AddProvider(TFakeLineProvider.Create([100, 200, 300]));
    InfoSet.AddProvider(TFakeLineProvider.Create([150, 250]));
    var Rvas := InfoSet.SortedRvas;
    Assert.AreEqual<Integer>(5, Length(Rvas), 'all RVAs must be present');
    for var I := 1 to High(Rvas) do
      Assert.IsTrue(Rvas[I - 1] <= Rvas[I],
        Format('SortedRvas not sorted at index %d: %d > %d',
          [I, Rvas[I - 1], Rvas[I]]));
  finally
    InfoSet.Free;
  end;
end;

{ ------------------------------------------------- protocol robustness ---- }

procedure TBugRegressionTests.UnknownCommand_IsRefused_NotSilentlySucceeded;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // `setExpression` is real DAP, and one of the optional requests this adapter
  // does not implement. It is also exactly the shape that used to be dangerous:
  // an empty success would have told the client the assignment was made.
  var Seq  := FClient.SendRequest('setExpression',
    '{"expression":"X","value":"1"}');
  var Resp := FClient.WaitRawResponse(Seq, 8000);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'an unimplemented command must be REFUSED, not answered with an empty ' +
      'success a client would act on: ' + Resp.ToJSON);
    // The reason travels in `body.error.format`, where SendErrorResponse puts
    // every refusal. It has to NAME the command: "something failed" is only
    // marginally better than the empty success it replaced.
    Assert.IsTrue(Resp.ToJSON.Contains('setExpression'),
      'the refusal must name the command: ' + Resp.ToJSON);
    Assert.IsTrue(Resp.ToJSON.Contains('not implemented'),
      'the refusal must say what went wrong: ' + Resp.ToJSON);
  finally
    Resp.Free;
  end;
end;

procedure TBugRegressionTests.CancelCommand_IsToleratedAsANoOp;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // The client is abandoning a request; answering "done" is honest whether or
  // not anything was still running, and refusing would turn a client's cleanup
  // into a visible error.
  var Seq  := FClient.SendRequest('cancel', '{"requestId":1}');
  var Resp := FClient.WaitRawResponse(Seq, 8000);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False),
      'cancel must be tolerated as a no-op: ' + Resp.ToJSON);
  finally
    Resp.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TBugRegressionTests);
  TDUnitX.RegisterTestFixture(TDebugInfoSetTests);

end.
