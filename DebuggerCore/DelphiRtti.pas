unit DelphiRtti;

// Reads Delphi enhanced RTTI from a live Win64 debuggee process.
// All data is fetched via ReadProcessMemory -- no calls into the debuggee.
// Supports class-instance expansion (all visibility, all ancestor levels),
// record field enumeration, and dynamic-array element enumeration.

{$APPTYPE CONSOLE}

interface

uses
  Winapi.Windows, System.SysUtils, System.TypInfo, TargetLayout;

const
  // VMT metadata slot byte offsets for Delphi Athens 36 Win64.
  //
  // Slot positions confirmed by:
  //   (a) reading System.pas's `vmt*` constants for the 64-bit branch,
  //   (b) reading live VMTs from the debuggee (TStuff / Exception / TObject),
  //   (c) cross-referencing TObject.ClassInfo / TObject.ClassName output
  //       against the bytes the adapter reads back.
  //
  // Two layouts coexist in the same EXE:
  //
  //   STANDARD (user-code classes):       vmtSelfPtr at -176
  //   CPP_ABI  (RTL: System.SysUtils, ...): vmtSelfPtr at -200
  //
  // CPP_ABI shift = 3 * SizeOf(Pointer) = 24 bytes; it is the
  // CPP_ABI_ADJUST value System.pas subtracts from EVERY negative VMT
  // offset when the unit is built with `{$DEFINE CPP_ABI_SUPPORT}`.
  // VmtLayoutShift(VmtAddr) detects which layout an instance follows by
  // checking which of the two SelfPtr positions actually points back at
  // the VMT itself.
  //
  // For the metadata slots below the empirically observed offsets work
  // for BOTH layouts (the compiler emits them at the same fixed
  // position regardless of CPP_ABI, even though System.pas's formula
  // would suggest a shifted position for the CPP_ABI case). The lone
  // exception is vmtClassName: that one really does move under
  // CPP_ABI, so GetInstanceClassName's fallback path applies the
  // detected shift there.
  VMT64_SELF_PTR     = -176;   // CPP_ABI: -200 (detected via VmtLayoutShift)
  VMT64_TYPEINFO     = -168;   // same for both layouts in practice
  VMT64_FIELDTABLE   = -160;   // same for both layouts in practice
  VMT64_CLASSNAME    = -112;   // CPP_ABI: -136 (shift applied at read time)
  VMT64_INSTANCESIZE = -104;
  VMT64_PARENT       = -96;

  VMT64_CPPABI_SHIFT      = 24;
  VMT64_SELF_PTR_CPPABI   = VMT64_SELF_PTR     - VMT64_CPPABI_SHIFT;
  VMT64_TYPEINFO_CPPABI   = VMT64_TYPEINFO     - VMT64_CPPABI_SHIFT;
  VMT64_FIELDTABLE_CPPABI = VMT64_FIELDTABLE   - VMT64_CPPABI_SHIFT;
  VMT64_CLASSNAME_CPPABI  = VMT64_CLASSNAME    - VMT64_CPPABI_SHIFT;
  VMT64_INSTANCESIZE_CPPABI = VMT64_INSTANCESIZE - VMT64_CPPABI_SHIFT;
  VMT64_PARENT_CPPABI     = VMT64_PARENT       - VMT64_CPPABI_SHIFT;

  // TTypeKind ordinal values. Tied to the RTL enum so a future Athens
  // release that renumbers TTypeKind (vanishingly unlikely; the kinds
  // are part of the public RTTI surface) propagates here automatically.
  TK_UNKNOWN   = Byte(System.TypInfo.tkUnknown);
  TK_INTEGER   = Byte(System.TypInfo.tkInteger);
  TK_CHAR      = Byte(System.TypInfo.tkChar);
  TK_ENUM      = Byte(System.TypInfo.tkEnumeration);
  TK_FLOAT     = Byte(System.TypInfo.tkFloat);
  TK_STRING    = Byte(System.TypInfo.tkString);
  TK_SET       = Byte(System.TypInfo.tkSet);
  TK_CLASS     = Byte(System.TypInfo.tkClass);
  TK_METHOD    = Byte(System.TypInfo.tkMethod);
  TK_WCHAR     = Byte(System.TypInfo.tkWChar);
  TK_LSTRING   = Byte(System.TypInfo.tkLString);
  TK_WSTRING   = Byte(System.TypInfo.tkWString);
  TK_VARIANT   = Byte(System.TypInfo.tkVariant);
  TK_ARRAY     = Byte(System.TypInfo.tkArray);
  TK_RECORD    = Byte(System.TypInfo.tkRecord);
  TK_INTERFACE = Byte(System.TypInfo.tkInterface);
  TK_INT64     = Byte(System.TypInfo.tkInt64);
  TK_DYNARRAY  = Byte(System.TypInfo.tkDynArray);
  TK_USTRING   = Byte(System.TypInfo.tkUString);
  TK_CLASSREF  = Byte(System.TypInfo.tkClassRef);
  TK_POINTER   = Byte(System.TypInfo.tkPointer);
  TK_PROCEDURE = Byte(System.TypInfo.tkProcedure);
  TK_MRECORD   = Byte(System.tkMRecord);

