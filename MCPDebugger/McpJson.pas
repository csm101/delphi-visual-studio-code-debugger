unit McpJson;

// Serializes the neutral DebugSession records to compact JSON for MCP tool
// results. No DAP ids appear here: frames carry a semantic index, breakpoints a
// file|line id, variables a formatted value. All functions return a fresh
// TJSONValue the caller owns.

interface

uses
  System.JSON, System.Generics.Collections,
  DebugSessionTypes, DebugTarget, DebugInfoTypes, DebugSession, ProcessEnum;

function IdJsonOf(Msg: TJSONObject): string;
function ParseIdOrNull(const IdJson: string): TJSONValue;

function StateName(S: TDebugSessionState): string;
function ReasonName(R: TStopReason): string;
function ArchName(A: TProcessArch): string;

function ProcessListToJson(const Procs: TArray<TProcessInfo>): TJSONArray;
function StatusToJson(Session: TDebugSession): TJSONObject;
function BreakpointListToJson(const Bps: TArray<TSessionBreakpoint>): TJSONArray;
function LocationToJson(const FnName, SrcFile: string; Line: Integer): TJSONObject;
function FrameListToJson(const Frames: TArray<TSessionFrame>): TJSONArray;
function ThreadListToJson(const Threads: TArray<TSessionThread>): TJSONArray;
function VarToJson(const V: TSessionVariable): TJSONObject;
function VarListToJson(const Vars: TArray<TSessionVariable>): TJSONArray;
function EvalResultToJson(const R: TSessionEvalResult): TJSONObject;
function ExceptionToJson(const E: TSessionExceptionInfo): TJSONObject;
function SnapshotToJson(const S: TCompactSnapshot): TJSONObject;
function StringListToJson(const Items: TArray<string>): TJSONArray;

implementation

uses
  System.SysUtils, System.DateUtils;

function IdJsonOf(Msg: TJSONObject): string;
begin
  var V := Msg.FindValue('id');
  if V = nil then
    Result := 'null'
  else
    Result := V.ToJSON;
end;

function ParseIdOrNull(const IdJson: string): TJSONValue;
begin
  if IdJson = '' then
    Exit(TJSONNull.Create);
  Result := TJSONObject.ParseJSONValue(IdJson);
  if Result = nil then
    Result := TJSONNull.Create;
end;

function StateName(S: TDebugSessionState): string;
begin
  case S of
    dsNone:       Result := 'none';
    dsConfiguring:Result := 'configuring';
    dsLaunching:  Result := 'launching';
    dsAttaching:  Result := 'attaching';
    dsRunning:    Result := 'running';
    dsStopped:    Result := 'stopped';
    dsExited:     Result := 'exited';
    dsDetached:   Result := 'detached';
    dsTerminated: Result := 'terminated';
  else
    Result := 'unknown';
  end;
end;

function ReasonName(R: TStopReason): string;
begin
  case R of
    srEntry:      Result := 'entry';
    srBreakpoint: Result := 'breakpoint';
    srStep:       Result := 'step';
    srException:  Result := 'exception';
    srPause:      Result := 'pause';
  else
    Result := 'unknown';
  end;
end;

function ArchName(A: TProcessArch): string;
begin
  case A of
    paX86:   Result := 'x86';
    paX64:   Result := 'x64';
    paArm64: Result := 'arm64';
  else
    Result := 'unknown';
  end;
end;

