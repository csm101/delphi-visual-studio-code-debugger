program MapLineRvaProbe;

// Checks TMapFile's line <-> RVA mapping against the PE section table of the
// matching image, on a REAL MAP of any size.
//
// Every "Line numbers for Unit(file)" section lists `line SSSS:offset` records.
// The address of a record is the VirtualAddress of the PE section named like
// segment SSSS, plus the offset -- derived here WITHOUT TMapFile, from the
// MAP's segment table (names only) and the PE section headers.
//
// Most addresses carry exactly one record, and TMapFile must return it. Some
// carry several, from different sections: at a unit boundary, one unit's
// section ends with a record at its end address, which is the next unit's
// first record. There the expected answer is a record of the unit that OWNS
// the address according to the MAP's "Detailed map of segments" -- again
// derived independently of TMapFile, which never reads the detailed map.
//
// Checked addresses: the first record of sections spread over the whole MAP
// (always including the farthest section of each segment), plus EVERY address
// that carries more than one record. For each, TMapFile is asked
//
//   RvaToSourceLine(address)       -> must be an acceptable record;
//   SourceLineToRva(file, line)    -> (unshared records only) an RVA that maps
//                                     back to that line.
//
// Written for GitHub issue #12: once .text passes 4 MB the detailed map's
// segment-relative offsets exceed the preferred base, and TMapFile's segment
// table parse took one of them for segment 1's base. No test fixture is that
// large; run this against a large real MAP after any MapFileReader change.
//
// It also counts sections whose records are not in ascending address order:
// TMapFile bounds a section by its first and last record, which is exact only
// if there are none.
//
// Side effect: like the adapter, TMapFile writes `<map>.idx` next to the MAP.
// Running twice exercises both the full scan and the sidecar fast path.
//
// Usage:
//   MapLineRvaProbe <image.exe|dll|bpl> <file.map> [spreadSamples]
//
// Exit code: 0 = every address agreed, 1 = at least one disagreed, 2 = bad input.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.StrUtils, System.IOUtils, System.Diagnostics,
  System.Generics.Collections, System.Generics.Defaults,
  Winapi.Windows,
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  MapFileReader  in '..\DebuggerCore\MapFileReader.pas';

