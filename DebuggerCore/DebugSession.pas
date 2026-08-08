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
  DelphiRtti, DelphiValueReaders, ExprEval, WinDebuggerBase, WinDebuggerX86,
  SourceResolver,
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
  // A data breakpoint the session REMOVED on its own, with the reason. Today
  // that is exactly one case: a frame-scoped watchpoint whose frame has exited
  // (increment 6 of DATA_BREAKPOINTS_PLAN.md). The user must be told -- a
  // watchpoint silently left on dead stack reports hits that are lies.
  TSessionDataBpRemovedEvent  = procedure(const Bp: TSessionDataBreakpoint;
                                  const Reason: string) of object;

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

    // Data breakpoints (watchpoints; increment 4 of DATA_BREAKPOINTS_PLAN.md).
    // Unlike source breakpoints there is no per-file grouping -- SetDataBreakpoints
    // replaces the WHOLE set on every call, mirroring DAP's own setDataBreakpoints.
    FDataBreakpoints: TList<TSessionDataBreakpoint>;
    FNextDataBpId:    Integer;
    // Set by PruneStaleDataBreakpoints when the watchpoint that produced THIS
    // stop is the one just found stale, so the stop description says the hit
    // landed on reused stack instead of reading like a genuine change. Cleared
    // at the start of every stop.
    FStaleDataBpNote: string;

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
    FOnDataBpRemoved:           TSessionDataBpRemovedEvent;
    FOnSymbolsArrived:          TNotifyEvent;

    function  Readers: TDelphiValueReader;
    procedure SetState(NewState: TDebugSessionState);
    function  BuildAndWireDebugger(PreferredBase: UInt64): Boolean;
    procedure ApplyPendingBreakpoints;
    // Resolves a data-breakpoint expression to a live VA: a literal address
    // ("$hex" / "0xhex" / a plain decimal), else a global/unit variable via the
    // same resolution the evaluator uses. Distinguishes "no such symbol" from
    // "that IS a symbol, but a LOCAL" (RejectReason names which, so the caller
    // is told WHY rather than just that it failed) -- KnownLocal is set only in
    // the second case. ModuleName/Rva are populated when Addr falls inside a
    // module GetModules currently knows about; '' / 0 otherwise.
    function  ResolveDataBpAddress(const Expression: string; out Addr: UInt64;
                out ModuleName: string; out Rva: UInt64; out KnownLocal: Boolean;
                out RejectReason: string): Boolean;
    // Resolves and arms ONE spec via IDebugTarget.ApplyDataBreakpointCommand,
    // filling in every field of the returned record including the failure
    // case (Verified=False, Message=why).
    function  ArmOneDataBreakpoint(const Spec: TDataBpSpec): TSessionDataBreakpoint;
    // "expression: old -> new (thread N)" from the engine's last watchpoint
    // hit. Shared by HandleTargetStopped (the OnStopped event) and Snapshot
    // (a later poll) so the two never disagree.
    function  BuildDataBreakpointDescription: string;
    // Is the frame a dbsLocal watchpoint was scoped to still on its thread's
    // stack? Answerable only AT A STOP, which is why staleness is detected at a
    // stop and nowhere else.
    function  FrameStillLive(const Frame: TDataBpFrameScope): Boolean;
    // Called at every stop, before the stop is reported. Removes (and clears the
    // hardware slot of) every frame-scoped watchpoint whose frame is gone, and
    // fires OnDataBreakpointRemoved for each. Runs only when a frame-scoped
    // watchpoint exists, so an ordinary stop costs nothing.
    procedure PruneStaleDataBreakpoints;
    // Byte width to watch for a resolved local/global, from its declared type.
    // 0 = could not be established at one of the four hardware widths, which is
    // a REFUSAL (never a rounded guess -- the hardware ignores the low address
    // bits, so a wrong width watches a neighbouring cell).
    function  WatchWidthForType(const TypeHint: string; TypeKind: Byte): Integer;
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
    // A bare identifier, so the closure-capture fallback in EvaluateForFrame is
    // only tried for names a captured variable could have.
    function  IsPlainIdentifier(const S: string): Boolean;
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
    // Address breakpoints (DISASSEMBLY_PLAN.md increment 5). Identity is
    // (ModuleName, Rva), resolved from the caller's absolute address at SET
    // time against GetModules -- never a bare VA, which is meaningless across
    // a relaunch or an ASLR-rebased package.
    function  ResolveModuleForAddress(Address: UInt64;
                out ModuleName: string; out ModuleBase: UInt64): Boolean;
    // Translates a FRIENDLY module name (as stored in TSessionBreakpoint.ModuleName
    // and reported to a caller -- the exe's own lowercase filename for the main
    // module) into the identity the ENGINE expects on TAddrBpSpec.ModuleName: ''
    // for the main exe, matching TWinDebugger's own convention (FDllBases only
    // ever holds runtime-loaded DLL/BPL entries, never the main exe -- exactly
    // like FImageBase is consulted separately from FDllBases everywhere else in
    // the engine). Anything else (a real DLL/BPL name) passes through unchanged.
    function  EngineModuleNameFor(const FriendlyModuleName: string): string;
    function  HaveAddressBreakpoints: Boolean;
    // Re-derives Verified/Address/Message for every stored address breakpoint
    // against the CURRENT module table, then reposts each affected module's
    // whole address-breakpoint set to the engine (which drops/replants
    // depending on whether that module is loaded right now). ExtraModule, when
    // non-empty, forces an explicit clear command for a module that no longer
    // owns ANY address breakpoint (a removal can empty a module's set
    // entirely, in which case it would not otherwise appear in this sweep).
    procedure RepostAddressBreakpoints(const ExtraModule: string = '');
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

    // Breakpoint at an ABSOLUTE ADDRESS rather than a source line
    // (DISASSEMBLY_PLAN.md increment 5) -- what makes a disassembly view
    // actionable. The address is resolved to (ModuleName, Rva) against the
    // CURRENT module table (GetModules) at set time and that pair, not the
    // bare VA, is the breakpoint's identity: it re-resolves to a fresh VA
    // whenever the named module (re)loads, exactly like a source breakpoint's
    // deferred binding. An address inside a module that is NOT currently
    // loaded cannot be attributed to anything -- refused with Verified=False
    // and Message set, never planted at a VA that may belong to something
    // else once a module maps there. Conditions/hit-counts/logpoints reuse
    // the same per-breakpoint machinery source breakpoints already use.
    // Idempotent: setting the same (module, rva) again replaces the prior
    // entry rather than duplicating it. Appears in ListBreakpoints alongside
    // source breakpoints, Kind=bkAddress.
    function  SetAddressBreakpoint(Address: UInt64;
                const Condition, HitCondition, LogMessage: string): TSessionBreakpoint;
    // Removes one address breakpoint by its Id (as returned by
    // SetAddressBreakpoint / ListBreakpoints). False when no bkAddress entry
    // has that Id.
    function  RemoveAddressBreakpoint(const Id: string): Boolean;

    // Data breakpoints (watchpoints; increment 4 of DATA_BREAKPOINTS_PLAN.md).
    // Mirrors the source-breakpoint API's shape, but SetDataBreakpoints
    // replaces the WHOLE set on every call (no per-file grouping exists for an
    // address), matching DAP's own setDataBreakpoints semantics. Only callable
    // while State = dsStopped: arming reads/writes live thread contexts, which
    // are only stable at a stop (the same reason DAP's own dataBreakpointInfo /
    // setDataBreakpoints only make sense there). Each spec is resolved and
    // armed independently and reports its OWN Verified/Message -- one bad
    // expression does not fail the others.
    function  SetDataBreakpoints(const Specs: TArray<TDataBpSpec>): TArray<TSessionDataBreakpoint>;
    function  ListDataBreakpoints: TArray<TSessionDataBreakpoint>;
    procedure RemoveAllDataBreakpoints;
    // Can this variable be watched, and at what address/width? The neutral
    // engine behind DAP's dataBreakpointInfo request (increment 6).
    //
    // Name is resolved in frame FrameIndex of thread ThreadId (0 = the stopped
    // thread) exactly as the locals view resolves it, then as a global, then as
    // a literal address. A LOCAL comes back Kind=dbsLocal with Frame filled in:
    // its address is only valid while that frame lives, and the caller must
    // hand Frame back in the spec so the session can retire the watchpoint the
    // moment the frame is gone.
    //
    // Everything that cannot be justified is REFUSED with a Reason: a
    // register-allocated local (no address at all), a type whose width is not
    // 1/2/4/8, a misaligned address, an unknown name. Never a rounded guess.
    function  GetDataBreakpointInfo(const Name: string; FrameIndex: Integer;
                ThreadId: Cardinal = 0): TDataBpTargetInfo;

    // Introspection (valid only when State = dsStopped).
    function  GetCallStack: TArray<TSessionFrame>; overload;
    // Per-thread call stack (read-only). Delegates to the engine's TID-scoped
    // stack walk; does NOT disturb the stopped thread's cached FLastFrames.
    function  GetCallStack(ThreadId: Cardinal): TArray<TSessionFrame>; overload;
    // Opt-in brute-force sweep of the thread's stack for return addresses, for
    // when the exact walk STOPS in code with no unwind data and the question
    // becomes "which of my routines is underneath this". Separate from
    // GetCallStack on purpose: the results are positions, not a chain.
    function  GetRawStackScan(ThreadId: Cardinal = 0;
                MaxItems: Integer = 0): TArray<TSessionFrame>;
    // Every image mapped in the debuggee, main module first, with its symbol
    // state and the debug-info formats that actually loaded for it. Valid
    // whenever a process exists -- it describes the address space, not a stop.
    function  GetModules: TArray<TSessionModule>;
    function  GetModuleSources: TArray<TSessionModuleSources>;
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
    // AllowCalls=False forbids running anything in the debuggee: no methods, no
    // property getters, no speculative parameterless invocation. Pass False for
    // a HOVER, where the user rested the mouse and did not ask for an effect.
    // Plain reads still resolve.
    function  EvaluateForFrame(const Expr: string; FrameIndex: Integer;
                ThreadId: Cardinal = 0;
                AllowCalls: Boolean = True): TSessionEvalResult;
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
    // Fired when the session retires a data breakpoint by itself (a frame-scoped
    // watchpoint whose frame has exited). Unsubscribed = the watchpoint is still
    // removed, the user simply is not told -- so a frontend that offers
    // frame-scoped watchpoints must subscribe.
    property OnDataBreakpointRemoved: TSessionDataBpRemovedEvent
      read FOnDataBpRemoved write FOnDataBpRemoved;
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
  FDataBreakpoints := TList<TSessionDataBreakpoint>.Create;
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
  // A session going away still OWNS whatever it started. Dropping the engine
  // reference without saying so left a launched debuggee running with nobody
  // able to control it any more: during a suite run hundreds piled up, alive
  // until the runner exited and Windows collected them, loading the machine
  // enough to make timing-sensitive behaviour (the symbol-index warm-up) worse.
  //
  // StopDebugging already encodes the ownership rule -- terminate what we
  // launched, DETACH from what we attached to -- so an attached process we were
  // asked to leave running is still left running.
  if FDebugger <> nil then
    try
      StopDebugging;
    except
      // Teardown must not raise out of a destructor; the engine may already be
      // gone (target exited, adapter shutting down).
      on E: Exception do
        DapLog('TDebugSession.Destroy: StopDebugging raised ' + E.ClassName +
               ': ' + E.Message);
    end;
  FDebugger := nil;  // release the IDebugTarget refcount (engine teardown)
  FReaders.Free;
  FRtti.Free;
  FExpander.Free;        // frees only its handle table; reader refs not owned
  FBpEval.Free;          // owns nothing; reader/rtti refs not owned
  FDebuggerOutput.Free;
  FDebuggeeOutput.Free;
  FLoader.Free;          // removes its module providers from FDebugInfo, frees
                         // the registry; main readers released below via ARC
  FDataBreakpoints.Free;
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
    FRtti := TDelphiRtti.Create(FDebugger.ProcessHandle, FDebugger.TargetLayout);
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
  // The target's architecture decides the class, and it has to be known BEFORE
  // the object exists. IsWow64Process2 cannot answer until
  // CREATE_PROCESS_DEBUG_EVENT, which is long after construction; the on-disk
  // PE header can answer now. TWinDebugger's own TargetIsWow64 check remains,
  // demoted to an assertion that the live process agrees with what we built.
  if ReadPEMachine(FExePath) = IMAGE_FILE_MACHINE_I386 then
    FDebugger := TWin32Debugger.Create(FDebugInfo, PreferredBase)
  else
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