type
  TRttiFieldInfo = record
    Name:         string;
    TypeKind:     Byte;
    TypeName:     string;
    FieldOffset:  Cardinal;
    FieldAddr:    UInt64;   // base address + FieldOffset
    TypeInfoAddr: UInt64;   // PTypeInfo in debuggee (0 if unavailable)
    IsExpandable: Boolean;
  end;

  // Encoding of a property's GetProc / SetProc accessor pointer (Delphi Win64):
  //   high byte $FF -> field-backed:  low 56 bits = byte offset within the
  //                                   instance.
  //   high byte $FE -> virtual method: low 56 bits = byte offset within the
  //                                   VMT (relative to the class VMT pointer).
  //   other         -> static method:  GetProc IS the function's VA.
  TPropAccessorKind = (akStatic, akVirtual, akField);

  TRttiPropInfo = record
    Name:             string;
    PropTypeInfoAddr: UInt64;  // PTypeInfo of property type (0 if unknown)
    PropTypeKind:     Byte;    // TK_INTEGER, TK_USTRING, ...
    PropTypeName:     string;
    GetKind:          TPropAccessorKind;
    GetValue:         UInt64;  // field offset / vmt offset / static VA
    HasGetter:        Boolean; // False when GetProc was nil
  end;

  TDelphiRtti = class
  private
    FProcess: THandle;
    // Layout of the DEBUGGEE's address space. This class reads through a raw
    // process handle rather than IDebugTarget, so it cannot ask the target and
    // must be told.
    FLayout:  TTargetLayout;

    function ReadU8(Addr: UInt64; out V: Byte): Boolean; inline;
    function ReadU16(Addr: UInt64; out V: Word): Boolean; inline;
    function ReadU32(Addr: UInt64; out V: Cardinal): Boolean; inline;
    // There is deliberately no ReadU64 here. Everything 8 bytes wide in these
    // RTTI records is a POINTER or a NativeInt, both of which are 4 bytes on a
    // 32-bit target -- so a fixed 8-byte read is wrong there, and wrong in the
    // quiet way: it splices the neighbouring field into the high half and
    // desynchronises the rest of the walk. Use ReadTargetPointer.

    // Read a ShortString (1-byte length prefix + ANSI chars).
    // BytesConsumed = 1 + length.
    function ReadShortStr(Addr: UInt64; out S: string; out BytesConsumed: Integer): Boolean;

    // Advance Addr past a ShortString.
    function SkipShortStr(var Addr: UInt64): Boolean;

    // Advance Addr past TAttrData (Len: Word; total = Len bytes from Addr).
    function SkipAttrData(var Addr: UInt64): Boolean;

  public
    function IsValidVmt(VmtAddr: UInt64): Boolean;
    function VmtLayoutShift(VmtAddr: UInt64): Integer;
    function ReadVmtSlot(VmtAddr: UInt64; Offset: Integer; out V: UInt64): Boolean;
    // One TARGET pointer at Addr. Same read as a VMT slot, named for the many
    // places that are walking an RTTI record rather than a VMT.
    function ReadTargetPointer(Addr: UInt64; out V: UInt64): Boolean;
    // Follows TTypeData.ParentInfo to the ancestor class's TypeInfo.
    function TryReadParentTypeInfo(TypeDataAddr: UInt64;
      out ParentTypeInfo: UInt64): Boolean;
  private

    // Read TTypeInfo.Kind and .Name; return address of the following TTypeData.
    function ReadTypeInfoKindName(TypeInfoAddr: UInt64; out Kind: Byte;
      out TypeName: string; out TypeDataAddr: UInt64): Boolean;

    // Append to Fields the enhanced-RTTI fields declared at one VMT level.
    procedure AppendClassLevelFields(VmtAddr: UInt64; ObjBase: UInt64;
      var Fields: TArray<TRttiFieldInfo>);

  public
    // ALayout defaults to the 64-bit shape so existing call sites keep their
    // behaviour; a 32-bit target must pass its own.
    constructor Create(AProcess: THandle); overload;
    constructor Create(AProcess: THandle; const ALayout: TTargetLayout); overload;

    // Element count of a dynamic array, from the header below its data
    // pointer. Bitness-dependent in both offset and width, so it cannot go
    // through ReadU64.
    function ReadDynArrayLength(DataPtr: UInt64; out Len: UInt64): Boolean;

    // True if the value ObjAddr (stored in a class variable) points to what
    // looks like a valid Delphi object (VMT self-pointer check).
    function IsClassInstance(ObjAddr: UInt64): Boolean;
    // True when this object's class, or an ancestor, declares an implemented
    // interface whose hidden field sits exactly Offset bytes in. The exact test
    // for whether an interface reference at Obj+Offset belongs to Obj.
    function DeclaresInterfaceAtOffset(ObjAddr: UInt64; Offset: Cardinal): Boolean;
    // Recovers the object an interface reference points into, and its concrete
    // class. THE single mechanism for this question -- see the implementation
    // for why the alternatives were dropped.
    function TryRecoverObjectFromInterface(IntfPtr: UInt64; out Obj: UInt64;
      out ConcreteClass: string): Boolean;

    // Reads the (un-decorated) class name from the VMT of the instance at
    // ObjAddr. Returns '' on read failure.
    function GetInstanceClassName(ObjAddr: UInt64): string;
    // The declared instance size from the object's runtime VMT (vmtInstanceSize),
    // used to disambiguate two classes that share a bare name in the debug info:
    // their type records have different Size fields. 0 when the VMT is unreadable.
    function GetInstanceSize(ObjAddr: UInt64): Integer;
    // Pascal `instance is TFoo` semantics: True if the object's runtime class
    // is `TargetClassName` OR any descendant. Walks the VMT/TypeInfo parent
    // chain comparing each class name case-insensitively. Returns False if
    // the address isn't a class instance or the chain bottoms out before a
    // match.
    function IsInstanceOf(ObjAddr: UInt64; const TargetClassName: string): Boolean;

    // The instance's class name followed by each ancestor, up to TObject.
    // Needed to CALL an inherited method: its symbol lives under the class that
    // declares it (TDataSet.FieldByName), while the receiver's runtime class is
    // some descendant (TAppDataSet), so a lookup by runtime class name alone
    // finds nothing. Empty when ObjAddr is not a class instance.
    function GetClassChainNames(ObjAddr: UInt64): TArray<string>;

    // Enumerates the published properties of the class at ObjAddr and all
    // ancestor classes. Properties declared at public/private/protected
    // levels are NOT included unless the class is `{$M+}` or descends from
    // TPersistent. Returns empty array on failure.
    function GetClassProperties(ObjAddr: UInt64): TArray<TRttiPropInfo>;

    // Enumerate all fields (all visibility levels, all ancestor classes) of
    // the object at ObjAddr.
    function ExpandClass(ObjAddr: UInt64): TArray<TRttiFieldInfo>;

    // Enumerate fields of a record at RecAddr.  TypeInfoAddr must be known
    // (obtained from a parent field's TypeRef or passed in by the caller).
    function ExpandRecord(RecAddr: UInt64; TypeInfoAddr: UInt64): TArray<TRttiFieldInfo>;

    // Enumerate elements of a Delphi dynamic array.
    // ArrVarAddr is the address of the variable that holds the array pointer
    // (i.e., F.FieldAddr for a dynarray field, not the data pointer itself).
    function ExpandDynArray(ArrVarAddr: UInt64; ElemTypeInfoAddr: UInt64;
      ElemTypeKind: Byte; ElemSize: Cardinal): TArray<TRttiFieldInfo>;

    // For a TK_DYNARRAY TypeInfo, return element size, element TypeInfo address,
    // and element TypeKind.
    function GetDynArrayElemInfo(TypeInfoAddr: UInt64; out ElemSize: Cardinal;
      out ElemTypeInfoAddr: UInt64; out ElemTypeKind: Byte): Boolean;
  end;

function TypeKindIsExpandable(Kind: Byte): Boolean; inline;

implementation

const
  MAX_ANCESTOR_DEPTH = 64;
  MAX_DYNARRAY_ELEMS = 512;

{ -- }

