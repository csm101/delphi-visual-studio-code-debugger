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
    function TargetExe32: string;
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
    [Test] procedure SourceFiles_ListTheFileSetBreakpointExpects;
    // Data breakpoints (watchpoints) -- increment 5 of DATA_BREAKPOINTS_PLAN.md.
    // The session/engine correctness (per-thread replication, DR6
    // disambiguation, slot allocation) is proven by DataBp_SessionApi_* in
    // DebugSessionTests.pas; these cover the MCP TOOL surface on top of it --
    // argument parsing, the access-type refusal, and the JSON shape a caller
    // actually sees.
    [Test] procedure DataBreakpoint_StopsWithAddressThreadOldNew;
    [Test] procedure DataBreakpoint_ReadWriteAccessCarriesCaveat;
    [Test] procedure DataBreakpoint_ReadAccessRefusedExplicitly;
    [Test] procedure DataBreakpoint_LocalRefusedWithReason;
    [Test] procedure DataBreakpoint_SlotExhaustion_RefusesFifthWithEngineMessage;
    [Test] procedure DataBreakpoint_ListAndRemove_ClearsHardwareSlotForReal;
    // DISASSEMBLY_PLAN.md increment 4: MCP `disassemble`.
    [Test] procedure Disassemble_Forward_ReturnsDecodedInstructionsAtStopAddress;
    [Test] procedure Disassemble_ViaFrameIndex_MatchesAddressForm;
    [Test] procedure Disassemble_Before_ReturnsProvenPrecedingInstructions;
    [Test] procedure Disassemble_Win32_Forward_ReturnsDecodedInstructions;
    [Test] procedure Disassemble_ReportsUnavailable_WhenZydisDllNotFound;
    // DISASSEMBLY_PLAN.md increment 5: address breakpoints. Uses disassemble's
    // own echoed address (the documented workflow: feed a frame/instruction
    // address straight back in) so the tool surface is proven the way an
    // agent would actually drive it, not with a hand-computed VA.
    [Test] procedure SetBreakpointAtAddress_UsingDisassembledAddress_StopsAgain;
    [Test] procedure SetBreakpointAtAddress_Win32_StopsAgain;
    [Test] procedure SetBreakpointAtAddress_RefusedWhenNotInAnyLoadedModule;
    [Test] procedure RemoveBreakpointAtAddress_UnplantsAndDoesNotStopAgain;

    // ASSEMBLY_LEVEL_DEBUGGING.md increment 4: registers. The MCP equivalent
    // of DAP's writable Registers scope -- same TDebugSession.GetRegisters /
    // SetRegister path, so these prove the TOOL surface (JSON shape, the
    // "must be stopped" gate, an unrecognised-name refusal); the register
    // VALUES themselves already come from the same engine call the DAP
    // Registers scope has used for a long time.
    [Test] procedure GetRegisters_MatchesCallStackRip;
    [Test] procedure GetRegisters_Win32_MatchesRipAndZeroExtendsUpperRegisters;
    [Test] procedure GetRegisters_RefusedBeforeLaunch;
    [Test] procedure SetRegister_WritesAndReadsBack;
    [Test] procedure SetRegister_UnknownName_Refused;

    // ASSEMBLY_LEVEL_DEBUGGING.md increment 4: instruction-granularity
    // stepping over MCP. The ENGINE rules (call/rep/recursion, every refusal
    // reason) are InstructionStepTests.pas's job and are not re-proven here;
    // this proves granularity:"instruction" reaches TDebugSession.
    // StepInstruction with the right TInstructionStepKind, that a refusal
    // surfaces as isError:true (never a silent no-op or an unresolved wait),
    // and that "statement" (default) is untouched. Reuses increment 1's own
    // fixture, InstructionStepSample.exe -- MCP has never driven step_over/
    // step_into/step_out at all before this increment, so these are also the
    // first coverage of those tools' plain (statement) behaviour.
    [Test] procedure StepInto_Instruction_AdvancesOneInstructionSameLine;
    [Test] procedure StepInto_Instruction_Win32_AdvancesOneInstructionSameLine;
    [Test] procedure StepOver_Instruction_AdvancesOneInstructionSameLine;
    [Test] procedure StepOut_Instruction_LandsInTheCaller;
    [Test] procedure StepOut_Instruction_Win32_LandsInTheCaller;
    [Test] procedure StepInto_GranularityAbsentOrStatement_StillAdvancesToNewLine;
    [Test] procedure StepOver_UnknownGranularity_Refused;
    [Test] procedure StepInto_Instruction_RefusedBeforeLaunch;
    // Unlike the DAP surface (InstructionStepDapTests.pas), MCP is a separate
    // PROCESS: copying it to a scratch directory outside the repo (the same
    // technique Disassemble_ReportsUnavailable_WhenZydisDllNotFound uses)
    // makes the disassembler-unavailable refusal reachable from OUTSIDE the
    // process too, not just at the engine level.
    [Test] procedure StepInto_Instruction_RefusedWhenDisassemblerUnavailable;
  end;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.IOUtils;

const
  EVAL_MARKER = 'EVAL_BODY';
  EVAL_SOURCE = 'TestTargetCore.pas';
  // Data-breakpoint fixtures (shared with DataBp_SessionApi_* in
  // DebuggerTests\DebugSessionTests.pas; see DATA_BREAKPOINTS_PLAN.md).
  DATABP_ARGS       = '-run-databp-step';
  DATABPTHREAD_ARGS = '-run-databp-thread';

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

function TMcpE2ETests.TargetExe32: string;
begin
  Result := TargetDir + 'Win32\Debug\TestTarget.exe';
end;

function TMcpE2ETests.HostExe: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.exe';
end;

// ASSEMBLY_LEVEL_DEBUGGING.md increment 1's own fixture -- a separate target
// on purpose (TRAPS.md: adding scenarios to TestTarget shifts RSM import
// indices and marker ordering). mapFile/rsmFile are left to launch_debuggee's
// default (exe path with .map/.rsm), same as every other launch in this file.
const
  INSTR_SAMPLE_SOURCE = 'InstructionStepSample.dpr';

function InstrSampleExe(const RootDir, Bitness: string): string;
begin
  Result := RootDir + Bitness + '\Debug\InstructionStepSample.exe';
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

// The point of the tool is that the names it returns are the ones
// set_breakpoint accepts. A list that omitted the very unit the fixture breaks
// in would still look plausible, so the assertion is specifically that the file
// used elsewhere in this suite is present -- and that it is reported in the
// lowercase spelling the rest of the surface uses.
procedure TMcpE2ETests.SourceFiles_ListTheFileSetBreakpointExpects;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var Groups := C.CallTool('get_source_files', nil);
    try
      var Arr := Groups as TJSONArray;
      Assert.IsTrue(Arr.Count >= 1, 'no module groups were returned: ' + Arr.ToJSON);

      var MainSeen := False;
      var FoundEvalSource := False;
      for var I := 0 to Arr.Count - 1 do begin
        var G := Arr.Items[I] as TJSONObject;
        Assert.IsTrue(G.GetValue<string>('module', '') <> '',
          'a group has no module name: ' + G.ToJSON);
        var Files := G.GetValue<TJSONArray>('files');
        Assert.IsNotNull(Files, 'group has no files array: ' + G.ToJSON);
        // A group that lists files must say which format listed them; the pair
        // is what lets a caller tell "none" from "cannot enumerate".
        if Files.Count > 0 then
          Assert.IsTrue(G.GetValue<string>('listedBy', '') <> '',
            'files were listed with no listedBy: ' + G.ToJSON);
        Assert.AreEqual(Files.Count, G.GetValue<Integer>('fileCount', -1),
          'fileCount disagrees with the files array: ' + G.ToJSON);

        if not G.GetValue<Boolean>('isMain', False) then
          Continue;
        MainSeen := True;
        for var J := 0 to Files.Count - 1 do begin
          var Name := (Files.Items[J] as TJSONObject).GetValue<string>('name', '');
          Assert.AreEqual(LowerCase(Name), Name,
            'source file names must be lowercase like every other surface: ' + Name);
          if SameText(Name, EVAL_SOURCE) then
            FoundEvalSource := True;
        end;
      end;

      Assert.IsTrue(MainSeen, 'the main image has no source group: ' + Arr.ToJSON);
      Assert.IsTrue(FoundEvalSource,
        Format('%s is missing from the main image source list, yet breakpoints bind in it: %s',
          [EVAL_SOURCE, Arr.ToJSON]));
    finally
      Groups.Free;
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

