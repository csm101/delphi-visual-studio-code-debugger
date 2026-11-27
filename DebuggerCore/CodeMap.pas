unit CodeMap;

// The code map of ONE module: every routine and every line record its debug
// information knows, joined once so that a consumer which must touch every line
// (coverage, profiling) does not ask a provider about one address at a time.
//
// What it adds to the two provider tables it is built from
// (ILineRecordProvider, IRoutineRangeProvider):
//
//   * MODULE-RELATIVE RVAs. The engine's RVA space is anchored at the main
//     executable, and the providers of a DLL/BPL answer shifted by
//     `Base - exeImageBase` (ModuleSymbolLoader.ModuleRvaRange). That shift
//     depends on where the module happened to be loaded, so nothing kept past a
//     run may carry it. The map takes the shift as an argument and removes it;
//     a map built from the file (shift 0) and one built from a live module's
//     shifted provider are identical.
//   * The routine of each line record, or -1. A record is "in a routine" only
//     when it lies inside a routine RANGE. The ones that do not are kept,
//     flagged (RoutineIndex = -1) and counted: about 0.5 % of a real binary's
//     records, mostly anonymous-method bodies, and some of the rest point at
//     DATA (docs/TD32_FORMAT_NOTES.md, "What a line record points at"). Nothing
//     may be planted on them.
//   * The length of each record's code: the distance to the next record or to
//     the end of its routine, whichever is nearer.
//   * Lookups: RVA -> line record, RVA -> routine, (file, line) -> its records.
//
// The unit depends on DebugInfoTypes and nothing else of the engine: no
// session, no process, no front end. Source paths are resolved through a
// callback for the same reason, so a map can be built from a binary on disk.
//
// A map is immutable once Build returns and can be read from any thread.

