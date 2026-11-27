program LineSiteSurvey;

// Static survey of the places a line probe could go, for one binary that
// carries TD32 debug information. It is the static half of "Increment 0" of
// docs/PROFILER_COVERAGE_PLAN.md and answers assumptions 1, 8, 9, 17 and 18
// with numbers. Nothing is executed: the binary is read as a file.
//
// What it does, per binary:
//
//   1. Reads the line table through TTD32FileReader (the engine's own reader)
//      and groups the records by the TD32 procedure that contains them.
//   2. Analyses every such routine the way the plan's "Routine analysis"
//      describes: a decode that FOLLOWS CONTROL FLOW from proven places and
//      never starts at a line record. The proven places are added in stages
//      so the report can say what each source buys:
//        stage 0  routine entry, direct branch targets, in-routine call targets
//        stage 1  x64: .pdata function starts, scope-table targets (finally
//                 funclets, bare except blocks), clause-table blocks
//        stage 2  entries of recognised jump tables
//        stage 3  x86: handler stubs named by `push imm32`, the code or the
//                 clause table after a stub, the continuation a try/finally
//                 pushes for the `pop REG; jmp REG` that ends its finally block
//      A record is CONFIRMED when such a decode arrives exactly at it.
//   3. From the result: which probe form each record and each routine exit
//      could take, by the rules of "The jump rule", "The call form" and "The
//      probe may sit anywhere in the line's first straight-line block".
//   4. Every indirect jump, with the code around it and the table after it.
//   5. -compare: whether two binaries name the same lines of a shared file.
//
// Simplifications (every one of them is repeated in the report header):
//
//   * Only routines that own at least one line record are decoded. Code with
//     no line record is never looked at, so its indirect jumps are not counted.
//   * A routine's end is where RvaToFunctionStart stops answering with its
//     start, found by bisection; a procedure range is assumed contiguous.
//   * Every call is assumed to return, except a call to System.@Halt0 (what
//     follows the one that ends a program block is data). `int3`, `int n`,
//     `hlt` and `ud2` end a decode path. A decode that runs into data behind
//     another call that never returns marks its routine incomplete, and the
//     instructions it decoded past that call are not withdrawn.
//   * An instruction is relocatable unless it is `int3` / `int n`. Relative
//     branches count as relocatable (they need re-encoding).
//   * An indirect jump that is not an import thunk (delay-load included), not a
//     recognised table and not the x86 finally exit (`pop REG; jmp REG` with a
//     handler stub directly behind it) makes its routine "incomplete", as the
//     plan says, even when its shape is plainly a tail jump through a register
//     or a method table.
//   * In-routine addresses used as immediates or displacements come from the
//     base relocations on x86 (exact) and from the absolute address Zydis
//     prints for a RIP-relative operand on x64.
//   * The x64 "window" of a return address is: an optional `add rsp, imm` or
//     `lea rsp, [..]`, any number of `pop r64`, and the one instruction after
//     them.
//   * Rule 5 of the jump rule (breakpoints, thread positions) is dynamic and
//     is not modelled. Flags liveness is not modelled.
//   * Exit sites: the span is the shortest run of straight-line instructions
//     that ends WITH the `ret` or the leaving jump and covers five bytes. A
//     conditional jump that leaves the routine is counted, not classified.
//   * The reader keeps one line per distinct RVA and identifies a source file
//     by its base name; the raw number of line pairs is not exposed.
//
// Usage:
//   LineSiteSurvey.exe <exe-or-bpl> [-out <dir>] [-src <dir>]... [-compare <other>]
//                      [-sample N] [-maxlist N] [-zydisdll <path>]
//
//   -out <dir>      write the detail listings there (stdout stays a summary)
//   -src <dir>      extra source root, searched recursively (repeatable); the
//                   binary's own directory and three parents are always tried
//   -compare <bin>  compare the line tables of the files both binaries share
//   -sample N       analyse every Nth routine only; counts are then SAMPLED
//   -maxlist N      cap of each detail listing (default 20000 lines)

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

uses
  System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, System.Math, System.Diagnostics,
  System.Generics.Collections, System.Generics.Defaults,
  Winapi.Windows,
  ZydisApi       in '..\DebuggerCore\ZydisApi.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas';

const
  // Per-byte flags over the executable sections.
  fInsn      = $0001;  // first byte of an instruction a proven decode reached
  fInterior  = $0002;  // any other byte of such an instruction
  fTarget    = $0004;  // reachable other than by falling through
  fLine      = $0008;  // a line record names this address
  fData      = $0010;  // inside a recognised table
  fWindow    = $0020;  // x64: instruction in the window of a return address
  fRetAddr   = $0040;  // the instruction that ends here is a call
  fAddrRef   = $0080;  // named by an immediate / displacement / relocation of its own routine
  fSeedPd    = $0100;  // x64: BeginAddress of a .pdata entry
  fSeedEH    = $0200;  // exception-handler entry (x64 scope/clause target, x86 stub and what follows it)
  fReloc     = $0400;  // a base relocation is applied here
  fTableEnt  = $0800;  // target of a recognised jump-table entry
  fStub      = $1000;  // x86: handler stub (`jmp` to an RTL handler)
  fExtTgt    = $2000;  // target of a direct jump or call from another routine
  fClauseTbl = $4000;  // fData that is a clause table
  fJmpTbl    = $8000;  // fData that is a jump table

  // What ends a straight-line block and what may not sit strictly inside a span.
  BARRIER_HARD = fTarget or fAddrRef or fSeedPd or fSeedEH or fTableEnt;

  // Instruction classes, kept in the low nibble of Cls[]; the length is the high nibble.
  icOther     = 0;
  icCall      = 1;   // direct
  icCallInd   = 2;
  icJmp       = 3;   // direct, unconditional
  icJcc       = 4;   // direct, conditional (Jcc, LOOPx, JxCXZ)
  icJmpInd    = 5;   // indirect, not (yet) explained
  icRet       = 6;
  icInt3      = 7;
  icTrap      = 8;   // int n, into, hlt, ud2
  icJmpTable  = 9;   // indirect, through a recognised table
  icJmpImport = 10;  // indirect, through an import slot
  icFar       = 11;  // far jump
  icJmpFinally = 12; // x86: `pop REG; jmp REG` that leaves a finally block

  IMAGE_FILE_MACHINE_I386  = $014C;
  IMAGE_FILE_MACHINE_AMD64 = $8664;

type
  TLits = array[0..5] of UInt64;

  TForm = (fmNone, fmStub, fmRetarget, fmJump, fmCallForm, fmCC);
  TSpanFail = (sfNone, sfLineStart, sfBranchTarget, sfCall, sfBranchBefore,
    sfNotRelocatable, sfUnproven, sfRoutineEdge);
  TUnconfReason = (urInsideInsn, urInTable, urAfterIndJmp, urAfterRetJmp,
    urAfterTrap, urAfterStop, urAfterTable, urNothingBefore);
  TIncompleteWhy = (iwUndecodable, iwConflict, iwCrossesEnd, iwIndJmp);
  TIncompleteSet = set of TIncompleteWhy;
  TTableKind = (tkAbs32, tkAbs64, tkRel32);

const
  FORM_NAME: array[TForm] of string = ('unconfirmed: no probe', 'x86 handler stub: never probed',
    'retargeted call', 'jump', 'call form', 'left to a $CC');
  FAIL_NAME: array[TSpanFail] of string = ('(none)', 'a line start within five bytes',
    'a branch target / handler entry / address reference within five bytes',
    'a call within five bytes', 'a branch directly before the exit',
    'int3 / int n in the span', 'bytes after it are not proven instructions',
    'the routine edge within five bytes');
  UNCONF_NAME: array[TUnconfReason] of string = (
    'inside an instruction the proven decode reached (decode overshot the record)',
    'inside a recognised table',
    'unreached: follows an indirect jump',
    'unreached: follows a ret / unconditional jmp, no known branch to it',
    'unreached: follows int3 / int n / hlt / far jump',
    'unreached: the decode before it stopped (undecodable byte or conflict)',
    'unreached: follows a recognised table',
    'unreached: nothing proven before it in the routine');
  A17_NAME: array[0..3] of string = ('finally target (funclet)', 'bare except target (block)',
    'clause block (on ... do)', 'clause table');
  INC_NAME: array[TIncompleteWhy] of string = ('a byte that does not decode',
    'two proven decodes disagree about instruction boundaries',
    'an instruction crosses the routine end',
    'an indirect jump that is not a recognised table');

{ ------------------------------------------------------------------ helpers }

function Pct(A, B: Int64): string;
begin
  if B = 0 then
    Result := '   n/a'
  else
    Result := Format('%6.2f%%', [A * 100.0 / B]);
end;

function HexBytes(P: PByte; N: Integer): string;
begin
  Result := '';
  if P = nil then
    Exit;
  for var I := 0 to N - 1 do
    Result := Result + IntToHex(P[I], 2) + ' ';
  Result := Result.TrimRight;
end;

function ParseHexLiterals(const Text: string; var Vals: TLits): Integer;
// Every `0x<hex>` literal of a Zydis instruction text.
begin
  Result := 0;
  var N := Length(Text);
  var I := 1;
  while I < N do begin
    if (Text[I] <> '0') or (Text[I + 1] <> 'x') then begin
      Inc(I);
      Continue;
    end;
    var V: UInt64 := 0;
    var J := I + 2;
    while J <= N do begin
      var C := Text[J];
      var D: Integer;
      if (C >= '0') and (C <= '9') then
        D := Ord(C) - Ord('0')
      else if (C >= 'A') and (C <= 'F') then
        D := Ord(C) - Ord('A') + 10
      else if (C >= 'a') and (C <= 'f') then
        D := Ord(C) - Ord('a') + 10
      else
        Break;
      V := (V shl 4) or UInt64(D);
      Inc(J);
    end;
    if Result <= High(Vals) then begin
      Vals[Result] := V;
      Inc(Result);
    end;
    I := J;
  end;
end;

{ ------------------------------------------------------------------ TDetail }

type
  // A detail listing with a cap, so a 500 MB binary cannot produce a 500 MB text.
  TDetail = class
  private
    FLines: TStringList;
    FCap: Integer;
    FDropped: Int64;
  public
    constructor Create(Cap: Integer);
    destructor Destroy; override;
    procedure Add(const S: string);
    procedure Save(const Path, Header: string);
  end;

constructor TDetail.Create(Cap: Integer);
begin
  inherited Create;
  FLines := TStringList.Create;
  FCap := Cap;
end;

destructor TDetail.Destroy;
begin
  FLines.Free;
  inherited;
end;

procedure TDetail.Add(const S: string);
begin
  if FLines.Count >= FCap then
    Inc(FDropped)
  else
    FLines.Add(S);
end;

procedure TDetail.Save(const Path, Header: string);
begin
  FLines.Insert(0, Header);
  if FDropped > 0 then
    FLines.Add(Format('... %d more entries not listed (raise -maxlist)', [FDropped]));
  FLines.SaveToFile(Path, TEncoding.UTF8);
end;

{ ----------------------------------------------------------------- TPEImage }

type
  TSection = record
    Name: string;
    VA, VSize, RawOfs, RawSize, Chars: Cardinal;
  end;

  // The PE file, mapped read-only. Self-contained like every DevTools PE reader.
  TPEImage = class
  private
    FFile, FMap: THandle;
    FBase: PByte;
    FSize: Int64;
    FLastSec: Integer;
  public
    Machine: Word;
    Is64: Boolean;
    ImageBase: UInt64;
    SizeOfImage: Cardinal;
    Sections: TArray<TSection>;
    DirRva, DirSize: array[0..15] of Cardinal;
    constructor Create(const Path: string);
    destructor Destroy; override;
    // Pointer to Size bytes at Rva, nil when they are not backed by raw data.
    function Ptr(Rva: Cardinal; Size: Integer): PByte;
    // Pointer at Rva plus how many raw bytes follow in its section.
    function PtrAvail(Rva: Cardinal; out Avail: Integer): PByte;
    function U32(Rva: Cardinal; out V: Cardinal): Boolean;
    function AnsiZ(Rva: Cardinal): string;
    function SectionNameOf(Rva: Cardinal): string;
  end;

