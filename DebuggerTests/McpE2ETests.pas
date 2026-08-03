unit McpE2ETests;

// End-to-end tests for the MCP stdio server. Spawns DelphiDebuggerMcp.exe, speaks
// newline-delimited JSON-RPC 2.0 over its stdio pipes, and drives the autonomous
// debugging workflow: initialize -> tools/list -> list processes -> launch ->
// set breakpoint -> continue_and_wait -> inspect (snapshot / locals / evaluate).

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TMcpE2ETests = class
  private
    function RepoRoot: string;
    function McpExe: string;
    function TargetDir: string;
    function TargetExe: string;
    function HostExe: string;
    function MarkerLine(const SourceBaseName, Marker: string): Integer;
  public
    [Test] procedure Initialize_And_ListTools;
    [Test] procedure ListProcesses_ReturnsEntries;
    [Test] procedure Launch_Breakpoint_Continue_Snapshot;
    [Test] procedure Evaluate_AfterStop;
    [Test] procedure ExpandVariable_ObjectFields;
    [Test] procedure ExpandVariable_PropertyGetter;
    [Test] procedure ConditionalBreakpoint_Stops;
    [Test] procedure Logpoint_EmitsToDebuggerOutput;
    [Test] procedure Bpl_Breakpoint_Stops;
    [Test] procedure SetBreakpointsPlural_Stops;
    [Test] procedure LaunchFromConfig_Stops;
    [Test] procedure Relaunch_AfterTerminate_Succeeds;
    [Test] procedure Evaluate_Object_IsExpandable;
    [Test] procedure Locals_FrameIndex_ReadsCallerFrame;
    // The raw sweep as an AGENT sees it. What matters is not that it finds
    // things -- it is that every hit says it is a position and not a caller,
    // because an agent that mistakes one for a call chain will report a routine
    // as "called this" when it merely ran earlier.
    [Test] procedure RawStackScan_HitsAreMarkedAsPositions;
    // The module list must describe the EXE on the same terms as every runtime
    // module, and must say which formats actually loaded -- an agent asking
    // "why is this frame nameless" needs "the module has no debug info" to be
    // distinguishable from "the module is not loaded".
    [Test] procedure LoadedModules_DescribeMainAndPackages;
  end;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.IOUtils;

const
  EVAL_MARKER = 'EVAL_BODY';
  EVAL_SOURCE = 'TestTargetCore.pas';

type
  // Minimal JSON-RPC-over-stdio client for the MCP server under test.
  TMcpTestClient = class
  private
    FProc:    TProcessInformation;
    FInWrite: THandle;   // we write child's stdin
    FOutRead: THandle;   // we read child's stdout
    FNextId:  Integer;
    procedure WriteLine(const S: string);
    function  ReadLine(TimeoutMs: Cardinal): string;
  public
    constructor Start(const ExePath: string);
    destructor Destroy; override;
    function Call(const Method: string; Params: TJSONObject): TJSONObject; // caller frees
    procedure Notify(const Method: string; Params: TJSONObject);
    // Calls a tool and returns the parsed JSON of its text content (caller frees).
    function CallTool(const Name: string; Args: TJSONObject): TJSONValue;
  end;

constructor TMcpTestClient.Start(const ExePath: string);
var
  Sec: TSecurityAttributes;
  ChildIn, ChildOut: THandle;
  SI: TStartupInfo;
begin
  inherited Create;
  FNextId := 1;
  Sec := Default(TSecurityAttributes);
  Sec.nLength := SizeOf(Sec);
  Sec.bInheritHandle := True;

  if not CreatePipe(ChildIn, FInWrite, @Sec, 0) then
    RaiseLastOSError;
  SetHandleInformation(FInWrite, HANDLE_FLAG_INHERIT, 0);
  if not CreatePipe(FOutRead, ChildOut, @Sec, 0) then
    RaiseLastOSError;
  SetHandleInformation(FOutRead, HANDLE_FLAG_INHERIT, 0);

  SI := Default(TStartupInfo);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput  := ChildIn;
  SI.hStdOutput := ChildOut;
  SI.hStdError  := ChildOut;

  if not CreateProcess(nil, PChar(ExePath), nil, nil, True,
       CREATE_NO_WINDOW, nil, PChar(ExtractFileDir(ExePath)), SI, FProc) then
    RaiseLastOSError;

  CloseHandle(ChildIn);
  CloseHandle(ChildOut);
end;

