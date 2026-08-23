program DisasmCoverage;

// Differential coverage sweep for the disassembly backend (docs/DISASSEMBLY_PLAN.md
// increment 3). Feeds the SAME bytes to Zydis (via IDisassembler /
// TZydisDisassembler, the production backend in DebuggerCore) and to an
// INDEPENDENT oracle -- dumpbin /DISASM:BYTES from the MSVC toolset -- over
// real compiled binaries, and reports every case where the two decoders
// disagree about WHAT AN INSTRUCTION IS. Formatting differences (operand
// syntax, hex casing, alias mnemonics such as je/jz) are normalised away
// first; only a genuine disagreement is counted as a divergence.
//
// Oracle choice: dumpbin, not XED. XED (intelxed/xed) was the plan's other
// candidate but is not installed on this machine and building it needs a
// Python + mbuild toolchain this project does not otherwise depend on.
// dumpbin ships with Visual Studio, is already used elsewhere in this repo
// (`dumpbin /exports`, PROVENANCE.md), and is reachable from a plain .bat via
// VsDevCmd.bat -- see run_disasm_coverage.bat.
//
// Methodology -- why a synthetic PE per module, not a raw byte compare:
//
//   dumpbin /DISASM has no "decode this byte range" mode: it disassembles an
//   entire section, LINEARLY, with no notion of instruction boundaries other
//   than its own decode. Delphi binaries embed real DATA directly inside the
//   .text section (RTTI/typeinfo string literals, jump tables, exception
//   tables), so a blind whole-image dumpbin run walks straight into that data,
//   decodes garbage, and its own address cursor desyncs from real code -- for
//   good, since nothing tells it where to resync. A raw whole-image compare
//   would therefore report thousands of "divergences" that are really just
//   dumpbin (or Zydis) guessing at data, which is exactly the sample-size trap
//   X86DecodeProbe already hit once (DevTools\README.md, X86DecodeProbe entry).
//
//   The fix is the same one X86DecodeProbe already uses for a DIFFERENT
//   purpose (proving X86Decode's lengths): anchor every span to a KNOWN
//   instruction boundary.
//
//     - When the module carries embedded TD32 debug info, every line-table
//       RVA is a proven instruction boundary (the compiler emitted a line for
//       it), so consecutive line-table RVAs within the same routine bound a
//       "line-to-line span" whose START and END are both verified real code.
//       This is the SAME anchor set X86DecodeProbe uses; see its
//       "line-to-line spans" comment.
//     - When the module ships with no debug info at all (the RTL/VCL runtime
//       packages, built for release), the PE export table still gives a
//       proven START (an export IS a real function entry by construction).
//       The END is NOT verified -- the span is capped at the next export's
//       RVA or a fixed byte budget, whichever is smaller, so it may run into
//       data before either decoder would naturally stop. Reported separately
//       as "export-anchored" so a reader can tell the two methodologies apart.
//
//   Every selected span's bytes are copied VERBATIM out of the real module
//   (the actual bytes the debuggee would execute) and concatenated into ONE
//   synthetic buffer, each span followed by a PAD_LEN run of $CC (INT3).
//   $CC as the first byte of any decode attempt is unconditionally a
//   single-byte INT3 in x86/x64 -- there is no multi-byte opcode beginning
//   with $CC in either engine -- so a run of 20 of them (comfortably more
//   than the 15-byte legal instruction-length ceiling) guarantees BOTH
//   decoders resynchronise to the same address by the next span's start,
//   regardless of how far either one drifted decoding the span itself. That
//   turns "did the two decoders even land on the same address" into its own
//   useful signal (a "boundary" divergence) instead of a design flaw.
//
//   The synthetic buffer is wrapped in a minimal hand-built PE (DOS header,
//   PE signature, one IMAGE_FILE_HEADER, one IMAGE_OPTIONAL_HEADER32/64, one
//   .text IMAGE_SECTION_HEADER, then the buffer as that section's raw data)
//   so dumpbin has something to load. Absolute addresses in dumpbin's output
//   are therefore synthetic (an arbitrary image base), never the module's own
//   -- irrelevant here, because only mnemonic identity and instruction length
//   are compared, never the resolved operand text.
//
// Divergence classes:
//   boundary  - at a Zydis instruction's own address, dumpbin has no
//               instruction starting there at all (its own walk disagreed
//               with Zydis's on an EARLIER instruction's length within this
//               span). The span comparison stops here; the pad guarantees the
//               NEXT span starts clean regardless.
//   length    - both decoders start at the same address but disagree on how
//               many bytes the instruction occupies. Comparison stops for the
//               rest of this span (alignment is gone).
//   refusal   - one decoder produced a mnemonic, the other refused (Zydis
//               'db XX' / dumpbin's bytes-only line with no mnemonic column).
//               The single most interesting class: a real per-decoder gap.
//   mnemonic  - both decoded the SAME LENGTH instruction but named it
//               differently after alias normalisation (je/jz, jc/jb, ...).
//               Comparison continues -- byte alignment is unaffected.
//
// Usage:
//   DisasmCoverage.exe <module1> [<module2> ...]
//     [-maxspan N]     export-anchored span cap in bytes (default 256)
//     [-sample N]      keep every Nth span per module (default 1: full sweep)
//     [-maxdivs N]     divergences printed per class per module (default 25)
//     [-dumpbin <path>] override dumpbin.exe location
//     [-zydisdll <path>] override Zydis.dll location
//     [-v] verbose: print every divergence, not just the first -maxdivs
//
// Prefer run_disasm_coverage.bat, which initialises the VS toolset first so
// dumpbin is found on PATH without needing -dumpbin.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.StrUtils, System.Math,
  System.Generics.Collections,
  Winapi.Windows,
  Disassembler      in '..\DebuggerCore\Disassembler.pas',
  ZydisApi          in '..\DebuggerCore\ZydisApi.pas',
  ZydisDisassembler in '..\DebuggerCore\ZydisDisassembler.pas',
  DebugInfoTypes    in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader    in '..\DebuggerCore\TD32FileReader.pas';

const
  IMAGE_FILE_MACHINE_I386  = $014C;
  IMAGE_FILE_MACHINE_AMD64 = $8664;
  PAD_LEN  = 20;   // > 15 (legal x86/x64 max instruction length) -- guarantees resync
  PAD_BYTE = $CC;  // INT3: unconditionally a 1-byte decode as the first byte read

type
  TImageSection = record
    VirtualAddr, VirtualSize, RawOffset, RawSize: DWORD;
  end;

  // Reads sections and (when present) the export table of a PE image. Not the
  // debugger's own PE reader -- deliberately self-contained, like every other
  // DevTools probe's PE parsing.
  TPEImage = class
  private
    FRaw: TBytes;
    FSections: TArray<TImageSection>;
    FMachine: Word;
    FDataDirRva:  array[0..15] of DWORD;
    FDataDirSize: array[0..15] of DWORD;
    FNumDataDirs: Integer;
  public
    constructor Create(const Path: string);
    // Returns the number of bytes actually placed (may be less than Size at a
    // section's raw-data edge) -- truncate, never fail, same discipline as
    // TDisasmByteReader.
    function ReadAt(Rva: UInt64; Buf: Pointer; Size: Integer): Integer;
    // Sorted, de-duplicated function entry RVAs from the export directory.
    // Forwarder entries (RVA points back inside the export directory itself,
    // i.e. a string, not code) are excluded.
    function ExportedFunctionRvas: TArray<UInt64>;
    property Machine: Word read FMachine;
  end;

