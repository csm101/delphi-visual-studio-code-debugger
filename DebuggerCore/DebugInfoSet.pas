unit DebugInfoSet;

// Aggregates multiple debug-info providers (MAP, RSM, future PDB/DWARF) and
// exposes a single unified API. Each provider is queried in registration
// order; the first positive answer wins. Providers only need to implement the
// capabilities they support.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  DebugInfoTypes;

type
  // A local-symbol provider scoped to one binary's RVA range (a BPL/DLL).
  // Used to route the by-name locals fallback to the module that OWNS the
  // frame's RVA, so a same-named proc in ANOTHER binary's RSM/DCP cannot win
  // the cross-provider by-name merge (multi-binary collision).
  TRangedLocalProvider = record
    Prov: ILocalSymbolProvider;
    Lo, Hi: UInt64;   // [Lo, Hi) in the main-exe RVA space
  end;

  TRangedGlobalProvider = record
    Prov: IGlobalSymbolProvider;
    Lo, Hi: UInt64;   // [Lo, Hi) in the main-exe RVA space
    ModuleName: string;        // owning package base name (lowercase, no ext),
                               // '' for the main exe; used to match `Requires`.
    Requires: TArray<string>;  // package base names this binary requires
                               // (lowercase), from its PACKAGEINFO. Drives the
                               // uses-graph global tier in FindGlobalForRva.
  end;

  // Address->source-line / address->function resolution scoped to one binary's
  // RVA range. Without this, the flat first-hit iteration lets a provider that
  // does NOT own an RVA answer for it (clamping to its nearest line/function),
  // so on a multi-module target a step-over crossing into another module's code
  // gets the WRONG unit's line/function and stops on a phantom line. Mirrors
  // TRangedGlobalProvider for the Rva-> direction.
  TRangedLineProvider = record
    Prov: ISourceLineProvider;
    Lo, Hi: UInt64;
  end;

  TRangedFuncProvider = record
    Prov: IFunctionNameProvider;
    Lo, Hi: UInt64;
  end;

  TDebugInfoSet = class
  private
    FRevision:        UInt64;
    FRangedLocals:    TList<TRangedLocalProvider>;
    FRangedGlobals:   TList<TRangedGlobalProvider>;
    FRangedLine:      TList<TRangedLineProvider>;
    FRangedFunc:      TList<TRangedFuncProvider>;
    FLineProviders:   TList<ISourceLineProvider>;
    FFuncProviders:   TList<IFunctionNameProvider>;
    FLocalProviders:  TList<ILocalSymbolProvider>;
    FGlobalProviders: TList<IGlobalSymbolProvider>;
    FUsesProviders:   TList<IUnitUsesProvider>;
    FFuncScopeProviders: TList<IUnitScopedFuncProvider>;
    FConstProviders:  TList<IUnitScopedConstProvider>;
    FEnumProviders:   TList<IEnumInfoProvider>;
    FMemberProviders: TList<IClassMemberProvider>;
    FSigProviders:    TList<IMethodSignatureProvider>;
    FSizeProviders:   TList<ITypeSizeProvider>;
    FHierProviders:   TList<IClassHierarchyProvider>;
    FBgIndexProviders: TList<IBackgroundIndexProvider>;
    function IsSuspectMisTag(const T: string): Boolean;
    function IsBetterHint(const NewH, CurH: string): Boolean;
    // Source unit (basename, no path/ext) that owns Rva, or '' if unknown.
    function UnitNameForRva(Rva: UInt64): string;
    // If Prov can disambiguate by unit AND FallbackName collides across units,
    // return that unit's locals. Returns False (and leaves the caller's existing
    // by-name path untouched) for non-colliding names or providers that can't.
    function TryUnitScopedLocals(const Prov: ILocalSymbolProvider;
                const Name, UnitHint: string;
                out Locals: TArray<TLocalSymbol>): Boolean;
    // Global counterpart of TryUnitScopedLocals: if Prov can disambiguate a
    // global by unit AND Name collides across units, return UnitHint's global.
    function TryUnitScopedGlobal(const Prov: IGlobalSymbolProvider;
                const Name, UnitHint: string;
                out Global: TGlobalSymbol): Boolean;
    // Uses-graph tier: when the global is NOT in the frame's own binary, look
    // it up in the binaries the frame's binary `requires` (transitively, in
    // declared order), so a required package's global beats an unrelated
    // module's same-named global. Returns False if the frame binary has no
    // requires or none of them declare Name.
    function TryRequiresClosureGlobal(Rva: UInt64; const Name: string;
                out Global: TGlobalSymbol): Boolean;
  public
    constructor Create;
    destructor  Destroy; override;

    // Registration: pass in a concrete provider instance. The set holds an
    // interface reference; the caller does not need to free the provider.
    // Primary inserts the provider at the FRONT of the MEMBER, LOCAL and ENUM
    // lists (TD32's strengths), so it wins GetClassMembers / GetLocalsForFunction
    // / enum lookups while staying last for global / function lookups. Makes TD32
    // primary for types + locals + enums; RSM remains the FALLBACK for what TD32
    // lacks (notably program-main-block locals, which Delphi emits only in RSM).
    procedure AddProvider(const Provider: IInterface; Primary: Boolean = False);
    // Registers a provider AND its owning binary's RVA range so the by-name
    // locals fallback can prefer the binary that owns the frame's RVA. Pass the
    // range in main-exe RVA space ([Base-exeImageBase, +ImageSize)).
    procedure AddProviderForModule(const Provider: IInterface;
          RvaLo, RvaHi: UInt64; Primary: Boolean = False;
          const ModuleName: string = ''; const Requires: TArray<string> = nil);
    procedure RemoveProvider(const Provider: IInterface);

    // Unified queries -- each iterates providers in registration order.
    function  RvaToSourceLine(Rva: UInt64; out Loc: TSourceLocation): Boolean;
    function  SourceLineToRva(const FileName: string; Line: Integer;
                out Rva: UInt64): Boolean;
    // Every distinct RVA this (file, line) maps to across all providers. Line
    // keys are basename-based, so in a multi-module target more than one module
    // can own the same (file, line); a breakpoint must be planted at all of them.
    function  SourceLineToRvaCandidates(const FileName: string;
                Line: Integer): TArray<UInt64>;
    function  RvaToFunctionName(Rva: UInt64; out Name: string): Boolean;
    function  RvaToFunctionStart(Rva: UInt64; out FuncRva: UInt64): Boolean;
    function  NameToRva(const Name: string; out Rva: UInt64): Boolean;
    function  NameToRvaCandidates(const Name: string): TArray<UInt64>;
    // Like NameToRva but, when the name collides across units, picks the
    // candidate whose owning unit is visible from the frame at FrameRva (the
    // frame's own unit or a unit it `uses`). Falls back to NameToRva when there
    // is no collision or no uses data, so non-colliding names are unaffected.
    function  NameToRvaScoped(const Name: string; FrameRva: UInt64;
                out Rva: UInt64): Boolean;
    // The identifier-visibility scope at FrameRva: the frame's own unit plus the
    // units it directly `uses` (lowercased basenames). Delphi has no transitive
    // uses, so this is the exact, bounded set of units whose globals a bare
    // identifier there can name. Empty when the frame unit or the uses graph is
    // unknown (the caller then keeps the un-scoped fallback). Drives a bounded
    // symbol warm-up: load only these units' modules, not every loaded module.
    function  ScopeUnitsForFrame(FrameRva: UInt64): TArray<string>;
    // Resolves a class NAME to its VMT/TClass RVA, scoped to the frame's `uses`.
    // The Delphi MAP emits each class's VMT as the public `Unit..Class`, so a
    // per-unit-visible class reference is the in-scope unit's `Unit..ClassName`
    // (own unit shadows; among `uses`, last-wins -- mirrors NameToRvaScoped).
    function  TryResolveClassVmtScoped(const ClassName: string; FrameRva: UInt64;
                out Rva: UInt64): Boolean;
    // Resolves a named CONSTANT, scoped to the frame's `uses` (own unit shadows;
    // among uses, last-wins). Falls back to a flat any-unit lookup when no scoped
    // copy is visible, so a uniquely-named const still resolves. Untyped ordinal
    // consts are inlined (no symbol) -- value comes from the RSM `$25` records.
    function  TryResolveConstScoped(const Name: string; FrameRva: UInt64;
                out Value: Int64; out TypeHint: string): Boolean;
    function  GetEnclosingProcedure(const Inner: string;
                out Parent: string): Boolean;
    function  GetEnclosingProcedureByRva(InnerRva: UInt64;
                out Parent: string): Boolean;
    function  GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
                out ParentRva: UInt64): Boolean;
    function  GetLocalsForFunction(const FunctionName: string;
                out Locals: TArray<TLocalSymbol>): Boolean;
    function  GetLocalsForFunctionByRva(InnerRva: UInt64;
                const FallbackName: string;
                out Locals: TArray<TLocalSymbol>): Boolean;
    function  GetGlobalsForRva(Rva: UInt64): TArray<TGlobalSymbol>;
    function  FindGlobalForRva(Rva: UInt64; const Name: string;
          out Global: TGlobalSymbol): Boolean;
    function  GetGlobals: TArray<TGlobalSymbol>;
    function  FindGlobal(const Name: string; out Global: TGlobalSymbol): Boolean;
    function  LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
    function  LookupTypeKind(const TypeName: string): Byte;
    function  TryResolveEnumLiteral(const Name: string;
                out Ordinal: Integer; out EnumTypeName: string): Boolean;
    function  GetClassMembers(const ClassName: string;
                out Members: TArray<TClassMember>; PreferInstanceSize: Integer = 0): Boolean;
    // Declared parameters of a class method (first provider that resolves the
    // signature; TD32). Self is excluded from Params; HasSelf reports whether the
    // method takes one (so ABI slot 0 is Self, declared params start at slot 1).
    function  TryGetMethodParams(const ClassName, MethodName: string;
                out Params: TArray<TMethodParam>; out HasSelf: Boolean): Boolean;
    function  TryGetFreeFunctionParamCount(const FuncName: string;
                out Count: Integer): Boolean;
    function  GetTypeSize(const TypeName: string; out Size: Integer): Boolean;
    // Immediate parent (base) class name of ClassName, via the first hierarchy
    // provider that knows it (TD32). False when unknown / no base.
    function  GetParentClassName(const ClassName: string; out Parent: string): Boolean;
    function  Revision: UInt64;
    // True while any provider is still building its name index on a background
    // thread (MAP publics). A name miss may still resolve once it completes, so
    // callers can bound a retry by "something is still indexing" instead of a
    // blind fixed sleep.
    function  AnyBackgroundIndexingPending: Boolean;
    // Diagnostic: enumerates every (already-loaded) local-symbol provider's
    // proc name list. Used by the BP-callback failure log to figure out
    // why a function the MAP knows about can't be looked up via RSM.
    function  DiagAllProcNames: TArray<string>;
    function  SortedRvas: TArray<UInt64>;
  end;

