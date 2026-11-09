program McpStdioProbe;

{$APPTYPE CONSOLE}

// Drives DelphiDebuggerMcp.exe over stdio the way an MCP client does and
// reports, for every line the server writes back, when it arrived, how big it
// is, and whether it parses. Built to settle "the tool call never returned"
// reports: it shows whether the server answered at all, how late, and whether
// something else (a debuggee writing into the server's stdout) got in the way.
//
//   McpStdioProbe <serverExe> <program> [args] [filtersCsv] [timeoutMs]
//
//   args        command-line arguments for the program; "-" for none. (An empty
//               "" is not a safe way to skip it: PowerShell may drop it, which
//               shifts every later argument one place to the left.)
//   filtersCsv  exception filters for launch_debuggee ("delphi,av,unhandled"
//               by default; "-" passes an empty array).
//   timeoutMs   timeoutMs handed to continue_and_wait (default 60000). The
//               probe itself waits that long plus 60 s before giving up.
//
// Sequence: initialize, launch_debuggee, continue_and_wait, then
// terminate_debuggee. Exit code 0 when every call was answered, 2 when one
// was not.

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.Diagnostics;

type
  TStdioClient = class
  private
    FProc:    TProcessInformation;
    FInWrite: THandle;
    FOutRead: THandle;
    FNextId:  Integer;
    FWatch:   TStopwatch;
    procedure WriteLine(const S: string);
    function  ReadLine(TimeoutMs: Cardinal; out Line: string): Boolean;
    function  Stamp: string;
  public
    constructor Start(const ExePath: string);
    destructor Destroy; override;
    // Sends a request and waits for the response carrying its id, reporting
    // every other line that arrives meanwhile. nil when nothing matching came
    // back within TimeoutMs.
    function Call(const Method: string; Params: TJSONObject; TimeoutMs: Cardinal): TJSONObject;
    function CallTool(const Name: string; Args: TJSONObject; TimeoutMs: Cardinal): TJSONValue;
  end;

constructor TStdioClient.Start(const ExePath: string);
var
  Sec: TSecurityAttributes;
  ChildIn, ChildOut: THandle;
  SI: TStartupInfo;
begin
  inherited Create;
  FNextId := 1;
  FWatch := TStopwatch.StartNew;
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

  var CommandLine := '"' + ExePath + '"';
  UniqueString(CommandLine);
  if not CreateProcess(nil, PChar(CommandLine), nil, nil, True,
       CREATE_NO_WINDOW, nil, PChar(ExtractFileDir(ExePath)), SI, FProc) then
    RaiseLastOSError;
  CloseHandle(ChildIn);
  CloseHandle(ChildOut);
end;

destructor TStdioClient.Destroy;
begin
  if FInWrite <> 0 then
    CloseHandle(FInWrite);
  if FOutRead <> 0 then
    CloseHandle(FOutRead);
  if FProc.hProcess <> 0 then begin
    TerminateProcess(FProc.hProcess, 0);
    WaitForSingleObject(FProc.hProcess, 5000);
    CloseHandle(FProc.hThread);
    CloseHandle(FProc.hProcess);
  end;
  inherited;
end;

function TStdioClient.Stamp: string;
begin
  Result := Format('[%7d ms]', [FWatch.ElapsedMilliseconds]);
end;

