unit ModuleSymbolLoader;

// Shared symbol/module loader used by every frontend (the neutral TDebugSession
// core and the DAP TDapServer). It owns the runtime-module registry, every
// per-module symbol-load primitive that both frontends previously duplicated as
// two divergent copies, and the background symbol PREFETCHER.
//
// Threading -- read this before touching anything here:
//
//   * Every public primitive (Ensure*, LoadModuleSymbols, EnqueuePrefetch,
//     DrainPrefetch, registry mutation) MUST be called on the
//     caller's debug-loop / dispatch thread. The injected TDebugInfoSet has no
//     lock at all (AddProvider fans a provider out across ~15 lists and then
//     bumps a revision counter), so provider registration is single-threaded by
//     construction and stays that way.
//
//   * The prefetcher adds exactly ONE worker thread. It never touches a
//     TModuleSymbols, the registry, the TDebugInfoSet or any already-registered
//     reader. It receives a VALUE SNAPSHOT (TPrefetchRequest), builds brand-new
//     reader objects that nothing else can see, and hands the finished objects
//     back through a queue that the dispatch thread drains (DrainPrefetch, called
//     from TDebugSession.Pump). Single writer, publish once.
//
//   * A module is CLAIMED before the worker starts: EnqueuePrefetch sets
//     TModuleSymbols.PrefetchInFlight on the dispatch thread, and PublishPrefetch
//     clears it on the same thread. Both ends of the claim therefore run on one
//     thread and the flag needs no lock. While it is set, no dispatch-thread
//     Ensure* may parse that module -- it either takes the request back off the
//     queue (TryRevoke) and parses it in-line, or DECLINES and lets the result
//     register on a later pump turn. This is the single-load-path rule; without
//     it the dispatch thread and the worker parse the same file at the same
//     time, which is precisely why the previous DAP-side background loader had
//     to be disabled.
//
//   * It NEVER WAITS for the worker. Waiting on symbol state from the dispatch
//     thread is the F14 hazard, and a bounded 750 ms wait here was measured to
//     reproduce the same intermittent request timeout that disabled the previous
//     loader. See PrefetchBlocks.
//
//   * A dispatch-thread Ensure* that declines because of a claim returns WITHOUT
//     setting the module's *Tried flag. A nameless frame must stay retryable;
//     marking it tried would turn a transient gap into a permanent one.
//
// Ownership: the injected deps (Debugger / DebugInfo) are NOT owned. The main-
// module readers created here are kept alive by the interface refs FDebugInfo
// holds (they are TInterfacedObject); the loader never frees them (freeing the
// raw object would be a double-free). The module registry IS owned and freed
// here, removing each module's providers from FDebugInfo first.
//
// Load-order invariants (a violation reintroduces the 30-70s freeze or mis-types
// symbols -- see DAP_DEBUGGER_ARCHITECTURE.md):
//   * Provider registration order per module: RSM before TD32 before MAP before
//     DCP. The main-module TD32 is the PRIMARY (front-inserted for member/local/
//     enum lookups); everything else is appended. First-match-wins is load-bearing.
//   * RVA shift = Base - exeImageBase computed under {$Q-} (overflow off).
//   * The DLL MAP is added UNSCOPED (global-ish publics); RSM/TD32/DCP are
//     RVA-range-scoped via AddProviderForModule.
//   * The per-module *Tried negative-cache flags gate probe-once. A module whose
//     flag is set is never re-parsed (unless the injected ShouldRetryModule hook
//     says otherwise, e.g. a launch-configured module in the DAP). This is the
//     sole guard against per-stop re-parse freezes.
//   * SymbolFileIsStale (2s grace) gates every sidecar load; no behaviour change.

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  DebugTarget, DebugInfoSet, DebugInfoTypes,
  MapFileReader, RsmFileReader, TD32FileReader, JclDebugReader;

type
  // Everything the prefetch worker needs, by VALUE. Deliberately not a reference
  // to TModuleSymbols: the module may be unloaded (and its record freed) while
  // the worker is parsing, and the worker must never dereference registry state.
  TPrefetchRequest = record
    Name, FullPath: string;
    MapPath, RsmPath, DcpPath, TdsPath: string;
    Base, ImageSize, PreferredBase, ImageBase: UInt64;
    RsmDisabled: Boolean;
  end;

  // Finished, UNREGISTERED readers produced by the worker, plus the diagnostics
  // it would have logged. Logs are buffered rather than emitted because the
  // frontend log/console sinks are dispatch-thread objects.
  TPrefetchOutcome = record
    Req:  TPrefetchRequest;
    Rsm:  TRsmFile;
    Td32: TTD32FileReader;
    Tds:  TTD32FileReader;
    Map:  TMapFile;
    Dcp:  TRsmFile;
    Jcl:  IInterface;
    PreferredBase: UInt64;
    DcpPathUsed:   string;
    Logs: TArray<string>;
    procedure FreeUnregistered;
  end;

  // One worker thread + two locked queues. Owns no debugger state whatsoever.
  TSymbolPrefetcher = class
  private
    FThread:  TThread;
    FStop:    Integer;
    FLock:    TCriticalSection;   // guards FPending and FDone
    FWake:    TEvent;
    FPending: TList<TPrefetchRequest>;
    FDone:    TList<TPrefetchOutcome>;
    procedure Execute;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Start;
    // Dispatch thread. HighPriority jumps the queue (a module the debugger is
    // about to need: it owns a breakpoint, or a frame just landed in it).
    procedure Push(const Req: TPrefetchRequest; HighPriority: Boolean);
    // Dispatch thread. Takes a still-QUEUED request back off the worker so the
    // caller can parse it in-line. False when the worker has already popped it
    // (or it was never queued) -- pop and revoke share one lock, so there is no
    // window in which both threads believe they own the module.
    function  TryRevoke(const AName: string; ABase: UInt64): Boolean;
    // Dispatch thread. False when nothing is ready.
    function  Pop(out Outcome: TPrefetchOutcome): Boolean;
    function  Running: Boolean;
    // Stops the worker, joins it, and frees every outcome nobody collected.
    procedure Shutdown;
  end;
  // A runtime-loaded module (DLL / BPL) and its lazily-loaded symbol providers.
  // Interface refs keep the readers alive; FDebugInfo owns them via its provider
  // lists. The *Tried flags are a negative cache so a module with no sidecar is
  // probed once, not on every stop. Frontends may subclass this (the DAP attaches
  // its PACKAGEINFO / source-index enrichment) and set TModuleSymbolLoader.
  // ModuleClass so the registry instantiates the subclass.
  TModuleSymbols = class
  public
    Name:          string;    // lowercase file name (e.g. 'testsubject.bpl')
    FullPath:      string;
    Base:          UInt64;    // actual load base
    ImageSize:     UInt64;
    PreferredBase: UInt64;
    MapPath, RsmPath, DcpPath, TdsPath: string;
    MapIface, RsmIface, Td32Iface, DcpIface, JclIface, TdsIface: IInterface;
    MapTried, RsmTried, Td32Tried, DcpTried, JclTried, TdsTried: Boolean;
    // Set once the "no debug info in any format" diagnostic has been emitted for
    // this module, so a per-stop LoadModuleSymbols sweep does not repeat it.
    NoSymbolsReported: Boolean;
    // The prefetch CLAIM. Set by EnqueuePrefetch and cleared by PublishPrefetch,
    // both on the dispatch thread, so it needs no lock. While it is True the
    // worker owns this module's parse and no Ensure* may start one.
    PrefetchInFlight:  Boolean;
    // True once a prefetch for this module has been enqueued, so a per-stop sweep
    // does not enqueue it again after it has already been published.
    PrefetchRequested: Boolean;
    constructor Create; virtual;
    function ContainsPC(PC: UInt64): Boolean;
    // True when at least one symbol provider (embedded TD32 / .map / .rsm / .dcp
    // / .jdbg) is loaded for this module.
    function HasAnySymbols: Boolean;
    // True while at least one symbol format has never been probed for this
    // module, i.e. a LoadModuleSymbols call would still do real parsing work.
    // Every Ensure* sets its *Tried flag before attempting anything, so once all
    // six are set the sweep is a no-op and reporting "loading symbols" would lie.
    function HasUnprobedSymbolFormats: Boolean;
    // Human-facing module name for progress/status text: the file name without
    // its extension, preserving the on-disk casing (Name is lowercased).
    function DisplayName: string;
    // Why this module can (or cannot) name an address in it. Never returns
    // saUnknownModule -- the record's existence already proves the module known.
    function SymbolAvailability: TSymbolAvailability;
    // Does this module own the given source file? Used to gate eager symbol
    // loading so an unrelated sidecar-bearing module is not parsed just because a
    // breakpoint exists elsewhere. The base answer is CONSERVATIVE (True: assume it
    // might, so a breakpoint is never missed); a frontend subclass (DAP's
    // TDllModule) overrides with a cheap authoritative check (PACKAGEINFO for BPLs,
    // MAP source index otherwise) so a many-module host does not repost-storm.
    function ContainsSourceFile(const FileName: string): Boolean; virtual;
  end;
  TModuleSymbolsClass = class of TModuleSymbols;

  // Frontend hooks (all optional / owner-set).
  TModuleLoaderLog        = procedure(const Msg: string) of object;
  TModuleSymbolsEvent     = procedure(Module: TModuleSymbols) of object;
  TModuleRetryPredicate   = function(const AName: string): Boolean of object;
  TModuleRequiresSupplier = function(Module: TModuleSymbols): TArray<string> of object;

