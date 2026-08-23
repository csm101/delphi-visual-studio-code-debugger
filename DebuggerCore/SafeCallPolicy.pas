unit SafeCallPolicy;

// Which getters the debugger may call WITHOUT being asked.
//
// A property backed by a getter defers as "(expand to evaluate)" because
// calling code the user did not ask to run is how a debugger mutates the very
// state it is showing. This unit holds the POLICY that lifts that deferral for
// members someone has vouched for -- by hand (the user file this unit also
// writes), or by a generated archive committed next to the sources it
// describes. The MECHANISM stays elsewhere and stays on regardless: the
// synthetic-call raise/AV abort and its watchdog protect whitelisted calls
// exactly like requested ones, so a wrong verdict costs a visible error, never
// a silent corruption.
//
// Archives are `*.safelist.json` files, discovered by CONVENTION, never by
// launch.json:
//
//   1. <user dir>\user.safelist.json      -- manual decisions, allow AND deny.
//                                            The correction layer: beats all.
//   2. nearest ancestor of the SYMBOL's    -- an archive covers the sources
//      source file carrying a verdict        below its directory, so the one
//                                            closest to the source is the most
//                                            specific. This is what lets a
//                                            library repo commit its own
//                                            archive and every colleague pick
//                                            it up with a pull.
//   3. any archive along the source dirs   -- the same files, consulted by
//      (each dir + its ancestors)            name when the symbol's source
//                                            path is not known.
//   4. <user dir>\*.safelist.json          -- generated archives that apply to
//      (all but user.safelist.json)          every project of this user.
//   5. <shipped dir>\*.safelist.json       -- distributed with the release.
//
// The verdict vocabulary is a CLAIM STRENGTH, not a boolean, because the false
// friends differ: `lazyInit` (a getter that creates on first call -- the
// canonical TWinControl.Handle, which creates the WINDOW) must never run
// automatically, while `mayRaise` (pure but for a guarded error path) is safe
// to run where a visible error is acceptable. `trusted` is what a manual
// "always evaluate this" click writes: user-approved, which is an authority,
// not a proof -- kept distinct from `pure` so an archive reader can tell them
// apart.
//
// Reading is LAZY at every level, following the loader's own philosophy: a
// directory is probed for archive NAMES once (existence + mtime, no content),
// an archive's content is parsed on the first lookup that consults its
// directory, and a parsed archive keeps only what decisions need -- key and
// verdict. Evidence lines, hashes and provenance stay in the file for humans
// and for the lint; the debugger never pays for them.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TSafeVerdict = (
    svNone,         // no archive has an opinion
    svDeny,         // the user said never -- beats everything below
    svUnsafe,       // analysis says it mutates
    svLazyInit,     // creates state on first call; never auto
    svConditional,  // safe iff its dependsOn are; deferred until increment 3
    svMayRaise,     // pure except a guarded error path
    svTrusted,      // user-approved by hand
    svPure          // analysis says it only reads
  );

  // One parsed archive: lowercase 'class.member' -> verdict. Everything else in
  // the file (evidence, hashes, dependsOn) is deliberately not retained.
  TSafelistArchive = class
  public
    Path:     string;
    Dir:      string;   // lowercase directory, the containment anchor
    MTime:    TDateTime;
    Verdicts: TDictionary<string, TSafeVerdict>;
    constructor Create;
    destructor Destroy; override;
  end;

  TSafeCallPolicy = class
  private
    FUserDir:    string;   // %USERPROFILE%\.DelphiWinDebugger by default
    FShippedDir: string;   // directory of the adapter exe
    FSourceDirs: TList<string>;         // registered roots (sourceRoot, search paths)
    FPoolBuilt:  Boolean;
    FPoolDirs:   TList<string>;         // source dirs + ancestors, deduped, lowercase
    // dir (lowercase) -> archive file paths found there. A MISS is cached too:
    // an empty list. This is what keeps the per-symbol ancestor walk off the
    // filesystem.
    FDirFiles:   TDictionary<string, TArray<string>>;
    // archive path (lowercase) -> parsed archive, mtime-validated on access.
    FArchives:   TObjectDictionary<string, TSafelistArchive>;
    // Names that resolved to svNone anywhere, so a repeated hover over an
    // unlisted getter costs one dictionary probe. Cleared on Reload.
    FNegative:   TDictionary<string, Byte>;

    function  UserFilePath: string;
    function  ProbeDir(const Dir: string): TArray<string>;
    function  ArchiveFor(const Path: string): TSafelistArchive;
    function  LookupInDir(const Dir: string; const Keys: TArray<string>;
                out Verdict: TSafeVerdict): Boolean;
    function  LookupInFiles(const Files: TArray<string>; const Keys: TArray<string>;
                out Verdict: TSafeVerdict): Boolean;
    procedure BuildPool;
    procedure WriteUserFile(const Entries: TArray<TPair<string, TSafeVerdict>>);
    function  ReadUserEntries: TArray<TPair<string, TSafeVerdict>>;
  public
    constructor Create(const AUserDir, AShippedDir: string);
    destructor Destroy; override;

    // sourceRoot + sourceSearchPaths, from the launch configuration the session
    // already has. Registering after lookups is fine: the pool rebuilds.
    procedure RegisterSourceDirs(const Dirs: TArray<string>);

    // The decision. Keys are the spellings the caller can honestly derive, most
    // specific first (e.g. 'TWidget.DoCalcScore', then 'TWidget.Score');
    // SourceFileHint, when known, anchors the containment walk. First verdict
    // wins across the layer order documented above.
    function Resolve(const Keys: TArray<string>;
               const SourceFileHint: string = ''): TSafeVerdict;

    // True when a verdict allows calling WITHOUT an explicit request. This is
    // the only question the expander asks; keeping it here means the tier
    // policy has one home.
    class function AllowsAutoCall(V: TSafeVerdict): Boolean; static;

    // The user file: one entry per key, deny or trusted. Written atomically
    // (temp + rename), stably sorted, one entry per line -- the file is meant
    // to be hand-corrected and diffed.
    procedure AddUser(const Key: string; Deny: Boolean);
    procedure RemoveUser(const Key: string);

    // Forget everything cached and re-read on next use. Called after AddUser /
    // RemoveUser internally and by the frontends' explicit reload request.
    procedure Reload;

    class function VerdictName(V: TSafeVerdict): string; static;
    class function ParseVerdict(const S: string): TSafeVerdict; static;
  end;