function TDebugSession.BuildDataBreakpointDescription: string;
begin
  Result := '';
  if FDebugger = nil then
    Exit;
  var Hit := FDebugger.LastHardwareWatchpointHit;
  var Name := Hit.Description;
  if Name = '' then
    Name := Format('$%x', [Hit.Address]);
  Result := Format('%s: $%x -> $%x (thread %d)',
    [Name, Hit.OldValue, Hit.NewValue, Hit.ThreadId]);
  // The hit that produced THIS stop came from a watchpoint whose frame had
  // already exited: the cell it names is reused stack, not the variable the
  // user asked about. Saying "old -> new" alone would be a lie.
  if FStaleDataBpNote <> '' then
    Result := Result + ' -- ' + FStaleDataBpNote;
end;

function TDebugSession.ListBreakpoints: TArray<TSessionBreakpoint>;
begin
  Result := FBreakpoints.ToArray;
end;

function TDebugSession.ResolveDataBpAddress(const Expression: string; out Addr: UInt64;
  out ModuleName: string; out Rva: UInt64; out KnownLocal: Boolean;
  out RejectReason: string): Boolean;

  // A literal address: "$hex", "0xhex", or a plain decimal. Anything else
  // falls through to symbol resolution.
  function TryParseLiteral(const S: string; out V: UInt64): Boolean;
  var
    Norm: string;
  begin
    Norm := S;
    if (Norm <> '') and (Norm[1] = '$') then
      // already Delphi hex syntax
    else if (Length(Norm) > 2) and (Norm[1] = '0') and
            CharInSet(Norm[2], ['x', 'X']) then
      Norm := '$' + Copy(Norm, 3, MaxInt)
    else if not ((Norm <> '') and CharInSet(Norm[1], ['0'..'9'])) then
      Exit(False);
    Result := TryStrToUInt64(Norm, V);
  end;

var
  Expr: string;
  V:    UInt64;
  LV:   TLocalValue;
begin
  Result       := False;
  Addr         := 0;
  ModuleName   := '';
  Rva          := 0;
  KnownLocal   := False;
  RejectReason := '';
  Expr := Trim(Expression);

  if TryParseLiteral(Expr, V) then begin
    Addr   := V;
    Result := True;
  end else if (FDebugger <> nil) and FDebugger.EvaluateGlobalName(Expr, LV) and
              (LV.Address <> 0) then begin
    Addr   := LV.Address;
    Result := True;
  end else if (FDebugger <> nil) and FDebugger.EvaluateLocalName(Expr, LV) then begin
    // A real symbol, but its address only means something for the lifetime of
    // the frame that owns it -- refuse explicitly rather than arm a watchpoint
    // that will silently start watching reused stack once the frame is gone.
    KnownLocal   := True;
    RejectReason := 'local variables are not supported yet -- their lifetime is ' +
      'tied to the stack frame (dataBreakpointInfo, increment 6); watch the ' +
      'containing global, or pass a literal address, instead';
    Exit(False);
  end else begin
    RejectReason := 'unresolved symbol: ' + Expr;
    Exit(False);
  end;

  for var M in GetModules do
    if (M.Size > 0) and (Addr >= M.Base) and (Addr < M.Base + M.Size) then begin
      ModuleName := M.Name;
      Rva        := Addr - M.Base;
      Break;
    end;
end;

