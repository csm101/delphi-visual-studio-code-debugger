unit RoutineAnalysisTests;

// Tests for the routine analysis (DebuggerCore\RoutineAnalysis.pas,
// docs/PROFILER_COVERAGE_PLAN.md increment 4).
//
// Two fixtures, and they prove different things.
//
// TRoutineAnalysisTests is STATIC: every binary is read as a file. What the
// analysis claims is checked against what the bytes say, through a decode that
// shares nothing with the analysis but the decoder -- the instruction's TEXT,
// which the analysis never looks at, says whether it is a call, where a branch
// goes, whether an instruction is the `pop` an unwinder window ends on. No
// address is written by hand anywhere: routines are found through the
// `{BP:...}` markers of the sources, tables through the jumps that use them.
//
// TRoutineAnalysisDynamicTests is the strong one, and it is independent of the
// analysis' own decoding altogether: the sample is run under the engine and
// single-stepped one instruction at a time, and every address the PROCESSOR
// stopped at inside an analysed routine must be an instruction boundary the
// analysis found. A boundary the analysis invented does not show up there; a
// boundary it missed, or put in the middle of an instruction, does.
//
// Every static test runs on both bitnesses and COLLECTS its failures: both
// fixture executables carry the same name, so a first-failure abort would hide
// the other bitness and a message built from the file name could not say which
// one failed (docs/TRAPS.md, "Proving a fix").

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.Generics.Collections,
  DebugInfoTypes, TD32FileReader, CodeMap, Disassembler, ZydisApi, PeImageFile,
  RoutineAnalysis;

type
  // One fixture binary as a file: image, code map and analyzer. Owns all three.
  TAnalysedBinary = class
  private
    FKeepReader: IInterface;
  public
    Caption:  string;
    Is64:     Boolean;
    Image:    TPeImageFile;
    Map:      TModuleCodeMap;
    Analyzer: TRoutineAnalyzer;
    // RoutinesFrom: an optional provider of routine ranges to build the code map
    // with instead of TD32's own (a MAP, which names anonymous-method bodies).
    constructor Create(const ACaption, Path: string; Disabled: TRoutineAnalysisRules = [];
      const RoutinesFrom: IRoutineRangeProvider = nil);
    destructor Destroy; override;
    function Mode: TZydisMachineMode;
    // The instruction at an address of the FILE, decoded apart from the analysis.
    function Decode(Rva: Cardinal; out Detail: TZydisInstructionDetail; out Text: string): Boolean;
    function ReadU32(Rva: Cardinal): Cardinal;
    function ReadU64(Rva: Cardinal): UInt64;
    function ReadByte(Rva: Cardinal): Byte;
    // Module-relative address of a VA stored in the image.
    function RvaOf(VA: UInt64): Int64;
    function RoutineNamed(const Name: string): Integer;
  end;

  // A `{BP:NAME}` marker of a source file.
  TSourceMarker = record
    FileName: string;
    Name:     string;
    Line:     Integer;
  end;

  [TestFixture]
  TRoutineAnalysisTests = class
  private
    FProblems: TList<string>;
    procedure Check(Condition: Boolean; const Problem: string);
    procedure AssertNoProblems;
    function  OpenSample(const Bitness: string; Disabled: TRoutineAnalysisRules = []): TAnalysedBinary;
    function  MarkerRecords(Binary: TAnalysedBinary; const Marker: string): TArray<Integer>;
    function  RoutineOfMarker(Binary: TAnalysedBinary; const Marker: string): Integer;
    function  AnalyzeMarker(Binary: TAnalysedBinary; const Marker: string): TRoutineAnalysis;
    procedure CheckMarkersConfirmed(Binary: TAnalysedBinary; const Markers: TArray<TSourceMarker>;
      MinShare: Double);
    procedure CheckAgainstTheBytes(Binary: TAnalysedBinary; const Analysis: TRoutineAnalysis);
    procedure CheckEveryRange(Binary: TAnalysedBinary);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    // --- every fixture, both bitnesses ---
    [Test] procedure Markers_AreConfirmedRecords_InEveryFixture;
    [Test] procedure EveryRoutine_IsWhatTheBytesSay_Sample;
    [Test] procedure EveryRoutine_IsWhatTheBytesSay_TestTargetAndPackage;

    // --- the shapes of the sample ---
    [Test] procedure Sample_X86_DenseCase_TableDirectlyAfterTheJump;
    [Test] procedure Sample_X86_IndexedCase_ByteIndexTableBeforeTheAddressTable;
    [Test] procedure Sample_X64_CaseStatements_CompileToNoTableAtAll;
    [Test] procedure Sample_AsmTable_HandWrittenTableIsFoundAndItsLineIsNotCode;
    [Test] procedure Sample_X64_ExceptionBlocks_AreNamedByTheScopeAndClauseTables;
    [Test] procedure Sample_X86_ExceptionBlocks_AreFoundThroughTheirStubs;
    [Test] procedure Sample_Safecall_HandlerIsAFuncletOnX64AndAStubOnX86;
    [Test] procedure Sample_RoutineEndingInACall_ItsEpilogueIsInTheWindowOnX64Only;
    [Test] procedure Sample_OneLineLoop_FirstBlockStopsBeforeTheLoopBody;
    [Test] procedure Sample_FramelessLeaf_IsOneBlockEndingInItsRet;
    [Test] procedure Sample_NestedRoutines_AreRoutinesOfTheirOwn;
    [Test] procedure Sample_AnonymousMethod_X64FromPdata_X86OnlyWithAMap;

    // --- negative controls: the same binaries with one rule switched off ---
    [Test] procedure Without_TheX86FinallyExit_RoutinesGoIncomplete;
    [Test] procedure Without_JumpTables_TheCaseArmsAreNotConfirmed;
    [Test] procedure Without_X86HandlerStubs_TheHandlerBlocksAreNotConfirmed;
    [Test] procedure Without_X64ExceptionTables_TheHandlerBlocksAreNotConfirmed;
    [Test] procedure Without_NoReturnCalls_TheMainBlockRunsIntoData;

    // --- the three verdicts are three ---
    [Test] procedure StrayRecords_AreNotCodeOnlyWhenTheBytesSaySo;
    [Test] procedure Unavailable_WhenDllMissing_NothingIsConfirmedAndNothingIsRefused;
  end;

  [TestFixture]
  TRoutineAnalysisDynamicTests = class
  public
    [Setup] procedure ResetDisassemblerLoadLatch;
    [Test] procedure X64_EveryAddressTheProcessorStoppedAt_IsABoundaryTheAnalysisFound;
    [Test] procedure Win32_EveryAddressTheProcessorStoppedAt_IsABoundaryTheAnalysisFound;
  end;

implementation

uses
  System.Classes, System.IOUtils, System.StrUtils, Winapi.Windows,
  MapFileReader, PeSymbolSupport,
  DebugTarget, DebugSession, DebugSessionTypes;

const
  SAMPLE_SOURCE      = 'AnalysisSample.dpr';
  MAX_PROBLEMS_SHOWN = 25;

{ ------------------------------------------------------------- locations ---- }

function FixtureRoot: string;
begin
  // RunTests.exe lives in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\');
end;

function TargetDir: string;
begin
  Result := FixtureRoot + 'TestTarget\';
end;

function SamplePath(const Bitness, Extension: string): string;
begin
  Result := TargetDir + Bitness + '\Debug\AnalysisSample' + Extension;
end;

function ZydisDll: string;
begin
  Result := ExpandFileName(FixtureRoot + '..\ThirdParty\Zydis\bin\x64\Zydis.dll');
end;

function MarkersOf(const SourcePath: string): TArray<TSourceMarker>;
const
  OPENING = '{BP:';
begin
  Result := [];
  var Source := TStringList.Create;
  try
    Source.LoadFromFile(SourcePath);
    for var I := 0 to Source.Count - 1 do begin
      var Start := Source[I].IndexOf(OPENING);
      if Start < 0 then
        Continue;
      var Stop := Source[I].IndexOf('}', Start);
      if Stop < 0 then
        Continue;
      var Name := Source[I].Substring(Start + OPENING.Length, Stop - Start - OPENING.Length);
      // Header comments describe the convention as `{BP:<NAME>}` or `{BP:...}`.
      if (Name = '') or (Name.IndexOfAny(['<', '>', ' ', '.']) >= 0) then
        Continue;
      var Marker: TSourceMarker;
      Marker.FileName := ExtractFileName(SourcePath);
      Marker.Name     := Name;
      Marker.Line     := I + 1;
      Result := Result + [Marker];
    end;
  finally
    Source.Free;
  end;
end;

function SampleMarkers: TArray<TSourceMarker>;
begin
  Result := MarkersOf(TargetDir + SAMPLE_SOURCE);
  Assert.IsTrue(Length(Result) >= 30,
    Format('only %d markers found in %s: the scan is broken', [Length(Result), SAMPLE_SOURCE]));
end;

// The markers of every source of the TestTarget program and package.
function TestTargetMarkers: TArray<TSourceMarker>;
begin
  Result := [];
  for var Path in TDirectory.GetFiles(TargetDir, 'TestTarget*.pas') do
    Result := Result + MarkersOf(Path);
  Result := Result + MarkersOf(TargetDir + 'TestTarget.dpr');
  Assert.IsTrue(Length(Result) > 100,
    Format('only %d markers found in the TestTarget sources: the scan is broken', [Length(Result)]));
end;

// First word of an instruction's text, lower case: its mnemonic. A prefix that
// Zydis prints as a word of its own is skipped.
function MnemonicOf(const Text: string): string;
begin
  var Words := Text.ToLower.Split([' ']);
  for var Word in Words do
    if not MatchStr(Word, ['rep', 'repe', 'repne', 'lock', 'bnd', 'notrack', 'xacquire', 'xrelease']) then
      Exit(Word);
  Result := '';
end;

// The address a direct branch names, as Zydis prints it: `<mnemonic> 0x<hex>`.
function TextTarget(const Text: string; out VA: UInt64): Boolean;
begin
  VA := 0;
  var At := Text.IndexOf(' 0x');
  if (At < 0) or (Text.IndexOf(' ', At + 1) >= 0) then
    Exit(False);
  Result := TryStrToUInt64('$' + Text.Substring(At + 3), VA);
end;

{ TAnalysedBinary }

constructor TAnalysedBinary.Create(const ACaption, Path: string;
  Disabled: TRoutineAnalysisRules; const RoutinesFrom: IRoutineRangeProvider);
begin
  inherited Create;
  Caption := ACaption;
  if not TFile.Exists(Path) then
    Assert.Fail(Format('%s fixture not found at %s -- run build_and_run.bat', [ACaption, Path]));
  Image := TPeImageFile.Create(Path);
  Is64  := Image.Is64;
  var Reader := TTD32FileReader.Create;
  FKeepReader := Reader;
  Reader.LoadFromFile(Path);
  Assert.IsTrue(Reader.Loaded, ACaption + ': no TD32 debug information in ' + Path);
  var Routines: IRoutineRangeProvider := Reader;
  if RoutinesFrom <> nil then
    Routines := RoutinesFrom;
  Map := TModuleCodeMap.Build(ExtractFileName(Path), Reader, Routines, 0, Image.SizeOfImage);

  var Input := Default(TRoutineAnalysisInput);
  Input.Mode := dmmLegacy32;
  if Is64 then
    Input.Mode := dmmLong64;
  Input.Reader        := Image.Read;
  Input.ImageBase     := Image.ImageBase;
  Input.CodeMap       := Map;
  Input.ZydisDllPath  := ZydisDll;
  Input.DisabledRules := Disabled;
  Analyzer := TRoutineAnalyzer.Create(Input);
  Assert.IsTrue(Analyzer.Available, ACaption + ': ' + Analyzer.StatusText);
end;

destructor TAnalysedBinary.Destroy;
begin
  Analyzer.Free;
  Map.Free;
  FKeepReader := nil;
  Image.Free;
  inherited;
end;

function TAnalysedBinary.Mode: TZydisMachineMode;
begin
  if Is64 then
    Exit(zmmLong64);
  Result := zmmLegacy32;
end;

function TAnalysedBinary.Decode(Rva: Cardinal; out Detail: TZydisInstructionDetail;
  out Text: string): Boolean;
var
  Code: array[0..15] of Byte;
begin
  FillChar(Code, SizeOf(Code), 0);
  var Got := Image.Read(Image.ImageBase + Rva, @Code[0], 15);
  Result := (Got > 0) and ZydisDecodeDetail(Mode, Image.ImageBase + Rva, Code, Got, Detail, Text);
end;

function TAnalysedBinary.ReadU32(Rva: Cardinal): Cardinal;
begin
  Result := 0;
  Assert.AreEqual(4, Image.Read(Image.ImageBase + Rva, @Result, 4),
    Format('%s: cannot read 4 bytes at $%x', [Caption, Rva]));
end;

function TAnalysedBinary.ReadU64(Rva: Cardinal): UInt64;
begin
  Result := 0;
  Assert.AreEqual(8, Image.Read(Image.ImageBase + Rva, @Result, 8),
    Format('%s: cannot read 8 bytes at $%x', [Caption, Rva]));
end;

function TAnalysedBinary.ReadByte(Rva: Cardinal): Byte;
begin
  Result := 0;
  Assert.AreEqual(1, Image.Read(Image.ImageBase + Rva, @Result, 1),
    Format('%s: cannot read a byte at $%x', [Caption, Rva]));
end;

function TAnalysedBinary.RvaOf(VA: UInt64): Int64;
begin
  Result := Int64(VA) - Int64(Image.ImageBase);
