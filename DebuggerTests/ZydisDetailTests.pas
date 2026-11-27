unit ZydisDetailTests;

// Pins ZydisApi.ZydisDecodeDetail: the second entry point of the Zydis import
// unit, which returns the facts a control-flow analysis and an instruction
// relocator need -- the instruction's class, and where its displacement and
// its immediates are -- instead of its text.
//
// Those facts are read at byte offsets inside a C struct the DLL fills, and the
// offsets were MEASURED, not transcribed (ThirdParty\Zydis\PROVENANCE.md,
// "Measured struct layout"). A wrong offset does not fail: it returns a
// plausible number from a neighbouring field. So every field is pinned here
// against encodings whose layout the instruction set itself defines: each case
// is a handful of bytes, and the expectation says where in those bytes the
// displacement and the immediate are, what they hold, and what the instruction
// does to control flow. Both machine modes, because a 64-bit debugger decodes
// 32-bit targets through the same DLL.
//
// The expectation is one line of text (see Describe). A mismatch therefore
// shows the whole decoded instruction next to the whole expected one, which is
// what one needs to see when an offset has moved.

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  ZydisApi;

type
  [TestFixture]
  TZydisDetailTests = class
  public
    // docs/TRAPS.md: ZydisTryLoad is a process-wide ONE-SHOT latch, and other
    // tests deliberately leave it pointed at a missing DLL.
    [Setup] procedure LoadTheRealDll;

    [Test] procedure Long64_KnownEncodings_EveryFieldIsWhereTheEncodingPutsIt;
    [Test] procedure Legacy32_KnownEncodings_EveryFieldIsWhereTheEncodingPutsIt;
    // The decode-only path and the one that also formats text read the same
    // fields out of two different structs; and the text must be exactly what
    // the first entry point, ZydisDecodeOne, has always returned.
    [Test] procedure BothEntryPoints_AgreeOnEveryField_AndTheTextIsDecodeOnes;
    [Test] procedure BytesThatAreNotAnInstruction_AreRefused;
    // Fail closed: no decoder, no facts.
    [Test] procedure Unavailable_WhenDllMissing_DetailIsRefused;
  end;

implementation

uses
  System.TypInfo, System.Generics.Collections;

type
  TEncoding = record
    Address: UInt64;
    Bytes:   TBytes;
    Expect:  string;
  end;

const
  X64_BASE = UInt64($140001000);
  X86_BASE = UInt64($00401000);

function RealZydisDllPath: string;
begin
  // RunTests.exe lives at DebuggerTests\Win64\Debug\, three levels below the root.
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\') +
    'ThirdParty\Zydis\bin\x64\Zydis.dll';
end;

function Enc(Address: UInt64; const Bytes: TBytes; const Expect: string): TEncoding;
begin
  Result.Address := Address;
  Result.Bytes   := Bytes;
  Result.Expect  := Expect;
end;

function HexOf(const Bytes: TBytes): string;
begin
  Result := '';
  for var B in Bytes do
    Result := Result + IntToHex(B, 2) + ' ';
  Result := Result.TrimRight;
end;

// One line holding every field of a detail record:
//
//   <kind> len=N op=XX map=M [modrm=mod/reg/rm@offset] [sib=scale/index/base]
//   [disp=value:bits@offset] [imm0=value:bits@offset[r][s]] [imm1=...]
//   [rip->address] [branch->address]
//
// r = the immediate is relative, s = the decoder treats it as signed.
// The s flag is Zydis' own description of the operand (it calls most immediates
// signed, a `ret n` count and a far pointer unsigned), not a fact of the encoding;
// it is pinned so that a change in it is noticed.
function Describe(const Detail: TZydisInstructionDetail): string;

  function Immediate(const Imm: TZydisImmediate): string;
  begin
    Result := Format('$%x:%d@%d', [Imm.Value, Imm.Size, Imm.Offset]);
    if Imm.IsRelative then
      Result := Result + 'r';
    if Imm.IsSigned then
      Result := Result + 's';
  end;

