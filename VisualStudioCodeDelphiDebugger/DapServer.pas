unit DapServer;

interface

procedure RunDapServer;

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.SyncObjs, System.StrUtils, System.IOUtils, System.Math, System.DateUtils,
  System.NetEncoding,
  Winapi.Windows, Winapi.TlHelp32,
  DapProtocol, DebugInfoTypes, DebugInfoSet, DebugTarget, ExceptionRules,
  MapFileReader, TD32FileReader, RsmFileReader, WinDebuggerBase, DelphiRtti, DebugSourceIndex,
  DelphiValueReaders, SourceResolver, DebugSessionTypes, DebugSession, VariableExpander,
  BreakpointEval, PeSymbolSupport, ModuleSymbolLoader,
  // For NoStockMemoryViewSwitch: the unit that owns which command-line switches
  // this program recognises also owns their spelling.
  ProcessListJson,
  // For DefaultSafelistUserDir (the safelist responses name the user file).
  SafeCallPolicy,
  ExprEval, ValueEncoders, Disassembler, ZydisDisassembler;

// Full definition lives in the disassemble section further down (it is the
// same helper HandleDisassemble uses to locate Zydis.dll); needed earlier by
// TDapServer.BuildPlaceholderDisassembly (docs/ASSEMBLY_LEVEL_DEBUGGING.md
// increment 5). Forward-declared so call order is irrelevant.
function ResolveZydisDllPath: string; forward;

// Defined further down; used earlier by OnDllLoaded. Forward-declared so
// call order is irrelevant.

// Parse the launch.json `exceptionRules` array into the rule-engine table.
// Each entry: { class?: string|string[], classIs?: string|string[],
// code?: string|number|array, message?, messageRegex?, unit?, line?: int,
// lineFrom?: int, lineTo?: int, action: "ignore"|"log"|"logStack"|"break" }.
// Unknown / malformed entries are skipped.
function ParseExceptionRulesArray(Arr: TJSONArray): TArray<TExceptionRule>;

  function ReadNames(Entry: TJSONObject; const Key: string): TArray<string>;
  begin
    Result := nil;
    var V := Entry.FindValue(Key);
    if V is TJSONArray then begin
      for var I := 0 to TJSONArray(V).Count - 1 do
        Result := Result + [TJSONArray(V).Items[I].Value]
    end
    else if (V <> nil) and (V.Value <> '') then
      Result := [V.Value];
  end;

  // `code` accepts a hex ("0xC0000005" / "$C0000005") or decimal spelling, as a
  // JSON string or a JSON number, singly or as an any-of array. Entries that do
  // not parse are dropped rather than turned into a match-everything rule.
  function ReadCodes(Entry: TJSONObject; const Key: string): TArray<Cardinal>;

    procedure AddCode(V: TJSONValue; var Codes: TArray<Cardinal>);
    begin
      if V = nil then
        Exit;
      var Code: Cardinal;
      if ParseExceptionCode(V.Value, Code) then
        Codes := Codes + [Code];
    end;

  begin
    Result := nil;
    var V := Entry.FindValue(Key);
    if V is TJSONArray then begin
      for var I := 0 to TJSONArray(V).Count - 1 do
        AddCode(TJSONArray(V).Items[I], Result)
    end
    else
      AddCode(V, Result);
  end;

var
  Rules: TList<TExceptionRule>;
begin
  Result := nil;
  if Arr = nil then Exit;
  Rules := TList<TExceptionRule>.Create;
  try
    for var I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then Continue;
      var Entry := TJSONObject(Arr.Items[I]);
      var Action: TExceptionAction;
      if not ParseExceptionAction(Entry.GetValue<string>('action', ''), Action) then
        Continue;  // an action is mandatory and must be valid

      var Rule := Default(TExceptionRule);
      Rule.Action       := Action;
      Rule.ClassNames   := ReadNames(Entry, 'class');
      Rule.ClassIsNames := ReadNames(Entry, 'classIs');
      Rule.Codes        := ReadCodes(Entry, 'code');
      // A `code` that parsed to nothing would silently degrade into a wildcard
      // and make the rule match every exception; drop the rule instead.
      if (Entry.FindValue('code') <> nil) and (Length(Rule.Codes) = 0) then begin
        DapLog('exceptionRules: rule skipped, `code` is not a valid Win32 exception code');
        Continue;
      end;
      Rule.MessageSub   := Entry.GetValue<string>('message', '');
      Rule.MessageRegex := Entry.GetValue<string>('messageRegex', '');
      var UnitStr := Entry.GetValue<string>('unit', '');
      if SameText(UnitStr, UNKNOWN_UNIT_TOKEN) then
        Rule.MatchUnknownUnit := True
      else
        Rule.UnitName := UnitStr;
      Rule.LineFrom := -1;
      Rule.LineTo   := -1;
      var SingleLine := Entry.GetValue<Integer>('line', -1);
      if SingleLine >= 0 then begin
        Rule.LineFrom := SingleLine;
        Rule.LineTo   := SingleLine;
      end;
      Rule.LineFrom := Entry.GetValue<Integer>('lineFrom', Rule.LineFrom);
      Rule.LineTo   := Entry.GetValue<Integer>('lineTo',   Rule.LineTo);
      Rules.Add(Rule);
    end;
    Result := Rules.ToArray;
  finally
    Rules.Free;
  end;
end;

// Load exception rules from a JSON file -- the machine-wide shared file or
// either project sidecar; all three have the same shape. Accepts a bare array or
// an object with an `exceptionRules` key. Strict JSON, no JSONC: this is not
// launch.json. A missing or malformed file yields no rules and never raises --
// rules the user cannot see are a nuisance, a debugger that will not start is not.
function LoadExceptionRulesFile(const Path: string): TArray<TExceptionRule>;
begin
  Result := nil;
  if (Path = '') or not FileExists(Path) then Exit;
  try
    var Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Path, TEncoding.UTF8));
    if Root = nil then Exit;
    try
      if Root is TJSONArray then
        Result := ParseExceptionRulesArray(TJSONArray(Root))
      else if Root is TJSONObject then
        Result := ParseExceptionRulesArray(
          TJSONObject(Root).FindValue('exceptionRules') as TJSONArray);
    finally
      Root.Free;
    end;
  except
    on E: Exception do
      DapLog('LoadExceptionRulesFile failed: ' + E.Message);
  end;
end;

// Default shared-rules path: %USERPROFILE%\.DelphiWinDebugger\exceptionRules.json
function DefaultGlobalExceptionRulesPath: string;
begin
  var Home := GetEnvironmentVariable('USERPROFILE');
  if Home = '' then Exit('');
  Result := TPath.Combine(TPath.Combine(Home, '.DelphiWinDebugger'), 'exceptionRules.json');
end;

// Last-write time of a rules file, 0 when absent -- used to detect edits. An
// absent file legitimately has an mtime: creating it later IS a change.
function ExceptionRulesFileMTime(const Path: string): TDateTime;
begin
  Result := 0;
  if (Path <> '') and FileExists(Path) then
    try
      Result := TFile.GetLastWriteTime(Path);
    except
      Result := 0;
    end;
end;


// Whether to advertise `supportsReadMemoryRequest` / `supportsWriteMemoryRequest`.
// A command-line switch rather than a launch-config field, because `initialize`
// -- where capabilities are answered -- arrives BEFORE any launch configuration
// the client might carry an option in.
function StockMemoryViewEnabled: Boolean;
begin
  Result := True;
  for var I := 1 to ParamCount do
    if SameText(ParamStr(I), NoStockMemoryViewSwitch) then
      Exit(False);
end;

function NormalizeModuleName(const Name: string): string;
begin
  // Extract the basename robustly across separator styles. ExtractFileName only
  // splits on '\' and ':' (Windows), so a launch-config module path that uses
  // FORWARD slashes (e.g. "/Users/Public/.../libAboutBoxD29.bpl", as the IDE plugin
  // currently emits) would otherwise be compared whole -> the module is never
  // recognised as configured -> wrong sidecar paths, DCP/locals never load.
  var S := Trim(Name);
  var P := LastDelimiter('/\:', S);   // 1-based; 0 when none present
  if P > 0 then
    S := Copy(S, P + 1, MaxInt);
  Result := LowerCase(S);
end;

function ModuleNameMatches(const ConfigName, ModuleName: string): Boolean;
begin
  var Cfg := NormalizeModuleName(ConfigName);
  var ModName := NormalizeModuleName(ModuleName);
  if (Cfg = '') or (ModName = '') then
    Exit(False);
  if Cfg = ModName then
    Exit(True);
  Result := SameText(ChangeFileExt(Cfg, ''), ChangeFileExt(ModName, ''));
end;

const
  // DAP variablesReference values. Each scope uses a fixed non-zero ref.
  LOCALS_VAR_REF    = 1000;
  REGISTERS_VAR_REF = 1001;
  // Object/record expansion refs start here and are allocated dynamically.
  EXPANSION_REF_BASE = 2000;

type
  TModuleConfig = record
    Name:    string; // lowercase filename
    MapPath: string;
    RsmPath: string;
    DcpPath: string;
  end;

  // The DAP-side runtime module record: the shared slim record (Name/paths/iface-
  // slots/*Tried flags/ContainsPC, in ModuleSymbolLoader.TModuleSymbols) enriched
  // with the PACKAGEINFO / source-index membership test the DAP frontend needs.
  // TModuleSymbolLoader.ModuleClass is set to this class so its registry creates
  // TDllModule instances that the loader treats through the base type.
  TDllModule = class(TModuleSymbols)
  private
    FIndex: TDebugSourceIndex; // lazy-created on first ContainsSourceFile call
    FPackageUnitsLoaded: Boolean;
    FPackageUnits: TDictionary<string, Boolean>; // lowercase unit name -> present
    FRequiredPackages: TArray<string>; // lowercase base names from PACKAGEINFO
    function ContainsUnitByPackageInfo(const UnitName: string): Boolean;
  public
    destructor Destroy; override;
    function ContainsSourceFile(const FileName: string): Boolean; override;
    // Package base names this BPL `requires` (lowercase, no extension), read
    // from PACKAGEINFO. Drives the uses-graph global tier so a required
    // package's global beats an unrelated module's same-named global.
    function RequiredPackages: TArray<string>;
  end;

type
  // One memory view the client currently has open, learned from the readMemory
  // requests it issues -- DAP has no "the user opened a memory pane" request, and
  // the client never says when it closes one either, so this is the only evidence
  // there is. Offset/EndOff bound the widest span read through this reference, so
  // one `memory` event can invalidate everything the pane has shown.
  TMemoryView = record
    MemRef: string;
    Offset: Int64;   // lowest byte offset read through MemRef
    EndOff: Int64;   // exclusive upper bound of the bytes read
  end;

  // What a memoryReference the adapter handed out actually refers to. The
  // client's memory view knows only an address; this is how it learns WHICH
  // bytes belong to the variable it was opened on, so it can mark the value's
  // formal extent instead of drawing an undifferentiated dump.
  TMemoryExtent = record
    Address:  UInt64;
    Size:     UInt64;   // 0 = the adapter could not establish it (never guessed)
    Name:     string;
    TypeName: string;
  end;

  // One tier of the exception-rule precedence chain. The session holds them in
  // order, most specific first, and the table handed to the engine is simply
  // their rules concatenated -- first match wins across the whole chain.
  //
  // Every tier is a FILE, and carries the mtime last seen there so the resume
  // path can notice an edit and reload just that tier.
  TExceptionRuleTier = record
    Path:        string;
    Description: string;   // how the console log names this tier
    MTime:       TDateTime;
    Rules:       TArray<TExceptionRule>;
  end;

  // Background symbol-loader work item. A VALUE copy of the fields the parse
  TDapServer = class
  private
    FIO:        TDapIO;
    // The debugger-core facade OWNS the single engine (IDebugTarget), the aggregate
    // debug-info set + symbol loader, the source resolver, RTTI + value readers, the
    // variable expander and the breakpoint evaluator. The DAP frontend constructs and
    // frees exactly this one object; every former field below (FDebugInfo / FLoader /
    // FDebugger / FExpander / FRtti / FSourceResolver / Readers) is now a thin read
    // accessor returning the session's single instance -- the DAP layer creates and
    // frees none of them.
    FSession:   TDebugSession;
    FLastFrames: TArray<TSessionFrame>;  // cached by stackTrace; frameId indexes it
    // Thread the last stackTrace was for. A frameId is only an INDEX, so it is
    // meaningful only together with its thread -- scopes/evaluate carry no
    // threadId, and without this the index was paired with the stopped thread.
    FLastStackTid: Cardinal;
    // frameId of the last `scopes` request. A `dataBreakpointInfo` for a
    // variable in the Locals scope carries the CONTAINER's variablesReference
    // and no frameId, so the frame it means is the one the Locals scope was
    // last opened for -- exactly what the following `variables` request resolves
    // against too.
    FLastScopeFrameId: Integer;
    // `rawStackScan` in launch.json: append the brute-force sweep of the
    // thread's stack below the walked frames. Off by default -- the results are
    // POSITIONS on the stack, not a chain, and a user who has not asked for
    // them must never be shown them next to real frames.
    FRawStackScan: Boolean;
    // `noSourcePlaceholder` in launch.json, default True. False attaches no
    // source at all to a sourceless frame, so the client is left to its own
    // handling. See ParseRawStackScan for why this is a switch and not a
    // decision.
    FNoSourcePlaceholder: Boolean;
    // True when the client declared `supportsInvalidatedEvent` in `initialize`.
    // The raw-stack toggle uses it to make the Call Stack redraw immediately; a
    // client without it still gets the toggle, its effect showing at the next stop.
    FClientSupportsInvalidated: Boolean;
    // True when the client declared `supportsMemoryEvent` in `initialize`. VS Code
    // does. Without the event a hex pane shows whatever it read when it opened and
    // never refreshes -- not after a resume/stop, not after a setVariable write --
    // because nothing else in DAP tells a client that target MEMORY changed
    // (`invalidated` covers stacks/variables, not memory).
    FClientSupportsMemoryEvent: Boolean;
    // Memory views the client has open, one entry per memoryReference. Bounded:
    // the client is free to open a view on every variable it ever showed, and
    // nothing says when one closes, so old entries are evicted rather than kept
    // forever. A stale entry costs one re-read the client throws away.
    FMemoryViews: TArray<TMemoryView>;
    // Every memoryReference handed out this session, and what it refers to.
    // Written where the reference is minted (the variables and evaluate paths),
    // because that is the only moment the variable's name, type and size are in
    // hand; read by the `delphiMemoryExtent` request the memory view issues.
    FMemoryExtents: TDictionary<string, TMemoryExtent>;
    // Where the DEBUGGER's own diagnostics go. True (default) sends them as
    // `delphiLog` custom events for the extension's "Delphi Debugger" output
    // channel; False keeps the old behaviour and prints them in the Debug
    // Console. The program's output and logpoint messages are unaffected
    // either way -- they always go to the Debug Console.
    FDiagnosticsToOutputChannel: Boolean;
                                         // (neutral session frames carry FrameRBP /
                                         // FuncEntryVA / IP for frame selection)
    // Placeholder documents for frames with no source file. Without a `source`
    // of any kind VS Code has nothing to open, so a stop in sourceless code
    // looks like nothing happened at all -- the debug view does not come
    // forward and no editor appears. A `sourceReference` gives the client a
    // document to open; the text says WHY there is no source. Keyed by the
    // frame label so the same address reuses one reference, which is what lets
    // the client cache the content.
    FSynthSourceRefs:    TDictionary<string, Integer>;
    FSynthSourceTexts:   TDictionary<Integer, string>;
    FNextSynthSourceRef: Integer;
    FExePath:    string;
    FMapPath:    string;
    FRsmPath:    string;
    FSourceRoot: string;
    FExtraSourcePaths: TArray<string>;
    FStopAtEntry: Boolean;
    FLaunched:   Boolean;
    FQuit:       Boolean;  // set by HandleDisconnect / wrAbandoned to break the Run loop cleanly
    FConfigDone: Boolean;
    // Breakpoint plant/verify/pending are owned by FSession now. The DAP layer keeps
    // only the mapping needed to answer setBreakpoints and to emit the `breakpoint`
    // changed event: a stable numeric id per session 'file|line', the original request
    // source path for the changed event's source object, and the next id to hand out.
    // DLL module tracking for multi-module debugging lives in FLoader.Modules.
    FBpIds:         TDictionary<string, Integer>; // session 'file|line' -> stable DAP breakpoint id
    FBpSourcePath:  TDictionary<string, string>;  // lcase basename -> original request source path
    FNextBpId:      Integer;
    // Data breakpoints. FDataBpIds gives each dataId a stable numeric DAP id so
    // a `breakpoint` event can name one; FDataBpNonce stamps frame-scoped
    // dataIds with the identity of THIS run, because VS Code persists data
    // breakpoints across sessions and a stack frame from a previous process is
    // not something to re-arm silently.
    FDataBpIds:     TDictionary<string, Integer>;
    FNextDataBpId:  Integer;
    FDataBpNonce:   string;
    FModulesConfig: TArray<TModuleConfig>;         // from launch 'modules' array
    // The RTTI reader, leaf value readers and the nested-variable expansion engine
    // (opaque-handle table) all live in FSession now; reached via the FRtti / Readers
    // / FExpander read accessors. The DAP frontend still owns the integer
    // variablesReference <-> opaque TVarHandle bimap below (per-stop, DAP-only).
    FRefToHandle: TDictionary<Integer, TVarHandle>;  // DAP ref -> opaque handle
    FHandleToRef: TDictionary<TVarHandle, Integer>;  // reverse (one handle -> one ref)
    FNextExpRef:  Integer;
    FStoppedOnException: Boolean; // current stop is an exception -> show $exception local
    // Where progress is rendered, from the launch/attach config `progressLocation`
    // ("statusBar" -- the default -- or "notification").
    //
    // True  -> emit ONLY the `delphiProgress` custom event, which our VS Code
    //          extension renders in the status bar.
    // False -> emit ONLY the standard DAP progressStart/Update/End events, which
    //          VS Code renders as notification toasts.
    //
    // Never both. A DAP client that is not our extension gets the standard events
    // by setting `progressLocation: "notification"` and keeps working unchanged;
    // emitting both channels at once would double-report every operation.
    FProgressAsCustomEvent: Boolean;
    // Startup progress tracking
    FStartupActive:   Boolean;
    // Tick of the most recent module-load event. Startup progress normally ends
    // at the first stop, but an ATTACH to an application that simply keeps
    // running never produces one, so the indicator stayed up for the whole
    // session. The watchdog closes it once module loading has gone quiet.
    FLastDllTick:     UInt64;
    // Operation progress (id 'op'): a status-bar spinner shown while the adapter
    // is BUSY -- a step/continue command AND the post-stop request burst it
    // triggers (stackTrace / variables / the slow watch evaluates), so the user
    // sees activity instead of a silent toolbar. `MarkBusy` (re)arms it and
    // refreshes FLastBusyTick; a watchdog thread closes it ~400ms after the last
    // activity (continuous spinner across the burst, no per-request flicker).
    FOpProgressActive: Boolean;
    FLastBusyTick:     UInt64;
    FOpBusyTitle:      string;
    FOpLock:           TRTLCriticalSection;
    FWatchdog:         TThread;
    FWatchdogStop:     Boolean;
    FStepPending:      Boolean;  // a step/continue posted, awaiting the stop
    FProcessing:       Boolean;  // a DAP request is being handled right now
                                 // (so a single slow request -- e.g. a 5s watch
                                 // evaluate -- keeps the spinner up; the watchdog
                                 // only closes it once BOTH are clear + idle)
    FBusyArmed:        Boolean;  // an operation is in progress (armed by MarkBusy)
    FBusySince:        UInt64;   // when the current busy period began -- the
                                 // spinner is only SHOWN once busy > ~350ms, so
                                 // fast steps never pop a notification (debounce)
    FStartupDllCount: Integer;
    FStartupMapCount: Integer;
    FStartupTick:     UInt64;  // GetTickCount64 at launch
    FAdapterStartTick: UInt64; // GetTickCount64 at adapter process start
    FSetBpCount:      Integer; // number of setBreakpoints calls received
    // Session breakpoint ids planted by the LAST setInstructionBreakpoints
    // call, so the NEXT call (which replaces the whole set, per the DAP spec)
    // can remove exactly the ones it is dropping instead of a blind
    // remove-everything -- mirrors FDataBpOwnIds in the MCP server.
    FInstrBpIds:      TArray<string>;
    // DebugInfo revision at which the evaluate-fallback symbol warm-up last ran
    // to completion. While it is unchanged no new module could have appeared, so
    // a failed evaluate skips re-iterating every DLL module (was paid on every
    // unresolved watch on every stop). A module load bumps Revision -> re-warm.
    FLastEvalWarmupRevision: UInt64;
    FEvalWarmupRan:          Boolean;
    // O(1) negative-result index for bare-identifier watches/hovers.
    // Key: lcase(name)|funcEntryVA|revision -> the '<name: not found>' result.
    // A full miss is stable for the same function at the same provider revision,
    // so a repeated unresolved watch becomes a single dictionary lookup instead
    // of re-running ExprEval's whole resolution chain on every stop.
    FEvalMissCache:          TDictionary<string, string>;
    FExceptionFilters:    TExceptionFilters;
    FExceptionFiltersSet: Boolean;
    FDelphiClassFilter:   string;  // condition for the `delphi` filter (comma-separated class names)
    // Exception-rule state, captured at launch so the file-backed tiers can be
    // hot-reloaded on resume without re-reading launch.json.
    FRuleTiers:         TArray<TExceptionRuleTier>; // ordered, most specific first
    FDelphiProjectFile: string;   // `delphiProjectFile`, absolute; '' = no project scope
    FUseGlobalRules:    Boolean;
    FGlobalRulesPath:   string;

    // `progressLocation` from the launch/attach config -> FProgressAsCustomEvent.
    procedure ParseProgressLocation(Args: TJSONObject);
    // `rawStackScan` from the launch/attach config -> FRawStackScan.
    procedure ParseRawStackScan(Args: TJSONObject);
    // Custom request: flips the raw stack sweep mid-session (Call Stack toggle).
    procedure HandleSetRawStackScan(Seq: Integer; Args: TJSONObject);
    // `diagnosticsLocation` -> FDiagnosticsToOutputChannel.
    procedure ParseDiagnosticsLocation(Args: TJSONObject);
    // Emits one diagnostic line to wherever diagnostics currently go.
    procedure SendDiagnosticEvent(const Text: string);
    // Marks a raw-sweep frame's displayed name; returns a walked frame's name
    // unchanged.
    function  RawStackLabel(const F: TSessionFrame; const Name: string): string;
    // THE single fan-out point for every progress moment of both channels
    // ('startup' and 'op'). AState is 'start', 'update' or 'end'. It picks the
    // wire format from FProgressAsCustomEvent; no caller ever emits an event
    // directly, so the two channels can never diverge or both fire.
    procedure EmitProgress(const AId, AState, AText: string);
    procedure SendProgressStart(const AMsg: string);
    procedure SendProgressUpdate(const AMsg: string);
    procedure SendProgressEnd(const AMsg: string);
    // Operation progress (id 'op') -- raw senders (caller holds FOpLock).
    procedure SendOpProgressStart(const ATitle: string);
    procedure SendOpProgressEnd;
    // (Re)arm the busy spinner and refresh the idle timer. Thread-safe.
    // StepPending=True marks an async step/continue in flight (cleared by the
    // next MarkBusy, i.e. at the stop) so the watchdog won't close mid-step.
    procedure MarkBusy(const ATitle: string; StepPending: Boolean = False);
    // Retitle the busy period in flight (and push it to the client if the
    // spinner is already up) without restarting the debounce. Thread-safe.
    procedure UpdateBusyTitle(const ATitle: string);
    // TModuleSymbolLoader.OnModuleLoadBegin subscriber: names the module whose
    // symbols are being parsed right now in the busy text.
    procedure LoaderModuleLoadBegin(const ADisplayName: string);
    procedure SendConsoleLog(const AMsg: string);
    procedure EnsureMainRsm;

    procedure HandleInitialize(Seq: Integer; Args: TJSONObject);
    procedure HandleLaunch(Seq: Integer; Args: TJSONObject);
    procedure HandleAttach(Seq: Integer; Args: TJSONObject);
    procedure HandleConfigurationDone(Seq: Integer);
    procedure HandleSetBreakpoints(Seq: Integer; Args: TJSONObject);
    // Address breakpoints (docs/DISASSEMBLY_PLAN.md increment 5) -- VS Code's own
    // address-breakpoint channel, and the one the Disassembly View gutter
    // uses. Replaces the WHOLE set on every call, per the DAP spec, using
    // FInstrBpIds to remove exactly what the previous call planted.
    procedure HandleSetInstructionBreakpoints(Seq: Integer; Args: TJSONObject);
    procedure HandleSetExceptionBreakpoints(Seq: Integer; Args: TJSONObject);
    procedure HandleExceptionInfo(Seq: Integer; Args: TJSONObject);
    function  BuildExceptionFilterCapability: TJSONArray;
    // Data breakpoints (watchpoints). `dataBreakpointInfo` turns a variable the
    // user right-clicked into an opaque dataId; `setDataBreakpoints` replaces
    // the whole armed set from those ids.
    procedure HandleDataBreakpointInfo(Seq: Integer; Args: TJSONObject);
    procedure HandleSetDataBreakpoints(Seq: Integer; Args: TJSONObject);
    // dataId <-> what it names. The id is adapter-private and round-trips
    // through the client (VS Code even persists it between sessions), so it
    // carries everything needed to re-derive the target -- and, for a
    // frame-scoped local, the session nonce that makes a stale one refusable.
    function  EncodeDataId(const Info: TDataBpTargetInfo): string;
    function  DecodeDataId(const DataId: string; out Spec: TDataBpSpec;
                out Error: string): Boolean;
    // Stable numeric DAP breakpoint id per dataId, for the `breakpoint` event.
    function  DataBpIdFor(const DataId: string): Integer;
    // The session retired a frame-scoped watchpoint because its frame exited.
    procedure SessionDataBreakpointRemoved(const Bp: TSessionDataBreakpoint;
                const Reason: string);
    procedure HandleContinue(Seq: Integer; Args: TJSONObject);
    function  StepThreadFromArgs(Args: TJSONObject): DWORD;
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 2: true only for the exact string
    // "instruction". Absent, or any other value (VS Code also sends "line" and
    // "statement"), takes the unchanged source-level path -- see
    // docs/DAP_DEBUGGER_ARCHITECTURE.md "Instruction granularity (DAP)".
    function  WantsInstructionGranularity(Args: TJSONObject): Boolean;
    // Shared by next/stepIn/stepOut when granularity="instruction". The
    // engine's decision phase (TDebugSession.StepInstruction) is synchronous
    // and runs on THIS thread -- the DAP request-processing thread, the same
    // one HandleStackTrace already calls dbghelp from -- so a refusal is known
    // BEFORE any response is sent: the request fails with success=false and
    // the reason, never a silent no-op and never a quiet fallback to a
    // source-level step.
    procedure HandleInstructionStep(Seq: Integer; const Cmd: string;
                Kind: TInstructionStepKind; Args: TJSONObject);
    // Shared body of next / stepIn / stepOut at source granularity. Kept in one
    // place because the response ORDERING differs by stop kind, and three copies
    // of that rule is exactly how one of them goes stale.
    procedure HandleSourceStep(Seq: Integer; const Cmd: string;
                Kind: TInstructionStepKind; Args: TJSONObject);
    procedure HandleNext(Seq: Integer; Args: TJSONObject);
    procedure HandleStepIn(Seq: Integer; Args: TJSONObject);
    procedure HandleStepOut(Seq: Integer; Args: TJSONObject);
    procedure HandlePause(Seq: Integer; Args: TJSONObject);
    procedure HandleStackTrace(Seq: Integer; Args: TJSONObject);
    // docs/DISASSEMBLY_PLAN.md increment 6: DAP `disassemble`, what makes the
    // Disassembly View work. Reuses the exact same IDisassembler/Zydis
    // pipeline the MCP `disassemble` tool already uses, and the SAME
    // proven-boundary-only backward-decode mechanism (Disassembler
    // .DisassembleBackward / IDebugTarget.NearestInstructionBoundaryBefore /
    // NearestExportedEntryBefore) established in increment 4 -- see
    // "Decision: backward disassembly is proven-boundary-only" in
    // docs/DISASSEMBLY_PLAN.md.
    procedure HandleDisassemble(Seq: Integer; Args: TJSONObject);
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3: `readMemory`/`writeMemory`.
    // Thin surface over the engine primitives MCP's read_memory/write_memory
    // already use -- see the implementation comments for the base64/
    // unreadableBytes/allowPartial contract.
    procedure HandleReadMemory(Seq: Integer; Args: TJSONObject);
    procedure HandleWriteMemory(Seq: Integer; Args: TJSONObject);
    // DAP `modules`: which images are loaded, and what the debugger knows about
    // each. The question it answers -- "does THIS module have symbols, and from
    // which file" -- has no other answer today short of reading the diagnostic
    // log, and on a multi-package application it is the first thing anyone asks
    // when a breakpoint stays unverified.
    procedure HandleModules(Seq: Integer; Args: TJSONObject);
    // Tells a client the module table changed, so a view of it can refresh
    // without waiting for the next stop -- a package loaded while the target is
    // RUNNING is exactly the case worth watching. Custom: DAP's own `module`
    // event describes one module at a time and would need per-module bookkeeping
    // to stay accurate across reloads; this says only "ask again".
    procedure EmitModulesChanged;
    // Remembers a span the client actually read, widening the entry it already
    // has for that memoryReference (FMemoryViews).
    procedure TrackMemoryView(const MemRef: string; Offset, Count: Int64);
    // Records what a reference refers to, at the moment it is handed out.
    procedure RememberMemoryExtent(const MemRef: string; Address, Size: UInt64;
                const Name, TypeName: string);
    // Custom request `delphiMemoryExtent`: answers what a reference refers to,
    // for the extension's memory view. Deliberately NOT part of the DAP surface
    // -- no standard request carries a value's byte extent.
    procedure HandleMemoryExtent(Seq: Integer; Args: TJSONObject);
    // Custom requests `delphiSafelistAdd` / `delphiSafelistRemove` /
    // `delphiSafelistReload`: the safe-getter user file, written through the
    // adapter because the adapter owns the paths and the reload. After a
    // mutation an `invalidated(variables)` follows, so the panel re-renders
    // with the row now evaluated (or deferred again) without waiting for the
    // next stop.
    procedure HandleSafelist(Seq: Integer; const Cmd: string; Args: TJSONObject);
    // Tells the client every tracked view may have changed. Called wherever the
    // debuggee's memory can have moved under an open pane: at each stop, and
    // after a write this adapter itself performed.
    procedure EmitMemoryChanged;
    // A slot this backend actually decoded: real bytes, real text, and
    // symbol/source location when a provider knows one.
    function  BuildDapInstruction(const Ins: TDisasmInstruction;
                ResolveSymbols: Boolean): TJSONObject;
    // A slot nothing could prove (an unproven backward span, or a forward
    // read that ran off mapped memory): `presentationHint: 'invalid'`, the
    // DAP spec's own mechanism for "filler, not reachable code"
    // (DisassembleArguments.instructionCount requires EXACTLY instructionCount
    // entries back; this is how the ones that cannot be decoded are padded).
    // Addr is a synthetic filler address, never a proven instruction start.
    function  BuildInvalidDapInstruction(Addr: UInt64): TJSONObject;
    // Placeholder document for a frame the providers could not give source for.
    procedure HandleSource(Seq: Integer; Args: TJSONObject);
    function  SyntheticSourceText(const F: TSessionFrame): string;
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 5: the disassembly section of that
    // document -- real decode around the frame's PC, not prose, using the same
    // mechanism HandleDisassemble uses. Falls back to naming the real reason
    // when the Zydis backend is unavailable; never blank.
    // AnyLineShown reports whether at least one listed instruction carried a
    // source line, so the trailing note can talk about line numbers only when
    // there are some. On a module with no line information at all that sentence
    // is pure noise beside a listing that shows none.
    function  BuildPlaceholderDisassembly(const F: TSessionFrame;
                out AnyLineShown: Boolean): string;
    function  FormatPlaceholderInstruction(const Ins: TDisasmInstruction;
                CurrentVA: UInt64): string;
    function  SyntheticSourceRef(const ALabel: string; const F: TSessionFrame): Integer;
    procedure AttachPlaceholderSource(FO: TJSONObject; const F: TSessionFrame;
                const ALabel: string);
    procedure HandleScopes(Seq: Integer; Args: TJSONObject);
    procedure HandleVariables(Seq: Integer; Args: TJSONObject);
    procedure HandleEvaluate(Seq: Integer; Args: TJSONObject);
    procedure HandleSetVariable(Seq: Integer; Args: TJSONObject);
    procedure HandleDisconnect(Seq: Integer);
    procedure HandleThreads(Seq: Integer);
    procedure HandleGotoTargets(Seq: Integer; Args: TJSONObject);
    procedure HandleGoto(Seq: Integer; Args: TJSONObject);
    procedure ProcessRequest(Msg: TJSONObject);
    // Private read accessors onto the session's single owned instances. The DAP
    // layer neither constructs nor frees any of these; there is exactly ONE of each.
    function  FDebugger: IDebugTarget;
    function  FDebugInfo: TDebugInfoSet;
    function  FLoader: TModuleSymbolLoader;
    function  FExpander: TVariableExpander;
    function  FRtti: TDelphiRtti;
    function  FSourceResolver: TSourceResolver;
    // TDebugSession event subscribers (the DAP-only halves of the old engine
    // callbacks). The neutral halves run inside the session's own Handle* methods.
    procedure OnSessionStopped(const Info: TStopInfo);
    procedure OnSessionExited(ExitCode: Integer);
    procedure OnSessionOutput(Kind: TOutputKind; const Text: string);
    procedure SendOutputEvent(const Text, Category: string);
    // Says so in the Debug Console when a stop has no source anywhere on the
    // stack -- the one case where the client may show nothing at all.
    procedure AnnounceSourcelessStop(const Info: TStopInfo);
    // OnDllLoadedHook subscriber: the DAP-side PACKAGEINFO-gated eager BP-probe,
    // stale-sidecar warnings, startup progress and background enqueue. The session
    // has already registered the module record before firing this.
    procedure SessionDllLoaded(const Name, Path: string; Base, ImageSize: UInt64);
    // OnBreakpointChanged subscriber: the SINGLE gutter re-colour path. Emits the
    // DAP `breakpoint` changed event when the session flips a line to verified.
    procedure SessionBreakpointChanged(const SourceFile: string; Line: Integer;
                Verified: Boolean);
    // The prefetcher registered a module's providers while the target is stopped:
    // a stack the client already drew may now have names it did not have. DAP has
    // an event for exactly this -- ask the client to re-fetch instead of leaving
    // stale nameless frames on screen until the user steps.
    procedure SessionSymbolsArrived(Sender: TObject);
    // FLoader hooks: config-retry predicate + PACKAGEINFO requires supplier + logs.
    function  LoaderShouldRetry(const AName: string): Boolean;
    function  LoaderRequiresFor(Module: TModuleSymbols): TArray<string>;
    procedure LoaderLog(const Msg: string);
    procedure LoaderConsole(const Msg: string);
    // DLL symbol helpers
    function  ModuleIsConfigured(const ModuleName: string): Boolean;
    function  FindLiveModule(const AName: string; ABase: UInt64): TDllModule;
    // Loads the symbol providers of every package the frame-binary at PC
    // `requires` (transitively). Without this, a global declared in a required
    // package that the debuggee never STOPPED in is not loaded, so the
    // uses-graph global tier has nothing to resolve and an unrelated module's
    // same-named global wins. Bounded by the frame-binary's requires-closure
    // (small for a BPL), and EnsureDll* is idempotent.
    procedure WarmupRequiresClosureForPC(PC: UInt64);
    // Loads ONLY the modules of the frame's identifier-visibility scope (its unit
    // + the units it directly `uses`), for a bare-identifier watch. Bounded to the
    // Delphi scope instead of a brute-force sweep of every loaded module. Returns
    // True when the scope was known (so a still-missing identifier is genuinely
    // out of scope -> reject); False when there is no uses graph (caller falls
    // back to the un-scoped warm-up).
    function  WarmupUsesScopeForFrame(FrameRva: UInt64): Boolean;
    // Emits a DAP `breakpoint` changed event so VS Code re-colours a gutter marker
    // -- grey to solid when the owning module's symbols arrive, and solid back to
    // grey when that module unloads. Driven only by SessionBreakpointChanged (the
    // session's OnBreakpointChanged) -- the single re-colour path.
    procedure SendBreakpointChanged(Id, Line: Integer;
                const SourceName, SourcePath: string; Verified: Boolean);
    function  FindSourceFile(const Name: string): string;
    function  ResolveSourcePath(const BaseName: string): string;
    function  ResolveUnitToSource(const UnitName: string): string;
    function  TrySyntheticUnitSource(const FuncName: string;
                out FullPath: string; out Line: Integer): Boolean;
    // Parse launch.json into the neutral session option records + the DAP-side
    // config fields the introspection handlers still read (FExePath / FModulesConfig
    // / source roots). Does NOT load symbols or configure the resolver -- the session
    // does both inside Launch/Attach.
    procedure ParseSourceAndModules(Args: TJSONObject; const ProgramPath: string);
    function  SessionModules: TArray<TSessionModuleConfig>;
    // Capture exception-rule config (the whole precedence chain plus its
    // hot-reload state) and return the combined table for the launch/attach
    // options.
    function  ApplyExceptionRules(Args: TJSONObject): TArray<TExceptionRule>;
    function  ResolveDelphiProjectFile(Args: TJSONObject): string;
    procedure AddFileRuleTier(const Path, Description: string);
    function  CombinedExceptionRules: TArray<TExceptionRule>;
    procedure ReloadExceptionRuleFilesIfChanged;
    // Value formatting (FormatLocalValue / FormatLocalType / Variant + string
    // decode / SlotSizeAt) moved to DelphiValueReaders (TDelphiValueReader).
    // `Readers` lazily creates it and refreshes its Debugger/Rtti refs from
    // the current session on each access.
    function  Readers: TDelphiValueReader;
    // Push the current session references into the shared expander. Called on
    // every stop and at the top of each variable-facing handler, so the engine
    // always sees the live Debugger / DebugInfo / TD32 / Rtti / value reader.
    procedure SyncExpander;
    // Map an opaque expander handle to a stable per-stop DAP variablesReference
    // (0 stays 0). Reuses an existing mapping so a handle always yields one ref.
    function  RefForHandle(H: TVarHandle): Integer;
    // Serialise one neutral variable row into the DAP `variables` array. A
    // vkGroup row renders as a virtual grouping node (no type); everything else
    // carries value + type; the child ref comes from RefForHandle(V.Handle).
    procedure EmitVar(Arr: TJSONArray; const V: TSessionVariable);
    function  BuildCurrentExceptionRef(out ValueStr, ClassName: string;
                out VarRef: Integer; out ObjAddr: UInt64;
                out HandlerKind: TExcHandlerBlockKind;
                out Reason: string): Boolean;
    procedure AppendExceptionLocal(Arr: TJSONArray);
  public
    constructor Create;
    destructor  Destroy; override;
    procedure   Run;
  end;

