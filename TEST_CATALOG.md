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
- [x] Integer / LongInt / Int32
- [x] Cardinal / UInt32
- [x] Byte / ShortInt
- [x] Word / SmallInt
- [x] Int64 / UInt64
- [x] Single / Double / Currency
- [x] Boolean (1-byte)
- [x] ByteBool / WordBool / LongBool (TD32 $0031 named-subrange NameIdx
      pickup -> declared alias preserved -> True/False display)
- [x] AnsiChar / Char (WideChar)
- [x] AnsiString / UnicodeString
- [x] ShortString (TD32 $0033 named-array NameIdx pickup + inline
      length-prefixed value decode)
- [x] WideString (TD32 $0039 managed-type tag)
- [ ] RawByteString / UTF8String (covered for property GET; local display missing)
- [x] TDateTime (Double-backed)
- [x] TGUID (16-byte record literal)
- [ ] PChar / PAnsiChar / PWideChar with non-string content
- [x] PChar with string content (`^Char` alias) -- decoded via
      FormatStringByPointer extension
- [x] **Critical regression guard**: Integer = 1 next to zeroed
      neighbour locals must surface as Integer, not as varNull / TVarRec.
      Now enforced by `Test_Types_TrickyOne_NotMisDecodedAsVariant`
      (TVarRec augment denylist + Variant pattern slot-size guard).

### A.2 Enums and sets
- [x] Enum literal value display (`wmRunning`)
- [x] Set value display (`[wmRunning, wmIdle]`)
- [x] Enum whose ordinal exceeds byte (`Test_Types_BigEnum_DisplaysName`)
- [ ] Set whose element enum lives in a different unit
- [x] Non-trivial set decode (`Test_Types_NonEmptySet_Display`)
- [x] Empty set displays as `[]` (`Test_Types_EmptySet_Display`)
- [ ] Set with `..` ranges in source (compiler may expand differently)

### A.3 Records
- [x] Flat record fields
- [x] Nested record field expansion
- [x] Packed record locals-view expansion (`Test_Types_PackedRecord_FieldsVisible`)
- [x] Managed-field record locals-view expansion
      (`Test_Types_ManagedRecord_FieldsVisible`)
- [ ] Record with methods (modern Delphi)
- [ ] Record with class operators (body steppable -- partial)
- [ ] Anonymous record `record A,B: Integer end`

### A.4 Arrays
- [x] Static array `array[0..N] of T`
- [x] Dynamic array `TArray<T>` / `array of T` (Integer)
- [x] Dynamic array of class/record as a FIELD (RTTI TypeInfo path, e.g.
      MRec.Tags) -- expands via ExpandDynArray
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
- [ ] Open array parameter (`array of const`)
- [x] Open array parameter `array of T` -- `A[i]` indexing in a watch
      (`Test_E2_OpenArrayParam_Element`; `^Element` base, DerefPtr)

### A.5 Classes
- [x] Class instance, declared and runtime type match
- [x] Class instance, derived shown as declared not base
- [x] Null class reference displays as `nil`
- [x] Self visible in nested proc of class method
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
- [x] `^TClass` displays as class (nil for 0, $addr (RuntimeClassName) for non-zero)
- [x] `^TRecord` (typed pointer-to-record) display (covered via PtrRecord test)
- [x] Untyped `Pointer` display
- [x] Pointer deref `P^` in watch (`Test_Types_PtrPrimitive_DerefMatches`)
- [x] PChar string content covered above (A.1)

### A.7 Variants
- [x] varEmpty
- [x] varNull
- [x] varInteger
- [x] varBoolean
- [x] varDouble
- [x] varInt64
- [x] varString / varUString
- [x] varDate
- [x] VarArray 1D / 2D shape and expansion (hover/watch + locals view)
- [x] Variant in nested proc auto-decoded
- [x] Const Variant parameter deref through pointer
- [x] Variant parameter mis-tagged as small int recovered
- [x] **regression**: Integer = 1 next to zeroed neighbours must NOT trigger varNull recovery
- [ ] varByRef (Variant containing a reference to another Variant)
- [ ] OleVariant
- [ ] varDispatch (IDispatch)

### A.8 Other reference types
- [x] Interface variable LIVE: `Test_Types_Interface_Live_HasClassName`
- [x] Interface NIL: `Test_Types_Interface_Nil_DisplaysAsNil`
- [x] Method pointer NIL: `Test_Types_MethodPointer_Nil` (TD32 $0034 ->
      `procedure of object` label -> nil-shape display)
- [x] Method pointer LIVE / anonymous proc (partial -- pending real call dispatch)
- [ ] Anonymous method reference: `reference to procedure`
- [ ] TextFile / typed File (legacy)

---

## B. Parameter passing

