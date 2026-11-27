unit PackageInfoReaderTests;

// Tests for DebuggerCore\PackageInfoReader.pas: the unit list and the requires
// list of a binary's PACKAGEINFO resource.
//
// The reader was moved out of the DAP front end (TDllModule in DapServer.pas),
// so the fixture-driven tests have two independent oracles:
//   * the RTL's own reader, System.SysUtils.GetPackageInfo, run over the same
//     file mapped as data;
//   * the parser the DAP front end used before the move, kept here verbatim
//     (LegacyDapPackageInfo), which proves the lookup keys the front end
//     builds from the new reader are the ones it always built.
//
// No debug session: the fixture package is read as a file, on both bitnesses.

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Generics.Collections;

type
  [TestFixture]
  TPackageInfoReaderTests = class
  private
    function FixtureRoot: string;
    function PackagePaths: TArray<string>;
    procedure CheckAgainstTheRtl(const Path: string; ExpectRequires: Boolean);
  public
    [Test] procedure TestSubject_UnitsAndRequires_AreWhatTheRtlReads;
    [Test] procedure Executable_CarriesTheResourceToo;
    [Test] procedure TestSubject_LookupKeys_AreWhatTheFormerDapParserBuilt;
    [Test] procedure Parse_ResourceCutShortAnywhere_IsIncompleteAndKeepsWhatItRead;
    [Test] procedure Parse_NegativeCount_IsIncomplete;
    [Test] procedure Read_MissingFileOrNotAnImage_ReturnsFalse;
    [Test] procedure LookupKeys_FullNameAndLastSegment;
  end;

implementation

uses
  System.Classes, System.IOUtils, Winapi.Windows,
  PackageInfoReader;

type
  // What System.SysUtils.GetPackageInfo reports, in the order it reports it.
  TRtlPackageNames = class
  public
    Units:    TList<string>;
    Requires: TList<string>;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TRtlPackageNames.Create;
begin
  inherited Create;
  Units    := TList<string>.Create;
  Requires := TList<string>.Create;
end;

destructor TRtlPackageNames.Destroy;
begin
  Requires.Free;
  Units.Free;
  inherited;
end;

procedure CollectRtlName(const Name: string; NameType: TNameType; Flags: Byte; Param: Pointer);
begin
  var Names := TRtlPackageNames(Param);
  case NameType of
    ntContainsUnit:    Names.Units.Add(Name);
    ntRequiresPackage: Names.Requires.Add(Name);
  end;
end;

// The parser TDllModule.ContainsUnitByPackageInfo held in line before the
// reader moved to DebuggerCore, unchanged except that it fills the two
// arguments instead of the module's fields. Returns what the DAP front end's
// first call computed: the dictionary of lookup keys and the requires list.
procedure LegacyDapPackageInfo(const FullPath: string; PackageUnits: TDictionary<string, Boolean>;
  out RequiredPackages: TArray<string>);

  function ReadAnsiZLen(P, PEnd: PByte; out Len: Integer): Boolean;
  begin
    Len := 0;
    while (P + Len) < PEnd do begin
      if PByte(P + Len)^ = 0 then
        Exit(True);
      Inc(Len);
    end;
    Result := False;
  end;

type
  PPackageInfoHeader = ^TPackageInfoHeader;
  TPackageInfoHeader = packed record
    Flags: Cardinal;
    RequiresCount: Integer;
  end;

var
  ModuleHandle: HMODULE;
  ResInfo: HRSRC;
  ResData: HGLOBAL;
  Cur, Stop: PByte;
  Header: PPackageInfoHeader;