{ TDapServer }

constructor TDapServer.Create;
begin
  inherited;
  // The default belongs HERE, not in the launch parse. Diagnostics start before
  // any launch arrives -- `initialize done` is the first line the adapter ever
  // writes -- and a field left at its zero value routed those early lines to
  // the Debug Console, which is exactly where they were not wanted. The launch
  // config can still turn it off; it can no longer be the thing that turns it
  // ON.
  FDiagnosticsToOutputChannel := True;
  FIO         := TDapIO.Create;
  // The session owns the engine + all symbol/expansion machinery. Configure its
  // loader with the DAP-side enriched module class + PACKAGEINFO hooks + log sinks
  // BEFORE any launch, and subscribe to the session's async + module events.
  FSession    := TDebugSession.Create;
  FSession.Loader.ModuleClass       := TDllModule;   // registry instantiates the enriched record
  FSession.Loader.ShouldRetryModule := LoaderShouldRetry;  // configured modules always retry
  FSession.Loader.RequiresFor       := LoaderRequiresFor;  // PACKAGEINFO requires (uses-graph)
  FSession.Loader.OnLog             := LoaderLog;           // diagnostic -> DapLog
  FSession.Loader.OnConsole         := LoaderConsole;       // user-facing -> SendConsoleLog
  FSession.Loader.OnModuleLoadBegin := LoaderModuleLoadBegin; // progress -> busy title
  FSession.OnSessionStopped          := OnSessionStopped;
  FSession.OnSessionExited           := OnSessionExited;
  FSession.OnSessionOutput           := OnSessionOutput;
  FSession.OnDllLoadedHook           := SessionDllLoaded;
  FSession.OnBreakpointChanged       := SessionBreakpointChanged;
  FSession.OnDataBreakpointRemoved   := SessionDataBreakpointRemoved;
  FSession.OnSymbolsArrivedWhileStopped := SessionSymbolsArrived;
  FBpIds        := TDictionary<string, Integer>.Create;
  FBpSourcePath := TDictionary<string, string>.Create;
  FNextBpId     := 1;
  FDataBpIds    := TDictionary<string, Integer>.Create;
  FNextDataBpId := 10000;   // kept clear of the source-breakpoint id space
  // Identity of THIS adapter run, stamped into every frame-scoped dataId. VS
  // Code persists data breakpoints in workspace state and re-sends them at the
  // next launch; a stack frame from a dead process must be refused by name, not
  // re-armed at whatever now lives at that address.
  FDataBpNonce  := Format('%x%x', [GetCurrentProcessId, GetTickCount64]);
  FRefToHandle := TDictionary<Integer, TVarHandle>.Create;
  FHandleToRef := TDictionary<TVarHandle, Integer>.Create;
  // Keyed by the reference STRING exactly as it went out on the wire, so the
  // lookup cannot disagree with what the client sends back.
  FMemoryExtents := TDictionary<string, TMemoryExtent>.Create;
  FEvalMissCache   := TDictionary<string, string>.Create;
  FSynthSourceRefs    := TDictionary<string, Integer>.Create;
  FSynthSourceTexts   := TDictionary<Integer, string>.Create;
  FNextSynthSourceRef := 1;   // 0 means "use the path", so references start at 1
  FNextExpRef := EXPANSION_REF_BASE;
  FAdapterStartTick := GetTickCount64;
  // Status bar is the default rendering location; launch/attach may override it.
  FProgressAsCustomEvent := True;

  // Busy-spinner watchdog: closes the 'op' progress once the adapter has been
  // idle (no MarkBusy) for ~400ms, so the spinner spans a step + its post-stop
  // request burst without flickering and disappears when the user can act.
  InitializeCriticalSection(FOpLock);
  FWatchdogStop := False;
  FWatchdog := TThread.CreateAnonymousThread(
    procedure
    begin
      while not FWatchdogStop do begin
        Sleep(80);
        EnterCriticalSection(FOpLock);
        try
          var NowMs := GetTickCount64;
          var Busy := FBusyArmed and
            (FStepPending or FProcessing or (NowMs - FLastBusyTick <= 400));
          // Startup progress normally ends at the first stop. An ATTACH to an
          // application that just keeps running never reaches one, so close it
          // when configuration is done and module loading has been quiet for a
          // while: at that point everything the indicator was reporting has
          // happened. Left as it was, it claimed to be loading modules for the
          // entire session.
          if FStartupActive and FConfigDone and (FLastDllTick <> 0) and
             (NowMs - FLastDllTick > 1000) then begin
            var Summary := Format('Ready -- %d modules loaded (%d with symbols) in %dms',
              [FStartupDllCount, FStartupMapCount, FLastDllTick - FStartupTick]);
            SendProgressEnd(Summary);
            SendConsoleLog('[DONE] ' + Summary);
          end;

          if FBusyArmed and not Busy then begin
            // Busy period ended: hide the spinner if it was shown.
            FBusyArmed := False;
            if FOpProgressActive then SendOpProgressEnd;
          end
          else if Busy and not FOpProgressActive and (NowMs - FBusySince > 200) then
            // Still busy past the debounce window -> now worth showing. 200ms is
            // below the "feels frozen" threshold yet above instant ops, so the
            // spinner appears on any noticeable stall without flickering on fast ones.
            SendOpProgressStart(FOpBusyTitle);
        finally
          LeaveCriticalSection(FOpLock);
        end;
      end;
    end);
  FWatchdog.FreeOnTerminate := False;
  FWatchdog.Start;
end;

function TDapServer.Readers: TDelphiValueReader;
begin
  Result := FSession.GetReaders;
end;

// --- Read accessors onto the session's single owned instances ---------------
function TDapServer.FDebugger: IDebugTarget;
begin
  Result := FSession.Debugger;
end;

function TDapServer.FDebugInfo: TDebugInfoSet;
begin
  Result := FSession.DebugInfo;
end;

function TDapServer.FLoader: TModuleSymbolLoader;
begin
  Result := FSession.Loader;
end;

function TDapServer.FExpander: TVariableExpander;
begin
  Result := FSession.Expander;
end;

function TDapServer.FRtti: TDelphiRtti;
begin
  Result := FSession.Rtti;
end;

function TDapServer.FSourceResolver: TSourceResolver;
begin
  Result := FSession.SourceResolver;
end;

destructor TDapServer.Destroy;
begin
  // The symbol prefetcher lives inside TModuleSymbolLoader now and is joined by
  // its destructor, which the session's destructor runs before freeing
  // FDebugInfo -- so there is nothing to stop here.
  if FWatchdog <> nil then begin
    FWatchdogStop := True;
    FWatchdog.WaitFor;
    FWatchdog.Free;
    DeleteCriticalSection(FOpLock);
  end;
  // The session's destructor tears down the engine and frees Loader-before-DebugInfo
  // in the correct order; the DAP layer owns and frees NONE of those directly.
  FSession.Free;
  FRefToHandle.Free;
  FHandleToRef.Free;
  FMemoryExtents.Free;
  FEvalMissCache.Free;
  FSynthSourceRefs.Free;
  FSynthSourceTexts.Free;
  FBpIds.Free;
  FDataBpIds.Free;
  FBpSourcePath.Free;
  FIO.Free;
  inherited;
end;

{ TDllModule }

destructor TDllModule.Destroy;
begin
  FIndex.Free;
  FPackageUnits.Free;
  inherited;
end;

function TDllModule.ContainsUnitByPackageInfo(const UnitName: string): Boolean;

  function ReadAnsiZLen(P, PEnd: PByte; out Len: Integer): Boolean;
  begin
    Len := 0;
    while (P + Len) < PEnd do begin
      if PByte(P + Len)^ = 0 then
        Exit(True);
      Inc(Len);
    end;
    Result := False;
  end;

type
  PPackageInfoHeader = ^TPackageInfoHeader;
  TPackageInfoHeader = packed record
    Flags: Cardinal;
    RequiresCount: Integer;
  end;

var
  ModuleHandle: HMODULE;
  ResInfo: HRSRC;
  ResData: HGLOBAL;
  Cur, Stop: PByte;
  Header: PPackageInfoHeader;
begin
  if FPackageUnitsLoaded then begin
    Result := (FPackageUnits <> nil) and FPackageUnits.ContainsKey(UnitName);
    Exit;
  end;

  FPackageUnitsLoaded := True;
  Result := False;

  if (FullPath = '') or not FileExists(FullPath) then
    Exit;

  ModuleHandle := LoadLibraryEx(PChar(FullPath), 0, LOAD_LIBRARY_AS_DATAFILE);
  if ModuleHandle = 0 then
    Exit;
  try
    ResInfo := FindResource(ModuleHandle, 'PACKAGEINFO', RT_RCDATA);
    if ResInfo = 0 then
      Exit;
    ResData := LoadResource(ModuleHandle, ResInfo);
    if ResData = 0 then
      Exit;

    Cur := LockResource(ResData);
    if Cur = nil then
      Exit;
    Stop := Cur + SizeofResource(ModuleHandle, ResInfo);
    if Stop <= Cur then
      Exit;
    if (Stop - Cur) < SizeOf(TPackageInfoHeader) then
      Exit;

    if FPackageUnits = nil then
      FPackageUnits := TDictionary<string, Boolean>.Create
    else
      FPackageUnits.Clear;

    Header := PPackageInfoHeader(Cur);
    Inc(Cur, SizeOf(TPackageInfoHeader));

    if Header.RequiresCount < 0 then
      Exit;

    // Required-package name list: Flags(1) + AnsiZ name, one per requirement.
    // Capture the base names (lowercase) for the uses-graph global tier.
    FRequiredPackages := nil;
    for var I := 0 to Header.RequiresCount - 1 do begin
      if Cur + 2 > Stop then
        Exit;
      var NameLen := 0;
      if not ReadAnsiZLen(Cur + 1, Stop, NameLen) then
        Exit;
      if NameLen > 0 then begin
        var ReqName: AnsiString;
        SetString(ReqName, PAnsiChar(Cur + 1), NameLen);
        // PACKAGEINFO stores requires as the BPL filename (e.g. 'rtl290.bpl');
        // strip the extension to match the extension-less ModuleName used by
        // the ranged-global providers.
        FRequiredPackages := FRequiredPackages +
          [LowerCase(ChangeFileExt(string(ReqName), ''))];
      end;
      Inc(Cur, NameLen + 2);
    end;

    if Cur + SizeOf(Integer) > Stop then
      Exit;
    var ContainsCount := PInteger(Cur)^;
    if ContainsCount < 0 then
      Exit;
    Inc(Cur, SizeOf(Integer));

    // Unit entries: Flags(1) + Hash(1) + UTF8 unit name + #0.
    for var I := 0 to ContainsCount - 1 do begin
      if Cur + 3 > Stop then
        Exit;
      var NameLen := 0;
      if not ReadAnsiZLen(Cur + 2, Stop, NameLen) then
        Exit;

      var Utf8Unit: UTF8String;
      SetString(Utf8Unit, PAnsiChar(Cur + 2), NameLen);
      var FullUnit := LowerCase(UTF8ToString(Utf8Unit));
      if FullUnit <> '' then begin
        FPackageUnits.AddOrSetValue(FullUnit, True);
        var DotPos := LastDelimiter('.', FullUnit);
        if DotPos > 0 then
          FPackageUnits.AddOrSetValue(Copy(FullUnit, DotPos + 1, MaxInt), True);
      end;

      Inc(Cur, NameLen + 3);
    end;
  finally
    FreeLibrary(ModuleHandle);
  end;

  Result := (FPackageUnits <> nil) and FPackageUnits.ContainsKey(UnitName);
end;

function TDllModule.RequiredPackages: TArray<string>;
begin
  // PACKAGEINFO is parsed once, lazily, by ContainsUnitByPackageInfo; trigger
  // it (the '' unit never matches) so FRequiredPackages is populated.
  if not FPackageUnitsLoaded then
    ContainsUnitByPackageInfo('');
  Result := FRequiredPackages;
end;

function TDllModule.ContainsSourceFile(const FileName: string): Boolean;
begin
  var IsBpl := SameText(ExtractFileExt(Name), '.bpl');
  if IsBpl then begin
    var UnitName := LowerCase(ChangeFileExt(ExtractFileName(FileName), ''));
    if ContainsUnitByPackageInfo(UnitName) then
      Exit(True);
    // For Delphi packages, PACKAGEINFO is authoritative. If the unit isn't
    // listed there (or PACKAGEINFO can't be read), this module is not treated
    // as a candidate. No MAP fallback for BPLs.
    if FPackageUnitsLoaded then
      Exit(False);
  end;

  // Non-BPL fallback path: MAP sidecar index first, then TD32 source list.
  if (MapPath <> '') and FileExists(MapPath) then begin
    if FIndex = nil then
      FIndex := TMapSourceIndex.Create(MapPath);
    Result := FIndex.ContainsFile(FileName);
    if Result then Exit;
  end;
  if (FullPath = '') or not FileExists(FullPath) then
    Exit(False);
  // Quick TD32 source-file scan. Reuses TTD32FileReader but discards
  // the reader after the lookup -- the real BPL TD32 provider gets
  // re-created via EnsureDllTD32 once a BP source match is confirmed.
  Result := False;
  var R := TTD32FileReader.Create;
  try
    try
      R.LoadFromFile(FullPath);
    except
      Exit(False);
    end;
    var Target := AnsiLowerCase(ExtractFileName(FileName));
    for var Src in R.GetSourceFiles do
      if Src = Target then begin
        Result := True;
        Break;
      end;
  finally
    R.Free;
  end;
end;

{ TDapServer -- DLL module helpers }

{ TDapServer -- startup progress }

// `progressLocation` (launch/attach config): "statusBar" (default) or
// "notification". Anything unrecognised falls back to the default rather than
// silently disabling progress.
procedure TDapServer.ParseProgressLocation(Args: TJSONObject);
begin
  var Loc := Trim(Args.GetValue<string>('progressLocation', ''));
  FProgressAsCustomEvent := not SameText(Loc, 'notification');
  if FProgressAsCustomEvent then
    DapLog('progressLocation = statusBar (delphiProgress custom events)')
  else
    DapLog('progressLocation = notification (standard DAP progress events)');
end;

// Prefixes the displayed name of a raw-sweep frame, and leaves a walked frame
// untouched. `[raw]` means the instruction ending at that address was DECODED
// as a call; `[raw?]` means there was no line table to decode from, so the hit
// rests on the address being executable code and nothing more. Neither says the
// frame is LIVE -- a call that has already returned leaves its return address
// behind, and no sweep can tell the difference.
function TDapServer.RawStackLabel(const F: TSessionFrame;
  const Name: string): string;
begin
  case F.Origin of
    foRawProven:   Result := '[raw] '  + Name;
    foRawUnproven: Result := '[raw?] ' + Name;
  else
    Result := Name;
  end;
end;

procedure TDapServer.ParseRawStackScan(Args: TJSONObject);
begin
  FRawStackScan := (Args <> nil) and Args.GetValue<Boolean>('rawStackScan', False);
  if FRawStackScan then
    DapLog('rawStackScan = ON (raw sweep appended below the walked frames)');

  // `noSourcePlaceholder` in launch.json, default TRUE. Setting it to false
  // attaches NO source to a sourceless frame, which is the only way to observe
  // what the client does when left to itself -- the adapter cannot open a
  // Disassembly View, since DAP has no request for it, so "our document versus
  // the client's own handling" is not a choice the adapter can make, only one
  // it can get out of the way of. Kept as a switch rather than a decision
  // because the answer differs per editor and has never been measured.
  FNoSourcePlaceholder := (Args = nil) or
    Args.GetValue<Boolean>('noSourcePlaceholder', True);
  if not FNoSourcePlaceholder then
    DapLog('noSourcePlaceholder = OFF (sourceless frames get no source at all)');
end;

// Flips the raw stack sweep mid-session, for the Call Stack title-bar toggle.
// The launch flag alone meant editing launch.json and restarting -- backwards
// for something reached for exactly when a stack has just come up short.
//
// The reply carries the resulting state so the button can label itself from
// what the adapter actually did rather than from what the client assumed, and
// an `invalidated` event follows: VS Code caches the call stack and will not
// re-request it because a setting changed, so without this the toggle appears
// to do nothing until the next step.
procedure TDapServer.HandleSetRawStackScan(Seq: Integer; Args: TJSONObject);
begin
  var Enabled := FRawStackScan;
  if Args <> nil then begin
    if Args.GetValue('enabled') <> nil then
      Enabled := Args.GetValue<Boolean>('enabled', Enabled)
    else
      Enabled := not FRawStackScan;   // no argument = toggle
  end
  else
    Enabled := not FRawStackScan;
  FRawStackScan := Enabled;
  DapLog(Format('delphiSetRawStackScan -> %s', [BoolToStr(FRawStackScan, True)]));

  var Body := TJSONObject.Create;
  try
    Body.AddPair('enabled', TJSONBool.Create(FRawStackScan));
    FIO.SendResponse(Seq, 'delphiSetRawStackScan', True, Body);
  finally
    Body.Free;
  end;

  // Only meaningful while stopped; a running target has no stack to redraw.
  if FClientSupportsInvalidated and (FSession.State = dsStopped) then begin
    var Inv := TJSONObject.Create;
    try
      Inv.AddPair('areas', TJSONArray.Create(TJSONString.Create('stacks')));
      FIO.SendEvent('invalidated', Inv);
    finally
      Inv.Free;
    end;
  end;
end;

procedure TDapServer.ParseDiagnosticsLocation(Args: TJSONObject);
begin
  // Default: the output channel. The extension is always loaded when this debug
  // type runs (it is the manifest's `main`), so the custom event always has a
  // listener. `debugConsole` is the escape hatch for a bare DAP client.
  var Loc := '';
  if Args <> nil then
    Loc := Trim(Args.GetValue<string>('diagnosticsLocation', ''));
  FDiagnosticsToOutputChannel := not SameText(Loc, 'debugConsole');
  if FDiagnosticsToOutputChannel then
    DapLog('diagnosticsLocation = outputChannel ("Delphi Debugger" via delphiLog events)')
  else
    DapLog('diagnosticsLocation = debugConsole');
end;

// Every progress moment of every channel goes through here. The busy/debounce
// logic upstream is unaware of the wire format: it calls the same Send* helpers
// in both modes, and only this routine decides which events go out.
procedure TDapServer.EmitProgress(const AId, AState, AText: string);
var
  Body: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    if FProgressAsCustomEvent then begin
      // Custom event contract (rendered by our extension in the status bar):
      //   { "id": string, "state": "start"|"update"|"end", "text": string }
      // `text` is omitted on "end" -- nothing is left to display at that point.
      Body.AddPair('id',    AId);
      Body.AddPair('state', AState);
      if AState <> 'end' then
        Body.AddPair('text', AText);
      FIO.SendEvent('delphiProgress', Body);
      Exit;
    end;
    Body.AddPair('progressId', AId);
    if AState = 'start' then begin
      Body.AddPair('title',       AText);
      Body.AddPair('cancellable', TJSONBool.Create(False));
      FIO.SendEvent('progressStart', Body);
    end
    else if AState = 'update' then begin
      Body.AddPair('message', AText);
      FIO.SendEvent('progressUpdate', Body);
    end
    else begin
      if AText <> '' then
        Body.AddPair('message', AText);
      FIO.SendEvent('progressEnd', Body);
    end;
  finally
    Body.Free;
  end;
end;

procedure TDapServer.SendProgressStart(const AMsg: string);
begin
  EmitProgress('startup', 'start', AMsg);
  FStartupActive := True;
end;

procedure TDapServer.SendProgressUpdate(const AMsg: string);
begin
  if not FStartupActive then
    Exit;
  EmitProgress('startup', 'update', AMsg);
end;

procedure TDapServer.SendProgressEnd(const AMsg: string);
begin
  if not FStartupActive then
    Exit;
  FStartupActive := False;
  EmitProgress('startup', 'end', AMsg);
end;

procedure TDapServer.SendOpProgressStart(const ATitle: string);
begin
  if FOpProgressActive then Exit;
  FOpProgressActive := True;
  EmitProgress('op', 'start', ATitle);
end;

