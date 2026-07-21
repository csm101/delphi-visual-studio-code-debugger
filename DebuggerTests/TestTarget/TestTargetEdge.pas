unit TestTargetEdge;

// Edge-case sampler. Each scenario is a local (or dedicated frame) the
// integration tests inspect to pin correct behaviour on tricky shapes:
// large sets, gap enums, empty/nil strings, special floats, recursion,
// cyclic object graphs, objects mid-construction, variant records,
// interface->class resolution, embedded-NUL / emoji strings.

interface

procedure RunEdgeCases;
procedure RunRecursion;
procedure RunCtorProbe;
procedure RunStepRaise;

implementation

uses
  System.SysUtils, System.Math;

type
  TLocalSink = class
    procedure Use(const Tag: string; const Vals: array of const); virtual;
  end;

procedure TLocalSink.Use(const Tag: string; const Vals: array of const);
begin
end;

var
  GSink: TLocalSink;

type
  // 20-member enum -> set needs 4 bytes (bits beyond the first 8 expose
  // the 1-byte set-decode bug if present).
  TManyEnum = (me0, me1, me2, me3, me4, me5, me6, me7, me8, me9,
               me10, me11, me12, me13, me14, me15, me16, me17, me18, me19);
  TManySet = set of TManyEnum;

  // Enum with explicit, non-contiguous ordinals.
  TGapEnum = (geA = 5, geB = 10, geC = 20);

  // Variant record (overlapping fields).
  TVariantRec = record
    case Kind: Integer of
      0: (AsInt: Integer);
      1: (AsBytes: array[0..3] of Byte);
  end;

  IThing = interface
    ['{7F3A1C28-9D44-4B6E-8A12-5C0E2F9B7A36}']
    function Name: string;
  end;

  TThing = class(TInterfacedObject, IThing)
  public
    FName: string;
    function Name: string;
  end;

  // Self-referential node (cyclic graph: child.Parent points back to root).
  TEdgeNode = class
  public
    Value:  Integer;
    Parent: TEdgeNode;
    Child:  TEdgeNode;
  end;

  TCtorProbe = class
  public
    FirstField:  Integer;
    SecondField: Integer;
    constructor Create;
  end;

  // Virtual method + override, for `inherited` in a watch expression.
  TGreetBase = class
    function Greet: string; virtual;
  end;

  TGreetDerived = class(TGreetBase)
    function Greet: string; override;
  end;

  // Deliberately very long class name: the fully-qualified method name exceeds
  // 200 chars, exercising name resolution / frame labelling against any fixed
  // buffer limit.
  TLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongName = class
    procedure Marker;
  end;

function TThing.Name: string;
begin
  Result := FName;
end;

function TGreetBase.Greet: string;
begin
  Result := 'base-greet';
end;

function TGreetDerived.Greet: string;
begin
  Result := 'derived-' + inherited Greet;
  GSink.Use('inherited-body', [Length(Result)]);   // {BP:INHERITED_BODY}
end;

procedure RunInherited;
var
  O: TGreetBase;
begin
  O := TGreetDerived.Create;
  try
    GSink.Use('inherited-res', [Length(O.Greet)]);
  finally
    O.Free;
  end;
end;

procedure TLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongName.Marker;
begin
  GSink.Use('longname-body', [1]);   // {BP:LONGNAME_BODY}
end;

procedure RunStepRaise;
begin
  try
    raise Exception.Create('step-raise-exc');   // {BP:STEP_AT_RAISE}
  except
    on E: Exception do   // {BP:STEP_RAISE_HANDLER} -- step-over the raise lands here
      GSink.Use('step-handler', [Length(E.Message)]);
  end;
end;

procedure RunLongName;
var
  O: TLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongName;
begin
  O := TLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongNameLongName.Create;
  try
    O.Marker;
  finally
    O.Free;
  end;
end;

constructor TCtorProbe.Create;
begin
  inherited Create;
  FirstField := 111;
  GSink.Use('ctor-mid', [FirstField]);   // {BP:CTOR_MID_BODY}  SecondField not set yet
  SecondField := 222;
end;

// Recursive: BP at the base case; the stack then holds one frame per
// depth, each with its own N. Tests per-frame local isolation.
function EdgeFactorial(N: Integer): Integer;
begin
  if N <= 1 then begin
    Result := 1;
    GSink.Use('fact-base', [N]);   // {BP:RECURSION_BASE_BODY}
    Exit;
  end;
  Result := N * EdgeFactorial(N - 1);
end;

procedure RunRecursion;
begin
  GSink.Use('fact-result', [EdgeFactorial(5)]);
end;

procedure RunCtorProbe;
var
  P: TCtorProbe;
begin
  P := TCtorProbe.Create;
  try
    GSink.Use('ctor-done', [P.FirstField, P.SecondField]);
  finally
    P.Free;
  end;
end;

procedure RunEdgeCases;
var
  ManySet:  TManySet;
  EmptySet2: TManySet;
  Gap:      TGapEnum;
  EmptyStr: string;
  NilStr:   string;
  NegI:     Integer;
  NegI64:   Int64;
  NegSmall: SmallInt;
  FNan:     Double;
  FInf:     Double;
  FNegZero: Double;
  LongStr:  string;
  NulStr:   string;
  EmojiStr: string;
  VRec:     TVariantRec;
  Thing:    IThing;
  Root:     TEdgeNode;
  Leaf:     TEdgeNode;
begin
  RunInherited;                    // exercises `inherited` in a watch (own BP)
  RunLongName;                     // exercises >200-char qualified name (own BP)
  ManySet   := [me0, me9, me19];   // bits 0,9,19 -> needs >1 byte
  EmptySet2 := [];
  Gap       := geB;                // ordinal 10
  EmptyStr  := '';
  NilStr    := '';                 // both are nil pointers in Delphi
  NegI      := -5;
  NegI64    := -5000000000;
  NegSmall  := -1234;
  FNan      := NaN;
  FInf      := Infinity;
  FNegZero  := -0.0;
  LongStr   := StringOfChar('X', 5000);
  NulStr    := 'a'#0'b';
  EmojiStr  := 'hi '#$D83D#$DE00;  // 'hi ' + grinning-face surrogate pair
  VRec.AsInt := $01020304;

  Thing := TThing.Create;
  (Thing as TThing).FName := 'thing-impl';

  Root := TEdgeNode.Create;
  Leaf := TEdgeNode.Create;
  Root.Value  := 1;
  Leaf.Value  := 2;
  Root.Child  := Leaf;
  Leaf.Parent := Root;             // cycle: Root.Child.Parent = Root

  GSink.Use('edge-body',           // {BP:EDGE_BODY}
    [NegI, NegI64, NegSmall, Ord(Gap), Length(LongStr), Length(NulStr),
     EmptyStr, NilStr, VRec.AsInt, Thing.Name, Root.Value, Leaf.Value]);
  // keep float + set + emoji locals live across the BP
  GSink.Use('edge-keep',
    [FNan, FInf, FNegZero, EmojiStr, Byte(ManySet <> EmptySet2)]);

  Root.Free;
  Leaf.Free;
end;

initialization
  GSink := TLocalSink.Create;

finalization
  GSink.Free;

end.
