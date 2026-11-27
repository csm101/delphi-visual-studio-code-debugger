unit LineProbes;

// Which line records of which modules carry a one-shot probe, kept by MODULE
// NAME so that it outlives every mapping (docs/DAP_DEBUGGER_ARCHITECTURE.md,
// "Code patches", "When a module's probes go in").
//
// The engine (ICodePatchTarget, CodePatchMap.pas) writes a probe on an address
// it is given and knows nothing about lines, verdicts or module names. The
// routine analysis (TLiveCodeAnalysis) knows which line records are instruction
// boundaries and nothing about probes. This unit sits between the two:
//
//   * a REQUEST names a module and either a set of module-relative addresses
//     or "every line record of the module"; it stays in force until it is
//     withdrawn, across unloads and loads of the module;
//   * only records the analysis CONFIRMS are handed to the engine. That is
//     stricter than the rule for a breakpoint, which is refused only where the
//     analysis shows something else;
//   * a module is armed at the first moment its code can be analysed and
//     before any of it has run after that moment: at the request for a module
//     that is loaded, at its load event for one that loads later, at its entry
//     point for a fixed-base image the loader had to move (its absolute
//     addresses are only right from there on), and at a paced retry when its
//     debug information was not ready at either;
//   * results are read by module name and survive the process.
//
// Who chooses the addresses (a scope, a coverage collection) is not here, nor
// is a store: this is the in-memory mechanism those are built on.
//
// The unit knows neither the session nor the engine class: the engine comes
// through a callback that answers nil when there is none, modules through a
// lookup by name. Every method runs on the thread that pumps the debug events.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  CodePatchMap, LiveCodeAnalysis;