procedure TStdioClient.WriteLine(const S: string);
begin
  var Bytes := TEncoding.UTF8.GetBytes(S + #10);
  var Written: DWORD;
  WriteFile(FInWrite, Bytes[0], Length(Bytes), Written, nil);
end;

function TStdioClient.ReadLine(TimeoutMs: Cardinal; out Line: string): Boolean;
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  var Bytes: TBytes := [];
  while True do begin
    var Avail: DWORD := 0;
    if not PeekNamedPipe(FOutRead, nil, 0, nil, @Avail, nil) then
      raise Exception.Create('server stdout pipe closed');
    if Avail = 0 then begin
      if GetTickCount64 > Deadline then
        Exit(False);
      Sleep(2);
      Continue;
    end;
    var B: Byte;
    var Rd: DWORD;
    if not ReadFile(FOutRead, B, 1, Rd, nil) or (Rd = 0) then
      raise Exception.Create('server stdout read failed');
    if B = 10 then
      Break;
    if B = 13 then
      Continue;
    Bytes := Bytes + [B];
  end;
  Line := TEncoding.UTF8.GetString(Bytes);
  Result := True;
end;

function TStdioClient.Call(const Method: string; Params: TJSONObject; TimeoutMs: Cardinal): TJSONObject;
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
  Writeln(Format('%s -> id=%d %s', [Stamp, Id, Method]));

  var Deadline := GetTickCount64 + TimeoutMs;
  while True do begin
    var Remaining := Int64(Deadline) - Int64(GetTickCount64);
    if Remaining <= 0 then begin
      Writeln(Format('%s NO RESPONSE for id=%d after %d ms', [Stamp, Id, TimeoutMs]));
      Exit(nil);
    end;
    var Line: string;
    if not ReadLine(Cardinal(Remaining), Line) then
      Continue;
    var V := TJSONObject.ParseJSONValue(Line);
    if not (V is TJSONObject) then begin
      Writeln(Format('%s <- UNPARSEABLE line, %d chars: %s', [Stamp, Length(Line), Copy(Line, 1, 200)]));
      V.Free;
      Continue;
    end;
    var Obj := TJSONObject(V);
    var IdV := Obj.GetValue('id');
    var LineId := -1;
    if IdV is TJSONNumber then
      LineId := TJSONNumber(IdV).AsInt;
    Writeln(Format('%s <- id=%d %d chars', [Stamp, LineId, Length(Line)]));
    if LineId = Id then
      Exit(Obj);
    Obj.Free;
  end;
end;

function TStdioClient.CallTool(const Name: string; Args: TJSONObject; TimeoutMs: Cardinal): TJSONValue;
begin
  var Params := TJSONObject.Create;
  Params.AddPair('name', Name);
  if Args <> nil then
    Params.AddPair('arguments', Args)
  else
    Params.AddPair('arguments', TJSONObject.Create);
  var Resp := Call('tools/call', Params, TimeoutMs);
  if Resp = nil then
    Exit(nil);
  try
    var ResultObj := Resp.GetValue('result') as TJSONObject;
    if ResultObj = nil then begin
      Writeln('  error reply: ' + Copy(Resp.ToJSON, 1, 400));
      Exit(TJSONObject.Create);
    end;
    var Text := ResultObj.GetValue<TJSONArray>('content').Items[0].GetValue<string>('text');
    Writeln(Format('  text: %d chars; starts: %s', [Length(Text), Copy(Text, 1, 300)]));
    Result := TJSONObject.ParseJSONValue(Text);
    if Result = nil then
      Result := TJSONString.Create(Text);
  finally
    Resp.Free;
  end;
end;

function FiltersArray(const Csv: string): TJSONArray;
begin
  Result := TJSONArray.Create;
  if Csv = '-' then
    Exit;
  for var F in Csv.Split([',']) do
    if F.Trim <> '' then
      Result.Add(F.Trim);
end;

procedure Describe(V: TJSONValue);
begin
  if not (V is TJSONObject) then
    Exit;
  var O := TJSONObject(V);
  Writeln(Format('  state=%s stopReason=%s exception=%s', [
    O.GetValue<string>('state', '?'), O.GetValue<string>('stopReason', '-'),
    O.GetValue<string>('exception.class', '-')]));
end;

begin
  if ParamCount < 2 then begin
    Writeln('McpStdioProbe <serverExe> <program> [args] [filtersCsv] [timeoutMs]');
    Halt(1);
  end;
  var ServerExe := ParamStr(1);
  var Target    := ParamStr(2);
  var Args      := ParamStr(3);
  if Args = '-' then
    Args := '';
  var Filters   := ParamStr(4);
  if Filters = '' then
    Filters := 'delphi,av,unhandled';
  var TimeoutMs := StrToIntDef(ParamStr(5), 60000);

  var Missing := 0;
  var C := TStdioClient.Start(ServerExe);
  try
    var Init := C.Call('initialize', nil, 10000);
    if Init = nil then
      Inc(Missing)
    else
      Init.Free;

    var LaunchArgs := TJSONObject.Create;
    LaunchArgs.AddPair('program', Target);
    if Args <> '' then
      LaunchArgs.AddPair('args', Args);
    LaunchArgs.AddPair('exceptionFilters', FiltersArray(Filters));
    var L := C.CallTool('launch_debuggee', LaunchArgs, 60000);
    if L = nil then
      Inc(Missing)
    else begin
      Describe(L);
      L.Free;
    end;

    var WaitArgs := TJSONObject.Create;
    WaitArgs.AddPair('timeoutMs', TJSONNumber.Create(TimeoutMs));
    var W := C.CallTool('continue_and_wait', WaitArgs, Cardinal(TimeoutMs) + 60000);
    if W = nil then begin
      Inc(Missing);
      // Same probe the bug report used to see where the session really was.
      var S := C.CallTool('get_debug_session_status', nil, 30000);
      if S <> nil then begin
        Describe(S);
        S.Free;
      end;
    end
    else begin
      Describe(W);
      W.Free;
    end;

    var T := C.CallTool('terminate_debuggee', nil, 30000);
    if T = nil then
      Inc(Missing)
    else
      T.Free;
  finally
    C.Free;
  end;
  if Missing > 0 then begin
    Writeln(Format('RESULT: %d call(s) never answered', [Missing]));
    Halt(2);
  end;
  Writeln('RESULT: every call answered');
end.
