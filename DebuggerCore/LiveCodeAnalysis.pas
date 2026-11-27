unit LiveCodeAnalysis;

// The code map and the routine analysis of the modules of a LIVE session, and
// the two answers the breakpoint path takes from them
// (docs/DAP_DEBUGGER_ARCHITECTURE.md, "Breakpoints"):
//
//   * may a user's source breakpoint be written at this address -- refused only
//     when the analysis SHOWS the address to be something else than the start
//     of an instruction (inside an instruction, inside a table, on data). An
//     address it could not confirm is planted: on x86 without a MAP the body of
//     an anonymous method is exactly that;
//   * where else was the code of this line emitted within the same routine --
//     on x64 a `finally` block exists inline and again as a funclet the
//     exception dispatch calls, and a breakpoint has to sit in both.
//
// Nothing is built until it is asked for, and then per module: the code map of
// a module on the first question about an address in it, and the analysis of a
// routine on the first question about an address in that routine. A verdict is
// kept for as long as the module stays loaded. A module's map and analyzer go
// when it unloads (ForgetModule) -- the loader maps, unmaps and maps again at
// the same address, so anything keyed by address must not survive an unload.
//
// What the first question about a large module costs is the code map, not the
// analysis: about 0.4 s and 90 MB for an image with 2.8 million line records,
// against a few milliseconds for the routine. It is paid on the calling thread.
//
// The unit knows no session and no engine class. Bytes come through a reader
// (the session passes IDebugTarget.ReadCodeMemoryAt, so the analysis sees the
// program's bytes under planted breakpoints) and modules through a lookup
// callback. That is also what makes it testable without a process.
//
// Thread safety: every entry point takes one lock. The analyzers themselves are
// single-threaded and never leave it.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

uses
  System.SysUtils, System.Generics.Collections, System.SyncObjs,
  DebugInfoTypes, DebugTarget, CodeMap, Disassembler, RoutineAnalysis;

