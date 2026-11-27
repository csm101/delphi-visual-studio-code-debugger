unit ZydisApi;

// Dynamic-load import unit for Zydis (ThirdParty\Zydis\bin\x64\Zydis.dll),
// the x86/x64 disassembler chosen in docs/DISASSEMBLY_PLAN.md. This is an IMPORT
// UNIT, not a header translation: it declares only the entry points a caller
// needs (ZydisDisassembleIntel, ZydisGetVersion, and the two decode-only
// exports behind ZydisDecodeDetail) plus the byte offsets this unit reads out
// of Zydis's output structs.
//
// Two ways to decode one instruction:
//
//   ZydisDecodeOne     length and Intel-syntax text. What a disassembly view
//                      shows.
//   ZydisDecodeDetail  the instruction's class, its displacement and its
//                      immediates with their byte offsets, its branch target --
//                      what a control-flow analysis and an instruction
//                      relocator need. Without text it formats nothing and is
//                      the entry point for decoding a great many instructions.
//
// Load is explicit and dynamic (LoadLibrary), never a static import. A
// missing or incompatible DLL makes ZydisAvailable return False; nothing else
// in the debugger may notice. Call ZydisTryLoad once before decoding; it is
// idempotent -- the first call decides the outcome for the process lifetime.
// Every entry point fails closed without the DLL: it returns False, never a
// guessed length.
//
// `ZydisDisassembledInstruction` (Zydis\Disassembler.h) has nested unions and
// C bitfields (ZydisDecodedInstruction, ZydisDecodedOperand[10]) that are not
// safely hand-transcribed field-by-field into a Pascal record -- a single
// wrong bitfield silently shifts every offset after it. Instead, every fact
// this unit reads (the struct sizes, and the offset of each field it uses)
// was MEASURED with a throwaway C probe compiled against the pinned Zydis
// headers (`sizeof`/`offsetof` are compile-time constants, so no linking was
// needed). See PROVENANCE.md "Measured struct layout" for the values and the
// procedure, and the constants below. Re-measure after ever repinning the
// submodule to a release with a different struct layout;
// DebuggerTests\ZydisDetailTests.pas pins each field against known encodings.

interface

