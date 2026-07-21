unit TestTargetUsesA;

// Per-unit-uses scoping fixture, unit A. Units A/B/C declare the SAME names
// (TDupRec, TDup, DupFunc, DupConst) with DIFFERENT shapes/values, so an
// unqualified reference from a frame can only be resolved correctly by the
// frame unit's uses clause (Delphi last-wins on collisions). The values/sizes
// are distinct per unit so a watch reveals WHICH unit's symbol was picked.

interface

type
  // 1 field -> SizeOf = 4. (B: 8, C: 12.)
  TDupRec = record
    A1: Integer;
  end;

  TDup = class
    class function Tag: Integer;
  end;

const
  DupConst = 1;   // A=1, B=2, C=3

function DupFunc: Integer;

implementation

class function TDup.Tag: Integer;
begin
  Result := 1;
end;

function DupFunc: Integer;
begin
  Result := 1;
end;

end.