type
  /// <summary>One loaded module, as the owner of the analysis describes it.</summary>
  TLiveModuleInfo = record
    /// <summary>Module name, for reports.</summary>
    Name: string;
    /// <summary>Address the module is loaded at.</summary>
    Base: UInt64;
    /// <summary>Its SizeOfImage; 0 when unknown.</summary>
    Size: UInt64;
    /// <summary>What the module's providers add to a module-relative RVA: 0
    /// for the main executable, <c>Base - exeImageBase</c> for a runtime
    /// module (<c>TModuleSymbolLoader.ModuleRvaRange</c>).</summary>
    RvaShift: UInt64;
    /// <summary>The module's loaded debug-information providers, most trusted
    /// first (TD32 or .tds, then MAP, then JDBG). Empty when none is loaded.</summary>
    Providers: TArray<IInterface>;
  end;

  /// <summary>Finds the loaded module that holds an address.</summary>
  /// <param name="VA">Any address.</param>
  /// <param name="Info">The module.</param>
  /// <returns>False when no known module holds the address.</returns>
  TLiveModuleLookup = reference to function(VA: UInt64; out Info: TLiveModuleInfo): Boolean;

  /// <summary>Diagnostic sink.</summary>
  /// <param name="Text">One line.</param>
  TLiveAnalysisLog = reference to procedure(const Text: string);

  /// <summary>What was built for one module, for reports and tests.</summary>
  TLiveModuleStats = record
    /// <summary>Module name.</summary>
    Name: string;
    /// <summary>Load address.</summary>
    Base: UInt64;
    /// <summary>True when the module's code is 64-bit.</summary>
    Is64: Boolean;
    /// <summary>Whether the decoder is loaded; False leaves every verdict to
    /// the caller's own fallback.</summary>
    DecoderAvailable: Boolean;
    /// <summary>Line records of the code map.</summary>
    LineCount: Integer;
    /// <summary>Routines of the code map.</summary>
    RoutineCount: Integer;
    /// <summary>Routines the code map took from a second routine provider.</summary>
    SecondProviderRoutineCount: Integer;
    /// <summary>Number of providers the module had when its code map was built.</summary>
    ProviderCount: Integer;
    /// <summary>Time the code map took to build, in milliseconds.</summary>
    MapBuildMs: Double;
    /// <summary>Time the analyzer took to set up, in milliseconds.</summary>
    AnalyzerSetupMs: Double;
    /// <summary>Addresses judged so far (each analysed its routine once).</summary>
    VerdictCount: Integer;
  end;

  /// <summary>What a sweep for the CONFIRMED line records of a module found
  /// (<c>TLiveCodeAnalysis.ConfirmedLineRecords</c>).</summary>
  TConfirmedLineTally = record
    /// <summary>Line records looked at: the addresses asked about, or every
    /// record of the module.</summary>
    Asked: Integer;
    /// <summary>Confirmed as the first byte of an instruction, and returned.</summary>
    Confirmed: Integer;
    /// <summary>Shown to be something else (inside an instruction, a table,
    /// data, a unit's final <c>end.</c>).</summary>
    NotCode: Integer;
    /// <summary>Neither confirmed nor refuted: not returned.</summary>
    Unconfirmed: Integer;
    /// <summary>Addresses asked about at which no line record starts.</summary>
    NotALineRecord: Integer;
    /// <summary>Confirmed, yet left out: a zero byte in a routine whose entry
    /// only a MAP names.</summary>
    ZeroByteInMapNamedRoutine: Integer;
    /// <summary>Routines analysed.</summary>
    RoutinesAnalysed: Integer;
    /// <summary>Of those, not analysed completely.</summary>
    RoutinesIncomplete: Integer;
    /// <summary>Time the sweep took, in milliseconds, the code map included
    /// when this call had to build it.</summary>
    Milliseconds: Double;
    /// <summary>x86: the module's second routine provider (a MAP, which
    /// names the bodies of anonymous methods) was still indexing. The answer
    /// is complete for everything else; those bodies are unconfirmed until it
    /// is ready (<c>TLiveCodeAnalysis.SecondProviderPending</c>).</summary>
    SecondProviderPending: Boolean;
  end;

  /// <summary>Code maps and routine analyzers of a live session's modules,
  /// built on demand.</summary>
  TLiveCodeAnalysis = class
  private type
    TModuleState = class
      Name:          string;
      Base:          UInt64;
      Size:          UInt64;
      Is64:          Boolean;
      // Nil when the module's providers cannot supply a code map (only .rsm or
      // .dcp, or none loaded yet): remembered, so that the question is not
      // worked out again for every breakpoint in such a module.
      Map:           TModuleCodeMap;
      Analyzer:      TRoutineAnalyzer;
      Verdicts:      TDictionary<Cardinal, TRoutineLine>;
      // The providers the map was built from, to notice that better ones
      // arrived (a module's TD32 is published after its MAP).
      ProviderKey:   string;
      ProviderCount: Integer;
      // A second routine provider exists but was still indexing when the map
      // was built: the map is rebuilt once it is ready.
      SecondPending: Boolean;
      MapBuildMs:    Double;
      SetupMs:       Double;
      destructor Destroy; override;
    end;
  private
    FLock:     TCriticalSection;
    FReader:   TDisasmByteReader;
    FLookup:   TLiveModuleLookup;
    FLog:      TLiveAnalysisLog;
    FModules:  TObjectList<TModuleState>;
    // Load addresses of modules that could not be analysed, or not in full,
    // for a reason that passes by itself: an image not relocated yet, a
    // provider whose index is still being built.
    FDeferred: TList<UInt64>;
    // Load addresses of modules the owner has SEEN relocated (MarkRelocated).
    FKnownRelocated: TList<UInt64>;
    FZydisDllPath: string;
    procedure Log(const Text: string);
    function  FindState(VA: UInt64): TModuleState;
    function  StateFor(VA: UInt64): TModuleState;
    function  BuildState(const Info: TLiveModuleInfo; const ProviderKey: string): TModuleState;
    function  ReadImageHeader(Base: UInt64; out Is64: Boolean; out HeaderBase: UInt64;
      out SizeOfImage: Cardinal): Boolean;
    function  Defer(Base: UInt64): Boolean;
    function  IsRelocated(Base, HeaderBase: UInt64): Boolean;
    function  IsIndexing(const Provider: IInterface): Boolean;
    function  WouldBeCompleteNow(const Info: TLiveModuleInfo): Boolean;
    function  VerdictOf(State: TModuleState; Rva: Cardinal): TRoutineLine;
    function  AnalyzeLocked(VA: UInt64; out Line: TRoutineLine; out State: TModuleState): Boolean;
    function  EntryIsUnproven(State: TModuleState; const Line: TRoutineLine): Boolean;
  public
    /// <summary>Creates an empty store.</summary>
    /// <param name="Reader">Reads the target's code by virtual address, with
    /// the program's own bytes where a breakpoint is planted.</param>
    /// <param name="Lookup">Finds the loaded module holding an address.</param>
    /// <exception cref="EArgumentNilException">A callback is nil.</exception>
    constructor Create(const Reader: TDisasmByteReader; const Lookup: TLiveModuleLookup);
    destructor Destroy; override;
    /// <summary>Whether a user's source breakpoint may be written at an address.</summary>
    /// <param name="VA">The address.</param>
    /// <param name="Reason">For <c>pvRefuse</c>: what the address is.</param>
    /// <returns><c>pvRefuse</c> when the analysis shows the address not to be
    /// the start of an instruction; <c>pvPlant</c> when it is one or nothing
    /// shows otherwise; <c>pvNoAnalysis</c> when there is no decoder, no code
    /// map for the module, or the module's image is not relocated yet.</returns>
    function JudgeAddress(VA: UInt64; out Reason: string): TPlantVerdict;
    /// <summary>The verdict of the analysis for an address, unreduced.</summary>
    /// <param name="VA">The address.</param>
    /// <param name="Line">The verdict, its reason and, for a line record, its
    /// first block.</param>
    /// <returns>False when the address is in no analysable module.</returns>
    function TryAnalyzeAddress(VA: UInt64; out Line: TRoutineLine): Boolean;
    /// <summary>The line records of a module that the routine analysis
    /// CONFIRMS as instruction boundaries: the only places a code patch may
    /// go. Stricter than <c>JudgeAddress</c>, which refuses a breakpoint only
    /// where the analysis shows something else.</summary>
    /// <remarks>Each routine is analysed once. Nothing is remembered per
    /// record (a module can have millions), so the sweep costs the same every
    /// time: about a second per million records.</remarks>
    /// <param name="ModuleBase">Load address of the module.</param>
    /// <param name="Wanted">Module-relative addresses to judge; ignored with
    /// <c>WholeModule</c>.</param>
    /// <param name="WholeModule">True for every line record of the module.</param>
    /// <param name="Confirmed">The confirmed ones, module-relative, ascending.</param>
    /// <param name="Tally">Counts by verdict.</param>
    /// <param name="WhyNot">When the result is False: why the module cannot be
    /// analysed now.</param>
    /// <returns>False when the module cannot be analysed NOW: it is not
    /// loaded, its image is not known to be relocated, a provider is still
    /// indexing, its debug information has no line records with routine
    /// ranges, or the decoder is missing. Nothing is confirmed then.</returns>
    function ConfirmedLineRecords(ModuleBase: UInt64; const Wanted: TArray<Cardinal>;
      WholeModule: Boolean; out Confirmed: TArray<Cardinal>; out Tally: TConfirmedLineTally;
      out WhyNot: string): Boolean;
    /// <summary>Whether the analysis of a module was built without its second
    /// routine provider because that one was still indexing, and still is.</summary>
    /// <remarks>Cheap: builds nothing. Once it answers False, the next
    /// <c>ConfirmedLineRecords</c> rebuilds the module's map with the provider
    /// and confirms what it adds.</remarks>
    /// <param name="ModuleBase">Load address of the module.</param>
    /// <returns>False when nothing was built for the module, or when it was
    /// built complete, or when the provider is ready now.</returns>
    function SecondProviderPending(ModuleBase: UInt64): Boolean;
    /// <summary>The copies of a source line's code within the same routine.</summary>
    /// <remarks>x64 only. <c>.pdata</c> divides a routine into its body and
    /// its funclets. For the line record at <c>VA</c>, each OTHER piece of the
    /// same routine that holds records of the same file and line contributes
    /// its lowest one. Records of the same piece are never copies of each
    /// other: the two records of a <c>for</c> line are the loop's entry and its
    /// back edge.</remarks>
    /// <param name="VA">Address of a line record.</param>
    /// <returns>The addresses, ascending; empty on x86, when no record starts
    /// at <c>VA</c>, and when nothing is known.</returns>
    function CopiesOf(VA: UInt64): TArray<UInt64>;
    /// <summary>Drops what was built for the module loaded at an address. To
    /// be called when its providers change; what is known about its relocation
    /// is kept.</summary>
    /// <param name="Base">The module's load address.</param>
    procedure ForgetModule(Base: UInt64);
    /// <summary>The module at an address has unloaded: everything about that
    /// address goes, since another mapping can take it.</summary>
    /// <param name="Base">The load address.</param>
    procedure ModuleUnloaded(Base: UInt64);
    /// <summary>Tells the analysis that the image at an address is relocated.</summary>
    /// <remarks>Needed for one kind of image only: one WITHOUT a dynamic base
    /// that could not be mapped at its preferred base. The loader relocates it
    /// after its load event, and its mapped header keeps saying the preferred
    /// base for ever after, so nothing read from the image tells "not yet"
    /// from "done". The owner knows: the engine watches such a module's entry
    /// point. Until this is called the module is not analysed.</remarks>
    /// <param name="Base">The module's load address.</param>
    procedure MarkRelocated(Base: UInt64);
    /// <summary>Drops everything.</summary>
    procedure Clear;
    /// <summary>Whether a module that could not be analysed before, or only in
    /// part, can be now: its image has been relocated, or the index of one of
    /// its providers is ready.</summary>
    /// <remarks>Nothing is built by asking. A module is reported once; the
    /// caller is expected to have the breakpoints judged again, since the
    /// verdicts and the copies it got for that module were those of the
    /// fallback.</remarks>
    /// <returns>True when at least one such module became analysable since
    /// the last call.</returns>
    function TakeModulesThatBecameReady: Boolean;
    /// <summary>Number of modules still waiting for that.</summary>
    function DeferredCount: Integer;
    /// <summary>What has been built so far.</summary>
    /// <returns>One entry per module with a code map.</returns>
    function Stats: TArray<TLiveModuleStats>;
    /// <summary>Text of a verdict reason as a user is told it.</summary>
    /// <param name="Reason">A reason of the "not code" verdict.</param>
    /// <returns>One clause of English.</returns>
    class function RefusalText(Reason: TLineVerdictReason): string; static;
    /// <summary>Optional diagnostic sink.</summary>
    property OnLog: TLiveAnalysisLog read FLog write FLog;
    /// <summary>Where Zydis.dll is; empty uses the normal search order. Set
    /// before the first question.</summary>
    property ZydisDllPath: string read FZydisDllPath write FZydisDllPath;
  end;