function TypeKindIsExpandable(Kind: Byte): Boolean;
begin
  Result := Kind in [TK_CLASS, TK_RECORD, TK_MRECORD, TK_DYNARRAY];
end;

{ TDelphiRtti }

constructor TDelphiRtti.Create(AProcess: THandle);
begin
  Create(AProcess, TTargetLayout.For64Bit);
end;

constructor TDelphiRtti.Create(AProcess: THandle; const ALayout: TTargetLayout);
begin
  inherited Create;
  FProcess := AProcess;
  FLayout  := ALayout;
end;

function TDelphiRtti.ReadDynArrayLength(DataPtr: UInt64; out Len: UInt64): Boolean;
var
  R: SIZE_T;
begin
  Len := 0;
  var Addr := FLayout.DynArrayLengthAddr(DataPtr);
  Result := (FProcess <> 0) and (Addr > 4096) and
    ReadProcessMemory(FProcess, Pointer(Addr), @Len, FLayout.DynArrayLengthSize, R) and
    (R = FLayout.DynArrayLengthSize);
end;

function TDelphiRtti.ReadU8(Addr: UInt64; out V: Byte): Boolean;
var
  R: SIZE_T;
begin
  Result := (FProcess <> 0) and (Addr > 4096) and
    ReadProcessMemory(FProcess, Pointer(Addr), @V, 1, R) and (R = 1);
end;

function TDelphiRtti.ReadU16(Addr: UInt64; out V: Word): Boolean;
var
  R: SIZE_T;
begin
  Result := (FProcess <> 0) and (Addr > 4096) and
    ReadProcessMemory(FProcess, Pointer(Addr), @V, 2, R) and (R = 2);
end;

function TDelphiRtti.ReadU32(Addr: UInt64; out V: Cardinal): Boolean;
var
  R: SIZE_T;
begin
  Result := (FProcess <> 0) and (Addr > 4096) and
    ReadProcessMemory(FProcess, Pointer(Addr), @V, 4, R) and (R = 4);
end;

function TDelphiRtti.ReadShortStr(Addr: UInt64; out S: string;
  out BytesConsumed: Integer): Boolean;
var
  Len: Byte;
  Buf: TBytes;
  R:   SIZE_T;
begin
  Result := False;
  BytesConsumed := 0;
  if not ReadU8(Addr, Len) then Exit;
  BytesConsumed := 1 + Len;
  if Len = 0 then begin
    S := '';
    Result := True;
    Exit;
  end;
  SetLength(Buf, Len);
  Result := (FProcess <> 0) and
    ReadProcessMemory(FProcess, Pointer(Addr + 1), @Buf[0], Len, R) and (R = Len);
  if Result then
    S := TEncoding.ANSI.GetString(Buf);
end;

function TDelphiRtti.SkipShortStr(var Addr: UInt64): Boolean;
var
  Len: Byte;
begin
  Result := ReadU8(Addr, Len);
  if Result then
    Addr := Addr + 1 + Len;
end;

function TDelphiRtti.SkipAttrData(var Addr: UInt64): Boolean;
var
  Len: Word;
begin
  Result := ReadU16(Addr, Len);
  if Result then begin
    if Len < 2 then Len := 2;
    Addr := Addr + Len;
  end;
end;

// Returns the byte offset to add to every negative VMT slot constant
// when probing this particular VMT. 0 for standard user-class layout,
// -24 for RTL classes built with CPP_ABI_SUPPORT (Exception, TObject, ...).
// Returns -1 when neither layout's vmtSelfPtr matches -- the caller
// should treat the address as not-a-VMT.
// A VMT slot holds one TARGET pointer, so it is 4 bytes wide on a 32-bit
// target. Reading 8 there splices the adjacent slot into the high half and
// yields a plausible-looking address that points nowhere.
function TDelphiRtti.ReadVmtSlot(VmtAddr: UInt64; Offset: Integer; out V: UInt64): Boolean;
var
  R: SIZE_T;
begin
  V := 0;
  var Addr := UInt64(Int64(VmtAddr) + Offset);
  Result := (FProcess <> 0) and (Addr > 4096) and
    ReadProcessMemory(FProcess, Pointer(Addr), @V, FLayout.PointerSize, R) and
    (R = FLayout.PointerSize);
end;

function TDelphiRtti.ReadTargetPointer(Addr: UInt64; out V: UInt64): Boolean;
begin
  Result := ReadVmtSlot(Addr, 0, V);
end;

// TTypeData.tkClass is ClassType(ptr) followed by ParentInfo(ptr), so the parent
// link sits one TARGET pointer in and needs two dereferences: the field is a
// PPTypeInfo. TObject's is nil, which ends the walk.
function TDelphiRtti.TryReadParentTypeInfo(TypeDataAddr: UInt64;
  out ParentTypeInfo: UInt64): Boolean;
begin
  ParentTypeInfo := 0;
  var PPParent: UInt64;
  if not ReadTargetPointer(TypeDataAddr + FLayout.PointerSize, PPParent) then
    Exit(False);
  if PPParent = 0 then
    Exit(False);
  Result := ReadTargetPointer(PPParent, ParentTypeInfo);
end;

function TDelphiRtti.GetInstanceSize(ObjAddr: UInt64): Integer;
var
  VmtAddr, SizeVal: UInt64;
begin
  Result := 0;
  if ObjAddr < 65536 then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  if not IsValidVmt(VmtAddr) then Exit;
  // vmtInstanceSize sits a FIXED +40 above vmtTypeInfo in every Delphi VMT
  // layout (standard: -144/-104; Athens's empirical -168 for TypeInfo puts it at
  // -128). Deriving it from VMT64_TYPEINFO keeps it correct on the same layout
  // GetInstanceClassName already reads TypeInfo from, rather than the standalone
  // VMT64_INSTANCESIZE constant which carries the pre-Athens offset.
  if ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo + FLayout.VmtInstanceSizeFromTypeInfo, SizeVal) and
     (SizeVal > 0) and (SizeVal < $10000000) then
    Result := Integer(SizeVal);
end;

function TDelphiRtti.VmtLayoutShift(VmtAddr: UInt64): Integer;
var
  SelfPtr: UInt64;
begin
  if VmtAddr < 65536 then Exit(MaxInt);
  if ReadVmtSlot(VmtAddr, FLayout.VmtSelfPtr, SelfPtr) and
     (SelfPtr = VmtAddr) then
    Exit(0);
  if ReadVmtSlot(VmtAddr, FLayout.VmtSelfPtr - FLayout.VmtCppAbiShift, SelfPtr) and
     (SelfPtr = VmtAddr) then
    Exit(-FLayout.VmtCppAbiShift);
  Result := MaxInt;
end;