// Master switch for the background symbol prefetcher.
//
// DEFAULT: OFF. The prefetcher below is complete and its concurrency design
// has been reviewed and documented, but with it enabled the full test suite
// reproducibly loses ONE-to-THREE requests per run to a 30 s response timeout,
// always in the BPL fixture (TDebuggerTestsBpl), always on the first request
// after a stop, and never in isolation. That is the same signature that got
// the previous background loader disabled and it is NOT yet explained --
// proven to be the prefetcher rather than the rest of this change set by
// running the identical build with the prefetcher off (clean, 0 errored).
//
// Everything else in this change set (the reader-level concurrency fixes, the
// single-load-path claim protocol, the publication plumbing) is live and
// green. Set SYMBOL_PREFETCH=1, or call SetSymbolPrefetchEnabled(True), to
// turn the prefetcher on for further investigation.
procedure SetSymbolPrefetchEnabled(Value: Boolean);
function  SymbolPrefetchEnabled: Boolean;

type
  TModuleSymbolLoader = class
  private
    // Injected, not owned.
    FDebugger:   IDebugTarget;
    FDebugInfo:  TDebugInfoSet;
    FRsmDisabled: Boolean;

    // Main-module state (paths retained so the latched EnsureMainRsm can be
    // called lazily long after LoadMainModule).
    FExePath, FMapPath, FRsmPath: string;
    // Main-module readers: created here, kept alive by FDebugInfo provider refs,
    // NEVER freed here (ARC via the interfaces -- see the unit header).
    FMainMap:       TMapFile;
    FMainTD32:      TTD32FileReader;
    // External `.tds` reader (dcc64 -VT) used ONLY when the exe has no embedded
    // `.debug` (a -VT-only build). Same CodeView format as FMainTD32; MainTD32
    // falls back to it so the frontend's variable expander still binds.
    FMainTds:       TTD32FileReader;
    FMainRsm:       TRsmFile;
    FMainRsmLoaded: Boolean;
    // JCL provider (linked 'JCLDEBUG' section or '.jdbg' sidecar). Kept alive by
    // FDebugInfo's provider ref; never freed here (ARC). Latched load like RSM.
    FMainJcl:       IInterface;
    FMainJclLoaded: Boolean;
    // Count of main-module providers actually registered (TD32 / RSM / MAP / JCL),
    // so LoadMainModule can warn when the exe has NO usable debug info at all.
    FMainProviderCount: Integer;
    // Format names of the main-module providers that were actually registered,
    // in registration order (see AddMainProvider).
    FMainFormats:       TArray<string>;
    // Main-module extent, so an address in the exe can be attributed to it. The
    // exe is deliberately NOT in the runtime registry (it must never be probed
    // for DLL sidecars), so it needs its own range check.
    FMainImageSize:     UInt64;
    // True once FMainMap is a registered provider; only then may it be asked
    // whether its publics index is still building.
    FMainMapRegistered: Boolean;

    // Owned registry.
    FModules:     TObjectList<TModuleSymbols>;
    FModuleClass: TModuleSymbolsClass;

    // Frontend hooks.
    FOnSymbolsLoaded:   TModuleSymbolsEvent;
    FShouldRetryModule: TModuleRetryPredicate;
    FRequiresFor:       TModuleRequiresSupplier;
    FOnLog:             TModuleLoaderLog;   // diagnostic sink (DAP: DapLog)
    FOnConsole:         TModuleLoaderLog;   // user-facing sink (DAP: SendConsoleLog)
    FOnModuleLoadBegin: TModuleLoaderLog;   // progress sink, gets the display name

    // Background prefetcher (created lazily on the first enqueue).
    FPrefetch: TSymbolPrefetcher;

    procedure Log(const Msg: string);
    procedure Console(const Msg: string);
    function  PublishPrefetch(const Outcome: TPrefetchOutcome): Boolean;
    function  SnapshotForPrefetch(Module: TModuleSymbols;
                out Req: TPrefetchRequest): Boolean;
    function  PrefetchBlocks(Module: TModuleSymbols): Boolean;
    function  ShouldRetry(const AName: string): Boolean;
    function  RequiresOf(Module: TModuleSymbols): TArray<string>;
    procedure AddMainProvider(const Provider: IInterface; const Format: string;
                Primary: Boolean = False);
    function  GetMainTD32: TTD32FileReader;
    function  MainModuleContainsPC(PC: UInt64): Boolean;
  public
    // Symbol state of the MAIN image, and which formats actually supplied it.
    // Public because a frontend listing modules has to describe the exe on the
    // same terms as every DLL/BPL; without it the main module would be the one
    // entry with no answer.
    function  MainSymbolAvailability: TSymbolAvailability;
    function  MainSymbolFormats: TArray<string>;
    property  MainImageSize: UInt64 read FMainImageSize;
    constructor Create;
    destructor  Destroy; override;

    // Injected deps + hooks (owner-set before first use).
    property Debugger:      IDebugTarget  read FDebugger   write FDebugger;
    property DebugInfo:     TDebugInfoSet read FDebugInfo  write FDebugInfo;
    property IsRsmDisabled: Boolean       read FRsmDisabled write FRsmDisabled;
    property ModuleClass:   TModuleSymbolsClass read FModuleClass write FModuleClass;

    property OnSymbolsLoaded:   TModuleSymbolsEvent     read FOnSymbolsLoaded   write FOnSymbolsLoaded;
    property ShouldRetryModule: TModuleRetryPredicate   read FShouldRetryModule write FShouldRetryModule;
    property RequiresFor:       TModuleRequiresSupplier read FRequiresFor       write FRequiresFor;
    property OnLog:             TModuleLoaderLog        read FOnLog     write FOnLog;
    property OnConsole:         TModuleLoaderLog        read FOnConsole write FOnConsole;
    // Fired immediately BEFORE a module's symbols are actually parsed (and only
    // when there is still unprobed work), with the module's DisplayName. The
    // frontend uses it to say WHICH module is being loaded while the debugger is
    // busy, instead of an unattributed "building call stack...".
    property OnModuleLoadBegin: TModuleLoaderLog        read FOnModuleLoadBegin write FOnModuleLoadBegin;

    // The main-exe CodeView reader (kept alive by FDebugInfo). Used by the frontend
    // to wire the variable expander; nil-safe for callers. Falls back to the
    // external `.tds` reader when the exe has no embedded `.debug`.
    property MainTD32: TTD32FileReader read GetMainTD32;
    // The owned module registry (read-only view for the frontends to iterate).
    property Modules:  TObjectList<TModuleSymbols> read FModules;

    // --- Main module (exe: RSM + TD32 + MAP) ---
    // EnsureMainRsm is latched + idempotent so it can also be called lazily from a
    // frontend before the first variable inspection.
    procedure EnsureMainRsm;
    function  LoadMainTD32: Boolean;
    // Loads the main exe's EXTERNAL `.tds` (dcc64 -VT) as the CodeView provider
    // when the exe has no embedded `.debug`. Skips a `.tds` older than the exe.
    // Returns True when a provider was registered.
    function  LoadMainTds: Boolean;
    // Registers the main exe's JCL provider (if present + fresh) BELOW TD32 but
    // ABOVE MAP in the provider chain. Latched + idempotent like EnsureMainRsm.
    procedure EnsureMainJcl;
    procedure LoadMainMap;
    procedure LoadMainModule(const AExePath, AMapPath, ARsmPath: string);

    // --- Runtime-module registry ---
    function  RegisterModuleRecord(const AName, AFullPath: string;
                ABase, AImageSize: UInt64): TModuleSymbols;
    procedure RemoveModuleRecord(const AName: string; ABase: UInt64);
    function  ModuleForPC(PC: UInt64): TModuleSymbols;
    // Owning-module identity + symbol state for an arbitrary code address,
    // covering BOTH the main exe and the runtime-loaded modules. ModuleName is
    // '' only when no known module owns PC (result saUnknownModule). Purely
    // descriptive: it never triggers a symbol load, so it is safe to call while
    // rendering a stack.
    function  DescribeAddress(PC: UInt64; out ModuleName: string): TSymbolAvailability;
    function  ModuleRvaRange(Module: TModuleSymbols; out Lo, Hi: UInt64): Boolean;
    procedure AddModuleProvider(Module: TModuleSymbols; const Provider: IInterface);

    // --- Per-module symbol load (synchronous) ---
    procedure EnsureModuleRsm(Module: TModuleSymbols);
    procedure EnsureModuleTD32(Module: TModuleSymbols);
    procedure EnsureModuleTds(Module: TModuleSymbols);
    procedure EnsureModuleJcl(Module: TModuleSymbols);
    procedure EnsureModuleMap(Module: TModuleSymbols);
    procedure EnsureModuleDcp(Module: TModuleSymbols);
    procedure LoadModuleSymbols(Module: TModuleSymbols);
    procedure EnsureModuleForPC(PC: UInt64);

    // --- Background prefetch (see the threading notes in the unit header) ---
    // Hands a just-loaded module to the worker so its symbols are already parsed
    // by the time the user stops. Idempotent and cheap; silently ignores modules
    // that are already loaded, already claimed, or are OS DLLs.
    procedure EnqueuePrefetch(Module: TModuleSymbols; HighPriority: Boolean = False);
    // Dispatch thread ONLY. Registers everything the worker finished since the
    // last call. Returns True when at least one provider was registered, so the
    // caller can repost breakpoints ONCE for the whole drain and tell a client
    // that the stack is worth re-fetching. Must be called regularly from the
    // frontend loop -- TDebugSession.Pump does.
    function  DrainPrefetch: Boolean;
    // Stops the worker and discards uncollected results. Idempotent.
    procedure ShutdownPrefetch;
  end;