function TDebugSession.ArmOneDataBreakpoint(const Spec: TDataBpSpec): TSessionDataBreakpoint;
begin
  Result := Default(TSessionDataBreakpoint);
  Inc(FNextDataBpId);
  Result.Id         := 'databp' + IntToStr(FNextDataBpId);
  Result.Expression := Spec.Expression;
  Result.SizeBytes   := Spec.SizeBytes;
  Result.WriteOnly   := Spec.WriteOnly;
  Result.Slot        := -1;
  Result.DisplayName := Spec.DisplayName;
  Result.Frame       := Spec.Frame;

  // A frame-scoped spec carries an address that was resolved against ONE live
  // frame. Re-arming it after that frame has exited would watch reused stack,
  // which is the whole failure mode frame scoping exists to prevent -- so the
  // liveness test runs here too, not only at the stop-time prune.
  if Spec.Frame.Scoped and not FrameStillLive(Spec.Frame) then begin
    var Shown := Spec.DisplayName;
    if Shown = '' then
      Shown := Spec.Expression;
    Result.Message := Format('the stack frame that owned %s (thread %d) is no longer ' +
      'on the stack -- its address is now reused stack; select the variable again ' +
      'in a live frame', [Shown, Spec.Frame.ThreadId]);
    Exit;
  end;

  if not (Spec.SizeBytes in [1, 2, 4, 8]) then begin
    Result.Message := Format('unsupported size %d bytes (must be 1, 2, 4 or 8)',
      [Spec.SizeBytes]);
    Exit;
  end;

  var Addr:       UInt64;
  var ModName:    string;
  var Rva:        UInt64;
  var KnownLocal: Boolean;
  var Reason:     string;
  if not ResolveDataBpAddress(Spec.Expression, Addr, ModName, Rva, KnownLocal, Reason) then begin
    Result.Message := Reason;
    Exit;
  end;

  if (Addr mod UInt64(Spec.SizeBytes)) <> 0 then begin
    Result.Message := Format('address $%x is not aligned to %d bytes',
      [Addr, Spec.SizeBytes]);
    Exit;
  end;

  Result.ModuleName := ModName;
  Result.Rva        := Rva;
  Result.Address     := Addr;

  if FDebugger = nil then begin
    Result.Message := 'no active debug session';
    Exit;
  end;

  var ArmSpec: TDataBpArmSpec;
  ArmSpec := Default(TDataBpArmSpec);
  ArmSpec.Address          := Addr;
  ArmSpec.SizeBytes        := Spec.SizeBytes;
  ArmSpec.WriteOnly        := Spec.WriteOnly;
  // What a stop description will call this watchpoint. A frame-scoped local
  // arrives as a literal address, so without DisplayName every hit would read
  // "$19fe44: ..." instead of naming the variable the user picked.
  if Spec.DisplayName <> '' then
    ArmSpec.OwnerDescription := Spec.DisplayName
  else
    ArmSpec.OwnerDescription := Spec.Expression;

  var Slot: Integer;
  var RefusalReason: string;
  if FDebugger.ApplyDataBreakpointCommand(ArmSpec, Slot, RefusalReason) then begin
    Result.Slot     := Slot;
    Result.Verified := True;
    // x86 has no read-only hardware watchpoint: a caller that asked for
    // read-or-write did not filter anything, and the honest thing is to say
    // so rather than let a surprise write-hit look like a bug.
    if not Spec.WriteOnly then
      Result.Message := 'no read-only watchpoint on this CPU -- also fires on writes';
  end else
    Result.Message := RefusalReason;
end;

function TDebugSession.SetDataBreakpoints(
  const Specs: TArray<TDataBpSpec>): TArray<TSessionDataBreakpoint>;
begin
  SetLength(Result, Length(Specs));
  if (FDebugger = nil) or (FState <> dsStopped) then begin
    for var I := 0 to High(Specs) do begin
      Result[I] := Default(TSessionDataBreakpoint);
      Result[I].Expression := Specs[I].Expression;
      Result[I].SizeBytes  := Specs[I].SizeBytes;
      Result[I].WriteOnly  := Specs[I].WriteOnly;
      Result[I].Slot       := -1;
      Result[I].Message    := 'data breakpoints can only be set while stopped';
    end;
    Exit;
  end;

  // Whole-set replace, mirroring DAP's own setDataBreakpoints -- there is no
  // per-file grouping for an address the way there is for a source line.
  RemoveAllDataBreakpoints;
  for var I := 0 to High(Specs) do begin
    var Bp := ArmOneDataBreakpoint(Specs[I]);
    FDataBreakpoints.Add(Bp);
    Result[I] := Bp;
  end;
end;

function TDebugSession.ListDataBreakpoints: TArray<TSessionDataBreakpoint>;
begin
  Result := FDataBreakpoints.ToArray;
end;

procedure TDebugSession.RemoveAllDataBreakpoints;
begin
  if FDebugger <> nil then
    for var Bp in FDataBreakpoints do
      if Bp.Slot >= 0 then begin
        var ClearSpec: TDataBpArmSpec;
        ClearSpec := Default(TDataBpArmSpec);
        ClearSpec.Clear := True;
        ClearSpec.Slot  := Bp.Slot;
        var Slot: Integer;
        var Reason: string;
        FDebugger.ApplyDataBreakpointCommand(ClearSpec, Slot, Reason);
      end;
  FDataBreakpoints.Clear;
end;

// A local's address is a stack slot, and a stack slot means the variable the
// user picked only while the frame that owns it is still there. There is no way
// to be told when a frame is popped -- a `ret` is not an event -- so the frame
// is checked at every STOP, which is the only moment the stack can be read.
//
// Identity is (FrameBase, FuncEntryVA), not FrameBase alone: an unrelated
// routine reaching the same stack depth gets the same base and would otherwise
// look like the original frame.
//
// One case remains undetectable BY CONSTRUCTION, and is a limitation rather
// than a bug: the SAME routine called again at the SAME stack depth produces an
// identical (FrameBase, FuncEntryVA) pair. The watchpoint then follows the same
// local of a NEW invocation -- the same variable in the same routine, a
// different call. It can never drift onto a DIFFERENT variable, which is the
// failure this whole mechanism exists to prevent.
function TDebugSession.FrameStillLive(const Frame: TDataBpFrameScope): Boolean;
begin
  Result := False;
  if (not Frame.Scoped) or (FDebugger = nil) or (FState <> dsStopped) then
    Exit;
  var Tid := Frame.ThreadId;
  if Tid = 0 then
    Tid := FStopTid;
  // The RAW walk on purpose: no symbol loading, no raise-plumbing trim, and no
  // write to the stopped thread's frame cache. This runs at every stop while a
  // frame-scoped watchpoint exists, and it only needs geometry.
  for var F in FDebugger.GetStackFrames(Tid) do
    if (F.FrameRBP = Frame.FrameBase) and (F.FuncEntryVA = Frame.FuncEntryVA) then
      Exit(True);
end;

procedure TDebugSession.PruneStaleDataBreakpoints;
begin
  FStaleDataBpNote := '';
  if (FDebugger = nil) or (FDataBreakpoints.Count = 0) then
    Exit;

  var AnyScoped := False;
  for var Bp in FDataBreakpoints do
    if Bp.Frame.Scoped then begin
      AnyScoped := True;
      Break;
    end;
  if not AnyScoped then
    Exit;

  // When THIS stop is a watchpoint hit, remember which address fired, so a hit
  // produced by the very watchpoint being retired can be labelled as landing on
  // reused stack instead of being reported as a genuine change.
  var HitAddress: UInt64 := 0;
  if FStopReason = srDataBreakpoint then
    HitAddress := FDebugger.LastHardwareWatchpointHit.Address;

  for var I := FDataBreakpoints.Count - 1 downto 0 do begin
    var Bp := FDataBreakpoints[I];
    if not Bp.Frame.Scoped then
      Continue;
    if FrameStillLive(Bp.Frame) then
      Continue;

    var Shown := Bp.DisplayName;
    if Shown = '' then
      Shown := Bp.Expression;

    if Bp.Slot >= 0 then begin
      var ClearSpec: TDataBpArmSpec;
      ClearSpec       := Default(TDataBpArmSpec);
      ClearSpec.Clear := True;
      ClearSpec.Slot  := Bp.Slot;
      var Slot: Integer;
      var Reason: string;
      FDebugger.ApplyDataBreakpointCommand(ClearSpec, Slot, Reason);
    end;
    FDataBreakpoints.Delete(I);

    if (HitAddress <> 0) and (HitAddress = Bp.Address) then
      FStaleDataBpNote := Format('STALE: the frame that owned %s has exited, so this ' +
        'hit was on reused stack, not on the variable; the data breakpoint has been ' +
        'removed', [Shown]);

    if Assigned(FOnDataBpRemoved) then
      FOnDataBpRemoved(Bp, Format('data breakpoint on %s removed: the stack frame that ' +
        'owned it (thread %d) has exited, so its address is now reused stack',
        [Shown, Bp.Frame.ThreadId]));
  end;