implementation

uses
  DapProtocol;

constructor TDebugInfoSet.Create;
begin
  inherited;
  FRevision        := 0;
  FRangedLocals    := TList<TRangedLocalProvider>.Create;
  FRangedGlobals   := TList<TRangedGlobalProvider>.Create;
  FRangedLine      := TList<TRangedLineProvider>.Create;
  FRangedFunc      := TList<TRangedFuncProvider>.Create;
  FLineProviders   := TList<ISourceLineProvider>.Create;
  FFuncProviders   := TList<IFunctionNameProvider>.Create;
  FLocalProviders  := TList<ILocalSymbolProvider>.Create;
  FGlobalProviders := TList<IGlobalSymbolProvider>.Create;
  FUsesProviders   := TList<IUnitUsesProvider>.Create;
  FFuncScopeProviders := TList<IUnitScopedFuncProvider>.Create;
  FConstProviders  := TList<IUnitScopedConstProvider>.Create;
  FEnumProviders   := TList<IEnumInfoProvider>.Create;
  FMemberProviders := TList<IClassMemberProvider>.Create;
  FSigProviders    := TList<IMethodSignatureProvider>.Create;
  FSizeProviders   := TList<ITypeSizeProvider>.Create;
  FHierProviders   := TList<IClassHierarchyProvider>.Create;
  FBgIndexProviders := TList<IBackgroundIndexProvider>.Create;
end;

destructor TDebugInfoSet.Destroy;
begin
  FRangedLocals.Free;
  FRangedGlobals.Free;
  FRangedLine.Free;
  FRangedFunc.Free;
  FLineProviders.Free;
  FFuncProviders.Free;
  FLocalProviders.Free;
  FGlobalProviders.Free;
  FUsesProviders.Free;
  FFuncScopeProviders.Free;
  FConstProviders.Free;
  FEnumProviders.Free;
  FMemberProviders.Free;
  FSigProviders.Free;
  FSizeProviders.Free;
  FHierProviders.Free;
  FBgIndexProviders.Free;
  inherited;
end;

procedure TDebugInfoSet.AddProvider(const Provider: IInterface; Primary: Boolean);
var
  LineP:   ISourceLineProvider;
  FuncP:   IFunctionNameProvider;
  LocalP:  ILocalSymbolProvider;
  GlobalP: IGlobalSymbolProvider;
  EnumP:   IEnumInfoProvider;
  MemberP: IClassMemberProvider;
  SizeP:   ITypeSizeProvider;
  HierP:   IClassHierarchyProvider;
begin
  if Supports(Provider, ISourceLineProvider, LineP) then
    FLineProviders.Add(LineP);
  if Supports(Provider, IClassHierarchyProvider, HierP) then
    if Primary then FHierProviders.Insert(0, HierP) else FHierProviders.Add(HierP);
  if Supports(Provider, IFunctionNameProvider, FuncP) then
    FFuncProviders.Add(FuncP);
  // Primary fronts the MEMBER, LOCAL and ENUM lists (TD32's strengths: correct
  // member types+offsets, proc/method locals, enum metadata). Global / func /
  // line lists stay appended so the existing RSM-first semantics there are
  // untouched; RSM thus acts as the FALLBACK for what TD32 lacks -- notably
  // program-main-block locals, which Delphi emits only in RSM (TD32 returns
  // empty for that frame -> RSM answers).
  if Supports(Provider, ILocalSymbolProvider, LocalP) then
    if Primary then
      FLocalProviders.Insert(0, LocalP)
    else
      FLocalProviders.Add(LocalP);
  if Supports(Provider, IGlobalSymbolProvider, GlobalP) then
    FGlobalProviders.Add(GlobalP);
  var UsesP: IUnitUsesProvider;
  if Supports(Provider, IUnitUsesProvider, UsesP) then
    FUsesProviders.Add(UsesP);
  var FuncScopeP: IUnitScopedFuncProvider;
  if Supports(Provider, IUnitScopedFuncProvider, FuncScopeP) then
    FFuncScopeProviders.Add(FuncScopeP);
  var ConstP: IUnitScopedConstProvider;
  if Supports(Provider, IUnitScopedConstProvider, ConstP) then
    FConstProviders.Add(ConstP);
  if Supports(Provider, IEnumInfoProvider, EnumP) then
    if Primary then
      FEnumProviders.Insert(0, EnumP)
    else
      FEnumProviders.Add(EnumP);
  if Supports(Provider, IClassMemberProvider, MemberP) then
    if Primary then
      FMemberProviders.Insert(0, MemberP)
    else
      FMemberProviders.Add(MemberP);
  var SigP: IMethodSignatureProvider;
  if Supports(Provider, IMethodSignatureProvider, SigP) then
    if Primary then
      FSigProviders.Insert(0, SigP)
    else
      FSigProviders.Add(SigP);
  if Supports(Provider, ITypeSizeProvider, SizeP) then
    FSizeProviders.Add(SizeP);
  var BgIdxP: IBackgroundIndexProvider;
  if Supports(Provider, IBackgroundIndexProvider, BgIdxP) then
    FBgIndexProviders.Add(BgIdxP);
  Inc(FRevision);
