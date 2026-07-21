unit TestTargetCollider;

// Secondary unit hosting a class whose method names deliberately collide
// with TestTarget.dpr's TMenuRepro. Two units, each declaring a method
// `LoadMenu` with a nested `CreateNodes`. Verifies the debugger does not
// pull the wrong scope's locals on a short-name augment lookup.
//
// Bug repro target:
//   * `RsmFileReader.FProcOffsets` is keyed by lowercase short proc name.
//     AddOrSetValue keeps the LAST `createnodes` indexed; every same-name
//     lookup then returns the wrong scope's locals.
//   * `MapFileReader.FRvaToParent` correlates `_ZZ$pdata$` / regular
//     publics by (Unit, Inner); cross-unit duplicates would otherwise
//     point the parent walk at the wrong enclosing method.
//
// Test assertion (in DebuggerTests.pas): stop in
// `TMenuRepro.LoadMenu.CreateNodes` (declared in TestTarget.dpr) and
// verify CurrentLevel is Integer 1 -- NOT the `string 'collider-level'`
// that THIS unit's CreateNodes would emit if the wrong scope leaked
// through the augment merge.

interface

type
  TMenuCollider = class
  public
    procedure LoadMenu;
  end;

procedure RunCollider;

implementation

// Local opaque sink: virtual call keeps locals live without touching the
// program's GSink. The collider unit is intentionally self-contained.
type
  TLocalSink = class
    procedure Use(const Tag: string; const Vals: array of const); virtual;
  end;

procedure TLocalSink.Use(const Tag: string; const Vals: array of const);
begin
  // intentionally empty; the virtual dispatch defeats the optimiser.
end;

var
  GLocalSink: TLocalSink;

procedure TMenuCollider.LoadMenu;
var
  Sentinel: Integer;

  procedure CreateNodes(NodeId: Integer);
  var
    CurrentLevel:  string;          // intentionally string, NOT Integer
    CurrentParent: string;          // intentionally string, NOT class-ptr
    LocalStr:      Integer;         // intentionally Integer, NOT string
  begin
    CurrentLevel  := 'collider-level';
    CurrentParent := 'collider-parent';
    LocalStr      := 99;
    GLocalSink.Use('collider-createnodes',
      [NodeId, CurrentLevel, CurrentParent, LocalStr, Sentinel]);
  end;

begin
  Sentinel := 7;
  CreateNodes(1);
end;

procedure RunCollider;
var
  C: TMenuCollider;
begin
  C := TMenuCollider.Create;
  try
    C.LoadMenu;
  finally
    C.Free;
  end;
end;

initialization
  GLocalSink := TLocalSink.Create;

finalization
  GLocalSink.Free;

end.
