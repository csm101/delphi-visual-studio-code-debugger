program JclProbe;

// Surveys whether a PE binary carries JCL debug information and what it holds.
//
// The tool accepts either a PE image (exe/dll/bpl) or a standalone .jdbg file.
// For a PE it looks first for a linked 'JCLDEBUG' section and falls back to a
// sidecar .jdbg next to the image. Whatever it finds is handed to
// TJclBinDebugScanner, and the proc-name table is enumerated -- counting the
// mangled nested-procedure publics ("$", "_ZZ", "$pdata$", "$unwind$") that
// matter for outer-scope local resolution.
//
// Doubles as a link check that JclDebug compiles for Win64 in this toolchain.
//
// Usage: JclProbe.exe <pe-or-jdbg-file>
// Example: JclProbe.exe Win64\Debug\Debugme.exe

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.AnsiStrings, System.Classes, Winapi.Windows,
  JclDebug;

type
  // Local copy of JCL's 6-bit name decoder (implementation-private in JclDebug).
  // Kept in sync with DecodeNameString in JclDebug.pas.
  TDecodeBuffer = array[0..255] of AnsiChar;

const
  MaxSampleNames = 30;

function SimpleCryptStr(const S: RawByteString): RawByteString;
begin
  SetLength(Result, Length(S));
  for var I := 1 to Length(S) do begin
    var C := Byte(S[I]);
    if C <> $AA then
      C := C xor $AA;
    Result[I] := AnsiChar(C);
  end;
end;

function DecodeName(S: PAnsiChar): string;
var
  Buffer: TDecodeBuffer;
begin
  Result := '';
  var Used := 0;
  var P := PByte(S);
  case P^ of
    1:
      begin
        Inc(P);
        var Raw: RawByteString := PAnsiChar(P);
        Exit(UTF8ToString(SimpleCryptStr(Raw)));
      end;
    2:
      begin
        Inc(P);
        Buffer[Used] := '@';
        Inc(Used);
      end;
  end;

  var Index := 0;
  var C: Byte := 0;
  repeat
    case Index and $03 of
      0: C := P^ and $3F;
      1: begin
           C := (P^ shr 6) and $03;
           Inc(P);
           Inc(C, (P^ and $0F) shl 2);
         end;
      2: begin
           C := (P^ shr 4) and $0F;
           Inc(P);
           Inc(C, (P^ and $03) shl 4);
         end;
      3: begin
           C := (P^ shr 2) and $3F;
           Inc(P);
         end;
    end;
    case C of
      $00: Break;
      $01..$0A: Inc(C, Ord('0') - $01);
      $0B..$24: Inc(C, Ord('A') - $0B);
      $25..$3E: Inc(C, Ord('a') - $25);
      $3F: C := Ord('_');
    end;
    if C <> 0 then begin
      Buffer[Used] := AnsiChar(C);
      Inc(Used);
    end;
    Inc(Index);
  until (C = 0) or (Used >= High(Buffer));
  Buffer[Used] := #0;
  Result := string(AnsiString(PAnsiChar(@Buffer[0])));
end;

var
  DebugData: PByte;
  DebugHeader: PJclDbgHeader;

function ReadVarint(var P: PByte): Integer;
begin
  Result := 0;
  var Shift := 0;
  var B: Byte;
  repeat
    B := P^;
    Inc(P);
    Inc(Result, (B and $7F) shl Shift);
    Inc(Shift, 7);
  until B and $80 = 0;
end;

function WordTableEntry(Offset: Integer): string;
begin
  if Offset = 0 then
    Exit('');
  Result := DecodeName(PAnsiChar(DebugData + Offset + DebugHeader^.Words - 1));
end;

// Extract min(SizeOfRawData, VirtualSize) bytes of the named PE section from an
// on-disk image into Stream. Mirrors TJclPeSectionStream sizing. Returns False
// if the section is absent.
function ReadPeSection(const FileName, SectionName: string; Stream: TMemoryStream): Boolean;
var
  DosHeader: TImageDosHeader;
  NtHeaders: TImageNtHeaders64;
  Section: TImageSectionHeader;