constructor TPEImage.Create(const Path: string);
var
  PEOffset: DWORD;
  NumSections: Word;
  OptHeaderSize: Word;
  OptMagic: Word;
  DataDirBase: DWORD;
begin
  inherited Create;
  var F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(FRaw, F.Size);
    if Length(FRaw) > 0 then
      F.ReadBuffer(FRaw[0], Length(FRaw));
  finally
    F.Free;
  end;

  PEOffset := PCardinal(@FRaw[$3C])^;
  if PCardinal(@FRaw[PEOffset])^ <> $00004550 then
    raise Exception.Create('not a PE image: ' + Path);

  FMachine      := PWord(@FRaw[PEOffset + 4])^;
  NumSections   := PWord(@FRaw[PEOffset + 6])^;
  OptHeaderSize := PWord(@FRaw[PEOffset + 20])^;
  var OptBase := PEOffset + 24;
  OptMagic := PWord(@FRaw[OptBase])^;

  // DataDirectory[] sits right after the fixed optional-header fields: 96
  // bytes in for PE32 (Magic $10B), 112 bytes in for PE32+ (Magic $20B).
  if OptMagic = $20B then
    DataDirBase := OptBase + 112
  else
    DataDirBase := OptBase + 96;

  var NumRvaAndSizesOffset := DataDirBase - 4;
  var NumRvaAndSizes := PDWORD(@FRaw[NumRvaAndSizesOffset])^;
  FNumDataDirs := Min(Integer(NumRvaAndSizes), 16);
  for var I := 0 to FNumDataDirs - 1 do begin
    FDataDirRva[I]  := PDWORD(@FRaw[DataDirBase + UInt32(I) * 8])^;
    FDataDirSize[I] := PDWORD(@FRaw[DataDirBase + UInt32(I) * 8 + 4])^;
  end;

  var SecBase := OptBase + OptHeaderSize;
  SetLength(FSections, NumSections);
  for var I := 0 to NumSections - 1 do begin
    var P := SecBase + UInt32(I) * 40;
    FSections[I].VirtualSize := PDWORD(@FRaw[P + 8])^;
    FSections[I].VirtualAddr := PDWORD(@FRaw[P + 12])^;
    FSections[I].RawSize     := PDWORD(@FRaw[P + 16])^;
    FSections[I].RawOffset   := PDWORD(@FRaw[P + 20])^;
  end;
end;

function TPEImage.ReadAt(Rva: UInt64; Buf: Pointer; Size: Integer): Integer;
begin
  Result := 0;
  for var S in FSections do begin
    if (Rva < S.VirtualAddr) or (Rva >= UInt64(S.VirtualAddr) + S.VirtualSize) then
      Continue;
    var Delta := Rva - S.VirtualAddr;
    if Delta >= S.RawSize then
      Exit(0);
    var Avail: Int64 := Int64(S.RawSize) - Int64(Delta);
    if Avail > Size then
      Avail := Size;
    var Ofs := UInt64(S.RawOffset) + Delta;
    if Ofs + UInt64(Avail) > UInt64(Length(FRaw)) then
      Avail := Int64(Length(FRaw)) - Int64(Ofs);
    if Avail <= 0 then
      Exit(0);
    Move(FRaw[Ofs], Buf^, Avail);
    Exit(Integer(Avail));
  end;
end;

function TPEImage.ExportedFunctionRvas: TArray<UInt64>;
const
  DIR_LEN = 40;
var
  DirBuf: array[0..DIR_LEN - 1] of Byte;
begin
  SetLength(Result, 0);
  if FNumDataDirs < 1 then
    Exit;
  var ExportRva  := FDataDirRva[0];
  var ExportSize := FDataDirSize[0];
  if (ExportRva = 0) or (ExportSize = 0) then
    Exit;
  if ReadAt(ExportRva, @DirBuf[0], DIR_LEN) < DIR_LEN then
    Exit;

  var NumFuncs  := PDWORD(@DirBuf[20])^;
  var AddrFuncs := PDWORD(@DirBuf[28])^;

  var List := TList<UInt64>.Create;
  try
    for var I := 0 to Integer(NumFuncs) - 1 do begin
      var Rva: DWORD := 0;
      if ReadAt(UInt64(AddrFuncs) + UInt64(I) * 4, @Rva, 4) < 4 then
        Continue;
      if Rva = 0 then
        Continue;
      if (Rva >= ExportRva) and (Rva < ExportRva + ExportSize) then
        Continue;   // forwarder: points at a string inside the export dir, not code
      List.Add(Rva);
    end;
    List.Sort;
    var Uniq := TList<UInt64>.Create;
    try
      var Prev: UInt64 := High(UInt64);
      for var V in List do begin
        if V <> Prev then
          Uniq.Add(V);
        Prev := V;
      end;
      Result := Uniq.ToArray;
    finally
      Uniq.Free;
    end;
  finally
    List.Free;
  end;
end;

{ --------------------------------------------------------------- spans ---- }

type
  TAnchorKind = (akLineVerified, akExportOnly);

  TSpanDef = record
    OrigRva: UInt64;
    Len:     Integer;
    Kind:    TAnchorKind;
  end;

// Same construction X86DecodeProbe uses for its "line-to-line spans": group
// every TD32 line-table RVA by the routine that owns it, sort within the
// routine, and treat each consecutive pair as one span. Both ends are proven
// instruction boundaries -- the compiler emitted a source line for each.
function BuildLineAnchoredSpans(Reader: TTD32FileReader): TArray<TSpanDef>;
begin
  SetLength(Result, 0);
  var Map := TDictionary<UInt64, TList<UInt64>>.Create;
  try
    for var Rva in Reader.SortedRvas do begin
      var Start: UInt64;
      if not Reader.RvaToFunctionStart(Rva, Start) then
        Continue;
      var L: TList<UInt64>;
      if not Map.TryGetValue(Start, L) then begin
        L := TList<UInt64>.Create;
        Map.Add(Start, L);
      end;
      L.Add(Rva);
    end;

    var Spans := TList<TSpanDef>.Create;
    try
      for var Pair in Map do begin
        Pair.Value.Sort;
        var Rvas := Pair.Value.ToArray;
        for var I := 0 to High(Rvas) - 1 do begin
          if Rvas[I + 1] <= Rvas[I] then
            Continue;   // duplicate address for two source lines: nothing to decode
          var S: TSpanDef;
          S.OrigRva := Rvas[I];
          S.Len     := Integer(Rvas[I + 1] - Rvas[I]);
          S.Kind    := akLineVerified;
          Spans.Add(S);
        end;
      end;
      Result := Spans.ToArray;
    finally
      Spans.Free;
    end;
  finally
    for var L in Map.Values do
      L.Free;
    Map.Free;
  end;
end;