type
  TPeSection = record
    Name:           string;
    VirtualAddress: UInt64;
  end;

  // One `line SSSS:offset` record of a "Line numbers for Unit(file)" section.
  TMapRecord = record
    UnitName:   string;
    SourcePath: string;
    Line:       Integer;
    Segment:    Integer;
    Offset:     UInt64;
    function Address: UInt64;
    function Describe: string;
  end;

  // A unit's piece of one segment, from the "Detailed map of segments".
  TUnitRange = record
    Start:    UInt64;
    Size:     UInt64;
    UnitName: string;
  end;

  TRecordVisitor = reference to procedure(const MapRecord: TMapRecord);

  // What the first pass over the MAP learns.
  TMapLayout = class
  private
    FSegmentNames:      TDictionary<Integer, string>;
    FUnitRanges:        TObjectDictionary<Integer, TList<TUnitRange>>;
    FFirstRecords:      TList<TMapRecord>;
    FRecordsPerAddress: TDictionary<UInt64, Integer>;
    FUnorderedSections: Integer;
    procedure ReadSegmentRow(const Line: string);
    procedure ReadDetailedMapRow(const Line: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Read(const MapPath: string);
    function  OwnerUnit(Segment: Integer; Offset: UInt64): string;
    function  SharedAddresses: TArray<UInt64>;
    property  SegmentNames: TDictionary<Integer, string> read FSegmentNames;
    property  FirstRecords: TList<TMapRecord> read FFirstRecords;
    property  UnorderedSections: Integer read FUnorderedSections;
  end;

const
  DEFAULT_SPREAD_SAMPLES = 300;
  MAX_FAILURES_SHOWN     = 15;
  INDEX_DEADLINE_MS      = 15 * 60 * 1000;

function PackAddress(Segment: Integer; Offset: UInt64): UInt64;
begin
  Result := (UInt64(Segment) shl 48) or Offset;
end;

function TMapRecord.Address: UInt64;
begin
  Result := PackAddress(Segment, Offset);
end;

function TMapRecord.Describe: string;
begin
  Result := Format('%s(%s):%d', [UnitName, ExtractFileName(SourcePath), Line]);
end;

{ PE image }

function SectionName(const Header: TImageSectionHeader): string;
begin
  var Len := 0;
  while (Len < IMAGE_SIZEOF_SHORT_NAME) and (Ord(Header.Name[Len]) <> 0) do
    Inc(Len);
  var Raw: AnsiString;
  SetString(Raw, PAnsiChar(@Header.Name[0]), Len);
  Result := string(Raw);
end;

function ReadPeSections(const ImagePath: string): TArray<TPeSection>;
begin
  Result := [];
  var Stream := TFileStream.Create(ImagePath, fmOpenRead or fmShareDenyNone);
  try
    var DosHeader: TImageDosHeader;
    Stream.ReadBuffer(DosHeader, SizeOf(DosHeader));
    Stream.Position := DosHeader._lfanew;
    var Signature: DWORD;
    Stream.ReadBuffer(Signature, SizeOf(Signature));
    if Signature <> IMAGE_NT_SIGNATURE then
      raise Exception.Create('not a PE image: ' + ImagePath);
    var FileHeader: TImageFileHeader;
    Stream.ReadBuffer(FileHeader, SizeOf(FileHeader));
    Stream.Seek(Int64(FileHeader.SizeOfOptionalHeader), soCurrent);
    for var Index := 1 to FileHeader.NumberOfSections do begin
      var Header: TImageSectionHeader;
      Stream.ReadBuffer(Header, SizeOf(Header));
      var Section: TPeSection;
      Section.Name           := SectionName(Header);
      Section.VirtualAddress := Header.VirtualAddress;
      Result := Result + [Section];
    end;
  finally
    Stream.Free;
  end;
end;

function TrySectionAddress(const Sections: TArray<TPeSection>; const Name: string;
  out VirtualAddress: UInt64): Boolean;
begin
  for var Section in Sections do
    if SameText(Section.Name, Name) then begin
      VirtualAddress := Section.VirtualAddress;
      Exit(True);
    end;
  Result := False;
end;

{ MAP text }

function TryParseSegOffset(const Token: string; out Segment: Integer; out Offset: UInt64): Boolean;
begin
  var ColonPos := Token.IndexOf(':');
  if ColonPos < 1 then
    Exit(False);
  Segment := StrToIntDef('$' + Token.Substring(0, ColonPos), -1);
  if Segment <= 0 then
    Exit(False);
  var Value: Int64;
  if not TryStrToInt64('$' + Token.Substring(ColonPos + 1), Value) then
    Exit(False);
  Offset := UInt64(Value);
  Result := True;
end;

function SplitTokens(const Line: string): TArray<string>;
begin
  Result := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
end;

// "Line numbers for Unit(path\File.pas) segment .text" -> Unit, path\File.pas
function TryParseSectionHeader(const Header: string; out UnitName, SourcePath: string): Boolean;
const
  PREFIX = 'Line numbers for ';
begin
  var OpenPos  := Header.IndexOf('(');
  var ClosePos := Header.LastIndexOf(')');
  if (OpenPos < PREFIX.Length) or (ClosePos <= OpenPos) then
    Exit(False);
  UnitName   := Header.Substring(PREFIX.Length, OpenPos - PREFIX.Length);
  SourcePath := Header.Substring(OpenPos + 1, ClosePos - OpenPos - 1);
  Result := True;
end;

// A record at segment offset 0 is a placeholder for a line with no code
// (whole sections of them exist, e.g. for resourcestring units); TMapFile gives
// it no address, so it is skipped.
procedure VisitRecordsOn(const DataLine: string; var Current: TMapRecord; const Visit: TRecordVisitor);
begin
  var Tokens := SplitTokens(DataLine);
  var PairIndex := 0;
  while PairIndex + 1 < Length(Tokens) do begin
    Current.Line := StrToIntDef(Tokens[PairIndex], 0);
    var Parsed := (Current.Line > 0) and TryParseSegOffset(Tokens[PairIndex + 1], Current.Segment, Current.Offset);
    Inc(PairIndex, 2);
    if Parsed and (Current.Offset <> 0) then
      Visit(Current);
  end;
end;

// Calls Visit for every record of every "Line numbers for" section, in MAP
// order, and OnSectionEnd after each section. A section's data lines start with
// a digit; the first line that does not (the next header, "Bound resource
// files") ends it. Blank lines do not, so a record TMapFile would miss after a
// blank line still counts here.
procedure ForEachLineRecord(const MapPath: string; const Visit: TRecordVisitor;
  const OnSectionEnd: TProc = nil);
begin
  var Reader := TStreamReader.Create(MapPath, TEncoding.ANSI, False, 4 * 1024 * 1024);
  try
    var Current := Default(TMapRecord);
    var InSection := False;
    while not Reader.EndOfStream do begin
      var Line := Reader.ReadLine.Trim;
      if Line.IsEmpty then
        Continue;
      if InSection and not CharInSet(Line.Chars[0], ['0'..'9']) then begin
        InSection := False;
        if Assigned(OnSectionEnd) then
          OnSectionEnd();
      end;
      if Line.StartsWith('Line numbers for ') then
        InSection := TryParseSectionHeader(Line, Current.UnitName, Current.SourcePath)
      else if InSection then
        VisitRecordsOn(Line, Current, Visit);
    end;
    if InSection and Assigned(OnSectionEnd) then
      OnSectionEnd();
  finally
    Reader.Free;
  end;
end;

{ TMapLayout }

constructor TMapLayout.Create;
begin
  inherited;
  FSegmentNames      := TDictionary<Integer, string>.Create;
  FUnitRanges        := TObjectDictionary<Integer, TList<TUnitRange>>.Create([doOwnsValues]);
  FFirstRecords      := TList<TMapRecord>.Create;
  FRecordsPerAddress := TDictionary<UInt64, Integer>.Create;
end;

destructor TMapLayout.Destroy;
begin
  FRecordsPerAddress.Free;
  FFirstRecords.Free;
  FUnitRanges.Free;
  FSegmentNames.Free;
  inherited;
end;

procedure TMapLayout.ReadSegmentRow(const Line: string);
begin
  var Tokens := SplitTokens(Line);
  if Length(Tokens) < 4 then
    Exit;
  var Segment: Integer;
  var Start: UInt64;
  if not TryParseSegOffset(Tokens[0], Segment, Start) then
    Exit;
  if Tokens[2].StartsWith('.') then
    FSegmentNames.AddOrSetValue(Segment, Tokens[2]);
end;

// ` 0001:063EF864 000587E8 C=CODE S=.text G=(none) M=SomeUnit ACBP=A9`
procedure TMapLayout.ReadDetailedMapRow(const Line: string);
begin
  var Tokens := SplitTokens(Line);
  if Length(Tokens) < 3 then
    Exit;
  var Segment: Integer;
  var Range: TUnitRange;
  if not TryParseSegOffset(Tokens[0], Segment, Range.Start) then
    Exit;
  Range.Size := StrToInt64Def('$' + Tokens[1], 0);
  Range.UnitName := '';
  for var Token in Tokens do
    if Token.StartsWith('M=') then
      Range.UnitName := Token.Substring(2);
  if Range.UnitName.IsEmpty then
    Exit;
  var Ranges: TList<TUnitRange>;
  if not FUnitRanges.TryGetValue(Segment, Ranges) then begin
    Ranges := TList<TUnitRange>.Create;
    FUnitRanges.Add(Segment, Ranges);
  end;
  Ranges.Add(Range);
end;

procedure TMapLayout.Read(const MapPath: string);
type
  TPart = (mpSegmentTable, mpDetailedMap, mpRest);
begin
  // Header part: segment table, then the detailed map. Stops at the publics.
  var Reader := TStreamReader.Create(MapPath, TEncoding.ANSI, False, 4 * 1024 * 1024);
  try
    var Part := mpSegmentTable;
    while (Part <> mpRest) and not Reader.EndOfStream do begin
      var Line := Reader.ReadLine.Trim;
      if Line.StartsWith('Detailed map of segments') then
        Part := mpDetailedMap
      else if Line.Contains('Publics by') or Line.StartsWith('Line numbers for ') then
        Part := mpRest
      else if Part = mpSegmentTable then
        ReadSegmentRow(Line)
      else
        ReadDetailedMapRow(Line);
    end;
  finally
    Reader.Free;
  end;
  for var Ranges in FUnitRanges.Values do
    Ranges.Sort(TComparer<TUnitRange>.Construct(
      function(const A, B: TUnitRange): Integer
      begin
        Result := CompareValue(A.Start, B.Start);
      end));

  // Line records.
  var SectionHasRecords := False;
  var LastOffset: UInt64 := 0;
  var Unordered := False;
  ForEachLineRecord(MapPath,
    procedure(const MapRecord: TMapRecord)
    begin
      if not SectionHasRecords then
        FFirstRecords.Add(MapRecord)
      else if MapRecord.Offset < LastOffset then
        Unordered := True;
      SectionHasRecords := True;
      LastOffset := MapRecord.Offset;
      var Count := 0;
      FRecordsPerAddress.TryGetValue(MapRecord.Address, Count);
      FRecordsPerAddress.AddOrSetValue(MapRecord.Address, Count + 1);
    end,
    procedure
    begin
      if Unordered then
        Inc(FUnorderedSections);
      SectionHasRecords := False;
      Unordered := False;
    end);
end;

function TMapLayout.OwnerUnit(Segment: Integer; Offset: UInt64): string;
begin
  Result := '';
  var Ranges: TList<TUnitRange>;
  if not FUnitRanges.TryGetValue(Segment, Ranges) then
    Exit;
  var Lo := 0;
  var Hi := Ranges.Count - 1;
  var Best := -1;
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) div 2;
    if Ranges[Mid].Start <= Offset then begin
      Best := Mid;
      Lo   := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if (Best >= 0) and (Offset < Ranges[Best].Start + Ranges[Best].Size) then
    Result := Ranges[Best].UnitName;