// The worker thread scenario: GDataBpThreadWatched is written by a thread that
// was already alive (spinning) when the watchpoint is armed, proving arm-time
// per-thread replication reaches the MCP surface. Also the negative control for
// McpJson.ReasonName: with srDataBreakpoint left unhandled there, stopReason
// comes back "unknown" instead of "dataBreakpoint" and this test fails on that
// assertion alone.
procedure TMcpE2ETests.DataBreakpoint_StopsWithAddressThreadOldNew;
begin
  var ReadyLine := MarkerLine(EVAL_SOURCE, 'DATABPTHREAD_READY');
  Assert.IsTrue(ReadyLine > 0, 'DATABPTHREAD_READY marker not found');

  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    LaunchArgs.AddPair('args', DATABPTHREAD_ARGS);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(ReadyLine));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var MainTid := -1;
    var Snap1 := C.CallTool('continue_and_wait', nil);
    try
      var S1 := TJSONObject(Snap1);
      Assert.AreEqual('stopped', S1.GetValue<string>('state', ''),
        'did not stop at DATABPTHREAD_READY: ' + S1.ToJSON);
      MainTid := S1.GetValue<Integer>('thread', -1);
    finally
      Snap1.Free;
    end;

    var DbpArgs := TJSONObject.Create;
    DbpArgs.AddPair('expression', 'GDataBpThreadWatched');
    DbpArgs.AddPair('size', TJSONNumber.Create(4));
    DbpArgs.AddPair('access', 'write');
    var Armed := C.CallTool('set_data_breakpoint', DbpArgs);
    try
      Assert.IsTrue(Armed is TJSONObject, 'set_data_breakpoint errored: ' + Armed.ToJSON);
      var A := TJSONObject(Armed);
      Assert.IsTrue(A.GetValue<Boolean>('verified', False),
        'watchpoint refused: ' + A.GetValue<string>('message', ''));
      Assert.IsTrue(A.GetValue<string>('address', '') <> '', 'no resolved address in the result');
      Assert.IsTrue(A.GetValue<Integer>('slot', -1) >= 0, 'a verified watchpoint must carry a real slot');
      Assert.AreEqual('write', A.GetValue<string>('access', ''), 'access mismatch');
    finally
      Armed.Free;
    end;

    var Snap2 := C.CallTool('continue_and_wait', nil);
    try
      var S2 := TJSONObject(Snap2);
      Assert.AreEqual('stopped', S2.GetValue<string>('state', ''),
        'the target never stopped on the watchpoint: ' + S2.ToJSON);
      Assert.AreEqual('dataBreakpoint', S2.GetValue<string>('stopReason', ''),
        'stopReason should name the data-breakpoint stop: ' + S2.ToJSON);
      var FiringTid := S2.GetValue<Integer>('thread', -1);
      Assert.AreNotEqual(MainTid, FiringTid,
        'the stop was attributed to the MAIN thread, not the worker that wrote it');
      var Desc := S2.GetValue<string>('dataBreakpointDescription', '');
      Assert.IsTrue(Desc.Contains('GDataBpThreadWatched'),
        'description does not name the watched expression: ' + Desc);
      Assert.IsTrue(Desc.Contains('-> $1'), 'description does not show the write (-> 1): ' + Desc);
      Assert.IsTrue(Desc.Contains(IntToStr(FiringTid)),
        'description does not name the firing thread: ' + Desc);
    finally
      Snap2.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// access="readWrite" is the only way to also catch reads, and there is no
// read-only hardware watchpoint on x86/x64 -- it must arm (this is a real,
// useful watchpoint) but say plainly that it also fires on writes.
procedure TMcpE2ETests.DataBreakpoint_ReadWriteAccessCarriesCaveat;
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

    var DbpArgs := TJSONObject.Create;
    DbpArgs.AddPair('expression', 'GDataBpWatched');
    DbpArgs.AddPair('size', TJSONNumber.Create(4));
    DbpArgs.AddPair('access', 'readWrite');
    var R := C.CallTool('set_data_breakpoint', DbpArgs);
    try
      Assert.IsTrue(R is TJSONObject, 'set_data_breakpoint errored: ' + R.ToJSON);
      var O := TJSONObject(R);
      Assert.IsTrue(O.GetValue<Boolean>('verified', False),
        'a readWrite watchpoint on a resolvable global must arm: ' + O.GetValue<string>('message', ''));
      Assert.AreEqual('readWrite', O.GetValue<string>('access', ''), 'access mismatch');
      var Msg := O.GetValue<string>('message', '');
      Assert.IsTrue(Msg.ToLower.Contains('write'),
        'a readWrite watchpoint must say it ALSO fires on writes: ' + Msg);
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// access="read" has no hardware equivalent and must be refused OUTRIGHT --
// never silently downgraded to readWrite, which would let a caller believe it
// asked for (and got) something that filtered out writes.
procedure TMcpE2ETests.DataBreakpoint_ReadAccessRefusedExplicitly;
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

    var DbpArgs := TJSONObject.Create;
    DbpArgs.AddPair('expression', 'GDataBpWatched');
    DbpArgs.AddPair('size', TJSONNumber.Create(4));
    DbpArgs.AddPair('access', 'read');
    var R := C.CallTool('set_data_breakpoint', DbpArgs);
    try
      Assert.IsTrue(R is TJSONString,
        'access="read" should be refused as a tool error, never silently accepted: ' + R.ToJSON);
      var Msg := (R as TJSONString).Value;
      Assert.IsTrue(Msg.ToLower.Contains('read-only') or Msg.ToLower.Contains('hardware equivalent'),
        'the refusal does not explain WHY "read" is rejected: ' + Msg);
    finally
      R.Free;
    end;

    // A refused request must not create any tracked entry.
    var Listed := C.CallTool('list_data_breakpoints', nil);
    try
      Assert.AreEqual(0, (Listed as TJSONArray).Count,
        'a refused access="read" request must not create an entry: ' + Listed.ToJSON);
    finally
      Listed.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// A local is a real symbol, but watching its address past the frame's