// Fallback for modules with no embedded debug info (the shipped RTL/VCL
// packages): each export is a proven function START. The end is NOT
// verified -- capped at the next export or MaxSpanBytes, whichever is
// smaller, so the window may still run into data (a jump table, a literal)
// before either decoder would naturally stop. Reported as its own anchor
// kind so a reader can tell the weaker methodology apart from line-verified
// spans.
function BuildExportAnchoredSpans(Img: TPEImage; MaxSpanBytes: Integer): TArray<TSpanDef>;
begin
  SetLength(Result, 0);
  var Rvas := Img.ExportedFunctionRvas;
  if Length(Rvas) = 0 then
    Exit;
  var Spans := TList<TSpanDef>.Create;
  try
    for var I := 0 to High(Rvas) do begin
      var Cap := MaxSpanBytes;
      if I < High(Rvas) then begin
        var Gap := Integer(Rvas[I + 1] - Rvas[I]);
        if (Gap > 0) and (Gap < Cap) then
          Cap := Gap;
      end;
      if Cap <= 0 then
        Continue;
      var S: TSpanDef;
      S.OrigRva := Rvas[I];
      S.Len     := Cap;
      S.Kind    := akExportOnly;
      Spans.Add(S);
    end;
    Result := Spans.ToArray;
  finally
    Spans.Free;
  end;
end;

function ApplySampling(const Spans: TArray<TSpanDef>; SampleEvery: Integer): TArray<TSpanDef>;
begin
  if SampleEvery <= 1 then
    Exit(Spans);
  var Kept := TList<TSpanDef>.Create;
  try
    var I := 0;
    while I <= High(Spans) do begin
      Kept.Add(Spans[I]);
      Inc(I, SampleEvery);
    end;
    Result := Kept.ToArray;
  finally
    Kept.Free;
  end;
end;

{ -------------------------------------------------------- synthetic PE ---- }

// Builds a minimal single-section PE (DOS header, PE signature, file header,
// optional header 32/64, one .text section header, then SectionBytes as that
// section's raw data) so dumpbin has an image to load. Addresses in the
// resulting file are synthetic -- only mnemonic identity and instruction
// length are ever compared against Zydis's decode of the SAME bytes.
function BuildSyntheticPE(Machine: Word; const SectionBytes: TBytes;
  out ImageBase: UInt64; out SectionRva: DWORD): TBytes;
const
  SECTION_ALIGN = $1000;
  FILE_ALIGN    = $1000;
var
  Is64: Boolean;
  OptHeaderSize: Word;
  HeadersLen: Integer;
  SizeOfHeaders: DWORD;
  SecSize, SecSizeAligned, SizeOfImage: DWORD;
  Characteristics: Word;
begin
  Is64 := Machine = IMAGE_FILE_MACHINE_AMD64;
  if Is64 then
    ImageBase := UInt64($140000000)
  else
    ImageBase := UInt64($00400000);

  OptHeaderSize := IfThen(Is64, 240, 224);
  HeadersLen := 64 {dos} + 4 {sig} + 20 {file hdr} + OptHeaderSize + 40 {one section hdr};
  SizeOfHeaders := DWORD(((HeadersLen + FILE_ALIGN - 1) div FILE_ALIGN) * FILE_ALIGN);
  SectionRva := SizeOfHeaders;

  SecSize := DWORD(Length(SectionBytes));
  SecSizeAligned := DWORD(((Int64(SecSize) + FILE_ALIGN - 1) div FILE_ALIGN) * FILE_ALIGN);
  SizeOfImage := DWORD(((Int64(SectionRva) + SecSize + SECTION_ALIGN - 1) div SECTION_ALIGN) * SECTION_ALIGN);

  Characteristics := $0002 or $0001 or $0004 or $0008;  // EXE|RELOCS_STRIPPED|LINE_NUMS_STRIPPED|LOCAL_SYMS_STRIPPED
  if Is64 then
    Characteristics := Characteristics or $0020          // LARGE_ADDRESS_AWARE
  else
    Characteristics := Characteristics or $0100;         // 32BIT_MACHINE

  var MS := TMemoryStream.Create;
  try
    var Dos: array[0..63] of Byte;
    FillChar(Dos, SizeOf(Dos), 0);
    Dos[0] := Ord('M');
    Dos[1] := Ord('Z');
    PDWORD(@Dos[$3C])^ := 64;   // e_lfanew: PE header starts right after this
    MS.WriteBuffer(Dos, SizeOf(Dos));

    var Sig: DWORD := $00004550;
    MS.WriteBuffer(Sig, 4);

    var W: Word;
    var D: DWORD;
    W := Machine;                MS.WriteBuffer(W, 2);
    W := 1;                      MS.WriteBuffer(W, 2);   // NumberOfSections
    D := 0;                      MS.WriteBuffer(D, 4);   // TimeDateStamp
    D := 0;                      MS.WriteBuffer(D, 4);   // PointerToSymbolTable
    D := 0;                      MS.WriteBuffer(D, 4);   // NumberOfSymbols
    W := OptHeaderSize;          MS.WriteBuffer(W, 2);
    W := Characteristics;        MS.WriteBuffer(W, 2);

    W := IfThen(Is64, $020B, $010B); MS.WriteBuffer(W, 2);  // Magic
    var B: Byte := 14; MS.WriteBuffer(B, 1);  // MajorLinkerVersion
    B := 0;             MS.WriteBuffer(B, 1);  // MinorLinkerVersion
    D := SecSizeAligned; MS.WriteBuffer(D, 4); // SizeOfCode
    D := 0; MS.WriteBuffer(D, 4);              // SizeOfInitializedData
    D := 0; MS.WriteBuffer(D, 4);              // SizeOfUninitializedData
    D := SectionRva; MS.WriteBuffer(D, 4);     // AddressOfEntryPoint
    D := SectionRva; MS.WriteBuffer(D, 4);     // BaseOfCode
    if not Is64 then begin
      D := SectionRva; MS.WriteBuffer(D, 4);   // BaseOfData (PE32 only)
    end;
    if Is64 then begin
      var Q: UInt64 := ImageBase; MS.WriteBuffer(Q, 8);
    end
    else begin
      D := DWORD(ImageBase); MS.WriteBuffer(D, 4);
    end;
    D := SECTION_ALIGN; MS.WriteBuffer(D, 4);
    D := FILE_ALIGN;    MS.WriteBuffer(D, 4);
    W := 6; MS.WriteBuffer(W, 2);   // MajorOperatingSystemVersion
    W := 0; MS.WriteBuffer(W, 2);
    W := 0; MS.WriteBuffer(W, 2);   // MajorImageVersion
    W := 0; MS.WriteBuffer(W, 2);
    W := 6; MS.WriteBuffer(W, 2);   // MajorSubsystemVersion
    W := 0; MS.WriteBuffer(W, 2);
    D := 0; MS.WriteBuffer(D, 4);   // Win32VersionValue
    D := SizeOfImage;    MS.WriteBuffer(D, 4);
    D := SizeOfHeaders;  MS.WriteBuffer(D, 4);
    D := 0; MS.WriteBuffer(D, 4);   // CheckSum
    W := 3; MS.WriteBuffer(W, 2);   // Subsystem = CUI
    W := 0; MS.WriteBuffer(W, 2);   // DllCharacteristics
    if Is64 then begin
      var Q: UInt64;
      Q := $100000; MS.WriteBuffer(Q, 8);   // SizeOfStackReserve
      Q := $1000;   MS.WriteBuffer(Q, 8);   // SizeOfStackCommit
      Q := $100000; MS.WriteBuffer(Q, 8);   // SizeOfHeapReserve
      Q := $1000;   MS.WriteBuffer(Q, 8);   // SizeOfHeapCommit
    end
    else begin
      D := $100000; MS.WriteBuffer(D, 4);
      D := $1000;   MS.WriteBuffer(D, 4);
      D := $100000; MS.WriteBuffer(D, 4);
      D := $1000;   MS.WriteBuffer(D, 4);
    end;
    D := 0;  MS.WriteBuffer(D, 4);   // LoaderFlags
    D := 16; MS.WriteBuffer(D, 4);   // NumberOfRvaAndSizes
    var Zero8: array[0..7] of Byte;
    FillChar(Zero8, 8, 0);
    for var K := 0 to 15 do
      MS.WriteBuffer(Zero8, 8);      // DataDirectory[16], all zero

    var Name8: array[0..7] of Byte;
    FillChar(Name8, 8, 0);
    Move(PAnsiChar('.text')^, Name8, 5);
    MS.WriteBuffer(Name8, 8);
    D := SecSize;         MS.WriteBuffer(D, 4);   // VirtualSize
    D := SectionRva;      MS.WriteBuffer(D, 4);   // VirtualAddress
    D := SecSizeAligned;  MS.WriteBuffer(D, 4);   // SizeOfRawData
    D := SizeOfHeaders;   MS.WriteBuffer(D, 4);   // PointerToRawData
    D := 0; MS.WriteBuffer(D, 4);   // PointerToRelocations
    D := 0; MS.WriteBuffer(D, 4);   // PointerToLinenumbers
    W := 0; MS.WriteBuffer(W, 2);   // NumberOfRelocations
    W := 0; MS.WriteBuffer(W, 2);   // NumberOfLinenumbers
    D := $60000020; MS.WriteBuffer(D, 4);   // CODE | EXECUTE | READ

    while MS.Size < SizeOfHeaders do begin
      B := 0;
      MS.WriteBuffer(B, 1);
    end;

    if SecSize > 0 then
      MS.WriteBuffer(SectionBytes[0], Length(SectionBytes));
    while MS.Size < Int64(SizeOfHeaders) + Int64(SecSizeAligned) do begin
      B := PAD_BYTE;
      MS.WriteBuffer(B, 1);
    end;

    SetLength(Result, MS.Size);
    Move(MS.Memory^, Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

{ ------------------------------------------------------------ Zydis pass -- }

function DecodeWholeBuffer(Mode: TDisasmMachineMode; const Buf: TBytes;
  SynthBase: UInt64; const DllPath: string): TArray<TDisasmInstruction>;
begin
  var Reader: TDisasmByteReader :=
    function(VA: UInt64; Dst: Pointer; Size: Integer): Integer
    begin
      var Offset := Int64(VA) - Int64(SynthBase);
      if (Offset < 0) or (Offset >= Length(Buf)) then
        Exit(0);
      var Avail := Int64(Length(Buf)) - Offset;
      if Avail > Size then
        Avail := Size;
      Move(Buf[Offset], Dst^, Avail);
      Result := Integer(Avail);
    end;

  var Disasm: IDisassembler := TZydisDisassembler.Create(Mode, Reader, nil, 0, DllPath);
  if not Disasm.Available then begin
    Writeln('FATAL: Zydis unavailable: ', Disasm.StatusText);
    Halt(9);
  end;
  Result := Disasm.Disassemble(SynthBase, Length(Buf));  // upper bound: >=1 byte/instruction
end;

{ ---------------------------------------------------------- dumpbin pass -- }

function FindOnPath(const ExeName: string): string;
var
  Buf: array[0..MAX_PATH] of Char;
  FilePart: PWideChar;
begin
  Result := '';
  FilePart := nil;
  if SearchPathW(nil, PChar(ExeName), nil, MAX_PATH, @Buf[0], FilePart) > 0 then
    Result := Buf;
end;

// Same fallback order Disasm.dpr uses: next to this exe, then the
// repo-relative ThirdParty\Zydis\bin\x64\Zydis.dll so a fresh build works
// without copying anything.
function DefaultZydisDllPath: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(ExtractFileDir(ParamStr(0)),
    '..\..\..\ThirdParty\Zydis\bin\x64\Zydis.dll'));