constructor TPEImage.Create(const Path: string);
begin
  inherited Create;
  FFile := CreateFile(PChar(Path), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FFile = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  var SizeHigh: DWORD := 0;
  var SizeLow := GetFileSize(FFile, @SizeHigh);
  FSize := (Int64(SizeHigh) shl 32) or SizeLow;
  FMap := CreateFileMapping(FFile, nil, PAGE_READONLY, 0, 0, nil);
  if FMap = 0 then
    RaiseLastOSError;
  FBase := MapViewOfFile(FMap, FILE_MAP_READ, 0, 0, 0);
  if FBase = nil then
    RaiseLastOSError;

  var PEOfs := PCardinal(FBase + $3C)^;
  if (PEOfs + 24 > FSize) or (PCardinal(FBase + PEOfs)^ <> $00004550) then
    raise Exception.Create('not a PE image: ' + Path);
  Machine := PWord(FBase + PEOfs + 4)^;
  var NumSections := PWord(FBase + PEOfs + 6)^;
  var OptSize := PWord(FBase + PEOfs + 20)^;
  var Opt := FBase + PEOfs + 24;
  Is64 := PWord(Opt)^ = $20B;
  var DirBase: PByte;
  if Is64 then begin
    ImageBase := PUInt64(Opt + 24)^;
    DirBase := Opt + 112;
  end
  else begin
    ImageBase := PCardinal(Opt + 28)^;
    DirBase := Opt + 96;
  end;
  SizeOfImage := PCardinal(Opt + 56)^;
  var NumDirs := Min(Integer(PCardinal(DirBase - 4)^), 16);
  for var I := 0 to NumDirs - 1 do begin
    DirRva[I] := PCardinal(DirBase + I * 8)^;
    DirSize[I] := PCardinal(DirBase + I * 8 + 4)^;
  end;
  SetLength(Sections, NumSections);
  var Sec := Opt + OptSize;
  for var I := 0 to NumSections - 1 do begin
    var P := Sec + I * 40;
    var Raw: array[0..8] of AnsiChar;
    FillChar(Raw, SizeOf(Raw), 0);
    Move(P^, Raw, 8);
    Sections[I].Name := string(AnsiString(PAnsiChar(@Raw[0])));
    Sections[I].VSize := PCardinal(P + 8)^;
    Sections[I].VA := PCardinal(P + 12)^;
    Sections[I].RawSize := PCardinal(P + 16)^;
    Sections[I].RawOfs := PCardinal(P + 20)^;
    Sections[I].Chars := PCardinal(P + 36)^;
  end;
end;

destructor TPEImage.Destroy;
begin
  if FBase <> nil then
    UnmapViewOfFile(FBase);
  if FMap <> 0 then
    CloseHandle(FMap);
  if (FFile <> 0) and (FFile <> INVALID_HANDLE_VALUE) then
    CloseHandle(FFile);
  inherited;
end;

function TPEImage.PtrAvail(Rva: Cardinal; out Avail: Integer): PByte;

  function TrySection(Idx: Integer; out P: PByte; out A: Integer): Boolean;
  begin
    var S := Sections[Idx];
    if (Rva < S.VA) or (UInt64(Rva) >= UInt64(S.VA) + S.RawSize) then
      Exit(False);
    var Delta := Rva - S.VA;
    var Left: Int64 := Int64(S.RawSize) - Delta;
    if Int64(S.RawOfs) + Delta + Left > FSize then
      Left := FSize - S.RawOfs - Delta;
    if Left <= 0 then
      Exit(False);
    if Left > MaxInt then
      Left := MaxInt;
    P := FBase + S.RawOfs + Delta;
    A := Integer(Left);
    Result := True;
  end;

begin
  Avail := 0;
  if (FLastSec >= 0) and (FLastSec < Length(Sections)) and TrySection(FLastSec, Result, Avail) then
    Exit;
  for var I := 0 to High(Sections) do
    if TrySection(I, Result, Avail) then begin
      FLastSec := I;
      Exit;
    end;
  Result := nil;
end;

function TPEImage.Ptr(Rva: Cardinal; Size: Integer): PByte;
begin
  var Avail: Integer;
  Result := PtrAvail(Rva, Avail);
  if (Result <> nil) and (Avail < Size) then
    Result := nil;
end;

function TPEImage.U32(Rva: Cardinal; out V: Cardinal): Boolean;
begin
  var P := Ptr(Rva, 4);
  Result := P <> nil;
  if Result then
    V := PCardinal(P)^
  else
    V := 0;
end;

function TPEImage.AnsiZ(Rva: Cardinal): string;
begin
  Result := '';
  var Avail: Integer;
  var P := PtrAvail(Rva, Avail);
  if P = nil then
    Exit;
  var N := 0;
  while (N < Avail) and (N < 512) and (P[N] <> 0) do
    Inc(N);
  var A: AnsiString;
  SetString(A, PAnsiChar(P), N);
  Result := string(A);
end;

function TPEImage.SectionNameOf(Rva: Cardinal): string;
begin
  for var S in Sections do
    if (Rva >= S.VA) and (UInt64(Rva) < UInt64(S.VA) + Max(S.VSize, S.RawSize)) then
      Exit(S.Name);
  Result := '(none)';
end;

{ ------------------------------------------------------------------ TSurvey }

type
  // One analysed range: a TD32 procedure, or (x64) a .pdata function that no
  // TD32 procedure covers.
  TUnitCtx = record
    S, E: Cardinal;
    FirstRec, LastRec: Integer;
    Pseudo: Boolean;
    Why: TIncompleteSet;
    PdPrimary: Integer;
  end;

  TBucket = record
    Units, UnitsIncomplete: Int64;
    IncBy, IncRecsBy: array[TIncompleteWhy] of Int64;
    IncOnlyIndJmp, IncOnlyIndJmpRecs: Int64;
    Recs: Int64;
    Conf: array[0..3] of Int64;
    Unconf: array[TUnconfReason] of Int64;
    UnconfRunHeads: Int64;
    LenHist: array[0..3] of Int64;
    RetAddrRecs, WindowRecs, Int3Recs: Int64;
    FormStrict, FormRelaxed: array[TForm] of Int64;
    FormIncomplete: Int64;
    CCWhy: array[TSpanFail] of Int64;
    CCIndCall: Int64;
    Exits: Int64;
    ExitKind: array[0..2] of Int64;
    ExitStrict, ExitRelaxed: array[TForm] of Int64;
    ExitIncomplete: Int64;
    ExitCCWhy: array[TSpanFail] of Int64;
    FinallyRets, FuncletRets, Stubs, CondExits: Int64;
    Insns, FellOut: Int64;
    RangeBytes, ProvenBytes, DataBytes: Int64;
  end;
  PBucket = ^TBucket;

  TShape = class
    Count, Entries: Int64;
    Contexts: TDictionary<string, Integer>;
    Examples: TList<string>;
    constructor Create;
    destructor Destroy; override;
  end;

  TMultiLine = record
    Key: UInt64;      // file id shl 32 or line
    Count: Integer;
    Interleaved, FuncletCopy: Boolean;
    FirstRva: Cardinal;
  end;

  TKeyRva = record
    Key: UInt64;
    Rva: Cardinal;
    Ord: Integer;
  end;

  TSurvey = class
  private
    FPath: string;
    Img: TPEImage;
    Mode: TZydisMachineMode;
    Is64: Boolean;
    ImageBase: UInt64;
    CodeLo, CodeHi: Cardinal;
    Flags: TArray<Word>;
    Cls: TArray<Byte>;
    Recs: TArray<UInt64>;
    RecKey: TArray<UInt64>;
    RecUnit: TArray<Integer>;
    Units: TArray<TUnitCtx>;
    FileIds: TDictionary<string, Integer>;
    FileNames: TList<string>;
    FRegs: TDictionary<string, Boolean>;
    FImports: TDictionary<Cardinal, string>;
    FExports: TDictionary<Cardinal, Boolean>;
    HasRelocs: Boolean;
    RelocTotal, RelocInCode: Int64;
    // x64 unwind data
    PdBegin, PdEnd, PdUnw, PdHandler, PdData: TArray<Cardinal>;
    PdChained, PdProcStart, PdInsideProc, PdOutside, PdOutsideTarget: Int64;
    UnwSections, ClauseSections: TDictionary<string, Integer>;
    Handlers: TDictionary<Cardinal, Integer>;
    DelphiHandlers: TDictionary<Cardinal, Boolean>;
    ScopeTables, ScopeEntries, ScopeMalformed, ScopeOwnersNoProc: Int64;
    // [finally target, bare except target, clause block, clause table] x [own procedure, another, none]
    A17: array[0..3, 0..2] of Int64;
    // analysis state
    FWork: TStack<Cardinal>;
    FPendJmp, FPendPush: TList<Cardinal>;
    Bk: array[Boolean] of TBucket;
    Shapes: TDictionary<string, TShape>;
    ImportThunkJumps, TablesFound, TableEntries, IndexTables, FinallyJumps, FinallyJumpsNoStub: Int64;
    NoReturnCalls: Int64;
    FNoRet: TDictionary<Cardinal, Boolean>;
    FSrcIndexBuilt: Boolean;
    FSrcCacheName: string;
    FSrcCacheLines: TStringList;
    FSrcCacheOk: Boolean;
    StubKinds: TDictionary<string, Integer>;
    ClauseTables86, Clauses86, ClauseNameMismatch, PushedContinuations, PushedUnrecognised: Int64;
    UnexplainedPtrs: Int64;
    OrphanRecs, OrphanInPdata, OrphanExtTgt, OrphanExported, NotInCode, SplitRoutines, RoutinesSeen: Int64;
    OrphanKinds, UnconfByExt: TDictionary<string, Integer>;
    Multi: TList<TMultiLine>;
    LinesInRoutines, MultiLines, MultiExtra, MultiInterleaved, MultiFuncletCopy: Int64;
    MultiHist: array[0..3] of Int64;
    KeyCmp: IComparer<TKeyRva>;
    SrcIndex: TDictionary<string, string>;
    function F(Rva: Cardinal): Word; inline;
    procedure SetF(Rva: Cardinal; Bits: Word); inline;
    function InCode(Rva: Int64): Boolean; inline;
    function InsnLen(Rva: Cardinal): Integer; inline;
    function InsnCls(Rva: Cardinal): Byte; inline;
    procedure SetCls(Rva: Cardinal; C: Byte);
    function DecodeAt(Rva: Cardinal; out Len: Integer; out Text: string): Boolean;
    function Classify(P: PByte; Len: Integer; Rva: Cardinal; out Target: Int64): Byte;
    function BranchTargetOf(Rva: Cardinal): Int64;
    function CodeName(Rva: Cardinal): string;
    function NameOrSub(Rva: Cardinal): string;
    function LineOf(Rva: Cardinal): string;
    function NormText(const Text: string; S, E, After: Cardinal): string;
    function DisasmLine(Rva: Cardinal): string;
    function PrevInsn(P, Lo: Cardinal; out Q: Cardinal): Boolean;
    procedure ParseRelocs;
    procedure ParseImports;
    procedure ParseExports;
    procedure ParsePdata;
    procedure DecodeScopeTable(Idx: Integer);
    function FindPdata(Rva: Cardinal): Integer;
    procedure BuildUnits;
    function FindRoutineEnd(S: UInt64; LastInside: UInt64): Cardinal;
    procedure Seed(const U: TUnitCtx; Rva: Int64; Bits: Word);
    procedure Drain(var U: TUnitCtx);
    procedure NoteAddrRefs(const U: TUnitCtx; Pc: Cardinal; Len: Integer; C: Byte; P: PByte; const Text: string);
    function ReadTable(const U: TUnitCtx; Tbl: Cardinal; Kind: TTableKind; RelBase: Int64; Targets: TList<Cardinal>): Integer;
    procedure ResolveIndirectJump(var U: TUnitCtx; J: Cardinal);
    function LooksLikeClauseTable(const U: TUnitCtx; X: Cardinal; out Count: Cardinal): Boolean;
    function ProcessPushes(var U: TUnitCtx): Boolean;
    function CountConfirmed(const U: TUnitCtx): Int64;
    procedure ScanUnexplainedPointers(const U: TUnitCtx);
    procedure MarkWindows(const U: TUnitCtx);
    function SpanFrom(P, E: Cardinal; Relaxed: Boolean; out Why: TSpanFail): Boolean;
    procedure EvalLineSite(A, LineEnd, E: Cardinal; Relaxed: Boolean; out Form: TForm; out Why: TSpanFail; out IndCall: Boolean);
    function EvalExit(X, S: Cardinal; Relaxed: Boolean; out Why: TSpanFail): TForm;
    function UnconfReason(const U: TUnitCtx; A: Cardinal; out RunHead: Boolean; out Before: Cardinal): TUnconfReason;
    procedure AnalyseUnit(var U: TUnitCtx);
    procedure TallyUnit(var U: TUnitCtx);
    procedure TallyMultiLines(const U: TUnitCtx);
    procedure ClassifyOrphans;
    procedure BuildSourceIndex;
    procedure ClassifyMultiBySource;
    function SourceLine(const FileBase: string; Line: Integer; out Text: string): Integer;
    procedure ReportBucket(const Title: string; const B: TBucket);
  public
    Reader: TTD32FileReader;
    Sample: Integer;
    OutDir: string;
    SrcDirs: TArray<string>;
    MaxList: Integer;
    DetUnconf, DetOrphan, DetTable, DetMulti, DetIndJmp, DetIncomplete, DetPush: TDetail;
    constructor Create(const Path: string);
    destructor Destroy; override;
    procedure Run;
    function Tag: string;
  end;

constructor TShape.Create;
begin
  inherited Create;
  Contexts := TDictionary<string, Integer>.Create;
  Examples := TList<string>.Create;
end;

destructor TShape.Destroy;
begin
  Contexts.Free;
  Examples.Free;
  inherited;
end;

constructor TSurvey.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  MaxList := 20000;
  Sample := 1;
  FileIds := TDictionary<string, Integer>.Create;
  FileNames := TList<string>.Create;
  FRegs := TDictionary<string, Boolean>.Create;
  FImports := TDictionary<Cardinal, string>.Create;
  FExports := TDictionary<Cardinal, Boolean>.Create;
  UnwSections := TDictionary<string, Integer>.Create;
  ClauseSections := TDictionary<string, Integer>.Create;
  Handlers := TDictionary<Cardinal, Integer>.Create;
  DelphiHandlers := TDictionary<Cardinal, Boolean>.Create;
  FWork := TStack<Cardinal>.Create;
  FPendJmp := TList<Cardinal>.Create;
  FPendPush := TList<Cardinal>.Create;
  Shapes := TObjectDictionary<string, TShape>.Create([doOwnsValues]);
  StubKinds := TDictionary<string, Integer>.Create;
  OrphanKinds := TDictionary<string, Integer>.Create;
  UnconfByExt := TDictionary<string, Integer>.Create;
  Multi := TList<TMultiLine>.Create;
  SrcIndex := TDictionary<string, string>.Create;
  FNoRet := TDictionary<Cardinal, Boolean>.Create;
  FSrcCacheLines := TStringList.Create;
  KeyCmp := TComparer<TKeyRva>.Construct(
    function(const A, B: TKeyRva): Integer
    begin
      if A.Key < B.Key then
        Result := -1
      else if A.Key > B.Key then
        Result := 1
      else
        Result := A.Ord - B.Ord;
    end);
  // General-purpose register names, folded to one token when a shape is
  // normalised. The stack, frame and instruction pointers keep their names.
  for var R in ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15',
    'eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'r8d', 'r9d', 'r10d', 'r11d', 'r12d', 'r13d', 'r14d', 'r15d',
    'ax', 'bx', 'cx', 'dx', 'si', 'di', 'r8w', 'r9w', 'r10w', 'r11w', 'r12w', 'r13w', 'r14w', 'r15w',
    'al', 'bl', 'cl', 'dl', 'ah', 'bh', 'ch', 'dh', 'sil', 'dil', 'r8b', 'r9b', 'r10b', 'r11b', 'r12b',
    'r13b', 'r14b', 'r15b'] do
    FRegs.Add(R, True);
end;

destructor TSurvey.Destroy;
begin
  for var D in [DetUnconf, DetOrphan, DetTable, DetMulti, DetIndJmp, DetIncomplete, DetPush] do
    D.Free;
  FSrcCacheLines.Free;
  FNoRet.Free;
  SrcIndex.Free;
  Multi.Free;
  UnconfByExt.Free;
  OrphanKinds.Free;
  StubKinds.Free;
  Shapes.Free;
  FPendPush.Free;
  FPendJmp.Free;
  FWork.Free;
  DelphiHandlers.Free;
  Handlers.Free;
  ClauseSections.Free;
  UnwSections.Free;
  FExports.Free;
  FImports.Free;
  FRegs.Free;
  FileNames.Free;
  FileIds.Free;
  Reader.Free;
  Img.Free;
  inherited;
end;

function TSurvey.Tag: string;
begin
  Result := ChangeFileExt(ExtractFileName(FPath), '');
  if Is64 then
    Result := Result + '.x64'
  else
    Result := Result + '.x86';
end;

function TSurvey.F(Rva: Cardinal): Word;
begin
  Result := Flags[Rva - CodeLo];
end;

procedure TSurvey.SetF(Rva: Cardinal; Bits: Word);
begin
  Flags[Rva - CodeLo] := Flags[Rva - CodeLo] or Bits;
end;

function TSurvey.InCode(Rva: Int64): Boolean;
begin
  Result := (Rva >= CodeLo) and (Rva < CodeHi);
end;

function TSurvey.InsnLen(Rva: Cardinal): Integer;
begin
  Result := Cls[Rva - CodeLo] shr 4;
end;

function TSurvey.InsnCls(Rva: Cardinal): Byte;
begin
  Result := Cls[Rva - CodeLo] and $0F;
end;

procedure TSurvey.SetCls(Rva: Cardinal; C: Byte);
begin
  Cls[Rva - CodeLo] := (Cls[Rva - CodeLo] and $F0) or C;
end;

function TSurvey.DecodeAt(Rva: Cardinal; out Len: Integer; out Text: string): Boolean;
var
  Insn: TZydisInstruction;
begin
  Len := 0;
  Text := '';
  var Avail: Integer;
  var P := Img.PtrAvail(Rva, Avail);
  if P = nil then
    Exit(False);
  if Avail > 15 then
    Avail := 15;
  Result := ZydisDecodeOne(Mode, ImageBase + Rva, P^, Avail, Insn);
  if Result then begin
    Len := Insn.Length;
    Text := Insn.Text;
  end;
end;

function TSurvey.Classify(P: PByte; Len: Integer; Rva: Cardinal; out Target: Int64): Byte;
// Class of the instruction from its bytes; the length comes from Zydis. Target
// is the RVA a direct branch names, -1 otherwise.

  function Rel(Size: Integer): Int64;
  begin
    var R: Int64;
    case Size of
      1: R := ShortInt(P[Len - 1]);
      2: R := PSmallInt(P + Len - 2)^;
    else
      R := PInteger(P + Len - 4)^;
    end;
    Result := Int64(Rva) + Len + R;
    if not Is64 then
      Result := Result and $FFFFFFFF;
  end;

begin
  Target := -1;
  Result := icOther;
  var I := 0;
  while (I < Len) and (P[I] in [$F0, $F2, $F3, $2E, $36, $3E, $26, $64, $65, $66, $67]) do
    Inc(I);
  if Is64 and (I < Len) and ((P[I] and $F0) = $40) then
    Inc(I);
  if I >= Len then
    Exit;
  var Rest := Len - I - 1;
  case P[I] of
    $E8: begin
      Result := icCall;
      if Rest in [2, 4] then
        Target := Rel(Rest);
    end;
    $E9: begin
      Result := icJmp;
      if Rest in [2, 4] then
        Target := Rel(Rest);
    end;
    $EB: begin
      Result := icJmp;
      Target := Rel(1);
    end;
    $70..$7F, $E0..$E3: begin
      Result := icJcc;
      Target := Rel(1);
    end;
    $0F:
      if Rest >= 1 then begin
        if P[I + 1] in [$80..$8F] then begin
          Result := icJcc;
          Target := Rel(Rest - 1);
        end
        else if P[I + 1] = $0B then
          Result := icTrap;
      end;
    $C2, $C3, $CA, $CB, $CF:
      Result := icRet;
    $CC:
      Result := icInt3;
    $CD, $CE, $F4:
      Result := icTrap;
    $EA:
      Result := icFar;
    $9A:
      Result := icCallInd;
    $FF:
      if Rest >= 1 then
        case (P[I + 1] shr 3) and 7 of
          2, 3: Result := icCallInd;
          4: Result := icJmpInd;
          5: Result := icFar;
        end;
  end;
end;

function TSurvey.BranchTargetOf(Rva: Cardinal): Int64;
begin
  var Len := InsnLen(Rva);
  var P := Img.Ptr(Rva, Len);
  if P = nil then
    Exit(-1);
  Classify(P, Len, Rva, Result);
end;