type
  /// <summary>One request for line probes in one module.</summary>
  TLineProbeRequest = record
    /// <summary>The module, as the session's module list names it: the file
    /// name, whatever the case; the main executable by its own file name.</summary>
    ModuleName: string;
    /// <summary>Module-relative addresses of line records. Ignored with
    /// <c>WholeModule</c>.</summary>
    Rvas: TArray<Cardinal>;
    /// <summary>True for every line record of the module.</summary>
    WholeModule: Boolean;
    /// <summary>Must be True for a process attached to with killOnDetach
    /// false (see <c>TCodePatchArmRequest</c>).</summary>
    AcceptBreakpointBytesLeftBehindIfTheDebuggerDies: Boolean;
  end;

  /// <summary>Where a request stands for the current mapping of its module.</summary>
  TLineProbeState = (
    /// <summary>The module is not loaded (or there is no process): the request
    /// waits for its load event.</summary>
    lpsNotLoaded,
    /// <summary>The module is loaded and cannot be analysed yet: its image is
    /// not known to be relocated, or its debug information is not ready. The
    /// request waits for the entry point or a retry.</summary>
    lpsWaitingForAnalysis,
    /// <summary>The probes are in.</summary>
    lpsArmed,
    /// <summary>The engine refused the request as a whole.</summary>
    lpsRefused
  );

  /// <summary>What became of a request.</summary>
  TLineProbeReport = record
    /// <summary>The module.</summary>
    ModuleName: string;
    /// <summary>Where the request stands.</summary>
    State: TLineProbeState;
    /// <summary>Why it waits or was refused; empty when armed.</summary>
    Note: string;
    /// <summary>The moment the current mapping was armed: "the request", "its
    /// load event", "its entry point", "the load event of another module", "a
    /// retry".</summary>
    ArmedAt: string;
    /// <summary>Load address of the mapping that was armed; 0 when none is.</summary>
    ModuleBase: UInt64;
    /// <summary>How many mappings of the module have been armed so far.</summary>
    Loads: Integer;
    /// <summary>Armed while the module's second routine provider (x86: the MAP
    /// that names the bodies of anonymous methods) was still indexing: the
    /// records only it confirms carry no probe yet. They are armed by a retry
    /// once it is ready.</summary>
    Partial: Boolean;
    /// <summary>What the analysis said about the records asked for.</summary>
    Tally: TConfirmedLineTally;
    /// <summary>What the engine did with the confirmed ones.</summary>
    Outcome: TCodePatchArmOutcome;
  end;

  /// <summary>The engine of the live process, or nil when there is none.</summary>
  TLineProbeEngine = reference to function: ICodePatchTarget;

  /// <summary>Finds a loaded module by name and makes sure its debug
  /// information is loaded.</summary>
  /// <param name="ModuleName">File name of the module, any case.</param>
  /// <param name="Base">Its load address.</param>
  /// <returns>False when no module of that name is loaded.</returns>
  TLineProbeModuleLookup = reference to function(const ModuleName: string; out Base: UInt64): Boolean;

  /// <summary>Diagnostic sink.</summary>
  /// <param name="Text">One line.</param>
  TLineProbeLog = reference to procedure(const Text: string);

  /// <summary>The standing requests for line probes of one debug session, and
  /// their results.</summary>
  TLineProbeHost = class
  private type
    TStanding = class
      Key:        string;      // lower-case module name
      Request:    TLineProbeRequest;
      Report:     TLineProbeReport;
      ArmedBase:  UInt64;      // the mapping the request is armed in; 0 = none
      Stale:      Boolean;     // the request changed since it was armed
    end;
  private
    FAnalysis: TLiveCodeAnalysis;
    FEngine:   TLineProbeEngine;
    FLookup:   TLineProbeModuleLookup;
    FLog:      TLineProbeLog;
    FStanding: TObjectList<TStanding>;
    // Results taken from an engine that has gone away, by key.
    FKept:     TDictionary<string, TArray<Cardinal>>;
    // Every key a request was ever made under: a withdrawn request leaves its
    // results behind, and they are taken over from the engine like the others.
    FKeys:     TList<string>;
    function  Find(const ModuleName: string): TStanding;
    function  IsWaiting(Standing: TStanding): Boolean;
    procedure TryArm(Standing: TStanding; const AtWhat: string);
    procedure ArmWhatIsDue(const LoadedModule: string; RelocatedBase: UInt64; OnlyWaiting: Boolean;
      const Otherwise: string);
    procedure Log(const Text: string);
  public
    /// <summary>Creates a host with no request.</summary>
    /// <param name="Analysis">The session's code analysis. Not owned.</param>
    /// <param name="Engine">The engine of the live process, or nil.</param>
    /// <param name="Lookup">Finds a loaded module by name.</param>
    /// <exception cref="EArgumentNilException">An argument is nil.</exception>
    constructor Create(Analysis: TLiveCodeAnalysis; const Engine: TLineProbeEngine;
      const Lookup: TLineProbeModuleLookup);
    destructor Destroy; override;
    /// <summary>Asks for line probes in a module. A second request for the
    /// same module adds to the first.</summary>
    /// <remarks>Armed at once when the module is loaded and can be analysed;
    /// otherwise the request stands and is armed at the module's load event,
    /// at its entry point, or at a retry (see the unit header).</remarks>
    /// <param name="Request">Module and addresses.</param>
    /// <param name="Report">Where the request stands now.</param>
    /// <returns>False when the engine refused the request as a whole; the
    /// request does not stand then.</returns>
    function Arm(const Request: TLineProbeRequest; out Report: TLineProbeReport): Boolean;
    /// <summary>Withdraws the request for a module and takes its armed probes
    /// away; what they recorded stays.</summary>
    /// <param name="ModuleName">The module; empty for every module.</param>
    procedure Disarm(const ModuleName: string = '');
    /// <summary>The line records of a module recorded as executed.</summary>
    /// <param name="ModuleName">The module.</param>
    /// <returns>Module-relative addresses, ascending. Valid while the process
    /// runs and after it has ended.</returns>
    function Hits(const ModuleName: string): TArray<Cardinal>;
    /// <summary>Where the request for a module stands.</summary>
    /// <param name="ModuleName">The module.</param>
    /// <param name="Report">The report.</param>
    /// <returns>False when there is no request for that module.</returns>
    function TryGetReport(const ModuleName: string; out Report: TLineProbeReport): Boolean;
    /// <summary>The engine's counters; zeroes without an engine.</summary>
    function Stats: TCodePatchStats;
    /// <summary>True while a request stands.</summary>
    function HasRequests: Boolean;
    /// <summary>True while a request waits for an analysis that was not
    /// possible yet, or is armed only in part (<c>TLineProbeReport.Partial</c>).</summary>
    function HasWaiting: Boolean;
    /// <summary>A module was mapped (its load event is being handled): every
    /// request that is due and can be armed now is armed, the one for that
    /// module first of all.</summary>
    /// <param name="ModuleName">The module that loaded.</param>
    procedure ModuleLoaded(const ModuleName: string);
    /// <summary>A module that was not relocated at its load event reached its
    /// entry point.</summary>
    /// <param name="Base">Its load address.</param>
    procedure ModuleRelocated(Base: UInt64);
    /// <summary>A module was unmapped: its request waits for the next load.</summary>
    /// <param name="ModuleName">The module.</param>
    procedure ModuleUnloaded(const ModuleName: string);
    /// <summary>Tries the requests that wait for an analysis again.</summary>
    procedure RetryWaiting;
    /// <summary>The process is gone: every request waits for a load again.</summary>
    procedure ProcessGone;
    /// <summary>The engine is about to be released: its results are taken
    /// over, so that they stay readable.</summary>
    /// <param name="Engine">The engine that is going away.</param>
    procedure EngineGoingAway(const Engine: ICodePatchTarget);
    /// <summary>A new process is about to start under this session: the
    /// results of the previous one are dropped, the requests stand.</summary>
    procedure NewProcess;
    /// <summary>Optional diagnostic sink.</summary>
    property OnLog: TLineProbeLog read FLog write FLog;
  end;