begin
  Result := Format('%s len=%d op=%.2x map=%d', [
    GetEnumName(TypeInfo(TZydisInstructionKind), Ord(Detail.Kind)), Detail.Length,
    Detail.Opcode, Detail.OpcodeMap]);
  if Detail.HasModRM then
    Result := Result + Format(' modrm=%d/%d/%d@%d', [Detail.ModRMMod, Detail.ModRMReg,
      Detail.ModRMRm, Detail.ModRMOffset]);
  if Detail.HasSib then
    Result := Result + Format(' sib=%d/%d/%d', [Detail.SibScale, Detail.SibIndex, Detail.SibBase]);
  if Detail.DispSize <> 0 then begin
    if Detail.DispValue < 0 then
      Result := Result + Format(' disp=-$%x:%d@%d', [-Detail.DispValue, Detail.DispSize, Detail.DispOffset])
    else
      Result := Result + Format(' disp=$%x:%d@%d', [Detail.DispValue, Detail.DispSize, Detail.DispOffset]);
  end;
  if Detail.Imm[0].Size <> 0 then
    Result := Result + ' imm0=' + Immediate(Detail.Imm[0]);
  if Detail.Imm[1].Size <> 0 then
    Result := Result + ' imm1=' + Immediate(Detail.Imm[1]);
  if Detail.IsRipRelative then
    Result := Result + Format(' rip->$%x', [Detail.MemoryTarget]);
  if Detail.HasBranchTarget then
    Result := Result + Format(' branch->$%x', [Detail.BranchTarget]);
end;

function Long64Cases: TArray<TEncoding>;
begin
  Result := [
    // --- direct calls and jumps: the relative immediate and its target ---
    Enc(X64_BASE, [$E8, $10, $00, $00, $00],
      'zikCallDirect len=5 op=E8 map=0 imm0=$10:32@1rs branch->$140001015'),
    Enc(X64_BASE, [$E8, $FB, $FF, $FF, $FF],
      'zikCallDirect len=5 op=E8 map=0 imm0=$FFFFFFFFFFFFFFFB:32@1rs branch->$140001000'),
    Enc(X64_BASE, [$EB, $FE],
      'zikJumpDirect len=2 op=EB map=0 imm0=$FFFFFFFFFFFFFFFE:8@1rs branch->$140001000'),
    Enc(X64_BASE, [$E9, $00, $01, $00, $00],
      'zikJumpDirect len=5 op=E9 map=0 imm0=$100:32@1rs branch->$140001105'),
    Enc(X64_BASE, [$0F, $84, $00, $01, $00, $00],
      'zikJumpConditional len=6 op=84 map=1 imm0=$100:32@2rs branch->$140001106'),
    Enc(X64_BASE, [$75, $05],
      'zikJumpConditional len=2 op=75 map=0 imm0=$5:8@1rs branch->$140001007'),
    // --- indirect calls and jumps: ModRM, SIB, displacement, RIP-relative ---
    Enc(X64_BASE, [$FF, $15, $20, $00, $00, $00],
      'zikCallIndirect len=6 op=FF map=0 modrm=0/2/5@1 disp=$20:32@2 rip->$140001026'),
    Enc(X64_BASE, [$FF, $10],
      'zikCallIndirect len=2 op=FF map=0 modrm=0/2/0@1'),
    Enc(X64_BASE, [$FF, $E0],
      'zikJumpIndirect len=2 op=FF map=0 modrm=3/4/0@1'),
    // REX.B extends rm to r10; the raw field stays 2 and the ModRM byte moves.
    Enc(X64_BASE, [$41, $FF, $E2],
      'zikJumpIndirect len=3 op=FF map=0 modrm=3/4/2@2'),
    Enc(X64_BASE, [$FF, $25, $10, $00, $00, $00],
      'zikJumpIndirect len=6 op=FF map=0 modrm=0/4/5@1 disp=$10:32@2 rip->$140001016'),
    // jmp qword ptr [rax*8+0x401000]: an absolute table, NOT RIP-relative.
    Enc(X64_BASE, [$FF, $24, $C5, $00, $10, $40, $00],
      'zikJumpIndirect len=7 op=FF map=0 modrm=0/4/4@1 sib=3/0/5 disp=$401000:32@3'),
    // --- RIP-relative data: a negative displacement behind a REX prefix ---
    Enc(X64_BASE, [$48, $8B, $05, $F8, $FF, $FF, $FF],
      'zikOther len=7 op=8B map=0 modrm=0/0/5@2 disp=-$8:32@3 rip->$140000FFF'),
    // --- returns, traps ---
    Enc(X64_BASE, [$C3], 'zikReturn len=1 op=C3 map=0'),
    Enc(X64_BASE, [$C2, $08, $00], 'zikReturn len=3 op=C2 map=0 imm0=$8:16@1'),
    Enc(X64_BASE, [$CC], 'zikInt3 len=1 op=CC map=0'),
    Enc(X64_BASE, [$CD, $2E], 'zikInterrupt len=2 op=CD map=0 imm0=$2E:8@1'),
    Enc(X64_BASE, [$F4], 'zikHalt len=1 op=F4 map=0'),
    Enc(X64_BASE, [$0F, $0B], 'zikHalt len=2 op=0B map=1'),
    // --- immediates: 64-bit, one behind a displacement, two in one instruction ---
    Enc(X64_BASE, [$48, $B8, $88, $77, $66, $55, $44, $33, $22, $11],
      'zikOther len=10 op=B8 map=0 imm0=$1122334455667788:64@2s'),
    Enc(X64_BASE, [$C7, $85, $10, $FF, $FF, $FF, $78, $56, $34, $12],
      'zikOther len=10 op=C7 map=0 modrm=2/0/5@1 disp=-$F0:32@2 imm0=$12345678:32@6s'),
    Enc(X64_BASE, [$C8, $10, $00, $01],
      'zikOther len=4 op=C8 map=0 imm0=$10:16@1 imm1=$1:8@3'),
    // --- the epilogue shapes the x64 unwinder reads ---
    Enc(X64_BASE, [$48, $83, $C4, $28],
      'zikOther len=4 op=83 map=0 modrm=3/0/4@2 imm0=$28:8@3s'),
    Enc(X64_BASE, [$48, $8D, $65, $20],
      'zikOther len=4 op=8D map=0 modrm=1/4/5@2 disp=$20:8@3'),
    Enc(X64_BASE, [$5D], 'zikOther len=1 op=5D map=0'),
    // --- a prefix that is not part of the opcode ---
    Enc(X64_BASE, [$F3, $A4], 'zikOther len=2 op=A4 map=0')];