end;

function ResolveZydisDllPath(const OverridePath: string): string;
var
  NextToExe: string;
begin
  if OverridePath <> '' then
    Exit(OverridePath);
  NextToExe := TPath.Combine(ExtractFileDir(ParamStr(0)), 'Zydis.dll');
  if FileExists(NextToExe) then
    Exit(NextToExe);
  if FileExists(DefaultZydisDllPath) then
    Exit(DefaultZydisDllPath);
  Result := '';
end;

function ResolveDumpbinPath(const OverridePath: string): string;
const
  // Last-resort fallback for this dev machine's VS 2026 install, used only
  // when dumpbin is not already on PATH -- i.e. this tool was invoked
  // directly rather than through run_disasm_coverage.bat's VsDevCmd.bat.
  // Re-locate with `vswhere` (or `where dumpbin` inside a Developer Command
  // Prompt) and update this constant after a Visual Studio upgrade.
  FallbackPath = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\dumpbin.exe';
begin
  if OverridePath <> '' then
    Exit(OverridePath);
  var OnPath := FindOnPath('dumpbin.exe');
  if OnPath <> '' then
    Exit(OnPath);
  if FileExists(FallbackPath) then
    Exit(FallbackPath);
  Result := '';
end;

// Redirects the child's stdout/stderr STRAIGHT TO A FILE (never through an
// in-process pipe buffer), and returns only the exit code. A large sweep
// (the 497 MB Hydra2SingleEXE.exe, 2.3M+ spans) makes dumpbin emit gigabytes
// of disassembly text; accumulating that in one in-memory string overflowed
// Delphi's Integer-length string internals (measured: "EEncodingError:
// Invalid count (-1158168115)", a wrapped negative length) on the first full
// sweep attempt. Writing to disk and parsing it back as a STREAM (see
// ParseDumpbinFile) has no such ceiling.
function RunToFile(const CmdLine, WorkDir, OutFile: string): DWORD;
var
  SecAttr: TSecurityAttributes;
  OutHandle: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  FillChar(SecAttr, SizeOf(SecAttr), 0);
  SecAttr.nLength := SizeOf(SecAttr);
  SecAttr.bInheritHandle := True;
  OutHandle := CreateFile(PChar(OutFile), GENERIC_WRITE, FILE_SHARE_READ, @SecAttr,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if OutHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  SI.hStdOutput := OutHandle;
  SI.hStdError  := OutHandle;
  SI.hStdInput  := 0;

  var Cmd: string := CmdLine;
  UniqueString(Cmd);
  if not CreateProcess(nil, PChar(Cmd), nil, nil, True, 0, nil,
       PChar(WorkDir), SI, PI) then begin
    CloseHandle(OutHandle);
    RaiseLastOSError;
  end;
  CloseHandle(OutHandle);   // the child holds its own inherited copy

  WaitForSingleObject(PI.hProcess, INFINITE);
  GetExitCodeProcess(PI.hProcess, Result);
  CloseHandle(PI.hProcess);
  CloseHandle(PI.hThread);
end;

type
  TDumpbinEntry = record
    Len:     Integer;
    RawText: string;
    Decoded: Boolean;
  end;

function IsHexByteToken(const S: string): Boolean;
begin
  Result := (Length(S) = 2) and CharInSet(S[1], ['0'..'9', 'A'..'F', 'a'..'f'])
    and CharInSet(S[2], ['0'..'9', 'A'..'F', 'a'..'f']);
end;

function IsHexDigitsOnly(const S: string): Boolean;
begin
  Result := True;
  for var C in S do
    if not CharInSet(C, ['0'..'9', 'A'..'F', 'a'..'f']) then
      Exit(False);
end;

// Parses `dumpbin /DISASM:BYTES` output into address -> instruction. Each
// real line is "  <hexaddr>: <hex byte> <hex byte> ...  <mnemonic operands>";
// an undecodable byte prints with NO mnemonic column at all (dumpbin's own
// fail-closed behaviour, one byte at a time); a long instruction's extra
// bytes wrap onto a continuation line with no address prefix, pure hex
// tokens only, and are folded back into the previous entry's length.
procedure ProcessDumpbinLine(const RawLine: string; Dict: TDictionary<UInt64, TDumpbinEntry>;
  var LastVA: UInt64; var HaveLast: Boolean);
begin
  var Line := RawLine.TrimRight;
  if Line.Trim = '' then
    Exit;
  var ColonPos := Line.IndexOf(':');
  var IsAddrLine := False;
  var AddrHex := '';
  if (ColonPos > 0) and (ColonPos <= 18) then begin
    AddrHex := Line.Substring(0, ColonPos).Trim;
    IsAddrLine := (AddrHex.Length >= 4) and IsHexDigitsOnly(AddrHex);
  end;

  if IsAddrLine then begin
    var VA: UInt64;
    if not TryStrToUInt64('$' + AddrHex, VA) then
      Exit;
    var Rest := Line.Substring(ColonPos + 1).Trim;
    var Tokens := Rest.Split([' '], TStringSplitOptions.ExcludeEmpty);
    var ByteCount := 0;
    while (ByteCount < Length(Tokens)) and IsHexByteToken(Tokens[ByteCount]) do
      Inc(ByteCount);
    if ByteCount = 0 then
      Exit;   // not actually a byte-prefixed line -- ignore defensively
    var Mnem := '';
    for var I := ByteCount to High(Tokens) do begin
      if Mnem <> '' then
        Mnem := Mnem + ' ';
      Mnem := Mnem + Tokens[I];
    end;
    var E: TDumpbinEntry;
    E.Len     := ByteCount;
    E.RawText := Mnem;
    E.Decoded := Mnem <> '';
    Dict.AddOrSetValue(VA, E);
    LastVA := VA;
    HaveLast := True;
  end
  else begin
    // Continuation line: only valid if EVERY token is a hex-byte pair.
    var Tokens := Line.Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Tokens) = 0 then
      Exit;
    var AllHex := True;
    for var T in Tokens do
      if not IsHexByteToken(T) then begin
        AllHex := False;
        Break;
      end;
    if AllHex and HaveLast then begin
      var E := Dict[LastVA];
      Inc(E.Len, Length(Tokens));
      Dict[LastVA] := E;
    end;
    // Anything else (banner lines, "Summary", section-size rows) is simply
    // not a decode line -- skip it.
  end;
