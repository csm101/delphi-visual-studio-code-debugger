unit TestTargetTypes;

// Wide-coverage type sampler. One procedure declares a local of every
// Delphi type family the debugger ought to handle. A single BP marker
// (search the lowercase form `types_body`) sits AFTER every assignment
// so each integration test can stop once and inspect any subset.
//
// Catalog gaps that surface only when these locals/parameters exist in
// a real frame:
//   * WordBool / LongBool (multi-byte boolean aliases)
//   * ShortString, WideString
//   * TGUID literal
//   * Interface variable (nil and live)
//   * Method pointer (procedure of object) -- nil and live
//   * Anonymous method reference -- nil and live
//   * Class reference (`class of TBar`) -- nil and live
//   * Generic class instance: TList<Integer>
//   * Untyped Pointer, PChar string content
//   * Out parameter
//   * Const parameter
//   * Default parameter
//   * Class static method (no Self)
//   * Class constructor body
//   * Operator overload body
//   * Property getter / setter body
//   * 3-level deep nested procedure (parent + grandparent locals)
//   * Same name across units (already covered by TestTargetCollider for
//     LoadMenu/CreateNodes; extended here with `DoWork` collision)

interface

uses
  System.Generics.Collections, System.SysUtils;

type
  // Top-level class named TDupCross. A DIFFERENT unit (TestTargetCore) declares
  // a nested class of the same bare name. This is the exact shape of the live
  // Data.DB.TFields vs System.Classes.TFieldsCache.TFields collision: same bare
  // name, two units, one top-level and one nested. Same-unit nesting did not
  // reproduce it (the compiler qualifies those), cross-unit does.
  TDupCross = class
  public
    RealFirst:  Integer;   // = 4242
    RealSecond: Integer;   // = 8484
    constructor Create;
  end;

  TStaticOps = class
  public
    class procedure Run(Tag: Integer); static;
  end;

  ICounter = interface
    ['{2B6A4F3E-8C1D-4F2B-9A5C-1E7D8F0A3B2C}']
    function NextValue: Integer;
  end;

  TCounter = class(TInterfacedObject, ICounter)
  public
    Value: Integer;
    constructor Create(AStart: Integer);
    function NextValue: Integer;
  end;

  TMethodPtr = procedure (X: Integer) of object;
  TAnonProc  = reference to procedure(X: Integer);

  TBase = class
  public
    BaseTag: Integer;
    constructor Create(ATag: Integer); virtual;
  end;

  TDerivedA = class(TBase)
  public
    constructor Create(ATag: Integer); override;
  end;

  TClassRef = class of TBase;

  TPoint2D = record
    X, Y: Double;
    function Magnitude: Double;
    class operator Add(const A, B: TPoint2D): TPoint2D;
  end;

  TPackedRec = packed record
    A: Byte;
    B: Integer;
    C: Word;
  end;

  TManagedRec = record
    Name: string;
    Tags: TArray<Integer>;
  end;

  TBareCounter = class
  private
    FValue: Integer;
    procedure SetValue(AValue: Integer);
  public
    constructor Create(AValue: Integer);
    property Value: Integer read FValue write SetValue;
  end;

// All-types main entrypoint
procedure RunTypeSampler;

// 3-level nesting depth test
procedure RunDeepNesting;

// Same-name collision with TestTarget.dpr `RunNestedClassMethodTest`
// helper (DoWork). Lets the adapter exercise short-name collision on a
// FREE proc, not just a class-method nested proc.
procedure DoWork;

// Class static method test entry
procedure RunStaticClassMethod;

// Operator overload test entry
procedure RunOperatorOverload;

// Property setter test entry
procedure RunPropertySetter;

// Collections: dynamic array of records and of class instances, plus an
// interfaced-class field-inspection exercise.
procedure RunCollections;

implementation

uses
  System.Variants;

constructor TDupCross.Create;
begin
  inherited Create;
  RealFirst  := 4242;
  RealSecond := 8484;
end;

// Local sink. Same-shape virtual call as TestTarget.dpr's GSink so the
// optimiser cannot drop the local values just to keep the frame small.
type
  TLocalSink = class
    procedure Use(const Tag: string; const Vals: array of const); virtual;
  end;

procedure TLocalSink.Use(const Tag: string; const Vals: array of const);
begin
  // intentionally empty; virtual dispatch defeats the optimiser.
