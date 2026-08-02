unit X86DecodeTests;

// Unit tests for the 32-bit instruction-length decoder.
//
// The decoder exists so the x86 stack walker can PROVE that a stack word is a
// return address instead of guessing, so these tests pin two things: that
// lengths are right for the encodings dcc32 actually emits, and that the
// specific false positive which produced a wrong call stack stays rejected.
//
// No debuggee is needed: every case is a byte sequence taken from real dcc32
// output.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TX86DecodeTests = class
  public
    // Lengths for the encodings that make up almost all of dcc32's output.
    // A single wrong length desynchronises a linear decode, which is how a
    // wrong frame would get on screen.
    [Test]
    procedure Lengths_MatchRealEncodings;

    // Both call forms must be recognised, including the indirect one a virtual
    // method call uses -- that is the call the lost-frame case hangs on.
    [Test]
    procedure Call_DirectAndIndirect_AreRecognised;

    // A direct call's target is the only one recoverable without running the
    // program, and the walker uses it to name the routine that is missing.
    [Test]
    procedure DirectCall_ResolvesItsTarget;

    // REGRESSION. `push offset @@finallyHandler` puts a code address on the
    // stack that is not a return address. The previous test -- look a few bytes
    // back for something call-shaped -- accepted it, and the walker produced a
    // frame naming the right routine while pointing at its `finally` block.
    [Test]
    procedure PushImmediate_IsNotACallSite;

    // Unknown opcodes must report length 0 rather than a plausible number:
    // the whole design rests on "exact or nothing".
    [Test]
    procedure UnknownOpcode_ReportsZeroLength;

    // Deciding from a boundary that is not really a boundary must be refused,
    // not answered. csaUndecidable and csaNo are different answers and the
    // walker treats only csaYes as acceptance.
    [Test]
    procedure Overshoot_IsUndecidableNotNo;

    // Data embedded in the code stream -- dcc32 emits the exception-handler
    // table inline after `jmp @HandleAnyException` -- must not produce an
    // answer either.
    [Test]
    procedure SpanCrossingInlineData_IsUndecidable;
  end;

implementation

uses
  System.SysUtils,
  X86Decode;

const
  BASE = UInt32($00401000);   // arbitrary; only relative maths depends on it

function Decode(const B: array of Byte): TX86Insn;
begin
  Result := DecodeX86Insn32(B, Length(B), BASE);
end;

// Wraps a byte array as the code reader CallSiteEndsAt expects, with the array
// mapped at BASE.
function ReaderFor(const B: TBytes): TReadCodeProc;
begin
  Result :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Boolean
    begin
      if VA < BASE then
        Exit(False);
      var Ofs := VA - BASE;
      if Ofs + UInt64(Size) > UInt64(Length(B)) then
        Exit(False);
      Move(B[Ofs], Buf^, Size);
      Result := True;
    end;
end;

procedure TX86DecodeTests.Lengths_MatchRealEncodings;

  procedure Check(const Expected: Integer; const Bytes: array of Byte;
    const Why: string);
  begin
    var Insn := Decode(Bytes);
    Assert.AreEqual(Expected, Insn.Length, Why);
  end;

begin
  Check(1, [$55],                            'push ebp');
  Check(1, [$C3],                            'ret');
  Check(2, [$8B, $EC],                       'mov ebp,esp');
  Check(2, [$33, $C0],                       'xor eax,eax');
  Check(2, [$EB, $54],                       'jmp short');
  Check(2, [$F7, $D8],                       'neg eax (F7 /3 has no immediate)');
  Check(3, [$83, $C4, $F8],                  'add esp,-8');
  Check(3, [$89, $45, $FC],                  'mov [ebp-4],eax');
  Check(3, [$8D, $45, $F0],                  'lea eax,[ebp-16]');
  Check(3, [$64, $89, $10],                  'mov fs:[eax],edx (segment prefix)');
  Check(3, [$D9, $45, $FC],                  'fld dword [ebp-4] (x87)');
  Check(4, [$0F, $B6, $45, $FF],             'movzx eax,byte [ebp-1]');
  Check(4, [$66, $B8, $34, $12],             'mov ax,imm16 (66 shrinks the imm)');
  Check(5, [$E9, $B7, $B4, $F2, $FF],        'jmp rel32');
  Check(5, [$A1, $00, $10, $40, $00],        'mov eax,[moffs32]');
  Check(5, [$68, $C8, $D6, $4D, $00],        'push imm32');
  Check(6, [$0F, $84, $12, $00, $00, $00],   'jz rel32');
  Check(7, [$C7, $45, $FC, $00, $00, $00, $00],
                                             'mov dword [ebp-4],imm32');
  Check(7, [$F7, $45, $FC, $01, $00, $00, $00],
                                             'test dword [ebp-4],imm32 (F7 /0 HAS an immediate)');
  Check(7, [$8B, $04, $8D, $00, $00, $00, $00],
                                             'mov eax,[ecx*4+disp32] (SIB with no base)');
  Check(7, [$FF, $24, $85, $00, $00, $00, $00],
                                             'jmp [eax*4+disp32] (FF /4 is not a call)');
