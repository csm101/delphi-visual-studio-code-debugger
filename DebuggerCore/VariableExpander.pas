unit VariableExpander;

// Shared nested-variable expansion engine. Owns the opaque-handle table and all
// the logic that turns a class / record / dynamic-array / property / Variant-array
// value into child rows (TSessionVariable). Both frontends drive one instance:
// TDebugSession (MCP) and TDapServer (DAP) delegate their expansion here so there
// is a single engine, not two divergent copies.
//
// Ownership: the expander OWNS only its handle table. Debugger / DebugInfo / TD32 /
// Rtti / Readers are references the owner sets as they become available (Rtti is
// created lazily on the first stop). The owner calls Reset on every stop to rebuild
// the per-stop handle table.

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Variants,
  System.Math, Winapi.Windows,
  DebugSessionTypes, DebugTarget, DebugInfoTypes, DebugInfoSet,
  TD32FileReader, DelphiRtti, DelphiValueReaders, ExprEval, SafeCallPolicy;

type
  // A pending nested-expansion node, addressed by an opaque TVarHandle. Minted
  // when a variable/field is found expandable; the table is rebuilt each stop.
  //   exRsmMembers - expand ClassName's member table at BaseAddr (class object
  //                  pointer OR inline record memory).
  //   exClassRtti  - expand a class instance at BaseAddr via runtime RTTI when no
  //                  RSM/TD32 member table exists.
  //   exDynArray   - expand a Delphi dynamic array; BaseAddr is the data pointer,
  //                  ElemTypeName/ElemSize/ElemCount describe the elements.
  //   exPropGroup  - the 'properties' category of a class: enumerate TypeName's
  //                  non-event properties at BaseAddr (field-backed read inline,
  //                  getter-backed deferred, indexed as a leaf).
  //   exEventGroup - the 'event handlers' category: method-pointer properties.
  //   exPropertyGetter - a deferred getter-backed property; on expand, run the
  //                  getter expression (EvaluateName) and split the result.
  //   exVariantArray - a Variant array; VarArrPtr/VarBaseType/VarDimCount/
  //                  VarBounds describe the TVarArray in user (declared) order.
  //   exRecordRtti - a record expanded purely through runtime RTTI (TypeInfoAddr).
  //                  Used to rescue a generic backing field TD32 left untyped.
  //   exDynArrayRtti - a dynamic array expanded through runtime RTTI: BaseAddr is
  //                  the array-pointer slot; TypeInfoAddr/ElemTypeInfoAddr/
  //                  ElemTypeKind/ElemSize describe the elements. Same rescue role.
  TSessionExpKind = (exRsmMembers, exClassRtti, exDynArray,
                     exPropGroup, exEventGroup, exPropertyGetter, exVariantArray,
                     exRecordRtti, exDynArrayRtti);
  TSessionExpansion = record
    Kind:         TSessionExpKind;
    BaseAddr:     UInt64;
    TypeName:     string;
    EvaluateName: string;
    IsRecord:     Boolean;   // display hint only (vkRecord vs vkClass)
    NoGroup:      Boolean;   // exRsmMembers: list fields flat, skip the group split
    ElemTypeName: string;    // exDynArray: element type
    ElemSize:     Cardinal;  // exDynArray / exDynArrayRtti: element stride in bytes
    ElemCount:    Integer;   // exDynArray: length
    TypeInfoAddr:     UInt64;  // exRecordRtti / exDynArrayRtti: PTypeInfo in debuggee
    ElemTypeInfoAddr: UInt64;  // exDynArrayRtti: element PTypeInfo
    ElemTypeKind:     Byte;    // exDynArrayRtti: element TTypeKind
    VarArrPtr:    UInt64;    // exVariantArray: TVarArray header pointer
    VarBaseType:  Word;      // exVariantArray: element base VType
    VarDimCount:  Integer;   // exVariantArray: dimension count (1..16)
    VarBounds:    TArray<Integer>;  // exVariantArray: [LB0,Count0,LB1,Count1,...] user order
  end;

  TVariableExpander = class
  public
    // References set by the owner as they become available. Not owned here.
    Debugger:  IDebugTarget;
    DebugInfo: TDebugInfoSet;
    TD32:      TTD32FileReader;
    Rtti:      TDelphiRtti;
    Readers:   TDelphiValueReader;
    // Which getters may be called WITHOUT an explicit request. nil = none may:
    // every getter-backed property defers, which is the historical behaviour.
    Policy:    TSafeCallPolicy;
  private
    FByHandle:   TDictionary<TVarHandle, TSessionExpansion>;
    FNextHandle: TVarHandle;

    function  MintHandle(const Exp: TSessionExpansion): TVarHandle;
    function  HasMembers(const TypeName: string): Boolean;
    // Recovers the compiler-generated closure object behind an anonymous-method
    // value. InterfaceRef is the interface reference stored in the local; it points
    // INTO the object (at its interface field), so the object header sits a few
    // pointer-slots below. Scans, VMT-validates each candidate, and accepts only a
    // `...$ActRec` activation record that carries debug-info members. False for a
    // plain interface / non-closure. Debug-info driven -- RTTI is optional in Delphi
    // and $ActRec has no runtime field table.
    function  TryRecoverClosureObject(InterfaceRef: UInt64;
                out ObjBase: UInt64; out ClassName: string): Boolean;
    // TypeKind is passed when the CALLER already knows it -- notably that a
    // flattened `^T` member is really a dynamic array. Without it the reader has
    // only the ambiguous spelling and must guess from memory shape.
    function  SyntheticLocal(const Name, TypeName: string; Addr: UInt64;
                TypeKind: Byte = 0): TLocalValue;
  public
    // Renders an evaluated expression. PUBLIC and shared: TDebugSession had its
    // own byte-identical copy, and the two drifted -- the copy here learned to
    // carry ValueKind while the other did not, so EXPANDING `MRec.Tags` showed
    // `[4, 5, 6]` and EVALUATING it showed a bare address. One conversion, so
    // they cannot disagree again.
    function  FormatExprValue(const E: TExprValue): string;
  private
    // Element type for any spelling of a dynamic array (`^E`, `TArray<E>`,
    // `array of E`), so all of them reach the array expansion.
    function  TryDynArrayElementType(const TypeName: string;
                out ElemType: string): Boolean;
    function  TryClassifyChild(const TypeName, EvalName: string;
                FieldAddr, PtrVal: UInt64; out Exp: TSessionExpansion): Boolean;
    function  FormatMemberValue(const TypeName: string; TypeKind: Byte;
                FieldAddr: UInt64): string;
    function  MemberFieldToSession(const Exp: TSessionExpansion;
                const M: TClassMember;
                const ParentRttiFields: TArray<TRttiFieldInfo>): TSessionVariable;
    // Build an expansion for an RTTI field (class/record/dyn-array) from its own
    // TypeInfo. Mirrors the DAP FieldDrillDownRef same-offset rescue: used to
    // expand a generic backing field TD32 could not type.
    function  TryMakeRttiFieldExpansion(const RF: TRttiFieldInfo;
                out Exp: TSessionExpansion): Boolean;
    // Expand an exRecordRtti / exDynArrayRtti node purely through runtime RTTI.
    function  ExpandRttiTyped(const Exp: TSessionExpansion): TArray<TSessionVariable>;
    function  BuildGroupNodes(const Exp: TSessionExpansion;
                const Members: TArray<TClassMember>): TArray<TSessionVariable>;
    function  IsEventHandlerProp(const P: TClassMember): Boolean;
    function  ClassHasProperties(const Members: TArray<TClassMember>): Boolean;
    function  ClassHasPropertyKind(const Members: TArray<TClassMember>;
                WantEvents: Boolean): Boolean;
    function  PropertyBackingFieldOffset(const Members: TArray<TClassMember>;
                const Prop: TClassMember; out Offset: Integer): Boolean;
    // The spellings a safelist entry for this property could use, most specific
    // first: the declaring class + the getter METHOD where TD32 names it (the
    // verdict is about the code that runs), then class + property name (all an
    // RSM-sourced member can offer). SafelistKeyFor is the single spelling the
    // row carries for the frontend's add/deny actions.
    function  SafelistKeysFor(const OwnerClass: string;
                const P: TClassMember): TArray<string>;
    function  SafelistKeyFor(const OwnerClass: string;
                const P: TClassMember): string;
    // Runs the getter NOW and fills the row with the result -- the exact call
    // clicking "expand to evaluate" would have made, value formatting and
    // drill-down handle included. On failure the row carries the error text,
    // which for a mayRaise member is the intended outcome, not a defect.
    procedure EvaluateGetterInto(var Child: TSessionVariable;
                const PropExpr, DeclaredTypeName: string);
    function  ExpandViaMembers(const Exp: TSessionExpansion): TArray<TSessionVariable>;
    function  ExpandDynArray(const Exp: TSessionExpansion): TArray<TSessionVariable>;
    function  ExpandProperties(const Exp: TSessionExpansion): TArray<TSessionVariable>;
    function  ExpandPropertyGetter(const Exp: TSessionExpansion): TArray<TSessionVariable>;
    function  FormatVariantElement(ElemAddr: UInt64; BaseType: Word;
                ElemSize: Cardinal): string;
    function  TryMakeVariantArray(VariantAddr: UInt64; const EvalName: string;
                out Exp: TSessionExpansion): Boolean;
    function  ExpandVariantArray(const Exp: TSessionExpansion): TArray<TSessionVariable>;
    function  TryMakeDynArray(SlotPtr: UInt64; const ElemTypeName, EvalName: string;
                out Exp: TSessionExpansion): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Rebuild the per-stop handle table. Call on every stop.
    procedure Reset;
    // Read the child rows of a previously-minted expandable value.
    function  GetChildren(Handle: TVarHandle): TArray<TSessionVariable>;
    // The expansion behind a handle, for a caller that needs its SHAPE rather
    // than its children: a dynamic array's element size and count were already
    // measured (and sanity-checked) when the expansion was minted, so asking how
    // many BYTES the value occupies is a lookup rather than a second decode.
    function  TryGetExpansion(Handle: TVarHandle; out Exp: TSessionExpansion): Boolean;

    // WHERE a value's bytes are, and HOW MANY of them there are. They live here
    // rather than in TDebugSession because the answer needs the debuggee, the
    // runtime RTTI, the type tables AND the expansion table -- and because the
    // rows that most need them are the ones this class builds: a field of an
    // expanded object, an element of an array. TDebugSession delegates.
    //
    // Delphi's reference types -- string, dynamic array, class instance,
    // interface -- store one pointer and keep the value elsewhere, so the slot's
    // bytes are the pointer and nothing anyone wants to look at. PayloadAddress
    // returns where the value really is for those, and 0 for a value type, whose
    // own storage already IS its bytes. A plain typed pointer is deliberately
    // NOT among them: there the pointer is the value, and `P^` is how Pascal
    // asks for the pointee. ForceReference says "this slot holds a pointer to
    // the value whatever its type spells" -- true of a var/out parameter.
    function  PayloadAddress(TypeKind: Byte; const TypeHint: string;
                RawValue: UInt64; ForceReference: Boolean = False): UInt64;
    // Byte width of a type whose size the LANGUAGE fixes (0 = not one of them).
    // Consulted before the type table, which resolves ids per unit: a
    // mis-resolved id gives a size that is wrong without looking wrong.
    function  NamedTypeByteSize(const TypeName: string; PtrSize: Integer): Integer;
    // How many bytes the value occupies, measured where it can be measured and
    // 0 where it cannot -- a memory view draws this as the value's extent, so an
    // unjustified number here would claim a neighbour's storage.
    function  ValueByteSize(TypeKind: Byte; const TypeHint: string;
                Address, DataAddress: UInt64; Handle: TVarHandle): UInt64;
    // Fills DataAddress and ValueSize on a row that already knows its Address,
    // its TypeName and (if it has one) its expansion handle. RawValue is the
    // pointer-sized word AT that address, which is what a reference type stores.
    // One call, so every producer of a row answers "where are its bytes" the
    // same way.
    procedure DescribeStorage(var V: TSessionVariable; TypeKind: Byte;
                RawValue: UInt64; ForceReference: Boolean = False);
    // Attach an expansion handle to an already-formatted local, if it is a
    // class / Variant-array / dyn-array / record value. The caller fills V's
    // Name/Value/TypeName/EvaluateName first.
    procedure ClassifyLocal(const LV: TLocalValue; var V: TSessionVariable);
    // Mint an expansion for a known class instance at BaseAddr (member table when
    // available, else runtime RTTI). Used by a frontend to make a synthetic object
    // node (e.g. $exception) expandable. Returns 0 for a nil/unusable pointer.
    function  MakeClassExpansion(BaseAddr: UInt64; const ClassName, EvalName: string): TVarHandle;
    // Resolve a writable backing field of an exRsmMembers expansion by name,
    // returning its target address + declared type (for setVariable). Only member
    // expansions are writable; anything else returns False.
    function  TryGetWritableField(Handle: TVarHandle; const FieldName: string;
                out FieldAddr: UInt64; out FieldType: string): Boolean;
    // Mint a Variant-array expansion for a Variant value at VariantAddr, if its
    // VType has the varArray bit set. Returns 0 otherwise. Used by a frontend to
    // make an evaluated Variant-array result expandable.
    function  MakeVariantArrayExpansion(VariantAddr: UInt64;
                const EvalName: string): TVarHandle;
    // Resolve a type's member table, preferring the main-module TD32 over the
    // aggregate provider set. Shared with a frontend that needs member info
    // outside an expansion (e.g. the DAP evaluate handler).
    function  GetDisplayMembers(const TypeName: string;
                out Members: TArray<TClassMember>; PreferInstanceSize: Integer = 0): Boolean;
  end;

