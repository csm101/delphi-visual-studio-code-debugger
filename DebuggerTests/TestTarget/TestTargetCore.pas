unit TestTargetCore;
// Subject code for the Win64Debugger integration tests, relocated out of
// TestTarget.dpr's program body so the SAME code compiles BOTH into the
// monolithic TestTarget.exe AND into TestSubject.bpl (BPL scenario parity).
//
// Breakpoint markers: lines containing {BP:<NAME>} are valid BP locations.
//
// Each former Writeln call site is a virtual method call on a global sink
// (TSink.Use). The virtual dispatch is opaque to the compiler, so the passed
// values are materialized and kept live, while producing no output / no window.
//
// RunAllScenarios is the single driver entry (exported) that the BPL host calls
// after LoadPackage; the monolithic TestTarget.dpr calls it directly and then
// runs its own exe-only program-main-block (RSM-only inline-var) scenario.

interface

uses
  System.SysUtils, System.Variants, System.Classes, Winapi.Windows,
  TestTargetCollider, TestTargetTypes, TestTargetEdge, TestTargetEdge2,
  TestTargetFlow, TestTargetReal, TestTargetConflictSink, TestTargetConflict1,
  TestTargetConflict2, TestTargetUsesA, TestTargetUsesB, TestTargetUsesC,
  TestTargetUsesHost;

type
  TSink = class
    procedure Use(const Args: array of const); overload; virtual;
    procedure Use(const V: Variant);          overload; virtual;
  end;

  TPoint3D = record
    X, Y, Z: Double;
  end;

  TSmallRec = record
    A, B: SmallInt;   // 4 bytes total — fits in RAX
  end;

  // Replica of the Debugme.dpr TFoo: a class whose ALL members (fields AND
  // constructor) live under a single `private` section, with no `public` /
  // `published` at all.
  TBareClass = class
  private
    Name:   string;
    Value:  Integer;
    Active: Boolean;
    Pt:     TPoint3D;
    constructor Create(const AName: string; AValue: Integer);
  end;

  TWorkMode  = (wmIdle, wmRunning, wmPaused, wmError);
  TWorkModes = set of TWorkMode;

  // A wide enum + its set, so the set spans more than 8 bytes (member ordinals
  // reach 79 -> 10 bytes). Decoding only the low 8 bytes drops every member
  // above bit 63. `set of AnsiChar` (32 bytes) is the same shape in real code.
  TWideEnum = (we00, we01, we02, we03, we04, we05, we06, we07, we08, we09,
               we10, we11, we12, we13, we14, we15, we16, we17, we18, we19,
               we20, we21, we22, we23, we24, we25, we26, we27, we28, we29,
               we30, we31, we32, we33, we34, we35, we36, we37, we38, we39,
               we40, we41, we42, we43, we44, we45, we46, we47, we48, we49,
               we50, we51, we52, we53, we54, we55, we56, we57, we58, we59,
               we60, we61, we62, we63, we64, we65, we66, we67, we68, we69,
               we70, we71, we72, we73, we74, we75, we76, we77, we78, we79);
  TWideSet = set of TWideEnum;

  // 12-member enum -> a 2-byte set, for a field-backed set property (member 10
  // lives in byte 1, dropped when only byte 0 is read).
  TOpt  = (o0, o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11);
  TOpts = set of TOpt;

  // $M- class wide enough that its trailing fields live BEYOND byte offset
  // 127, exercising the RSM $2C field-offset decode for offsets that do not
  // fit the single-byte `value*2` form.
  TWideFields = class
  private
    FHead:  Integer;                 // offset 8
    FPad:   array[0..29] of Int64;   // offset 16..255
    FTailA: Integer;                 // offset 256
    FTailB: Integer;                 // offset 260
  public
    constructor Create;
  end;

  TConQuestoTiFrego = type Integer;

  // Deliberately NOT {$M+} and NOT a TPersistent descendant — its private/public
  // members are NOT visible via the published TPropInfo table. The debugger must
  // still see them (debug info, NOT RTTI, is the source of truth).
  TStuff = class
  private
    FCount:     Integer;
    FLabel:     string;
    FMode:      TWorkMode;       // enum field — module-local odd typeId
    FPoint:     TPoint3D;        // record field — module-local odd typeId
    function    GetMyLabel:  string;
    function    GetTriple:   TArray<Double>;
    property    PrivCount:   Integer read FCount;
    property    PrivLabel:   string  read GetMyLabel;
  public
    constructor Create(ACount: Integer; const ALabel: string);
    property    PubCount:    Integer         read FCount;
    property    PubMode:     TWorkMode       read FMode;     // enum prop
    property    PubPoint:    TPoint3D        read FPoint;    // record prop
    property    PubTriple:   TArray<Double>  read GetTriple; // dyn-array prop
    function    PubBump:     Integer;
    function    BumpCount:   Integer;
    function    RaiseBoom:   Integer;
  end;

  // A buffer with a guard byte on either side, for the watchpoint-on-a-computed-
  // address fixture. The guards exist to be hit by an off-by-one: writing
  // Data[High(Data)] is correct, writing After is the overrun.
  // Named rather than written inline. This was first done on the theory that an
  // anonymous member type would not resolve -- it made no difference, and the
  // real defect was in the evaluator (a static array was missing from its
  // "indexable" test). Kept because a named type is the ordinary spelling, not
  // because anything here depends on it.
  TDataBpBufferBytes = array[0..7] of Byte;

  TDataBpGuardedBuffer = record
    Before: Byte;
    Data:   TDataBpBufferBytes;
    After:  Byte;
  end;

  // A destructor with a body worth stopping in: it has a field to read, a
  // marker line, and an effect (GDtorRan) observable after it returns.
  TDtorProbe = class
  private
    FTag: Integer;
  public
    constructor Create(ATag: Integer);
    destructor Destroy; override;
  end;

  // Indexed (array) property sampler.
  TIndexedBag = class
  private
    FData: array[0..2] of Integer;
    function GetItem(Index: Integer): Integer;
    function GetCaption: string;
  public
    constructor Create;
    property Item[Index: Integer]: Integer read GetItem;   // indexed array property
    property Caption: string read GetCaption;              // scalar getter property
  end;

  // Event-handler (method-pointer) type.
  TWidgetNotify = procedure(Sender: TObject) of object;

  {$M+}
  TWidget = class
  private
    FName:   string;
    FValue:  Integer;
    FActive: Boolean;
    FPt:     TPoint3D;
    FChild:  TWidget;  // deliberately never assigned -> stays nil
    FBigHandle: UInt64;  // a plain UInt64 must be a leaf (never expandable)
    // Typed sources for the synthetic-call argument test below. They are FIELDS
    // exposed as field-backed properties so an expression can name a value whose
    // type matches the parameter it is passed to -- a literal like 0.25 is typed
    // Double by the evaluator and would say nothing about Single placement.
    FArgS:   Single;
    FArgD:   Double;
    FArgE:   Extended;
    FArgI64: Int64;
    FArgCur: Currency;
    FOnNotify: TWidgetNotify;  // backing field for the OnNotify event handler
    function DoCalcScore:   Integer;     // deliberately NOT named GetScore
    // Blocks for far longer than any automatic-call budget, so a safelisted
    // getter that HANGS can be reproduced deliberately. Nothing in the program
    // reads SlowScore: it exists only for a debugger to try to evaluate.
    function DoSlowScore:   Integer;
    function DoCalcInt64:   Int64;
    function DoCalcCard:    Cardinal;
    function DoCalcBool:    Boolean;
    function DoCalcEnum:    TWorkMode;
    function DoCalcSet:     TWorkModes;
    function DoCalcChar:    WideChar;
    function DoCalcClass:   TObject;
    function DoCalcNative:  NativeUInt;
    function DoCalcSingle:  Single;
    function DoCalcDouble:  Double;
    function DoCalcDate:    TDateTime;
    function DoCalcCurr:    Currency;
    // Real is a Double alias on both architectures; Extended is a genuine
    // 10-byte x87 type on Win32 but aliases Double on Win64, so the pair
    // covers the two ends of the float family that are NOT just Double.
    function DoCalcReal:    Real;
    function DoCalcExt:     Extended;
    function DoCalcUStr:    UnicodeString;
    function DoCalcAStr:    AnsiString;
    function DoCalcWStr:    WideString;
    function DoCalcUTF8:    UTF8String;
    function DoCalcRBS:     RawByteString;
    function DoCalcDynArr:  TArray<Integer>;
    function DoCalcVariant: Variant;
    function DoCalcSmallRec: TSmallRec;
    function DoCalcBigRec:   TPoint3D;
    function DoCalcBoom:    Integer;
    function DoCalcAvBoom:  Integer;
  public
    constructor Create(const AName: string; AValue: Integer);
    procedure Compute(var AResult: Integer);
    function Mult(A, B: Integer): Integer;
    function Sum5(A, B, C, D, E: Integer): Integer;
    function Scale(X: Double): Double;
    // A TDateTime parameter (a Double alias): the debugger must marshal it to
    // an XMM register, which name-only float detection failed to do. Returns the
    // day-of-month so a wrong (0.0) argument gives a distinguishable answer.
    function DayOfDate(const D: TDateTime): Integer;
    // Every argument class Delphi's 32-bit `register` convention treats
    // differently, interleaved with ordinals so a wrong register/stack split
    // shows up. A and C must still reach EAX/EDX -- floats and 8-byte values
    // consume no register slot -- while B, D, E, F and G go on the stack at 8,
    // 4, 12, 8 and 8 bytes. Each contributes a distinct power of two, so any
    // argument landing in the wrong place changes the sum.
    function SumArgs(A: Integer; B: Double; C: Integer; D: Single;
                     E: Extended; F: Int64; G: Currency): Double;
    // Typed sources for the call above, field-backed so naming one costs no
    // synthetic call of its own.
    property ArgS:   Single   read FArgS;
    property ArgD:   Double   read FArgD;
    property ArgE:   Extended read FArgE;
    property ArgI64: Int64    read FArgI64;
    property ArgCur: Currency read FArgCur;
    function Greet(const Who: string): string;
    // Step-into prologue fixture (F19): a METHOD whose Self and three
    // by-register parameters (RCX/RDX/R8/XMM3) only become readable once the
    // prologue has spilled them into their home slots.
    function StepIntoProbe(AInt: Integer; const AStr: string; ADbl: Double): Integer;
    function GetSelf: TWidget;
    function Items(Idx: Integer): Integer;
    function GetSlot(Idx: Integer): Integer;
    property Slot[Idx: Integer]: Integer read GetSlot; default;
  published
    property Name:     string        read FName;
    property OnNotify: TWidgetNotify  read FOnNotify write FOnNotify;
    property Child:    TWidget        read FChild;  // field-backed, nil
    property Value:    Integer       read FValue;
    property Active:   Boolean       read FActive;
    property Score:    Integer       read DoCalcScore;
    property SlowScore: Integer      read DoSlowScore;
    property AsInt64:  Int64         read DoCalcInt64;
    property AsCard:   Cardinal      read DoCalcCard;
    property AsBool:   Boolean       read DoCalcBool;
    property AsEnum:   TWorkMode     read DoCalcEnum;
    property AsSet:    TWorkModes    read DoCalcSet;
    property AsChar:   WideChar      read DoCalcChar;
    property AsClass:  TObject       read DoCalcClass;
    property AsPtr:    NativeUInt    read DoCalcNative;
    property AsSingle: Single        read DoCalcSingle;
    property AsDouble: Double        read DoCalcDouble;
    property AsDate:   TDateTime     read DoCalcDate;
    property AsCurr:   Currency      read DoCalcCurr;
    property AsReal:   Real          read DoCalcReal;
    property AsExt:    Extended      read DoCalcExt;
    property AsUStr:   UnicodeString read DoCalcUStr;
    property AsAStr:   AnsiString    read DoCalcAStr;
    property AsWStr:   WideString    read DoCalcWStr;
    property AsUTF8:   UTF8String    read DoCalcUTF8;
    property AsRBS:    RawByteString read DoCalcRBS;
    property AsDyn:    TArray<Integer> read DoCalcDynArr;
    property AsVar:    Variant       read DoCalcVariant;
    property AsSmall:  TSmallRec     read DoCalcSmallRec;
    property AsBig:    TPoint3D      read DoCalcBigRec;
    property AsBoom:   Integer       read DoCalcBoom;
    property AsAvBoom: Integer       read DoCalcAvBoom;
  end;
  {$M-}

  // Field layout designed to DETECT byte clobbering around 1-byte enum/set fields.
  TEnumPack = class
  private
    FBefore: Integer;     // offset 8
    FGap:    TWorkMode;   // offset 12 (1 byte)
    FMark:   Byte;        // offset 13 -- clobber detector for FGap
    FAfter:  Integer;     // offset 16 -- clobber detector for FGap
    FModes:  TWorkModes;  // offset 20 (set of 4 -> 1 byte)
    FMark2:  Byte;        // offset 21 -- clobber detector for FModes
    FAfter2: Integer;     // offset 24 -- clobber detector for FModes
  public
    constructor Create;
  end;

  // Class method with a nested local procedure (TreeMenu repro).
  TMenuCacheBase = class
  public
    BaseTag: Integer;
    constructor Create;
    function GetBaseScore: Integer;
    // Called on a DERIVED instance by the evaluator tests. The symbol is
    // TMenuCacheBase.*, while the receiver's runtime class is TMenuCache, so
    // resolving a method by the runtime class name alone cannot find it -- the
    // shape of every inherited-method call (TDataSet.FieldByName on a
    // TSomeDataSet, TComponent.FindComponent on a form, ...).
    function BaseEcho(AValue: Integer): Integer;
    function BaseLen(const AText: string): Integer;
    property BaseScore: Integer read GetBaseScore;
  end;

  TMenuCache = class(TMenuCacheBase)
  private
    FLevels: array of Integer;
    function GetLevel(Idx: Integer): Integer;
  public
    Items: TArray<string>;
    constructor Create;
    property Level[Idx: Integer]: Integer read GetLevel;
  end;

  // Format probe: two array properties that differ ONLY in the `default`
  // marker. `Probe['x']` in Pascal means `Probe.ByName['x']`, so the evaluator
  // has to know which property is the default one - and whether TD32/RSM record
  // that at all is exactly what these two let us answer, by comparing the two
  // property records byte for byte.
  TIndexProbe = class
  private
    FBias: Integer;
    function GetByName(const AName: string): Integer;
    function GetPlain(AIdx: Integer): Integer;
    function GetCell(ARow: Integer; const ACol: string): Integer;
  public
    constructor Create;
    property ByName[const AName: string]: Integer read GetByName; default;
    property Plain[AIdx: Integer]: Integer read GetPlain;
    // Two indices, mixed types: exercises `probe.Cell[3, 'x']` -- multi-arg,
    // int + string. A matrix property (IMldoSqlResult-style) is this shape.
    property Cell[ARow: Integer; const ACol: string]: Integer read GetCell;
  end;

  // Default property returning a VARIANT, exactly like TDataSet.FieldValues,
  // which is what `dataset['CODE']` resolves to. The var-out slot holds a
  // TVarData by value; the debugger must DECODE it, not read its first 8 bytes
  // (which showed 258 = the varUString VType word live). GetTag returns a
  // one-char string variant, mirroring the char(1) CODE field.
  TVariantProbe = class
  private
    function GetTag(const AKey: string): Variant;
    function GetNum(AIdx: Integer): Variant;
  public
    property Tag[const AKey: string]: Variant read GetTag; default;
    property Num[AIdx: Integer]: Variant read GetNum;
  end;

  // Field-backed set property: `Options` reads the FOptions field directly (no
  // getter), so the debugger reads the field bytes. A 2-byte set with member 10
  // set must not be truncated to byte 0.
  TThingWithOptSet = class(TPersistent)
  private
    FOptions: TOpts;
  published
    property Options: TOpts read FOptions;
  public
    constructor Create;
  end;

  // A DISTINCT type that is a Variant underneath (`type ... = type Variant`).
  // Its name is NOT "Variant", so decoding must follow the alias to its kind,
  // not match the literal name.
  NullableInteger = type Variant;
  // A distinct UnicodeString alias: indexing it must read WideChars, not narrow
  // AnsiChars (B1). A plain `string` name is collapsed by TD32, so a `type ...`
  // alias is needed to keep the name in the debug info.
  TStrAlias = type UnicodeString;

  // 12 bytes (> 8) so it is returned through the hidden var-out slot, not packed
  // in RAX. The <= 8-byte case comes back in RAX and its field-by-field access
  // is a separate, still-open follow-up.
  TPointRec = record
    X: Integer;
    Y: Integer;
    Z: Integer;
  end;

  // Indexed properties whose return type is, in turn: a Variant ALIAS, a CLASS,
  // and a RECORD. Exercises return-ABI decode driven by the declared type's
  // KIND rather than its name.
  TReturnKindProbe = class
  private
    FChild: TMenuCacheBase;
    function GetNVar(AIdx: Integer): NullableInteger;
    function GetObj(AIdx: Integer): TMenuCacheBase;
    function GetRec(AIdx: Integer): TPointRec;
    function GetModes(AIdx: Integer): TWorkModes;
    function GetWide(AIdx: Integer): TWideSet;
    function GetRec0: TPointRec;
    function GetModes0: TWorkModes;
    function GetWide0: TWideSet;
  public
    constructor Create;
    destructor Destroy; override;
    property NVar[AIdx: Integer]: NullableInteger read GetNVar;
    property Obj[AIdx: Integer]:  TMenuCacheBase  read GetObj;
    property Rec[AIdx: Integer]:  TPointRec       read GetRec;
    property Modes[AIdx: Integer]: TWorkModes     read GetModes;  // <= 8-byte set (RAX)
    property Wide[AIdx: Integer]:  TWideSet        read GetWide;  // > 8-byte set (var-out)
    // NON-indexed getter-backed properties: these take the property-getter
    // resolution path (InvokeGetter / ResolveRsmMethodProp), the C1/C2 sites.
    property PointP:  TPointRec  read GetRec0;
    property SmallSetP: TWorkModes read GetModes0;
    property WideSetP:  TWideSet   read GetWide0;
  end;

  // A class whose DEFAULT property takes TWO indices, so `M[r, c]` (not through
  // an explicit name) has to marshal both. Delphi allows a multi-index default.
  TMatrixProbe = class
  private
    FSeed: Integer;
    function GetItem(ARow, ACol: Integer): Integer;
  public
    constructor Create;
    property Item[ARow, ACol: Integer]: Integer read GetItem; default;
  end;

  // Two classes with the SAME bare name, nested in different outer classes in
  // the SAME unit. Neither the bare name nor the unit name tells them apart:
  // only the VMT address does. Distinct layouts so a wrong pick shows plainly.
  // This is the shape behind the live `dataset.Fields` bug, where the debugger
  // returned the members of System.Classes.TFieldsCache.TFields for a
  // Data.DB.TFields instance.
  TCollideOuterA = class
  public type
    TDup = class
    public
      AlphaA: Integer;   // = 111
      BetaA:  Integer;   // = 222
      constructor Create;
    end;
  end;

  TCollideOuterB = class
  public type
    TDup = class
    public
      // Deliberately MORE fields than TCollideOuterA.TDup so the two same-named
      // records have DIFFERENT instance sizes: the size-disambiguation in
      // GetClassMembers must pick the right one from the bare name + size.
      GammaB: Int64;     // = 999
      DeltaB: Int64;
      EpsilonB: Int64;
      constructor Create;
    end;
  end;

  // Nested class whose bare name TDupCross collides with the top-level
  // TestTargetTypes.TDupCross. Different fields, so a wrong pick shows plainly.
  // Mirrors System.Classes.TFieldsCache.TFields (nested) shadowing
  // Data.DB.TFields (top-level) in the live bug.
  TDupCrossCache = class
  public type
    TDupCross = class
    public
      FakeHits: Int64;   // = 777 -- name/width/offset all differ from the real one
      constructor Create;
    end;
  end;

  TMenuRepro = class
  public
    FOwnerName: string;
    constructor Create(const AOwnerName: string);
    procedure LoadMenu;
  end;

  TSetThreadDescription = function(hThread: THandle; lpThreadDescription: PWideChar): HRESULT; stdcall;

