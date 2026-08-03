program NestedEnumSample;

// Fixture for ONE fact: how the compiler records a type declared INSIDE a class
// versus one declared at unit level or inside a routine.
//
// It exists as a separate target rather than as additions to TestTarget because
// adding declarations to TestTarget shifts the RSM per-unit import indices, and
// that has already broken unrelated tests once. Nothing here is debugged live;
// the tests read the binary's TD32 with TTD32FileReader.
//
// The shape reproduces the defect found on two real applications: DevExpress
// declares
//   TdxPopupMenuController = class ... strict protected type
//     TPopupMenuKind = (External, VCL, Application);
// so `Application` is an enum member of a CLASS-NESTED type -- unreachable by a
// bare name from anywhere -- and a flat scan of every enum answered a bare
// `Application` with it.

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

type
  // Unit-level: its members ARE reachable by a bare name from any unit that
  // uses this one. Must keep resolving.
  TVisibleMode = (vmFirst, vmSecond, vmThird);

  // Class-nested: `TNestedHost.TInnerKind.ikHidden` is the ONLY legal spelling.
  // A bare `ikHidden` means nothing, even inside TNestedHost.
  TNestedHost = class
  strict protected type
    TInnerKind = (ikHidden, ikAlsoHidden);
  public
    Mode: TVisibleMode;
    function Describe: string;
  end;

function TNestedHost.Describe: string;
begin
  // Referenced so the compiler keeps the nested type in the debug info.
  var K: TInnerKind := ikAlsoHidden;
  Result := Format('%d/%d', [Ord(Mode), Ord(K)]);
end;

procedure UseRoutineLocalEnum;
type
  // Routine-local: reachable by a bare name INSIDE this routine, so it must
  // keep resolving. This is the case a naive "refuse anything scoped" rule
  // would break.
  TRoutineKind = (rkAlpha, rkBeta);
var
  R: TRoutineKind;
begin
  R := rkBeta;
  Writeln(Ord(R));
end;

begin
  var H := TNestedHost.Create;
  try
    H.Mode := vmSecond;
    Writeln(H.Describe);
    UseRoutineLocalEnum;
  finally
    H.Free;
  end;
end.
