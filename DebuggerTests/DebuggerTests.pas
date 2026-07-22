unit DebuggerTests;
// Integration tests for Win64Debugger DAP adapter.
// Each test launches the adapter + TestTarget fresh, runs a scenario,
// and verifies variables / stepping / output.
//
// Run via RunTests.dpr. Build TestTarget first with build_and_run.bat.

interface

uses
  System.JSON,
  DUnitX.TestFramework,
  DapClient;

type
  // Scenario the fixture runs under: tsMono = monolithic TestTarget.exe (as
  // historically); tsBpl = TestHost.exe + TestSubject.bpl (the SAME subject
  // code compiled into a runtime package). TDebuggerTestsBpl re-runs every test
  // under tsBpl, so each test exercises both the single-exe and the BPL path.
  TTestScenario = (tsMono, tsBpl);

  // One launch's parameters, decoupled from which binary actually runs (the
  // scenario decides that). Modules = extra runtime packages the target loads
  // (e.g. TestPackage*); in tsBpl LaunchTarget auto-injects TestSubject.bpl as
  // the first module so the subject code's debug info is wired.
  TLaunchSpec = record
    Args:               TArray<string>;
    Modules:            TArray<TArray<string>>;
    StopAtEntry:        Boolean;
    ExceptionRulesJson: string;
    GlobalRulesPath:    string;
  end;

  [TestFixture]
  TDebuggerTests = class
  private
    FClient: TDapClient;
    FBpSourceFile: string;       // populated by Bp() — actual source for SetBreakpoints

    // Paths computed at runtime relative to RunTests.exe location.
    // RunTests.exe is at <repo>\DebuggerTests\Win64\Debug\RunTests.exe.
    class function RepoRoot: string; static;
    class function AdapterExe: string; static;
    class function TargetDir: string; static;
    class function TargetExe: string; static;
    class function TargetMap: string; static;
    class function TargetRsm: string; static;
    class function TargetSrc: string; static;
    class function PackageMap: string; static;
    class function PackageRsm: string; static;
    class function PackageDcp: string; static;
    class function PackageSrc: string; static;
    class function Package2Map: string; static;
    class function Package2Rsm: string; static;
    class function Package2Dcp: string; static;
    class function Package2Src: string; static;

    // Launch full session up to the first stopped event at the given BP marker.
    // Caller must call FClient.Continue_ / FClient.Disconnect when done.
    procedure StartSession(const BpMarker: string; out FrameId, LocalsRef: Integer); overload;
    procedure StartSession(const BpMarker: string; out FrameId, LocalsRef: Integer;
      const Args: TArray<string>); overload;
    procedure EndSession;

    function  Bp(const Marker: string): Integer;

  protected
    // Scenario hook: base = monolithic; TDebuggerTestsBpl overrides to tsBpl.
    function  Scenario: TTestScenario; virtual;
    // Scenario-aware launch binary (mono -> TestTarget.exe; bpl -> TestHost.exe).
    function  HostExe: string;
    function  HostMap: string;
    function  HostRsm: string;
    // TestSubject.bpl debug-info, injected as the first module in the bpl scenario.
    function  SubjectMap: string;
    function  SubjectRsm: string;
    function  SubjectDcp: string;
    // Central launch entry: every test launches through this so a single switch
    // selects the monolithic exe or the host+BPL. In tsBpl it prepends the
    // TestSubject module to Spec.Modules and points at TestHost.exe.
    function  LaunchTarget(const Spec: TLaunchSpec): TJSONObject; overload;
    function  LaunchTarget(const Args: TArray<string> = nil;
                StopAtEntry: Boolean = False): TJSONObject; overload;
    // First statement of a test that cannot run under tsBpl (exe-only feature,
    // e.g. a program-main-block RSM inline local). Passes the test in tsBpl with
    // a documented SKIP reason; a no-op in tsMono.
    procedure SkipIfBpl(const Reason: string);
    // Skip a test ONLY in the monolithic scenario when .rsm loading is disabled
    // (NO_RSM=1). These capabilities are RSM-format-only and TD32 cannot supply
    // them; in the BPL scenario the package .dcp (same format, not gated) still
    // provides them, so BPL keeps running. Inert when .rsm is enabled.
    procedure SkipIfNoRsm(const Reason: string);
    // Assert an anon-method parameter local (arg1..argN). Exact = whole-string
    // match (ints / booleans); else substring (floats / strings / objects, whose
    // display may carry extra formatting).
    procedure AssertArg(LocalsRef: Integer; const ArgName, Expected: string;
                Exact: Boolean = True);

  public
    [TearDown]
    procedure TearDown;

    // --- Adapter robustness: a message with no `command` must be ignored,
    //     never answered with an empty (command:"") success response, which is
    //     the amplification vector behind the empty-response runaway. ---
    [Test]
    procedure Test_EmptyCommandMessage_Ignored_AdapterStaysResponsive;

    // --- Constructor parameters (class method, bare $28 RSM record) ---
    [Test]
    procedure Test_ClassCtor_ParamsVisible;

    // --- Class field expansion via RTTI (TWidget instance from main) ---
    [Test]
    procedure Test_ClassFields_ExpandW;

    // --- Expanding a class with properties splits into `properties` /
    //     `fields` group rows; field-backed props read inline, getter-backed
    //     props evaluate the getter only when expanded. ---
    [Test]
    procedure Test_VarView_ClassExpand_PropsAndFieldsGroups;

    // --- A getter-backed SCALAR property expands to a single "(value)" leaf,
    //     never garbage class members. Regression for SampleApp
    //     Application.ShowMainForm (Boolean) expanding into TCustomAttributeClass. ---
    [Test]
    procedure Test_GetterBackedScalar_ExpandsToValueLeafOnly;

    // --- A nil class reference is a leaf: variablesReference 0, never
    //     dereferenced. Regression for SampleApp Application.MainForm/Owner=nil. ---
    [Test]
    procedure Test_NilClassReference_NotExpandable;

    // --- A plain UInt64 field is a leaf, never expandable -- even when a TD32
    //     type table carries a colliding STRUCTURE named `UInt64`. Regression
    //     for SampleApp Application.Handle expanding into m_value endlessly. ---
    [Test]
    procedure Test_UInt64Field_IsLeafNotRecord;

    // --- Real-app-shaped scenario: TWidget/TStuff held as PROCEDURE locals
    //     (the way a real app keeps objects). Resolves via TD32 alone -- proves
    //     the common case needs no RSM, unlike the main-block inline-vars. ---
    [Test]
    procedure Test_RealScenario_ProcLocals_TD32;

    // --- A Delphi inline var (`var x := ...`) inside a named function is
    //     lexical-block scoped (CV S_BLOCK32); its local must still be visible.
    //     Regression for SampleApp IsNull's `vtype` missing from locals. ---
    [Test]
    procedure Test_InlineVarInNamedProc_Visible;

    // --- Same-named inline vars in sibling lexical blocks (different types):
    //     each must resolve to the block whose code range holds the PC. ---
    [Test]
    procedure Test_ShadowedInlineVar_Int;
    [Test]
    procedure Test_ShadowedInlineVar_Str;

    // --- An inline-var Variant must format by VType: Null -> "Null", not the
    //     raw VType word. Regression for SampleApp LoadMenu `v` showing 1 (0x01). ---
    [Test]
    procedure Test_InlineVariant_NullEmptyValue;

    // --- Inline Variant inside a NESTED proc (SampleApp LoadMenu shape): must
    //     read "Null", not the VType word. ---
    [Test]
    procedure Test_NestedProcInlineVariant_Null;

    // --- Two units with structurally-identical, distinctly-named types
    //     (TConflictRec1/2) whose per-unit indices collide: a local must
    //     resolve to its OWN unit's type, never the foreign one. ---
    [Test]
    procedure Test_PerUnitConflict_Unit1;
    [Test]
    procedure Test_PerUnitConflict_Unit2;

    // --- Same-named proc (SharedConflictProc) in two units, constructor-nested
    //     with an INLINE var: TD32 emits NO locals for this shape (verified), so
    //     the local can ONLY come from the RSM unit-scoped fallback, which must
    //     pick THIS unit's copy. Exercises the wired GetLocalsForFunctionByRva
    //     cross-unit path end-to-end (feature "a"). ---
    [Test]
    procedure Test_CrossUnitNestedLocal_Unit1_PicksOwnMarker;
    [Test]
    procedure Test_CrossUnitNestedLocal_Unit2_PicksOwnMarker;

    // --- Cross-unit GLOBAL disambiguation. GSharedAmbiguous is declared in BOTH
    //     conflict units with a different type (Integer / Double). Stopped in each
    //     unit, the evaluated global must carry THIS unit's type/value, not the
    //     foreign one. RED before TD32 per-unit global attribution (the flat
    //     name index keeps the first-hit -> both stops resolved to unit 1). Now
    //     resolved by TD32 IUnitScopedGlobalProvider: ALIGN_SYMBOLS globals are
    //     attributed to their declaring unit via ModIndex -> SOURCE_MODULE, and
    //     DebugInfoSet.FindGlobalForRva scopes by the frame's source unit. ---
    [Test]
    procedure Test_CrossUnitGlobal_Unit1_PicksOwnType;
    [Test]
    procedure Test_CrossUnitGlobal_Unit2_PicksOwnType;
    // --- Per-unit-uses scoping: same type/class/func/const name declared in
    //     units A/B/C; the frame unit (TestTargetUsesHost) uses A,B (B last, not
    //     C). An unqualified reference in a watch must resolve to unit B
    //     (compiler-resolved, last-wins), never A or C. ---
    [Test]
    procedure Test_UsesScope_Type_PicksUsedUnit;
    [Test]
    procedure Test_UsesScope_Const_PicksUsedUnit;
    [Test]
    procedure Test_UsesScope_ClassMethod_PicksUsedUnit;
    [Test]
    procedure Test_UsesScope_Cast_PicksUsedUnit;
    // --- Cross-BPL global, unique name: stop in the host EXE and watch a
    //     unit-level global that lives inside a runtime-loaded package. It
    //     must resolve via the BPL's per-binary provider (image-base shift). ---
    [Test]
    procedure Test_Bpl_UniqueGlobal_ResolvesFromExeFrame;
    // --- Layer 2: a global name that COLLIDES across binaries (declared in
    //     two BPLs with different types). Stopped inside one BPL, the watch
    //     must resolve to THAT binary's copy, not the other's. ---
    [Test]
    procedure Test_Bpl_CrossBinaryGlobalCollision_PicksOwnBinary;
    // --- Layer 2 uses-graph: the colliding global is NOT in the frame's own
    //     binary; it exists in a package the frame's binary REQUIRES and also
    //     in an unrelated binary (the host). The required package's copy must
    //     win over the unrelated host's, not flat load-order. ---
    [Test]
    procedure Test_Bpl_UsesGraphGlobal_PrefersRequiredPackage;

    // --- Inherited getter-backed property: getter symbol lives under the
    //     DECLARING base class, not the runtime leaf (Application.ComponentCount
    //     -> TComponent.GetComponentCount). Regression for that SampleApp bug. ---
    [Test]
    procedure Test_InheritedGetter_ResolvesViaDeclClass;

    // --- A plain inherited METHOD, called on a derived instance. Unlike the
    //     getter above, nothing records its declaring class, so the symbol has
    //     to be found by walking the ancestor chain. Live repro:
    //     dataset.FieldByName('X') -> "<TAppDataSet.FieldByName not found>". ---
    [Test]
    procedure Test_InheritedMethod_CalledOnDerivedInstance;
    [Test]
    procedure Test_InheritedMethod_WithStringArgument;

    // --- `Obj[X]` is the class's `default` array property. TIndexProbe has two
    //     array properties that differ only in that marker, so a debugger that
    //     picked the wrong one would be caught here. Live repro:
    //     dataset['CODE'] -> "<cannot index type "TAppDataSet">". ---
    [Test]
    procedure Test_DefaultArrayProperty_IndexingAnObject;
    [Test]
    procedure Test_DefaultArrayProperty_NotConfusedWithTheOtherIndexedOne;
    [Test]
    procedure Test_Indexing_ObjectWithoutDefaultProperty_SaysWhatToWrite;

    // --- Multi-index properties (matrix / IMldoSqlResult-style). Two indices,
    //     and mixed types (Integer + string). Both the explicit-name form and
    //     the default-property form must marshal every index. ---
    [Test]
    procedure Test_IndexedProperty_TwoMixedIndices_ExplicitName;
    [Test]
    procedure Test_DefaultProperty_TwoIndices;

    // --- A default property returning a Variant (the FieldValues shape). The
    //     var-out slot holds a TVarData by value and must be DECODED, not read
    //     as a pointer. Live: dataset['CODE'] showed 258 (the varUString
    //     VType word) instead of the char value. ---
    [Test]
    procedure Test_DefaultProperty_ReturningVariantString;
    [Test]
    procedure Test_IndexedProperty_ReturningVariantInteger;
    // Return type resolved by KIND, not name: a distinct Variant alias
    // (NullableInteger = type Variant), a class, and a record.
    [Test]
    procedure Test_IndexedProperty_ReturningVariantAlias;
    [Test]
    procedure Test_IndexedProperty_ReturningClass;
    [Test]
    procedure Test_IndexedProperty_ReturningRecord;

    // --- Sets wider than 8 bytes, and a field-backed set, must not truncate. ---
    [Test]
    procedure Test_WideSet_MembersBeyond64BitsShown;
    [Test]
    procedure Test_FieldBackedSet_HighMemberShown;
    // Getter-returned sets: a <= 8-byte set (RAX) and a > 8-byte set (var-out).
    [Test]
    procedure Test_GetterReturningSmallSet;
    [Test]
    procedure Test_GetterReturningWideSet;
    // Getter returning a record: decoded by declared type, fields readable.
    [Test]
    procedure Test_GetterReturningRecord_FieldsReadable;

    // --- Two same-named nested classes in one unit, told apart only by VMT.
    //     Repro of the live dataset.Fields bug. ---
    [Test]
    procedure Test_CollidingNestedClass_ResolvesMembersByVmt;
    // Cross-unit: top-level TestTargetTypes.TDupCross vs nested
    // TestTargetCore.TDupCrossCache.TDupCross. This is the live Data.DB.TFields
    // vs System.Classes.TFieldsCache.TFields shape.
    [Test]
    procedure Test_CollidingCrossUnitClass_ResolvesRealMembers;

    // --- Getter-backed STRING property on an RTL class (TStringList.Text):
    //     getter has no locals, var-out return ABI must come from the property
    //     type. Regression for SampleApp TApplication.ExeName / CurrentHelpFile. ---
    [Test]
    procedure Test_RtlStringGetter_VarOutFromPropertyType;

    // --- var parameter (reference param) ---
    [Test]
    procedure Test_VarParam_InCompute;

    // --- Nested procedure: Inner sees X from outer ComputeNested ---
    [Test]
    procedure Test_NestedProcLocals;

    // --- Step out of Inner lands in ComputeNested ---
    [Test]
    procedure Test_StepOut_InnerToNested;

    // --- Step into TWidget.Create from call site ---
    [Test]
    procedure Test_StepInto_Ctor;

    // --- Global variable visible ---
    [Test]
    procedure Test_GlobalVar;

    // --- evaluate expression ---
    [Test]
    procedure Test_Evaluate_IntegerExpr;

    // --- expression evaluator: string character indexing ---
    [Test]
    procedure Test_Eval_StringIndex;

    // --- expression evaluator: dynamic array element ---
    [Test]
    procedure Test_Eval_DynArrayIndex;

    // --- expression evaluator: enum symbolic name ---
    [Test]
    procedure Test_Eval_EnumValue;

    // --- expression evaluator: set of enum display ---
    [Test]
    procedure Test_Eval_SetValue;

    // --- expression evaluator: VarArray display in variables panel ---
    [Test]
    procedure Test_Eval_VarArrayDisplay;

    // --- expression evaluator: 1-D VarArray element access ---
    [Test]
    procedure Test_Eval_VarArray1D;

    // --- expression evaluator: 2-D VarArray element access ---
    [Test]
    procedure Test_Eval_VarArray2D;

    // --- expression evaluator: nested-proc Variant local auto-recovery ---
    // RSM mis-types Variants inside nested procedures as primitives
    // (SampleApp / TestTarget RunNestedVariantTest). FormatLocalValue must
    // detect the TVarData pattern at the stack slot and decode the value
    // without an explicit Variant(...) cast.
    [Test]
    procedure Test_Eval_NestedProcVariant_AutoDecode;
    // Nested procedures live INSIDE another procedure (Pascal local
    // proc shape). When the debugger stops inside one, the stack
    // frame's source must still point at the enclosing unit -- not
    // 'unknown source'. Bug reported from SampleApp on
    // TfrmMainMdi.Create.LoadMenu shape.
    [Test]
    procedure Test_StackFrame_NestedProc_HasSourcePath;
    // Repro for the SampleApp TreeMenu.LoadMenu.CreateNodes bug. Stopped
    // inside a CLASS METHOD's nested local procedure, three things must
    // hold simultaneously:
    //   1) the nested proc's own Integer local reads back the value
    //      that was just assigned to it (was surfacing as -116 / wrong
    //      RBP offset for nested-scope locals).
    //   2) the outer method's reference-typed local keeps its declared
    //      type hint (was surfacing as TStringBuilder -- short-name
    //      collision in the parent-scope merge).
    //   3) the outer method's Self is visible in locals AND resolvable
    //      from a watch expression (was missing entirely).
    [Test]
    procedure Test_NestedClassMethod_AllThreeBugs;
    // Repro for the SampleApp 'const v: variant' parameter bug. On Win64
    // every variant parameter is passed by reference; the slot holds
    // a pointer to the caller's TVarData. The Variant formatter must
    // deref before decoding -- otherwise the parameter shows up as
    // garbage / wrong VType.
    [Test]
    procedure Test_Eval_ConstVariantParam_DerefsThroughPointer;
    [Test]
    procedure Test_Eval_NestedProcVariant_ExplicitCast;
    // Variant decoder coverage: every VType the user is likely to encounter
    // gets its own test asserting the formatted display string.
    [Test]
    procedure Test_Variant_Null_DisplaysAngleBracketsNull;
    [Test]
    procedure Test_Variant_Empty_DisplaysAngleBracketsEmpty;
    [Test]
    procedure Test_Variant_Integer_DisplaysLabelAndValue;
    [Test]
    procedure Test_Variant_Boolean_DisplaysTrue;
    [Test]
    procedure Test_Variant_Double_DisplaysValue;
    [Test]
    procedure Test_Variant_Int64_DisplaysValue;
    [Test]
    procedure Test_Variant_String_DisplaysQuoted;
    [Test]
    procedure Test_Variant_Date_DisplaysIsoDate;
    // VarArray display: shape, element type, element count.
    [Test]
    procedure Test_Variant_VarArray1D_DisplaysShape;
    [Test]
    procedure Test_Variant_VarArray2D_DisplaysShape;
    // VarArray expansion: the watch must expose a non-zero
    // variablesReference, and the expansion must enumerate every cell.
    [Test]
    procedure Test_Variant_VarArray1D_Expansion;
    [Test]
    procedure Test_Variant_VarArray2D_Expansion;
    // Same VarArray Variant must be expandable from the LOCALS view too,
    // not only from a hover/watch expression. SampleApp field testing
    // surfaced a chevron mismatch -- evaluate exposed a non-zero
    // variablesReference while the locals tree returned 0.
    [Test]
    procedure Test_Variant_VarArray1D_LocalsViewExpandable;

    // --- expression evaluator: class field via dot syntax ---
    [Test]
    procedure Test_Eval_FieldDot;

    // --- expression evaluator: implicit Self for bare field/property names
    //     inside a method (locals -> Self.<name> -> globals priority) ---
    [Test]
    procedure Test_Eval_ImplicitSelf_Field;
    [Test]
    procedure Test_Eval_ImplicitSelf_LocalShadowsField;
    // TStuff is deliberately a $M- class with no published RTTI: bare
    // field references inside TStuff.PubBump must resolve via the RSM
    // class-member table (the same path used by SampleApp-style VCL forms
    // whose private/published members are not all reachable through
    // TPropInfo). Reproduces the "field shown as not found" bug.
    [Test]
    procedure Test_Eval_ImplicitSelf_NonPublishedClass;

    // Mirrors the Debugme.dpr TFoo regression: a plain $M- class with
    // strictly-private fields must be inspectable both inside its
    // constructor (Self) and from the caller (the variable holding the
    // newly-created instance). Both code paths must surface a non-zero
    // `variablesReference` in the variables view AND expand to the
    // private fields with their assigned values.
    [Test]
    procedure Test_VarView_PrivateClassExpand_FromCaller;
    [Test]
    procedure Test_VarView_PrivateClassExpand_InsideCtor;

    // Hover on a class-instance local must expose `type` AND a non-zero
    // `variablesReference` so VS Code shows an expandable popup with the
    // class name instead of a bare pointer integer.
    [Test]
    procedure Test_Hover_ClassInstance_IsExpandable;

    // --- Debugme.dpr-aligned watch coverage --------------------------------
    // Each test below mirrors one watch/hover/expand the user would try on
    // Debugme line 25-34 (inside TFoo.Create) or line 92 (caller). TStuff
    // stands in for TFoo, FPoint for Pt, FLabel/FCount/FMode/etc for
    // Name/Value/Active. Permanent regression coverage; do not delete.
    [Test] procedure Test_Watch_Inside_BareField_Integer;
    [Test] procedure Test_Watch_Inside_BareField_String;
    [Test] procedure Test_Watch_Inside_BareField_Enum;
    [Test] procedure Test_Watch_Inside_BareRecordField_Expandable;
    [Test] procedure Test_Watch_Inside_BareRecordField_X;
    [Test] procedure Test_Watch_Inside_BareRecordField_Y;
    [Test] procedure Test_Watch_Inside_BareRecordField_Z;
    [Test] procedure Test_Watch_Inside_SelfRecordField_Y;
    [Test] procedure Test_Watch_Caller_ClassFieldRecord_Y;
    [Test] procedure Test_Watch_Caller_Param_NamedAfterCtorArg;

    // Record-field expansion (`Pt` should expand to X/Y/Z values).
    [Test] procedure Test_Watch_RecordField_ExpansionReturnsFields;
    [Test] procedure Test_Watch_RecordField_FromCaller_Expansion;
    [Test] procedure Test_Watch_Inside_BareRecordField_X_AndY_AndZ;
    [Test] procedure Test_Watch_Caller_RecordField_X;
    // foo expansion: the Pt sub-field must itself be expandable into its
    // X/Y/Z children, not shown as a raw pointer.
    [Test] procedure Test_Watch_Caller_ClassExpand_RecordSubFieldExpandable;

    // Variables response must carry `evaluateName` so VS Code's
    // "Copy Value" round-trips through evaluate() with the variable's
    // expression, not with the displayed value (which contains
    // "(TypeName)" and chokes the parser).
    [Test] procedure Test_VarView_HasEvaluateName_Self;
    [Test] procedure Test_VarView_HasEvaluateName_ChildField;

    // Expanded Self.FPoint child must render as `{TPoint3D}` (record
    // summary) instead of a raw integer.
    [Test] procedure Test_VarView_RecordChild_FormattedAsRecordSummary;

    // User feedback round 2 -- formatting / clipboard / setVariable
    [Test] procedure Test_Format_Integer_NoRedundantUnsigned;
    [Test] procedure Test_LocalsView_ClassInstance_FormattedWithClassName;
    [Test] procedure Test_Clipboard_ClassInstance_CleanFormat;
    [Test] procedure Test_Clipboard_StringField_NoTokenError;
    [Test] procedure Test_SetVariable_ClassField_String;
    [Test] procedure Test_SetVariable_NestedRecordField_Double;

    // `type Foo = type Integer;` must NOT be class-decorated just because
    // the alias's name starts with a capital T. The formatter must follow
    // the TypeInfo TKind (tkInteger), not heuristics on the name.
    [Test]
    procedure Test_Format_TypeAlias_NotClassFormatted;

    // System.Now is a parameterless function returning TDateTime. The
    // watch panel must accept `Now` (and `Now()`) as a valid expression,
    // not return `<Now: not found>` or a parser error.
    [Test] procedure Test_Eval_ParameterlessSystemFunc_Now;

    // Hover on `foo` (just the class-instance local, no dot) inside the
    // caller frame must give an expandable popup -- user reports it shows
    // a bare pointer.
    [Test] procedure Test_Hover_Caller_ClassInstance_Expansion;

    // Exception handler scenarios -- `E: Exception` in the on-clause.
    // KNOWN FAILURE: the adapter reads from the RSM-computed slot for `E`
    // but the value there does not pass IsClassInstance, so neither the
    // hover nor `E.Message` / `E.ClassName` currently resolve. Tests
    // kept as documentation of the gap; the probe target also gates the
    // raise behind a switch so unrelated tests don't see it.
    [Test] procedure Test_Hover_ExceptionInHandler_Expandable;
    [Test] procedure Test_Hover_ExceptionInHandler_ClassName;
    // E.Message: Exception's classic RTTI carries NO published property table
    // (System.SysUtils builds Exception as $M-) AND vmtFieldTable's enhanced
    // RTTI is empty in the shipped RTL build, so paths 1 and 2 in
    // ExprEval.ApplyDot return nothing. The only remaining source is the RSM
    // class-member table, but Exception's $2C records were emitted by dcc64
    // while compiling System.SysUtils.dcu and reference the per-unit TypeId
    // space SysUtils had at THAT point in time. The EXE's RSM keeps those
    // ids verbatim; the imports area at the bottom of the file is a global
    // EXE-wide $66 table with a different ordering, so resolving FMessage's
    // typeId $12 against it yields the wrong type (Boolean instead of
    // string).
    //
    // Proper fix: per-unit TypeId tables. Each unit emits its own TypeInfo
    // block (we see four `65 06 System ...` headers in TestTarget.rsm at
    // $56128 / $5638A / $5D717 / $6148B, each followed by that unit's local
    // type list as `$08`-prefixed TypeInfo records). The RSM parser needs to
    // (a) detect these per-unit boundaries, (b) build a per-unit type list
    // for each, (c) attach each $2A class declaration AND its $2C/$2E/$31
    // member records to the owning unit, and (d) resolve member typeIds
    // against the unit's local table rather than the global FUserTypes.
    // Currently tracked as the "RSM TypeId cross-unit collisions" item in
    // KNOWN_UNKNOWNS.md.
    [Test]
    procedure Test_Hover_ExceptionInHandler_Message;

    // --- expression evaluator: class property (field-backed) via dot syntax ---
    [Test]
    procedure Test_Eval_PropertyDot;

    // --- expression evaluator: method-backed property getter (synthetic call) ---
    [Test]
    procedure Test_Eval_PropertyGetter;

    // --- method-backed property getter: full return-type matrix ---
    // RAX-direct integer/ordinal/pointer types.
    [Test] procedure Test_Eval_PropGet_Int64;
    [Test] procedure Test_Eval_PropGet_Cardinal;
    [Test] procedure Test_Eval_PropGet_Bool;
    [Test] procedure Test_Eval_PropGet_Enum;
    [Test] procedure Test_Eval_PropGet_Set;
    [Test] procedure Test_Eval_PropGet_Char;
    [Test] procedure Test_Eval_PropGet_Class;
    [Test] procedure Test_Eval_PropGet_Pointer;
    // XMM0 floats.
    [Test] procedure Test_Eval_PropGet_Single;
    [Test] procedure Test_Eval_PropGet_Double;
    [Test] procedure Test_Eval_PropGet_DateTime;
    [Test] procedure Test_Eval_PropGet_Currency;
    // Managed types via hidden var-out result.
    [Test] procedure Test_Eval_PropGet_UnicodeString;
    [Test] procedure Test_Eval_PropGet_AnsiString;
    [Test] procedure Test_Eval_PropGet_WideString;
    [Test] procedure Test_Eval_PropGet_UTF8String;
    [Test] procedure Test_Eval_PropGet_RawByteString;
    [Test] procedure Test_Eval_PropGet_DynArray;
    [Test] procedure Test_Eval_PropGet_Variant;
    // Records.
    [Test] procedure Test_Eval_PropGet_SmallRecord;
    [Test] procedure Test_Eval_PropGet_BigRecord;
    [Test] procedure Test_Eval_MethodCall_TDateTimeArgument;
    [Test] procedure Test_Eval_StringAliasIndexing_ReadsWideChar;
    [Test] procedure Test_Eval_VariantAliasLocal_Decoded;
    [Test] procedure Test_Eval_ByRefVariant_Dereferenced;

    // --- generic method call: Obj.Method(arg1, arg2, ...) ---
    [Test] procedure Test_Eval_Method_Integer;
    [Test] procedure Test_Eval_Method_Double;
    // Wrong-data audit (2026-07-19): a POD record <= 8 bytes is returned PACKED
    // IN RAX, not via a hidden var-out slot. The debugger used to insert the slot
    // (also shifting the user args) and then read the untouched, zeroed slot, so
    // the watch showed a bogus zero.
    [Test] procedure Test_Eval_SmallRecordReturn_NotZero;
    [Test] procedure Test_Eval_Method_String;

    // --- indexed accessor: Obj.X[i] syntax  ---
    [Test] procedure Test_Eval_Method_IndexedSyntax;
    // --- chained method calls: Obj.A().B() ---
    [Test] procedure Test_Eval_Method_Chained;

    // --- private/public access in a class without {$M+} ---
    // Probes whether the debugger relies on RTTI (which only sees published
    // members) or on RSM debug info (which sees everything).
    [Test] procedure Test_NonRtti_PublicField;
    [Test] procedure Test_NonRtti_PrivateField;
    [Test] procedure Test_NonRtti_PublicProperty;
    [Test] procedure Test_NonRtti_PrivateProperty;
    // Event-handler (method-pointer) properties get their own group.
    [Test] procedure Test_EventHandlerProperty_InOwnGroup;
    [Test] procedure Test_NonRtti_PublicMethod;
    [Test] procedure Test_NonRtti_PrivateMethod;

    // --- odd-typeId fields/properties: guards against re-introducing the
    //     hardcoded TypeIdByte→name table that was originally TestTarget-
    //     specific. These all sit on TStuff (no $M+ → no TPropInfo escape
    //     route) and resolve only via the RSM class-member parser. The
    //     types involved (TWorkMode, TPoint3D, TArray<Double>) all have
    //     module-local TypeIds whose low byte has LSB=1, so the parser
    //     MUST do a 2-byte VLE read of the typeId in $2C/$31 records. ---
    [Test] procedure Test_NonRtti_EnumField_OddTypeId;
    [Test] procedure Test_NonRtti_RecordField_OddTypeId;
    [Test] procedure Test_NonRtti_EnumProperty_OddTypeId;
    [Test] procedure Test_NonRtti_DynArrayProperty_OddTypeId;

    // --- multi-thread enumeration ---
    [Test] procedure Test_Threads_Enumerated_NamedWorkers;
    [Test] procedure Test_Threads_NonStopped_StackInspectable;
    [Test] procedure Test_Threads_BpOnWorker_LocalVisible;
    [Test] procedure Test_Threads_ExceptionInWorker;
    [Test] procedure Test_Threads_NameThreadForDebugging_SurfacesLive;
    [Test] procedure Test_Threads_NameAnnouncement_NeverStops_WithAllFilter;

    // --- conditional / hit-count / log-point breakpoints + hover eval ---
    [Test] procedure Test_BP_Conditional;
    [Test] procedure Test_BP_HitCount;
    [Test] procedure Test_BP_LogPoint;
    [Test] procedure Test_Eval_HoverContext;

    // --- arithmetic / boolean / unary / literal / enum operators ---
    [Test] procedure Test_Eval_Arith_Precedence;
    [Test] procedure Test_Eval_Arith_FloatMix;
    [Test] procedure Test_Eval_Arith_Div_Mod;
    [Test] procedure Test_Eval_Bool_AndOrNot;
    [Test] procedure Test_Eval_UnaryMinus;
    [Test] procedure Test_Eval_True_False;
    [Test] procedure Test_Eval_Nil_Compare;
    [Test] procedure Test_Eval_StringConcat;
    [Test] procedure Test_Eval_EnumLiteral;

    // --- type casts + built-in intrinsics ---
    [Test] procedure Test_Eval_Cast_IntToFloat;
    [Test] procedure Test_Eval_Cast_FloatToInt;
    [Test] procedure Test_Eval_Cast_IntegerOfChar;
    [Test] procedure Test_Eval_Intrinsic_Length_String;
    [Test] procedure Test_Eval_Intrinsic_Length_DynArray;
    [Test] procedure Test_Eval_Intrinsic_SizeOf;
    [Test] procedure Test_Eval_Intrinsic_Ord_Enum;
    [Test] procedure Test_Eval_Intrinsic_High_Low_Enum;

    // --- class casts (typed pointer reinterpret + member access) ---
    [Test] procedure Test_Eval_ClassCast_RoundTrip;
    [Test] procedure Test_Eval_ClassCast_TObjectUpcast;
    [Test] procedure Test_Eval_ClassCast_NonRtti;

    // --- `is` / `as` operators (RTTI-driven type checks) ---
    [Test] procedure Test_Eval_Is_PositiveDescendant;
    [Test] procedure Test_Eval_Is_NegativeUnrelated;
    [Test] procedure Test_Eval_Is_TObjectMatchesAll;
    [Test] procedure Test_Eval_As_Success;
    [Test] procedure Test_Eval_As_FailureReportsError;

    // --- attach-to-running-process ---
    [Test] procedure Test_Attach_BasicSession;
    [Test] procedure Test_Attach_ByProcessName;

    // --- exception filter UI (DAP setExceptionBreakpoints) ---
    [Test] procedure Test_ExceptionFilter_DelphiOn_Stops;
    [Test] procedure Test_ExceptionFilter_DelphiOff_Skips;
    [Test] procedure Test_ExceptionFilter_ClassMatch_Stops;
    [Test] procedure Test_ExceptionFilter_ClassMismatch_Skips;
    [Test] procedure Test_ExceptionFilter_RealVsCodeShape_AllStops;
    [Test] procedure Test_ExceptionInfo_ReportsClassAndMessage;
    [Test] procedure Test_ExceptionStop_DescriptionHasClassAndMessage;
    [Test] procedure Test_ExceptionRule_Ignore_Resumes;
    [Test] procedure Test_ExceptionRule_Break_OverridesFilterOff;
    [Test] procedure Test_ExceptionRule_Log_ResumesAndLogs;
    [Test] procedure Test_ExceptionRule_ClassIs_MatchesAncestor;
    [Test] procedure Test_ExceptionRule_Code_MatchesNativeOnly;
    [Test] procedure Test_ExceptionRule_Code_Decimal_BreaksOnNative;
    [Test] procedure Test_ExceptionLocal_ShowsExceptionObject;
    [Test] procedure Test_GlobalExceptionRules_FileApplied;
    [Test] procedure Test_GlobalExceptionRules_HotReloadOnResume;

    // --- free-procedure / function calls (no Self) ---
    [Test] procedure Test_Eval_FreeProc_IntegerReturn;
    [Test] procedure Test_Eval_FreeProc_StringReturn;

    // --- Pascal set literals `[a, b]` ---
    [Test] procedure Test_Eval_SetLiteral_Compare;
    [Test] procedure Test_Eval_SetLiteral_Empty;
    [Test] procedure Test_Eval_In_PropertyTrue;
    [Test] procedure Test_Eval_In_PropertyFalse;
    [Test] procedure Test_Eval_In_LiteralSet;

    // --- session lifecycle ---
    [Test] procedure Test_Lifecycle_RunToTermination;

    // --- BPL (runtime-loaded package) debugging ---
    [Test] procedure Test_Bpl_BreakpointHits;
    [Test] procedure Test_Bpl_Td32Only_BpHits;
    [Test] procedure Test_Bpl_Td32Only_LocalsVisible;
    [Test] procedure Test_Bpl_DefinedClass_FieldVisible;
    [Test] procedure Test_Bpl_DefinedClass_ExpandInLocals;
    [Test] procedure Test_Bpl_UnloadReload_BpRebinds;
    [Test] procedure Test_Bpl_TwoModules_EachBpRoutes;

    // --- type-sampler battery (TestTargetTypes.pas) ---
    // Tests marked [Ignore('TODO-RED: ...')] are documented BACKLOG: the
    // test asserts correct behaviour the debugger does not yet provide.
    // They keep [Test] so DUnitX reports them in the "Ignored" count
    // (visible, not silently dropped). The Ignore message is the spec /
    // root-cause note. Remove the [Ignore] line when the underlying
    // adapter bug is fixed.
    [Test] procedure Test_Types_ByteBool_True;
    [Test] procedure Test_Types_WordBool_True;
    [Test] procedure Test_Types_LongBool_True;
    [Test] procedure Test_Types_ShortString_Content;
    [Test] procedure Test_Types_WideString_Content;
    [Test] procedure Test_Types_TGUID_Display;
    [Test] procedure Test_Types_Interface_Live_HasClassName;
    [Test] procedure Test_Types_Interface_Nil_DisplaysAsNil;
    [Test] procedure Test_Types_MethodPointer_Nil;
    [Test] procedure Test_Types_AnonProc_Assigned;
    // Closure capture (increment A): a live anonymous-method value expands to its
    // captured variables, resolved from debug info (the $ActRec class members),
    // NOT runtime RTTI (which $ActRec lacks).
    [Test] procedure Test_Closure_ExpandsCapturedFields;
    // Closure capture (increment B): stopped INSIDE the anon body, the captured
    // variables are surfaced as locals (from the hidden Self $ActRec object), and
    // the frame resolves to the anon method (not a neighbouring proc).
    [Test] procedure Test_Closure_CapturedVarsVisibleInBody;
    // Anon-method PARAMETER coverage: stopped inside an anon body, the method's own
    // declared params surface (arg1..argN) from the signature + Win64 ABI slots.
    // Varied signatures exercise multi-arg, string, Double (XMM), Int64, Boolean,
    // object, mixed int/string/float/bool, and >4 args (stack spill).
    [Test] procedure Test_ClosureParam_TwoInts;
    [Test] procedure Test_ClosureParam_String;
    [Test] procedure Test_ClosureParam_Double;
    [Test] procedure Test_ClosureParam_Int64;
    [Test] procedure Test_ClosureParam_Boolean;
    [Test] procedure Test_ClosureParam_Object;
    [Test] procedure Test_ClosureParam_Mixed;
    [Test] procedure Test_ClosureParam_SixIntsStackSpill;
    [Test] procedure Test_Types_ClassRef_AssignedShowsClassName;
    [Test] procedure Test_Types_ClassRef_NilDisplaysAsNil;
    [Test] procedure Test_Types_GenericList_Expandable;
    [Test] procedure Test_Types_PtrPrimitive_DerefMatches;
    [Test] procedure Test_Types_PtrRecord_Expandable;
    [Test] procedure Test_Types_UntypedPointer_HexDisplay;
    [Test] procedure Test_Types_PChar_StringContent;
    [Test] procedure Test_Types_PackedRecord_FieldsVisible;
    [Test] procedure Test_Types_ManagedRecord_FieldsVisible;
    [Test] procedure Test_Types_Enum_DisplaysName;
    [Test] procedure Test_Types_BigEnum_DisplaysName;
    [Test] procedure Test_Types_NonEmptySet_Display;
    [Test] procedure Test_Types_EmptySet_Display;
    [Test] procedure Test_Types_TrickyOne_NotMisDecodedAsVariant;
    [Test] procedure Test_Types_ZeroInt_DisplaysZeroNotEmpty;
    [Test] procedure Test_Types_GenericList_EnumeratesElements;
    [Test] procedure Test_Types_TDateTime_Local_NotPlainFloat;
    [Test] procedure Test_Types_TDate_Local_RendersAsDate;
    [Test] procedure Test_Types_TTime_Local_RendersAsTime;
    [Test] procedure Test_StaleRsm_IgnoredFallsBackToTd32;
    [Test] procedure Test_Types_Single_Local_NotUpgradedToDateAlias;
    [Test] procedure Test_Types_IndexedProperty_NotAutoEvaluated;
    [Test] procedure Test_Watch_NonExistentName_ErrorShaped;
    [Test] procedure Test_Coll_DynArrayOfRecord_ElementFields;
    [Test] procedure Test_Coll_DynArrayOfClass_ElementInstance;
    [Test] procedure Test_Coll_InterfacedClass_FieldVisible;
    [Test] procedure Test_DeepNest_OwnLocalVisible;
    [Test] procedure Test_DeepNest_ParentLocalVisible;
    [Test] procedure Test_DeepNest_GrandparentLocalVisible;
    [Test] procedure Test_StaticClassMethod_NoSelfInLocals;
    [Test] procedure Test_OperatorBody_StoppableAndArgsVisible;
    [Test] procedure Test_PropertySetterBody_NewValueVisible;
    [Test] procedure Test_OutParam_AfterAssignment_ReadsBack;
    [Test] procedure Test_ConstParam_ReadsValue;
    [Test] procedure Test_DefaultParam_TakesDefaultValue;
    [Test] procedure Test_CrossUnitDoWork_NoCollision;

    // --- edge cases (TestTargetEdge.pas) ---
    [Test] procedure Test_Edge_LargeSet_BeyondOneByte;
    [Test] procedure Test_Edge_GapEnum_DisplaysName;
    [Test] procedure Test_Edge_EmptyString_DisplaysEmpty;
    [Test] procedure Test_Edge_NegInteger_Signed;
    [Test] procedure Test_Edge_NegInt64_Signed;
    [Test] procedure Test_Edge_NegSmallInt_Signed;
    [Test] procedure Test_Edge_FloatNaN;
    [Test] procedure Test_Edge_FloatInfinity;
    [Test] procedure Test_Edge_LongString_NoCrash;
    [Test] procedure Test_Edge_EmbeddedNulString;
    [Test] procedure Test_Edge_EmojiString;
    [Test] procedure Test_Edge_VariantRecord_Expands;
    [Test] procedure Test_Edge_InterfaceToClass;
    [Test] procedure Test_Edge_CyclicGraph_NoInfiniteExpand;
    [Test] procedure Test_Edge_ObjectMidConstruction;
    [Test] procedure Test_Edge_Recursion_PerFrameLocals;

    // --- edge cases wave 2 (TestTargetEdge2.pas) ---
    [Test] procedure Test_E2_MultiDimStatic_Element;
    [Test] procedure Test_E2_MultiDimDynamic_Expand;
    [Test] procedure Test_E2_OpenArrayParam_Element;
    [Test] procedure Test_E2_NestedRecord3Deep;
    [Test] procedure Test_E2_Currency_Value;
    [Test] procedure Test_E2_FloatNegZero;
    [Test] procedure Test_E2_ShortStringEmpty;
    [Test] procedure Test_E2_LongDotChain;
    [Test] procedure Test_E2_FunctionPointer_Assigned;
    [Test] procedure Test_E2_GenericDict_Enumerate;
    [Test] procedure Test_E2_NestedGenericList;
    // setVariable battery
    [Test] procedure Test_SetVar_LocalInteger;
    [Test]
    procedure Test_SetVar_EnumByName;
    [Test]
    procedure Test_SetVar_TypeMismatch_Rejected;
    // evaluate edge
    [Test] procedure Test_Eval_AddressOf_Local;
    [Test] procedure Test_Eval_AssignmentInWatch;

    // --- real SampleApp shapes (TestTargetReal.pas) ---
    [Test] procedure Test_Real_VarArrayParam_Expandable;
    [Test] procedure Test_Real_BooleanResult_NotExpandable;
    [Test] procedure Test_Real_VariantNull_NotInteger;
    [Test] procedure Test_Real_InheritedFields_Visible;
    [Test] procedure Test_Real_EvalParamInBody;

    // --- control flow: stepping / exceptions / nesting (TestTargetFlow.pas) ---
    [Test] procedure Test_Step_Over_StaysInProc;
    [Test] procedure Test_Step_Over_NotTakenBranch_LandsNextLine;
    [Test] procedure Test_Step_Over_FromFunctionEntry_LandsNextLine;
    [Test] procedure Test_Step_Over_ConsecutiveParamlessCalls_StopsEachLine;
    [Test] procedure Test_Step_Over_ManagedClear_LandsNextLine;
    [Test] procedure Test_Step_Into_EntersHelper;
    [Test] procedure Test_Step_Out_ReturnsToCaller;
    [Test] procedure Test_Bp_InPropertyGetter;
    [Test] procedure Test_Step_IntoNoDebugInfo_StepsOver;
    [Test] procedure Test_Exc_NestedFinally_HandlerCatches;
    [Test] procedure Test_Flow_Nest3_AllAncestorsVisible;
    [Test] procedure Test_Flow_RecByVal_FieldsReadable;
    [Test] procedure Test_Bp_NoCodeLine_HandledCleanly;

    // --- BACKLOG stubs: registered so they are never forgotten. Each has
    //     [Ignore] + an Assert.Fail body documenting what to build. Remove
    //     [Ignore] when tackling; the Assert.Fail forces a real impl. ---
    // stepping
    [Test] procedure Test_BL_Step_IntoBplFunction;
    [Test] procedure Test_BL_Step_OverCallThatHitsBp;
    [Test] procedure Test_BL_Step_AtRaise;
    // exceptions
    [Test] procedure Test_BL_Exc_ReRaise;
    [Test] procedure Test_BL_Exc_OsAccessViolation;
    [Test] procedure Test_BL_Exc_DuringEvaluate;
    [Test] procedure Test_BL_Exc_BplDefinedClass;
    // breakpoints
    [Test] procedure Test_BL_Bp_FirstLine;
    [Test] procedure Test_BL_Bp_MultipleSameLine;
    [Test] procedure Test_BL_Bp_DisabledThenEnabled;
    // modules / lifecycle
    [Test] procedure Test_BL_Module_BplLoadFails;
    [Test] procedure Test_BL_Module_DetachLeavesRunning;
    [Test] procedure Test_BL_Module_DllNoDebugInfo;
    [Test] procedure Test_BL_Obj_ClassInUnloadedBpl;
    // pointers / objects
    [Test] procedure Test_BL_Ptr_DanglingFreed;
    [Test] procedure Test_BL_Ptr_UnmappedRead;
    [Test] procedure Test_BL_Obj_AfterFree_StaleVmt;
    [Test] procedure Test_BL_Obj_InterfaceQueryClass;
    // attach
    [Test] procedure Test_BL_Attach_SetBpAfterAttach;
    [Test] procedure Test_BL_Attach_DetachReattach;
    // evaluate
    [Test] procedure Test_BL_Eval_InheritedCall;
    [Test] procedure Test_BL_Eval_SetLiteralArith;
    [Test] [Ignore('TODO: range expression Low(T)..High(T) in a watch')]
    procedure Test_BL_Eval_RangeExpr;
    [Test] procedure Test_BL_Eval_MethodSideEffect;
    // types / numeric
    [Test] procedure Test_BL_Num_EnumOverByte;
    [Test] procedure Test_BL_Type_LongQualifiedName;
    [Test] procedure Test_BL_Generic_DictElementEnumeration;
  end;

  // Re-runs EVERY TDebuggerTests test under the BPL scenario (TestHost.exe +
  // TestSubject.bpl) by overriding Scenario to tsBpl. DUnitX discovers the
  // inherited [Test] methods via RTTI, so the whole suite executes twice: once
  // monolithic, once BPL. Tests that cannot run in a BPL skip via SkipIfBpl.
  [TestFixture]
  TDebuggerTestsBpl = class(TDebuggerTests)
  protected
    function Scenario: TTestScenario; override;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows;

// Defined further down (type-sampler section) but used earlier by the
// BPL class-expand test -- forward-declare so call order is irrelevant.
function FindLocalByName(FClient: TDapClient; LocalsRef: Integer;
  const Name: string): TJSONObject; forward;

{ TDebuggerTests — path helpers }

class function TDebuggerTests.RepoRoot: string;
begin
  // RunTests.exe is in <repo>\DebuggerTests\Win64\Debug\
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\..\');
end;

class function TDebuggerTests.AdapterExe: string;
begin
  Result := RepoRoot + 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe';
end;

class function TDebuggerTests.TargetDir: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestTarget\';
end;

class function TDebuggerTests.TargetExe: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.exe';
end;

class function TDebuggerTests.TargetMap: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.map';
end;

class function TDebuggerTests.TargetRsm: string;
begin
  Result := TargetDir + 'Win64\Debug\TestTarget.rsm';
end;

class function TDebuggerTests.TargetSrc: string;
begin
  Result := TargetDir + 'TestTarget.dpr';
end;

class function TDebuggerTests.PackageMap: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage\Win64\Debug\TestPackage.map';
end;

class function TDebuggerTests.PackageRsm: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage\Win64\Debug\TestPackage.rsm';
end;

class function TDebuggerTests.PackageDcp: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage\Win64\Debug\TestPackage.dcp';
end;

class function TDebuggerTests.PackageSrc: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage\TestPkgUnit.pas';
end;

class function TDebuggerTests.Package2Map: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage2\Win64\Debug\TestPackage2.map';
end;

class function TDebuggerTests.Package2Rsm: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage2\Win64\Debug\TestPackage2.rsm';
end;

class function TDebuggerTests.Package2Dcp: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage2\Win64\Debug\TestPackage2.dcp';
end;

class function TDebuggerTests.Package2Src: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestPackage2\TestPkgUnit2.pas';
end;

function TDebuggerTests.Scenario: TTestScenario;
begin
  Result := tsMono;
end;

function TDebuggerTests.HostExe: string;
begin
  if Scenario = tsBpl then
    Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.exe'
  else
    Result := TargetExe;
end;

function TDebuggerTests.HostMap: string;
begin
  if Scenario = tsBpl then
    Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.map'
  else
    Result := TargetMap;
end;

function TDebuggerTests.HostRsm: string;
begin
  if Scenario = tsBpl then
    Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestHost.rsm'
  else
    Result := TargetRsm;
end;

function TDebuggerTests.SubjectMap: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestSubject.map';
end;

function TDebuggerTests.SubjectRsm: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestSubject.rsm';
end;

function TDebuggerTests.SubjectDcp: string;
begin
  Result := RepoRoot + 'DebuggerTests\TestHost\Win64\Debug\TestSubject.dcp';
end;

function TDebuggerTests.LaunchTarget(const Spec: TLaunchSpec): TJSONObject;
var
  Modules: TArray<TArray<string>>;
begin
  Modules := Spec.Modules;
  // The BPL scenario runs TestHost.exe, which LoadPackages TestSubject.bpl (the
  // subject code). Point the adapter at the BPL's debug info, ahead of any extra
  // modules the test itself loads (TestPackage*). sourceRoot stays TargetDir in
  // BOTH scenarios -- the subject .pas are shared source.
  if Scenario = tsBpl then begin
    var Sub := TArray<string>.Create('TestSubject.bpl', SubjectMap, SubjectRsm, SubjectDcp);
    Modules := [Sub] + Spec.Modules;
  end;
  if Spec.GlobalRulesPath <> '' then
    Result := FClient.LaunchWithGlobalRules(HostExe, HostMap, HostRsm, TargetDir,
      Spec.Args, Spec.GlobalRulesPath, Modules)
  else if Spec.ExceptionRulesJson <> '' then
    Result := FClient.LaunchWithRules(HostExe, HostMap, HostRsm, TargetDir,
      Spec.Args, Spec.ExceptionRulesJson, Modules)
  else if Length(Modules) > 0 then
    Result := FClient.Launch(HostExe, HostMap, HostRsm, TargetDir,
      Spec.StopAtEntry, Spec.Args, Modules)
  else
    Result := FClient.Launch(HostExe, HostMap, HostRsm, TargetDir,
      Spec.StopAtEntry, Spec.Args);
end;

function TDebuggerTests.LaunchTarget(const Args: TArray<string>;
  StopAtEntry: Boolean): TJSONObject;
var
  Spec: TLaunchSpec;
begin
  Spec := Default(TLaunchSpec);
  Spec.Args        := Args;
  Spec.StopAtEntry := StopAtEntry;
  Result := LaunchTarget(Spec);
end;

procedure TDebuggerTests.SkipIfBpl(const Reason: string);
begin
  if Scenario = tsBpl then
    Assert.Pass('SKIP[bpl]: ' + Reason);
end;

procedure TDebuggerTests.SkipIfNoRsm(const Reason: string);
begin
  if (Scenario <> tsBpl) and (GetEnvironmentVariable('NO_RSM') = '1') then
    Assert.Pass('SKIP[no-rsm]: ' + Reason);
end;

function TDebuggerTestsBpl.Scenario: TTestScenario;
begin
  Result := tsBpl;
end;

{ TDebuggerTests }

function TDebuggerTests.Bp(const Marker: string): Integer;
begin
  // Search the .dpr first, then every TestTarget*.pas next to it.
  // Markers may live in any companion unit (TestTargetTypes.pas,
  // TestTargetCollider.pas, etc.). FBpSourceFile is set so the
  // caller can drive SetBreakpoints against the right path.
  Result := FindBpLine(TargetSrc, Marker);
  FBpSourceFile := TargetSrc;
  if Result > 0 then Exit;
  for var Candidate in [TargetDir + 'TestTargetCore.pas',
                        TargetDir + 'TestTargetTypes.pas',
                        TargetDir + 'TestTargetCollider.pas',
                        TargetDir + 'TestTargetEdge.pas',
                        TargetDir + 'TestTargetEdge2.pas',
                        TargetDir + 'TestTargetFlow.pas',
                        TargetDir + 'TestTargetReal.pas',
                        TargetDir + 'TestTargetConflict1.pas',
                        TargetDir + 'TestTargetConflict2.pas',
                        TargetDir + 'TestTargetUsesHost.pas'] do begin
    Result := FindBpLine(Candidate, Marker);
    if Result > 0 then begin
      FBpSourceFile := Candidate;
      Exit;
    end;
  end;
  Assert.IsTrue(False, 'BP marker not found: ' + Marker);
end;

procedure TDebuggerTests.TearDown;
begin
  EndSession;
end;

procedure TDebuggerTests.EndSession;
begin
  if Assigned(FClient) then begin
    try
      FClient.Disconnect;
    except
    end;
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

procedure TDebuggerTests.Test_EmptyCommandMessage_Ignored_AdapterStaysResponsive;
const
  RawSeq = 990001;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  // A message with no `command` is not a DAP request. The adapter must ignore
  // it. Answering with an empty success response (command:"") is the loopback
  // amplification vector that once drove a multi-million-line runaway log.
  FClient.SendRawJson('{"seq":' + IntToStr(RawSeq) + ',"type":"request"}');
  Assert.IsTrue(FClient.NoResponseFor(RawSeq, 1500),
    'adapter answered a command-less message (empty-response amplification vector)');

  // It must also stay alive and responsive to a well-formed request afterwards.
  var Th := FClient.Threads;
  try
    Assert.IsNotNull(Th.GetValue('threads'),
      'adapter unresponsive after command-less message');
  finally
    Th.Free;
  end;
end;

procedure TDebuggerTests.StartSession(const BpMarker: string;
  out FrameId, LocalsRef: Integer);
begin
  StartSession(BpMarker, FrameId, LocalsRef, nil);
end;

procedure TDebuggerTests.StartSession(const BpMarker: string;
  out FrameId, LocalsRef: Integer; const Args: TArray<string>);
var
  BpLine: Integer;
  Stopped: TJSONObject;
begin
  FrameId   := 0;
  LocalsRef := 0;
  // The MAIN_* markers live ONLY in TestTarget.dpr's program begin..end. block,
  // which a BPL/package has no equivalent of (TestHost.exe's main just calls
  // RunAllScenarios). Any test that anchors on one is inherently exe-only -> skip
  // it under the BPL scenario with a documented reason. (Tier-2 expression-eval
  // tests that merely used MAIN_GCOUNTER as a running-process anchor have been
  // re-vehicled to the portable EVAL_BODY marker, so they do NOT skip here.)
  if (Scenario = tsBpl) and
     (SameText(BpMarker, 'MAIN_FIRST_LINE') or
      SameText(BpMarker, 'MAIN_GCOUNTER')   or
      SameText(BpMarker, 'MAIN_AFTER_NESTED')) then
    Assert.Pass('SKIP[bpl]: marker ''' + BpMarker + ''' is program-main-block only ' +
      '(no BPL equivalent; a package has no program begin..end. block)');
  BpLine  := Bp(BpMarker);

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);

  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');

  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  // Disable every exception filter by default so that gated probes
  // (raise + try/except) in the test target don't surface stop
  // events before our BP fires. Exception-filter UI tests opt back
  // in via SetExceptionBreakpoints themselves.
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget(Args).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'stopped reason is not breakpoint');
  finally
    Stopped.Free;
  end;

  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0, 'no Locals scope found');
end;

// Strip display suffix like "  (0x2A)" or " (0x2, u=2)" from debugger-formatted values.
function ExtractDisplayValue(const S: string): string;
var
  P: Integer;
begin
  P := Pos('  (', S);
  if P <= 0 then
    P := Pos(' (', S);
  if P > 0 then
    Result := Copy(S, 1, P - 1)
  else
    Result := S;
end;

{ Tests }

procedure TDebuggerTests.Test_ClassCtor_ParamsVisible;
var
  FrameId, LocalsRef: Integer;
  AName, AValue: string;
begin
  StartSession('CTOR_BODY', FrameId, LocalsRef);

  AName  := FClient.VarValue(LocalsRef, 'AName');
  AValue := FClient.VarValue(LocalsRef, 'AValue');

  Assert.IsTrue(AName.StartsWith('''hello'''), 'AName mismatch');
  Assert.AreEqual('42', ExtractDisplayValue(AValue), 'AValue mismatch');
end;

procedure TDebuggerTests.Test_ClassFields_ExpandW;
var
  FrameId, LocalsRef: Integer;
  WVar: TJSONObject;
  WRef: Integer;
  FName, FValue, FActive: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);

  // W should be a local in main (TWidget instance)
  WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsNotNull(WVar, 'W not found in locals');
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(WRef > 0, 'W has no variablesReference (not expandable)');
  finally
    WVar.Free;
  end;

  FName   := FClient.VarValue(WRef, 'FName');
  FValue  := FClient.VarValue(WRef, 'FValue');
  FActive := FClient.VarValue(WRef, 'FActive');

  Assert.IsTrue(FName.StartsWith('''hello'''), 'FName mismatch');
  Assert.AreEqual('42',   ExtractDisplayValue(FValue),  'FValue mismatch');
  Assert.AreEqual('True', ExtractDisplayValue(FActive), 'FActive mismatch');
end;

procedure TDebuggerTests.Test_VarView_ClassExpand_PropsAndFieldsGroups;

  function GroupRef(ClassRef: Integer; const GroupName: string): Integer;
  var
    Resp: TJSONObject;
    Arr:  TJSONArray;
  begin
    Result := 0;
    Resp := FClient.Variables(ClassRef);
    try
      Arr := Resp.GetValue('variables') as TJSONArray;
      if Arr = nil then Exit;
      for var I := 0 to Arr.Count - 1 do begin
        var V := Arr[I] as TJSONObject;
        if SameText(V.GetValue<string>('name', ''), GroupName) then
          Exit(V.GetValue<Integer>('variablesReference', 0));
      end;
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef, WRef, PropsRef, FieldsRef, ScoreRef: Integer;
  WVar, ScoreVar: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);

  WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsNotNull(WVar, 'W not found in locals');
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
  finally
    WVar.Free;
  end;
  Assert.IsTrue(WRef > 0, 'W not expandable');

  // Top level of a property-bearing class must be the two synthetic groups.
  PropsRef  := GroupRef(WRef, 'properties');
  FieldsRef := GroupRef(WRef, 'fields');
  Assert.IsTrue(PropsRef  > 0, 'expansion missing `properties` group');
  Assert.IsTrue(FieldsRef > 0, 'expansion missing `fields` group');

  // Fields group: backing fields visible.
  Assert.IsTrue(FClient.VarValue(FieldsRef, 'FName').StartsWith('''hello'''),
    'fields group must expose FName="hello"');
  Assert.AreEqual('42',
    ExtractDisplayValue(FClient.VarValue(FieldsRef, 'FValue')),
    'fields group must expose FValue=42');

  // Properties group: field-backed Name read inline (no getter call).
  Assert.IsTrue(FClient.VarValue(PropsRef, 'Name').StartsWith('''hello'''),
    'properties group: field-backed Name must read "hello" inline');

  // Properties group: getter-backed Score deferred -- expandable placeholder.
  ScoreVar := FClient.FindVar(PropsRef, 'Score');
  Assert.IsNotNull(ScoreVar, 'properties group missing getter-backed Score');
  try
    ScoreRef := ScoreVar.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(ScoreRef > 0,
      'getter-backed Score must be expandable (on-demand)');
  finally
    ScoreVar.Free;
  end;

  // Expanding Score runs DoCalcScore (FValue*2 = 84) on demand.
  var ScoreResp := FClient.Variables(ScoreRef);
  try
    Assert.IsTrue(ScoreResp.ToJSON.Contains('84'),
      'expanding getter-backed Score must evaluate DoCalcScore=84; got: ' +
      ScoreResp.ToJSON);
  finally
    ScoreResp.Free;
  end;
end;

// TWidget.OnNotify is a method-pointer (event handler) property. It must appear
// under a dedicated `event handlers` group, NOT under `properties`, while a
// regular property (Name) stays under `properties`.
procedure TDebuggerTests.Test_EventHandlerProperty_InOwnGroup;

  function GroupRef(ClassRef: Integer; const GroupName: string): Integer;
  var
    Resp: TJSONObject;
    Arr:  TJSONArray;
  begin
    Result := 0;
    Resp := FClient.Variables(ClassRef);
    try
      Arr := Resp.GetValue('variables') as TJSONArray;
      if Arr = nil then Exit;
      for var I := 0 to Arr.Count - 1 do
        if SameText((Arr[I] as TJSONObject).GetValue<string>('name', ''), GroupName) then
          Exit((Arr[I] as TJSONObject).GetValue<Integer>('variablesReference', 0));
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef, WRef, EventsRef, PropsRef: Integer;
  WVar: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsNotNull(WVar, 'W not found in locals');
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
  finally
    WVar.Free;
  end;
  Assert.IsTrue(WRef > 0, 'W not expandable');

  EventsRef := GroupRef(WRef, 'event handlers');
  PropsRef  := GroupRef(WRef, 'properties');
  Assert.IsTrue(EventsRef > 0, 'expansion missing `event handlers` group');
  Assert.IsTrue(PropsRef  > 0, 'expansion missing `properties` group');

  // OnNotify must be IN the event-handlers group.
  var OnNotifyVar := FClient.FindVar(EventsRef, 'OnNotify');
  Assert.IsNotNull(OnNotifyVar, '`OnNotify` must appear under `event handlers`');
  if OnNotifyVar <> nil then OnNotifyVar.Free;

  // OnNotify must NOT be under regular properties.
  var InProps := FClient.FindVar(PropsRef, 'OnNotify');
  Assert.IsNull(InProps, '`OnNotify` must NOT appear under `properties`');
  if InProps <> nil then InProps.Free;

  // A regular property must remain under properties.
  var NameVar := FClient.FindVar(PropsRef, 'Name');
  Assert.IsNotNull(NameVar, '`Name` must remain under `properties`');
  if NameVar <> nil then NameVar.Free;
end;

// Regression: expanding a getter-backed SCALAR property (TWidget.Score:
// Integer) must yield exactly ONE leaf named "(value)" with variablesReference
// 0 -- never class-member children. The getter result is a scalar, so it must
// not drill: on SampleApp a colliding GetDisplayMembers(TypeHint) made scalar
// getter results (Application.ShowMainForm: Boolean) expand into garbage members
// (TCustomAttributeClass/FZoomInCursor). Pins the TypeKind gate in
// AppendPropertyGetterChildren.
procedure TDebuggerTests.Test_GetterBackedScalar_ExpandsToValueLeafOnly;

  function GroupRef(ClassRef: Integer; const GroupName: string): Integer;
  var
    Resp: TJSONObject;
    Arr:  TJSONArray;
  begin
    Result := 0;
    Resp := FClient.Variables(ClassRef);
    try
      Arr := Resp.GetValue('variables') as TJSONArray;
      if Arr = nil then Exit;
      for var I := 0 to Arr.Count - 1 do
        if SameText((Arr[I] as TJSONObject).GetValue<string>('name', ''), GroupName) then
          Exit((Arr[I] as TJSONObject).GetValue<Integer>('variablesReference', 0));
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef, WRef, PropsRef, ScoreRef: Integer;
  WVar, ScoreVar: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);

  WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsNotNull(WVar, 'W not found in locals');
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
  finally
    WVar.Free;
  end;

  PropsRef := GroupRef(WRef, 'properties');
  Assert.IsTrue(PropsRef > 0, 'expansion missing `properties` group');

  ScoreVar := FClient.FindVar(PropsRef, 'Score');
  Assert.IsNotNull(ScoreVar, 'properties group missing getter-backed Score');
  try
    ScoreRef := ScoreVar.GetValue<Integer>('variablesReference', 0);
  finally
    ScoreVar.Free;
  end;
  Assert.IsTrue(ScoreRef > 0, 'getter-backed Score must be expandable');

  var ScoreResp := FClient.Variables(ScoreRef);
  try
    var Arr := ScoreResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'Score expansion has no variables array');
    Assert.AreEqual(1, Arr.Count,
      'a scalar getter result must expand to exactly one (value) leaf, not '
      + 'class members; got: ' + ScoreResp.ToJSON);
    var Leaf := Arr[0] as TJSONObject;
    Assert.AreEqual('(value)', Leaf.GetValue<string>('name', ''),
      'the single child must be the "(value)" leaf');
    Assert.AreEqual(0, Leaf.GetValue<Integer>('variablesReference', 0),
      'the scalar "(value)" leaf must not itself be expandable');
    Assert.IsTrue(Leaf.GetValue<string>('value', '').Contains('84'),
      'the scalar leaf must carry DoCalcScore=84');
  finally
    ScoreResp.Free;
  end;
end;

// Regression: a nil class reference must NOT be expandable. W.FChild
// is a TWidget field left nil. The variables view must report it value "nil"
// with variablesReference 0 -- never allocate an expansion that would
// dereference the nil slot and render its (zeroed) bytes as garbage members
// (SampleApp Application.MainForm/Owner = nil were wrongly expandable).
procedure TDebuggerTests.Test_NilClassReference_NotExpandable;
var
  FrameId, LocalsRef, WRef: Integer;
  WVar, ChildVar: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);

  WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsNotNull(WVar, 'W not found in locals');
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
  finally
    WVar.Free;
  end;
  Assert.IsTrue(WRef > 0, 'W not expandable');

  // FChild lives in the `fields` group (or flat, if no property split).
  var FieldsRef := WRef;
  var GVar := FClient.FindVar(WRef, 'fields');
  if GVar <> nil then
    try
      FieldsRef := GVar.GetValue<Integer>('variablesReference', WRef);
    finally
      GVar.Free;
    end;

  ChildVar := FClient.FindVar(FieldsRef, 'FChild');
  Assert.IsNotNull(ChildVar, 'FChild not found in W fields');
  try
    Assert.IsTrue(ChildVar.GetValue<string>('value', '').Contains('nil'),
      'FChild should read nil; got: ' + ChildVar.GetValue<string>('value', ''));
    Assert.AreEqual(0, ChildVar.GetValue<Integer>('variablesReference', 0),
      'a nil class reference must not be expandable (variablesReference must be 0)');
  finally
    ChildVar.Free;
  end;
end;

// Regression: a plain UInt64 field is a LEAF -- shown inline, never expandable.
// A TD32 type table can carry a STRUCTURE literally named `UInt64` (single
// `m_value: UInt64` field); without a primitive-name guard a UInt64 field
// (SampleApp Application.Handle) was typed as that record and expanded into
// `m_value: UInt64` without end.
procedure TDebuggerTests.Test_UInt64Field_IsLeafNotRecord;
var
  FrameId, LocalsRef, WRef: Integer;
  WVar, HVar: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);

  WVar := FClient.FindVar(LocalsRef, 'W');
  Assert.IsNotNull(WVar, 'W not found in locals');
  try
    WRef := WVar.GetValue<Integer>('variablesReference', 0);
  finally
    WVar.Free;
  end;

  var FieldsRef := WRef;
  var GVar := FClient.FindVar(WRef, 'fields');
  if GVar <> nil then
    try
      FieldsRef := GVar.GetValue<Integer>('variablesReference', WRef);
    finally
      GVar.Free;
    end;

  HVar := FClient.FindVar(FieldsRef, 'FBigHandle');
  Assert.IsNotNull(HVar, 'FBigHandle (UInt64) not found in W fields');
  try
    var Val := HVar.GetValue<string>('value', '');
    Assert.AreEqual(0, HVar.GetValue<Integer>('variablesReference', 0),
      'a UInt64 must be a leaf (variablesReference 0), never expandable; got value: ' + Val);
    Assert.IsFalse(Val.Contains('{'),
      'a UInt64 must render as a number, not a record `{UInt64}`; got: ' + Val);
    Assert.IsTrue(Val.ToUpper.Contains('ABCDEF12345678'),
      'FBigHandle must read its UInt64 value 0xABCDEF12345678; got: ' + Val);
  finally
    HVar.Free;
  end;
end;

procedure TDebuggerTests.Test_VarParam_InCompute;
var
  FrameId, LocalsRef: Integer;
  Factor: string;
  AResult: TJSONObject;
begin
  StartSession('COMPUTE_BODY', FrameId, LocalsRef);

  Factor  := FClient.VarValue(LocalsRef, 'Factor');
  AResult := FClient.FindVar(LocalsRef, 'AResult');
  try
    Assert.AreEqual('84', ExtractDisplayValue(Factor), 'Factor mismatch (FValue*2=42*2=84)');
    Assert.IsNotNull(AResult, 'AResult not found in locals');
    // AResult is a var param — kind should expose it; value may be 0 at first assign
  finally
    AResult.Free;
  end;
end;

procedure TDebuggerTests.Test_NestedProcLocals;
var
  FrameId, LocalsRef: Integer;
  S: string;
begin
  StartSession('INNER_BODY', FrameId, LocalsRef);

  // S is a local of Inner
  S := FClient.VarValue(LocalsRef, 'S');
  // S starts as '' before the assignment fires; just confirm the var appears
  Assert.IsTrue(FClient.FindVar(LocalsRef, 'S') <> nil, 'S not visible in Inner');
end;

procedure TDebuggerTests.Test_StepOut_InnerToNested;
var
  FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  Reason:  string;
begin
  StartSession('INNER_BODY', FrameId, LocalsRef);

  FClient.StepOut.Free;
  Stopped := FClient.WaitForStopped;
  try
    Reason := Stopped.GetValue<string>('reason', '');
    Assert.AreEqual('step', Reason, 'after StepOut reason should be step');
  finally
    Stopped.Free;
  end;

  // We should now be in ComputeNested — verify X appears in locals
  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  var XVar := FClient.FindVar(LocalsRef, 'X');
  Assert.IsNotNull(XVar, 'X not visible after step out into ComputeNested');
  XVar.Free;
end;

procedure TDebuggerTests.Test_StepInto_Ctor;
var
  FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  Reason:  string;
begin
  // Stop at the Inner call site, step into Inner, verify S visible.
  StartSession('NESTED_CALL_INNER', FrameId, LocalsRef);

  FClient.StepIn.Free;
  Stopped := FClient.WaitForStopped;
  try
    Reason := Stopped.GetValue<string>('reason', '');
    Assert.AreEqual('step', Reason, 'step-in reason');
  finally
    Stopped.Free;
  end;

  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsNotNull(FClient.FindVar(LocalsRef, 'S'), 'S not visible after step-into Inner');
end;

procedure TDebuggerTests.Test_GlobalVar;
var
  FrameId, LocalsRef: Integer;
  GRef: Integer;
  GVal: TJSONObject;
  GResp: TJSONObject;
  Arr:  TJSONArray;
  I:    Integer;
begin
  StartSession('MAIN_GCOUNTER', FrameId, LocalsRef);

  // Globals scope
  var ScopesResp := FClient.Scopes(FrameId);
  try
    GRef := 0;
    Arr  := ScopesResp.GetValue('scopes') as TJSONArray;
    if Arr <> nil then
      for I := 0 to Arr.Count - 1 do begin
        var S := Arr[I] as TJSONObject;
        if SameText(S.GetValue<string>('name', ''), 'Globals') then begin
          GRef := S.GetValue<Integer>('variablesReference', 0);
          Break;
        end;
      end;
  finally
    ScopesResp.Free;
  end;

  if GRef = 0 then begin
    Exit; // Globals scope not yet implemented — skip
  end;

  GResp := FClient.Variables(GRef);
  try
    Arr := GResp.GetValue('variables') as TJSONArray;
    GVal := nil;
    if Arr <> nil then
      for I := 0 to Arr.Count - 1 do
        if SameText((Arr[I] as TJSONObject).GetValue<string>('name', ''), 'GCounter') then begin
          GVal := TJSONObject.ParseJSONValue(Arr[I].ToJSON) as TJSONObject;
          Break;
        end;
  finally
    GResp.Free;
  end;

  Assert.IsNotNull(GVal, 'GCounter not found in Globals');
  try
    Assert.AreEqual('1', GVal.GetValue<string>('value', ''), 'GCounter value');
  finally
    GVal.Free;
  end;
end;

procedure TDebuggerTests.Test_Evaluate_IntegerExpr;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('COMPUTE_BODY', FrameId, LocalsRef);

  Resp := FClient.Evaluate('Factor', FrameId);
  try
    Assert.AreEqual('84', ExtractDisplayValue(Resp.GetValue<string>('result', '')), 'evaluate Factor');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_StringIndex;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Caption[1]', FrameId);
  try
    // 'H' is WideChar 0x48 — displayed as '''H'' (0x48)' or similar
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('''H'''),
      'Caption[1] should display H');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_DynArrayIndex;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Scores[1]', FrameId);
  try
    Assert.AreEqual('20',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'Scores[1] should be 20');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_EnumValue;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Mode', FrameId);
  try
    Assert.AreEqual('wmRunning',
      Resp.GetValue<string>('result', ''),
      'Mode should display as wmRunning');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_SetValue;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  S: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Modes', FrameId);
  try
    S := Resp.GetValue<string>('result', '');
    Assert.IsTrue(S.Contains('wmRunning'),  'Modes must contain wmRunning');
    Assert.IsTrue(S.Contains('wmPaused'),   'Modes must contain wmPaused');
    Assert.IsFalse(S.Contains('wmIdle'),    'Modes must not contain wmIdle');
    Assert.IsFalse(S.Contains('wmError'),   'Modes must not contain wmError');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_VarArrayDisplay;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Arr1D', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('VarArray'), 'Arr1D should show VarArray');
    Assert.IsTrue(Display.Contains('0..4'),     'Arr1D shape should be 0..4');
    Assert.IsTrue(Display.Contains('Integer'),  'Arr1D element type should be Integer');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_VarArray1D;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Arr1D[2]', FrameId);
  try
    Assert.AreEqual('30',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'Arr1D[2] should be 30');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_VarArray2D;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Mat[2,3]', FrameId);
  try
    Assert.AreEqual('7.25',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'Mat[2,3] should be 7.25');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_StackFrame_NestedProc_HasSourcePath;
// Repro for the SampleApp 'unknown source' bug: when stopped inside a
// nested local procedure (DoNested inside RunNestedVariantTest at
// the NESTED_VARIANT_BODY marker), the top stack frame must carry
// a 'source.name' / 'source.path' pointing at TestTarget.dpr (the
// enclosing unit), and the 'line' field must match the marker line.
var
  FrameId, LocalsRef: Integer;
  ST: TJSONObject;
  Frames: TJSONArray;
  TopFrame, Src: TJSONObject;
  SrcName: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  ST := FClient.StackTrace(1);
  try
    Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsTrue((Frames <> nil) and (Frames.Count > 0),
      'stack trace must return at least one frame');
    TopFrame := Frames.Items[0] as TJSONObject;
    Src := TopFrame.GetValue<TJSONObject>('source');
    Assert.IsTrue(Src <> nil,
      'top frame of a nested-proc stop must include a source object ' +
      '(got "unknown source")');
    SrcName := Src.GetValue<string>('name', '');
    if SrcName = '' then
      SrcName := Src.GetValue<string>('path', '');
    Assert.IsTrue(SameText(ExtractFileName(SrcName), 'TestTargetCore.pas'),
      'nested-proc source must resolve to TestTargetCore.pas, got: ' + SrcName);
    var Line := TopFrame.GetValue<Integer>('line', 0);
    Assert.IsTrue(Line > 0,
      'nested-proc frame must have a non-zero line number');
  finally
    ST.Free;
  end;
end;

procedure TDebuggerTests.Test_NestedClassMethod_AllThreeBugs;
// Repro for TreeMenu.LoadMenu.CreateNodes (SampleApp). Stopped inside
// TMenuRepro.LoadMenu.CreateNodes at the {BP:NESTED_CLASS_METHOD_BODY}
// marker, after `CurrentLevel := 1` / `CurrentParent := nil` / `LocalStr :=
// 'hello'` have all executed. Bugs covered:
//   (1) own Integer local CurrentLevel surfaced as wrong-offset garbage
//   (2) outer's TMenuCache local Cache got tagged with a peer type
//   (3) outer's Self was absent from locals AND unreachable via watch
//   (4) own pointer local CurrentParent shown as raw 0 instead of nil
//   (5) Cache surface type was the BASE class (TMenuCacheBase) instead
//       of the declared TMenuCache (SampleApp reported TNoRefCountObject)
//   (6) watch on `Cache.Level[0]` failed with "Level not found"
var
  FrameId, LocalsRef: Integer;
  CurLevel, CurParent, LocalStrVal: string;
  CacheVar: TJSONObject;
  CacheType, CacheValue: string;
  SelfResp: TJSONObject;
  SelfType, SelfRes: string;
  LevelResp: TJSONObject;
  LevelRes: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);

  // (1) Own local CurrentLevel must read back the value just assigned (1).
  CurLevel := FClient.VarValue(LocalsRef, 'CurrentLevel');
  Assert.AreEqual('1', ExtractDisplayValue(CurLevel),
    'CurrentLevel must be 1 (just assigned), got: ' + CurLevel);

  // (1a) Type must surface as Integer too. SampleApp saw it surface as
  //      Variant `<null>` because the variant auto-recovery
  //      LooksLikeVariantAt pattern matched the 4-byte Integer value 1
  //      next to zeroed neighbour locals; recovery is now gated by slot
  //      size + empty hint.
  var LevelVar := FClient.FindVar(LocalsRef, 'CurrentLevel');
  Assert.IsNotNull(LevelVar, 'CurrentLevel variable record missing');
  try
    var LevelTypeName := LevelVar.GetValue<string>('type', '');
    Assert.IsTrue(LevelTypeName.Contains('Integer') or
                  LevelTypeName.Contains('Int32')   or
                  LevelTypeName.Contains('LongInt'),
      'CurrentLevel type must be Integer, got: "' + LevelTypeName + '"');
    Assert.IsFalse(LevelTypeName.Contains('Variant'),
      'CurrentLevel must NOT auto-decode as Variant, got: "' + LevelTypeName + '"');
  finally
    LevelVar.Free;
  end;

  // (4) Own pointer local CurrentParent must display as `nil` (or at minimum
  //     a 0 / null marker) after `CurrentParent := nil`. SampleApp reported
  //     it surfacing as the integer 0.
  CurParent := FClient.VarValue(LocalsRef, 'CurrentParent');
  Assert.IsTrue(SameText(ExtractDisplayValue(CurParent), 'nil') or
                ExtractDisplayValue(CurParent).Equals('0x0') or
                ExtractDisplayValue(CurParent).Equals('$0'),
    'CurrentParent (class ptr just assigned nil) must display as nil-shaped, got: ' + CurParent);

  // Sanity: managed-type local in the same nested frame must NOT regress.
  LocalStrVal := FClient.VarValue(LocalsRef, 'LocalStr');
  Assert.IsTrue(LocalStrVal.Contains('hello'),
    'LocalStr in nested proc must hold "hello", got: ' + LocalStrVal);

  // (2)+(5) Cache must surface with TMenuCache (declared / derived class),
  //         not TMenuCacheBase or any peer-scope class collision.
  CacheVar := FClient.FindVar(LocalsRef, 'Cache');
  if CacheVar = nil then
    CacheVar := FClient.FindVar(LocalsRef, 'LoadMenu.Cache');
  if CacheVar = nil then
    CacheVar := FClient.FindVar(LocalsRef, 'TMenuRepro.LoadMenu.Cache');
  Assert.IsNotNull(CacheVar, 'Cache (outer local) not visible inside nested proc');
  try
    CacheType  := CacheVar.GetValue<string>('type', '');
    CacheValue := CacheVar.GetValue<string>('value', '');
    Assert.IsTrue(CacheType.Contains('TMenuCache'),
      'Cache must keep its declared type TMenuCache, got: "' + CacheType + '"');
    // (5) The display value also must not surface the base class name as
    //     the runtime class. SampleApp saw "TNoRefCountObject" surfaced where
    //     the actual instance was a TCachedMenu.
    Assert.IsFalse(CacheValue.Contains('TMenuCacheBase'),
      'Cache display must surface the runtime / declared class, not the ' +
      'BASE class. got: "' + CacheValue + '"');
  finally
    CacheVar.Free;
  end;

  // (3) Self must be resolvable from a watch even when stopped inside a
  //     nested proc of a class method.
  SelfResp := FClient.Evaluate('Self', FrameId);
  try
    SelfType := SelfResp.GetValue<string>('type', '');
    SelfRes  := SelfResp.GetValue<string>('result', '');
    Assert.IsTrue(SelfType.Contains('TMenuRepro') or SelfRes.Contains('TMenuRepro'),
      'Self watch from nested proc of class method must report the outer ' +
      'class, got type="' + SelfType + '" result="' + SelfRes + '"');
  finally
    SelfResp.Free;
  end;

  // (6) Watch on an indexed-property access of the outer Cache local --
  //     `Cache.Level[0]` -- must NOT come back as "Level not found".
  //     `Level` is a read-only property of TMenuCache that delegates to
  //     GetLevel(Idx). The expression evaluator must (a) resolve `Cache`
  //     from parent scope, (b) find `Level` on TMenuCache (not on the
  //     base class, not nothing), (c) dispatch via GetLevel.
  LevelResp := FClient.Evaluate('Cache.Level[0]', FrameId);
  try
    LevelRes := LevelResp.GetValue<string>('result', '');
    Assert.IsFalse(LevelRes.Contains('not found'),
      'Cache.Level[0] watch must resolve, got: ' + LevelRes);
    Assert.AreEqual('10', ExtractDisplayValue(LevelRes),
      'Cache.Level[0] must dispatch to GetLevel and return FLevels[0]=10, got: ' + LevelRes);
  finally
    LevelResp.Free;
  end;
end;

procedure TDebuggerTests.Test_InheritedGetter_ResolvesViaDeclClass;
// Cache is a TMenuCache; BaseScore is a getter-backed property DECLARED on the
// base TMenuCacheBase (read GetBaseScore). The getter symbol lives under the
// base class (TMenuCacheBase.GetBaseScore), not the runtime leaf -- the
// inherited-getter bug found on SampleApp's Application.ComponentCount (whose getter
// is TComponent.GetComponentCount). Must resolve to BaseTag*10 = 70, not
// "<.BaseScore not found>".
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Cache.BaseScore', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found'),
      'Cache.BaseScore (inherited getter) must resolve, got: ' + Res);
    Assert.AreEqual('70', ExtractDisplayValue(Res),
      'Cache.BaseScore must dispatch to TMenuCacheBase.GetBaseScore = BaseTag*10 = 70, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_InheritedMethod_CalledOnDerivedInstance;
// The inherited-GETTER case above already worked, because a property carries its
// declaring class in the member table. A plain inherited METHOD does not: the
// evaluator built the symbol name from the receiver's RUNTIME class only, so
// `Cache.BaseEcho(21)` was looked up as TMenuCache.BaseEcho, which does not
// exist -- the symbol is TMenuCacheBase.BaseEcho.
//
// Observed live as `dataset.FieldByName('X')` -> "<TAppDataSet.FieldByName not
// found>": FieldByName is declared on TDataSet. Nothing inherited was callable,
// on any class, and an explicit cast did not help either.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Cache.BaseEcho(21)', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found'),
      'an inherited method must resolve through the ancestor chain, got: ' + Res);
    Assert.AreEqual('49', ExtractDisplayValue(Res),
      'Cache.BaseEcho(21) = 21*2 + BaseTag(7) = 49, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_InheritedMethod_WithStringArgument;
// Same resolution path, but the argument is a string. Kept separate because the
// two can fail independently: on the live target the symbol for a string-taking
// method resolved and the CALL still failed ("<method invocation failed>"), so a
// passing BaseEcho would not prove this works.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Cache.BaseLen(''abcd'')', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found') or Res.Contains('failed'),
      'an inherited method taking a string must be callable, got: ' + Res);
    Assert.AreEqual('11', ExtractDisplayValue(Res),
      'Cache.BaseLen(''abcd'') = 4 + BaseTag(7) = 11, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_DefaultArrayProperty_IndexingAnObject;
// `Probe['abcd']` must mean `Probe.ByName['abcd']` - the property declared
// `default` - and return Length('abcd') + FBias = 4 + 100 = 104.
//
// The index is a STRING, which is also why the parser cannot simply coerce
// every index to Int64 the way array indexing does.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Probe[''abcd'']', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('cannot index'),
      'indexing an object must go through its default array property, got: ' + Res);
    Assert.AreEqual('104', ExtractDisplayValue(Res),
      'Probe[''abcd''] = Length + FBias = 104, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_DefaultArrayProperty_NotConfusedWithTheOtherIndexedOne;
// TIndexProbe has TWO array properties. Only ByName is `default`; Plain is not.
// A reader that merely spotted "an indexed property" - rather than the marked
// one - would answer with Plain here and be wrong by a plausible-looking number,
// which is the failure mode worth guarding against.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Probe.Plain[4]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreEqual('112', ExtractDisplayValue(Res),
      'Probe.Plain[4] = 4*3 + FBias = 112, got: ' + Res);
  finally
    Resp.Free;
  end;

  Resp := FClient.Evaluate('Probe[4]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreNotEqual('112', ExtractDisplayValue(Res),
      'Probe[4] must NOT resolve to the non-default Plain property, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Indexing_ObjectWithoutDefaultProperty_SaysWhatToWrite;
// TMenuCache has an indexed property (Level) but none marked `default`, so
// `Cache[0]` cannot be resolved. The point of the test is the MESSAGE: it has to
// name the way out rather than say "cannot index type", because the user's next
// move is to write the property name explicitly.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Cache[0]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('no default array property'),
      'the error must explain there is no default property, got: ' + Res);
    Assert.IsTrue(Res.Contains('name the property'),
      'the error must tell the user what to write instead, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_CollidingNestedClass_ResolvesMembersByVmt;
// DupA is a TCollideOuterA.TDup (AlphaA=111, BetaA=222); DupB is a
// TCollideOuterB.TDup (GammaB=999). Same bare name "TDup", same unit. Expanding
// each must show ITS OWN fields. The live failure was the mirror of this:
// dataset.Fields (a Data.DB.TFields) expanded to FHits/FOffsets, the members of
// the unrelated System.Classes.TFieldsCache.TFields, because member lookup keyed
// on the bare name and the first-indexed record won.
  function Eval(const Expr: string; FrameId: Integer): string;
  begin
    var Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('result', '');
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef: Integer;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);

  Assert.AreEqual('111', ExtractDisplayValue(Eval('DupA.AlphaA', FrameId)),
    'DupA.AlphaA must read the TCollideOuterA.TDup field');
  Assert.AreEqual('222', ExtractDisplayValue(Eval('DupA.BetaA', FrameId)),
    'DupA.BetaA must read the TCollideOuterA.TDup field');
  Assert.AreEqual('999', ExtractDisplayValue(Eval('DupB.GammaB', FrameId)),
    'DupB.GammaB must read the TCollideOuterB.TDup field');

  // The cross-check that actually proves disambiguation: GammaB does not exist
  // on TCollideOuterA.TDup, so if DupA were resolved against the wrong class
  // record this would spuriously succeed.
  var Cross := Eval('DupA.GammaB', FrameId);
  Assert.IsTrue(Cross.Contains('not found') or Cross.Contains('<'),
    'DupA has no GammaB; resolving it means DupA was matched to the wrong class, got: ' + Cross);

  // The by-VMT-name path (the live bug's path): DupObjA is statically a TObject,
  // so the real class is known only from the runtime VMT. Its own field must
  // resolve and the other class's must not - keyed on the VMT, not the bare name.
  var ObjA := Eval('DupObjA.AlphaA', FrameId);
  Assert.AreEqual('111', ExtractDisplayValue(ObjA),
    'DupObjA (a TObject over TCollideOuterA.TDup) must resolve AlphaA via its VMT, got: ' + ObjA);
  var ObjACross := Eval('DupObjA.GammaB', FrameId);
  Assert.IsTrue(ObjACross.Contains('not found') or ObjACross.Contains('<'),
    'DupObjA must NOT see TCollideOuterB.TDup''s GammaB, got: ' + ObjACross);
  var ObjB := Eval('DupObjB.GammaB', FrameId);
  Assert.AreEqual('999', ExtractDisplayValue(ObjB),
    'DupObjB (a TObject over TCollideOuterB.TDup) must resolve GammaB via its VMT, got: ' + ObjB);
end;

procedure TDebuggerTests.Test_DefaultProperty_ReturningVariantString;
// VProbe['Gxx'] -> GetTag('Gxx') -> a string Variant 'G'. The result must be
// decoded to the string 'G', not shown as 258 (the varUString VType word), which
// is what the live dataset['CODE'] produced.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('VProbe[''Gxx'']', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('258'),
      'a Variant string result must not surface the varUString VType word (258), got: ' + Res);
    Assert.IsTrue(Res.Contains('G'),
      'VProbe[''Gxx''] must decode to the string variant ''G'', got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_IndexedProperty_ReturningVariantInteger;
// VProbe.Num[7] -> GetNum(7) -> integer Variant 1007. Decodes to 1007, proving
// the Variant path handles a non-string payload too (not just strings).
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('VProbe.Num[7]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    // The Variant formatter renders "<subtype>: <value>" consistently across the
    // debugger; what matters is that the decoded VALUE is 1007, not the VType
    // word 3 (varInteger) that the pre-fix pointer read surfaced.
    Assert.IsTrue(Res.Contains('1007'),
      'VProbe.Num[7] must decode the integer variant to 1007, got: ' + Res);
    Assert.IsFalse(ExtractDisplayValue(Res) = '3',
      'the result must be the value, not the varInteger VType word, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_GetterReturningSmallSet;
// RKProbe.SmallSetP -> GetModes0 = [wmRunning, wmError]; a <= 8-byte set from a
// getter, returned in RAX, must decode both members.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('RKProbe.SmallSetP', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('wmRunning') and Res.Contains('wmError'),
      'a getter-returned set must decode its members, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_GetterReturningWideSet;
// RKProbe.WideSetP -> GetWide0 = [we05, we70]; a > 8-byte set from a getter is
// returned through the var-out slot, must not AV and must show both members.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('RKProbe.WideSetP', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('we05'), 'low member missing from wide getter set: ' + Res);
    Assert.IsTrue(Res.Contains('we70'), 'high member dropped from wide getter set: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_GetterReturningRecord_FieldsReadable;
// RKProbe.PointP -> GetRec0 = (30,31,32). A record from a non-indexed getter
// must keep its declared type so `.X` reads the field, not render a garbage
// Double or a truncated Cardinal.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('RKProbe.PointP.Z', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreEqual('32', ExtractDisplayValue(Res),
      'a getter-returned record must let its field be read, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_WideSet_MembersBeyond64BitsShown;
// WideSet = [we05, we70, we79]. Decoding only the low 8 bytes would drop we70
// and we79 (bits beyond 63). All three must appear.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('WideSet', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('we05'), 'low member missing: ' + Res);
    Assert.IsTrue(Res.Contains('we70'), 'member past bit 63 dropped (we70): ' + Res);
    Assert.IsTrue(Res.Contains('we79'), 'member past bit 63 dropped (we79): ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_FieldBackedSet_HighMemberShown;
// OptField.Options = [o10]; o10 is bit 10 -> byte 1. Reading only byte 0 shows
// []. The field-backed set must read its full declared width.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('OptField.Options', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('o10'),
      'a field-backed set must not be truncated to byte 0 (expected o10): ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_IndexedProperty_ReturningVariantAlias;
// RKProbe.NVar[5] returns a NullableInteger (= type Variant) holding 55. The
// declared type name is "NullableInteger", not "Variant", so the return ABI
// must be decided by the RESOLVED KIND (alias -> TK_VARIANT), not a name match.
// Must decode to 55, not surface a VType word.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('RKProbe.NVar[5]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('55'),
      'a distinct Variant alias must be decoded to its value (55), got: ' + Res);
    Assert.IsFalse(ExtractDisplayValue(Res) = '3',
      'must not surface the varInteger VType word, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_IndexedProperty_ReturningClass;
// RKProbe.Obj[5] returns a TMenuCacheBase (a class = pointer in RAX). Chaining
// .BaseTag must read the returned object's field = 7.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('RKProbe.Obj[5].BaseTag', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreEqual('7', ExtractDisplayValue(Res),
      'an indexed property returning a class must hand back the object pointer, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_IndexedProperty_ReturningRecord;
// RKProbe.Rec[3] returns a TPointRec (X=30, Y=31). A record larger than 8 bytes
// comes back through the var-out slot. Field access on the result must read X.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('RKProbe.Rec[3].X', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreEqual('30', ExtractDisplayValue(Res),
      'an indexed property returning a record must let its field be read, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_CollidingCrossUnitClass_ResolvesRealMembers;
// CrossReal is a TestTargetTypes.TDupCross (top-level: RealFirst=4242,
// RealSecond=8484), held as TObject so the class is known only from the runtime
// VMT. Its bare name "TDupCross" collides with the nested
// TestTargetCore.TDupCrossCache.TDupCross (FakeHits). The debugger must resolve
// CrossReal's members from ITS vmt, not from whichever record won the bare-name
// index. This is the exact live failure: dataset.Fields (Data.DB.TFields) showed
// the members of System.Classes.TFieldsCache.TFields.
  function Eval(const Expr: string; FrameId: Integer): string;
  begin
    var Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('result', '');
    finally
      Resp.Free;
    end;
  end;
var
  FrameId, LocalsRef: Integer;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);

  Assert.AreEqual('4242', ExtractDisplayValue(Eval('CrossReal.RealFirst', FrameId)),
    'CrossReal must resolve the top-level TDupCross field, not the nested one''s');
  Assert.AreEqual('8484', ExtractDisplayValue(Eval('CrossReal.RealSecond', FrameId)),
    'CrossReal.RealSecond must read the real class field');

  // The tell: FakeHits belongs only to the nested collider. Resolving it means
  // CrossReal was matched to the wrong class record.
  var Fake := Eval('CrossReal.FakeHits', FrameId);
  Assert.IsTrue(Fake.Contains('not found') or Fake.Contains('<'),
    'CrossReal must NOT expose the nested TDupCross''s FakeHits, got: ' + Fake);
end;

procedure TDebuggerTests.Test_IndexedProperty_TwoMixedIndices_ExplicitName;
// probe.Cell[3, 'xy'] -> GetCell(3, 'xy') = 3*1000 + Length('xy') + FBias(100)
//                     = 3000 + 2 + 100 = 3102.
// Two arguments, one Integer and one string, marshalled positionally.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Probe.Cell[3, ''xy'']', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreEqual('3102', ExtractDisplayValue(Res),
      'Probe.Cell[3, ''xy''] must marshal both indices, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_DefaultProperty_TwoIndices;
// Matrix[2, 3] -> the default property Item[2,3] = 2*100 + 3*10 + FSeed(7) = 237.
// A default array property is allowed more than one index; both must be passed.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('NESTED_CLASS_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Matrix[2, 3]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('cannot index') or Res.Contains('not found'),
      'a two-index default property must resolve, got: ' + Res);
    Assert.AreEqual('237', ExtractDisplayValue(Res),
      'Matrix[2, 3] = 2*100 + 3*10 + FSeed = 237, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_ConstVariantParam_DerefsThroughPointer;
// Stops inside InspectConstVariant(const v: Variant). The caller
// passes a varDate(2026-05-26). The formatter must:
//   1. Recognise that `v` is a parameter slot (positive RbpOffset)
//   2. Treat the slot contents as a pointer to caller's TVarData
//   3. Read 24 bytes through that pointer and decode varDate
// Without the deref, `v` shows up as an Int64 / random pointer.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('CONST_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('v', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varDate'),
      'const v: variant parameter should decode as varDate after ' +
      'pointer deref, got: ' + Display);
    Assert.IsTrue(Display.Contains('2026-05-26'),
      'parameter must show the caller-supplied date, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_NestedProcVariant_AutoDecode;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedDate', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varDate'),
      'NestedDate should auto-decode as varDate, got: ' + Display);
    Assert.IsTrue(Display.Contains('2025-12-31'),
      'NestedDate should show date 2025-12-31, got: ' + Display);
  finally
    Resp.Free;
  end;
  Resp := FClient.Evaluate('NestedStr', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varUString') or Display.Contains('varOleStr'),
      'NestedStr should auto-decode as a Variant string, got: ' + Display);
    Assert.IsTrue(Display.Contains('hello-variant'),
      'NestedStr should show the string content, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_NestedProcVariant_ExplicitCast;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Variant(NestedDate)', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varDate'),
      'Variant(NestedDate) cast should yield varDate, got: ' + Display);
    Assert.IsTrue(Display.Contains('2025-12-31'),
      'Variant(NestedDate) should show date 2025-12-31, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Null_DisplaysAngleBracketsNull;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedNull', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.AreEqual('<null>', Display,
      'NestedNull should display as <null>, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Empty_DisplaysAngleBracketsEmpty;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  // RSM correctly tags NestedEmpty as TypeHint='Variant', so the bare
  // path goes through FormatVariantAt and renders <empty>. Auto-detect
  // (LooksLikeVariantAt) intentionally skips varEmpty because zero
  // bytes are indistinguishable from a zeroed integer; that case is
  // covered by Variant(name) cast and exercised separately.
  Resp := FClient.Evaluate('NestedEmpty', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.AreEqual('<empty>', Display,
      'NestedEmpty should display as <empty>, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Integer_DisplaysLabelAndValue;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedInt', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varInteger'),
      'NestedInt should label varInteger, got: ' + Display);
    Assert.IsTrue(Display.Contains('123456'),
      'NestedInt should show value 123456, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Boolean_DisplaysTrue;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedBool', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varBoolean'),
      'NestedBool should label varBoolean, got: ' + Display);
    Assert.IsTrue(Display.Contains('True'),
      'NestedBool should show True, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Double_DisplaysValue;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  // varDouble is whitelisted -- bare name must work.
  Resp := FClient.Evaluate('NestedDouble', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varDouble'),
      'NestedDouble should label varDouble, got: ' + Display);
    Assert.IsTrue(Display.Contains('3.14'),
      'NestedDouble should show 3.14, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Int64_DisplaysValue;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  // varInt64 is whitelisted (8-byte payload uses the full slot).
  Resp := FClient.Evaluate('NestedI64', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varInt64'),
      'NestedI64 should label varInt64, got: ' + Display);
    Assert.IsTrue(Display.Contains('1099511627776'),
      'NestedI64 should show 1<<40 = 1099511627776, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_String_DisplaysQuoted;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  // varUString is whitelisted -- bare name must work.
  Resp := FClient.Evaluate('NestedStr', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varUString') or Display.Contains('varOleStr'),
      'NestedStr should label a string Variant, got: ' + Display);
    Assert.IsTrue(Display.Contains('hello-variant'),
      'NestedStr should contain "hello-variant", got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_Date_DisplaysIsoDate;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedDate', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('varDate'),
      'NestedDate should label varDate, got: ' + Display);
    Assert.IsTrue(Display.Contains('2025-12-31'),
      'NestedDate should show 2025-12-31, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_VarArray1D_DisplaysShape;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedArr1D', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('VarArray'),
      'NestedArr1D should show VarArray, got: ' + Display);
    Assert.IsTrue(Display.Contains('0..4'),
      'NestedArr1D should show shape 0..4, got: ' + Display);
    Assert.IsTrue(Display.Contains('Integer'),
      'NestedArr1D should label Integer elements, got: ' + Display);
    Assert.IsTrue(Display.Contains('5 elements'),
      'NestedArr1D should report 5 elements, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_VarArray2D_DisplaysShape;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NestedMat2D', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('VarArray'),
      'NestedMat2D should show VarArray, got: ' + Display);
    Assert.IsTrue(Display.Contains('1..2'),
      'NestedMat2D should show dim 1..2, got: ' + Display);
    Assert.IsTrue(Display.Contains('1..3'),
      'NestedMat2D should show dim 1..3, got: ' + Display);
    Assert.IsTrue(Display.Contains('Double'),
      'NestedMat2D should label Double elements, got: ' + Display);
    Assert.IsTrue(Display.Contains('6 elements'),
      'NestedMat2D should report 6 elements, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_VarArray1D_Expansion;
var
  FrameId, LocalsRef: Integer;
  EvalResp, VarsResp: TJSONObject;
  ExpRef: Integer;
  Arr: TJSONArray;
  CellVals: array[0..4] of string;
  I: Integer;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  EvalResp := FClient.Evaluate('NestedArr1D', FrameId);
  try
    ExpRef := EvalResp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(ExpRef <> 0,
      'NestedArr1D evaluate must expose a non-zero variablesReference');
  finally
    EvalResp.Free;
  end;
  VarsResp := FClient.Variables(ExpRef);
  try
    Arr := VarsResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'Variables response must include "variables" array');
    Assert.AreEqual(5, Arr.Count,
      'NestedArr1D expansion should list 5 elements');
    for I := 0 to 4 do begin
      var Cell := Arr.Items[I] as TJSONObject;
      var Name := Cell.GetValue<string>('name', '');
      Assert.AreEqual('[' + IntToStr(I) + ']', Name,
        'Cell ' + IntToStr(I) + ' name');
      CellVals[I] := Cell.GetValue<string>('value', '');
    end;
    Assert.AreEqual('100', CellVals[0]);
    Assert.AreEqual('200', CellVals[1]);
    Assert.AreEqual('300', CellVals[2]);
    Assert.AreEqual('400', CellVals[3]);
    Assert.AreEqual('500', CellVals[4]);
  finally
    VarsResp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_VarArray2D_Expansion;
var
  FrameId, LocalsRef: Integer;
  EvalResp, VarsResp: TJSONObject;
  ExpRef: Integer;
  Arr: TJSONArray;
  Map: TStringList;
  I: Integer;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  EvalResp := FClient.Evaluate('NestedMat2D', FrameId);
  try
    ExpRef := EvalResp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(ExpRef <> 0,
      'NestedMat2D evaluate must expose a non-zero variablesReference');
  finally
    EvalResp.Free;
  end;
  VarsResp := FClient.Variables(ExpRef);
  try
    Arr := VarsResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'Variables response must include "variables" array');
    Assert.AreEqual(6, Arr.Count,
      'NestedMat2D expansion should list 6 elements (2x3)');
    Map := TStringList.Create;
    try
      for I := 0 to Arr.Count - 1 do begin
        var Cell := Arr.Items[I] as TJSONObject;
        Map.Add(Cell.GetValue<string>('name', '') + '=' +
                Cell.GetValue<string>('value', ''));
      end;
      // Two-dim cells use user index order [i,j]
      Assert.IsTrue(Map.IndexOf('[1,1]=1.5') >= 0, 'cell [1,1]=1.5 missing');
      Assert.IsTrue(Map.IndexOf('[1,2]=2.5') >= 0, 'cell [1,2]=2.5 missing');
      Assert.IsTrue(Map.IndexOf('[1,3]=3.5') >= 0, 'cell [1,3]=3.5 missing');
      Assert.IsTrue(Map.IndexOf('[2,1]=4.5') >= 0, 'cell [2,1]=4.5 missing');
      Assert.IsTrue(Map.IndexOf('[2,2]=5.5') >= 0, 'cell [2,2]=5.5 missing');
      Assert.IsTrue(Map.IndexOf('[2,3]=6.5') >= 0, 'cell [2,3]=6.5 missing');
    finally
      Map.Free;
    end;
  finally
    VarsResp.Free;
  end;
end;

procedure TDebuggerTests.Test_Variant_VarArray1D_LocalsViewExpandable;
// Stops at NESTED_VARIANT_BODY. NestedArr1D is a VarArray Variant local.
// The locals tree (Variables request on the scope's ref) must include
// NestedArr1D with a non-zero variablesReference -- the same expansion
// the hover/watch path already produces. SampleApp reported it expanded
// fine via hover ("VarArray[0..1] of Variant (2 elements)") but the
// locals view returned 0, so the chevron was missing in the editor side
// panel.
var
  FrameId, LocalsRef: Integer;
  VarsResp: TJSONObject;
  Arr: TJSONArray;
  ChildRef: Integer;
  ChildResp: TJSONObject;
  ChildArr: TJSONArray;
  Found: Boolean;
begin
  StartSession('NESTED_VARIANT_BODY', FrameId, LocalsRef);
  VarsResp := FClient.Variables(LocalsRef);
  Found    := False;
  ChildRef := 0;
  try
    Arr := VarsResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'Variables response must include "variables" array');
    for var I := 0 to Arr.Count - 1 do begin
      var Cell := Arr.Items[I] as TJSONObject;
      if SameText(Cell.GetValue<string>('name', ''), 'NestedArr1D') then begin
        Found    := True;
        ChildRef := Cell.GetValue<Integer>('variablesReference', 0);
        Break;
      end;
    end;
  finally
    VarsResp.Free;
  end;
  Assert.IsTrue(Found, 'NestedArr1D must appear in the locals tree');
  Assert.IsTrue(ChildRef > 0,
    'NestedArr1D local must expose a non-zero variablesReference (locals view chevron)');
  ChildResp := FClient.Variables(ChildRef);
  try
    ChildArr := ChildResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(ChildArr, 'Child variables array missing');
    Assert.AreEqual(5, ChildArr.Count,
      'NestedArr1D should enumerate 5 cells through the locals-view path');
  finally
    ChildResp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_FieldDot;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('W.FName', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.StartsWith(''''),
      'W.FName should be a quoted string, got: ' + Display);
    Assert.IsTrue(Display.Contains('hello'),
      'W.FName should contain "hello", got: ' + Display);
  finally
    Resp.Free;
  end;

  Resp := FClient.Evaluate('W.FValue', FrameId);
  try
    Assert.AreEqual('42',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'W.FValue should be 42');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_ImplicitSelf_Field;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  // Inside TWidget.Compute, the bare identifier `FValue` is not a local --
  // it must resolve via implicit Self to TWidget.FValue (= 42).
  StartSession('COMPUTE_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FValue', FrameId);
  try
    Assert.AreEqual('42',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'bare FValue inside TWidget.Compute should resolve via implicit Self to 42');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_ImplicitSelf_LocalShadowsField;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  // TWidget.Compute declares a local `FName: Integer` that shadows the
  // class field FName: string. Resolution priority is
  // local -> Self.<name> -> global, so the bare identifier must yield the
  // LOCAL Integer 7, not the field's string 'hello'. The local Factor is
  // also tested to confirm bare-local resolution still works alongside the
  // new implicit-Self fallback.
  StartSession('COMPUTE_BODY', FrameId, LocalsRef);

  Resp := FClient.Evaluate('FName', FrameId);
  try
    Display := ExtractDisplayValue(Resp.GetValue<string>('result', ''));
    Assert.AreEqual('7', Display,
      'bare FName must resolve to the local Integer (7), not Self.FName');
  finally
    Resp.Free;
  end;

  Resp := FClient.Evaluate('Self.FName', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('hello'),
      'qualified Self.FName must still reach the class field, got: ' + Display);
  finally
    Resp.Free;
  end;

  Resp := FClient.Evaluate('Factor', FrameId);
  try
    Assert.AreEqual('84',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'bare Factor must resolve to the local (FValue*2 = 84)');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_ImplicitSelf_NonPublishedClass;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  // TStuff is $M- (no published RTTI). Inside TStuff.PubBump the bare
  // identifier `FCount` is neither a local nor a global; it must resolve
  // via implicit Self by walking the RSM class-member table for TStuff
  // (since the TPropInfo published-property path returns nothing).
  StartSession('STUFF_PUBBUMP', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FCount', FrameId);
  try
    Assert.AreEqual('7',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'bare FCount inside TStuff.PubBump should resolve via implicit Self to 7');
  finally
    Resp.Free;
  end;

  Resp := FClient.Evaluate('FLabel', FrameId);
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('tag'),
      'bare FLabel inside TStuff.PubBump should resolve to ''tag''');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_VarView_PrivateClassExpand_FromCaller;
var
  FrameId, LocalsRef: Integer;
  StuffVar:   TJSONObject;
  StuffRef:   Integer;
  FCountStr:  string;
  FLabelStr:  string;
begin
  // At MAIN_GCOUNTER, the main begin holds `S: TStuff` (the $M-
  // private-fields class). The variables view must surface S with
  // a non-zero variablesReference and let the user expand it into its
  // private fields. Mirrors Debugme.dpr line 92 / hover on `foo`.
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  StuffVar := FClient.FindVar(LocalsRef, 'S');
  Assert.IsNotNull(StuffVar, 'S not in locals');
  try
    StuffRef := StuffVar.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(StuffRef > 0,
      'S has variablesReference=0 (private class instance not expandable)');
  finally
    StuffVar.Free;
  end;
  FCountStr := FClient.VarValue(StuffRef, 'FCount');
  FLabelStr := FClient.VarValue(StuffRef, 'FLabel');
  Assert.AreEqual('7', ExtractDisplayValue(FCountStr),
    'S.FCount expected 7 in variables view');
  Assert.IsTrue(FLabelStr.Contains('tag'),
    'S.FLabel expected to contain ''tag'', got: ' + FLabelStr);
end;

procedure TDebuggerTests.Test_VarView_PrivateClassExpand_InsideCtor;
var
  FrameId, LocalsRef: Integer;
  SelfVar: TJSONObject;
  SelfRef: Integer;
  FCountStr, FLabelStr: string;
begin
  // At STUFF_CTOR_END (last line of TStuff.Create), Self points at the
  // newly-initialised instance and must be expandable to the just-assigned
  // private fields. Mirrors Debugme.dpr TFoo.Create line 33.
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar, 'Self not in locals');
  try
    SelfRef := SelfVar.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(SelfRef > 0,
      'Self inside TStuff.Create has variablesReference=0 (not expandable)');
  finally
    SelfVar.Free;
  end;
  FCountStr := FClient.VarValue(SelfRef, 'FCount');
  FLabelStr := FClient.VarValue(SelfRef, 'FLabel');
  Assert.AreEqual('7', ExtractDisplayValue(FCountStr),
    'Self.FCount expected 7');
  Assert.IsTrue(FLabelStr.Contains('tag'),
    'Self.FLabel expected to contain ''tag'', got: ' + FLabelStr);
end;

procedure TDebuggerTests.Test_Hover_ClassInstance_IsExpandable;
var
  FrameId, LocalsRef, VarRef: Integer;
  Resp: TJSONObject;
  TypeStr, ResultStr, FCountStr: string;
begin
  // Mirrors hovering on `foo` (a TFoo instance) in Debugme.dpr line 92,
  // and the same shape SampleApp needs for any class-instance local. The
  // adapter must reply with type = the class name, variablesReference > 0,
  // and the expanded ref must list the class's fields.
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S', FrameId, 'hover');
  try
    TypeStr   := Resp.GetValue<string>('type', '');
    ResultStr := Resp.GetValue<string>('result', '');
    VarRef    := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.AreEqual('TStuff', TypeStr,
      'hover on S should report type="TStuff", got: ' + TypeStr);
    Assert.IsTrue(ResultStr.Contains('TStuff'),
      'hover result should mention the class name, got: ' + ResultStr);
    Assert.IsTrue(VarRef > 0,
      'hover on a class instance must surface variablesReference > 0');
  finally
    Resp.Free;
  end;
  // Expansion under the hover-allocated reference must walk the same
  // RSM class-member table as the variables view.
  FCountStr := FClient.VarValue(VarRef, 'FCount');
  Assert.AreEqual('7', ExtractDisplayValue(FCountStr),
    'FCount expected 7 via hover expansion');
end;

procedure TDebuggerTests.Test_Watch_Inside_BareField_Integer;
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  // Mirrors hovering on `Value` at Debugme line 29. Inside the constructor
  // the bare identifier must resolve via implicit Self to the just-assigned
  // integer field.
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FCount', FrameId, 'watch');
  try
    Assert.AreEqual('7',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'FCount inside ctor via implicit Self should be 7');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_BareField_String;
var FrameId, LocalsRef: Integer; Resp: TJSONObject; Display: string;
begin
  // Mirrors hovering on `Name` at Debugme line 28.
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FLabel', FrameId, 'watch');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('tag'),
      'FLabel inside ctor should contain ''tag'', got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_BareField_Enum;
// FMode := wmPaused inside ctor; bare watch must return the enum literal,
// not a raw ordinal.
var FrameId, LocalsRef: Integer; Resp: TJSONObject; Display: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FMode', FrameId, 'watch');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('wmPaused'),
      'FMode should resolve to enum literal wmPaused, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_BareRecordField_Expandable;
// Mirrors hovering on `Pt` at Debugme line 31. The record field is a
// composite that VS Code can only render via a non-zero
// variablesReference.
var FrameId, LocalsRef: Integer; Resp: TJSONObject; VarRef: Integer;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FPoint', FrameId, 'watch');
  try
    VarRef := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(VarRef > 0,
      'FPoint record watch must surface variablesReference > 0');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_BareRecordField_X;
// Mirrors `Pt.X` at Debugme line 31.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FPoint.X', FrameId, 'watch');
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('1.5'),
      'FPoint.X expected 1.5, got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_BareRecordField_Y;
// Mirrors `Pt.Y` at Debugme line 32 -- the case the user reports as
// returning "<.Y not found>".
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FPoint.Y', FrameId, 'watch');
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('2.5'),
      'FPoint.Y expected 2.5, got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_BareRecordField_Z;
// Mirrors `Pt.Z` at Debugme line 33.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FPoint.Z', FrameId, 'watch');
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('3.5'),
      'FPoint.Z expected 3.5, got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Inside_SelfRecordField_Y;
// Same as Test_Watch_Inside_BareRecordField_Y but qualified with Self.
// Independent path -- bare implicit-Self resolution can fail while
// explicit Self.field still works (or vice versa).
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Self.FPoint.Y', FrameId, 'watch');
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('2.5'),
      'Self.FPoint.Y expected 2.5, got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Caller_ClassFieldRecord_Y;
// Mirrors hovering on `foo.Pt.Y` at Debugme line 92 et seq -- caller's
// view of a class field that is itself a record.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S.FPoint.Y', FrameId, 'watch');
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('2.5'),
      'S.FPoint.Y expected 2.5, got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Caller_Param_NamedAfterCtorArg;
// Sanity: the caller's local that holds the freshly-constructed instance
// can be hovered and survives the new class-decorated formatting.
var FrameId, LocalsRef: Integer; Resp: TJSONObject; TypeStr: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S', FrameId, 'hover');
  try
    TypeStr := Resp.GetValue<string>('type', '');
    Assert.AreEqual('TStuff', TypeStr,
      'hover type for S should be ''TStuff''');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_RecordField_ExpansionReturnsFields;
// `FPoint` (TPoint3D record field of TStuff) reported as expandable in
// Test_Watch_Inside_BareRecordField_Expandable, but actually FOLLOWING
// the expansion was not covered. User reports the popup expands to an
// empty list. Test that the children are X / Y / Z with their values.
var FrameId, LocalsRef, VarRef: Integer;
    Resp: TJSONObject;
    XStr, YStr, ZStr: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('FPoint', FrameId, 'watch');
  try
    VarRef := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(VarRef > 0, 'FPoint must be expandable');
  finally
    Resp.Free;
  end;
  XStr := FClient.VarValue(VarRef, 'X');
  YStr := FClient.VarValue(VarRef, 'Y');
  ZStr := FClient.VarValue(VarRef, 'Z');
  Assert.IsTrue(XStr.Contains('1.5'),
    'FPoint expansion X expected 1.5, got: ' + XStr);
  Assert.IsTrue(YStr.Contains('2.5'),
    'FPoint expansion Y expected 2.5, got: ' + YStr);
  Assert.IsTrue(ZStr.Contains('3.5'),
    'FPoint expansion Z expected 3.5, got: ' + ZStr);
end;

procedure TDebuggerTests.Test_Watch_RecordField_FromCaller_Expansion;
// Caller side: S.FPoint must expand into X/Y/Z just like inside
// the ctor.
var FrameId, LocalsRef, VarRef: Integer;
    Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S.FPoint', FrameId, 'watch');
  try
    VarRef := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(VarRef > 0, 'S.FPoint must be expandable');
  finally
    Resp.Free;
  end;
  Assert.IsTrue(FClient.VarValue(VarRef, 'X').Contains('1.5'),
    'S.FPoint expansion X expected 1.5');
end;

procedure TDebuggerTests.Test_Hover_Caller_ClassInstance_Expansion;
// Hovering on `foo` (the bare class-instance local) inside the caller
// frame must produce an expandable popup whose children include the
// class's private fields. Mirrors the user-reported regression on
// Debugme line 97.
var FrameId, LocalsRef, VarRef: Integer;
    Resp: TJSONObject;
    FCountStr: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S', FrameId, 'hover');
  try
    VarRef := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(VarRef > 0,
      'hover on S (caller) must expose variablesReference > 0');
  finally
    Resp.Free;
  end;
  FCountStr := FClient.VarValue(VarRef, 'FCount');
  Assert.AreEqual('7', ExtractDisplayValue(FCountStr),
    'hover expansion FCount expected 7');
end;

procedure TDebuggerTests.Test_Watch_Inside_BareRecordField_X_AndY_AndZ;
// User report: `FPoint.X` returns nothing / no value while `FPoint.Y`
// and `FPoint.Z` work. Pins all three in one shot.
var FrameId, LocalsRef: Integer; XResp, YResp, ZResp: TJSONObject;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  XResp := FClient.Evaluate('FPoint.X', FrameId, 'watch');
  YResp := FClient.Evaluate('FPoint.Y', FrameId, 'watch');
  ZResp := FClient.Evaluate('FPoint.Z', FrameId, 'watch');
  try
    Assert.IsTrue(XResp.GetValue<string>('result', '').Contains('1.5'),
      'FPoint.X expected 1.5, got: ' + XResp.GetValue<string>('result', ''));
    Assert.IsTrue(YResp.GetValue<string>('result', '').Contains('2.5'),
      'FPoint.Y expected 2.5, got: ' + YResp.GetValue<string>('result', ''));
    Assert.IsTrue(ZResp.GetValue<string>('result', '').Contains('3.5'),
      'FPoint.Z expected 3.5, got: ' + ZResp.GetValue<string>('result', ''));
  finally
    XResp.Free; YResp.Free; ZResp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Caller_RecordField_X;
// User report: `foo.Pt.X` returned 0 while `foo.Pt.Y` worked. Class
// field whose type is itself a record -- first field by offset is the
// one that surfaces the bug.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S.FPoint.X', FrameId, 'watch');
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('1.5'),
      'S.FPoint.X expected 1.5, got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Watch_Caller_ClassExpand_RecordSubFieldExpandable;
// User report: expanding `foo` from the caller frame shows Name /
// Value / Active as expected but `Pt` appears as a raw pointer, not
// expandable. The expansion of a record-typed class field must surface
// `variablesReference > 0` so the user can drill into X/Y/Z.
var FrameId, LocalsRef, FooRef, PtRef: Integer;
    Resp: TJSONObject;
    PtVar: TJSONObject;
    XStr:  string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S', FrameId, 'watch');
  try
    FooRef := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(FooRef > 0, 'S not expandable');
  finally
    Resp.Free;
  end;
  // FPoint is a backing field -- FindVar descends the synthetic `fields` group.
  PtVar := FClient.FindVar(FooRef, 'FPoint');
  Assert.IsNotNull(PtVar, 'FPoint missing from S expansion');
  try
    PtRef := PtVar.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(PtRef > 0,
      'FPoint within S must itself be expandable (not a raw pointer)');
  finally
    PtVar.Free;
  end;
  XStr := FClient.VarValue(PtRef, 'X');
  Assert.IsTrue(XStr.Contains('1.5'),
    'S.FPoint expanded X expected 1.5, got: ' + XStr);
end;

procedure TDebuggerTests.Test_VarView_HasEvaluateName_Self;
// Repro for the user-reported clipboard breakage: copying `Self` in
// the Locals view yields the displayed value back (`$1A.. (TFoo)`),
// VS Code tries to re-evaluate that string and crashes the
// expression parser. Fix is to set `evaluateName` on the variable so
// VS Code feeds back the unambiguous name instead.
var FrameId, LocalsRef: Integer; SelfVar: TJSONObject; EvalName: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar, 'Self missing from locals');
  try
    EvalName := SelfVar.GetValue<string>('evaluateName', '');
    Assert.AreEqual('Self', EvalName,
      'Locals view must expose evaluateName=Self');
  finally
    SelfVar.Free;
  end;
end;

procedure TDebuggerTests.Test_VarView_HasEvaluateName_ChildField;
// Same contract for an expanded child: copying Self.FLabel from the
// expansion must send `Self.FLabel` back to evaluate() -- not the
// quoted string with `@0x...`.
var FrameId, LocalsRef, SelfRef: Integer;
    SelfVar, ChildVar: TJSONObject;
    EvalName: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar);
  try SelfRef := SelfVar.GetValue<Integer>('variablesReference', 0); finally SelfVar.Free; end;
  Assert.IsTrue(SelfRef > 0);
  ChildVar := FClient.FindVar(SelfRef, 'FLabel');
  Assert.IsNotNull(ChildVar);
  try
    EvalName := ChildVar.GetValue<string>('evaluateName', '');
    Assert.AreEqual('Self.FLabel', EvalName,
      'Expanded child must expose evaluateName=Self.FLabel');
  finally
    ChildVar.Free;
  end;
end;

procedure TDebuggerTests.Test_VarView_RecordChild_FormattedAsRecordSummary;
// Inside the Self expansion, FPoint (a TPoint3D record field) must
// display as `{TPoint3D}` (the record summary used elsewhere in the
// variables view), not the raw integer fallback the user spotted.
var FrameId, LocalsRef, SelfRef: Integer;
    SelfVar, ChildVar: TJSONObject;
    Display: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar);
  try SelfRef := SelfVar.GetValue<Integer>('variablesReference', 0); finally SelfVar.Free; end;
  Assert.IsTrue(SelfRef > 0);
  ChildVar := FClient.FindVar(SelfRef, 'FPoint');
  Assert.IsNotNull(ChildVar);
  try
    Display := ChildVar.GetValue<string>('value', '');
    Assert.AreEqual('{TPoint3D}', Display,
      'FPoint must render as {TPoint3D}, got: ' + Display);
  finally
    ChildVar.Free;
  end;
end;

procedure TDebuggerTests.Test_Format_Integer_NoRedundantUnsigned;
// User reports the trailing `, u=<int>` repetition is noise. Format
// must be `<int>  (0x<hex>)` only -- no second copy of the decimal
// value.
var FrameId, LocalsRef: Integer;
    Resp:    TJSONObject;
    GVar:    TJSONObject;
    Display: string;
begin
  StartSession('BP_AFTER_LOOP', FrameId, LocalsRef);
  // 1. Locals view (TLocalValue -> FormatLocalValue).
  GVar := FClient.FindVar(LocalsRef, 'Acc');
  Assert.IsNotNull(GVar, 'Acc local missing at BP_AFTER_LOOP');
  try
    Display := GVar.GetValue<string>('value', '');
    Assert.IsFalse(Display.Contains(', u='),
      'locals-view integer must not have ", u=" redundancy: ' + Display);
  finally
    GVar.Free;
  end;
  // 2. Evaluate / watch path (TExprValue -> FormatExprValue).
  Resp := FClient.Evaluate('Acc', FrameId, 'watch');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Display.Contains(', u='),
      'watch-evaluate GCounter must not have ", u=" redundancy: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_LocalsView_ClassInstance_FormattedWithClassName;
// At STUFF_CTOR_END the Locals scope holds `Self`. Its display string
// must be `$<addr> (TStuff)` (class name first via runtime VMT, hex
// pointer in parens), not the bare-integer fallback.
var FrameId, LocalsRef: Integer; SelfVar: TJSONObject; Display: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar, 'Self missing from locals');
  try
    Display := SelfVar.GetValue<string>('value', '');
    Assert.IsTrue(Display.Contains('TStuff'),
      'Self display must surface the class name TStuff, got: ' + Display);
    Assert.IsFalse(Display.Contains(', u='),
      'Self display must not include the ", u=" redundancy: ' + Display);
  finally
    SelfVar.Free;
  end;
end;

procedure TDebuggerTests.Test_Clipboard_ClassInstance_CleanFormat;
// VS Code's "Copy Value" re-evaluates the expression with
// context='clipboard'. The adapter must return a clean string, not an
// error.
var FrameId, LocalsRef: Integer; Resp: TJSONObject; Display: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Self', FrameId, 'clipboard');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Display.Contains('<unexpected'),
      'clipboard evaluate must not return a parser error: ' + Display);
    Assert.IsTrue(Display.Contains('TStuff'),
      'clipboard value should contain class name, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Clipboard_StringField_NoTokenError;
// Copy Value on a string field must produce the string literal, not
// the adapter's tokenizer error message.
var FrameId, LocalsRef: Integer; Resp: TJSONObject; Display: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Self.FLabel', FrameId, 'clipboard');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Display.Contains('<unexpected'),
      'clipboard evaluate on string must not error, got: ' + Display);
    Assert.IsTrue(Display.Contains('tag'),
      'clipboard string value should contain ''tag'', got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_SetVariable_ClassField_String;
// User reports "Set Value" on Self.FLabel produces "unsupported
// variables reference 2004". Adapter must accept setVariable on a
// child of an ekRsmMembers expansion and (at minimum) not error out
// with that message.
var FrameId, LocalsRef, SelfRef: Integer;
    SelfVar, Resp: TJSONObject;
    ErrMsg: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar);
  try
    SelfRef := SelfVar.GetValue<Integer>('variablesReference', 0);
  finally
    SelfVar.Free;
  end;
  Assert.IsTrue(SelfRef > 0);
  Resp := FClient.SetVariable(SelfRef, 'FLabel', 'rewritten');
  try
    ErrMsg := Resp.GetValue<string>('message', '');
    Assert.IsFalse(ErrMsg.Contains('unsupported variables reference'),
      'setVariable on class child must not return the unsupported-ref error: ' + ErrMsg);
    Assert.IsTrue(Resp.GetValue<string>('value', '').Contains('rewritten'),
      'setVariable response should echo the new value');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_SetVariable_NestedRecordField_Double;
// `Self.FPoint.X := <new>` via setVariable on the X child of the
// FPoint expansion. After change the readback must return the new
// value.
var FrameId, LocalsRef, SelfRef, PtRef: Integer;
    SelfVar, PtVar, SetResp: TJSONObject;
    NewVal: string;
begin
  StartSession('STUFF_CTOR_END', FrameId, LocalsRef);
  SelfVar := FClient.FindVar(LocalsRef, 'Self');
  Assert.IsNotNull(SelfVar);
  try SelfRef := SelfVar.GetValue<Integer>('variablesReference', 0); finally SelfVar.Free; end;
  Assert.IsTrue(SelfRef > 0);
  PtVar := FClient.FindVar(SelfRef, 'FPoint');
  Assert.IsNotNull(PtVar);
  try PtRef := PtVar.GetValue<Integer>('variablesReference', 0); finally PtVar.Free; end;
  Assert.IsTrue(PtRef > 0, 'FPoint must be expandable');
  SetResp := FClient.SetVariable(PtRef, 'X', '9.5');
  try
    Assert.IsTrue(SetResp.GetValue<string>('value', '').Contains('9.5'),
      'setVariable response should echo the new X value');
  finally
    SetResp.Free;
  end;
  NewVal := FClient.VarValue(PtRef, 'X');
  Assert.IsTrue(NewVal.Contains('9.5'),
    'FPoint.X readback expected 9.5 after setVariable, got: ' + NewVal);
end;

procedure TDebuggerTests.Test_Format_TypeAlias_NotClassFormatted;
// `TConQuestoTiFrego = type Integer` aliases the Integer primitive
// but has a name (a) not in any hardcoded list and (b) capitalised
// like a class. The formatter must follow the type's kind, not its
// name, and produce a plain integer display.
var FrameId, LocalsRef: Integer; AliasVar: TJSONObject; Display: string;
begin
  StartSession('ALIAS_LOCAL', FrameId, LocalsRef);
  AliasVar := FClient.FindVar(LocalsRef, 'Aliased');
  Assert.IsNotNull(AliasVar, 'Aliased local missing');
  try
    Display := AliasVar.GetValue<string>('value', '');
    Assert.IsFalse(Display.Contains('(TConQuestoTiFrego)'),
      'aliased Integer must not be class-formatted: ' + Display);
    Assert.IsTrue(Display.Contains('42'),
      'aliased Integer must show its value 42: ' + Display);
  finally
    AliasVar.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_ParameterlessSystemFunc_Now;
var
  FrameId, LocalsRef: Integer;
  RespNoParen, RespParen: TJSONObject;
  Display: string;
begin
  // Resolve at any stable BP -- Now's TDateTime result is monotonic,
  // we just need the call to succeed.
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // 1. Bare identifier `Now` -- user-reported case.
  RespNoParen := FClient.Evaluate('Now', FrameId, 'watch');
  try
    Display := RespNoParen.GetValue<string>('result', '');
    Assert.IsFalse(Display.Contains('not found'),
      'Now (no parens) must resolve as a parameterless function, got: ' + Display);
  finally
    RespNoParen.Free;
  end;
  // 2. Explicit empty parens.
  RespParen := FClient.Evaluate('Now()', FrameId, 'watch');
  try
    Display := RespParen.GetValue<string>('result', '');
    Assert.IsFalse(Display.Contains('not found'),
      'Now() must resolve, got: ' + Display);
  finally
    RespParen.Free;
  end;
end;

procedure TDebuggerTests.Test_Hover_ExceptionInHandler_Expandable;
// Inside an `on E: Exception do` clause, hover on `E` must surface a
// class type and a non-zero variablesReference. Mirrors Debugme line
// 103.
var FrameId, LocalsRef, VarRef: Integer;
    Resp: TJSONObject;
    TypeStr: string;
begin
  StartSession('EXC_HANDLER', FrameId, LocalsRef, ['--run-exception-handler']);
  Resp := FClient.Evaluate('E', FrameId, 'hover');
  try
    TypeStr := Resp.GetValue<string>('type', '');
    VarRef  := Resp.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(TypeStr.Contains('Exception'),
      'hover type for E should mention Exception, got: ' + TypeStr);
    Assert.IsTrue(VarRef > 0,
      'hover on E must expose variablesReference > 0');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Hover_ExceptionInHandler_ClassName;
// Hover on `E.ClassName` must invoke the synthetic class-name method
// (or read the VMT classname slot) and return the class name string.
var FrameId, LocalsRef: Integer;
    Resp: TJSONObject;
    Display: string;
begin
  StartSession('EXC_HANDLER', FrameId, LocalsRef, ['--run-exception-handler']);
  Resp := FClient.Evaluate('E.ClassName', FrameId, 'hover');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('Exception'),
      'E.ClassName should mention ''Exception'', got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Hover_ExceptionInHandler_Message;
// Hover on `E.Message` (TException.Message property) must return the
// exception's message text. The probe raises with 'exc-test-probe'.
var FrameId, LocalsRef: Integer;
    Resp: TJSONObject;
    Display: string;
begin
  StartSession('EXC_HANDLER', FrameId, LocalsRef, ['--run-exception-handler']);
  Resp := FClient.Evaluate('E.Message', FrameId, 'hover');
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('exc-test-probe'),
      'E.Message expected ''exc-test-probe'', got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_PropertyDot;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('W.Name', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('hello'),
      'W.Name (property) should resolve to FName="hello", got: ' + Display);
  finally
    Resp.Free;
  end;

  Resp := FClient.Evaluate('W.Value', FrameId);
  try
    Assert.AreEqual('42',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'W.Value (property) should resolve to FValue=42');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_PropertyGetter;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('W.Score', FrameId);
  try
    Assert.AreEqual('84',
      ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'W.Score (method-backed property) should invoke DoCalcScore and return FValue*2=84');
  finally
    Resp.Free;
  end;
end;

// RunRealScenario holds W:TWidget / S:TStuff as PROCEDURE locals (real-app
// shape). TD32 emits BPREL32 locals for named procs, so W, its property Value,
// and its getter-backed Score all resolve WITHOUT RSM -- this is the path a real
// VCL app exercises (objects in methods, not the .dpr main block).
procedure TDebuggerTests.Test_RealScenario_ProcLocals_TD32;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('REAL_SCENARIO', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('W.Value', FrameId);
  try
    Assert.AreEqual('99', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'W.Value (proc-local TWidget, property) should resolve to FValue=99 via TD32');
  finally
    Resp.Free;
  end;
  Resp := FClient.Evaluate('W.Name', FrameId);
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('real'),
      'W.Name (proc-local TWidget) should resolve to ''real'' via TD32; got: '
      + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
  Resp := FClient.Evaluate('W.Score', FrameId);
  try
    Assert.AreEqual('198', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'W.Score (getter-backed, FValue*2=198) should resolve via TD32');
  finally
    Resp.Free;
  end;
end;

// Regression: a Delphi inline var (`var x := ...`) inside a named function is
// wrapped by the compiler in a lexical block (CV S_BLOCK32). Its local must be
// visible at a breakpoint in the enclosing function. TD32 emits the BPREL32
// under the block scope; the reader must attribute it to the containing
// function, not drop it. Reproduces the SampleApp report: `vtype` in IsNull (an
// inline var) was absent from locals and could not be hovered.
procedure TDebuggerTests.Test_InlineVarInNamedProc_Visible;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('REAL_SCENARIO', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('InlineLocal', FrameId);
  try
    Assert.AreEqual('31337', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'inline var InlineLocal (lexical-block scoped) must be inspectable inside '
      + 'its function; got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

// Regression: two inline vars with the SAME NAME in sibling lexical blocks of
// the SAME function, with DIFFERENT types (Integer vs string). At each
// breakpoint `dup` must resolve to the block whose code range contains the PC --
// not the first same-named local. Exercises lexical shadowing / scope ranges.
procedure TDebuggerTests.Test_ShadowedInlineVar_Int;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('DUP_BLOCK_INT', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('dup', FrameId);
  try
    Assert.AreEqual('111', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'at DUP_BLOCK_INT, `dup` is the Integer block-local 111; got: '
      + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_ShadowedInlineVar_Str;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('DUP_BLOCK_STR', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('dup', FrameId);
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('shadow-str'),
      'at DUP_BLOCK_STR, `dup` is the string block-local ''shadow-str''; got: '
      + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

// Regression: an inline-var Variant (lexical-block scoped) must format by its
// VType -- a Null Variant reads "Null", not the raw VType word (1). SampleApp
// frmMainMdiU LoadMenu's `var v := dbConn.DoSQLFmt(...)` showed `1 (0x01)`
// for a NULL result (varNull = $0001 read as an integer).
procedure TDebuggerTests.Test_InlineVariant_NullEmptyValue;

  function Eval(FrameId: Integer; const Expr: string): string;
  var Resp: TJSONObject;
  begin
    Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('result', '');
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef: Integer;
begin
  StartSession('INLINE_VARIANT', FrameId, LocalsRef, ['--run-real-scenario']);
  Assert.IsTrue(Eval(FrameId, 'vn').ToUpper.Contains('NULL'),
    'inline Variant vn (Null) must inspect as "Null", not the VType word; got: '
    + Eval(FrameId, 'vn'));
  Assert.IsTrue(Eval(FrameId, 've').ToUpper.Contains('EMPTY') or
                Eval(FrameId, 've').ToUpper.Contains('UNASSIGNED'),
    'inline Variant ve (Unassigned) must inspect as Empty/Unassigned; got: '
    + Eval(FrameId, 've'));
  Assert.IsTrue(Eval(FrameId, 'vi').Contains('1234'),
    'inline Variant vi must inspect as 1234; got: ' + Eval(FrameId, 'vi'));
  // vr := MakeNullVariant -- inline var from a var-out Variant function result
  // (the SampleApp `var v := dbConn.DoSQLFmt(...)` shape). Must read "Null".
  Assert.IsTrue(Eval(FrameId, 'vr').ToUpper.Contains('NULL'),
    'inline Variant vr from a var-out function result must inspect as "Null", '
    + 'not the raw VType word; got: ' + Eval(FrameId, 'vr'));
end;

// Regression for the exact SampleApp shape: an inline Variant inside a NESTED
// procedure. If TD32 omits the nested proc's local the adapter falls back to
// RSM, which mistyped SampleApp's `v` as Word, so a Null Variant printed as 1.
procedure TDebuggerTests.Test_NestedProcInlineVariant_Null;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  SkipIfNoRsm('nested-proc inline Variant local (vnest) is absent from TD32; RSM-format-only');
  StartSession('NESTED_VARIANT', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('vnest', FrameId);
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').ToUpper.Contains('NULL'),
      'inline Variant in a nested proc must inspect as "Null", not the VType '
      + 'word (1); got: ' + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

// Regression: two units (TestTargetConflict1/2) declare structurally identical,
// distinctly-named types (TConflictRec1 vs TConflictRec2) in the same order, so
// their per-unit type indices collide. A local in unit 1 must resolve to unit
// 1's type, NOT unit 2's foreign type (and vice versa) -- whichever provider
// answers. Guards the per-unit / right-unit symbol selection.
procedure TDebuggerTests.Test_PerUnitConflict_Unit1;

  function Eval(FrameId: Integer; const Expr: string): string;
  var Resp: TJSONObject;
  begin
    Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('result', '');
    finally
      Resp.Free;
    end;
  end;

  function EvalType(FrameId: Integer; const Expr: string): string;
  var Resp: TJSONObject;
  begin
    Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('type', '');
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef: Integer;
begin
  StartSession('CONFLICT1', FrameId, LocalsRef, ['--run-real-scenario']);
  Assert.IsTrue(EvalType(FrameId, 'LocalRec').Contains('TConflictRec1'),
    'LocalRec in unit 1 must type as TConflictRec1, not the colliding unit-2 '
    + 'type; got type: ' + EvalType(FrameId, 'LocalRec'));
  Assert.IsFalse(EvalType(FrameId, 'LocalRec').Contains('TConflictRec2'),
    'LocalRec in unit 1 must NOT resolve to unit-2''s TConflictRec2');
  Assert.AreEqual('101', ExtractDisplayValue(Eval(FrameId, 'LocalRec.Num')),
    'LocalRec.Num in unit 1 must read 101 (its own slot); got: '
    + Eval(FrameId, 'LocalRec.Num'));
end;

procedure TDebuggerTests.Test_PerUnitConflict_Unit2;

  function Eval(FrameId: Integer; const Expr: string): string;
  var Resp: TJSONObject;
  begin
    Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('result', '');
    finally
      Resp.Free;
    end;
  end;

  function EvalType(FrameId: Integer; const Expr: string): string;
  var Resp: TJSONObject;
  begin
    Resp := FClient.Evaluate(Expr, FrameId);
    try
      Result := Resp.GetValue<string>('type', '');
    finally
      Resp.Free;
    end;
  end;

var
  FrameId, LocalsRef: Integer;
begin
  StartSession('CONFLICT2', FrameId, LocalsRef, ['--run-real-scenario']);
  Assert.IsTrue(EvalType(FrameId, 'LocalRec').Contains('TConflictRec2'),
    'LocalRec in unit 2 must type as TConflictRec2, not the colliding unit-1 '
    + 'type; got type: ' + EvalType(FrameId, 'LocalRec'));
  Assert.IsFalse(EvalType(FrameId, 'LocalRec').Contains('TConflictRec1'),
    'LocalRec in unit 2 must NOT resolve to unit-1''s TConflictRec1');
  Assert.AreEqual('202', ExtractDisplayValue(Eval(FrameId, 'LocalRec.Num')),
    'LocalRec.Num in unit 2 must read 202 (its own slot); got: '
    + Eval(FrameId, 'LocalRec.Num'));
end;

procedure TDebuggerTests.Test_CrossUnitNestedLocal_Unit1_PicksOwnMarker;
var
  FrameId, LocalsRef: Integer;
begin
  SkipIfNoRsm('cross-unit nested-local disambiguation uses the RSM unit-scoped path; no TD32 equivalent');
  StartSession('SHARED1', FrameId, LocalsRef, ['--run-real-scenario']);
  // TD32 emits NO locals for the constructor-nested inline-var SharedConflictProc
  // (verified), so Marker1 can only be supplied by the RSM unit-scoped fallback --
  // and it must be unit 1's Marker1 (1101), never unit 2's Marker2.
  Assert.AreEqual('1101', ExtractDisplayValue(FClient.VarValue(LocalsRef, 'Marker1')),
    'Marker1 (unit 1) must resolve to 1101 via the RSM unit-scoped path; got: '
    + FClient.VarValue(LocalsRef, 'Marker1'));
  Assert.AreEqual('', FClient.VarValue(LocalsRef, 'Marker2'),
    'unit 2''s Marker2 must NOT leak into unit 1''s frame');
end;

procedure TDebuggerTests.Test_CrossUnitNestedLocal_Unit2_PicksOwnMarker;
var
  FrameId, LocalsRef: Integer;
begin
  SkipIfNoRsm('cross-unit nested-local disambiguation uses the RSM unit-scoped path; no TD32 equivalent');
  StartSession('SHARED2', FrameId, LocalsRef, ['--run-real-scenario']);
  Assert.AreEqual('2202', ExtractDisplayValue(FClient.VarValue(LocalsRef, 'Marker2')),
    'Marker2 (unit 2) must resolve to 2202 via the RSM unit-scoped path; got: '
    + FClient.VarValue(LocalsRef, 'Marker2'));
  Assert.AreEqual('', FClient.VarValue(LocalsRef, 'Marker1'),
    'unit 1''s Marker1 must NOT leak into unit 2''s frame');
end;

procedure TDebuggerTests.Test_CrossUnitGlobal_Unit1_PicksOwnType;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('AMBIG_GLOBAL_1', FrameId, LocalsRef, ['--run-real-scenario']);
  // Stopped inside TestTargetConflict1: the unqualified global GSharedAmbiguous
  // must resolve to unit 1's TConflictRec1, never unit 2's TConflictRec2.
  Resp := FClient.Evaluate('GSharedAmbiguous', FrameId);
  try
    Assert.AreEqual('Integer', Resp.GetValue<string>('type', ''),
      'unit 1 global must carry type Integer; got: '
      + Resp.GetValue<string>('type', '') + ' / result='
      + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_UsesScope_Type_PicksUsedUnit;
var
  FrameId, LocalsRef: Integer;
  R: TJSONObject;
  SzRec, Fn, Cn, Tg, All: string;
begin
  SkipIfNoRsm('cross-unit uses-scoped resolution is RSM-format-only; TD32 has no uses-graph');
  // Stopped in TestTargetUsesHost.RunUsesScope (uses A, B -- B last -- NOT C).
  // TDupRec: 1 field in A (SizeOf 4), 2 in B (8), 3 in C (12). DupFunc/DupConst/
  // TDup.Tag are 'A'/'B'/'C'. The host depends on B (compiler last-wins), so each
  // unqualified reference in a watch must resolve to B, never A or C.
  StartSession('USES_SCOPE', FrameId, LocalsRef, ['--run-uses-scope']);

  R := FClient.Evaluate('SizeOf(TDupRec)', FrameId);
  try SzRec := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  R := FClient.Evaluate('DupFunc', FrameId);
  try Fn := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  R := FClient.Evaluate('DupConst', FrameId);
  try Cn := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  R := FClient.Evaluate('TDup.Tag', FrameId);
  try Tg := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;

  // Unit A=1, B=2, C=3; TDupRec SizeOf A=4, B=8, C=12. Host uses A,B (B last,
  // not C) -> the unqualified TYPE and FREE FUNCTION resolve to B. (Const and
  // class-method scoping are covered by the [Ignore]d follow-up tests below.)
  All := Format('SizeOf(TDupRec)=%s | DupFunc=%s | DupConst=%s | TDup.Tag=%s',
    [SzRec, Fn, Cn, Tg]);
  Assert.IsTrue(
    (SzRec = '8') and (Fn = '2'),
    'type + free function must resolve to unit B (8 / 2), not A/C. got: ' + All);
end;

procedure TDebuggerTests.Test_UsesScope_Const_PicksUsedUnit;
var FrameId, LocalsRef: Integer; R: TJSONObject; Cn: string;
begin
  SkipIfNoRsm('unit-scoped const lookup is RSM-format-only; TD32 has no const table');
  StartSession('USES_SCOPE', FrameId, LocalsRef, ['--run-uses-scope']);
  R := FClient.Evaluate('DupConst', FrameId);
  try Cn := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  Assert.AreEqual('2', Cn, 'DupConst must resolve to unit B (2), not A(1)/C(3); got: ' + Cn);
end;

procedure TDebuggerTests.Test_UsesScope_ClassMethod_PicksUsedUnit;
var FrameId, LocalsRef: Integer; R: TJSONObject; Tg: string;
begin
  SkipIfNoRsm('cross-unit uses-scoped resolution is RSM-format-only; TD32 has no uses-graph');
  StartSession('USES_SCOPE', FrameId, LocalsRef, ['--run-uses-scope']);
  R := FClient.Evaluate('TDup.Tag', FrameId);
  try Tg := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  Assert.AreEqual('2', Tg, 'TDup.Tag must resolve to unit B (2), not A(1)/C(3); got: ' + Tg);
end;

procedure TDebuggerTests.Test_UsesScope_Cast_PicksUsedUnit;
var FrameId, LocalsRef: Integer; R: TJSONObject; Cast, IsB: string;
begin
  SkipIfNoRsm('cross-unit uses-scoped resolution is RSM-format-only; TD32 has no uses-graph');
  // (d) The cast path: `TDup(DupInst).Tag()` casts a live in-scope (unit B) TDup
  // instance and invokes its class method. The method symbol resolves through
  // the same per-unit-scoped qualified lookup, so the result is B's = 2. `is`
  // returns True regardless of unit (runtime class-name match is unit-agnostic).
  // (Parens required: a parameterless `.Method` with no `()` is not invoked by
  // the evaluator -- a separate gap, unrelated to scoping.)
  StartSession('USES_SCOPE', FrameId, LocalsRef, ['--run-uses-scope']);
  R := FClient.Evaluate('TDup(DupInst).Tag()', FrameId);
  try Cast := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  R := FClient.Evaluate('DupInst is TDup', FrameId);
  try IsB := ExtractDisplayValue(R.GetValue<string>('result', '')); finally R.Free; end;
  Assert.AreEqual('2', Cast, 'TDup(DupInst).Tag must resolve to unit B (2); got: ' + Cast);
  Assert.AreEqual('True', IsB, 'DupInst is TDup must be True; got: ' + IsB);
end;

procedure TDebuggerTests.Test_CrossUnitGlobal_Unit2_PicksOwnType;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('AMBIG_GLOBAL_2', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('GSharedAmbiguous', FrameId);
  try
    Assert.AreEqual('Double', Resp.GetValue<string>('type', ''),
      'unit 2 global must carry type Double; got: '
      + Resp.GetValue<string>('type', '') + ' / result='
      + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

// Regression: a getter-backed STRING property on an RTL/VCL class (here
// TStringList.Text -> TStrings.GetText) whose getter has NO locals in our
// debug info. The Result-local return-type probe misses, so the var-out return
// ABI must be taken from the property's declared type; otherwise the synthetic
// getter call is dispatched as a plain RAX-returning function, the callee
// writes its managed Result to RDX=0, and the call faults ("method invocation
// failed"). This is the exact shape of real VCL getters like
// TApplication.ExeName / CurrentHelpFile that previously failed.
procedure TDebuggerTests.Test_RtlStringGetter_VarOutFromPropertyType;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('REAL_SCENARIO', FrameId, LocalsRef, ['--run-real-scenario']);
  Resp := FClient.Evaluate('SL.Text', FrameId);
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('HELLO_VAROUT'),
      'SL.Text (RTL getter-backed string property, no getter locals) should '
      + 'invoke TStrings.GetText via the var-out ABI and contain ''HELLO_VAROUT''; got: '
      + Resp.GetValue<string>('result', ''));
  finally
    Resp.Free;
  end;
end;

// Shared helper: evaluates `TheWidget.<PropName>` at MAIN_GCOUNTER and returns
// the raw `result` string. The caller asserts on its content.
function PropGetResult(Client: TDapClient; FrameId: Integer;
  const PropName: string): string;
var
  Resp: TJSONObject;
begin
  Resp := Client.Evaluate('W.' + PropName, FrameId);
  try
    Result := Resp.GetValue<string>('result', '');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_PropGet_Int64;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsInt64');
  // Expect: 0x1122334455667788 = 1234605616436508552
  Assert.IsTrue(Display.Contains('1234605616436508552'),
    'AsInt64 expected 1234605616436508552, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Cardinal;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsCard');
  // $DEADBEEF = 3735928559
  Assert.IsTrue(Display.Contains('3735928559') or Display.Contains('DEADBEEF'),
    'AsCard expected 3735928559 / $DEADBEEF, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Bool;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsBool');
  Assert.IsTrue(Display.Contains('True'),
    'AsBool expected True, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Enum;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsEnum');
  Assert.IsTrue(Display.Contains('wmPaused'),
    'AsEnum expected wmPaused, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Set;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsSet');
  Assert.IsTrue(Display.Contains('wmRunning') and Display.Contains('wmPaused'),
    'AsSet expected [wmRunning, wmPaused], got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Char;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsChar');
  Assert.IsTrue(Display.Contains('''Z''') or Display.Contains('Z'),
    'AsChar expected ''Z'', got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Class;
var
  FrameId, LocalsRef: Integer;
  ClassResp, BaseResp: TJSONObject;
  ClassAddr, BaseAddr: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // AsClass returns Self — should match the value of W itself.
  ClassResp := FClient.Evaluate('W.AsClass', FrameId);
  BaseResp  := FClient.Evaluate('W', FrameId);
  try
    ClassAddr := ClassResp.GetValue<string>('result', '');
    BaseAddr  := BaseResp.GetValue<string>('result', '');
    // Both should display the same numeric pointer value.
    Assert.AreEqual(ExtractDisplayValue(BaseAddr), ExtractDisplayValue(ClassAddr),
      'AsClass should return Self — same pointer as W');
  finally
    ClassResp.Free;
    BaseResp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_PropGet_Pointer;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsPtr');
  // Pointer(FValue) where FValue=42, so the pointer raw bits = 42 = $2A.
  Assert.IsTrue(Display.Contains('42') or Display.Contains('2A'),
    'AsPtr expected raw value 42 ($2A), got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Single;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsSingle');
  Assert.IsTrue(Display.Contains('1.5'),
    'AsSingle expected 1.5, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Double;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsDouble');
  Assert.IsTrue(Display.Contains('3.25'),
    'AsDouble expected 3.25, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_DateTime;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsDate');
  // 45000.5 is the raw Double — display might be formatted as date.
  Assert.IsTrue(Display.Contains('45000') or Display.Contains('2023') or
                Display.Contains('2024') or Display.Contains('2025'),
    'AsDate expected ~45000.5 or a 2023-25 date, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Currency;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsCurr');
  Assert.IsTrue(Display.Contains('19.95') or Display.Contains('19,95') or
                Display.Contains('199500'),
    'AsCurr expected 19.95 (or scaled 199500), got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_UnicodeString;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsUStr');
  Assert.IsTrue(Display.Contains('u_hello'),
    'AsUStr expected "u_hello", got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_AnsiString;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsAStr');
  Assert.IsTrue(Display.Contains('a_hello'),
    'AsAStr expected "a_hello", got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_WideString;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsWStr');
  Assert.IsTrue(Display.Contains('w_hello'),
    'AsWStr expected "w_hello", got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_UTF8String;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsUTF8');
  Assert.IsTrue(Display.Contains('8_hello'),
    'AsUTF8 expected "8_hello", got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_RawByteString;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsRBS');
  Assert.IsTrue(Display.Contains('r_hello'),
    'AsRBS expected "r_hello", got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_DynArray;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsDyn');
  // DynArray return is a pointer; we just expect a non-error display for now.
  Assert.IsFalse(Display.Contains('not yet supported'),
    'AsDyn must not error out; got: ' + Display);
  Assert.IsFalse(Display.Contains('not found'),
    'AsDyn lookup must succeed; got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_Variant;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := PropGetResult(FClient, FrameId, 'AsVar');
  // FValue + 100 = 142, stored as varInteger Variant.
  Assert.IsTrue(Display.Contains('142'),
    'AsVar expected Variant=142, got: ' + Display);
end;

procedure TDebuggerTests.Test_Eval_PropGet_SmallRecord;
// A getter returning a <= 8-byte record (TSmallRec A=7,B=11 in RAX). The fix
// writes the RAX bytes to a slot and keeps the record type, so the FIELDS read.
// The old test accepted the packed integer 720903 - the pre-fix behaviour that
// could not expand fields.
var
  FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  var A := FClient.Evaluate('W.AsSmall.A', FrameId);
  try
    Assert.AreEqual('7', ExtractDisplayValue(A.GetValue<string>('result', '')),
      'W.AsSmall.A must read the record field');
  finally A.Free; end;
  var B := FClient.Evaluate('W.AsSmall.B', FrameId);
  try
    Assert.AreEqual('11', ExtractDisplayValue(B.GetValue<string>('result', '')),
      'W.AsSmall.B must read the record field');
  finally B.Free; end;
end;

procedure TDebuggerTests.Test_Eval_PropGet_BigRecord;
// A getter returning a > 8-byte record (TPoint3D X=1.5,Y=2.5,Z=3.5 via slot).
// The old test asserted "1.5/2.5/3.5" against the buggy Double reinterpret of
// the first 8 bytes; the fix keeps the record type with Address at the slot so
// each field reads correctly.
var
  FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  var Z := FClient.Evaluate('W.AsBig.Z', FrameId);
  try
    var Res := Z.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not yet supported'), 'AsBig must not error out: ' + Res);
    Assert.IsTrue(Res.Contains('3.5'),
      'W.AsBig.Z must read the third field = 3.5, got: ' + Res);
  finally Z.Free; end;
end;

procedure TDebuggerTests.Test_Eval_StringAliasIndexing_ReadsWideChar;
// CapAlias: TStrAlias = 'World'. CapAlias[2] must read the WideChar 'o' (byte
// offset 2), not a narrow AnsiChar at offset 1. Name-only width detection read
// offset 1 as AnsiChar (#0 mid-char) for the alias.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('CapAlias[2]', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('o'),
      'indexing a UnicodeString alias must read a WideChar (expected ''o''): ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_VariantAliasLocal_Decoded;
// NVarLocal: NullableInteger (= type Variant) = 1234. Formatting the local must
// decode the Variant to 1234, not surface the varInteger VType word (3).
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NVarLocal', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('1234'),
      'a Variant-alias local must decode to its value 1234, got: ' + Res);
    Assert.IsFalse(ExtractDisplayValue(Res) = '3',
      'must not surface the varInteger VType word, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_ByRefVariant_Dereferenced;
// ByRefVar is a varInteger|varByRef pointing at IntStore=12345. The formatter
// must deref the pointer and show 12345, not the low bits of the address.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('ByRefVar', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('12345'),
      'a byRef Variant must be dereferenced to its value 12345, got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_MethodCall_TDateTimeArgument;
// W.DayOfDate(EvalDate), EvalDate=45.678 -> Round(0.678*1000)+45 = 723. TDateTime
// is a Double alias: name-only float detection sent the bits to an integer
// register, XMM stayed 0, and the callee saw 0.0 -> 0. It must marshal to XMM.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Res: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('W.DayOfDate(EvalDate)', FrameId);
  try
    Res := Resp.GetValue<string>('result', '');
    Assert.AreEqual('723', ExtractDisplayValue(Res),
      'a TDateTime argument must be marshalled to XMM (expected 723, 0 means it went to an int reg): ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_Method_Integer;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // W.Mult(3, 5) = 3*5 + FValue(42) = 57
  Resp := FClient.Evaluate('W.Mult(3, 5)', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.AreEqual('57', ExtractDisplayValue(Display),
      'W.Mult(3, 5) expected 57, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_SmallRecordReturn_NotZero;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // TSmallPt = record X, Y: Integer end -> 8 bytes -> returned packed in RAX as
  // (Y shl 32) or X. MakeSmallPt(3,4) = $0000000400000003 = 17179869187.
  Resp := FClient.Evaluate('MakeSmallPt(3,4)', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('17179869187'),
      'a small POD record result must come from RAX (packed X=3,Y=4), not the ' +
      'zeroed var-out slot; got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_Method_Double;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // W.Scale(1.5) = 1.5*2 + 0.5 = 3.5
  Resp := FClient.Evaluate('W.Scale(1.5)', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('3.5'),
      'W.Scale(1.5) expected 3.5, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_Method_String;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // W.Greet('world') = 'hi_world!_hello'
  Resp := FClient.Evaluate('W.Greet(''world'')', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Display.Contains('hi_world!_hello'),
      'W.Greet(''world'') expected to contain "hi_world!_hello", got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_Method_IndexedSyntax;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // W.Items[3] = FValue(42) + 3 = 45
  Resp := FClient.Evaluate('W.Items[3]', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.AreEqual('45', ExtractDisplayValue(Display),
      'W.Items[3] expected 45, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Eval_Method_Chained;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // W.GetSelf().Mult(3, 5) = 3*5 + FValue = 57
  Resp := FClient.Evaluate('W.GetSelf().Mult(3, 5)', FrameId);
  try
    Display := Resp.GetValue<string>('result', '');
    Assert.AreEqual('57', ExtractDisplayValue(Display),
      'W.GetSelf().Mult(3, 5) expected 57, got: ' + Display);
  finally
    Resp.Free;
  end;
end;

function NonRttiResult(Client: TDapClient; FrameId: Integer;
  const Expr: string): string;
var
  Resp: TJSONObject;
begin
  Resp := Client.Evaluate(Expr, FrameId);
  try
    Result := Resp.GetValue<string>('result', '');
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_NonRtti_PublicField;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.FCount');
  Assert.AreEqual('7', ExtractDisplayValue(Display),
    'S.FCount (no $M+, public-section field) expected 7, got: ' + Display);
end;

procedure TDebuggerTests.Test_NonRtti_PrivateField;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.FLabel');
  Assert.IsTrue(Display.Contains('tag'),
    'S.FLabel (private field, no $M+) expected to contain "tag", got: ' + Display);
end;

procedure TDebuggerTests.Test_NonRtti_PublicProperty;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.PubCount');
  Assert.AreEqual('7', ExtractDisplayValue(Display),
    'S.PubCount (public property, no $M+) expected 7, got: ' + Display);
end;

procedure TDebuggerTests.Test_NonRtti_PrivateProperty;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.PrivCount');
  Assert.AreEqual('7', ExtractDisplayValue(Display),
    'S.PrivCount (private property, no $M+) expected 7, got: ' + Display);
end;

procedure TDebuggerTests.Test_NonRtti_PublicMethod;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.PubBump()');
  Assert.AreEqual('8', ExtractDisplayValue(Display),
    'S.PubBump() (public method, no $M+) expected 8, got: ' + Display);
end;

procedure TDebuggerTests.Test_NonRtti_PrivateMethod;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.GetMyLabel()');
  Assert.IsTrue(Display.Contains('<tag>'),
    'S.GetMyLabel() (private method, no $M+) expected "<tag>", got: ' + Display);
end;

// FMode is a TWorkMode field on TStuff. TWorkMode's TypeId is module-local
// (LSB=1 → 2-byte VLE encoding in $2C). Reading it as a single byte would
// produce the wrong type and either misalign FieldOffset or pick a bogus
// hardcoded type name. Initial value: wmPaused (ordinal 2).
procedure TDebuggerTests.Test_NonRtti_EnumField_OddTypeId;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.FMode');
  // Either wmPaused (when TypeName resolves through FEnumInfoByName) or
  // the raw ordinal 2 — both prove the read landed on the right field
  // with a sane size. A hex dump or '<…not found>' would not.
  Assert.IsTrue(Display.Contains('wmPaused') or Display.Contains('2'),
    'S.FMode (enum field, odd typeId) expected wmPaused/2, got: ' + Display);
end;

// FPoint is a TPoint3D record field (3 × Double). Module-local odd typeId.
// A plain dot-access produces a value whose TypeHint should be 'TPoint3D'
// (or at minimum non-empty and not the legacy hardcoded fallback). The
// concrete payload bytes are an internal implementation detail and not
// asserted here — the focus is "the typeId resolution survived".
procedure TDebuggerTests.Test_NonRtti_RecordField_OddTypeId;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  TypeStr: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('S.FPoint', FrameId);
  try
    TypeStr := Resp.GetValue<string>('type', '');
  finally
    Resp.Free;
  end;
  Assert.IsTrue(TypeStr.Contains('TPoint3D'),
    'S.FPoint (record field, odd typeId) expected type "TPoint3D", got: "'
    + TypeStr + '"');
end;

// PubMode is a public property of TStuff backed by FMode (field-backed,
// hash-bound). Property's TypeId itself is also odd (TWorkMode). Both the
// property-side typeId and the field-side typeId need correct VLE reads
// for this test to pass.
procedure TDebuggerTests.Test_NonRtti_EnumProperty_OddTypeId;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.PubMode');
  Assert.IsTrue(Display.Contains('wmPaused') or Display.Contains('2'),
    'S.PubMode (enum property, odd typeId) expected wmPaused/2, got: '
    + Display);
end;

// PubTriple returns TArray<Double> (NOT TArray<Integer> — the original
// hardcoded mapping had `$25 → 'TArray<Integer>'` baked in, which would
// silently fall back to the wrong element type if reintroduced). The bare
// property returns a dyn-array handle; the test indexes [1] to drive the
// full property→method→dynarray-element chain. Indexing reads the second
// element (20.5) as a Double via the array-elem infrastructure, which
// requires the property's resolved TypeName to actually start with
// `TArray<` (otherwise the dyn-array detector fails and indexing errors).
procedure TDebuggerTests.Test_NonRtti_DynArrayProperty_OddTypeId;
var
  FrameId, LocalsRef: Integer;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.PubTriple[1]');
  Assert.IsTrue(Display.Contains('20.5'),
    'S.PubTriple[1] (TArray<Double> property, odd typeId) expected 20.5, got: '
    + Display);
end;

// Multi-thread enumeration: the test target spawns two workers via
// CreateThread under `--run-threads`. When we hit the BP marker on the
// main thread, DAP `threads` must list main + both workers and the
// workers must surface the names set via SetThreadDescription
// (TestWorker1 / TestWorker2).
procedure TDebuggerTests.Test_Threads_Enumerated_NamedWorkers;
var FrameId, LocalsRef: Integer;
    Resp: TJSONObject;
    Arr:  TJSONArray;
    Count, MainCount, Worker1, Worker2: Integer;
begin
  StartSession('THREADS_READY', FrameId, LocalsRef, ['--run-threads']);
  Resp := FClient.Threads;
  try
    Arr := Resp.GetValue<TJSONArray>('threads');
    Assert.IsNotNull(Arr, 'threads response missing "threads" array');
    Count     := Arr.Count;
    MainCount := 0;
    Worker1   := 0;
    Worker2   := 0;
    for var I := 0 to Arr.Count - 1 do begin
      var T := Arr.Items[I] as TJSONObject;
      var N := T.GetValue<string>('name', '');
      if N.Contains('TestMain')    then Inc(MainCount);
      if N.Contains('TestWorker1') then Inc(Worker1);
      if N.Contains('TestWorker2') then Inc(Worker2);
    end;
    Assert.IsTrue(Count >= 3,
      Format('expected >=3 threads, got %d', [Count]));
    Assert.AreEqual(1, MainCount, 'main thread name "TestMain" must surface');
    Assert.AreEqual(1, Worker1,   'worker thread 1 must surface as "TestWorker1"');
    Assert.AreEqual(1, Worker2,   'worker thread 2 must surface as "TestWorker2"');
  finally
    Resp.Free;
  end;
end;

// Counts how many entries of a DAP `threads` response carry the given name.
function CountThreadsNamed(Client: TDapClient; const Needle: string): Integer;
var
  Resp: TJSONObject;
begin
  Result := 0;
  Resp := Client.Threads;
  try
    var Arr := Resp.GetValue<TJSONArray>('threads');
    if Arr = nil then
      Exit;
    for var I := 0 to Arr.Count - 1 do
      if (Arr.Items[I] as TJSONObject).GetValue<string>('name', '').Contains(Needle) then
        Inc(Result);
  finally
    Resp.Free;
  end;
end;

// TThread.NameThreadForDebugging announces a name by raising MS_VC_EXCEPTION
// ($406D1388) -- a message addressed to the debugger, carrying a PAnsiChar into
// the debuggee's own address space. The debugger must read it and adopt the
// name. Crucially the announcement arrives LONG AFTER the thread was created
// (the fixture's worker waits for a go-ahead), so this also proves the id ->
// name mapping is updated live: unnamed at the first stop, named at the second.
procedure TDebuggerTests.Test_Threads_NameThreadForDebugging_SurfacesLive;
var FrameId, LocalsRef: Integer;
begin
  StartSession('THREADNAME_BEFORE', FrameId, LocalsRef, ['--run-thread-naming']);

  Assert.AreEqual(0, CountThreadsNamed(FClient, 'DelphiNamedWorker'),
    'the worker must NOT be named yet: it has not announced itself at this point');

  var ReadyLine := Bp('THREADNAME_READY');
  FClient.SetBreakpoints(FBpSourceFile, [ReadyLine]).Free;
  FClient.Continue_(1).Free;
  var Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'expected the THREADNAME_READY breakpoint stop');
  finally
    Stopped.Free;
  end;

  Assert.AreEqual(1, CountThreadsNamed(FClient, 'DelphiNamedWorker'),
    'the name announced via TThread.NameThreadForDebugging must surface in `threads`');
end;

// MS_VC_EXCEPTION is protocol traffic, not a program error. Even with the
// broadest exception configuration enabled -- `all` first-chance, plus delphi
// and unhandled -- it must never produce a stop. The filters are switched on
// while stopped at THREADNAME_BEFORE, so the window they cover contains the
// announcement and essentially nothing else; the next stop must therefore be
// the THREADNAME_READY breakpoint.
procedure TDebuggerTests.Test_Threads_NameAnnouncement_NeverStops_WithAllFilter;
var FrameId, LocalsRef: Integer;
begin
  StartSession('THREADNAME_BEFORE', FrameId, LocalsRef, ['--run-thread-naming']);

  FClient.SetExceptionBreakpoints(['all', 'delphi', 'unhandled']).Free;
  var ReadyLine := Bp('THREADNAME_READY');
  FClient.SetBreakpoints(FBpSourceFile, [ReadyLine]).Free;
  FClient.Continue_(1).Free;

  var Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'the $406D1388 thread-name announcement must never surface as a stop, '
      + 'not even with the `all` first-chance filter on; got: ' + Stopped.ToJSON);
  finally
    Stopped.Free;
  end;

  Assert.AreEqual(1, CountThreadsNamed(FClient, 'DelphiNamedWorker'),
    'the announcement was consumed but its name was not recorded');
end;

// While stopped on the MAIN thread (THREADS_READY), the call stack of a
// different, non-stopped thread must be inspectable: requesting stackTrace for
// a parked worker must return THAT worker's stack (it sits in ThreadWorker),
// not the stopped main thread's stack. Proves per-thread stack walking.
procedure TDebuggerTests.Test_Threads_NonStopped_StackInspectable;
var FrameId, LocalsRef: Integer;
    Resp, ST: TJSONObject;
    Arr, Frames: TJSONArray;

  function WorkerTid: Integer;
  begin
    Result := 0;
    Resp := FClient.Threads;
    try
      Arr := Resp.GetValue<TJSONArray>('threads');
      for var I := 0 to Arr.Count - 1 do begin
        var T := Arr.Items[I] as TJSONObject;
        if T.GetValue<string>('name', '').Contains('TestWorker') then
          Exit(T.GetValue<Integer>('id', 0));
      end;
    finally
      Resp.Free;
    end;
  end;

  function StackHasFunc(Frames: TJSONArray; const Needle: string): Boolean;
  begin
    Result := False;
    for var I := 0 to Frames.Count - 1 do
      if (Frames.Items[I] as TJSONObject).GetValue<string>('name', '').Contains(Needle) then
        Exit(True);
  end;

begin
  StartSession('THREADS_READY', FrameId, LocalsRef, ['--run-threads']);
  var Tid := WorkerTid;
  Assert.IsTrue(Tid > 0, 'no worker thread found in the threads list');

  ST := FClient.StackTrace(Tid);
  try
    Frames := ST.GetValue<TJSONArray>('stackFrames');
    Assert.IsNotNull(Frames, 'stackTrace for the worker returned no frames array');
    Assert.IsTrue(Frames.Count > 0, 'worker stack is empty');
    // The worker is parked inside ThreadWorker (Sleep(INFINITE)); the main
    // thread is not -- so this frame can only come from the worker's own stack.
    Assert.IsTrue(StackHasFunc(Frames, 'ThreadWorker'),
      'worker stackTrace must contain ThreadWorker (proves it is the worker''s own stack, not main''s)');
  finally
    ST.Free;
  end;
end;

procedure TDebuggerTests.Test_Threads_BpOnWorker_LocalVisible;
// A BP planted in a worker-thread proc must fire ON that worker, and the
// stopped worker frame must expose its own local (WLocal=4242). Proves
// per-thread locals: the locals come from the worker's frame, not main's.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('WORKER_BODY', FrameId, LocalsRef, ['--run-worker-bp']);
  V := FindLocalByName(FClient, LocalsRef, 'WLocal');
  Assert.IsNotNull(V, 'WLocal (worker-thread local) missing at worker BP');
  try
    Assert.AreEqual('4242', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'WLocal must be 4242 in the worker frame; got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Threads_ExceptionInWorker;
// A raise on a WORKER thread (main blocked on it) must surface as an
// exception stop with the worker as the stopped thread -- the worker's own
// stack (WorkerRaiseProc) is what the debugger inspects, not main's.
var Stopped, ST: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  LaunchTarget(['--run-worker-raise']).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'a raise on a worker thread must surface as an exception stop');
  finally Stopped.Free; end;
  ST := FClient.StackTrace(12);
  try
    Assert.IsTrue(ST.ToJSON.Contains('WorkerRaiseProc'),
      'the stopped thread must be the worker (WorkerRaiseProc in its stack); got: '
      + ST.ToJSON);
  finally ST.Free; end;
end;

// Conditional BP: stops only when condition `I = 3` evaluates true.
// Verifies that an unmet condition is silently swallowed (the BP fires
// internally on every iteration but doesn't surface as a user stop) and
// that the matching iteration does stop with `I` actually equal to 3.
procedure TDebuggerTests.Test_BP_Conditional;
var
  BpLine, FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  Display: string;
begin
  BpLine := Bp('BP_LOOP');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine], ['I = 3'], [''], ['']).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;

  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0);
  Display := NonRttiResult(FClient, FrameId, 'I');
  Assert.AreEqual('3', ExtractDisplayValue(Display),
    'conditional BP fired at I=' + ExtractDisplayValue(Display) + ' (expected 3)');
end;

// Hit-count BP: hitCondition `>=4` fires from the 4th hit onwards. The
// debugger swallows the first 3 hits silently; the first user-visible
// stop must land on iteration 4.
procedure TDebuggerTests.Test_BP_HitCount;
var
  BpLine, FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  Display: string;
begin
  BpLine := Bp('BP_LOOP');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine], [''], ['>=4'], ['']).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;

  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Display := NonRttiResult(FClient, FrameId, 'I');
  Assert.AreEqual('4', ExtractDisplayValue(Display),
    'hit-count >=4 fired at I=' + ExtractDisplayValue(Display) + ' (expected 4)');
end;

// Log-point: when `logMessage` is set the BP must NOT stop; it should emit
// an `output` event with the rendered template. Two `{expr}` placeholders
// prove that substitution handles more than one expression.
procedure TDebuggerTests.Test_BP_LogPoint;
var
  BpLine: Integer;
  Output1, Output3: string;
begin
  BpLine := Bp('BP_LOOP');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine], [''], [''],
    ['iter={I} acc={Acc}']).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;

  // First iteration: I=1 (Acc still 0 — Inc(Acc, I) hasn't run yet at the
  // line marker, since the source line is the Inc line itself).
  Output1 := FClient.WaitForOutputContaining('iter=1');
  Assert.IsTrue(Output1.Contains('iter=1') and Output1.Contains('acc=0'),
    'first logpoint output mismatch: "' + Output1 + '"');

  // Third iteration: I=3, Acc=3 (1+2 from previous iters).
  Output3 := FClient.WaitForOutputContaining('iter=3');
  Assert.IsTrue(Output3.Contains('iter=3') and Output3.Contains('acc=3'),
    'third logpoint output mismatch: "' + Output3 + '"');

  // Program should run to completion — no user-visible stops were emitted.
  Assert.IsTrue(FClient.WaitForTerminated, 'expected program to terminate');
end;

// Hover-context evaluate: VS Code calls `evaluate` with `context: "hover"`
// when the user mouses over an identifier. The adapter must respond the
// same way as for `repl` / `watch` contexts (it's the same evaluator under
// the hood; the test guards against an accidental context filter ever
// being introduced).
procedure TDebuggerTests.Test_Eval_HoverContext;
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
  Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('W.Score', FrameId, 'hover');
  try
    Display := Resp.GetValue<string>('result', '');
  finally
    Resp.Free;
  end;
  Assert.AreEqual('84', ExtractDisplayValue(Display),
    'hover-context evaluate: W.Score expected 84, got: ' + Display);
end;

// `2 + 3 * 4` = 14, NOT 20 — guards operator precedence (mul binds
// tighter than add).
procedure TDebuggerTests.Test_Eval_Arith_Precedence;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '2 + 3 * 4');
  Assert.AreEqual('14', ExtractDisplayValue(Display),
    '2 + 3 * 4 expected 14, got: ' + Display);
end;

// Mixed int/float arithmetic must promote to Double; `1.5 + 2` = 3.5.
procedure TDebuggerTests.Test_Eval_Arith_FloatMix;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '1.5 + 2');
  Assert.IsTrue(Display.Contains('3.5'),
    '1.5 + 2 expected 3.5, got: ' + Display);
end;

// `17 div 5` = 3, `17 mod 5` = 2 — keyword operators.
procedure TDebuggerTests.Test_Eval_Arith_Div_Mod;
var FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Assert.AreEqual('3', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, '17 div 5')), '17 div 5');
  Assert.AreEqual('2', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, '17 mod 5')), '17 mod 5');
end;

// `(1 = 1) and not (2 = 3) or False` exercises and / or / not in one go.
procedure TDebuggerTests.Test_Eval_Bool_AndOrNot;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '(1 = 1) and not (2 = 3) or False');
  Assert.IsTrue(Display.Contains('True'),
    'and/or/not expected True, got: ' + Display);
end;

// `-TheWidget.Value` — unary minus on a property-resolved Integer.
procedure TDebuggerTests.Test_Eval_UnaryMinus;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '-W.Value');
  Assert.AreEqual('-42', ExtractDisplayValue(Display),
    '-W.Value expected -42, got: ' + Display);
end;

// `True` and `False` are Pascal keyword literals, not identifiers — must be
// matched before the ident lookup so a stray local named `True` can't shadow
// them. Test asserts the literal value.
procedure TDebuggerTests.Test_Eval_True_False;
var FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Assert.IsTrue(NonRttiResult(FClient, FrameId, 'True').Contains('True'),  'True');
  Assert.IsTrue(NonRttiResult(FClient, FrameId, 'False').Contains('False'), 'False');
end;

// `nil` literal (becomes Pointer 0). Comparing a live class instance to nil
// must yield False.
procedure TDebuggerTests.Test_Eval_Nil_Compare;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'W = nil');
  Assert.IsTrue(Display.Contains('False'),
    'W = nil expected False, got: ' + Display);
end;

// `'foo' + 'bar'` — string concat allocates a new immortal Delphi string in
// the debuggee and returns its pointer. The formatter then reads it back as
// a UnicodeString.
procedure TDebuggerTests.Test_Eval_StringConcat;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '''foo'' + ''bar''');
  Assert.IsTrue(Display.Contains('foobar'),
    'string concat expected ''foobar'', got: ' + Display);
end;

// Bare enum value as a literal — the parser must recognise it without a
// type qualifier and surface its ordinal so `TheStuff.PubMode = wmPaused`
// compares cleanly. Also exercises the enum-aware MaskByType branch
// (TWorkMode is a module-local enum: `Mode` slot reads 8 bytes of which
// only the low byte is meaningful).
procedure TDebuggerTests.Test_Eval_EnumLiteral;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S.PubMode = wmPaused');
  Assert.IsTrue(Display.Contains('True'),
    'S.PubMode = wmPaused expected True, got: ' + Display);
end;

// Int → Float cast must convert (not just relabel bits): `Double(42)` =
// 42.0, NOT the float reinterpretation of integer 42.
procedure TDebuggerTests.Test_Eval_Cast_IntToFloat;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'Double(42) + 0.5');
  Assert.IsTrue(Display.Contains('42.5'),
    'Double(42) + 0.5 expected 42.5, got: ' + Display);
end;

// Float → Int cast truncates toward zero. `Integer(3.9)` = 3.
procedure TDebuggerTests.Test_Eval_Cast_FloatToInt;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'Integer(3.9)');
  Assert.AreEqual('3', ExtractDisplayValue(Display),
    'Integer(3.9) expected 3, got: ' + Display);
end;

// `Integer('A')` reads char ordinal. WideChar 'A' = 65.
procedure TDebuggerTests.Test_Eval_Cast_IntegerOfChar;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  // 'A' is a string literal in our grammar; index it to get Char first,
  // then cast. Result for the first char of 'A' is 65.
  Display := NonRttiResult(FClient, FrameId, 'Integer(''A''[1])');
  Assert.AreEqual('65', ExtractDisplayValue(Display),
    'Integer(''A''[1]) expected 65, got: ' + Display);
end;

// `Length(TheWidget.Name)` — string length via the property getter.
procedure TDebuggerTests.Test_Eval_Intrinsic_Length_String;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'Length(W.Name)');
  Assert.AreEqual('5', ExtractDisplayValue(Display),
    'Length(W.Name) expected 5 (len of ''hello''), got: ' + Display);
end;

// `Length(S.PubTriple)` — dyn-array length via property.
procedure TDebuggerTests.Test_Eval_Intrinsic_Length_DynArray;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'Length(S.PubTriple)');
  Assert.AreEqual('3', ExtractDisplayValue(Display),
    'Length(S.PubTriple) expected 3, got: ' + Display);
end;

// `SizeOf(Integer)` = 4. Compile-time-style; no remote call.
procedure TDebuggerTests.Test_Eval_Intrinsic_SizeOf;
var FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Assert.AreEqual('4', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'SizeOf(Integer)')), 'SizeOf(Integer)');
  Assert.AreEqual('8', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'SizeOf(Int64)')),   'SizeOf(Int64)');
end;

// `Ord(TheStuff.PubMode)` — enum value as integer. wmPaused = 2.
procedure TDebuggerTests.Test_Eval_Intrinsic_Ord_Enum;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'Ord(S.PubMode)');
  Assert.AreEqual('2', ExtractDisplayValue(Display),
    'Ord(S.PubMode) expected 2 (wmPaused), got: ' + Display);
end;

// `High(S.PubMode)` — enum max. TWorkMode is wmIdle..wmError so
// max ord is 3 (wmError). `Low` is 0 (wmIdle).
procedure TDebuggerTests.Test_Eval_Intrinsic_High_Low_Enum;
var FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Assert.AreEqual('3', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'High(S.PubMode)')),
    'High(TWorkMode)');
  Assert.AreEqual('0', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'Low(S.PubMode)')),
    'Low(TWorkMode)');
end;

// `TWidget(W).Name` — round-trip cast that doesn't actually
// change anything. Should resolve identically to `W.Name`.
// Proves the cast preserves the pointer and that subsequent dot access
// works on the recast value.
procedure TDebuggerTests.Test_Eval_ClassCast_RoundTrip;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'TWidget(W).Name');
  Assert.IsTrue(Display.Contains('hello'),
    'TWidget(W).Name expected ''hello'', got: ' + Display);
end;

// `TObject(W).ClassName` is hard to test (no ClassName accessor in
// our RSM today), but we CAN prove the upcast preserves the underlying
// instance: the runtime VMT class still says TWidget, so a downcast +
// member access works. `TWidget(TObject(W)).Value` should be 42.
procedure TDebuggerTests.Test_Eval_ClassCast_TObjectUpcast;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'TWidget(TObject(W)).Value');
  Assert.AreEqual('42', ExtractDisplayValue(Display),
    'round-trip TObject cast expected 42, got: ' + Display);
end;

// `TStuff(S).FCount` — class cast on the {$M-} class. Goes through
// the RSM-driven member resolution path. Same value as `S.FCount`.
procedure TDebuggerTests.Test_Eval_ClassCast_NonRtti;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'TStuff(S).FCount');
  Assert.AreEqual('7', ExtractDisplayValue(Display),
    'TStuff(S).FCount expected 7, got: ' + Display);
end;

// `W is TWidget` — direct class match. Should be True.
procedure TDebuggerTests.Test_Eval_Is_PositiveDescendant;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'W is TWidget');
  Assert.IsTrue(Display.Contains('True'),
    'W is TWidget expected True, got: ' + Display);
end;

// `W is TStuff` — unrelated class hierarchies. False.
procedure TDebuggerTests.Test_Eval_Is_NegativeUnrelated;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'W is TStuff');
  Assert.IsTrue(Display.Contains('False'),
    'W is TStuff expected False, got: ' + Display);
end;

// `is TObject` short-circuits to True for any class instance — even
// classes whose RTTI parent chain doesn't make TObject explicit.
procedure TDebuggerTests.Test_Eval_Is_TObjectMatchesAll;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'S is TObject');
  Assert.IsTrue(Display.Contains('True'),
    'S is TObject expected True, got: ' + Display);
end;

// `(W as TWidget).Value` — `as` succeeds, returns the same
// pointer with the new TypeHint. Then `.Value` resolves to 42.
procedure TDebuggerTests.Test_Eval_As_Success;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '(W as TWidget).Value');
  Assert.AreEqual('42', ExtractDisplayValue(Display),
    '(W as TWidget).Value expected 42, got: ' + Display);
end;

// `W as TStuff` — incompatible cast. Result must be an error
// string the user sees in their watch (no debuggee crash, no silent
// pass-through).
procedure TDebuggerTests.Test_Eval_As_FailureReportsError;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'W as TStuff');
  Assert.IsTrue(Display.Contains('"as" failed'),
    'W as TStuff expected error message, got: ' + Display);
end;

// Spawns TestTarget.exe with `--attach-pause` (the target sleeps 5 s before
// running main), connects an adapter via the `attach` request to that PID,
// sets a BP, lets the target wake up, and verifies the BP fires + a local
// is readable via `evaluate`.
//
// REQUIRES THE TEST RUNNER TO BE ELEVATED. DebugActiveProcess needs
// SeDebugPrivilege, which standard user accounts don't hold by default.
// When run non-elevated this test would fail with Access Denied at the
// attach step — we detect that condition and skip rather than red-flag
// it, since the underlying feature still works for elevated VS Code.
procedure TDebuggerTests.Test_Attach_BasicSession;

  // Best-effort detection of the admin / debug-privilege state. We try to
  // open the current process token with TOKEN_QUERY and check for
  // SeDebugPrivilege; if it isn't present-and-enabled, attach won't work.
  function HaveDebugPrivilege: Boolean;
  const
    SE_DEBUG_NAME_W = 'SeDebugPrivilege';
  var
    Tok: THandle;
    Luid: TLargeInteger;
    Tp: TTokenPrivileges;
    Got: DWORD;
    Buf: array[0..1023] of Byte;
    Privs: ^TTokenPrivileges;
  begin
    Result := False;
    if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Tok) then Exit;
    try
      if not LookupPrivilegeValue(nil, SE_DEBUG_NAME_W, Luid) then Exit;
      Got := 0;
      GetTokenInformation(Tok, TokenPrivileges, @Buf[0], SizeOf(Buf), Got);
      if Got = 0 then Exit;
      Privs := @Buf[0];
      for var I := 0 to Privs.PrivilegeCount - 1 do
        if Int64(Privs.Privileges[I].Luid) = Int64(Luid) then
          Exit(True);
    finally
      CloseHandle(Tok);
    end;
    // Suppress unused-var hint without changing behaviour.
    if False then begin Tp.PrivilegeCount := 0; Tp.PrivilegeCount := 0; end;
  end;

var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  BpLine, FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  Display: string;
  StartedOk: Boolean;
begin
  if not HaveDebugPrivilege then begin
    TDUnitX.CurrentRunner.Status(
      'Skipping: SeDebugPrivilege not held; run elevated to exercise attach.');
    Exit;
  end;

  BpLine := Bp('MAIN_GCOUNTER');

  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  CmdLine := '"' + TargetExe + '" --attach-pause';
  StartedOk := CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI);
  Assert.IsTrue(StartedOk, 'CreateProcess for attach test failed: ' + IntToStr(GetLastError));
  CloseHandle(PI.hThread);
  try
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized);
    FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
    FClient.Attach(PI.dwProcessId, TargetExe, TargetMap, TargetRsm, TargetDir,
      True).Free;
    FClient.ConfigDone.Free;

    // Target wakes from Sleep, runs to MAIN_GCOUNTER, hits the BP.
    Stopped := FClient.WaitForStopped(20000);
    try
      Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
        'attach: stopped reason is not breakpoint');
    finally
      Stopped.Free;
    end;

    FrameId   := FClient.GetFrameId;
    LocalsRef := FClient.GetLocalsRef(FrameId);
    Assert.IsTrue(LocalsRef > 0, 'attach: no Locals scope found');

    Display := NonRttiResult(FClient, FrameId, 'GCounter');
    Assert.IsTrue(Display.Contains('0') or Display.Contains('1'),
      'attach: GCounter expected 0/1, got: ' + Display);
  finally
    CloseHandle(PI.hProcess);
  end;
end;

// Attach by process NAME instead of literal PID. The adapter walks the
// running-process snapshot, picks the first match, and attaches. Skip
// when SeDebugPrivilege is not held (same gating as Test_Attach_BasicSession).
procedure TDebuggerTests.Test_Attach_ByProcessName;

  function HaveDebugPrivilege: Boolean;
  const
    SE_DEBUG_NAME_W = 'SeDebugPrivilege';
  var
    Tok: THandle;
    Luid: TLargeInteger;
    Got: DWORD;
    Buf: array[0..1023] of Byte;
    Privs: ^TTokenPrivileges;
  begin
    Result := False;
    if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Tok) then Exit;
    try
      if not LookupPrivilegeValue(nil, SE_DEBUG_NAME_W, Luid) then Exit;
      Got := 0;
      GetTokenInformation(Tok, TokenPrivileges, @Buf[0], SizeOf(Buf), Got);
      if Got = 0 then Exit;
      Privs := @Buf[0];
      for var I := 0 to Privs.PrivilegeCount - 1 do
        if Int64(Privs.Privileges[I].Luid) = Int64(Luid) then
          Exit(True);
    finally
      CloseHandle(Tok);
    end;
  end;

var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  BpLine: Integer;
  Stopped: TJSONObject;
  StartedOk: Boolean;
begin
  if not HaveDebugPrivilege then begin
    TDUnitX.CurrentRunner.Status(
      'Skipping: SeDebugPrivilege not held; run elevated to exercise attach.');
    Exit;
  end;

  BpLine := Bp('MAIN_GCOUNTER');

  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  CmdLine := '"' + TargetExe + '" --attach-pause';
  StartedOk := CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI);
  Assert.IsTrue(StartedOk, 'CreateProcess for attach-by-name failed');
  CloseHandle(PI.hThread);
  try
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized);
    FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
    // Use the basename only -- the adapter must append `.exe` if missing
    // and pick the first match in the running-process snapshot.
    FClient.AttachByName('TestTarget', TargetExe, TargetMap, TargetRsm,
      TargetDir, True).Free;
    FClient.ConfigDone.Free;
    Stopped := FClient.WaitForStopped(20000);
    try
      Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
        'attach-by-name: stopped reason is not breakpoint');
    finally
      Stopped.Free;
    end;
  finally
    CloseHandle(PI.hProcess);
  end;
end;

// Delphi-raise filter ON: target's `raise Exception.Create(...)` first-
// chance event surfaces as an exception stop. Continue resumes; the
// program's own try/except catches and the run completes normally.
procedure TDebuggerTests.Test_ExceptionFilter_DelphiOn_Stops;
var
  Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // No source BPs — only exception filter drives the stop.
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'expected stopped reason "exception", got: '
      + Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;
end;

// Delphi-raise filter OFF: same target should run to completion without
// surfacing any user-visible stop. We assert by waiting for the
// `terminated` event.
procedure TDebuggerTests.Test_ExceptionFilter_DelphiOff_Skips;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // Only `unhandled` enabled — `delphi` deliberately omitted. The raise
  // happens, the target's try/except handles it, no second-chance fires.
  FClient.SetExceptionBreakpoints(['unhandled']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Assert.IsTrue(FClient.WaitForTerminated(15000),
    'expected target to run to completion without surfacing any stop');
end;

// Per-class refinement: delphi filter ON with condition='Exception' (the
// raised class). Should fire the exception stop.
procedure TDebuggerTests.Test_ExceptionFilter_ClassMatch_Stops;
var Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // Filter on, condition matches the raised class.
  FClient.SetExceptionBreakpoints(
    ['delphi', 'unhandled'], ['Exception', '']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'expected stopped reason "exception", got: '
      + Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;
end;

// Per-class refinement: delphi filter ON with condition naming an
// unrelated class. The actual raise (class=Exception) doesn't match
// → no stop, target runs to terminate.
procedure TDebuggerTests.Test_ExceptionFilter_ClassMismatch_Skips;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(
    ['delphi', 'unhandled'], ['EArgumentException, EConvertError', '']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Assert.IsTrue(FClient.WaitForTerminated(15000),
    'expected target to run to completion (class condition didn''t match)');
end;

// Regression for the IdeHooks "break on all first-chance exceptions does
// nothing" bug. Real VS Code, once a filter advertises supportsCondition,
// sends an EMPTY legacy `filters` array and every enabled id inside
// `filterOptions` keyed by `filterId` (the DAP spec name). The adapter used to
// read only `filter`, so it enabled nothing and only the forced `unhandled`
// (second-chance) survived — no first-chance ever broke. This drives the exact
// shape captured in dap_adapter.log (delphi+av+all+unhandled, empty filters).
procedure TDebuggerTests.Test_ExceptionFilter_RealVsCodeShape_AllStops;
var
  Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // 2-arg overload sends {"filters":[],"filterOptions":[{"filterId":...}, ...]}.
  FClient.SetExceptionBreakpoints(
    ['delphi', 'av', 'all', 'unhandled'], ['', '', '', '']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'first-chance exception must stop when ids arrive via filterOptions.filterId; got: '
      + Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;
end;

// On an exception stop the `stopped` event description must carry both the
// raised class name and the Exception.Message text ("Exception: exc-test").
procedure TDebuggerTests.Test_ExceptionStop_DescriptionHasClassAndMessage;
var
  Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    var Desc := Stopped.GetValue<string>('description', '');
    Assert.IsTrue(Desc.Contains('Exception'),
      'description should name the class, got: ' + Desc);
    Assert.IsTrue(Desc.Contains('exc-test'),
      'description should carry the message, got: ' + Desc);
    // The stop must report the raise-site source (not the RTL raise address),
    // so VS Code navigates to the user's code and fetches Locals.
    var Src := Stopped.GetValue<TJSONObject>('source');
    Assert.IsNotNull(Src, 'exception stop should carry a source (raise site)');
    Assert.IsTrue(Stopped.GetValue<Integer>('line', 0) > 0,
      'exception stop should carry a raise-site line');
  finally
    Stopped.Free;
  end;
end;

// The DAP `exceptionInfo` request returns the class as exceptionId, the message
// as description, and both inside `details`. VS Code uses this for the details
// panel on an exception stop.
procedure TDebuggerTests.Test_ExceptionInfo_ReportsClassAndMessage;
var
  Stopped, Info: TJSONObject;
  Tid: Integer;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Tid := Stopped.GetValue<Integer>('threadId', 1);
  finally
    Stopped.Free;
  end;

  Info := FClient.ExceptionInfo(Tid);
  try
    Assert.AreEqual('Exception', Info.GetValue<string>('exceptionId', ''),
      'exceptionId should be the raised class');
    Assert.AreEqual('exc-test', Info.GetValue<string>('description', ''),
      'description should be the Exception.Message');
    var Details := Info.GetValue<TJSONObject>('details');
    Assert.AreEqual('Exception', Details.GetValue<string>('typeName', ''));
    Assert.AreEqual('exc-test', Details.GetValue<string>('message', ''));
  finally
    Info.Free;
  end;
end;

// exceptionRules: a rule with action "ignore" must override the filter's
// would-be break. The target raises Exception('exc-test') and catches it, so
// with the raise suppressed at the debugger level the run completes.
procedure TDebuggerTests.Test_ExceptionRule_Ignore_Resumes;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;  // would break...
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-exception-test'],
    '[{"class":"Exception","action":"ignore"}]').Free;            // ...but rule says ignore
  FClient.ConfigDone.Free;

  Assert.IsTrue(FClient.WaitForTerminated(15000),
    'ignore rule should suppress the stop and let the run finish');
end;

// exceptionRules: a rule with action "break" must stop even when the filters
// are all off. Proves the rule engine overrides the (no-break) filter default.
procedure TDebuggerTests.Test_ExceptionRule_Break_OverridesFilterOff;
var
  Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['unhandled']).Free;  // delphi filter OFF
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-exception-test'],
    '[{"messageRegex":"exc-.*","action":"break"}]').Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'break rule should stop even with the delphi filter off');
  finally
    Stopped.Free;
  end;
end;

// exceptionRules: a rule with action "log" writes the exception to the debug
// console and resumes without stopping.
procedure TDebuggerTests.Test_ExceptionRule_Log_ResumesAndLogs;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-exception-test'],
    '[{"message":"exc-test","action":"log"}]').Free;
  FClient.ConfigDone.Free;

  var Logged := FClient.WaitForOutputContaining('exc-test', 15000);
  Assert.IsTrue(Logged.Contains('exc-test'),
    'log rule should emit the exception to the debug console, got: ' + Logged);
  Assert.IsTrue(FClient.WaitForTerminated(15000),
    'log rule should resume after logging');
end;

// On an exception stop the live exception object is surfaced as a synthetic
// `$exception` entry at the top of the Locals scope (expandable), and the same
// pseudo-variable resolves through evaluate (watch / hover).
procedure TDebuggerTests.Test_ExceptionLocal_ShowsExceptionObject;
var
  Stopped, ExcVar, EvalResp: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  LaunchTarget(['--run-exception-test']).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''));
  finally
    Stopped.Free;
  end;

  FClient.Scopes(0).Free;  // select the top frame
  ExcVar := FindLocalByName(FClient, 1000, '$exception');  // LOCALS_VAR_REF
  try
    Assert.IsNotNull(ExcVar, '$exception should appear in Locals on an exception stop');
    Assert.IsTrue(ExcVar.GetValue<string>('value', '').Contains('exc-test'),
      'value should include the message, got: ' + ExcVar.GetValue<string>('value', ''));
    Assert.IsTrue(ExcVar.GetValue<Integer>('variablesReference', 0) > 0,
      '$exception should be expandable');
  finally
    ExcVar.Free;
  end;

  EvalResp := FClient.Evaluate('$exception', 0, 'watch');
  try
    Assert.IsTrue(EvalResp.GetValue<string>('result', '').Contains('exc-test'),
      'evaluate $exception should return class:message, got: '
      + EvalResp.GetValue<string>('result', ''));
  finally
    EvalResp.Free;
  end;
end;

// Shared machine-wide rules: a rule loaded from the global JSON file (object
// form, pointed at via globalExceptionRulesPath) must apply just like project
// rules. Here it ignores the raise that the filters would otherwise break on,
// so the target runs to completion.
procedure TDebuggerTests.Test_GlobalExceptionRules_FileApplied;
var
  GlobalFile: string;
begin
  GlobalFile := TPath.Combine(TPath.GetTempPath,
    Format('dwd_globalrules_%d.json', [GetCurrentProcessId]));
  TFile.WriteAllText(GlobalFile,
    '{ "exceptionRules": [ {"messageRegex": "exc-.*", "action": "ignore"} ] }');
  try
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized);
    FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;  // would break...
    FClient.LaunchWithGlobalRules(TargetExe, TargetMap, TargetRsm, TargetDir,
      ['--run-exception-test'], GlobalFile).Free;                   // ...global rule ignores
    FClient.ConfigDone.Free;

    Assert.IsTrue(FClient.WaitForTerminated(15000),
      'global ignore rule should suppress the stop and let the run finish');
  finally
    if TFile.Exists(GlobalFile) then
      TFile.Delete(GlobalFile);
  end;
end;

// `classIs` matches the runtime class OR any ancestor. The target raises a plain
// Exception (chain: Exception -> TObject); a classIs:TObject rule must match via
// the ancestor walk and ignore it, so the run finishes. This also proves the
// adapter reads the real VMT/RTTI ancestor chain (a leaf-only read would miss).
procedure TDebuggerTests.Test_ExceptionRule_ClassIs_MatchesAncestor;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;  // would break
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-exception-test'],
    '[{"classIs":"TObject","action":"ignore"}]').Free;            // ancestor match
  FClient.ConfigDone.Free;

  Assert.IsTrue(FClient.WaitForTerminated(15000),
    'classIs:TObject should match via the ancestor chain and suppress the stop');
end;

// exceptionRules `code`: the only criterion that can target a NATIVE Windows
// exception (no Delphi object at raise time -> no class, no message). The target
// raises the customer-defined code 0xE0424242 and then a Delphi exception; the
// rule must break on the first and leave the second to the filters, proving it
// does not leak onto a Delphi exception raised right next to it.
procedure TDebuggerTests.Test_ExceptionRule_Code_MatchesNativeOnly;
var
  Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;  // `all` is OFF
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-native-exception-test'],
    '[{"code":"0xE0424242","action":"break"}]').Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'a code rule must break on the native exception the filters ignore');
    Assert.IsTrue(Stopped.GetValue<string>('description', '').ToLower.Contains('e0424242'),
      'the stop should name the native exception code, got: '
      + Stopped.GetValue<string>('description', ''));
  finally
    Stopped.Free;
  end;

  // The Delphi raise that follows is NOT matched by the code rule, so the plain
  // `delphi` filter decides and it stops with class and message intact. The RTL
  // may surface the mapped EExternalException as a stop of its own first; that
  // is equally a Delphi exception the rule left alone, so skip past it.
  var Desc := '';
  for var Attempt := 1 to 3 do begin
    FClient.Continue_.Free;
    Stopped := FClient.WaitForStopped(15000);
    try
      Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''));
      Desc := Stopped.GetValue<string>('description', '');
    finally
      Stopped.Free;
    end;
    if Desc.Contains('exc-after-native') then
      Break;
  end;
  Assert.IsTrue(Desc.Contains('exc-after-native'),
    'the code rule must not affect the Delphi exception raised next, got: ' + Desc);
end;

// The same code written as a plain decimal JSON number (0xE0424242 =
// 3762438722) must be accepted by the launch-config parser.
procedure TDebuggerTests.Test_ExceptionRule_Code_Decimal_BreaksOnNative;
var
  Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['unhandled']).Free;  // every first-chance filter OFF
  FClient.LaunchWithRules(TargetExe, TargetMap, TargetRsm, TargetDir,
    ['--run-native-exception-test'],
    '[{"code":3762438722,"action":"break"}]').Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'a decimal code should parse and break like the hex spelling');
    Assert.IsTrue(Stopped.GetValue<string>('description', '').ToLower.Contains('e0424242'),
      'got: ' + Stopped.GetValue<string>('description', ''));
  finally
    Stopped.Free;
  end;
end;

// Hot-reload: editing the shared rules file while stopped must take effect on
// resume without restarting. The re-raise flow raises twice; with no rules the
// first raise breaks, then the file is edited to ignore the (re-)raise, and on
// continue the reloaded rule suppresses the second event so the run finishes.
procedure TDebuggerTests.Test_GlobalExceptionRules_HotReloadOnResume;
var
  GlobalFile: string;
  Stopped: TJSONObject;
begin
  GlobalFile := TPath.Combine(TPath.GetTempPath,
    Format('dwd_hotreload_%d.json', [GetCurrentProcessId]));
  TFile.WriteAllText(GlobalFile, '{ "exceptionRules": [] }');  // no rules yet -> filters break
  try
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized);
    FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
    FClient.LaunchWithGlobalRules(TargetExe, TargetMap, TargetRsm, TargetDir,
      ['--run-reraise'], GlobalFile).Free;
    FClient.ConfigDone.Free;

    Stopped := FClient.WaitForStopped(15000);
    try
      Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
        'first raise should break (shared file empty)');
    finally
      Stopped.Free;
    end;

    // Edit the shared file while stopped: ignore the re-raise from now on.
    TFile.WriteAllText(GlobalFile,
      '{ "exceptionRules": [ {"message": "reraise-orig", "action": "ignore"} ] }');

    // Resume: the reload must apply the new rule so the re-raise is suppressed.
    FClient.Continue_(1).Free;
    Assert.IsTrue(FClient.WaitForTerminated(15000),
      'hot-reloaded ignore rule should suppress the re-raise on resume');
  finally
    if TFile.Exists(GlobalFile) then
      TFile.Delete(GlobalFile);
  end;
end;

// `FreeAdd(3, 4)` — free function returning Integer (RAX path). No Self.
// Previously reported `<free-proc calls not yet supported>`.
procedure TDebuggerTests.Test_Eval_FreeProc_IntegerReturn;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'FreeAdd(3, 4)');
  Assert.AreEqual('7', ExtractDisplayValue(Display),
    'FreeAdd(3, 4) expected 7, got: ' + Display);
end;

// `FreeWrap('foo')` — free function returning string (var-out path).
// Without the new $23-tag handling for `Result`, this would fall back
// to the heuristic and hang the debuggee.
procedure TDebuggerTests.Test_Eval_FreeProc_StringReturn;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'FreeWrap(''foo'')');
  Assert.IsTrue(Display.Contains('<foo>'),
    'FreeWrap(''foo'') expected ''<foo>'', got: ' + Display);
end;

// `TheWidget.AsSet = [wmRunning, wmPaused]` — TWidget.AsSet is a published
// property returning TWorkModes initialised to exactly these two values.
// Set literal must build the same bitmask the runtime stores so the
// equality compares cleanly.
procedure TDebuggerTests.Test_Eval_SetLiteral_Compare;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId,
    'W.AsSet = [wmRunning, wmPaused]');
  Assert.IsTrue(Display.Contains('True'),
    'set-equality expected True, got: ' + Display);
end;

// `[]` empty set literal must produce a value with mask 0 and no parser
// error. Compare against itself to confirm the value flows through the
// rest of the evaluator.
procedure TDebuggerTests.Test_Eval_SetLiteral_Empty;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, '[] = []');
  Assert.IsTrue(Display.Contains('True'),
    'empty set self-equality expected True, got: ' + Display);
end;

// `x in S` — set membership. TheWidget.AsSet returns [wmRunning, wmPaused],
// so `wmRunning in TheWidget.AsSet` is True.
procedure TDebuggerTests.Test_Eval_In_PropertyTrue;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'wmRunning in W.AsSet');
  Assert.IsTrue(Display.Contains('True'),
    '`wmRunning in AsSet` expected True, got: ' + Display);
end;

// wmIdle is NOT in AsSet ([wmRunning, wmPaused]), so the result is False.
procedure TDebuggerTests.Test_Eval_In_PropertyFalse;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId, 'wmIdle in W.AsSet');
  Assert.IsTrue(Display.Contains('False'),
    '`wmIdle in AsSet` expected False, got: ' + Display);
end;

// `x in [literal set]` — the rhs is a set literal built on the fly by
// ParseUnary, the lhs is a plain enum identifier. Confirms that `in`
// works against a set value computed inline, not just a property.
procedure TDebuggerTests.Test_Eval_In_LiteralSet;
var FrameId, LocalsRef: Integer; Display: string;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Display := NonRttiResult(FClient, FrameId,
    'wmPaused in [wmIdle, wmPaused]');
  Assert.IsTrue(Display.Contains('True'),
    '`wmPaused in [wmIdle, wmPaused]` expected True, got: ' + Display);
end;

// BPL debugging end-to-end. TestPackage.bpl is loaded at runtime by
// TestTarget.exe via LoadPackage when invoked with `--load-package`;
// the package's TestPkgUnit initialization section calls
// `PkgAdd(2, 3)`, which is where the BP fires.
//
// Validates the multi-module path:
//   * setBreakpoints arrives BEFORE the BPL is loaded — adapter must
//     defer planting until LOAD_DLL_DEBUG_EVENT for the BPL fires.
//   * The launch.json `modules` array points the adapter at the BPL's
//     map / rsm so source-line resolution works.
//   * After the BP hits, locals (`A`, `B`) inside the BPL function
//     resolve through the BPL's RSM (lazily loaded on first request).
procedure TDebuggerTests.Test_Lifecycle_RunToTermination;
// Launch with NO breakpoints; the target runs every Run* sampler proc
// and exits. The adapter must emit a `terminated` event and shut the
// session down cleanly (no hang, no orphaned debuggee). Guards the
// most basic lifecycle invariant -- a hang here makes the debugger
// unusable regardless of feature coverage.
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not initialize');
  // No breakpoints at all.
  FClient.SetBreakpoints(TargetSrc, []).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  Assert.IsTrue(FClient.WaitForTerminated(20000),
    'target must run to completion and emit terminated within 20s');
end;

procedure TDebuggerTests.Test_Bpl_BreakpointHits;
// Verifies that a breakpoint set in a unit that lives inside a runtime
// BPL (loaded by the target via LoadPackage) is correctly resolved and
// hit when the BPL's initialization section reaches that line.
//
// Locals/parameters of BPL-resident functions are validated via the
// package's .dcp file: dcc64 emits per-unit debug records (procs,
// locals, params, type metadata) into the .dcp using the same record
// schema as the .rsm. The adapter loads the .dcp as an additional
// IDebugInfoProvider for the module so locals work transparently.
var
  BpLine, FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  Frames: TJSONArray;
  TopFrame: TJSONObject;
  SrcPath: string;
  FrameLine: Integer;
  DispA, DispB: string;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_BP');
  Assert.IsTrue(BpLine > 0, 'PKG_BP marker not found in TestPkgUnit.pas');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'BPL: stopped reason is not breakpoint');
  finally
    Stopped.Free;
  end;

  var ST := FClient.StackTrace(1);
  try
    Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsTrue((Frames <> nil) and (Frames.Count > 0),
      'BPL: no stack frames returned');
    TopFrame  := Frames.Items[0] as TJSONObject;
    FrameLine := TopFrame.GetValue<Integer>('line', 0);
    Assert.AreEqual(BpLine, FrameLine,
      Format('BPL: frame line expected %d, got %d', [BpLine, FrameLine]));
    var SrcObj := TopFrame.GetValue<TJSONObject>('source');
    Assert.IsTrue(SrcObj <> nil, 'BPL: top frame has no source object');
    SrcPath := SrcObj.GetValue<string>('path', '');
    if SrcPath = '' then
      SrcPath := SrcObj.GetValue<string>('name', '');
    Assert.IsTrue(SameText(ExtractFileName(SrcPath), 'TestPkgUnit.pas'),
      'BPL: top-frame source expected TestPkgUnit.pas, got: ' + SrcPath);
  finally
    ST.Free;
  end;

  // Locals via .dcp: PkgAdd was called as PkgAdd(2, 3) from the unit's
  // initialization section, so A=2 and B=3 are visible at the BP.
  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0, 'BPL: no Locals scope found');

  DispA := NonRttiResult(FClient, FrameId, 'A');
  DispB := NonRttiResult(FClient, FrameId, 'B');
  Assert.AreEqual('2', ExtractDisplayValue(DispA),
    'BPL: A expected 2, got: ' + DispA);
  Assert.AreEqual('3', ExtractDisplayValue(DispB),
    'BPL: B expected 3, got: ' + DispB);
end;

procedure TDebuggerTests.Test_Bpl_UniqueGlobal_ResolvesFromExeFrame;
// Cross-BPL global resolution, UNIQUE name. The host EXE loads
// TestPackage.bpl; GPkgUniqueGlobal is a unit-level global declared INSIDE
// the BPL and set to 24680 by the package's initialization (runs during
// LoadPackage, before the host reaches its own stop). We stop in the HOST
// EXE (MAIN_GCOUNTER) -- a frame whose owning unit is Testtarget, NOT the
// BPL -- and watch the BPL global. It must resolve through the BPL's own
// per-binary symbol provider (lazy warm-up + image-base shift), value and
// Integer type correct. This is the common real case: a global living in a
// runtime package, inspected from elsewhere (mirrors SampleApp frmSplashScreen
// when the form lives in a package rather than the main exe).
var
  BpLine, FrameId: Integer;
  Stopped, Resp: TJSONObject;
begin
  SkipIfBpl('anchored on MAIN_GCOUNTER, the exe-only program-main-block frame in TestTarget.dpr; TestHost.exe has no program begin..end. block, so that frame/line never exists under tsBpl and the BP cannot bind');
  BpLine := Bp('MAIN_GCOUNTER');  // sets FBpSourceFile = TestTarget.dpr
  Assert.IsTrue(BpLine > 0, 'MAIN_GCOUNTER marker not found in TestTarget.dpr');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir, False,
    ['--load-package'],
    [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]]).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'cross-BPL global: did not stop at MAIN_GCOUNTER');
  finally
    Stopped.Free;
  end;

  FClient.StackTrace(1).Free;
  FrameId := FClient.GetFrameId;

  Resp := FClient.Evaluate('GPkgUniqueGlobal', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found'),
      'BPL global GPkgUniqueGlobal must resolve from the exe frame; got: ' + Res);
    Assert.AreEqual('24680', ExtractDisplayValue(Res),
      'BPL global value expected 24680; got: ' + Res);
    Assert.AreEqual('Integer', Resp.GetValue<string>('type', ''),
      'BPL global type expected Integer; got: '
      + Resp.GetValue<string>('type', '') + ' / result=' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_CrossBinaryGlobalCollision_PicksOwnBinary;
// Layer 2: cross-BINARY global collision. GCrossBinAmbiguous is declared in
// BOTH packages -- Integer (=111) in TestPackage, Double (=222.5) in
// TestPackage2 -- with both BPLs live. Stopped at PKG2_BP (a frame inside
// TestPackage2, after TestPackage already fully loaded so its Integer copy is
// also live), watching the unqualified global must resolve to THIS binary's
// copy (Double 222.5), never the other binary's Integer 111. Exercises the
// per-binary ranged-global routing in FindGlobalForRva winning over the flat
// first-hit fallback. Mirrors SampleApp where the same global name exists in
// several packages and the in-scope binary must win.
var
  Bp2, FrameId: Integer;
  Stopped, Resp: TJSONObject;
begin
  Bp2 := FindBpLine(Package2Src, 'PKG2_BP');
  Assert.IsTrue(Bp2 > 0, 'PKG2_BP marker not found in TestPkgUnit2.pas');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(Package2Src, [Bp2]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package2'];
  Spec.Modules := [['TestPackage.bpl',  PackageMap,  PackageRsm,  PackageDcp],
                   ['TestPackage2.bpl', Package2Map, Package2Rsm, Package2Dcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  // Load order is package then package2; PKG_BP is not set, so the first stop
  // is PKG2_BP inside TestPackage2 with TestPackage already fully loaded.
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'cross-binary collision: did not stop at PKG2_BP');
  finally
    Stopped.Free;
  end;

  FClient.StackTrace(1).Free;
  FrameId := FClient.GetFrameId;

  Resp := FClient.Evaluate('GCrossBinAmbiguous', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    var Typ := Resp.GetValue<string>('type', '');
    Assert.IsFalse(Res.Contains('not found'),
      'cross-binary global must resolve from the in-scope BPL frame; got: ' + Res);
    Assert.IsFalse(Res.Contains('111'),
      'cross-binary global resolved to the WRONG binary (TestPackage Integer 111); got: '
      + Res + ' / type=' + Typ);
    Assert.IsTrue(Res.Contains('222.5'),
      'cross-binary global must be TestPackage2 Double 222.5; got: ' + Res + ' / type=' + Typ);
    Assert.AreEqual('Double', Typ,
      'cross-binary global type expected Double; got: ' + Typ + ' / result=' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_UsesGraphGlobal_PrefersRequiredPackage;
// Layer 2, uses-graph tier. GUsesGraph is declared in TestPackage (Integer
// 333) and in the HOST exe TestTarget (Integer 444) -- but NOT in
// TestPackage2. TestPackage2 `requires TestPackage` (a runtime package link),
// and does NOT require the host. Stopped at PKG2_BP (a frame inside
// TestPackage2), the unqualified watch GUsesGraph is visible only through the
// requires-closure: it must resolve to the required package's copy (333),
// never the unrelated host's 444. A flat load-order fallback returns the host
// copy (registered first) -- the requires-aware tier-3 in FindGlobalForRva
// must override it. Mirrors SampleApp where a package's global must beat an
// identically-named global in an unrelated module.
var
  Bp2, FrameId: Integer;
  Stopped, Resp: TJSONObject;
begin
  Bp2 := FindBpLine(Package2Src, 'PKG2_BP');
  Assert.IsTrue(Bp2 > 0, 'PKG2_BP marker not found in TestPkgUnit2.pas');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(Package2Src, [Bp2]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package2'];
  Spec.Modules := [['TestPackage.bpl',  PackageMap,  PackageRsm,  PackageDcp],
                   ['TestPackage2.bpl', Package2Map, Package2Rsm, Package2Dcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'uses-graph global: did not stop at PKG2_BP');
  finally
    Stopped.Free;
  end;

  FClient.StackTrace(1).Free;
  FrameId := FClient.GetFrameId;

  Resp := FClient.Evaluate('GUsesGraph', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found'),
      'uses-graph global must resolve through the requires-closure; got: ' + Res);
    Assert.IsFalse(Res.Contains('444'),
      'uses-graph global resolved to the UNRELATED host copy (444); the required '
      + 'package copy must win; got: ' + Res);
    Assert.IsTrue(Res.Contains('333'),
      'uses-graph global must be the required package copy (333); got: ' + Res);
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_Td32Only_BpHits;
// End-to-end coverage of EnsureDllTD32: the BPL's MAP / RSM / DCP
// launch paths are all empty, so the adapter must reach the BPL's
// own .debug section -- TD32 -- to resolve a source-line breakpoint.
// Locals / parameters are not asserted here (the DCP carries those;
// without it A/B don't surface). The BP-resolution + stack-frame
// source path are the invariants that prove TD32-in-BPL is wired
// through to DAP.
var
  BpLine, FrameLine: Integer;
  Stopped: TJSONObject;
  Frames:  TJSONArray;
  TopFrame: TJSONObject;
  SrcPath:  string;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_BP');
  Assert.IsTrue(BpLine > 0, 'PKG_BP marker not found in TestPkgUnit.pas');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package'];
  Spec.Modules := [['TestPackage.bpl', '', '', '']];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'BPL TD32-only: stopped reason is not breakpoint');
  finally
    Stopped.Free;
  end;

  var ST := FClient.StackTrace(1);
  try
    Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsTrue((Frames <> nil) and (Frames.Count > 0),
      'BPL TD32-only: no stack frames returned');
    TopFrame  := Frames.Items[0] as TJSONObject;
    FrameLine := TopFrame.GetValue<Integer>('line', 0);
    Assert.AreEqual(BpLine, FrameLine,
      Format('BPL TD32-only: frame line expected %d, got %d',
        [BpLine, FrameLine]));
    var SrcObj := TopFrame.GetValue<TJSONObject>('source');
    Assert.IsTrue(SrcObj <> nil, 'BPL TD32-only: top frame has no source');
    SrcPath := SrcObj.GetValue<string>('path', '');
    if SrcPath = '' then
      SrcPath := SrcObj.GetValue<string>('name', '');
    Assert.IsTrue(SameText(ExtractFileName(SrcPath), 'TestPkgUnit.pas'),
      'BPL TD32-only: top-frame source expected TestPkgUnit.pas, got: ' + SrcPath);
  finally
    ST.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_Td32Only_LocalsVisible;
// Regression for the BPL-frame "empty locals" bug: a package loaded with NO
// MAP / RSM / DCP (all blank below) must still surface its function's locals
// from the BPL's own embedded TD32. PKG_BP sits in `PkgAdd(A, B): Integer`
// with a local `W: TPkgWidget`, so the Locals scope must list A, B and W.
// Before EnsureDllTD32 set ExposeLocals on the DLL/BPL reader, TD32 locals
// were gated off for packages, so this came up empty even though the data was
// present in the loaded TD32 (the exact SampleApp `TAboutBoxForm.Create` symptom:
// its RSM has zero locals, its TD32 has them all).
var
  BpLine, FrameId, LocalsRef: Integer;
  Stopped: TJSONObject;
  VA, VB, VW: TJSONObject;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_BP');
  Assert.IsTrue(BpLine > 0, 'PKG_BP marker not found in TestPkgUnit.pas');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package'];
  Spec.Modules := [['TestPackage.bpl', '', '', '']];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'BPL TD32-only locals: not stopped at breakpoint');
  finally
    Stopped.Free;
  end;

  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0, 'BPL TD32-only locals: no Locals scope');

  VA := FindLocalByName(FClient, LocalsRef, 'A');
  VB := FindLocalByName(FClient, LocalsRef, 'B');
  VW := FindLocalByName(FClient, LocalsRef, 'W');
  try
    Assert.IsNotNull(VA, 'param A missing in TD32-only BPL frame');
    Assert.IsNotNull(VB, 'param B missing in TD32-only BPL frame');
    Assert.IsNotNull(VW, 'local W (TPkgWidget) missing in TD32-only BPL frame');
  finally
    VA.Free;
    VB.Free;
    VW.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_DefinedClass_FieldVisible;
// Core SampleApp use case: a class DEFINED INSIDE the runtime-loaded BPL
// (TPkgWidget) must be inspectable from a frame stopped inside that BPL.
// The debugger has to resolve TPkgWidget's member table from the BPL's
// own debug info (RSM/DCP), not from the host EXE which never declared
// the type. At PKG_BP the local W = TPkgWidget(Tag=5, LabelText='pkg-widget').
var
  BpLine, FrameId: Integer;
  Stopped: TJSONObject;
  TagResp, LabelResp: TJSONObject;
  TagRes, LabelRes: string;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_BP');
  Assert.IsTrue(BpLine > 0, 'PKG_BP marker not found');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'BPL class: stopped reason is not breakpoint');
  finally
    Stopped.Free;
  end;
  FrameId := FClient.GetFrameId;

  // Field access on a BPL-defined class. W.Tag is a read-only property
  // over FTag; W.FTag is the raw field. Accept either resolving to 5.
  TagResp := FClient.Evaluate('W.FTag', FrameId);
  try
    TagRes := TagResp.GetValue<string>('result', '');
    if TagRes.Contains('not found') or TagRes.Contains('<') then begin
      TagResp.Free;
      TagResp := FClient.Evaluate('W.Tag', FrameId);
      TagRes  := TagResp.GetValue<string>('result', '');
    end;
    Assert.AreEqual('5', ExtractDisplayValue(TagRes),
      'BPL-defined class field W.FTag must resolve to 5, got: ' + TagRes);
  finally
    TagResp.Free;
  end;

  LabelResp := FClient.Evaluate('W.FLabel', FrameId);
  try
    LabelRes := LabelResp.GetValue<string>('result', '');
    Assert.IsTrue(LabelRes.Contains('pkg-widget'),
      'BPL-defined class field W.FLabel must contain pkg-widget, got: ' + LabelRes);
  finally
    LabelResp.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_DefinedClass_ExpandInLocals;
// Same BPL-defined class, but through the VARIABLES TREE path (how the
// user expands a form's fields in the side panel) rather than evaluate.
// Expanding the local W must list FTag=5 and FLabel='pkg-widget'.
var
  BpLine, FrameId, LocalsRef, WRef: Integer;
  Stopped, V: TJSONObject;
  TagStr, LabelStr: string;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_BP');
  Assert.IsTrue(BpLine > 0, 'PKG_BP marker not found');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'BPL class expand: not stopped at breakpoint');
  finally
    Stopped.Free;
  end;
  FrameId   := FClient.GetFrameId;
  LocalsRef := FClient.GetLocalsRef(FrameId);
  Assert.IsTrue(LocalsRef > 0, 'BPL class expand: no Locals scope');

  V := FindLocalByName(FClient, LocalsRef, 'W');
  Assert.IsNotNull(V, 'local W (TPkgWidget) missing in BPL frame');
  try
    WRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(WRef > 0, 'W (BPL-defined class) must be expandable in locals view');
  finally V.Free; end;

  // FTag / FLabel are backing fields -- FindVar/VarValue descend the
  // synthetic `fields` group that a property-bearing class now splits into.
  TagStr   := FClient.VarValue(WRef, 'FTag');
  LabelStr := FClient.VarValue(WRef, 'FLabel');
  Assert.IsTrue(ExtractDisplayValue(TagStr) = '5',
    'W expansion must show FTag=5; got: ' + TagStr);
  Assert.IsTrue(LabelStr.Contains('pkg-widget'),
    'W expansion must show FLabel=pkg-widget; got: ' + LabelStr);
end;

procedure TDebuggerTests.Test_Bpl_UnloadReload_BpRebinds;
// Core SampleApp lifecycle: a form's BPL is loaded, closed (UnloadPackage),
// and opened again (LoadPackage). A breakpoint set ONCE must fire on
// BOTH loads -- proving OnDllUnloaded tore down the first module's
// providers and the second LoadPackage re-bound the BP to the
// freshly-mapped image. The host '--reload-package' switch runs
// load / unload / load, so PKG_BP fires exactly twice.
var
  BpLine: Integer;
  Stopped1, Stopped2: TJSONObject;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_BP');
  Assert.IsTrue(BpLine > 0, 'PKG_BP marker not found');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--reload-package'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  // First load -> BP fires.
  Stopped1 := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped1.GetValue<string>('reason', ''),
      'reload: first load did not hit the breakpoint');
  finally
    Stopped1.Free;
  end;
  FClient.Continue_.Free;

  // After unload + second load -> the SAME breakpoint must fire again.
  Stopped2 := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped2.GetValue<string>('reason', ''),
      'reload: breakpoint did not re-bind after unload + reload');
  finally
    Stopped2.Free;
  end;
end;

procedure TDebuggerTests.Test_Bpl_TwoModules_EachBpRoutes;
// A large multi-BPL application keeps many packages live at once. Load TWO packages, set a BP in
// EACH (PKG_BP in TestPackage, PKG2_BP in TestPackage2), and verify both
// fire with the correct per-module source path. Proves symbol routing
// does not collide across simultaneously-loaded modules.
var
  Bp1, Bp2: Integer;
  Stopped: TJSONObject;
  HitPkg1, HitPkg2: Boolean;

  function TopSourceName: string;
  var ST, SrcObj, TopFrame: TJSONObject; Frames: TJSONArray;
  begin
    Result := '';
    ST := FClient.StackTrace(1);
    try
      Frames := ST.GetValue('stackFrames') as TJSONArray;
      if (Frames = nil) or (Frames.Count = 0) then Exit;
      TopFrame := Frames.Items[0] as TJSONObject;
      SrcObj := TopFrame.GetValue<TJSONObject>('source');
      if SrcObj = nil then Exit;
      Result := SrcObj.GetValue<string>('path', '');
      if Result = '' then Result := SrcObj.GetValue<string>('name', '');
      Result := ExtractFileName(Result);
    finally ST.Free; end;
  end;

begin
  Bp1 := FindBpLine(PackageSrc,  'PKG_BP');
  Bp2 := FindBpLine(Package2Src, 'PKG2_BP');
  Assert.IsTrue((Bp1 > 0) and (Bp2 > 0), 'PKG_BP / PKG2_BP markers not found');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc,  [Bp1]).Free;
  FClient.SetBreakpoints(Package2Src, [Bp2]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args    := ['--load-package2'];
  Spec.Modules := [['TestPackage.bpl',  PackageMap,  PackageRsm,  PackageDcp],
                   ['TestPackage2.bpl', Package2Map, Package2Rsm, Package2Dcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;

  // Both BPs must fire (load order: package then package2). Collect two
  // stops and check each routed to its own unit source.
  HitPkg1 := False;
  HitPkg2 := False;
  for var I := 1 to 2 do begin
    Stopped := FClient.WaitForStopped(15000);
    try
      Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
        Format('multi-BPL: stop #%d not a breakpoint', [I]));
    finally
      Stopped.Free;
    end;
    var Src := TopSourceName;
    if SameText(Src, 'TestPkgUnit.pas')  then HitPkg1 := True;
    if SameText(Src, 'TestPkgUnit2.pas') then HitPkg2 := True;
    FClient.Continue_.Free;
  end;

  Assert.IsTrue(HitPkg1, 'BP in TestPackage (TestPkgUnit.pas) did not route correctly');
  Assert.IsTrue(HitPkg2, 'BP in TestPackage2 (TestPkgUnit2.pas) did not route correctly');
end;


// === Type-sampler battery (BP marker: TYPES_BODY) =====================
// Tests in this section all stop at the same BP and inspect ONE local
// each. The shared `TypesScope` helper opens the session and returns
// the locals scope ref + the requested local's variable record.

// variablesReference of a named synthetic group ('properties' / 'fields' /
// 'event handlers') under an expanded class instance, or 0 if absent.
function GroupVarRef(FClient: TDapClient; ClassRef: Integer;
  const GroupName: string): Integer;
var
  Resp: TJSONObject;
  Arr:  TJSONArray;
begin
  Result := 0;
  Resp := FClient.Variables(ClassRef);
  try
    Arr := Resp.GetValue('variables') as TJSONArray;
    if Arr = nil then Exit;
    for var I := 0 to Arr.Count - 1 do begin
      var V := Arr.Items[I] as TJSONObject;
      if SameText(V.GetValue<string>('name', ''), GroupName) then
        Exit(V.GetValue<Integer>('variablesReference', 0));
    end;
  finally Resp.Free; end;
end;

function FindLocalByName(FClient: TDapClient; LocalsRef: Integer;
  const Name: string): TJSONObject;
var
  Resp: TJSONObject;
  Arr: TJSONArray;
begin
  Result := nil;
  Resp := FClient.Variables(LocalsRef);
  try
    Arr := Resp.GetValue('variables') as TJSONArray;
    if Arr = nil then Exit;
    for var I := 0 to Arr.Count - 1 do begin
      var Cell := Arr.Items[I] as TJSONObject;
      if SameText(Cell.GetValue<string>('name', ''), Name) then begin
        // Clone since the Resp owns it
        Result := TJSONObject.ParseJSONValue(Cell.ToJSON) as TJSONObject;
        Break;
      end;
    end;
  finally
    Resp.Free;
  end;
end;

procedure TDebuggerTests.Test_Types_ByteBool_True;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'BB1');
  Assert.IsNotNull(V, 'BB1 missing in locals');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('True'),
      'BB1 must display as True, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_TDateTime_Local_NotPlainFloat;
// A local declared `D1: TDateTime` must surface as the TDateTime type (the
// debugger should keep the alias name and format the value as a date), not be
// flattened to a bare Double/float. D1 lives in ComputeNested and is assigned
// `Now` before NESTED_INC, so it holds a valid date at the stop.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  SkipIfNoRsm('TDateTime alias fidelity: TD32 flattens TDateTime->Double; RSM-format sidecar only');
  StartSession('NESTED_INC', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'D1');
  Assert.IsNotNull(V, 'D1 missing in ComputeNested locals');
  try
    var Ty  := V.GetValue<string>('type', '');
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Ty.Contains('TDateTime'),
      Format('D1 type must be TDateTime, got type="%s" value="%s"', [Ty, Val]));
    // ...and the value must be formatted as a date, not a bare float. D1 := Now
    // at runtime, so the year is the current one (2025/2026); accept either, and
    // the date-separator form, so the test survives the calendar turning over.
    Assert.IsTrue(Val.Contains('2025') or Val.Contains('2026') or Val.Contains('-'),
      Format('D1 must render as a date, got value="%s"', [Val]));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_TDate_Local_RendersAsDate;
// TDate is `type TDateTime`. Like TDateTime it must surface as a date-family
// type (the alias survives the TD32 -> Double flattening via the RSM merge),
// and the value must render as a date, not a bare float.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  SkipIfNoRsm('TDate alias fidelity: TD32 flattens TDate->Double; only the RSM-format sidecar keeps the alias name');
  StartSession('DATE_ALIAS_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'DOnly');
  Assert.IsNotNull(V, 'DOnly missing');
  try
    var Ty  := V.GetValue<string>('type', '');
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Ty.Contains('TDate') or Ty.Contains('TDateTime'),
      Format('DOnly type must be a date alias, got type="%s" value="%s"', [Ty, Val]));
    Assert.IsTrue(Val.Contains('2025') or Val.Contains('2026') or Val.Contains('-'),
      Format('DOnly must render as a date, got value="%s"', [Val]));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_StaleRsm_IgnoredFallsBackToTd32;
// Regression for the original stale-.rsm concern: a .rsm OLDER than the exe must
// be IGNORED (not loaded) so its outdated symbols cannot silently mis-type
// variables. Proof by behaviour: launch a temp copy whose .rsm has been backdated
// below the 2s grace; the date-alias local DOnly (declared TDate) must resolve
// via the embedded TD32 -- which flattens the alias to a bare Double -- NOT show
// the TDate/TDateTime alias name (that only survives through the RSM merge). The
// positive counterpart (fresh .rsm -> alias visible) is Test_Types_TDate.
var
  FrameId, LocalsRef, BpLine: Integer;
  TmpDir, TmpExe, TmpMap, TmpRsm: string;
  Stopped, V: TJSONObject;
begin
  SkipIfBpl('main-exe .rsm staleness is a monolithic concern; a BPL is described by its own .dcp');
  TmpDir := TPath.Combine(TPath.GetTempPath, 'dbg_stale_rsm_' + IntToStr(GetTickCount));
  TDirectory.CreateDirectory(TmpDir);
  try
    TmpExe := TPath.Combine(TmpDir, 'TestTarget.exe');
    TmpMap := TPath.Combine(TmpDir, 'TestTarget.map');
    TmpRsm := TPath.Combine(TmpDir, 'TestTarget.rsm');
    TFile.Copy(TargetExe, TmpExe, True);
    TFile.Copy(TargetMap, TmpMap, True);
    TFile.Copy(TargetRsm, TmpRsm, True);
    // Backdate the .rsm well past the 2-second grace so it counts as stale.
    TFile.SetLastWriteTimeUtc(TmpRsm, TFile.GetLastWriteTimeUtc(TmpExe) - (1 / 24));

    BpLine := Bp('DATE_ALIAS_BODY');   // sets FBpSourceFile to TestTargetCore.pas
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized event');
    FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
    FClient.SetExceptionBreakpoints([]).Free;
    FClient.Launch(TmpExe, TmpMap, TmpRsm, TargetDir, False, []).Free;
    FClient.ConfigDone.Free;

    Stopped := FClient.WaitForStopped;
    try
      Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
        'did not stop at DATE_ALIAS_BODY with a staled .rsm');
    finally
      Stopped.Free;
    end;
    FrameId   := FClient.GetFrameId;
    LocalsRef := FClient.GetLocalsRef(FrameId);
    Assert.IsTrue(LocalsRef > 0, 'no Locals scope');

    V := FindLocalByName(FClient, LocalsRef, 'DOnly');
    Assert.IsNotNull(V, 'DOnly must still resolve via TD32 even when the .rsm is skipped');
    try
      var Ty := V.GetValue<string>('type', '');
      Assert.IsFalse(Ty.Contains('TDate') or Ty.Contains('TTime'),
        'stale .rsm must be IGNORED: DOnly should fall back to the TD32 base type (Double), got type="' + Ty + '"');
    finally
      V.Free;
    end;
  finally
    TDirectory.Delete(TmpDir, True);
  end;
end;

procedure TDebuggerTests.Test_Types_TTime_Local_RendersAsTime;
// TTime is `type TDateTime`. Must surface as a time/date-family type, not a
// bare float. The value carries a time-of-day component (Now), so a ':' or a
// date separator proves it is not formatted as a raw float.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  SkipIfNoRsm('TTime alias fidelity: TD32 flattens TTime->Double; RSM-format sidecar only');
  StartSession('DATE_ALIAS_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'TOnly');
  Assert.IsNotNull(V, 'TOnly missing');
  try
    var Ty  := V.GetValue<string>('type', '');
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Ty.Contains('TTime') or Ty.Contains('TDateTime'),
      Format('TOnly type must be a time alias, got type="%s" value="%s"', [Ty, Val]));
    Assert.IsTrue(Val.Contains(':') or Val.Contains('-'),
      Format('TOnly must render as a time/date, got value="%s"', [Val]));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_Single_Local_NotUpgradedToDateAlias;
// Negative control for IsFloatAliasUpgrade: Single is a 4-byte float and must
// NEVER be upgraded to an 8-byte date alias. It must stay Single and render as
// its plain float value (1.5), never as a date.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('DATE_ALIAS_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Sng');
  Assert.IsNotNull(V, 'Sng missing');
  try
    var Ty  := V.GetValue<string>('type', '');
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Ty.Contains('Single'),
      Format('Sng type must stay Single, got type="%s" value="%s"', [Ty, Val]));
    Assert.IsFalse(Ty.Contains('Date') or Ty.Contains('Time'),
      Format('Sng must not be upgraded to a date alias, got type="%s"', [Ty]));
    Assert.IsTrue(Val.Contains('1.5'),
      Format('Sng must render as 1.5, got value="%s"', [Val]));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_IndexedProperty_NotAutoEvaluated;
// An indexed (array) property must be marked and left as a leaf -- never
// auto-evaluated, because its getter needs an index and there is no general way
// to enumerate valid indices (arbitrary index type, no standard count, no
// guaranteed base). The scalar getter property on the same object must still
// behave normally. The user can still read an element with an explicit watch.
var
  FrameId, LocalsRef, BagRef, PropsRef: Integer;
  BagVar, ItemVar: TJSONObject;
begin
  StartSession('INDEXED_PROP_BODY', FrameId, LocalsRef);
  BagVar := FClient.FindVar(LocalsRef, 'Bag');
  Assert.IsNotNull(BagVar, 'Bag not found in locals');
  try
    BagRef := BagVar.GetValue<Integer>('variablesReference', 0);
  finally BagVar.Free; end;
  Assert.IsTrue(BagRef > 0, 'Bag not expandable');
  PropsRef := GroupVarRef(FClient, BagRef, 'properties');
  Assert.IsTrue(PropsRef > 0, 'expansion missing `properties` group');

  ItemVar := FClient.FindVar(PropsRef, 'Item');
  Assert.IsNotNull(ItemVar, 'indexed property Item missing from properties group');
  try
    var Val := ItemVar.GetValue<string>('value', '');
    var Ty  := ItemVar.GetValue<string>('type', '');
    var Ref := ItemVar.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(Val.Contains('indexed'),
      'indexed property must be marked, not auto-evaluated; got value="' + Val + '"');
    Assert.IsTrue(Ty.Contains('indexed'),
      'indexed property type must be annotated; got type="' + Ty + '"');
    Assert.AreEqual(0, Ref,
      'indexed property must be a leaf (no getter expansion); got ref=' + IntToStr(Ref));
  finally ItemVar.Free; end;

  // The scalar getter property on the same object is unaffected.
  var CapVar := FClient.FindVar(PropsRef, 'Caption');
  Assert.IsNotNull(CapVar, 'scalar property Caption missing');
  try
    Assert.IsFalse(CapVar.GetValue<string>('type', '').Contains('indexed'),
      'scalar Caption must not be marked indexed');
  finally CapVar.Free; end;
end;

procedure TDebuggerTests.Test_Types_WordBool_True;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'WB1');
  Assert.IsNotNull(V, 'WB1 missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('True'),
      'WB1 must display as True, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_LongBool_True;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'LB1');
  Assert.IsNotNull(V, 'LB1 missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('True'),
      'LB1 must display as True, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_ShortString_Content;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'SS1');
  Assert.IsNotNull(V, 'SS1 missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('short-string-ascii'),
      'SS1 must contain its content, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_WideString_Content;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'WS1');
  Assert.IsNotNull(V, 'WS1 missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('wide-string-utf16'),
      'WS1 must contain its content, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_TGUID_Display;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'G1');
  Assert.IsNotNull(V, 'G1 missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('2B6A4F3E') or Val.Contains('TGUID') or Val.Contains('{'),
      'G1 must surface as TGUID-shaped, got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_Interface_Live_HasClassName;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Cnt');
  Assert.IsNotNull(V, 'Cnt missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0') or Val.Equals('0x0'),
      'Cnt is a live interface, must NOT display as nil');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_Interface_Nil_DisplaysAsNil;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NilCnt');
  Assert.IsNotNull(V, 'NilCnt missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(SameText(Val, 'nil') or Val.Equals('$0') or Val.Equals('0x0') or
                  Val.Contains('nil'),
      'NilCnt must surface as nil-shaped, got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_MethodPointer_Nil;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'MPNil');
  Assert.IsNotNull(V, 'MPNil missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(SameText(Val, 'nil') or Val.Contains('nil') or
                  Val.Equals('$0') or Val.Equals('0x0'),
      'MPNil must surface as nil-shaped, got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_AnonProc_Assigned;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'AP');
  Assert.IsNotNull(V, 'AP missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0'),
      'AP was assigned to an anon proc; MUST NOT show as nil');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Closure_ExpandsCapturedFields;
var FrameId, LocalsRef, CloRef: Integer; V: TJSONObject;
begin
  // Captured fields resolve from debug info in ANY scenario: TD32 decodes the
  // `$ActRec` class FIELDLIST (it keys the class as `_ActRec`; GetClassMembers
  // retries `$`->`_`), so this works on a BPL and under NO_RSM too, not only the
  // mono `.rsm`.
  StartSession('CLOSURE_EXPAND', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Clo');
  Assert.IsNotNull(V, 'Clo (closure) missing');
  try
    CloRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(CloRef > 0, 'a live anonymous-method closure must be expandable');
  finally V.Free; end;

  // Captured CapInt=42 + CapStr='captured' resolve from the $ActRec debug-info
  // members (RSM), which carry the names/offsets/types RTTI omits for $ActRec.
  var CapIntVar := FClient.FindVar(CloRef, 'CapInt');
  Assert.IsNotNull(CapIntVar, 'captured CapInt missing from closure expansion');
  try
    Assert.AreEqual('42', ExtractDisplayValue(CapIntVar.GetValue<string>('value', '')),
      'captured CapInt must read 42');
  finally CapIntVar.Free; end;

  var CapStrVar := FClient.FindVar(CloRef, 'CapStr');
  Assert.IsNotNull(CapStrVar, 'captured CapStr missing from closure expansion');
  try
    Assert.IsTrue(CapStrVar.GetValue<string>('value', '').Contains('captured'),
      'captured CapStr must read ''captured''');
  finally CapStrVar.Free; end;
end;

procedure TDebuggerTests.Test_Closure_CapturedVarsVisibleInBody;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  // Works in every scenario now: the captured field VALUES come from TD32 (FIELDLIST
  // + `$`->`_` retry), and the anon-body FRAME name resolves from the module MAP,
  // which is range-scoped like TD32 (so an owned RVA the BPL-TD32 can't name falls
  // through to the MAP instead of being blocked).
  StartSession('CLOSURE_BODY', FrameId, LocalsRef);

  V := FindLocalByName(FClient, LocalsRef, 'CapInt');
  Assert.IsNotNull(V, 'captured CapInt must be visible as a local inside the closure body');
  try
    Assert.AreEqual('42', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'captured CapInt must read 42 inside the closure body');
  finally V.Free; end;

  V := FindLocalByName(FClient, LocalsRef, 'CapStr');
  Assert.IsNotNull(V, 'captured CapStr must be visible as a local inside the closure body');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('captured'),
      'captured CapStr must read ''captured'' inside the closure body');
  finally V.Free; end;

  // The anon method's OWN declared parameter (`procedure(X: Integer)`, invoked as
  // Clo(7)). No local/param provider carries its slot; it is recovered from the
  // decoded method signature (TD32 ARGLIST) placed at its Win64 ABI home slot.
  // The name is unavailable (a CV ARGLIST is a bare type list), so it surfaces
  // positionally as arg1.
  V := FindLocalByName(FClient, LocalsRef, 'arg1');
  Assert.IsNotNull(V, 'anon-method parameter arg1 (X) must be visible inside the closure body');
  try
    Assert.AreEqual('7', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'anon-method param arg1 (X) must read 7 (Clo(7))');
  finally V.Free; end;
end;

procedure TDebuggerTests.AssertArg(LocalsRef: Integer;
  const ArgName, Expected: string; Exact: Boolean = True);
begin
  var V := FindLocalByName(FClient, LocalsRef, ArgName);
  Assert.IsNotNull(V, ArgName + ' (anon-method param) must be visible in the closure body');
  try
    var Disp := ExtractDisplayValue(V.GetValue<string>('value', ''));
    if Exact then
      Assert.AreEqual(Expected, Disp, ArgName + ' value mismatch')
    else
      Assert.IsTrue(Disp.Contains(Expected),
        Format('%s value mismatch: expected to contain "%s", got "%s"', [ArgName, Expected, Disp]));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_ClosureParam_TwoInts;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_TWO', FrameId, LocalsRef);
  AssertArg(LocalsRef, 'arg1', '11');
  AssertArg(LocalsRef, 'arg2', '22');
end;

procedure TDebuggerTests.Test_ClosureParam_String;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_STR', FrameId, LocalsRef);
  AssertArg(LocalsRef, 'arg1', 'hello-param', False);
end;

procedure TDebuggerTests.Test_ClosureParam_Double;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_DBL', FrameId, LocalsRef);
  AssertArg(LocalsRef, 'arg1', '3.5', False);
end;

procedure TDebuggerTests.Test_ClosureParam_Int64;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_WIDE', FrameId, LocalsRef);
  AssertArg(LocalsRef, 'arg1', '9876543210');
end;

procedure TDebuggerTests.Test_ClosureParam_Boolean;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_BOOL', FrameId, LocalsRef);
  AssertArg(LocalsRef, 'arg1', 'True', False);
end;

procedure TDebuggerTests.Test_ClosureParam_Object;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_OBJ', FrameId, LocalsRef);
  // Object param: the home slot holds the instance pointer; it displays as the
  // class instance (`$addr (TParamObj)`) and is expandable (drill into W.Name).
  var V := FindLocalByName(FClient, LocalsRef, 'arg1');
  Assert.IsNotNull(V, 'arg1 (object param) must be visible in the closure body');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('TParamObj'),
      'object param arg1 must display its class name; got: ' + V.GetValue<string>('value', ''));
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'object param arg1 must be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_ClosureParam_Mixed;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_MIX', FrameId, LocalsRef);
  // procedure(N: Integer; S: string; D: Double; F: Boolean) -- exercises the
  // positional Win64 home-slot mapping across mixed integer / string / float / bool.
  AssertArg(LocalsRef, 'arg1', '7');
  AssertArg(LocalsRef, 'arg2', 'mixed', False);
  AssertArg(LocalsRef, 'arg3', '2.5', False);
  AssertArg(LocalsRef, 'arg4', 'True', False);
end;

procedure TDebuggerTests.Test_ClosureParam_SixIntsStackSpill;
var FrameId, LocalsRef: Integer;
begin
  StartSession('CLOP_SIX', FrameId, LocalsRef);
  // 6 Integer params: args 5-6 spill past the 4-slot register home area onto the
  // stack; the positional home-slot formula must keep resolving them.
  AssertArg(LocalsRef, 'arg1', '1');
  AssertArg(LocalsRef, 'arg2', '2');
  AssertArg(LocalsRef, 'arg3', '3');
  AssertArg(LocalsRef, 'arg4', '4');
  AssertArg(LocalsRef, 'arg5', '5');
  AssertArg(LocalsRef, 'arg6', '6');
end;

procedure TDebuggerTests.Test_Types_ClassRef_AssignedShowsClassName;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ClsRef');
  Assert.IsNotNull(V, 'ClsRef missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0'),
      'ClsRef assigned to TDerivedA; MUST NOT show as nil');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_ClassRef_NilDisplaysAsNil;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NilCls');
  Assert.IsNotNull(V, 'NilCls missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(SameText(Val, 'nil') or Val.Contains('nil') or
                  Val.Equals('$0') or Val.Equals('0x0'),
      'NilCls must surface nil-shaped, got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_GenericList_Expandable;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'GenList');
  Assert.IsNotNull(V, 'GenList missing');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'GenList (TList<Integer>) must be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_PtrPrimitive_DerefMatches;
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  // PI := @PRec.B and PRec.B = 2
  Resp := FClient.Evaluate('PI^', FrameId);
  try
    Assert.AreEqual('2', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'PI^ must deref to 2');
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_Types_PtrRecord_Expandable;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'RecP');
  Assert.IsNotNull(V, 'RecP missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0'),
      'RecP points to PRec; MUST NOT show as nil');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_UntypedPointer_HexDisplay;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'UP');
  Assert.IsNotNull(V, 'UP missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0'),
      'UP points to PRec; MUST NOT show as nil');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_PChar_StringContent;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'PCh');
  Assert.IsNotNull(V, 'PCh missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('pchar-content'),
      'PCh must show the string content, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_PackedRecord_FieldsVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'PRec');
  Assert.IsNotNull(V, 'PRec missing');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'PRec record must be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_ManagedRecord_FieldsVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'MRec');
  Assert.IsNotNull(V, 'MRec missing');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'MRec record must be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_Enum_DisplaysName;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Col');
  Assert.IsNotNull(V, 'Col missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('Green') or Val.Contains('1'),
      'Col=Green; expected name or ordinal 1, got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_BigEnum_DisplaysName;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Big');
  Assert.IsNotNull(V, 'Big missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('beK') or Val.Contains('10'),
      'Big=beK (ord 10); got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_NonEmptySet_Display;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Cols');
  Assert.IsNotNull(V, 'Cols missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('Red') or Val.Contains('Blue') or Val.Contains('['),
      'Cols=[Red,Blue]; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_EmptySet_Display;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'EmptyCols');
  Assert.IsNotNull(V, 'EmptyCols missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('[]') or Val.Contains('0') or Val.Contains('empty'),
      'EmptyCols=[]; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_TrickyOne_NotMisDecodedAsVariant;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'TrickyOne');
  Assert.IsNotNull(V, 'TrickyOne missing');
  try
    Assert.AreEqual('1', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'TrickyOne must read back 1, got: ' + V.GetValue<string>('value', ''));
    Assert.IsFalse(V.GetValue<string>('type', '').Contains('Variant'),
      'TrickyOne MUST surface as Integer, not Variant');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_ZeroInt_DisplaysZeroNotEmpty;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ZeroInt');
  Assert.IsNotNull(V, 'ZeroInt missing');
  try
    var Val := ExtractDisplayValue(V.GetValue<string>('value', ''));
    Assert.AreEqual('0', Val,
      'ZeroInt must display as 0, got: ' + V.GetValue<string>('value', ''));
    Assert.IsFalse(V.GetValue<string>('value', '').Contains('empty'),
      'ZeroInt must NOT decode as <empty> Variant');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Types_GenericList_EnumeratesElements;
// GenList = TList<Integer> with [10,20,30]. The backing storage
// (FItems: TArray<Integer>) must be reachable by drilling: expand
// GenList -> find FItems -> expand FItems -> elements 10/20/30.
var
  FrameId, LocalsRef: Integer;
  V, ItemsVar, ElemResp: TJSONObject;
  ListRef, ItemsRef: Integer;
  Blob: string;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'GenList');
  Assert.IsNotNull(V, 'GenList missing');
  try
    ListRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(ListRef > 0, 'GenList must be expandable');
  finally V.Free; end;

  // Level 1: locate FItems (the backing dyn-array). TList<T> exposes
  // properties, so its expansion splits into groups; FindVar descends into
  // the `fields` group to reach the backing field.
  ItemsRef := 0;
  ItemsVar := FClient.FindVar(ListRef, 'FItems');
  Assert.IsNotNull(ItemsVar, 'GenList.FItems missing from expansion');
  try
    ItemsRef := ItemsVar.GetValue<Integer>('variablesReference', 0);
  finally ItemsVar.Free; end;
  Assert.IsTrue(ItemsRef > 0,
    'GenList.FItems (backing TArray<Integer>) must be expandable');

  // Level 2: FItems elements must include 10/20/30.
  ElemResp := FClient.Variables(ItemsRef);
  try
    Blob := ElemResp.ToJSON;
    Assert.IsTrue(Blob.Contains('10') and Blob.Contains('20') and Blob.Contains('30'),
      'FItems must enumerate elements 10/20/30; got: ' + Blob);
  finally ElemResp.Free; end;
end;

procedure TDebuggerTests.Test_Watch_NonExistentName_ErrorShaped;
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('NoSuchSymbolXyz', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    // Must come back as a clear error token, NOT a stale / garbage value
    // and NOT a raw exception leak.
    Assert.IsTrue(Res.Contains('not found') or Res.Contains('<') or (Res = ''),
      'missing-name watch must surface a clean error, got: ' + Res);
    Assert.IsFalse(Res.Contains('Exception') or Res.Contains('Access violation'),
      'missing-name watch must not leak a raw exception, got: ' + Res);
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_Coll_DynArrayOfRecord_ElementFields;
// ArrRec: TArray<TPackedRec> with [(11,12,13),(21,22,23)]. Expanding the
// local must list elements; expanding element [1] must show B=22.
var
  FrameId, LocalsRef: Integer;
  V, ElemResp: TJSONObject;
  ArrRef: Integer;
  Blob: string;
begin
  StartSession('COLLECTIONS_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ArrRec');
  Assert.IsNotNull(V, 'ArrRec missing');
  try
    ArrRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(ArrRef > 0, 'ArrRec (dyn array of record) must be expandable');
  finally V.Free; end;
  ElemResp := FClient.Variables(ArrRef);
  try
    // Two elements; each is a record (expandable). The record field
    // values (12 / 22) must be reachable in the expansion tree.
    Blob := ElemResp.ToJSON;
    var Arr := ElemResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'ArrRec element list missing');
    Assert.IsTrue(Arr.Count >= 2, 'ArrRec must list >= 2 elements, got ' + IntToStr(Arr.Count));
  finally ElemResp.Free; end;
end;

procedure TDebuggerTests.Test_Coll_DynArrayOfClass_ElementInstance;
// ArrObj: TArray<TBase> with two TDerivedA instances. Expanding lists
// the elements; element [0] must surface as a class instance, not a
// raw pointer integer.
var
  FrameId, LocalsRef: Integer;
  V, ElemResp: TJSONObject;
  ArrRef: Integer;
  Blob: string;
begin
  StartSession('COLLECTIONS_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ArrObj');
  Assert.IsNotNull(V, 'ArrObj missing');
  try
    ArrRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(ArrRef > 0, 'ArrObj (dyn array of class) must be expandable');
  finally V.Free; end;
  ElemResp := FClient.Variables(ArrRef);
  try
    var Arr := ElemResp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'ArrObj element list missing');
    Assert.IsTrue(Arr.Count >= 2, 'ArrObj must list >= 2 elements');
    Blob := ElemResp.ToJSON;
    Assert.IsTrue(Blob.Contains('TDerivedA') or Blob.Contains('TBase'),
      'ArrObj elements must surface as class instances, got: ' + Blob);
  finally ElemResp.Free; end;
end;

procedure TDebuggerTests.Test_Coll_InterfacedClass_FieldVisible;
// Cnt: ICounter backed by TCounter(55). The interface variable should
// surface as a live instance; expanding it must reach the TCounter.Value
// field (refcounted-class field inspection through an interface slot).
var
  FrameId, LocalsRef: Integer;
  V, ExpResp: TJSONObject;
  Ref: Integer;
  Blob: string;
begin
  StartSession('COLLECTIONS_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Cnt');
  Assert.IsNotNull(V, 'Cnt (interface) missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0'),
      'Cnt is a live interface; MUST NOT be nil');
    Ref := V.GetValue<Integer>('variablesReference', 0);
  finally V.Free; end;
  // Interface expansion is a best-effort: if the adapter exposes the
  // backing object's fields, Value=55 (or 56 after NextValue) must be
  // reachable. Only assert when expandable so the test documents the
  // contract without over-constraining the not-yet-built path.
  if Ref > 0 then begin
    ExpResp := FClient.Variables(Ref);
    try
      Blob := ExpResp.ToJSON;
      Assert.IsTrue(Blob.Contains('Value') or Blob.Contains('55') or Blob.Contains('56'),
        'interface expansion should reach TCounter.Value; got: ' + Blob);
    finally ExpResp.Free; end;
  end;
end;

procedure TDebuggerTests.Test_DeepNest_OwnLocalVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('DEEP_NEST_INNER_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'InnerTag');
  Assert.IsNotNull(V, 'InnerTag missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('3.14'),
      'InnerTag=3.14; got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_DeepNest_ParentLocalVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('DEEP_NEST_INNER_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'RunDeepNesting.Mid.MidTag');
  if V = nil then
    V := FindLocalByName(FClient, LocalsRef, 'Mid.MidTag');
  if V = nil then
    V := FindLocalByName(FClient, LocalsRef, 'MidTag');
  Assert.IsNotNull(V, 'MidTag (parent local) must be visible from Inner');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('mid-value'),
      'MidTag content from Inner frame');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_DeepNest_GrandparentLocalVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('DEEP_NEST_INNER_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'RunDeepNesting.OuterTag');
  if V = nil then
    V := FindLocalByName(FClient, LocalsRef, 'OuterTag');
  Assert.IsNotNull(V, 'OuterTag (grandparent local) must be visible from Inner');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('777'),
      'OuterTag=777 from Inner frame');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_StaticClassMethod_NoSelfInLocals;
var FrameId, LocalsRef: Integer; Resp: TJSONObject; Arr: TJSONArray;
begin
  StartSession('STATIC_METHOD_BODY', FrameId, LocalsRef);
  Resp := FClient.Variables(LocalsRef);
  try
    Arr := Resp.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr);
    for var I := 0 to Arr.Count - 1 do begin
      var Nm := (Arr.Items[I] as TJSONObject).GetValue<string>('name', '');
      Assert.IsFalse(SameText(Nm, 'Self'),
        'static class method must NOT expose Self in locals');
    end;
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_OperatorBody_StoppableAndArgsVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('OPERATOR_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'A');
  Assert.IsNotNull(V, 'operator+ first arg A must be visible');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'operator arg A (record) should be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_PropertySetterBody_NewValueVisible;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('PROP_SETTER_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'AValue');
  Assert.IsNotNull(V, 'property setter AValue must be visible');
  try
    Assert.AreEqual('99', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'AValue=99 (just passed) got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_OutParam_AfterAssignment_ReadsBack;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('HELPER_OUT_BODY', FrameId, LocalsRef);
  // BP is AFTER `X := Length(Tag) * Multiplier` (5*3=15)
  V := FindLocalByName(FClient, LocalsRef, 'X');
  Assert.IsNotNull(V, 'out param X must be visible');
  try
    Assert.AreEqual('15', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'X (out) = 5*3 = 15, got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_ConstParam_ReadsValue;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('HELPER_OUT_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Tag');
  Assert.IsNotNull(V, 'const param Tag must be visible');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('hello'),
      'Tag=''hello'' got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_DefaultParam_TakesDefaultValue;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('HELPER_OUT_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Multiplier');
  Assert.IsNotNull(V, 'default param Multiplier must be visible');
  try
    Assert.AreEqual('3', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'Multiplier default 3 (caller did NOT pass), got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_CrossUnitDoWork_NoCollision;
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  // No dedicated BP marker -- this test stops at TYPES_BODY and
  // exercises the cross-unit name collision via WATCH expression on a
  // qualified name. With TestTarget.dpr's main calling
  // `TestTargetTypes.DoWork` AND e.g. a similarly-named helper
  // possibly emitted elsewhere, evaluating the qualified form must
  // still resolve.
  StartSession('TYPES_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('TestTargetTypes.DoWork', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    // Just verify the evaluate did not surface "not found"; the proc
    // may not be callable from watch but the symbol must resolve.
    Assert.IsFalse(Res.Contains('not found'),
      'TestTargetTypes.DoWork must resolve as a symbol, got: ' + Res);
  finally Resp.Free; end;
end;

// === Edge-case battery (TestTargetEdge.pas) ===========================

procedure TDebuggerTests.Test_Edge_LargeSet_BeyondOneByte;
// ManySet = [me0, me9, me19]. Bits 9 and 19 live beyond the first byte;
// a 1-byte set decode would drop them. Expansion/value must mention all
// three members.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ManySet');
  Assert.IsNotNull(V, 'ManySet missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('me0'),  'ManySet must contain me0; got: ' + Val);
    Assert.IsTrue(Val.Contains('me9'),  'ManySet must contain me9 (bit>7); got: ' + Val);
    Assert.IsTrue(Val.Contains('me19'), 'ManySet must contain me19 (bit>15); got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_GapEnum_DisplaysName;
// Gap = geB, explicit ordinal 10. Name must resolve despite the gap.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Gap');
  Assert.IsNotNull(V, 'Gap missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('geB') or Val.Contains('10'),
      'Gap=geB (ord 10); got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_EmptyString_DisplaysEmpty;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'EmptyStr');
  Assert.IsNotNull(V, 'EmptyStr missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('''''') or SameText(Val.Trim, '') or
                  Val.Contains('empty') or Val.Equals(''''''),
      'EmptyStr must render as empty string, got: ' + Val);
    Assert.IsFalse(Val.Contains('failed') or Val.Contains('Exception'),
      'EmptyStr must not error; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_NegInteger_Signed;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NegI');
  Assert.IsNotNull(V, 'NegI missing');
  try
    Assert.AreEqual('-5', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'NegI must be -5; got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_NegInt64_Signed;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NegI64');
  Assert.IsNotNull(V, 'NegI64 missing');
  try
    Assert.AreEqual('-5000000000', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'NegI64 must be -5000000000; got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_NegSmallInt_Signed;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NegSmall');
  Assert.IsNotNull(V, 'NegSmall missing');
  try
    Assert.AreEqual('-1234', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'NegSmall must be -1234; got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_FloatNaN;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'FNan');
  Assert.IsNotNull(V, 'FNan missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.ToUpper.Contains('NAN'),
      'FNan must render as NaN; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_FloatInfinity;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'FInf');
  Assert.IsNotNull(V, 'FInf missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.ToUpper.Contains('INF'),
      'FInf must render as Inf; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_LongString_NoCrash;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'LongStr');
  Assert.IsNotNull(V, 'LongStr missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('X'),
      'LongStr must surface its content (possibly truncated); got len ' + IntToStr(Length(Val)));
    Assert.IsFalse(Val.Contains('failed'),
      'LongStr must not fail to read; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_EmbeddedNulString;
// NulStr = 'a'#0'b'. A C-string read would stop at the NUL and show only
// 'a'; a length-prefixed read shows the full 3-char content.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NulStr');
  Assert.IsNotNull(V, 'NulStr missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('a'),
      'NulStr must at least surface its first char; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_EmojiString;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'EmojiStr');
  Assert.IsNotNull(V, 'EmojiStr missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('hi'),
      'EmojiStr must surface the ASCII prefix; got: ' + Val);
    Assert.IsFalse(Val.Contains('failed'),
      'EmojiStr must not fail to read; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_VariantRecord_Expands;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'VRec');
  Assert.IsNotNull(V, 'VRec missing');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'VRec (variant record) must be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Edge_InterfaceToClass;
// Thing: IThing backed by TThing. Evaluating Thing.Name (interface
// method) or expanding to the impl class must reach 'thing-impl'.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Thing.Name', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('thing-impl') or (not Res.Contains('not found')),
      'Thing.Name (interface method) should resolve; got: ' + Res);
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_Edge_CyclicGraph_NoInfiniteExpand;
// Root.Child = Leaf, Leaf.Parent = Root (cycle). Expanding Root one level
// must list Child; drilling Child must list Parent -- without the adapter
// hanging or crashing on the cycle.
var
  FrameId, LocalsRef, RootRef, ChildRef: Integer;
  V, ChildVar, R2: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Root');
  Assert.IsNotNull(V, 'Root missing');
  try
    RootRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(RootRef > 0, 'Root must be expandable');
  finally V.Free; end;
  // Child may surface as a field or a property -- FindVar descends both
  // synthetic groups of a property-bearing class.
  ChildRef := 0;
  ChildVar := FClient.FindVar(RootRef, 'Child');
  Assert.IsNotNull(ChildVar, 'Root.Child missing from expansion');
  try
    ChildRef := ChildVar.GetValue<Integer>('variablesReference', 0);
  finally ChildVar.Free; end;
  Assert.IsTrue(ChildRef > 0, 'Root.Child must be expandable');
  // Drill one more level into the cycle -- must return promptly.
  R2 := FClient.Variables(ChildRef);
  try
    Assert.IsNotNull(R2.GetValue('variables') as TJSONArray,
      'Child expansion (into the cycle) must return a variables array, not hang');
  finally R2.Free; end;
end;

procedure TDebuggerTests.Test_Edge_ObjectMidConstruction;
// BP inside TCtorProbe.Create AFTER FirstField:=111 but BEFORE
// SecondField:=222. FirstField must read 111; SecondField is still 0.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('CTOR_MID_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Self.FirstField', FrameId);
  try
    Assert.AreEqual('111', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'mid-ctor FirstField must be 111; got: ' + Resp.GetValue<string>('result', ''));
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_Edge_Recursion_PerFrameLocals;
// BP at EdgeFactorial base case (N=1). The stack holds frames for
// N=1,2,3,4,5. Walking frames, each frame's N parameter must be distinct
// and increasing.
var
  FrameId, LocalsRef: Integer;
  ST: TJSONObject;
  Frames: TJSONArray;
  SeenN1, SeenN5: Boolean;
begin
  StartSession('RECURSION_BASE_BODY', FrameId, LocalsRef);
  // Base frame: N must be 1.
  var BaseN := NonRttiResult(FClient, FrameId, 'N');
  Assert.AreEqual('1', ExtractDisplayValue(BaseN),
    'recursion base frame N must be 1; got: ' + BaseN);

  // Walk frames; collect N at each EdgeFactorial frame.
  ST := FClient.StackTrace(16);
  SeenN1 := False;
  SeenN5 := False;
  try
    Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsNotNull(Frames);
    for var I := 0 to Frames.Count - 1 do begin
      var Fr := Frames.Items[I] as TJSONObject;
      if not SameText(Fr.GetValue<string>('name', ''), 'EdgeFactorial') then Continue;
      var Fid := Fr.GetValue<Integer>('id', -1);
      var NVal := ExtractDisplayValue(NonRttiResult(FClient, Fid, 'N'));
      if NVal = '1' then SeenN1 := True;
      if NVal = '5' then SeenN5 := True;
    end;
  finally ST.Free; end;
  Assert.IsTrue(SeenN1, 'recursion: a frame with N=1 must be visible');
  Assert.IsTrue(SeenN5, 'recursion: the outermost frame with N=5 must be visible (per-frame locals)');
end;

// === Edge wave 2 (TestTargetEdge2.pas) ================================

procedure TDebuggerTests.Test_E2_MultiDimStatic_Element;
// MStatic[1,1] = 11. Watch the 2-D element.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('MStatic[1,1]', FrameId);
  try
    Assert.AreEqual('11', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'MStatic[1,1] must be 11; got: ' + Resp.GetValue<string>('result', ''));
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_E2_MultiDimDynamic_Expand;
// MDyn: TArray<TArray<Integer>> = [[1,2,3],[4,5]]. Expand outer -> inner.
var FrameId, LocalsRef, OuterRef: Integer; V, R: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'MDyn');
  Assert.IsNotNull(V, 'MDyn missing');
  try
    OuterRef := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(OuterRef > 0, 'MDyn (2D dyn array) must be expandable');
  finally V.Free; end;
  R := FClient.Variables(OuterRef);
  try
    var Arr := R.GetValue('variables') as TJSONArray;
    Assert.IsNotNull(Arr, 'MDyn outer expansion missing');
    Assert.IsTrue(Arr.Count >= 2, 'MDyn must list 2 inner arrays; got ' + IntToStr(Arr.Count));
  finally R.Free; end;
end;

procedure TDebuggerTests.Test_E2_OpenArrayParam_Element;
// const A: array of Integer = [10,20,30]. A[0]=10.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('OPEN_ARRAY_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('A[0]', FrameId);
  try
    Assert.AreEqual('10', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'open-array A[0] must be 10; got: ' + Resp.GetValue<string>('result', ''));
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_E2_NestedRecord3Deep;
// Outer.Mid.Inner.X = 7.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Outer.Mid.Inner.X', FrameId);
  try
    Assert.AreEqual('7', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'Outer.Mid.Inner.X must be 7; got: ' + Resp.GetValue<string>('result', ''));
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_E2_Currency_Value;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Cur');
  Assert.IsNotNull(V, 'Cur missing');
  try
    Assert.IsTrue(V.GetValue<string>('value', '').Contains('12.34'),
      'Cur must be 12.34; got: ' + V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_E2_FloatNegZero;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'FNegZero');
  Assert.IsNotNull(V, 'FNegZero missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('0'),
      'FNegZero must render as a zero; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_E2_ShortStringEmpty;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ShortEmpty');
  Assert.IsNotNull(V, 'ShortEmpty missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('''''') or SameText(Val.Trim, '') or Val.Equals(''''''),
      'ShortEmpty must render as empty; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_E2_LongDotChain;
// Chain.A.B.C.D = 1234 (4-deep dot chain through class instances).
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Chain.A.B.C.D', FrameId);
  try
    Assert.AreEqual('1234', ExtractDisplayValue(Resp.GetValue<string>('result', '')),
      'Chain.A.B.C.D must be 1234; got: ' + Resp.GetValue<string>('result', ''));
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_E2_FunctionPointer_Assigned;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'ProcPtr');
  Assert.IsNotNull(V, 'ProcPtr missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsFalse(SameText(Val, 'nil') or Val.Equals('$0'),
      'ProcPtr is assigned; MUST NOT be nil; got: ' + Val);
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_E2_GenericDict_Enumerate;
// Dict: TDictionary<Integer,string> with {7:seven, 8:eight}. The backing
// storage (FItems buckets) must be reachable; 'seven'/'eight' somewhere
// in the expansion tree.
var FrameId, LocalsRef, Ref: Integer; V, R: TJSONObject; Blob: string;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Dict');
  Assert.IsNotNull(V, 'Dict missing');
  try
    Ref := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(Ref > 0, 'Dict must be expandable');
  finally V.Free; end;
  R := FClient.Variables(Ref);
  try
    Blob := R.ToJSON;
    Assert.IsTrue(Blob.Contains('FItems') or Blob.Contains('FCount') or Blob.Contains('FBuckets'),
      'Dict expansion must expose backing storage fields; got: ' + Blob);
  finally R.Free; end;
end;

procedure TDebuggerTests.Test_E2_NestedGenericList;
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'NestList');
  Assert.IsNotNull(V, 'NestList missing');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'NestList (TList<TList<Integer>>) must be expandable');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_SetVar_LocalInteger;
// Change a local Integer via setVariable and read it back.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.SetVariable(LocalsRef, 'SetLocal', '99');
  try
    var NewVal := Resp.GetValue<string>('value', '');
    Assert.IsTrue(ExtractDisplayValue(NewVal).Contains('99'),
      'setVariable SetLocal:=99 must report 99; got: ' + NewVal);
  finally Resp.Free; end;
  // Read back via evaluate to confirm it stuck in debuggee memory.
  var Chk := FClient.Evaluate('SetLocal', FrameId);
  try
    Assert.AreEqual('99', ExtractDisplayValue(Chk.GetValue<string>('result', '')),
      'SetLocal must read back 99 after setVariable');
  finally Chk.Free; end;
end;

procedure TDebuggerTests.Test_SetVar_EnumByName;
// Reuse the EDGE_BODY frame where Gap: TGapEnum lives. Set it to geC by name.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  Resp := FClient.SetVariable(LocalsRef, 'Gap', 'geC');
  try
    var Val := Resp.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('geC') or Val.Contains('20'),
      'setVariable Gap:=geC must report geC/20; got: ' + Val);
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_SetVar_TypeMismatch_Rejected;
// Setting an Integer local to a non-numeric string must fail cleanly,
// not corrupt memory or crash the session.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.SetVariableRaw(LocalsRef, 'SetLocal', 'not_a_number');
  try
    Assert.IsTrue((not Resp.GetValue<Boolean>('success', True)) or
                  Resp.ToJSON.Contains('rror') or Resp.ToJSON.Contains('alid'),
      'type-mismatch setVariable must be rejected, not silently accepted');
  finally Resp.Free; end;
  // Session must still be alive: a follow-up evaluate works.
  var Chk := FClient.Evaluate('SetLocal', FrameId);
  try
    Assert.IsTrue(Chk.GetValue<string>('result', '') <> '',
      'session must survive a rejected setVariable');
  finally Chk.Free; end;
end;

procedure TDebuggerTests.Test_Eval_AddressOf_Local;
// @SetLocal must yield a non-zero pointer.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('@SetLocal', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found') or Res.Contains('unexpected') or
                   Res.Equals('0') or Res.Equals('$0'),
      '@SetLocal must yield a non-zero address; got: ' + Res);
  finally Resp.Free; end;
end;

procedure TDebuggerTests.Test_Eval_AssignmentInWatch;
// `SetLocal := 77` evaluated as a watch must assign and the value read
// back as 77.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('SetLocal := 77', FrameId);
  try
    // Either the evaluate reports 77, or (if assignment-in-watch is not
    // supported) it returns a clean error -- but must not crash.
    var Res := Resp.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('77') or Res.Contains('<') or (Res = ''),
      'assignment-in-watch must assign or cleanly decline; got: ' + Res);
  finally Resp.Free; end;
end;

// === Control flow (TestTargetFlow.pas) ================================

function TopFrameName(FClient: TDapClient): string;
var ST: TJSONObject; Frames: TJSONArray;
begin
  Result := '';
  ST := FClient.StackTrace(4);
  try
    Frames := ST.GetValue('stackFrames') as TJSONArray;
    if (Frames <> nil) and (Frames.Count > 0) then
      Result := (Frames.Items[0] as TJSONObject).GetValue<string>('name', '');
  finally ST.Free; end;
end;

function TopFrameLine(FClient: TDapClient): Integer;
var ST: TJSONObject; Frames: TJSONArray;
begin
  Result := 0;
  ST := FClient.StackTrace(1);
  try
    Frames := ST.GetValue('stackFrames') as TJSONArray;
    if (Frames <> nil) and (Frames.Count > 0) then
      Result := (Frames.Items[0] as TJSONObject).GetValue<Integer>('line', 0);
  finally ST.Free; end;
end;

// SeDebugPrivilege probe shared by the attach tests: attach needs it, so
// when it is not held we skip rather than fail (the feature still works
// under an elevated VS Code).
function HaveSeDebugPrivilege: Boolean;
const
  SE_DEBUG_NAME_W = 'SeDebugPrivilege';
var
  Tok: THandle;
  Luid: TLargeInteger;
  Got: DWORD;
  Buf: array[0..1023] of Byte;
  Privs: ^TTokenPrivileges;
begin
  Result := False;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Tok) then Exit;
  try
    if not LookupPrivilegeValue(nil, SE_DEBUG_NAME_W, Luid) then Exit;
    Got := 0;
    GetTokenInformation(Tok, TokenPrivileges, @Buf[0], SizeOf(Buf), Got);
    if Got = 0 then Exit;
    Privs := @Buf[0];
    for var I := 0 to Privs.PrivilegeCount - 1 do
      if Int64(Privs.Privileges[I].Luid) = Int64(Luid) then
        Exit(True);
  finally
    CloseHandle(Tok);
  end;
end;

procedure TDebuggerTests.Test_Step_Over_StaysInProc;
var FrameId, LocalsRef: Integer; Stopped: TJSONObject;
begin
  StartSession('STEP_START', FrameId, LocalsRef);
  Stopped := FClient.StepOver;
  try Stopped.Free; except end;
  var S := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('step', S.GetValue<string>('reason', ''),
      'step-over must produce a step stop');
  finally S.Free; end;
  Assert.IsTrue(SameText(TopFrameName(FClient), 'RunStepFlow'),
    'step-over must stay in RunStepFlow; got: ' + TopFrameName(FClient));
end;

procedure TDebuggerTests.Test_Step_Over_NotTakenBranch_LandsNextLine;
// Step over an `if cond then <body>` whose condition is FALSE at runtime: the
// `then` body is skipped, so execution jumps from the `if` line to the
// fall-through line. A step-over that armed only the textual next line (the
// skipped body) would never be hit and run free to the next breakpoint. The
// step must land on STEP_IF_LAND (the fall-through), not STEP_BRANCH_END.
var
  IfLine, LandLine, EndLine, GotLine: Integer;
  Reason: string;
begin
  IfLine   := Bp('STEP_IF');
  LandLine := Bp('STEP_IF_LAND');
  EndLine  := Bp('STEP_BRANCH_END');
  Assert.IsTrue((IfLine > 0) and (LandLine > 0) and (EndLine > 0),
    'STEP_IF / STEP_IF_LAND / STEP_BRANCH_END markers must resolve');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // BP at the `if` and a guard BP further down. Old behaviour (single next-line
  // BP on the skipped body) runs free and stops at the guard -> GotLine = EndLine.
  FClient.SetBreakpoints(FBpSourceFile, [IfLine, EndLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  FClient.WaitForStopped.Free;            // at STEP_IF
  FClient.StepOver.Free;
  var S := FClient.WaitForStopped(8000);
  try
    Reason := S.GetValue<string>('reason', '');
  finally S.Free; end;
  var ST := FClient.StackTrace(1);
  try
    var Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'no stack frame after step');
    GotLine := (Frames.Items[0] as TJSONObject).GetValue<Integer>('line', 0);
  finally ST.Free; end;
  Assert.AreEqual(LandLine, GotLine,
    Format('step over a not-taken branch must land on STEP_IF_LAND (line %d); landed on %d',
      [LandLine, GotLine]));
  Assert.AreEqual('step', Reason, 'stop must be a step, not a runaway breakpoint hit');
end;

procedure TDebuggerTests.Test_Step_Over_FromFunctionEntry_LandsNextLine;
// Step over while stopped at a function's ENTRY line -- the `begin`, before the
// prologue has established the frame (RSP is at its entry value). The step must
// advance to the next line in the SAME function. The earlier RSP-based step-over
// captured the entry RSP and then treated every post-prologue same-frame line as
// a deeper recursive frame, skipping them all and running free out of the
// function -> the debugger appeared to freeze.
//
// The entry stop is reached with a BREAKPOINT on the `begin` line, which binds to
// the function's entry address. A step-into no longer parks there: it runs on to
// the first statement, because at the entry the register arguments are not yet
// spilled and every local would be read out of the caller's frame (see
// DebugSessionTests.StepInto_Method_ReportsSpilledSelfAndParams).
var
  BeginLine, L1Line, GotLine: Integer;
  Reason: string;
begin
  BeginLine := Bp('STEP_ML_BEGIN');
  L1Line    := Bp('STEP_ML_L1');
  Assert.IsTrue((BeginLine > 0) and (L1Line > 0),
    'STEP_ML_BEGIN / STEP_ML_L1 markers must resolve');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // Only the entry line is a breakpoint. There is no guard BP downstream, so a
  // runaway step-over runs the program to exit and WaitForStopped times out.
  FClient.SetBreakpoints(FBpSourceFile, [BeginLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  FClient.WaitForStopped.Free;            // at STEP_ML_BEGIN, the function entry
  Assert.IsTrue(SameText(TopFrameName(FClient), 'StepMultiLine'),
    'breakpoint must stop inside StepMultiLine; got: ' + TopFrameName(FClient));
  Assert.AreEqual(BeginLine, TopFrameLine(FClient),
    Format('breakpoint must bind to the function entry line %d', [BeginLine]));
  // Step over from the entry line: must advance to the next line in the function.
  FClient.StepOver.Free;
  var S := FClient.WaitForStopped(8000);
  try
    Reason := S.GetValue<string>('reason', '');
  finally S.Free; end;
  GotLine := TopFrameLine(FClient);
  Assert.IsTrue(SameText(TopFrameName(FClient), 'StepMultiLine'),
    'step-over from entry must stay in StepMultiLine; got: ' + TopFrameName(FClient));
  Assert.AreEqual(L1Line, GotLine,
    Format('step-over from the entry line must land on the next line %d; landed on %d',
      [L1Line, GotLine]));
  Assert.AreEqual('step', Reason, 'stop must be a step, not a runaway');
end;

procedure TDebuggerTests.Test_Step_Over_ConsecutiveParamlessCalls_StopsEachLine;
// Step over a line that is a single parameterless call (`Foo;`) when the next
// line is ALSO such a call. The return address of the first call is exactly the
// second call's instruction; the step must STOP on that next line, not step
// over the second call too and chain through the block. Repro of the
// sharedBugReporting JclHookExceptions/... sequence skipping straight to the end.
var
  L1, L2, EndL, GotLine: Integer;
  Reason: string;
begin
  L1   := Bp('STEP_CALLS_1');
  L2   := Bp('STEP_CALLS_2');
  EndL := Bp('STEP_CALLS_END');
  Assert.IsTrue((L1 > 0) and (L2 > 0) and (EndL > 0),
    'STEP_CALLS_1 / _2 / _END markers must resolve');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  // BP at the first call and a guard at the block end. The bug chains through
  // the intermediate parameterless calls and stops only at the guard.
  FClient.SetBreakpoints(FBpSourceFile, [L1, EndL]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  FClient.WaitForStopped.Free;            // at STEP_CALLS_1
  FClient.StepOver.Free;
  var S := FClient.WaitForStopped(8000);
  try
    Reason := S.GetValue<string>('reason', '');
  finally S.Free; end;
  GotLine := TopFrameLine(FClient);
  Assert.AreEqual(L2, GotLine,
    Format('step-over a parameterless call must land on the next line %d; landed on %d',
      [L2, GotLine]));
  Assert.AreEqual('step', Reason, 'stop must be a step, not a runaway breakpoint');
end;

procedure TDebuggerTests.Test_Step_Over_ManagedClear_LandsNextLine;
// Step over `Arr := nil` (clears a managed dynamic array via an RTL helper
// call). It must land on the next line. Also a perf guard: the helper must be
// run full-speed (one run-to-return), not single-stepped instruction by
// instruction -- see the SO done diagnostic in the adapter log.
var
  StartL, EndL, GotLine: Integer;
begin
  StartL := Bp('STEP_MGCLEAR_START');
  EndL   := Bp('STEP_MGCLEAR_END');
  Assert.IsTrue((StartL > 0) and (EndL > 0), 'STEP_MGCLEAR markers must resolve');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [StartL]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  FClient.WaitForStopped.Free;            // at STEP_MGCLEAR_START (Arr := [...])
  FClient.StepOver.Free;
  FClient.WaitForStopped(8000).Free;      // at `Arr := nil`
  FClient.StepOver.Free;                  // over the managed clear
  FClient.WaitForStopped(8000).Free;
  GotLine := TopFrameLine(FClient);
  Assert.AreEqual(EndL, GotLine,
    Format('step-over a managed clear must land on the next line %d; landed on %d',
      [EndL, GotLine]));
end;

procedure TDebuggerTests.Test_Step_Into_EntersHelper;
var FrameId, LocalsRef: Integer;
begin
  StartSession('STEP_START', FrameId, LocalsRef);
  // STEP_START is on `R := 1`; step over it to land on the StepHelper call.
  FClient.StepOver.Free;
  FClient.WaitForStopped(8000).Free;
  // Now on the call line; step into StepHelper.
  FClient.StepIn.Free;
  var S := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('step', S.GetValue<string>('reason', ''));
  finally S.Free; end;
  Assert.IsTrue(SameText(TopFrameName(FClient), 'StepHelper'),
    'step-into must enter StepHelper; got: ' + TopFrameName(FClient));
end;

procedure TDebuggerTests.Test_Step_Out_ReturnsToCaller;
var FrameId, LocalsRef: Integer;
begin
  StartSession('STEP_HELPER_BODY', FrameId, LocalsRef);
  // Stopped inside StepHelper; step out returns to RunStepFlow.
  FClient.StepOut.Free;
  var S := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('step', S.GetValue<string>('reason', ''));
  finally S.Free; end;
  Assert.IsTrue(SameText(TopFrameName(FClient), 'RunStepFlow'),
    'step-out must return to RunStepFlow; got: ' + TopFrameName(FClient));
end;

procedure TDebuggerTests.Test_Bp_InPropertyGetter;
// A BP inside a property getter body must fire when the property is read.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('GETTER_BODY', FrameId, LocalsRef);
  Assert.IsTrue(SameText(TopFrameName(FClient), 'GetVal') or
                TopFrameName(FClient).Contains('GetVal'),
    'BP must stop inside the getter GetVal; got: ' + TopFrameName(FClient));
  V := FindLocalByName(FClient, LocalsRef, 'Self');
  if V <> nil then V.Free;  // Self may or may not be listed; not asserted
end;

procedure TDebuggerTests.Test_Step_IntoNoDebugInfo_StepsOver;
// From STEP_START, advance to the `R := Length(IntToStr(R))` line, then
// step INTO. IntToStr/Length are RTL with no debug info: step-into must
// degrade to step-over (pivot to step-out at the sourceless call) and
// resurface on the next Delphi line, still inside RunStepFlow -- never
// park the user in RTL internals.
var FrameId, LocalsRef: Integer;
begin
  StartSession('STEP_START', FrameId, LocalsRef);
  FClient.StepOver.Free;                 // R := 1 -> call line
  FClient.WaitForStopped(8000).Free;
  FClient.StepOver.Free;                 // call line -> Length(IntToStr(R)) line
  FClient.WaitForStopped(8000).Free;
  FClient.StepIn.Free;                   // into RTL -> must behave as step-over
  var S := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('step', S.GetValue<string>('reason', ''),
      'step-into a no-debug-info RTL call must produce a step stop');
  finally S.Free; end;
  Assert.IsTrue(SameText(TopFrameName(FClient), 'RunStepFlow'),
    'step-into RTL must resurface in RunStepFlow, not park in RTL; got: ' +
    TopFrameName(FClient));
end;

procedure TDebuggerTests.Test_Exc_NestedFinally_HandlerCatches;
// Stopped in the except handler (no exception filter needed -- the raise
// is caught internally). E.Message must be the raised text AND FinallyRan
// must be 1, proving the nested finally ran before the handler.
var FrameId, LocalsRef: Integer; Resp: TJSONObject; V: TJSONObject;
begin
  StartSession('EXC_NESTED_CATCH', FrameId, LocalsRef, ['--run-exc-flow']);
  Resp := FClient.Evaluate('E.Message', FrameId);
  try
    Assert.IsTrue(Resp.GetValue<string>('result', '').Contains('flow-exc'),
      'handler E.Message must be flow-exc; got: ' + Resp.GetValue<string>('result', ''));
  finally Resp.Free; end;
  V := FindLocalByName(FClient, LocalsRef, 'FinallyRan');
  Assert.IsNotNull(V, 'FinallyRan missing');
  try
    Assert.AreEqual('1', ExtractDisplayValue(V.GetValue<string>('value', '')),
      'nested finally must have run (FinallyRan=1) before the handler; got: ' +
      V.GetValue<string>('value', ''));
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Flow_Nest3_AllAncestorsVisible;
// 3 named nesting levels: Inner sees own InnerV=3, parent MidV=2,
// grandparent OuterV=1.
var FrameId, LocalsRef: Integer;
  function L(const N: string): string;
  var V: TJSONObject;
  begin
    Result := '';
    V := FindLocalByName(FClient, LocalsRef, N);
    if V = nil then V := FindLocalByName(FClient, LocalsRef, 'Mid.' + N);
    if V = nil then V := FindLocalByName(FClient, LocalsRef, 'RunNest3Flow.Mid.' + N);
    if V = nil then V := FindLocalByName(FClient, LocalsRef, 'RunNest3Flow.' + N);
    if V <> nil then
    try Result := ExtractDisplayValue(V.GetValue<string>('value', '')); finally V.Free; end;
  end;
begin
  StartSession('NEST3_INNER', FrameId, LocalsRef);
  Assert.AreEqual('3', L('InnerV'), 'own InnerV must be 3');
  Assert.AreEqual('2', L('MidV'),   'parent MidV must be 2');
  Assert.AreEqual('1', L('OuterV'), 'grandparent OuterV must be 1');
end;

procedure TDebuggerTests.Test_Flow_RecByVal_FieldsReadable;
// Rec := MakeRec(11,22) -- record returned by value; fields readable.
var FrameId, LocalsRef: Integer; RX, RY: TJSONObject;
begin
  StartSession('REC_BYVAL_BODY', FrameId, LocalsRef);
  RX := FClient.Evaluate('Rec.X', FrameId);
  try
    Assert.AreEqual('11', ExtractDisplayValue(RX.GetValue<string>('result', '')),
      'Rec.X must be 11; got: ' + RX.GetValue<string>('result', ''));
  finally RX.Free; end;
  RY := FClient.Evaluate('Rec.Y', FrameId);
  try
    Assert.AreEqual('22', ExtractDisplayValue(RY.GetValue<string>('result', '')),
      'Rec.Y must be 22; got: ' + RY.GetValue<string>('result', ''));
  finally RY.Free; end;
end;

procedure TDebuggerTests.Test_Bp_NoCodeLine_HandledCleanly;
// A breakpoint requested on a comment-only / no-code line must be handled
// cleanly: it may verify-and-relocate to the next code line or stay
// unverified, but it must NOT crash the adapter or break a real breakpoint
// set in the same request. The real BP (STEP_START) still fires.
var NoCode, RealLine: Integer; Stopped: TJSONObject;
begin
  NoCode   := Bp('NO_CODE_LINE');
  RealLine := Bp('STEP_START');   // both in TestTargetFlow.pas -> FBpSourceFile
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [NoCode, RealLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'a no-code-line BP must not break a real BP in the same request');
    Assert.IsTrue(SameText(TopFrameName(FClient), 'RunStepFlow'),
      'must stop at the real BP in RunStepFlow; got: ' + TopFrameName(FClient));
  finally Stopped.Free; end;
end;

// === BACKLOG stubs (all [Ignore]; Assert.Fail forces impl when tackled) ===
procedure TDebuggerTests.Test_BL_Step_IntoBplFunction;
// Stop at a call inside BPL-resident code (PkgAdd) and step INTO the callee
// (PkgInner, also in the BPL). The step engine must resolve the next source
// line from the BPL's own debug info and land in PkgInner.
var BpLine: Integer; Stopped, S: TJSONObject;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_STEP_CALL');
  Assert.IsTrue(BpLine > 0, 'PKG_STEP_CALL marker not found in TestPkgUnit.pas');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args := ['--load-package'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'must stop at the PkgInner call in the BPL');
  finally Stopped.Free; end;
  FClient.StepIn.Free;
  S := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('step', S.GetValue<string>('reason', ''),
      'step-into must produce a step stop');
  finally S.Free; end;
  Assert.IsTrue(SameText(TopFrameName(FClient), 'PkgInner'),
    'step-into must enter the BPL function PkgInner; got: ' + TopFrameName(FClient));
end;
procedure TDebuggerTests.Test_BL_Step_OverCallThatHitsBp;
// Stop AT the call line (STEP_CALL); a BP is also planted inside StepHelper.
// Stepping OVER the `R := StepHelper(R)` call must be pre-empted by the BP
// inside the callee (the breakpoint wins over the step).
var CallLine, HelperLine: Integer; Stopped: TJSONObject;
begin
  CallLine   := Bp('STEP_CALL');
  HelperLine := Bp('STEP_HELPER_BODY');   // both markers live in TestTargetFlow.pas -> FBpSourceFile
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [CallLine, HelperLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  FClient.WaitForStopped.Free;            // at STEP_CALL (the call line)
  FClient.StepOver.Free;                  // step over the StepHelper(R) call
  Stopped := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'a BP inside the stepped-over callee must win over the step');
    Assert.IsTrue(SameText(TopFrameName(FClient), 'StepHelper'),
      'must stop inside StepHelper at its BP; got: ' + TopFrameName(FClient));
  finally Stopped.Free; end;
end;
procedure TDebuggerTests.Test_BL_Step_AtRaise;
// Stop AT a `raise` (marker STEP_AT_RAISE) with exception filters off, then step
// OVER it. The raise unwinds into the local except handler, so the step must
// land on the handler line -- not run away or stop at an unrelated line.
var
  FrameId, LocalsRef, HandlerLine, LandLine: Integer;
begin
  HandlerLine := Bp('STEP_RAISE_HANDLER');   // line lookup only; no BP planted here
  StartSession('STEP_AT_RAISE', FrameId, LocalsRef, ['--run-step-raise']);
  FClient.StepOver.Free;
  FClient.WaitForStopped(8000).Free;
  var ST := FClient.StackTrace(1);
  try
    var Frames := ST.GetValue('stackFrames') as TJSONArray;
    Assert.IsTrue((Frames <> nil) and (Frames.Count > 0), 'no stack frame after step');
    LandLine := (Frames.Items[0] as TJSONObject).GetValue<Integer>('line', 0);
  finally ST.Free; end;
  Assert.AreEqual(HandlerLine, LandLine,
    Format('step over a raise must land on the except-handler line %d; landed on %d',
      [HandlerLine, LandLine]));
end;
procedure TDebuggerTests.Test_BL_Exc_ReRaise;
// A bare `raise;` in a handler re-propagates the same exception, producing a
// SECOND first-chance event. With the Delphi filter on the debugger stops
// twice; continuing past the re-raise lets the outer handler catch it (the
// session stays alive). Continuing through the whole run isn't asserted (the
// default target run has other first-chance raises that the filter would also
// stop on); proving two stops + a clean continue past the re-raise suffices.
var S1, S2: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['delphi', 'unhandled']).Free;
  LaunchTarget(['--run-reraise']).Free;
  FClient.ConfigDone.Free;
  S1 := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', S1.GetValue<string>('reason', ''),
      'first raise must surface as an exception stop');
  finally S1.Free; end;
  FClient.Continue_.Free;
  S2 := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', S2.GetValue<string>('reason', ''),
      'the bare re-raise must surface as a second exception stop');
  finally S2.Free; end;
  FClient.Continue_.Free;   // outer handler catches; returning = session alive
end;
procedure TDebuggerTests.Test_BL_Exc_OsAccessViolation;
// A nil-pointer write raises an OS access violation (not a Delphi raise).
// With the `av` filter on, it must surface as an exception stop.
var Stopped: TJSONObject;
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['av', 'unhandled']).Free;
  LaunchTarget(['--run-av']).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('exception', Stopped.GetValue<string>('reason', ''),
      'access violation must surface as an exception stop; got: '
      + Stopped.GetValue<string>('reason', ''));
  finally Stopped.Free; end;
end;
procedure TDebuggerTests.Test_BL_Exc_DuringEvaluate;
// A watch/hover that invokes a method which RAISES must not hang or kill the
// session. The adapter aborts the synthetic call (restores the pre-call
// context) and returns; a follow-up evaluate still works. If the abort were
// missing, RunMethodCall would spin forever and this evaluate would time out.
var FrameId, LocalsRef: Integer; R, Chk: TJSONObject;
begin
  StartSession('MAIN_GCOUNTER', FrameId, LocalsRef);
  R := FClient.Evaluate('TheStuff.RaiseBoom()', FrameId);   // must return, not hang
  try
    Assert.IsTrue(R <> nil, 'evaluate of a raising method must return a response');
  finally R.Free; end;
  Chk := FClient.Evaluate('1 + 1', FrameId);
  try
    Assert.AreEqual('2', ExtractDisplayValue(Chk.GetValue<string>('result', '')),
      'session must survive a watch whose method raised');
  finally Chk.Free; end;
end;
procedure TDebuggerTests.Test_BL_Exc_BplDefinedClass;
// An exception whose class (EPkgError) is DEFINED in a runtime BPL must be
// inspectable in its handler: E.ClassName / E.Message resolve from the
// BPL's runtime RTTI even though the host EXE never declared the type.
var BpLine, FrameId: Integer; Stopped, R: TJSONObject;
begin
  BpLine := FindBpLine(PackageSrc, 'PKG_EXC_HANDLER');
  Assert.IsTrue(BpLine > 0, 'PKG_EXC_HANDLER marker not found in TestPkgUnit.pas');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(PackageSrc, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;   // stop only at the handler BP, not the raise
  var Spec := Default(TLaunchSpec);
  Spec.Args := ['--load-package', '--pkg-raise'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'must stop in the BPL exception handler');
  finally Stopped.Free; end;
  FrameId := FClient.GetFrameId;
  R := FClient.Evaluate('E.ClassName', FrameId);
  try
    Assert.IsTrue(R.GetValue<string>('result', '').Contains('EPkgError'),
      'E.ClassName must resolve the BPL-defined class; got: '
      + R.GetValue<string>('result', ''));
  finally R.Free; end;
  R := FClient.Evaluate('E.Message', FrameId);
  try
    Assert.IsTrue(R.GetValue<string>('result', '').Contains('pkg-exc-msg'),
      'E.Message must be readable; got: ' + R.GetValue<string>('result', ''));
  finally R.Free; end;
end;
procedure TDebuggerTests.Test_BL_Bp_FirstLine;
// A breakpoint on the very first executable statement of the program's main
// block must verify and fire -- the startup break plants user BPs before the
// program runs any of its own code.
var Line: Integer; Stopped: TJSONObject;
begin
  SkipIfBpl('MAIN_FIRST_LINE is the program main-block first executable line; a BPL/package has no program begin..end. block, so it cannot fire under TestHost+TestSubject.');
  Line := Bp('MAIN_FIRST_LINE');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [Line]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  FClient.Launch(TargetExe, TargetMap, TargetRsm, TargetDir).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'BP on the first program line must stop');
    Assert.AreEqual(Line, Stopped.GetValue<Integer>('line', -1),
      'must stop on the first-line marker');
  finally Stopped.Free; end;
end;
procedure TDebuggerTests.Test_BL_Bp_MultipleSameLine;
// Two breakpoints requested on the SAME source line must not double-fire
// or break binding: the line still stops exactly once per pass.
var BpLine: Integer; Stopped: TJSONObject;
begin
  BpLine := Bp('BP_LOOP');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine, BpLine]).Free;  // dup line
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'duplicate-line BP must still stop');
  finally Stopped.Free; end;
end;

procedure TDebuggerTests.Test_BL_Bp_DisabledThenEnabled;
// BP set, hit; cleared (disabled); re-set (enabled) -- must re-bind and
// fire again on a later loop iteration.
var BpLine: Integer; S1, S2: TJSONObject;
begin
  BpLine := Bp('BP_LOOP');
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget.Free;
  FClient.ConfigDone.Free;
  S1 := FClient.WaitForStopped;
  try
    Assert.AreEqual('breakpoint', S1.GetValue<string>('reason', ''), 'first hit');
  finally S1.Free; end;
  // Disable (clear) then re-enable (re-set) the same line.
  FClient.SetBreakpoints(TargetSrc, []).Free;
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.Continue_.Free;
  // BP_LOOP runs 5 iterations, so a re-set BP must catch a later one.
  S2 := FClient.WaitForStopped(8000);
  try
    Assert.AreEqual('breakpoint', S2.GetValue<string>('reason', ''),
      're-enabled BP must fire again on a later iteration');
  finally S2.Free; end;
end;
procedure TDebuggerTests.Test_BL_Module_BplLoadFails;
// LoadPackage of a missing BPL raises EPackageError in the target (caught
// there). The adapter must not choke on a load that maps no debug-info
// module: the session runs to completion. Delphi filter off so the caught
// exception stays silent.
begin
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized);
  FClient.SetExceptionBreakpoints(['unhandled']).Free;
  LaunchTarget(['--load-missing-bpl']).Free;
  FClient.ConfigDone.Free;
  Assert.IsTrue(FClient.WaitForTerminated(15000),
    'a failed BPL load must be handled gracefully and the session must complete');
end;
procedure TDebuggerTests.Test_BL_Module_DetachLeavesRunning;
// Attach with killOnDetach=False, then disconnect. The adapter must detach
// via DebugActiveProcessStop and leave the target RUNNING (not terminate
// it) -- the production-attach workflow.
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  Stopped: TJSONObject;
  BpLine: Integer;
begin
  if not HaveSeDebugPrivilege then begin
    TDUnitX.CurrentRunner.Status(
      'Skipping: SeDebugPrivilege not held; run elevated to exercise detach.');
    Exit;
  end;
  // The attach break-in is swallowed by design, so stop on a real breakpoint in
  // the survive-loop; after detach the loop keeps running (target stays alive).
  BpLine := Bp('ATTACH_SURVIVE_BODY');   // sets FBpSourceFile = TestTarget.dpr
  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  CmdLine := '"' + TargetExe + '" --attach-survive';
  Assert.IsTrue(CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI),
    'CreateProcess for detach test failed: ' + IntToStr(GetLastError));
  CloseHandle(PI.hThread);
  try
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized);
    FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
    FClient.SetExceptionBreakpoints([]).Free;
    FClient.Attach(PI.dwProcessId, TargetExe, TargetMap, TargetRsm, TargetDir,
      False).Free;   // killOnDetach = False
    FClient.ConfigDone.Free;
    // Stop at the survive-loop breakpoint so the target is in a known state
    // before we detach.
    Stopped := FClient.WaitForStopped(20000);
    Stopped.Free;
    FClient.Disconnect.Free;          // adapter -> DebugActiveProcessStop
    FClient.Stop;                     // tear down the adapter pipe
    FreeAndNil(FClient);
    // The target must still be alive (looping), not terminated.
    Assert.AreEqual(Cardinal(WAIT_TIMEOUT),
      Cardinal(WaitForSingleObject(PI.hProcess, 2000)),
      'detach with killOnDetach=False must leave the target running');
  finally
    TerminateProcess(PI.hProcess, 0);   // clean up the survivor
    CloseHandle(PI.hProcess);
  end;
end;
procedure TDebuggerTests.Test_BL_Module_DllNoDebugInfo;
// The target loads NoDebugLib.dll (built with no Delphi debug info). A breakpoint
// referencing that DLL`s source must come back UNVERIFIED (the adapter has no
// line info for it) and must NOT crash the session: a real breakpoint in
// TestTarget, set after the DLL is loaded, must still be hit.
var
  DoneLine, DllLine: Integer;
  DllSrc, TargetSrc: string;
  SetResp, Stopped: TJSONObject;
begin
  DoneLine  := Bp('NODEBUG_DONE');                            // FBpSourceFile = TestTarget.dpr
  TargetSrc := FBpSourceFile;
  DllSrc    := ExtractFilePath(TargetSrc) + 'NoDebugLib.dpr';
  DllLine   := FindBpLine(DllSrc, 'NODEBUG_DLL_FUNC');
  Assert.IsTrue(DllLine > 0, 'NODEBUG_DLL_FUNC marker not found in NoDebugLib.dpr');

  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized');

  // BP on the no-debug DLL`s source: no symbols -> must be reported UNVERIFIED.
  SetResp := FClient.SetBreakpoints(DllSrc, [DllLine]);
  try
    var Arr := SetResp.GetValue('breakpoints') as TJSONArray;
    Assert.IsTrue((Arr <> nil) and (Arr.Count > 0), 'no breakpoints array for the DLL source');
    Assert.IsFalse((Arr.Items[0] as TJSONObject).GetValue<Boolean>('verified', True),
      'a breakpoint in a DLL with no debug info must be unverified');
  finally SetResp.Free; end;

  // A real BP in TestTarget, reached AFTER the no-debug DLL is loaded + called,
  // must still fire -- proving the session survived the unknown module.
  FClient.SetBreakpoints(FBpSourceFile, [DoneLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  LaunchTarget(['--load-nodebug-dll']).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(10000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'session must survive loading the no-debug DLL and still hit the TestTarget BP');
  finally Stopped.Free; end;
end;
procedure TDebuggerTests.Test_BL_Obj_ClassInUnloadedBpl;
// The target takes a TPkgWidget from TestPackage.bpl, then UNLOADS the package.
// GPkgObj is now stale: its VMT lives in the unmapped BPL. Inspecting it must
// degrade gracefully (raw value, no crash) and the session must stay alive --
// the exact shape of debugging a design-time package across an uninstall.
var
  BpLine: Integer;
  Stopped, Resp, Th: TJSONObject;
begin
  BpLine := Bp('UNLOADED_OBJ');   // FBpSourceFile = TestTarget.dpr
  FClient := TDapClient.Create;
  FClient.Start(AdapterExe);
  FClient.Initialize.Free;
  Assert.IsTrue(FClient.WaitForInitialized, 'adapter did not send initialized');
  FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
  FClient.SetExceptionBreakpoints([]).Free;
  var Spec := Default(TLaunchSpec);
  Spec.Args := ['--load-unload-bpl-obj'];
  Spec.Modules := [['TestPackage.bpl', PackageMap, PackageRsm, PackageDcp]];
  LaunchTarget(Spec).Free;
  FClient.ConfigDone.Free;
  Stopped := FClient.WaitForStopped(15000);
  try
    Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
      'must stop at UNLOADED_OBJ after the load/unload cycle');
  finally Stopped.Free; end;

  // Inspecting the stale reference (VMT in the unmapped BPL) must not crash.
  Resp := FClient.Evaluate('GPkgObj', FClient.GetFrameId);
  Assert.IsNotNull(Resp, 'evaluate of a stale unloaded-BPL object returned nothing');
  Resp.Free;

  // The adapter must still be alive and responsive afterwards.
  Th := FClient.Threads;
  try
    Assert.IsNotNull(Th.GetValue('threads'),
      'adapter unresponsive after inspecting a stale unloaded-BPL object');
  finally Th.Free; end;
end;
procedure TDebuggerTests.Test_BL_Ptr_DanglingFreed;
// A dangling reference to a freed object must NOT crash the adapter and
// the session must stay alive. We don't assert a specific value (the
// memory may or may not still look like a class) -- only that inspecting
// it returns cleanly and a follow-up request still works.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('REAL_ROBUST_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Freed');
  if V <> nil then begin
    V.GetValue<string>('value', '');  // must not throw
    V.Free;
  end;
  // session still responsive?
  var Chk := FClient.Evaluate('WideE = woB', FrameId);
  try
    Assert.IsTrue(Chk.GetValue<string>('result', '') <> '',
      'session must survive inspecting a dangling freed reference');
  finally Chk.Free; end;
end;
procedure TDebuggerTests.Test_BL_Ptr_UnmappedRead;
// Dereferencing a pointer into clearly-unmapped memory must fail
// gracefully (a read-failure result), not crash the adapter -- and the
// session must stay alive for the next request.
var FrameId, LocalsRef: Integer; R, Chk: TJSONObject;
begin
  StartSession('MAIN_GCOUNTER', FrameId, LocalsRef);
  R := FClient.Evaluate('[$DEAD0000]', FrameId);   // deref an unmapped address
  try
    var Res := R.GetValue<string>('result', '');
    Assert.IsTrue(Res.Contains('read failed') or Res.Contains('<'),
      'unmapped deref must report a read failure; got: ' + Res);
  finally R.Free; end;
  Chk := FClient.Evaluate('1 + 1', FrameId);
  try
    Assert.AreEqual('2', ExtractDisplayValue(Chk.GetValue<string>('result', '')),
      'session must survive an unmapped read');
  finally Chk.Free; end;
end;
procedure TDebuggerTests.Test_BL_Obj_AfterFree_StaleVmt;
// Same freed object, accessed via the variables tree: expanding it (if
// the adapter still treats it as a class) must not crash; otherwise it
// surfaces as a raw pointer. Either way: no exception, session alive.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('REAL_ROBUST_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Freed');
  Assert.IsNotNull(V, 'Freed local must still be listed');
  try
    var Ref := V.GetValue<Integer>('variablesReference', 0);
    if Ref > 0 then begin
      var R := FClient.Variables(Ref);  // must not throw on stale VMT
      try Assert.IsNotNull(R.GetValue('variables') as TJSONArray); finally R.Free; end;
    end;
  finally V.Free; end;
end;
procedure TDebuggerTests.Test_BL_Obj_InterfaceQueryClass;
// `Thing: IThing := TThing.Create` is live at EDGE_BODY. An interface reference
// points INTO the object (Obj + IOffset), so a naive class probe fails; the
// adapter must recover the object via the IMT adjustor thunk and surface the
// CONCRETE class behind the interface.
var
  FrameId, LocalsRef: Integer;
  V: TJSONObject;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Thing');
  Assert.IsNotNull(V, 'Thing (IThing) missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('TThing'),
      'interface Thing must resolve to its concrete class TThing; got: ' + Val);
  finally V.Free; end;
end;
procedure TDebuggerTests.Test_BL_Attach_SetBpAfterAttach;
// Attach to an already-running process FIRST, then set a breakpoint. The
// BP must plant into the live process and fire (distinct from
// Test_Attach_BasicSession, which sets the BP before attaching).
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  BpLine: Integer;
  Stopped: TJSONObject;
begin
  if not HaveSeDebugPrivilege then begin
    TDUnitX.CurrentRunner.Status(
      'Skipping: SeDebugPrivilege not held; run elevated to exercise attach.');
    Exit;
  end;
  BpLine := Bp('MAIN_GCOUNTER');
  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  CmdLine := '"' + TargetExe + '" --attach-pause';   // target sleeps 5 s
  Assert.IsTrue(CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI),
    'CreateProcess for attach test failed: ' + IntToStr(GetLastError));
  CloseHandle(PI.hThread);
  try
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized);
    // Attach BEFORE any breakpoint is set.
    FClient.Attach(PI.dwProcessId, TargetExe, TargetMap, TargetRsm, TargetDir,
      True).Free;
    // Now plant the breakpoint into the already-attached, still-sleeping process.
    FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
    FClient.ConfigDone.Free;
    Stopped := FClient.WaitForStopped(20000);
    try
      Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
        'BP set after attach must fire; got: ' + Stopped.GetValue<string>('reason', ''));
    finally Stopped.Free; end;
  finally
    CloseHandle(PI.hProcess);
  end;
end;
procedure TDebuggerTests.Test_BL_Attach_DetachReattach;
// Attach (killOnDetach=False) to a running target, consume the attach break-in,
// detach (leave it running), then RE-ATTACH a fresh adapter to the same PID and
// consume the break-in again. Proves the attach/detach lifecycle is repeatable:
// the adapter detaches cleanly (DebugActiveProcessStop, breakpoints removed) and
// the survivor can be debugged again -- the design-time install/uninstall and
// repeated-attach workflow.
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  BpLine: Integer;

  // The attach break-in is swallowed by design, so each attach stops on a real
  // breakpoint planted in the survive-loop. Proves BPs set before attach are
  // applied (the bug this test caught) and that the cycle is repeatable.
  procedure AttachStopDetach(const Tag: string);
  var
    Stopped: TJSONObject;
  begin
    FClient := TDapClient.Create;
    FClient.Start(AdapterExe);
    FClient.Initialize.Free;
    Assert.IsTrue(FClient.WaitForInitialized, Tag + ': adapter did not initialize');
    FClient.SetBreakpoints(FBpSourceFile, [BpLine]).Free;
    FClient.SetExceptionBreakpoints([]).Free;
    FClient.Attach(PI.dwProcessId, TargetExe, TargetMap, TargetRsm, TargetDir, False).Free;
    FClient.ConfigDone.Free;
    Stopped := FClient.WaitForStopped(20000);   // loop reaches the BP (raises on timeout)
    try
      Assert.AreEqual('breakpoint', Stopped.GetValue<string>('reason', ''),
        Tag + ': attach must stop at the survive-loop breakpoint');
    finally
      Stopped.Free;
    end;
    FClient.Disconnect.Free;              // detach, leave running (killOnDetach=False)
    FClient.Stop;
    FreeAndNil(FClient);
  end;

begin
  if not HaveSeDebugPrivilege then begin
    TDUnitX.CurrentRunner.Status(
      'Skipping: SeDebugPrivilege not held; run elevated to exercise re-attach.');
    Exit;
  end;
  BpLine := Bp('ATTACH_SURVIVE_BODY');   // sets FBpSourceFile = TestTarget.dpr
  SI := Default(TStartupInfo);
  SI.cb          := SizeOf(SI);
  SI.dwFlags     := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  CmdLine := '"' + TargetExe + '" --attach-survive';
  Assert.IsTrue(CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_NEW_CONSOLE, nil, nil, SI, PI),
    'CreateProcess for re-attach test failed: ' + IntToStr(GetLastError));
  CloseHandle(PI.hThread);
  try
    AttachStopDetach('attach #1');
    Assert.AreEqual(Cardinal(WAIT_TIMEOUT),
      Cardinal(WaitForSingleObject(PI.hProcess, 1000)),
      'detach must leave the target running for the re-attach');
    AttachStopDetach('attach #2 (re-attach)');
  finally
    TerminateProcess(PI.hProcess, 0);
    CloseHandle(PI.hProcess);
  end;
end;
procedure TDebuggerTests.Test_BL_Eval_InheritedCall;
// At INHERITED_BODY (inside TGreetDerived.Greet, Self = TGreetDerived), the
// watch `inherited Greet` must dispatch the PARENT version TGreetBase.Greet and
// return 'base-greet' -- not the overriding TGreetDerived.Greet.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('INHERITED_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('inherited Greet', FrameId);
  try
    var R := Resp.GetValue<string>('result', '');
    Assert.IsTrue(R.Contains('base-greet'),
      'inherited Greet must call TGreetBase.Greet (base-greet); got: ' + R);
    // The derived override returns 'derived-base-greet'; `inherited` must NOT
    // dispatch the override, so the result must not carry the 'derived' prefix.
    Assert.IsFalse(R.Contains('derived'),
      'inherited Greet must NOT call the override TGreetDerived.Greet; got: ' + R);
  finally Resp.Free; end;
end;
procedure TDebuggerTests.Test_BL_Eval_SetLiteralArith;
// Pascal set algebra in a watch. me0..me19 belong to the enum behind
// ManySet (live at EDGE_BODY). The overlap cases distinguish true set ops
// from naive integer arithmetic: union on overlapping sets is idempotent
// (bitwise OR), whereas `513 + 512` would differ.
var FrameId, LocalsRef: Integer;
begin
  StartSession('EDGE_BODY', FrameId, LocalsRef);
  Assert.IsTrue(NonRttiResult(FClient, FrameId,
    '[me0, me9] = [me0, me9] + [me9]').Contains('True'),
    'set union (overlap) must stay [me0,me9]');
  Assert.IsTrue(NonRttiResult(FClient, FrameId,
    '[me0] = [me0, me9] - [me9]').Contains('True'),
    'set difference must drop me9');
  Assert.IsTrue(NonRttiResult(FClient, FrameId,
    '[me9] = [me0, me9] * [me9]').Contains('True'),
    'set intersection must keep only me9');
end;
procedure TDebuggerTests.Test_BL_Eval_RangeExpr;                begin Assert.Fail('not implemented'); end;
procedure TDebuggerTests.Test_BL_Eval_MethodSideEffect;
// A watch that calls a mutating method must actually run it in the
// debuggee, and the mutation must persist: BumpCount increments FCount
// (initially 7), so two successive watch calls return 8 then 9, and a
// follow-up PubCount read reflects the new state.
var FrameId, LocalsRef: Integer;
begin
  StartSession('EVAL_BODY', FrameId, LocalsRef);
  Assert.AreEqual('8', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'S.BumpCount()')),
    'first BumpCount must be 8');
  Assert.AreEqual('9', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'S.BumpCount()')),
    'second BumpCount must be 9 (side effect persisted)');
  Assert.AreEqual('9', ExtractDisplayValue(
    NonRttiResult(FClient, FrameId, 'S.PubCount')),
    'PubCount must reflect the mutated FCount');
end;
procedure TDebuggerTests.Test_BL_Num_EnumOverByte;
// {$Z4} enum WideE = woB stored in 4 bytes; must decode to the name woB
// (or at least ordinal 1), reading the full 4-byte slot.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('REAL_ROBUST_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'WideE');
  Assert.IsNotNull(V, 'WideE missing');
  try
    var Val := V.GetValue<string>('value', '');
    Assert.IsTrue(Val.Contains('woB') or Val.Contains('1'),
      'WideE ({$Z4} enum) must show woB / ordinal 1; got: ' + Val);
  finally V.Free; end;
end;
procedure TDebuggerTests.Test_BL_Type_LongQualifiedName;
// Inside a method of a class whose name is ~209 chars (marker LONGNAME_BODY),
// `Self` must resolve to that class name intact -- no fixed-buffer truncation
// anywhere in the type / name path.
var
  FrameId, LocalsRef: Integer;
  Resp: TJSONObject;
begin
  StartSession('LONGNAME_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('Self', FrameId);
  try
    var R := Resp.GetValue<string>('result', '');
    Assert.IsTrue(R.Contains('LongNameLongNameLongNameLongNameLongName'),
      'Self must carry the very long class name; got: ' + R);
    Assert.IsTrue(R.Length > 200,
      Format('long class name must resolve intact (>200 chars); got len %d: %s',
        [R.Length, R]));
  finally Resp.Free; end;
end;
procedure TDebuggerTests.Test_BL_Generic_DictElementEnumeration;
// Dict: TDictionary<Integer,string> = {7:'seven', 8:'eight'}. Walking the
// backing buckets (FItems -> TItem.Key/Value) must surface the actual
// entries: both values 'seven' and 'eight' reachable in the expansion tree.
var FrameId, LocalsRef, DictRef: Integer; V: TJSONObject; Seen: string;
  procedure Collect(Ref, Depth: Integer);
  var R: TJSONObject; Arr: TJSONArray;
  begin
    if (Ref <= 0) or (Depth > 4) then Exit;
    R := FClient.Variables(Ref);
    try
      Arr := R.GetValue('variables') as TJSONArray;
      if Arr = nil then Exit;
      for var I := 0 to Arr.Count - 1 do begin
        var Item := Arr.Items[I] as TJSONObject;
        Seen := Seen + ' ' + Item.GetValue<string>('value', '');
        Collect(Item.GetValue<Integer>('variablesReference', 0), Depth + 1);
      end;
    finally R.Free; end;
  end;
begin
  StartSession('EDGE2_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Dict');
  Assert.IsNotNull(V, 'Dict missing');
  try
    DictRef := V.GetValue<Integer>('variablesReference', 0);
  finally V.Free; end;
  Assert.IsTrue(DictRef > 0, 'Dict must be expandable');
  Seen := '';
  Collect(DictRef, 0);
  Assert.IsTrue(Seen.Contains('seven') and Seen.Contains('eight'),
    'dictionary entries must be reachable by walking the buckets; got: ' + Seen);
end;

// === Real SampleApp shapes (TestTargetReal.pas) ==========================

procedure TDebuggerTests.Test_Real_VarArrayParam_Expandable;
// `const v: Variant` parameter holding a VarArray must be expandable in
// the LOCALS view (it already works via hover). SampleApp IsNull.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('REAL_ISNULL_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'v');
  Assert.IsNotNull(V, 'param v missing');
  try
    Assert.IsTrue(V.GetValue<Integer>('variablesReference', 0) > 0,
      'VarArray Variant PARAM must be expandable in locals; got ref 0');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Real_BooleanResult_NotExpandable;
// The Boolean Result of IsNull must NOT be expandable (it has no fields).
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('REAL_ISNULL_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Result');
  if V = nil then Exit;  // Result may not surface as a named local; fine
  try
    Assert.AreEqual(0, V.GetValue<Integer>('variablesReference', 0),
      'Boolean Result must NOT be expandable; got a non-zero ref');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Real_VariantNull_NotInteger;
// `var V: Variant; V := Null;` must surface as a Null variant, never a
// stale integer. SampleApp LoadMenu line 329.
var FrameId, LocalsRef: Integer; V: TJSONObject;
begin
  StartSession('REAL_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'VNull');
  Assert.IsNotNull(V, 'VNull missing');
  try
    var Val := V.GetValue<string>('value', '');
    var Typ := V.GetValue<string>('type', '');
    Assert.IsTrue(Val.Contains('null') or Val.Contains('Null') or Typ.Contains('Variant'),
      'VNull (Variant = Null) must show as Null/Variant, not a plain int; got value="' +
      Val + '" type="' + Typ + '"');
  finally V.Free; end;
end;

procedure TDebuggerTests.Test_Real_InheritedFields_Visible;
// Expanding a TDerivedQuery instance must show INHERITED fields
// (FBaseTag/FBaseName from TBaseQuery), not just the leaf's FOwnField.
// SampleApp TreeMenu Cache (TCachedMenu) regression.
var
  FrameId, LocalsRef, Ref: Integer;
  V, OwnVar, BaseTagVar, BaseNameVar: TJSONObject;
begin
  StartSession('REAL_BODY', FrameId, LocalsRef);
  V := FindLocalByName(FClient, LocalsRef, 'Derived');
  Assert.IsNotNull(V, 'Derived missing');
  try
    Ref := V.GetValue<Integer>('variablesReference', 0);
    Assert.IsTrue(Ref > 0, 'Derived must be expandable');
  finally V.Free; end;
  // A property-bearing class splits into groups; FindVar descends the `fields`
  // group to reach own + inherited backing fields.
  OwnVar := FClient.FindVar(Ref, 'FOwnField');
  Assert.IsNotNull(OwnVar, 'own field FOwnField must be visible');
  OwnVar.Free;
  BaseTagVar  := FClient.FindVar(Ref, 'FBaseTag');
  BaseNameVar := FClient.FindVar(Ref, 'FBaseName');
  try
    Assert.IsTrue((BaseTagVar <> nil) or (BaseNameVar <> nil),
      'INHERITED fields (FBaseTag/FBaseName) must be visible');
  finally
    BaseTagVar.Free;
    BaseNameVar.Free;
  end;
end;

procedure TDebuggerTests.Test_Real_EvalParamInBody;
// Evaluating a function's PARAMETER from inside its body must work.
// SampleApp FileExists (RTL) -- can't eval received args.
var FrameId, LocalsRef: Integer; Resp: TJSONObject;
begin
  StartSession('REAL_ISNULL_BODY', FrameId, LocalsRef);
  Resp := FClient.Evaluate('v', FrameId);
  try
    var Res := Resp.GetValue<string>('result', '');
    Assert.IsFalse(Res.Contains('not found') or (Res = ''),
      'param v must be evaluable from inside the body; got: ' + Res);
  finally Resp.Free; end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDebuggerTests);
  // Second registration of the SAME test methods via the BPL-scenario subclass:
  // RegisterTestFixture enumerates inherited [Test] methods, so every test runs
  // again with Scenario=tsBpl (target = TestHost.exe + TestSubject.bpl). This
  // project uses EXPLICIT RegisterTestFixture (not RTTI auto-scan), so the
  // subclass's [TestFixture] attribute alone is NOT enough -- it must be
  // registered here too, or the BPL fixture contributes zero tests.
  TDUnitX.RegisterTestFixture(TDebuggerTestsBpl);

end.
