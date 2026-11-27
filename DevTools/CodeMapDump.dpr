program CodeMapDump;

{$APPTYPE CONSOLE}

// Builds the code map of ONE binary from its TD32 debug information, as a
// file -- nothing is launched -- and prints what the map holds and what it
// costs. The code map (DebuggerCore\CodeMap.pas) is the join of a module's
// routine ranges and line records that coverage and profiling work from.
//
// Usage:
//   CodeMapDump.exe <exe-or-bpl> [-tds <file.tds>] [-shift <hex>]
//                   [-lines <source file>] [-routine <name>]
//
//   -tds <file>      read the debug information from an external .tds
//                    (dcc64 -VT) instead of the binary's own .debug section
//   -shift <hex>     load the reader with this OutputRvaShift, as the engine
//                    does for a runtime module, and build the map from the
//                    shifted provider. The module-relative output must not
//                    change: that is the property the option exists to show.
//   -lines <file>    list the line records of one source file (name or path)
//   -routine <name>  list the routines of that name with their line records;
//                    matches the whole name or its last dotted part
//
// Output: the counts (routines, line records, records outside every routine
// range, files, units), the time the two provider tables and the build take,
// and the memory of the map -- computed from its tables, and measured as the
// growth of the process's private bytes over the build. (Private bytes after
// the reader is freed were tried as "the map alone" and dropped: they measure
// what the heap keeps of a freed 1 GB reader, not the map.)

uses
  System.SysUtils,
  System.Diagnostics,
  Winapi.Windows,
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader  in '..\DebuggerCore\TD32FileReader.pas',
  PeSymbolSupport in '..\DebuggerCore\PeSymbolSupport.pas',
  CodeMap         in '..\DebuggerCore\CodeMap.pas';

type
  TProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: SIZE_T;
    WorkingSetSize: SIZE_T;
    QuotaPeakPagedPoolUsage: SIZE_T;
    QuotaPagedPoolUsage: SIZE_T;
    QuotaPeakNonPagedPoolUsage: SIZE_T;
    QuotaNonPagedPoolUsage: SIZE_T;
    PagefileUsage: SIZE_T;
    PeakPagefileUsage: SIZE_T;
  end;

  TOptions = record
    BinaryPath:  string;
    TdsPath:     string;
    Shift:       UInt64;
    LinesOf:     string;
    RoutineName: string;
  end;