implementation

uses
  System.Diagnostics;

const
  PE_HEADER_PROBE = $400;

{ TLiveCodeAnalysis.TModuleState }

destructor TLiveCodeAnalysis.TModuleState.Destroy;
begin
  Verdicts.Free;
  Analyzer.Free;
  Map.Free;
  inherited;
end;

{ TLiveCodeAnalysis }

constructor TLiveCodeAnalysis.Create(const Reader: TDisasmByteReader;
  const Lookup: TLiveModuleLookup);
begin
  inherited Create;
  if not Assigned(Reader) then
    raise EArgumentNilException.Create('TLiveCodeAnalysis.Create: no byte reader');
  if not Assigned(Lookup) then
    raise EArgumentNilException.Create('TLiveCodeAnalysis.Create: no module lookup');
  FReader  := Reader;
  FLookup  := Lookup;
  FLock    := TCriticalSection.Create;
  FModules := TObjectList<TModuleState>.Create(True);
  FDeferred := TList<UInt64>.Create;
  FKnownRelocated := TList<UInt64>.Create;
end;

destructor TLiveCodeAnalysis.Destroy;
begin
  FKnownRelocated.Free;
  FDeferred.Free;
  FModules.Free;
  FLock.Free;
  inherited;
end;

procedure TLiveCodeAnalysis.Log(const Text: string);
begin
  if Assigned(FLog) then
    FLog(Text);