implementation

uses
  Winapi.Windows, PeSymbolSupport;

var
  // -1 = not yet resolved from the environment, 0 = off, 1 = on.
  GPrefetchEnabled: Integer = -1;

procedure SetSymbolPrefetchEnabled(Value: Boolean);
begin
  if Value then
    GPrefetchEnabled := 1
  else
    GPrefetchEnabled := 0;
end;

function SymbolPrefetchEnabled: Boolean;
begin
  if GPrefetchEnabled < 0 then
    SetSymbolPrefetchEnabled(GetEnvironmentVariable('SYMBOL_PREFETCH') = '1');
  Result := GPrefetchEnabled = 1;
end;

{ TPrefetchOutcome }

procedure TPrefetchOutcome.FreeUnregistered;
// Frees whatever is still a raw object. Callers nil out each field as they take
// an interface reference to it, so only the orphans are left here.
begin
  Rsm.Free;
  Td32.Free;
  Tds.Free;
  Map.Free;
  Dcp.Free;
  Jcl := nil;
end;

// Builds every reader for one module on the PREFETCH WORKER THREAD.
//
// It is a plain function, not a method, on purpose: it must be provably unable to
// reach the loader, the registry or the provider set. Its only inputs are the
// value-copied request and the file system; its only outputs are brand-new
// objects that nothing else has ever seen and a list of log lines. The order of
// the fields it fills mirrors LoadModuleSymbols, and PublishPrefetch registers
// them in that same order -- provider order is load-bearing (first match wins).
function ParsePrefetch(const Req: TPrefetchRequest): TPrefetchOutcome;
var
  Outcome: TPrefetchOutcome;

  procedure Note(const Msg: string);
  begin
    Outcome.Logs := Outcome.Logs + [Msg];
  end;

begin
  Outcome := Default(TPrefetchOutcome);
  Outcome.Req := Req;
  Result := Outcome;
  if (Req.FullPath = '') or not FileExists(Req.FullPath) then
    Exit;

  {$Q-}
  var Shift: UInt64 := Req.Base - Req.ImageBase;
  {$Q+}

  // NOTE: this function deliberately does NOT wait for TRsmFile's own background
  // index to finish. Waiting would make the module's CLAIM last as long as the
  // index build (up to ~0.5 s on a 45 MB .dcp), and a claim is the one thing that
  // can make the dispatch thread wait. Publishing a reader whose index is still
  // building is exactly what the synchronous path has always done, so this is no
  // worse -- and it keeps claims down to the TD32 parse, which is both the
  // dominant cost and the provider that actually names frames.
  // --- RSM ---
  if (not Req.RsmDisabled) and (Req.RsmPath <> '') and FileExists(Req.RsmPath) then begin
    if SymbolFileIsStale(Req.RsmPath, Req.FullPath) then
      Note('DLL RSM is STALE -- ignoring, using TD32/.dcp: ' + Req.Name)
    else begin
      var RsmObj := TRsmFile.Create;
      try
        RsmObj.LoadFromFile(Req.RsmPath);
        if RsmObj.Loaded then begin
          Outcome.Rsm := RsmObj;
          Note('DLL RSM loaded (prefetch): ' + Req.Name);
        end else
          RsmObj.Free;
      except
        on E: Exception do begin
          RsmObj.Free;
          Note(Format('DLL RSM prefetch skipped: %s -- %s', [Req.Name, E.Message]));
        end;
      end;
    end;
  end;

  // --- TD32 (embedded `.debug`; always in sync with the binary) ---
  var TdObj := TTD32FileReader.Create;
  try
    TdObj.LoadFromFile(Req.FullPath, Shift);
    TdObj.ExposeLocals := True;
    Outcome.Td32 := TdObj;
    Note(Format('DLL TD32 loaded (prefetch): %s (shift=$%x)', [Req.Name, Shift]));
  except
    on E: Exception do begin
      TdObj.Free;
      Note(Format('DLL TD32 prefetch skipped: %s -- %s', [Req.Name, E.Message]));
    end;
  end;

  // --- TDS (external -VT debug info; only when there is no embedded TD32) ---
  if (Outcome.Td32 = nil) and (Req.TdsPath <> '') and FileExists(Req.TdsPath) and
     not SymbolFileIsStale(Req.TdsPath, Req.FullPath) then begin
    var TdsObj := TTD32FileReader.Create;
    try
      TdsObj.LoadFromTdsFile(Req.TdsPath, Req.FullPath, Shift);
      TdsObj.ExposeLocals := True;
      Outcome.Tds := TdsObj;
      Note(Format('DLL TDS loaded (prefetch): %s (shift=$%x)', [Req.Name, Shift]));
    except
      on E: Exception do begin
        TdsObj.Free;
        Note(Format('DLL TDS prefetch skipped: %s -- %s', [Req.Name, E.Message]));
      end;
    end;
  end;

  // --- JCL (linked JCLDEBUG section or `.jdbg` sidecar) ---
  try
    var Linked: Boolean;
    var JdbgPath: string;
    if JclDebugDataPresent(Req.FullPath, Linked, JdbgPath) and
       not ((not Linked) and SymbolFileIsStale(JdbgPath, Req.FullPath)) then begin
      var Prov: IInterface;
      if CreateJclDebugProvider(Req.FullPath, Shift, Req.ImageSize, Prov) then begin
        Outcome.Jcl := Prov;
        Note(Format('DLL JCL loaded (prefetch): %s (linked=%s)',
          [Req.Name, BoolToStr(Linked, True)]));
      end;
    end;
  except
    on E: Exception do
      Note(Format('DLL JCL prefetch skipped: %s -- %s', [Req.Name, E.Message]));
  end;

  // --- MAP ---
  if (Req.MapPath <> '') and FileExists(Req.MapPath) then begin
    var PB := Req.PreferredBase;
    if PB = 0 then
      PB := ReadPEPreferredBase(Req.FullPath);
    Outcome.PreferredBase := PB;
    var MapObj := TMapFile.Create;
    try
      MapObj.LoadFromFile(Req.MapPath, PB, Shift);
      MapObj.ImageSize := Req.ImageSize;
      Outcome.Map := MapObj;
      Note(Format('DLL MAP loaded (prefetch): %s (PB=$%x shift=$%x)', [Req.Name, PB, Shift]));
    except
      on E: Exception do begin
        MapObj.Free;
        Note(Format('DLL MAP prefetch skipped: %s -- %s', [Req.Name, E.Message]));
      end;
    end;
  end;

  // --- DCP (the package's rich unit debug info) ---
  var DcpPath := Req.DcpPath;
  if (DcpPath = '') or not FileExists(DcpPath) then
    DcpPath := ChangeFileExt(Req.FullPath, '.dcp');
  if FileExists(DcpPath) then begin
    Outcome.DcpPathUsed := DcpPath;
    var DcpObj := TRsmFile.Create;
    try
      DcpObj.LoadFromFile(DcpPath);
      if DcpObj.Loaded then begin
        Outcome.Dcp := DcpObj;
        Note('DLL DCP loaded (prefetch): ' + Req.Name);
      end else
        DcpObj.Free;
    except
      on E: Exception do begin
        DcpObj.Free;
        Note(Format('DLL DCP prefetch skipped: %s -- %s', [Req.Name, E.Message]));
      end;
    end;
  end;
  Result := Outcome;
