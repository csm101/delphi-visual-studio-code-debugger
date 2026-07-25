unit DebugSession;

// Frontend-neutral debugger core facade. Owns the debug engine (IDebugTarget),
// the aggregate debug-info set + symbol readers, the source resolver, the
// expression evaluator and value formatter, plus an explicit session state
// machine. Exposes SEMANTIC operations returning the neutral records in
// DebugSessionTypes -- no JSON, no DAP ids. Both the DAP frontend and the MCP
// frontend sit on this one core.
//
// Threading: the session does NOT own a thread. It is pumped cooperatively by a
// single host loop calling Pump (which must run on the same thread that called
// Launch/Attach, because WaitForDebugEvent is thread-affine). Stops/exits arrive
// during Pump via the engine callbacks and surface as OnSessionStopped /
// OnSessionExited plus a bumped StopGeneration (the async-wait signal).
//
// Symbol loading (main exe + runtime DLL/BPL sidecars) lives in the shared
// TModuleSymbolLoader (FLoader). Multi-module IS wired: FLoader.EnsureModuleForPC
// loads a module's symbols on demand -- called at each stop, for every unresolved
// call-stack frame (then the stack is re-walked so its lines resolve), and for
// every already-loaded module when a breakpoint is set. Modules with no Delphi
// sidecar stay address-only (nothing to resolve).

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Variants,
  System.Math, Winapi.Windows,
  DebugSessionTypes, DebugTarget, DebugInfoTypes, DebugInfoSet,
  MapFileReader, RsmFileReader, TD32FileReader, ModuleSymbolLoader,
  DelphiRtti, DelphiValueReaders, ExprEval, Win64Debugger, SourceResolver,
  VariableExpander, BreakpointEval, ExceptionRules, ValueEncoders, DapProtocol;

type
  TSessionStoppedEvent = procedure(const Info: TStopInfo) of object;
  TSessionExitedEvent  = procedure(ExitCode: Integer) of object;
  TSessionOutputEvent  = procedure(Kind: TOutputKind; const Text: string) of object;

  // Additive frontend hooks (all optional). Fired IN ADDITION to the session's
  // own handling, never replacing it -- a no-op when unsubscribed.
  TSessionDllLoadedEvent      = procedure(const Name, Path: string;
                                  Base, ImageSize: UInt64) of object;
  TSessionModuleSymbolsEvent  = procedure(Module: TModuleSymbols) of object;
  TSessionBpChangedEvent      = procedure(const SourceFile: string;
                                  Line: Integer; Verified: Boolean) of object;

  TDebugSession = class
  private
    // Engine + symbols.
    FDebugger:   IDebugTarget;
    FDebugInfo:  TDebugInfoSet;
    FLoader:     TModuleSymbolLoader;  // shared synchronous symbol/module loader
    FRtti:       TDelphiRtti;
    FReaders:    TDelphiValueReader;
    FResolver:   TSourceResolver;

    // Session config / state.
    FState:              TDebugSessionState;
    FStartedByAttach:    Boolean;
    FStopGeneration:     UInt64;
    FStoppedOnException: Boolean;
    FStopReason:         TStopReason;
    FStopTid:            Cardinal;
    // True while a NON-top call-stack frame is explicitly selected (SelectFrame).
    // Guards the exception-stop locals auto-retarget so an explicit selection wins.
    FFrameSelected:      Boolean;
    FExePath:            string;
    FMapPath:            string;
    FRsmPath:            string;
    FRsmDisabled:        Boolean;
    FLastFrames:         TArray<TStackFrame>;
    // Thread the cached frames belong to. A frame INDEX is only meaningful
    // together with its thread: the client can walk another thread's stack and
    // then select one of ITS frames, and pairing that index with the stopped
    // thread's cache would read another thread's RBP (wrong-thread locals).
    FLastFramesTid:      Cardinal;

    // Breakpoints.
    FBreakpoints: TList<TSessionBreakpoint>;
    FPendingBps:  TList<TBpSpec>;
    FBpSpecs:     TDictionary<string, TBpSpec>;   // lcase file -> last spec, for repost on module load
    FBpVerified:  TDictionary<string, Boolean>;   // 'lcasefile|line' -> last-known verified state, for flip detection

    // Launch/attach-configured runtime-module sidecar overrides (empty = today's
    // auto-discovery; applied in HandleDllLoaded).
    FModulesConfig: TArray<TSessionModuleConfig>;

    // Runtime-loaded modules (DLL/BPL) symbol management lives in FLoader.

    // Nested-variable-expansion engine (shared with the DAP frontend). Owns the
    // per-stop handle table; the session wires its symbol/reader deps + resets it.
    FExpander:   TVariableExpander;

    // Conditional / hit-count / logpoint breakpoint evaluation (shared engine).
    FBpEval:     TBpEvaluator;

    // Output ring buffers (MCP has no async channel -> drained on demand).
    FDebuggeeOutput: TList<string>;   // program stdout
    FDebuggerOutput: TList<string>;   // debugger-generated (logpoints, notices)

    // Events.
    FOnStopped: TSessionStoppedEvent;
    FOnExited:  TSessionExitedEvent;
    FOnOutput:  TSessionOutputEvent;
    FOnDllLoadedHook:           TSessionDllLoadedEvent;
    FOnModuleSymbolsLoadedHook: TSessionModuleSymbolsEvent;
    FOnBreakpointChanged:       TSessionBpChangedEvent;
    FOnSymbolsArrived:          TNotifyEvent;

    function  Readers: TDelphiValueReader;
    procedure SetState(NewState: TDebugSessionState);
    function  BuildAndWireDebugger(PreferredBase: UInt64): Boolean;
    procedure ApplyPendingBreakpoints;
    // Free + recreate-empty the symbol infrastructure so its memory-mapped files
    // (target .exe TD32 section, .rsm, BPL .dcp) are released on terminate/detach.
    procedure ReleaseSymbolProviders;
    function  ResolveEffectiveStop(const SourceFile: string; SourceLine: Integer;
                out EffFile: string; out EffLine: Integer): Boolean;
    function  FrameToSession(const F: TStackFrame; Index: Integer): TSessionFrame;
    function  LocalToSession(const LV: TLocalValue): TSessionVariable;
    // Closure body support (increment B1b): when stopped inside an anonymous method
    // (`...$ActRec.$0$Body`), the captured variables are FIELDS of the hidden Self
    // ($ActRec) object, not stack locals -- and no provider carries the anon proc's
    // stack locals. Surface the captured vars by locating Self in the frame and
    // reading its debug-info fields.
    function  IsAnonBodyFunc(const Fn: string): Boolean;
    // Finds the closure Self ($ActRec object) for the stopped frame by scanning the
    // param registers + RBP/RSP-relative slots for a VMT-valid object whose class is
    // an $ActRec activation record with debug-info members. False when not found.
    function  TryFindClosureSelf(out SelfAddr: UInt64; out ClassName: string): Boolean;
    procedure AppendClosureCapturedLocals(var Locals: TArray<TSessionVariable>);
    // Surface the anon method's own declared parameters (arg1..argN) from the
    // decoded signature + Win64 ABI home slots (no provider carries their slots).
    procedure AppendAnonMethodParams(var Locals: TArray<TSessionVariable>;
                const FnName, CloClass: string);
    function  FormatExprValue(const E: TExprValue): string;
    // setVariable shared encode+write: dispatch ValueStr to the byte encoders
    // (enum-by-name / enum-ordinal / primitive, each at the type's TRUE width)
    // or the string-allocation path, then write into the debuggee at TargetAddr.
    // False + ErrMsg on any failure; the caller surfaces ErrMsg verbatim.
    function  EncodeAndWriteValue(TargetAddr: UInt64;
                const TypeHint, ValueStr: string; out ErrMsg: string): Boolean;

    // Nested expansion lives in FExpander (VariableExpander); GetChildren and
    // LocalToSession delegate to it. SyncExpander pushes current deps into it.
    procedure SyncExpander;

    // Breakpoint condition/hit/logpoint eval lives in FBpEval (BreakpointEval).

    // Engine callbacks (match the IDebugTarget callback signatures).
    procedure HandleTargetStopped(Reason: TStopReason; const SourceFile: string;
                SourceLine: Integer);
    procedure HandleTargetExited(ExitCode: Integer);
    procedure HandleTargetOutput(const Text: string);
    function  HandleBpHit(const BP: TBreakpointRec): Boolean;
    procedure HandleDllLoaded(const Name, Path: string; Base, ImageSize: UInt64);
    procedure HandleDllUnloaded(const Name: string; Base: UInt64);

    // Fired by FLoader when a runtime module's symbols (its TD32 line table) load,
    // so breakpoints set before the module was present can re-post and bind.
    procedure HandleModuleSymbolsLoaded(Module: TModuleSymbols);
    // Default sink for the loader's user-facing console messages (symbol-load
    // notices, "no debug info" diagnostic, stale-file warnings). Routes them into
    // the session's debugger-output buffer + OnSessionOutput so a frontend that
    // does NOT override FLoader.OnConsole (the MCP server) still surfaces them via
    // get_debugger_output. The DAP frontend overrides OnConsole with its own sink.
    procedure HandleLoaderConsole(const Msg: string);
    function  HaveBreakpoints: Boolean;
    function  ModuleOwnsPendingBreakpoint(Module: TModuleSymbols): Boolean;
    // Re-evaluate the verified state of every stored spec's line; update the stored
    // breakpoint record (what ListBreakpoints reports) and fire OnBreakpointChanged
    // for each line that flipped to verified.
    procedure NotifyBreakpointFlips;
    procedure StoreVerifiedState(const BpId: string; Verified: Boolean);
    procedure ApplyModuleConfig(Module: TModuleSymbols; const AName, APath: string);
    // Registers everything the symbol prefetcher finished, and reposts
    // breakpoints once if anything arrived. No-op unless stopped.
    procedure PublishPrefetchedSymbols;
    // Guarded exception-filter/rule passthrough. No-op when FiltersSet=False and
    // Rules is empty, so a default config reproduces today's behaviour exactly.
    procedure ApplyExceptionConfig(FiltersSet: Boolean; Filters: TExceptionFilters;
                const DelphiFilter: string; const Rules: TArray<TExceptionRule>);
  public
    constructor Create;
    destructor Destroy; override;

    // Lifecycle.
    function  Launch(const Opts: TLaunchOptions): Boolean;
    function  Attach(Pid: Cardinal; KillOnDetach: Boolean;
                const Opts: TAttachOptions): Boolean;
    procedure Detach;      // leave the target running (dsDetached)
    procedure Terminate;   // kill the target (dsTerminated)
    procedure StopDebugging; // detach an attached session, terminate a launched one
    procedure Pump;        // process one debug event; must run on the launch thread

    // State.
    function  State: TDebugSessionState;
    function  HasExited: Boolean;
    function  StopGeneration: UInt64;
    // OS process id of the live debuggee (0 when there is none / after teardown).
    function  DebuggeeProcessId: Cardinal;

    // Control (return immediately; the resulting stop arrives via Pump).
    // NB: named ContinueExecution, not Continue -- a method named Continue would
    // shadow the loop-control keyword inside this class's own methods (a bare
    // `Continue;` in any loop here would silently CALL it and resume the target).
    procedure ContinueExecution;
    // ThreadId selects the thread to step (0 = the currently-stopped thread).
    // While the step runs, every other thread is frozen so only this one
    // advances (per-thread stepping); run control afterwards targets it.
    procedure StepOver(ThreadId: DWORD = 0);
    procedure StepInto(ThreadId: DWORD = 0);
    procedure StepOut(ThreadId: DWORD = 0);
    procedure Pause;

    // Breakpoints.
    function  SetBreakpoints(const SourceFile: string;
                const Specs: TArray<TBpLineSpec>): TArray<TSessionBreakpoint>;
    function  ListBreakpoints: TArray<TSessionBreakpoint>;
    procedure RemoveAllBreakpoints;
    // Re-post every stored spec to the engine and fire OnBreakpointChanged for any
    // line that just flipped to verified. Public so an out-of-band symbol load (the
    // DAP background loader registering providers directly) can drive rebind and the
    // single gutter re-colour path without duplicating the flip detection.
    procedure RepostBreakpoints;

    // Introspection (valid only when State = dsStopped).
    function  GetCallStack: TArray<TSessionFrame>; overload;
    // Per-thread call stack (read-only). Delegates to the engine's TID-scoped
    // stack walk; does NOT disturb the stopped thread's cached FLastFrames.
    function  GetCallStack(ThreadId: Cardinal): TArray<TSessionFrame>; overload;
    function  GetCurrentLocation(out FnName, SrcFile: string;
                out Line: Integer): Boolean;
    function  GetLocals: TArray<TSessionVariable>;
    function  GetVariable(const Name: string): TSessionVariable;
    function  GetChildren(Handle: TVarHandle): TArray<TSessionVariable>;
    function  Evaluate(const Expr: string): TSessionEvalResult;
    // Frame-scoped rich evaluate. Selects FrameIndex (clears after), runs the
    // expression evaluator, then applies the SAME value decoration the DAP
    // evaluate handler used to do inline: derive a class name from the runtime
    // VMT when the static type is missing, render nil-class globals as `nil`,
    // and mint an expansion handle for a class / record / Variant-array result
    // (Expandable + non-zero Handle, valid for the current stop generation).
    // No warm-up and no miss-cache live here -- those stay in the frontend, which
    // re-invokes this on a miss after warming the relevant module providers.
    // ThreadId qualifies FrameIndex (see SelectFrame); 0 = the cached thread.
    function  EvaluateForFrame(const Expr: string; FrameIndex: Integer;
                ThreadId: Cardinal = 0): TSessionEvalResult;
    function  GetExceptionDetails: TSessionExceptionInfo;
    function  Snapshot: TCompactSnapshot;

    // Exception break configuration. ParseExceptionFilters maps the wire names
    // ('delphi'/'av'/'all'/'unhandled') to the engine filter set; a frontend uses
    // it to fill TLaunchOptions.ExceptionFilters, or calls SetExceptionFilters to
    // change them on a live session. Returns False if there is no active debuggee.
    class function ParseExceptionFilters(const Names: TArray<string>): TExceptionFilters;
    function  SetExceptionFilters(const Names: TArray<string>;
                const DelphiClasses: string): Boolean;

    // Threads.
    function  GetThreads: TArray<TSessionThread>;
    function  GetStoppedThreadId: Cardinal;

    // Frame selection: re-root GetLocals/Evaluate/GetVariable on a caller frame.
    // SelectFrame(0) or ClearFrame restores the stopped top frame. A selected
    // frame MUST be cleared within the same request cycle -- the engine's active
    // frame is global and is cleared on the next stop, so leaving it set across a
    // resume silently reads the wrong frame's locals.
    procedure SelectFrame(Index: Integer); overload;
    // Select frame Index OF THREAD ThreadId. A frame index is only meaningful
    // together with its thread, so when ThreadId is not the thread the frame
    // cache belongs to, that thread's stack is walked first. ThreadId = 0 means
    // "whatever the cache already holds" (the plain overload).
    procedure SelectFrame(Index: Integer; ThreadId: Cardinal); overload;
    procedure ClearFrame;

    // Registers (stopped thread).
    function  GetRegisters: TArray<TRegisterValue>;
    function  SetRegister(const Name: string; Value: UInt64): Boolean;

    // Write paths (setVariable). Encode ValueStr at the target's TRUE storage
    // width, write it into the debuggee, then re-read for the refreshed display.
    // On success return True with NewValue/NewType set to the refreshed render;
    // on failure return False with NewValue carrying the human-readable error
    // text (NewType then empty) so a frontend can surface it verbatim.
    //   SetLocalVariable  -- a top-frame local resolved via EvaluateName; writes
    //     through the pointer for var/reference parameters (lkVarParam).
    //   SetFieldVariable  -- a writable backing field of an exRsmMembers class /
    //     record expansion handle (only those handles expose writable fields).
    function  SetLocalVariable(const Name, ValueStr: string;
                out NewValue, NewType: string): Boolean;
    function  SetFieldVariable(Handle: TVarHandle; const Name, ValueStr: string;
                out NewValue, NewType: string): Boolean;

    // Goto / set-next-statement. GetGotoTargetVA resolves a source file+line to a
    // target VA through the debug-info line table (basename-keyed, full provider
    // chain). SetInstructionPointer moves RIP to that VA (guarded on dsStopped) and
    // invalidates the cached/selected frame state, since the moved RIP makes the
    // last stack walk and any active frame stale.
    function  GetGotoTargetVA(const SourceFile: string; Line: Integer;
                out VA: UInt64): Boolean;
    function  SetInstructionPointer(VA: UInt64): Boolean;

    // Source-path resolution passthrough (search roots configured at Launch/Attach).
    function  ResolveSourcePath(const NameOrPath: string): string;
    // Lazily load the main module's .rsm type info (idempotent, latched).
    procedure EnsureMainRsm;

    // Output.
    function  DrainDebuggeeOutput: TArray<string>;
    function  DrainDebuggerOutput: TArray<string>;

    // Read-only access to the shared engines the session owns+frees, so a
    // frontend can drive nested expansion / symbol load / lookups directly.
    property Expander:  TVariableExpander  read FExpander;
    property Loader:    TModuleSymbolLoader read FLoader;
    property DebugInfo: TDebugInfoSet      read FDebugInfo;
    // The engine itself + its lazily-created RTTI reader and value reader, plus the
    // source resolver: read-only so a frontend can keep its introspection handlers
    // driving the single owned engine directly during the ownership-transfer phase.
    property Debugger:       IDebugTarget     read FDebugger;
    property Rtti:           TDelphiRtti      read FRtti;
    property SourceResolver: TSourceResolver  read FResolver;
    // Lazily create (if the process handle is available) and return the RTTI
    // reader. Idempotent; returns nil only when no process handle exists yet.
    function EnsureRtti: TDelphiRtti;
    // The shared leaf value reader (Variant / string decode / interface recovery),
    // refreshed to the current Debugger/Rtti on each call.
    function GetReaders: TDelphiValueReader;

    property OnSessionStopped: TSessionStoppedEvent read FOnStopped write FOnStopped;
    property OnSessionExited:  TSessionExitedEvent  read FOnExited  write FOnExited;
    property OnSessionOutput:  TSessionOutputEvent  read FOnOutput  write FOnOutput;
    // Additive module/breakpoint hooks (fired in addition to the session's own
    // handling). A frontend uses these to run its PACKAGEINFO-gated eager probe
    // and re-colour verified breakpoints; unsubscribed = no behaviour change.
    property OnDllLoadedHook: TSessionDllLoadedEvent
      read FOnDllLoadedHook write FOnDllLoadedHook;
    property OnModuleSymbolsLoadedHook: TSessionModuleSymbolsEvent
      read FOnModuleSymbolsLoadedHook write FOnModuleSymbolsLoadedHook;
    property OnBreakpointChanged: TSessionBpChangedEvent
      read FOnBreakpointChanged write FOnBreakpointChanged;
    // Fired from Pump, on the dispatch thread, when the background prefetcher has
    // just registered a module's symbol providers WHILE THE TARGET IS STOPPED.
    // Anything the client already rendered from the old provider set (a stack with
    // nameless frames above all) is now improvable, so a frontend uses this to push
    // a refresh -- the DAP sends `invalidated`. Unsubscribed = no behaviour change:
    // the provider-set revision has bumped either way, so the next request
    // recomputes regardless.
    property OnSymbolsArrivedWhileStopped: TNotifyEvent
      read FOnSymbolsArrived write FOnSymbolsArrived;
    // Diagnostic: what the loader knows about a runtime module RIGHT NOW, without
    // triggering any load. Used by the integration tests to assert that a module
    // nobody set a breakpoint in still had its symbols ready at the first stop.
    function ModuleSymbolState(const ModuleName: string): TSymbolAvailability;
  end;

