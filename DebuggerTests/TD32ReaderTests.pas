unit TD32ReaderTests;

// Low-level unit tests for TTD32FileReader. Exercises:
//   * Itanium demangler (pure, no I/O)
//   * Line table forward/reverse on TestTarget.exe
//   * Proc name resolution (Class.Method, top-level, ctor/dtor, init)
//   * Global symbol lookup
//   * BPREL32 locals (when ExposeLocals is on)
//
// These tests catch regressions that would otherwise hide behind the
// MAP-file fallback: if TD32 returns junk, the integration suite stays
// green because the next provider in line patches things up.

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TTD32ReaderTests = class
  private
    function ExePath: string;
    function BplPath: string;
    function SyntheticAppendedBlobBinary(UseCppBuilderSignature: Boolean): string;
  public
    // --- Demangler (pure) ---
    // A bare identifier must not resolve to a member of a class-nested enum,
    // while unit-level and routine-local enums keep working.
    [Test] procedure NestedEnumMember_IsNotBareVisible;
    [Test] procedure NestedTypeDetection_SeparatesUnitRoutineAndClass;
    [Test] procedure Demangle_TopLevelProc_DropsUnit;
    [Test] procedure Demangle_ClassMethod_KeepsClassDotMethod;
    [Test] procedure Demangle_Constructor_C3_BecomesCreate;
    [Test] procedure Demangle_Destructor_D0_BecomesDestroy;
    [Test] procedure Demangle_Initialization_BecomesUnit;
    [Test] procedure Demangle_Finalization_BecomesUnit;
    [Test] procedure Demangle_NonMangled_ReturnsFalse;

    // --- Container location and dialect ---
    // The blob does not have to live in a `.debug` section: it can be appended
    // past the image with nothing describing it, in which case only the trailer
    // at the end of the FILE can find it.
    [Test] procedure AppendedBlob_WithNoDebugSection_LoadsIdentically;
    // C++Builder stamps the same container 'FB0A'. No C++Builder binary exists
    // here, so the dialect is exercised by restamping a Delphi one: this tests
    // that the signature is ACCEPTED, and claims nothing about demangling.
    [Test] procedure CppBuilderSignature_IsAccepted;
    [Test] procedure ContainerSignature_OfDelphiBinary_IsFB09;

    // --- Declared signatures (type table, not symbols) ---
    // The parameter list a routine DECLARES, decoded from its own signature
    // record. Independent of whether the routine has local symbols, which is
    // the point: it answers for frames the BPREL32 records do not describe.
    [Test] procedure ProcSignature_FreeFunction_ReportsDeclaredParams;
    [Test] procedure ProcSignature_Method_ReportsSelfSeparately;

    // --- Reader against TestTarget.exe ---
    [Test] procedure Loads_TestTargetExe;
    [Test] procedure LineTable_HasEntries;
    [Test] procedure LineTable_ForwardKnownRva;
    [Test] procedure LineTable_ReverseKnownLine;
    [Test] procedure FuncName_TopLevelProc_Resolves;
    [Test] procedure FuncName_ClassMethod_Resolves;
    [Test] procedure FuncStart_WithinFunctionRange;
    [Test] procedure NameToRva_KnownFunction_RoundTrips;
    [Test] procedure NameToRva_SuffixMatch_FindsUstrasg;
    [Test] procedure NameToRva_SuffixMatch_FindsNow;
    [Test] procedure Globals_HaveExitProc;
    [Test] procedure Globals_HaveEntries;
    [Test] procedure Globals_NameToRva_FindsExitProc;
    // IUnitScopedGlobalProvider: GSharedAmbiguous is declared in BOTH
    // TestTargetConflict1 (Integer) and TestTargetConflict2 (Double). The flat
    // FindGlobal/NameToRva keep the first-hit; only the unit-scoped lookup
    // (ALIGN_SYMBOLS ModIndex -> SOURCE_MODULE unit) tells them apart.
    [Test] procedure Globals_UnitScoped_DisambiguatesCollidingGlobal;
    [Test] procedure Locals_OptIn_ReturnsParametersForKnownProc;
    [Test] procedure Locals_Default_OptedOut;

    // --- TYPES / GLOBAL_TYPES type table ---
    [Test] procedure Types_TStuff_Resolves;
    [Test] procedure Types_TWidget_Resolves;
    [Test] procedure Types_TBareClass_Resolves;
    [Test] procedure Types_TObject_Resolves;
    [Test] procedure Types_ExceptionClass_Resolves;
    // Two classes named "TDup" (TCollideOuterA.TDup / TCollideOuterB.TDup) share
    // a bare name but have different sizes; GetClassMembers must pick the record
    // whose declared size matches the requested instance size. This is the
    // mechanism behind the live Data.DB.TFields vs TFieldsCache.TFields fix.
    [Test] procedure GetClassMembers_SizeHint_PicksTheMatchingRecord;
    // A property member must carry its RETURN type's kind/size, resolved by the
    // exact CV type id (not the descriptor id, not a re-lookup by name). This is
    // what lets the evaluator pick a getter's return ABI deterministically.
    [Test] procedure GetClassMembers_PropertyReturn_KindAndSizeResolvedById;
    // Currency ($04) and Real48 ($44) are TD32 primitives the id tables used to
    // skip: Real48 resolved to an EMPTY type name and both resolved to a ZERO
    // byte size. Unlike TDateTime (a Double alias the compiler flattens onto
    // $41, unrecoverable from TD32) these are distinct primitive ids, so the
    // information is present and was simply not decoded.
    [Test] procedure PrimitiveIds_CurrencyAndReal48_HaveNameAndSize;
    // An IDE-built package stores method names with NO leading '@', i.e. no unit
    // component: `TFrmColumns@Create`. The anchored-only demangler rejected that
    // shape, so the raw name reached the call stack (reported from the field on
    // QBFDesignD29.bpl). Both shapes must present as `Class.Method`.
    [Test] procedure Demangle_Borland_UnanchoredClassMethod_BecomesDotted;
    // A free function's declared parameter count, from its LF_PROCEDURE
    // signature. Lets the evaluator refuse to auto-call a bare `Foo` that
    // actually takes arguments (F1). Also validates the GPROC32 proctype offset.
    [Test] procedure FreeFunctionParamCount_ResolvesFromLfProcedure;
    [Test] procedure Types_LookupTypeKind_Class;
    [Test] procedure Types_PointerToClass_StripsCaret;

    // --- PE import table parsing ---
    [Test] procedure Imports_KernelExports_Resolve;
    [Test] procedure Imports_Multiple_NamesRegisterDistinctRvas;

    // --- TD32 in BPL .bpl files ---
    [Test] procedure Bpl_LoadsTd32Section;
    [Test] procedure Bpl_HasProcSymbols;
    [Test] procedure Bpl_ImportsResolve;

    // --- Demangler extensions ---
    [Test] procedure Demangle_BorlandPrefix_ZTR_Stripped;
    [Test] procedure Demangle_BorlandPrefix_ZTI_Stripped;
    [Test] procedure Demangle_Template_RendersAngleBrackets;
    [Test] procedure Demangle_Substitution_BackReference;
    [Test] procedure Demangle_Operator_Plus_RendersFriendly;
    [Test] procedure Demangle_Empty_ReturnsFalse;

    // --- FIELDLIST decoder ---
    [Test] procedure Fields_TStuff_HasFNameAtOffset16;
    [Test] procedure Fields_TWidget_FieldsAtExpectedOffsets;
    [Test] procedure Fields_TBareClass_DecodedSomeFields;

    // --- Primitive TypeIds (<$1000) ---
    [Test] procedure Primitive_Integer_ResolvedAs_Integer;
    [Test] procedure Primitive_Cardinal_ResolvedAs_Cardinal;
    [Test] procedure Primitive_Boolean_ResolvedAs_Boolean;

    // --- TypeId encoding ---
    [Test] procedure TypeId_FirstRecord_IsBias1000;

    // --- LF_PROCEDURE / LF_MFUNCTION ---
    [Test] procedure Types_DoCalcInt_ProcedureRecord;

    // --- $0030..$003A passthrough ---
    [Test] procedure PropertyDescriptor_UnwrapsToUnderlyingType;

    // --- Source-line nearest-previous fallback ---
    // RvaToSourceLine must resolve arbitrary RIPs (e.g. return
    // addresses one or two instructions past the last decoded line
    // entry) to the previous line, not return False. Without this,
    // stack-frame source paths surface as "unknown source" in
    // VS Code (bug observed on SampleApp nested-proc frames).
    [Test] procedure SourceLine_RvaInsideLine_ResolvesExact;
    [Test] procedure SourceLine_RvaOffByOne_FallsBackToPrevious;

    // --- External .tds (dcc64 -VT) via LoadFromTdsFile ---
    // TdsSample.exe has NO embedded .debug; its CodeView blob is the standalone
    // TdsSample.tds. The reader must resolve function + line from it exactly as
    // from an embedded section (proves the -VT address convention handling).
    [Test] procedure Tds_ResolvesFunctionAndLine;
    [Test] procedure Tds_NameToRva_RoundTrips;

    // --- Concurrent readers ---
    // ONE reader instance, several threads asking it questions at once, every
    // answer compared against a single-threaded baseline. The reader has no
    // lock of any kind: it is shared by every consumer of a module's symbols
    // and handed to the dispatch thread by the symbol prefetcher on the
    // strength of being immutable once loaded.
    //
    // These exist to FAIL if that stops being true. A lookup path that starts
    // filling something in on first use -- a memoised name, a decoded record, a
    // cache dictionary -- reintroduces exactly the defect the NAMES table
    // comment records: two threads racing a dynamic-array realloc, and an `Add`
    // raising a duplicate key out of a stack trace. Written BEFORE making
    // anything lazy, so they are a net rather than a description.
    [Test] procedure Concurrent_LocalsAndTypes_AgreeWithSingleThreaded;
    [Test] procedure Concurrent_LineLookups_AgreeWithSingleThreaded;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  TD32FileReader,
  DebugInfoTypes;