// lifetime is nonsense -- refused BY NAME (increment 6's dataBreakpointInfo
// is what will eventually support it), never treated as a stale address.
procedure TMcpE2ETests.DataBreakpoint_LocalRefusedWithReason;
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

    var DbpArgs := TJSONObject.Create;
    DbpArgs.AddPair('expression', 'W');   // the TWidget local at EVAL_BODY
    DbpArgs.AddPair('size', TJSONNumber.Create(8));
    DbpArgs.AddPair('access', 'write');
    var R := C.CallTool('set_data_breakpoint', DbpArgs);
    try
      Assert.IsTrue(R is TJSONObject,
        'a local is a per-item refusal (Verified=False), not a tool-level error: ' + R.ToJSON);
      var O := TJSONObject(R);
      Assert.IsFalse(O.GetValue<Boolean>('verified', True), 'a local must be refused, not armed');
      var Msg := O.GetValue<string>('message', '');
      Assert.IsTrue(Msg.ToLower.Contains('local'),
        'refusal reason does not say WHY (local lifetime): ' + Msg);
      Assert.AreEqual(-1, O.GetValue<Integer>('slot', -99), 'a refused request must not report a real slot');
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// Five distinct 4-byte globals, four hardware slots: exhaustion must be
// reported for the 5th with a message naming what already holds the slots
// (the engine's own refusal text, not a generic MCP failure), and the first
// four must still work.
procedure TMcpE2ETests.DataBreakpoint_SlotExhaustion_RefusesFifthWithEngineMessage;
const
  Globals: array[0..4] of string = (
    'GDataBpWatched', 'GDataBpOther', 'GCounter', 'GDataBpThreadWatched', 'GDataBpThreadLate');
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

    for var I := 0 to 3 do begin
      var DbpArgs := TJSONObject.Create;
      DbpArgs.AddPair('expression', Globals[I]);
      DbpArgs.AddPair('size', TJSONNumber.Create(4));
      DbpArgs.AddPair('access', 'write');
      var R := C.CallTool('set_data_breakpoint', DbpArgs);
      try
        Assert.IsTrue(R is TJSONObject, Format('spec %d (%s) errored: %s', [I, Globals[I], R.ToJSON]));
        Assert.IsTrue(TJSONObject(R).GetValue<Boolean>('verified', False),
          Format('spec %d (%s) should have armed: %s',
            [I, Globals[I], TJSONObject(R).GetValue<string>('message', '')]));
      finally
        R.Free;
      end;
    end;

    var LastArgs := TJSONObject.Create;
    LastArgs.AddPair('expression', Globals[4]);
    LastArgs.AddPair('size', TJSONNumber.Create(4));
    LastArgs.AddPair('access', 'write');
    var Fifth := C.CallTool('set_data_breakpoint', LastArgs);
    try
      Assert.IsTrue(Fifth is TJSONObject, 'the fifth spec should be a per-item refusal, not a tool error: ' + Fifth.ToJSON);
      var O := TJSONObject(Fifth);
      Assert.IsFalse(O.GetValue<Boolean>('verified', True), 'the fifth watchpoint should have been refused');
      var Msg := O.GetValue<string>('message', '');
      Assert.IsTrue(Msg.ToLower.Contains('slots are in use'),
        'exhaustion refusal does not name what holds the slots: ' + Msg);
      Assert.AreEqual(-1, O.GetValue<Integer>('slot', -99), 'a refused request must not report a real slot');
    finally
      Fifth.Free;
    end;

    var Listed := C.CallTool('list_data_breakpoints', nil);
    try
      Assert.AreEqual(5, (Listed as TJSONArray).Count,
        'expected all 5 tracked (4 armed + 1 refused), not silently dropped: ' + Listed.ToJSON);
    finally
      Listed.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// remove_data_breakpoint must genuinely clear the hardware slot, not just
// forget about it: after removal the target must run PAST the write it used
// to stop on.
procedure TMcpE2ETests.DataBreakpoint_ListAndRemove_ClearsHardwareSlotForReal;
begin
  var ReadyLine := MarkerLine(EVAL_SOURCE, 'DATABP_READY');
  var DoneLine  := MarkerLine(EVAL_SOURCE, 'DATABP_DONE');
  Assert.IsTrue((ReadyLine > 0) and (DoneLine > 0),
    'DATABP_READY / DATABP_DONE markers not found');

  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    LaunchArgs.AddPair('args', DATABP_ARGS);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var Bps := TJSONArray.Create;
    var B1 := TJSONObject.Create;
    B1.AddPair('sourceFile', EVAL_SOURCE); B1.AddPair('line', TJSONNumber.Create(ReadyLine));
    Bps.Add(B1);
    var B2 := TJSONObject.Create;
    B2.AddPair('sourceFile', EVAL_SOURCE); B2.AddPair('line', TJSONNumber.Create(DoneLine));
    Bps.Add(B2);
    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('breakpoints', Bps);
    C.CallTool('set_breakpoints', BpArgs).Free;

    var Snap1 := C.CallTool('continue_and_wait', nil);
    try
      Assert.AreEqual('stopped', TJSONObject(Snap1).GetValue<string>('state', ''),
        'did not stop at DATABP_READY: ' + Snap1.ToJSON);
    finally
      Snap1.Free;
    end;

    var DbpArgs := TJSONObject.Create;
    DbpArgs.AddPair('expression', 'GDataBpWatched');
    DbpArgs.AddPair('size', TJSONNumber.Create(4));
    DbpArgs.AddPair('access', 'write');
    var WpId := '';
    var Armed := C.CallTool('set_data_breakpoint', DbpArgs);
    try
      Assert.IsTrue(TJSONObject(Armed).GetValue<Boolean>('verified', False),
        'setup: watchpoint should have armed: ' + Armed.ToJSON);
      WpId := TJSONObject(Armed).GetValue<string>('id', '');
      Assert.IsTrue(WpId <> '', 'no id returned for the armed watchpoint');
    finally
      Armed.Free;
    end;

    var Listed1 := C.CallTool('list_data_breakpoints', nil);
    try
      Assert.AreEqual(1, (Listed1 as TJSONArray).Count, 'expected exactly one tracked watchpoint');
    finally
      Listed1.Free;
    end;

    var RemArgs := TJSONObject.Create;
    RemArgs.AddPair('id', WpId);
    var Remaining := C.CallTool('remove_data_breakpoint', RemArgs);
    try
      Assert.AreEqual(0, (Remaining as TJSONArray).Count,
        'remove_data_breakpoint left an entry behind: ' + Remaining.ToJSON);
    finally
      Remaining.Free;
    end;

    var Listed2 := C.CallTool('list_data_breakpoints', nil);
    try
      Assert.AreEqual(0, (Listed2 as TJSONArray).Count,
        'list_data_breakpoints disagrees with the removal: ' + Listed2.ToJSON);
    finally
      Listed2.Free;
    end;

    var Snap2 := C.CallTool('continue_and_wait', nil);
    try
      var S2 := TJSONObject(Snap2);
      Assert.AreEqual('stopped', S2.GetValue<string>('state', ''),
        'did not reach DATABP_DONE: ' + S2.ToJSON);
      Assert.AreNotEqual('dataBreakpoint', S2.GetValue<string>('stopReason', ''),
        'the removed watchpoint still fired -- the hardware slot was left armed: ' + S2.ToJSON);
      var Loc := S2.GetValue('location') as TJSONObject;
      Assert.AreEqual(DoneLine, Loc.GetValue<Integer>('line', -1), 'stopped at the wrong line');
    finally
      Snap2.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// DISASSEMBLY_PLAN.md increment 4: MCP `disassemble`.

function ParseHexAddr(const S: string): UInt64;
var
  T: string;
begin
  T := S;
  if T.StartsWith('0x', True) then
    T := '$' + T.Substring(2);
  Result := StrToUInt64(T);
