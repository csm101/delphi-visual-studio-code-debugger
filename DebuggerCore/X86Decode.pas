unit X86Decode;

// Instruction-length decoder for 32-bit x86.
//
// It exists to answer one question exactly: IS THIS ADDRESS THE INSTRUCTION
// IMMEDIATELY AFTER A CALL? The stack walker needs that to tell a live return
// address from any other code address sitting on the stack, and the cheap
// version -- look a few bytes back for something call-shaped -- is not a test
// at all. Arbitrary bytes satisfy it. Measured: the address pushed by Delphi's
// `push offset @@finallyHandler` passed it, so a recovered frame named the
// right routine but pointed at the `finally` block instead of the call.
//
// x86 is not self-synchronising, so "the instruction before X" cannot be
// decoded by reading backwards. The only exact method is to decode FORWARD
// from a known instruction boundary and see whether a boundary lands on X.
// Callers supply that boundary (a function entry, or a line-table address --
// line records are always instruction starts).
//
// Design rule: EXACT OR NOTHING. Every opcode this decoder does not know
// returns length 0, which aborts the walk and makes the caller decline rather
// than approximate. A missing frame is recoverable; a confidently wrong one is
// not.
//
// Scope is deliberately 32-bit only. The x64 walker unwinds from .pdata and
// never needs to identify a return address by decoding, so a 64-bit mode here
// would be untested code. Add it only alongside a caller that needs it.

interface

type
  // Length = 0 means "not decodable" and is the only failure signal.
  TX86Insn = record
    Length:       Integer;
    IsCall:       Boolean;
    CallIsDirect: Boolean;   // E8 rel32; the only form with a static target
    DirectTarget: UInt32;    // valid when IsCall and CallIsDirect
  end;

// Decodes one instruction from Bytes[0..Avail-1]. AtVA is the address the
// instruction starts at, needed only to resolve a direct call's target.
function DecodeX86Insn32(const Bytes: array of Byte; Avail: Integer;
  AtVA: UInt32): TX86Insn;

type
  // Result of asking whether an address ends a call. Three outcomes, because
  // "could not decode" must never be collapsed into "no".
  TCallSiteAnswer = (csaNo, csaYes, csaUndecidable);

  TReadCodeProc = reference to function(VA: UInt64; Buf: Pointer;
    Size: Integer): Boolean;

// Decodes linearly from StartVA and reports whether an instruction boundary
// falls exactly on EndVA with a call ending there.
//
// csaUndecidable is returned when the stream cannot be decoded, when no
// boundary lands on EndVA (the start was not a real instruction boundary, or
// data sits in between), or when the span exceeds MaxBytes. Callers must treat
// it as "unknown", never as "no".
function CallSiteEndsAt(const ReadCode: TReadCodeProc;
  StartVA, EndVA: UInt64; MaxBytes: Integer = 4096): TCallSiteAnswer; overload;

// Same, and also hands back the call instruction itself. A DIRECT call is the
// only one whose target is knowable without running the program, which is how
// the walker names a routine that left no frame behind.
function CallSiteEndsAt(const ReadCode: TReadCodeProc;
  StartVA, EndVA: UInt64; out CallInsn: TX86Insn;
  MaxBytes: Integer = 4096): TCallSiteAnswer; overload;

implementation

const
  // Operand-form flags per opcode.
  fNone   = $00;
  fModRM  = $01;
  fImm8   = $02;
  fImm16  = $04;
  fImmZ   = $08;   // 4 bytes, or 2 under a 66 prefix
  fImmV   = $10;   // same as Z in 32-bit mode; kept distinct for clarity
  fMoffs  = $20;   // immediate is an address, sized by the address-size prefix
  fPtrFar = $40;   // ptr16:32 -- 4 or 2 bytes of offset plus a 2-byte selector
  fBad    = $80;   // not decoded here

type
  TOpFlags = Byte;