type
  // Mirrors ZydisMachineMode (Zydis\SharedTypes.h) exactly -- ordinal values
  // matter, they are passed to the DLL as a C enum (4-byte int on this ABI).
  TZydisMachineMode = (
    zmmLong64       = 0,  // 64-bit mode
    zmmLongCompat32 = 1,
    zmmLongCompat16 = 2,
    zmmLegacy32     = 3,  // 32-bit mode -- what a WOW64 target executes
    zmmLegacy16     = 4,
    zmmReal16       = 5
  );

  TZydisInstruction = record
    Length:  Integer;  // instruction byte length; 0 when undecodable
    Text:    string;   // Intel-syntax text; empty when undecodable
    Decoded: Boolean;  // False means "db" territory -- caller must not guess
  end;

  /// <summary>What an instruction does to control flow, read from its opcode
  /// and never from its text.</summary>
  TZydisInstructionKind = (
    /// <summary>Anything that falls through to the next instruction.</summary>
    zikOther,
    /// <summary><c>call rel</c> (E8): <c>BranchTarget</c> is valid.</summary>
    zikCallDirect,
    /// <summary><c>call r/m</c> (FF /2), and the far calls (FF /3, 9A).</summary>
    zikCallIndirect,
    /// <summary><c>jmp rel</c> (E9, EB): <c>BranchTarget</c> is valid.</summary>
    zikJumpDirect,
    /// <summary><c>Jcc</c>, <c>LOOPx</c>, <c>JxCXZ</c>: <c>BranchTarget</c> is valid.</summary>
    zikJumpConditional,
    /// <summary><c>jmp r/m</c> (FF /4).</summary>
    zikJumpIndirect,
    /// <summary>The far jumps (EA, FF /5).</summary>
    zikJumpFar,
    /// <summary><c>ret</c>, <c>ret n</c>, <c>retf</c>, <c>iret</c>.</summary>
    zikReturn,
    /// <summary><c>int3</c> (CC).</summary>
    zikInt3,
    /// <summary><c>int n</c>, <c>into</c>, <c>int1</c>.</summary>
    zikInterrupt,
    /// <summary><c>hlt</c> and <c>ud2</c>: execution does not continue.</summary>
    zikHalt
  );

  /// <summary>One raw immediate of an instruction.</summary>
  TZydisImmediate = record
    /// <summary>The value, sign-extended to 64 bits when <c>IsSigned</c>.</summary>
    Value: UInt64;
    /// <summary>Physical size in BITS; 0 when the instruction has no such immediate.</summary>
    Size: Byte;
    /// <summary>Byte offset of the field inside the instruction.</summary>
    Offset: Byte;
    /// <summary>The decoder treats the value as signed.</summary>
    IsSigned: Boolean;
    /// <summary>The value is an offset from the end of the instruction (a
    /// relative branch).</summary>
    IsRelative: Boolean;
  end;

  /// <summary>The facts a control-flow analysis and an instruction relocator
  /// need about one instruction: its class, and where its displacement and
  /// immediates are, so that a field can be read or rewritten in place.</summary>
  TZydisInstructionDetail = record
    /// <summary>Instruction length in bytes.</summary>
    Length: Byte;
    /// <summary>Control-flow class.</summary>
    Kind: TZydisInstructionKind;
    /// <summary>The opcode byte, after prefixes and escape bytes.</summary>
    Opcode: Byte;
    /// <summary>The opcode map: 0 one-byte, 1 <c>0F</c>, 2 <c>0F 38</c>, 3 <c>0F 3A</c>,
    /// higher values for the VEX / EVEX / XOP maps.</summary>
    OpcodeMap: Byte;
    /// <summary>The instruction has a ModRM byte; the ModRM fields are valid.</summary>
    HasModRM: Boolean;
    /// <summary>The instruction has a SIB byte; the SIB fields are valid.</summary>
    HasSib: Boolean;
    /// <summary>Raw <c>mod</c> field of the ModRM byte (0..3).</summary>
    ModRMMod: Byte;
    /// <summary>Raw <c>reg</c> field of the ModRM byte (0..7, no REX bit).</summary>
    ModRMReg: Byte;
    /// <summary>Raw <c>rm</c> field of the ModRM byte (0..7, no REX bit).</summary>
    ModRMRm: Byte;
    /// <summary>Byte offset of the ModRM byte inside the instruction.</summary>
    ModRMOffset: Byte;
    /// <summary>Raw <c>scale</c> field of the SIB byte (0..3).</summary>
    SibScale: Byte;
    /// <summary>Raw <c>index</c> field of the SIB byte (0..7).</summary>
    SibIndex: Byte;
    /// <summary>Raw <c>base</c> field of the SIB byte (0..7).</summary>
    SibBase: Byte;
    /// <summary>The displacement, sign-extended.</summary>
    DispValue: Int64;
    /// <summary>Physical size of the displacement in BITS; 0 when there is none.</summary>
    DispSize: Byte;
    /// <summary>Byte offset of the displacement inside the instruction.</summary>
    DispOffset: Byte;
    /// <summary>The raw immediates, in encoding order.</summary>
    Imm: array[0..1] of TZydisImmediate;
    /// <summary>A memory operand is addressed relative to the end of the
    /// instruction (64-bit mode, <c>mod</c> = 0 and <c>rm</c> = 5):
    /// <c>MemoryTarget</c> is valid and the displacement must be re-based when
    /// the instruction moves.</summary>
    IsRipRelative: Boolean;
    /// <summary>Absolute address a RIP-relative operand designates.</summary>
    MemoryTarget: UInt64;
    /// <summary><c>BranchTarget</c> is valid: a direct call, jump or
    /// conditional jump.</summary>
    HasBranchTarget: Boolean;
    /// <summary>Absolute address a direct branch transfers to, computed from
    /// the runtime address given to the decoder.</summary>
    BranchTarget: UInt64;
  end;