implementation

uses
  System.IOUtils, System.DateUtils, PeSymbolSupport;

const
  // Delphi System.TTypeKind ordinals (as returned by TDebugInfoSet.LookupTypeKind).
  TK_CLASS     = 7;
  TK_INTERFACE = 15;
  TK_RECORD    = 14;
  TK_MRECORD   = 22;

  // Total budget (ms) for background symbol-index waits during ONE interactive
  // stop operation (stop handling + a call-stack / locals / evaluate read). Bounds
  // the cumulative TRsmFile.WaitForIndex cost across every just-loaded module so a
  // form-open that runtime-loads many BPLs cannot freeze the dispatch/pump thread
  // (F14). Correctness-critical waits outside this window (BP binding, module load)
  // are unbounded. Symbols not ready within the budget fill in on the next request.
  INTERACTIVE_WAIT_BUDGET_MS = 3000;

threadvar
  // Nesting depth of TInteractiveWaitGuard on THIS thread. Thread-local for the
  // same reason as TRsmFile.InteractiveDeadlineTicks, which it arms: the budget
  // belongs to the thread servicing the stop. As a process-wide class var, a
  // guard created on any other thread (the symbol prefetcher, a test worker)
  // could see depth 1 and skip arming, or reach depth 0 in its own destructor
  // and DISARM the dispatch thread's F14 protection in the middle of a stop.
  GInteractiveWaitDepth: Integer;

type
  // Reentrant scope guard: while any interactive stop operation is on the stack it
  // arms TRsmFile.InteractiveDeadlineTicks; the OUTERMOST guard on this thread owns
  // the deadline so nested reads share one budget. ARC clears it at scope exit.
  TInteractiveWaitGuard = class(TInterfacedObject)
  public
    constructor Create;
    destructor  Destroy; override;
  end;

constructor TInteractiveWaitGuard.Create;
begin
  inherited;
  if GInteractiveWaitDepth = 0 then
    TRsmFile.InteractiveDeadlineTicks := GetTickCount64 + INTERACTIVE_WAIT_BUDGET_MS;
  Inc(GInteractiveWaitDepth);