end;

procedure TDebugInfoSet.AddProviderForModule(const Provider: IInterface;
  RvaLo, RvaHi: UInt64; Primary: Boolean = False;
  const ModuleName: string = ''; const Requires: TArray<string> = nil);
var
  LocalP: ILocalSymbolProvider;
  GlobalP: IGlobalSymbolProvider;
begin
  AddProvider(Provider, Primary);
  if (RvaHi > RvaLo) and Supports(Provider, ILocalSymbolProvider, LocalP) then begin
    var R: TRangedLocalProvider;
    R.Prov := LocalP;
    R.Lo   := RvaLo;
    R.Hi   := RvaHi;
    FRangedLocals.Add(R);
  end;
  if (RvaHi > RvaLo) and Supports(Provider, IGlobalSymbolProvider, GlobalP) then begin
    var G: TRangedGlobalProvider;
    G.Prov       := GlobalP;
    G.Lo         := RvaLo;
    G.Hi         := RvaHi;
    G.ModuleName := LowerCase(ModuleName);
    G.Requires   := Requires;
    FRangedGlobals.Add(G);
  end;
  var LineP: ISourceLineProvider;
  if (RvaHi > RvaLo) and Supports(Provider, ISourceLineProvider, LineP) then begin
    var L: TRangedLineProvider;
    L.Prov := LineP;
    L.Lo   := RvaLo;
    L.Hi   := RvaHi;
    FRangedLine.Add(L);
  end;
  var FuncP: IFunctionNameProvider;
  if (RvaHi > RvaLo) and Supports(Provider, IFunctionNameProvider, FuncP) then begin
    var F: TRangedFuncProvider;
    F.Prov := FuncP;
    F.Lo   := RvaLo;
    F.Hi   := RvaHi;
    FRangedFunc.Add(F);
  end;
end;

procedure TDebugInfoSet.RemoveProvider(const Provider: IInterface);
var
  LineP:   ISourceLineProvider;
  FuncP:   IFunctionNameProvider;
  LocalP:  ILocalSymbolProvider;
  GlobalP: IGlobalSymbolProvider;
  EnumP:   IEnumInfoProvider;
  MemberP: IClassMemberProvider;
  SizeP:   ITypeSizeProvider;
  HierP:   IClassHierarchyProvider;
begin
  if Supports(Provider, IClassHierarchyProvider, HierP) then
    FHierProviders.Remove(HierP);
  if Supports(Provider, ISourceLineProvider, LineP) then begin
    FLineProviders.Remove(LineP);
    for var I := FRangedLine.Count - 1 downto 0 do
      if FRangedLine[I].Prov = LineP then
        FRangedLine.Delete(I);
  end;
  if Supports(Provider, IFunctionNameProvider, FuncP) then begin
    FFuncProviders.Remove(FuncP);
    for var I := FRangedFunc.Count - 1 downto 0 do
      if FRangedFunc[I].Prov = FuncP then
        FRangedFunc.Delete(I);
  end;
  if Supports(Provider, ILocalSymbolProvider, LocalP) then begin
    FLocalProviders.Remove(LocalP);
    for var I := FRangedLocals.Count - 1 downto 0 do
      if FRangedLocals[I].Prov = LocalP then
        FRangedLocals.Delete(I);
  end;
  if Supports(Provider, IGlobalSymbolProvider, GlobalP) then
    FGlobalProviders.Remove(GlobalP);
  if Supports(Provider, IGlobalSymbolProvider, GlobalP) then
    for var I := FRangedGlobals.Count - 1 downto 0 do
      if FRangedGlobals[I].Prov = GlobalP then
        FRangedGlobals.Delete(I);
  var UsesP: IUnitUsesProvider;
  if Supports(Provider, IUnitUsesProvider, UsesP) then
    FUsesProviders.Remove(UsesP);
  var FuncScopeP: IUnitScopedFuncProvider;
  if Supports(Provider, IUnitScopedFuncProvider, FuncScopeP) then
    FFuncScopeProviders.Remove(FuncScopeP);
  var ConstP: IUnitScopedConstProvider;
  if Supports(Provider, IUnitScopedConstProvider, ConstP) then
    FConstProviders.Remove(ConstP);
  if Supports(Provider, IEnumInfoProvider, EnumP) then
    FEnumProviders.Remove(EnumP);
  if Supports(Provider, IClassMemberProvider, MemberP) then
    FMemberProviders.Remove(MemberP);
  var SigP: IMethodSignatureProvider;
  if Supports(Provider, IMethodSignatureProvider, SigP) then
    FSigProviders.Remove(SigP);
  if Supports(Provider, ITypeSizeProvider, SizeP) then
    FSizeProviders.Remove(SizeP);
  var BgIdxP: IBackgroundIndexProvider;
  if Supports(Provider, IBackgroundIndexProvider, BgIdxP) then
    FBgIndexProviders.Remove(BgIdxP);
  Inc(FRevision);
end;

function TDebugInfoSet.AnyBackgroundIndexingPending: Boolean;
begin
  for var P in FBgIndexProviders do
    if P.BackgroundIndexingPending then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.Revision: UInt64;
begin
  Result := FRevision;
end;

function TDebugInfoSet.RvaToSourceLine(Rva: UInt64;
  out Loc: TSourceLocation): Boolean;
begin
  // Per-binary scoping: only the provider(s) whose RVA range OWNS Rva may
  // answer, so a different module cannot clamp Rva to its own nearest line.
  // When some binary owns Rva but has no line there, return False -- do NOT
  // fall through to the flat list, which could let another module clamp. The
  // flat fallback runs only when NO ranged provider owns Rva (e.g. a provider
  // registered without a range).
  var Owned := False;
  for var RG in FRangedLine do
    if (Rva >= RG.Lo) and (Rva < RG.Hi) then begin
      Owned := True;
      if RG.Prov.RvaToSourceLine(Rva, Loc) then
        Exit(True);
    end;
  if Owned then
    Exit(False);
  for var P in FLineProviders do
    if P.RvaToSourceLine(Rva, Loc) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.SourceLineToRva(const FileName: string; Line: Integer;
  out Rva: UInt64): Boolean;
begin
  for var P in FLineProviders do
    if P.SourceLineToRva(FileName, Line, Rva) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.SourceLineToRvaCandidates(const FileName: string;
  Line: Integer): TArray<UInt64>;