end;

function TAnalysedBinary.RoutineNamed(const Name: string): Integer;
begin
  Result := -1;
  for var I := 0 to High(Map.Routines) do
    if SameText(Map.Routines[I].Name, Name) or Map.Routines[I].Name.EndsWith('.' + Name, True) then begin
      Assert.AreEqual(-1, Result, Format('%s: more than one routine named %s', [Caption, Name]));
      Result := I;
    end;
  Assert.IsTrue(Result >= 0, Format('%s: no routine named %s in the code map', [Caption, Name]));
end;

{ TRoutineAnalysisTests: plumbing }

procedure TRoutineAnalysisTests.Setup;
begin
  // docs/TRAPS.md: other tests leave the Zydis load latch pointed at a missing DLL.
  ZydisResetForTests;
  FProblems := TList<string>.Create;
end;

procedure TRoutineAnalysisTests.TearDown;
begin
  FreeAndNil(FProblems);
end;

procedure TRoutineAnalysisTests.Check(Condition: Boolean; const Problem: string);
begin
  if not Condition then
    FProblems.Add(Problem);
end;

procedure TRoutineAnalysisTests.AssertNoProblems;
begin
  if FProblems.Count = 0 then
    Exit;
  var Text := TStringBuilder.Create;
  try
    Text.AppendFormat('%d problem(s):', [FProblems.Count]);
    for var I := 0 to FProblems.Count - 1 do begin
      if I = MAX_PROBLEMS_SHOWN then begin
        Text.AppendLine.Append('  ...');
        Break;
      end;
      Text.AppendLine.Append('  ').Append(FProblems[I]);
    end;
    Assert.Fail(Text.ToString);
  finally
    Text.Free;
  end;
end;

function TRoutineAnalysisTests.OpenSample(const Bitness: string;
  Disabled: TRoutineAnalysisRules): TAnalysedBinary;
begin
  Result := TAnalysedBinary.Create('sample ' + Bitness, SamplePath(Bitness, '.exe'), Disabled);
end;

function TRoutineAnalysisTests.MarkerRecords(Binary: TAnalysedBinary;
  const Marker: string): TArray<Integer>;
begin
  Result := [];
  for var Item in SampleMarkers do begin
    if Item.Name <> Marker then
      Continue;
    for var FileIndex in Binary.Map.FindFiles(Item.FileName) do
      Result := Result + Binary.Map.LinesAt(FileIndex, Item.Line);
    Assert.IsTrue(Length(Result) > 0,
      Format('%s: marker %s (line %d) has no line record', [Binary.Caption, Marker, Item.Line]));
    Exit;
  end;
  Assert.Fail('no marker ' + Marker + ' in ' + SAMPLE_SOURCE);
end;

function TRoutineAnalysisTests.RoutineOfMarker(Binary: TAnalysedBinary; const Marker: string): Integer;
begin
  Result := Binary.Map.Lines[MarkerRecords(Binary, Marker)[0]].RoutineIndex;
  Assert.IsTrue(Result >= 0,
    Format('%s: marker %s is outside every routine of the code map', [Binary.Caption, Marker]));
end;

function TRoutineAnalysisTests.AnalyzeMarker(Binary: TAnalysedBinary;
  const Marker: string): TRoutineAnalysis;
begin
  Result := Binary.Analyzer.Analyze(RoutineOfMarker(Binary, Marker));
end;

{ TRoutineAnalysisTests: every fixture }

procedure TRoutineAnalysisTests.CheckMarkersConfirmed(Binary: TAnalysedBinary;
  const Markers: TArray<TSourceMarker>; MinShare: Double);
// A marker sits on a statement the suite stops at: its records must be
// confirmed boundaries. The one legitimate exception is stated, not skipped:
// the body of an anonymous method lies outside every routine range, and on x86
// nothing in TD32 proves its entry, so there its records are UNCONFIRMED --
// never "not code".
begin
  var WithCode := 0;
  var Records := 0;
  for var Marker in Markers do begin
    var Found: TArray<Integer> := [];
    for var FileIndex in Binary.Map.FindFiles(Marker.FileName) do
      Found := Found + Binary.Map.LinesAt(FileIndex, Marker.Line);
    if Length(Found) = 0 then
      Continue;   // no code for the line in this binary (the linker dropped the routine)
    Inc(WithCode);
    for var LineIndex in Found do begin
      Inc(Records);
      var Line := Binary.Analyzer.AnalyzeLine(LineIndex);
      var Where := Format('%s: marker %s (%s:%d) record $%x', [Binary.Caption, Marker.Name,
        Marker.FileName, Marker.Line, Line.Rva]);
      var InRoutine := Binary.Map.Lines[LineIndex].RoutineIndex >= 0;
      if InRoutine or Binary.Is64 then
        Check(Line.Verdict = lvConfirmed, Format('%s is not confirmed: %s', [Where,
          LineVerdictReasonText(Line.Reason)]))
      else
        Check((Line.Verdict = lvUnconfirmed) and (Line.Reason = lvrOutsideEveryRoutine),
          Format('%s lies outside every routine on x86 and must be unconfirmed, got: %s', [Where,
            LineVerdictReasonText(Line.Reason)]));
      if Line.Verdict = lvConfirmed then
        Check(Line.BlockEndRva > Line.Rva, Where + ' is confirmed and has an empty first block');
    end;
  end;
  Check(WithCode >= MinShare * Length(Markers),
    Format('%s: only %d of %d markers have a line record: the test checked too little',
      [Binary.Caption, WithCode, Length(Markers)]));
  Check(Records >= WithCode, Binary.Caption + ': fewer records than marker lines');
end;

procedure TRoutineAnalysisTests.Markers_AreConfirmedRecords_InEveryFixture;

  procedure Run(const Caption, RelativePath: string; const Markers: TArray<TSourceMarker>;
    MinShare: Double);
  begin
    var Binary := TAnalysedBinary.Create(Caption, FixtureRoot + RelativePath);
    try
      CheckMarkersConfirmed(Binary, Markers, MinShare);
    finally
      Binary.Free;
    end;
  end;

begin
  // Every marker of the sample has code on both bitnesses.
  Run('sample x64', 'TestTarget\Win64\Debug\AnalysisSample.exe', SampleMarkers, 1.0);
  Run('sample x86', 'TestTarget\Win32\Debug\AnalysisSample.exe', SampleMarkers, 1.0);
  // Not every TestTarget marker has code everywhere: the executable's linker
  // drops routines only the package calls, and the reverse.
  var Markers := TestTargetMarkers;
  Run('exe x64', 'TestTarget\Win64\Debug\TestTarget.exe', Markers, 0.5);
  Run('exe x86', 'TestTarget\Win32\Debug\TestTarget.exe', Markers, 0.5);
  Run('bpl x64', 'TestHost\Win64\Debug\TestSubject.bpl', Markers, 0.5);
  Run('bpl x86', 'TestHost\Win32\Debug\TestSubject.bpl', Markers, 0.5);
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.CheckAgainstTheBytes(Binary: TAnalysedBinary;
  const Analysis: TRoutineAnalysis);