end;

{ TSymbolPrefetcher }

constructor TSymbolPrefetcher.Create;
begin
  inherited Create;
  FLock    := TCriticalSection.Create;
  FWake    := TEvent.Create(nil, {ManualReset=}False, {InitialState=}False, '');
  FPending := TList<TPrefetchRequest>.Create;
  FDone    := TList<TPrefetchOutcome>.Create;
end;

destructor TSymbolPrefetcher.Destroy;
begin
  Shutdown;
  FDone.Free;
  FPending.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TSymbolPrefetcher.Start;
begin
  if FThread <> nil then
    Exit;
  AtomicExchange(FStop, 0);
  FThread := TThread.CreateAnonymousThread(Execute);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

function TSymbolPrefetcher.Running: Boolean;
begin
  Result := FThread <> nil;
end;

procedure TSymbolPrefetcher.Execute;
begin
  while AtomicCmpExchange(FStop, 0, 0) = 0 do begin
    var Req: TPrefetchRequest;
    var Got := False;
    FLock.Acquire;
    try
      if FPending.Count > 0 then begin
        Req := FPending[0];
        FPending.Delete(0);
        Got := True;
      end;
    finally
      FLock.Release;
    end;
    if not Got then begin
      FWake.WaitFor(50);   // short, so the stop flag is re-checked promptly
      Continue;
    end;
    var Outcome: TPrefetchOutcome;
    try
      Outcome := ParsePrefetch(Req);
    except
      on E: Exception do begin
        // An outcome MUST be produced for every popped request: publishing is
        // what clears the module's claim, and a stranded claim would make the
        // dispatch thread skip that module for the rest of the session.
        Outcome := Default(TPrefetchOutcome);
        Outcome.Req  := Req;
        Outcome.Logs := [Format('Symbol prefetch failed for %s: %s', [Req.Name, E.Message])];
      end;
    end;
    FLock.Acquire;
    try
      FDone.Add(Outcome);
    finally
      FLock.Release;
    end;
  end;
end;

procedure TSymbolPrefetcher.Push(const Req: TPrefetchRequest; HighPriority: Boolean);
begin
  FLock.Acquire;
  try
    if HighPriority then
      FPending.Insert(0, Req)
    else
      FPending.Add(Req);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TSymbolPrefetcher.TryRevoke(const AName: string; ABase: UInt64): Boolean;
begin
  Result := False;
  FLock.Acquire;
  try
    for var I := 0 to FPending.Count - 1 do
      if (FPending[I].Base = ABase) and SameText(FPending[I].Name, AName) then begin
        FPending.Delete(I);
        Exit(True);
      end;
  finally
    FLock.Release;
  end;
end;

function TSymbolPrefetcher.Pop(out Outcome: TPrefetchOutcome): Boolean;
begin
  Result := False;
  FLock.Acquire;
  try
    if FDone.Count = 0 then
      Exit;
    Outcome := FDone[0];
    FDone.Delete(0);
    Result := True;
  finally
    FLock.Release;
  end;
end;

procedure TSymbolPrefetcher.Shutdown;
begin
  if FThread <> nil then begin
    AtomicExchange(FStop, 1);
    FWake.SetEvent;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  // The worker is joined, so these lists are ours alone now. Anything still in
  // FDone was never registered: free the readers instead of leaking them.
  FLock.Acquire;
  try
    FPending.Clear;
    for var I := 0 to FDone.Count - 1 do begin
      var O := FDone[I];
      O.FreeUnregistered;
    end;
    FDone.Clear;
  finally
    FLock.Release;
  end;
end;

{ TModuleSymbols }

constructor TModuleSymbols.Create;
begin
  inherited Create;
end;

function TModuleSymbols.ContainsPC(PC: UInt64): Boolean;
begin
  Result := (Base > 0) and (PC >= Base) and
            ((ImageSize = 0) or (PC < Base + ImageSize));
end;

function TModuleSymbols.HasAnySymbols: Boolean;
begin
  Result := (Td32Iface <> nil) or (MapIface <> nil) or (RsmIface <> nil) or
            (DcpIface <> nil) or (JclIface <> nil);
end;

function TModuleSymbols.HasUnprobedSymbolFormats: Boolean;
begin
  Result := not (MapTried and RsmTried and Td32Tried and DcpTried and
                 JclTried and TdsTried);
end;

function TModuleSymbols.DisplayName: string;
begin
  if FullPath <> '' then
    Result := ChangeFileExt(ExtractFileName(FullPath), '')
  else
    Result := ChangeFileExt(Name, '');
end;

function TModuleSymbols.SymbolAvailability: TSymbolAvailability;
begin
  if not HasAnySymbols then
    Exit(saNoSymbols);
  // Only a REGISTERED provider may be asked whether it is still indexing: an
  // unloaded TMapFile reports "pending" simply because it never started, which
  // would mislabel a symbol-less module as merely slow.
  for var Provider in [MapIface, RsmIface, Td32Iface, DcpIface, JclIface, TdsIface] do begin
    var Indexed: IBackgroundIndexProvider;
    if (Provider <> nil) and Supports(Provider, IBackgroundIndexProvider, Indexed) and
       Indexed.BackgroundIndexingPending then
      Exit(saIndexing);
  end;
  Result := saLoaded;
end;

function TModuleSymbols.ContainsSourceFile(const FileName: string): Boolean;
begin
  // Conservative base answer: a module with a Delphi sidecar might own the file,
  // so allow the load rather than risk missing a breakpoint. Subclasses override.
  Result := (MapPath <> '') or (RsmPath <> '') or (DcpPath <> '');
end;

{ TModuleSymbolLoader }

constructor TModuleSymbolLoader.Create;
begin
  inherited Create;
  FMainMap     := TMapFile.Create;
  FMainTD32    := TTD32FileReader.Create;
  FMainTds     := TTD32FileReader.Create;
  FMainRsm     := TRsmFile.Create;
  FModules     := TObjectList<TModuleSymbols>.Create(True);
  FModuleClass := TModuleSymbols;
end;

destructor TModuleSymbolLoader.Destroy;
begin
  // FIRST: join the worker and discard anything it produced but nobody
  // registered. After this point no other thread can reach the registry.
  ShutdownPrefetch;
  // Remove each runtime module's providers from FDebugInfo (while it is still
  // alive) before freeing the registry, so its interface refs are dropped
  // cleanly. The main-module readers are released by FDebugInfo itself (ARC).
  if FModules <> nil then begin
    if FDebugInfo <> nil then
      for var M in FModules do begin
        if M.MapIface  <> nil then FDebugInfo.RemoveProvider(M.MapIface);
        if M.RsmIface  <> nil then FDebugInfo.RemoveProvider(M.RsmIface);
        if M.Td32Iface <> nil then FDebugInfo.RemoveProvider(M.Td32Iface);
        if M.DcpIface  <> nil then FDebugInfo.RemoveProvider(M.DcpIface);
        if M.JclIface  <> nil then FDebugInfo.RemoveProvider(M.JclIface);
        if M.TdsIface  <> nil then FDebugInfo.RemoveProvider(M.TdsIface);
      end;
    FModules.Free;
  end;
  // FMainMap / FMainTD32 / FMainRsm are TInterfacedObject, ref-counted via the
  // interfaces held by FDebugInfo; freeing the raw object here is a double-free.
  // They auto-destroy when FDebugInfo releases its provider refs. An unused
  // loader (LoadMainModule never called) leaks these three -- acceptable, and
  // identical to the pre-extraction frontend behaviour.
  inherited;