function TTD32ReaderTests.ExePath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TestTarget.exe';
  if not TFile.Exists(Result) then
    Assert.Fail('TestTarget.exe not found at ' + Result +
                ' -- run build_target.bat first');
end;

function TTD32ReaderTests.BplPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..\..\TestPackage\Win64\Debug\TestPackage.bpl';
  if not TFile.Exists(Result) then
    Assert.Fail('TestPackage.bpl not found at ' + Result +
                ' -- run build_target.bat first');
end;

function TTD32ReaderTests.SyntheticAppendedBlobBinary(UseCppBuilderSignature: Boolean): string;
// Produces a temporary binary whose CodeView blob is APPENDED past the image,
// with no section describing it.
//
// No file is assembled by hand: in TestTarget.exe the `.debug` section is
// already the last one and already ends exactly at EOF, so deleting its 40-byte
// section HEADER (and decrementing NumberOfSections) leaves every byte of debug
// info exactly where it was. What remains is a binary the section walk cannot
// find anything in, and that only the trailer at the end of the file can locate
// -- which is the layout under test.
const
  SIG_DELPHI = $39304246;  // 'FB09'
  SIG_BCB    = $41304246;  // 'FB0A'
begin
  var Bytes := TFile.ReadAllBytes(ExePath);
  var PeOff: Cardinal := PCardinal(@Bytes[$3C])^;
  var NumSections: PWord := PWord(@Bytes[PeOff + 6]);
  var OptSize: Word := PWord(@Bytes[PeOff + 20])^;
  var LastHdr: Cardinal := PeOff + 24 + OptSize + (NumSections^ - 1) * 40;

  var SecName: AnsiString;
  SetString(SecName, PAnsiChar(@Bytes[LastHdr]), 6);
  if SecName <> '.debug' then
    Assert.Fail('TestTarget.exe no longer ends with a .debug section (found "' +
                string(SecName) + '") -- this test builds its fixture by deleting that header');

  var RawSize: Cardinal := PCardinal(@Bytes[LastHdr + 16])^;
  var RawOff:  Cardinal := PCardinal(@Bytes[LastHdr + 20])^;
  Assert.AreEqual(Int64(RawOff) + Int64(RawSize), Int64(Length(Bytes)),
    'the .debug section is expected to end at EOF for this fixture to be an appended blob');

  FillChar(Bytes[LastHdr], 40, 0);
  Dec(NumSections^);

  if UseCppBuilderSignature then begin
    var TrailerSig: PCardinal := PCardinal(@Bytes[Length(Bytes) - 8]);
    var OffBack: Cardinal := PCardinal(@Bytes[Length(Bytes) - 4])^;
    Assert.AreEqual(Cardinal(SIG_DELPHI), TrailerSig^, 'expected a Delphi-stamped fixture');
    TrailerSig^ := SIG_BCB;
    PCardinal(@Bytes[Cardinal(Length(Bytes)) - OffBack])^ := SIG_BCB;
  end;

  Result := TPath.Combine(TPath.GetTempPath,
    'td32_appended_' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '') + '.bin');
  TFile.WriteAllBytes(Result, Bytes);
end;

procedure TTD32ReaderTests.AppendedBlob_WithNoDebugSection_LoadsIdentically;
begin
  var Expected: Integer := 0;
  var Reference := TTD32FileReader.Create;
  try
    Reference.LoadFromFile(ExePath);
    Expected := Length(Reference.SortedRvas);
  finally
    Reference.Free;
  end;
  Assert.IsTrue(Expected > 0, 'reference load produced no line table');

  var Fixture := SyntheticAppendedBlobBinary(False);
  try
    var Reader := TTD32FileReader.Create;
    try
      Reader.LoadFromFile(Fixture);
      // Not merely "it loaded": the blob is found at the same place, so the
      // whole line table has to come out identical to the sectioned original.
      Assert.AreEqual<Integer>(Expected, Length(Reader.SortedRvas),
        'appended-blob load produced a different line table');
    finally
      Reader.Free;
    end;
  finally
    TFile.Delete(Fixture);
  end;
end;

procedure TTD32ReaderTests.CppBuilderSignature_IsAccepted;
begin
  var Fixture := SyntheticAppendedBlobBinary(True);
  try
    var Reader := TTD32FileReader.Create;
    try
      Reader.LoadFromFile(Fixture);
      Assert.AreEqual(Cardinal($41304246), Reader.ContainerSignature,
        'the reader did not report the C++Builder dialect it just parsed');
      Assert.IsTrue(Length(Reader.SortedRvas) > 0,
        'an FB0A-stamped container parsed to an empty line table');
    finally
      Reader.Free;
    end;
  finally
    TFile.Delete(Fixture);
  end;
end;

procedure TTD32ReaderTests.ContainerSignature_OfDelphiBinary_IsFB09;
begin
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ExePath);
    Assert.AreEqual(Cardinal($39304246), Reader.ContainerSignature);
  finally
    Reader.Free;
  end;
end;

// --- Concurrent readers ----------------------------------------------

type
  // Runs one closure on N threads and collects whatever went wrong. An
  // exception inside a thread is a RESULT here, not a crash: a race in the
  // reader surfaces as EListError or an access violation on a reallocated
  // array, and a test that let those escape would report "runner died" instead
  // of naming the defect.
  TParallelProbe = class
  private
    FFailures: TStringList;
    FLock:     TObject;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Fail(const Msg: string);
    procedure RunOnThreads(Count: Integer; const Work: TProc<Integer>);
    function  FailureText: string;
    function  FailureCount: Integer;
  end;

constructor TParallelProbe.Create;
begin
  inherited;
  FFailures := TStringList.Create;
  FLock     := TObject.Create;
end;

destructor TParallelProbe.Destroy;
begin
  FFailures.Free;
  FLock.Free;
  inherited;
end;

procedure TParallelProbe.Fail(const Msg: string);
begin
  TMonitor.Enter(FLock);
  try
    // Keep the first few only: a race usually produces thousands of identical
    // lines and the message has to stay readable.
    if FFailures.Count < 10 then
      FFailures.Add(Msg);
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TParallelProbe.FailureText: string;
begin
  TMonitor.Enter(FLock);
  try
    Result := FFailures.Text;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TParallelProbe.FailureCount: Integer;
begin
  TMonitor.Enter(FLock);
  try
    Result := FFailures.Count;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TParallelProbe.RunOnThreads(Count: Integer; const Work: TProc<Integer>);
// Every thread waits on one gate and is released together. Staggered starts
// were measured to hide the very defect this is for: the first thread warms
// whatever a lazy path fills in, and the others then only read it, so the race
// window closes before the second thread arrives.
begin
  var Gate := TEvent.Create(nil, {ManualReset=}True, {InitialState=}False, '');
  try
    var Threads: TArray<TThread> := [];
    for var I := 0 to Count - 1 do begin
      var Index := I;
      var T := TThread.CreateAnonymousThread(
        procedure
        begin
          Gate.WaitFor(INFINITE);
          try
            Work(Index);
          except
            on E: Exception do
              Fail(Format('thread %d raised %s: %s', [Index, E.ClassName, E.Message]));
          end;
        end);
      T.FreeOnTerminate := False;
      Threads := Threads + [T];
    end;
    for var T in Threads do
      T.Start;
    Gate.SetEvent;          // release them all at once
    try
      for var T in Threads do
        T.WaitFor;
    finally
      for var T in Threads do
        T.Free;
    end;
  finally
    Gate.Free;
  end;
end;

procedure TTD32ReaderTests.Concurrent_LocalsAndTypes_AgreeWithSingleThreaded;
const
  THREADS    = 6;
  ITERATIONS = 8;
  ROUTINES   = 400;  // thousands of first-touch lookups, so a cold window exists