end;

function TMapLayout.SharedAddresses: TArray<UInt64>;
begin
  Result := [];
  var Shared := TList<UInt64>.Create;
  try
    for var Pair in FRecordsPerAddress do
      if Pair.Value > 1 then
        Shared.Add(Pair.Key);
    Shared.Sort;
    Result := Shared.ToArray;
  finally
    Shared.Free;
  end;
end;

{ Sampling }

function FarthestPerSegment(Records: TList<TMapRecord>): TArray<Integer>;
begin
  var Farthest := TDictionary<Integer, Integer>.Create;  // segment -> record index
  try
    for var Index := 0 to Records.Count - 1 do begin
      var Current: Integer;
      if Farthest.TryGetValue(Records[Index].Segment, Current) and
         (Records[Current].Offset >= Records[Index].Offset) then
        Continue;
      Farthest.AddOrSetValue(Records[Index].Segment, Index);
    end;
    Result := Farthest.Values.ToArray;
  finally
    Farthest.Free;
  end;
end;

// Addresses to check: section starts spread over the MAP, the farthest section
// of each segment, and every shared address.
function SelectAddresses(Layout: TMapLayout; SpreadSamples: Integer): TArray<UInt64>;
begin
  var Chosen := TDictionary<UInt64, Boolean>.Create;
  try
    var Records := Layout.FirstRecords;
    var Step := Max(1, Records.Count div Max(1, SpreadSamples));
    var Index := 0;
    while Index < Records.Count do begin
      Chosen.AddOrSetValue(Records[Index].Address, True);
      Inc(Index, Step);
    end;
    for var Farthest in FarthestPerSegment(Records) do
      Chosen.AddOrSetValue(Records[Farthest].Address, True);
    for var Shared in Layout.SharedAddresses do
      Chosen.AddOrSetValue(Shared, True);
    Result := Chosen.Keys.ToArray;
    TArray.Sort<UInt64>(Result);
  finally
    Chosen.Free;
  end;