var
  GSink: TSink;
  // Holds a TPkgWidget created inside TestPackage.bpl; kept past UnloadPackage so
  // the debugger can inspect an instance whose class lives in an unloaded module.
  GPkgObj: TObject;
  // Uses-graph collision twin: same name as TestPackage's GUsesGraph (333).
  GUsesGraph: Integer;
  GCounter: Integer;
  // Bumped by TDtorProbe.Destroy. A breakpoint in a DESTRUCTOR body is the one
  // frame kind docs/TEST_CATALOG.md section C claimed and nothing tested; this
  // counter is what makes "the destructor body actually ran" observable from
  // outside, rather than only "we stopped somewhere called Destroy".
  GDtorRan: Integer;
  // Per-thread stepping isolation fixture (see RunPerThreadStepFixture): two
  // worker threads spin incrementing their OWN counter until GStepIsoStop is set.
  // While the debugger single-steps ONE of them the other must stay frozen, so
  // its counter must not move across the step.
  GStepIsoStop: Boolean;
  GStepIsoB:    Int64;
  GStepIsoC:    Int64;
  // Hardware-watchpoint fixture (see RunDataBpStepFixture). Integer, so the
  // cell is 4 bytes and naturally 4-aligned -- the alignment a debug register
  // requires, and the reason not to make it a Boolean or an Int64.
  GDataBpWatched: Integer;
  GDataBpOther:   Integer;
  // Buffer-overrun fixture (see RunDataBpBufferFixture). A record, not three
  // separate globals: only a record guarantees that Before and After really do
  // sit immediately either side of Data, which is the whole point -- the linker
  // is free to order globals however it likes. Bytes, so every interesting
  // address is odd as often as not, which is exactly what used to be refused
  // for "not aligned to 8 bytes".
  GDataBpBuffer: TDataBpGuardedBuffer;
  // Per-thread watchpoint replication fixture (see RunDataBpThreadFixture).
  // GDataBpThreadWatched is written by a worker thread ALIVE before the
  // watchpoint is armed (proves replication onto every live thread);
  // GDataBpThreadLate is written by a worker thread created AFTER the arm
  // (proves HandleCreateThread re-arms it). The main thread never touches
  // either -- a stop naming the main thread would mean the feature is broken,
  // not working.
  GDataBpThreadGo:      Boolean;
  GDataBpThreadWatched: Integer;
  GDataBpThreadLate:    Integer;

  // What the target itself saw after a deliberate API failure. The debugger
  // reads the same value out of the thread's TEB from outside; the test
  // compares the two. Ground truth has to come from inside the target because
  // a WOW64 process has two TEBs and only its own code knows which one it
  // writes to.
  GLastErrorSeen: Cardinal;

procedure ComputeNested(var X: Integer);
procedure RunAllScenarios;

implementation

procedure TSink.Use(const Args: array of const);
begin
  // intentionally empty: only here to anchor breakpoints and to force the
  // compiler to keep the arguments live across the call site.
end;

procedure TSink.Use(const V: Variant);
begin
  // see above; dedicated Variant overload mirrors Writeln(V) keep-alive semantics.
end;

constructor TWidget.Create(const AName: string; AValue: Integer);
begin
  inherited Create;
  FName   := AName;   // {BP:CTOR_BODY}
  FValue  := AValue;
  FActive := True;
  FPt.X   := 1.5;
  FPt.Y   := 2.5;
  FPt.Z   := 3.5;
  FBigHandle := $00ABCDEF12345678;  // UInt64 leaf: must show inline, never expand
  // Powers of two, so SumArgs' weighted total is exact in binary and any
  // argument that lands in the wrong register or stack slot changes it.
  FArgS   := 0.25;
  FArgD   := 0.5;
  FArgE   := 0.125;
  FArgI64 := 4;
  FArgCur := 2.0;
end;

procedure TWidget.Compute(var AResult: Integer);
var
  Factor: Integer;
  FName:  Integer;   // deliberately shadows the field of the same name on TWidget
begin
  Factor  := FValue * 2;
  FName   := 7;
  AResult := Factor + 10;  // {BP:COMPUTE_BODY}
end;

function TWidget.DoCalcScore: Integer;     begin Result := FValue * 2;       end; // 84
function TWidget.DoSlowScore: Integer;     begin Sleep(5000); Result := FValue * 3; end; // never returns within a budget
function TWidget.DoCalcInt64: Int64;       begin Result := Int64($1122334455667788); end;
function TWidget.DoCalcCard:  Cardinal;    begin Result := Cardinal($DEADBEEF); end;
function TWidget.DoCalcBool:  Boolean;     begin Result := True;             end;
function TWidget.DoCalcEnum:  TWorkMode;   begin Result := wmPaused;         end;
function TWidget.DoCalcSet:   TWorkModes;  begin Result := [wmRunning, wmPaused]; end;
function TWidget.DoCalcChar:  WideChar;    begin Result := 'Z';              end;
function TWidget.DoCalcClass: TObject;     begin Result := Self;             end;
function TWidget.DoCalcNative: NativeUInt; begin Result := NativeUInt(FValue); end;
function TWidget.DoCalcSingle: Single;     begin Result := 1.5;              end;
function TWidget.DoCalcDouble: Double;     begin Result := 3.25;             end;
function TWidget.DoCalcDate:   TDateTime;  begin Result := 45000.5;          end;
function TWidget.DoCalcCurr:   Currency;   begin Result := 19.95;            end;
// The weights are chosen so each argument contributes a DISTINCT power of two:
//
//   A=1     * 1   =  1      E=0.125 * 128 =  16
//   B=0.5   * 4   =  2      F=4     * 8   =  32
//   C=2     * 2   =  4      G=2.0   * 32  =  64
//   D=0.25  * 32  =  8                      ----
//                                    total = 127
//
// So a wrong total names the culprit: the deficit is the sum of the arguments
// that failed to arrive, and no two subsets share a sum.
function TWidget.SumArgs(A: Integer; B: Double; C: Integer; D: Single;
  E: Extended; F: Int64; G: Currency): Double;