begin
  // TWO readers on purpose. The baseline pass would otherwise warm every
  // deferred lookup in the instance the threads then hammer, so a lazy path
  // that fills something in on first use would already be full by the time the
  // race could happen -- and the test would pass while being blind to exactly
  // the defect it exists for (measured: it did).
  var Baseline := TTD32FileReader.Create;
  var Reader   := TTD32FileReader.Create;
  var Probe    := TParallelProbe.Create;
  try
    Baseline.ExposeLocals := True;
    Baseline.LoadFromFile(ExePath);
    Reader.ExposeLocals := True;
    Reader.LoadFromFile(ExePath);

    // Baseline, single-threaded, on the instance the threads never touch.
    var Names := Baseline.AllProcedureNames;
    Assert.IsTrue(Length(Names) > ROUTINES, 'not enough routines to probe');
    var Subjects: TArray<string> := [];
    var Expected: TArray<string> := [];
    for var I := 0 to Length(Names) - 1 do begin
      if Length(Subjects) >= ROUTINES then
        Break;
      var Locals: TArray<TLocalSymbol>;
      if not Baseline.GetLocalsForFunction(Names[I], Locals) or (Length(Locals) = 0) then
        Continue;
      var Rendered := '';
      for var L in Locals do
        Rendered := Rendered + Format('%s|%s|%d|%d;',
          [L.Name, L.TypeHint, L.RbpOffset, Ord(L.ParamStatus)]);
      Subjects := Subjects + [Names[I]];
      Expected := Expected + [Rendered];
    end;
    Assert.IsTrue(Length(Subjects) >= 10,
      Format('expected routines with locals, found %d', [Length(Subjects)]));

    // Now the same questions from several threads at once, each comparing
    // against its own copy of the baseline. Threads start at different points
    // in the list so they are not walking in lockstep.
    Probe.RunOnThreads(THREADS,
      procedure(ThreadIndex: Integer)
      begin
        for var Iteration := 0 to ITERATIONS - 1 do
          for var K := 0 to High(Subjects) do begin
            // Same order in every thread, deliberately: colliding on the SAME
            // key at the same moment is what a first-touch race needs.
            var Idx := K;
            var Locals: TArray<TLocalSymbol>;
            if not Reader.GetLocalsForFunction(Subjects[Idx], Locals) then begin
              Probe.Fail(Format('"%s" resolved single-threaded but not concurrently',
                [Subjects[Idx]]));
              Continue;
            end;
            var Rendered := '';
            for var L in Locals do
              Rendered := Rendered + Format('%s|%s|%d|%d;',
                [L.Name, L.TypeHint, L.RbpOffset, Ord(L.ParamStatus)]);
            if Rendered <> Expected[Idx] then
              Probe.Fail(Format('"%s": expected [%s] got [%s]',
                [Subjects[Idx], Expected[Idx], Rendered]));
          end;
      end);

    Assert.AreEqual<Integer>(0, Probe.FailureCount,
      'concurrent readers disagreed with the single-threaded answers:' +
      sLineBreak + Probe.FailureText);
  finally
    Probe.Free;
    Reader.Free;
    Baseline.Free;
  end;
end;

procedure TTD32ReaderTests.Concurrent_LineLookups_AgreeWithSingleThreaded;
const
  THREADS    = 6;
  ITERATIONS = 30;
  SAMPLES    = 400;
begin
  // Same two-reader split as the locals probe: the baseline must not warm the
  // instance the threads race on.
  var Baseline := TTD32FileReader.Create;
  var Reader   := TTD32FileReader.Create;
  var Probe    := TParallelProbe.Create;
  try
    Baseline.LoadFromFile(ExePath);
    Reader.LoadFromFile(ExePath);

    var Rvas := Baseline.SortedRvas;
    Assert.IsTrue(Length(Rvas) > SAMPLES, 'not enough line entries to probe');
    var Step := Length(Rvas) div SAMPLES;
    var Sample: TArray<UInt64> := [];
    var Expected: TArray<string> := [];
    var I := 0;
    while (I < Length(Rvas)) and (Length(Sample) < SAMPLES) do begin
      var Loc: TSourceLocation;
      if Baseline.RvaToSourceLine(Rvas[I], Loc) then begin
        Sample   := Sample + [Rvas[I]];
        Expected := Expected + [Format('%s:%d', [Loc.SourceFile, Loc.Line])];
      end;
      Inc(I, Step);
    end;
    Assert.IsTrue(Length(Sample) > 50, 'too few resolvable RVAs sampled');

    Probe.RunOnThreads(THREADS,
      procedure(ThreadIndex: Integer)
      begin
        for var Iteration := 0 to ITERATIONS - 1 do
          for var K := 0 to High(Sample) do begin
            var Idx := (K + ThreadIndex * 13 + Iteration) mod Length(Sample);
            var Loc: TSourceLocation;
            if not Reader.RvaToSourceLine(Sample[Idx], Loc) then begin
              Probe.Fail(Format('$%x resolved single-threaded but not concurrently',
                [Sample[Idx]]));
              Continue;
            end;
            var Got := Format('%s:%d', [Loc.SourceFile, Loc.Line]);
            if Got <> Expected[Idx] then
              Probe.Fail(Format('$%x: expected [%s] got [%s]',
                [Sample[Idx], Expected[Idx], Got]));
            // The reverse direction shares the file table with the forward one,
            // so it belongs in the same race.
            var Back: UInt64;
            if not Reader.SourceLineToRva(Loc.SourceFile, Loc.Line, Back) then
              Probe.Fail(Format('%s:%d has no RVA concurrently',
                [Loc.SourceFile, Loc.Line]));
          end;
      end);

    Assert.AreEqual<Integer>(0, Probe.FailureCount,
      'concurrent line lookups disagreed with the single-threaded answers:' +
      sLineBreak + Probe.FailureText);
  finally
    Probe.Free;
    Reader.Free;
    Baseline.Free;
  end;
end;

// --- Declared signatures ---------------------------------------------

procedure TTD32ReaderTests.ProcSignature_FreeFunction_ReportsDeclaredParams;
begin
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(Reader.NameToRva('EdgeFactorial', Rva), 'EdgeFactorial not found');
    var Params: TArray<TMethodParam>;
    var HasSelf: Boolean;
    Assert.IsTrue(Reader.TryGetProcSignatureByRva(Rva, Params, HasSelf),
      'no signature record for a plain function');
    Assert.IsFalse(HasSelf, 'a free function has no Self');
    Assert.AreEqual<Integer>(1, Length(Params), 'EdgeFactorial(N: Integer) takes one parameter');
    Assert.AreEqual('Integer', Params[0].TypeName);
  finally
    Reader.Free;
  end;
end;

procedure TTD32ReaderTests.ProcSignature_Method_ReportsSelfSeparately;
begin
  var Reader := TTD32FileReader.Create;
  try
    Reader.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(Reader.NameToRva('TWidget.Sum5', Rva), 'TWidget.Sum5 not found');
    var Params: TArray<TMethodParam>;
    var HasSelf: Boolean;
    Assert.IsTrue(Reader.TryGetProcSignatureByRva(Rva, Params, HasSelf),
      'no signature record for a method');
    // Self is reported as a flag, never as a parameter: a declaration does not
    // list it, and a caller counting ABI slots needs the two facts apart.
    Assert.IsTrue(HasSelf, 'an instance method takes a Self');
    Assert.AreEqual<Integer>(5, Length(Params), 'Sum5(A, B, C, D, E: Integer)');
    for var P in Params do
      Assert.AreEqual('Integer', P.TypeName);
  finally
    Reader.Free;
  end;
end;

// --- Demangler -------------------------------------------------------

procedure TTD32ReaderTests.Demangle_TopLevelProc_DropsUnit;
var Inner, Parent: string;
begin
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget12RunEvalTestsEv', Inner, Parent));
  Assert.AreEqual('RunEvalTests', Inner);
  Assert.AreEqual('', Parent,
    '2-part top-level proc must drop the unit prefix to match MAP convention');
end;

procedure TTD32ReaderTests.Demangle_ClassMethod_KeepsClassDotMethod;
var Inner, Parent: string;
begin
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget7TWidget11DoCalcInt64Ev', Inner, Parent));
  Assert.AreEqual('DoCalcInt64', Inner);
  Assert.AreEqual('TWidget', Parent,
    '3-part class method must expose the class as Parent');
end;

procedure TTD32ReaderTests.Demangle_Constructor_C3_BecomesCreate;
var Inner, Parent: string;
begin
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget6TStuffC3EiN6System13UnicodeStringE', Inner, Parent));
  Assert.AreEqual('Create', Inner, 'C3 (base ctor) must demangle to Create');
  Assert.AreEqual('TStuff', Parent);
end;

procedure TTD32ReaderTests.Demangle_Destructor_D0_BecomesDestroy;
var Inner, Parent: string;
begin
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget6TStuffD0Ev', Inner, Parent));
  Assert.AreEqual('Destroy', Inner, 'D0 (base dtor) must demangle to Destroy');
  Assert.AreEqual('TStuff', Parent);
end;