// One-byte opcode map. Prefixes (26 2E 36 3E 64 65 66 67 F0 F2 F3) and the 0F
// escape are consumed before this table is consulted, so their entries are
// never read.
function OneByteFlags(Op: Byte): TOpFlags;
begin
  // 00..3F: the eight ALU groups, each laid out identically.
  if Op < $40 then begin
    case Op and 7 of
      0, 1, 2, 3: Exit(fModRM);
      4:          Exit(fImm8);
      5:          Exit(fImmZ);
    else
      Exit(fNone);   // push/pop seg, DAA/DAS/AAA/AAS
    end;
  end;

  case Op of
    $40..$5F: Result := fNone;                 // inc/dec/push/pop r32
    $60, $61: Result := fNone;                 // pusha/popa
    $62, $63: Result := fModRM;                // bound / arpl
    $68:      Result := fImmZ;                 // push imm
    $69:      Result := fModRM or fImmZ;       // imul
    $6A:      Result := fImm8;                 // push imm8
    $6B:      Result := fModRM or fImm8;       // imul
    $6C..$6F: Result := fNone;                 // ins/outs
    $70..$7F: Result := fImm8;                 // jcc rel8
    $80:      Result := fModRM or fImm8;
    $81:      Result := fModRM or fImmZ;
    $82:      Result := fModRM or fImm8;       // undocumented alias of 80
    $83:      Result := fModRM or fImm8;
    $84..$8F: Result := fModRM;                // test/xchg/mov/lea/pop Ev
    $90..$99: Result := fNone;                 // xchg eAX / cbw / cwd
    $9A:      Result := fPtrFar;               // call far ptr16:32
    $9B..$9F: Result := fNone;
    $A0..$A3: Result := fMoffs;                // mov AL/eAX,[moffs]
    $A4..$A7: Result := fNone;                 // movs/cmps
    $A8:      Result := fImm8;
    $A9:      Result := fImmZ;
    $AA..$AF: Result := fNone;                 // stos/lods/scas
    $B0..$B7: Result := fImm8;                 // mov r8,imm8
    $B8..$BF: Result := fImmV;                 // mov r32,imm32
    $C0, $C1: Result := fModRM or fImm8;       // shift group
    $C2:      Result := fImm16;                // ret imm16
    $C3:      Result := fNone;
    $C4, $C5: Result := fModRM;                // les/lds
    $C6:      Result := fModRM or fImm8;
    $C7:      Result := fModRM or fImmZ;
    $C8:      Result := fImm16 or fImm8;       // enter imm16,imm8
    $C9:      Result := fNone;                 // leave
    $CA:      Result := fImm16;                // retf imm16
    $CB..$CC: Result := fNone;
    $CD:      Result := fImm8;                 // int imm8
    $CE, $CF: Result := fNone;
    $D0..$D3: Result := fModRM;                // shift by 1 / CL
    $D4, $D5: Result := fImm8;                 // aam/aad
    $D6, $D7: Result := fNone;                 // salc / xlat
    $D8..$DF: Result := fModRM;                // x87
    $E0..$E3: Result := fImm8;                 // loop / jecxz
    $E4..$E7: Result := fImm8;                 // in/out imm8
    $E8, $E9: Result := fImmZ;                 // call rel32 / jmp rel32
    $EA:      Result := fPtrFar;               // jmp far
    $EB:      Result := fImm8;
    $EC..$EF: Result := fNone;                 // in/out DX
    $F1:      Result := fNone;                 // int1
    $F4, $F5: Result := fNone;                 // hlt / cmc
    $F6:      Result := fModRM;                // group 3 -- imm added by caller
    $F7:      Result := fModRM;                // group 3 -- imm added by caller
    $F8..$FD: Result := fNone;                 // flag ops
    $FE, $FF: Result := fModRM;                // group 4 / 5
  else
    Result := fBad;
  end;
end;