begin
  Result := A * 1 + B * 4 + C * 2 + D * 32 + E * 128 + F * 8 + G * 32;
end;

function TWidget.DoCalcReal:   Real;       begin Result := 6.75;             end;
function TWidget.DoCalcExt:    Extended;   begin Result := 2.5;              end;
function TWidget.DoCalcUStr:   UnicodeString; begin Result := 'u_' + FName;  end;
function TWidget.DoCalcAStr:   AnsiString;    begin Result := AnsiString('a_' + FName); end;
function TWidget.DoCalcWStr:   WideString;    begin Result := WideString('w_' + FName); end;
function TWidget.DoCalcUTF8:   UTF8String;    begin Result := UTF8String('8_' + FName); end;
function TWidget.DoCalcRBS:    RawByteString; begin Result := RawByteString('r_' + FName); end;
function TWidget.DoCalcDynArr: TArray<Integer>; begin Result := [10, 20, 30]; end;
function TWidget.DoCalcVariant: Variant;       begin Result := FValue + 100; end; // 142
function TWidget.DoCalcSmallRec: TSmallRec;
begin
  Result.A := 7;
  Result.B := 11;
end;
function TWidget.DoCalcBigRec: TPoint3D;
begin
  Result.X := 1.5;
  Result.Y := 2.5;
  Result.Z := 3.5;
end;

// Callee of the step-into prologue fixture. The first statement is the FIRST
// source line of the method, so a step-into that reports at the function's entry
// address (before the prologue spilled RCX/RDX/R8/XMM3) still claims to be here
// while Self and every parameter still hold the CALLER's frame bytes.
function TWidget.StepIntoProbe(AInt: Integer; const AStr: string; ADbl: Double): Integer;
begin                                       // {BP:STEPIN_PROBE_BEGIN}
  Result := AInt + FValue;                  // {BP:STEPIN_PROBE_BODY}
  GSink.Use([AStr, ADbl, Result]);
end;

function TWidget.Mult(A, B: Integer): Integer;
begin
  Result := A * B + FValue;     // (3*5)+42 = 57
end;

function TWidget.Sum5(A, B, C, D, E: Integer): Integer;
begin
  Result := A * 10000 + B * 1000 + C * 100 + D * 10 + E;
end;

function TWidget.DoCalcBoom: Integer;
begin
  raise Exception.Create('boom-from-getter');
  Result := 0;  // unreachable; keeps the function-result contract explicit
end;

function TWidget.DoCalcAvBoom: Integer;
begin
  PInteger(nil)^ := 1;  // deliberate access violation
  Result := 0;
end;

function TWidget.Scale(X: Double): Double;
begin
  Result := X * 2 + 0.5;        // 1.5*2 + 0.5 = 3.5
end;

function TWidget.DayOfDate(const D: TDateTime): Integer;
begin
  // Trunc(D) is the date part; the fractional part is the time. A wrongly
  // marshalled argument (0.0) yields Trunc(0) = 0, distinct from any real day.
  Result := Round(Frac(D) * 1000) + Trunc(D);
end;

function TWidget.Greet(const Who: string): string;
begin
  Result := 'hi_' + Who + '!_' + FName;  // 'hi_world!_hello'
end;

function TWidget.GetSelf: TWidget;
begin
  Result := Self;
end;

function TWidget.Items(Idx: Integer): Integer;
begin
  Result := FValue + Idx;  // 42 + 3 = 45
end;

function TWidget.GetSlot(Idx: Integer): Integer;
begin
  Result := FValue * 10 + Idx;  // 42*10 + 3 = 423
end;

constructor TBareClass.Create(const AName: string; AValue: Integer);
begin
  inherited Create;
  Name   := AName;
  Value  := AValue;
  Active := True;
  Pt.X   := 1.5;
  Pt.Y   := 2.5;
  Pt.Z   := 3.5;
end;

constructor TStuff.Create(ACount: Integer; const ALabel: string);
begin
  inherited Create;
  FCount   := ACount;
  FLabel   := ALabel;
  FMode    := wmPaused;
  FPoint.X := 1.5;
  FPoint.Y := 2.5;
  FPoint.Z := 3.5;
  Inc(FCount, 0);   // {BP:STUFF_CTOR_END}
  if Length(PrivLabel) < 0 then ;
  if Length(PubTriple) < 0 then ;
end;

function TStuff.GetMyLabel: string;
begin
  Result := '<' + FLabel + '>';
end;

function TStuff.GetTriple: TArray<Double>;
begin
  Result := [10.5, 20.5, 30.5];
end;

function TStuff.PubBump: Integer;
begin
  Result := FCount + 1;  // {BP:STUFF_PUBBUMP}
end;

function TStuff.BumpCount: Integer;
begin
  Inc(FCount);
  Result := FCount;
end;

function TStuff.RaiseBoom: Integer;
begin
  raise Exception.Create('boom-from-watch');
  Result := 0;  // unreachable; keeps the function-result contract explicit
end;

procedure ComputeNested(var X: Integer);
var
  D1: TDateTime;
  // Extended is 10 bytes of x87 on Win32 and an alias of Double on Win64, so
  // this local reads back through two different decoders. Reading only 8 of the
  // 10 bytes yields the mantissa reinterpreted as a Double -- a wildly wrong
  // number rather than a rounded one, which is what makes it worth pinning.
  Ext1: Extended;
  // The pre-8087 Borland software float: 6 bytes, exponent in the LOWEST byte,
  // biased by 129. Nothing about it resembles an IEEE double, so it needs its
  // own decoder and is worth one local to keep that decoder honest.
  R48: Real48;

  procedure Inner;
  var
    S: string;
  begin
    S := 'inner_' + IntToStr(X);  // {BP:INNER_BODY}
    GSink.Use([S]);
  end;

begin
  var D := Now;
  D1 := D;
  Ext1 := 2.75;
  R48  := 3.5;
  Inc(X);    // {BP:NESTED_INC}
  // Keeps the Ext1/R48 stores live past the breakpoint above, so neither can be
  // read back as zero merely because nothing ever consumed them.
  if (Ext1 < 0) or (R48 < 0) then
    GSink.Use(['unreachable']);
  Inner;     // {BP:NESTED_CALL_INNER}
end;

procedure RunAliasLocalTest;
var
  Aliased: TConQuestoTiFrego;
begin
  Aliased := 42;
  GSink.Use([Aliased]); // {BP:ALIAS_LOCAL}
end;

// Anonymous-method closure capture. Clo captures CapInt + CapStr, so the compiler
// moves them into a heap $ActRec object that Clo (a refcounted interface) points
// to. In its OWN dedicated proc: capturing relocates the enclosing frame, which
// would break a shared proc's other local tests. Exercises closure inspection:
//  * CLOSURE_EXPAND: Clo is a live closure value -- expanding it must reveal the
//    captured fields (CapInt=42, CapStr='captured') from debug info (the $ActRec
//    class members), NOT runtime RTTI ($ActRec has no runtime field table).
//  * CLOSURE_BODY: stopped INSIDE the anon method body (future increment B).
procedure RunClosureSampler;
type
  TCloProc = reference to procedure(X: Integer);
var
  CapInt: Integer;
  CapStr: string;
  Clo:    TCloProc;
begin
  CapInt := 42;
  CapStr := 'captured';
  Clo := procedure(X: Integer)
         begin
           GSink.Use([X + CapInt, CapStr]);   // {BP:CLOSURE_BODY}
         end;
  GSink.Use([CapInt, CapStr]);   // {BP:CLOSURE_EXPAND} -- Clo is a live closure here
  Clo(7);
end;

// Anon-method PARAMETER coverage. Each closure captures Cap (so it is a real
// $ActRec with a recoverable Self), takes differently-typed parameters, and is
// invoked so its body runs. Stopping inside each body, the debugger must surface
// the anon method's own declared params (arg1..argN) from the method signature +
// Win64 ABI home slots. Own dedicated proc: a capturing closure relocates its host
// proc's frame, so this must not share with locals-under-test procs. Bodies are
// multi-line so each {BP} binds to the body line, not the construction site.
// Marker-free helper class for the object-parameter case. NOT TWidget: TWidget's
// constructor carries the CTOR_BODY marker, so creating one here would steal a
// ctor breakpoint from Test_ClassCtor_ParamsVisible.
type
  TParamObj = class
  public
    Name: string;
    constructor Create(const AName: string);
  end;

constructor TParamObj.Create(const AName: string);
begin
  Name := AName;
end;

procedure RunClosureParamSampler;
type
  TTwo  = reference to procedure(A: Integer; B: Integer);
  TStr  = reference to procedure(S: string);
  TDbl  = reference to procedure(D: Double);
  TWide = reference to procedure(Q: Int64);
  TBool = reference to procedure(F: Boolean);
  TObj  = reference to procedure(W: TParamObj);
  TMix  = reference to procedure(N: Integer; S: string; D: Double; F: Boolean);
  TSix  = reference to procedure(A, B, C, D, E, F: Integer);
var
  Cap:  Integer;
  Wg:   TParamObj;
  Two:  TTwo;
  Str:  TStr;
  Dbl:  TDbl;
  Wide: TWide;
  Bl:   TBool;
  Ob:   TObj;
  Mix:  TMix;
  Six:  TSix;
begin
  Cap := 100;
  Two := procedure(A: Integer; B: Integer)
         begin
           GSink.Use([A, B, Cap]);   // {BP:CLOP_TWO}
         end;
  Str := procedure(S: string)
         begin
           GSink.Use([S, Cap]);      // {BP:CLOP_STR}
         end;
  Dbl := procedure(D: Double)
         begin
           GSink.Use([D, Cap]);      // {BP:CLOP_DBL}
         end;
  Wide := procedure(Q: Int64)
          begin
            GSink.Use([Q, Cap]);     // {BP:CLOP_WIDE}
          end;
  Bl := procedure(F: Boolean)
        begin
          GSink.Use([F, Cap]);       // {BP:CLOP_BOOL}
        end;
  Ob := procedure(W: TParamObj)
        begin
          GSink.Use([W.Name, Cap]);  // {BP:CLOP_OBJ}
        end;
  Mix := procedure(N: Integer; S: string; D: Double; F: Boolean)
         begin
           GSink.Use([N, S, D, F, Cap]);   // {BP:CLOP_MIX}
         end;
  Six := procedure(A, B, C, D, E, F: Integer)
         begin
           GSink.Use([A, B, C, D, E, F, Cap]);   // {BP:CLOP_SIX}
         end;
  Wg := TParamObj.Create('wparam');
  Two(11, 22);
  Str('hello-param');
  Dbl(3.5);
  Wide(9876543210);
  Bl(True);
  Ob(Wg);
  Mix(7, 'mixed', 2.5, True);
  Six(1, 2, 3, 4, 5, 6);
  Wg.Free;
end;

// Two-level nested procedure (Inner in Middle in Outer) -- mirrors SampleApp's
// FilterTranslations.ParseLiteralDate (nested in ParseDate in GetSQL). The
// innermost body reads its OWN local AND locals from both enclosing scopes, so it
// exercises nested-proc local resolution at depth 2 (F11).
procedure RunDeepNestedTest;
var
  OuterVal: Integer;

  procedure MiddleLevel;
  var
    MiddleStr: string;

    procedure InnerLevel;
    var
      InnerVal: Integer;
    begin
      InnerVal := OuterVal + Length(MiddleStr);
      GSink.Use([InnerVal, OuterVal, Length(MiddleStr)]);  // {BP:DEEP_NESTED_BODY}
    end;

  begin
    MiddleStr := 'middle';
    InnerLevel;
  end;

begin
  OuterVal := 314;
  MiddleLevel;
end;

// Same 2-level nesting, but the innermost body RAISES, so the F11 exception-stop
// hypothesis can be tested: does get_locals resolve a nested proc's locals when the
// stop is a first-chance exception (as in SampleApp's ParseLiteralDate) rather than a
// breakpoint? Gated by a switch so it does not perturb other scenarios.
procedure RunDeepNestedRaise;
var
  RnOuter: Integer;

  procedure RnMiddle;
  var
    RnMid: string;

    procedure RnInner;
    var
      RnInnerVal: Integer;
    begin
      RnInnerVal := RnOuter + Length(RnMid);
      GSink.Use([RnInnerVal]);
      raise Exception.Create('deep nested raise');  // {BP:DEEP_NESTED_RAISE}
    end;

  begin
    RnMid := 'middle';
    RnInner;
  end;