end;

// The stop address a real breakpoint hit is fed straight back into
// `disassemble` -- proving the "no re-parsing of display text" claim: the
// SAME "0x..." string already sitting in the snapshot's top frame is used
// as the request, unmodified.
procedure TMcpE2ETests.Disassemble_Forward_ReturnsDecodedInstructionsAtStopAddress;
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

    var StopAddr := '';
    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'not stopped: ' + S.ToJSON);
      var Frames := S.GetValue('frames') as TJSONArray;
      Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'no frames in snapshot: ' + S.ToJSON);
      StopAddr := (Frames.Items[0] as TJSONObject).GetValue<string>('address', '');
      Assert.IsTrue(StopAddr <> '', 'top frame carries no "address" field: ' + S.ToJSON);
    finally
      Snap.Free;
    end;

    var DisArgs := TJSONObject.Create;
    DisArgs.AddPair('address', StopAddr);
    DisArgs.AddPair('count', TJSONNumber.Create(5));
    var R := C.CallTool('disassemble', DisArgs);
    try
      Assert.IsTrue(R is TJSONObject, 'disassemble did not return an object: ' + R.ToJSON);
      var O := TJSONObject(R);
      Assert.IsTrue(O.GetValue<Boolean>('available', False),
        'Zydis reported unavailable (is ThirdParty\Zydis\bin\x64\Zydis.dll present?): ' + O.ToJSON);
      Assert.AreEqual('x64', O.GetValue<string>('machineMode', ''), 'wrong machine mode: ' + O.ToJSON);
      Assert.AreEqual(StopAddr, O.GetValue<string>('address', ''), 'echoed address does not match the request');
      var Insns := O.GetValue('instructions') as TJSONArray;
      Assert.IsTrue((Insns <> nil) and (Insns.Count = 5),
        'expected exactly 5 decoded instructions: ' + O.ToJSON);
      var First := Insns.Items[0] as TJSONObject;
      Assert.AreEqual(StopAddr, First.GetValue<string>('address', ''),
        'the first instruction must start EXACTLY at the requested address');
      Assert.IsTrue(First.GetValue<string>('bytes', '') <> '', 'first instruction has no bytes');
      Assert.IsTrue(First.GetValue<string>('text', '') <> '', 'first instruction has no text');
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// frameIndex/threadId is a convenience over the SAME address form -- reuses
// the existing get_locals/get_variable/evaluate_expression frame-selection
// convention rather than a separate opaque "frameId".
procedure TMcpE2ETests.Disassemble_ViaFrameIndex_MatchesAddressForm;
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

    var ByFrame := C.CallTool('disassemble', nil);   // no address -> frameIndex 0 / threadId 0
    var ByAddr: TJSONValue := nil;
    try
      var OFrame := TJSONObject(ByFrame);
      var Addr := OFrame.GetValue<string>('address', '');
      Assert.IsTrue(Addr <> '', 'disassemble via frameIndex resolved no address: ' + OFrame.ToJSON);

      var DisArgs := TJSONObject.Create;
      DisArgs.AddPair('address', Addr);
      ByAddr := C.CallTool('disassemble', DisArgs);
      var OAddr := TJSONObject(ByAddr);

      Assert.AreEqual(Addr, OAddr.GetValue<string>('address', ''), 'address-form echoed a different address');
      var InsnsFrame := OFrame.GetValue('instructions') as TJSONArray;
      var InsnsAddr := OAddr.GetValue('instructions') as TJSONArray;
      Assert.AreEqual(InsnsFrame.Count, InsnsAddr.Count, 'instruction counts differ between the two forms');
      Assert.AreEqual(
        (InsnsFrame.Items[0] as TJSONObject).GetValue<string>('text', ''),
        (InsnsAddr.Items[0] as TJSONObject).GetValue<string>('text', ''),
        'the two forms decoded a different first instruction');
    finally
      ByFrame.Free;
      ByAddr.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// The "before" success path, end to end through the MCP tool (not just the
// DisassembleBackward unit tested directly in DisassemblerTests.pas): the
// ordinary EVAL_BODY stop sits past its routine's prologue, so a PROVEN
// earlier boundary exists and decoding forward from it must land exactly on
// the stop address.
procedure TMcpE2ETests.Disassemble_Before_ReturnsProvenPrecedingInstructions;
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

    var DisArgs := TJSONObject.Create;
    DisArgs.AddPair('count', TJSONNumber.Create(1));
    DisArgs.AddPair('before', TJSONNumber.Create(2));
    var R := C.CallTool('disassemble', DisArgs);
    try
      var O := TJSONObject(R);
      Assert.IsTrue(O.GetValue<Boolean>('available', False), 'Zydis unavailable: ' + O.ToJSON);
      var StopAddr := O.GetValue<string>('address', '');

      var Before := O.GetValue('before') as TJSONObject;
      Assert.IsNotNull(Before, '"before" missing from the result: ' + O.ToJSON);
      Assert.AreEqual(2, Before.GetValue<Integer>('requested', -1));
      Assert.IsFalse(Before.GetValue<Boolean>('refused', True),
        'a stop past its routine''s prologue must have a provable "before": ' + Before.ToJSON);
      var BInsns := Before.GetValue('instructions') as TJSONArray;
      Assert.IsTrue((BInsns <> nil) and (BInsns.Count > 0), '"before" returned no instructions: ' + Before.ToJSON);
      Assert.AreEqual(BInsns.Count, Before.GetValue<Integer>('returned', -1));

      // The LAST "before" instruction must end EXACTLY at the stop address --
      // the whole point of the proven-boundary-only design.
      var LastB := BInsns.Items[BInsns.Count - 1] as TJSONObject;
      var LastAddr := ParseHexAddr(LastB.GetValue<string>('address', '0x0'));
      var LastLen := Length(LastB.GetValue<string>('bytes', '')) div 2;
      Assert.AreEqual(ParseHexAddr(StopAddr), LastAddr + UInt64(LastLen),
        'the last "before" instruction does not end exactly at the stop address');
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// Bitness coverage: the SAME tool, SAME Zydis.dll, against a 32-bit target.
procedure TMcpE2ETests.Disassemble_Win32_Forward_ReturnsDecodedInstructions;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe32);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;
    C.CallTool('continue_and_wait', nil).Free;

    var DisArgs := TJSONObject.Create;
    DisArgs.AddPair('count', TJSONNumber.Create(3));
    var R := C.CallTool('disassemble', DisArgs);
    try
      var O := TJSONObject(R);
      Assert.IsTrue(O.GetValue<Boolean>('available', False), 'Zydis unavailable: ' + O.ToJSON);
      Assert.AreEqual('x86', O.GetValue<string>('machineMode', ''), 'wrong machine mode: ' + O.ToJSON);
      var Insns := O.GetValue('instructions') as TJSONArray;
      Assert.IsTrue((Insns <> nil) and (Insns.Count = 3), 'expected 3 instructions: ' + O.ToJSON);
      for var I := 0 to Insns.Count - 1 do begin
        var Ins := Insns.Items[I] as TJSONObject;
        // A 32-bit address must fit in 8 hex digits -- proves the x64 adapter
        // process actually decoded in legacy32 mode, not long64.
        var AddrHex := Ins.GetValue<string>('address', '');
        Assert.IsTrue(AddrHex.StartsWith('0x') and (AddrHex.Length - 2 <= 8),
          'address does not look like a 32-bit VA: ' + AddrHex);
      end;
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// Zydis is optional (DISASSEMBLY_PLAN.md "Constraints"): this is the path
// every user without the VC++ runtime hits, so it must report cleanly, never
// crash and never fabricate a result. Copies the MCP exe to a scratch
// directory outside the repo, so neither its own-directory Zydis.dll check
// nor its repo-relative fallback can resolve -- leaving ZydisTryLoad's own
// bare-name search (this exe's directory, then PATH) as the only path left,
// which finds nothing on an ordinary machine with no Zydis.dll on PATH.
procedure TMcpE2ETests.Disassemble_ReportsUnavailable_WhenZydisDllNotFound;
begin
  var ScratchDir := TPath.Combine(TPath.GetTempPath, 'mcp_no_zydis_test');
  TDirectory.CreateDirectory(ScratchDir);
  var IsolatedExe := TPath.Combine(ScratchDir, 'DelphiDebuggerMcp.exe');
  TFile.Copy(McpExe, IsolatedExe, True);
  try
    var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
    var C := TMcpTestClient.Start(IsolatedExe);
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

      var R := C.CallTool('disassemble', nil);
      try
        Assert.IsTrue(R is TJSONObject, 'disassemble did not return an object: ' + R.ToJSON);
        var O := TJSONObject(R);
        Assert.IsFalse(O.GetValue<Boolean>('available', True),
          'expected available:false with no Zydis.dll reachable: ' + O.ToJSON);
        Assert.IsTrue(O.GetValue<string>('reason', '') <> '',
          'no reason given for the UNAVAILABLE result: ' + O.ToJSON);
        Assert.IsNull(O.FindValue('instructions'),
          'an UNAVAILABLE result must never carry instructions -- never partial, never fabricated: ' + O.ToJSON);
        Assert.IsNull(O.FindValue('before'),
          'an UNAVAILABLE result must never carry a "before" section either: ' + O.ToJSON);
      finally
        R.Free;
      end;

      C.CallTool('terminate_debuggee', nil).Free;
    finally
      C.Free;
    end;
  finally
    TDirectory.Delete(ScratchDir, True);
  end;