// EVERY distinct address this (file, line) maps to, across all providers.
// Line keys are BASENAME-based (TD32 NAMES carries no directory), so in a
// multi-module target two different files sharing a basename -- or one unit
// linked into both the host exe and a package -- both answer. Taking only the
// first provider's hit bound a breakpoint to the WRONG module's copy while still
// reporting it verified: it then either never fired, or stopped in the other file
// while the UI highlighted the user's. Planting every candidate makes the
// verified flag honest and stops wherever that line actually runs.
begin
  Result := nil;
  for var P in FLineProviders do begin
    var R: UInt64;
    if not P.SourceLineToRva(FileName, Line, R) then
      Continue;
    var Dup := False;
    for var Existing in Result do
      if Existing = R then begin Dup := True; Break; end;
    if not Dup then
      Result := Result + [R];
  end;
end;

function TDebugInfoSet.RvaToFunctionName(Rva: UInt64;
  out Name: string): Boolean;
begin
  var Owned := False;
  for var RG in FRangedFunc do
    if (Rva >= RG.Lo) and (Rva < RG.Hi) then begin
      Owned := True;
      if RG.Prov.RvaToFunctionName(Rva, Name) then
        Exit(True);
    end;
  if Owned then
    Exit(False);
  for var P in FFuncProviders do
    if P.RvaToFunctionName(Rva, Name) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.RvaToFunctionStart(Rva: UInt64;
  out FuncRva: UInt64): Boolean;
begin
  // Per-binary scoping (see RvaToSourceLine): a wrong-module clamp here makes
  // step-over believe a callee in another module is still the step function and
  // stop on a phantom line. Only the owning binary may answer.
  var Owned := False;
  for var RG in FRangedFunc do
    if (Rva >= RG.Lo) and (Rva < RG.Hi) then begin
      Owned := True;
      if RG.Prov.RvaToFunctionStart(Rva, FuncRva) then
        Exit(True);
    end;
  if Owned then
    Exit(False);
  for var P in FFuncProviders do
    if P.RvaToFunctionStart(Rva, FuncRva) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.NameToRva(const Name: string; out Rva: UInt64): Boolean;
begin
  for var P in FFuncProviders do
    if P.NameToRva(Name, Rva) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.NameToRvaCandidates(const Name: string): TArray<UInt64>;
begin
  SetLength(Result, 0);
  for var P in FFuncProviders do begin
    var Rva: UInt64;
    if not P.NameToRva(Name, Rva) then
      Continue;
    var Seen := False;
    for var Existing in Result do
      if Existing = Rva then begin
        Seen := True;
        Break;
      end;
    if not Seen then
      Result := Result + [Rva];
  end;
end;

function TDebugInfoSet.ScopeUnitsForFrame(FrameRva: UInt64): TArray<string>;
begin
  SetLength(Result, 0);
  var FrameUnit := LowerCase(UnitNameForRva(FrameRva));
  if FrameUnit = '' then
    Exit;
  Result := [FrameUnit];
  for var U in FUsesProviders do begin
    var ProvUses: TArray<string>;
    if U.GetUnitUses(FrameUnit, ProvUses) then
      for var Used in ProvUses do
        Result := Result + [LowerCase(Used)];
  end;
end;

function TDebugInfoSet.NameToRvaScoped(const Name: string; FrameRva: UInt64;
  out Rva: UInt64): Boolean;

  // The RVA window of the module the frame executes in (from the ranged function
  // providers). Unit scoping alone is not enough in a multi-BPL target: the SAME
  // unit can be linked into the host exe AND a package, so `FindFuncRvaInUnit`
  // can answer from the wrong binary's copy -- the watch then calls/reads a
  // different module's function or global and returns a valid but wrong value.
  function InFrameModule(Candidate: UInt64): Boolean;
  begin
    Result := False;
    for var F in FRangedFunc do
      if (FrameRva >= F.Lo) and (FrameRva < F.Hi) then
        Exit((Candidate >= F.Lo) and (Candidate < F.Hi));
  end;

  // True when the frame sits in a module whose window we know (otherwise there is
  // nothing to prefer and the plain first-hit order stands).
  function FrameModuleKnown: Boolean;
  begin
    Result := False;
    for var F in FRangedFunc do
      if (FrameRva >= F.Lo) and (FrameRva < F.Hi) then
        Exit(True);
  end;

begin
  Rva := 0;
  var FrameUnit := LowerCase(UnitNameForRva(FrameRva));
  // No scoping possible (no frame unit / no unit-scoped func provider): first-hit.
  if (FrameUnit = '') or (FFuncScopeProviders.Count = 0) then
    Exit(NameToRva(Name, Rva));
  var ScopeToModule := FrameModuleKnown;

  // The frame's OWN unit shadows everything it uses: if the proc is declared in
  // the frame unit, that copy wins outright. Prefer the copy in the frame's OWN
  // module first, so a unit linked into several binaries resolves locally.
  if ScopeToModule then
    for var P in FFuncScopeProviders do begin
      var RLocal: UInt64;
      if P.FindFuncRvaInUnit(Name, FrameUnit, RLocal) and InFrameModule(RLocal) then begin
        Rva := RLocal;
        Exit(True);
      end;
    end;
  for var P in FFuncScopeProviders do
    if P.FindFuncRvaInUnit(Name, FrameUnit, Rva) then
      Exit(True);

  // Otherwise the units the frame `uses` (in recorded order). The compiler
  // already dropped shadowed/unused units from the uses cluster, so usually one
  // unit declares Name; if several do, the LAST one wins (Delphi uses last-wins,
  // approximated by recorded order).
  var FrameUses: TArray<string>;
  for var U in FUsesProviders do begin
    var ProvUses: TArray<string>;
    if U.GetUnitUses(FrameUnit, ProvUses) then
      FrameUses := FrameUses + ProvUses;
  end;
  var Best: UInt64 := 0;
  var Found := False;
  // Track an in-frame-module candidate separately: a used unit linked into both
  // the host exe and a package must resolve to the copy in the frame's binary.
  var BestLocal: UInt64 := 0;
  var FoundLocal := False;
  for var UsedUnit in FrameUses do
    for var P in FFuncScopeProviders do begin
      var R: UInt64;
      if P.FindFuncRvaInUnit(Name, UsedUnit, R) then begin
        Best := R;
        Found := True;
        if ScopeToModule and InFrameModule(R) then begin
          BestLocal  := R;
          FoundLocal := True;
        end;
      end;
    end;
  if FoundLocal then begin
    Rva := BestLocal;
    Exit(True);
  end;
  if Found then begin
    Rva := Best;
    Exit(True);
  end;
  // No visible per-unit copy -> don't break resolution; fall back to first-hit.
  Result := NameToRva(Name, Rva);
end;

function TDebugInfoSet.TryResolveClassVmtScoped(const ClassName: string;
  FrameRva: UInt64; out Rva: UInt64): Boolean;

  // Delphi MAP names a class VMT `Unit..Class` (double dot: the empty segment
  // before the class name marks the VMT public).
  function VmtName(const UnitName: string): string;
  begin
    Result := UnitName + '..' + ClassName;
  end;

begin
  Rva := 0;
  var FrameUnit := LowerCase(UnitNameForRva(FrameRva));
  if FrameUnit = '' then
    Exit(False);
  // The frame's own unit shadows everything it uses.
  if NameToRva(VmtName(FrameUnit), Rva) then
    Exit(True);
  // Otherwise the units the frame `uses`, last-wins on a collision.
  var FrameUses: TArray<string>;
  for var U in FUsesProviders do begin
    var ProvUses: TArray<string>;
    if U.GetUnitUses(FrameUnit, ProvUses) then
      FrameUses := FrameUses + ProvUses;
  end;
  var Best: UInt64 := 0;
  var Found := False;
  for var UsedUnit in FrameUses do begin
    var R: UInt64;
    if NameToRva(VmtName(UsedUnit), R) then begin
      Best := R;
      Found := True;
    end;
  end;
  if Found then begin
    Rva := Best;
    Exit(True);
  end;
  Result := False;