end;

function Legacy32Cases: TArray<TEncoding>;
begin
  Result := [
    Enc(X86_BASE, [$E8, $FB, $FF, $FF, $FF],
      'zikCallDirect len=5 op=E8 map=0 imm0=$FFFFFFFFFFFFFFFB:32@1rs branch->$401000'),
    // The instruction pointer is 32 bits wide: a branch past 4 GB wraps.
    Enc(UInt64($FFFFFFF0), [$E8, $20, $00, $00, $00],
      'zikCallDirect len=5 op=E8 map=0 imm0=$20:32@1rs branch->$15'),
    Enc(X86_BASE, [$E9, $10, $00, $00, $00],
      'zikJumpDirect len=5 op=E9 map=0 imm0=$10:32@1rs branch->$401015'),
    // An operand-size prefix makes it a 16-bit branch, truncated to 16 bits.
    Enc(X86_BASE, [$66, $E9, $10, $00],
      'zikJumpDirect len=4 op=E9 map=0 imm0=$10:16@2rs branch->$1014'),
    Enc(X86_BASE, [$E3, $05],
      'zikJumpConditional len=2 op=E3 map=0 imm0=$5:8@1rs branch->$401007'),
    Enc(X86_BASE, [$E2, $FE],
      'zikJumpConditional len=2 op=E2 map=0 imm0=$FFFFFFFFFFFFFFFE:8@1rs branch->$401000'),
    // jmp [0x402000]: the same bytes that are RIP-relative in 64-bit mode are
    // an absolute address here.
    Enc(X86_BASE, [$FF, $25, $00, $20, $40, $00],
      'zikJumpIndirect len=6 op=FF map=0 modrm=0/4/5@1 disp=$402000:32@2'),
    Enc(X86_BASE, [$FF, $15, $00, $20, $40, $00],
      'zikCallIndirect len=6 op=FF map=0 modrm=0/2/5@1 disp=$402000:32@2'),
    // jmp [eax*4+0x403000]: dcc32's `case` jump.
    Enc(X86_BASE, [$FF, $24, $85, $00, $30, $40, $00],
      'zikJumpIndirect len=7 op=FF map=0 modrm=0/4/4@1 sib=2/0/5 disp=$403000:32@3'),
    Enc(X86_BASE, [$FF, $E0],
      'zikJumpIndirect len=2 op=FF map=0 modrm=3/4/0@1'),
    // push 0x401234: how a handler stub and a finally continuation are named.
    Enc(X86_BASE, [$68, $34, $12, $40, $00],
      'zikOther len=5 op=68 map=0 imm0=$401234:32@1s'),
    Enc(X86_BASE, [$58], 'zikOther len=1 op=58 map=0'),
    // The byte index of dcc32's second `case` form.
    Enc(X86_BASE, [$0F, $B6, $80, $00, $20, $40, $00],
      'zikOther len=7 op=B6 map=1 modrm=2/0/0@2 disp=$402000:32@3'),
    Enc(X86_BASE, [$8B, $04, $85, $00, $20, $40, $00],
      'zikOther len=7 op=8B map=0 modrm=0/0/4@1 sib=2/0/5 disp=$402000:32@3'),
    // mov eax, [0x402000]: an address with no ModRM byte at all.
    Enc(X86_BASE, [$A1, $00, $20, $40, $00],
      'zikOther len=5 op=A1 map=0 disp=$402000:32@1'),
    Enc(X86_BASE, [$81, $7D, $FC, $78, $56, $34, $12],
      'zikOther len=7 op=81 map=0 modrm=1/7/5@1 disp=-$4:8@2 imm0=$12345678:32@3s'),
    Enc(X86_BASE, [$C2, $04, $00], 'zikReturn len=3 op=C2 map=0 imm0=$4:16@1'),
    Enc(X86_BASE, [$C3], 'zikReturn len=1 op=C3 map=0'),
    // Far transfers and `into` exist only outside 64-bit mode.
    Enc(X86_BASE, [$EA, $78, $56, $34, $12, $1B, $00],
      'zikJumpFar len=7 op=EA map=0 imm0=$12345678:32@1 imm1=$1B:16@5'),
    Enc(X86_BASE, [$9A, $78, $56, $34, $12, $1B, $00],
      'zikCallIndirect len=7 op=9A map=0 imm0=$12345678:32@1 imm1=$1B:16@5'),
    Enc(X86_BASE, [$CE], 'zikInterrupt len=1 op=CE map=0')];