destructor TMcpTestClient.Destroy;
begin
  if FInWrite <> 0 then CloseHandle(FInWrite);
  if FOutRead <> 0 then CloseHandle(FOutRead);
  if FProc.hProcess <> 0 then begin
    TerminateProcess(FProc.hProcess, 0);
    CloseHandle(FProc.hThread);
    CloseHandle(FProc.hProcess);
  end;
  inherited;
end;

procedure TMcpTestClient.WriteLine(const S: string);
begin
  var Bytes := TEncoding.UTF8.GetBytes(S + #10);
  var Written: DWORD;
  WriteFile(FInWrite, Bytes[0], Length(Bytes), Written, nil);
end;

function TMcpTestClient.ReadLine(TimeoutMs: Cardinal): string;
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  var Bytes: TBytes := [];
  while True do begin
    var Avail: DWORD := 0;
    if not PeekNamedPipe(FOutRead, nil, 0, nil, @Avail, nil) then
      raise Exception.Create('MCP stdout pipe closed');
    if Avail = 0 then begin
      if GetTickCount64 > Deadline then
        raise Exception.Create('MCP read timeout');
      Sleep(2);
      Continue;
    end;
    var B: Byte;
    var Rd: DWORD;
    if not ReadFile(FOutRead, B, 1, Rd, nil) or (Rd = 0) then
      raise Exception.Create('MCP stdout read failed');
    if B = 10 then
      Break;
    if B = 13 then
      Continue;
    Bytes := Bytes + [B];
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function TMcpTestClient.Call(const Method: string; Params: TJSONObject): TJSONObject;
begin
  var Id := FNextId;
  Inc(FNextId);
  var Req := TJSONObject.Create;
  try
    Req.AddPair('jsonrpc', '2.0');
    Req.AddPair('id', TJSONNumber.Create(Id));
    Req.AddPair('method', Method);
    if Params <> nil then
      Req.AddPair('params', Params)
    else
      Req.AddPair('params', TJSONObject.Create);
    WriteLine(Req.ToJSON);
  finally
    Req.Free;
  end;

  // Read responses until the one with our id (skip any notifications).
  while True do begin
    var Line := ReadLine(60000);
    var V := TJSONObject.ParseJSONValue(Line);
    if not (V is TJSONObject) then begin
      V.Free;
      Continue;
    end;
    var Obj := TJSONObject(V);
    var IdV := Obj.GetValue('id');
    if (IdV is TJSONNumber) and (TJSONNumber(IdV).AsInt = Id) then
      Exit(Obj);
    Obj.Free;
  end;
end;

procedure TMcpTestClient.Notify(const Method: string; Params: TJSONObject);
begin
  var Req := TJSONObject.Create;
  try
    Req.AddPair('jsonrpc', '2.0');
    Req.AddPair('method', Method);
    if Params <> nil then
      Req.AddPair('params', Params);
    WriteLine(Req.ToJSON);
  finally
    Req.Free;
  end;
end;

function TMcpTestClient.CallTool(const Name: string; Args: TJSONObject): TJSONValue;
begin
  var Params := TJSONObject.Create;
  Params.AddPair('name', Name);
  if Args <> nil then
    Params.AddPair('arguments', Args)
  else
    Params.AddPair('arguments', TJSONObject.Create);
  var Resp := Call('tools/call', Params);
  try
    var ResultObj := Resp.GetValue('result') as TJSONObject;
    if ResultObj = nil then
      raise Exception.Create('tool call has no result: ' + Resp.ToJSON);
    var Content := ResultObj.GetValue('content') as TJSONArray;
    if (Content = nil) or (Content.Count = 0) then
      raise Exception.Create('tool result has no content');
    var Text := (Content.Items[0] as TJSONObject).GetValue<string>('text', '');
    Result := TJSONObject.ParseJSONValue(Text);
    if Result = nil then
      Result := TJSONString.Create(Text);  // non-JSON text (e.g. an error message)
  finally
    Resp.Free;
  end;
end;

{ TMcpE2ETests }

function TMcpE2ETests.RepoRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

function TMcpE2ETests.McpExe: string;
begin
  Result := RepoRoot + 'MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe';
end;

function TMcpE2ETests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

function TMcpE2ETests.TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

function TMcpE2ETests.HostExe: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.exe';
end;

function TMcpE2ETests.MarkerLine(const SourceBaseName, Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(TargetDir + SourceBaseName);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then
        Exit(I + 1);
  finally
    Lines.Free;
  end;
end;

procedure TMcpE2ETests.Initialize_And_ListTools;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    var Init := C.Call('initialize', nil);
    try
      Assert.IsNotNull(Init.GetValue('result'), 'initialize returned no result');
      var SrvInfo := (Init.GetValue('result') as TJSONObject).GetValue('serverInfo') as TJSONObject;
      Assert.IsNotNull(SrvInfo, 'no serverInfo');
    finally
      Init.Free;
    end;
    C.Notify('notifications/initialized', nil);

    var Tools := C.Call('tools/list', nil);
    try
      var Arr := (Tools.GetValue('result') as TJSONObject).GetValue('tools') as TJSONArray;
      Assert.IsTrue(Arr.Count >= 10, 'expected many tools, got ' + IntToStr(Arr.Count));
      var Names := '';
      for var T in Arr do
        Names := Names + (T as TJSONObject).GetValue<string>('name') + ' ';
      Assert.IsTrue(Names.Contains('launch_debuggee'), 'launch_debuggee missing');
      Assert.IsTrue(Names.Contains('continue_and_wait'), 'continue_and_wait missing');
      Assert.IsTrue(Names.Contains('attach_to_process'), 'attach_to_process missing');
    finally
      Tools.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.ListProcesses_ReturnsEntries;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    var V := C.CallTool('list_debuggable_processes', nil);
    try
      Assert.IsTrue(V is TJSONArray, 'expected a JSON array of processes');
      Assert.IsTrue(TJSONArray(V).Count > 0, 'no processes listed');
    finally
      V.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.Launch_Breakpoint_Continue_Snapshot;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found');

  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    // launch (stops at entry)
    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    // set breakpoint at EVAL_BODY
    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    // continue and wait for the breakpoint stop
    var Snap := C.CallTool('continue_and_wait', nil);
    try
      Assert.IsTrue(Snap is TJSONObject, 'snapshot not an object');
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'not stopped: ' + S.ToJSON);
      var Loc := S.GetValue('location') as TJSONObject;
      Assert.IsNotNull(Loc, 'no location in snapshot');
      Assert.AreEqual(EVAL_SOURCE, ExtractFileName(Loc.GetValue<string>('sourceFile', '')),
        'wrong source file');
      Assert.AreEqual(Line, Loc.GetValue<Integer>('line', -1), 'wrong line');
      var Locals := S.GetValue('locals') as TJSONArray;
      Assert.IsTrue((Locals <> nil) and (Locals.Count > 0), 'no locals in snapshot');
    finally
      Snap.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.Evaluate_AfterStop;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    var EvalArgs := TJSONObject.Create;
    EvalArgs.AddPair('expression', 'W.FValue');
    var R := C.CallTool('evaluate_expression', EvalArgs);
    try
      var O := TJSONObject(R);
      Assert.IsTrue(O.GetValue<Boolean>('success', False), 'evaluate failed: ' + O.ToJSON);
      Assert.IsTrue(O.GetValue<string>('value', '').Contains('42'), 'W.FValue mismatch: ' + O.ToJSON);
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.LoadedModules_DescribeMainAndPackages;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    var Mods := C.CallTool('get_loaded_modules', nil);
    try
      var Arr := Mods as TJSONArray;
      // The registry is fed by the LOAD_DLL debug events, so it is not just the
      // modules the debugger happened to load symbols for: every Windows
      // process maps ntdll, and a list of length 1 would mean the runtime
      // modules never reach it.
      Assert.IsTrue(Arr.Count >= 2,
        'only the main image was listed -- runtime modules are missing: ' + Arr.ToJSON);

      var MainCount := 0;
      var MainFormats := 0;
      for var I := 0 to Arr.Count - 1 do begin
        var O := Arr.Items[I] as TJSONObject;
        Assert.IsTrue(O.GetValue<string>('name', '') <> '',
          'a module has no name: ' + O.ToJSON);
        // Every entry must state its symbol position, main image included --
        // the exe being the one row with no answer was the defect this guards.
        Assert.IsTrue(O.GetValue<string>('symbols', '') <> '',
          'module ' + O.GetValue<string>('name', '') + ' has no symbol state: ' + O.ToJSON);
        var Formats := O.GetValue<TJSONArray>('formats');
        Assert.IsNotNull(Formats,
          'module ' + O.GetValue<string>('name', '') + ' has no formats list: ' + O.ToJSON);
        // "loaded" without a single registered format would be self-
        // contradictory: something must have supplied the symbols.
        if O.GetValue<string>('symbols', '') = 'loaded' then
          Assert.IsTrue(Formats.Count > 0,
            'module ' + O.GetValue<string>('name', '') +
            ' claims loaded symbols but lists no format: ' + O.ToJSON);
        if O.GetValue<Boolean>('isMain', False) then begin
          Inc(MainCount);
          MainFormats := Formats.Count;
          Assert.IsTrue(SameText(ExtractFileName(TargetExe), O.GetValue<string>('name', '')),
            'the main module is not the launched exe: ' + O.ToJSON);
        end;
      end;
      Assert.AreEqual(1, MainCount, 'exactly one module must be the main image: ' + Arr.ToJSON);
      // The fixture is built with debug info, so the exe must report at least
      // one provider; zero would mean the format list is never populated.
      Assert.IsTrue(MainFormats > 0,
        'the main image reports no debug-info format: ' + Arr.ToJSON);
    finally
      Mods.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.RawStackScan_HitsAreMarkedAsPositions;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    // The walked stack must stay clean: no tool other than the sweep may ever
    // hand an agent a rawStackHit.
    var Walked := C.CallTool('get_call_stack', nil);
    try
      var WArr := Walked as TJSONArray;
      for var I := 0 to WArr.Count - 1 do
        Assert.AreEqual('', (WArr.Items[I] as TJSONObject).GetValue<string>('kind', ''),
          'get_call_stack returned a marked hit: ' + WArr.ToJSON);
    finally
      Walked.Free;
    end;

    var Raw := C.CallTool('get_raw_stack_scan', nil);
    try
      var Arr := Raw as TJSONArray;
      Assert.IsTrue(Arr.Count > 0, 'raw sweep found nothing: ' + Arr.ToJSON);
      for var I := 0 to Arr.Count - 1 do begin
        var O := Arr.Items[I] as TJSONObject;
        // Both fields, on EVERY hit. `kind` alone would leave `proven` to be
        // inferred from its absence, and an agent reading a missing field as
        // false is exactly the failure this is guarding against.
        Assert.AreEqual('rawStackHit', O.GetValue<string>('kind', ''),
          'a sweep hit is not marked as one: ' + O.ToJSON);
        Assert.IsNotNull(O.FindValue('proven'),
          'a sweep hit does not say whether it was proven: ' + O.ToJSON);
      end;
      // Deliberately NOT asserted here: that some hit came back proven=true.
      // This fixture is x64, and the call-site proof needs an instruction-length
      // decoder the engine only has for x86 -- so on a 64-bit target every hit
      // is honestly proven=false. Measured, not assumed: the first version of
      // this test demanded a proven hit and failed for exactly that reason.
      // The proof itself is covered on x86 by
      // RawStackScan_FindsTheChainAndSaysItIsRaw.
    finally
      Raw.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.ExpandVariable_ObjectFields;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    // get_locals -> find W and its expansion handle
    var Handle := '';
    var Locals := C.CallTool('get_locals', nil);
    try
      for var V in (Locals as TJSONArray) do begin
        var O := V as TJSONObject;
        if O.GetValue<string>('name', '') = 'W' then begin
          Assert.IsTrue(O.GetValue<Boolean>('expandable', False), 'W not expandable: ' + O.ToJSON);
          Handle := O.GetValue<string>('handle', '');
        end;
      end;
    finally
      Locals.Free;
    end;
    Assert.IsTrue(Handle <> '', 'no expansion handle for W');

    // expand_variable(handle) -> a property-bearing class expands into category
    // groups ('properties'/'event handlers'/'fields'); the backing fields live in
    // the 'fields' group. Descend it, then assert FName='hello', FValue=42.
    var ExpArgs := TJSONObject.Create;
    ExpArgs.AddPair('handle', Handle);
    var Children := C.CallTool('expand_variable', ExpArgs);
    try
      var Groups := Children as TJSONArray;
      var FieldsHandle := '';
      for var V in Groups do begin
        var O := V as TJSONObject;
        if O.GetValue<string>('name', '') = 'fields' then begin
          Assert.IsTrue(O.GetValue<Boolean>('group', False), 'fields row not marked group');
          FieldsHandle := O.GetValue<string>('handle', '');
        end;
      end;
      Assert.IsTrue(FieldsHandle <> '', 'no "fields" group in expansion: ' + Groups.ToJSON);

      var FArgs := TJSONObject.Create;
      FArgs.AddPair('handle', FieldsHandle);
      var FieldsResp := C.CallTool('expand_variable', FArgs);
      try
        var Fields := FieldsResp as TJSONArray;
        var FoundName := False;
        var FoundValue := False;
        for var V in Fields do begin
          var O := V as TJSONObject;
          if O.GetValue<string>('name', '') = 'FName' then
            FoundName := O.GetValue<string>('value', '').Contains('hello');
          if O.GetValue<string>('name', '') = 'FValue' then
            FoundValue := O.GetValue<string>('value', '').Contains('42');
        end;
        Assert.IsTrue(FoundName, 'FName=hello not found in fields: ' + Fields.ToJSON);
        Assert.IsTrue(FoundValue, 'FValue=42 not found in fields');
      finally
        FieldsResp.Free;
      end;
    finally
      Children.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

function McpExpand(C: TMcpTestClient; const Handle: string): TJSONValue;
begin
  var A := TJSONObject.Create;
  A.AddPair('handle', Handle);
  Result := C.CallTool('expand_variable', A);
end;

function McpFindRow(Arr: TJSONArray; const Name: string; out O: TJSONObject): Boolean;
begin
  Result := False;
  for var V in Arr do
    if (V as TJSONObject).GetValue<string>('name', '') = Name then begin
      O := V as TJSONObject;
      Exit(True);
    end;
end;

// Getter-backed property over MCP: W -> 'properties' group -> 'Score' deferred
// ('(expand to evaluate)') -> expand runs the getter (DoCalcScore = FValue*2 = 84).
procedure TMcpE2ETests.ExpandVariable_PropertyGetter;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;
    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    var WHandle := '';
    var Locals := C.CallTool('get_locals', nil);
    try
      var WO: TJSONObject;
      Assert.IsTrue(McpFindRow(Locals as TJSONArray, 'W', WO), 'W local not found');
      WHandle := WO.GetValue<string>('handle', '');
    finally
      Locals.Free;
    end;
    Assert.IsTrue(WHandle <> '', 'no handle for W');

    var PropsHandle := '';
    var Groups := McpExpand(C, WHandle);
    try
      var GO: TJSONObject;
      Assert.IsTrue(McpFindRow(Groups as TJSONArray, 'properties', GO),
        'no properties group: ' + (Groups as TJSONArray).ToJSON);
      PropsHandle := GO.GetValue<string>('handle', '');
    finally
      Groups.Free;
    end;

    var ScoreHandle := '';
    var Props := McpExpand(C, PropsHandle);
    try
      var SO: TJSONObject;
      Assert.IsTrue(McpFindRow(Props as TJSONArray, 'Score', SO), 'Score property not found');
      Assert.AreEqual('(expand to evaluate)', SO.GetValue<string>('value', ''),
        'Score placeholder mismatch');
      ScoreHandle := SO.GetValue<string>('handle', '');
      Assert.IsTrue(ScoreHandle <> '', 'Score has no getter handle');
    finally
      Props.Free;
    end;

    var GetterRows := McpExpand(C, ScoreHandle);
    try
      var VO: TJSONObject;
      Assert.IsTrue(McpFindRow(GetterRows as TJSONArray, '(value)', VO),
        'getter did not yield a value leaf: ' + (GetterRows as TJSONArray).ToJSON);
      Assert.IsTrue(VO.GetValue<string>('value', '').Contains('84'),
        'Score getter value mismatch: ' + VO.GetValue<string>('value', ''));
    finally
      GetterRows.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.ConditionalBreakpoint_Stops;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    BpArgs.AddPair('condition', 'W.FValue = 42');
    C.CallTool('set_breakpoint', BpArgs).Free;

    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''),
        'conditional breakpoint did not stop: ' + S.ToJSON);
      Assert.AreEqual(Line, (S.GetValue('location') as TJSONObject).GetValue<Integer>('line', -1),
        'stopped at wrong line');
    finally
      Snap.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.Logpoint_EmitsToDebuggerOutput;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    BpArgs.AddPair('logMessage', 'wv={W.FValue}');
    C.CallTool('set_breakpoint', BpArgs).Free;

    // Logpoint does not stop; the target runs to exit.
    var Snap := C.CallTool('continue_and_wait', nil);
    try
      Assert.AreEqual('exited', TJSONObject(Snap).GetValue<string>('state', ''),
        'logpoint should not stop; target should exit: ' + Snap.ToJSON);
    finally
      Snap.Free;
    end;

    var Logs := C.CallTool('get_debugger_output', nil);
    try
      var Joined := '';
      for var L in (Logs as TJSONArray) do
        Joined := Joined + (L as TJSONString).Value + '|';
      Assert.IsTrue(Joined.Contains('wv=42'), 'logpoint message not in debugger output: ' + Joined);
    finally
      Logs.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.Bpl_Breakpoint_Stops;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    // Launch the host that LoadPackage's TestSubject.bpl at runtime.
    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', HostExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    // Breakpoint in a unit that lives ONLY inside the BPL.
    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''),
        'did not stop in the BPL unit: ' + S.ToJSON);
      Assert.AreEqual(EVAL_SOURCE,
        ExtractFileName((S.GetValue('location') as TJSONObject).GetValue<string>('sourceFile', '')),
        'wrong source file (BPL)');
    finally
      Snap.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.SetBreakpointsPlural_Stops;
