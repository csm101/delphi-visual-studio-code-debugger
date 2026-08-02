unit RttiRobustnessTests;

// The RTTI reader is handed addresses that come out of the DEBUGGEE, so any
// value it receives may be garbage: a stale pointer, an interior pointer, a
// field that is not a pointer at all. Its job is to answer "no" for those, and
// answering must never mean RAISING -- the adapter builds a whole `variables`
// response in one pass, so one arithmetic exception loses every variable in the
// scope, not just the one that provoked it.
//
// The adapter is compiled with `-$Q+ -$R+`, and address arithmetic on foreign
// pointers wraps by nature. That combination is what makes this worth pinning:
// a subtraction that underflows raises EIntOverflow rather than producing a
// meaningless address the next read would reject anyway.
//
// No debuggee is needed. The reader takes a process handle, so it can be aimed
// at THIS process: valid addresses then read, invalid ones fail, exactly as
// with a real target -- and a real object gives a positive control proving the
// reader works at all rather than failing everything for an unrelated reason.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TRttiRobustnessTests = class
  public
    // Positive control. If this stops passing, the fixture below proves nothing:
    // every "did not raise" would be satisfied by a reader that reads nothing.
    [Test]
    procedure ReadsARealObjectInThisProcess;

    // Every public entry point, against addresses chosen to break address
    // arithmetic: zero, sub-page, the 32-bit and 64-bit ceilings, the sign
    // boundary, and unaligned values.
    [Test]
    procedure GarbageAddresses_AnswerNoInsteadOfRaising;

    // Interface recovery subtracts a table offset from the pointer it is given,
    // which underflows for any pointer smaller than the offset.
    [Test]
    procedure InterfaceRecovery_SmallPointer_DoesNotUnderflow;

    // The extremes above are the easy half. The failure that actually happened
    // was at a PLAUSIBLE address: the interface search ran off the end of a heap
    // block into a loaded module's data, a stretch of bytes there passed the VMT
    // identity check, and the readers raised on it. So sweep real mapped memory
    // and hand every word in it to the readers.
    [Test]
    procedure SweepingRealModuleMemory_NeverRaises;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  DelphiRtti;

const
  // Values picked to hit the edges of pointer arithmetic rather than to be
  // realistic: a reader must be total over its input type.
  ADVERSARIAL: array[0..9] of UInt64 = (
    0,
    1,
    4095,
    4096,
    $7FFFFFFF,
    $80000000,
    $FFFFFFFF,
    $7FFFFFFFFFFFFFFF,
    $8000000000000000,
    $FFFFFFFFFFFFFFFF);

procedure TRttiRobustnessTests.ReadsARealObjectInThisProcess;
begin
  var Rtti := TDelphiRtti.Create(GetCurrentProcess);
  try
    var Obj := TStringList.Create;
    try
      var Addr := UInt64(NativeUInt(Obj));
      Assert.IsTrue(Rtti.IsClassInstance(Addr),
        'a real object must be recognised, or the robustness cases below are vacuous');
      Assert.AreEqual('TStringList', Rtti.GetInstanceClassName(Addr),
        'the reader must name a real class');
      Assert.IsTrue(Rtti.GetInstanceSize(Addr) > 0, 'instance size must be positive');
    finally
      Obj.Free;
    end;
  finally
    Rtti.Free;
  end;
end;