// The default user directory (%USERPROFILE%\.DelphiWinDebugger), overridable
// via the DELPHI_DEBUGGER_SAFELIST_DIR environment variable -- which is how the
// tests keep their hands off the real user file.
function DefaultSafelistUserDir: string;

implementation

uses
  System.IOUtils, System.JSON, System.Generics.Defaults, Winapi.Windows;

function DefaultSafelistUserDir: string;
begin
  Result := GetEnvironmentVariable('DELPHI_DEBUGGER_SAFELIST_DIR');
  if Result <> '' then
    Exit;
  Result := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.DelphiWinDebugger');
end;

{ TSafelistArchive }

constructor TSafelistArchive.Create;
begin
  inherited;
  Verdicts := TDictionary<string, TSafeVerdict>.Create;
end;

destructor TSafelistArchive.Destroy;
begin
  Verdicts.Free;
  inherited;
end;

{ TSafeCallPolicy }

constructor TSafeCallPolicy.Create(const AUserDir, AShippedDir: string);
begin
  inherited Create;
  FUserDir    := AUserDir;
  FShippedDir := AShippedDir;
  FSourceDirs := TList<string>.Create;
  FPoolDirs   := TList<string>.Create;
  FDirFiles   := TDictionary<string, TArray<string>>.Create;
  FArchives   := TObjectDictionary<string, TSafelistArchive>.Create([doOwnsValues]);
  FNegative   := TDictionary<string, Byte>.Create;
end;

destructor TSafeCallPolicy.Destroy;
begin
  FNegative.Free;
  FArchives.Free;
  FDirFiles.Free;
  FPoolDirs.Free;
  FSourceDirs.Free;
  inherited;
end;

function TSafeCallPolicy.UserFilePath: string;
begin
  Result := TPath.Combine(FUserDir, 'user.safelist.json');
end;