end;

function TDebugSession.WatchWidthForType(const TypeHint: string;
  TypeKind: Byte): Integer;
const
  // Delphi TTypeKind ordinals whose STORAGE is one pointer: the variable itself
  // holds a reference. Watching it answers "when is this reference reassigned",
  // which is the only thing a hardware slot can answer about them.
  TK_CLASS_    = 7;
  TK_LSTRING   = 10;
  TK_WSTRING   = 11;
  TK_INTERFACE_= 15;
  TK_DYNARRAY  = 17;
  TK_USTRING   = 18;
  TK_CLASSREF  = 19;
  TK_POINTER   = 20;
var
  PtrSize: Integer;

  function NamedWidth(const N: string): Integer;
  begin
    for var Nm in ['Byte', 'ShortInt', 'Boolean', 'ByteBool', 'AnsiChar', 'UInt8', 'Int8'] do
      if SameText(N, Nm) then Exit(1);
    for var Nm in ['Word', 'SmallInt', 'WordBool', 'Char', 'WideChar', 'UInt16', 'Int16'] do
      if SameText(N, Nm) then Exit(2);
    for var Nm in ['Integer', 'LongInt', 'Cardinal', 'LongWord', 'LongBool', 'Single',
                   'UInt32', 'Int32', 'FixedInt', 'FixedUInt'] do
      if SameText(N, Nm) then Exit(4);
    for var Nm in ['Int64', 'UInt64', 'Double', 'Currency', 'TDateTime', 'TDate',
                   'TTime', 'Comp', 'Real'] do
      if SameText(N, Nm) then Exit(8);
    for var Nm in ['Pointer', 'NativeInt', 'NativeUInt', 'THandle', 'string',
                   'UnicodeString', 'AnsiString', 'WideString', 'PChar', 'PAnsiChar',
                   'PWideChar'] do
      if SameText(N, Nm) then Exit(PtrSize);
    // Extended is the one float whose width is target-dependent: 10 bytes of x87
    // on Win32 (no hardware watchpoint width fits it), a plain Double on Win64.
    if SameText(N, 'Extended') then
      Exit(WideFloatByteSize(N, PtrSize));
    Result := 0;
  end;

begin
  PtrSize := 8;
  if FDebugger <> nil then
    PtrSize := FDebugger.TargetLayout.PointerSize;

  Result := NamedWidth(Trim(TypeHint));
  if Result = 0 then begin
    var Sz: Integer;
    if (FDebugInfo <> nil) and FDebugInfo.GetTypeSize(TypeHint, Sz) and (Sz > 0) then
      Result := Sz;
  end;
  if (Result = 0) and (TypeKind in [TK_CLASS_, TK_LSTRING, TK_WSTRING, TK_INTERFACE_,
                                    TK_DYNARRAY, TK_USTRING, TK_CLASSREF, TK_POINTER]) then
    Result := PtrSize;
  // Anything the hardware cannot express is NOT rounded down to a slot that
  // would watch part of the variable and part of its neighbour.
  if not (Result in [1, 2, 4, 8]) then
    Result := 0;
end;

function TDebugSession.GetDataBreakpointInfo(const Name: string; FrameIndex: Integer;
  ThreadId: Cardinal): TDataBpTargetInfo;
var
  Tid: Cardinal;

  procedure Refuse(const AReason: string);
  begin
    Result.CanWatch := False;
    Result.Reason   := AReason;
  end;

  // A literal address: "$hex", "0xhex", or a plain decimal.
  function TryParseLiteral(const S: string; out V: UInt64): Boolean;
  begin
    var Norm := S;
    if (Norm <> '') and (Norm[1] = '$') then
      // already Delphi hex syntax
    else if (Length(Norm) > 2) and (Norm[1] = '0') and CharInSet(Norm[2], ['x', 'X']) then
      Norm := '$' + Copy(Norm, 3, MaxInt)
    else if not ((Norm <> '') and CharInSet(Norm[1], ['0'..'9'])) then
      Exit(False);
    Result := TryStrToUInt64(Norm, V);
  end;

  procedure FillModule(Addr: UInt64);
  begin
    for var M in GetModules do
      if (M.Size > 0) and (Addr >= M.Base) and (Addr < M.Base + M.Size) then begin
        Result.ModuleName := M.Name;
        Result.Rva        := Addr - M.Base;
        Break;
      end;
  end;