function TDelphiRtti.IsValidVmt(VmtAddr: UInt64): Boolean;
var
  SelfPtr:    UInt64;
begin
  // Athens System.pas computes vmtSelfPtr as `-176 - vmtArcOffset -
  // CPP_ABI_ADJUST`. CPP_ABI_ADJUST is 24 (3 * 8) when the RTL is
  // built with CPP_ABI_SUPPORT for C++Builder compatibility -- which
  // is the case for the bundled System / System.SysUtils units. So
  // RTL classes like `Exception` have vmtSelfPtr at -200, while user
  // code (no CPP_ABI_SUPPORT) keeps it at -176. The adapter must
  // accept either layout to recognise both.
  Result := False;
  if VmtAddr < 65536 then Exit;
  if ReadVmtSlot(VmtAddr, FLayout.VmtSelfPtr, SelfPtr) and
     (SelfPtr = VmtAddr) then
    Exit(True);
  if ReadVmtSlot(VmtAddr, FLayout.VmtSelfPtr - FLayout.VmtCppAbiShift, SelfPtr) and
     (SelfPtr = VmtAddr) then
    Exit(True);
end;

function TDelphiRtti.ReadTypeInfoKindName(TypeInfoAddr: UInt64; out Kind: Byte;
  out TypeName: string; out TypeDataAddr: UInt64): Boolean;
var
  Consumed: Integer;
begin
  Result := False;
  TypeDataAddr := 0;
  TypeName     := '';
  Kind         := TK_UNKNOWN;
  if TypeInfoAddr = 0 then Exit;
  if not ReadU8(TypeInfoAddr, Kind) then Exit;
  if not ReadShortStr(TypeInfoAddr + 1, TypeName, Consumed) then Exit;
  TypeDataAddr := TypeInfoAddr + 1 + UInt64(Consumed);
  Result := True;
end;

procedure TDelphiRtti.AppendClassLevelFields(VmtAddr: UInt64; ObjBase: UInt64;
  var Fields: TArray<TRttiFieldInfo>);
var
  FieldTablePtr, Pos: UInt64;
  ClassicCount, ExCount: Word;
begin
  // VMT slot VMT64_FIELDTABLE contains a pointer to TVmtFieldTable (or 0).
  // No CPP_ABI shift here: the empirically chosen -160 happens to be the
  // correct field-table offset for BOTH user-code and CPP_ABI-shifted RTL
  // classes (-160 corresponds to vmtAutoTable in user code and to
  // vmtFieldTable after the -24 CPP_ABI shift -- and what we read at -160
  // for user code is actually field-table-compatible data in practice).
  if not ReadVmtSlot(VmtAddr, FLayout.VmtFieldTable, FieldTablePtr) then Exit;
  if FieldTablePtr = 0 then Exit;

  // TVmtFieldTable (packed): Count(u16) + ClassTab(POINTER), then Count
  // TVmtFieldEntry records, then ExCount(u16), then ExCount TFieldExEntry.
  //
  // The header is 2 + pointer size, NOT a constant 10: ClassTab is a target
  // pointer, so the header is 10 bytes on x64 and 6 on x86. Hardcoding 10
  // over-read by four bytes on a 32-bit target and shifted the whole walk --
  // field names came out as fragments of unrelated memory, kinds as 0 and
  // offsets as values like -2025889729, which then addressed arbitrary memory.
  var PtrSize := UInt64(FLayout.PointerSize);
  if not ReadU16(FieldTablePtr, ClassicCount) then Exit;
  Pos := FieldTablePtr + 2 + PtrSize;

  // Skip ClassicCount TVmtFieldEntry records.
  // Each (packed): FieldOffset(4) + TypeIndex(2) + Name(ShortString) + AttrData.
  for var I := 0 to Integer(ClassicCount) - 1 do begin
    Pos := Pos + 6;
    if not SkipShortStr(Pos) then Exit;
    if not SkipAttrData(Pos) then Exit;
  end;

  if not ReadU16(Pos, ExCount) then Exit;
  Pos := Pos + 2;

  // Read ExCount TFieldExEntry records. Each (packed), in TARGET pointers:
  //   Flags(1) + TypeRef:PPTypeInfo(ptr) + Offset(4) + Name(ShortString) + AttrData
  // so the fixed part is 5 + ptr bytes, not a constant 13.
  for var I := 0 to Integer(ExCount) - 1 do begin
    var Flags:       Byte;
    var TypeRefPPtr: UInt64;
    var OffsetVal:   Cardinal;
    var FieldName:   string;
    var Consumed:    Integer;

    if not ReadU8(Pos, Flags) then Exit;
    if not ReadTargetPointer(Pos + 1, TypeRefPPtr) then Exit;
    if not ReadU32(Pos + 1 + PtrSize, OffsetVal) then Exit;
    Pos := Pos + 5 + PtrSize;

    if not ReadShortStr(Pos, FieldName, Consumed) then Exit;
    Pos := Pos + UInt64(Consumed);
    if not SkipAttrData(Pos) then Exit;

    // TypeRefPPtr is PPTypeInfo; dereference once to get PTypeInfo.
    var TypeInfoAddr: UInt64 := 0;
    if TypeRefPPtr <> 0 then
      ReadTargetPointer(TypeRefPPtr, TypeInfoAddr);

    var FieldKind:     Byte   := TK_UNKNOWN;
    var FieldTypeName: string := '';
    var TypeDataAddr:  UInt64;
    if TypeInfoAddr <> 0 then
      ReadTypeInfoKindName(TypeInfoAddr, FieldKind, FieldTypeName, TypeDataAddr);

    var FI: TRttiFieldInfo;
    FI.Name         := FieldName;
    FI.TypeKind     := FieldKind;
    FI.TypeName     := FieldTypeName;
    FI.FieldOffset  := OffsetVal;
    FI.FieldAddr    := ObjBase + OffsetVal;
    FI.TypeInfoAddr := TypeInfoAddr;
    FI.IsExpandable := TypeKindIsExpandable(FieldKind);
    SetLength(Fields, Length(Fields) + 1);
    Fields[High(Fields)] := FI;
  end;
end;

function TDelphiRtti.DeclaresInterfaceAtOffset(ObjAddr: UInt64;
  Offset: Cardinal): Boolean;
// True when the object's class (or an ancestor) declares an implemented
// interface whose hidden field sits exactly Offset bytes into the instance.
//
// This is the exact test for "does this interface reference belong to that
// object": Delphi records, per implemented interface, the byte offset of the
// field holding its method-table pointer, so a reference at Obj+Offset is that
// object's if and only if some entry says Offset. No inspection of what the
// memory looks like is involved.
//
// TInterfaceTable, measured by DevTools\IntfTableProbe on both bitnesses:
//   EntryCount : Integer, then padding to pointer alignment
//   entries    : IID(TGUID,16) + VTable(pointer) + IOffset(Integer) + ...
//   stride       40 bytes on x64, 28 on x86
const
  MAX_ENTRIES  = 256;   // a class implementing more than this is not real code
  MAX_ANCESTORS = 32;
