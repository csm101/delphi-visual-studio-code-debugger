program RoutineAnalysisSweep;

// Runs the routine analysis (DebuggerCore\RoutineAnalysis.pas) over a whole
// binary and prints what it found: how many line records are confirmed as
// instruction boundaries, how many are shown to be something else, how many
// stay unconfirmed and why; which routines were not analysed completely and
// why; the indirect jumps by kind; and the time it took. Static: the binary is
// read as a file through PeImageFile and never executed.
//
// It is also the analysis' own consistency check. While it tallies, it asserts
// for every analysed range that
//
//   * no two decoded instructions overlap: every boundary is followed by
//     exactly the interior bytes of an instruction whose length an independent
//     second decode reports, and no analysed range overlaps another;
//   * every confirmed record is a boundary, every record that is a boundary is
//     confirmed, and every "not code" record is on an interior byte, on a table
//     byte, or was not reached and holds a zero or an undecodable byte.
//
// A violated assertion is printed and the tool exits with code 1.
//
// The numbers are comparable with DevTools\LineSiteSurvey, the prototype this
// analysis was built from; the README entry lists where the two differ and why.
//
// Usage:
//   RoutineAnalysisSweep.exe <exe-or-bpl> [-all] [-out <dir>] [-maxlist N]
//                            [-routine <name>] [-without <rules>] [-decodebench]
//                            [-zydisdll <path>]
//
//   -all             analyse every routine of the code map, not only the ones
//                    that own a line record
//   -out <dir>       write detail listings there: the records that are not
//                    confirmed, the ranges not analysed completely, and (x64)
//                    the functions inside a routine range that are not funclets
//   -maxlist N       cap of each listing (default 20000 lines)
//   -routine <name>  also print the analysis of the routines with that name
//                    (the whole name or its last dotted part), byte by byte
//   -decodebench     also time the decoder alone over the instructions the
//                    analysis decoded
//   -without <rules> switch off sources of proven places, comma separated, to
//                    see what each one buys: noreturn, tables, finally (x86),
//                    stubs (x86), ehtables (x64)

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics,
  System.Generics.Collections, System.Generics.Defaults,
  DebugInfoTypes    in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader    in '..\DebuggerCore\TD32FileReader.pas',
  CodeMap           in '..\DebuggerCore\CodeMap.pas',
  Disassembler      in '..\DebuggerCore\Disassembler.pas',
  ZydisApi          in '..\DebuggerCore\ZydisApi.pas',
  PeImageFile       in '..\DebuggerCore\PeImageFile.pas',
  RoutineAnalysis   in '..\DebuggerCore\RoutineAnalysis.pas';

type
  TOptions = record
    BinaryPath:  string;
    OutDir:      string;
    RoutineName: string;
    ZydisDll:    string;
    MaxList:     Integer;
    AllRoutines: Boolean;
    DecodeBench: Boolean;
    Disabled:    TRoutineAnalysisRules;
  end;

  // The tallies of one group of analysed ranges.
  TGroup = record
    Ranges, Complete: Int64;
    IncompleteBy, IncompleteRecords: array[TRoutineIncompleteReason] of Int64;
    OnlyIndirectJump, OnlyIndirectJumpRecords: Int64;
    IncompleteRecordsTotal: Int64;
    Records: Int64;
    ByVerdict: array[TLineVerdict] of Int64;
    ByReason: array[TLineVerdictReason] of Int64;
    Instructions: Int64;
    RangeBytes, ProvenBytes, TableBytes: Int64;
    FallsOffEnd: Int64;
    ReturnAddressRecords, WindowRecords: Int64;
    BlockEnds: array[TLineBlockEnd] of Int64;
    Calls, IndirectCalls: Int64;
    Exits: array[TRoutineExitKind, TRoutineExitRole] of Int64;
    Handlers: array[TRoutineHandlerKind] of Int64;
    Stubs: array[TX86StubKind] of Int64;
    ClauseTables, Clauses: Int64;
    JumpTables, JumpTableEntries, IndexTables, TablesAfterJump: Int64;
    TableKinds: array[TRoutineTableKind] of Int64;
    SlotJumps, ImportSlotJumps, FinallyJumps, FinallyJumpsNoStub, UnexplainedJumps: Int64;
    PushedData: Int64;
    SecondaryFunctions: Int64;
  end;

  TRange = record
    StartRva, EndRva: Cardinal;
  end;

  TSweep = class
  private
    FOptions:   TOptions;
    FImage:     TPeImageFile;
    FMap:       TModuleCodeMap;
    FAnalyzer:  TRoutineAnalyzer;
    FMode:      TZydisMachineMode;
    FRoutines:  TGroup;
    FUnmapped:  TGroup;
    FStray:     TGroup;
    FRanges:    TList<TRange>;
    FViolations: TStringList;
    FNotConfirmed, FIncomplete, FSecondary: TStringList;
    FDropped:   array[0..2] of Int64;
    FAnalysisTicks, FCheckTicks: Int64;
    FBoundaries: TList<Cardinal>;
    function  LineText(LineIndex: Integer): string;
    function  RoutineLabel(const Analysis: TRoutineAnalysis): string;
    procedure Violation(const Text: string);
    procedure AddDetail(List: TStringList; Slot: Integer; const Text: string);
    procedure Check(const Analysis: TRoutineAnalysis);
    procedure Tally(var Group: TGroup; const Analysis: TRoutineAnalysis);
    procedure TallyStray(const Line: TRoutineLine);
    procedure Process(var Group: TGroup; const Analysis: TRoutineAnalysis);
    procedure CheckRangesDisjoint;
    procedure PrintGroup(const Title: string; const Group: TGroup);
    procedure PrintRoutine(const Analysis: TRoutineAnalysis);
    procedure SaveDetails;
  public
    constructor Create(const Options: TOptions);
    destructor Destroy; override;
    function Run: Integer;
  end;