end;

function TDebugInfoSet.TryResolveConstScoped(const Name: string; FrameRva: UInt64;
  out Value: Int64; out TypeHint: string): Boolean;
begin
  Value := 0;
  TypeHint := '';
  if FConstProviders.Count = 0 then Exit(False);

  var FrameUnit := LowerCase(UnitNameForRva(FrameRva));
  if FrameUnit <> '' then begin
    // Own unit shadows everything it uses.
    for var P in FConstProviders do
      if P.FindConstInUnit(Name, FrameUnit, Value, TypeHint) then
        Exit(True);
    // Units the frame `uses`, last-wins on a collision.
    var FrameUses: TArray<string>;
    for var U in FUsesProviders do begin
      var ProvUses: TArray<string>;
      if U.GetUnitUses(FrameUnit, ProvUses) then
        FrameUses := FrameUses + ProvUses;
    end;
    var BestVal: Int64 := 0;
    var BestType := '';
    var Found := False;
    for var UsedUnit in FrameUses do
      for var P in FConstProviders do begin
        var V: Int64;
        var TH: string;
        if P.FindConstInUnit(Name, UsedUnit, V, TH) then begin
          BestVal := V;
          BestType := TH;
          Found := True;
        end;
      end;
    if Found then begin
      Value := BestVal;
      TypeHint := BestType;
      Exit(True);
    end;
  end;

  // No visible per-unit copy -> flat any-unit lookup (uniquely-named const).
  for var P in FConstProviders do
    if P.FindConstInUnit(Name, '', Value, TypeHint) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.GetEnclosingProcedure(const Inner: string;
  out Parent: string): Boolean;
begin
  for var P in FFuncProviders do
    if P.GetEnclosingProcedure(Inner, Parent) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.GetEnclosingProcedureByRva(InnerRva: UInt64;
  out Parent: string): Boolean;
begin
  for var P in FFuncProviders do
    if P.GetEnclosingProcedureByRva(InnerRva, Parent) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.GetEnclosingProcedureRvaByRva(InnerRva: UInt64;
  out ParentRva: UInt64): Boolean;
begin
  for var P in FFuncProviders do
    if P.GetEnclosingProcedureRvaByRva(InnerRva, ParentRva) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.IsSuspectMisTag(const T: string): Boolean;
begin
  // Small-int primitive aliases -- often a placeholder for the real type
  // (enum, set, or wider integer).
  if SameText(T, 'SmallInt') or SameText(T, 'Word')     or
     SameText(T, 'Integer')  or SameText(T, 'Cardinal') or
     SameText(T, 'Byte')     or SameText(T, 'ShortInt') or
     SameText(T, 'LongInt')  or SameText(T, 'LongWord') or
     SameText(T, 'Int16')    or SameText(T, 'UInt16')   or
     SameText(T, 'Int32')    or SameText(T, 'UInt32') then
    Exit(True);
  // Pointer-shape hints are NOT marked suspect: `^Integer` may be a
  // genuine pointer-to-primitive local (in which case the test target's
  // `PI := @PRec.B` must dereference correctly), while a dynamic array
  // TD32 also emits as `^Element`. Without runtime metadata the two
  // shapes are indistinguishable, and an over-eager augment overwrite
  // turns `^Integer` into a wrong-scope set (`TInfoFlags`) in
  // RunTypeSampler. TD32 carries enough info to render the genuine
  // pointer; dynamic arrays now lose the RSM-side TArray<T> upgrade
  // path, which is accepted -- a TODO-RED test gates the regression.
  // Generic wrapper ancestors -- TD32 sometimes returns the parent class
  // (e.g. TNoRefCountObject) for a local declared as a descendant
  // (TCachedMenu). RSM by-name has the leaf class.
  if SameText(T, 'TObject')             or SameText(T, 'TPersistent') or
     SameText(T, 'TNoRefCountObject')   or SameText(T, 'TInterfacedObject') or
     SameText(T, 'TComponent') then
    Exit(True);
  Result := False;
end;

function IsStringFamilyType(const T: string): Boolean;
begin
  Result := SameText(T, 'string')        or SameText(T, 'UnicodeString') or
            SameText(T, 'AnsiString')    or SameText(T, 'WideString')    or
            SameText(T, 'RawByteString') or SameText(T, 'UTF8String')    or
            SameText(T, 'ShortString');
end;

// True when CurH is a bare 8-byte float primitive and NewH is one of the
// well-known RTL float aliases. TD32 flattens named float aliases to the
// underlying Double primitive (TypeId $41), losing the name; RSM keeps it.
// The alias has the same representation but carries date/time semantics the
// renderer needs, so it should win the merge. Single (4 bytes) is excluded:
// upgrading it to an 8-byte alias would be a size mismatch.
function IsFloatAliasUpgrade(const NewH, CurH: string): Boolean;
begin
  if not (SameText(CurH, 'Double') or SameText(CurH, 'Extended') or
          SameText(CurH, 'Real')) then
    Exit(False);
  Result := SameText(NewH, 'TDateTime') or SameText(NewH, 'TDate') or
            SameText(NewH, 'TTime');
end;

function TDebugInfoSet.IsBetterHint(const NewH, CurH: string): Boolean;
begin
  if NewH = '' then Exit(False);
  if CurH = '' then Exit(True);
  if SameText(NewH, CurH) then Exit(False);
  Result := (IsSuspectMisTag(CurH) and not IsSuspectMisTag(NewH)) or
            IsFloatAliasUpgrade(NewH, CurH);
end;

function TDebugInfoSet.UnitNameForRva(Rva: UInt64): string;
var
  Loc: TSourceLocation;
begin
  Result := '';
  if RvaToSourceLine(Rva, Loc) and (Loc.SourceFile <> '') then
    Result := ChangeFileExt(ExtractFileName(Loc.SourceFile), '');
end;

function TDebugInfoSet.TryUnitScopedLocals(const Prov: ILocalSymbolProvider;
  const Name, UnitHint: string; out Locals: TArray<TLocalSymbol>): Boolean;
var
  US: IUnitScopedLocalProvider;
begin
  Result := False;
  SetLength(Locals, 0);
  if not Supports(Prov, IUnitScopedLocalProvider, US) then Exit;
  if not US.NameCollidesAcrossUnits(Name) then Exit;
  Result := US.GetLocalsForFunctionInUnit(Name, UnitHint, Locals) and (Length(Locals) > 0);
  if Result then
    DapLog(Format('GetLocalsForFunctionByRva: unit-scoped "%s" in unit "%s" -> %d locals (cross-unit disambig)',
      [Name, UnitHint, Length(Locals)]));
end;

function TDebugInfoSet.GetLocalsForFunction(const FunctionName: string;
  out Locals: TArray<TLocalSymbol>): Boolean;
var
  Augment: TArray<TLocalSymbol>;
  FirstHit: Integer;
