unit TestTargetConflict2;

// Deliberate per-unit type-collision target #2. Structurally identical to
// TestTargetConflict1 (same shape, different type NAMES). See that unit's
// header for the rationale.

interface

type
  TConflictEnum2 = (ce2Lo, ce2Mid, ce2Hi);

  TConflictRec2 = record
    Num: Integer;
    Tag: string;
  end;

  TConflictHolder2 = class
  public
    Payload: TConflictRec2;
    Mode:    TConflictEnum2;
    constructor Create;
  end;

var
  GConflict2Global: TConflictRec2;
  // SAME NAME as TestTargetConflict1.GSharedAmbiguous (see that unit's note);
  // globally-distinct type (Double here vs Integer in unit 1).
  GSharedAmbiguous: Double;

procedure RunConflict2;

implementation

uses
  TestTargetConflictSink;

constructor TConflictHolder2.Create;
  procedure InnerNested2;
  var
    LocalRec: TConflictRec2;
  begin
    LocalRec.Num := 202;
    LocalRec.Tag := 'local-unit-2';
    ConflictSink := LocalRec.Num + Ord(ce2Hi);   // {BP:CONFLICT2}
  end;
  // Same NAME as TestTargetConflict1.SharedConflictProc; constructor-nested +
  // INLINE var with a unit-distinct name (Marker2). See unit 1's note.
  procedure SharedConflictProc;
  begin
    var Marker2 := 2202;
    ConflictSink := Marker2;   // {BP:SHARED2}
  end;
begin
  Payload.Num := 22;
  Payload.Tag := 'holder2';
  Mode := ce2Mid;
  InnerNested2;
  SharedConflictProc;
end;

procedure TouchSharedAmbiguous2;
begin
  GSharedAmbiguous := 7373.5;
  ConflictSink := Trunc(GSharedAmbiguous);   // {BP:AMBIG_GLOBAL_2}
end;

procedure RunConflict2;
begin
  var Holder := TConflictHolder2.Create;
  GConflict2Global := Holder.Payload;
  Holder.Free;
  TouchSharedAmbiguous2;
end;

end.