end;

// Streams the file line by line (TStreamReader, ANSI -- dumpbin's own
// output encoding) instead of ever materialising the whole dump as one
// in-memory string; see RunToFile for why that matters at Hydra2SingleEXE
// scale.
function ParseDumpbinFile(const Path: string): TDictionary<UInt64, TDumpbinEntry>;
var
  LastVA: UInt64;
  HaveLast: Boolean;
begin
  Result := TDictionary<UInt64, TDumpbinEntry>.Create;
  HaveLast := False;
  LastVA := 0;
  var Reader := TStreamReader.Create(Path, TEncoding.ANSI);
  try
    while not Reader.EndOfStream do
      ProcessDumpbinLine(Reader.ReadLine, Result, LastVA, HaveLast);
  finally
    Reader.Free;
  end;
end;

{ ------------------------------------------------------------ comparison -- }

type
  TDivKind = (dkNone, dkBoundary, dkLength, dkRefusal, dkMnemonic);

  TDivergence = record
    Va:      UInt64;   // synthetic address, inside the throwaway PE built for dumpbin
    OrigRva: UInt64;   // real RVA in the module under test -- use this to inspect real bytes
    Kind:    TDivKind;
    ZText, DText: string;
    ZLen, DLen: Integer;
  end;

  TCoverageStats = record
    LineSpans, ExportSpans: Integer;
    TotalSpans, CleanSpans: Integer;
    PositionsCompared: Integer;
    BoundaryDivs, LengthDivs, RefusalDivs, MnemonicDivs: Integer;
  end;

function DivKindName(K: TDivKind): string;
begin
  case K of
    dkBoundary: Result := 'boundary';
    dkLength:   Result := 'length';
    dkRefusal:  Result := 'refusal';
    dkMnemonic: Result := 'mnemonic';
  else
    Result := 'none';
  end;
end;

const
  // 'ht'/'hnt' (branch-hint-taken / branch-hint-not-taken, the historical
  // Pentium 4 2E/3E segment-override-as-hint prefixes on a Jcc) are
  // dumpbin-only spellings, measured on rtl290.bpl/vcl290.bpl -- Zydis's own
  // text carries no equivalent token at all for these.
  PREFIX_WORDS: array[0..14] of string = ('lock', 'rep', 'repe', 'repz', 'repne',
    'repnz', 'bnd', 'notrack', 'data16', 'addr32', 'addr16', 'xacquire', 'xrelease',
    'ht', 'hnt');

  // x86 condition-code synonym pairs: (alternate spelling, canonical
  // spelling). Applies to every mnemonic FAMILY that carries a condition
  // code suffix -- Jcc, SETcc, CMOVcc all use the same sixteen conditions,
  // and both decoders pick a spelling per instance rather than always the
  // same one within a family (measured: Zydis emits "setnz"/"setz" where
  // dumpbin emits "setne"/"sete" for the identical opcode). Extend this
  // table from real divergences found on real binaries -- do not guess ahead
  // of evidence.
  // Canonical spelling is always the one Zydis's own formatter emits (the
  // FBranchTargetRe whitelist in ZydisDisassembler.pas: jb/jnb/jz/jnz/jbe/
  // jnbe/js/jns/jp/jnp/jl/jnl/jle/jnle/jo/jno). Every entry here is
  // (alternate spelling -> that canonical one), one direction only -- an
  // earlier version of this table had both ('ge','nl') and ('nl','ge'),
  // which does not converge (whichever spelling appears gets flipped to the
  // OTHER one instead of both landing on the same string) and was caught by
  // this tool's own first real run against TestTarget.exe.
  CONDCODE_ALIASES: array[0..13] of array[0..1] of string = (
    ('c', 'b'), ('nae', 'b'), ('ae', 'nb'), ('nc', 'nb'),
    ('e', 'z'), ('ne', 'nz'),
    ('na', 'be'), ('a', 'nbe'),
    ('nge', 'l'), ('ge', 'nl'), ('ng', 'le'), ('g', 'nle'),
    ('pe', 'p'), ('po', 'np'));

  CONDITIONAL_PREFIXES: array[0..2] of string = ('j', 'set', 'cmov');

  // Standalone synonym pairs outside the Jcc/SETcc/CMOVcc condition-code
  // scheme above. 'wait'/'fwait' ($9B) measured on TestTarget.exe: dumpbin
  // names the plain x87 wait-for-FPU opcode "wait", Zydis names it "fwait" --
  // same historical instruction, two accepted spellings. 'aamb'/'aam' and
  // 'aadb'/'aad' ($D4/$D5 with the conventional imm8=0Ah operand) measured
  // on rtl290.bpl: dumpbin spells out the explicit byte-size suffix, Zydis
  // does not. 'sal'/'shl' ($D0-$D3/$C0-$C1 with reg field 100 or 110):
  // genuinely the SAME opcode under two names Intel's own manual lists side
  // by side -- dumpbin always says "sal", Zydis always says "shl".
  // 'fstpnce'/'fstp': one of the x87 unit's documented DUPLICATE opcode
  // encodings (see StripFpuDuplicateSuffix below for the digit-suffixed
  // half of this same family) -- Zydis names the alternate encoding
  // "fstpnce" ("no check exceptions"), dumpbin just tags it with a
  // different numeric suffix instead.
  MNEMONIC_ALIASES: array[0..6] of array[0..1] of string = (
    ('loopz', 'loope'), ('loopnz', 'loopne'), ('wait', 'fwait'),
    ('aamb', 'aam'), ('aadb', 'aad'), ('sal', 'shl'), ('fstpnce', 'fstp'));

  // String-move family: Zydis bakes the operand width into the mnemonic
  // (stosq/movsb/cmpsd/...); dumpbin keeps the base mnemonic and states the
  // width in the operand text instead ("stos qword ptr [rdi]"). Measured on
  // TestTarget.exe (STOSQ in the RTL's memory-fill routines) -- the FIRST
  // divergence class this tool ever found, and pure formatting, not a real
  // decode disagreement: both sides agree the instruction is REX.W AA.
  STRING_OP_BASES: array[0..6] of string = ('movs', 'cmps', 'stos', 'lods', 'scas', 'ins', 'outs');