procedure TSafeCallPolicy.RegisterSourceDirs(const Dirs: TArray<string>);
begin
  for var D in Dirs do begin
    var Norm := LowerCase(ExcludeTrailingPathDelimiter(Trim(D)));
    if (Norm <> '') and (not FSourceDirs.Contains(Norm)) then begin
      FSourceDirs.Add(Norm);
      FPoolBuilt := False;   // ancestors change; rebuild lazily
    end;
  end;
end;

class function TSafeCallPolicy.VerdictName(V: TSafeVerdict): string;
begin
  case V of
    svDeny:        Result := 'deny';
    svUnsafe:      Result := 'unsafe';
    svLazyInit:    Result := 'lazyInit';
    svConditional: Result := 'conditional';
    svMayRaise:    Result := 'mayRaise';
    svTrusted:     Result := 'trusted';
    svPure:        Result := 'pure';
    else           Result := 'none';
  end;
end;

class function TSafeCallPolicy.ParseVerdict(const S: string): TSafeVerdict;
begin
  // Unknown spellings map to svNone rather than raising: a NEWER archive with a
  // verdict this build does not know must degrade to "no opinion", not break
  // every lookup that walks through its directory.
  if SameText(S, 'deny')        then Exit(svDeny);
  if SameText(S, 'unsafe')      then Exit(svUnsafe);
  if SameText(S, 'lazyInit')    then Exit(svLazyInit);
  if SameText(S, 'conditional') then Exit(svConditional);
  if SameText(S, 'mayRaise')    then Exit(svMayRaise);
  if SameText(S, 'trusted')     then Exit(svTrusted);
  if SameText(S, 'pure')        then Exit(svPure);
  Result := svNone;
end;

class function TSafeCallPolicy.AllowsAutoCall(V: TSafeVerdict): Boolean;
begin
  // The tier policy, in one place. `conditional` waits for dependsOn resolution
  // (increment 3); `lazyInit` is never automatic BY DESIGN -- the getter
  // creates state, and a debugger that creates window handles on hover is the
  // failure this whole unit exists to prevent.
  Result := V in [svPure, svTrusted, svMayRaise];
end;

function TSafeCallPolicy.ProbeDir(const Dir: string): TArray<string>;
begin
  var Key := LowerCase(ExcludeTrailingPathDelimiter(Dir));
  if Key = '' then
    Exit(nil);
  if FDirFiles.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  try
    if TDirectory.Exists(Key) then
      Result := TDirectory.GetFiles(Key, '*.safelist.json', TSearchOption.soTopDirectoryOnly);
  except
    // An unreadable directory is a miss, and the miss is cached like any other.
  end;
  TArray.Sort<string>(Result);   // deterministic same-tier order
  FDirFiles.Add(Key, Result);
end;

function TSafeCallPolicy.ArchiveFor(const Path: string): TSafelistArchive;
begin
  var Key := LowerCase(Path);
  var MTime: TDateTime := 0;
  try
    MTime := TFile.GetLastWriteTime(Path);
  except
  end;
  if FArchives.TryGetValue(Key, Result) then begin
    if Result.MTime = MTime then
      Exit;
    FArchives.Remove(Key);   // stale: fall through and re-parse
  end;

  Result       := TSafelistArchive.Create;
  Result.Path  := Path;
  Result.Dir   := LowerCase(ExcludeTrailingPathDelimiter(ExtractFilePath(Path)));
  Result.MTime := MTime;
  try
    var Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Path, TEncoding.UTF8));
    try
      if Root is TJSONObject then begin
        var Entries := TJSONObject(Root).GetValue('entries') as TJSONArray;
        if Entries <> nil then
          for var V in Entries do begin
            if not (V is TJSONObject) then
              Continue;
            var E := TJSONObject(V);
            // Accept either the split fields (what the agent emits) or a
            // pre-joined "key" (what terse hand-written files use).
            var K := LowerCase(Trim(E.GetValue<string>('key', '')));
            if K = '' then begin
              var Cls    := Trim(E.GetValue<string>('class', ''));
              var Member := Trim(E.GetValue<string>('member', ''));
              if (Cls <> '') and (Member <> '') then
                K := LowerCase(Cls + '.' + Member);
            end;
            if K = '' then
              Continue;
            // First entry wins within one file; the lint flags duplicates, the
            // reader must not let a later line silently overturn an earlier one.
            if not Result.Verdicts.ContainsKey(K) then
              Result.Verdicts.Add(K, ParseVerdict(E.GetValue<string>('verdict', '')));
          end;
      end;
    finally
      Root.Free;
    end;
  except
    // A malformed archive contributes nothing. It must not take the session
    // down: the file is user-editable by design, and a typo in it costs the
    // entries, not the debugger.
    Result.Verdicts.Clear;
  end;
  FArchives.Add(Key, Result);
