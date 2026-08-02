unit TargetLayout;

// Memory layout of the DEBUGGEE, as opposed to the debugger.
//
// The adapter is a single 64-bit binary that debugs both x64 and WOW64 x86
// targets, so `SizeOf(Pointer)` is the HOST's pointer size and says nothing
// about the address space being read. Every stride, header offset and slot
// width that describes target memory belongs here instead.
//
// This is deliberately a plain DATA record, not an interface:
//
//   * A virtual call per pointer would shatter bulk reads into syscalls. The
//     rule is to read a region ONCE and then decode the local buffer using
//     these numbers -- never to ask the target a question per field.
//   * The values are consulted inside tight decode loops, where a branch on an
//     arch enum is free but an interface dispatch is not.
//
// BEHAVIOUR differences (context/registers, stack walk, prologue decoding,
// call ABI) are the opposite case and belong behind IDebugTarget.
//
// Numbers here were MEASURED against real binaries produced by the Athens 36
// compiler (see DevTools\VmtProbe.dpr and DevTools\PrologProbe.dpr), never
// derived by scaling a 64-bit value. Where a 32-bit value looks like half its
// 64-bit counterpart that is a coincidence of the layout, not the method.
//
// The record grows when a consumer needs a field. Do not add constants here
// speculatively: an unused number that later turns out to be wrong is worse
// than no number at all.

interface

type
  TTargetBitness = (tb32, tb64);

  TTargetLayout = record
  strict private
    FBitness: TTargetBitness;
  public
    // Width of a pointer in the target, in bytes. The single most load-bearing
    // value here: it is the stride for walking any array of pointers in target
    // memory, and the read size for fetching one.
    PointerSize: Byte;

    // Delphi's dynamic-array header sits immediately BELOW the data pointer and
    // is NOT bitness-neutral, unlike the string header:
    //
    //   Win64:  _Padding: LongInt; RefCnt: LongInt; Length: NativeInt (8 bytes)
    //   Win32:                     RefCnt: LongInt; Length: NativeInt (4 bytes)
    //
    // so on Win32 the length sits at data-4 and is 4 bytes wide, while on Win64
    // it sits at data-8 and is 8 wide. Reading a Win32 array with the Win64
    // shape yields a length built from the refcount and whatever precedes it.
    DynArrayLengthOffset:   Integer;  // signed, relative to the data pointer
    DynArrayLengthSize:     Byte;
    DynArrayRefCountOffset: Integer;  // signed, relative to the data pointer

    // Bytes consumed by one `push` of a general-purpose register, used when
    // accounting for a function prologue's saved registers.
    PushSlotSize: Byte;

    // Negative byte offsets of the VMT metadata slots, MEASURED on live VMTs
    // (DevTools\VmtProbe.dpr, by identity predicate) rather than taken from
    // System.pas, whose formula does not describe what the Athens compiler
    // actually emits. Each slot is one pointer wide, so a slot read uses
    // PointerSize, not a fixed 8.
    VmtSelfPtr:    Integer;
    // Slot holding PInterfaceTable. Measured by DevTools\IntfTableProbe against
    // TMyClass.GetInterfaceTable, and worth measuring: on x64 it sits BEFORE
    // SelfPtr (-192 vs -176), the opposite of the documented slot order.
    VmtIntfTable:  Integer;
    VmtTypeInfo:   Integer;
    VmtFieldTable: Integer;
    VmtClassName:  Integer;
    // vmtInstanceSize sits a fixed distance ABOVE vmtTypeInfo in every layout,
    // which is a more reliable derivation than its own standalone constant.
    VmtInstanceSizeFromTypeInfo: Integer;
    // True when the target returns floating-point results on the x87 stack,
    // which the debugger converts to a DOUBLE bit pattern before handing it
    // back. Two consequences a caller must honour:
    //
    //   * A Single result arrives as Double bits, NOT as the raw 4-byte Single
    //     pattern an SSE register would hold, so it has to be converted down.
    //   * Currency travels with the floats here. On Win64 it is a scaled Int64
    //     returned in RAX, and the return-class dispatch has to know which of
    //     the two it is looking at.
    FloatResultsUseX87: Boolean;

    // Where the HIDDEN result pointer sits among a synthetic call's arguments
    // when the function returns through a var-out slot (string, Variant,
    // interface, dynamic array, big record).
    //
    //   Win64: it follows Self  -- RCX = Self, RDX = @Result, args from R8.
    //   Win32: it is the LAST parameter -- EAX = Self, then the declared
    //          arguments, and @Result after them.
    //
    // Measured, not read off a manual: with the slot always placed second,
    // `W.DoCalcUStr()` (no arguments) worked on both -- Self, @Result lands in
    // EAX, EDX either way -- while `W.Greet(Caption)` failed ONLY on Win32,
    // because Self, @Result, Who put @Result in EDX and `Who` in ECX, so the
    // callee wrote its result string through the address of the argument's
    // character data and the call aborted. That is why the defect looked like
    // "string arguments are unsupported" when it was really about the slot.
    HiddenResultParamIsLast: Boolean;

    // Units built with CPP_ABI_SUPPORT shift every negative slot by this much,
    // so two layouts coexist in one image and the reader has to detect which
    // one a given VMT follows. Zero when the target has no such variation --
    // measured as 0 on Win32 and 24 on Win64.
    VmtCppAbiShift: Integer;

    class function For32Bit: TTargetLayout; static;
    class function For64Bit: TTargetLayout; static;
    class function ForBitness(Bitness: TTargetBitness): TTargetLayout; static;

    // Absolute addresses of the dynamic-array header fields, given the array's
    // DATA pointer (the value the variable itself holds). Both the offset and,
    // for the length, the READ WIDTH differ per bitness, so a caller must read
    // DynArrayLengthSize bytes into a zeroed variable rather than assuming 8.
    function DynArrayLengthAddr(DataPtr: UInt64): UInt64;
    function DynArrayRefCountAddr(DataPtr: UInt64): UInt64;

    property Bitness: TTargetBitness read FBitness;
    function Is64Bit: Boolean;
  end;