- [x] Value param (Integer, String, Variant, Const Variant, Var Variant)
- [x] Var param `var X: Integer` (modifies caller's slot)
- [x] Out param: `Test_OutParam_AfterAssignment_ReadsBack` (TD32 `^T`
      promoted to lkVarParam; deref + width-correct read)
- [x] Const param: `Test_ConstParam_ReadsValue`
- [x] Default parameter: `Test_DefaultParam_TakesDefaultValue`
- [ ] Open array parameter (`array of const`)
- [ ] Untyped var parameter (`var X` without type)

---

## C. Frame layout and call kinds

- [x] Top-level free proc
- [x] Class method (Self visible)
- [x] Class function with Result
- [x] Constructor (StepInto_Ctor)
- [x] Destructor side-effect verified (BP in `Destroy` body)
- [x] Nested proc 1 level
- [x] Nested proc inside class method (`TMenuRepro.LoadMenu.CreateNodes`)
- [x] Nested proc inside nested proc (2 levels): own local,
      parent (`Mid.MidTag`), grandparent (`RunDeepNesting.OuterTag`).
      Multi-Z Itanium parser + NameToRva qualified-fallback wired.
- [ ] Anonymous method body invoked via `TThread.CreateAnonymousThread`
- [ ] Generic method body
- [x] Property setter body: `Test_PropertySetterBody_NewValueVisible`
- [x] Operator overload body: `Test_OperatorBody_StoppableAndArgsVisible`
- [ ] Class constructor body
- [ ] Initialization / Finalization sections

---

## D. Expression evaluation (watch / hover)

- [x] Identifier (local, global, Self.X implicit)
- [x] Field access `a.b.c`
- [x] Indexed property `a.Level[0]`
- [x] Method call (no args, with args, chained)
- [x] Boolean ops, comparisons, precedence, unary minus
- [x] Arithmetic int and float mix, div/mod
- [x] String concat
- [x] nil compare
- [x] Cast: `Integer(x)`, class cast, TObject upcast
- [x] `is` and `as`
- [x] Length, High, Low, SizeOf, Ord
- [ ] @ address-of operator on locals
- [x] Pointer dereference `P^`: `Test_Types_PtrPrimitive_DerefMatches`
- [x] Set algebra `[a] + [b]` union, `-` difference, `*` intersection
      (`Test_BL_Eval_SetLiteralArith`)
- [x] In: `wmRunning in S`
- [x] Method call with a side effect persists across evals
      (`Test_BL_Eval_MethodSideEffect`)
- [x] Deref of unmapped memory fails gracefully, session survives
      (`Test_BL_Ptr_UnmappedRead`)
- [ ] Inherited call (`inherited Foo`)
- [x] Parameterless system funcs (Now)
- [ ] Long dot chain `Self.A.B.C.D.E.F`
- [ ] Anonymous record literal
- [ ] Range expression `Low(T) .. High(T)`

---

## E. Stepping and breakpoints

- [x] Set / clear BP at source line
- [x] Conditional BP
- [x] Hit-count BP
- [x] Log point BP
- [x] Step over
- [x] Step over a call that hits a BP in the callee -- BP wins
      (`Test_BL_Step_OverCallThatHitsBp`)
- [x] Step into ctor
- [x] Step into a no-debug-info (RTL) call degrades to step-over
      (`Test_Step_IntoNoDebugInfo_StepsOver`)
- [x] Step out from nested proc
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

- [x] Pause on Delphi exception (filter on)
- [x] Pause filtered by class match
- [x] Hover E.ClassName / E.Message inside on-clause
- [x] Expand E in variables view
- [x] Exception class DEFINED in a BPL -- E.ClassName/E.Message in its
      handler via runtime VMT (`Test_BL_Exc_BplDefinedClass`)
- [x] Re-raise (bare `raise;`) -- second exception stop, propagation to the
      outer handler (`Test_BL_Exc_ReRaise`)
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

---

## G. Threads

- [x] Enumerate threads and read names
- [x] Per-thread locals: BP on a worker fires on that worker, its frame
      exposes the worker's own local (`Test_Threads_BpOnWorker_LocalVisible`)
- [x] Exception raised on a worker thread surfaces on that thread; the
      worker's stack is inspected (`Test_Threads_ExceptionInWorker`)
- [ ] Step on a specific thread while others stop

---

## H. Modules and debug info sources

- [x] EXE TD32 + RSM
- [x] EXE MAP fallback
- [x] BPL TD32 -- BP hits
- [x] BPL TD32-only BP hits
- [x] BPL loaded after launch (deferred `LoadPackage`; BP set before load
      binds when the module arrives -- Test_Bpl_BreakpointHits)
- [x] DCP for unit symbols not in EXE TD32 (BPL params A/B via .dcp)
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

---

## I. Real-world / SampleApp quirks

- [x] CurrentLevel := 1 in nested proc shows as Integer 1 (not Variant `<null>`)
- [x] CurrentParent := nil in nested proc shows as `nil` (not `0 (0x0)`)
- [x] Outer-method local with ancestor mis-tag (TNoRefCountObject -> TCachedMenu) augments to the leaf class
- [x] Cache.Level[0] indexed-property watch resolves on a class whose
      member list comes from RSM, not TD32 (TD32 may report True/0 members)
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
- [x] Gap enum (`geA=5,geB=10,geC=20`) name display
- [x] Empty string `''` renders empty, no error
- [x] Negative Integer / Int64 signed display
- [x] Float NaN / Infinity display
- [x] Embedded-NUL string (`'a'#0'b'`) -- surfaces content
- [x] Emoji / surrogate-pair string -- no read failure
- [x] Variant record (`case ... of`) expandable
- [x] Interface method call resolves (`Thing.Name`)
- [x] Cyclic object graph (Root.Child.Parent=Root) -- expand without hang
- [x] Object mid-construction (BP in ctor; FirstField set, SecondField 0)
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

- [x] Class field string
- [x] Nested record field double
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

- [x] Class instance clean format
- [x] String field no token error
- [x] Integer no redundant unsigned suffix
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

## What the suite does NOT prove (2026-08-08)

Coverage-honesty notes. Each records a place where a green run is weaker evidence
than it looks, so that a future session does not read the suite as a guarantee it
never gave. Recovered from `TASK_RESUME.md` when that file was cut back.

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