begin
  var EvalLine := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var CtorLine := MarkerLine(EVAL_SOURCE, 'CTOR_BODY');
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    // set_breakpoints (plural): two lines in one file at once.
    var Bps := TJSONArray.Create;
    var B1 := TJSONObject.Create;
    B1.AddPair('sourceFile', EVAL_SOURCE); B1.AddPair('line', TJSONNumber.Create(EvalLine));
    Bps.Add(B1);
    var B2 := TJSONObject.Create;
    B2.AddPair('sourceFile', EVAL_SOURCE); B2.AddPair('line', TJSONNumber.Create(CtorLine));
    Bps.Add(B2);
    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('breakpoints', Bps);
    var BpResult := C.CallTool('set_breakpoints', BpArgs);
    try
      Assert.AreEqual(2, (BpResult as TJSONArray).Count, 'expected 2 breakpoints set');
    finally
      BpResult.Free;
    end;

    // continue -> stops at one of the two set lines
    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'did not stop');
      var StopLine := (S.GetValue('location') as TJSONObject).GetValue<Integer>('line', -1);
      Assert.IsTrue((StopLine = EvalLine) or (StopLine = CtorLine),
        'stopped at an unexpected line: ' + IntToStr(StopLine));
    finally
      Snap.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.LaunchFromConfig_Stops;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var Prog := StringReplace(TargetExe, '\', '\\', [rfReplaceAll]);
  // JSONC: line + block comments, trailing commas, ${workspaceFolder}.
  var Content :=
    '{' + sLineBreak +
    '  // Delphi launch config (JSONC)' + sLineBreak +
    '  "version": "0.2.0",' + sLineBreak +
    '  "configurations": [' + sLineBreak +
    '    {' + sLineBreak +
    '      "name": "Debug TestTarget",' + sLineBreak +
    '      "type": "delphi-win64",' + sLineBreak +
    '      /* the target */' + sLineBreak +
    '      "program": "' + Prog + '",' + sLineBreak +
    '      "sourceRoot": "${workspaceFolder}",' + sLineBreak +
    '    },' + sLineBreak +
    '  ],' + sLineBreak +
    '}';
  var CfgPath := TPath.Combine(TPath.GetTempPath, 'mcp_test_launch.json');
  TFile.WriteAllText(CfgPath, Content);

  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('configFile', CfgPath);
    LaunchArgs.AddPair('workspaceFolder', TargetDir);  // ${workspaceFolder} -> source root
    var LR := C.CallTool('launch_from_config', LaunchArgs);
    try
      // On success the tool returns an entry snapshot (a JSON object); an error
      // comes back as a plain-text message (a JSON string).
      Assert.IsTrue(LR is TJSONObject, 'launch_from_config errored: ' + LR.ToJSON);
    finally
      LR.Free;
    end;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''),
        'launch_from_config did not reach the breakpoint: ' + S.ToJSON);
      Assert.AreEqual(EVAL_SOURCE,
        ExtractFileName((S.GetValue('location') as TJSONObject).GetValue<string>('sourceFile', '')),
        'wrong source file');
    finally
      Snap.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// Regression for the "A debug session is already active" lock-up: after a