// Everything the analysis claims about one range, against an independent decode
// of the same bytes. The mnemonic and the branch target come from Zydis' TEXT,
// which the analysis never reads.
var
  Where: string;
  Detail: TZydisInstructionDetail;
  Text: string;
  ExpectWindow: TArray<Boolean>;

  function InRange(Rva: Int64): Boolean;
  begin
    Result := (Rva >= Analysis.StartRva) and (Rva < Analysis.EndRva);
  end;

  function FindExit(Rva: Cardinal): Integer;
  begin
    for var I := 0 to High(Analysis.Exits) do
      if Analysis.Exits[I].Rva = Rva then
        Exit(I);
    Result := -1;
  end;

  function FindCall(Rva: Cardinal): Integer;
  begin
    for var I := 0 to High(Analysis.CallSites) do
      if Analysis.CallSites[I].CallRva = Rva then
        Exit(I);
    Result := -1;
  end;

  // The window of a return address as the plan defines it, read off the TEXT
  // of the instructions: an optional `add rsp` / `lea rsp`, any number of
  // `pop r64`, and the one instruction after them.
  function WindowEndByText(ReturnRva: Cardinal): Cardinal;
  var
    At: Cardinal;
    D: TZydisInstructionDetail;
    T: string;

    function Next: Boolean;
    begin
      Result := Analysis.IsBoundary(At) and Binary.Decode(At, D, T);
    end;

    procedure Take;
    begin
      ExpectWindow[At - Analysis.StartRva] := True;
      Inc(At, D.Length);
    end;

  begin
    At := ReturnRva;
    if not Next then
      Exit(At);
    if T.StartsWith('add rsp,') or T.StartsWith('lea rsp,') then begin
      Take;
      if not Next then
        Exit(At);
    end;
    while T.StartsWith('pop ') and (D.Opcode >= $58) and (D.Opcode <= $5F) and (D.Length <= 2) do begin
      Take;
      if not Next then
        Exit(At);
    end;
    Take;
    Result := At;
  end;

  procedure CheckInstruction(Rva: Cardinal; Kind: TRoutineInsnKind);
  begin
    var Mnemonic := MnemonicOf(Text);
    var Target: UInt64;
    var Direct := TextTarget(Text, Target);
    var Expected: set of TRoutineInsnKind := [rikOther];
    if Mnemonic = 'call' then begin
      Expected := [rikCallIndirect];
      if Direct then
        Expected := [rikCall];
    end
    else if Mnemonic = 'jmp' then begin
      Expected := [rikJumpIndirect, rikJumpTable, rikJumpSlot, rikJumpFinally, rikJumpFar];
      if Direct then
        Expected := [rikJump];
    end
    else if Mnemonic.StartsWith('j') or Mnemonic.StartsWith('loop') then
      Expected := [rikJumpConditional]
    else if MatchStr(Mnemonic, ['ret', 'retf', 'iret', 'iretd', 'iretq']) then
      Expected := [rikReturn]
    else if Mnemonic = 'int3' then
      Expected := [rikInt3]
    else if MatchStr(Mnemonic, ['int', 'into', 'int1', 'hlt', 'ud2']) then
      Expected := [rikTrap];
    Check(Kind in Expected, Format('%s: $%x `%s` is classified as kind %d', [Where, Rva, Text, Ord(Kind)]));

    var After := Rva + Detail.Length;
    var ExitIndex := FindExit(Rva);
    case Kind of
      rikCall, rikCallIndirect: begin
        var CallIndex := FindCall(Rva);
        Check(CallIndex >= 0, Format('%s: the call at $%x is not in CallSites', [Where, Rva]));
        if CallIndex < 0 then
          Exit;
        var Call := Analysis.CallSites[CallIndex];
        Check(Call.ReturnRva = After, Format('%s: call at $%x returns to $%x, not $%x', [Where, Rva, After, Call.ReturnRva]));
        Check(Call.Indirect = (Kind = rikCallIndirect), Format('%s: call at $%x: Indirect is wrong', [Where, Rva]));
        if Direct then
          Check(Call.TargetRva = Binary.RvaOf(Target), Format('%s: call at $%x goes to $%x, the analysis says $%x',
            [Where, Rva, Binary.RvaOf(Target), Call.TargetRva]))
        else
          Check(Call.TargetRva = -1, Format('%s: indirect call at $%x has a target', [Where, Rva]));
        if InRange(After) then
          Check(Analysis.FlagsAt(After) and rbfReturnAddr <> 0,
            Format('%s: $%x follows a call and is not flagged a return address', [Where, After]));
        if Direct and InRange(Binary.RvaOf(Target)) then
          Check(Analysis.FlagsAt(Cardinal(Binary.RvaOf(Target))) and rbfTarget <> 0,
            Format('%s: in-routine call target $%x is not flagged a target', [Where, Binary.RvaOf(Target)]));
        // The window of the return address.
        if Binary.Is64 and InRange(After) then
          Check(Call.WindowEndRva = WindowEndByText(After),
            Format('%s: window of return address $%x ends at $%x, the instructions say $%x',
              [Where, After, Call.WindowEndRva, WindowEndByText(After)]))
        else
          Check(Call.WindowEndRva = Call.ReturnRva,
            Format('%s: return address $%x has a window where there is none', [Where, After]));
      end;
      rikJump, rikJumpConditional: begin
        Check(Direct, Format('%s: $%x `%s` has no readable target', [Where, Rva, Text]));
        var TargetRva := Binary.RvaOf(Target);
        if InRange(TargetRva) then begin
          Check(Analysis.FlagsAt(Cardinal(TargetRva)) and rbfTarget <> 0,
            Format('%s: branch target $%x (from $%x) is not flagged a target', [Where, TargetRva, Rva]));
          if Analysis.Complete then
            Check(Analysis.IsBoundary(Cardinal(TargetRva)),
              Format('%s: branch target $%x (from $%x) is not a boundary', [Where, TargetRva, Rva]));
          Check(ExitIndex < 0, Format('%s: the jump at $%x stays inside and is listed as an exit', [Where, Rva]));
        end
        else begin
          Check(ExitIndex >= 0, Format('%s: the jump at $%x leaves the routine and is not an exit', [Where, Rva]));
          if ExitIndex >= 0 then
            Check((Analysis.Exits[ExitIndex].Kind = rekJump) = (Kind = rikJump),
              Format('%s: exit at $%x has the wrong kind', [Where, Rva]));
        end;
      end;
      rikReturn: begin
        Check(ExitIndex >= 0, Format('%s: the ret at $%x is not an exit', [Where, Rva]));
        if ExitIndex >= 0 then
          Check(Analysis.Exits[ExitIndex].Kind = rekReturn, Format('%s: exit at $%x is not a ret', [Where, Rva]));
      end;
      rikJumpSlot, rikJumpIndirect, rikJumpFinally: begin
        Check(ExitIndex >= 0, Format('%s: the indirect jump at $%x is not in Exits', [Where, Rva]));
        if ExitIndex >= 0 then
          Check((Analysis.Exits[ExitIndex].Kind = rekJumpSlot) = (Kind = rikJumpSlot),
            Format('%s: exit at $%x has the wrong kind', [Where, Rva]));
      end;
      rikJumpTable: begin
        Check(ExitIndex < 0, Format('%s: the table jump at $%x is listed as an exit', [Where, Rva]));
        var Listed := False;
        for var Table in Analysis.JumpTables do
          if Table.JumpRva = Rva then
            Listed := True;
        Check(Listed, Format('%s: the table jump at $%x has no table', [Where, Rva]));
      end;
    end;
  end;

  procedure CheckLine(Index: Integer);
  begin
    var Line := Analysis.Lines[Index];
    var Flag := Analysis.FlagsAt(Line.Rva);
    var Tag := Format('%s: record $%x', [Where, Line.Rva]);
    Check(Flag and rbfLine <> 0, Tag + ' is not flagged a line start');
    Check((Line.Verdict = lvConfirmed) = (Flag and rbfBoundary <> 0), Tag + ': verdict and boundary flag disagree');
    Check(Line.Verdict = VerdictOfReason(Line.Reason), Tag + ': the reason belongs to another verdict');
    case Line.Reason of
      lvrInsideInstruction: Check(Flag and rbfInterior <> 0, Tag + ' is said to be inside an instruction');
      lvrInJumpTable:       Check(Flag and rbfJumpTable <> 0, Tag + ' is said to be in a jump table');
      lvrInClauseTable:     Check(Flag and rbfClauseTable <> 0, Tag + ' is said to be in a clause table');
      lvrZeroByte:          Check(Binary.ReadByte(Line.Rva) = 0, Tag + ' is said to hold a zero byte');
    end;
    if Line.Verdict <> lvConfirmed then begin
      Check(Line.BlockEnd = lbeNone, Tag + ' is not confirmed and has a block');
      Exit;
    end;

    // The first straight-line block: whole proven instructions, nothing a
    // branch can reach after the first, only the last one may transfer
    // control, and no instruction of it starts in the next line.
    var NextRva := Analysis.EndRva;
    if Index < High(Analysis.Lines) then
      NextRva := Analysis.Lines[Index + 1].Rva;
    var At := Line.Rva;
    var LastKind := rikOther;
    var Count := 0;
    while At < Line.BlockEndRva do begin
      if not Analysis.IsBoundary(At) then begin
        Check(False, Format('%s: its block holds $%x, which is not a boundary', [Tag, At]));
        Exit;
      end;
      if At > Line.Rva then
        Check(Analysis.FlagsAt(At) and rbfBarrier = 0,
          Format('%s: its block runs past $%x, which a branch can reach', [Tag, At]));
      Check(At < NextRva, Format('%s: its block holds $%x, in the next line', [Tag, At]));
      Check(LastKind = rikOther, Format('%s: its block continues at $%x after a control transfer', [Tag, At]));
      LastKind := Analysis.KindAt(At);
      Inc(At, Analysis.InstructionLength(At));
      Inc(Count);
    end;
    Check(At = Line.BlockEndRva, Tag + ': its block does not end on an instruction boundary');
    case Line.BlockEnd of
      lbeCall:         Check(LastKind = rikCall, Tag + ': block said to end in a direct call');
      lbeCallIndirect: Check(LastKind = rikCallIndirect, Tag + ': block said to end in an indirect call');
      lbeReturn:       Check(LastKind = rikReturn, Tag + ': block said to end in a ret');
      lbeTrap:         Check(LastKind in [rikInt3, rikTrap], Tag + ': block said to end in a trap');
      lbeBranch:       Check(LastKind in [rikJump, rikJumpConditional, rikJumpIndirect, rikJumpTable,
                         rikJumpSlot, rikJumpFar, rikJumpFinally], Tag + ': block said to end in a jump');
      lbeTarget:       Check((LastKind = rikOther) and (Analysis.FlagsAt(Line.BlockEndRva) and rbfBarrier <> 0),
                         Tag + ': block said to end before a branch target');
      lbeNextLine:     Check((LastKind = rikOther) and (Line.BlockEndRva >= NextRva),
                         Tag + ': block said to end at the next line');
      lbeUnproven:     Check((LastKind = rikOther) and not Analysis.IsBoundary(Line.BlockEndRva),
                         Tag + ': block said to end before unproven bytes');
      lbeRoutineEnd:   Check((LastKind = rikOther) and (Line.BlockEndRva = Analysis.EndRva),
                         Tag + ': block said to end at the routine end');
    else
      Check(False, Tag + ' is confirmed and has no block end');
    end;
    Check(Count > 0, Tag + ': empty block');
  end;

  procedure CheckTables;
  begin
    for var Table in Analysis.JumpTables do begin
      var Tag := Format('%s: jump table at $%x', [Where, Table.TableRva]);
      Check(Analysis.KindAt(Table.JumpRva) = rikJumpTable, Tag + ': its jump is not a table jump');
      var EntrySize: Cardinal := 4;
      if Table.Kind = rtkAbsolute64 then
        EntrySize := 8;
      for var I := 0 to Table.EntryCount - 1 do begin
        var EntryRva := Table.TableRva + Cardinal(I) * EntrySize;
        for var B := 0 to Integer(EntrySize) - 1 do
          Check(Analysis.FlagsAt(EntryRva + Cardinal(B)) and (rbfJumpTable or rbfBoundary or rbfInterior) = rbfJumpTable,
            Format('%s: byte $%x is not flagged table only', [Tag, EntryRva + Cardinal(B)]));
        if Table.Kind = rtkRelative32 then
          Continue;   // the base is the analysis' own finding; nothing independent to compare
        var Target: Int64;
        if Table.Kind = rtkAbsolute64 then
          Target := Binary.RvaOf(Binary.ReadU64(EntryRva))
        else
          Target := Binary.RvaOf(Binary.ReadU32(EntryRva));
        Check(InRange(Target), Format('%s: entry %d points outside the routine', [Tag, I]));
        if not InRange(Target) then
          Continue;
        var Flag := Analysis.FlagsAt(Cardinal(Target));
        Check(Flag and (rbfTarget or rbfTableEntry) = rbfTarget or rbfTableEntry,
          Format('%s: entry %d -> $%x is not flagged a table entry', [Tag, I, Target]));
        if Analysis.Complete then
          Check(Flag and rbfBoundary <> 0, Format('%s: entry %d -> $%x is not a boundary', [Tag, I, Target]));
      end;
      for var I := 0 to Integer(Table.IndexTableSize) - 1 do begin
        var IndexRva := Table.IndexTableRva + Cardinal(I);
        Check(Analysis.FlagsAt(IndexRva) and rbfJumpTable <> 0,
          Format('%s: index byte $%x is not flagged a table', [Tag, IndexRva]));
        Check(Binary.ReadByte(IndexRva) < Table.EntryCount,
          Format('%s: index byte $%x selects an entry the table does not have', [Tag, IndexRva]));
      end;
    end;
    for var Clause in Analysis.ClauseTables do begin
      var Tag := Format('%s: clause table at $%x', [Where, Clause.Rva]);
      Check(Integer(Binary.ReadU32(Clause.Rva)) = Clause.Count, Tag + ': the count is not what the bytes hold');
      for var B := 0 to 4 + Clause.Count * 8 - 1 do
        Check(Analysis.FlagsAt(Clause.Rva + Cardinal(B)) and (rbfClauseTable or rbfBoundary or rbfInterior) = rbfClauseTable,
          Format('%s: byte +%d is not flagged clause table only', [Tag, B]));
    end;
    for var Handler in Analysis.HandlerEntries do begin
      var Flag := Analysis.FlagsAt(Handler.Rva);
      var Tag := Format('%s: handler entry $%x', [Where, Handler.Rva]);
      Check(Flag and (rbfHandlerEntry or rbfTarget) = rbfHandlerEntry or rbfTarget, Tag + ' is not flagged');
      if Analysis.Complete then
        Check(Flag and rbfBoundary <> 0, Tag + ' is not a boundary');
      Check((Handler.Kind = rhkStub) = (Flag and rbfStub <> 0), Tag + ': stub flag and kind disagree');
      if Handler.Kind = rhkStub then
        Check(Binary.ReadByte(Handler.Rva) = $E9, Tag + ': a stub that is not a jmp');
    end;
  end;

begin
  Where := '<.pdata function>';
  if Analysis.RoutineIndex >= 0 then
    Where := Binary.Map.Routines[Analysis.RoutineIndex].Name;
  Where := Format('%s: %s [%x..%x)', [Binary.Caption, Where, Analysis.StartRva, Analysis.EndRva]);
  var Len := Length(Analysis.Flags);
  Check(Len = Int64(Analysis.EndRva) - Analysis.StartRva, Where + ': Flags does not cover the range');
  if Len <> Int64(Analysis.EndRva) - Analysis.StartRva then
    Exit;
  SetLength(ExpectWindow, Len);

  // Instructions: no two overlap, each is as long as a second decode says, and
  // each is the kind of instruction its text says.
  var Calls := 0;
  var Instructions := 0;
  var Ofs := 0;
  while Ofs < Len do begin
    var Flag := Analysis.Flags[Ofs];
    var Rva := Analysis.StartRva + Cardinal(Ofs);
    if Flag and rbfBoundary = 0 then begin
      Check(Flag and rbfInterior = 0, Format('%s: interior byte $%x belongs to no instruction', [Where, Rva]));
      Inc(Ofs);
      Continue;
    end;
    Inc(Instructions);
    Check(Flag and (rbfInterior or rbfData) = 0, Format('%s: boundary $%x is also interior or table', [Where, Rva]));
    var FlagLen := Analysis.InstructionLength(Rva);
    if not Binary.Decode(Rva, Detail, Text) then begin
      Check(False, Format('%s: boundary $%x does not decode a second time', [Where, Rva]));
      Inc(Ofs, FlagLen);
      Continue;
    end;
    Check(Detail.Length = FlagLen, Format('%s: $%x `%s` is %d bytes by its flags, %d decoded again',
      [Where, Rva, Text, FlagLen, Detail.Length]));
    for var K := 1 to FlagLen - 1 do
      Check(Analysis.Flags[Ofs + K] and (rbfInterior or rbfBoundary or rbfData) = rbfInterior,
        Format('%s: byte +%d of the instruction at $%x is not interior only', [Where, K, Rva]));
    var Kind := Analysis.KindAt(Rva);
    if Kind in [rikCall, rikCallIndirect] then
      Inc(Calls);
    CheckInstruction(Rva, Kind);
    Inc(Ofs, FlagLen);
  end;
  Check(Instructions = Analysis.InstructionCount, Where + ': InstructionCount is not the number of boundaries');
  Check(Calls = Length(Analysis.CallSites), Where + ': CallSites lists calls the flags do not have');
  for var I := 1 to High(Analysis.CallSites) do
    Check(Analysis.CallSites[I].CallRva > Analysis.CallSites[I - 1].CallRva, Where + ': CallSites is not ascending');
  for var I := 1 to High(Analysis.Exits) do
    Check(Analysis.Exits[I].Rva > Analysis.Exits[I - 1].Rva, Where + ': Exits is not ascending');
  for var ExitItem in Analysis.Exits do
    Check(Analysis.IsBoundary(ExitItem.Rva), Format('%s: exit $%x is not a boundary', [Where, ExitItem.Rva]));

  // Windows: exactly the instructions the text-derived windows hold.
  for var I := 0 to Len - 1 do begin
    var Flagged := Analysis.Flags[I] and rbfWindow <> 0;
    if Binary.Is64 then
      Check(Flagged = ExpectWindow[I], Format('%s: window flag of $%x is %s, the instructions say %s',
        [Where, Analysis.StartRva + Cardinal(I), BoolToStr(Flagged, True), BoolToStr(ExpectWindow[I], True)]))
    else
      Check(not Flagged, Format('%s: $%x is flagged an unwinder window on x86', [Where, Analysis.StartRva + Cardinal(I)]));
  end;

  for var I := 0 to High(Analysis.Lines) do
    CheckLine(I);
  CheckTables;
  Check(Analysis.Complete = (Analysis.Incomplete = []), Where + ': Complete and Incomplete disagree');
end;

procedure TRoutineAnalysisTests.CheckEveryRange(Binary: TAnalysedBinary);
begin
  var Ranges := 0;
  var Confirmed := 0;
  for var I := 0 to High(Binary.Map.Routines) do begin
    if Binary.Map.Routines[I].LineCount = 0 then
      Continue;
    var Analysis := Binary.Analyzer.Analyze(I);
    CheckAgainstTheBytes(Binary, Analysis);
    Inc(Ranges);
    for var Line in Analysis.Lines do
      if Line.Verdict = lvConfirmed then
        Inc(Confirmed);
  end;
  for var I := 0 to High(Binary.Analyzer.UnmappedFunctions) do begin
    var Analysis := Binary.Analyzer.AnalyzeUnmapped(I);
    Check(Analysis.RoutineIndex = -1, Binary.Caption + ': an unmapped function with a routine index');
    CheckAgainstTheBytes(Binary, Analysis);
    Inc(Ranges);
  end;
  Check(Binary.Is64 or (Length(Binary.Analyzer.UnmappedFunctions) = 0),
    Binary.Caption + ': unmapped functions on x86, where there is no .pdata');
  Check(Ranges > 10, Format('%s: only %d ranges analysed', [Binary.Caption, Ranges]));
  Check(Confirmed > 50, Format('%s: only %d records confirmed', [Binary.Caption, Confirmed]));