begin
  RnOuter := 271;
  try
    RnMiddle;
  except
    // Swallowed: the debugger sees the FIRST-CHANCE raise inside InnerLevel; the
    // app itself handles it so the process continues normally afterwards.
  end;
end;

// Free functions for the speculative-invoke guard (F1): a parameterless one may
// be auto-called by a bare identifier; one taking a parameter must not.
function GetFortyTwo: Integer;
begin
  Result := 42;
end;

function TripleValue(X: Integer): Integer;
begin
  Result := X * 3;
end;

procedure RunEvalTests;
var
  Caption: string;
  Scores:  TArray<Integer>;
  Mode:    TWorkMode;
  Modes:   TWorkModes;
  W:       TWidget;   // portable object receivers for the eval/property/method tests:
  S:       TStuff;    // present as NAMED-proc locals so TD32 resolves them WITHOUT .rsm
  EvalDate: TDateTime;   // float-argument marshalling fixture (D1)
  CapAlias: TStrAlias;   // string-alias indexing fixture (B1)
  NVarLocal: NullableInteger;  // Variant-alias local formatting fixture (B2)
  IntStore:  Integer;    // byRef-Variant target (A3)
  ByRefVar:  Variant;
begin
  Caption := 'Hello';
  Scores  := TArray<Integer>.Create(10, 20, 30);
  Mode    := wmRunning;
  Modes   := [wmRunning, wmPaused];
  W := TWidget.Create('hello', 42);   // same canonical values the .dpr main block used
  S := TStuff.Create(7, 'tag');
  EvalDate := 45.678;                  // DayOfDate -> Round(0.678*1000)+45 = 723
  CapAlias  := 'World';                // CapAlias[2] -> 'o' (wide)
  NVarLocal := 1234;                   // must decode to 1234, not the VType word 3
  IntStore  := 12345;                  // byRef Variant: must deref to 12345
  TVarData(ByRefVar).VType     := varInteger or varByRef;
  TVarData(ByRefVar).VPointer  := @IntStore;
  GSink.Use([Caption, W.Name, S.PubCount, EvalDate, CapAlias, NVarLocal, IntStore, ByRefVar]);  // {BP:EVAL_BODY}
  GSink.Use([GetFortyTwo, TripleValue(2)]);   // keep the free functions linked
  S.Free;
  W.Free;
end;

// Fixtures for the expression-evaluator semantics: string comparison, Delphi
// operator precedence and the compiler intrinsics. Deliberately a procedure of
// its own rather than more locals in RunEvalTests -- several tests assert the
// exact local set of that frame, and this one exists to be added to.
procedure RunExprSemanticsTests;
var
  Greeting:     string;
  GreetingCopy: string;      // the same characters in a DIFFERENT allocation
  Blank:        string;
  Narrow:       AnsiString;  // the other string family, its own header layout
  Initial:      Char;
  Flags:        Integer;
  Mask:         Integer;
  Present:      TWidget;
  Absent:       TWidget;
begin
  Greeting := 'Hello';
  // Built at run time so it cannot share the literal's storage: the whole point
  // of the comparison tests is that two equal strings live at two addresses.
  GreetingCopy := Copy('xHello', 2, 5);
  Blank        := '';
  Narrow       := 'Hello';
  Initial      := 'H';
  Flags        := $0F;
  Mask         := $F0;    // Flags and Mask = 0 -- true only with Delphi precedence
  Present      := TWidget.Create('present', 1);
  Absent       := nil;
  try
    GSink.Use([Greeting, GreetingCopy, Blank, string(Narrow), Initial, Flags, Mask, Absent = nil]);  // {BP:EXPR_SEMANTICS}
  finally
    Present.Free;
  end;
end;

// The ORACLE for expression semantics.
//
// Every Ora* local below is a Boolean that DCC64 computed from the expression
// written beside it. The test asks the debugger to evaluate that same source
// text and asserts the two agree. The expected value is therefore the Delphi
// compiler's, never a number someone typed into an assertion -- which is
// precisely how `S = 'abc'` and `Flags and MASK = 0` stayed wrong through a
// thousand passing tests: the evaluator and the assertion were written from the
// same misunderstanding of the language, agreed with each other, and proved
// nothing about Delphi.
//
// Add a form here rather than an `Assert.AreEqual` somewhere: one line in this
// procedure and one row in the test's table, and the compiler owns the answer.
procedure RunExprOracle;
var
  Flags, Mask, Small:            Integer;
  Greeting, GreetingCopy, Blank: string;
  Narrow:                        AnsiString;
  Initial:                       Char;
  Mode:                          TWorkMode;
  Modes:                         TWorkModes;
  // Bitwise / boolean against a comparison -- the precedence that was inverted.
  Ora01, Ora02, Ora03, Ora04, Ora05, Ora06, Ora07, Ora08, Ora09: Boolean;
  // Integer operators no test had ever evaluated.
  Ora10, Ora11, Ora12, Ora13, Ora14, Ora15, Ora16, Ora17: Boolean;
  // Relational operators, likewise.
  Ora18, Ora19, Ora20, Ora21, Ora22: Boolean;
  // Strings, where the comparison used to be on the pointer.
  Ora23, Ora24, Ora25, Ora26, Ora27, Ora28, Ora29, Ora30, Ora31, Ora32: Boolean;
  // Enum and set.
  Ora33, Ora34: Boolean;
  // Forms the catalogue claimed were covered and were not: string concat, nil
  // comparison, numeric casts, `as`, and genuinely MIXED int/float arithmetic.
  Ora35, Ora36, Ora37, Ora38, Ora39, Ora40, Ora41, Ora42, Ora43: Boolean;
  Present, Absent: TWidget;
begin
  Flags := $0F;
  Mask  := $F0;
  Small := 3;
  Greeting     := 'Hello';
  GreetingCopy := Copy('xHello', 2, 5);   // same text, its own allocation
  Blank        := '';
  Narrow       := 'Hello';
  Initial      := 'H';
  Mode         := wmRunning;
  Modes        := [wmRunning, wmPaused];

  Ora01 := Flags and Mask = 0;
  Ora02 := Flags and Mask <> 0;
  Ora03 := Flags and $0F = $0F;
  Ora04 := Flags or Mask = 255;
  Ora05 := Flags xor Mask = 255;
  Ora06 := Flags or 0 and 0 = 15;
  Ora07 := not (Flags = 15);
  Ora08 := (Flags > 1) and (Mask > 1);
  Ora09 := (Flags > 99) or (Mask > 1);

  Ora10 := Flags shl 4 = 240;
  Ora11 := Mask shr 4 = 15;
  Ora12 := Flags div 4 = 3;
  Ora13 := Flags mod 4 = 3;
  Ora14 := Flags / 2 = 7.5;
  Ora15 := -Flags = 0 - 15;
  Ora16 := 1 + 2 * 3 = 7;
  Ora17 := (1 + 2) * 3 = 9;

  Ora18 := Small <> Flags;
  Ora19 := Small < Flags;
  Ora20 := Small <= Flags;
  Ora21 := Flags > Small;
  Ora22 := Flags >= Small;

  Ora23 := Greeting = 'Hello';
  Ora24 := Greeting = 'Nope';
  Ora25 := Greeting <> 'Nope';
  Ora26 := Greeting = GreetingCopy;
  Ora27 := Greeting < 'Z';
  Ora28 := Greeting >= 'Hello';
  Ora29 := Narrow = 'Hello';
  Ora30 := Blank = '';
  Ora31 := Initial = 'H';
  Ora32 := Initial = 'h';

  Ora33 := Mode = wmRunning;
  Ora34 := wmRunning in Modes;

  Present := TWidget.Create('present', 1);
  Absent  := nil;
  try
    Ora35 := Greeting + '!' = 'Hello!';
    Ora36 := Blank + Greeting = Greeting;   // concat where one side is a nil handle
    Ora37 := Absent = nil;
    Ora38 := Present <> nil;
    Ora39 := Integer(Initial) = 72;
    Ora40 := Flags * 1.0 = 15.0;            // int operand, float operand
    Ora41 := Flags + 1.5 = 16.5;
    Ora42 := (Present as TWidget).FValue = 1;
    Ora43 := TObject(Present) <> nil;

    GSink.Use([Ora01, Ora02, Ora03, Ora04, Ora05, Ora06, Ora07, Ora08, Ora09, Ora10, Ora11, Ora12]);
    GSink.Use([Ora13, Ora14, Ora15, Ora16, Ora17, Ora18, Ora19, Ora20, Ora21, Ora22, Ora23, Ora24]);
    GSink.Use([Ora25, Ora26, Ora27, Ora28, Ora29, Ora30, Ora31, Ora32, Ora33, Ora34, Ora35, Ora36]);
    GSink.Use([Ora37, Ora38, Ora39, Ora40, Ora41, Ora42, Ora43]);  // {BP:EXPR_ORACLE}
  finally
    Present.Free;
  end;
end;

// One local of every PRIMITIVE type, for the "local variable type display"
// claims in docs/TEST_CATALOG.md section A. Those rows were ticked for years with no
// test behind them, and no fixture even declared a Cardinal, ShortInt, AnsiChar
// or Currency local for one to read.
//
// Values are chosen to be self-evidencing: negative where the type is signed
// (a lost sign shows up), above the signed maximum where it is unsigned (a
// signed read wraps to a negative), and never zero -- a zero byte is exactly
// what makes an over-wide or mis-sized read look correct by accident.
procedure RunPrimitiveDisplaySampler;
var
  VInteger:  Integer;
  VLongInt:  LongInt;
  VCardinal: Cardinal;
  VLongWord: LongWord;
  VByte:     Byte;
  VShortInt: ShortInt;
  VWord:     Word;
  VSmallInt: SmallInt;
  VInt64:    Int64;
  VUInt64:   UInt64;
  VSingle:   Single;
  VDouble:   Double;
  VCurrency: Currency;
  VBoolean:  Boolean;
  VAnsiChar: AnsiChar;
  VWideChar: Char;
  VAnsiStr:  AnsiString;
  VUniStr:   UnicodeString;
begin
  VInteger  := -123456789;
  VLongInt  := 987654321;
  VCardinal := 4000000000;              // above MaxInt: a signed read goes negative
  VLongWord := $C0000000;
  VByte     := 234;
  VShortInt := -77;
  VWord     := 60001;                   // above MaxSmallInt, same reason
  VSmallInt := -30001;
  VInt64    := -1234567890123456789;
  VUInt64   := $F000000000000000;       // above MaxInt64
  VSingle   := 1.5;
  VDouble   := -2.25;
  VCurrency := 12.34;
  VBoolean  := True;
  VAnsiChar := 'A';
  VWideChar := 'Z';
  VAnsiStr  := 'ansi-content';
  VUniStr   := 'unicode-content';
  GSink.Use([VInteger, VLongInt, VCardinal, VLongWord, VByte, VShortInt, VWord, VSmallInt, VInt64]);
  GSink.Use([VSingle, VDouble, VCurrency, VBoolean, VWideChar, string(VAnsiStr), VUniStr]);  // {BP:PRIMITIVE_DISPLAY}
end;

{ TDtorProbe }

constructor TDtorProbe.Create(ATag: Integer);
begin
  inherited Create;
  FTag := ATag;
end;

destructor TDtorProbe.Destroy;
begin
  Inc(GDtorRan);
  GSink.Use([FTag]);   // {BP:DTOR_BODY}
  inherited;
end;

procedure RunDestructorProbe;
var
  Probe: TDtorProbe;
begin
  Probe := TDtorProbe.Create(4242);
  Probe.Free;                       // runs Destroy, where the marker sits
  GSink.Use([GDtorRan]);
end;

constructor TIndexedBag.Create;
begin
  inherited Create;
  FData[0] := 10;
  FData[1] := 20;
  FData[2] := 30;
end;

constructor TWideFields.Create;
begin
  inherited Create;
  FHead  := 11;
  FTailA := 4242;   // at offset 256 -- decoder must not truncate the offset
  FTailB := 8484;   // at offset 260
end;

procedure RunWideFieldsProbe;
var
  WF: TWideFields;
begin
  WF := TWideFields.Create;
  try
    GSink.Use([WF.FHead, WF.FTailA, WF.FTailB]);  // {BP:WIDE_FIELDS_BODY}
  finally
    WF.Free;
  end;
end;

procedure RunDynArrayDisplayProbe;
var
  EmptyDyn: TArray<Integer>;
  FullDyn:  TArray<Integer>;
begin
  FullDyn := [10, 20, 30];
  GSink.Use([Length(EmptyDyn), Length(FullDyn)]);  // {BP:DYNARR_DISPLAY_BODY}