begin
  RequiredPackages := nil;
  ModuleHandle := LoadLibraryEx(PChar(FullPath), 0, LOAD_LIBRARY_AS_DATAFILE);
  if ModuleHandle = 0 then
    Exit;
  try
    ResInfo := FindResource(ModuleHandle, 'PACKAGEINFO', RT_RCDATA);
    if ResInfo = 0 then
      Exit;
    ResData := LoadResource(ModuleHandle, ResInfo);
    if ResData = 0 then
      Exit;
    Cur := LockResource(ResData);
    if Cur = nil then
      Exit;
    Stop := Cur + SizeofResource(ModuleHandle, ResInfo);
    if Stop <= Cur then
      Exit;
    if (Stop - Cur) < SizeOf(TPackageInfoHeader) then
      Exit;

    Header := PPackageInfoHeader(Cur);
    Inc(Cur, SizeOf(TPackageInfoHeader));
    if Header.RequiresCount < 0 then
      Exit;

    for var I := 0 to Header.RequiresCount - 1 do begin
      if Cur + 2 > Stop then
        Exit;
      var NameLen := 0;
      if not ReadAnsiZLen(Cur + 1, Stop, NameLen) then
        Exit;
      if NameLen > 0 then begin
        var ReqName: AnsiString;
        SetString(ReqName, PAnsiChar(Cur + 1), NameLen);
        RequiredPackages := RequiredPackages + [LowerCase(ChangeFileExt(string(ReqName), ''))];
      end;
      Inc(Cur, NameLen + 2);
    end;

    if Cur + SizeOf(Integer) > Stop then
      Exit;
    var ContainsCount := PInteger(Cur)^;
    if ContainsCount < 0 then
      Exit;
    Inc(Cur, SizeOf(Integer));

    for var I := 0 to ContainsCount - 1 do begin
      if Cur + 3 > Stop then
        Exit;
      var NameLen := 0;
      if not ReadAnsiZLen(Cur + 2, Stop, NameLen) then
        Exit;
      var Utf8Unit: UTF8String;
      SetString(Utf8Unit, PAnsiChar(Cur + 2), NameLen);
      var FullUnit := LowerCase(UTF8ToString(Utf8Unit));
      if FullUnit <> '' then begin
        PackageUnits.AddOrSetValue(FullUnit, True);
        var DotPos := LastDelimiter('.', FullUnit);
        if DotPos > 0 then
          PackageUnits.AddOrSetValue(Copy(FullUnit, DotPos + 1, MaxInt), True);
      end;
      Inc(Cur, NameLen + 3);
    end;
  finally
    FreeLibrary(ModuleHandle);
  end;
end;

// A PACKAGEINFO resource built by hand, in the layout the linker writes.
function BuildResource(Flags: Cardinal; RequiresCount: Integer; const Requires: TArray<string>;
  ContainsCount: Integer; const Units: TArray<string>): TBytes;
var
  Stream: TBytesStream;

  procedure WriteName(const Name: string);
  begin
    var Raw := UTF8Encode(Name);
    if Length(Raw) > 0 then
      Stream.WriteBuffer(Raw[1], Length(Raw));
    var Terminator: Byte := 0;
    Stream.WriteBuffer(Terminator, 1);
  end;

begin
  Stream := TBytesStream.Create;
  try
    var Hash: Byte := $5A;
    var UnitFlags: Byte := $10;
    Stream.WriteBuffer(Flags, SizeOf(Flags));
    Stream.WriteBuffer(RequiresCount, SizeOf(RequiresCount));
    for var Name in Requires do begin
      Stream.WriteBuffer(Hash, 1);
      WriteName(Name);
    end;
    Stream.WriteBuffer(ContainsCount, SizeOf(ContainsCount));
    for var Name in Units do begin
      Stream.WriteBuffer(UnitFlags, 1);
      Stream.WriteBuffer(Hash, 1);
      WriteName(Name);
    end;
    Result := Copy(Stream.Bytes, 0, Integer(Stream.Size));
  finally
    Stream.Free;
  end;
end;

function IsPrefixOf(const Part, Whole: TArray<string>): Boolean;
begin
  if Length(Part) > Length(Whole) then
    Exit(False);
  for var I := 0 to High(Part) do
    if Part[I] <> Whole[I] then
      Exit(False);
  Result := True;
end;

{ TPackageInfoReaderTests }

function TPackageInfoReaderTests.FixtureRoot: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\');
end;

function TPackageInfoReaderTests.PackagePaths: TArray<string>;
begin
  Result := [
    FixtureRoot + 'TestHost\Win64\Debug\TestSubject.bpl',
    FixtureRoot + 'TestHost\Win32\Debug\TestSubject.bpl'];
  for var Path in Result do
    if not TFile.Exists(Path) then
      Assert.Fail('package fixture not found at ' + Path + ' -- run build_and_run.bat');
end;

procedure TPackageInfoReaderTests.TestSubject_UnitsAndRequires_AreWhatTheRtlReads;
begin
  for var Path in PackagePaths do
    CheckAgainstTheRtl(Path, True);
end;

procedure TPackageInfoReaderTests.Executable_CarriesTheResourceToo;
// The linker writes PACKAGEINFO into executables as well, so the unit list of
// a main module is as cheap to get as a package's.
begin
  for var Platform in ['Win64', 'Win32'] do begin
    var Path := FixtureRoot + 'TestTarget\' + Platform + '\Debug\TestTarget.exe';
    Assert.IsTrue(TFile.Exists(Path), 'executable fixture not found at ' + Path + ' -- run build_and_run.bat');
    CheckAgainstTheRtl(Path, False);
  end;
