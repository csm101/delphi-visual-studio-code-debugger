unit McpServer;

// MCP (Model Context Protocol) frontend over TDebugSession. Speaks JSON-RPC 2.0
// over stdio using newline-delimited framing (the MCP stdio transport: one
// compact JSON message per line, no embedded newlines). Exposes semantic
// debugging tools -- no raw DAP ids ever cross this boundary.
//
// Async model: MCP/JSON-RPC has no server->client events, so a stop is folded
// into the tool response. A wait-class tool (continue_and_wait, step_*, pause,
// wait_until_stopped) posts its command, records the request id in FWait, and
// returns WITHOUT responding. The Run loop keeps pumping the session; when the
// stop generation advances (or the target exits) it sends the deferred snapshot
// response. No arbitrary sleeps: the per-event 10 ms wait inside Pump paces it,
// and a deadline bounds the wait.

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Winapi.Windows, System.SyncObjs,
  DebugSession, DebugSessionTypes, DebugTarget, ProcessEnum;

type
  TMcpIO = class
  private
    FIn:      THandle;
    FOut:     THandle;
    FOutLock: TCriticalSection;
    procedure WriteRaw(const S: string);
  public
    constructor Create;
    destructor Destroy; override;
    // Reads one newline-delimited JSON message. Returns nil on EOF.
    function  ReadMessage: TJSONObject;
    procedure SendResult(const IdJson: string; ResultVal: TJSONValue);
    procedure SendError(const IdJson: string; Code: Integer; const Msg: string);
  end;

  TPendingWait = record
    Active:   Boolean;
    IdJson:   string;
    Baseline: UInt64;
    Deadline: UInt64;
  end;

  TMcpServer = class
  private
    FIO:      TMcpIO;
    FSession: TDebugSession;
    FQuit:    Boolean;
    FWait:    TPendingWait;

    // Data breakpoints (watchpoints; increment 5 of docs/DATA_BREAKPOINTS_PLAN.md).
    // TDebugSession.SetDataBreakpoints replaces the WHOLE set on every call
    // (mirrors DAP's own setDataBreakpoints) and reassigns every entry a FRESH
    // session-level Id each time, even for specs that did not change -- so an id
    // handed back after one set_data_breakpoint call is no longer the id of that
    // same watchpoint after the next one. The MCP tool surface wants to add and
    // remove ONE watchpoint at a time with a STABLE id, so this layer keeps its
    // own accumulated spec list (the source of truth SetDataBreakpoints is always
    // called with in full) plus a parallel array of MCP-owned ids that never
    // change once issued. Kept in lockstep by construction: every mutation
    // (add/remove) updates both arrays together, then resends the whole list.
    FDataBpSpecs:     TArray<TDataBpSpec>;
    FDataBpOwnIds:    TArray<string>;
    FNextDataBpOwnId: Integer;

    procedure ProcessRpc(Msg: TJSONObject);
    procedure DispatchInitialize(const IdJson: string);
    procedure DispatchToolsList(const IdJson: string);
    procedure DispatchToolsCall(const IdJson: string; Params: TJSONObject);
    // Shared attach flow: resolve pid (from a name, rejecting ambiguity), gate on
    // architecture, default the program path, attach, and arm the entry-break wait.
    procedure PerformAttach(const IdJson: string; Pid: Cardinal; const PName: string;
                KillOnDetach: Boolean; Opts: TAttachOptions);
    // Recreate FSession when the previous debuggee has ended so a new launch/attach
    // is not refused forever by a lingering terminal-state session.
    procedure EnsureFreshSessionForStart;

    procedure ArmWait(const IdJson: string; TimeoutMs: Integer);
    procedure FulfilPendingWait;
    procedure CheckWaitTimeout;
    procedure HandleReadMemory(const IdJson, AddrStr: string; Count: Integer);
    procedure HandleWriteMemory(const IdJson, AddrStr, HexBytes: string);
    // docs/DISASSEMBLY_PLAN.md increment 4. AddrStr = '' means "resolve from
    // FrameIndex/ThreadId instead" (same frame-selection convention
    // get_locals/get_variable/evaluate_expression already use -- no separate
    // opaque frameId shape).
    procedure HandleDisassemble(const IdJson, AddrStr: string;
                FrameIndex: Integer; ThreadId: Cardinal; Count, Before: Integer);
    // docs/DISASSEMBLY_PLAN.md increment 5. AddrStr is parsed the same way
    // read_memory/disassemble parse theirs (ParseAddress: "0x..", "$..", decimal).
    procedure HandleSetBreakpointAtAddress(const IdJson, AddrStr,
                Condition, HitCondition, LogMessage: string);
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 4: step_over/step_into/step_out all
    // funnel through this so "granularity" is handled once. Kind is the
    // pre-existing 1:1 mapping each tool already implies (step_over -> iskOver,
    // etc); the SAME facade increment 2's DAP plumbing calls
    // (TDebugSession.StepInstruction), decided BEFORE the wait is armed so a
    // refusal reaches the caller as isError:true instead of a wait that never
    // resolves.
    procedure HandleStepTool(const IdJson: string; Kind: TInstructionStepKind;
                const Granularity: string; ThreadId: Cardinal);

    // Tool-result envelopes.
    procedure SendToolJson(const IdJson: string; Payload: TJSONValue);
    procedure SendToolError(const IdJson, Msg: string);
    procedure SendSnapshotResult(const IdJson: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

procedure RunMcpServer;

implementation

uses
  System.IOUtils, McpToolSchemas, McpJson, LaunchConfig,
  Disassembler, ZydisDisassembler;

var
  GLogPath: string;

procedure McpLog(const S: string);
begin
  if GLogPath = '' then
    Exit;
  try
    TFile.AppendAllText(GLogPath, FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + S + sLineBreak);
  except
  end;
end;

// Forward: implemented below (near HandleReadMemory), used earlier by
// DispatchToolsCall's set_register handling -- same "0x..", "$..", decimal
// parsing read_memory/write_memory/disassemble/set_breakpoint_at_address
// already share.
function ParseAddress(const S: string; out Addr: UInt64): Boolean; forward;

{ TMcpIO }

constructor TMcpIO.Create;
begin
  inherited Create;
  FIn      := GetStdHandle(STD_INPUT_HANDLE);
  FOut     := GetStdHandle(STD_OUTPUT_HANDLE);
  FOutLock := TCriticalSection.Create;
end;

destructor TMcpIO.Destroy;
begin
  FOutLock.Free;
  inherited;
end;

function TMcpIO.ReadMessage: TJSONObject;
var
  Bytes:   TBytes;
  B:       Byte;
  Read:    DWORD;
begin
  Result := nil;
  SetLength(Bytes, 0);
  // Accumulate a UTF-8 line up to (and not including) LF; strip a trailing CR.
  while True do begin
    if not ReadFile(FIn, B, 1, Read, nil) or (Read = 0) then begin
      if Length(Bytes) = 0 then
        Exit(nil);   // clean EOF between messages
      Break;         // EOF mid-line: parse what we have
    end;
    if B = 10 then
      Break;
    if B = 13 then
      Continue;
    Bytes := Bytes + [B];
  end;
  if Length(Bytes) = 0 then
    Exit(nil);
  var Line := TEncoding.UTF8.GetString(Bytes);
  var V := TJSONObject.ParseJSONValue(Line);
  if V is TJSONObject then
    Result := TJSONObject(V)
  else
    V.Free;
end;

procedure TMcpIO.WriteRaw(const S: string);
begin
  var Bytes := TEncoding.UTF8.GetBytes(S + #10);
  FOutLock.Enter;
  try
    var Written: DWORD;
    WriteFile(FOut, Bytes[0], Length(Bytes), Written, nil);
  finally
    FOutLock.Leave;
  end;
end;

procedure TMcpIO.SendResult(const IdJson: string; ResultVal: TJSONValue);
begin
  var Obj := TJSONObject.Create;
  try
    Obj.AddPair('jsonrpc', '2.0');
    Obj.AddPair('id', McpJson.ParseIdOrNull(IdJson));
    Obj.AddPair('result', ResultVal);
    WriteRaw(Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

procedure TMcpIO.SendError(const IdJson: string; Code: Integer; const Msg: string);
begin
  var Obj := TJSONObject.Create;
  try
    Obj.AddPair('jsonrpc', '2.0');
    Obj.AddPair('id', McpJson.ParseIdOrNull(IdJson));
    var Err := TJSONObject.Create;
    Err.AddPair('code', TJSONNumber.Create(Code));
    Err.AddPair('message', Msg);
    Obj.AddPair('error', Err);
    WriteRaw(Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

{ TMcpServer }

constructor TMcpServer.Create;
begin
  inherited Create;
  FIO      := TMcpIO.Create;
  FSession := TDebugSession.Create;
end;

destructor TMcpServer.Destroy;
begin
  FSession.Free;
  FIO.Free;
  inherited;
end;

procedure TMcpServer.SendToolJson(const IdJson: string; Payload: TJSONValue);
begin
  // MCP tools return { content: [ { type:"text", text:<compact json> } ] }.
  var ResultObj := TJSONObject.Create;
  var Content := TJSONArray.Create;
  var Item := TJSONObject.Create;
  Item.AddPair('type', 'text');
  Item.AddPair('text', Payload.ToJSON);
  Content.Add(Item);
  ResultObj.AddPair('content', Content);
  Payload.Free;
  FIO.SendResult(IdJson, ResultObj);
end;

procedure TMcpServer.SendToolError(const IdJson, Msg: string);
begin
  var ResultObj := TJSONObject.Create;
  var Content := TJSONArray.Create;
  var Item := TJSONObject.Create;
  Item.AddPair('type', 'text');
  Item.AddPair('text', Msg);
  Content.Add(Item);
  ResultObj.AddPair('content', Content);
  ResultObj.AddPair('isError', TJSONBool.Create(True));
  FIO.SendResult(IdJson, ResultObj);
end;

procedure TMcpServer.SendSnapshotResult(const IdJson: string);
begin
  SendToolJson(IdJson, McpJson.SnapshotToJson(FSession.Snapshot));
end;

procedure TMcpServer.EnsureFreshSessionForStart;
begin
  // A session that has ended (terminated / exited / detached, or the engine
  // reports the target gone) can never host a new debuggee: TDebugSession.Launch
  // rejects any state other than dsNone. Replace it with a clean instance so the
  // server accepts the next launch/attach instead of failing with "A debug
  // session is already active" for the rest of the process lifetime.
  // A genuinely live session (dsRunning / dsStopped) is left untouched so Launch
  // still rejects a concurrent start.
  if (FSession.State in [dsExited, dsDetached, dsTerminated]) or FSession.HasExited then begin
    FSession.Free;
    FSession := TDebugSession.Create;
    FWait.Active := False;
    // A fresh session's own FDataBreakpoints starts empty; this layer's
    // bookkeeping must follow or list_data_breakpoints would keep reporting
    // watchpoints from a debuggee that no longer exists.
    FDataBpSpecs  := nil;
    FDataBpOwnIds := nil;
  end;
end;

// "write" -> WriteOnly=True (the only access type with a real hardware
// equivalent); "readWrite" -> WriteOnly=False (read-or-write -- there is no
// read-only watchpoint on x86/x64). "read" alone is refused outright rather
// than silently mapped to readWrite: accepting it would let a caller believe
// it filtered out writes, which no x86/x64 hardware watchpoint can do.
function ParseDataBpAccess(const Access: string; out WriteOnly: Boolean;
  out ErrMsg: string): Boolean;
begin
  ErrMsg := '';
  if SameText(Access, 'write') then begin
    WriteOnly := True;
    Exit(True);
  end;
  if SameText(Access, 'readWrite') then begin
    WriteOnly := False;
    Exit(True);
  end;
  WriteOnly := False;
  if SameText(Access, 'read') then
    ErrMsg := '"read" has no hardware equivalent on x86/x64 -- there is no read-only ' +
      'watchpoint. Use "readWrite" to also catch reads (it ALSO fires on writes, it does ' +
      'not filter them out), or "write" to only catch writes.'
  else
    ErrMsg := Format('unknown access "%s" -- use "write" or "readWrite".', [Access]);
  Result := False;
end;

procedure TMcpServer.ArmWait(const IdJson: string; TimeoutMs: Integer);
begin
  FWait.Active   := True;
  FWait.IdJson   := IdJson;
  FWait.Baseline := FSession.StopGeneration;
  FWait.Deadline := GetTickCount64 + UInt64(TimeoutMs);
end;

procedure TMcpServer.FulfilPendingWait;
begin
  if not FWait.Active then
    Exit;
  if (FSession.StopGeneration > FWait.Baseline) or FSession.HasExited then begin
    FWait.Active := False;
    SendSnapshotResult(FWait.IdJson);
  end;
end;

procedure TMcpServer.CheckWaitTimeout;
begin
  if not FWait.Active then
    Exit;
  if GetTickCount64 >= FWait.Deadline then begin
    FWait.Active := False;
    SendSnapshotResult(FWait.IdJson);  // snapshot reports state=running
  end;
end;

procedure TMcpServer.DispatchInitialize(const IdJson: string);
begin
  var R := TJSONObject.Create;
  R.AddPair('protocolVersion', '2024-11-05');
  var Caps := TJSONObject.Create;
  Caps.AddPair('tools', TJSONObject.Create);
  R.AddPair('capabilities', Caps);
  var Info := TJSONObject.Create;
  Info.AddPair('name', 'delphi-win64-debugger');
  Info.AddPair('version', '0.1.0');
  R.AddPair('serverInfo', Info);
  FIO.SendResult(IdJson, R);
end;

procedure TMcpServer.DispatchToolsList(const IdJson: string);
begin
  var R := TJSONObject.Create;
  R.AddPair('tools', McpToolSchemas.BuildToolsArray);
  FIO.SendResult(IdJson, R);
end;

procedure TMcpServer.PerformAttach(const IdJson: string; Pid: Cardinal;
  const PName: string; KillOnDetach: Boolean; Opts: TAttachOptions);
begin
  EnsureFreshSessionForStart;
  if Pid = 0 then begin
    if PName = '' then begin
      SendToolError(IdJson, 'Provide processId or processName (or a config with one).');
      Exit;
    end;
    var Matches := ProcessEnum.FindProcessesByName(PName);
    if Length(Matches) = 0 then begin
      SendToolError(IdJson, Format('No running process matches "%s".', [PName]));
      Exit;
    end;
    if Length(Matches) > 1 then begin
      SendToolError(IdJson, 'Ambiguous: ' + IntToStr(Length(Matches)) +
        ' processes match "' + PName + '". Pick a pid: ' +
        McpJson.ProcessListToJson(Matches).ToJSON);
      Exit;
    end;
    Pid := Matches[0].Pid;
  end;

  var Info: TProcessInfo;
  if not ProcessEnum.GetProcessInfo(Pid, Info) then begin
    SendToolError(IdJson, Format('Process %d not found (it may have exited).', [Pid]));
    Exit;
  end;
  var Reason: string;
  if not ProcessEnum.CanDebug(Info, Reason) then begin
    SendToolError(IdJson, 'Cannot attach: ' + Reason);
    Exit;
  end;
  if Opts.ProgramPath = '' then
    Opts.ProgramPath := Info.ExePath;
  FSession.Attach(Pid, KillOnDetach, Opts);
  ArmWait(IdJson, 30000);  // wait for the initial attach-break
end;

procedure TMcpServer.DispatchToolsCall(const IdJson: string; Params: TJSONObject);
var
  Name: string;
  Args: TJSONObject;

  function ArgStr(const Key: string; const Def: string = ''): string;
  begin
    if Args <> nil then
      Result := Args.GetValue<string>(Key, Def)
    else
      Result := Def;
  end;
  function ArgInt(const Key: string; Def: Integer = 0): Integer;
  begin
    if Args <> nil then
      Result := Args.GetValue<Integer>(Key, Def)
    else
      Result := Def;
  end;
  function ArgBool(const Key: string; Def: Boolean = False): Boolean;
  begin
    if Args <> nil then
      Result := Args.GetValue<Boolean>(Key, Def)
    else
      Result := Def;
  end;
  function ArgStrArray(const Key: string): TArray<string>;
  begin
    Result := nil;
    if Args = nil then
      Exit;
    var V := Args.FindValue(Key);
    if V is TJSONArray then
      for var Item in TJSONArray(V) do
        Result := Result + [Item.Value];
  end;
  function Stopped: Boolean;
  begin
    Result := FSession.State = dsStopped;
  end;

  // F18: read locals/variables in a CALLER frame, or in a frame of another
  // thread, instead of always the top frame of the stopped thread. After a pause
  // the top frame is almost always inside a system DLL (a wait or the message
  // pump), where no local and not even a global resolves -- exactly when an
  // agent pauses to look around.
  //
  // The engine's active frame is GLOBAL and survives until the next stop, so a
  // selection left behind would make the NEXT request silently read the wrong
  // frame. Every use is therefore paired with EndSelectedFrame in a finally.
  // True when the caller actually named a frame. `frameIndex: 0` is a request
  // for the top frame and must not read as "no frame given" -- at an exception
  // stop the two now mean different things (the top frame is the raise/fault
  // site; the session's default is the frame that has the locals), so the
  // presence of the key is the question, not its value.
  function FrameArgGiven: Boolean;
  begin
    Result := (Args <> nil) and (Args.FindValue('frameIndex') <> nil);
  end;

  procedure BeginSelectedFrame;
  begin
    var ThreadId := Cardinal(ArgInt('threadId', 0));
    if FrameArgGiven or (ThreadId <> 0) then
      FSession.SelectFrame(ArgInt('frameIndex', 0), ThreadId);
  end;

  procedure EndSelectedFrame;
  begin
    if FrameArgGiven or (ArgInt('threadId', 0) <> 0) then
      FSession.ClearFrame;
  end;

begin
  Name := Params.GetValue<string>('name', '');
  Args := nil;
  var AV := Params.FindValue('arguments');
  if AV is TJSONObject then
    Args := TJSONObject(AV);

  McpLog('tools/call ' + Name);

  try
    // ---- process listing ----
    if Name = 'list_debuggable_processes' then begin
      var Processes := ProcessEnum.EnumerateProcesses(ArgStr('nameFilter'));
      ProcessEnum.AttachMainWindowTitles(Processes);
      SendToolJson(IdJson, McpJson.ProcessListToJson(Processes));
      Exit;
    end;

    // ---- launch ----
    if Name = 'launch_debuggee' then begin
      EnsureFreshSessionForStart;
      var Opts: TLaunchOptions;
      Opts             := Default(TLaunchOptions);
      Opts.ExePath     := ArgStr('program');
      Opts.Args        := ArgStr('args');
      Opts.MapPath     := ArgStr('mapFile');
      Opts.RsmPath     := ArgStr('rsmFile');
      Opts.SourceRoot  := ArgStr('sourceRoot');
      Opts.ExtraSourcePaths := LaunchConfig.ExpandSearchPaths(ArgStrArray('sourceSearchPaths'), ArgStr('workspaceFolder'));
      var ExcFilters := ArgStrArray('exceptionFilters');
      if Length(ExcFilters) > 0 then begin
        Opts.ExceptionFilters    := TDebugSession.ParseExceptionFilters(ExcFilters);
        Opts.ExceptionFiltersSet := True;
        Opts.DelphiClassFilter   := ArgStr('delphiExceptionClasses');
      end;
      // Always stop at entry so breakpoints can be set BEFORE any user code runs.
      // Without this the Run loop would pump past the entry point (and any not-yet-
      // set breakpoint) before the agent's set_breakpoint call arrives. The agent
      // then sets breakpoints and calls continue_and_wait. The stopAtEntry arg is
      // accepted for compatibility but entry-stop is unconditional for safety.
      Opts.StopAtEntry := True;
      FSession.Launch(Opts);
      ArmWait(IdJson, 30000);          // wait for the entry stop
      Exit;
    end;

    // ---- launch from an existing VS Code launch.json ----
    if Name = 'launch_from_config' then begin
      EnsureFreshSessionForStart;
      var CfgFile := ArgStr('configFile');
      if CfgFile = '' then
        CfgFile := TPath.Combine(TDirectory.GetCurrentDirectory, '.vscode\launch.json');
      var Opts: TLaunchOptions;
      var Err: string;
      if not LaunchConfig.LoadLaunchConfig(CfgFile, ArgStr('configName'),
           ArgStr('workspaceFolder'), Opts, Err) then begin
        SendToolError(IdJson, Err);
        Exit;
      end;
      Opts.StopAtEntry := True;
      FSession.Launch(Opts);
      ArmWait(IdJson, 30000);
      Exit;
    end;

    // ---- attach ----
    if Name = 'attach_to_process' then begin
      var Opts: TAttachOptions;
      Opts                  := Default(TAttachOptions);
      Opts.ProgramPath      := ArgStr('program');
      Opts.MapPath          := ArgStr('mapFile');
      Opts.RsmPath          := ArgStr('rsmFile');
      Opts.SourceRoot       := ArgStr('sourceRoot');
      Opts.ExtraSourcePaths := LaunchConfig.ExpandSearchPaths(ArgStrArray('sourceSearchPaths'), ArgStr('workspaceFolder'));
      PerformAttach(IdJson, Cardinal(ArgInt('processId', 0)), ArgStr('processName'),
        ArgBool('killOnDetach'), Opts);
      Exit;
    end;

    // ---- attach using an existing VS Code launch.json (request "attach") ----
    if Name = 'attach_from_config' then begin
      var CfgFile := ArgStr('configFile');
      if CfgFile = '' then
        CfgFile := TPath.Combine(TDirectory.GetCurrentDirectory, '.vscode\launch.json');
      var Opts: TAttachOptions;
      var Pid: Cardinal;
      var PName, Err: string;
      if not LaunchConfig.LoadAttachConfig(CfgFile, ArgStr('configName'),
           ArgStr('workspaceFolder'), Opts, Pid, PName, Err) then begin
        SendToolError(IdJson, Err);
        Exit;
      end;
      PerformAttach(IdJson, Pid, PName, ArgBool('killOnDetach'), Opts);
      Exit;
    end;

    // ---- lifecycle ----
    if Name = 'detach_debugger' then begin
      FSession.Detach;
      SendToolJson(IdJson, McpJson.StatusToJson(FSession));
      Exit;
    end;
    if Name = 'terminate_debuggee' then begin
      FSession.Terminate;
      SendToolJson(IdJson, McpJson.StatusToJson(FSession));
      Exit;
    end;
    if Name = 'stop_debugging' then begin
      FSession.StopDebugging;
      SendToolJson(IdJson, McpJson.StatusToJson(FSession));
      Exit;
    end;
    if Name = 'get_debug_session_status' then begin
      SendToolJson(IdJson, McpJson.StatusToJson(FSession));
      Exit;
    end;

    // ---- breakpoints ----
    if Name = 'set_breakpoint' then begin
      var Spec: TBpLineSpec;
      Spec              := Default(TBpLineSpec);
      Spec.Line         := ArgInt('line');
      Spec.Condition    := ArgStr('condition');
      Spec.HitCondition := ArgStr('hitCondition');
      Spec.LogMessage   := ArgStr('logMessage');
      var Bps := FSession.SetBreakpoints(ArgStr('sourceFile'), [Spec]);
      SendToolJson(IdJson, McpJson.BreakpointListToJson(Bps));
      Exit;
    end;
    if Name = 'set_breakpoints' then begin
      var BpArr := Args.FindValue('breakpoints');
      if not (BpArr is TJSONArray) then begin
        SendToolError(IdJson, 'Provide a "breakpoints" array of { sourceFile, line, ... }.');
        Exit;
      end;
      var ByFile := TDictionary<string, TList<TBpLineSpec>>.Create;
      try
        for var Item in TJSONArray(BpArr) do begin
          if not (Item is TJSONObject) then
            Continue;
          var O := TJSONObject(Item);
          var SrcFile := O.GetValue<string>('sourceFile', '');
          if SrcFile = '' then
            Continue;
          var Spec: TBpLineSpec;
          Spec              := Default(TBpLineSpec);
          Spec.Line         := O.GetValue<Integer>('line', 0);
          Spec.Condition    := O.GetValue<string>('condition', '');
          Spec.HitCondition := O.GetValue<string>('hitCondition', '');
          Spec.LogMessage   := O.GetValue<string>('logMessage', '');
          if not ByFile.ContainsKey(SrcFile) then
            ByFile.Add(SrcFile, TList<TBpLineSpec>.Create);
          ByFile[SrcFile].Add(Spec);
        end;
        var All := TList<TSessionBreakpoint>.Create;
        try
          for var KV in ByFile do
            All.AddRange(FSession.SetBreakpoints(KV.Key, KV.Value.ToArray));
          SendToolJson(IdJson, McpJson.BreakpointListToJson(All.ToArray));
        finally
          All.Free;
        end;
      finally
        for var L in ByFile.Values do
          L.Free;
        ByFile.Free;
      end;
      Exit;
    end;
    if Name = 'list_breakpoints' then begin
      SendToolJson(IdJson, McpJson.BreakpointListToJson(FSession.ListBreakpoints));
      Exit;
    end;
    if Name = 'remove_all_breakpoints' then begin
      FSession.RemoveAllBreakpoints;
      SendToolJson(IdJson, McpJson.BreakpointListToJson(FSession.ListBreakpoints));
      Exit;
    end;
    if Name = 'set_breakpoint_at_address' then begin
      HandleSetBreakpointAtAddress(IdJson, ArgStr('address'), ArgStr('condition'),
        ArgStr('hitCondition'), ArgStr('logMessage'));
      Exit;
    end;
    if Name = 'remove_breakpoint_at_address' then begin
      var TargetId := ArgStr('id');
      if not FSession.RemoveAddressBreakpoint(TargetId) then begin
        SendToolError(IdJson, Format('No address breakpoint with id "%s". Use list_breakpoints to see current ids.', [TargetId]));
        Exit;
      end;
      SendToolJson(IdJson, McpJson.BreakpointListToJson(FSession.ListBreakpoints));
      Exit;
    end;

    // ---- data breakpoints (watchpoints) ----
    // Arming/removal both funnel through FSession.SetDataBreakpoints (never a
    // direct RemoveAllDataBreakpoints call) so the session's own "only while
    // stopped" guard always applies -- but gate here too, with a clearer
    // message: a whole-list refusal from the session would otherwise make
    // ALREADY-armed watchpoints look newly broken.
    if Name = 'set_data_breakpoint' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot set a data breakpoint while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      var Expr := ArgStr('expression');
      if Expr = '' then begin
        SendToolError(IdJson, 'Provide "expression" (a literal address like "0x1234"/"1234" or a global/unit variable name).');
        Exit;
      end;
      var WriteOnly: Boolean;
      var AccessErr: string;
      if not ParseDataBpAccess(ArgStr('access'), WriteOnly, AccessErr) then begin
        SendToolError(IdJson, AccessErr);
        Exit;
      end;
      var Spec: TDataBpSpec;
      Spec             := Default(TDataBpSpec);
      Spec.Expression  := Expr;
      Spec.SizeBytes   := ArgInt('size', 0);
      Spec.WriteOnly   := WriteOnly;
      Inc(FNextDataBpOwnId);
      FDataBpSpecs  := FDataBpSpecs  + [Spec];
      FDataBpOwnIds := FDataBpOwnIds + ['wp' + IntToStr(FNextDataBpOwnId)];
      var Results := FSession.SetDataBreakpoints(FDataBpSpecs);
      // Report only the just-added entry (its position is the last one, since
      // specs are only ever appended) -- mirrors set_breakpoint returning what
      // was just set, not the whole accumulated list (list_data_breakpoints is
      // for that).
      if Length(Results) > 0 then
        SendToolJson(IdJson, McpJson.DataBreakpointToJson(Results[High(Results)], FDataBpOwnIds[High(FDataBpOwnIds)]))
      else
        SendToolError(IdJson, 'internal error: no result for the new data breakpoint');
      Exit;
    end;
    if Name = 'list_data_breakpoints' then begin
      SendToolJson(IdJson, McpJson.DataBreakpointListToJson(FSession.ListDataBreakpoints, FDataBpOwnIds));
      Exit;
    end;
    if Name = 'remove_data_breakpoint' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot remove a data breakpoint while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      var TargetId := ArgStr('id');
      var FoundIdx := -1;
      for var I := 0 to High(FDataBpOwnIds) do
        if FDataBpOwnIds[I] = TargetId then begin
          FoundIdx := I;
          Break;
        end;
      if FoundIdx < 0 then begin
        SendToolError(IdJson, Format('No data breakpoint with id "%s". Use list_data_breakpoints to see current ids.', [TargetId]));
        Exit;
      end;
      Delete(FDataBpSpecs, FoundIdx, 1);
      Delete(FDataBpOwnIds, FoundIdx, 1);
      var Results := FSession.SetDataBreakpoints(FDataBpSpecs);
      SendToolJson(IdJson, McpJson.DataBreakpointListToJson(Results, FDataBpOwnIds));
      Exit;
    end;

    // ---- execution control (async-wait) ----
    if Name = 'continue_and_wait' then begin
      FSession.ContinueExecution;
      ArmWait(IdJson, ArgInt('timeoutMs', 30000));
      Exit;
    end;
    if Name = 'step_over' then begin
      HandleStepTool(IdJson, iskOver, ArgStr('granularity'), Cardinal(ArgInt('threadId', 0)));
      Exit;
    end;
    if Name = 'step_into' then begin
      HandleStepTool(IdJson, iskInto, ArgStr('granularity'), Cardinal(ArgInt('threadId', 0)));
      Exit;
    end;
    if Name = 'step_out' then begin
      HandleStepTool(IdJson, iskOut, ArgStr('granularity'), Cardinal(ArgInt('threadId', 0)));
      Exit;
    end;
    if Name = 'pause_execution' then begin
      FSession.Pause;     ArmWait(IdJson, 30000); Exit;
    end;
    if Name = 'wait_until_stopped' then begin
      ArmWait(IdJson, ArgInt('timeoutMs', 30000)); Exit;
    end;

    // ---- inspection (require a stop) ----
    if Name = 'get_current_source_location' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Not stopped. Wait for a breakpoint or pause first.');
        Exit;
      end;
      var Fn, Src: string; var Ln: Integer;
      FSession.GetCurrentLocation(Fn, Src, Ln);
      SendToolJson(IdJson, McpJson.LocationToJson(Fn, Src, Ln));
      Exit;
    end;
    if Name = 'get_call_stack' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot read the call stack while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      var Tid := Cardinal(ArgInt('threadId', 0));
      if Tid <> 0 then
        SendToolJson(IdJson, McpJson.FrameListToJson(FSession.GetCallStack(Tid)))
      else
        SendToolJson(IdJson, McpJson.FrameListToJson(FSession.GetCallStack));
      Exit;
    end;
    if Name = 'get_loaded_modules' then begin
      // Deliberately NOT gated on being stopped: which images are mapped is a
      // property of the process, and the question is most useful exactly when a
      // breakpoint has not bound yet and the agent needs to know whether the
      // owning package is even loaded.
      var Mods := FSession.GetModules;
      if Length(Mods) = 0 then
        SendToolError(IdJson, 'No active debuggee. Launch or attach first.')
      else
        SendToolJson(IdJson, McpJson.ModuleListToJson(Mods));
      Exit;
    end;
    if Name = 'get_source_files' then begin
      // Not gated on being stopped, for the same reason as get_loaded_modules:
      // the answer is a property of what has been loaded, and it is most useful
      // BEFORE running, when a breakpoint file name is being chosen.
      var Groups := FSession.GetModuleSources;
      if Length(Groups) = 0 then begin
        SendToolError(IdJson, 'No active debuggee. Launch or attach first.');
        Exit;
      end;
      var Wanted := Trim(ArgStr('module'));
      if Wanted <> '' then begin
        var Kept: TArray<TSessionModuleSources> := [];
        for var G in Groups do
          if SameText(G.Module, Wanted) then
            Kept := Kept + [G];
        if Length(Kept) = 0 then begin
          SendToolError(IdJson, Format(
            'No module named "%s" is loaded. Use get_loaded_modules to see the exact names.',
            [Wanted]));
          Exit;
        end;
        Groups := Kept;
      end;
      if ArgBool('nameOnly') then
        for var I := 0 to High(Groups) do
          for var J := 0 to High(Groups[I].Files) do
            Groups[I].Files[J].FullPath := '';
      SendToolJson(IdJson, McpJson.ModuleSourcesToJson(Groups));
      Exit;
    end;
    if Name = 'get_raw_stack_scan' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot sweep the stack while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      SendToolJson(IdJson, McpJson.FrameListToJson(
        FSession.GetRawStackScan(Cardinal(ArgInt('threadId', 0)),
                                 ArgInt('maxItems', 0))));
      Exit;
    end;
    if Name = 'get_threads' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot list threads while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      SendToolJson(IdJson, McpJson.ThreadListToJson(FSession.GetThreads));
      Exit;
    end;
    if Name = 'set_exception_filters' then begin
      if not FSession.SetExceptionFilters(ArgStrArray('filters'), ArgStr('delphiExceptionClasses')) then
        SendToolError(IdJson, 'No active debuggee. Launch or attach first.')
      else
        SendToolJson(IdJson, McpJson.StatusToJson(FSession));
      Exit;
    end;
    if Name = 'get_locals' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot read locals while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      BeginSelectedFrame;
      try
        SendToolJson(IdJson, McpJson.VarListToJson(FSession.GetLocals));
      finally
        EndSelectedFrame;
      end;
      Exit;
    end;
    if Name = 'get_variable' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot read a variable while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      BeginSelectedFrame;
      try
        SendToolJson(IdJson, McpJson.VarToJson(FSession.GetVariable(ArgStr('name'))));
      finally
        EndSelectedFrame;
      end;
      Exit;
    end;
    if Name = 'expand_variable' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot expand a variable while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      var HStr := ArgStr('handle');
      var H: UInt64;
      if (HStr = '') or not TryStrToUInt64(HStr, H) then begin
        SendToolError(IdJson, 'Provide a valid "handle" (from get_locals or a prior expand_variable).');
        Exit;
      end;
      SendToolJson(IdJson, McpJson.VarListToJson(FSession.GetChildren(TVarHandle(H))));
      Exit;
    end;
    if Name = 'evaluate_expression' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot evaluate while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      // EvaluateForFrame produces the same rich result the DAP hover/watch uses --
      // including an expansion handle for a class/record/array -- so an object
      // result is drillable via expand_variable (F8). frameIndex/threadId let the
      // caller evaluate in a CALLER frame: after a pause the top frame is usually
      // inside a system DLL, where nothing resolves (F18). With no frameIndex at
      // all the session picks its own default frame, which at an exception stop
      // is the frame that raised rather than the raise site.
      var EvalFrame := DEFAULT_FRAME_INDEX;
      if FrameArgGiven then
        EvalFrame := ArgInt('frameIndex', 0);
      SendToolJson(IdJson, McpJson.EvalResultToJson(
        FSession.EvaluateForFrame(ArgStr('expression'),
          EvalFrame, Cardinal(ArgInt('threadId', 0)))));
      Exit;
    end;
    if Name = 'get_exception_details' then begin
      SendToolJson(IdJson, McpJson.ExceptionToJson(FSession.GetExceptionDetails));
      Exit;
    end;
    if Name = 'get_compact_debug_snapshot' then begin
      SendSnapshotResult(IdJson);
      Exit;
    end;
    if Name = 'get_debuggee_output' then begin
      SendToolJson(IdJson, McpJson.StringListToJson(FSession.DrainDebuggeeOutput));
      Exit;
    end;
    if Name = 'get_debugger_output' then begin
      SendToolJson(IdJson, McpJson.StringListToJson(FSession.DrainDebuggerOutput));
      Exit;
    end;
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 4: the MCP equivalent of DAP's
    // writable Registers scope (REGISTERS_VAR_REF in DapServer.pas). Both go
    // through the SAME session-level path -- FSession.GetRegisters /
    // FSession.SetRegister, backed by TDebugTarget.GetRegisters /
    // SetRegisterByName -- no second mechanism.
    if Name = 'get_registers' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot read registers while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      SendToolJson(IdJson, McpJson.RegisterListToJson(FSession.GetRegisters));
      Exit;
    end;
    if Name = 'set_register' then begin
      if not Stopped then begin
        SendToolError(IdJson, 'Cannot write a register while the debuggee is running. Pause or wait for a stop first.');
        Exit;
      end;
      var RegName := ArgStr('name');
      var RawVal: UInt64;
      if not ParseAddress(ArgStr('value'), RawVal) then begin
        SendToolError(IdJson, 'invalid value: ' + ArgStr('value'));
        Exit;
      end;
      if not FSession.SetRegister(RegName, RawVal) then begin
        SendToolError(IdJson, Format('Unknown register "%s".', [RegName]));
        Exit;
      end;
      // Re-read rather than echo the request back -- the response proves the
      // write reached the thread context instead of merely restating the ask.
      var Written: TRegisterValue;
      if FSession.TryGetRegister(RegName, Written) then
        SendToolJson(IdJson, McpJson.RegisterToJson(Written))
      else
        SendToolError(IdJson, Format('"%s" was written but does not appear in get_registers.', [RegName]));
      Exit;
    end;
    if Name = 'read_memory' then begin
      HandleReadMemory(IdJson, ArgStr('address'), ArgInt('count'));
      Exit;
    end;
    if Name = 'write_memory' then begin
      HandleWriteMemory(IdJson, ArgStr('address'), ArgStr('hexBytes'));
      Exit;
    end;
    if Name = 'disassemble' then begin
      HandleDisassemble(IdJson, ArgStr('address'), ArgInt('frameIndex', 0),
        Cardinal(ArgInt('threadId', 0)), ArgInt('count', 10), ArgInt('before', 0));
      Exit;
    end;

    SendToolError(IdJson, 'Unknown tool: ' + Name);
  except
    on E: Exception do
      SendToolError(IdJson, E.ClassName + ': ' + E.Message);
  end;
end;

function ParseAddress(const S: string; out Addr: UInt64): Boolean;
begin
  var T := Trim(S);
  if T.StartsWith('0x', True) then
    T := '$' + T.Substring(2)
  else if not T.StartsWith('$') then
    T := T;   // decimal
  Result := TryStrToUInt64(T, Addr);
end;

procedure TMcpServer.HandleReadMemory(const IdJson, AddrStr: string; Count: Integer);
var
  Addr: UInt64;
begin
  if (Count < 1) or (Count > 4096) then begin
    SendToolError(IdJson, 'count must be 1..4096');
    Exit;
  end;
  if not ParseAddress(AddrStr, Addr) then begin
    SendToolError(IdJson, 'invalid address: ' + AddrStr);
    Exit;
  end;
  var Buf: TBytes;
  SetLength(Buf, Count);
  if not FSession.Debugger.ReadProcessMemoryAt(Addr, @Buf[0], Count) then begin
    SendToolError(IdJson, Format('read failed at 0x%x (%d bytes)', [Addr, Count]));
    Exit;
  end;
  var Hex := '';
  for var B in Buf do
    Hex := Hex + IntToHex(B, 2);
  var Obj := TJSONObject.Create;
  Obj.AddPair('address', Format('0x%x', [Addr]));
  Obj.AddPair('count', TJSONNumber.Create(Count));
  Obj.AddPair('hex', Hex);
  // Little-endian integer views for the common widths, for reading VMT slots
  // and record fields without hand-assembling the bytes.
  if Count >= 8 then Obj.AddPair('u64le', TJSONNumber.Create(PUInt64(@Buf[0])^));
  if Count >= 4 then Obj.AddPair('u32le', TJSONNumber.Create(Int64(PCardinal(@Buf[0])^)));
  if Count >= 2 then Obj.AddPair('u16le', TJSONNumber.Create(PWord(@Buf[0])^));
  SendToolJson(IdJson, Obj);
end;

procedure TMcpServer.HandleWriteMemory(const IdJson, AddrStr, HexBytes: string);
var
  Addr: UInt64;
begin
  if not ParseAddress(AddrStr, Addr) then begin
    SendToolError(IdJson, 'invalid address: ' + AddrStr);
    Exit;
  end;
  var Clean := StringReplace(HexBytes, ' ', '', [rfReplaceAll]);
  Clean := StringReplace(Clean, #9, '', [rfReplaceAll]);
  if (Clean = '') or (Length(Clean) mod 2 <> 0) then begin
    SendToolError(IdJson, 'hexBytes must be an even number of hex digits');
    Exit;
  end;
  var Buf: TBytes;
  SetLength(Buf, Length(Clean) div 2);
  for var I := 0 to High(Buf) do begin
    var ByteVal: Integer;
    if not TryStrToInt('$' + Clean.Substring(I * 2, 2), ByteVal) then begin
      SendToolError(IdJson, 'invalid hex at byte ' + IntToStr(I));
      Exit;
    end;
    Buf[I] := Byte(ByteVal);
  end;
  if not FSession.Debugger.WriteMemoryAt(Addr, @Buf[0], Length(Buf)) then begin
    SendToolError(IdJson, Format('write failed at 0x%x', [Addr]));
    Exit;
  end;
  var Obj := TJSONObject.Create;
  Obj.AddPair('address', Format('0x%x', [Addr]));
  Obj.AddPair('written', TJSONNumber.Create(Length(Buf)));
  SendToolJson(IdJson, Obj);
end;

// docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 4. "statement" (default, or omitted)
// keeps the pre-existing fire-and-forget behaviour (the source-level step
// never refuses). "instruction" calls TDebugSession.StepInstruction FIRST and
// only arms the wait when it is ACCEPTED -- exactly the ordering increment 2's
// DAP HandleInstructionStep uses and for the same reason: a refusal must reach
// the caller as a real error, not a silent no-op or a wait that never resolves.
procedure TMcpServer.HandleStepTool(const IdJson: string; Kind: TInstructionStepKind;
  const Granularity: string; ThreadId: Cardinal);
begin
  if (Granularity <> '') and not SameText(Granularity, 'statement') and
     not SameText(Granularity, 'instruction') then begin
    SendToolError(IdJson, Format(
      'unknown granularity "%s" -- use "statement" (default) or "instruction".',
      [Granularity]));
    Exit;
  end;
  if SameText(Granularity, 'instruction') then begin
    var RefusalReason: string;
    if not FSession.StepInstruction(Kind, ThreadId, RefusalReason) then begin
      SendToolError(IdJson, RefusalReason);
      Exit;
    end;
  end
  else begin
    // A source-level step is still fire-and-forget at an ordinary stop. At a
    // first-chance EXCEPTION stop it means "run to the handler that receives
    // this exception" and CAN refuse, so the refusal has to reach the caller as
    // a real error rather than as a wait that never resolves.
    var RefusalReason: string;
    var Ok := True;
    case Kind of
      iskOver: Ok := FSession.StepOver(ThreadId, RefusalReason);
      iskInto: Ok := FSession.StepInto(ThreadId, RefusalReason);
      iskOut:  Ok := FSession.StepOut (ThreadId, RefusalReason);
    end;
    if not Ok then begin
      SendToolError(IdJson, RefusalReason);
      Exit;
    end;
  end;
  ArmWait(IdJson, 30000);
end;

procedure TMcpServer.HandleSetBreakpointAtAddress(const IdJson, AddrStr,
  Condition, HitCondition, LogMessage: string);
var
  Addr: UInt64;
begin
  if not ParseAddress(AddrStr, Addr) then begin
    SendToolError(IdJson, 'invalid address: ' + AddrStr);
    Exit;
  end;
  var Bp := FSession.SetAddressBreakpoint(Addr, Condition, HitCondition, LogMessage);
  SendToolJson(IdJson, McpJson.BreakpointListToJson([Bp]));
end;

// MCPDebugger\Win64\<Config>\DelphiDebuggerMcp.exe is three levels below the
// repo root, same depth as DevTools\Win64\<Config>\*.exe (see Disasm.dpr's
// DefaultZydisDllPath, which this mirrors) -- lets a dev/test build find the
// committed DLL without any install step. An installed copy (no repo beside
// it, no DLL sitting next to the exe) falls through to ZydisTryLoad('')'s
// own bare-name search, which is the ordinary "Zydis unavailable" path this
// feature is built to report honestly rather than hide.
function DefaultZydisDllPath: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFileDir(ParamStr(0)),
    '..\..\..\ThirdParty\Zydis\bin\x64\Zydis.dll'));
end;

function ResolveZydisDllPath: string;
var
  NextToExe: string;
begin
  NextToExe := TPath.Combine(ExtractFileDir(ParamStr(0)), 'Zydis.dll');
  if FileExists(NextToExe) then
    Exit(NextToExe);
  if FileExists(DefaultZydisDllPath) then
    Exit(DefaultZydisDllPath);
  Result := '';
end;

// Which loaded module (main exe or a runtime package/DLL) owns VA, or ''
// when none of them do (kernel32, ntdll, or anything the debugger has not
// logged a LOAD_DLL event for yet). Same GetModules the get_loaded_modules
// tool already exposes, reused here so a `before` refusal can name the
// module rather than just the bare address.
function ModuleNameForVA(Session: TDebugSession; VA: UInt64): string;
begin
  Result := '';
  for var M in Session.GetModules do
    if (M.Base <> 0) and (VA >= M.Base) and (VA < M.Base + M.Size) then
      Exit(M.Name);
end;

// docs/DISASSEMBLY_PLAN.md increment 4: MCP `disassemble`. Requires a stop, same
// as get_call_stack/get_raw_stack_scan -- both the byte read and (when
// resolving via frameIndex/threadId) the call stack need a consistent,
// non-running snapshot.
//
// Zydis is optional (docs/DISASSEMBLY_PLAN.md, "Constraints"): a missing or
// version-mismatched DLL is reported as available:false with a reason, never
// a partial or fabricated result -- the ORDINARY case on a machine without
// the VC++ runtime, not an error. `before` is a SEPARATE refusal channel
// from the call itself (decision recorded in docs/DISASSEMBLY_PLAN.md): backward
// disassembly is answered only from a PROVEN earlier instruction boundary
// (debug info, or a module's PE export table when it has none) that decodes
// forward to land EXACTLY on the requested address; anything else refuses
// with a reason while the forward `instructions` are still returned
// untouched -- a refused `before` is not a failed call.
procedure TMcpServer.HandleDisassemble(const IdJson, AddrStr: string;
  FrameIndex: Integer; ThreadId: Cardinal; Count, Before: Integer);
var
  Addr: UInt64;
begin
  if FSession.State <> dsStopped then begin
    SendToolError(IdJson, 'Cannot disassemble while the debuggee is running. Pause or wait for a stop first.');
    Exit;
  end;
  if (Count < 1) or (Count > 500) then begin
    SendToolError(IdJson, 'count must be 1..500');
    Exit;
  end;
  if (Before < 0) or (Before > 100) then begin
    SendToolError(IdJson, 'before must be 0..100');
    Exit;
  end;

  if Trim(AddrStr) <> '' then begin
    if not ParseAddress(AddrStr, Addr) then begin
      SendToolError(IdJson, 'invalid address: ' + AddrStr);
      Exit;
    end;
  end
  else begin
    var Frames: TArray<TSessionFrame>;
    if ThreadId <> 0 then
      Frames := FSession.GetCallStack(ThreadId)
    else
      Frames := FSession.GetCallStack;
    if (FrameIndex < 0) or (FrameIndex > High(Frames)) then begin
      SendToolError(IdJson, Format(
        'frameIndex %d out of range (0..%d). Use get_call_stack first, or pass address directly.',
        [FrameIndex, High(Frames)]));
      Exit;
    end;
    Addr := Frames[FrameIndex].IP;
  end;

  var Mode: TDisasmMachineMode;
  if FSession.Debugger.TargetLayout.PointerSize = 8 then
    Mode := dmmLong64
  else
    Mode := dmmLegacy32;

  var Debugger := FSession.Debugger;
  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      Result := Integer(Debugger.ReadCodeMemoryAt(VA, Buf, NativeUInt(Size)));
    end;

  var Disasm: IDisassembler := TZydisDisassembler.Create(Mode, Reader,
    FSession.DebugInfo, Debugger.ImageBase, ResolveZydisDllPath);

  var Obj := TJSONObject.Create;
  Obj.AddPair('address', '0x' + IntToHex(Addr, 1));
  var ModName := ModuleNameForVA(FSession, Addr);
  if ModName <> '' then
    Obj.AddPair('module', ModName);
  if Mode = dmmLong64 then
    Obj.AddPair('machineMode', 'x64')
  else
    Obj.AddPair('machineMode', 'x86');
  Obj.AddPair('available', TJSONBool.Create(Disasm.Available));

  if not Disasm.Available then begin
    // Fail closed BEFORE decoding anything: no `instructions`, no `before` --
    // the whole point is that an unavailable backend never hands back a
    // partial result an agent could mistake for a real one.
    Obj.AddPair('reason', Disasm.StatusText);
    SendToolJson(IdJson, Obj);
    Exit;
  end;

  var Forward := Disasm.Disassemble(Addr, Count);
  Obj.AddPair('instructions', McpJson.DisasmInstructionListToJson(Forward));

  if Before > 0 then begin
    var BeforeObj := TJSONObject.Create;
    BeforeObj.AddPair('requested', TJSONNumber.Create(Before));

    var BoundaryVA: UInt64;
    var HaveBoundary := Debugger.NearestInstructionBoundaryBefore(Addr, BoundaryVA);
    if not HaveBoundary then
      HaveBoundary := Debugger.NearestExportedEntryBefore(Addr, BoundaryVA);

    var Backward: TArray<TDisasmInstruction> := nil;
    if HaveBoundary then
      Backward := DisassembleBackward(Disasm, BoundaryVA, Addr, Before);

    if Length(Backward) > 0 then begin
      BeforeObj.AddPair('returned', TJSONNumber.Create(Length(Backward)));
      BeforeObj.AddPair('refused', TJSONBool.Create(False));
      BeforeObj.AddPair('instructions', McpJson.DisasmInstructionListToJson(Backward));
    end
    else begin
      BeforeObj.AddPair('returned', TJSONNumber.Create(0));
      BeforeObj.AddPair('refused', TJSONBool.Create(True));
      if not HaveBoundary then begin
        var ReasonModule := ModName;
        if ReasonModule = '' then
          ReasonModule := 'an unknown module';
        BeforeObj.AddPair('reason', Format(
          'no proven instruction boundary precedes this address in %s', [ReasonModule]));
      end
      else
        BeforeObj.AddPair('reason',
          'decoding forward from the nearest known boundary does not land exactly on the ' +
          'requested address, so preceding instruction boundaries cannot be determined without guessing');
    end;
    Obj.AddPair('before', BeforeObj);
  end;

  SendToolJson(IdJson, Obj);
end;

procedure TMcpServer.ProcessRpc(Msg: TJSONObject);
begin
  var Method := Msg.GetValue<string>('method', '');
  var IdJson := McpJson.IdJsonOf(Msg);
  var HasId  := Msg.FindValue('id') <> nil;

  if Method = 'initialize' then
    DispatchInitialize(IdJson)
  else if Method = 'notifications/initialized' then
    // notification, no response
  else if Method = 'tools/list' then
    DispatchToolsList(IdJson)
  else if Method = 'tools/call' then begin
    var P := Msg.FindValue('params');
    if P is TJSONObject then
      DispatchToolsCall(IdJson, TJSONObject(P))
    else
      FIO.SendError(IdJson, -32602, 'Missing params');
  end
  else if Method = 'ping' then
    FIO.SendResult(IdJson, TJSONObject.Create)
  else if Method = 'shutdown' then begin
    FQuit := True;
    if HasId then
      FIO.SendResult(IdJson, TJSONObject.Create);
  end
  else if HasId then
    FIO.SendError(IdJson, -32601, 'Method not found: ' + Method);
  // else: unknown notification -> ignore
end;

procedure TMcpServer.Run;
var
  MsgQueue: TThreadedQueue<TJSONObject>;
begin
  GLogPath := TPath.Combine(TPath.GetTempPath, 'mcp_adapter.log');
  McpLog('=== MCP server starting ===');

  MsgQueue := TThreadedQueue<TJSONObject>.Create(256, INFINITE, 0);
  var Reader := TThread.CreateAnonymousThread(
    procedure
    begin
      while True do begin
        var M := FIO.ReadMessage;
        if M = nil then begin
          MsgQueue.DoShutDown;
          Break;
        end;
        MsgQueue.PushItem(M);
      end;
    end);
  Reader.FreeOnTerminate := True;
  Reader.Start;

  try
    while not FQuit do begin
      var DidWork := False;

      var Msg: TJSONObject;
      var PopRes := MsgQueue.PopItem(Msg);
      if PopRes = wrSignaled then begin
        try
          ProcessRpc(Msg);
        except
          on E: Exception do
            McpLog('EXCEPTION in ProcessRpc: ' + E.Message);
        end;
        Msg.Free;
        DidWork := True;
      end
      else if PopRes = wrAbandoned then begin
        FQuit := True;
        Break;
      end;

      if FSession.State in [dsLaunching, dsAttaching, dsRunning, dsStopped] then begin
        FSession.Pump;
        DidWork := True;
      end;

      FulfilPendingWait;
      CheckWaitTimeout;

      if not DidWork then
        Sleep(5);
    end;
  finally
    MsgQueue.Free;
    McpLog('=== MCP server stopped ===');
  end;
end;

procedure RunMcpServer;
begin
  var Server := TMcpServer.Create;
  try
    Server.Run;
  finally
    Server.Free;
  end;
end;

end.
