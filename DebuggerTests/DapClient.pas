unit DapClient;
// Minimal synchronous DAP client for integration testing.
// Spawns the adapter exe, communicates over stdin/stdout pipes,
// and exposes blocking helpers for the common DAP request/event cycle.

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  System.Generics.Collections, System.SyncObjs,
  Winapi.Windows;

type
  EDapError = class(Exception);

  TDapClient = class
  private
    FProc:        THandle;
    FThread:      THandle;
    FStdinW:      THandle;
    FStdoutR:     THandle;
    FSeq:         Integer;
    FQueue:       TList<TJSONObject>;  // owns objects
    FLock:        TCriticalSection;
    // Signalled by the reader thread whenever a message is enqueued, so Dequeue
    // wakes on arrival instead of polling. Manual-reset: Dequeue resets it while
    // holding FLock right after a scan found nothing, so any Set that races in
    // afterwards is still observed and cannot be lost.
    FDataEvent:   TEvent;
    FReader:      TThread;
    FDead:        Boolean;
    // Scratch directory holding the project file (never opened) and the shared
    // rules sidecar LaunchWithRules writes into it. Removed on destroy.
    FRulesScratchDir: string;
    // What each seq was, so a timeout can name the request instead of a number,
    // and where THIS adapter's diagnostic log went, so the message can point at
    // the file that has the answer. Under parallel workers there are up to eight
    // adapters alive at once; a message naming only a seq identifies nothing.
    FSeqCommands:     TDictionary<Integer, string>;
    FAdapterLogPath:  string;

    function  NextSeq: Integer;
    procedure WriteMsg(const Body: string);

    // Background reader
    procedure ReaderProc;
    function  ReadByte(out B: Byte): Boolean;

    // Queue helpers
    procedure Enqueue(Obj: TJSONObject);
    function  Dequeue(Pred: TFunc<TJSONObject, Boolean>;
                TimeoutMs: Integer; out Msg: TJSONObject): Boolean;

    function  SendCmd(const Cmd: string; Args: TJSONObject): Integer;
    // What to say when a response never arrives: which request it was, and
    // which adapter log to open.
    function  TimeoutDetail(Seq: Integer): string;
    // Points the adapter about to be spawned at a log file nobody else writes.
    // No-op unless the runner itself has DAP_LOG=1.
    procedure GiveThisAdapterItsOwnLog;
    function  WaitResp(Seq: Integer; TimeoutMs: Integer = 30000): TJSONObject;
    // Returns the full response message (no `success` check, no raise except
    // on timeout). Caller owns the result.
    function  WaitRespRaw(Seq: Integer; TimeoutMs: Integer = 30000): TJSONObject;
    // Emits `rawStackScan` into a launch/attach request when the test asked for
    // it. Applied by EVERY launch variant on purpose: an option that only some
    // of them honour is a trap for whoever writes the next test.
    procedure MaybeAddRawStackScan(Req: TJSONObject);
    // Emits `delphiProjectFile` into a launch/attach request when the test set
    // it. Same rule as above: every launch AND attach variant carries it, since
    // the project-scoped rule files must be reachable from both.
    procedure MaybeAddDelphiProjectFile(Req: TJSONObject);
    // Writes LaunchWithRules' rules where a project's shared rules file would be
    // and points the session at that project. Uses FRulesScratchDir, created on
    // first use and removed on destroy.
    procedure StageRulesSidecar(const RulesJson: string);

  public
    // Set before Launch to exercise the adapter's raw stack sweep.
    RawStackScan: Boolean;
    // Set before Launch/Attach to give the session a project scope, which is
    // what makes the adapter look for <Project>.ExceptionSettings[.local].json.
    DelphiProjectFile: string;

    constructor Create;
    destructor  Destroy; override;

    // Lifecycle
    // ExtraArgs goes on the adapter's command line verbatim. The adapter has one
    // switch (`--no-stock-memory-view`) that only a command line can carry:
    // `initialize` is answered before any launch configuration exists.
    procedure   Start(const AdapterExe: string; const ExtraArgs: string = '');
    procedure   Stop;

    // DAP requests — all return the response body (or raise EDapError on failure)
    // SupportsMemoryEvent mirrors the client capability of the same name. It is
    // a parameter rather than a constant because the adapter GATES the `memory`
    // event on it, and a gate is only proven by a client that does not declare
    // it (real VS Code does).
    function    Initialize(SupportsMemoryEvent: Boolean = True): TJSONObject;
    function    Launch(const TargetExe, MapFile, RsmFile, SourceRoot: string;
                  StopAtEntry: Boolean = False;
                  const Args: TArray<string> = nil): TJSONObject; overload;
    // Launch with explicit `modules` config — each entry is
    // [moduleName, mapPath, rsmPath]. Used by the BPL test to point the
    // adapter at the BPL's debug-info files.
    function    Launch(const TargetExe, MapFile, RsmFile, SourceRoot: string;
                  StopAtEntry: Boolean;
                  const Args: TArray<string>;
                  const Modules: TArray<TArray<string>>): TJSONObject; overload;
    // Launch with these exception rules in effect, supplied as a JSON array
    // literal (e.g. '[{"class":"EAbort","action":"ignore"}]').
    //
    // They are delivered through a PROJECT's shared rules file, in a scratch
    // directory of this client's own: a launch configuration cannot carry rules
    // any more, so a rules file is the only channel there is. Tests that care
    // about the rule ENGINE rather than about where rules come from should keep
    // using this and ignore the delivery.
    function    LaunchWithRules(const TargetExe, MapFile, RsmFile, SourceRoot: string;
                  const Args: TArray<string>;
                  const RulesJson: string;
                  const Modules: TArray<TArray<string>> = nil): TJSONObject;
    // Puts an `exceptionRules` array in the launch REQUEST itself, the way
    // launch.json used to. It exists to prove that the adapter no longer reads
    // it; nothing else should call it.
    function    LaunchWithRulesInTheRequest(const TargetExe, MapFile, RsmFile,
                  SourceRoot: string; const Args: TArray<string>;
                  const RulesJson: string): TJSONObject;
    // Launch enabling the shared machine-wide rules file at an explicit path
    // (sets useGlobalExceptionRules + globalExceptionRulesPath). No project rules.
    function    LaunchWithGlobalRules(const TargetExe, MapFile, RsmFile, SourceRoot: string;
                  const Args: TArray<string>;
                  const GlobalRulesPath: string;
                  const Modules: TArray<TArray<string>> = nil): TJSONObject;
    // DAP attach. ProgramPath is optional — adapter resolves from PID via
    // QueryFullProcessImageName when omitted, but supplying it lets the
    // tests pin MAP/RSM paths to a known target binary.
    function    Attach(ProcessId: Cardinal;
                  const ProgramPath, MapFile, RsmFile, SourceRoot: string;
                  KillOnDetach: Boolean = True): TJSONObject;
    function    AttachByName(const ProcessName, ProgramPath, MapFile,
                  RsmFile, SourceRoot: string;
                  KillOnDetach: Boolean = True): TJSONObject;
    function    SetBreakpoints(const SourcePath: string;
                  Lines: TArray<Integer>): TJSONObject; overload;
    // Extended form for conditional / hit-count / log-point tests.
    // Conditions, HitConditions, LogMessages must each be the same length as
    // Lines (or empty, which means "no per-line metadata"). Empty string in a
    // slot means "no constraint" for that line.
    function    SetBreakpoints(const SourcePath: string;
                  Lines: TArray<Integer>;
                  const Conditions, HitConditions, LogMessages: TArray<string>
                  ): TJSONObject; overload;
    // Address breakpoints (docs/DISASSEMBLY_PLAN.md increment 5). Addresses are
    // '0x...' strings (matching what disassemble/stackTrace echo); the whole
    // set replaces whatever a previous call planted, per the DAP spec.
    function    SetInstructionBreakpoints(
                  const Addresses: TArray<string>): TJSONObject; overload;
    function    SetInstructionBreakpoints(
                  const Addresses: TArray<string>;
                  const Conditions, HitConditions: TArray<string>
                  ): TJSONObject; overload;
    // Capture an `output` event whose `output` field contains `Substring`.
    // Used by the log-point test to assert that the rendered text fired.
    function    WaitForOutputContaining(const Substring: string;
                  TimeoutMs: Integer = 8000): string;
    // Toggle exception filters by ID. The adapter advertises filter IDs
    // (`delphi` / `av` / `all` / `unhandled`) in its initialize response;
    // the array passed here is the ENABLED set — anything missing is
    // off. `unhandled` is force-enabled by the adapter regardless.
    function    SetExceptionBreakpoints(
                  const FilterIds: TArray<string>): TJSONObject; overload;
    // Extended form sending DAP `filterOptions` so tests can attach a
    // per-filter `condition` string (e.g. comma-separated class names
    // for the Delphi filter).
    function    SetExceptionBreakpoints(
                  const FilterIds, Conditions: TArray<string>): TJSONObject; overload;
    // DAP dataBreakpointInfo: ask whether a variable can be watched and get the
    // opaque `dataId` back. VariablesReference names the CONTAINER the variable
    // belongs to (the Locals scope ref for a plain local, 0 for an expression);
    // FrameId < 0 omits the field, which is what VS Code does when it sends a
    // container reference.
    function    DataBreakpointInfo(const Name: string;
                  VariablesReference: Integer; FrameId: Integer = -1): TJSONObject;
    // DAP setDataBreakpoints: whole-set replace. AccessTypes must be the same
    // length as DataIds (or empty, meaning `write` for every entry).
    // The address form (DAP 1.66, gated on supportsDataBreakpointBytes): `name`
    // is an expression evaluated as an ADDRESS, with an explicit byte count.
    // This is what VS Code's "Add Data Breakpoint at Address" sends, and the
    // only path by which a watch target can be typed rather than picked off a
    // Variables row.
    function    DataBreakpointInfoAtAddress(const Expr: string; Bytes: Integer;
                  FrameId: Integer = -1): TJSONObject;
    function    SetDataBreakpoints(const DataIds: TArray<string>;
                  const AccessTypes: TArray<string> = nil): TJSONObject;
    function    ConfigDone: TJSONObject;
    function    Continue_(ThreadId: Integer = 1): TJSONObject;
    // Granularity, when non-empty, is sent verbatim as the DAP `granularity`
    // argument (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 2) -- '' omits the field
    // entirely, matching what a client that predates the capability sends.
    function    StepIn(ThreadId: Integer = 1; const Granularity: string = ''): TJSONObject;
    function    StepOut(ThreadId: Integer = 1; const Granularity: string = ''): TJSONObject;
    function    StepOver(ThreadId: Integer = 1; const Granularity: string = ''): TJSONObject;
    // Same requests, returning the FULL response (no raise on success:false) --
    // for tests that expect an instruction-granularity step to be REFUSED.
    function    StepInRaw(ThreadId: Integer; const Granularity: string): TJSONObject;
    function    StepOutRaw(ThreadId: Integer; const Granularity: string): TJSONObject;
    function    StepOverRaw(ThreadId: Integer; const Granularity: string): TJSONObject;
    function    SourceContent(SourceReference: Integer): TJSONObject;
    function    StackTrace(ThreadId: Integer = 1): TJSONObject;
    // DAP disassemble (docs/DISASSEMBLY_PLAN.md increment 6). InstructionOffset
    // can be negative -- VS Code's own convention for "instructions before
    // memoryReference". Raises on a success:false response; use
    // DisassembleRaw to inspect a failure (e.g. "not stopped") without
    // raising.
    function    Disassemble(const MemoryReference: string; InstructionOffset,
                  InstructionCount: Integer; ByteOffset: Integer = 0): TJSONObject;
    // Same request, returning the FULL response (success + message/body)
    // without raising -- for tests that expect the request to fail cleanly.
    function    DisassembleRaw(const MemoryReference: string; InstructionOffset,
                  InstructionCount: Integer; ByteOffset: Integer = 0): TJSONObject;
    // DAP readMemory/writeMemory (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3).
    // Raises on success:false; use the Raw variants to inspect a refusal
    // (e.g. "not stopped", a rejected partial write) without raising.
    function    ReadMemory(const MemoryReference: string; Count: Integer;
                  ByteOffset: Integer = 0): TJSONObject;
    function    ReadMemoryRaw(const MemoryReference: string; Count: Integer;
                  ByteOffset: Integer = 0): TJSONObject;
    function    WriteMemory(const MemoryReference, DataBase64: string;
                  ByteOffset: Integer = 0; AllowPartial: Boolean = False): TJSONObject;
    function    WriteMemoryRaw(const MemoryReference, DataBase64: string;
                  ByteOffset: Integer = 0; AllowPartial: Boolean = False): TJSONObject;
    function    Threads: TJSONObject;
    function    ExceptionInfo(ThreadId: Integer): TJSONObject;
    function    Scopes(FrameId: Integer): TJSONObject;
    function    Variables(VarsRef: Integer): TJSONObject;
    // Context selects how VS Code would have invoked evaluate: 'repl' for
    // the Debug Console, 'watch' for the Watch panel, 'hover' for source
    // tooltips. The adapter currently treats them all the same; the
    // parameter exists so the hover test can prove that.
    function    Evaluate(const Expr: string; FrameId: Integer;
                  const Context: string = 'repl'): TJSONObject;
    // DAP setVariable: change the value of a variable within an expanded
    // scope (locals, registers, or a class/record expansion).
    function    SetVariable(VarsRef: Integer; const Name, Value: string): TJSONObject;
    // Like SetVariable but returns the FULL response message (with `success`
    // and `message`) and does NOT raise on a failed request. Lets tests assert
    // that an invalid write is rejected cleanly.
    function    SetVariableRaw(VarsRef: Integer; const Name, Value: string): TJSONObject;
    function    Disconnect: TJSONObject;

    // --- Test injection of malformed / edge-case input ---
    // Send a fully-formed raw JSON message verbatim (no seq/command synthesis).
    // Lets tests feed the adapter inputs a well-behaved client never would,
    // e.g. a message with no `command`.
    procedure   SendRawJson(const Body: string);
    // True when NO response with request_seq=Seq arrives within TimeoutMs.
    // Used to assert the adapter correctly ignores a non-request message.
    function    NoResponseFor(Seq: Integer; TimeoutMs: Integer): Boolean;
    // Send a request whose arguments come from a literal JSON string and
    // return the assigned seq. Pair with WaitRawResponse to assert on the
    // raw success flag (no raise on failure).
    function    SendRequest(const Cmd, ArgsJson: string): Integer;
    // Public access to the raw response (full message, caller checks
    // `success`). Raises EDapError only on timeout.
    function    WaitRawResponse(Seq: Integer; TimeoutMs: Integer = 8000): TJSONObject;
    // DAP gotoTargets for a source line. Returns the response body.
    function    GotoTargets(const SourcePath: string; Line: Integer): TJSONObject;
    // DAP goto: move the instruction pointer to a target obtained from
    // gotoTargets. TargetId is the adapter''s target id (a VA, 64-bit).
    function    Goto_(ThreadId: Integer; TargetId: Int64): TJSONObject;

    // Event waiting
    function    WaitForInitialized(TimeoutMs: Integer = 8000): Boolean;
    function    WaitForStopped(TimeoutMs: Integer = 15000): TJSONObject;
    function    WaitForTerminated(TimeoutMs: Integer = 8000): Boolean;
    // Any event, by name. Returns False on timeout instead of raising, so a test
    // can assert an event did NOT arrive as readily as that it did. Body is the
    // event's `body` object (caller frees) and nil when it carried none.
    function    TryWaitForEvent(const EventName: string; TimeoutMs: Integer;
                  out Body: TJSONObject): Boolean;

    // High-level helpers
    function    GetFrameId: Integer;
    function    GetLocalsRef(FrameId: Integer): Integer;
    function    FindVar(VarsRef: Integer; const Name: string): TJSONObject;
    function    VarValue(VarsRef: Integer; const Name: string): string;
  end;

