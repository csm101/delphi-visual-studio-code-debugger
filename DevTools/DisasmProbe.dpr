program DisasmProbe;

// Proves the Zydis pipeline end to end (DISASSEMBLY_PLAN.md increment 1):
// loads the committed Zydis.dll, reads real bytes out of a real PE image at a
// caller-given RVA, and decodes a run of instructions through
// DebuggerCore\ZydisApi.pas. No feature lives here -- IDisassembler and
// symbolication are increment 2.
//
// Usage:
//   DisasmProbe.exe <exe> <hexRVA> [count] [-mode long64|legacy32] [-zydisdll <path>]
//
// <exe>     any PE image (EXE or DLL), 32-bit or 64-bit.
// <hexRVA>  where to start decoding, hex, with or without a "0x"/"$" prefix.
// [count]   how many instructions to decode (default 10).
// -mode     overrides the machine mode Zydis decodes with. Default: read from
//           the image's own PE header (IMAGE_FILE_HEADER.Machine) -- never
//           assume the host's bitness, exactly like the real IDisassembler
//           will (DISASSEMBLY_PLAN.md "The seam").
// -zydisdll overrides where Zydis.dll is loaded from. Default: the normal
//           Windows DLL search order (this exe's own directory, then PATH);
//           if that finds nothing, falls back to the repo-relative
//           ThirdParty\Zydis\bin\x64\Zydis.dll so the probe works from a
//           fresh build without copying anything.
//
// Example (prove BOTH machine modes -- run once per real binary):
//   DisasmProbe.exe DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe 1000 8
//   DisasmProbe.exe DebuggerTests\TestTarget\Win32\Debug\TestTarget.exe 1000 8
// Each invocation auto-detects its own machine mode from the PE header, so
// the pair proves the SAME x64 Zydis.dll decodes both a native 64-bit image
// and a 32-bit (WOW64) image correctly -- the case that matters for this
// project, since the adapter is one 64-bit process debugging either bitness.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows,
  ZydisApi in '..\DebuggerCore\ZydisApi.pas';

const
  IMAGE_FILE_MACHINE_I386  = $014C;
  IMAGE_FILE_MACHINE_AMD64 = $8664;

type
  TImageSection = record
    Name:        string;
    VirtualAddr: DWORD;
    VirtualSize: DWORD;
    RawOffset:   DWORD;
    RawSize:     DWORD;
  end;

function ReadPEMachine(const Path: string): Word;
var
  F: TFileStream;
  DosHeader: array[0..63] of Byte;
  PEOffset: DWORD;
  Sig: DWORD;
begin
  Result := 0;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    F.ReadBuffer(DosHeader, SizeOf(DosHeader));
    PEOffset := PCardinal(@DosHeader[$3C])^;
    F.Position := PEOffset;
    F.ReadBuffer(Sig, SizeOf(Sig));
    if Sig <> $00004550 then
      Exit;
    F.ReadBuffer(Result, SizeOf(Result));  // IMAGE_FILE_HEADER.Machine, first field after the PE signature
  finally
    F.Free;
  end;
end;

function ReadSections(const Path: string): TArray<TImageSection>;
var
  F: TFileStream;
  DosHeader: array[0..63] of Byte;
  PEOffset: DWORD;
  Sig: DWORD;
  NumSectionsW: Word;
  OptHeaderSize: Word;
  SectionRaw: array[0..39] of Byte;
