program RvaLookup;

// Resolves a list of RVAs against a Delphi MAP + RSM pair, producing
// "name+offset (source:line)" for each. Used to interpret stack frames
// dumped by WinDbg/cdb when the EXE has no symbols (Delphi binaries
// only export _dbk_fcall_wrapper, so cdb shows everything as huge
// offsets from that single export).
//
// Usage:
//   RvaLookup.exe <path-to-map> <path-to-rsm> <rva1> [rva2] [rva3] ...
//
// RVAs are accepted as hex (with or without 0x prefix) or decimal.
//
// Output line per RVA:
//   RVA 0xXXXX  -> ProcName+0xNN  (Unit.pas:line)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  MapFileReader   in '..\DebuggerCore\MapFileReader.pas',
  RsmFileReader   in '..\DebuggerCore\RsmFileReader.pas';

function ParseRva(const S: string): UInt64;
var
  T: string;
begin
  T := S;
  if T.StartsWith('0x') or T.StartsWith('0X') then T := T.Substring(2);
  if T.StartsWith('$') then T := T.Substring(1);
  Result := StrToUInt64('$' + T);
end;

procedure Run;
var
  Map:     TMapFile;
  Rsm:     TRsmFile;
  Rva:     UInt64;
  Name:    string;
  FuncRva: UInt64;
  Loc:     TSourceLocation;
begin
  if ParamCount < 3 then begin
    Writeln('Usage: RvaLookup.exe <map> <rsm> <rva1> [rva2] ...');
    Halt(1);
  end;
  Map := TMapFile.Create;
  Rsm := TRsmFile.Create;
  try
    Map.LoadFromFile(ParamStr(1), $400000);  // assume preferred base
    Rsm.LoadFromFile(ParamStr(2));
    Writeln(Format('MAP: %s  RSM: %s', [ParamStr(1), ParamStr(2)]));
    Writeln('Resolving ', ParamCount - 2, ' RVAs...');
    Writeln;

    // Force background indexing to complete by issuing a lookup early.
    Map.RvaToFunctionName(0, Name);

    for var I := 3 to ParamCount do begin
      Rva := ParseRva(ParamStr(I));
      Write(Format('RVA 0x%x  -> ', [Rva]));

      if Map.RvaToFunctionName(Rva, Name) then begin
        Map.RvaToFunctionStart(Rva, FuncRva);
        Write(Format('%s+0x%x', [Name, Rva - FuncRva]));
      end else
        Write('(no public)');

      if Map.RvaToSourceLine(Rva, Loc) then
        Write(Format('  (%s:%d)', [ExtractFileName(Loc.SourceFile), Loc.Line]))
      else
        Write('  (no source)');

      Writeln;
    end;
  finally
    Rsm.Free;
    Map.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(2);
    end;
  end;
end.