end;

// CTOR_BODY (TWidget.Create) is hit more than once per run (see
// DebuggerTests\DebugSessionTests.pas' own use of the same marker), which is
// what proves a REPLANT rather than a one-time hit: a source breakpoint stops
// on the FIRST call, gets removed, an address breakpoint is set at the exact
// address it stopped at, and continuing must stop there AGAIN on a LATER call.
procedure TMcpE2ETests.SetBreakpointAtAddress_UsingDisassembledAddress_StopsAgain;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'CTOR_BODY');
  Assert.IsTrue(Line > 0, 'CTOR_BODY marker not found');
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

    var StopAddr := '';
    var Snap1 := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap1);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'first CTOR hit did not stop: ' + S.ToJSON);
      var Frames := S.GetValue('frames') as TJSONArray;
      Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'no frames at first stop');
      StopAddr := (Frames.Items[0] as TJSONObject).GetValue<string>('address', '');
      Assert.IsTrue(StopAddr <> '', 'top frame carries no address field');
    finally
      Snap1.Free;
    end;

    C.CallTool('remove_all_breakpoints', nil).Free;

    var AddrArgs := TJSONObject.Create;
    AddrArgs.AddPair('address', StopAddr);
    var SetResult := C.CallTool('set_breakpoint_at_address', AddrArgs);
    var NewId := '';
    try
      var Arr := SetResult as TJSONArray;
      Assert.IsTrue((Arr <> nil) and (Arr.Count = 1), 'expected a one-element array: ' + SetResult.ToJSON);
      var O := Arr.Items[0] as TJSONObject;
      Assert.AreEqual('address', O.GetValue<string>('kind', ''), 'wrong kind');
      Assert.IsTrue(O.GetValue<Boolean>('verified', False),
        'address breakpoint at a live, already-stopped-at address must resolve: ' + O.ToJSON);
      Assert.AreEqual(StopAddr, O.GetValue<string>('address', ''), 'echoed address mismatch');
      Assert.IsTrue(O.GetValue<string>('module', '') <> '', 'no owning module reported');
      NewId := O.GetValue<string>('id', '');
      Assert.IsTrue(NewId <> '', 'no id returned');
    finally
      SetResult.Free;
    end;

    var Snap2 := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap2);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''),
        'address breakpoint did not stop the target on a later call: ' + S.ToJSON);
      var Frames := S.GetValue('frames') as TJSONArray;
      Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'no frames at second stop');
      Assert.AreEqual(StopAddr, (Frames.Items[0] as TJSONObject).GetValue<string>('address', ''),
        'second stop landed at a different address');
    finally
      Snap2.Free;
    end;

    var ListResult := C.CallTool('list_breakpoints', nil);
    try
      var Arr := ListResult as TJSONArray;
      var Found := False;
      for var Item in Arr do begin
        var O := Item as TJSONObject;
        if O.GetValue<string>('id', '') = NewId then begin
          Found := True;
          Assert.AreEqual('address', O.GetValue<string>('kind', ''), 'listed with the wrong kind');
          Assert.IsTrue(O.GetValue<Boolean>('verified', False), 'listed as unverified after firing');
        end;
      end;
      Assert.IsTrue(Found, 'address breakpoint missing from list_breakpoints');
    finally
      ListResult.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// Bitness coverage: the same workflow against the 32-bit build, proving the
// address round trip (a 32-bit VA echoed back and re-resolved) works under
// WOW64 too, not just x64.
procedure TMcpE2ETests.SetBreakpointAtAddress_Win32_StopsAgain;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'CTOR_BODY');
  Assert.IsTrue(Line > 0, 'CTOR_BODY marker not found');
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe32);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var StopAddr := '';
    var Snap1 := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap1);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'first CTOR hit did not stop: ' + S.ToJSON);
      var Frames := S.GetValue('frames') as TJSONArray;
      Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'no frames at first stop');
      StopAddr := (Frames.Items[0] as TJSONObject).GetValue<string>('address', '');
      Assert.IsTrue(StopAddr <> '', 'top frame carries no address field');
      Assert.IsTrue(StopAddr.Length - 2 <= 8, 'expected a 32-bit VA: ' + StopAddr);
    finally
      Snap1.Free;
    end;

    C.CallTool('remove_all_breakpoints', nil).Free;

    var AddrArgs := TJSONObject.Create;
    AddrArgs.AddPair('address', StopAddr);
    var SetResult := C.CallTool('set_breakpoint_at_address', AddrArgs);
    try
      var Arr := SetResult as TJSONArray;
      var O := Arr.Items[0] as TJSONObject;
      Assert.IsTrue(O.GetValue<Boolean>('verified', False),
        'address breakpoint should resolve on Win32 too: ' + O.ToJSON);
    finally
      SetResult.Free;
    end;

    var Snap2 := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap2);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''),
        'address breakpoint did not stop the Win32 target on a later call: ' + S.ToJSON);
    finally
      Snap2.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.SetBreakpointAtAddress_RefusedWhenNotInAnyLoadedModule;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var AddrArgs := TJSONObject.Create;
    AddrArgs.AddPair('address', '0x1');
    var SetResult := C.CallTool('set_breakpoint_at_address', AddrArgs);
    try
      var Arr := SetResult as TJSONArray;
      Assert.IsTrue((Arr <> nil) and (Arr.Count = 1), 'expected a one-element array: ' + SetResult.ToJSON);
      var O := Arr.Items[0] as TJSONObject;
      Assert.IsFalse(O.GetValue<Boolean>('verified', True), '0x1 must not resolve to any loaded module');
      Assert.IsTrue(O.GetValue<string>('message', '') <> '', 'a refusal must name a reason: ' + O.ToJSON);
    finally
      SetResult.Free;
    end;

    var ListResult := C.CallTool('list_breakpoints', nil);
    try
      Assert.AreEqual(0, (ListResult as TJSONArray).Count,
        'a refused address breakpoint must not appear in list_breakpoints');
    finally
      ListResult.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.RemoveBreakpointAtAddress_UnplantsAndDoesNotStopAgain;
