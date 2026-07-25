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
