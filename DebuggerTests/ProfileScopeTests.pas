unit ProfileScopeTests;

// Tests for the profiling / coverage scope (DebuggerCore\ProfileScope.pas):
// the include / exclude grammar, the default scope, the reference set, and the
// module-level question asked before a module is parsed.
//
// No debug session. Two kinds of test:
//   * on a HAND-BUILT code map, where the grammar is pinned record by record
//     (the expectations there are the specification, written out);
//   * on the fixture binaries (TestTarget.exe and TestSubject.bpl, both
//     bitnesses), where the expectations are computed from the code map, the
//     file system and PACKAGEINFO rather than written by hand.
//
// A fixture-driven test collects its failures across the four binaries: both
// executables are called TestTarget.exe, so a first-failure abort would hide
// the other bitness.

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Generics.Collections,
  DebugInfoTypes, TD32FileReader, CodeMap, ProfileScope;

type
  // One fixture binary, loaded. Keep holds the reference that keeps the
  // reference-counted reader alive while it is also used as an object.
  TScopeBinary = record
    Caption:   string;
    Path:      string;
    IsPackage: Boolean;
    ImageSize: UInt64;
    Reader:    TTD32FileReader;
    Keep:      IInterface;
  end;

  TRoutinePredicate = reference to function(const Routine: TCodeMapRoutine): Boolean;

  [TestFixture]
  TProfileScopeTests = class
  private
    FProblems: TList<string>;
    function  FixtureRoot: string;
    function  SourceDir: string;
    function  LoadOne(const Caption, RelativePath: string; IsPackage: Boolean): TScopeBinary;
    function  LoadBinaries: TArray<TScopeBinary>;
    function  BuildMap(const Binary: TScopeBinary; Resolve: Boolean = True): TModuleCodeMap;
    function  SyntheticMap: TModuleCodeMap;
    function  Selected(const Options: TProfileScopeOptions; IsMainModule: Boolean = False): string;
    function  SelectedBy(const Include: TArray<string>; const Exclude: TArray<string> = nil): string;
    function  SelectedUnder(const SourceRoot: string; const Exclude: TArray<string> = nil): string;
    function  SelectedByReference(const Files: TArray<string>): string;
    function  ErrorOf(const Options: TProfileScopeOptions): string;
    function  MayHold(const Include, Exclude: TArray<string>; const ModuleName: string;
      IsMainModule: Boolean; const UnitNames: TArray<string>; UnitNamesKnown: Boolean): Boolean;
    function  Evaluate(Map: TModuleCodeMap; const Options: TProfileScopeOptions;
      IsMainModule: Boolean): TModuleScope;
    function  ExpectedByRoutine(Map: TModuleCodeMap; const Wanted: TRoutinePredicate): TArray<Boolean>;
    function  CountOf(const Flags: TArray<Boolean>): Integer;
    procedure Check(Condition: Boolean; const Problem: string);
    procedure CheckDecision(const Caption: string; Map: TModuleCodeMap; const Decision: TModuleScope;
      const Expected: TArray<Boolean>);
    procedure CheckPattern(const Caption, Entry: string; Map: TModuleCodeMap; const Wanted: TRoutinePredicate);
    procedure CheckDefaultScope(const Binary: TScopeBinary);
    procedure CheckReferenceScope(const Caption: string; const Reference, Measured: TScopeBinary;
      Resolve: Boolean);
    procedure AssertNoProblems;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // --- the grammar, with no code map ---
    [Test] procedure Grammar_EachKindAndTheBarePattern_Parse;
    [Test] procedure Grammar_MalformedEntries_AreRejectedByName;
    [Test] procedure Wildcards_StarAndQuestionMark_IgnoreCase;
    [Test] procedure SplitRoutineName_AsEachProviderSpellsIt;
    [Test] procedure IsPathUnder_IsAPathPrefixNotATextPrefix;

    // --- the decision on a hand-built code map ---
    [Test] procedure Patterns_EachKindSelectsItsRecords;
    [Test] procedure Exclusion_WinsOverInclusion;
    [Test] procedure RoutineWithoutLineRecords_IsNeverInScope;
    [Test] procedure SourceRoot_SelectsFilesResolvedUnderIt;
    [Test] procedure NoSourceRoot_SelectsTheMainModuleOnly;
    [Test] procedure ReferenceSet_ReplacesTheDefault;
    [Test] procedure ModuleQuestion_RulesOutOnlyWhatItCan;

    // --- on the fixture binaries ---
    [Test] procedure DefaultScope_Executable_OwnSourcesInOthersOut;
    [Test] procedure DefaultScope_Package_OwnSourcesInOthersOut;
    [Test] procedure NoSourceRoot_OnTheFixtures_EveryRecordOfTheMainModule;
    [Test] procedure ReferenceSet_OnTheFixtures_ThePackageSourcesInTheExecutable;
    [Test] procedure RecordsOutsideEveryRoutine_AreNeverInScope;
    [Test] procedure ClassAndRoutinePatterns_FollowTheProvidersNames;
    [Test] procedure UnitPattern_TakesGenericCodeTheFilePatternLeavesOut;
    [Test] procedure SplitRoutineName_ReassemblesEveryFixtureRoutine;
    [Test] procedure ModuleQuestion_OnThePackage_AgreesWithPackageInfoAndTheCodeMap;
  end;

implementation

uses
  System.StrUtils, System.IOUtils,
  PeSymbolSupport, PackageInfoReader;

const
  MAX_PROBLEMS_SHOWN = 25;
  // Where the fixture resolver puts every source file that is not one of the
  // fixture's own: a path that is not under the fixture's source directory.
  ELSEWHERE = 'C:\not-the-project\source\';

  // The hand-built module. See SyntheticMap for the table these come from.
  SYNTHETIC_MODULE = 'Fake.bpl';
  ALL_IN_ROUTINES  = '100,150,200,300,350,400,500,550,560';

type
  // Hand-built tables: the cases whose expectations are the specification.
  TFakeScopeTables = class(TInterfacedObject, ILineRecordProvider, IRoutineRangeProvider)
  public
    Table:  TLineRecordTable;
    Ranges: TArray<TRoutineRange>;
    function LineRecordTable(out Complete: Boolean): TLineRecordTable;
    function RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
  end;

function TFakeScopeTables.LineRecordTable(out Complete: Boolean): TLineRecordTable;
begin
  Complete := True;
  Result := Table;
  Result.Records := Copy(Table.Records);
end;

function TFakeScopeTables.RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
begin
  Complete := True;
  Result := Copy(Ranges);
end;

function Options(const Include: TArray<string>; const Exclude: TArray<string> = nil): TProfileScopeOptions;
begin
  Result := Default(TProfileScopeOptions);
  Result.Include := Include;
  Result.Exclude := Exclude;
end;

// A routine named `<ClassName>.<Method>`, with nothing nested in between.
function IsMethodOf(const ClassName, RoutineName: string): Boolean;
begin
  var Prefix := ClassName + '.';
  if not StartsText(Prefix, RoutineName) then
    Exit(False);
  Result := PosEx('.', RoutineName, Length(Prefix) + 1) = 0;
end;

{ TProfileScopeTests: plumbing }

procedure TProfileScopeTests.Setup;
begin
  FProblems := TList<string>.Create;
end;

procedure TProfileScopeTests.TearDown;
begin
  FreeAndNil(FProblems);
end;

procedure TProfileScopeTests.Check(Condition: Boolean; const Problem: string);
begin
  if not Condition then
    FProblems.Add(Problem);
end;

procedure TProfileScopeTests.AssertNoProblems;
begin
  if FProblems.Count = 0 then
    Exit;
  var Text := TStringBuilder.Create;
  try
    Text.AppendFormat('%d problem(s):', [FProblems.Count]);
    for var I := 0 to FProblems.Count - 1 do begin
      if I = MAX_PROBLEMS_SHOWN then begin
        Text.AppendLine.Append('  ...');
        Break;
      end;
      Text.AppendLine.Append('  ').Append(FProblems[I]);
    end;
    Assert.Fail(Text.ToString);
  finally
    Text.Free;
  end;
end;

function TProfileScopeTests.FixtureRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\');
end;

function TProfileScopeTests.SourceDir: string;
begin
  Result := FixtureRoot + 'TestTarget\';
end;

function TProfileScopeTests.LoadOne(const Caption, RelativePath: string; IsPackage: Boolean): TScopeBinary;
begin
  Result := Default(TScopeBinary);
  Result.Caption   := Caption;
  Result.Path      := FixtureRoot + RelativePath;
  Result.IsPackage := IsPackage;
  if not TFile.Exists(Result.Path) then
    Assert.Fail(Format('%s fixture not found at %s -- run build_and_run.bat', [Caption, Result.Path]));
  Result.ImageSize := ReadPEImageSize(Result.Path);
  Result.Reader := TTD32FileReader.Create;
  Result.Keep   := Result.Reader;
  Result.Reader.LoadFromFile(Result.Path, 0);
end;

function TProfileScopeTests.LoadBinaries: TArray<TScopeBinary>;
begin
  Result := [
    LoadOne('exe x64', 'TestTarget\Win64\Debug\TestTarget.exe', False),
    LoadOne('exe x86', 'TestTarget\Win32\Debug\TestTarget.exe', False),
    LoadOne('bpl x64', 'TestHost\Win64\Debug\TestSubject.bpl', True),
    LoadOne('bpl x86', 'TestHost\Win32\Debug\TestSubject.bpl', True)];