begin
  Result := False;
  var VmtAddr: UInt64;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  if not IsValidVmt(VmtAddr) then Exit;

  var PtrSize   := UInt64(FLayout.PointerSize);
  var HeaderLen := PtrSize;                       // Integer count, then aligned
  var Stride    := 16 + PtrSize + 4;              // IID + VTable + IOffset
  if (Stride mod PtrSize) <> 0 then               // ... then ImplGetter, aligned
    Stride := Stride + (PtrSize - (Stride mod PtrSize));
  Stride := Stride + PtrSize;
  var IOffsetAt := 16 + PtrSize;

  // An interface can be introduced by an ancestor, so every class in the chain
  // is consulted. The chain is walked through TypeInfo, the same way
  // ExpandClass collects ancestor VMTs -- there is no measured vmtParent
  // constant, and inventing one is exactly what this codebase avoids.
  var Vmts: TArray<UInt64> := [VmtAddr];
  var TypeInfoAddr: UInt64;
  if ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo, TypeInfoAddr) and (TypeInfoAddr <> 0) then begin
    var CurTypeInfo := TypeInfoAddr;
    for var Depth := 1 to MAX_ANCESTORS do begin
      if CurTypeInfo = 0 then Break;
      var Kind: Byte;
      var TypeName: string;
      var TypeDataAddr: UInt64;
      if not ReadTypeInfoKindName(CurTypeInfo, Kind, TypeName, TypeDataAddr) then Break;
      if Kind <> TK_CLASS then Break;
      var AncVmt: UInt64;
      if ReadTargetPointer(TypeDataAddr, AncVmt) and (AncVmt <> 0) then
        Vmts := Vmts + [AncVmt];
      var PParent: UInt64;
      if not TryReadParentTypeInfo(TypeDataAddr, PParent) then Break;
      CurTypeInfo := PParent;
    end;
  end;

  for var Vmt in Vmts do begin
    var TablePtr: UInt64;
    if not ReadVmtSlot(Vmt, FLayout.VmtIntfTable, TablePtr) then Continue;
    if TablePtr < 65536 then Continue;
    var Count: Cardinal;
    if not ReadU32(TablePtr, Count) then Continue;
    if (Count = 0) or (Count > MAX_ENTRIES) then Continue;
    for var I := 0 to Integer(Count) - 1 do begin
      var EntryAt := TablePtr + HeaderLen + UInt64(I) * Stride;
      var Candidate: Cardinal;
      if ReadU32(EntryAt + IOffsetAt, Candidate) and (Candidate = Offset) then
        Exit(True);
    end;
  end;
end;

function TDelphiRtti.TryRecoverObjectFromInterface(IntfPtr: UInt64;
  out Obj: UInt64; out ConcreteClass: string): Boolean;
// An interface reference addresses a hidden field INSIDE the implementing
// object, so it is not itself a class instance. Walk back a pointer at a time
// and accept a candidate only when its class declares an implemented interface
// at exactly this offset -- an exact structural match, from the class's own
// interface table.
//
// This replaces two earlier mechanisms:
//   * decoding the IMT adjustor thunk's machine code (`add rcx, imm`), which
//     only ever matched x64 encodings, so a 32-bit target never resolved the
//     concrete class at all;
//   * accepting any candidate with a valid VMT whose instance size merely
//     reached the pointer, which is a far weaker claim than the class saying
//     an interface lives there.
// One mechanism, no instruction decoding, same answer on both bitnesses.
const
  // Backstop only. The real bound is the allocation, below.
  MAX_SEARCH_BYTES = 4096;
begin
  Obj           := 0;
  ConcreteClass := '';
  Result        := False;
  if IntfPtr < 65536 then Exit;

  // Bound the walk by the ALLOCATION the reference points into. An object never
  // spans two allocations, so anything below that base cannot be the object --
  // and walking on regardless is not merely wasted work: with a fixed 4096-byte
  // window the search ran off the end of the heap block and into a loaded
  // module's data, where a stretch of bytes passed the VMT identity check and
  // the RTTI readers then raised EIntOverflow on it (measured: offset 4048,
  // candidate $7FFF154D8A60). The allocation base is a fact from the OS, which
  // a byte count never was.
  var LowestCandidate: UInt64 := 0;
  if FProcess <> 0 then begin
    var Mbi: TMemoryBasicInformation;
    if VirtualQueryEx(FProcess, Pointer(IntfPtr), Mbi, SizeOf(Mbi)) = SizeOf(Mbi) then
      LowestCandidate := UInt64(Mbi.AllocationBase);
  end;

  var Step := UInt64(FLayout.PointerSize);
  var Offset: UInt64 := 0;
  while Offset <= MAX_SEARCH_BYTES do begin
    var Candidate := IntfPtr - Offset;
    if (LowestCandidate <> 0) and (Candidate < LowestCandidate) then
      Break;
    if IsClassInstance(Candidate) then begin
      var InstSize := GetInstanceSize(Candidate);
      if (InstSize > 0) and (Offset + Step <= UInt64(InstSize)) and
         DeclaresInterfaceAtOffset(Candidate, Cardinal(Offset)) then begin
        ConcreteClass := GetInstanceClassName(Candidate);
        if ConcreteClass <> '' then begin
          Obj := Candidate;
          Exit(True);
        end;
      end;
    end;
    Inc(Offset, Step);
  end;
end;

function TDelphiRtti.IsClassInstance(ObjAddr: UInt64): Boolean;
var
  VmtAddr: UInt64;
begin
  Result := False;
  if ObjAddr < 65536 then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  Result := IsValidVmt(VmtAddr);
end;

