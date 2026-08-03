unit DapProtocol;

interface

uses
  System.SysUtils, System.JSON, Winapi.Windows;

procedure DapLog(const S: string);

// Enable / disable diagnostic logging. Default: off. The launch handler sets
// this from the launch.json `diagnosticLog: true` flag; the env var
// `DAP_LOG=1` also forces it on (developer convenience). Calls to DapLog
// before this is invoked are silently dropped -- startup-phase messages won't
// appear in the file unless logging is enabled by env var.
procedure SetDapLogEnabled(Enable: Boolean);

type
  TDapIO = class
  private
    FIn: THandle;
    FOut: THandle;
    FOutLock: TRTLCriticalSection;
    FSeq: Integer;
    function ReadRaw(Count: Integer): TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function ReadMessage: TJSONObject; // nil = EOF; caller frees
    procedure SendResponse(RequestSeq: Integer; const Cmd: string;
      OK: Boolean; Body: TJSONObject = nil);
    procedure SendEvent(const Name: string; Body: TJSONObject = nil);
    procedure SendErrorResponse(RequestSeq: Integer; const Cmd, Msg: string);
  end;

implementation

var
  GLogLock:    TRTLCriticalSection;
  GLogPath:    string;
  GLogEnabled: Boolean = False;
  GLogHandle:  THandle = INVALID_HANDLE_VALUE;
  // Safety cap: a runaway (e.g. an infinite resolution loop calling DapLog)
  // once grew dap_adapter.log to 7.3 GB and filled the disk. Stop writing past
  // this many bytes per adapter process; a single marker line records the cap.
  GLogBytes:   Int64   = 0;
  GLogCapped:  Boolean = False;

const
  DAP_LOG_CAP_BYTES = Int64(256) * 1024 * 1024;  // 256 MB / process

procedure SetDapLogEnabled(Enable: Boolean);
begin
  GLogEnabled := Enable;
end;

// Open the log file once and keep the handle. Per-line AssignFile/Append/
// CloseFile cost milliseconds each (Defender scans every open of a %TEMP%
// file), so on a SampleApp-scale expand that logs hundreds of lines it alone
// added seconds. FILE_APPEND_DATA lets the OS append atomically without a
// seek; FILE_SHARE_READ keeps the file tailable while open. Must hold
// GLogLock.
procedure EnsureLogOpen;
begin
  if GLogHandle <> INVALID_HANDLE_VALUE then Exit;
  GLogHandle := CreateFile(PChar(GLogPath), FILE_APPEND_DATA,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, 0);
end;

procedure DapLog(const S: string);
var
  Bytes:   TBytes;
  Written: DWORD;