function Pct(Part, Whole: Int64): string;
begin
  if Whole = 0 then
    Exit('   n/a');
  Result := Format('%6.2f%%', [Part * 100.0 / Whole]);
end;

function HexBytes(const Bytes: array of Byte; Count: Integer): string;
begin
  Result := '';
  for var I := 0 to Count - 1 do
    Result := Result + IntToHex(Bytes[I], 2) + ' ';
  Result := Result.TrimRight;
end;

{ TSweep }

constructor TSweep.Create(const Options: TOptions);
begin
  inherited Create;
  FOptions    := Options;
  FRanges     := TList<TRange>.Create;
  FBoundaries := TList<Cardinal>.Create;
  FViolations := TStringList.Create;
  FNotConfirmed := TStringList.Create;
  FIncomplete := TStringList.Create;
  FSecondary  := TStringList.Create;
end;

destructor TSweep.Destroy;
begin
  FSecondary.Free;
  FIncomplete.Free;
  FNotConfirmed.Free;
  FViolations.Free;
  FRanges.Free;
  FBoundaries.Free;
  FAnalyzer.Free;
  FMap.Free;
  FImage.Free;
  inherited;
end;

function TSweep.LineText(LineIndex: Integer): string;
begin
  var Line := FMap.Lines[LineIndex];
  Result := Format('%s:%d', [FMap.Files[Line.FileIndex].Name, Line.Line]);
end;

function TSweep.RoutineLabel(const Analysis: TRoutineAnalysis): string;
begin
  if Analysis.RoutineIndex >= 0 then
    Result := FMap.Routines[Analysis.RoutineIndex].Name
  else
    Result := '<.pdata function>';
  Result := Format('%s [%x..%x)', [Result, Analysis.StartRva, Analysis.EndRva]);
end;

procedure TSweep.Violation(const Text: string);
begin
  if FViolations.Count < 200 then
    FViolations.Add(Text);
end;

procedure TSweep.AddDetail(List: TStringList; Slot: Integer; const Text: string);
begin
  if FOptions.OutDir = '' then
    Exit;
  if List.Count >= FOptions.MaxList then
    Inc(FDropped[Slot])
  else
    List.Add(Text);
end;

procedure TSweep.Check(const Analysis: TRoutineAnalysis);
// The assertions of the header. The second decode goes through the public
// entry point with the bytes read again from the image, so it shares nothing
// with the analysis but the decoder itself.
var
  Code: array[0..15] of Byte;
  Detail: TZydisInstructionDetail;
begin
  var Len := Length(Analysis.Flags);
  var Ofs := 0;
  var Where := RoutineLabel(Analysis);
  while Ofs < Len do begin
    var Flag := Analysis.Flags[Ofs];
    if Flag and rbfBoundary = 0 then begin
      if Flag and rbfInterior <> 0 then
        Violation(Format('%s: interior byte at $%x belongs to no instruction', [Where, Analysis.StartRva + Cardinal(Ofs)]));
      Inc(Ofs);
      Continue;
    end;
    if Flag and (rbfInterior or rbfData) <> 0 then
      Violation(Format('%s: boundary at $%x is also interior or table', [Where, Analysis.StartRva + Cardinal(Ofs)]));
    var Rva := Analysis.StartRva + Cardinal(Ofs);
    var FlagLen := Analysis.InstructionLength(Rva);
    if FOptions.DecodeBench then
      FBoundaries.Add(Rva);
    FillChar(Code, SizeOf(Code), 0);
    var Got := FImage.Read(FImage.ImageBase + Rva, @Code[0], 15);
    if (Got <= 0) or not ZydisDecodeDetail(FMode, FImage.ImageBase + Rva, Code, Got, Detail) then
      Violation(Format('%s: boundary at $%x does not decode a second time', [Where, Rva]))
    else if Detail.Length <> FlagLen then
      Violation(Format('%s: instruction at $%x is %d bytes by its flags and %d decoded again',
        [Where, Rva, FlagLen, Detail.Length]));
    for var K := 1 to FlagLen - 1 do
      if Analysis.Flags[Ofs + K] and (rbfBoundary or rbfData) <> 0 then
        Violation(Format('%s: instruction at $%x overlaps a boundary or a table at +%d', [Where, Rva, K]));
    Inc(Ofs, FlagLen);
  end;

  for var Line in Analysis.Lines do begin
    var Flag := Analysis.FlagsAt(Line.Rva);
    var IsBoundary := Flag and rbfBoundary <> 0;
    if (Line.Verdict = lvConfirmed) <> IsBoundary then
      Violation(Format('%s: record $%x (%s) verdict and boundary flag disagree', [Where, Line.Rva, LineText(Line.LineIndex)]));
    if Line.Verdict <> VerdictOfReason(Line.Reason) then
      Violation(Format('%s: record $%x has a reason of another verdict', [Where, Line.Rva]));
    if Flag and rbfLine = 0 then
      Violation(Format('%s: record $%x is not flagged as a line start', [Where, Line.Rva]));
    case Line.Reason of
      lvrInsideInstruction:
        if Flag and rbfInterior = 0 then
          Violation(Format('%s: record $%x said inside an instruction, flag disagrees', [Where, Line.Rva]));
      lvrInJumpTable, lvrInClauseTable:
        if Flag and rbfData = 0 then
          Violation(Format('%s: record $%x said in a table, flag disagrees', [Where, Line.Rva]));
    end;
    if (Line.Verdict = lvConfirmed) and
       ((Line.BlockEndRva < Line.Rva) or (Line.BlockEndRva > Analysis.EndRva) or (Line.BlockEnd = lbeNone)) then
      Violation(Format('%s: record $%x has no valid first block', [Where, Line.Rva]));
  end;

  var Range: TRange;
  Range.StartRva := Analysis.StartRva;
  Range.EndRva   := Analysis.EndRva;
  if Range.EndRva > Range.StartRva then
    FRanges.Add(Range);