end;

procedure RunGotoProbe;
var
  A, B: Integer;
begin
  A := 1;            // runs before the stop
  A := 2;            // {BP:GOTO_START} stop here (A=1); this line is skipped
  B := A;            // {BP:GOTO_LAND}  jump target -- A must still be 1
  GSink.Use([A, B]);
end;

constructor TEnumPack.Create;
begin
  inherited Create;
  FBefore := 111;
  FGap    := wmRunning;
  FMark   := 77;
  FAfter  := 999;
  FModes  := [wmIdle];
  FMark2  := 88;
  FAfter2 := 777;
end;

procedure RunEnumPackProbe;
var
  EP: TEnumPack;
begin
  EP := TEnumPack.Create;
  try
    GSink.Use([EP.FBefore, Ord(EP.FGap), EP.FMark, EP.FAfter]); // {BP:ENUM_PACK_BODY}
    GSink.Use([EP.FMark, EP.FAfter, Byte(EP.FModes), EP.FMark2, EP.FAfter2]);
  finally
    EP.Free;
  end;
end;

procedure RunBigVarArrayProbe;
var
  Big: Variant;
begin
  Big := VarArrayCreate([0, 1499], varInteger);
  Big[0]    := 5;
  Big[1499] := 6;
  GSink.Use(Big);  // {BP:BIG_VARARRAY_BODY}
end;

// Fixture for the dynamic-array expansion cap. More elements than the 1024 the
// expander is willing to list, so there is something for the "showing first N
// of M" trailer to say -- without it, 1024 of 1500 looked exactly like all of
// an array of 1024.
procedure RunBigDynArrayProbe;
var
  Big: TArray<Integer>;
begin
  SetLength(Big, 1500);
  Big[0]    := 5;
  Big[1499] := 6;
  GSink.Use([Length(Big), Big[0], Big[1499]]);  // {BP:BIG_DYNARRAY_BODY}
end;

procedure RunOdsProbe;
begin
  OutputDebugStringA('ods-ansi-clean');
  GSink.Use(['ods-done']);
end;

function TIndexedBag.GetItem(Index: Integer): Integer;
begin
  Result := FData[Index];
end;

function TIndexedBag.GetCaption: string;
begin
  Result := 'bag';
end;

procedure RunStepManagedClear;
var
  Arr: TArray<string>;
  N:   Integer;
begin
  Arr := ['x', 'y', 'z'];   // {BP:STEP_MGCLEAR_START}
  Arr := nil;               // managed clear -- step over THIS line
  N   := 7;                 // {BP:STEP_MGCLEAR_END}
  GSink.Use([N, Length(Arr)]);
end;

procedure NoArgStepA; begin GSink.Use(['sa']); end;
procedure NoArgStepB; begin GSink.Use(['sb']); end;
procedure NoArgStepC; begin GSink.Use(['sc']); end;

procedure RunStepConsecutiveCalls;
begin
  NoArgStepA;            // {BP:STEP_CALLS_1}
  NoArgStepB;            // {BP:STEP_CALLS_2}  step-over from _1 must land here
  NoArgStepC;            // {BP:STEP_CALLS_3}
  GSink.Use(['calls']);  // {BP:STEP_CALLS_END}
end;

// Step-over stack-argument fixture. On x86 the first three parameters travel in
// EAX/EDX/ECX and the FOURTH is pushed on the stack -- so at the moment of the
// CALL it sits immediately above the return address. Reading that return address
// eight bytes wide therefore splices this value into its high half, which is
// exactly the defect this fixture pins (observed in the field as a run-to-return
// breakpoint planted at $5196C430B5AA25BC).
//
// The existing STEPIN_CALLSITE fixture could not catch it: its stack argument is
// the Double 2.5, whose low 4 bytes are ZERO, so the over-wide read happened to
// produce the correct address. The marker value here is chosen to have every
// byte non-zero for that reason.
function StepOverStackArgProbe(A, B, C, D: Integer): Integer;
begin
  Result := A + B + C + (D and $FF);
end;

procedure RunStepOverStackArg;
var
  R: Integer;
begin
  R := StepOverStackArgProbe(1, 2, 3, Integer($5EEDBEEF));  // {BP:STEPOVER_STACKARG}
  GSink.Use([R]);                                           // {BP:STEPOVER_STACKARG_NEXT}
end;

// Step-into prologue fixture (F19). Stopping at STEPIN_CALLSITE and stepping
// into TWidget.StepIntoProbe must report Self and the three by-register
// parameters with their PASSED values, not the caller's leftover frame bytes.
// The owner's field values are deliberately unlike any other fixture's, so a
// stale read cannot coincidentally look right.
procedure RunStepIntoPrologue;
var
  W: TWidget;
  R: Integer;
begin
  W := TWidget.Create('stepin-owner', 4242);
  try
    R := W.StepIntoProbe(1234, 'probe-str', 2.5);   // {BP:STEPIN_CALLSITE}
    GSink.Use([R]);
  finally
    W.Free;
  end;
end;

procedure RunIndexedPropTest;
var
  Bag: TIndexedBag;
begin
  Bag := TIndexedBag.Create;
  try
    GSink.Use([Bag.Item[1], Bag.Caption]);   // {BP:INDEXED_PROP_BODY}
  finally
    Bag.Free;
  end;
end;

procedure RunDateTimeAliasTest;
var
  DOnly: TDate;
  TOnly: TTime;
  Sng:   Single;
begin
  DOnly := Now;
  TOnly := Now;
  Sng   := 1.5;
  GSink.Use([DOnly, TOnly, Sng]);  // {BP:DATE_ALIAS_BODY}
end;

procedure DupNameBlocks;
begin
  begin
    var dup := 111;
    GSink.Use([dup]);                 // {BP:DUP_BLOCK_INT}
  end;
  begin
    var dup := 'shadow-str';
    GSink.Use([Length(dup)]);         // {BP:DUP_BLOCK_STR}
  end;
end;

function MakeNullVariant: Variant;
begin
  Result := Null;   // a Variant returned via the hidden var-out slot
end;

procedure InlineVariantScenario;
  procedure InnerNested;
  begin
    var vnest := MakeNullVariant;
    GSink.Use([vnest]);               // {BP:NESTED_VARIANT}
  end;
begin
  var vn: Variant := Null;
  var ve: Variant := Unassigned;
  var vi: Variant := 1234;
  var vr := MakeNullVariant;
  InnerNested;
  GSink.Use([vn, ve, vi, vr]);        // {BP:INLINE_VARIANT}
end;

procedure RunRealScenario;
var
  W: TWidget;
  S: TStuff;
  SL: TStringList;
begin
  DupNameBlocks;
  InlineVariantScenario;
  RunConflict1;
  RunConflict2;
  W := TWidget.Create('real', 99);
  S := TStuff.Create(5, 'rtag');
  SL := TStringList.Create;
  try
    SL.Add('HELLO_VAROUT');
    var InlineLocal := 31337;
    GSink.Use([W.Value, S.PubCount, SL.Count, InlineLocal]);  // {BP:REAL_SCENARIO}
  finally
    SL.Free;
    S.Free;
    W.Free;
  end;
end;

procedure RunVariantTests;
var
  V:     Variant;
  Arr1D: Variant;
  Mat:   Variant;
begin
  V     := 99;
  Arr1D := VarArrayCreate([0, 4], varInteger);
  Arr1D[0] := 10;  Arr1D[1] := 20;  Arr1D[2] := 30;  Arr1D[3] := 40;  Arr1D[4] := 50;
  Mat   := VarArrayCreate([1, 3, 1, 4], varDouble);
  Mat[1, 1] := 1.5;
  Mat[2, 3] := 7.25;
  GSink.Use(V);  // {BP:VARIANT_BODY}
end;

procedure RunNestedVariantTest;

  procedure DoNested;
  var
    NestedDate:    Variant;
    NestedStr:     Variant;
    NestedNull:    Variant;
    NestedEmpty:   Variant;
    NestedInt:     Variant;
    NestedBool:    Variant;
    NestedDouble:  Variant;
    NestedI64:     Variant;
    NestedArr1D:   Variant;
    NestedMat2D:   Variant;
  begin
    NestedDate   := EncodeDate(2025, 12, 31);
    NestedStr    := 'hello-variant';
    NestedNull   := Null;     // explicit varNull
    NestedEmpty  := Unassigned; // explicit varEmpty (Variant default)
    NestedInt    := Int32(123456);
    NestedBool   := True;
    NestedDouble := Double(3.14);
    NestedI64    := Int64(1) shl 40;
    NestedArr1D  := VarArrayCreate([0, 4], varInteger);
    NestedArr1D[0] := 100; NestedArr1D[1] := 200; NestedArr1D[2] := 300;
    NestedArr1D[3] := 400; NestedArr1D[4] := 500;
    NestedMat2D  := VarArrayCreate([1, 2, 1, 3], varDouble);
    NestedMat2D[1, 1] := 1.5; NestedMat2D[1, 2] := 2.5; NestedMat2D[1, 3] := 3.5;
    NestedMat2D[2, 1] := 4.5; NestedMat2D[2, 2] := 5.5; NestedMat2D[2, 3] := 6.5;
    GSink.Use(NestedDate);  // {BP:NESTED_VARIANT_BODY}
  end;

begin
  DoNested;
end;

procedure InspectConstVariant(const v: Variant);
begin
  GSink.Use(v);  // {BP:CONST_VARIANT_BODY}
end;

procedure RunConstVariantTest;
var
  Outer: Variant;
begin
  Outer := EncodeDate(2026, 5, 26);
  InspectConstVariant(Outer);
end;

procedure RunMistaggedConstVariantTest;
  procedure InspectInsideNested(const v: Variant);
  begin
    GSink.Use(v);  // {BP:MISTAGGED_CONST_VARIANT_BODY}
  end;
var
  Outer: Variant;
begin
  Outer := EncodeDate(2026, 12, 31);
  InspectInsideNested(Outer);
end;

constructor TMenuCacheBase.Create;
begin
  inherited Create;
  BaseTag := 7;
end;

function TMenuCacheBase.GetBaseScore: Integer;
begin
  Result := BaseTag * 10;   // 70
end;

constructor TIndexProbe.Create;
begin
  inherited Create;
  FBias := 100;
end;

function TIndexProbe.GetByName(const AName: string): Integer;
begin
  Result := Length(AName) + FBias;   // ByName['abcd'] = 104
end;

function TIndexProbe.GetPlain(AIdx: Integer): Integer;
begin
  Result := AIdx * 3 + FBias;        // Plain[4] = 112
end;

function TIndexProbe.GetCell(ARow: Integer; const ACol: string): Integer;
begin
  Result := ARow * 1000 + Length(ACol) + FBias;   // Cell[3, 'xy'] = 3102
end;

function TVariantProbe.GetTag(const AKey: string): Variant;
begin
  // One-char string variant, like the char(1) CODE field ('A'/'B'/'C'/'D').
  if AKey = '' then
    Result := 'A'
  else
    Result := Copy(AKey, 1, 1);   // Tag['Gxx'] -> 'G'
end;

function TVariantProbe.GetNum(AIdx: Integer): Variant;
begin
  Result := AIdx + 1000;          // integer variant, Num[7] -> 1007
end;

constructor TReturnKindProbe.Create;
begin
  inherited Create;
  FChild := TMenuCacheBase.Create;   // BaseTag = 7
end;

destructor TReturnKindProbe.Destroy;
begin
  FChild.Free;
  inherited;
end;

constructor TThingWithOptSet.Create;
begin
  inherited Create;
  FOptions := [o10];   // bit 10 -> byte 1; reading only byte 0 shows []
end;

function TReturnKindProbe.GetNVar(AIdx: Integer): NullableInteger;
begin
  Result := AIdx + 50;   // NVar[5] -> a Variant(alias) holding 55
end;

function TReturnKindProbe.GetObj(AIdx: Integer): TMenuCacheBase;
begin
  Result := FChild;      // Obj[0].BaseTag -> 7
end;

function TReturnKindProbe.GetRec(AIdx: Integer): TPointRec;
begin
  Result.X := AIdx * 10; // Rec[3] -> (30, 31, 32)
  Result.Y := AIdx * 10 + 1;
  Result.Z := AIdx * 10 + 2;
end;

function TReturnKindProbe.GetModes(AIdx: Integer): TWorkModes;
begin
  Result := [wmRunning, wmError];   // <= 8-byte set returned in RAX
end;

function TReturnKindProbe.GetWide(AIdx: Integer): TWideSet;
begin
  Result := [we05, we70];           // > 8-byte set returned via var-out slot
end;

function TReturnKindProbe.GetRec0: TPointRec;
begin
  Result.X := 30; Result.Y := 31; Result.Z := 32;
end;

function TReturnKindProbe.GetModes0: TWorkModes;
begin
  Result := [wmRunning, wmError];