end;

procedure TModuleSymbolLoader.Log(const Msg: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Msg);
end;

procedure TModuleSymbolLoader.Console(const Msg: string);
begin
  if Assigned(FOnConsole) then
    FOnConsole(Msg);
end;

function TModuleSymbolLoader.ShouldRetry(const AName: string): Boolean;
begin
  if Assigned(FShouldRetryModule) then
    Result := FShouldRetryModule(AName)
  else
    Result := False;
end;

function TModuleSymbolLoader.RequiresOf(Module: TModuleSymbols): TArray<string>;
begin
  if Assigned(FRequiresFor) then
    Result := FRequiresFor(Module)
  else
    Result := nil;
end;

procedure TModuleSymbolLoader.AddMainProvider(const Provider: IInterface;
  const Format: string; Primary: Boolean = False);
begin
  var ImageSize := ReadPEImageSize(FExePath);
  if ImageSize > 0 then
    FDebugInfo.AddProviderForModule(Provider, 0, ImageSize, Primary)
  else
    FDebugInfo.AddProvider(Provider, Primary);
  Inc(FMainProviderCount);
  // Recorded HERE, where the registration actually happens, rather than
  // inferred afterwards from the various *Loaded flags: those say an attempt
  // was made, not that a provider was accepted.
  if Format <> '' then
    FMainFormats := FMainFormats + [Format];
end;

function TModuleSymbolLoader.MainSymbolFormats: TArray<string>;
begin
  Result := FMainFormats;
end;

{ Main module }

procedure TModuleSymbolLoader.EnsureMainRsm;
begin
  if FMainRsmLoaded then
    Exit;
  FMainRsmLoaded := True;
  if FRsmDisabled then begin
    Console('RSM disabled by NO_RSM=1 -- main module uses TD32+MAP only');
    Exit;
  end;
  if not FileExists(FRsmPath) then
    Exit;
  // A .rsm older than the EXE describes a previous build: its symbols/types/
  // offsets no longer match and would silently mis-type variables. Skip it and
  // rely on the always-in-sync embedded TD32 instead.
  if SymbolFileIsStale(FRsmPath, FExePath) then begin
    Console(Format('RSM is STALE (older than the EXE) -- IGNORING it; using TD32. Rebuild to refresh: %s',
      [FRsmPath]));
    Exit;
  end;
  Console('Loading RSM type info: ' + FRsmPath);
  FMainRsm.LoadFromFile(FRsmPath);
  AddMainProvider(FMainRsm, 'rsm');
  Console('RSM loaded');
end;

function TModuleSymbolLoader.LoadMainTD32: Boolean;
begin
  Result := False;
  try
    FMainTD32.LoadFromFile(FExePath);
    // Expose locals so DebugInfoSet.GetLocalsForFunction can merge TD32's better
    // TypeHints (managed types via $003x leaves) on top of RSM's locals.
    FMainTD32.ExposeLocals := True;
    AddMainProvider(FMainTD32 as IInterface, 'td32', {Primary=}True);
    Result := True;
    Console('TD32 loaded');
  except
    on E: Exception do
      Console('TD32 unavailable: ' + E.Message + ' -- continuing with MAP');
  end;
end;

function TModuleSymbolLoader.GetMainTD32: TTD32FileReader;
begin
  // Prefer the embedded reader; fall back to the external `.tds` reader when the
  // exe had no `.debug` section (a -VT-only build).
  if (FMainTD32 <> nil) and FMainTD32.Loaded then
    Result := FMainTD32
  else if (FMainTds <> nil) and FMainTds.Loaded then
    Result := FMainTds
  else
    Result := FMainTD32;
end;

function TModuleSymbolLoader.LoadMainTds: Boolean;
begin
  Result := False;
  var TdsPath := ChangeFileExt(FExePath, '.tds');
  if not FileExists(TdsPath) then
    Exit;
  // A `.tds` older than the exe describes a previous build: skip it (same policy
  // as a stale .rsm/.map/.jdbg) rather than mis-resolving against the new binary.
  if SymbolFileIsStale(TdsPath, FExePath) then begin
    Console(Format('TDS is STALE (older than the EXE) -- IGNORING it: %s', [TdsPath]));
    Exit;
  end;
  try
    FMainTds.LoadFromTdsFile(TdsPath, FExePath);
    FMainTds.ExposeLocals := True;
    AddMainProvider(FMainTds as IInterface, 'tds', {Primary=}True);
    Result := True;
    Console('TDS (external -VT debug info) loaded: ' + TdsPath);
  except
    on E: Exception do
      Console('TDS load failed: ' + E.Message + ' -- continuing with MAP');
  end;
end;

procedure TModuleSymbolLoader.EnsureMainJcl;
begin
  if FMainJclLoaded then
    Exit;
  FMainJclLoaded := True;
  var Linked: Boolean;
  var JdbgPath: string;
  if not JclDebugDataPresent(FExePath, Linked, JdbgPath) then
    Exit;
  // A '.jdbg' sidecar older than the EXE describes a previous build (linked
  // section data lives inside the EXE, so it is never stale). Skip a stale
  // sidecar and rely on the always-in-sync embedded TD32.
  if (not Linked) and SymbolFileIsStale(JdbgPath, FExePath) then begin
    Console(Format('JCL .jdbg is STALE (older than the EXE) -- IGNORING it; using TD32. Rebuild to refresh: %s',
      [JdbgPath]));
    Exit;
  end;
  var Prov: IInterface;
  // ImageSize bounds the RVA window the provider answers for (0-based for the
  // main exe), so a flat-path query with a kernel / other-module address is
  // rejected instead of mis-clamped by JCL's scanner.
  if not CreateJclDebugProvider(FExePath, 0, ReadPEImageSize(FExePath), Prov) then
    Exit;
  FMainJcl := Prov;
  AddMainProvider(Prov, 'jdbg');
  if Linked then
    Console('JCL debug info loaded (linked JCLDEBUG section): ' + FExePath)
  else
    Console('JCL debug info loaded (sidecar): ' + JdbgPath);
end;

procedure TModuleSymbolLoader.LoadMainMap;
begin
  if not FileExists(FMapPath) then
    Exit;
  Console('Loading MAP: ' + FMapPath);
  FMainMap.LoadFromFile(FMapPath, ReadPEPreferredBase(FExePath));
  AddMainProvider(FMainMap, 'map');
  FMainMapRegistered := True;
  Console('MAP loaded');
end;

procedure TModuleSymbolLoader.LoadMainModule(const AExePath, AMapPath, ARsmPath: string);
begin
  FExePath := AExePath;
  FMapPath := AMapPath;
  FRsmPath := ARsmPath;
  // SizeOfImage from the on-disk headers: the exe is mapped at FDebugger.ImageBase
  // and this is the only place its extent is known without a module event.
  FMainImageSize := ReadPEImageSize(FExePath);
  // RSM must be added BEFORE TD32 so TD32 is the primary for types/locals with
  // RSM as the fallback. JCL slots BELOW TD32 (embedded, always fresh) but ABOVE
  // MAP as a line/function fallback. MAP loads last (nested-proc parent linkage
  // lives only in the MAP's $pdata publics; JCL does not carry it).
  EnsureMainRsm;
  // Embedded TD32 (`.debug`) is always in sync with the exe. Only if it is absent
  // (a -VT-only build) fall back to the external `.tds`.
  if not LoadMainTD32 then
    LoadMainTds;
  EnsureMainJcl;
  LoadMainMap;
  // "No debug info in any format" diagnostic for the main exe: with no provider
  // registered there are no lines / locals / function names at all, so make the
  // blind exe obvious instead of silently producing nothing.
  if FMainProviderCount = 0 then
    Console(Format('No debug info for %s -- symbols unavailable (looked for ' +
      'embedded TD32 / .tds / .map / .rsm / .jdbg). Build with -V -VN -VR for debug info.',
      [FExePath]));
  // TD32 is embedded (always fresh); only the .rsm / .map sidecars can drift.
  if SymbolFileIsStale(FRsmPath, FExePath) then
    Console(Format('WARNING: RSM is OLDER than the EXE -- it will be IGNORED (TD32 used instead) to avoid stale mis-typing. Rebuild to use it: %s',
      [FRsmPath]));
  if SymbolFileIsStale(FMapPath, FExePath) then
    Console(Format('WARNING: MAP is OLDER than the EXE -- symbols may be stale. Rebuild to regenerate: %s',
      [FMapPath]));