end;

destructor TInteractiveWaitGuard.Destroy;
begin
  Dec(GInteractiveWaitDepth);
  if GInteractiveWaitDepth = 0 then
    TRsmFile.InteractiveDeadlineTicks := 0;
  inherited;
end;

// Arm the interactive index-wait budget for the duration of the caller's scope.
// Usage: `var G := InteractiveWait;` at the top of an interactive stop method.
function InteractiveWait: IInterface;
begin
  Result := TInteractiveWaitGuard.Create;
end;

{ TDebugSession }

constructor TDebugSession.Create;
begin
  inherited Create;
  FDebugInfo  := TDebugInfoSet.Create;
  FResolver   := TSourceResolver.Create;
  FBreakpoints := TList<TSessionBreakpoint>.Create;
  FPendingBps  := TList<TBpSpec>.Create;
  FBpSpecs     := TDictionary<string, TBpSpec>.Create;
  FBpVerified  := TDictionary<string, Boolean>.Create;
  FDebuggeeOutput := TList<string>.Create;
  FDebuggerOutput := TList<string>.Create;
  FExpander    := TVariableExpander.Create;
  FBpEval      := TBpEvaluator.Create;
  FRsmDisabled := GetEnvironmentVariable('NO_RSM') = '1';
  FLoader      := TModuleSymbolLoader.Create;
  FLoader.DebugInfo       := FDebugInfo;
  FLoader.IsRsmDisabled   := FRsmDisabled;
  FLoader.OnSymbolsLoaded  := HandleModuleSymbolsLoaded;
  FLoader.OnConsole        := HandleLoaderConsole;
  // ShouldRetryModule / RequiresFor stay nil (no launch-config retry, no
  // PACKAGEINFO requires) -- the neutral core is single-module oriented.
  FState := dsNone;
end;

destructor TDebugSession.Destroy;
begin
  FDebugger := nil;  // release the IDebugTarget refcount (engine teardown)
  FReaders.Free;
  FRtti.Free;
  FExpander.Free;        // frees only its handle table; reader refs not owned
  FBpEval.Free;          // owns nothing; reader/rtti refs not owned
  FDebuggerOutput.Free;
  FDebuggeeOutput.Free;
  FLoader.Free;          // removes its module providers from FDebugInfo, frees
                         // the registry; main readers released below via ARC
  FBpVerified.Free;
  FBpSpecs.Free;
  FPendingBps.Free;
  FBreakpoints.Free;
  FResolver.Free;
  FDebugInfo.Free;       // releases provider refs; readers auto-destroy (ARC)
  inherited;
end;

procedure TDebugSession.ReleaseSymbolProviders;
begin
  // The symbol readers memory-map their files (the target .exe's TD32 `.debug`
  // section, the .rsm, each BPL's .dcp). Left alive after teardown they keep the
  // .exe LOCKED (blocking a rebuild) and hold a lot of RAM until the next launch.
  // Free them here and recreate empty infrastructure so the session object stays
  // valid (destructor + a later relaunch both work; every read is gated on
  // dsStopped, so nothing touches these between now and the next launch). F17.
  FExpander.Reset;             // drop cached expansion handles into the old readers
  FreeAndNil(FReaders);        // holds a now-stale FDebugInfo ref
  FreeAndNil(FRtti);           // the process handle is dead after teardown
  // Preserve the loader's frontend-configured hooks across the recreate. The DAP
  // sets ModuleClass (enriched TDllModule) / ShouldRetryModule / RequiresFor /
  // OnLog / OnConsole ONCE at construction; without carrying them over, a relaunch
  // on the same session would silently lose the enriched module class + PACKAGEINFO
  // uses-graph + log sinks (multi-BPL binding + console notices would break).
  // Explicit types: a method-pointer property read with `var x := ...` inference
  // would be treated as an auto-invocation of the pointer (E2035), not a capture.
  var SavedModuleClass: TModuleSymbolsClass     := FLoader.ModuleClass;
  var SavedShouldRetry: TModuleRetryPredicate   := FLoader.ShouldRetryModule;
  var SavedRequiresFor: TModuleRequiresSupplier := FLoader.RequiresFor;
  var SavedOnLog:       TModuleLoaderLog        := FLoader.OnLog;
  var SavedOnConsole:   TModuleLoaderLog        := FLoader.OnConsole;
  FLoader.Free;                // removes its module providers from FDebugInfo, frees registry
  FDebugInfo.Free;             // releases provider refs -> main readers unmap files (ARC)
  SetLength(FLastFrames, 0);
  FLastFramesTid := 0;

  FDebugInfo := TDebugInfoSet.Create;
  FLoader    := TModuleSymbolLoader.Create;
  FLoader.DebugInfo       := FDebugInfo;
  FLoader.IsRsmDisabled   := FRsmDisabled;
  FLoader.OnSymbolsLoaded := HandleModuleSymbolsLoaded;
  FLoader.OnConsole       := HandleLoaderConsole;
  // Reapply the frontend hooks captured above (nil for the neutral core / MCP).
  if SavedModuleClass <> nil then FLoader.ModuleClass := SavedModuleClass;
  if Assigned(SavedShouldRetry) then FLoader.ShouldRetryModule := SavedShouldRetry;
  if Assigned(SavedRequiresFor) then FLoader.RequiresFor := SavedRequiresFor;
  if Assigned(SavedOnLog) then FLoader.OnLog := SavedOnLog;
  if Assigned(SavedOnConsole) then FLoader.OnConsole := SavedOnConsole;
end;

function TDebugSession.Readers: TDelphiValueReader;
begin
  if FReaders = nil then
    FReaders := TDelphiValueReader.Create(FDebugInfo, FDebugger, FRtti)
  else begin
    FReaders.Debugger := FDebugger;
    FReaders.Rtti     := FRtti;
  end;
  Result := FReaders;
end;

function TDebugSession.EnsureRtti: TDelphiRtti;
begin
  if (FRtti = nil) and (FDebugger <> nil) and (FDebugger.ProcessHandle <> 0) then
    FRtti := TDelphiRtti.Create(FDebugger.ProcessHandle);
  Result := FRtti;
end;

function TDebugSession.GetReaders: TDelphiValueReader;
begin
  Result := Readers;
end;

procedure TDebugSession.SetState(NewState: TDebugSessionState);
begin
  FState := NewState;
end;

function TDebugSession.State: TDebugSessionState;
begin
  Result := FState;
end;

function TDebugSession.HasExited: Boolean;
begin
  Result := (FState in [dsExited, dsTerminated]) or
            ((FDebugger <> nil) and FDebugger.HasExited);
end;

function TDebugSession.StopGeneration: UInt64;
begin
  Result := FStopGeneration;
end;

function TDebugSession.DebuggeeProcessId: Cardinal;
begin
  Result := 0;
  if (FDebugger <> nil) and (FDebugger.ProcessHandle <> 0) then
    Result := GetProcessId(FDebugger.ProcessHandle);
end;

function TDebugSession.BuildAndWireDebugger(PreferredBase: UInt64): Boolean;
begin
  FDebugger := TWinDebugger.Create(FDebugInfo, PreferredBase);
  FDebugger.OnStopped     := HandleTargetStopped;
  FDebugger.OnExited      := HandleTargetExited;
  FDebugger.OnOutput      := HandleTargetOutput;
  FDebugger.OnBpHit       := HandleBpHit;
  FDebugger.OnDllLoaded   := HandleDllLoaded;
  FDebugger.OnDllUnloaded := HandleDllUnloaded;
  FLoader.Debugger := FDebugger;  // now available for DLL RVA-shift math
  Result := True;
end;

procedure TDebugSession.ApplyPendingBreakpoints;
begin
  for var Spec in FPendingBps do begin
    var Cmd: TCommand;
    Cmd.Kind   := ckSetBreakpoints;
    Cmd.BpSpec := Spec;
    FDebugger.PostCommand(Cmd);
  end;
  FPendingBps.Clear;
end;

function TDebugSession.Launch(const Opts: TLaunchOptions): Boolean;
begin
  Result := False;
  if FState <> dsNone then
    raise Exception.Create('A debug session is already active');
  if not FileExists(Opts.ExePath) then
    raise Exception.CreateFmt('Program not found: %s', [Opts.ExePath]);

  SetState(dsLaunching);
  FStartedByAttach := False;
  FExePath := Opts.ExePath;
  if Opts.MapPath <> '' then FMapPath := Opts.MapPath
  else                       FMapPath := ChangeFileExt(FExePath, '.map');
  if Opts.RsmPath <> '' then FRsmPath := Opts.RsmPath
  else                       FRsmPath := ChangeFileExt(FExePath, '.rsm');
  FResolver.Configure(Opts.SourceRoot, FExePath, Opts.ExtraSourcePaths);

  FModulesConfig := Opts.Modules;
  FLoader.LoadMainModule(FExePath, FMapPath, FRsmPath);
  var PreferredBase := ReadPEPreferredBase(FExePath);
  BuildAndWireDebugger(PreferredBase);
  ApplyExceptionConfig(Opts.ExceptionFiltersSet, Opts.ExceptionFilters,
    Opts.DelphiClassFilter, Opts.ExceptionRules);

  var CmdLine := '"' + FExePath + '"';
  if Opts.Args <> '' then
    CmdLine := CmdLine + ' ' + Opts.Args;
  try
    FDebugger.Launch(CmdLine, Opts.StopAtEntry);
  except
    on E: Exception do begin
      FDebugger := nil;
      SetState(dsNone);
      raise Exception.CreateFmt('Cannot start "%s": %s', [FExePath, E.Message]);
    end;
  end;
  SetState(dsRunning);
  ApplyPendingBreakpoints;
  Result := True;
end;

function TDebugSession.Attach(Pid: Cardinal; KillOnDetach: Boolean;
  const Opts: TAttachOptions): Boolean;
begin
  Result := False;
  if FState <> dsNone then
    raise Exception.Create('A debug session is already active');
  if Opts.ProgramPath = '' then
    raise Exception.Create('Attach requires a resolved program path');

  SetState(dsAttaching);
  FStartedByAttach := True;
  FExePath := Opts.ProgramPath;
  if Opts.MapPath <> '' then FMapPath := Opts.MapPath
  else                       FMapPath := ChangeFileExt(FExePath, '.map');
  if Opts.RsmPath <> '' then FRsmPath := Opts.RsmPath
  else                       FRsmPath := ChangeFileExt(FExePath, '.rsm');
  FResolver.Configure(Opts.SourceRoot, FExePath, Opts.ExtraSourcePaths);

  FModulesConfig := Opts.Modules;
  FLoader.LoadMainModule(FExePath, FMapPath, FRsmPath);
  BuildAndWireDebugger(ReadPEPreferredBase(FExePath));
  ApplyExceptionConfig(Opts.ExceptionFiltersSet, Opts.ExceptionFilters,
    Opts.DelphiClassFilter, Opts.ExceptionRules);
  try
    FDebugger.Attach(Pid, KillOnDetach);
  except
    on E: Exception do begin
      FDebugger := nil;
      SetState(dsNone);
      raise Exception.CreateFmt('Cannot attach to PID %d: %s', [Pid, E.Message]);
    end;
  end;
  SetState(dsRunning);
  ApplyPendingBreakpoints;
  Result := True;