end;

function TSafeCallPolicy.LookupInFiles(const Files: TArray<string>;
  const Keys: TArray<string>; out Verdict: TSafeVerdict): Boolean;
begin
  for var F in Files do begin
    var A := ArchiveFor(F);
    for var K in Keys do
      if A.Verdicts.TryGetValue(K, Verdict) and (Verdict <> svNone) then
        Exit(True);
  end;
  Verdict := svNone;
  Result := False;
end;

function TSafeCallPolicy.LookupInDir(const Dir: string;
  const Keys: TArray<string>; out Verdict: TSafeVerdict): Boolean;
begin
  Result := LookupInFiles(ProbeDir(Dir), Keys, Verdict);
end;

procedure TSafeCallPolicy.BuildPool;
begin
  if FPoolBuilt then
    Exit;
  FPoolDirs.Clear;
  var Seen := TDictionary<string, Byte>.Create;
  try
    for var D in FSourceDirs do begin
      // The dir itself and every ancestor up to the drive root: the containment
      // rule ("an archive covers the sources below it") read from the discovery
      // side. Ancestors repeat massively across 150 search paths; Seen keeps
      // the pool a fraction of that.
      var Cur := D;
      while Cur <> '' do begin
        if not Seen.ContainsKey(Cur) then begin
          Seen.Add(Cur, 0);
          FPoolDirs.Add(Cur);
        end;
        var Parent := ExcludeTrailingPathDelimiter(ExtractFilePath(Cur));
        if SameText(Parent, Cur) then
          Break;
        Cur := Parent;
      end;
    end;
  finally
    Seen.Free;
  end;
  FPoolBuilt := True;
end;

function TSafeCallPolicy.Resolve(const Keys: TArray<string>;
  const SourceFileHint: string): TSafeVerdict;
begin
  Result := svNone;
  if Length(Keys) = 0 then
    Exit;

  var Norm: TArray<string>;
  SetLength(Norm, Length(Keys));
  var NegKey := '';
  for var I := 0 to High(Keys) do begin
    Norm[I] := LowerCase(Trim(Keys[I]));
    NegKey := NegKey + Norm[I] + '|';
  end;
  if FNegative.ContainsKey(NegKey) then
    Exit;

  // 1. The user's own decisions.
  if LookupInDir(FUserDir, Norm, Result) then begin
    // user.safelist.json specifically; other files in the user dir belong to
    // tier 4. ProbeDir returned every archive there, so re-check the winner:
    // if it came from user.safelist.json we are done, otherwise remember the
    // verdict as the tier-4 fallback and keep going.
    var UserOnly: TArray<string> := nil;
    if TFile.Exists(UserFilePath) then
      UserOnly := [UserFilePath];
    var V: TSafeVerdict;
    if LookupInFiles(UserOnly, Norm, V) then
      Exit(V);
  end;

  // 2. Anchored to the symbol's source: nearest ancestor wins.
  if SourceFileHint <> '' then begin
    var Cur := LowerCase(ExcludeTrailingPathDelimiter(ExtractFilePath(SourceFileHint)));
    while Cur <> '' do begin
      var V: TSafeVerdict;
      if LookupInDir(Cur, Norm, V) then
        Exit(V);
      var Parent := ExcludeTrailingPathDelimiter(ExtractFilePath(Cur));
      if SameText(Parent, Cur) then
        Break;
      Cur := Parent;
    end;
  end;

  // 3. The source-derived pool, by name.
  BuildPool;
  for var D in FPoolDirs do begin
    var V: TSafeVerdict;
    if LookupInDir(D, Norm, V) then
      Exit(V);
  end;

  // 4. Generated archives in the user dir (everything but user.safelist.json).
  var UserFiles := ProbeDir(FUserDir);
  var Others: TArray<string> := nil;
  for var F in UserFiles do
    if not SameText(F, UserFilePath) then
      Others := Others + [F];
  var V4: TSafeVerdict;
  if LookupInFiles(Others, Norm, V4) then
    Exit(V4);

  // 5. Shipped beside the adapter.
  if (FShippedDir <> '') and LookupInDir(FShippedDir, Norm, Result) then
    Exit;

  Result := svNone;
  // Bounded: a pathological session watching thousands of distinct unlisted
  // getters must not grow this forever.
  if FNegative.Count < 4096 then
    FNegative.Add(NegKey, 0);