end;

procedure TRoutineAnalysisTests.EveryRoutine_IsWhatTheBytesSay_Sample;
begin
  for var Bitness in ['Win64', 'Win32'] do begin
    var Binary := OpenSample(Bitness);
    try
      CheckEveryRange(Binary);
    finally
      Binary.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.EveryRoutine_IsWhatTheBytesSay_TestTargetAndPackage;

  procedure Run(const Caption, RelativePath: string);
  begin
    var Binary := TAnalysedBinary.Create(Caption, FixtureRoot + RelativePath);
    try
      CheckEveryRange(Binary);
    finally
      Binary.Free;
    end;
  end;

begin
  Run('exe x64', 'TestTarget\Win64\Debug\TestTarget.exe');
  Run('exe x86', 'TestTarget\Win32\Debug\TestTarget.exe');
  Run('bpl x64', 'TestHost\Win64\Debug\TestSubject.bpl');
  Run('bpl x86', 'TestHost\Win32\Debug\TestSubject.bpl');
  AssertNoProblems;
end;

{ TRoutineAnalysisTests: the shapes of the sample }

procedure TRoutineAnalysisTests.Sample_X86_DenseCase_TableDirectlyAfterTheJump;
begin
  var Binary := OpenSample('Win32');
  try
    var Analysis := AnalyzeMarker(Binary, 'AN_DENSE_CASE');
    Assert.IsTrue(Analysis.Complete, 'DenseCase must be analysed completely');
    Assert.AreEqual<Integer>(1, Length(Analysis.JumpTables), 'DenseCase has one jump table');
    var Table := Analysis.JumpTables[0];
    Assert.IsTrue(Table.Kind = rtkAbsolute32, 'the table holds 32-bit addresses');
    Assert.IsTrue(Table.DirectlyAfterJump, 'dcc32 puts the table right after the jmp');
    Assert.AreEqual<Cardinal>(0, Table.IndexTableSize, 'a dense case needs no byte index');
    // Eight consecutive values in the source, eight entries in the table.
    Assert.AreEqual<Integer>(8, Table.EntryCount, 'one entry per case value 0..7');
    Assert.AreEqual<Cardinal>(Table.JumpRva + Cardinal(Analysis.InstructionLength(Table.JumpRva)),
      Table.TableRva, 'the table starts where the jmp ends');

    // The arm of value N is where entry N points: read the table as the
    // processor does and land on the arm's line record.
    for var Pair in [0, 6] do begin
      var Marker := 'AN_DENSE_' + IntToStr(Pair);
      var Target := Binary.RvaOf(Binary.ReadU32(Table.TableRva + Cardinal(Pair) * 4));
      var Records := MarkerRecords(Binary, Marker);
      Assert.AreEqual<Int64>(Binary.Map.Lines[Records[0]].Rva, Target,
        Format('entry %d of the table must point at the line of marker %s', [Pair, Marker]));
      Assert.IsTrue(Analysis.FlagsAt(Cardinal(Target)) and (rbfBoundary or rbfTableEntry) =
        rbfBoundary or rbfTableEntry, Marker + ': the arm is a boundary reached through the table');
    end;
    // The `else` arm is reached by the range check in front of the jmp, not
    // through the table.
    var ElseRva := Binary.Map.Lines[MarkerRecords(Binary, 'AN_DENSE_ELSE')[0]].Rva;
    Assert.IsTrue(Analysis.IsBoundary(ElseRva), 'the else arm is a boundary');
    Assert.IsTrue(Analysis.FlagsAt(ElseRva) and rbfTableEntry = 0, 'the else arm is not a table entry');
    Assert.IsTrue(Analysis.FlagsAt(ElseRva) and rbfTarget <> 0, 'the else arm is a branch target');
  finally
    Binary.Free;
  end;
end;

procedure TRoutineAnalysisTests.Sample_X86_IndexedCase_ByteIndexTableBeforeTheAddressTable;
begin
  var Binary := OpenSample('Win32');
  try
    var Analysis := AnalyzeMarker(Binary, 'AN_INDEXED_CASE');
    Assert.IsTrue(Analysis.Complete, 'IndexedCase must be analysed completely');
    Assert.AreEqual<Integer>(1, Length(Analysis.JumpTables), 'IndexedCase has one jump table');
    var Table := Analysis.JumpTables[0];
    Assert.IsFalse(Table.DirectlyAfterJump, 'the address table is behind the byte index');
    // Twenty-four consecutive values in the source: one index byte each.
    Assert.AreEqual<Cardinal>(24, Table.IndexTableSize, 'one index byte per case value 0..23');
    Assert.AreEqual<Cardinal>(Table.JumpRva + Cardinal(Analysis.InstructionLength(Table.JumpRva)),
      Table.IndexTableRva, 'the byte index starts where the jmp ends');
    Assert.AreEqual<Cardinal>(Table.IndexTableRva + Table.IndexTableSize, Table.TableRva,
      'the address table follows the byte index');

    // Value -> index byte -> table entry -> the arm's line record: the lookup
    // the compiled code performs, done on the file's bytes.
    var Expected: TArray<TPair<Integer, string>> := [
      TPair<Integer, string>.Create(4, 'AN_INDEXED_EVEN'),
      TPair<Integer, string>.Create(7, 'AN_INDEXED_ODD'),
      TPair<Integer, string>.Create(22, 'AN_INDEXED_TAIL')];
    for var Pair in Expected do begin
      var Index := Binary.ReadByte(Table.IndexTableRva + Cardinal(Pair.Key));
      Assert.IsTrue(Index < Table.EntryCount, Format('index byte of value %d is beyond the table', [Pair.Key]));
      var Target := Binary.RvaOf(Binary.ReadU32(Table.TableRva + Cardinal(Index) * 4));
      Assert.AreEqual<Int64>(Binary.Map.Lines[MarkerRecords(Binary, Pair.Value)[0]].Rva, Target,
        Format('value %d must reach the line of marker %s', [Pair.Key, Pair.Value]));
      Assert.IsTrue(Analysis.IsBoundary(Cardinal(Target)), Pair.Value + ': the arm is a boundary');
    end;
    // No line record may be confirmed inside either table.
    for var Line in Analysis.Lines do
      if (Line.Rva >= Table.IndexTableRva) and (Line.Rva < Table.TableRva + Cardinal(Table.EntryCount) * 4) then
        Assert.IsTrue(Line.Reason = lvrInJumpTable, Format('record $%x is inside the tables', [Line.Rva]));
  finally
    Binary.Free;
  end;
end;

procedure TRoutineAnalysisTests.Sample_X64_CaseStatements_CompileToNoTableAtAll;
// dcc64 emits compare chains for the very sources dcc32 turns into tables.
begin
  var Binary := OpenSample('Win64');
  try
    for var Marker in ['AN_DENSE_CASE', 'AN_INDEXED_CASE'] do begin
      var Analysis := AnalyzeMarker(Binary, Marker);
      Assert.IsTrue(Analysis.Complete, Marker + ': must be analysed completely');
      Assert.AreEqual<Integer>(0, Length(Analysis.JumpTables), Marker + ': dcc64 emits no jump table');
      for var Flag in Analysis.Flags do
        if Flag and rbfBoundary <> 0 then
          Assert.IsFalse(TRoutineInsnKind(Flag shr rbfKindShift) in [rikJumpTable, rikJumpIndirect],
            Marker + ': an indirect jump in a compiled case statement');
    end;
  finally
    Binary.Free;
  end;
end;

procedure TRoutineAnalysisTests.Sample_AsmTable_HandWrittenTableIsFoundAndItsLineIsNotCode;
begin
  for var Bitness in ['Win64', 'Win32'] do begin
    var Binary := OpenSample(Bitness);
    try
      var Analysis := Binary.Analyzer.Analyze(Binary.RoutineNamed('AsmTable'));
      var Tag := Binary.Caption + ': AsmTable';
      Check(Analysis.Complete, Tag + ' is not analysed completely');
      Check(Length(Analysis.JumpTables) = 1, Format('%s has %d jump tables, not 1', [Tag, Length(Analysis.JumpTables)]));
      if Length(Analysis.JumpTables) <> 1 then
        Continue;
      var Table := Analysis.JumpTables[0];
      Check(Table.EntryCount = 4, Format('%s: %d entries, the source has 4', [Tag, Table.EntryCount]));
      Check(not Table.DirectlyAfterJump, Tag + ': the table is after the last ret, not after the jmp');
      Check(Table.IndexTableSize = 0, Tag + ': a byte index in hand-written code');
      var EntrySize: Cardinal := 4;
      if Binary.Is64 then
        EntrySize := 8;
      Check((Table.Kind = rtkAbsolute64) = Binary.Is64, Tag + ': the entries have the pointer size of the target');

      // Entry N leads to `mov eax, 100 + N`: read the table, decode its target.
      for var I := 0 to 3 do begin
        var Target: Int64;
        if Binary.Is64 then
          Target := Binary.RvaOf(Binary.ReadU64(Table.TableRva + Cardinal(I) * EntrySize))
        else
          Target := Binary.RvaOf(Binary.ReadU32(Table.TableRva + Cardinal(I) * EntrySize));
        var Detail: TZydisInstructionDetail;
        var Text: string;
        Check(Analysis.IsBoundary(Cardinal(Target)), Format('%s: entry %d is not a boundary', [Tag, I]));
        Check(Binary.Decode(Cardinal(Target), Detail, Text) and SameText(Text, Format('mov eax, 0x%x', [100 + I])),
          Format('%s: entry %d leads to `%s`, not to mov eax, %d', [Tag, I, Text, 100 + I]));
      end;

      // The three verdicts in one routine: the DD / DQ line is inside the
      // table (NOT CODE); the alignment in front of it and the `end` behind it
      // are simply not reached (UNCONFIRMED); everything else is confirmed.
      var InTable := 0;
      var Unconfirmed := 0;
      var TableEnd := Table.TableRva + 4 * EntrySize;
      for var Line in Analysis.Lines do begin
        var Inside := (Line.Rva >= Table.TableRva) and (Line.Rva < TableEnd);
        Check(Inside = (Line.Reason = lvrInJumpTable), Format('%s: record $%x: %s', [Tag, Line.Rva,
          LineVerdictReasonText(Line.Reason)]));
        if Inside then
          Inc(InTable);
        if Line.Verdict = lvUnconfirmed then
          Inc(Unconfirmed);
      end;
      Check(InTable = 1, Format('%s: %d records inside the table, the DD line is one', [Tag, InTable]));
      Check(Unconfirmed >= 1, Tag + ': no unconfirmed record, yet the bytes around the table are not reached');
    finally
      Binary.Free;
    end;
  end;
  AssertNoProblems;
end;

function CountKind(const Analysis: TRoutineAnalysis; Kind: TRoutineHandlerKind): Integer;
begin
  Result := 0;
  for var Handler in Analysis.HandlerEntries do
    if Handler.Kind = Kind then
      Inc(Result);
end;

function CountRole(const Analysis: TRoutineAnalysis; Role: TRoutineExitRole): Integer;
begin
  Result := 0;
  for var ExitItem in Analysis.Exits do
    if ExitItem.Role = Role then
      Inc(Result);
end;

procedure TRoutineAnalysisTests.Sample_X64_ExceptionBlocks_AreNamedByTheScopeAndClauseTables;
begin
  var Binary := OpenSample('Win64');
  try
    // try..finally: the funclet is a .pdata function of its own inside the
    // routine, named as a finally target; its ret is not an exit of the routine.
    var Analysis := AnalyzeMarker(Binary, 'AN_FINALLY_BODY');
    Assert.IsTrue(Analysis.Complete, 'TryFinally must be analysed completely');
    Assert.AreEqual(1, CountKind(Analysis, rhkFinally), 'TryFinally: one finally target');
    Assert.AreEqual(1, CountKind(Analysis, rhkFunction), 'TryFinally: one funclet in .pdata');
    Assert.AreEqual(1, CountRole(Analysis, rerFuncletReturn), 'TryFinally: the funclet returns once');
    Assert.AreEqual(1, CountRole(Analysis, rerRoutineExit), 'TryFinally: the routine has one exit');
    // The finally body has two copies: inline, and in the funclet.
    var Records := MarkerRecords(Binary, 'AN_FINALLY_BLOCK');
    Assert.AreEqual<Integer>(2, Length(Records), 'the finally line has a record in the body and one in the funclet');
    for var LineIndex in Records do
      Assert.IsTrue(Analysis.IsBoundary(Binary.Map.Lines[LineIndex].Rva), 'both copies are confirmed');

    // except with `on`: one clause table of two clauses, inside the routine,
    // and the first block is the line of the first `on`.
    Analysis := AnalyzeMarker(Binary, 'AN_EXCEPT_ON_CLAUSE');
    Assert.IsTrue(Analysis.Complete, 'ExceptWithOn must be analysed completely');
    Assert.AreEqual<Integer>(1, Length(Analysis.ClauseTables), 'ExceptWithOn: one clause table');
    Assert.AreEqual(2, Analysis.ClauseTables[0].Count, 'ExceptWithOn: two `on` clauses');
    Assert.AreEqual(2, CountKind(Analysis, rhkOnBlock), 'ExceptWithOn: two clause blocks');
    var OnLine := Binary.Map.Lines[MarkerRecords(Binary, 'AN_EXCEPT_ON_CLAUSE')[0]].Rva;
    // Read the first clause's block out of the table itself.
    var FirstBlock := Binary.ReadU32(Analysis.ClauseTables[0].Rva + 8);
    Assert.AreEqual<Cardinal>(OnLine, FirstBlock, 'the first clause block is the line of the first `on`');
    Assert.IsTrue(Analysis.FlagsAt(FirstBlock) and (rbfHandlerEntry or rbfBoundary) = rbfHandlerEntry or rbfBoundary,
      'the clause block is a handler entry and a boundary');

    // bare except: no table, one block.
    Analysis := AnalyzeMarker(Binary, 'AN_BARE_BLOCK');
    Assert.IsTrue(Analysis.Complete, 'BareExcept must be analysed completely');
    Assert.AreEqual<Integer>(0, Length(Analysis.ClauseTables), 'BareExcept: no clause table');
    Assert.IsTrue(CountKind(Analysis, rhkExcept) >= 1, 'BareExcept: its except block is named');
    Assert.IsTrue(Analysis.IsBoundary(Binary.Map.Lines[MarkerRecords(Binary, 'AN_BARE_BLOCK')[0]].Rva),
      'the statement in the except block is confirmed');
  finally
    Binary.Free;
  end;
