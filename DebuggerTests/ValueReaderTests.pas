unit ValueReaderTests;

// Pure unit tests for TDelphiValueReader.FormatLocalValue that need no live
// debuggee: the integer-formatting path only touches the raw value + the type
// tables, so an empty TDebugInfoSet (no providers) exercises the "unknown type"
// fallback deterministically.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TValueReaderTests = class
  public
    // F4 regression: a member field typed as an ordinal SUBRANGE of unknown size
    // (e.g. TBorderWidth = 0..MaxInt) is read as 8 bytes, so the high dword holds
    // the ADJACENT field's bytes. The formatter must mask it down to its storage
    // width instead of printing the corrupted 64-bit value.
    // Locals that share a frame address are fabricated: two distinct stack
    // locals cannot occupy one address, and in the field 22 of them rendered
    // the saved frame pointer as their value with plausible names and types.
    [Test] procedure CollidingLocals_AreDropped_UniqueAndRegisterOnesKept;
    // A generic class ancestor may be refined by a DESCENDANT CLASS and by
    // nothing else. Letting "any non-suspect type" win turned a constructor's
    // `AOwner: TComponent` into `ByteBool` on a real 797 MB binary.
    [Test] procedure ClassAncestorHint_IsNotOverriddenByANonClass;
    [Test] procedure UnknownOrdinalSubrange_MasksHighDword;
    // Guard: a genuine 64-bit type (matched by name) must still show all 8 bytes.
    [Test] procedure Int64ByName_KeepsAllEightBytes;
    // Wrong-data audit (2026-07-19): the Variant auto-detect must NOT accept a
    // plain integer whose value is 20/21 (= varInt64/varUInt64 VType) as a
    // Variant -- doing so read the NEIGHBOURING slot as the payload. varInt64 /
    // varUInt64 must fall through to False, like varSmallint / varInteger.
    [Test] procedure VariantAutoDetect_Int64Pattern_Rejected;
    [Test] procedure VariantAutoDetect_UInt64Pattern_Rejected;
    // Guard: a genuine varDouble TVarData must still auto-detect as a Variant
    // (the fix must not break real Variant recovery).
    [Test] procedure VariantAutoDetect_DoublePattern_Accepted;
    // Wrong-data audit (2026-07-19): an AnsiString must decode with the code page
    // in its OWN header (TStrRec.codePage at Ptr-12), not the machine's system
    // ANSI page -- otherwise a UTF8String renders as mojibake.
    [Test] procedure AnsiString_Utf8CodePage_DecodesAsUtf8;
    [Test] procedure AnsiString_DefaultCodePage_StillAnsi;
    // Wrong-data audit (2026-07-19): enum display must use the enum's REAL
    // storage width -- a fixed 4-byte ordinal mask folded the adjacent local in,
    // and a fixed $FF member mask aliased ordinals 256..511 to a wrong member.
    [Test] procedure Enum_UninitialisedOrdinal_MasksToStorageWidth;
    [Test] procedure Enum_OrdinalAbove255_ResolvesCorrectMember;
    // Win32 target support: unlike the string header, Delphi's dynamic-array
    // header is NOT bitness-neutral. Win64 is _Padding(4) RefCnt(4)
    // Length:NativeInt(8), so the length sits at data-8 and is 8 bytes wide;
    // Win32 is RefCnt(4) Length(4), so it sits at data-4 and is 4 wide.
    // Decoding one with the other's shape does not fail, it returns a plausible
    // wrong number -- which is why the negative case below is part of the suite.
    [Test] procedure DynArrayHeader_Win32Layout_DecodesLength;
    [Test] procedure DynArrayHeader_Win64Layout_DecodesLength;
    [Test] procedure DynArrayHeader_Win32ImageReadAsWin64_IsWrong;
  end;

  // The debug-info provider interfaces are looked up by GUID with `Supports`,
  // which does not care whether two of them share one. Duplicating a GUID hands
  // out the WRONG vtable, so a call lands on whichever method occupies that slot
  // and arguments are reinterpreted as its own -- a corruption with no exception
  // at the call site. It has happened once: ISourceFileListProvider shipped with
  // IThreadLocalNameProvider's GUID and thirteen tests died writing an array
  // result through a Boolean's address.
  [TestFixture]
  TProviderInterfaceTests = class
  public
    [Test] procedure ProviderInterfaceGuids_AreUnique;
  end;

  // Pure unit tests for the setVariable byte encoders.
  [TestFixture]
  TValueEncoderTests = class
  public
    // Wrong-data audit (2026-07-19): a set is BYTE-granular. `set of (c0..c19)`
    // is exactly 3 bytes; the encoder rounded it to 4 and the write then zeroed
    // the first byte of the physically ADJACENT variable.
    [Test] procedure SetOfTwentyMembers_EncodesExactThreeBytes;
    [Test] procedure SetOfTwentyMembers_NoProviderSize_StillThreeBytes;
    // Guard: enum widths (1/2/4) must be unchanged by the set fix.
    [Test] procedure SmallEnum_StillEncodesOneByte;
  end;

implementation

uses
  System.SysUtils, System.TypInfo, Winapi.Windows,
  DebugInfoTypes, DebugTarget, DebugInfoSet, DelphiValueReaders, ExceptionRules,
  ValueEncoders, TargetLayout, WinDebuggerBase;

