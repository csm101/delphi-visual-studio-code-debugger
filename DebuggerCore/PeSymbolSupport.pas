unit PeSymbolSupport;

// Small PE-geometry + symbol-file-freshness helpers shared by every frontend's
// module loader. These were copy-pasted in TDapServer and TDebugSession; kept in
// one place so a fix (e.g. the staleness grace window) can't drift between copies.

interface

// Reads the PE OptionalHeader SizeOfImage (offset $38 for both HDR32/HDR64) so a
// module's provider can be scoped to the RVA range [0, ImageSize). 0 on failure.
function ReadPEImageSize(const ExePath: string): UInt64;

// True when a symbol sidecar (.rsm / .map / .dcp) is older than its binary, so the
// loader should ignore it and fall back to fresher sources. A 2-second grace
// avoids a same-build write-order race; missing files / errors are treated as
// not-stale (do not block a load on a timestamp hiccup).
function SymbolFileIsStale(const SymPath, BinPath: string): Boolean;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.DateUtils, Winapi.Windows;

function ReadPEImageSize(const ExePath: string): UInt64;
var
  FS: TFileStream;
  Dos: TImageDosHeader;
  NtSig: Cardinal;
  FileHdr: TImageFileHeader;
  OptMagic: Word;
  SizeOfImage32: Cardinal;
  SizeOfImage64: Cardinal;
begin
  Result := 0;
  if not FileExists(ExePath) then
    Exit;
  FS := TFileStream.Create(ExePath, fmOpenRead or fmShareDenyWrite);
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
    case OptMagic of
      IMAGE_NT_OPTIONAL_HDR32_MAGIC: begin
        FS.Position := Dos._lfanew + 4 + SizeOf(FileHdr) + $38;
        FS.ReadBuffer(SizeOfImage32, 4);
        Result := SizeOfImage32;
      end;
      IMAGE_NT_OPTIONAL_HDR64_MAGIC: begin
        FS.Position := Dos._lfanew + 4 + SizeOf(FileHdr) + $38;
        FS.ReadBuffer(SizeOfImage64, 4);
        Result := SizeOfImage64;
      end;
    end;
  finally
    FS.Free;
  end;
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