implementation

class function TTargetLayout.For64Bit: TTargetLayout;
begin
  Result := Default(TTargetLayout);
  Result.FBitness               := tb64;
  Result.PointerSize            := 8;
  Result.DynArrayLengthOffset   := -8;
  Result.DynArrayLengthSize     := 8;
  Result.DynArrayRefCountOffset := -12;
  Result.PushSlotSize           := 8;
  Result.VmtSelfPtr             := -176;
  Result.VmtIntfTable           := -192;
  Result.VmtTypeInfo            := -168;
  Result.VmtFieldTable          := -160;
  Result.VmtClassName           := -112;
  Result.VmtInstanceSizeFromTypeInfo := 40;
  Result.VmtCppAbiShift         := 24;
  Result.FloatResultsUseX87     := False;   // SSE: XMM0 carries the result
  Result.HiddenResultParamIsLast := False;  // it follows Self, in RDX
end;

class function TTargetLayout.For32Bit: TTargetLayout;
begin
  Result := Default(TTargetLayout);
  Result.FBitness               := tb32;
  Result.PointerSize            := 4;
  Result.DynArrayLengthOffset   := -4;
  Result.DynArrayLengthSize     := 4;
  Result.DynArrayRefCountOffset := -8;
  Result.PushSlotSize           := 4;
  Result.VmtSelfPtr             := -88;
  Result.VmtIntfTable           := -84;
  Result.VmtTypeInfo            := -72;
  Result.VmtFieldTable          := -68;
  Result.VmtClassName           := -56;
  // -52 measured, i.e. TypeInfo + 20.
  Result.VmtInstanceSizeFromTypeInfo := 20;
  // CPP_ABI_SUPPORT is defined for WIN64/EXTERNALLINKER only, so on Win32
  // every class uses one layout and there is nothing to detect.
  Result.VmtCppAbiShift         := 0;
  Result.FloatResultsUseX87     := True;
  Result.HiddenResultParamIsLast := True;
end;

class function TTargetLayout.ForBitness(Bitness: TTargetBitness): TTargetLayout;
begin
  if Bitness = tb32 then
    Result := For32Bit
  else
    Result := For64Bit;
end;

function TTargetLayout.DynArrayLengthAddr(DataPtr: UInt64): UInt64;
begin
  {$Q-}{$R-}
  Result := UInt64(Int64(DataPtr) + DynArrayLengthOffset);
  {$Q+}{$R+}
end;

function TTargetLayout.DynArrayRefCountAddr(DataPtr: UInt64): UInt64;
begin
  {$Q-}{$R-}
  Result := UInt64(Int64(DataPtr) + DynArrayRefCountOffset);
  {$Q+}{$R+}
end;

function TTargetLayout.Is64Bit: Boolean;
begin
  Result := FBitness = tb64;
end;

end.
