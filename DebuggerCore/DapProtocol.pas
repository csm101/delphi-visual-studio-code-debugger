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

// Redirect the log. Closes the current file, so the next line reopens at the
// new path and re-reads its size. Exists for the tests -- a size cap and a
// rotation are only provable against a file the test owns -- and for any
// consumer that wants its own log rather than the shared `%TEMP%` one.
procedure SetDapLogPath(const Path: string);

// The log file currently in use, and the one previous generation kept beside
// it (`dap_adapter.log` / `dap_adapter.1.log` in `%TEMP%` by default).
function DapLogPath: string;
function DapLogPreviousPath: string;

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
  // Bytes in the log FILE, not bytes written by this process. The distinction
  // is the whole point: the cap used to count only what the running adapter
  // had written and the file is opened for APPEND, so every new debug session
  // started the count at zero on top of whatever was already there. The file
  // was measured at 1.5 GB on a normal working machine -- the cap had never
  // once been reached, because no single session writes 256 MB.
  GLogBytes:   Int64   = 0;
  // The cap in bytes, resolved from the environment on first use. -1 = not yet
  // read. See LogCapBytes.
  GLogCapBytes: Int64  = -1;

const
  // Per FILE, and rotated rather than truncated: one previous log is kept, so
  // the worst case on disk is twice this and the session before last is still
  // readable. 64 MB is minutes of verbose tracing at adapter speeds.
  DAP_LOG_DEFAULT_MB = 64;

procedure SetDapLogEnabled(Enable: Boolean);
begin
  GLogEnabled := Enable;
end;

function DapLogPath: string;
begin
  Result := GLogPath;
end;

// One naming rule, used by the rotation and by anyone looking for the previous
// generation, so the two cannot disagree about the file's name.
function PreviousPathFor(const Path: string): string;
begin
  Result := ChangeFileExt(Path, '.1' + ExtractFileExt(Path));
end;

function DapLogPreviousPath: string;
begin
  Result := PreviousPathFor(GLogPath);
end;

procedure SetDapLogPath(const Path: string);
begin
  EnterCriticalSection(GLogLock);
  try
    if GLogHandle <> INVALID_HANDLE_VALUE then begin
      CloseHandle(GLogHandle);
      GLogHandle := INVALID_HANDLE_VALUE;
    end;
    GLogPath     := Path;
    GLogBytes    := 0;    // re-read from the new file when it is opened
    GLogCapBytes := -1;   // and re-read the cap: a test sets it per case
  finally
    LeaveCriticalSection(GLogLock);
  end;
end;

// Open the log file once and keep the handle. Per-line AssignFile/Append/
// CloseFile cost milliseconds each (Defender scans every open of a %TEMP%
// file), so on a SampleApp-scale expand that logs hundreds of lines it alone
// added seconds. FILE_APPEND_DATA lets the OS append atomically without a
// seek; FILE_SHARE_READ keeps the file tailable while open. Must hold
// GLogLock.
// The cap, in bytes. `DAP_LOG_MAX_MB` overrides it; 0 disables the cap for
// someone who really is chasing a rare event and has the disk for it.
//
// Read ONCE. This is consulted on every logged line, and a GetEnvironmentVariable
// per line is a syscall on the hot path of the very thing being diagnosed --
// exactly the kind of cost that made per-line file opens worth removing here in
// the first place. `SetDapLogPath` clears the cache, which is what lets a test
// change the cap between cases.
function LogCapBytes: Int64;
begin
  if GLogCapBytes < 0 then begin
    var Mb := DAP_LOG_DEFAULT_MB;
    var Env := GetEnvironmentVariable('DAP_LOG_MAX_MB');
    if Env <> '' then begin
      var Parsed: Integer;
      if TryStrToInt(Trim(Env), Parsed) and (Parsed >= 0) then
        Mb := Parsed;
    end;
    GLogCapBytes := Int64(Mb) * 1024 * 1024;
  end;
  Result := GLogCapBytes;
end;

function LogFileSize(const Path: string): Int64;
begin
  Result := 0;
  var Data: TWin32FileAttributeData;
  if GetFileAttributesEx(PChar(Path), GetFileExInfoStandard, @Data) then
    Result := (Int64(Data.nFileSizeHigh) shl 32) or Data.nFileSizeLow;
end;

// Renames the current log aside, keeping ONE generation. Rotation rather than
// truncation because the interesting lines are usually the ones just before
// the moment you went looking, and a session that has just rolled over would
// otherwise have nothing behind it. Must hold GLogLock, with the log closed.
procedure RotateLog;
begin
  var Previous := PreviousPathFor(GLogPath);
  DeleteFile(PChar(Previous));
  MoveFile(PChar(GLogPath), PChar(Previous));
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
  // Start from what is ALREADY in the file. Appending to a file whose size we
  // never looked at is how a 64 MB-per-session cap produced a 1.5 GB file.
  GLogBytes := LogFileSize(GLogPath);
  var Cap := LogCapBytes;
  if (Cap > 0) and (GLogBytes >= Cap) then begin
    RotateLog;
    GLogBytes := 0;
  end;
  GLogHandle := CreateFile(PChar(GLogPath), FILE_APPEND_DATA,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, 0);
end;

// Rolls over mid-session once the file reaches the cap. Must hold GLogLock.
procedure RollOverIfFull;
begin
  var Cap := LogCapBytes;
  if (Cap <= 0) or (GLogBytes < Cap) then
    Exit;
  if GLogHandle <> INVALID_HANDLE_VALUE then begin
    var Bytes := TEncoding.UTF8.GetBytes(
      Format('=== continues in a new file; this one reached the %d MB cap ' +
             '(DAP_LOG_MAX_MB) ===' + #13#10, [Cap div (1024 * 1024)]));
    var Written: DWORD;
    WriteFile(GLogHandle, Bytes[0], Length(Bytes), Written, nil);
    CloseHandle(GLogHandle);
    GLogHandle := INVALID_HANDLE_VALUE;
  end;
  RotateLog;
  GLogBytes := 0;
  EnsureLogOpen;
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
    RollOverIfFull;
    if GLogHandle = INVALID_HANDLE_VALUE then Exit;
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
