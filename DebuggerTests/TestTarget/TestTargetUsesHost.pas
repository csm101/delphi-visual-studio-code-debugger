unit TestTargetUsesHost;

// Frame unit for the per-unit-uses scoping test. Its uses clause is
// `TestTargetUsesA, TestTargetUsesB` (B LAST), and it does NOT use C. So an
// unqualified reference resolved AT a frame in this unit must pick unit B's
// symbol on every collision (Delphi last-wins), never A's (earlier in uses) and
// never C's (not used). The debugger must reproduce this when the user types
// the same names in a watch/hover (type cast, class method, free function,
// const).

interface

procedure RunUsesScope;

implementation

uses
  TestTargetUsesA,
  TestTargetUsesB;   // B is last -> wins all the A/B collisions

var
  GUsesHostSink: Integer;

procedure RunUsesScope;
begin
  // `TDup` unqualified here = unit B's (last in uses), so the instance is B's
  // TDup. A watch that casts it -- `TDup(DupInst).Tag` -- must resolve through
  // unit B and read 2 (the cast path of per-unit scoping, increment d).
  var DupInst: TDup := TDup.Create;
  try
    // Reference the unqualified names so unit B's copies are linked + present.
    // At the marker the debugger must resolve these SAME names (DupFunc /
    // DupConst / TDup.Tag / SizeOf(TDupRec)) to unit B (= 2 / 2 / 2 / 8).
    GUsesHostSink := DupFunc + DupConst + TDup.Tag + SizeOf(TDupRec);
    GUsesHostSink := GUsesHostSink + DupInst.Tag;   // {BP:USES_SCOPE}
  finally
    DupInst.Free;
  end;
end;

end.