procedure TRttiRobustnessTests.GarbageAddresses_AnswerNoInsteadOfRaising;
begin
  var Rtti := TDelphiRtti.Create(GetCurrentProcess);
  try
    // Named, so a failure says WHICH entry point broke on WHICH address.
    // "something raised" is not a usable report.
    var Calls: TArray<TPair<string, TProc<UInt64>>> := [
      TPair<string, TProc<UInt64>>.Create('IsClassInstance',
        procedure(A: UInt64) begin Rtti.IsClassInstance(A) end),
      TPair<string, TProc<UInt64>>.Create('IsValidVmt',
        procedure(A: UInt64) begin Rtti.IsValidVmt(A) end),
      TPair<string, TProc<UInt64>>.Create('VmtLayoutShift',
        procedure(A: UInt64) begin Rtti.VmtLayoutShift(A) end),
      TPair<string, TProc<UInt64>>.Create('GetInstanceClassName',
        procedure(A: UInt64) begin Rtti.GetInstanceClassName(A) end),
      TPair<string, TProc<UInt64>>.Create('GetInstanceSize',
        procedure(A: UInt64) begin Rtti.GetInstanceSize(A) end),
      TPair<string, TProc<UInt64>>.Create('GetClassChainNames',
        procedure(A: UInt64) begin Rtti.GetClassChainNames(A) end),
      TPair<string, TProc<UInt64>>.Create('IsInstanceOf',
        procedure(A: UInt64) begin Rtti.IsInstanceOf(A, 'TObject') end),
      TPair<string, TProc<UInt64>>.Create('DeclaresInterfaceAtOffset(0)',
        procedure(A: UInt64) begin Rtti.DeclaresInterfaceAtOffset(A, 0) end),
      TPair<string, TProc<UInt64>>.Create('DeclaresInterfaceAtOffset(64K)',
        procedure(A: UInt64) begin Rtti.DeclaresInterfaceAtOffset(A, $10000) end),
      TPair<string, TProc<UInt64>>.Create('ExpandClass',
        procedure(A: UInt64) begin Rtti.ExpandClass(A) end),
      TPair<string, TProc<UInt64>>.Create('GetClassProperties',
        procedure(A: UInt64) begin Rtti.GetClassProperties(A) end),
      TPair<string, TProc<UInt64>>.Create('ReadDynArrayLength',
        procedure(A: UInt64)
        begin
          var Len: UInt64;
          Rtti.ReadDynArrayLength(A, Len);
        end)];

    for var Addr in ADVERSARIAL do
      for var Call in Calls do
        try
          Call.Value(Addr);
        except
          on E: Exception do
            Assert.Fail(Format('%s raised in %s on $%s: %s',
              [E.ClassName, Call.Key, IntToHex(Addr, 16), E.Message]));
        end;
  finally
    Rtti.Free;
  end;
end;

procedure TRttiRobustnessTests.InterfaceRecovery_SmallPointer_DoesNotUnderflow;
begin
  var Rtti := TDelphiRtti.Create(GetCurrentProcess);
  try
    for var Addr in ADVERSARIAL do begin
      var Obj: UInt64 := 0;
      var ConcreteClass: string := '';
      try
        Rtti.TryRecoverObjectFromInterface(Addr, Obj, ConcreteClass);
      except
        on E: Exception do
          Assert.Fail(Format('%s raised recovering from $%s: %s',
            [E.ClassName, IntToHex(Addr, 16), E.Message]));
      end;
    end;
  finally
    Rtti.Free;
  end;
end;

procedure TRttiRobustnessTests.SweepingRealModuleMemory_NeverRaises;
const
  SWEEP_BYTES = $10000;   // 64 KB of this module, which spans code and data
begin
  var Rtti := TDelphiRtti.Create(GetCurrentProcess);
  try
    var Base := UInt64(NativeUInt(GetModuleHandle(nil)));
    Assert.IsTrue(Base > 0, 'no module base');
    var Addr := Base;
    while Addr < Base + SWEEP_BYTES do begin
      try
        Rtti.IsClassInstance(Addr);
        Rtti.IsValidVmt(Addr);
        Rtti.GetInstanceSize(Addr);
        Rtti.GetInstanceClassName(Addr);
        var Obj: UInt64 := 0;
        var ConcreteClass: string := '';
        Rtti.TryRecoverObjectFromInterface(Addr, Obj, ConcreteClass);
      except
        on E: Exception do
          Assert.Fail(Format('%s raised sweeping $%s: %s',
            [E.ClassName, IntToHex(Addr, 16), E.Message]));
      end;
      Inc(Addr, 8);
    end;
  finally
    Rtti.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TRttiRobustnessTests);

end.