end;

function TReturnKindProbe.GetWide0: TWideSet;
begin
  Result := [we05, we70];
end;

constructor TMatrixProbe.Create;
begin
  inherited Create;
  FSeed := 7;
end;

constructor TCollideOuterA.TDup.Create;
begin
  inherited Create;
  AlphaA := 111;
  BetaA  := 222;
end;

constructor TCollideOuterB.TDup.Create;
begin
  inherited Create;
  GammaB := 999;
  DeltaB := 1000;
  EpsilonB := 1001;
end;

constructor TDupCrossCache.TDupCross.Create;
begin
  inherited Create;
  FakeHits := 777;
end;

function TMatrixProbe.GetItem(ARow, ACol: Integer): Integer;
begin
  Result := ARow * 100 + ACol * 10 + FSeed;        // Item[2,3] = 237
end;

function TMenuCacheBase.BaseEcho(AValue: Integer): Integer;
begin
  Result := AValue * 2 + BaseTag;   // BaseEcho(21) = 49 with BaseTag = 7
end;

function TMenuCacheBase.BaseLen(const AText: string): Integer;
begin
  Result := Length(AText) + BaseTag;   // BaseLen('abcd') = 11 with BaseTag = 7
end;

constructor TMenuCache.Create;
begin
  inherited Create;
  Items   := ['one', 'two'];
  FLevels := [10, 20, 30];
end;

function TMenuCache.GetLevel(Idx: Integer): Integer;
begin
  if (Idx >= 0) and (Idx <= High(FLevels)) then
    Result := FLevels[Idx]
  else
    Result := -1;
end;

constructor TMenuRepro.Create(const AOwnerName: string);
begin
  inherited Create;
  FOwnerName := AOwnerName;
end;

procedure TMenuRepro.LoadMenu;
var
  Cache: TMenuCache;
  Probe: TIndexProbe;    // in scope at NESTED_CLASS_METHOD_BODY for the evaluator tests
  Matrix: TMatrixProbe;  // multi-index default property
  VProbe: TVariantProbe; // default property returning a Variant (FieldValues shape)
  RKProbe: TReturnKindProbe; // indexed properties returning variant-alias/class/record
  WideSet:  TWideSet;        // > 8-byte set (A1)
  OptField: TThingWithOptSet;// field-backed 2-byte set (A2)
  DupA: TCollideOuterA.TDup;   // two same-named nested classes, distinct layouts
  DupB: TCollideOuterB.TDup;
  // Same two objects, but typed as TObject: the static type carries no member
  // list, so the debugger must read the runtime VMT to find the real class -
  // the by-name path that the live `dataset.Fields` bug travels.
  DupObjA: TObject;
  DupObjB: TObject;
  // Instance of the TOP-LEVEL TestTargetTypes.TDupCross, held as TObject so the
  // debugger must resolve members from the runtime VMT by the bare name that
  // collides with the nested TDupCrossCache.TDupCross.
  CrossReal: TObject;

  procedure CreateNodes(NodeId: Integer);
  var
    CurrentLevel:  Integer;
    CurrentParent: TMenuCache; // class-typed pointer; must show as `nil` not `0`
    LocalStr:      string;
  begin
    CurrentLevel  := 1;
    CurrentParent := nil;
    LocalStr      := 'hello';
    GSink.Use([NodeId]);                                    // {BP:NESTED_CLASS_METHOD_BODY}
    GSink.Use([CurrentLevel, LocalStr, Cache.Items[0], FOwnerName, Cache.Level[0]]);
    // Referenced so the linker keeps them: the evaluator tests call these two
    // through the debugger, and a method nothing calls is smart-linked away -
    // its symbol would be missing and the test would fail for the wrong reason.
    GSink.Use([Cache.BaseEcho(0), Cache.BaseLen('')]);
    // Same reason: every getter must survive the linker for the default-property
    // work, and `Probe['x']` / `Matrix[r,c]` must have something to resolve to.
    GSink.Use([Probe['seed'], Probe.Plain[1], Probe.Cell[0, ''], Matrix[0, 0]]);
    GSink.Use([VProbe['a'], VProbe.Num[0]]);
    GSink.Use([RKProbe.NVar[0], RKProbe.Obj[0].BaseTag, RKProbe.Rec[0].X]);
    if (WideSet <> []) and (OptField <> nil) then GSink.Use(['s']);
    if (RKProbe.Modes[0] <> []) and (RKProbe.Wide[0] <> []) then GSink.Use(['g']);
    if (RKProbe.SmallSetP <> []) and (RKProbe.WideSetP <> []) then GSink.Use([RKProbe.PointP.X]);
    // Keep every same-named instance referenced and reachable.
    GSink.Use([DupA.AlphaA, DupB.GammaB]);
    if (DupObjA = nil) or (DupObjB = nil) or (CrossReal = nil) then GSink.Use(['x']);
    if CurrentParent <> nil then
      GSink.Use(['parent: ', CurrentParent.Items[0]]);
  end;

begin
  Cache  := TMenuCache.Create;
  Probe  := TIndexProbe.Create;
  Matrix := TMatrixProbe.Create;
  VProbe := TVariantProbe.Create;
  RKProbe := TReturnKindProbe.Create;
  WideSet  := [we05, we70, we79];   // members beyond bit 63
  OptField := TThingWithOptSet.Create;
  DupA   := TCollideOuterA.TDup.Create;
  DupB   := TCollideOuterB.TDup.Create;
  DupObjA := DupA;
  DupObjB := DupB;
  CrossReal := TestTargetTypes.TDupCross.Create;
  try
    CreateNodes(42);
  finally
    CrossReal.Free;
    DupB.Free;
    DupA.Free;
    OptField.Free;
    RKProbe.Free;
    VProbe.Free;
    Matrix.Free;
    Probe.Free;
    Cache.Free;
  end;
end;

procedure RunNestedClassMethodTest;
var
  R: TMenuRepro;
begin
  // Call the collider FIRST so its `createnodes` proc record is parsed and
  // indexed before TMenuRepro's (RSM short-name last-write-wins).
  RunCollider;
  R := TMenuRepro.Create('repro-owner');
  try
    R.LoadMenu;
  finally
    R.Free;
  end;
end;

procedure RunExceptionTest;
begin
  try
    raise Exception.Create('exc-test'); // {BP:EXC_RAISE}
  except
    on E: Exception do
      GSink.Use(['caught: ', E.Message]);
  end;
end;

// Native (non-Delphi) Windows exception followed by a Delphi one. The native
// raise carries no exception object at the point the debugger sees it, hence no
// class and no message: only the `code` rule criterion can target it. The code
// is a customer-defined one so it collides with nothing the debugger handles
// itself (0x406D1388, the thread-name announcement, is consumed by the debugger
// before rules run and can therefore not be used here).
procedure RunNativeExceptionTest;
const
  CUSTOM_NATIVE_EXCEPTION_CODE = $E0424242;
begin
  try
    RaiseException(CUSTOM_NATIVE_EXCEPTION_CODE, 0, 0, nil);   // {BP:NATIVE_RAISE}
  except
    on E: Exception do
      GSink.Use(['native caught: ', E.Message]);
  end;
  try
    raise Exception.Create('exc-after-native');   // {BP:AFTER_NATIVE_RAISE}
  except
    on E: Exception do
      GSink.Use(['caught: ', E.Message]);
  end;
end;

procedure RunReRaiseFlow;
begin
  try
    try
      raise Exception.Create('reraise-orig');   // first raise
    except
      raise;                                     // {BP:RERAISE} bare re-raise
    end;
  except
    on E: Exception do
      GSink.Use(['reraise caught: ', E.Message]);
  end;
end;

procedure RunAccessViolation;
var
  P: PInteger;
begin
  try
    P := nil;
    P^ := 42;   // {BP:AV_WRITE} write to address 0 -> access violation
  except
    on E: Exception do
      GSink.Use(['av-caught: ', E.Message]);
  end;
end;

procedure RunAttachSurvive;
var
  I: Integer;
begin
  for I := 1 to 120 do begin
    GSink.Use(['attach-survive', I]);   // {BP:ATTACH_SURVIVE_BODY}
    Sleep(250);
  end;
end;

// Like RunAttachSurvive, but every pass RAISES and catches a Delphi exception.
// An attach happens while the target is already running, so an attach test that
// needs a first-chance exception needs one that keeps arriving after the attach
// completes rather than one raised during startup, which is a race the test
// would lose most of the time.
procedure RunAttachRaiseLoop;
begin
  for var Pass := 1 to 120 do begin
    try
      raise Exception.Create('attach-exc');   // {BP:ATTACH_RAISE_LOOP}
    except
      on E: Exception do
        GSink.Use(['attach-raise ', Pass, ': ', E.Message]);
    end;
    Sleep(250);
  end;
end;

procedure RunLoadNoDebugDll;
type
  TNoDebugAdd = function(A, B: Integer): Integer; stdcall;
var
  H:  HMODULE;
  Fn: TNoDebugAdd;
  R:  Integer;
begin
  R := 0;
  H := LoadLibrary('NoDebugLib.dll');
  if H <> 0 then begin
    @Fn := GetProcAddress(H, 'NoDebugAdd');
    if Assigned(Fn) then
      R := Fn(40, 2);
  end;
  GSink.Use(['nodebug-add=', R]);   // {BP:NODEBUG_DONE} reached after the no-debug DLL is loaded + called
end;

procedure RunLoadUnloadBplObj;
type
  TMakeWidget = function: NativeUInt;
var
  H:  HMODULE;
  Fn: TMakeWidget;
begin
  GPkgObj := nil;
  H := LoadPackage('TestPackage.bpl');
  if H <> 0 then begin
    @Fn := GetProcAddress(H, 'PkgMakePersistentWidget');
    if Assigned(Fn) then
      GPkgObj := TObject(Pointer(Fn()));
    UnloadPackage(H);   // BPL code + VMT unmapped; GPkgObj is now stale
  end;
  GSink.Use(['unloaded-bpl-obj']);   // {BP:UNLOADED_OBJ} inspect GPkgObj -- must not crash
end;

procedure RunExceptionHandlerProbe;
begin
  try
    raise Exception.Create('exc-test-probe');
  except
    on E: Exception do begin
      GSink.Use(['handler: ', E.Message]);
      GSink.Use([0]); // {BP:EXC_HANDLER}
    end;
  end;
end;

// A bare `except .. end` inside an ordinary PROCEDURE. The exception it caught
// has no source-level name at all, so `$exception` is the only way to reach it
// -- and unlike the main-block probes this one is compiled into the BPL too, so
// the scenario covers a runtime package as well as a monolithic exe.
procedure RunBareExceptProbe;
begin
  try
    raise Exception.Create('bare-test-probe');
  except
    GSink.Use(['bare handler']);
    GSink.Use([0]); // {BP:BARE_EXCEPT}
  end;
end;

function FreeAdd(A, B: Integer): Integer;
begin
  Result := A + B;
end;

function FreeWrap(const S: string): string;
begin
  Result := '<' + S + '>';
end;

type
  // POD record of exactly 8 bytes: the Win64 ABI returns it PACKED IN RAX, not
  // through a hidden var-out slot. Watching a call to MakeSmallPt used to show a
  // bogus zero because the debugger read the untouched var-out slot.
  TSmallPt = record
    X, Y: Integer;
  end;

function MakeSmallPt(AX, AY: Integer): TSmallPt;
begin
  Result.X := AX;
  Result.Y := AY;
end;

procedure NameCurrentThread(const Name: string);
var
  H:  HMODULE;
  Fn: TSetThreadDescription;
begin
  H := GetModuleHandleW('kernel32.dll');
  if H = 0 then Exit;
  Fn := TSetThreadDescription(GetProcAddress(H, 'SetThreadDescription'));
  if Assigned(Fn) then
    Fn(GetCurrentThread, PWideChar(Name));
end;

function ThreadWorker(Param: Pointer): DWORD; stdcall;
begin
  NameCurrentThread('TestWorker' + IntToStr(NativeUInt(Param)));
  Sleep(INFINITE);
  Result := 0;
end;

function WorkerBpProc(Param: Pointer): DWORD; stdcall;
var
  WLocal: Integer;
begin
  NameCurrentThread('BpWorker');
  WLocal := 4242;
  GSink.Use(['worker-body ', WLocal]);   // {BP:WORKER_BODY}
  Result := 0;
end;

procedure RunWorkerBpTest;
var
  H: THandle;
  Id: DWORD;
begin
  H := CreateThread(nil, 0, @WorkerBpProc, nil, 0, Id);
  WaitForSingleObject(H, 5000);
  CloseHandle(H);
end;

