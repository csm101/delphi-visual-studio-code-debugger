# Test Catalog

Living index of what the Debugger Tests cover and what is still uncovered.

Status legend:
- `[x]` covered by an automated test in `DebuggerTests.pas`
- `[ ]` known gap -- add a TestTarget proc + DUnitX assertion before fixing
       any bug in this area
- `[~]` partially covered (some aspect works, an edge case is missing)

Update this catalog in the same change set as the test or fix.

**Backlog as registered tests:** every edge case brainstormed is now a
named DUnitX test. Runnable ones are `[Test]` (green) or
`[Test] [Ignore('TODO-RED: ...')]` (real bug, root cause in the message).
Not-yet-feasible ones are `Test_BL_*` stubs: `[Ignore('TODO: ...')]` with
an `Assert.Fail('not implemented')` body, so removing `[Ignore]` forces a
real implementation. Run summary shows the live count
(`Tests Ignored : N`). Nothing is tracked only in prose.

---

## A. Local variable type display

### A.1 Primitives
- [x] Integer / LongInt / Int32 (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`,
      `Test_Types_ZeroInt_DisplaysZeroNotEmpty`)
- [x] Cardinal / UInt32 (`PrimitiveLocals_DisplayTheirValueAndDeclaredType` -- the fixture
      value is above MaxInt, so a signed read shows up as a negative). Ticked for
      years while NO fixture anywhere declared a Cardinal local
- [x] Byte / ShortInt (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`; ShortInt is
      negative in the fixture). No ShortInt local existed anywhere before it
- [x] Word / SmallInt (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`,
      `Test_Edge_NegSmallInt_Signed`)
- [x] Int64 / UInt64 (`PrimitiveLocals_DisplayTheirValueAndDeclaredType` -- the UInt64
      value is above MaxInt64, so a signed read wraps negative)
- [x] Single / Double / Currency (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`,
      `Test_Types_Single_Local_NotUpgradedToDateAlias`). No Currency local was
      readable by any test before it
- [x] Boolean (1-byte) (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`)
- [x] ByteBool / WordBool / LongBool (TD32 $0031 named-subrange NameIdx
      pickup -> declared alias preserved -> True/False display)
      (`Test_Types_ByteBool_True`, `Test_Types_WordBool_True`,
      `Test_Types_LongBool_True`)
- [x] AnsiChar / Char (WideChar) (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`).
      No AnsiChar local existed anywhere before it
- [x] AnsiString / UnicodeString (`PrimitiveLocals_DisplayTheirValueAndDeclaredType`). NOTE: an
      `AnsiString` local is currently REPORTED as `RawByteString` and so gets
      the hex/ascii rendering meant for that type -- TD32 tag `\` carries no
      public type name. Value and kind are right; see KNOWN_UNKNOWNS.md
- [x] ShortString (TD32 $0033 named-array NameIdx pickup + inline
      length-prefixed value decode) (`Test_Types_ShortString_Content`)
- [x] WideString (TD32 $0039 managed-type tag) (`Test_Types_WideString_Content`)
- [ ] RawByteString / UTF8String (covered for property GET; local display missing)
- [x] TDateTime (Double-backed) (`Test_Types_TDateTime_Local_NotPlainFloat`,
      `Test_Types_TDate_Local_RendersAsDate`, `Test_Types_TTime_Local_RendersAsTime`)
- [x] TGUID (16-byte record literal) (`Test_Types_TGUID_Display`)
- [ ] PChar / PAnsiChar / PWideChar with non-string content
- [x] PChar with string content (`^Char` alias) -- decoded via
      FormatStringByPointer extension (`Test_Types_PChar_StringContent`)
- [x] **Critical regression guard**: Integer = 1 next to zeroed
      neighbour locals must surface as Integer, not as varNull / TVarRec.
      Now enforced by `Test_Types_TrickyOne_NotMisDecodedAsVariant`
      (TVarRec augment denylist + Variant pattern slot-size guard).

### A.2 Enums and sets
- [x] Enum literal value display (`wmRunning`) (`Test_Types_Enum_DisplaysName`)
- [x] Set value display (`[wmRunning, wmIdle]`)
      (`Test_Types_NonEmptySet_Display`, `Test_Types_EmptySet_Display`)
- [x] Enum whose ordinal exceeds byte (`Test_Types_BigEnum_DisplaysName`)
- [ ] Set whose element enum lives in a different unit
- [x] Non-trivial set decode (`Test_Types_NonEmptySet_Display`)
- [x] Empty set displays as `[]` (`Test_Types_EmptySet_Display`)
- [ ] Set with `..` ranges in source (compiler may expand differently)

### A.3 Records
- [x] Flat record fields (`Test_Types_PackedRecord_FieldsVisible`,
      `RecordLocals_ShowTheirTypeOnBothBitnesses`)
- [x] Nested record field expansion (`ExpandVariable_NestedRecord`,
      `Test_E2_NestedRecord3Deep`)
- [x] Packed record locals-view expansion (`Test_Types_PackedRecord_FieldsVisible`)
- [x] Managed-field record locals-view expansion
      (`Test_Types_ManagedRecord_FieldsVisible`)
- [ ] Record with methods (modern Delphi)
- [ ] Record with class operators (body steppable -- partial)
- [ ] Anonymous record `record A,B: Integer end`

### A.4 Arrays
- [x] Static array `array[0..N] of T` (`Test_E2_MultiDimStatic_Element`,
      `EvaluateReportsDeclaredTypesOnBothBitnesses`)
- [x] Dynamic array `TArray<T>` / `array of T` (Integer)
      (`ExpandVariable_DynArray_Elements`)
- [x] Dynamic array of class/record as a FIELD (RTTI TypeInfo path, e.g.
      MRec.Tags) -- expands via ExpandDynArray
      (`DynArrayRendering_NeedsAStatedKindOnBothBitnesses`)
- [x] Dynamic array of records as a LOCAL
      (`Test_Coll_DynArrayOfRecord_ElementFields`) -- ekDynArrayNamed:
      validates Win64 dyn-array header (RefCnt@-12, Length@-8), element
      stride from ITypeSizeProvider, per-element ekRsmMembers children.
- [x] Dynamic array of class instances as a LOCAL
      (`Test_Coll_DynArrayOfClass_ElementInstance`) -- same path,
      class elements dereferenced + labelled.
- [ ] Multi-dim static array -- display + `[i,j]` index. BLOCKED: TD32 types
      a static array as its element ("Integer"), dims lost (needs LF_ARRAY).
- [x] Multi-dim dynamic array expand (`Test_E2_MultiDimDynamic_Expand`)
- [x] A dynamic array longer than the 1024-child cap SAYS it was truncated,
      with the true element count (`ExpandVariable_LongDynArray_SaysItWasTruncated`;
      fixture `RunBigDynArrayProbe`, marker `BIG_DYNARRAY_BODY`). Before this the
      list simply stopped, so 1024 of 50000 rendered exactly like an array of 1024
- [ ] Open array parameter (`array of const`)
- [x] Open array parameter `array of T` -- `A[i]` indexing in a watch
      (`Test_E2_OpenArrayParam_Element`; `^Element` base, DerefPtr)

### A.5 Classes
- [x] Class instance, declared and runtime type match
      (`EvaluateNamesTheClassTheObjectIsOnBothBitnesses`,
      `EvaluateReportsDeclaredTypesOnBothBitnesses`)
- [x] Class instance, derived shown as declared not base
      (`EvaluateNamesTheClassTheObjectIsOnBothBitnesses`,
      `Test_InheritedMethod_CalledOnDerivedInstance`)
- [x] Null class reference displays as `nil` (`Test_Types_ClassRef_NilDisplaysAsNil`,
      `Test_NilClassReference_NotExpandable`)
- [x] Self visible in nested proc of class method
      (`Test_NestedClassMethod_AllThreeBugs`)
- [ ] Static class method (no Self)
- [ ] Class constructor (`class constructor` body)
- [ ] Abstract class (no concrete VMT)
- [ ] Anonymous (non-named) class created via `class procedure`
- [x] Generic class instance `TList<Integer>` -- elements reachable by
      drilling GenList -> FItems -> [0..2] (`Test_Types_GenericList_EnumeratesElements`)
- [x] `TDictionary<K,V>` element enumeration (buckets) -- entries reachable
      by walking Dict -> FItems -> TItem.Key/Value
      (`Test_BL_Generic_DictElementEnumeration`)
- [x] Interfaced class (refcounted) -- live non-nil + field reach
      (`Test_Coll_InterfacedClass_FieldVisible`)
- [x] Class reference value `class of TBar` (`Test_Types_ClassRef_*`)

### A.6 Pointers
- [x] `^Integer` displays through pointer-to-primitive recovery
      (`Test_Types_PtrPrimitive_DerefMatches`)
- [x] `^TClass` displays as class (nil for 0, $addr (RuntimeClassName) for
      non-zero) (`Test_Types_ClassRef_AssignedShowsClassName`,
      `Test_Types_ClassRef_NilDisplaysAsNil`)
- [x] `^TRecord` (typed pointer-to-record) display
      (`Test_Types_PtrRecord_Expandable`)
- [x] Untyped `Pointer` display (`Test_Types_UntypedPointer_HexDisplay`)
- [x] Pointer deref `P^` in watch (`Test_Types_PtrPrimitive_DerefMatches`)
- [x] PChar string content -- see A.1 (`Test_Types_PChar_StringContent`)

### A.7 Variants
- [x] varEmpty (`Test_Variant_Empty_DisplaysAngleBracketsEmpty`)
- [x] varNull (`Test_Variant_Null_DisplaysAngleBracketsNull`)
- [x] varInteger (`Test_Variant_Integer_DisplaysLabelAndValue`)
- [x] varBoolean (`Test_Variant_Boolean_DisplaysTrue`)
- [x] varDouble (`Test_Variant_Double_DisplaysValue`)
- [x] varInt64 (`Test_Variant_Int64_DisplaysValue`)
- [x] varString / varUString (`Test_Variant_String_DisplaysQuoted`)
- [x] varDate (`Test_Variant_Date_DisplaysIsoDate`)
- [x] VarArray 1D / 2D shape and expansion (hover/watch + locals view)
      (`Test_Variant_VarArray1D_DisplaysShape`, `Test_Variant_VarArray1D_Expansion`,
      `Test_Variant_VarArray1D_LocalsViewExpandable`,
      `Test_Variant_VarArray2D_DisplaysShape`, `Test_Variant_VarArray2D_Expansion`)
- [x] Variant in nested proc auto-decoded (`Test_Eval_NestedProcVariant_AutoDecode`,
      `Test_Eval_NestedProcVariant_ExplicitCast`, `Test_NestedProcInlineVariant_Null`)
- [x] Const Variant parameter deref through pointer
      (`Test_Eval_ConstVariantParam_DerefsThroughPointer`)
- [x] Variant parameter mis-tagged as small int recovered
      (`Test_Real_VariantNull_NotInteger`, `VariantAutoDetect_DoublePattern_Accepted`,
      `VariantAutoDetect_Int64Pattern_Rejected`)
- [x] **regression**: Integer = 1 next to zeroed neighbours must NOT trigger
      varNull recovery (`Test_Types_TrickyOne_NotMisDecodedAsVariant`)
- [ ] varByRef (Variant containing a reference to another Variant)
- [ ] OleVariant
- [ ] varDispatch (IDispatch)

### A.8 Other reference types
- [x] Interface variable LIVE: `Test_Types_Interface_Live_HasClassName`
- [x] Interface NIL: `Test_Types_Interface_Nil_DisplaysAsNil`
- [x] Method pointer NIL: `Test_Types_MethodPointer_Nil` (TD32 $0034 ->
      `procedure of object` label -> nil-shape display)
- [x] Method pointer LIVE / anonymous proc (partial -- pending real call
      dispatch) (`Test_Types_AnonProc_Assigned`)
- [ ] Anonymous method reference: `reference to procedure`
- [ ] TextFile / typed File (legacy)

---

## B. Parameter passing

- [x] Value param (Integer, String, Variant, Const Variant, Var Variant)
      (`BreakpointOnBeginLine_ReportsPassedParameters`, `Test_ConstParam_ReadsValue`,
      `Test_Eval_ConstVariantParam_DerefsThroughPointer`, `Test_ClosureParam_Mixed`)
- [x] Var param `var X: Integer` (modifies caller's slot)
      (`Test_VarParam_InCompute`, `VarParameters_ShowTheValueOnBothBitnesses`,
      `Test_OutParam_AfterAssignment_ReadsBack`)
- [x] Out param: `Test_OutParam_AfterAssignment_ReadsBack` (TD32 `^T`
      promoted to lkVarParam; deref + width-correct read)
- [x] Const param: `Test_ConstParam_ReadsValue`
- [x] Default parameter: `Test_DefaultParam_TakesDefaultValue`
- [ ] Open array parameter (`array of const`)
- [ ] Untyped var parameter (`var X` without type)

---

## C. Frame layout and call kinds

- [x] Every frame carries its own ARGUMENT VALUES, on both bitnesses
      (`CallStack_Frames_CarryTheirArgumentValues`). Asserted on the recursion
      fixture, where every frame is the same routine and only the argument tells
      them apart — so a frame handed the TOP frame's locals (what a missing
      frame switch looks like, and it reads as plausible) fails the test
- [x] A routine's DECLARED parameter list decodes from its own signature record,
      for a free function and for a method with its implicit Self reported
      separately (`ProcSignature_FreeFunction_ReportsDeclaredParams`,
      `ProcSignature_Method_ReportsSelfSeparately`)
- [ ] The call stack's fallback to that declared list, for a frame whose symbols
      describe no parameters, has NO fixture: `{$LOCALSYMBOLS OFF}` was tried and
      does not remove the BPREL32 records (measured -- the parameters were still
      there), so a "types but no locals" module cannot be produced on demand
      here. The decoder it depends on is covered by the two tests above; the
      wiring is exercised only against real modules built without local symbols
- [~] Which symbols count as parameters comes from the declared parameter count
      plus declaration order (`MarkParametersByDeclaredCount`). Covered for
      free procs and methods; a routine whose symbol count disagrees with its
      signature is deliberately left unclassified and has no fixture
- [x] Top-level free proc (`Test_Eval_FreeProc_IntegerReturn`,
      `Test_Eval_FreeProc_StringReturn`)
- [x] Class method (Self visible) (`StepInto_Method_ReportsSpilledSelfAndParams`,
      `Test_Eval_ImplicitSelf_LocalShadowsField`)
- [x] Class function with Result (`Test_Real_BooleanResult_NotExpandable`,
      `Test_Eval_ParameterlessMethod_NoParens_IsCalled`)
- [x] Constructor (`Test_StepInto_Ctor`, `Test_ClassCtor_ParamsVisible`,
      `StoppedInCtorPreamble_StackStillReachesTheCallerOnBothBitnesses`)
- [x] Destructor side-effect verified -- BP in a `Destroy` body: it fires, the
      frame is named as the destructor, the dying object's field still reads, and
      the body demonstrably RAN (`Breakpoint_InDestructorBody_StopsAndTheBodyRuns`;
      fixture `TDtorProbe`/`RunDestructorProbe`, marker `DTOR_BODY`).
      Ticked for years while NO test planted a breakpoint in any destructor --
      the only destructor test in the suite demangled a NAME
- [x] Nested proc 1 level (`Test_NestedProcLocals`,
      `NestedProc_SeesTheParentScopeOnBothBitnesses`)
- [x] Nested proc inside class method (`TMenuRepro.LoadMenu.CreateNodes`)
      (`Test_NestedClassMethod_AllThreeBugs`, `Test_StackFrame_NestedProc_HasSourcePath`)
- [x] Nested proc inside nested proc (2 levels): own local,
      parent (`Mid.MidTag`), grandparent (`RunDeepNesting.OuterTag`).
      Multi-Z Itanium parser + NameToRva qualified-fallback wired.
      (`DeepNested_LocalsResolveAtDepth2`, `DeepNested_LocalsResolveAtExceptionStop`,
      `Test_Flow_Nest3_AllAncestorsVisible`)
- [ ] Anonymous method body invoked via `TThread.CreateAnonymousThread`
- [ ] Generic method body
- [x] Property setter body: `Test_PropertySetterBody_NewValueVisible`
- [x] Operator overload body: `Test_OperatorBody_StoppableAndArgsVisible`
- [ ] Class constructor body
- [ ] Initialization / Finalization sections

---

## D. Expression evaluation (watch / hover)

> Every `[x]` below NAMES the test that backs it. A ticked box with no test name
> is a claim, not coverage, and it is worse than an empty one: nobody writes a
> test for something the catalogue says is already covered. Audited line by line
> in 2026-08 after `[x] Boolean ops, comparisons, precedence` turned out to have
> nothing behind it at all.

- [x] Identifier — local, global, implicit `Self.X`
      (`Test_Eval_ImplicitSelf_LocalShadowsField`,
      `UnitGlobals_ResolveOnBothBitnesses`)
- [x] Field access `a.b.c` (`Test_E2_NestedRecord3Deep` — `Outer.Mid.Inner.X`,
      `Test_E2_LongDotChain`)
- [x] Indexed property `a.Level[0]` (`Test_NestedClassMethod_AllThreeBugs`,
      `Test_IndexedProperty_TwoMixedIndices_ExplicitName`)
- [x] Method call — no args, with args, chained (`Test_Eval_Method_Chained` —
      `W.GetSelf().Mult(3, 5)`, `Test_InheritedMethod_CalledOnDerivedInstance`)
- [x] **The compiler is the oracle.** 34 expressions are assigned to Boolean
      locals in `RunExprOracle` (marker `EXPR_ORACLE`), so DCC64 computes the
      expected answer; the test evaluates the SAME source text through the
      debugger and asserts they agree
      (`ExprOracle_DebuggerAgreesWithTheCompiler`). Covers `and` `or` `xor`
      `not` `div` `mod` `shl` `shr` `/`, all six relational operators, string
      comparison and concatenation, `Char` comparison, `nil` comparison,
      ordinal and class casts, `as`, mixed int/float arithmetic, enum `=` and
      `in`, and the precedence combinations between them. The table asserts both
      outcomes are present, so an evaluator answering True to everything cannot
      pass. Both negative controls were RUN, not assumed: mispairing one row
      fails naming the disagreement, and disabling the text-comparison route
      turns exactly the six string rows red.
      Written after an audit found that, of 232 expressions the suite evaluated,
      NONE contained `and` `or` `xor` `not` `div` `mod` `shl` `shr` `<>` `<` `>`
      `<=` `>=` and exactly one contained `=` -- while this line read
      "[x] Boolean ops, comparisons, precedence, unary minus". A hand-written
      assertion is worth only as much as its author's reading of the language,
      and a wrong reading produces an evaluator and an assertion that agree with
      each other and not with Delphi. Add a form here rather than an
      `Assert.AreEqual`: one line in the fixture, one row in the table.
- [x] Boolean ops, comparisons, precedence, unary minus
      (`ExprOracle_DebuggerAgreesWithTheCompiler`,
      `ExprSemantics_OperatorPrecedence_MatchesDelphi`)
- [x] DELPHI operator precedence: `and` with `*`, `or`/`xor` with `+`, both
      tighter than any comparison, so `Flags and MASK = 0` groups as the source
      does and the C-like `a > 1 and b < 2` no longer parses
      (`ExprSemantics_OperatorPrecedence_MatchesDelphi`)
- [x] Arithmetic with an int operand and a float operand, `div`, `mod`
      (`ExprOracle_...` — `Flags + 1.5 = 16.5`, `Flags * 1.0 = 15.0`,
      `Flags div 4 = 3`, `Flags mod 4 = 3`, `Flags / 2 = 7.5`).
      Was ticked with nothing behind it: `div` and `mod` had never been
      evaluated, and the only "mix" was int-with-int through `/`
- [x] String concat (`ExprOracle_...` — `Greeting + '!' = 'Hello!'`, and
      `Blank + Greeting = Greeting` where one side is a nil string handle).
      Was ticked with nothing behind it: NO evaluated expression in the suite
      had ever concatenated two strings
- [x] String COMPARISON compares characters, not heap pointers: literal on
      either side, two equal strings in different allocations, `AnsiString` vs
      `string`, empty string, ordering, `Char` vs a one-character literal, and a
      refusal when the other operand is not text
      (`ExprSemantics_StringComparison_ComparesCharacters`)
- [x] Intrinsics beyond the original five -- `Assigned` `Pred` `Succ` `Abs`
      `Chr` `Trunc` `Round` `Int` `Copy` `Pos` `UpperCase` `LowerCase` -- and an
      UNIMPLEMENTED intrinsic refused by name with the reason rather than as an
      unresolved symbol (`ExprSemantics_Intrinsics_EvaluateOrExplain`)
- [x] Pascal literal forms: `#65` / `#$41`, literal runs (`'a'#13#10'b'`),
      exponent floats, and the leading-dot float refused by name
      (`ExprSemantics_Literals_FollowPascal`)