type
  // Minimal IDebugTarget fake: only ReadProcessMemoryAt is live, serving a fixed
  // byte window at a fixed base VA. Everything else is a benign default. Lets the
  // memory-pattern heuristics (Variant / dyn-array auto-detect) be unit-tested
  // deterministically with no live debuggee.
  TFakeMemTarget = class(TInterfacedObject, IDebugTarget)
  private
    FBase: UInt64;
    FMem:  TBytes;
    FLayout: TTargetLayout;
    FEnumName: string;
    FEnumInfo: TRsmEnumInfo;
    FOnStopped: TOnStopped; FOnExited: TOnExited; FOnOutput: TOnOutput;
    FOnDllLoaded: TOnDllLoaded; FOnDllUnloaded: TOnDllUnloaded; FOnBpHit: TOnBpHit;
  public
    constructor Create(BaseVA: UInt64; const Bytes: TBytes);
    // Serve one enum type through IDebugTarget.LookupEnumInfo (the enum-name
    // display path queries the DEBUGGER, not the debug-info set).
    procedure SetEnum(const AName: string; const AInfo: TRsmEnumInfo);
    // Defaults to the 64-bit layout. Settable so a decode path that depends on
    // the TARGET's pointer size (dynamic-array headers, pointer strides) can be
    // exercised for both bitnesses against a fixed byte window, with no live
    // debuggee and no 32-bit build required.
    procedure SetLayout(const ALayout: TTargetLayout);
    function  TargetLayout: TTargetLayout;
    function  ReadProcessMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    // --- everything below is an inert stub ---
    function  ProcessHandle: THandle;
    function  ImageBase: UInt64;
    function  HasExited: Boolean;
    function  LastExceptionDesc: string;
    function  LastExceptionClass: string;
    function  LastExceptionMessage: string;
    function  CurrentExceptionObject: UInt64;
    function  WriteMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
    function  RvaToVA(Rva: UInt64): UInt64;
    function  GetThreadIds: TArray<DWORD>;
    function  GetThreadName(TID: DWORD): string;
    function  GetStoppedThreadId: DWORD;
    function  GetRegisters: TRegisterSnapshot;
    function  GetStackFrames: TArray<TStackFrame>; overload;
    function  GetStackFrames(TID: DWORD): TArray<TStackFrame>; overload;
    function  GetRawStackFrames(TID: DWORD; MaxItems: Integer = 0): TArray<TStackFrame>;
    function  ResymbolicateFrames(const Frames: TArray<TStackFrame>): TArray<TStackFrame>;
    function  CurrentScopeClassName: string;
    function  LastSyntheticCallError: string;
    function  GetLocalValues: TArray<TLocalValue>;
    procedure SetActiveFrame(FrameRBP, FuncEntryVA: UInt64; const FuncName: string; FramePC: UInt64 = 0);
    procedure ClearActiveFrame;
    function  CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64;
    function  EvaluateName(const Name: string; out Value: TLocalValue): Boolean;
    function  EvaluateLocalName(const Name: string; out Value: TLocalValue): Boolean;
    function  EvaluateGlobalName(const Name: string; out Value: TLocalValue): Boolean;
    function  SetRegisterByName(const Name: string; Value: UInt64): Boolean;
    function  SetInstructionPointer(VA: UInt64): Boolean;
    function  ArmHardwareWatchpoint(TID: DWORD; Slot: Integer; Address: UInt64;
                SizeBytes: Integer; WriteOnly: Boolean): Boolean;
    function  DisarmHardwareWatchpoint(TID: DWORD; Slot: Integer): Boolean;
    function  HardwareWatchpointHitCount: Integer;
    function  LastHardwareWatchpointHit: TWatchpointHit;
    function  AllocateRemoteString(const Text, TypeHint: string; out NewPtr: UInt64): Boolean;
    function  SetStringVariable(TargetAddr: UInt64; const Text, TypeHint: string): Boolean;
    function  TryResolveSymbolVA(const Name: string; out VA: UInt64): Boolean;
    function  AddressIsExecutable(VA: UInt64): Boolean;
    function  RemoteCallInFlight: Boolean;
    procedure RequestAbortRemoteCall;
    function  TryResolveClassRef(const ClassName: string; out VA: UInt64): Boolean;
    function  TryResolveConstValue(const Name: string; out Value: Int64; out TypeHint: string): Boolean;
    function  GetRemoteScratchSlot(MinSize: NativeUInt): UInt64;
    function  RunMethodCall(FuncVA: UInt64; const ArgValues: array of UInt64;
                const ArgKinds: array of TSyntheticArgKind; out IntResult, FloatResultLow: UInt64): Boolean;
    function  RunRemoteCallEx(FuncVA: UInt64; Arg0, Arg1, Arg2, Arg3: UInt64;
                out IntResult, FloatResultLow: UInt64): Boolean;
    function  LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
    procedure SetExceptionFilters(Filters: TExceptionFilters);
    procedure SetDelphiClassFilter(const ClassNames: string);
    procedure SetExceptionRules(const Rules: TArray<TExceptionRule>);
    procedure Launch(const ExePath: string; StopAtEntry: Boolean);
    procedure Attach(ProcessId: Cardinal; KillOnDetach: Boolean);
    procedure Terminate;
    procedure PostCommand(const Cmd: TCommand);
    procedure ProcessOneEvent;
    function  GetOnStopped: TOnStopped;
    procedure SetOnStopped(const Value: TOnStopped);
    function  GetOnExited: TOnExited;
    procedure SetOnExited(const Value: TOnExited);
    function  GetOnOutput: TOnOutput;
    procedure SetOnOutput(const Value: TOnOutput);
    function  GetOnDllLoaded: TOnDllLoaded;
    procedure SetOnDllLoaded(const Value: TOnDllLoaded);
    function  GetOnDllUnloaded: TOnDllUnloaded;
    procedure SetOnDllUnloaded(const Value: TOnDllUnloaded);
    function  GetOnBpHit: TOnBpHit;
    procedure SetOnBpHit(const Value: TOnBpHit);
  end;