function StripStringOpSizeSuffix(const M: string): string;
begin
  Result := M;
  for var Base in STRING_OP_BASES do
    if (Length(M) = Length(Base) + 1) and M.StartsWith(Base) and CharInSet(M[Length(M)], ['b', 'w', 'd', 'q']) then
      Exit(Base);
end;

// x87 has a handful of opcodes with more than one valid byte encoding for
// the identical operation (FCOM/FCOMP/FSTP/FXCH and a few others -- listed
// as "duplicate" entries in Intel's own opcode tables). dumpbin/MASM tags
// each duplicate with an arbitrary trailing digit to say WHICH byte
// encoding was used ("fcomp3" vs "fcomp5" for two different duplicate
// FCOMP bytes, both operating on the same ST(i) and nothing else differs);
// Zydis gives the base mnemonic a plain name (occasionally a different
// suffix like "fstpnce", handled via MNEMONIC_ALIASES instead since it is
// not a trailing digit). Stripping the digit collapses every duplicate
// encoding to the same base mnemonic on both sides -- correct here, because
// the point of this tool is "do the two decoders agree on the instruction",
// and two decoders both correctly recognising redundant hardware encodings
// of FCOMP are not disagreeing about anything.
function StripFpuDuplicateSuffix(const M: string): string;
begin
  Result := M;
  if (Length(M) < 2) or (M[1] <> 'f') then
    Exit;
  var L := Length(Result);
  while (L > 1) and CharInSet(Result[L], ['0'..'9']) do
    Dec(L);
  if L < Length(Result) then
    Result := Copy(Result, 1, L);
end;

// Several 8087/80287-era x87 opcodes (FENI, FDISI, FSETPM, ...) are
// architecturally no-ops from the 80387 onward. Zydis spells that out
// explicitly -- '<name><generation>_nop', e.g. 'feni8087_nop',
// 'fdisi8087_nop', 'fsetpm287_nop' (all three measured: the first two on
// rtl290.bpl, the third on Hydra2SingleEXE.exe) -- while dumpbin keeps the
// bare historical mnemonic. One general rule replaces what would otherwise
// be an ever-growing per-opcode alias list for this exact family.
function StripLegacyNopSuffix(const M: string): string;
const
  NopSuffix = '_nop';
begin
  Result := M;
  if not M.EndsWith(NopSuffix) then
    Exit;
  var L := Length(M) - Length(NopSuffix);
  while (L > 1) and CharInSet(M[L], ['0'..'9']) do
    Dec(L);
  Result := Copy(M, 1, L);
end;

// Canonicalises the condition-code SUFFIX of a Jcc/SETcc/CMOVcc mnemonic
// (e.g. 'setne' -> 'setnz'), leaving anything else (including 'jmp', which
// also starts with 'j' but carries no condition code) unchanged.
function CanonicalizeConditionCode(const M: string): string;
begin
  Result := M;
  for var Prefix in CONDITIONAL_PREFIXES do begin
    if not M.StartsWith(Prefix) then
      Continue;
    var Suffix := M.Substring(Length(Prefix));
    if Suffix = '' then
      Continue;
    for var Ai := 0 to High(CONDCODE_ALIASES) do
      if Suffix = CONDCODE_ALIASES[Ai][0] then
        Exit(Prefix + CONDCODE_ALIASES[Ai][1]);
    Exit;   // a conditional prefix, but the suffix is already canonical or unrecognised
  end;
end;

function NormMnemonic(const RawText: string; Decoded: Boolean): string;
begin
  if not Decoded then
    Exit('db');
  var Parts := RawText.Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) = 0 then
    Exit('');
  var I := 0;
  var M := LowerCase(Parts[I]);
  while (I < High(Parts)) and MatchStr(M, PREFIX_WORDS) do begin
    Inc(I);
    M := LowerCase(Parts[I]);
  end;

  // Two-token compound mnemonics: dumpbin/MASM spells these as ONE word,
  // Zydis's formatter emits mnemonic-plus-operand-looking-like-a-second-word.
  // 'int 3' ($CC) measured on rtl290.bpl: dumpbin -> "int 3", Zydis ->
  // "int3" for the SAME single-byte opcode (both already agreed on Length
  // by the time NormMnemonic runs, so this only fires for the true 1-byte
  // form, never the general 2-byte "int imm8"). 'ret far' ($CB) measured on
  // vcl290.bpl: dumpbin -> "retf", Zydis -> "ret far".
  // 'int3' ($CC, ALWAYS one fused Zydis token with no operand) must collapse
  // to plain 'int' so it matches dumpbin's always-separate 'int'+operand
  // spelling -- for BOTH the 1-byte $CC form ("int 3") and the 2-byte $CD
  // 03 form ("int 3" again, decimal; Zydis prints "int 0x03", hex). An
  // earlier version tried to detect this by checking whether the SECOND
  // token's VALUE was literally '3', which only matched dumpbin's decimal
  // spelling and not Zydis's hex one -- found on the FULL Hydra2SingleEXE.exe
  // sweep (2 377 660 spans), where it silently misclassified every 2-byte
  // "int 0x03"/"int 3" pair as a divergence. The fix does not look at the
  // operand at all, only at whether Zydis fused it into one token.
  if M = 'int3' then
    M := 'int';
  if (M = 'ret') and (I < High(Parts)) and (LowerCase(Parts[I + 1]) = 'far') then
    Exit('retf');

  M := StripStringOpSizeSuffix(M);
  M := StripLegacyNopSuffix(M);
  M := StripFpuDuplicateSuffix(M);
  M := CanonicalizeConditionCode(M);
  for var Ai := 0 to High(MNEMONIC_ALIASES) do
    if (M = MNEMONIC_ALIASES[Ai][0]) or (M = MNEMONIC_ALIASES[Ai][1]) then
      Exit(MNEMONIC_ALIASES[Ai][1]);   // canonicalise to the Zydis spelling
  Result := M;