end;

procedure TDebugSession.Detach;
begin
  if FDebugger = nil then
    Exit;
  // Terminate() on the engine honours the KillOnDetach flag captured at Attach.
  // For a detach request the caller must have attached with KillOnDetach=False,
  // so the engine's Terminate performs a clean DebugActiveProcessStop.
  FDebugger.Terminate;
  FDebugger := nil;
  SetState(dsDetached);
  ReleaseSymbolProviders;   // unlock the target's symbol files (F17)
end;

procedure TDebugSession.Terminate;
begin
  if FDebugger <> nil then
    FDebugger.Terminate;
  FDebugger := nil;
  SetState(dsTerminated);
  ReleaseSymbolProviders;   // unlock the target's symbol files (F17)
end;

procedure TDebugSession.StopDebugging;
begin
  if FStartedByAttach then
    Detach
  else
    Terminate;
end;

procedure TDebugSession.Pump;
begin
  if (FDebugger = nil) or not (FState in [dsLaunching, dsAttaching, dsRunning, dsStopped]) then
    Exit;
  // Register whatever the symbol prefetcher finished, BEFORE handling the next
  // debug event, so a stop that is about to be reported symbolicates against the
  // most complete provider set available.
  //
  // This is the ONLY publication point, and it is deliberately here rather than
  // in an RTL synchronize queue: TThread.Queue would be pumped by the DAP's
  // CheckSynchronize but is never drained by the MCP loop, so modules would parse
  // forever and never register under MCP while every DAP test passed.
  //
  // Only while STOPPED. Registering providers leads to reposting breakpoint
  // specs, and reposting rewrites planted INT3s. Doing that from the pump while
  // the debuggee is genuinely executing opens an unplant/replant window the
  // target can run straight through -- an intermittently missed breakpoint,
  // which is a correctness regression far worse than a late frame name. Results
  // simply queue until the next stop, which is exactly when they are needed.
  PublishPrefetchedSymbols;
  FDebugger.ProcessOneEvent;
  PublishPrefetchedSymbols;
end;

procedure TDebugSession.PublishPrefetchedSymbols;
begin
  if FState <> dsStopped then
    Exit;
  if not FLoader.DrainPrefetch then
    Exit;
  // ONE repost for the whole drain, not one per module: a drain can publish a
  // dozen modules at once and each repost rewrites every spec.
  RepostBreakpoints;
  if Assigned(FOnSymbolsArrived) then
    FOnSymbolsArrived(Self);
end;

function TDebugSession.ModuleSymbolState(const ModuleName: string): TSymbolAvailability;
begin
  var Wanted := LowerCase(ModuleName);
  for var M in FLoader.Modules do
    if M.Name = Wanted then
      Exit(M.SymbolAvailability);
  Result := saUnknownModule;
end;

procedure TDebugSession.ContinueExecution;
begin
  if FDebugger = nil then
    raise Exception.Create('No active debuggee to continue');
  var Cmd: TCommand;
  Cmd.Kind := ckContinue;
  FDebugger.PostCommand(Cmd);
  SetState(dsRunning);
end;

procedure TDebugSession.StepOver(ThreadId: DWORD = 0);
begin
  if FDebugger = nil then
    raise Exception.Create('No active debuggee to step');
  var Cmd: TCommand;
  Cmd.Kind     := ckStepOver;
  Cmd.ThreadId := ThreadId;
  FDebugger.PostCommand(Cmd);
  SetState(dsRunning);
end;

procedure TDebugSession.StepInto(ThreadId: DWORD = 0);
begin
  if FDebugger = nil then
    raise Exception.Create('No active debuggee to step');
  var Cmd: TCommand;
  Cmd.Kind     := ckStepInto;
  Cmd.ThreadId := ThreadId;
  FDebugger.PostCommand(Cmd);
  SetState(dsRunning);
end;

procedure TDebugSession.StepOut(ThreadId: DWORD = 0);
begin
  if FDebugger = nil then
    raise Exception.Create('No active debuggee to step');
  var Cmd: TCommand;
  Cmd.Kind     := ckStepOut;
  Cmd.ThreadId := ThreadId;
  FDebugger.PostCommand(Cmd);
  SetState(dsRunning);
end;

procedure TDebugSession.Pause;
begin
  if FDebugger = nil then
    raise Exception.Create('No active debuggee to pause');
  var Cmd: TCommand;
  Cmd.Kind := ckPause;
  FDebugger.PostCommand(Cmd);
end;

function TDebugSession.SetBreakpoints(const SourceFile: string;
  const Specs: TArray<TBpLineSpec>): TArray<TSessionBreakpoint>;
begin
  var Spec: TBpSpec;
  Spec.SourceFile := SourceFile;
  SetLength(Spec.Lines,         Length(Specs));
  SetLength(Spec.Conditions,    Length(Specs));
  SetLength(Spec.HitConditions, Length(Specs));
  SetLength(Spec.LogMessages,   Length(Specs));

  // Drop any prior breakpoints for this file (a set replaces the file's set).
  for var I := FBreakpoints.Count - 1 downto 0 do
    if SameText(FBreakpoints[I].SourceFile, SourceFile) then
      FBreakpoints.Delete(I);

  SetLength(Result, Length(Specs));
  for var I := 0 to High(Specs) do begin
    Spec.Lines[I]         := Specs[I].Line;
    Spec.Conditions[I]    := Specs[I].Condition;
    Spec.HitConditions[I] := Specs[I].HitCondition;
    Spec.LogMessages[I]   := Specs[I].LogMessage;

    var Rva: UInt64;
    var Bp: TSessionBreakpoint;
    Bp.Id           := LowerCase(ExtractFileName(SourceFile)) + '|' + IntToStr(Specs[I].Line);
    Bp.SourceFile   := SourceFile;
    Bp.Line         := Specs[I].Line;
    Bp.Verified     := FDebugInfo.SourceLineToRva(SourceFile, Specs[I].Line, Rva);
    Bp.Condition    := Specs[I].Condition;
    Bp.HitCondition := Specs[I].HitCondition;
    Bp.LogMessage   := Specs[I].LogMessage;
    Bp.HitCount     := 0;
    FBreakpoints.Add(Bp);
    // Seed the flip-detection baseline so a later module-load repost only fires
    // OnBreakpointChanged for a line that actually transitions to verified.
    FBpVerified.AddOrSetValue(Bp.Id, Bp.Verified);
    Result[I] := Bp;
  end;

  // Retain the spec so it can be re-posted when a DLL/BPL that owns its source
  // loads after the breakpoint was set.
  FBpSpecs.AddOrSetValue(LowerCase(SourceFile), Spec);

  // Load symbols for an already-in-memory module that OWNS this source (notably a
  // package loaded BEFORE an attach) so the breakpoint resolves now -- for a launch
  // the BPL loads after the breakpoint and is handled in HandleDllLoaded. Gated by
  // ContainsSourceFile so an unrelated sidecar-bearing module is not parsed.
  // Idempotent (per-module tried-flags).
  for var M in FLoader.Modules do
    if M.ContainsSourceFile(SourceFile) then
      FLoader.LoadModuleSymbols(M);

  if FDebugger <> nil then begin
    var Cmd: TCommand;
    Cmd.Kind   := ckSetBreakpoints;
    Cmd.BpSpec := Spec;
    FDebugger.PostCommand(Cmd);
  end
  else
    FPendingBps.Add(Spec);
end;

function TDebugSession.ListBreakpoints: TArray<TSessionBreakpoint>;
begin
  Result := FBreakpoints.ToArray;
end;

procedure TDebugSession.RemoveAllBreakpoints;
begin
  // Post an empty spec per known source file FIRST so the engine clears the
  // planted INT3s. The old code cleared the lists before iterating them, so it
  // posted nothing and the breakpoints stayed planted in the target.
  if FDebugger <> nil then
    for var KV in FBpSpecs do begin
      var Cmd: TCommand;
      Cmd.Kind              := ckSetBreakpoints;
      Cmd.BpSpec            := Default(TBpSpec);
      Cmd.BpSpec.SourceFile := KV.Value.SourceFile;  // empty Lines => clear the file
      FDebugger.PostCommand(Cmd);
    end;
  FBreakpoints.Clear;
  FPendingBps.Clear;
  FBpSpecs.Clear;
  FBpVerified.Clear;
end;

function TDebugSession.ResolveEffectiveStop(const SourceFile: string;
  SourceLine: Integer; out EffFile: string; out EffLine: Integer): Boolean;
begin
  EffFile := SourceFile;
  EffLine := SourceLine;
  Result  := EffFile <> '';
  if Result or (FDebugger = nil) then
    Exit;
  // Exception raised in RTL plumbing: walk to the first frame with source.
  var Frames := FResolver.TrimRaisePlumbing(FDebugger.GetStackFrames, FStoppedOnException);
  FLastFrames    := Frames;
  FLastFramesTid := FStopTid;
  for var F in Frames do
    if F.SourceFile <> '' then begin
      EffFile := F.SourceFile;
      EffLine := F.SourceLine;
      Exit(True);
    end;
end;

procedure TDebugSession.HandleTargetStopped(Reason: TStopReason;
  const SourceFile: string; SourceLine: Integer);
begin
  var Guard := InteractiveWait;  // bound symbol-index waits during the stop (F14)
  FFrameSelected := False;       // a fresh stop clears any prior frame selection
  if FDebugger <> nil then
    FDebugger.ClearActiveFrame;
  SetLength(FLastFrames, 0);
  FLastFramesTid := 0;
  FExpander.Reset;             // expansion handles are valid only within a stop
  FStoppedOnException := Reason = srException;
  FStopReason := Reason;
  if (FRtti = nil) and (FDebugger <> nil) and (FDebugger.ProcessHandle <> 0) then
    FRtti := TDelphiRtti.Create(FDebugger.ProcessHandle);
  if FDebugger <> nil then begin
    FLoader.EnsureModuleForPC(FDebugger.GetRegisters.Rip);  // load DLL/BPL symbols at the stop
    FStopTid := FDebugger.GetStoppedThreadId;
  end;

  var EffFile: string;
  var EffLine: Integer;
  ResolveEffectiveStop(SourceFile, SourceLine, EffFile, EffLine);

  SetState(dsStopped);
  Inc(FStopGeneration);

  if Assigned(FOnStopped) then begin
    var Info: TStopInfo;
    Info.Reason      := Reason;
    Info.SourceFile  := EffFile;
    Info.SourceLine  := EffLine;
    Info.FunctionName := '';
    if FDebugger <> nil then begin
      var FnName: string;
      var SrcFile: string;
      var Ln: Integer;
      if GetCurrentLocation(FnName, SrcFile, Ln) then
        Info.FunctionName := FnName;
    end;
    Info.OsThreadId  := FStopTid;
    if (Reason = srException) and (FDebugger <> nil) then
      Info.ExceptionDescription := FDebugger.LastExceptionDesc;
    FOnStopped(Info);
  end;
