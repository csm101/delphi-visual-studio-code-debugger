program TestNested;

// Tests that the MAP file reader correctly identifies nested (inner) procedures
// and resolves their enclosing parent procedures.  Run this against a .map
// file to verify nested-proc detection when debugging stepping or locals.
//
// Usage: TestNested.exe <path-to-map>
// Default: uses Debugme.map from the standard build output.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  MapFileReader  in '..\DebuggerCore\MapFileReader.pas';

procedure Run(const MapPath: string);
begin
  Writeln('Map: ', MapPath);
  var Map := TMapFile.Create;
  try
    Map.LoadFromFile(MapPath);
    for var Inner in ['ThisIsALocalProcedure', 'Increment', 'Inner', 'NotANest'] do begin
      var Parent: string;
      if Map.GetEnclosingProcedure(Inner, Parent) then
        Writeln(Format('  %-25s -> parent = %s', [Inner, Parent]))
      else
        Writeln(Format('  %-25s -> (no parent registered)', [Inner]));
    end;
  finally
    Map.Free;
  end;
end;

begin
  try
    if ParamCount >= 1 then
      Run(ParamStr(1))
    else
      Run(ExpandFileName(ExtractFilePath(ParamStr(0)) +
        '..\Win64\Debug\Debugme.map'));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