begin
  Result := Default(TDataBpTargetInfo);
  // The access types that genuinely exist on this CPU. `read` is absent on
  // purpose and must never be added: x86/x64 has no read-only watchpoint, and
  // advertising one would promise a filter the hardware cannot apply.
  Result.AccessWrite     := True;
  Result.AccessReadWrite := True;
  Result.ReadWriteCaveat := 'no read-only watchpoint on this CPU -- ' +
    '"readWrite" also fires on writes';

  var Expr := Trim(Name);
  if Expr = '' then begin
    Refuse('no variable name given');
    Exit;
  end;
  if (FDebugger = nil) or (FState <> dsStopped) then begin
    Refuse('data breakpoints can only be resolved while the target is stopped');
    Exit;
  end;

  Tid := ThreadId;
  if Tid = 0 then
    Tid := FStopTid;

  // A literal address is unambiguous and needs no frame at all.
  var LitAddr: UInt64;
  if TryParseLiteral(Expr, LitAddr) then begin
    var LitSize := FDebugger.TargetLayout.PointerSize;
    if (LitAddr mod UInt64(LitSize)) <> 0 then begin
      Refuse(Format('address $%x is not aligned to %d bytes', [LitAddr, LitSize]));
      Exit;
    end;
    Result.CanWatch    := True;
    Result.Kind        := dbsAddress;
    Result.Address     := LitAddr;
    Result.SizeBytes   := LitSize;
    Result.DisplayName := Format('$%x', [LitAddr]);
    FillModule(LitAddr);
    Result.Description := Format('$%x, %d bytes (default width for a literal address)',
      [LitAddr, LitSize]);
    Exit;
  end;

  // Make sure the frame cache holds the thread the caller means, so FrameIndex
  // resolves against the right stack (a frame index is only meaningful together
  // with its thread).
  if (Tid = FStopTid) and (Length(FLastFrames) = 0) then
    GetCallStack;
  SelectFrame(FrameIndex, Tid);
  try
    var LV: TLocalValue;
    if FDebugger.EvaluateLocalName(Expr, LV) then begin
      if LV.RegId > 0 then begin
        Refuse(Format('%s is held in a register in this frame, so it has no address ' +
          'a hardware watchpoint could watch', [Expr]));
        Exit;
      end;
      if (FrameIndex < 0) or (FrameIndex >= Length(FLastFrames)) then begin
        Refuse('no such stack frame');
        Exit;
      end;
      var Frm := FLastFrames[FrameIndex];
      if Frm.FrameRBP = 0 then begin
        Refuse(Format('the frame holding %s has no frame pointer, so the watchpoint ' +
          'could not be retired when the frame exits', [Expr]));
        Exit;
      end;

      // A var/reference parameter's own slot holds a POINTER; the storage the
      // user means is the pointee. Watching the slot would only report the
      // reference being rebound, which never happens.
      var Addr := LV.Address;
      var ViaRef := False;
      if LV.Kind = lkVarParam then begin
        if not (LV.DerefValid and (LV.DerefValue <> 0)) then begin
          Refuse(Format('%s is a var parameter whose target address could not be read',
            [Expr]));
          Exit;
        end;
        Addr   := LV.DerefValue;
        ViaRef := True;
      end;
      if Addr = 0 then begin
        Refuse(Format('%s has no address in this frame', [Expr]));
        Exit;
      end;

      var Width := WatchWidthForType(LV.TypeHint, LV.TypeKind);
      if Width = 0 then begin
        Refuse(Format('cannot watch %s: its type (%s) has no 1/2/4/8-byte width a ' +
          'hardware watchpoint can express', [Expr, LV.TypeHint]));
        Exit;
      end;
      if (Addr mod UInt64(Width)) <> 0 then begin
        Refuse(Format('the address of %s ($%x) is not aligned to its %d-byte width',
          [Expr, Addr, Width]));
        Exit;
      end;

      Result.CanWatch          := True;
      Result.Kind              := dbsLocal;
      Result.Address           := Addr;
      Result.SizeBytes         := Width;
      Result.DisplayName       := Expr;
      Result.Frame.Scoped      := True;
      Result.Frame.ThreadId    := Tid;
      Result.Frame.FrameBase   := Frm.FrameRBP;
      Result.Frame.FuncEntryVA := Frm.FuncEntryVA;
      FillModule(Addr);
      var Where := Frm.FunctionName;
      if Where = '' then
        Where := Format('frame %d', [FrameIndex]);
      Result.Description := Format('%s: %s, %d bytes at $%x (local of %s on thread %d)',
        [Expr, LV.TypeHint, Width, Addr, Where, Tid]);
      if ViaRef then
        Result.Description := Result.Description + ' [var parameter: watching the ' +
          'storage it references]';
      Exit;
    end;

    var GV: TLocalValue;
    if FDebugger.EvaluateGlobalName(Expr, GV) and (GV.Address <> 0) then begin
      var GWidth := WatchWidthForType(GV.TypeHint, GV.TypeKind);
      if GWidth = 0 then begin
        Refuse(Format('cannot watch %s: its type (%s) has no 1/2/4/8-byte width a ' +
          'hardware watchpoint can express', [Expr, GV.TypeHint]));
        Exit;
      end;
      if (GV.Address mod UInt64(GWidth)) <> 0 then begin
        Refuse(Format('the address of %s ($%x) is not aligned to its %d-byte width',
          [Expr, GV.Address, GWidth]));
        Exit;
      end;
      Result.CanWatch    := True;
      Result.Kind        := dbsGlobal;
      Result.Address     := GV.Address;
      Result.SizeBytes   := GWidth;
      Result.DisplayName := Expr;
      FillModule(GV.Address);
      Result.Description := Format('%s: %s, %d bytes at $%x (global)',
        [Expr, GV.TypeHint, GWidth, GV.Address]);
      Exit;
    end;

    Refuse('unresolved symbol: ' + Expr);
  finally
    ClearFrame;
  end;
end;

procedure TDebugSession.RemoveAllBreakpoints;
begin
  // Post an empty spec per known source file FIRST so the engine clears the
  // planted INT3s. The old code cleared the lists before iterating them, so it
  // posted nothing and the breakpoints stayed planted in the target.
  if FDebugger <> nil then begin
    for var KV in FBpSpecs do begin
      var Cmd: TCommand;
      Cmd.Kind              := ckSetBreakpoints;
      Cmd.BpSpec            := Default(TBpSpec);
      Cmd.BpSpec.SourceFile := KV.Value.SourceFile;  // empty Lines => clear the file
      FDebugger.PostCommand(Cmd);
    end;
    // Address breakpoints: one empty-Rvas clear command per module that
    // currently owns one, same reasoning as the source-file loop above.
    var AddrModules := TDictionary<string, Byte>.Create;
    try
      for var Bp in FBreakpoints do
        if Bp.Kind = bkAddress then
          AddrModules.AddOrSetValue(Bp.ModuleName, 0);
      for var ModName in AddrModules.Keys do begin
        var Cmd: TCommand;
        Cmd.Kind                  := ckSetAddressBreakpoints;
        Cmd.AddrBpSpec            := Default(TAddrBpSpec);
        // Translate to the engine's own '' sentinel for the main exe -- see
        // EngineModuleNameFor.
        Cmd.AddrBpSpec.ModuleName := EngineModuleNameFor(ModName);  // empty Rvas => clears the module
        FDebugger.PostCommand(Cmd);
      end;
    finally
      AddrModules.Free;
    end;
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
    FRtti := TDelphiRtti.Create(FDebugger.ProcessHandle, FDebugger.TargetLayout);
  if FDebugger <> nil then begin
    FLoader.EnsureModuleForPC(FDebugger.GetRegisters.Pc);  // load DLL/BPL symbols at the stop
    FStopTid := FDebugger.GetStoppedThreadId;
  end;

  var EffFile: string;
  var EffLine: Integer;
  ResolveEffectiveStop(SourceFile, SourceLine, EffFile, EffLine);

  SetState(dsStopped);
  Inc(FStopGeneration);

  // A stop is the only moment a stack can be read, so it is the only moment a
  // frame-scoped watchpoint can be found stale. Do it BEFORE the stop is
  // reported: when the stale watchpoint is what caused this very stop, the
  // description must say the hit landed on reused stack.
  PruneStaleDataBreakpoints;

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
    if Reason = srDataBreakpoint then
      Info.DataBreakpointDescription := BuildDataBreakpointDescription;
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
    FRtti := TDelphiRtti.Create(FDebugger.ProcessHandle, FDebugger.TargetLayout);
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
      // A logpoint message is the USER's, not the debugger's: it goes where the
      // program's own output goes, not into the diagnostics channel. It stays
      // in FDebuggerOutput as well, because the MCP `get_debugger_output` tool
      // is documented as returning logpoint messages AND debugger notices.
      if Assigned(FOnOutput) then
        FOnOutput(okLogPoint, LogText);
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

function TDebugSession.ResolveModuleForAddress(Address: UInt64;
  out ModuleName: string; out ModuleBase: UInt64): Boolean;
begin
  ModuleName := '';
  ModuleBase := 0;
  for var M in GetModules do
    if (M.Base <> 0) and (M.Size > 0) and
       (Address >= M.Base) and (Address < M.Base + M.Size) then begin
      ModuleName := M.Name;
      ModuleBase := M.Base;
      Exit(True);
    end;
  Result := False;
end;

function TDebugSession.EngineModuleNameFor(const FriendlyModuleName: string): string;
begin
  Result := FriendlyModuleName;
  for var M in GetModules do
    if M.IsMain and SameText(M.Name, FriendlyModuleName) then
      Exit('');
end;

function TDebugSession.HaveAddressBreakpoints: Boolean;
begin
  for var Bp in FBreakpoints do
    if Bp.Kind = bkAddress then
      Exit(True);
  Result := False;
end;