function TDelphiRtti.GetClassProperties(ObjAddr: UInt64): TArray<TRttiPropInfo>;
const
  MAX_PARENT_DEPTH = 32;

  function ReadRaw(Addr: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
  var
    Bytes: SIZE_T;
  begin
    Result := ReadProcessMemory(FProcess, Pointer(Addr), Buf, Size, Bytes) and (Bytes = Size);
  end;

  procedure ReadOneClass(TypeInfoAddr: UInt64);
  var
    Kind:         Byte;
    TypeName:     string;
    TypeDataAddr: UInt64;
    Cursor:       UInt64;
    ClassType:    UInt64;
    ParentInfo:   UInt64;
    PropCount:    Word;
    Bytes:        Integer;
    PropTIPP:     UInt64;
    PropTI:       UInt64;
    GetProc:      UInt64;
    SetProc:      UInt64;
    StoredProc:   UInt64;
    IndexVal:     Cardinal;
    DefaultVal:   Cardinal;
    NameIdx:      Word;
    PropName:     string;
  begin
    if TypeInfoAddr = 0 then Exit;
    if not ReadTypeInfoKindName(TypeInfoAddr, Kind, TypeName, TypeDataAddr) then Exit;
    if Kind <> TK_CLASS then Exit;

    // EVERY pointer in these RTTI records is a TARGET pointer, so all the
    // offsets below are expressed in PtrSize rather than a literal 8. The
    // 64-bit-only version of this walk desynchronised on the very first record
    // of a 32-bit target -- 18 bytes consumed where the record is 10 -- so no
    // property ever matched by name and the whole live-RTTI property surface
    // silently degraded to the debug-info fallback.
    var PtrSize := UInt64(FLayout.PointerSize);

    // TTypeData.tkClass layout: ClassType(ptr) ParentInfo(ptr) PropCount(2)
    //                           UnitName(ShortString) TPropData
    Cursor := TypeDataAddr;
    if not ReadTargetPointer(Cursor, ClassType)  then Exit;
    Inc(Cursor, PtrSize);
    if not ReadTargetPointer(Cursor, ParentInfo) then Exit;
    Inc(Cursor, PtrSize);
    // Skip the SmallInt PropCount field on TTypeData (we'll use TPropData.PropCount).
    Inc(Cursor, 2);
    if not SkipShortStr(Cursor) then Exit;  // UnitName
    // TPropData: Word PropCount, then PropList.
    if not ReadRaw(Cursor, @PropCount, 2) then Exit;
    Inc(Cursor, 2);
    for var I := 0 to Integer(PropCount) - 1 do begin
      // TPropInfo (packed):
      //   PropType:   PPTypeInfo   (ptr)  pointer-to-pointer-to-TypeInfo
      //   GetProc:    Pointer      (ptr)
      //   SetProc:    Pointer      (ptr)
      //   StoredProc: Pointer      (ptr)
      //   Index:      Integer      (4)
      //   Default:    Integer      (4)
      //   NameIndex:  Word         (2)
      //   Name:       ShortString  (1 + len)
      var FixedEnd := Cursor + 4 * PtrSize;
      if not ReadTargetPointer(Cursor,               PropTIPP)   then Exit;
      if not ReadTargetPointer(Cursor + PtrSize,     GetProc)    then Exit;
      if not ReadTargetPointer(Cursor + 2 * PtrSize, SetProc)    then Exit;
      if not ReadTargetPointer(Cursor + 3 * PtrSize, StoredProc) then Exit;
      if not ReadU32(FixedEnd,     IndexVal)   then Exit;
      if not ReadU32(FixedEnd + 4, DefaultVal) then Exit;
      if not ReadRaw(FixedEnd + 8, @NameIdx, 2) then Exit;
      var NameAddr := FixedEnd + 10;
      if not ReadShortStr(NameAddr, PropName, Bytes) then Exit;
      var AfterName: UInt64 := NameAddr + UInt64(Bytes);
      // No AttrData in the basic TPropInfo published layout -- the record
      // ends right after the Name ShortString. System.TypInfo walks the
      // list by adding 1 + Length(Name) to the Name address.
      var Info: TRttiPropInfo;
      Info := Default(TRttiPropInfo);
      Info.Name := PropName;
      PropTI := 0;
      if PropTIPP <> 0 then
        ReadTargetPointer(PropTIPP, PropTI);
      Info.PropTypeInfoAddr := PropTI;
      if PropTI <> 0 then begin
        var TDAignored: UInt64;
        ReadTypeInfoKindName(PropTI, Info.PropTypeKind, Info.PropTypeName, TDAignored);
      end;
      Info.HasGetter := GetProc <> 0;
      if Info.HasGetter then begin
        // The accessor kind is encoded in the TOP BYTE of the pointer, so the
        // shift follows the target's pointer width: System.TypInfo's
        // PROPSLOT_MASK is $FF000000 at 32-bit and $FF00000000000000 at 64-bit.
        var TagShift  := 8 * PtrSize - 8;
        var AddrMask  := (UInt64(1) shl TagShift) - 1;
        case (GetProc shr TagShift) and $FF of
          $FF: begin Info.GetKind := akField;   Info.GetValue := GetProc and AddrMask; end;
          $FE: begin Info.GetKind := akVirtual; Info.GetValue := GetProc and AddrMask; end;
        else
          Info.GetKind  := akStatic;
          Info.GetValue := GetProc;
        end;
      end;
      Result := Result + [Info];
      Cursor := AfterName;
    end;

  end;

var
  VmtAddr, TypeInfoAddr: UInt64;
begin
  SetLength(Result, 0);
  if not IsClassInstance(ObjAddr) then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  if not ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo, TypeInfoAddr) then Exit;

  // Walk: this class' TypeInfo, then ParentInfo, etc.
  var CurTI := TypeInfoAddr;
  for var Depth := 0 to MAX_PARENT_DEPTH - 1 do begin
    if CurTI = 0 then Break;
    ReadOneClass(CurTI);

    // Advance to parent: TTypeData.ParentInfo is a PPTypeInfo sitting one
    // TARGET pointer past ClassType, so both the offset and the read width
    // follow the target's bitness.
    var Kind: Byte;
    var TN: string;
    var TDA: UInt64;
    if not ReadTypeInfoKindName(CurTI, Kind, TN, TDA) then Break;
    if Kind <> TK_CLASS then Break;
    var ParentPP: UInt64;
    if not ReadTargetPointer(TDA + FLayout.PointerSize, ParentPP) then Break;
    if ParentPP = 0 then Break;
    var ParentTI: UInt64;
    if not ReadTargetPointer(ParentPP, ParentTI) then Break;
    CurTI := ParentTI;
  end;
end;

function TDelphiRtti.GetInstanceClassName(ObjAddr: UInt64): string;
var
  VmtAddr, TypeInfoAddr, TypeDataAddr, NamePtr: UInt64;
  Kind: Byte;
  Shift: Integer;
begin
  Result := '';
  if ObjAddr < 65536 then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  Shift := VmtLayoutShift(VmtAddr);
  if Shift = MaxInt then Exit;
  // Primary: TTypeInfo Name ShortString.
  // (No CPP_ABI shift here -- the empirical -168 offset hits Exception's
  // vmtTypeInfo too, see comment on VMT64_TYPEINFO above.)
  if ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo, TypeInfoAddr) and
     (TypeInfoAddr <> 0) and
     ReadTypeInfoKindName(TypeInfoAddr, Kind, Result, TypeDataAddr) and
     (Result <> '') then
    Exit;
  // Fallback: vmtClassName slot (PShortString).
  if not ReadVmtSlot(VmtAddr, FLayout.VmtClassName + Shift, NamePtr) then Exit;
  if NamePtr < 65536 then Exit;
  var Consumed: Integer;
  ReadShortStr(NamePtr, Result, Consumed);