implementation

constructor TVariableExpander.Create;
begin
  inherited Create;
  FByHandle   := TDictionary<TVarHandle, TSessionExpansion>.Create;
  FNextHandle := 1;
end;

destructor TVariableExpander.Destroy;
begin
  FByHandle.Free;
  inherited Destroy;
end;

procedure TVariableExpander.Reset;
begin
  FByHandle.Clear;
  FNextHandle := 1;
end;

function TVariableExpander.MintHandle(const Exp: TSessionExpansion): TVarHandle;
begin
  Result := FNextHandle;
  FByHandle.Add(Result, Exp);
  Inc(FNextHandle);
end;

// Resolves a type's members preferring the main-module TD32 over the aggregate
// set: the RSM provider can win the aggregate query with a partial member list
// for some record types, so TD32 (which carries the full field list) is tried
// first, then the aggregate as fallback.
function TVariableExpander.GetDisplayMembers(const TypeName: string;
  out Members: TArray<TClassMember>; PreferInstanceSize: Integer): Boolean;
begin
  Result := False;
  Members := nil;
  if TypeName = '' then
    Exit;
  // PreferInstanceSize disambiguates two classes sharing a bare name by the
  // object's real VMT size (Data.DB.TFields vs System.Classes.TFieldsCache.
  // TFields), so expansion lists the right class's fields.
  if (TD32 <> nil) and TD32.GetClassMembers(TypeName, Members, PreferInstanceSize) and (Length(Members) > 0) then
    Exit(True);
  if (DebugInfo <> nil) and DebugInfo.GetClassMembers(TypeName, Members, PreferInstanceSize) and (Length(Members) > 0) then
    Exit(True);
end;

function TVariableExpander.HasMembers(const TypeName: string): Boolean;
var
  Members: TArray<TClassMember>;
begin
  Result := GetDisplayMembers(TypeName, Members);
end;

function TVariableExpander.TryRecoverClosureObject(InterfaceRef: UInt64;
  out ObjBase: UInt64; out ClassName: string): Boolean;

  // Accepts a candidate only if it really is a closure activation record.
  function IsActivationRecord(Cand: UInt64; out Cn: string): Boolean;
  begin
    Cn := '';
    if (Cand < 65536) or not Rtti.IsClassInstance(Cand) then
      Exit(False);
    Cn := Rtti.GetInstanceClassName(Cand);
    Result := (Cn <> '') and Cn.Contains('$ActRec') and HasMembers(Cn);
  end;

begin
  Result := False;
  ObjBase := 0;
  ClassName := '';
  if (Rtti = nil) or (Debugger = nil) or (InterfaceRef < 65536) then Exit;

  // A closure variable holds an INTERFACE REFERENCE into its activation record,
  // so the record's address is derivable exactly -- decode the IMT adjustor
  // thunk the reference itself points at. Two cases, both exact:
  //
  //   * the interface field sits at a non-zero offset inside the record, which
  //     is the normal shape (the record descends from TInterfacedObject), and
  //     the thunk carries -IOffset;
  //   * the reference already IS the object, when the interface sits at offset
  //     zero and no adjustor thunk is emitted.
  //
  // What this replaces was a backward scan of eight pointer slots taking the
  // first `$ActRec` it met. In a closure-heavy target activation records are
  // dense on the stack, so it could latch an UNRELATED neighbouring record and
  // expand a FOREIGN closure's captured variables -- values that look entirely
  // real and belong to something else. No amount of tightening makes a scan
  // exact; asking the reference where its object is does not need to be
  // tightened.
  var Cn: string;
  var ViaThunk := Rtti.ObjectFromInterfaceThunk(InterfaceRef);
  if (ViaThunk <> 0) and IsActivationRecord(ViaThunk, Cn) then begin
    ObjBase := ViaThunk;
    ClassName := Cn;
    Exit(True);
  end;
  if IsActivationRecord(InterfaceRef, Cn) then begin
    ObjBase := InterfaceRef;
    ClassName := Cn;
    Exit(True);
  end;
end;

function TVariableExpander.SyntheticLocal(const Name, TypeName: string;
  Addr: UInt64; TypeKind: Byte): TLocalValue;
begin
  Result            := Default(TLocalValue);
  Result.Name       := Name;
  Result.TypeHint   := TypeName;
  Result.TypeKind   := TypeKind;
  Result.Address    := Addr;
  Result.Kind       := lkLocal;
  if Debugger = nil then
    Exit;
  // Read the slot at its real width. Reading a fixed 8 here is what made a
  // 32-bit target render a string field as `@0x2A03172D4C (string read
  // failed)`: the 4-byte handle came back with the neighbouring field spliced
  // into its high half, giving an address far outside the target's range.
  // Read into a local first: inside the closure `Result` is the closure's own
  // Boolean, so naming the record's field there would only invite confusion.
  var Raw: UInt64 := 0;
  var Reader := Debugger;
  Result.ValueValid := ReadValueSlotRaw(
    function(A: UInt64; Dest: Pointer; Size: Integer): Boolean
    begin
      Result := Reader.ReadProcessMemoryAt(A, Dest, Size);
    end,
    Addr, TypeName, Reader.TargetLayout.PointerSize, Raw);
  Result.RawValue := Raw;
end;

function TVariableExpander.FormatExprValue(const E: TExprValue): string;
var
  LV: TLocalValue;