end;

{ user file writing }

function TSafeCallPolicy.ReadUserEntries: TArray<TPair<string, TSafeVerdict>>;
begin
  Result := nil;
  var A := ArchiveFor(UserFilePath);
  for var P in A.Verdicts do
    Result := Result + [TPair<string, TSafeVerdict>.Create(P.Key, P.Value)];
end;

procedure TSafeCallPolicy.WriteUserFile(
  const Entries: TArray<TPair<string, TSafeVerdict>>);
begin
  // Stable order and one entry per line: the file is meant to be diffed and
  // hand-corrected, and a regenerated file must differ only where a decision
  // actually changed.
  var Sorted := Entries;
  TArray.Sort<TPair<string, TSafeVerdict>>(Sorted,
    TComparer<TPair<string, TSafeVerdict>>.Construct(
      function(const L, R: TPair<string, TSafeVerdict>): Integer
      begin
        Result := CompareStr(L.Key, R.Key);
      end));

  var SB := TStringBuilder.Create;
  try
    SB.AppendLine('{');
    SB.AppendLine('  "schemaVersion": 1,');
    SB.AppendLine('  "origin": "user",');
    SB.Append('  "entries": [');
    for var I := 0 to High(Sorted) do begin
      if I > 0 then
        SB.Append(',');
      SB.AppendLine;
      SB.Append(Format('    { "key": "%s", "verdict": "%s" }',
        [Sorted[I].Key, VerdictName(Sorted[I].Value)]));
    end;
    SB.AppendLine;
    SB.AppendLine('  ]');
    SB.AppendLine('}');

    if not TDirectory.Exists(FUserDir) then
      TDirectory.CreateDirectory(FUserDir);
    // Atomic: a crash mid-write must leave the previous file, not half a file.
    var Tmp := UserFilePath + '.tmp';
    TFile.WriteAllText(Tmp, SB.ToString, TEncoding.UTF8);
    if TFile.Exists(UserFilePath) then
      TFile.Delete(UserFilePath);
    TFile.Move(Tmp, UserFilePath);
  finally
    SB.Free;
  end;
end;

procedure TSafeCallPolicy.AddUser(const Key: string; Deny: Boolean);
begin
  var K := LowerCase(Trim(Key));
  if K = '' then
    Exit;
  var Entries := ReadUserEntries;
  var Verdict := svTrusted;
  if Deny then
    Verdict := svDeny;
  var Found := False;
  for var I := 0 to High(Entries) do
    if Entries[I].Key = K then begin
      Entries[I] := TPair<string, TSafeVerdict>.Create(K, Verdict);
      Found := True;
      Break;
    end;
  if not Found then
    Entries := Entries + [TPair<string, TSafeVerdict>.Create(K, Verdict)];
  WriteUserFile(Entries);
  Reload;
end;

procedure TSafeCallPolicy.RemoveUser(const Key: string);
begin
  var K := LowerCase(Trim(Key));
  var Entries := ReadUserEntries;
  var Kept: TArray<TPair<string, TSafeVerdict>> := nil;
  for var E in Entries do
    if E.Key <> K then
      Kept := Kept + [E];
  if Length(Kept) = Length(Entries) then
    Exit;
  WriteUserFile(Kept);
  Reload;
end;

procedure TSafeCallPolicy.Reload;
begin
  FDirFiles.Clear;
  FArchives.Clear;
  FNegative.Clear;
  FPoolBuilt := False;
end;

end.