begin
  if not GLogEnabled then Exit;
  EnterCriticalSection(GLogLock);
  try
    EnsureLogOpen;
    if GLogHandle = INVALID_HANDLE_VALUE then Exit;
    if GLogBytes >= DAP_LOG_CAP_BYTES then begin
      if not GLogCapped then begin
        GLogCapped := True;
        Bytes := TEncoding.UTF8.GetBytes(
          '=== dap_adapter.log capped at 256 MB; further lines suppressed '
          + '(possible runaway loop) ==='#13#10);
        WriteFile(GLogHandle, Bytes[0], Length(Bytes), Written, nil);
      end;
      Exit;
    end;
    Bytes := TEncoding.UTF8.GetBytes(
      FormatDateTime('hh:nn:ss.zzz', Now) + ' ' + S + #13#10);
    WriteFile(GLogHandle, Bytes[0], Length(Bytes), Written, nil);
    Inc(GLogBytes, Length(Bytes));
  finally
    LeaveCriticalSection(GLogLock);
  end;
end;

constructor TDapIO.Create;
begin
  inherited;
  FIn  := GetStdHandle(STD_INPUT_HANDLE);
  FOut := GetStdHandle(STD_OUTPUT_HANDLE);
  InitializeCriticalSection(FOutLock);
  FSeq := 0;
  DapLog('=== VisualStudioCodeDelphiDebugger started ===');
end;

destructor TDapIO.Destroy;
begin
  DapLog('=== TDapIO destroyed ===');
  DeleteCriticalSection(FOutLock);
  inherited;
end;

function TDapIO.ReadRaw(Count: Integer): TBytes;
var
  Written: DWORD;
  Offset: Integer;
begin
  SetLength(Result, Count);
  Offset := 0;
  while Offset < Count do begin
    if not ReadFile(FIn, Result[Offset], Count - Offset, Written, nil) or (Written = 0) then
      Exit(nil);
    Inc(Offset, Written);
  end;
end;

function TDapIO.ReadMessage: TJSONObject;
var
  B: Byte;
  Written: DWORD;
  Headers: string;
  ContentLength: Integer;
  Body: TBytes;
begin
  Result := nil;
  Headers := '';
  ContentLength := -1;
  repeat
    if not ReadFile(FIn, B, 1, Written, nil) or (Written = 0) then
      Exit;
    Headers := Headers + Char(B);
    if not Headers.EndsWith(#13#10#13#10) then
      Continue;
    for var Line in Headers.Split([#13#10]) do
      if Line.StartsWith('Content-Length: ') then
        ContentLength := StrToIntDef(Line.Substring(16).Trim, -1);
    if ContentLength > 0 then
      Break;
    // Malformed header block -- keep reading
  until False;
  if ContentLength <= 0 then begin
    DapLog('ReadMessage: bad ContentLength=' + IntToStr(ContentLength));
    Exit;
  end;
  Body := ReadRaw(ContentLength);
  if Body = nil then begin
    DapLog('ReadMessage: EOF reading body');
    Exit;
  end;
  var JsonStr := TEncoding.UTF8.GetString(Body);
  DapLog('RECV: ' + JsonStr);
  Result := TJSONObject.ParseJSONValue(JsonStr) as TJSONObject;
  if Result = nil then
    DapLog('ReadMessage: JSON parse failed');
end;

procedure TDapIO.SendResponse(RequestSeq: Integer; const Cmd: string;
  OK: Boolean; Body: TJSONObject = nil);
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('seq',         TJSONNumber.Create(AtomicIncrement(FSeq)));
    Msg.AddPair('type',        'response');
    Msg.AddPair('request_seq', TJSONNumber.Create(RequestSeq));
    Msg.AddPair('success',     TJSONBool.Create(OK));
    Msg.AddPair('command',     Cmd);
    if Body <> nil then
      Msg.AddPair('body', Body.Clone as TJSONValue);
    var Json   := TEncoding.UTF8.GetBytes(Msg.ToJSON);
    var Header := TEncoding.ASCII.GetBytes(
      Format('Content-Length: %d'#13#10#13#10, [Length(Json)]));
    DapLog('SEND resp ' + Cmd + ': ' + Msg.ToJSON);
    EnterCriticalSection(FOutLock);
    try
      var D: DWORD;
      WriteFile(FOut, Header[0], Length(Header), D, nil);
      WriteFile(FOut, Json[0],   Length(Json),   D, nil);
    finally
      LeaveCriticalSection(FOutLock);
    end;
  finally
    Msg.Free;
  end;
end;

procedure TDapIO.SendEvent(const Name: string; Body: TJSONObject = nil);
var
  Msg: TJSONObject;
begin
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('seq',   TJSONNumber.Create(AtomicIncrement(FSeq)));
    Msg.AddPair('type',  'event');
    Msg.AddPair('event', Name);
    if Body <> nil then
      Msg.AddPair('body', Body.Clone as TJSONValue);
    var Json   := TEncoding.UTF8.GetBytes(Msg.ToJSON);
    var Header := TEncoding.ASCII.GetBytes(
      Format('Content-Length: %d'#13#10#13#10, [Length(Json)]));
    DapLog('SEND event ' + Name + ': ' + Msg.ToJSON);
    EnterCriticalSection(FOutLock);
    try
      var D: DWORD;
      WriteFile(FOut, Header[0], Length(Header), D, nil);
      WriteFile(FOut, Json[0],   Length(Json),   D, nil);
    finally
      LeaveCriticalSection(FOutLock);
    end;
  finally
    Msg.Free;
  end;
end;

procedure TDapIO.SendErrorResponse(RequestSeq: Integer; const Cmd, Msg: string);
var
  Body: TJSONObject;
  ErrObj: TJSONObject;
begin
  Body   := TJSONObject.Create;
  ErrObj := TJSONObject.Create;
  try
    ErrObj.AddPair('id',     TJSONNumber.Create(1));
    ErrObj.AddPair('format', Msg);
    Body.AddPair('error', ErrObj.Clone as TJSONValue);
    SendResponse(RequestSeq, Cmd, False, Body);
  finally
    Body.Free;
    ErrObj.Free;
  end;
end;

initialization
  InitializeCriticalSection(GLogLock);
  // Where the log goes, and whether it is on, belong to the UNIT, not to
  // TDapIO. They used to be set in that constructor, which meant every
  // consumer of the engine that is not the DAP server -- the DevTools probes,
  // the test runner, the MCP server -- had GLogPath = '', so DapLog silently
  // wrote nowhere even when explicitly enabled. Diagnostics that vanish
  // depending on which frontend is running are worse than none.
  GLogPath := GetEnvironmentVariable('TEMP') + '\dap_adapter.log';
  // Env-var override: DAP_LOG=1 forces logging on regardless of launch.json.
  if SameText(GetEnvironmentVariable('DAP_LOG'), '1') then
    GLogEnabled := True;

finalization
  if GLogHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(GLogHandle);
    GLogHandle := INVALID_HANDLE_VALUE;
  end;
  DeleteCriticalSection(GLogLock);

end.