begin
  LV            := Default(TLocalValue);
  LV.TypeHint   := E.TypeHint;
  // ONLY the dynamic-array fact is carried, deliberately not the kind wholesale.
  // It is what separates a flattened dynamic array from a genuine typed
  // pointer, both of which read `^T`; without it `MRec.Tags` evaluated to a bare
  // address while EXPANDING the same field showed `[4, 5, 6]`.
  //
  // Copying the kind wholesale is wrong here and was measured wrong: a `var`
  // parameter's kind describes its DECLARED type (`^Integer`) while RawValue
  // already holds the value the caller passed, so the formatter rendered the
  // correct number in pointer style -- `0x5E` instead of `94`.
  if E.ValueKind = TK_DYNARRAY then
    LV.TypeKind := TK_DYNARRAY;
  LV.Address    := E.Address;
  LV.RawValue   := E.RawValue;
  LV.ValueValid := E.IsValid;
  LV.Kind       := lkLocal;
  Result := Readers.FormatLocalValue(LV);
end;

// Decides whether a member/field (declared TypeName, memory at FieldAddr, and the
// 8 bytes there read as PtrVal) is itself expandable, and if so returns the child
// expansion. A class/interface field holds a POINTER to the object -> deref +
// validate; a record field is expanded IN PLACE at FieldAddr.
// Recognises the spellings a dynamic array arrives under and yields its element
// type: `^Element` (TD32's fallback when it has no name), `TArray<Element>` and
// `array of Element` (the real names, which runtime RTTI and richer providers
// do supply). Any of them means the value is a data pointer with a length
// header, so they must all reach the same expansion.
function TVariableExpander.TryDynArrayElementType(const TypeName: string;
  out ElemType: string): Boolean;
begin
  ElemType := '';
  if TypeName = '' then
    Exit(False);
  if TypeName[1] = '^' then begin
    ElemType := Copy(TypeName, 2, MaxInt);
    Exit(ElemType <> '');
  end;
  if TypeName.StartsWith('TArray<', True) and TypeName.EndsWith('>') then begin
    ElemType := TypeName.Substring(7, TypeName.Length - 8);
    if ElemType.StartsWith('System.', True) then
      ElemType := ElemType.Substring(7);
    Exit(ElemType <> '');
  end;
  if TypeName.StartsWith('array of ', True) then begin
    ElemType := Trim(TypeName.Substring(9));
    Exit(ElemType <> '');
  end;
  Result := False;
end;

function TVariableExpander.TryClassifyChild(const TypeName, EvalName: string;
  FieldAddr, PtrVal: UInt64; out Exp: TSessionExpansion): Boolean;
begin
  Result := False;
  if TypeName = '' then
    Exit;

  // A dynamic array, in any of the spellings debug info uses for one. Keying
  // this on the `^` prefix alone was a trap: TD32 writes `^Element` only when
  // it has no better name, and once runtime RTTI started supplying the real
  // instantiated name -- `TArray<System.Integer>` -- the field stopped being
  // recognised as an array and fell through to the class path below, which
  // expanded it into ITSELF. The DAP request then recursed until it failed.
  var ElemType: string;
  if TryDynArrayElementType(TypeName, ElemType) then begin
    if TryMakeDynArray(PtrVal, ElemType, EvalName, Exp) then
      Result := True;
    Exit;
  end;

  var K := 0;
  if DebugInfo <> nil then
    K := DebugInfo.LookupTypeKind(TypeName);

  var LooksLikeObject := (PtrVal >= 65536) and (Rtti <> nil) and Rtti.IsClassInstance(PtrVal);
  if (K = TK_CLASS) or (K = TK_INTERFACE) or LooksLikeObject then begin
    if not LooksLikeObject then
      Exit;   // nil / unresolvable class reference -> leaf
    var ClsName := Rtti.GetInstanceClassName(PtrVal);
    if ClsName = '' then
      ClsName := TypeName;
    if HasMembers(ClsName) then begin
      Exp := Default(TSessionExpansion);
      Exp.Kind := exRsmMembers; Exp.BaseAddr := PtrVal; Exp.TypeName := ClsName;
      Exp.EvaluateName := EvalName; Exp.IsRecord := False;
      Exit(True);
    end;
    if Length(Rtti.ExpandClass(PtrVal)) > 0 then begin
      Exp := Default(TSessionExpansion);
      Exp.Kind := exClassRtti; Exp.BaseAddr := PtrVal; Exp.TypeName := TypeName;
      Exp.EvaluateName := EvalName; Exp.IsRecord := False;
      Exit(True);
    end;
    Exit;
  end;

  // Record / managed record / untyped-but-has-members: expand in place.
  if (K = TK_RECORD) or (K = TK_MRECORD) or (K = 0) then
    if HasMembers(TypeName) then begin
      Exp := Default(TSessionExpansion);
      Exp.Kind := exRsmMembers; Exp.BaseAddr := FieldAddr; Exp.TypeName := TypeName;
      Exp.EvaluateName := EvalName; Exp.IsRecord := True;
      Exit(True);
    end;
end;

procedure TVariableExpander.ClassifyLocal(const LV: TLocalValue;
  var V: TSessionVariable);
begin
  var EffVal := LV.RawValue;
  if LV.Kind = lkVarParam then
    EffVal := LV.DerefValue;

  // Class instance: mint an expansion on the object pointer.
  if (Rtti <> nil) and LV.ValueValid and (EffVal >= 65536) and Rtti.IsClassInstance(EffVal) then begin
    var ClsName := Rtti.GetInstanceClassName(EffVal);
    if ClsName = '' then
      ClsName := LV.TypeHint;
    var Exp := Default(TSessionExpansion);
    Exp.EvaluateName := LV.Name;
    Exp.BaseAddr     := EffVal;
    if HasMembers(ClsName) then begin
      Exp.Kind := exRsmMembers; Exp.TypeName := ClsName;
      V.Kind := vkClass; V.Expandable := True; V.Handle := MintHandle(Exp);
    end
    else if Length(Rtti.ExpandClass(EffVal)) > 0 then begin
      Exp.Kind := exClassRtti; Exp.TypeName := ClsName;
      V.Kind := vkClass; V.Expandable := True; V.Handle := MintHandle(Exp);
    end;
    Exit;
  end;

  // Anonymous-method closure: EffVal is an interface reference to a compiler-
  // generated `...$ActRec` object holding the captured variables. It is NOT itself a
  // class instance (the check above already failed), so recover the object header
  // and expand its captured fields from debug info (the $ActRec class members) --
  // $ActRec carries no runtime field table, so this must not depend on RTTI.
  if (Rtti <> nil) and LV.ValueValid and (EffVal >= 65536) then begin
    var CloBase: UInt64;
    var CloClass: string;
    if TryRecoverClosureObject(EffVal, CloBase, CloClass) then begin
      var Exp := Default(TSessionExpansion);
      Exp.Kind := exRsmMembers; Exp.BaseAddr := CloBase; Exp.TypeName := CloClass;
      Exp.EvaluateName := LV.Name;
      V.Kind := vkClass; V.Expandable := True; V.Handle := MintHandle(Exp);
      Exit;
    end;
  end;

  // Variant array local: a Variant whose VType has the varArray bit set. The
  // TVarData lives at the slot address (lkLocal) or is pointed to (lkVarParam).
  // TryMakeVariantArray self-gates on the varArray bit, so a plain scalar local
  // harmlessly fails it.
  if LV.ValueValid then begin
    var VarAddr: UInt64;
    if LV.Kind = lkVarParam then VarAddr := LV.RawValue else VarAddr := LV.Address;
    var VExp: TSessionExpansion;
    if TryMakeVariantArray(VarAddr, LV.Name, VExp) then begin
      V.Kind := vkArray; V.Expandable := True; V.Handle := MintHandle(VExp);
      Exit;
    end;
  end;

  // Dynamic array local. TD32 renders one as `^Element`, but a provider with a
  // real name gives `TArray<Element>` -- both mean the slot holds the array's
  // data pointer, so both must reach here (see TryDynArrayElementType).
  var LocalElemType: string;
  if LV.ValueValid and TryDynArrayElementType(LV.TypeHint, LocalElemType) then begin
    var Exp: TSessionExpansion;
    if TryMakeDynArray(EffVal, LocalElemType, LV.Name, Exp) then begin
      V.Kind := vkArray; V.Expandable := True; V.Handle := MintHandle(Exp);
    end;
    Exit;
  end;

  // Record local: expand its member table in place.
  if (LV.Kind = lkLocal) and (LV.Address <> 0) and (LV.TypeHint <> '') and HasMembers(LV.TypeHint) then begin
    var K := 0;
    if DebugInfo <> nil then
      K := DebugInfo.LookupTypeKind(LV.TypeHint);
    if (K <> TK_CLASS) and (K <> TK_INTERFACE) then begin
      var Exp := Default(TSessionExpansion);
      Exp.Kind := exRsmMembers; Exp.BaseAddr := LV.Address; Exp.TypeName := LV.TypeHint;
      Exp.EvaluateName := LV.Name; Exp.IsRecord := True;
      V.Kind := vkRecord; V.Expandable := True; V.Handle := MintHandle(Exp);
    end;
  end;
end;

// Renders a member/field value the way the DAP frontend does (FormatRttiField):
// class -> 'nil' | '{Type @ 0xADDR}', record -> '{Type}', dyn-array ->
// '(empty)' | 'Type[len]', everything else -> the scalar formatter.
function TVariableExpander.FormatMemberValue(const TypeName: string; TypeKind: Byte;
  FieldAddr: UInt64): string;