end;

procedure TDebugSession.HandleTargetExited(ExitCode: Integer);
begin
  SetState(dsExited);
  Inc(FStopGeneration);
  if Assigned(FOnExited) then
    FOnExited(ExitCode);
end;

procedure TDebugSession.HandleTargetOutput(const Text: string);
begin
  FDebuggeeOutput.Add(Text);
  if Assigned(FOnOutput) then
    FOnOutput(okDebuggee, Text);
end;

// Called by the engine when a planted breakpoint fires. Delegates the condition /
// hit-count / logpoint decision to the shared evaluator; on a logpoint it emits the
// rendered text to the debugger-output buffer and resumes. Returns True to stop,
// False to silently resume.
function TDebugSession.HandleBpHit(const BP: TBreakpointRec): Boolean;
begin
  // A conditional / logpoint hit can fire before any frontend request has forced
  // the main .rsm to load; the condition/log expression evaluator needs it.
  EnsureMainRsm;
  if (FRtti = nil) and (FDebugger <> nil) and (FDebugger.ProcessHandle <> 0) then
    FRtti := TDelphiRtti.Create(FDebugger.ProcessHandle);
  FBpEval.Debugger  := FDebugger;
  FBpEval.Rtti      := FRtti;
  FBpEval.DebugInfo := FDebugInfo;
  FBpEval.Readers   := Readers;
  var LogText: string;
  case FBpEval.Decide(BP.Condition, BP.HitCondition, BP.LogMessage, BP.HitCount, LogText) of
    bpStop:
      Result := True;
    bpLog: begin
      FDebuggerOutput.Add(LogText);
      if Assigned(FOnOutput) then
        FOnOutput(okDebugger, LogText);
      Result := False;
    end;
  else
    Result := False;   // bpResume
  end;
end;

function TDebugSession.HaveBreakpoints: Boolean;
begin
  Result := (FBreakpoints.Count > 0) or (FPendingBps.Count > 0) or (FBpSpecs.Count > 0);
end;

// True when the module owns the source file of any pending breakpoint spec, so it
// is worth eager-loading its symbols. ContainsSourceFile is authoritative for the
// frontend's module subclass (DAP's TDllModule: PACKAGEINFO / MAP index).
function TDebugSession.ModuleOwnsPendingBreakpoint(Module: TModuleSymbols): Boolean;
begin
  Result := False;
  for var Spec in FBpSpecs.Values do
    if Module.ContainsSourceFile(Spec.SourceFile) then
      Exit(True);
end;

// Fired by FLoader after a runtime module's TD32 (its line table) loads; re-post
// every stored spec so a breakpoint set before the module was present binds.
procedure TDebugSession.HandleModuleSymbolsLoaded(Module: TModuleSymbols);
begin
  RepostBreakpoints;
  if Assigned(FOnModuleSymbolsLoadedHook) then
    FOnModuleSymbolsLoadedHook(Module);
end;

procedure TDebugSession.HandleLoaderConsole(const Msg: string);
begin
  FDebuggerOutput.Add(Msg);
  if Assigned(FOnOutput) then
    FOnOutput(okDebugger, Msg);
end;

procedure TDebugSession.RepostBreakpoints;
begin
  if FDebugger = nil then
    Exit;
  for var KV in FBpSpecs do begin
    var Cmd: TCommand;
    Cmd.Kind   := ckSetBreakpoints;
    Cmd.BpSpec := KV.Value;
    FDebugger.PostCommand(Cmd);
  end;
  // A repost happens when a module's symbols just became available; a line that
  // could not resolve before may resolve now -> tell a subscribed frontend to
  // re-colour its gutter.
  NotifyBreakpointFlips;
end;

// Writes the new verified state into the stored TSessionBreakpoint record. Records
// in the list are value types, so the whole record has to be read back, patched and
// re-assigned by index. Bp.Id uses the same 'lcasefile|line' formula as the flip key.
procedure TDebugSession.StoreVerifiedState(const BpId: string; Verified: Boolean);
begin
  for var I := 0 to FBreakpoints.Count - 1 do begin
    if FBreakpoints[I].Id <> BpId then
      Continue;
    var Bp := FBreakpoints[I];
    Bp.Verified := Verified;
    FBreakpoints[I] := Bp;
    Exit;
  end;
end;

procedure TDebugSession.NotifyBreakpointFlips;
begin
  if FDebugInfo = nil then
    Exit;
  for var KV in FBpSpecs do begin
    var Spec := KV.Value;
    for var Line in Spec.Lines do begin
      var Key := LowerCase(ExtractFileName(Spec.SourceFile)) + '|' + IntToStr(Line);
      var Rva: UInt64;
      var Verified := FDebugInfo.SourceLineToRva(Spec.SourceFile, Line, Rva);
      var Prev := False;
      FBpVerified.TryGetValue(Key, Prev);
      if Verified = Prev then
        Continue;
      FBpVerified.AddOrSetValue(Key, Verified);
      // F22: FBreakpoints is what ListBreakpoints returns, and the MCP frontend
      // serialises that array verbatim. Without this write it stayed frozen at the
      // value computed when the breakpoint was SET, so a breakpoint in a package
      // loaded later was still reported unverified while it was planted and firing.
      // Both directions are stored: a module unload that makes the line stop
      // resolving must not leave a client believing the breakpoint is still live.
      StoreVerifiedState(Key, Verified);
      // The event stays a verified-transition notification only -- a subscribed DAP
      // frontend uses it to re-colour a gutter that was drawn unverified.
      if Verified and Assigned(FOnBreakpointChanged) then
        FOnBreakpointChanged(Spec.SourceFile, Line, True);
    end;
  end;
end;

procedure TDebugSession.HandleDllLoaded(const Name, Path: string;
  Base, ImageSize: UInt64);
begin
  var M := FLoader.RegisterModuleRecord(Name, Path, Base, ImageSize);
  ApplyModuleConfig(M, Name, Path);

  // Eagerly load a newly-loaded module's symbols ONLY when it actually owns a
  // pending breakpoint's source (so the breakpoint resolves + plants once the
  // module is in memory), then re-post the specs. Gating on ContainsSourceFile
  // (authoritative PACKAGEINFO/MAP-index via the frontend's TModuleSymbols
  // subclass) stops a many-package host from parsing every unrelated sidecar-
  // bearing BPL on each load -- the repost-storm / seq-timeout freeze class.
  if HaveBreakpoints and ModuleOwnsPendingBreakpoint(M) then begin
    FLoader.LoadModuleSymbols(M);
    RepostBreakpoints;
  end;

  if Assigned(FOnDllLoadedHook) then
    FOnDllLoadedHook(Name, Path, Base, ImageSize);

  // Everything else goes to the background prefetcher. This is the WHEN fix: a
  // module's ~150 ms - 0.65 s of TD32 parsing now happens on a worker at
  // LOAD_DLL time instead of synchronously at the first stop that touches it.
  //
  // LAST on purpose. Both synchronous breakpoint-binding paths above -- the gate
  // and the frontend's own eager probe in OnDllLoadedHook -- must bind the module
  // BEFORE the debuggee is resumed, because a package's initialization code runs
  // the instant this event is continued. Enqueueing earlier would let the worker
  // claim the module and turn that hard requirement into a best-effort one: the
  // breakpoint would only plant when the prefetch published, by which time the
  // code it guards has already executed. EnqueuePrefetch is a no-op for anything
  // those paths just loaded.
  FLoader.EnqueuePrefetch(M);
end;

procedure TDebugSession.ApplyModuleConfig(Module: TModuleSymbols;
  const AName, APath: string);

  function BaseName(const S: string): string;
  begin
    var T := Trim(S);
    var P := LastDelimiter('/\:', T);   // 1-based; 0 when no separator present
    if P > 0 then
      T := Copy(T, P + 1, MaxInt);
    Result := LowerCase(T);
  end;

  function Matches(const ACfgName, ACandidate: string): Boolean;
  begin
    var C := BaseName(ACfgName);
    var N := BaseName(ACandidate);
    if (C = '') or (N = '') then
      Exit(False);
    if C = N then
      Exit(True);
    Result := SameText(ChangeFileExt(C, ''), ChangeFileExt(N, ''));
  end;

begin
  if Length(FModulesConfig) = 0 then
    Exit;
  for var Cfg in FModulesConfig do
    if Matches(Cfg.Name, AName) or Matches(Cfg.Name, APath) then begin
      if Cfg.MapPath <> '' then Module.MapPath := Cfg.MapPath;
      if Cfg.RsmPath <> '' then Module.RsmPath := Cfg.RsmPath;
      if Cfg.DcpPath <> '' then Module.DcpPath := Cfg.DcpPath;
      Exit;
    end;
end;

procedure TDebugSession.ApplyExceptionConfig(FiltersSet: Boolean;
  Filters: TExceptionFilters; const DelphiFilter: string;
  const Rules: TArray<TExceptionRule>);
begin
  if FDebugger = nil then
    Exit;
  if FiltersSet then begin
    FDebugger.SetExceptionFilters(Filters);
    FDebugger.SetDelphiClassFilter(DelphiFilter);
  end;
  if Length(Rules) > 0 then
    FDebugger.SetExceptionRules(Rules);
end;

class function TDebugSession.ParseExceptionFilters(
  const Names: TArray<string>): TExceptionFilters;
begin
  Result := [];
  for var N in Names do
    if      SameText(N, 'delphi')    then Include(Result, efDelphi)
    else if SameText(N, 'av')        then Include(Result, efAccessViolation)
    else if SameText(N, 'all')       then Include(Result, efAllFirstChance)
    else if SameText(N, 'unhandled') then Include(Result, efUnhandled);
end;

function TDebugSession.SetExceptionFilters(const Names: TArray<string>;
  const DelphiClasses: string): Boolean;
begin
  Result := FDebugger <> nil;
  if not Result then
    Exit;
  FDebugger.SetExceptionFilters(ParseExceptionFilters(Names));
  FDebugger.SetDelphiClassFilter(DelphiClasses);
end;

procedure TDebugSession.HandleDllUnloaded(const Name: string; Base: UInt64);
begin
  FLoader.RemoveModuleRecord(Name, Base);
end;

function TDebugSession.FrameToSession(const F: TStackFrame;
  Index: Integer): TSessionFrame;
begin
  Result := Default(TSessionFrame);
  Result.Index        := Index;
  Result.FunctionName := F.FunctionName;
  Result.SourceFile   := FResolver.Resolve(F.SourceFile);
  if Result.SourceFile = '' then
    Result.SourceFile := F.SourceFile;
  Result.SourceLine   := F.SourceLine;
  Result.IP           := F.IP;
  Result.FrameRBP     := F.FrameRBP;
  Result.FuncEntryVA  := F.FuncEntryVA;
  // Owning module + symbol state. A frame the providers could not name arrives
  // here with FunctionName = '' and no explanation; this is the only place that
  // still knows WHICH module the address belongs to and whether that module has
  // symbols at all. Purely descriptive -- it loads nothing (the eager
  // EnsureModuleForPC sweep in GetCallStack has already run by now).
  Result.Symbols := FLoader.DescribeAddress(F.IP, Result.ModuleName);