// Attempts to load Zydis.dll and resolve/version-check its exports. Safe to
// call more than once: only the first call does any work, later calls just
// return the cached result. ExplicitPath overrides the normal Windows DLL
// search order (the calling exe's own directory, then PATH) -- DevTools
// probes that do not ship the DLL next to themselves use this; the adapter,
// which does, calls with an empty string.
function ZydisTryLoad(const ExplicitPath: string = ''): Boolean;

// True once ZydisTryLoad has succeeded. False before the first call.
function ZydisAvailable: Boolean;

// Diagnostics: what happened on the last ZydisTryLoad (found path, resolved
// version, or why unavailable). Never empty.
function ZydisStatusText: string;

// Decodes exactly one instruction at RuntimeAddress from Bytes[0..AvailLen-1].
// Returns False (Insn.Decoded = False, Insn.Length = 0) when Zydis is
// unavailable or the bytes do not decode as a valid instruction -- this unit
// never guesses at a length or a mnemonic.
function ZydisDecodeOne(Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  const Bytes; AvailLen: Integer; out Insn: TZydisInstruction): Boolean;

/// <summary>Decodes one instruction and returns its facts without its text:
/// class, displacement, immediates, branch target. The entry point for anything
/// that decodes a great many instructions.</summary>
/// <remarks>No text is formatted and no operand is decoded, which makes it
/// several times cheaper than <c>ZydisDecodeOne</c>. Same contract otherwise:
/// it never guesses.</remarks>
/// <param name="Mode">Machine mode of the code.</param>
/// <param name="RuntimeAddress">Address of the instruction; branch and
/// RIP-relative targets are computed from it.</param>
/// <param name="Bytes">The code bytes.</param>
/// <param name="AvailLen">Number of bytes readable at <c>Bytes</c>.</param>
/// <param name="Detail">The facts; zeroed when the result is False.</param>
/// <returns>False when Zydis is unavailable or the bytes are not a valid
/// instruction.</returns>
function ZydisDecodeDetail(Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  const Bytes; AvailLen: Integer; out Detail: TZydisInstructionDetail): Boolean; overload;

/// <summary>Decodes one instruction and returns its facts AND its Intel-syntax
/// text.</summary>
/// <param name="Mode">Machine mode of the code.</param>
/// <param name="RuntimeAddress">Address of the instruction.</param>
/// <param name="Bytes">The code bytes.</param>
/// <param name="AvailLen">Number of bytes readable at <c>Bytes</c>.</param>
/// <param name="Detail">The facts; zeroed when the result is False.</param>
/// <param name="Text">The text <c>ZydisDecodeOne</c> returns for the same bytes;
/// empty when the result is False.</param>
/// <returns>False when Zydis is unavailable or the bytes are not a valid
/// instruction.</returns>
function ZydisDecodeDetail(Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  const Bytes; AvailLen: Integer; out Detail: TZydisInstructionDetail;
  out Text: string): Boolean; overload;

// TEST-ONLY. Resets the one-shot load latch (frees the module if one is
// loaded, and clears GLoadAttempted) so a single process can exercise BOTH
// the missing-DLL path and a real decode -- in EITHER order -- instead of
// the two being permanently exclusive within one process lifetime.
// Production code must never call this: ZydisTryLoad's one-shot contract
// ("the first call decides the outcome for the process's whole lifetime")
// is deliberate everywhere else, and stays in force for every caller except
// a test that explicitly wants to re-drive the load from a clean state.
procedure ZydisResetForTests;

implementation