end;

procedure TSweep.Tally(var Group: TGroup; const Analysis: TRoutineAnalysis);
var
  Code: array[0..15] of Byte;
  Detail: TZydisInstructionDetail;
begin
  Inc(Group.Ranges);
  var RecordCount := Length(Analysis.Lines);
  if Analysis.Complete then
    Inc(Group.Complete)
  else begin
    Inc(Group.IncompleteRecordsTotal, RecordCount);
    for var Why := Low(TRoutineIncompleteReason) to High(TRoutineIncompleteReason) do
      if Why in Analysis.Incomplete then begin
        Inc(Group.IncompleteBy[Why]);
        Inc(Group.IncompleteRecords[Why], RecordCount);
      end;
    if Analysis.Incomplete = [rirIndirectJump] then begin
      Inc(Group.OnlyIndirectJump);
      Inc(Group.OnlyIndirectJumpRecords, RecordCount);
    end;
    var Reasons := '';
    for var Why := Low(TRoutineIncompleteReason) to High(TRoutineIncompleteReason) do
      if Why in Analysis.Incomplete then
        Reasons := Reasons + IncompleteReasonText(Why) + '; ';
    AddDetail(FIncomplete, 1, Format('%s  first break at $%x  records=%d  %s',
      [RoutineLabel(Analysis), Analysis.IncompleteAtRva, RecordCount, Reasons]));
  end;
  if Analysis.FallsOffEnd then
    Inc(Group.FallsOffEnd);
  Inc(Group.Instructions, Analysis.InstructionCount);
  Inc(Group.RangeBytes, Int64(Analysis.EndRva) - Analysis.StartRva);
  Inc(Group.PushedData, Analysis.PushedDataCount);
  for var Flag in Analysis.Flags do
    if Flag and (rbfBoundary or rbfInterior) <> 0 then
      Inc(Group.ProvenBytes)
    else if Flag and rbfData <> 0 then
      Inc(Group.TableBytes);

  for var Line in Analysis.Lines do begin
    Inc(Group.Records);
    Inc(Group.ByVerdict[Line.Verdict]);
    Inc(Group.ByReason[Line.Reason]);
    Inc(Group.BlockEnds[Line.BlockEnd]);
    var Flag := Analysis.FlagsAt(Line.Rva);
    if Line.Verdict = lvConfirmed then begin
      if Flag and rbfReturnAddr <> 0 then
        Inc(Group.ReturnAddressRecords);
      if Flag and rbfWindow <> 0 then
        Inc(Group.WindowRecords);
    end
    else
      AddDetail(FNotConfirmed, 0, Format('$%.8x  %s  %s  routine=%s', [Line.Rva, LineText(Line.LineIndex),
        LineVerdictReasonText(Line.Reason), RoutineLabel(Analysis)]));
  end;

  Inc(Group.Calls, Length(Analysis.CallSites));
  for var Call in Analysis.CallSites do
    if Call.Indirect then
      Inc(Group.IndirectCalls);
  for var ExitItem in Analysis.Exits do
    Inc(Group.Exits[ExitItem.Kind, ExitItem.Role]);
  for var Handler in Analysis.HandlerEntries do begin
    Inc(Group.Handlers[Handler.Kind]);
    if Handler.Kind = rhkStub then
      Inc(Group.Stubs[Handler.Stub]);
    // x64: a function of its own inside the range that no scope table names as a
    // funclet (a finally target, a safecall handler): its ret is counted as an
    // exit.
    if Handler.Kind <> rhkFunction then
      Continue;
    var IsFunclet := False;
    for var Other in Analysis.HandlerEntries do
      if (Other.Kind in [rhkFinally, rhkSafecall]) and (Other.Rva = Handler.Rva) then
        IsFunclet := True;
    if not IsFunclet then begin
      Inc(Group.SecondaryFunctions);
      AddDetail(FSecondary, 2, Format('$%.8x  %s', [Handler.Rva, RoutineLabel(Analysis)]));
    end;
  end;
  for var Clause in Analysis.ClauseTables do begin
    Inc(Group.ClauseTables);
    Inc(Group.Clauses, Clause.Count);
  end;
  for var Table in Analysis.JumpTables do begin
    Inc(Group.JumpTables);
    Inc(Group.JumpTableEntries, Table.EntryCount);
    Inc(Group.TableKinds[Table.Kind]);
    if Table.IndexTableSize > 0 then
      Inc(Group.IndexTables);
    if Table.DirectlyAfterJump then
      Inc(Group.TablesAfterJump);
  end;

  // Indirect jumps by kind. The table ones are counted above.
  for var Ofs := 0 to High(Analysis.Flags) do begin
    if Analysis.Flags[Ofs] and rbfBoundary = 0 then
      Continue;
    var Rva := Analysis.StartRva + Cardinal(Ofs);
    case TRoutineInsnKind(Analysis.Flags[Ofs] shr rbfKindShift) of
      rikJumpIndirect:
        Inc(Group.UnexplainedJumps);
      rikJumpFinally: begin
        Inc(Group.FinallyJumps);
        if Analysis.FlagsAt(Rva + Cardinal(Analysis.InstructionLength(Rva))) and rbfStub = 0 then
          Inc(Group.FinallyJumpsNoStub);
      end;
      rikJumpSlot: begin
        Inc(Group.SlotJumps);
        // Whether the slot is an import: read from the jump itself.
        FillChar(Code, SizeOf(Code), 0);
        var Got := FImage.Read(FImage.ImageBase + Rva, @Code[0], 15);
        if (Got > 0) and ZydisDecodeDetail(FMode, FImage.ImageBase + Rva, Code, Got, Detail) then begin
          var Slot: Int64;
          if Detail.IsRipRelative then
            Slot := Int64(Detail.MemoryTarget - FImage.ImageBase)
          else
            Slot := Int64(UInt64(Detail.DispValue and $FFFFFFFF)) - Int64(FImage.ImageBase);
          if FAnalyzer.ImportNameOfSlot(Slot) <> '' then
            Inc(Group.ImportSlotJumps);
        end;
      end;
    end;
  end;