end;

procedure TRoutineAnalysisTests.Sample_X86_ExceptionBlocks_AreFoundThroughTheirStubs;

  function StubOf(const Analysis: TRoutineAnalysis; Kind: TX86StubKind; out Rva: Cardinal): Integer;
  begin
    Result := 0;
    Rva := 0;
    for var Handler in Analysis.HandlerEntries do
      if (Handler.Kind = rhkStub) and (Handler.Stub = Kind) then begin
        Rva := Handler.Rva;
        Inc(Result);
      end;
  end;

  function HasEntry(const Analysis: TRoutineAnalysis; Kind: TRoutineHandlerKind; Rva: Cardinal): Boolean;
  begin
    for var Handler in Analysis.HandlerEntries do
      if (Handler.Kind = Kind) and (Handler.Rva = Rva) then
        Exit(True);
    Result := False;
  end;

  function ExitAt(const Analysis: TRoutineAnalysis; Rva: Cardinal): TRoutineExit;
  begin
    Result := Default(TRoutineExit);
    for var Item in Analysis.Exits do
      if Item.Rva = Rva then
        Exit(Item);
    Assert.Fail(Format('no exit at $%x', [Rva]));
  end;

begin
  var Binary := OpenSample('Win32');
  try
    var Stub: Cardinal;
    // try..finally: stub -> System.@HandleFinally, which CALLS stub + 5; the
    // block ends with pop reg; jmp reg directly in front of the stub; the
    // continuation the try pushed sits behind the jmp at stub + 5.
    var Analysis := AnalyzeMarker(Binary, 'AN_FINALLY_BODY');
    Assert.IsTrue(Analysis.Complete, 'TryFinally must be analysed completely');
    Assert.AreEqual(1, StubOf(Analysis, xskFinally, Stub), 'TryFinally: one stub to HandleFinally');
    Assert.IsTrue(HasEntry(Analysis, rhkAfterStub, Stub + 5), 'TryFinally: the code at stub + 5 is an entry');
    Assert.AreEqual<Integer>(Ord(rerHandlerStub), Ord(ExitAt(Analysis, Stub).Role), 'the stub is not an exit');
    // The instruction in front of the stub is the finally exit.
    var FinallyExits := 0;
    for var Item in Analysis.Exits do
      if Item.Role = rerFinallyExit then begin
        Inc(FinallyExits);
        Assert.AreEqual<Cardinal>(Stub, Item.Rva + Cardinal(Analysis.InstructionLength(Item.Rva)),
          'the finally exit is directly in front of the stub');
        Assert.IsTrue(Analysis.KindAt(Item.Rva) = rikJumpFinally, 'the finally exit is the pop+jmp shape');
      end;
    Assert.AreEqual(1, FinallyExits, 'TryFinally: one finally exit');
    // The continuation: right behind the jump at stub + 5, which goes back to
    // the block's first instruction -- the line of the finally body.
    var JumpBack: TZydisInstructionDetail;
    var Text: string;
    Assert.IsTrue(Binary.Decode(Stub + 5, JumpBack, Text) and JumpBack.HasBranchTarget,
      'stub + 5 is a jump: ' + Text);
    Assert.AreEqual<Int64>(Binary.Map.Lines[MarkerRecords(Binary, 'AN_FINALLY_BLOCK')[0]].Rva,
      Binary.RvaOf(JumpBack.BranchTarget), 'the jump at stub + 5 goes to the finally block');
    Assert.IsTrue(HasEntry(Analysis, rhkContinuation, Stub + 5 + JumpBack.Length),
      'the continuation is right behind the jump at stub + 5');
    Assert.AreEqual<Cardinal>(Stub + 5 + JumpBack.Length,
      Binary.Map.Lines[MarkerRecords(Binary, 'AN_FINALLY_AFTER')[0]].Rva,
      'the continuation is the statement after the try');
    Assert.AreEqual(1, CountRole(Analysis, rerRoutineExit), 'TryFinally: one exit of the routine');

    // except with `on`: stub -> System.@HandleOnException, clause table at
    // stub + 5 with two clauses, the first block being the first `on` line.
    Analysis := AnalyzeMarker(Binary, 'AN_EXCEPT_ON_CLAUSE');
    Assert.IsTrue(Analysis.Complete, 'ExceptWithOn must be analysed completely');
    Assert.AreEqual(1, StubOf(Analysis, xskOnException, Stub), 'ExceptWithOn: one stub to HandleOnException');
    Assert.AreEqual<Integer>(1, Length(Analysis.ClauseTables), 'ExceptWithOn: one clause table');
    Assert.AreEqual<Cardinal>(Stub + 5, Analysis.ClauseTables[0].Rva, 'the clause table is at stub + 5');
    Assert.AreEqual(2, Analysis.ClauseTables[0].Count, 'ExceptWithOn: two `on` clauses');
    var FirstBlock := Binary.RvaOf(Binary.ReadU32(Stub + 5 + 8));
    Assert.AreEqual<Int64>(Binary.Map.Lines[MarkerRecords(Binary, 'AN_EXCEPT_ON_CLAUSE')[0]].Rva, FirstBlock,
      'the first clause block is the line of the first `on`');
    Assert.IsTrue(HasEntry(Analysis, rhkOnBlock, Cardinal(FirstBlock)), 'the clause block is an entry');
    Assert.IsFalse(HasEntry(Analysis, rhkAfterStub, Stub + 5), 'a clause table is not code');

    // bare except: stub -> System.@HandleAnyException, which JUMPS to stub + 5.
    Analysis := AnalyzeMarker(Binary, 'AN_BARE_BLOCK');
    Assert.IsTrue(Analysis.Complete, 'BareExcept must be analysed completely');
    Assert.AreEqual(1, StubOf(Analysis, xskAnyException, Stub), 'BareExcept: one stub to HandleAnyException');
    Assert.AreEqual<Integer>(0, Length(Analysis.ClauseTables), 'BareExcept: no clause table');
    Assert.IsTrue(HasEntry(Analysis, rhkAfterStub, Stub + 5), 'BareExcept: the block starts at stub + 5');
    Assert.IsTrue(Analysis.IsBoundary(Binary.Map.Lines[MarkerRecords(Binary, 'AN_BARE_BLOCK')[0]].Rva),
      'the statement in the except block is confirmed');
  finally
    Binary.Free;
  end;
end;

procedure TRoutineAnalysisTests.Sample_RoutineEndingInACall_ItsEpilogueIsInTheWindowOnX64Only;
begin
  for var Bitness in ['Win64', 'Win32'] do begin
    var Binary := OpenSample(Bitness);
    try
      var Analysis := AnalyzeMarker(Binary, 'AN_LASTCALL_CALL');
      var Tag := Binary.Caption + ': LastStatementIsACall';
      Check(Analysis.Complete, Tag + ' is not analysed completely');
      Check(Length(Analysis.CallSites) >= 1, Tag + ' has no call site');
      if Length(Analysis.CallSites) = 0 then
        Continue;
      var Last := Analysis.CallSites[High(Analysis.CallSites)];
      // The statement after the call is `end`: its record is the return address.
      Check(Analysis.FindLine(Last.ReturnRva) >= 0, Tag + ': the return address of the last call is not a line start');
      // What follows the last call is the epilogue, up to the ret.
      var RetRva: Cardinal := 0;
      for var ExitItem in Analysis.Exits do
        if (ExitItem.Kind = rekReturn) and (ExitItem.Role = rerRoutineExit) then
          RetRva := ExitItem.Rva;
      Check(RetRva > Last.ReturnRva, Tag + ': no ret after the last call');
      if Binary.Is64 then begin
        // lea rsp, [rbp+N]; pop rbp; ret -- the whole epilogue is in the window.
        Check(Last.WindowEndRva = RetRva + Cardinal(Analysis.InstructionLength(RetRva)),
          Format('%s: the window ends at $%x, the ret ends at $%x', [Tag, Last.WindowEndRva,
            RetRva + Cardinal(Analysis.InstructionLength(RetRva))]));
        Check(Analysis.FlagsAt(RetRva) and rbfWindow <> 0, Tag + ': the ret is not in the window');
        Check(Analysis.FlagsAt(Last.ReturnRva) and rbfWindow <> 0, Tag + ': the return address is not in its own window');
      end
      else begin
        Check(Last.WindowEndRva = Last.ReturnRva, Tag + ': a window on x86');
        Check(Analysis.FlagsAt(RetRva) and rbfWindow = 0, Tag + ': the ret is flagged a window on x86');
      end;
      // The call line's first block ends in that call.
      var CallLine := Analysis.Lines[Analysis.FindLine(Binary.Map.Lines[MarkerRecords(Binary, 'AN_LASTCALL_CALL')[0]].Rva)];
      Check(CallLine.BlockEnd = lbeCall, Tag + ': the block of the call line does not end in the call');
      Check(CallLine.BlockEndRva = Last.ReturnRva, Tag + ': the block of the call line does not end at the return address');
    finally
      Binary.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Sample_OneLineLoop_FirstBlockStopsBeforeTheLoopBody;
// `for I := 1 to 3 do Inc(GSink, I);` on one line: the line is entered once
// and its body runs three times. A probe that counts the LINE must sit before
// the address the loop jumps back to.
begin
  for var Bitness in ['Win64', 'Win32'] do begin
    var Binary := OpenSample(Bitness);
    try
      var Analysis := AnalyzeMarker(Binary, 'AN_ONELINE_LOOP');
      var Tag := Binary.Caption + ': OneLineLoop';
      Check(Analysis.Complete, Tag + ' is not analysed completely');
      var Records := MarkerRecords(Binary, 'AN_ONELINE_LOOP');
      var First := Analysis.Lines[Analysis.FindLine(Binary.Map.Lines[Records[0]].Rva)];
      var AfterRva := Binary.Map.Lines[MarkerRecords(Binary, 'AN_ONELINE_AFTER')[0]].Rva;
      // The loop head: the target of the backward jump of the line.
      var Head: Cardinal := 0;
      var Detail: TZydisInstructionDetail;
      var Text: string;
      var At := First.Rva;
      while At < AfterRva do begin
        if not Analysis.IsBoundary(At) then
          Break;
        if (Analysis.KindAt(At) in [rikJump, rikJumpConditional]) and Binary.Decode(At, Detail, Text) and
           (Binary.RvaOf(Detail.BranchTarget) <= At) and (Binary.RvaOf(Detail.BranchTarget) > First.Rva) then
          Head := Cardinal(Binary.RvaOf(Detail.BranchTarget));
        Inc(At, Analysis.InstructionLength(At));
      end;
      Check(Head <> 0, Tag + ': no backward jump found in the line: the fixture is not a loop any more');
      if Head = 0 then
        Continue;
      Check(Analysis.FlagsAt(Head) and rbfTarget <> 0, Tag + ': the loop head is not flagged a target');
      Check(First.Verdict = lvConfirmed, Tag + ': the line is not confirmed');
      Check(First.BlockEndRva <= Head, Format('%s: the first block [$%x..$%x) reaches into the loop body at $%x',
        [Tag, First.Rva, First.BlockEndRva, Head]));
    finally
      Binary.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Sample_FramelessLeaf_IsOneBlockEndingInItsRet;
begin
  for var Bitness in ['Win64', 'Win32'] do begin
    var Binary := OpenSample(Bitness);
    try
      var Analysis := AnalyzeMarker(Binary, 'AN_LEAF_BODY');
      var Tag := Binary.Caption + ': FramelessLeaf';
      Check(Analysis.Complete, Tag + ' is not analysed completely');
      Check(Length(Analysis.CallSites) = 0, Tag + ' is a leaf and has call sites');
      Check(Length(Analysis.Exits) = 1, Format('%s has %d exits', [Tag, Length(Analysis.Exits)]));
      // No prologue: the first instruction is not a push of the frame pointer.
      Check(not (Binary.ReadByte(Analysis.StartRva) in [$55]), Tag + ' starts with push ebp/rbp: it has a frame');
      // Every byte of it is a proven instruction.
      var Proven := 0;
      for var Flag in Analysis.Flags do
        if Flag and (rbfBoundary or rbfInterior) <> 0 then
          Inc(Proven);
      var LastRet := Analysis.Exits[High(Analysis.Exits)].Rva;
      Check(Proven >= Integer(LastRet - Analysis.StartRva) + 1, Tag + ': unproven bytes before its ret');
    finally
      Binary.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Sample_NestedRoutines_AreRoutinesOfTheirOwn;
