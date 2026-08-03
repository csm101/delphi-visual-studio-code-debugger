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
  System.IOUtils, McpToolSchemas, McpJson, LaunchConfig;

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
  end;
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
  procedure BeginSelectedFrame;
  begin
    var FrameIndex := ArgInt('frameIndex', 0);
    var ThreadId := Cardinal(ArgInt('threadId', 0));
    if (FrameIndex <> 0) or (ThreadId <> 0) then
      FSession.SelectFrame(FrameIndex, ThreadId);
  end;

  procedure EndSelectedFrame;
  begin
    if (ArgInt('frameIndex', 0) <> 0) or (ArgInt('threadId', 0) <> 0) then
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

    // ---- execution control (async-wait) ----
    if Name = 'continue_and_wait' then begin
      FSession.ContinueExecution;
      ArmWait(IdJson, ArgInt('timeoutMs', 30000));
      Exit;
    end;
    if Name = 'step_over' then begin
      FSession.StepOver(Cardinal(ArgInt('threadId', 0)));  ArmWait(IdJson, 30000); Exit;
    end;
    if Name = 'step_into' then begin
      FSession.StepInto(Cardinal(ArgInt('threadId', 0)));  ArmWait(IdJson, 30000); Exit;
    end;
    if Name = 'step_out' then begin
      FSession.StepOut(Cardinal(ArgInt('threadId', 0)));   ArmWait(IdJson, 30000); Exit;
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
      // inside a system DLL, where nothing resolves (F18).
      SendToolJson(IdJson, McpJson.EvalResultToJson(
        FSession.EvaluateForFrame(ArgStr('expression'),
          ArgInt('frameIndex', 0), Cardinal(ArgInt('threadId', 0)))));
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
    if Name = 'read_memory' then begin
      HandleReadMemory(IdJson, ArgStr('address'), ArgInt('count'));
      Exit;
    end;
    if Name = 'write_memory' then begin
      HandleWriteMemory(IdJson, ArgStr('address'), ArgStr('hexBytes'));
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