begin
  Result   := False;
  FirstHit := -1;
  for var I := 0 to FLocalProviders.Count - 1 do
    if FLocalProviders[I].GetLocalsForFunction(FunctionName, Locals) then begin
      Result   := True;
      FirstHit := I;
      Break;
    end;
  if not Result then Exit;
  DapLog(Format('GetLocalsForFunction "%s" firstHit=#%d localsCount=%d',
    [FunctionName, FirstHit, Length(Locals)]));
  for var Idx := 0 to High(Locals) do
    DapLog(Format('  [#%d] "%s" RbpOff=%d Hint="%s" Kind=%d UseDirect=%s TypeId=%d',
      [Idx, Locals[Idx].Name, Locals[Idx].RbpOffset, Locals[Idx].TypeHint,
       Ord(Locals[Idx].Kind),
       BoolToStr(Locals[Idx].UseDirectOffset, True), Locals[Idx].TypeId]));
  // Walk REMAINING providers; merge their per-name TypeHint where it
  // wins by IsBetterHint. Done in-place on Locals so callers see the
  // merged view.
  for var I := 0 to FLocalProviders.Count - 1 do begin
    if I = FirstHit then Continue;
    if not FLocalProviders[I].GetLocalsForFunction(FunctionName, Augment) then Continue;
    for var Idx := 0 to High(Locals) do
      for var A in Augment do
        if SameText(A.Name, Locals[Idx].Name) then begin
          if IsBetterHint(A.TypeHint, Locals[Idx].TypeHint) then
            Locals[Idx].TypeHint := A.TypeHint;
          Break;
        end;
  end;
end;

function TDebugInfoSet.GetLocalsForFunctionByRva(InnerRva: UInt64;
  const FallbackName: string;
  out Locals: TArray<TLocalSymbol>): Boolean;
var
  Augment:  TArray<TLocalSymbol>;
  FirstHit: Integer;
begin
  // Prefer the RVA-keyed lookup of the first provider that has it (TD32
  // populates its per-RVA locals index; RSM stubs to False). This disambiguates the
  // SampleApp multi-unit nested-CreateNodes case where the name-keyed lookup
  // surfaces locals from the wrong CreateNodes.
  Result   := False;
  FirstHit := -1;
  for var I := 0 to FLocalProviders.Count - 1 do
    if FLocalProviders[I].GetLocalsForFunctionByRva(InnerRva, Locals) then begin
      Result   := True;
      FirstHit := I;
      Break;
    end;
  if not Result then begin
    // No provider had it by RVA. Before the generic cross-provider by-name
    // lookup (which picks the FIRST provider with the name -- wrong when a
    // same-named proc exists in another binary's RSM/DCP), prefer the providers
    // of the BINARY that OWNS InnerRva. This routes the multi-binary by-name
    // fallback to the right module (RSM has no RVA index, so a same-named proc
    // in another BPL would otherwise win the merge).
    // Cross-unit, same-binary disambiguation. RSM's by-name index is last-wins,
    // so when a proc name is declared in more than one unit of a binary and TD32
    // lacks it by RVA, the plain by-name lookup can surface the WRONG unit's
    // locals. If the name collides, scope the lookup to the frame's source unit.
    // Gated by NameCollidesAcrossUnits (O(1)), so non-colliding names cost nothing.
    var UnitHint := UnitNameForRva(InnerRva);
    for var RL in FRangedLocals do
      if (InnerRva >= RL.Lo) and (InnerRva < RL.Hi) then begin
        if (UnitHint <> '') and
           TryUnitScopedLocals(RL.Prov, FallbackName, UnitHint, Locals) then
          Exit(True);
        if RL.Prov.GetLocalsForFunction(FallbackName, Locals) and
           (Length(Locals) > 0) then
          Exit(True);
      end;
    if UnitHint <> '' then
      for var I := 0 to FLocalProviders.Count - 1 do
        if TryUnitScopedLocals(FLocalProviders[I], FallbackName, UnitHint, Locals) then
          Exit(True);
    Result := GetLocalsForFunction(FallbackName, Locals);
    Exit;
  end;
  DapLog(Format('GetLocalsForFunctionByRva InnerRva=$%x FallbackName="%s" firstHit=#%d localsCount=%d (pre-merge)',
    [InnerRva, FallbackName, FirstHit, Length(Locals)]));
  for var Idx := 0 to High(Locals) do
    DapLog(Format('  pre [#%d] "%s" RbpOff=%d Hint="%s" TypeId=%d',
      [Idx, Locals[Idx].Name, Locals[Idx].RbpOffset,
       Locals[Idx].TypeHint, Locals[Idx].TypeId]));
  // Augment TypeHints from OTHER providers' name-keyed view. RSM/MAP
  // by-name lookups collide across units when nested procs share short
  // names (SampleApp: dozens of nested `CreateNodes`). For nested procs
  // (those with an enclosing parent), skip augment entirely -- the
  // RVA-correct result from TD32 is more trustworthy than a coin-flip
  // among identically-named nested procs. For top-level procs, augment
  // runs with the conservative rule below (override only when current
  // hint is "suspect").
  var ParentName: string;
  var IsNested := False;
  for var I := 0 to FFuncProviders.Count - 1 do
    if FFuncProviders[I].GetEnclosingProcedureByRva(InnerRva, ParentName) then begin
      IsNested := True;
      Break;
    end;
  if IsNested then begin
    DapLog(Format('  skip augment: InnerRva=$%x is nested under "%s" (collision risk on short-name augment)',
      [InnerRva, ParentName]));
    Exit;
  end;
  for var I := 0 to FLocalProviders.Count - 1 do begin
    if I = FirstHit then Continue;
    if not FLocalProviders[I].GetLocalsForFunction(FallbackName, Augment) then Continue;
    // Count duplicates per name in Augment. The compiler can emit a
    // pseudo-local with the user's name (e.g. a TVarRec temp inside an
    // `array of const` argument list) sharing the simple name of a real
    // local. The merge MUST NOT trust the augment hint when this happens
    // because we cannot tell which entry is the "real" local.
    var DupNames := TDictionary<string, Integer>.Create;
    try
      for var A in Augment do begin
        var Key := AnsiLowerCase(A.Name);
        var Count: Integer;
        if DupNames.TryGetValue(Key, Count) then
          DupNames[Key] := Count + 1
        else
          DupNames.Add(Key, 1);
      end;
      for var Idx := 0 to High(Locals) do
        for var A in Augment do
          if SameText(A.Name, Locals[Idx].Name) then begin
            var Cur := Locals[Idx].TypeHint;
            var DupCount: Integer;
            DupNames.TryGetValue(AnsiLowerCase(A.Name), DupCount);
            if DupCount > 1 then begin
              DapLog(Format('  merge SKIP "%s": augment has %d entries (ambiguous, provider #%d)',
                [Locals[Idx].Name, DupCount, I]));
              Break;
            end;
            if A.TypeHint = '' then
              // nothing to merge
            else if Cur = '' then
              Locals[Idx].TypeHint := A.TypeHint
            else if SameText(A.TypeHint, Cur) then
              // same -- skip
            else if SameText(A.TypeHint, 'TVarRec') then begin
              // Compiler-internal TVarRec emitted for `array of const` /
              // open-array argument boxing. RSM surfaces these under
              // their source-side name, polluting the augment view. NEVER
              // override a TD32 hint with a TVarRec augment.
              DapLog(Format('  merge KEEP "%s": "%s" (rejected TVarRec augment from #%d)',
                [Locals[Idx].Name, Cur, I]));
            end else if IsSuspectMisTag(Cur) and IsStringFamilyType(A.TypeHint) then begin
              // Augment claims a string type for a slot TD32 saw as a
              // primitive integer. Sizes don't line up (string=8-byte
              // pointer vs Integer=4 bytes / SmallInt=2 / Byte=1). The
              // augment is reaching a different scope -- reject.
              DapLog(Format('  merge KEEP "%s": "%s" (rejected string augment "%s" from #%d)',
                [Locals[Idx].Name, Cur, A.TypeHint, I]));
            end else if IsSuspectMisTag(Cur) and SameText(A.TypeHint, 'Currency') then begin
              // Same shape: Currency is an Int64 alias, never aliased to
              // narrower primitives. Reject.
              DapLog(Format('  merge KEEP "%s": "%s" (rejected Currency augment from #%d)',
                [Locals[Idx].Name, Cur, I]));
            end else if IsSuspectMisTag(Cur) and A.TypeHint.StartsWith('TArray', True) then begin
              // 8-byte dyn-array handle can never be the real type of a slot
              // TD32 sized as a 1/2/4-byte primitive. A genuine TArray<T>
              // local is typed `^Element` by TD32 (not a small-int), so
              // this only fires on a wrong-scope augment leak (SampleApp /
              // RunTypeSampler). Reject.
              DapLog(Format('  merge KEEP "%s": "%s" (rejected TArray augment "%s" from #%d)',
                [Locals[Idx].Name, Cur, A.TypeHint, I]));
            end else if IsSuspectMisTag(Cur) and not IsSuspectMisTag(A.TypeHint) then begin
              DapLog(Format('  merge override "%s": "%s" -> "%s" (Cur suspect, provider #%d)',
                [Locals[Idx].Name, Cur, A.TypeHint, I]));
              Locals[Idx].TypeHint := A.TypeHint;
            end else if A.TypeHint.StartsWith(Cur, True) and
                        ((Length(A.TypeHint) - Length(Cur)) in [1, 2]) then begin
              // Common Delphi pattern: TD32 reports the BASE enum (TFoo) for a
              // local whose declared type is the matching SET (TFoos / TFooes).
              // Lexical-stem match with 1-2 trailing chars upgrades it.
              DapLog(Format('  merge override "%s": "%s" -> "%s" (enum->set stem match, provider #%d)',
                [Locals[Idx].Name, Cur, A.TypeHint, I]));
              Locals[Idx].TypeHint := A.TypeHint;
            end else if IsFloatAliasUpgrade(A.TypeHint, Cur) then begin
              // TD32 flattens named float aliases (TDateTime/TDate/TTime) to the
              // bare Double primitive; RSM keeps the alias. Same 8-byte layout,
              // richer semantics -- upgrade so the renderer formats it as a date.
              DapLog(Format('  merge override "%s": "%s" -> "%s" (float alias upgrade, provider #%d)',
                [Locals[Idx].Name, Cur, A.TypeHint, I]));
              Locals[Idx].TypeHint := A.TypeHint;
            end else
              DapLog(Format('  merge KEEP "%s": "%s" (rejected augment "%s" from #%d)',
                [Locals[Idx].Name, Cur, A.TypeHint, I]));
            Break;
          end;
    finally
      DupNames.Free;
    end;
  end;
