unit MapReaderTests;

// Unit tests for TMapFile name resolution. Exercises NameToRva against the
// freshly-built TestTarget.map without needing a live debug session.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TMapReaderTests = class
  public
    // Regression for the SampleApp getter-address miss: the MAP qualifies a
    // method with its unit but without the dotted namespace
    // (`Forms.TApplication.GetMainFormHandle`), so a `ClassName.Method` getter
    // lookup (`TApplication.GetMainFormHandle`) matched neither the exact full
    // name nor (safely) the bare last segment. NameToRva must resolve it via
    // the `Class.Method` (last-two-segments) index, ignoring the unit prefix.
    [Test]
    procedure NameToRva_ClassMethod_ResolvesIgnoringUnitPrefix;
  end;

implementation

uses
  System.SysUtils,
  MapFileReader;

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

initialization
  TDUnitX.RegisterTestFixture(TMapReaderTests);

end.