end;

function TDebugSession.GetCallStack: TArray<TSessionFrame>;
begin
  var Guard := InteractiveWait;   // bound per-frame symbol-index waits (F14)
  Result := nil;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;
  var Frames := FDebugger.GetStackFrames;
  // Load symbols for any runtime module (DLL/BPL) owning an unresolved frame,
  // then re-walk so its source/function names resolve.
  var NeedRefresh := False;
  for var F in Frames do
    if (F.SourceFile = '') or (F.FunctionName = '') then begin
      FLoader.EnsureModuleForPC(F.IP);
      NeedRefresh := True;
    end;
  if NeedRefresh then
    Frames := FDebugger.GetStackFrames;
  Frames := FResolver.TrimRaisePlumbing(Frames, FStoppedOnException);
  FLastFrames    := Frames;
  FLastFramesTid := FStopTid;
  SetLength(Result, Length(Frames));
  for var I := 0 to High(Frames) do
    Result[I] := FrameToSession(Frames[I], I);
end;

function TDebugSession.GetCallStack(ThreadId: Cardinal): TArray<TSessionFrame>;
begin
  var Guard := InteractiveWait;   // bound per-frame symbol-index waits (F14)
  Result := nil;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;
  // The stopped thread goes through the full trim + FLastFrames caching path so
  // frame selection stays consistent; a non-current thread is a read-only walk
  // that must NOT clobber the stopped thread's cached frames.
  if ThreadId = FStopTid then
    Exit(GetCallStack);
  var Frames := FDebugger.GetStackFrames(ThreadId);
  var NeedRefresh := False;
  for var F in Frames do
    if (F.SourceFile = '') or (F.FunctionName = '') then begin
      FLoader.EnsureModuleForPC(F.IP);
      NeedRefresh := True;
    end;
  if NeedRefresh then
    Frames := FDebugger.GetStackFrames(ThreadId);
  SetLength(Result, Length(Frames));
  for var I := 0 to High(Frames) do
    Result[I] := FrameToSession(Frames[I], I);
end;

function TDebugSession.GetThreads: TArray<TSessionThread>;
begin
  Result := nil;
  if FDebugger = nil then
    Exit;
  var Ids := FDebugger.GetThreadIds;
  SetLength(Result, Length(Ids));
  for var I := 0 to High(Ids) do begin
    Result[I]            := Default(TSessionThread);
    Result[I].Index      := I;
    Result[I].OsThreadId := Ids[I];
    Result[I].Name       := FDebugger.GetThreadName(Ids[I]);
    Result[I].IsStopped  := FState = dsStopped;
    Result[I].IsCurrent  := Ids[I] = FStopTid;
  end;
end;

function TDebugSession.GetStoppedThreadId: Cardinal;
begin
  Result := FStopTid;
end;

procedure TDebugSession.SelectFrame(Index: Integer);
begin
  SelectFrame(Index, 0);
end;

procedure TDebugSession.SelectFrame(Index: Integer; ThreadId: Cardinal);
begin
  if FDebugger = nil then
    Exit;
  // The cache holds ONE thread's frames. The client can walk another thread's
  // stack (GetCallStack(tid) deliberately does not clobber the cache) and then
  // select one of ITS frames; pairing that index with the stopped thread's cache
  // read ANOTHER thread's RBP/entry, so the Variables panel showed a complete,
  // plausible set of locals belonging to a different thread. Re-walk on mismatch.
  if (ThreadId <> 0) and (ThreadId <> FLastFramesTid) then begin
    FLastFrames    := FDebugger.GetStackFrames(ThreadId);
    FLastFramesTid := ThreadId;
  end;
  // Frame 0 of the STOPPED thread normally clears the selection (the stopped RIP
  // already is that frame). For any OTHER thread frame 0 is a real, distinct
  // frame that must be selected explicitly -- clearing would silently fall back
  // to the stopped thread's top frame.
  var ForeignThread := (FLastFramesTid <> 0) and (FLastFramesTid <> FStopTid);
  // Index refers to the frames cached by the last GetCallStack. Frame 0 (the
  // stopped top frame) and any frame lacking an RBP clear the selection.
  // A non-top frame is always selected explicitly. Frame 0 normally CLEARS (the
  // stopped RIP is the top frame) -- but at an EXCEPTION stop the stopped RIP is RTL
  // raise-plumbing, so frame 0 (the trimmed user frame that raised) must be selected
  // explicitly for its locals / evaluate to resolve (F11).
  var Selectable := (Index >= 0) and (Index < Length(FLastFrames)) and
                    (FLastFrames[Index].FrameRBP <> 0) and
                    ((Index > 0) or FStoppedOnException or ForeignThread);
  if Selectable then
    FDebugger.SetActiveFrame(FLastFrames[Index].FrameRBP, FLastFrames[Index].FuncEntryVA,
      FLastFrames[Index].FunctionName, FLastFrames[Index].IP)
  else
    FDebugger.ClearActiveFrame;
  // Only a NON-top selection counts as user-chosen (guards GetLocals' auto-retarget).
  // Any frame of a foreign thread counts, including its frame 0.
  FFrameSelected := Selectable and ((Index > 0) or ForeignThread);
end;

procedure TDebugSession.ClearFrame;
begin
  FFrameSelected := False;
  if FDebugger <> nil then
    FDebugger.ClearActiveFrame;
end;

function TDebugSession.GetRegisters: TArray<TRegisterValue>;

  procedure Emit(const AName: string; AValue: UInt64; ASize: Byte);
  begin
    var R: TRegisterValue;
    R.Name  := AName;
    R.Value := AValue;
    R.Size  := ASize;
    Result := Result + [R];
  end;

begin
  Result := nil;
  if FDebugger = nil then
    Exit;
  var Regs := FDebugger.GetRegisters;
  if not Regs.Valid then
    Exit;
  Emit('RIP', Regs.Rip, 8);  Emit('RSP', Regs.Rsp, 8);  Emit('RBP', Regs.Rbp, 8);
  Emit('RAX', Regs.Rax, 8);  Emit('RBX', Regs.Rbx, 8);  Emit('RCX', Regs.Rcx, 8);
  Emit('RDX', Regs.Rdx, 8);  Emit('RSI', Regs.Rsi, 8);  Emit('RDI', Regs.Rdi, 8);
  Emit('R8',  Regs.R8,  8);  Emit('R9',  Regs.R9,  8);  Emit('R10', Regs.R10, 8);
  Emit('R11', Regs.R11, 8);  Emit('R12', Regs.R12, 8);  Emit('R13', Regs.R13, 8);
  Emit('R14', Regs.R14, 8);  Emit('R15', Regs.R15, 8);
  Emit('EFlags', Regs.EFlags, 4);
end;

function TDebugSession.SetRegister(const Name: string; Value: UInt64): Boolean;
begin
  Result := (FDebugger <> nil) and FDebugger.SetRegisterByName(Name, Value);
end;

function TDebugSession.GetGotoTargetVA(const SourceFile: string; Line: Integer;
  out VA: UInt64): Boolean;
begin
  VA     := 0;
  Result := False;
  if (FDebugInfo = nil) or (FDebugger = nil) then
    Exit;
  // Basename, as everywhere else -- providers key their line tables on it. The
  // aggregate set queries the full provider chain (TD32 primary, MAP fallback).
  var Rva: UInt64;
  if not FDebugInfo.SourceLineToRva(ExtractFileName(SourceFile), Line, Rva) then
    Exit;
  VA     := FDebugger.RvaToVA(Rva);
  Result := True;
end;

function TDebugSession.SetInstructionPointer(VA: UInt64): Boolean;
begin
  Result := False;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;
  if not FDebugger.SetInstructionPointer(VA) then
    Exit;
  // The RIP moved: the last stack walk is stale and any explicitly-selected frame
  // no longer applies. Clear both so a scopes/evaluate issued before the client
  // re-stacks resolves against the new top frame, not a pre-goto cached frame.
  SetLength(FLastFrames, 0);
  FLastFramesTid := 0;
  FDebugger.ClearActiveFrame;
  Result := True;
end;

function TDebugSession.EncodeAndWriteValue(TargetAddr: UInt64;
  const TypeHint, ValueStr: string; out ErrMsg: string): Boolean;
var
  Buf:  array[0..7] of Byte;
  Size: Integer;
begin
  Result := False;
  ErrMsg := '';
  // Enum targets first (literal name, then numeric ordinal at the enum's TRUE
  // width). EncodeValueForType's unknown-type fallback writes 8 bytes and would
  // clobber the fields that follow a 1/2-byte enum/set slot.
  if TryEncodeEnumByName(FDebugInfo, ValueStr, TypeHint, Buf, Size) or
     TryEncodeEnumOrdinal(FDebugInfo, ValueStr, TypeHint, Buf, Size) or
     EncodeValueForType(ValueStr, TypeHint, Buf, Size, ErrMsg) then begin
    if not FDebugger.WriteMemoryAt(TargetAddr, @Buf[0], Size) then begin
      ErrMsg := Format('Memory write failed at 0x%x', [TargetAddr]);
      Exit;
    end;
    Exit(True);
  end;
  if ErrMsg = '__STRING_PATH__' then begin
    // String type -- hand off to the RTL helper. SetStringVariable allocates a
    // new literal buffer and invokes @UStrAsg/@LStrAsg in the debuggee so the
    // old string's refcount is properly decremented.
    if not FDebugger.SetStringVariable(TargetAddr,
        StripStringQuotes(ValueStr), TypeHint) then begin
      ErrMsg := 'String assignment failed (could not invoke RTL helper)';
      Exit;
    end;
    Exit(True);
  end;
  // ErrMsg already carries the encoder's specific rejection text.
end;

function TDebugSession.SetLocalVariable(const Name, ValueStr: string;
  out NewValue, NewType: string): Boolean;
var
  V:      TLocalValue;
  ErrMsg: string;
begin
  Result   := False;
  NewValue := '';
  NewType  := '';
  if (FState <> dsStopped) or (FDebugger = nil) then begin
    NewValue := 'Not running';
    Exit;
  end;
  // Look up the target variable to discover its type and address.
  if not FDebugger.EvaluateName(Name, V) or (V.Address = 0) then begin
    NewValue := Format('Cannot find variable "%s"', [Name]);
    Exit;
  end;
  // For var/reference parameters the stack slot holds a pointer to the real
  // storage; write through the pointer so we modify the caller's value instead
  // of clobbering the parameter slot.
  var TargetAddr := V.Address;
  if (V.Kind = lkVarParam) and (V.RawValue <> 0) then
    TargetAddr := V.RawValue;
  if not EncodeAndWriteValue(TargetAddr, V.TypeHint, ValueStr, ErrMsg) then begin
    NewValue := ErrMsg;
    Exit;
  end;
  // Refresh via a fresh EvaluateName so the render reflects the new bytes.
  if FDebugger.EvaluateName(Name, V) then begin
    NewValue := Readers.FormatLocalValue(V);
    NewType  := Readers.FormatLocalType(V);
  end;
  Result := True;