end;

procedure CheckCases(Mode: TZydisMachineMode; const Cases: TArray<TEncoding>);
begin
  var Problems := TList<string>.Create;
  try
    for var Item in Cases do begin
      var Detail: TZydisInstructionDetail;
      if not ZydisDecodeDetail(Mode, Item.Address, Item.Bytes[0], Length(Item.Bytes), Detail) then begin
        Problems.Add(Format('[%s] did not decode', [HexOf(Item.Bytes)]));
        Continue;
      end;
      var Actual := Describe(Detail);
      if Actual <> Item.Expect then
        Problems.Add(Format('[%s]'#13#10'    expected %s'#13#10'    decoded  %s',
          [HexOf(Item.Bytes), Item.Expect, Actual]));
    end;
    if Problems.Count > 0 then
      Assert.Fail(Format('%d of %d encodings disagree:'#13#10'  %s',
        [Problems.Count, Length(Cases), string.Join(#13#10'  ', Problems.ToArray)]));
  finally
    Problems.Free;
  end;
end;

{ TZydisDetailTests }

procedure TZydisDetailTests.LoadTheRealDll;
begin
  ZydisResetForTests;
  Assert.IsTrue(ZydisTryLoad(RealZydisDllPath), 'real Zydis.dll must load: ' + ZydisStatusText);
end;

procedure TZydisDetailTests.Long64_KnownEncodings_EveryFieldIsWhereTheEncodingPutsIt;
begin
  CheckCases(zmmLong64, Long64Cases);
end;

procedure TZydisDetailTests.Legacy32_KnownEncodings_EveryFieldIsWhereTheEncodingPutsIt;
begin
  CheckCases(zmmLegacy32, Legacy32Cases);
end;

procedure TZydisDetailTests.BothEntryPoints_AgreeOnEveryField_AndTheTextIsDecodeOnes;

  procedure Compare(Mode: TZydisMachineMode; const Cases: TArray<TEncoding>);
  begin
    for var Item in Cases do begin
      var Fast, WithText: TZydisInstructionDetail;
      var Text: string;
      var Insn: TZydisInstruction;
      var Bytes := HexOf(Item.Bytes);
      Assert.IsTrue(ZydisDecodeDetail(Mode, Item.Address, Item.Bytes[0], Length(Item.Bytes), Fast),
        Bytes + ': the decode-only entry point refused');
      Assert.IsTrue(ZydisDecodeDetail(Mode, Item.Address, Item.Bytes[0], Length(Item.Bytes), WithText, Text),
        Bytes + ': the entry point with text refused');
      Assert.IsTrue(ZydisDecodeOne(Mode, Item.Address, Item.Bytes[0], Length(Item.Bytes), Insn),
        Bytes + ': ZydisDecodeOne refused');
      Assert.AreEqual(Describe(WithText), Describe(Fast), Bytes + ': the two entry points disagree');
      Assert.AreEqual(Insn.Text, Text, Bytes + ': the text is not ZydisDecodeOne''s');
      Assert.AreEqual<Integer>(Insn.Length, Fast.Length, Bytes + ': the length is not ZydisDecodeOne''s');
      Assert.IsTrue(Text <> '', Bytes + ': empty text');
    end;
  end;

begin
  Compare(zmmLong64, Long64Cases);
  Compare(zmmLegacy32, Legacy32Cases);
end;

procedure TZydisDetailTests.BytesThatAreNotAnInstruction_AreRefused;

  procedure Refused(Mode: TZydisMachineMode; const Bytes: TBytes; const Why: string);
  begin
    var Detail: TZydisInstructionDetail;
    var Text: string;
    // Pre-filled, so "zeroed on refusal" is observed and not assumed.
    FillChar(Detail, SizeOf(Detail), $A5);
    Assert.IsFalse(ZydisDecodeDetail(Mode, X64_BASE, Bytes[0], Length(Bytes), Detail), Why);
    Assert.AreEqual<Integer>(0, Detail.Length, Why + ': Length must be 0 on refusal');
    Assert.IsFalse(Detail.HasBranchTarget, Why + ': no branch target on refusal');
    FillChar(Detail, SizeOf(Detail), $A5);
    Text := 'stale';
    Assert.IsFalse(ZydisDecodeDetail(Mode, X64_BASE, Bytes[0], Length(Bytes), Detail, Text),
      Why + ' (entry point with text)');
    Assert.AreEqual<Integer>(0, Detail.Length, Why + ': Length must be 0 on refusal (with text)');
    Assert.AreEqual('', Text, Why + ': the text must be empty on refusal');
  end;

begin
  // `push es` and a far jump are not instructions in 64-bit mode.
  Refused(zmmLong64, [$06], 'push es in 64-bit mode');
  Refused(zmmLong64, [$EA, $78, $56, $34, $12, $1B, $00], 'jmp far in 64-bit mode');
  // A call whose immediate is cut off by the end of the buffer.
  Refused(zmmLong64, [$E8, $10, $00], 'truncated call, 64-bit');
  Refused(zmmLegacy32, [$E8, $10, $00], 'truncated call, 32-bit');
end;

procedure TZydisDetailTests.Unavailable_WhenDllMissing_DetailIsRefused;
begin
  ZydisResetForTests;
  Assert.IsFalse(ZydisTryLoad('X:\does-not-exist\ZydisDetailTests\NotReallyZydis.dll'),
    'a missing DLL must not load');
  try
    var Code: TBytes := [$C3];
    var Detail: TZydisInstructionDetail;
    var Text: string;
    FillChar(Detail, SizeOf(Detail), $A5);
    Assert.IsFalse(ZydisDecodeDetail(zmmLong64, X64_BASE, Code[0], 1, Detail),
      'no decoder: the decode-only entry point must refuse');
    Assert.AreEqual<Integer>(0, Detail.Length, 'no decoder: Length must be 0');
    FillChar(Detail, SizeOf(Detail), $A5);
    Assert.IsFalse(ZydisDecodeDetail(zmmLong64, X64_BASE, Code[0], 1, Detail, Text),
      'no decoder: the entry point with text must refuse');
    Assert.AreEqual<Integer>(0, Detail.Length, 'no decoder: Length must be 0 (with text)');
    Assert.AreEqual('', Text, 'no decoder: no text');
  finally
    // Leave the latch clean for whatever runs next in this process.
    ZydisResetForTests;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TZydisDetailTests);

end.
