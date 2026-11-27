unit CodeMapTests;

// Tests for the code map (DebuggerCore\CodeMap.pas) and for the two provider
// interfaces it is built from, ILineRecordProvider and IRoutineRangeProvider.
//
// No debug session: every test reads the fixture binaries as files. The
// expectations are not written by hand -- the providers' own point lookups
// (RvaToSourceLine, SourceLineToRva, RvaToFunctionStart, RvaToFunctionName)
// are the oracle, so a test cannot agree with the code under test merely
// because both were written from the same reading of a format.
//
// Every fixture-driven test runs on the executable AND the package, on both
// bitnesses, and COLLECTS its failures: both executables are called
// TestTarget.exe, so a first-failure abort would hide the other bitness and a
// message built from the file name could not say which one failed.

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Generics.Collections,
  DebugInfoTypes, TD32FileReader, CodeMap;

type
  // One fixture binary, loaded. Keep holds the reference that keeps the
  // reference-counted reader alive while it is also used as an object.
  TLoadedBinary = record
    Caption:   string;
    Path:      string;
    MapPath:   string;
    ImageSize: UInt64;
    Reader:    TTD32FileReader;
    Keep:      IInterface;
  end;

  // A marker line of TestTargetCore.pas: `{BP:NAME}`.
  TMarker = record
    Name: string;
    Line: Integer;
  end;

  [TestFixture]
  TCodeMapTests = class
  private
    FProblems: TList<string>;
    function  FixtureRoot: string;
    function  LoadBinaries: TArray<TLoadedBinary>;
    function  LoadOne(const Caption, RelativePath: string; OutputRvaShift: UInt64 = 0): TLoadedBinary;
    function  BuildMap(const Binary: TLoadedBinary; OutputRvaShift: UInt64 = 0): TModuleCodeMap;
    function  Markers: TArray<TMarker>;
    procedure Check(Condition: Boolean; const Problem: string);
    procedure AssertNoProblems;
    procedure CheckMarkersAgainst(const Caption: string; Map: TModuleCodeMap;
      const LineOracle: ISourceLineProvider; const NameOracle: IFunctionNameProvider;
      const AddressOracle: ISourceLineProvider);
    procedure CheckMapsAreIdentical(const Caption: string; Expected, Actual: TModuleCodeMap);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // --- the provider tables, against the same reader's point lookups ---
    [Test] procedure Td32_LineRecordTable_AgreesWithThePointLookups;
    [Test] procedure Td32_RoutineRanges_AgreeWithThePointLookups;
    // The unit of a line record comes from a second walk of the line tables;
    // the unit a routine is DECLARED in comes from the symbol streams. Two
    // independent paths through the format that must name the same unit.
    [Test] procedure Td32_LineRecordUnit_IsTheUnitThatDeclaresTheRoutine;
    // The external .tds path is the same class with a different blob.
    [Test] procedure Td32_ExternalTds_SuppliesBothTables;

    // --- the code map on the fixtures ---
    [Test] procedure Markers_AreLineRecordsInTheRoutineTheProvidersName;
    [Test] procedure RecordsOutsideEveryRoutine_MatchTheProvidersRecordByRecord;
    [Test] procedure ModuleRelativeRvas_AreTheSameFromTheFileAndThroughAShiftedProvider;
    [Test] procedure CodeLength_ReachesTheNextRecordOrTheRoutineEnd;
    [Test] procedure Lookups_RoundTripOverEveryRecord;
    [Test] procedure Resolver_IsAskedOncePerFile;

    // --- the code map on hand-built tables ---
    [Test] procedure Synthetic_OverlapsUnsortedInputAndDroppedRows;
    [Test] procedure PickProviders_PrefersOneProviderForBothTables;
    [Test] procedure PickProviders_WithoutBothTables_ReportsNotMeasurable;
    [Test] procedure Build_WithoutAProvider_Raises;

    // --- a second routine provider (TD32 has no procedure record for the body
    //     of an anonymous method; a MAP names it) ---
    [Test] procedure SecondRoutineProvider_Synthetic_AddsOnlyWhatTheFirstLeavesOut;
    [Test] procedure SecondRoutineProvider_OnTheFixtures_NamesAnonymousMethodBodies;
    [Test] procedure PickSecondRoutineProvider_IsTheNextOneThatHasRanges;

    // --- the other formats ---
    // ONE test for the MAP on purpose: a MAP loaded unshifted writes an index
    // sidecar beside itself, and two tests doing that in two worker processes
    // would race on the file.
    [Test] procedure Map_Tables_MarkersRoutineEndsAndUnits;
    [Test] procedure Jdbg_Markers_AreLineRecordsInTheRoutineJclNames;
  end;

implementation

uses
  System.Classes, System.IOUtils,
  MapFileReader, JclDebugReader, PeSymbolSupport, TestTempDirs;

const
  MARKER_SOURCE = 'TestTargetCore.pas';
  // At least this share of the marker lines must have code in a binary, or a
  // marker test would pass having checked nothing. Not every marker has code
  // everywhere: the executable's linker drops routines only the package calls.
  MIN_MARKER_SHARE = 0.5;
  MAX_PROBLEMS_SHOWN = 25;

type
  // Hand-built tables, for the cases no compiler output contains.
  TFakeTables = class(TInterfacedObject, ILineRecordProvider, IRoutineRangeProvider)
  public
    Table:            TLineRecordTable;
    Ranges:           TArray<TRoutineRange>;
    LinesComplete:    Boolean;
    RoutinesComplete: Boolean;
    function LineRecordTable(out Complete: Boolean): TLineRecordTable;
    function RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
  end;

  TFakeLinesOnly = class(TInterfacedObject, ILineRecordProvider)
  public
    function LineRecordTable(out Complete: Boolean): TLineRecordTable;
  end;

  TFakeRoutinesOnly = class(TInterfacedObject, IRoutineRangeProvider)
  public
    function RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
  end;

function TFakeTables.LineRecordTable(out Complete: Boolean): TLineRecordTable;
begin
  Complete := LinesComplete;
  Result := Table;
  // A provider hands out a table the caller owns.
  Result.Records := Copy(Table.Records);
end;

function TFakeTables.RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
begin
  Complete := RoutinesComplete;
  Result := Copy(Ranges);
end;

function TFakeLinesOnly.LineRecordTable(out Complete: Boolean): TLineRecordTable;
begin
  Complete := True;
  Result := Default(TLineRecordTable);
end;

function TFakeRoutinesOnly.RoutineRanges(out Complete: Boolean): TArray<TRoutineRange>;
begin
  Complete := True;
  Result := nil;
end;

{ TCodeMapTests: plumbing }

procedure TCodeMapTests.Setup;
begin
  FProblems := TList<string>.Create;
end;

procedure TCodeMapTests.TearDown;
begin
  FreeAndNil(FProblems);
end;

procedure TCodeMapTests.Check(Condition: Boolean; const Problem: string);
begin
  if not Condition then
    FProblems.Add(Problem);
end;

procedure TCodeMapTests.AssertNoProblems;
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

function TCodeMapTests.FixtureRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\');
end;

function TCodeMapTests.LoadOne(const Caption, RelativePath: string;
  OutputRvaShift: UInt64): TLoadedBinary;
begin
  Result := Default(TLoadedBinary);
  Result.Caption := Caption;
  Result.Path    := FixtureRoot + RelativePath;
  Result.MapPath := ChangeFileExt(Result.Path, '.map');
  if not TFile.Exists(Result.Path) then
    Assert.Fail(Format('%s fixture not found at %s -- run build_and_run.bat', [Caption, Result.Path]));
  Result.ImageSize := ReadPEImageSize(Result.Path);
  Result.Reader := TTD32FileReader.Create;
  Result.Keep   := Result.Reader;
  Result.Reader.LoadFromFile(Result.Path, OutputRvaShift);
end;

function TCodeMapTests.LoadBinaries: TArray<TLoadedBinary>;
begin
  Result := [
    LoadOne('exe x64', 'TestTarget\Win64\Debug\TestTarget.exe'),
    LoadOne('exe x86', 'TestTarget\Win32\Debug\TestTarget.exe'),
    LoadOne('bpl x64', 'TestHost\Win64\Debug\TestSubject.bpl'),
    LoadOne('bpl x86', 'TestHost\Win32\Debug\TestSubject.bpl')];
end;

function TCodeMapTests.BuildMap(const Binary: TLoadedBinary;
  OutputRvaShift: UInt64): TModuleCodeMap;
begin
  Result := TModuleCodeMap.Build(ExtractFileName(Binary.Path), Binary.Reader, Binary.Reader,
    OutputRvaShift, Binary.ImageSize);
end;

function TCodeMapTests.Markers: TArray<TMarker>;
const
  OPENING = '{BP:';
