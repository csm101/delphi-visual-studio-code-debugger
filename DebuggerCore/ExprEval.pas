unit ExprEval;
// Recursive-descent expression evaluator for the Win64 DAP adapter.
//
// Grammar (current):
//   Expr    := Unary
//   Unary   := '@' Primary        -- address-of
//             | '[' Expr ']'      -- memory dereference
//             | Primary Suffix*
//   Primary := IntLiteral | '(' Expr ')' | Ident
//   Suffix  := '[' Expr ']'       -- string char or dynarray element (step 1)
//            | '.' Ident          -- field/property (step 2, RTTI-driven)
//
// Binary operators and function calls are deferred (see PROJECT_STATE.md).

interface

uses
  System.SysUtils, System.Math,
  DebugInfoTypes, DebugInfoSet, DebugTarget, DelphiRtti, DapProtocol;

type
  TExprValue = record
    TypeHint:     string;   // Delphi type name, or error message when IsValid=False
    TypeInfoAddr: UInt64;   // PTypeInfo in debuggee; 0 when unknown
    Address:      UInt64;   // lvalue address in debuggee; 0 for rvalues
    RawValue:     UInt64;   // up to 8 bytes of value data
    Size:         Integer;  // logical byte size (1, 2, 4, 8)
    IsValid:      Boolean;
    DerefPtr:     Boolean;  // True when this came from a var/reference param:
                            // Address holds the underlying pointer, RawValue the
                            // pointee. Indexing a `^X` base must use Address.
    IsSet:        Boolean;  // True for a Pascal set value (RawValue is a bitmask);
                            // drives set-aware +, -, * in ApplyArith.
    IsTypeRef:    Boolean;  // True when this is a bare TYPE reference (a class /
                            // type name used as a value), not an instance. Drives
                            // class-reference member access: `TFoo.ClassMethod`.
    IsIntLiteral: Boolean;  // True for an integer literal written in the
                            // expression. Such a literal is typed Int64 for
                            // storage, but that says nothing about the parameter
                            // it is being passed to -- and on a 32-bit target an
                            // Int64 argument occupies 8 stack bytes and no
                            // register slot, while an ordinal takes a register.
                            // Without the callee's declared parameter types, the
                            // literal's own magnitude is the only signal there is.
  end;

  TExprEvaluator = class
  private
    FDebugger:  IDebugTarget;
    FRtti:      TDelphiRtti;     // optional -- when nil, runtime VMT introspection disabled
    FDebugInfo: TDebugInfoSet;   // optional -- when present, RSM-driven member resolution
    FExpr:      string;
    FPos:       Integer;

    // Tokenizer
    procedure SkipWS;
    function  CurChar: Char;
    function  MatchChar(C: Char): Boolean;
    function  ScanIdent: string;
    function  ScanIntLiteral(out V: Int64): Boolean;

    // Recursive descent. Precedence (low -> high):
    //   ParseOr  := ParseAnd  ( ('or' | 'xor') ParseAnd  )*
    //   ParseAnd := ParseCmp  ( 'and'           ParseCmp  )*
    //   ParseCmp := ParseAdd  ( cmpOp           ParseAdd  )?
    //   ParseAdd := ParseMul  ( ('+' | '-')     ParseMul  )*
    //   ParseMul := ParseUnary( ('*' | '/' | 'div' | 'mod' | 'shl' | 'shr')
    //                                            ParseUnary )*
    //   ParseUnary  := '@' ParsePrimary
    //                | '[' ParseExpr ']'
    //                | '-' ParseUnary
    //                | 'not' ParseUnary
    //                | ParsePrimary Suffix*
    //   ParsePrimary := IntLit | FloatLit | StrLit | True | False | nil
    //                 | '(' ParseExpr ')' | Ident
    function  ParseExpr: TExprValue;
    function  ParseOr:   TExprValue;
    function  ParseAnd:  TExprValue;
    function  ParseCmp:  TExprValue;
    function  ParseAdd:  TExprValue;
    function  ParseMul:  TExprValue;
    function  ParseUnary: TExprValue;
    function  ParsePrimary: TExprValue;
    function  MatchKeyword(const KW: string): Boolean;
    function  ApplyArith(const L, R: TExprValue; const Op: string): TExprValue;
    function  ApplyBoolean(const L, R: TExprValue; const Op: string): TExprValue;
    function  ApplyCompare(const L, R: TExprValue; const Op: string): TExprValue;
    function  ConcatStrings(const L, R: TExprValue): TExprValue;
    function  MaskByType(V: UInt64; const T: string): Int64;
    function  IsFloatHint(const H: string): Boolean;
    function  AsDouble(const V: TExprValue): Double;
    function  AsInt64(const V: TExprValue): Int64;
    function  MakeBool(B: Boolean): TExprValue;
    function  MakeInt64(V: Int64): TExprValue;
    function  MakeDouble(V: Double): TExprValue;
    function  MakePointer(V: UInt64): TExprValue;
    function  TryResolveEnumLiteral(const Name: string;
                out Ordinal: Integer; out EnumTypeName: string): Boolean;
    function  LooksLikeSetLiteral: Boolean;
    function  ParseSetLiteral: TExprValue;
    function  IsKnownTypeName(const Name: string): Boolean;
    function  ApplyCast(const TypeName: string; const V: TExprValue): TExprValue;
    function  IsBuiltinIntrinsic(const Name: string): Boolean;
    function  ApplyIntrinsic(const Name: string;
                const Args: TArray<TExprValue>): TExprValue;
    function  ParseStringLiteral(out S: string): Boolean;
    function  ApplySuffixes(const Base: TExprValue): TExprValue;
    function  ApplyIndex(const Base: TExprValue; Idx: Int64): TExprValue;
    // Distinguishes a real dynamic array from a bare pointer-to-element by
    // looking for a live dyn-array header below the data pointer, which is the
    // only reliable signal: TD32 renders both as `^Element`.
    function  TryDynArrayCountFromHeader(DataPtr: UInt64; out Count: Int64): Boolean;
    // Stride of one array element. A record / set / static array element is
    // stored by value and is as wide as itself; everything else PrimTypeSize
    // does not recognise really is a pointer-sized handle.
    function  ElementStride(const ElemType: string): Integer;
    function  IsPointerSizedFallback(const TypeName: string): Boolean;
    // Record / set / static array: stored by value, so it is addressed rather
    // than lifted into an 8-byte RawValue.
    function  IsByValueAggregate(const TypeName: string): Boolean;
    // `Obj[X]` on a class instance: finds the class's `default` array property,
    // walking the ancestor chain (TStringList's default is TStrings.Strings).
    // False when the receiver is not an instance or no ancestor declares one.
    function  TryFindDefaultProperty(const Base: TExprValue;
                out PropName, DeclClass, PropType: string;
                out PropKind: Byte; out PropSize: Integer): Boolean;
    // True when `PropName` is a known INDEXED property of Base's class (or an
    // ancestor). Lets `obj.Prop[i]` skip the speculative zero-argument getter
    // call: if the member is indexed, `[i]` is its argument, full stop. On a hit
    // `PropType` is its declared return type, passed on so the call decodes the
    // result by the DECLARED type rather than guessing from the getter's locals.
    function  IsKnownIndexedProperty(const Base: TExprValue;
                const PropName: string; out PropType: string;
                out PropKind: Byte; out PropSize: Integer): Boolean;
    function  ApplyVarArrayIndex(const Base: TExprValue; const Indices: TArray<Int64>): TExprValue;
    // Static Pascal array `array[lo..hi, ...] of T` (possibly multi-dim).
    function  IsStaticArrayHint(const H: string): Boolean;
    function  ParseStaticArrayDims(const H: string;
                out Los, His: TArray<Integer>; out ElemType: string): Boolean;
    function  ApplyStaticArrayIndex(const Base: TExprValue;
                const Indices: TArray<Int64>): TExprValue;
    function  ApplyDot(const Base: TExprValue; const Field: string): TExprValue;
    function  ApplyMethodCall(const Base: TExprValue; const MethodName: string;
                const Args: TArray<TExprValue>;
                const ExplicitClass: string = '';
                const ReturnTypeHint: string = '';
                ClassRefSelf: UInt64 = 0;
                ForceClassMethod: Boolean = False;
                Speculative: Boolean = False;
                // Deterministic return-type kind/size, resolved by the debug-info
                // provider from the member's EXACT type id. When non-zero they are
                // authoritative over ReturnTypeHint (a name, first-wins-ambiguous):
                // ReturnKindHint drives the RAX/XMM0/var-out ABI choice and
                // ReturnSizeHint sizes the var-out slot for a record/set return.
                ReturnKindHint: Byte = 0;
                ReturnSizeHint: Integer = 0): TExprValue;
    // `TClassName.Member[(args)]` on a bare class reference (Base.IsTypeRef).
    // Invokes a class method / class function with Self = the class VMT.
    function  ApplyClassRefMember(const ClassName, Member: string;
                const Args: TArray<TExprValue>): TExprValue;

    // Memory helpers
    function  ReadU8 (Addr: UInt64; out V: Byte):    Boolean;
    function  ReadU16(Addr: UInt64; out V: Word):    Boolean;
    function  ReadU32(Addr: UInt64; out V: Cardinal): Boolean;
    function  ReadU64(Addr: UInt64; out V: UInt64):  Boolean;
    function  ReadDynArrayLength(DataPtr: UInt64; out Len: UInt64): Boolean;

    // Value construction
    function  InvalidValue(const Msg: string): TExprValue;
    function  LocalToExpr(const L: TLocalValue): TExprValue;
    function  ResolveIdent(const Name: string): TExprValue;
    function  TryGetRegister(const Regs: TRegisterSnapshot; const Name: string;
                out Val: UInt64): Boolean;

    // Type helpers
    function  IsStringTypeHint(const H: string): Boolean;
    function  IsWideStringHint(const H: string): Boolean;
    function  PrimTypeSize(const TypeName: string): Integer;
    function  TryArrayElemInfo(const TypeHint: string;
                out ElemType: string; out ElemSize: Integer): Boolean;

    // Maps a Delphi type name (resolved through the RSM type tables) to
    // the runtime TypeKind used by the Win64 ABI return-class dispatch
    // (`InvokeGetter` / `ApplyMethodCall` need this to pick RAX vs XMM0
    // vs hidden var-out result slot). Names are matched case-insensitively
    // against the System unit's primitive set; anything else returns
    // TK_UNKNOWN and the caller picks a safe default.
    function  TypeNameToKind(const TypeName: string): Byte;
    // True when a value of this type is passed/returned in an XMM register
    // (Single/Double/Extended/TDateTime/float aliases; NOT Currency). Resolves
    // the kind so aliases are not missed. Used for both argument marshalling and
    // the return-class heuristic so the two cannot drift.
    function  IsFloatValueHint(const TypeHint: string): Boolean;
    // Classifies one synthetic-call argument for the target's calling
    // convention. Resolves through the same TypeNameToKind as IsFloatValueHint,
    // so the two cannot disagree about what counts as a float.
    function  SyntheticArgKindOf(const V: TExprValue): TSyntheticArgKind;
    // Reads a value into the 8-byte RawValue every formatter decodes from,
    // routing the float types that do not fit that slot through the shared
    // reader. FallbackSize comes from the CALLER because SizeForKind and
    // PrimTypeSize know record and set widths that LocalReadSize does not.
    function  ReadValueAt(Addr: UInt64; const TypeName: string;
                FallbackSize: Integer; out Raw: UInt64): Boolean;
    // Converts a float-class return from the TARGET's wire encoding into the
    // raw encoding the value formatters expect (see AsDouble). Called from
    // every site that lifts a float result so the two cannot drift.
    function  NormaliseFloatReturn(FloatBits: UInt64; const TypeName: string): UInt64;
    // True when this target returns Currency alongside the floats rather than
    // as a scaled Int64 in an integer register.
    function  CurrencyReturnsWithFloats: Boolean;

  public
    constructor Create(const Debugger: IDebugTarget; Rtti: TDelphiRtti = nil;
                       DebugInfo: TDebugInfoSet = nil);
    function Evaluate(const Expr: string; out Val: TExprValue): Boolean;
  end;

implementation

uses
  DelphiValueReaders;   // WideFloatByteSize / ReadValueSlotRaw for the float
                        // types that do not fit the 8-byte value slot

{ TExprEvaluator }

constructor TExprEvaluator.Create(const Debugger: IDebugTarget; Rtti: TDelphiRtti;
  DebugInfo: TDebugInfoSet);
begin
  inherited Create;
  FDebugger  := Debugger;
  FRtti      := Rtti;
  FDebugInfo := DebugInfo;
end;

{ Tokenizer }