end;

function TDebugInfoSet.GetGlobals: TArray<TGlobalSymbol>;
begin
  SetLength(Result, 0);
  for var P in FGlobalProviders do
    Result := Result + P.GetGlobals;
end;

function TDebugInfoSet.GetGlobalsForRva(Rva: UInt64): TArray<TGlobalSymbol>;
begin
  SetLength(Result, 0);
  for var RG in FRangedGlobals do
    if (Rva >= RG.Lo) and (Rva < RG.Hi) then
      Result := Result + RG.Prov.GetGlobals;
  if Length(Result) > 0 then
    Exit;
  Result := GetGlobals;
end;

function TDebugInfoSet.TryUnitScopedGlobal(const Prov: IGlobalSymbolProvider;
  const Name, UnitHint: string; out Global: TGlobalSymbol): Boolean;
var
  USG: IUnitScopedGlobalProvider;
begin
  Result := False;
  if not Supports(Prov, IUnitScopedGlobalProvider, USG) then Exit;
  if not USG.GlobalNameCollidesAcrossUnits(Name) then Exit;
  Result := USG.FindGlobalInUnit(Name, UnitHint, Global);
  if Result then
    DapLog(Format('FindGlobalForRva: unit-scoped "%s" in unit "%s" -> TypeHint="%s" (cross-unit disambig)',
      [Name, UnitHint, Global.TypeHint]));
end;

function TDebugInfoSet.TryRequiresClosureGlobal(Rva: UInt64;
  const Name: string; out Global: TGlobalSymbol): Boolean;
begin
  Result := False;
  // Requires of the binary that owns Rva (the frame's binary).
  var FrameRequires: TArray<string> := nil;
  var HaveFrame := False;
  for var RG in FRangedGlobals do
    if (Rva >= RG.Lo) and (Rva < RG.Hi) then begin
      FrameRequires := RG.Requires;
      HaveFrame     := True;
      Break;
    end;
  if not HaveFrame or (Length(FrameRequires) = 0) then Exit;

  // Walk the requires-closure breadth-first in declared order; the first
  // required package that declares Name wins. A visited set guards cycles and
  // makes the walk O(modules).
  var Visited := TDictionary<string, Boolean>.Create;
  var Queue   := TQueue<string>.Create;
  try
    for var R in FrameRequires do
      Queue.Enqueue(LowerCase(R));
    while Queue.Count > 0 do begin
      var ReqName := Queue.Dequeue;
      if (ReqName = '') or Visited.ContainsKey(ReqName) then Continue;
      Visited.Add(ReqName, True);
      for var RG in FRangedGlobals do
        if (RG.ModuleName <> '') and SameText(RG.ModuleName, ReqName) then begin
          if RG.Prov.FindGlobal(Name, Global) then begin
            DapLog(Format('FindGlobalForRva: uses-graph "%s" via required package "%s" -> TypeHint="%s"',
              [Name, ReqName, Global.TypeHint]));
            Exit(True);
          end;
          for var R2 in RG.Requires do
            if not Visited.ContainsKey(LowerCase(R2)) then
              Queue.Enqueue(LowerCase(R2));
        end;
    end;
  finally
    Queue.Free;
    Visited.Free;
  end;
end;

function TDebugInfoSet.FindGlobalForRva(Rva: UInt64; const Name: string;
  out Global: TGlobalSymbol): Boolean;
begin
  // Cross-unit, same-binary disambiguation (mirror of GetLocalsForFunctionByRva):
  // when a global name is declared in more than one unit of the binary that owns
  // Rva, the plain first-hit FindGlobal returns the WRONG unit's metadata. Scope
  // the lookup to the frame's source unit first. Gated by the O(1) collision
  // check inside TryUnitScopedGlobal, so non-colliding names cost nothing.
  var UnitHint := UnitNameForRva(Rva);
  for var RG in FRangedGlobals do
    if (Rva >= RG.Lo) and (Rva < RG.Hi) then begin
      if (UnitHint <> '') and TryUnitScopedGlobal(RG.Prov, Name, UnitHint, Global) then
        Exit(True);
      if RG.Prov.FindGlobal(Name, Global) then
        Exit(True);
    end;
  // Uses-graph tier: the global is not in the frame's own binary. Prefer a
  // copy from a binary the frame's binary `requires` (its visible scope) over
  // the flat first-hit, which would otherwise return an unrelated module's
  // same-named global by load order.
  if TryRequiresClosureGlobal(Rva, Name, Global) then
    Exit(True);
  Result := FindGlobal(Name, Global);
end;

function TDebugInfoSet.FindGlobal(const Name: string;
  out Global: TGlobalSymbol): Boolean;
begin
  for var P in FGlobalProviders do
    if P.FindGlobal(Name, Global) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.LookupEnumInfo(const TypeName: string;
  out Info: TRsmEnumInfo): Boolean;
var
  Tmp: TRsmEnumInfo;