end;

function TProfileScopeTests.BuildMap(const Binary: TScopeBinary; Resolve: Boolean): TModuleCodeMap;
// The injected resolver: a file that exists in the fixture's source directory
// is there, every other file is somewhere else.
begin
  var Resolver: TCodeMapPathResolver := nil;
  if Resolve then begin
    var Own := SourceDir;
    Resolver :=
      function(const FileName, RecordedPath: string): string
      begin
        if TFile.Exists(Own + FileName) then
          Exit(Own + FileName);
        Result := ELSEWHERE + FileName;
      end;
  end;
  Result := TModuleCodeMap.Build(ExtractFileName(Binary.Path), Binary.Reader, Binary.Reader, 0,
    Binary.ImageSize, Resolver);
end;

function TProfileScopeTests.SyntheticMap: TModuleCodeMap;
// One module, two units, five source files:
//
//   file       resolved            recorded        records (address: routine)
//   A.pas      C:\src\A.pas                        90: none   100,150: TWidget.Create
//                                                  200: TWidget.Destroy   650: none
//   B.pas      c:/SRC/sub/B.pas                    300: Helper   400: TOuter.TInner.Run
//   Gen.pas    C:\src2\Gen.pas                     350: Helper   500: TList__1<System.Integer>.Add
//   Rtl.pas    (not resolved)      D:\rtl\Rtl.pas  550: TList__1<System.Integer>.Add
//   Loose.pas  (not resolved)                      560: TList__1<System.Integer>.Add
//
// Unit UnitA holds 90..350 and 650, unit Vendor.UnitB holds 400..560. The
// routine NoLines has no record at all.

  function Routine(StartRva, EndRva: UInt64; const Name, UnitName: string): TRoutineRange;
  begin
    Result := Default(TRoutineRange);
    Result.StartRva := StartRva;
    Result.EndRva   := EndRva;
    Result.Name     := Name;
    Result.UnitName := UnitName;
  end;

  function Line(Rva: UInt64; FileIndex, LineNumber, UnitIndex: Integer): TLineRecord;
  begin
    Result.Rva       := Rva;
    Result.FileIndex := FileIndex;
    Result.Line      := LineNumber;
    Result.UnitIndex := UnitIndex;
  end;

const
  FILE_A = 0; FILE_B = 1; FILE_GEN = 2; FILE_RTL = 3; FILE_LOOSE = 4;
  UNIT_A = 0; UNIT_B = 1;
begin
  var Fake := TFakeScopeTables.Create;
  var Keep: IInterface := Fake;
  Fake.Ranges := [
    Routine(100, 200, 'TWidget.Create', 'UnitA'),
    Routine(200, 300, 'TWidget.Destroy', 'UnitA'),
    Routine(300, 400, 'Helper', 'UnitA'),
    Routine(400, 500, 'TOuter.TInner.Run', 'Vendor.UnitB'),
    Routine(500, 600, 'TList__1<System.Integer>.Add', 'Vendor.UnitB'),
    Routine(700, 800, 'NoLines', 'UnitA')];
  SetLength(Fake.Table.Files, 5);
  Fake.Table.Files[FILE_A].Name     := 'A.pas';
  Fake.Table.Files[FILE_B].Name     := 'B.pas';
  Fake.Table.Files[FILE_GEN].Name   := 'Gen.pas';
  Fake.Table.Files[FILE_RTL].Name   := 'Rtl.pas';
  Fake.Table.Files[FILE_RTL].FullPath := 'D:\rtl\Rtl.pas';
  Fake.Table.Files[FILE_LOOSE].Name := 'Loose.pas';
  Fake.Table.Units := ['UnitA', 'Vendor.UnitB'];
  Fake.Table.Records := [
    Line(90, FILE_A, 1, UNIT_A),
    Line(100, FILE_A, 10, UNIT_A),
    Line(150, FILE_A, 11, UNIT_A),
    Line(200, FILE_A, 20, UNIT_A),
    Line(300, FILE_B, 5, UNIT_A),
    Line(350, FILE_GEN, 7, UNIT_A),
    Line(400, FILE_B, 30, UNIT_B),
    Line(500, FILE_GEN, 40, UNIT_B),
    Line(550, FILE_RTL, 9, UNIT_B),
    Line(560, FILE_LOOSE, 3, UNIT_B),
    Line(650, FILE_A, 99, UNIT_A)];
  Result := TModuleCodeMap.Build(SYNTHETIC_MODULE, Fake, Fake, 0, $1000,
    function(const FileName, RecordedPath: string): string
    begin
      Result := '';
      if FileName = 'A.pas' then
        Result := 'C:\src\A.pas'
      else if FileName = 'B.pas' then
        Result := 'c:/SRC/sub/B.pas'
      else if FileName = 'Gen.pas' then
        Result := 'C:\src2\Gen.pas';
    end);
end;

function TProfileScopeTests.Selected(const Options: TProfileScopeOptions; IsMainModule: Boolean): string;
// The addresses of the synthetic map's records that are in scope, in order.
// Also holds the decision to its own arithmetic: the counts are the flags
// counted, and a routine is flagged exactly when one of its records is.
begin
  Result := '';
  var Map := SyntheticMap;
  var Scope := TProfileScope.Create(Options);
  try
    var Decision := Scope.Evaluate(Map, IsMainModule);
    Assert.AreEqual(Integer(Length(Map.Lines)), Integer(Length(Decision.Lines)), 'one flag per line record');
    Assert.AreEqual(Integer(Length(Map.Routines)), Integer(Length(Decision.Routines)), 'one flag per routine');
    var LineCount := 0;
    for var I := 0 to High(Map.Lines) do begin
      if not Decision.Lines[I] then
        Continue;
      Assert.IsTrue(Map.Lines[I].InRoutine, Format('the record at %d is outside every routine', [Map.Lines[I].Rva]));
      if Result <> '' then
        Result := Result + ',';
      Result := Result + IntToStr(Map.Lines[I].Rva);
      Inc(LineCount);
    end;
    Assert.AreEqual(LineCount, Decision.LineCount, 'LineCount');
    var RoutineCount := 0;
    for var R := 0 to High(Map.Routines) do begin
      var HasRecord := False;
      for var Offset := 0 to Map.Routines[R].LineCount - 1 do
        HasRecord := HasRecord or Decision.Lines[Map.Routines[R].FirstLine + Offset];
      Assert.AreEqual(HasRecord, Decision.Routines[R], 'routine flag of ' + Map.Routines[R].Name);
      if HasRecord then
        Inc(RoutineCount);
    end;
    Assert.AreEqual(RoutineCount, Decision.RoutineCount, 'RoutineCount');
  finally
    Scope.Free;
    Map.Free;
  end;
end;

function TProfileScopeTests.SelectedBy(const Include, Exclude: TArray<string>): string;
begin
  Result := Selected(Options(Include, Exclude));
end;

function TProfileScopeTests.SelectedUnder(const SourceRoot: string; const Exclude: TArray<string>): string;
begin
  var Given := Options(nil, Exclude);
  Given.SourceRoot := SourceRoot;
  Result := Selected(Given);
end;

function TProfileScopeTests.SelectedByReference(const Files: TArray<string>): string;
begin
  var Given := Default(TProfileScopeOptions);
  Given.HasReferenceFiles := True;
  Given.ReferenceFiles    := Files;
  Result := Selected(Given);
end;

function TProfileScopeTests.ErrorOf(const Options: TProfileScopeOptions): string;
begin
  var Scope: TProfileScope;
  if TProfileScope.TryCreate(Options, Scope, Result) then begin
    Scope.Free;
    Exit('');
  end;
  Assert.IsNull(Scope, 'a failed TryCreate returns no scope');
  Assert.AreNotEqual('', Result, 'a failed TryCreate says why');
end;

function TProfileScopeTests.MayHold(const Include, Exclude: TArray<string>; const ModuleName: string;
  IsMainModule: Boolean; const UnitNames: TArray<string>; UnitNamesKnown: Boolean): Boolean;
begin
  var Scope := TProfileScope.Create(Options(Include, Exclude));
  try
    Result := Scope.ModuleMayHoldScope(ModuleName, IsMainModule, UnitNames, UnitNamesKnown);
  finally
    Scope.Free;
  end;
end;

function TProfileScopeTests.Evaluate(Map: TModuleCodeMap; const Options: TProfileScopeOptions;
  IsMainModule: Boolean): TModuleScope;
begin
  var Scope := TProfileScope.Create(Options);
  try
    Result := Scope.Evaluate(Map, IsMainModule);
  finally
    Scope.Free;
  end;
end;

function TProfileScopeTests.ExpectedByRoutine(Map: TModuleCodeMap;
  const Wanted: TRoutinePredicate): TArray<Boolean>;
begin
  SetLength(Result, Length(Map.Lines));
  for var I := 0 to High(Map.Lines) do
    Result[I] := Map.Lines[I].InRoutine and Wanted(Map.Routines[Map.Lines[I].RoutineIndex]);
end;

function TProfileScopeTests.CountOf(const Flags: TArray<Boolean>): Integer;
begin
  Result := 0;
  for var Flag in Flags do
    if Flag then
      Inc(Result);
end;

procedure TProfileScopeTests.CheckDecision(const Caption: string; Map: TModuleCodeMap;
  const Decision: TModuleScope; const Expected: TArray<Boolean>);
