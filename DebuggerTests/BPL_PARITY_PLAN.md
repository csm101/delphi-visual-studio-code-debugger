# BPL parity plan — run every DebuggerTests test in BOTH monolithic-exe and BPL scenarios

Goal: every `TDebuggerTests` test runs against `TestTarget.exe` (monolithic) AND
against `TestHost.exe + TestSubject.bpl` (the SAME subject code compiled into a
runtime package), via a fixture subclass registered twice. Source from the
`bpl-parity-inventory` workflow (run wf_90042d53-498).

## Architecture

- The subject code that most tests inspect currently lives in **TestTarget.dpr's
  program body** (~10 types + ~50 Run*/helper procs + globals GSink/GCounter/
  GPkgObj/GUsesGraph). A package file cannot hold program-body code → extract it
  into a new unit **TestTargetCore.pas**.
- TestTargetCore exports `procedure RunAllScenarios;` (body = the old .dpr main
  block MINUS the exe-only MAIN_* inline-var scenario; `GSink := TSink.Create`
  first; `FindCmdLineSwitch` dispatch kept verbatim — a loaded BPL shares the
  host process command line; preserve order: GUsesGraph:=444 before any
  LoadPackage; inside RunNestedClassMethodTest RunCollider BEFORE
  TMenuRepro.LoadMenu).
- **TestTarget.dpr** (mono) shrinks to `uses TestTargetCore;` + main block =
  `RunAllScenarios;` then the irreducibly exe-only RSM-main-block scenario
  (GCounter, `var TheWidget`, `var TheStuff`, Res, Compute, X, ComputeNested,
  markers MAIN_GCOUNTER / MAIN_AFTER_NESTED). MAIN_FIRST_LINE moves to the GSink
  line inside RunAllScenarios.
- **TestSubject.dpk** (`{$RUNONLY}`, `requires rtl`, `contains` TestTargetCore +
  13 subject units) → TestHost\Win64\Debug\TestSubject.{bpl,map,rsm,dcp}.
- **TestHost.dpr**: thin GUI host, `H:=LoadPackage('TestSubject.bpl'); @Fn:=
  GetProcAddress(H,'RunAllScenarios'); Fn;` — does NOT statically use any subject
  unit (so subject classes exist only in the BPL).
- NoDebugLib.dpr stays a plain no-debug DLL; copied next to BOTH exes.

## Fixture refactor

- `TTestScenario=(tsMono,tsBpl)`; `function Scenario: TTestScenario; virtual;`
  (base tsMono). Host*/Subject* path helpers branch on Scenario. sourceRoot stays
  TargetDir in BOTH (shared subject .pas).
- Central `LaunchTarget` (record `TLaunchSpec` {Args, ModuleSet, CustomModules,
  StopAtEntry, ExceptionRulesJson, GlobalRulesPath} + a convenience overload for
  shapes A/B/C). In tsBpl, ALWAYS inject `['TestSubject.bpl',SubjectMap,Rsm,Dcp]`
  as the first module. Route StartSession's launch (DebuggerTests.pas:940) through it.
- DapClient: add optional trailing `Modules` param to LaunchWithRules /
  LaunchWithGlobalRules (emit same `modules` JSON as 7-arg Launch).
