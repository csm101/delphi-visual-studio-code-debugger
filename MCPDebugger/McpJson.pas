unit McpJson;

// Serializes the neutral DebugSession records to compact JSON for MCP tool
// results. No DAP ids appear here: frames carry a semantic index, breakpoints a
// file|line id, variables a formatted value. All functions return a fresh
// TJSONValue the caller owns.

interface

uses
  System.JSON, System.Generics.Collections,
  DebugSessionTypes, DebugTarget, DebugInfoTypes, DebugSession, ProcessEnum,
  Disassembler;

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
function ModuleListToJson(const Modules: TArray<TSessionModule>): TJSONArray;
function ModuleSourcesToJson(const Groups: TArray<TSessionModuleSources>): TJSONArray;
function StringListToJson(const Items: TArray<string>): TJSONArray;
function DataBreakpointToJson(const Bp: TSessionDataBreakpoint; const OwnId: string): TJSONObject;
function DataBreakpointListToJson(const Bps: TArray<TSessionDataBreakpoint>;
  const OwnIds: TArray<string>): TJSONArray;

// docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 4: the MCP equivalent of the DAP
// Registers scope. `value` is a variable-width hex string (never a bare JSON
// number -- a 64-bit register does not fit an IEEE double without loss), same
// convention DisasmInstructionToJson/DataBreakpointToJson already use for
// addresses. `size` is 8 for the 64-bit registers, 4 for EFlags.
function RegisterToJson(const R: TRegisterValue): TJSONObject;
function RegisterListToJson(const Regs: TArray<TRegisterValue>): TJSONArray;

// One disassembled instruction: address (same '0x' + hex spelling frames use,
// so it feeds straight back into `disassemble`), raw bytes, Intel-syntax
// text, whether Zydis decoded it (False -> Text is 'db XX', never a guessed
// mnemonic), and symbol/source when a provider knows one.
function DisasmInstructionToJson(const Ins: TDisasmInstruction): TJSONObject;
function DisasmInstructionListToJson(const Insns: TArray<TDisasmInstruction>): TJSONArray;

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
    // A watchpoint stop is not a breakpoint stop -- callers branching on this
    // string (an agent checking "did I hit MY breakpoint or the watchpoint")
    // must see a distinct value, not fall through to 'unknown'.
    srDataBreakpoint: Result := 'dataBreakpoint';
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
    if B.Kind = bkAddress then begin
      O.AddPair('kind', 'address');
      O.AddPair('address', '0x' + IntToHex(B.Address, 1));
      O.AddPair('module', B.ModuleName);
      O.AddPair('rva', '0x' + IntToHex(B.Rva, 1));
      O.AddPair('verified', TJSONBool.Create(B.Verified));
      if B.Message <> '' then
        O.AddPair('message', B.Message);
    end else begin
      O.AddPair('kind', 'source');
      O.AddPair('sourceFile', B.SourceFile);
      O.AddPair('line', TJSONNumber.Create(B.Line));
      O.AddPair('verified', TJSONBool.Create(B.Verified));
    end;
    if B.Condition <> '' then
      O.AddPair('condition', B.Condition);
    if B.HitCondition <> '' then
      O.AddPair('hitCondition', B.HitCondition);
    if B.LogMessage <> '' then
      O.AddPair('logMessage', B.LogMessage);
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
  // WHERE the value is, so an agent can reach read_memory / write_memory /
  // set_data_breakpoint without first re-deriving an address from the value
  // text. `address` is what a memory view would open on: the PAYLOAD for a
  // reference type (a string's characters, an array's elements, an object's
  // instance) and the variable's own storage otherwise -- dumping the slot of a
  // string shows a pointer, never the text. `storageAddress` is the slot
  // itself, which is what a WRITE to the variable targets, and it is emitted
  // only when the two differ, so the common case stays one field.
  //
  // Both are omitted rather than zeroed when the value has no address at all: a
  // register-resident local, a synthetic group row, a value a getter call
  // produced. `sizeBytes` likewise appears only when it was established, never
  // guessed -- see TVariableExpander.ValueByteSize.
  var Addr := V.Address;
  if V.DataAddress <> 0 then
    Addr := V.DataAddress;
  if Addr <> 0 then begin
    Result.AddPair('address', '0x' + IntToHex(Addr, 1));
    if (V.DataAddress <> 0) and (V.Address <> 0) and (V.Address <> V.DataAddress) then
      Result.AddPair('storageAddress', '0x' + IntToHex(V.Address, 1));
    if V.ValueSize > 0 then
      Result.AddPair('sizeBytes', TJSONNumber.Create(Int64(V.ValueSize)));
  end;
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
    // Same fields, same meaning, as VarToJson: an expression that names storage
    // can be read, written or watched by address. An rvalue -- an arithmetic
    // result, a value a call returned -- exists nowhere and carries none.
    var Addr := R.Address;
    if R.DataAddress <> 0 then
      Addr := R.DataAddress;
    if Addr <> 0 then begin
      Result.AddPair('address', '0x' + IntToHex(Addr, 1));
      if (R.DataAddress <> 0) and (R.Address <> 0) and (R.Address <> R.DataAddress) then
        Result.AddPair('storageAddress', '0x' + IntToHex(R.Address, 1));
      if R.ValueSize > 0 then
        Result.AddPair('sizeBytes', TJSONNumber.Create(Int64(R.ValueSize)));
    end;
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
    // "expression: $old -> $new (thread N)" -- the watched name/address, the
    // firing thread (also in `thread` above, repeated here so it is not
    // buried) and the old->new values in one string. Only meaningful when
    // stopReason = "dataBreakpoint".
    if S.StopReason = srDataBreakpoint then
      Result.AddPair('dataBreakpointDescription', S.DataBreakpointDescription);
    // Present only when the stop happened BECAUSE the breakpoint's condition
    // would not evaluate. Without it the stop looks unconditional, which is the
    // one thing an agent reading this snapshot cannot otherwise tell.
    if S.BreakpointConditionError <> '' then
      Result.AddPair('breakpointConditionError', S.BreakpointConditionError);
  end;