implementation

const
  AT_REQUEST      = 'the request';
  AT_LOAD_EVENT   = 'its load event';
  AT_ENTRY_POINT  = 'its entry point';
  AT_OTHER_LOAD   = 'the load event of another module';
  AT_OTHER_ENTRY  = 'the entry point of another module';
  AT_RETRY        = 'a retry';

{ TLineProbeHost }

constructor TLineProbeHost.Create(Analysis: TLiveCodeAnalysis; const Engine: TLineProbeEngine;
  const Lookup: TLineProbeModuleLookup);
begin
  inherited Create;
  if (Analysis = nil) or (not Assigned(Engine)) or (not Assigned(Lookup)) then
    raise EArgumentNilException.Create('TLineProbeHost.Create: an argument is missing');
  FAnalysis := Analysis;
  FEngine   := Engine;
  FLookup   := Lookup;
  FStanding := TObjectList<TStanding>.Create(True);
  FKept     := TDictionary<string, TArray<Cardinal>>.Create;
  FKeys     := TList<string>.Create;
end;

destructor TLineProbeHost.Destroy;
begin
  FKeys.Free;
  FKept.Free;
  FStanding.Free;
  inherited;
end;

procedure TLineProbeHost.Log(const Text: string);
begin
  if Assigned(FLog) then
    FLog(Text);
end;

function TLineProbeHost.Find(const ModuleName: string): TStanding;
begin
  var Key := LowerCase(ModuleName);
  for var Standing in FStanding do
    if Standing.Key = Key then
      Exit(Standing);
  Result := nil;
end;

function TLineProbeHost.HasRequests: Boolean;
begin
  Result := FStanding.Count > 0;
end;

function TLineProbeHost.HasWaiting: Boolean;
begin
  for var Standing in FStanding do
    if IsWaiting(Standing) then
      Exit(True);
  Result := False;
end;

function TLineProbeHost.IsWaiting(Standing: TStanding): Boolean;
begin
  Result := (Standing.Report.State = lpsWaitingForAnalysis) or
    ((Standing.Report.State = lpsArmed) and Standing.Report.Partial);
end;