end;

{ Registry }

function TModuleSymbolLoader.RegisterModuleRecord(const AName, AFullPath: string;
  ABase, AImageSize: UInt64): TModuleSymbols;
begin
  Result := FModuleClass.Create;
  Result.Name      := LowerCase(AName);
  Result.FullPath  := AFullPath;
  Result.Base      := ABase;
  Result.ImageSize := AImageSize;
  Result.MapPath   := ChangeFileExt(AFullPath, '.map');
  Result.RsmPath   := ChangeFileExt(AFullPath, '.rsm');
  Result.DcpPath   := ChangeFileExt(AFullPath, '.dcp');
  Result.TdsPath   := ChangeFileExt(AFullPath, '.tds');
  FModules.Add(Result);
end;

procedure TModuleSymbolLoader.RemoveModuleRecord(const AName: string; ABase: UInt64);
begin
  var LName := LowerCase(AName);
  for var I := FModules.Count - 1 downto 0 do begin
    var M := FModules[I];
    if M.Name = LName then begin
      if M.MapIface  <> nil then FDebugInfo.RemoveProvider(M.MapIface);
      if M.RsmIface  <> nil then FDebugInfo.RemoveProvider(M.RsmIface);
      if M.Td32Iface <> nil then FDebugInfo.RemoveProvider(M.Td32Iface);
      if M.DcpIface  <> nil then FDebugInfo.RemoveProvider(M.DcpIface);
      if M.JclIface  <> nil then FDebugInfo.RemoveProvider(M.JclIface);
      if M.TdsIface  <> nil then FDebugInfo.RemoveProvider(M.TdsIface);
      FModules.Delete(I);
      Exit;
    end;
  end;
end;

function TModuleSymbolLoader.ModuleForPC(PC: UInt64): TModuleSymbols;
begin
  // Pick the nearest module base <= PC among matching ranges. Avoids false
  // positives when a LOAD_DLL event did not expose SizeOfImage (ImageSize=0),
  // where a first-match scan can pick the wrong module.
  Result := nil;
  var BestBase: UInt64 := 0;
  for var M in FModules do
    if M.ContainsPC(PC) then
      if (Result = nil) or (M.Base >= BestBase) then begin
        Result := M;
        BestBase := M.Base;
      end;
end;

function TModuleSymbolLoader.MainModuleContainsPC(PC: UInt64): Boolean;
begin
  if (FExePath = '') or (FDebugger = nil) then
    Exit(False);
  var Base := FDebugger.ImageBase;
  if (Base = 0) or (PC < Base) then
    Exit(False);
  // An unreadable / absent PE gives size 0; treat the extent as unknown rather
  // than claiming every address above the base belongs to the exe.
  Result := (FMainImageSize > 0) and (PC < Base + FMainImageSize);
end;

function TModuleSymbolLoader.MainSymbolAvailability: TSymbolAvailability;
begin
  if FMainProviderCount = 0 then
    Exit(saNoSymbols);
  if FMainMapRegistered and FMainMap.BackgroundIndexingPending then
    Exit(saIndexing);
  Result := saLoaded;
end;

function TModuleSymbolLoader.DescribeAddress(PC: UInt64;
  out ModuleName: string): TSymbolAvailability;
begin
  ModuleName := '';
  var Module := ModuleForPC(PC);
  if Module <> nil then begin
    ModuleName := Module.Name;
    Exit(Module.SymbolAvailability);
  end;
  if MainModuleContainsPC(PC) then begin
    ModuleName := LowerCase(ExtractFileName(FExePath));
    Exit(MainSymbolAvailability);
  end;
  Result := saUnknownModule;
end;

function TModuleSymbolLoader.ModuleRvaRange(Module: TModuleSymbols;
  out Lo, Hi: UInt64): Boolean;
begin
  Lo := 0; Hi := 0;
  Result := (FDebugger <> nil) and (Module.Base <> 0) and (Module.ImageSize > 0);
  if not Result then
    Exit;
  {$Q-}
  Lo := Module.Base - FDebugger.ImageBase;
  {$Q+}
  Hi := Lo + Module.ImageSize;
end;

procedure TModuleSymbolLoader.AddModuleProvider(Module: TModuleSymbols;
  const Provider: IInterface);
begin
  var Lo, Hi: UInt64;
  if ModuleRvaRange(Module, Lo, Hi) then
    // Tag the ranged provider with this module's base name + its requires so the
    // by-name locals fallback stays within the owning binary and the uses-graph
    // global tier can prefer a required package's global.
    FDebugInfo.AddProviderForModule(Provider, Lo, Hi, False,
      LowerCase(ChangeFileExt(Module.Name, '')), RequiresOf(Module))
  else
    FDebugInfo.AddProvider(Provider);
end;

{ Per-module symbol load }

procedure TModuleSymbolLoader.EnsureModuleMap(Module: TModuleSymbols);
begin
  if PrefetchBlocks(Module) then
    Exit;
  if Module.MapIface <> nil then
    Exit;
  if Module.MapTried and not ShouldRetry(Module.Name) then
    Exit;
  Module.MapTried := True;
  if (Module.MapPath = '') or not FileExists(Module.MapPath) then
    Exit;
  if (Module.PreferredBase = 0) and FileExists(Module.FullPath) then
    Module.PreferredBase := ReadPEPreferredBase(Module.FullPath);
  var MapObj := TMapFile.Create;
  // FDebugInfo presents RVAs relative to the exe's ImageBase. A DLL/BPL function
  // at runtime VA = Module.Base + dllRva; to present it as an exe-RVA we add
  // Shift = Module.Base - exeImageBase to every emitted RVA.
  {$Q-}
  var Shift: UInt64 := Module.Base - FDebugger.ImageBase;
  {$Q+}
  MapObj.LoadFromFile(Module.MapPath, Module.PreferredBase, Shift);
  // Bound the MAP's Rva window to this module's REAL size. Without it a blanket
  // 1 GB span let an Rva from another (unknown / stripped) module fall inside this
  // module's range and take the name of its nearest preceding public.
  MapObj.ImageSize := Module.ImageSize;
  Module.MapIface := MapObj as IInterface;
  // Range-scope the module MAP like TD32/RSM/DCP/JCL. AddModuleProvider still adds it
  // to the FLAT name/line lists (so cross-module NameToRva etc. are unchanged), but
  // ALSO to the ranged Rva-> lists, so an RVA this module OWNS that its ranged TD32
  // can't name (e.g. an anonymous-method body -- TD32 emits no proc symbol for it)
  // falls through to the MAP here instead of the ranged TD32 returning "owned but
  // none" and blocking the flat MAP entirely.
  AddModuleProvider(Module, MapObj);
  Log(Format('DLL MAP loaded: %s (PB=$%x shift=$%x)',
    [Module.Name, Module.PreferredBase, Shift]));
end;

procedure TModuleSymbolLoader.EnsureModuleRsm(Module: TModuleSymbols);
begin
  if PrefetchBlocks(Module) then
    Exit;
  if Module.RsmIface <> nil then
    Exit;
  if Module.RsmTried and not ShouldRetry(Module.Name) then
    Exit;
  Module.RsmTried := True;
  if FRsmDisabled then begin
    Log('DLL RSM skipped (NO_RSM=1): ' + Module.Name);
    Exit;
  end;
  if (Module.RsmPath = '') or not FileExists(Module.RsmPath) then
    Exit;
  // A stale module .rsm (older than the BPL) would mis-type; the package's
  // embedded TD32 and its .dcp cover the module instead.
  if SymbolFileIsStale(Module.RsmPath, Module.FullPath) then begin
    Log('DLL RSM is STALE -- ignoring, using TD32/.dcp: ' + Module.Name);
    Exit;
  end;
  var RsmObj := TRsmFile.Create;
  RsmObj.LoadFromFile(Module.RsmPath);
  Module.RsmIface := RsmObj as IInterface;
  AddModuleProvider(Module, RsmObj);
  Log('DLL RSM loaded: ' + Module.Name);
end;