begin
  var Line := MarkerLine(EVAL_SOURCE, 'CTOR_BODY');
  Assert.IsTrue(Line > 0, 'CTOR_BODY marker not found');
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

    var StopAddr := '';
    var Snap1 := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap1);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'first CTOR hit did not stop: ' + S.ToJSON);
      StopAddr := ((S.GetValue('frames') as TJSONArray).Items[0] as TJSONObject).GetValue<string>('address', '');
    finally
      Snap1.Free;
    end;

    C.CallTool('remove_all_breakpoints', nil).Free;

    var AddrArgs := TJSONObject.Create;
    AddrArgs.AddPair('address', StopAddr);
    var SetResult := C.CallTool('set_breakpoint_at_address', AddrArgs);
    var NewId := '';
    try
      var O := (SetResult as TJSONArray).Items[0] as TJSONObject;
      Assert.IsTrue(O.GetValue<Boolean>('verified', False), 'address breakpoint should resolve: ' + O.ToJSON);
      NewId := O.GetValue<string>('id', '');
    finally
      SetResult.Free;
    end;

    var RemArgs := TJSONObject.Create;
    RemArgs.AddPair('id', NewId);
    var RemResult := C.CallTool('remove_breakpoint_at_address', RemArgs);
    try
      for var Item in (RemResult as TJSONArray) do
        Assert.AreNotEqual(NewId, (Item as TJSONObject).GetValue<string>('id', ''),
          'removed address breakpoint still listed');
    finally
      RemResult.Free;
    end;

    var Snap2 := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap2);
      Assert.AreEqual('exited', S.GetValue<string>('state', ''),
        'after removal the target must run to exit (INT3 not cleared): ' + S.ToJSON);
    finally
      Snap2.Free;
    end;
  finally
    C.Free;
  end;
end;

{ ---------------------------------------------------- registers (increment 4) - }

// The value must be the SAME address the call stack already reports for the
// stop -- RegisterToJson and FrameListToJson use the identical '0x' + hex
// format, so this is a plain string comparison, not a numeric one.
procedure TMcpE2ETests.GetRegisters_MatchesCallStackRip;
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

    var ExpectedRip := '';
    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'did not stop: ' + S.ToJSON);
      ExpectedRip := ((S.GetValue('frames') as TJSONArray).Items[0] as TJSONObject)
        .GetValue<string>('address', '');
      Assert.IsTrue(ExpectedRip <> '', 'snapshot frame has no address');
    finally
      Snap.Free;
    end;

    var Regs := C.CallTool('get_registers', nil);
    try
      var Arr := Regs as TJSONArray;
      // RIP, RSP, RBP, RAX..RDI (6), R8..R15 (8), EFlags.
      Assert.AreEqual(18, Arr.Count, 'unexpected register count: ' + Arr.ToJSON);
      var Rip: TJSONObject;
      Assert.IsTrue(McpFindRow(Arr, 'RIP', Rip), 'no RIP in get_registers: ' + Arr.ToJSON);
      Assert.AreEqual(ExpectedRip, Rip.GetValue<string>('value', ''),
        'get_registers RIP disagrees with the call stack''s own address for the same stop');
      Assert.AreEqual(8, Rip.GetValue<Integer>('size', -1), 'RIP size should be 8');
      var Rsp: TJSONObject;
      Assert.IsTrue(McpFindRow(Arr, 'RSP', Rsp), 'no RSP in get_registers: ' + Arr.ToJSON);
      Assert.AreNotEqual('0x0', Rsp.GetValue<string>('value', ''), 'RSP should not be zero while stopped');
      var Flags: TJSONObject;
      Assert.IsTrue(McpFindRow(Arr, 'EFlags', Flags), 'no EFlags in get_registers: ' + Arr.ToJSON);
      Assert.AreEqual(4, Flags.GetValue<Integer>('size', -1), 'EFlags size should be 4');
    finally
      Regs.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// The genuinely bitness-sensitive half: on a WOW64 (32-bit) target
// ReadThreadRegisters (WinDebuggerX86.pas) reads Wow64GetThreadContext and
// never sets R8..R15 (TRegisterSnapshot starts zeroed), so they must read
// back as literal zero -- proving the MCP surface passes through what the
// engine actually reports rather than fabricating a 64-register file.
procedure TMcpE2ETests.GetRegisters_Win32_MatchesRipAndZeroExtendsUpperRegisters;
begin
  var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', TargetExe32);
    LaunchArgs.AddPair('sourceRoot', TargetDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;
    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', EVAL_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var ExpectedRip := '';
    var Snap := C.CallTool('continue_and_wait', nil);
    try
      var S := TJSONObject(Snap);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'did not stop: ' + S.ToJSON);
      ExpectedRip := ((S.GetValue('frames') as TJSONArray).Items[0] as TJSONObject)
        .GetValue<string>('address', '');
    finally
      Snap.Free;
    end;

    var Regs := C.CallTool('get_registers', nil);
    try
      var Arr := Regs as TJSONArray;
      var Rip: TJSONObject;
      Assert.IsTrue(McpFindRow(Arr, 'RIP', Rip), 'no RIP in get_registers: ' + Arr.ToJSON);
      Assert.AreEqual(ExpectedRip, Rip.GetValue<string>('value', ''),
        'Win32: get_registers RIP disagrees with the call stack''s own address');
      // A 32-bit address must fit in 8 hex digits -- proves this really read the
      // WOW64 32-bit context, not a stale/garbage 64-bit one.
      Assert.IsTrue(ExpectedRip.Length - 2 <= 8, 'RIP does not look like a 32-bit VA: ' + ExpectedRip);
      for var RegName in ['R8', 'R9', 'R10', 'R11', 'R12', 'R13', 'R14', 'R15'] do begin
        var R: TJSONObject;
        Assert.IsTrue(McpFindRow(Arr, RegName, R), 'no ' + RegName + ' in get_registers: ' + Arr.ToJSON);
        Assert.AreEqual('0x0', R.GetValue<string>('value', ''),
          Format('Win32: %s should read as zero (no such register at this width), got %s',
            [RegName, R.GetValue<string>('value', '')]));
      end;
    finally
      Regs.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.GetRegisters_RefusedBeforeLaunch;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    var R := C.CallTool('get_registers', nil);
    try
      Assert.IsTrue(R is TJSONString,
        'get_registers before launch should be a tool error, not a (possibly empty) array: ' + R.ToJSON);
      Assert.IsTrue((R as TJSONString).Value.ToLower.Contains('stop'),
        'refusal does not explain that the session must be stopped: ' + (R as TJSONString).Value);
    finally
      R.Free;
    end;
  finally
    C.Free;
  end;
end;