end;

// Second pass: every record at the chosen addresses.
function RecordsAt(const MapPath: string; const Addresses: TArray<UInt64>): TObjectDictionary<UInt64, TList<TMapRecord>>;
begin
  var Found := TObjectDictionary<UInt64, TList<TMapRecord>>.Create([doOwnsValues]);
  try
    for var Address in Addresses do
      Found.Add(Address, TList<TMapRecord>.Create);
    ForEachLineRecord(MapPath,
      procedure(const MapRecord: TMapRecord)
      begin
        var Records: TList<TMapRecord>;
        if Found.TryGetValue(MapRecord.Address, Records) then
          Records.Add(MapRecord);
      end);
  except
    Found.Free;
    raise;
  end;
  Result := Found;
end;

// One record: that one. Several: those of the unit owning the address.
function AcceptableRecords(Layout: TMapLayout; Records: TList<TMapRecord>): TArray<TMapRecord>;
begin
  if Records.Count = 1 then
    Exit(Records.ToArray);
  Result := [];
  var Owner := Layout.OwnerUnit(Records[0].Segment, Records[0].Offset);
  for var MapRecord in Records do
    if SameText(MapRecord.UnitName, Owner) then
      Result := Result + [MapRecord];
end;

{ Checks }

function Fail(out Failure: string; const Reason: string): Boolean;
begin
  Failure := Reason;
  Result  := False;