begin
  SetLength(Result, 0);
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    F.ReadBuffer(DosHeader, SizeOf(DosHeader));
    PEOffset := PCardinal(@DosHeader[$3C])^;
    F.Position := PEOffset;
    F.ReadBuffer(Sig, SizeOf(Sig));
    if Sig <> $00004550 then
      Exit;
    F.Position := PEOffset + 4 + 2;
    F.ReadBuffer(NumSectionsW, SizeOf(NumSectionsW));
    F.Position := PEOffset + 4 + 16;
    F.ReadBuffer(OptHeaderSize, SizeOf(OptHeaderSize));
    F.Position := PEOffset + 4 + 20 + OptHeaderSize;
    SetLength(Result, NumSectionsW);
    for var I := 0 to NumSectionsW - 1 do begin
      F.ReadBuffer(SectionRaw, SizeOf(SectionRaw));
      var S: TImageSection;
      var NameBytes: array[0..7] of AnsiChar;
      Move(SectionRaw[0], NameBytes, 8);
      S.Name        := string(NameBytes);
      S.VirtualSize := PDWORD(@SectionRaw[8])^;
      S.VirtualAddr := PDWORD(@SectionRaw[12])^;
      S.RawSize     := PDWORD(@SectionRaw[16])^;
      S.RawOffset   := PDWORD(@SectionRaw[20])^;
      Result[I] := S;
    end;
  finally
    F.Free;
  end;
end;

function RvaToFileOffset(const Sections: TArray<TImageSection>; RVA: DWORD;
  out Found: Boolean): DWORD;
begin
  Found := False;
  Result := 0;
  for var S in Sections do
    if (RVA >= S.VirtualAddr) and (RVA < S.VirtualAddr + S.VirtualSize) then begin
      Result := S.RawOffset + (RVA - S.VirtualAddr);
      Found := True;
      Exit;
    end;
end;

function ReadWindow(const Path: string; FileOffset: Int64; Len: Integer): TBytes;
var
  F: TFileStream;
  Avail: Int64;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    Avail := F.Size - FileOffset;
    if Avail < 0 then
      Avail := 0;
    if Avail < Len then
      Len := Avail;
    SetLength(Result, Len);
    if Len > 0 then begin
      F.Position := FileOffset;
      F.ReadBuffer(Result[0], Len);
    end;
  finally
    F.Free;
  end;
end;

function DefaultZydisDllPath: string;
begin
  // Repo-relative fallback: DevTools\Win64\<Config>\DisasmProbe.exe is three
  // levels below the repo root. Used only when the bare-name search (this
  // exe's own directory, then PATH) finds nothing.
  Result := TPath.GetFullPath(TPath.Combine(ExtractFileDir(ParamStr(0)),
    '..\..\..\ThirdParty\Zydis\bin\x64\Zydis.dll'));
end;

function ParseHexArg(const S: string): UInt64;
var
  Cleaned: string;
begin
  Cleaned := S;
  if Cleaned.StartsWith('0x', True) then
    Cleaned := Cleaned.Substring(2)
  else if Cleaned.StartsWith('$') then
    Cleaned := Cleaned.Substring(1);
  Result := StrToUInt64('$' + Cleaned);
end;

function ParseModeOverride(const S: string; out Mode: TZydisMachineMode): Boolean;
begin
  Result := True;
  if SameText(S, 'long64') then
    Mode := zmmLong64
  else if SameText(S, 'legacy32') then
    Mode := zmmLegacy32
  else
    Result := False;
end;

function ModeName(Mode: TZydisMachineMode): string;
begin
  case Mode of
    zmmLong64:       Result := 'long64 (64-bit)';
    zmmLongCompat32: Result := 'longcompat32';
    zmmLongCompat16: Result := 'longcompat16';
    zmmLegacy32:     Result := 'legacy32 (32-bit)';
    zmmLegacy16:     Result := 'legacy16';
    zmmReal16:       Result := 'real16';
  else
    Result := 'unknown';
  end;
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
  Result := '';  // nothing found; let ZydisTryLoad's bare-name search have the final say
end;

procedure LoadZydisOrDie(const ExplicitPath: string);
var
  Loaded: Boolean;
begin
  // ZydisTryLoad is single-attempt (by design -- see ZydisApi.pas), so the
  // probe resolves the path to try up front rather than retrying with a
  // second call.
  Loaded := ZydisTryLoad(ResolveZydisDllPath(ExplicitPath));
  Writeln(ZydisStatusText);
  if not Loaded then begin
    Writeln('FATAL: Zydis unavailable, cannot prove anything.');
    Halt(1);
  end;
end;