end;

function TDebugSession.SetFieldVariable(Handle: TVarHandle;
  const Name, ValueStr: string; out NewValue, NewType: string): Boolean;
var
  FieldAddr:         UInt64;
  FieldType, ErrMsg: string;
begin
  Result   := False;
  NewValue := '';
  NewType  := '';
  if (FState <> dsStopped) or (FDebugger = nil) then begin
    NewValue := 'Not running';
    Exit;
  end;
  SyncExpander;  // TryGetWritableField reads members through the current deps
  // Only member (exRsmMembers) expansions expose writable backing fields; the
  // expander returns the absolute field address + declared type.
  if not FExpander.TryGetWritableField(Handle, Name, FieldAddr, FieldType) then begin
    NewValue := Format('setVariable not supported for field "%s"', [Name]);
    Exit;
  end;
  if not EncodeAndWriteValue(FieldAddr, FieldType, ValueStr, ErrMsg) then begin
    NewValue := ErrMsg;
    Exit;
  end;
  // Build a refreshed display from a fresh 8-byte read at the field address.
  var FreshRaw: UInt64 := 0;
  if FDebugger.ReadProcessMemoryAt(FieldAddr, @FreshRaw, 8) then begin
    var Lv := Default(TLocalValue);
    Lv.Name       := Name;
    Lv.TypeHint   := FieldType;
    Lv.Address    := FieldAddr;
    Lv.RawValue   := FreshRaw;
    Lv.ValueValid := True;
    NewValue := Readers.FormatLocalValue(Lv);
    NewType  := FieldType;
  end;
  Result := True;
end;

function TDebugSession.ResolveSourcePath(const NameOrPath: string): string;
begin
  Result := FResolver.Resolve(NameOrPath);
  if Result = '' then
    Result := NameOrPath;
end;

procedure TDebugSession.EnsureMainRsm;
begin
  FLoader.EnsureMainRsm;
end;

function TDebugSession.GetCurrentLocation(out FnName, SrcFile: string;
  out Line: Integer): Boolean;
begin
  var Guard := InteractiveWait;   // bound symbol-index waits (F14)
  FnName  := '';
  SrcFile := '';
  Line    := 0;
  Result  := False;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;
  var Frames := FDebugger.GetStackFrames;
  if (Length(Frames) > 0) and ((Frames[0].SourceFile = '') or (Frames[0].FunctionName = '')) then begin
    FLoader.EnsureModuleForPC(Frames[0].IP);
    Frames := FDebugger.GetStackFrames;
  end;
  Frames := FResolver.TrimRaisePlumbing(Frames, FStoppedOnException);
  if Length(Frames) = 0 then
    Exit;
  FnName  := Frames[0].FunctionName;
  SrcFile := FResolver.Resolve(Frames[0].SourceFile);
  if SrcFile = '' then
    SrcFile := Frames[0].SourceFile;
  Line    := Frames[0].SourceLine;
  Result  := True;
end;

// Pushes the current symbol/reader/rtti references into the shared expander just
// before use. FRtti and FReaders are created lazily on the first stop, so the
// expander must pick up whatever exists at point of use, not at construction.
procedure TDebugSession.SyncExpander;
begin
  FExpander.Debugger  := FDebugger;
  FExpander.DebugInfo := FDebugInfo;
  FExpander.TD32      := FLoader.MainTD32;
  FExpander.Rtti      := FRtti;
  FExpander.Readers   := Readers;
end;

function TDebugSession.LocalToSession(const LV: TLocalValue): TSessionVariable;
begin
  Result := Default(TSessionVariable);
  Result.Name         := LV.Name;
  Result.Value        := Readers.FormatLocalValue(LV);
  Result.TypeName     := Readers.FormatLocalType(LV);
  Result.Kind         := vkScalar;
  Result.Expandable   := False;
  Result.Handle       := 0;
  Result.EvaluateName := LV.Name;
  // Attach an expansion handle when the value is a class/record/array/Variant.
  SyncExpander;
  FExpander.ClassifyLocal(LV, Result);
end;

function TDebugSession.GetChildren(Handle: TVarHandle): TArray<TSessionVariable>;
begin
  var Guard := InteractiveWait;   // bound symbol-index waits (F14)
  Result := nil;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;
  SyncExpander;
  Result := FExpander.GetChildren(Handle);
end;

function TDebugSession.GetLocals: TArray<TSessionVariable>;
begin
  var Guard := InteractiveWait;   // bound symbol-index waits (F14)
  Result := nil;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;

  // At an exception stop the raw stopped RIP sits in RTL raise-plumbing (no user
  // locals), while the reported top frame is the user frame that raised. When no
  // frame is explicitly selected, resolve locals for that trimmed top user frame
  // so a nested proc which raised still shows its locals (F11). ClearActiveFrame
  // in the finally keeps run-control on the raw stopped context.
  var Retarget := FStoppedOnException and not FFrameSelected;
  if Retarget then begin
    if Length(FLastFrames) = 0 then
      GetCallStack;   // populate the trimmed frame cache
    Retarget := (Length(FLastFrames) > 0) and (FLastFrames[0].FrameRBP <> 0);
    if Retarget then
      FDebugger.SetActiveFrame(FLastFrames[0].FrameRBP, FLastFrames[0].FuncEntryVA,
        FLastFrames[0].FunctionName, FLastFrames[0].IP);
  end;
  try
    var Locals := FDebugger.GetLocalValues;
    SetLength(Result, Length(Locals));
    for var I := 0 to High(Locals) do
      Result[I] := LocalToSession(Locals[I]);
    // Inside an anonymous method body, the captured variables live in the hidden
    // Self ($ActRec) object, not the (empty) stack-local set -- surface them.
    AppendClosureCapturedLocals(Result);
  finally
    if Retarget then
      FDebugger.ClearActiveFrame;
  end;
end;

function TDebugSession.IsAnonBodyFunc(const Fn: string): Boolean;
begin
  // Compiler-generated closure body, e.g. `RunClosureSampler$ActRec.$0$Body`.
  Result := Fn.Contains('$ActRec') and Fn.Contains('$Body');
end;

function TDebugSession.TryFindClosureSelf(out SelfAddr: UInt64;
  out ClassName: string): Boolean;

  function Consider(P: UInt64): Boolean;
  begin
    Result := False;
    if (P < 65536) or (FRtti = nil) or not FRtti.IsClassInstance(P) then Exit;
    var Cn := FRtti.GetInstanceClassName(P);
    if (Cn = '') or not Cn.Contains('$ActRec') then Exit;
    var Members: TArray<TClassMember>;
    if (FDebugInfo = nil) or not FDebugInfo.GetClassMembers(Cn, Members) or
       (Length(Members) = 0) then Exit;
    SelfAddr := P; ClassName := Cn; Result := True;
  end;

begin
  Result := False;
  SelfAddr := 0; ClassName := '';
  if FDebugger = nil then Exit;
  // Self is ABI parameter 0 (RCX) of the anon body method, spilled to its Win64
  // home slot. Read it DIRECTLY -- exact, and (unlike a blind register/stack scan)
  // it cannot pick up a STALE `$ActRec` pointer left on the stack by an unrelated
  // closure that ran earlier, which would resolve the wrong class + methods.
  var Layout := FDebugger.TargetLayout;
  var SelfHome := FDebugger.CurrentFrameParamHomeAddr(0);
  if SelfHome <> 0 then begin
    var SelfPtr: UInt64 := 0;
    if FDebugger.ReadProcessMemoryAt(SelfHome, @SelfPtr, Layout.PointerSize) and
       Consider(SelfPtr) then
      Exit(True);
  end;
  // Fallback (home slot unreadable / prologue not recognised): scan the param
  // registers, then a bounded stack window around RBP/RSP.
  var Regs := FDebugger.GetRegisters;
  for var R in [Regs.Rcx, Regs.Rdx, Regs.R8, Regs.R9, Regs.Rbx,
                Regs.Rsi, Regs.Rdi, Regs.R12, Regs.R13, Regs.R14, Regs.R15] do
    if Consider(R) then Exit(True);
  // Stack slots are the TARGET's pointer size, not the debugger's: an 8-byte
  // stride over a 32-bit stack visits every other slot and covers twice the
  // intended window.
  for var Anchor in [Regs.Rbp, Regs.Rsp] do begin
    if Anchor = 0 then Continue;
    for var K := -16 to 32 do begin
      var Slot: UInt64 := 0;
      {$Q-}{$R-}
      var SlotAddr := Anchor + UInt64(Int64(K) * Layout.PointerSize);
      {$Q+}{$R+}
      if FDebugger.ReadProcessMemoryAt(SlotAddr, @Slot, Layout.PointerSize) and
         Consider(Slot) then
        Exit(True);
    end;
  end;
end;

procedure TDebugSession.AppendClosureCapturedLocals(
  var Locals: TArray<TSessionVariable>);
begin
  if (FDebugger = nil) or (FDebugInfo = nil) then Exit;
  var FnName, Src: string;
  var Line: Integer;
  if not GetCurrentLocation(FnName, Src, Line) or not IsAnonBodyFunc(FnName) then Exit;
  var SelfAddr: UInt64;
  var CloClass: string;
  if not TryFindClosureSelf(SelfAddr, CloClass) then Exit;
  var Members: TArray<TClassMember>;
  if FDebugInfo.GetClassMembers(CloClass, Members) then
    for var M in Members do begin
      if M.Kind <> cmkField then Continue;
      // Skip the activation-record base internals so only the user's captured vars
      // surface. TD32 returns the base TInterfacedObject-like fields too (a name-based
      // skip is robust across mono/BPL; the DeclClass form varies by scenario, RSM
      // leaves it empty). Captured user vars never carry these names.
      if SameText(M.Name, 'FRefCount') or SameText(M.Name, 'FMonitor') then Continue;
      var LV := Default(TLocalValue);
      LV.Name       := M.Name;
      LV.Address    := SelfAddr + UInt64(M.FieldOffset);
      LV.TypeHint   := M.TypeName;
      LV.Kind       := lkLocal;
      LV.ValueValid := FDebugger.ReadProcessMemoryAt(LV.Address, @LV.RawValue, 8);
      Locals := Locals + [LocalToSession(LV)];
    end;
  AppendAnonMethodParams(Locals, FnName, CloClass);
end;

// Surface the anonymous method's OWN declared parameters. No local/param provider
// carries their stack slots (the anon body frame has no BPREL/local record), but
// the method SIGNATURE does (TD32 ARGLIST). Map each declared param to its Win64
// ABI home slot -- Self is slot 0, so declared params start at slot 1 -- and read
// the value. A CV ARGLIST is a bare type list with no names, so parameters are
// labelled positionally (arg1, arg2, ...).
procedure TDebugSession.AppendAnonMethodParams(
  var Locals: TArray<TSessionVariable>; const FnName, CloClass: string);