end;

function SameSourceFile(const Left, Right: string): Boolean;
begin
  Result := SameText(ExtractFileName(Left), ExtractFileName(Right));
end;

function IsAcceptable(const Loc: TSourceLocation; const Acceptable: TArray<TMapRecord>): Boolean;
begin
  for var MapRecord in Acceptable do
    if (Loc.Line = MapRecord.Line) and SameSourceFile(Loc.SourceFile, MapRecord.SourcePath) then
      Exit(True);
  Result := False;
end;

function DescribeAll(Records: TList<TMapRecord>): string;
begin
  Result := '';
  for var MapRecord in Records do
    Result := Result + IfThen(Result.IsEmpty, '', ', ') + MapRecord.Describe;
end;

function AddressAgrees(Map: TMapFile; Records: TList<TMapRecord>; const Acceptable: TArray<TMapRecord>;
  Rva: UInt64; out Failure: string): Boolean;
begin
  var Where := Format('RVA $%x [%s]', [Rva, DescribeAll(Records)]);
  var Loc: TSourceLocation;
  if not Map.RvaToSourceLine(Rva, Loc) then
    Exit(Fail(Failure, Where + ': RvaToSourceLine found nothing'));
  if not IsAcceptable(Loc, Acceptable) then
    Exit(Fail(Failure, Format('%s: RvaToSourceLine gave %s:%d', [Where, ExtractFileName(Loc.SourceFile), Loc.Line])));
  if Records.Count > 1 then
    Exit(True);
  // Line -> address, for an address with a single record.
  var Only := Records[0];
  var BoundRva: UInt64;
  if not Map.SourceLineToRva(Only.SourcePath, Only.Line, BoundRva) then
    Exit(Fail(Failure, Where + ': SourceLineToRva found nothing'));
  var BoundLoc: TSourceLocation;
  if not Map.RvaToSourceLine(BoundRva, BoundLoc) or (BoundLoc.Line <> Only.Line) then
    Exit(Fail(Failure, Format('%s: SourceLineToRva gave $%x, which is not that line', [Where, BoundRva])));
  Result := True;
end;

procedure WaitUntilIndexed(Map: TMapFile);
begin
  var Deadline := GetTickCount64 + INDEX_DEADLINE_MS;
  while Map.BackgroundIndexingPending do begin
    if GetTickCount64 > Deadline then
      raise Exception.Create('MAP not indexed within the deadline');
    Sleep(20);
  end;
end;

type
  TTally = record
    Agreed, Disagreed, NoSection, NoOwnerRecord: Integer;
    SlowestMs: Int64;
  end;

procedure CheckAddress(Map: TMapFile; Layout: TMapLayout; const Sections: TArray<TPeSection>;
  Records: TList<TMapRecord>; var Tally: TTally);
begin
  if Records.Count = 0 then
    Exit;
  var SegmentName := '';
  Layout.SegmentNames.TryGetValue(Records[0].Segment, SegmentName);
  var SectionAddress: UInt64;
  if not TrySectionAddress(Sections, SegmentName, SectionAddress) then begin
    Inc(Tally.NoSection);
    Exit;
  end;
  var Acceptable := AcceptableRecords(Layout, Records);
  if Length(Acceptable) = 0 then begin
    Inc(Tally.NoOwnerRecord);
    var Owner := Layout.OwnerUnit(Records[0].Segment, Records[0].Offset);
    Writeln(Format('  AMBIGUOUS seg %d + $%x [%s]: owner per detailed map = %s',
      [Records[0].Segment, Records[0].Offset, DescribeAll(Records), IfThen(Owner.IsEmpty, '(none)', Owner)]));
    Exit;
  end;
  var Failure: string;
  var Watch := TStopwatch.StartNew;
  var Agrees := AddressAgrees(Map, Records, Acceptable, SectionAddress + Records[0].Offset, Failure);
  Tally.SlowestMs := Max(Tally.SlowestMs, Watch.ElapsedMilliseconds);
  if Agrees then begin
    Inc(Tally.Agreed);
    Exit;
  end;
  Inc(Tally.Disagreed);
  if Tally.Disagreed <= MAX_FAILURES_SHOWN then
    Writeln('  FAIL ', Failure);
end;