// Every line flag against the expectation, then the decision's own arithmetic.
begin
  Check(Length(Decision.Lines) = Length(Map.Lines),
    Format('%s: %d line flags for %d records', [Caption, Length(Decision.Lines), Length(Map.Lines)]));
  Check(Length(Decision.Routines) = Length(Map.Routines),
    Format('%s: %d routine flags for %d routines', [Caption, Length(Decision.Routines), Length(Map.Routines)]));
  if (Length(Decision.Lines) <> Length(Map.Lines)) or (Length(Decision.Routines) <> Length(Map.Routines)) then
    Exit;
  var RoutineHasRecord: TArray<Boolean>;
  SetLength(RoutineHasRecord, Length(Map.Routines));
  for var I := 0 to High(Map.Lines) do begin
    var Line := Map.Lines[I];
    if Decision.Lines[I] <> Expected[I] then
      Check(False, Format('%s: %s:%d at $%x in scope: %s, expected %s', [Caption, Map.Files[Line.FileIndex].Name,
        Line.Line, Line.Rva, BoolToStr(Decision.Lines[I], True), BoolToStr(Expected[I], True)]));
    if Decision.Lines[I] and Line.InRoutine then
      RoutineHasRecord[Line.RoutineIndex] := True;
    Check(Line.InRoutine or not Decision.Lines[I],
      Format('%s: the record at $%x is outside every routine and in scope', [Caption, Line.Rva]));
  end;
  Check(Decision.LineCount = CountOf(Decision.Lines),
    Format('%s: LineCount %d, %d flags set', [Caption, Decision.LineCount, CountOf(Decision.Lines)]));
  for var R := 0 to High(Map.Routines) do
    if Decision.Routines[R] <> RoutineHasRecord[R] then
      Check(False, Format('%s: routine %s flagged %s, a record of it in scope: %s', [Caption, Map.Routines[R].Name,
        BoolToStr(Decision.Routines[R], True), BoolToStr(RoutineHasRecord[R], True)]));
  Check(Decision.RoutineCount = CountOf(Decision.Routines),
    Format('%s: RoutineCount %d, %d flags set', [Caption, Decision.RoutineCount, CountOf(Decision.Routines)]));
end;

procedure TProfileScopeTests.CheckPattern(const Caption, Entry: string; Map: TModuleCodeMap;
  const Wanted: TRoutinePredicate);
begin
  var Expected := ExpectedByRoutine(Map, Wanted);
  Check(CountOf(Expected) > 0,
    Format('%s: no record is expected for "%s", so the check proves nothing', [Caption, Entry]));
  Check(CountOf(Expected) < Length(Map.Lines) - Map.OutsideRoutineCount,
    Format('%s: "%s" is expected to select everything, so the check proves nothing', [Caption, Entry]));
  CheckDecision(Format('%s, %s', [Caption, Entry]), Map, Evaluate(Map, Options([Entry]), False), Expected);
end;

{ The grammar }

procedure TProfileScopeTests.Grammar_EachKindAndTheBarePattern_Parse;

  procedure Expect(const Text: string; Kind: TProfileScopeKind; const Pattern: string; Qualified: Boolean);
  begin
    var Entry: TProfileScopeEntry;
    var Problem: string;
    Assert.IsTrue(TProfileScope.ParseEntry(Text, Entry, Problem), Format('"%s": %s', [Text, Problem]));
    Assert.AreEqual('', Problem, Text);
    Assert.AreEqual(Text, Entry.Text, False, 'the entry is kept as given');
    Assert.IsTrue(Kind = Entry.Kind, Format('"%s": kind %d', [Text, Ord(Entry.Kind)]));
    Assert.AreEqual(Pattern, Entry.Pattern, False, Text);
    Assert.AreEqual(Qualified, Entry.Qualified, Text + ': qualified');
  end;

begin
  Expect('module:TestSubject.bpl', TProfileScopeKind.Module, 'testsubject.bpl', False);
  Expect('unit:System.SysUtils', TProfileScopeKind.CodeUnit, 'system.sysutils', False);
  Expect('file:Unit1.pas', TProfileScopeKind.SourceFile, 'unit1.pas', False);
  Expect('class:TWidget', TProfileScopeKind.ClassName, 'twidget', False);
  Expect('routine:DoWork', TProfileScopeKind.Routine, 'dowork', False);
  // A bare pattern is a unit.
  Expect('Vcl.*', TProfileScopeKind.CodeUnit, 'vcl.*', False);
  // The kind is not case-sensitive, and blanks around either part are dropped.
  Expect('  ROUTINE :  TWidget.Create  ', TProfileScopeKind.Routine, 'twidget.create', True);
  Expect('File:x.pas', TProfileScopeKind.SourceFile, 'x.pas', False);
  // The kind ends at the FIRST colon: a drive letter belongs to the pattern.
  Expect('file:C:\src\*.pas', TProfileScopeKind.SourceFile, 'c:\src\*.pas', True);
  Expect('file:sub/dir/*.inc', TProfileScopeKind.SourceFile, 'sub\dir\*.inc', True);
  // A routine pattern is qualified by a dot OUTSIDE the brackets only.
  Expect('routine:TList<System.Integer>', TProfileScopeKind.Routine, 'tlist<system.integer>', False);
  Expect('routine:*.Create', TProfileScopeKind.Routine, '*.create', True);

  var Scope := TProfileScope.Create(Options(['unit:A', 'B'], ['class:C']));
  try
    Assert.AreEqual(2, Integer(Length(Scope.Include)));
    Assert.AreEqual(1, Integer(Length(Scope.Exclude)));
    Assert.IsTrue(Scope.Basis = TProfileScopeBasis.Patterns);
    Assert.AreEqual('', Scope.SourceRoot);
  finally
    Scope.Free;
  end;
end;

procedure TProfileScopeTests.Grammar_MalformedEntries_AreRejectedByName;

  procedure ExpectRejected(const Text, Reason: string);
  begin
    var Entry: TProfileScopeEntry;
    var Problem: string;
    Assert.IsFalse(TProfileScope.ParseEntry(Text, Entry, Problem), Format('"%s" was accepted', [Text]));
    Assert.Contains(Problem, Reason, Text);
  end;

begin
  ExpectRejected('bogus:Foo', 'unknown kind "bogus"');
  ExpectRejected('units:Foo', 'unknown kind "units"');
  ExpectRejected(':Foo', 'unknown kind ""');
  // A path with no kind is not a unit: its drive letter is read as the kind.
  ExpectRejected('C:\src\Unit1.pas', 'unknown kind "C"');
  ExpectRejected('unit:', 'empty pattern');
  ExpectRejected('file:   ', 'empty pattern');
  ExpectRejected('', 'empty pattern');
  ExpectRejected('   ', 'empty pattern');

  // A scope names the list and the entry, and every offender at once.
  var Error := ErrorOf(Options(['unit:Good', 'bogus:Foo', 'class:'], ['nope:Bar']));
  Assert.Contains(Error, 'include entry "bogus:Foo"');
  Assert.Contains(Error, 'unknown kind "bogus"');
  Assert.Contains(Error, 'include entry "class:"');
  Assert.Contains(Error, 'exclude entry "nope:Bar"');
  Assert.IsFalse(Error.Contains('unit:Good'), 'a well-formed entry is not reported');
  Assert.Contains(Error, 'module, unit, file, class, routine', 'the message lists the kinds there are');

  Assert.WillRaise(
    procedure
    begin
      TProfileScope.Create(Options(['bogus:Foo'])).Free;
    end, EProfileScopeError);

  // A source root must be an absolute path: a relative one would mean
  // something different in every process.
  var Relative := Default(TProfileScopeOptions);
  Relative.SourceRoot := 'src\project';
  Assert.Contains(ErrorOf(Relative), 'source root "src\project"');
  Relative.SourceRoot := 'C:project';
  Assert.Contains(ErrorOf(Relative), 'source root "C:project"');

  // A reference file is an absolute path or a bare name.
  var Reference := Default(TProfileScopeOptions);
  Reference.HasReferenceFiles := True;
  Reference.ReferenceFiles := ['C:\src\A.pas', 'Loose.pas', 'sub\B.pas', ''];
  Error := ErrorOf(Reference);
  Assert.Contains(Error, 'reference file "sub\B.pas"');
  Assert.Contains(Error, 'reference file ""');
  Assert.IsFalse(Error.Contains('A.pas'), 'an absolute path is accepted');
  Assert.IsFalse(Error.Contains('Loose.pas'), 'a bare name is accepted');
  // The same list is not looked at when it is not a reference set.
  Reference.HasReferenceFiles := False;
  Assert.AreEqual('', ErrorOf(Reference));
end;

procedure TProfileScopeTests.Wildcards_StarAndQuestionMark_IgnoreCase;

  procedure Expect(const Pattern, Text: string; Matching: Boolean);
  begin
    Assert.AreEqual(Matching, TProfileScope.Matches(Pattern, Text), Format('"%s" against "%s"', [Pattern, Text]));
  end;

