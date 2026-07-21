program DumpTd32Globals;

// Lists the global / unit-level symbols exposed by a module's TD32 debug info.
// Answers the question "which module actually owns this global?": run it on the
// main executable and on each BPL until the symbol shows up.
//
// For every global it prints the name, RVA and resolved type hint. It also runs
// the raw symbol-record scan (DiagFindSymbolRecords), which reports the owning
// module/unit of each record, and lists the source files the TD32 info covers.
//
// Usage: DumpTd32Globals.exe <exe-or-bpl> [name-substring-filter]

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas';

procedure PrintUsage;
begin
  Writeln('Usage: DumpTd32Globals.exe <exe-or-bpl> [name-substring-filter]');
  Writeln('  <exe-or-bpl>            module whose TD32 debug info is read (required)');
  Writeln('  [name-substring-filter] case-insensitive substring; without it every global is listed');
end;

function MatchesFilter(const Name, Filter: string): Boolean;
begin
  if Filter = '' then
    Exit(True);
  Result := Pos(LowerCase(Filter), LowerCase(Name)) > 0;
end;

procedure PrintGlobal(const G: TGlobalSymbol);
begin
  Writeln(Format('  %-48s RVA=$%x  typeId=%d  type="%s"',
    [G.Name, G.RVA, G.TypeId, G.TypeHint]));
end;

procedure ReportExactLookup(Reader: TTD32FileReader; const Name: string);
begin
  Writeln('=== exact lookup for "', Name, '" ===');

  var Rva: UInt64 := 0;
  if Reader.NameToRva(Name, Rva) then
    Writeln(Format('  NameToRva  : HIT  RVA=$%x', [Rva]))
  else
    Writeln('  NameToRva  : MISS');

  var G: TGlobalSymbol;
  if Reader.FindGlobal(Name, G) then
    Writeln(Format('  FindGlobal : HIT  RVA=$%x typeId=%d type="%s"', [G.RVA, G.TypeId, G.TypeHint]))
  else
    Writeln('  FindGlobal : MISS');

  Writeln;
end;

procedure ReportGlobals(Reader: TTD32FileReader; const Filter: string);
begin
  var Globals := Reader.GetGlobals;
  if Filter = '' then
    Writeln('=== globals (', Length(Globals), ' total) ===')
  else
    Writeln('=== globals matching "', Filter, '" (', Length(Globals), ' total in module) ===');

  var Shown := 0;
  for var G in Globals do begin
    if not MatchesFilter(G.Name, Filter) then
      Continue;
    PrintGlobal(G);
    Inc(Shown);
  end;

  if Shown = 0 then
    Writeln('  (none)');
  Writeln('  listed ', Shown, ' of ', Length(Globals));
  Writeln;
end;

procedure ReportRawSymbolRecords(Reader: TTD32FileReader; const Filter: string);
begin
  if Filter = '' then
    Writeln('=== raw symbol-record scan: all data globals by unit ===')
  else
    Writeln('=== raw symbol-record scan for "', Filter, '" ===');

  var Lines := Reader.DiagFindSymbolRecords(Filter);
  if Length(Lines) = 0 then
    Writeln('  (no records)');
  for var Line in Lines do
    Writeln('  ', Line);
  Writeln;
end;

procedure ReportSourceCoverage(Reader: TTD32FileReader);
begin
  var SourceFiles := Reader.GetSourceFiles;
  Writeln('=== TD32 source coverage (', Length(SourceFiles), ' files) ===');
  for var SourceFile in SourceFiles do
    Writeln('  ', SourceFile);
  Writeln;
end;

procedure DumpModule(const ModulePath, Filter: string);
begin
  Writeln('Module: ', ModulePath);

  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ModulePath);
    if not Reader.Loaded then begin
      Writeln('  (no TD32 debug info found in this module)');
      Exit;
    end;

    Writeln;
    if Filter <> '' then
      ReportExactLookup(Reader, Filter);
    ReportGlobals(Reader, Filter);
    ReportRawSymbolRecords(Reader, Filter);
    ReportSourceCoverage(Reader);
  finally
    Reader.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      PrintUsage;
      Halt(1);
    end;

    var ModulePath := ParamStr(1);
    if not FileExists(ModulePath) then begin
      Writeln('File not found: ', ModulePath);
      Halt(1);
    end;

    DumpModule(ModulePath, ParamStr(2));
    Writeln('done.');
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