end;

function TDelphiRtti.IsInstanceOf(ObjAddr: UInt64;
  const TargetClassName: string): Boolean;
const
  MAX_DEPTH = 32;
var
  VmtAddr, TypeInfoAddr, TypeDataAddr, PParent: UInt64;
  Kind: Byte;
  TypeName: string;
begin
  Result := False;
  if not IsClassInstance(ObjAddr) then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  if not ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo, TypeInfoAddr) then Exit;
  // `TObject` matches anything that's a valid class instance -- there's no
  // explicit TypeInfo entry to compare against in some cases.
  if SameText(TargetClassName, 'TObject') then Exit(True);
  var Depth := 0;
  while (TypeInfoAddr <> 0) and (Depth < MAX_DEPTH) do begin
    Inc(Depth);
    if not ReadTypeInfoKindName(TypeInfoAddr, Kind, TypeName, TypeDataAddr) then Exit;
    if Kind <> TK_CLASS then Exit;
    if SameText(TypeName, TargetClassName) then Exit(True);
    if not TryReadParentTypeInfo(TypeDataAddr, PParent) then Exit;
    TypeInfoAddr := PParent;
  end;
end;

function TDelphiRtti.GetClassChainNames(ObjAddr: UInt64): TArray<string>;
const
  MAX_DEPTH = 32;
var
  VmtAddr, TypeInfoAddr, TypeDataAddr, PParent: UInt64;
  Kind: Byte;
  TypeName: string;
begin
  SetLength(Result, 0);
  if not IsClassInstance(ObjAddr) then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  if not ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo, TypeInfoAddr) then Exit;

  var Depth := 0;
  while (TypeInfoAddr <> 0) and (Depth < MAX_DEPTH) do begin
    Inc(Depth);
    if not ReadTypeInfoKindName(TypeInfoAddr, Kind, TypeName, TypeDataAddr) then Exit;
    if Kind <> TK_CLASS then Exit;
    if TypeName <> '' then begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := TypeName;
    end;
    if not TryReadParentTypeInfo(TypeDataAddr, PParent) then Exit;
    TypeInfoAddr := PParent;
  end;
end;

function TDelphiRtti.ExpandClass(ObjAddr: UInt64): TArray<TRttiFieldInfo>;
var
  VmtAddr, TypeInfoAddr: UInt64;
begin
  SetLength(Result, 0);
  if ObjAddr = 0 then Exit;
  if not ReadVmtSlot(ObjAddr, 0, VmtAddr) then Exit;
  if not IsValidVmt(VmtAddr) then Exit;

  // Read TypeInfo from VMT slot VMT64_TYPEINFO.  If absent, show only current-class fields.
  if not ReadVmtSlot(VmtAddr, FLayout.VmtTypeInfo, TypeInfoAddr) then begin
    AppendClassLevelFields(VmtAddr, ObjAddr, Result);
    Exit;
  end;
  if TypeInfoAddr = 0 then begin
    AppendClassLevelFields(VmtAddr, ObjAddr, Result);
    Exit;
  end;

  // Walk the TypeInfo parent chain to collect ancestor VMTs.
  // TTypeData.tkClass layout (packed), in TARGET pointers:
  //   +0:   ClassType (TClass = VMT address)
  //   +ptr: ParentInfo (PPTypeInfo) -- dereference to get parent PTypeInfo
  var AncestorVMTs: TArray<UInt64>;
  var CurTypeInfo := TypeInfoAddr;
  var Depth := 0;
  while (CurTypeInfo <> 0) and (Depth < MAX_ANCESTOR_DEPTH) do begin
    Inc(Depth);
    var Kind:        Byte;
    var TypeName:    string;
    var TypeDataAddr: UInt64;
    if not ReadTypeInfoKindName(CurTypeInfo, Kind, TypeName, TypeDataAddr) then Break;
    if Kind <> TK_CLASS then Break;

    var AncVmt: UInt64;
    if not ReadTargetPointer(TypeDataAddr, AncVmt) then Break;
    SetLength(AncestorVMTs, Length(AncestorVMTs) + 1);
    AncestorVMTs[High(AncestorVMTs)] := AncVmt;

    var PParent: UInt64;
    if not TryReadParentTypeInfo(TypeDataAddr, PParent) then Break;
    CurTypeInfo := PParent;
  end;

  // Walk from base class downward so fields appear in declaration order.
  for var I := High(AncestorVMTs) downto 0 do
    AppendClassLevelFields(AncestorVMTs[I], ObjAddr, Result);
end;

function TDelphiRtti.ExpandRecord(RecAddr: UInt64; TypeInfoAddr: UInt64): TArray<TRttiFieldInfo>;
var
  Kind:        Byte;
  TypeName:    string;
  TypeDataAddr: UInt64;
