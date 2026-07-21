program TdsProbe;

// Tries to parse the embedded TD32 (.debug section, magic FB09) of a
// Delphi-built EXE using JCL's TJclTD32InfoParser. Goal: validate
// whether JCL's existing TD32 parser can read what dcc64 emits when
// invoked with -V (no -VR), as the foundation for a CodeView/TD32
// IDebugInfoProvider in the adapter.
//
// Reports: number of modules, source modules, symbols, proc symbols,
// names. Lists first few of each. Highlights raw symbol-type counts
// per record kind so we can see whether locals (BPREL32) are present
// in the binary even if JCL doesn't expose them as classes.
//
// Usage: TdsProbe.exe <path-to-exe>

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, Winapi.Windows,
  JclTD32 in 'C:\Athens\jcl\jcl\source\windows\JclTD32.pas';

procedure ExtractDebugSection(const ExePath: string; out Data: TBytes);
var
  FS:           TFileStream;
  Buf:          TBytes;
  ELfanew:      Integer;
  NSections:    Word;
  OptHdrSize:   Word;
  SectOff:      Integer;
  I:            Integer;
  SectName:     string;
  RawSize:      Integer;
  RawPtr:       Integer;
begin
  Data := nil;
  FS := TFileStream.Create(ExePath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Buf, FS.Size);
    FS.ReadBuffer(Buf[0], FS.Size);
  finally
    FS.Free;
  end;

  ELfanew    := PInteger(@Buf[$3C])^;
  NSections  := PWord(@Buf[ELfanew + 6])^;
  OptHdrSize := PWord(@Buf[ELfanew + 20])^;
  SectOff    := ELfanew + 24 + OptHdrSize;

  for I := 0 to NSections - 1 do begin
    var Off := SectOff + I * 40;
    SetString(SectName, PAnsiChar(@Buf[Off]), 8);
    SectName := Trim(SectName.TrimRight([#0]));
    if SectName = '.debug' then begin
      RawSize := PInteger(@Buf[Off + 16])^;
      RawPtr  := PInteger(@Buf[Off + 20])^;
      // Skip leading PE-alignment padding zeros to land on the FB09 magic.
      // dcc64 emits the .debug section with a small zero prefix (16-32 bytes
      // observed) before the actual TD32 stream.
      var SkipBytes: Integer := 0;
      while (SkipBytes + 4 < RawSize) and
            ((Buf[RawPtr + SkipBytes]     <> $46) or
             (Buf[RawPtr + SkipBytes + 1] <> $42) or
             (Buf[RawPtr + SkipBytes + 2] <> $30) or
             (Buf[RawPtr + SkipBytes + 3] <> $39)) do
        Inc(SkipBytes);
      if SkipBytes + 8 >= RawSize then Exit; // no FB09 anywhere
      Writeln(Format('  (skipped %d leading bytes before FB09)', [SkipBytes]));
      SetLength(Data, RawSize - SkipBytes);
      Move(Buf[RawPtr + SkipBytes], Data[0], RawSize - SkipBytes);
      Exit;
    end;
  end;
end;

procedure Probe(const ExePath: string);
var
  Bytes:   TBytes;
  MS:      TMemoryStream;
  Parser:  TJclTD32InfoParser;
  Scanner: TJclTD32InfoScanner;
begin
  Writeln('=== ', ExePath, ' ===');
  ExtractDebugSection(ExePath, Bytes);
  if Length(Bytes) = 0 then begin
    Writeln('  (no .debug section)');
    Exit;
  end;
  Writeln(Format('.debug section: %d bytes', [Length(Bytes)]));

  // Header bytes
  Write('  first 16 bytes: ');
  for var I := 0 to 15 do Write(Format('%.2x ', [Bytes[I]]));
  Writeln;

  MS := TMemoryStream.Create;
  try
    MS.Write(Bytes[0], Length(Bytes));
    MS.Position := 0;

    Scanner := TJclTD32InfoScanner.Create(MS);
    Parser  := Scanner;
    try
      Writeln('ValidData      : ', Parser.ValidData);
      Writeln('NameCount      : ', Parser.NameCount);
      Writeln('ModuleCount    : ', Parser.ModuleCount);
      Writeln('SourceModules  : ', Parser.SourceModuleCount);
      Writeln('SymbolCount    : ', Parser.SymbolCount);
      Writeln('ProcSymbols    : ', Parser.ProcSymbolCount);

      Writeln('-- first 10 names --');
      for var I := 0 to Min(9, Parser.NameCount - 1) do
        Writeln(Format('  [%d] %s', [I, Parser.Names[I]]));

      Writeln('-- first 10 procs --');
      for var I := 0 to Min(9, Parser.ProcSymbolCount - 1) do begin
        var P := Parser.ProcSymbols[I];
        Writeln(Format('  [%d] name=%s offset=$%x size=%d',
          [I, Parser.Names[P.NameIndex], P.Offset, P.Size]));
      end;

      Writeln('-- LineNumber lookup probes --');
      for var Rva in [DWORD($1000), $5000, $A000, $20000, $30000] do begin
        var Off: Integer := 0;
        var Ln := Scanner.LineNumberFromAddr(Rva, Off);
        var Pn := Scanner.ProcNameFromAddr(Rva, Off);
        var Sn := Scanner.SourceNameFromAddr(Rva);
        Writeln(Format('  RVA $%x → line=%d proc="%s" src="%s"',
          [Rva, Ln, Pn, Sn]));
      end;
    finally
      Parser.Free;
    end;
  finally
    MS.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: TdsProbe.exe <path-to-exe>');
      Halt(1);
    end;
    Probe(ParamStr(1));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(2);
    end;
  end;
end.