begin
  Expect('abc', 'abc', True);
  Expect('abc', 'ABC', True);
  Expect('ABC', 'abc', True);
  Expect('abc', 'abcd', False);
  Expect('abc', 'ab', False);
  Expect('', '', True);
  Expect('', 'a', False);
  Expect('*', '', True);
  Expect('*', 'anything.at.all', True);
  Expect('a*', 'a', True);
  Expect('a*', 'abc', True);
  Expect('a*', 'ba', False);
  Expect('*c', 'abc', True);
  Expect('*c', 'abcd', False);
  Expect('a*c', 'ac', True);
  Expect('a*c', 'abbbc', True);
  Expect('a*c', 'abcb', False);
  Expect('*b*', 'abc', True);
  Expect('*b*', 'ac', False);
  Expect('a**c', 'abc', True);
  // The star must be able to give characters back.
  Expect('*ab', 'aab', True);
  Expect('*.pas', 'Unit.pas.pas', True);
  Expect('a*b*c', 'axbxbxc', True);
  Expect('a*b*c', 'axbxbx', False);
  Expect('?', 'a', True);
  Expect('?', '', False);
  Expect('?', 'ab', False);
  Expect('a?c', 'abc', True);
  Expect('a?c', 'ac', False);
  Expect('??', 'ab', True);
  Expect('*?', 'a', True);
  Expect('*?', '', False);
  Expect('T*.Create', 'TWidget.Create', True);
  Expect('T*.Create', 'TWidget.CreateFmt', False);
  // Nothing but `*` and `?` is special.
  Expect('TList<[a]>', 'TList<[a]>', True);
  Expect('TList<[a]>', 'TList<a>', False);
  Expect('a.c', 'abc', False);
end;

procedure TProfileScopeTests.SplitRoutineName_AsEachProviderSpellsIt;

  procedure Expect(const Name, ClassPart, RoutinePart: string);
  begin
    var GotClass, GotRoutine: string;
    TProfileScope.SplitRoutineName(Name, GotClass, GotRoutine);
    Assert.AreEqual(ClassPart, GotClass, False, Name + ': class part');
    Assert.AreEqual(RoutinePart, GotRoutine, False, Name + ': routine part');
  end;

begin
  // TD32.
  Expect('TWidget.Create', 'TWidget', 'Create');
  Expect('InnerNested', '', 'InnerNested');
  Expect('TList__1<Integer>.Pack', 'TList__1<Integer>', 'Pack');
  Expect('TDictionary__2<Integer, System.UnicodeString>.Create',
    'TDictionary__2<Integer, System.UnicodeString>', 'Create');
  Expect('TOuter.TInner.Run', 'TOuter.TInner', 'Run');
  // TD32 of a 32-bit image: a generic instantiation keeps its mangled name.
  Expect('%TList__1.Add$qqrxp40System@Generics@Collections@%TList__1$i%',
    '%TList__1', 'Add$qqrxp40System@Generics@Collections@%TList__1$i%');
  Expect('%TDictionary__2.$bctr$qqrv', '%TDictionary__2', '$bctr$qqrv');
  // MAP and JDBG.
  Expect('{System.Generics.Collections}TList<System.Integer>.Add',
    '{System.Generics.Collections}TList<System.Integer>', 'Add');
  Expect('RunTypeSampler$ActRec.$0$Body', 'RunTypeSampler$ActRec', '$0$Body');
  Expect('TPoint2D.&op_Addition', 'TPoint2D', '&op_Addition');
  Expect('Finalization', '', 'Finalization');
  // What the MAP reader leaves of a routine in a unit with a dotted name.
  Expect('SysUtils.TEncoding.GetBytes', 'SysUtils.TEncoding', 'GetBytes');
  // A dot inside brackets never splits; an unmatched closing bracket is ignored.
  Expect('TList<System.Integer>', '', 'TList<System.Integer>');
  Expect('Odd>.Name', 'Odd>', 'Name');
  Expect('', '', '');
end;

procedure TProfileScopeTests.IsPathUnder_IsAPathPrefixNotATextPrefix;

  procedure Expect(const Root, Path: string; Under: Boolean);
  begin
    Assert.AreEqual(Under, TProfileScope.IsPathUnder(Root, Path), Format('"%s" under "%s"', [Path, Root]));
  end;

begin
  Expect('C:\src', 'C:\src\Unit1.pas', True);
  Expect('C:\src', 'C:\src\sub\deeper\Unit1.pas', True);
  Expect('C:\src', 'C:\src', True);
  // The prefix ends at a separator.
  Expect('C:\src', 'C:\src2\Unit1.pas', False);
  Expect('C:\src', 'C:\srcUnit1.pas', False);
  Expect('C:\src', 'C:\sr\Unit1.pas', False);
  Expect('C:\src', 'C:\other\src\Unit1.pas', False);
  // Case, the kind of separator and a trailing one do not matter.
  Expect('c:\SRC\', 'C:\src\Unit1.pas', True);
  Expect('C:/src/', 'c:\SRC\Unit1.pas', True);
  Expect('C:\src', 'C:/src/sub/Unit1.pas', True);
  // `.` and `..` are folded before the comparison.
  Expect('C:\src\sub\..', 'C:\src\Unit1.pas', True);
  Expect('C:\src', 'C:\src\..\src2\Unit1.pas', False);
  Expect('C:\src', 'C:\other\..\src\Unit1.pas', True);
  // A drive root, and a share.
  Expect('C:\', 'C:\anything\Unit1.pas', True);
  Expect('C:\', 'D:\anything\Unit1.pas', False);
  Expect('\\server\share\src', '\\server\share\src\Unit1.pas', True);
  Expect('\\server\share\src', '\\server\share\src2\Unit1.pas', False);
  // A path that is not absolute is under nothing, and nothing is under it.
  Expect('C:\src', 'Unit1.pas', False);
  Expect('C:\src', 'src\Unit1.pas', False);
  Expect('C:\src', '', False);
  Expect('src', 'src\Unit1.pas', False);
  Expect('', 'C:\src\Unit1.pas', False);
end;

{ The decision on a hand-built code map }

procedure TProfileScopeTests.Patterns_EachKindSelectsItsRecords;
const
  NOTHING = '';
begin
  // module: the file name, with or without the extension.
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['module:Fake.bpl']));
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['module:fake']));
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['module:F?KE.*']));
  Assert.AreEqual(NOTHING, SelectedBy(['module:Other.bpl']));
  Assert.AreEqual(NOTHING, SelectedBy(['module:Fake.exe']));

  // unit: the whole unit name; a bare pattern is a unit.
  Assert.AreEqual('100,150,200,300,350', SelectedBy(['unit:UnitA']));
  Assert.AreEqual('100,150,200,300,350', SelectedBy(['unita']));
  Assert.AreEqual('400,500,550,560', SelectedBy(['Vendor.*']));
  Assert.AreEqual('400,500,550,560', SelectedBy(['*.UnitB']));
  Assert.AreEqual(NOTHING, SelectedBy(['unit:UnitB']), 'the last segment alone is not the unit name');
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['unit:*']));

  // file: without a separator, the file name.
  Assert.AreEqual('100,150,200', SelectedBy(['file:a.pas']));
  Assert.AreEqual('350,500', SelectedBy(['file:Gen.pas']));
  Assert.AreEqual('560', SelectedBy(['file:Loose.pas']));
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['file:*.pas']));
  // file: with a separator, the resolved path, else the recorded one, else the name.
  Assert.AreEqual('100,150,200,300,400', SelectedBy(['file:C:\src\*']), 'C:\src2 is another directory');
  Assert.AreEqual('300,400', SelectedBy(['file:c:/src/sub/*']), 'either separator, on either side');
  Assert.AreEqual('350,500', SelectedBy(['file:*\src2\*']));
  Assert.AreEqual('550', SelectedBy(['file:D:\rtl\*']), 'the recorded path of a file that did not resolve');
  Assert.AreEqual(NOTHING, SelectedBy(['file:*\Loose.pas']), 'a file with no path has no separator to match');
  Assert.AreEqual(NOTHING, SelectedBy(['file:C:\src']), 'the whole path must match');

  // class: the class part of the routine name.
  Assert.AreEqual('100,150,200', SelectedBy(['class:TWidget']));
  Assert.AreEqual('100,150,200', SelectedBy(['class:twidget']));
  Assert.AreEqual('100,150,200,400,500,550,560', SelectedBy(['class:*']), 'Helper has no class part');
  Assert.AreEqual(NOTHING, SelectedBy(['class:TOuter']), 'a nested class is named with its outer class');
  Assert.AreEqual('400', SelectedBy(['class:TOuter*']));
  Assert.AreEqual('400', SelectedBy(['class:TOuter.TInner']));
  Assert.AreEqual('500,550,560', SelectedBy(['class:TList__1<*>']));
  Assert.AreEqual(NOTHING, SelectedBy(['class:Helper']));

  // routine: without a class part, the routine part; with one, the whole name.
  Assert.AreEqual('100,150', SelectedBy(['routine:Create']));
  Assert.AreEqual('100,150', SelectedBy(['routine:TWidget.Create']));
  Assert.AreEqual('100,150', SelectedBy(['routine:*.Create']));
  Assert.AreEqual('100,150,200', SelectedBy(['routine:TWidget.*']));
  Assert.AreEqual('300,350', SelectedBy(['routine:Helper']));
  Assert.AreEqual(NOTHING, SelectedBy(['routine:*.Helper']), 'Helper is not a method');
  Assert.AreEqual('400', SelectedBy(['routine:Run']));
  Assert.AreEqual(NOTHING, SelectedBy(['routine:TInner.Run']), 'the whole name is TOuter.TInner.Run');
  Assert.AreEqual('400', SelectedBy(['routine:*TInner.Run']));
  Assert.AreEqual('500,550,560', SelectedBy(['routine:Add']));
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['routine:*']));

  // The entries of a list are alternatives.
  Assert.AreEqual('100,150,400', SelectedBy(['routine:Create', 'routine:Run']));
  Assert.AreEqual('100,150,200,560', SelectedBy(['class:TWidget', 'file:Loose.pas']));
  Assert.AreEqual('100,150,200,300,350,400', SelectedBy(['unit:UnitA', 'routine:Run']));