- Double registration: `[TestFixture] TDebuggerTestsBpl = class(TDebuggerTests)`
  overriding Scenario→tsBpl. VERIFY DUnitX enumerates inherited [Test] methods on
  the subclass BEFORE mass-converting (risk #1).

## Skip list (exe-only in BPL)

Mechanical rule: every test whose stop marker is **MAIN_FIRST_LINE /
MAIN_GCOUNTER / MAIN_AFTER_NESTED** calls `SkipIfBpl(reason)` (first statement) —
those markers live only in the program main block. ~96 such tests; SKIP all
EXCEPT the ~17 Tier-2 re-vehicled ones.

- Tier-1 SKIP (TheWidget/TheStuff main-block inline locals): all `Test_Eval_PropGet_*`
  (24), the TheWidget eval/method/cast/is/as/in tests, the TheStuff
  watch/hover/NonRtti tests, Test_ClassFields_ExpandW, Test_VarView_*, etc.
- Tier-1 SKIP D (marker IS the feature): Test_BL_Bp_FirstLine,
  Test_BL_Exc_DuringEvaluate, Test_BL_Eval_MethodSideEffect.
- Tier-3 SKIP-with-TODO PROTOTYPE (portable feature, anchor not yet re-vehicled):
  Test_GlobalVar, Test_Attach_BasicSession, Test_Attach_ByProcessName,
  Test_BL_Attach_SetBpAfterAttach, Test_BL_Ptr_UnmappedRead.
- Tier-2 RE-VEHICLE (must run in BOTH; move stop MAIN_GCOUNTER→EVAL_BODY, no skip):
  Test_Eval_Arith_Div_Mod, _FloatMix, _Precedence, _Bool_AndOrNot, _Cast_FloatToInt,
  _Cast_IntToFloat, _Cast_IntegerOfChar, _FreeProc_IntegerReturn, _FreeProc_StringReturn,
  _In_LiteralSet, _Intrinsic_SizeOf, _ParameterlessSystemFunc_Now, _SetLiteral_Empty,
  _StringConcat, _True_False.

## Step order (REGRESSION GATE at step 3: mono suite green before any BPL work)

1. Create TestTargetCore.pas (cut types/procs/globals out of TestTarget.dpr;
   add RunAllScenarios + `exports`). CRLF.
2. Shrink TestTarget.dpr (uses TestTargetCore; main = RunAllScenarios + MAIN_* block).
3. **GATE**: build_target + run_tests → existing suite must stay green. Fix fallout.
4. TestHost\TestSubject.dpk + .cfg; build; confirm RunAllScenarios export.
5. TestHost\TestHost.dpr + .cfg; build; run standalone, loads BPL, clean exit.
6. build_host.bat (build dpk+host, copy TestSubject.bpl + TestPackage*.bpl +
   NoDebugLib.dll next to TestHost.exe); wire into build_and_run.bat after TestTarget.
7. Scenario plumbing in TDebuggerTests (+ TestTargetCore.pas in Bp() candidates).
8. TLaunchSpec + ResolveModules + LaunchTarget overloads; route StartSession; extend DapClient.
9. Convert all 46 launch sites to LaunchTarget. Rebuild runner; mono suite green (pure refactor).
10. SkipIfBpl helper; insert in every Tier-1+Tier-3 skip test.
11. Re-vehicle ~15 Tier-2 tests MAIN_GCOUNTER→EVAL_BODY; mono suite green.
12. `TDebuggerTestsBpl` subclass; verify inherited-test discovery FIRST.
13. Full build_and_run; triage BPL failures; both fixtures green (skips report SKIP[bpl]).
14. Update PROJECT_STATE / DAP_DEBUGGER_ARCHITECTURE / TASK_RESUME (+ Tier-3 TODO PROTOTYPE).

## Risks (watch)

1. DUnitX inherited-test discovery on subclass (verify @ step 12; fallback: gen override stubs).
2. rtl.bpl coexistence: TestHost static + LoadPackage(requires rtl) → two RTLs.
   If MM/RTTI faults, build TestHost with runtime packages (`-LUrtl`).
3. Cross-BPL exception flow (E/F shapes) needs the injected TestSubject module.
4. Source-line mapping TestTargetCore.pas → TestSubject.bpl (image-base shifted); verify early.
5. exports name 'RunAllScenarios' undecorated for GetProcAddress; exe tolerates the export.
6. Re-vehicling Tier-2 changes eval scope; re-assert in mono (step 11).
7. init/finalization timing shifts (process-start → LoadPackage) for the 6 sampler units.
8. Co-located binaries beside TestHost.exe (NoDebugLib.dll, TestPackage*.bpl).
9. Double-BPL stacking (TestSubject + TestPackage simultaneously).
