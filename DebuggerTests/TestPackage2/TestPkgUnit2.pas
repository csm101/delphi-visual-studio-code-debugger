unit TestPkgUnit2;

interface

type
  // A class defined in a SECOND, independently loaded BPL. Used to prove
  // the adapter routes symbols per-module: with two BPLs loaded at once,
  // a breakpoint in each must resolve against its OWN module's debug
  // info, not collide with the other's.
  TPkg2Gadget = class
  private
    FSerial: Integer;
    FKind:   string;
  public
    constructor Create(ASerial: Integer; const AKind: string);
    property Serial: Integer read FSerial;
    property Kind: string read FKind;
  end;

var
  // Cross-BINARY collision twin: same name as TestPackage's GCrossBinAmbiguous
  // (declared there as Integer). With both BPLs loaded, watching this from a
  // frame inside THIS package must resolve to this binary's copy (Double),
  // never the other binary's Integer. Set in initialization.
  GCrossBinAmbiguous: Double;

function PkgMul(A, B: Integer): Integer;

implementation

uses
  Winapi.Windows;

constructor TPkg2Gadget.Create(ASerial: Integer; const AKind: string);
begin
  inherited Create;
  FSerial := ASerial;
  FKind   := AKind;
end;

function PkgMul(A, B: Integer): Integer;
var
  G: TPkg2Gadget;
begin
  G := TPkg2Gadget.Create(A * B, 'gadget2');
  try
    Result := G.Serial;     // {BP:PKG2_BP}
    Sleep(0);
  finally
    G.Free;
  end;
end;

initialization
  // PkgMul(4, 5) -> A=4, B=5, G.Serial=20. The PKG2_BP marker fires
  // here when the host LoadPackages this BPL.
  // Set BEFORE PkgMul so the value is live when PKG2_BP (inside PkgMul) fires.
  GCrossBinAmbiguous := 222.5;
  PkgMul(4, 5);

end.
