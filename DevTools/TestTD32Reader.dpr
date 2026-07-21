program TestTD32Reader;

{$APPTYPE CONSOLE}

// Smoke test for TD32FileReader.
//
// Usage:
//   TestTD32Reader.exe <exe-path>
//
// Loads the .debug section of the given PE, parses SOURCE_MODULE entries,
// prints summary stats and a sample of RVA<->line mappings.

uses
  System.SysUtils,
  System.Math,
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';

procedure Dump(const ExePath: string);
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rvas := R.SortedRvas;
    Writeln(Format('Loaded TD32 for %s', [ExePath]));
    Writeln(Format('Total line pairs: %d', [Length(Rvas)]));
    if Length(Rvas) = 0 then Exit;
    Writeln('First 5 entries:');
    for var I := 0 to Min(4, Length(Rvas) - 1) do begin
      var Loc: TSourceLocation;
      if R.RvaToSourceLine(Rvas[I], Loc) then
        Writeln(Format('  RVA $%x -> %s:%d', [Rvas[I], Loc.SourceFile, Loc.Line]));
    end;
    Writeln('Last 5 entries:');
    for var I := Max(0, Length(Rvas) - 5) to Length(Rvas) - 1 do begin
      var Loc: TSourceLocation;
      if R.RvaToSourceLine(Rvas[I], Loc) then
        Writeln(Format('  RVA $%x -> %s:%d', [Rvas[I], Loc.SourceFile, Loc.Line]));
    end;

    // Reverse lookup smoke test
    var Probe: TSourceLocation;
    if R.RvaToSourceLine(Rvas[0], Probe) then begin
      var Back: UInt64;
      if R.SourceLineToRva(Probe.SourceFile, Probe.Line, Back) then
        Writeln(Format('Reverse: %s:%d -> RVA $%x (orig $%x)',
          [Probe.SourceFile, Probe.Line, Back, Rvas[0]]))
      else
        Writeln('Reverse lookup failed.');
    end;
  finally
    R.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: TestTD32Reader.exe <exe-path>');
      Halt(1);
    end;
    Dump(ParamStr(1));
  except
    on E: Exception do begin
      Writeln('ERR: ', E.Message);
      Halt(2);
    end;
  end;
end.