// Re-derives Verified/Address/Message for every stored address breakpoint
// against the CURRENT module table, then reposts each affected module's
// whole address-breakpoint set to the engine. Called after a module loads
// (rebind: the module may now resolve, possibly at a different base than
// last time) and after one unloads (the engine has already unplanted --
// HandleUnloadDll removes any breakpoint whose VA falls in the unloaded
// range regardless of kind -- so this only needs to flip Verified off and
// leave the identity in place for a later reload).
procedure TDebugSession.RepostAddressBreakpoints(const ExtraModule: string = '');
begin
  if FDebugger = nil then
    Exit;
  var Modules := GetModules;
  var ByModule := TDictionary<string, TList<Integer>>.Create;
  try
    for var I := 0 to FBreakpoints.Count - 1 do begin
      if FBreakpoints[I].Kind <> bkAddress then
        Continue;
      var Key := FBreakpoints[I].ModuleName;
      if not ByModule.ContainsKey(Key) then
        ByModule.Add(Key, TList<Integer>.Create);
      ByModule[Key].Add(I);
    end;
    // A module whose LAST address breakpoint was just removed no longer has
    // any FBreakpoints entry to derive it from; seed it explicitly so the
    // clear command below still reaches the engine.
    if (ExtraModule <> '') and not ByModule.ContainsKey(ExtraModule) then
      ByModule.Add(ExtraModule, TList<Integer>.Create);

    for var KV in ByModule do begin
      var ModBase: UInt64 := 0;
      var Loaded := False;
      for var M in Modules do
        if SameText(M.Name, KV.Key) and (M.Base <> 0) then begin
          ModBase := M.Base;
          Loaded  := True;
          Break;
        end;

      for var Idx in KV.Value do begin
        var Bp := FBreakpoints[Idx];
        Bp.Verified := Loaded;
        if Loaded then begin
          Bp.Address := ModBase + Bp.Rva;
          Bp.Message := '';
        end else
          Bp.Message := Format('Module "%s" is not currently loaded.', [Bp.ModuleName]);
        FBreakpoints[Idx] := Bp;
      end;

      var Spec: TAddrBpSpec;
      // The engine's own sentinel for "the main exe" is '' (matching FDllBases,
      // which never holds an entry for it) -- translate the friendly name
      // (what FBreakpoints/reporting use) at this one boundary.
      Spec.ModuleName := EngineModuleNameFor(KV.Key);
      SetLength(Spec.Rvas,          KV.Value.Count);
      SetLength(Spec.Conditions,    KV.Value.Count);
      SetLength(Spec.HitConditions, KV.Value.Count);
      SetLength(Spec.LogMessages,   KV.Value.Count);
      for var J := 0 to KV.Value.Count - 1 do begin
        var Bp := FBreakpoints[KV.Value[J]];
        Spec.Rvas[J]          := Bp.Rva;
        Spec.Conditions[J]    := Bp.Condition;
        Spec.HitConditions[J] := Bp.HitCondition;
        Spec.LogMessages[J]   := Bp.LogMessage;
      end;
      var Cmd: TCommand;
      Cmd.Kind       := ckSetAddressBreakpoints;
      Cmd.AddrBpSpec := Spec;
      FDebugger.PostCommand(Cmd);
    end;
  finally
    for var L in ByModule.Values do
      L.Free;
    ByModule.Free;
  end;
end;

function TDebugSession.SetAddressBreakpoint(Address: UInt64;
  const Condition, HitCondition, LogMessage: string): TSessionBreakpoint;
begin
  Result := Default(TSessionBreakpoint);
  Result.Kind         := bkAddress;
  Result.Address      := Address;
  Result.Condition    := Condition;
  Result.HitCondition := HitCondition;
  Result.LogMessage   := LogMessage;

  if FDebugger = nil then begin
    Result.Message := 'No active debug session -- launch or attach before setting an address breakpoint.';
    Exit;
  end;

  var ModuleName: string;
  var ModuleBase: UInt64;
  if not ResolveModuleForAddress(Address, ModuleName, ModuleBase) then begin
    Result.Message := Format(
      '0x%x is not inside any currently loaded module -- an address ' +
      'breakpoint cannot be attributed until the owning module is loaded.',
      [Address]);
    Exit;
  end;

  Result.ModuleName := ModuleName;
  Result.Rva         := Address - ModuleBase;
  Result.Id          := 'addr:' + ModuleName + ':' + IntToHex(Result.Rva, 1);
  Result.Verified    := True;

  // Idempotent: replace any prior entry with the SAME (module, rva) identity.
  for var I := FBreakpoints.Count - 1 downto 0 do
    if (FBreakpoints[I].Kind = bkAddress) and (FBreakpoints[I].Id = Result.Id) then
      FBreakpoints.Delete(I);
  FBreakpoints.Add(Result);

  RepostAddressBreakpoints;
end;

function TDebugSession.RemoveAddressBreakpoint(const Id: string): Boolean;
begin
  Result := False;
  var ModuleName := '';
  for var I := FBreakpoints.Count - 1 downto 0 do
    if (FBreakpoints[I].Kind = bkAddress) and (FBreakpoints[I].Id = Id) then begin
      ModuleName := FBreakpoints[I].ModuleName;
      FBreakpoints.Delete(I);
      Result := True;
      Break;   // ids are unique
    end;
  if Result then
    RepostAddressBreakpoints(ModuleName);
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

  // Address breakpoints need no symbols to rebind -- only the module's live
  // base, which is already known at this point (RegisterModuleRecord just
  // set it). Re-derive Verified/Address and replant against it, exactly like
  // the source-breakpoint gate above and for the same reason: this runs
  // BEFORE the debuggee is resumed, and the module's own init code can run
  // past an address the instant this event is continued.
  if HaveAddressBreakpoints then
    RepostAddressBreakpoints;

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
  // The engine has already unplanted any breakpoint (of either kind) whose VA
  // fell in this module's range (TWinDebugger.HandleUnloadDll, VA-range based,
  // kind-agnostic). An address breakpoint's IDENTITY survives regardless --
  // (ModuleName, Rva) still names the same intended instruction -- so this
  // only needs to flip Verified off; a later HandleDllLoaded for the same
  // module name rebinds and replants at whatever base it reloads at.
  if HaveAddressBreakpoints then
    RepostAddressBreakpoints;
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
  Result.Origin       := F.Origin;
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

// The formats a runtime module actually registered, read off the provider
// references themselves. A `*Tried` flag would say only that a format was
// looked for.
function FormatsOf(M: TModuleSymbols): TArray<string>;
begin
  Result := [];
  if M.Td32Iface <> nil then Result := Result + ['td32'];
  if M.TdsIface  <> nil then Result := Result + ['tds'];
  if M.MapIface  <> nil then Result := Result + ['map'];
  if M.RsmIface  <> nil then Result := Result + ['rsm'];
  if M.DcpIface  <> nil then Result := Result + ['dcp'];
  if M.JclIface  <> nil then Result := Result + ['jdbg'];
end;

function TDebugSession.GetModules: TArray<TSessionModule>;
begin
  Result := nil;
  if (FDebugger = nil) or (FLoader = nil) then
    Exit;

  var Main := Default(TSessionModule);
  Main.IsMain  := True;
  Main.Path    := FExePath;
  Main.Name    := LowerCase(ExtractFileName(FExePath));
  Main.Base    := FDebugger.ImageBase;
  Main.Size    := FLoader.MainImageSize;
  Main.Symbols := FLoader.MainSymbolAvailability;
  Main.Formats := FLoader.MainSymbolFormats;
  Result := [Main];

  for var M in FLoader.Modules do begin
    var Rec := Default(TSessionModule);
    Rec.Name    := M.Name;
    Rec.Path    := M.FullPath;
    Rec.Base    := M.Base;
    Rec.Size    := M.ImageSize;
    Rec.Symbols := M.SymbolAvailability;
    Rec.Formats := FormatsOf(M);
    Result := Result + [Rec];
  end;
end;

// Every source file the loaded debug info can name, grouped by owning module.
//
// Like GetModules, deliberately NOT gated on being stopped: which files are
// covered is a property of what has been loaded, and the question is most
// useful before running -- it is how a caller learns the file spelling that
// set_breakpoint expects instead of guessing at it.
//
// Only formats that already loaded are asked. A module whose sidecars have not
// been probed yet reports what it has so far rather than triggering a parse:
// enumerating sources must not be the thing that stalls a session for seconds.
function TDebugSession.GetModuleSources: TArray<TSessionModuleSources>;
begin
  Result := nil;
  if (FDebugger = nil) or (FLoader = nil) then
    Exit;

  var Main := Default(TSessionModuleSources);
  Main.Module  := LowerCase(ExtractFileName(FExePath));
  Main.IsMain  := True;
  Main.Formats := FLoader.MainSymbolFormats;
  Main.Files   := FLoader.MainSourceFileList(Main.ListedBy, Main.Complete);
  Result := [Main];

  for var M in FLoader.Modules do begin
    var Rec := Default(TSessionModuleSources);
    Rec.Module  := M.Name;
    Rec.Formats := FormatsOf(M);
    Rec.Files   := M.SourceFileList(Rec.ListedBy, Rec.Complete);
    Result := Result + [Rec];
  end;