begin
  var MethodName := FnName;
  var Dot := FnName.LastIndexOf('.');
  if Dot >= 0 then
    MethodName := FnName.Substring(Dot + 1);
  var Params: TArray<TMethodParam>;
  var HasSelf: Boolean;
  if not FDebugInfo.TryGetMethodParams(CloClass, MethodName, Params, HasSelf) then Exit;
  for var I := 0 to High(Params) do begin
    var AbiIndex := I;
    if HasSelf then Inc(AbiIndex);   // Self occupies ABI slot 0
    var Addr := FDebugger.CurrentFrameParamHomeAddr(AbiIndex);
    if Addr = 0 then Continue;
    var LV := Default(TLocalValue);
    LV.Name       := Format('arg%d', [I + 1]);
    LV.Address    := Addr;
    LV.TypeHint   := Params[I].TypeName;
    LV.Kind       := lkLocal;
    LV.ValueValid := FDebugger.ReadProcessMemoryAt(Addr, @LV.RawValue, 8);
    // A single param that fails to read / format must not lose the other locals.
    try
      Locals := Locals + [LocalToSession(LV)];
    except
      on E: Exception do
        DapLog(Format('AnonParams:   arg%d format EXC %s: %s', [I + 1, E.ClassName, E.Message]));
    end;
  end;
end;

// Resolve a single named variable. Prefers a top-frame local (so the result
// carries an expansion handle for a class/record/array); otherwise falls back to
// evaluating the name as an expression (fields, globals, dotted paths).
function TDebugSession.GetVariable(const Name: string): TSessionVariable;
begin
  Result := Default(TSessionVariable);
  Result.Name         := Name;
  Result.EvaluateName := Name;
  if (FState <> dsStopped) or (FDebugger = nil) then begin
    Result.Value := '<not stopped>';
    Exit;
  end;
  for var V in GetLocals do
    if SameText(V.Name, Name) then
      Exit(V);
  var R := Evaluate(Name);
  if R.Success then begin
    Result.Value    := R.Value;
    Result.TypeName := R.TypeName;
  end
  else
    Result.Value := R.ErrorText;
end;

function TDebugSession.FormatExprValue(const E: TExprValue): string;
var
  LV: TLocalValue;
begin
  LV            := Default(TLocalValue);
  LV.TypeHint   := E.TypeHint;
  LV.Address    := E.Address;
  LV.RawValue   := E.RawValue;
  LV.ValueValid := E.IsValid;
  LV.Kind       := lkLocal;
  Result := Readers.FormatLocalValue(LV);
end;

function TDebugSession.Evaluate(const Expr: string): TSessionEvalResult;
begin
  // Delegate to the rich frame-scoped path (top frame): a bare Evaluate then gets
  // the same class/handle decoration (F8) AND the exception-stop frame retarget so
  // a local in a nested proc that raised resolves (F11). ErrorText format preserved.
  Result := EvaluateForFrame(Expr, 0);
end;

// Frame-scoped rich evaluate: ExprEval + the full class/VMT/nil/variant-array
// decoration block, ported verbatim from the DAP evaluate handler so both the
// DAP and MCP frontends produce identical hover/watch rendering and expandable
// results. Warm-up + miss-cache stay in the frontend, which re-invokes this on a
// miss (IsValid=False) after warming module providers.
function TDebugSession.EvaluateForFrame(const Expr: string;
  FrameIndex: Integer; ThreadId: Cardinal = 0): TSessionEvalResult;
begin
  var Guard := InteractiveWait;   // bound symbol-index waits (F14)
  Result := Default(TSessionEvalResult);
  if (FState <> dsStopped) or (FDebugger = nil) or (FDebugger.ProcessHandle = 0) then begin
    Result.Success   := False;
    Result.IsValid   := False;
    Result.ErrorText := 'Cannot evaluate: the debuggee is not stopped. Pause or wait for a stop first.';
    Result.Value     := Result.ErrorText;
    Exit;
  end;

  EnsureRtti;    // lazy-create FRtti so ExprEval / VMT probes can read the target
  SyncExpander;  // MakeClassExpansion / MakeVariantArrayExpansion need current deps

  // SelectFrame reads the trimmed frame cache; at an exception stop it needs it
  // populated so frame 0 retargets off the RTL raise-plumbing to the user frame (F11).
  if FStoppedOnException and (Length(FLastFrames) = 0) then
    GetCallStack;
  SelectFrame(FrameIndex, ThreadId);
  try
    var Val: TExprValue := Default(TExprValue);
    var Display: string;
    var Eval := TExprEvaluator.Create(FDebugger, FRtti, FDebugInfo);
    try
      if Eval.Evaluate(Expr, Val) then
        Display := FormatExprValue(Val)
      else
        Display := Val.TypeHint;  // error message like '<X: not found>'
    finally
      Eval.Free;
    end;

    // Nil-class fallback for globals: a bare known global whose value is nil with
    // no resolved TypeHint renders as `nil` rather than `0  (0x0)`.
    if Val.IsValid and (Val.TypeHint = '') and (Val.RawValue = 0) and (FDebugInfo <> nil) then begin
      var GSym: TGlobalSymbol;
      if FDebugInfo.FindGlobal(Expr, GSym) then
        Display := 'nil';
    end;

    // Runtime-VMT class-name derivation when the static TypeHint is empty (or an
    // RTL alias for a slot that actually holds a class instance). Tries the direct
    // pointer and one extra dereference (Win64 spills some on-clause `E: Exception`
    // locals as pointer-to-pointer).
    if Val.IsValid and (Val.RawValue >= 65536) and (FRtti <> nil) then begin
      var Probe: UInt64 := Val.RawValue;
      var IsInst := FRtti.IsClassInstance(Probe);
      if (not IsInst) and FDebugger.ReadProcessMemoryAt(Val.RawValue, @Probe, 8) and
         (Probe >= 65536) and FRtti.IsClassInstance(Probe) then begin
        Val.RawValue := Probe;
        IsInst := True;
      end;
      if IsInst then begin
        var Resolved := FRtti.GetInstanceClassName(Val.RawValue);
        if Resolved <> '' then begin
          var ShouldOverride := (Val.TypeHint = '');
          if (not ShouldOverride) and (FDebugInfo <> nil) then begin
            var TH_Kind := FDebugInfo.LookupTypeKind(Val.TypeHint);
            ShouldOverride := (TH_Kind <> 0) and
                              (TH_Kind <> TK_CLASS) and
                              (TH_Kind <> TK_INTERFACE);
          end;
          if ShouldOverride then
            Val.TypeHint := Resolved;
        end;
      end;
    end;

    // Class / record decoration: show `$addr (TFoo)` (or `nil (TFoo)`), and mint a
    // member/RTTI expansion so the frontend can offer an expand chevron.
    var ExpHandle: TVarHandle := 0;
    var Kind: Byte := 0;
    if (Val.TypeHint <> '') and (FDebugInfo <> nil) then
      Kind := FDebugInfo.LookupTypeKind(Val.TypeHint);
    if Val.IsValid and (Val.TypeHint <> '') and
       ((Kind = 0) or IsExpandableTKind(Kind)) then begin
      var Members: TArray<TClassMember>;
      var HasMembers := FExpander.GetDisplayMembers(Val.TypeHint, Members) and
                        (Length(Members) > 0);
      var IsClassInst := (FRtti <> nil) and (Val.RawValue >= 65536) and
                         FRtti.IsClassInstance(Val.RawValue);
      if IsExpandableTKind(Kind) or HasMembers or IsClassInst then begin
        var DisplayAddr: UInt64;
        if IsClassInst then
          DisplayAddr := Val.RawValue
        else
          DisplayAddr := Val.Address;
        if (Kind = TK_CLASS) and (Val.RawValue = 0) then
          Display := Format('nil (%s)', [Val.TypeHint])
        else
          Display := Format('$%x (%s)', [DisplayAddr, Val.TypeHint]);
        if (DisplayAddr >= 65536) and (HasMembers or IsClassInst) then
          ExpHandle := FExpander.MakeClassExpansion(DisplayAddr, Val.TypeHint, Expr);
      end;
    end;

    // VarArray Variant: mint an array expansion (returns 0 for non-arrays). Runs
    // after class/record decoration so a class ref doesn't trigger it.
    if (ExpHandle = 0) and Val.IsValid and (Val.Address <> 0) then
      ExpHandle := FExpander.MakeVariantArrayExpansion(Val.Address, Expr);

    Result.Success    := Val.IsValid;
    Result.IsValid    := Val.IsValid;
    Result.RawValue   := Val.RawValue;
    Result.Value      := Display;
    Result.TypeName   := Val.TypeHint;
    Result.Handle     := ExpHandle;
    Result.Expandable := ExpHandle <> 0;
    if not Val.IsValid then
      Result.ErrorText := Display;
  finally
    ClearFrame;  // never leave a stale active frame across a resume
  end;
end;

function TDebugSession.GetExceptionDetails: TSessionExceptionInfo;
begin
  Result := Default(TSessionExceptionInfo);
  if FDebugger = nil then
    Exit;
  Result.ExceptionClass := FDebugger.LastExceptionClass;
  Result.Message        := FDebugger.LastExceptionMessage;
  Result.Description    := FDebugger.LastExceptionDesc;
  Result.OsThreadId     := FStopTid;
  Result.ObjectVA       := FDebugger.CurrentExceptionObject;
  Result.Frames         := GetCallStack;
end;

function TDebugSession.Snapshot: TCompactSnapshot;
const
  // A generous preview so the compact snapshot is not misleadingly shallow (F12).
  // get_call_stack still returns the complete stack.
  MAX_TOP_FRAMES = 32;
begin
  var Guard := InteractiveWait;   // one shared symbol-index budget for the whole snapshot (F14)
  Result := Default(TCompactSnapshot);
  Result.State      := FState;
  Result.StopReason := FStopReason;
  Result.OsThreadId := FStopTid;
  if FState <> dsStopped then
    Exit;

  var FnName, SrcFile: string;
  var Ln: Integer;
  if GetCurrentLocation(FnName, SrcFile, Ln) then begin
    Result.CurrentFunction := FnName;
    Result.CurrentFile     := SrcFile;
    Result.CurrentLine     := Ln;
  end;

  var Frames := GetCallStack;
  if Length(Frames) > MAX_TOP_FRAMES then
    SetLength(Frames, MAX_TOP_FRAMES);
  Result.TopFrames := Frames;
  Result.Locals    := GetLocals;

  if FStoppedOnException then begin
    Result.HasException := True;
    Result.Exception_   := GetExceptionDetails;
  end;
end;

function TDebugSession.DrainDebuggeeOutput: TArray<string>;
begin
  Result := FDebuggeeOutput.ToArray;
  FDebuggeeOutput.Clear;
end;

function TDebugSession.DrainDebuggerOutput: TArray<string>;
begin
  Result := FDebuggerOutput.ToArray;
  FDebuggerOutput.Clear;
end;


end.