procedure TModuleSymbolLoader.EnsureModuleDcp(Module: TModuleSymbols);
// Loads the per-package .dcp as an additional symbol provider for BPL targets.
// dcc64 emits unit-level debug records into the .dcp using the same schema as the
// .rsm (only the container prefix differs), so TRsmFile parses both. A BPL's own
// .rsm holds only package skeleton + RTL boilerplate; the code's debug info is in
// the .dcp. The DAP stamps Module.DcpPath from launch config in OnDllLoaded, so
// the config override is already reflected in Module.DcpPath here.
begin
  if PrefetchBlocks(Module) then
    Exit;
  if Module.DcpIface <> nil then
    Exit;
  if Module.DcpTried and not ShouldRetry(Module.Name) then
    Exit;
  Module.DcpTried := True;
  var DcpPath := Module.DcpPath;
  if (DcpPath = '') or not FileExists(DcpPath) then
    DcpPath := ChangeFileExt(Module.FullPath, '.dcp');
  if not FileExists(DcpPath) then
    Exit;
  Module.DcpPath := DcpPath;
  var DcpObj := TRsmFile.Create;
  DcpObj.LoadFromFile(DcpPath);
  if not DcpObj.Loaded then begin
    DcpObj.Free;
    Log('DLL DCP load skipped (magic check failed): ' + DcpPath);
    Exit;
  end;
  Module.DcpIface := DcpObj as IInterface;
  AddModuleProvider(Module, DcpObj);
  Log('DLL DCP loaded: ' + Module.Name);
end;

procedure TModuleSymbolLoader.EnsureModuleJcl(Module: TModuleSymbols);
// Loads a runtime module's JCL provider (linked 'JCLDEBUG' section or '.jdbg'
// sidecar), RVA-range-scoped and shifted like TD32/MAP. Registered BELOW TD32 and
// ABOVE MAP as a line/function fallback for a module lacking embedded TD32.
begin
  if PrefetchBlocks(Module) then
    Exit;
  if Module.JclIface <> nil then
    Exit;
  if Module.JclTried and not ShouldRetry(Module.Name) then
    Exit;
  Module.JclTried := True;
  if (Module.FullPath = '') or not FileExists(Module.FullPath) then
    Exit;
  var Linked: Boolean;
  var JdbgPath: string;
  if not JclDebugDataPresent(Module.FullPath, Linked, JdbgPath) then
    Exit;
  if (not Linked) and SymbolFileIsStale(JdbgPath, Module.FullPath) then begin
    Log('DLL JCL .jdbg is STALE -- ignoring, using TD32/.dcp: ' + Module.Name);
    Exit;
  end;
  {$Q-}
  var Shift: UInt64 := Module.Base - FDebugger.ImageBase;
  {$Q+}
  var Prov: IInterface;
  // ImageSize bounds the exe-space RVA window [Shift, Shift+ImageSize) this
  // module answers for, so JCL is never queried for another module's address.
  if not CreateJclDebugProvider(Module.FullPath, Shift, Module.ImageSize, Prov) then
    Exit;
  Module.JclIface := Prov;
  AddModuleProvider(Module, Prov);
  Log(Format('DLL JCL debug info loaded: %s (linked=%s shift=$%x)',
    [Module.Name, BoolToStr(Linked, True), Shift]));
end;

procedure TModuleSymbolLoader.EnsureModuleTD32(Module: TModuleSymbols);
begin
  if PrefetchBlocks(Module) then
    Exit;
  if Module.Td32Iface <> nil then
    Exit;
  if Module.Td32Tried and not ShouldRetry(Module.Name) then
    Exit;
  Module.Td32Tried := True;
  if (Module.FullPath = '') or not FileExists(Module.FullPath) then
    Exit;
  // OutputRvaShift = Module.Base - exeImageBase (mirrors EnsureModuleMap; using
  // the BPL's own preferred base would double-count the relocation and BPs in BPL
  // code would never fire).
  {$Q-}
  var Shift: UInt64 := Module.Base - FDebugger.ImageBase;
  {$Q+}
  var Obj := TTD32FileReader.Create;
  try
    Obj.LoadFromFile(Module.FullPath, Shift);
  except
    on E: Exception do begin
      Obj.Free;
      Log(Format('DLL TD32 load skipped: %s -- %s', [Module.Name, E.Message]));
      Exit;
    end;
  end;
  // Expose locals from the BPL/DLL TD32 as the main exe does: a package's RSM
  // frequently lacks a function's locals that its TD32 has in full.
  Obj.ExposeLocals := True;
  Module.Td32Iface := Obj as IInterface;
  AddModuleProvider(Module, Obj);
  Log(Format('DLL TD32 loaded: %s (shift=$%x)', [Module.Name, Shift]));
  // Symbols (the line table lives in TD32) are now in: let the frontend re-bind /
  // re-colour any breakpoint whose source lives here (eventually-consistent BP
  // binding across load/stop/evaluate triggers).
  if Assigned(FOnSymbolsLoaded) then
    FOnSymbolsLoaded(Module);
end;

procedure TModuleSymbolLoader.EnsureModuleTds(Module: TModuleSymbols);
// External `.tds` (dcc64 -VT) for a runtime module that has NO embedded `.debug`.
// Only attempted when EnsureModuleTD32 registered nothing; skips a stale `.tds`.
begin
  if PrefetchBlocks(Module) then
    Exit;
  if (Module.Td32Iface <> nil) or (Module.TdsIface <> nil) then
    Exit;
  if Module.TdsTried and not ShouldRetry(Module.Name) then
    Exit;
  Module.TdsTried := True;
  if (Module.TdsPath = '') or not FileExists(Module.TdsPath) or
     (Module.FullPath = '') or not FileExists(Module.FullPath) then
    Exit;
  if SymbolFileIsStale(Module.TdsPath, Module.FullPath) then begin
    Log('DLL TDS is STALE -- ignoring: ' + Module.Name);
    Exit;
  end;
  {$Q-}
  var Shift: UInt64 := Module.Base - FDebugger.ImageBase;
  {$Q+}
  var Obj := TTD32FileReader.Create;
  try
    Obj.LoadFromTdsFile(Module.TdsPath, Module.FullPath, Shift);
  except
    on E: Exception do begin
      Obj.Free;
      Log(Format('DLL TDS load skipped: %s -- %s', [Module.Name, E.Message]));
      Exit;
    end;
  end;
  Obj.ExposeLocals := True;
  Module.TdsIface := Obj as IInterface;
  AddModuleProvider(Module, Obj);
  Log(Format('DLL TDS (external -VT) loaded: %s (shift=$%x)', [Module.Name, Shift]));
  if Assigned(FOnSymbolsLoaded) then
    FOnSymbolsLoaded(Module);
end;

procedure TModuleSymbolLoader.LoadModuleSymbols(Module: TModuleSymbols);
begin
  // Tell the frontend which module is about to be parsed, but only when at least
  // one format is still unprobed -- a re-sweep over an already-loaded module is
  // free and must not produce a misleading "Loading symbols: X" message.
  if Assigned(FOnModuleLoadBegin) and Module.HasUnprobedSymbolFormats then
    FOnModuleLoadBegin(Module.DisplayName);
  // RSM first so it stays the primary member/enum answerer for the types it
  // knows; TD32 then fills gaps (line tables, function names, imports); MAP / DCP
  // are further fallbacks. TDS is the embedded-TD32 alternative for -VT modules.
  EnsureModuleRsm(Module);
  EnsureModuleTD32(Module);
  EnsureModuleTds(Module);
  EnsureModuleJcl(Module);
  EnsureModuleMap(Module);
  EnsureModuleDcp(Module);
  // "No debug info in any format" diagnostic: a module the debugger cannot
  // symbolicate is otherwise silent (no lines / locals / function names). Report
  // it once -- but only when nothing is left to try (every format probed AND no
  // retry pending), so a module still awaiting a config-supplied path is not
  // flagged prematurely.
  // A module whose prefetch is still in flight is LOADING, not symbol-less: saying
  // so would be both wrong and a console flood on a many-package host.
  if (not Module.HasAnySymbols) and (not Module.NoSymbolsReported) and
     (not Module.PrefetchInFlight) and not ShouldRetry(Module.Name) then begin
    Module.NoSymbolsReported := True;
    Console(Format('No debug info for module %s -- symbols unavailable ' +
      '(looked for embedded TD32 / .map / .rsm / .dcp / .jdbg)', [Module.Name]));
  end;
end;

procedure TModuleSymbolLoader.EnsureModuleForPC(PC: UInt64);
begin
  var Module := ModuleForPC(PC);
  if Module = nil then
    Exit;
  // Deliberately does NOT enqueue. A module the debugger needs RIGHT NOW is
  // cheaper to parse in-line than to hand to the worker and then wait for -- the
  // dispatch thread would pay the same parse plus queue latency. Prefetching is
  // about modules the debugger will need LATER, which is why the only enqueue
  // site is the module-load event.
  LoadModuleSymbols(Module);