end;

procedure TX86DecodeTests.Call_DirectAndIndirect_AreRecognised;
begin
  var Direct := Decode([$E8, $12, $34, $56, $78]);
  Assert.AreEqual(5, Direct.Length, 'call rel32 is 5 bytes');
  Assert.IsTrue(Direct.IsCall, 'E8 must be reported as a call');
  Assert.IsTrue(Direct.CallIsDirect, 'E8 has a static target');

  // FF /2 with a 32-bit displacement -- how a virtual method is invoked.
  var Indirect := Decode([$FF, $91, $A8, $00, $00, $00]);
  Assert.AreEqual(6, Indirect.Length, 'call [ecx+disp32] is 6 bytes');
  Assert.IsTrue(Indirect.IsCall, 'FF /2 must be reported as a call');
  Assert.IsFalse(Indirect.CallIsDirect, 'an indirect call has no static target');

  // FF /4 is a JMP through the same encoding shape and must NOT be a call.
  var IndirectJmp := Decode([$FF, $E0]);
  Assert.AreEqual(2, IndirectJmp.Length, 'jmp eax is 2 bytes');
  Assert.IsFalse(IndirectJmp.IsCall, 'FF /4 is a jump, not a call');
end;

procedure TX86DecodeTests.DirectCall_ResolvesItsTarget;
begin
  // rel32 = -$1000, so the target is (BASE + 5) - $1000.
  var Insn := Decode([$E8, $00, $F0, $FF, $FF]);
  Assert.IsTrue(Insn.IsCall and Insn.CallIsDirect, 'must be a direct call');
  Assert.AreEqual(UInt32(BASE + 5 - $1000), Insn.DirectTarget,
    'target is relative to the END of the instruction');
end;

procedure TX86DecodeTests.PushImmediate_IsNotACallSite;
begin
  // push ebp / push offset @@handler. The pushed value is a code address, and
  // the address AFTER the push is what a backwards byte scan used to accept.
  var Code: TBytes := [$55, $68, $C8, $D6, $4D, $00];
  Assert.AreEqual(Ord(csaNo),
    Ord(CallSiteEndsAt(ReaderFor(Code), BASE, BASE + UInt64(Length(Code)))),
    'the address after `push imm32` must be rejected, not accepted');

  // The same span shape, but ending after a real indirect call, must pass --
  // otherwise the fix would just be a blanket refusal.
  var WithCall: TBytes := [$55, $8B, $EC, $FF, $91, $A8, $00, $00, $00];
  Assert.AreEqual(Ord(csaYes),
    Ord(CallSiteEndsAt(ReaderFor(WithCall), BASE, BASE + UInt64(Length(WithCall)))),
    'the address after a virtual call must be accepted');
end;

procedure TX86DecodeTests.UnknownOpcode_ReportsZeroLength;
begin
  // 0F 04 is not a defined opcode in the map, and must not be guessed at.
  Assert.AreEqual(0, Decode([$0F, $04]).Length,
    'an unmapped opcode must report length 0');

  // C5 with mod=3 is the 2-byte AVX VEX prefix, not LDS. Decoding it as LDS
  // would produce a plausible wrong length, which is the one outcome the
  // design forbids.
  Assert.AreEqual(0, Decode([$C5, $F8, $57, $C0]).Length,
    'a VEX prefix must report length 0, not an LDS length');

  // The memory form of the same opcode IS LDS and must still decode.
  Assert.AreEqual(3, Decode([$C5, $45, $FC]).Length,
    'lds eax,[ebp-4] must still decode');
end;

procedure TX86DecodeTests.Overshoot_IsUndecidableNotNo;
begin
  // The end address falls INSIDE a 7-byte instruction, so no boundary can land
  // on it. That is "cannot tell", not "no".
  var Code: TBytes := [$C7, $45, $FC, $00, $00, $00, $00];
  Assert.AreEqual(Ord(csaUndecidable),
    Ord(CallSiteEndsAt(ReaderFor(Code), BASE, BASE + 2)),
    'an end address inside an instruction must be undecidable');
end;

procedure TX86DecodeTests.SpanCrossingInlineData_IsUndecidable;
begin
  // Verbatim from TestTarget.exe (Win32): the try/except tail, where dcc32
  // emits `jmp @HandleAnyException` followed by the handler table as raw data
  // and then the handler body. Decoding across the table cannot work, and the
  // decoder must say so rather than resynchronise onto something.
  var Code: TBytes := [
    $E9, $7C, $BF, $F2, $FF,               // jmp @HandleAnyException
    $01, $00, $00, $00,                    // handler count
    $70, $A3, $41, $00,                    // Exception VMT
    $C8, $D6, $4D, $00,                    // handler address
    $89, $45, $FC];                        // handler body: mov [ebp-4],eax
  Assert.AreEqual(Ord(csaUndecidable),
    Ord(CallSiteEndsAt(ReaderFor(Code), BASE, BASE + 17)),
    'a span crossing the inline exception table must be undecidable');
end;

initialization
  TDUnitX.RegisterTestFixture(TX86DecodeTests);

end.