procedure TDapServer.SendOpProgressEnd;
begin
  if not FOpProgressActive then Exit;
  FOpProgressActive := False;
  EmitProgress('op', 'end', '');
end;

procedure TDapServer.MarkBusy(const ATitle: string; StepPending: Boolean);
begin
  EnterCriticalSection(FOpLock);
  try
    FStepPending  := StepPending;
    FLastBusyTick := GetTickCount64;
    // Arm a new busy period (debounce START -- the watchdog shows the spinner
    // only if this period lasts > ~200ms, so fast steps never pop a toast). The
    // title is taken from whatever started the period.
    if not FBusyArmed then begin
      FBusyArmed   := True;
      FBusySince   := FLastBusyTick;
      FOpBusyTitle := ATitle;
    end;
  finally
    LeaveCriticalSection(FOpLock);
  end;
end;

// Retitles the busy period already in flight. It deliberately does NOT arm one:
// a title with nothing running has nothing to describe, and arming here would
// make an idle background load pop a spinner of its own.
procedure TDapServer.UpdateBusyTitle(const ATitle: string);
begin
  EnterCriticalSection(FOpLock);
  try
    if not FBusyArmed then
      Exit;
    FLastBusyTick := GetTickCount64;
    FOpBusyTitle  := ATitle;
    // Already visible -> push the new text. Not yet visible -> the watchdog picks
    // FOpBusyTitle up when the debounce expires, so no event is needed.
    if FOpProgressActive then
      EmitProgress('op', 'update', ATitle);
  finally
    LeaveCriticalSection(FOpLock);
  end;
end;

// The loader is about to parse a module's symbols. On a stop landing in fresh
// modules this is the bulk of the wait (~14 ms/MB; ~100 ms for a typical package
// and up to ~650 ms for the largest, summed over the distinct modules on the
// stack), so name the module instead of leaving the generic "building call
// stack..." to read as if stack building itself were slow.
procedure TDapServer.LoaderModuleLoadBegin(const ADisplayName: string);
begin
  if ADisplayName = '' then
    Exit;
  UpdateBusyTitle('Delphi debugger: loading symbols: ' + ADisplayName);
end;

// Every adapter-authored line -- symbol loading, `launch:`, `setBreakpoints
// #N`, `configurationDone`, the loader's module notices -- goes through here,
// and all of it is DIAGNOSTICS. So it routes with the rest of the diagnostics
// rather than straight to the Debug Console.
//
// This was the path the first attempt at the split MISSED. `OnSessionOutput`
// was changed and the job declared done, but that function is not the only
// emitter: these fourteen call sites wrote `output`/`console` directly, which
// is why the console still looked exactly the same afterwards.
procedure TDapServer.SendConsoleLog(const AMsg: string);
begin
  SendDiagnosticEvent(AMsg);
end;

// Latched + idempotent: delegates to the shared loader (which retains the main
// paths captured at LoadMainModule and does the disabled/stale/exists gating).
// Called eagerly at launch (inside LoadMainModule) and lazily before the first
// variable inspection.
procedure TDapServer.EnsureMainRsm;
begin
  FLoader.EnsureMainRsm;
end;

// TDebugSession.OnBreakpointChanged subscriber -- the SINGLE gutter re-colour path.
// The session fires this from RepostBreakpoints/NotifyBreakpointFlips whenever a
// stored spec's line changes verified state: up when a runtime module's symbols
// load, DOWN when that module unloads. Look up the numeric id we handed VS Code
// for that 'file|line' and emit the DAP `breakpoint` changed event, so the marker
// follows in both directions rather than only going grey -> solid.
procedure TDapServer.SessionBreakpointChanged(const SourceFile: string;
  Line: Integer; Verified: Boolean);
begin
  var Base := LowerCase(ExtractFileName(SourceFile));
  var Key  := Base + '|' + IntToStr(Line);
  var Id: Integer;
  if not FBpIds.TryGetValue(Key, Id) then
    Exit;
  var FullPath := '';
  FBpSourcePath.TryGetValue(Base, FullPath);
  SendBreakpointChanged(Id, Line, ExtractFileName(SourceFile), FullPath, Verified);
  // Losing a breakpoint is worth saying out loud. The marker turning grey is
  // easy to miss in a gutter the user is not looking at, and the effect --
  // execution running straight past a line they set a breakpoint on -- is
  // otherwise indistinguishable from the line never being reached.
  if not Verified then
    SendConsoleLog(Format('[BP] %s:%d is no longer bound -- the module that ' +
      'owns this source is not loaded', [ExtractFileName(SourceFile), Line]));
end;

procedure TDapServer.SessionSymbolsArrived(Sender: TObject);
begin
  // A module that had no symbols a moment ago may have them now, which changes
  // what a modules view should be showing -- and unlike the stack redraw below,
  // that is worth saying whether or not a stack has been served yet.
  EmitModulesChanged;
  if FLastStackTid = 0 then
    Exit;   // no stack has been served yet: nothing on screen to invalidate
  var Body := TJSONObject.Create;
  try
    Body.AddPair('areas', TJSONArray.Create(TJSONString.Create('stacks')));
    Body.AddPair('threadId', TJSONNumber.Create(Int64(FLastStackTid)));
    FIO.SendEvent('invalidated', Body);
  finally
    Body.Free;
  end;
  DapLog('invalidated(stacks): background symbol load registered new providers');
end;

// FLoader.ShouldRetryModule: a launch-configured module must be re-probed even
// after a *Tried flag is set (its first probe can fail transiently -- config not
// yet matched / a relocation instance). Configured modules are few, so retrying
// is cheap; the negative cache still stops the System-DLL storm.
function TDapServer.LoaderShouldRetry(const AName: string): Boolean;
begin
  Result := ModuleIsConfigured(AName);
end;

// FLoader.RequiresFor: the module's PACKAGEINFO requires (uses-graph global tier).
function TDapServer.LoaderRequiresFor(Module: TModuleSymbols): TArray<string>;
begin
  Result := TDllModule(Module).RequiredPackages;
end;

procedure TDapServer.LoaderLog(const Msg: string);
begin
  DapLog(Msg);
end;

procedure TDapServer.LoaderConsole(const Msg: string);
begin
  SendConsoleLog(Format('[T+%dms] %s', [GetTickCount64 - FAdapterStartTick, Msg]));
end;

// OnDllLoadedHook subscriber. The session's own HandleDllLoaded has already
// registered the module record (RegisterModuleRecord is NOT idempotent -- calling
// it again would create a DUPLICATE record), so re-find the live module rather than
// re-register. Everything else (config override, PACKAGEINFO-gated eager BP-probe,
// stale-sidecar warnings, startup progress, background enqueue) is the DAP-side
// half and runs here.
procedure TDapServer.SessionDllLoaded(const Name, Path: string; Base, ImageSize: UInt64);
var
  Module: TDllModule;
  CfgIdx: Integer;
begin
  // A module arrived: any view of the table is now out of date, and this is the
  // case worth telling a client about -- a package loaded while the target is
  // RUNNING would otherwise not show until the next stop.
  EmitModulesChanged;

  Module := FindLiveModule(Name, Base);
  if Module = nil then
    Exit;

  // Find an explicit config override (if any); RegisterModuleRecord already set
  // the adjacent (auto-discovery) paths as the fallback.
  CfgIdx := -1;
  for var I := 0 to High(FModulesConfig) do
    if ModuleNameMatches(FModulesConfig[I].Name, Name) then begin
      CfgIdx := I;
      Break;
    end;

  if CfgIdx >= 0 then begin
    Module.MapPath := FModulesConfig[CfgIdx].MapPath;
    Module.RsmPath := FModulesConfig[CfgIdx].RsmPath;
    Module.DcpPath := FModulesConfig[CfgIdx].DcpPath;
  end;

  // Only load this module's debug info providers if at least one active
  // breakpoint spec references a source file that lives inside it. A
  // fast text scan (MAP) or TD32 source-file walk (no full parse) lets
  // us skip the 199-of-200-BPL case cheaply. RSM stays lazy -- only
  // loaded when variable inspection is requested.
  //
  // When launch.json provides a non-empty `modules` array, treat it as an
  // explicit allow-list for eager probing: non-listed modules are tracked
  // but not scanned here. This avoids O(all loaded modules) symbol scans on
  // host applications that load hundreds of DLL/BPLs.
  // The session's HandleDllLoaded already re-posted its stored specs before firing
  // this hook (the single repost path), so here we only surface the DAP-side
  // stale-sidecar warnings and count MAP coverage. Gate on a session breakpoint's
  // source actually living in this module + the launch-config allow-list so an
  // unrelated module is not probed -- avoids O(N_dlls) work during startup.
  var MapLoaded := False;
  var ShouldProbe := (Length(FModulesConfig) = 0) or (CfgIdx >= 0);
  if ShouldProbe then
    for var Bp in FSession.ListBreakpoints do
      if Module.ContainsSourceFile(Bp.SourceFile) then begin
        // Stale-sidecar warning for the BPL's own symbol files (the BPL's
        // embedded TD32 is always in sync; .rsm/.map/.dcp can drift).
        if SymbolFileIsStale(Module.RsmPath, Module.FullPath) then
          SendConsoleLog(Format('WARNING: %s RSM is OLDER than the BPL -- it will be IGNORED (TD32/.dcp used instead): %s',
            [Module.Name, Module.RsmPath]));
        if SymbolFileIsStale(Module.MapPath, Module.FullPath) then
          SendConsoleLog(Format('WARNING: %s MAP is OLDER than the BPL -- symbols may be stale: %s',
            [Module.Name, Module.MapPath]));
        if SymbolFileIsStale(Module.DcpPath, Module.FullPath) then
          SendConsoleLog(Format('WARNING: %s DCP is OLDER than the BPL -- locals may be stale: %s',
            [Module.Name, Module.DcpPath]));
        // Idempotent (per-module tried flags); the session already loaded these
        // when HaveBreakpoints. Recorded here only so MapLoaded reflects coverage.
        if FileExists(Module.MapPath) then begin
          FLoader.EnsureModuleMap(Module);
          MapLoaded := True;
        end;
        FLoader.EnsureModuleTD32(Module);
        Break;
      end;

  // Symbol prefetching is no longer done here: TDebugSession.HandleDllLoaded
  // enqueues every runtime module with the shared prefetcher inside
  // TModuleSymbolLoader, so the MCP frontend gets it too.

  Inc(FStartupDllCount);
  if MapLoaded then
    Inc(FStartupMapCount);

  // Per-module load goes to the opt-in diagnostic log only. The debug console
  // would otherwise get one noisy line per system DLL; the throttled status-bar
  // progress below and the final summary cover the user-facing case.
  var ElapsedMs := GetTickCount64 - FStartupTick;
  var MapTag: string := '';
  if MapLoaded then MapTag := ' [MAP]';
  DapLog(Format('[%dms] #%d %s%s', [ElapsedMs, FStartupDllCount, Name, MapTag]));

  // Throttle: update status bar every 10 modules to avoid event flood.
  FLastDllTick := GetTickCount64;
  if FStartupActive and (FStartupDllCount mod 10 = 0) then
    SendProgressUpdate(Format('Loading modules... %d loaded, %d with symbols',
      [FStartupDllCount, FStartupMapCount]));
end;

function TDapServer.ModuleIsConfigured(const ModuleName: string): Boolean;
begin
  for var Cfg in FModulesConfig do
    if ModuleNameMatches(Cfg.Name, ModuleName) then
      Exit(True);
  Result := False;
end;

function TDapServer.FindLiveModule(const AName: string; ABase: UInt64): TDllModule;
begin
  for var M in FLoader.Modules do
    if (M.Base = ABase) and SameText(M.Name, AName) then
      Exit(TDllModule(M));
  Result := nil;
end;

procedure TDapServer.WarmupRequiresClosureForPC(PC: UInt64);

  function ModuleByBaseName(const BaseName: string): TDllModule;
  begin
    Result := nil;
    for var M in FLoader.Modules do
      if SameText(LowerCase(ChangeFileExt(M.Name, '')), BaseName) then
        Exit(TDllModule(M));
  end;

begin
  var FrameModule := TDllModule(FLoader.ModuleForPC(PC));
  if FrameModule = nil then
    Exit; // main-exe frame (no PACKAGEINFO requires) -- nothing to warm.

  var Visited := TDictionary<string, Boolean>.Create;
  var Queue   := TQueue<string>.Create;
  try
    for var R in FrameModule.RequiredPackages do
      Queue.Enqueue(R);
    while Queue.Count > 0 do begin
      var ReqName := Queue.Dequeue;
      if (ReqName = '') or Visited.ContainsKey(ReqName) then Continue;
      Visited.Add(ReqName, True);
      var ReqModule := ModuleByBaseName(ReqName);
      if ReqModule = nil then
        Continue; // not a debuggable module we track (e.g. rtl) -- skip.
      FLoader.EnsureModuleRsm(ReqModule);
      FLoader.EnsureModuleTD32(ReqModule);
      FLoader.EnsureModuleMap(ReqModule);
      FLoader.EnsureModuleDcp(ReqModule);
      for var R2 in ReqModule.RequiredPackages do
        if not Visited.ContainsKey(R2) then
          Queue.Enqueue(R2);
    end;
  finally
    Queue.Free;
    Visited.Free;
  end;
end;

function TDapServer.WarmupUsesScopeForFrame(FrameRva: UInt64): Boolean;
begin
  var ScopeUnits := FDebugInfo.ScopeUnitsForFrame(FrameRva);
  Result := Length(ScopeUnits) > 0;
  if not Result then
    Exit;  // no uses graph for this frame -> caller keeps the un-scoped fallback
  // Delphi has no transitive uses: the visible scope is exactly the frame's unit
  // plus its direct uses. Load ONLY the modules that own those units -- a bounded
  // set -- instead of every loaded module. A unit lives in one module, so stop at
  // the first owner. EnsureModule* is idempotent.
  for var UnitName in ScopeUnits do begin
    if UnitName = '' then Continue;
    var SrcFile := UnitName + '.pas';
    for var Module in FLoader.Modules do
      if TDllModule(Module).ContainsSourceFile(SrcFile) then begin
        FLoader.EnsureModuleTD32(Module);
        FLoader.EnsureModuleMap(Module);
        FLoader.EnsureModuleDcp(Module);
        Break;
      end;
  end;
end;

procedure TDapServer.SendBreakpointChanged(Id, Line: Integer;
  const SourceName, SourcePath: string; Verified: Boolean);
var
  Body: TJSONObject;
begin
  var Bp := TJSONObject.Create;
  Bp.AddPair('id',       TJSONNumber.Create(Id));
  Bp.AddPair('verified', TJSONBool.Create(Verified));
  Bp.AddPair('line',     TJSONNumber.Create(Line));
  var Src := TJSONObject.Create;
  Src.AddPair('name', SourceName);
  if SourcePath <> '' then
    Src.AddPair('path', SourcePath);
  Bp.AddPair('source', Src);
  Body := TJSONObject.Create;
  try
    Body.AddPair('reason', 'changed');
    Body.AddPair('breakpoint', Bp);
    FIO.SendEvent('breakpoint', Body);
  finally
    Body.Free;
  end;
  DapLog(Format('breakpoint changed: id=%d verified=%s %s:%d',
    [Id, BoolToStr(Verified, True), SourceName, Line]));
end;

function TDapServer.FindSourceFile(const Name: string): string;
begin
  Result := ExtractFileName(Name);
end;

// Searches rooted directories for a source file by basename. Each root is
// probed at the top level and one level deep. The RTL/VCL source tree has
// many subdirectories (rtl\common, rtl\sys, rtl\win, vcl, ...) so we also
// walk one level deeper for any root whose basename is 'source' (matches the
// Delphi installation layout).
function TDapServer.ResolveSourcePath(const BaseName: string): string;
begin
  // Delegated to the shared TSourceResolver (normalization + search + session-
  // stable cache all live there).
  Result := FSourceResolver.Resolve(BaseName);
end;

// HISTORICAL — the routine this described NO LONGER EXISTS. Kept only because
// the behaviour it describes is still observed and is currently UNEXPLAINED (see
// docs/KNOWN_UNKNOWNS.md, "an exception stop does not report the faulting frame"):
// on an exception stop the reported frame 0 is the calling Delphi frame with
// real source, not the true fault address, and that also reproduces against the
// engine directly rather than only through this adapter. So whatever produces
// it, it is NOT this trimming. Do not read the paragraph below as a description
// of live code.
//
// On an exception stop the top frames are RTL raise plumbing
// (@RaiseExcept / @Assert / AssertErrorHandler / ...). They have no locally
// resolvable source, so VS Code cannot open them and shows them as
// "Unknown Source". Drop the leading frames up to the first one with a
// resolvable local source so the call stack starts at the raise / assert site
// in the user's code. Only applied to exception stops, and never when no frame
// at all is navigable (then the full stack is kept).



// Map a (namespace-stripped) unit name from a MAP public symbol to its source
// file. The Delphi RTL/VCL ship files named with the full namespace
// (System.Classes.pas) while the MAP publics drop it (Classes.TFileStream...),
// so try the bare name first, then the common namespace prefixes. User and
// third-party units are usually un-namespaced, so the bare name covers them.
function TDapServer.ResolveUnitToSource(const UnitName: string): string;
begin
  Result := FSourceResolver.ResolveUnitToSource(UnitName);
end;

// For a frame that has a function name but no source line (RTL/third-party
// modules whose MAP/RSM carry publics only), synthesize a source location from
// the unit so VS Code treats the frame as selectable -- without a sourced frame
// it never opens the Variables view (Locals / $exception / watches). The line is
// not known (no line table), so point at line 1.
function TDapServer.TrySyntheticUnitSource(const FuncName: string;
  out FullPath: string; out Line: Integer): Boolean;
begin
  FullPath := '';
  Line     := 0;
  Result   := False;
  if (FuncName = '') or (FuncName[1] = '@') then Exit;
  var DotPos := Pos('.', FuncName);
  if DotPos <= 1 then Exit;
  var UnitName := Copy(FuncName, 1, DotPos - 1);
  FullPath := ResolveUnitToSource(UnitName);
  if FullPath = '' then Exit;
  Line   := 1;
  Result := True;
end;

// The `delphiProjectFile` launch/attach argument: the `.dpr` / `.dpk` / `.dproj`
// the configuration was generated for. The IDE plugin writes it as a
// ${workspaceFolder}-relative path, which VS Code (or the MCP launch-config
// loader) substitutes before the request reaches us, so it normally arrives
// absolute and needs no expansion here.
//
// The field is OPTIONAL. Absent -- a hand-written launch.json, or a plugin older
// than the field -- means no project scope exists, and the two sidecar tiers are
// not looked for at all: resolution is then exactly what it was before they
// existed. An entry still carrying a macro cannot name a directory, so say so
// rather than deriving sidecar paths from a literal `${...}`.
function TDapServer.ResolveDelphiProjectFile(Args: TJSONObject): string;
begin
  Result := Trim(Args.GetValue<string>('delphiProjectFile', ''));
  if Result = '' then
    Exit;
  if (Pos('${', Result) > 0) or (Pos('$(', Result) > 0) then begin
    DapLog('delphiProjectFile: IGNORED, unresolved macro in "' + Result + '"');
    Exit('');
  end;
  Result := ExpandFileName(Result);
end;

// Append a file-backed tier. The file need not exist: an absent one contributes
// no rules but keeps its place in the chain, so creating it mid-session is picked
// up by the hot-reload on the next resume (mtime 0 -> a real timestamp).
procedure TDapServer.AddFileRuleTier(const Path, Description: string);
begin
  if Path = '' then
    Exit;
  var Tier := Default(TExceptionRuleTier);
  Tier.Path        := Path;
  Tier.Description := Description;
  Tier.MTime       := ExceptionRulesFileMTime(Path);
  Tier.Rules       := LoadExceptionRulesFile(Path);
  FRuleTiers := FRuleTiers + [Tier];
  if Length(Tier.Rules) > 0 then
    DapLog(Format('exceptionRules: %d %s rule(s) from %s',
      [Length(Tier.Rules), Description, Path]));
end;

function TDapServer.CombinedExceptionRules: TArray<TExceptionRule>;
begin
  Result := nil;
  for var Tier in FRuleTiers do
    Result := Result + Tier.Rules;
end;

// Capture the session's exception-rule config at launch/attach and return the
// combined table, so the caller can hand it to the session's launch/attach
// options -- the session pushes it to the engine it builds (the engine does not
// exist yet at this point).
//
// The chain runs from the narrowest scope to the widest, and first match wins
// across all of it:
//
//   1. <Project>.ExceptionSettings.local.json  this developer, this machine
//   2. <Project>.ExceptionSettings.json        the project's own, shared by the team
//   3. the machine-wide shared file
//
// Tiers 1 and 2 exist only when the configuration named a `delphiProjectFile`;
// with no project named, the machine-wide file is the whole chain.
//
// A launch configuration cannot carry rules of its own. It once could, and the
// result was that debugging the SAME program obeyed different rules depending on
// whether the session launched it or attached to it -- two configurations for
// one project, free to disagree. Which rules apply and how the session started
// are orthogonal, so the launch-configuration scope is gone rather than kept
// alongside the ones that mean something.
function TDapServer.ApplyExceptionRules(Args: TJSONObject): TArray<TExceptionRule>;
begin
  SetLength(FRuleTiers, 0);
  FDelphiProjectFile := ResolveDelphiProjectFile(Args);
  FUseGlobalRules    := Args.GetValue<Boolean>('useGlobalExceptionRules', True);
  FGlobalRulesPath   := Args.GetValue<string>('globalExceptionRulesPath', '');
  if FUseGlobalRules and (FGlobalRulesPath = '') then
    FGlobalRulesPath := DefaultGlobalExceptionRulesPath;

  if FDelphiProjectFile <> '' then begin
    DapLog('delphiProjectFile: ' + FDelphiProjectFile);
    AddFileRuleTier(LocalProjectExceptionRulesPath(FDelphiProjectFile), 'project (local)');
    AddFileRuleTier(ProjectExceptionRulesPath(FDelphiProjectFile),      'project (shared)');
  end;
  if FUseGlobalRules then
    AddFileRuleTier(FGlobalRulesPath, 'machine-wide');

  Result := CombinedExceptionRules;
end;

// Hot-reload: re-read every tier that changed on disk, so the user can edit
// rules while stopped and have them apply on resume without restarting. Called
// from the continue / step handlers.
procedure TDapServer.ReloadExceptionRuleFilesIfChanged;
begin
  if FDebugger = nil then
    Exit;
  var Changed := False;
  for var I := 0 to High(FRuleTiers) do begin
    var MTime := ExceptionRulesFileMTime(FRuleTiers[I].Path);
    if MTime = FRuleTiers[I].MTime then
      Continue;
    FRuleTiers[I].MTime := MTime;
    FRuleTiers[I].Rules := LoadExceptionRulesFile(FRuleTiers[I].Path);
    Changed := True;
    SendConsoleLog(Format('[exceptionRules] reloaded %s (%d rules): %s',
      [FRuleTiers[I].Description, Length(FRuleTiers[I].Rules), FRuleTiers[I].Path]));
  end;
  if Changed then
    FDebugger.SetExceptionRules(CombinedExceptionRules);
end;

// TDebugSession.OnSessionStopped subscriber. The neutral half (ClearActiveFrame,
// FExpander.Reset, FRtti create, EnsureModuleForPC, raise-plumbing trim, dsStopped +
// StopGeneration bump, effective source resolution) already ran inside the session's
// HandleTargetStopped; Info carries the resolved reason/source/function/thread +
// exception description. This does the DAP-only half: reset the per-stop bimap, arm
// the busy spinner, end startup progress, then build and send the `stopped` event.
procedure TDapServer.OnSessionStopped(const Info: TStopInfo);
var
  Body: TJSONObject;
  Src:  TJSONObject;
begin
  SetLength(FLastFrames, 0);
  FStoppedOnException := Info.Reason = srException;
  // End startup progress on first stop, reporting elapsed time and module counts.
  if FStartupActive then begin
    var SummaryMsg := Format('Ready -- %d modules loaded (%d with symbols) in %dms',
      [FStartupDllCount, FStartupMapCount, GetTickCount64 - FStartupTick]);
    SendProgressEnd(SummaryMsg);
    SendConsoleLog('[DONE] ' + SummaryMsg);
  end;
  // Keep the busy spinner alive across the post-stop request burst (stackTrace /
  // variables / slow watch evaluates that follow). The watchdog closes it once
  // those settle; closing it here would hide the slowest, most visible part.
  MarkBusy('Delphi debugger: updating...');
  // The DAP int-ref <-> opaque-handle bimap is DAP-only and MUST be reset every
  // stop (the session resets its own expander handle table but not this map).
  FRefToHandle.Clear;
  FHandleToRef.Clear;
  FNextExpRef := EXPANSION_REF_BASE;
  SyncExpander;

  Body := TJSONObject.Create;
  try
    case Info.Reason of
      srEntry:      Body.AddPair('reason', 'entry');
      srBreakpoint: begin
        Body.AddPair('reason', 'breakpoint');
        if Info.BreakpointConditionError <> '' then begin
          // The stop happened BECAUSE the condition would not evaluate. VS Code
          // has no modal message box (which is how the Delphi IDE reports this),
          // but `description` / `text` on the stopped event put the reason in the
          // inline widget where exception and watchpoint stops already explain
          // themselves -- otherwise this looks like an unconditional stop on a
          // line the user deliberately conditioned.
          Body.AddPair('description', Info.BreakpointConditionError);
          Body.AddPair('text',        Info.BreakpointConditionError);
        end;
      end;
      srStep:       Body.AddPair('reason', 'step');
      srException: begin
        Body.AddPair('reason', 'exception');
        if Info.ExceptionDescription <> '' then begin
          // `description` is the inline-widget header; `text` is the longer blurb
          // VS Code shows under it. Use the combined "Class: Message" for both.
          Body.AddPair('description', Info.ExceptionDescription);
          Body.AddPair('text',        Info.ExceptionDescription);
        end;
      end;
      srPause:      Body.AddPair('reason', 'pause');
      srDataBreakpoint: begin
        // DAP's own reason string for a watchpoint hit. Without this case the
        // stop arrived with NO reason at all, which VS Code renders as a plain
        // pause -- indistinguishable from the user hitting the pause button.
        Body.AddPair('reason', 'data breakpoint');
        if Info.DataBreakpointDescription <> '' then begin
          // "V: $1 -> $2a (thread 5)" -- old -> new and the thread that wrote
          // it are the answer the feature exists to give, so they go in the
          // inline header, not only in the log.
          Body.AddPair('description', Info.DataBreakpointDescription);
          Body.AddPair('text',        Info.DataBreakpointDescription);
        end;
      end;
    end;
    var StoppedTid: DWORD := Info.OsThreadId;
    if StoppedTid = 0 then StoppedTid := 1;
    Body.AddPair('threadId',            TJSONNumber.Create(Int64(StoppedTid)));
    Body.AddPair('allThreadsStopped',   TJSONBool.Create(True));

    // The session already resolved the raise site into Info.SourceFile/Line. When an
    // exception still lands with no source (raised entirely in RTL / publics-only
    // code), reproduce the DAP-only fallback: walk the stack, cache it so frameId
    // maps before the first stackTrace, and synthesise a unit source so VS Code
    // still selects a frame and shows $exception.
    var EffSourceFile := Info.SourceFile;
    var EffSourceLine := Info.SourceLine;
    if (Info.Reason = srException) and (EffSourceFile = '') then begin
      // The session walks + lazy-loads symbols + trims raise plumbing for the
      // stopped thread and caches its frames for SelectFrame; take the same
      // neutral frames so frameId maps even before the first stackTrace request.
      FLastFrames := FSession.GetCallStack;
      for var F in FLastFrames do
        if F.SourceFile <> '' then begin
          EffSourceFile := F.SourceFile;
          EffSourceLine := F.SourceLine;
          Break;
        end;
      if EffSourceFile = '' then
        for var F in FLastFrames do begin
          var SynthPath: string;
          var SynthLine: Integer;
          if TrySyntheticUnitSource(F.FunctionName, SynthPath, SynthLine) then begin
            EffSourceFile := SynthPath;   // already a full path
            EffSourceLine := SynthLine;
            Break;
          end;
        end;
    end;

    if EffSourceFile <> '' then begin
      Src := TJSONObject.Create;
      Src.AddPair('name', ExtractFileName(EffSourceFile));
      var FullPath := ResolveSourcePath(EffSourceFile);
      if FullPath <> '' then
        Src.AddPair('path', FullPath);
      Body.AddPair('source', Src);
      Body.AddPair('line', TJSONNumber.Create(EffSourceLine));
    end;
    FIO.SendEvent('stopped', Body);
    // Everything the target ran since the last stop could have rewritten what an
    // open hex pane is showing. The client re-reads variables at a stop on its
    // own; memory it does not, without being told.
    EmitMemoryChanged;
    // Belt and braces for the case the user actually complained about: a stop
    // where nothing on the stack has real source. Whether the client opens the
    // placeholder document is the client's choice; this is not.
    if EffSourceFile = '' then
      AnnounceSourcelessStop(Info);
  finally
    Body.Free;
  end;
end;

// Label for a frame the symbol providers could not name. A bare `0x...` hides
// three different situations behind one rendering; spelling the reason out lets
// the user act on it (rebuild that module / wait for the index / nothing to do).
// Declared here rather than beside HandleStackTrace because the sourceless-stop
// announcement below needs it too.
function NamelessFrameLabel(const F: TSessionFrame): string;
begin
  var Reason: string;
  case F.Symbols of
    saNoSymbols: Reason := 'no symbols';
    saIndexing:  Reason := 'symbols indexing';
    saLoaded:    Reason := 'not covered by symbols';
  else
    Reason := 'unknown module';
  end;
  if F.ModuleName <> '' then
    Exit(Format('0x%x (%s: %s)', [F.IP, F.ModuleName, Reason]));
  Result := Format('0x%x (%s)', [F.IP, Reason]);