end;

var
  GSink: TLocalSink;

constructor TCounter.Create(AStart: Integer);
begin
  inherited Create;
  Value := AStart;
end;

function TCounter.NextValue: Integer;
begin
  Inc(Value);
  Result := Value;
end;

constructor TBase.Create(ATag: Integer);
begin
  inherited Create;
  BaseTag := ATag;
end;

constructor TDerivedA.Create(ATag: Integer);
begin
  inherited Create(ATag);
  BaseTag := ATag * 10;
end;

function TPoint2D.Magnitude: Double;
begin
  Result := Sqrt(X * X + Y * Y);
end;

class operator TPoint2D.Add(const A, B: TPoint2D): TPoint2D;
begin
  Result.X := A.X + B.X;                                   // {BP:OPERATOR_BODY}
  Result.Y := A.Y + B.Y;
  GSink.Use('op-add', [Result.X, Result.Y]);
end;

constructor TBareCounter.Create(AValue: Integer);
begin
  inherited Create;
  FValue := AValue;
end;

procedure TBareCounter.SetValue(AValue: Integer);
begin
  FValue := AValue;                                        // {BP:PROP_SETTER_BODY}
  GSink.Use('prop-setter', [AValue]);
end;

// Lives in an external unit so the indexed augment lookup sees TWO
// entries for "dowork" -- the TestTarget.dpr DoWork (Integer parameter)
// and this one (string parameter). Pre-fix adapter would coin-flip the
// scope on a watch.
procedure DoWork;
var
  Marker: string;
begin
  Marker := 'types-dowork';
  GSink.Use('types-dowork', [Marker]);
end;

class procedure TStaticOps.Run(Tag: Integer);
var
  LocalCount: Integer;
begin
  LocalCount := Tag * 2;
  // No Self in this frame; verify the Variables view does NOT surface
  // a bogus Self from the parent frame walk.
  GSink.Use('static-method', [Tag, LocalCount]);           // {BP:STATIC_METHOD_BODY}
end;

procedure RunStaticClassMethod;
begin
  TStaticOps.Run(42);
end;

procedure RunOperatorOverload;
var
  A, B, C: TPoint2D;
begin
  A.X := 1.0; A.Y := 2.0;
  B.X := 3.0; B.Y := 4.0;
  C := A + B;
  GSink.Use('op-result', [C.X, C.Y]);
end;

procedure RunPropertySetter;
var
  Counter: TBareCounter;
begin
  Counter := TBareCounter.Create(7);
  try
    Counter.Value := 99;            // triggers SetValue body BP
    GSink.Use('prop-after', [Counter.Value]);
  finally
    Counter.Free;
  end;
end;

procedure RunDeepNesting;
var
  OuterTag: Integer;

  procedure Mid;
  var
    MidTag: string;

    procedure Inner;
    var
      InnerTag: Double;
    begin
      InnerTag := 3.14;
      // From Inner the variables view should expose:
      //   own: InnerTag
      //   parent: Mid.MidTag
      //   grandparent: RunDeepNesting.OuterTag
      GSink.Use('inner', [InnerTag, MidTag, OuterTag]);   // {BP:DEEP_NEST_INNER_BODY}
    end;

  begin
    MidTag := 'mid-value';
    Inner;
  end;

begin
  OuterTag := 777;
  Mid;
end;

// ---------------------------------------------------------------------
// The big one: every type family in a single frame so one BP covers a
// large surface area. Out / const / default parameters live on dedicated
// helper procs because Delphi syntax cannot mix them in a single frame
// the way locals can.
// ---------------------------------------------------------------------
procedure HelperOut(out X: Integer; const Tag: string; Multiplier: Integer = 3);
begin
  // `out X` slot is uninitialised on entry; the adapter must surface
  // garbage cleanly, then -- after `X := ...` -- read the assigned
  // value back.
  X := Length(Tag) * Multiplier;
  GSink.Use('helper-out', [X, Tag, Multiplier]);           // {BP:HELPER_OUT_BODY}
end;

procedure RunTypeSampler;
type
  TColor = (Red, Green, Blue);
  TColors = set of TColor;
  TBigEnum = (beA, beB, beC, beD, beE, beF, beG, beH, beI, beJ, beK, beL,
              beM, beN, beO, beP, beQ, beR, beS, beT);