function GetProcessMemoryInfo(Process: THandle; var Counters: TProcessMemoryCounters;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll';

// Private bytes of this process: what its heap has committed. Unlike the
// working set it does not move with the mapped view of the binary.
function PrivateBytes: Int64;
begin
  var Counters: TProcessMemoryCounters;
  FillChar(Counters, SizeOf(Counters), 0);
  Counters.cb := SizeOf(Counters);
  if GetProcessMemoryInfo(GetCurrentProcess, Counters, SizeOf(Counters)) then
    Result := Int64(Counters.PagefileUsage)
  else
    Result := -1;
end;

function Megabytes(Bytes: Int64): string;
begin
  Result := Format('%.1f MB', [Bytes / (1024 * 1024)]);
end;

procedure PrintUsage;
begin
  Writeln('Usage: CodeMapDump.exe <exe-or-bpl> [-tds <file.tds>] [-shift <hex>]');
  Writeln('                       [-lines <source file>] [-routine <name>]');
end;

function ParseOptions(out Options: TOptions): Boolean;
begin
  Options := Default(TOptions);
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    var HasValue := I < ParamCount;
    if SameText(Arg, '-tds') and HasValue then begin
      Options.TdsPath := ParamStr(I + 1);
      Inc(I);
    end else if SameText(Arg, '-shift') and HasValue then begin
      Options.Shift := StrToUInt64('$' + ParamStr(I + 1).Replace('$', '').Replace('0x', ''));
      Inc(I);
    end else if SameText(Arg, '-lines') and HasValue then begin
      Options.LinesOf := ParamStr(I + 1);
      Inc(I);
    end else if SameText(Arg, '-routine') and HasValue then begin
      Options.RoutineName := ParamStr(I + 1);
      Inc(I);
    end else if Arg.StartsWith('-') then
      Exit(False)
    else if Options.BinaryPath = '' then
      Options.BinaryPath := ExpandFileName(Arg)
    else
      Exit(False);
    Inc(I);
  end;
  Result := Options.BinaryPath <> '';
end;

function RoutineLabel(Map: TModuleCodeMap; RoutineIndex: Integer): string;
begin
  if RoutineIndex < 0 then
    Exit('<outside every routine>');
  Result := Map.Routines[RoutineIndex].Name;
end;

procedure PrintLinesOfFile(Map: TModuleCodeMap; const FileName: string);
begin
  Writeln;
  var Files := Map.FindFiles(FileName);
  if Length(Files) = 0 then begin
    Writeln(Format('-lines: no source file named "%s" in the map', [FileName]));
    Exit;
  end;
  for var FileIndex in Files do begin
    var Records := Map.LinesOfFile(FileIndex);
    Writeln(Format('%s: %d line records', [Map.Files[FileIndex].Name, Length(Records)]));
    Writeln('    line  rva        len  unit / routine');
    for var LineIndex in Records do begin
      var Line := Map.Lines[LineIndex];
      Writeln(Format('  %6d  $%.8x %5d  %s / %s', [Line.Line, Line.Rva, Line.CodeLength,
        Map.UnitName(Line.UnitIndex), RoutineLabel(Map, Line.RoutineIndex)]));
    end;
  end;
end;

function RoutineMatches(const RoutineName, Wanted: string): Boolean;
begin
  if SameText(RoutineName, Wanted) then
    Exit(True);
  Result := RoutineName.EndsWith('.' + Wanted, True);
end;

procedure PrintRoutine(Map: TModuleCodeMap; RoutineIndex: Integer);
begin
  var Routine := Map.Routines[RoutineIndex];
  var EndNote := '';
  if Routine.EndIsApproximate then
    EndNote := ' (end approximate)';
  Writeln(Format('%s  [$%.8x, $%.8x)%s  %d bytes  unit %s  %d line records',
    [Routine.Name, Routine.StartRva, Routine.EndRva, EndNote,
     Int64(Routine.EndRva) - Routine.StartRva, Map.UnitName(Routine.UnitIndex), Routine.LineCount]));
  for var Offset := 0 to Routine.LineCount - 1 do begin
    var Line := Map.Lines[Routine.FirstLine + Offset];
    Writeln(Format('  $%.8x  +%-5d len %-5d %s:%d', [Line.Rva, Int64(Line.Rva) - Routine.StartRva,
      Line.CodeLength, Map.Files[Line.FileIndex].Name, Line.Line]));
  end;
end;

procedure PrintRoutinesNamed(Map: TModuleCodeMap; const Wanted: string);
begin
  Writeln;
  var Found := 0;
  for var I := 0 to High(Map.Routines) do
    if RoutineMatches(Map.Routines[I].Name, Wanted) then begin
      PrintRoutine(Map, I);
      Inc(Found);
    end;
  if Found = 0 then
    Writeln(Format('-routine: no routine named "%s" in the map', [Wanted]));
end;

procedure PrintSummary(Map: TModuleCodeMap; LoadMs, LinesMs, RoutinesMs: Double;
  GrowthWithReader: Int64);
begin
  var Lines := Length(Map.Lines);
  var OutsideShare := 0.0;
  if Lines > 0 then
    OutsideShare := 100.0 * Map.OutsideRoutineCount / Lines;
  var RoutinesWithLines := 0;
  var ApproximateEnds := 0;
  for var I := 0 to High(Map.Routines) do begin
    if Map.Routines[I].LineCount > 0 then
      Inc(RoutinesWithLines);
    if Map.Routines[I].EndIsApproximate then
      Inc(ApproximateEnds);
  end;
  // A record whose file is not its unit's own source: a generic written in one
  // unit and instantiated in another, or an include file. Compared once per
  // (file, unit) pair, since neighbouring records share both.
  var LinesWithoutUnit := 0;
  var LinesInAnotherFile := 0;
  var LastFile := -1;
  var LastUnit := -1;
  var LastIsForeign := False;
  for var I := 0 to High(Map.Lines) do begin
    var Line := Map.Lines[I];
    if Line.UnitIndex < 0 then begin
      Inc(LinesWithoutUnit);
      Continue;
    end;
    if (Line.FileIndex <> LastFile) or (Line.UnitIndex <> LastUnit) then begin
      LastFile := Line.FileIndex;
      LastUnit := Line.UnitIndex;
      LastIsForeign := not SameText(ChangeFileExt(Map.Files[LastFile].Name, ''), Map.Units[LastUnit]);
    end;
    if LastIsForeign then
      Inc(LinesInAnotherFile);
  end;

  Writeln('counts');
  Writeln(Format('  routines                              %d  (%d with line records, %d with an approximate end)',
    [Length(Map.Routines), RoutinesWithLines, ApproximateEnds]));
  Writeln(Format('  line records                          %d', [Lines]));
  Writeln(Format('  records outside every routine range   %d  (%.2f %%)', [Map.OutsideRoutineCount, OutsideShare]));
  Writeln(Format('  source files                          %d', [Length(Map.Files)]));
  Writeln(Format('  units                                 %d  (%d line records without a unit)',
    [Length(Map.Units), LinesWithoutUnit]));
  Writeln(Format('  records in a file not their unit''s own %d  (generic instantiations, include files)',
    [LinesInAnotherFile]));
  Writeln(Format('  dropped by the build                  %d line records, %d routines',
    [Map.DroppedLineCount, Map.DroppedRoutineCount]));
  Writeln(Format('  complete                              lines %s, routines %s',
    [BoolToStr(Map.LinesComplete, True), BoolToStr(Map.RoutinesComplete, True)]));
  Writeln('time');
  Writeln(Format('  TD32 load                             %.0f ms', [LoadMs]));
  Writeln(Format('  line record table alone               %.0f ms', [LinesMs]));
  Writeln(Format('  routine range table alone             %.0f ms', [RoutinesMs]));
  Writeln(Format('  code map build (both tables + join)   %.0f ms', [Map.BuildMs]));
  Writeln('memory of the map');
  Writeln(Format('  tables (computed)                     %s', [Megabytes(Map.TableBytes)]));
  Writeln(Format('  names (computed)                      %s  (routine names are shared with the reader while it lives)',
    [Megabytes(Map.NameBytes)]));
  Writeln(Format('  kept without the reader (computed)    %s', [Megabytes(Map.TableBytes + Map.NameBytes)]));
  Writeln(Format('  private bytes grown by the build      %s  (measured, reader still loaded)', [Megabytes(GrowthWithReader)]));
end;

procedure Run(const Options: TOptions);
begin
  var ImageSize := ReadPEImageSize(Options.BinaryPath);
  Writeln(Format('%s  (image size $%x, shift $%x)', [Options.BinaryPath, ImageSize, Options.Shift]));

  var Reader := TTD32FileReader.Create;
  // The reader is reference counted: this reference keeps it alive until the
  // measurement below drops it.
  var Holder: IInterface := Reader;
  var Clock := TStopwatch.StartNew;
  if Options.TdsPath <> '' then
    Reader.LoadFromTdsFile(Options.TdsPath, Options.BinaryPath, Options.Shift)
  else
    Reader.LoadFromFile(Options.BinaryPath, Options.Shift);
  var LoadMs := Clock.Elapsed.TotalMilliseconds;

  // Each table once on its own, for the split of the build time; the results
  // are dropped before anything is measured.
  var Complete: Boolean;
  Clock := TStopwatch.StartNew;
  var LineTable := Reader.LineRecordTable(Complete);
  var LinesMs := Clock.Elapsed.TotalMilliseconds;
  LineTable := Default(TLineRecordTable);
  Clock := TStopwatch.StartNew;
  var Ranges := Reader.RoutineRanges(Complete);
  var RoutinesMs := Clock.Elapsed.TotalMilliseconds;
  Ranges := nil;

  var BeforeBuild := PrivateBytes;
  var Map := TModuleCodeMap.Build(ExtractFileName(Options.BinaryPath), Reader, Reader,
    Options.Shift, ImageSize);
  try
    PrintSummary(Map, LoadMs, LinesMs, RoutinesMs, PrivateBytes - BeforeBuild);
    // The map must not need the reader: everything below runs without it.
    Holder := nil;

    if Options.LinesOf <> '' then
      PrintLinesOfFile(Map, Options.LinesOf);
    if Options.RoutineName <> '' then
      PrintRoutinesNamed(Map, Options.RoutineName);
  finally
    Map.Free;
  end;
end;

begin
  try
    var Options: TOptions;
    if not ParseOptions(Options) then begin
      PrintUsage;
      Halt(2);
    end;
    if not FileExists(Options.BinaryPath) then begin
      Writeln('File not found: ', Options.BinaryPath);
      Halt(2);
    end;
    Run(Options);
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