- [x] Parser recursion is bounded: a 400-deep parenthesis nest is refused with
      the reason and the session still evaluates afterwards
      (`ExprSemantics_DeepNesting_IsRefused_NotACrash`)
- [x] nil compare (`ExprOracle_...` — `Absent = nil`, `Present <> nil`).
      Was ticked with nothing behind it: `nil` appeared in no evaluated
      expression anywhere in the suite
- [x] Cast — `Integer(x)` ordinal, class cast, `TObject` upcast
      (`ExprOracle_...` — `Integer(Initial) = 72`,
      `TObject(Present) <> nil`; `Test_UsesScope_Cast_PicksUsedUnit` —
      `TDup(DupInst).Tag()`). Only the class cast had a test
- [x] `is` and `as` (`Test_UsesScope_Cast_PicksUsedUnit` — `DupInst is TDup`;
      `ExprOracle_...` — `(Present as TWidget).FValue = 1`).
      `as` had never been evaluated
- [x] Length, High, Low, SizeOf, Ord
      (`ArrayBounds_AreEnforcedOnBothBitnesses`,
      `RecordArrayStride_IsTheRecordWidthOnBothBitnesses`,
      `Test_UsesScope_TypeSize_PicksUsedUnit`,
      `NestedTypeNames_ResolveOnBothBitnesses`)
- [ ] @ address-of operator on locals
- [x] Pointer dereference `P^`: `Test_Types_PtrPrimitive_DerefMatches`
- [x] Set algebra `[a] + [b]` union, `-` difference, `*` intersection
      (`Test_BL_Eval_SetLiteralArith`)
- [x] In: `wmRunning in S` (`NestedTypeNames_ResolveOnBothBitnesses` —
      `Red in Cols`; `ExprOracle_...` — `wmRunning in Modes`)
- [x] Method call with a side effect persists across evals
      (`Test_BL_Eval_MethodSideEffect`)
- [x] Deref of unmapped memory fails gracefully, session survives
      (`Test_BL_Ptr_UnmappedRead`)
- [ ] Inherited call (`inherited Foo`)
- [x] Parameterless system funcs — `Now`, `Now()`
      (`Test_Eval_ParameterlessSystemFunc_Now`)
- [ ] Long dot chain `Self.A.B.C.D.E.F`
- [ ] Anonymous record literal
- [ ] Range expression `Low(T) .. High(T)`

---

## E. Stepping and breakpoints

- [x] Set / clear BP at source line (`Test_BL_Bp_FirstLine`,
      `Test_BL_Bp_DisabledThenEnabled`, `Test_BL_Bp_MultipleSameLine`)
- [x] Conditional BP (`Test_BP_Conditional`, `Breakpoint_Condition_True_Stops`,
      `Breakpoint_Condition_False_RunsToExit`)
- [x] A condition that CANNOT be evaluated stops and reports the reason, in the
      stop info and once on the console
      (`Breakpoint_UnevaluatableCondition_StopsAndSaysWhy`,
      `..._AnnouncedOncePerSession`)
- [x] Hit-count BP (`Test_BP_HitCount`, `Breakpoint_HitCount_SkipsEarlyHits`)
- [x] Log point BP (`Test_BP_LogPoint`, `Breakpoint_Logpoint_EmitsAndContinues`)
- [x] The verified-state event reports the transition DOWN as well as up: a
      source breakpoint in a package unit goes unverified when the package
      unloads (`Bpl_BreakpointGoesUnverified_WhenItsModuleUnloads`)
- [x] Step over (`Test_Step_Over_StaysInProc`,
      `Test_Step_Over_FromFunctionEntry_LandsNextLine`,
      `Test_Step_Over_NotTakenBranch_LandsNextLine`)
- [x] Step over a call that hits a BP in the callee -- BP wins
      (`Test_BL_Step_OverCallThatHitsBp`)
- [x] Step into ctor (`Test_StepInto_Ctor`)
- [x] Step into a no-debug-info (RTL) call degrades to step-over
      (`Test_Step_IntoNoDebugInfo_StepsOver`)
- [x] Step out from nested proc (`Test_StepOut_InnerToNested`,
      `Test_Step_Out_ReturnsToCaller`)
- [x] BP on the program's first executable line (`Test_BL_Bp_FirstLine`)
- [x] BP on a no-code/comment line handled cleanly; a real BP in the same
      request still fires (`Test_Bp_NoCodeLine_HandledCleanly`)
- [ ] Run to cursor
- [ ] Step into / over of a chained `try..finally`
- [ ] Step on `for var x := ... do` inline-var loop
- [ ] Restart session
- [x] Disconnect leaves the target running (attach + killOnDetach=False)
      (`Test_BL_Module_DetachLeavesRunning`)
- [x] Set a BP AFTER attaching to a live process
      (`Test_BL_Attach_SetBpAfterAttach`)
- [x] Terminate / run-to-completion clean shutdown
      (`Test_Lifecycle_RunToTermination`)

Hardware watchpoints share the single-step exception with the stepping engine,
so they are covered here rather than under their own heading. Both bitnesses,
`DebugSessionTests.pas`:

- [x] A step still completes with a watchpoint armed
      (`DataBp_StepCompletesWithWatchpointArmed` / `Win32_...`)
- [x] A hit inside a stepped-over call is not reported as the step completing
      (`DataBp_HitDuringStep_IsNotReportedAsStepCompletion` / `Win32_...`)
- [x] A hit on the stepped instruction itself (`DR6` = `BS` + slot bit) still
      completes the step
      (`DataBp_HitOnTheSteppedInstruction_StillCompletesTheStep` / `Win32_...`)
- [x] Slot exhaustion refuses the fifth watchpoint
      (`DataBp_SlotExhaustion_RefusesTheFifth`, x64 only)
- [x] A watchpoint replicated onto a thread created after it was set
      (`DataBp_ThreadCreatedAfterArm_StillTrips` / `Win32_...`)
- [x] Detach leaves the target unarmed
      (`DataBp_CleanDetach_LeavesTargetUnarmed`, x64 attach-based)
- [x] The stop names the WRITING thread, and old -> new -- session API
      (`DataBp_SessionApi_StopsWithOldNewAndThread` / `Win32_...`)
- [x] A BARE local name (no frame identity behind it) is refused by name, not
      treated as a stale address (`DataBp_SessionApi_RejectsLocalWithReason`).
      A local resolved through `GetDataBreakpointInfo` DOES arm -- see the
      frame-scoped block below.
- [x] Exhaustion reported PER SPEC through the session API, not failing the
      whole request (`DataBp_SessionApi_SlotExhaustion_PerSpecResults`)
- [x] `RemoveAllDataBreakpoints` genuinely clears the hardware slot
      (`DataBp_SessionApi_RemoveAll_StopsWatching`)
- [x] A watchpoint hit during a synthetic call aborts the call, like a raise
      (`DataBp_DuringSyntheticCall_AbortsEvaluation` / `Win32_...`)

**MCP tool surface** (increment 5 -- `set_data_breakpoint` / `list_data_breakpoints`
/ `remove_data_breakpoint` in `MCPDebugger\McpServer.pas`; DUnitX in
`DebuggerTests\McpE2ETests.pas`; the session/engine correctness above is not
re-proven here, only the tool wiring on top of it):

- [x] Stop payload names the address, the firing thread and old->new; `stopReason`
      is `"dataBreakpoint"`, not `"unknown"`
      (`DataBreakpoint_StopsWithAddressThreadOldNew`)
