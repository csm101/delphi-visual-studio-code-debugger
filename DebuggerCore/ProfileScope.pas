unit ProfileScope;

// What a profiling or coverage collection measures: the `include` / `exclude`
// lists of docs/PROFILER_COVERAGE_PLAN.md ("Scope") turned into a decision
// over a code map (CodeMap.pas).
//
// GRAMMAR. An entry is `kind:pattern`. The kind is the text before the FIRST
// colon, so a pattern may hold a drive letter (`file:C:\src\*.pas`). Kinds,
// without regard to case: module, unit, file, class, routine. An entry with no
// colon is a unit. `*` matches any run of characters, `?` exactly one;
// everything is compared without regard to case. An unknown kind or an empty
// pattern is an error that names the entry -- nothing is skipped silently.
//
//   module:   the module's file name, with or without its extension.
//   unit:     the unit that holds a line record: the full name the debug
//             information gives it (`System.SysUtils`). For a generic
//             instantiated in another unit that is the INSTANTIATING unit.
//   file:     a pattern with a path separator is matched against the file's
//             path -- the resolved one when there is one, else the recorded
//             one, else the bare name; `/` and `\` are the same character. A
//             pattern without a separator is matched against the file name.
//   class:    the class part of the routine's name (see below). A routine
//             without one matches no `class:` pattern, not even `*`.
//   routine:  a pattern with a class part is matched against the whole
//             routine name, one without against the routine part alone:
//             `routine:Create` is every Create, `routine:TWidget.Create` one
//             method, `routine:*.Create` every METHOD called Create.
//
// THE ROUTINE NAME is taken as the provider spells it, and the providers do not
// put the unit in it. It is split at the LAST dot that is outside `<...>` and
// `{...}`: what precedes is the class part, what follows the routine part.
//
//   TD32   TWidget.Create                                    TWidget | Create
//          InnerNested (a nested routine: its own name only)        | InnerNested
//          TDictionary__2<Integer, System.UnicodeString>.Create
//                          TDictionary__2<Integer, System.UnicodeString> | Create
//   TD32, 32-bit image: a generic instantiation keeps its mangled name
//          %TList__1.Add$qqrxp40System@Generics@Collections@%TList__1$i%
//                    %TList__1 | Add$qqrxp40System@Generics@Collections@%TList__1$i%
//          %TDictionary__2.$bctr$qqrv (a constructor)    %TDictionary__2 | $bctr$qqrv
//   MAP    {System.Generics.Collections}TList<System.Integer>.Add
//                     {System.Generics.Collections}TList<System.Integer> | Add
//          RunTypeSampler$ActRec.$0$Body      RunTypeSampler$ActRec | $0$Body
//
// What that cannot express:
//   * A routine of ONE unit when another unit has a routine of the same name:
//     the name carries no unit and the entries of a list are alternatives,
//     never a conjunction. Include the unit and exclude what is not wanted.
//   * One overload: overloads share a name.
//   * A nested routine through its parent: TD32 names it by its own name only.
//   * An anonymous method under TD32: its body has no procedure record, so its
//     line records lie outside every routine and are never in scope.
//   * A generic instantiation by one spelling: TD32 writes `TList__1<Integer>`
//     in a 64-bit image and `%TList__1` in a 32-bit one, MAP and JDBG
//     `{System.Generics.Collections}TList<System.Integer>`. Use a wildcard
//     (`class:*TList*`). In a 32-bit image under TD32 the type arguments are
//     not in the class part at all, so TList<Integer> and TList<string> cannot
//     be told apart there, and the routine part carries the mangled signature:
//     `routine:Add` does not match it, `routine:Add$*` does.
//   * A class nested in another by the outer name alone: its class part is
//     `TOuter.TInner`, which `class:TOuter` does not match and `class:TOuter*`
//     does.
//   * With the MAP as the routine provider, a routine of a unit with a dotted
//     name keeps what follows the unit's first segment
//     (`SysUtils.TEncoding.GetBytes`), which becomes part of the class part.
//
// DECISION. Exclusion wins: a record that matches any `exclude` entry is out.
// Otherwise, with at least one `include` entry, a record is in when it matches
// any of them. With no `include` the default applies, the first of:
//   1. the reference set, when one is given: the record's file is in it;
//   2. the source root, when one is given: the record's file RESOLVES to a
//      path under it (an unresolved file is under nothing);
//   3. neither: the record belongs to the main module.
//
// Two rules hold whatever the lists say:
//   * A line record outside every routine range is never in scope.
//   * A routine is in scope exactly when one of its line records is. A routine
//     without line records therefore never is: nothing measured on it could be
//     keyed by source.
//
// The unit depends on CodeMap and on nothing else of the engine: no session,
// no process, no front end. A scope is immutable once created and can be used
// from any thread.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}
{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  CodeMap;

type
  /// <summary>A malformed scope: an entry with an unknown kind or an empty
  /// pattern, a source root that is not an absolute path, a reference file
  /// that is neither an absolute path nor a bare name. The message names every
  /// offending entry.</summary>
  EProfileScopeError = class(Exception);

  /// <summary>What an entry of an include or exclude list is matched against.</summary>
  TProfileScopeKind = (
    /// <summary><c>module:</c> the module's file name.</summary>
    Module,
    /// <summary><c>unit:</c>, or an entry with no kind: the unit name.</summary>
    CodeUnit,
    /// <summary><c>file:</c> the source file's path or name.</summary>
    SourceFile,
    /// <summary><c>class:</c> the class part of the routine name.</summary>
    ClassName,
    /// <summary><c>routine:</c> the routine name.</summary>
    Routine);

  /// <summary>One parsed entry of an include or exclude list.</summary>
  TProfileScopeEntry = record
    /// <summary>The entry as it was given.</summary>
    Text: string;
    /// <summary>What the pattern is matched against.</summary>
    Kind: TProfileScopeKind;
    /// <summary>The pattern, trimmed and lowercased; for a <c>file:</c> entry
    /// with every <c>/</c> turned into <c>\</c>.</summary>
    Pattern: string;
    /// <summary>For <c>file:</c>, the pattern holds a path separator and is
    /// matched against a path. For <c>routine:</c>, the pattern has a class
    /// part and is matched against the whole routine name. False for the other
    /// kinds.</summary>
    Qualified: Boolean;
  end;

  /// <summary>Which rule decides what is in scope before exclusion.</summary>
  TProfileScopeBasis = (
    /// <summary>The include list.</summary>
    Patterns,
    /// <summary>No include list; a reference set of source files.</summary>
    ReferenceFiles,
    /// <summary>No include list, no reference set; a source root.</summary>
    SourceRoot,
    /// <summary>None of the above: the main module.</summary>
    MainModule);

  /// <summary>The inputs of a scope.</summary>
  TProfileScopeOptions = record
    /// <summary>Entries of the include list; empty selects the default.</summary>
    Include: TArray<string>;
    /// <summary>Entries of the exclude list; applied to the default as well.</summary>
    Exclude: TArray<string>;
    /// <summary>The project's source root as an absolute path, or empty. Used
    /// only when there is neither an include list nor a reference set.</summary>
    SourceRoot: string;
    /// <summary>True when <c>ReferenceFiles</c> is a reference set, even an
    /// empty one (which then selects nothing). False ignores the list.</summary>
    HasReferenceFiles: Boolean;
    /// <summary>The source files of the reference: each an absolute path, or a
    /// bare file name for a file that was not resolved. Replaces the
    /// source-root default when there is no include list.</summary>
    ReferenceFiles: TArray<string>;
  end;

  /// <summary>The scope decision for one module's code map.</summary>
  TModuleScope = record
    /// <summary>One flag per entry of <c>TModuleCodeMap.Lines</c>: the line
    /// record is in scope.</summary>
    Lines: TArray<Boolean>;
    /// <summary>One flag per entry of <c>TModuleCodeMap.Routines</c>: at least
    /// one line record of the routine is in scope.</summary>
    Routines: TArray<Boolean>;
    /// <summary>Number of line records in scope.</summary>
    LineCount: Integer;
    /// <summary>Number of routines in scope.</summary>
    RoutineCount: Integer;
    /// <summary>Line records the lists select that are NOT in scope because
    /// they lie outside every routine range. Reported, never measured.</summary>
    SelectedOutsideRoutineCount: Integer;
  end;

  /// <summary>An include / exclude scope, parsed once and applied to any
  /// number of code maps. Immutable once created.</summary>
  TProfileScope = class
  private
    FInclude:        TArray<TProfileScopeEntry>;
    FExclude:        TArray<TProfileScopeEntry>;
    FSourceRoot:     string;   // normalised; empty when none
    FBasis:          TProfileScopeBasis;
    FReferencePaths: TDictionary<string, Boolean>;   // normalised absolute paths
    FReferenceNames: TDictionary<string, Boolean>;   // lowercase bare names
    procedure ParseList(const ListName: string; const Entries: TArray<string>;
      var Parsed: TArray<TProfileScopeEntry>; Problems: TList<string>);
    procedure LoadReferenceFiles(const Files: TArray<string>; Problems: TList<string>);
    function  FileIsInReference(const SourceFile: TCodeMapFile): Boolean;
    function  FileIsUnderRoot(const SourceFile: TCodeMapFile): Boolean;
    class function HasKind(const Entries: TArray<TProfileScopeEntry>;
      Kind: TProfileScopeKind): Boolean; static;
    class function HasKindOtherThan(const Entries: TArray<TProfileScopeEntry>;
      First, Second: TProfileScopeKind): Boolean; static;
    class function ModuleMatches(const Entries: TArray<TProfileScopeEntry>;
      const ModuleName: string): Boolean; static;
    class function UnitMatches(const Entries: TArray<TProfileScopeEntry>;
      const LoweredUnitName: string): Boolean; static;
    class function FileMatches(const Entries: TArray<TProfileScopeEntry>;
      const SourceFile: TCodeMapFile): Boolean; static;
    class function RoutineMatches(const Entries: TArray<TProfileScopeEntry>;
      const LoweredName, LoweredClassPart, LoweredRoutinePart: string): Boolean; static;
    class function MatchesLowered(const Pattern, Text: string): Boolean; static;
    class function NormalizedAbsolutePath(const Path: string): string; static;
  public
    /// <summary>Parses the lists and fixes the rule that decides the scope.</summary>
    /// <param name="Options">Include and exclude lists, source root, reference set.</param>
    /// <exception cref="EProfileScopeError">An entry is malformed, the source
    /// root is not an absolute path, or a reference file is neither an
    /// absolute path nor a bare name. Every offender is named.</exception>
    constructor Create(const Options: TProfileScopeOptions);
    /// <summary>Releases the scope.</summary>
    destructor Destroy; override;
    /// <summary>Creates a scope without raising.</summary>
    /// <param name="Options">As for <c>Create</c>.</param>
    /// <param name="Scope">The scope, owned by the caller; nil on failure.</param>
    /// <param name="Error">What is malformed; empty on success.</param>
    /// <returns>True when the scope was created.</returns>
    class function TryCreate(const Options: TProfileScopeOptions; out Scope: TProfileScope;
      out Error: string): Boolean; static;

    /// <summary>Parses one entry of an include or exclude list.</summary>
    /// <param name="Text">The entry: <c>kind:pattern</c>, or a bare unit pattern.</param>
    /// <param name="Entry">The parsed entry.</param>
    /// <param name="Problem">Why the entry is malformed; empty on success.</param>
    /// <returns>False for an unknown kind or an empty pattern.</returns>
    class function ParseEntry(const Text: string; out Entry: TProfileScopeEntry;
      out Problem: string): Boolean; static;
    /// <summary>Wildcard comparison without regard to case.</summary>
    /// <param name="Pattern"><c>*</c> matches any run of characters, including
    /// none; <c>?</c> exactly one character. Nothing else is special.</param>
    /// <param name="Text">The text; the whole of it must match.</param>
    /// <returns>True when the pattern matches the text.</returns>
    class function Matches(const Pattern, Text: string): Boolean; static;
    /// <summary>Splits a routine name, as a provider spells it, into its class
    /// part and its routine part: at the last dot outside <c>&lt;...&gt;</c>
    /// and <c>{...}</c>.</summary>
    /// <param name="Name">The routine name, without a unit.</param>
    /// <param name="ClassPart">What precedes that dot; empty when there is none.</param>
    /// <param name="RoutinePart">What follows it; the whole name when there is none.</param>
    class procedure SplitRoutineName(const Name: string; out ClassPart, RoutinePart: string); static;
    /// <summary>Whether a path lies in a directory or below it.</summary>
    /// <remarks>A prefix test on normalised absolute paths, without regard to
    /// case and with <c>/</c> equal to <c>\</c>, that ends at a separator:
    /// <c>C:\src2\a.pas</c> is not under <c>C:\src</c>. Short (8.3) names,
    /// links and substituted drives are not resolved.</remarks>
    /// <param name="Root">The directory; an absolute path.</param>
    /// <param name="Path">The path to test; an absolute path.</param>
    /// <returns>True when Path is Root or below it; False when either is not
    /// an absolute path.</returns>
    class function IsPathUnder(const Root, Path: string): Boolean; static;

    /// <summary>Decides, for every line record and routine of a code map,
    /// whether it is in scope.</summary>
    /// <param name="Map">The module's code map.</param>
    /// <param name="IsMainModule">The module is the main executable. Decides
    /// the default when there is neither an include list, a reference set nor
    /// a source root.</param>
    /// <returns>The flags and their counts.</returns>
    /// <exception cref="EArgumentNilException">Map is nil.</exception>
    function Evaluate(Map: TModuleCodeMap; IsMainModule: Boolean): TModuleScope;
    /// <summary>Whether a module can contain anything in scope, asked before
    /// its debug information is parsed.</summary>
    /// <remarks>Answers False only when the scope rules the module out: an
    /// excluding <c>module:</c> entry matches it; every unit it contains is
    /// excluded; the include list holds only <c>module:</c> and <c>unit:</c>
    /// entries and neither the module nor any of its units matches one; or
    /// the default is the main module and this is not it. A scope decided by
    /// source files (a source root, a reference set, a <c>file:</c> entry) or
    /// by routine names (<c>class:</c>, <c>routine:</c>) never rules a module
    /// out: generic code written in a file is compiled into whichever module
    /// instantiates it, and no unit list says where.</remarks>
    /// <param name="ModuleName">The module's file name, or its path.</param>
    /// <param name="IsMainModule">The module is the main executable.</param>
    /// <param name="UnitNames">The units the module contains (for a package,
    /// <c>TPackageInfo.ContainedUnits</c>). Ignored when not known.</param>
    /// <param name="UnitNamesKnown">False when the unit list could not be
    /// obtained; the module is then never ruled out by its units.</param>
    /// <returns>True whenever the module cannot be ruled out.</returns>
    function ModuleMayHoldScope(const ModuleName: string; IsMainModule: Boolean;
      const UnitNames: TArray<string>; UnitNamesKnown: Boolean): Boolean;

    /// <summary>The parsed include list. Read-only: do not modify the array.</summary>
    property Include: TArray<TProfileScopeEntry> read FInclude;
    /// <summary>The parsed exclude list. Read-only: do not modify the array.</summary>
    property Exclude: TArray<TProfileScopeEntry> read FExclude;
    /// <summary>The source root, normalised (lowercase, no trailing
    /// separator); empty when none was given.</summary>
    property SourceRoot: string read FSourceRoot;
    /// <summary>Which rule decides what is in scope before exclusion.</summary>
    property Basis: TProfileScopeBasis read FBasis;
  end;

implementation

const
  KIND_NAMES: array[TProfileScopeKind] of string = ('module', 'unit', 'file', 'class', 'routine');
  PATH_SEPARATOR = '\';

function KindList: string;
begin
  Result := '';
  for var Kind := Low(TProfileScopeKind) to High(TProfileScopeKind) do begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + KIND_NAMES[Kind];
  end;
end;

function WithBackslashes(const Path: string): string;
begin
  Result := Path.Replace('/', PATH_SEPARATOR);
end;

// A drive path (`C:\...`) or a UNC path (`\\server\...`). A path relative to
// the current directory or to the current drive is not absolute: what it means
// depends on the process that asks.
function IsAbsolutePath(const Path: string): Boolean;
begin
  if Path.StartsWith('\\') then
    Exit(True);
  if Length(Path) < 3 then
    Exit(False);
  Result := CharInSet(Path[1], ['A'..'Z', 'a'..'z']) and (Path[2] = ':') and (Path[3] = PATH_SEPARATOR);
end;

{ TProfileScope: parsing }

class function TProfileScope.ParseEntry(const Text: string; out Entry: TProfileScopeEntry;
  out Problem: string): Boolean;
begin
  Entry := Default(TProfileScopeEntry);
  Entry.Text := Text;
  Entry.Kind := TProfileScopeKind.CodeUnit;
  Problem := '';

  var Trimmed := Text.Trim;
  var Pattern := Trimmed;
  var Colon := Trimmed.IndexOf(':');
  if Colon >= 0 then begin
    var KindText := Trimmed.Substring(0, Colon).Trim;
    Pattern := Trimmed.Substring(Colon + 1).Trim;
    var Known := False;
    for var Kind := Low(TProfileScopeKind) to High(TProfileScopeKind) do
      if SameText(KindText, KIND_NAMES[Kind]) then begin
        Entry.Kind := Kind;
        Known := True;
      end;
    if not Known then begin
      Problem := Format('unknown kind "%s" (expected one of: %s)', [KindText, KindList]);
      Exit(False);
    end;
  end;
  if Pattern = '' then begin
    Problem := 'empty pattern';
    Exit(False);
  end;

  Entry.Pattern := Pattern.ToLowerInvariant;
  if Entry.Kind = TProfileScopeKind.SourceFile then begin
    Entry.Pattern := WithBackslashes(Entry.Pattern);
    Entry.Qualified := Entry.Pattern.Contains(PATH_SEPARATOR);
  end else if Entry.Kind = TProfileScopeKind.Routine then begin
    var ClassPart, RoutinePart: string;
    SplitRoutineName(Entry.Pattern, ClassPart, RoutinePart);
    Entry.Qualified := ClassPart <> '';
  end;
  Result := True;
end;

procedure TProfileScope.ParseList(const ListName: string; const Entries: TArray<string>;
  var Parsed: TArray<TProfileScopeEntry>; Problems: TList<string>);
begin
  SetLength(Parsed, Length(Entries));
  var Count := 0;
  for var Text in Entries do begin
    var Problem: string;
    if ParseEntry(Text, Parsed[Count], Problem) then
      Inc(Count)
    else
      Problems.Add(Format('%s entry "%s": %s', [ListName, Text, Problem]));
  end;
  SetLength(Parsed, Count);
end;

procedure TProfileScope.LoadReferenceFiles(const Files: TArray<string>; Problems: TList<string>);
begin
  for var Text in Files do begin
    var Entry := WithBackslashes(Text.Trim);
    if Entry = '' then begin
      Problems.Add('reference file "": empty entry');
      Continue;
    end;
    if not Entry.Contains(PATH_SEPARATOR) and not Entry.Contains(':') then begin
      FReferenceNames.AddOrSetValue(Entry.ToLowerInvariant, True);
      Continue;
    end;
    var Path := NormalizedAbsolutePath(Entry);
    if Path = '' then begin
      Problems.Add(Format('reference file "%s": neither an absolute path nor a bare file name', [Text]));
      Continue;
    end;
    FReferencePaths.AddOrSetValue(Path, True);
  end;
end;

constructor TProfileScope.Create(const Options: TProfileScopeOptions);
begin
  inherited Create;
  FReferencePaths := TDictionary<string, Boolean>.Create;
  FReferenceNames := TDictionary<string, Boolean>.Create;
  var Problems := TList<string>.Create;
  try
    ParseList('include', Options.Include, FInclude, Problems);
    ParseList('exclude', Options.Exclude, FExclude, Problems);
    if Options.SourceRoot.Trim <> '' then begin
      FSourceRoot := NormalizedAbsolutePath(Options.SourceRoot);
      if FSourceRoot = '' then
        Problems.Add(Format('source root "%s": not an absolute path', [Options.SourceRoot]));
    end;
    if Options.HasReferenceFiles then
      LoadReferenceFiles(Options.ReferenceFiles, Problems);
    if Problems.Count > 0 then
      raise EProfileScopeError.Create(string.Join('; ', Problems.ToArray));
  finally
    Problems.Free;
  end;

  if Length(FInclude) > 0 then
    FBasis := TProfileScopeBasis.Patterns
  else if Options.HasReferenceFiles then
    FBasis := TProfileScopeBasis.ReferenceFiles
  else if FSourceRoot <> '' then
    FBasis := TProfileScopeBasis.SourceRoot
  else
    FBasis := TProfileScopeBasis.MainModule;
end;

destructor TProfileScope.Destroy;
begin
  FReferenceNames.Free;
  FReferencePaths.Free;
  inherited;
end;

class function TProfileScope.TryCreate(const Options: TProfileScopeOptions;
  out Scope: TProfileScope; out Error: string): Boolean;
begin
  Scope := nil;
  Error := '';
  try
    Scope := TProfileScope.Create(Options);
    Result := True;
  except
    on E: EProfileScopeError do begin
      Error := E.Message;
      Result := False;
    end;
  end;
end;

{ TProfileScope: matching }

class function TProfileScope.MatchesLowered(const Pattern, Text: string): Boolean;
// Greedy with one point of return: on a mismatch the last `*` swallows one
// more character. Linear in practice, never recursive.
begin
  var P := 1;
  var T := 1;
  var StarAt := 0;       // position of the last `*` in the pattern
  var StarText := 0;     // where in the text that `*` stopped swallowing
  while T <= Length(Text) do begin
    if (P <= Length(Pattern)) and (Pattern[P] = '*') then begin
      StarAt := P;
      StarText := T;
      Inc(P);
    end else if (P <= Length(Pattern)) and ((Pattern[P] = '?') or (Pattern[P] = Text[T])) then begin
      Inc(P);
      Inc(T);
    end else if StarAt > 0 then begin
      P := StarAt + 1;
      Inc(StarText);
      T := StarText;
    end else
      Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do
    Inc(P);
  Result := P > Length(Pattern);
end;

class function TProfileScope.Matches(const Pattern, Text: string): Boolean;
begin
  Result := MatchesLowered(Pattern.ToLowerInvariant, Text.ToLowerInvariant);
end;

class procedure TProfileScope.SplitRoutineName(const Name: string;
  out ClassPart, RoutinePart: string);
begin
  var Depth := 0;
  var LastDot := 0;
  for var I := 1 to Length(Name) do
    case Name[I] of
      '<', '{':
        Inc(Depth);
      '>', '}':
        if Depth > 0 then
          Dec(Depth);
      '.':
        if Depth = 0 then
          LastDot := I;
    end;
  ClassPart   := Copy(Name, 1, LastDot - 1);
  RoutinePart := Copy(Name, LastDot + 1, MaxInt);
end;

class function TProfileScope.NormalizedAbsolutePath(const Path: string): string;
// Lowercase, backslashes, `.` and `..` folded, no trailing separator. Empty
// when the path is not absolute.
begin
  var Work := WithBackslashes(Path.Trim);
  if not IsAbsolutePath(Work) then
    Exit('');
  Work := ExpandFileName(Work);
  while Work.EndsWith(PATH_SEPARATOR) do
    Work := Work.Substring(0, Length(Work) - 1);
  Result := Work.ToLowerInvariant;
end;

class function TProfileScope.IsPathUnder(const Root, Path: string): Boolean;
begin
  var NormalRoot := NormalizedAbsolutePath(Root);
  var NormalPath := NormalizedAbsolutePath(Path);
  if (NormalRoot = '') or (NormalPath = '') then
    Exit(False);
  Result := (NormalPath = NormalRoot) or NormalPath.StartsWith(NormalRoot + PATH_SEPARATOR);
end;

class function TProfileScope.HasKind(const Entries: TArray<TProfileScopeEntry>;
  Kind: TProfileScopeKind): Boolean;
begin
  for var Entry in Entries do
    if Entry.Kind = Kind then
      Exit(True);
  Result := False;
end;

class function TProfileScope.HasKindOtherThan(const Entries: TArray<TProfileScopeEntry>;
  First, Second: TProfileScopeKind): Boolean;
begin
  for var Entry in Entries do
    if (Entry.Kind <> First) and (Entry.Kind <> Second) then
      Exit(True);
  Result := False;
end;

class function TProfileScope.ModuleMatches(const Entries: TArray<TProfileScopeEntry>;
  const ModuleName: string): Boolean;
begin
  Result := False;
  if not HasKind(Entries, TProfileScopeKind.Module) then
    Exit;
  var FileName := ExtractFileName(WithBackslashes(ModuleName)).ToLowerInvariant;
  var Stem := ChangeFileExt(FileName, '');
  for var Entry in Entries do begin
    if Entry.Kind <> TProfileScopeKind.Module then
      Continue;
    if MatchesLowered(Entry.Pattern, FileName) or MatchesLowered(Entry.Pattern, Stem) then
      Exit(True);
  end;
end;

class function TProfileScope.UnitMatches(const Entries: TArray<TProfileScopeEntry>;
  const LoweredUnitName: string): Boolean;
begin
  for var Entry in Entries do
    if (Entry.Kind = TProfileScopeKind.CodeUnit) and MatchesLowered(Entry.Pattern, LoweredUnitName) then
      Exit(True);
  Result := False;
end;

class function TProfileScope.FileMatches(const Entries: TArray<TProfileScopeEntry>;
  const SourceFile: TCodeMapFile): Boolean;
begin
  Result := False;
  if not HasKind(Entries, TProfileScopeKind.SourceFile) then
    Exit;
  var Name := SourceFile.Name.ToLowerInvariant;
  // The best path there is: resolved, else recorded, else the name alone.
  var Path := SourceFile.ResolvedPath;
  if Path = '' then
    Path := SourceFile.RecordedPath;
  if Path = '' then
    Path := SourceFile.Name;
  Path := WithBackslashes(Path).ToLowerInvariant;
  for var Entry in Entries do begin
    if Entry.Kind <> TProfileScopeKind.SourceFile then
      Continue;
    if Entry.Qualified and MatchesLowered(Entry.Pattern, Path) then
      Exit(True);
    if not Entry.Qualified and MatchesLowered(Entry.Pattern, Name) then
      Exit(True);
  end;
end;

class function TProfileScope.RoutineMatches(const Entries: TArray<TProfileScopeEntry>;
  const LoweredName, LoweredClassPart, LoweredRoutinePart: string): Boolean;
begin
  for var Entry in Entries do
    case Entry.Kind of
      TProfileScopeKind.ClassName:
        if (LoweredClassPart <> '') and MatchesLowered(Entry.Pattern, LoweredClassPart) then
          Exit(True);
      TProfileScopeKind.Routine:
        begin
          if Entry.Qualified and MatchesLowered(Entry.Pattern, LoweredName) then
            Exit(True);
          if not Entry.Qualified and MatchesLowered(Entry.Pattern, LoweredRoutinePart) then
            Exit(True);
        end;
    end;
  Result := False;
end;

function TProfileScope.FileIsInReference(const SourceFile: TCodeMapFile): Boolean;
begin
  if FReferenceNames.ContainsKey(SourceFile.Name.ToLowerInvariant) then
    Exit(True);
  if FReferencePaths.Count = 0 then
    Exit(False);
  var Path := SourceFile.ResolvedPath;
  if Path = '' then
    Path := SourceFile.RecordedPath;
  var Normal := NormalizedAbsolutePath(Path);
  Result := (Normal <> '') and FReferencePaths.ContainsKey(Normal);
end;

function TProfileScope.FileIsUnderRoot(const SourceFile: TCodeMapFile): Boolean;
begin
  // FSourceRoot is normalised already, and must not be normalised twice: a
  // drive root loses its separator the first time (`C:\` becomes `c:`) and is
  // no longer an absolute path the second.
  var Normal := NormalizedAbsolutePath(SourceFile.ResolvedPath);
  if Normal = '' then
    Exit(False);
  Result := (Normal = FSourceRoot) or Normal.StartsWith(FSourceRoot + PATH_SEPARATOR);
end;

{ TProfileScope: decisions }

function TProfileScope.Evaluate(Map: TModuleCodeMap; IsMainModule: Boolean): TModuleScope;
var
  FileIn, FileOut, UnitIn, UnitOut, RoutineIn, RoutineOut: TArray<Boolean>;

  procedure DecideFiles;
  begin
    SetLength(FileIn, Length(Map.Files));
    SetLength(FileOut, Length(Map.Files));
    for var I := 0 to High(Map.Files) do begin
      FileOut[I] := FileMatches(FExclude, Map.Files[I]);
      case FBasis of
        TProfileScopeBasis.Patterns:       FileIn[I] := FileMatches(FInclude, Map.Files[I]);
        TProfileScopeBasis.ReferenceFiles: FileIn[I] := FileIsInReference(Map.Files[I]);
        TProfileScopeBasis.SourceRoot:     FileIn[I] := FileIsUnderRoot(Map.Files[I]);
      end;
    end;
  end;

  procedure DecideUnits;
  begin
    SetLength(UnitIn, Length(Map.Units));
    SetLength(UnitOut, Length(Map.Units));
    var Including := (FBasis = TProfileScopeBasis.Patterns) and HasKind(FInclude, TProfileScopeKind.CodeUnit);
    var Excluding := HasKind(FExclude, TProfileScopeKind.CodeUnit);
    if not Including and not Excluding then
      Exit;
    for var I := 0 to High(Map.Units) do begin
      var Lowered := Map.Units[I].ToLowerInvariant;
      UnitIn[I]  := Including and UnitMatches(FInclude, Lowered);
      UnitOut[I] := Excluding and UnitMatches(FExclude, Lowered);
    end;
  end;

  function NamesRoutines(const Entries: TArray<TProfileScopeEntry>): Boolean;
  begin
    Result := HasKind(Entries, TProfileScopeKind.ClassName) or HasKind(Entries, TProfileScopeKind.Routine);
  end;

  procedure DecideRoutines;
  begin
    SetLength(RoutineIn, Length(Map.Routines));
    SetLength(RoutineOut, Length(Map.Routines));
    var Including := (FBasis = TProfileScopeBasis.Patterns) and NamesRoutines(FInclude);
    var Excluding := NamesRoutines(FExclude);
    if not Including and not Excluding then
      Exit;
    var Routines := Map.Routines;
    for var I := 0 to High(Routines) do begin
      // A routine without line records cannot be in scope; its name is not read.
      if Routines[I].LineCount = 0 then
        Continue;
      var Lowered := Routines[I].Name.ToLowerInvariant;
      var ClassPart, RoutinePart: string;
      SplitRoutineName(Lowered, ClassPart, RoutinePart);
      RoutineIn[I]  := Including and RoutineMatches(FInclude, Lowered, ClassPart, RoutinePart);
      RoutineOut[I] := Excluding and RoutineMatches(FExclude, Lowered, ClassPart, RoutinePart);
    end;
  end;

begin
  if Map = nil then
    raise EArgumentNilException.Create('TProfileScope.Evaluate: no code map');
  Result := Default(TModuleScope);
  SetLength(Result.Lines, Length(Map.Lines));
  SetLength(Result.Routines, Length(Map.Routines));
  if ModuleMatches(FExclude, Map.ModuleName) then
    Exit;

  // What selects every record of the module at once.
  var WholeModule := False;
  case FBasis of
    TProfileScopeBasis.Patterns:   WholeModule := ModuleMatches(FInclude, Map.ModuleName);
    TProfileScopeBasis.MainModule: WholeModule := IsMainModule;
  end;
  DecideFiles;
  DecideUnits;
  DecideRoutines;

  var Lines := Map.Lines;
  for var I := 0 to High(Lines) do begin
    var Line := Lines[I];
    var Selected := WholeModule or FileIn[Line.FileIndex];
    var Rejected := FileOut[Line.FileIndex];
    if Line.UnitIndex >= 0 then begin
      Selected := Selected or UnitIn[Line.UnitIndex];
      Rejected := Rejected or UnitOut[Line.UnitIndex];
    end;
    if Line.RoutineIndex >= 0 then begin
      Selected := Selected or RoutineIn[Line.RoutineIndex];
      Rejected := Rejected or RoutineOut[Line.RoutineIndex];
    end;
    if Rejected or not Selected then
      Continue;
    if Line.RoutineIndex < 0 then begin
      Inc(Result.SelectedOutsideRoutineCount);
      Continue;
    end;
    Result.Lines[I] := True;
    Inc(Result.LineCount);
    if not Result.Routines[Line.RoutineIndex] then begin
      Result.Routines[Line.RoutineIndex] := True;
      Inc(Result.RoutineCount);
    end;
  end;
end;

function TProfileScope.ModuleMayHoldScope(const ModuleName: string; IsMainModule: Boolean;
  const UnitNames: TArray<string>; UnitNamesKnown: Boolean): Boolean;

  // Every line record belongs to one of the module's units, so a module whose
  // units are all excluded has nothing left.
  function EveryUnitIsExcluded: Boolean;
  begin
    if not UnitNamesKnown or (Length(UnitNames) = 0) then
      Exit(False);
    if not HasKind(FExclude, TProfileScopeKind.CodeUnit) then
      Exit(False);
    for var Name in UnitNames do
      if not UnitMatches(FExclude, Name.ToLowerInvariant) then
        Exit(False);
    Result := True;
  end;

  function SomeUnitIsIncludedAndNotExcluded: Boolean;
  begin
    for var Name in UnitNames do begin
      var Lowered := Name.ToLowerInvariant;
      if UnitMatches(FInclude, Lowered) and not UnitMatches(FExclude, Lowered) then
        Exit(True);
    end;
    Result := False;
  end;

begin
  if ModuleMatches(FExclude, ModuleName) then
    Exit(False);
  if EveryUnitIsExcluded then
    Exit(False);
  case FBasis of
    TProfileScopeBasis.MainModule:
      Exit(IsMainModule);
    // Decided by source files: no unit list says where a file's code went.
    TProfileScopeBasis.ReferenceFiles, TProfileScopeBasis.SourceRoot:
      Exit(True);
  end;

  if ModuleMatches(FInclude, ModuleName) then
    Exit(True);
  // A file, class or routine entry can match code of any module.
  if HasKindOtherThan(FInclude, TProfileScopeKind.Module, TProfileScopeKind.CodeUnit) then
    Exit(True);
  // Only module and unit entries are left, and no module entry matched.
  if not HasKind(FInclude, TProfileScopeKind.CodeUnit) then
    Exit(False);
  if not UnitNamesKnown then
    Exit(True);
  Result := SomeUnitIsIncludedAndNotExcluded;
end;

end.