begin
  // SET resolution: a set typedef may be reported by several providers --
  // one as a bare Kind=6 with NO member names (e.g. RSM), another (TD32)
  // as Kind=6 WITH the base enum's names populated. First-hit-wins would
  // pick the empty one. Prefer the richest set result: Kind=6 with the
  // most member names. Fall back to first hit for non-set types.
  var BestSet:   TRsmEnumInfo;
  var BestNames: Integer := -1;
  for var P in FEnumProviders do
    if P.LookupEnumInfo(TypeName, Tmp) and (Tmp.Kind = 6) then
      if Length(Tmp.Names) > BestNames then begin
        BestSet   := Tmp;
        BestNames := Length(Tmp.Names);
      end;
  if BestNames >= 0 then begin
    Info := BestSet;
    Exit(True);
  end;
  for var P in FEnumProviders do
    if P.LookupEnumInfo(TypeName, Info) then
      Exit(True);
  Result := False;
end;

// RTL aliases declared as `TName = type string`. A `type string` is a DISTINCT
// type with its own TypeInfo, so its SOURCE name (e.g. TCaption) is what RSM
// records -- RSM does not collapse it to `string` the way TD32 does. When the
// owning binary's TD32 is not loaded (e.g. VCL in an unloaded runtime BPL on a
// multi-package build), member/property resolution falls to RSM and the alias
// name reaches this lookup. Map the well-known RTL string aliases to tkUString
// so getter-ABI dispatch and string formatting treat them as strings.
// Limitation: a USER-defined `type string` in a binary whose TD32 is not loaded
// is not covered (no generic RSM alias decoding yet) -- see KNOWN_UNKNOWNS.
function RtlStringAliasKind(const TypeName: string): Byte;
const
  TK_USTRING_ = 18; // System.TypInfo.tkUString
begin
  for var N in ['TCaption', 'TTranslateString', 'TFileName',
                'TComponentName', 'TFontName'] do
    if SameText(TypeName, N) then
      Exit(TK_USTRING_);
  Result := 0;
end;

function TDebugInfoSet.LookupTypeKind(const TypeName: string): Byte;
begin
  for var P in FEnumProviders do begin
    Result := P.LookupTypeKind(TypeName);
    if Result <> 0 then Exit;
  end;
  Result := RtlStringAliasKind(TypeName);
end;

function TDebugInfoSet.GetClassMembers(const ClassName: string;
  out Members: TArray<TClassMember>; PreferInstanceSize: Integer): Boolean;
var
  ProviderMembers: TArray<TClassMember>;
begin
  // Use the first provider that returns a NON-EMPTY member list. TD32 may
  // recognise the class as a type but fail to parse its FIELDLIST (BPL
  // type that lives in another compilation unit), reporting True / 0
  // members. Without the non-empty gate, that suppresses the RSM fallback
  // which holds the real member list. SampleApp: TCachedMenu's `Level`
  // indexed property could not be found because TD32's 0-member True
  // shadowed RSM's 11-member view.
  //
  // PreferInstanceSize disambiguates a bare name shared by two classes (the
  // live Data.DB.TFields vs System.Classes.TFieldsCache.TFields): it is passed
  // to each provider so the record whose declared size matches the object's
  // runtime VMT wins over the first-indexed one.
  Result := False;
  SetLength(Members, 0);
  for var P in FMemberProviders do
    if P.GetClassMembers(ClassName, ProviderMembers, PreferInstanceSize) and
       (Length(ProviderMembers) > 0) then begin
      Members := ProviderMembers;
      Exit(True);
    end;
end;

function TDebugInfoSet.TryGetMethodParams(const ClassName, MethodName: string;
  out Params: TArray<TMethodParam>; out HasSelf: Boolean): Boolean;
begin
  Result := False;
  SetLength(Params, 0);
  HasSelf := False;
  // First provider that resolves the signature wins. Only TD32 implements it.
  for var P in FSigProviders do
    if P.TryGetMethodParams(ClassName, MethodName, Params, HasSelf) then
      Exit(True);
end;

function TDebugInfoSet.TryGetFreeFunctionParamCount(const FuncName: string;
  out Count: Integer): Boolean;
begin
  Result := False;
  Count  := 0;
  // First provider that recognises the free proc wins. Only TD32 implements it.
  for var P in FSigProviders do
    if P.TryGetFreeFunctionParamCount(FuncName, Count) then
      Exit(True);
end;

function TDebugInfoSet.GetParentClassName(const ClassName: string;
  out Parent: string): Boolean;
begin
  Result := False;
  Parent := '';
  if ClassName = '' then Exit;
  for var P in FHierProviders do
    if P.GetParentClassName(ClassName, Parent) and (Parent <> '') then
      Exit(True);
end;

function TDebugInfoSet.GetTypeSize(const TypeName: string;
  out Size: Integer): Boolean;
begin
  Size   := 0;
  Result := False;
  if TypeName = '' then Exit;
  // Primitive byte sizes (no provider needed). Mirrors LocalReadSize /
  // PrimTypeSize so dyn-array stride is exact for primitive elements.
  if SameText(TypeName, 'Byte')     or SameText(TypeName, 'ShortInt') or
     SameText(TypeName, 'AnsiChar') or SameText(TypeName, 'Boolean')  or
     SameText(TypeName, 'ByteBool') then begin
    Size := 1; Exit(True);
  end;
  if SameText(TypeName, 'Word')     or SameText(TypeName, 'SmallInt') or
     SameText(TypeName, 'WideChar') or SameText(TypeName, 'Char')     or
     SameText(TypeName, 'WordBool') then begin
    Size := 2; Exit(True);
  end;
  if SameText(TypeName, 'Integer')  or SameText(TypeName, 'Cardinal') or
     SameText(TypeName, 'LongInt')  or SameText(TypeName, 'LongWord') or
     SameText(TypeName, 'Int32')    or SameText(TypeName, 'UInt32')   or
     SameText(TypeName, 'Single')   or SameText(TypeName, 'LongBool') then begin
    Size := 4; Exit(True);
  end;
  if SameText(TypeName, 'Int64')    or SameText(TypeName, 'UInt64')   or
     SameText(TypeName, 'Double')   or SameText(TypeName, 'Currency') or
     SameText(TypeName, 'TDateTime') then begin
    Size := 8; Exit(True);
  end;
  // Named record / class / pointer family: ask the providers (TD32 reads
  // the exact size from its TYPES record).
  for var P in FSizeProviders do
    if P.GetTypeSize(TypeName, Size) and (Size > 0) then
      Exit(True);
end;

function TDebugInfoSet.TryResolveEnumLiteral(const Name: string;
  out Ordinal: Integer; out EnumTypeName: string): Boolean;
begin
  for var P in FEnumProviders do
    if P.TryResolveEnumLiteral(Name, Ordinal, EnumTypeName) then
      Exit(True);
  Result := False;
end;

function TDebugInfoSet.DiagAllProcNames: TArray<string>;
begin
  SetLength(Result, 0);
  for var P in FLocalProviders do
    Result := Result + P.AllProcedureNames;
end;

function TDebugInfoSet.SortedRvas: TArray<UInt64>;
begin
  SetLength(Result, 0);
  for var P in FLineProviders do
    Result := Result + P.SortedRvas;
  // Each provider's list is sorted, but their concatenation is NOT (TD32 and
  // MAP both cover the same module ranges). Callers binary-search this array
  // (PlantInFuncStepBps), so re-sort and drop the cross-provider duplicates.
  if Length(Result) = 0 then
    Exit;
  TArray.Sort<UInt64>(Result);
  var Last := 0;
  for var I := 1 to High(Result) do
    if Result[I] <> Result[Last] then begin
      Inc(Last);
      Result[Last] := Result[I];
    end;
  SetLength(Result, Last + 1);
end;

end.