// Scan source file for line containing {BP:MarkerName}; returns 1-based line or 0.
function FindBpLine(const SourceFile, Marker: string): Integer;

implementation

uses
  System.IOUtils, System.StrUtils, TestTempDirs;

{ --------------------------------------------------------------------------- }
{ Reader thread }
{ --------------------------------------------------------------------------- }

type
  TReaderThread = class(TThread)
  private
    FOwner: TDapClient;
  public
    constructor Create(Owner: TDapClient);
    procedure Execute; override;
  end;

constructor TReaderThread.Create(Owner: TDapClient);
begin
  inherited Create(False);
  FOwner      := Owner;
  FreeOnTerminate := False;
end;

procedure TReaderThread.Execute;
begin
  FOwner.ReaderProc;
end;

{ --------------------------------------------------------------------------- }
{ TDapClient }
{ --------------------------------------------------------------------------- }

constructor TDapClient.Create;
begin
  inherited;
  FQueue  := TList<TJSONObject>.Create;
  FLock   := TCriticalSection.Create;
  FDataEvent := TEvent.Create(nil, True, False, '');
  FProc   := 0;
  FThread := 0;
  FStdinW := INVALID_HANDLE_VALUE;
  FStdoutR:= INVALID_HANDLE_VALUE;
  FSeq    := 0;
  FDead   := False;
  FSeqCommands := TDictionary<Integer, string>.Create;
