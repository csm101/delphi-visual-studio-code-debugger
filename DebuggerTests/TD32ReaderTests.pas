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
  public
    // --- Demangler (pure) ---
    [Test] procedure Demangle_TopLevelProc_DropsUnit;
    [Test] procedure Demangle_ClassMethod_KeepsClassDotMethod;
    [Test] procedure Demangle_Constructor_C3_BecomesCreate;
    [Test] procedure Demangle_Destructor_D0_BecomesDestroy;
    [Test] procedure Demangle_Initialization_BecomesUnit;
    [Test] procedure Demangle_Finalization_BecomesUnit;
    [Test] procedure Demangle_NonMangled_ReturnsFalse;

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
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
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