begin
  case TypeKind of
    TK_CLASS: begin
      var ObjPtr: UInt64 := 0;
      Debugger.ReadProcessMemoryAt(FieldAddr, @ObjPtr, Debugger.TargetLayout.PointerSize);
      if ObjPtr = 0 then
        Result := 'nil'
      else
        Result := Format('{%s @ 0x%x}', [TypeName, ObjPtr]);
    end;
    TK_RECORD, TK_MRECORD:
      Result := '{' + TypeName + '}';
    TK_DYNARRAY: begin
      var ArrPtr: UInt64 := 0;
      Debugger.ReadProcessMemoryAt(FieldAddr, @ArrPtr, Debugger.TargetLayout.PointerSize);
      if ArrPtr = 0 then
        Result := '(empty)'
      else begin
        // Prefer the element preview. The kind is CARRIED here, so the reader
        // renders the array because it was told it is one -- not because the
        // pointed-to bytes resembled a header, which is the guess a genuine
        // `^T2` aimed at a live `array of T1` also passes.
        Result := Readers.FormatLocalValue(
          SyntheticLocal('', TypeName, FieldAddr, TK_DYNARRAY));
        if Result = '' then begin
          var LenVal: UInt64 := 0;
          var Layout := Debugger.TargetLayout;
          Debugger.ReadProcessMemoryAt(Layout.DynArrayLengthAddr(ArrPtr),
            @LenVal, Layout.DynArrayLengthSize);
          Result := Format('%s[%d]', [TypeName, Integer(LenVal)]);
        end;
      end;
    end;
  else
    Result := Readers.FormatLocalValue(SyntheticLocal('', TypeName, FieldAddr));
  end;
end;

function TVariableExpander.MemberFieldToSession(const Exp: TSessionExpansion;
  const M: TClassMember; const ParentRttiFields: TArray<TRttiFieldInfo>): TSessionVariable;
begin
  var FieldAddr := Exp.BaseAddr + UInt64(M.FieldOffset);
  // The member's OWN resolved kind wins over a lookup by type NAME. The name is
  // the ambiguous thing: TD32 flattens a dynamic-array member to `^T`, spelled
  // exactly like a genuine typed pointer, so `LookupTypeKind('^Integer')` throws
  // away an answer the member already carries. Measured with
  // `Td32AliasProbe -class TManagedRec`: `Tags` arrives with kind=17
  // (tkDynArray) on both bitnesses, and asking by name turned that into nothing.
  var TypeKind: Byte := M.TypeKind;
  if (TypeKind = TK_UNKNOWN) and (DebugInfo <> nil) and (M.TypeName <> '') then
    TypeKind := DebugInfo.LookupTypeKind(M.TypeName);

  Result := Default(TSessionVariable);
  Result.Name     := M.Name;
  Result.Value    := FormatMemberValue(M.TypeName, TypeKind, FieldAddr);
  Result.TypeName := M.TypeName;
  Result.Kind     := vkScalar;
  // A field lives at a real, directly-read address in the debuggee -- always
  // addressable, unlike a getter-backed property (ExpandPropertyGetter),
  // which never sets this.
  Result.Address  := FieldAddr;
  if Exp.EvaluateName <> '' then
    Result.EvaluateName := Exp.EvaluateName + '.' + M.Name;

  var PtrVal: UInt64 := 0;
  Debugger.ReadProcessMemoryAt(FieldAddr, @PtrVal, Debugger.TargetLayout.PointerSize);
  var ChildExp: TSessionExpansion;
  if TryClassifyChild(M.TypeName, Result.EvaluateName, FieldAddr, PtrVal, ChildExp) then begin
    Result.Expandable := True;
    Result.Handle     := MintHandle(ChildExp);
    if ChildExp.IsRecord then Result.Kind := vkRecord else Result.Kind := vkClass;
    // After the handle: a dynamic array's extent comes from the expansion that
    // was just minted, which already measured its element size and count.
    DescribeStorage(Result, TypeKind, PtrVal);
    Exit;
  end;

  // Same-offset RTTI rescue: TD32 can mis-type a generic backing field (e.g.
  // TList<T>.FItems lands on PShortInt / a bare pointer, TDictionary buckets on
  // an untyped dyn-array). Consult the live object's runtime RTTI at the same
  // byte offset; if the real field there is an expandable aggregate, expand via
  // its own TypeInfo and relabel the displayed type.
  for var RF in ParentRttiFields do
    if (RF.FieldOffset = Cardinal(M.FieldOffset)) and RF.IsExpandable then begin
      var RExp: TSessionExpansion;
      if TryMakeRttiFieldExpansion(RF, RExp) then begin
        Result.Expandable := True;
        Result.Handle     := MintHandle(RExp);
        if RExp.Kind = exRecordRtti then Result.Kind := vkRecord
        else if RExp.Kind = exDynArrayRtti then Result.Kind := vkArray
        else Result.Kind := vkClass;
      end;
      if RF.TypeName <> '' then
        Result.TypeName := RF.TypeName;
      Break;
    end;
  DescribeStorage(Result, TypeKind, PtrVal);
end;

function TVariableExpander.TryMakeRttiFieldExpansion(const RF: TRttiFieldInfo;
  out Exp: TSessionExpansion): Boolean;
begin
  Result := False;
  Exp := Default(TSessionExpansion);
  if Rtti = nil then
    Exit;
  case RF.TypeKind of
    TK_CLASS: begin
      var ObjPtr: UInt64 := 0;
      if (Debugger = nil) or not Debugger.ReadProcessMemoryAt(RF.FieldAddr, @ObjPtr, Debugger.TargetLayout.PointerSize) then
        Exit;
      if ObjPtr = 0 then
        Exit;
      if not Rtti.IsClassInstance(ObjPtr) then
        Exit;
      Exp.Kind     := exClassRtti;
      Exp.BaseAddr := ObjPtr;
      Exp.TypeName := RF.TypeName;
    end;
    TK_RECORD, TK_MRECORD: begin
      if RF.TypeInfoAddr = 0 then
        Exit;
      Exp.Kind         := exRecordRtti;
      Exp.BaseAddr     := RF.FieldAddr;
      Exp.TypeInfoAddr := RF.TypeInfoAddr;
      Exp.TypeName     := RF.TypeName;
      Exp.IsRecord     := True;
    end;
    TK_DYNARRAY: begin
      if RF.TypeInfoAddr = 0 then
        Exit;
      var ElemSz: Cardinal;
      var ElemTIAddr: UInt64;
      var ElemKind: Byte;
      if not Rtti.GetDynArrayElemInfo(RF.TypeInfoAddr, ElemSz, ElemTIAddr, ElemKind) then
        Exit;
      Exp.Kind             := exDynArrayRtti;
      Exp.BaseAddr         := RF.FieldAddr;
      Exp.TypeInfoAddr     := RF.TypeInfoAddr;
      Exp.ElemSize         := ElemSz;
      Exp.ElemTypeInfoAddr := ElemTIAddr;
      Exp.ElemTypeKind     := ElemKind;
      Exp.TypeName         := RF.TypeName;
    end;
  else
    Exit;
  end;
  Result := True;
end;

// Expands a record / dyn-array node purely through runtime RTTI. Each field/
// element is rendered like FormatMemberValue and, when itself an aggregate,
// gets its own RTTI-typed child expansion (so generic nested types keep working
// where TD32/RSM have no member table).
function TVariableExpander.ExpandRttiTyped(
  const Exp: TSessionExpansion): TArray<TSessionVariable>;
var
  Fields: TArray<TRttiFieldInfo>;
begin
  Result := nil;
  if Rtti = nil then
    Exit;
  case Exp.Kind of
    exClassRtti:
      Fields := Rtti.ExpandClass(Exp.BaseAddr);
    exRecordRtti:
      Fields := Rtti.ExpandRecord(Exp.BaseAddr, Exp.TypeInfoAddr);
    exDynArrayRtti:
      Fields := Rtti.ExpandDynArray(Exp.BaseAddr, Exp.ElemTypeInfoAddr,
                                    Exp.ElemTypeKind, Exp.ElemSize);
  else
    Exit;
  end;
  SetLength(Result, Length(Fields));
  var N := 0;
  for var F in Fields do begin
    var Child := Default(TSessionVariable);
    Child.Name     := F.Name;
    Child.Value    := FormatMemberValue(F.TypeName, F.TypeKind, F.FieldAddr);
    Child.TypeName := F.TypeName;
    Child.Kind     := vkScalar;
    Child.Address  := F.FieldAddr;   // real field address, same as MemberFieldToSession
    if Exp.EvaluateName <> '' then begin
      if F.Name.StartsWith('[') then
        Child.EvaluateName := Exp.EvaluateName + F.Name          // array element
      else
        Child.EvaluateName := Exp.EvaluateName + '.' + F.Name;   // named field
    end;
    // Recurse via the field's OWN runtime TypeInfo (not TD32/RSM). This is the
    // only reliable source for generic instantiations (TList<T>.FItems,
    // TDictionary buckets) that TD32 leaves untyped.
    if F.IsExpandable then begin
      var CE: TSessionExpansion;
      if TryMakeRttiFieldExpansion(F, CE) then begin
        CE.EvaluateName  := Child.EvaluateName;
        Child.Expandable := True;
        Child.Handle     := MintHandle(CE);
        if CE.Kind = exRecordRtti then Child.Kind := vkRecord
        else if CE.Kind = exDynArrayRtti then Child.Kind := vkArray
        else Child.Kind := vkClass;
      end;
    end;
    // Where this field's bytes are. A string field holds a pointer, so the row
    // must point a memory view at the characters rather than at the slot.
    var FieldPtr: UInt64 := 0;
    if Debugger <> nil then
      Debugger.ReadProcessMemoryAt(F.FieldAddr, @FieldPtr, Debugger.TargetLayout.PointerSize);
    DescribeStorage(Child, F.TypeKind, FieldPtr);
    Result[N] := Child;
    Inc(N);
  end;
end;

// A property-bearing class expands into up to three synthetic category rows:
// 'properties' (non-event), 'event handlers' (method-pointer), and 'fields'
// (the flat backing-field list, which stays writable).
function TVariableExpander.BuildGroupNodes(const Exp: TSessionExpansion;
  const Members: TArray<TClassMember>): TArray<TSessionVariable>;

  function GroupNode(const Name: string; Kind: TSessionExpKind;
    NoGroup: Boolean): TSessionVariable;
  begin
    var G := Exp;
    G.Kind    := Kind;
    G.NoGroup := NoGroup;
    Result := Default(TSessionVariable);
    Result.Name       := Name;
    Result.Kind       := vkGroup;
    Result.Expandable := True;
    Result.Handle     := MintHandle(G);
  end;

