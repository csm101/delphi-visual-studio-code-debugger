program TestRsmParser;

// Smoke-tests the adapter's RsmFileReader against a .rsm file.
// Prints all procedures discovered by the parser and their local variables
// (name, RBP offset, type id).  Run this after changing RsmFileReader.pas
// to verify the parser still finds the expected procs and locals.
//
// Usage: TestRsmParser.exe <path-to-rsm>
// Default: uses Debugme.rsm from the standard build output.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  RsmFileReader  in '..\DebuggerCore\RsmFileReader.pas';

procedure Dump(const Path: string);
begin
  Writeln('=== ', Path, ' ===');
  var Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(Path);
    if not Rsm.Loaded then begin
      Writeln('  (not loaded — not a CSH7 RSM?)');
      Exit;
    end;

    var Gs := Rsm.GetGlobals;
    if Length(Gs) = 0 then
      Writeln('  (no globals)')
    else begin
      Writeln('  Globals (', Length(Gs), '):');
      for var G in Gs do
        Writeln('    ', G.Name);
    end;

    var Ut := Rsm.UserTypes;
    if Length(Ut) > 0 then begin
      Write('  UserTypes: ');
      for var I := 0 to High(Ut) do begin
        if I > 0 then Write(', ');
        Write(Ut[I]);
      end;
      Writeln;
    end;

    var Names := Rsm.AllProcedureNames;
    for var ProcName in Names do begin
      var Locals: TArray<TLocalSymbol>;
      if Rsm.GetLocalsForFunction(ProcName, Locals) then begin
        Writeln('  Procedure "', ProcName, '" has ', Length(Locals), ' locals:');
        for var I := 0 to High(Locals) do begin
          var L := Locals[I];
          var Sign: string;
          if L.RbpOffset >= 0 then Sign := '+' else Sign := '-';
          Writeln(Format('    #%d  %-20s  RBP%s%d   (typeId=0x%.2x  %s)',
            [I + 1, L.Name, Sign, Abs(L.RbpOffset), L.TypeId, L.TypeHint]));
        end;
      end;
    end;
  finally
    Rsm.Free;
  end;
end;

begin
  try
    if ParamCount >= 1 then
      Dump(ParamStr(1))
    else
      Dump(ExpandFileName(ExtractFilePath(ParamStr(0)) +
        '..\..\..\samples\Debugme\Win64\Debug\Debugme.rsm'));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