- [x] `access="readWrite"` arms and its result carries the no-read-only-watchpoint
      caveat (`DataBreakpoint_ReadWriteAccessCarriesCaveat`)
- [x] `access="read"` is refused outright as a tool error, explained, never
      silently downgraded to `readWrite`
      (`DataBreakpoint_ReadAccessRefusedExplicitly`)
- [x] A local is refused with a reason at the MCP surface too
      (`DataBreakpoint_LocalRefusedWithReason`)
- [x] Slot exhaustion surfaces the engine's own message (what already holds the
      slots), not a generic MCP failure
      (`DataBreakpoint_SlotExhaustion_RefusesFifthWithEngineMessage`)
- [x] `list_data_breakpoints` / `remove_data_breakpoint` round-trip with a STABLE
      MCP-owned id (independent of the session's own id, which is reassigned on
      every `SetDataBreakpoints` call), and removal genuinely frees the hardware
      slot -- the target runs PAST the watched write afterward
      (`DataBreakpoint_ListAndRemove_ClearsHardwareSlotForReal`)
**Frame-scoped watchpoints on LOCALS** (increment 6 --
`TDebugSession.GetDataBreakpointInfo` + `PruneStaleDataBreakpoints`; DUnitX in
`DebuggerTests\DebugSessionTests.pas`, over the `-run-databp-local` fixture.
Mirrored on Win32 because frame identity is EBP-based there and liveness runs
over the x86 walk):

- [x] The offered access types are exactly `write` + `readWrite`, with the
      no-read-only caveat, and the width comes from the declared type
      (`DataBp_Info_OffersWriteAndReadWriteButNeverRead`)
- [x] An unknown name is refused with a reason and carries no address
      (`DataBp_Info_RefusesUnknownNameWithReason`)
- [x] A watchpoint on a LOCAL fires and the stop names the variable (not the raw
      address) with old -> new (`DataBp_LocalWatch_FiresWithOldNew` / `Win32_...`)
- [x] Once the owning frame exits, the watchpoint is retired at the next stop,
      the removal is ANNOUNCED with the reason, the list is empty, and re-arming
      the same address+frame is refused
      (`DataBp_LocalWatch_GoesStaleWhenFrameExits` / `Win32_...`)

**DAP surface** (increment 6 -- `supportsDataBreakpoints`,
`dataBreakpointInfo`, `setDataBreakpoints`, and the `stopped` reason;
`DebuggerTests\DebuggerTests.pas`, so each runs in BOTH the mono and the BPL
fixture):

- [x] `supportsDataBreakpoints` is advertised -- without it VS Code never offers
      "Break on Value Change" and neither request is ever sent
      (`Test_DataBp_CapabilityAdvertised`)
- [x] info -> set -> continue stops with reason `"data breakpoint"` and a
      description naming the variable, old -> new and the thread; `accessTypes`
      never contains `read`; `canPersist` is false for a frame-scoped local
      (`Test_DataBp_LocalWrite_StopsWithOldNewAndThread`)
- [x] The stale flow end to end: announced on the Debug Console, removed, and
      re-arming the same `dataId` refused
      (`Test_DataBp_LocalGoesStale_RemovedAndAnnounced`)
- [x] `accessType:"read"` refused with a reason pointing at `readWrite`
      (`Test_DataBp_ReadAccessRefusedWithReason`)
- [x] The Registers scope is refused with its OWN reason, distinct from the
      expansion-handle one (`Test_DataBp_Info_RegisterScopeRefusedWithReason`)
- [ ] A watchpoint on a FIELD of an expanded object/record -- refused today (the
      expansion handle carries no address); see `DATA_BREAKPOINTS_PLAN.md`
- [ ] A `setDataBreakpoints` that arrives while the target is RUNNING is refused
      per entry rather than queued -- no fixture; the consequence (a watchpoint
      deleted mid-run stays armed until the next stop) is documented, not tested

---

## F. Exception handling

- [x] Pause on Delphi exception (filter on) (`Test_ExceptionFilter_DelphiOn_Stops`,
      `Test_ExceptionFilter_DelphiOff_Skips`)
- [x] Pause filtered by class match (`Test_ExceptionFilter_ClassMatch_Stops`,
      `Test_ExceptionFilter_ClassMismatch_Skips`)
- [x] Hover E.ClassName / E.Message inside on-clause
      (`Test_Hover_ExceptionInHandler_ClassName`,
      `Test_Hover_ExceptionInHandler_Message`)
- [x] Expand E in variables view (`Test_Hover_ExceptionInHandler_Expandable`,
      `Test_ExceptionLocal_ShowsExceptionObject`)
- [x] `on E:` alias inside a PROCEDURE stays a Locals row
      (`Test_ProcedureHandler_AliasStillListedInLocals`)
- [x] `on E:` alias inside the PROGRAM MAIN BLOCK is a Locals row -- the
      compiler puts it in a module-level static, not on the frame
      (`Test_MainBlockHandler_AliasListedInLocals`), holds the live object
      (`Test_MainBlockHandler_AliasMessageEvaluates`), and is usable as a
      breakpoint condition in both directions
      (`Test_MainBlockHandler_AliasGatesConditionalBreakpoint`,
      `Test_MainBlockHandler_AliasConditionFalse_NeverStops`)
- [x] That alias is scoped to its own clause: absent in a sibling bare
      `except` (`Test_MainBlockHandler_AliasAbsentInBareHandler`) and absent
      outside any handler (`Test_MainBlockHandler_AliasAbsentOutsideHandler`)
- [x] Exception class DEFINED in a BPL -- E.ClassName/E.Message in its
      handler via runtime VMT (`Test_BL_Exc_BplDefinedClass`)
- [x] Re-raise (bare `raise;`) -- second exception stop, propagation to the
      outer handler (`Test_BL_Exc_ReRaise`)
- [x] Bare `except .. end` (no `on`): the caught exception is a `$exception`
      Locals row and an evaluable expression for the WHOLE block, in a
      procedure, in a BPL and in a program main block
      (`Test_BareHandler_DollarExceptionInLocals`,
      `Test_BareHandler_DollarExceptionEvaluates`,
      `Test_MainBlockBareHandler_DollarExceptionInLocals`)
- [x] `$exception` and an `on E:` alias are mutually exclusive for one handler
      (`Test_MainBlockAliasedHandler_NoDollarExceptionBesideAlias`,
      `Test_MainBlockHandler_AliasAbsentInBareHandler`) and neither is offered
      outside a handler (`Test_MainBlock_NoDollarExceptionOutsideAnyHandler`)
- [x] x86 states the limitation instead of showing nothing, against an x64
      control at the same marker, and says it through `evaluate` too rather
      than only by omitting a row
      (`Win32_BareHandlerException_RefusesWithAReason`)
- [x] `$exception` is a real expression token: dotted expressions
      (`Test_DollarException_DottedExpressionEvaluates`), breakpoint conditions
      in both directions (`Test_DollarException_GatesConditionalBreakpoint`,
      `Test_DollarException_ConditionFalse_NeverStops`), and a stated reason
      instead of a parse error where no exception is in scope
      (`Test_DollarException_OutsideHandler_SaysWhyNotParseError`)
- [ ] Nested except / try-finally
- [x] OS exception (access violation) surfaces via the `av` filter
      (`Test_BL_Exc_OsAccessViolation`)
- [x] Native (non-Delphi) exception targeted by the `code` rule criterion:
      breaks on the raise the filters ignore and leaves the Delphi exception
      raised next to it alone (`Test_ExceptionRule_Code_MatchesNativeOnly`,
      `Test_ExceptionRule_Code_Decimal_BreaksOnNative`)
- [ ] Unhandled exception terminates session cleanly
- [x] Watch/hover that invokes a method which RAISES must not hang
      (`Test_BL_Exc_DuringEvaluate`) -- RunMethodCall aborts the synthetic
      call on raise/AV/second-chance and the session survives

### F.1 Exception-rule scopes (`ProjectExceptionRulesTests.pas`)

- [x] Where a project's two sidecar files live, for a `.dpr`, a `.dpk` and the
      `.dproj` the IDE actually reports, including a dotted project name
      (`SidecarPaths_SitNextToTheProject`, `SidecarPaths_AcceptDprDpkAndDproj`,
      `SidecarPaths_KeepADottedProjectName`,
      `SidecarPaths_EmptyProjectYieldsNoPath`)
- [x] A rule that exists only in `<Project>.ExceptionSettings.json` breaks where
      the filters would not (`SharedSidecar_BreaksWhereTheFiltersWouldNot`)
- [x] No `delphiProjectFile` -> the sidecars are not looked for at all, so an
      existing user's resolution is unchanged
      (`WithoutDelphiProjectFile_TheSidecarsAreNotRead`); an unexpanded `${...}`
      is ignored rather than used literally
      (`UnresolvedMacroInTheProjectPath_IsIgnored`)
- [x] Precedence proved in BOTH directions at every seam -- local over shared
      (`LocalSidecar_IgnoresWhereTheSharedSidecarBreaks`,
      `LocalSidecar_BreaksWhereTheSharedSidecarIgnores`), shared over the
      machine-wide file (`SharedSidecar_BreaksWhereTheMachineWideFileIgnores`,
      `SharedSidecar_IgnoresWhereTheMachineWideFileBreaks`)
- [x] A non-matching sidecar rule does not shadow the machine-wide file's rules
      (`TheMachineWideFileStillDecidesWhatNoSidecarMatches`)
- [x] The scope that was REMOVED: an `exceptionRules` array sent in the launch
      request the way launch.json used to carry it changes nothing at all
      (`RulesInTheLaunchRequest_AreNotRead`). Without this the removal is pinned
      by no test and a revival of the field reads as a feature
- [x] Both file shapes (`SidecarAsBareArray_IsAccepted`) and a malformed file
      costing the rules, not the session (`MalformedSidecar_LeavesDebuggingWorking`)
- [x] Hot-reload on resume, both for an edit
      (`SharedSidecar_HotReloadsOnResume`) and for a sidecar that did not exist
      when the session started (`SidecarCreatedMidSession_IsPickedUpOnResume`)
- [x] The attach path reads the same chain (`Attach_HonoursTheSharedSidecar`)
- [x] A rule scoped to `TestPackage.dpk` fires inside a host executable that
      declares nothing about the package
      (`PackageSidecar_AppliesInsideAHostThatKnowsNothingAboutIt`)
- [x] The worked example committed in this repository is a file the adapter can
      actually read -- strict JSON, right shape, known actions. A broken one
      would be silently ignored, which is exactly why it is asserted
      (`TheDebugmeSampleSidecar_IsAFileTheAdapterCanActuallyRead`)

---

## G. Threads

- [x] Enumerate threads and read names (`Test_Threads_Enumerated_NamedWorkers`,
      `Test_Threads_NameThreadForDebugging_SurfacesLive`)
- [x] Per-thread locals: BP on a worker fires on that worker, its frame
      exposes the worker's own local (`Test_Threads_BpOnWorker_LocalVisible`)
- [x] Exception raised on a worker thread surfaces on that thread; the
      worker's stack is inspected (`Test_Threads_ExceptionInWorker`)
- [ ] Step on a specific thread while others stop

---

## H. Modules and debug info sources

- [x] EXE TD32 + RSM (`Test_RealScenario_ProcLocals_TD32`,
      `Test_Modules_ListsTheMainImageAndItsSymbolFormats`)
- [x] EXE MAP fallback -- a target built with a detailed MAP and NO embedded
      debug info (`TypelessGlobals_ReadTheirOwnBytesOnBothBitnesses`; fixture
      `MapOnlyGlobals`)
- [x] BPL TD32 -- BP hits (`Test_Bpl_BreakpointHits`,
      `Bpl_Breakpoint_InPackageUnit_Stops`)
- [x] BPL TD32-only BP hits (`Test_Bpl_Td32Only_BpHits`,
      `Test_Bpl_Td32Only_LocalsVisible`)
- [x] BPL loaded after launch (deferred `LoadPackage`; BP set before load
      binds when the module arrives -- Test_Bpl_BreakpointHits)
- [x] DCP for unit symbols not in EXE TD32 (BPL params A/B via .dcp)
      (`Bpl_Breakpoint_InPackageUnit_Stops` -- reads a BPL-unit local that only
      the .dcp describes; `DelphiInstalledLayout_FindsTheSiblingDcpTree` and
      `NoDcpAnywhere_ReturnsTheBesideCandidate` for the discovery rules)
- [x] Missing/invalid BPL load fails gracefully, session completes
      (`Test_BL_Module_BplLoadFails`)
- [x] Step INTO a BPL-resident function (BPL debug info drives the step)
      (`Test_BL_Step_IntoBplFunction`)
- [x] Detach (killOnDetach=False) leaves the target running
      (`Test_BL_Module_DetachLeavesRunning`)
- [x] **BPL-defined class inspected from a BPL frame** (TPkgWidget):
      field eval (`Test_Bpl_DefinedClass_FieldVisible`) + variables-tree
      expand (`Test_Bpl_DefinedClass_ExpandInLocals`). Core SampleApp case.
- [ ] DLL with no Delphi debug info (TD32 absent, MAP absent) -- graceful
- [x] Module UNLOAD + RELOAD (form close / reopen): BP set once fires on
      both loads -- proves provider teardown + re-bind
      (`Test_Bpl_UnloadReload_BpRebinds`)
- [x] Two BPLs loaded simultaneously, BP in each routes to its own unit
      source (`Test_Bpl_TwoModules_EachBpRoutes`, TestPackage2 fixture).
      Fixing this exposed + fixed a real race: BP planting on DLL load
      was async, so a deferred module's init could run past the BP before
      the int3 landed. Now planted synchronously in the LOAD_DLL handler.
- [ ] EXE built with -V- (no debug info) refuses to start session gracefully
- [x] CodeView blob APPENDED past the image, with no `.debug` section describing
      it, is found from the file trailer and produces the same line table as the
      sectioned original (`AppendedBlob_WithNoDebugSection_LoadsIdentically`;
      fixture is built by deleting the section header from a copy of
      TestTarget.exe)