begin
  var List := TList<TSessionVariable>.Create;
  try
    if ClassHasPropertyKind(Members, False) then
      List.Add(GroupNode('properties', exPropGroup, False));
    if ClassHasPropertyKind(Members, True) then
      List.Add(GroupNode('event handlers', exEventGroup, False));
    List.Add(GroupNode('fields', exRsmMembers, True));
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TVariableExpander.ExpandViaMembers(
  const Exp: TSessionExpansion): TArray<TSessionVariable>;
var
  Members: TArray<TClassMember>;
  List: TList<TSessionVariable>;
begin
  Result := nil;
  // The object's real VMT size disambiguates a bare class name shared across
  // units, so the right class's members are listed.
  var PreferSize := 0;
  if (Rtti <> nil) and (Exp.BaseAddr <> 0) and Rtti.IsClassInstance(Exp.BaseAddr) then
    PreferSize := Rtti.GetInstanceSize(Exp.BaseAddr);
  if not GetDisplayMembers(Exp.TypeName, Members, PreferSize) then
    Exit;
  // Top of a property-bearing type: split into properties / events / fields.
  if (not Exp.NoGroup) and ClassHasProperties(Members) then
    Exit(BuildGroupNodes(Exp, Members));
  // RTTI field view of the same instance (empty for a record base), matched by
  // offset to rescue members TD32 left untyped (e.g. a generic backing field).
  var ParentRttiFields: TArray<TRttiFieldInfo>;
  if Rtti <> nil then
    ParentRttiFields := Rtti.ExpandClass(Exp.BaseAddr);
  // Flat field list (a plain record/class, or the 'fields' group node).
  List := TList<TSessionVariable>.Create;
  try
    for var M in Members do begin
      if M.Kind <> cmkField then
        Continue;
      List.Add(MemberFieldToSession(Exp, M, ParentRttiFields));
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

// --- property / event classification (ported from the DAP frontend) ---

function TVariableExpander.IsEventHandlerProp(const P: TClassMember): Boolean;
begin
  if P.Kind <> cmkProperty then Exit(False);
  if SameText(P.TypeName, 'procedure of object') then Exit(True);
  Result := (DebugInfo <> nil) and (P.TypeName <> '') and
            (DebugInfo.LookupTypeKind(P.TypeName) = TK_METHOD);
end;

function TVariableExpander.ClassHasProperties(
  const Members: TArray<TClassMember>): Boolean;
begin
  for var M in Members do
    if M.Kind = cmkProperty then
      Exit(True);
  Result := False;
end;

function TVariableExpander.ClassHasPropertyKind(
  const Members: TArray<TClassMember>; WantEvents: Boolean): Boolean;
begin
  for var M in Members do
    if (M.Kind = cmkProperty) and (IsEventHandlerProp(M) = WantEvents) then
      Exit(True);
  Result := False;
end;

// Decides whether a property is field-backed (read the backing field inline) or
// getter-backed (defer). Returns the backing byte offset when field-backed.
function TVariableExpander.PropertyBackingFieldOffset(
  const Members: TArray<TClassMember>; const Prop: TClassMember;
  out Offset: Integer): Boolean;
begin
  Offset := 0;
  if Prop.GetterName <> '' then Exit(False);
  for var M in Members do
    if (M.Kind = cmkField) and (Prop.GetterHash <> 0) and
       (M.Hash = Prop.GetterHash) then begin
      Offset := M.FieldOffset;
      Exit(True);
    end;
  if Prop.FieldOffset > 0 then begin
    Offset := Prop.FieldOffset;
    Exit(True);
  end;
  for var M in Members do
    if (M.Kind = cmkField) and (M.FieldOffset > 0) and
       SameText(M.Name, 'F' + Prop.Name) then begin
      Offset := M.FieldOffset;
      Exit(True);
    end;
  Result := False;
end;

// Enumerates the properties (exPropGroup) or event handlers (exEventGroup) of a
// class: field-backed read inline, getter-backed deferred, indexed as a leaf.
function TVariableExpander.ExpandProperties(
  const Exp: TSessionExpansion): TArray<TSessionVariable>;
var
  Members: TArray<TClassMember>;
begin
  Result := nil;
  if not GetDisplayMembers(Exp.TypeName, Members) then
    Exit;
  var WantEvents := Exp.Kind = exEventGroup;
  var List := TList<TSessionVariable>.Create;
  // Members span the whole ancestor chain, so a property re-published at several
  // levels (Caption, AutoScroll, ...) appears more than once. Keep the first (most
  // specific) and drop later duplicates so the group is not noisy (F7).
  var Seen := TDictionary<string, Boolean>.Create;
  try
    for var P in Members do begin
      if P.Kind <> cmkProperty then Continue;
      if IsEventHandlerProp(P) <> WantEvents then Continue;
      if Seen.ContainsKey(LowerCase(P.Name)) then Continue;
      Seen.Add(LowerCase(P.Name), True);

      var PropExpr := '';
      if Exp.EvaluateName <> '' then
        PropExpr := Exp.EvaluateName + '.' + P.Name;

      var Child := Default(TSessionVariable);
      Child.Name         := P.Name;
      Child.Kind         := vkProperty;
      Child.EvaluateName := PropExpr;

      // Indexed property: no general way to enumerate indices -> leaf.
      if P.IsIndexed then begin
        Child.Value := '(indexed property)';
        if P.TypeName <> '' then
          Child.TypeName := P.TypeName + ' [indexed]';
        List.Add(Child);
        Continue;
      end;

      var Offset: Integer;
      if PropertyBackingFieldOffset(Members, P, Offset) then begin
        var FieldAddr := Exp.BaseAddr + UInt64(Offset);
        var TypeKind: Byte := TK_UNKNOWN;
        if (DebugInfo <> nil) and (P.TypeName <> '') then
          TypeKind := DebugInfo.LookupTypeKind(P.TypeName);
        Child.Value    := FormatMemberValue(P.TypeName, TypeKind, FieldAddr);
        Child.TypeName := P.TypeName;
        Child.Address  := FieldAddr;   // field-backed: a real address, unlike the getter-backed branch below
        var PtrVal: UInt64 := 0;
        Debugger.ReadProcessMemoryAt(FieldAddr, @PtrVal, Debugger.TargetLayout.PointerSize);
        var ChildExp: TSessionExpansion;
        if TryClassifyChild(P.TypeName, PropExpr, FieldAddr, PtrVal, ChildExp) then begin
          Child.Expandable := True;
          Child.Handle     := MintHandle(ChildExp);
          if ChildExp.IsRecord then Child.Kind := vkRecord else Child.Kind := vkClass;
        end;
        // A field-backed property has the backing field's storage. The
        // getter-backed branch below deliberately gets none: a value a getter
        // CALL produced exists nowhere to point at.
        DescribeStorage(Child, TypeKind, PtrVal);
      end
      else begin
        // Getter-backed: deferred by default -- calling code the user did not
        // ask to run is how a debugger mutates the state it is showing. The
        // safelist lifts the deferral for members someone vouched for, and
        // what it authorises is EXACTLY the call clicking "expand to evaluate"
        // would have made: same resolution, same guards, no new call path.
        Child.SafelistKey := SafelistKeyFor(Exp.TypeName, P);
        if PropExpr <> '' then begin
          if (Policy <> nil) and
             TSafeCallPolicy.AllowsAutoCall(
               Policy.Resolve(SafelistKeysFor(Exp.TypeName, P))) then begin
            EvaluateGetterInto(Child, PropExpr, P.TypeName);
          end
          else begin
            var GetExp := Default(TSessionExpansion);
            GetExp.Kind         := exPropertyGetter;
            GetExp.BaseAddr     := Exp.BaseAddr;
            GetExp.TypeName     := P.TypeName;
            GetExp.EvaluateName := PropExpr;
            Child.Value      := '(expand to evaluate)';
            Child.Expandable := True;
            Child.Handle     := MintHandle(GetExp);
          end;
        end
        else
          Child.Value := '(getter)';
        if (Child.TypeName = '') and (P.TypeName <> '') then
          Child.TypeName := P.TypeName;
      end;
      List.Add(Child);
    end;
    Result := List.ToArray;
  finally
    List.Free;
    Seen.Free;
  end;
end;

function TVariableExpander.SafelistKeysFor(const OwnerClass: string;
  const P: TClassMember): TArray<string>;

  procedure Add(const Cls, Member: string);
  begin
    if (Cls = '') or (Member = '') then
      Exit;
    var K := LowerCase(Cls + '.' + Member);
    for var Existing in Result do
      if Existing = K then
        Exit;
    Result := Result + [K];
  end;

begin
  Result := nil;
  // Property spellings FIRST, so SafelistKeyFor (the one the UI writes for a
  // deny/allow) is `class.property`. That is the only form a hand-typed watch
  // -- `Self.Score` -- can reconstruct, so a deny written here also bites in the
  // Debug Console, not just in the expansion tree. It is also the readable form
  // for a hand-edited file.
  Add(OwnerClass,  P.Name);
  Add(P.DeclClass, P.Name);
  // Getter-METHOD spellings after: an analysis archive keys the verdict by the
  // code that runs, so the expansion lookup must still find `TStrings.GetTextStr`
  // -- it just is not the spelling a click writes.
  Add(P.DeclClass, P.GetterName);
  Add(OwnerClass,  P.GetterName);
end;

function TVariableExpander.SafelistKeyFor(const OwnerClass: string;
  const P: TClassMember): string;