end;

procedure TPackageInfoReaderTests.CheckAgainstTheRtl(const Path: string; ExpectRequires: Boolean);
begin
  var Info: TPackageInfo;
  Assert.IsTrue(ReadPackageInfo(Path, Info), Path + ': no PACKAGEINFO read');
  Assert.IsTrue(Info.Complete, Path + ': the resource was not read to its end');

  var Rtl := TRtlPackageNames.Create;
  try
    var Module := LoadLibraryEx(PChar(Path), 0, LOAD_LIBRARY_AS_DATAFILE);
    Assert.IsTrue(Module <> 0, Path + ': cannot be mapped as data');
    var RtlFlags := 0;
    try
      GetPackageInfo(Module, Rtl, RtlFlags, CollectRtlName);
    finally
      FreeLibrary(Module);
    end;
    Assert.IsTrue(Rtl.Units.Count > 10,
      Format('%s: the RTL reads only %d units, so the comparison proves nothing', [Path, Rtl.Units.Count]));
    Assert.AreEqual(ExpectRequires, Rtl.Requires.Count > 0, Path + ': the RTL reads a required package');
    Assert.AreEqual(Cardinal(RtlFlags), Info.Flags, Path + ': flags');
    Assert.AreEqual(string.Join('|', Rtl.Units.ToArray), string.Join('|', Info.ContainedUnits), False,
      Path + ': contained units');
    Assert.AreEqual(string.Join('|', Rtl.Requires.ToArray), string.Join('|', Info.RequiredPackages), False,
      Path + ': required packages');
  finally
    Rtl.Free;
  end;
end;

procedure TPackageInfoReaderTests.TestSubject_LookupKeys_AreWhatTheFormerDapParserBuilt;
begin
  for var Path in PackagePaths do begin
    var Legacy := TDictionary<string, Boolean>.Create;
    var Current := TDictionary<string, Boolean>.Create;
    try
      var LegacyRequires: TArray<string>;
      LegacyDapPackageInfo(Path, Legacy, LegacyRequires);
      Assert.IsTrue(Legacy.Count > 10,
        Format('%s: the former parser yields only %d keys, so the comparison proves nothing', [Path, Legacy.Count]));

      // What TDllModule.ContainsUnitByPackageInfo does with the new reader.
      var Info: TPackageInfo;
      Assert.IsTrue(ReadPackageInfo(Path, Info), Path + ': no PACKAGEINFO read');
      var CurrentRequires: TArray<string> := [];
      for var Required in Info.RequiredPackages do
        CurrentRequires := CurrentRequires + [LowerCase(ChangeFileExt(Required, ''))];
      for var ContainedUnit in Info.ContainedUnits do
        for var Key in PackageUnitLookupKeys(ContainedUnit) do
          Current.AddOrSetValue(Key, True);

      var LegacyKeys := Legacy.Keys.ToArray;
      var CurrentKeys := Current.Keys.ToArray;
      TArray.Sort<string>(LegacyKeys);
      TArray.Sort<string>(CurrentKeys);
      Assert.AreEqual(string.Join('|', LegacyKeys), string.Join('|', CurrentKeys), False, Path + ': lookup keys');
      Assert.AreEqual(string.Join('|', LegacyRequires), string.Join('|', CurrentRequires), False,
        Path + ': required packages, in the spelling the front end keeps');
    finally
      Current.Free;
      Legacy.Free;
    end;
  end;
end;

procedure TPackageInfoReaderTests.Parse_ResourceCutShortAnywhere_IsIncompleteAndKeepsWhatItRead;
const
  FLAGS = Cardinal($C0000005);
  HEADER_SIZE = 8;
  GUARD_BYTES = 32;