// Re-reads via a FRESH get_registers call afterwards (not just the set_register
// response) so the round trip is proven twice: the write reached the thread
// context, and it is still there on a later, independent read.
procedure TMcpE2ETests.SetRegister_WritesAndReadsBack;
const
  SENTINEL = '0x1122334455667788';
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

    var SetArgs := TJSONObject.Create;
    SetArgs.AddPair('name', 'RAX');
    SetArgs.AddPair('value', SENTINEL);
    var SetResult := C.CallTool('set_register', SetArgs);
    try
      Assert.IsTrue(SetResult is TJSONObject, 'set_register errored: ' + SetResult.ToJSON);
      var O := TJSONObject(SetResult);
      Assert.AreEqual('RAX', O.GetValue<string>('name', ''), 'wrong register echoed back');
      Assert.AreEqual(SENTINEL, O.GetValue<string>('value', ''),
        'set_register''s own response does not show the new value');
      Assert.AreEqual(8, O.GetValue<Integer>('size', -1), 'RAX size should be 8');
    finally
      SetResult.Free;
    end;

    var Regs := C.CallTool('get_registers', nil);
    try
      var Rax: TJSONObject;
      Assert.IsTrue(McpFindRow(Regs as TJSONArray, 'RAX', Rax), 'no RAX in get_registers');
      Assert.AreEqual(SENTINEL, Rax.GetValue<string>('value', ''),
        'a later, independent get_registers call does not see the write');
    finally
      Regs.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.SetRegister_UnknownName_Refused;
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

    var SetArgs := TJSONObject.Create;
    SetArgs.AddPair('name', 'NOTAREGISTER');
    SetArgs.AddPair('value', '0x1');
    var R := C.CallTool('set_register', SetArgs);
    try
      Assert.IsTrue(R is TJSONString,
        'an unrecognised register name should be a tool error, never silently ignored: ' + R.ToJSON);
      Assert.IsTrue((R as TJSONString).Value.Contains('NOTAREGISTER'),
        'refusal does not name the unrecognised register: ' + (R as TJSONString).Value);
    finally
      R.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

{ -------------------------------------------- instruction stepping (increment 4) - }

function McpExePath(const RootDir: string): string;
begin
  Result := RootDir + 'MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe';
end;

procedure OpenInstrSampleAt(C: TMcpTestClient; const RootDir, Bitness, Marker: string);
begin
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(RootDir + INSTR_SAMPLE_SOURCE);
    var Tag := '{BP:' + Marker + '}';
    var Line := 0;
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then begin
        Line := I + 1;
        Break;
      end;
    Assert.IsTrue(Line > 0, 'marker ' + Marker + ' not found in ' + INSTR_SAMPLE_SOURCE);

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', InstrSampleExe(RootDir, Bitness));
    LaunchArgs.AddPair('sourceRoot', RootDir);
    C.CallTool('launch_debuggee', LaunchArgs).Free;

    var BpArgs := TJSONObject.Create;
    BpArgs.AddPair('sourceFile', INSTR_SAMPLE_SOURCE);
    BpArgs.AddPair('line', TJSONNumber.Create(Line));
    C.CallTool('set_breakpoint', BpArgs).Free;

    var Snap := C.CallTool('continue_and_wait', nil);
    try
      Assert.AreEqual('stopped', TJSONObject(Snap).GetValue<string>('state', ''),
        Format('%s: did not stop at %s (line %d): %s', [Bitness, Marker, Line, Snap.ToJSON]));
    finally
      Snap.Free;
    end;
  finally
    Lines.Free;
  end;
end;

function SnapshotLine(Snap: TJSONValue): Integer;
begin
  Result := ((Snap as TJSONObject).GetValue('location') as TJSONObject).GetValue<Integer>('line', -1);
end;

function SnapshotFunction(Snap: TJSONValue): string;
begin
  Result := ((Snap as TJSONObject).GetValue('location') as TJSONObject).GetValue<string>('function', '');
end;

function SnapshotIp(Snap: TJSONValue): string;
begin
  Result := (((Snap as TJSONObject).GetValue('frames') as TJSONArray).Items[0] as TJSONObject)
    .GetValue<string>('address', '');
end;