end;

destructor TDapClient.Destroy;
begin
  Stop;
  if FRulesScratchDir <> '' then
    DeleteTempDirWithRetry(FRulesScratchDir);
  FLock.Acquire;
  try
    for var O in FQueue do O.Free;
    FQueue.Clear;
  finally
    FLock.Release;
  end;
  FQueue.Free;
  FLock.Free;
  FDataEvent.Free;
  FSeqCommands.Free;
  inherited;
end;

procedure TDapClient.Start(const AdapterExe: string; const ExtraArgs: string);
var
  SA:  TSecurityAttributes;
  SI:  TStartupInfo;
  PI:  TProcessInformation;
  StdinR, StdoutW: THandle;
  TmpR, TmpW: THandle;
begin
  SA.nLength              := SizeOf(SA);
  SA.bInheritHandle       := True;
  SA.lpSecurityDescriptor := nil;

  // stdin pipe
  Win32Check(CreatePipe(StdinR, TmpW, @SA, 0));
  Win32Check(DuplicateHandle(GetCurrentProcess, TmpW,
    GetCurrentProcess, @FStdinW, 0, False, DUPLICATE_SAME_ACCESS));
  CloseHandle(TmpW);

  // stdout pipe
  Win32Check(CreatePipe(TmpR, StdoutW, @SA, 0));
  Win32Check(DuplicateHandle(GetCurrentProcess, TmpR,
    GetCurrentProcess, @FStdoutR, 0, False, DUPLICATE_SAME_ACCESS));
  CloseHandle(TmpR);

  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESTDHANDLES;
  SI.hStdInput   := StdinR;
  SI.hStdOutput  := StdoutW;
  SI.hStdError   := StdoutW;

  var CmdLine := '"' + AdapterExe + '"';
  if ExtraArgs <> '' then
    CmdLine := CmdLine + ' ' + ExtraArgs;
  // When the runner was started with DAP_LOG=1, give this adapter a log file of
  // its own and remember where it is. The child inherits the environment, so
  // setting the variable here is what routes it; without a distinct path all the
  // adapters a parallel run has alive at once write into one file, and the one
  // interleaved log answers no question about any of them.
  GiveThisAdapterItsOwnLog;
  Win32Check(CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI));

  CloseHandle(StdinR);
  CloseHandle(StdoutW);

  FProc   := PI.hProcess;
  FThread := PI.hThread;
  FDead   := False;

  FReader := TReaderThread.Create(Self);
end;

procedure TDapClient.Stop;
begin
  if FProc <> 0 then begin
    TerminateProcess(FProc, 0);
    WaitForSingleObject(FProc, 3000);
    CloseHandle(FProc);
    CloseHandle(FThread);
    FProc   := 0;
    FThread := 0;
  end;
  if Assigned(FReader) then begin
    FReader.Terminate;
    FReader.WaitFor;
    FReader.Free;
    FReader := nil;
  end;
  if FStdinW <> INVALID_HANDLE_VALUE then begin
    CloseHandle(FStdinW);
    FStdinW := INVALID_HANDLE_VALUE;
  end;
  if FStdoutR <> INVALID_HANDLE_VALUE then begin
    CloseHandle(FStdoutR);
    FStdoutR := INVALID_HANDLE_VALUE;
  end;
end;

function TDapClient.NextSeq: Integer;
begin
  Inc(FSeq);
  Result := FSeq;
end;

procedure TDapClient.WriteMsg(const Body: string);
var
  UTF8: TBytes;
  Hdr:  AnsiString;
  Written: DWORD;