{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

interface

uses
  System.SysUtils, System.Generics.Collections,
  DebugInfoTypes;

type
  /// <summary>Maps a source file as the debug information recorded it to a
  /// path on this machine.</summary>
  /// <param name="FileName">File name without a directory.</param>
  /// <param name="RecordedPath">Path recorded at compile time; may be empty.</param>
  /// <returns>The resolved path, or an empty string when the file is not found.</returns>
  TCodeMapPathResolver = reference to function(const FileName, RecordedPath: string): string;

  /// <summary>One source file of a code map.</summary>
  TCodeMapFile = record
    /// <summary>File name as recorded, without a directory.</summary>
    Name: string;
    /// <summary>Path as recorded at compile time; empty when the format keeps
    /// the name only.</summary>
    RecordedPath: string;
    /// <summary>What the resolver returned for the file; empty when it found
    /// nothing or when the map was built without a resolver.</summary>
    ResolvedPath: string;
  end;

  /// <summary>One routine of a code map.</summary>
  TCodeMapRoutine = record
    /// <summary>First byte, module-relative.</summary>
    StartRva: Cardinal;
    /// <summary>One past the last byte (exclusive), module-relative, as the
    /// provider reported it.</summary>
    EndRva: Cardinal;
    /// <summary>Routine name as the provider spells it.</summary>
    Name: string;
    /// <summary>Index into <c>TModuleCodeMap.Units</c>, or -1 when unknown.</summary>
    UnitIndex: Integer;
    /// <summary>True when <c>EndRva</c> was derived rather than recorded.</summary>
    EndIsApproximate: Boolean;
    /// <summary>Index of the routine's first line record, or -1 when it has
    /// none. Its records are contiguous in <c>TModuleCodeMap.Lines</c>.</summary>
    FirstLine: Integer;
    /// <summary>Number of line records inside the routine.</summary>
    LineCount: Integer;
  end;

  /// <summary>One line record of a code map.</summary>
  TCodeMapLine = record
    /// <summary>Address, module-relative.</summary>
    Rva: Cardinal;
    /// <summary>Bytes from this record to the next one or to the end of its
    /// routine, whichever is nearer. For a record outside every routine: to
    /// the next record or the next routine. 0 when nothing follows.</summary>
    CodeLength: Cardinal;
    /// <summary>1-based source line.</summary>
    Line: Integer;
    /// <summary>Index into <c>TModuleCodeMap.Files</c>.</summary>
    FileIndex: Integer;
    /// <summary>Index into <c>TModuleCodeMap.Routines</c> of the routine whose
    /// range contains the record, or -1: the record lies outside every routine
    /// and must not be patched.</summary>
    RoutineIndex: Integer;
    /// <summary>Index into <c>TModuleCodeMap.Units</c>, or -1 when unknown.</summary>
    UnitIndex: Integer;
    /// <summary>Whether the record lies inside a routine range.</summary>
    /// <returns>False for a record that is kept and counted but never used.</returns>
    function InRoutine: Boolean; inline;
  end;

  /// <summary>Routines, line records and files of one module, in
  /// module-relative RVAs. Immutable once built.</summary>
  TModuleCodeMap = class
  private
    FModuleName:          string;
    FRvaShift:            UInt64;
    FLimit:               UInt64;   // module-relative RVAs are < FLimit
    FRoutines:            TArray<TCodeMapRoutine>;
    FLines:               TArray<TCodeMapLine>;
    FFiles:               TArray<TCodeMapFile>;
    FUnits:               TArray<string>;
    // Line record indexes ordered by (file, line, RVA), and where each file's
    // run starts in it (one extra entry closes the last run).
    FByFileLine:          TArray<Integer>;
    FFileFirst:           TArray<Integer>;
    FOutsideRoutineCount: Integer;
    FDroppedLineCount:    Integer;
    FDroppedRoutineCount: Integer;
    FLinesComplete:       Boolean;
    FRoutinesComplete:    Boolean;
    FBuildMs:             Double;
    function  ToModuleRva(ProviderRva: UInt64; out Rva: Cardinal): Boolean;
    function  ToModuleEnd(ProviderEndRva: UInt64; StartRva: Cardinal): Cardinal;
    function  EffectiveEnd(RoutineIndex: Integer): Cardinal;
    procedure LoadRoutines(const Provider: IRoutineRangeProvider;
      UnitIds: TDictionary<string, Integer>);
    procedure LoadLines(const Provider: ILineRecordProvider;
      UnitIds: TDictionary<string, Integer>; const Resolver: TCodeMapPathResolver);
    procedure SortRoutinesByStart;
    procedure SortLinesByRva;
    procedure LinkLinesToRoutines;
    procedure SpreadUnits;
    procedure IndexByFileAndLine;
    function  InternUnit(UnitIds: TDictionary<string, Integer>; const UnitName: string): Integer;
    function  GetComplete: Boolean;
  public
    /// <summary>Picks, from a module's providers in order of preference, the
    /// two a code map is built from.</summary>
    /// <remarks>A provider that supplies BOTH tables wins over an earlier one
    /// that supplies only one: lines and ranges read from the same format agree
    /// by construction. Failing that, the first provider of each kind is taken.</remarks>
    /// <param name="Candidates">The module's providers, most trusted first
    /// (TD32 or .tds, then MAP, then JDBG). Nil entries are skipped.</param>
    /// <param name="LineProvider">The line-table provider, or nil.</param>
    /// <param name="RoutineProvider">The routine-range provider, or nil.</param>
    /// <returns>True when both were found; False means the module cannot be
    /// measured with the formats it has (for example only .rsm or .dcp).</returns>
    class function PickProviders(const Candidates: array of IInterface;
      out LineProvider: ILineRecordProvider;
      out RoutineProvider: IRoutineRangeProvider): Boolean; static;
    /// <summary>Builds the code map of one module.</summary>
    /// <param name="ModuleName">Name of the module, kept for reports.</param>
    /// <param name="LineProvider">Source of the line records.</param>
    /// <param name="RoutineProvider">Source of the routine ranges.</param>
    /// <param name="RvaShift">What the providers add to a module-relative RVA:
    /// 0 for a provider opened on the file (or the main executable), the
    /// module's <c>Base - exeImageBase</c> for a runtime module of a session.</param>
    /// <param name="ImageSize">The module's SizeOfImage, or 0 when unknown.
    /// Records and routines that do not fall inside it are dropped and counted.</param>
    /// <param name="Resolver">Optional; fills <c>TCodeMapFile.ResolvedPath</c>.</param>
    /// <returns>The map; the caller owns it.</returns>
    /// <exception cref="EArgumentNilException">A provider is nil.</exception>
    class function Build(const ModuleName: string;
      const LineProvider: ILineRecordProvider;
      const RoutineProvider: IRoutineRangeProvider;
      RvaShift, ImageSize: UInt64;
      const Resolver: TCodeMapPathResolver = nil): TModuleCodeMap; static;

    /// <summary>Index of the line record AT an address.</summary>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>The index into <c>Lines</c>, or -1 when no record starts there.</returns>
    function FindLine(Rva: Cardinal): Integer;
    /// <summary>Index of the line record whose code COVERS an address.</summary>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>The index into <c>Lines</c> of the record with
    /// <c>Rva</c> in <c>[record, record + CodeLength)</c>, or -1.</returns>
    function FindLineCovering(Rva: Cardinal): Integer;
    /// <summary>Index of the routine whose range contains an address.</summary>
    /// <remarks>The routine is the one with the nearest start at or below the
    /// address, and only if the address is below its end: the same rule the
    /// providers' <c>RvaToFunctionStart</c> applies.</remarks>
    /// <param name="Rva">Module-relative address.</param>
    /// <returns>The index into <c>Routines</c>, or -1.</returns>
    function FindRoutine(Rva: Cardinal): Integer;
    /// <summary>Files matching a name or a path.</summary>
    /// <param name="FileNameOrPath">A file name, compared without regard to
    /// case; when it carries a directory and some file's recorded or resolved
    /// path equals it, only those files are returned.</param>
    /// <returns>Indexes into <c>Files</c>; empty when none matches.</returns>
    function FindFiles(const FileNameOrPath: string): TArray<Integer>;
    /// <summary>Every line record of one source line.</summary>
    /// <param name="FileIndex">Index into <c>Files</c>.</param>
    /// <param name="Line">1-based source line.</param>
    /// <returns>Indexes into <c>Lines</c>, by ascending address; empty when
    /// the line has no code. One line can have several records (a loop header,
    /// a generic instantiated more than once).</returns>
    function LinesAt(FileIndex, Line: Integer): TArray<Integer>;
    /// <summary>Every line record of one source file.</summary>
    /// <param name="FileIndex">Index into <c>Files</c>.</param>
    /// <returns>Indexes into <c>Lines</c>, ordered by line and then address.</returns>
    function LinesOfFile(FileIndex: Integer): TArray<Integer>;
    /// <summary>Name of a unit.</summary>
    /// <param name="UnitIndex">Index into <c>Units</c>, or -1.</param>
    /// <returns>The name, or an empty string for -1.</returns>
    function UnitName(UnitIndex: Integer): string;
    /// <summary>Bytes held by the map's tables (routines, line records, the
    /// (file, line) index), excluding strings.</summary>
    /// <returns>The size in bytes.</returns>
    function TableBytes: Int64;
    /// <summary>Bytes of the strings the map references: routine, file and
    /// unit names and paths.</summary>
    /// <remarks>Routine names are shared with the provider while it is alive,
    /// so they cost this much only once the provider is gone.</remarks>
    /// <returns>The size in bytes.</returns>
    function NameBytes: Int64;

    /// <summary>Module name given to <c>Build</c>.</summary>
    property ModuleName: string read FModuleName;
    /// <summary>Routines, sorted by <c>StartRva</c>, one per distinct start.
    /// Read-only: do not modify the array.</summary>
    property Routines: TArray<TCodeMapRoutine> read FRoutines;
    /// <summary>Line records, sorted by <c>Rva</c>, one per distinct address.
    /// Read-only: do not modify the array.</summary>
    property Lines: TArray<TCodeMapLine> read FLines;
    /// <summary>Source files. Read-only: do not modify the array.</summary>
    property Files: TArray<TCodeMapFile> read FFiles;
    /// <summary>Unit names. Read-only: do not modify the array.</summary>
    property Units: TArray<string> read FUnits;
    /// <summary>Line records that lie outside every routine range.</summary>
    property OutsideRoutineCount: Integer read FOutsideRoutineCount;
    /// <summary>Line records the provider returned that were dropped: outside
    /// the image, without a valid file, or repeating an address.</summary>
    property DroppedLineCount: Integer read FDroppedLineCount;
    /// <summary>Routines the provider returned that were dropped: outside the
    /// image, or repeating a start address.</summary>
    property DroppedRoutineCount: Integer read FDroppedRoutineCount;
    /// <summary>Whether the line provider enumerated everything.</summary>
    property LinesComplete: Boolean read FLinesComplete;
    /// <summary>Whether the routine provider enumerated everything.</summary>
    property RoutinesComplete: Boolean read FRoutinesComplete;
    /// <summary>Both providers enumerated everything.</summary>
    property Complete: Boolean read GetComplete;
    /// <summary>Wall time <c>Build</c> took, in milliseconds, including the
    /// providers' own enumeration.</summary>
    property BuildMs: Double read FBuildMs;
  end;

implementation

uses
  System.Diagnostics, System.Generics.Defaults;

const
  // A PE image is smaller than 4 GB, so a module-relative RVA fits 32 bits.
  // Used as the bound when the caller does not know the image size.
  MAX_IMAGE_SPAN = UInt64($100000000);
  // Past this the (file, line) index is built with a comparison sort instead
  // of a counting pass: no compiler emits such line numbers, and a count array
  // of that size would cost more than the sort.
  MAX_COUNTED_LINE = 4 * 1024 * 1024;

{ TCodeMapLine }

function TCodeMapLine.InRoutine: Boolean;
begin
  Result := RoutineIndex >= 0;
end;

{ TModuleCodeMap }

class function TModuleCodeMap.PickProviders(const Candidates: array of IInterface;
  out LineProvider: ILineRecordProvider;
  out RoutineProvider: IRoutineRangeProvider): Boolean;
begin
  for var Candidate in Candidates do begin
    if Candidate = nil then
      Continue;
    if Supports(Candidate, ILineRecordProvider, LineProvider) and
       Supports(Candidate, IRoutineRangeProvider, RoutineProvider) then
      Exit(True);
  end;
  LineProvider    := nil;
  RoutineProvider := nil;
  for var Candidate in Candidates do begin
    if Candidate = nil then
      Continue;
    if LineProvider = nil then
      Supports(Candidate, ILineRecordProvider, LineProvider);
    if RoutineProvider = nil then
      Supports(Candidate, IRoutineRangeProvider, RoutineProvider);
  end;
  Result := (LineProvider <> nil) and (RoutineProvider <> nil);
end;

class function TModuleCodeMap.Build(const ModuleName: string;
  const LineProvider: ILineRecordProvider;
  const RoutineProvider: IRoutineRangeProvider;
  RvaShift, ImageSize: UInt64;
  const Resolver: TCodeMapPathResolver): TModuleCodeMap;
begin
  if LineProvider = nil then
    raise EArgumentNilException.Create('TModuleCodeMap.Build: no line record provider');
  if RoutineProvider = nil then
    raise EArgumentNilException.Create('TModuleCodeMap.Build: no routine range provider');
  var Clock := TStopwatch.StartNew;
  Result := TModuleCodeMap.Create;
  try
    Result.FModuleName := ModuleName;
    Result.FRvaShift   := RvaShift;
    Result.FLimit      := MAX_IMAGE_SPAN;
    if (ImageSize > 0) and (ImageSize < MAX_IMAGE_SPAN) then
      Result.FLimit := ImageSize;
    // Unit names arrive from both providers; one table serves both.
    var UnitIds := TDictionary<string, Integer>.Create;
    try
      Result.LoadRoutines(RoutineProvider, UnitIds);
      Result.LoadLines(LineProvider, UnitIds, Resolver);
    finally
      UnitIds.Free;
    end;
    Result.LinkLinesToRoutines;
    Result.SpreadUnits;
    Result.IndexByFileAndLine;
    Result.FBuildMs := Clock.Elapsed.TotalMilliseconds;
  except
    Result.Free;
    raise;
  end;
end;

function TModuleCodeMap.GetComplete: Boolean;
begin
  Result := FLinesComplete and FRoutinesComplete;
end;

function TModuleCodeMap.ToModuleRva(ProviderRva: UInt64; out Rva: Cardinal): Boolean;
// Removes the provider's shift. The subtraction wraps on purpose: the shift of
// a module loaded BELOW the main executable is `Base - exeImageBase` modulo
// 2^64, and the provider added it with the same wrap-around.
begin
  {$OVERFLOWCHECKS OFF}{$RANGECHECKS OFF}
  var Relative: UInt64 := ProviderRva - FRvaShift;
  {$OVERFLOWCHECKS ON}{$RANGECHECKS ON}
  Rva := 0;
  Result := Relative < FLimit;
  if Result then
    Rva := Cardinal(Relative);
end;

function TModuleCodeMap.ToModuleEnd(ProviderEndRva: UInt64; StartRva: Cardinal): Cardinal;
// A routine's exclusive end, held to [StartRva, image end]. An end below the
// start is a damaged record: the routine is kept, empty.
begin
  {$OVERFLOWCHECKS OFF}{$RANGECHECKS OFF}
  var Relative: UInt64 := ProviderEndRva - FRvaShift;
  {$OVERFLOWCHECKS ON}{$RANGECHECKS ON}
  var Highest: UInt64 := FLimit;
  if Highest > High(Cardinal) then
    Highest := High(Cardinal);
  if Relative > Highest then
    Relative := Highest;
  if Relative < StartRva then
    Relative := StartRva;
  Result := Cardinal(Relative);
end;

function TModuleCodeMap.InternUnit(UnitIds: TDictionary<string, Integer>;
  const UnitName: string): Integer;
begin
  if UnitName = '' then
    Exit(-1);
  var Key := AnsiLowerCase(UnitName);
  if UnitIds.TryGetValue(Key, Result) then
    Exit;
  Result := Length(FUnits);
  FUnits := FUnits + [UnitName];
  UnitIds.Add(Key, Result);
end;

procedure TModuleCodeMap.LoadRoutines(const Provider: IRoutineRangeProvider;
  UnitIds: TDictionary<string, Integer>);
begin
  var Ranges := Provider.RoutineRanges(FRoutinesComplete);
  SetLength(FRoutines, Length(Ranges));
  var Count := 0;
  var InOrder := True;
  for var I := 0 to High(Ranges) do begin
    var StartRva: Cardinal;
    if not ToModuleRva(Ranges[I].StartRva, StartRva) then begin
      Inc(FDroppedRoutineCount);
      Continue;
    end;
    if (Count > 0) and (StartRva <= FRoutines[Count - 1].StartRva) then
      InOrder := False;
    FRoutines[Count].StartRva         := StartRva;
    FRoutines[Count].EndRva           := ToModuleEnd(Ranges[I].EndRva, StartRva);
    FRoutines[Count].Name             := Ranges[I].Name;
    FRoutines[Count].UnitIndex        := InternUnit(UnitIds, Ranges[I].UnitName);
    FRoutines[Count].EndIsApproximate := Ranges[I].EndIsApproximate;
    FRoutines[Count].FirstLine        := -1;
    FRoutines[Count].LineCount        := 0;
    Inc(Count);
  end;
  SetLength(FRoutines, Count);
  // A provider returns its table sorted with one row per start. Everything
  // below bisects, so that is verified here and repaired rather than trusted.
  if not InOrder then
    SortRoutinesByStart;
end;

procedure TModuleCodeMap.SortRoutinesByStart;
begin
  TArray.Sort<TCodeMapRoutine>(FRoutines, TComparer<TCodeMapRoutine>.Construct(
    function(const A, B: TCodeMapRoutine): Integer
    begin
      if A.StartRva < B.StartRva then
        Exit(-1);
      if A.StartRva > B.StartRva then
        Exit(1);
      Result := 0;
    end));
  var Count := 0;
  for var I := 0 to High(FRoutines) do begin
    if (Count > 0) and (FRoutines[I].StartRva = FRoutines[Count - 1].StartRva) then begin
      Inc(FDroppedRoutineCount);
      Continue;
    end;
    if I <> Count then
      FRoutines[Count] := FRoutines[I];
    Inc(Count);
  end;
  SetLength(FRoutines, Count);
end;

procedure TModuleCodeMap.LoadLines(const Provider: ILineRecordProvider;
  UnitIds: TDictionary<string, Integer>; const Resolver: TCodeMapPathResolver);
begin
  var Table := Provider.LineRecordTable(FLinesComplete);

  SetLength(FFiles, Length(Table.Files));
  for var I := 0 to High(Table.Files) do begin
    FFiles[I].Name         := Table.Files[I].Name;
    FFiles[I].RecordedPath := Table.Files[I].FullPath;
    if Assigned(Resolver) then
      FFiles[I].ResolvedPath := Resolver(Table.Files[I].Name, Table.Files[I].FullPath);
  end;

  // The provider's unit indexes, translated into this map's unit table.
  var UnitOfProviderUnit: TArray<Integer>;
  SetLength(UnitOfProviderUnit, Length(Table.Units));
  for var I := 0 to High(Table.Units) do
    UnitOfProviderUnit[I] := InternUnit(UnitIds, Table.Units[I]);

  SetLength(FLines, Length(Table.Records));
  var Count := 0;
  var InOrder := True;
  for var I := 0 to High(Table.Records) do begin
    var Rva: Cardinal;
    var FileIndex := Table.Records[I].FileIndex;
    if (FileIndex < 0) or (FileIndex >= Length(FFiles)) or
       not ToModuleRva(Table.Records[I].Rva, Rva) then begin
      Inc(FDroppedLineCount);
      Continue;
    end;
    if (Count > 0) and (Rva <= FLines[Count - 1].Rva) then
      InOrder := False;
    FLines[Count].Rva          := Rva;
    FLines[Count].CodeLength   := 0;
    FLines[Count].Line         := Table.Records[I].Line;
    FLines[Count].FileIndex    := FileIndex;
    FLines[Count].RoutineIndex := -1;
    FLines[Count].UnitIndex    := -1;
    var ProviderUnit := Table.Records[I].UnitIndex;
    if (ProviderUnit >= 0) and (ProviderUnit < Length(UnitOfProviderUnit)) then
      FLines[Count].UnitIndex := UnitOfProviderUnit[ProviderUnit];
    Inc(Count);
  end;
  SetLength(FLines, Count);
  if not InOrder then
    SortLinesByRva;
end;

procedure TModuleCodeMap.SortLinesByRva;
begin
  TArray.Sort<TCodeMapLine>(FLines, TComparer<TCodeMapLine>.Construct(
    function(const A, B: TCodeMapLine): Integer
    begin
      if A.Rva < B.Rva then
        Exit(-1);
      if A.Rva > B.Rva then
        Exit(1);
      Result := 0;
    end));
  var Count := 0;
  for var I := 0 to High(FLines) do begin
    if (Count > 0) and (FLines[I].Rva = FLines[Count - 1].Rva) then begin
      Inc(FDroppedLineCount);
      Continue;
    end;
    FLines[Count] := FLines[I];
    Inc(Count);
  end;
  SetLength(FLines, Count);
end;

function TModuleCodeMap.EffectiveEnd(RoutineIndex: Integer): Cardinal;
// Where a routine stops owning addresses: its end, or the next routine's start
// when the two ranges overlap. An address belongs to the routine with the
// nearest start at or below it, so nothing past the next start is this one's.
begin
  Result := FRoutines[RoutineIndex].EndRva;
  if (RoutineIndex < High(FRoutines)) and
     (FRoutines[RoutineIndex + 1].StartRva < Result) then
    Result := FRoutines[RoutineIndex + 1].StartRva;
end;

procedure TModuleCodeMap.LinkLinesToRoutines;
// One pass over both sorted tables: the routine of every record, the records
// of every routine, and each record's code length.
var
  Nearest: Integer;   // last routine starting at or below the current record

  function OwnerOf(Rva: Cardinal): Integer;
  begin
    if (Nearest < 0) or (Rva >= EffectiveEnd(Nearest)) then
      Exit(-1);
    Result := Nearest;
  end;

  // First address above Rva that belongs to something else: the next record,
  // or where the code this record is part of ends. 0 when nothing follows.
  function BoundAfter(LineIndex, Owner: Integer): UInt64;
  begin
    Result := 0;
    if LineIndex < High(FLines) then
      Result := FLines[LineIndex + 1].Rva;
    var CodeEnd: UInt64 := 0;
    if Owner >= 0 then
      CodeEnd := EffectiveEnd(Owner)
    else if Nearest < High(FRoutines) then
      CodeEnd := FRoutines[Nearest + 1].StartRva;
    if (CodeEnd > 0) and ((Result = 0) or (CodeEnd < Result)) then
      Result := CodeEnd;
  end;

begin
  Nearest := -1;
  FOutsideRoutineCount := 0;
  for var I := 0 to High(FLines) do begin
    var Rva := FLines[I].Rva;
    while (Nearest < High(FRoutines)) and (FRoutines[Nearest + 1].StartRva <= Rva) do
      Inc(Nearest);
    var Owner := OwnerOf(Rva);
    FLines[I].RoutineIndex := Owner;
    if Owner < 0 then
      Inc(FOutsideRoutineCount)
    else begin
      if FRoutines[Owner].FirstLine < 0 then
        FRoutines[Owner].FirstLine := I;
      Inc(FRoutines[Owner].LineCount);
    end;
    var Bound := BoundAfter(I, Owner);
    if Bound > Rva then
      FLines[I].CodeLength := Cardinal(Bound - Rva);
  end;
end;

procedure TModuleCodeMap.SpreadUnits;
// A provider may know the unit of its records and not of its routines (TD32 as
// read today), or the reverse. Each side fills the other where it is silent:
// a routine takes the unit of its first record, a record that of its routine.
begin
  for var I := 0 to High(FRoutines) do
    if (FRoutines[I].UnitIndex < 0) and (FRoutines[I].FirstLine >= 0) then
      FRoutines[I].UnitIndex := FLines[FRoutines[I].FirstLine].UnitIndex;
  for var I := 0 to High(FLines) do
    if (FLines[I].UnitIndex < 0) and (FLines[I].RoutineIndex >= 0) then
      FLines[I].UnitIndex := FRoutines[FLines[I].RoutineIndex].UnitIndex;
end;

procedure TModuleCodeMap.IndexByFileAndLine;
// Orders the record indexes by (file, line, RVA). The records are already in
// RVA order, so two STABLE counting passes -- by line, then by file -- give
// that order in linear time; a comparison sort of a large binary's 2.8 million
// records costs about a second.
var
  ByLine: TArray<Integer>;

  procedure OrderByLineWithASort;
  begin
    var Records := FLines;
    TArray.Sort<Integer>(ByLine, TComparer<Integer>.Construct(
      function(const A, B: Integer): Integer
      begin
        if Records[A].Line <> Records[B].Line then begin
          if Records[A].Line < Records[B].Line then
            Exit(-1);
          Exit(1);
        end;
        // Indexes are in RVA order: comparing them keeps the pass stable.
        if A < B then
          Exit(-1);
        if A > B then
          Exit(1);
        Result := 0;
      end));
  end;

  procedure OrderByLineCounting(MaxLine: Integer);
  begin
    var Starts: TArray<Integer>;
    SetLength(Starts, MaxLine + 2);
    for var I := 0 to High(FLines) do
      Inc(Starts[FLines[I].Line + 1]);
    for var L := 1 to High(Starts) do
      Inc(Starts[L], Starts[L - 1]);
    for var I := 0 to High(FLines) do begin
      var Line := FLines[I].Line;
      ByLine[Starts[Line]] := I;
      Inc(Starts[Line]);
    end;
  end;

begin
  SetLength(ByLine, Length(FLines));
  var MaxLine := 0;
  var Countable := True;
  for var I := 0 to High(FLines) do begin
    ByLine[I] := I;
    if FLines[I].Line < 0 then
      Countable := False
    else if FLines[I].Line > MaxLine then
      MaxLine := FLines[I].Line;
  end;
  if Countable and (MaxLine <= MAX_COUNTED_LINE) then
    OrderByLineCounting(MaxLine)
  else
    OrderByLineWithASort;

  // Second pass, by file. FFileFirst[F] ends up as the start of file F's run.
  SetLength(FFileFirst, Length(FFiles) + 1);
  for var I := 0 to High(FLines) do
    Inc(FFileFirst[FLines[I].FileIndex + 1]);
  for var F := 1 to High(FFileFirst) do
    Inc(FFileFirst[F], FFileFirst[F - 1]);
  var Next := Copy(FFileFirst);
  SetLength(FByFileLine, Length(FLines));
  for var I := 0 to High(ByLine) do begin
    var FileIndex := FLines[ByLine[I]].FileIndex;
    FByFileLine[Next[FileIndex]] := ByLine[I];
    Inc(Next[FileIndex]);
  end;
end;

function TModuleCodeMap.FindLine(Rva: Cardinal): Integer;
begin
  var Lo := 0;
  var Hi := High(FLines);
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if FLines[Mid].Rva = Rva then
      Exit(Mid);
    if FLines[Mid].Rva < Rva then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := -1;
end;

function TModuleCodeMap.FindLineCovering(Rva: Cardinal): Integer;
begin
  Result := -1;
  var Lo := 0;
  var Hi := High(FLines);
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if FLines[Mid].Rva <= Rva then begin
      Result := Mid;
      Lo     := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if Result < 0 then
    Exit;
  if UInt64(Rva) - FLines[Result].Rva >= FLines[Result].CodeLength then
    Result := -1;
end;

function TModuleCodeMap.FindRoutine(Rva: Cardinal): Integer;
begin
  Result := -1;
  var Lo := 0;
  var Hi := High(FRoutines);
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if FRoutines[Mid].StartRva <= Rva then begin
      Result := Mid;
      Lo     := Mid + 1;
    end else
      Hi := Mid - 1;
  end;
  if (Result >= 0) and (Rva >= FRoutines[Result].EndRva) then
    Result := -1;
end;

function TModuleCodeMap.FindFiles(const FileNameOrPath: string): TArray<Integer>;
begin
  Result := [];
  var Exact: TArray<Integer> := [];
  var BaseName := ExtractFileName(FileNameOrPath);
  var HasDirectory := BaseName <> FileNameOrPath;
  for var I := 0 to High(FFiles) do begin
    if not AnsiSameText(FFiles[I].Name, BaseName) then
      Continue;
    Result := Result + [I];
    if HasDirectory and (AnsiSameText(FFiles[I].RecordedPath, FileNameOrPath) or
                         AnsiSameText(FFiles[I].ResolvedPath, FileNameOrPath)) then
      Exact := Exact + [I];
  end;
  if Length(Exact) > 0 then
    Result := Exact;
end;

function TModuleCodeMap.LinesOfFile(FileIndex: Integer): TArray<Integer>;
begin
  if (FileIndex < 0) or (FileIndex >= Length(FFiles)) then
    Exit(nil);
  Result := Copy(FByFileLine, FFileFirst[FileIndex],
    FFileFirst[FileIndex + 1] - FFileFirst[FileIndex]);
end;

function TModuleCodeMap.LinesAt(FileIndex, Line: Integer): TArray<Integer>;
begin
  Result := nil;
  if (FileIndex < 0) or (FileIndex >= Length(FFiles)) then
    Exit;
  // First entry of the file's run whose line is >= Line.
  var Lo := FFileFirst[FileIndex];
  var Stop := FFileFirst[FileIndex + 1];
  var Hi := Stop;
  while Lo < Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if FLines[FByFileLine[Mid]].Line < Line then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  var Last := Lo;
  while (Last < Stop) and (FLines[FByFileLine[Last]].Line = Line) do
    Inc(Last);
  Result := Copy(FByFileLine, Lo, Last - Lo);
end;

function TModuleCodeMap.UnitName(UnitIndex: Integer): string;
begin
  if (UnitIndex < 0) or (UnitIndex >= Length(FUnits)) then
    Exit('');
  Result := FUnits[UnitIndex];
end;

function TModuleCodeMap.TableBytes: Int64;
begin
  Result := Int64(Length(FLines)) * SizeOf(TCodeMapLine) +
            Int64(Length(FRoutines)) * SizeOf(TCodeMapRoutine) +
            Int64(Length(FByFileLine)) * SizeOf(Integer) +
            Int64(Length(FFileFirst)) * SizeOf(Integer) +
            Int64(Length(FFiles)) * SizeOf(TCodeMapFile) +
            Int64(Length(FUnits)) * SizeOf(string);
end;

function TModuleCodeMap.NameBytes: Int64;
const
  // Header of a heap string (code page, element size, reference count,
  // length) plus its terminator, on a 64-bit build.
  STRING_OVERHEAD = 16 + SizeOf(Char);

  function StringBytes(const S: string): Int64;
  begin
    if S = '' then
      Exit(0);
    Result := Int64(Length(S)) * SizeOf(Char) + STRING_OVERHEAD;
  end;

begin
  Result := 0;
  for var I := 0 to High(FRoutines) do
    Inc(Result, StringBytes(FRoutines[I].Name));
  for var I := 0 to High(FFiles) do
    Inc(Result, StringBytes(FFiles[I].Name) + StringBytes(FFiles[I].RecordedPath) +
      StringBytes(FFiles[I].ResolvedPath));
  for var I := 0 to High(FUnits) do
    Inc(Result, StringBytes(FUnits[I]));
end;

end.
