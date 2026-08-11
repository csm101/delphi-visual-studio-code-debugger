unit MemoryDapTests;

// DAP-layer plumbing for `readMemory`/`writeMemory` and `memoryReference` on
// variables (ASSEMBLY_LEVEL_DEBUGGING.md increment 3). The engine primitives
// (IDebugTarget.ReadCodeMemoryAt / WriteMemoryPartial) are the SAME ones the
// MCP `read_memory`/`write_memory` tools and the `disassemble` request already
// use -- their truncate-at-region-boundary and INT3-restoring behaviour is
// proven elsewhere (DisassemblerTests.pas, InstructionStepTests.pas). This
// file proves the THIN layer on top: does the DAP request reach the engine
// with the right address/count, does a truncated read come back as a PARTIAL
// success (`unreadableBytes`) rather than a failure, does a rejected write
// report itself as a REFUSAL (never a silent no-op or a false success), and
// does a variable's `memoryReference` actually point at the address that
// backs its displayed value.
//
// Bitness scope: the read/write positive scenarios (does the byte round-trip
// through the wire at all) run on both bitnesses. Everything else here is
// plain JSON glue with no bitness-sensitive content -- same scoping call
// InstructionStepDapTests.pas already recorded for its own JSON-glue tests.

interface

uses
  DUnitX.TestFramework, DapClient;

type
  [TestFixture]
  TMemoryDapTests = class
  private
    FClient: TDapClient;
    procedure OpenSampleAt(const Bitness, Marker: string;
                ClientSupportsMemoryEvent: Boolean = True);
  public
    [TearDown] procedure TearDown;

    [Test] procedure Capability_SupportsReadWriteMemoryRequest_IsAdvertised;
    // The switch the VS Code extension passes because it ships its own memory
    // view: it withdraws the two CAPABILITIES (which is what removes the
    // editor's built-in pane) without disabling the REQUESTS, which the
    // extension reaches through customRequest.
    [Test] procedure NoStockMemoryView_WithdrawsCapabilities_ButServesTheRequests;

    [Test] procedure X64_ReadMemory_LocalVariable_MatchesDisplayedValue;
    [Test] procedure Win32_ReadMemory_LocalVariable_MatchesDisplayedValue;
    [Test] procedure X64_WriteMemory_LocalVariable_ChangesVisibleValue;
    [Test] procedure Win32_WriteMemory_LocalVariable_ChangesVisibleValue;

    [Test] procedure Variables_LocalCarriesMemoryReference_RegistersScopeDoesNot;

    // "View Binary Data" on anything with a derivable address: a reference-typed
    // variable must point at its PAYLOAD (the characters, the elements), and a
    // watch row must carry a memoryReference at all -- until this increment only
    // the Variables view had one, so a string could be dumped from Locals and
    // not from Watch, and what it dumped was the pointer.
    [Test] procedure Variables_StringLocal_MemoryReferencePointsAtCharacters;
    [Test] procedure Variables_DynArrayLocal_MemoryReferencePointsAtElements;
    [Test] procedure Evaluate_StringWatch_CarriesSameMemoryReferenceAsLocals;
    [Test] procedure Evaluate_Rvalue_CarriesNoMemoryReference;
    // A row that is a CHILD of an expansion -- a field of an object, an element
    // of an array -- follows the same rule as a local. It did not: the payload
    // rule was applied where locals are built and nowhere else, so expanding an
    // object and opening its string field showed the pointer.
    [Test] procedure Variables_StringFieldOfObject_PointsAtItsCharacters;

    // An open hex pane goes stale silently: nothing in DAP tells a client that
    // target MEMORY changed except the `memory` event, so without these the view
    // keeps showing the bytes it read when it was opened -- through a resume, a
    // stop, and a value the user typed into the Variables panel.
    [Test] procedure MemoryEvent_AfterResumeAndStop_NamesTheOpenView;
    [Test] procedure MemoryEvent_AfterSetVariable_NamesTheOpenView;
    [Test] procedure MemoryEvent_NotSentWhenClientDidNotDeclareIt;

    // `delphiMemoryExtent` (custom): what a memoryReference refers to, so the
    // extension's memory view can mark where the value starts and ends. No
    // standard DAP request carries a value's byte extent.
    [Test] procedure MemoryExtent_IntegerLocal_ReportsItsDeclaredWidth;
    [Test] procedure MemoryExtent_StringLocal_ReportsTheCharacterBytes;
    [Test] procedure MemoryExtent_UnknownReference_SaysSoInsteadOfGuessing;
    [Test] procedure MemoryExtent_ExtendedLocal_UsesTheLanguageWidthNotTheTypeTable;
    [Test] procedure MemoryExtent_NilClassLocal_ReportsThePointerSlot;

    [Test] procedure ReadMemory_UnmappedAddress_ReportsUnreadableBytesNotFailure;
    [Test] procedure ReadMemory_InvalidMemoryReference_Refused;
    [Test] procedure ReadMemory_MissingCount_Refused;
    [Test] procedure ReadMemory_RefusedWhenNotLaunched;

    [Test] procedure WriteMemory_UnwritableAddress_RefusedWithoutAllowPartial;
    [Test] procedure WriteMemory_UnwritableAddress_AllowPartial_ReportsZeroBytesWritten;
    [Test] procedure WriteMemory_MissingData_Refused;
    [Test] procedure WriteMemory_RefusedWhenNotLaunched;
  end;