// debuggee is terminated the server must accept a fresh launch instead of
// rejecting every subsequent start for the rest of its lifetime. Drives two full
// launch->breakpoint->stop cycles over one server, terminating between them.
procedure TMcpE2ETests.Relaunch_AfterTerminate_Succeeds;

  procedure RunOneCycle(C: TMcpTestClient; Line: Integer);
  begin
    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var Snap := C.CallTool('continue_and_wait', nil);
    try
      Assert.AreEqual('stopped', TJSONObject(Snap).GetValue<string>('state', ''),
        'cycle did not reach the breakpoint: ' + Snap.ToJSON);
    finally
      Snap.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  end;

begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  Assert.IsTrue(Line > 0, 'marker not found');

  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    RunOneCycle(C, Line);   // first debuggee, terminated at the end
    RunOneCycle(C, Line);   // second launch on the SAME server must be accepted
  finally
    C.Free;
  end;
end;

// F8 regression: evaluating an expression that yields an OBJECT must return an
// expansion handle (like get_locals does), so a watch on an object can be drilled
// into with expand_variable instead of being a dead end.
procedure TMcpE2ETests.Evaluate_Object_IsExpandable;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    var Handle := '';
    var EvalArgs := TJSONObject.Create;
    EvalArgs.AddPair('expression', 'W');   // the TWidget object local
    var R := C.CallTool('evaluate_expression', EvalArgs);
    try
      var O := TJSONObject(R);
      Assert.IsTrue(O.GetValue<Boolean>('success', False), 'evaluate W failed: ' + O.ToJSON);
      Assert.IsTrue(O.GetValue<Boolean>('expandable', False),
        'an object result must be expandable: ' + O.ToJSON);
      Handle := O.GetValue<string>('handle', '');
      Assert.IsTrue(Handle <> '', 'an object result must carry an expansion handle: ' + O.ToJSON);
    finally
      R.Free;
    end;

    // The handle must drive expand_variable, yielding the object's members.
    var Children := McpExpand(C, Handle);
    try
      Assert.IsTrue(Children is TJSONArray, 'expand_variable did not return an array');
      Assert.IsTrue(TJSONArray(Children).Count > 0, 'object expansion returned no members');
    finally
      Children.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// F18 regression: get_locals and evaluate_expression must honour an explicit
