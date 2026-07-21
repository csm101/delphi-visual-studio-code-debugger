unit TestTargetUsesB;

// Per-unit-uses scoping fixture, unit B (see TestTargetUsesA). Same names,
// 2-field record (SizeOf = 8) and value 'B'.

interface

type
  TDupRec = record
    A1: Integer;
    A2: Integer;
  end;

  TDup = class
    class function Tag: Integer;
  end;

const
  DupConst = 2;

function DupFunc: Integer;

implementation

class function TDup.Tag: Integer;
begin
  Result := 2;
end;

function DupFunc: Integer;
begin
  Result := 2;
end;

end.
