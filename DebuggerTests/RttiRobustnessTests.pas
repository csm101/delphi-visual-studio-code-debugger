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
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
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
    for var Addr in ADVERSARIAL do begin
      // Each call is reported with the address that provoked it, because
      // "something raised" is useless without knowing which input did it.
      var Where := '$' + IntToHex(Addr, 16);
      try
        Rtti.IsClassInstance(Addr);
        Rtti.IsValidVmt(Addr);
        Rtti.VmtLayoutShift(Addr);
        Rtti.GetInstanceClassName(Addr);
        Rtti.GetInstanceSize(Addr);
        Rtti.GetClassChainNames(Addr);
        Rtti.IsInstanceOf(Addr, 'TObject');
        Rtti.DeclaresInterfaceAtOffset(Addr, 0);
        Rtti.DeclaresInterfaceAtOffset(Addr, $10000);
        Rtti.ExpandClass(Addr);
        Rtti.GetClassProperties(Addr);
        var Len: UInt64;
        Rtti.ReadDynArrayLength(Addr, Len);
      except
        on E: Exception do
          Assert.Fail(Format('%s raised on %s: %s',
            [E.ClassName, Where, E.Message]));
      end;
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

initialization
  TDUnitX.RegisterTestFixture(TRttiRobustnessTests);

end.
