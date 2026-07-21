unit TestTargetReal;

// Scenarios mirroring REAL SampleApp code shapes that idealised samplers
// missed:
//   * a `const v: Variant` PARAMETER holding a VarArray (IsNull pattern)
//     -- must be expandable in the locals view; the Boolean Result must
//     NOT be expandable.
//   * a `var V: Variant` local assigned Null -- must show as Null, not a
//     stale integer.
//   * a class deriving from a base with fields -- expansion must include
//     INHERITED fields, not only the leaf class's own.
//   * evaluating a function's PARAMETERS from inside its body.

interface

uses
  System.Variants;

procedure RunReal;
procedure RunRobust;

{$Z4}
type
  TWideOrdEnum = (woA, woB, woC);   // {$Z4}: stored in 4 bytes
{$Z1}

type
  TBaseQuery = class
  public
    FBaseTag:  Integer;
    FBaseName: string;
    constructor Create;
  end;

  TDerivedQuery = class(TBaseQuery)
  public
    FOwnField: Integer;
    constructor Create;
  end;

implementation

uses
  System.SysUtils;

type
  TLocalSink = class
    procedure Use(const Tag: string; const Vals: array of const); virtual;
  end;

procedure TLocalSink.Use(const Tag: string; const Vals: array of const);
begin
end;

var
  GSink: TLocalSink;

constructor TBaseQuery.Create;
begin
  inherited Create;
  FBaseTag  := 77;
  FBaseName := 'base-name';
end;

constructor TDerivedQuery.Create;
begin
  inherited Create;
  FOwnField := 88;
end;

// IsNull-shaped: const Variant param, Boolean result. At REAL_ISNULL_BODY
// the param `v` is a VarArray of two Variants; Result is a plain Boolean.
function RealIsNull(const v: Variant): Boolean;
begin
  Result := VarIsNull(v);
  GSink.Use('isnull', [Result]);   // {BP:REAL_ISNULL_BODY}
end;

procedure RunReal;
var
  VArr:    Variant;
  VNull:   Variant;
  Derived: TDerivedQuery;
  B:       Boolean;
begin
  // VarArray of two Variants (the IsNull caller shape).
  VArr := VarArrayCreate([0, 1], varVariant);
  VArr[0] := VarToDateTime('2026-01-02');
  VArr[1] := VarToDateTime('2026-03-04');
  B := RealIsNull(VArr);

  // Variant explicitly holding Null.
  VNull := Null;

  Derived := TDerivedQuery.Create;
  try
    GSink.Use('real-body', [B, VarType(VNull), Derived.FOwnField, Derived.FBaseTag]);  // {BP:REAL_BODY}
  finally
    Derived.Free;
  end;
end;

// Robustness + edge: a dangling reference to a freed object (formatter
// must not crash), and a {$Z4} 4-byte enum.
procedure RunRobust;
var
  Freed: TDerivedQuery;
  WideE: TWideOrdEnum;
begin
  Freed := TDerivedQuery.Create;
  Freed.Free;            // Freed is now a dangling pointer (not nil)
  WideE := woB;          // ordinal 1, stored in 4 bytes
  GSink.Use('robust', [WideE = woB, NativeInt(Pointer(Freed))]);   // {BP:REAL_ROBUST_BODY}
end;

initialization
  GSink := TLocalSink.Create;

finalization
  GSink.Free;

end.