function ProcessListToJson(const Procs: TArray<TProcessInfo>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var P in Procs do begin
    var O := TJSONObject.Create;
    O.AddPair('pid',       TJSONNumber.Create(P.Pid));
    O.AddPair('parentPid', TJSONNumber.Create(P.ParentPid));
    O.AddPair('name',      P.ExeName);
    O.AddPair('path',      P.ExePath);
    O.AddPair('commandLine', P.CommandLine);
    // Same reason the attach picker shows it: with two instances of one
    // application the caption is often the only field that differs.
    if P.MainWindowTitle <> '' then
      O.AddPair('windowTitle', P.MainWindowTitle);
    O.AddPair('arch',      ArchName(P.Arch));
    if P.StartTime > 0 then
      O.AddPair('startTime', DateToISO8601(P.StartTime, False));
    Result.Add(O);
  end;
end;

function LocationToJson(const FnName, SrcFile: string; Line: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('function', FnName);
  Result.AddPair('sourceFile', SrcFile);
  Result.AddPair('line', TJSONNumber.Create(Line));
end;

function StatusToJson(Session: TDebugSession): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('state', StateName(Session.State));
  Result.AddPair('hasExited', TJSONBool.Create(Session.HasExited));
  if Session.State = dsStopped then begin
    var Fn, Src: string; var Ln: Integer;
    if Session.GetCurrentLocation(Fn, Src, Ln) then
      Result.AddPair('location', LocationToJson(Fn, Src, Ln));
  end;
end;

function BreakpointListToJson(const Bps: TArray<TSessionBreakpoint>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var B in Bps do begin
    var O := TJSONObject.Create;
    O.AddPair('id', B.Id);
    O.AddPair('sourceFile', B.SourceFile);
    O.AddPair('line', TJSONNumber.Create(B.Line));
    O.AddPair('verified', TJSONBool.Create(B.Verified));
    if B.Condition <> '' then
      O.AddPair('condition', B.Condition);
    Result.Add(O);
  end;
end;

function FrameListToJson(const Frames: TArray<TSessionFrame>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var F in Frames do begin
    var O := TJSONObject.Create;
    O.AddPair('index', TJSONNumber.Create(F.Index));
    O.AddPair('function', F.FunctionName);
    O.AddPair('sourceFile', F.SourceFile);
    O.AddPair('line', TJSONNumber.Create(F.SourceLine));
    // Address + owning module give a frame with no source (system / RTL / a
    // not-yet-symbolicated module) a usable identity instead of being blank (F2/F6).
    if F.IP <> 0 then
      O.AddPair('address', '0x' + IntToHex(F.IP, 1));
    if F.ModuleName <> '' then
      O.AddPair('module', F.ModuleName);
    // Always emitted, so an empty `function` is self-explaining: 'noSymbols'
    // (module known, built without debug info), 'indexing' (retry shortly),
    // 'unknownModule' (nothing mapped there), 'loaded' (symbols present -- this
    // particular address just is not covered by them).
    O.AddPair('symbols', SymbolAvailabilityName(F.Symbols));
    // A raw-sweep hit must not read like a walked frame to an agent either. It
    // is a POSITION on the stack: `proven` says the instruction ending at that
    // address was decoded and is a call, and NEITHER value says the routine is
    // still on the current chain -- a call that has already returned leaves its
    // return address behind. Walked frames carry no `kind`, so existing
    // consumers see no change.
    if F.Origin in [foRawProven, foRawUnproven] then begin
      O.AddPair('kind',   'rawStackHit');
      O.AddPair('proven', TJSONBool.Create(F.Origin = foRawProven));
    end;
    Result.Add(O);
  end;
end;

function ThreadListToJson(const Threads: TArray<TSessionThread>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var T in Threads do begin
    var O := TJSONObject.Create;
    O.AddPair('id', TJSONNumber.Create(Int64(T.OsThreadId)));
    O.AddPair('name', T.Name);
    O.AddPair('isStopped', TJSONBool.Create(T.IsStopped));
    // isCurrent marks the thread the debugger reports for this stop (for a pause
    // that is the retargeted main thread, not the injected one). Pass its id as
    // get_call_stack's threadId to walk any other thread.
    O.AddPair('isCurrent', TJSONBool.Create(T.IsCurrent));
    Result.Add(O);
  end;
end;

function VarToJson(const V: TSessionVariable): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', V.Name);
  Result.AddPair('value', V.Value);
  Result.AddPair('type', V.TypeName);
  Result.AddPair('expandable', TJSONBool.Create(V.Expandable));
  // Addressable path for re-evaluation (a getter-backed property, a field, an
  // array element). Present only when the value has one.
  if V.EvaluateName <> '' then
    Result.AddPair('evaluateName', V.EvaluateName);
  // A synthetic category row ('properties'/'event handlers'/'fields'): it has no
  // value of its own; expand it to read the members of that category.
  if V.Kind = vkGroup then
    Result.AddPair('group', TJSONBool.Create(True));
  // Opaque expansion handle (valid until the next stop). Pass it to
  // expand_variable to read the children of a class/record/array/group value.
  if V.Expandable and (V.Handle <> 0) then
    Result.AddPair('handle', UInt64(V.Handle).ToString);
end;

function VarListToJson(const Vars: TArray<TSessionVariable>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var V in Vars do
    Result.Add(VarToJson(V));
end;

function EvalResultToJson(const R: TSessionEvalResult): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('success', TJSONBool.Create(R.Success));
  if R.Success then begin
    Result.AddPair('value', R.Value);
    Result.AddPair('type', R.TypeName);
    // A class/record/array/Variant-array result is expandable: expose the same
    // opaque handle get_locals uses so a watch on an object can be drilled into
    // via expand_variable (F8).
    Result.AddPair('expandable', TJSONBool.Create(R.Expandable));
    if R.Expandable and (R.Handle <> 0) then
      Result.AddPair('handle', UInt64(R.Handle).ToString);
  end
  else
    Result.AddPair('error', R.ErrorText);
end;

function ExceptionToJson(const E: TSessionExceptionInfo): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('class', E.ExceptionClass);
  Result.AddPair('message', E.Message);
  Result.AddPair('description', E.Description);
  Result.AddPair('frames', FrameListToJson(E.Frames));
end;

function SnapshotToJson(const S: TCompactSnapshot): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('state', StateName(S.State));
  if S.State = dsStopped then begin
    Result.AddPair('stopReason', ReasonName(S.StopReason));
    Result.AddPair('thread', TJSONNumber.Create(S.OsThreadId));
    Result.AddPair('location', LocationToJson(S.CurrentFunction, S.CurrentFile, S.CurrentLine));
    Result.AddPair('frames', FrameListToJson(S.TopFrames));
    Result.AddPair('locals', VarListToJson(S.Locals));
    if S.HasException then
      Result.AddPair('exception', ExceptionToJson(S.Exception_));
  end;
end;

function StringListToJson(const Items: TArray<string>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var S in Items do
    Result.Add(S);
end;

end.