end;

// A stop where NO frame has real source is the one that cannot be seen: there is
// no file for the client to bring forward, so the screen may not change at all
// and the target simply goes quiet. `AttachPlaceholderSource` gives the client
// something to open; this states the stop somewhere always visible regardless.
// `important` is the DAP output category VS Code renders prominently and reveals
// the Debug Console for.
procedure TDapServer.AnnounceSourcelessStop(const Info: TStopInfo);
begin
  // The exception path already walked the stack into FLastFrames; other reasons
  // have not, and this is the rare branch, so paying for a walk here is fine.
  if Length(FLastFrames) = 0 then
    FLastFrames := FSession.GetCallStack;

  var Where := '<location unknown>';
  if Length(FLastFrames) > 0 then begin
    var F := FLastFrames[0];
    if F.FunctionName <> '' then
      Where := Format('%s  (0x%x in %s)', [F.FunctionName, F.IP, F.ModuleName])
    else
      Where := NamelessFrameLabel(F);
  end;

  var What: string;
  case Info.Reason of
    srEntry:      What := 'STOPPED at the process entry point';
    srBreakpoint: What := 'STOPPED at a breakpoint';
    srStep:       What := 'STOPPED after a step';
    srException:  What := 'STOPPED on an exception';
    srPause:      What := 'PAUSED';
  else
    What := 'STOPPED';
  end;

  var Msg := '>>> DEBUGGER ' + What + ' -- no source available for this stack' + sLineBreak +
             '    at ' + Where + sLineBreak;
  if (Info.Reason = srException) and (Info.ExceptionDescription <> '') then
    Msg := Msg + '    ' + Info.ExceptionDescription + sLineBreak;
  Msg := Msg +
    '    No frame in this call stack carries debug info the adapter can read,' + sLineBreak +
    '    so there is no line to open. The target IS stopped. There is still' + sLineBreak +
    '    plenty to look at: open the DISASSEMBLY VIEW on a frame to see the' + sLineBreak +
    '    instructions at the stop, use the CALL STACK view, or select a frame' + sLineBreak +
    '    to open its placeholder description.' + sLineBreak;
  SendOutputEvent(Msg, 'important');
end;

procedure TDapServer.OnSessionExited(ExitCode: Integer);
var
  Body: TJSONObject;
begin
  SendProgressEnd('');  // close spinner if process exits before first stop
  EnterCriticalSection(FOpLock);  // close op spinner if it exits mid-step/continue
  FBusyArmed := False;
  SendOpProgressEnd;
  LeaveCriticalSection(FOpLock);
  Body := TJSONObject.Create;
  try
    Body.AddPair('exitCode', TJSONNumber.Create(ExitCode));
    FIO.SendEvent('exited', Body);
    FIO.SendEvent('terminated');
  finally
    Body.Free;
  end;
end;

// Program stdout (okDebuggee) -> `output` category stdout. Debugger-generated text
// (okDebugger), which is how the session's HandleBpHit surfaces logpoint messages,
// -> `output` category console, matching the old OnBpHit console emission (with the
// trailing line break the logpoint path used to append).
// Three destinations, because the three kinds are not the same thing to a user.
//
// The program's stdout and a logpoint the user WROTE both belong in the Debug
// Console -- that panel is about the program. The debugger's own diagnostics
// (symbol loading, modules without debug info, warnings) are about the
// DEBUGGER, and mixing them in buries the first two: a multi-package app emits
// hundreds of "no debug info for X" lines before the program prints anything.
//
// Diagnostics leave as a CUSTOM event rather than an `output` one. A debug
// adapter tracker can observe `output` events but cannot suppress them, so
// filtering in the extension would show every line twice. The same reasoning
// already produced the `delphiProgress` custom event.
procedure TDapServer.OnSessionOutput(Kind: TOutputKind; const Text: string);
begin
  case Kind of
    okDebuggee:
      SendOutputEvent(Text, 'stdout');
    okLogPoint:
      SendOutputEvent(Text + sLineBreak, 'console');
    okNotice:
      // The debugger complaining about something the user WROTE. Console, for
      // the same reason a logpoint goes there: it is about the user's own input,
      // and the diagnostics channel is where it would be buried.
      SendOutputEvent(Text + sLineBreak, 'console');
  else
    SendDiagnosticEvent(Text);
  end;
end;