begin
  var Keys := SafelistKeysFor(OwnerClass, P);
  if Length(Keys) = 0 then
    Exit('');
  Result := Keys[0];
end;

procedure TVariableExpander.EvaluateGetterInto(var Child: TSessionVariable;
  const PropExpr, DeclaredTypeName: string);
begin
  if Debugger = nil then
    Exit;
  Debugger.ClearActiveFrame;
  var Eval := TExprEvaluator.Create(Debugger, Rtti, DebugInfo);
  var Val: TExprValue;
  var OK: Boolean;
  try
    OK := Eval.Evaluate(PropExpr, Val);
  finally
    Eval.Free;
  end;

  if not OK then begin
    // The raise/AV/watchdog abort inside the synthetic call turned into an
    // error string. Showing it IS the contract for a mayRaise member.
    Child.Value := Val.TypeHint;
    if DeclaredTypeName <> '' then
      Child.TypeName := DeclaredTypeName;
    Exit;
  end;

  Child.Value := FormatExprValue(Val);
  if Val.TypeHint <> '' then
    Child.TypeName := Val.TypeHint
  else if DeclaredTypeName <> '' then
    Child.TypeName := DeclaredTypeName;

  // Same drill-down the deferred path's expansion would have offered: a class
  // or record result gets a members handle; the value row replaces only the
  // '(expand to evaluate)' placeholder, never the ability to descend.
  var IsClassInst := (Rtti <> nil) and (Val.RawValue >= 65536) and
                     Rtti.IsClassInstance(Val.RawValue);
  var DrillAddr: UInt64;
  if IsClassInst then DrillAddr := Val.RawValue else DrillAddr := Val.Address;
  var ChildExp: TSessionExpansion;
  if (DrillAddr >= 65536) and
     TryClassifyChild(Child.TypeName, PropExpr, Val.Address, Val.RawValue, ChildExp) then begin
    Child.Expandable := True;
    Child.Handle     := MintHandle(ChildExp);
    if ChildExp.IsRecord then Child.Kind := vkRecord else Child.Kind := vkClass;
  end;
end;

// Runs a deferred getter-backed property (exPropertyGetter). Evaluates the
// property expression against the top frame, then splits a structured result
// into its members or emits a single '(value)' leaf.
function TVariableExpander.ExpandPropertyGetter(
  const Exp: TSessionExpansion): TArray<TSessionVariable>;
begin
  Result := nil;
  if Debugger = nil then Exit;

  Debugger.ClearActiveFrame;
  var Eval := TExprEvaluator.Create(Debugger, Rtti, DebugInfo);
  var Val: TExprValue;
  var OK: Boolean;
  try
    OK := Eval.Evaluate(Exp.EvaluateName, Val);
  finally
    Eval.Free;
  end;

  if not OK then begin
    var ErrLeaf := Default(TSessionVariable);
    ErrLeaf.Name  := '(value)';
    ErrLeaf.Value := Val.TypeHint;   // error text, e.g. '<X: not found>'
    Result := [ErrLeaf];
    Exit;
  end;

  var IsClassInst := (Rtti <> nil) and (Val.RawValue >= 65536) and
                     Rtti.IsClassInstance(Val.RawValue);
  var Kind: Byte := TK_UNKNOWN;
  if (DebugInfo <> nil) and (Val.TypeHint <> '') then
    Kind := DebugInfo.LookupTypeKind(Val.TypeHint);
  var Structured := IsClassInst or IsExpandableTKind(Kind) or
                    (Kind = TK_DYNARRAY) or (Kind = TK_ARRAY);
  var DisplayAddr: UInt64;
  if IsClassInst then DisplayAddr := Val.RawValue else DisplayAddr := Val.Address;
  var Members: TArray<TClassMember>;
  var StructHasMembers := (Val.TypeHint <> '') and
                          GetDisplayMembers(Val.TypeHint, Members) and (Length(Members) > 0);
  if (DisplayAddr >= 65536) and StructHasMembers and Structured then begin
    var ResultExp := Default(TSessionExpansion);
    ResultExp.Kind         := exRsmMembers;
    ResultExp.BaseAddr     := DisplayAddr;
    ResultExp.TypeName     := Val.TypeHint;
    ResultExp.EvaluateName := Exp.EvaluateName;
    Exit(ExpandViaMembers(ResultExp));
  end;

  // Scalar result -> single leaf carrying the evaluated value.
  var Leaf := Default(TSessionVariable);
  Leaf.Name         := '(value)';
  Leaf.EvaluateName := Exp.EvaluateName;
  Leaf.Value        := FormatExprValue(Val);
  Leaf.TypeName     := Val.TypeHint;
  Result := [Leaf];
end;


function TVariableExpander.TryMakeDynArray(SlotPtr: UInt64;
  const ElemTypeName, EvalName: string; out Exp: TSessionExpansion): Boolean;
const
  MAX_LEN = 1 shl 24;   // 16M elements sanity cap
begin
  Result := False;
  Exp := Default(TSessionExpansion);
  if (SlotPtr < 65536) or (Debugger = nil) or (DebugInfo = nil) or (ElemTypeName = '') then
    Exit;
  // SlotPtr = the array DATA pointer. TDynArrayRec sits just below it, and its
  // shape is bitness-dependent (unlike the string header): Win64 has
  // -12 RefCnt(i32), -8 Length(NativeInt=8); Win32 has -8 RefCnt, -4 Length(4).
  // A genuine typed pointer fails the header sanity (its preceding bytes are
  // not a valid refcnt/length pair).
  // Len starts at 0, not a sentinel: a 32-bit target writes only the low 4
  // bytes, so anything else would leave the high half as garbage.
  var Len: Int64 := 0;
  var RefCount: Int32 := -999;
  var ElemSize: Integer := 0;
  var Layout := Debugger.TargetLayout;
  var RdLen := Debugger.ReadProcessMemoryAt(Layout.DynArrayLengthAddr(SlotPtr),
                 @Len, Layout.DynArrayLengthSize);
  var RdRef := Debugger.ReadProcessMemoryAt(Layout.DynArrayRefCountAddr(SlotPtr),
                 @RefCount, 4);
  var GotSize := DebugInfo.GetTypeSize(ElemTypeName, ElemSize);
  if not RdLen or not RdRef then
    Exit;
  if (Len < 1) or (Len > MAX_LEN) then
    Exit;
  if not ((RefCount = -1) or ((RefCount >= 1) and (RefCount <= MAX_LEN))) then
    Exit;
  if not GotSize or (ElemSize <= 0) then
    Exit;
  Exp.Kind         := exDynArray;
  Exp.BaseAddr     := SlotPtr;
  Exp.ElemTypeName := ElemTypeName;
  Exp.ElemSize     := Cardinal(ElemSize);
  Exp.ElemCount    := Integer(Len);
  Exp.EvaluateName := EvalName;
  Result := True;
end;

function TVariableExpander.ExpandDynArray(
  const Exp: TSessionExpansion): TArray<TSessionVariable>;
const
  MAX_CHILDREN = 1024;
begin
  Result := nil;
  if (Exp.BaseAddr = 0) or (Exp.ElemSize = 0) then
    Exit;
  var Total := Exp.ElemCount;
  var Capped := Total > MAX_CHILDREN;
  if Capped then
    Total := MAX_CHILDREN;

  var ElemKind := 0;
  if DebugInfo <> nil then
    ElemKind := DebugInfo.LookupTypeKind(Exp.ElemTypeName);
  var ElemMembers: TArray<TClassMember>;
  var ElemHasMembers := GetDisplayMembers(Exp.ElemTypeName, ElemMembers);

  var List := TList<TSessionVariable>.Create;
  try
    for var I := 0 to Total - 1 do begin
      var ElemAddr := Exp.BaseAddr + UInt64(I) * Exp.ElemSize;
      var Child := Default(TSessionVariable);
      Child.Name     := Format('[%d]', [I]);
      Child.TypeName := Exp.ElemTypeName;
      Child.Kind     := vkScalar;
      Child.Address  := ElemAddr;   // real element slot in the array's data buffer
      if Exp.EvaluateName <> '' then
        Child.EvaluateName := Format('%s[%d]', [Exp.EvaluateName, I]);

      if ElemKind = TK_CLASS then begin
        var ObjPtr: UInt64 := 0;
        Debugger.ReadProcessMemoryAt(ElemAddr, @ObjPtr, Debugger.TargetLayout.PointerSize);
        if ObjPtr = 0 then
          Child.Value := 'nil'
        else begin
          var RtClass := Exp.ElemTypeName;
          if Rtti <> nil then begin
            var Rn := Rtti.GetInstanceClassName(ObjPtr);
            if Rn <> '' then RtClass := Rn;
          end;
          Child.Value := Format('$%x (%s)', [ObjPtr, RtClass]);
          if ElemHasMembers and (ObjPtr >= 65536) then begin
            var CE := Default(TSessionExpansion);
            CE.Kind := exRsmMembers; CE.BaseAddr := ObjPtr; CE.TypeName := Exp.ElemTypeName;
            CE.EvaluateName := Child.EvaluateName;
            Child.Expandable := True; Child.Handle := MintHandle(CE); Child.Kind := vkClass;
          end;
        end;
      end
      else if ElemHasMembers then begin
        Child.Value := '{' + Exp.ElemTypeName + '}';
        var CE := Default(TSessionExpansion);
        CE.Kind := exRsmMembers; CE.BaseAddr := ElemAddr; CE.TypeName := Exp.ElemTypeName;
        CE.EvaluateName := Child.EvaluateName; CE.IsRecord := True;
        Child.Expandable := True; Child.Handle := MintHandle(CE); Child.Kind := vkRecord;
      end
      else begin
        var LV := SyntheticLocal('', Exp.ElemTypeName, ElemAddr);
        Child.Value := Readers.FormatLocalValue(LV);
      end;
      // An element of an array of strings or of objects holds a pointer like
      // any other slot; the row points at what it refers to.
      var ElemPtr: UInt64 := 0;
      Debugger.ReadProcessMemoryAt(ElemAddr, @ElemPtr, Debugger.TargetLayout.PointerSize);
      DescribeStorage(Child, ElemKind, ElemPtr);
      // The element's own width is known exactly here -- it is what the stride
      // was computed from -- so it beats anything derived from the type name.
      if Child.DataAddress = 0 then
        Child.ValueSize := Exp.ElemSize;
      List.Add(Child);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