end;

class function TLiveCodeAnalysis.RefusalText(Reason: TLineVerdictReason): string;
begin
  case Reason of
    lvrInsideInstruction:
      Result := 'it is inside an instruction, not at the start of one';
    lvrInJumpTable:
      Result := 'it holds data, not code (it is inside a jump table)';
    lvrInClauseTable:
      Result := 'it holds data, not code (it is inside an exception clause table)';
    lvrZeroByte:
      Result := 'it holds data, not code (no instruction leads there and the byte is $00; ' +
                'typically the final "end." of a unit)';
    lvrUndecodable:
      Result := 'it holds data, not code (no instruction leads there and the bytes are not an instruction)';
    lvrFinalEndOfUnit:
      Result := 'it holds data, not code (it is the last line of its file and outside every routine: ' +
                'the unit''s final "end.", which has no code)';
  else
    Result := LineVerdictReasonText(Reason);
  end;
end;

function TLiveCodeAnalysis.ReadImageHeader(Base: UInt64; out Is64: Boolean;
  out HeaderBase: UInt64; out SizeOfImage: Cardinal): Boolean;
// The three header fields the analysis needs, read from the MAPPED image.
var
  Head: array[0..PE_HEADER_PROBE - 1] of Byte;
begin
  Is64        := False;
  HeaderBase  := 0;
  SizeOfImage := 0;
  var Got := FReader(Base, @Head[0], SizeOf(Head));
  if Got < $40 then
    Exit(False);
  if (Head[0] <> Ord('M')) or (Head[1] <> Ord('Z')) then
    Exit(False);
  var PeOfs := PCardinal(@Head[$3C])^;
  // Signature (4), file header (20), then the optional header up to and
  // including SizeOfImage at +56.
  if UInt64(PeOfs) + 24 + 60 > UInt64(Got) then
    Exit(False);
  if PCardinal(@Head[PeOfs])^ <> $00004550 then
    Exit(False);
  var Optional := PeOfs + 24;
  case PWord(@Head[Optional])^ of
    $010B: begin
      Is64       := False;
      HeaderBase := PCardinal(@Head[Optional + 28])^;
    end;
    $020B: begin
      Is64       := True;
      HeaderBase := PUInt64(@Head[Optional + 24])^;
    end;
  else
    Exit(False);
  end;
  SizeOfImage := PCardinal(@Head[Optional + 56])^;
  Result := True;
end;

function TLiveCodeAnalysis.Defer(Base: UInt64): Boolean;
// True the first time: for a log line that is not repeated at every question.
begin
  Result := not FDeferred.Contains(Base);
  if Result then
    FDeferred.Add(Base);
end;

function TLiveCodeAnalysis.IsRelocated(Base, HeaderBase: UInt64): Boolean;
// An image with a dynamic base is relocated when it is mapped, and its mapped
// header says the address it is at. A fixed-base image mapped where it asked
// to be needs no relocation, and says the same. That leaves a fixed-base image
// that had to move: the loader relocates it after its load event and before
// its entry point, and does NOT rewrite the header -- the field keeps the
// preferred base for as long as the module stays (measured at the entry point
// and at later stops, both bitnesses). For that one the owner has to say so.
begin
  Result := (HeaderBase = Base) or FKnownRelocated.Contains(Base);
end;

function TLiveCodeAnalysis.IsIndexing(const Provider: IInterface): Boolean;
begin
  var Background: IBackgroundIndexProvider;
  Result := (Provider <> nil) and Supports(Provider, IBackgroundIndexProvider, Background) and
            Background.BackgroundIndexingPending;
end;

function TLiveCodeAnalysis.WouldBeCompleteNow(const Info: TLiveModuleInfo): Boolean;
// What BuildState checks before it builds, without building: the image is
// relocated and no provider it would use is still indexing.
begin
  var Is64: Boolean;
  var HeaderBase: UInt64;
  var SizeOfImage: Cardinal;
  if not ReadImageHeader(Info.Base, Is64, HeaderBase, SizeOfImage) then
    Exit(False);
  if not IsRelocated(Info.Base, HeaderBase) then
    Exit(False);
  var LineProvider: ILineRecordProvider;
  var RoutineProvider: IRoutineRangeProvider;
  if not TModuleCodeMap.PickProviders(Info.Providers, LineProvider, RoutineProvider) then
    Exit(True);   // nothing to wait for: it has no usable provider at all
  if IsIndexing(LineProvider) or IsIndexing(RoutineProvider) then
    Exit(False);
  if (not Is64) and IsIndexing(TModuleCodeMap.PickSecondRoutineProvider(Info.Providers, RoutineProvider)) then
    Exit(False);
  Result := True;
end;