function WorkerRaiseProc(Param: Pointer): DWORD; stdcall;
begin
  NameCurrentThread('RaiseWorker');
  try
    raise Exception.Create('worker-boom');   // {BP:WORKER_RAISE}
  except
    on E: Exception do
      GSink.Use(['worker caught ', E.Message]);
  end;
  Result := 0;
end;

procedure RunWorkerRaiseTest;
var
  H: THandle;
  Id: DWORD;
begin
  H := CreateThread(nil, 0, @WorkerRaiseProc, nil, 0, Id);
  WaitForSingleObject(H, 10000);
  CloseHandle(H);
end;

procedure RunThreadsTest;
var
  H1, H2: THandle;
  Id1, Id2: DWORD;
begin
  NameCurrentThread('TestMain');
  H1 := CreateThread(nil, 0, @ThreadWorker, Pointer(1), 0, Id1);
  H2 := CreateThread(nil, 0, @ThreadWorker, Pointer(2), 0, Id2);
  Sleep(150);
  GSink.Use(['workers spawned ', Id1, ' ', Id2]); // {BP:THREADS_READY}
  CloseHandle(H1);
  CloseHandle(H2);
end;

// --- MS_VC_EXCEPTION self-naming fixture -----------------------------------
// TThread.NameThreadForDebugging announces a thread's name to the debugger by
// raising the $406D1388 protocol exception. The debugger must consume it: adopt
// the name AND never surface it as a stop, whatever the exception filters say.
//
// The worker names itself only after the main thread gives it the go-ahead, so
// the announcement lands long after the thread's CREATE_THREAD event. That is
// deliberate: it forces the debugger's id -> name mapping to be updated live
// rather than snapshotted when the thread appeared.

type
  TSelfNamingThread = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  GNamingGo:   THandle = 0;  // main -> worker: name yourself now
  GNamingDone: Integer = 0;  // worker -> main: announcement sent

procedure TSelfNamingThread.Execute;
begin
  WaitForSingleObject(GNamingGo, 10000);
  TThread.NameThreadForDebugging('DelphiNamedWorker');
  GNamingDone := 1;
  while not Terminated do
    Sleep(10);
end;

procedure RunThreadNamingTest;
var
  Worker: TSelfNamingThread;
begin
  NameCurrentThread('NamingMain');
  GNamingDone := 0;
  GNamingGo   := CreateEvent(nil, True, False, nil);
  Worker      := TSelfNamingThread.Create(False);
  try
    Sleep(150);                                     // worker parked, still unnamed
    SetEvent(GNamingGo);                            // {BP:THREADNAME_BEFORE}
    Sleep(400);                                     // let the announcement land
    GSink.Use(['named ', GNamingDone]);             // {BP:THREADNAME_READY}
    Worker.Terminate;
    Worker.WaitFor;
  finally
    Worker.Free;
    CloseHandle(GNamingGo);
    GNamingGo := 0;
  end;
end;

// --- Per-thread stepping isolation fixture --------------------------------
// Two worker threads spin incrementing their OWN counter until GStepIsoStop.
// The main thread stops at STEPISO_MAIN with both spinners live (frozen by the
// stop). A test then single-steps ONE spinner and asserts only its counter moved
// while the other's stayed exactly put -- proof the step froze every other thread.

function StepIsoSpinB(Param: Pointer): DWORD; stdcall;
var
  TagB: Integer;             // distinctive live local: proves a frame selected on
begin                        // THIS thread reads THIS thread's stack
  NameCurrentThread('StepIsoSpinB');
  TagB := 12345;
  while not GStepIsoStop do begin
    Inc(GStepIsoB);          // {BP:STEPISO_SPIN_B}
    if TagB = 0 then Break;  // never taken; keeps TagB live across the loop
  end;
  Result := 0;
end;

function StepIsoSpinC(Param: Pointer): DWORD; stdcall;
begin
  NameCurrentThread('StepIsoSpinC');
  while not GStepIsoStop do
    Inc(GStepIsoC);          // {BP:STEPISO_SPIN_C}
  Result := 0;
end;

procedure StepIsoMainMark;
begin
  GSink.Use(['per-thread-step ready ', GStepIsoB, GStepIsoC]);   // {BP:STEPISO_MAIN}
end;

procedure RunPerThreadStepFixture;
var
  HB, HC: THandle;
  IdB, IdC: DWORD;
begin
  NameCurrentThread('StepIsoMain');
  GStepIsoStop := False;
  GStepIsoB    := 0;
  GStepIsoC    := 0;
  HB := CreateThread(nil, 0, @StepIsoSpinB, nil, 0, IdB);
  HC := CreateThread(nil, 0, @StepIsoSpinC, nil, 0, IdC);
  Sleep(100);            // let both spinners get well inside their loops
  StepIsoMainMark;       // debugger stops here; both spinners live but frozen
  GStepIsoStop := True;  // reached only once the debugger resumes / detaches
  WaitForSingleObject(HB, 5000);
  WaitForSingleObject(HC, 5000);
  CloseHandle(HB);
  CloseHandle(HC);
end;

// --- Hardware-watchpoint / DR6 disambiguation fixture ----------------------
// A watchpoint hit and a completed single step arrive as the SAME exception, so
// the event pump can only separate them by reading DR6. Two directions have to
// be provable, and this fixture supplies one call site for each:
//
//   * a step still completes while a watchpoint is armed -- step over
//     DataBpQuietStep, which never touches the watched cell;
//   * a hit that happens inside a stepped-over call is NOT reported as that
//     step completing -- step over DataBpWriteWatched, which writes it.
//
// The write sits in a CALLEE deliberately. During a step-over the target runs
// free to a planted return breakpoint with the trap flag off, so the trap the
// watchpoint produces is unambiguously not the step's own -- which is exactly
// the event the pump used to misread as a completed step.

procedure DataBpQuietStep;
begin
  Inc(GDataBpOther);                                          // {BP:DATABP_QUIET_BODY}
end;

// The write is deliberately NOT the first statement: a breakpoint on a routine's
// first statement is subject to entry/body adjustment, and the combined-case test
// needs the breakpoint to sit exactly BEFORE the writing instruction.
procedure DataBpWriteWatched;
begin
  GDataBpOther := GDataBpOther + 1;                           // {BP:DATABP_WRITE_PRE}
  Inc(GDataBpWatched);                                        // {BP:DATABP_WRITE_BODY}
  GDataBpOther := GDataBpOther + 2;                           // {BP:DATABP_WRITE_AFTER}
end;

procedure RunDataBpStepFixture;
begin
  GDataBpWatched := 0;
  GDataBpOther   := 0;
  GSink.Use(['databp ready ', GDataBpWatched]);               // {BP:DATABP_READY}
  DataBpQuietStep;                                            // {BP:DATABP_QUIET_CALL}
  DataBpWriteWatched;                                         // {BP:DATABP_WRITE_CALL}
  GSink.Use(['databp done ', GDataBpWatched, GDataBpOther]);  // {BP:DATABP_DONE}
end;

// --- Per-thread watchpoint replication fixture -----------------------------
// WorkerA is created and spinning BEFORE the debugger arms a watchpoint at
// DATABPTHREAD_READY -- proving arm-time replication onto every live thread.
// WorkerB is created AFTER the debugger has resumed past that stop -- proving
// HandleCreateThread re-arms an in-use slot on a thread it did not know about
// yet. Each writes a DIFFERENT global so a test that arms only one of them
// sees exactly one hit, from exactly the thread that must have caused it.

function DataBpThreadWorkerA(Param: Pointer): DWORD; stdcall;
begin
  NameCurrentThread('DataBpWorkerA');
  while not GDataBpThreadGo do
    Sleep(1);
  Inc(GDataBpThreadWatched);                              // {BP:DATABPTHREAD_WORKERA_WRITE}
  Result := 0;
end;

function DataBpThreadWorkerB(Param: Pointer): DWORD; stdcall;
begin
  NameCurrentThread('DataBpWorkerB');
  Inc(GDataBpThreadLate);                                 // {BP:DATABPTHREAD_WORKERB_WRITE}
  Result := 0;
end;

procedure RunDataBpThreadFixture;
var
  HA, HB: THandle;
  IdA, IdB: DWORD;
begin
  NameCurrentThread('DataBpThreadMain');
  GDataBpThreadGo      := False;
  GDataBpThreadWatched := 0;
  GDataBpThreadLate    := 0;
  HA := CreateThread(nil, 0, @DataBpThreadWorkerA, nil, 0, IdA);
  Sleep(100);   // let WorkerA reach its poll loop before the debugger stops us
  GSink.Use(['databp thread ready ', GDataBpThreadWatched]);   // {BP:DATABPTHREAD_READY}
  // Debugger arms a watchpoint here (on GDataBpThreadWatched and/or
  // GDataBpThreadLate) and resumes.
  HB := CreateThread(nil, 0, @DataBpThreadWorkerB, nil, 0, IdB);  // created AFTER the arm
  GDataBpThreadGo := True;  // release WorkerA to write
  WaitForSingleObject(HA, 5000);
  WaitForSingleObject(HB, 5000);
  CloseHandle(HA);
  CloseHandle(HB);
  GSink.Use(['databp thread done ', GDataBpThreadWatched, GDataBpThreadLate]);  // {BP:DATABPTHREAD_DONE}
end;

// --- Frame-scoped (local) watchpoint fixture -------------------------------
// A watchpoint on a LOCAL is only meaningful while the frame that owns it is
// still on the stack, and this fixture supplies both halves of that:
//
//   * DataBpLocalWriter stops with V already initialised (so a watchpoint set
//     there has a real OLD value) and then writes it exactly once -- the hit;
//   * that frame then EXITS and DataBpLocalAfter runs at the SAME stack depth
//     with a local of the same width, so the slot is genuinely reused. From
//     that point the watchpoint must be reported stale and withdrawn, never
//     reported as another change to V.
//
// The watched write is deliberately not the routine's first statement (see the
// same note on DataBpWriteWatched).

procedure DataBpLocalAfter;
var
  Reuse: Integer;
begin
  Reuse := 4242;                                        // {BP:DATABPLOCAL_REUSE}
  GDataBpOther := GDataBpOther + Reuse;
end;

procedure DataBpLocalWriter;
var
  V: Integer;
begin
  V := 1;
  GSink.Use(['databp local start ', V]);                // {BP:DATABPLOCAL_ARM}
  V := V + 41;                                          // {BP:DATABPLOCAL_WRITE}
  GSink.Use(['databp local end ', V]);                  // {BP:DATABPLOCAL_END}
end;

// LastError / LastStatus fixture. A call that is certain to fail sets both
// halves: the Win32 wrapper stores the error code, the native call underneath
// it stores the NTSTATUS that caused it. The routine then captures the Win32
// half in a global, so a test can compare what the debugger read out of the TEB
// against what the target itself saw -- which is the only trustworthy ground
// truth for a WOW64 target, where two TEBs exist and only the running code
// knows which one it writes.
//
// Nothing that could call an API sits between the capture and the marker: any
// intervening call could set an error of its own and the test would be chasing
// it instead.
procedure RunLastErrorFixture;
begin
  var H := CreateFile(PChar('C:\__no_such_directory__\__no_such_file__'),
                      GENERIC_READ, 0, nil, OPEN_EXISTING, 0, 0);
  if H <> INVALID_HANDLE_VALUE then
    CloseHandle(H);
  GLastErrorSeen := GetLastError;
  GSink.Use(['lasterror ', GLastErrorSeen]);            // {BP:LASTERROR_BODY}
end;

procedure RunDataBpLocalFixture;
begin
  GDataBpOther := 0;
  GSink.Use(['databp local ready']);                    // {BP:DATABPLOCAL_READY}
  DataBpLocalWriter;
  DataBpLocalAfter;                                     // {BP:DATABPLOCAL_AFTER_CALL}
  GSink.Use(['databp local done ', GDataBpOther]);      // {BP:DATABPLOCAL_DONE}
end;

// The case a watchpoint on a COMPUTED address exists for: a routine that writes
// its buffer correctly, then writes one byte past the end. Neither write names
// a variable a user could right-click -- the target has to be reached by an
// expression (`GDataBpBuffer.Data[High(...)]`, or the address just past it).
//
// Each write is a separate statement with its own marker so a test can arm
// between them, and none of them is the routine's first statement (same reason
// as DataBpWriteWatched: the arm must happen while the routine is already
// running).
procedure DataBpBufferWriter;
begin
  GDataBpBuffer.Data[0] := 1;                                 // {BP:DATABP_BUF_ARM}
  GDataBpBuffer.Data[High(GDataBpBuffer.Data)] := 2;          // {BP:DATABP_BUF_LAST}
  GDataBpBuffer.After := 3;                                   // {BP:DATABP_BUF_OVERRUN}
  GSink.Use(['databp buffer end ', GDataBpBuffer.After]);     // {BP:DATABP_BUF_END}
end;

