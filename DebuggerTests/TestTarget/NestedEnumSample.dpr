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

  // Class-nested. With the default {$SCOPEDENUMS OFF} the members land in the
  // CLASS's scope, so a bare `ikHidden` is legal inside TNestedHost's own
  // methods -- and inside a DESCENDANT's methods -- and nowhere else.
  TNestedHost = class
  protected type
    TInnerKind = (ikHidden, ikAlsoHidden);
  public
    Mode: TVisibleMode;
    function Describe: string;
  end;

  // Inheritance: a protected nested type is visible in a descendant's methods
  // too, so the bare member must resolve while stopped here as well.
  TDerivedHost = class(TNestedHost)
  public
    function DescribeDerived: string;
  end;

function TNestedHost.Describe: string;
begin
  // Referenced so the compiler keeps the nested type in the debug info. That
  // this line COMPILES is itself the evidence that a class-nested enum member
  // is bare-visible inside the owning class.
  var K: TInnerKind := ikAlsoHidden;
  Result := Format('%d/%d', [Ord(Mode), Ord(K)]);
end;

function TDerivedHost.DescribeDerived: string;
begin
  // And bare-visible in a DESCENDANT: this compiles without naming TNestedHost.
  var K: TInnerKind := ikHidden;
  Result := Format('derived %d', [Ord(K)]);
end;

// SCOPED enums: with the directive ON the members are NOT injected into the
// enclosing scope, so `seSecond` is illegal bare -- `TScopedMode.seSecond` is
// the only spelling, even in this same unit. Present so the debug info of a
// scoped enum can be compared against an unscoped one: if nothing distinguishes
// them, a bare-name lookup CANNOT honour the directive and that is a stated
// limit rather than a silent one.
{$SCOPEDENUMS ON}
type
  TScopedMode = (seFirst, seSecond, seThird);
{$SCOPEDENUMS OFF}

procedure UseScopedEnum;
var
  S: TScopedMode;
begin
  S := TScopedMode.seSecond;   // qualified -- the bare form would not compile
  Writeln(Ord(S));
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
    UseScopedEnum;
  finally
    H.Free;
  end;
  var D := TDerivedHost.Create;
  try
    Writeln(D.DescribeDerived);
  finally
    D.Free;
  end;
end.