procedure TTD32ReaderTests.Demangle_Initialization_BecomesUnit;
var Inner, Parent: string;
begin
  // Delphi emits the program's initialization block as a 2-part nested
  // name whose Inner is `initialization`. RSM keys those locals by the
  // unit name itself, so the demangler must rewrite Inner to the unit.
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget14initializationEv', Inner, Parent));
  Assert.AreEqual('Testtarget', Inner,
    'initialization must map to the unit name (matches RSM key)');
  Assert.AreEqual('', Parent);
end;

procedure TTD32ReaderTests.Demangle_Finalization_BecomesUnit;
var Inner, Parent: string;
begin
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget12finalizationEv', Inner, Parent));
  Assert.AreEqual('Testtarget', Inner);
  Assert.AreEqual('', Parent);
end;

procedure TTD32ReaderTests.Demangle_NonMangled_ReturnsFalse;
var Inner, Parent: string;
begin
  Assert.IsFalse(TTD32FileReader.DemangleItanium('PlainName', Inner, Parent));
end;

// --- Reader ----------------------------------------------------------

procedure TTD32ReaderTests.Loads_TestTargetExe;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.Pass;
  finally R.Free; end;
end;

procedure TTD32ReaderTests.LineTable_HasEntries;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(Length(R.SortedRvas) > 100,
      Format('expected >100 line entries, got %d', [Length(R.SortedRvas)]));
  finally R.Free; end;
end;

procedure TTD32ReaderTests.LineTable_ForwardKnownRva;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    // First line-table entry must resolve to one of the test target's
    // source files at a positive source line. The actual file depends on
    // unit link order (TestTargetCollider.pas was added after the
    // original assertion was written); accept any TestTarget* source.
    var Rvas := R.SortedRvas;
    Assert.IsTrue(Length(Rvas) > 0, 'TD32 must surface line entries');
    var Loc: TSourceLocation;
    Assert.IsTrue(R.RvaToSourceLine(Rvas[0], Loc),
      'first sorted RVA must resolve to a line entry');
    Assert.IsTrue(SameText(Loc.SourceFile, 'TestTarget.dpr') or
                  Loc.SourceFile.StartsWith('TestTarget', True),
      'source file should be a TestTarget* unit, got ' + Loc.SourceFile);
    Assert.IsTrue(Loc.Line > 0, 'line number should be positive');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.LineTable_ReverseKnownLine;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rvas := R.SortedRvas;
    Assert.IsTrue(Length(Rvas) > 0);
    var Loc: TSourceLocation;
    Assert.IsTrue(R.RvaToSourceLine(Rvas[0], Loc));
    var Rva: UInt64;
    Assert.IsTrue(R.SourceLineToRva(Loc.SourceFile, Loc.Line, Rva),
      'reverse lookup must succeed');
    Assert.AreEqual(Rvas[0], Rva,
      'first RVA per line should be stable');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.FuncName_TopLevelProc_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('RunBpTests', Rva),
      'RunBpTests must be resolvable');
    var Name: string;
    Assert.IsTrue(R.RvaToFunctionName(Rva, Name));
    Assert.AreEqual('RunBpTests', Name,
      'top-level proc must come out without unit prefix');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.FuncName_ClassMethod_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('TWidget.DoCalcInt64', Rva),
      'TWidget.DoCalcInt64 must be resolvable');
    var Name: string;
    Assert.IsTrue(R.RvaToFunctionName(Rva, Name));
    Assert.AreEqual('TWidget.DoCalcInt64', Name);
  finally R.Free; end;
end;

procedure TTD32ReaderTests.FuncStart_WithinFunctionRange;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Entry: UInt64;
    Assert.IsTrue(R.NameToRva('RunBpTests', Entry));
    // An RVA a few bytes into the proc must still resolve back to the
    // proc's entry RVA.
    var Funcrva: UInt64;
    Assert.IsTrue(R.RvaToFunctionStart(Entry + 5, Funcrva),
      'RVA inside RunBpTests must find a containing proc');
    Assert.AreEqual(Entry, Funcrva,
      'RvaToFunctionStart must return the proc entry, not the queried RVA');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.NameToRva_KnownFunction_RoundTrips;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    for var Nm in ['RunEvalTests', 'RunExceptionTest', 'TStuff.Create',
                   'TWidget.GetSelf', 'TSink.Use'] do begin
      var Rva: UInt64;
      Assert.IsTrue(R.NameToRva(Nm, Rva),
        Format('TD32 must resolve %s -> RVA', [Nm]));
      var Back: string;
      Assert.IsTrue(R.RvaToFunctionName(Rva, Back),
        Format('TD32 must round-trip %s', [Nm]));
      Assert.IsTrue(SameText(Back, Nm),
        Format('round-trip %s -> %s', [Nm, Back]));
    end;
  finally R.Free; end;
end;

procedure TTD32ReaderTests.NameToRva_SuffixMatch_FindsUstrasg;
begin
  // String setVariable goes through `@UStrAsg`, which TD32 stores as
  // `system.@ustrasg`. Suffix match must resolve the unqualified form.
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('@UStrAsg', Rva),
      'suffix match must find System.@UStrAsg');
    Assert.IsTrue(Rva > 0, '@UStrAsg RVA must be > 0');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.NameToRva_SuffixMatch_FindsNow;
begin
  // Watch panel ``Now`` resolves via suffix lookup over SysUtils.Now.
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('Now', Rva),
      'suffix match must find SysUtils.Now');
    Assert.IsTrue(Rva > 0, 'Now RVA must be > 0');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Globals_HaveExitProc;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var G: TGlobalSymbol;
    Assert.IsTrue(R.FindGlobal('ExitProc', G),
      'TD32 must find the standard ExitProc global');
    Assert.IsTrue(G.RVA > 0, 'ExitProc RVA should be > 0');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Globals_HaveEntries;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(Length(R.GetGlobals) > 20,
      Format('expected >20 globals, got %d', [Length(R.GetGlobals)]));
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Globals_NameToRva_FindsExitProc;
// EvaluateGlobalName relies on NameToRva (the function-name lookup) to
// translate a symbolic global name into a memory address. Globals must be
// exposed there too, otherwise the expression evaluator returns "not found"
// for any global -- only function pointers / public symbols would resolve.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var GRva, NRva: UInt64;
    var G: TGlobalSymbol;
    Assert.IsTrue(R.FindGlobal('ExitProc', G), 'ExitProc must be a known global');
    Assert.IsTrue(R.NameToRva('ExitProc', NRva), 'NameToRva must also expose globals');
    GRva := G.RVA;
    Assert.AreEqual(GRva, NRva, 'NameToRva must return the same RVA as FindGlobal');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Globals_UnitScoped_DisambiguatesCollidingGlobal;
var
  G1, G2, GTmp: TGlobalSymbol;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);

    Assert.IsTrue(R.GlobalNameCollidesAcrossUnits('GSharedAmbiguous'),
      'GSharedAmbiguous (in both conflict units) must be flagged colliding');
    Assert.IsFalse(R.GlobalNameCollidesAcrossUnits('GConflict1Global'),
      'GConflict1Global is unique -- must NOT be flagged colliding');

    Assert.IsTrue(R.FindGlobalInUnit('GSharedAmbiguous', 'TestTargetConflict1', G1),
      'unit-scoped lookup must find GSharedAmbiguous in TestTargetConflict1');
    Assert.IsTrue(R.FindGlobalInUnit('GSharedAmbiguous', 'TestTargetConflict2', G2),
      'unit-scoped lookup must find GSharedAmbiguous in TestTargetConflict2');

    Assert.AreEqual('Integer', G1.TypeHint, 'unit 1 copy is Integer; got ' + G1.TypeHint);
    Assert.AreEqual('Double',  G2.TypeHint, 'unit 2 copy is Double; got '  + G2.TypeHint);
    Assert.IsTrue((G1.RVA <> 0) and (G2.RVA <> 0) and (G1.RVA <> G2.RVA),
      'the two units must resolve to DISTINCT global addresses');

    Assert.IsFalse(R.FindGlobalInUnit('GSharedAmbiguous', 'NoSuchUnitXYZ', GTmp),
      'lookup in an unknown unit must miss');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Locals_OptIn_ReturnsParametersForKnownProc;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    R.ExposeLocals := True;
    var Locs: TArray<TLocalSymbol>;
    Assert.IsTrue(R.GetLocalsForFunction('RunBpTests', Locs),
      'RunBpTests must have at least one BPREL32 local');
    // Every proc has a hidden Self/RetAddr-equivalent positive offset.
    var HasAny := False;
    for var L in Locs do
      if L.Name <> '' then begin HasAny := True; Break; end;
    Assert.IsTrue(HasAny, 'at least one local must have a name');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Locals_Default_OptedOut;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    // Default ExposeLocals=False: ILocalSymbolProvider must report no locals
    // so RSM (with richer type info) keeps primacy in the provider chain.
    var Locs: TArray<TLocalSymbol>;
    Assert.IsFalse(R.GetLocalsForFunction('RunBpTests', Locs),
      'with ExposeLocals=False, TD32 must NOT advertise locals');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_TStuff_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rec: TTD32TypeRecord;
    Assert.IsTrue(R.FindTypeByName('TStuff', Rec),
      'TStuff must resolve from the TD32 type table');
    Assert.AreEqual(Ord(tkClass), Ord(Rec.Kind), 'TStuff must be tkClass');
    Assert.IsTrue(Rec.Size > 0, 'TStuff must report a non-zero instance size');
    Assert.IsTrue(Rec.FieldListId >= $1000, 'TStuff must reference a fieldlist');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_TWidget_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rec: TTD32TypeRecord;
    Assert.IsTrue(R.FindTypeByName('TWidget', Rec),
      'TWidget must resolve from the TD32 type table');
    Assert.AreEqual(Ord(tkClass), Ord(Rec.Kind), 'TWidget must be tkClass');
    Assert.IsTrue(Rec.Size >= 8, 'TWidget instance must be at least 8 bytes');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_TBareClass_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rec: TTD32TypeRecord;
    Assert.IsTrue(R.FindTypeByName('TBareClass', Rec),
      'TBareClass must resolve from the TD32 type table');
    Assert.AreEqual(Ord(tkClass), Ord(Rec.Kind), 'TBareClass must be tkClass');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.GetClassMembers_SizeHint_PicksTheMatchingRecord;

  function HasField(const Members: TArray<TClassMember>; const Name: string): Boolean;
  begin
    Result := False;
    for var M in Members do
      if SameText(M.Name, Name) then Exit(True);
  end;

begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);

    // Find the two "TDup" records and their sizes.
    var SizeA := 0;
    var SizeB := 0;
    var Rec: TTD32TypeRecord;
    for var Tid := Cardinal($1000) to Cardinal($40000) do begin
      if not R.GetTypeRecord(Tid, Rec) then Continue;
      if not SameText(Rec.Name, 'TDup') then Continue;
      // A carries AlphaA/BetaA (small); B carries GammaB/DeltaB/EpsilonB (large).
      var HasAlpha := False;
      for var M in Rec.Members do
        if SameText(M.Name, 'AlphaA') then HasAlpha := True;
      if HasAlpha then SizeA := Integer(Rec.Size) else SizeB := Integer(Rec.Size);
    end;
    Assert.IsTrue((SizeA > 0) and (SizeB > 0), 'both TDup records must be present');
    Assert.AreNotEqual(SizeA, SizeB, 'the two TDup records must have different sizes');

    var MembersA: TArray<TClassMember>;
    Assert.IsTrue(R.GetClassMembers('TDup', MembersA, SizeA),
      'GetClassMembers(TDup, sizeA) must resolve');
    Assert.IsTrue(HasField(MembersA, 'AlphaA'),
      'size A must select TCollideOuterA.TDup (AlphaA)');
    Assert.IsFalse(HasField(MembersA, 'GammaB'),
      'size A must NOT select the other TDup (GammaB)');

    var MembersB: TArray<TClassMember>;
    Assert.IsTrue(R.GetClassMembers('TDup', MembersB, SizeB),
      'GetClassMembers(TDup, sizeB) must resolve');
    Assert.IsTrue(HasField(MembersB, 'GammaB'),
      'size B must select TCollideOuterB.TDup (GammaB)');
    Assert.IsFalse(HasField(MembersB, 'AlphaA'),
      'size B must NOT select the other TDup (AlphaA)');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.GetClassMembers_PropertyReturn_KindAndSizeResolvedById;

  function FindMember(const Members: TArray<TClassMember>;
    const Name: string; out M: TClassMember): Boolean;
  begin
    Result := False;
    for var Cand in Members do
      if SameText(Cand.Name, Name) then begin
        M := Cand;
        Exit(True);
      end;
  end;

begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Members: TArray<TClassMember>;
    Assert.IsTrue(R.GetClassMembers('TWidget', Members),
      'TWidget must resolve');

    var M: TClassMember;

    // AsBig: TPoint3D -> tkRecord (14), 24 bytes (3 x Double). Both come from the
    // property's return-type id; a fix that dropped it would leave them 0 / wrong.
    Assert.IsTrue(FindMember(Members, 'AsBig', M), 'AsBig property must be present');
    Assert.AreEqual(14, Integer(M.TypeKind), 'AsBig return kind must be tkRecord');
    Assert.AreEqual(24, M.TypeSize, 'AsBig return size must be SizeOf(TPoint3D)');

    // AsSet: TWorkModes -> tkSet (6), 1 byte.
    Assert.IsTrue(FindMember(Members, 'AsSet', M), 'AsSet property must be present');
    Assert.AreEqual(6, Integer(M.TypeKind), 'AsSet return kind must be tkSet');
    Assert.AreEqual(1, M.TypeSize, 'AsSet return size must be 1 (set of 4 values)');

    // AsClass: TObject -> tkClass (7).
    Assert.IsTrue(FindMember(Members, 'AsClass', M), 'AsClass property must be present');
    Assert.AreEqual(7, Integer(M.TypeKind), 'AsClass return kind must be tkClass');

    // A primitive-typed FIELD keeps TypeKind = 0 (by design: primitive names never
    // collide, so the name path owns them) but still resolves a byte size by id.
    Assert.IsTrue(FindMember(Members, 'FValue', M), 'FValue field must be present');
    Assert.AreEqual(0, Integer(M.TypeKind), 'a primitive field must leave TypeKind 0');
    Assert.AreEqual(4, M.TypeSize, 'FValue is an Integer -> 4 bytes');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Demangle_Borland_UnanchoredClassMethod_BecomesDotted;
var
  Inner, Parent: string;
begin
  // The shape from the field: no unit component, so BOTH parts are real scopes.
  Assert.IsTrue(TTD32FileReader.DemangleBorland('TFrmColumns@Create', Inner, Parent),
    'an unanchored Class@Method must demangle');
  Assert.AreEqual('Create', Inner);
  Assert.AreEqual('TFrmColumns', Parent);

  // With the parameter encoding attached, as a real record carries it.
  Assert.IsTrue(TTD32FileReader.DemangleBorland('TFrmColumns@Create$qqrp20System@TComponent',
    Inner, Parent), 'the $ suffix must be stripped');
  Assert.AreEqual('Create', Inner);
  Assert.AreEqual('TFrmColumns', Parent);

  // ANCHORED shapes are unchanged: the leading '@' still marks the unit, which
  // is dropped for a plain routine and kept out of a method's Class.Method.
  Assert.IsTrue(TTD32FileReader.DemangleBorland('@Testtargetedge@EdgeFactorial$qqri',
    Inner, Parent), 'unit + routine must still demangle');
  Assert.AreEqual('EdgeFactorial', Inner);
  Assert.AreEqual('', Parent, 'the unit must not become the parent scope');

  Assert.IsTrue(TTD32FileReader.DemangleBorland('@Forms@TApplication@Run$qqrv',
    Inner, Parent), 'unit + class + method must still demangle');
  Assert.AreEqual('Run', Inner);
  Assert.AreEqual('TApplication', Parent);

  // A name with no '@' at all is not mangled and must be left alone -- otherwise
  // every plain symbol would be rewritten.
  Assert.IsFalse(TTD32FileReader.DemangleBorland('PlainName', Inner, Parent),
    'a name with no separator is not Borland-mangled');

  // The initialization/finalization special case survives in both shapes.
  Assert.IsTrue(TTD32FileReader.DemangleBorland('@Testtarget@initialization', Inner, Parent));
  Assert.AreEqual('Testtarget', Inner, 'a unit main block reads as the unit name');
  Assert.IsTrue(TTD32FileReader.DemangleBorland('Testtarget@finalization', Inner, Parent));
  Assert.AreEqual('Testtarget', Inner);
end;

procedure TTD32ReaderTests.PrimitiveIds_CurrencyAndReal48_HaveNameAndSize;

  function FindMember(const Members: TArray<TClassMember>;
    const Name: string; out M: TClassMember): Boolean;
  begin
    Result := False;
    for var Cand in Members do
      if SameText(Cand.Name, Name) then begin
        M := Cand;
        Exit(True);
      end;
  end;

begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);

    // Real48 NAME. `ComputeNested` declares `R48: Real48`; its CV id is $0044 on
    // both bitnesses. Before the fix PrimitiveTypeName had no case for it, so the
    // hint came back '' and the variables view had no type to show.
    R.ExposeLocals := True;
    var Locs: TArray<TLocalSymbol>;
    Assert.IsTrue(R.GetLocalsForFunction('ComputeNested', Locs),
      'ComputeNested must expose its BPREL32 locals');
    var FoundR48 := False;
    for var L in Locs do
      if SameText(L.Name, 'R48') then begin
        FoundR48 := True;
        Assert.AreEqual('Real48', L.TypeHint,
          'a Real48 local must report its primitive name, not an empty hint');
      end;
    Assert.IsTrue(FoundR48, 'ComputeNested must declare the R48 local');

    // Currency SIZE. TypeSizeById feeds the evaluator's getter-return decoding,
    // so a 0 here is a wrong read width, not a cosmetic gap.
    var Members: TArray<TClassMember>;
    Assert.IsTrue(R.GetClassMembers('TWidget', Members), 'TWidget must resolve');
    var M: TClassMember;
    Assert.IsTrue(FindMember(Members, 'FArgCur', M), 'FArgCur field must be present');
    Assert.AreEqual(8, M.TypeSize, 'Currency is a scaled Int64 -> 8 bytes');
    Assert.IsTrue(FindMember(Members, 'AsCurr', M), 'AsCurr property must be present');
    Assert.AreEqual(8, M.TypeSize, 'a Currency-returning property must size at 8 bytes');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.FreeFunctionParamCount_ResolvesFromLfProcedure;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var C: Integer;
    // FreeAdd(A, B: Integer): Integer -> 2 params.
    Assert.IsTrue(R.TryGetFreeFunctionParamCount('FreeAdd', C),
      'FreeAdd must resolve as a free function');
    Assert.AreEqual(2, C, 'FreeAdd(A, B) declares 2 parameters');
    // FreeWrap(const S: string): string -> 1 param.
    Assert.IsTrue(R.TryGetFreeFunctionParamCount('FreeWrap', C),
      'FreeWrap must resolve as a free function');
    Assert.AreEqual(1, C, 'FreeWrap(S) declares 1 parameter');
    // Unknown name must fail cleanly (so the F1 gate stays inert for it).
    Assert.IsFalse(R.TryGetFreeFunctionParamCount('NoSuchFreeFunc____', C),
      'an unknown name must not resolve');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_TObject_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rec: TTD32TypeRecord;
    Assert.IsTrue(R.FindTypeByName('TObject', Rec),
      'TObject is the root class and must always be in the type table');
    Assert.AreEqual(Ord(tkClass), Ord(Rec.Kind), 'TObject must be tkClass');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_ExceptionClass_Resolves;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rec: TTD32TypeRecord;
    Assert.IsTrue(R.FindTypeByName('Exception', Rec),
      'Exception must resolve (System.SysUtils is linked)');
    Assert.AreEqual(Ord(tkClass), Ord(Rec.Kind));
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_LookupTypeKind_Class;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    // System.TypInfo.tkClass = 7
    Assert.AreEqual(7, Integer(R.LookupTypeKind('TStuff')),
      'LookupTypeKind for a class must return TTypeKind.tkClass');
    Assert.AreEqual(7, Integer(R.LookupTypeKind('TWidget')));
    Assert.AreEqual(7, Integer(R.LookupTypeKind('TObject')));
    Assert.AreEqual(0, Integer(R.LookupTypeKind('NoSuchType')),
      'unknown type must return 0');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Types_PointerToClass_StripsCaret;
// A Delphi `var Foo: TFoo` is internally a pointer to the class instance.
// GetTypeName for a POINTER-to-CLASS TypeId must return the bare class
// name (Delphi syntax), not '^TFoo'.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    // ExceptionClass is `var ExceptionClass: ExceptClass;` -- ExceptClass is
    // a metaclass reference (class of Exception) which surfaces as a
    // pointer-to-class in TD32.
    var G: TGlobalSymbol;
    if R.FindGlobal('MonitorSupport', G) then
      // MonitorSupport: PMonitorSupport (POINTER to a RECORD).
      // For pointer-to-record the '^' prefix must REMAIN.
      Assert.IsTrue(G.TypeHint.StartsWith('^'),
        'pointer-to-record must keep the caret, got: ' + G.TypeHint);
  finally R.Free; end;
end;

// --- PE import table --------------------------------------------------

procedure TTD32ReaderTests.Imports_KernelExports_Resolve;
// ParseImportTable walks the PE IMAGE_IMPORT_DESCRIPTOR array during
// LoadFromFile. After load, every named imported function must
// surface through NameToRva keyed by lowercase name.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('ExitProcess', Rva),
      'kernel32!ExitProcess is a guaranteed import of every Delphi EXE');
    Assert.IsTrue(Rva > 0, 'import RVA must be non-zero');
    Assert.IsTrue(R.NameToRva('GetProcessHeap', Rva),
      'kernel32!GetProcessHeap is imported by the Delphi RTL allocator');
    Assert.IsTrue(R.NameToRva('WriteFile', Rva),
      'kernel32!WriteFile is imported (used by stdout / file streams)');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Imports_Multiple_NamesRegisterDistinctRvas;
// Distinct imported functions must land at distinct IAT slots.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var RvaA, RvaB: UInt64;
    if R.NameToRva('ExitProcess', RvaA) and R.NameToRva('WriteFile', RvaB) then
      Assert.AreNotEqual(RvaA, RvaB,
        'distinct imports must occupy distinct IAT slots');
  finally R.Free; end;
end;

// --- TD32 in BPL ------------------------------------------------------

procedure TTD32ReaderTests.Bpl_LoadsTd32Section;
// dcc64 emits a .debug section into .bpl packages built with -V. The
// TD32 reader must accept the BPL the same way it accepts the EXE.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(BplPath);
    // No exception = load OK; sanity-check the line table is non-empty.
    Assert.IsTrue(Length(R.SortedRvas) > 0,
      'BPL must surface line-table entries through TD32');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Bpl_HasProcSymbols;
// The BPL's TD32 stream must carry at least one named procedure
// (initialization / finalization at minimum). RvaToFunctionStart on
// any RVA inside the BPL's code section must return that proc's
// entry RVA.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(BplPath);
    var Rvas := R.SortedRvas;
    Assert.IsTrue(Length(Rvas) > 0, 'BPL must have at least one line entry');
    var Rva := Rvas[0];
    var FuncStart: UInt64;
    Assert.IsTrue(R.RvaToFunctionStart(Rva, FuncStart),
      'first line-entry RVA must resolve to its enclosing function');
    Assert.IsTrue(FuncStart > 0, 'function start RVA must be non-zero');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Bpl_ImportsResolve;
// BPLs import a smaller surface than the main EXE (most RTL stubs
// come via the rtl package). GetLastError is one of the few direct
// kernel32 imports a Delphi package always pulls; it must surface
// through TD32's PE import-table walk on the BPL.
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(BplPath);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('GetLastError', Rva),
      'BPL must surface kernel32.GetLastError via TD32 PE import walk');
    Assert.IsTrue(Rva > 0, 'GetLastError IAT slot RVA must be non-zero');
  finally R.Free; end;
end;

// --- Demangler extensions --------------------------------------------

procedure TTD32ReaderTests.Demangle_BorlandPrefix_ZTR_Stripped;
var Inner, Parent: string;
begin
  // _ZTRN10Testtarget7TWidgetE -- typeref prefix wraps a nested name.
  // DecodeFriendlyTypeName strips '_ZTR' before demangling so the
  // surfaced name is the bare class identifier.
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget7TWidgetE', Inner, Parent),
    'underlying _ZN form must demangle once the _ZTR prefix is stripped');
  Assert.AreEqual('TWidget', Inner);
end;

procedure TTD32ReaderTests.Demangle_BorlandPrefix_ZTI_Stripped;
var Inner, Parent: string;
begin
  // _ZTIN6System10IInterfaceE -- typeinfo prefix variant.
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN6System10IInterfaceE', Inner, Parent));
  Assert.AreEqual('IInterface', Inner);
end;

procedure TTD32ReaderTests.Demangle_Template_RendersAngleBrackets;
var Inner, Parent: string;
begin
  // Generic instance: TList<Integer> mangles as
  // _ZN6System5TListIiEE -- name 'TList', then template-args 'IiE'
  // (i = built-in integer), closing E.
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN6System5TListIiEE', Inner, Parent),
    'generic instantiation must demangle');
  Assert.AreEqual('TList<Integer>', Inner,
    'template-args must render as <Type> in Delphi syntax');
end;

procedure TTD32ReaderTests.Demangle_Substitution_BackReference;
var Inner, Parent: string;
begin
  // Itanium S_ back-reference -- refers to the first remembered
  // component. Here `_ZN10Testtarget6TStuffES_E` would reference
  // 'Testtarget' as the inner name via S_; we accept either the
  // resolved substitution or a fallback string.
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN10Testtarget6TStuffE', Inner, Parent),
    'plain nested name demangles');
  Assert.AreEqual('TStuff', Inner);
end;

procedure TTD32ReaderTests.Demangle_Operator_Plus_RendersFriendly;
var Inner, Parent: string;
begin
  // Operator+ on a class: _ZN8MyVector2plE -> 'operator+' inner name.
  Assert.IsTrue(TTD32FileReader.DemangleItanium(
    '_ZN8MyVectorplE', Inner, Parent),
    'operator name should demangle');
  Assert.AreEqual('operator+', Inner);
end;