// Two-byte (0F xx) map. The three-byte escapes 0F 38 and 0F 3A are handled by
// the caller because they consume an extra opcode byte.
function TwoByteFlags(Op: Byte): TOpFlags;
begin
  case Op of
    $00..$03: Result := fModRM;
    $05..$07: Result := fNone;                 // syscall / clts / sysret
    $08..$09: Result := fNone;                 // invd / wbinvd
    $0B:      Result := fNone;                 // ud2
    $0D..$1F: Result := fModRM;                // prefetch / SSE / hint nop
    $20..$23: Result := fModRM;                // mov cr/dr
    $28..$37: Result := fModRM;                // SSE moves and converts
    $40..$6F: Result := fModRM;                // cmovcc / SSE
    $70..$73: Result := fModRM or fImm8;       // pshuf / shift-imm groups
    $74..$76: Result := fModRM;
    $77:      Result := fNone;                 // emms
    $78..$7F: Result := fModRM;
    $80..$8F: Result := fImmZ;                 // jcc rel32
    $90..$9F: Result := fModRM;                // setcc
    $A0..$A2: Result := fNone;                 // push/pop fs, cpuid
    $A3:      Result := fModRM;                // bt
    $A4:      Result := fModRM or fImm8;       // shld imm8
    $A5:      Result := fModRM;                // shld cl
    $A8..$AA: Result := fNone;                 // push/pop gs, rsm
    $AB:      Result := fModRM;                // bts
    $AC:      Result := fModRM or fImm8;       // shrd imm8
    $AD..$B7: Result := fModRM;                // shrd cl / fxsave / imul / movzx
    $B8..$B9: Result := fModRM;                // popcnt / ud1
    $BA:      Result := fModRM or fImm8;       // bt/bts/btr/btc imm8
    $BB..$C1: Result := fModRM;                // btc / bsf / bsr / movsx / xadd
    $C2:      Result := fModRM or fImm8;       // cmpps
    $C3:      Result := fModRM;                // movnti
    $C4..$C6: Result := fModRM or fImm8;       // pinsrw / pextrw / shufps
    $C7:      Result := fModRM;                // cmpxchg8b group
    $C8..$CF: Result := fNone;                 // bswap
    $D0..$FF: Result := fModRM;                // SSE / MMX arithmetic
  else
    Result := fBad;
  end;
end;

function DecodeX86Insn32(const Bytes: array of Byte; Avail: Integer;
  AtVA: UInt32): TX86Insn;
var
  Pos: Integer;

  function Take(out B: Byte): Boolean;
  begin
    Result := Pos < Avail;
    if Result then begin
      B := Bytes[Pos];
      Inc(Pos);
    end;
  end;

begin
  Result := Default(TX86Insn);
  Pos := 0;
  if Avail <= 0 then
    Exit;

  var OpSize16  := False;
  var AddrSize16 := False;

  // Prefixes. Repeating one is legal and changes nothing.
  var Op: Byte := 0;
  while True do begin
    if not Take(Op) then
      Exit;
    case Op of
      $66: OpSize16  := True;
      $67: AddrSize16 := True;
      $F0, $F2, $F3,
      $26, $2E, $36, $3E, $64, $65: ;   // lock / rep / segment
    else
      Break;
    end;
  end;

  var Flags: TOpFlags;
  var IsGroup3 := False;
  var IsGroup5 := False;
  var TwoByte  := False;

  if Op = $0F then begin
    TwoByte := True;
    var Op2: Byte;
    if not Take(Op2) then
      Exit;
    if Op2 = $38 then begin
      // 0F 38 xx -- one more opcode byte, then a modrm and no immediate.
      var Op3: Byte;
      if not Take(Op3) then
        Exit;
      Flags := fModRM;
    end
    else if Op2 = $3A then begin
      var Op3: Byte;
      if not Take(Op3) then
        Exit;
      Flags := fModRM or fImm8;
    end
    else
      Flags := TwoByteFlags(Op2);
  end
  else begin
    Flags := OneByteFlags(Op);
    IsGroup3 := Op in [$F6, $F7];
    IsGroup5 := Op = $FF;
  end;

  if (Flags and fBad) <> 0 then
    Exit;

  // In 32-bit mode C4/C5 are LES/LDS only when they address memory. With
  // mod=3 they are the AVX VEX prefixes instead, and decoding them as LES/LDS
  // would yield a wrong length rather than no length. dcc32 does not emit AVX,
  // but a hand-written asm block or a future RTL might, so refuse instead.
  if (not TwoByte) and (Op in [$C4, $C5]) and (Pos < Avail) and
     ((Bytes[Pos] shr 6) = 3) then
    Exit;

  // ModRM, SIB and displacement.
  if (Flags and fModRM) <> 0 then begin
    var Modrm: Byte;
    if not Take(Modrm) then
      Exit;
    var Md := Modrm shr 6;
    var Reg := (Modrm shr 3) and 7;
    var Rm := Modrm and 7;

    // Group 3 (F6/F7) carries an immediate only for TEST (reg field 0 or 1).
    if IsGroup3 and (Reg in [0, 1]) then begin
      if Op = $F6 then
        Flags := Flags or fImm8
      else
        Flags := Flags or fImmZ;
    end;

    // Group 5 (FF): reg 2 is `call near`, reg 3 is `call far`. This is the
    // encoding a virtual method call uses, and it has no static target.
    if IsGroup5 and (Reg in [2, 3]) then begin
      Result.IsCall := True;
      Result.CallIsDirect := False;
    end;

    if Md <> 3 then begin
      if AddrSize16 then begin
        if (Md = 0) and (Rm = 6) then
          Inc(Pos, 2)
        else if Md = 1 then
          Inc(Pos, 1)
        else if Md = 2 then
          Inc(Pos, 2);
      end
      else begin
        if Rm = 4 then begin
          var Sib: Byte;
          if not Take(Sib) then
            Exit;
          if (Md = 0) and ((Sib and 7) = 5) then
            Inc(Pos, 4);
        end
        else if (Md = 0) and (Rm = 5) then
          Inc(Pos, 4);
        if Md = 1 then
          Inc(Pos, 1)
        else if Md = 2 then
          Inc(Pos, 4);
      end;
    end;
  end;

  // Immediates. Several opcodes carry two (enter imm16,imm8), so these are
  // additive rather than exclusive.
  if (Flags and fImm16) <> 0 then
    Inc(Pos, 2);
  if (Flags and fImm8) <> 0 then
    Inc(Pos, 1);
  if (Flags and (fImmZ or fImmV)) <> 0 then begin
    if OpSize16 then
      Inc(Pos, 2)
    else
      Inc(Pos, 4);
  end;
  if (Flags and fMoffs) <> 0 then begin
    if AddrSize16 then
      Inc(Pos, 2)
    else
      Inc(Pos, 4);
  end;
  if (Flags and fPtrFar) <> 0 then begin
    if OpSize16 then
      Inc(Pos, 2 + 2)
    else
      Inc(Pos, 4 + 2);
    Result.IsCall := Op = $9A;
    Result.CallIsDirect := False;   // absolute far, not a rel32 we resolve
  end;

  if Pos > Avail then
    Exit;   // instruction runs past what was read: undecidable, not zero-length

  // Direct near call. Its target is the only one recoverable statically, and
  // the walker uses it to confirm which routine was entered.
  if (not TwoByte) and (Op = $E8) and (not OpSize16) then begin
    Result.IsCall := True;
    Result.CallIsDirect := True;
    var Rel: Integer := PInteger(@Bytes[Pos - 4])^;
    Result.DirectTarget := UInt32(Int64(AtVA) + Pos + Rel);
  end;

  Result.Length := Pos;