procedure TLineProbeHost.TryArm(Standing: TStanding; const AtWhat: string);
begin
  var Target := FEngine();
  var Base: UInt64 := 0;
  if (Target = nil) or not FLookup(Standing.Request.ModuleName, Base) then begin
    Standing.ArmedBase         := 0;
    Standing.Report.State      := lpsNotLoaded;
    Standing.Report.ModuleBase := 0;
    Standing.Report.Partial    := False;
    Standing.Report.Note       := 'the module is not loaded; the request waits for its load event';
    Exit;
  end;
  // The engine no longer holds the mapping this request was armed in: it was
  // unloaded and the request was not told. What is at the address now is
  // another mapping, possibly of the same module at the same base, and it is
  // armed afresh. (An unload inside a synthetic call reaches the session at
  // the next turn of the main loop, so this is a guard, not the mechanism.)
  if (Standing.ArmedBase = Base) and not Target.ModuleIsArmed(Base) then
    Standing.ArmedBase := 0;
  // Nothing to do for a mapping that already carries exactly this request --
  // unless it was armed in part and what was missing can be analysed now.
  if (Standing.ArmedBase = Base) and not Standing.Stale then begin
    if not Standing.Report.Partial then
      Exit;
    if FAnalysis.SecondProviderPending(Base) then
      Exit;
  end;

  var Confirmed: TArray<Cardinal>;
  var Tally: TConfirmedLineTally;
  var WhyNot: string;
  if not FAnalysis.ConfirmedLineRecords(Base, Standing.Request.Rvas, Standing.Request.WholeModule,
       Confirmed, Tally, WhyNot) then begin
    Standing.Report.State      := lpsWaitingForAnalysis;
    Standing.Report.ModuleBase := Base;
    Standing.Report.Note       := WhyNot;
    Exit;
  end;

  var Request := Default(TCodePatchArmRequest);
  Request.ModuleBase := Base;
  Request.ResultKey  := Standing.Key;
  Request.Rvas       := Confirmed;
  Request.AcceptBreakpointBytesLeftBehindIfTheDebuggerDies :=
    Standing.Request.AcceptBreakpointBytesLeftBehindIfTheDebuggerDies;
  var Outcome: TCodePatchArmOutcome;
  var Refusal: string;
  if not Target.ArmOneShotProbes(Request, Outcome, Refusal) then begin
    Standing.Report.State      := lpsRefused;
    Standing.Report.ModuleBase := Base;
    Standing.Report.Note       := Refusal;
    Exit;
  end;
  if Standing.ArmedBase <> Base then
    Inc(Standing.Report.Loads);
  Standing.ArmedBase         := Base;
  Standing.Stale             := False;
  Standing.Report.State      := lpsArmed;
  Standing.Report.Note       := '';
  Standing.Report.ArmedAt    := AtWhat;
  Standing.Report.ModuleBase := Base;
  Standing.Report.Partial    := Tally.SecondProviderPending;
  Standing.Report.Tally      := Tally;
  Standing.Report.Outcome    := Outcome;
  if Tally.SecondProviderPending then
    Standing.Report.Note := 'armed without the bodies of anonymous methods: the MAP that names them is ' +
      'still being indexed, and they are armed when it is ready';
  Log(Format('line probes: %s at $%x armed at %s: %d record(s) asked, %d confirmed, %d armed ' +
    '(%d already hit, %d own int3) in %d write(s); analysis %.1f ms, arming %.1f ms',
    [Standing.Key, Base, AtWhat, Tally.Asked, Tally.Confirmed, Outcome.Armed, Outcome.AlreadyHit,
     Outcome.OwnBreakpointInstruction, Outcome.WriteCalls, Tally.Milliseconds, Outcome.Milliseconds]));
end;

function TLineProbeHost.Arm(const Request: TLineProbeRequest; out Report: TLineProbeReport): Boolean;
begin
  var Standing := Find(Request.ModuleName);
  var IsNew := Standing = nil;
  if IsNew then begin
    Standing := TStanding.Create;
    Standing.Key     := LowerCase(Request.ModuleName);
    Standing.Request := Request;
    Standing.Report  := Default(TLineProbeReport);
    Standing.Report.ModuleName := Request.ModuleName;
    FStanding.Add(Standing);
    if not FKeys.Contains(Standing.Key) then
      FKeys.Add(Standing.Key);
  end else begin
    Standing.Request.WholeModule := Standing.Request.WholeModule or Request.WholeModule;
    Standing.Request.Rvas        := Standing.Request.Rvas + Request.Rvas;
    Standing.Request.AcceptBreakpointBytesLeftBehindIfTheDebuggerDies :=
      Request.AcceptBreakpointBytesLeftBehindIfTheDebuggerDies;
    Standing.Stale := True;
  end;
  TryArm(Standing, AT_REQUEST);
  Report := Standing.Report;
  Result := Report.State <> lpsRefused;
  // A refused request does not stand: it would be refused again at every
  // module event, and silently.
  if (not Result) and IsNew then
    FStanding.Remove(Standing);
end;