procedure TTD32ReaderTests.Demangle_Empty_ReturnsFalse;
var Inner, Parent: string;
begin
  Assert.IsFalse(TTD32FileReader.DemangleItanium('', Inner, Parent),
    'empty input must return False');
end;

// --- FIELDLIST decoder -----------------------------------------------

procedure TTD32ReaderTests.Fields_TStuff_HasFNameAtOffset16;
var Ms: TArray<TClassMember>;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.GetClassMembers('TStuff', Ms),
      'TStuff member list must be available through TD32');
    var Found := False;
    for var M in Ms do
      if SameText(M.Name, 'FLabel') and (M.FieldOffset = 16) then begin
        Found := True;
        Break;
      end;
    Assert.IsTrue(Found, 'TStuff.FLabel must surface at offset 16');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Fields_TWidget_FieldsAtExpectedOffsets;
var Ms: TArray<TClassMember>;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.GetClassMembers('TWidget', Ms),
      'TWidget member list must be available');
    var FoundName, FoundValue, FoundActive: Boolean;
    FoundName := False; FoundValue := False; FoundActive := False;
    for var M in Ms do begin
      if SameText(M.Name, 'FName')   and (M.FieldOffset = 8)  then FoundName   := True;
      if SameText(M.Name, 'FValue')  and (M.FieldOffset = 16) then FoundValue  := True;
      if SameText(M.Name, 'FActive') and (M.FieldOffset = 20) then FoundActive := True;
    end;
    Assert.IsTrue(FoundName,   'FName @ 8 expected');
    Assert.IsTrue(FoundValue,  'FValue @ 16 expected');
    Assert.IsTrue(FoundActive, 'FActive @ 20 expected');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Fields_TBareClass_DecodedSomeFields;
var Ms: TArray<TClassMember>;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.GetClassMembers('TBareClass', Ms),
      'TBareClass member list must be available');
    Assert.IsTrue(Length(Ms) > 0,
      'TBareClass should expose at least one field via TD32');
  finally R.Free; end;
end;

// --- Primitive TypeIds -----------------------------------------------

procedure TTD32ReaderTests.Primitive_Integer_ResolvedAs_Integer;
// CmdShow is `var CmdShow: Integer;` in System. Its global TypeHint
// must come back as 'Integer' after primitive-table lookup.
var G: TGlobalSymbol;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.FindGlobal('CmdShow', G), 'CmdShow must be a global');
    Assert.AreEqual('Integer', G.TypeHint,
      'CmdShow TypeHint must resolve through the primitive table');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Primitive_Cardinal_ResolvedAs_Cardinal;
// MainThreadID is `var MainThreadID: TThreadID;` -- TThreadID = LongWord = Cardinal.
var G: TGlobalSymbol;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.FindGlobal('MainThreadID', G),
      'MainThreadID must be a global');
    Assert.AreEqual('Cardinal', G.TypeHint,
      'MainThreadID TypeHint must resolve to Cardinal (= TThreadID)');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Primitive_Boolean_ResolvedAs_Boolean;
// IsLibrary is `var IsLibrary: Boolean;`.
var G: TGlobalSymbol;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.FindGlobal('IsLibrary', G),
      'IsLibrary must be a global');
    Assert.AreEqual('Boolean', G.TypeHint,
      'IsLibrary TypeHint must resolve to Boolean');
  finally R.Free; end;
end;

// --- TypeId encoding -------------------------------------------------

procedure TTD32ReaderTests.TypeId_FirstRecord_IsBias1000;
// TypeId = $1000 + recordIndex. The first record (idx 0) must
// answer to TypeId $1000.
var Rec: TTD32TypeRecord;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.GetTypeRecord($1000, Rec),
      'TypeId $1000 must map to record index 0');
    Assert.AreEqual(0, Rec.Index,
      'TypeId $1000 must be record index 0');
  finally R.Free; end;
end;

// --- LF_PROCEDURE / LF_MFUNCTION -------------------------------------

procedure TTD32ReaderTests.Types_DoCalcInt_ProcedureRecord;
// TWidget.DoCalcInt is a method whose existence we already exercise
// in DAP integration tests. Beyond surfacing the symbol, the TD32
// type table also carries an LF_PROCEDURE or LF_MFUNCTION record
// for its signature. We just sanity-check that some PROCEDURE /
// MFUNCTION records were decoded (every non-trivial Delphi binary
// has hundreds of these).
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Found := False;
    for var Tid: Cardinal := $1000 to $1100 do begin
      var Rec: TTD32TypeRecord;
      if R.GetTypeRecord(Tid, Rec) then
        if (Rec.Kind = tkProcedure) or (Rec.Kind = tkMFunction) then begin
          Found := True;
          Break;
        end;
    end;
    Assert.IsTrue(Found,
      'at least one tkProcedure / tkMFunction record in the first 256 type slots');
  finally R.Free; end;
end;

// --- $0030..$003A property descriptors -------------------------------

procedure TTD32ReaderTests.PropertyDescriptor_UnwrapsToUnderlyingType;
// TStuff.PubCount is a property reading FCount: Integer. After the
// $0030..$003A property descriptor passthrough, the surfaced
// TypeName for the property entry must be 'Integer' (the underlying
// type) rather than the empty descriptor record name.
var Ms: TArray<TClassMember>;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    Assert.IsTrue(R.GetClassMembers('TStuff', Ms),
      'TStuff member list must be available');
    var Found := False;
    for var M in Ms do
      if SameText(M.Name, 'PubCount') then begin
        Assert.AreEqual('Integer', M.TypeName,
          'TStuff.PubCount must surface its underlying Integer type');
        Found := True;
        Break;
      end;
    Assert.IsTrue(Found, 'TStuff.PubCount entry not found');
  finally R.Free; end;
end;

// --- Source-line nearest-previous ------------------------------------

procedure TTD32ReaderTests.SourceLine_RvaInsideLine_ResolvesExact;
// Sanity-check: when the input RVA is one of the compiler-emitted
// statement RVAs, the lookup hits via the direct dictionary path.
var Loc: TSourceLocation;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rvas := R.SortedRvas;
    Assert.IsTrue(Length(Rvas) > 0, 'must have at least one line entry');
    Assert.IsTrue(R.RvaToSourceLine(Rvas[0], Loc),
      'exact-RVA lookup must succeed');
    Assert.IsTrue(Loc.SourceFile <> '', 'exact hit must carry a file name');
    Assert.IsTrue(Loc.Line > 0, 'exact hit must carry a line number');
  finally R.Free; end;
end;

procedure TTD32ReaderTests.SourceLine_RvaOffByOne_FallsBackToPrevious;
// Critical case: a RIP that lands a few bytes PAST a known statement
// (typical of a return address after a CALL instruction) must
// resolve to that previous statement, not to "no entry" / empty
// source.
var
  LocExact, LocFallback: TSourceLocation;
begin
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(ExePath);
    var Rvas := R.SortedRvas;
    // Find a pair of adjacent entries (Rvas[i] then Rvas[i+1]); pick
    // a mid-RVA that's NOT in the dictionary and at most a few bytes
    // past Rvas[i].
    Assert.IsTrue(Length(Rvas) >= 2, 'need at least two line entries');
    var Anchor := Rvas[0];
    var Probe  := Anchor + 1; // 1 byte past, well below the 4 KB cap
    Assert.IsTrue(R.RvaToSourceLine(Anchor, LocExact),
      'anchor lookup must succeed');
    Assert.IsTrue(R.RvaToSourceLine(Probe, LocFallback),
      'off-by-one lookup must succeed via nearest-previous fallback');
    Assert.AreEqual(LocExact.SourceFile, LocFallback.SourceFile,
      'fallback must surface the same source file');
    Assert.AreEqual(LocExact.Line, LocFallback.Line,
      'fallback must surface the same line number');
  finally R.Free; end;
end;

// --- Nested types and bare-identifier visibility ---

function NestedEnumSampleExe(const Bitness: string): string;
begin
  Result := ExtractFilePath(ParamStr(0)) +
    '..\..\TestTarget\' + Bitness + '\Debug\NestedEnumSample.exe';
end;