uses
  Winapi.Windows, System.SysUtils;

const
  ZydisDllBareName = 'Zydis.dll';

  // This unit was written against Zydis v4.1.1. Compared major.minor only:
  // ZydisGetVersion() on the pinned build reports 4.1.0.0, one patch digit
  // behind the git tag (the ZYDIS_VERSION macro was not bumped for the 4.1.1
  // release -- confirmed against Zydis.c, see PROVENANCE.md). An exact-match
  // check would reject the very DLL this unit was built and tested against.
  ZydisExpectedMajor = 4;
  ZydisExpectedMinor = 1;

  // ZydisDisassembledInstruction layout, measured against this MSVC toolset
  // (PROVENANCE.md "Verification questions answered" / build log). The DLL
  // writes the WHOLE struct through our pointer, so RawInstructionSize must
  // be exactly right -- not "big enough".
  RawInstructionSize = 1232;  // sizeof(ZydisDisassembledInstruction)
  LengthFieldOffset  = 16;    // offsetof(.., info.length); 1 byte (ZyanU8)
  TextFieldOffset    = 1136;  // offsetof(.., text); 96 bytes, NUL-terminated
  TextFieldMaxLen    = 96;

  // ZydisDecodedInstruction (the `info` member, at offset 8 of the struct
  // above) and the fields ZydisDecodeDetail reads from it. Measured the same
  // way, 2026-11-27 (PROVENANCE.md "Measured struct layout"); every offset
  // below is relative to the START OF `info`, so the same table serves the
  // struct ZydisDisassembleIntel fills (info at +8) and the one
  // ZydisDecoderDecodeInstruction fills (info at +0).
  InfoOffsetInDisassembled = 8;    // offsetof(ZydisDisassembledInstruction, info)
  InfoSize                 = 328;  // sizeof(ZydisDecodedInstruction)
  InfoLength         = 8;    // length; ZyanU8
  InfoOpcodeMap      = 16;   // opcode_map; 4-byte enum
  InfoOpcode         = 20;   // opcode; ZyanU8
  InfoOperandWidth   = 22;   // operand_width; ZyanU8, in bits
  InfoAttributes     = 32;   // attributes; ZyanU64
  InfoModRMMod       = 255;  // raw.modrm.mod; ZyanU8
  InfoModRMReg       = 256;  // raw.modrm.reg
  InfoModRMRm        = 257;  // raw.modrm.rm
  InfoModRMOffset    = 258;  // raw.modrm.offset
  InfoSibScale       = 259;  // raw.sib.scale
  InfoSibIndex       = 260;  // raw.sib.index
  InfoSibBase        = 261;  // raw.sib.base
  InfoDispValue      = 264;  // raw.disp.value; ZyanI64
  InfoDispSize       = 272;  // raw.disp.size; ZyanU8, in bits
  InfoDispOffset     = 273;  // raw.disp.offset; ZyanU8
  InfoImm0           = 280;  // raw.imm[0]
  InfoImmStride      = 24;   // sizeof(raw.imm[0])
  ImmIsSigned        = 0;    // is_signed; ZyanBool (1 byte)
  ImmIsRelative      = 1;    // is_relative; ZyanBool
  ImmValue           = 8;    // value; ZyanU64 / ZyanI64
  ImmSize            = 16;   // size; ZyanU8, in bits
  ImmOffset          = 17;   // offset; ZyanU8

  AttribHasModRM   = UInt64(1) shl 0;   // ZYDIS_ATTRIB_HAS_MODRM
  AttribHasSib     = UInt64(1) shl 1;   // ZYDIS_ATTRIB_HAS_SIB

  OpcodeMapDefault = 0;   // ZYDIS_OPCODE_MAP_DEFAULT
  OpcodeMap0F      = 1;   // ZYDIS_OPCODE_MAP_0F

  DecoderSize      = 12;  // sizeof(ZydisDecoder)
  // ZydisStackWidth: 16 = 0, 32 = 1, 64 = 2.
  StackWidthOfMode: array[TZydisMachineMode] of UInt32 = (2, 1, 0, 1, 0, 0);

