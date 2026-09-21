unit MapReaderTests;

// Unit tests for TMapFile. Name resolution runs against the freshly-built
// TestTarget.map; the layout cases run against synthetic MAP files, because the
// shapes they need (a .text past 4 MB) cannot be built cheaply. Neither needs a
// live debug session.

interface

uses
  DUnitX.TestFramework,
  MapFileReader;

type
  [TestFixture]
  TMapReaderTests = class
  private
    FTempDir: string;
    FMapPath: string;
    procedure WriteSyntheticMap(const MapText: string);
    function  LoadSyntheticMap: TMapFile;
    procedure CheckTextLineBindsPastTheDetailedMap(Is64Bit: Boolean);
  public
    [TearDown]
    procedure TearDown;
    // Regression for the SampleApp getter-address miss: the MAP qualifies a
    // method with its unit but without the dotted namespace
    // (`Forms.TApplication.GetMainFormHandle`), so a `ClassName.Method` getter
    // lookup (`TApplication.GetMainFormHandle`) matched neither the exact full
    // name nor (safely) the bare last segment. NameToRva must resolve it via
    // the `Class.Method` (last-two-segments) index, ignoring the unit prefix.
    [Test]
    procedure NameToRva_ClassMethod_ResolvesIgnoringUnitPrefix;
    // GitHub issue #12. The detailed map of segments follows the segment table
    // and lists segment-RELATIVE offsets; once .text passes 4 MB they exceed
    // the preferred base, and the segment-table scan took the last one as
    // segment 1's base. Every .text breakpoint then bound to a bogus address
    // while still being reported verified. Both widths of the Start column.
    [Test]
    procedure SegmentTable_PE32_IgnoresDetailedMapOffsetsAboveThePreferredBase;
    [Test]
    procedure SegmentTable_PE32Plus_IgnoresDetailedMapOffsetsAboveThePreferredBase;
    // Delphi writes a second "Line numbers for" section for the same file for
    // its .itext code (initialization/finalization, a program's main block).
    // Only the first section was indexed, so a line there had no address and an
    // address there had no line.
    [Test]
    procedure LineNumbers_ItextSectionOfTheSameFile_IsIndexed;
    // The same, with the index read back from the .idx sidecar a previous load
    // wrote: the sidecar must keep every section, not one per file.
    [Test]
    procedure LineNumbers_ItextSectionOfTheSameFile_SurvivesTheSidecar;
    // A generic instantiated inside a unit gets its own section, and its code
    // sits between the unit's own lines. An address in the unit's code right
    // after the generic's was attributed to the generic: the lookup loaded only
    // the section starting closest before the address, then took the nearest
    // loaded record. Found on a real 139 MB MAP by DevTools\MapLineRvaProbe.
    [Test]
    procedure RvaToSourceLine_AfterAnInterleavedSection_ResolvesToItsOwnFile;
    // Two sections with a record at the same address, at a unit boundary: the
    // later section (the unit whose code starts there) must win whatever order
    // the files were loaded in. It used to be whichever was loaded first.
    [Test]
    procedure RvaToSourceLine_SharedAddressAtAUnitBoundary_GoesToTheLaterSection;
  end;

implementation

uses
  System.SysUtils, System.IOUtils,
  Winapi.Windows,
  DebugInfoTypes;

const
  SYNTHETIC_PREFERRED_BASE = $400000;
  BIG_UNIT_SOURCE          = 'C:\src\BigUnit.pas';
  // .text base RVA $1000 + BigUnit's .text offset $063EF864.
  BIG_UNIT_TEXT_LINE       = 10;
  BIG_UNIT_TEXT_RVA        = $63F0864;
  // .itext base RVA $6501000 + offset $10.
  BIG_UNIT_ITEXT_LINE      = 40;
  BIG_UNIT_ITEXT_RVA       = $6501010;