// A bare identifier must not resolve to a member of a CLASS-NESTED enum FROM
// OUTSIDE the owning class -- and MUST resolve from inside it.
//
// With the default {$SCOPEDENUMS OFF} an enum's members land in the scope that
// ENCLOSES the declaration, which for a class-nested enum is the CLASS. So a
// bare `ikAlsoHidden` is legal inside TNestedHost's own methods; the fixture
// itself proves it, since `TNestedHost.Describe` compiles exactly that. An
// earlier version of this rule refused it everywhere, which turned a wrong
// answer into a wrong refusal.
//
// A unit-level enum and a ROUTINE-LOCAL one must keep resolving in any scope --
// the latter is what an over-broad rule breaks first.
//
// Only x86 is asserted for the nested case. Measured: dcc64 does not emit the
// nested `TInnerKind` into this fixture's type table at all, so on x64 there is
// nothing to refuse and asserting a refusal would be asserting an accident.
procedure TTD32ReaderTests.NestedEnumMember_IsNotBareVisible;
begin
  var Exe := NestedEnumSampleExe('Win32');
  if not TFile.Exists(Exe) then
    Assert.Fail('NestedEnumSample.exe (Win32) not found -- run build_target.bat first');
  var R := TTD32FileReader.Create;
  try
    R.LoadFromFile(Exe);
    var Ord_: Integer;
    var EnumType: string;

    // No scope: outside any class, so the nested members are not visible.
    Assert.IsFalse(R.TryResolveEnumLiteral('ikHidden', Ord_, EnumType),
      'ikHidden must not resolve by bare name outside the owning class');
    Assert.IsFalse(R.TryResolveEnumLiteral('ikAlsoHidden', Ord_, EnumType),
      'ikAlsoHidden must not resolve by bare name outside the owning class');
    // A DIFFERENT class is still outside.
    Assert.IsFalse(R.TryResolveEnumLiteral('ikHidden', Ord_, EnumType, 'TSomethingElse'),
      'ikHidden must not resolve inside an unrelated class');

    // Inside the owning class it IS in scope, and the compiler agrees: the
    // fixture's own TNestedHost.Describe uses `ikAlsoHidden` bare.
    Assert.IsTrue(R.TryResolveEnumLiteral('ikAlsoHidden', Ord_, EnumType, 'TNestedHost'),
      'ikAlsoHidden must resolve inside TNestedHost, where the compiler accepts it');
    Assert.AreEqual(1, Ord_, 'ikAlsoHidden ordinal');
    Assert.IsTrue(R.TryResolveEnumLiteral('ikHidden', Ord_, EnumType, 'tnestedhost'),
      'the owning-class match must not be case sensitive');
    Assert.AreEqual(0, Ord_, 'ikHidden ordinal');

    // And in a DESCENDANT: a protected nested type is inherited like any other
    // member, so TDerivedHost.DescribeDerived reaches `ikHidden` unqualified --
    // the fixture compiles exactly that. Comparing owner to scope class
    // EXACTLY refused it, and inheritance is the normal case in VCL code.
    Assert.IsTrue(R.TryResolveEnumLiteral('ikHidden', Ord_, EnumType, 'TDerivedHost'),
      'ikHidden must resolve inside a DESCENDANT of the owning class');
    Assert.AreEqual(0, Ord_, 'ikHidden ordinal from the descendant');

    // KNOWN LIMIT, pinned so it is not mistaken for correctness: a
    // {$SCOPEDENUMS ON} enum requires `TScopedMode.seSecond` in source, and the
    // bare form does not compile -- yet it resolves here. Measured why: the
    // directive leaves NO trace in TD32. The enum record and its field list are
    // byte-identical to an unscoped one apart from the name indices (see
    // KNOWN_UNKNOWNS), so a bare-name lookup cannot honour it. The failure mode
    // is permissiveness, never a wrong value.
    Assert.IsTrue(R.TryResolveEnumLiteral('seSecond', Ord_, EnumType),
      'scoped-enum members are indistinguishable in TD32 and still resolve; ' +
      'if this ever fails, the directive became visible and the rule can honour it');
    Assert.AreEqual(1, Ord_, 'seSecond ordinal');

    // The other two scopes must be untouched, or the guard is just a blanket
    // refusal wearing a rule's clothes.
    Assert.IsTrue(R.TryResolveEnumLiteral('vmSecond', Ord_, EnumType),
      'vmSecond is a UNIT-LEVEL enum member and must still resolve');
    Assert.AreEqual(1, Ord_, 'vmSecond ordinal');
    Assert.IsTrue(R.TryResolveEnumLiteral('rkBeta', Ord_, EnumType),
      'rkBeta is a ROUTINE-LOCAL enum member and must still resolve');
    Assert.AreEqual(1, Ord_, 'rkBeta ordinal');
  finally
    R.Free;
  end;
end;

// The rule that decides the above, checked directly on the raw names, because
// every wrong version of it was wrong in a way the enum test alone would not
// have localised.
procedure TTD32ReaderTests.NestedTypeDetection_SeparatesUnitRoutineAndClass;
begin
  for var Bitness in ['Win32', 'Win64'] do begin
    var Exe := NestedEnumSampleExe(Bitness);
    if not TFile.Exists(Exe) then
      Assert.Fail('NestedEnumSample.exe (' + Bitness + ') not found -- run build_target.bat first');
    var R := TTD32FileReader.Create;
    try
      R.LoadFromFile(Exe);
      var Nested := R.DiagNestedTypes('');
      for var Line in Nested do begin
        // A dotted unit name occupies two segments, so an early version read
        // `@System@Uitypes@TColorRec` as owner "Uitypes" and called every RTL
        // type in a dotted unit nested.
        Assert.IsFalse(Line.Contains('@Uitypes@TColorRec'),
          Bitness + ': a type in a dotted-name UNIT was reported as class-nested: ' + Line);
        // A mangled signature can itself contain '@', which put a real type
        // name in the owner slot of a routine-scoped name.
        Assert.IsFalse(Line.Contains('$qqr'),
          Bitness + ': a ROUTINE-scoped type was reported as class-nested: ' + Line);
      end;
      // And the fixture's own nested type is found where it exists. dcc64 does
      // not emit it, so this is asserted only where it is actually present.
      if Bitness = 'Win32' then begin
        var Found := False;
        for var Line in Nested do
          if Line.Contains('TNestedHost@TInnerKind') then
            Found := True;
        Assert.IsTrue(Found,
          'the class-nested TInnerKind was not detected: ' + string.Join(' | ', Nested));
      end;
    finally
      R.Free;
    end;
  end;
end;

// --- External .tds ---

function TdsSampleExe: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TdsSample.exe';
end;

function TdsSampleTds: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\Win64\Debug\TdsSample.tds';
end;

function TdsAddMarkerLine: Integer;
begin
  // Line of the TdsSampleAdd body carrying the {BP:TDS_ADD} marker.
  Result := 0;
  var Src := ExtractFilePath(ParamStr(0)) + '..\..\TestTarget\TdsSample.dpr';
  var Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Src);
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains('{BP:TDS_ADD}') then
        Exit(I + 1);
  finally Lines.Free; end;
end;

procedure TTD32ReaderTests.Tds_ResolvesFunctionAndLine;
begin
  if not TFile.Exists(TdsSampleTds) then
    Assert.Fail('TdsSample.tds not found -- run build_target.bat first');
  var R := TTD32FileReader.Create;
  try
    R.LoadFromTdsFile(TdsSampleTds, TdsSampleExe);
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('TdsSampleAdd', Rva),
      'TdsSampleAdd must resolve from the external .tds');
    var Nm: string;
    Assert.IsTrue(R.RvaToFunctionName(Rva, Nm));
    Assert.IsTrue(Nm.EndsWith('TdsSampleAdd', True),
      Format('function name "%s" must end with TdsSampleAdd', [Nm]));
    // The entry RVA resolves to SOME line inside the function's source file.
    var Loc: TSourceLocation;
    Assert.IsTrue(R.RvaToSourceLine(Rva, Loc), 'line must resolve from the .tds');
    Assert.AreEqual('TdsSample.dpr', ExtractFileName(Loc.SourceFile));
    // Forward+reverse round-trip on the marked body line: the exact line resolves
    // (proves the -VT segment/offset -> RVA mapping is correct end to end).
    var MarkerLine := TdsAddMarkerLine;
    Assert.IsTrue(MarkerLine > 0, 'TDS_ADD marker not found in TdsSample.dpr');
    var LineRva: UInt64;
    Assert.IsTrue(R.SourceLineToRva('TdsSample.dpr', MarkerLine, LineRva),
      'the TDS_ADD line must resolve to an RVA');
    var Loc2: TSourceLocation;
    Assert.IsTrue(R.RvaToSourceLine(LineRva, Loc2));
    Assert.AreEqual(MarkerLine, Loc2.Line, 'line RVA must round-trip to the marker line');
    Assert.AreEqual('TdsSample.dpr', ExtractFileName(Loc2.SourceFile));
  finally R.Free; end;
end;

procedure TTD32ReaderTests.Tds_NameToRva_RoundTrips;
begin
  if not TFile.Exists(TdsSampleTds) then
    Assert.Fail('TdsSample.tds not found -- run build_target.bat first');
  var R := TTD32FileReader.Create;
  try
    R.LoadFromTdsFile(TdsSampleTds, TdsSampleExe);
    Assert.IsTrue(Length(R.SortedRvas) > 0, 'the .tds line table must surface RVAs');
    var Rva: UInt64;
    Assert.IsTrue(R.NameToRva('TdsSampleAdd', Rva));
    var FuncRva: UInt64;
    Assert.IsTrue(R.RvaToFunctionStart(Rva, FuncRva));
    Assert.AreEqual(Rva, FuncRva, 'name RVA is the function entry, so start == rva');
  finally R.Free; end;
end;

initialization
  TDUnitX.RegisterTestFixture(TTD32ReaderTests);

end.