end;

procedure TSweep.TallyStray(const Line: TRoutineLine);
begin
  Inc(FStray.Records);
  Inc(FStray.ByVerdict[Line.Verdict]);
  Inc(FStray.ByReason[Line.Reason]);
  AddDetail(FNotConfirmed, 0, Format('$%.8x  %s  %s  routine=<none>', [Line.Rva, LineText(Line.LineIndex),
    LineVerdictReasonText(Line.Reason)]));
end;

procedure TSweep.Process(var Group: TGroup; const Analysis: TRoutineAnalysis);
begin
  var Clock := TStopwatch.StartNew;
  Check(Analysis);
  Tally(Group, Analysis);
  Inc(FCheckTicks, Clock.ElapsedTicks);
end;

procedure TSweep.CheckRangesDisjoint;
begin
  FRanges.Sort(TComparer<TRange>.Construct(
    function(const A, B: TRange): Integer
    begin
      if A.StartRva < B.StartRva then
        Exit(-1);
      if A.StartRva > B.StartRva then
        Exit(1);
      Result := 0;
    end));
  for var I := 1 to FRanges.Count - 1 do
    if FRanges[I].StartRva < FRanges[I - 1].EndRva then
      Violation(Format('analysed ranges overlap: [%x..%x) and [%x..%x)', [FRanges[I - 1].StartRva,
        FRanges[I - 1].EndRva, FRanges[I].StartRva, FRanges[I].EndRva]));
end;

procedure TSweep.PrintGroup(const Title: string; const Group: TGroup);
const
  VERDICT_NAME: array[TLineVerdict] of string = ('CONFIRMED as an instruction boundary',
    'NOT CODE (shown to be something else)', 'UNCONFIRMED (no proof either way)');
  EXIT_KIND: array[TRoutineExitKind] of string = ('ret', 'direct jmp out', 'conditional jmp out',
    'indirect jmp through a fixed slot', 'indirect jmp, unexplained');
  HANDLER_KIND: array[TRoutineHandlerKind] of string = ('x64 .pdata function inside the range (funclet)',
    'x64 finally target', 'x64 bare except block', 'x64 safecall handler funclet', 'clause block (on ... do)',
    'x86 handler stub', 'x86 code at stub + 5', 'x86 finally continuation');
  STUB_KIND: array[TX86StubKind] of string = ('', 'HandleFinally', 'HandleAnyException', 'HandleOnException',
    'HandleAutoException', '(target not named by the code map)');
  TABLE_KIND: array[TRoutineTableKind] of string = ('abs32', 'abs64', 'rel32');
  BLOCK_END: array[TLineBlockEnd] of string = ('', 'a direct call', 'an indirect call', 'a jump', 'a ret',
    'int3 / int n / hlt / ud2', 'an address a branch can reach', 'the next line record',
    'bytes that are not proven instructions', 'the routine end');