type
  TRawInstructionBuf = array[0..RawInstructionSize - 1] of Byte;
  // A whole number of 8-byte words, so the buffer is aligned as the C struct is.
  TRawInfoBuf = array[0..InfoSize div 8 - 1] of UInt64;
  TRawDecoder = array[0..DecoderSize - 1] of Byte;

  // ZyanStatus ZydisDecoderInit(ZydisDecoder*, ZydisMachineMode, ZydisStackWidth);
  TZydisDecoderInitFunc = function(Decoder: Pointer; MachineMode, StackWidth: UInt32): UInt32; cdecl;

  // ZyanStatus ZydisDecoderDecodeInstruction(const ZydisDecoder*, ZydisDecoderContext*,
  //   const void* buffer, ZyanUSize length, ZydisDecodedInstruction*);
  TZydisDecoderDecodeInstructionFunc = function(Decoder, Context, Buffer: Pointer;
    BufLength: NativeUInt; Instruction: Pointer): UInt32; cdecl;

  // ZyanStatus ZydisDisassembleIntel(ZydisMachineMode, ZyanU64 runtime_address,
  //   const void* buffer, ZyanUSize length, ZydisDisassembledInstruction*);
  TZydisDisassembleIntelFunc = function(MachineMode: UInt32; RuntimeAddress: UInt64;
    Buffer: Pointer; BufLength: NativeUInt; Instruction: Pointer): UInt32; cdecl;

  // ZyanU64 ZydisGetVersion(void);
  TZydisGetVersionFunc = function: UInt64; cdecl;

var
  GLoadAttempted:     Boolean = False;
  GModule:            HMODULE = 0;
  GDisassembleIntel:  TZydisDisassembleIntelFunc = nil;
  GGetVersionFunc:    TZydisGetVersionFunc = nil;
  GStatusText:        string = 'ZydisTryLoad was never called';
  // The decode-only path of ZydisDecodeDetail. Optional: when either export is
  // missing or a decoder does not initialise, GDecodeInstruction stays nil and
  // ZydisDecodeDetail goes through ZydisDisassembleIntel instead.
  GDecodeInstruction: TZydisDecoderDecodeInstructionFunc = nil;
  GDecoders:          array[TZydisMachineMode] of TRawDecoder;

function ZyanSucceeded(Status: UInt32): Boolean; inline;
begin
  Result := (Status and $80000000) = 0;
end;

function DecodeZydisVersion(RawVersion: UInt64; out Major, Minor, Patch, Build: UInt32): string;
begin
  Major := (RawVersion shr 48) and $FFFF;
  Minor := (RawVersion shr 32) and $FFFF;
  Patch := (RawVersion shr 16) and $FFFF;
  Build := RawVersion and $FFFF;
  Result := Format('%d.%d.%d.%d', [Major, Minor, Patch, Build]);
end;

function ZydisTryLoad(const ExplicitPath: string = ''): Boolean;

  function LoadPathFor(const ExplicitPath: string): string;
  begin
    if ExplicitPath <> '' then
      Result := ExplicitPath
    else
      Result := ZydisDllBareName;
  end;

  function VersionIsCompatible(RawVersion: UInt64; out VersionText: string): Boolean;
  var
    Major, Minor, Patch, Build: UInt32;
  begin
    VersionText := DecodeZydisVersion(RawVersion, Major, Minor, Patch, Build);
    Result := (Major = ZydisExpectedMajor) and (Minor = ZydisExpectedMinor);
  end;

  // One decoder per machine mode, initialised once: a decoder is read-only
  // after ZydisDecoderInit, so the decode-only path needs no per-call set-up.
  procedure PrepareDecodeOnlyPath;
  var
    InitDecoder: TZydisDecoderInitFunc;
  begin
    GDecodeInstruction := nil;
    @InitDecoder := GetProcAddress(GModule, 'ZydisDecoderInit');
    if not Assigned(InitDecoder) then
      Exit;
    for var Mode := Low(TZydisMachineMode) to High(TZydisMachineMode) do
      if not ZyanSucceeded(InitDecoder(@GDecoders[Mode], UInt32(Mode), StackWidthOfMode[Mode])) then
        Exit;
    @GDecodeInstruction := GetProcAddress(GModule, 'ZydisDecoderDecodeInstruction');
  end;