begin
  SetLength(Result, 0);
  if TypeInfoAddr = 0 then Exit;
  if not ReadTypeInfoKindName(TypeInfoAddr, Kind, TypeName, TypeDataAddr) then Exit;
  if (Kind <> TK_RECORD) and (Kind <> TK_MRECORD) then Exit;

  // TTypeData.tkRecord (packed, Win64):
  //   +0:  RecSize (Integer, 4 bytes)
  //   +4:  ManagedFldCount (Integer, 4 bytes)
  // Then: ManagedFldCount * TManagedField, each = TypeRef:PPTypeInfo(8) + FldOffset:NativeInt(8) = 16 bytes
  // Then: NumOps (Byte, 1 byte)
  // Then: NumOps * Pointer (8 bytes each)
  // Then: RecFldCnt (Integer, 4 bytes)
  // Then: RecFldCnt * TRecordTypeField records (variable length)
  // TRecordTypeField (packed): Field:TManagedField(16) + Flags:Byte(1) + Name:ShortString + AttrData
  //   i.e. TypeRef(8) + FldOffset:NativeInt(8) + Flags(1) + NameLen(1) + NameChars + AttrData
  var Pos: UInt64 := TypeDataAddr;

  var ManagedFldCount: Cardinal;
  if not ReadU32(Pos + 4, ManagedFldCount) then Exit;
  Pos := Pos + 8 + ManagedFldCount * 16;  // TManagedField = TypeRef(8) + NativeInt(8) = 16 bytes

  var NumOps: Byte;
  if not ReadU8(Pos, NumOps) then Exit;
  Pos := Pos + 1 + NumOps * 8;

  var RecFldCnt: Cardinal;
  if not ReadU32(Pos, RecFldCnt) then Exit;
  Pos := Pos + 4;

  // TRecordTypeField (packed), in TARGET pointers -- both members of
  // TManagedField are pointer-width, so the fixed part is 2*ptr + 1:
  //   TManagedField: TypeInfo:PPTypeInfo(ptr) + FldOffset:NativeInt(ptr)
  //   Flags: Byte(1)
  //   Name: ShortString (variable)
  //   {AttrData: TAttrData} (variable)
  var PtrSize := UInt64(FLayout.PointerSize);
  for var I := 0 to Integer(RecFldCnt) - 1 do begin
    var TypeRefPPtr:  UInt64;
    var FldOffset:    Cardinal;
    var FieldFlags:   Byte;
    var FieldName:    string;
    var Consumed:     Integer;

    if not ReadTargetPointer(Pos, TypeRefPPtr) then Exit;
    var FldOffsetNI: UInt64;
    if not ReadTargetPointer(Pos + PtrSize, FldOffsetNI) then Exit;  // NativeInt
    FldOffset := Cardinal(FldOffsetNI);
    if not ReadU8(Pos + 2 * PtrSize, FieldFlags) then Exit;
    Pos := Pos + 2 * PtrSize + 1;

    if not ReadShortStr(Pos, FieldName, Consumed) then Exit;
    Pos := Pos + UInt64(Consumed);
    if not SkipAttrData(Pos) then Exit;

    // TManagedField.TypeInfo is PPTypeInfo; dereference once.
    var FieldTypeInfoAddr: UInt64 := 0;
    if TypeRefPPtr <> 0 then
      ReadTargetPointer(TypeRefPPtr, FieldTypeInfoAddr);

    var FieldKind:     Byte   := TK_UNKNOWN;
    var FieldTypeName: string := '';
    var Dummy:         UInt64;
    if FieldTypeInfoAddr <> 0 then
      ReadTypeInfoKindName(FieldTypeInfoAddr, FieldKind, FieldTypeName, Dummy);

    var FI: TRttiFieldInfo;
    FI.Name         := FieldName;
    FI.TypeKind     := FieldKind;
    FI.TypeName     := FieldTypeName;
    FI.FieldOffset  := FldOffset;
    FI.FieldAddr    := RecAddr + FldOffset;
    FI.TypeInfoAddr := FieldTypeInfoAddr;
    FI.IsExpandable := TypeKindIsExpandable(FieldKind);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := FI;
  end;
end;

function TDelphiRtti.GetDynArrayElemInfo(TypeInfoAddr: UInt64; out ElemSize: Cardinal;
  out ElemTypeInfoAddr: UInt64; out ElemTypeKind: Byte): Boolean;
var
  Kind:        Byte;
  TypeName:    string;
  TypeDataAddr: UInt64;
begin
  Result := False;
  ElemSize         := 0;
  ElemTypeInfoAddr := 0;
  ElemTypeKind     := TK_UNKNOWN;
  if not ReadTypeInfoKindName(TypeInfoAddr, Kind, TypeName, TypeDataAddr) then Exit;
  if Kind <> TK_DYNARRAY then Exit;

  // TTypeData.tkDynArray (packed), in TARGET pointers:
  //   +0:       elSize (Integer, 4 bytes)
  //   +4:       elType (PPTypeInfo) -- nil if the element needs no managed cleanup
  //   +4+ptr:   varType (Integer, 4 bytes)
  //   +8+ptr:   elType2 (PPTypeInfo) -- always present; the actual element type
  var PtrSize := UInt64(FLayout.PointerSize);
  var ElSz: Cardinal;
  if not ReadU32(TypeDataAddr, ElSz) then Exit;
  ElemSize := ElSz;

  // Prefer elType2 (always valid); fall back to elType.
  var ElTypePPtr: UInt64;
  if not ReadTargetPointer(TypeDataAddr + 8 + PtrSize, ElTypePPtr) or (ElTypePPtr = 0) then
    if not ReadTargetPointer(TypeDataAddr + 4, ElTypePPtr) then Exit;
  if ElTypePPtr = 0 then Exit;

  var ElTypePtr: UInt64;
  if not ReadTargetPointer(ElTypePPtr, ElTypePtr) then Exit;
  ElemTypeInfoAddr := ElTypePtr;

  var ElemTypeData: UInt64;
  ReadTypeInfoKindName(ElemTypeInfoAddr, ElemTypeKind, TypeName, ElemTypeData);
  Result := True;
end;

function TDelphiRtti.ExpandDynArray(ArrVarAddr: UInt64; ElemTypeInfoAddr: UInt64;
  ElemTypeKind: Byte; ElemSize: Cardinal): TArray<TRttiFieldInfo>;
var
  ArrPtr, LenVal: UInt64;
  ElemCount:      Integer;
  ElemTypeName:   string;
begin
  SetLength(Result, 0);
  if (ArrVarAddr = 0) or (ElemSize = 0) then Exit;
  // ArrVarAddr holds the dynamic-array pointer (the variable slot), one TARGET
  // pointer wide -- reading 8 on a 32-bit target splices in the next slot.
  if not ReadTargetPointer(ArrVarAddr, ArrPtr) then Exit;
  if ArrPtr = 0 then Exit;

  // Delphi dynarray layout in process: ArrPtr[-8] = element count (NativeInt).
  if not ReadDynArrayLength(ArrPtr, LenVal) then Exit;
  ElemCount := Integer(LenVal);
  if ElemCount <= 0 then Exit;
  if ElemCount > MAX_DYNARRAY_ELEMS then ElemCount := MAX_DYNARRAY_ELEMS;

  // Read element type name for display.
  ElemTypeName := '';
  if ElemTypeInfoAddr <> 0 then begin
    var DummyKind: Byte;
    var DummyData: UInt64;
    ReadTypeInfoKindName(ElemTypeInfoAddr, DummyKind, ElemTypeName, DummyData);
  end;

  SetLength(Result, ElemCount);
  for var I := 0 to ElemCount - 1 do begin
    var ElemAddr := ArrPtr + UInt64(I) * ElemSize;
    Result[I].Name         := Format('[%d]', [I]);
    Result[I].TypeKind     := ElemTypeKind;
    Result[I].TypeName     := ElemTypeName;
    Result[I].FieldOffset  := Cardinal(I) * ElemSize;
    Result[I].FieldAddr    := ElemAddr;
    Result[I].TypeInfoAddr := ElemTypeInfoAddr;
    Result[I].IsExpandable := TypeKindIsExpandable(ElemTypeKind);
  end;
end;

end.