end;

procedure TProfileScopeTests.Exclusion_WinsOverInclusion;
const
  NOTHING = '';
begin
  Assert.AreEqual('100,150,200', SelectedBy(['unit:UnitA'], ['routine:Helper']));
  Assert.AreEqual('100,150,200,300,400,550,560', SelectedBy(['module:Fake'], ['file:Gen.pas']));
  Assert.AreEqual('300,350,400,500,550,560', SelectedBy(['module:Fake'], ['class:TWidget']));
  Assert.AreEqual('100,150,200,300,350', SelectedBy(['module:Fake'], ['unit:Vendor.*']));
  Assert.AreEqual('350,500,550,560', SelectedBy(['module:Fake'], ['file:C:\src\*']));
  // The same entry on both sides: out.
  Assert.AreEqual(NOTHING, SelectedBy(['unit:UnitA'], ['unit:UnitA']));
  Assert.AreEqual(NOTHING, SelectedBy(['routine:Create'], ['class:TWidget']));
  // An excluded module is out whatever else selects its records.
  Assert.AreEqual(NOTHING, SelectedBy(['unit:UnitA', 'file:*.pas'], ['module:Fake.bpl']));
  Assert.AreEqual(NOTHING, SelectedBy(['module:Fake'], ['module:Fake']));
  Assert.AreEqual(ALL_IN_ROUTINES, SelectedBy(['module:Fake'], ['module:Other']));
  // Several exclusions add up.
  Assert.AreEqual('400', SelectedBy(['module:Fake'], ['unit:UnitA', 'routine:Add']));
end;

procedure TProfileScopeTests.RoutineWithoutLineRecords_IsNeverInScope;
begin
  var Map := SyntheticMap;
  try
    Assert.AreEqual(2, Map.OutsideRoutineCount, 'the records at 90 and 650');
    var NoLines := -1;
    for var R := 0 to High(Map.Routines) do
      if Map.Routines[R].Name = 'NoLines' then
        NoLines := R;
    Assert.IsTrue(NoLines >= 0, 'the fixture routine is missing');
    Assert.AreEqual(0, Map.Routines[NoLines].LineCount);

    // Named outright, and selected with its whole module: still not in scope.
    var Named := Evaluate(Map, Options(['routine:NoLines']), True);
    Assert.AreEqual(0, Named.RoutineCount);
    Assert.AreEqual(0, Named.LineCount);
    var Whole := Evaluate(Map, Options(['module:Fake']), True);
    Assert.IsFalse(Whole.Routines[NoLines], 'a routine with no line record');
    Assert.AreEqual(5, Whole.RoutineCount, 'the five routines that have records');
    Assert.AreEqual(9, Whole.LineCount);
    // The two records outside every routine were selected and are reported.
    Assert.AreEqual(2, Whole.SelectedOutsideRoutineCount);
    Assert.AreEqual(2, Evaluate(Map, Options(['file:A.pas']), True).SelectedOutsideRoutineCount);
    Assert.AreEqual(0, Evaluate(Map, Options(['file:B.pas']), True).SelectedOutsideRoutineCount);
    Assert.AreEqual(0, Evaluate(Map, Options(['file:A.pas'], ['unit:UnitA']), True).SelectedOutsideRoutineCount,
      'an excluded record is not counted as selected');
  finally
    Map.Free;
  end;

  Assert.WillRaise(
    procedure
    begin
      var Scope := TProfileScope.Create(Options(['unit:UnitA']));
      try
        Scope.Evaluate(nil, True);
      finally
        Scope.Free;
      end;
    end, EArgumentNilException);
end;

procedure TProfileScopeTests.SourceRoot_SelectsFilesResolvedUnderIt;
const
  NOTHING = '';
  UNDER_SRC = '100,150,200,300,400';   // A.pas and sub\B.pas
