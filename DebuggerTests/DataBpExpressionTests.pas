unit DataBpExpressionTests;

// Watchpoints on a COMPUTED address.
//
// Until now a watch target had to be a name: a local or global the user could
// right-click in the Variables view, or a literal address typed by a caller
// that already knew the number. That covers "who changes this variable" and
// misses the question watchpoints are actually reached for -- "who is writing
// past the end of my array", where the interesting address belongs to no
// variable at all and is one byte outside the one that does.
//
// Three things had to change together, and all three are asserted here:
//
//   * the resolver accepts an EXPRESSION, by one rule: a bare identifier is a
//     symbol and is watched at its own storage; `@X` is already an address;
//     anything else is watched where IT lives (`Arr[High(Arr)]`);
//   * a width the caller did not name is chosen to FIT the address rather than
//     defaulting to a pointer and refusing everything unaligned -- the byte
//     after a buffer is at an odd address as often as not, and that refusal
//     made the feature unusable for its main case;
//   * the adapter advertises `supportsDataBreakpointBytes`, which is what makes
//     VS Code offer "Add Data Breakpoint at Address" -- the only place in the
//     UI where a target can be TYPED.
//
// Fixture: `TestTarget --run-databp-buffer` (RunDataBpBufferFixture in
// TestTargetCore.pas). `GDataBpBuffer` is a RECORD -- Before, Data[0..7],
// After -- because only a record guarantees the guard bytes really do sit
// either side of the buffer; the linker orders separate globals as it pleases.

interface

uses
  System.JSON, DUnitX.TestFramework, DapClient;

type
  [TestFixture]
  TDataBpExpressionTests = class
  private
    FClient: TDapClient;
    // Stops inside DataBpBufferWriter, after the first buffer write and before
    // the last-element write and the overrun, so a watchpoint armed here still
    // has both writes ahead of it.
    procedure StartAtArmMarker;
    function  ArmAndContinue(const DataId: string): TJSONObject;
  public
    [TearDown] procedure TearDown;

    // The adapter must SAY it takes an address+byte-count, or VS Code never
    // offers the UI and the whole path is unreachable from the GUI however well
    // it works underneath.
    [Test] procedure Capability_DataBreakpointBytes_IsAdvertised;

    // `GDataBpBuffer.Data[High(GDataBpBuffer.Data)]` -- no variable names this
    // cell, and its width (1 byte, from the element type) is not the pointer
    // width the old code would have assumed.
    [Test] procedure Expression_LastArrayElement_ArmsAndFires;

    // The overrun itself, through the address form the "Add Data Breakpoint at
    // Address" panel uses: an expression evaluated as an address, plus bytes.
    [Test] procedure AddressForm_ByteAfterTheBuffer_ArmsAndFires;

    // A width the debug registers cannot express is refused by name. 3 bytes is
    // not rounded to 4 -- the hardware ignores the low address bits, so a
    // widened watch silently covers a neighbouring cell.
    [Test] procedure AddressForm_UnsupportedWidth_Refused;

    // Regression: an odd address used to be refused outright ("not aligned to 8
    // bytes") because a literal always took the pointer width. The width the
    // CALLER did not name is now chosen to fit.
    [Test] procedure OddAddress_ChoosesAFittingWidth_InsteadOfRefusing;

    // ...but a width the caller DID name is honoured strictly: no quiet
    // narrowing behind the caller's back.
    [Test] procedure OddAddress_WithExplicitWiderWidth_Refused;

    // An unknown bare NAME must stay "unresolved symbol". It must never be
    // reinterpreted as arithmetic that happens to evaluate to something.
    [Test] procedure UnknownBareName_StillRefusedAsASymbol;
  end;

implementation

uses
  System.SysUtils;

// A refusal answers with `dataId: null`, which is a JSON null and not an empty
// string -- reading it as a string yields the DEFAULT, so a test that compares
// against '' concludes the opposite of what happened.
function NoDataId(Info: TJSONObject): Boolean;
begin
  var V := Info.GetValue('dataId');
  Result := (V = nil) or (V is TJSONNull);
end;

const
  SOURCE     = 'TestTargetCore.pas';
  ARM_MARKER = 'DATABP_BUF_ARM';

function RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function SourcePath: string;
begin
  Result := TargetDir + SOURCE;
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

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

{ ------------------------------------------------------------------ setup -- }

procedure TDataBpExpressionTests.StartAtArmMarker;
begin
  var Line := FindBpLine(SourcePath, ARM_MARKER);
  Assert.IsTrue(Line > 0, 'marker ' + ARM_MARKER + ' not found in ' + SOURCE);

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  FClient.SetBreakpoints(SourcePath, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False,
    ['--run-databp-buffer']).Free;
  FClient.ConfigDone.Free;

  var Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      Format('did not stop at %s (line %d)', [ARM_MARKER, Line]));
  finally
    Stopped.Free;
  end;
end;

function TDataBpExpressionTests.ArmAndContinue(const DataId: string): TJSONObject;
begin
  var SetResp := FClient.SetDataBreakpoints([DataId]);
  try
    var Arr := SetResp.GetValue('breakpoints') as TJSONArray;
    Assert.IsTrue((Arr <> nil) and (Arr.Count = 1), 'setDataBreakpoints returned no entry');
    var E := Arr.Items[0] as TJSONObject;
    Assert.IsTrue(E.GetValue<Boolean>('verified', False),
      'the watchpoint was not armed: ' + E.GetValue<string>('message', ''));
  finally
    SetResp.Free;
  end;

  FClient.Continue_.Free;
  Result := FClient.WaitForStopped(20000);
end;

procedure TDataBpExpressionTests.TearDown;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect.Free;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

{ ---------------------------------------------------------------- tests ---- }

procedure TDataBpExpressionTests.Capability_DataBreakpointBytes_IsAdvertised;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  var Caps := FClient.Initialize;
  try
    Assert.IsTrue(Caps.GetValue<Boolean>('supportsDataBreakpointBytes', False),
      'without this capability VS Code never offers "Add Data Breakpoint at ' +
      'Address", and an address can only be watched by a client that already ' +
      'knows the number');
  finally
    Caps.Free;
  end;
end;

procedure TDataBpExpressionTests.Expression_LastArrayElement_ArmsAndFires;
const
  EXPR = 'GDataBpBuffer.Data[High(GDataBpBuffer.Data)]';
begin
  StartAtArmMarker;

  var DataId: string := '';
  var Info := FClient.DataBreakpointInfo(EXPR, 0);
  try
    DataId := Info.GetValue<string>('dataId', '');
    Assert.IsFalse(DataId = '',
      'dataBreakpointInfo refused an expression naming a real cell: ' +
      Info.GetValue<string>('description', ''));
    // The element is a Byte: the width must come from what the expression
    // DENOTES, not from the pointer width a bare address would default to.
    Assert.IsTrue(Info.GetValue<string>('description', '').Contains('1 bytes'),
      'the width must follow the element type: ' +
      Info.GetValue<string>('description', ''));
  finally
    Info.Free;
  end;

  var Stopped := ArmAndContinue(DataId);
  try
    Assert.AreEqual('data breakpoint', Stopped.GetValue<string>('reason', ''),
      'the write to the last element did not report a data-breakpoint stop');
    var Desc := Stopped.GetValue<string>('description', '');
    Assert.IsTrue(Desc.Contains('GDataBpBuffer.Data['),
      'the stop must name the EXPRESSION the user watched, not the address it ' +
      'resolved to: ' + Desc);
    Assert.IsTrue(Desc.Contains('$0 -> $2'),
      'the stop must carry old -> new (0 -> 2): ' + Desc);
  finally
    Stopped.Free;
  end;
end;