function TLiveCodeAnalysis.TakeModulesThatBecameReady: Boolean;
begin
  Result := False;
  FLock.Enter;
  try
    for var I := FDeferred.Count - 1 downto 0 do begin
      var Base := FDeferred[I];
      var Info: TLiveModuleInfo;
      // Gone, or another module at that address: nothing is owed to it.
      if (not FLookup(Base, Info)) or (Info.Base <> Base) then begin
        FDeferred.Delete(I);
        Continue;
      end;
      if not WouldBeCompleteNow(Info) then
        Continue;
      FDeferred.Delete(I);
      // Whatever was kept for it was built without the part that is ready now.
      for var K := FModules.Count - 1 downto 0 do
        if FModules[K].Base = Base then
          FModules.Delete(K);
      Log(Format('code analysis: %s at $%x can be analysed in full now', [Info.Name, Base]));
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.DeferredCount: Integer;
begin
  FLock.Enter;
  try
    Result := FDeferred.Count;
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.FindState(VA: UInt64): TModuleState;
begin
  for var State in FModules do
    if (VA >= State.Base) and (VA - State.Base < State.Size) then
      Exit(State);
  Result := nil;
end;

function TLiveCodeAnalysis.BuildState(const Info: TLiveModuleInfo;
  const ProviderKey: string): TModuleState;
begin
  Result := nil;
  var Is64: Boolean;
  var HeaderBase: UInt64;
  var SizeOfImage: Cardinal;
  if not ReadImageHeader(Info.Base, Is64, HeaderBase, SizeOfImage) then begin
    Log(Format('code analysis: %s at $%x has no readable PE header', [Info.Name, Info.Base]));
    Exit;
  end;
  // A fixed-base image that had to move is relocated AFTER its load event and
  // before its entry point; until then the absolute addresses in its code
  // still assume the preferred base. Such an image is not analysed and not
  // remembered until its owner has seen it relocated (IsRelocated).
  if not IsRelocated(Info.Base, HeaderBase) then begin
    if Defer(Info.Base) then
      Log(Format('code analysis: %s at $%x is not known to be relocated (header base $%x), not analysed',
        [Info.Name, Info.Base, HeaderBase]));
    Exit;
  end;

  var Size := Info.Size;
  if Size = 0 then
    Size := SizeOfImage;
  Result := TModuleState.Create;
  Result.Name        := Info.Name;
  Result.Base        := Info.Base;
  Result.Size        := Size;
  Result.Is64        := Is64;
  Result.ProviderKey := ProviderKey;
  Result.ProviderCount := Length(Info.Providers);

  var LineProvider: ILineRecordProvider;
  var RoutineProvider: IRoutineRangeProvider;
  if not TModuleCodeMap.PickProviders(Info.Providers, LineProvider, RoutineProvider) then begin
    Log(Format('code analysis: %s has no provider of line records and routine ranges', [Info.Name]));
    Exit;
  end;
  // NEVER wait for an index, the primary provider's any more than the second
  // one's: a MAP asked for its tables while its background indexer runs waits
  // up to fifteen seconds for it, and this is the thread that dispatches debug
  // events. A module whose only provider is such a MAP is not analysed now and
  // nothing is kept for it; the next question finds the index ready or does
  // not wait either.
  if IsIndexing(LineProvider) or IsIndexing(RoutineProvider) then begin
    if Defer(Info.Base) then
      Log(Format('code analysis: %s: a provider is still indexing, not analysed now', [Info.Name]));
    FreeAndNil(Result);
    Exit;
  end;
  // A second routine provider matters on x86 only: there nothing but a MAP
  // names the body of an anonymous method. On x64 .pdata gives its entry.
  var Second: IRoutineRangeProvider := nil;
  var SecondPending := False;
  if not Is64 then begin
    Second := TModuleCodeMap.PickSecondRoutineProvider(Info.Providers, RoutineProvider);
    // Never wait for an index that is still building: the map is built
    // without it now and once more when it is ready.
    if IsIndexing(Second) then begin
      Second := nil;
      SecondPending := True;
      Defer(Info.Base);
    end;
  end;

  try
    Result.SecondPending := SecondPending;
    Result.Verdicts      := TDictionary<Cardinal, TRoutineLine>.Create;
    Result.Map := TModuleCodeMap.Build(Info.Name, LineProvider, RoutineProvider,
      Info.RvaShift, Size, nil, Second);
    Result.MapBuildMs := Result.Map.BuildMs;
    // A table a provider could not enumerate in full is not a code map: a
    // record missing from it reads as "outside every routine", a routine
    // missing from it as a gap. Such a map is not used. The state is kept
    // WITHOUT it (the providers are not indexing, so asking again would give
    // the same), which the next change of the module's providers undoes.
    if not Result.Map.Complete then begin
      Log(Format('code analysis: %s: the providers could not enumerate everything (lines %s, routines %s), ' +
        'not analysed', [Info.Name, BoolToStr(Result.Map.LinesComplete, True),
        BoolToStr(Result.Map.RoutinesComplete, True)]));
      FreeAndNil(Result.Map);
      FreeAndNil(Result.Verdicts);
      Exit;
    end;

    var Clock := TStopwatch.StartNew;
    var Input := Default(TRoutineAnalysisInput);
    if Is64 then
      Input.Mode := dmmLong64
    else
      Input.Mode := dmmLegacy32;
    Input.Reader       := FReader;
    Input.ImageBase    := Info.Base;
    Input.CodeMap      := Result.Map;
    Input.ZydisDllPath := FZydisDllPath;
    Result.Analyzer := TRoutineAnalyzer.Create(Input);
    Result.SetupMs  := Clock.Elapsed.TotalMilliseconds;
  except
    Result.Free;
    raise;
  end;
  Log(Format('code analysis: %s at $%x: %d line records, %d routines (%d from a second provider), ' +
    'map %.0f ms, analyzer %.0f ms, decoder %s',
    [Info.Name, Info.Base, Length(Result.Map.Lines), Length(Result.Map.Routines),
     Result.Map.SecondProviderRoutineCount, Result.MapBuildMs, Result.SetupMs,
     BoolToStr(Result.Analyzer.Available, True)]));
