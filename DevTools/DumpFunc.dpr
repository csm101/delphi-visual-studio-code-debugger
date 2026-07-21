program DumpFunc;

// Dumps N bytes of machine code starting at a given RVA inside a PE (exe/dll).
// Use this to disassemble a specific function and understand its frame layout,
// prologue, or epilogue without needing a full disassembler.
//
// Usage: DumpFunc.exe <exe> <hexRVA> <count>
// Example: DumpFunc.exe Debugme.exe 2CCA0 64

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, Winapi.Windows;

type
  TImageSection = record
    Name:         string;
    VirtualAddr:  DWORD;
    VirtualSize:  DWORD;
    RawOffset:    DWORD;
    RawSize:      DWORD;
  end;

function ReadSections(const Path: string): TArray<TImageSection>;
var
  F: TFileStream;
  DosHeader: array[0..63] of Byte;
  PEOffset, NumSections: DWORD;
  Sig: DWORD;
  NumSectionsW: Word;
  OptHeaderSize: Word;
  SectionRaw: array[0..39] of Byte;
begin
  SetLength(Result, 0);
  F := TFileStream.Create(Path, fmOpenRead);
  try
    F.ReadBuffer(DosHeader, 64);
    PEOffset := PCardinal(@DosHeader[$3C])^;
    F.Position := PEOffset;
    F.ReadBuffer(Sig, 4);
    if Sig <> $00004550 then Exit;
    F.Position := PEOffset + 4 + 2;
    F.ReadBuffer(NumSectionsW, 2);
    F.Position := PEOffset + 4 + 16;
    F.ReadBuffer(OptHeaderSize, 2);
    F.Position := PEOffset + 4 + 20 + OptHeaderSize;
    NumSections := NumSectionsW;
    SetLength(Result, NumSections);
    for var I := 0 to NumSections - 1 do begin
      F.ReadBuffer(SectionRaw, 40);
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

begin
  if ParamCount < 3 then begin
    Writeln('Usage: DumpFunc.exe <exe> <hexRVA> <count>');
    Halt(1);
  end;
  var ExePath := ParamStr(1);
  var RVA := StrToInt64('$' + ParamStr(2));
  var Count := StrToInt(ParamStr(3));

  var Sections := ReadSections(ExePath);
  Writeln('Sections:');
  for var S in Sections do
    Writeln(Format('  %-10s va=0x%.8x vsize=0x%.8x raw=0x%.8x rsize=0x%.8x',
      [S.Name, S.VirtualAddr, S.VirtualSize, S.RawOffset, S.RawSize]));

  var Found: Boolean;
  var Offset := RvaToFileOffset(Sections, RVA, Found);
  if not Found then begin
    Writeln('RVA ', IntToHex(RVA, 8), ' not in any section');
    Halt(2);
  end;
  Writeln(Format('RVA 0x%.x => file offset 0x%.x', [RVA, Offset]));

  var F := TFileStream.Create(ExePath, fmOpenRead);
  try
    F.Position := Offset;
    var Bytes: TBytes;
    SetLength(Bytes, Count);
    F.ReadBuffer(Bytes[0], Count);
    for var I := 0 to Count - 1 do begin
      if I mod 16 = 0 then begin
        if I > 0 then Writeln;
        Write(Format('  %.8x  ', [RVA + UInt64(I)]));
      end;
      Write(IntToHex(Bytes[I], 2), ' ');
    end;
    Writeln;
  finally
    F.Free;
  end;
end.