function TSurvey.CodeName(Rva: Cardinal): string;
// Name of a code address: the TD32 procedure, else the import a thunk jumps through.
begin
  if Reader.RvaToFunctionName(Rva, Result) then
    Exit;
  Result := '';
  var P := Img.Ptr(Rva, 7);
  if P = nil then
    Exit;
  var Skip := 0;
  if Is64 and (P[0] = $48) then
    Skip := 1;
  if (P[Skip] <> $FF) or (P[Skip + 1] <> $25) then
    Exit;
  var Disp := PInteger(P + Skip + 2)^;
  var Slot: Cardinal;
  if Is64 then
    Slot := Cardinal(Int64(Rva) + Skip + 6 + Disp)
  else
    Slot := Cardinal(Cardinal(Disp) - Cardinal(ImageBase));
  var Name: string;
  if FImports.TryGetValue(Slot, Name) then
    Result := 'import ' + Name;
end;

function TSurvey.NameOrSub(Rva: Cardinal): string;
begin
  Result := CodeName(Rva);
  if Result = '' then
    Result := Format('sub_%x', [Rva]);
end;

function TSurvey.LineOf(Rva: Cardinal): string;
begin
  var Loc: TSourceLocation;
  if Reader.RvaToSourceLine(Rva, Loc) then
    Result := Format('%s:%d', [Loc.SourceFile, Loc.Line])
  else
    Result := '?';
end;

function TSurvey.NormText(const Text: string; S, E, After: Cardinal): string;
// The instruction text with register names folded to REG and every number
// replaced by what it IS: an address of the routine, the address right after
// the jump, another code address, an image address, or a plain number.

  function IsIdent(C: Char): Boolean;
  begin
    Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or ((C >= '0') and (C <= '9')) or (C = '_');
  end;

  function LiteralClass(const Tok: string): string;
  begin
    var V: UInt64;
    if not TryStrToUInt64('$' + Copy(Tok, 3, MaxInt), V) then
      Exit('N');
    if (V < ImageBase) or (V - ImageBase >= Img.SizeOfImage) then
      Exit('N');
    var Rva := Cardinal(V - ImageBase);
    if Rva = After then
      Result := '<after-jmp>'
    else if (Rva >= S) and (Rva < E) then
      Result := '<in-routine>'
    else if InCode(Rva) then
      Result := '<code>'
    else
      Result := '<image>';
  end;

begin
  var SB := TStringBuilder.Create;
  try
    var N := Length(Text);
    var I := 1;
    while I <= N do begin
      if not IsIdent(Text[I]) then begin
        SB.Append(Text[I]);
        Inc(I);
        Continue;
      end;
      var J := I;
      while (J <= N) and IsIdent(Text[J]) do
        Inc(J);
      var Tok := Copy(Text, I, J - I);
      if (Length(Tok) > 2) and (Tok[1] = '0') and (Tok[2] = 'x') then
        SB.Append(LiteralClass(Tok))
      else if FRegs.ContainsKey(Tok) then
        SB.Append('REG')
      else
        SB.Append(Tok);
      I := J;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TSurvey.DisasmLine(Rva: Cardinal): string;
begin
  var Len: Integer;
  var Text: string;
  if DecodeAt(Rva, Len, Text) then
    Result := Format('    $%.8x  %-24s %s', [Rva, HexBytes(Img.Ptr(Rva, Len), Len), Text])
  else
    Result := Format('    $%.8x  %-24s (does not decode)', [Rva, HexBytes(Img.Ptr(Rva, 4), 4)]);
end;

function TSurvey.PrevInsn(P, Lo: Cardinal; out Q: Cardinal): Boolean;
// The proven instruction that ends exactly at P, if there is one.
begin
  Q := 0;
  var K: Cardinal := 1;
  while (K <= 15) and (P >= Lo + K) do begin
    var Fl := F(P - K);
    if Fl and fInsn <> 0 then begin
      Q := P - K;
      Exit(Cardinal(InsnLen(Q)) = K);
    end;
    if Fl and fInterior = 0 then
      Exit(False);
    Inc(K);
  end;
  Result := False;
end;

{ ---------------------------------------------------------- PE directories }

procedure TSurvey.ParseRelocs;
begin
  var Rva := Img.DirRva[5];
  var Size := Img.DirSize[5];
  var Ofs: Cardinal := 0;
  while Ofs + 8 <= Size do begin
    var P := Img.Ptr(Rva + Ofs, 8);
    if P = nil then
      Break;
    var Page := PCardinal(P)^;
    var BlockSize := PCardinal(P + 4)^;
    if BlockSize < 8 then
      Break;
    var E := Img.Ptr(Rva + Ofs + 8, BlockSize - 8);
    if E = nil then
      Break;
    for var I := 0 to Integer(BlockSize - 8) div 2 - 1 do begin
      var W := PWord(E + I * 2)^;
      var Typ := W shr 12;
      if (Typ <> 3) and (Typ <> 10) then
        Continue;
      Inc(RelocTotal);
      var Site := Page + (W and $FFF);
      if InCode(Site) then begin
        SetF(Site, fReloc);
        Inc(RelocInCode);
      end;
    end;
    Inc(Ofs, BlockSize);
  end;
  HasRelocs := RelocTotal > 0;
end;

procedure TSurvey.ParseImports;
begin
  var Dir := Img.DirRva[1];
  if Dir = 0 then
    Exit;
  var PtrSize: Cardinal := 4;
  if Is64 then
    PtrSize := 8;
  var I: Cardinal := 0;
  while True do begin
    var D := Img.Ptr(Dir + I * 20, 20);
    if D = nil then
      Break;
    var Oft := PCardinal(D)^;
    var NameRva := PCardinal(D + 12)^;
    var Ft := PCardinal(D + 16)^;
    if (Oft = 0) and (Ft = 0) then
      Break;
    var Dll := Img.AnsiZ(NameRva);
    var Ilt := Oft;
    if Ilt = 0 then
      Ilt := Ft;
    var K: Cardinal := 0;
    while True do begin
      var E := Img.Ptr(Ilt + K * PtrSize, PtrSize);
      if E = nil then
        Break;
      var V: UInt64;
      if Is64 then
        V := PUInt64(E)^
      else
        V := PCardinal(E)^;
      if V = 0 then
        Break;
      var Name: string;
      if (Is64 and (V shr 63 <> 0)) or ((not Is64) and (V shr 31 <> 0)) then
        Name := Format('%s!#%d', [Dll, V and $FFFF])
      else
        Name := Dll + '!' + Img.AnsiZ(Cardinal(V) + 2);
      FImports.AddOrSetValue(Ft + K * PtrSize, Name);
      Inc(K);
    end;
    Inc(I);
  end;

  // Delay-load imports: a `jmp [slot]` through one of these is an import thunk too.
  Dir := Img.DirRva[13];
  if Dir = 0 then
    Exit;
  I := 0;
  while True do begin
    var D := Img.Ptr(Dir + I * 32, 32);
    if D = nil then
      Break;
    var Attrs := PCardinal(D)^;
    var NameRva := PCardinal(D + 4)^;
    var Iat := PCardinal(D + 12)^;
    var Names := PCardinal(D + 16)^;
    if (NameRva = 0) and (Iat = 0) then
      Break;
    // Attribute bit 0 clear: the fields are virtual addresses, not RVAs.
    if Attrs and 1 = 0 then begin
      Dec(NameRva, Cardinal(ImageBase));
      Dec(Iat, Cardinal(ImageBase));
      Dec(Names, Cardinal(ImageBase));
    end;
    var Dll := Img.AnsiZ(NameRva);
    var K: Cardinal := 0;
    while True do begin
      var E := Img.Ptr(Names + K * PtrSize, PtrSize);
      if E = nil then
        Break;
      var V: UInt64;
      if Is64 then
        V := PUInt64(E)^
      else
        V := PCardinal(E)^;
      if V = 0 then
        Break;
      var Name: string;
      if (Is64 and (V shr 63 <> 0)) or ((not Is64) and (V shr 31 <> 0)) then
        Name := Format('%s!#%d (delay-load)', [Dll, V and $FFFF])
      else begin
        if Attrs and 1 = 0 then
          Dec(V, ImageBase);
        Name := Dll + '!' + Img.AnsiZ(Cardinal(V) + 2) + ' (delay-load)';
      end;
      FImports.AddOrSetValue(Iat + K * PtrSize, Name);
      Inc(K);
    end;
    Inc(I);
  end;
end;

procedure TSurvey.ParseExports;
begin
  var Dir := Img.DirRva[0];
  var P := Img.Ptr(Dir, 40);
  if (Dir = 0) or (P = nil) then
    Exit;
  var NumFuncs := PCardinal(P + 20)^;
  var AddrFuncs := PCardinal(P + 28)^;
  for var I := 0 to Integer(NumFuncs) - 1 do begin
    var V: Cardinal;
    if Img.U32(AddrFuncs + Cardinal(I) * 4, V) and (V <> 0) then
      FExports.AddOrSetValue(V, True);
  end;
end;

function TSurvey.FindPdata(Rva: Cardinal): Integer;
// Index of the .pdata entry whose [Begin, End) holds Rva, or -1.
begin
  var Lo := 0;
  var Hi := High(PdBegin);
  while Lo <= Hi do begin
    var Mid := (Lo + Hi) shr 1;
    if PdBegin[Mid] <= Rva then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  if (Hi >= 0) and (Rva < PdEnd[Hi]) then
    Result := Hi
  else
    Result := -1;
end;

procedure TSurvey.DecodeScopeTable(Idx: Integer);
// The MSVC-shaped scope table dcc64 hangs off _DelphiExceptionHandler
// (docs/EH_FORMAT_NOTES.md). Marks every handler entry as a seed, every clause
// table as data, and tallies where they sit relative to the TD32 range of the
// procedure that owns them (assumption 17).

  function Where(Rva: Cardinal; HaveOwner: Boolean; OwnerS: UInt64): Integer;
  begin
    var S: UInt64;
    if not Reader.RvaToFunctionStart(Rva, S) then
      Exit(2);
    if HaveOwner and (S = OwnerS) then
      Result := 0
    else
      Result := 1;
  end;

begin
  var Data := PdData[Idx];
  var Count: Cardinal;
  if (not Img.U32(Data, Count)) or (Count = 0) or (Count > 8192) or (Img.Ptr(Data + 4, Count * 16) = nil) then begin
    Inc(ScopeMalformed);
    Exit;
  end;
  Inc(ScopeTables);
  var OwnerS: UInt64;
  var HaveOwner := Reader.RvaToFunctionStart(PdBegin[Idx], OwnerS);
  if not HaveOwner then
    Inc(ScopeOwnersNoProc);
  for var I := 0 to Integer(Count) - 1 do begin
    var P := Img.Ptr(Data + 4 + Cardinal(I) * 16, 16);
    var Handler := PCardinal(P + 8)^;
    var Target := PCardinal(P + 12)^;
    Inc(ScopeEntries);
    if Handler <= 2 then begin
      if not InCode(Target) then
        Continue;
      SetF(Target, fSeedEH);
      var Kind := 0;
      if Handler <> 0 then
        Kind := 1;
      Inc(A17[Kind, Where(Target, HaveOwner, OwnerS)]);
      Continue;
    end;
    var N: Cardinal;
    if (not Img.U32(Handler, N)) or (N = 0) or (N > 4096) or (Img.Ptr(Handler + 4, N * 8) = nil) then begin
      Inc(ScopeMalformed);
      Continue;
    end;
    Inc(A17[3, Where(Handler, HaveOwner, OwnerS)]);
    var SecName := Img.SectionNameOf(Handler);
    var Cnt: Integer;
    ClauseSections.TryGetValue(SecName, Cnt);
    ClauseSections.AddOrSetValue(SecName, Cnt + 1);
    if InCode(Handler) and InCode(Handler + 4 + N * 8 - 1) then
      for var B := Handler to Handler + 4 + N * 8 - 1 do
        SetF(B, fData or fClauseTbl);
    for var K := 0 to Integer(N) - 1 do begin
      var Block: Cardinal;
      Img.U32(Handler + 8 + Cardinal(K) * 8, Block);
      if not InCode(Block) then
        Continue;
      SetF(Block, fSeedEH);
      Inc(A17[2, Where(Block, HaveOwner, OwnerS)]);
    end;
  end;
end;

procedure TSurvey.ParsePdata;
type
  TRow = record
    B, E, U: Cardinal;
  end;
begin
  if not Is64 then
    Exit;
  var Rva := Img.DirRva[3];
  var Rows := TList<TRow>.Create;
  try
    for var I := 0 to Integer(Img.DirSize[3] div 12) - 1 do begin
      var P := Img.Ptr(Rva + Cardinal(I) * 12, 12);
      if P = nil then
        Break;
      var R: TRow;
      R.B := PCardinal(P)^;
      R.E := PCardinal(P + 4)^;
      R.U := PCardinal(P + 8)^;
      if R.E > R.B then
        Rows.Add(R);
    end;
    Rows.Sort(TComparer<TRow>.Construct(
      function(const A, B: TRow): Integer
      begin
        if A.B < B.B then
          Result := -1
        else if A.B > B.B then
          Result := 1
        else
          Result := 0;
      end));
    SetLength(PdBegin, Rows.Count);
    SetLength(PdEnd, Rows.Count);
    SetLength(PdUnw, Rows.Count);
    SetLength(PdHandler, Rows.Count);
    SetLength(PdData, Rows.Count);
    for var I := 0 to Rows.Count - 1 do begin
      PdBegin[I] := Rows[I].B;
      PdEnd[I] := Rows[I].E;
      PdUnw[I] := Rows[I].U;
    end;
  finally
    Rows.Free;
  end;

  for var I := 0 to High(PdBegin) do begin
    if InCode(PdBegin[I]) then
      SetF(PdBegin[I], fSeedPd);
    var P := Img.Ptr(PdUnw[I], 4);
    if P = nil then
      Continue;
    var SecName := Img.SectionNameOf(PdUnw[I]);
    var Cnt: Integer;
    UnwSections.TryGetValue(SecName, Cnt);
    UnwSections.AddOrSetValue(SecName, Cnt + 1);
    var Fl := P[0] shr 3;
    var Ofs: Cardinal := 4 + ((Cardinal(P[2]) + 1) and not Cardinal(1)) * 2;
    if Fl and 4 <> 0 then begin
      Inc(PdChained);
      Continue;
    end;
    if Fl and 3 = 0 then
      Continue;
    var H: Cardinal;
    if not Img.U32(PdUnw[I] + Ofs, H) then
      Continue;
    PdHandler[I] := H;
    PdData[I] := PdUnw[I] + Ofs + 4;
    Handlers.TryGetValue(H, Cnt);
    Handlers.AddOrSetValue(H, Cnt + 1);
  end;

  // Only _DelphiExceptionHandler's data is a Delphi scope table; under another
  // language handler the same field means something else.
  for var H in Handlers.Keys do
    if CodeName(H).Contains('DelphiExceptionHandler') then
      DelphiHandlers.AddOrSetValue(H, True);
  for var I := 0 to High(PdBegin) do
    if (PdHandler[I] <> 0) and DelphiHandlers.ContainsKey(PdHandler[I]) then
      DecodeScopeTable(I);

  for var I := 0 to High(PdBegin) do begin
    var S: UInt64;
    if not Reader.RvaToFunctionStart(PdBegin[I], S) then begin
      Inc(PdOutside);
      if InCode(PdBegin[I]) and (F(PdBegin[I]) and fSeedEH <> 0) then
        Inc(PdOutsideTarget);
    end
    else if S = PdBegin[I] then
      Inc(PdProcStart)
    else
      Inc(PdInsideProc);
  end;
end;

{ ------------------------------------------------------------ unit building }

function TSurvey.FindRoutineEnd(S: UInt64; LastInside: UInt64): Cardinal;

  function Inside(X: UInt64): Boolean;
  begin
    var T: UInt64;
    Result := (X < CodeHi) and Reader.RvaToFunctionStart(X, T) and (T = S);
  end;

begin
  var Lo := LastInside;
  var Step: UInt64 := 16;
  var Hi := Lo + Step;
  while Inside(Hi) do begin
    Lo := Hi;
    Step := Step * 2;
    Hi := Lo + Step;
  end;
  while Hi - Lo > 1 do begin
    var Mid := (Lo + Hi) shr 1;
    if Inside(Mid) then
      Lo := Mid
    else
      Hi := Mid;
  end;
  Result := Cardinal(Hi);
end;