end;

function ClassifyPosition(const Z: TDisasmInstruction; const DE: TDumpbinEntry;
  HaveEntry: Boolean): TDivKind;
begin
  if not HaveEntry then
    Exit(dkBoundary);
  if Z.Length <> DE.Len then
    Exit(dkLength);
  if Z.Decoded <> DE.Decoded then
    Exit(dkRefusal);
  if NormMnemonic(Z.Text, Z.Decoded) <> NormMnemonic(DE.RawText, DE.Decoded) then
    Exit(dkMnemonic);
  Result := dkNone;
end;

procedure CompareSpans(const Spans: TArray<TSpanDef>; const Offsets: TArray<Integer>;
  SynthBase: UInt64; const ZInsns: TArray<TDisasmInstruction>;
  DBin: TDictionary<UInt64, TDumpbinEntry>;
  var Stats: TCoverageStats; Divs: TList<TDivergence>; MaxDivsPerKind: Integer);
var
  Zi: Integer;
  DivCounts: array[TDivKind] of Integer;
begin
  Zi := 0;
  FillChar(DivCounts, SizeOf(DivCounts), 0);

  for var SpanIdx := 0 to High(Spans) do begin
    var SpanStart := SynthBase + UInt64(Offsets[SpanIdx]);
    var SpanEnd   := SpanStart + UInt64(Spans[SpanIdx].Len);

    while (Zi <= High(ZInsns)) and (ZInsns[Zi].VA < SpanStart) do
      Inc(Zi);

    Inc(Stats.TotalSpans);
    if Spans[SpanIdx].Kind = akLineVerified then
      Inc(Stats.LineSpans)
    else
      Inc(Stats.ExportSpans);

    if (Zi > High(ZInsns)) or (ZInsns[Zi].VA <> SpanStart) then
      Continue;   // should not happen given the pad guarantee; skip defensively

    var SpanClean := True;
    while (Zi <= High(ZInsns)) and (ZInsns[Zi].VA < SpanEnd) do begin
      var Z := ZInsns[Zi];
      Inc(Stats.PositionsCompared);
      var DE: TDumpbinEntry;
      var HaveEntry := DBin.TryGetValue(Z.VA, DE);
      var Kind := ClassifyPosition(Z, DE, HaveEntry);
      if Kind <> dkNone then begin
        SpanClean := False;
        case Kind of
          dkBoundary: Inc(Stats.BoundaryDivs);
          dkLength:   Inc(Stats.LengthDivs);
          dkRefusal:  Inc(Stats.RefusalDivs);
          dkMnemonic: Inc(Stats.MnemonicDivs);
        end;
        Inc(DivCounts[Kind]);
        if DivCounts[Kind] <= MaxDivsPerKind then begin
          var Dv: TDivergence;
          Dv.Va      := Z.VA;
          Dv.OrigRva := Spans[SpanIdx].OrigRva + (Z.VA - SpanStart);
          Dv.Kind    := Kind;
          Dv.ZText := Z.Text;
          Dv.ZLen  := Z.Length;
          if HaveEntry then begin
            Dv.DText := DE.RawText;
            Dv.DLen  := DE.Len;
          end
          else begin
            Dv.DText := '<no dumpbin instruction at this address>';
            Dv.DLen  := 0;
          end;
          Divs.Add(Dv);
        end;
      end;
      Inc(Zi);
      if Kind in [dkBoundary, dkLength] then
        Break;   // alignment lost for the rest of this span
    end;
    if SpanClean then
      Inc(Stats.CleanSpans);
  end;
end;

procedure MergeStats(var Grand: TCoverageStats; const M: TCoverageStats);
begin
  Inc(Grand.LineSpans, M.LineSpans);
  Inc(Grand.ExportSpans, M.ExportSpans);
  Inc(Grand.TotalSpans, M.TotalSpans);
  Inc(Grand.CleanSpans, M.CleanSpans);
  Inc(Grand.PositionsCompared, M.PositionsCompared);
  Inc(Grand.BoundaryDivs, M.BoundaryDivs);
  Inc(Grand.LengthDivs, M.LengthDivs);
  Inc(Grand.RefusalDivs, M.RefusalDivs);
  Inc(Grand.MnemonicDivs, M.MnemonicDivs);
end;

procedure PrintStats(const Stats: TCoverageStats; const Indent: string);
begin
  Writeln(Format('%sspans             : %d  (line-verified %d, export-anchored %d)',
    [Indent, Stats.TotalSpans, Stats.LineSpans, Stats.ExportSpans]));
  Writeln(Format('%sclean spans       : %d / %d (%.2f%%)',
    [Indent, Stats.CleanSpans, Stats.TotalSpans,
     Stats.CleanSpans * 100.0 / Max(Stats.TotalSpans, 1)]));
  Writeln(Format('%spositions compared: %d', [Indent, Stats.PositionsCompared]));
  Writeln(Format('%sdivergences       : boundary=%d (%.4f%%)  length=%d (%.4f%%)  refusal=%d (%.4f%%)  mnemonic=%d (%.4f%%)',
    [Indent, Stats.BoundaryDivs, Stats.BoundaryDivs * 100.0 / Max(Stats.PositionsCompared, 1),
     Stats.LengthDivs, Stats.LengthDivs * 100.0 / Max(Stats.PositionsCompared, 1),
     Stats.RefusalDivs, Stats.RefusalDivs * 100.0 / Max(Stats.PositionsCompared, 1),
     Stats.MnemonicDivs, Stats.MnemonicDivs * 100.0 / Max(Stats.PositionsCompared, 1)]));
end;

procedure PrintDivergences(Divs: TList<TDivergence>; MaxDivsPerKind: Integer);
begin
  if Divs.Count = 0 then
    Exit;
  Writeln(Format('  first %d divergence(s) per class (rva = real offset in the module under test):', [MaxDivsPerKind]));
  for var Dv in Divs do
    Writeln(Format('    [%-8s] rva=$%x  zydis="%s" (len %d)  dumpbin="%s" (len %d)',
      [DivKindName(Dv.Kind), Dv.OrigRva, Dv.ZText, Dv.ZLen, Dv.DText, Dv.DLen]));
end;

{ ------------------------------------------------------------------- run -- }

procedure RunModule(const Path, DumpbinPath, ZydisDllPath: string;
  MaxSpanBytes, SampleEvery, MaxDivsPerKind: Integer; var Grand: TCoverageStats);