function CheckAddresses(const MapPath: string; PreferredBase: UInt64; const Sections: TArray<TPeSection>;
  Layout: TMapLayout; Found: TObjectDictionary<UInt64, TList<TMapRecord>>): Integer;
begin
  var SidecarPath := MapPath + '.idx';
  var SidecarFresh := TFile.Exists(SidecarPath) and
    (TFile.GetLastWriteTime(SidecarPath) >= TFile.GetLastWriteTime(MapPath));
  Writeln('Sidecar before load: ', IfThen(SidecarFresh, 'fresh (fast path if the magic matches)',
    'absent or stale (full scan)'));

  var Map := TMapFile.Create;
  try
    var IndexWatch := TStopwatch.StartNew;
    Map.LoadFromFile(MapPath, PreferredBase);
    WaitUntilIndexed(Map);
    Writeln(Format('Indexed in %.1f s', [IndexWatch.Elapsed.TotalSeconds]));

    var Tally := Default(TTally);
    var ChecksWatch := TStopwatch.StartNew;
    var Addresses := Found.Keys.ToArray;
    TArray.Sort<UInt64>(Addresses);
    for var Address in Addresses do
      CheckAddress(Map, Layout, Sections, Found[Address], Tally);
    Writeln(Format('Addresses: %d agreed, %d disagreed; skipped %d (no PE section), %d (shared, no record of ' +
      'the owning unit); %.1f s total, slowest %d ms', [Tally.Agreed, Tally.Disagreed, Tally.NoSection,
      Tally.NoOwnerRecord, ChecksWatch.Elapsed.TotalSeconds, Tally.SlowestMs]));
    Result := IfThen(Tally.Disagreed = 0, 0, 1);
  finally
    Map.Free;
  end;
end;

procedure PrintSegments(Layout: TMapLayout; const Sections: TArray<TPeSection>; PreferredBase: UInt64);
begin
  var Keys := Layout.SegmentNames.Keys.ToArray;
  TArray.Sort<Integer>(Keys);
  for var Segment in Keys do begin
    var MaxOffset: UInt64 := 0;
    for var MapRecord in Layout.FirstRecords do
      if (MapRecord.Segment = Segment) and (MapRecord.Offset > MaxOffset) then
        MaxOffset := MapRecord.Offset;
    var VirtualAddress: UInt64;
    var PeText := 'no PE section';
    if TrySectionAddress(Sections, Layout.SegmentNames[Segment], VirtualAddress) then
      PeText := Format('PE VA $%x', [VirtualAddress]);
    Writeln(Format('  seg %.4d %-8s %-16s farthest section start $%x%s', [Segment, Layout.SegmentNames[Segment],
      PeText, MaxOffset, IfThen(MaxOffset >= PreferredBase, '  (>= preferred base)', '')]));
  end;
end;

function Run(const ImagePath, MapPath: string; SpreadSamples: Integer): Integer;
begin
  var PreferredBase := ReadPEPreferredBase(ImagePath);
  var Sections := ReadPeSections(ImagePath);
  Writeln('Image: ', ImagePath, Format('  preferred base $%x, %d sections', [PreferredBase, Length(Sections)]));
  Writeln('MAP:   ', MapPath);
  var Layout := TMapLayout.Create;
  try
    Layout.Read(MapPath);
    PrintSegments(Layout, Sections, PreferredBase);
    var Shared := Layout.SharedAddresses;
    Writeln(Format('Line sections: %d (%d not in ascending address order); addresses with several records: %d',
      [Layout.FirstRecords.Count, Layout.UnorderedSections, Length(Shared)]));
    var Addresses := SelectAddresses(Layout, SpreadSamples);
    Writeln(Format('Addresses to check: %d', [Length(Addresses)]));
    var Found := RecordsAt(MapPath, Addresses);
    try
      Result := CheckAddresses(MapPath, PreferredBase, Sections, Layout, Found);
    finally
      Found.Free;
    end;
  finally
    Layout.Free;
  end;
  Writeln(IfThen(Result = 0, 'RESULT: PASS', 'RESULT: FAIL'));
end;

begin
  try
    if ParamCount < 2 then begin
      Writeln('Usage: MapLineRvaProbe <image.exe|dll|bpl> <file.map> [spreadSamples]');
      ExitCode := 2;
      Exit;
    end;
    ExitCode := Run(ParamStr(1), ParamStr(2), StrToIntDef(ParamStr(3), DEFAULT_SPREAD_SAMPLES));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