end;

function TLiveCodeAnalysis.StateFor(VA: UInt64): TModuleState;
// The module's state, built or rebuilt when needed. Called for an address that
// has no remembered verdict, so the lookup below is not on the path of a
// breakpoint that is merely re-armed.
begin
  var Info: TLiveModuleInfo;
  if not FLookup(VA, Info) then
    Exit(nil);
  var Key := '';
  for var Provider in Info.Providers do
    Key := Key + IntToHex(NativeUInt(Pointer(Provider)), 1) + ';';

  Result := FindState(VA);
  if Result <> nil then begin
    var Stale := (Result.Base <> Info.Base) or (Result.ProviderKey <> Key);
    if (not Stale) and Result.SecondPending then begin
      var Line: ILineRecordProvider;
      var First: IRoutineRangeProvider;
      var Background: IBackgroundIndexProvider;
      if TModuleCodeMap.PickProviders(Info.Providers, Line, First) then begin
        var Second := TModuleCodeMap.PickSecondRoutineProvider(Info.Providers, First);
        Stale := (Second <> nil) and not (Supports(Second, IBackgroundIndexProvider, Background) and
          Background.BackgroundIndexingPending);
      end;
    end;
    if not Stale then
      Exit;
    FModules.Remove(Result);
  end;
  Result := BuildState(Info, Key);
  if Result <> nil then
    FModules.Add(Result);
end;

function TLiveCodeAnalysis.VerdictOf(State: TModuleState; Rva: Cardinal): TRoutineLine;
begin
  if State.Verdicts.TryGetValue(Rva, Result) then
    Exit;
  Result := State.Analyzer.AnalyzeAddress(Rva);
  // "Unreadable" can be a passing state (a page not committed yet).
  if Result.Reason <> lvrUnreadable then
    State.Verdicts.AddOrSetValue(Rva, Result);
end;

function TLiveCodeAnalysis.AnalyzeLocked(VA: UInt64; out Line: TRoutineLine;
  out State: TModuleState): Boolean;
begin
  Line := Default(TRoutineLine);
  // A remembered verdict first: this is the whole cost of re-arming a
  // breakpoint, and it needs neither the lookup nor the analyzer.
  // (Not while a second routine provider is still awaited: the verdict of
  // a record it would have given a routine to is worth working out again.)
  State := FindState(VA);
  if (State <> nil) and (State.Map <> nil) and (not State.SecondPending) and
     State.Verdicts.TryGetValue(Cardinal(VA - State.Base), Line) then
    Exit(True);
  State := StateFor(VA);
  if (State = nil) or (State.Map = nil) then
    Exit(False);
  Line := VerdictOf(State, Cardinal(VA - State.Base));
  Result := True;
end;

function TLiveCodeAnalysis.TryAnalyzeAddress(VA: UInt64; out Line: TRoutineLine): Boolean;
begin
  FLock.Enter;
  try
    var State: TModuleState;
    Result := AnalyzeLocked(VA, Line, State);
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.EntryIsUnproven(State: TModuleState; const Line: TRoutineLine): Boolean;
// True when the routine the verdict was worked out in is known from a second
// routine provider only: its entry is a name in a MAP, which nothing in the
// binary proves to be code.
begin
  var Routine := State.Map.FindRoutine(Line.Rva);
  Result := (Routine >= 0) and State.Map.Routines[Routine].FromSecondProvider;
end;

function TLiveCodeAnalysis.JudgeAddress(VA: UInt64; out Reason: string): TPlantVerdict;
begin
  Reason := '';
  FLock.Enter;
  try
    var Line: TRoutineLine;
    var State: TModuleState;
    if not AnalyzeLocked(VA, Line, State) then
      Exit(pvNoAnalysis);
    // Without a decoder, or without the bytes, nothing was analysed: the
    // caller's own test decides.
    if Line.Reason in [lvrDecoderUnavailable, lvrUnreadable] then
      Exit(pvNoAnalysis);
    if Line.Verdict = lvNotCode then begin
      Reason := RefusalText(Line.Reason);
      Exit(pvRefuse);
    end;
    // A floor under the one place where the proof is weakest. A decode that
    // started at an entry only a MAP names can run through data and "arrive"
    // anywhere; there the rule of 0.9.3 still holds on its own: no statement
    // starts with $00.
    if EntryIsUnproven(State, Line) then begin
      var FirstByte: Byte := $FF;
      if (FReader(VA, @FirstByte, 1) = 1) and (FirstByte = 0) then begin
        Reason := 'it holds data, not code (the byte is $00, and the only routine start that leads ' +
                  'there is one a MAP names)';
        Exit(pvRefuse);
      end;
    end;
    Result := pvPlant;
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.ConfirmedLineRecords(ModuleBase: UInt64;
  const Wanted: TArray<Cardinal>; WholeModule: Boolean; out Confirmed: TArray<Cardinal>;
  out Tally: TConfirmedLineTally; out WhyNot: string): Boolean;