begin
  Result := [];
  var Source := TStringList.Create;
  try
    Source.LoadFromFile(FixtureRoot + 'TestTarget\' + MARKER_SOURCE);
    for var I := 0 to Source.Count - 1 do begin
      var Start := Source[I].IndexOf(OPENING);
      if Start < 0 then
        Continue;
      var Stop := Source[I].IndexOf('}', Start);
      if Stop < 0 then
        Continue;
      var Name := Source[I].Substring(Start + OPENING.Length, Stop - Start - OPENING.Length);
      // The header comment describes the convention as `{BP:<NAME>}`.
      if (Name = '') or (Name.IndexOfAny(['<', '>', ' ']) >= 0) then
        Continue;
      var Marker: TMarker;
      Marker.Name := Name;
      Marker.Line := I + 1;
      Result := Result + [Marker];
    end;
  finally
    Source.Free;
  end;
  Assert.IsTrue(Length(Result) > 50,
    Format('only %d markers found in %s: the scan is broken', [Length(Result), MARKER_SOURCE]));
end;

{ Provider tables }

procedure TCodeMapTests.Td32_LineRecordTable_AgreesWithThePointLookups;
begin
  for var Binary in LoadBinaries do begin
    var Complete: Boolean;
    var Table := Binary.Reader.LineRecordTable(Complete);
    var Rvas := Binary.Reader.SortedRvas;
    Check(Complete, Binary.Caption + ': the TD32 line table must be complete');
    Check(Length(Table.Records) > 1000,
      Format('%s: only %d line records', [Binary.Caption, Length(Table.Records)]));
    Check(Length(Table.Records) = Length(Rvas),
      Format('%s: %d records against %d line addresses', [Binary.Caption, Length(Table.Records), Length(Rvas)]));
    if Length(Table.Records) <> Length(Rvas) then
      Continue;
    var WithoutUnit := 0;
    for var I := 0 to High(Table.Records) do begin
      var Rec := Table.Records[I];
      Check(Rec.Rva = Rvas[I], Format('%s: record %d is at $%x, SortedRvas has $%x',
        [Binary.Caption, I, Rec.Rva, Rvas[I]]));
      Check((I = 0) or (Rec.Rva > Table.Records[I - 1].Rva),
        Format('%s: record %d ($%x) does not follow the one before it', [Binary.Caption, I, Rec.Rva]));
      if (Rec.FileIndex < 0) or (Rec.FileIndex > High(Table.Files)) then begin
        Check(False, Format('%s: record %d has file index %d', [Binary.Caption, I, Rec.FileIndex]));
        Continue;
      end;
      var Loc: TSourceLocation;
      if not Binary.Reader.RvaToSourceLine(Rec.Rva, Loc) then begin
        Check(False, Format('%s: RvaToSourceLine does not know record $%x', [Binary.Caption, Rec.Rva]));
        Continue;
      end;
      Check(Loc.Line = Rec.Line, Format('%s: $%x is line %d in the table, %d by lookup',
        [Binary.Caption, Rec.Rva, Rec.Line, Loc.Line]));
      Check(Loc.SourceFile = Table.Files[Rec.FileIndex].Name,
        Format('%s: $%x is in "%s" in the table, "%s" by lookup',
          [Binary.Caption, Rec.Rva, Table.Files[Rec.FileIndex].Name, Loc.SourceFile]));
      if (Rec.UnitIndex < 0) or (Rec.UnitIndex > High(Table.Units)) then
        Inc(WithoutUnit);
    end;
    Check(WithoutUnit = 0, Format('%s: %d line records without a unit', [Binary.Caption, WithoutUnit]));
    for var FileEntry in Table.Files do
      Check(FileEntry.FullPath = '',
        Format('%s: TD32 keeps file names only, yet "%s" has path "%s"',
          [Binary.Caption, FileEntry.Name, FileEntry.FullPath]));
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.Td32_RoutineRanges_AgreeWithThePointLookups;
begin
  for var Binary in LoadBinaries do begin
    var Complete: Boolean;
    var Ranges := Binary.Reader.RoutineRanges(Complete);
    Check(Complete, Binary.Caption + ': the TD32 routine table must be complete');
    Check(Length(Ranges) > 100, Format('%s: only %d routines', [Binary.Caption, Length(Ranges)]));
    for var I := 0 to High(Ranges) do begin
      var Range := Ranges[I];
      Check((I = 0) or (Range.StartRva > Ranges[I - 1].StartRva),
        Format('%s: routine %d ($%x) does not follow the one before it', [Binary.Caption, I, Range.StartRva]));
      Check(not Range.EndIsApproximate,
        Format('%s: %s has an approximate end; TD32 records the length', [Binary.Caption, Range.Name]));
      if Range.EndRva <= Range.StartRva then
        Continue;   // an empty record contains no address to ask about
      var Start: UInt64;
      var Name: string;
      Check(Binary.Reader.RvaToFunctionStart(Range.StartRva, Start) and (Start = Range.StartRva),
        Format('%s: RvaToFunctionStart($%x) does not answer with the range start', [Binary.Caption, Range.StartRva]));
      Check(Binary.Reader.RvaToFunctionName(Range.StartRva, Name) and (Name = Range.Name),
        Format('%s: $%x is "%s" in the table, "%s" by lookup', [Binary.Caption, Range.StartRva, Range.Name, Name]));
      // The last byte belongs to the routine unless another one starts inside it.
      if (I = High(Ranges)) or (Ranges[I + 1].StartRva >= Range.EndRva) then begin
        Check(Binary.Reader.RvaToFunctionStart(Range.EndRva - 1, Start) and (Start = Range.StartRva),
          Format('%s: the last byte of %s ($%x) is not in it by lookup', [Binary.Caption, Range.Name, Range.EndRva - 1]));
        Check(not (Binary.Reader.RvaToFunctionStart(Range.EndRva, Start) and (Start = Range.StartRva)),
          Format('%s: the end of %s ($%x) is exclusive, yet the lookup puts it inside', [Binary.Caption, Range.Name, Range.EndRva]));
      end;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.Td32_LineRecordUnit_IsTheUnitThatDeclaresTheRoutine;
begin
  for var Binary in LoadBinaries do begin
    var Complete: Boolean;
    var Table := Binary.Reader.LineRecordTable(Complete);
    var Ranges := Binary.Reader.RoutineRanges(Complete);
    var UnitAt := TDictionary<UInt64, Integer>.Create;
    var NamesAt := TDictionary<UInt64, string>.Create;
    try
      for var Rec in Table.Records do
        UnitAt.Add(Rec.Rva, Rec.UnitIndex);
      for var Range in Ranges do
        NamesAt.Add(Range.StartRva, Range.Name);
      var Checked := 0;
      var Exact := 0;
      for var Range in Ranges do begin
        var UnitIndex: Integer;
        if not UnitAt.TryGetValue(Range.StartRva, UnitIndex) or (UnitIndex < 0) then
          Continue;   // no line record at the routine's first byte
        Inc(Checked);
        var Declared: UInt64;
        if not Binary.Reader.FindFuncRvaInUnit(Range.Name, Table.Units[UnitIndex], Declared) then begin
          Check(False, Format('%s: %s at $%x has line-record unit "%s", but that unit declares no such routine',
            [Binary.Caption, Range.Name, Range.StartRva, Table.Units[UnitIndex]]));
          Continue;
        end;
        if Declared = Range.StartRva then begin
          Inc(Exact);
          Continue;
        end;
        // The unit-scoped index keeps the first routine of a name per unit, so
        // an overload answers with a sibling: same unit, same name.
        var Sibling: string;
        Check(NamesAt.TryGetValue(Declared, Sibling) and (Sibling = Range.Name),
          Format('%s: %s at $%x: unit "%s" declares that name at $%x, which is not a routine of that name',
            [Binary.Caption, Range.Name, Range.StartRva, Table.Units[UnitIndex], Declared]));
      end;
      Check(Checked > 100, Format('%s: only %d routines could be checked', [Binary.Caption, Checked]));
      Check(Exact * 10 >= Checked * 9,
        Format('%s: only %d of %d routines are declared at their own start in the unit of their line record',
          [Binary.Caption, Exact, Checked]));
    finally
      NamesAt.Free;
      UnitAt.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.Td32_ExternalTds_SuppliesBothTables;
begin
  var ExePath := FixtureRoot + 'TestTarget\Win64\Debug\TdsSample.exe';
  var TdsPath := ChangeFileExt(ExePath, '.tds');
  Assert.IsTrue(TFile.Exists(ExePath) and TFile.Exists(TdsPath),
    'TdsSample fixture missing -- run build_and_run.bat');
  var Reader := TTD32FileReader.Create;
  var Keep: IInterface := Reader;
  Reader.LoadFromTdsFile(TdsPath, ExePath);

  var Map := TModuleCodeMap.Build('TdsSample.exe', Reader, Reader, 0, ReadPEImageSize(ExePath));
  try
    Assert.IsTrue(Map.Complete, 'a .tds is parsed in full');
    Assert.IsTrue(Length(Map.Lines) > 0, 'no line records from the .tds');
    Assert.IsTrue(Length(Map.Routines) > 0, 'no routines from the .tds');
    Assert.AreEqual(0, Map.DroppedLineCount, 'line records outside the image');
    for var I := 0 to High(Map.Lines) do begin
      var Line := Map.Lines[I];
      var Loc: TSourceLocation;
      Check(Reader.RvaToSourceLine(Line.Rva, Loc) and (Loc.Line = Line.Line) and
            (Loc.SourceFile = Map.Files[Line.FileIndex].Name),
        Format('tds: $%x is %s:%d in the map, %s:%d by lookup',
          [Line.Rva, Map.Files[Line.FileIndex].Name, Line.Line, Loc.SourceFile, Loc.Line]));
      var Start: UInt64;
      var Named := Reader.RvaToFunctionStart(Line.Rva, Start);
      Check(Named = Line.InRoutine, Format('tds: $%x in a routine: map %s, lookup %s',
        [Line.Rva, BoolToStr(Line.InRoutine, True), BoolToStr(Named, True)]));
    end;
  finally
    Map.Free;
  end;
  AssertNoProblems;
end;

{ The code map on the fixtures }

procedure TCodeMapTests.CheckMarkersAgainst(const Caption: string; Map: TModuleCodeMap;
  const LineOracle: ISourceLineProvider; const NameOracle: IFunctionNameProvider;
  const AddressOracle: ISourceLineProvider);
// For every marker line: if AddressOracle can bind it, the map must hold a
// record for it AT that address, and every record of the line must sit in the
// routine NameOracle names for its address -- or outside every routine when it
// names none (the body of an anonymous method has no procedure record).
begin
  var Files := Map.FindFiles(MARKER_SOURCE);
  Check(Length(Files) = 1, Format('%s: %d files named %s in the map', [Caption, Length(Files), MARKER_SOURCE]));
  if Length(Files) <> 1 then
    Exit;
  var AllMarkers := Markers;
  var WithCode := 0;
  var InRoutines := 0;
  for var Marker in AllMarkers do begin
    var Records := Map.LinesAt(Files[0], Marker.Line);
    var BoundAt: UInt64;
    if not AddressOracle.SourceLineToRva(MARKER_SOURCE, Marker.Line, BoundAt) then begin
      Check(Length(Records) = 0, Format('%s: marker %s (line %d) has no code by lookup, yet %d records in the map',
        [Caption, Marker.Name, Marker.Line, Length(Records)]));
      Continue;
    end;
    Inc(WithCode);
    if Length(Records) = 0 then begin
      Check(False, Format('%s: marker %s (line %d) binds at $%x, yet the map has no record for the line',
        [Caption, Marker.Name, Marker.Line, BoundAt]));
      Continue;
    end;
    var AtBoundAddress := False;
    for var LineIndex in Records do begin
      var Line := Map.Lines[LineIndex];
      if Line.Rva = BoundAt then
        AtBoundAddress := True;
      var Loc: TSourceLocation;
      Check(LineOracle.RvaToSourceLine(Line.Rva, Loc) and (Loc.Line = Marker.Line),
        Format('%s: marker %s: the map has $%x on line %d, the lookup says line %d',
          [Caption, Marker.Name, Line.Rva, Marker.Line, Loc.Line]));
      var Start: UInt64;
      if not NameOracle.RvaToFunctionStart(Line.Rva, Start) then begin
        if Line.InRoutine then
          Check(False, Format('%s: marker %s at $%x is in routine "%s" in the map, in none by lookup',
            [Caption, Marker.Name, Line.Rva, Map.Routines[Line.RoutineIndex].Name]));
        Continue;
      end;
      if not Line.InRoutine then begin
        Check(False, Format('%s: marker %s at $%x is outside every routine in the map; the lookup puts it in the one at $%x',
          [Caption, Marker.Name, Line.Rva, Start]));
        Continue;
      end;
      Inc(InRoutines);
      var Routine := Map.Routines[Line.RoutineIndex];
      var Name: string;
      NameOracle.RvaToFunctionName(Line.Rva, Name);
      Check(Routine.StartRva = Start, Format('%s: marker %s at $%x: routine starts at $%x in the map, $%x by lookup',
        [Caption, Marker.Name, Line.Rva, Routine.StartRva, Start]));
      Check(Routine.Name = Name, Format('%s: marker %s at $%x: routine "%s" in the map, "%s" by lookup',
        [Caption, Marker.Name, Line.Rva, Routine.Name, Name]));
      Check((Line.Rva >= Routine.StartRva) and (Line.Rva < Routine.EndRva),
        Format('%s: marker %s at $%x is not inside [$%x, $%x)',
          [Caption, Marker.Name, Line.Rva, Routine.StartRva, Routine.EndRva]));
    end;
    Check(AtBoundAddress, Format('%s: marker %s (line %d) binds at $%x, which is not one of the line''s %d records',
      [Caption, Marker.Name, Marker.Line, BoundAt, Length(Records)]));
  end;
  Check(WithCode >= MIN_MARKER_SHARE * Length(AllMarkers),
    Format('%s: only %d of %d markers have code', [Caption, WithCode, Length(AllMarkers)]));
  Check(InRoutines >= WithCode div 2,
    Format('%s: only %d marker records are inside a routine (%d markers have code)', [Caption, InRoutines, WithCode]));
end;

procedure TCodeMapTests.Markers_AreLineRecordsInTheRoutineTheProvidersName;
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      CheckMarkersAgainst(Binary.Caption, Map, Binary.Reader, Binary.Reader, Binary.Reader);
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.RecordsOutsideEveryRoutine_MatchTheProvidersRecordByRecord;
// The count DevTools\LineSiteSurvey reports as "records outside every TD32
// procedure range" (28 on the x64 executable, 32 on the x86 one when this was
// written) is computed here the way that tool computes it, from the reader's
// own lookups, so the test follows the binary when the fixture changes.
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      var Rvas := Binary.Reader.SortedRvas;
      Check(Length(Map.Lines) = Length(Rvas),
        Format('%s: %d records in the map, %d line addresses', [Binary.Caption, Length(Map.Lines), Length(Rvas)]));
      Check(Map.DroppedLineCount + Map.DroppedRoutineCount = 0,
        Format('%s: %d line records and %d routines dropped', [Binary.Caption, Map.DroppedLineCount, Map.DroppedRoutineCount]));
      var Expected := 0;
      for var Rva in Rvas do begin
        var Start: UInt64;
        if not Binary.Reader.RvaToFunctionStart(Rva, Start) then
          Inc(Expected);
      end;
      Check(Expected > 0, Binary.Caption + ': no record lies outside a routine, so the test proves nothing');
      Check(Map.OutsideRoutineCount = Expected,
        Format('%s: %d records outside every routine in the map, %d by lookup',
          [Binary.Caption, Map.OutsideRoutineCount, Expected]));
      var Flagged := 0;
      for var I := 0 to High(Map.Lines) do begin
        var Line := Map.Lines[I];
        if not Line.InRoutine then
          Inc(Flagged);
        var Start: UInt64;
        var Named := Binary.Reader.RvaToFunctionStart(Line.Rva, Start);
        if Named <> Line.InRoutine then
          Check(False, Format('%s: $%x in a routine: map %s, lookup %s',
            [Binary.Caption, Line.Rva, BoolToStr(Line.InRoutine, True), BoolToStr(Named, True)]))
        else if Named then
          Check(Map.Routines[Line.RoutineIndex].StartRva = Start,
            Format('%s: $%x: routine at $%x in the map, $%x by lookup',
              [Binary.Caption, Line.Rva, Map.Routines[Line.RoutineIndex].StartRva, Start]));
      end;
      Check(Flagged = Map.OutsideRoutineCount,
        Format('%s: %d records flagged, counter says %d', [Binary.Caption, Flagged, Map.OutsideRoutineCount]));
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.CheckMapsAreIdentical(const Caption: string;
  Expected, Actual: TModuleCodeMap);
begin
  Check(Length(Expected.Lines) = Length(Actual.Lines),
    Format('%s: %d line records, expected %d', [Caption, Length(Actual.Lines), Length(Expected.Lines)]));
  Check(Length(Expected.Routines) = Length(Actual.Routines),
    Format('%s: %d routines, expected %d', [Caption, Length(Actual.Routines), Length(Expected.Routines)]));
  Check(Actual.DroppedLineCount + Actual.DroppedRoutineCount = 0,
    Format('%s: %d line records and %d routines dropped', [Caption, Actual.DroppedLineCount, Actual.DroppedRoutineCount]));
  Check(Expected.OutsideRoutineCount = Actual.OutsideRoutineCount,
    Format('%s: %d records outside every routine, expected %d',
      [Caption, Actual.OutsideRoutineCount, Expected.OutsideRoutineCount]));
  if (Length(Expected.Lines) <> Length(Actual.Lines)) or
     (Length(Expected.Routines) <> Length(Actual.Routines)) then
    Exit;
  for var I := 0 to High(Expected.Lines) do begin
    var Want := Expected.Lines[I];
    var Got  := Actual.Lines[I];
    Check((Want.Rva = Got.Rva) and (Want.CodeLength = Got.CodeLength) and (Want.Line = Got.Line) and
          (Want.RoutineIndex = Got.RoutineIndex) and
          (Expected.Files[Want.FileIndex].Name = Actual.Files[Got.FileIndex].Name) and
          (Expected.UnitName(Want.UnitIndex) = Actual.UnitName(Got.UnitIndex)),
      Format('%s: line record %d differs: $%x len %d line %d routine %d, expected $%x len %d line %d routine %d',
        [Caption, I, Got.Rva, Got.CodeLength, Got.Line, Got.RoutineIndex,
         Want.Rva, Want.CodeLength, Want.Line, Want.RoutineIndex]));
  end;
  for var I := 0 to High(Expected.Routines) do begin
    var Want := Expected.Routines[I];
    var Got  := Actual.Routines[I];
    Check((Want.StartRva = Got.StartRva) and (Want.EndRva = Got.EndRva) and (Want.Name = Got.Name) and
          (Want.FirstLine = Got.FirstLine) and (Want.LineCount = Got.LineCount) and
          (Expected.UnitName(Want.UnitIndex) = Actual.UnitName(Got.UnitIndex)),
      Format('%s: routine %d differs: %s [$%x, $%x), expected %s [$%x, $%x)',
        [Caption, I, Got.Name, Got.StartRva, Got.EndRva, Want.Name, Want.StartRva, Want.EndRva]));
  end;
end;

procedure TCodeMapTests.ModuleRelativeRvas_AreTheSameFromTheFileAndThroughAShiftedProvider;
// The engine loads a package's reader with OutputRvaShift = Base - exeImageBase.
// Two shifts: a package above the executable, and one BELOW it, whose shift is
// that difference modulo 2^64 -- every RVA of such a provider sits at the top
// of the 64-bit range.
const
  SHIFT_ABOVE = UInt64($0000000712340000);
  SHIFT_BELOW = UInt64($FFFFFFFFFF210000);
  PACKAGES: array[0..1] of string = ('Win64', 'Win32');
begin
  for var Platform in PACKAGES do begin
    var RelativePath := 'TestHost\' + Platform + '\Debug\TestSubject.bpl';
    var FromFile := LoadOne('bpl ' + Platform, RelativePath);
    var Reference := BuildMap(FromFile);
    try
      Check(Length(Reference.Lines) > 1000,
        Format('bpl %s: only %d line records', [Platform, Length(Reference.Lines)]));
      var Shifts: TArray<UInt64> := [SHIFT_ABOVE, SHIFT_BELOW];
      for var Shift in Shifts do begin
        var Caption := Format('bpl %s shifted by $%x', [Platform, Shift]);
        var Shifted := LoadOne(Caption, RelativePath, Shift);
        // The provider really is shifted: its first record is not where the file's is.
        Check(Shifted.Reader.SortedRvas[0] <> FromFile.Reader.SortedRvas[0],
          Caption + ': the shifted reader answers in the file''s RVA space, so the test proves nothing');
        var Map := BuildMap(Shifted, Shift);
        try
          CheckMapsAreIdentical(Caption, Reference, Map);
        finally
          Map.Free;
        end;
      end;
    finally
      Reference.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.CodeLength_ReachesTheNextRecordOrTheRoutineEnd;
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      for var I := 0 to High(Map.Lines) do begin
        var Line := Map.Lines[I];
        var Bound: UInt64 := 0;
        if I < High(Map.Lines) then
          Bound := Map.Lines[I + 1].Rva;
        if Line.InRoutine then begin
          var RoutineEnd: UInt64 := Map.Routines[Line.RoutineIndex].EndRva;
          if (Bound = 0) or (RoutineEnd < Bound) then
            Bound := RoutineEnd;
          Check(Line.CodeLength > 0, Format('%s: $%x is in a routine and has no length', [Binary.Caption, Line.Rva]));
        end;
        if (Bound = 0) or Line.InRoutine then
          Check((Bound = 0) or (UInt64(Line.Rva) + Line.CodeLength = Bound),
            Format('%s: $%x has length %d, which does not end at $%x',
              [Binary.Caption, Line.Rva, Line.CodeLength, Bound]))
        else
          // Outside a routine the next ROUTINE may come before the next record.
          Check(UInt64(Line.Rva) + Line.CodeLength <= Bound,
            Format('%s: $%x (outside every routine) has length %d, past the next record at $%x',
              [Binary.Caption, Line.Rva, Line.CodeLength, Bound]));
      end;
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.Lookups_RoundTripOverEveryRecord;
begin
  for var Binary in LoadBinaries do begin
    var Map := BuildMap(Binary);
    try
      for var I := 0 to High(Map.Lines) do begin
        var Line := Map.Lines[I];
        Check(Map.FindLine(Line.Rva) = I, Format('%s: FindLine($%x) <> %d', [Binary.Caption, Line.Rva, I]));
        if Line.CodeLength > 0 then begin
          Check(Map.FindLineCovering(Line.Rva + Line.CodeLength - 1) = I,
            Format('%s: the last byte of record $%x is not covered by it', [Binary.Caption, Line.Rva]));
          if Line.CodeLength > 1 then
            Check(Map.FindLine(Line.Rva + 1) = -1,
              Format('%s: FindLine finds a record inside the code of $%x', [Binary.Caption, Line.Rva]));
        end;
        Check(Map.FindRoutine(Line.Rva) = Line.RoutineIndex,
          Format('%s: FindRoutine($%x) = %d, the record says %d',
            [Binary.Caption, Line.Rva, Map.FindRoutine(Line.Rva), Line.RoutineIndex]));
        var Found := False;
        var Previous: Int64 := -1;
        for var Candidate in Map.LinesAt(Line.FileIndex, Line.Line) do begin
          if Candidate = I then
            Found := True;
          Check(Map.Lines[Candidate].Rva > Previous,
            Format('%s: LinesAt(%d, %d) is not in address order', [Binary.Caption, Line.FileIndex, Line.Line]));
          Previous := Map.Lines[Candidate].Rva;
        end;
        Check(Found, Format('%s: LinesAt does not return record $%x for its own file and line', [Binary.Caption, Line.Rva]));
      end;
      var Listed := 0;
      for var FileIndex := 0 to High(Map.Files) do
        Inc(Listed, Length(Map.LinesOfFile(FileIndex)));
      Check(Listed = Length(Map.Lines),
        Format('%s: the files list %d records, the map has %d', [Binary.Caption, Listed, Length(Map.Lines)]));
      for var R := 0 to High(Map.Routines) do begin
        var Routine := Map.Routines[R];
        if Routine.EndRva > Routine.StartRva then
          Check(Map.FindRoutine(Routine.StartRva) = R,
            Format('%s: FindRoutine does not find %s at its own start', [Binary.Caption, Routine.Name]));
        for var Offset := 0 to Routine.LineCount - 1 do
          Check(Map.Lines[Routine.FirstLine + Offset].RoutineIndex = R,
            Format('%s: record %d of %s belongs to another routine', [Binary.Caption, Offset, Routine.Name]));
      end;
      Check(Length(Map.FindFiles(UpperCase(MARKER_SOURCE))) = 1,
        Binary.Caption + ': FindFiles must ignore case');
      Check(Length(Map.FindFiles('C:\somewhere\else\' + MARKER_SOURCE)) = 1,
        Binary.Caption + ': FindFiles must fall back to the file name when no path matches');
      Check(Length(Map.FindFiles('NoSuchFile.pas')) = 0, Binary.Caption + ': FindFiles invented a file');
      Check(Length(Map.LinesAt(-1, 1)) + Length(Map.LinesAt(Length(Map.Files), 1)) = 0,
        Binary.Caption + ': LinesAt accepted a file index out of range');
    finally
      Map.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.Resolver_IsAskedOncePerFile;
const
  FAKE_ROOT = 'C:\resolved-by-the-test\';
begin
  var Binary := LoadOne('exe x64', 'TestTarget\Win64\Debug\TestTarget.exe');
  var Asked := 0;
  var Map := TModuleCodeMap.Build('TestTarget.exe', Binary.Reader, Binary.Reader, 0, Binary.ImageSize,
    function(const FileName, RecordedPath: string): string
    begin
      Inc(Asked);
      Result := '';
      if not SameText(FileName, MARKER_SOURCE) then
        Result := FAKE_ROOT + FileName;
    end);
  try
    Assert.AreEqual(Integer(Length(Map.Files)), Asked, 'the resolver is asked once for every file');
    for var FileEntry in Map.Files do
      if SameText(FileEntry.Name, MARKER_SOURCE) then
        Assert.AreEqual('', FileEntry.ResolvedPath, 'a file the resolver does not find stays unresolved')
      else
        Assert.AreEqual(FAKE_ROOT + FileEntry.Name, FileEntry.ResolvedPath);
    // A path only the resolver knows selects the file.
    var Other := '';
    for var FileEntry in Map.Files do
      if FileEntry.ResolvedPath <> '' then
        Other := FileEntry.ResolvedPath;
    Assert.AreEqual(1, Integer(Length(Map.FindFiles(Other))), 'FindFiles by resolved path');
  finally
    Map.Free;
  end;

  var Plain := BuildMap(Binary);
  try
    for var FileEntry in Plain.Files do
      Assert.AreEqual('', FileEntry.ResolvedPath, 'no resolver, no resolved path');
  finally
    Plain.Free;
  end;
end;

{ The code map on hand-built tables }

procedure TCodeMapTests.Synthetic_OverlapsUnsortedInputAndDroppedRows;
const
  SHIFT = UInt64($10000000);
  IMAGE_SIZE = $1000;

  function Routine(StartRva, EndRva: UInt64; const Name, UnitName: string; Approximate: Boolean): TRoutineRange;
  begin
    Result := Default(TRoutineRange);
    Result.StartRva := SHIFT + StartRva;
    Result.EndRva   := SHIFT + EndRva;
    Result.Name     := Name;
    Result.UnitName := UnitName;
    Result.EndIsApproximate := Approximate;
  end;

  function Line(Rva: UInt64; FileIndex, LineNumber, UnitIndex: Integer): TLineRecord;
  begin
    Result.Rva       := SHIFT + Rva;
    Result.FileIndex := FileIndex;
    Result.Line      := LineNumber;
    Result.UnitIndex := UnitIndex;
  end;

begin
  var Fake := TFakeTables.Create;
  var Provider: IInterface := Fake;
  Fake.LinesComplete    := False;
  Fake.RoutinesComplete := True;
  // B lies INSIDE A's range, as a nested range would. Out of order on purpose.
  Fake.Ranges := [
    Routine(150, 160, 'B', '', False),
    Routine(100, 200, 'A', 'UnitA', False),
    Routine(300, 340, 'C', '', True),
    Routine($2000, $2010, 'OutOfImage', '', False)];
  Fake.Table.Files := [Default(TLineRecordFile), Default(TLineRecordFile)];
  Fake.Table.Files[0].Name := 'First.pas';
  Fake.Table.Files[1].Name := 'Second.pas';
  Fake.Table.Files[1].FullPath := 'D:\src\Second.pas';
  Fake.Table.Units := ['UnitX'];
  Fake.Table.Records := [
    Line(250, 0, 13, -1),
    Line(90, 0, 1, -1),
    Line(100, 0, 10, 0),
    Line(120, 0, 11, -1),
    Line(120, 0, 11, -1),     // the same address twice
    Line(150, 1, 5, 0),
    Line(155, 1, 5, -1),
    Line(170, 0, 12, -1),
    Line(310, 1, 7, -1),
    Line(130, 9, 1, -1),      // no such file
    Line($5000, 0, 1, -1)];   // outside the image

  var Map := TModuleCodeMap.Build('fake', Fake, Fake, SHIFT, IMAGE_SIZE);
  try
    Assert.IsFalse(Map.LinesComplete, 'the line provider said incomplete');
    Assert.IsTrue(Map.RoutinesComplete);
    Assert.IsFalse(Map.Complete, 'one incomplete table makes the map incomplete');

    Assert.AreEqual(3, Integer(Length(Map.Routines)), 'routines kept');
    Assert.AreEqual(1, Map.DroppedRoutineCount, 'the routine outside the image is dropped');
    Assert.AreEqual('A', Map.Routines[0].Name);
    Assert.AreEqual('B', Map.Routines[1].Name);
    Assert.AreEqual('C', Map.Routines[2].Name);
    Assert.AreEqual(100, Integer(Map.Routines[0].StartRva), 'module-relative start');
    Assert.AreEqual(200, Integer(Map.Routines[0].EndRva), 'the end is kept as recorded');
    Assert.IsTrue(Map.Routines[2].EndIsApproximate);

    Assert.AreEqual(8, Integer(Length(Map.Lines)), 'line records kept');
    Assert.AreEqual(3, Map.DroppedLineCount, 'a repeated address, an unknown file, an address outside the image');
    Assert.AreEqual(3, Map.OutsideRoutineCount, 'records at 90, 170 and 250');

    // rva, routine (-1 = outside), code length
    var Expected: TArray<TArray<Integer>> := [
      [90, -1, 10],    // to the next routine and the next record, both at 100
      [100, 0, 20],
      [120, 0, 30],    // A stops owning addresses where B starts
      [150, 1, 5],
      [155, 1, 5],     // to B's end
      [170, -1, 80],   // past B's end: the nearest start is B's, so it is in no routine
      [250, -1, 50],   // to C's start, before the next record
      [310, 2, 30]];   // the last record: to C's end
    for var I := 0 to High(Expected) do begin
      Assert.AreEqual(Expected[I][0], Integer(Map.Lines[I].Rva), Format('record %d: address', [I]));
      Assert.AreEqual(Expected[I][1], Map.Lines[I].RoutineIndex, Format('record at %d: routine', [Expected[I][0]]));
      Assert.AreEqual(Expected[I][2], Integer(Map.Lines[I].CodeLength), Format('record at %d: length', [Expected[I][0]]));
    end;

    Assert.AreEqual(1, Map.Routines[0].FirstLine, 'A starts at the record at 100');
    Assert.AreEqual(2, Map.Routines[0].LineCount, 'A owns 100 and 120');
    Assert.AreEqual(2, Map.Routines[1].LineCount, 'B owns 150 and 155');
    Assert.AreEqual(1, Map.Routines[2].LineCount);

    // Units: A has its own; B takes its first record's; C and its record have none.
    Assert.AreEqual('UnitA', Map.UnitName(Map.Routines[0].UnitIndex));
    Assert.AreEqual('UnitX', Map.UnitName(Map.Routines[1].UnitIndex), 'a routine takes the unit of its first record');
    Assert.AreEqual(-1, Map.Routines[2].UnitIndex);
    Assert.AreEqual('UnitX', Map.UnitName(Map.Lines[1].UnitIndex), 'a record keeps its own unit');
    Assert.AreEqual('UnitA', Map.UnitName(Map.Lines[2].UnitIndex), 'a record without one takes its routine''s');
    Assert.AreEqual('UnitX', Map.UnitName(Map.Lines[4].UnitIndex));
    Assert.AreEqual(-1, Map.Lines[0].UnitIndex, 'outside every routine and unknown to the provider');

    Assert.AreEqual(0, Map.FindRoutine(149));
    Assert.AreEqual(1, Map.FindRoutine(155));
    Assert.AreEqual(-1, Map.FindRoutine(170), 'past the end of the routine with the nearest start');
    Assert.AreEqual(-1, Map.FindRoutine(99));
    Assert.AreEqual(2, Map.FindLineCovering(125));
    Assert.AreEqual(-1, Map.FindLineCovering(165), 'between B''s end and the next record');
    Assert.AreEqual(-1, Map.FindLineCovering(50));
    Assert.AreEqual(-1, Map.FindLine(125));

    var SameLine := Map.LinesAt(1, 5);
    Assert.AreEqual(2, Integer(Length(SameLine)), 'two records for Second.pas line 5');
    Assert.AreEqual(3, SameLine[0]);
    Assert.AreEqual(4, SameLine[1]);
    Assert.AreEqual(0, Integer(Length(Map.LinesAt(1, 6))));
    Assert.AreEqual(3, Integer(Length(Map.LinesOfFile(1))));
    Assert.AreEqual(1, Integer(Length(Map.FindFiles('D:\src\Second.pas'))), 'by recorded path');
    Assert.AreEqual('D:\src\Second.pas', Map.Files[1].RecordedPath);
  finally
    Map.Free;
  end;
end;

procedure TCodeMapTests.PickProviders_PrefersOneProviderForBothTables;
begin
  var LinesOnly: IInterface := TFakeLinesOnly.Create;
  var RoutinesOnly: IInterface := TFakeRoutinesOnly.Create;
  var Both: IInterface := TFakeTables.Create;
  var Lines: ILineRecordProvider;
  var Routines: IRoutineRangeProvider;

  Assert.IsTrue(TModuleCodeMap.PickProviders([nil, LinesOnly, RoutinesOnly, Both], Lines, Routines));
  Assert.IsTrue((Lines as TObject) = (Both as TObject), 'the provider of both tables supplies the lines');
  Assert.IsTrue((Routines as TObject) = (Both as TObject), 'and the routines');

  Assert.IsTrue(TModuleCodeMap.PickProviders([RoutinesOnly, LinesOnly], Lines, Routines),
    'two providers of one table each are enough');
  Assert.IsTrue((Lines as TObject) = (LinesOnly as TObject));
  Assert.IsTrue((Routines as TObject) = (RoutinesOnly as TObject));
end;

procedure TCodeMapTests.PickProviders_WithoutBothTables_ReportsNotMeasurable;
begin
  var LinesOnly: IInterface := TFakeLinesOnly.Create;
  var NoTables: IInterface := TInterfacedObject.Create;
  var Lines: ILineRecordProvider;
  var Routines: IRoutineRangeProvider;
  Assert.IsFalse(TModuleCodeMap.PickProviders([NoTables], Lines, Routines));
  Assert.IsTrue((Lines = nil) and (Routines = nil));
  Assert.IsFalse(TModuleCodeMap.PickProviders([NoTables, LinesOnly], Lines, Routines),
    'line records without routine ranges cannot be measured');
  Assert.IsFalse(TModuleCodeMap.PickProviders([], Lines, Routines));
end;

procedure TCodeMapTests.Build_WithoutAProvider_Raises;
begin
  var Fake: ILineRecordProvider := TFakeLinesOnly.Create;
  Assert.WillRaise(
    procedure
    begin
      TModuleCodeMap.Build('fake', Fake, nil, 0, 0).Free;
    end, EArgumentNilException);
  Assert.WillRaise(
    procedure
    begin
      TModuleCodeMap.Build('fake', nil, nil, 0, 0).Free;
    end, EArgumentNilException);
end;

{ A second routine provider }

procedure TCodeMapTests.SecondRoutineProvider_Synthetic_AddsOnlyWhatTheFirstLeavesOut;
const
  IMAGE_SIZE = $2000;
  UNIT_A = 0;
  UNIT_B = 1;

  function Routine(StartRva, EndRva: UInt64; const Name, UnitName: string; Approximate: Boolean): TRoutineRange;
  begin
    Result := Default(TRoutineRange);
    Result.StartRva := StartRva;
    Result.EndRva   := EndRva;
    Result.Name     := Name;
    Result.UnitName := UnitName;
    Result.EndIsApproximate := Approximate;
  end;

  function Line(Rva: UInt64; LineNumber, UnitIndex: Integer): TLineRecord;
  begin
    Result.Rva       := Rva;
    Result.FileIndex := 0;
    Result.Line      := LineNumber;
    Result.UnitIndex := UnitIndex;
  end;

  function OwnerName(Map: TModuleCodeMap; Rva: Cardinal): string;
  begin
    var Index := Map.FindLine(Rva);
    if (Index < 0) or (Map.Lines[Index].RoutineIndex < 0) then
      Exit('');
    Result := Map.Routines[Map.Lines[Index].RoutineIndex].Name;
  end;

begin
  var First := TFakeTables.Create;
  var FirstRef: IInterface := First;
  First.LinesComplete    := True;
  First.RoutinesComplete := True;
  First.Ranges := [
    Routine(100, 200, 'A', 'UnitA', False),
    Routine(300, 400, 'B', 'UnitA', False)];
  First.Table.Files := [Default(TLineRecordFile)];
  First.Table.Files[0].Name := 'Only.pas';
  First.Table.Units := ['UnitA', 'UnitB'];
  First.Table.Records := [
    Line(100, 1, UNIT_A), Line(150, 2, UNIT_A),     // in A
    Line(210, 3, UNIT_B), Line(220, 4, UNIT_B), Line(240, 5, UNIT_B),  // the gap between A and B
    Line(255, 6, UNIT_B), Line(260, 7, UNIT_B),
    Line(300, 8, UNIT_A),                           // in B
    Line(450, 9, UNIT_B), Line(470, 10, UNIT_B),    // after B
    Line(600, 11, UNIT_A),                          // a record of UnitA where UnitB's data is
    Line(700, 12, UNIT_B), Line(710, 13, UNIT_B),   // inside a range with no record on its start
    Line(1000, 14, UNIT_B)];                        // far from everything

  var Second := TFakeTables.Create;
  var SecondRef: IInterface := Second;
  Second.RoutinesComplete := True;
  Second.Ranges := [
    // Repeats a range of the first provider: no record of it is left out.
    Routine(100, 200, 'A-again', 'UnitB', True),
    // Wholly in the gap, a record of its unit on its first byte: taken as it is.
    Routine(210, 250, 'Anon1', 'UnitB', False),
    // Starts in the gap, reaches into B: taken, cut where B starts.
    Routine(255, 350, 'Anon2', 'UnitB', True),
    // Holds the two records after B, but STARTS inside B: it would take over
    // B's records behind its start. Refused.
    Routine(380, 480, 'Straddle', 'UnitB', True),
    // A record sits on its first byte, of ANOTHER unit: the shape of a unit's
    // final `end.` landing on the next unit's class data. Refused.
    Routine(600, 650, 'OtherUnitsData', 'UnitB', True),
    // Holds records, none on its first byte: nothing says it is a routine.
    Routine(695, 720, 'NoEntryRecord', 'UnitB', True),
    // Holds no record: never looked at.
    Routine(900, 950, 'Empty', 'UnitB', True)];

  var Plain := TModuleCodeMap.Build('fake', First, First, 0, IMAGE_SIZE);
  var Map := TModuleCodeMap.Build('fake', First, First, 0, IMAGE_SIZE, nil, Second);
  try
    Assert.AreEqual(0, Plain.SecondProviderRoutineCount, 'no second provider, nothing taken from one');
    Assert.AreEqual(11, Plain.OutsideRoutineCount, 'the first provider alone leaves eleven records out');
    Assert.AreEqual(2, Map.SecondProviderRoutineCount, 'two ranges of the second provider are taken');
    Assert.AreEqual(3, Map.SecondProviderRefusedCount, 'three are refused');
    Assert.AreEqual(4, Integer(Length(Map.Routines)));
    Assert.AreEqual(6, Map.OutsideRoutineCount, 'six records stay outside every routine');

    Assert.AreEqual('Anon1', OwnerName(Map, 210));
    Assert.AreEqual('Anon1', OwnerName(Map, 220));
    Assert.AreEqual('Anon1', OwnerName(Map, 240));
    Assert.AreEqual('Anon2', OwnerName(Map, 255));
    Assert.AreEqual('Anon2', OwnerName(Map, 260));
    Assert.AreEqual('', OwnerName(Map, 450), 'a record held by a range that starts inside a routine stays outside');
    Assert.AreEqual('', OwnerName(Map, 470));
    Assert.AreEqual('', OwnerName(Map, 600), 'a record of another unit on the start of a range does not make it a routine');
    Assert.AreEqual('', OwnerName(Map, 700), 'a range with no record on its start is not a routine');
    Assert.AreEqual('', OwnerName(Map, 710));
    Assert.AreEqual('', OwnerName(Map, 1000));

    for var I := 0 to High(Map.Routines) do begin
      var Taken := Map.Routines[I];
      if not Taken.FromSecondProvider then
        Continue;
      Assert.IsTrue(Taken.EndIsApproximate, Taken.Name + ': an end taken from a second provider is approximate');
      Assert.IsTrue(Taken.LineCount > 0, Taken.Name + ': taken without a record in it');
      Assert.AreEqual('UnitB', Map.UnitName(Taken.UnitIndex), Taken.Name + ': the second provider''s unit');
    end;
    var Anon2 := Map.Routines[Map.Lines[Map.FindLine(260)].RoutineIndex];
    Assert.AreEqual<Cardinal>(255, Anon2.StartRva);
    Assert.AreEqual<Cardinal>(300, Anon2.EndRva, 'cut at the next routine of the first provider');

    // Nothing changed for a record the first provider covers.
    Assert.AreEqual(Integer(Length(Plain.Lines)), Integer(Length(Map.Lines)));
    for var I := 0 to High(Plain.Lines) do begin
      var Before := Plain.Lines[I];
      var After := Map.Lines[I];
      Assert.AreEqual(Before.Rva, After.Rva);
      if Before.RoutineIndex < 0 then
        Continue;
      var Was := Plain.Routines[Before.RoutineIndex];
      var Still := Map.Routines[After.RoutineIndex];
      Assert.AreEqual(Was.Name, Still.Name, Format('record $%x changed routine', [Before.Rva]));
      Assert.AreEqual(Was.StartRva, Still.StartRva);
      Assert.AreEqual(Was.EndRva, Still.EndRva);
      Assert.AreEqual(Was.EndIsApproximate, Still.EndIsApproximate);
      Assert.IsFalse(Still.FromSecondProvider);
      Assert.AreEqual(Was.LineCount, Still.LineCount);
      Assert.AreEqual(Before.CodeLength, After.CodeLength, Format('record $%x changed length', [Before.Rva]));
    end;
  finally
    Map.Free;
    Plain.Free;
  end;
end;

procedure TCodeMapTests.SecondRoutineProvider_OnTheFixtures_NamesAnonymousMethodBodies;
// On real binaries, both bitnesses: with the MAP as the second routine
// provider the body of an anonymous method -- outside every TD32 range -- gets
// a routine, and every record TD32 covers keeps exactly what it had.
type
  TSample = record
    Name, Source, Marker: string;
  end;
const
  SAMPLES: array[0..1] of TSample = (
    (Name: 'BreakpointSample'; Source: 'BreakpointSample.dpr'; Marker: '{BP:BS_ANON_BODY}'),
    (Name: 'AnalysisSample';   Source: 'AnalysisSample.dpr';   Marker: '{BP:AN_ANON_BODY}'));

  function MarkerLineOf(const Sample: TSample): Integer;
  begin
    Result := 0;
    var Source := TStringList.Create;
    try
      Source.LoadFromFile(FixtureRoot + 'TestTarget\' + Sample.Source);
      for var I := 0 to Source.Count - 1 do
        if Source[I].Contains(Sample.Marker) then
          Exit(I + 1);
    finally
      Source.Free;
    end;
  end;

begin
  // The MAP is read from a private copy: a MAP loaded as a file writes an
  // index sidecar beside itself, and the fixture directory is shared with the
  // other worker processes.
  PurgeLeftoverTempDirs('cmap2nd_');
  var Scratch := MakeTestScratchDir('cmap2nd_');
  try
    for var Sample in SAMPLES do
      for var Bitness in ['Win32', 'Win64'] do begin
        var Binary := LoadOne(Sample.Name + ' ' + Bitness,
          'TestTarget\' + Bitness + '\Debug\' + Sample.Name + '.exe');
        var MapCopy := TPath.Combine(Scratch, Sample.Name + '_' + Bitness + '.map');
        TFile.Copy(Binary.MapPath, MapCopy, True);
        var MapFile := TMapFile.Create;
        var KeepMap: IInterface := MapFile;
        MapFile.LoadFromFile(MapCopy, ReadPEPreferredBase(Binary.Path));
        MapFile.ImageSize := Binary.ImageSize;

        var Second := TModuleCodeMap.PickSecondRoutineProvider([Binary.Keep, KeepMap], Binary.Reader);
        Check(Second <> nil, Binary.Caption + ': the MAP was not picked as the second routine provider');
        var Plain := BuildMap(Binary);
        var Map := TModuleCodeMap.Build(ExtractFileName(Binary.Path), Binary.Reader, Binary.Reader, 0,
          Binary.ImageSize, nil, Second);
        try
          Check(Map.SecondProviderRoutineCount > 0, Binary.Caption + ': nothing was taken from the MAP');
          Check(Length(Map.Routines) = Length(Plain.Routines) + Map.SecondProviderRoutineCount,
            Binary.Caption + ': the routine count does not add up');

          // The body of the anonymous method.
          var Line := MarkerLineOf(Sample);
          var Files := Map.FindFiles(Sample.Source);
          Check((Line > 0) and (Length(Files) = 1), Binary.Caption + ': marker or file not found');
          if (Line > 0) and (Length(Files) = 1) then begin
            var Records := Map.LinesAt(Files[0], Line);
            Check(Length(Records) > 0, Binary.Caption + ': the body has no line record');
            for var Index in Records do begin
              Check(Plain.Lines[Index].RoutineIndex < 0,
                Binary.Caption + ': TD32 has a procedure record for the body after all');
              var Owner := Map.Lines[Index].RoutineIndex;
              Check(Owner >= 0, Binary.Caption + ': the body is still outside every routine');
              if Owner < 0 then
                Continue;
              var Routine := Map.Routines[Owner];
              Check(Routine.FromSecondProvider and Routine.EndIsApproximate,
                Binary.Caption + ': the body''s routine is not flagged as the MAP''s, approximate');
              Check(Routine.Name.Contains('$ActRec'),
                Binary.Caption + ': the body''s routine is named ' + Routine.Name);
            end;
          end;

          // Every routine taken lies in a gap of TD32's ranges and holds a record.
          for var I := 0 to High(Map.Routines) do begin
            var Routine := Map.Routines[I];
            if not Routine.FromSecondProvider then
              Continue;
            Check(Routine.LineCount > 0, Format('%s: %s was taken without a record', [Binary.Caption, Routine.Name]));
            Check(Plain.FindRoutine(Routine.StartRva) < 0,
              Format('%s: %s starts inside a TD32 routine', [Binary.Caption, Routine.Name]));
            if Routine.EndRva > Routine.StartRva then
              Check(Plain.FindRoutine(Routine.EndRva - 1) < 0,
                Format('%s: %s reaches into a TD32 routine', [Binary.Caption, Routine.Name]));
          end;

          // Nothing changed for a record TD32 covers.
          Check(Length(Map.Lines) = Length(Plain.Lines), Binary.Caption + ': the line records differ in number');
          if Length(Map.Lines) = Length(Plain.Lines) then
            for var I := 0 to High(Plain.Lines) do begin
              var Before := Plain.Lines[I];
              var After := Map.Lines[I];
              Check((Before.Rva = After.Rva) and (Before.Line = After.Line) and
                    (Before.FileIndex = After.FileIndex), Format('%s: record %d differs', [Binary.Caption, I]));
              if Before.RoutineIndex < 0 then
                Continue;
              var Was := Plain.Routines[Before.RoutineIndex];
              var Still := Map.Routines[After.RoutineIndex];
              Check((Was.StartRva = Still.StartRva) and (Was.EndRva = Still.EndRva) and (Was.Name = Still.Name) and
                    (Was.EndIsApproximate = Still.EndIsApproximate) and (not Still.FromSecondProvider) and
                    (Was.LineCount = Still.LineCount) and (Before.CodeLength = After.CodeLength),
                Format('%s: record $%x of %s changed', [Binary.Caption, Before.Rva, Was.Name]));
            end;
        finally
          Map.Free;
          Plain.Free;
          KeepMap := nil;
        end;
      end;
    // What must NOT be taken. A MAP lists the class data of a unit among the
    // publics of the code segment (`Unit..TClass`), and on x86 the record of
    // the previous unit's final `end.` lands a few bytes into it. Taken as a
    // routine, that data would be decoded as instructions.
    for var Bitness in ['Win32', 'Win64'] do begin
      var Binary := LoadOne('TestTarget ' + Bitness, 'TestTarget\' + Bitness + '\Debug\TestTarget.exe');
      var MapCopy := TPath.Combine(Scratch, 'TestTarget_' + Bitness + '.map');
      TFile.Copy(Binary.MapPath, MapCopy, True);
      var MapFile := TMapFile.Create;
      var KeepMap: IInterface := MapFile;
      MapFile.LoadFromFile(MapCopy, ReadPEPreferredBase(Binary.Path));
      MapFile.ImageSize := Binary.ImageSize;
      var Plain := BuildMap(Binary);
      var Map := TModuleCodeMap.Build(ExtractFileName(Binary.Path), Binary.Reader, Binary.Reader, 0,
        Binary.ImageSize, nil, TModuleCodeMap.PickSecondRoutineProvider([Binary.Keep, KeepMap], Binary.Reader));
      try
        Check(Map.SecondProviderRoutineCount > 0, Binary.Caption + ': nothing was taken from the MAP');
        for var I := 0 to High(Map.Routines) do
          if Map.Routines[I].FromSecondProvider then
            Check(not Map.Routines[I].Name.Contains('..'),
              Format('%s: class data %s was taken for a routine', [Binary.Caption, Map.Routines[I].Name]));
        // The last record of each of these units is its final `end.`.
        for var UnitFile in ['TestTargetUsesA.pas', 'TestTargetUsesB.pas', 'TestTargetUsesHost.pas'] do begin
          var Files := Map.FindFiles(UnitFile);
          if Length(Files) <> 1 then
            Continue;
          var Records := Map.LinesOfFile(Files[0]);
          if Length(Records) = 0 then
            Continue;
          var Last := Records[High(Records)];
          if Plain.Lines[Last].RoutineIndex >= 0 then
            Continue;   // this build has it inside a routine: not the shape tested
          var Given := '';
          if Map.Lines[Last].RoutineIndex >= 0 then
            Given := Map.Routines[Map.Lines[Last].RoutineIndex].Name;
          Check(Given = '', Format('%s: the "end." record of %s ($%x) was given the routine %s by the MAP',
            [Binary.Caption, UnitFile, Map.Lines[Last].Rva, Given]));
        end;
      finally
        Map.Free;
        Plain.Free;
        KeepMap := nil;
      end;
    end;
  finally
    DeleteTempDirWithRetry(Scratch);
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.PickSecondRoutineProvider_IsTheNextOneThatHasRanges;
begin
  var LinesOnly: IInterface := TFakeLinesOnly.Create;
  var Both: IInterface := TFakeTables.Create;
  var RoutinesOnly: IInterface := TFakeRoutinesOnly.Create;
  var Lines: ILineRecordProvider;
  var First: IRoutineRangeProvider;
  Assert.IsTrue(TModuleCodeMap.PickProviders([nil, Both, LinesOnly, RoutinesOnly], Lines, First));

  var Second := TModuleCodeMap.PickSecondRoutineProvider([nil, Both, LinesOnly, RoutinesOnly], First);
  Assert.IsTrue((Second <> nil) and ((Second as TObject) = (RoutinesOnly as TObject)),
    'the next provider of ranges after the first one');
  Assert.IsTrue(TModuleCodeMap.PickSecondRoutineProvider([Both, LinesOnly], First) = nil,
    'no other provider of ranges: none');
  Assert.IsTrue(TModuleCodeMap.PickSecondRoutineProvider([], First) = nil);
end;

{ The other formats }

procedure TCodeMapTests.Map_Tables_MarkersRoutineEndsAndUnits;
begin
  for var Binary in LoadBinaries do begin
    Check(TFile.Exists(Binary.MapPath), Binary.Caption + ': no MAP at ' + Binary.MapPath);
    if not TFile.Exists(Binary.MapPath) then
      Continue;
    var MapFile := TMapFile.Create;
    var Keep: IInterface := MapFile;
    MapFile.LoadFromFile(Binary.MapPath, ReadPEPreferredBase(Binary.Path));
    MapFile.ImageSize := Binary.ImageSize;

    var Lines: ILineRecordProvider;
    var Routines: IRoutineRangeProvider;
    Check(TModuleCodeMap.PickProviders([Keep], Lines, Routines), Binary.Caption + ': the MAP reader must supply both tables');
    var Map := TModuleCodeMap.Build(ExtractFileName(Binary.Path), Lines, Routines, 0, Binary.ImageSize);
    var Td32Map := BuildMap(Binary);
    try
      Check(Map.Complete, Binary.Caption + ': the MAP was not enumerated in full');
      Check(Map.DroppedLineCount = 0, Format('%s: %d MAP line records dropped', [Binary.Caption, Map.DroppedLineCount]));
      CheckMarkersAgainst(Binary.Caption + ' (map)', Map, MapFile, MapFile, MapFile);

      // The two formats describe one binary: a marker line must have at least
      // one address in common, or one of the two RVA spaces is wrong.
      var MapFiles := Map.FindFiles(MARKER_SOURCE);
      var Td32Files := Td32Map.FindFiles(MARKER_SOURCE);
      if (Length(MapFiles) = 1) and (Length(Td32Files) = 1) then
        for var Marker in Markers do begin
          var FromTd32 := Td32Map.LinesAt(Td32Files[0], Marker.Line);
          if Length(FromTd32) = 0 then
            Continue;
          var Shared := False;
          for var MapIndex in Map.LinesAt(MapFiles[0], Marker.Line) do
            for var Td32Index in FromTd32 do
              if Map.Lines[MapIndex].Rva = Td32Map.Lines[Td32Index].Rva then
                Shared := True;
          Check(Shared, Format('%s: marker %s (line %d): MAP and TD32 share no address',
            [Binary.Caption, Marker.Name, Marker.Line]));
        end;
    finally
      Td32Map.Free;
      Map.Free;
    end;

    var Complete: Boolean;
    var Ranges := MapFile.RoutineRanges(Complete);
    Check(Complete and (Length(Ranges) > 100),
      Format('%s: %d routines from the MAP, complete %s', [Binary.Caption, Length(Ranges), BoolToStr(Complete, True)]));
    for var I := 0 to High(Ranges) do begin
      Check(Ranges[I].EndIsApproximate, Format('%s: %s claims an exact end', [Binary.Caption, Ranges[I].Name]));
      Check(Ranges[I].EndRva > Ranges[I].StartRva, Format('%s: %s is empty', [Binary.Caption, Ranges[I].Name]));
      Check((I = 0) or (Ranges[I].StartRva >= Ranges[I - 1].EndRva),
        Format('%s: %s starts inside the routine before it', [Binary.Caption, Ranges[I].Name]));
    end;

    var Table := MapFile.LineRecordTable(Complete);
    Check(Complete and (Length(Table.Records) > 1000),
      Format('%s: %d line records from the MAP', [Binary.Caption, Length(Table.Records)]));
    var WithoutUnit := 0;
    for var I := 0 to High(Table.Records) do begin
      if Table.Records[I].UnitIndex < 0 then
        Inc(WithoutUnit);
      Check((I = 0) or (Table.Records[I].Rva > Table.Records[I - 1].Rva),
        Format('%s: MAP record %d does not follow the one before it', [Binary.Caption, I]));
    end;
    Check(WithoutUnit = 0, Format('%s: %d MAP line records without a unit', [Binary.Caption, WithoutUnit]));
  end;
  AssertNoProblems;
end;

procedure TCodeMapTests.Jdbg_Markers_AreLineRecordsInTheRoutineJclNames;
begin
  var Binary := LoadOne('exe x64', 'TestTarget\Win64\Debug\TestTarget.exe');
  var Provider: IInterface;
  if not CreateJclDebugProvider(Binary.Path, 0, Binary.ImageSize, Provider) then
    Assert.Pass('SKIP[no-jcl]: TestTarget.jdbg absent (JCL disabled or not generated)');

  var Lines: ILineRecordProvider;
  var Routines: IRoutineRangeProvider;
  Assert.IsTrue(TModuleCodeMap.PickProviders([Provider], Lines, Routines),
    'the JCL reader must supply both tables');
  var Map := TModuleCodeMap.Build('TestTarget.exe', Lines, Routines, 0, Binary.ImageSize);
  try
    Check(Map.Complete, 'jdbg: not enumerated in full');
    Check(Length(Map.Lines) > 1000, Format('jdbg: only %d line records', [Length(Map.Lines)]));
    Check(Map.DroppedLineCount + Map.DroppedRoutineCount = 0,
      Format('jdbg: %d line records and %d routines dropped', [Map.DroppedLineCount, Map.DroppedRoutineCount]));
    for var Routine in Map.Routines do
      Check(Routine.EndIsApproximate and (Routine.UnitIndex >= 0),
        Format('jdbg: %s must have an approximate end and a unit', [Routine.Name]));
    // JCL cannot bind a line to an address, so TD32 says where each marker is
    // and JCL's own lookups say what is there.
    CheckMarkersAgainst('exe x64 (jdbg)', Map, Provider as ISourceLineProvider,
      Provider as IFunctionNameProvider, Binary.Reader);
    // Every record agrees with JCL's own point lookups -- except in the LAST
    // source file of the image, where the lookup has nothing to say:
    // TJclBinDebugScanner.SourceNameFromAddr reports a source name only when
    // it meets a LATER entry of the source table, so the addresses of the last
    // entry (here the program's main block) get no file from it. The table
    // read whole has them. The exception is pinned to exactly that shape: the
    // records the lookup does not know are the tail of the address order and
    // share one file.
    var LineOracle := Provider as ISourceLineProvider;
    var NameOracle := Provider as IFunctionNameProvider;
    var Unknown := 0;
    var UnknownFile := -1;
    for var Line in Map.Lines do begin
      var Loc: TSourceLocation;
      if not LineOracle.RvaToSourceLine(Line.Rva, Loc) then begin
        Inc(Unknown);
        if UnknownFile < 0 then
          UnknownFile := Line.FileIndex;
        Check(Line.FileIndex = UnknownFile,
          Format('jdbg: the lookup knows neither $%x (%s) nor a record of %s',
            [Line.Rva, Map.Files[Line.FileIndex].Name, Map.Files[UnknownFile].Name]));
      end else begin
        Check(Unknown = 0,
          Format('jdbg: the lookup knows $%x but not %d records below it', [Line.Rva, Unknown]));
        Check((Loc.Line = Line.Line) and SameText(Loc.SourceFile, Map.Files[Line.FileIndex].Name),
          Format('jdbg: $%x is %s:%d in the map, %s:%d by lookup',
            [Line.Rva, Map.Files[Line.FileIndex].Name, Line.Line, Loc.SourceFile, Loc.Line]));
      end;
      var Start: UInt64;
      var Named := NameOracle.RvaToFunctionStart(Line.Rva, Start);
      Check(Named = Line.InRoutine, Format('jdbg: $%x in a routine: map %s, lookup %s',
        [Line.Rva, BoolToStr(Line.InRoutine, True), BoolToStr(Named, True)]));
      if Named and Line.InRoutine then
        Check(Map.Routines[Line.RoutineIndex].StartRva = Start,
          Format('jdbg: $%x: routine at $%x in the map, $%x by lookup',
            [Line.Rva, Map.Routines[Line.RoutineIndex].StartRva, Start]));
    end;
    Check(Unknown * 10 < Length(Map.Lines),
      Format('jdbg: the lookup does not know %d of %d records', [Unknown, Length(Map.Lines)]));
  finally
    Map.Free;
  end;
  AssertNoProblems;
end;

initialization
  TDUnitX.RegisterTestFixture(TCodeMapTests);

end.