constructor TFakeMemTarget.Create(BaseVA: UInt64; const Bytes: TBytes);
begin
  inherited Create;
  FBase   := BaseVA;
  FMem    := Bytes;
  FLayout := TTargetLayout.For64Bit;
end;

procedure TFakeMemTarget.SetLayout(const ALayout: TTargetLayout);
begin
  FLayout := ALayout;
end;

function TFakeMemTarget.TargetLayout: TTargetLayout;
begin
  Result := FLayout;
end;

function TFakeMemTarget.ReadProcessMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean;
begin
  Result := False;
  if (VA < FBase) or (VA + Size > FBase + UInt64(Length(FMem))) then Exit;
  Move(FMem[VA - FBase], Buf^, Size);
  Result := True;
end;

function  TFakeMemTarget.ProcessHandle: THandle; begin Result := 0; end;
function  TFakeMemTarget.ImageBase: UInt64; begin Result := 0; end;
function  TFakeMemTarget.HasExited: Boolean; begin Result := False; end;
function  TFakeMemTarget.LastExceptionDesc: string; begin Result := ''; end;
function  TFakeMemTarget.LastExceptionClass: string; begin Result := ''; end;
function  TFakeMemTarget.LastExceptionMessage: string; begin Result := ''; end;
function  TFakeMemTarget.CurrentExceptionObject: UInt64; begin Result := 0; end;
function  TFakeMemTarget.WriteMemoryAt(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean; begin Result := False; end;
function  TFakeMemTarget.RvaToVA(Rva: UInt64): UInt64; begin Result := Rva; end;
function  TFakeMemTarget.GetThreadIds: TArray<DWORD>; begin Result := nil; end;
function  TFakeMemTarget.GetThreadName(TID: DWORD): string; begin Result := ''; end;
function  TFakeMemTarget.GetStoppedThreadId: DWORD; begin Result := 0; end;
function  TFakeMemTarget.GetRegisters: TRegisterSnapshot; begin Result := Default(TRegisterSnapshot); end;
function  TFakeMemTarget.GetStackFrames: TArray<TStackFrame>; begin Result := nil; end;
function  TFakeMemTarget.GetStackFrames(TID: DWORD): TArray<TStackFrame>; begin Result := nil; end;
function  TFakeMemTarget.GetRawStackFrames(TID: DWORD; MaxItems: Integer): TArray<TStackFrame>; begin Result := nil; end;
function  TFakeMemTarget.ResymbolicateFrames(const Frames: TArray<TStackFrame>): TArray<TStackFrame>; begin Result := Frames; end;
function  TFakeMemTarget.CurrentScopeClassName: string; begin Result := ''; end;
function  TFakeMemTarget.LastSyntheticCallError: string; begin Result := ''; end;
function  TFakeMemTarget.GetLocalValues: TArray<TLocalValue>; begin Result := nil; end;
procedure TFakeMemTarget.SetActiveFrame(FrameRBP, FuncEntryVA: UInt64; const FuncName: string; FramePC: UInt64 = 0); begin end;
procedure TFakeMemTarget.ClearActiveFrame; begin end;
function  TFakeMemTarget.CurrentFrameParamHomeAddr(ParamIndex: Integer): UInt64; begin Result := 0; end;
function  TFakeMemTarget.EvaluateName(const Name: string; out Value: TLocalValue): Boolean; begin Value := Default(TLocalValue); Result := False; end;
function  TFakeMemTarget.EvaluateLocalName(const Name: string; out Value: TLocalValue): Boolean; begin Value := Default(TLocalValue); Result := False; end;
function  TFakeMemTarget.EvaluateGlobalName(const Name: string; out Value: TLocalValue): Boolean; begin Value := Default(TLocalValue); Result := False; end;
function  TFakeMemTarget.SetRegisterByName(const Name: string; Value: UInt64): Boolean; begin Result := False; end;
function  TFakeMemTarget.SetInstructionPointer(VA: UInt64): Boolean; begin Result := False; end;
// This fake has no live process and therefore no debug registers: arming must
// FAIL rather than silently claim a watchpoint nothing can deliver.
function  TFakeMemTarget.ArmHardwareWatchpoint(TID: DWORD; Slot: Integer; Address: UInt64; SizeBytes: Integer; WriteOnly: Boolean): Boolean; begin Result := False; end;
function  TFakeMemTarget.DisarmHardwareWatchpoint(TID: DWORD; Slot: Integer): Boolean; begin Result := False; end;
function  TFakeMemTarget.HardwareWatchpointHitCount: Integer; begin Result := 0; end;
function  TFakeMemTarget.LastHardwareWatchpointHit: TWatchpointHit; begin Result := Default(TWatchpointHit); Result.Slot := -1; end;
function  TFakeMemTarget.AllocateRemoteString(const Text, TypeHint: string; out NewPtr: UInt64): Boolean; begin NewPtr := 0; Result := False; end;
function  TFakeMemTarget.SetStringVariable(TargetAddr: UInt64; const Text, TypeHint: string): Boolean; begin Result := False; end;
function  TFakeMemTarget.TryResolveSymbolVA(const Name: string; out VA: UInt64): Boolean; begin VA := 0; Result := False; end;
function  TFakeMemTarget.AddressIsExecutable(VA: UInt64): Boolean; begin Result := False; end;
function  TFakeMemTarget.RemoteCallInFlight: Boolean; begin Result := False; end;
procedure TFakeMemTarget.RequestAbortRemoteCall; begin end;
function  TFakeMemTarget.TryResolveClassRef(const ClassName: string; out VA: UInt64): Boolean; begin VA := 0; Result := False; end;
function  TFakeMemTarget.TryResolveConstValue(const Name: string; out Value: Int64; out TypeHint: string): Boolean; begin Value := 0; TypeHint := ''; Result := False; end;
function  TFakeMemTarget.GetRemoteScratchSlot(MinSize: NativeUInt): UInt64; begin Result := 0; end;
function  TFakeMemTarget.RunMethodCall(FuncVA: UInt64; const ArgValues: array of UInt64; const ArgKinds: array of TSyntheticArgKind; out IntResult, FloatResultLow: UInt64): Boolean; begin IntResult := 0; FloatResultLow := 0; Result := False; end;
function  TFakeMemTarget.RunRemoteCallEx(FuncVA: UInt64; Arg0, Arg1, Arg2, Arg3: UInt64; out IntResult, FloatResultLow: UInt64): Boolean; begin IntResult := 0; FloatResultLow := 0; Result := False; end;
procedure TFakeMemTarget.SetEnum(const AName: string; const AInfo: TRsmEnumInfo);
begin
  FEnumName := AName;
  FEnumInfo := AInfo;
end;

function  TFakeMemTarget.LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
begin
  Info := Default(TRsmEnumInfo);
  Result := (FEnumName <> '') and SameText(TypeName, FEnumName);
  if Result then Info := FEnumInfo;
end;
procedure TFakeMemTarget.SetExceptionFilters(Filters: TExceptionFilters); begin end;
procedure TFakeMemTarget.SetDelphiClassFilter(const ClassNames: string); begin end;
procedure TFakeMemTarget.SetExceptionRules(const Rules: TArray<TExceptionRule>); begin end;
procedure TFakeMemTarget.Launch(const ExePath: string; StopAtEntry: Boolean); begin end;
procedure TFakeMemTarget.Attach(ProcessId: Cardinal; KillOnDetach: Boolean); begin end;
procedure TFakeMemTarget.Terminate; begin end;
procedure TFakeMemTarget.PostCommand(const Cmd: TCommand); begin end;
procedure TFakeMemTarget.ProcessOneEvent; begin end;
function  TFakeMemTarget.GetOnStopped: TOnStopped; begin Result := FOnStopped; end;
procedure TFakeMemTarget.SetOnStopped(const Value: TOnStopped); begin FOnStopped := Value; end;
function  TFakeMemTarget.GetOnExited: TOnExited; begin Result := FOnExited; end;
procedure TFakeMemTarget.SetOnExited(const Value: TOnExited); begin FOnExited := Value; end;
function  TFakeMemTarget.GetOnOutput: TOnOutput; begin Result := FOnOutput; end;
procedure TFakeMemTarget.SetOnOutput(const Value: TOnOutput); begin FOnOutput := Value; end;
function  TFakeMemTarget.GetOnDllLoaded: TOnDllLoaded; begin Result := FOnDllLoaded; end;
procedure TFakeMemTarget.SetOnDllLoaded(const Value: TOnDllLoaded); begin FOnDllLoaded := Value; end;
function  TFakeMemTarget.GetOnDllUnloaded: TOnDllUnloaded; begin Result := FOnDllUnloaded; end;
procedure TFakeMemTarget.SetOnDllUnloaded(const Value: TOnDllUnloaded); begin FOnDllUnloaded := Value; end;
function  TFakeMemTarget.GetOnBpHit: TOnBpHit; begin Result := FOnBpHit; end;
procedure TFakeMemTarget.SetOnBpHit(const Value: TOnBpHit); begin FOnBpHit := Value; end;

procedure TValueReaderTests.CollidingLocals_AreDropped_UniqueAndRegisterOnesKept;

  function MakeLocal(const Name: string; Addr: UInt64; Reg: Word): TLocalValue;
  begin
    Result         := Default(TLocalValue);
    Result.Name    := Name;
    Result.Address := Addr;
    Result.RegId   := Reg;
  end;

begin
  // The measured shape: a set of stack locals all landing on one address
  // (the debug info gave them no location at all), one genuine local at its
  // own address, and a register-allocated local which legitimately carries no
  // frame address and must survive.
  var Input: TArray<TLocalValue> := [
    MakeLocal('bogusA',  $1F6FF8B0, 0),
    MakeLocal('bogusB',  $1F6FF8B0, 0),
    MakeLocal('bogusC',  $1F6FF8B0, 0),
    MakeLocal('genuine', $1F6FF8AC, 0),
    MakeLocal('inEax',   0,         1),
    MakeLocal('inEdx',   0,         2)];

  var Dropped := -1;
  var Kept := DropAddressCollisions(Input, Dropped);

  Assert.AreEqual(3, Dropped, 'the three colliding stack locals must be dropped');
  Assert.AreEqual(3, Integer(Length(Kept)),
    'genuine + the two register locals must remain');

  var Names := '';
  for var K in Kept do
    Names := Names + K.Name + ' ';
  Assert.IsTrue(Names.Contains('genuine'),
    'a local with its own address is not a collision: ' + Names);
  // Register locals share address 0 with each other, which says nothing about
  // them -- their value is not on the frame. Dropping them would delete every
  // register-allocated variable in an optimised build.
  Assert.IsTrue(Names.Contains('inEax') and Names.Contains('inEdx'),
    'register-allocated locals must be exempt from the address test: ' + Names);
  Assert.IsFalse(Names.Contains('bogus'),
    'no member of a colliding group may be kept -- which one is real is not ' +
    'knowable: ' + Names);
end;

procedure TValueReaderTests.UnknownOrdinalSubrange_MasksHighDword;
begin
  var DI := TDebugInfoSet.Create;
  var Reader := TDelphiValueReader.Create(DI, nil, nil);
  try
    var V := Default(TLocalValue);
    V.TypeHint   := 'TBorderWidth';       // unknown ordinal subrange
    V.Kind       := lkLocal;
    V.RawValue   := UInt64($3DAADA6000000000);  // real value 0; high dword = neighbour
    V.ValueValid := True;
    var S := Reader.FormatLocalValue(V);
    Assert.AreEqual('0  (0x0)', S,
      'unknown ordinal subrange must mask to 4 bytes, not print the 8-byte bleed');
  finally
    Reader.Free;
    DI.Free;
  end;
end;

procedure TValueReaderTests.Int64ByName_KeepsAllEightBytes;
begin
  var DI := TDebugInfoSet.Create;
  var Reader := TDelphiValueReader.Create(DI, nil, nil);
  try
    var V := Default(TLocalValue);
    V.TypeHint   := 'Int64';
    V.Kind       := lkLocal;
    V.RawValue   := UInt64($00000001_00000002);
    V.ValueValid := True;
    var S := Reader.FormatLocalValue(V);
    Assert.AreEqual(Format('%d  (0x%x)', [Int64($0000000100000002), UInt64($0000000100000002)]), S,
      'a named 64-bit type must keep all 8 bytes');
  finally
    Reader.Free;
    DI.Free;
  end;
end;

const
  FAKE_BASE = UInt64($400000);

// Build a 24-byte TVarData image: VType at +0, an 8-byte payload at +8, the
// reserved words (+2..+7) and tail (+16..+23) left zero.
function MakeVarData(VType: Word; Payload: UInt64): TBytes;
begin
  SetLength(Result, 24);
  FillChar(Result[0], 24, 0);
  PWord(@Result[0])^   := VType;
  PUInt64(@Result[8])^ := Payload;
end;

function LooksLikeVariant(VType: Word; Payload: UInt64): Boolean;
begin
  var Fake: IDebugTarget := TFakeMemTarget.Create(FAKE_BASE, MakeVarData(VType, Payload));
  var DI := TDebugInfoSet.Create;
  var Reader := TDelphiValueReader.Create(DI, Fake, nil);
  try
    Result := Reader.LooksLikeVariantAt(FAKE_BASE);
  finally
    Reader.Free;
    DI.Free;
  end;
end;

procedure TValueReaderTests.VariantAutoDetect_Int64Pattern_Rejected;
begin
  // Plain integer local whose value is exactly 20 ($0014 = varInt64), with a
  // nonzero NEIGHBOUR qword in the next slot. Auto-detect must REJECT it -- else
  // it would be shown as a Variant reading the neighbour's bytes as the value.
  Assert.IsFalse(LooksLikeVariant($0014, UInt64($1122334455667788)),
    'a plain integer equal to 20 must not be auto-detected as a varInt64 Variant');
end;

// A Win32 dynamic-array image: RefCnt(4), Length(4), then the elements. The
// array VARIABLE holds a pointer to the ELEMENTS, i.e. base + 8.
function MakeDynArray32(RefCnt, Len, ElemBytes: Integer): TBytes;
begin
  SetLength(Result, 8 + ElemBytes);
  FillChar(Result[0], Length(Result), 0);
  PInteger(@Result[0])^ := RefCnt;
  PInteger(@Result[4])^ := Len;
end;

// The Win64 image: _Padding(4), RefCnt(4), Length(8), then the elements, so the
// data pointer is base + 16.
function MakeDynArray64(RefCnt: Integer; Len: Int64; ElemBytes: Integer): TBytes;
begin
  SetLength(Result, 16 + ElemBytes);
  FillChar(Result[0], Length(Result), 0);
  PInteger(@Result[4])^ := RefCnt;
  PInt64(@Result[8])^   := Len;
end;

// Reads the length the way the production decoders now do: address and width
// both taken from the layout, into a variable zeroed first so a narrow read
// cannot leave the high half as garbage.
function ReadDynLenWith(const Image: TBytes; DataOffset: Integer;
  const Layout: TTargetLayout): Int64;
var
  Raw: UInt64;
begin
  var Fake := TFakeMemTarget.Create(FAKE_BASE, Image);
  Fake.SetLayout(Layout);
  var Target: IDebugTarget := Fake;
  Raw := 0;
  Target.ReadProcessMemoryAt(
    Layout.DynArrayLengthAddr(FAKE_BASE + UInt64(DataOffset)),
    @Raw, Layout.DynArrayLengthSize);
  Result := Int64(Raw);
end;

procedure TValueReaderTests.DynArrayHeader_Win32Layout_DecodesLength;
begin
  var Image := MakeDynArray32(1, 7, 28);
  Assert.AreEqual(Int64(7),
    ReadDynLenWith(Image, 8, TTargetLayout.For32Bit),
    'a 32-bit dynamic array must report its real element count');
end;

procedure TValueReaderTests.DynArrayHeader_Win64Layout_DecodesLength;
begin
  var Image := MakeDynArray64(1, 7, 56);
  Assert.AreEqual(Int64(7),
    ReadDynLenWith(Image, 16, TTargetLayout.For64Bit),
    'a 64-bit dynamic array must report its real element count');
end;

procedure TValueReaderTests.DynArrayHeader_Win32ImageReadAsWin64_IsWrong;
begin
  // Proves the layout is load-bearing rather than decorative: read the SAME
  // 32-bit image with the 64-bit shape and the refcount is spliced into the
  // length. If this ever starts returning 7, the decoders have stopped
  // consulting the layout and the two tests above have gone vacuous.
  var Image := MakeDynArray32(1, 7, 28);
  var Wrong := ReadDynLenWith(Image, 8, TTargetLayout.For64Bit);
  Assert.AreNotEqual(Int64(7), Wrong,
    'reading a 32-bit array header with the 64-bit shape must NOT happen to be right');
  Assert.AreEqual(Int64($0000000700000001), Wrong,
    'the wrong read should splice Length into the high half and RefCnt into the low');
end;

procedure TValueReaderTests.VariantAutoDetect_UInt64Pattern_Rejected;
begin
  Assert.IsFalse(LooksLikeVariant($0015, UInt64($DEADBEEFCAFEF00D)),
    'a plain integer equal to 21 must not be auto-detected as a varUInt64 Variant');
end;

procedure TValueReaderTests.VariantAutoDetect_DoublePattern_Accepted;
begin
  // Guard: a genuine varDouble TVarData (3.5) must still auto-detect -- the
  // varInt64 fix must not regress real Variant recovery.
  Assert.IsTrue(LooksLikeVariant($0005, UInt64($400C000000000000)),
    'a genuine varDouble TVarData must still be recognised as a Variant');
end;

// Build a Delphi AnsiString image: TStrRec header then the chars. The string
// POINTER is (buffer base + 12) -- codePage@-12, elemSize@-10, refCnt@-8, len@-4.
function MakeAnsiStr(CodePage: Word; const Data: array of Byte): TBytes;
begin
  SetLength(Result, 12 + Length(Data));
  FillChar(Result[0], Length(Result), 0);
  PWord(@Result[0])^    := CodePage;
  PWord(@Result[2])^    := 1;                 // elemSize
  PInteger(@Result[4])^ := 1;                 // refCnt
  PInteger(@Result[8])^ := Length(Data);      // length (bytes)
  for var I := 0 to High(Data) do
    Result[12 + I] := Data[I];
end;

function ReadAnsiAt(CodePage: Word; const Data: array of Byte): string;
begin
  var Fake: IDebugTarget := TFakeMemTarget.Create(FAKE_BASE, MakeAnsiStr(CodePage, Data));
  var DI := TDebugInfoSet.Create;
  var Reader := TDelphiValueReader.Create(DI, Fake, nil);
  try
    if not Reader.ReadDelphiAnsiString(FAKE_BASE + 12, Result) then
      Result := '<read failed>';
  finally
    Reader.Free;
    DI.Free;
  end;
end;

procedure TValueReaderTests.AnsiString_Utf8CodePage_DecodesAsUtf8;
begin
  // UTF8String 'citt' + U+00E0  ->  63 69 74 74 C3 A0 with codePage 65001.
  Assert.AreEqual('citt' + #$00E0, ReadAnsiAt(65001, [$63, $69, $74, $74, $C3, $A0]),
    'a UTF8String must decode with its own code page, not the system ANSI page');
end;

procedure TValueReaderTests.AnsiString_DefaultCodePage_StillAnsi;
begin
  // CP_ACP (0) keeps the system ANSI decode -- guard against regressing the
  // ordinary AnsiString path.
  Assert.AreEqual('abc', ReadAnsiAt(0, [$61, $62, $63]),
    'a default-code-page AnsiString must still decode as before');
end;

// --- setVariable encoder tests ------------------------------------------------

type
  // Serves one named enum/set type: its TRsmEnumInfo and (optionally) an exact
  // provider size. Size = 0 means "no provider size", forcing the encoder's
  // derived-width path.
  // One routine's locals, answering by RVA, by name, or both -- enough to stand
  // in for TD32 (RVA-keyed, authoritative types) or RSM (name-keyed) in a merge.
  TFakeLocalProvider = class(TInterfacedObject, ILocalSymbolProvider)
  private
    FLocals:    TArray<TLocalSymbol>;
    FAnswerRva: Boolean;
    FAnswerName: Boolean;
  public
    constructor Create(const ALocals: TArray<TLocalSymbol>;
      AnswerRva, AnswerName: Boolean);
    function GetLocalsForFunction(const FunctionName: string;
      out Locals: TArray<TLocalSymbol>): Boolean;
    function GetLocalsForFunctionByRva(InnerRva: UInt64;
      out Locals: TArray<TLocalSymbol>): Boolean;
    function AllProcedureNames: TArray<string>;
  end;

  TFakeEnumSizeProvider = class(TInterfacedObject, IEnumInfoProvider, ITypeSizeProvider)
  private
    FTypeName: string;
    FInfo:     TRsmEnumInfo;
    FSize:     Integer;
  public
    constructor Create(const ATypeName: string; const AInfo: TRsmEnumInfo; ASize: Integer);
    function LookupEnumInfo(const TypeName: string; out Info: TRsmEnumInfo): Boolean;
    function TryResolveEnumLiteral(const Name: string;
      out Ordinal: Integer; out EnumTypeName: string;
      const ScopeClass: string = ''): Boolean;
    function LookupTypeKind(const TypeName: string): Byte;
    function GetTypeSize(const TypeName: string; out Size: Integer): Boolean;
  end;

constructor TFakeLocalProvider.Create(const ALocals: TArray<TLocalSymbol>;
  AnswerRva, AnswerName: Boolean);
begin
  inherited Create;
  FLocals     := ALocals;
  FAnswerRva  := AnswerRva;
  FAnswerName := AnswerName;
end;

function TFakeLocalProvider.GetLocalsForFunction(const FunctionName: string;
  out Locals: TArray<TLocalSymbol>): Boolean;
begin
  Locals := FLocals;
  Result := FAnswerName and (Length(FLocals) > 0);
end;

function TFakeLocalProvider.GetLocalsForFunctionByRva(InnerRva: UInt64;
  out Locals: TArray<TLocalSymbol>): Boolean;
begin
  Locals := FLocals;
  Result := FAnswerRva and (Length(FLocals) > 0);
end;

function TFakeLocalProvider.AllProcedureNames: TArray<string>;
begin
  Result := nil;
end;

procedure TValueReaderTests.ClassAncestorHint_IsNotOverriddenByANonClass;

  function Local(const Name, Hint: string; Off: Integer): TLocalSymbol;
  begin
    Result           := Default(TLocalSymbol);
    Result.Name      := Name;
    Result.TypeHint  := Hint;
    Result.RbpOffset := Off;
  end;

begin
  // The measured shape. TD32 answers by RVA and is right; RSM answers by name
  // with a mis-resolved typeId. `TComponent` is on the suspect list because
  // TD32 does sometimes name a generic ancestor where the source declares a
  // descendant -- but "not suspect" is not "plausible for this slot", and a
  // one-byte boolean can never refine a class reference.
  var Info := TDebugInfoSet.Create;
  try
    Info.AddProvider(TFakeLocalProvider.Create(
      [Local('Self', 'TfrmSomething', 16), Local('AOwner', 'TComponent', 32)],
      {AnswerRva=}True, {AnswerName=}False) as IInterface, {Primary=}True);
    Info.AddProvider(TFakeLocalProvider.Create(
      [Local('Self', 'TfrmSomething', 16), Local('AOwner', 'ByteBool', 32)],
      {AnswerRva=}False, {AnswerName=}True) as IInterface);

    var Locals: TArray<TLocalSymbol>;
    Assert.IsTrue(Info.GetLocalsForFunctionByRva($1000, 'TfrmSomething.Create', Locals),
      'the RVA-keyed provider must answer');

    var Hint := '';
    for var L in Locals do
      if SameText(L.Name, 'AOwner') then
        Hint := L.TypeHint;
    Assert.AreEqual('TComponent', Hint,
      'a class-ancestor hint must survive a non-class augment; got "' + Hint + '"');
  finally
    Info.Free;
  end;
end;

constructor TFakeEnumSizeProvider.Create(const ATypeName: string;
  const AInfo: TRsmEnumInfo; ASize: Integer);
begin
  inherited Create;
  FTypeName := ATypeName;
  FInfo     := AInfo;
  FSize     := ASize;
end;

function TFakeEnumSizeProvider.LookupEnumInfo(const TypeName: string;
  out Info: TRsmEnumInfo): Boolean;
begin
  Info := Default(TRsmEnumInfo);
  Result := SameText(TypeName, FTypeName);
  if Result then Info := FInfo;
end;

function TFakeEnumSizeProvider.TryResolveEnumLiteral(const Name: string;
  out Ordinal: Integer; out EnumTypeName: string;
  const ScopeClass: string): Boolean;
begin
  Ordinal := 0; EnumTypeName := ''; Result := False;
end;

function TFakeEnumSizeProvider.LookupTypeKind(const TypeName: string): Byte;
begin
  if SameText(TypeName, FTypeName) then Result := FInfo.Kind else Result := 0;
end;

function TFakeEnumSizeProvider.GetTypeSize(const TypeName: string;
  out Size: Integer): Boolean;
begin
  Size := 0;
  Result := SameText(TypeName, FTypeName) and (FSize > 0);
  if Result then Size := FSize;
end;

// Kind: 3 = tkEnumeration, 6 = tkSet. Members c0..cHighOrd.
function MakeEnumInfo(Kind: Byte; HighOrd: Integer): TRsmEnumInfo;
begin
  Result          := Default(TRsmEnumInfo);
  Result.Kind     := Kind;
  Result.MinValue := 0;
  Result.MaxValue := HighOrd;
  SetLength(Result.Names, HighOrd + 1);
  for var I := 0 to HighOrd do
    Result.Names[I] := Format('c%d', [I]);
  Result.IsValid := True;
end;

procedure TValueReaderTests.Enum_UninitialisedOrdinal_MasksToStorageWidth;
begin
  // 1-byte enum (3 members) in an UNINITIALISED slot: byte 0 = 7 (out of range),
  // bytes 1..7 = the adjacent local. Debugger=nil so the enum-NAME path is
  // skipped and the ordinal-display branch runs. Must show the 1-byte truth.
  var DI := TDebugInfoSet.Create;
  var Reader := TDelphiValueReader.Create(DI, nil, nil);
  try
    DI.AddProvider(TFakeEnumSizeProvider.Create('TState',
      MakeEnumInfo(3, 2), 0) as IInterface);
    var V := Default(TLocalValue);
    V.TypeHint   := 'TState';
    V.Kind       := lkLocal;
    V.RawValue   := UInt64($00007FF6ABCD1207);
    V.ValueValid := True;
    Assert.AreEqual('7  (0x7)', Reader.FormatLocalValue(V),
      'a 1-byte enum must mask to 1 byte, not fold the neighbouring local in');
  finally
    Reader.Free;
    DI.Free;
  end;
end;

procedure TValueReaderTests.Enum_OrdinalAbove255_ResolvesCorrectMember;
begin
  // 300-member enum => 2-byte storage. Ordinal 260 must resolve to its OWN
  // member; the old `and $FF` aliased it to ordinal 4 and showed that member.
  var Fake := TFakeMemTarget.Create(FAKE_BASE, nil);
  Fake.SetEnum('TBigEnum', MakeEnumInfo(3, 299));
  var FakeI: IDebugTarget := Fake;
  var DI := TDebugInfoSet.Create;
  var Reader := TDelphiValueReader.Create(DI, FakeI, nil);
  try
    var V := Default(TLocalValue);
    V.TypeHint   := 'TBigEnum';
    V.Kind       := lkLocal;
    V.RawValue   := 260;
    V.ValueValid := True;
    Assert.AreEqual('c260', Reader.FormatLocalValue(V),
      'ordinal 260 must resolve to its own member, not alias to (260 and $FF) = 4');
  finally
    Reader.Free;
    DI.Free;
  end;
end;

// Encode ValStr as TypeName; ProviderSize 0 = provider reports no size.
function EncodeOrdinal(Kind: Byte; HighOrd, ProviderSize: Integer;
  const ValStr: string; out Buf: array of Byte; out Size: Integer): Boolean;
begin
  var DI := TDebugInfoSet.Create;
  try
    DI.AddProvider(TFakeEnumSizeProvider.Create('TFakeSet',
      MakeEnumInfo(Kind, HighOrd), ProviderSize) as IInterface);
    Result := TryEncodeEnumOrdinal(DI, ValStr, 'TFakeSet', Buf, Size);
  finally
    DI.Free;
  end;
end;

procedure TValueEncoderTests.SetOfTwentyMembers_EncodesExactThreeBytes;
begin
  var Buf: array[0..7] of Byte;
  var Size: Integer;
  Assert.IsTrue(EncodeOrdinal(6, 19, 3, '7', Buf, Size), 'set encode failed');
  Assert.AreEqual(3, Size,
    'a 20-member set is 3 bytes; writing 4 would clobber the adjacent variable');
  Assert.AreEqual(7, Integer(Buf[0]), 'bitmask low byte');
  Assert.AreEqual(0, Integer(Buf[1]));
  Assert.AreEqual(0, Integer(Buf[2]));
end;

procedure TValueEncoderTests.SetOfTwentyMembers_NoProviderSize_StillThreeBytes;
begin
  var Buf: array[0..7] of Byte;
  var Size: Integer;
  // No provider size -> derived width must be ceil((19+1)/8) = 3, not rounded to 4.
  Assert.IsTrue(EncodeOrdinal(6, 19, 0, '7', Buf, Size), 'set encode failed');
  Assert.AreEqual(3, Size, 'derived set width must be exact, not rounded to 1/2/4');
end;

procedure TValueEncoderTests.SmallEnum_StillEncodesOneByte;
begin
  var Buf: array[0..7] of Byte;
  var Size: Integer;
  Assert.IsTrue(EncodeOrdinal(3, 2, 0, '2', Buf, Size), 'enum encode failed');
  Assert.AreEqual(1, Size, 'a 3-member enum stays 1 byte');
  Assert.AreEqual(2, Integer(Buf[0]));
end;

// Every provider interface listed here must carry its own GUID. The list is
// maintained by hand because Delphi offers no way to enumerate the interfaces
// declared in a unit; a forgotten entry weakens the check but can never make it
// fail spuriously, which is the right way round for a guard like this.
procedure TProviderInterfaceTests.ProviderInterfaceGuids_AreUnique;
type
  TNamedGuid = record
    Name: string;
    Guid: TGUID;
  end;

  function Entry(const Name: string; Info: PTypeInfo): TNamedGuid;
  begin
    Result.Name := Name;
    Result.Guid := GetTypeData(Info)^.Guid;
  end;

begin
  var All: TArray<TNamedGuid> := [
    Entry('ISourceLineProvider',       TypeInfo(ISourceLineProvider)),
    Entry('IFunctionNameProvider',     TypeInfo(IFunctionNameProvider)),
    Entry('ISourceFileListProvider',   TypeInfo(ISourceFileListProvider)),
    Entry('IBackgroundIndexProvider',  TypeInfo(IBackgroundIndexProvider)),
    Entry('ILocalSymbolProvider',      TypeInfo(ILocalSymbolProvider)),
    Entry('IUnitScopedLocalProvider',  TypeInfo(IUnitScopedLocalProvider)),
    Entry('IGlobalSymbolProvider',     TypeInfo(IGlobalSymbolProvider)),
    Entry('ISymbolExtentProvider',     TypeInfo(ISymbolExtentProvider)),
    Entry('IThreadLocalNameProvider',  TypeInfo(IThreadLocalNameProvider)),
    Entry('IUnitScopedGlobalProvider', TypeInfo(IUnitScopedGlobalProvider)),
    Entry('IUnitUsesProvider',         TypeInfo(IUnitUsesProvider)),
    Entry('IUnitScopedFuncProvider',   TypeInfo(IUnitScopedFuncProvider)),
    Entry('IUnitScopedConstProvider',  TypeInfo(IUnitScopedConstProvider)),
    Entry('IEnumInfoProvider',         TypeInfo(IEnumInfoProvider)),
    Entry('IClassMemberProvider',      TypeInfo(IClassMemberProvider)),
    Entry('IClassHierarchyProvider',   TypeInfo(IClassHierarchyProvider)),
    Entry('ITypePointeeKindProvider',  TypeInfo(ITypePointeeKindProvider)),
    Entry('ITypeSizeProvider',         TypeInfo(ITypeSizeProvider)),
    Entry('IMethodSignatureProvider',  TypeInfo(IMethodSignatureProvider))
  ];

  for var I := 0 to High(All) do begin
    Assert.AreNotEqual(GUIDToString(TGUID.Empty), GUIDToString(All[I].Guid),
      All[I].Name + ' has no GUID -- Supports() cannot find it at all');
    for var J := I + 1 to High(All) do
      Assert.AreNotEqual(GUIDToString(All[I].Guid), GUIDToString(All[J].Guid),
        Format('%s and %s share a GUID: Supports() will hand out the wrong ' +
               'vtable and calls will land on the other interface''s methods',
          [All[I].Name, All[J].Name]));
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TValueReaderTests);
  TDUnitX.RegisterTestFixture(TProviderInterfaceTests);
  TDUnitX.RegisterTestFixture(TValueEncoderTests);

end.