var
  LoadPath: string;
  RawVersion: UInt64;
  VersionText: string;
begin
  if GLoadAttempted then
    Exit(GModule <> 0);
  GLoadAttempted := True;

  LoadPath := LoadPathFor(ExplicitPath);
  GModule := LoadLibraryW(PWideChar(LoadPath));
  if GModule = 0 then begin
    GStatusText := Format('Zydis unavailable: LoadLibrary(''%s'') failed, GetLastError=%d',
      [LoadPath, GetLastError]);
    Exit(False);
  end;

  @GDisassembleIntel := GetProcAddress(GModule, 'ZydisDisassembleIntel');
  @GGetVersionFunc := GetProcAddress(GModule, 'ZydisGetVersion');
  if not Assigned(GDisassembleIntel) or not Assigned(GGetVersionFunc) then begin
    GStatusText := Format('Zydis unavailable: ''%s'' is missing an expected export', [LoadPath]);
    FreeLibrary(GModule);
    GModule := 0;
    Exit(False);
  end;

  RawVersion := GGetVersionFunc();
  if not VersionIsCompatible(RawVersion, VersionText) then begin
    GStatusText := Format('Zydis unavailable: ''%s'' reports version %s, expected %d.%d.x.x',
      [LoadPath, VersionText, ZydisExpectedMajor, ZydisExpectedMinor]);
    FreeLibrary(GModule);
    GModule := 0;
    GDisassembleIntel := nil;
    GGetVersionFunc := nil;
    Exit(False);
  end;

  PrepareDecodeOnlyPath;
  GStatusText := Format('Zydis %s loaded from ''%s''', [VersionText, LoadPath]);
  Result := True;
end;

function ZydisAvailable: Boolean;
begin
  Result := GLoadAttempted and (GModule <> 0);
end;

function ZydisStatusText: string;
begin
  Result := GStatusText;
end;

procedure ZydisResetForTests;
begin
  if GModule <> 0 then begin
    FreeLibrary(GModule);
    GModule := 0;
  end;
  GLoadAttempted := False;
  GDisassembleIntel := nil;
  GGetVersionFunc := nil;
  GDecodeInstruction := nil;
  GStatusText := 'ZydisTryLoad was never called';
end;

function RawTextToString(const Buf: TRawInstructionBuf): string;
var
  TextPtr: PAnsiChar;
begin
  TextPtr := PAnsiChar(@Buf[TextFieldOffset]);
  Result := string(AnsiString(TextPtr));  // AnsiString(PAnsiChar) stops at the first #0
end;

function ZydisDecodeOne(Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  const Bytes; AvailLen: Integer; out Insn: TZydisInstruction): Boolean;
var
  RawBuf: TRawInstructionBuf;
  Status: UInt32;
begin
  Insn.Length := 0;
  Insn.Text := '';
  Insn.Decoded := False;

  if not ZydisAvailable then
    Exit(False);
  if AvailLen <= 0 then
    Exit(False);

  FillChar(RawBuf, SizeOf(RawBuf), 0);
  Status := GDisassembleIntel(UInt32(Mode), RuntimeAddress, @Bytes,
    NativeUInt(AvailLen), @RawBuf[0]);
  if not ZyanSucceeded(Status) then
    Exit(False);

  Insn.Length := RawBuf[LengthFieldOffset];
  Insn.Text := RawTextToString(RawBuf);
  Insn.Decoded := Insn.Length > 0;
  Result := Insn.Decoded;