procedure RunStepIntoInstructionAdvancesOneInstructionSameLine(const RootDir, Bitness: string);
begin
  var C := TMcpTestClient.Start(McpExePath(RootDir));
  try
    C.Call('initialize', nil).Free;
    OpenInstrSampleAt(C, RootDir + 'DebuggerTests\TestTarget\', Bitness, 'INSTR_MULTI');

    var Before := C.CallTool('get_compact_debug_snapshot', nil);
    var LineBefore := SnapshotLine(Before);
    var IpBefore := SnapshotIp(Before);
    Before.Free;

    var StepArgs := TJSONObject.Create;
    StepArgs.AddPair('granularity', 'instruction');
    var After := C.CallTool('step_into', StepArgs);
    try
      Assert.AreEqual('stopped', (After as TJSONObject).GetValue<string>('state', ''),
        Format('%s: instruction-granularity step_into did not stop: %s', [Bitness, After.ToJSON]));
      Assert.AreEqual(LineBefore, SnapshotLine(After),
        Format('%s: an instruction-granularity step_into left the source line -- that is a ' +
               'statement-granularity step, not an instruction one', [Bitness]));
      Assert.AreNotEqual(IpBefore, SnapshotIp(After),
        Format('%s: the instruction pointer did not move at all', [Bitness]));
    finally
      After.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.StepInto_Instruction_AdvancesOneInstructionSameLine;
begin
  RunStepIntoInstructionAdvancesOneInstructionSameLine(RepoRoot, 'Win64');
end;

procedure TMcpE2ETests.StepInto_Instruction_Win32_AdvancesOneInstructionSameLine;
begin
  RunStepIntoInstructionAdvancesOneInstructionSameLine(RepoRoot, 'Win32');
end;

procedure TMcpE2ETests.StepOver_Instruction_AdvancesOneInstructionSameLine;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    OpenInstrSampleAt(C, TargetDir, 'Win64', 'INSTR_MULTI');

    var Before := C.CallTool('get_compact_debug_snapshot', nil);
    var LineBefore := SnapshotLine(Before);
    var IpBefore := SnapshotIp(Before);
    Before.Free;

    var StepArgs := TJSONObject.Create;
    StepArgs.AddPair('granularity', 'instruction');
    var After := C.CallTool('step_over', StepArgs);
    try
      Assert.AreEqual('stopped', (After as TJSONObject).GetValue<string>('state', ''),
        'instruction-granularity step_over did not stop: ' + After.ToJSON);
      Assert.AreEqual(LineBefore, SnapshotLine(After),
        'an instruction-granularity step_over left the source line');
      Assert.AreNotEqual(IpBefore, SnapshotIp(After), 'the instruction pointer did not move at all');
    finally
      After.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure RunStepOutInstructionLandsInTheCaller(const RootDir, Bitness: string);
begin
  var C := TMcpTestClient.Start(McpExePath(RootDir));
  try
    C.Call('initialize', nil).Free;
    OpenInstrSampleAt(C, RootDir + 'DebuggerTests\TestTarget\', Bitness, 'INSTR_CALLEE_BODY');

    var Before := C.CallTool('get_compact_debug_snapshot', nil);
    var FnBefore := SnapshotFunction(Before);
    Before.Free;
    Assert.IsTrue(FnBefore.ToLower.Contains('instrstepcallee'),
      Format('%s: did not stop inside the callee, got "%s"', [Bitness, FnBefore]));

    var StepArgs := TJSONObject.Create;
    StepArgs.AddPair('granularity', 'instruction');
    var After := C.CallTool('step_out', StepArgs);
    try
      Assert.AreEqual('stopped', (After as TJSONObject).GetValue<string>('state', ''),
        Format('%s: instruction-granularity step_out did not stop: %s', [Bitness, After.ToJSON]));
      var FnAfter := SnapshotFunction(After);
      Assert.IsTrue(FnAfter.ToLower.Contains('instrstepcallscenario'),
        Format('%s: instruction-granularity step_out landed in "%s", not in the caller',
          [Bitness, FnAfter]));
    finally
      After.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.StepOut_Instruction_LandsInTheCaller;
begin
  RunStepOutInstructionLandsInTheCaller(RepoRoot, 'Win64');
end;

procedure TMcpE2ETests.StepOut_Instruction_Win32_LandsInTheCaller;
begin
  RunStepOutInstructionLandsInTheCaller(RepoRoot, 'Win32');
end;

// The FIRST MCP coverage of plain (statement-level) step_into at all -- proves
// granularity absent, and granularity="statement" explicitly, both still run
// to the NEXT SOURCE LINE (the pre-existing, untouched behaviour), unlike the
// instruction-granularity tests above which stay on the same line.
procedure TMcpE2ETests.StepInto_GranularityAbsentOrStatement_StillAdvancesToNewLine;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    OpenInstrSampleAt(C, TargetDir, 'Win64', 'INSTR_MULTI');

    var Snap0 := C.CallTool('get_compact_debug_snapshot', nil);
    var Line0 := SnapshotLine(Snap0);
    Snap0.Free;

    // No "granularity" argument at all.
    var After1 := C.CallTool('step_into', nil);
    var Line1 := -1;
    try
      Assert.AreEqual('stopped', (After1 as TJSONObject).GetValue<string>('state', ''),
        'granularity-absent step_into did not stop: ' + After1.ToJSON);
      Line1 := SnapshotLine(After1);
      Assert.AreNotEqual(Line0, Line1,
        'granularity-absent step_into did not advance to a new source line -- this is a ' +
        'regression in the EXISTING (statement-level) behaviour');
    finally
      After1.Free;
    end;

    // Explicit granularity="statement".
    var StepArgs := TJSONObject.Create;
    StepArgs.AddPair('granularity', 'statement');
    var After2 := C.CallTool('step_into', StepArgs);
    try
      Assert.AreEqual('stopped', (After2 as TJSONObject).GetValue<string>('state', ''),
        'granularity="statement" step_into did not stop: ' + After2.ToJSON);
      Assert.AreNotEqual(Line1, SnapshotLine(After2),
        'granularity="statement" step_into did not advance to a new source line -- this is a ' +
        'regression in the EXISTING (statement-level) behaviour');
    finally
      After2.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

procedure TMcpE2ETests.StepOver_UnknownGranularity_Refused;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    OpenInstrSampleAt(C, TargetDir, 'Win64', 'INSTR_MULTI');

    var Before := C.CallTool('get_compact_debug_snapshot', nil);
    var LineBefore := SnapshotLine(Before);
    Before.Free;

    var StepArgs := TJSONObject.Create;
    StepArgs.AddPair('granularity', 'bogus');
    var R := C.CallTool('step_over', StepArgs);
    try
      Assert.IsTrue(R is TJSONString,
        'an unknown granularity should be a tool error, never silently treated as "statement": ' +
        R.ToJSON);
      Assert.IsTrue((R as TJSONString).Value.ToLower.Contains('granularity'),
        'refusal does not name the bad argument: ' + (R as TJSONString).Value);
    finally
      R.Free;
    end;

    // Nothing must have moved: no wait was armed, so the session is still
    // sitting exactly where it stopped.
    var Status := C.CallTool('get_debug_session_status', nil);
    try
      var S := TJSONObject(Status);
      Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'a refused step must not resume: ' + S.ToJSON);
      Assert.AreEqual(LineBefore,
        (S.GetValue('location') as TJSONObject).GetValue<Integer>('line', -1),
        'a refused step must not move the program counter');
    finally
      Status.Free;
    end;

    C.CallTool('terminate_debuggee', nil).Free;
  finally
    C.Free;
  end;
end;

// The one refusal reliably reachable without launching anything: there is
// nothing to step before a target exists. Mirrors
// InstructionStepDapTests.Refused_WhenNotLaunched_ReachesClientAsFailedRequest.
procedure TMcpE2ETests.StepInto_Instruction_RefusedBeforeLaunch;
begin
  var C := TMcpTestClient.Start(McpExe);
  try
    C.Call('initialize', nil).Free;
    var StepArgs := TJSONObject.Create;
    StepArgs.AddPair('granularity', 'instruction');
    var R := C.CallTool('step_into', StepArgs);
    try
      Assert.IsTrue(R is TJSONString,
        'an instruction-granularity step_into before launch was accepted -- there is nothing to step: ' +
        R.ToJSON);
      Assert.IsTrue((R as TJSONString).Value.ToLower.Contains('debuggee'),
        'refusal does not say there is no active debuggee: ' + (R as TJSONString).Value);
    finally
      R.Free;
    end;
  finally
    C.Free;
  end;
end;

// The disassembler-unavailable refusal, reached from OUTSIDE the process (MCP
// is a separate exe, unlike the DAP adapter InstructionStepDapTests drives in-
// process) -- same isolation trick as Disassemble_ReportsUnavailable_
// WhenZydisDllNotFound: copy the MCP exe to a scratch directory neither its
// own-directory Zydis.dll check nor its repo-relative fallback can resolve,
// leaving ZydisTryLoad's bare-name search (this exe's directory, then PATH) as
// the only path left, which finds nothing on an ordinary machine.
procedure TMcpE2ETests.StepInto_Instruction_RefusedWhenDisassemblerUnavailable;
begin
  var ScratchDir := TPath.Combine(TPath.GetTempPath, 'mcp_no_zydis_step_test');
  TDirectory.CreateDirectory(ScratchDir);
  var IsolatedExe := TPath.Combine(ScratchDir, 'DelphiDebuggerMcp.exe');
  TFile.Copy(McpExe, IsolatedExe, True);
  try
    var Line := MarkerLine(EVAL_SOURCE, EVAL_MARKER);
    var C := TMcpTestClient.Start(IsolatedExe);
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

      var StepArgs := TJSONObject.Create;
      StepArgs.AddPair('granularity', 'instruction');
      var R := C.CallTool('step_into', StepArgs);
      try
        Assert.IsTrue(R is TJSONString,
          'instruction step with no Zydis reachable was ACCEPTED -- this project has no fallback ' +
          'decoder and must never guess an instruction length: ' + R.ToJSON);
        Assert.IsTrue((R as TJSONString).Value.ToLower.Contains('disassembler'),
          'the refusal does not say what is missing: ' + (R as TJSONString).Value);
      finally
        R.Free;
      end;

      var Status := C.CallTool('get_debug_session_status', nil);
      try
        var S := TJSONObject(Status);
        Assert.AreEqual('stopped', S.GetValue<string>('state', ''), 'a refused step must not resume: ' + S.ToJSON);
        Assert.AreEqual(Line,
          (S.GetValue('location') as TJSONObject).GetValue<Integer>('line', -1),
          'a refused step must not move the program counter');
      finally
        Status.Free;
      end;

      C.CallTool('terminate_debuggee', nil).Free;
    finally
      C.Free;
    end;
  finally
    TDirectory.Delete(ScratchDir, True);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMcpE2ETests);

end.