procedure TDataBpExpressionTests.AddressForm_ByteAfterTheBuffer_ArmsAndFires;
begin
  StartAtArmMarker;

  var DataId: string := '';
  var Info := FClient.DataBreakpointInfoAtAddress('@GDataBpBuffer.After', 1);
  try
    DataId := Info.GetValue<string>('dataId', '');
    Assert.IsFalse(DataId = '',
      'the address form refused an expression that evaluates to an address: ' +
      Info.GetValue<string>('description', ''));
  finally
    Info.Free;
  end;

  var Stopped := ArmAndContinue(DataId);
  try
    Assert.AreEqual('data breakpoint', Stopped.GetValue<string>('reason', ''),
      'the overrun write did not report a data-breakpoint stop');
    var Desc := Stopped.GetValue<string>('description', '');
    Assert.IsTrue(Desc.Contains('$0 -> $3'),
      'the stop must carry old -> new (0 -> 3): ' + Desc);
    Assert.IsTrue(Desc.Contains('thread '),
      'the stop must name the thread that wrote the byte -- usually the whole ' +
      'answer to "who did this": ' + Desc);
  finally
    Stopped.Free;
  end;
end;

procedure TDataBpExpressionTests.AddressForm_UnsupportedWidth_Refused;
begin
  StartAtArmMarker;

  var Info := FClient.DataBreakpointInfoAtAddress('@GDataBpBuffer.After', 3);
  try
    Assert.IsTrue(NoDataId(Info),
      '3 bytes is not a width a debug register can watch and must not be ' +
      'accepted: ' + Info.ToJSON);
    Assert.IsTrue(Info.GetValue<string>('description', '').Contains('1, 2, 4 or 8'),
      'the refusal must say which widths exist: ' +
      Info.GetValue<string>('description', ''));
  finally
    Info.Free;
  end;
end;

procedure TDataBpExpressionTests.OddAddress_ChoosesAFittingWidth_InsteadOfRefusing;
begin
  StartAtArmMarker;

  // Ask the target itself where an interior byte lives, so the test depends on
  // no assumption about the record's layout. Data[1] is one byte past Data[0]
  // and therefore has the opposite parity, whatever the record's alignment.
  var Addr: string := '';
  var Ev := FClient.Evaluate('@GDataBpBuffer.Data[1]', 0);
  try
    Addr := Ev.GetValue<string>('result', '');
  finally
    Ev.Free;
  end;
  Assert.IsFalse(Addr = '', 'could not take the address of an array element');

  var Info := FClient.DataBreakpointInfo(Addr, 0);
  try
    Assert.IsFalse(Info.GetValue<string>('dataId', '') = '',
      'a literal address must not be refused for alignment against a width ' +
      'nobody asked for: ' + Info.GetValue<string>('description', ''));
  finally
    Info.Free;
  end;
end;

procedure TDataBpExpressionTests.OddAddress_WithExplicitWiderWidth_Refused;
begin
  StartAtArmMarker;

  var Addr: string := '';
  var Ev := FClient.Evaluate('@GDataBpBuffer.Data[1]', 0);
  try
    Addr := Ev.GetValue<string>('result', '');
  finally
    Ev.Free;
  end;
  Assert.IsFalse(Addr = '', 'could not take the address of an array element');

  // 8 bytes at Data[1]: whatever the record's alignment, Data[1] cannot be
  // 8-aligned at the same time as Data[0] is. A width the caller NAMED is
  // honoured strictly -- narrowing it silently would watch a different cell
  // than the one asked for.
  var Info := FClient.DataBreakpointInfoAtAddress(Addr, 8);
  try
    Assert.IsTrue(NoDataId(Info),
      'an explicitly requested width that the address is not aligned to must ' +
      'be refused, not narrowed: ' + Info.ToJSON);
    Assert.IsTrue(Info.GetValue<string>('description', '').Contains('aligned'),
      'the refusal must say it is about alignment: ' +
      Info.GetValue<string>('description', ''));
  finally
    Info.Free;
  end;
end;

procedure TDataBpExpressionTests.UnknownBareName_StillRefusedAsASymbol;
begin
  StartAtArmMarker;

  var Info := FClient.DataBreakpointInfo('NoSuchGlobalAnywhere', 0);
  try
    Assert.IsTrue(NoDataId(Info),
      'an unknown name must not resolve to anything: ' + Info.ToJSON);
    Assert.IsTrue(Info.GetValue<string>('description', '').Contains('unresolved symbol'),
      'an unknown bare NAME must stay an unresolved symbol rather than be ' +
      'reinterpreted as an expression: ' + Info.GetValue<string>('description', ''));
  finally
    Info.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDataBpExpressionTests);

end.