// A MAP of an image whose .text is ~100 MB, reduced to the lines the reader
// looks at. BigUnit starts past the 4 MB preferred base inside .text, and its
// offset appears in the detailed map and in the publics -- both of which the
// segment-table scan used to read as segment rows.
function BigImageMapText(Is64Bit: Boolean): string;
begin
  var SegmentRows: TArray<string>;
  if Is64Bit then
    SegmentRows := [
      ' Start                 Length     Name                   Class',
      ' 0001:0000000000401000 06500000H .text                   CODE',
      ' 0002:0000000006901000 00001000H .itext                  ICODE',
      ' 0003:0000000006902000 00001000H .data                   DATA',
      ' 0004:0000000006903000 00001000H .bss                    BSS',
      ' 0005:0000000000400000 00000024H .tls                    TLS']
  else
    SegmentRows := [
      ' Start         Length     Name                   Class',
      ' 0001:00401000 06500000H .text                   CODE',
      ' 0002:06901000 00001000H .itext                  ICODE',
      ' 0003:06902000 00001000H .data                   DATA',
      ' 0004:06903000 00001000H .bss                    BSS',
      ' 0005:00000000 00000024H .tls                    TLS'];
  var Lines: TArray<string> := [''] + SegmentRows + [
    '',
    '',
    'Detailed map of segments',
    '',
    ' 0001:00000000 063EF864 C=CODE     S=.text    G=(none)   M=System   ACBP=A9',
    ' 0001:063EF864 000587E8 C=CODE     S=.text    G=(none)   M=BigUnit  ACBP=A9',
    ' 0002:00000000 00000100 C=ICODE    S=.itext   G=(none)   M=BigUnit  ACBP=A9',
    '',
    '',
    '  Address             Publics by Name',
    '',
    ' 0001:063EF864       BigUnit.DoWork',
    '',
    '',
    '  Address             Publics by Value',
    '',
    ' 0001:063EF864       BigUnit.DoWork',
    '',
    '',
    'Line numbers for BigUnit(' + BIG_UNIT_SOURCE + ') segment .text',
    '',
    '    10 0001:063EF864    11 0001:063EF870',
    '',
    'Line numbers for BigUnit(' + BIG_UNIT_SOURCE + ') segment .itext',
    '',
    '    40 0002:00000010    41 0002:00000018',
    '',
    'Bound resource files',
    '',
    'Program entry point at 0002:00000010',
    ''];
  Result := string.Join(#13#10, Lines);
end;

// A small PE32 image (.text at RVA $1000) whose MAP carries the given
// "Line numbers for" sections, each a header plus one data line.
function SmallImageMapText(const Sections: array of string): string;
begin
  var Lines: TArray<string> := [
    '',
    ' Start         Length     Name                   Class',
    ' 0001:00401000 00010000H .text                   CODE',
    ' 0002:00411000 00001000H .data                   DATA',
    '',
    '',
    'Detailed map of segments',
    '',
    ' 0001:00000000 00010000 C=CODE     S=.text    G=(none)   M=System   ACBP=A9',
    '',
    '',
    '  Address             Publics by Value',
    '',
    ' 0001:00001000       UnitU.Run',
    ''];
  var Index := 0;
  while Index + 1 <= High(Sections) do begin
    Lines := Lines + ['', Sections[Index], '', Sections[Index + 1]];
    Inc(Index, 2);
  end;
  Lines := Lines + ['', 'Bound resource files', ''];
  Result := string.Join(#13#10, Lines);
end;

// UnitU's own lines at .text offsets $1000 / $1100 / $1300, with a generic from
// Gen.pas instantiated in between at $1200; UnitV instantiates the same generic
// elsewhere. RVA = $1000 (.text base) + offset.
function InterleavedMapText: string;
begin
  Result := SmallImageMapText([
    'Line numbers for UnitU(C:\src\UnitU.pas) segment .text',
    '    10 0001:00001000    11 0001:00001100    30 0001:00001300',
    'Line numbers for UnitU(C:\src\Gen.pas) segment .text',
    '   500 0001:00001200',
    'Line numbers for UnitV(C:\src\Gen.pas) segment .text',
    '   600 0001:00005000']);
end;

// As seen on a real MAP at a unit boundary: UnitA's generic section ends with a
// record at UnitA's end address, $2000, where UnitB's code and its first
// record begin.
function UnitBoundaryMapText: string;
begin
  Result := SmallImageMapText([
    'Line numbers for UnitA(C:\src\Gen.pas) segment .text',
    '   900 0001:00002000',
    'Line numbers for UnitB(C:\src\UnitB.pas) segment .text',
    '    20 0001:00002000    21 0001:00002010']);
end;

// The background indexer publishes the unit sections first and the publics
// last, so "publics done" means everything a line lookup reads is in place.
procedure WaitUntilIndexed(Map: TMapFile);
const
  INDEX_DEADLINE_MS = 10000;
begin
  var Deadline := GetTickCount64 + INDEX_DEADLINE_MS;
  while Map.BackgroundIndexingPending do begin
    if GetTickCount64 > Deadline then
      Assert.Fail('synthetic MAP not indexed within 10 s');
    Sleep(5);
  end;
end;

procedure TMapReaderTests.WriteSyntheticMap(const MapText: string);
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'MapReaderTests-' + TGUID.NewGuid.ToString);
  TDirectory.CreateDirectory(FTempDir);
  FMapPath := TPath.Combine(FTempDir, 'BigImage.map');
  TFile.WriteAllText(FMapPath, MapText, TEncoding.ASCII);
end;

function TMapReaderTests.LoadSyntheticMap: TMapFile;
begin
  Result := TMapFile.Create;
  Result.LoadFromFile(FMapPath, SYNTHETIC_PREFERRED_BASE);
  WaitUntilIndexed(Result);
end;

procedure TMapReaderTests.TearDown;
begin
  if (FTempDir <> '') and TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
  FTempDir := '';
end;

procedure TMapReaderTests.NameToRva_ClassMethod_ResolvesIgnoringUnitPrefix;
var
  Map:     TMapFile;
  Rva:     UInt64;
  MapPath: string;
begin
  MapPath := ExtractFilePath(ParamStr(0)) +
    '..\..\TestTarget\Win64\Debug\TestTarget.map';
  if not FileExists(MapPath) then
    Assert.Fail('TestTarget.map not found at ' + MapPath +
                ' -- run build_target.bat first');
  Map := TMapFile.Create;
  try
    Map.LoadFromFile(MapPath);
    // TWidget.Mult is a public method; the MAP stores it unit-qualified
    // (e.g. TestTarget.TWidget.Mult). The Class.Method lookup must find it.
    Assert.IsTrue(Map.NameToRva('TWidget.Mult', Rva) and (Rva > 0),
      'TWidget.Mult must resolve by Class.Method, ignoring the unit prefix');
  finally
    Map.Free;
  end;
end;

procedure TMapReaderTests.SegmentTable_PE32_IgnoresDetailedMapOffsetsAboveThePreferredBase;
begin
  CheckTextLineBindsPastTheDetailedMap(False);
end;

procedure TMapReaderTests.SegmentTable_PE32Plus_IgnoresDetailedMapOffsetsAboveThePreferredBase;
begin
  CheckTextLineBindsPastTheDetailedMap(True);
end;

procedure TMapReaderTests.CheckTextLineBindsPastTheDetailedMap(Is64Bit: Boolean);
begin
  WriteSyntheticMap(BigImageMapText(Is64Bit));
  var Map := LoadSyntheticMap;
  try
    var Rva: UInt64;
    Assert.IsTrue(Map.SourceLineToRva(BIG_UNIT_SOURCE, BIG_UNIT_TEXT_LINE, Rva),
      'a .text line of BigUnit must have an address');
    Assert.AreEqual<UInt64>(BIG_UNIT_TEXT_RVA, Rva,
      Format('.text line bound to RVA $%x; segment 1 base must be $1000', [Rva]));
  finally
    Map.Free;
  end;
end;

procedure TMapReaderTests.LineNumbers_ItextSectionOfTheSameFile_IsIndexed;
begin
  WriteSyntheticMap(BigImageMapText(False));
  var Map := LoadSyntheticMap;
  try
    var Rva: UInt64;
    Assert.IsTrue(Map.SourceLineToRva(BIG_UNIT_SOURCE, BIG_UNIT_ITEXT_LINE, Rva),
      'a line in the .itext section must have an address');
    Assert.AreEqual<UInt64>(BIG_UNIT_ITEXT_RVA, Rva);
    var Loc: TSourceLocation;
    Assert.IsTrue(Map.RvaToSourceLine(BIG_UNIT_ITEXT_RVA, Loc),
      'an address in the .itext section must have a line');
    Assert.AreEqual(BIG_UNIT_ITEXT_LINE, Loc.Line);
    Assert.AreEqual(BIG_UNIT_SOURCE, Loc.SourceFile);
  finally
    Map.Free;
  end;
end;

procedure TMapReaderTests.LineNumbers_ItextSectionOfTheSameFile_SurvivesTheSidecar;
begin
  WriteSyntheticMap(BigImageMapText(False));
  // The first load scans the MAP and writes the sidecar; the second reads it.
  LoadSyntheticMap.Free;
  Assert.IsTrue(TFile.Exists(FMapPath + '.idx'), 'the first load must write the .idx sidecar');
  var Map := LoadSyntheticMap;
  try
    var Rva: UInt64;
    Assert.IsTrue(Map.SourceLineToRva(BIG_UNIT_SOURCE, BIG_UNIT_ITEXT_LINE, Rva),
      'a line in the .itext section must have an address after a sidecar load');
    Assert.AreEqual<UInt64>(BIG_UNIT_ITEXT_RVA, Rva);
    Assert.IsTrue(Map.SourceLineToRva(BIG_UNIT_SOURCE, BIG_UNIT_TEXT_LINE, Rva),
      'the .text section must still be there after a sidecar load');
    Assert.AreEqual<UInt64>(BIG_UNIT_TEXT_RVA, Rva);
  finally
    Map.Free;
  end;
end;

procedure CheckLine(Map: TMapFile; Rva: UInt64; const ExpectedFile: string; ExpectedLine: Integer);
begin
  var Loc: TSourceLocation;
  Assert.IsTrue(Map.RvaToSourceLine(Rva, Loc), Format('RVA $%x must have a line', [Rva]));
  Assert.AreEqual(ExpectedFile + ':' + IntToStr(ExpectedLine),
    ExtractFileName(Loc.SourceFile) + ':' + IntToStr(Loc.Line), Format('line of RVA $%x', [Rva]));
end;

procedure TMapReaderTests.RvaToSourceLine_SharedAddressAtAUnitBoundary_GoesToTheLaterSection;
begin
  WriteSyntheticMap(UnitBoundaryMapText);
  var Map := LoadSyntheticMap;
  try
    // Load Gen.pas first, the order that used to keep its record.
    var Rva: UInt64;
    Assert.IsTrue(Map.SourceLineToRva('C:\src\Gen.pas', 900, Rva), 'Gen.pas:900 must have an address');
    CheckLine(Map, $3000, 'UnitB.pas', 20);
    CheckLine(Map, $3008, 'UnitB.pas', 20);
  finally
    Map.Free;
  end;
end;

procedure TMapReaderTests.RvaToSourceLine_AfterAnInterleavedSection_ResolvesToItsOwnFile;
begin
  WriteSyntheticMap(InterleavedMapText);
  var Map := LoadSyntheticMap;
  try
    // First lookup, nothing loaded: UnitU.pas:30 follows Gen.pas:500 by $100.
    CheckLine(Map, $2300, 'UnitU.pas', 30);
    // Inside the generic's code, and back in UnitU's after it with both loaded.
    CheckLine(Map, $2210, 'Gen.pas', 500);
    CheckLine(Map, $2310, 'UnitU.pas', 30);
    CheckLine(Map, $6000, 'Gen.pas', 600);
  finally
    Map.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMapReaderTests);

end.