procedure Run;
var
  ExePath, ModeArg, DllArg: string;
  RVA: UInt64;
  Count: Integer;
  I: Integer;
  Mode: TZydisMachineMode;
  Machine: Word;
  Sections: TArray<TImageSection>;
  Found: Boolean;
  FileOffset: DWORD;
  Window: TBytes;
  Cursor: UInt64;
  WindowPos: Integer;
  Insn: TZydisInstruction;
  BytesText: string;
begin
  if ParamCount < 2 then begin
    Writeln('Usage: DisasmProbe.exe <exe> <hexRVA> [count] [-mode long64|legacy32] [-zydisdll <path>]');
    Halt(1);
  end;

  ExePath := ParamStr(1);
  RVA := ParseHexArg(ParamStr(2));
  Count := 10;
  ModeArg := '';
  DllArg := '';

  I := 3;
  while I <= ParamCount do begin
    if SameText(ParamStr(I), '-mode') and (I < ParamCount) then begin
      ModeArg := ParamStr(I + 1);
      Inc(I, 2);
    end
    else if SameText(ParamStr(I), '-zydisdll') and (I < ParamCount) then begin
      DllArg := ParamStr(I + 1);
      Inc(I, 2);
    end
    else begin
      Count := StrToInt(ParamStr(I));
      Inc(I);
    end;
  end;

  LoadZydisOrDie(DllArg);

  Machine := ReadPEMachine(ExePath);
  case Machine of
    IMAGE_FILE_MACHINE_I386:  Mode := zmmLegacy32;
    IMAGE_FILE_MACHINE_AMD64: Mode := zmmLong64;
  else
    Writeln(Format('FATAL: %s has unrecognised PE machine $%.4x', [ExePath, Machine]));
    Halt(2);
  end;
  Writeln(Format('%s: PE machine $%.4x -> auto mode %s', [ExtractFileName(ExePath), Machine, ModeName(Mode)]));

  if ModeArg <> '' then begin
    if not ParseModeOverride(ModeArg, Mode) then begin
      Writeln('FATAL: unknown -mode value "', ModeArg, '" (expected long64 or legacy32)');
      Halt(2);
    end;
    Writeln('  -mode override -> ', ModeName(Mode));
  end;

  Sections := ReadSections(ExePath);
  FileOffset := RvaToFileOffset(Sections, DWORD(RVA), Found);
  if not Found then begin
    Writeln(Format('FATAL: RVA $%.x is not inside any section of %s', [RVA, ExePath]));
    Halt(2);
  end;

  // 15 bytes is ZYDIS_MAX_INSTRUCTION_LENGTH; read a generous window so the
  // last instruction in the run never gets truncated at the buffer edge.
  Window := ReadWindow(ExePath, FileOffset, Count * 15 + 15);
  if Length(Window) = 0 then begin
    Writeln('FATAL: nothing readable at that RVA (past end of section/file)');
    Halt(2);
  end;

  Writeln(Format('Decoding %d instruction(s) from RVA $%.x (%d bytes available):', [Count, RVA, Length(Window)]));
  Cursor := RVA;
  WindowPos := 0;
  for I := 1 to Count do begin
    if WindowPos >= Length(Window) then begin
      Writeln('  (ran out of window bytes)');
      Break;
    end;
    if not ZydisDecodeOne(Mode, Cursor, Window[WindowPos], Length(Window) - WindowPos, Insn) then begin
      Writeln(Format('  $%.8x  db %.2x                 ; undecodable', [Cursor, Window[WindowPos]]));
      Inc(Cursor);
      Inc(WindowPos);
      Continue;
    end;
    BytesText := '';
    for var B := 0 to Insn.Length - 1 do
      BytesText := BytesText + IntToHex(Window[WindowPos + B], 2) + ' ';
    Writeln(Format('  $%.8x  %-24s  %s', [Cursor, BytesText.TrimRight, Insn.Text]));
    Inc(Cursor, Insn.Length);
    Inc(WindowPos, Insn.Length);
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.ClassName, ': ', E.Message);
      Halt(3);
    end;
  end;
end.