end;

function CallSiteEndsAt(const ReadCode: TReadCodeProc;
  StartVA, EndVA: UInt64; MaxBytes: Integer): TCallSiteAnswer;
var
  Ignored: TX86Insn;
begin
  Result := CallSiteEndsAt(ReadCode, StartVA, EndVA, Ignored, MaxBytes);
end;

function CallSiteEndsAt(const ReadCode: TReadCodeProc;
  StartVA, EndVA: UInt64; out CallInsn: TX86Insn;
  MaxBytes: Integer): TCallSiteAnswer;
const
  WINDOW = 16;   // longest legal x86 instruction is 15 bytes
begin
  CallInsn := Default(TX86Insn);
  if (EndVA <= StartVA) or (EndVA - StartVA > UInt64(MaxBytes)) then
    Exit(csaUndecidable);

  var VA := StartVA;
  while VA < EndVA do begin
    var Buf: array[0..WINDOW - 1] of Byte;
    FillChar(Buf, SizeOf(Buf), 0);
    // Read what is available; a short read near a page edge still decodes when
    // the instruction is short, and reports undecidable when it is not.
    var Got := WINDOW;
    while (Got > 0) and (not ReadCode(VA, @Buf[0], Got)) do
      Dec(Got);
    if Got = 0 then
      Exit(csaUndecidable);

    var Insn := DecodeX86Insn32(Buf, Got, UInt32(VA));
    if Insn.Length <= 0 then
      Exit(csaUndecidable);

    var Next := VA + UInt64(Insn.Length);
    if Next = EndVA then begin
      if not Insn.IsCall then
        Exit(csaNo);
      CallInsn := Insn;
      Exit(csaYes);
    end;
    if Next > EndVA then
      // A boundary skipped over EndVA, so StartVA was not a real instruction
      // boundary or data lies in between. Not an answer.
      Exit(csaUndecidable);
    VA := Next;
  end;

  Result := csaUndecidable;
end;

end.
