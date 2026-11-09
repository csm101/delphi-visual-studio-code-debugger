unit PeSymbolSupport;

// Small PE-geometry + symbol-file-freshness helpers shared by every frontend's
// module loader. These were copy-pasted in TDapServer and TDebugSession; kept in
// one place so a fix (e.g. the staleness grace window) can't drift between copies.

interface

// Reads the PE OptionalHeader SizeOfImage (offset $38 for both HDR32/HDR64) so a
// module's provider can be scoped to the RVA range [0, ImageSize). 0 on failure.
function ReadPEImageSize(const ExePath: string): UInt64;

// Reads the PE OptionalHeader Subsystem (IMAGE_SUBSYSTEM_*, offset $44 for both
// HDR32/HDR64) before the process exists: a console program has to be launched
// with standard handles of its own. 0 on failure.
function ReadPESubsystem(const ExePath: string): Word;

// True when a symbol sidecar (.rsm / .map / .dcp) is older than its binary, so the
// loader should ignore it and fall back to fresher sources. A 2-second grace
// avoids a same-build write-order race; missing files / errors are treated as
// not-stale (do not block a load on a timestamp hiccup).
function SymbolFileIsStale(const SymPath, BinPath: string): Boolean;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.DateUtils, Winapi.Windows;

function IsKnownOptionalHeaderMagic(Magic: Word): Boolean;
begin
  if Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC then
    Exit(True);
  Result := Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
end;

// The Size-byte field (at most 4) at Offset from the start of an on-disk image's
// OptionalHeader, or 0. Only for fields at the same offset in HDR32 and HDR64,
// which is every field from SectionAlignment ($20) to DllCharacteristics ($46):
// HDR64 widens ImageBase by exactly the 4 bytes it drops with BaseOfData.
function ReadOptionalHeaderField(const ExePath: string; Offset, Size: Integer): Cardinal;
var
  FS: TFileStream;
  Dos: TImageDosHeader;
  NtSig: Cardinal;
  FileHdr: TImageFileHeader;
  OptMagic: Word;
begin
  Result := 0;
  if not FileExists(ExePath) then
    Exit;
  FS := TFileStream.Create(ExePath, fmOpenRead or fmShareDenyNone);
  try
    if FS.Size < SizeOf(TImageDosHeader) then
      Exit;
    FS.ReadBuffer(Dos, SizeOf(Dos));
    if Dos.e_magic <> IMAGE_DOS_SIGNATURE then
      Exit;
    FS.Position := Dos._lfanew;
    if FS.Position + 4 + SizeOf(FileHdr) + 2 > FS.Size then
      Exit;
    FS.ReadBuffer(NtSig, 4);
    if NtSig <> IMAGE_NT_SIGNATURE then
      Exit;
    FS.ReadBuffer(FileHdr, SizeOf(FileHdr));
    FS.ReadBuffer(OptMagic, SizeOf(OptMagic));
    if not IsKnownOptionalHeaderMagic(OptMagic) then
      Exit;
    FS.Position := Dos._lfanew + 4 + SizeOf(FileHdr) + Offset;
    FS.ReadBuffer(Result, Size);
  finally
    FS.Free;
  end;
end;

function ReadPEImageSize(const ExePath: string): UInt64;
begin
  Result := ReadOptionalHeaderField(ExePath, $38, SizeOf(Cardinal));
end;

function ReadPESubsystem(const ExePath: string): Word;
begin
  Result := Word(ReadOptionalHeaderField(ExePath, $44, SizeOf(Word)));
end;

function SymbolFileIsStale(const SymPath, BinPath: string): Boolean;
begin
  Result := False;
  if (SymPath = '') or (BinPath = '') then Exit;
  if (not FileExists(SymPath)) or (not FileExists(BinPath)) then Exit;
  try
    // 2-second grace so a same-build-step write-order race doesn't false-positive.
    Result := TFile.GetLastWriteTime(SymPath) <
              IncSecond(TFile.GetLastWriteTime(BinPath), -2);
  except
    Result := False;
  end;
end;

end.