begin
  UTF8 := TEncoding.UTF8.GetBytes(Body);
  Hdr  := AnsiString(Format('Content-Length: %d'#13#10#13#10, [Length(UTF8)]));
  WriteFile(FStdinW, Hdr[1], Length(Hdr), Written, nil);
  if Length(UTF8) > 0 then
    WriteFile(FStdinW, UTF8[0], Length(UTF8), Written, nil);
end;

function TDapClient.ReadByte(out B: Byte): Boolean;
var
  Read: DWORD;
begin
  Result := ReadFile(FStdoutR, B, 1, Read, nil) and (Read = 1);
end;

procedure TDapClient.ReaderProc;
var
  B:    Byte;
  Line: string;
  ContentLen: Integer;
  Buf:  TBytes;
  Read: DWORD;
  Obj:  TJSONObject;

  function ReadLine: string;
  var
    Acc: TBytes;
    Prev: Byte;
  begin
    SetLength(Acc, 0);
    Prev := 0;
    while ReadByte(B) do begin
      if (Prev = 13) and (B = 10) then begin
        SetLength(Acc, Length(Acc) - 1);
        Break;
      end;
      Acc := Acc + [B];
      Prev := B;
    end;
    Result := TEncoding.UTF8.GetString(Acc);
  end;

begin
  while not TThread.CurrentThread.CheckTerminated do begin
    // Read headers
    ContentLen := -1;
    while True do begin
      Line := ReadLine;
      if (FStdoutR = INVALID_HANDLE_VALUE) or FDead then Exit;
      if Line = '' then Break;
      if Line.StartsWith('Content-Length:') then
        ContentLen := StrToIntDef(Trim(Line.Substring(15)), -1);
    end;
    if ContentLen <= 0 then Continue;

    // Read body
    SetLength(Buf, ContentLen);
    var Remaining := ContentLen;
    var Offset    := 0;
    while Remaining > 0 do begin
      if not ReadFile(FStdoutR, Buf[Offset], Remaining, Read, nil) or (Read = 0) then begin
        FDead := True;
        Exit;
      end;
      Inc(Offset, Read);
      Dec(Remaining, Read);
    end;

    try
      var JSON := TEncoding.UTF8.GetString(Buf);
      Obj := TJSONObject.ParseJSONValue(JSON) as TJSONObject;
      if Obj <> nil then
        Enqueue(Obj);
    except
      // Ignore malformed JSON
    end;
  end;
end;

procedure TDapClient.Enqueue(Obj: TJSONObject);
begin
  FLock.Acquire;
  try
    FQueue.Add(Obj);
    FDataEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TDapClient.Dequeue(Pred: TFunc<TJSONObject, Boolean>;
  TimeoutMs: Integer; out Msg: TJSONObject): Boolean;
var
  Deadline: UInt64;
  I:        Integer;
  Now:      UInt64;
begin
  Result   := False;
  Msg      := nil;
  Deadline := GetTickCount64 + UInt64(TimeoutMs);
  // Event-driven, not polled. The previous Sleep(15) loop quantised EVERY DAP
  // round trip to a 15 ms grid: a reply that arrived in 1 ms was still handed
  // back ~8 ms later on average. With ~30 waits per test and ~1200 tests that
  // quantisation alone was minutes of wall clock.
  while True do begin
    FLock.Acquire;
    try
      for I := 0 to FQueue.Count - 1 do
        if Pred(FQueue[I]) then begin
          Msg := FQueue[I];
          FQueue.Delete(I);
          Exit(True);
        end;
      // Nothing matched what is in the queue right now. Clearing the event here,
      // under the same lock Enqueue takes, means a message added from now on is
      // guaranteed to re-signal it.
      FDataEvent.ResetEvent;
    finally
      FLock.Release;
    end;
    Now := GetTickCount64;
    if Now >= Deadline then Exit(False);
    FDataEvent.WaitFor(Cardinal(Deadline - Now));
  end;
end;

function TDapClient.SendCmd(const Cmd: string; Args: TJSONObject): Integer;
var
  Req: TJSONObject;
begin
  Result := NextSeq;
  Req := TJSONObject.Create;
  try
    Req.AddPair('seq',     TJSONNumber.Create(Result));
    Req.AddPair('type',    'request');
    Req.AddPair('command', Cmd);
    FSeqCommands.AddOrSetValue(Result, Cmd);
    if Args <> nil then
      Req.AddPair('arguments', Args)
    else
      Req.AddPair('arguments', TJSONObject.Create);
    WriteMsg(Req.ToJSON);
  finally
    Req.Free;
  end;
end;

var
  // Distinguishes the adapters one runner spawns over its lifetime; the process
  // id distinguishes the runners. Together they name a file uniquely across a
  // parallel run without any coordination between the workers.
  GAdapterLogSerial: Integer = 0;

procedure TDapClient.GiveThisAdapterItsOwnLog;
begin
  FAdapterLogPath := '';
  if not SameText(GetEnvironmentVariable('DAP_LOG'), '1') then begin
    SetEnvironmentVariable('DAP_LOG_PATH', nil);
    Exit;
  end;
  Inc(GAdapterLogSerial);
  FAdapterLogPath := Format('%s\dap_adapter_%d_%d.log',
    [GetEnvironmentVariable('TEMP'), GetCurrentProcessId, GAdapterLogSerial]);
  SetEnvironmentVariable('DAP_LOG_PATH', PChar(FAdapterLogPath));
end;

function TDapClient.TimeoutDetail(Seq: Integer): string;
begin
  var Cmd: string;
  if not FSeqCommands.TryGetValue(Seq, Cmd) then
    Cmd := 'unknown request';
  Result := Format('seq=%d (%s)', [Seq, Cmd]);
  if FAdapterLogPath <> '' then
    Result := Result + ' -- adapter log: ' + FAdapterLogPath;
end;

function TDapClient.WaitResp(Seq, TimeoutMs: Integer): TJSONObject;
var
  Msg: TJSONObject;
begin
  if not Dequeue(
    function(O: TJSONObject): Boolean
    begin
      var T := O.GetValue<string>('type', '');
      var S := O.GetValue<Integer>('request_seq', -1);
      Result := (T = 'response') and (S = Seq);
    end, TimeoutMs, Msg) then
    raise EDapError.CreateFmt('Timeout after %d ms waiting for response to %s', [TimeoutMs, TimeoutDetail(Seq)]);

  if not Msg.GetValue<Boolean>('success', False) then begin
    var Err := Msg.GetValue<string>('message', 'unknown error');
    Msg.Free;
    raise EDapError.CreateFmt('DAP request failed: %s', [Err]);
  end;

  var BodyVal := Msg.GetValue('body') as TJSONObject;
  if BodyVal <> nil then
    Result := TJSONObject.ParseJSONValue(BodyVal.ToJSON) as TJSONObject
  else
    Result := TJSONObject.Create;
  Msg.Free;
end;

function TDapClient.WaitRespRaw(Seq, TimeoutMs: Integer): TJSONObject;
var
  Msg: TJSONObject;
begin
  if not Dequeue(
    function(O: TJSONObject): Boolean
    begin
      var T := O.GetValue<string>('type', '');
      var S := O.GetValue<Integer>('request_seq', -1);
      Result := (T = 'response') and (S = Seq);
    end, TimeoutMs, Msg) then
    raise EDapError.CreateFmt('Timeout after %d ms waiting for response to %s', [TimeoutMs, TimeoutDetail(Seq)]);
  // Hand back a private copy of the whole message; caller inspects success.
  Result := TJSONObject.ParseJSONValue(Msg.ToJSON) as TJSONObject;
  Msg.Free;
end;

{ DAP requests }

function TDapClient.Initialize(SupportsMemoryEvent: Boolean): TJSONObject;
var
  Args: TJSONObject;
  Seq:  Integer;
begin
  Args := TJSONObject.Create;
  Args.AddPair('clientID',             'DebuggerTests');
  Args.AddPair('adapterID',            'delphi-win64');
  Args.AddPair('linesStartAt1',        TJSONBool.Create(True));
  Args.AddPair('columnsStartAt1',      TJSONBool.Create(True));
  Args.AddPair('pathFormat',           'path');
  Args.AddPair('supportsVariableType', TJSONBool.Create(True));
  // Declared because VS Code declares it: the adapter is only allowed to emit
  // `invalidated` to a client that asked for it, and the raw-stack toggle relies
  // on that event to redraw the Call Stack. A test client that stayed silent
  // would leave that path unexercised.
  Args.AddPair('supportsInvalidatedEvent', TJSONBool.Create(True));
  // Real VS Code declares this so the adapter knows the client understands
  // `memoryReference` fields (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3). The
  // adapter does not currently gate memoryReference emission on it (neither
  // does the pre-existing `instructionPointerReference`), but a test client
  // that stayed silent here would not mirror what a real client sends.
  Args.AddPair('supportsMemoryReferences', TJSONBool.Create(True));
  // What lets the adapter tell an open memory view that its bytes changed --
  // at a stop, or after a write it performed itself. Gated: an adapter must not
  // send an event to a client that never declared it.
  if SupportsMemoryEvent then
    Args.AddPair('supportsMemoryEvent', TJSONBool.Create(True));
  Seq    := SendCmd('initialize', Args);
  Result := WaitResp(Seq);
end;

procedure TDapClient.MaybeAddDelphiProjectFile(Req: TJSONObject);
begin
  if DelphiProjectFile <> '' then
    Req.AddPair('delphiProjectFile', DelphiProjectFile);
end;

procedure TDapClient.MaybeAddRawStackScan(Req: TJSONObject);
begin
  if RawStackScan then
    Req.AddPair('rawStackScan', TJSONBool.Create(True));
end;

// Write the rules where a project's shared rules file would be, and point the
// session at that project. The project file itself is never opened by anyone --
// only its directory and base name decide the sidecar's name -- so it does not
// have to exist.
procedure TDapClient.StageRulesSidecar(const RulesJson: string);
begin
  if FRulesScratchDir = '' then
    FRulesScratchDir := MakeTestScratchDir('DapClientRules_');
  var ProjectFile := TPath.Combine(FRulesScratchDir, 'ScopedRules.dpr');
  TFile.WriteAllText(ChangeFileExt(ProjectFile, '.ExceptionSettings.json'), RulesJson);
  DelphiProjectFile := ProjectFile;
end;

function TDapClient.LaunchWithRules(const TargetExe, MapFile, RsmFile, SourceRoot: string;
  const Args: TArray<string>; const RulesJson: string;
  const Modules: TArray<TArray<string>>): TJSONObject;
var
  Req:    TJSONObject;
  ArgArr: TJSONArray;
  Seq:    Integer;
begin
  StageRulesSidecar(RulesJson);
  Req := TJSONObject.Create;
  Req.AddPair('program',      TargetExe);
  Req.AddPair('mapFile',      MapFile);
  Req.AddPair('rsmFile',      RsmFile);
  Req.AddPair('sourceRoot',   SourceRoot);
  Req.AddPair('stopAtEntry',  TJSONBool.Create(False));
  Req.AddPair('noDebug',      TJSONBool.Create(False));
  MaybeAddRawStackScan(Req);
  MaybeAddDelphiProjectFile(Req);
  Req.AddPair('useGlobalExceptionRules', TJSONBool.Create(False)); // test isolation: ignore the machine-wide rules file
  if Length(Args) > 0 then begin
    ArgArr := TJSONArray.Create;
    for var A in Args do ArgArr.Add(A);
    Req.AddPair('args', ArgArr);
  end;
  if Length(Modules) > 0 then begin
    var ModArr := TJSONArray.Create;
    for var M in Modules do begin
      var O := TJSONObject.Create;
      O.AddPair('name', M[0]);
      if Length(M) >= 2 then O.AddPair('map', M[1]);
      if Length(M) >= 3 then O.AddPair('rsm', M[2]);
      if Length(M) >= 4 then O.AddPair('dcp', M[3]);
      ModArr.AddElement(O);
    end;
    Req.AddPair('modules', ModArr);
  end;
  Seq    := SendCmd('launch', Req);
  Result := WaitResp(Seq);
end;

function TDapClient.LaunchWithRulesInTheRequest(const TargetExe, MapFile, RsmFile,
  SourceRoot: string; const Args: TArray<string>;
  const RulesJson: string): TJSONObject;
var
  Req: TJSONObject;
begin
  Req := TJSONObject.Create;
  Req.AddPair('program',      TargetExe);
  Req.AddPair('mapFile',      MapFile);
  Req.AddPair('rsmFile',      RsmFile);
  Req.AddPair('sourceRoot',   SourceRoot);
  Req.AddPair('stopAtEntry',  TJSONBool.Create(False));
  Req.AddPair('noDebug',      TJSONBool.Create(False));
  Req.AddPair('useGlobalExceptionRules', TJSONBool.Create(False));
  if Length(Args) > 0 then begin
    var ArgArr := TJSONArray.Create;
    for var A in Args do ArgArr.Add(A);
    Req.AddPair('args', ArgArr);
  end;
  var Rules := TJSONObject.ParseJSONValue(RulesJson) as TJSONArray;
  if Rules <> nil then
    Req.AddPair('exceptionRules', Rules);
  Result := WaitResp(SendCmd('launch', Req));
end;

function TDapClient.LaunchWithGlobalRules(const TargetExe, MapFile, RsmFile, SourceRoot: string;
  const Args: TArray<string>; const GlobalRulesPath: string;
  const Modules: TArray<TArray<string>>): TJSONObject;
var
  Req:    TJSONObject;
  ArgArr: TJSONArray;
  Seq:    Integer;
begin
  Req := TJSONObject.Create;
  Req.AddPair('program',      TargetExe);
  Req.AddPair('mapFile',      MapFile);
  Req.AddPair('rsmFile',      RsmFile);
  Req.AddPair('sourceRoot',   SourceRoot);
  Req.AddPair('stopAtEntry',  TJSONBool.Create(False));
  Req.AddPair('noDebug',      TJSONBool.Create(False));
  MaybeAddRawStackScan(Req);
  MaybeAddDelphiProjectFile(Req);
  Req.AddPair('useGlobalExceptionRules',   TJSONBool.Create(True));
  Req.AddPair('globalExceptionRulesPath',  GlobalRulesPath);
  if Length(Args) > 0 then begin
    ArgArr := TJSONArray.Create;
    for var A in Args do ArgArr.Add(A);
    Req.AddPair('args', ArgArr);
  end;
  if Length(Modules) > 0 then begin
    var ModArr := TJSONArray.Create;
    for var M in Modules do begin
      var O := TJSONObject.Create;
      O.AddPair('name', M[0]);
      if Length(M) >= 2 then O.AddPair('map', M[1]);
      if Length(M) >= 3 then O.AddPair('rsm', M[2]);
      if Length(M) >= 4 then O.AddPair('dcp', M[3]);
      ModArr.AddElement(O);
    end;
    Req.AddPair('modules', ModArr);
  end;
  Seq    := SendCmd('launch', Req);
  Result := WaitResp(Seq);
end;

function TDapClient.Launch(const TargetExe, MapFile, RsmFile, SourceRoot: string;
  StopAtEntry: Boolean; const Args: TArray<string>): TJSONObject;
var
  Req:    TJSONObject;
  ArgArr: TJSONArray;
  Seq:    Integer;
begin
  Req := TJSONObject.Create;
  Req.AddPair('program',      TargetExe);
  Req.AddPair('mapFile',      MapFile);
  Req.AddPair('rsmFile',      RsmFile);
  Req.AddPair('sourceRoot',   SourceRoot);
  Req.AddPair('stopAtEntry',  TJSONBool.Create(StopAtEntry));
  Req.AddPair('noDebug',      TJSONBool.Create(False));
  MaybeAddRawStackScan(Req);
  MaybeAddDelphiProjectFile(Req);
  Req.AddPair('useGlobalExceptionRules', TJSONBool.Create(False)); // test isolation: ignore the machine-wide rules file
  if Length(Args) > 0 then begin
    ArgArr := TJSONArray.Create;
    for var A in Args do ArgArr.Add(A);
    Req.AddPair('args', ArgArr);
  end;
  Seq    := SendCmd('launch', Req);
  Result := WaitResp(Seq);
end;

function TDapClient.Launch(const TargetExe, MapFile, RsmFile, SourceRoot: string;
  StopAtEntry: Boolean; const Args: TArray<string>;
  const Modules: TArray<TArray<string>>): TJSONObject;
var
  Req:    TJSONObject;
  ArgArr: TJSONArray;
  ModArr: TJSONArray;
  Seq:    Integer;
begin
  Req := TJSONObject.Create;
  Req.AddPair('program',      TargetExe);
  Req.AddPair('mapFile',      MapFile);
  Req.AddPair('rsmFile',      RsmFile);
  Req.AddPair('sourceRoot',   SourceRoot);
  Req.AddPair('stopAtEntry',  TJSONBool.Create(StopAtEntry));
  Req.AddPair('noDebug',      TJSONBool.Create(False));
  MaybeAddRawStackScan(Req);
  MaybeAddDelphiProjectFile(Req);
  Req.AddPair('useGlobalExceptionRules', TJSONBool.Create(False)); // test isolation: ignore the machine-wide rules file
  if Length(Args) > 0 then begin
    ArgArr := TJSONArray.Create;
    for var A in Args do ArgArr.Add(A);
    Req.AddPair('args', ArgArr);
  end;
  if Length(Modules) > 0 then begin
    ModArr := TJSONArray.Create;
    for var M in Modules do begin
      var O := TJSONObject.Create;
      O.AddPair('name', M[0]);
      if Length(M) >= 2 then O.AddPair('map', M[1]);
      if Length(M) >= 3 then O.AddPair('rsm', M[2]);
      if Length(M) >= 4 then O.AddPair('dcp', M[3]);
      ModArr.AddElement(O);
    end;
    Req.AddPair('modules', ModArr);
  end;
  Seq    := SendCmd('launch', Req);
  Result := WaitResp(Seq);
end;

function TDapClient.Attach(ProcessId: Cardinal;
  const ProgramPath, MapFile, RsmFile, SourceRoot: string;
  KillOnDetach: Boolean): TJSONObject;
var
  Args: TJSONObject;
  Seq:  Integer;
begin
  Args := TJSONObject.Create;
  Args.AddPair('processId',    TJSONNumber.Create(ProcessId));
  if ProgramPath <> '' then Args.AddPair('program',    ProgramPath);
  if MapFile     <> '' then Args.AddPair('mapFile',    MapFile);
  if RsmFile     <> '' then Args.AddPair('rsmFile',    RsmFile);
  if SourceRoot  <> '' then Args.AddPair('sourceRoot', SourceRoot);
  Args.AddPair('killOnDetach', TJSONBool.Create(KillOnDetach));
  Args.AddPair('useGlobalExceptionRules', TJSONBool.Create(False)); // test isolation: ignore the machine-wide rules file
  MaybeAddDelphiProjectFile(Args);
  Seq    := SendCmd('attach', Args);
  Result := WaitResp(Seq);
end;

function TDapClient.AttachByName(const ProcessName, ProgramPath, MapFile,
  RsmFile, SourceRoot: string; KillOnDetach: Boolean): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('processName', ProcessName);
  if ProgramPath <> '' then Args.AddPair('program',    ProgramPath);
  if MapFile     <> '' then Args.AddPair('mapFile',    MapFile);
  if RsmFile     <> '' then Args.AddPair('rsmFile',    RsmFile);
  if SourceRoot  <> '' then Args.AddPair('sourceRoot', SourceRoot);
  Args.AddPair('killOnDetach', TJSONBool.Create(KillOnDetach));
  Args.AddPair('useGlobalExceptionRules', TJSONBool.Create(False)); // test isolation: ignore the machine-wide rules file
  MaybeAddDelphiProjectFile(Args);
  Result := WaitResp(SendCmd('attach', Args));
end;

function TDapClient.SetBreakpoints(const SourcePath: string;
  Lines: TArray<Integer>): TJSONObject;
var
  Args, Src: TJSONObject;
  BpArr:     TJSONArray;
  Seq:       Integer;
begin
  Src := TJSONObject.Create;
  Src.AddPair('path', SourcePath);
  BpArr := TJSONArray.Create;
  for var L in Lines do begin
    var BP := TJSONObject.Create;
    BP.AddPair('line', TJSONNumber.Create(L));
    BpArr.Add(BP);
  end;
  Args := TJSONObject.Create;
  Args.AddPair('source',      Src);
  Args.AddPair('breakpoints', BpArr);
  Seq    := SendCmd('setBreakpoints', Args);
  Result := WaitResp(Seq);
end;

function TDapClient.SetBreakpoints(const SourcePath: string;
  Lines: TArray<Integer>;
  const Conditions, HitConditions, LogMessages: TArray<string>): TJSONObject;
var
  Args, Src: TJSONObject;
  BpArr:     TJSONArray;
  Seq:       Integer;

  function NthOrEmpty(const Arr: TArray<string>; Idx: Integer): string;
  begin
    if (Idx >= 0) and (Idx < Length(Arr)) then Result := Arr[Idx] else Result := '';
  end;

begin
  Src := TJSONObject.Create;
  Src.AddPair('path', SourcePath);
  BpArr := TJSONArray.Create;
  for var I := 0 to High(Lines) do begin
    var BP := TJSONObject.Create;
    BP.AddPair('line', TJSONNumber.Create(Lines[I]));
    var C := NthOrEmpty(Conditions,    I); if C <> '' then BP.AddPair('condition',    C);
    var H := NthOrEmpty(HitConditions, I); if H <> '' then BP.AddPair('hitCondition', H);
    var L := NthOrEmpty(LogMessages,   I); if L <> '' then BP.AddPair('logMessage',   L);
    BpArr.Add(BP);
  end;
  Args := TJSONObject.Create;
  Args.AddPair('source',      Src);
  Args.AddPair('breakpoints', BpArr);
  Seq    := SendCmd('setBreakpoints', Args);
  Result := WaitResp(Seq);
end;

function TDapClient.SetInstructionBreakpoints(
  const Addresses: TArray<string>): TJSONObject;
begin
  Result := SetInstructionBreakpoints(Addresses, nil, nil);
end;

function TDapClient.SetInstructionBreakpoints(const Addresses: TArray<string>;
  const Conditions, HitConditions: TArray<string>): TJSONObject;
var
  Args: TJSONObject;
  BpArr: TJSONArray;
  Seq:   Integer;

  function NthOrEmpty(const Arr: TArray<string>; Idx: Integer): string;
  begin
    if (Idx >= 0) and (Idx < Length(Arr)) then Result := Arr[Idx] else Result := '';
  end;

begin
  BpArr := TJSONArray.Create;
  for var I := 0 to High(Addresses) do begin
    var BP := TJSONObject.Create;
    BP.AddPair('instructionReference', Addresses[I]);
    var C := NthOrEmpty(Conditions,    I); if C <> '' then BP.AddPair('condition',    C);
    var H := NthOrEmpty(HitConditions, I); if H <> '' then BP.AddPair('hitCondition', H);
    BpArr.Add(BP);
  end;
  Args := TJSONObject.Create;
  Args.AddPair('breakpoints', BpArr);
  Seq    := SendCmd('setInstructionBreakpoints', Args);
  Result := WaitResp(Seq);
end;

function TDapClient.DataBreakpointInfo(const Name: string;
  VariablesReference: Integer; FrameId: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('name', Name);
  Args.AddPair('variablesReference', TJSONNumber.Create(VariablesReference));
  if FrameId >= 0 then
    Args.AddPair('frameId', TJSONNumber.Create(FrameId));
  Result := WaitResp(SendCmd('dataBreakpointInfo', Args));
end;

function TDapClient.DataBreakpointInfoAtAddress(const Expr: string; Bytes: Integer;
  FrameId: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('name', Expr);
  Args.AddPair('asAddress', TJSONBool.Create(True));
  if Bytes > 0 then
    Args.AddPair('bytes', TJSONNumber.Create(Bytes));
  if FrameId >= 0 then
    Args.AddPair('frameId', TJSONNumber.Create(FrameId));
  Result := WaitResp(SendCmd('dataBreakpointInfo', Args));
end;

function TDapClient.SetDataBreakpoints(const DataIds: TArray<string>;
  const AccessTypes: TArray<string>): TJSONObject;
var
  Args:  TJSONObject;
  BpArr: TJSONArray;
begin
  BpArr := TJSONArray.Create;
  for var I := 0 to High(DataIds) do begin
    var BP := TJSONObject.Create;
    BP.AddPair('dataId', DataIds[I]);
    if (I <= High(AccessTypes)) and (AccessTypes[I] <> '') then
      BP.AddPair('accessType', AccessTypes[I]);
    BpArr.Add(BP);
  end;
  Args := TJSONObject.Create;
  Args.AddPair('breakpoints', BpArr);
  Result := WaitResp(SendCmd('setDataBreakpoints', Args));
end;

function TDapClient.SetExceptionBreakpoints(
  const FilterIds: TArray<string>): TJSONObject;
var
  Args: TJSONObject;
  Arr:  TJSONArray;
begin
  Arr := TJSONArray.Create;
  for var Id in FilterIds do Arr.Add(Id);
  Args := TJSONObject.Create;
  Args.AddPair('filters', Arr);
  Result := WaitResp(SendCmd('setExceptionBreakpoints', Args));
end;

function TDapClient.SetExceptionBreakpoints(
  const FilterIds, Conditions: TArray<string>): TJSONObject;
var
  Args: TJSONObject;
  Filters, Opts: TJSONArray;
begin
  // Mirror real VS Code: once any filter advertises supportsCondition, the
  // client leaves the legacy `filters` array empty and sends every enabled
  // id inside `filterOptions` keyed by `filterId` (the DAP spec name).
  Filters := TJSONArray.Create;
  Opts    := TJSONArray.Create;
  for var I := 0 to High(FilterIds) do begin
    var O := TJSONObject.Create;
    O.AddPair('filterId', FilterIds[I]);
    if (I <= High(Conditions)) and (Conditions[I] <> '') then
      O.AddPair('condition', Conditions[I]);
    Opts.AddElement(O);
  end;
  Args := TJSONObject.Create;
  Args.AddPair('filters',       Filters);
  Args.AddPair('filterOptions', Opts);
  Result := WaitResp(SendCmd('setExceptionBreakpoints', Args));
end;

function TDapClient.ConfigDone: TJSONObject;
begin
  Result := WaitResp(SendCmd('configurationDone', nil));
end;

function TDapClient.Continue_(ThreadId: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('threadId', TJSONNumber.Create(ThreadId));
  Result := WaitResp(SendCmd('continue', Args));
end;

// Shared by the six Step*/Step*Raw methods below: `threadId` always sent,
// `granularity` only when the caller asked for it.
function BuildStepArgs(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('threadId', TJSONNumber.Create(ThreadId));
  if Granularity <> '' then
    Result.AddPair('granularity', Granularity);
end;

function TDapClient.StepIn(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := WaitResp(SendCmd('stepIn', BuildStepArgs(ThreadId, Granularity)));
end;

function TDapClient.StepOut(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := WaitResp(SendCmd('stepOut', BuildStepArgs(ThreadId, Granularity)));
end;

function TDapClient.StepOver(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := WaitResp(SendCmd('next', BuildStepArgs(ThreadId, Granularity)));
end;

function TDapClient.StepInRaw(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := WaitRespRaw(SendCmd('stepIn', BuildStepArgs(ThreadId, Granularity)));
end;

function TDapClient.StepOutRaw(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := WaitRespRaw(SendCmd('stepOut', BuildStepArgs(ThreadId, Granularity)));
end;

function TDapClient.StepOverRaw(ThreadId: Integer; const Granularity: string): TJSONObject;
begin
  Result := WaitRespRaw(SendCmd('next', BuildStepArgs(ThreadId, Granularity)));
end;

function TDapClient.StackTrace(ThreadId: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('threadId', TJSONNumber.Create(ThreadId));
  Args.AddPair('levels',   TJSONNumber.Create(10));
  Result := WaitResp(SendCmd('stackTrace', Args));
end;

function TDapClient.Disassemble(const MemoryReference: string;
  InstructionOffset, InstructionCount, ByteOffset: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('memoryReference',   MemoryReference);
  Args.AddPair('instructionOffset', TJSONNumber.Create(InstructionOffset));
  Args.AddPair('instructionCount',  TJSONNumber.Create(InstructionCount));
  if ByteOffset <> 0 then
    Args.AddPair('offset', TJSONNumber.Create(ByteOffset));
  Result := WaitResp(SendCmd('disassemble', Args));
end;

function TDapClient.DisassembleRaw(const MemoryReference: string;
  InstructionOffset, InstructionCount, ByteOffset: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('memoryReference',   MemoryReference);
  Args.AddPair('instructionOffset', TJSONNumber.Create(InstructionOffset));
  Args.AddPair('instructionCount',  TJSONNumber.Create(InstructionCount));
  if ByteOffset <> 0 then
    Args.AddPair('offset', TJSONNumber.Create(ByteOffset));
  Result := WaitRespRaw(SendCmd('disassemble', Args));
end;

function TDapClient.ReadMemory(const MemoryReference: string; Count: Integer;
  ByteOffset: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('memoryReference', MemoryReference);
  Args.AddPair('count',           TJSONNumber.Create(Count));
  if ByteOffset <> 0 then
    Args.AddPair('offset', TJSONNumber.Create(ByteOffset));
  Result := WaitResp(SendCmd('readMemory', Args));
end;

function TDapClient.ReadMemoryRaw(const MemoryReference: string; Count: Integer;
  ByteOffset: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('memoryReference', MemoryReference);
  Args.AddPair('count',           TJSONNumber.Create(Count));
  if ByteOffset <> 0 then
    Args.AddPair('offset', TJSONNumber.Create(ByteOffset));
  Result := WaitRespRaw(SendCmd('readMemory', Args));
end;

function TDapClient.WriteMemory(const MemoryReference, DataBase64: string;
  ByteOffset: Integer; AllowPartial: Boolean): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('memoryReference', MemoryReference);
  Args.AddPair('data',            DataBase64);
  if ByteOffset <> 0 then
    Args.AddPair('offset', TJSONNumber.Create(ByteOffset));
  if AllowPartial then
    Args.AddPair('allowPartial', TJSONBool.Create(True));
  Result := WaitResp(SendCmd('writeMemory', Args));
end;

function TDapClient.WriteMemoryRaw(const MemoryReference, DataBase64: string;
  ByteOffset: Integer; AllowPartial: Boolean): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('memoryReference', MemoryReference);
  Args.AddPair('data',            DataBase64);
  if ByteOffset <> 0 then
    Args.AddPair('offset', TJSONNumber.Create(ByteOffset));
  if AllowPartial then
    Args.AddPair('allowPartial', TJSONBool.Create(True));
  Result := WaitRespRaw(SendCmd('writeMemory', Args));
end;

// DAP `source`: fetches the content behind a frame's sourceReference. The
// adapter uses one only for the placeholder document it synthesises for frames
// with no real source file.
function TDapClient.SourceContent(SourceReference: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('sourceReference', TJSONNumber.Create(SourceReference));
  Result := WaitResp(SendCmd('source', Args));
end;

function TDapClient.Threads: TJSONObject;
begin
  Result := WaitResp(SendCmd('threads', TJSONObject.Create));
end;

function TDapClient.ExceptionInfo(ThreadId: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('threadId', TJSONNumber.Create(ThreadId));
  Result := WaitResp(SendCmd('exceptionInfo', Args));
end;

function TDapClient.Scopes(FrameId: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('frameId', TJSONNumber.Create(FrameId));
  Result := WaitResp(SendCmd('scopes', Args));
end;

function TDapClient.Variables(VarsRef: Integer): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('variablesReference', TJSONNumber.Create(VarsRef));
  Result := WaitResp(SendCmd('variables', Args));
end;

function TDapClient.Evaluate(const Expr: string; FrameId: Integer;
  const Context: string): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('expression', Expr);
  Args.AddPair('frameId',    TJSONNumber.Create(FrameId));
  Args.AddPair('context',    Context);
  Result := WaitResp(SendCmd('evaluate', Args));
end;

function TDapClient.SetVariable(VarsRef: Integer; const Name, Value: string): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('variablesReference', TJSONNumber.Create(VarsRef));
  Args.AddPair('name',  Name);
  Args.AddPair('value', Value);
  Result := WaitResp(SendCmd('setVariable', Args));
end;

function TDapClient.SetVariableRaw(VarsRef: Integer; const Name, Value: string): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('variablesReference', TJSONNumber.Create(VarsRef));
  Args.AddPair('name',  Name);
  Args.AddPair('value', Value);
  Result := WaitRespRaw(SendCmd('setVariable', Args));
end;

function TDapClient.Disconnect: TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('terminateDebuggee', TJSONBool.Create(True));
  try
    Result := WaitResp(SendCmd('disconnect', Args), 3000);
  except
    Result := TJSONObject.Create; // adapter may die before responding
  end;
end;

procedure TDapClient.SendRawJson(const Body: string);
begin
  WriteMsg(Body);
end;

function TDapClient.SendRequest(const Cmd, ArgsJson: string): Integer;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.ParseJSONValue(ArgsJson) as TJSONObject;
  // SendCmd takes ownership of Args (adds it to the request object it frees).
  Result := SendCmd(Cmd, Args);
end;

function TDapClient.WaitRawResponse(Seq: Integer; TimeoutMs: Integer): TJSONObject;
begin
  Result := WaitRespRaw(Seq, TimeoutMs);
end;

function TDapClient.GotoTargets(const SourcePath: string; Line: Integer): TJSONObject;
var
  Args, Src: TJSONObject;
begin
  Src := TJSONObject.Create;
  Src.AddPair('path', SourcePath);
  Args := TJSONObject.Create;
  Args.AddPair('source', Src);
  Args.AddPair('line', TJSONNumber.Create(Line));
  Result := WaitResp(SendCmd('gotoTargets', Args));
end;

function TDapClient.Goto_(ThreadId: Integer; TargetId: Int64): TJSONObject;
var
  Args: TJSONObject;
begin
  Args := TJSONObject.Create;
  Args.AddPair('threadId', TJSONNumber.Create(ThreadId));
  Args.AddPair('targetId', TJSONNumber.Create(TargetId));
  Result := WaitResp(SendCmd('goto', Args));
end;

function TDapClient.NoResponseFor(Seq: Integer; TimeoutMs: Integer): Boolean;
var
  Msg: TJSONObject;
begin
  // Dequeue returns True if a matching response shows up -> there WAS a response.
  Result := not Dequeue(
    function(O: TJSONObject): Boolean
    begin
      Result := (O.GetValue<string>('type', '') = 'response') and
                (O.GetValue<Integer>('request_seq', -1) = Seq);
    end, TimeoutMs, Msg);
  if not Result then
    Msg.Free;
end;

{ Event waiting }

function TDapClient.WaitForInitialized(TimeoutMs: Integer): Boolean;
var
  Msg: TJSONObject;
begin
  Result := Dequeue(
    function(O: TJSONObject): Boolean
    begin
      Result := (O.GetValue<string>('type', '') = 'event') and
                (O.GetValue<string>('event', '') = 'initialized');
    end, TimeoutMs, Msg);
  if Result then Msg.Free;
end;

function TDapClient.WaitForStopped(TimeoutMs: Integer): TJSONObject;
var
  Msg: TJSONObject;
begin
  if not Dequeue(
    function(O: TJSONObject): Boolean
    begin
      Result := (O.GetValue<string>('type', '') = 'event') and
                (O.GetValue<string>('event', '') = 'stopped');
    end, TimeoutMs, Msg) then
    raise EDapError.Create('Timeout waiting for stopped event' +
      IfThen(FAdapterLogPath <> '', ' -- adapter log: ' + FAdapterLogPath));

  var Body := Msg.GetValue('body') as TJSONObject;
  if Body <> nil then
    Result := TJSONObject.ParseJSONValue(Body.ToJSON) as TJSONObject
  else
    Result := TJSONObject.Create;
  Msg.Free;
end;

function TDapClient.TryWaitForEvent(const EventName: string; TimeoutMs: Integer;
  out Body: TJSONObject): Boolean;
var
  Msg: TJSONObject;
begin
  Body := nil;
  var Wanted := EventName;
  Result := Dequeue(
    function(O: TJSONObject): Boolean
    begin
      Result := (O.GetValue<string>('type', '') = 'event') and
                (O.GetValue<string>('event', '') = Wanted);
    end, TimeoutMs, Msg);
  if not Result then
    Exit;
  var B := Msg.GetValue('body') as TJSONObject;
  if B <> nil then
    Body := TJSONObject.ParseJSONValue(B.ToJSON) as TJSONObject;
  Msg.Free;
end;

function TDapClient.WaitForOutputContaining(const Substring: string;
  TimeoutMs: Integer): string;
var
  Msg:    TJSONObject;
  Body:   TJSONObject;
  OutStr: string;
  Sub:    string;
begin
  Sub    := Substring;
  Result := '';
  if not Dequeue(
    function(O: TJSONObject): Boolean
    var Inner: TJSONObject; S: string;
    begin
      Result := False;
      if (O.GetValue<string>('type', '')  <> 'event')  then Exit;
      if (O.GetValue<string>('event', '') <> 'output') then Exit;
      Inner := O.GetValue('body') as TJSONObject;
      if Inner = nil then Exit;
      S := Inner.GetValue<string>('output', '');
      Result := (Sub = '') or S.Contains(Sub);
    end, TimeoutMs, Msg) then
    raise EDapError.Create('Timeout waiting for output event containing "' + Substring + '"');
  Body   := Msg.GetValue('body') as TJSONObject;
  OutStr := '';
  if Body <> nil then OutStr := Body.GetValue<string>('output', '');
  Msg.Free;
  Result := OutStr;
end;

function TDapClient.WaitForTerminated(TimeoutMs: Integer): Boolean;
var
  Msg: TJSONObject;
begin
  Result := Dequeue(
    function(O: TJSONObject): Boolean
    begin
      var T  := O.GetValue<string>('type', '');
      var Ev := O.GetValue<string>('event', '');
      Result := (T = 'event') and ((Ev = 'terminated') or (Ev = 'exited'));
    end, TimeoutMs, Msg);
  if Result then Msg.Free;
end;

{ High-level helpers }

function TDapClient.GetFrameId: Integer;
var
  ST, Frames: TJSONObject;
  Arr:        TJSONArray;
begin
  ST     := StackTrace(1);
  try
    Arr    := ST.GetValue('stackFrames') as TJSONArray;
    if (Arr = nil) or (Arr.Count = 0) then
      raise EDapError.Create('No stack frames');
    Frames := Arr[0] as TJSONObject;
    Result := Frames.GetValue<Integer>('id', -1);
  finally
    ST.Free;
  end;
end;

function TDapClient.GetLocalsRef(FrameId: Integer): Integer;
var
  Sc:  TJSONObject;
  Arr: TJSONArray;
  I:   Integer;
begin
  Result := 0;
  Sc := Scopes(FrameId);
  try
    Arr := Sc.GetValue('scopes') as TJSONArray;
    if Arr = nil then Exit;
    for I := 0 to Arr.Count - 1 do begin
      var S := Arr[I] as TJSONObject;
      if SameText(S.GetValue<string>('name', ''), 'Locals') then begin
        Result := S.GetValue<Integer>('variablesReference', 0);
        Exit;
      end;
    end;
  finally
    Sc.Free;
  end;
end;

function TDapClient.FindVar(VarsRef: Integer; const Name: string): TJSONObject;

  // A class/record expansion now splits its members into synthetic
  // `properties` / `fields` group rows. A member the caller asks for by name
  // therefore lives one level down. Search the direct children first, then
  // descend into those group rows so callers keep addressing members by name.
  function SearchRef(Ref, Depth: Integer): TJSONObject;
  var
    Resp: TJSONObject;
    Arr:  TJSONArray;
    I:    Integer;
  begin
    Result := nil;
    if (Ref <= 0) or (Depth > 2) then Exit;
    Resp := Variables(Ref);
    try
      Arr := Resp.GetValue('variables') as TJSONArray;
      if Arr = nil then Exit;
      for I := 0 to Arr.Count - 1 do begin
        var V := Arr[I] as TJSONObject;
        if SameText(V.GetValue<string>('name', ''), Name) then
          Exit(TJSONObject.ParseJSONValue(V.ToJSON) as TJSONObject);
      end;
      for I := 0 to Arr.Count - 1 do begin
        var V := Arr[I] as TJSONObject;
        var N := V.GetValue<string>('name', '');
        if SameText(N, 'fields') or SameText(N, 'properties') then begin
          Result := SearchRef(V.GetValue<Integer>('variablesReference', 0), Depth + 1);
          if Result <> nil then Exit;
        end;
      end;
    finally
      Resp.Free;
    end;
  end;

begin
  Result := SearchRef(VarsRef, 0);
end;

function TDapClient.VarValue(VarsRef: Integer; const Name: string): string;
var
  V: TJSONObject;
begin
  Result := '';
  V := FindVar(VarsRef, Name);
  if V <> nil then
    try
      Result := V.GetValue<string>('value', '');
    finally
      V.Free;
    end;
end;

{ FindBpLine }

function FindBpLine(const SourceFile, Marker: string): Integer;
var
  Lines: TStringList;
  Tag:   string;
  I:     Integer;
begin
  Result := 0;
  Tag    := '{BP:' + Marker + '}';
  Lines  := TStringList.Create;
  try
    Lines.LoadFromFile(SourceFile);
    for I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then
        Exit(I + 1); // 1-based
  finally
    Lines.Free;
  end;
end;

end.