// frameIndex so a caller can inspect a CALLER frame. On a real application the
// top frame after pause_execution sits inside ntdll, where get_locals returns []
// and even a global fails to evaluate, while the useful frame is several levels
// down -- without frame selection the MCP surface is unusable after a pause.
//
// Scenario: breakpoint at COMPUTE_BODY, inside TWidget.Compute (own locals
// Factor = FValue*2 = 84 and FName). In the monolithic exe its only caller is the
// TestTarget.dpr program main block, whose inline vars (TheWidget = 'hello'/42,
// TheStuff, Res) exist in no other frame. Both directions are asserted: the
// default frame must show Factor and NOT TheWidget, frameIndex 1 must show
// TheWidget and NOT Factor.
procedure TMcpE2ETests.Locals_FrameIndex_ReadsCallerFrame;

  function LocalsForFrame(C: TMcpTestClient; FrameIndex: Integer): TJSONArray;
  begin
    var Args: TJSONObject := nil;
    if FrameIndex <> 0 then begin
      Args := TJSONObject.Create;
      Args.AddPair('frameIndex', TJSONNumber.Create(FrameIndex));
    end;
    var V := C.CallTool('get_locals', Args);
    if not (V is TJSONArray) then begin
      var Text := V.ToJSON;
      V.Free;
      raise Exception.Create('get_locals did not return an array: ' + Text);
    end;
    Result := TJSONArray(V);
  end;

  function EvalInFrame(C: TMcpTestClient; const Expr: string; FrameIndex: Integer): TJSONObject;
  begin
    var Args := TJSONObject.Create;
    Args.AddPair('expression', Expr);
    if FrameIndex <> 0 then
      Args.AddPair('frameIndex', TJSONNumber.Create(FrameIndex));
    var V := C.CallTool('evaluate_expression', Args);
    if not (V is TJSONObject) then begin
      var Text := V.ToJSON;
      V.Free;
      raise Exception.Create('evaluate_expression did not return an object: ' + Text);
    end;
    Result := TJSONObject(V);
  end;