begin
  for var Bitness in ['Win64', 'Win32'] do begin
    var Binary := OpenSample(Bitness);
    try
      var Outer := RoutineOfMarker(Binary, 'AN_NESTED_OUTER');
      var Middle := RoutineOfMarker(Binary, 'AN_NESTED_MIDDLE');
      var Inner := RoutineOfMarker(Binary, 'AN_NESTED_INNER');
      Check((Outer <> Middle) and (Middle <> Inner) and (Outer <> Inner),
        Binary.Caption + ': the nested routines do not have three ranges of their own');
      for var Index in TArray<Integer>.Create(Outer, Middle, Inner) do begin
        var Analysis := Binary.Analyzer.Analyze(Index);
        Check(Analysis.Complete, Format('%s: %s is not analysed completely', [Binary.Caption,
          Binary.Map.Routines[Index].Name]));
        for var Line in Analysis.Lines do
          Check(Line.Verdict = lvConfirmed, Format('%s: %s record $%x: %s', [Binary.Caption,
            Binary.Map.Routines[Index].Name, Line.Rva, LineVerdictReasonText(Line.Reason)]));
      end;
      // The middle routine calls the inner one twice, directly.
      var MiddleAnalysis := Binary.Analyzer.Analyze(Middle);
      var ToInner := 0;
      for var Call in MiddleAnalysis.CallSites do
        if Call.TargetRva = Binary.Map.Routines[Inner].StartRva then
          Inc(ToInner);
      Check(ToInner = 2, Format('%s: %d direct calls from AddTwice to AddOnce, the source has 2',
        [Binary.Caption, ToInner]));
    finally
      Binary.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Sample_AnonymousMethod_X64FromPdata_X86OnlyWithAMap;
// The body of an anonymous method has no procedure record in TD32. On x64
// .pdata names it; on x86 nothing does, unless the code map takes its routine
// ranges from a MAP, which calls it ...$ActRec.$0$Body.
begin
  // x64: outside every routine of the code map, inside an unmapped function,
  // confirmed.
  var Binary := OpenSample('Win64');
  try
    var Records := MarkerRecords(Binary, 'AN_ANON_BODY');
    Assert.AreEqual(-1, Binary.Map.Lines[Records[0]].RoutineIndex,
      'x64: the body of the anonymous method must lie outside every TD32 routine (the premise)');
    Assert.IsTrue(Length(Binary.Analyzer.UnmappedFunctions) >= 1, 'x64: .pdata must name the body');
    var Line := Binary.Analyzer.AnalyzeLine(Records[0]);
    Assert.IsTrue(Line.Verdict = lvConfirmed, 'x64: confirmed from the .pdata entry: ' +
      LineVerdictReasonText(Line.Reason));
    var Holder := -1;
    for var I := 0 to High(Binary.Analyzer.UnmappedFunctions) do
      if (Line.Rva >= Binary.Analyzer.UnmappedFunctions[I].StartRva) and
         (Line.Rva < Binary.Analyzer.UnmappedFunctions[I].EndRva) then
        Holder := I;
    Assert.IsTrue(Holder >= 0, 'x64: no unmapped function holds the record');
    var Analysis := Binary.Analyzer.AnalyzeUnmapped(Holder);
    Assert.IsTrue(Analysis.Complete, 'x64: the body must be analysed completely');
    Assert.AreEqual(-1, Analysis.RoutineIndex, 'x64: the body is not a routine of the code map');
    // Its entry is the .pdata BeginAddress, so the range starts on a boundary.
    Assert.IsTrue(Analysis.IsBoundary(Analysis.StartRva), 'x64: the function starts on a boundary');
  finally
    Binary.Free;
  end;

  // x86, TD32 alone: unconfirmed, and NOT "not code".
  Binary := OpenSample('Win32');
  var BodyRva: Cardinal;
  try
    var Records := MarkerRecords(Binary, 'AN_ANON_BODY');
    Assert.AreEqual(-1, Binary.Map.Lines[Records[0]].RoutineIndex,
      'x86: the body of the anonymous method must lie outside every TD32 routine (the premise)');
    var Line := Binary.Analyzer.AnalyzeLine(Records[0]);
    BodyRva := Line.Rva;
    Assert.IsTrue(Line.Verdict = lvUnconfirmed, 'x86 without a MAP: unconfirmed');
    Assert.IsTrue(Line.Reason = lvrOutsideEveryRoutine, 'x86 without a MAP: ' + LineVerdictReasonText(Line.Reason));
  finally
    Binary.Free;
  end;

  // x86, routine ranges from the MAP: the body is a routine and its records
  // are confirmed.
  var MapFile := TMapFile.Create;
  var Keep: IInterface := MapFile;
  MapFile.LoadFromFile(SamplePath('Win32', '.map'), ReadPEPreferredBase(SamplePath('Win32', '.exe')));
  MapFile.ImageSize := ReadPEImageSize(SamplePath('Win32', '.exe'));
  var Routines: IRoutineRangeProvider;
  Assert.IsTrue(Supports(Keep, IRoutineRangeProvider, Routines), 'the MAP reader must supply routine ranges');
  Binary := TAnalysedBinary.Create('sample x86 + MAP', SamplePath('Win32', '.exe'), [], Routines);
  try
    var LineIndex := Binary.Map.FindLine(BodyRva);
    Assert.IsTrue(LineIndex >= 0, 'x86 + MAP: the record is gone');
    Assert.IsTrue(Binary.Map.Lines[LineIndex].RoutineIndex >= 0,
      'x86 + MAP: the MAP must give the body a routine range');
    var Line := Binary.Analyzer.AnalyzeLine(LineIndex);
    Assert.IsTrue(Line.Verdict = lvConfirmed, 'x86 + MAP: confirmed: ' + LineVerdictReasonText(Line.Reason));
  finally
    Binary.Free;
  end;
end;

procedure TRoutineAnalysisTests.Sample_Safecall_HandlerIsAFuncletOnX64AndAStubOnX86;
// The compiler wraps a safecall routine's body in a handler of its own. On x64
// it is a FUNCLET: a scope entry with Handler = 1 whose Target is a .pdata
// function inside the routine's range, and whose ret goes back to the RTL. On
// x86 it is a stub to System.@HandleAutoException, which jumps to stub + 5.
begin
  var Binary := OpenSample('Win64');
  try
    var Analysis := AnalyzeMarker(Binary, 'AN_SAFECALL_BODY');
    Assert.IsTrue(Analysis.Complete, 'x64: SafecallShape must be analysed completely');
    Assert.AreEqual(1, CountKind(Analysis, rhkSafecall), 'x64: one safecall handler');
    var Funclet: Cardinal := 0;
    for var Handler in Analysis.HandlerEntries do
      if Handler.Kind = rhkSafecall then
        Funclet := Handler.Rva;
    var IsFunction := False;
    for var Handler in Analysis.HandlerEntries do
      if (Handler.Kind = rhkFunction) and (Handler.Rva = Funclet) then
        IsFunction := True;
    Assert.IsTrue(IsFunction, 'x64: the safecall handler is a .pdata function of its own');
    Assert.IsTrue(Analysis.IsBoundary(Funclet), 'x64: the funclet starts on a boundary');
    Assert.AreEqual(1, CountRole(Analysis, rerRoutineExit), 'x64: the routine has one exit');
    var FuncletReturns := 0;
    for var ExitItem in Analysis.Exits do
      if ExitItem.Role = rerFuncletReturn then begin
        Inc(FuncletReturns);
        Assert.IsTrue(ExitItem.Rva > Funclet, 'x64: the funclet''s ret is inside the funclet');
      end;
    Assert.AreEqual(1, FuncletReturns, 'x64: the ret of the handler funclet is not an exit of the routine');
  finally
    Binary.Free;
  end;

  Binary := OpenSample('Win32');
  try
    var Analysis := AnalyzeMarker(Binary, 'AN_SAFECALL_BODY');
    Assert.IsTrue(Analysis.Complete, 'x86: SafecallShape must be analysed completely');
    var Stub: Cardinal := 0;
    var Stubs := 0;
    for var Handler in Analysis.HandlerEntries do
      if (Handler.Kind = rhkStub) and (Handler.Stub = xskAutoException) then begin
        Stub := Handler.Rva;
        Inc(Stubs);
      end;
    Assert.AreEqual(1, Stubs, 'x86: one stub to HandleAutoException');
    var Entered := False;
    for var Handler in Analysis.HandlerEntries do
      if (Handler.Kind = rhkAfterStub) and (Handler.Rva = Stub + 5) then
        Entered := True;
    Assert.IsTrue(Entered, 'x86: the RTL jumps to stub + 5, which must be an entry');
    Assert.IsTrue(Analysis.IsBoundary(Stub + 5), 'x86: stub + 5 is a boundary');
    Assert.AreEqual<Integer>(0, Length(Analysis.ClauseTables), 'x86: no clause table behind this stub');
    Assert.AreEqual(1, CountRole(Analysis, rerRoutineExit), 'x86: the routine has one exit');
    Assert.AreEqual(1, CountRole(Analysis, rerHandlerStub), 'x86: the stub is listed, and is not an exit');
  finally
    Binary.Free;
  end;
end;

{ TRoutineAnalysisTests: negative controls }

procedure TRoutineAnalysisTests.Without_TheX86FinallyExit_RoutinesGoIncomplete;
// The plan's measurement: without the `pop eax; jmp eax` shape a fifth of all
// routines come out unfinished. Here: every routine that has such an exit, and
// no other.
begin
  for var RelativePath in ['TestTarget\Win32\Debug\AnalysisSample.exe', 'TestTarget\Win32\Debug\TestTarget.exe'] do begin
    var WithRule := TAnalysedBinary.Create('x86 ' + ExtractFileName(RelativePath), FixtureRoot + RelativePath);
    var Without := TAnalysedBinary.Create('x86 ' + ExtractFileName(RelativePath) + ' without the rule',
      FixtureRoot + RelativePath, [rarFinallyExit]);
    try
      var HaveOne := 0;
      for var I := 0 to High(WithRule.Map.Routines) do begin
        if WithRule.Map.Routines[I].LineCount = 0 then
          Continue;
        var Good := WithRule.Analyzer.Analyze(I);
        var Bad := Without.Analyzer.Analyze(I);
        var FinallyExits := 0;
        for var ExitItem in Good.Exits do
          if ExitItem.Role = rerFinallyExit then
            Inc(FinallyExits);
        var Name := WithRule.Caption + ': ' + WithRule.Map.Routines[I].Name;
        Check(Good.Complete, Name + ' is not complete WITH the rule');
        if FinallyExits = 0 then begin
          Check(Bad.Complete, Name + ' has no finally exit and is incomplete without the rule');
          Continue;
        end;
        Inc(HaveOne);
        Check((not Bad.Complete) and (rirIndirectJump in Bad.Incomplete),
          Name + ' has a finally exit and is still complete without the rule');
        // Not complete means: no multi-byte patch anywhere in it. What was
        // confirmed before the break stays confirmed.
        Check(Bad.IsBoundary(Bad.StartRva), Name + ': the entry is no longer a boundary');
      end;
      Check(HaveOne > 0, WithRule.Caption + ': no routine with a finally exit: the control controls nothing');
      // The fixture the plan measured: 87 of 425.
      if RelativePath.EndsWith('TestTarget.exe') then
        Check(HaveOne > 50, Format('%s: only %d routines with a finally exit', [WithRule.Caption, HaveOne]));
    finally
      Without.Free;
      WithRule.Free;
    end;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Without_JumpTables_TheCaseArmsAreNotConfirmed;
begin
  var Without := OpenSample('Win32', [rarJumpTables]);
  try
    var Analysis := AnalyzeMarker(Without, 'AN_DENSE_CASE');
    Assert.IsFalse(Analysis.Complete, 'without table recognition DenseCase must be incomplete');
    Assert.IsTrue(rirIndirectJump in Analysis.Incomplete, 'the reason is the indirect jump');
    Assert.AreEqual<Integer>(0, Length(Analysis.JumpTables), 'no table may be listed');
    // The arms are reached ONLY through the table: unconfirmed, not "not code".
    var Arm := Analysis.Lines[Analysis.FindLine(Without.Map.Lines[MarkerRecords(Without, 'AN_DENSE_6')[0]].Rva)];
    Assert.IsTrue(Arm.Verdict = lvUnconfirmed, 'the arm of value 6: ' + LineVerdictReasonText(Arm.Reason));
    // What the decode reached before the jump stays confirmed.
    var Head := Analysis.Lines[Analysis.FindLine(Without.Map.Lines[MarkerRecords(Without, 'AN_DENSE_CASE')[0]].Rva)];
    Assert.IsTrue(Head.Verdict = lvConfirmed, 'the case line itself stays confirmed');
  finally
    Without.Free;
  end;
end;

