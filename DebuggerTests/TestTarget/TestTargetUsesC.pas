unit TestTargetUsesC;

// Per-unit-uses scoping fixture, unit C (see TestTargetUsesA). Same names,
// 3-field record (SizeOf = 12) and value 'C'. C is the NEGATIVE control: the
// host unit does NOT use C, so resolution must never pick C's symbols.

interface

type
  TDupRec = record
    A1: Integer;
    A2: Integer;
    A3: Integer;
  end;

  TDup = class
    class function Tag: Integer;
  end;

const
  DupConst = 3;

function DupFunc: Integer;

implementation

class function TDup.Tag: Integer;
begin
  Result := 3;
end;

function DupFunc: Integer;
begin
  Result := 3;
end;

end.
