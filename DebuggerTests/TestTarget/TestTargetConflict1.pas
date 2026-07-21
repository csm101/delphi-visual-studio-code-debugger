unit TestTargetConflict1;

// Deliberate per-unit type-collision target #1. Structurally identical to
// TestTargetConflict2 (same declaration order/shape, different type NAMES) so
// the two units' per-unit RSM TypeIds line up and collide in the global
// TypeId->name map. The local under test lives in a CONSTRUCTOR-NESTED proc --
// the one scope TD32 does not emit locals for (mirrors SampleApp LoadMenu) -- so
// resolution falls back to RSM, where the per-unit fix must pick THIS unit's
// type, not the colliding foreign one.

interface

type
  TConflictEnum1 = (ce1Lo, ce1Mid, ce1Hi);

  TConflictRec1 = record
    Num: Integer;
    Tag: string;
  end;

  TConflictHolder1 = class
  public
    Payload: TConflictRec1;
    Mode:    TConflictEnum1;
    constructor Create;
  end;

var
  GConflict1Global: TConflictRec1;
  // SAME NAME as TestTargetConflict2.GSharedAmbiguous but a DIFFERENT,
  // globally-distinct type (Integer here vs Double in unit 2). The plain
  // first-hit FindGlobal returns whichever unit was parsed first for BOTH
  // stops; only the IUnitScopedGlobalProvider path picks THIS unit's record.
  // (Distinct primitive types keep the type-name resolution unambiguous, so the
  // test isolates unit-scoped record selection from the separate RSM
  // record/class typeId-collision bug.)
  GSharedAmbiguous: Integer;

procedure RunConflict1;

implementation

uses
  TestTargetConflictSink;

constructor TConflictHolder1.Create;
  // Nested inside a constructor on purpose: TD32 emits no locals here, forcing
  // the RSM per-unit path for `LocalRec`.
  procedure InnerNested1;
  var
    LocalRec: TConflictRec1;
  begin
    LocalRec.Num := 101;
    LocalRec.Tag := 'local-unit-1';
    ConflictSink := LocalRec.Num + Ord(ce1Hi);   // {BP:CONFLICT1}
  end;
  // Same NAME in both conflict units. Constructor-nested + INLINE var (not a
  // var-block): the exact shape TD32 emits NO locals for (mirrors SampleApp
  // LoadMenu). With TD32 silent by RVA, the adapter must resolve `Marker1` via
  // the RSM unit-scoped path -- and must pick THIS unit's copy, not unit 2's.
  procedure SharedConflictProc;
  begin
    var Marker1 := 1101;
    ConflictSink := Marker1;   // {BP:SHARED1}
  end;
begin
  Payload.Num := 11;
  Payload.Tag := 'holder1';
  Mode := ce1Mid;
  InnerNested1;
  SharedConflictProc;
end;

procedure TouchSharedAmbiguous1;
begin
  GSharedAmbiguous := 4242;
  ConflictSink := GSharedAmbiguous;   // {BP:AMBIG_GLOBAL_1}
end;

procedure RunConflict1;
begin
  var Holder := TConflictHolder1.Create;
  GConflict1Global := Holder.Payload;
  Holder.Free;
  TouchSharedAmbiguous1;
end;

end.