end;

{ Background prefetch }

function TModuleSymbolLoader.PrefetchBlocks(Module: TModuleSymbols): Boolean;
// Gate at the top of every dispatch-thread Ensure*.
//
// False -> the caller owns this module and parses normally.
// True  -> the worker owns it and is not finished; the caller must return
//          WITHOUT parsing and WITHOUT setting any *Tried flag, because the
//          module is LOADING, not symbol-less, and the next request must retry.
//
// IT NEVER WAITS. Two outcomes only:
//   * the request is still queued -> steal it back and parse in-line, which is
//     exactly the cost and latency of the pre-prefetch code;
//   * the worker has already started -> decline, and let the result register on
//     a following pump turn. The frame is nameless for this one request and the
//     DAP's `invalidated` event (or the next MCP request) refills it.
//
// An earlier revision waited briefly here instead of declining. It was bounded
// (750 ms, further capped by the interactive budget) and it still reintroduced
// the exact failure that got the previous background loader disabled: one
// request per full-suite run timing out in the BPL fixture, invisible in
// isolation. Waiting on symbol state from the dispatch thread is the F14 hazard;
// a bound is not enough, because publication, breakpoint reposting and further
// module loads all run on that same thread and compound. Do not put a wait back.
begin
  Result := False;
  if not Module.PrefetchInFlight then
    Exit;
  if (FPrefetch <> nil) and FPrefetch.TryRevoke(Module.Name, Module.Base) then begin
    Module.PrefetchInFlight := False;
    Exit;
  end;
  Result := True;
end;

function TModuleSymbolLoader.SnapshotForPrefetch(Module: TModuleSymbols;
  out Req: TPrefetchRequest): Boolean;
begin
  Req := Default(TPrefetchRequest);
  Result := False;
  if (FDebugger = nil) or (Module.FullPath = '') then
    Exit;
  Req.Name          := Module.Name;
  Req.FullPath      := Module.FullPath;
  Req.MapPath       := Module.MapPath;
  Req.RsmPath       := Module.RsmPath;
  Req.DcpPath       := Module.DcpPath;
  Req.TdsPath       := Module.TdsPath;
  Req.Base          := Module.Base;
  Req.ImageSize     := Module.ImageSize;
  Req.PreferredBase := Module.PreferredBase;
  Req.ImageBase     := FDebugger.ImageBase;
  Req.RsmDisabled   := FRsmDisabled;
  Result := True;
end;

procedure TModuleSymbolLoader.EnqueuePrefetch(Module: TModuleSymbols;
  HighPriority: Boolean = False);
begin
  if (Module = nil) or Module.PrefetchInFlight or Module.PrefetchRequested then
    Exit;
  // OFF by default -- see the note on SetSymbolPrefetchEnabled.
  if not SymbolPrefetchEnabled then
    Exit;
  // Nothing left to prefetch: the synchronous path already covered this module
  // (typically because it owns a breakpoint and was loaded eagerly at its
  // LOAD_DLL event).
  if Module.Td32Tried and Module.RsmTried and Module.MapTried and Module.DcpTried then
    Exit;
  // Skip the OS-DLL storm. A stripped system module costs ~1 ms to probe, but a
  // many-package host maps hundreds of them and they can never carry Delphi debug
  // info, so there is nothing to gain and a queue to keep short.
  if Module.FullPath.ToLower.Contains('\windows\') then
    Exit;
  var Req: TPrefetchRequest;
  if not SnapshotForPrefetch(Module, Req) then
    Exit;
  if FPrefetch = nil then
    FPrefetch := TSymbolPrefetcher.Create;
  FPrefetch.Start;
  // CLAIM FIRST, then queue. Between here and PublishPrefetch no dispatch-thread
  // Ensure* may parse this module -- that is the whole single-load-path rule.
  Module.PrefetchRequested := True;
  Module.PrefetchInFlight  := True;
  FPrefetch.Push(Req, HighPriority);
end;

function TModuleSymbolLoader.PublishPrefetch(const Outcome: TPrefetchOutcome): Boolean;
// Dispatch thread. Takes an interface reference to each finished reader (which
// registers it) or frees it. Registration order mirrors LoadModuleSymbols exactly
// -- RSM, TD32, TDS, JCL, MAP, DCP -- because first-match-wins across the provider
// chain is load-bearing.
var
  Orphans: TPrefetchOutcome;
begin
  Result := False;
  Orphans := Outcome;
  var SymbolsArrived := False;
  try
    // The module may have unloaded while the worker was parsing. Match on name
    // AND base so a reload at a different address is not mistaken for the same
    // module (the readers carry a base-derived RVA shift and would be wrong).
    var Module: TModuleSymbols := nil;
    for var M in FModules do
      if (M.Base = Outcome.Req.Base) and SameText(M.Name, Outcome.Req.Name) then begin
        Module := M;
        Break;
      end;
    if Module = nil then
      Exit;
    Module.PrefetchInFlight := False;

    for var Line in Outcome.Logs do
      Log(Line);
    if Outcome.PreferredBase <> 0 then
      Module.PreferredBase := Outcome.PreferredBase;
    if Outcome.DcpPathUsed <> '' then
      Module.DcpPath := Outcome.DcpPathUsed;

    if Outcome.Rsm <> nil then begin
      Module.RsmTried := True;
      if Module.RsmIface = nil then begin
        Module.RsmIface := Outcome.Rsm as IInterface;
        Orphans.Rsm := nil;
        AddModuleProvider(Module, Module.RsmIface);
      end;
    end;
    if Outcome.Td32 <> nil then begin
      Module.Td32Tried := True;
      if Module.Td32Iface = nil then begin
        Module.Td32Iface := Outcome.Td32 as IInterface;
        Orphans.Td32 := nil;
        AddModuleProvider(Module, Module.Td32Iface);
        SymbolsArrived := True;
      end;
    end;
    if Outcome.Tds <> nil then begin
      Module.TdsTried := True;
      if (Module.Td32Iface = nil) and (Module.TdsIface = nil) then begin
        Module.TdsIface := Outcome.Tds as IInterface;
        Orphans.Tds := nil;
        AddModuleProvider(Module, Module.TdsIface);
        SymbolsArrived := True;
      end;
    end;
    if Outcome.Jcl <> nil then begin
      Module.JclTried := True;
      if Module.JclIface = nil then begin
        Module.JclIface := Outcome.Jcl;
        Orphans.Jcl := nil;
        AddModuleProvider(Module, Module.JclIface);
        SymbolsArrived := True;
      end;
    end;
    if Outcome.Map <> nil then begin
      Module.MapTried := True;
      if Module.MapIface = nil then begin
        Module.MapIface := Outcome.Map as IInterface;
        Orphans.Map := nil;
        AddModuleProvider(Module, Module.MapIface);
        SymbolsArrived := True;
      end;
    end;
    if Outcome.Dcp <> nil then begin
      Module.DcpTried := True;
      if Module.DcpIface = nil then begin
        Module.DcpIface := Outcome.Dcp as IInterface;
        Orphans.Dcp := nil;
        AddModuleProvider(Module, Module.DcpIface);
        SymbolsArrived := True;
      end;
    end;

    // NOTE: FOnSymbolsLoaded is deliberately NOT fired per module here. It drives
    // RepostBreakpoints, and a drain can publish a dozen modules in one turn;
    // reposting every breakpoint spec a dozen times over is pure churn. The
    // caller reposts ONCE for the whole drain instead (DrainPrefetch's result).
    Result := SymbolsArrived;
  finally
    // Whatever we did not take a reference to (module gone, or a provider that
    // the synchronous path had already registered) is freed here.
    Orphans.FreeUnregistered;
  end;
end;

function TModuleSymbolLoader.DrainPrefetch: Boolean;
begin
  Result := False;
  if FPrefetch = nil then
    Exit;
  var Outcome: TPrefetchOutcome;
  while FPrefetch.Pop(Outcome) do
    if PublishPrefetch(Outcome) then
      Result := True;
end;

procedure TModuleSymbolLoader.ShutdownPrefetch;
begin
  if FPrefetch = nil then
    Exit;
  FPrefetch.Shutdown;
  FreeAndNil(FPrefetch);
  // Any module still claimed will never be published now; release the claims so
  // the synchronous path can take over.
  if FModules <> nil then
    for var M in FModules do
      M.PrefetchInFlight := False;
end;

end.