implementation

uses
  System.SysUtils, System.StrUtils, System.JSON, System.NetEncoding;

const
  SAMPLE_SOURCE = 'InstructionStepSample.dpr';
  // Reserved null-page region: never MEM_COMMIT for any usermode process, on
  // either bitness. A deterministic "definitely not there" address, not a
  // guess -- the same role Win32's guard page plays for the disassembler's
  // own boundary-truncation tests.
  UNMAPPED_ADDR = '0x10';

function RepoRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function SamplePath: string;
begin
  Result := TargetDir + SAMPLE_SOURCE;
end;

function SampleExe(const Bitness: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\InstructionStepSample.exe';
end;

function SampleMap(const Bitness: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\InstructionStepSample.map';
end;

function SampleRsm(const Bitness: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\InstructionStepSample.rsm';
end;

function AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

{ ------------------------------------------------------------------ setup -- }

procedure TMemoryDapTests.OpenSampleAt(const Bitness, Marker: string;
  ClientSupportsMemoryEvent: Boolean = True);
begin
  var Line := FindBpLine(SamplePath, Marker);
  Assert.IsTrue(Line > 0, 'marker ' + Marker + ' not found in ' + SAMPLE_SOURCE);
  Assert.IsTrue(FileExists(SampleExe(Bitness)),
    'fixture not built: ' + SampleExe(Bitness));

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize(ClientSupportsMemoryEvent).Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  FClient.SetBreakpoints(SamplePath, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(SampleExe(Bitness), SampleMap(Bitness), SampleRsm(Bitness), TargetDir).Free;
  FClient.ConfigDone.Free;

  var Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      Format('%s: did not stop at %s (line %d)', [Bitness, Marker, Line]));
  finally
    Stopped.Free;
  end;
end;

procedure TMemoryDapTests.TearDown;
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

{ ---------------------------------------------------- shared local lookup -- }

// `X` at INSTR_MULTI: the breakpoint sits ON the multi-instruction line, so it
// has not run yet -- X is still the 7 the PRECEDING statement assigned
// (InstructionStepSample.dpr: `X := 7;` then `X := (X * 3) + ...  // {BP:INSTR_MULTI}`).
// A plain Integer stack local under this sample's `{$O-}` build, so it is
// always stack-resident (never register-allocated) -- a real, stable address
// on both bitnesses.
function FindLocalX(Client: TDapClient): TJSONObject;
begin
  var FrameId := Client.GetFrameId;
  var LocalsRef := Client.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0, 'no Locals scope');
  Result := Client.FindVar(LocalsRef, 'X');
  Assert.IsTrue(Result <> nil, '"X" not found in Locals');
end;

{ ---------------------------------------------------------------- tests ---- }

procedure TMemoryDapTests.Capability_SupportsReadWriteMemoryRequest_IsAdvertised;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  var InitResp := FClient.Initialize;
  try
    Assert.IsTrue(InitResp.GetValue<Boolean>('supportsReadMemoryRequest', False),
      'initialize response did not advertise supportsReadMemoryRequest');
    Assert.IsTrue(InitResp.GetValue<Boolean>('supportsWriteMemoryRequest', False),
      'initialize response did not advertise supportsWriteMemoryRequest');
  finally
    InitResp.Free;
  end;
end;

procedure RunReadMemoryLocalVariableMatchesDisplayedValue(const Bitness: string;
  Client: TDapClient);
begin
  var XVar := FindLocalX(Client);
  var MemRef: string;
  try
    MemRef := XVar.GetValue<string>('memoryReference', '');
  finally
    XVar.Free;
  end;
  Assert.IsTrue(MemRef <> '',
    Format('%s: local "X" carries no memoryReference -- it is a real stack local ' +
           'under -O-, this should never be empty', [Bitness]));

  var Resp := Client.ReadMemory(MemRef, 4);
  try
    Assert.AreEqual(0, Resp.GetValue<Integer>('unreadableBytes', 0),
      Format('%s: a 4-byte read of a live stack slot reported unreadable bytes', [Bitness]));
    var DataStr := Resp.GetValue<string>('data', '');
    Assert.IsTrue(DataStr <> '', Format('%s: readMemory returned no data', [Bitness]));
    var Bytes := TNetEncoding.Base64String.DecodeStringToBytes(DataStr);
    Assert.AreEqual(4, Integer(Length(Bytes)), Format('%s: expected 4 bytes back', [Bitness]));
    // Little-endian Integer 7: 07 00 00 00.
    Assert.AreEqual<Byte>(7, Bytes[0], Format('%s: byte 0', [Bitness]));
    Assert.AreEqual<Byte>(0, Bytes[1], Format('%s: byte 1', [Bitness]));
    Assert.AreEqual<Byte>(0, Bytes[2], Format('%s: byte 2', [Bitness]));
    Assert.AreEqual<Byte>(0, Bytes[3], Format('%s: byte 3', [Bitness]));
  finally
    Resp.Free;
  end;
end;

procedure TMemoryDapTests.X64_ReadMemory_LocalVariable_MatchesDisplayedValue;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  RunReadMemoryLocalVariableMatchesDisplayedValue('Win64', FClient);
end;

procedure TMemoryDapTests.Win32_ReadMemory_LocalVariable_MatchesDisplayedValue;
begin
  OpenSampleAt('Win32', 'INSTR_MULTI');
  RunReadMemoryLocalVariableMatchesDisplayedValue('Win32', FClient);
end;

procedure RunWriteMemoryLocalVariableChangesVisibleValue(const Bitness: string;
  Client: TDapClient);
begin
  var XVar := FindLocalX(Client);
  var MemRef: string;
  var LocalsRef: Integer;
  try
    MemRef := XVar.GetValue<string>('memoryReference', '');
  finally
    XVar.Free;
  end;
  Assert.IsTrue(MemRef <> '', Format('%s: local "X" carries no memoryReference', [Bitness]));

  // Little-endian Integer 42: 2A 00 00 00.
  var NewBytes: TBytes := [42, 0, 0, 0];
  var Resp := Client.WriteMemory(MemRef, TNetEncoding.Base64String.EncodeBytesToString(NewBytes));
  Resp.Free;

  LocalsRef := Client.GetLocalsRef(Client.GetFrameId);
  var NewVal := Client.VarValue(LocalsRef, 'X');
  Assert.IsTrue(ContainsText(NewVal, '(0x2a)'),
    Format('%s: X did not show 42 after writeMemory -- got "%s"', [Bitness, NewVal]));
end;

procedure TMemoryDapTests.X64_WriteMemory_LocalVariable_ChangesVisibleValue;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  RunWriteMemoryLocalVariableChangesVisibleValue('Win64', FClient);
end;

procedure TMemoryDapTests.Win32_WriteMemory_LocalVariable_ChangesVisibleValue;
begin
  OpenSampleAt('Win32', 'INSTR_MULTI');
  RunWriteMemoryLocalVariableChangesVisibleValue('Win32', FClient);
end;

// A register-resident value has no memory slot at all -- the Registers scope
// never goes through EmitVar (DapServer.HandleVariables builds those rows
// directly), so it is the one place in the existing wire format guaranteed
// to carry no memoryReference. Proves the omission side of the "if in doubt,
// omit" rule, not just the presence side the read/write tests above prove.
procedure TMemoryDapTests.Variables_LocalCarriesMemoryReference_RegistersScopeDoesNot;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');

  var XVar := FindLocalX(FClient);
  try
    Assert.IsTrue(XVar.GetValue<string>('memoryReference', '') <> '',
      'local "X" should carry a memoryReference');
  finally
    XVar.Free;
  end;

  var FrameId := FClient.GetFrameId;
  var ScopesResp := FClient.Scopes(FrameId);
  var RegistersRef := 0;
  try
    var Arr := ScopesResp.GetValue('scopes') as TJSONArray;
    Assert.IsTrue(Arr <> nil, 'no scopes array');
    for var I := 0 to Arr.Count - 1 do begin
      var S := Arr[I] as TJSONObject;
      if SameText(S.GetValue<string>('name', ''), 'Registers') then
        RegistersRef := S.GetValue<Integer>('variablesReference', 0);
    end;
  finally
    ScopesResp.Free;
  end;
  Assert.IsTrue(RegistersRef > 0, 'no Registers scope');

  var RegsResp := FClient.Variables(RegistersRef);
  try
    var Arr := RegsResp.GetValue('variables') as TJSONArray;
    Assert.IsTrue((Arr <> nil) and (Arr.Count > 0), 'Registers scope returned no rows');
    for var I := 0 to Arr.Count - 1 do begin
      var R := Arr[I] as TJSONObject;
      Assert.IsFalse(R.FindValue('memoryReference') <> nil,
        Format('register "%s" carries a memoryReference -- a register is not a memory address',
          [R.GetValue<string>('name', '?')]));
    end;
  finally
    RegsResp.Free;
  end;
end;

{ ------------------------- memoryReference on reference-typed values ------- }

// Reads Count bytes at MemRef and returns them, asserting the read was whole.
function ReadBytesAt(Client: TDapClient; const MemRef: string;
  Count: Integer; const Whose: string): TBytes;
begin
  Assert.IsTrue(MemRef <> '', Whose + ': no memoryReference');
  var Resp := Client.ReadMemory(MemRef, Count);
  try
    Assert.AreEqual(0, Resp.GetValue<Integer>('unreadableBytes', 0),
      Whose + ': the payload address was not fully readable');
    Result := TNetEncoding.Base64String.DecodeStringToBytes(
                Resp.GetValue<string>('data', ''));
  finally
    Resp.Free;
  end;
  Assert.AreEqual(Count, Integer(Length(Result)), Whose + ': short read');
end;

function MemRefOfLocal(Client: TDapClient; const Name: string): string;
begin
  var V := Client.FindVar(Client.GetLocalsRef(Client.GetFrameId), Name);
  Assert.IsTrue(V <> nil, '"' + Name + '" not found in Locals');
  try
    Result := V.GetValue<string>('memoryReference', '');
  finally
    V.Free;
  end;
end;

// A `string` local occupies one POINTER. Dumping the slot shows that pointer;
// what the user asked for is the text. RED before this increment: the
// memoryReference was the slot, so these six bytes came back as the low half of
// an address instead of 'Hex' in UTF-16.
procedure TMemoryDapTests.Variables_StringLocal_MemoryReferencePointsAtCharacters;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var Bytes := ReadBytesAt(FClient, MemRefOfLocal(FClient, 'Text'), 6, 'string local "Text"');
  Assert.AreEqual('H', Char(Bytes[0]), 'first character');
  Assert.AreEqual(#0,  Char(Bytes[1]), 'UTF-16: the high byte of an ASCII character is 0');
  Assert.AreEqual('e', Char(Bytes[2]), 'second character');
  Assert.AreEqual('x', Char(Bytes[4]), 'third character');
end;

// Same rule for a dynamic array: the slot is a pointer to the ELEMENTS, and the
// elements are what a memory view exists to show.
procedure TMemoryDapTests.Variables_DynArrayLocal_MemoryReferencePointsAtElements;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var Bytes := ReadBytesAt(FClient, MemRefOfLocal(FClient, 'Buf'), 4, 'TBytes local "Buf"');
  Assert.AreEqual($11, Integer(Bytes[0]), 'element 0');
  Assert.AreEqual($22, Integer(Bytes[1]), 'element 1');
  Assert.AreEqual($33, Integer(Bytes[2]), 'element 2');
  Assert.AreEqual($44, Integer(Bytes[3]), 'element 3');
end;

// The watch panel is where a debugger user actually looks at a value they went
// hunting for, and until this increment an `evaluate` response carried no
// memoryReference at all -- so VS Code offered no memory view there. It must
// resolve to the SAME address the Locals row resolves to: two panes showing one
// variable must not disagree about where it lives.
procedure TMemoryDapTests.Evaluate_StringWatch_CarriesSameMemoryReferenceAsLocals;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var FromLocals := MemRefOfLocal(FClient, 'Text');
  Assert.IsTrue(FromLocals <> '', 'Locals row for "Text" carries no memoryReference');

  var Resp := FClient.Evaluate('Text', FClient.GetFrameId, 'watch');
  try
    Assert.AreEqual(FromLocals, Resp.GetValue<string>('memoryReference', ''),
      'the watch row and the Locals row must name the same address');
  finally
    Resp.Free;
  end;
end;

// An rvalue has no storage anywhere in the debuggee. Offering a memory view on
// it would open one on whatever number the arithmetic produced -- the omission
// side of the rule, and the reason the address is not simply "the value".
procedure TMemoryDapTests.Evaluate_Rvalue_CarriesNoMemoryReference;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var Resp := FClient.Evaluate('Length(Text) + 1', FClient.GetFrameId, 'watch');
  try
    // The integer rendering carries the hex form too ('4  (0x4)'), which is the
    // Variables view's own format -- assert it STARTS with the value rather
    // than pinning the decoration, which is not what this test is about.
    Assert.IsTrue(Resp.GetValue<string>('result', '').StartsWith('4'),
      'precondition: the expression itself must evaluate, got: ' +
      Resp.GetValue<string>('result', ''));
    Assert.IsTrue(Resp.FindValue('memoryReference') = nil,
      'a computed value has no address and must carry no memoryReference');
  finally
    Resp.Free;
  end;
end;

{ ------------------------------- memory events for an open hex pane -------- }

// Opens a view the way a client does -- by reading through the variable's
// memoryReference -- and returns that reference.
function OpenMemoryViewOnLocalX(Client: TDapClient): string;
begin
  var XVar := FindLocalX(Client);
  try
    Result := XVar.GetValue<string>('memoryReference', '');
  finally
    XVar.Free;
  end;
  Assert.IsTrue(Result <> '', 'local "X" carries no memoryReference');
  Client.ReadMemory(Result, 4).Free;
end;

// Resume, stop again: the target ran, so anything an open pane is showing may
// have changed. RED before this increment -- no `memory` event existed at all,
// and the pane in VS Code kept its original bytes on screen.
procedure TMemoryDapTests.MemoryEvent_AfterResumeAndStop_NamesTheOpenView;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var MemRef := OpenMemoryViewOnLocalX(FClient);

  // Move the breakpoint further down the SAME routine, so X's frame -- and
  // therefore the address the view is open on -- is still alive at the next stop.
  var NextLine := FindBpLine(SamplePath, 'INSTR_CALLSITE_NEXT');
  Assert.IsTrue(NextLine > 0, 'marker INSTR_CALLSITE_NEXT not found');
  FClient.SetBreakpoints(SamplePath, [NextLine]).Free;
  FClient.Continue_.Free;
  FClient.WaitForStopped.Free;

  var Body: TJSONObject;
  Assert.IsTrue(FClient.TryWaitForEvent('memory', 8000, Body),
    'no memory event after the resume/stop -- an open view would never refresh');
  try
    Assert.AreEqual(MemRef, Body.GetValue<string>('memoryReference', ''),
      'the event must name the reference the view was opened on');
    Assert.IsTrue(Body.GetValue<Integer>('count', 0) >= 4,
      'the event must cover at least the bytes that were read');
  finally
    Body.Free;
  end;
end;

// A write the DEBUGGER performed: nothing in the debuggee ran, so a client has
// no other reason to suspect the bytes moved.
procedure TMemoryDapTests.MemoryEvent_AfterSetVariable_NamesTheOpenView;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var MemRef := OpenMemoryViewOnLocalX(FClient);

  var LocalsRef := FClient.GetLocalsRef(FClient.GetFrameId);
  FClient.SetVariable(LocalsRef, 'X', '99').Free;

  var Body: TJSONObject;
  Assert.IsTrue(FClient.TryWaitForEvent('memory', 8000, Body),
    'no memory event after setVariable -- the pane keeps showing the old value');
  try
    Assert.AreEqual(MemRef, Body.GetValue<string>('memoryReference', ''),
      'the event must name the reference the view was opened on');
  finally
    Body.Free;
  end;
end;

// The gate. A client that never declared `supportsMemoryEvent` must not be sent
// one -- the spec lets it treat an undeclared event as a protocol error, and
// "we only ever tested it with a client that declares everything" is how an
// adapter ends up broken against a real one.
procedure TMemoryDapTests.MemoryEvent_NotSentWhenClientDidNotDeclareIt;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI', {ClientSupportsMemoryEvent=}False);
  OpenMemoryViewOnLocalX(FClient);

  var LocalsRef := FClient.GetLocalsRef(FClient.GetFrameId);
  FClient.SetVariable(LocalsRef, 'X', '99').Free;

  var Body: TJSONObject;
  Assert.IsFalse(FClient.TryWaitForEvent('memory', 1500, Body),
    'a memory event was sent to a client that never declared supportsMemoryEvent');
  if Body <> nil then
    Body.Free;
end;

// The editor's built-in memory pane is driven purely by these two capabilities,
// so withdrawing them is what makes its inline icon go away. What must NOT go
// away is the ability to read and write memory: the extension's own view uses
// the same requests through customRequest, which no capability gates.
procedure TMemoryDapTests.NoStockMemoryView_WithdrawsCapabilities_ButServesTheRequests;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe, '--no-stock-memory-view');
  var InitResp := FClient.Initialize;
  try
    Assert.IsFalse(InitResp.GetValue<Boolean>('supportsReadMemoryRequest', False),
      'the switch must withdraw supportsReadMemoryRequest');
    Assert.IsFalse(InitResp.GetValue<Boolean>('supportsWriteMemoryRequest', False),
      'the switch must withdraw supportsWriteMemoryRequest');
    // Everything else stays: withdrawing the pane must not cost the Disassembly
    // View or the watchpoint menu entries.
    Assert.IsTrue(InitResp.GetValue<Boolean>('supportsDisassembleRequest', False),
      'unrelated capabilities must be untouched');
  finally
    InitResp.Free;
  end;

  var Line := FindBpLine(SamplePath, 'INSTR_MULTI');
  FClient.SetBreakpoints(SamplePath, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(SampleExe('Win64'), SampleMap('Win64'), SampleRsm('Win64'), TargetDir).Free;
  FClient.ConfigDone.Free;
  FClient.WaitForStopped.Free;

  // The row still carries its address, and the request behind the view still
  // answers -- the capability is about the EDITOR's pane, not about the engine.
  var MemRef := MemRefOfLocal(FClient, 'X');
  Assert.IsTrue(MemRef <> '', 'a variable must still carry its memoryReference');
  var Bytes := ReadBytesAt(FClient, MemRef, 4, 'local "X" with the stock view withdrawn');
  Assert.AreEqual(7, Integer(Bytes[0]), 'X is 7 at this marker');
end;

{ ------------------------------------ delphiMemoryExtent (custom request) -- }

function ExtentOf(Client: TDapClient; const MemRef: string): TJSONObject;
begin
  var Seq := Client.SendRequest('delphiMemoryExtent',
               Format('{"memoryReference":"%s"}', [MemRef]));
  var Resp := Client.WaitRawResponse(Seq);
  try
    Assert.IsTrue(Resp.GetValue<Boolean>('success', False),
      'delphiMemoryExtent failed for ' + MemRef);
    Result := TJSONObject.ParseJSONValue(
                (Resp.GetValue('body') as TJSONObject).ToJSON) as TJSONObject;
  finally
    Resp.Free;
  end;
end;

// A plain Integer: four bytes, from the declared type. This is the size the
// view draws as the variable's extent, so it must come from the type table
// rather than from how many bytes anyone happened to read.
procedure TMemoryDapTests.MemoryExtent_IntegerLocal_ReportsItsDeclaredWidth;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Body := ExtentOf(FClient, MemRefOfLocal(FClient, 'X'));
  try
    Assert.AreEqual(4, Body.GetValue<Integer>('size', 0),
      'an Integer local occupies four bytes');
    Assert.AreEqual('X', Body.GetValue<string>('name', ''), 'the extent names the variable');
  finally
    Body.Free;
  end;
end;

// A string: the extent is the CHARACTERS, read from the string header
// (Length * ElemSize), not the pointer slot's width and not the header itself.
// 'Hex' is three UTF-16 characters, so six bytes.
procedure TMemoryDapTests.MemoryExtent_StringLocal_ReportsTheCharacterBytes;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var Body := ExtentOf(FClient, MemRefOfLocal(FClient, 'Text'));
  try
    Assert.AreEqual(6, Body.GetValue<Integer>('size', 0),
      '''Hex'' is 3 characters of 2 bytes each');
  finally
    Body.Free;
  end;
end;

// A reference the adapter never handed out. Answering with a size would be an
// invention; the request says so instead, and the view then highlights nothing.
procedure TMemoryDapTests.MemoryExtent_UnknownReference_SaysSoInsteadOfGuessing;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Body := ExtentOf(FClient, '0xDEADBEEF');
  try
    Assert.IsTrue(Body.GetValue<Boolean>('unknownReference', False),
      'an unknown reference must be reported as unknown, not given a size');
    Assert.IsTrue(Body.FindValue('size') = nil,
      'an unknown reference must carry no size at all');
  finally
    Body.Free;
  end;
end;

// `Extended` is 8 bytes on Win64 (an alias for Double) and 10 on Win32, so the
// LANGUAGE answers it and the per-unit type table is not asked. Measured
// motivation: a real session reported an Extended local as 121 bytes, which a
// memory view would have drawn as 121 bytes of the variable -- most of them
// belonging to whatever sits next to it on the stack.
procedure TMemoryDapTests.MemoryExtent_ExtendedLocal_UsesTheLanguageWidthNotTheTypeTable;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var Body := ExtentOf(FClient, MemRefOfLocal(FClient, 'Wide'));
  try
    Assert.AreEqual(8, Body.GetValue<Integer>('size', 0),
      'Extended is a Double on Win64');
  finally
    Body.Free;
  end;
end;

// A nil class reference has no instance to measure, but the variable is still a
// pointer-wide slot and that slot is exactly what the view is opened on.
// Reporting "unknown" there left the commonest row in the panel unhighlighted.
procedure TMemoryDapTests.MemoryExtent_NilClassLocal_ReportsThePointerSlot;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');
  var Body := ExtentOf(FClient, MemRefOfLocal(FClient, 'Obj'));
  try
    Assert.AreEqual(8, Body.GetValue<Integer>('size', 0),
      'a nil object reference occupies one 64-bit pointer');
  finally
    Body.Free;
  end;
end;

// Holder is a live object whose FText field holds 'Chars'. Expanding it and
// asking for the field's memory must reach the five characters, not the eight
// bytes of pointer that refer to them -- and the extent must say 10, which the
// string header reports rather than what the field slot measures. The payload
// rule used to be applied where LOCALS are built and nowhere else, so every
// row inside an expansion pointed at its pointer.
procedure TMemoryDapTests.Variables_StringFieldOfObject_PointsAtItsCharacters;
begin
  OpenSampleAt('Win64', 'INSTR_MEMREF');

  var HolderVar := FClient.FindVar(FClient.GetLocalsRef(FClient.GetFrameId), 'Holder');
  Assert.IsTrue(HolderVar <> nil, '"Holder" not found in Locals');
  var ChildrenRef := 0;
  try
    ChildrenRef := HolderVar.GetValue<Integer>('variablesReference', 0);
  finally
    HolderVar.Free;
  end;
  Assert.IsTrue(ChildrenRef > 0, 'Holder should be expandable');

  var Field := FClient.FindVar(ChildrenRef, 'FText');
  Assert.IsTrue(Field <> nil, 'FText not found among Holder''s members');
  var MemRef: string;
  try
    MemRef := Field.GetValue<string>('memoryReference', '');
  finally
    Field.Free;
  end;

  var Bytes := ReadBytesAt(FClient, MemRef, 10, 'string field "FText"');
  Assert.AreEqual('C', Char(Bytes[0]), 'first character');
  Assert.AreEqual(#0,  Char(Bytes[1]), 'UTF-16 high byte');
  Assert.AreEqual('h', Char(Bytes[2]), 'second character');
  Assert.AreEqual('s', Char(Bytes[8]), 'fifth character');

  var Body := ExtentOf(FClient, MemRef);
  try
    Assert.AreEqual(10, Body.GetValue<Integer>('size', 0),
      '''Chars'' is 5 characters of 2 bytes each');
  finally
    Body.Free;
  end;
end;

// The null-page region: VirtualQueryEx reports it MEM_FREE, never MEM_COMMIT,
// for any usermode process. ReadCodeMemoryAt's existing truncation rule
// (DebugTarget.IDebugTarget.ReadCodeMemoryAt, already proven at the engine
// level) then returns 0 bytes -- and that must surface as a PARTIAL success
// (unreadableBytes = count, no `data`), never as a failed request. Running
// off the end of mapped memory is a normal thing to ask for, not an error.
procedure TMemoryDapTests.ReadMemory_UnmappedAddress_ReportsUnreadableBytesNotFailure;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Resp := FClient.ReadMemory(UNMAPPED_ADDR, 16);
  try
    Assert.AreEqual(16, Resp.GetValue<Integer>('unreadableBytes', 0),
      'a read entirely inside the null page should report all bytes unreadable');
    Assert.IsFalse(Resp.FindValue('data') <> nil,
      'no bytes were readable -- there should be no `data` field at all');
  finally
    Resp.Free;
  end;
end;

procedure TMemoryDapTests.ReadMemory_InvalidMemoryReference_Refused;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Resp := FClient.ReadMemoryRaw('not-an-address', 4);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'a malformed memoryReference should be refused, not silently read from address 0');
  finally
    Resp.Free;
  end;
end;

// `count` is a REQUIRED field (DAP spec, ReadMemoryArguments). A request that
// omits it must be refused, not silently treated as count=0 -- an absent
// required field is a malformed request, not "read nothing".
procedure TMemoryDapTests.ReadMemory_MissingCount_Refused;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Seq := FClient.SendRequest('readMemory', '{"memoryReference":"0x1000"}');
  var Resp := FClient.WaitRawResponse(Seq);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'readMemory with no "count" field should be refused');
  finally
    Resp.Free;
  end;
end;

procedure TMemoryDapTests.ReadMemory_RefusedWhenNotLaunched;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  var Resp := FClient.ReadMemoryRaw('0x1000', 4);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'a readMemory before launch was accepted -- there is nothing to read');
  finally
    Resp.Free;
  end;
end;

// Writing 4 bytes into the null page: WriteMemoryPartial reports 0 bytes
// landed (VirtualProtectEx/WriteProcessMemory both fail against an
// uncommitted region). Without allowPartial the caller did not opt into a
// partial outcome, so this must come back as a REFUSAL -- never as a quiet
// success that leaves the caller believing 4 bytes changed when 0 did.
procedure TMemoryDapTests.WriteMemory_UnwritableAddress_RefusedWithoutAllowPartial;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Payload := TNetEncoding.Base64String.EncodeBytesToString(TBytes.Create(1, 2, 3, 4));
  var Resp := FClient.WriteMemoryRaw(UNMAPPED_ADDR, Payload);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'a write into the null page without allowPartial should be refused');
  finally
    Resp.Free;
  end;