end;

// Opt-in raw sweep of the stopped thread's stack. Never called by GetCallStack
// and never merged into it: a raw hit says a return address to that routine is
// PRESENT on the stack, not that the routine is on the current chain. The
// distinction is carried per frame in Origin (foRawProven / foRawUnproven) so a
// frontend cannot lose it by accident.
//
// Modules are warmed the same way the walk warms them, or every frame in a
// runtime package would come back nameless -- which for this feature is the
// whole answer, since its point is naming the user's own code underneath
// foreign frames.
function TDebugSession.GetRawStackScan(ThreadId: Cardinal;
  MaxItems: Integer): TArray<TSessionFrame>;
begin
  var Guard := InteractiveWait;
  Result := nil;
  if (FState <> dsStopped) or (FDebugger = nil) then
    Exit;
  var Tid := ThreadId;
  if Tid = 0 then
    Tid := FStopTid;
  var Frames := FDebugger.GetRawStackFrames(Tid, MaxItems);
  var NeedRefresh := False;
  for var F in Frames do
    if (F.SourceFile = '') or (F.FunctionName = '') then begin
      FLoader.EnsureModuleForPC(F.IP);
      NeedRefresh := True;
    end;
  // Re-resolve, do NOT sweep again: the sweep reads the whole stack and a
  // second pass over several megabytes to pick up names just loaded would
  // double the cost of the feature for nothing.
  if NeedRefresh then
    Frames := FDebugger.ResymbolicateFrames(Frames);
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
  // 16, not 8: a Win32 `Extended` is 10 bytes wide.
  Buf:  array[0..15] of Byte;
  Size: Integer;
begin
  Result := False;
  ErrMsg := '';
  // Enum targets first (literal name, then numeric ordinal at the enum's TRUE
  // width), then the float types whose target width the generic encoder gets
  // wrong. EncodeValueForType writes 8 bytes for anything it calls a float and
  // for its unknown-type fallback, which would clobber what follows a 1/2-byte
  // enum/set slot and would half-write a 10-byte Extended.
  if TryEncodeEnumByName(FDebugInfo, ValueStr, TypeHint, Buf, Size) or
     TryEncodeEnumOrdinal(FDebugInfo, ValueStr, TypeHint, Buf, Size) or
     TryEncodeWideFloat(ValueStr, TypeHint,
       FDebugger.TargetLayout.PointerSize, Buf, Size) or
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
  // Build a refreshed display from a fresh read at the field address, at the
  // FIELD's own width. Eight bytes folds the neighbouring field into the high
  // half on a 32-bit target, which for a pointer-shaped field (a string, an
  // object) yields an address outside the process and a read failure where the
  // write in fact succeeded.
  var FreshRaw: UInt64 := 0;
  if FDebugger.ReadProcessMemoryAt(FieldAddr, @FreshRaw,
       LocalReadSize(FieldType, FDebugger.TargetLayout.PointerSize)) then begin
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

  // A RECORD has no scalar value, so the generic formatter rendered its first
  // bytes as a number: a `packed record A: Byte; B: Integer; C: Word` holding
  // 1/2/3 was listed as 513 -- which is $0201, the first two fields read as an
  // integer -- and a TPoint2D as 0. The watch path already presents a record as
  // `$addr (TypeName)` and expands its fields; the locals list did not, so the
  // same variable read differently depending on where you looked at it.
  // Records only: a set renders as [Red, Blue], a dynamic array as [10, 20, 30]
  // and a string as its text, all of which are already right.
  if (LV.Address <> 0) and (LV.TypeHint <> '') and (FDebugInfo <> nil) and
     (FDebugInfo.LookupTypeKind(LV.TypeHint) in [TK_RECORD, TK_MRECORD]) then
    Result.Value := Format('$%x (%s)', [LV.Address, LV.TypeHint]);
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