procedure TRoutineAnalysisTests.Without_X86HandlerStubs_TheHandlerBlocksAreNotConfirmed;
begin
  var Without := OpenSample('Win32', [rarHandlerStubs]);
  try
    for var Marker in ['AN_EXCEPT_ON_BLOCK', 'AN_BARE_BLOCK', 'AN_FINALLY_AFTER'] do begin
      var Analysis := AnalyzeMarker(Without, Marker);
      var Line := Analysis.Lines[Analysis.FindLine(Without.Map.Lines[MarkerRecords(Without, Marker)[0]].Rva)];
      Check(Line.Verdict = lvUnconfirmed, Format('%s without the stubs: %s', [Marker,
        LineVerdictReasonText(Line.Reason)]));
      Check(Length(Analysis.HandlerEntries) = 0, Marker + ': handler entries listed without the rule');
    end;
  finally
    Without.Free;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Without_X64ExceptionTables_TheHandlerBlocksAreNotConfirmed;
begin
  var Without := OpenSample('Win64', [rarExceptionTables]);
  try
    for var Marker in ['AN_EXCEPT_ON_CLAUSE', 'AN_BARE_BLOCK'] do begin
      var Analysis := AnalyzeMarker(Without, Marker);
      var Line := Analysis.Lines[Analysis.FindLine(Without.Map.Lines[MarkerRecords(Without, Marker)[0]].Rva)];
      Check(Line.Verdict = lvUnconfirmed, Format('%s without the exception tables: %s', [Marker,
        LineVerdictReasonText(Line.Reason)]));
      Check(Length(Analysis.HandlerEntries) = 0, Marker + ': handler entries listed without the rule');
    end;
    // The funclet copy of a finally body is reached only through .pdata.
    var Records := MarkerRecords(Without, 'AN_FINALLY_UNWOUND');
    var Analysis := AnalyzeMarker(Without, 'AN_FINALLY_UNWOUND');
    var Unconfirmed := 0;
    for var LineIndex in Records do
      if not Analysis.IsBoundary(Without.Map.Lines[LineIndex].Rva) then
        Inc(Unconfirmed);
    Check(Unconfirmed >= 1, 'the funclet copy of the finally body is confirmed without the exception tables');
  finally
    Without.Free;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Without_NoReturnCalls_TheMainBlockRunsIntoData;
// A program's main block ends in a call to System.@Halt0, and what follows it
// in the procedure range is not code.
begin
  var WithRule := TAnalysedBinary.Create('exe x86', FixtureRoot + 'TestTarget\Win32\Debug\TestTarget.exe');
  var Without := TAnalysedBinary.Create('exe x86 without the rule',
    FixtureRoot + 'TestTarget\Win32\Debug\TestTarget.exe', [rarNoReturnCalls]);
  try
    var Broken := 0;
    for var I := 0 to High(WithRule.Map.Routines) do begin
      if WithRule.Map.Routines[I].LineCount = 0 then
        Continue;
      var Good := WithRule.Analyzer.Analyze(I);
      var Bad := Without.Analyzer.Analyze(I);
      Check(Good.Complete, WithRule.Map.Routines[I].Name + ' is not complete WITH the rule');
      if Bad.Complete then
        Continue;
      Inc(Broken);
      // The break is behind a call to the routine that never returns.
      var AfterHalt := False;
      for var Call in Good.CallSites do
        if (Call.TargetRva >= 0) and (WithRule.Map.FindRoutine(Cardinal(Call.TargetRva)) >= 0) and
           WithRule.Map.Routines[WithRule.Map.FindRoutine(Cardinal(Call.TargetRva))].Name.Contains('Halt0') and
           (Bad.IncompleteAtRva >= Call.ReturnRva) then
          AfterHalt := True;
      Check(AfterHalt, WithRule.Map.Routines[I].Name + ' breaks without the rule, but not behind a call to Halt0');
    end;
    Check(Broken >= 1, 'no routine breaks without the rule: the control controls nothing');
  finally
    Without.Free;
    WithRule.Free;
  end;
  AssertNoProblems;
end;

{ TRoutineAnalysisTests: the verdicts }

procedure TRoutineAnalysisTests.StrayRecords_AreNotCodeOnlyWhenTheBytesSaySo;
// A record outside every routine (and, on x64, outside every .pdata function)
// cannot be confirmed. It is "not code" only when its own bytes show it: a
// zero byte -- the final `end.` of a unit on a 32-bit image, which the 0.9.3
// stopgap refuses for the same reason -- or bytes that are no instruction.
// Otherwise it stays unconfirmed: on x86 it may be an anonymous method.
begin
  for var RelativePath in ['TestTarget\Win32\Debug\TestTarget.exe', 'TestTarget\Win64\Debug\TestTarget.exe',
    'TestHost\Win32\Debug\TestSubject.bpl', 'TestHost\Win64\Debug\TestSubject.bpl'] do begin
    var Binary := TAnalysedBinary.Create(RelativePath, FixtureRoot + RelativePath);
    try
      for var I := 0 to High(Binary.Map.Lines) do begin
        if Binary.Map.Lines[I].RoutineIndex >= 0 then
          Continue;
        var Line := Binary.Analyzer.AnalyzeLine(I);
        var Tag := Format('%s: record $%x outside every routine', [RelativePath, Line.Rva]);
        var Detail: TZydisInstructionDetail;
        var Text: string;
        case Line.Verdict of
          lvConfirmed:
            Check(Binary.Is64, Tag + ' is confirmed on x86, where nothing proves an entry');
          lvNotCode:
            Check(((Line.Reason = lvrZeroByte) and (Binary.ReadByte(Line.Rva) = 0)) or
                  ((Line.Reason = lvrUndecodable) and not Binary.Decode(Line.Rva, Detail, Text)),
                  Format('%s is said not to be code (%s) and its bytes do not show it', [Tag,
                    LineVerdictReasonText(Line.Reason)]));
          lvUnconfirmed:
            Check((Binary.ReadByte(Line.Rva) <> 0) and Binary.Decode(Line.Rva, Detail, Text),
              Tag + ' is unconfirmed although its bytes are zero or no instruction');
        end;
      end;
    finally
      Binary.Free;
    end;
  end;
  // The x86 executable is the one the stopgap was written for: its units'
  // final `end.` records point at a zero byte.
  var Exe := TAnalysedBinary.Create('exe x86', FixtureRoot + 'TestTarget\Win32\Debug\TestTarget.exe');
  try
    var ZeroByte := 0;
    for var I := 0 to High(Exe.Map.Lines) do
      if (Exe.Map.Lines[I].RoutineIndex < 0) and (Exe.Analyzer.AnalyzeLine(I).Reason = lvrZeroByte) then
        Inc(ZeroByte);
    Check(ZeroByte >= 1, 'exe x86: no stray record on a zero byte: the fixture lost its `end.` records');
  finally
    Exe.Free;
  end;
  AssertNoProblems;
end;

procedure TRoutineAnalysisTests.Unavailable_WhenDllMissing_NothingIsConfirmedAndNothingIsRefused;
// Zydis is optional at run time. Without it the analysis reports "unavailable":
// no record is confirmed (so no probe is placed) and none is called "not code"
// (so no breakpoint is refused on the strength of an analysis that did not run).
begin
  ZydisResetForTests;
  Assert.IsFalse(ZydisTryLoad('X:\does-not-exist\RoutineAnalysisTests\NotReallyZydis.dll'),
    'a missing DLL must not load');
  try
    var Image := TPeImageFile.Create(SamplePath('Win32', '.exe'));
    var Reader := TTD32FileReader.Create;
    var Keep: IInterface := Reader;
    Reader.LoadFromFile(SamplePath('Win32', '.exe'));
    var Map := TModuleCodeMap.Build('AnalysisSample.exe', Reader, Reader, 0, Image.SizeOfImage);
    var Input := Default(TRoutineAnalysisInput);
    Input.Mode      := dmmLegacy32;
    Input.Reader    := Image.Read;
    Input.ImageBase := Image.ImageBase;
    Input.CodeMap   := Map;
    // A path is given, and ignored: the load latch already holds the failure.
    Input.ZydisDllPath := ZydisDll;
    var Analyzer := TRoutineAnalyzer.Create(Input);
    try
      Assert.IsFalse(Analyzer.Available, 'the analyzer must report the decoder unavailable');
      Assert.IsTrue(Analyzer.StatusText <> '', 'and say why');
      var Analysed := 0;
      for var I := 0 to High(Map.Routines) do begin
        if Map.Routines[I].LineCount = 0 then
          Continue;
        var Analysis := Analyzer.Analyze(I);
        Inc(Analysed);
        Assert.IsFalse(Analysis.Complete, 'no routine may be complete');
        Assert.IsTrue(Analysis.Incomplete = [rirDecoderUnavailable], 'the reason is the decoder');
        Assert.AreEqual<Integer>(0, Analysis.InstructionCount, 'nothing may be decoded');
        Assert.AreEqual<Integer>(Map.Routines[I].LineCount, Length(Analysis.Lines), 'every record gets a verdict');
        for var Line in Analysis.Lines do begin
          Assert.IsTrue(Line.Verdict = lvUnconfirmed, 'no record may be confirmed or refused');
          Assert.IsTrue(Line.Reason = lvrDecoderUnavailable, 'the reason is the decoder');
        end;
      end;
      Assert.IsTrue(Analysed > 10, 'the test analysed nothing');
      for var I := 0 to High(Map.Lines) do
        if Map.Lines[I].RoutineIndex < 0 then begin
          var Stray := Analyzer.AnalyzeLine(I);
          Assert.IsTrue((Stray.Verdict = lvUnconfirmed) and (Stray.Reason = lvrDecoderUnavailable),
            'a stray record must not be refused without a decoder');
        end;
    finally
      Analyzer.Free;
      Map.Free;
      Keep := nil;
      Image.Free;
    end;
  finally
    // Leave the latch clean for whatever runs next in this process.
    ZydisResetForTests;
  end;
end;

{ ------------------------------------------------------- dynamic oracle ---- }

const
  // The whole sample is a few thousand instructions. A run that needs more
  // stops than this is looping.
  MAX_STOPS       = 20000;
  STOP_TIMEOUT_MS = 60000;
  RUN_TIMEOUT_MS  = 300000;

procedure PumpUntilStop(Session: TDebugSession; TimeoutMs: Cardinal);
begin
  var Deadline := GetTickCount64 + TimeoutMs;
  while (Session.State <> dsStopped) and (not Session.HasExited) and (GetTickCount64 < Deadline) do
    Session.Pump;
end;

// The analysis of the SAME routines made on the live process, through the
// engine's reader, must be the analysis made on the file: same flags byte for
// byte, same verdicts. The live image is relocated and has breakpoints
// planted in it; neither may show.
procedure CompareLiveWithFile(Binary: TAnalysedBinary; Session: TDebugSession;
  const FromFile: TList<TRoutineAnalysis>; Problems: TList<string>);
begin
  var Dbg := Session.Debugger;
  var Input := Default(TRoutineAnalysisInput);
  Input.Mode := dmmLegacy32;
  if Binary.Is64 then
    Input.Mode := dmmLong64;
  Input.Reader :=
    function(VA: UInt64; Buf: Pointer; Size: Integer): Integer
    begin
      Result := Integer(Dbg.ReadCodeMemoryAt(VA, Buf, NativeUInt(Size)));
    end;
  Input.ImageBase    := Dbg.ImageBase;
  Input.CodeMap      := Binary.Map;
  Input.ZydisDllPath := ZydisDll;
  var Live := TRoutineAnalyzer.Create(Input);
  try
    if Length(Live.UnmappedFunctions) <> Length(Binary.Analyzer.UnmappedFunctions) then
      Problems.Add(Format('live: %d functions known from .pdata only, the file has %d',
        [Length(Live.UnmappedFunctions), Length(Binary.Analyzer.UnmappedFunctions)]));
    for var Expected in FromFile do begin
      var Actual: TRoutineAnalysis;
      if Expected.RoutineIndex >= 0 then
        Actual := Live.Analyze(Expected.RoutineIndex)
      else begin
        var Index := -1;
        for var I := 0 to High(Live.UnmappedFunctions) do
          if Live.UnmappedFunctions[I].StartRva = Expected.StartRva then
            Index := I;
        if Index < 0 then begin
          Problems.Add(Format('live: no .pdata function at $%x', [Expected.StartRva]));
          Continue;
        end;
        Actual := Live.AnalyzeUnmapped(Index);
      end;
      var Tag := Format('live analysis of [%x..%x)', [Expected.StartRva, Expected.EndRva]);
      if (Actual.Complete <> Expected.Complete) or (Actual.InstructionCount <> Expected.InstructionCount) then
        Problems.Add(Format('%s: complete=%s instructions=%d, the file says %s and %d', [Tag,
          BoolToStr(Actual.Complete, True), Actual.InstructionCount, BoolToStr(Expected.Complete, True),
          Expected.InstructionCount]));
      if (Length(Actual.Flags) <> Length(Expected.Flags)) or ((Length(Actual.Flags) > 0) and
         not CompareMem(@Actual.Flags[0], @Expected.Flags[0], Length(Actual.Flags) * SizeOf(Word))) then
        Problems.Add(Tag + ': the flags differ from the file''s');
      if Length(Actual.Lines) <> Length(Expected.Lines) then
        Problems.Add(Tag + ': a different number of line records')
      else
        for var I := 0 to High(Actual.Lines) do
          if (Actual.Lines[I].Reason <> Expected.Lines[I].Reason) or
             (Actual.Lines[I].BlockEndRva <> Expected.Lines[I].BlockEndRva) then
            Problems.Add(Format('%s: record $%x differs from the file''s', [Tag, Actual.Lines[I].Rva]));
      if (Length(Actual.JumpTables) <> Length(Expected.JumpTables)) or
         (Length(Actual.HandlerEntries) <> Length(Expected.HandlerEntries)) or
         (Length(Actual.CallSites) <> Length(Expected.CallSites)) or
         (Length(Actual.Exits) <> Length(Expected.Exits)) then
        Problems.Add(Tag + ': tables, handler entries, call sites or exits differ from the file''s');
    end;
  finally
    Live.Free;
  end;