end;

// Same write, but the caller explicitly accepted a partial outcome: the
// request must succeed and truthfully report zero bytes written, not the
// 4 that were requested.
procedure TMemoryDapTests.WriteMemory_UnwritableAddress_AllowPartial_ReportsZeroBytesWritten;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Payload := TNetEncoding.Base64String.EncodeBytesToString(TBytes.Create(1, 2, 3, 4));
  var Resp := FClient.WriteMemory(UNMAPPED_ADDR, Payload, 0, True);
  try
    Assert.AreEqual(0, Resp.GetValue<Integer>('bytesWritten', -1),
      'allowPartial write into the null page should report bytesWritten=0');
  finally
    Resp.Free;
  end;
end;

// `data` is a REQUIRED field (DAP spec, WriteMemoryArguments). Omitting it
// must be refused, not silently treated as "write zero bytes" -- a caller
// that forgot the payload gets told so, not a quiet vacuous success.
procedure TMemoryDapTests.WriteMemory_MissingData_Refused;
begin
  OpenSampleAt('Win64', 'INSTR_MULTI');
  var Seq := FClient.SendRequest('writeMemory', '{"memoryReference":"0x1000"}');
  var Resp := FClient.WaitRawResponse(Seq);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'writeMemory with no "data" field should be refused');
  finally
    Resp.Free;
  end;
end;

procedure TMemoryDapTests.WriteMemory_RefusedWhenNotLaunched;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  var Payload := TNetEncoding.Base64String.EncodeBytesToString(TBytes.Create(1, 2, 3, 4));
  var Resp := FClient.WriteMemoryRaw('0x1000', Payload);
  try
    Assert.IsFalse(Resp.GetValue<Boolean>('success', True),
      'a writeMemory before launch was accepted -- there is nothing to write to');
  finally
    Resp.Free;
  end;
end;

initialization
  // EXPLICIT registration: this project does not use RTTI auto-scan, and an
  // unregistered fixture silently never runs (TRAPS.md).
  TDUnitX.RegisterTestFixture(TMemoryDapTests);

end.