begin
  Writeln('=== ', Path, ' ===');
  var Img := TPEImage.Create(Path);
  try
    var Mode: TDisasmMachineMode;
    case Img.Machine of
      IMAGE_FILE_MACHINE_I386:  Mode := dmmLegacy32;
      IMAGE_FILE_MACHINE_AMD64: Mode := dmmLong64;
    else
      Writeln(Format('  SKIP: unrecognised PE machine $%.4x', [Img.Machine]));
      Exit;
    end;

    var AllSpans: TArray<TSpanDef>;
    var MethodDesc: string;
    var Reader := TTD32FileReader.Create;
    try
      // LoadFromFile RAISES (does not just leave Loaded=False) when the PE
      // carries no .debug section at all -- the expected, normal case for a
      // shipped release RTL/VCL package. Treat that one specific failure as
      // "no debug info", exactly like a False Loaded, and fall back to the
      // export-anchored methodology; any OTHER exception is a real problem
      // and must still propagate.
      try
        Reader.LoadFromFile(Path);
      except
        on E: Exception do begin
          if not E.Message.StartsWith('No .debug section') then
            raise;
        end;
      end;
      if Reader.Loaded then begin
        AllSpans := BuildLineAnchoredSpans(Reader);
        MethodDesc := 'TD32 line-to-line spans (start and end both verified)';
      end
      else begin
        AllSpans := BuildExportAnchoredSpans(Img, MaxSpanBytes);
        MethodDesc := Format('PE export table (start verified only; window capped at %d bytes or the next export)',
          [MaxSpanBytes]);
      end;
    finally
      Reader.Free;
    end;

    var TotalBeforeSample := Length(AllSpans);
    var Spans := ApplySampling(AllSpans, SampleEvery);
    Writeln(Format('  mode=%s  anchors=%s',
      [IfThen(Mode = dmmLong64, 'long64', 'legacy32'), MethodDesc]));
    if SampleEvery > 1 then
      Writeln(Format('  SAMPLED: %d of %d spans (every %dth span, %.2f%% of total)',
        [Length(Spans), TotalBeforeSample, SampleEvery, Length(Spans) * 100.0 / Max(TotalBeforeSample, 1)]))
    else
      Writeln(Format('  full sweep: %d spans (no sampling)', [Length(Spans)]));

    if Length(Spans) = 0 then begin
      Writeln('  (no spans found -- nothing to compare)');
      Exit;
    end;

    var Buf: TBytes := nil;
    var Offsets: TArray<Integer>;
    SetLength(Offsets, Length(Spans));
    for var I := 0 to High(Spans) do begin
      Offsets[I] := Length(Buf);
      var SpanBytes: TBytes;
      SetLength(SpanBytes, Spans[I].Len);
      var Got := Img.ReadAt(Spans[I].OrigRva, @SpanBytes[0], Spans[I].Len);
      if Got < Spans[I].Len then
        SetLength(SpanBytes, Max(Got, 0));
      Buf := Buf + SpanBytes;
      var Pad: TBytes;
      SetLength(Pad, PAD_LEN);
      FillChar(Pad[0], PAD_LEN, PAD_BYTE);
      Buf := Buf + Pad;
    end;

    var ImageBase: UInt64;
    var SectionRva: DWORD;
    var SynthPE := BuildSyntheticPE(Img.Machine, Buf, ImageBase, SectionRva);
    var SynthBase := ImageBase + SectionRva;

    var TmpFile := TPath.Combine(TPath.GetTempPath,
      'DisasmCoverage_' + ChangeFileExt(ExtractFileName(Path), '') + '_' +
      IntToStr(GetCurrentProcessId) + '.exe');
    var FS := TFileStream.Create(TmpFile, fmCreate);
    try
      FS.WriteBuffer(SynthPE[0], Length(SynthPE));
    finally
      FS.Free;
    end;

    var ZInsns := DecodeWholeBuffer(Mode, Buf, SynthBase, ZydisDllPath);

    var DumpTxtFile := ChangeFileExt(TmpFile, '.dumpbin.txt');
    var ExitCode := RunToFile(
      Format('"%s" /NOLOGO /DISASM:BYTES "%s"', [DumpbinPath, TmpFile]),
      ExtractFilePath(TmpFile), DumpTxtFile);
    var DBin := ParseDumpbinFile(DumpTxtFile);
    try
      System.SysUtils.DeleteFile(TmpFile);
      System.SysUtils.DeleteFile(DumpTxtFile);

      var Stats := Default(TCoverageStats);
      var Divs := TList<TDivergence>.Create;
      try
        CompareSpans(Spans, Offsets, SynthBase, ZInsns, DBin, Stats, Divs, MaxDivsPerKind);
        PrintStats(Stats, '  ');
        PrintDivergences(Divs, MaxDivsPerKind);
        MergeStats(Grand, Stats);
      finally
        Divs.Free;
      end;
    finally
      DBin.Free;
    end;
  finally
    Img.Free;
  end;
  Writeln;
end;

{ ------------------------------------------------------------------- main - }

procedure Run;
begin
  var Args: TArray<string>;
  SetLength(Args, ParamCount);
  for var I := 1 to ParamCount do
    Args[I - 1] := ParamStr(I);

  var DumpbinArg := '';
  var ZydisDllArg := '';
  var MaxSpanBytes := 256;
  var SampleEvery := 1;
  var MaxDivsPerKind := 25;
  for var I := High(Args) downto 0 do begin
    if SameText(Args[I], '-dumpbin') and (I < High(Args)) then begin
      DumpbinArg := Args[I + 1];
      Delete(Args, I, 2);
    end
    else if SameText(Args[I], '-zydisdll') and (I < High(Args)) then begin
      ZydisDllArg := Args[I + 1];
      Delete(Args, I, 2);
    end
    else if SameText(Args[I], '-maxspan') and (I < High(Args)) then begin
      MaxSpanBytes := StrToIntDef(Args[I + 1], MaxSpanBytes);
      Delete(Args, I, 2);
    end
    else if SameText(Args[I], '-sample') and (I < High(Args)) then begin
      SampleEvery := StrToIntDef(Args[I + 1], SampleEvery);
      Delete(Args, I, 2);
    end
    else if SameText(Args[I], '-maxdivs') and (I < High(Args)) then begin
      MaxDivsPerKind := StrToIntDef(Args[I + 1], MaxDivsPerKind);
      Delete(Args, I, 2);
    end;
  end;

  if Length(Args) = 0 then begin
    Writeln('Usage: DisasmCoverage.exe <module1> [<module2> ...] [-maxspan N] [-sample N] [-maxdivs N] [-dumpbin <path>] [-zydisdll <path>]');
    Halt(1);
  end;

  var DumpbinPath := ResolveDumpbinPath(DumpbinArg);
  if DumpbinPath = '' then begin
    Writeln('FATAL: dumpbin.exe not found on PATH and no -dumpbin given. ' +
      'Run via run_disasm_coverage.bat, or pass -dumpbin <path>.');
    Halt(2);
  end;
  Writeln('dumpbin: ', DumpbinPath);
  Writeln;

  var Grand := Default(TCoverageStats);
  for var ModPath in Args do begin
    if not FileExists(ModPath) then begin
      Writeln('=== ', ModPath, ' === SKIP: file not found');
      Continue;
    end;
    RunModule(ModPath, DumpbinPath, ResolveZydisDllPath(ZydisDllArg), MaxSpanBytes, SampleEvery, MaxDivsPerKind, Grand);
  end;

  Writeln('=== TOTAL across all modules ===');
  PrintStats(Grand, '  ');
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.ClassName, ': ', E.Message);
      Halt(9);
    end;
  end;
end.