var
  State: TModuleState;
  Found: TList<Cardinal>;
  LocalTally: TConfirmedLineTally;
  Judged: TArray<Boolean>;

  // A confirmed record is taken, with one floor: in a routine whose entry only
  // a MAP names, a decode can run through data and "arrive" anywhere, and the
  // rule that no statement starts with $00 still holds on its own there.
  procedure Judge(const Line: TRoutineLine);
  begin
    if (Line.LineIndex >= 0) and (Line.LineIndex < Length(Judged)) then begin
      if Judged[Line.LineIndex] then
        Exit;
      Judged[Line.LineIndex] := True;
    end;
    case Line.Verdict of
      lvNotCode: begin
        Inc(LocalTally.NotCode);
        Exit;
      end;
      lvUnconfirmed: begin
        Inc(LocalTally.Unconfirmed);
        Exit;
      end;
    end;
    if EntryIsUnproven(State, Line) then begin
      var FirstByte: Byte := $FF;
      if (FReader(State.Base + Line.Rva, @FirstByte, 1) = 1) and (FirstByte = 0) then begin
        Inc(LocalTally.ZeroByteInMapNamedRoutine);
        Exit;
      end;
    end;
    Inc(LocalTally.Confirmed);
    Found.Add(Line.Rva);
  end;

  procedure Count(const Analysis: TRoutineAnalysis);
  begin
    Inc(LocalTally.RoutinesAnalysed);
    if not Analysis.Complete then
      Inc(LocalTally.RoutinesIncomplete);
  end;

  procedure SweepTheModule;
  begin
    var Map := State.Map;
    LocalTally.Asked := Length(Map.Lines);
    SetLength(Judged, Length(Map.Lines));
    for var R := 0 to High(Map.Routines) do begin
      if Map.Routines[R].LineCount = 0 then
        Continue;
      var Analysis := State.Analyzer.Analyze(R);
      Count(Analysis);
      for var Line in Analysis.Lines do
        Judge(Line);
    end;
    // x64: the bodies of anonymous methods, which only .pdata knows.
    for var U := 0 to High(State.Analyzer.UnmappedFunctions) do begin
      var Analysis := State.Analyzer.AnalyzeUnmapped(U);
      Count(Analysis);
      for var Line in Analysis.Lines do
        Judge(Line);
    end;
    // What neither kind of routine holds: judged one by one (never confirmed,
    // since nothing proves an entry there; some are shown not to be code).
    for var I := 0 to High(Judged) do
      if not Judged[I] then
        Judge(State.Analyzer.AnalyzeLine(I));
  end;

  procedure JudgeTheWanted;
  begin
    var Map := State.Map;
    var Sorted := Copy(Wanted);
    TArray.Sort<Cardinal>(Sorted);
    var LastRoutine := -1;
    var Analysis := Default(TRoutineAnalysis);
    for var I := 0 to High(Sorted) do begin
      if (I > 0) and (Sorted[I] = Sorted[I - 1]) then
        Continue;
      var LineIndex := Map.FindLine(Sorted[I]);
      if LineIndex < 0 then begin
        Inc(LocalTally.NotALineRecord);
        Continue;
      end;
      Inc(LocalTally.Asked);
      var Routine := Map.Lines[LineIndex].RoutineIndex;
      if Routine < 0 then begin
        Judge(State.Analyzer.AnalyzeLine(LineIndex));
        Continue;
      end;
      // Sorted addresses: the records of one routine come together, and the
      // routine is analysed once for all of them.
      if Routine <> LastRoutine then begin
        Analysis := State.Analyzer.Analyze(Routine);
        Count(Analysis);
        LastRoutine := Routine;
      end;
      var InRoutine := Analysis.FindLine(Sorted[I]);
      if InRoutine < 0 then begin
        Inc(LocalTally.Unconfirmed);
        Continue;
      end;
      Judge(Analysis.Lines[InRoutine]);
    end;
  end;

begin
  Confirmed := nil;
  Tally  := Default(TConfirmedLineTally);
  WhyNot := '';
  LocalTally := Default(TConfirmedLineTally);
  var Clock := TStopwatch.StartNew;
  FLock.Enter;
  try
    State := StateFor(ModuleBase);
    if State = nil then begin
      if FDeferred.Contains(ModuleBase) then
        WhyNot := 'its image is not known to be relocated yet, or a provider of its line records is still indexing'
      else
        WhyNot := 'no module with a readable image is loaded at that address';
      Exit(False);
    end;
    if State.Base <> ModuleBase then begin
      WhyNot := 'that address is inside a module, not the start of one';
      Exit(False);
    end;
    if State.Map = nil then begin
      WhyNot := 'its debug information cannot supply line records together with routine ranges';
      Exit(False);
    end;
    if not State.Analyzer.Available then begin
      WhyNot := 'the decoder is not available: ' + State.Analyzer.StatusText;
      Exit(False);
    end;
    Found := TList<Cardinal>.Create;
    try
      if WholeModule then
        SweepTheModule
      else
        JudgeTheWanted;
      Found.Sort;
      // A record is judged in the one routine that holds it, so it cannot
      // come twice; the guard costs one pass and keeps the answer a set even
      // if a routine and a .pdata function ever overlapped.
      var Distinct := 0;
      SetLength(Confirmed, Found.Count);
      for var I := 0 to Found.Count - 1 do begin
        if (Distinct > 0) and (Confirmed[Distinct - 1] = Found[I]) then
          Continue;
        Confirmed[Distinct] := Found[I];
        Inc(Distinct);
      end;
      SetLength(Confirmed, Distinct);
    finally
      Found.Free;
    end;
    LocalTally.SecondProviderPending := State.SecondPending;
    LocalTally.Milliseconds := Clock.Elapsed.TotalMilliseconds;
    Tally := LocalTally;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.SecondProviderPending(ModuleBase: UInt64): Boolean;