begin
  // A name with a character outside ASCII, so the UTF-8 decoding is exercised.
  var Requires: TArray<string> := ['rtl290.bpl', 'vcl290.bpl'];
  var Units: TArray<string> := ['System.SysUtils', 'Unit' + #$00E9, 'Vcl.Forms'];
  var Whole := BuildResource(FLAGS, Length(Requires), Requires, Length(Units), Units);

  var Info: TPackageInfo;
  Assert.IsTrue(ParsePackageInfo(@Whole[0], Length(Whole), Info));
  Assert.IsTrue(Info.Complete, 'the whole resource');
  Assert.AreEqual(FLAGS, Info.Flags);
  Assert.AreEqual(string.Join('|', Requires), string.Join('|', Info.RequiredPackages), False);
  Assert.AreEqual(string.Join('|', Units), string.Join('|', Info.ContainedUnits), False);

  for var Size := 0 to Length(Whole) - 1 do begin
    // The cut block is followed by bytes that are neither a terminator nor
    // valid text: a reader that runs past Size returns a name it should not.
    var Cut: TBytes;
    SetLength(Cut, Size + GUARD_BYTES);
    FillChar(Cut[0], Length(Cut), $FF);
    if Size > 0 then
      Move(Whole[0], Cut[0], Size);
    var Accepted := ParsePackageInfo(@Cut[0], Size, Info);
    Assert.AreEqual(Size >= HEADER_SIZE, Accepted, Format('%d bytes: accepted', [Size]));
    Assert.IsFalse(Info.Complete, Format('%d bytes: reported complete', [Size]));
    Assert.IsTrue(IsPrefixOf(Info.RequiredPackages, Requires),
      Format('%d bytes: requires "%s"', [Size, string.Join('|', Info.RequiredPackages)]));
    Assert.IsTrue(IsPrefixOf(Info.ContainedUnits, Units),
      Format('%d bytes: units "%s"', [Size, string.Join('|', Info.ContainedUnits)]));
  end;

  Assert.IsFalse(ParsePackageInfo(nil, 100, Info), 'no data');
end;

procedure TPackageInfoReaderTests.Parse_NegativeCount_IsIncomplete;
begin
  var Info: TPackageInfo;
  var NoRequires := BuildResource(1, -1, [], 1, ['UnitA']);
  Assert.IsTrue(ParsePackageInfo(@NoRequires[0], Length(NoRequires), Info), 'the header is there');
  Assert.IsFalse(Info.Complete, 'a negative requires count');
  Assert.AreEqual(0, Integer(Length(Info.ContainedUnits)), 'nothing past a negative requires count is read');

  var NoUnits := BuildResource(1, 1, ['rtl290.bpl'], -1, ['UnitA']);
  Assert.IsTrue(ParsePackageInfo(@NoUnits[0], Length(NoUnits), Info));
  Assert.IsFalse(Info.Complete, 'a negative contains count');
  Assert.AreEqual('rtl290.bpl', string.Join('|', Info.RequiredPackages), False, 'the requires list was read before it');
  Assert.AreEqual(0, Integer(Length(Info.ContainedUnits)));

  // An entry with an empty name is skipped, in both lists.
  var EmptyNames := BuildResource(1, 2, ['', 'rtl290.bpl'], 2, ['UnitA', '']);
  Assert.IsTrue(ParsePackageInfo(@EmptyNames[0], Length(EmptyNames), Info));
  Assert.IsTrue(Info.Complete);
  Assert.AreEqual('rtl290.bpl', string.Join('|', Info.RequiredPackages), False);
  Assert.AreEqual('UnitA', string.Join('|', Info.ContainedUnits), False);
end;

procedure TPackageInfoReaderTests.Read_MissingFileOrNotAnImage_ReturnsFalse;
begin
  var Info: TPackageInfo;
  Assert.IsFalse(ReadPackageInfo('', Info), 'no path');
  Assert.IsFalse(ReadPackageInfo(FixtureRoot + 'TestHost\NoSuchPackage.bpl', Info), 'a file that does not exist');
  // A text file is not an image: it has no resources to look in.
  var NotAnImage := FixtureRoot + 'TestHost\TestSubject.dpk';
  Assert.IsTrue(TFile.Exists(NotAnImage), NotAnImage + ' is part of the repository');
  Assert.IsFalse(ReadPackageInfo(NotAnImage, Info), 'a file that is not a PE image');
  Assert.IsFalse(Info.Complete);
  Assert.AreEqual(0, Integer(Length(Info.ContainedUnits)));
end;

procedure TPackageInfoReaderTests.LookupKeys_FullNameAndLastSegment;
begin
  Assert.AreEqual('vcl.forms|forms', string.Join('|', PackageUnitLookupKeys('Vcl.Forms')), False);
  Assert.AreEqual('system.generics.collections|collections',
    string.Join('|', PackageUnitLookupKeys('System.Generics.Collections')), False);
  Assert.AreEqual('testtargetcore', string.Join('|', PackageUnitLookupKeys('TestTargetCore')), False,
    'a name with one segment has one key');
  Assert.AreEqual(0, Integer(Length(PackageUnitLookupKeys(''))));
end;

initialization
  TDUnitX.RegisterTestFixture(TPackageInfoReaderTests);

end.