procedure TSurvey.BuildUnits;
begin
  Recs := Reader.SortedRvas;
  SetLength(RecUnit, Length(Recs));
  SetLength(RecKey, Length(Recs));
  for var I := 0 to High(Recs) do begin
    RecUnit[I] := -1;
    if InCode(Recs[I]) then
      SetF(Cardinal(Recs[I]), fLine)
    else
      Inc(NotInCode);
    var Loc: TSourceLocation;
    Reader.RvaToSourceLine(Recs[I], Loc);
    var Id: Integer;
    if not FileIds.TryGetValue(Loc.SourceFile, Id) then begin
      Id := FileNames.Count;
      FileNames.Add(Loc.SourceFile);
      FileIds.Add(Loc.SourceFile, Id);
    end;
    RecKey[I] := (UInt64(Id) shl 32) or UInt64(Cardinal(Loc.Line));
  end;

  var List := TList<TUnitCtx>.Create;
  var Seen := TDictionary<UInt64, Boolean>.Create;
  try
    var I := 0;
    while I <= High(Recs) do begin
      var Rva := Recs[I];
      if not InCode(Rva) then begin
        Inc(I);
        Continue;
      end;
      var U := Default(TUnitCtx);
      U.PdPrimary := -1;
      var S: UInt64;
      if Reader.RvaToFunctionStart(Rva, S) and InCode(S) then begin
        U.S := Cardinal(S);
        U.FirstRec := I;
        var J := I;
        var S2: UInt64;
        while (J < High(Recs)) and Reader.RvaToFunctionStart(Recs[J + 1], S2) and (S2 = S) do
          Inc(J);
        U.LastRec := J;
        U.E := FindRoutineEnd(S, Recs[J]);
        if Is64 then
          U.PdPrimary := FindPdata(U.S);
        if Seen.ContainsKey(S) then
          Inc(SplitRoutines)
        else
          Seen.Add(S, True);
        for var K := I to J do
          RecUnit[K] := List.Count;
        List.Add(U);
        I := J + 1;
        Continue;
      end;
      Inc(OrphanRecs);
      var Pd := -1;
      if Is64 then
        Pd := FindPdata(Cardinal(Rva));
      if (Pd >= 0) and ((List.Count = 0) or (PdBegin[Pd] >= List.Last.E)) then begin
        // A .pdata function no TD32 procedure covers: analysed on its own, from
        // its BeginAddress, and reported apart from the procedures.
        Inc(OrphanInPdata);
        U.Pseudo := True;
        U.S := PdBegin[Pd];
        U.E := Min(PdEnd[Pd], CodeHi);
        U.PdPrimary := Pd;
        U.FirstRec := I;
        var J := I;
        var S2: UInt64;
        while (J < High(Recs)) and (Recs[J + 1] < U.E) and not Reader.RvaToFunctionStart(Recs[J + 1], S2) do begin
          Inc(J);
          Inc(OrphanRecs);
          Inc(OrphanInPdata);
        end;
        U.LastRec := J;
        for var K := I to J do
          RecUnit[K] := List.Count;
        List.Add(U);
        I := J + 1;
        Continue;
      end;
      Inc(I);
    end;
    RoutinesSeen := Seen.Count;
    Units := List.ToArray;
  finally
    Seen.Free;
    List.Free;
  end;
end;

{ ------------------------------------------------------------ routine decode }

procedure TSurvey.Seed(const U: TUnitCtx; Rva: Int64; Bits: Word);
begin
  if (Rva < U.S) or (Rva >= U.E) then
    Exit;
  SetF(Cardinal(Rva), Bits);
  FWork.Push(Cardinal(Rva));
end;

procedure TSurvey.NoteAddrRefs(const U: TUnitCtx; Pc: Cardinal; Len: Integer; C: Byte; P: PByte; const Text: string);
// Addresses of the routine that one of its own instructions names as an
// immediate or a displacement. On x86 the base relocations say exactly where
// such an address is; on x64 Zydis prints a RIP-relative operand as the
// absolute address it designates.
begin
  if (not Is64) and HasRelocs then begin
    for var K := 1 to Len - 4 do begin
      if F(Pc + Cardinal(K)) and fReloc = 0 then
        Continue;
      var T := Int64(PCardinal(P + K)^) - Int64(ImageBase);
      if (T < U.S) or (T >= U.E) then
        Continue;
      SetF(Cardinal(T), fAddrRef);
      if (P[0] = $68) and (K = 1) then
        FPendPush.Add(Cardinal(T));
    end;
    Exit;
  end;
  if not (C in [icOther, icCallInd, icJmpInd]) then
    Exit;
  if Pos('0x', Text) = 0 then
    Exit;
  var Lits: TLits;
  for var K := 0 to ParseHexLiterals(Text, Lits) - 1 do begin
    if Lits[K] < ImageBase then
      Continue;
    var T := Lits[K] - ImageBase;
    if (T < U.S) or (T >= U.E) then
      Continue;
    SetF(Cardinal(T), fAddrRef);
    if (not Is64) and (P[0] = $68) then
      FPendPush.Add(Cardinal(T));
  end;
end;

procedure TSurvey.Drain(var U: TUnitCtx);
var
  Insn: TZydisInstruction;
begin
  var B: PBucket := @Bk[U.Pseudo];
  while FWork.Count > 0 do begin
    var Pc := FWork.Pop;
    var LastCall: Int64 := -1;
    while True do begin
      if (Pc < U.S) or (Pc >= U.E) then begin
        Inc(B.FellOut);
        Break;
      end;
      var Fl := F(Pc);
      if Fl and fInsn <> 0 then
        Break;
      if Fl and (fInterior or fData) <> 0 then begin
        Include(U.Why, iwConflict);
        Break;
      end;
      var Avail: Integer;
      var P := Img.PtrAvail(Pc, Avail);
      if P = nil then begin
        Include(U.Why, iwUndecodable);
        Break;
      end;
      if Avail > 15 then
        Avail := 15;
      if not ZydisDecodeOne(Mode, ImageBase + Pc, P^, Avail, Insn) then begin
        Include(U.Why, iwUndecodable);
        if DetIncomplete <> nil then begin
          var After := '';
          if LastCall >= 0 then
            After := '  last direct call on this path: ' + NameOrSub(Cardinal(LastCall));
          DetIncomplete.Add(Format('$%.8x  does not decode: %s  routine=%s%s', [Pc, HexBytes(P, Min(Avail, 8)), NameOrSub(U.S), After]));
        end;
        Break;
      end;
      var Len := Insn.Length;
      if Pc + Cardinal(Len) > U.E then begin
        Include(U.Why, iwCrossesEnd);
        Break;
      end;
      var Clash := False;
      for var K := 1 to Len - 1 do
        if F(Pc + Cardinal(K)) and (fInsn or fInterior or fData) <> 0 then
          Clash := True;
      if Clash then begin
        Include(U.Why, iwConflict);
        if DetIncomplete <> nil then
          DetIncomplete.Add(Format('$%.8x  overlaps an instruction another proven decode reached  routine=%s', [Pc, NameOrSub(U.S)]));
        Break;
      end;
      var Target: Int64;
      var C := Classify(P, Len, Pc, Target);
      SetF(Pc, fInsn);
      for var K := 1 to Len - 1 do
        SetF(Pc + Cardinal(K), fInterior);
      Cls[Pc - CodeLo] := C or Byte(Len shl 4);
      Inc(B.Insns);
      NoteAddrRefs(U, Pc, Len, C, P, Insn.Text);
      var Next := Pc + Cardinal(Len);
      var Stop := False;
      case C of
        icCall, icCallInd: begin
          if InCode(Next) then
            SetF(Next, fRetAddr);
          if (C = icCall) and (Target >= 0) then begin
            LastCall := Target;
            if (Target >= U.S) and (Target < U.E) then
              Seed(U, Target, fTarget)
            else if InCode(Target) then begin
              SetF(Cardinal(Target), fExtTgt);
              // System.@Halt0 never returns, and what follows the call that ends
              // a program's main block is data.
              var NoRet: Boolean;
              if not FNoRet.TryGetValue(Cardinal(Target), NoRet) then begin
                NoRet := CodeName(Cardinal(Target)).Contains('Halt0');
                FNoRet.Add(Cardinal(Target), NoRet);
              end;
              if NoRet then begin
                Inc(NoReturnCalls);
                Stop := True;
              end;
            end;
          end;
        end;
        icJcc, icJmp: begin
          if (Target >= U.S) and (Target < U.E) then
            Seed(U, Target, fTarget)
          else if InCode(Target) then
            SetF(Cardinal(Target), fExtTgt);
          Stop := C = icJmp;
        end;
        icJmpInd: begin
          FPendJmp.Add(Pc);
          Stop := True;
        end;
        icRet, icInt3, icTrap, icFar:
          Stop := True;
      end;
      if Stop then
        Break;
      Pc := Next;
    end;
  end;
end;

function TSurvey.ReadTable(const U: TUnitCtx; Tbl: Cardinal; Kind: TTableKind; RelBase: Int64;
  Targets: TList<Cardinal>): Integer;
// Reads a jump table at Tbl for as long as its entries land inside the routine.
// The table cannot run into code a proven decode already reached, nor into the
// lowest of its own targets above it.
begin
  Targets.Clear;
  var EntSize: Cardinal := 4;
  if Kind = tkAbs64 then
    EntSize := 8;
  var Limit := U.E;
  var A := Tbl;
  while (A >= U.S) and (A + EntSize <= Limit) do begin
    if F(A) and (fInsn or fInterior) <> 0 then
      Break;
    var P := Img.Ptr(A, EntSize);
    if P = nil then
      Break;
    var T: Int64;
    case Kind of
      tkAbs32: begin
        if HasRelocs and (F(A) and fReloc = 0) then
          Break;
        T := Int64(PCardinal(P)^) - Int64(ImageBase);
      end;
      tkAbs64: begin
        if HasRelocs and (F(A) and fReloc = 0) then
          Break;
        T := Int64(PUInt64(P)^ - ImageBase);
      end;
    else
      T := RelBase + PInteger(P)^;
    end;
    if (T < U.S) or (T >= U.E) then
      Break;
    if (T >= Tbl) and (T < A + EntSize) then
      Break;
    if F(Cardinal(T)) and (fInterior or fData) <> 0 then
      Break;
    Targets.Add(Cardinal(T));
    if (T > A) and (T < Limit) then
      Limit := Cardinal(T);
    Inc(A, EntSize);
  end;
  Result := Targets.Count;
end;

procedure TSurvey.ResolveIndirectJump(var U: TUnitCtx; J: Cardinal);
// Decides what an indirect jump is: an import thunk, a jump through a table
// this tool recognises, or something else. Records its shape either way.
const
  KIND_NAME: array[TTableKind] of string = ('abs32', 'abs64', 'rel32');
begin
  var Len := InsnLen(J);
  var P := Img.Ptr(J, Len);
  var After := J + Cardinal(Len);
  var I := 0;
  while (I < Len - 1) and (P[I] <> $FF) do
    Inc(I);
  var ModRM := P[I + 1];
  var Md := ModRM shr 6;
  var Rm := ModRM and 7;

  if (Md = 0) and (Rm = 5) and (I + 6 <= Len) then begin
    var Disp := PInteger(P + I + 2)^;
    var Slot: Cardinal;
    if Is64 then
      Slot := Cardinal(Int64(After) + Disp)
    else
      Slot := Cardinal(Cardinal(Disp) - Cardinal(ImageBase));
    if FImports.ContainsKey(Slot) then begin
      SetCls(J, icJmpImport);
      Inc(ImportThunkJumps);
      Exit;
    end;
  end;

  // The instructions before the jump: context for the shape, and the routine
  // addresses they name are candidate table bases.
  var Before := TList<Cardinal>.Create;
  var Cands := TList<Cardinal>.Create;
  var Targets := TList<Cardinal>.Create;
  var Best := TList<Cardinal>.Create;
  try
    var Q := J;
    var ByteLoad: Int64 := -1;
    for var K := 1 to 8 do begin
      var Prev: Cardinal;
      if not PrevInsn(Q, U.S, Prev) then
        Break;
      if InsnCls(Prev) in [icJmp, icRet, icJmpInd, icJmpTable, icJmpImport, icJmpFinally, icInt3, icTrap, icFar] then
        Break;
      Before.Insert(0, Prev);
      var L2: Integer;
      var T2: string;
      if DecodeAt(Prev, L2, T2) then begin
        var Lits: TLits;
        for var M := 0 to ParseHexLiterals(T2, Lits) - 1 do begin
          if Lits[M] < ImageBase then
            Continue;
          var R := Lits[M] - ImageBase;
          if (R < U.S) or (R >= U.E) then
            Continue;
          if not Cands.Contains(Cardinal(R)) then
            Cands.Add(Cardinal(R));
          if K = 1 then
            ByteLoad := R;
        end;
      end;
      Q := Prev;
    end;

    var Found := False;
    var TblAt: Cardinal := 0;
    var TblKind := tkAbs32;
    var RelDesc := '';
    // x86: `pop REG; jmp REG` directly in front of a handler stub is how dcc32
    // leaves a finally block. It is not a table jump and not a routine exit:
    // the address it pops is the continuation the try pushed.
    var FinallyExit := False;
    if (not Is64) and (Md = 3) and (Before.Count > 0) then begin
      var Pop := Before.Last;
      var PA := Img.Ptr(After, 5);
      if (InsnLen(Pop) = 1) and (Img.Ptr(Pop, 1)^ = $58 + Rm) and (PA <> nil) and (PA[0] = $E9) then begin
        var Dest := (Int64(After) + 5 + PInteger(PA + 1)^) and $FFFFFFFF;
        FinallyExit := (Dest < U.S) or (Dest >= U.E);
      end;
    end;
    // x86: jmp dword ptr [index*4 + table]
    if FinallyExit then begin
      SetCls(J, icJmpFinally);
      Inc(FinallyJumps);
    end
    else if (not Is64) and (Md = 0) and (Rm = 4) and (I + 7 <= Len) and ((P[I + 2] and 7) = 5) and ((P[I + 2] shr 6) = 2) then begin
      var T := Int64(PCardinal(P + I + 3)^) - Int64(ImageBase);
      if (T >= U.S) and (T < U.E) and (ReadTable(U, Cardinal(T), tkAbs32, 0, Best) >= 1) then begin
        Found := True;
        TblAt := Cardinal(T);
      end;
    end;
    // Anything else: try every candidate table address against every base an
    // entry could be relative to.
    if not Found and not FinallyExit then begin
      if not Cands.Contains(After) then
        Cands.Add(After);
      var Bases := TList<Int64>.Create;
      try
        for var C in Cands do
          Bases.Add(C);
        Bases.Add(U.S);
        Bases.Add(0);
        for var Tbl in Cands do begin
          if not Is64 then begin
            if (ReadTable(U, Tbl, tkAbs32, 0, Targets) >= 2) and (Targets.Count > Best.Count) then begin
              Best.Clear;
              Best.AddRange(Targets);
              TblAt := Tbl;
              TblKind := tkAbs32;
              RelDesc := '';
            end;
            Continue;
          end;
          if (ReadTable(U, Tbl, tkAbs64, 0, Targets) >= 2) and (Targets.Count > Best.Count) then begin
            Best.Clear;
            Best.AddRange(Targets);
            TblAt := Tbl;
            TblKind := tkAbs64;
            RelDesc := '';
          end;
          for var Base in Bases do
            if (ReadTable(U, Tbl, tkRel32, Base, Targets) >= 2) and (Targets.Count > Best.Count) then begin
              Best.Clear;
              Best.AddRange(Targets);
              TblAt := Tbl;
              TblKind := tkRel32;
              if Base = Tbl then
                RelDesc := ' relative to the table'
              else if Base = 0 then
                RelDesc := ' (RVAs)'
              else if Base = U.S then
                RelDesc := ' relative to the routine start'
              else
                RelDesc := ' relative to another routine address';
            end;
        end;
        Found := Best.Count >= 2;
      finally
        Bases.Free;
      end;
    end;

    var Verdict: string;
    if FinallyExit then
      Verdict := 'x86 FINALLY EXIT: pop REG; jmp REG to the continuation the try pushed; the handler stub follows'
    else if Found then begin
      var EntSize: Cardinal := 4;
      if TblKind = tkAbs64 then
        EntSize := 8;
      for var B := TblAt to TblAt + Cardinal(Best.Count) * EntSize - 1 do
        SetF(B, fData or fJmpTbl);
      Verdict := 'TABLE ' + KIND_NAME[TblKind] + RelDesc;
      if TblAt = After then
        Verdict := Verdict + ', directly after the jmp'
      else
        Verdict := Verdict + ', not adjacent to the jmp';
      // x86 two-level form: a byte index table between the jump and the table.
      // dcc32 loads the index with `movzx REG, byte ptr [REG+idx]` or with
      // `mov REG8, [REG+idx]`; either way idx is the address right after the jmp.
      if (not Is64) and (TblKind = tkAbs32) and (ByteLoad = After) and (After < TblAt) and (TblAt - After <= 4096) then begin
        for var B := After to TblAt - 1 do
          SetF(B, fData or fJmpTbl);
        Verdict := Verdict + ', byte index table before it';
        Inc(IndexTables);
      end;
      SetCls(J, icJmpTable);
      Inc(TablesFound);
      Inc(TableEntries, Best.Count);
      for var T in Best do
        Seed(U, T, fTarget or fTableEnt);
    end
    else begin
      Include(U.Why, iwIndJmp);
      Verdict := 'NO TABLE recognised';
      if (not Is64) and (ReadTable(U, After, tkAbs32, 0, Targets) >= 1) then
        Verdict := Verdict + ' (but routine addresses follow the jmp)';
    end;

    var L1: Integer;
    var Text: string;
    DecodeAt(J, L1, Text);
    var Key := NormText(Text, U.S, U.E, After) + '  =>  ' + Verdict;
    var Sh: TShape;
    if not Shapes.TryGetValue(Key, Sh) then begin
      Sh := TShape.Create;
      Shapes.Add(Key, Sh);
    end;
    Inc(Sh.Count);
    if Found then
      Inc(Sh.Entries, Best.Count);
    var Ctx := '';
    for var K := Max(0, Before.Count - 3) to Before.Count - 1 do begin
      var L2: Integer;
      var T2: string;
      DecodeAt(Before[K], L2, T2);
      Ctx := Ctx + NormText(T2, U.S, U.E, After) + ' ; ';
    end;
    var N: Integer;
    Sh.Contexts.TryGetValue(Ctx, N);
    Sh.Contexts.AddOrSetValue(Ctx, N + 1);
    if Sh.Examples.Count < 3 then begin
      var SB := TStringBuilder.Create;
      try
        SB.AppendLine(Format('  in %s  (%s)', [NameOrSub(U.S), LineOf(J)]));
        for var K := Max(0, Before.Count - 6) to Before.Count - 1 do
          SB.AppendLine(DisasmLine(Before[K]));
        SB.AppendLine(DisasmLine(J));
        if Found then begin
          var EntSize: Cardinal := 4;
          if TblKind = tkAbs64 then
            EntSize := 8;
          for var K := 0 to Min(Best.Count, 6) - 1 do
            SB.AppendLine(Format('    $%.8x  %-24s entry %d -> $%.8x', [TblAt + Cardinal(K) * EntSize,
              HexBytes(Img.Ptr(TblAt + Cardinal(K) * EntSize, EntSize), EntSize), K, Best[K]]));
          SB.AppendLine(Format('    (%d entries)', [Best.Count]));
        end
        else
          SB.AppendLine(Format('    $%.8x  %-24s (bytes after the jmp)', [After, HexBytes(Img.Ptr(After, 12), 12)]));
        Sh.Examples.Add(SB.ToString);
      finally
        SB.Free;
      end;
    end;
  finally
    Best.Free;
    Targets.Free;
    Cands.Free;
    Before.Free;
  end;