procedure TExprEvaluator.SkipWS;
begin
  while (FPos <= Length(FExpr)) and CharInSet(FExpr[FPos], [' ', #9]) do
    Inc(FPos);
end;

function TExprEvaluator.CurChar: Char;
begin
  SkipWS;
  if FPos <= Length(FExpr) then
    Result := FExpr[FPos]
  else
    Result := #0;
end;

function TExprEvaluator.MatchChar(C: Char): Boolean;
begin
  Result := CurChar = C;
  if Result then Inc(FPos);
end;

// Scans a single identifier. Dots are NOT consumed -- they are picked up by
// `ApplySuffixes` as the `.` field-access operator. Stops before any other
// non-identifier character (whitespace, brackets, operators, dots).
function TExprEvaluator.ScanIdent: string;
var
  Start: Integer;
begin
  SkipWS;
  Start := FPos;
  while (FPos <= Length(FExpr)) and
        CharInSet(FExpr[FPos], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    Inc(FPos);
  Result := Copy(FExpr, Start, FPos - Start);
end;

function TExprEvaluator.ScanIntLiteral(out V: Int64): Boolean;
var
  Start: Integer;
  S:     string;
  Code:  Integer;
begin
  SkipWS;
  Start := FPos;
  // $HEX
  if CurChar = '$' then begin
    Inc(FPos);
    while (FPos <= Length(FExpr)) and
          CharInSet(FExpr[FPos], ['0'..'9', 'A'..'F', 'a'..'f']) do
      Inc(FPos);
    S := Copy(FExpr, Start, FPos - Start);
  end
  // 0xHEX
  else if (CurChar = '0') and (FPos + 1 <= Length(FExpr)) and
          CharInSet(FExpr[FPos + 1], ['x', 'X']) then begin
    Inc(FPos, 2);
    while (FPos <= Length(FExpr)) and
          CharInSet(FExpr[FPos], ['0'..'9', 'A'..'F', 'a'..'f']) do
      Inc(FPos);
    S := '$' + Copy(FExpr, Start + 2, FPos - Start - 2);
  end
  // Decimal
  else if CharInSet(CurChar, ['0'..'9']) then begin
    while (FPos <= Length(FExpr)) and CharInSet(FExpr[FPos], ['0'..'9']) do
      Inc(FPos);
    S := Copy(FExpr, Start, FPos - Start);
  end else begin
    Result := False;
    Exit;
  end;
  Val(S, V, Code);
  Result := (Code = 0) and (FPos > Start);
end;

{ Memory helpers }

function TExprEvaluator.ReadU8(Addr: UInt64; out V: Byte): Boolean;
begin
  Result := FDebugger.ReadProcessMemoryAt(Addr, @V, 1);
end;

function TExprEvaluator.ReadU16(Addr: UInt64; out V: Word): Boolean;
begin
  Result := FDebugger.ReadProcessMemoryAt(Addr, @V, 2);
end;

function TExprEvaluator.ReadU32(Addr: UInt64; out V: Cardinal): Boolean;
begin
  Result := FDebugger.ReadProcessMemoryAt(Addr, @V, 4);
end;

function TExprEvaluator.ReadU64(Addr: UInt64; out V: UInt64): Boolean;
begin
  Result := FDebugger.ReadProcessMemoryAt(Addr, @V, 8);
end;

// Reads a dynamic array's element count from the header below its data
// pointer. Both the offset and the width are bitness-dependent, so this cannot
// go through ReadU64: on a 32-bit target the length is a 4-byte NativeInt at
// data-4, and reading 8 bytes at data-8 would splice the refcount into it.
function TExprEvaluator.ReadDynArrayLength(DataPtr: UInt64; out Len: UInt64): Boolean;
begin
  Len := 0;
  var Layout := FDebugger.TargetLayout;
  Result := FDebugger.ReadProcessMemoryAt(Layout.DynArrayLengthAddr(DataPtr),
              @Len, Layout.DynArrayLengthSize);
end;

// True when a live dynamic-array header sits below DataPtr, in which case Count
// is its element count. Used to tell a real dynamic array from a bare
// pointer-to-element when the NAME cannot: TD32 renders both as `^Element`.
//
// The same sanity test the dyn-array formatter applies, and for the same reason
// -- an arbitrary pointer has SOMETHING at ptr-8, so the value only counts as a
// header when both fields are self-consistent: a length within a sane range and
// a refcount that is either -1 (a constant/literal array) or a live count.
function TExprEvaluator.TryDynArrayCountFromHeader(DataPtr: UInt64;
  out Count: Int64): Boolean;
const
  MAX_PLAUSIBLE_LEN = 1 shl 24;
begin
  Count  := 0;
  Result := False;
  if DataPtr < 65536 then
    Exit;
  var Len: UInt64;
  if not ReadDynArrayLength(DataPtr, Len) then
    Exit;
  if Int64(Len) > MAX_PLAUSIBLE_LEN then
    Exit;
  var RefCnt: Int32 := 0;
  if not FDebugger.ReadProcessMemoryAt(
           FDebugger.TargetLayout.DynArrayRefCountAddr(DataPtr), @RefCnt, 4) then
    Exit;
  if not ((RefCnt = -1) or ((RefCnt >= 1) and (RefCnt <= MAX_PLAUSIBLE_LEN))) then
    Exit;
  Count  := Int64(Len);
  Result := True;
end;

{ Value construction }

function TExprEvaluator.InvalidValue(const Msg: string): TExprValue;
begin
  Result          := Default(TExprValue);
  Result.TypeHint := Msg;
  Result.IsValid  := False;
end;

function TExprEvaluator.LocalToExpr(const L: TLocalValue): TExprValue;
begin
  Result          := Default(TExprValue);
  Result.TypeHint := L.TypeHint;
  Result.Size     := 8;
  if L.Kind = lkVarParam then begin
    // Dereference transparently: the slot holds a pointer; we present the pointee.
    Result.Address  := L.RawValue;
    Result.RawValue := L.DerefValue;
    Result.IsValid  := L.DerefValid;
    Result.DerefPtr := True;
  end else begin
    Result.Address  := L.Address;
    Result.RawValue := L.RawValue;
    Result.IsValid  := L.ValueValid;
  end;
end;

function TExprEvaluator.TryGetRegister(const Regs: TRegisterSnapshot;
  const Name: string; out Val: UInt64): Boolean;
begin
  Result := True;
  if      SameText(Name, 'rip') then Val := Regs.Rip
  else if SameText(Name, 'rsp') then Val := Regs.Rsp
  else if SameText(Name, 'rbp') then Val := Regs.Rbp
  else if SameText(Name, 'rax') then Val := Regs.Rax
  else if SameText(Name, 'rbx') then Val := Regs.Rbx
  else if SameText(Name, 'rcx') then Val := Regs.Rcx
  else if SameText(Name, 'rdx') then Val := Regs.Rdx
  else if SameText(Name, 'rsi') then Val := Regs.Rsi
  else if SameText(Name, 'rdi') then Val := Regs.Rdi
  else if SameText(Name, 'r8')  then Val := Regs.R8
  else if SameText(Name, 'r9')  then Val := Regs.R9
  else if SameText(Name, 'r10') then Val := Regs.R10
  else if SameText(Name, 'r11') then Val := Regs.R11
  else if SameText(Name, 'r12') then Val := Regs.R12
  else if SameText(Name, 'r13') then Val := Regs.R13
  else if SameText(Name, 'r14') then Val := Regs.R14
  else if SameText(Name, 'r15') then Val := Regs.R15
  else Result := False;
end;

function TExprEvaluator.ResolveIdent(const Name: string): TExprValue;
var
  LV:     TLocalValue;
  SelfLV: TLocalValue;
  Regs:   TRegisterSnapshot;
  RegVal: UInt64;
begin
  // Registers (case-insensitive)
  Regs := FDebugger.GetRegisters;
  if Regs.Valid and TryGetRegister(Regs, Name, RegVal) then begin
    Result          := Default(TExprValue);
    Result.TypeHint := 'UInt64';
    Result.RawValue := RegVal;
    Result.Size     := 8;
    Result.IsValid  := True;
    Exit;
  end;

  // Resolution order, per Delphi scoping rules:
  //   1) locals (incl. parent-frame short names)
  //   2) Self.<Name> when inside a method
  //   3) globals / public symbols
  // Without step (2), hovering on a form's component (e.g. `chkInvMagH24`
  // inside `TfrmTabStores.Create`) returns "not found" even though
  // the field exists; with it, bare field references inside a method
  // resolve through the implicit Self the same way the Delphi compiler does.
  if FDebugger.EvaluateLocalName(Name, LV) then
    Exit(LocalToExpr(LV));

  if not SameText(Name, 'Self') and FDebugger.EvaluateLocalName('Self', SelfLV) then begin
    Result := ApplyDot(LocalToExpr(SelfLV), Name);
    if Result.IsValid then
      Exit;
  end;

  // A bare free FUNCTION that declares parameters cannot be auto-called: Delphi
  // would require the arguments. Refuse it here, up front -- before the
  // speculative zero-arg call (which would read garbage argument registers) AND
  // before the global fallback (which would return the function's code address
  // read as raw prologue bytes). The declared arity comes from the LF_PROCEDURE
  // signature; a parameterless function (count 0) is unaffected, so `Now` still
  // calls. Unknown arity falls through unchanged.
  if FDebugInfo <> nil then begin
    var DeclaredParamCount: Integer;
    if FDebugInfo.TryGetFreeFunctionParamCount(Name, DeclaredParamCount) and
       (DeclaredParamCount > 0) then
      Exit(InvalidValue(Format('<%s requires %d argument(s)>',
        [Name, DeclaredParamCount])));
  end;

  // 3) Parameterless free-function call BEFORE the global lookup. In Delphi a
  // bare function name IS a call (`Now` = `Now()`), so it must be invoked, not
  // resolved to the function's code address (which EvaluateGlobalName's
  // code-resident fallback would otherwise return, read as raw bytes). A
  // non-function name fails here cheaply and falls through to the global.
  var EmptyArgs: TArray<TExprValue>;
  SetLength(EmptyArgs, 0);
  Result := ApplyMethodCall(Default(TExprValue), Name, EmptyArgs,
    '', '', 0, False, {Speculative=}True);
  if Result.IsValid then Exit;

  // 4) Data global / public symbol.
  if FDebugger.EvaluateGlobalName(Name, LV) then
    Exit(LocalToExpr(LV));

  // 5) Named constant (inlined `const X = 1` -- no storage; value from the RSM
  // `$25` records, scoped to the frame's uses).
  var ConstVal: Int64;
  var ConstType: string;
  if FDebugger.TryResolveConstValue(Name, ConstVal, ConstType) then begin
    Result := Default(TExprValue);
    Result.TypeHint := ConstType;
    Result.RawValue := UInt64(ConstVal);
    Result.Size     := PrimTypeSize(ConstType);
    if Result.Size = 0 then Result.Size := 4;
    Result.IsValid  := True;
    Exit;
  end;

  Result := InvalidValue(Format('<%s: not found>', [Name]));
end;

{ Type helpers }

function TExprEvaluator.IsStringTypeHint(const H: string): Boolean;
begin
  for var T in ['string', 'UnicodeString', 'WideString',
                'AnsiString', 'UTF8String', 'RawByteString'] do
    if SameText(H, T) then
      Exit(True);
  // `type string` aliases (TCaption, TFileName, ...) and any name the type
  // system reports as a string kind. Without this a getter/field typed as such
  // an alias is not deref'd as a string (shown as a raw pointer integer).
  if FDebugInfo <> nil then
    case FDebugInfo.LookupTypeKind(H) of
      TK_USTRING, TK_WSTRING, TK_LSTRING: Exit(True);
    end;
  Result := False;
end;

function TExprEvaluator.IsWideStringHint(const H: string): Boolean;
begin
  if SameText(H, 'string') or SameText(H, 'UnicodeString') or SameText(H, 'WideString') then
    Exit(True);
  // A string alias (TCaption, TFileName, TComponentName, ...) is 2-byte
  // UnicodeString, not narrow AnsiChar. Resolve the KIND so indexing reads a
  // WideChar: only TK_LSTRING (AnsiString family) is 1 byte. IsStringTypeHint,
  // which gates the caller, already follows these aliases.
  case TypeNameToKind(H) of
    TK_USTRING, TK_WSTRING: Result := True;
  else
    Result := False;
  end;
end;

// Stride of one ELEMENT of an array of TypeName. Differs from PrimTypeSize for
// exactly one family: a record, set or static array is stored BY VALUE, so its
// stride is its own width, while a string / class / interface / dynamic array
// element is a handle and really is pointer-sized.
//
// PrimTypeSize alone returned pointer size for every name it did not recognise,
// records included. Indexing a `TArray<TPackedRec>` (a 7-byte packed record)
// therefore walked in 8-byte steps on x64 and 4-byte steps on x86: element 0
// read correctly and every later element was skewed, silently, into the middle
// of its neighbour.
// True when a value of this type is stored BY VALUE rather than as a
// pointer-sized handle: a record, a set, or a static array. The families that
// need an Address rather than a RawValue.
function TExprEvaluator.IsByValueAggregate(const TypeName: string): Boolean;
begin
  Result := False;
  if (TypeName = '') or (FDebugInfo = nil) then
    Exit;
  if not IsPointerSizedFallback(TypeName) then
    Exit;   // a recognised primitive is never an aggregate
  Result := FDebugInfo.LookupTypeKind(TypeName) in
              [TK_RECORD, TK_MRECORD, TK_SET, TK_ARRAY];
end;

function TExprEvaluator.ElementStride(const ElemType: string): Integer;
begin
  Result := PrimTypeSize(ElemType);
  if not IsPointerSizedFallback(ElemType) then
    Exit;
  if FDebugInfo = nil then
    Exit;
  var Kind := FDebugInfo.LookupTypeKind(ElemType);
  if not (Kind in [TK_RECORD, TK_MRECORD, TK_SET, TK_ARRAY]) then
    Exit;
  var Sz: Integer;
  if FDebugInfo.GetTypeSize(ElemType, Sz) and (Sz > 0) then
    Result := Sz;
end;

// True when PrimTypeSize did not RECOGNISE the name and fell through to its
// pointer-sized default, as opposed to a type that is genuinely pointer-sized.
function TExprEvaluator.IsPointerSizedFallback(const TypeName: string): Boolean;
begin
  for var Known in ['Byte', 'ShortInt', 'Boolean', 'AnsiChar', 'ByteBool',
                    'Word', 'SmallInt', 'Char', 'WideChar', 'WordBool',
                    'Integer', 'LongInt', 'Cardinal', 'LongWord', 'Single',
                    'LongBool', 'Int64', 'UInt64', 'QWord', 'Double',
                    'Currency', 'Comp', 'Extended', 'Real', 'TDateTime',
                    'TDate', 'TTime'] do
    if SameText(TypeName, Known) then
      Exit(False);
  Result := True;
end;

function TExprEvaluator.PrimTypeSize(const TypeName: string): Integer;
begin
  if SameText(TypeName, 'Byte')     or SameText(TypeName, 'ShortInt')  or
     SameText(TypeName, 'Boolean')  or SameText(TypeName, 'AnsiChar')  or
     SameText(TypeName, 'ByteBool') then
    Exit(1);
  if SameText(TypeName, 'Word')     or SameText(TypeName, 'SmallInt')  or
     SameText(TypeName, 'Char')     or SameText(TypeName, 'WideChar')  or
     SameText(TypeName, 'WordBool') then
    Exit(2);
  if SameText(TypeName, 'Integer')  or SameText(TypeName, 'LongInt')   or
     SameText(TypeName, 'Cardinal') or SameText(TypeName, 'LongWord')  or
     SameText(TypeName, 'Single')   or SameText(TypeName, 'LongBool')  then
    Exit(4);
  // Genuinely 8 bytes on both architectures.
  if SameText(TypeName, 'Int64')  or SameText(TypeName, 'UInt64')   or
     SameText(TypeName, 'QWord')  or SameText(TypeName, 'Double')   or
     SameText(TypeName, 'Currency') or SameText(TypeName, 'Comp')   or
     SameText(TypeName, 'Extended') or SameText(TypeName, 'Real')   or
     SameText(TypeName, 'TDateTime') or SameText(TypeName, 'TDate') or
     SameText(TypeName, 'TTime') then
    Exit(8);
  // Everything else reaching here is a pointer-sized handle -- a string, class,
  // interface, dynamic array or plain pointer -- or a type we could not
  // identify. That is 4 bytes on a 32-bit target, where reading 8 folds the
  // neighbouring slot into the high half and turns a valid string handle into
  // an address outside the process.
  Result := FDebugger.TargetLayout.PointerSize;
end;

// Recognises "array of X" and "TArray<X>" (with optional "System." prefix).
// ElemSize defaults to 8 for unknown element types (safe: read as raw pointer).
function TExprEvaluator.TryArrayElemInfo(const TypeHint: string;
  out ElemType: string; out ElemSize: Integer): Boolean;
var
  Inner: string;
begin
  if TypeHint.StartsWith('array of ', True) then begin
    Inner    := Trim(TypeHint.Substring(9));
    ElemType := Inner;
    ElemSize := ElementStride(Inner);
    Exit(True);
  end;
  if TypeHint.StartsWith('TArray<', True) and TypeHint.EndsWith('>') then begin
    Inner := TypeHint.Substring(7, TypeHint.Length - 8);
    if Inner.StartsWith('System.', True) then
      Inner := Inner.Substring(7);
    ElemType := Inner;
    ElemSize := ElementStride(Inner);
    Exit(True);
  end;
  // TD32 emits dynamic arrays as `^Element` (pointer-to-element) when no
  // explicit type name is registered. Treat `^Primitive` as a dynarray
  // when the user applies `[...]` -- the genuine pointer-to-primitive
  // case is reachable via the `^` deref operator instead.
  if (Length(TypeHint) >= 2) and (TypeHint[1] = '^') then begin
    Inner := Copy(TypeHint, 2, MaxInt);
    var Sz := ElementStride(Inner);
    if Sz > 0 then begin
      ElemType := Inner;
      ElemSize := Sz;
      Exit(True);
    end;
  end;
  Result   := False;
  ElemType := '';
  ElemSize := 0;
end;

{ TypeName -> TypeKind (System primitives only) }

function TExprEvaluator.IsFloatValueHint(const TypeHint: string): Boolean;
begin
  // A floating-point value goes into an XMM register on the Win64 ABI. Decided
  // by the resolved KIND, not a fixed name list: TypeNameToKind knows TDateTime,
  // TDate, TTime and follows a `type TRate = type Double` alias, all of which
  // the old SameText('Single'/'Double'/'Extended') missed - sending the bits to
  // an integer register and leaving XMM 0. Currency is TK_FLOAT but ABI-wise a
  // scaled Int64 in an integer register, so it is excluded.
  if SameText(TypeHint, 'Currency') then
    Exit(False);
  Result := TypeNameToKind(TypeHint) = TK_FLOAT;
end;

// Classifies one synthetic-call argument for the target's calling convention.
// Sits next to IsFloatValueHint and resolves through the same TypeNameToKind, so
// the two cannot disagree about what counts as a float.
//
// Currency is deliberately sakInt64 rather than a float kind: as an ARGUMENT it
// is just its scaled Int64, on both architectures. (As a RESULT it does travel
// with the floats on x86 -- see CurrencyReturnsWithFloats. The two directions
// genuinely differ.)
// Reading the low 8 of an Extended's 10 bytes keeps the MANTISSA and drops the
// EXPONENT. For 0.125 the mantissa is $8000000000000000, which reads back as
// -0.0 and displays as a perfectly innocent "0" -- no error, no clue.
function TExprEvaluator.ReadValueAt(Addr: UInt64; const TypeName: string;
  FallbackSize: Integer; out Raw: UInt64): Boolean;
begin
  Raw := 0;
  var PtrSize := FDebugger.TargetLayout.PointerSize;
  if WideFloatByteSize(TypeName, PtrSize) <> 0 then
    Exit(ReadValueSlotRaw(
      function(A: UInt64; Dest: Pointer; Sz: Integer): Boolean
      begin
        Result := FDebugger.ReadProcessMemoryAt(A, Dest, Sz);
      end,
      Addr, TypeName, PtrSize, Raw));
  Result := FDebugger.ReadProcessMemoryAt(Addr, @Raw, Min(FallbackSize, 8));
end;

function TExprEvaluator.SyntheticArgKindOf(const V: TExprValue): TSyntheticArgKind;
begin
  if SameText(V.TypeHint, 'Single') then
    Exit(sakSingle);
  if SameText(V.TypeHint, 'Extended') or SameText(V.TypeHint, 'Extended80') then
    Exit(sakExtended);
  for var Name in ['Int64', 'UInt64', 'QWord', 'Currency', 'Comp'] do
    if SameText(V.TypeHint, Name) then begin
      // An integer LITERAL is typed Int64 for storage, which says nothing about
      // the parameter it is passed to -- and the two differ sharply on x86,
      // where an Int64 takes 8 stack bytes and no register slot while an
      // ordinal takes a register. `Foo(3)` almost always means an ordinal
      // parameter, so a literal that fits 32 bits is passed as one; one that
      // does not could only be an Int64. A literal genuinely meant for an
      // Int64 parameter but small enough to fit 32 bits is the case this gets
      // wrong, and it is exactly the case the code got wrong before too -- the
      // real fix is the callee's declared parameter types, which the debug info
      // does not currently surface.
      if V.IsIntLiteral and (Int64(V.RawValue) >= Low(Integer)) and
         (Int64(V.RawValue) <= High(Integer)) then
        Exit(sakOrdinal);
      Exit(sakInt64);
    end;
  if IsFloatValueHint(V.TypeHint) then
    Exit(sakDouble);        // Double, Real, TDateTime, TDate, TTime, aliases
  Result := sakOrdinal;
end;

function TExprEvaluator.CurrencyReturnsWithFloats: Boolean;
begin
  // An x87 target returns every float-family type on the FPU stack, Currency
  // included; an SSE target keeps Currency in an integer register.
  Result := FDebugger.TargetLayout.FloatResultsUseX87;
end;

// The formatters in AsDouble read three different raw encodings depending on the
// declared type:
//
//   Single   -> the 4-byte Single bit pattern
//   Currency -> the scaled Int64 it then divides by 10000
//   others   -> the 8-byte Double bit pattern
//
// On an SSE target XMM0 already holds exactly those, so this is the identity.
// An x87 target returns EVERYTHING in ST(0) and the debugger converts the
// 80-bit register to Double bits on the way out, so both special cases have to
// be undone here -- otherwise a Single reads as 0 (the low half of a Double is
// all zeroes for a value that narrows exactly) and a Currency reads as a
// nonsense trillions figure.
//
// MEASURED, not assumed: DevTools\Win32FloatAbiProbe reports Currency arriving
// in ST(0) already SCALED (19.95 -> 199500), which is why rounding that value
// is the whole conversion and no further scaling is applied.
function TExprEvaluator.NormaliseFloatReturn(FloatBits: UInt64;
  const TypeName: string): UInt64;
begin
  Result := FloatBits;
  if not FDebugger.TargetLayout.FloatResultsUseX87 then
    Exit;
  var Value: Double := 0;
  PUInt64(@Value)^ := FloatBits;
  if SameText(TypeName, 'Single') then begin
    var Narrowed: Single := Value;
    Result := PCardinal(@Narrowed)^;
  end
  else if SameText(TypeName, 'Currency') then
    Result := UInt64(Round(Value));
end;

function TExprEvaluator.TypeNameToKind(const TypeName: string): Byte;
begin
  // Integers / cardinals
  if SameText(TypeName, 'Integer')   or SameText(TypeName, 'Cardinal')  or
     SameText(TypeName, 'LongInt')   or SameText(TypeName, 'LongWord')  or
     SameText(TypeName, 'SmallInt')  or SameText(TypeName, 'Word')      or
     SameText(TypeName, 'ShortInt')  or SameText(TypeName, 'Byte')      then
    Exit(TK_INTEGER);
  if SameText(TypeName, 'Int64')     or SameText(TypeName, 'UInt64')    or
     SameText(TypeName, 'NativeInt') or SameText(TypeName, 'NativeUInt') then
    Exit(TK_INT64);
  if SameText(TypeName, 'Boolean')   or SameText(TypeName, 'ByteBool')  or
     SameText(TypeName, 'WordBool')  or SameText(TypeName, 'LongBool')  then
    Exit(TK_ENUM);
  // Floats -- TDateTime is a Double alias on the wire
  if SameText(TypeName, 'Single')    or SameText(TypeName, 'Double')    or
     SameText(TypeName, 'Extended')  or SameText(TypeName, 'TDateTime') then
    Exit(TK_FLOAT);
  if SameText(TypeName, 'Currency') then
    Exit(TK_FLOAT);    // ABI: scaled Int64 -> caller treats as RAX, not XMM0
  // Characters
  if SameText(TypeName, 'AnsiChar') then
    Exit(TK_CHAR);
  if SameText(TypeName, 'WideChar')  or SameText(TypeName, 'Char') then
    Exit(TK_WCHAR);
  // Strings
  if SameText(TypeName, 'string')    or SameText(TypeName, 'UnicodeString') then
    Exit(TK_USTRING);
  if SameText(TypeName, 'WideString') then
    Exit(TK_WSTRING);
  if SameText(TypeName, 'AnsiString')   or SameText(TypeName, 'UTF8String') or
     SameText(TypeName, 'RawByteString') then
    Exit(TK_LSTRING);
  // Other managed
  if SameText(TypeName, 'Variant')   or SameText(TypeName, 'OleVariant') then
    Exit(TK_VARIANT);
  if SameText(TypeName, 'Pointer') then
    Exit(TK_POINTER);
  // TArray<...>: dynamic array
  if TypeName.StartsWith('TArray<', True) or TypeName.StartsWith('array of ', True) then
    Exit(TK_DYNARRAY);
  // Unknown by name: consult the aggregated type system. TD32 collapses a
  // `type string` alias to a string kind; DebugInfoSet maps the well-known RTL
  // string aliases (TCaption, ...). This lets getter-ABI dispatch route e.g. a
  // `Caption: TCaption read GetText` getter through the managed var-out path
  // instead of mis-reading the result as an integer in RAX.
  if FDebugInfo <> nil then
    Exit(FDebugInfo.LookupTypeKind(TypeName));
  Result := TK_UNKNOWN;
end;

{ Indexing }

function TExprEvaluator.TryFindDefaultProperty(const Base: TExprValue;
  out PropName, DeclClass, PropType: string;
  out PropKind: Byte; out PropSize: Integer): Boolean;
begin
  Result    := False;
  PropName  := '';
  DeclClass := '';
  PropType  := '';
  PropKind  := 0;
  PropSize  := 0;
  if (FRtti = nil) or (FDebugInfo = nil) or (not Base.IsValid) then
    Exit;
  if not FRtti.IsClassInstance(Base.RawValue) then
    Exit;

  for var ClassName in FRtti.GetClassChainNames(Base.RawValue) do begin
    var Members: TArray<TClassMember>;
    if not FDebugInfo.GetClassMembers(ClassName, Members) then
      Continue;
    for var M in Members do
      if (M.Kind = cmkProperty) and M.IsDefaultProperty and (M.Name <> '') then begin
        PropName := M.Name;
        PropType := M.TypeName;
        PropKind := M.TypeKind;
        PropSize := M.TypeSize;
        // The member list of a class already includes its inherited members, so
        // the flag may be found while scanning a descendant. Dispatch against
        // the class that DECLARES it when that is known, since the getter's
        // symbol lives there.
        if M.DeclClass <> '' then
          DeclClass := M.DeclClass
        else
          DeclClass := ClassName;
        Exit(True);
      end;
  end;
end;

function TExprEvaluator.IsKnownIndexedProperty(const Base: TExprValue;
  const PropName: string; out PropType: string;
  out PropKind: Byte; out PropSize: Integer): Boolean;
begin
  Result   := False;
  PropType := '';
  PropKind := 0;
  PropSize := 0;
  if (FRtti = nil) or (FDebugInfo = nil) or (not Base.IsValid) then
    Exit;
  if not FRtti.IsClassInstance(Base.RawValue) then
    Exit;
  for var ClassName in FRtti.GetClassChainNames(Base.RawValue) do begin
    var Members: TArray<TClassMember>;
    if not FDebugInfo.GetClassMembers(ClassName, Members) then
      Continue;
    for var M in Members do begin
      if (M.Kind <> cmkProperty) or not SameText(M.Name, PropName) then
        Continue;
      if M.IsIndexed then begin
        PropType := M.TypeName;
        PropKind := M.TypeKind;
        PropSize := M.TypeSize;
        Exit(True);
      end;
      // IsIndexed can be lost when the class FIELDLIST is empty (RSM fallback /
      // a BPL type). A getter that TAKES parameters is an indexed property just
      // the same: `[...]` are its arguments, not a post-index of its result.
      if M.GetterName <> '' then begin
        var GParams: TArray<TMethodParam>;
        var GHasSelf: Boolean;
        if FDebugInfo.TryGetMethodParams(ClassName, M.GetterName, GParams, GHasSelf) and
           (Length(GParams) > 0) then begin
          PropType := M.TypeName;
          PropKind := M.TypeKind;
          PropSize := M.TypeSize;
          Exit(True);
        end;
      end;
    end;
  end;
end;

function TExprEvaluator.ApplyIndex(const Base: TExprValue; Idx: Int64): TExprValue;
var
  DataPtr:  UInt64;
  ElemType: string;
  ElemSize: Integer;
  ElemAddr: UInt64;
  ElemRaw:  UInt64;
  IsWide:   Boolean;
  LenVal:   Cardinal;
  ArrLen:   UInt64;
begin
  if not Base.IsValid then
    Exit(Base);

  DataPtr := Base.RawValue;
  if DataPtr = 0 then
    Exit(InvalidValue('<nil pointer>'));

  // String: 1-based Delphi indexing; length at DataPtr[-4] (Longint, in chars)
  if IsStringTypeHint(Base.TypeHint) then begin
    IsWide := IsWideStringHint(Base.TypeHint);
    if not ReadU32(DataPtr - 4, LenVal) then
      Exit(InvalidValue('<cannot read string length>'));
    if (Idx < 1) or (Idx > Int64(LenVal)) then
      Exit(InvalidValue(Format('<index %d out of bounds [1..%d]>', [Idx, LenVal])));

    ElemAddr := DataPtr + UInt64((Idx - 1) * IfThen(IsWide, 2, 1));
    Result   := Default(TExprValue);
    Result.Address := ElemAddr;
    Result.IsValid := True;
    if IsWide then begin
      var Ch: Word;
      if not ReadU16(ElemAddr, Ch) then
        Exit(InvalidValue('<char read failed>'));
      Result.TypeHint := 'Char';
      Result.RawValue := Ch;
      Result.Size     := 2;
    end else begin
      var Ch: Byte;
      if not ReadU8(ElemAddr, Ch) then
        Exit(InvalidValue('<char read failed>'));
      Result.TypeHint := 'AnsiChar';
      Result.RawValue := Ch;
      Result.Size     := 1;
    end;
    Exit;
  end;

  // Dynamic array: 0-based; length at DataPtr[-8] (NativeInt = Int64 on Win64).
  if TryArrayElemInfo(Base.TypeHint, ElemType, ElemSize) then begin
    // Every array form indexed here is 0-based, so a negative index is wrong
    // whatever the base turns out to be. Rejecting it up front matters because
    // the bytes BELOW the data pointer are the array's own header: `A[-1]`
    // returned the length field as if it were an element.
    if Idx < 0 then
      Exit(InvalidValue(Format('<index %d out of bounds (arrays are 0-based)>', [Idx])));

    // Pointer-to-element (`^X`) covers open-array parameters, which Delphi
    // passes as a bare (ptr, high) pair with NO dyn-array length header at
    // ptr-8, so their bounds genuinely are not in scope here.
    //
    // But a real DYNAMIC array reaches this branch too: TD32 has no dyn-array
    // encoding and renders `TArray<Integer>` as `^Integer`, indistinguishable
    // BY NAME from a pointer. Skipping the check for both meant `Scores[3]` on
    // a 3-element array returned a plausible integer from past the end and
    // `Scores[-1]` returned the length -- silently wrong values, not errors.
    //
    // So ask memory instead of the name: if a valid dyn-array header sits below
    // the data pointer, the base IS a dynamic array and its bounds apply. An
    // open array fails that test (whatever precedes it is unrelated data) and
    // keeps the previous unchecked behaviour, so this can only add rejections
    // that were genuine errors.
    var IsPtrToElem := (Base.TypeHint <> '') and (Base.TypeHint[1] = '^');
    if IsPtrToElem then begin
      // A var/reference-param base presents the pointee in RawValue; the actual
      // data pointer is in Address. Use it so `A[i]` walks the array, not the
      // first element reinterpreted as an address.
      if Base.DerefPtr then
        DataPtr := Base.Address;
      var HeaderCount: Int64;
      if TryDynArrayCountFromHeader(DataPtr, HeaderCount) and (Idx >= HeaderCount) then
        Exit(InvalidValue(Format('<index %d out of bounds [0..%d]>',
          [Idx, HeaderCount - 1])));
    end else begin
      if not ReadDynArrayLength(DataPtr, ArrLen) then
        Exit(InvalidValue('<cannot read array length>'));
      var Count := Int64(ArrLen);
      if Idx >= Count then
        Exit(InvalidValue(Format('<index %d out of bounds [0..%d]>', [Idx, Count - 1])));
    end;

    ElemAddr := DataPtr + UInt64(Idx * ElemSize);
    ElemRaw  := 0;
    if not FDebugger.ReadProcessMemoryAt(ElemAddr, @ElemRaw, Min(ElemSize, 8)) then
      Exit(InvalidValue('<element read failed>'));

    Result          := Default(TExprValue);
    Result.TypeHint := ElemType;
    Result.Address  := ElemAddr;
    Result.RawValue := ElemRaw;
    Result.Size     := ElemSize;
    Result.IsValid  := True;
    Exit;
  end;

  // Variant array element access (single-dimension call)
  if SameText(Base.TypeHint, 'Variant') or SameText(Base.TypeHint, 'TVarData') then
    Exit(ApplyVarArrayIndex(Base, [Idx]));

  // A class instance that reaches here declares no `default` array property
  // anywhere in its chain (or its debug information does not carry one). Say so,
  // and say what to write instead: a named property still works.
  if (FRtti <> nil) and Base.IsValid and FRtti.IsClassInstance(Base.RawValue) then
    Exit(InvalidValue(Format(
      '<"%s" has no default array property; name the property, e.g. Obj.Items[%d]>',
      [Base.TypeHint, Idx])));

  Result := InvalidValue(Format('<cannot index type "%s">', [Base.TypeHint]));
end;

// Accesses an element of a Delphi VarArray Variant.
// Indices must match the array's DimCount exactly.
// TVarArray layout (Win64, default alignment -- NOT packed):
//   +0  DimCount    Word
//   +2  Flags       Word
//   +4  ElementSize Integer
//   +8  LockCount   Integer
//   +12 padding (4 bytes -- Pointer needs 8-byte alignment)
//   +16 Data        Pointer
//   +24 Bounds[0..DimCount-1]: each TVarArrayBound = 2 x Integer (8 bytes)
function TExprEvaluator.IsStaticArrayHint(const H: string): Boolean;
begin
  // `array[` => static array (with bounds). `array of` => dynamic (handled
  // by TryArrayElemInfo / ApplyIndex).
  Result := H.StartsWith('array[', True);
end;

function TExprEvaluator.ParseStaticArrayDims(const H: string;
  out Los, His: TArray<Integer>; out ElemType: string): Boolean;
begin
  Los := nil;
  His := nil;
  ElemType := '';
  if not H.StartsWith('array[', True) then
    Exit(False);
  var CloseB := H.IndexOf(']');
  if CloseB < 0 then
    Exit(False);
  var Inner := H.Substring(6, CloseB - 6);          // between '[' and ']'
  var Rest  := H.Substring(CloseB + 1).Trim;        // 'of <Elem>'
  if Rest.StartsWith('of ', True) then
    ElemType := Rest.Substring(3).Trim
  else
    Exit(False);
  if ElemType = '' then
    Exit(False);
  for var Part in Inner.Split([',']) do begin
    var P := Part.Trim;
    var DotDot := P.IndexOf('..');
    if DotDot < 0 then
      Exit(False);
    var LoV, HiV: Integer;
    if not TryStrToInt(P.Substring(0, DotDot).Trim, LoV) or
       not TryStrToInt(P.Substring(DotDot + 2).Trim, HiV) then
      Exit(False);
    Los := Los + [LoV];
    His := His + [HiV];
  end;
  Result := Length(Los) > 0;
end;

// Static array element access. Supports multi-dim `A[i,j,...]` and partial
// indexing (`A[i]` of a 2-D array returns the i-th sub-array). Memory layout is
// row-major (last index varies fastest), matching Delphi's static-array storage.
function TExprEvaluator.ApplyStaticArrayIndex(const Base: TExprValue;
  const Indices: TArray<Int64>): TExprValue;
var
  Los, His: TArray<Integer>;
  ElemType: string;
begin
  if not Base.IsValid then
    Exit(Base);
  if not ParseStaticArrayDims(Base.TypeHint, Los, His, ElemType) then
    Exit(InvalidValue(Format('<cannot parse static array "%s">', [Base.TypeHint])));
  if Base.Address = 0 then
    Exit(InvalidValue('<static array has no address>'));
  var DimCount := Length(Los);
  if Length(Indices) > DimCount then
    Exit(InvalidValue(Format('<%d indices for a %d-dimensional array>',
      [Length(Indices), DimCount])));

  var ElemSize := 0;
  if not ((FDebugInfo <> nil) and FDebugInfo.GetTypeSize(ElemType, ElemSize) and (ElemSize > 0)) then
    ElemSize := PrimTypeSize(ElemType);

  // Row-major flat index over the provided leading dimensions.
  var Flat: Int64 := 0;
  for var K := 0 to High(Indices) do begin
    if (Indices[K] < Los[K]) or (Indices[K] > His[K]) then
      Exit(InvalidValue(Format('<index %d out of bounds [%d..%d]>',
        [Indices[K], Los[K], His[K]])));
    Flat := Flat * (His[K] - Los[K] + 1) + (Indices[K] - Los[K]);
  end;

  // Element stride of the dimensions left un-indexed.
  var RemStride: Int64 := 1;
  for var K := Length(Indices) to DimCount - 1 do
    RemStride := RemStride * (His[K] - Los[K] + 1);

  var ElemAddr := Base.Address + UInt64(Flat * RemStride * ElemSize);

  Result := Default(TExprValue);
  Result.Address := ElemAddr;
  Result.IsValid := True;

  if Length(Indices) = DimCount then begin
    var Raw: UInt64 := 0;
    if not FDebugger.ReadProcessMemoryAt(ElemAddr, @Raw, Min(ElemSize, 8)) then
      Exit(InvalidValue('<element read failed>'));
    Result.TypeHint := ElemType;
    Result.RawValue := Raw;
    Result.Size     := ElemSize;
  end
  else begin
    var Dims := '';
    for var K := Length(Indices) to DimCount - 1 do begin
      if Dims <> '' then
        Dims := Dims + ', ';
      Dims := Dims + Format('%d..%d', [Los[K], His[K]]);
    end;
    Result.TypeHint := Format('array[%s] of %s', [Dims, ElemType]);
    Result.Size     := 8;
    var Raw: UInt64 := 0;
    FDebugger.ReadProcessMemoryAt(ElemAddr, @Raw, 8);
    Result.RawValue := Raw;
  end;
end;

function TExprEvaluator.ApplyVarArrayIndex(const Base: TExprValue;
  const Indices: TArray<Int64>): TExprValue;
const
  varArray = $2000;
var
  VTypeWord:  Word;
  DataField:  UInt64;
  VarArrPtr:  UInt64;
  DimWord:    Word;
  DimCount:   Integer;
  ElemSzCard: Cardinal;
  ElemSize:   Integer;
  DataPtr:    UInt64;
  BoundsBase: UInt64;
  LinearOff:  Int64;
  ElemAddr:   UInt64;
  RawVal:     UInt64;
begin
  if Base.Address = 0 then
    Exit(InvalidValue('<Variant address not known>'));

  if not ReadU16(Base.Address, VTypeWord) then
    Exit(InvalidValue('<cannot read Variant VType>'));

  if (VTypeWord and varArray) = 0 then
    Exit(InvalidValue('<Variant is not an array>'));

  var BaseElemType := VTypeWord and $0FFF;

  // TVarData.Data (offset +8) holds the PVarArray pointer
  if not ReadU64(Base.Address + 8, DataField) then
    Exit(InvalidValue('<cannot read VarArray pointer>'));
  VarArrPtr := DataField;
  if VarArrPtr = 0 then
    Exit(InvalidValue('<nil VarArray>'));

  if not ReadU16(VarArrPtr, DimWord) then
    Exit(InvalidValue('<cannot read VarArray DimCount>'));
  DimCount := Integer(DimWord);

  if Length(Indices) <> DimCount then
    Exit(InvalidValue(Format('<VarArray has %d dimension(s), got %d index/indices>',
      [DimCount, Length(Indices)])));

  if not ReadU32(VarArrPtr + 4, ElemSzCard) then
    Exit(InvalidValue('<cannot read VarArray ElementSize>'));
  ElemSize := Integer(ElemSzCard);
  if ElemSize <= 0 then
    Exit(InvalidValue('<VarArray: invalid ElementSize>'));

  if not ReadU64(VarArrPtr + 16, DataPtr) then
    Exit(InvalidValue('<cannot read VarArray Data>'));
  if DataPtr = 0 then
    Exit(InvalidValue('<VarArray data is nil (locked?)>'));

  // Delphi VarArray stores bounds in REVERSE declaration order:
  //   `VarArrayCreate([loA,hiA, loB,hiB], ...)` produces storage with
  //   Bounds[0] = (B's EC, B's LB), Bounds[1] = (A's EC, A's LB).
  // Addressing is column-major in declaration order: the FIRST user index
  // varies fastest, the LAST varies slowest. Equivalently, in storage order
  // (where Bound[0] is the outermost dim), addressing is row-major.
  //
  // Concretely, for Mat declared [1..3, 1..4], `Mat[i,j]` is stored at:
  //   linear = (i - LB_i)  +  (j - LB_j) * EC_i
  BoundsBase := VarArrPtr + 24;
  LinearOff  := 0;
  var Stride: Int64 := 1;
  for var I := 0 to DimCount - 1 do begin
    // User dim I -> storage Bound[DimCount-1-I]
    var StorageK := DimCount - 1 - I;
    var ElemCountU: Cardinal;
    var LowBoundU:  Cardinal;
    if not ReadU32(BoundsBase + UInt64(StorageK * 8),     ElemCountU) or
       not ReadU32(BoundsBase + UInt64(StorageK * 8 + 4), LowBoundU)  then
      Exit(InvalidValue('<cannot read VarArray bound>'));
    var LB  := Int32(LowBoundU);
    var EC  := Int32(ElemCountU);
    var Idx := Indices[I];
    if (Idx < LB) or (Idx > LB + EC - 1) then
      Exit(InvalidValue(Format('<index %d out of bounds [%d..%d] (dim %d)>',
        [Idx, LB, LB + EC - 1, I])));
    LinearOff := LinearOff + (Idx - LB) * Stride;
    Stride    := Stride * Int64(EC);
  end;

  ElemAddr := DataPtr + UInt64(LinearOff * ElemSize);
  RawVal   := 0;

  // varVariant elements are full 16-byte TVarData structs -- recurse-able
  if BaseElemType = $000C then begin
    if not ReadU64(ElemAddr, RawVal) then
      Exit(InvalidValue('<cannot read Variant element>'));
    Result          := Default(TExprValue);
    Result.TypeHint := 'Variant';
    Result.Address  := ElemAddr;
    Result.RawValue := RawVal;
    Result.Size     := 16;
    Result.IsValid  := True;
    Exit;
  end;

  // All other element types: raw value at ElemAddr
  var ResultHint: string;
  case BaseElemType of
    $0002: ResultHint := 'SmallInt';
    $0003: ResultHint := 'Integer';
    $0004: ResultHint := 'Single';
    $0005: ResultHint := 'Double';
    $0006: ResultHint := 'Currency';
    $0007: ResultHint := 'TDateTime';
    $000B: ResultHint := 'Boolean';
    $0010: ResultHint := 'ShortInt';
    $0011: ResultHint := 'Byte';
    $0012: ResultHint := 'Word';
    $0013: ResultHint := 'Cardinal';
    $0014: ResultHint := 'Int64';
    $0015: ResultHint := 'UInt64';
    $0100: ResultHint := 'AnsiString';
    $0102: ResultHint := 'string';
    $0008: ResultHint := 'WideString';
  else
    ResultHint := Format('vartype=$%.4x', [BaseElemType]);
  end;

  FDebugger.ReadProcessMemoryAt(ElemAddr, @RawVal, Min(ElemSize, 8));
  Result          := Default(TExprValue);
  Result.TypeHint := ResultHint;
  Result.Address  := ElemAddr;
  Result.RawValue := RawVal;
  Result.Size     := ElemSize;
  Result.IsValid  := True;
end;

// Generic instance-method invoker: `Obj.Method(args)`. Resolves the method
// to a VA via the loaded MAP/RSM (using the instance's runtime class
// name), marshalls the args according to the Win64 ABI, and dispatches
// the return value based on a heuristic (the call's first non-Self
// argument type) -- TODO: read the method's extended-RTTI signature for
// the proper return-type dispatch instead of guessing.
//
// Args marshalling:
//   * Integer / pointer-like -> packed into the position's RCX/RDX/R8/R9.
//   * Float (Single/Double)  -> packed into XMM0..3 at the same position.
//   * String literal         -> already allocated in the debuggee by
//                              ParsePrimary; its RawValue is the
//                              string-buffer pointer.
//
// Return dispatch (heuristic on the FIRST user arg's type-hint, with
// Integer as the fallback):
//   * Float arg            -> XMM0 low qword as Double.
//   * String arg           -> hidden var-out result, RDX = Slot, real
//                            args shift by one (R8, R9, stack).
//   * Otherwise            -> RAX as Int64.
function TExprEvaluator.ApplyMethodCall(const Base: TExprValue;
  const MethodName: string; const Args: TArray<TExprValue>;
  const ExplicitClass: string; const ReturnTypeHint: string;
  ClassRefSelf: UInt64; ForceClassMethod: Boolean;
  Speculative: Boolean; ReturnKindHint: Byte; ReturnSizeHint: Integer): TExprValue;

  // Authoritative return-type lookup: every Delphi function records its
  // `Result` slot as a local in the procedure's $28 RSM record. Var-out
  // functions (string, Variant, dyn-array, big record) tag it $23 instead
  // of $20 -- the parser accepts both. Procedures (no return) have no
  // `Result` local; the caller falls back to the legacy heuristic.
  function TryGetReturnTypeFromResultLocal(const FullProcName: string;
    out RetTypeName: string; out RetKind: Byte): Boolean;
  var
    Locals: TArray<TLocalSymbol>;
  begin
    Result := False;
    if FDebugInfo = nil then Exit;
    if not FDebugInfo.GetLocalsForFunction(FullProcName, Locals) then Exit;
    for var L in Locals do
      if SameText(L.Name, 'Result') and (L.TypeHint <> '') then begin
        RetTypeName := L.TypeHint;
        RetKind     := TypeNameToKind(RetTypeName);
        // TD32 renders the Result of a VAR-OUT function as a POINTER to the
        // real return type -- `^Variant`, `^TPoint3D`, `^string` -- because the
        // hidden slot is what the routine actually writes through. The caret is
        // the ABI, not the type, and leaving it on means the kind never
        // resolves: `W.DoCalcVariant()` returned 3 (the VType word) and
        // `W.DoCalcBigRec()` the record's first field as an integer, while
        // `W.DoCalcUStr()` worked only because the string path strips it
        // separately further down.
        //
        // Strip it ONLY when the stripped name is a type that is genuinely
        // returned through the var-out slot. A function returning a pointer BY
        // VALUE (RAX) also has a caret in its Result hint, and stripping that
        // one would read the pointee instead of the pointer.
        if RetTypeName.StartsWith('^') then begin
          var Pointee     := RetTypeName.Substring(1);
          var PointeeKind := TypeNameToKind(Pointee);
          // A NAME cannot separate a dynamic array from a plain pointer -- TD32
          // renders both as `^Element`, so `W.DoCalcDynArr()` (Result typed
          // `^^Integer`) looked like a pointer-to-pointer and kept its
          // indirection, decoding the array with a pointer-sized stride:
          // [85899345930, 30, []], where 85899345930 is 0x14_0000000A, the
          // elements 20 and 10 read as ONE 8-byte element. The TYPE GRAPH does
          // separate them -- a dynamic array is a pointer to an array
          // descriptor -- so ask by id when the name came back unhelpful.
          if (PointeeKind = 0) or (PointeeKind = TK_POINTER) then begin
            var ByIdKind := FDebugInfo.PointeeKindById(Cardinal(L.TypeId));
            if ByIdKind <> 0 then
              PointeeKind := ByIdKind;
          end;
          // Same set as IsManagedReturnKind below, plus records; spelled out
          // because that helper is declared after this one.
          if PointeeKind in [TK_LSTRING, TK_USTRING, TK_WSTRING, TK_DYNARRAY,
                             TK_INTERFACE, TK_VARIANT, TK_RECORD, TK_MRECORD] then begin
            RetTypeName := Pointee;
            RetKind     := PointeeKind;
          end;
        end;
        Exit(True);
      end;
  end;

  // The managed/variant return families (string, dyn-array, interface, Variant)
  // travel through the hidden var-out slot and are decoded specially. A CV type-id
  // kind cannot separate them from a by-value record, so when the declared NAME
  // already resolves to one of these it must win over the id-resolved kind hint.
  function IsManagedReturnKind(K: Byte): Boolean;
  begin
    Result := K in [TK_LSTRING, TK_USTRING, TK_WSTRING,
                    TK_DYNARRAY, TK_INTERFACE, TK_VARIANT];
  end;

var
  ClassName, FullName: string;
  FuncVA: UInt64;
  Rax, Xmm0: UInt64;
  Slot: UInt64;
  WantsFloatReturn, WantsStringReturn: Boolean;
  // A Variant return also uses the var-out slot, but the slot holds a TVarData
  // BY VALUE, not a data pointer. Tracked apart from WantsStringReturn so the
  // result is decoded as a Variant rather than read as an 8-byte pointer - the
  // old lumping showed 258 (the varUString VType word) for `dataset['X']`.
  WantsVariantReturn: Boolean;
  // A record larger than 8 bytes is written into the var-out slot BY VALUE too.
  // Its Address must point at the slot so field access reads the fields; reading
  // 8 bytes as a pointer (the string path) would use the first two fields as an
  // address. RetRecSize is its declared size, used to size the slot.
  WantsRecordReturn: Boolean;
  RetRecSize:        Integer;
  // A set wider than 8 bytes is returned through the var-out slot by value, like
  // a record. A <= 8-byte set comes back in RAX and is decoded from RawValue.
  WantsSetReturn:    Boolean;
  RetSetSize:        Integer;
  // Win64 ABI: a POD record of size <= 8 bytes is returned PACKED IN RAX, not
  // through a hidden var-out slot. Tracked separately so the slot argument is
  // NOT inserted for such a call (inserting it also shifted the user args into
  // the wrong registers) and the result is taken from RAX.
  SmallRecInRax: Boolean;
  Vals: TArray<UInt64>;
  Kinds: TArray<TSyntheticArgKind>;
  RetTypeName: string;
  RetKind:     Byte;
  HaveBoundReturn: Boolean;
var
  IsFreeProc: Boolean;
begin
  Result := Default(TExprValue);
  // Three call modes: instance method (Base is a class instance), class method
  // (ForceClassMethod -- Self is the class VMT in ClassRefSelf, not an instance),
  // and free procedure (Base is the synthetic "no-receiver" sentinel passed by
  // ParsePrimary). Discriminator is whether Base looks like an object.
  IsFreeProc := (not ForceClassMethod) and
                ((not Base.IsValid) or (Base.RawValue < 65536) or
                 (FRtti = nil) or
                 (not FRtti.IsClassInstance(Base.RawValue)));
  if IsFreeProc then begin
    ClassName := '';
    FullName  := MethodName;
  end else begin
    // ExplicitClass (the member's DECLARING class) wins over the runtime leaf
    // class: an inherited getter's symbol lives under the class that declares it
    // (e.g. TComponent.GetComponentCount, not TApplication.GetComponentCount).
    if ExplicitClass <> '' then
      ClassName := ExplicitClass
    else
      ClassName := FRtti.GetInstanceClassName(Base.RawValue);
    if ClassName = '' then
      Exit(InvalidValue('<receiver has no class name>'));
    FullName := ClassName + '.' + MethodName;
  end;
  if not FDebugger.TryResolveSymbolVA(FullName, FuncVA) then begin
    // Inherited method: the symbol lives under the class that DECLARES it, not
    // under the receiver's runtime class. `dataset.FieldByName('X')` on a
    // TAppDataSet must resolve TDataSet.FieldByName; looking only under the
    // runtime class made every inherited method uncallable, and an explicit
    // cast did not help because the cast does not change the receiver's class.
    //
    // Walked over the RUNTIME chain rather than a debug-info one so it works
    // for classes whose declaring module has no symbols of its own.
    if (not IsFreeProc) and (not ForceClassMethod) and (FRtti <> nil) then
      for var Ancestor in FRtti.GetClassChainNames(Base.RawValue) do begin
        if SameText(Ancestor, ClassName) then
          Continue;
        var Inherited_ := Ancestor + '.' + MethodName;
        if FDebugger.TryResolveSymbolVA(Inherited_, FuncVA) then begin
          DapLog(Format('  inherited method HIT "%s" (receiver class "%s")',
            [Inherited_, ClassName]));
          FullName  := Inherited_;
          ClassName := Ancestor;
          Break;
        end;
      end;
  end;

  if FuncVA = 0 then begin
    // Indexed-property fallback: `Cache.Level[0]` parses to a `Level`
    // method call with [0] as arg. If `Level` is actually a read-only
    // property whose getter is a different method name (e.g. GetLevel),
    // redirect through the class-member table: look up the property by
    // the requested member name, then dispatch on its GetterName.
    if (not IsFreeProc) and (FDebugInfo <> nil) then begin
      var Members: TArray<TClassMember>;
      var GotMembers := FDebugInfo.GetClassMembers(ClassName, Members);
      DapLog(Format('IdxPropFB class="%s" method="%s" gotMembers=%s memberCount=%d',
        [ClassName, MethodName, BoolToStr(GotMembers, True), Length(Members)]));
      if GotMembers then begin
        // NB: do not log every member here. On real VCL classes the table
        // has hundreds of members and DapLog flushes per line, so the dump
        // alone cost seconds per hover/watch. Member-level detail can be
        // re-added behind a dedicated ultra-verbose switch if needed.
        for var I := 0 to High(Members) do
          if SameText(Members[I].Name, MethodName) and
             (Members[I].Kind = cmkProperty) then begin
            // Path A: TD32-derived demangled getter name (already populated).
            if Members[I].GetterName <> '' then begin
              FullName := ClassName + '.' + Members[I].GetterName;
              if FDebugger.TryResolveSymbolVA(FullName, FuncVA) then begin
                DapLog(Format('  IdxPropFB pathA HIT FullName="%s"', [FullName]));
                Break;
              end;
              FullName := ClassName + '.' + MethodName;
            end else begin
              // Path A': TD32 sometimes loses an indexed property's getter name
              // (e.g. `property Level[i] read GetLevel` arrives with no getter).
              // Try the `Get<Name>` convention.
              FullName := ClassName + '.Get' + MethodName;
              if FDebugger.TryResolveSymbolVA(FullName, FuncVA) then begin
                DapLog(Format('  IdxPropFB pathA'' HIT FullName="%s"', [FullName]));
                Break;
              end;
              FullName := ClassName + '.' + MethodName;
            end;
            // Path B: RSM-style hash binding -- the property's GetterHash
            // matches another member's Hash. When that other member is a
            // method, dispatch through its Name (works for indexed
            // properties whose getter takes the index arguments).
            for var J := 0 to High(Members) do
              if (Members[J].Hash = Members[I].GetterHash) and
                 (Members[J].Kind = cmkMethod) and (Members[J].Name <> '') then begin
                FullName := ClassName + '.' + Members[J].Name;
                if FDebugger.TryResolveSymbolVA(FullName, FuncVA) then begin
                  DapLog(Format('  IdxPropFB pathB HIT FullName="%s"', [FullName]));
                  Break;
                end;
                FullName := ClassName + '.' + MethodName;
              end;
            if FuncVA <> 0 then Break;
          end;
      end;
    end;
    if not FDebugger.TryResolveSymbolVA(FullName, FuncVA) then
      Exit(InvalidValue(Format('<%s not found>', [FullName])));
  end;

  // A bare name that is actually a DATA global (a unit `var`, e.g. SampleApp's
  // cross-binary `Globals` in libSharedFormsD29.bpl) must be READ, not invoked.
  // ResolveIdent tries the parameterless free-function call BEFORE the data
  // global lookup (so `Now` is invoked as `Now()`), but for a variable that is
  // wrong: TryResolveSymbolVA can resolve a same-named CODE symbol (a getter /
  // a tail match) whose address IS executable, so `AddressIsExecutable` alone
  // does not catch it -- the call then runs unrelated code and returns garbage
  // in RAX (a different value, hence a different runtime-VMT-guessed type, on
  // every step). Refuse the free-proc call when the name is a known data global
  // OR when the resolved target is not on an executable page; resolution then
  // falls through to EvaluateGlobalName, which reads the variable.
  if IsFreeProc and (FDebugInfo <> nil) then begin
    var GSymVar: TGlobalSymbol;
    if FDebugInfo.FindGlobal(MethodName, GSymVar) and (GSymVar.RVA <> 0) then
      Exit(InvalidValue(Format('<%s is a data global, not a procedure>', [MethodName])));
  end;
  if IsFreeProc and (not FDebugger.AddressIsExecutable(FuncVA)) then
    Exit(InvalidValue(Format('<%s is not a callable procedure>', [FullName])));

  // First try the RSM: if a property in the same class binds to this method
  // by hash, take the return ABI from the property's typeId. This catches
  // string-returning unpublished methods (`GetMyLabel: string`) where the
  // first-argument heuristic would otherwise hang the debuggee.
  HaveBoundReturn   := TryGetReturnTypeFromResultLocal(FullName,
                        RetTypeName, RetKind);
  // VCL/RTL getters (e.g. TApplication.GetExeName) have no locals in our debug
  // info, so the Result-local probe above misses and the return ABI would
  // default to RAX. A managed return (string/interface/...) is passed via a
  // hidden var-out slot; calling it without that slot makes the callee write
  // its Result to RDX=0 -> access violation -> the call aborts. When the caller
  // already knows the declared property type, use it: classify by name, then
  // fall back to the authoritative TD32 type kind for non-primitive names.
  // The DECLARED return type, when the caller provides it, is authoritative over
  // the Result-local probe. The property/method's declared type is ground truth
  // for the return ABI (RAX vs a hidden var-out slot vs XMM0), and the local
  // probe misses entirely for RTL/VCL getters with no debug info and can, in the
  // BPL scenario, classify a var-out Result local as the wrong kind.
  //
  // The kind is RESOLVED, never matched by name: TypeNameToKind consults the
  // debug-info type system for any name it does not know built-in, so it follows
  // `type NullableInteger = type variant` to TK_VARIANT, `TCaption = type string`
  // to a string kind, and a class or record name to TK_CLASS / TK_RECORD. Keying
  // on the literal name "Variant" would have missed every distinct alias.
  //
  // ReturnKindHint is the same member's kind resolved from its EXACT type id, so
  // it is immune to the first-wins ambiguity of two same-named types. It arbitrates
  // the class-vs-record-vs-set-vs-enum-vs-pointer question the name can get wrong.
  // But the id path CANNOT represent the managed families -- a Variant (TVarData),
  // a string, a dyn-array and an interface all look like a struct/pointer record by
  // CV kind -- so a managed name must WIN over the id hint, or a `: Variant` getter
  // would be dispatched as a by-value record (the old 258/TVarData-as-record bug).
  // Hence: name first for managed/variant kinds; the id hint arbitrates the rest
  // and fills in when the name cannot be classified.
  if ReturnTypeHint <> '' then begin
    var HintKind := TypeNameToKind(ReturnTypeHint);
    if not IsManagedReturnKind(HintKind) and (ReturnKindHint <> TK_UNKNOWN) then
      HintKind := ReturnKindHint;
    if HintKind <> TK_UNKNOWN then begin
      RetTypeName     := ReturnTypeHint;
      RetKind         := HintKind;
      HaveBoundReturn := True;
    end else if not HaveBoundReturn then begin
      // No resolvable kind and nothing from the probe: keep the name so the
      // formatter at least has a type hint, and let the ABI default to RAX.
      RetTypeName     := ReturnTypeHint;
      RetKind         := TK_UNKNOWN;
    end;
  end else if ReturnKindHint <> TK_UNKNOWN then begin
    // No declared name, but the member carried an id-resolved kind.
    RetKind         := ReturnKindHint;
    HaveBoundReturn := True;
  end;
  // Speculative bare-identifier free "call" (ResolveIdent's `Foo` = `Foo()`
  // convenience): only invoke when a return type could be BOUND, i.e. the symbol
  // is a genuine value-returning function. A bare unit name
  // (`frmSelezioneCompanyU`), a type, or a procedure also resolves to an
  // executable address, but synthetically invoking it runs code that may never
  // return to our INT3 trap -- the event pump then waits forever and FREEZES the
  // whole adapter (every later request, step-over included, queues behind the
  // single-threaded dispatch). Refuse it here; an explicit `Name(...)` call
  // (Speculative=False) is never gated, and a bare data global was already
  // handled above.
  if IsFreeProc and Speculative and (not HaveBoundReturn) then
    Exit(InvalidValue(Format('<%s is not a value-returning function>', [FullName])));
  // A free function that TAKES parameters must not be invoked with fewer
  // arguments than it declares: the synthetic call would read whatever garbage
  // is in the unset argument registers and return a plausible-but-wrong value.
  // The declared count comes from the function's LF_PROCEDURE signature, so we
  // refuse WITHOUT ever attempting the call (the bare `Foo` speculative form and
  // an explicit `Foo()` with too few args are both caught). A genuinely
  // parameterless function (count 0) is unaffected, so `Now` etc. still auto-call.
  // When the arity is unknown the call proceeds as before -- a strict improvement.
  if IsFreeProc and (FDebugInfo <> nil) then begin
    var DeclaredParamCount: Integer;
    if FDebugInfo.TryGetFreeFunctionParamCount(FullName, DeclaredParamCount) and
       (DeclaredParamCount > Length(Args)) then
      Exit(InvalidValue(Format('<%s requires %d argument(s)>',
        [FullName, DeclaredParamCount])));
  end;
  WantsFloatReturn   := False;
  WantsStringReturn  := False;
  WantsVariantReturn := False;
  WantsRecordReturn  := False;
  RetRecSize         := 0;
  WantsSetReturn     := False;
  RetSetSize         := 0;
  SmallRecInRax      := False;
  if HaveBoundReturn then begin
    case RetKind of
      TK_FLOAT:
        WantsFloatReturn := CurrencyReturnsWithFloats or
                            not SameText(RetTypeName, 'Currency');
      TK_SET:
        // > 8 bytes -> var-out slot (by value). <= 8 -> RAX (the else branch);
        // the set formatter reads the real width from RawValue there. Size from
        // the exact id when available (ReturnSizeHint), else the name table.
        if ReturnSizeHint > 0 then begin
          RetSetSize := ReturnSizeHint;
          if RetSetSize > 8 then
            WantsSetReturn := True;
        end
        else if FDebugInfo.GetTypeSize(RetTypeName, RetSetSize) and (RetSetSize > 8) then
          WantsSetReturn := True;
      TK_VARIANT:
        // Returned through the var-out slot like a string, but the slot holds a
        // 16/24-byte TVarData by value, decoded below - not a data pointer.
        WantsVariantReturn := True;
      TK_LSTRING, TK_USTRING, TK_WSTRING, TK_DYNARRAY, TK_INTERFACE:
        // Interfaces and dynamic arrays are managed: a function returning one
        // uses the hidden var-out slot (RDX for methods), and the slot holds a
        // data/reference POINTER, read as 8 bytes like a string return.
        WantsStringReturn := True;
      TK_RECORD, TK_MRECORD: begin
        // A POD record <= 8 bytes comes back in RAX (the same ABI rule
        // InvokeGetter documents). A larger record - and any managed record - is
        // written into the var-out slot BY VALUE: point Address at the slot so
        // its fields can be read. Managed records are never returned in RAX.
        // Size from the exact id (ReturnSizeHint) when available; the name table
        // otherwise. RetRecSize is kept for the slot allocation below.
        var HaveRecSize: Boolean;
        if ReturnSizeHint > 0 then begin
          RetRecSize  := ReturnSizeHint;
          HaveRecSize := True;
        end
        else
          HaveRecSize := FDebugInfo.GetTypeSize(RetTypeName, RetRecSize);
        if (RetKind = TK_MRECORD) or
           (not (HaveRecSize and (RetRecSize > 0) and (RetRecSize <= 8))) then
          WantsRecordReturn := True
        else
          SmallRecInRax := True;
      end;
    end;
    // TD32 types a managed dynamic-array Result as `^Element` (it has no
    // distinct dyn-array encoding). Such a function still returns via the hidden
    // var-out slot, so route it through the same slot-deref path as a dyn-array.
    if RetTypeName.StartsWith('^') then
      WantsStringReturn := True;
  end else if Length(Args) > 0 then begin
    // Fallback heuristic: dispatch on first arg's declared TypeHint.
    if IsFloatValueHint(Args[0].TypeHint) then
      WantsFloatReturn := True
    else if SameText(Args[0].TypeHint, 'UnicodeString') or
            SameText(Args[0].TypeHint, 'string')         or
            SameText(Args[0].TypeHint, 'AnsiString')     or
            SameText(Args[0].TypeHint, 'WideString')     or
            SameText(Args[0].TypeHint, 'UTF8String')     or
            SameText(Args[0].TypeHint, 'RawByteString') then
      WantsStringReturn := True;
  end;

  // Build the call frame. Self is the first argument in RCX for methods;
  // free procedures skip it. For a class method, Self is the class reference
  // (VMT) rather than an instance pointer.
  SetLength(Vals, 0);
  SetLength(Kinds, 0);
  if not IsFreeProc then begin
    if ForceClassMethod then
      Vals := Vals + [ClassRefSelf]
    else
      Vals := Vals + [Base.RawValue];
    Kinds := Kinds + [sakOrdinal];   // Self / class reference: a pointer
  end;

  // For a var-out return the callee is handed a hidden pointer to write its
  // result through. A Variant needs the whole 24-byte TVarData zeroed, not just
  // 8 bytes, so a field the getter leaves untouched cannot read as stale
  // VType/data.
  Slot := 0;
  if WantsStringReturn or WantsVariantReturn or WantsRecordReturn or WantsSetReturn then begin
    if WantsVariantReturn then
      Slot := FDebugger.GetRemoteScratchSlot(24)
    else if WantsRecordReturn then
      Slot := FDebugger.GetRemoteScratchSlot(NativeUInt(Max(RetRecSize, 16)))
    else if WantsSetReturn then
      Slot := FDebugger.GetRemoteScratchSlot(NativeUInt(Max(RetSetSize, 16)))
    else
      Slot := FDebugger.GetRemoteScratchSlot(8);
    if Slot = 0 then
      Exit(InvalidValue('<method scratch alloc failed>'));
  end;

  // WHERE that hidden pointer goes is the ABI's business, and the two targets
  // disagree: on Win64 it follows Self (RDX for a method, RCX for a free proc),
  // on Win32 it is the LAST parameter, after every declared argument. Placing
  // it second unconditionally was right only by accident for a function taking
  // NO arguments -- Self, @Result lands in EAX, EDX either way. With one
  // argument it put @Result in EDX and the argument in ECX, so `W.Greet(x)`
  // made the callee write its result string through the address of the
  // argument's character data and the call aborted, on Win32 only.
  var SlotGoesLast := FDebugger.TargetLayout.HiddenResultParamIsLast;
  if (Slot <> 0) and not SlotGoesLast then begin
    Vals  := Vals  + [Slot];
    Kinds := Kinds + [sakOrdinal];   // hidden var-out slot: a pointer
  end;

  // Marshall user args. The KIND, not merely "is it a float", because the two
  // architectures need different things from it: x64 uses it only to choose the
  // register file, x86 to decide whether the argument competes for a register
  // slot at all and how many stack bytes it occupies.
  for var I := 0 to High(Args) do begin
    Vals  := Vals  + [Args[I].RawValue];
    Kinds := Kinds + [SyntheticArgKindOf(Args[I])];
  end;

  if (Slot <> 0) and SlotGoesLast then begin
    Vals  := Vals  + [Slot];
    Kinds := Kinds + [sakOrdinal];
  end;

  if not FDebugger.RunMethodCall(FuncVA, Vals, Kinds, Rax, Xmm0) then
    Exit(InvalidValue('<method invocation failed>'));

  // Build the return TExprValue. When we have a bound-property return type,
  // use it verbatim; otherwise fall back to the legacy heuristic shape.
  if WantsFloatReturn then begin
    if HaveBoundReturn then
      Result.TypeHint := RetTypeName
    else
      Result.TypeHint := 'Double';
    Result.RawValue := NormaliseFloatReturn(Xmm0, Result.TypeHint);
    Result.Size     := 8;
  end else if WantsVariantReturn then begin
    // The slot IS the TVarData (by value). Point Address at it and leave
    // RawValue 0; the value formatter's FormatVariantAt decodes VType + data.
    // Reading 8 bytes as a pointer here is the bug that surfaced 258 (the
    // varUString VType word) for a Variant-returning default property.
    Result.TypeHint := 'Variant';
    Result.Address  := Slot;
    Result.RawValue := 0;
    Result.Size     := 24;
  end else if WantsRecordReturn then begin
    // The slot IS the record (by value). Address at the slot lets the record
    // field resolver read fields at slot + offset; RawValue stays 0 so nothing
    // reinterprets the first bytes as a pointer.
    Result.TypeHint := RetTypeName;
    Result.Address  := Slot;
    Result.RawValue := 0;
    Result.Size     := RetRecSize;
  end else if WantsSetReturn then begin
    // The slot holds the set by value; Address lets DecodeSetMembers read the
    // full declared width.
    Result.TypeHint := RetTypeName;
    Result.Address  := Slot;
    Result.RawValue := 0;
    Result.Size     := RetSetSize;
  end else if WantsStringReturn then begin
    if HaveBoundReturn then
      Result.TypeHint := RetTypeName
    else
      Result.TypeHint := 'UnicodeString';
    // TD32 types a var-out string Result as `^string` / `^AnsiString` / ... The
    // slot holds the string DATA pointer, so present it as the string type (not
    // a `^` pointer) so the value formatter reads characters, not an address.
    // (A var-out dyn-array stays `^Element` -- handled by the array logic.)
    if Result.TypeHint.StartsWith('^', True) and
       IsStringTypeHint(Copy(Result.TypeHint, 2, MaxInt)) then
      Result.TypeHint := Copy(Result.TypeHint, 2, MaxInt);
    Result.Size     := 8;
    if not FDebugger.ReadProcessMemoryAt(Slot, @Result.RawValue, 8) then
      Exit(InvalidValue('<string result deref failed>'));
  end else begin
    if SmallRecInRax then
      // The packed record bytes ARE the value in RAX. Present all 8 of them as a
      // packed Int64 rather than as the record type -- a record TypeHint would
      // make the expander treat RawValue as the record's ADDRESS and read an
      // unrelated location (and a 4-byte hint would drop the second field).
      // Field-by-field expansion of a register-returned record is a follow-up;
      // the point here is that the value is no longer a bogus zero.
      Result.TypeHint := 'Int64'
    else if HaveBoundReturn then
      Result.TypeHint := RetTypeName
    else
      Result.TypeHint := 'Integer';
    Result.RawValue := Rax;
    Result.Size     := 8;
  end;
  Result.IsValid := True;
end;

// `TClassName.Member[(args)]` on a bare class reference. Resolves the member
// against the in-scope class (the qualified `ClassName.Member` symbol is scoped
// to the frame's `uses` by TryResolveSymbolVA, so a same-named class in another
// unit is not picked). Currently supports class methods / class functions; the
// class const / class var forms fall through to "not found" for now.
//
// Self for the call is the class reference (TClass = the VMT), resolved scoped
// to the frame's uses. A class function that does not dereference Self works
// even when the VMT is unresolved (Self=0). One that touches Self/class vars
// without a resolvable VMT fails gracefully via the synthetic-call abort.
function TExprEvaluator.ApplyClassRefMember(const ClassName, Member: string;
  const Args: TArray<TExprValue>): TExprValue;
var
  SelfVmt: UInt64;
begin
  SelfVmt := 0;
  FDebugger.TryResolveClassRef(ClassName, SelfVmt);
  Result := ApplyMethodCall(Default(TExprValue), Member, Args, ClassName, '',
              SelfVmt, True);
end;

// Dot-field access on a class instance. Resolution order:
//   1. Class property whose name matches Field (via TPropInfo RTTI). The
//      property's GetProc encoding tells us how to resolve the value:
//        akField   -> read at instance + offset.
//        akStatic  -> invoke the function at GetValue (a direct VA).
//        akVirtual -> resolve the function via instance's VMT slot at offset.
//   2. Direct field name (e.g. `TheWidget.FName`) via extended RTTI field
//      table.
//   3. Qualified-name lookup (e.g. `ComputeNested.X`) for nested-proc
//      parent locals -- handled by `EvaluateName`.
function TExprEvaluator.ApplyDot(const Base: TExprValue; const Field: string): TExprValue;

  // Returns the storage size for a primitive Delphi type identified by its
  // TypeKind plus optional TypeName. Strings, classes and dynamic arrays are
  // pointer-sized handles, so their width follows the TARGET, not the host.
  function SizeForKind(K: Byte; const Name: string): Integer;
  begin
    case K of
      TK_SET: begin
        // A set is 1..32 bytes. Resolve the declared width so a >8-byte set
        // (e.g. `set of AnsiChar`) is not read as a single byte, dropping every
        // member past bit 7. GetTypeSize is authoritative; fall back to 1.
        var SetSz: Integer;
        if (FDebugInfo <> nil) and FDebugInfo.GetTypeSize(Name, SetSz) and (SetSz > 0) then
          Exit(SetSz);
        Exit(1);
      end;
      TK_CHAR, TK_ENUM, TK_WCHAR:
        // Enum size depends on declaration; default to 1 byte (most common).
        if SameText(Name, 'WideChar') then Exit(2) else Exit(1);
      TK_INTEGER, TK_FLOAT:
        if SameText(Name, 'Single') then Exit(4)
        else if SameText(Name, 'Double') or SameText(Name, 'Extended') then Exit(8)
        else Exit(4);   // SmallInt/Word also 2; conservative -- caller knows
      TK_INT64: Exit(8);
      TK_STRING: Exit(1);   // ShortString first byte = length (caller-specific)
      TK_LSTRING, TK_USTRING, TK_WSTRING, TK_DYNARRAY, TK_CLASS,
      TK_INTERFACE, TK_POINTER, TK_PROCEDURE, TK_VARIANT:
        Exit(FDebugger.TargetLayout.PointerSize);
    else
      Exit(PrimTypeSize(Name));
    end;
  end;

  function ReadFieldValue(const F: TRttiFieldInfo): TExprValue;
  var
    Raw:  UInt64;
    Size: Integer;
  begin
    Result := Default(TExprValue);
    Result.TypeHint     := F.TypeName;
    Result.Address      := F.FieldAddr;
    Result.TypeInfoAddr := F.TypeInfoAddr;
    Size := PrimTypeSize(F.TypeName);
    Result.Size    := Size;
    Raw := 0;
    if FDebugger.ReadProcessMemoryAt(F.FieldAddr, @Raw, Min(Size, 8)) then begin
      Result.RawValue := Raw;
      Result.IsValid  := True;
    end else
      Result := InvalidValue(Format('<read failed @ 0x%x>', [F.FieldAddr]));
  end;

  // Reads the value of a field-backed property given its byte offset within
  // the instance.
  function ReadFieldBackedProp(ObjAddr: UInt64; FieldOffset: UInt64;
    const P: TRttiPropInfo): TExprValue;
  var
    Raw:  UInt64;
    Size: Integer;
  begin
    Result := Default(TExprValue);
    Result.TypeHint     := P.PropTypeName;
    Result.Address      := ObjAddr + FieldOffset;
    Result.TypeInfoAddr := P.PropTypeInfoAddr;
    Size := SizeForKind(P.PropTypeKind, P.PropTypeName);
    Result.Size    := Size;
    if ReadValueAt(Result.Address, P.PropTypeName, Size, Raw) then begin
      Result.RawValue := Raw;
      Result.IsValid  := True;
    end else
      Result := InvalidValue(Format('<read failed @ 0x%x>', [Result.Address]));
  end;

  // Invokes a static- or virtual-method-backed property getter. Currently
  // handles return types that come back in RAX (Integer, Boolean, Enum,
  // Int64, pointer-sized handles). String/record/Float returns are not yet
  // wired through and will report a typed error.
  // Returns True if the property's return type is delivered via Win64's
  // hidden var-out result parameter (caller allocates the result slot,
  // passes its pointer as the first arg; the real first user arg --
  // `Self` for a method getter -- shifts to RDX).
  function ReturnsViaVarOut(const P: TRttiPropInfo): Boolean;
  begin
    case P.PropTypeKind of
      TK_LSTRING, TK_USTRING, TK_WSTRING, TK_DYNARRAY,
      TK_VARIANT, TK_RECORD, TK_MRECORD: Exit(True);
      TK_SET: begin
        // A set of 1/2/4/8 bytes comes back in RAX like an ordinal; a set wider
        // than 8 bytes is returned through the hidden result pointer. Dispatching
        // a >8-byte set through RAX would leave the callee writing to a garbage
        // RDX -> access violation.
        var SetSz: Integer := 0;
        Exit(FDebugInfo.GetTypeSize(P.PropTypeName, SetSz) and (SetSz > 8));
      end;
    else
      Exit(False);
    end;
  end;

  function InvokeGetter(FuncVA, ObjAddr: UInt64;
    const P: TRttiPropInfo): TExprValue;
  var
    Rax, Xmm0: UInt64;
    UsesXmm0:  Boolean;
    Slot:      UInt64;
    SlotSize:  Integer;
  begin
    Result := Default(TExprValue);

    if ReturnsViaVarOut(P) then begin
      // Decide the result-slot size so the callee doesn't write past the
      // page. 16 bytes for a TVarData; up to 256 bytes for records (covers
      // the common cases without parsing the TypeInfo size yet); 8 bytes
      // for managed pointer-sized handles (strings, dyn-arrays).
      case P.PropTypeKind of
        TK_VARIANT:               SlotSize := 16;
        TK_RECORD, TK_MRECORD:    SlotSize := 256;
        TK_SET: begin
          SlotSize := 0;
          FDebugInfo.GetTypeSize(P.PropTypeName, SlotSize);
          if SlotSize < 1 then SlotSize := 32;
        end;
      else
        SlotSize := 8;
      end;
      Slot := FDebugger.GetRemoteScratchSlot(SlotSize);
      if Slot = 0 then
        Exit(InvalidValue('<getter scratch alloc failed>'));
      // Delphi Win64 ABI for functions returning a managed/record result:
      // RCX = Self, RDX = hidden result-slot pointer. (Counter-intuitive vs
      // pure MS x64 ABI; Delphi keeps Self in the first integer register.)
      // Positional: Self first, hidden result-slot pointer second. On x64 those
      // land in RCX and RDX; naming them that way here would bake in an ABI
      // this call deliberately does not know about.
      if not FDebugger.RunRemoteCallEx(FuncVA, ObjAddr, Slot, 0, 0, Rax, Xmm0) then
        Exit(InvalidValue('<getter invocation failed>'));
      Result.TypeHint     := P.PropTypeName;
      Result.TypeInfoAddr := P.PropTypeInfoAddr;
      Result.Address      := Slot;
      Result.Size         := SlotSize;
      Result.IsValid      := True;
      // For string-like and dyn-array results, the slot now holds a pointer
      // to the actual data. Lift it into RawValue so the existing local-var
      // string / dyn-array formatters keep working unchanged.
      case P.PropTypeKind of
        TK_LSTRING, TK_USTRING, TK_WSTRING, TK_DYNARRAY: begin
          if not FDebugger.ReadProcessMemoryAt(Slot, @Result.RawValue, 8) then
            Exit(InvalidValue('<getter result deref failed>'));
        end;
        TK_RECORD, TK_MRECORD: begin
          // Decide by the DECLARED size, not by probing the slot. A record <= 8
          // bytes (and not managed) is returned PACKED IN RAX; the callee never
          // touches the slot. Write those RAX bytes into the slot so the value
          // has a memory home and its fields can be read at slot + offset -
          // exactly like the larger records that arrive in the slot directly.
          // Keeping TypeHint = the record type is what lets `.X` resolve; the
          // old 'Cardinal'/'Double' reinterpret dropped fields / showed garbage.
          var RecSz: Integer := 0;
          FDebugInfo.GetTypeSize(P.PropTypeName, RecSz);
          if (P.PropTypeKind = TK_RECORD) and (RecSz > 0) and (RecSz <= 8) then
            FDebugger.WriteMemoryAt(Slot, @Rax, 8);
          Result.TypeHint := P.PropTypeName;
          Result.Address  := Slot;
          Result.RawValue := 0;
          if RecSz > 0 then
            Result.Size := RecSz;
        end;
        TK_SET: begin
          // A >8-byte set lives in the slot by value; Address at the slot lets
          // DecodeSetMembers read the full width. (<= 8-byte sets take the RAX
          // path below, not this branch.)
          Result.TypeHint := P.PropTypeName;
          Result.Address  := Slot;
          Result.RawValue := 0;
        end;
        // TK_VARIANT -- leave RawValue=0; FormatVariantAt reads via Address.
      end;
      Exit;
    end;

    UsesXmm0 := False;
    // Return-class dispatch for non var-out returns:
    //   Integer/ordinal/pointer/class/interface (<=8 bytes) -> integer register.
    //   Single/Double/Extended/TDateTime -> the float slot.
    //   Currency is TK_FLOAT but on Win64 it is ABI-wise a scaled Int64 in RAX.
    // On a target whose floats come back on the x87 stack, Currency travels
    // with them instead -- that rule is the target's, not a constant, which is
    // why it is asked rather than assumed.
    case P.PropTypeKind of
      TK_INTEGER, TK_INT64, TK_ENUM, TK_CHAR, TK_WCHAR, TK_SET, TK_CLASS,
      TK_INTERFACE, TK_POINTER: ;
      TK_FLOAT:
        UsesXmm0 := CurrencyReturnsWithFloats or
                    not SameText(P.PropTypeName, 'Currency');
    else
      Exit(InvalidValue(Format('<getter for "%s" returns %s -- not yet supported>',
        [P.Name, P.PropTypeName])));
    end;
    if not FDebugger.RunRemoteCallEx(FuncVA, ObjAddr, 0, 0, 0, Rax, Xmm0) then
      Exit(InvalidValue('<getter invocation failed>'));
    Result.TypeHint     := P.PropTypeName;
    Result.TypeInfoAddr := P.PropTypeInfoAddr;
    if UsesXmm0 then
      Result.RawValue := NormaliseFloatReturn(Xmm0, P.PropTypeName)
    else
      Result.RawValue := Rax;
    Result.Size    := SizeForKind(P.PropTypeKind, P.PropTypeName);
    Result.IsValid := True;
  end;

  function ResolveProperty(ObjAddr: UInt64; const P: TRttiPropInfo): TExprValue;
  var
    VmtAddr, FuncVA: UInt64;
  begin
    if not P.HasGetter then
      Exit(InvalidValue(Format('<property %s has no read accessor>', [P.Name])));
    case P.GetKind of
      akField:
        Exit(ReadFieldBackedProp(ObjAddr, P.GetValue, P));
      akStatic:
        Exit(InvokeGetter(P.GetValue, ObjAddr, P));
      akVirtual: begin
        // VMT slot offset; resolve through the instance's actual VMT. Both the
        // object's VMT pointer and the slot inside it are one TARGET pointer
        // wide -- reading 8 on a 32-bit target splices the adjacent slot in and
        // the call would be dispatched to a nonsense address.
        var PtrSize := FDebugger.TargetLayout.PointerSize;
        VmtAddr := 0;
        FuncVA  := 0;
        if not FDebugger.ReadProcessMemoryAt(ObjAddr, @VmtAddr, PtrSize) then
          Exit(InvalidValue('<vmt read failed>'));
        if not FDebugger.ReadProcessMemoryAt(VmtAddr + P.GetValue, @FuncVA, PtrSize) then
          Exit(InvalidValue('<vmt slot read failed>'));
        Exit(InvokeGetter(FuncVA, ObjAddr, P));
      end;
    end;
    Result := InvalidValue('<unknown property accessor kind>');
  end;

  function ResolveRsmField(ObjAddr: UInt64; const M: TClassMember): TExprValue;
  var
    Raw:  UInt64;
    Size: Integer;
  begin
    Result := Default(TExprValue);
    if M.TypeName <> '' then
      Result.TypeHint := M.TypeName
    else
      Result.TypeHint := 'Pointer';
    Size := PrimTypeSize(Result.TypeHint);
    if Size = 0 then Size := 8;
    Result.Address := ObjAddr + UInt64(M.FieldOffset);
    Result.Size    := Size;
    if ReadValueAt(Result.Address, Result.TypeHint, Size, Raw) then begin
      Result.RawValue := Raw;
      Result.IsValid  := True;
    end else
      Result := InvalidValue(Format('<read failed @ 0x%x>', [Result.Address]));
  end;

  // Synthesize a TRttiPropInfo from a RSM property + its bound method, then
  // delegate to the existing InvokeGetter -- keeps return-class dispatch
  // (RAX / XMM0 / hidden var-out) consistent with the TPropInfo path.
  function ResolveRsmMethodProp(ObjAddr: UInt64;
    const PropMember, MethodMember: TClassMember; const ClassName: string): TExprValue;
  var
    P:      TRttiPropInfo;
    FuncVA: UInt64;
  begin
    // Without a resolved return type we cannot pick the getter's calling
    // convention (RAX vs XMM0 vs a hidden var-out slot for a managed result).
    // Guessing 'Pointer' for what is actually a managed return (dyn-array /
    // string / Variant / large record) sets up a malformed synthetic call:
    // the callee never returns to the trap, WaitForDebugEvent blocks forever
    // and the whole adapter hangs. Refuse the call and report unknown instead.
    if PropMember.TypeName = '' then
      Exit(InvalidValue(Format('<%s: getter return type unknown>',
        [PropMember.Name])));
    P := Default(TRttiPropInfo);
    P.Name         := PropMember.Name;
    P.HasGetter    := True;
    P.GetKind      := akStatic;
    P.PropTypeName := PropMember.TypeName;
    P.PropTypeKind := TypeNameToKind(P.PropTypeName);
    if not FDebugger.TryResolveSymbolVA(ClassName + '.' + MethodMember.Name, FuncVA) then
      Exit(InvalidValue(Format('<getter %s.%s not in MAP>', [ClassName, MethodMember.Name])));
    P.GetValue := FuncVA;
    Result := InvokeGetter(FuncVA, ObjAddr, P);
  end;

  function TryResolveViaRsm(const Field: string; out V: TExprValue): Boolean;
  var
    ClassName: string;
    Members:   TArray<TClassMember>;
  begin
    Result := False;
    V      := Default(TExprValue);
    if FDebugInfo = nil then begin
      DapLog(Format('  RsmDot: FDebugInfo=nil for "%s"', [Field]));
      Exit;
    end;
    if FRtti = nil then begin
      DapLog(Format('  RsmDot: FRtti=nil for "%s"', [Field]));
      Exit;
    end;
    ClassName := FRtti.GetInstanceClassName(Base.RawValue);
    // Decide whether Base is a class instance pointer (member offset added
    // to RawValue, the actual heap pointer) or an inline value (record,
    // struct) where the bytes live at Base.Address and member offsets
    // add to Address. The runtime VMT check disambiguates: when it
    // succeeds we're on a class, otherwise treat as a record / inline
    // value. Without this split, accessing `FPoint.X` on a TPoint3D
    // field falls into the class branch and reads from `floatBits + 0`
    // -- garbage -- instead of `recordAddress + 0`.
    var IsClass: Boolean := (ClassName <> '') and
                             FRtti.IsClassInstance(Base.RawValue);
    if ClassName = '' then
      ClassName := Base.TypeHint;
    DapLog(Format('  RsmDot field="%s" Base.Raw=$%x Base.Addr=$%x ClassName="%s" BaseHint="%s" IsClass=%s',
      [Field, Base.RawValue, Base.Address, ClassName, Base.TypeHint,
       BoolToStr(IsClass, True)]));
    if ClassName = '' then Exit;
    // Disambiguate a bare class name shared by two units (Data.DB.TFields vs the
    // nested System.Classes.TFieldsCache.TFields) by the OBJECT's real instance
    // size, read from its VMT. Without it, member resolution and expansion used
    // whichever record was indexed first and showed the wrong class's fields.
    var InstSize := 0;
    if IsClass then
      InstSize := FRtti.GetInstanceSize(Base.RawValue);
    if not FDebugInfo.GetClassMembers(ClassName, Members, InstSize) then begin
      DapLog(Format('  RsmDot: no class members for "%s"', [ClassName]));
      Exit;
    end;
    DapLog(Format('  RsmDot: class "%s" has %d members', [ClassName, Length(Members)]));

    var ObjAddr: UInt64;
    if IsClass then
      ObjAddr := Base.RawValue
    else
      ObjAddr := Base.Address;
    if ObjAddr = 0 then Exit;

    for var I := 0 to High(Members) do begin
      if not SameText(Members[I].Name, Field) then Continue;
      case Members[I].Kind of
        cmkField: begin
          V := ResolveRsmField(ObjAddr, Members[I]);
          Exit(True);
        end;
        cmkProperty: begin
          // TD32 names a method getter explicitly -> method-backed; invoke it
          // FIRST. TD32 leaves member hashes 0 and FieldOffset 0 for getter
          // properties, so neither the hash match nor the FieldOffset fallback
          // below could classify it (and a 0 = 0 hash match would falsely bind
          // it to the first field). RSM carries no GetterName, so this is
          // TD32-only; RSM keeps the hash path.
          if Members[I].GetterName <> '' then begin
            // Resolve the getter against its DECLARING class (DeclClass), so an
            // INHERITED getter (e.g. TComponent.GetComponentCount on a
            // TApplication instance) is found under the right class symbol.
            // Pass the id-resolved return kind/size (from GetClassMembers) so the
            // getter's ABI is chosen deterministically, not by re-looking-up the
            // return type NAME (which two same-named types would share).
            V := ApplyMethodCall(Base, Members[I].GetterName, [], Members[I].DeclClass,
                   Members[I].TypeName, 0, False, False,
                   Members[I].TypeKind, Members[I].TypeSize);
            if V.IsValid and (Members[I].TypeName <> '') then
              V.TypeHint := Members[I].TypeName;
            // Propagate the getter's own outcome (value OR its specific error,
            // e.g. "<getter ... not in MAP>" / "<method invocation failed>")
            // instead of falling through to the generic "<.Name not found>",
            // which hid the real reason a getter-backed property failed.
            Exit(True);
          end;
          // RSM: bind via a NON-ZERO getter hash to a sibling field or method.
          for var J := 0 to High(Members) do begin
            if (Members[I].GetterHash = 0) or
               (Members[J].Hash <> Members[I].GetterHash) then Continue;
            if Members[J].Kind = cmkField then begin
              V := ResolveRsmField(ObjAddr, Members[J]);
              if (Members[I].TypeName <> '') and V.IsValid then
                V.TypeHint := Members[I].TypeName;
              Exit(True);
            end else if Members[J].Kind = cmkMethod then begin
              V := ResolveRsmMethodProp(ObjAddr, Members[I], Members[J], ClassName);
              Exit(True);
            end;
          end;
          // Field-backed property carries the backing field's byte offset
          // directly (TD32 field-backed property, or RSM without a hash match).
          if Members[I].FieldOffset > 0 then begin
            var Synth: TClassMember;
            Synth := Members[I];
            Synth.Kind := cmkField;
            V := ResolveRsmField(ObjAddr, Synth);
            if V.IsValid and (Members[I].TypeName <> '') then
              V.TypeHint := Members[I].TypeName;
            Exit(True);
          end;
          // Field-name convention `read FName`: TD32 sometimes loses a property's
          // backing offset AND getter name (e.g. Exception.Message off 0, no
          // getter, really backed by FMessage). Bind to a sibling field 'F'+Name.
          for var J := 0 to High(Members) do
            if (Members[J].Kind = cmkField) and
               SameText(Members[J].Name, 'F' + Members[I].Name) then begin
              V := ResolveRsmField(ObjAddr, Members[J]);
              if V.IsValid and (Members[I].TypeName <> '') then
                V.TypeHint := Members[I].TypeName;
              Exit(True);
            end;
          Exit;
        end;
      end;
    end;
  end;

begin
  // Intrinsic on every Delphi class: ClassName is a method that returns
  // the type's ShortString name -- handled via the runtime VMT slot
  // rather than a remote method call so it works even when the class's
  // method symbols aren't reachable in the MAP (e.g. inherited from
  // TObject and exported under a parent class name).
  if SameText(Field, 'ClassName') and (FRtti <> nil) and
     (Base.RawValue >= 65536) then begin
    var ClassNameStr := FRtti.GetInstanceClassName(Base.RawValue);
    if ClassNameStr <> '' then begin
      Result          := Default(TExprValue);
      Result.TypeHint := 'string';
      Result.RawValue := 0;
      Result.Size     := 8;
      Result.IsValid  := True;
      // Inline string allocation into a debuggee scratch slot so the
      // string formatter can dereference it.
      var Ptr: UInt64;
      if FDebugger.AllocateRemoteString(ClassNameStr, 'UnicodeString', Ptr) then
        Result.RawValue := Ptr;
      Exit;
    end;
  end;

  // Delphi lets a pointer-to-record be dotted without the caret -- `RecP.B` is
  // `RecP^.B` -- so accept it here rather than making the user write a caret
  // the language does not require. Only for a pointee that is genuinely an
  // aggregate: a `^Integer` has no fields, and a dynamic array (also spelled
  // `^Element` by TD32) must keep falling through to the array paths.
  if (Base.TypeHint <> '') and (Base.TypeHint[1] = '^') and Base.IsValid then begin
    var Pointee := Copy(Base.TypeHint, 2, MaxInt);
    if IsByValueAggregate(Pointee) and (Base.RawValue >= 65536) then begin
      var AsRecord := Default(TExprValue);
      AsRecord.TypeHint := Pointee;
      AsRecord.Address  := Base.RawValue;
      AsRecord.RawValue := 0;
      AsRecord.Size     := ElementStride(Pointee);
      AsRecord.IsValid  := True;
      Exit(ApplyDot(AsRecord, Field));
    end;
  end;

  DapLog(Format('  ApplyDot field="%s" Base=$%x BaseValid=%s BaseHint="%s" FRtti=%s IsClassInst=%s',
    [Field, Base.RawValue, BoolToStr(Base.IsValid, True), Base.TypeHint,
     BoolToStr(FRtti <> nil, True),
     BoolToStr((FRtti <> nil) and (Base.RawValue >= 65536) and FRtti.IsClassInstance(Base.RawValue), True)]));
  // The RTTI-based paths (1 + 2) require a valid VMT (IsClassInstance). The
  // RSM-based path (3) only needs the static class-name TypeHint and a
  // plausible pointer -- it does not deref the VMT. Splitting the gate lets
  // class-member lookup work for classes whose VMT can't be recognised at
  // runtime (e.g. an early breakpoint where the form isn't fully initialised,
  // or simply a Self pointer whose VMT slot isn't where IsValidVmt expects).
  if (FRtti <> nil) and Base.IsValid and (Base.RawValue >= 65536) and
     FRtti.IsClassInstance(Base.RawValue) then begin
    // 1. Property name match via TPropInfo RTTI (published / $M+ classes).
    //    This path carries full PropTypeInfoAddr so enum-name resolution and
    //    record/dyn-array expansion keep working -- preferred when available.
    var Props := FRtti.GetClassProperties(Base.RawValue);
    for var I := 0 to High(Props) do
      if SameText(Props[I].Name, Field) then
        Exit(ResolveProperty(Base.RawValue, Props[I]));

    // 2. Direct field name match (e.g. `TheWidget.FName`).
    var Fields := FRtti.ExpandClass(Base.RawValue);
    for var I := 0 to High(Fields) do
      if SameText(Fields[I].Name, Field) then
        Exit(ReadFieldValue(Fields[I]));

    // 3. RSM-driven class-member resolution. Catches $M- classes (no published
    //    table -> RTTI returns nothing) and private/public members invisible to
    //    TPropInfo. Only kicks in when paths 1/2 miss.
    var RsmVal: TExprValue;
    // A True result means a class member matched Field; surface its outcome
    // (value or its own specific error) instead of dropping an invalid result
    // and falling through to the generic "<.Field not found>".
    if TryResolveViaRsm(Field, RsmVal) then
      Exit(RsmVal);
  end;

  // 3b. RSM-based resolution OUTSIDE the IsClassInstance gate. The RSM
  // path covers two cases the inner block misses:
  //   - Class instances on which IsValidVmt failed (e.g. big SampleApp VCL
  //     forms whose VMT slot is laid out differently from what
  //     IsValidVmt expects).
  //   - Records / inline value types accessed by field, where Base
  //     carries the record's address (Base.Address) but
  //     Base.RawValue is the first 8 bytes of the record's payload --
  //     useless as an instance pointer.
  // TryResolveViaRsm picks the right ObjAddr internally (RawValue for
  // confirmed classes, Address for everything else).
  if Base.IsValid and (Base.TypeHint <> '') and
     ((Base.RawValue >= 65536) or (Base.Address >= 65536)) then begin
    var RsmVal2: TExprValue;
    // TryResolveViaRsm returns True only when a class member actually matched
    // Field. When it did, surface its outcome -- value OR its own specific
    // error (e.g. a getter that could not be invoked) -- rather than dropping
    // an invalid result and falling through to the generic "<.Field not found>"
    // below, which hid the real reason getter-backed properties failed.
    if TryResolveViaRsm(Field, RsmVal2) then
      Exit(RsmVal2);
  end;

  // 3c. A parameterless METHOD named without parentheses. In Pascal `Obj.M` IS
  // a call -- the same rule the bare-identifier path already applies to a free
  // function (`Now` = `Now()`), never extended to a method on an object.
  // Without it the name fell through to the qualified-name lookup below, which
  // found the METHOD'S OWN CODE ADDRESS and read it as data: `W.GetSelf`
  // returned 0x83EC8B55 on Win32 and 0xEC834855 on Win64 -- `push ebp; mov
  // ebp,esp` and `push rbp; sub rsp`, the prologue of GetSelf itself. It also
  // poisoned every chain built on it (`W.GetSelf.Name`).
  //
  // A method that TAKES arguments must not be auto-called; the declared
  // parameter count is what decides, exactly as the free-function guard does.
  // Fields and properties are resolved above, so a member sharing a method's
  // name still wins there.
  if Base.IsValid and (FDebugInfo <> nil) then begin
    var CallClass := '';
    if (FRtti <> nil) and (Base.RawValue >= 65536) then
      CallClass := FRtti.GetInstanceClassName(Base.RawValue);
    if CallClass = '' then
      CallClass := Base.TypeHint;
    if CallClass <> '' then begin
      var MethodParams: TArray<TMethodParam>;
      var MethodHasSelf: Boolean;
      if FDebugInfo.TryGetMethodParams(CallClass, Field, MethodParams, MethodHasSelf) and
         (Length(MethodParams) = 0) then
        Exit(ApplyMethodCall(Base, Field, [], CallClass, '', 0, False, False));
    end;
  end;

  // 4. Qualified-name lookup: nested-proc parent locals stored as "Parent.Field".
  var LV: TLocalValue;
  if FDebugger.EvaluateName(Field, LV) then
    Exit(LocalToExpr(LV));

  Result := InvalidValue(Format('<.%s not found>', [Field]));
end;

{ Suffix chain }

function TExprEvaluator.ApplySuffixes(const Base: TExprValue): TExprValue;
var
  IdxVal: TExprValue;
  Field:  string;
begin
  Result := Base;
  while True do begin
    SkipWS;
    if FPos > Length(FExpr) then
      Break;
    case FExpr[FPos] of
      '[': begin
        Inc(FPos);
        // Collect comma-separated indices: arr[i] or arr[i,j,...] (Variant arrays)
        var Indices: TArray<Int64>;
        // The same indices UNCOERCED. A default array property may take a
        // string (`dataset['CODE']` -> FieldValues['CODE']), and
        // Int64(RawValue) throws that away.
        var IndexValues: TArray<TExprValue>;
        SetLength(Indices, 0);
        SetLength(IndexValues, 0);
        repeat
          IdxVal := ParseExpr;
          if not IdxVal.IsValid then
            Exit(IdxVal);
          Indices     := Indices + [Int64(IdxVal.RawValue)];
          IndexValues := IndexValues + [IdxVal];
          SkipWS;
        until not MatchChar(',');
        if not MatchChar(']') then
          Exit(InvalidValue('<missing ] after index>'));
        // A class instance indexes through its `default` array property, which
        // is what `Obj[X]` means in Pascal. Checked before the array forms: an
        // object is not an array, and without this it fell through to
        // "<cannot index type>".
        var DefaultProp, DefaultPropClass, DefaultPropType: string;
        var DefaultPropKind: Byte;
        var DefaultPropSize: Integer;
        if (not Result.IsTypeRef) and
           TryFindDefaultProperty(Result, DefaultProp, DefaultPropClass, DefaultPropType,
             DefaultPropKind, DefaultPropSize) then
          Result := ApplyMethodCall(Result, DefaultProp, IndexValues, DefaultPropClass,
                      DefaultPropType, 0, False, False, DefaultPropKind, DefaultPropSize)
        else if IsStaticArrayHint(Result.TypeHint) then
          Result := ApplyStaticArrayIndex(Result, Indices)
        else if Length(Indices) = 1 then
          Result := ApplyIndex(Result, Indices[0])
        else
          Result := ApplyVarArrayIndex(Result, Indices);
      end;
      '.': begin
        Inc(FPos);
        SkipWS;
        Field := ScanIdent;
        if Field = '' then
          Exit(InvalidValue('<expected field name after .>'));
        SkipWS;
        // Class-reference member: `TFoo.Bar` where the base is a bare class type
        // (not an instance). Dispatches to ApplyClassRefMember, consuming an
        // optional `(args)`. Class methods / class functions are invoked here;
        // class const / var fall through to ApplyClassRefMember's "not found".
        var ClassRefMembers: TArray<TClassMember>;
        if Result.IsTypeRef and (FDebugInfo <> nil) and
           FDebugInfo.GetClassMembers(Result.TypeHint, ClassRefMembers) then begin
          var ClassRefArgs: TArray<TExprValue>;
          SetLength(ClassRefArgs, 0);
          if (FPos <= Length(FExpr)) and (FExpr[FPos] = '(') then begin
            Inc(FPos);
            SkipWS;
            if (FPos <= Length(FExpr)) and (FExpr[FPos] <> ')') then
              repeat
                var A := ParseExpr;
                if not A.IsValid then Exit(A);
                ClassRefArgs := ClassRefArgs + [A];
                SkipWS;
              until not MatchChar(',');
            if not MatchChar(')') then
              Exit(InvalidValue('<missing ) after class method args>'));
          end;
          Result := ApplyClassRefMember(Result.TypeHint, Field, ClassRefArgs);
          Continue;
        end;
        // Possibilities right after `.Ident`:
        //   `.Ident(args)`  -> ordinary method call.
        //   `.Ident[args]`  -> ambiguous -- could be:
        //                     (a) a property (`PubTriple`) returning a string /
        //                         dynarray / variant that the user then indexes,
        //                         or
        //                     (b) an indexed-accessor sugar over a method
        //                         (`Items[3]` where Items is a method).
        //                     Resolve by trying `ApplyDot` first; if that
        //                     yields a value whose TypeHint is an indexable
        //                     primitive (string / TArray<...> / Variant /
        //                     array of ...), the `[i]` is the user-level
        //                     index. Otherwise fall back to method-call
        //                     dispatch with the indices as arguments.
        //   `.Ident`        -> property / field access via RTTI / RSM.
        if (FPos <= Length(FExpr)) and (FExpr[FPos] = '(') then begin
          // Plain method call.
          Inc(FPos);
          var Args: TArray<TExprValue>;
          SetLength(Args, 0);
          SkipWS;
          if (FPos <= Length(FExpr)) and (FExpr[FPos] <> ')') then begin
            repeat
              var A := ParseExpr;
              if not A.IsValid then Exit(A);
              Args := Args + [A];
              SkipWS;
            until not MatchChar(',');
          end;
          if not MatchChar(')') then
            Exit(InvalidValue('<missing ) after method args>'));
          Result := ApplyMethodCall(Result, Field, Args);
        end else if (FPos <= Length(FExpr)) and (FExpr[FPos] = '[') then begin
          // `.Ident[...]` is ambiguous: either `.Ident` is a non-indexed
          // property whose (string / array / variant) result is then indexed
          // (`obj.Caption[2]`), or `.Ident` is an indexed property whose getter
          // TAKES the index (`obj.Items[2]`).
          //
          // When the debug info already says `.Ident` is an INDEXED property,
          // there is nothing to probe: `[...]` are its arguments. Go straight to
          // the call. This is the only correct branch for an indexed property --
          // evaluating `.Ident` with no arguments would fire the getter with the
          // index registers holding garbage.
          var HandledAsIndexedCall := False;
          var IndexedPropType: string;
          var IndexedPropKind: Byte;
          var IndexedPropSize: Integer;
          if IsKnownIndexedProperty(Result, Field, IndexedPropType,
               IndexedPropKind, IndexedPropSize) then begin
            Inc(FPos);
            var IdxArgs: TArray<TExprValue>;
            SetLength(IdxArgs, 0);
            SkipWS;
            if (FPos <= Length(FExpr)) and (FExpr[FPos] <> ']') then begin
              repeat
                var A := ParseExpr;
                if not A.IsValid then Exit(A);
                IdxArgs := IdxArgs + [A];
                SkipWS;
              until not MatchChar(',');
            end;
            if not MatchChar(']') then
              Exit(InvalidValue('<missing ] after indexed-property args>'));
            Result := ApplyMethodCall(Result, Field, IdxArgs, '', IndexedPropType,
                        0, False, False, IndexedPropKind, IndexedPropSize);
            HandledAsIndexedCall := True;
          end;

          if not HandledAsIndexedCall then begin
            // Not known to be indexed. Evaluate `.Ident`; if it yields an
            // indexable value, the top-level `[` branch consumes `[...]` on the
            // next iteration. Otherwise treat `[...]` as accessor arguments -
            // this is the metadata-less fallback (RTTI-only or MAP-only targets)
            // and the only place the zero-argument probe still runs.
            var DotResult := ApplyDot(Result, Field);
            if DotResult.IsValid and
               (IsStringTypeHint(DotResult.TypeHint) or
                SameText(DotResult.TypeHint, 'Variant') or
                DotResult.TypeHint.StartsWith('TArray<', True) or
                DotResult.TypeHint.StartsWith('array of ', True) or
                // TD32 types a dyn-array property as `^Element`; index the result.
                DotResult.TypeHint.StartsWith('^', True)) then
              Result := DotResult
            else begin
              Inc(FPos);
              var Args: TArray<TExprValue>;
              SetLength(Args, 0);
              SkipWS;
              if (FPos <= Length(FExpr)) and (FExpr[FPos] <> ']') then begin
                repeat
                  var A := ParseExpr;
                  if not A.IsValid then Exit(A);
                  Args := Args + [A];
                  SkipWS;
                until not MatchChar(',');
              end;
              if not MatchChar(']') then
                Exit(InvalidValue('<missing ] after method args>'));
              Result := ApplyMethodCall(Result, Field, Args);
            end;
          end;
        end else
          Result := ApplyDot(Result, Field);
      end;
      '^': begin
        // Pointer dereference: `P^` reads the value at the pointer.
        // The result's TypeHint is the inner type (strip leading `^`).
        // For `^Primitive`, the inner type drives the read size below.
        Inc(FPos);
        var Addr := Result.RawValue;
        var InnerHint := Result.TypeHint;
        if (Length(InnerHint) >= 2) and (InnerHint[1] = '^') then
          InnerHint := Copy(InnerHint, 2, MaxInt);
        var ReadBytes: Integer := 8;
        if SameText(InnerHint, 'Byte') or SameText(InnerHint, 'ShortInt') or
           SameText(InnerHint, 'AnsiChar') or SameText(InnerHint, 'Boolean') then
          ReadBytes := 1
        else if SameText(InnerHint, 'Word') or SameText(InnerHint, 'SmallInt') or
                SameText(InnerHint, 'Char') or SameText(InnerHint, 'WideChar') then
          ReadBytes := 2
        else if SameText(InnerHint, 'Integer')  or SameText(InnerHint, 'Cardinal') or
                SameText(InnerHint, 'LongInt')  or SameText(InnerHint, 'LongWord') or
                SameText(InnerHint, 'Int32')    or SameText(InnerHint, 'UInt32')   or
                SameText(InnerHint, 'Single') then
          ReadBytes := 4;
        // A record (or set / static array) pointee is an AGGREGATE: there is no
        // scalar to lift into RawValue, and reading 8 bytes there produced a
        // value with no Address at all -- `RecP^` rendered as `$0 (TPackedRec)`
        // and `RecP^.B` could not find a field, because the field resolver
        // needs the record's address. Point Address at the record instead, the
        // same shape a by-value record takes everywhere else.
        if IsByValueAggregate(InnerHint) then begin
          if Addr < 65536 then
            Exit(InvalidValue(Format('<deref of nil %s>', [Result.TypeHint])));
          Result := Default(TExprValue);
          Result.TypeHint := InnerHint;
          Result.Address  := Addr;
          Result.RawValue := 0;
          Result.Size     := ElementStride(InnerHint);
          Result.IsValid  := True;
          Continue;
        end;
        var Deref: UInt64 := 0;
        if FDebugger.ReadProcessMemoryAt(Addr, @Deref, ReadBytes) then begin
          Result := Default(TExprValue);
          Result.RawValue := Deref;
          Result.TypeHint := InnerHint;
          Result.Address  := Addr;
          Result.IsValid  := True;
        end else
          Exit(InvalidValue(Format('<deref failed at $%x>', [Addr])));
      end;
    else
      Break;
    end;
  end;
end;

{ Recursive descent }

// Word-boundary keyword peek. Matches case-insensitively, requires the next
// char (if any) to NOT be an identifier-continuation char so e.g. `andrew`
// doesn't match `and`. Consumes only on success.
function TExprEvaluator.MatchKeyword(const KW: string): Boolean;
begin
  Result := False;
  SkipWS;
  if FPos + Length(KW) - 1 > Length(FExpr) then Exit;
  if not SameText(Copy(FExpr, FPos, Length(KW)), KW) then Exit;
  if (FPos + Length(KW) <= Length(FExpr)) and
     CharInSet(FExpr[FPos + Length(KW)],
       ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
    Exit;
  Inc(FPos, Length(KW));
  Result := True;
end;

function TExprEvaluator.IsFloatHint(const H: string): Boolean;
begin
  Result := SameText(H, 'Double') or SameText(H, 'Single') or
            SameText(H, 'Extended') or SameText(H, 'TDateTime') or
            SameText(H, 'TDate') or SameText(H, 'TTime') or
            SameText(H, 'Real') or SameText(H, 'Currency');
end;

// Local var reads always return 8 raw bytes from the RBP slot. For sub-8
// primitive types, the upper bytes carry adjacent-stack garbage. Sign- or
// zero-extend the meaningful low bits so Integer / SmallInt / Byte / Boolean
// arithmetic and comparison behave like the source language.
function TExprEvaluator.MaskByType(V: UInt64; const T: string): Int64;
begin
  if SameText(T, 'Integer') or SameText(T, 'LongInt') then
    Result := Int64(Int32(V and $FFFFFFFF))
  else if SameText(T, 'Cardinal') or SameText(T, 'LongWord') then
    Result := Int64(V and $FFFFFFFF)
  else if SameText(T, 'SmallInt') then
    Result := Int64(SmallInt(V and $FFFF))
  else if SameText(T, 'Word') then
    Result := Int64(V and $FFFF)
  else if SameText(T, 'ShortInt') then
    Result := Int64(ShortInt(V and $FF))
  else if SameText(T, 'Byte') or SameText(T, 'Boolean') or
          SameText(T, 'ByteBool') or SameText(T, 'AnsiChar') then
    Result := Int64(V and $FF)
  else if SameText(T, 'WordBool') or SameText(T, 'Char') or
          SameText(T, 'WideChar') then
    Result := Int64(V and $FFFF)
  else if SameText(T, 'LongBool') then
    Result := Int64(V and $FFFFFFFF)
  else begin
    // Module-local enum types -- mask to the storage width implied by the
    // enum's MaxValue. Without this, an enum local read yields 8 bytes of
    // which only the low byte is meaningful, and `Mode = wmPaused` compares
    // garbage upper bits.
    var EnumInfo: TRsmEnumInfo;
    if (FDebugInfo <> nil) and FDebugInfo.LookupEnumInfo(T, EnumInfo) and
       (EnumInfo.Kind = 3) then begin
      if EnumInfo.MaxValue <= $FF then
        Result := Int64(V and $FF)
      else if EnumInfo.MaxValue <= $FFFF then
        Result := Int64(V and $FFFF)
      else
        Result := Int64(V and $FFFFFFFF);
      Exit;
    end;
    Result := Int64(V);
  end;
end;

function TExprEvaluator.AsDouble(const V: TExprValue): Double;
begin
  if SameText(V.TypeHint, 'Single') then
    Result := PSingle(@V.RawValue)^
  else if SameText(V.TypeHint, 'Currency') then
    Result := Int64(V.RawValue) / 10000.0
  else if IsFloatHint(V.TypeHint) then
    Result := PDouble(@V.RawValue)^
  else
    Result := MaskByType(V.RawValue, V.TypeHint);
end;

function TExprEvaluator.AsInt64(const V: TExprValue): Int64;
begin
  if IsFloatHint(V.TypeHint) then
    Result := Trunc(AsDouble(V))
  else
    Result := MaskByType(V.RawValue, V.TypeHint);
end;

function TExprEvaluator.MakeBool(B: Boolean): TExprValue;
begin
  Result := Default(TExprValue);
  Result.TypeHint := 'Boolean';
  if B then Result.RawValue := 1 else Result.RawValue := 0;
  Result.Size    := 1;
  Result.IsValid := True;
end;

function TExprEvaluator.MakeInt64(V: Int64): TExprValue;
begin
  Result := Default(TExprValue);
  Result.TypeHint := 'Int64';
  Result.RawValue := UInt64(V);
  Result.Size     := 8;
  Result.IsValid  := True;
end;

function TExprEvaluator.MakeDouble(V: Double): TExprValue;
begin
  Result := Default(TExprValue);
  Result.TypeHint := 'Double';
  Result.RawValue := PUInt64(@V)^;
  Result.Size     := 8;
  Result.IsValid  := True;
end;

function TExprEvaluator.MakePointer(V: UInt64): TExprValue;
begin
  Result := Default(TExprValue);
  Result.TypeHint := 'Pointer';
  Result.RawValue := V;
  Result.Size     := 8;
  Result.IsValid  := True;
end;

function TExprEvaluator.TryResolveEnumLiteral(const Name: string;
  out Ordinal: Integer; out EnumTypeName: string): Boolean;
begin
  Result := False;
  if FDebugInfo = nil then Exit;
  Result := FDebugInfo.TryResolveEnumLiteral(Name, Ordinal, EnumTypeName);
end;

// Peek at the current `[` to decide whether what follows is a set
// literal or a deref. Saves and restores FPos so the actual parser
// can re-consume from scratch.
function TExprEvaluator.LooksLikeSetLiteral: Boolean;
var
  Save: Integer;
  Ord: Integer;
  EnumTypeName: string;
begin
  Result := False;
  if (FPos > Length(FExpr)) or (FExpr[FPos] <> '[') then Exit;
  Save := FPos;
  try
    Inc(FPos);
    SkipWS;
    if (FPos <= Length(FExpr)) and (FExpr[FPos] = ']') then
      Exit(True);  // empty set `[]`
    if (FPos > Length(FExpr)) or
       not CharInSet(FExpr[FPos], ['A'..'Z', 'a'..'z', '_']) then
      Exit;  // not even an identifier -- treat as deref
    var Name := ScanIdent;
    Result := TryResolveEnumLiteral(Name, Ord, EnumTypeName);
  finally
    FPos := Save;
  end;
end;

// Builds a Pascal set bitmask. Each element resolves through
// TryResolveEnumLiteral; bit `ordinal` of the byte mask is set. All
// elements should belong to the same enum type (Pascal source rule);
// the result's TypeHint becomes `<EnumName>s` (the conventional set
// type name) so a comparison against a `set of` field's value works.
function TExprEvaluator.ParseSetLiteral: TExprValue;
var
  Mask:         UInt64;
  ElemTypeName: string;
  Ord:          Integer;
  ElemEnum:     string;
begin
  Result := Default(TExprValue);
  Mask := 0;
  ElemTypeName := '';
  if not MatchChar('[') then Exit(InvalidValue('<missing [ in set literal>'));
  SkipWS;
  if not MatchChar(']') then begin
    repeat
      SkipWS;
      if (FPos > Length(FExpr)) or
         not CharInSet(FExpr[FPos], ['A'..'Z', 'a'..'z', '_']) then
        Exit(InvalidValue('<set element: identifier expected>'));
      var Name := ScanIdent;
      if not TryResolveEnumLiteral(Name, Ord, ElemEnum) then
        Exit(InvalidValue(Format('<set element "%s" is not an enum value>', [Name])));
      if (ElemTypeName <> '') and not SameText(ElemTypeName, ElemEnum) then
        Exit(InvalidValue(Format('<set elements must share a type (%s vs %s)>',
          [ElemTypeName, ElemEnum])));
      ElemTypeName := ElemEnum;
      if (Ord >= 0) and (Ord < 64) then
        Mask := Mask or (UInt64(1) shl Ord);
      SkipWS;
    until not MatchChar(',');
    if not MatchChar(']') then
      Exit(InvalidValue('<missing ] in set literal>'));
  end;
  Result.RawValue := Mask;
  Result.Size     := 1;  // most Delphi enums fit in a single byte
  Result.IsValid  := True;
  Result.IsSet    := True;
  if ElemTypeName = '' then
    Result.TypeHint := 'set of ?'
  else
    // Conventional Delphi naming: TWorkMode -> TWorkModes. Falls back
    // to 'set of <Enum>' when the +s form isn't a recognised type
    // (callers that need precise typing can match either form).
    Result.TypeHint := ElemTypeName + 's';
end;

function TExprEvaluator.IsKnownTypeName(const Name: string): Boolean;
var
  EnumInfo: TRsmEnumInfo;
  Members:  TArray<TClassMember>;
begin
  if IsFloatHint(Name)        then Exit(True);
  if IsStringTypeHint(Name)   then Exit(True);
  // Built-in ordinal / pointer types.
  if SameText(Name, 'Integer')  or SameText(Name, 'LongInt')  or
     SameText(Name, 'Cardinal') or SameText(Name, 'LongWord') or
     SameText(Name, 'SmallInt') or SameText(Name, 'Word')     or
     SameText(Name, 'ShortInt') or SameText(Name, 'Byte')     or
     SameText(Name, 'Int64')    or SameText(Name, 'UInt64')   or
     SameText(Name, 'NativeInt')or SameText(Name, 'NativeUInt') or
     SameText(Name, 'Boolean')  or SameText(Name, 'ByteBool') or
     SameText(Name, 'WordBool') or SameText(Name, 'LongBool') or
     SameText(Name, 'AnsiChar') or SameText(Name, 'WideChar') or
     SameText(Name, 'Char')     or SameText(Name, 'Pointer')  or
     SameText(Name, 'TObject')  or SameText(Name, 'Variant')   or
     SameText(Name, 'OleVariant') or SameText(Name, 'TVarData') then
    Exit(True);
  // Module-local enum or set type known to the RSM.
  if (FDebugInfo <> nil) and FDebugInfo.LookupEnumInfo(Name, EnumInfo) then
    Exit(True);
  // Module-local class type -- recognised by presence of $2C/$2E/$31
  // member records under that name in the RSM class-member table.
  if (FDebugInfo <> nil) and FDebugInfo.GetClassMembers(Name, Members) then
    Exit(True);
  Result := False;
end;

// Pascal-style hard cast `TypeName(value)`. Numeric -> numeric is a bit-
// reinterpret aside from the int<->float boundary which converts. The result
// retains the cast's TypeHint so subsequent ops dispatch correctly.
function TExprEvaluator.ApplyCast(const TypeName: string; const V: TExprValue): TExprValue;
var
  D: Double;
  Sz: Integer;
  IsClassCast: Boolean;
  Members: TArray<TClassMember>;
begin
  Result := Default(TExprValue);
  Result.TypeHint := TypeName;
  Result.IsValid  := V.IsValid;
  Sz := PrimTypeSize(TypeName);
  if Sz = 0 then Sz := 8;
  Result.Size := Sz;
  // Variant / OleVariant / TVarData cast: preserve the operand's address so
  // the formatter can decode the 24-byte TVarData record at that location.
  // Workaround for cases where the RSM mis-types a Variant local as a
  // primitive (observed in nested procedures in SampleApp): user can type
  // `Variant(name)` in a watch/hover to force Variant decoding.
  if SameText(TypeName, 'Variant') or SameText(TypeName, 'OleVariant') or
     SameText(TypeName, 'TVarData') then begin
    Result.TypeHint := 'Variant';
    Result.Address  := V.Address;
    Result.RawValue := V.RawValue;
    Result.Size     := 24;
    Exit;
  end;
  // Class / interface cast: preserve the raw pointer bits and stamp the
  // claimed class name. Subsequent `.field` / `.method` access goes
  // through ApplyDot / ApplyMethodCall which use the runtime VMT class
  // name (`FRtti.GetInstanceClassName`) for member resolution -- that
  // gives the actual class regardless of the cast's TypeHint, so an
  // upcast like `TObject(TheWidget)` still resolves TWidget's members.
  //
  // Guard: NEVER reach the class-cast path for primitive type names. The
  // RSM class-member table can contain spurious entries for type aliases
  // (e.g. `Double` -- some unit's $2A record for the alias ends up in
  // FClassMembers), and treating `Double(42)` as a class cast skips the
  // int->float conversion and yields gibberish (42 raw bits interpreted
  // as Double ~= 0).
  IsClassCast := (not IsFloatHint(TypeName)) and
                 (not IsStringTypeHint(TypeName)) and
                 (SameText(TypeName, 'TObject') or
                  ((FDebugInfo <> nil) and FDebugInfo.GetClassMembers(TypeName, Members)));
  if IsClassCast then begin
    Result.RawValue := V.RawValue;
    Result.Address  := V.Address;
    Exit;
  end;
  if IsFloatHint(TypeName) and not IsFloatHint(V.TypeHint) then begin
    D := AsInt64(V);
    Result.RawValue := PUInt64(@D)^;
  end else if not IsFloatHint(TypeName) and IsFloatHint(V.TypeHint) then
    Result.RawValue := UInt64(Trunc(AsDouble(V)))
  else
    // Same numeric class or pointer -- keep raw bits, mask to target width.
    Result.RawValue := UInt64(MaskByType(V.RawValue, TypeName));
end;

function TExprEvaluator.IsBuiltinIntrinsic(const Name: string): Boolean;
begin
  Result := SameText(Name, 'Length')  or SameText(Name, 'SizeOf')   or
            SameText(Name, 'Ord')     or SameText(Name, 'High')     or
            SameText(Name, 'Low');
end;

function TExprEvaluator.ApplyIntrinsic(const Name: string;
  const Args: TArray<TExprValue>): TExprValue;

  function StringLength(const A: TExprValue): TExprValue;
  var L: Cardinal;
  begin
    if A.RawValue = 0 then Exit(MakeInt64(0));
    if not ReadU32(A.RawValue - 4, L) then
      Exit(InvalidValue('<Length: string read failed>'));
    Result := MakeInt64(Int64(Int32(L)));
  end;

  function DynArrayLength(const A: TExprValue): TExprValue;
  var L: UInt64;
  begin
    if A.RawValue = 0 then Exit(MakeInt64(0));
    // An OPEN ARRAY parameter has no length header -- Delphi passes it as a
    // bare (pointer, high) pair -- so the bytes below the data pointer are
    // unrelated. Reading them anyway returned whatever was there: on a 32-bit
    // target `Length(A)` on an open array reported 50013, and on a 64-bit one
    // it happened to fail the read instead. Verify the header before trusting
    // it, and say why when there is none.
    var HeaderCount: Int64;
    if not TryDynArrayCountFromHeader(A.RawValue, HeaderCount) then
      Exit(InvalidValue('<Length: no dynamic-array header; an open-array ' +
        'parameter carries its bound separately>'));
    if not ReadDynArrayLength(A.RawValue, L) then
      Exit(InvalidValue('<Length: array length read failed>'));
    Result := MakeInt64(Int64(L));
  end;

  // Min/max ordinal for an enum; bounds for an array. Falls back to
  // primitive limits for known integer types.
  function OrdinalLimit(const A: TExprValue; UseMax: Boolean): TExprValue;
  var
    EnumInfo: TRsmEnumInfo;
  begin
    if (FDebugInfo <> nil) and FDebugInfo.LookupEnumInfo(A.TypeHint, EnumInfo) and
       (EnumInfo.Kind = 3) then begin
      if UseMax then
        Exit(MakeInt64(EnumInfo.MaxValue))
      else
        Exit(MakeInt64(EnumInfo.MinValue));
    end;
    if SameText(A.TypeHint, 'Byte') then begin
      if UseMax then Exit(MakeInt64(255)) else Exit(MakeInt64(0));
    end;
    if SameText(A.TypeHint, 'ShortInt') then begin
      if UseMax then Exit(MakeInt64(127)) else Exit(MakeInt64(-128));
    end;
    if SameText(A.TypeHint, 'Word') then begin
      if UseMax then Exit(MakeInt64(65535)) else Exit(MakeInt64(0));
    end;
    if SameText(A.TypeHint, 'SmallInt') then begin
      if UseMax then Exit(MakeInt64(32767)) else Exit(MakeInt64(-32768));
    end;
    if SameText(A.TypeHint, 'Integer') then begin
      if UseMax then Exit(MakeInt64(MaxInt)) else Exit(MakeInt64(-MaxInt - 1));
    end;
    // Dynarrays: Low=0, High=Length-1. Matched by NAME here, but TD32 renders a
    // dynamic array as `^Element`, so a `TArray<Integer>` local reached the
    // "not supported" line below while `Length()` on the very same value
    // worked. Confirm by header instead when the name is a bare pointer -- the
    // same discriminator ApplyIndex uses, so the three intrinsics agree about
    // what is an array.
    var LooksLikeDynArrayByName :=
      A.TypeHint.StartsWith('TArray<', True) or A.TypeHint.StartsWith('array of ', True);
    var HeaderCount: Int64;
    var HasHeader := (A.TypeHint <> '') and (A.TypeHint[1] = '^') and
                     TryDynArrayCountFromHeader(A.RawValue, HeaderCount);
    if LooksLikeDynArrayByName or HasHeader then begin
      if not UseMax then Exit(MakeInt64(0));
      var Len := DynArrayLength(A);
      if not Len.IsValid then Exit(Len);
      Exit(MakeInt64(Int64(Len.RawValue) - 1));
    end;
    // Strings: Low=1 (Delphi 1-based), High=Length.
    if IsStringTypeHint(A.TypeHint) then begin
      if not UseMax then Exit(MakeInt64(1));
      Exit(StringLength(A));
    end;
    var OpName: string;
    if UseMax then OpName := 'High' else OpName := 'Low';
    Result := InvalidValue(Format('<%s for "%s" not supported>',
      [OpName, A.TypeHint]));
  end;

begin
  if Length(Args) <> 1 then
    Exit(InvalidValue(Format('<%s: 1 arg expected, got %d>', [Name, Length(Args)])));
  if SameText(Name, 'Length') then begin
    if IsStringTypeHint(Args[0].TypeHint) then Exit(StringLength(Args[0]));
    if Args[0].TypeHint.StartsWith('TArray<', True) or
       Args[0].TypeHint.StartsWith('array of ', True) then
      Exit(DynArrayLength(Args[0]));
    // TD32 surfaces a dynamic array as `^Element` (no TArray<> name). Its
    // runtime length still lives at [data-ptr - 8].
    if Args[0].TypeHint.StartsWith('^', True) then
      Exit(DynArrayLength(Args[0]));
    Exit(InvalidValue(Format('<Length: type "%s" unsupported>', [Args[0].TypeHint])));
  end;
  if SameText(Name, 'SizeOf') then begin
    // Same rule as an array element's stride, and for the same reason: a
    // record / set / static array is as wide as itself, while a string, class
    // or interface is a pointer-sized handle -- which is also what Delphi's
    // SizeOf reports for them. PrimTypeSize alone answered 8 (x64) or 4 (x86)
    // for a 7-byte packed record.
    Exit(MakeInt64(ElementStride(Args[0].TypeHint)));
  end;
  if SameText(Name, 'Ord')  then Exit(MakeInt64(MaskByType(Args[0].RawValue, Args[0].TypeHint)));
  if SameText(Name, 'Low')  then Exit(OrdinalLimit(Args[0], False));
  if SameText(Name, 'High') then Exit(OrdinalLimit(Args[0], True));
  Result := InvalidValue(Format('<intrinsic "%s" not implemented>', [Name]));
end;

// Allocates a fresh remote string holding L+R and returns a TExprValue
// pointing at it. Used by the `+` operator when both operands look like
// strings (handled in ApplyArith).
function TExprEvaluator.ConcatStrings(const L, R: TExprValue): TExprValue;
const
  MAX_STR_LEN = 65536;

  // Reads a Delphi UnicodeString (or compatible UTF-16 string) given its
  // payload pointer. Length lives at Ptr-4 (Longint, char count).
  function ReadUStrAt(Ptr: UInt64; out S: string): Boolean;
  var
    StrLen: Integer;
    Buf: TBytes;
  begin
    Result := False;
    S := '';
    if Ptr = 0 then Exit(True);
    if not FDebugger.ReadProcessMemoryAt(Ptr - 4, @StrLen, 4) then Exit;
    if StrLen = 0 then Exit(True);
    if (StrLen < 0) or (StrLen > MAX_STR_LEN) then Exit;
    SetLength(Buf, StrLen * 2);
    if not FDebugger.ReadProcessMemoryAt(Ptr, @Buf[0], StrLen * 2) then Exit;
    S := TEncoding.Unicode.GetString(Buf);
    Result := True;
  end;

var
  LeftStr, RightStr: string;
  Ptr: UInt64;
begin
  if not ReadUStrAt(L.RawValue, LeftStr) then
    Exit(InvalidValue('<concat: left string read failed>'));
  if not ReadUStrAt(R.RawValue, RightStr) then
    Exit(InvalidValue('<concat: right string read failed>'));
  if not FDebugger.AllocateRemoteString(LeftStr + RightStr,
       'UnicodeString', Ptr) then
    Exit(InvalidValue('<concat: alloc failed>'));
  Result := Default(TExprValue);
  Result.TypeHint := 'UnicodeString';
  Result.RawValue := Ptr;
  Result.Size     := 8;
  Result.IsValid  := True;
end;

// Arithmetic operators. Promotes to Double if either side is float (except
// integer-only ops `div`, `mod`, `shl`, `shr` which require integers).
// `+` between two strings is handled here too (ConcatStrings).
function TExprEvaluator.ApplyArith(const L, R: TExprValue; const Op: string): TExprValue;
var
  LL, RR, Z: Int64;
  LD, RD, ZD: Double;
begin
  // Set algebra -- Pascal operators on two set operands: `+` union, `-`
  // difference, `*` intersection. Both sides carry a bitmask in RawValue.
  if L.IsSet and R.IsSet then begin
    var SetMask: UInt64;
    if      Op = '+' then SetMask := L.RawValue or R.RawValue
    else if Op = '-' then SetMask := L.RawValue and not R.RawValue
    else if Op = '*' then SetMask := L.RawValue and R.RawValue
    else Exit(InvalidValue(Format('<set operator "%s" not supported>', [Op])));
    Result          := L;   // preserve set type hint + IsSet
    Result.RawValue := SetMask;
    Result.Address  := 0;   // computed rvalue
    Exit;
  end;

  // String concat -- only `+` and only when BOTH sides look like a string.
  if (Op = '+') and IsStringTypeHint(L.TypeHint) and
                    IsStringTypeHint(R.TypeHint) then
    Exit(ConcatStrings(L, R));

  // Float promotion -- any operand floaty (and op is not a strict-int one)
  // -> compute in Double.
  if (IsFloatHint(L.TypeHint) or IsFloatHint(R.TypeHint)) and
     (Op <> 'div') and (Op <> 'mod') and (Op <> 'shl') and (Op <> 'shr') then begin
    LD := AsDouble(L);
    RD := AsDouble(R);
    if      Op = '+' then ZD := LD + RD
    else if Op = '-' then ZD := LD - RD
    else if Op = '*' then ZD := LD * RD
    else if Op = '/' then begin
      if RD = 0 then Exit(InvalidValue('<division by zero>'));
      ZD := LD / RD;
    end else
      Exit(InvalidValue(Format('<float "%s" not supported>', [Op])));
    Exit(MakeDouble(ZD));
  end;

  // Int64 path -- including `/` which always promotes to Double in Pascal.
  if Op = '/' then begin
    LD := AsDouble(L);
    RD := AsDouble(R);
    if RD = 0 then Exit(InvalidValue('<division by zero>'));
    Exit(MakeDouble(LD / RD));
  end;

  LL := AsInt64(L);
  RR := AsInt64(R);
  if      Op = '+'   then Z := LL + RR
  else if Op = '-'   then Z := LL - RR
  else if Op = '*'   then Z := LL * RR
  else if Op = 'div' then begin
    if RR = 0 then Exit(InvalidValue('<div by zero>'));
    Z := LL div RR;
  end
  else if Op = 'mod' then begin
    if RR = 0 then Exit(InvalidValue('<mod by zero>'));
    Z := LL mod RR;
  end
  else if Op = 'shl' then Z := LL shl RR
  else if Op = 'shr' then Z := LL shr RR
  else
    Exit(InvalidValue(Format('<int op "%s" not supported>', [Op])));
  Result := MakeInt64(Z);
end;

// Boolean / bitwise operators. With Boolean operands -> logical; with
// integer operands -> bitwise. Pascal-style.
function TExprEvaluator.ApplyBoolean(const L, R: TExprValue; const Op: string): TExprValue;
var
  LB, RB: Boolean;
  LL, RR, Z: Int64;
begin
  if SameText(L.TypeHint, 'Boolean') and SameText(R.TypeHint, 'Boolean') then begin
    LB := (L.RawValue and $FF) <> 0;
    RB := (R.RawValue and $FF) <> 0;
    if      Op = 'and' then Result := MakeBool(LB and RB)
    else if Op = 'or'  then Result := MakeBool(LB or  RB)
    else if Op = 'xor' then Result := MakeBool(LB xor RB)
    else                    Result := InvalidValue(Format('<bool "%s" unsupported>', [Op]));
    Exit;
  end;
  // Integer / bitwise.
  LL := AsInt64(L);
  RR := AsInt64(R);
  if      Op = 'and' then Z := LL and RR
  else if Op = 'or'  then Z := LL or  RR
  else if Op = 'xor' then Z := LL xor RR
  else                    Exit(InvalidValue(Format('<bitwise "%s" unsupported>', [Op])));
  Result := MakeInt64(Z);
end;

function TExprEvaluator.ApplyCompare(const L, R: TExprValue; const Op: string): TExprValue;

  function CompareInt64Op(LL, RR: Int64): Boolean;
  begin
    if      Op = '='  then Result := LL =  RR
    else if Op = '<>' then Result := LL <> RR
    else if Op = '<'  then Result := LL <  RR
    else if Op = '<=' then Result := LL <= RR
    else if Op = '>'  then Result := LL >  RR
    else if Op = '>=' then Result := LL >= RR
    else                    Result := False;
  end;

  function CompareDoubleOp(LL, RR: Double): Boolean;
  begin
    if      Op = '='  then Result := LL =  RR
    else if Op = '<>' then Result := LL <> RR
    else if Op = '<'  then Result := LL <  RR
    else if Op = '<=' then Result := LL <= RR
    else if Op = '>'  then Result := LL >  RR
    else if Op = '>=' then Result := LL >= RR
    else                    Result := False;
  end;

begin
  if IsFloatHint(L.TypeHint) or IsFloatHint(R.TypeHint) then
    Result := MakeBool(CompareDoubleOp(AsDouble(L), AsDouble(R)))
  else
    Result := MakeBool(CompareInt64Op(AsInt64(L), AsInt64(R)));
end;

function TExprEvaluator.ParseExpr: TExprValue;
begin
  Result := ParseOr;
end;

function TExprEvaluator.ParseOr: TExprValue;
begin
  Result := ParseAnd;
  if not Result.IsValid then Exit;
  while True do begin
    var Op: string := '';
    if      MatchKeyword('or')  then Op := 'or'
    else if MatchKeyword('xor') then Op := 'xor'
    else Break;
    var Rhs := ParseAnd;
    if not Rhs.IsValid then Exit(Rhs);
    Result := ApplyBoolean(Result, Rhs, Op);
    if not Result.IsValid then Exit;
  end;
end;

function TExprEvaluator.ParseAnd: TExprValue;
begin
  Result := ParseCmp;
  if not Result.IsValid then Exit;
  while MatchKeyword('and') do begin
    var Rhs := ParseCmp;
    if not Rhs.IsValid then Exit(Rhs);
    Result := ApplyBoolean(Result, Rhs, 'and');
    if not Result.IsValid then Exit;
  end;
end;

function TExprEvaluator.ParseCmp: TExprValue;

  function TryReadCompareOp(out Op: string): Boolean;
  begin
    Op := '';
    SkipWS;
    if FPos > Length(FExpr) then Exit(False);
    if FPos + 1 <= Length(FExpr) then begin
      var Two := Copy(FExpr, FPos, 2);
      if (Two = '<=') or (Two = '>=') or (Two = '<>') then begin
        Op := Two;
        Inc(FPos, 2);
        Exit(True);
      end;
    end;
    if CharInSet(FExpr[FPos], ['=', '<', '>']) then begin
      Op := FExpr[FPos];
      Inc(FPos);
      Exit(True);
    end;
    Result := False;
  end;

var
  Lhs, Rhs: TExprValue;
  Op: string;
  ClassName: string;
begin
  Lhs := ParseAdd;
  if not Lhs.IsValid then Exit(Lhs);
  // `instance is TFoo` / `instance as TFoo` -- handled at the comparison
  // level: bind tighter than boolean ops, looser than arithmetic.
  if MatchKeyword('is') then begin
    SkipWS;
    ClassName := ScanIdent;
    if ClassName = '' then Exit(InvalidValue('<expected class name after "is">'));
    if FRtti = nil then Exit(InvalidValue('<no RTTI for "is">'));
    Exit(MakeBool(FRtti.IsInstanceOf(Lhs.RawValue, ClassName)));
  end;
  if MatchKeyword('as') then begin
    SkipWS;
    ClassName := ScanIdent;
    if ClassName = '' then Exit(InvalidValue('<expected class name after "as">'));
    if FRtti = nil then Exit(InvalidValue('<no RTTI for "as">'));
    if not FRtti.IsInstanceOf(Lhs.RawValue, ClassName) then
      Exit(InvalidValue(Format('<"as" failed: not a %s>', [ClassName])));
    Result := Lhs;
    Result.TypeHint := ClassName;
    Exit;
  end;
  // `x in S` -- set membership. Lhs is an ordinal (enum element or small
  // integer); Rhs is a set value whose RawValue is the bit mask. Sets larger
  // than 64 elements are not supported by this evaluator (consistent with
  // the set-literal builder in ParseUnary, which also accumulates into a
  // 64-bit mask).
  if MatchKeyword('in') then begin
    Rhs := ParseAdd;
    if not Rhs.IsValid then Exit(Rhs);
    if Lhs.RawValue >= 64 then
      Exit(InvalidValue('<set element ordinal too large for 64-bit mask>'));
    Exit(MakeBool(((Rhs.RawValue shr Lhs.RawValue) and 1) = 1));
  end;
  if not TryReadCompareOp(Op) then Exit(Lhs);
  Rhs := ParseAdd;
  if not Rhs.IsValid then Exit(Rhs);
  Result := ApplyCompare(Lhs, Rhs, Op);
end;

function TExprEvaluator.ParseAdd: TExprValue;
begin
  Result := ParseMul;
  if not Result.IsValid then Exit;
  while True do begin
    SkipWS;
    if FPos > Length(FExpr) then Break;
    var Op: string := '';
    if FExpr[FPos] = '+' then Op := '+'
    else if FExpr[FPos] = '-' then Op := '-'
    else Break;
    Inc(FPos);
    var Rhs := ParseMul;
    if not Rhs.IsValid then Exit(Rhs);
    Result := ApplyArith(Result, Rhs, Op);
    if not Result.IsValid then Exit;
  end;
end;

function TExprEvaluator.ParseMul: TExprValue;
begin
  Result := ParseUnary;
  if not Result.IsValid then Exit;
  while True do begin
    SkipWS;
    if FPos > Length(FExpr) then Break;
    var Op: string := '';
    if FExpr[FPos] = '*' then begin Op := '*'; Inc(FPos); end
    else if FExpr[FPos] = '/' then begin Op := '/'; Inc(FPos); end
    else if MatchKeyword('div') then Op := 'div'
    else if MatchKeyword('mod') then Op := 'mod'
    else if MatchKeyword('shl') then Op := 'shl'
    else if MatchKeyword('shr') then Op := 'shr'
    else Break;
    var Rhs := ParseUnary;
    if not Rhs.IsValid then Exit(Rhs);
    Result := ApplyArith(Result, Rhs, Op);
    if not Result.IsValid then Exit;
  end;
end;

function TExprEvaluator.ParseUnary: TExprValue;
var
  Inner: TExprValue;
  Ptr:   UInt64;
  V:     UInt64;
begin
  SkipWS;
  // @ expr  ->  address-of
  if MatchChar('@') then begin
    Inner := ParsePrimary;
    if not Inner.IsValid then
      Exit(Inner);
    Result          := Default(TExprValue);
    Result.TypeHint := 'Pointer';
    Result.RawValue := Inner.Address;
    Result.IsValid  := Inner.Address <> 0;
    Result.Size     := 8;
    Exit;
  end;
  // `[ ... ]` is overloaded: (a) `[expr]` dereferences a pointer; (b)
  // `[]` / `[a, b, ...]` is a Pascal set literal. Disambiguate by
  // peeking past the opening bracket: empty `[]` and `[ident, ...]`
  // where `ident` is a known enum value go down the set path; anything
  // else is treated as deref.
  if (FPos <= Length(FExpr)) and (FExpr[FPos] = '[') and
     LooksLikeSetLiteral then
    Exit(ParseSetLiteral);
  // [ expr ]  ->  read 8 bytes at address given by expr
  if MatchChar('[') then begin
    Inner := ParseExpr;
    if not MatchChar(']') then
      Exit(InvalidValue('<missing ] in dereference>'));
    if not Inner.IsValid then
      Exit(Inner);
    Ptr := Inner.RawValue;
    if not ReadU64(Ptr, V) then
      Exit(InvalidValue(Format('<read failed @ 0x%x>', [Ptr])));
    Result          := Default(TExprValue);
    Result.TypeHint := 'UInt64';
    Result.RawValue := V;
    Result.Address  := Ptr;
    Result.IsValid  := True;
    Result.Size     := 8;
    Exit;
  end;
  // -expr  ->  unary minus
  if MatchChar('-') then begin
    Inner := ParseUnary;
    if not Inner.IsValid then Exit(Inner);
    if IsFloatHint(Inner.TypeHint) then
      Exit(MakeDouble(-AsDouble(Inner)));
    Exit(MakeInt64(-AsInt64(Inner)));
  end;
  // not expr  ->  logical / bitwise complement
  if MatchKeyword('not') then begin
    Inner := ParseUnary;
    if not Inner.IsValid then Exit(Inner);
    if SameText(Inner.TypeHint, 'Boolean') then
      Exit(MakeBool((Inner.RawValue and $FF) = 0));
    Exit(MakeInt64(not AsInt64(Inner)));
  end;
  Result := ApplySuffixes(ParsePrimary);
end;

function TExprEvaluator.ParseStringLiteral(out S: string): Boolean;
var
  Buf: TStringBuilder;
begin
  Result := False;
  S := '';
  if (FPos > Length(FExpr)) or (FExpr[FPos] <> '''') then Exit;
  Inc(FPos);
  Buf := TStringBuilder.Create;
  try
    while FPos <= Length(FExpr) do begin
      if FExpr[FPos] = '''' then begin
        // Doubled '' means literal apostrophe.
        if (FPos + 1 <= Length(FExpr)) and (FExpr[FPos + 1] = '''') then begin
          Buf.Append('''');
          Inc(FPos, 2);
        end else begin
          Inc(FPos);
          S := Buf.ToString;
          Exit(True);
        end;
      end else begin
        Buf.Append(FExpr[FPos]);
        Inc(FPos);
      end;
    end;
  finally
    Buf.Free;
  end;
end;

function TExprEvaluator.ParsePrimary: TExprValue;
var
  IntV: Int64;
begin
  SkipWS;
  if FPos > Length(FExpr) then
    Exit(InvalidValue('<unexpected end of expression>'));

  // Parenthesised sub-expression
  if MatchChar('(') then begin
    Result := ParseExpr;
    if not MatchChar(')') then
      Result := InvalidValue('<missing )>');
    Exit;
  end;

  // Pascal string literal: 'text' with doubled '' for literal apostrophes.
  // Allocates the value in the debuggee so it can be marshalled as an arg.
  if FExpr[FPos] = '''' then begin
    var S: string;
    if not ParseStringLiteral(S) then
      Exit(InvalidValue('<unterminated string literal>'));
    Result := Default(TExprValue);
    Result.TypeHint := 'UnicodeString';
    Result.Size     := 8;
    var Ptr: UInt64;
    if FDebugger.AllocateRemoteString(S, 'UnicodeString', Ptr) then begin
      Result.RawValue := Ptr;
      Result.IsValid  := True;
    end else
      Exit(InvalidValue('<failed to allocate string literal in debuggee>'));
    Exit;
  end;

  // Float literal (decimal point) -- must be checked BEFORE integer parsing
  // so that "1.5" doesn't get consumed as Int=1 then ".5".
  if CharInSet(FExpr[FPos], ['0'..'9']) then begin
    // Look ahead for a decimal point inside the digit run.
    var SaveStart := FPos;
    while (FPos <= Length(FExpr)) and CharInSet(FExpr[FPos], ['0'..'9']) do
      Inc(FPos);
    if (FPos <= Length(FExpr)) and (FExpr[FPos] = '.') and
       (FPos + 1 <= Length(FExpr)) and CharInSet(FExpr[FPos + 1], ['0'..'9']) then begin
      // It's a float.
      Inc(FPos);
      while (FPos <= Length(FExpr)) and CharInSet(FExpr[FPos], ['0'..'9']) do
        Inc(FPos);
      var FltStr := Copy(FExpr, SaveStart, FPos - SaveStart);
      var FS: TFormatSettings;
      FS := TFormatSettings.Create;
      FS.DecimalSeparator := '.';
      var Dbl: Double := StrToFloat(FltStr, FS);
      Result          := Default(TExprValue);
      Result.TypeHint := 'Double';
      Result.RawValue := PUInt64(@Dbl)^;
      Result.Size     := 8;
      Result.IsValid  := True;
      Exit;
    end;
    // Not a float -- rewind and let the integer parser take it.
    FPos := SaveStart;
  end;

  // Integer literal (decimal, $HEX, 0xHEX)
  if CharInSet(FExpr[FPos], ['0'..'9', '$']) then begin
    if ScanIntLiteral(IntV) then begin
      Result              := Default(TExprValue);
      Result.IsIntLiteral := True;
      Result.TypeHint     := 'Int64';
      Result.RawValue := UInt64(IntV);
      Result.Size     := 8;
      Result.IsValid  := True;
      Exit;
    end;
  end;

  // Pascal keyword literals -- must be matched BEFORE generic identifier
  // resolution so `True` / `False` / `nil` don't shadow the keywords with
  // some variable that happens to share the name.
  if MatchKeyword('True')  then Exit(MakeBool(True));
  if MatchKeyword('False') then Exit(MakeBool(False));
  if MatchKeyword('nil')   then Exit(MakePointer(0));

  // `inherited Method[(args)]` -- static (non-virtual) call to the version of
  // Method declared in the PARENT of the current method's class. The current
  // class is Self's declared type; its parent comes from the class hierarchy.
  if MatchKeyword('inherited') then begin
    SkipWS;
    var MethodName := ScanIdent;
    if MethodName = '' then
      Exit(InvalidValue('<expected method name after inherited>'));
    var SelfLV: TLocalValue;
    if not FDebugger.EvaluateLocalName('Self', SelfLV) then
      Exit(InvalidValue('<inherited: no Self in scope>'));
    var SelfVal := LocalToExpr(SelfLV);
    var ParentClass := '';
    if (FDebugInfo = nil) or
       not FDebugInfo.GetParentClassName(SelfVal.TypeHint, ParentClass) then
      Exit(InvalidValue(Format('<inherited: parent of "%s" unknown>', [SelfVal.TypeHint])));
    var Args: TArray<TExprValue>;
    SetLength(Args, 0);
    SkipWS;
    if (FPos <= Length(FExpr)) and (FExpr[FPos] = '(') then begin
      Inc(FPos);
      SkipWS;
      if (FPos <= Length(FExpr)) and (FExpr[FPos] <> ')') then
        repeat
          var A := ParseExpr;
          if not A.IsValid then Exit(A);
          Args := Args + [A];
          SkipWS;
        until not MatchChar(',');
      if not MatchChar(')') then
        Exit(InvalidValue('<missing ) in inherited call>'));
    end;
    Exit(ApplyMethodCall(SelfVal, MethodName, Args, ParentClass));
  end;

  // Identifier. Three paths in order:
  //   * `Ident(arg, ...)` -- known type -> cast; built-in intrinsic -> eval.
  //     Free-proc / function calls are NOT yet wired (return-type
  //     dispatch is the same heuristic-prone problem the $2E method
  //     case faces; see KNOWN_UNKNOWNS.md).
  //   * Local / global / register / qualified-name match -> return value.
  //   * Bare enum value (`wmPaused`) -> enum ordinal.
  if CharInSet(FExpr[FPos], ['A'..'Z', 'a'..'z', '_']) then begin
    var Name := ScanIdent;
    SkipWS;
    if (FPos <= Length(FExpr)) and (FExpr[FPos] = '(') then begin
      Inc(FPos);
      var Args: TArray<TExprValue>;
      SetLength(Args, 0);
      SkipWS;
      if (FPos <= Length(FExpr)) and (FExpr[FPos] <> ')') then begin
        repeat
          var A := ParseExpr;
          if not A.IsValid then Exit(A);
          Args := Args + [A];
          SkipWS;
        until not MatchChar(',');
      end;
      if not MatchChar(')') then
        Exit(InvalidValue('<missing ) in call>'));
      if IsBuiltinIntrinsic(Name) then
        Exit(ApplyIntrinsic(Name, Args));
      if (Length(Args) = 1) and IsKnownTypeName(Name) then
        Exit(ApplyCast(Name, Args[0]));
      // Free-procedure / function call. ApplyMethodCall detects the
      // "no receiver" case (Base.IsValid=False) and skips Self in the
      // call frame; return-type ABI dispatch comes from the proc's
      // `Result` local in the RSM $28 record, same as for methods.
      Exit(ApplyMethodCall(Default(TExprValue), Name, Args));
    end;
    // A bare CLASS name immediately followed by `.` is a class-reference member
    // access (`TFoo.ClassMethod`), not a data symbol. Return it as a type ref so
    // ApplySuffixes invokes the class method. Without this short-circuit,
    // ResolveIdent's EvaluateGlobalName code-resident fallback accepts the class
    // VMT symbol as a "global" and reads its bytes as data (garbage).
    if (FPos <= Length(FExpr)) and (FExpr[FPos] = '.') and (FDebugInfo <> nil) then begin
      var ClassMembersPeek: TArray<TClassMember>;
      if FDebugInfo.GetClassMembers(Name, ClassMembersPeek) then begin
        Result := Default(TExprValue);
        Result.TypeHint  := Name;
        Result.Size      := 8;
        Result.IsValid   := True;
        Result.IsTypeRef := True;
        Exit;
      end;
    end;
    var Resolved := ResolveIdent(Name);
    if Resolved.IsValid then Exit(Resolved);
    var EnumOrd: Integer;
    var EnumTypeName: string;
    if TryResolveEnumLiteral(Name, EnumOrd, EnumTypeName) then begin
      Result := Default(TExprValue);
      Result.TypeHint := EnumTypeName;
      Result.RawValue := UInt64(EnumOrd);
      Result.Size     := 1;
      Result.IsValid  := True;
      Exit;
    end;
    // Type-name as a value-less expression. Used by `SizeOf(Integer)`,
    // `Low(TWorkMode)`, etc. -- intrinsics that take a type rather than a
    // value. The TExprValue has only TypeHint + Size set; reading
    // RawValue is meaningless and intrinsic handlers know not to.
    if IsKnownTypeName(Name) then begin
      Result := Default(TExprValue);
      Result.TypeHint  := Name;
      Result.Size      := PrimTypeSize(Name);
      if Result.Size = 0 then Result.Size := 8;
      Result.IsValid   := True;
      Result.IsTypeRef := True;
      Exit;
    end;
    Exit(Resolved);  // propagate original "<X: not found>" message
  end;

  Result := InvalidValue(Format('<unexpected: "%s">', [FExpr[FPos]]));
end;

{ Public }

function TExprEvaluator.Evaluate(const Expr: string; out Val: TExprValue): Boolean;
begin
  FExpr := Trim(Expr);
  FPos  := 1;
  Val   := ParseExpr;
  SkipWS;
  // If input was not fully consumed, report a parse error.
  if (FPos <= Length(FExpr)) and Val.IsValid then
    Val := InvalidValue(Format('<unexpected token at %d: "%s">',
            [FPos, Copy(FExpr, FPos, 8)]));
  Result := Val.IsValid;
end;

end.