begin
  if (Group.Ranges = 0) and (Group.Records = 0) then
    Exit;
  Writeln;
  Writeln('--- ', Title, ' ---');
  if Group.Ranges > 0 then begin
    Writeln(Format('  ranges analysed %d, instructions decoded %d, ranges where a proven path runs past the end %d',
      [Group.Ranges, Group.Instructions, Group.FallsOffEnd]));
    var Unreached := Group.RangeBytes - Group.ProvenBytes - Group.TableBytes;
    Writeln(Format('  bytes in the ranges %d: proven instructions %d (%s), recognised tables %d, never reached %d (%s)',
      [Group.RangeBytes, Group.ProvenBytes, Pct(Group.ProvenBytes, Group.RangeBytes).Trim, Group.TableBytes,
       Unreached, Pct(Unreached, Group.RangeBytes).Trim]));
    Writeln(Format('  ranges NOT analysed completely: %d (%s), holding %d records', [Group.Ranges - Group.Complete,
      Pct(Group.Ranges - Group.Complete, Group.Ranges).Trim, Group.IncompleteRecordsTotal]));
    for var Why := Low(TRoutineIncompleteReason) to High(TRoutineIncompleteReason) do
      if Group.IncompleteBy[Why] > 0 then
        Writeln(Format('    %-58s %8d ranges %9d records', [IncompleteReasonText(Why), Group.IncompleteBy[Why],
          Group.IncompleteRecords[Why]]));
    if Group.OnlyIndirectJump > 0 then
      Writeln(Format('    (incomplete ONLY because of an unexplained indirect jump: %d ranges, %d records)',
        [Group.OnlyIndirectJump, Group.OnlyIndirectJumpRecords]));
  end;

  Writeln(Format('  line records %d', [Group.Records]));
  for var Verdict := Low(TLineVerdict) to High(TLineVerdict) do begin
    Writeln(Format('    %-40s %9d  %s', [VERDICT_NAME[Verdict], Group.ByVerdict[Verdict],
      Pct(Group.ByVerdict[Verdict], Group.Records)]));
    if Verdict = lvConfirmed then
      Continue;
    for var Reason := Low(TLineVerdictReason) to High(TLineVerdictReason) do
      if (VerdictOfReason(Reason) = Verdict) and (Group.ByReason[Reason] > 0) then
        Writeln(Format('      %-70s %8d', [LineVerdictReasonText(Reason), Group.ByReason[Reason]]));
  end;
  if Group.Ranges = 0 then
    Exit;

  Writeln(Format('  confirmed records that are a return address: %d (%s); inside an x64 unwinder window: %d (%s)',
    [Group.ReturnAddressRecords, Pct(Group.ReturnAddressRecords, Group.Records).Trim, Group.WindowRecords,
     Pct(Group.WindowRecords, Group.Records).Trim]));
  Writeln('  what ends the first straight-line block of a confirmed record:');
  for var Kind := Succ(Low(TLineBlockEnd)) to High(TLineBlockEnd) do
    if Group.BlockEnds[Kind] > 0 then
      Writeln(Format('    %-42s %9d  %s', [BLOCK_END[Kind], Group.BlockEnds[Kind],
        Pct(Group.BlockEnds[Kind], Group.ByVerdict[lvConfirmed])]));

  Writeln(Format('  call sites %d (indirect %d)', [Group.Calls, Group.IndirectCalls]));
  var RoutineExits: Int64 := 0;
  for var Kind := Low(TRoutineExitKind) to High(TRoutineExitKind) do
    Inc(RoutineExits, Group.Exits[Kind, rerRoutineExit]);
  Writeln(Format('  routine exits %d:', [RoutineExits]));
  for var Kind := Low(TRoutineExitKind) to High(TRoutineExitKind) do
    if Group.Exits[Kind, rerRoutineExit] > 0 then
      Writeln(Format('    %-42s %9d', [EXIT_KIND[Kind], Group.Exits[Kind, rerRoutineExit]]));
  Writeln(Format('  not exits of the routine: x86 finally-block exit %d (ret %d, pop+jmp %d), x86 handler stub %d, ' +
    'x64 ret/jmp in a funclet %d',
    [Group.Exits[rekReturn, rerFinallyExit] + Group.Exits[rekJumpIndirect, rerFinallyExit],
     Group.Exits[rekReturn, rerFinallyExit], Group.Exits[rekJumpIndirect, rerFinallyExit],
     Group.Exits[rekJump, rerHandlerStub],
     Group.Exits[rekReturn, rerFuncletReturn] + Group.Exits[rekJump, rerFuncletReturn] +
     Group.Exits[rekJumpConditional, rerFuncletReturn] + Group.Exits[rekJumpSlot, rerFuncletReturn] +
     Group.Exits[rekJumpIndirect, rerFuncletReturn]]));

  Writeln('  indirect jumps (FF /4) reached by the proven decode:');
  Writeln(Format('    total %d: through a fixed slot %d (an import slot %d, another slot %d), through a recognised table %d ' +
    '(%d entries, %d with a byte index table, %d directly after the jmp), x86 finally exit %d ' +
    '(%d of them with no stub found behind), unexplained %d',
    [Group.SlotJumps + Group.JumpTables + Group.FinallyJumps + Group.UnexplainedJumps, Group.SlotJumps,
     Group.ImportSlotJumps, Group.SlotJumps - Group.ImportSlotJumps, Group.JumpTables, Group.JumpTableEntries,
     Group.IndexTables, Group.TablesAfterJump, Group.FinallyJumps, Group.FinallyJumpsNoStub,
     Group.UnexplainedJumps]));
  for var Kind := Low(TRoutineTableKind) to High(TRoutineTableKind) do
    if Group.TableKinds[Kind] > 0 then
      Writeln(Format('    tables of %s entries %d', [TABLE_KIND[Kind], Group.TableKinds[Kind]]));

  Writeln('  exception-handler entries:');
  for var Kind := Low(TRoutineHandlerKind) to High(TRoutineHandlerKind) do
    if Group.Handlers[Kind] > 0 then
      Writeln(Format('    %-48s %9d', [HANDLER_KIND[Kind], Group.Handlers[Kind]]));
  for var Kind := Succ(Low(TX86StubKind)) to High(TX86StubKind) do
    if Group.Stubs[Kind] > 0 then
      Writeln(Format('      stub to %-40s %9d', [STUB_KIND[Kind], Group.Stubs[Kind]]));
  Writeln(Format('    clause tables inside the ranges %d (%d clauses)', [Group.ClauseTables, Group.Clauses]));
  if Group.SecondaryFunctions > 0 then
    Writeln(Format('    x64 .pdata functions inside a range that are NOT funclets (functions of their own) %d',
      [Group.SecondaryFunctions]));
  if not FAnalyzer.Is64 then
    Writeln(Format('  x86 pushed addresses of the routine that are neither a stub nor a continuation (data) %d',
      [Group.PushedData]));
end;

procedure TSweep.PrintRoutine(const Analysis: TRoutineAnalysis);
const
  KIND_NAME: array[TRoutineInsnKind] of string = ('', 'call', 'call-indirect', 'jmp', 'jcc', 'jmp-indirect?',
    'ret', 'int3', 'trap', 'jmp-table', 'jmp-slot', 'jmp-far', 'jmp-finally');
  HANDLER_KIND_SHORT: array[TRoutineHandlerKind] of string = ('.pdata function', 'finally target',
    'except block', 'safecall handler funclet', 'clause block', 'x86 stub', 'x86 stub + 5', 'x86 finally continuation');
  EXIT_ROLE: array[TRoutineExitRole] of string = ('exit of the routine', 'x86 end of a finally block',
    'x64 return of a funclet', 'x86 handler stub');