begin
  Assert.AreEqual(UNDER_SRC, SelectedUnder('C:\src'), 'C:\src2\Gen.pas is not under C:\src');
  Assert.AreEqual(UNDER_SRC, SelectedUnder('c:\SRC\'));
  Assert.AreEqual(UNDER_SRC, SelectedUnder('C:/src'));
  Assert.AreEqual(UNDER_SRC, SelectedUnder('C:\src\sub\..'));
  Assert.AreEqual('300,400', SelectedUnder('C:\src\sub'));
  Assert.AreEqual('350,500', SelectedUnder('C:\src2'));
  Assert.AreEqual(NOTHING, SelectedUnder('C:\sr'));
  Assert.AreEqual(NOTHING, SelectedUnder('C:\elsewhere'));
  Assert.AreEqual('100,150,200,300,350,400,500', SelectedUnder('C:\'), 'every file that resolved');
  // A file that did not resolve is under nothing: a recorded path is where the
  // file was when it was compiled, not where it is.
  Assert.AreEqual(NOTHING, SelectedUnder('D:\rtl'));

  // The main-module flag plays no part once there is a root.
  var Given := Default(TProfileScopeOptions);
  Given.SourceRoot := 'C:\src';
  Assert.AreEqual(UNDER_SRC, Selected(Given, True));
  Assert.AreEqual(UNDER_SRC, Selected(Given, False));

  // Exclusion applies to the default.
  Assert.AreEqual('300,400', SelectedUnder('C:\src', ['class:TWidget']));
  Assert.AreEqual('100,150,200', SelectedUnder('C:\src', ['file:B.pas']));
  Assert.AreEqual('400', SelectedUnder('C:\src', ['unit:UnitA']));
  Assert.AreEqual(NOTHING, SelectedUnder('C:\src', ['module:Fake']));

  // An include list replaces the root altogether.
  Given.Include := ['file:Gen.pas'];
  Assert.AreEqual('350,500', Selected(Given));

  var Scope := TProfileScope.Create(Options(nil));
  try
    Assert.IsTrue(Scope.Basis = TProfileScopeBasis.MainModule);
  finally
    Scope.Free;
  end;
  Given := Default(TProfileScopeOptions);
  Given.SourceRoot := 'C:\Src\Sub\';
  Scope := TProfileScope.Create(Given);
  try
    Assert.IsTrue(Scope.Basis = TProfileScopeBasis.SourceRoot);
    Assert.AreEqual('c:\src\sub', Scope.SourceRoot, False, 'the root is kept normalised');
  finally
    Scope.Free;
  end;
end;

procedure TProfileScopeTests.NoSourceRoot_SelectsTheMainModuleOnly;
const
  NOTHING = '';
begin
  var Given := Default(TProfileScopeOptions);
  Assert.AreEqual(ALL_IN_ROUTINES, Selected(Given, True), 'every record of the main module');
  Assert.AreEqual(NOTHING, Selected(Given, False), 'nothing of any other module');
  // Exclusion applies to this default too.
  Given.Exclude := ['unit:Vendor.*'];
  Assert.AreEqual('100,150,200,300,350', Selected(Given, True));
  Assert.AreEqual(NOTHING, Selected(Given, False));
  Given.Exclude := ['module:Fake'];
  Assert.AreEqual(NOTHING, Selected(Given, True));
  // A blank root is no root.
  Given := Default(TProfileScopeOptions);
  Given.SourceRoot := '   ';
  Assert.AreEqual(ALL_IN_ROUTINES, Selected(Given, True));
end;

procedure TProfileScopeTests.ReferenceSet_ReplacesTheDefault;
const
  NOTHING = '';
begin
  // By resolved path, however it is written.
  Assert.AreEqual('100,150,200', SelectedByReference(['c:\SRC\a.pas']));
  Assert.AreEqual('300,400', SelectedByReference(['C:/src/sub/B.pas']));
  Assert.AreEqual('100,150,200,350,500', SelectedByReference(['C:\src\A.pas', 'C:\src2\Gen.pas']));
  // The same name in another directory is another file.
  Assert.AreEqual(NOTHING, SelectedByReference(['C:\elsewhere\A.pas']));
  // By name, for a file the reference did not resolve.
  Assert.AreEqual('560', SelectedByReference(['loose.pas']));
  Assert.AreEqual('350,500', SelectedByReference(['Gen.pas']), 'a bare name matches the file wherever it is');
  // A file that did not resolve is matched through its recorded path.
  Assert.AreEqual('550', SelectedByReference(['D:\rtl\Rtl.pas']));
  // An empty reference is a reference: it selects nothing.
  Assert.AreEqual(NOTHING, SelectedByReference(nil));

  var Given := Default(TProfileScopeOptions);
  Given.HasReferenceFiles := True;
  Given.ReferenceFiles    := ['C:\src\A.pas', 'Loose.pas'];
  // It replaces the two other defaults: neither the root nor the main module counts.
  Given.SourceRoot := 'C:\src2';
  Assert.AreEqual('100,150,200,560', Selected(Given, True));
  Assert.AreEqual('100,150,200,560', Selected(Given, False));
  var Scope := TProfileScope.Create(Given);
  try
    Assert.IsTrue(Scope.Basis = TProfileScopeBasis.ReferenceFiles);
  finally
    Scope.Free;
  end;
  // Exclusion applies to it.
  Given.Exclude := ['routine:Create'];
  Assert.AreEqual('200,560', Selected(Given));
  // An include list replaces it.
  Given.Exclude := nil;
  Given.Include := ['file:B.pas'];
  Assert.AreEqual('300,400', Selected(Given));
  // A list that is not flagged as a reference set is not one.
  Given := Default(TProfileScopeOptions);
  Given.ReferenceFiles := ['C:\src\A.pas'];
  Assert.AreEqual(ALL_IN_ROUTINES, Selected(Given, True));
end;

procedure TProfileScopeTests.ModuleQuestion_RulesOutOnlyWhatItCan;
const
  KNOWN = True;
  UNKNOWN = False;
  MAIN = True;
  NOT_MAIN = False;
begin
  // No include, no root, no reference: the main module and nothing else.
  Assert.IsTrue(MayHold(nil, nil, 'App.exe', MAIN, nil, UNKNOWN));
  Assert.IsFalse(MayHold(nil, nil, 'Pkg.bpl', NOT_MAIN, ['UnitA'], KNOWN));
  Assert.IsFalse(MayHold(nil, nil, 'Pkg.bpl', NOT_MAIN, nil, UNKNOWN));

  // unit: entries against a known list.
  Assert.IsTrue(MayHold(['unit:UnitA'], nil, 'Pkg.bpl', NOT_MAIN, ['UnitX', 'unita'], KNOWN));
  Assert.IsFalse(MayHold(['unit:UnitA'], nil, 'Pkg.bpl', NOT_MAIN, ['UnitX', 'UnitY'], KNOWN));
  Assert.IsTrue(MayHold(['Vcl.*'], nil, 'Pkg.bpl', NOT_MAIN, ['System.SysUtils', 'Vcl.Forms'], KNOWN));
  Assert.IsFalse(MayHold(['unit:Forms'], nil, 'Pkg.bpl', NOT_MAIN, ['Vcl.Forms'], KNOWN),
    'a unit is matched by its whole name here as in Evaluate');
  Assert.IsFalse(MayHold(['unit:UnitA'], nil, 'Pkg.bpl', NOT_MAIN, nil, KNOWN), 'a module known to hold no unit');
  // The main module is not special once there is an include list.
  Assert.IsFalse(MayHold(['unit:UnitA'], nil, 'App.exe', MAIN, ['UnitX'], KNOWN));
  // An unknown list rules nothing out.
  Assert.IsTrue(MayHold(['unit:UnitA'], nil, 'Some.dll', NOT_MAIN, nil, UNKNOWN));
  Assert.IsTrue(MayHold(['unit:UnitA'], nil, 'Some.dll', NOT_MAIN, ['UnitX'], UNKNOWN),
    'a list flagged unknown is not read');

  // module: entries.
  Assert.IsTrue(MayHold(['module:Pkg'], nil, 'C:\app\bin\PKG.BPL', NOT_MAIN, ['UnitX'], KNOWN));
  Assert.IsTrue(MayHold(['module:Pkg.bpl'], nil, 'Pkg.bpl', NOT_MAIN, nil, UNKNOWN));
  Assert.IsFalse(MayHold(['module:Pkg'], nil, 'Other.bpl', NOT_MAIN, ['UnitX'], KNOWN));
  Assert.IsFalse(MayHold(['module:Pkg'], nil, 'Other.bpl', NOT_MAIN, nil, UNKNOWN),
    'only module entries, none matching: the unit list is not needed');
  Assert.IsTrue(MayHold(['module:Pkg', 'unit:UnitA'], nil, 'Other.bpl', NOT_MAIN, nil, UNKNOWN));
  Assert.IsTrue(MayHold(['module:Pkg', 'unit:UnitA'], nil, 'Other.bpl', NOT_MAIN, ['UnitA'], KNOWN));
  Assert.IsFalse(MayHold(['module:Pkg', 'unit:UnitA'], nil, 'Other.bpl', NOT_MAIN, ['UnitX'], KNOWN));

  // file:, class: and routine: entries can match code of any module.
  Assert.IsTrue(MayHold(['file:A.pas'], nil, 'Other.bpl', NOT_MAIN, ['UnitX'], KNOWN));
  Assert.IsTrue(MayHold(['class:TWidget'], nil, 'Other.bpl', NOT_MAIN, ['UnitX'], KNOWN));
  Assert.IsTrue(MayHold(['routine:Create'], nil, 'Other.bpl', NOT_MAIN, ['UnitX'], KNOWN));
  Assert.IsTrue(MayHold(['unit:UnitA', 'routine:Create'], nil, 'Other.bpl', NOT_MAIN, ['UnitX'], KNOWN));

  // Exclusion.
  Assert.IsFalse(MayHold(nil, ['module:App'], 'App.exe', MAIN, nil, UNKNOWN));
  Assert.IsFalse(MayHold(['file:A.pas'], ['module:Other.*'], 'Other.bpl', NOT_MAIN, nil, UNKNOWN));
  Assert.IsFalse(MayHold(['unit:UnitA'], ['unit:UnitA'], 'Pkg.bpl', NOT_MAIN, ['UnitA', 'UnitX'], KNOWN),
    'the only unit that is included is excluded');
  Assert.IsTrue(MayHold(['unit:Unit*'], ['unit:UnitA'], 'Pkg.bpl', NOT_MAIN, ['UnitA', 'UnitX'], KNOWN));
  Assert.IsFalse(MayHold(['file:A.pas'], ['unit:Unit*'], 'Pkg.bpl', NOT_MAIN, ['UnitA', 'UnitX'], KNOWN),
    'every unit of the module is excluded');
  Assert.IsTrue(MayHold(['file:A.pas'], ['unit:Unit*'], 'Pkg.bpl', NOT_MAIN, ['UnitA', 'Other'], KNOWN));
  Assert.IsTrue(MayHold(['file:A.pas'], ['unit:*'], 'Some.dll', NOT_MAIN, nil, UNKNOWN));
  Assert.IsFalse(MayHold(nil, ['unit:*'], 'App.exe', MAIN, ['UnitA'], KNOWN));
  // Exclusions that name files or routines rule no module out.
  Assert.IsTrue(MayHold(nil, ['file:*', 'class:*', 'routine:*'], 'App.exe', MAIN, ['UnitA'], KNOWN));

  // A scope decided by source files never rules a module out by its units:
  // generic code written under the root is compiled into whichever module
  // instantiates it.
  var Rooted := Default(TProfileScopeOptions);
  Rooted.SourceRoot := 'C:\src';
  var Scope := TProfileScope.Create(Rooted);
  try
    Assert.IsTrue(Scope.ModuleMayHoldScope('Pkg.bpl', NOT_MAIN, ['UnitX'], KNOWN));
    Assert.IsTrue(Scope.ModuleMayHoldScope('Pkg.bpl', NOT_MAIN, nil, UNKNOWN));
  finally
    Scope.Free;
  end;
  var Referenced := Default(TProfileScopeOptions);
  Referenced.HasReferenceFiles := True;
  Referenced.ReferenceFiles    := ['C:\src\A.pas'];
  Referenced.Exclude           := ['module:Skip*'];
  Scope := TProfileScope.Create(Referenced);
  try
    Assert.IsTrue(Scope.ModuleMayHoldScope('Pkg.bpl', NOT_MAIN, ['UnitX'], KNOWN));
    Assert.IsFalse(Scope.ModuleMayHoldScope('SkipMe.bpl', NOT_MAIN, ['UnitX'], KNOWN));
  finally
    Scope.Free;
  end;
end;

{ On the fixture binaries }

procedure TProfileScopeTests.CheckDefaultScope(const Binary: TScopeBinary);
// The default scope with the fixture's source directory as the root. Expected:
// a record is in scope when it lies in a routine and its file EXISTS in that
// directory -- the file system decides, not a comparison of paths.
begin
  var Map := BuildMap(Binary);
  try
    var OwnFile: TArray<Boolean>;
    SetLength(OwnFile, Length(Map.Files));
    for var F := 0 to High(Map.Files) do
      OwnFile[F] := TFile.Exists(SourceDir + Map.Files[F].Name);

    var Expected: TArray<Boolean>;
    SetLength(Expected, Length(Map.Lines));
    var OwnFileHasCode, OtherFileHasCode: TArray<Boolean>;
    SetLength(OwnFileHasCode, Length(Map.Files));
    SetLength(OtherFileHasCode, Length(Map.Files));
    var LinesOfUnit: TArray<Integer>;
    SetLength(LinesOfUnit, Length(Map.Units));
    for var I := 0 to High(Map.Lines) do begin
      var Line := Map.Lines[I];
      if not Line.InRoutine then
        Continue;
      Expected[I] := OwnFile[Line.FileIndex];
      if OwnFile[Line.FileIndex] then
        OwnFileHasCode[Line.FileIndex] := True
      else
        OtherFileHasCode[Line.FileIndex] := True;
      if Expected[I] and (Line.UnitIndex >= 0) then
        Inc(LinesOfUnit[Line.UnitIndex]);
    end;
    // The fixture must supply both sides, or the test proves nothing.
    Check(CountOf(OwnFileHasCode) >= 10,
      Format('%s: only %d of the fixture''s own source files have code', [Binary.Caption, CountOf(OwnFileHasCode)]));
    Check(CountOf(OtherFileHasCode) >= 1,
      Binary.Caption + ': no record lies in a source file outside the fixture''s directory');

    var Given := Default(TProfileScopeOptions);
    Given.SourceRoot := SourceDir;
    CheckDecision(Binary.Caption + ', source root', Map, Evaluate(Map, Given, True), Expected);
    CheckDecision(Binary.Caption + ', source root, not the main module', Map, Evaluate(Map, Given, False), Expected);
    // The root's parent holds the fixture's sources too; a sibling does not.
    Given.SourceRoot := FixtureRoot;
    CheckDecision(Binary.Caption + ', the parent as root', Map, Evaluate(Map, Given, False), Expected);
    Given.SourceRoot := FixtureRoot + 'TestTar';
    Check(Evaluate(Map, Given, True).LineCount = 0,
      Binary.Caption + ': a root that is only a text prefix of the source directory selects records');
    Given.SourceRoot := FixtureRoot + 'TestHost';
    Check(Evaluate(Map, Given, True).LineCount = 0,
      Binary.Caption + ': a sibling directory as root selects records');

    // Exclusion applies to the default: drop the unit with the most records.
    var Busiest := -1;
    for var U := 0 to High(LinesOfUnit) do
      if (Busiest < 0) or (LinesOfUnit[U] > LinesOfUnit[Busiest]) then
        Busiest := U;
    Check(Busiest >= 0, Binary.Caption + ': the map names no unit');
    if Busiest < 0 then
      Exit;
    var WithoutBusiest := Copy(Expected);
    for var I := 0 to High(Map.Lines) do
      if Map.Lines[I].UnitIndex = Busiest then
        WithoutBusiest[I] := False;
    Check((CountOf(WithoutBusiest) > 0) and (CountOf(WithoutBusiest) < CountOf(Expected)),
      Format('%s: excluding %s leaves %d of %d records, so the check proves nothing',
        [Binary.Caption, Map.Units[Busiest], CountOf(WithoutBusiest), CountOf(Expected)]));
    Given.SourceRoot := SourceDir;
    Given.Exclude := ['unit:' + Map.Units[Busiest]];
    CheckDecision(Format('%s, source root without %s', [Binary.Caption, Map.Units[Busiest]]), Map,
      Evaluate(Map, Given, True), WithoutBusiest);
  finally
    Map.Free;
  end;
end;

procedure TProfileScopeTests.DefaultScope_Executable_OwnSourcesInOthersOut;
begin
  for var Binary in LoadBinaries do
    if not Binary.IsPackage then
      CheckDefaultScope(Binary);
  AssertNoProblems;
end;

procedure TProfileScopeTests.DefaultScope_Package_OwnSourcesInOthersOut;
begin
  for var Binary in LoadBinaries do
    if Binary.IsPackage then
      CheckDefaultScope(Binary);
  AssertNoProblems;
end;

procedure TProfileScopeTests.NoSourceRoot_OnTheFixtures_EveryRecordOfTheMainModule;
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      var EveryRecord := ExpectedByRoutine(Map,
        function(const Routine: TCodeMapRoutine): Boolean
        begin
          Result := True;
        end);
      Check(CountOf(EveryRecord) > 1000, Format('%s: only %d records in routines', [Binary.Caption, CountOf(EveryRecord)]));
      var Given := Default(TProfileScopeOptions);
      CheckDecision(Binary.Caption + ', as the main module', Map, Evaluate(Map, Given, True), EveryRecord);
      var Nothing: TArray<Boolean>;
      SetLength(Nothing, Length(Map.Lines));
      CheckDecision(Binary.Caption + ', as another module', Map, Evaluate(Map, Given, False), Nothing);
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TProfileScopeTests.CheckReferenceScope(const Caption: string;
  const Reference, Measured: TScopeBinary; Resolve: Boolean);
// The reference is the package, the measured module the executable built from
// the same sources. Expected: a record of the executable is in scope when it
// lies in a routine and its file is one of the package's files -- the same
// path when the maps were built with a resolver, the same name when not.
begin
  var ReferenceMap := BuildMap(Reference, Resolve);
  var MeasuredMap := BuildMap(Measured, Resolve);
  var InReference := TDictionary<string, Boolean>.Create;
  try
    var Given := Default(TProfileScopeOptions);
    Given.HasReferenceFiles := True;
    for var SourceFile in ReferenceMap.Files do begin
      var Key := SourceFile.Name;
      if SourceFile.ResolvedPath <> '' then
        Key := SourceFile.ResolvedPath;
      Check((SourceFile.ResolvedPath <> '') = Resolve,
        Format('%s: %s resolved to "%s"', [Caption, SourceFile.Name, SourceFile.ResolvedPath]));
      Given.ReferenceFiles := Given.ReferenceFiles + [Key];
      InReference.AddOrSetValue(AnsiLowerCase(Key), True);
    end;

    var Expected: TArray<Boolean>;
    SetLength(Expected, Length(MeasuredMap.Lines));
    var LeftOut := 0;
    for var I := 0 to High(MeasuredMap.Lines) do begin
      var Line := MeasuredMap.Lines[I];
      if not Line.InRoutine then
        Continue;
      var Key := MeasuredMap.Files[Line.FileIndex].Name;
      if Resolve then
        Key := MeasuredMap.Files[Line.FileIndex].ResolvedPath;
      Expected[I] := InReference.ContainsKey(AnsiLowerCase(Key));
      if not Expected[I] then
        Inc(LeftOut);
    end;
    Check(CountOf(Expected) > 1000, Format('%s: only %d records expected in scope', [Caption, CountOf(Expected)]));
    // The executable's own program file is in no package.
    Check(LeftOut > 0, Caption + ': every record of the executable is in the reference, so the check proves nothing');

    // The main-module flag and a source root that would select nothing play no part.
    Given.SourceRoot := ELSEWHERE + 'nowhere';
    CheckDecision(Caption, MeasuredMap, Evaluate(MeasuredMap, Given, True), Expected);
    CheckDecision(Caption + ', not the main module', MeasuredMap, Evaluate(MeasuredMap, Given, False), Expected);
  finally
    InReference.Free;
    MeasuredMap.Free;
    ReferenceMap.Free;
  end;
end;

procedure TProfileScopeTests.ReferenceSet_OnTheFixtures_ThePackageSourcesInTheExecutable;
begin
  var Binaries := LoadBinaries;
  // exe x64 with bpl x64, exe x86 with bpl x86.
  for var Pair := 0 to 1 do begin
    var Measured := Binaries[Pair];
    var Reference := Binaries[Pair + 2];
    Assert.IsTrue(Reference.IsPackage and not Measured.IsPackage, 'the fixture order changed');
    CheckReferenceScope(Format('%s against %s, by resolved path', [Measured.Caption, Reference.Caption]),
      Reference, Measured, True);
    CheckReferenceScope(Format('%s against %s, by name', [Measured.Caption, Reference.Caption]),
      Reference, Measured, False);
  end;
  AssertNoProblems;
end;

procedure TProfileScopeTests.RecordsOutsideEveryRoutine_AreNeverInScope;
// Every way of selecting a whole module, on every fixture: the records outside
// every routine stay out, and are reported as selected and not measured.
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      Check(Map.OutsideRoutineCount > 0,
        Binary.Caption + ': no record lies outside a routine, so the test proves nothing');
      var EveryRecord := ExpectedByRoutine(Map,
        function(const Routine: TCodeMapRoutine): Boolean
        begin
          Result := True;
        end);
      var Whole: TArray<TProfileScopeOptions> := [
        Options(['module:*']), Options(['unit:*']), Options(['file:*']), Options(['file:*\*']),
        Options(['module:' + ExtractFileName(Binary.Path), 'routine:*', 'class:*']),
        Default(TProfileScopeOptions)];
      for var W := 0 to High(Whole) do begin
        var Caption := Format('%s, whole-module scope %d', [Binary.Caption, W]);
        var Decision := Evaluate(Map, Whole[W], True);
        CheckDecision(Caption, Map, Decision, EveryRecord);
        Check(Decision.SelectedOutsideRoutineCount = Map.OutsideRoutineCount,
          Format('%s: %d records selected outside every routine, the map has %d',
            [Caption, Decision.SelectedOutsideRoutineCount, Map.OutsideRoutineCount]));
        Check(Decision.LineCount = Length(Map.Lines) - Map.OutsideRoutineCount,
          Format('%s: %d records in scope of %d in routines',
            [Caption, Decision.LineCount, Length(Map.Lines) - Map.OutsideRoutineCount]));
      end;
      // Patterns that name routines cannot even select them.
      var ByRoutine := Evaluate(Map, Options(['routine:*', 'class:*']), True);
      CheckDecision(Binary.Caption + ', every routine', Map, ByRoutine, EveryRecord);
      Check(ByRoutine.SelectedOutsideRoutineCount = 0,
        Format('%s: %d records outside every routine selected by a routine pattern',
          [Binary.Caption, ByRoutine.SelectedOutsideRoutineCount]));
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TProfileScopeTests.ClassAndRoutinePatterns_FollowTheProvidersNames;
// The names come from the fixture's sources; what each pattern must select is
// computed from the routine names the code map holds, by plain text tests.
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      // A method: `Class.Method`.
      CheckPattern(Binary.Caption, 'class:TWidget', Map,
        function(const Routine: TCodeMapRoutine): Boolean
        begin
          Result := IsMethodOf('TWidget', Routine.Name);
        end);
      CheckPattern(Binary.Caption, 'routine:TWidget.Create', Map,
        function(const Routine: TCodeMapRoutine): Boolean
        begin
          Result := SameText(Routine.Name, 'TWidget.Create');
        end);
      // Every Create: of a class, or standing alone.
      CheckPattern(Binary.Caption, 'routine:Create', Map,
        function(const Routine: TCodeMapRoutine): Boolean
        begin
          Result := SameText(Routine.Name, 'Create') or EndsText('.Create', Routine.Name);
        end);
      // A nested routine is spelled by its own name, without its parent.
      CheckPattern(Binary.Caption, 'routine:InnerNested', Map,
        function(const Routine: TCodeMapRoutine): Boolean
        begin
          Result := SameText(Routine.Name, 'InnerNested');
        end);

      // A generic instantiation: the first one the map holds with code. TD32
      // spells it `TList__1<Integer>.Pack` in a 64-bit image and keeps the
      // mangled `%TList__1.Pack$qqrv` in a 32-bit one; both split at their dot.
      var GenericClass := '';
      for var Routine in Map.Routines do begin
        var LastDot := LastDelimiter('.', Routine.Name);
        if (Routine.LineCount = 0) or (LastDot <= 2) then
          Continue;
        if (Routine.Name[LastDot - 1] = '>') or Routine.Name.StartsWith('%') then begin
          GenericClass := Copy(Routine.Name, 1, LastDot - 1);
          Break;
        end;
      end;
      Check(GenericClass <> '', Binary.Caption + ': no generic instantiation with code in the map');
      Check(GenericClass.StartsWith('%') = Binary.Caption.EndsWith('x86'),
        Format('%s: the generic class is spelled "%s"; the mangled form is expected in the 32-bit image only',
          [Binary.Caption, GenericClass]));
      if GenericClass <> '' then
        CheckPattern(Binary.Caption, 'class:' + GenericClass, Map,
          function(const Routine: TCodeMapRoutine): Boolean
          begin
            Result := IsMethodOf(GenericClass, Routine.Name);
          end);
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TProfileScopeTests.UnitPattern_TakesGenericCodeTheFilePatternLeavesOut;
// A generic written in one file and instantiated in a unit of the fixture: its
// records belong to the instantiating unit and to the file the generic was
// written in. `unit:` follows the first, `file:` the second.
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      var Foreign := -1;
      for var I := 0 to High(Map.Lines) do begin
        var Line := Map.Lines[I];
        if not Line.InRoutine or (Line.UnitIndex < 0) then
          Continue;
        var OwnFile := Map.Units[Line.UnitIndex] + '.pas';
        if SameText(Map.Files[Line.FileIndex].Name, OwnFile) or (Length(Map.FindFiles(OwnFile)) = 0) then
          Continue;
        Foreign := I;
        Break;
      end;
      Check(Foreign >= 0, Binary.Caption + ': no record lies in a file other than its unit''s own');
      if Foreign < 0 then
        Continue;
      var UnitName := Map.Units[Map.Lines[Foreign].UnitIndex];
      var FileName := Map.Files[Map.Lines[Foreign].FileIndex].Name;

      var ByUnit := Evaluate(Map, Options(['unit:' + UnitName]), False);
      Check(ByUnit.Lines[Foreign], Format('%s: unit:%s leaves out its record in %s', [Binary.Caption, UnitName, FileName]));
      var ByFile := Evaluate(Map, Options(['file:' + UnitName + '.pas']), False);
      Check(not ByFile.Lines[Foreign],
        Format('%s: file:%s.pas takes a record of %s', [Binary.Caption, UnitName, FileName]));
      Check((ByFile.LineCount > 0) and (ByFile.LineCount < ByUnit.LineCount),
        Format('%s: file:%s.pas selects %d records, unit:%s %d', [Binary.Caption, UnitName, ByFile.LineCount,
          UnitName, ByUnit.LineCount]));
      var ByForeignFile := Evaluate(Map, Options(['file:' + FileName]), False);
      Check(ByForeignFile.Lines[Foreign], Format('%s: file:%s leaves out its own record', [Binary.Caption, FileName]));
      // Both together, minus the unit: what other units instantiated of that file.
      var Elsewhere := Evaluate(Map, Options(['file:' + FileName], ['unit:' + UnitName]), False);
      Check(not Elsewhere.Lines[Foreign] and (Elsewhere.LineCount < ByForeignFile.LineCount),
        Format('%s: excluding unit:%s does not remove its records of %s', [Binary.Caption, UnitName, FileName]));
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TProfileScopeTests.SplitRoutineName_ReassemblesEveryFixtureRoutine;
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      var WithClass := 0;
      var Generic := 0;
      for var Routine in Map.Routines do begin
        var ClassPart, RoutinePart: string;
        TProfileScope.SplitRoutineName(Routine.Name, ClassPart, RoutinePart);
        if ClassPart = '' then begin
          // No class part: the name has no dot outside brackets, or starts with one.
          Check((RoutinePart = Routine.Name) or ('.' + RoutinePart = Routine.Name),
            Format('%s: "%s" split into "" and "%s"', [Binary.Caption, Routine.Name, RoutinePart]));
          Continue;
        end;
        Inc(WithClass);
        Check(ClassPart + '.' + RoutinePart = Routine.Name,
          Format('%s: "%s" split into "%s" and "%s"', [Binary.Caption, Routine.Name, ClassPart, RoutinePart]));
        // A generic instantiation: brackets, or the mangled form of a 32-bit image.
        if Routine.Name.StartsWith('%') then
          Inc(Generic);
        if Routine.Name.IndexOfAny(['<', '{']) >= 0 then begin
          Inc(Generic);
          Continue;
        end;
        Check(not RoutinePart.Contains('.'),
          Format('%s: "%s": the routine part "%s" still holds a dot', [Binary.Caption, Routine.Name, RoutinePart]));
      end;
      Check(WithClass > 100, Format('%s: only %d routines with a class part', [Binary.Caption, WithClass]));
      Check(Generic > 0, Binary.Caption + ': no generic instantiation among the routine names');
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TProfileScopeTests.ModuleQuestion_OnThePackage_AgreesWithPackageInfoAndTheCodeMap;
// The unit list is the package's own PACKAGEINFO. The question must say yes
// for every unit the code map has records of, and whenever it says no the
// decision over the code map must select nothing.
begin
  for var Binary in LoadBinaries do begin
    if not Binary.IsPackage then
      Continue;
    var Info: TPackageInfo;
    Check(ReadPackageInfo(Binary.Path, Info) and Info.Complete, Binary.Caption + ': PACKAGEINFO not read');
    var Contained := TDictionary<string, Boolean>.Create;
    var Map := BuildMap(Binary);
    try
      for var Name in Info.ContainedUnits do
        Contained.AddOrSetValue(AnsiLowerCase(Name), True);

      var UnitsWithCode := 0;
      for var U := 0 to High(Map.Units) do begin
        var Name := Map.Units[U];
        var Scope := TProfileScope.Create(Options(['unit:' + Name]));
        try
          var Decision := Scope.Evaluate(Map, False);
          if Decision.LineCount = 0 then
            Continue;
          Inc(UnitsWithCode);
          Check(Contained.ContainsKey(AnsiLowerCase(Name)),
            Format('%s: the code map has records of unit %s, PACKAGEINFO does not list it', [Binary.Caption, Name]));
          Check(Scope.ModuleMayHoldScope(Binary.Path, False, Info.ContainedUnits, True),
            Format('%s: ruled out for unit:%s, which has %d records in it', [Binary.Caption, Name, Decision.LineCount]));
        finally
          Scope.Free;
        end;
      end;
      Check(UnitsWithCode >= 10, Format('%s: only %d units with records', [Binary.Caption, UnitsWithCode]));

      // Scopes of every shape: a "no" must never hide records.
      var FirstUnit := Info.ContainedUnits[0];
      var Shapes: TArray<TProfileScopeOptions> := [
        Options(['unit:NoSuchUnitAnywhere']),
        Options(['unit:NoSuchUnitAnywhere', 'module:NoSuchModule']),
        Options(['module:NoSuchModule']),
        Options(['module:TestSubject']),
        Options(['unit:TestTarget*']),
        Options(['unit:TestTarget*'], ['unit:TestTarget*']),
        Options(['unit:*'], ['unit:*']),
        Options(['unit:' + FirstUnit], ['unit:' + FirstUnit]),
        Options(['file:*.pas'], ['module:TestSubject.bpl']),
        Options(['class:TWidget']),
        Options(['routine:NoSuchRoutineAnywhere']),
        Default(TProfileScopeOptions)];
      var RuledOut := 0;
      for var S := 0 to High(Shapes) do begin
        var Scope := TProfileScope.Create(Shapes[S]);
        try
          if Scope.ModuleMayHoldScope(Binary.Path, False, Info.ContainedUnits, True) then
            Continue;
          Inc(RuledOut);
          var Decision := Scope.Evaluate(Map, False);
          Check(Decision.LineCount = 0,
            Format('%s: scope %d rules the package out, yet %d of its records are in scope',
              [Binary.Caption, S, Decision.LineCount]));
        finally
          Scope.Free;
        end;
      end;
      Check(RuledOut >= 6, Format('%s: only %d of the scopes rule the package out', [Binary.Caption, RuledOut]));
    finally
      Map.Free;
      Contained.Free;
    end;
  end;
  AssertNoProblems;
end;

initialization
  TDUnitX.RegisterTestFixture(TProfileScopeTests);

end.
