unit ZydisApi;

// Dynamic-load import unit for Zydis (ThirdParty\Zydis\bin\x64\Zydis.dll),
// the x86/x64 disassembler chosen in DISASSEMBLY_PLAN.md. This is an IMPORT
// UNIT, not a header translation: it declares only the two entry points a
// caller needs (ZydisDisassembleIntel, ZydisGetVersion) plus the byte offsets
// this unit reads out of Zydis's output struct.
//
// Load is explicit and dynamic (LoadLibrary), never a static import. A
// missing or incompatible DLL makes ZydisAvailable return False; nothing else
// in the debugger may notice. Call ZydisTryLoad once before using
// ZydisDecodeOne; it is idempotent -- the first call decides the outcome for
// the process lifetime.
//
// `ZydisDisassembledInstruction` (Zydis\Disassembler.h) has nested unions and
// C bitfields (ZydisDecodedInstruction, ZydisDecodedOperand[10]) that are not
// safely hand-transcribed field-by-field into a Pascal record -- a single
// wrong bitfield silently shifts every offset after it. Instead, the three
// facts this unit actually needs (total struct size, the byte-length field's
// offset, the formatted-text field's offset) were MEASURED with a throwaway
// C probe compiled against the pinned Zydis headers (`sizeof`/`offsetof` are
// compile-time constants, so no linking was needed). See PROVENANCE.md
// "Runtime version quirk" and the constants below for the measured values.
// Re-measure after ever repinning the submodule to a release with a
// different struct layout.

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

type
  TRawInstructionBuf = array[0..RawInstructionSize - 1] of Byte;

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

initialization

finalization
  if GModule <> 0 then begin
    FreeLibrary(GModule);
    GModule := 0;
  end;

end.
