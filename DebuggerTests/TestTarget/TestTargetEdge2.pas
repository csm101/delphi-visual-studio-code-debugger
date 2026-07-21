unit TestTargetEdge2;

// Second edge sampler: multi-dim arrays, nested generics, open-array
// params, nested records, currency / neg-zero float, short-string empty,
// long dot chain, function pointer, freed object, setVariable targets.

interface

uses
  System.Generics.Collections;

procedure RunEdge2;
procedure RunOpenArray;

type
  TInner3  = record X, Y: Integer; end;
  TMid3    = record Tag: Integer; Inner: TInner3; end;
  TOuter3  = record Name: ShortString; Mid: TMid3; end;

  TChainD = class public D: Integer; end;
  TChainC = class public C: TChainD; end;
  TChainB = class public B: TChainC; end;
  TChainA = class public A: TChainB; end;

  TPlainProc = procedure(X: Integer);

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

procedure PlainTarget(X: Integer);
begin
  GSink.Use('plain', [X]);
end;

// const open array parameter: A arrives as (pointer, high).
procedure RunOpenArray;

  procedure Inspect(const A: array of Integer);
  begin
    GSink.Use('open-array', [Length(A), A[0], A[High(A)]]);   // {BP:OPEN_ARRAY_BODY}
  end;

begin
  Inspect([10, 20, 30]);
end;

procedure RunEdge2;
var
  MStatic:  array[0..2, 0..2] of Integer;   // multi-dim static
  MDyn:     TArray<TArray<Integer>>;        // multi-dim dynamic
  Dict:     TDictionary<Integer, string>;   // generic dictionary
  NestList: TList<TList<Integer>>;          // nested generic
  Outer:    TOuter3;                        // nested record 3 deep
  Cur:      Currency;
  FNegZero: Double;
  ShortEmpty: ShortString;
  Chain:    TChainA;
  ProcPtr:  TPlainProc;
  SetLocal: Integer;                        // plain int for setVariable target
begin
  for var I := 0 to 2 do
    for var J := 0 to 2 do
      MStatic[I, J] := I * 10 + J;

  SetLength(MDyn, 2);
  MDyn[0] := [1, 2, 3];
  MDyn[1] := [4, 5];

  Dict := TDictionary<Integer, string>.Create;
  Dict.Add(7, 'seven');
  Dict.Add(8, 'eight');

  NestList := TList<TList<Integer>>.Create;
  NestList.Add(TList<Integer>.Create);
  NestList[0].AddRange([100, 200]);

  Outer.Name      := 'outer';
  Outer.Mid.Tag   := 42;
  Outer.Mid.Inner.X := 7;
  Outer.Mid.Inner.Y := 9;

  Cur       := 12.34;
  FNegZero  := -0.0;
  ShortEmpty := '';

  Chain := TChainA.Create;
  Chain.A := TChainB.Create;
  Chain.A.B := TChainC.Create;
  Chain.A.B.C := TChainD.Create;
  Chain.A.B.C.D := 1234;

  ProcPtr := PlainTarget;
  SetLocal := 5;

  GSink.Use('edge2-body',                  // {BP:EDGE2_BODY}
    [MStatic[1, 1], Length(MDyn), Dict.Count, NestList.Count,
     Outer.Mid.Inner.X, Cur, ShortEmpty, Chain.A.B.C.D, SetLocal]);
  GSink.Use('edge2-keep', [FNegZero, Integer(Assigned(ProcPtr))]);

  Chain.A.B.C.Free; Chain.A.B.Free; Chain.A.Free; Chain.Free;
  NestList[0].Free; NestList.Free;
  Dict.Free;
end;

initialization
  GSink := TLocalSink.Create;

finalization
  GSink.Free;

end.