var
  Code: array[0..15] of Byte;
  Detail: TZydisInstructionDetail;
begin
  Writeln;
  Writeln(Format('=== %s  complete=%s  instructions=%d ===', [RoutineLabel(Analysis),
    BoolToStr(Analysis.Complete, True), Analysis.InstructionCount]));
  for var Why := Low(TRoutineIncompleteReason) to High(TRoutineIncompleteReason) do
    if Why in Analysis.Incomplete then
      Writeln(Format('  incomplete: %s (first break at $%x)', [IncompleteReasonText(Why), Analysis.IncompleteAtRva]));
  var Ofs := 0;
  while Ofs < Length(Analysis.Flags) do begin
    var Flag := Analysis.Flags[Ofs];
    var Rva := Analysis.StartRva + Cardinal(Ofs);
    var Step := 1;
    var Text := '';
    FillChar(Code, SizeOf(Code), 0);
    var Got := FImage.Read(FImage.ImageBase + Rva, @Code[0], 15);
    if Flag and rbfBoundary <> 0 then begin
      Step := Analysis.InstructionLength(Rva);
      var Insn: string;
      if (Got > 0) and ZydisDecodeDetail(FMode, FImage.ImageBase + Rva, Code, Got, Detail, Insn) then
        Text := Insn;
      Text := Format('%-24s %s', [HexBytes(Code, Step), Text]);
      var Kind := KIND_NAME[Analysis.KindAt(Rva)];
      if Kind <> '' then
        Text := Text + '   <' + Kind + '>';
    end
    else if Flag and rbfJumpTable <> 0 then
      Text := Format('%-24s (jump table)', [HexBytes(Code, 1)])
    else if Flag and rbfClauseTable <> 0 then
      Text := Format('%-24s (clause table)', [HexBytes(Code, 1)])
    else
      Text := Format('%-24s (not reached)', [HexBytes(Code, 1)]);
    var Marks := '';
    if Flag and rbfTarget <> 0 then Marks := Marks + ' target';
    if Flag and rbfAddressRef <> 0 then Marks := Marks + ' addr-ref';
    if Flag and rbfTableEntry <> 0 then Marks := Marks + ' table-entry';
    if Flag and rbfHandlerEntry <> 0 then Marks := Marks + ' handler';
    if Flag and rbfStub <> 0 then Marks := Marks + ' stub';
    if Flag and rbfReturnAddr <> 0 then Marks := Marks + ' return-addr';
    if Flag and rbfWindow <> 0 then Marks := Marks + ' window';
    if Flag and rbfLine <> 0 then begin
      var Index := Analysis.FindLine(Rva);
      Marks := Marks + Format(' LINE %s [%s; block to $%x]', [LineText(Analysis.Lines[Index].LineIndex),
        LineVerdictReasonText(Analysis.Lines[Index].Reason), Analysis.Lines[Index].BlockEndRva]);
    end;
    Writeln(Format('  $%.8x  %s%s', [Rva, Text, Marks]));
    Inc(Ofs, Step);
  end;
  for var Call in Analysis.CallSites do
    Writeln(Format('  call $%x -> return $%x, window to $%x', [Call.CallRva, Call.ReturnRva, Call.WindowEndRva]));
  for var Table in Analysis.JumpTables do
    Writeln(Format('  jump table at $%x, %d entries, jmp at $%x, byte index table $%x+%d', [Table.TableRva,
      Table.EntryCount, Table.JumpRva, Table.IndexTableRva, Table.IndexTableSize]));
  for var Handler in Analysis.HandlerEntries do
    Writeln(Format('  handler entry $%x: %s', [Handler.Rva, HANDLER_KIND_SHORT[Handler.Kind]]));
  for var ExitItem in Analysis.Exits do
    Writeln(Format('  exit $%x: %s', [ExitItem.Rva, EXIT_ROLE[ExitItem.Role]]));
end;

procedure TSweep.SaveDetails;

  procedure Save(List: TStringList; Slot: Integer; const Suffix, Header: string);
  begin
    List.Insert(0, Header);
    if FDropped[Slot] > 0 then
      List.Add(Format('... %d more entries not listed (raise -maxlist)', [FDropped[Slot]]));
    var Name := ChangeFileExt(ExtractFileName(FOptions.BinaryPath), '');
    if FAnalyzer.Is64 then
      Name := Name + '.x64'
    else
      Name := Name + '.x86';
    List.SaveToFile(TPath.Combine(FOptions.OutDir, Name + Suffix), TEncoding.UTF8);
  end;

begin
  if FOptions.OutDir = '' then
    Exit;
  ForceDirectories(FOptions.OutDir);
  Save(FNotConfirmed, 0, '.notconfirmed.txt', 'Line records that are not confirmed: ' + FOptions.BinaryPath);
  Save(FIncomplete, 1, '.incomplete.txt', 'Ranges not analysed completely: ' + FOptions.BinaryPath);
  Save(FSecondary, 2, '.secondary.txt',
    'x64 .pdata functions inside a routine range that are not funclets: ' + FOptions.BinaryPath);
  Writeln;
  Writeln('detail listings in ', FOptions.OutDir);
end;

function TSweep.Run: Integer;

  function Matches(const RoutineName: string): Boolean;
  begin
    if FOptions.RoutineName = '' then
      Exit(False);
    if SameText(RoutineName, FOptions.RoutineName) then
      Exit(True);
    Result := RoutineName.EndsWith('.' + FOptions.RoutineName, True);
  end;