// Diagnostics for the extension's "Delphi Debugger" output channel, as the
// `delphiLog` custom event. The destination is chosen SOLELY by the
// `diagnosticsLocation` config value; there is no listener detection, and DAP
// offers no capability a client could declare that would provide one.
//
// The consequence, stated rather than papered over: a client that is not this
// extension and does not set `"diagnosticsLocation": "debugConsole"` receives
// `delphiLog` events it has no handler for, and the lines are lost. A plain DAP
// client should set that option. (An earlier version of this comment claimed a
// fallback that the code never had.)
procedure TDapServer.SendDiagnosticEvent(const Text: string);
begin
  if not FDiagnosticsToOutputChannel then begin
    SendOutputEvent(Text + sLineBreak, 'console');
    Exit;
  end;
  var Body := TJSONObject.Create;
  try
    Body.AddPair('text', Text);
    FIO.SendEvent('delphiLog', Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.HandleInitialize(Seq: Integer; Args: TJSONObject);
var
  Caps: TJSONObject;
begin
  // The `invalidated` event may only be sent to a client that asked for it.
  // Recorded here rather than assumed: the raw-stack toggle needs it to make the
  // Call Stack redraw, and a client without it must get the toggle anyway (its
  // effect simply shows at the next stop).
  if Args <> nil then begin
    FClientSupportsInvalidated := Args.GetValue<Boolean>('supportsInvalidatedEvent', False);
    // Gate for the `memory` event. A client that never declared it would be sent
    // an event it does not understand, which the spec leaves it free to treat as
    // a protocol error.
    FClientSupportsMemoryEvent := Args.GetValue<Boolean>('supportsMemoryEvent', False);
  end;

  Caps := TJSONObject.Create;
  try
    Caps.AddPair('supportsConfigurationDoneRequest', TJSONBool.Create(True));
    Caps.AddPair('supportsFunctionBreakpoints',      TJSONBool.Create(False));
    Caps.AddPair('supportsConditionalBreakpoints',   TJSONBool.Create(True));
    Caps.AddPair('supportsHitConditionalBreakpoints',TJSONBool.Create(True));
    Caps.AddPair('supportsLogPoints',                TJSONBool.Create(True));
    // Exception-breakpoint filters surfaced in the BREAKPOINTS view.
    // Filter IDs are echoed back by the client in `setExceptionBreakpoints`;
    // `default: True` means the box is checked when the session first opens.
    Caps.AddPair('exceptionBreakpointFilters',
      BuildExceptionFilterCapability);
    // Allow per-filter `condition` strings -- used to refine the `delphi`
    // filter to a comma-separated class list.
    Caps.AddPair('supportsExceptionFilterOptions', TJSONBool.Create(True));
    // `exceptionInfo` request: VS Code calls it on an exception stop to fill the
    // details panel with the class name, message, and break mode.
    Caps.AddPair('supportsExceptionInfoRequest',   TJSONBool.Create(True));
    Caps.AddPair('supportsStepInTargetsRequest',     TJSONBool.Create(False));
    Caps.AddPair('supportsEvaluateForHovers',        TJSONBool.Create(True));
    Caps.AddPair('supportsSetVariable',              TJSONBool.Create(True));
    Caps.AddPair('supportsGotoTargetsRequest',       TJSONBool.Create(True));
    // Hardware watchpoints. Declaring this is what puts "Break on Value Change"
    // (and "... Value Access") into the Variables context menu, so the two
    // requests behind it must be right before it is advertised:
    // `dataBreakpointInfo` derives the dataId, `setDataBreakpoints` replaces the
    // whole set. Only `write` and `readWrite` are ever offered -- x86/x64 has no
    // read-only watchpoint (see HandleDataBreakpointInfo).
    Caps.AddPair('supportsDataBreakpoints',          TJSONBool.Create(True));
    // Turns on VS Code's "Add Data Breakpoint at Address" entry in the
    // Breakpoints panel -- the only place in the UI where a watch target can be
    // TYPED rather than picked off a Variables row. Without it there is no way
    // to watch the byte just past the end of a buffer, which is most of what
    // watchpoints are wanted for.
    Caps.AddPair('supportsDataBreakpointBytes',      TJSONBool.Create(True));
    // Address breakpoints (docs/DISASSEMBLY_PLAN.md increment 5): VS Code's own
    // address-breakpoint channel, and what the Disassembly View gutter uses to
    // let a click plant one. `setInstructionBreakpoints` behind it replaces the
    // whole address-breakpoint set on every call, matching the DAP spec.
    Caps.AddPair('supportsInstructionBreakpoints',   TJSONBool.Create(True));
    // Disassembly View (docs/DISASSEMBLY_PLAN.md increment 6): the `disassemble`
    // request behind it decodes real target memory through the same
    // IDisassembler/Zydis backend the MCP `disassemble` tool already uses.
    // `instructionPointerReference` on every StackFrame (HandleStackTrace) is
    // what enables "Open Disassembly View" from the Call Stack.
    Caps.AddPair('supportsDisassembleRequest',       TJSONBool.Create(True));
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3: `readMemory`/`writeMemory`,
    // what backs VS Code's "View Binary Data" memory inspector. Same engine
    // primitives (IDebugTarget.ReadCodeMemoryAt / WriteMemoryPartial) the MCP
    // `read_memory`/`write_memory` tools already use -- not a second path.
    //
    // Advertised by DEFAULT, because a client with no Delphi extension (another
    // editor, a bare DAP client) has no other way to inspect memory at all.
    // `--no-stock-memory-view` withdraws the two capabilities WITHOUT disabling
    // the requests: the VS Code extension passes it because it ships its own
    // memory view, and the editor's built-in pane -- which cannot scroll before
    // the value, mark its extent, or show what changed -- is then redundant
    // clutter on every variable row. The requests keep working, and the
    // extension's view reaches them through `customRequest`, which is not gated
    // on an advertised capability.
    if StockMemoryViewEnabled then begin
      Caps.AddPair('supportsReadMemoryRequest',      TJSONBool.Create(True));
      Caps.AddPair('supportsWriteMemoryRequest',     TJSONBool.Create(True));
    end;
    // docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 2: `granularity: "instruction"` on
    // next/stepIn/stepOut, routed to TDebugSession.StepInstruction (increment
    // 1's engine primitive). VS Code sends the field only when the
    // Disassembly View has focus, and only once this capability says the
    // adapter understands it.
    // `modules`: which images are loaded and what debug info each has. VS Code
    // has no built-in view for it, so the extension draws one -- but the request
    // is the standard one, because any DAP client can then ask.
    Caps.AddPair('supportsModulesRequest',           TJSONBool.Create(True));
    Caps.AddPair('supportsSteppingGranularity',      TJSONBool.Create(True));
    // NOTE: `supportsProgressReporting` is a CLIENT capability in the DAP spec
    // (InitializeRequestArguments), not an adapter one. VS Code ignores it in the
    // initialize response, so it does not gate whether progress toasts appear --
    // only actually emitting progressStart/Update/End does. It stays True (a
    // harmless statement of intent); suppressing toasts in statusBar mode is done
    // by not emitting those events at all. See EmitProgress.
    Caps.AddPair('supportsProgressReporting',         TJSONBool.Create(True));
    FIO.SendResponse(Seq, 'initialize', True, Caps);
    FIO.SendEvent('initialized');
    SendConsoleLog(Format('[T+%dms] initialize done', [GetTickCount64 - FAdapterStartTick]));
  finally
    Caps.Free;
  end;
end;

// Resolves an EXE path from a process ID via the Windows
// QueryFullProcessImageName API. Returns '' if the process can't be opened
// (insufficient privilege, already exited, ...).
// Imported manually because Winapi.Windows on this Delphi version doesn't
// surface it.
function QueryFullProcessImageNameW(hProcess: THandle; dwFlags: DWORD;
  lpExeName: PWideChar; var lpdwSize: DWORD): BOOL; stdcall;
  external kernel32 name 'QueryFullProcessImageNameW';

// True when a separate symbol file (.rsm / .map) is OLDER than the binary
// it describes -- its symbols / types / offsets may no longer match, which
// silently corrupts the variables view (wrong type, wrong value). TD32 is
// embedded in the binary so it can never go stale; only the sidecar
// symbol files can drift (rebuild the EXE without regenerating them, or
// copy an older .rsm next to a newer .exe).
function ExePathFromPid(Pid: Cardinal): string;
const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
var
  H: THandle;
  Buf: array[0..MAX_PATH - 1] of WideChar;
  Sz: DWORD;
begin
  Result := '';
  H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if H = 0 then Exit;
  try
    Sz := MAX_PATH;
    if QueryFullProcessImageNameW(H, 0, @Buf[0], Sz) then
      SetString(Result, PWideChar(@Buf[0]), Sz);
  finally
    CloseHandle(H);
  end;
end;

// Walks the running-process snapshot looking for an EXE basename match
// (case-insensitive). Returns the first matching PID or 0 if none.
// Every process whose image name matches, NOT just the first. Attaching to
// "whichever one the kernel enumerated first" is indistinguishable from
// attaching to the one the user meant, and the mistake only surfaces later as
// breakpoints that never fire in an application that looks identical.
function PidsFromExeName(const ExeName: string): TArray<Cardinal>;
var
  Snap: THandle;
  Pe:   TProcessEntry32W;
  Wanted: string;
begin
  Result := [];
  Wanted := AnsiLowerCase(ExeName);
  // Be permissive: caller may pass `MyApp` or `MyApp.exe`.
  if not Wanted.EndsWith('.exe') then
    Wanted := Wanted + '.exe';
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then Exit;
  try
    Pe.dwSize := SizeOf(Pe);
    if not Process32FirstW(Snap, Pe) then Exit;
    repeat
      if SameText(string(Pe.szExeFile), Wanted) then
        Result := Result + [Pe.th32ProcessID];
    until not Process32NextW(Snap, Pe);
  finally
    CloseHandle(Snap);
  end;
end;

// Parse launch.json source-path + module config into the DAP-side fields the
// introspection handlers still read (FExePath / source roots / FModulesConfig).
// The session loads the main module and configures the source resolver itself in
// Launch/Attach, so this does NEITHER -- it only parses.
procedure TDapServer.ParseSourceAndModules(Args: TJSONObject;
  const ProgramPath: string);
begin
  FExePath     := ProgramPath;
  FMapPath     := Args.GetValue<string>('mapFile', ChangeFileExt(ProgramPath, '.map'));
  FRsmPath     := Args.GetValue<string>('rsmFile', ChangeFileExt(ProgramPath, '.rsm'));
  FSourceRoot  := Args.GetValue<string>('sourceRoot', '');

  SetLength(FExtraSourcePaths, 0);
  var ArrP := Args.FindValue('sourceSearchPaths');
  if ArrP is TJSONArray then
    for var I := 0 to TJSONArray(ArrP).Count - 1 do begin
      var Raw := TJSONArray(ArrP).Items[I].Value;
      var Expanded := Raw;
      var P1 := Pos('${env:', Expanded);
      while P1 > 0 do begin
        var P2 := Pos('}', Expanded, P1);
        if P2 <= P1 then Break;
        var VarName  := Copy(Expanded, P1 + 6, P2 - P1 - 6);
        var VarValue := GetEnvironmentVariable(VarName);
        Expanded := Copy(Expanded, 1, P1 - 1) + VarValue + Copy(Expanded, P2 + 1, MaxInt);
        P1 := Pos('${env:', Expanded);
      end;
      // An entry that still carries a macro cannot be used as a directory. That
      // happens with Delphi-style $(Platform) / $(Config), which no one expands:
      // VS Code does not know them, and this adapter only resolves ${env:VAR}
      // (${workspaceFolder} is already substituted by VS Code, or by the MCP
      // launch-config loader, before it reaches us). Dropping such an entry
      // silently costs the user source files with no visible error, so say so.
      if (Pos('$(', Expanded) > 0) or (Pos('${', Expanded) > 0) then begin
        DapLog('  sourceSearchPaths: SKIPPED unresolved entry "' + Raw +
               '" (unexpanded macro; use ${env:VAR} or ${workspaceFolder}, ' +
               'not Delphi-style $(Platform)/$(Config))');
        Continue;
      end;
      for var Part in SplitString(Expanded, ';') do begin
        var Entry := Trim(Part);
        if Entry = '' then Continue;
        FExtraSourcePaths := FExtraSourcePaths + [Entry];
        if not DirectoryExists(Entry) then
          DapLog('  sourceSearchPaths: entry does not exist: ' + Entry);
      end;
    end;
  var Bds := GetEnvironmentVariable('BDS');
  if Bds <> '' then begin
    var BdsSource := IncludeTrailingPathDelimiter(Bds) + 'source';
    if DirectoryExists(BdsSource) then
      FExtraSourcePaths := FExtraSourcePaths + [BdsSource];
  end;

  SetLength(FModulesConfig, 0);
  var ModArr := Args.FindValue('modules');
  if ModArr is TJSONArray then
    for var ModItem in TJSONArray(ModArr) do begin
      var MObj := ModItem as TJSONObject;
      var MCfg: TModuleConfig;
      MCfg.Name    := NormalizeModuleName(MObj.GetValue<string>('name', ''));
      MCfg.MapPath := MObj.GetValue<string>('map',  '');
      MCfg.RsmPath := MObj.GetValue<string>('rsm',  '');
      MCfg.DcpPath := MObj.GetValue<string>('dcp',  '');
      if MCfg.Name <> '' then
        FModulesConfig := FModulesConfig + [MCfg];
    end;
end;

// Project the DAP-side module config onto the neutral session record the launch/
// attach options carry (the session applies the sidecar overrides in HandleDllLoaded).
function TDapServer.SessionModules: TArray<TSessionModuleConfig>;
begin
  SetLength(Result, Length(FModulesConfig));
  for var I := 0 to High(FModulesConfig) do begin
    Result[I].Name    := FModulesConfig[I].Name;
    Result[I].MapPath := FModulesConfig[I].MapPath;
    Result[I].RsmPath := FModulesConfig[I].RsmPath;
    Result[I].DcpPath := FModulesConfig[I].DcpPath;
  end;
end;

procedure TDapServer.HandleAttach(Seq: Integer; Args: TJSONObject);
var
  Pid: Cardinal;
  ProgramPath: string;
  KillOnDetach: Boolean;
begin
  // One response per request, sent at the END (see HandleLaunch).
  if Args.GetValue<Boolean>('diagnosticLog', False) then
    SetDapLogEnabled(True);
  ParseProgressLocation(Args);
  Pid := Cardinal(Args.GetValue<Integer>('processId', 0));
  if Pid = 0 then begin
    // Convenience: caller may pass `processName` (basename or full file
    // name) instead of a literal PID. We pick the first match from the
    // running-process snapshot. Useful when the IDE doesn't know the PID
    // up front.
    var WantName := Args.GetValue<string>('processName', '');
    if WantName <> '' then begin
      var Matches := PidsFromExeName(WantName);
      if Length(Matches) = 0 then begin
        FIO.SendErrorResponse(Seq, 'attach',
          Format('No running process matches "%s"', [WantName]));
        Exit;
      end;
      if Length(Matches) > 1 then begin
        var PidList := '';
        for var P in Matches do begin
          if PidList <> '' then
            PidList := PidList + ', ';
          PidList := PidList + UIntToStr(P);
        end;
        FIO.SendErrorResponse(Seq, 'attach',
          Format('%d processes match "%s" (PIDs %s). Set "processId" to the one you want, ' +
                 'or use "processId": "${command:delphi-win64.pickProcess}" to choose at launch.',
                 [Length(Matches), WantName, PidList]));
        Exit;
      end;
      Pid := Matches[0];
    end;
  end;
  if Pid = 0 then begin
    FIO.SendErrorResponse(Seq, 'attach',
      'Missing or zero "processId" (or empty "processName") in attach config');
    Exit;
  end;

  // EXE path is preferred from launch.json (lets the user point at a
  // matching MAP/RSM independent of the running binary). Fall back to
  // the kernel's view of the process image.
  ProgramPath := Args.GetValue<string>('program', '');
  if ProgramPath = '' then begin
    ProgramPath := ExePathFromPid(Pid);
    if ProgramPath = '' then begin
      FIO.SendErrorResponse(Seq, 'attach',
        Format('Cannot resolve EXE path for PID %d (process gone or insufficient privilege)',
          [Pid]));
      Exit;
    end;
  end;

  KillOnDetach := Args.GetValue<Boolean>('killOnDetach', False);
  ParseRawStackScan(Args);
  ParseDiagnosticsLocation(Args);

  ParseSourceAndModules(Args, ProgramPath);
  DapLog(Format('Attach: pid=%d exe=%s map=%s rsm=%s killOnDetach=%s',
    [Pid, FExePath, FMapPath, FRsmPath, BoolToStr(KillOnDetach, True)]));

  // Hand the engine ownership + symbol/resolver setup to the session. It builds and
  // wires the single TWinDebugger, loads the main module, configures the resolver and
  // applies the exception filters/rules from the options.
  var Opts := Default(TAttachOptions);
  Opts.ProgramPath      := FExePath;
  Opts.MapPath          := FMapPath;
  Opts.RsmPath          := FRsmPath;
  Opts.SourceRoot       := FSourceRoot;
  Opts.ExtraSourcePaths := FExtraSourcePaths;
  Opts.Modules          := SessionModules;
  Opts.ExceptionRules      := ApplyExceptionRules(Args);
  Opts.ExceptionFilters    := FExceptionFilters;
  Opts.ExceptionFiltersSet := FExceptionFiltersSet;
  Opts.DelphiClassFilter   := FDelphiClassFilter;

  try
    FSession.Attach(Pid, KillOnDetach, Opts);
  except
    on E: Exception do begin
      DapLog('Attach FAILED: ' + E.Message);
      FIO.SendErrorResponse(Seq, 'attach',
        Format('Cannot attach to PID %d: %s', [Pid, E.Message]));
      Exit;
    end;
  end;
  FLaunched := True;
  // Addresses from a previous run mean nothing in this one (a fresh process,
  // rebased modules, a different stack), so no view carries over.
  SetLength(FMemoryViews, 0);
  FStartupDllCount := 0;
  FStartupMapCount := 0;
  FStartupTick     := GetTickCount64;
  FIO.SendResponse(Seq, 'attach', True);
  SendProgressStart(Format('Attached to PID %d', [Pid]));
  // Breakpoints that arrived before attach were delegated to FSession.SetBreakpoints
  // and buffered in the session's own pending list; FSession.Attach flushes them once
  // the engine is wired (ApplyPendingBreakpoints), so the DAP layer does nothing here.
end;

procedure TDapServer.HandleLaunch(Seq: Integer; Args: TJSONObject);
var
  ProgramPath: string;
begin
  // NOTE: exactly ONE response per request. The success response is sent at
  // the END, after CreateProcess succeeded -- answering success up-front and
  // following up with an error was a DAP violation and left VS Code with a
  // zombie session when the launch failed.
  ProgramPath  := Args.GetValue<string>('program', '');
  FStopAtEntry := Args.GetValue<Boolean>('stopAtEntry', False);
  ParseRawStackScan(Args);
  ParseDiagnosticsLocation(Args);

  // Diagnostic log opt-in: writes %TEMP%\dap_adapter.log when launch.json
  // sets `"diagnosticLog": true` (or env var DAP_LOG=1, set at adapter startup).
  // Default off so a normal user's TEMP folder isn't littered with adapter logs.
  if Args.GetValue<Boolean>('diagnosticLog', False) then
    SetDapLogEnabled(True);

  // Read before the first SendProgressStart below, so startup progress already
  // uses the configured channel.
  ParseProgressLocation(Args);

  if ProgramPath = '' then begin
    FIO.SendErrorResponse(Seq, 'launch', 'Missing "program" in launch config');
    Exit;
  end;
  if not FileExists(ProgramPath) then begin
    FIO.SendErrorResponse(Seq, 'launch',
      Format('Program not found: %s', [ProgramPath]));
    Exit;
  end;

  // Parse source roots + module config into the DAP-side fields (the session loads
  // the main module + configures the resolver itself in Launch).
  ParseSourceAndModules(Args, ProgramPath);
  DapLog('Source search paths:');
  DapLog('  sourceRoot = ' + FSourceRoot);
  for var SP in FExtraSourcePaths do
    DapLog('  extra     = ' + SP);

  DapLog('Launch: exe=' + FExePath + ' map=' + FMapPath + ' rsm=' + FRsmPath +
    ' stopAtEntry=' + BoolToStr(FStopAtEntry, True));
  DapLog('  exe exists=' + BoolToStr(FileExists(FExePath), True) +
    ' map exists=' + BoolToStr(FileExists(FMapPath), True) +
    ' rsm exists=' + BoolToStr(FileExists(FRsmPath), True));

  // Optional cmd-line args from launch.json (`args: ["--foo", "bar"]`), joined
  // into a single string for the session to append to the EXE path.
  var ArgStr := '';
  var ArgsArr := Args.FindValue('args');
  if ArgsArr is TJSONArray then
    for var I := 0 to TJSONArray(ArgsArr).Count - 1 do
      ArgStr := ArgStr + ' ' + TJSONArray(ArgsArr).Items[I].Value;
  ArgStr := Trim(ArgStr);

  // Hand engine ownership + symbol/resolver setup + exception config to the session.
  var Opts := Default(TLaunchOptions);
  Opts.ExePath          := FExePath;
  Opts.MapPath          := FMapPath;
  Opts.RsmPath          := FRsmPath;
  Opts.SourceRoot       := FSourceRoot;
  Opts.ExtraSourcePaths := FExtraSourcePaths;
  Opts.Args             := ArgStr;
  Opts.StopAtEntry      := FStopAtEntry;
  Opts.Modules          := SessionModules;
  Opts.ExceptionRules      := ApplyExceptionRules(Args);
  Opts.ExceptionFilters    := FExceptionFilters;
  Opts.ExceptionFiltersSet := FExceptionFiltersSet;
  Opts.DelphiClassFilter   := FDelphiClassFilter;

  DapLog('Launching via session');
  try
    FSession.Launch(Opts);
  except
    on E: Exception do begin
      DapLog('Launch FAILED: ' + E.Message);
      FIO.SendErrorResponse(Seq, 'launch',
        Format('Cannot start "%s": %s', [FExePath, E.Message]));
      Exit;
    end;
  end;
  DapLog('Launch succeeded');
  FLaunched := True;
  // Addresses from a previous run mean nothing in this one (a fresh process,
  // rebased modules, a different stack), so no view carries over.
  SetLength(FMemoryViews, 0);
  FStartupDllCount := 0;
  FStartupMapCount := 0;
  FStartupTick     := GetTickCount64;
  FIO.SendResponse(Seq, 'launch', True);
  SendProgressStart('Starting ' + ExtractFileName(FExePath) + '...');
  SendConsoleLog(Format('[T+%dms] launch: %s', [GetTickCount64 - FAdapterStartTick, FExePath]));
  // Breakpoints that arrived before launch were delegated to FSession.SetBreakpoints
  // and buffered in the session's own pending list; FSession.Launch flushes them once
  // the engine is wired (ApplyPendingBreakpoints), so the DAP layer does nothing here.
end;

procedure TDapServer.HandleConfigurationDone(Seq: Integer);
begin
  FConfigDone := True;
  FIO.SendResponse(Seq, 'configurationDone', True);
  SendConsoleLog(Format('[T+%dms] configurationDone (%d setBreakpoints received)',
    [GetTickCount64 - FAdapterStartTick, FSetBpCount]));
end;

// VS Code's BREAKPOINTS view sends `setExceptionBreakpoints` whenever the
// user toggles a filter checkbox. Args.filters is an array of filter IDs
// that should be ENABLED; everything else is disabled. We translate those
// IDs into a TExceptionFilters set and forward to the debugger.
//
// `unhandled` is forced ON regardless of the user's choice -- silently
// swallowing a second-chance exception almost always wedges the program,
// and the DAP UI doesn't make the consequence obvious enough to trust.
function TDapServer.BuildExceptionFilterCapability: TJSONArray;

  procedure AddFilter(const Id, Label_: string; DefaultOn, SupportsCondition: Boolean;
    const ConditionDescription: string = '');
  var O: TJSONObject;
  begin
    O := TJSONObject.Create;
    O.AddPair('filter',  Id);
    O.AddPair('label',   Label_);
    O.AddPair('default', TJSONBool.Create(DefaultOn));
    if SupportsCondition then begin
      O.AddPair('supportsCondition', TJSONBool.Create(True));
      if ConditionDescription <> '' then
        O.AddPair('conditionDescription', ConditionDescription);
    end;
    Result.AddElement(O);
  end;

begin
  Result := TJSONArray.Create;
  AddFilter('delphi',    'Delphi-raised exceptions (first-chance)', True, True,
    'Comma-separated class names (e.g. EAccessViolation, EConvertError) -- empty = all');
  AddFilter('av',        'Access violations (first-chance)',        True, False);
  AddFilter('all',       'All first-chance exceptions',             False, False);
  AddFilter('unhandled', 'Unhandled / second-chance exceptions',    True, False);
end;

procedure TDapServer.HandleSetExceptionBreakpoints(Seq: Integer; Args: TJSONObject);
var
  Active: TExceptionFilters;
  DelphiCondition: string;

  procedure EnableById(const Id: string);
  begin
    if      SameText(Id, 'delphi')    then Include(Active, efDelphi)
    else if SameText(Id, 'av')        then Include(Active, efAccessViolation)
    else if SameText(Id, 'all')       then Include(Active, efAllFirstChance)
    else if SameText(Id, 'unhandled') then Include(Active, efUnhandled);
  end;

begin
  Active := [efUnhandled];
  DelphiCondition := '';
  var Arr := Args.FindValue('filters');
  if Arr is TJSONArray then
    for var I := 0 to TJSONArray(Arr).Count - 1 do
      EnableById(TJSONArray(Arr).Items[I].Value);
  // `filterOptions` is the richer form -- each entry is {filter, condition}.
  // VS Code sends BOTH `filters` (legacy IDs without condition) and
  // `filterOptions` (carrying conditions). Apply both.
  var Opts := Args.FindValue('filterOptions');
  if Opts is TJSONArray then
    for var I := 0 to TJSONArray(Opts).Count - 1 do begin
      var O := TJSONArray(Opts).Items[I] as TJSONObject;
      // DAP spec names the key `filterId`; VS Code sends that. Older test
      // clients used `filter`. Accept both so neither path silently no-ops.
      var Id   := O.GetValue<string>('filterId', '');
      if Id = '' then
        Id := O.GetValue<string>('filter', '');
      var Cond := O.GetValue<string>('condition', '');
      EnableById(Id);
      if SameText(Id, 'delphi') then DelphiCondition := Cond;
    end;
  // Cache for the Launch / Attach handler -- VS Code typically sends
  // setExceptionBreakpoints BEFORE launch, so FDebugger is still nil.
  FExceptionFilters    := Active;
  FExceptionFiltersSet := True;
  FDelphiClassFilter   := DelphiCondition;
  if FDebugger <> nil then begin
    FDebugger.SetExceptionFilters(Active);
    FDebugger.SetDelphiClassFilter(DelphiCondition);
  end;
  FIO.SendResponse(Seq, 'setExceptionBreakpoints', True);
end;

// VS Code issues `exceptionInfo` right after an exception stop to populate the
// details panel. Report the raised class as exceptionId, the Exception.Message
// as description, and echo both into `details` (typeName + message).
procedure TDapServer.HandleExceptionInfo(Seq: Integer; Args: TJSONObject);
var
  Body, Details: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    var ExcClass   := '';
    var ExcMessage := '';
    if FDebugger <> nil then begin
      ExcClass   := FDebugger.LastExceptionClass;
      ExcMessage := FDebugger.LastExceptionMessage;
    end;
    if ExcClass = '' then
      ExcClass := 'Exception';
    Body.AddPair('exceptionId', ExcClass);
    if ExcMessage <> '' then
      Body.AddPair('description', ExcMessage);
    Body.AddPair('breakMode', 'always');
    Details := TJSONObject.Create;
    Details.AddPair('typeName', ExcClass);
    if ExcMessage <> '' then
      Details.AddPair('message', ExcMessage);
    Body.AddPair('details', Details);
    FIO.SendResponse(Seq, 'exceptionInfo', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.HandleSetBreakpoints(Seq: Integer; Args: TJSONObject);
begin
  Inc(FSetBpCount);
  var SourceObj := Args.GetValue<TJSONObject>('source');
  SendConsoleLog(Format('[T+%dms] setBreakpoints #%d: %s',
    [GetTickCount64 - FAdapterStartTick, FSetBpCount,
     IfThen(SourceObj <> nil, SourceObj.GetValue<string>('path', '?'), '?')]));

  var SourcePath := '';
  if SourceObj <> nil then
    SourcePath := SourceObj.GetValue<string>('path', '');
  var FileName := FindSourceFile(SourcePath);

  // Remember the original request source path so a later `breakpoint` changed
  // event can carry a proper source object (the session tracks only basenames).
  FBpSourcePath.AddOrSetValue(LowerCase(FileName), SourcePath);

  // Parse the DAP request into the session's line-spec form. Empty strings for
  // metadata VS Code did not supply -- the session treats them as "no constraint".
  var Specs: TArray<TBpLineSpec>;
  var BpsArr := Args.GetValue<TJSONArray>('breakpoints');
  if BpsArr <> nil then
    for var Item in BpsArr do begin
      var IObj := Item as TJSONObject;
      var L := IObj.GetValue<Integer>('line', 0);
      if L <= 0 then Continue;
      var Sp: TBpLineSpec;
      Sp.Line         := L;
      Sp.Condition    := IObj.GetValue<string>('condition',    '');
      Sp.HitCondition := IObj.GetValue<string>('hitCondition', '');
      Sp.LogMessage   := IObj.GetValue<string>('logMessage',   '');
      Specs := Specs + [Sp];
    end;

  // Delegate plant + verify + pending to the session. It replaces the file's
  // breakpoint set, eager-loads symbols for already-loaded modules so a BP in an
  // attached BPL binds now, and returns one TSessionBreakpoint per line with the
  // resolved Verified flag and a stable 'file|line' id.
  var SessBps := FSession.SetBreakpoints(FileName, Specs);

  // Map to the DAP response, minting/reusing a stable NUMERIC id per session id so
  // VS Code (which correlates breakpoints by id) keeps the same marker across
  // resends. The later `breakpoint` changed event references this same numeric id.
  var Body := TJSONObject.Create;
  try
    var BpList := TJSONArray.Create;
    for var Bp in SessBps do begin
      var Id: Integer;
      if not FBpIds.TryGetValue(Bp.Id, Id) then begin
        Id := FNextBpId;
        Inc(FNextBpId);
        FBpIds.AddOrSetValue(Bp.Id, Id);
      end;
      var BpItem := TJSONObject.Create;
      BpItem.AddPair('id',       TJSONNumber.Create(Id));
      BpItem.AddPair('verified', TJSONBool.Create(Bp.Verified));
      BpItem.AddPair('line',     TJSONNumber.Create(Bp.Line));
      if SourceObj <> nil then
        BpItem.AddPair('source', SourceObj.Clone as TJSONObject);
      if not Bp.Verified then
        BpItem.AddPair('message', 'No debug info for this line');
      BpList.AddElement(BpItem);
    end;
    Body.AddPair('breakpoints', BpList);
    FIO.SendResponse(Seq, 'setBreakpoints', True, Body);
  finally
    Body.Free;
  end;
end;

// docs/DISASSEMBLY_PLAN.md increment 5: address breakpoints over DAP. Unlike
// `setBreakpoints` (scoped to one source file, other files untouched),
// `setInstructionBreakpoints` replaces the WHOLE address-breakpoint set on
// every call -- there is no file to scope by, an instruction reference is
// global. FInstrBpIds records exactly which session ids the PREVIOUS call
// planted, so this one can drop precisely those before (re)adding the new
// list, rather than a blind remove-everything that would also wipe an
// address breakpoint some OTHER path might have set.
procedure TDapServer.HandleSetInstructionBreakpoints(Seq: Integer; Args: TJSONObject);
type
  TInstrReq = record
    RawRef:               string;
    Addr:                 UInt64;
    AddrValid:             Boolean;
    Condition, HitCondition: string;
  end;
var
  Reqs: TArray<TInstrReq>;
begin
  var Items: TJSONArray := nil;
  if Args <> nil then
    Items := Args.GetValue<TJSONArray>('breakpoints');

  if Items <> nil then
    for var It in Items do begin
      var O := It as TJSONObject;
      var R: TInstrReq;
      R          := Default(TInstrReq);
      R.RawRef   := O.GetValue<string>('instructionReference', '');
      var Offset := O.GetValue<Integer>('offset', 0);
      var Base: UInt64;
      R.AddrValid := TryStrToUInt64Lit(Trim(R.RawRef), Base);
      if R.AddrValid then
        R.Addr := Base + UInt64(Offset);
      R.Condition    := O.GetValue<string>('condition',    '');
      R.HitCondition := O.GetValue<string>('hitCondition', '');
      Reqs := Reqs + [R];
    end;

  // Replace: drop every address breakpoint the PREVIOUS call planted before
  // adding this call's list, so a shrinking set actually shrinks.
  for var OldId in FInstrBpIds do
    FSession.RemoveAddressBreakpoint(OldId);
  SetLength(FInstrBpIds, 0);

  var Body := TJSONObject.Create;
  try
    var BpList := TJSONArray.Create;
    for var R in Reqs do begin
      var Item := TJSONObject.Create;
      if not R.AddrValid then begin
        Item.AddPair('verified', TJSONBool.Create(False));
        Item.AddPair('message', 'invalid instructionReference: ' + R.RawRef);
      end else begin
        var Bp := FSession.SetAddressBreakpoint(R.Addr, R.Condition, R.HitCondition, '');
        FInstrBpIds := FInstrBpIds + [Bp.Id];
        Item.AddPair('verified', TJSONBool.Create(Bp.Verified));
        Item.AddPair('instructionReference', '0x' + IntToHex(Bp.Address, 1));
        if not Bp.Verified and (Bp.Message <> '') then
          Item.AddPair('message', Bp.Message);
      end;
      BpList.AddElement(Item);
    end;
    Body.AddPair('breakpoints', BpList);
    FIO.SendResponse(Seq, 'setInstructionBreakpoints', True, Body);
  finally
    Body.Free;
  end;
end;

{ --------------------------- data breakpoints ------------------------------ }
// A `dataId` is adapter-private and round-trips through the client verbatim, so
// it must carry everything needed to re-derive the target: DAP's
// setDataBreakpoints request sends the id and an access type and NOTHING else --
// no address, no width, no frame.
//
// VS Code also PERSISTS data breakpoints in workspace state and re-sends them at
// the next launch, which is why the frame-scoped form is stamped with this run's
// nonce: an id naming a stack frame of a process that no longer exists is
// refused by name instead of being re-armed at whatever now lives there.
const
  DATA_ID_PREFIX = 'd1';

function TDapServer.EncodeDataId(const Info: TDataBpTargetInfo): string;
begin
  case Info.Kind of
    dbsGlobal:
      // By NAME, so it survives a relaunch and a rebased module: the address is
      // resolved again at set time.
      Result := Format('%s|g|%d|%s', [DATA_ID_PREFIX, Info.SizeBytes, Info.DisplayName]);
    dbsLocal:
      Result := Format('%s|l|%d|%s|%d|%x|%x|%x|%s',
        [DATA_ID_PREFIX, Info.SizeBytes, FDataBpNonce, Info.Frame.ThreadId,
         Info.Frame.FrameBase, Info.Frame.FuncEntryVA, Info.Address, Info.DisplayName]);
  else begin
    // module+RVA when the address falls inside a known image, a bare VA
    // otherwise -- same reasoning as an address breakpoint. The DISPLAY NAME
    // travels with it: a target that came from an expression must keep reading
    // as that expression at every hit, not as the hex address it resolved to.
    // '|' is the field separator, so it cannot survive inside a name.
    var Shown := StringReplace(Info.DisplayName, '|', '/', [rfReplaceAll]);
    if Info.ModuleName <> '' then
      Result := Format('%s|a|%d|%s|%x|%s', [DATA_ID_PREFIX, Info.SizeBytes,
        Info.ModuleName, Info.Rva, Shown])
    else
      Result := Format('%s|a|%d||%x|%s', [DATA_ID_PREFIX, Info.SizeBytes,
        Info.Address, Shown]);
  end;
  end;
end;

function TDapServer.DecodeDataId(const DataId: string; out Spec: TDataBpSpec;
  out Error: string): Boolean;

  function HexToU64(const S: string; out V: UInt64): Boolean;
  begin
    Result := TryStrToUInt64('$' + S, V);
  end;

begin
  Spec   := Default(TDataBpSpec);
  Error  := '';
  Result := False;
  var P := DataId.Split(['|']);
  if (Length(P) < 4) or (P[0] <> DATA_ID_PREFIX) then begin
    Error := 'unrecognised dataId (obtain one from dataBreakpointInfo)';
    Exit;
  end;
  Spec.SizeBytes := StrToIntDef(P[2], 0);
  if not (Spec.SizeBytes in [1, 2, 4, 8]) then begin
    Error := 'dataId carries an unsupported width';
    Exit;
  end;

  if P[1] = 'g' then begin
    Spec.Expression  := P[3];
    Spec.DisplayName := P[3];
    Exit(True);
  end;

  if P[1] = 'a' then begin
    if Length(P) < 5 then begin
      Error := 'malformed address dataId';
      Exit;
    end;
    var Raw: UInt64;
    if not HexToU64(P[4], Raw) then begin
      Error := 'malformed address in dataId';
      Exit;
    end;
    var Addr := Raw;
    if P[3] <> '' then begin
      var Found := False;
      for var M in FSession.GetModules do
        if SameText(M.Name, P[3]) then begin
          Addr  := M.Base + Raw;
          Found := True;
          Break;
        end;
      if not Found then begin
        Error := Format('module %s is not loaded, so this address cannot be resolved',
          [P[3]]);
        Exit;
      end;
    end;
    // The address is re-resolved from module+RVA, so the EXPRESSION handed to
    // the engine stays a literal -- an expression cannot be re-evaluated in a
    // frame that no longer exists. Only the name shown to the user survives.
    Spec.Expression  := Format('$%x', [Addr]);
    Spec.DisplayName := Spec.Expression;
    if (Length(P) >= 6) and (P[5] <> '') then
      Spec.DisplayName := P[5];
    Exit(True);
  end;

  if P[1] = 'l' then begin
    if Length(P) < 9 then begin
      Error := 'malformed local dataId';
      Exit;
    end;
    if P[3] <> FDataBpNonce then begin
      Error := 'this data breakpoint was created for a stack frame of an earlier ' +
        'debug session; select the variable again and set it anew';
      Exit;
    end;
    var Base, Entry, Addr: UInt64;
    if not (HexToU64(P[5], Base) and HexToU64(P[6], Entry) and HexToU64(P[7], Addr)) then begin
      Error := 'malformed frame data in dataId';
      Exit;
    end;
    Spec.Expression         := Format('$%x', [Addr]);
    Spec.DisplayName        := P[8];
    Spec.Frame.Scoped       := True;
    Spec.Frame.ThreadId     := StrToIntDef(P[4], 0);
    Spec.Frame.FrameBase    := Base;
    Spec.Frame.FuncEntryVA  := Entry;
    Exit(True);
  end;

  Error := 'unrecognised dataId kind';
end;

function TDapServer.DataBpIdFor(const DataId: string): Integer;
begin
  if FDataBpIds.TryGetValue(DataId, Result) then
    Exit;
  Result := FNextDataBpId;
  Inc(FNextDataBpId);
  FDataBpIds.AddOrSetValue(DataId, Result);
end;

procedure TDapServer.HandleDataBreakpointInfo(Seq: Integer; Args: TJSONObject);

  procedure Answer(const DataId, Description: string; Persist: Boolean;
    WithAccessTypes: Boolean);
  begin
    var Body := TJSONObject.Create;
    try
      if DataId = '' then
        Body.AddPair('dataId', TJSONNull.Create)
      else
        Body.AddPair('dataId', DataId);
      Body.AddPair('description', Description);
      if WithAccessTypes then begin
        // Exactly the two the hardware has. `read` is NOT listed: x86/x64 has no
        // read-only watchpoint, and offering it would advertise a filter that
        // cannot be applied -- the user would get write hits on a "read" break
        // and read it as a bug.
        var Acc := TJSONArray.Create;
        Acc.Add('write');
        Acc.Add('readWrite');
        Body.AddPair('accessTypes', Acc);
      end;
      Body.AddPair('canPersist', TJSONBool.Create(Persist));
      FIO.SendResponse(Seq, 'dataBreakpointInfo', True, Body);
    finally
      Body.Free;
    end;
  end;

begin
  MarkBusy('Delphi debugger: resolving watchpoint target...');
  EnsureMainRsm;
  var Name    := '';
  var VarsRef := 0;
  var FrameId := -1;
  var AsAddress := False;
  var Bytes     := 0;
  if Args <> nil then begin
    Name    := Args.GetValue<string>('name', '');
    VarsRef := Args.GetValue<Integer>('variablesReference', 0);
    if Args.FindValue('frameId') <> nil then
      FrameId := Args.GetValue<Integer>('frameId', 0);
    // DAP 1.66: the client asks for a watch on an ADDRESS it lets the user
    // type, with an explicit byte count. VS Code sends these only because the
    // adapter advertises supportsDataBreakpointBytes.
    AsAddress := Args.GetValue<Boolean>('asAddress', False);
    Bytes     := Args.GetValue<Integer>('bytes', 0);
  end;

  if not FLaunched or (FDebugger = nil) then begin
    Answer('', 'no debug session is running', False, False);
    Exit;
  end;

  if AsAddress and (Bytes > 0) and not (Bytes in [1, 2, 4, 8]) then begin
    Answer('', Format('%d bytes is not a width the debug registers can watch ' +
      '(1, 2, 4 or 8)', [Bytes]), False, False);
    Exit;
  end;

  // A register genuinely has no address, and an expansion handle (an object /
  // record child) does not carry one either -- the expander answers in values,
  // not addresses. Say which, instead of returning an address that is not the
  // variable's. Neither applies to the address form: it carries no
  // variablesReference at all, only text the user typed.
  if (not AsAddress) and (VarsRef = REGISTERS_VAR_REF) then begin
    Answer('', 'a CPU register has no memory address to watch', False, False);
    Exit;
  end;
  if (not AsAddress) and (VarsRef <> 0) and (VarsRef <> LOCALS_VAR_REF) then begin
    Answer('', 'watching a field of an expanded object or record is not supported ' +
      'yet -- the expansion handle carries no address. Watch the variable itself, ' +
      'or a global, instead', False, False);
    Exit;
  end;

  // The Locals scope sends the container ref and no frameId; the frame it means
  // is the one the scope was last opened for.
  var EffFrame := FrameId;
  if EffFrame < 0 then
    EffFrame := FLastScopeFrameId;
  if EffFrame < 0 then
    EffFrame := 0;

  var Info := FSession.GetDataBreakpointInfo(Name, EffFrame, FLastStackTid,
                AsAddress, Bytes);
  // GetDataBreakpointInfo selects the frame it resolves in and clears the
  // selection afterwards. HandleScopes deliberately LEAVES a frame selected, so
  // restore it: without this the next `variables` request on the Locals scope
  // would read the TOP frame's locals instead of the frame the user is on.
  FSession.SelectFrame(FLastScopeFrameId, FLastStackTid);
  if not Info.CanWatch then begin
    Answer('', Info.Reason, False, False);
    Exit;
  end;

  var Desc := Info.Description;
  if Info.ReadWriteCaveat <> '' then
    Desc := Desc + ' -- ' + Info.ReadWriteCaveat;
  // A frame-scoped local must NOT be persisted by the client: the frame it names
  // will not exist in the next session, and re-arming it there would watch
  // unrelated stack.
  Answer(EncodeDataId(Info), Desc, Info.Kind <> dbsLocal, True);
end;

procedure TDapServer.HandleSetDataBreakpoints(Seq: Integer; Args: TJSONObject);
type
  TReq = record
    DataId: string;
    Spec:   TDataBpSpec;
    Error:  string;   // '' = send this spec to the session
  end;
var
  Reqs: TArray<TReq>;
begin
  MarkBusy('Delphi debugger: arming watchpoints...');
  var Items: TJSONArray := nil;
  if Args <> nil then
    Items := Args.GetValue<TJSONArray>('breakpoints');

  if Items <> nil then
    for var It in Items do begin
      var O := It as TJSONObject;
      var R: TReq;
      R        := Default(TReq);
      R.DataId := O.GetValue<string>('dataId', '');
      var Access := O.GetValue<string>('accessType', 'write');
      if SameText(Access, 'read') then begin
        // Refused OUTRIGHT rather than silently promoted: there is no read-only
        // watchpoint on x86/x64, and quietly arming read-or-write would report a
        // "read" breakpoint that fires on writes.
        R.Error := 'no read-only watchpoint exists on x86/x64 -- use "readWrite" ' +
          '(it fires on reads AND writes)';
      end
      else if DecodeDataId(R.DataId, R.Spec, R.Error) then
        R.Spec.WriteOnly := not SameText(Access, 'readWrite');
      Reqs := Reqs + [R];
    end;

  // Arming reads and writes live thread contexts, which are only stable at a
  // stop. Gate here rather than letting the session refuse every entry with the
  // same sentence: a request that arrives while running would otherwise make
  // already-armed watchpoints look newly broken.
  var Running := (FDebugger = nil) or (FSession.State <> dsStopped);

  var Specs: TArray<TDataBpSpec>;
  var Slots: TArray<Integer>;   // index into Specs for each Req, -1 when not sent
  SetLength(Slots, Length(Reqs));
  for var I := 0 to High(Reqs) do begin
    Slots[I] := -1;
    if Running or (Reqs[I].Error <> '') then
      Continue;
    Slots[I] := Length(Specs);
    Specs    := Specs + [Reqs[I].Spec];
  end;

  var Results: TArray<TSessionDataBreakpoint>;
  if not Running then
    Results := FSession.SetDataBreakpoints(Specs);

  var Body := TJSONObject.Create;
  try
    var Arr := TJSONArray.Create;
    for var I := 0 to High(Reqs) do begin
      var Item := TJSONObject.Create;
      if Reqs[I].DataId <> '' then
        Item.AddPair('id', TJSONNumber.Create(DataBpIdFor(Reqs[I].DataId)));
      if Running then begin
        Item.AddPair('verified', TJSONBool.Create(False));
        Item.AddPair('message', 'data breakpoints can only be set while the target ' +
          'is stopped');
      end
      else if Reqs[I].Error <> '' then begin
        Item.AddPair('verified', TJSONBool.Create(False));
        Item.AddPair('message', Reqs[I].Error);
      end
      else begin
        var R := Results[Slots[I]];
        Item.AddPair('verified', TJSONBool.Create(R.Verified));
        if R.Message <> '' then
          Item.AddPair('message', R.Message);
      end;
      Arr.AddElement(Item);
    end;
    Body.AddPair('breakpoints', Arr);
    FIO.SendResponse(Seq, 'setDataBreakpoints', True, Body);
  finally
    Body.Free;
  end;
end;

// TDebugSession.OnDataBreakpointRemoved subscriber. The session retires a
// frame-scoped watchpoint the first time it stops and finds the owning frame
// gone. Removing it silently would be the worst outcome available -- the user
// would keep a breakpoint in the view that watches reused stack -- so this both
// SAYS so in the Debug Console and withdraws it from the client.
procedure TDapServer.SessionDataBreakpointRemoved(const Bp: TSessionDataBreakpoint;
  const Reason: string);
begin
  SendOutputEvent('[data breakpoint] ' + Reason + sLineBreak, 'console');
  DapLog('data breakpoint removed as stale: ' + Reason);
  // The dataId is not carried on the session record, so the numeric id is only
  // known when this watchpoint came through setDataBreakpoints in this run --
  // which is the only way a frame-scoped one can exist.
  for var Pair in FDataBpIds do begin
    var Spec: TDataBpSpec;
    var Err:  string;
    if not DecodeDataId(Pair.Key, Spec, Err) then
      Continue;
    if not Spec.Frame.Scoped then
      Continue;
    // Frame identity ALONE is not enough to pick the right id: two locals of the
    // same frame share it. The literal address in the decoded expression is what
    // separates them.
    if (Spec.Frame.FrameBase <> Bp.Frame.FrameBase) or
       (Spec.Frame.FuncEntryVA <> Bp.Frame.FuncEntryVA) or
       not SameText(Spec.Expression, Format('$%x', [Bp.Address])) then
      Continue;
    var EvBody := TJSONObject.Create;
    try
      var BpObj := TJSONObject.Create;
      BpObj.AddPair('id',       TJSONNumber.Create(Pair.Value));
      BpObj.AddPair('verified', TJSONBool.Create(False));
      BpObj.AddPair('message',  Reason);
      EvBody.AddPair('reason',     'removed');
      EvBody.AddPair('breakpoint', BpObj);
      FIO.SendEvent('breakpoint', EvBody);
    finally
      EvBody.Free;
    end;
    Break;
  end;
end;

procedure TDapServer.HandleContinue(Seq: Integer; Args: TJSONObject);
var
  Body: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('allThreadsContinued', TJSONBool.Create(True));
    FIO.SendResponse(Seq, 'continue', True, Body);
  finally
    Body.Free;
  end;
  if FLaunched then begin
    ReloadExceptionRuleFilesIfChanged;  // pick up rules-file edits made while stopped
    MarkBusy('Delphi debugger: running...', True);
    FSession.ContinueExecution;
  end;
end;

// The DAP next/stepIn/stepOut requests carry the thread the user selected. We
// report OS thread ids as the DAP thread ids, so Args.threadId IS the OS tid to
// step. Validate it against the live thread set and fall back to the stopped
// thread (0) for an unknown/placeholder id, matching HandleStackTrace.
function TDapServer.StepThreadFromArgs(Args: TJSONObject): DWORD;
begin
  Result := 0;
  if (Args = nil) or (Args.GetValue('threadId') = nil) then
    Exit;
  var Requested := DWORD(Args.GetValue<Int64>('threadId', 0));
  if Requested = 0 then
    Exit;
  for var Th in FSession.GetThreads do
    if Th.OsThreadId = Requested then
      Exit(Requested);
end;

function TDapServer.WantsInstructionGranularity(Args: TJSONObject): Boolean;
begin
  Result := (Args <> nil) and
    SameText(Args.GetValue<string>('granularity', ''), 'instruction');
end;

// The DECISION (decode, refuse, or choose trap-flag vs one-shot) happens
// inside TDebugSession.StepInstruction, synchronously, before this procedure
// answers the request. A True result has already POSTED the engine command
// that runs the plan on the Run thread -- the same split ASSEMBLY_LEVEL_
// DEBUGGING.md increment 1 built, just reached from the DAP thread instead of
// a test harness.
procedure TDapServer.HandleInstructionStep(Seq: Integer; const Cmd: string;
  Kind: TInstructionStepKind; Args: TJSONObject);
begin
  if not FLaunched then begin
    FIO.SendErrorResponse(Seq, Cmd, 'Not running');
    Exit;
  end;
  ReloadExceptionRuleFilesIfChanged;
  var RefusalReason: string;
  if not FSession.StepInstruction(Kind, StepThreadFromArgs(Args), RefusalReason) then begin
    FIO.SendErrorResponse(Seq, Cmd, RefusalReason);
    Exit;
  end;
  MarkBusy('Delphi debugger: step instruction...', True);
  FIO.SendResponse(Seq, Cmd, True);
end;

// A source-level step never refuses at an ordinary stop, so the response goes
// out first and the step runs behind it -- the long-standing behaviour, kept.
// At a first-chance EXCEPTION stop the step means "run to the handler that
// receives this exception", which CAN refuse (no decodable handler; a 32-bit
// try/finally or bare `except`, whose block address the registration record
// does not carry). There the decision is synchronous, so the response has to
// wait for it and a refusal reaches VS Code as a failed request carrying the
// reason -- the same ordering HandleInstructionStep uses, for the same reason.
procedure TDapServer.HandleSourceStep(Seq: Integer; const Cmd: string;
  Kind: TInstructionStepKind; Args: TJSONObject);
begin
  if not FLaunched then begin
    FIO.SendResponse(Seq, Cmd, True);
    Exit;
  end;
  ReloadExceptionRuleFilesIfChanged;
  var Busy := 'Delphi debugger: step over...';
  case Kind of
    iskInto: Busy := 'Delphi debugger: step into...';
    iskOut:  Busy := 'Delphi debugger: step out...';
  end;
  if FSession.StoppedOnUndeliveredException then begin
    var RefusalReason: string;
    var Ok := False;
    case Kind of
      iskOver: Ok := FSession.StepOver(StepThreadFromArgs(Args), RefusalReason);
      iskInto: Ok := FSession.StepInto(StepThreadFromArgs(Args), RefusalReason);
      iskOut:  Ok := FSession.StepOut (StepThreadFromArgs(Args), RefusalReason);
    end;
    if not Ok then begin
      FIO.SendErrorResponse(Seq, Cmd, RefusalReason);
      Exit;
    end;
    MarkBusy('Delphi debugger: running to the exception handler...', True);
    FIO.SendResponse(Seq, Cmd, True);
    Exit;
  end;
  FIO.SendResponse(Seq, Cmd, True);
  MarkBusy(Busy, True);
  case Kind of
    iskOver: FSession.StepOver(StepThreadFromArgs(Args));
    iskInto: FSession.StepInto(StepThreadFromArgs(Args));
    iskOut:  FSession.StepOut (StepThreadFromArgs(Args));
  end;
end;

procedure TDapServer.HandleNext(Seq: Integer; Args: TJSONObject);
begin
  if WantsInstructionGranularity(Args) then begin
    HandleInstructionStep(Seq, 'next', iskOver, Args);
    Exit;
  end;
  HandleSourceStep(Seq, 'next', iskOver, Args);
end;

procedure TDapServer.HandleStepIn(Seq: Integer; Args: TJSONObject);
begin
  if WantsInstructionGranularity(Args) then begin
    HandleInstructionStep(Seq, 'stepIn', iskInto, Args);
    Exit;
  end;
  HandleSourceStep(Seq, 'stepIn', iskInto, Args);
end;

procedure TDapServer.HandleStepOut(Seq: Integer; Args: TJSONObject);
begin
  if WantsInstructionGranularity(Args) then begin
    HandleInstructionStep(Seq, 'stepOut', iskOut, Args);
    Exit;
  end;
  HandleSourceStep(Seq, 'stepOut', iskOut, Args);
end;

procedure TDapServer.HandlePause(Seq: Integer; Args: TJSONObject);
begin
  FIO.SendResponse(Seq, 'pause', True);
  if FLaunched then begin
    MarkBusy('Delphi debugger: pausing...', True);
    FSession.Pause;
  end;
end;

// One line of the placeholder's disassembly section: the current-instruction
// marker, address, nearest symbol + offset (or an explicit "(no symbol)" --
// never blank, so a missing annotation cannot be mistaken for a formatting
// gap), the decoded mnemonic, and -- when the line table has one -- the source
// file and line for THIS instruction's own address, independently of whether
// the frame's own PC has one. When the file is named but cannot be resolved on
// disk, naming it plainly IS the actionable answer (docs/ASSEMBLY_LEVEL_DEBUGGING.md
// increment 5's "line known, file missing" case); when it resolves, the full
// path is shown so the reader knows disassembly was not the only option.
function TDapServer.FormatPlaceholderInstruction(const Ins: TDisasmInstruction;
  CurrentVA: UInt64): string;
begin
  var Marker := '   ';
  if Ins.VA = CurrentVA then
    Marker := '=> ';
  var SymPart := Ins.Symbol;
  if SymPart = '' then
    SymPart := '(no symbol)';
  Result := Format('%s0x%s  %-28s %s', [Marker, IntToHex(Ins.VA, 1), SymPart, Ins.Text]);
  if Ins.VA = CurrentVA then
    Result := Result + '   <-- current instruction';
  if Ins.SrcFile <> '' then begin
    var FullPath := ResolveSourcePath(Ins.SrcFile);
    if FullPath <> '' then
      Result := Result + Format('   ; %s:%d', [FullPath, Ins.SrcLine])
    else
      Result := Result + Format('   ; %s:%d (not found in the source path)',
        [Ins.SrcFile, Ins.SrcLine]);
  end;
end;

// The disassembly section of a sourceless frame's placeholder document
// (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 5). Deliberately the SAME mechanism
// HandleDisassemble (increment 6) uses -- the same byte reader
// (FDebugger.ReadCodeMemoryAt, which restores this debugger's own planted
// breakpoint bytes before decoding, never a raw read), the same backend, the
// same symbol/line lookups -- so what appears here is exactly what a real
// `disassemble` request would answer for this address, shown in the one place
// nothing else currently offers to. The backend is optional: when Zydis did
// not load, this names the REAL reason (Disasm.StatusText) and decodes
// nothing -- never a guessed listing, and never a claim of failure the
// backend did not actually report.
function TDapServer.BuildPlaceholderDisassembly(const F: TSessionFrame;
  out AnyLineShown: Boolean): string;
const
  INSTRS_BEFORE = 8;
  INSTRS_AFTER  = 16;   // includes the current instruction
begin
  AnyLineShown := False;
  if FDebugger = nil then
    Exit('Disassembly is unavailable: the debugger is not attached.');

  var Mode: TDisasmMachineMode;
  if FDebugger.TargetLayout.PointerSize = 8 then
    Mode := dmmLong64
  else
    Mode := dmmLegacy32;
  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      Result := Integer(FDebugger.ReadCodeMemoryAt(VA, Buf, NativeUInt(Size)));
    end;
  var Disasm: IDisassembler := TZydisDisassembler.Create(Mode, Reader, FDebugInfo,
    FDebugger.ImageBase, ResolveZydisDllPath);
  if not Disasm.Available then
    Exit('Disassembly is unavailable: ' + Disasm.StatusText + '.');

  var Lines: TArray<string> := nil;

  // Backward span: proven-boundary-only, exactly DisassembleBackward's own
  // contract -- no boundary or an unproven span simply means fewer (or zero)
  // "before" lines, never a guessed one.
  var BoundaryVA: UInt64;
  var HaveBoundary := FDebugger.NearestInstructionBoundaryBefore(F.IP, BoundaryVA);
  if not HaveBoundary then
    HaveBoundary := FDebugger.NearestExportedEntryBefore(F.IP, BoundaryVA);
  if HaveBoundary then begin
    var Before := DisassembleBackward(Disasm, BoundaryVA, F.IP, INSTRS_BEFORE);
    for var Ins in Before do begin
      if Ins.SrcFile <> '' then
        AnyLineShown := True;
      Lines := Lines + [FormatPlaceholderInstruction(Ins, F.IP)];
    end;
  end;

  // Forward span starts exactly at the frame's own PC, so the current
  // instruction is always the first forward line (and always present when
  // anything at all was readable).
  var Forward := Disasm.Disassemble(F.IP, INSTRS_AFTER);
  for var Ins in Forward do begin
    if Ins.SrcFile <> '' then
      AnyLineShown := True;
    Lines := Lines + [FormatPlaceholderInstruction(Ins, F.IP)];
  end;

  if Length(Lines) = 0 then
    Exit('No bytes could be read at this address; the memory here may be' +
      ' unmapped or protected.');

  Result := string.Join(sLineBreak, Lines);
end;

// Text of the placeholder document opened for a frame with no source. It exists
// to make a stop VISIBLE: without any `source` the client has nothing to bring
// forward, so stopping in sourceless code is indistinguishable from not stopping
// at all. Says which of the three reasons applies and what can be done about it,
// then shows the disassembly around the frame's PC -- real code, not just an
// explanation of its absence (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 5).
function TDapServer.SyntheticSourceText(const F: TSessionFrame): string;
const
  // This document opens in a plain text editor with no word wrap, so a long
  // line runs off the right edge and its end is never read. Prose is therefore
  // hard-wrapped. The disassembly block is deliberately NOT wrapped: its lines
  // are already short and column-aligned, and folding one would destroy the
  // alignment that makes it readable.
  PLACEHOLDER_WRAP_COL = 78;

  // A paragraph, wrapped and followed by a blank line. TrimRight keeps the
  // spacing independent of whether WrapText leaves a trailing break.
  function Para(const S: string): string;
  begin
    Result := TrimRight(WrapText(S, PLACEHOLDER_WRAP_COL)) +
      sLineBreak + sLineBreak;
  end;

begin
  var Reason: string;
  var Advice: string;
  case F.Symbols of
    saNoSymbols: begin
      Reason := 'no debug information of any kind was found for this module';
      Advice := 'If the module is yours, rebuild it with -V -VN -VR. System DLLs' +
                ' never have Delphi debug info and are expected here.';
    end;
    saIndexing: begin
      Reason := 'the symbol index for this module is still being built';
      Advice := 'Refresh the call stack in a moment -- this frame should resolve' +
                ' on its own once indexing finishes.';
    end;
    saLoaded: begin
      Reason := 'debug information was loaded, but it does not cover this address';
      Advice := 'The module''s symbol files may be older than the binary, or this' +
                ' code may come from a unit compiled without debug info. Rebuild' +
                ' the module and check the console for stale-symbol warnings.';
    end;
  else
    Reason := 'no loaded module owns this address';
    Advice := 'This is usually a frame the stack walker could not resolve.' +
              ' Frames below it may still be correct.';
  end;
  Result :=
    'No source available for this stack frame.' + sLineBreak + sLineBreak +
    Format('    Address : 0x%x', [F.IP]) + sLineBreak;
  if F.ModuleName <> '' then
    Result := Result + Format('    Module  : %s', [F.ModuleName]) + sLineBreak;
  if F.FunctionName <> '' then
    Result := Result + Format('    Function: %s', [F.FunctionName]) + sLineBreak;
  Result := Result + sLineBreak +
    Para('The debugger IS stopped here.') +
    Para('Why there is no source: ' + Reason + '.') +
    Para(Advice) +
    Para('Selecting a frame further down the call stack will open real source' +
      ' if any frame there has it.') +
    '------------------------------------------------------------------------' + sLineBreak +
    'Disassembly around the current instruction (=> marks it):' + sLineBreak +
    '------------------------------------------------------------------------' + sLineBreak;

  var AnyLineShown: Boolean;
  Result := Result + BuildPlaceholderDisassembly(F, AnyLineShown) + sLineBreak;

  // The line-table sentence is emitted ONLY when a line actually appeared. On a
  // module with no line information -- which is most of the frames that reach
  // this document -- explaining what the absent annotation would have meant is
  // noise next to a listing that plainly has none.
  if AnyLineShown then
    Result := Result +
      Para('A line shown above came from this module''s own line table; where' +
        ' none is shown, no line-number information exists for that' +
        ' instruction.');

  Result := Result +
    // Confirmed by hand in VS Code (2026-08-10): "Open Disassembly View" is
    // offered on the Call Stack frame as well as in the Command Palette, and
    // F10/F11 inside it step a single instruction. Naming it is therefore
    // accurate rather than a guess -- but the hedge stays for clients that are
    // not VS Code or a fork of it.
    Para('Where the editor offers one -- in VS Code, "Open Disassembly View" on' +
      ' this frame in the Call Stack, or the same entry in the Command Palette' +
      ' -- its Disassembly View shows more of this routine than this snippet,' +
      ' with gutter breakpoints, scrolling, and F10/F11 stepping one' +
      ' instruction at a time.');
end;

// Gives a sourceless frame a `source` backed by a sourceReference instead of a
// path, plus line 1, so the client has something to select and open.
procedure TDapServer.AttachPlaceholderSource(FO: TJSONObject;
  const F: TSessionFrame; const ALabel: string);
begin
  // Opted out via launch.json: emit no `source` at all and let the client decide
  // what a sourceless frame looks like. The stop may become invisible again --
  // that is the behaviour this document was built to replace, and the only way
  // to compare the two is to be able to turn it off.
  if not FNoSourcePlaceholder then
    Exit;

  var Src := TJSONObject.Create;
  Src.AddPair('name', ALabel);
  Src.AddPair('sourceReference', TJSONNumber.Create(SyntheticSourceRef(ALabel, F)));
  // NO presentationHint. `deemphasize` was set here first, to grey the entry and
  // keep it out of recent files -- and it defeated the entire point: VS Code
  // treats a deemphasized source as one the user is not meant to look at and
  // will NOT open it when the frame is focused, so the stop stayed just as
  // invisible as it was with no source at all. Verified in the field: the frame
  // label rendered as `0x76549F54 (kernelbase.dll: no symbols):1`, proving the
  // source WAS attached, while no editor ever appeared.
  if F.ModuleName <> '' then
    Src.AddPair('origin', F.ModuleName);
  FO.AddPair('source', Src);
  FO.AddPair('line',   TJSONNumber.Create(1));
  FO.AddPair('column', TJSONNumber.Create(1));
end;

// Registers (or reuses) a placeholder document for Label and returns its DAP
// sourceReference. Reused per label so the client can cache the content and so a
// long session does not mint a reference per stack request.
function TDapServer.SyntheticSourceRef(const ALabel: string; const F: TSessionFrame): Integer;
begin
  if FSynthSourceRefs.TryGetValue(ALabel, Result) then
    Exit;
  Result := FNextSynthSourceRef;
  Inc(FNextSynthSourceRef);
  FSynthSourceRefs.Add(ALabel, Result);
  FSynthSourceTexts.Add(Result, SyntheticSourceText(F));
end;

procedure TDapServer.HandleSource(Seq: Integer; Args: TJSONObject);
begin
  var Ref := 0;
  if Args <> nil then begin
    Ref := Integer(Args.GetValue<Int64>('sourceReference', 0));
    if Ref = 0 then begin
      var Src := Args.GetValue<TJSONObject>('source', nil);
      if Src <> nil then
        Ref := Integer(Src.GetValue<Int64>('sourceReference', 0));
    end;
  end;
  var Text: string;
  if not FSynthSourceTexts.TryGetValue(Ref, Text) then begin
    FIO.SendErrorResponse(Seq, 'source', Format('Unknown sourceReference %d', [Ref]));
    Exit;
  end;
  var Body := TJSONObject.Create;
  try
    Body.AddPair('content', Text);
    Body.AddPair('mimeType', 'text/plain');
    FIO.SendResponse(Seq, 'source', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.HandleStackTrace(Seq: Integer; Args: TJSONObject);
var
  Body:      TJSONObject;
  FrameArr:  TJSONArray;
begin
  if not FLaunched then begin
    FIO.SendErrorResponse(Seq, 'stackTrace', 'Not running');
    Exit;
  end;
  // Arm the busy spinner: a stackTrace that triggers a lazy DLL symbol load, or
  // the first cold source-path resolution, can run for a noticeable window.
  // Idempotent -- refreshes the period when one is already armed (post-stop burst).
  MarkBusy('Delphi debugger: building call stack...');
  // VS Code requests the stack of a specific thread (the id we reported in the
  // `threads` response). Default to the stopped thread when omitted, and keep it
  // when the id is not a live thread (a placeholder from a client that does not
  // track real thread ids).
  var ReqTid: Cardinal := FSession.GetStoppedThreadId;
  if (Args <> nil) and (Args.GetValue('threadId') <> nil) then begin
    var Requested := Cardinal(Args.GetValue<Int64>('threadId', Int64(ReqTid)));
    for var Th in FSession.GetThreads do
      if Th.OsThreadId = Requested then begin
        ReqTid := Requested;
        Break;
      end;
  end;
  // The session lazy-loads symbols for unresolved frame modules, trims the raise
  // plumbing for the stopped thread, and caches the stopped thread's frames so
  // SelectFrame/evaluate can re-root. A non-current thread id is a read-only walk.
  var Frames := FSession.GetCallStack(ReqTid);
  // Opt-in raw sweep, APPENDED below the walked frames and never interleaved
  // with them. It answers a different question -- "which of my routines has a
  // return address somewhere on this stack" -- for the case where the walk ends
  // in code with no unwind data. Each appended frame is marked in its name and
  // rendered subtle, because a raw hit may be a return address left by a call
  // that has already returned.
  //
  // They go into FLastFrames too, so a frameId still indexes one array and
  // selecting a raw frame is harmless: its FrameRBP is 0, so locals come back
  // empty rather than decoded from an unrelated frame.
  if FRawStackScan then begin
    var RawFrames := FSession.GetRawStackScan(ReqTid);
    for var R in RawFrames do begin
      var Appended := R;
      Appended.Index := Length(Frames);
      Frames := Frames + [Appended];
    end;
  end;
  FLastFrames   := Frames;   // cache so scopes/evaluate can map frameId -> frame
  FLastStackTid := ReqTid;   // ...and remember WHICH thread those indices belong to
  Body     := TJSONObject.Create;
  FrameArr := TJSONArray.Create;
  try
    for var I := 0 to High(Frames) do begin
      var F  := Frames[I];
      var FO := TJSONObject.Create;
      FO.AddPair('id', TJSONNumber.Create(I));
      // docs/DISASSEMBLY_PLAN.md increment 6: what enables "Open Disassembly View"
      // from the Call Stack. Emitted for every frame, including raw-scan hits
      // and nameless ones -- IP is always populated (TSessionFrame.IP), same
      // field McpJson.FrameListToJson already echoes as "address".
      FO.AddPair('instructionPointerReference', '0x' + IntToHex(F.IP, 1));
      // A raw hit must not be able to pass for a walked frame. Two independent
      // markers, because either one alone can be lost: the name carries it into
      // any log or copy-paste, and `subtle` greys it in the Call Stack view.
      var IsRaw := F.Origin in [foRawProven, foRawUnproven];
      if IsRaw then
        FO.AddPair('presentationHint', 'subtle');
      // DAP StackFrame.moduleId: the owning binary. Emitted whenever a module is
      // known -- including for frames that could not be named -- so the client can
      // always say WHERE the frame is, not just at which address.
      if F.ModuleName <> '' then
        FO.AddPair('moduleId', F.ModuleName);
      if F.SourceFile <> '' then begin
        var Src := TJSONObject.Create;
        Src.AddPair('name', ExtractFileName(F.SourceFile));
        var FullPath := ResolveSourcePath(F.SourceFile);
        if FullPath <> '' then
          Src.AddPair('path', FullPath);
        FO.AddPair('source', Src);
        FO.AddPair('line',   TJSONNumber.Create(F.SourceLine));
        FO.AddPair('column', TJSONNumber.Create(1));
        if F.FunctionName <> '' then
          FO.AddPair('name', RawStackLabel(F, F.FunctionName))
        else
          FO.AddPair('name', RawStackLabel(F,
            Format('%s:%d', [ExtractFileName(F.SourceFile), F.SourceLine])));
      end else if F.FunctionName <> '' then begin
        FO.AddPair('name', RawStackLabel(F, F.FunctionName));
        // No source line for this frame (publics-only module). If the unit
        // resolves to a file, attach a synthetic source so VS Code can select
        // the frame and open the Variables view (Locals / $exception / watches).
        var SynthPath: string;
        var SynthLine: Integer;
        if TrySyntheticUnitSource(F.FunctionName, SynthPath, SynthLine) then begin
          var SrcS := TJSONObject.Create;
          SrcS.AddPair('name', ExtractFileName(SynthPath));
          SrcS.AddPair('path', SynthPath);
          FO.AddPair('source', SrcS);
          FO.AddPair('line',   TJSONNumber.Create(SynthLine));
          FO.AddPair('column', TJSONNumber.Create(1));
        end else
          AttachPlaceholderSource(FO, F, F.FunctionName);
      end else begin
        var Nameless := NamelessFrameLabel(F);
        FO.AddPair('name', RawStackLabel(F, Nameless));
        AttachPlaceholderSource(FO, F, Nameless);
      end;
      FrameArr.AddElement(FO);
    end;
    Body.AddPair('stackFrames', FrameArr);
    Body.AddPair('totalFrames', TJSONNumber.Create(Length(Frames)));
    FIO.SendResponse(Seq, 'stackTrace', True, Body);
  finally
    Body.Free;
  end;
end;

{ ----------------------------- disassemble ---------------------------------
  docs/DISASSEMBLY_PLAN.md increment 6. Mirrors MCPDebugger\McpServer.pas'
  ResolveZydisDllPath/DefaultZydisDllPath exactly -- VisualStudioCodeDelphiDebugger.exe
  sits at the same three-levels-below-repo-root depth
  (VisualStudioCodeDelphiDebugger\Win64\<Config>\*.exe) as DelphiDebuggerMcp.exe
  (MCPDebugger\Win64\<Config>\*.exe), so the same relative fallback path finds
  the committed dev-build DLL. Kept as a local copy rather than shared: the two
  frontends are separate executables (see "Two frontends over one core" in
  docs/DAP_DEBUGGER_ARCHITECTURE.md), and increments 4/5 already duplicate small
  helpers like this one across them rather than introduce a shared unit for a
  few lines. }

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

function TDapServer.BuildDapInstruction(const Ins: TDisasmInstruction;
  ResolveSymbols: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('address', '0x' + IntToHex(Ins.VA, 1));
  var BytesStr := '';
  for var B in Ins.Bytes do begin
    if BytesStr <> '' then
      BytesStr := BytesStr + ' ';
    BytesStr := BytesStr + IntToHex(B, 2);
  end;
  Result.AddPair('instructionBytes', BytesStr);
  Result.AddPair('instruction', Ins.Text);   // 'db XX' when Zydis could not decode --
                                              // real bytes, just an unrecognised
                                              // encoding, never presentationHint 'invalid'
  if ResolveSymbols and (Ins.Symbol <> '') then
    Result.AddPair('symbol', Ins.Symbol);
  if Ins.SrcFile <> '' then begin
    var Src := TJSONObject.Create;
    Src.AddPair('name', ExtractFileName(Ins.SrcFile));
    var FullPath := ResolveSourcePath(Ins.SrcFile);
    if FullPath <> '' then
      Src.AddPair('path', FullPath);
    Result.AddPair('location', Src);
    Result.AddPair('line', TJSONNumber.Create(Ins.SrcLine));
  end;
end;

function TDapServer.BuildInvalidDapInstruction(Addr: UInt64): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('address', '0x' + IntToHex(Addr, 1));
  Result.AddPair('instruction', '??');
  Result.AddPair('presentationHint', 'invalid');
end;

// DAP `disassemble`: memoryReference + offset (bytes) + instructionOffset
// (instructions, can be negative) + instructionCount. The spec requires
// returning EXACTLY instructionCount entries, padding whatever cannot be
// decoded with an implementation-defined "invalid instruction" value
// (debugAdapterProtocol.json, DisassembleArguments.instructionCount) --
// BuildInvalidDapInstruction/presentationHint:'invalid' is this adapter's
// answer, and it is also how the proven-boundary-only backward-decode
// refusal from docs/DISASSEMBLY_PLAN.md's increment-4 decision reaches the
// client: never a partial or guessed decode presented as real, only fewer
// PROVEN entries with the rest clearly marked. A forward read that runs off
// mapped memory is padded the same way, for the same reason.
procedure TDapServer.HandleDisassemble(Seq: Integer; Args: TJSONObject);
var
  BaseAddr: UInt64;
  Disasm:   IDisassembler;

  // The FULL backward range [instructionOffset .. -1], ascending by address,
  // NegCount entries. Proven ones come from DisassembleBackward, which is
  // all-or-nothing for the SPAN it is asked to decode: when the natural chain
  // from the nearest proven boundary to BaseAddr is shorter than NegCount,
  // only its LATEST entries (closest to BaseAddr) are proven; the earlier
  // slots, closer to the boundary, have no proof at all and become invalid
  // placeholders anchored on the boundary's own genuinely proven address
  // (Proven[0].VA IS that boundary whenever it is the whole natural chain).
  // When no boundary exists at all, every slot is invalid, anchored on
  // BaseAddr itself.
  function BuildBackwardSlots(ResolveSymbols: Boolean; NegCount: Int64): TArray<TJSONObject>;
  var
    Proven:       TArray<TDisasmInstruction>;
    BoundaryVA:   UInt64;
    HaveBoundary: Boolean;
    Anchor:       UInt64;
    ProvenLen, InvalidLen: Int64;
  begin
    SetLength(Result, NegCount);
    HaveBoundary := FDebugger.NearestInstructionBoundaryBefore(BaseAddr, BoundaryVA);
    if not HaveBoundary then
      HaveBoundary := FDebugger.NearestExportedEntryBefore(BaseAddr, BoundaryVA);
    Proven := nil;
    if HaveBoundary then
      Proven := DisassembleBackward(Disasm, BoundaryVA, BaseAddr, NegCount);

    ProvenLen  := Length(Proven);
    InvalidLen := NegCount - ProvenLen;
    Anchor     := BaseAddr;
    if ProvenLen > 0 then
      Anchor := Proven[0].VA;
    for var I := 0 to InvalidLen - 1 do
      Result[I] := BuildInvalidDapInstruction(Anchor - UInt64(InvalidLen - I));
    for var I := 0 to ProvenLen - 1 do
      Result[InvalidLen + I] := BuildDapInstruction(Proven[I], ResolveSymbols);
  end;

  // PosCount entries starting PosSkip instructions after BaseAddr. A reader
  // that runs dry (unmapped memory) truncates per IDisassembler's own
  // contract; the missing tail is padded the same way as an unproven
  // backward slot -- a truncated forward read is just as unprovable as an
  // unproven backward span, and must never be guessed either.
  function BuildForwardSlots(ResolveSymbols: Boolean; PosSkip, PosCount: Int64): TArray<TJSONObject>;
  var
    Forward: TArray<TDisasmInstruction>;
    LastVA:  UInt64;
  begin
    SetLength(Result, PosCount);
    Forward := Disasm.Disassemble(BaseAddr, Integer(PosSkip + PosCount));
    LastVA := BaseAddr;
    if Length(Forward) > 0 then
      LastVA := Forward[High(Forward)].VA + UInt64(Forward[High(Forward)].Length);
    for var I := 0 to PosCount - 1 do begin
      var Idx := PosSkip + I;
      if Idx < Length(Forward) then
        Result[I] := BuildDapInstruction(Forward[Idx], ResolveSymbols)
      else
        Result[I] := BuildInvalidDapInstruction(LastVA + UInt64(Idx - Length(Forward)));
    end;
  end;

begin
  if (not FLaunched) or (FDebugger = nil) then begin
    FIO.SendErrorResponse(Seq, 'disassemble', 'Not running');
    Exit;
  end;
  if FSession.State <> dsStopped then begin
    FIO.SendErrorResponse(Seq, 'disassemble', 'Cannot disassemble while the debuggee is running');
    Exit;
  end;
  if Args = nil then begin
    FIO.SendErrorResponse(Seq, 'disassemble', 'Missing arguments');
    Exit;
  end;

  var MemRef := Args.GetValue<string>('memoryReference', '');
  var RefAddr: UInt64;
  if not TryStrToUInt64Lit(Trim(MemRef), RefAddr) then begin
    FIO.SendErrorResponse(Seq, 'disassemble', 'invalid memoryReference: ' + MemRef);
    Exit;
  end;
  var InstrCount := Args.GetValue<Int64>('instructionCount', 0);
  if InstrCount <= 0 then begin
    FIO.SendErrorResponse(Seq, 'disassemble', 'instructionCount must be > 0');
    Exit;
  end;
  var ByteOffset     := Args.GetValue<Int64>('offset', 0);
  var InstrOffset    := Args.GetValue<Int64>('instructionOffset', 0);
  var ResolveSymbols := Args.GetValue<Boolean>('resolveSymbols', True);
  BaseAddr := UInt64(Int64(RefAddr) + ByteOffset);

  var Mode: TDisasmMachineMode;
  if FDebugger.TargetLayout.PointerSize = 8 then
    Mode := dmmLong64
  else
    Mode := dmmLegacy32;
  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      Result := Integer(FDebugger.ReadCodeMemoryAt(VA, Buf, NativeUInt(Size)));
    end;
  Disasm := TZydisDisassembler.Create(Mode, Reader, FDebugInfo,
    FDebugger.ImageBase, ResolveZydisDllPath);
  if not Disasm.Available then begin
    FIO.SendErrorResponse(Seq, 'disassemble', 'disassembler unavailable: ' + Disasm.StatusText);
    Exit;
  end;

  var TrueNegCount: Int64 := 0;
  var PosSkip:       Int64 := 0;
  if InstrOffset < 0 then
    TrueNegCount := -InstrOffset
  else
    PosSkip := InstrOffset;
  var WantedBack := TrueNegCount;
  if WantedBack > InstrCount then
    WantedBack := InstrCount;
  var PosCount := InstrCount - WantedBack;

  var Slots: TArray<TJSONObject> := nil;
  if TrueNegCount > 0 then begin
    var FullBack := BuildBackwardSlots(ResolveSymbols, TrueNegCount);
    // Slots beyond WantedBack fall outside the requested window entirely
    // (a "far" backward request that never reaches BaseAddr) -- proven or
    // not, they are not part of the response and must not leak.
    for var I := WantedBack to TrueNegCount - 1 do
      FullBack[I].Free;
    Slots := Slots + Copy(FullBack, 0, WantedBack);
  end;
  if PosCount > 0 then
    Slots := Slots + BuildForwardSlots(ResolveSymbols, PosSkip, PosCount);

  var Body := TJSONObject.Create;
  try
    var InsArr := TJSONArray.Create;
    for var S in Slots do
      InsArr.AddElement(S);
    Body.AddPair('instructions', InsArr);
    FIO.SendResponse(Seq, 'disassemble', True, Body);
  finally
    Body.Free;
  end;
end;

// DAP `readMemory` (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3). Reuses the SAME
// engine primitive the MCP `read_memory` tool and `disassemble` already use
// (IDebugTarget.ReadCodeMemoryAt) -- not a second read path. That primitive
// restores the debugger's OWN planted INT3 bytes within the returned window
// (so a byte the user breakpointed reads back as their original code, not
// $CC) and TRUNCATES at the end of the committed VirtualQueryEx region
// instead of failing outright. A truncated read is reported as a PARTIAL
// success (`unreadableBytes`, the DAP spec's own mechanism for this), never
// as a request failure -- running off the end of a mapped region (the last
// page of the heap, an object near a guard page) is a normal thing to ask
// for, not a caller error. `data` is base64, per the DAP spec; encoded with
// TBase64StringEncoding (TNetEncoding.Base64String) specifically because the
// default TNetEncoding.Base64 wraps at 76 characters with embedded CRLFs,
// which is not what a JSON string field wants.
procedure TDapServer.HandleReadMemory(Seq: Integer; Args: TJSONObject);
const
  MAX_READ = 64 * 1024 * 1024;   // sanity guard against a malformed request, not a protocol limit
begin
  if (not FLaunched) or (FDebugger = nil) then begin
    FIO.SendErrorResponse(Seq, 'readMemory', 'Not running');
    Exit;
  end;
  if FSession.State <> dsStopped then begin
    FIO.SendErrorResponse(Seq, 'readMemory', 'Cannot read memory while the debuggee is running');
    Exit;
  end;
  if Args = nil then begin
    FIO.SendErrorResponse(Seq, 'readMemory', 'Missing arguments');
    Exit;
  end;

  var MemRef := Args.GetValue<string>('memoryReference', '');
  var RefAddr: UInt64;
  if not TryStrToUInt64Lit(Trim(MemRef), RefAddr) then begin
    FIO.SendErrorResponse(Seq, 'readMemory', 'invalid memoryReference: ' + MemRef);
    Exit;
  end;
  if Args.FindValue('count') = nil then begin
    FIO.SendErrorResponse(Seq, 'readMemory', 'Missing "count"');
    Exit;
  end;
  var Count := Args.GetValue<Int64>('count', 0);
  if Count < 0 then begin
    FIO.SendErrorResponse(Seq, 'readMemory', 'count must be >= 0');
    Exit;
  end;
  if Count > MAX_READ then begin
    FIO.SendErrorResponse(Seq, 'readMemory',
      Format('count %d exceeds the %d-byte guard', [Count, MAX_READ]));
    Exit;
  end;
  var ByteOffset := Args.GetValue<Int64>('offset', 0);
  var Addr := UInt64(Int64(RefAddr) + ByteOffset);

  var Body := TJSONObject.Create;
  try
    Body.AddPair('address', '0x' + IntToHex(Addr, 1));
    if Count > 0 then begin
      var Buf: TBytes;
      SetLength(Buf, Count);
      var Got := FDebugger.ReadCodeMemoryAt(Addr, @Buf[0], NativeUInt(Count));
      if Got > 0 then
        Body.AddPair('data', TNetEncoding.Base64String.EncodeBytesToString(Copy(Buf, 0, Got)));
      if UInt64(Got) < UInt64(Count) then
        Body.AddPair('unreadableBytes', TJSONNumber.Create(Count - Int64(Got)));
      // The request itself is how we learn a pane is open on this reference:
      // there is no DAP message for "the user opened a memory view".
      TrackMemoryView(MemRef, ByteOffset, Count);
    end;
    FIO.SendResponse(Seq, 'readMemory', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.TrackMemoryView(const MemRef: string; Offset, Count: Int64);
const
  // A hex pane reads its reference in chunks as the user scrolls, so entries are
  // per REFERENCE, not per chunk -- but a session that inspects many variables
  // would still grow this without a bound. Oldest out first.
  MAX_TRACKED_VIEWS = 32;
begin
  if (MemRef = '') or (Count <= 0) then
    Exit;
  for var I := 0 to High(FMemoryViews) do
    if SameText(FMemoryViews[I].MemRef, MemRef) then begin
      if Offset < FMemoryViews[I].Offset then
        FMemoryViews[I].Offset := Offset;
      if Offset + Count > FMemoryViews[I].EndOff then
        FMemoryViews[I].EndOff := Offset + Count;
      Exit;
    end;

  var V: TMemoryView;
  V.MemRef := MemRef;
  V.Offset := Offset;
  V.EndOff := Offset + Count;
  FMemoryViews := FMemoryViews + [V];
  if Length(FMemoryViews) > MAX_TRACKED_VIEWS then
    Delete(FMemoryViews, 0, Length(FMemoryViews) - MAX_TRACKED_VIEWS);
end;

// Human-readable answer to "what does the debugger have for this module".
// Names the FORMATS rather than saying yes/no: "TD32" and "MAP only" are
// different situations -- the second has no types and no locals -- and a view
// that flattened them to "symbols" would hide the reason a variable is missing.
function SymbolStatusText(const M: TSessionModule): string;
begin
  if Length(M.Formats) = 0 then begin
    // "still indexing" and "there is nothing" look identical in a list and mean
    // opposite things -- one is worth waiting for.
    if M.Symbols = saIndexing then
      Exit('indexing');
    Exit('no debug information');
  end;
  Result := '';
  for var F in M.Formats do begin
    if Result <> '' then
      Result := Result + ', ';
    // Spelled as the file extension a user would look for on disk, except TD32,
    // which is a section INSIDE the binary and has no file of its own.
    if SameText(F, 'td32') then Result := Result + 'TD32 (embedded)'
    else                        Result := Result + '.' + LowerCase(F);
  end;
end;

procedure TDapServer.HandleModules(Seq: Integer; Args: TJSONObject);
begin
  var Modules := FSession.GetModules;

  // DAP paging. A client may ask for a window; omitting both is "everything",
  // which is what every client this adapter has met actually does.
  var Start := 0;
  var Count := Length(Modules);
  if Args <> nil then begin
    Start := Args.GetValue<Integer>('startModule', 0);
    var Requested := Args.GetValue<Integer>('moduleCount', 0);
    if Requested > 0 then
      Count := Requested;
  end;
  if Start < 0 then
    Start := 0;
  if Start + Count > Length(Modules) then
    Count := Length(Modules) - Start;
  if Count < 0 then
    Count := 0;

  var Arr := TJSONArray.Create;
  for var I := Start to Start + Count - 1 do begin
    var M := Modules[I];
    var O := TJSONObject.Create;
    // The name IS the identity here: the engine keys its module table by
    // lowercase file name, and a client that acts on a row (setting a module
    // breakpoint, opening its debug info) has to name the same thing.
    O.AddPair('id',   M.Name);
    O.AddPair('name', M.Name);
    if M.Path <> '' then
      O.AddPair('path', M.Path);
    O.AddPair('symbolStatus', SymbolStatusText(M));
    O.AddPair('addressRange', '0x' + IntToHex(M.Base, 1));
    // Beyond the spec, because the spec has no field for them and they are the
    // point of the view: WHICH formats, whether this is the executable itself,
    // and how big the image is.
    var Formats := TJSONArray.Create;
    for var F in M.Formats do
      Formats.Add(LowerCase(F));
    O.AddPair('delphiFormats', Formats);
    O.AddPair('delphiIsMain', TJSONBool.Create(M.IsMain));
    if M.Size > 0 then
      O.AddPair('delphiImageSize', TJSONNumber.Create(Int64(M.Size)));
    Arr.AddElement(O);
  end;

  var Body := TJSONObject.Create;
  try
    Body.AddPair('modules', Arr);
    Body.AddPair('totalModules', TJSONNumber.Create(Length(Modules)));
    FIO.SendResponse(Seq, 'modules', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.EmitModulesChanged;
begin
  FIO.SendEvent('delphiModulesChanged');
end;

procedure TDapServer.RememberMemoryExtent(const MemRef: string;
  Address, Size: UInt64; const Name, TypeName: string);
begin
  if MemRef = '' then
    Exit;
  var E: TMemoryExtent;
  E.Address  := Address;
  E.Size     := Size;
  E.Name     := Name;
  E.TypeName := TypeName;
  FMemoryExtents.AddOrSetValue(MemRef, E);
end;

procedure TDapServer.HandleMemoryExtent(Seq: Integer; Args: TJSONObject);
begin
  var MemRef := '';
  if Args <> nil then
    MemRef := Trim(Args.GetValue<string>('memoryReference', ''));

  var Body := TJSONObject.Create;
  try
    var E: TMemoryExtent;
    if (MemRef <> '') and FMemoryExtents.TryGetValue(MemRef, E) then begin
      Body.AddPair('memoryReference', MemRef);
      Body.AddPair('address', '0x' + IntToHex(E.Address, 1));
      Body.AddPair('name',    E.Name);
      Body.AddPair('type',    E.TypeName);
      // `size` is present only when it was established. A view that draws an
      // extent must be able to tell "this value is 4 bytes" from "nobody
      // knows", and a 0 it has to interpret is not that distinction.
      if E.Size > 0 then
        Body.AddPair('size', TJSONNumber.Create(Int64(E.Size)))
      else
        Body.AddPair('sizeUnknown', TJSONBool.Create(True));
    end
    else
      Body.AddPair('unknownReference', TJSONBool.Create(True));
    FIO.SendResponse(Seq, 'delphiMemoryExtent', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.HandleSafelist(Seq: Integer; const Cmd: string;
  Args: TJSONObject);
begin
  if SameText(Cmd, 'delphiSafelistReload') then begin
    FSession.SafelistReload;
    FIO.SendResponse(Seq, Cmd, True);
    Exit;
  end;

  // The key comes EITHER pre-built (a row that carried it) OR as an
  // `expression`, which is how the VS Code context menu reaches here: VS Code
  // propagates a variable's standard fields (evaluateName) into the command but
  // NOT custom ones, so the frontend cannot hand back the key the row carried.
  // The session rebuilds it from the expression the same way the expansion does.
  var Key := '';
  if Args <> nil then begin
    Key := Trim(Args.GetValue<string>('key', ''));
    if Key = '' then begin
      var Expr := Trim(Args.GetValue<string>('expression', ''));
      if Expr <> '' then
        Key := FSession.SafelistKeyForExpression(Expr);
    end;
  end;

  if Key = '' then begin
    // Not a getter-backed property -- a field read needs no permission. Report
    // it as an unremarkable outcome, not an error the panel would surface.
    var B := TJSONObject.Create;
    try
      B.AddPair('applicable', TJSONBool.Create(False));
      FIO.SendResponse(Seq, Cmd, True, B);
    finally
      B.Free;
    end;
    Exit;
  end;

  if SameText(Cmd, 'delphiSafelistAdd') then
    FSession.SafelistAdd(Key, Args.GetValue<string>('verdict', '') = 'deny')
  else if SameText(Cmd, 'delphiSafelistRemove') then
    FSession.SafelistRemove(Key)
  else begin
    FIO.SendErrorResponse(Seq, Cmd, 'unknown safelist command');
    Exit;
  end;

  var Body := TJSONObject.Create;
  try
    Body.AddPair('userFile',
      TPath.Combine(DefaultSafelistUserDir, 'user.safelist.json'));
    FIO.SendResponse(Seq, Cmd, True, Body);
  finally
    Body.Free;
  end;

  // The decision changed while stopped: make the panel re-ask instead of
  // showing yesterday's deferral until the next stop.
  if FClientSupportsInvalidated and (FSession.State = dsStopped) then begin
    var Inv := TJSONObject.Create;
    try
      Inv.AddPair('areas', TJSONArray.Create(TJSONString.Create('variables')));
      FIO.SendEvent('invalidated', Inv);
    finally
      Inv.Free;
    end;
  end;
end;

procedure TDapServer.EmitMemoryChanged;
begin
  if not FClientSupportsMemoryEvent then
    Exit;
  for var V in FMemoryViews do begin
    var Body := TJSONObject.Create;
    try
      Body.AddPair('memoryReference', V.MemRef);
      Body.AddPair('offset', TJSONNumber.Create(V.Offset));
      Body.AddPair('count',  TJSONNumber.Create(V.EndOff - V.Offset));
      FIO.SendEvent('memory', Body);
    finally
      Body.Free;
    end;
  end;
end;

// DAP `writeMemory` (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3). Writing into a
// live debuggee is destructive and the caller is doing it deliberately, but a
// write that only PARTLY lands (the tail of the requested range crosses from
// writable into read-only/unmapped memory) must never be reported the same
// way as one that fully lands.
//
// `allowPartial` (DAP spec, WriteMemoryArguments) is the caller's explicit
// opt-in to that outcome:
//   - absent/false: the response is success:false whenever fewer than
//     Length(data) bytes actually landed. This is a REFUSAL, not a silent
//     no-op -- WriteMemoryPartial may already have written the bytes that
//     WERE writable before hitting the boundary (WriteProcessMemory is not
//     transactional), so the error message states exactly how many bytes
//     already changed rather than leaving the caller to assume nothing did.
//   - true: the response is success:true and the body's `bytesWritten`
//     reports exactly how many bytes landed (`offset` is always 0 -- this
//     adapter attempts one contiguous write starting at the requested
//     address; it never skips a leading unwritable span, only truncates a
//     trailing one, so the first attempted byte is always the first
//     requested byte).
procedure TDapServer.HandleWriteMemory(Seq: Integer; Args: TJSONObject);
begin
  if (not FLaunched) or (FDebugger = nil) then begin
    FIO.SendErrorResponse(Seq, 'writeMemory', 'Not running');
    Exit;
  end;
  if FSession.State <> dsStopped then begin
    FIO.SendErrorResponse(Seq, 'writeMemory', 'Cannot write memory while the debuggee is running');
    Exit;
  end;
  if Args = nil then begin
    FIO.SendErrorResponse(Seq, 'writeMemory', 'Missing arguments');
    Exit;
  end;

  var MemRef := Args.GetValue<string>('memoryReference', '');
  var RefAddr: UInt64;
  if not TryStrToUInt64Lit(Trim(MemRef), RefAddr) then begin
    FIO.SendErrorResponse(Seq, 'writeMemory', 'invalid memoryReference: ' + MemRef);
    Exit;
  end;
  if Args.FindValue('data') = nil then begin
    FIO.SendErrorResponse(Seq, 'writeMemory', 'Missing "data"');
    Exit;
  end;
  var DataStr      := Args.GetValue<string>('data', '');
  var ByteOffset   := Args.GetValue<Int64>('offset', 0);
  var AllowPartial := Args.GetValue<Boolean>('allowPartial', False);

  var Buf: TBytes;
  try
    Buf := TNetEncoding.Base64String.DecodeStringToBytes(DataStr);
  except
    on E: Exception do begin
      FIO.SendErrorResponse(Seq, 'writeMemory', 'invalid base64 data: ' + E.Message);
      Exit;
    end;
  end;

  var Addr := UInt64(Int64(RefAddr) + ByteOffset);
  var Written: NativeUInt := 0;
  if Length(Buf) > 0 then
    Written := FDebugger.WriteMemoryPartial(Addr, @Buf[0], NativeUInt(Length(Buf)));

  if (not AllowPartial) and (Written <> NativeUInt(Length(Buf))) then begin
    FIO.SendErrorResponse(Seq, 'writeMemory', Format(
      'write at 0x%x refused: only %d of %d bytes are writable there ' +
      '(%d bytes were already changed in the debuggee -- retry with allowPartial to accept this)',
      [Addr, Written, Length(Buf), Written]));
    Exit;
  end;

  var Body := TJSONObject.Create;
  try
    if AllowPartial then begin
      Body.AddPair('offset',       TJSONNumber.Create(0));
      Body.AddPair('bytesWritten', TJSONNumber.Create(Int64(Written)));
    end;
    FIO.SendResponse(Seq, 'writeMemory', True, Body);
  finally
    Body.Free;
  end;
  // The bytes under an open pane just changed, and this adapter is the only one
  // who knows -- the write went straight into the debuggee.
  TrackMemoryView(MemRef, ByteOffset, Length(Buf));
  EmitMemoryChanged;
end;

procedure TDapServer.HandleScopes(Seq: Integer; Args: TJSONObject);
  function MakeScope(const Name: string; VarRef: Integer): TJSONObject;
  begin
    Result := TJSONObject.Create;
    Result.AddPair('name',               Name);
    Result.AddPair('variablesReference', TJSONNumber.Create(VarRef));
    Result.AddPair('expensive',          TJSONBool.Create(False));
  end;
begin
  // Select the requested call-stack frame so the Locals scope resolves against
  // IT, not always the stopped top frame. frameId indexes the frames cached by
  // the last stackTrace (GetCallStack). The session clears the active frame
  // again on the next stop, so it never leaks across a resume (set-then-clear
  // discipline).
  //
  // A frameId that IS present is an explicit selection whatever its value, index
  // 0 included: at an exception stop frame 0 is the raise/fault site, and a
  // client asking for it gets that frame's locals -- empty, when it is OS code
  // with no frame pointer -- rather than a different frame's under its name. The
  // spec makes frameId mandatory here, so the absent branch is only reachable
  // from a non-conforming client; it means "no opinion" and takes the default.
  if Args <> nil then begin
    if Args.FindValue('frameId') <> nil then
      FLastScopeFrameId := Args.GetValue<Integer>('frameId', 0)
    else
      FLastScopeFrameId := DEFAULT_FRAME_INDEX;
    FSession.SelectFrame(FLastScopeFrameId, FLastStackTid);
  end;
  var Body     := TJSONObject.Create;
  var ScopeArr := TJSONArray.Create;
  try
    ScopeArr.AddElement(MakeScope('Locals',    LOCALS_VAR_REF));
    ScopeArr.AddElement(MakeScope('Registers', REGISTERS_VAR_REF));
    Body.AddPair('scopes', ScopeArr);
    FIO.SendResponse(Seq, 'scopes', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.SyncExpander;
begin
  FExpander.Debugger  := FDebugger;
  FExpander.DebugInfo := FDebugInfo;
  FExpander.TD32      := FLoader.MainTD32;
  FExpander.Rtti      := FRtti;
  FExpander.Readers   := Readers;
end;

function TDapServer.RefForHandle(H: TVarHandle): Integer;
begin
  if H = 0 then
    Exit(0);
  if FHandleToRef.TryGetValue(H, Result) then
    Exit;
  Result := FNextExpRef;
  FRefToHandle.Add(Result, H);
  FHandleToRef.Add(H, Result);
  Inc(FNextExpRef);
end;

procedure TDapServer.EmitVar(Arr: TJSONArray; const V: TSessionVariable);
begin
  var Item := TJSONObject.Create;
  Item.AddPair('name', V.Name);
  if V.EvaluateName <> '' then
    Item.AddPair('evaluateName', V.EvaluateName);
  if V.Kind = vkGroup then begin
    // Synthetic grouping row (`properties` / `event handlers` / `fields`):
    // empty value, virtual presentation hint, no type.
    Item.AddPair('value', '');
    var Hint := TJSONObject.Create;
    Hint.AddPair('kind', 'virtual');
    Item.AddPair('presentationHint', Hint);
  end else begin
    Item.AddPair('value', V.Value);
    Item.AddPair('type',  V.TypeName);
  end;
  Item.AddPair('variablesReference', TJSONNumber.Create(RefForHandle(V.Handle)));
  // `memoryReference` (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3): only when the
  // value genuinely lives at a known target address -- a stack local, a
  // class/record field, an array element. A register-resident local, a
  // synthetic group row ('properties'/'fields'), or a getter-produced value
  // carries V.Address = 0 and gets no reference. Omitted, never fabricated:
  // a wrong memoryReference opens VS Code's "View Binary Data" on a location
  // that has nothing to do with the value shown.
  //
  // DataAddress wins where it is set: a string, a dynamic array, a class
  // instance and an interface all occupy one POINTER, and a memory view opened
  // on that slot shows eight bytes of pointer rather than the characters or the
  // elements the user meant. See TDebugSession.PayloadAddress for which types
  // that covers and why a plain typed pointer is deliberately not among them.
  var MemRef := V.Address;
  if V.DataAddress <> 0 then
    MemRef := V.DataAddress;
  if MemRef <> 0 then begin
    var RefStr := '0x' + IntToHex(MemRef, 1);
    Item.AddPair('memoryReference', RefStr);
    RememberMemoryExtent(RefStr, MemRef, V.ValueSize, V.Name, V.TypeName);
  end;
  // Getter-backed property rows carry the safelist spelling, so the frontend's
  // "always evaluate" / "never" actions name exactly the member this row is.
  if V.SafelistKey <> '' then
    Item.AddPair('delphiSafelistKey', V.SafelistKey);
  Arr.AddElement(Item);
end;

// Shared builder for the `$exception` pseudo-variable. Returns False, with a
// Reason, when there is no exception in scope. On success: ValueStr =
// "Class: Message", ClassName = the raised class, VarRef = an expansion ref so
// the object's members can be drilled into.
//
// Two sources, in this order:
//   1. the stop itself, when it IS an exception stop -- the object of the raise
//      the debugger just reported;
//   2. otherwise the `except` block the PC is standing in, asked of the RTL's
//      own raise list. This is what keeps `$exception` alive for the WHOLE
//      handler instead of only at the instant of the raise. HandlerKind comes
//      back so the caller can honour the alias/`$exception` exclusion.
function TDapServer.BuildCurrentExceptionRef(out ValueStr, ClassName: string;
  out VarRef: Integer; out ObjAddr: UInt64;
  out HandlerKind: TExcHandlerBlockKind; out Reason: string): Boolean;
begin
  ValueStr    := '';
  ClassName   := '';
  VarRef      := 0;
  ObjAddr     := 0;
  HandlerKind := ehbNone;
  Reason      := '';
  Result      := False;
  if (FDebugger = nil) or (FRtti = nil) then begin
    Reason := 'no debug session';
    Exit;
  end;

  var ExcObj: UInt64 := 0;
  var FromStop := FStoppedOnException;
  if FromStop then
    ExcObj := FDebugger.CurrentExceptionObject
  else if not FDebugger.TryGetHandlerException(HandlerKind, ExcObj, Reason) then
    Exit;
  if (ExcObj < 65536) or not FRtti.IsClassInstance(ExcObj) then begin
    if Reason = '' then
      Reason := 'no live Delphi exception object';
    Exit;
  end;
  ObjAddr := ExcObj;

  // At an exception stop the recorded class and message describe exactly this
  // object. Reached through a handler they still do whenever the object is the
  // one that raise reported, which is every case except a nested exception
  // that has already been handled -- there the VMT is the only honest source,
  // and a class name with no message beats a message belonging to something
  // else.
  if FromStop or (ExcObj = FDebugger.CurrentExceptionObject) then begin
    ClassName := FDebugger.LastExceptionClass;
    var Msg   := FDebugger.LastExceptionMessage;
    ValueStr  := ClassName;
    if Msg <> '' then
      ValueStr := ClassName + ': ' + Msg;
  end else begin
    ClassName := FRtti.GetInstanceClassName(ExcObj);
    ValueStr  := ClassName;
  end;

  // Mint an expansion for the live object (member table when the class is
  // known, else runtime RTTI) and map it to a DAP ref so the object's members
  // can be drilled into. The inline value already shows class+message.
  SyncExpander;
  VarRef := RefForHandle(FExpander.MakeClassExpansion(ExcObj, ClassName, '$exception'));
  Result := True;
end;

// Surfaces the live exception object as a synthetic `$exception` entry at the
// top of the Locals scope so it is inspectable (and expandable) without anyone
// having to know to type the name into Watch.
//
// Offered at an exception stop, and inside a BARE `except .. end` for as long
// as the stop stays in that block. NOT inside an `on X: ... do` clause: there
// the exception already has a source-level name and that name is listed as an
// ordinary local, so adding `$exception` beside it would show one object under
// two names in the same Locals scope.
procedure TDapServer.AppendExceptionLocal(Arr: TJSONArray);
var
  ValueStr, ClsName: string;
  VarRef: Integer;
  ObjAddr: UInt64;
  HandlerKind: TExcHandlerBlockKind;
  Reason: string;
begin
  if not BuildCurrentExceptionRef(ValueStr, ClsName, VarRef, ObjAddr,
           HandlerKind, Reason) then Exit;
  if HandlerKind = ehbOnClause then Exit;
  var Item := TJSONObject.Create;
  Item.AddPair('name',               '$exception');
  Item.AddPair('evaluateName',       '$exception');
  Item.AddPair('value',              ValueStr);
  Item.AddPair('type',               ClsName);
  Item.AddPair('variablesReference', TJSONNumber.Create(VarRef));
  // The live exception object's own address -- always genuine when
  // BuildCurrentExceptionRef succeeded (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 3).
  if ObjAddr <> 0 then
    Item.AddPair('memoryReference', '0x' + IntToHex(ObjAddr, 1));
  Arr.AddElement(Item);
end;


// The single formatting of a register row, shared by the `variables` listing and
// by the `setVariable` response. They must agree: VS Code replaces the row it
// already shows with whatever the setVariable response carries, so a response
// formatted differently -- or omitted -- rewrites the row into something else.
procedure DescribeRegister(const Reg: TRegisterValue; out AValue, AType: string);
begin
  if Reg.Size = 4 then begin
    AValue := Format('0x%.8x', [Reg.Value]);
    AType  := 'UInt32';
  end
  else begin
    AValue := Format('0x%.16x  (%d)', [Reg.Value, Reg.Value]);
    AType  := 'UInt64';
  end;
end;

procedure TDapServer.HandleVariables(Seq: Integer; Args: TJSONObject);
var
  Body:    TJSONObject;
  VarArr:  TJSONArray;
  Ref:     Integer;
begin
  // Arm the busy spinner: a standalone variables request (a tree expansion after
  // the post-stop window closed, or one whose EnsureMainRsm / lazy symbol load
  // blocks) would otherwise show no feedback. Idempotent -- refreshes the period
  // when one is already armed (post-stop burst).
  MarkBusy('Delphi debugger: reading variables...');
  EnsureMainRsm;
  SyncExpander;
  Ref  := 0;
  if Args <> nil then
    Ref := Args.GetValue<Integer>('variablesReference', 0);

  Body   := TJSONObject.Create;
  VarArr := TJSONArray.Create;
  try
    if FLaunched and (FDebugger <> nil) then begin
      case Ref of
        LOCALS_VAR_REF: begin
          AppendExceptionLocal(VarArr);  // $exception first, when stopped on a raise
          // The session builds each neutral row (value/type via the same
          // formatters, evaluateName = the local name so "Copy Value" /
          // drag-into-Watch round-trips through evaluate()) and classifies it
          // (class / Variant-array / dyn-array / record) attaching an opaque
          // expansion handle on the shared expander that RefForHandle maps.
          for var Sv in FSession.GetLocals do
            EmitVar(VarArr, Sv);
        end;
        REGISTERS_VAR_REF: begin
          // The session emits RIP..R15 (Size 8) then EFlags (Size 4) in that
          // order; keep the DAP formatting (16-hex + decimal for 64-bit,
          // 8-hex for the 32-bit EFlags) and the leaf variablesReference of 0.
          for var Reg in FSession.GetRegisters do begin
            var RegValue, RegType: string;
            DescribeRegister(Reg, RegValue, RegType);
            var Item := TJSONObject.Create;
            Item.AddPair('name', Reg.Name);
            Item.AddPair('value', RegValue);
            Item.AddPair('type',  RegType);
            Item.AddPair('variablesReference', TJSONNumber.Create(0));
            VarArr.AddElement(Item);
          end;
        end;
        else begin
          // Nested-expansion ref: map it back to the opaque handle and let the
          // shared engine enumerate the children (object/record fields, dyn-array
          // or Variant-array elements, property / event / getter nodes).
          var H: TVarHandle;
          if FRefToHandle.TryGetValue(Ref, H) then
            for var C in FExpander.GetChildren(H) do
              EmitVar(VarArr, C);
        end;
      end;
    end;
    Body.AddPair('variables', VarArr);
    FIO.SendResponse(Seq, 'variables', True, Body);
  finally
    Body.Free;
  end;
end;

// Formats a TExprValue for display, reusing the existing FormatLocalValue logic.
// Sends a DAP `output` event. Category is 'console' (debug-console pane) or
// 'stdout'/'stderr' for program output. Used by log-points and console logs.
procedure TDapServer.SendOutputEvent(const Text, Category: string);
var
  Body: TJSONObject;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('category', Category);
    Body.AddPair('output',   Text);
    FIO.SendEvent('output', Body);
  finally
    Body.Free;
  end;
end;

// Breakpoint condition / hit-count / logpoint decisions now live entirely in the
// session's HandleBpHit; logpoint text arrives here via OnSessionOutput(okDebugger).

// Heuristic: a TypeHint that looks like a Delphi class / interface name
// (starts with `T` or `I` followed by an uppercase letter). Used to gate
// the class-expansion branch in hover responses so we don't accidentally
// treat e.g. a `Pointer` or `string` field as a class.
procedure TDapServer.HandleEvaluate(Seq: Integer; Args: TJSONObject);
var
  Body:    TJSONObject;
  Expr:    string;
  ConfigDirs: TArray<string>;   // captured by WarmupSymbolProvidersForEvaluate

  function LeadingIdentifier(const S: string): string;
  begin
    var Name := Trim(S);
    Result := '';
    if Name = '' then
      Exit;
    if not CharInSet(Name[1], ['A'..'Z', 'a'..'z', '_']) then
      Exit;
    var I := 2;
    while (I <= Length(Name)) and CharInSet(Name[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
      Inc(I);
    Result := Copy(Name, 1, I - 1);
  end;

  function NormalizeFsPath(const S: string): string;
  begin
    Result := Trim(S).ToLower;
    Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
    Result := ExcludeTrailingPathDelimiter(Result);
  end;

  function IsUnderPath(const Candidate, Root: string): Boolean;
  begin
    if (Candidate = '') or (Root = '') then
      Exit(False);
    if SameText(Candidate, Root) then
      Exit(True);
    Result := Candidate.StartsWith(IncludeTrailingPathDelimiter(Root), True);
  end;

  procedure AddConfigDir(const PathOrFile: string);
  begin
    var P := NormalizeFsPath(PathOrFile);
    if P = '' then
      Exit;
    var D := P;
    if ExtractFileExt(D) <> '' then
      D := NormalizeFsPath(ExtractFileDir(D));
    if D = '' then
      Exit;
    for var Existing in ConfigDirs do
      if SameText(Existing, D) then
        Exit;
    ConfigDirs := ConfigDirs + [D];
  end;

  function IsUnderConfiguredDirs(const FullPath: string): Boolean;
  begin
    for var D in ConfigDirs do
      if IsUnderPath(FullPath, D) then
        Exit(True);
    Result := False;
  end;

  // On BPL-based apps the current stop can be in EXE code while the watched
  // global lives in another loaded package. Startup intentionally avoids eager
  // symbol loading for every module, so evaluate may initially miss. Warm the
  // relevant module providers lazily and retry once.
  function WarmupSymbolProvidersForEvaluate: Integer;
  begin
    Result := 0;
    // Nothing new can have loaded since the last full warm-up at this revision;
    // skip re-scanning every module (the dominant residual miss cost on a
    // large multi-module target where most watches resolve or are absent).
    if FEvalWarmupRan and (FDebugInfo.Revision = FLastEvalWarmupRevision) then
      Exit;

    var ExeDir := NormalizeFsPath(ExtractFileDir(FExePath));
    var SourceRoot := NormalizeFsPath(FSourceRoot);

    SetLength(ConfigDirs, 0);
    for var Cfg in FModulesConfig do begin
      AddConfigDir(Cfg.Name);
      AddConfigDir(Cfg.MapPath);
      AddConfigDir(Cfg.RsmPath);
      AddConfigDir(Cfg.DcpPath);
    end;

    // This loop is the one genuinely O(N) symbol path in the adapter: on a host
    // whose launch config names a module in the shared BPL output directory,
    // every loaded package becomes eligible, and parsing them in-line was
    // measured at 7-55 s of uninterruptible dispatch-thread work. It is not
    // restructured here; what defuses it is that the prefetcher has normally
    // already loaded these modules at their LOAD_DLL event, so the Ensure* calls
    // below find everything registered and do nothing.
    for var Module in FLoader.Modules do begin
      var ShouldLoad := ModuleIsConfigured(Module.Name);
      if not ShouldLoad then begin
        var FullPath := NormalizeFsPath(Module.FullPath);
        ShouldLoad := IsUnderPath(FullPath, ExeDir) or
                      IsUnderPath(FullPath, SourceRoot) or
                      IsUnderConfiguredDirs(FullPath);
      end;
      if not ShouldLoad then
        Continue;

      var HadTd32 := Module.Td32Iface <> nil;
      var HadMap := Module.MapIface <> nil;
      var HadDcp := Module.DcpIface <> nil;

      FLoader.EnsureModuleTD32(Module);
      // Some package globals are only discoverable through MAP publics
      // (TD32 may not carry every data symbol), so evaluate warm-up must
      // load MAP even when TD32 is already available.
      FLoader.EnsureModuleMap(Module);
      FLoader.EnsureModuleDcp(Module);

      if ((not HadTd32) and (Module.Td32Iface <> nil)) or
         ((not HadMap) and (Module.MapIface <> nil)) or
         ((not HadDcp) and (Module.DcpIface <> nil)) then
        Inc(Result);
    end;

    FLastEvalWarmupRevision := FDebugInfo.Revision;
    FEvalWarmupRan := True;
    DapLog(Format('Evaluate fallback: warmed symbols for %d modules (configDirs=%d)',
      [Result, Length(ConfigDirs)]));
  end;

begin
  // A watch/hover evaluate can be slow (symbol warm-up). Arm the busy spinner so
  // even a standalone evaluate (no preceding step) shows activity; ProcessRequest's
  // FProcessing flag keeps it up for the whole evaluate, however long it takes.
  MarkBusy('Delphi debugger: evaluating...');
  Body := TJSONObject.Create;
  try
    EnsureMainRsm;
    SyncExpander;
    Expr := '';
    if Args <> nil then
      Expr := Args.GetValue<string>('expression', '');

    if (not FLaunched) or (FDebugger = nil) then begin
      Body.AddPair('result', '<not running>');
      Body.AddPair('variablesReference', TJSONNumber.Create(0));
      FIO.SendResponse(Seq, 'evaluate', True, Body);
      Exit;
    end;

    // `$exception` pseudo-variable: the live exception object at an exception
    // stop. Frame-independent, so resolve it before frame selection. Members
    // are reachable by expanding the returned reference (e.g. `.Message`).
    if SameText(Trim(Expr), '$exception') then begin
      var ValueStr, ClsName: string;
      var VarRef: Integer;
      var ObjAddr: UInt64;
      var HandlerKind: TExcHandlerBlockKind;
      var ExcReason: string;
      if BuildCurrentExceptionRef(ValueStr, ClsName, VarRef, ObjAddr,
           HandlerKind, ExcReason) then begin
        Body.AddPair('result', ValueStr);
        if ClsName <> '' then Body.AddPair('type', ClsName);
        Body.AddPair('variablesReference', TJSONNumber.Create(VarRef));
        if ObjAddr <> 0 then
          Body.AddPair('memoryReference', '0x' + IntToHex(ObjAddr, 1));
      end else begin
        // Two very different situations reached this branch with one message,
        // and the difference matters to whoever is reading it. `$exception` is
        // the Delphi exception OBJECT; at a first-chance HARDWARE fault that
        // object does not exist yet -- the RTL creates EAccessViolation and
        // friends only when its handler converts the SEH exception. Saying "no
        // current exception" there reads as "nothing happened" while the
        // debugger is stopped on precisely that exception.
        var NoExcText := '<no current exception>';
        if (FSession <> nil) and (FSession.StopReason = srException) and
           (FDebugger <> nil) and (not FDebugger.LastExceptionIsDelphiRaise) then
          NoExcText := '<hardware fault: no Delphi exception object exists yet --' +
            ' the RTL creates one only when it converts the fault. The fault''s' +
            ' class, address and message are in the stop reason and the Debug' +
            ' Console.>'
        else if ExcReason <> '' then
          // Away from an exception stop the honest answer is not "none" but
          // WHY none: on a 32-bit target the handler's extent is not derivable
          // at all, and a row that simply never appears is indistinguishable
          // from a bug.
          NoExcText := '<no exception in scope: ' + ExcReason + '>';
        Body.AddPair('result', NoExcText);
        Body.AddPair('variablesReference', TJSONNumber.Create(0));
      end;
      FIO.SendResponse(Seq, 'evaluate', True, Body);
      Exit;
    end;

    // Resolve the watch against the requested call-stack frame: a watch in a
    // selected (non-top) frame must read THAT frame's locals. The engine's
    // SetActiveFrame/ClearActiveFrame is applied inside FSession.EvaluateForFrame(Fid);
    // here we only pick the frame id -- it is also used below for the warm-up PC
    // and the miss-cache key, both of which stay frontend.
    // No frameId at all (a Debug Console expression typed with nothing selected)
    // is NOT the same as frameId 0: the session's default frame answers the
    // first, the top frame answers the second, and at an exception stop those
    // are different frames. DEFAULT_FRAME_INDEX is negative, so it falls through
    // every `Fid >= 0` / `Fid > 0` cache lookup below untouched.
    var Fid := DEFAULT_FRAME_INDEX;
    if (Args <> nil) and (Args.FindValue('frameId') <> nil) then
      Fid := Args.GetValue<Integer>('frameId', 0);

    // O(1) negative-result index. A bare identifier that fully misses stays a
    // miss for the same function at the same provider revision (locals are
    // function-scoped; globals/enums/consts are revision-stable), so a repeat
    // watch is a single lookup instead of re-running the whole resolution chain
    // (warm-up + ExprEval's global/enum/const tiers, each scanning big tables).
    // A module load bumps Revision and changes the key, so a newly-loadable
    // symbol is retried. Only bare single identifiers are cached; compound
    // expressions can have side effects / frame-sensitive values.
    var MissKey := '';
    if FDebugInfo <> nil then begin
      var BareId := LeadingIdentifier(Expr);
      var FuncKey: UInt64 := 0;
      if (Fid >= 0) and (Fid < Length(FLastFrames)) then
        FuncKey := FLastFrames[Fid].FuncEntryVA;
      if (BareId <> '') and SameText(BareId, Trim(Expr)) and (FuncKey <> 0) then begin
        MissKey := LowerCase(BareId) + '|' + IntToHex(FuncKey, 16) + '|' +
                   UIntToStr(FDebugInfo.Revision);
        var CachedMiss: string;
        if FEvalMissCache.TryGetValue(MissKey, CachedMiss) then begin
          Body.AddPair('result', CachedMiss);
          Body.AddPair('type', CachedMiss);
          Body.AddPair('variablesReference', TJSONNumber.Create(0));
          FIO.SendResponse(Seq, 'evaluate', True, Body);
          Exit;
        end;
      end;
    end;

    // For an identifier watch in a package frame, warm the frame-binary's
    // requires-closure so a global living in a required package (that the
    // debuggee never stopped in) is loaded and can win the uses-graph tier
    // over an unrelated module's same-named global. Cheap + idempotent;
    // no-op for main-exe frames.
    // Frame IP -- used by the requires-closure warm-up below AND the bounded
    // uses-scope warm-up on a miss further down.
    var WarmPC: UInt64 := 0;
    if (Fid > 0) and (Fid < Length(FLastFrames)) then
      WarmPC := FLastFrames[Fid].IP
    else if FDebugger.GetRegisters.Valid then
      WarmPC := FDebugger.GetRegisters.Rip;
    if (LeadingIdentifier(Expr) <> '') and (WarmPC <> 0) then
      WarmupRequiresClosureForPC(WarmPC);

    // Rich evaluate now lives in the session (shared with the MCP frontend):
    // FSession.EvaluateForFrame selects the frame, runs ExprEval, and applies the
    // full class/VMT/nil/variant-array decoration, returning a neutral result with
    // an expansion Handle. The performance layer stays HERE, unchanged: warm the
    // frame's requires-closure first, and on a miss warm its uses-scope (or fall
    // back to the un-scoped provider sweep) and retry the evaluate ONCE -- exactly
    // the ordering the inline code used, so watch latency on BPL is preserved.
    // A HOVER is not a request to execute anything: the user rested the mouse.
    // Property getters and parameterless routines are CALLED by the evaluator
    // by design (in Pascal a bare `Now` IS a call), so without this the mouse
    // alone could open a connection, write a log, or crash the target. The
    // Debug Console and the Watch panel keep the full behaviour, because there
    // the user asked.
    var AllowCalls := not SameText(Args.GetValue<string>('context', ''), 'hover');
    var R := FSession.EvaluateForFrame(Expr, Fid, FLastStackTid, AllowCalls);
    if (not R.IsValid) and (LeadingIdentifier(Expr) <> '') then begin
      // Bounded, scope-correct warm-up: load ONLY the frame's uses-scope (its unit
      // + its direct uses). A still-missing identifier there is genuinely out of
      // scope -> reject WITHOUT the multi-second brute-force sweep of every loaded
      // module. Fall back to the un-scoped sweep only when the uses graph is
      // unavailable for this frame (WarmupUsesScopeForFrame = False).
      {$Q-}
      var FrameRva: UInt64 := WarmPC - FDebugger.ImageBase;
      {$Q+}
      if (WarmPC <> 0) and WarmupUsesScopeForFrame(FrameRva) then
        R := FSession.EvaluateForFrame(Expr, Fid, FLastStackTid, AllowCalls)
      else if WarmupSymbolProvidersForEvaluate > 0 then
        R := FSession.EvaluateForFrame(Expr, Fid, FLastStackTid, AllowCalls);
    end;

    // Record a confirmed miss so the next identical watch is an O(1) lookup.
    if (MissKey <> '') and (not R.IsValid) then
      FEvalMissCache.AddOrSetValue(MissKey, R.Value);

    Body.AddPair('result', R.Value);
    if R.TypeName <> '' then
      Body.AddPair('type', R.TypeName);
    // `memoryReference` on a WATCH row, by the same rule the Variables view
    // follows (EmitVar): the payload address when the value is a reference,
    // the expression's own storage otherwise, and nothing at all for an rvalue.
    // Without it VS Code offers no "View Binary Data" on a watch, so the only
    // way to dump a string or an array was to find it in the Locals tree.
    var MemRef := R.Address;
    if R.DataAddress <> 0 then
      MemRef := R.DataAddress;
    if MemRef <> 0 then begin
      var RefStr := '0x' + IntToHex(MemRef, 1);
      Body.AddPair('memoryReference', RefStr);
      RememberMemoryExtent(RefStr, MemRef, R.ValueSize, Expr, R.TypeName);
    end;
    // The Handle was minted on the session's shared expander; map it to a DAP
    // int-ref via the same bimap the locals path uses (0 -> non-expandable).
    Body.AddPair('variablesReference', TJSONNumber.Create(RefForHandle(R.Handle)));
    FIO.SendResponse(Seq, 'evaluate', True, Body);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.HandleSetVariable(Seq: Integer; Args: TJSONObject);
// Thin DAP frontend over the session write path: parse the DAP request, pick
// the write target from the variablesReference scope, and delegate to the
// TDebugSession core (which owns the value encoders + the memory write). The
// core returns the refreshed {value,type} on success, or an error string (in
// NewValue) that we surface through the standard DAP error response.
var
  Body: TJSONObject;
  Ref: Integer;
  Name, ValStr, NewValue, NewType: string;
  Raw: UInt64;
begin
  EnsureMainRsm;
  SyncExpander;
  Body := TJSONObject.Create;
  try
    Ref := 0;
    Name := '';
    ValStr := '';
    if Args <> nil then begin
      Ref    := Args.GetValue<Integer>('variablesReference', 0);
      Name   := Args.GetValue<string>('name', '');
      ValStr := Args.GetValue<string>('value', '');
    end;

    if (not FLaunched) or (FDebugger = nil) then begin
      FIO.SendErrorResponse(Seq, 'setVariable', 'Not running');
      Exit;
    end;

    // Registers scope: a 64-bit integer written by name through the session.
    if Ref = REGISTERS_VAR_REF then begin
      if not TryStrToUInt64Lit(Trim(ValStr), Raw) then begin
        FIO.SendErrorResponse(Seq, 'setVariable',
          Format('Cannot parse "%s" as integer', [ValStr]));
        Exit;
      end;
      if not FSession.SetRegister(Name, Raw) then begin
        FIO.SendErrorResponse(Seq, 'setVariable',
          Format('Unknown register "%s"', [Name]));
        Exit;
      end;
      // Re-read rather than echo Raw: on a 32-bit target the register is
      // narrower than the value that was parsed, so what landed there is the
      // only truthful thing to show.
      var Written: TRegisterValue;
      if FSession.TryGetRegister(Name, Written) then begin
        var RegValue, RegType: string;
        DescribeRegister(Written, RegValue, RegType);
        Body.AddPair('value', RegValue);
        Body.AddPair('type',  RegType);
      end;
      FIO.SendResponse(Seq, 'setVariable', True, Body);
      Exit;
    end;

    // Nested-expansion ref: resolve the DAP int ref to the session's opaque
    // handle via the bimap, then delegate the writable-field write to the core.
    if Ref <> LOCALS_VAR_REF then begin
      var H: TVarHandle;
      if not FRefToHandle.TryGetValue(Ref, H) then begin
        FIO.SendErrorResponse(Seq, 'setVariable',
          Format('Unknown variablesReference %d', [Ref]));
        Exit;
      end;
      if FSession.SetFieldVariable(H, Name, ValStr, NewValue, NewType) then begin
        if NewValue <> '' then
          Body.AddPair('value', NewValue);
        if NewType <> '' then
          Body.AddPair('type', NewType);
        FIO.SendResponse(Seq, 'setVariable', True, Body);
        // The write landed in the debuggee; a pane open on those bytes is now
        // showing the old ones.
        EmitMemoryChanged;
      end
      else
        FIO.SendErrorResponse(Seq, 'setVariable', NewValue);
      Exit;
    end;

    // Locals scope (default): delegate to the session's local writer.
    if FSession.SetLocalVariable(Name, ValStr, NewValue, NewType) then begin
      if NewValue <> '' then
        Body.AddPair('value', NewValue);
      if NewType <> '' then
        Body.AddPair('type', NewType);
      FIO.SendResponse(Seq, 'setVariable', True, Body);
      EmitMemoryChanged;
    end
    else
      FIO.SendErrorResponse(Seq, 'setVariable', NewValue);
  finally
    Body.Free;
  end;
end;

procedure TDapServer.HandleDisconnect(Seq: Integer);
begin
  // Terminate BEFORE sending the response: the client's TDapClient.Disconnect
  // waits for the response, then immediately calls Stop -> TerminateProcess on
  // the adapter. If we send the response first, the adapter can be killed before
  // DebugActiveProcessStop runs, leaving the target's debug port in a dirty state
  // that prevents a later re-attach from receiving exception events (the planted
  // INT3 fires unhandled in the target instead of stopping the new debugger).
  if FLaunched then
    FSession.StopDebugging;  // terminate a launched target / detach an attached one
  FIO.SendResponse(Seq, 'disconnect', True);
  FQuit := True;
end;

procedure TDapServer.HandleThreads(Seq: Integer);
var
  Body:      TJSONObject;
  ThreadArr: TJSONArray;
begin
  Body      := TJSONObject.Create;
  ThreadArr := TJSONArray.Create;
  var Threads := FSession.GetThreads;
  // Empty list during initialize / before launch -- still return the
  // sentinel so VS Code's threads view does not error out.
  if Length(Threads) = 0 then begin
    var T := TJSONObject.Create;
    T.AddPair('id',   TJSONNumber.Create(1));
    T.AddPair('name', 'Main Thread');
    ThreadArr.AddElement(T);
  end
  else begin
    var StoppedTid := FSession.GetStoppedThreadId;
    var StoppedPresent := False;
    for var Th in Threads do begin
      var T := TJSONObject.Create;
      T.AddPair('id',   TJSONNumber.Create(Int64(Th.OsThreadId)));
      T.AddPair('name', Th.Name);
      ThreadArr.AddElement(T);
      if Th.OsThreadId = StoppedTid then
        StoppedPresent := True;
    end;
    // Ensure stoppedTid is in the list -- defensive guard if the kernel hands
    // us an event for a thread we have not seen a CREATE for yet, so a
    // following stackTrace(threadId) always references a known thread.
    if (StoppedTid <> 0) and not StoppedPresent then begin
      var T := TJSONObject.Create;
      T.AddPair('id',   TJSONNumber.Create(Int64(StoppedTid)));
      T.AddPair('name', FDebugger.GetThreadName(StoppedTid));
      ThreadArr.AddElement(T);
    end;
  end;
  Body.AddPair('threads', ThreadArr);
  FIO.SendResponse(Seq, 'threads', True, Body);
  Body.Free;
end;

procedure TDapServer.HandleGotoTargets(Seq: Integer; Args: TJSONObject);
begin
  var Src := Args.GetValue<TJSONObject>('source', nil);
  var Line := Args.GetValue<Integer>('line', 0);
  var VA: UInt64 := 0;
  // The session resolves the source file+line to a target VA through the full
  // provider chain; on any miss (no source, bad line, unknown line) reply with an
  // empty targets array, exactly as before.
  if (Src = nil) or (Line <= 0) or
     not FSession.GetGotoTargetVA(Src.GetValue<string>('path', ''), Line, VA) then begin
    var Empty := TJSONObject.Create;
    Empty.AddPair('targets', TJSONArray.Create);
    FIO.SendResponse(Seq, 'gotoTargets', True, Empty);
    Exit;
  end;
  var Target := TJSONObject.Create;
  Target.AddPair('id',    TJSONNumber.Create(Int64(VA)));
  Target.AddPair('label', Format('Line %d', [Line]));
  Target.AddPair('line',  TJSONNumber.Create(Line));
  var Targets := TJSONArray.Create;
  Targets.AddElement(Target);
  var Body := TJSONObject.Create;
  Body.AddPair('targets', Targets);
  FIO.SendResponse(Seq, 'gotoTargets', True, Body);
end;

procedure TDapServer.HandleGoto(Seq: Integer; Args: TJSONObject);
begin
  if not FLaunched then begin
    FIO.SendErrorResponse(Seq, 'goto', 'Not running');
    Exit;
  end;
  var TargetId := Args.GetValue<Int64>('targetId', 0);
  if TargetId = 0 then begin
    FIO.SendErrorResponse(Seq, 'goto', 'Invalid targetId');
    Exit;
  end;
  // The session moves RIP and invalidates its own cached/selected frame state
  // (guarded on dsStopped); a False result means the target was not stopped.
  if not FSession.SetInstructionPointer(UInt64(TargetId)) then begin
    FIO.SendErrorResponse(Seq, 'goto', 'Not stopped');
    Exit;
  end;
  // The RIP moved: the DAP-cached call stack from the last stackTrace is now
  // stale, so a scopes/evaluate issued before the client re-stacks resolves
  // against the (new) top frame instead of a pre-goto cached frame.
  SetLength(FLastFrames, 0);
  FIO.SendResponse(Seq, 'goto', True);
  var StopBody := TJSONObject.Create;
  StopBody.AddPair('reason',            'goto');
  var GotoTid: DWORD := FSession.GetStoppedThreadId;
  if GotoTid = 0 then GotoTid := 1;
  StopBody.AddPair('threadId',          TJSONNumber.Create(Int64(GotoTid)));
  StopBody.AddPair('allThreadsStopped', TJSONBool.Create(True));
  FIO.SendEvent('stopped', StopBody);
  // Set Next Statement does not itself write memory, but the client redraws
  // everything at this stop and a pane opened on a frame-local address is now
  // showing bytes from before the jump.
  EmitMemoryChanged;
end;

procedure TDapServer.ProcessRequest(Msg: TJSONObject);
var
  Seq:  Integer;
  Cmd:  string;
  Args: TJSONObject;
begin
  Seq  := Msg.GetValue<Integer>('seq', 0);
  Cmd  := Msg.GetValue<string>('command', '');
  Args := Msg.FindValue('arguments') as TJSONObject;

  // A message with no command is not a DAP request. Never answer it: an empty
  // success response (command:"") fed back in any loopback/echo condition is the
  // amplification vector that once produced a multi-million-line runaway log.
  if Cmd = '' then begin
    DapLog('ProcessRequest: ignoring message with empty command (seq=' + IntToStr(Seq) + ')');
    Exit;
  end;

  // Mark the adapter busy while this request runs, so a single slow request
  // (e.g. a multi-second watch evaluate) keeps the busy spinner up; the watchdog
  // only closes it once no request is in flight AND the idle window elapses.
  EnterCriticalSection(FOpLock);
  FProcessing := True;
  LeaveCriticalSection(FOpLock);
  try
  try
    if      Cmd = 'initialize'        then HandleInitialize(Seq, Args)
    else if Cmd = 'launch'            then HandleLaunch(Seq, Args)
    else if Cmd = 'attach'            then HandleAttach(Seq, Args)
    else if Cmd = 'configurationDone' then HandleConfigurationDone(Seq)
    else if Cmd = 'setBreakpoints'    then HandleSetBreakpoints(Seq, Args)
    else if Cmd = 'setInstructionBreakpoints' then HandleSetInstructionBreakpoints(Seq, Args)
    else if Cmd = 'setExceptionBreakpoints' then HandleSetExceptionBreakpoints(Seq, Args)
    else if Cmd = 'dataBreakpointInfo'  then HandleDataBreakpointInfo(Seq, Args)
    else if Cmd = 'setDataBreakpoints'  then HandleSetDataBreakpoints(Seq, Args)
    else if Cmd = 'exceptionInfo'     then HandleExceptionInfo(Seq, Args)
    else if Cmd = 'continue'          then HandleContinue(Seq, Args)
    else if Cmd = 'next'              then HandleNext(Seq, Args)
    else if Cmd = 'stepIn'            then HandleStepIn(Seq, Args)
    else if Cmd = 'stepOut'           then HandleStepOut(Seq, Args)
    else if Cmd = 'pause'             then HandlePause(Seq, Args)
    else if Cmd = 'stackTrace'        then HandleStackTrace(Seq, Args)
    else if Cmd = 'disassemble'       then HandleDisassemble(Seq, Args)
    else if Cmd = 'readMemory'        then HandleReadMemory(Seq, Args)
    else if Cmd = 'writeMemory'       then HandleWriteMemory(Seq, Args)
    else if Cmd = 'source'            then HandleSource(Seq, Args)
    else if Cmd = 'scopes'            then HandleScopes(Seq, Args)
    else if Cmd = 'variables'         then HandleVariables(Seq, Args)
    else if Cmd = 'evaluate'          then HandleEvaluate(Seq, Args)
    else if Cmd = 'setVariable'       then HandleSetVariable(Seq, Args)
    else if Cmd = 'threads'           then HandleThreads(Seq)
    else if Cmd = 'gotoTargets'       then HandleGotoTargets(Seq, Args)
    else if Cmd = 'goto'              then HandleGoto(Seq, Args)
    else if Cmd = 'disconnect'        then HandleDisconnect(Seq)
    else if Cmd = 'modules'           then HandleModules(Seq, Args)
    else if Cmd = 'delphiSetRawStackScan' then HandleSetRawStackScan(Seq, Args)
    else if Cmd = 'delphiMemoryExtent'    then HandleMemoryExtent(Seq, Args)
    else if Cmd.StartsWith('delphiSafelist') then HandleSafelist(Seq, Cmd, Args)
    // `cancel` is the one command worth tolerating as a no-op: the client is
    // abandoning a request, and answering "done" is honest whether or not that
    // request was still running. Everything else falls through to the refusal
    // below.
    else if Cmd = 'cancel'            then FIO.SendResponse(Seq, Cmd, True)
    else begin
      // Unknown command. The client MUST be answered -- an unanswered request
      // leaves it waiting forever -- but answering "success" with an empty body
      // is the wrong way to do it: a client that acts on that success sees a
      // silent no-op, the user presses something and nothing happens, and there
      // is no error anywhere. An error response unblocks the client just as
      // well and says what actually happened.
      //
      // Every optional request this adapter does not implement (`terminate`,
      // `restart`, `restartFrame`, `stepBack`, `reverseContinue`,
      // `setFunctionBreakpoints`, `setExpression`, `completions`,
      // `loadedSources`, `breakpointLocations`, `terminateThreads`,
      // `stepInTargets`) is gated on a capability this adapter does not
      // advertise, so a compliant client never sends one and no user-visible
      // error toast can come of this.
      DapLog(Format('ProcessRequest: refusing unimplemented command "%s" (seq=%d)',
        [Cmd, Seq]));
      FIO.SendErrorResponse(Seq, Cmd,
        Format('"%s" is not implemented by this debug adapter. Its capability ' +
               'is not advertised, so nothing should be sending it.', [Cmd]));
    end;
  except
    // A handler that raises must still ANSWER the request: a logged-but-
    // unanswered request leaves the client waiting forever (e.g. a malformed
    // setBreakpoints without `arguments` used to AV here and time out the
    // client). The session itself survives.
    on E: Exception do begin
      DapLog(Format('EXCEPTION in handler "%s": %s: %s',
        [Cmd, E.ClassName, E.Message]));
      // The class and message alone do not say WHERE, and an adapter-internal
      // failure is exactly the case where that matters most.
      if E.StackTrace <> '' then
        DapLog('  raised at:'#13#10 + E.StackTrace);
      FIO.SendErrorResponse(Seq, Cmd,
        Format('Internal adapter error: %s', [E.Message]));
    end;
  end;
  finally
    EnterCriticalSection(FOpLock);
    FProcessing   := False;
    FLastBusyTick := GetTickCount64;
    LeaveCriticalSection(FOpLock);
  end;
end;

procedure TDapServer.Run;
var
  StdinThread: TThread;
  MsgQueue:    TThreadedQueue<TJSONObject>;
  MsgArrived:  TEvent;
  Msg:         TJSONObject;
  QueueSize:   Integer;
begin
  MsgQueue := TThreadedQueue<TJSONObject>.Create(256, INFINITE, 0);
  // Signalled by the stdin thread on every push. The idle branch below waits on
  // it instead of sleeping a flat 10 ms, so a request that arrives while the
  // adapter has nothing to do is picked up at once rather than up to 10 ms
  // later. Manual-reset, cleared at the top of each iteration before the drain,
  // so a push racing the drain can never be missed.
  MsgArrived := TEvent.Create(nil, True, False, '');
  try
    StdinThread := TThread.CreateAnonymousThread(
      procedure
      var
        M: TJSONObject;
      begin
        repeat
          M := FIO.ReadMessage;
          if M = nil then
            Break;
          // Cancel an in-flight synthetic evaluation the moment the user issues
          // a control command, so a slow or hung getter cannot keep the adapter
          // frozen behind it (the request itself is still queued and runs next).
          if (FDebugger <> nil) and FDebugger.RemoteCallInFlight then begin
            var Cmd := M.GetValue<string>('command', '');
            for var Ctl in ['next', 'stepIn', 'stepOut', 'continue', 'pause',
                            'disconnect', 'terminate'] do
              if SameText(Cmd, Ctl) then begin
                FDebugger.RequestAbortRemoteCall;
                Break;
              end;
          end;
          MsgQueue.PushItem(M);
          MsgArrived.SetEvent;
        until False;
        MsgQueue.DoShutDown;
        MsgArrived.SetEvent;
      end);
    StdinThread.FreeOnTerminate := True;
    StdinThread.Start;

    repeat
      if FQuit then
        Break;

      var DidWork := False;
      MsgArrived.ResetEvent;

      // Drain the incoming request queue FIRST (non-blocking). Handling pending
      // client requests before the 10ms debug-event poll below cuts up to ~10ms of
      // input latency per loop iteration during active stepping, and lets a step /
      // continue command a request just posted run THIS iteration (ProcessCommandQueue
      // executes at the top of ProcessOneEvent). Safe: the client only sends requests
      // in response to events already reported on a prior iteration, so nothing here
      // depends on a debug event still queued in the OS -- ProcessOneEvent drains
      // those immediately after.
      repeat
        var PopResult := MsgQueue.PopItem(QueueSize, Msg);
        if PopResult = wrTimeout then
          Break;
        if PopResult = wrAbandoned then begin
          DapLog('Run: stdin closed (wrAbandoned) -- sending terminated');
          FIO.SendEvent('terminated');
          FQuit := True;
          Break;
        end;
        try
          ProcessRequest(Msg);
        except
          on E: Exception do
            DapLog('EXCEPTION in ProcessRequest: ' + E.ClassName + ': ' + E.Message);
        end;
        Msg.Free;
        DidWork := True;
      until False;

      if FQuit then
        Break;

      // Process debug events (non-blocking, 10ms timeout inside). Runs AFTER the
      // drain so a just-posted step/continue command executes this same iteration.
      // It also throttles the loop; when it does not run (pre-launch / no engine)
      // the idle Sleep below prevents a 100% CPU busy-spin. Pump stays on THIS
      // (launch/dispatch) thread -- WaitForDebugEvent is thread-affine.
      if FLaunched and (FDebugger <> nil) then begin
        FSession.Pump;
        DidWork := True;
      end;

      if FQuit then
        Break;

      // Pump background symbol-loader registrations marshalled via TThread.Queue.
      // Runs on THIS (main) thread, so all FDebugInfo mutation stays single-threaded.
      if CheckSynchronize(0) then
        DidWork := True;

      // Nothing to do this iteration (no debugger events, empty queue): block
      // until the next request arrives, at most 10 ms, so an idle or orphaned
      // adapter does not spin a core at 100% and a request that arrives 1 ms
      // from now is not made to wait out a full sleep quantum.
      if not DidWork then
        MsgArrived.WaitFor(10);

      if FLaunched and FSession.HasExited then begin
        DapLog('Run: debuggee has exited');
        // Process any last items in queue
        Sleep(50);
        repeat
          var PR := MsgQueue.PopItem(QueueSize, Msg);
          if PR = wrTimeout then
            Break;
          if PR = wrAbandoned then
            Break;
          try
            ProcessRequest(Msg);
          finally
            Msg.Free;
          end;
        until False;
        Break;
      end;
    until False;
  finally
    MsgQueue.Free;
    MsgArrived.Free;
  end;
end;

procedure RunDapServer;
var
  Server: TDapServer;
begin
  Server := TDapServer.Create;
  try
    Server.Run;
  finally
    Server.Free;
  end;
end;

end.