end;

function ModuleListToJson(const Modules: TArray<TSessionModule>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var M in Modules do begin
    var O := TJSONObject.Create;
    O.AddPair('name', M.Name);
    if M.Path <> '' then
      O.AddPair('path', M.Path);
    O.AddPair('isMain', TJSONBool.Create(M.IsMain));
    if M.Base <> 0 then
      O.AddPair('base', '0x' + IntToHex(M.Base, 1));
    if M.Size <> 0 then
      O.AddPair('size', TJSONNumber.Create(Int64(M.Size)));
    // Same vocabulary the frames use, so "why is this frame nameless" and "what
    // does this module have" are answered in one language.
    O.AddPair('symbols', SymbolAvailabilityName(M.Symbols));
    // Which formats actually LOADED. `symbols:"loaded"` with an empty list
    // cannot happen; `noSymbols` with an empty list is the ordinary case of a
    // module built without debug info.
    O.AddPair('formats', StringListToJson(M.Formats));
    Result.Add(O);
  end;
end;

function StringListToJson(const Items: TArray<string>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var S in Items do
    Result.Add(S);
end;

function ModuleSourcesToJson(
  const Groups: TArray<TSessionModuleSources>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var G in Groups do begin
    var O := TJSONObject.Create;
    O.AddPair('module', G.Module);
    O.AddPair('isMain', TJSONBool.Create(G.IsMain));
    O.AddPair('formats', StringListToJson(G.Formats));
    // '' means no loaded format can enumerate -- reported as an explicit null so
    // it cannot be misread as an empty file set.
    if G.ListedBy <> '' then
      O.AddPair('listedBy', G.ListedBy)
    else
      O.AddPair('listedBy', TJSONNull.Create);
    O.AddPair('complete', TJSONBool.Create(G.Complete));
    O.AddPair('fileCount', TJSONNumber.Create(Length(G.Files)));
    var Arr := TJSONArray.Create;
    for var F in G.Files do begin
      var FO := TJSONObject.Create;
      FO.AddPair('name', F.Name);
      if F.FullPath <> '' then
        FO.AddPair('path', F.FullPath);
      Arr.Add(FO);
    end;
    O.AddPair('files', Arr);
    Result.Add(O);
  end;
end;

// WriteOnly=True is the only access type with a real hardware equivalent
// ("write"); WriteOnly=False means read-or-write ("readWrite" -- there is no
// read-only watchpoint on x86/x64, see TSessionDataBreakpoint.Message for the
// caveat text carried alongside it).
function DataBpAccessName(WriteOnly: Boolean): string;
begin
  if WriteOnly then
    Result := 'write'
  else
    Result := 'readWrite';
end;

function DataBreakpointToJson(const Bp: TSessionDataBreakpoint; const OwnId: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', OwnId);
  Result.AddPair('expression', Bp.Expression);
  Result.AddPair('size', TJSONNumber.Create(Bp.SizeBytes));
  Result.AddPair('access', DataBpAccessName(Bp.WriteOnly));
  Result.AddPair('verified', TJSONBool.Create(Bp.Verified));
  // Address (and module+rva when it falls inside a known module) is filled in
  // as soon as the expression RESOLVES, even when arming itself was then
  // refused (e.g. slot exhaustion) -- so a refusal still tells the caller
  // which address it was about.
  if Bp.Address <> 0 then
    Result.AddPair('address', '0x' + IntToHex(Bp.Address, 1));
  if Bp.ModuleName <> '' then begin
    Result.AddPair('module', Bp.ModuleName);
    Result.AddPair('rva', '0x' + IntToHex(Bp.Rva, 1));
  end;
  // -1 until armed; a real DR0..DR3 index (four slots, process-wide) once
  // verified. Informational: it is what "exhausted" refers to.
  Result.AddPair('slot', TJSONNumber.Create(Bp.Slot));
  // A refusal reason when Verified=False, OR the no-read-only-watchpoint
  // caveat when Verified=True and access is "readWrite". Never both, never
  // silently absent when there is something to say.
  if Bp.Message <> '' then
    Result.AddPair('message', Bp.Message);
end;

function DataBreakpointListToJson(const Bps: TArray<TSessionDataBreakpoint>;
  const OwnIds: TArray<string>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var I := 0 to High(Bps) do begin
    var OwnId: string;
    // Defensive only: OwnIds is kept in lockstep with Bps by the caller
    // (McpServer) on every mutation. Fall back to the session-assigned id
    // (regenerated on every SetDataBreakpoints call) rather than crash if it
    // is ever out of sync.
    if I <= High(OwnIds) then
      OwnId := OwnIds[I]
    else
      OwnId := Bps[I].Id;
    Result.Add(DataBreakpointToJson(Bps[I], OwnId));
  end;
end;

function DisasmInstructionToJson(const Ins: TDisasmInstruction): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('address', '0x' + IntToHex(Ins.VA, 1));
  var BytesHex := '';
  for var B in Ins.Bytes do
    BytesHex := BytesHex + IntToHex(B, 2);
  Result.AddPair('bytes', BytesHex);
  Result.AddPair('text', Ins.Text);
  Result.AddPair('decoded', TJSONBool.Create(Ins.Decoded));
  if Ins.Symbol <> '' then
    Result.AddPair('symbol', Ins.Symbol);
  if Ins.SrcFile <> '' then begin
    Result.AddPair('sourceFile', Ins.SrcFile);
    Result.AddPair('sourceLine', TJSONNumber.Create(Ins.SrcLine));
  end;
end;

function DisasmInstructionListToJson(const Insns: TArray<TDisasmInstruction>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var Ins in Insns do
    Result.Add(DisasmInstructionToJson(Ins));
end;

function RegisterToJson(const R: TRegisterValue): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', R.Name);
  Result.AddPair('value', '0x' + IntToHex(R.Value, 1));
  Result.AddPair('size', TJSONNumber.Create(R.Size));
end;

function RegisterListToJson(const Regs: TArray<TRegisterValue>): TJSONArray;
begin
  Result := TJSONArray.Create;
  for var R in Regs do
    Result.Add(RegisterToJson(R));
end;

end.