end;

procedure RunDynamicOracle(const Bitness: string);
var
  Code: array[0..15] of Byte;
  Detail: TZydisInstructionDetail;
begin
  Assert.IsTrue(FileExists(SamplePath(Bitness, '.exe')), 'fixture not built: ' + SamplePath(Bitness, '.exe'));
  var Binary := TAnalysedBinary.Create('sample ' + Bitness, SamplePath(Bitness, '.exe'));
  var Analyses := TList<TRoutineAnalysis>.Create;
  var Problems := TList<string>.Create;
  var Seen := TDictionary<Cardinal, Boolean>.Create;
  var RoutinesSeen := TDictionary<Cardinal, Boolean>.Create;
  var MarkerRvas := TDictionary<Cardinal, Boolean>.Create;
  var Session: TDebugSession := nil;
  try
    // The ranges under test: every routine that holds a line record (the
    // sample's own code; the RTL it links has none), and on x64 the functions
    // only .pdata knows -- the anonymous method. Both lists ascend.
    for var I := 0 to High(Binary.Map.Routines) do
      if Binary.Map.Routines[I].LineCount > 0 then
        Analyses.Add(Binary.Analyzer.Analyze(I));
    for var I := 0 to High(Binary.Analyzer.UnmappedFunctions) do
      Analyses.Add(Binary.Analyzer.AnalyzeUnmapped(I));
    Assert.IsTrue(Analyses.Count >= 15, Format('%s: only %d ranges to step through', [Bitness, Analyses.Count]));

    var FindAnalysis: TFunc<Int64, Integer> :=
      function(Rva: Int64): Integer
      begin
        for var I := 0 to Analyses.Count - 1 do
          if (Rva >= Analyses[I].StartRva) and (Rva < Analyses[I].EndRva) then
            Exit(I);
        Result := -1;
      end;

    Session := TDebugSession.Create;
    var Opts := Default(TLaunchOptions);
    Opts.ExePath     := SamplePath(Bitness, '.exe');
    Opts.MapPath     := SamplePath(Bitness, '.map');
    Opts.RsmPath     := SamplePath(Bitness, '.rsm');
    Opts.SourceRoot  := TargetDir;
    Opts.StopAtEntry := False;
    Assert.IsTrue(Session.Launch(Opts), Bitness + ': Launch returned False');

    // A breakpoint on every marker line: where single-stepping resumes after
    // the program has been somewhere this test does not follow it (the RTL,
    // the system's exception dispatch). Marker lines only -- a breakpoint on
    // the DD line of AsmTable would be a $CC in its jump table.
    var Specs: TArray<TBpLineSpec> := [];
    for var Marker in SampleMarkers do begin
      var Spec := Default(TBpLineSpec);
      Spec.Line := Marker.Line;
      Specs := Specs + [Spec];
      for var FileIndex in Binary.Map.FindFiles(SAMPLE_SOURCE) do begin
        var Records := Binary.Map.LinesAt(FileIndex, Marker.Line);
        if Length(Records) > 0 then
          MarkerRvas.AddOrSetValue(Binary.Map.Lines[Records[0]].Rva, True);
      end;
    end;
    Session.SetBreakpoints(SAMPLE_SOURCE, Specs);
    var LastStatementRva: Cardinal := 0;
    for var Marker in SampleMarkers do
      if Marker.Name = 'AN_MAIN_LAST' then
        for var FileIndex in Binary.Map.FindFiles(SAMPLE_SOURCE) do
          LastStatementRva := Binary.Map.Lines[Binary.Map.LinesAt(FileIndex, Marker.Line)[0]].Rva;
    Assert.IsTrue(LastStatementRva <> 0, Bitness + ': marker AN_MAIN_LAST has no line record');
    PumpUntilStop(Session, STOP_TIMEOUT_MS);
    Assert.AreEqual(Ord(dsStopped), Ord(Session.State), Bitness + ': the sample did not stop at its first marker');

    var Dbg := Session.Debugger;
    var Base: UInt64 := Dbg.ImageBase;
    var Mode := Binary.Mode;
    CompareLiveWithFile(Binary, Session, Analyses, Problems);

    // And a breakpoint on every exception-handler entry of the analysed ranges.
    // Those addresses are read from tables and pushed immediates, not decoded;
    // a handler is entered by the system or by the RTL, so no single step leads
    // to its first instruction. Stopping there shows the processor does start
    // an instruction at the address, and lets the steps continue from it.
    // Not where a marker breakpoint already sits: every SetAddressBreakpoint
    // re-posts the whole address set, and TWinDebugger.RemoveInt3 puts the
    // original byte back without looking for a second breakpoint on the same
    // address -- the marker would silently stop firing (measured here: the
    // `on` block of ExceptWithOn was run through without a stop).
    for var Item in Analyses do
      for var Handler in Item.HandlerEntries do
        if not MarkerRvas.ContainsKey(Handler.Rva) then
          Session.SetAddressBreakpoint(Base + Handler.Rva, '', '', '');

    var Stops := 0;
    var Steps := 0;
    var Inside := 0;
    var LineStarts := 0;
    var Transfers := 0;
    var ThroughTables := 0;
    var HandlerEntries := 0;
    var HandlerStops := '';
    var ReachedTheEnd := False;
    var PrevStepped := False;
    var PrevIndex := -1;
    var PrevRva: Cardinal := 0;
    var PrevLen := 0;
    var PrevKind := zikOther;
    var Deadline := GetTickCount64 + RUN_TIMEOUT_MS;
    while (Session.State = dsStopped) and not Session.HasExited do begin
      Inc(Stops);
      if (Stops > MAX_STOPS) or (GetTickCount64 > Deadline) then begin
        Problems.Add(Format('gave up after %d stops: the run does not end', [Stops]));
        Break;
      end;
      var Pc: UInt64 := Dbg.GetRegisters.Pc;
      var Index := -1;
      var Rva: Cardinal := 0;
      if (Pc >= Base) and (Pc - Base < Binary.Image.SizeOfImage) then begin
        Rva := Cardinal(Pc - Base);
        Index := FindAnalysis(Rva);
      end;
      // Somewhere this test does not follow: run on to the next marker.
      if (Index < 0) or (Session.StopReason = srException) then begin
        PrevStepped := False;
        Session.ContinueExecution;
        PumpUntilStop(Session, STOP_TIMEOUT_MS);
        Continue;
      end;

      // THE ORACLE: the processor is about to execute an instruction here.
      var Analysis := Analyses[Index];
      Inc(Inside);
      Seen.AddOrSetValue(Rva, True);
      RoutinesSeen.AddOrSetValue(Analysis.StartRva, True);
      var Flag := Analysis.FlagsAt(Rva);
      if Flag and rbfBoundary = 0 then
        Problems.Add(Format('the processor stopped at $%x in [%x..%x) and the analysis has no boundary there (flags $%x)',
          [Rva, Analysis.StartRva, Analysis.EndRva, Flag]));
      if Rva = LastStatementRva then
        ReachedTheEnd := True;
      var LineAt := Analysis.FindLine(Rva);
      if LineAt >= 0 then begin
        Inc(LineStarts);
        if Analysis.Lines[LineAt].Verdict <> lvConfirmed then
          Problems.Add(Format('the processor executed the line record at $%x and the analysis says: %s',
            [Rva, LineVerdictReasonText(Analysis.Lines[LineAt].Reason)]));
      end;
      if Flag and rbfHandlerEntry <> 0 then begin
        Inc(HandlerEntries);
        HandlerStops := HandlerStops + Format(' $%x', [Rva]);
      end;
      // Control arrived here by a single step inside the same range and not by
      // falling through: the analysis must list the address as reachable.
      if PrevStepped and (PrevIndex = Index) and (Int64(Rva) <> Int64(PrevRva) + PrevLen) then begin
        Inc(Transfers);
        var Reachable := Flag and rbfTarget <> 0;
        if PrevKind = zikReturn then
          Reachable := Reachable or (Flag and rbfReturnAddr <> 0);
        if not Reachable then
          Problems.Add(Format('control went from $%x to $%x and the analysis does not list $%x as a target (flags $%x)',
            [PrevRva, Rva, Rva, Flag]));
        if (PrevKind = zikJumpIndirect) and (Flag and rbfTableEntry <> 0) then
          Inc(ThroughTables);
      end;

      // What is about to run, read from the process -- not from the analysis.
      FillChar(Code, SizeOf(Code), 0);
      var Got := Integer(Dbg.ReadCodeMemoryAt(Pc, @Code[0], 15));
      if (Got <= 0) or not ZydisDecodeDetail(Mode, Pc, Code, Got, Detail) then begin
        Problems.Add(Format('the instruction at $%x does not decode', [Rva]));
        Break;
      end;
      if (Flag and rbfBoundary <> 0) and (Analysis.InstructionLength(Rva) <> Detail.Length) then
        Problems.Add(Format('the instruction at $%x is %d bytes in the process and %d in the analysis',
          [Rva, Detail.Length, Analysis.InstructionLength(Rva)]));

      // Step INTO everything that stays in the analysed code, OVER every call
      // that leaves it (the RTL) or whose target is not known beforehand.
      var Kind := iskInto;
      if Detail.Kind = zikCallIndirect then
        Kind := iskOver
      else if (Detail.Kind = zikCallDirect) and
              ((Detail.BranchTarget < Base) or (FindAnalysis(Int64(Detail.BranchTarget - Base)) < 0)) then
        Kind := iskOver;
      PrevStepped := Kind = iskInto;
      PrevIndex   := Index;
      PrevRva     := Rva;
      PrevLen     := Detail.Length;
      PrevKind    := Detail.Kind;
      var Refusal: string;
      if not Session.StepInstruction(Kind, 0, Refusal) then begin
        Problems.Add(Format('the instruction step at $%x was refused: %s', [Rva, Refusal]));
        Break;
      end;
      Inc(Steps);
      PumpUntilStop(Session, STOP_TIMEOUT_MS);
    end;

    if not Session.HasExited then
      Problems.Add('the sample did not run to its end');

    // What the run covered, for whoever reads the numbers.
    var Summary := Format('%s (loaded at $%x, preferred base $%x): %d stops, %d single steps, %d stops inside analysed code at %d distinct addresses ' +
      'in %d of %d ranges; %d at a line record; %d transfers of control checked, %d of them through a jump table; ' +
      '%d stops on a handler entry (%s ); %d problems',
      [Bitness, Base, Binary.Image.ImageBase, Stops, Steps, Inside, Seen.Count, RoutinesSeen.Count, Analyses.Count, LineStarts, Transfers,
       ThroughTables, HandlerEntries, HandlerStops, Problems.Count]);
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'RoutineAnalysisDynamic_' + Bitness + '.txt', Summary);

    // The run must have been worth something.
    if RoutinesSeen.Count <> Analyses.Count then begin
      for var Item in Analyses do
        if not RoutinesSeen.ContainsKey(Item.StartRva) then
          Problems.Add(Format('the range [%x..%x) was never executed', [Item.StartRva, Item.EndRva]));
    end;
    if Seen.Count < 300 then
      Problems.Add(Format('only %d distinct addresses: the run covered too little', [Seen.Count]));
    if Transfers < 20 then
      Problems.Add(Format('only %d transfers of control checked', [Transfers]));
    // AsmTable has four entries; the first label follows the jmp directly, so
    // arriving there is not told apart from falling through.
    if ThroughTables < 3 then
      Problems.Add(Format('only %d arrivals through a jump table: AsmTable alone has three', [ThroughTables]));
    // x64: the funclet of the finally an exception runs through, the `on`
    // block, the bare except block. x86 has the stubs and continuations too.
    if HandlerEntries < 3 then
      Problems.Add(Format('only %d stops on a handler entry: the exception paths were not executed', [HandlerEntries]));
    if not ReachedTheEnd then
      Problems.Add('the last statement of the sample was never reached');

    if Problems.Count > 0 then begin
      var Shown := Problems.Count;
      if Shown > MAX_PROBLEMS_SHOWN then
        Shown := MAX_PROBLEMS_SHOWN;
      Assert.Fail(Format('%s'#13#10'  %s', [Summary, string.Join(#13#10'  ', Copy(Problems.ToArray, 0, Shown))]));
    end;
  finally
    if Session <> nil then begin
      Session.Terminate;
      Session.Free;
    end;
    MarkerRvas.Free;
    RoutinesSeen.Free;
    Seen.Free;
    Problems.Free;
    Analyses.Free;
    Binary.Free;
  end;
end;

{ TRoutineAnalysisDynamicTests }

procedure TRoutineAnalysisDynamicTests.ResetDisassemblerLoadLatch;
begin
  ZydisResetForTests;
end;

procedure TRoutineAnalysisDynamicTests.X64_EveryAddressTheProcessorStoppedAt_IsABoundaryTheAnalysisFound;
begin
  RunDynamicOracle('Win64');
end;

procedure TRoutineAnalysisDynamicTests.Win32_EveryAddressTheProcessorStoppedAt_IsABoundaryTheAnalysisFound;
begin
  RunDynamicOracle('Win32');
end;

initialization
  TDUnitX.RegisterTestFixture(TRoutineAnalysisTests);
  TDUnitX.RegisterTestFixture(TRoutineAnalysisDynamicTests);

end.
