program RsmAnalyzer;

// Analyzes a Delphi .rsm (remote symbol map) file and produces three output
// files next to the input: .analysis.txt (summary), .strings.txt (all ASCII
// runs), .hex.txt (full hex dump).  Useful for investigating the RSM binary
// format when the parser behaves unexpectedly.
//
// Usage: RsmAnalyzer.exe <path-to-rsm>

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  RsmReader in 'RsmReader.pas';

procedure RunAnalysis;
begin
  if ParamCount < 1 then begin
    Writeln('Usage: RsmAnalyzer.exe <path-to-rsm>');
    Writeln('Produces <path>.analysis.txt, <path>.strings.txt, <path>.hex.txt');
    Halt(1);
  end;

  var InputPath := ParamStr(1);
  if not FileExists(InputPath) then begin
    Writeln('File not found: ', InputPath);
    Halt(2);
  end;

  var SummaryPath := ChangeFileExt(InputPath, '.analysis.txt');
  var StringsPath := ChangeFileExt(InputPath, '.strings.txt');
  var HexPath     := ChangeFileExt(InputPath, '.hex.txt');

  var Analyzer := TRsmAnalyzer.Create;
  try
    Analyzer.Analyze(InputPath, SummaryPath, StringsPath, HexPath);
  finally
    Analyzer.Free;
  end;

  Writeln('Analysis written to:');
  Writeln('  ', SummaryPath);
  Writeln('  ', StringsPath);
  Writeln('  ', HexPath);
end;

begin
  try
    RunAnalysis;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(3);
    end;
  end;
end.