var
  // primitives / aliases not covered earlier
  BB1: ByteBool;
  WB1: WordBool;
  LB1: LongBool;
  SS1: ShortString;
  WS1: WideString;
  G1:  TGUID;

  // refcount + interface
  Cnt: ICounter;        // live interface
  NilCnt: ICounter;     // nil interface

  // method pointer
  MP:    TMethodPtr;
  MPNil: TMethodPtr;
  AP:    TAnonProc;
  APNil: TAnonProc;

  // class reference
  ClsRef: TClassRef;
  NilCls: TClassRef;

  // generic class
  GenList: TList<Integer>;

  // pointer family
  PI:   ^Integer;          // pointer-to-primitive
  RecP: ^TPackedRec;       // pointer-to-record
  UP:   Pointer;           // untyped
  PCh:  PChar;             // pointer-to-char (real string content)

  // records
  PRec: TPackedRec;
  MRec: TManagedRec;
  Pt:   TPoint2D;

  // enums and sets
  Col:  TColor;
  Big:  TBigEnum;
  Cols: TColors;
  EmptyCols: TColors;

  // for out-helper exercise
  OutResult: Integer;

  // an Integer that MUST NOT be misread as varNull (regression guard)
  TrickyOne: Integer;

  // an Integer = 0 -- MUST display as 0, never <empty> (varEmpty edge:
  // 24 zero bytes look like an empty Variant; a 4-byte zero Integer must
  // not be mis-recovered).
  ZeroInt: Integer;
begin
  BB1 := True;
  WB1 := True;
  LB1 := True;
  SS1 := 'short-string-ascii';
  WS1 := 'wide-string-utf16';
  G1  := StringToGUID('{2B6A4F3E-8C1D-4F2B-9A5C-1E7D8F0A3B2C}');

  Cnt    := TCounter.Create(10);
  NilCnt := nil;

  MP    := nil;
  MPNil := nil;
  AP    := procedure(X: Integer) begin GSink.Use('anon', [X]); end;
  APNil := nil;

  ClsRef := TDerivedA;
  NilCls := nil;

  GenList := TList<Integer>.Create;
  GenList.AddRange([10, 20, 30]);

  PRec.A := 1;
  PRec.B := 2;
  PRec.C := 3;
  MRec.Name := 'managed';
  MRec.Tags := [4, 5, 6];
  Pt.X := 1.5; Pt.Y := 2.5;

  PI   := @PRec.B;
  RecP := @PRec;
  UP   := Pointer(@PRec);
  PCh  := PChar('pchar-content');

  Col  := Green;
  Big  := beK;
  Cols := [Red, Blue];
  EmptyCols := [];

  TrickyOne := 1;
  ZeroInt   := 0;

  HelperOut(OutResult, 'hello');

  GSink.Use('types-body', [BB1, WB1, LB1, Ord(Col), Ord(Big), Pt.X, Pt.Y, OutResult, TrickyOne, ZeroInt]);   // {BP:TYPES_BODY}

  // Keep dependent locals live across the BP
  if Cnt.NextValue > 0 then
    GSink.Use('post', [SS1, WS1, MRec.Name, GenList.Count]);
  Cnt := nil;
  FreeAndNil(GenList);
end;

procedure RunCollections;
var
  ArrRec: TArray<TPackedRec>;       // dynamic array of records
  ArrObj: TArray<TBase>;            // dynamic array of class instances
  Cnt:    ICounter;                 // interfaced class -- inspect impl field
begin
  SetLength(ArrRec, 2);
  ArrRec[0].A := 11; ArrRec[0].B := 12; ArrRec[0].C := 13;
  ArrRec[1].A := 21; ArrRec[1].B := 22; ArrRec[1].C := 23;

  SetLength(ArrObj, 2);
  ArrObj[0] := TDerivedA.Create(100);
  ArrObj[1] := TDerivedA.Create(200);

  Cnt := TCounter.Create(55);

  GSink.Use('collections', [ArrRec[0].B, ArrRec[1].B, ArrObj[0].BaseTag, Cnt.NextValue]);   // {BP:COLLECTIONS_BODY}

  ArrObj[0].Free;
  ArrObj[1].Free;
  Cnt := nil;
end;

initialization
  GSink := TLocalSink.Create;

finalization
  GSink.Free;

end.