begin
  var Line := MarkerLine(EVAL_SOURCE, 'COMPUTE_BODY');
  Assert.IsTrue(Line > 0, 'COMPUTE_BODY marker not found');

  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var Snap := C.CallTool('continue_and_wait', nil);
    try
      Assert.AreEqual('stopped', TJSONObject(Snap).GetValue<string>('state', ''),
        'did not stop at COMPUTE_BODY: ' + Snap.ToJSON);
    finally
      Snap.Free;
    end;

    // Confirm WHICH frame is frame 1 before relying on it; its description is
    // quoted by every later assertion so a future failure is diagnosable.
    var Frame1Desc := '';
    var Stack := C.CallTool('get_call_stack', nil);
    try
      var Frames := Stack as TJSONArray;
      Assert.IsTrue(Frames.Count >= 2, 'need at least 2 frames: ' + Frames.ToJSON);
      var F0 := Frames.Items[0] as TJSONObject;
      var F1 := Frames.Items[1] as TJSONObject;
      Frame1Desc := 'frame1=' + F1.GetValue<string>('function', '(anonymous)') + ' @ ' +
        ExtractFileName(F1.GetValue<string>('sourceFile', '')) + ':' +
        IntToStr(F1.GetValue<Integer>('line', -1));
      Assert.IsTrue(F0.GetValue<string>('function', '').Contains('Compute'),
        'frame 0 is not TWidget.Compute: ' + Frames.ToJSON);
      Assert.AreEqual('TestTarget.dpr', ExtractFileName(F1.GetValue<string>('sourceFile', '')),
        'frame 1 is not the program main block that calls Compute: ' + Frames.ToJSON);
    finally
      Stack.Free;
    end;

    // Direction 1: no frameIndex -> the CALLEE's own locals.
    var TopLocals := LocalsForFrame(C, 0);
    try
      var Row: TJSONObject := nil;
      Assert.IsTrue(McpFindRow(TopLocals, 'Factor', Row),
        'callee local Factor missing from the default frame: ' + TopLocals.ToJSON);
      Assert.IsTrue(Row.GetValue<string>('value', '').Contains('84'),
        'Factor should be 84 inside TWidget.Compute: ' + Row.ToJSON);
      Assert.IsFalse(McpFindRow(TopLocals, 'TheWidget', Row),
        'the default frame must not expose the caller local TheWidget (' + Frame1Desc +
        '): ' + TopLocals.ToJSON);
    finally
      TopLocals.Free;
    end;

    // Direction 2: frameIndex 1 -> the CALLER's locals instead.
    var CallerLocals := LocalsForFrame(C, 1);
    try
      var Row: TJSONObject := nil;
      Assert.IsTrue(McpFindRow(CallerLocals, 'TheWidget', Row),
        'caller local TheWidget missing at frameIndex 1 (' + Frame1Desc + '): ' +
        CallerLocals.ToJSON);
      Assert.IsFalse(McpFindRow(CallerLocals, 'Factor', Row),
        'frameIndex 1 still shows the callee local Factor (' + Frame1Desc + '): ' +
        CallerLocals.ToJSON);
    finally
      CallerLocals.Free;
    end;

    // evaluate_expression follows the same frame selection.
    var TopEval := EvalInFrame(C, 'Factor', 0);
    try
      Assert.IsTrue(TopEval.GetValue<Boolean>('success', False),
        'evaluating the callee local Factor in the default frame failed: ' + TopEval.ToJSON);
      Assert.IsTrue(TopEval.GetValue<string>('value', '').Contains('84'),
        'Factor mismatch in the default frame: ' + TopEval.ToJSON);
    finally
      TopEval.Free;
    end;

    var CallerEval := EvalInFrame(C, 'TheWidget.Name', 1);
    try
      Assert.IsTrue(CallerEval.GetValue<Boolean>('success', False),
        'evaluating the caller local TheWidget.Name at frameIndex 1 failed (' +
        Frame1Desc + '): ' + CallerEval.ToJSON);
      Assert.IsTrue(CallerEval.GetValue<string>('value', '').Contains('hello'),
        'TheWidget.Name mismatch at frameIndex 1 (' + Frame1Desc + '): ' + CallerEval.ToJSON);
    finally
      CallerEval.Free;
    end;

    // The very same expression must NOT resolve to the caller's value without
    // frameIndex -- otherwise the frame selection above proves nothing.
    var LeakEval := EvalInFrame(C, 'TheWidget.Name', 0);
    try
      var LeakedValue := LeakEval.GetValue<Boolean>('success', False) and
        LeakEval.GetValue<string>('value', '').Contains('hello');
      Assert.IsFalse(LeakedValue,
        'TheWidget.Name resolved in the default (callee) frame, so frameIndex is not what ' +
        'selected the caller (' + Frame1Desc + '): ' + LeakEval.ToJSON);
    finally
      LeakEval.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMcpE2ETests);

end.
