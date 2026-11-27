program BreakpointPlanProbe;

{$APPTYPE CONSOLE}

// Answers, for ONE binary read as a file (nothing is launched), the two
// questions the engine asks before it plants a source breakpoint
// (docs/DAP_DEBUGGER_ARCHITECTURE.md, "Breakpoints"), through the very class
// the session uses for a live process (DebuggerCore\LiveCodeAnalysis.pas):
//
//   * what the FIRST breakpoint in the module costs: the code map and the
//     analyzer are built by the first question, on the calling thread;
//   * for a source line: every line record it has, the piece of the routine
//     each is in (x64: body or funclet), the verdict of the routine analysis,
//     and which of them get a breakpoint.
//
// Usage:
//   BreakpointPlanProbe.exe <exe-or-bpl> [-map <file.map>] [-zydis <Zydis.dll>]
//                           [-line <source file>:<line>]... [-notcode]
//                           [-lastlines | -listlast [-src <dir>]...]
//
//   -map <file>      also load this MAP, as the session does when one lies
//                    beside the binary. On a 32-bit image it becomes the second
//                    routine provider of the code map (it names the bodies of
//                    anonymous methods, which TD32 has no procedure record for)
//   -zydis <file>    where Zydis.dll is (default: next to this tool, else the
//                    repository's ThirdParty\Zydis\bin\x64 copy)
//   -line <f>:<n>    report the records of this source line; may be repeated
//   -notcode         list the source lines that have a record the analysis
//                    shows NOT to be the start of an instruction, with the
//                    reason (analyses every routine: seconds on a large image)
//   -lastlines       survey the rule "a record outside every routine, on the
//                    highest line of its source file, is the unit's final end."
//                    (CodeMap.LastLineOutsideRoutines): how many records
//                    qualify, what their bytes are, and what else is outside
//                    every routine
//   -listlast        -lastlines, and list every record that qualifies
//   -src <dir>       with -lastlines: a source root, searched recursively
//                    (repeatable). The text of each qualifying line is read
//                    and the ones that are NOT a bare "end." are listed
//
// The timings are printed in the order a session pays them: the debug
// information is loaded when the session starts, whether or not a breakpoint is
// ever set; the code map, the analyzer and the first routine are what the first
// breakpoint adds.

uses
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Generics.Collections,
  System.IOUtils,
  Winapi.Windows,
  DebugInfoTypes   in '..\DebuggerCore\DebugInfoTypes.pas',
  DebugTarget      in '..\DebuggerCore\DebugTarget.pas',
  TD32FileReader   in '..\DebuggerCore\TD32FileReader.pas',
  MapFileReader    in '..\DebuggerCore\MapFileReader.pas',
  PeSymbolSupport  in '..\DebuggerCore\PeSymbolSupport.pas',
  CodeMap          in '..\DebuggerCore\CodeMap.pas',
  Disassembler     in '..\DebuggerCore\Disassembler.pas',
  ZydisApi         in '..\DebuggerCore\ZydisApi.pas',
  ZydisDisassembler in '..\DebuggerCore\ZydisDisassembler.pas',
  PeImageFile      in '..\DebuggerCore\PeImageFile.pas',
  RoutineAnalysis  in '..\DebuggerCore\RoutineAnalysis.pas',
  LiveCodeAnalysis in '..\DebuggerCore\LiveCodeAnalysis.pas';

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

  TLineRequest = record
    FileName: string;
    Line: Integer;
  end;

  TOptions = record
    BinaryPath: string;
    MapPath:    string;
    ZydisDll:   string;
    Lines:      TArray<TLineRequest>;
    NotCode:    Boolean;
    LastLines:  Boolean;
    ListLast:   Boolean;
    SourceDirs: TArray<string>;
  end;

