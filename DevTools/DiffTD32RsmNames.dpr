program DiffTD32RsmNames;
{$APPTYPE CONSOLE}

// Diff between proc names exposed by TD32FileReader and those keyed by
// the RSM reader's FProcOffsets index. Any name TD32 emits but RSM does
// not recognize fails the locals lookup downstream.

uses
  System.SysUtils,
  System.Math,
  System.Generics.Collections,
  System.Generics.Defaults,
  TD32FileReader  in '..\DebuggerCore\TD32FileReader.pas',
  RsmFileReader   in '..\DebuggerCore\RsmFileReader.pas',
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas';

begin
  try
    if ParamCount < 1 then begin Writeln('Usage: <exe>'); Halt(1); end;
    var ExePath := ParamStr(1);
    var RsmPath := ChangeFileExt(ExePath, '.rsm');

    var TD32 := TTD32FileReader.Create;
    var Rsm  := TRsmFile.Create;
    try
      TD32.LoadFromFile(ExePath);
      Rsm.LoadFromFile(RsmPath);

      // Locals dump
      TD32.ExposeLocals := True;
      var Names := TD32.AllProcedureNames;
      Writeln(Format('TD32 procs with locals: %d', [Length(Names)]));
      var Probed := 0;
      for var Nm in Names do begin
        var Locs: TArray<TLocalSymbol>;
        if TD32.GetLocalsForFunction(Nm, Locs) then begin
          Writeln(Format('  proc %s -- %d locals', [Nm, Length(Locs)]));
          for var L in Locs do
            Writeln(Format('     %s @ RBP%+d  Type=$%x', [L.Name, L.RbpOffset, L.TypeId]));
          Inc(Probed);
          if Probed >= 4 then Break;
        end;
      end;
      Writeln;

      // Globals
      var Globals := TD32.GetGlobals;
      Writeln(Format('TD32 globals total: %d', [Length(Globals)]));
      for var I := 0 to Min(9, Length(Globals) - 1) do
        Writeln(Format('  $%x  Type=$%x  %s',
          [Globals[I].RVA, Globals[I].TypeId, Globals[I].Name]));
      Writeln;
      // Probe specific globals
      for var GName in ['ExitProc', 'System.IsConsole', 'IsConsole',
                         'System.RandSeed', 'RandSeed'] do begin
        var G: TGlobalSymbol;
        if TD32.FindGlobal(GName, G) then
          Writeln(Format('  Global "%s" -> $%x Type=$%x', [GName, G.RVA, G.TypeId]))
        else
          Writeln(Format('  Global "%s" -> NOT FOUND', [GName]));
      end;
      Writeln;

      // Show how many proc names TD32 knows about + sample.
      var TD32Names := TD32.AllKnownProcNames;
      Writeln(Format('TD32 known proc names: %d', [Length(TD32Names)]));
      Writeln('Searching for "now" substring:');
      var Hits := 0;
      for var N in TD32Names do
        if N.Contains('now') then begin
          Writeln('  ', N);
          Inc(Hits);
          if Hits >= 10 then Break;
        end;
      Writeln;

      // Diagnostic: try a few specific names
      Writeln('Specific NameToRva probes:');
      for var Q in ['Now', 'now', 'TWidget.DoCalcInt64', 'System.Now',
                    'DateUtils.Now', 'RunBpTests', 'GetTickCount64',
                    'gettickcount64', 'tobject.classname'] do begin
        var R: UInt64;
        if TD32.NameToRva(Q, R) then
          Writeln(Format('  "%s" -> $%x', [Q, R]))
        else
          Writeln(Format('  "%s" -> NOT FOUND', [Q]));
      end;
      Writeln;

      var RsmNames := Rsm.AllProcedureNames;
      var RsmSet := TDictionary<string, Integer>.Create;
      try
        for var Name in RsmNames do
          RsmSet.AddOrSetValue(Name, 1);
        Writeln('RSM proc count: ', Length(RsmNames));

        // For every RVA TD32 has a line for, query TD32 for function name
        // and check against the RSM proc set.
        var Rvas := TD32.SortedRvas;
        var Tested := 0; var Matched := 0;
        var Missing: TArray<string>;
        for var Rva in Rvas do begin
          var Name: string;
          if not TD32.RvaToFunctionName(Rva, Name) then Continue;
          Inc(Tested);
          if RsmSet.ContainsKey(LowerCase(Name)) then
            Inc(Matched)
          else if Length(Missing) < 25 then
            Missing := Missing + [Format('RVA $%x  TD32=%s', [Rva, Name])];
        end;
        Writeln(Format('Tested=%d Matched=%d Missing=%d', [Tested, Matched, Tested - Matched]));
        Writeln('First missing names:');
        for var M in Missing do Writeln('  ', M);

        // Inverse: RSM names TD32 cannot resolve via NameToRva.
        Writeln;
        Writeln('RSM names absent from TD32.NameToRva (sample):');
        var Bad := 0;
        for var Name in RsmNames do begin
          var R: UInt64;
          if not TD32.NameToRva(Name, R) then begin
            Inc(Bad);
            if Bad <= 15 then Writeln('  ', Name);
          end;
        end;
        Writeln(Format('Total RSM names not findable by TD32.NameToRva: %d / %d',
          [Bad, Length(RsmNames)]));
      finally RsmSet.Free; end;
    finally
      Rsm.Free;
      TD32.Free;
    end;
  except
    on E: Exception do begin Writeln('ERR: ', E.Message); Halt(99); end;
  end;
end.