end;

function TSurvey.LooksLikeClauseTable(const U: TUnitCtx; X: Cardinal; out Count: Cardinal): Boolean;
// x86: DWORD count, then count pairs { class VMT VA, block VA } whose block is
// an address of the routine (docs/EH_FORMAT_NOTES.md).
begin
  Result := False;
  if (not Img.U32(X, Count)) or (Count = 0) or (Count > 512) then
    Exit;
  if UInt64(X) + 4 + UInt64(Count) * 8 > U.E then
    Exit;
  for var K := 0 to Integer(Count) - 1 do begin
    var Slot := X + 8 + Cardinal(K) * 8;
    var V: Cardinal;
    if not Img.U32(Slot, V) then
      Exit;
    var T := Int64(V) - Int64(ImageBase);
    if (T < U.S) or (T >= U.E) then
      Exit;
    if HasRelocs and (F(Slot) and fReloc = 0) then
      Exit;
  end;
  Result := True;
end;

function TSurvey.ProcessPushes(var U: TUnitCtx): Boolean;
// x86: what a `push imm32` of an address of the routine leads to. A handler
// stub (`jmp` to an RTL handler), then either a clause table or code; or the
// continuation a try/finally pushes for the jump that ends its finally block.
// Any other pushed address of the routine is data in its range (a string
// literal, typically) and is left alone.
begin
  Result := False;
  // Stubs first: a continuation is recognised by the stub in front of it.
  for var Pass := 0 to 1 do begin
    var I := 0;
    while I < FPendPush.Count do begin
      var T := FPendPush[I];
      if F(T) and fSeedEH <> 0 then begin
        FPendPush.Delete(I);
        Continue;
      end;
      var P := Img.Ptr(T, 5);
      if P = nil then begin
        Inc(I);
        Continue;
      end;
      if Pass = 0 then begin
        var Dest := (Int64(T) + 5 + PInteger(P + 1)^) and $FFFFFFFF;
        if (P[0] <> $E9) or ((Dest >= U.S) and (Dest < U.E)) then begin
          Inc(I);
          Continue;
        end;
        FPendPush.Delete(I);
        Result := True;
        Seed(U, T, fStub or fSeedEH or fTarget);
        var Name := CodeName(Cardinal(Dest));
        var Kind := Name;
        for var Known in ['HandleFinally', 'HandleAnyException', 'HandleOnException', 'HandleAutoException'] do
          if Name.Contains(Known) then
            Kind := Known;
        if Kind = '' then
          Kind := '(unnamed target)';
        var N: Integer;
        StubKinds.TryGetValue(Kind, N);
        StubKinds.AddOrSetValue(Kind, N + 1);
        var X := T + 5;
        if X >= U.E then
          Continue;
        var Count: Cardinal;
        var Structural := LooksLikeClauseTable(U, X, Count);
        var UseTable := Structural;
        if Name <> '' then begin
          UseTable := Name.Contains('HandleOnException');
          if UseTable <> Structural then
            Inc(ClauseNameMismatch);
          UseTable := UseTable and Structural;
        end;
        if not UseTable then begin
          Seed(U, X, fTarget or fSeedEH);
          Continue;
        end;
        Inc(ClauseTables86);
        Inc(Clauses86, Count);
        for var B := X to X + 4 + Count * 8 - 1 do
          SetF(B, fData or fClauseTbl);
        for var K := 0 to Integer(Count) - 1 do begin
          var V: Cardinal;
          Img.U32(X + 8 + Cardinal(K) * 8, V);
          Seed(U, Int64(V) - Int64(ImageBase), fTarget or fSeedEH);
        end;
        Continue;
      end;
      // Pass 1: the continuation sits right after `jmp @HandleFinally; jmp <finally>`.
      var AfterShort := (T >= U.S + 7) and (Img.Ptr(T - 2, 1)^ = $EB) and (F(T - 7) and fStub <> 0);
      var AfterNear := (T >= U.S + 10) and (Img.Ptr(T - 5, 1)^ = $E9) and (F(T - 10) and fStub <> 0);
      if AfterShort or AfterNear then begin
        FPendPush.Delete(I);
        Result := True;
        Inc(PushedContinuations);
        Seed(U, T, fTarget or fSeedEH);
        Continue;
      end;
      Inc(I);
    end;
  end;
end;

function TSurvey.CountConfirmed(const U: TUnitCtx): Int64;
begin
  Result := 0;
  for var I := U.FirstRec to U.LastRec do
    if F(Cardinal(Recs[I])) and fInsn <> 0 then
      Inc(Result);
end;

procedure TSurvey.ScanUnexplainedPointers(const U: TUnitCtx);
// x86: a relocated DWORD in the routine, outside every proven instruction and
// every recognised table, that points back into the routine. Each one is a
// table this tool did not recognise.
begin
  if Is64 or not HasRelocs then
    Exit;
  for var A := U.S to U.E - 4 do begin
    var Fl := F(A);
    if (Fl and fReloc = 0) or (Fl and (fInsn or fInterior or fData) <> 0) then
      Continue;
    var V: Cardinal;
    if not Img.U32(A, V) then
      Continue;
    var T := Int64(V) - Int64(ImageBase);
    if (T < U.S) or (T >= U.E) then
      Continue;
    SetF(Cardinal(T), fAddrRef);
    Inc(UnexplainedPtrs);
    if DetPush <> nil then
      DetPush.Add(Format('$%.8x  relocated pointer into its own routine, in no instruction and no recognised table -> $%.8x  routine=%s',
        [A, Cardinal(T), NameOrSub(U.S)]));
  end;
end;

procedure TSurvey.MarkWindows(const U: TUnitCtx);
// x64: the instructions RtlVirtualUnwind may read from a return address when
// it tests for an epilogue.

  function Proven(A: Cardinal): Boolean;
  begin
    Result := (A < U.E) and (F(A) and fInsn <> 0);
  end;

  function IsRspAdjust(A: Cardinal): Boolean;
  begin
    var P := Img.Ptr(A, 3);
    if (P = nil) or ((P[0] and $4C) <> $48) then
      Exit(False);
    if ((P[1] = $83) or (P[1] = $81)) and (P[2] = $C4) then
      Exit(True);
    Result := (P[1] = $8D) and ((P[2] and $38) = $20);
  end;

  function IsPop(A: Cardinal): Boolean;
  begin
    var P := Img.Ptr(A, 2);
    if P = nil then
      Exit(False);
    if (P[0] >= $58) and (P[0] <= $5F) then
      Exit(True);
    Result := ((P[0] and $F0) = $40) and (P[1] >= $58) and (P[1] <= $5F) and (InsnLen(A) = 2);
  end;

begin
  if not Is64 then
    Exit;
  for var R := U.S to U.E - 1 do begin
    if F(R) and (fRetAddr or fInsn) <> (fRetAddr or fInsn) then
      Continue;
    var A := R;
    if IsRspAdjust(A) then begin
      SetF(A, fWindow);
      Inc(A, InsnLen(A));
    end;
    while Proven(A) and IsPop(A) do begin
      SetF(A, fWindow);
      Inc(A, InsnLen(A));
    end;
    if Proven(A) then
      SetF(A, fWindow);
  end;
end;

{ ----------------------------------------------------------- site evaluation }

function TSurvey.SpanFrom(P, E: Cardinal; Relaxed: Boolean; out Why: TSpanFail): Boolean;
// Rules 2-4 of the jump rule for a span that starts at P: whole proven
// instructions covering five bytes inside the routine, nothing able to transfer
// control strictly inside, every instruction relocatable and none a call.
// Relaxed lets a later line start sit inside the span ("merged spans").
begin
  Why := sfNone;
  var Q := P;
  var Total := 0;
  while Total < 5 do begin
    if Q >= E then begin
      Why := sfRoutineEdge;
      Exit(False);
    end;
    if F(Q) and fInsn = 0 then begin
      Why := sfUnproven;
      Exit(False);
    end;
    case InsnCls(Q) of
      icCall, icCallInd: begin
        Why := sfCall;
        Exit(False);
      end;
      icInt3, icTrap: begin
        Why := sfNotRelocatable;
        Exit(False);
      end;
    end;
    var L := InsnLen(Q);
    for var K := 0 to L - 1 do begin
      if (Q = P) and (K = 0) then
        Continue;
      var Fl := F(Q + Cardinal(K));
      if Fl and BARRIER_HARD <> 0 then begin
        Why := sfBranchTarget;
        Exit(False);
      end;
      if (not Relaxed) and (Fl and fLine <> 0) then begin
        Why := sfLineStart;
        Exit(False);
      end;
    end;
    Inc(Total, L);
    Inc(Q, L);
  end;
  Result := True;
end;

procedure TSurvey.EvalLineSite(A, LineEnd, E: Cardinal; Relaxed: Boolean; out Form: TForm;
  out Why: TSpanFail; out IndCall: Boolean);
// The cheapest counting form for the line record at A, in the plan's order of
// preference. The probe may sit on any instruction of the line's first
// straight-line block: from A up to its first branch, its first call, the
// first address a branch can reach, or the next line start.
begin
  Form := fmCC;
  Why := sfNone;
  IndCall := False;
  var HaveJump := False;
  var HaveCall := False;
  var First := True;
  var Q := A;
  while Q < LineEnd do begin
    var Fl := F(Q);
    if Fl and fInsn = 0 then
      Break;
    if (Q > A) and (Fl and BARRIER_HARD <> 0) then
      Break;
    var C := InsnCls(Q);
    var L := InsnLen(Q);
    if (C = icCall) and (L = 5) then begin
      Form := fmRetarget;
      Exit;
    end;
    if C in [icCall, icCallInd, icInt3, icTrap] then begin
      IndCall := C = icCallInd;
      if First then begin
        if C in [icCall, icCallInd] then
          Why := sfCall
        else
          Why := sfNotRelocatable;
      end;
      Break;
    end;
    var W: TSpanFail;
    if SpanFrom(Q, E, Relaxed, W) then begin
      HaveCall := True;
      if (not Is64) or (Fl and fWindow = 0) then
        HaveJump := True;
    end
    else if First then
      Why := W;
    First := False;
    if C <> icOther then
      Break;
    Inc(Q, L);
  end;
  if HaveJump then
    Form := fmJump
  else if HaveCall then
    Form := fmCallForm;
  if Form <> fmCC then
    Why := sfNone
  else if Why = sfNone then
    Why := sfUnproven;
end;

function TSurvey.EvalExit(X, S: Cardinal; Relaxed: Boolean; out Why: TSpanFail): TForm;
// The form an exit probe on the `ret` / leaving jump at X could take. The span
// ends WITH X and is extended backwards over straight-line instructions until
// it covers five bytes; the probe then runs exactly when the exit does.
begin
  Why := sfNone;
  Result := fmCC;
  var P := X;
  var N := InsnLen(X);
  var Last := X + Cardinal(N);
  while N < 5 do begin
    var Fl := F(P);
    if Fl and BARRIER_HARD <> 0 then begin
      Why := sfBranchTarget;
      Exit;
    end;
    if (not Relaxed) and (Fl and fLine <> 0) then begin
      Why := sfLineStart;
      Exit;
    end;
    if P <= S then begin
      Why := sfRoutineEdge;
      Exit;
    end;
    var Q: Cardinal;
    if not PrevInsn(P, S, Q) then begin
      Why := sfUnproven;
      Exit;
    end;
    case InsnCls(Q) of
      icOther: ;
      icCall, icCallInd: begin
        Why := sfCall;
        Exit;
      end;
      icInt3, icTrap: begin
        Why := sfNotRelocatable;
        Exit;
      end;
    else
      Why := sfBranchBefore;
      Exit;
    end;
    P := Q;
    Inc(N, InsnLen(Q));
  end;
  for var B := P + 1 to Last - 1 do begin
    var Fl := F(B);
    if Fl and BARRIER_HARD <> 0 then begin
      Why := sfBranchTarget;
      Exit;
    end;
    if (not Relaxed) and (Fl and fLine <> 0) then begin
      Why := sfLineStart;
      Exit;
    end;
  end;
  if Is64 and (F(P) and fWindow <> 0) then
    Result := fmCallForm
  else
    Result := fmJump;
end;

function TSurvey.UnconfReason(const U: TUnitCtx; A: Cardinal; out RunHead: Boolean; out Before: Cardinal): TUnconfReason;
begin
  RunHead := False;
  Before := 0;
  var Fl := F(A);
  if Fl and fData <> 0 then
    Exit(urInTable);
  if Fl and fInterior <> 0 then
    Exit(urInsideInsn);
  var Q: Int64 := Int64(A) - 1;
  RunHead := (Q >= U.S) and (F(Cardinal(Q)) and (fInsn or fInterior or fData) <> 0);
  while Q >= U.S do begin
    var F2 := F(Cardinal(Q));
    if F2 and fData <> 0 then
      Exit(urAfterTable);
    if F2 and (fInsn or fInterior) <> 0 then begin
      while (Q >= U.S) and (F(Cardinal(Q)) and fInsn = 0) do
        Dec(Q);
      if Q < U.S then
        Exit(urNothingBefore);
      Before := Cardinal(Q);
      case InsnCls(Cardinal(Q)) of
        icJmpInd, icJmpTable, icJmpImport, icJmpFinally: Exit(urAfterIndJmp);
        icRet, icJmp: Exit(urAfterRetJmp);
        icInt3, icTrap, icFar: Exit(urAfterTrap);
      else
        Exit(urAfterStop);
      end;
    end;
    Dec(Q);
  end;
  Result := urNothingBefore;
end;

{ ---------------------------------------------------------------- per unit }