- [x] C++Builder container signature `FB0A` is accepted, and the dialect that
      was found is reported (`CppBuilderSignature_IsAccepted`,
      `ContainerSignature_OfDelphiBinary_IsFB09`). Exercised by restamping a
      Delphi container: **no C++Builder binary is tested anywhere**, and nothing
      here claims C++ demangling works
- [x] Frames in a module with NO debug info of any kind are named from its
      export table, on both bitnesses
      (`CallStack_OsTailFrames_AreNamedFromExports`), while the module and the
      `saNoSymbols` state survive that naming
      (`Frames_NoDebugInfoModule_ReportModuleAndSymbolState`)
- [x] `$lasterror` / `$laststatus` read the stopped thread's TEB and agree with
      what the target itself recorded, on both bitnesses
      (`LastError_MatchesWhatTheTargetItselfSaw`, fixture `--run-lasterror`).
      The 32-bit half is the one that matters: a WOW64 thread has two TEBs and
      the one the OS reports to a 64-bit debugger is not the one the target
      writes to
- [ ] Constant NAMES for the error codes (`ERROR_PATH_NOT_FOUND` rather than 3).
      The number is there; naming needs a table, and the NTSTATUS side has
      undocumented values with no complete SDK list
- [x] A WOW64 session keeps only its own bitness: the 64-bit ntdll and the
      `wow64*.dll` layer are dropped at `LOAD_DLL`, so the two `ntdll.dll` no
      longer collide in the name-keyed registry, while the 64-bit control still
      sees its modules above 4 GB
      (`Modules_Win32Session_ExcludesTheWow64Layer`)
- [~] Export naming says where the nearest EXPORTED routine starts, so an
      address inside a non-exported routine is attributed to the export before
      it (a WOW64 target's outermost frame reads
      `ntdll.dll!RtlGetAppContainerNamedObjectPath+$230`, not
      `RtlUserThreadStart`). Deriving the true function start from `.pdata` on
      x64 would fix that half and is not done

---

## I. Real-world / SampleApp quirks

- [x] CurrentLevel := 1 in nested proc shows as Integer 1 (not Variant `<null>`)
      (`Test_Types_TrickyOne_NotMisDecodedAsVariant`, `Test_Real_VariantNull_NotInteger`)
- [x] CurrentParent := nil in nested proc shows as `nil` (not `0 (0x0)`)
      (`Test_NilClassReference_NotExpandable`, `Test_Types_ClassRef_NilDisplaysAsNil`)
- [x] Outer-method local with ancestor mis-tag (TNoRefCountObject -> TCachedMenu)
      augments to the leaf class (`ClassAncestorHint_IsNotOverriddenByANonClass`,
      `Test_CollidingNestedClass_ResolvesMembersByVmt`)
- [x] Cache.Level[0] indexed-property watch resolves on a class whose
      member list comes from RSM, not TD32 (TD32 may report True/0 members)
      (`Test_NestedClassMethod_AllThreeBugs`)
- [x] **cross-unit collision**: TestTargetCollider.pas declares a second
      `LoadMenu.CreateNodes` with opposite local types; wired before the
      repro so RSM short-name index collides. Covered by
      `Test_NestedClassMethod_AllThreeBugs` + `Test_CrossUnitDoWork_NoCollision`.
- [x] **deep nesting** (2 levels: RunDeepNesting.Mid.Inner) -- own,
      parent, grandparent locals all visible. Parent body RVA resolved
      via FRvaToParentRva (same-unit), collision-proof across units
      (`Test_Flow_Nest3_AllAncestorsVisible` adds a SECOND unit with the
      same Mid/Inner names; both resolve correctly).
- [ ] **3+ levels deep nesting** (`A.B.C.D`) -- not yet exercised
- [ ] **same TypeId for different declared types**: TD32 emits the same
      TypeId for pointer locals of different declared classes; verify
      each displays its declared / runtime class correctly
- [ ] **BPL-defined class referenced from main EXE**: instantiate from
      EXE, stop in EXE, inspect a field of the BPL-class instance
- [ ] **fully-qualified method name longer than 200 chars**
- [ ] **Self.A.B.C dot chain of length > 4** in watch

---

## J. Edge cases

- [ ] Uninitialised local (read after declare, before assign)
- [ ] Variable optimised away (compiler dropped slot)
- [ ] Local in register only (no memory home slot)
- [ ] Local that moves register-to-memory mid-procedure
- [ ] Inline function call (no own frame)
- [ ] Tail-call optimised return (no return-to frame)
- [x] $00000001 4-byte Integer next to zeroed neighbours -- not varNull
      (`Test_Types_TrickyOne_NotMisDecodedAsVariant`)
- [x] $00000000 4-byte Integer -- displays 0, not `<empty>`
      (`Test_Types_ZeroInt_DisplaysZeroNotEmpty`)
- [x] Watch on a name that does not exist -- clean error, no exception
      leak (`Test_Watch_NonExistentName_ErrorShaped`)

### J.1 Edge battery (TestTargetEdge.pas)
- [x] Gap enum (`geA=5,geB=10,geC=20`) name display (`Test_Edge_GapEnum_DisplaysName`)
- [x] Empty string `''` renders empty, no error (`Test_Edge_EmptyString_DisplaysEmpty`)
- [x] Negative Integer / Int64 signed display (`Test_Edge_NegInteger_Signed`,
      `Test_Edge_NegInt64_Signed`, `Test_Edge_NegSmallInt_Signed`)
- [x] Float NaN / Infinity display (`Test_Edge_FloatNaN`, `Test_Edge_FloatInfinity`)
- [x] Embedded-NUL string (`'a'#0'b'`) -- surfaces content (`Test_Edge_EmbeddedNulString`)
- [x] Emoji / surrogate-pair string -- no read failure (`Test_Edge_EmojiString`)
- [x] Variant record (`case ... of`) expandable (`Test_Edge_VariantRecord_Expands`)
- [x] Interface method call resolves (`Thing.Name`) (`Test_Edge_InterfaceToClass`,
      `Test_Types_Interface_Live_HasClassName`)
- [x] Cyclic object graph (Root.Child.Parent=Root) -- expand without hang
      (`Test_Edge_CyclicGraph_NoInfiniteExpand`)
- [x] Object mid-construction (BP in ctor; FirstField set, SecondField 0)
      (`Test_Edge_ObjectMidConstruction`)
- [x] **Large set (>8 elements)** (`Test_Edge_LargeSet_BeyondOneByte`):
      TD32 $0030 leaf decoded as a named set (tkSet) with base-enum names
      populated; LookupEnumInfo prefers the richest set result; formatter
      decodes membership across the full 64-bit slot. `set of TManyEnum`
      = `[me0, me9, me19]`.
- [x] **Negative SmallInt** (`Test_Edge_NegSmallInt_Signed`): merge now
      rejects a `TArray\`1` augment over a small-int local (geometric
      mismatch), so it stays SmallInt and reads 2 bytes signed.
- [!] **Long string**: TODO-RED `Test_Edge_LongString_NoCrash` --
      ReadDelphiUnicodeString returns `''` for a 5000-char string (length
      cap returns nothing instead of truncated content).
- [x] **Recursion / non-top-frame locals** (`Test_Edge_Recursion_PerFrameLocals`):
      scopes/evaluate now honor frameId -- the adapter selects that
      call-stack frame (its unwound Ctx.Rbp) and reads ITS locals/params.
      Each recursion frame's N (1..5) reads distinctly. High value: any
      deep-stack inspection / clicking a frame in the call stack.

---

## K. Set variable

- [x] Class field string (`Test_SetVariable_ClassField_String`,
      `SetFieldVariable_ViaClassHandle_WritesField`)
- [x] Nested record field double (`Test_SetVariable_NestedRecordField_Double`)
- [ ] Class field Integer / Cardinal / Int64
- [x] Enum by name (`Gap := geC`) -- type-scoped, gapped enums OK
      (`Test_SetVar_EnumByName`)
- [ ] Class field Set
- [ ] Class field Variant
- [ ] Local variable (not a field)
- [ ] Parameter
- [x] Invalid write rejected cleanly (success:false, session survives)
      (`Test_SetVar_TypeMismatch_Rejected`)

---

## L. Clipboard / format

- [x] Class instance clean format (`Test_Clipboard_ClassInstance_CleanFormat`,
      `Test_LocalsView_ClassInstance_FormattedWithClassName`)
- [x] String field no token error (`Test_Clipboard_StringField_NoTokenError`)
- [x] Integer no redundant unsigned suffix (`Test_Format_Integer_NoRedundantUnsigned`)
- [ ] Variant clipboard text
- [ ] Set clipboard text
- [ ] Class with > 30 fields -- truncated representation

## M. Disassembly (DISASSEMBLY_PLAN.md increments 2-6)

- [x] Backend reports `Available=False` with a non-empty `StatusText` and
      `Disassemble` returns an empty array -- WITHOUT ever invoking the byte
      reader -- when the DLL is missing
      (`TDisassemblerBackendTests.Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads`)
- [x] Trap 1 (a planted breakpoint elsewhere in the disassembly window reads
      back as its ORIGINAL opcode via `IDebugTarget.ReadCodeMemoryAt`, not the
      `$CC` raw process memory shows), on both bitnesses
      (`TReadCodeMemoryAtTests` / `TReadCodeMemoryAtWin32Tests`
      `.ReadCodeMemoryAt_RestoresAnotherStillPlantedBreakpoint`)
- [ ] Trap 2 (a read that runs past a committed region's end truncates rather
      than fails) -- no automated fixture; exercised manually via
      `DevTools\Disasm.exe` (static mode truncates at file EOF, live mode at
      the `VirtualQueryEx` region boundary in `ReadCodeMemoryAt`)
- [x] The positive decode path (real `Zydis.dll`, correct bytes/mnemonics),
      both machine modes -- increment 3 made `ZydisApi.ZydisTryLoad`'s
      one-shot latch resettable (`ZydisResetForTests`, test-only), removing
      the reason this was excluded before. Known prologue bytes measured in
      increment 1 decode to the expected mnemonics
      (`TZydisPositiveDecodeTests.Long64_KnownPrologueBytes_DecodeToExpectedMnemonics`
      / `.Legacy32_KnownPrologueBytes_DecodeToExpectedMnemonics`). All
      Zydis-touching fixtures in `DisassemblerTests.pas` (this one, the
      negative-DLL test, the whitelist regression below, and both
      `ReadCodeMemoryAt` fixtures) run together in ONE process and pass
      regardless of DUnitX's own execution order -- proven by running them
      together, not assumed. `DevTools\Disasm.exe` remains the manual
      end-to-end demonstration against real binaries with real
      symbolication.
- [x] Call-target symbolication correctness (mnemonic whitelist) -- the exact
      bug found by hand during increment 2 development now has an automated
      regression guard: `push 0x2A` fed through `TZydisDisassembler` with a
      fake symbol provider that answers a name for EVERY address must never
      grow a `"; <name>"` comment
      (`TCallTargetWhitelistTests.PushImmediate_NeverAnnotatedAsCallTarget`).
      Negative-controlled: reverting `FBranchTargetRe` to the pre-fix open
      `[A-Za-z]+ 0x<hex>` pattern fails the test with the exact bug
      description in the assertion message.
- [x] Differential coverage of Zydis's actual decode against an independent
      oracle (dumpbin), over real binaries at real scale -- increment 3,
      `DevTools\DisasmCoverage.exe`. Not a DUnitX fixture (it is a
      measurement tool, not a fast repeatable assertion — a full sweep of
      the largest binary takes minutes), so tracked here as a `[x]` because
      the measurement itself is done and recorded, not because it runs in
      `RunTests.exe`. 13 173 394 instruction positions compared across
      `TestTarget.exe` (both bitnesses), `TestSubject.bpl` (both
      bitnesses), `rtl290.bpl`, `vcl290.bpl`, and both bitnesses of a
      500+ MB real production binary (33% sample, disclosed): zero
      mnemonic-identity divergences. Full numbers, classification of every
      non-mnemonic divergence, and the dumpbin-scale artifact this sweep
      surfaced are in `DISASSEMBLY_PLAN.md` "Verified in increment 3 — Half
      B" and `DevTools\README.md`'s `DisasmCoverage` entry.
- [x] MCP `disassemble` -- increment 4. Forward decode at a resolved address
      returns the right instructions starting exactly there, both bitnesses
      (`TMcpE2ETests.Disassemble_Forward_ReturnsDecodedInstructionsAtStopAddress`
      x64, `.Disassemble_Win32_Forward_ReturnsDecodedInstructions` x86).
      `frameIndex`/`threadId` (no separate opaque frameId) resolves to the
      SAME address form (`.Disassemble_ViaFrameIndex_MatchesAddressForm`).
      `available:false` with a reason and no `instructions`/`before` at all
      when Zydis cannot load -- proven against a real isolated copy of the
      MCP exe with no discoverable DLL, not simulated
      (`.Disassemble_ReportsUnavailable_WhenZydisDllNotFound`).