begin
  Result := False;
  var FileStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if FileStream.Read(DosHeader, SizeOf(DosHeader)) <> SizeOf(DosHeader) then
      Exit;
    if DosHeader.e_magic <> IMAGE_DOS_SIGNATURE then
      Exit;

    FileStream.Position := DosHeader._lfanew;
    if FileStream.Read(NtHeaders, SizeOf(NtHeaders)) <> SizeOf(NtHeaders) then
      Exit;
    if NtHeaders.Signature <> IMAGE_NT_SIGNATURE then
      Exit;

    // The section table follows the optional header.
    FileStream.Position := DosHeader._lfanew + SizeOf(DWORD) + SizeOf(TImageFileHeader) +
      NtHeaders.FileHeader.SizeOfOptionalHeader;
    for var I := 0 to NtHeaders.FileHeader.NumberOfSections - 1 do begin
      if FileStream.Read(Section, SizeOf(Section)) <> SizeOf(Section) then
        Exit;
      var RawName: AnsiString;
      SetString(RawName, PAnsiChar(@Section.Name[0]),
        System.AnsiStrings.StrLen(PAnsiChar(@Section.Name[0])));
      if not SameText(string(RawName), SectionName) then
        Continue;

      var DataSize := Section.SizeOfRawData;
      if (Section.Misc.VirtualSize > 0) and (Section.Misc.VirtualSize < DataSize) then
        DataSize := Section.Misc.VirtualSize;
      Stream.Size := 0;
      FileStream.Position := Section.PointerToRawData;
      Stream.CopyFrom(FileStream, DataSize);
      Stream.Position := 0;
      Exit(True);
    end;
  finally
    FileStream.Free;
  end;
end;

function IsMangledNestedName(const Name: string): Boolean;
begin
  for var Marker in ['_ZZ', '$pdata$', '$unwind$'] do
    if Pos(Marker, Name) > 0 then
      Exit(True);
  Result := False;
end;

procedure EnumProcNames;
begin
  var CurrentAddress := 0;
  var UnitWord := 0;
  var ProcWord := 0;
  var Total := 0;
  var WithDollar := 0;
  var Mangled := 0;

  var Samples := TStringList.Create;
  try
    var P := PByte(NativeUInt(DebugData) + NativeUInt(DebugHeader^.Symbols));
    while True do begin
      var Delta := ReadVarint(P);
      if Delta = MaxInt then
        Break;
      Inc(CurrentAddress, Delta);
      Inc(UnitWord, ReadVarint(P));
      Inc(ProcWord, ReadVarint(P));
      if UnitWord = 0 then
        Continue;

      var Name := WordTableEntry(UnitWord);
      if ProcWord <> 0 then
        Name := Name + '.' + WordTableEntry(ProcWord);

      Inc(Total);
      if (Pos('$', Name) > 0) and (Pos('$thunk', Name) = 0) then begin
        Inc(WithDollar);
        if Samples.Count < MaxSampleNames then
          Samples.Add(Format('  [$%x] %s', [CurrentAddress, Name]));
      end;
      if IsMangledNestedName(Name) then
        Inc(Mangled);
    end;

    Writeln(Format('Proc-name entries: %d total, %d non-thunk "$", %d mangled (_ZZ/$pdata$/$unwind$)',
      [Total, WithDollar, Mangled]));
    if Samples.Count = 0 then
      Exit;
    Writeln('Sample non-thunk "$" names:');
    Write(Samples.Text);
  finally
    Samples.Free;
  end;
end;

function LoadDebugData(const FileName: string; Stream: TMemoryStream): Boolean;
begin
  if SameText(ExtractFileExt(FileName), '.jdbg') then begin
    Stream.LoadFromFile(FileName);
    Writeln('Source: .jdbg file (', Stream.Size, ' bytes)');
    Exit(True);
  end;

  if ReadPeSection(FileName, 'JCLDEBUG', Stream) then begin
    Writeln('Source: linked JCLDEBUG section (', Stream.Size, ' bytes)');
    Exit(True);
  end;

  var SidecarName := ChangeFileExt(FileName, '.jdbg');
  if not FileExists(SidecarName) then
    Exit(False);

  Stream.LoadFromFile(SidecarName);
  Writeln('Source: sidecar ', ExtractFileName(SidecarName), ' (', Stream.Size, ' bytes)');
  Result := True;
end;

procedure Probe(const FileName: string);
begin
  Writeln('Target: ', FileName);
  var Stream := TMemoryStream.Create;
  try
    if not LoadDebugData(FileName, Stream) then begin
      Writeln('RESULT: no JCL debug data (no JCLDEBUG section, no .jdbg sidecar).');
      Exit;
    end;

    DebugData := Stream.Memory;
    DebugHeader := PJclDbgHeader(DebugData);
    var Scanner := TJclBinDebugScanner.Create(Stream, True, False);
    try
      Writeln('ValidFormat: ', Scanner.ValidFormat);
      Writeln('ModuleName : ', Scanner.ModuleName);
      if not Scanner.ValidFormat then
        Exit;
      EnumProcNames;
    finally
      Scanner.Free;
    end;
  finally
    Stream.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: JclProbe.exe <pe-or-jdbg-file>');
      Halt(1);
    end;

    var TargetPath := ParamStr(1);
    if not FileExists(TargetPath) then begin
      Writeln('File not found: ', TargetPath);
      Halt(1);
    end;

    Probe(TargetPath);
  except
    on E: Exception do begin
      Writeln('EXCEPTION: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