procedure RunDataBpBufferFixture;
begin
  GDataBpBuffer.Before := 0;
  GDataBpBuffer.After  := 0;
  for var I := Low(GDataBpBuffer.Data) to High(GDataBpBuffer.Data) do
    GDataBpBuffer.Data[I] := 0;
  GSink.Use(['databp buffer ready']);                         // {BP:DATABP_BUF_READY}
  DataBpBufferWriter;
  GSink.Use(['databp buffer done ', GDataBpBuffer.Data[0]]);  // {BP:DATABP_BUF_DONE}
end;

procedure RunBpTests;
var
  I, Acc: Integer;
begin
  Acc := 0;
  I   := 1;
  while I <= 5 do begin
    Inc(Acc, I);              // {BP:BP_LOOP}
    if Acc < 0 then GSink.Use(['?']);
    Inc(I);
  end;
  GSink.Use(['Acc=', Acc]);   // {BP:BP_AFTER_LOOP}
end;

// Portable replica of the program-main-block object scenario using PROC-LOCAL
// objects instead of main-block inline vars. The inline vars TheWidget/TheStuff
// in TestTarget.dpr are exe-only (RSM main-block table, no BPL/TD32 equivalent),
// but the METHOD markers they exercise -- CTOR_BODY, STUFF_CTOR_END,
// COMPUTE_BODY, NESTED_INC/NESTED_CALL_INNER/INNER_BODY, STUFF_PUBBUMP -- and the
// canonical field values ('hello',42 / 7,'tag' -> FValue=42 => Factor=84,
// FCount=7) are PORTABLE. Calling this from RunAllScenarios makes every
// "inside a method" test (implicit-Self, bare fields, var param, ctor params,
// nested-proc locals) fire in BOTH the monolithic exe AND the BPL. In the exe,
// RunAllScenarios runs BEFORE the .dpr main block, so these markers hit HERE
// first with identical values -- monolithic assertions are unchanged.
procedure RunMainObjectScenarioPortable;
var
  W:    TWidget;
  S:    TStuff;
  Res:  Integer;
  X:    Integer;
begin
  // NB: the BP markers (CTOR_BODY/STUFF_CTOR_END/COMPUTE_BODY/NESTED_*/INNER_BODY/
  // STUFF_PUBBUMP) live INSIDE the called methods -- do NOT repeat the {BP:...}
  // token at these call sites or Bp() would find each marker twice.
  W := TWidget.Create('hello', 42);   // -> CTOR_BODY (inside TWidget.Create)
  S := TStuff.Create(7, 'tag');        // -> STUFF_CTOR_END (FCount=7)
  try
    Res := 0;
    W.Compute(Res);                    // -> COMPUTE_BODY (Factor = FValue*2 = 84)
    GSink.Use(['Compute: ', Res]);
    if Res < 0 then
      GSink.Use([W.Sum5(1, 2, 3, 4, 5)]);
    X := 10;
    ComputeNested(X);                  // -> NESTED_INC / NESTED_CALL_INNER / INNER_BODY
    GSink.Use(['X after: ', X]);
    GSink.Use([S.PubCount]);
    GSink.Use([S.PubBump]);            // -> STUFF_PUBBUMP
    if Res < 0 then begin
      GSink.Use([S.BumpCount]);
      GSink.Use([S.RaiseBoom]);
    end;
  finally
    S.Free;
    W.Free;
  end;
end;

// True when THIS code is executing from inside the runtime package
// (TestSubject.bpl) rather than the monolithic exe. Resolves the module that
// physically contains this unit's code from a code address: VirtualQuery gives
// the allocation base of that address (the module's load base), then
// GetModuleFileName turns it into a path. Reliable PER-MODULE even when the host
// exe and the package share a single RTL package -- in that case IsLibrary and
// HInstance are the shared MAIN module's values (exe -> False), so they cannot
// be used to tell exe-hosted code apart from package-hosted code.
function RunningInsidePackageModule: Boolean;
var
  Info: TMemoryBasicInformation;
  Path: array[0..MAX_PATH] of Char;
begin
  Result := False;
  if VirtualQuery(@RunMainObjectScenarioPortable, Info, SizeOf(Info)) = 0 then
    Exit;
  if GetModuleFileName(HINST(Info.AllocationBase), Path, Length(Path)) = 0 then
    Exit;
  Result := SameText(ExtractFileExt(Path), '.bpl');
end;

procedure RunAllScenarios;
begin
  GSink := TSink.Create;
  // Attach test entrypoint: when invoked with `--attach-pause`, sleep long
  // enough for an external debugger to attach before the target races to exit.
  if FindCmdLineSwitch('attach-pause') or FindCmdLineSwitch('-attach-pause') then
    Sleep(5000);

  if FindCmdLineSwitch('attach-survive') or FindCmdLineSwitch('-attach-survive') then
    RunAttachSurvive;

  if FindCmdLineSwitch('attach-raise-loop') or FindCmdLineSwitch('-attach-raise-loop') then
    RunAttachRaiseLoop;

  if FindCmdLineSwitch('run-per-thread-step') or FindCmdLineSwitch('-run-per-thread-step') then
    RunPerThreadStepFixture;

  if FindCmdLineSwitch('run-databp-step') or FindCmdLineSwitch('-run-databp-step') then
    RunDataBpStepFixture;

  if FindCmdLineSwitch('run-databp-thread') or FindCmdLineSwitch('-run-databp-thread') then
    RunDataBpThreadFixture;

  if FindCmdLineSwitch('run-databp-local') or FindCmdLineSwitch('-run-databp-local') then
    RunDataBpLocalFixture;

  if FindCmdLineSwitch('run-lasterror') or FindCmdLineSwitch('-run-lasterror') then
    RunLastErrorFixture;

  if FindCmdLineSwitch('run-databp-buffer') or FindCmdLineSwitch('-run-databp-buffer') then
    RunDataBpBufferFixture;

  if FindCmdLineSwitch('run-av') or FindCmdLineSwitch('-run-av') then
    RunAccessViolation;

  if FindCmdLineSwitch('run-reraise') or FindCmdLineSwitch('-run-reraise') then
    RunReRaiseFlow;

  if FindCmdLineSwitch('run-worker-raise') or FindCmdLineSwitch('-run-worker-raise') then
    RunWorkerRaiseTest;

  if FindCmdLineSwitch('run-step-raise') or FindCmdLineSwitch('-run-step-raise') then
    RunStepRaise;

  if FindCmdLineSwitch('run-deep-nested-raise') or FindCmdLineSwitch('-run-deep-nested-raise') then
    RunDeepNestedRaise;

  if FindCmdLineSwitch('load-nodebug-dll') or FindCmdLineSwitch('-load-nodebug-dll') then
    RunLoadNoDebugDll;

  if FindCmdLineSwitch('load-unload-bpl-obj') or FindCmdLineSwitch('-load-unload-bpl-obj') then
    RunLoadUnloadBplObj;

  if FindCmdLineSwitch('run-real-scenario') or FindCmdLineSwitch('-run-real-scenario') then
    RunRealScenario;

  if FindCmdLineSwitch('run-uses-scope') or FindCmdLineSwitch('-run-uses-scope') then begin
    GSink.Use([TestTargetUsesA.DupFunc,  TestTargetUsesB.DupFunc,  TestTargetUsesC.DupFunc,
               TestTargetUsesA.DupConst, TestTargetUsesB.DupConst, TestTargetUsesC.DupConst,
               TestTargetUsesA.TDup.Tag, TestTargetUsesB.TDup.Tag, TestTargetUsesC.TDup.Tag,
               SizeOf(TestTargetUsesA.TDupRec), SizeOf(TestTargetUsesB.TDupRec),
               SizeOf(TestTargetUsesC.TDupRec)]);
    RunUsesScope;
  end;

  // Keep the free procs alive (DCE guard, never true at runtime).
  if FreeAdd(1, 2) < 0 then ;
  if Length(FreeWrap('x')) < 0 then ;
  if MakeSmallPt(1, 2).X < 0 then ;

  // Keep TBareClass alive in the binary: instantiate then free. All its members
  // are private; its constructor is only reachable from inside this unit, so the
  // keep-alive lives here (not in the thin .dpr). The type record is what the
  // RSM all-private-class test cares about.
  TBareClass.Create('bare', 99).Free;

  // Host copy of the uses-graph collision global. Set before any package loads.
  GUsesGraph := 444;

  if FindCmdLineSwitch('load-package') or FindCmdLineSwitch('-load-package') then
    LoadPackage('TestPackage.bpl');

  if FindCmdLineSwitch('load-missing-bpl') or FindCmdLineSwitch('-load-missing-bpl') then
    try
      LoadPackage('NoSuchPackage_zzz.bpl');
    except
      on E: Exception do
        GSink.Use(['missing-bpl caught: ', E.Message]);
    end;

  if FindCmdLineSwitch('reload-package') or FindCmdLineSwitch('-reload-package') then begin
    var H := LoadPackage('TestPackage.bpl');   // load #1 -> BP fires
    UnloadPackage(H);                           // form closed
    LoadPackage('TestPackage.bpl');            // load #2 -> BP fires again
  end;

  if FindCmdLineSwitch('load-package2') or FindCmdLineSwitch('-load-package2') then begin
    LoadPackage('TestPackage.bpl');    // PkgAdd  -> PKG_BP
    LoadPackage('TestPackage2.bpl');   // PkgMul  -> PKG2_BP
  end;

  // Portable object-method scenario: makes the "inside a method" markers
  // (CTOR_BODY/STUFF_CTOR_END/COMPUTE_BODY/NESTED_*/INNER_BODY/STUFF_PUBBUMP)
  // fire with the canonical 'hello'/42, 7/'tag' values. ONLY in the BPL
  // (IsLibrary = True when this code runs inside TestSubject.bpl): in the
  // monolithic exe the .dpr main block already exercises these markers, and
  // running this first there would flip the MAIN_GCOUNTER-before-STUFF_PUBBUMP
  // order some monolithic tests (e.g. Test_Bug16) depend on.
  if RunningInsidePackageModule then
    RunMainObjectScenarioPortable;

  RunAliasLocalTest;
  RunClosureSampler;
  RunClosureParamSampler;
  RunDeepNestedTest;
  RunEvalTests;
  RunExprSemanticsTests;
  RunExprOracle;
  RunPrimitiveDisplaySampler;
  RunDestructorProbe;
  RunDateTimeAliasTest;
  RunStepConsecutiveCalls;
  RunStepIntoPrologue;
  RunStepOverStackArg;
  RunStepManagedClear;
  RunIndexedPropTest;
  RunVariantTests;
  RunWideFieldsProbe;
  RunDynArrayDisplayProbe;
  if FindCmdLineSwitch('run-goto') or FindCmdLineSwitch('-run-goto') then
    RunGotoProbe;
  RunEnumPackProbe;
  RunBigVarArrayProbe;
  RunBigDynArrayProbe;
  if FindCmdLineSwitch('run-ods') or FindCmdLineSwitch('-run-ods') then
    RunOdsProbe;
  RunNestedVariantTest;
  RunConstVariantTest;
  RunMistaggedConstVariantTest;
  RunNestedClassMethodTest;
  RunDeepNesting;
  RunStaticClassMethod;
  RunOperatorOverload;
  RunPropertySetter;
  RunCollections;
  RunTypeSampler;
  RunEdgeCases;
  RunRecursion;
  RunCtorProbe;
  RunEdge2;
  RunOpenArray;
  RunRtlCallback;
  RunThreadVar;
  RunReal;
  RunRobust;
  RunStepFlow;
  RunStepBranchFlow;
  RunStepEntryFlow;
  RunNest3Flow;
  RunRecByValFlow;
  if FindCmdLineSwitch('run-exc-flow') or FindCmdLineSwitch('-run-exc-flow') then
    RunExcHandlerFlow;
  TestTargetTypes.DoWork;
  RunBpTests;
  if FindCmdLineSwitch('run-exception-handler') or
     FindCmdLineSwitch('-run-exception-handler') then
    RunExceptionHandlerProbe;
  if FindCmdLineSwitch('run-bare-except') or
     FindCmdLineSwitch('-run-bare-except') then
    RunBareExceptProbe;
  if FindCmdLineSwitch('run-exception-test') or
     FindCmdLineSwitch('-run-exception-test') then
    RunExceptionTest;
  if FindCmdLineSwitch('run-native-exception-test') or
     FindCmdLineSwitch('-run-native-exception-test') then
    RunNativeExceptionTest;
  if FindCmdLineSwitch('run-threads') or FindCmdLineSwitch('-run-threads') then
    RunThreadsTest;
  if FindCmdLineSwitch('run-thread-naming') or FindCmdLineSwitch('-run-thread-naming') then
    RunThreadNamingTest;
  if FindCmdLineSwitch('run-worker-bp') or FindCmdLineSwitch('-run-worker-bp') then
    RunWorkerBpTest;
end;

exports RunAllScenarios;

end.