// Formats one VarArray cell. varVariant elements are 24-byte TVarData ->
// recurse; typed elements decode per-VType.
function TVariableExpander.FormatVariantElement(ElemAddr: UInt64; BaseType: Word;
  ElemSize: Cardinal): string;
var
  Buf: array[0..15] of Byte;
begin
  Result := '<read failed>';
  if BaseType = varVariant then
    Exit(Readers.FormatVariantAt(ElemAddr));
  var ReadBytes := Integer(ElemSize);
  if ReadBytes > SizeOf(Buf) then ReadBytes := SizeOf(Buf);
  if ReadBytes <= 0 then Exit;
  if not Debugger.ReadProcessMemoryAt(ElemAddr, @Buf, ReadBytes) then Exit;
  case BaseType of
    varSmallint: Result := IntToStr(PSmallInt(@Buf[0])^);
    varInteger:  Result := IntToStr(PInteger(@Buf[0])^);
    varSingle:   Result := FormatFloatNicely(PSingle(@Buf[0])^);
    varDouble:   Result := FormatFloatNicely(PDouble(@Buf[0])^);
    varCurrency: Result := FormatFloatNicely(PInt64(@Buf[0])^ / 10000.0);
    varDate:     Result := FormatDelphiDateTime(PDouble(@Buf[0])^);
    varBoolean:
      if PSmallInt(@Buf[0])^ <> 0 then Result := 'True' else Result := 'False';
    varShortInt: Result := IntToStr(PShortInt(@Buf[0])^);
    varByte:     Result := IntToStr(PByte(@Buf[0])^);
    varWord:     Result := IntToStr(PWord(@Buf[0])^);
    varLongWord: Result := IntToStr(PCardinal(@Buf[0])^);
    varInt64:    Result := IntToStr(PInt64(@Buf[0])^);
    varUInt64:   Result := UIntToStr(PUInt64(@Buf[0])^);
    varOleStr, varUString: begin
      var Ptr := PUInt64(@Buf[0])^;
      if Ptr = 0 then
        Result := ''''''
      else begin
        var S: string;
        if Readers.ReadDelphiUnicodeString(Ptr, S) then
          Result := QuotedStr(S)
        else
          Result := Format('@0x%x', [Ptr]);
      end;
    end;
    varString: begin
      var Ptr := PUInt64(@Buf[0])^;
      if Ptr = 0 then
        Result := ''''''
      else begin
        var S: string;
        if Readers.ReadDelphiAnsiString(Ptr, S) then
          Result := QuotedStr(S)
        else
          Result := Format('@0x%x', [Ptr]);
      end;
    end;
  else
    Result := Format('0x%x', [PUInt64(@Buf[0])^]);
  end;
end;

// Validates a Variant slot as a VarArray and captures its header + bounds (user
// order). Returns False for a plain (non-array) Variant or a by-ref array.
function TVariableExpander.TryMakeVariantArray(VariantAddr: UInt64;
  const EvalName: string; out Exp: TSessionExpansion): Boolean;
var
  Header: array[0..7] of Byte;
  Data:   UInt64;
begin
  Result := False;
  Exp := Default(TSessionExpansion);
  if (VariantAddr = 0) or (Debugger = nil) then Exit;
  if not Debugger.ReadProcessMemoryAt(VariantAddr,     @Header, 8) then Exit;
  if not Debugger.ReadProcessMemoryAt(VariantAddr + 8, @Data,   8) then Exit;
  var VType := PWord(@Header[0])^;
  if (VType and varArray) = 0 then Exit;
  if (VType and varByRef) <> 0 then Exit;
  var VarArrPtr := Data;
  if VarArrPtr = 0 then Exit;
  var DimWord: Word;
  if not Debugger.ReadProcessMemoryAt(VarArrPtr, @DimWord, 2) then Exit;
  var DimCount := Integer(DimWord);
  if (DimCount < 1) or (DimCount > 16) then Exit;
  var BoundsBase := VarArrPtr + 24;
  var Bounds: TArray<Integer>;
  SetLength(Bounds, DimCount * 2);
  for var I := 0 to DimCount - 1 do begin
    var StorageK := DimCount - 1 - I;
    var EC, LB: Cardinal;
    if not Debugger.ReadProcessMemoryAt(BoundsBase + UInt64(StorageK * 8),     @EC, 4) then Exit;
    if not Debugger.ReadProcessMemoryAt(BoundsBase + UInt64(StorageK * 8 + 4), @LB, 4) then Exit;
    Bounds[I * 2]     := Int32(LB);
    Bounds[I * 2 + 1] := Int32(EC);
  end;
  Exp.Kind         := exVariantArray;
  Exp.VarArrPtr    := VarArrPtr;
  Exp.VarBaseType  := VType and varTypeMask;
  Exp.VarDimCount  := DimCount;
  Exp.VarBounds    := Bounds;
  Exp.EvaluateName := EvalName;
  Result := True;
end;

function TVariableExpander.ExpandVariantArray(
  const Exp: TSessionExpansion): TArray<TSessionVariable>;
const
  MAX_CHILDREN = 1024;
var
  ElemSize: Cardinal;
  DataPtr:  UInt64;
begin
  Result := nil;
  if (Exp.VarArrPtr = 0) or (Debugger = nil) then Exit;
  if not Debugger.ReadProcessMemoryAt(Exp.VarArrPtr + 4,  @ElemSize, 4) then Exit;
  if not Debugger.ReadProcessMemoryAt(Exp.VarArrPtr + 16, @DataPtr,  8) then Exit;
  if (DataPtr = 0) or (ElemSize = 0) then Exit;
  var N := Exp.VarDimCount;
  if (N < 1) or (N * 2 > Length(Exp.VarBounds)) then Exit;
  var LBs, ECs: TArray<Integer>;
  SetLength(LBs, N);
  SetLength(ECs, N);
  for var I := 0 to N - 1 do begin
    LBs[I] := Exp.VarBounds[I * 2];
    ECs[I] := Exp.VarBounds[I * 2 + 1];
  end;
  var TotalElems: Int64 := 1;
  for var EC in ECs do
    TotalElems := TotalElems * Int64(EC);
  var Total := TotalElems;
  var Capped := Total > MAX_CHILDREN;
  if Capped then
    Total := MAX_CHILDREN;

  var List := TList<TSessionVariable>.Create;
  try
    var Coords: TArray<Integer>;
    SetLength(Coords, N);
    for var Lin: Int64 := 0 to Total - 1 do begin
      var Rem: Int64 := Lin;
      for var I := 0 to N - 1 do begin
        Coords[I] := LBs[I] + Integer(Rem mod ECs[I]);
        Rem       := Rem div ECs[I];
      end;
      var ElemAddr := DataPtr + UInt64(Lin) * ElemSize;
      var Nm: string := '[';
      for var I := 0 to N - 1 do begin
        if I > 0 then Nm := Nm + ',';
        Nm := Nm + IntToStr(Coords[I]);
      end;
      Nm := Nm + ']';
      var Child := Default(TSessionVariable);
      Child.Name    := Nm;
      Child.Kind    := vkVariant;
      Child.Value   := FormatVariantElement(ElemAddr, Exp.VarBaseType, ElemSize);
      Child.Address := ElemAddr;   // real element slot in the VarArray's data buffer
      // A VarArray cell is a value in place, of exactly the stride the array was
      // created with -- no pointer to follow, and no type name to ask.
      Child.ValueSize := ElemSize;
      if Exp.EvaluateName <> '' then
        Child.EvaluateName := Exp.EvaluateName + Nm;
      List.Add(Child);
    end;
    if Capped then begin
      var Trailer := Default(TSessionVariable);
      Trailer.Name  := '...';
      Trailer.Value := Format('(showing first %d of %d elements)', [MAX_CHILDREN, TotalElems]);
      List.Add(Trailer);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TVariableExpander.MakeClassExpansion(BaseAddr: UInt64;
  const ClassName, EvalName: string): TVarHandle;
var
  Members: TArray<TClassMember>;
begin
  Result := 0;
  if BaseAddr < 65536 then
    Exit;
  var Exp := Default(TSessionExpansion);
  Exp.BaseAddr     := BaseAddr;
  Exp.EvaluateName := EvalName;
  Exp.TypeName     := ClassName;
  if (ClassName <> '') and GetDisplayMembers(ClassName, Members) and (Length(Members) > 0) then
    Exp.Kind := exRsmMembers
  else
    Exp.Kind := exClassRtti;
  Result := MintHandle(Exp);
end;

function TVariableExpander.TryGetWritableField(Handle: TVarHandle;
  const FieldName: string; out FieldAddr: UInt64; out FieldType: string): Boolean;
var
  Exp: TSessionExpansion;
  Members: TArray<TClassMember>;
begin
  Result    := False;
  FieldAddr := 0;
  FieldType := '';
  if not FByHandle.TryGetValue(Handle, Exp) then
    Exit;
  if Exp.Kind <> exRsmMembers then
    Exit;   // only member expansions expose writable backing fields
  if not GetDisplayMembers(Exp.TypeName, Members) then
    Exit;
  for var M in Members do
    if (M.Kind = cmkField) and SameText(M.Name, FieldName) then begin
      FieldAddr := Exp.BaseAddr + UInt64(M.FieldOffset);
      FieldType := M.TypeName;
      Exit(True);
    end;