begin
  var Total := TStopwatch.StartNew;
  FImage := TPeImageFile.Create(FOptions.BinaryPath);
  var Mode := dmmLegacy32;
  FMode := zmmLegacy32;
  if FImage.Is64 then begin
    Mode := dmmLong64;
    FMode := zmmLong64;
  end;

  var Reader := TTD32FileReader.Create;
  var Holder: IInterface := Reader;
  var Clock := TStopwatch.StartNew;
  Reader.LoadFromFile(FOptions.BinaryPath);
  if not Reader.Loaded then
    raise Exception.Create('no TD32 debug information in ' + FOptions.BinaryPath);
  var LoadMs := Clock.Elapsed.TotalMilliseconds;
  FMap := TModuleCodeMap.Build(ExtractFileName(FOptions.BinaryPath), Reader, Reader, 0, FImage.SizeOfImage);
  Holder := nil;

  Clock := TStopwatch.StartNew;
  var Input := Default(TRoutineAnalysisInput);
  Input.Mode         := Mode;
  Input.Reader       := FImage.Read;
  Input.ImageBase    := FImage.ImageBase;
  Input.CodeMap      := FMap;
  Input.ZydisDllPath := FOptions.ZydisDll;
  Input.DisabledRules := FOptions.Disabled;
  FAnalyzer := TRoutineAnalyzer.Create(Input);
  var PrepareMs := Clock.Elapsed.TotalMilliseconds;

  Writeln('=== RoutineAnalysisSweep: ', FOptions.BinaryPath, ' ===');
  var Bitness := 'x86 (dcc32)';
  if FImage.Is64 then
    Bitness := 'x64 (dcc64)';
  Writeln(Format('%s, image base $%x, image size $%x, .pdata entries %d', [Bitness, FImage.ImageBase,
    FImage.SizeOfImage, FAnalyzer.PdataCount]));
  Writeln(FAnalyzer.StatusText);
  if FOptions.Disabled <> [] then
    Writeln('*** RULES SWITCHED OFF (-without): the numbers below show what the analysis loses without them ***');
  if not FAnalyzer.Available then begin
    Writeln('The decoder is unavailable: nothing can be analysed.');
    Exit(2);
  end;

  var Analysed := 0;
  var Skipped := 0;
  for var I := 0 to High(FMap.Routines) do begin
    if (not FOptions.AllRoutines) and (FMap.Routines[I].LineCount = 0) then begin
      Inc(Skipped);
      Continue;
    end;
    Clock := TStopwatch.StartNew;
    var Analysis := FAnalyzer.Analyze(I);
    Inc(FAnalysisTicks, Clock.ElapsedTicks);
    Process(FRoutines, Analysis);
    Inc(Analysed);
    if Matches(FMap.Routines[I].Name) then
      PrintRoutine(Analysis);
  end;

  // x64: the functions only .pdata knows, which is where anonymous methods are.
  Clock := TStopwatch.StartNew;
  var Unmapped := FAnalyzer.UnmappedFunctions;
  Inc(FAnalysisTicks, Clock.ElapsedTicks);
  for var I := 0 to High(Unmapped) do begin
    Clock := TStopwatch.StartNew;
    var Analysis := FAnalyzer.AnalyzeUnmapped(I);
    Inc(FAnalysisTicks, Clock.ElapsedTicks);
    Process(FUnmapped, Analysis);
    if FOptions.RoutineName = '.pdata' then
      PrintRoutine(Analysis);
  end;

  // The records in neither: no routine range, no .pdata function.
  var Covered := 0;
  for var I := 0 to High(FMap.Lines) do begin
    var Line := FMap.Lines[I];
    if Line.RoutineIndex >= 0 then
      Continue;
    // Skip the ones an unmapped function holds (both lists ascend).
    while (Covered < Length(Unmapped)) and (Unmapped[Covered].EndRva <= Line.Rva) do
      Inc(Covered);
    if (Covered < Length(Unmapped)) and (Line.Rva >= Unmapped[Covered].StartRva) then
      Continue;
    Clock := TStopwatch.StartNew;
    var Stray := FAnalyzer.AnalyzeLine(I);
    Inc(FAnalysisTicks, Clock.ElapsedTicks);
    TallyStray(Stray);
  end;
  CheckRangesDisjoint;

  Writeln(Format('line records %d: in a routine of the code map %d, outside every routine %d (%s)',
    [Length(FMap.Lines), Length(FMap.Lines) - FMap.OutsideRoutineCount, FMap.OutsideRoutineCount,
     Pct(FMap.OutsideRoutineCount, Length(FMap.Lines)).Trim]));
  Writeln(Format('routines in the code map %d: analysed %d, skipped for having no line record %d',
    [Length(FMap.Routines), Analysed, Skipped]));

  PrintGroup('routines of the code map', FRoutines);
  PrintGroup('x64 functions known from .pdata only (anonymous-method bodies)', FUnmapped);
  PrintGroup('records in no routine and no .pdata function', FStray);

  var AllRecords := FRoutines.Records + FUnmapped.Records + FStray.Records;
  var Confirmed := FRoutines.ByVerdict[lvConfirmed] + FUnmapped.ByVerdict[lvConfirmed];
  var NotCode := FRoutines.ByVerdict[lvNotCode] + FUnmapped.ByVerdict[lvNotCode] + FStray.ByVerdict[lvNotCode];
  var Unconfirmed := FRoutines.ByVerdict[lvUnconfirmed] + FUnmapped.ByVerdict[lvUnconfirmed] +
    FStray.ByVerdict[lvUnconfirmed];
  Writeln;
  Writeln(Format('ALL RECORDS %d: confirmed %d (%s), not code %d (%s), unconfirmed %d (%s)', [AllRecords,
    Confirmed, Pct(Confirmed, AllRecords).Trim, NotCode, Pct(NotCode, AllRecords).Trim, Unconfirmed,
    Pct(Unconfirmed, AllRecords).Trim]));
  if AllRecords <> Length(FMap.Lines) then
    Violation(Format('%d records were given a verdict, the code map holds %d', [AllRecords, Length(FMap.Lines)]));

  SaveDetails;

  var Frequency: Double := TStopwatch.Frequency;
  Writeln;
  Writeln(Format('time: TD32 load %.0f ms, code map %.0f ms, analyzer set-up %.0f ms, ANALYSIS %.0f ms ' +
    '(%d instructions, %.0f ns each), checks and tallies %.0f ms, total %.1f s',
    [LoadMs, FMap.BuildMs, PrepareMs, FAnalysisTicks * 1000.0 / Frequency,
     FRoutines.Instructions + FUnmapped.Instructions,
     FAnalysisTicks * 1.0e9 / Frequency / (FRoutines.Instructions + FUnmapped.Instructions + 1),
     FCheckTicks * 1000.0 / Frequency, Total.Elapsed.TotalSeconds]));

  if FOptions.DecodeBench and (FBoundaries.Count > 0) then begin
    // The decoder alone, over the very instructions the analysis decoded: what
    // part of the analysis time is Zydis and what part is the analysis.
    var Code: array[0..15] of Byte;
    var Detail: TZydisInstructionDetail;
    FillChar(Code, SizeOf(Code), 0);
    Clock := TStopwatch.StartNew;
    for var Rva in FBoundaries do begin
      var Got := FImage.Read(FImage.ImageBase + Rva, @Code[0], 15);
      ZydisDecodeDetail(FMode, FImage.ImageBase + Rva, Code, Got, Detail);
    end;
    var DecodeNs := Clock.Elapsed.TotalMilliseconds * 1.0e6 / FBoundaries.Count;
    Clock := TStopwatch.StartNew;
    for var Rva in FBoundaries do
      FImage.Read(FImage.ImageBase + Rva, @Code[0], 15);
    var ReadNs := Clock.Elapsed.TotalMilliseconds * 1.0e6 / FBoundaries.Count;
    Writeln(Format('decoder alone: %.0f ns per instruction (reading the bytes from the file image: %.0f ns of it)',
      [DecodeNs, ReadNs]));
  end;

  Writeln;
  if FViolations.Count = 0 then begin
    Writeln('assertions: no two decoded instructions overlap, every confirmed record is a boundary -- OK');
    Exit(0);
  end;
  Writeln(Format('ASSERTIONS VIOLATED (%d shown):', [FViolations.Count]));
  for var Line in FViolations do
    Writeln('  ', Line);
  Result := 1;