end;

function ClassifyOpcode(OpcodeMap, Opcode: Byte; HasModRM: Boolean;
  ModRMReg: Byte): TZydisInstructionKind;
begin
  Result := zikOther;
  if OpcodeMap = OpcodeMap0F then begin
    case Opcode of
      $80..$8F: Result := zikJumpConditional;
      $0B:      Result := zikHalt;             // ud2
    end;
    Exit;
  end;
  if OpcodeMap <> OpcodeMapDefault then
    Exit;
  case Opcode of
    $E8:                     Result := zikCallDirect;
    $E9, $EB:                Result := zikJumpDirect;
    $70..$7F, $E0..$E3:      Result := zikJumpConditional;   // Jcc, LOOPx, JxCXZ
    $C2, $C3, $CA, $CB, $CF: Result := zikReturn;            // ret, retf, iret
    $CC:                     Result := zikInt3;
    $CD, $CE, $F1:           Result := zikInterrupt;         // int n, into, int1
    $F4:                     Result := zikHalt;
    $EA:                     Result := zikJumpFar;
    $9A:                     Result := zikCallIndirect;      // call far ptr16:32
    $FF:
      if HasModRM then
        case ModRMReg of
          2, 3: Result := zikCallIndirect;
          4:    Result := zikJumpIndirect;
          5:    Result := zikJumpFar;
        end;
  end;
end;

// Fills Detail from a ZydisDecodedInstruction at Info. Reads fixed offsets and
// allocates nothing: this is the hot path of the routine analysis.
procedure ReadDetail(Info: PByte; Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  out Detail: TZydisInstructionDetail);
begin
  var Attributes := PUInt64(Info + InfoAttributes)^;
  Detail.Length      := Info[InfoLength];
  Detail.Opcode      := Info[InfoOpcode];
  Detail.OpcodeMap   := Byte(PCardinal(Info + InfoOpcodeMap)^);
  Detail.HasModRM    := Attributes and AttribHasModRM <> 0;
  Detail.HasSib      := Attributes and AttribHasSib <> 0;
  Detail.ModRMMod    := Info[InfoModRMMod];
  Detail.ModRMReg    := Info[InfoModRMReg];
  Detail.ModRMRm     := Info[InfoModRMRm];
  Detail.ModRMOffset := Info[InfoModRMOffset];
  Detail.SibScale    := Info[InfoSibScale];
  Detail.SibIndex    := Info[InfoSibIndex];
  Detail.SibBase     := Info[InfoSibBase];
  Detail.DispValue   := PInt64(Info + InfoDispValue)^;
  Detail.DispSize    := Info[InfoDispSize];
  Detail.DispOffset  := Info[InfoDispOffset];
  for var I := 0 to 1 do begin
    var Imm := Info + InfoImm0 + I * InfoImmStride;
    Detail.Imm[I].Value      := PUInt64(Imm + ImmValue)^;
    Detail.Imm[I].Size       := Imm[ImmSize];
    Detail.Imm[I].Offset     := Imm[ImmOffset];
    Detail.Imm[I].IsSigned   := Imm[ImmIsSigned] <> 0;
    Detail.Imm[I].IsRelative := Imm[ImmIsRelative] <> 0;
  end;
  Detail.Kind := ClassifyOpcode(Detail.OpcodeMap, Detail.Opcode, Detail.HasModRM, Detail.ModRMReg);

  // Addresses wrap by definition; the adapter is compiled with overflow and
  // range checks on.
  {$IFOPT Q+}{$DEFINE ZYDIS_RESTORE_Q}{$OVERFLOWCHECKS OFF}{$ENDIF}
  {$IFOPT R+}{$DEFINE ZYDIS_RESTORE_R}{$RANGECHECKS OFF}{$ENDIF}
  var NextAddress := RuntimeAddress + Detail.Length;
  Detail.IsRipRelative := (Mode = zmmLong64) and Detail.HasModRM and
    (Detail.ModRMMod = 0) and (Detail.ModRMRm = 5);
  Detail.MemoryTarget := 0;
  if Detail.IsRipRelative then
    Detail.MemoryTarget := NextAddress + UInt64(Detail.DispValue);
  Detail.HasBranchTarget := (Detail.Kind in [zikCallDirect, zikJumpDirect, zikJumpConditional]) and
    Detail.Imm[0].IsRelative;
  Detail.BranchTarget := 0;
  if Detail.HasBranchTarget then begin
    Detail.BranchTarget := NextAddress + Detail.Imm[0].Value;
    // Outside 64-bit mode the instruction pointer is truncated to the operand
    // size; in 64-bit mode a near branch is always 64 bits wide.
    if Mode <> zmmLong64 then begin
      if Info[InfoOperandWidth] = 16 then
        Detail.BranchTarget := Detail.BranchTarget and $FFFF
      else
        Detail.BranchTarget := Detail.BranchTarget and $FFFFFFFF;
    end;
  end;
  {$IFDEF ZYDIS_RESTORE_Q}{$OVERFLOWCHECKS ON}{$UNDEF ZYDIS_RESTORE_Q}{$ENDIF}
  {$IFDEF ZYDIS_RESTORE_R}{$RANGECHECKS ON}{$UNDEF ZYDIS_RESTORE_R}{$ENDIF}