procedure TSurvey.AnalyseUnit(var U: TUnitCtx);

  procedure DrainWithTables;
  begin
    Drain(U);
    while FPendJmp.Count > 0 do begin
      var J := FPendJmp.Last;
      FPendJmp.Delete(FPendJmp.Count - 1);
      ResolveIndirectJump(U, J);
      Drain(U);
    end;
  end;

begin
  var B: PBucket := @Bk[U.Pseudo];
  FWork.Clear;
  FPendJmp.Clear;
  FPendPush.Clear;

  // Stage 0: the entry, direct branch targets, in-routine call targets.
  Seed(U, U.S, 0);
  Drain(U);
  Inc(B.Conf[0], CountConfirmed(U));

  // Stage 1 (x64): .pdata function starts and handler entries inside the range.
  if Is64 then begin
    for var Q := U.S + 1 to U.E - 1 do
      if F(Q) and (fSeedPd or fSeedEH) <> 0 then
        Seed(U, Q, fTarget);
    Drain(U);
  end;
  Inc(B.Conf[1], CountConfirmed(U));

  // Stage 2: jump tables.
  DrainWithTables;
  Inc(B.Conf[2], CountConfirmed(U));

  // Stage 3 (x86): handler stubs, clause tables, pushed continuations.
  if not Is64 then begin
    while ProcessPushes(U) do
      DrainWithTables;
    for var T in FPendPush do begin
      Inc(PushedUnrecognised);
      if DetPush <> nil then
        DetPush.Add(Format('$%.8x  pushed address of its own routine that is neither a handler stub nor a finally continuation: %s  routine=%s',
          [T, HexBytes(Img.Ptr(T, 8), 8), NameOrSub(U.S)]));
    end;
  end;
  Inc(B.Conf[3], CountConfirmed(U));

  ScanUnexplainedPointers(U);
  MarkWindows(U);
end;

procedure TSurvey.TallyMultiLines(const U: TUnitCtx);
// Source lines with more than one record in this routine.
begin
  var N := U.LastRec - U.FirstRec + 1;
  var Arr: TArray<TKeyRva>;
  SetLength(Arr, N);
  for var I := 0 to N - 1 do begin
    Arr[I].Key := RecKey[U.FirstRec + I];
    Arr[I].Rva := Cardinal(Recs[U.FirstRec + I]);
    Arr[I].Ord := I;
  end;
  TArray.Sort<TKeyRva>(Arr, KeyCmp);
  var I := 0;
  while I < N do begin
    var J := I;
    while (J + 1 < N) and (Arr[J + 1].Key = Arr[I].Key) do
      Inc(J);
    Inc(LinesInRoutines);
    var Cnt := J - I + 1;
    if Cnt > 1 then begin
      var M := Default(TMultiLine);
      M.Key := Arr[I].Key;
      M.Count := Cnt;
      M.FirstRva := Arr[I].Rva;
      M.Interleaved := Arr[J].Ord - Arr[I].Ord + 1 > Cnt;
      if Is64 then begin
        var Pd0 := FindPdata(Arr[I].Rva);
        for var K := I + 1 to J do
          if FindPdata(Arr[K].Rva) <> Pd0 then
            M.FuncletCopy := True;
      end;
      Multi.Add(M);
      Inc(MultiLines);
      Inc(MultiExtra, Cnt - 1);
      Inc(MultiHist[Min(Cnt, 5) - 2]);
      if M.Interleaved then
        Inc(MultiInterleaved);
      if M.FuncletCopy then
        Inc(MultiFuncletCopy);
    end;
    I := J + 1;
  end;
end;

procedure TSurvey.TallyUnit(var U: TUnitCtx);
begin
  var B: PBucket := @Bk[U.Pseudo];
  var Complete := U.Why = [];
  var RecCount := U.LastRec - U.FirstRec + 1;
  Inc(B.Units);
  if not Complete then begin
    Inc(B.UnitsIncomplete);
    for var W := Low(TIncompleteWhy) to High(TIncompleteWhy) do
      if W in U.Why then begin
        Inc(B.IncBy[W]);
        Inc(B.IncRecsBy[W], RecCount);
      end;
    if U.Why = [iwIndJmp] then begin
      Inc(B.IncOnlyIndJmp);
      Inc(B.IncOnlyIndJmpRecs, RecCount);
    end;
  end;

  for var I := U.FirstRec to U.LastRec do begin
    var A := Cardinal(Recs[I]);
    var NextA := U.E;
    if I < U.LastRec then
      NextA := Cardinal(Recs[I + 1]);
    Inc(B.Recs);
    var L := NextA - A;
    if L < 5 then
      Inc(B.LenHist[0])
    else if L <= 8 then
      Inc(B.LenHist[1])
    else if L <= 16 then
      Inc(B.LenHist[2])
    else
      Inc(B.LenHist[3]);
    var Fl := F(A);
    if Fl and fInsn = 0 then begin
      var RunHead: Boolean;
      var Before: Cardinal;
      var Reason := UnconfReason(U, A, RunHead, Before);
      Inc(B.Unconf[Reason]);
      var Ext := AnsiLowerCase(ExtractFileExt(FileNames[Integer(RecKey[I] shr 32)]));
      var ExtCount: Integer;
      UnconfByExt.TryGetValue(Ext, ExtCount);
      UnconfByExt.AddOrSetValue(Ext, ExtCount + 1);
      if RunHead then
        Inc(B.UnconfRunHeads);
      Inc(B.FormStrict[fmNone]);
      Inc(B.FormRelaxed[fmNone]);
      if DetUnconf <> nil then begin
        var Prev := '';
        if Before <> 0 then
          Prev := '  after: ' + DisasmLine(Before).Trim;
        DetUnconf.Add(Format('$%.8x  %s  routine=%s [%x..%x)  bytes=%s  reason=%s%s', [A, LineOf(A), NameOrSub(U.S),
          U.S, U.E, HexBytes(Img.Ptr(A, 8), 8), UNCONF_NAME[Reason], Prev]));
      end;
      Continue;
    end;
    if Fl and fRetAddr <> 0 then
      Inc(B.RetAddrRecs);
    if Fl and fWindow <> 0 then
      Inc(B.WindowRecs);
    if InsnCls(A) = icInt3 then
      Inc(B.Int3Recs);
    if Fl and fStub <> 0 then begin
      Inc(B.FormStrict[fmStub]);
      Inc(B.FormRelaxed[fmStub]);
      Continue;
    end;
    if not Complete then begin
      Inc(B.FormStrict[fmCC]);
      Inc(B.FormRelaxed[fmCC]);
      Inc(B.FormIncomplete);
      Continue;
    end;
    var Form: TForm;
    var Why: TSpanFail;
    var IndCall: Boolean;
    EvalLineSite(A, NextA, U.E, False, Form, Why, IndCall);
    Inc(B.FormStrict[Form]);
    if Form = fmCC then begin
      Inc(B.CCWhy[Why]);
      if IndCall then
        Inc(B.CCIndCall);
    end;
    EvalLineSite(A, NextA, U.E, True, Form, Why, IndCall);
    Inc(B.FormRelaxed[Form]);
  end;

  // Exits: every `ret` and every jump that leaves the routine.
  var Q := U.S;
  while Q < U.E do begin
    if F(Q) and fInsn = 0 then begin
      Inc(Q);
      Continue;
    end;
    var C := InsnCls(Q);
    var L := Cardinal(InsnLen(Q));
    var Kind := -1;
    case C of
      icRet:
        // x86: the `ret` that ends a finally block returns to the continuation
        // the try pushed, not to the caller; the handler stub follows it.
        if (not Is64) and InCode(Q + L) and (F(Q + L) and fStub <> 0) then
          Inc(B.FinallyRets)
        else
          Kind := 0;
      icJmp, icJcc: begin
        var T := BranchTargetOf(Q);
        if (T < U.S) or (T >= U.E) then begin
          if C = icJcc then
            Inc(B.CondExits)
          else if F(Q) and fStub <> 0 then
            Inc(B.Stubs)
          else
            Kind := 1;
        end;
      end;
      icJmpInd, icJmpImport:
        Kind := 2;
      icJmpFinally:
        // x86: `pop REG; jmp REG` leaves a finally block for the continuation the
        // try pushed. The stub behind it must have been found through its push.
        if InCode(Q + L) and (F(Q + L) and fStub <> 0) then
          Inc(B.FinallyRets)
        else begin
          Inc(FinallyJumpsNoStub);
          Kind := 2;
        end;
    end;
    if (Kind >= 0) and Is64 then begin
      // A `ret` in a funclet returns to the dispatcher or to the body.
      var Pd := FindPdata(Q);
      if U.Pseudo or ((Pd >= 0) and (Pd <> U.PdPrimary)) then begin
        Inc(B.FuncletRets);
        Kind := -1;
      end;
    end;
    if Kind >= 0 then begin
      Inc(B.Exits);
      Inc(B.ExitKind[Kind]);
      if not Complete then begin
        Inc(B.ExitStrict[fmCC]);
        Inc(B.ExitRelaxed[fmCC]);
        Inc(B.ExitIncomplete);
      end
      else begin
        var Why: TSpanFail;
        var Form := EvalExit(Q, U.S, False, Why);
        Inc(B.ExitStrict[Form]);
        if Form = fmCC then
          Inc(B.ExitCCWhy[Why]);
        Inc(B.ExitRelaxed[EvalExit(Q, U.S, True, Why)]);
      end;
    end;
    Inc(Q, L);
  end;

  for var A := U.S to U.E - 1 do begin
    var Fl := F(A);
    if Fl and (fInsn or fInterior) <> 0 then
      Inc(B.ProvenBytes)
    else if Fl and fData <> 0 then
      Inc(B.DataBytes);
  end;
  Inc(B.RangeBytes, U.E - U.S);

  if not U.Pseudo then
    TallyMultiLines(U);
end;

{ ----------------------------------------------------------------- orphans }

procedure TSurvey.ClassifyOrphans;
// Records no TD32 procedure range contains: what precedes and follows them.

  function DecodesAsCode(A: Cardinal): Boolean;
  begin
    for var K := 1 to 48 do begin
      var Len: Integer;
      var Text: string;
      if not DecodeAt(A, Len, Text) then
        Exit(False);
      var P := Img.Ptr(A, Len);
      var Target: Int64;
      if Classify(P, Len, A, Target) in [icJmp, icRet, icJmpInd, icFar] then
        Exit(True);
      Inc(A, Len);
    end;
    Result := True;
  end;

  function SourceHint(A: Cardinal): string;
  // What the source says the record is, when the source can be found.
  begin
    var Loc: TSourceLocation;
    if not Reader.RvaToSourceLine(A, Loc) then
      Exit('');
    var Text, Prev: string;
    case SourceLine(Loc.SourceFile, Loc.Line, Text) of
      0: Exit(' [source file not found]');
      2: Exit(' [source line beyond the end of the file]');
    end;
    var Line := Text.Trim.ToLower;
    if Line.StartsWith('end.') then
      Exit(' [source: the final `end.` of the unit]');
    if Line.StartsWith('initialization') or Line.StartsWith('finalization') then
      Exit(' [source: opens an initialization/finalization section]');
    SourceLine(Loc.SourceFile, Loc.Line - 1, Prev);
    // `procedure` / `function` followed by a name is a declared routine;
    // followed by `(`, `:`, `begin` or nothing it is an anonymous method.
    for var Where in [Line, Prev.Trim.ToLower] do
      for var Kw in ['procedure', 'function'] do begin
        var At := Where.IndexOf(Kw);
        if At < 0 then
          Continue;
        var Rest := Where.Substring(At + Length(Kw)).TrimLeft;
        if (Rest = '') or (Rest[1] = '(') or (Rest[1] = ':') or Rest.StartsWith('begin') then
          Exit(' [source: body of an anonymous method]');
        Exit(' [source: a declared routine]');
      end;
    Result := ' [source: other]';
  end;

begin
  var LastUnit := -1;
  var GroupKind := '';
  var PrevWasOrphanCode := False;
  for var I := 0 to High(Recs) do begin
    var IsPseudo := (RecUnit[I] >= 0) and Units[RecUnit[I]].Pseudo;
    if (RecUnit[I] >= 0) and not IsPseudo then begin
      LastUnit := RecUnit[I];
      PrevWasOrphanCode := False;
      Continue;
    end;
    if not InCode(Recs[I]) then
      Continue;
    var A := Cardinal(Recs[I]);
    var Kind: string;
    if IsPseudo then begin
      if F(Units[RecUnit[I]].S) and fSeedEH <> 0 then
        Kind := 'x64 funclet: a .pdata function that is a scope-table target, outside every TD32 procedure'
      else
        Kind := 'x64 .pdata function that is not a scope-table target, outside every TD32 procedure';
      Kind := Kind + SourceHint(Cardinal(Recs[Units[RecUnit[I]].FirstRec]));
      PrevWasOrphanCode := False;
    end
    else begin
      var Gap: Int64 := -1;
      if LastUnit >= 0 then
        Gap := Int64(A) - Int64(Units[LastUnit].E);
      var Near := '';
      if (Gap >= 0) and (Gap <= 16) then
        Near := ', within 16 bytes after the preceding procedure';
      var P := Img.Ptr(A, 2);
      if F(A) and fData <> 0 then
        Kind := 'inside a recognised table'
      else if (P <> nil) and (P[0] = 0) and (P[1] = 0) then
        Kind := 'zero bytes: data or padding, not code' + Near + SourceHint(A)
      else if not DecodesAsCode(A) then
        Kind := 'data (does not decode as code)' + Near + SourceHint(A)
      else begin
        // Records are grouped: a group opens at the first orphan after a
        // procedure and again at every `push ebp`/`push rbp`, and the whole
        // group takes the description of its first record.
        var Opens := (P <> nil) and (P[0] = $55);
        if Opens or not PrevWasOrphanCode then begin
          if Opens then
            GroupKind := 'code that opens like a routine (push ebp), no TD32 procedure'
          else
            GroupKind := 'code, no TD32 procedure';
          GroupKind := GroupKind + Near + SourceHint(A);
        end;
        Kind := GroupKind;
        PrevWasOrphanCode := True;
      end;
      if F(A) and fExtTgt <> 0 then
        Inc(OrphanExtTgt);
      if FExports.ContainsKey(A) then
        Inc(OrphanExported);
    end;
    var N: Integer;
    OrphanKinds.TryGetValue(Kind, N);
    OrphanKinds.AddOrSetValue(Kind, N + 1);
    if DetOrphan <> nil then begin
      var Prev := '';
      if LastUnit >= 0 then
        Prev := Format('%s [%x..%x)', [NameOrSub(Units[LastUnit].S), Units[LastUnit].S, Units[LastUnit].E]);
      DetOrphan.Add(Format('$%.8x  %s  kind=%s  preceding procedure=%s', [A, LineOf(A), Kind, Prev]));
      DetOrphan.Add(DisasmLine(A));
    end;
  end;
end;

{ ---------------------------------------------- multi-record lines by source }

procedure TSurvey.BuildSourceIndex;
begin
  var Dir := ExtractFileDir(TPath.GetFullPath(FPath));
  for var Up := 0 to 3 do begin
    if (Dir = '') or not TDirectory.Exists(Dir) then
      Break;
    for var Ext in ['*.pas', '*.dpr', '*.inc', '*.dpk'] do
      for var FileName in TDirectory.GetFiles(Dir, Ext) do
        if not SrcIndex.ContainsKey(AnsiLowerCase(ExtractFileName(FileName))) then
          SrcIndex.Add(AnsiLowerCase(ExtractFileName(FileName)), FileName);
    Dir := ExtractFileDir(Dir);
  end;
  for var Root in SrcDirs do begin
    if not TDirectory.Exists(Root) then
      Continue;
    try
      for var FileName in TDirectory.GetFiles(Root, '*.*', TSearchOption.soAllDirectories) do begin
        var Ext := AnsiLowerCase(ExtractFileExt(FileName));
        if (Ext <> '.pas') and (Ext <> '.dpr') and (Ext <> '.inc') and (Ext <> '.dpk') then
          Continue;
        if not SrcIndex.ContainsKey(AnsiLowerCase(ExtractFileName(FileName))) then
          SrcIndex.Add(AnsiLowerCase(ExtractFileName(FileName)), FileName);
      end;
    except
      on E: Exception do
        Writeln('  (source root ', Root, ' not fully enumerated: ', E.Message, ')');
    end;
  end;
end;