function GetProcessMemoryInfo(Process: THandle; var Counters: TProcessMemoryCounters;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll';

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

procedure PrintUsage;
begin
  Writeln('Usage: BreakpointPlanProbe.exe <exe-or-bpl> [-map <file.map>] [-zydis <Zydis.dll>]');
  Writeln('                               [-line <source file>:<line>]... [-notcode]');
  Writeln('                               [-lastlines [-src <dir>]...]');
end;

function ParseOptions(out Options: TOptions): Boolean;
begin
  Options := Default(TOptions);
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    var HasValue := I < ParamCount;
    if SameText(Arg, '-map') and HasValue then begin
      Options.MapPath := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end else if SameText(Arg, '-zydis') and HasValue then begin
      Options.ZydisDll := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end else if SameText(Arg, '-line') and HasValue then begin
      var Value := ParamStr(I + 1);
      var Colon := Value.LastIndexOf(':');
      var Request: TLineRequest;
      if (Colon <= 0) or not TryStrToInt(Value.Substring(Colon + 1), Request.Line) then
        Exit(False);
      Request.FileName := Value.Substring(0, Colon);
      Options.Lines := Options.Lines + [Request];
      Inc(I);
    end else if SameText(Arg, '-notcode') then
      Options.NotCode := True
    else if SameText(Arg, '-lastlines') then
      Options.LastLines := True
    else if SameText(Arg, '-listlast') then begin
      Options.LastLines := True;
      Options.ListLast  := True;
    end
    else if SameText(Arg, '-src') and HasValue then begin
      Options.SourceDirs := Options.SourceDirs + [ExpandFileName(ParamStr(I + 1))];
      Inc(I);
    end
    else if Arg.StartsWith('-') then
      Exit(False)
    else if Options.BinaryPath = '' then
      Options.BinaryPath := ExpandFileName(Arg)
    else
      Exit(False);
    Inc(I);
  end;
  if Options.ZydisDll = '' then
    Options.ZydisDll := ResolveZydisDllPathForThisExe;
  Result := Options.BinaryPath <> '';
end;

function VerdictText(const Line: TRoutineLine): string;
begin
  case Line.Verdict of
    lvConfirmed:   Result := 'confirmed';
    lvNotCode:     Result := 'NOT CODE';
  else
    Result := 'unconfirmed';
  end;
  Result := Result + ' (' + LineVerdictReasonText(Line.Reason) + ')';
end;

procedure ReportLine(Analysis: TLiveCodeAnalysis; Reader: TTD32FileReader; Map: TModuleCodeMap;
  Analyzer: TRoutineAnalyzer; ImageBase: UInt64; const Request: TLineRequest);
begin
  Writeln;
  Writeln(Format('%s:%d', [Request.FileName, Request.Line]));
  // What a line-table provider answers: one address for the line.
  var PrimaryRva: UInt64 := 0;
  var HasPrimary := Reader.SourceLineToRva(Request.FileName, Request.Line, PrimaryRva);
  if not HasPrimary then begin
    Writeln('  the debug information has no address for this line');
    Exit;
  end;
  var Copies := Analysis.CopiesOf(ImageBase + PrimaryRva);

  var Listed := 0;
  for var FileIndex in Map.FindFiles(Request.FileName) do
    for var LineIndex in Map.LinesAt(FileIndex, Request.Line) do begin
      var Rec := Map.Lines[LineIndex];
      var Where := '<outside every routine>';
      if Rec.RoutineIndex >= 0 then
        Where := Map.Routines[Rec.RoutineIndex].Name;
      var Region, Root: Cardinal;
      var Piece := '';
      if Analyzer.CodeRegionOf(Rec.Rva, Region, Root) then
        if Region = Root then
          Piece := Format('  body $%.8x', [Root])
        else
          Piece := Format('  FUNCLET $%.8x of $%.8x', [Region, Root]);
      var Role := '    ';
      if Rec.Rva = PrimaryRva then
        Role := 'BP  '
      else
        for var CopyVA in Copies do
          if CopyVA = ImageBase + Rec.Rva then
            Role := 'COPY';
      var Verdict: TRoutineLine;
      var VerdictNote := 'no analysis';
      if Analysis.TryAnalyzeAddress(ImageBase + Rec.Rva, Verdict) then
        VerdictNote := VerdictText(Verdict);
      Writeln(Format('  %s $%.8x  %s%s  %s', [Role, Rec.Rva, Where, Piece, VerdictNote]));
      Inc(Listed);
    end;
  if Listed = 0 then
    Writeln(Format('  the code map has no record for the line (provider answered $%x)', [PrimaryRva]));
  var Reason: string;
  case Analysis.JudgeAddress(ImageBase + PrimaryRva, Reason) of
    pvPlant:      Writeln('  plant verdict for the provider''s address: plant');
    pvRefuse:     Writeln('  plant verdict for the provider''s address: REFUSE, ' + Reason);
  else
    Writeln('  plant verdict for the provider''s address: no analysis (zero-byte test applies)');
  end;
end;

procedure ReportNotCode(Map: TModuleCodeMap; Analyzer: TRoutineAnalyzer);
begin
  Writeln;
  Writeln('line records the analysis shows not to be the start of an instruction');
  var Found := 0;
  var Lines := Map.Lines;
  var I := 0;
  while I <= High(Lines) do begin
    // One analysis per routine; a record outside every routine on its own.
    if Lines[I].RoutineIndex < 0 then begin
      var Stray := Analyzer.AnalyzeLine(I);
      if Stray.Verdict = lvNotCode then begin
        Writeln(Format('  $%.8x  %s:%d  <outside every routine>  %s', [Lines[I].Rva,
          Map.Files[Lines[I].FileIndex].Name, Lines[I].Line, LineVerdictReasonText(Stray.Reason)]));
        Inc(Found);
      end;
      Inc(I);
      Continue;
    end;
    var Routine := Lines[I].RoutineIndex;
    var Analysis := Analyzer.Analyze(Routine);
    for var Item in Analysis.Lines do
      if Item.Verdict = lvNotCode then begin
        var Rec := Lines[Item.LineIndex];
        Writeln(Format('  $%.8x  %s:%d  %s  %s', [Rec.Rva, Map.Files[Rec.FileIndex].Name, Rec.Line,
          Map.Routines[Routine].Name, LineVerdictReasonText(Item.Reason)]));
        Inc(Found);
      end;
    I := Map.Routines[Routine].FirstLine + Map.Routines[Routine].LineCount;
  end;
  Writeln(Format('  %d records', [Found]));
end;

// Every source file under the given roots, by lowercase name.
function IndexSources(const Dirs: TArray<string>): TDictionary<string, TArray<string>>;
begin
  Result := TDictionary<string, TArray<string>>.Create;
  for var Dir in Dirs do begin
    if not TDirectory.Exists(Dir) then begin
      Writeln('  -src: no such directory: ', Dir);
      Continue;
    end;
    for var Path in TDirectory.GetFiles(Dir, '*.*', TSearchOption.soAllDirectories) do begin
      var Ext := LowerCase(ExtractFileExt(Path));
      if (Ext <> '.pas') and (Ext <> '.dpr') and (Ext <> '.inc') and (Ext <> '.dpk') then
        Continue;
      var Key := LowerCase(ExtractFileName(Path));
      var Known: TArray<string>;
      Result.TryGetValue(Key, Known);
      Result.AddOrSetValue(Key, Known + [Path]);
    end;
  end;
end;

// The text of a source line, from the first file of that name that is long
// enough; a file whose line is a bare "end." is preferred when several share
// the name. Found is False when no file of the name has that many lines.
function SourceLineText(Sources: TDictionary<string, TArray<string>>;
  Cache: TDictionary<string, TArray<string>>; const FileName: string; Line: Integer;
  out Found: Boolean): string;
begin
  Result := '';
  Found := False;
  var Paths: TArray<string>;
  if not Sources.TryGetValue(LowerCase(FileName), Paths) then
    Exit;
  for var Path in Paths do begin
    var Text: TArray<string>;
    if not Cache.TryGetValue(Path, Text) then begin
      try
        Text := TFile.ReadAllLines(Path);
      except
        Text := nil;
      end;
      Cache.Add(Path, Text);
    end;
    if (Line < 1) or (Line > Length(Text)) then
      Continue;
    var Candidate := Text[Line - 1].Trim;
    if SameText(Candidate, 'end.') then begin
      Found := True;
      Exit(Candidate);
    end;
    if not Found then begin
      Found := True;
      Result := Candidate;
    end;
  end;
end;

procedure ReportLastLines(Map: TModuleCodeMap; Analyzer: TRoutineAnalyzer; Image: TPeImageFile;
  const Options: TOptions);
type
  TBytes3 = (bZero, bUndecodable, bDecodes);
const
  BYTES_TEXT: array[TBytes3] of string = ('byte is $00', 'bytes are no instruction', 'bytes decode');
var
  Code: array[0..15] of Byte;
begin
  Writeln;
  Writeln('records outside every routine, and the last line of each file');
  var Sources := IndexSources(Options.SourceDirs);
  var Cache := TDictionary<string, TArray<string>>.Create;
  try
    var Lines := Map.Lines;
    var Outside := 0;
    var InPdata := 0;
    var Qualify := 0;
    var QualifyInPdata := 0;
    var ByBytes: array[TBytes3] of Integer;
    var OthersByBytes: array[TBytes3] of Integer;
    // The rule as the analyzer applies it (TRoutineAnalyzer.IsFinalEndOfUnit).
    var Taken := 0;
    var TakenByBytes: array[TBytes3] of Integer;
    FillChar(TakenByBytes, SizeOf(TakenByBytes), 0);
    FillChar(ByBytes, SizeOf(ByBytes), 0);
    FillChar(OthersByBytes, SizeOf(OthersByBytes), 0);
    var IsEnd := 0;
    var NotEnd := 0;
    var NoSource := 0;
    var Listed := 0;
    var Mode := zmmLegacy32;
    if Image.Is64 then
      Mode := zmmLong64;
    for var I := 0 to High(Lines) do begin
      if Lines[I].RoutineIndex >= 0 then
        Continue;
      Inc(Outside);
      // x64: a record inside a function .pdata knows (an anonymous method's
      // body) is analysed from that function's entry; the rule is not for it.
      var Region, Root: Cardinal;
      var Pdata := Analyzer.CodeRegionOf(Lines[I].Rva, Region, Root);
      if Pdata then
        Inc(InPdata);
      FillChar(Code, SizeOf(Code), 0);
      var Got := Image.Read(Image.ImageBase + Lines[I].Rva, @Code[0], SizeOf(Code));
      var Kind := bDecodes;
      var Detail: TZydisInstructionDetail;
      if (Got <= 0) or (Code[0] = 0) then
        Kind := bZero
      else if not ZydisDecodeDetail(Mode, Image.ImageBase + Lines[I].Rva, Code, Got, Detail) then
        Kind := bUndecodable;
      var Qualifies := Map.LastLineOutsideRoutines(Lines[I].FileIndex) = Lines[I].Line;
      if not Qualifies then begin
        if not Pdata then
          Inc(OthersByBytes[Kind]);
        Continue;
      end;
      if Pdata then begin
        Inc(QualifyInPdata);
        Writeln(Format('  in a .pdata function although the last line of its file: $%.8x %s:%d',
          [Lines[I].Rva, Map.Files[Lines[I].FileIndex].Name, Lines[I].Line]));
        Continue;
      end;
      Inc(Qualify);
      Inc(ByBytes[Kind]);
      if not Analyzer.IsFinalEndOfUnit(I) then begin
        Writeln(Format('  NOT TAKEN by the rule (not the own file of unit %s): $%.8x %s:%d  [%s]',
          [Map.UnitName(Lines[I].UnitIndex), Lines[I].Rva, Map.Files[Lines[I].FileIndex].Name, Lines[I].Line,
           BYTES_TEXT[Kind]]));
        Continue;
      end;
      Inc(Taken);
      Inc(TakenByBytes[Kind]);
      if Options.ListLast then begin
        // Where the record sits among the routines: how far past the end of
        // the nearest routine below it, whose unit that routine is, and
        // whether a routine of the record's own unit starts above it.
        var Below := -1;
        var Lo := 0;
        var Hi := High(Map.Routines);
        while Lo <= Hi do begin
          var Mid := (Lo + Hi) shr 1;
          if Map.Routines[Mid].StartRva <= Lines[I].Rva then begin
            Below := Mid;
            Lo := Mid + 1;
          end else
            Hi := Mid - 1;
        end;
        var Gap: Int64 := -1;
        var BelowUnit: string := '?';
        if Below >= 0 then begin
          Gap := Int64(Lines[I].Rva) - Map.Routines[Below].EndRva;
          BelowUnit := 'other';
          if Map.Routines[Below].UnitIndex = Lines[I].UnitIndex then
            BelowUnit := 'own';
        end;
        var OwnAbove: string := 'no';
        for var K := Below + 1 to High(Map.Routines) do begin
          if K - Below > 4000 then
            Break;
          if Map.Routines[K].UnitIndex = Lines[I].UnitIndex then begin
            OwnAbove := 'YES';
            Break;
          end;
        end;
        Writeln(Format('  LAST: $%.8x %s:%d  [%s]  gap=%d below=%s ownRoutineAbove=%s unit=%s', [Lines[I].Rva,
          Map.Files[Lines[I].FileIndex].Name, Lines[I].Line, BYTES_TEXT[Kind], Gap, BelowUnit, OwnAbove,
          Map.UnitName(Lines[I].UnitIndex)]));
      end;
      if Sources.Count = 0 then
        Continue;
      var Found: Boolean;
      var Text := SourceLineText(Sources, Cache, Map.Files[Lines[I].FileIndex].Name, Lines[I].Line, Found);
      if not Found then
        Inc(NoSource)
      else if SameText(Text, 'end.') then
        Inc(IsEnd)
      else begin
        Inc(NotEnd);
        if Listed < 200 then
          Writeln(Format('  NOT "end.": $%.8x %s:%d  [%s]  %s', [Lines[I].Rva,
            Map.Files[Lines[I].FileIndex].Name, Lines[I].Line, BYTES_TEXT[Kind], Text]));
        Inc(Listed);
      end;
    end;
    Writeln(Format('  outside every routine                         %d', [Outside]));
    Writeln(Format('    of which inside a .pdata function (x64)     %d', [InPdata]));
    Writeln(Format('  on the last line of their file, no record of that line in a routine: %d', [Qualify]));
    for var Kind := Low(TBytes3) to High(TBytes3) do
      Writeln(Format('      %-26s %d', [BYTES_TEXT[Kind], ByBytes[Kind]]));
    Writeln(Format('    the same, but inside a .pdata function      %d', [QualifyInPdata]));
    Writeln(Format('  of those, in the own file of their unit -- what the rule calls a final "end.": %d', [Taken]));
    for var Kind := Low(TBytes3) to High(TBytes3) do
      Writeln(Format('      %-26s %d', [BYTES_TEXT[Kind], TakenByBytes[Kind]]));
    if Sources.Count > 0 then begin
      Writeln(Format('    source says "end."                          %d', [IsEnd]));
      Writeln(Format('    source says something else                  %d', [NotEnd]));
      Writeln(Format('    source not found                            %d', [NoSource]));
    end;
    Writeln('  the other records outside every routine and every .pdata function');
    for var Kind := Low(TBytes3) to High(TBytes3) do
      Writeln(Format('      %-26s %d', [BYTES_TEXT[Kind], OthersByBytes[Kind]]));
  finally
    Cache.Free;
    Sources.Free;
  end;
end;

procedure Run(const Options: TOptions);
begin
  var Image := TPeImageFile.Create(Options.BinaryPath);
  try
    var Bits := 32;
    if Image.Is64 then
      Bits := 64;
    Writeln(Format('%s  (%d-bit, image size $%x)', [Options.BinaryPath, Bits, Image.SizeOfImage]));

    // --- what the session has paid before any breakpoint is set ---
    var Reader := TTD32FileReader.Create;
    var ReaderRef: IInterface := Reader;
    var Clock := TStopwatch.StartNew;
    Reader.LoadFromFile(Options.BinaryPath);
    var Td32Ms := Clock.Elapsed.TotalMilliseconds;

    var MapReader: TMapFile := nil;
    var MapRef: IInterface := nil;
    var MapLoadMs := 0.0;
    var MapIndexMs := 0.0;
    if (Options.MapPath <> '') and not FileExists(Options.MapPath) then
      // A TMapFile over a file that is not there reports its index as pending
      // for ever; the wait below would only run out.
      raise Exception.Create('-map: no such file: ' + Options.MapPath);
    if Options.MapPath <> '' then begin
      MapReader := TMapFile.Create;
      MapRef := MapReader;
      Clock := TStopwatch.StartNew;
      MapReader.LoadFromFile(Options.MapPath, ReadPEPreferredBase(Options.BinaryPath));
      MapLoadMs := Clock.Elapsed.TotalMilliseconds;
      // The publics are indexed on a background thread; the session never
      // waits for them, and the code map is built without the MAP until they
      // are ready. Waiting here measures the case where they are.
      Clock := TStopwatch.StartNew;
      while MapReader.BackgroundIndexingPending and (Clock.Elapsed.TotalSeconds < 120) do
        Sleep(5);
      MapIndexMs := Clock.Elapsed.TotalMilliseconds;
    end;

    var Providers: TArray<IInterface> := [ReaderRef];
    if MapRef <> nil then
      Providers := Providers + [MapRef];
    var ImageBase := Image.ImageBase;
    var ImageSize: UInt64 := Image.SizeOfImage;
    var ModuleName := ExtractFileName(Options.BinaryPath);

    var Analysis := TLiveCodeAnalysis.Create(Image.Read,
      function(VA: UInt64; out Info: TLiveModuleInfo): Boolean
      begin
        Info := Default(TLiveModuleInfo);
        Result := (VA >= ImageBase) and (VA - ImageBase < ImageSize);
        if not Result then
          Exit;
        Info.Name      := ModuleName;
        Info.Base      := ImageBase;
        Info.Size      := ImageSize;
        Info.Providers := Providers;
      end);
    try
      Analysis.ZydisDllPath := Options.ZydisDll;

      // --- the first breakpoint: any address of the module ---
      // The address a provider gives for the first requested line, or the
      // entry point of the program when no line was asked for.
      var FirstRva: UInt64 := 0;
      if (Length(Options.Lines) = 0) or
         not Reader.SourceLineToRva(Options.Lines[0].FileName, Options.Lines[0].Line, FirstRva) then begin
        var Head: array[0..$3FF] of Byte;
        Image.Read(ImageBase, @Head[0], SizeOf(Head));
        FirstRva := PCardinal(@Head[PCardinal(@Head[$3C])^ + 40])^;
      end;
      var Before := PrivateBytes;
      Clock := TStopwatch.StartNew;
      var Reason: string;
      var FirstVerdict := Analysis.JudgeAddress(ImageBase + FirstRva, Reason);
      var FirstMs := Clock.Elapsed.TotalMilliseconds;
      var Growth := PrivateBytes - Before;
      Clock := TStopwatch.StartNew;
      Analysis.JudgeAddress(ImageBase + FirstRva, Reason);
      var AgainMs := Clock.Elapsed.TotalMilliseconds;

      var Stats := Analysis.Stats;
      Writeln('paid when the session starts, breakpoint or not');
      Writeln(Format('  TD32 load                              %8.0f ms', [Td32Ms]));
      if MapReader <> nil then begin
        Writeln(Format('  MAP load (sections indexed)            %8.0f ms', [MapLoadMs]));
        Writeln(Format('  MAP publics, background thread         %8.0f ms more until ready', [MapIndexMs]));
      end;
      Writeln('the first source breakpoint in the module');
      Writeln(Format('  first verdict, everything included     %8.1f ms  (address $%x: %d)',
        [FirstMs, FirstRva, Ord(FirstVerdict)]));
      if Length(Stats) = 1 then begin
        Writeln(Format('    of which the code map                %8.1f ms  (%d line records, %d routines, %d from the MAP)',
          [Stats[0].MapBuildMs, Stats[0].LineCount, Stats[0].RoutineCount,
           Stats[0].SecondProviderRoutineCount]));
        Writeln(Format('    of which the analyzer set-up         %8.1f ms  (decoder available: %s)',
          [Stats[0].AnalyzerSetupMs, BoolToStr(Stats[0].DecoderAvailable, True)]));
      end else
        Writeln('    no code map was built: ' + IntToStr(Length(Stats)) + ' modules analysed');
      Writeln(Format('  private bytes grown by it              %8.1f MB', [Growth / (1024 * 1024)]));
      Writeln(Format('  the same address asked again           %8.3f ms', [AgainMs]));

      if (Length(Options.Lines) = 0) and not Options.NotCode and not Options.LastLines then
        Exit;

      // The probe's own map and analyzer, for listing: the store keeps its
      // own private.
      var LineProvider: ILineRecordProvider;
      var RoutineProvider: IRoutineRangeProvider;
      if not TModuleCodeMap.PickProviders(Providers, LineProvider, RoutineProvider) then begin
        Writeln('no provider of line records and routine ranges');
        Exit;
      end;
      var Second: IRoutineRangeProvider := nil;
      if not Image.Is64 then
        Second := TModuleCodeMap.PickSecondRoutineProvider(Providers, RoutineProvider);
      var Map := TModuleCodeMap.Build(ModuleName, LineProvider, RoutineProvider, 0, ImageSize, nil, Second);
      try
        var Input := Default(TRoutineAnalysisInput);
        if Image.Is64 then
          Input.Mode := dmmLong64
        else
          Input.Mode := dmmLegacy32;
        Input.Reader       := Image.Read;
        Input.ImageBase    := ImageBase;
        Input.CodeMap      := Map;
        Input.ZydisDllPath := Options.ZydisDll;
        var Analyzer := TRoutineAnalyzer.Create(Input);
        try
          Clock := TStopwatch.StartNew;
          for var Request in Options.Lines do
            ReportLine(Analysis, Reader, Map, Analyzer, ImageBase, Request);
          if Options.NotCode then
            ReportNotCode(Map, Analyzer);
          if Options.LastLines then
            ReportLastLines(Map, Analyzer, Image, Options);
        finally
          Analyzer.Free;
        end;
      finally
        Map.Free;
      end;
    finally
      Analysis.Free;
    end;
  finally
    Image.Free;
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