begin
  FLock.Enter;
  try
    var State := FindState(ModuleBase);
    if (State = nil) or (State.Base <> ModuleBase) or not State.SecondPending then
      Exit(False);
    var Info: TLiveModuleInfo;
    if not FLookup(ModuleBase, Info) then
      Exit(False);
    var Line: ILineRecordProvider;
    var First: IRoutineRangeProvider;
    if not TModuleCodeMap.PickProviders(Info.Providers, Line, First) then
      Exit(False);
    Result := IsIndexing(TModuleCodeMap.PickSecondRoutineProvider(Info.Providers, First));
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.CopiesOf(VA: UInt64): TArray<UInt64>;
begin
  Result := nil;
  FLock.Enter;
  try
    var State := FindState(VA);
    if (State = nil) or (State.Map = nil) then
      State := StateFor(VA);
    if (State = nil) or (State.Map = nil) or (not State.Is64) or
       (not State.Analyzer.Available) then
      Exit;
    var Map := State.Map;
    var Rva := Cardinal(VA - State.Base);
    var LineIndex := Map.FindLine(Rva);
    if LineIndex < 0 then
      Exit;
    var Region, Root: Cardinal;
    if not State.Analyzer.CodeRegionOf(Rva, Region, Root) then
      Exit;
    var Lines := Map.Lines;
    // Pieces of the routine already served: the one the record itself is in,
    // then each piece a copy was taken from.
    var Served: TArray<Cardinal> := [Region];
    for var Sibling in Map.LinesAt(Lines[LineIndex].FileIndex, Lines[LineIndex].Line) do begin
      if Sibling = LineIndex then
        Continue;
      var SiblingRegion, SiblingRoot: Cardinal;
      if not State.Analyzer.CodeRegionOf(Lines[Sibling].Rva, SiblingRegion, SiblingRoot) then
        Continue;
      // Another routine holding the same line (a generic instantiated twice)
      // is not a copy of this one.
      if SiblingRoot <> Root then
        Continue;
      var Seen := False;
      for var Piece in Served do
        if Piece = SiblingRegion then
          Seen := True;
      if Seen then
        Continue;
      Served := Served + [SiblingRegion];
      Result := Result + [State.Base + Lines[Sibling].Rva];
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLiveCodeAnalysis.ForgetModule(Base: UInt64);
begin
  FLock.Enter;
  try
    for var I := FModules.Count - 1 downto 0 do
      if FModules[I].Base = Base then
        FModules.Delete(I);
  finally
    FLock.Leave;
  end;
end;

procedure TLiveCodeAnalysis.ModuleUnloaded(Base: UInt64);
begin
  FLock.Enter;
  try
    for var I := FModules.Count - 1 downto 0 do
      if FModules[I].Base = Base then
        FModules.Delete(I);
    FDeferred.Remove(Base);
    FKnownRelocated.Remove(Base);
  finally
    FLock.Leave;
  end;
end;

procedure TLiveCodeAnalysis.MarkRelocated(Base: UInt64);
begin
  FLock.Enter;
  try
    if not FKnownRelocated.Contains(Base) then
      FKnownRelocated.Add(Base);
  finally
    FLock.Leave;
  end;
end;

procedure TLiveCodeAnalysis.Clear;
begin
  FLock.Enter;
  try
    FModules.Clear;
    FDeferred.Clear;
    FKnownRelocated.Clear;
  finally
    FLock.Leave;
  end;
end;

function TLiveCodeAnalysis.Stats: TArray<TLiveModuleStats>;
begin
  FLock.Enter;
  try
    Result := nil;
    for var State in FModules do begin
      if State.Map = nil then
        Continue;
      var Item := Default(TLiveModuleStats);
      Item.Name             := State.Name;
      Item.Base             := State.Base;
      Item.Is64             := State.Is64;
      Item.DecoderAvailable := State.Analyzer.Available;
      Item.LineCount        := Length(State.Map.Lines);
      Item.RoutineCount     := Length(State.Map.Routines);
      Item.SecondProviderRoutineCount := State.Map.SecondProviderRoutineCount;
      Item.ProviderCount    := State.ProviderCount;
      Item.MapBuildMs       := State.MapBuildMs;
      Item.AnalyzerSetupMs  := State.SetupMs;
      Item.VerdictCount     := State.Verdicts.Count;
      Result := Result + [Item];
    end;
  finally
    FLock.Leave;
  end;
end;

end.