function TSurvey.SourceLine(const FileBase: string; Line: Integer; out Text: string): Integer;
// 0: the source file was not found; 1: Text is the line; 2: the file has fewer lines.
begin
  Text := '';
  if not FSrcIndexBuilt then begin
    BuildSourceIndex;
    FSrcIndexBuilt := True;
  end;
  if not SameText(FSrcCacheName, FileBase) then begin
    FSrcCacheName := FileBase;
    FSrcCacheOk := False;
    FSrcCacheLines.Clear;
    var Path: string;
    if SrcIndex.TryGetValue(AnsiLowerCase(FileBase), Path) then
      try
        FSrcCacheLines.LoadFromFile(Path);
        FSrcCacheOk := True;
      except
        FSrcCacheOk := False;
      end;
  end;
  if not FSrcCacheOk then
    Exit(0);
  if (Line < 1) or (Line > FSrcCacheLines.Count) then
    Exit(2);
  Text := FSrcCacheLines[Line - 1];
  Result := 1;
end;

procedure TSurvey.ClassifyMultiBySource;
// Names the construct by the first token of the source line, where the source
// file can be found. A base name that occurs in several directories resolves
// to the first one found; a source newer than the binary shifts lines.
const
  KEYWORDS: array[0..27] of string = ('begin', 'end', 'for', 'while', 'repeat', 'until', 'if', 'else', 'case',
    'try', 'finally', 'except', 'on', 'with', 'exit', 'raise', 'inherited', 'break', 'continue', 'goto',
    'procedure', 'function', 'constructor', 'destructor', 'class', 'initialization', 'finalization', 'asm');

  function FirstToken(const Line: string): string;
  begin
    var S := Line.Trim.ToLower;
    if S = '' then
      Exit('(empty line)');
    if S.StartsWith('//') or S.StartsWith('{') or S.StartsWith('(*') then
      Exit('(comment)');
    var N := 0;
    while (N < Length(S)) and CharInSet(S[N + 1], ['a'..'z', '0'..'9', '_']) do
      Inc(N);
    var Tok := Copy(S, 1, N);
    for var K in KEYWORDS do
      if Tok = K then
        Exit(Tok);
    if S.Contains(':=') then
      Result := '(assignment)'
    else
      Result := '(call or other statement)';
  end;

begin
  if Multi.Count = 0 then
    Exit;
  Multi.Sort(TComparer<TMultiLine>.Construct(
    function(const A, B: TMultiLine): Integer
    begin
      if A.Key < B.Key then
        Result := -1
      else if A.Key > B.Key then
        Result := 1
      else
        Result := 0;
    end));
  var Tally := TDictionary<string, TArray<Int64>>.Create;
  try
    for var M in Multi do begin
      var FileId := Integer(M.Key shr 32);
      var LineNo := Integer(M.Key and $FFFFFFFF);
      var Tok, Text: string;
      case SourceLine(FileNames[FileId], LineNo, Text) of
        0: Tok := '(source file not found)';
        2: Tok := '(line beyond the end of the source file)';
      else
        Tok := FirstToken(Text);
      end;
      var Row: TArray<Int64>;
      if not Tally.TryGetValue(Tok, Row) then
        SetLength(Row, 4);
      Inc(Row[0]);
      Inc(Row[1], M.Count);
      if M.Interleaved then
        Inc(Row[2]);
      if M.FuncletCopy then
        Inc(Row[3]);
      Tally.AddOrSetValue(Tok, Row);
      if DetMulti <> nil then
        DetMulti.Add(Format('%s:%d  records=%d  first=$%.8x  routine=%s  token=%s%s%s', [FileNames[FileId], LineNo,
          M.Count, M.FirstRva, NameOrSub(M.FirstRva), Tok, IfThen(M.Interleaved, '  interleaved', ''),
          IfThen(M.FuncletCopy, '  funclet-copy', '')]));
    end;
    var Keys := Tally.Keys.ToArray;
    TArray.Sort<string>(Keys, TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := CompareValue(Tally[B][0], Tally[A][0]);
        if Result = 0 then
          Result := CompareStr(A, B);
      end));
    Writeln('  by the first token of the source line (lines / records / interleaved with other lines / copy in another .pdata function):');
    for var K in Keys do
      Writeln(Format('    %-42s %8d %8d %8d %8d', [K, Tally[K][0], Tally[K][1], Tally[K][2], Tally[K][3]]));
  finally
    Tally.Free;
  end;
end;

{ ------------------------------------------------------------------ report }

procedure TSurvey.ReportBucket(const Title: string; const B: TBucket);
begin
  if B.Units = 0 then
    Exit;
  Writeln;
  Writeln('--- ', Title, ' ---');
  Writeln(Format('  ranges analysed %d, instructions decoded %d, decode paths that ran past the range end %d',
    [B.Units, B.Insns, B.FellOut]));
  Writeln(Format('  bytes in the ranges %d: proven instructions %d (%s), recognised tables %d, never reached %d (%s)', [B.RangeBytes,
    B.ProvenBytes, Pct(B.ProvenBytes, B.RangeBytes).Trim, B.DataBytes, B.RangeBytes - B.ProvenBytes - B.DataBytes,
    Pct(B.RangeBytes - B.ProvenBytes - B.DataBytes, B.RangeBytes).Trim]));
  Writeln(Format('  ranges NOT analysed completely: %d (%s), holding %d records', [B.UnitsIncomplete,
    Pct(B.UnitsIncomplete, B.Units).Trim, B.FormIncomplete]));
  for var W := Low(TIncompleteWhy) to High(TIncompleteWhy) do
    if B.IncBy[W] > 0 then
      Writeln(Format('    %-58s %8d ranges %9d records', [INC_NAME[W], B.IncBy[W], B.IncRecsBy[W]]));
  if B.IncOnlyIndJmp > 0 then
    Writeln(Format('    (incomplete ONLY because of an unrecognised indirect jump: %d ranges, %d records)',
      [B.IncOnlyIndJmp, B.IncOnlyIndJmpRecs]));

  Writeln('[3] boundary confirmation (records a proven decode arrives at exactly)');
  Writeln(Format('  records                                             %9d', [B.Recs]));
  Writeln(Format('  confirmed from entry + direct branches              %9d  %s', [B.Conf[0], Pct(B.Conf[0], B.Recs)]));
  Writeln(Format('  + x64 .pdata starts and scope/clause targets        %9d  %s', [B.Conf[1], Pct(B.Conf[1], B.Recs)]));
  Writeln(Format('  + recognised jump-table entries                     %9d  %s', [B.Conf[2], Pct(B.Conf[2], B.Recs)]));
  Writeln(Format('  + x86 handler stubs, clause tables, continuations   %9d  %s', [B.Conf[3], Pct(B.Conf[3], B.Recs)]));
  Writeln(Format('  UNCONFIRMED                                         %9d  %s  (in %d runs)', [B.Recs - B.Conf[3],
    Pct(B.Recs - B.Conf[3], B.Recs), B.UnconfRunHeads]));
  for var R := Low(TUnconfReason) to High(TUnconfReason) do
    if B.Unconf[R] > 0 then
      Writeln(Format('    %-76s %8d', [UNCONF_NAME[R], B.Unconf[R]]));

  Writeln('[6] span statistics per record');
  Writeln(Format('  code length to the next record or the range end:  <5: %d (%s)   5..8: %d (%s)   9..16: %d (%s)   >16: %d (%s)',
    [B.LenHist[0], Pct(B.LenHist[0], B.Recs).Trim, B.LenHist[1], Pct(B.LenHist[1], B.Recs).Trim,
     B.LenHist[2], Pct(B.LenHist[2], B.Recs).Trim, B.LenHist[3], Pct(B.LenHist[3], B.Recs).Trim]));
  Writeln(Format('  record is a return address: %d (%s)', [B.RetAddrRecs, Pct(B.RetAddrRecs, B.Recs).Trim]));
  if Is64 then
    Writeln(Format('  record is inside the window of a return address: %d (%s)', [B.WindowRecs, Pct(B.WindowRecs, B.Recs).Trim]));
  if B.Int3Recs > 0 then
    Writeln(Format('  record whose own first byte is $CC: %d', [B.Int3Recs]));
  Writeln('  probe form per record                      by the plan''s rules      if a span may contain later line starts');
  for var Fm := Low(TForm) to High(TForm) do
    if (B.FormStrict[Fm] > 0) or (B.FormRelaxed[Fm] > 0) then
      Writeln(Format('    %-36s %9d  %s        %9d  %s', [FORM_NAME[Fm], B.FormStrict[Fm], Pct(B.FormStrict[Fm], B.Recs),
        B.FormRelaxed[Fm], Pct(B.FormRelaxed[Fm], B.Recs)]));
  Writeln(Format('    of the records left to a $CC: %d are confirmed records of a range not analysed completely;', [B.FormIncomplete]));
  Writeln('    the others, by what stops a five-byte span at the record''s own address:');
  for var W := Low(TSpanFail) to High(TSpanFail) do
    if B.CCWhy[W] > 0 then
      Writeln(Format('      %-70s %8d', [FAIL_NAME[W], B.CCWhy[W]]));
  if B.CCIndCall > 0 then
    Writeln(Format('    (%d of them have an INDIRECT call in the first block: a re-encoded call could carry the probe)', [B.CCIndCall]));

  Writeln('  routine exits');
  Writeln(Format('    exits %d: ret %d, direct jmp out of the routine %d, indirect jmp %d', [B.Exits, B.ExitKind[0],
    B.ExitKind[1], B.ExitKind[2]]));
  Writeln(Format('    not counted as exits: x86 finally-block exit (ret or pop+jmp) %d, x86 handler stub %d, ' +
    'x64 ret/jmp in a funclet %d, conditional jump out %d',
    [B.FinallyRets, B.Stubs, B.FuncletRets, B.CondExits]));
  Writeln('    probe form per exit                      by the plan''s rules      if a span may contain line starts');
  for var Fm in [fmJump, fmCallForm, fmCC] do
    Writeln(Format('    %-36s %9d  %s        %9d  %s', [FORM_NAME[Fm], B.ExitStrict[Fm], Pct(B.ExitStrict[Fm], B.Exits),
      B.ExitRelaxed[Fm], Pct(B.ExitRelaxed[Fm], B.Exits)]));
  Writeln(Format('    of the exits left to a $CC: %d are in a range not analysed completely; the others:', [B.ExitIncomplete]));
  for var W := Low(TSpanFail) to High(TSpanFail) do
    if B.ExitCCWhy[W] > 0 then
      Writeln(Format('      %-70s %8d', [FAIL_NAME[W], B.ExitCCWhy[W]]));
end;

procedure TSurvey.Run;

  procedure PrintDict(D: TDictionary<string, Integer>; const Indent: string);
  begin
    var Keys := D.Keys.ToArray;
    TArray.Sort<string>(Keys, TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := D[B] - D[A];
        if Result = 0 then
          Result := CompareStr(A, B);
      end));
    for var K in Keys do
      Writeln(Format('%s%8d  %s', [Indent, D[K], K]));
  end;