end;

function TVariableExpander.MakeVariantArrayExpansion(VariantAddr: UInt64;
  const EvalName: string): TVarHandle;
var
  Exp: TSessionExpansion;
begin
  Result := 0;
  if TryMakeVariantArray(VariantAddr, EvalName, Exp) then
    Result := MintHandle(Exp);
end;

function TVariableExpander.TryGetExpansion(Handle: TVarHandle;
  out Exp: TSessionExpansion): Boolean;
begin
  Result := FByHandle.TryGetValue(Handle, Exp);
end;

function TVariableExpander.PayloadAddress(TypeKind: Byte; const TypeHint: string;
  RawValue: UInt64; ForceReference: Boolean): UInt64;
const
  // Below this, an address is not a user-space allocation on either bitness --
  // it is a nil reference, or a small ordinal sharing the slot's spelling.
  MIN_PLAUSIBLE_ADDR = 65536;

  function TypeNameIsReference: Boolean;
  begin
    // TD32 does not always resolve a kind (0), and the name is then the only
    // evidence there is. Restricted to spellings that can ONLY be a managed
    // reference -- never `Pointer` or `PChar`, whose value is the answer.
    for var Nm in ['string', 'UnicodeString', 'AnsiString', 'WideString', 'RawByteString',
                   'UTF8String', 'TBytes'] do
      if SameText(Trim(TypeHint), Nm) then
        Exit(True);
    Result := False;
  end;

begin
  Result := 0;
  if (RawValue < MIN_PLAUSIBLE_ADDR) or (Debugger = nil) then
    Exit;
  if not (ForceReference or
          (TypeKind in [TK_LSTRING, TK_WSTRING, TK_CLASS, TK_INTERFACE,
                        TK_DYNARRAY, TK_USTRING]) or
          ((TypeKind = TK_UNKNOWN) and TypeNameIsReference)) then
    Exit;
  // Readable, or it is not an address worth handing to a memory view.
  var Probe: Byte := 0;
  if not Debugger.ReadProcessMemoryAt(RawValue, @Probe, 1) then
    Exit;
  Result := RawValue;
end;

function TVariableExpander.NamedTypeByteSize(const TypeName: string;
  PtrSize: Integer): Integer;
begin
  var N := Trim(TypeName);
  for var Nm in ['Byte', 'ShortInt', 'Boolean', 'ByteBool', 'AnsiChar', 'UInt8', 'Int8'] do
    if SameText(N, Nm) then Exit(1);
  for var Nm in ['Word', 'SmallInt', 'WordBool', 'Char', 'WideChar', 'UInt16', 'Int16'] do
    if SameText(N, Nm) then Exit(2);
  for var Nm in ['Integer', 'LongInt', 'Cardinal', 'LongWord', 'LongBool', 'Single',
                 'UInt32', 'Int32', 'FixedInt', 'FixedUInt'] do
    if SameText(N, Nm) then Exit(4);
  for var Nm in ['Int64', 'UInt64', 'Double', 'Currency', 'TDateTime', 'TDate',
                 'TTime', 'Comp', 'Real'] do
    if SameText(N, Nm) then Exit(8);
  for var Nm in ['Pointer', 'NativeInt', 'NativeUInt', 'THandle', 'string',
                 'UnicodeString', 'AnsiString', 'WideString', 'PChar', 'PAnsiChar',
                 'PWideChar'] do
    if SameText(N, Nm) then Exit(PtrSize);
  // The wide floats. WideFloatByteSize reports only the widths that DIFFER from
  // the eight-byte value slot -- it answers 0 for `Extended` on Win64, where the
  // type IS a plain Double -- so 0 there means "eight", not "unknown". Taking
  // that 0 at face value reported a Win64 Extended local as having no
  // measurable extent at all.
  for var Nm in ['Extended', 'Extended80', 'Real48'] do
    if SameText(N, Nm) then begin
      var Wide := WideFloatByteSize(N, PtrSize);
      if Wide > 0 then
        Exit(Wide);
      Exit(8);
    end;
  Result := 0;
end;

function TVariableExpander.ValueByteSize(TypeKind: Byte; const TypeHint: string;
  Address, DataAddress: UInt64; Handle: TVarHandle): UInt64;
const
  // A value bigger than this is not a variable's extent; it is a decode that
  // went wrong.
  MAX_EXTENT = 16 * 1024 * 1024;

  // Delphi's string header is the same shape on both bitnesses:
  // CodePage(2) ElemSize(2) RefCnt(4) Length(4), then the characters. The byte
  // length is Length * ElemSize, both READ from the header rather than assumed
  // from the type name -- an AnsiString and a UnicodeString differ by exactly
  // that factor.
  function StringPayloadBytes(Payload: UInt64): UInt64;
  begin
    Result := 0;
    if (Payload < 65536) or (Debugger = nil) then
      Exit;
    var ElemSize: UInt16 := 0;
    var Len: Int32 := 0;
    if not Debugger.ReadProcessMemoryAt(Payload - 10, @ElemSize, 2) then
      Exit;
    if not Debugger.ReadProcessMemoryAt(Payload - 4, @Len, 4) then
      Exit;
    if (Len <= 0) or (ElemSize = 0) or (ElemSize > 4) then
      Exit;
    if Int64(Len) * ElemSize > MAX_EXTENT then
      Exit;
    Result := UInt64(Len) * ElemSize;
  end;

  function TypeNameIsString: Boolean;
  begin
    for var Nm in ['string', 'UnicodeString', 'AnsiString', 'WideString',
                   'RawByteString', 'UTF8String'] do
      if SameText(Trim(TypeHint), Nm) then
        Exit(True);
    Result := False;
  end;

begin
  Result := 0;
  if DataAddress <> 0 then begin
    // The dynamic-array expansion FIRST, and regardless of the declared kind:
    // it is measured EVIDENCE (a validated length/refcount header plus a known
    // element size), where the kind is only a claim the type table makes.
    if Handle <> 0 then begin
      var Exp: TSessionExpansion;
      if TryGetExpansion(Handle, Exp) and (Exp.Kind = exDynArray) and
         (Exp.ElemSize > 0) and (Exp.ElemCount > 0) then begin
        var Total := UInt64(Exp.ElemSize) * UInt64(Exp.ElemCount);
        if Total <= MAX_EXTENT then
          Exit(Total);
      end;
    end;
    if (TypeKind in [TK_LSTRING, TK_WSTRING, TK_USTRING]) or TypeNameIsString then
      Exit(StringPayloadBytes(DataAddress));
    // A live object answers for itself: its VMT carries InstanceSize. Accepted
    // on the runtime evidence rather than only on a declared TK_CLASS, for the
    // same reason as the array above.
    if (Rtti <> nil) and ((TypeKind = TK_CLASS) or Rtti.IsClassInstance(DataAddress)) then begin
      var InstSize := Rtti.GetInstanceSize(DataAddress);
      if (InstSize > 0) and (InstSize <= MAX_EXTENT) then
        Exit(UInt64(InstSize));
      Exit(0);
    end;
    // A payload whose length nothing here can establish (an interface, a
    // reference type this build does not decode): no extent rather than a
    // plausible one.
    Exit(0);
  end;

  if Address = 0 then
    Exit;

  var PtrSize := 8;
  if Debugger <> nil then
    PtrSize := Debugger.TargetLayout.PointerSize;

  var Named := NamedTypeByteSize(TypeHint, PtrSize);
  if Named > 0 then
    Exit(UInt64(Named));

  if (TypeHint <> '') and (DebugInfo <> nil) then begin
    var Sz: Integer;
    if DebugInfo.GetTypeSize(TypeHint, Sz) and (Sz > 0) and (Sz <= MAX_EXTENT) then
      Exit(UInt64(Sz));
  end;

  // A reference-typed row with no payload to point at -- a nil object, an empty
  // string, an unassigned interface. It is still a pointer-wide slot, and that
  // slot IS what a view opened on it shows.
  if TypeKind in [TK_LSTRING, TK_WSTRING, TK_USTRING, TK_CLASS, TK_DYNARRAY] then
    Exit(UInt64(PtrSize));
  if (DebugInfo <> nil) and (TypeHint <> '') and
     (DebugInfo.LookupTypeKind(TypeHint) in [TK_CLASS, TK_DYNARRAY,
                                             TK_LSTRING, TK_WSTRING, TK_USTRING]) then
    Exit(UInt64(PtrSize));
end;

procedure TVariableExpander.DescribeStorage(var V: TSessionVariable;
  TypeKind: Byte; RawValue: UInt64; ForceReference: Boolean);
begin
  V.DataAddress := PayloadAddress(TypeKind, V.TypeName, RawValue, ForceReference);
  V.ValueSize   := ValueByteSize(TypeKind, V.TypeName, V.Address, V.DataAddress, V.Handle);
end;

function TVariableExpander.GetChildren(Handle: TVarHandle): TArray<TSessionVariable>;
var
  Exp: TSessionExpansion;
begin
  Result := nil;
  if Debugger = nil then
    Exit;
  if not FByHandle.TryGetValue(Handle, Exp) then
    Exit;
  case Exp.Kind of
    exRsmMembers:     Result := ExpandViaMembers(Exp);
    exClassRtti,
    exRecordRtti,
    exDynArrayRtti:   Result := ExpandRttiTyped(Exp);
    exDynArray:       Result := ExpandDynArray(Exp);
    exPropGroup,
    exEventGroup:     Result := ExpandProperties(Exp);
    exPropertyGetter: Result := ExpandPropertyGetter(Exp);
    exVariantArray:   Result := ExpandVariantArray(Exp);
  end;
end;

end.