// True for a bare identifier -- no dots, indexing, calls or operators. Keeps the
// closure-capture fallback to names a captured variable could actually have,
// rather than retrying it for every failed expression.
function TDebugSession.IsPlainIdentifier(const S: string): Boolean;
begin
  Result := False;
  if S = '' then
    Exit;
  if not CharInSet(S[1], ['A'..'Z', 'a'..'z', '_']) then
    Exit;
  for var I := 2 to Length(S) do
    if not CharInSet(S[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit;
  Result := True;
end;

function TDebugSession.IsAnonBodyFunc(const Fn: string): Boolean;
begin
  // Compiler-generated closure body, e.g. `RunClosureSampler$ActRec.$0$Body`.
  Result := Fn.Contains('$ActRec') and Fn.Contains('$Body');
end;

function TDebugSession.TryFindClosureSelf(out SelfAddr: UInt64;
  out ClassName: string): Boolean;

  // Last dot-separated segment, so a qualified runtime class name and an
  // unqualified one compare equal.
  function Unqualified(const S: string): string;
  begin
    Result := S;
    var Dot := Result.LastIndexOf('.');
    if Dot >= 0 then
      Result := Result.Substring(Dot + 1);
  end;

  // The $ActRec class THIS frame belongs to, taken from its own function name:
  // `Unit.RunClosureSampler$ActRec.$0$Body` -> `RunClosureSampler$ActRec`.
  function ExpectedActRecClass: string;
  begin
    Result := '';
    var Fn, Src: string;
    var Ln: Integer;
    if not GetCurrentLocation(Fn, Src, Ln) then
      Exit;
    var Dot := Fn.LastIndexOf('.');       // drop `.$0$Body`
    if Dot < 0 then
      Exit;
    Result := Unqualified(Fn.Substring(0, Dot));
    if not Result.Contains('$ActRec') then
      Result := '';
  end;

var
  WantClass: string;

  function Consider(P: UInt64; RequireExactClass: Boolean): Boolean;
  begin
    Result := False;
    if (P < 65536) or (FRtti = nil) or not FRtti.IsClassInstance(P) then Exit;
    var Cn := FRtti.GetInstanceClassName(P);
    if (Cn = '') or not Cn.Contains('$ActRec') then Exit;
    // Accepting ANY activation record found by the scan is how a STALE pointer
    // left by an earlier closure gets picked up -- and on a 32-bit target the
    // scan is the only path, because there is no parameter home slot to read
    // Self from. That made the captured set depend on leftover register and
    // stack contents: the same test listed CapStr but not CapInt on some runs
    // and both on others. The frame's own name says which activation record it
    // belongs to, so demand that one.
    if RequireExactClass and (WantClass <> '') and
       not SameText(Unqualified(Cn), WantClass) then
      Exit;
    var Members: TArray<TClassMember>;
    if (FDebugInfo = nil) or not FDebugInfo.GetClassMembers(Cn, Members) or
       (Length(Members) = 0) then Exit;
    SelfAddr := P; ClassName := Cn; Result := True;
  end;

  // Registers first, then a bounded stack window around the frame and stack
  // pointers. Stack slots are the TARGET's pointer size, not the debugger's:
  // an 8-byte stride over a 32-bit stack visits every other slot and covers
  // twice the intended window.
  function ScanFor(RequireExactClass: Boolean): Boolean;
  begin
    Result := False;
    var Layout := FDebugger.TargetLayout;
    var Regs := FDebugger.GetRegisters;
    for var R in [Regs.Rcx, Regs.Rdx, Regs.R8, Regs.R9, Regs.Rbx,
                  Regs.Rsi, Regs.Rdi, Regs.R12, Regs.R13, Regs.R14, Regs.R15] do
      if Consider(R, RequireExactClass) then Exit(True);
    for var Anchor in [Regs.FramePtr, Regs.StackPtr] do begin
      if Anchor = 0 then Continue;
      for var K := -16 to 32 do begin
        var Slot: UInt64 := 0;
        {$Q-}{$R-}
        var SlotAddr := Anchor + UInt64(Int64(K) * Layout.PointerSize);
        {$Q+}{$R+}
        if FDebugger.ReadProcessMemoryAt(SlotAddr, @Slot, Layout.PointerSize) and
           Consider(Slot, RequireExactClass) then
          Exit(True);
      end;
    end;
  end;

begin
  Result := False;
  SelfAddr := 0; ClassName := '';
  if FDebugger = nil then Exit;
  // Self is ABI parameter 0 (RCX) of the anon body method, spilled to its Win64
  // home slot. Read it DIRECTLY -- exact, and (unlike a blind register/stack scan)
  // it cannot pick up a STALE `$ActRec` pointer left on the stack by an unrelated
  // closure that ran earlier, which would resolve the wrong class + methods.
  WantClass := ExpectedActRecClass;
  var Layout := FDebugger.TargetLayout;
  var SelfHome := FDebugger.CurrentFrameParamHomeAddr(0);
  if SelfHome <> 0 then begin
    var SelfPtr: UInt64 := 0;
    if FDebugger.ReadProcessMemoryAt(SelfHome, @SelfPtr, Layout.PointerSize) and
       Consider(SelfPtr, True) then
      Exit(True);
  end;
  // Fallback (home slot unreadable / prologue not recognised / no home-slot
  // formula at all, which is the case on x86). Two passes: first demanding the
  // activation record this frame actually belongs to, then -- only if that
  // finds nothing, e.g. because the runtime class name is spelled differently
  // from the symbol -- accepting any, which is the pre-existing behaviour.
  if ScanFor(True) then
    Exit(True);
  Result := ScanFor(False);
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
  if not TryFindClosureSelf(SelfAddr, CloClass) then begin
    // We KNOW this frame is an anonymous-method body, so it has captured
    // variables whether or not we can reach them. Resolving them needs the
    // $ActRec class members from the symbol index, and every interactive read
    // waits only a bounded time for that index -- so on a cold one the captures
    // silently vanish and the variables view looks like the closure captured
    // nothing. Say so instead: an empty list is indistinguishable from a
    // truthful answer, and this one is not truthful.
    var Pending := Default(TSessionVariable);
    Pending.Name         := '<captured>';
    Pending.Value        := '<symbols not ready -- refresh to retry>';
    Pending.EvaluateName := '';
    Locals := Locals + [Pending];
    Exit;
  end;
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
      // Read the field at its OWN width. Eight bytes unconditionally folds the
      // NEXT field into the high half on a 32-bit target: a captured `string`
      // came back as $2A030181CC -- a ten-digit address in a four-byte process --
      // and rendered as a read failure. An Integer survived it only because the
      // formatter masks the high half away.
      LV.ValueValid := FDebugger.ReadProcessMemoryAt(LV.Address, @LV.RawValue,
        LocalReadSize(LV.TypeHint, FDebugger.TargetLayout.PointerSize));
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
    // Same rule as the captured fields above: the parameter's own width, not 8.
    LV.ValueValid := FDebugger.ReadProcessMemoryAt(Addr, @LV.RawValue,
      LocalReadSize(LV.TypeHint, FDebugger.TargetLayout.PointerSize));
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
begin
  // Delegated rather than duplicated. This used to be a byte-identical copy of
  // the expander's, and the two drifted: the expander's learned to carry
  // ValueKind -- the only thing that tells a flattened dynamic array from a
  // genuine typed pointer, both spelled `^T` -- while this one kept dropping
  // it, so expanding `MRec.Tags` rendered `[4, 5, 6]` and evaluating the same
  // field rendered a bare address.
  Result := FExpander.FormatExprValue(E);
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
  FrameIndex: Integer; ThreadId: Cardinal = 0;
  AllowCalls: Boolean = True): TSessionEvalResult;
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
  // Selecting a frame indexes the cache the last GetCallStack filled, and an
  // index into an EMPTY cache is silently unselectable -- evaluation then falls
  // back to the stopped top frame and answers with the WRONG frame's locals
  // rather than saying anything. A caller that asks for frame N without having
  // fetched the stack (an MCP evaluate, a watch issued before the stack panel
  // is opened) hit exactly that. Fill the cache first, through GetCallStack, so
  // the indexing matches what a client would have seen.
  if (Length(FLastFrames) = 0) and (FStoppedOnException or (FrameIndex > 0)) then
    GetCallStack;
  SelectFrame(FrameIndex, ThreadId);
  try
    var Val: TExprValue := Default(TExprValue);
    var Display: string;
    var Eval := TExprEvaluator.Create(FDebugger, FRtti, FDebugInfo, AllowCalls);
    try
      if Eval.Evaluate(Expr, Val) then
        Display := FormatExprValue(Val)
      else
        Display := Val.TypeHint;  // error message like '<X: not found>'
    finally
      Eval.Free;
    end;

    // A variable CAPTURED by an anonymous method is listed among the locals but
    // was not resolvable by name: inside a closure body the captured variables
    // are fields of the hidden $ActRec Self object, and only this layer knows
    // that -- the evaluator sees an empty stack-local set and answers
    // `<CapStr: not found>` for a name the variables view is displaying right
    // next to it. Look it up the same way the locals list builds it.
    if not Val.IsValid and IsPlainIdentifier(Expr) then begin
      var Captured: TArray<TSessionVariable>;
      AppendClosureCapturedLocals(Captured);
      for var C in Captured do
        if SameText(C.Name, Expr) then begin
          Result.Success    := True;
          Result.IsValid    := True;
          Result.Value      := C.Value;
          Result.TypeName   := C.TypeName;
          Result.Handle     := C.Handle;
          Result.Expandable := C.Expandable;
          Exit;
        end;
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
      // The extra dereference reads a POINTER, so read one pointer. At eight
      // bytes the high half is the neighbouring word on a 32-bit target, which
      // makes the probe fail there every time -- so this recovery has simply
      // never worked on x86.
      Probe := 0;
      if (not IsInst) and FDebugger.ReadProcessMemoryAt(Val.RawValue, @Probe,
             FDebugger.TargetLayout.PointerSize) and
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
    // A Variant is a LEAF: FormatLocalValue has already decoded the TVarData
    // into `varInteger: 142`, and overwriting that with the address form throws
    // the value away. It gets here because the underlying TVarData IS a struct,
    // so whether the decoration fires depends on what the binary's type table
    // happens to expose -- on Win32 `Variant` reported members and every
    // Variant-returning call rendered as `$1060000 (Variant)`, while the same
    // expression on Win64 rendered correctly. Same test the reader dispatches
    // on, so the two cannot disagree about what counts as a Variant.
    // The VarArray expansion below still runs: it only mints a handle.
    var RendersAsVariant :=
      SameText(Val.TypeHint, 'Variant') or SameText(Val.TypeHint, 'OleVariant') or
      SameText(Val.TypeHint, 'TVarData') or (Kind = TK_VARIANT);
    if Val.IsValid and (Val.TypeHint <> '') and (not RendersAsVariant) and
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
        // Which class to NAME. The locals reader labels an object with the class
        // its VMT says it IS (FormatTyped prefers the runtime name over the
        // declared one), and this path labelled it with the DECLARED type, so
        // the same object read differently depending on which pane asked.
        // Measured on Hydra2: `AOwner`, declared TComponent and holding the
        // TApplication, was `(TApplication)` in locals and `(TComponent)` from
        // evaluate.
        //
        // Only the LABEL changes. Result.TypeName keeps the declared type and
        // the expansion is still minted from it, so member resolution cannot
        // start depending on whether a runtime class happens to be covered by
        // the loaded debug info.
        var DisplayType := Val.TypeHint;
        if IsClassInst then begin
          var RuntimeClass := FRtti.GetInstanceClassName(Val.RawValue);
          if RuntimeClass <> '' then
            DisplayType := RuntimeClass;
        end;
        if (Kind = TK_CLASS) and (Val.RawValue = 0) then
          Display := Format('nil (%s)', [DisplayType])
        else
          Display := Format('$%x (%s)', [DisplayAddr, DisplayType]);
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
  if FStopReason = srDataBreakpoint then
    Result.DataBreakpointDescription := BuildDataBreakpointDescription;
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