- [x] `before` (backward disassembly) -- proven-boundary-only, per the
      decision recorded in `DISASSEMBLY_PLAN.md` ("Decision: backward
      disassembly is proven-boundary-only"). The pure mechanism
      (`Disassembler.DisassembleBackward`): a forward decode from a known
      boundary that lands exactly on the target returns the correct
      preceding instructions, most-recent-last
      (`TDisassembleBackwardTests.ProvenBoundary_LandsExactly_ReturnsExactPrecedingInstructions`);
      a boundary whose forward decode does NOT land exactly on the target
      (mid-instruction) refuses with an EMPTY result rather than a
      misaligned guess
      (`.Misalignment_DoesNotLandExactly_RefusesWithEmptyResult`, negative-
      controlled -- see `DISASSEMBLY_PLAN.md`). End to end through the MCP
      tool at an ordinary breakpoint stop (past its routine's prologue, so a
      debug-info boundary exists): `before.refused=false` and the last
      returned instruction ends exactly at the stop address
      (`TMcpE2ETests.Disassemble_Before_ReturnsProvenPrecedingInstructions`).
- [ ] `before`'s PE-export-table fallback (`IDebugTarget
      .NearestExportedEntryBefore`, for a module with no debug info at all)
      has no automated fixture: the only symbol-less modules in the test
      fixtures (kernel32/ntdll) also have such large export tables that a
      targeted regression is hard to construct deterministically. Exercised
      only by construction (the same PE export-directory parse
      `DevTools\DisasmCoverage.exe`'s `TPEImage.ExportedFunctionRvas` already
      validates against real binaries, read from live memory instead of a
      file here) -- not by a DUnitX test.
- [x] DAP `disassemble` request + `instructionPointerReference` -- increment
      6, the last functional increment. Capability advertised
      (`Test_Initialize_AdvertisesSupportsDisassembleRequest`);
      `instructionPointerReference` on the top stack frame matches the
      independent Registers-scope RIP oracle
      (`Test_StackTrace_InstructionPointerReference_MatchesRip`); forward
      decode returns exactly `instructionCount` real instructions starting
      exactly at `memoryReference`, strictly ascending
      (`Test_Disassemble_Forward_ReturnsExactCountAtInstructionPointer`);
      negative `instructionOffset` at a stop with a provable boundary returns
      a REAL preceding instruction ending exactly at the stop address, reusing
      `Disassembler.DisassembleBackward` per the increment-4 decision, not
      re-deriving it
      (`Test_Disassemble_NegativeOffset_ProvenBoundary_ReturnsRealPrecedingInstruction`);
      an address with no proven boundary in either direction (`0x1000`, inside
      Windows' reserved NULL-page region) returns EXACTLY the requested count
      with every slot marked `presentationHint: 'invalid'`, no
      `instructionBytes`, never a guessed decode
      (`Test_Disassemble_UnprovenAddress_MarksEveryInstructionInvalid_NeverGuessed`).
      All five run under both the mono and BPL fixture. Negative-controlled
      (5 independent controls: capability flag, `instructionPointerReference`
      emission, the dispatch line, the boundary lookup, and the
      `presentationHint` marking) -- exact failure text in `DISASSEMBLY_PLAN.md`
      "Verified in increment 6".
- [ ] No test drives a REAL VS Code Disassembly View against the adapter --
      every assertion above is at the DAP protocol layer through
      `DebuggerTests\DapClient.pas`, the same synchronous test client every
      other DAP integration test in this suite uses.
- [ ] DAP-layer Win32 (32-bit target) coverage for `disassemble` -- not
      written this increment, same scoping choice as `setInstructionBreakpoints`
      below: bitness is already proven at the MCP layer
      (`Disassemble_Win32_Forward_ReturnsDecodedInstructions`), and DAP's
      `HandleDisassemble` shares the exact same `TargetLayout.PointerSize` ->
      machine-mode dispatch MCP's does.
- [ ] No test exercises a request whose window straddles `memoryReference`
      with a NEGATIVE `instructionOffset` smaller in magnitude than
      `instructionCount` (the mixed backward+forward case) -- covered by
      construction (the same `TrueNegCount`/`PosCount` split in
      `HandleDisassemble` handles it), not by a dedicated test. The two
      shipped negative-offset tests are the reaches-`memoryReference`-exactly
      case and the entirely-below-zero refusal case.

## N. Address breakpoints (DISASSEMBLY_PLAN.md increment 5)

- [x] Engine plant/refuse: an address inside the (already loaded) main exe
      resolves to `(module, rva)` and actually stops the target on a LATER
      call, not merely reports `verified:true`
      (`DebugSessionTests.AddrBp_MainExe_SetAtKnownAddress_StopsThere`).
      Negative-controlled: caught a real cross-layer identity bug on its
      first run (the main-exe module-name sentinel differs between the
      session and engine layers) -- full detail in `DISASSEMBLY_PLAN.md`
      "Verified in increment 5".
- [x] Conditions/hit-counts reuse the SAME per-breakpoint machinery a source
      breakpoint uses, not a parallel implementation: `hitCondition '>=2'`
      on an address breakpoint skips the first hit exactly like
      `Breakpoint_HitCount_SkipsEarlyHits` proves for a source breakpoint
      (`AddrBp_HitCondition_SkipsEarlyHits`).
- [x] Refusal: an address not inside any currently loaded module is refused
      with a reason and never appears in `list_breakpoints` -- never planted
      at a VA that might belong to something else later
      (`AddrBp_RefusedWhenAddressNotInAnyLoadedModule`, negative-controlled).
- [x] `list_breakpoints` carries BOTH kinds in one list, each stating which
      kind it is (`AddrBp_ListBreakpoints_ReportsBothKinds`, negative-
      controlled).
- [x] Remove unplants for real (the INT3 is gone from the target, not just
      from the session's own list) — mirrors `RemoveAllBreakpoints_
      ClearsPlantedInt3`'s proof shape (`AddrBp_Remove_
      UnplantsAndDoesNotStopAgain`, negative-controlled).
- [x] **The BPL fixture, where module+RVA identity earns its keep.** An
      address breakpoint set ONCE, while stopped at the first load, survives
      `TestPackage.bpl` unloading and reloading (`--reload-package`) and
      fires AGAIN with no second set call -- proven at the session layer
      (`AddrBp_Bpl_UnloadReload_Rebinds`) and mirrored end to end through
      both frontends (`TMcpE2ETests` uses the disassembled/echoed address
      convention on the mono fixture instead, see below; DAP's
      `Test_SetInstructionBreakpoints_Bpl_UnloadReload_Rebinds` drives the
      exact same package lifecycle). Negative-controlled: BOTH the load-side
      and unload-side repost call had to be disabled together to break it
      (disabling only one is not a sufficient negative control -- the
      unload-side repost's queued command gets drained by the NEXT load
      event anyway; see `DISASSEMBLY_PLAN.md` "Traps found in this
      increment").
- [x] MCP `set_breakpoint_at_address` / `remove_breakpoint_at_address`, both
      bitnesses, using the documented "feed a real stop's own echoed address
      straight back in" workflow
      (`TMcpE2ETests.SetBreakpointAtAddress_UsingDisassembledAddress_
      StopsAgain` x64, `.SetBreakpointAtAddress_Win32_StopsAgain` x86,
      `.SetBreakpointAtAddress_RefusedWhenNotInAnyLoadedModule`,
      `.RemoveBreakpointAtAddress_UnplantsAndDoesNotStopAgain`).
- [x] DAP `setInstructionBreakpoints` + `supportsInstructionBreakpoints`,
      mono (`Test_SetInstructionBreakpoints_Basic_StopsAndVerifies`,
      reading the exact stop address off the DAP Registers scope since no
      address-echoing stack-frame field existed yet at the time -- increment
      6 later added `instructionPointerReference`, not retrofitted into this
      test) and the BPL reload scenario above.
      Negative-controlled: commenting out the dispatch wire-up fails with
      `Value 'breakpoints' not found` (the generic unknown-command
      fallback), proving the wire-up itself is exercised, not just the
      session mechanism underneath it.
- [ ] DAP-layer Win32 coverage for `setInstructionBreakpoints` -- not written
      this increment (bitness is proven at the MCP layer; DAP is JSON glue
      over the same already-bitness-proven session code). A scoping choice,
      not an oversight -- recorded here rather than silently omitted.
- [ ] No automated fixture proves the module unload transition's `Verified`
      flip is visible mid-flight (between `UnloadPackage` and the next
      `LoadPackage`) -- only the eventual outcome (refires after reload) is
      asserted. The transition would need polling `ListBreakpoints` from
      inside the pump loop at an unpredictable moment, which is exactly the
      kind of timing-dependent assertion this project avoids.
- [ ] No live DAP `breakpoint`-changed event fires when an address
      breakpoint's `Verified` flips on module unload/reload (unlike a source
      breakpoint's verified-flip, which fires one via `OnBreakpointChanged`).
      A follow-up, not a correctness gap: a fresh `list_breakpoints` /
      `setInstructionBreakpoints` call reports the current truth regardless.

## O. Instruction-granularity stepping (ASSEMBLY_LEVEL_DEBUGGING.md increment 1)

`DebuggerTests\InstructionStepTests.pas`, 8 scenarios x BOTH bitnesses as
separate test cases (16), driving `TDebugSession.StepInstruction` directly — no
DAP, no MCP (those are increments 2 and 4). The fixture is its own target,
`TestTarget\InstructionStepSample.dpr`, for the usual reason: adding scenarios to
`TestTarget` shifts RSM import indices and marker ordering. Every one was proven
RED by removing its rule and re-running; the measured failure text is in the
increment-1 report.

- [x] **One instruction, not one line.** The marker line is deliberately several
      instructions long, so the step must land at PC + the decoded length with
      the source line UNCHANGED
      (`*_Into_AdvancesOneInstructionAndEntersTheCallee`). RED control: degrade
      the plan to the source-level `smInto` and it runs to the next line.
- [x] **Step-into a `call` enters the callee** (same test, second half).
- [x] **Step-over does NOT single-step a `call`**: lands at PC + length, in the
      same frame, same routine (`*_Over_StaysInTheCallerFrame`). RED control:
      drop the call rule and it lands at the callee's entry.
- [x] **The stack-pointer guard, on a genuinely recursive callee**: stepping over
      the recursive `call` inside the OUTERMOST incarnation must land at the same
      stack pointer it started from (`*_Over_RecursiveCallee_StaysInTheOuterFrame`).
      RED control: zero `MinResumeSP` and it lands at the right address with a
      lower stack pointer — the innermost incarnation ended the step.
- [x] **A `rep`-prefixed instruction completes as ONE step**, for step-over AND
      step-into (`*_Over_/_Into_RepPrefixed_CompletesTheWholeStringOperation`).
      Proven by the COUNT REGISTER — 65536 before, 0 after — which needs no
      symbol resolution and cannot be satisfied by one iteration. RED control:
      drop the rep rule and the PC is byte-identical before and after.
- [x] **Step-out lands in the caller** with a risen stack pointer
      (`*_Out_LandsInTheCaller`). RED control: make it a trap-flag step and it
      stays inside the callee.
- [x] **Refusal when the disassembler backend is unavailable**, for all three
      kinds, with the session left stopped and the PC unmoved
      (`*_Refused_WhenDisassemblerUnavailable`). The backend is an INJECTED
      `IDisassembler` double with `Available=False`, not a bad DLL path: the
      Zydis loader is a process-wide one-shot latch (`TRAPS.md`).
- [x] **A watchpoint firing inside a stepped-over call is not the step
      completing** (`*_WatchpointHitDuringStepOver_IsNotAStepCompletion`) — the
      instruction-granularity twin of the existing source-level DR6 tests. RED
      control: remove the in-flight-step gate in the DR6 branch and the step
      stops inside the callee, at the write.
- [ ] The `iskOut` branch that refuses because NO return address can be proven
      (x64 code with no unwind data and no frame pointer) has no fixture — the
      same limitation `TRAPS.md` already records for the x86 walk, since dbghelp
      knows every test module. What IS proven is that the refusal MECHANISM
      works and leaves the session untouched, via the unavailable-backend test.
- [ ] No test drives instruction stepping on a NON-stopped session or an unknown
      thread id; both are guarded in `StepInstruction` and answered with a
      reason, but only by construction.

## P. DAP stepping granularity (ASSEMBLY_LEVEL_DEBUGGING.md increment 2)

`DebuggerTests\InstructionStepDapTests.pas`, driving the real adapter process
over stdio (`TDapClient`) against the SAME `InstructionStepSample.exe`/`.map`/
`.rsm` fixture increment 1 built — no new fixture needed. Scope: this file
proves the DAP PLUMBING (does `granularity: "instruction"` reach
`TDebugSession.StepInstruction` with the right `TInstructionStepKind`, does a
refusal reach the client as a failed request, is the unchanged path truly
unchanged); the ENGINE semantics (call/rep/recursion rules, every refusal
reason) are InstructionStepTests.pas's job (section O) and are not
re-proven here.

- [x] **Capability advertised** (`Capability_SupportsSteppingGranularity_
      IsAdvertised`): the `initialize` response carries
      `supportsSteppingGranularity: true`.
- [x] **`stepIn` with `granularity: "instruction"` stays on the source line**
      (`*_StepIn_Instruction_AdvancesOneInstructionSameLine`, both bitnesses,
      at the same `INSTR_MULTI` marker increment 1 uses): the line is
      unchanged and the instruction pointer moved. RED control: comment out
      the `WantsInstructionGranularity` dispatch in `HandleStepIn` — the
      request falls through to the old `FSession.StepInto` path, which runs
      to the NEXT source line, and the "line unchanged" assertion fails
      (measured: line advanced from the marker line to the next statement).
- [x] **`next` with `granularity: "instruction"` stays on the source line**
      (`*_Next_Instruction_AdvancesOneInstructionSameLine`, both bitnesses,
      same marker and mechanism). Same RED control, applied to `HandleNext`.
- [x] **`stepOut` with `granularity: "instruction"` lands in the caller**
      (`*_StepOut_Instruction_LandsInTheCaller`, both bitnesses, at
      `INSTR_CALLEE_BODY`): the frame name changes from the callee to the
      caller. RED control here is a Kind-mapping mutation rather than a
      revert, and it has to be: in this NON-recursive scenario the pre-
      existing source-level `stepOut` also lands correctly in the immediate
      caller (it uses the same `FStepOverVA`/`FStepResumeSP` one-shot
      machinery `iskOut` reuses), so disabling the dispatch alone does not
      change the observable outcome — reverting it is not a valid negative
      control here (see TRAPS.md, "Proving a fix"). Swapping the mapped kind
      from `iskOut` to `iskInto` in `HandleStepOut` IS a valid control: the
      step then stays inside the callee (one more instruction into the SAME
      routine) and the "landed in caller" assertion fails.
- [x] **Granularity absent / `"statement"` is BYTE-IDENTICAL to pre-increment-2
      behaviour** (`X64_StepIn_GranularityAbsent_StillAdvancesToNewLine`,
      `X64_StepIn_GranularityStatement_StillAdvancesToNewLine`,
      `X64_Next_GranularityAbsent_StillAdvancesToNewLine`): the source line
      DOES change at the same `INSTR_MULTI` marker where the instruction-
      granularity tests above assert it stays put — the two are direct
      opposites of each other, at the identical stop. Win64 only: this is
      plain JSON-field parsing with no bitness-sensitive content, the same
      scoping call already recorded for `setInstructionBreakpoints`'
      DAP layer (section N).
- [x] **A refusal reaches the client as a FAILED request, not a silent
      success** (`Refused_WhenNotLaunched_ReachesClientAsFailedRequest`): an
      instruction-granularity `stepIn` sent before `launch` comes back
      `success: false` with a non-empty `message`. RED control: make
      `HandleInstructionStep` send `success: true` unconditionally before
      calling `StepInstruction` (the exact shape of the pre-existing
      `HandleNext`/`HandleStepIn`/`HandleStepOut` handlers) — the assertion
      that `success` is `False` fails.
- [ ] The other two increment-1 refusal reasons ("thread is not live", "no
      disassembler backend") are UNREACHABLE through the DAP wire protocol,
      not merely untested: `StepThreadFromArgs` folds any unmatched
      `threadId` back to 0 (the stopped thread, same fallback `stackTrace`
      uses), and there is no launch-config knob that forces the Zydis
      backend unavailable from outside the process. Both refusal MECHANISMS
      are fully covered at the engine level (section O).

## Q. MCP registers and instruction stepping (ASSEMBLY_LEVEL_DEBUGGING.md increment 4)

`DebuggerTests\McpE2ETests.pas`, driving the real `DelphiDebuggerMcp.exe`
process over stdio (`TMcpTestClient`). Registers use the mono `TestTarget`
fixture (`EVAL_SOURCE`/`EVAL_MARKER`, shared with the rest of this file);
stepping reuses increment 1's own fixture,
`TestTarget\InstructionStepSample.dpr` — no new fixture built for this
increment. Unlike DAP (in-process, `InstructionStepDapTests.pas`), MCP is a
separate exe, which makes the disassembler-unavailable refusal reachable from
OUTSIDE the process too (the same scratch-directory isolation trick
`Disassemble_ReportsUnavailable_WhenZydisDllNotFound` uses), not just at the
engine level.

**Registers** — the ENGINE values are already proven by DAP's own Registers
scope coverage; these tests prove the MCP TOOL surface (JSON shape, the
"must be stopped" gate, an unrecognised-name refusal):

- [x] **`get_registers`' RIP agrees with the call stack's own address for the
      SAME stop** (`GetRegisters_MatchesCallStackRip`) — a plain string
      comparison, since `RegisterToJson` and `FrameListToJson` use the
      identical `'0x' + hex` format. Also asserts the row count (18) and
      that RSP is non-zero and EFlags reports `size: 4`. RED control: rename
      the `get_registers` dispatch string so it falls through to "Unknown
      tool" — the test errors with an invalid class typecast (an array was
      expected, got the plain-text error wrapped as a JSON string).
- [x] **On a WOW64 (32-bit) target, `get_registers` describes an x86 register
      file** (`GetRegisters_Win32_ReportsAnX86RegisterFile`) — the one
      genuinely bitness-sensitive assertion here: `EIP` agrees with the call
      stack's own address, every row is `size: 4`, and `R8`/`R9`/`R15`/`RIP`/
      `RAX` are ABSENT. It previously asserted the opposite (`R8`..`R15`
      present, reading `"0x0"`), which was the shape of `TRegisterSnapshot`
      rather than a measurement of the target.
- [x] **Refused before any launch, with a reason** (`GetRegisters_RefusedBeforeLaunch`).
- [x] **`set_register` writes, and a LATER, independent `get_registers` call
      still sees it** (`SetRegister_WritesAndReadsBack`) — writes RAX to a
      16-hex-digit sentinel, checks the immediate response, then re-reads.
      RED control: same rename trick as `get_registers` — 3 of the 5
      register tests fail (`SetRegister_WritesAndReadsBack`,
      `SetRegister_UnknownName_Refused`, `GetRegisters_RefusedBeforeLaunch`'s
      message no longer names "stop").
- [x] **An unrecognised register name is refused, naming the bad name**
      (`SetRegister_UnknownName_Refused`).
- [x] **`set_register` on a WOW64 target — resolved in increment 6.** See
      section S below for the measurement and the fix
      (`TWin32Debugger.SetRegisterByName`).

**Instruction-granularity stepping** — the ENGINE rules (call/rep/recursion,
every refusal reason) are `InstructionStepTests.pas`'s job (section O) and
are not re-proven here; this proves `granularity:"instruction"` reaches
`TDebugSession.StepInstruction` with the right `TInstructionStepKind`, that a
refusal surfaces as `isError:true` (never a silent no-op or an unresolved
wait), and that `"statement"` (default) is untouched. MCP had NO coverage of
plain `step_over`/`step_into`/`step_out` before this increment, so the
granularity-absent tests below are also the first coverage of those tools at
all:

- [x] **`step_into` at instruction granularity advances exactly one
      instruction, same source line** (`StepInto_Instruction_
      AdvancesOneInstructionSameLine`, both bitnesses, at the same
      `INSTR_MULTI` marker increment 1/2 use). RED control: force the
      granularity check to always take the `"statement"` branch — both
      bitness cases fail (`Expected [63] but got [64]`, i.e. it ran to the
      next line), plus the disassembler-unavailable refusal test below (a
      statement-level step never refuses, so it silently accepted where it
      should have errored). NOT a valid control for
      `StepInto_Instruction_RefusedBeforeLaunch`: the statement-level
      fallback ALSO refuses before launch (`FSession.StepInto` raises "No
      active debuggee to step" for its own, unrelated reason), so that one
      test cannot distinguish the two code paths — recorded rather than
      silently claimed as proof.
- [x] **`step_over` at instruction granularity does the same, Win64 only**
      (`StepOver_Instruction_AdvancesOneInstructionSameLine`) — the
      call/rep-avoidance rules are already both-bitness-proven at the engine
      and DAP layers; this only needs to prove the Kind mapping reaches the
      engine, which is bitness-insensitive JSON glue.
- [x] **`step_out` at instruction granularity lands in the caller** (`StepOut_
      Instruction_LandsInTheCaller`, both bitnesses, at `INSTR_CALLEE_BODY`).
      RED control here needed the SAME non-obvious mutation increment 2's DAP
      test needed, not a plain revert: disabling the granularity dispatch
      does NOT fail this test, because the pre-existing STATEMENT-level
      `step_out` also lands correctly in the immediate caller in this
      non-recursive scenario (same `FStepOverVA`/`FStepResumeSP` machinery
      `iskOut` reuses) — measured, not assumed, before settling on the valid
      control: swap the `Kind` passed to `HandleStepTool` for the `step_out`
      tool from `iskOut` to `iskInto`. That fails both bitness cases
      (`landed in "InstrStepCallee", not in the caller`).
- [x] **Granularity absent, and explicit `"statement"`, are BYTE-IDENTICAL to
      pre-increment-4 behaviour** (`StepInto_GranularityAbsentOrStatement_
      StillAdvancesToNewLine`) — the source line DOES change at the same stop
      where the instruction-granularity test above asserts it stays put.
- [x] **An unrecognised `granularity` value is refused, never silently
      treated as `"statement"`** (`StepOver_UnknownGranularity_Refused`) —
      also asserts nothing moved (`get_debug_session_status` still reports
      the pre-call line). RED control: disable the validation branch — the
      call SUCCEEDS and the program counter visibly advances (`stopReason:
      "step"`, a new line), instead of being refused.
- [x] **Refused before any launch** (`StepInto_Instruction_RefusedBeforeLaunch`)
      — mirrors the DAP `Refused_WhenNotLaunched_...` control, but is a
      WEAKER control here (see above): both the instruction- and
      statement-level paths refuse before launch, for different reasons.
- [x] **Refused when the disassembler backend is unavailable, reached from
      OUTSIDE the process** (`StepInto_Instruction_
      RefusedWhenDisassemblerUnavailable`) — unlike DAP (where this refusal
      is only reachable in-process, via `SetInstructionDisassembler`), MCP
      is a separate exe: copying it to a scratch directory neither its
      own-directory Zydis.dll check nor its repo-relative fallback can
      resolve leaves nothing for `ZydisTryLoad`'s bare-name search to find,
      reproducing "unavailable" from a real external client. Also asserts
      nothing moved.
- [ ] The `iskOut` "no provable return address" refusal has no MCP fixture,
      for the same reason section O records at the engine level: it needs
      x64 code with no unwind data, and dbghelp knows every test module.

## R. DAP memory: readMemory/writeMemory, memoryReference (ASSEMBLY_LEVEL_DEBUGGING.md increment 3)

`DebuggerTests\MemoryDapTests.pas`, driving the real adapter process over
stdio (`TDapClient`), against the SAME `InstructionStepSample.exe`/`.map`/
`.rsm` fixture increments 1/2 built — no new fixture needed. `X` at the
`INSTR_MULTI` marker (a plain stack-resident Integer under this sample's
`{$O-}` build, value 7 at that stop) is the one local these tests read and
write. The ENGINE primitives (`IDebugTarget.ReadCodeMemoryAt`'s truncate-at-
region-boundary and INT3-restoring behaviour) are already proven at the
engine level (`DisassemblerTests.pas`, `InstructionStepTests.pas`); this file
proves the THIN layer on top: does the request reach the engine with the
right address/count, does a truncated/refused outcome come back reported
correctly rather than as a silent success, and does a variable's
`memoryReference` actually point at the address backing its displayed value.

- [x] **Capability advertised** (`Capability_SupportsReadWriteMemoryRequest_
      IsAdvertised`): the `initialize` response carries
      `supportsReadMemoryRequest: true` and `supportsWriteMemoryRequest: true`.
- [x] **`readMemory` on a local's `memoryReference` returns exactly the bytes
      backing its displayed value** (`*_ReadMemory_LocalVariable_
      MatchesDisplayedValue`, both bitnesses): reads `X`'s 4-byte slot and
      decodes base64 `data` to `[07,00,00,00]` (little-endian Integer 7), with
      `unreadableBytes` absent/0. RED control: disable `EmitVar`'s
      `memoryReference` emission — both bitness cases fail at "carries no
      memoryReference" before the read is even attempted (see the
      `memoryReference`-presence control below; the same mutation invalidates
      every test that starts from a variable's own reference).
- [x] **`writeMemory` on a local's `memoryReference` changes the value the
      NEXT `variables` request shows** (`*_WriteMemory_LocalVariable_
      ChangesVisibleValue`, both bitnesses): writes little-endian 42 into `X`,
      then re-fetches Locals and asserts the displayed value now contains
      `(0x2a)`. RED control: disable the `readMemory`/`writeMemory` dispatch
      cases in `ProcessRequest` — 12 of the 14 tests in this section fail (the
      2 survivors are the capability test and the memoryReference-presence
      half of the Registers-scope control, neither of which sends a
      `readMemory`/`writeMemory` request at all).
- [x] **A stack local carries `memoryReference`; the Registers scope never
      does** (`Variables_LocalCarriesMemoryReference_RegistersScopeDoesNot`) —
      the omission side of the "if in doubt, omit" rule, not just the
      presence side the read/write tests above prove. A register is a CPU
      register, not a byte-addressable location; `HandleVariables`' Registers
      branch builds its rows directly rather than through `EmitVar`, so this
      is structural, not a value check that happens to come out empty.
- [x] **A read that runs off mapped memory is a PARTIAL SUCCESS, never a
      failure** (`ReadMemory_UnmappedAddress_ReportsUnreadableBytesNotFailure`):
      reads 16 bytes starting at `0x10` (the reserved null-page region — never
      `MEM_COMMIT` for any usermode process, on either bitness, so this is a
      deterministic "definitely not there" address rather than a guess at a
      real boundary). Asserts `unreadableBytes = 16` and no `data` field.
      RED control: disable the `unreadableBytes`-computing branch in
      `HandleReadMemory` — this one test fails (`Expected [16] but got [0]`),
      nothing else does.
- [x] **An invalid `memoryReference` is refused, not silently read as address
      0** (`ReadMemory_InvalidMemoryReference_Refused`).
- [x] **`count` is a required field; omitting it is refused, not treated as
      count=0** (`ReadMemory_MissingCount_Refused`) — sent via raw JSON
      (`{"memoryReference":"0x1000"}`, no `count`) since `TDapClient.ReadMemory`
      itself cannot construct a malformed request.
- [x] **Refused before any launch** (`ReadMemory_RefusedWhenNotLaunched`) —
      mirrors the `Refused_WhenNotLaunched_...` pattern sections P/Q already use.
- [x] **A write that lands PARTLY (here: not at all) is refused when the
      caller did not opt into `allowPartial`** (`WriteMemory_
      UnwritableAddress_RefusedWithoutAllowPartial`): writes 4 bytes to
      `0x10`; `WriteMemoryPartial` reports 0 bytes landed, and without
      `allowPartial` that is a REFUSAL (`success:false`), never a quiet
      no-op — the message states how many bytes actually changed (0) so the
      caller is not left assuming the request had no effect at all when it
      might have partially. RED control: force the refusal check to `False`
      — this one test fails (the request wrongly succeeds).
- [x] **The SAME write, with `allowPartial: true`, succeeds and truthfully
      reports zero bytes written** (`WriteMemory_UnwritableAddress_
      AllowPartial_ReportsZeroBytesWritten`) — `bytesWritten = 0`, not the 4
      requested.
- [x] **`data` is a required field; omitting it is refused, not treated as
      "write zero bytes"** (`WriteMemory_MissingData_Refused`) — same raw-JSON
      technique as the `count` control above.
- [x] **Refused before any launch** (`WriteMemory_RefusedWhenNotLaunched`).
- [ ] **The "while running" gate on both requests is unverified** — matching
      `disassemble`'s own precedent (section M), a test that deliberately
      catches the debuggee mid-`continue` is racy to construct reliably in
      this fixture and was not attempted; the code path
      (`FSession.State <> dsStopped`) is the same shape `HandleDisassemble`
      already uses.
- [ ] **`memoryReference` on nested fields/array/Variant-array elements
      (`MemberFieldToSession`, `ExpandRttiTyped`, `ExpandProperties`
      field-backed properties, `ExpandDynArray`, `ExpandVariantArray` in
      `VariableExpander.pas`) is implemented but has no DAP-level test of its
      own** — only the top-level Locals-scope case above is driven end-to-end
      through a real adapter session. Each of those five sites sets
      `.Address` from a value already used for a genuine memory read one line
      away (`FieldAddr`/`ElemAddr`), the same mechanism proven for the
      top-level case, so the gap is coverage breadth, not a different
      mechanism.

## S. Register writes on a WOW64 target (ASSEMBLY_LEVEL_DEBUGGING.md increment 6)

`TWinDebugger.SetRegisterByName` had no WOW64 override, unlike every other
member of the thread-context funnel (`ReadThreadRegisters`, `SetThreadPc`,
`SetThreadTrapFlag`, `ReadDebugRegisters`/`WriteDebugRegisters`) — it always
used the native `GetThreadContext`/`SetThreadContext` pair. **Measured**
(`DevTools\Wow64RegWriteProbe.dpr`, both at the WOW64 loader breakpoint and at
a real application breakpoint, on both bitnesses):

- At the WOW64 loader breakpoint (before the 32-bit environment finishes
  initialising) a native write is genuinely invisible to
  `Wow64GetThreadContext` — reproduces the originally-suspected defect.
- At a REAL application breakpoint — an `INT3` planted in running 32-bit
  code, which is every stop this debugger actually reports to a user — the
  native and WOW64 views alias exactly, on this measured Windows build, for
  every field tested: `Rip`/`Rsp`/`Rbp` (control-flow registers) and every
  general-purpose register (`Rax`/`Rbx`/`Rcx`/`Rdx`/`Rsi`/`Rdi`). A native
  write reaches the guest-visible register correctly. The originally-assumed
  "silent wrong-register write" is NOT reproducible at any state the debugger
  actually presents to a user.
- **R8..R15 do not exist on x86 at any width, and this WAS a real, reachable
  defect independent of the aliasing question above**: the unfixed base
  class's name matching accepted `"R8"`..`"R15"` and reported success while
  writing a native-context field that means nothing on a WOW64 target.

Given the write path was unverified either way, `TWin32Debugger.
SetRegisterByName` (`WinDebuggerX86.pas`) was given a WOW64 override anyway
(Outcome 1 of the increment's two acceptable outcomes) — using the
documented-correct `Wow64Get/SetThreadContext` API instead of relying on
OS aliasing behaviour that is not guaranteed to hold on every Windows
version, matching the rest of the funnel, and closing the R8..R15 defect,
which is real regardless of the aliasing finding. R8..R15 are refused
outright (no logical register exists to write).

DAP `setVariable` on the `Registers` scope and MCP `set_register` share the
identical engine path (`TDebugSession.SetRegister` ->
`IDebugTarget.SetRegisterByName`) — proven, not assumed, by driving BOTH
surfaces:

- [x] **`DebuggerTests\DebugSessionTests.pas`, `TWin32RunControlTests`**
      (session/engine level, no DAP or MCP involved):
      `Win32_SetRegister_WritesAndReadsBack` (regression guard — passes with
      or without the fix, per the aliasing finding above) and
      `Win32_SetRegister_ExtendedRegister_Refused` (the real RED control:
      writing `R8` must be refused). RED control confirmed by temporarily
      falling back to the unfixed base implementation
      (`Result := inherited SetRegisterByName(...); Exit;`): the
      `WritesAndReadsBack` test still passed, `ExtendedRegister_Refused`
      failed with `Condition is True when False expected`.
- [x] **`DebuggerTests\McpE2ETests.pas`**: `SetRegister_Win32_
      WritesAndReadsBack` (regression guard) and `SetRegister_Win32_
      ExtendedRegister_Refused` (RED control, same shape as the session-level
      pair).
- [x] **`DebuggerTests\RegisterWriteDapTests.pas`** (new file — no DAP-level
      test of writing the Registers scope existed before this increment, on
      either bitness): `X64_SetVariable_Register_WritesAndReadsBack` (x64
      control), `Win32_SetVariable_Register_WritesAndReadsBack` (regression
      guard), `Win32_SetVariable_Register_ExtendedRegister_Refused` (RED
      control — asserts `success: false` and `body.error.format` names the
      register).
- [x] **A successful `setVariable` on a register answers with the new value**
      (`X64_`/`Win32_SetVariable_Register_ResponseCarriesNewValue`). Reported
      from the GUI: the write reached the register, but the response body went
      out empty, and VS Code — which replaces the displayed row with whatever
      the response carries — blanked the register, leaving the name with
      nothing after it. Both assert the response value is IDENTICAL to what
      the `Registers` scope reports for the same register, not merely
      non-empty. RED without the fix on both bitnesses, with the failure
      message carrying the literal `{}` that caused it.
- [x] **A 32-bit target reports a 32-bit register file**
      (`Win32_Registers_UseX86Names`): `EIP`/`ESP`/`EBP`/`EAX`..`EDI` present,
      `RIP`/`RAX`/`R8`/`R15` absent, and `EAX` rendered at 32-bit width
      (asserted by rendered LENGTH, so it holds whatever the register happens
      to contain — an earlier spelling of this check compared against a
      leading-zeros prefix and failed whenever `EAX` was legitimately small).
- [x] **The rename strands no caller**
      (`Win32_SetVariable_Register_AcceptsEitherSpelling`): a write named
      `RAX` still reaches `EAX` on a 32-bit target, while the row keeps the
      name the target owns.
- [ ] **Not verified on any Windows version other than the one this was
      measured on** (Windows 11, build 26200). The aliasing behaviour that
      makes the round-trip tests pass even without the fix is an OS
      implementation detail, not a documented Microsoft contract — the WOW64
      override is kept specifically so correctness does not depend on it
      holding elsewhere.
- [ ] **The "while running" gate on `setVariable`/`set_register` is
      unverified**, same racy-to-construct reason as sections M/R.

## T. Placeholder document disassembly (ASSEMBLY_LEVEL_DEBUGGING.md increment 5)

`DebuggerTests\PlaceholderDisassemblyTests.pas` — new file. Measured 2026-08-09
in VS Code: selecting a sourceless frame opens the adapter's placeholder
document, not the client's own Disassembly View, so the document's content had
to become real disassembly rather than only a paragraph of explanation
(`TDapServer.BuildPlaceholderDisassembly` / `FormatPlaceholderInstruction`,
appended by `SyntheticSourceText`). Mechanism: `DAP_DEBUGGER_ARCHITECTURE.md`,
"The document's content — increment 5".

Fixture: the SAME parked-worker-thread mechanism
`Test_SourcelessFrame_HasPlaceholderDocument` (`DebuggerTests.pas`, not
separately cataloged in this file) already proves reaches a genuinely
sourceless frame — `TestTarget.exe
--run-threads`, breakpoint at `THREADS_READY` (`TestTargetCore.pas`) on the
main thread, then a `stackTrace` on the spawned worker thread, which is parked
in `Sleep(INFINITE)` and therefore bottoms out inside ntdll/kernel32
(`Symbols = saNoSymbols`). `NoSourceStop.dpr` was not used here because at the
time an exception stop on it landed on a NAMED Delphi frame with real source,
never reaching the placeholder — that was `TrimRaisePlumbing` discarding the
faulting frame (fixed since; see section U and `DAP_DEBUGGER_ARCHITECTURE.md`,
"Frames versus the active frame"), not a property of the fixture. It would work
as a placeholder fixture today.

- [x] **`Win64_WorkerParkedInNtdll_PlaceholderShowsDisassemblyWithCurrentMarker`**
      — the header still names the `saNoSymbols` reason; the disassembly
      section is present; the current instruction carries both the `=>` marker
      and the `<-- current instruction` suffix; every line says `(no symbol)`
      (no Delphi provider covers ntdll/kernel32); the text never contains the
      literal phrase `Open Disassembly View` (that menu entry was never
      confirmed to exist) and does contain the hedged `where it offers one`
      phrasing instead. RED confirmed: reverting `DapServer.pas` to its
      pre-increment-5 state (via `git stash` on that one file — increments
      1-4/6 are committed, so this reverts exactly the increment-5 diff and
      nothing else) reproduces the OLD placeholder text (header only, no
      "Disassembly around the current instruction" section at all) and this
      test fails with `Condition is False when True expected. [placeholder
      must carry a disassembly section; got: No source available for this
      stack frame. ... Selecting a frame further down the call stack will
      open real source if any frame there has it.]` — the disassembly section
      is simply absent, exactly the pre-fix shape.
- [x] **`Win64_WorkerParkedInNtdll_HeaderStillNamesAddressAndStoppedState`** —
      regression guard on the UNCHANGED header text
      (`Test_SourcelessFrame_HasPlaceholderDocument`'s own assertions,
      duplicated here so a header regression fails two independent tests, not
      one). Passes with or without the increment-5 fix, by design — it is not
      a RED control.
- [ ] **The `saLoaded` case (debug info loaded, this address not covered) runs
      through the identical `BuildPlaceholderDisassembly` code path but was
      NOT exercised by an automated fixture** — no fixture parks a frame in a
      module that HAS debug info at an address the info does not cover. Only the
      header's `Reason`/`Advice` text differs between
      `saNoSymbols` and `saLoaded`, and that text is unchanged pre-increment-5
      code, unit-tested by construction of the existing `case F.Symbols of`
      branches, but the disassembly section specifically has not been observed
      rendering for a `saLoaded` frame.
- [ ] **The per-instruction "line known, file not on disk" annotation
      (`FormatPlaceholderInstruction`'s `ResolveSourcePath` branch) is
      implemented but not independently exercised by a test.** Neither the
      `NoSourceStop.dpr` scenarios nor the parked-worker fixture surfaces a
      nearby instruction whose line IS known but whose file cannot be
      resolved — building a fixture for exactly that byte pattern was out of
      scope. The code path is the SAME one `disassemble`'s `BuildDapInstruction`
      already uses for `location.name`/`line` (increment 6), which IS
      exercised by the `disassemble` request tests (section M).
- [ ] **The Zydis-unavailable fallback (`Disasm.Available = False`) is not
      exercised at the DAP-adapter-process level**, same limitation increment
      1 already recorded: `ZydisApi.ZydisTryLoad` is a one-shot,
      process-wide latch with no launch-config knob to force it unavailable
      from outside the process, and the adapter runs as a separate executable
      from `RunTests.exe`. Verified by code inspection instead: `if not
      Disasm.Available then Exit('Disassembly is unavailable: ' +
      Disasm.StatusText + '.');` is the first statement after constructing
      the disassembler, identical in shape to `HandleDisassemble`'s own
      (tested) refusal.

## U. Exception stops: which frames exist vs which frame answers

Three tests, covering the separation described in
`DAP_DEBUGGER_ARCHITECTURE.md`, "Frames versus the active frame". They exist
because one mechanism — `TSourceResolver.TrimRaisePlumbing` deleting the leading
frames — was carrying three unrelated responsibilities at once (which frames
exist, where the editor points, which frame locals come from), so fixing any one
of them broke the others.

- [x] **`ExceptionInOsCode_TopFrameIsTheFaultingFrame`**
      (`DebugSessionTests.pas`) — `NoSourceStop.exe -os` faults inside ntdll's
      `RtlMoveMemory` reading address `$1`. Frame 0 must name `ntdll` and carry
      no source, AND the stack below it must still reach `NoSourceStop.dpr`.
      Both bitnesses, failures collected. Before the fix frame 0 was the calling
      Delphi frame, with source, and the ntdll frame was absent from the array
      entirely.
- [x] **`ExceptionStop_DefaultFrameServesLocals_ExplicitSelectionWins`**
      (`DebugSessionTests.pas`) — the ordinary Delphi `raise` path
      (`TestTarget --run-deep-nested-raise`), which is what regressed when the
      trim stopped discarding plumbing. Asserts, per bitness: `RnInner` is on
      the reported stack at an index **> 0** (the frames above the raise site
      were not discarded); `DefaultFrameIndex` equals that index; `GetLocals`
      with no selection returns `RnInnerVal`; a frame-less `Evaluate` resolves
      `RnInnerVal`; `SelectFrame(0)` does NOT return it (explicit selection of
      the RTL/OS frame wins); `ClearFrame` restores the default.
      **RED confirmed**: `git stash push -- DebuggerCore/DebugSession.pas` (which
      leaves the new by-name trim in `SourceResolver.pas` in place, reproducing
      exactly the intermediate broken state) + rebuilt runner → fails with
      `Win64: RnInnerVal missing with no frame selected -- locals did not come
      from the default frame | Win32: <same>`. The `DefaultFrameIndex`
      assertion has to be commented out for the control to compile, since the
      property does not exist without the fix.
      Note on the evaluate assertion: it reads a local of the RAISING procedure,
      not of an enclosing one — the x86 nested-proc static link reaches only one
      level up, so `RnOuter` fails on Win32 for a reason unrelated to frame
      selection (measured; `DeepNested_LocalsResolveAtExceptionStop` asserts
      `RnOuter` and is Win64-only for the same reason).
- [x] **`Test_ExceptionStop_LocalsDefaultToRaisingFrame_ScopesFrameWins`**
      (`DebuggerTests.pas`, runs in BOTH the mono and BPL fixtures) — the same
      rule over the DAP wire. `variables` on the Locals scope BEFORE any
      `scopes` request returns `RnInnerVal` (the default frame);
      `scopes(frameId: 0)` then does NOT; `scopes(frameId: <RnInner's id>)`
      does again. Also asserts `RnInner`'s frame id is > 0, so the test fails
      rather than passing vacuously if the plumbing frames are ever discarded
      again.

Diagnostics: `DevTools\ExceptionStopProbe.exe <exe> <sourceRoot> [-args ...]
[-filters ...] [-frames N]` drives a real `TDebugSession` to the first exception
stop and prints the RAW walk, the REPORTED stack, the locals with no frame
selected, and the locals of each of the first N frames selected in turn. That
side-by-side view is what separates "the stack is wrong" from "the stack is
right and the wrong frame answered".

## V. Stepping at an exception stop

Twelve tests in `DebuggerTests\ExceptionStepTests.pas`, a NEW fixture rather than
an addition to `DebuggerTests.pas` / `DebugSessionTests.pas`. Debuggee:
`DevTools\Fixtures\ExcNestFixture.dpr` (both bitnesses, built by
`DevTools\build_exc_fixture.bat`, which `build_and_run.bat` and
`build_target.bat` now call). It is REUSED rather than replaced by new scenarios
in `TestTarget`, which would shift RSM import indices and marker ordering.

The fixture gained one orthogonal switch for this work, `-nofinally`: without it
every scenario lands in the intervening `try/finally`, because that is the
handler the exception reaches first — which is the correct answer, and also
makes the `except` variants unreachable as a landing site. Combined with
`-bare` / `-two` / `-av` it gives every construct on both bitnesses.

Each test is bitness-parameterised and COLLECTS its failures (both executables
are called `ExcNestFixture.exe`, so a message built from the file name cannot
identify the bitness).

- [x] **`Win64_Step_LandsInTheFinallyThatRunsFirst`** — no switches: the step
      lands on the `finally` funclet (`FINALLY_BLOCK`), not on the outer
      `except`, because the finally receives the exception first.
- [x] **`Win64_Step_LandsInTheOnClauseBlock`** — `-nofinally`, lands on the
      `on E: Exception do` line.
- [x] **`Win64_Step_LandsInTheBareExceptBlock`** — `-nofinally -bare`. The
      landing line is the last line of the `try` body, which is what the line
      table attributes that address to (`EH_FORMAT_NOTES.md`); asserting the
      `except` statement's own line would fail on working behaviour.
- [x] **`Win64_Step_LandsInTheMATCHINGClauseOfTwo`** — `-nofinally -two`, whose
      FIRST clause is `on E: EAccessViolation` and does not match. Landing on
      clause 0's line would mean the debugger took entry 0 of the table.
- [x] **`Win64_Step_AccessViolation_LandsInTheFinally`** — `-av`, a hardware
      fault: no Delphi exception object, a different code, and frame 0 IS the
      faulting instruction.
- [x] **`Win64_StepIntoAndStepOut_LandWhereStepOverDoes`** — all three kinds mean
      the same thing at an exception stop.
- [x] **`Win64_Step_DoesNotRefireTheSameException`** — the reported symptom
      stated as a property. **Must use `-av`**: a Delphi `raise` is a software
      `RaiseException` call, so swallowing it lets the call return and the step
      wanders off instead of looping. Only a hardware fault re-executes.
- [x] **`Win32_Step_LandsInTheOnClauseBlock`**, **`Win32_Step_LandsInTheMATCHINGClauseOfTwo`**
      — the only x86 construct whose block address is derivable (the
      `@HandleOnException` stub is followed by a clause table of absolute VAs).
- [x] **`Win32_Step_TryFinally_RefusesAndNamesTheConstruct`**,
      **`Win32_Step_BareExcept_RefusesAndNamesTheConstruct`** — the deliberate
      negative half. Asserts the step is REFUSED and that the reason names the
      construct (`try/FINALLY`, `bare \`except\``), the stub
      (`HandleFinally` / `HandleAnyException`) and the words `not derivable`.
- [x] **`Step_AtAnOrdinaryStop_IsStillFireAndForget`** — the routing must be
      invisible at a plain breakpoint stop, on both bitnesses.

**RED confirmed** by restoring the defect in two places at once —
`TDebugSession.PostSourceStep`'s `StoppedOnUndeliveredException` routing disabled
AND the three step handlers' `ReleasePendingEvent(ContStatus)` changed back to
`ReleasePendingEvent(DBG_CONTINUE)` — then rebuilding the runner. **11 of 12 go
red** (10 in one pass, plus `Win64_Step_DoesNotRefireTheSameException` once it
was switched from a Delphi raise to `-av`; the twelfth is the no-regression
surface test and is correctly unaffected):

```
Win64_Step_LandsInTheFinallyThatRunsFirst   landed outside the fixture source: (blank)
Win64_Step_LandsInTheOnClauseBlock          landed outside the fixture source: (blank)
Win64_Step_LandsInTheBareExceptBlock        landed outside the fixture source: (blank)
Win64_Step_LandsInTheMATCHINGClauseOfTwo    landed outside the fixture source: (blank)
Win64_Step_AccessViolation_LandsInTheFinally
        the step did not report a step stop (reason 3) at ExcNestFixture.dpr:52
Win64_StepIntoAndStepOut_LandWhereStepOverDoes   (both kinds, same as above)
Win64_Step_DoesNotRefireTheSameException
        Expected [0] but got [1] the step produced another EXCEPTION stop at
        ExcNestFixture.dpr:52 instead of a landing (the exception was swallowed
        and the faulting instruction re-executed)
Win32_Step_LandsInTheOnClauseBlock          landed on line 56, expected 84
Win32_Step_LandsInTheMATCHINGClauseOfTwo    landed on line 56, expected 110
Win32_Step_TryFinally_RefusesAndNamesTheConstruct
        the step was ACCEPTED and landed at ExcNestFixture.dpr:56 -- it was
        expected to refuse, because the block address is not derivable here
Win32_Step_BareExcept_RefusesAndNamesTheConstruct   (same)
```

`ExcNestFixture.dpr:52` is `AV_SITE` — the faulting instruction itself, reported
again as an exception: the field-reported loop, reproduced. Line 56 is the `end;`
of `Level3Raise`: a plausible-looking stop that is simply wrong, which is what
the x86 refusals replace.

Diagnostics: `DevTools\ExcHandlerProbe.exe <exe> [-args ...] [-plant] [-tf]` —
see `EH_FORMAT_NOTES.md`.

## W. Watchpoints on a computed address (DATA_BREAKPOINTS_PLAN.md, case 4)

`DebuggerTests\DataBpExpressionTests.pas` — new file. A watch target used to have
to be a NAME (a variable to right-click) or a literal address a caller already
knew. That covers "who changes this variable" and misses what watchpoints are
mostly reached for: *who is writing past the end of my array*, where the
interesting byte belongs to no variable at all.

Fixture: `TestTarget --run-databp-buffer` (`RunDataBpBufferFixture`).
`GDataBpBuffer` is a `TDataBpGuardedBuffer` record — `Before`, `Data[0..7]`,
`After` — because only a record guarantees the guard bytes sit either side of the
buffer; the linker orders separate globals as it pleases. `DataBpBufferWriter`
writes `Data[0]`, then `Data[High(Data)]` (correct), then `After` (the overrun).

- [x] **`supportsDataBreakpointBytes` is advertised**
      (`Capability_DataBreakpointBytes_IsAdvertised`). Without it VS Code never
      offers "Add Data Breakpoint at Address", and the whole path is unreachable
      from the GUI however well it works underneath.
- [x] **An expression naming a cell no variable names arms and fires**
      (`Expression_LastArrayElement_ArmsAndFires`):
      `GDataBpBuffer.Data[High(GDataBpBuffer.Data)]`. Also asserts the width came
      from the ELEMENT type (1 byte, not the pointer width a bare address would
      have defaulted to) and that the stop names the EXPRESSION, not the hex
      address it resolved to.
- [x] **The overrun, through the address form**
      (`AddressForm_ByteAfterTheBuffer_ArmsAndFires`): `asAddress` +
      `bytes: 1`, exactly what the VS Code panel sends. Asserts old -> new and
      that the stop names the writing thread.
- [x] **A width the hardware lacks is refused by name**
      (`AddressForm_UnsupportedWidth_Refused`): 3 bytes is not rounded up to 4 —
      the hardware ignores the low address bits, so a widened watch silently
      covers a neighbouring cell.
- [x] **An odd address is no longer refused for alignment nobody asked for**
      (`OddAddress_ChoosesAFittingWidth_InsteadOfRefusing`). RED before
      `WidthFittingAddress`: a literal always took the pointer width and was then
      refused unless 8-aligned.
- [x] **...but an explicitly requested width is honoured strictly**
      (`OddAddress_WithExplicitWiderWidth_Refused`): 8 bytes at an address that
      cannot be 8-aligned is refused, never narrowed behind the caller's back.
- [x] **An unknown bare NAME stays "unresolved symbol"**
      (`UnknownBareName_StillRefusedAsASymbol`) — never reinterpreted as
      arithmetic that happens to evaluate to something.

Three evaluator defects were found by these tests and fixed in `ExprEval`, so
`evaluate` and every watch expression gained them too: `@` parsed only a bare
`Primary` (so `@Rec.F`, `@Arr[I]`, `@(expr)` all failed); a STATIC array field
was missing from the "is this value indexable" test, so `Rec.Buf[1]` was reported
as `<Buf not found>` after `Rec.Buf` had just resolved as an array; and
`High`/`Low`/`Length` did not know static arrays, whose bounds are in the type.
The probe that established all three, before any of them were fixed, was a
throwaway test that evaluated nine spellings and failed with the results — worth
repeating rather than guessing at a parser from the outside.

## What the suite does NOT prove (2026-08-08)

Coverage-honesty notes. Each records a place where a green run is weaker evidence
than it looks, so that a future session does not read the suite as a guarantee it
never gave. Recovered from `TASK_RESUME.md` when that file was cut back.

- **The step-at-an-exception refusals are covered only for the cases the fixture
  can produce.** Section V proves the two x86 constructs and the "all provable"
  x64 paths. Three refusal branches have NO fixture: an x64 frame that CAN
  receive the exception and declares a **non-Delphi** language handler while
  still having a source line (every such frame in the fixtures is `ntdll` /
  `kernelbase`, which has no source and is therefore skipped rather than refused
  on); an x64 scope table that fails validation; and "no frame protects this code
  at all" — Delphi's generated main block always installs an unconditional
  `except`, so the walk always finds one. Those three are correct by
  construction against `EH_FORMAT_NOTES.md`, not by test.
- **The `smToHandler` re-fire guard is belt-and-braces and is not what the green
  suite proves.** With the exception delivered the faulting instruction is not
  re-executed, so the loop is structurally gone; the guard exists for the case
  where the planted block is never reached and the same exception arrives again
  (a loop in the debuggee's own code). No fixture produces it.
- **A step whose planted block is never reached does not stop at all.** If the
  first receiving frame's `on` clause does not match — possible only when a
  frame's scope entry covers the PC but its clause table is exhaustive against
  the raised class — the exception passes on to a frame the plan did not cover
  and the step runs free until the next breakpoint or exit. It is not a WRONG
  answer, but it is not a refusal either, and nothing in the suite exercises it.
- **`Win32_RecordAndDynArrayExpansion_MatchWin64` asserts cross-bitness PARITY of
  the result, not that the live-RTTI path served it.** The record could have been
  expanded through TD32 members instead. The RTTI table-walk fixes
  (`TFieldExEntry`, `TRecordTypeField`, `tkDynArray` `elType2`, the parent-info
  walks) are correct by construction against the RTL's own declarations in
  `System.TypInfo` — not by test. It is nonetheless the guard the suite is credited
  with for the whole pointer-width RTTI sweep.
- **The x86 field failure condition cannot be reproduced here.** It needs a caller
  in a module dbghelp knows nothing about, and dbghelp knows every test module.
- **`HandleSmOverStep`'s entry-RSP handling is defensive, not covered.** Stepping
  over from the RAW function-entry address is no longer reachable — neither a
  breakpoint nor a step-into parks there.
- **The "symbols still indexing" retry path has no fixture and cannot get one.**
  The window is real at a `stopAtEntry` stop, but the frames blank there are
  `kernel32.dll` / `ntdll.dll` — genuinely `saNoSymbols` — so no name was ever
  observed to appear on retry. The fixture MAP index finishes far faster than any
  frame it would resolve is needed.
- **A named-frame-count improvement cannot be measured in the fixtures.** Every
  fixture stop has a breakpoint in the module it stops in, and the conservative
  `ContainsSourceFile` makes any breakpoint load every module, so old and new code
  behave identically.
- **The live-attach test is gated by `HaveDebugPrivilege` and silently SKIPS when
  not elevated.**
- **`SkipIfNoRsm(reason)` skips ONLY the mono scenario** under `NO_RSM=1`; BPL and
  RSM-on mono still execute, so a green `NO_RSM` run is not proof that those
  capabilities work without RSM.
- **A green `RunTests.exe` proves the disassembly SEAM, not decoder
  coverage.** `DisassemblerTests.pas`'s positive-decode tests (increment 3)
  check four known instructions on each bitness -- real, but tiny. The
  actual coverage claim ("Zydis agrees with an independent oracle at scale")
  comes from `DevTools\DisasmCoverage.exe`, a separate measurement tool that
  is NOT part of `RunTests.exe` and does not run on every suite invocation
  -- its numbers are only as current as the last time someone re-ran it
  (`DISASSEMBLY_PLAN.md` "Verified in increment 3 — Half B" records when).
  Within that tool's own numbers: the export-anchored methodology (used for
  `rtl290.bpl`/`vcl290.bpl`, which ship with no debug info) has an
  UNVERIFIED span end, so its `length`-divergence count is dominated by
  spans running into data past a short routine's real end, not decoder
  disagreement -- stated in the tool's own output, not silently absorbed
  into a clean-looking percentage. And a single UNSAMPLED full sweep of the
  largest binary surfaced a genuine dumpbin-side scale artifact (478 083
  `boundary` divergences that vanish at a 33% sample of the SAME binary) --
  a reminder that the oracle itself can have limits worth measuring, not
  just the thing being checked against it.

### Fixture-design rules that follow from the above

- **An argument containing ZERO BYTES silently makes an over-wide read look
  correct.** `Win32_StepOver_AdvancesWithinTheSameFrame` could never have caught
  the over-wide return-address read: it steps over
  `W.StepIntoProbe(1234, 'probe-str', 2.5)`, where on x86 the first three
  arguments travel in EAX/EDX/ECX and the fourth pushed value is the Double 2.5,
  whose low 4 bytes are ZERO — so an 8-byte read of a 4-byte slot produced the
  RIGHT address by accident. The replacement fixture `RunStepOverStackArg` passes
  `Integer($5EEDBEEF)` precisely so that every byte is non-zero. Apply this to
  every width or bitness regression fixture; the host-vs-target pointer-width class
  of bug is explicitly expected to recur.
- **`RunMainObjectScenarioPortable` runs only inside the BPL on purpose.** In the
  exe the `.dpr` MAIN_* block already exercises those markers, and running the
  portable proc there as well flips the `MAIN_GCOUNTER`-before-`STUFF_PUBBUMP`
  first-hit order that `Test_Bug16` depends on. Do not "tidy it for parity".

See `TRAPS.md` for the operational rules around running the suite.