begin
  var Clock := TStopwatch.StartNew;
  Img := TPEImage.Create(FPath);
  Is64 := Img.Is64;
  ImageBase := Img.ImageBase;
  case Img.Machine of
    IMAGE_FILE_MACHINE_I386: Mode := zmmLegacy32;
    IMAGE_FILE_MACHINE_AMD64: Mode := zmmLong64;
  else
    raise Exception.CreateFmt('unsupported PE machine $%.4x', [Img.Machine]);
  end;

  CodeLo := High(Cardinal);
  CodeHi := 0;
  var SecList := '';
  for var S in Img.Sections do
    if (S.Chars and $20000020 <> 0) and (S.RawSize > 0) then begin
      CodeLo := Min(CodeLo, S.VA);
      CodeHi := Max(CodeHi, S.VA + Max(S.VSize, S.RawSize));
      SecList := SecList + Format(' %s[$%x..$%x)', [S.Name, S.VA, S.VA + S.VSize]);
    end;
  if CodeHi <= CodeLo then
    raise Exception.Create('no executable section');
  SetLength(Flags, CodeHi - CodeLo + 16);
  SetLength(Cls, CodeHi - CodeLo + 16);

  Reader := TTD32FileReader.Create;
  Reader.LoadFromFile(FPath);
  if not Reader.Loaded then
    raise Exception.Create('no TD32 debug information in ' + FPath);
  var LoadMs := Clock.ElapsedMilliseconds;

  if OutDir <> '' then begin
    ForceDirectories(OutDir);
    DetUnconf := TDetail.Create(MaxList);
    DetOrphan := TDetail.Create(MaxList);
    DetTable := TDetail.Create(MaxList);
    DetMulti := TDetail.Create(MaxList);
    DetIndJmp := TDetail.Create(MaxList);
    DetIncomplete := TDetail.Create(MaxList);
    DetPush := TDetail.Create(MaxList);
  end;

  ParseRelocs;
  ParseImports;
  ParseExports;
  ParsePdata;
  BuildUnits;
  var PrepMs := Clock.ElapsedMilliseconds;

  var Analysed := 0;
  for var I := 0 to High(Units) do begin
    if (Sample > 1) and (I mod Sample <> 0) then
      Continue;
    AnalyseUnit(Units[I]);
    Inc(Analysed);
  end;
  for var I := 0 to High(Units) do begin
    if (Sample > 1) and (I mod Sample <> 0) then
      Continue;
    TallyUnit(Units[I]);
  end;
  ClassifyOrphans;
  var AnalyseMs := Clock.ElapsedMilliseconds;

  { ---- header ---- }
  Writeln('=== LineSiteSurvey: ', FPath, ' ===');
  Writeln(Format('%s, image base $%x, code:%s', [IfThen(Is64, 'x64 (dcc64)', 'x86 (dcc32)'), ImageBase, SecList]));
  Writeln(Format('base relocations %d (%d in code), import slots %d, exports %d, .pdata entries %d',
    [RelocTotal, RelocInCode, FImports.Count, FExports.Count, Length(PdBegin)]));
  Writeln(ZydisStatusText);
  if Sample > 1 then
    Writeln(Format('*** SAMPLED: every %dth range analysed (%d of %d). Sections 3-7 are SAMPLED counts. ***',
      [Sample, Analysed, Length(Units)]));

  { ---- 1 ---- }
  Writeln;
  Writeln('[1] counts');
  var Keys := Copy(RecKey);
  TArray.Sort<UInt64>(Keys);
  var DistinctLines := 0;
  for var I := 0 to High(Keys) do
    if (I = 0) or (Keys[I] <> Keys[I - 1]) then
      Inc(DistinctLines);
  Writeln(Format('  line records = distinct RVAs (the reader keeps one line per RVA; raw pair count not exposed)  %d', [Length(Recs)]));
  Writeln(Format('  distinct (file, line)                                  %d', [DistinctLines]));
  Writeln(Format('  distinct (routine, file, line)                         %d%s', [LinesInRoutines, IfThen(Sample > 1, '  (SAMPLED)', '')]));
  Writeln(Format('  routines seen (TD32 procedures owning >= 1 record)     %d', [RoutinesSeen]));
  Writeln(Format('  source files (base names) in the line table            %d  (the reader lists %d)', [FileNames.Count,
    Length(Reader.GetSourceFiles)]));
  if NotInCode > 0 then
    Writeln(Format('  records outside the executable sections                %d', [NotInCode]));
  if SplitRoutines > 0 then
    Writeln(Format('  procedure ranges met again after another range         %d', [SplitRoutines]));
  var FileCount := Length(Reader.GetSourceFiles);
  if Int64(FileCount) * 65535 <= 40000000 then begin
    // The (file, line) table is not enumerable, but it can be asked line by line.
    var Known := 0;
    for var FileName in Reader.GetSourceFiles do
      for var L := 1 to 65535 do begin
        var Rva: UInt64;
        if Reader.SourceLineToRva(FileName, L, Rva) then
          Inc(Known);
      end;
    Writeln(Format('  (file, line) pairs SourceLineToRva knows               %d  (%d more than the RVA table shows: lines sharing an RVA with another line)',
      [Known, Known - DistinctLines]));
  end
  else
    Writeln('  (file, line) pairs SourceLineToRva knows               not probed (too many files for a line-by-line sweep)');

  { ---- 2 ---- }
  Writeln;
  Writeln('[2] records outside every TD32 procedure range');
  Writeln(Format('  %d of %d (%s)', [OrphanRecs, Length(Recs), Pct(OrphanRecs, Length(Recs)).Trim]));
  PrintDict(OrphanKinds, '  ');
  Writeln(Format('  of them: target of a direct jump or call from an analysed routine %d, exported %d', [OrphanExtTgt, OrphanExported]));
  if Is64 then begin
    Writeln(Format('  .pdata entries %d: BeginAddress is a TD32 procedure start %d, inside a TD32 procedure %d, ' +
      'outside every procedure %d (of which scope-table targets %d); chained %d',
      [Length(PdBegin), PdProcStart, PdInsideProc, PdOutside, PdOutsideTarget, PdChained]));
    Writeln('  UNWIND_INFO lives in:');
    PrintDict(UnwSections, '    ');
    Writeln('  language handlers:');
    for var H in Handlers.Keys do
      Writeln(Format('    %8d  $%.8x %s%s', [Handlers[H], H, CodeName(H), IfThen(DelphiHandlers.ContainsKey(H), '  <- scope tables decoded', '')]));
    Writeln(Format('  scope tables %d, entries %d, malformed %d, owned by a .pdata function with no TD32 procedure %d',
      [ScopeTables, ScopeEntries, ScopeMalformed, ScopeOwnersNoProc]));
    Writeln('  assumption 17 - where each handler entry sits relative to TD32 ranges   in its own procedure / in another / in none');
    for var K := 0 to 3 do
      Writeln(Format('    %-30s %9d %9d %9d', [A17_NAME[K], A17[K, 0], A17[K, 1], A17[K, 2]]));
    Writeln('  clause tables live in:');
    PrintDict(ClauseSections, '    ');
  end;

  ReportBucket('TD32 procedures', Bk[False]);
  ReportBucket('x64 .pdata functions outside every TD32 procedure (analysed from their BeginAddress)', Bk[True]);
  if UnconfByExt.Count > 0 then begin
    Writeln;
    Writeln('unconfirmed records by the extension of their source file (both groups):');
    PrintDict(UnconfByExt, '  ');
  end;

  { ---- 4 ---- }
  Writeln;
  Writeln('[4] records that point at a table rather than at code');
  var TblJmp := 0;
  var TblClause := 0;
  for var I := 0 to High(Recs) do begin
    if not InCode(Recs[I]) then
      Continue;
    var Fl := F(Cardinal(Recs[I]));
    if Fl and fData = 0 then
      Continue;
    if Fl and fClauseTbl <> 0 then
      Inc(TblClause)
    else
      Inc(TblJmp);
    if DetTable <> nil then
      DetTable.Add(Format('$%.8x  %s  %s  bytes=%s', [Cardinal(Recs[I]), LineOf(Cardinal(Recs[I])),
        IfThen(Fl and fClauseTbl <> 0, 'clause table', 'jump table'), HexBytes(Img.Ptr(Cardinal(Recs[I]), 8), 8)]));
  end;
  Writeln(Format('  in a recognised jump table %d, in a clause table %d', [TblJmp, TblClause]));
  if not Is64 then begin
    Writeln(Format('  x86 handler stubs found through `push imm32`: (clause tables after them %d, clauses %d; name/structure disagreements %d)',
      [ClauseTables86, Clauses86, ClauseNameMismatch]));
    PrintDict(StubKinds, '    ');
    Writeln(Format('  x86 try/finally continuations found through their push %d; ' +
      'pushed addresses inside the procedure range that are neither (data, e.g. string literals) %d',
      [PushedContinuations, PushedUnrecognised]));
    Writeln(Format('  x86 relocated pointers into their own routine in no instruction and no recognised table %d', [UnexplainedPtrs]));
  end;

  { ---- 5 ---- }
  Writeln;
  Writeln('[5] source lines with more than one record in the same routine', IfThen(Sample > 1, '  (SAMPLED)', ''));
  Writeln(Format('  %d of %d lines (%s); extra records %d; with 2 / 3 / 4 / 5+ records: %d / %d / %d / %d',
    [MultiLines, LinesInRoutines, Pct(MultiLines, LinesInRoutines).Trim, MultiExtra, MultiHist[0], MultiHist[1],
     MultiHist[2], MultiHist[3]]));
  Writeln(Format('  records of the line separated by records of other lines: %d; a record in another .pdata function (x64): %d',
    [MultiInterleaved, MultiFuncletCopy]));
  ClassifyMultiBySource;

  { ---- 7 ---- }
  Writeln;
  Writeln('[7] indirect jumps (FF /4) reached by the proven decode');
  var TotalInd: Int64 := ImportThunkJumps;
  for var Sh in Shapes.Values do
    Inc(TotalInd, Sh.Count);
  Writeln(Format('  total %d: through an import slot %d, through a recognised table %d (%d entries, %d with a byte index table), ' +
    'x86 finally exit %d (%d of them with no stub found behind), other %d',
    [TotalInd, ImportThunkJumps, TablesFound, TableEntries, IndexTables, FinallyJumps, FinallyJumpsNoStub,
     TotalInd - ImportThunkJumps - TablesFound - FinallyJumps]));
  Writeln(Format('  calls to System.@Halt0 taken as the end of a decode path: %d', [NoReturnCalls]));
  var ShapeKeys := Shapes.Keys.ToArray;
  TArray.Sort<string>(ShapeKeys, TComparer<string>.Construct(
    function(const A, B: string): Integer
    begin
      Result := CompareValue(Shapes[B].Count, Shapes[A].Count);
      if Result = 0 then
        Result := CompareStr(A, B);
    end));
  for var K in ShapeKeys do begin
    var Sh := Shapes[K];
    Writeln(Format('  %7d  %s%s', [Sh.Count, K, IfThen(Sh.Entries > 0, Format('   [%d entries]', [Sh.Entries]), '')]));
    var Ctxs := Sh.Contexts.Keys.ToArray;
    TArray.Sort<string>(Ctxs, TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := Sh.Contexts[B] - Sh.Contexts[A];
        if Result = 0 then
          Result := CompareStr(A, B);
      end));
    for var I := 0 to Min(High(Ctxs), 2) do
      Writeln(Format('           %6d x  %s', [Sh.Contexts[Ctxs[I]], Ctxs[I]]));
    if Length(Ctxs) > 3 then
      Writeln(Format('           (%d more preceding sequences)', [Length(Ctxs) - 3]));
    if DetIndJmp <> nil then begin
      DetIndJmp.Add(Format('%d x  %s', [Sh.Count, K]));
      for var Ex in Sh.Examples do
        DetIndJmp.Add(Ex);
    end;
  end;

  if OutDir <> '' then begin
    var Base := TPath.Combine(OutDir, Tag);
    DetUnconf.Save(Base + '.unconfirmed.txt', 'Unconfirmed line records: ' + FPath);
    DetOrphan.Save(Base + '.orphans.txt', 'Line records outside every TD32 procedure range: ' + FPath);
    DetTable.Save(Base + '.tablerecords.txt', 'Line records inside a recognised table: ' + FPath);
    DetMulti.Save(Base + '.multiline.txt', 'Source lines with more than one record in one routine: ' + FPath);
    DetIndJmp.Save(Base + '.indjmp.txt', 'Indirect jump shapes with examples: ' + FPath);
    DetIncomplete.Save(Base + '.incomplete.txt', 'Where a proven decode stopped: ' + FPath);
    DetPush.Save(Base + '.pointers.txt', 'x86 pushed / relocated routine addresses not explained: ' + FPath);
    Writeln;
    Writeln('detail listings: ', Base, '.*.txt');
  end;

  Writeln;
  Writeln(Format('time: load %d ms, directories and grouping %d ms, analysis %d ms, report %d ms, total %.1f s',
    [LoadMs, PrepMs - LoadMs, AnalyseMs - PrepMs, Clock.ElapsedMilliseconds - AnalyseMs, Clock.ElapsedMilliseconds / 1000]));
end;

{ ----------------------------------------------------------------- compare }

procedure CompareLineTables(RA, RB: TTD32FileReader; const NameA, NameB, DetailPath: string);
// Assumption 18: for every source file both binaries carry, do the two line
// tables name the same lines? A differing line is attributed to its routine,
// and the routine is looked for in the other binary's lines of the same file.
const
  MAXLINE = 65535;

  function NameAt(R: TTD32FileReader; Rva: UInt64): string;
  begin
    if not R.RvaToFunctionName(Rva, Result) then
      Result := Format('?%x', [Rva]);
  end;

begin
  var Det := TStringList.Create;
  var InB := TDictionary<string, Boolean>.Create;
  var Common := TList<string>.Create;
  try
    for var FileName in RB.GetSourceFiles do
      InB.AddOrSetValue(FileName, True);
    for var FileName in RA.GetSourceFiles do
      if InB.ContainsKey(FileName) and not Common.Contains(FileName) then
        Common.Add(FileName);
    Common.Sort;
    Writeln;
    Writeln('[8] -compare: do the two line tables name the same lines of the files they share (assumption 18)');
    Writeln('  A = ', NameA);
    Writeln('  B = ', NameB);
    Writeln(Format('  source files: A %d, B %d, in both %d', [Length(RA.GetSourceFiles), Length(RB.GetSourceFiles), Common.Count]));
    Writeln('  file                                lines A  lines B     both   only A (routine absent from B)   only B (routine absent from A)');
    var Identical := 0;
    var Compared := 0;
    var TotBoth: Int64 := 0;
    var TotOnlyA: Int64 := 0;
    var TotOnlyB: Int64 := 0;
    var TotOnlyAAbsent: Int64 := 0;
    var TotOnlyBAbsent: Int64 := 0;
    var RvaA, RvaB: TArray<UInt64>;
    SetLength(RvaA, MAXLINE + 1);
    SetLength(RvaB, MAXLINE + 1);
    for var FileName in Common do begin
      var RoutA := TDictionary<string, Boolean>.Create;
      var RoutB := TDictionary<string, Boolean>.Create;
      try
        var CntA := 0;
        var CntB := 0;
        for var L := 1 to MAXLINE do begin
          RvaA[L] := 0;
          RvaB[L] := 0;
          if RA.SourceLineToRva(FileName, L, RvaA[L]) then begin
            Inc(CntA);
            RoutA.AddOrSetValue(NameAt(RA, RvaA[L]), True);
          end;
          if RB.SourceLineToRva(FileName, L, RvaB[L]) then begin
            Inc(CntB);
            RoutB.AddOrSetValue(NameAt(RB, RvaB[L]), True);
          end;
        end;
        if (CntA = 0) and (CntB = 0) then
          Continue;
        Inc(Compared);
        var Both := 0;
        var OnlyA := 0;
        var OnlyB := 0;
        var OnlyAAbsent := 0;
        var OnlyBAbsent := 0;
        for var L := 1 to MAXLINE do begin
          if (RvaA[L] <> 0) and (RvaB[L] <> 0) then
            Inc(Both)
          else if RvaA[L] <> 0 then begin
            Inc(OnlyA);
            var Routine := NameAt(RA, RvaA[L]);
            var Absent := not RoutB.ContainsKey(Routine);
            if Absent then
              Inc(OnlyAAbsent);
            Det.Add(Format('%s:%d  only in A  routine=%s  %s', [FileName, L, Routine,
              IfThen(Absent, 'routine has no line in B', 'ROUTINE PRESENT IN B')]));
          end
          else if RvaB[L] <> 0 then begin
            Inc(OnlyB);
            var Routine := NameAt(RB, RvaB[L]);
            var Absent := not RoutA.ContainsKey(Routine);
            if Absent then
              Inc(OnlyBAbsent);
            Det.Add(Format('%s:%d  only in B  routine=%s  %s', [FileName, L, Routine,
              IfThen(Absent, 'routine has no line in A', 'ROUTINE PRESENT IN A')]));
          end;
        end;
        if (OnlyA = 0) and (OnlyB = 0) then
          Inc(Identical);
        Inc(TotBoth, Both);
        Inc(TotOnlyA, OnlyA);
        Inc(TotOnlyB, OnlyB);
        Inc(TotOnlyAAbsent, OnlyAAbsent);
        Inc(TotOnlyBAbsent, OnlyBAbsent);
        if (Common.Count <= 80) or (OnlyA + OnlyB > 0) then
          Writeln(Format('  %-34s %8d %8d %8d %8d (%d) %22d (%d)%s', [FileName, CntA, CntB, Both, OnlyA, OnlyAAbsent,
            OnlyB, OnlyBAbsent, IfThen((OnlyA = 0) and (OnlyB = 0), '   identical', '')]));
      finally
        RoutA.Free;
        RoutB.Free;
      end;
    end;
    Writeln(Format('  files compared %d, identical %d', [Compared, Identical]));
    Writeln(Format('  lines in both %d; only in A %d (routine absent from B %d, routine present in B %d); ' +
      'only in B %d (routine absent from A %d, routine present in A %d)',
      [TotBoth, TotOnlyA, TotOnlyAAbsent, TotOnlyA - TotOnlyAAbsent, TotOnlyB, TotOnlyBAbsent, TotOnlyB - TotOnlyBAbsent]));
    if DetailPath <> '' then begin
      Det.Insert(0, Format('Lines that differ. A = %s, B = %s', [NameA, NameB]));
      Det.SaveToFile(DetailPath, TEncoding.UTF8);
      Writeln('  detail: ', DetailPath);
    end;
  finally
    Common.Free;
    InB.Free;
    Det.Free;
  end;
end;

{ -------------------------------------------------------------------- main }

function ResolveZydisDll(const OverridePath: string): string;
// -zydisdll, then next to this exe, then ThirdParty\Zydis\bin\x64 of the
// repository this exe was built in (searched upwards, so a private output
// directory works too).
begin
  if OverridePath <> '' then
    Exit(OverridePath);
  var Dir := ExtractFileDir(ParamStr(0));
  Result := TPath.Combine(Dir, 'Zydis.dll');
  if FileExists(Result) then
    Exit;
  for var Up := 1 to 6 do begin
    Dir := ExtractFileDir(Dir);
    if Dir = '' then
      Break;
    Result := TPath.Combine(Dir, 'ThirdParty\Zydis\bin\x64\Zydis.dll');
    if FileExists(Result) then
      Exit;
  end;
  Result := '';
end;

procedure Main;
begin
  FormatSettings.DecimalSeparator := '.';
  var Target := '';
  var OutDir := '';
  var CompareWith := '';
  var ZydisDll := '';
  var Sample := 1;
  var MaxList := 20000;
  var SrcDirs: TArray<string> := [];
  var I := 1;
  while I <= ParamCount do begin
    var A := ParamStr(I);
    var HasValue := I < ParamCount;
    if SameText(A, '-out') and HasValue then begin
      OutDir := ParamStr(I + 1);
      Inc(I);
    end
    else if SameText(A, '-src') and HasValue then begin
      SrcDirs := SrcDirs + [ParamStr(I + 1)];
      Inc(I);
    end
    else if SameText(A, '-compare') and HasValue then begin
      CompareWith := ParamStr(I + 1);
      Inc(I);
    end
    else if SameText(A, '-sample') and HasValue then begin
      Sample := Max(1, StrToIntDef(ParamStr(I + 1), 1));
      Inc(I);
    end
    else if SameText(A, '-maxlist') and HasValue then begin
      MaxList := StrToIntDef(ParamStr(I + 1), MaxList);
      Inc(I);
    end
    else if SameText(A, '-zydisdll') and HasValue then begin
      ZydisDll := ParamStr(I + 1);
      Inc(I);
    end
    else if Target = '' then
      Target := A
    else
      raise Exception.Create('unexpected argument: ' + A);
    Inc(I);
  end;
  if Target = '' then begin
    Writeln('Usage: LineSiteSurvey.exe <exe-or-bpl> [-out <dir>] [-src <dir>]... [-compare <other>] [-sample N] [-maxlist N] [-zydisdll <path>]');
    Halt(1);
  end;
  if not FileExists(Target) then
    raise Exception.Create('file not found: ' + Target);
  if not ZydisTryLoad(ResolveZydisDll(ZydisDll)) then
    raise Exception.Create(ZydisStatusText);

  var Survey := TSurvey.Create(Target);
  try
    Survey.OutDir := OutDir;
    Survey.SrcDirs := SrcDirs;
    Survey.Sample := Sample;
    Survey.MaxList := MaxList;
    Survey.Run;
    if CompareWith <> '' then begin
      if not FileExists(CompareWith) then
        raise Exception.Create('file not found: ' + CompareWith);
      var Other := TTD32FileReader.Create;
      try
        Other.LoadFromFile(CompareWith);
        if not Other.Loaded then
          raise Exception.Create('no TD32 debug information in ' + CompareWith);
        var DetailPath := '';
        if OutDir <> '' then
          DetailPath := TPath.Combine(OutDir, Survey.Tag + '.compare.txt');
        CompareLineTables(Survey.Reader, Other, Target, CompareWith, DetailPath);
      finally
        Other.Free;
      end;
    end;
  finally
    Survey.Free;
  end;
end;

begin
  try
    Main;
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.ClassName, ': ', E.Message);
      Halt(9);
    end;
  end;
end.