procedure TLineProbeHost.Disarm(const ModuleName: string);
begin
  var Target := FEngine();
  for var I := FStanding.Count - 1 downto 0 do begin
    var Standing := FStanding[I];
    if (ModuleName <> '') and (Standing.Key <> LowerCase(ModuleName)) then
      Continue;
    if (Target <> nil) and (Standing.ArmedBase <> 0) then
      Target.DisarmProbes(Standing.ArmedBase);
    FStanding.Delete(I);
  end;
end;

function TLineProbeHost.Hits(const ModuleName: string): TArray<Cardinal>;
begin
  var Key := LowerCase(ModuleName);
  var Target := FEngine();
  if Target <> nil then
    Exit(Target.ProbeHits(Key));
  if not FKept.TryGetValue(Key, Result) then
    Result := nil;
end;

function TLineProbeHost.TryGetReport(const ModuleName: string; out Report: TLineProbeReport): Boolean;
begin
  Report := Default(TLineProbeReport);
  var Standing := Find(ModuleName);
  Result := Standing <> nil;
  if Result then
    Report := Standing.Report;
end;

function TLineProbeHost.Stats: TCodePatchStats;
begin
  Result := Default(TCodePatchStats);
  var Target := FEngine();
  if Target <> nil then
    Result := Target.CodePatchStats;
end;

procedure TLineProbeHost.ArmWhatIsDue(const LoadedModule: string; RelocatedBase: UInt64;
  OnlyWaiting: Boolean; const Otherwise: string);
// One pass over the requests. The one the event is ABOUT is labelled with the
// event; any other request that happens to be armable now (the main executable,
// asked for before the process existed, at the first module event) says so.
begin
  var LoadedKey := LowerCase(LoadedModule);
  for var Standing in FStanding do begin
    // A request the engine refused as a whole is refused again at every event
    // (the reason is the process, not the module), after an analysis of the
    // whole module each time. It waits for the caller to ask again.
    if Standing.Report.State = lpsRefused then
      Continue;
    if OnlyWaiting and not IsWaiting(Standing) then
      Continue;
    var AtWhat := Otherwise;
    if (LoadedKey <> '') and (Standing.Key = LoadedKey) then
      AtWhat := AT_LOAD_EVENT;
    if (RelocatedBase <> 0) and (Standing.Report.ModuleBase = RelocatedBase) then
      AtWhat := AT_ENTRY_POINT;
    TryArm(Standing, AtWhat);
  end;
end;

procedure TLineProbeHost.ModuleLoaded(const ModuleName: string);
begin
  ArmWhatIsDue(ModuleName, 0, False, AT_OTHER_LOAD);
end;

procedure TLineProbeHost.ModuleRelocated(Base: UInt64);
begin
  ArmWhatIsDue('', Base, False, AT_OTHER_ENTRY);
end;

procedure TLineProbeHost.RetryWaiting;
begin
  ArmWhatIsDue('', 0, True, AT_RETRY);
end;

procedure TLineProbeHost.ModuleUnloaded(const ModuleName: string);
begin
  var Standing := Find(ModuleName);
  if Standing = nil then
    Exit;
  Standing.ArmedBase         := 0;
  Standing.Report.State      := lpsNotLoaded;
  Standing.Report.ModuleBase := 0;
  Standing.Report.Partial    := False;
  Standing.Report.Note       := 'the module was unloaded; the request waits for its next load event';
end;

procedure TLineProbeHost.ProcessGone;
begin
  for var Standing in FStanding do begin
    Standing.ArmedBase         := 0;
    Standing.Report.State      := lpsNotLoaded;
    Standing.Report.ModuleBase := 0;
    Standing.Report.Partial    := False;
    Standing.Report.Note       := 'the process has ended';
  end;
end;

procedure TLineProbeHost.EngineGoingAway(const Engine: ICodePatchTarget);
begin
  if Engine = nil then
    Exit;
  for var Key in FKeys do
    FKept.AddOrSetValue(Key, Engine.ProbeHits(Key));
  ProcessGone;
end;

procedure TLineProbeHost.NewProcess;
begin
  FKept.Clear;
  for var Standing in FStanding do begin
    Standing.ArmedBase := 0;
    Standing.Report.Loads      := 0;
    Standing.Report.State      := lpsNotLoaded;
    Standing.Report.ModuleBase := 0;
    Standing.Report.Partial    := False;
    Standing.Report.Note       := 'the process has not started';
  end;
end;

end.