end;

function ParseOptions(out Options: TOptions): Boolean;
begin
  Options := Default(TOptions);
  Options.MaxList := 20000;
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    var HasValue := I < ParamCount;
    if SameText(Arg, '-all') then
      Options.AllRoutines := True
    else if SameText(Arg, '-decodebench') then
      Options.DecodeBench := True
    else if SameText(Arg, '-out') and HasValue then begin
      Options.OutDir := ParamStr(I + 1);
      Inc(I);
    end else if SameText(Arg, '-maxlist') and HasValue then begin
      Options.MaxList := StrToIntDef(ParamStr(I + 1), Options.MaxList);
      Inc(I);
    end else if SameText(Arg, '-routine') and HasValue then begin
      Options.RoutineName := ParamStr(I + 1);
      Inc(I);
    end else if SameText(Arg, '-without') and HasValue then begin
      for var Name in ParamStr(I + 1).Split([',']) do
        if SameText(Name, 'noreturn') then
          Include(Options.Disabled, rarNoReturnCalls)
        else if SameText(Name, 'tables') then
          Include(Options.Disabled, rarJumpTables)
        else if SameText(Name, 'finally') then
          Include(Options.Disabled, rarFinallyExit)
        else if SameText(Name, 'stubs') then
          Include(Options.Disabled, rarHandlerStubs)
        else if SameText(Name, 'ehtables') then
          Include(Options.Disabled, rarExceptionTables)
        else
          Exit(False);
      Inc(I);
    end else if SameText(Arg, '-zydisdll') and HasValue then begin
      Options.ZydisDll := ParamStr(I + 1);
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

function DefaultZydisDll: string;
// Next to this executable, else the committed copy in the repository (every
// DevTools binary sits three directories below its root).
begin
  var ExeDir := ExtractFileDir(ParamStr(0));
  Result := TPath.Combine(ExeDir, 'Zydis.dll');
  if FileExists(Result) then
    Exit;
  Result := TPath.GetFullPath(TPath.Combine(ExeDir, '..\..\..\ThirdParty\Zydis\bin\x64\Zydis.dll'));
  if not FileExists(Result) then
    Result := '';
end;

begin
  // The numbers are quoted in documents: one spelling on every machine.
  FormatSettings.DecimalSeparator := '.';
  try
    var Options: TOptions;
    if not ParseOptions(Options) then begin
      Writeln('Usage: RoutineAnalysisSweep.exe <exe-or-bpl> [-all] [-out <dir>] [-maxlist N]');
      Writeln('                                [-routine <name>] [-without <rules>] [-decodebench]');
      Writeln('                                [-zydisdll <path>]');
      Halt(2);
    end;
    if not FileExists(Options.BinaryPath) then begin
      Writeln('File not found: ', Options.BinaryPath);
      Halt(2);
    end;
    if Options.ZydisDll = '' then
      Options.ZydisDll := DefaultZydisDll;
    var Sweep := TSweep.Create(Options);
    try
      ExitCode := Sweep.Run;
    finally
      Sweep.Free;
    end;
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(3);
    end;
  end;
end.
