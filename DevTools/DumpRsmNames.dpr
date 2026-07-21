program DumpRsmNames;
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  RsmFileReader in '..\DebuggerCore\RsmFileReader.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas';
begin
  if ParamCount < 1 then begin Writeln('Usage: <rsm path>'); Halt(1); end;
  var R := TRsmFile.Create;
  try
    R.LoadFromFile(ParamStr(1));
    var Names := R.AllProcedureNames;
    Writeln('Total names: ', Length(Names));
    Writeln('Names containing "testtarget" / "init" / "initialization":');
    for var N in Names do
      if N.Contains('testtarget') or N.Contains('init') or N.Contains('initialization') then
        Writeln('  ', N);
    Writeln;
    Writeln('Names containing key test-target identifiers:');
    for var N in Names do
      if N.Contains('runevaltests') or N.Contains('runbptests') or
         N.Contains('runexceptiontest') or N.Contains('pubbump') or
         N.Contains('docalcint64') or N.Contains('tstuff') or
         N.Contains('twidget') or N.Contains('tsink.use') then
        Writeln('  ', N);
  finally R.Free; end;
end.