end;

function ZydisDecodeDetail(Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  const Bytes; AvailLen: Integer; out Detail: TZydisInstructionDetail;
  out Text: string): Boolean;
var
  RawBuf: TRawInstructionBuf;
begin
  Detail := Default(TZydisInstructionDetail);
  Text := '';
  if (not ZydisAvailable) or (AvailLen <= 0) then
    Exit(False);
  FillChar(RawBuf, SizeOf(RawBuf), 0);
  if not ZyanSucceeded(GDisassembleIntel(UInt32(Mode), RuntimeAddress, @Bytes,
       NativeUInt(AvailLen), @RawBuf[0])) then
    Exit(False);
  if RawBuf[LengthFieldOffset] = 0 then
    Exit(False);
  ReadDetail(@RawBuf[InfoOffsetInDisassembled], Mode, RuntimeAddress, Detail);
  Text := RawTextToString(RawBuf);
  Result := True;
end;

function ZydisDecodeDetail(Mode: TZydisMachineMode; RuntimeAddress: UInt64;
  const Bytes; AvailLen: Integer; out Detail: TZydisInstructionDetail): Boolean;
var
  Info: TRawInfoBuf;
begin
  if (not ZydisAvailable) or (AvailLen <= 0) then begin
    Detail := Default(TZydisInstructionDetail);
    Exit(False);
  end;
  if not Assigned(GDecodeInstruction) then begin
    // The decode-only exports are not there: same facts, the slower way.
    var Unused: string;
    Exit(ZydisDecodeDetail(Mode, RuntimeAddress, Bytes, AvailLen, Detail, Unused));
  end;
  // No FillChar: a successful decode writes the whole struct, a failed one is
  // not read.
  if (not ZyanSucceeded(GDecodeInstruction(@GDecoders[Mode], nil, @Bytes,
        NativeUInt(AvailLen), @Info[0]))) or (PByte(@Info[0])[InfoLength] = 0) then begin
    Detail := Default(TZydisInstructionDetail);
    Exit(False);
  end;
  ReadDetail(@Info[0], Mode, RuntimeAddress, Detail);
  Result := True;
end;

initialization

finalization
  if GModule <> 0 then begin
    FreeLibrary(GModule);
    GModule := 0;
  end;

end.
