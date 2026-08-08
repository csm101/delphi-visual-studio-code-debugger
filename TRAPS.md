# Traps

Operational rules that prevent wasted work. Each one is here because it already
cost time at least once.

This is a living document, extracted from `TASK_RESUME.md` on 2026-08-08 when that
file was cut back to being a cursor again. `TASK_RESUME.md` carries only the traps
of the task IN FLIGHT; anything that outlives a task belongs here.

Read it before an unfamiliar kind of change; grep it when something behaves
absurdly.

## Running the suite

- **Never edit `DebuggerTests\TestTarget\*.pas` while the suite is running.** The
  runner reads those files at run time to resolve `{BP:...}` markers, so the `.exe`
  compiles from the old source while the marker lookup reads the new one. Fakes a
  ~70-failure regression.
- **Never run the suite twice at once.** A second `build_and_run.bat` hangs. A
  healthy full run is ~400 s, and it is I/O-bound by design — CPU time is not a
  hang signal.
- **Capture the WHOLE log.** The habitual `Select-Object -Last 40` truncates the
  pass/fail counts off the top when the failure list is long. That once looked
  exactly like a regression.
- **A block of `DAP request failed: unknown error` across `Test_Types_*` has been
  seen once as a dirty run** that did not reproduce on identical code. Re-run
  before investigating.
- **Green on mono is not committable.** Every change must be green on BOTH
  fixtures — mono `TestTarget` and BPL `TestSubject`.
- **Validate any symbol-loading or concurrency change under the FULL suite with
  the BPL fixture.** The failed background loader passed in isolation and produced
  23-26 "Timeout waiting for response" hangs under full-suite load, all in
  `TDebuggerTestsBpl`.
- **A test green alone but flaky inside the suite points at a COLD symbol index**:
  the interactive wait is bounded, and the locals path has no warm-up/retry (the
  watch path does).
- **A test that passes suspiciously fast may be exercising nothing.** The x64
  attach test passed in 0.1 s WITHOUT attaching, gated on a privilege only needed
  for another user's process.
- `RUNTESTS_ONLY` (substring filter in `RunTests.dpr`, inert when unset) gives a
  ~2 s rebuild plus a filtered run instead of the full doubled suite.
- **`RunTests` uses EXPLICIT fixture registration, not auto-scan.**
  `TDebuggerTestsBpl` runs only because of `TDUnitX.RegisterTestFixture` in
  `DebuggerTests.pas` initialization; an unregistered fixture silently never runs.
- **`SkipIfNoRsm(reason)` skips ONLY the mono scenario** when `NO_RSM=1`; BPL and
  RSM-on mono still execute. A green `NO_RSM` run does not prove those
  capabilities work without RSM.
- **Kill blocking processes yourself.** A live adapter session holds
  `VisualStudioCodeDelphiDebugger.exe` and fails the build with F2039, so only the
  runner rebuilds and the adapter under test is stale. Idle
  `DelphiDebuggerMcp.exe` children of `claude.exe` do the same. Expect them in any
  editor session with the MCP server registered.

## Building

- **`build_runner.bat` does NOT rebuild the adapter, nor the DevTools probes**, and
  `RunTests.exe` links `DebuggerCore` statically. Rebuild EVERY consumer before
  trusting any measurement — stale binaries have produced at least four wrong
  conclusions in this project.
- **The adapter builds `-$Q+ -$R+`; `RunTests.cfg` and DevTools do not.** A defect
  that exists only under overflow/range checking passes the suite. Pin the
  directive in the unit source for arithmetic on debuggee-supplied addresses.
- **After any unit move, re-verify all four builds**: DAP (`.cfg` + `.dpr`
  in-clauses + `.dproj`), `build_mcp.bat`, `RunTests`/`build_runner`, and DevTools
  `build_all.bat` flags.
- **`build_and_run.bat` must call `build_runner.bat`**, never keep its own copy of
  the compile line — it silently went stale when search paths moved.
- **`DevTools\build_all.bat` discovers `*.dpr`; keep the `%~xF` extension guard**,
  or cmd's wildcard also matches `*.dproj` through 8.3 short names.
- **Batch quoting**: `-E"%~dp0"` breaks (the trailing backslash escapes the quote).
  Use `cd /d %~dp0` inside the `.bat`, then `-E.`. `dcc64` will not create a
  missing `-NU` output directory — `mkdir` it first.
- **JCL is not optional** (`DebuggerCore\JclDebugReader.pas` needs it).
  `JCL_ROOT` / `DUNITX_ROOT` come from `setpaths.bat`; never hardcode them back
  into `.cfg` files (`dcc64` reads `.cfg` unconditionally, with no conditional
  syntax).
- **Do NOT fork the `.cfg` files for 32-bit builds**: `-E` / `-NU` are overridable
  from the `dcc32` command line, last wins.
- Build 32-bit DevTools probes with `DevTools\build_one32.bat`.
- **Do not compile `DebuggerCore` with `-$O+`**: measured ~5 % (636 -> 601 ms), and
  it costs a debuggable adapter build. The scans are memory-bound.
- `settings.local.json` is machine-specific — never touched by reorganisations.
- `.claude/worktrees/` is git-ignored (agent worktrees are full checkouts).
- **`ZydisApi.ZydisTryLoad` is a ONE-SHOT, process-wide latch** (`ZydisApi.pas`):
  the FIRST call in a process decides Available/StatusText for that process's
  whole lifetime; later calls are no-ops that return the cached outcome. A test
  that deliberately points it at a missing/bad DLL to prove the "unavailable"
  path therefore poisons every OTHER test in the SAME process that wanted a
  real decode. `ZydisApi.ZydisResetForTests` (test-only, added increment 3)
  clears the latch, so `DisassemblerTests.pas` now calls it as the FIRST
  statement of every Zydis-touching test — negative-DLL and positive-decode
  tests share `RunTests.exe` safely, in any order, as long as each test
  resets before it cares about the outcome. Production code must never call
  `ZydisResetForTests`.

## Proving a fix

- **Run negative controls, do not assume them.** Revert the fix and confirm the new
  test fails with its intended message, in BOTH the mono and the BPL fixture,
  before believing it covers the bug.
- **Check every defect on BOTH bitnesses.** That is what separates "Win32
  regression" from "always been wrong".
- **State which half is proven and which is only guarded.** Some fixes cannot be
  reproduced in the fixtures; say so rather than letting a green suite imply
  coverage.
- **When asserting a recovered stack frame, assert the LINE as well as the routine
  name.** An earlier unsound attempt produced the right routine at the `finally`
  line (81) instead of the call line (79).
- **Bitness-parameterised tests must COLLECT failures, not assert per case.** Both
  executables are named `TestTarget.exe`, so a message built from the file name
  cannot identify the bitness, and a first-failure abort hides the x86 case.
- **After ANY sidecar or RSM-parser change, verify byte-identity**:
  `DevTools\Win64\Debug\PrebuildIdx.exe <dir> -verify` (SHA-256 against existing
  sidecars). `-r` / `-j N` / `-force` for offline warm-up.
- **To prove a MAP/TD32 reader change, rebuild DevTools against the changed reader
  and re-run `CompareMapTD32.exe <exe> <map>` on a 32-bit target AND a 64-bit
  control.** Expected residual after the segment-column fix: Win32 1568 entries ->
  9 forward / 10 reverse divergences; Win64 control 1487 -> 6 / 9. Those leftovers
  are MAP-vs-TD32 granularity (one source line owning many RVAs in instantiated
  generics), not a bitness defect. Without these baselines the tool is unreadable.
- **`DAP_LOG=1` is set at USER env level on this machine**, so adapter logging
  (synchronous `WriteFile` per line) is always on. `setx DAP_LOG 0` before
  measuring latency; re-enable only while diagnosing.
- **Validate any instruction-length decoder against a LARGE real binary.** 70 476
  spans showed zero unknown opcodes; 2 354 868 spans surfaced 61, one a real gap
  (AVX in `System.Move`). Trivial targets hide decoding gaps entirely.
- **A second-decoder oracle can have its OWN scale limit — measure it before
  blaming the decoder under test.** `DevTools\DisasmCoverage.exe`'s first
  unsampled full sweep of a 500+ MB binary (2 377 660 spans, a ~100+ MB
  synthetic image fed to dumpbin) reported 478 083 "boundary" divergences —
  dumpbin silently produced NO output at many span-start addresses Zydis
  decoded as ordinary code. A 33% sample of the SAME binary showed ZERO —
  the sharp threshold (not a rate that scales with sample size) is what
  proved it was dumpbin's own capacity limit at extreme single-section
  scale, not a real per-instruction disagreement. Before trusting a
  divergence count from ANY external tool at large scale, re-run at a
  smaller sample and check whether the rate is stable.
- **Capturing a large subprocess's stdout through an in-process pipe has a
  ceiling; redirect to a FILE instead.** The same full sweep's dumpbin
  output, captured via `ReadFile` into one Delphi string, failed outright
  with `EEncodingError: Invalid count (-1158168115)` (an overflowed string
  length) before the pipe capture was even the bottleneck being measured.
  Fixed by redirecting the child's `hStdOutput` straight to a file
  (`CreateProcess`) and parsing it back with a streaming `TStreamReader`,
  never materialising the whole output as one string.

## Fixture design

- **An argument containing ZERO BYTES silently makes an over-wide read look
  correct.** `Win32_StepOver_AdvancesWithinTheSameFrame` could never have caught
  the over-wide return-address read: the fourth pushed value was the Double 2.5,
  whose low 4 bytes are zero, so an 8-byte read of a 4-byte slot produced the right
  address by accident. `RunStepOverStackArg` passes `Integer($5EEDBEEF)` precisely
  so every byte is non-zero. This is the general rule for every width/bitness
  regression fixture.
- **Do NOT add type declarations to `TestTarget` for RSM experiments** — it shifts
  RSM import indices. Use a separate target
  (`DebuggerTests\TestTarget\NestedEnumSample.dpr`).
- **Adding object construction to a `TestTargetCore` proc perturbs first-hit marker
  ordering** (extra `CTOR_BODY` / `STUFF_CTOR_END` hits). Validate with the full
  suite, not one test.
- **A capturing closure inside an existing proc relocates that proc's frame
  layout**, so its other locals stop resolving at the expected offsets. A closure
  fixture must live in its OWN proc.
- **`RunMainObjectScenarioPortable` is called only inside the BPL on purpose.** In
  the exe the `.dpr` MAIN_* block already exercises those markers, and running the
  portable proc there as well flips the `MAIN_GCOUNTER`-before-`STUFF_PUBBUMP`
  first-hit order that `Test_Bug16` depends on.
- **A local nothing ever reads gets its store ELIDED even under `-$O-`.** Make the
  variable live before chasing a zero read-back.
- **A fixture that needs a breakpoint exactly BEFORE a given instruction must not
  put that instruction in the routine's FIRST statement.** A breakpoint on the
  first statement is subject to entry/body adjustment, and on the 32-bit build it
  landed AFTER the write it was supposed to precede — the x64 build did not, so
  the test failed on one bitness only and looked like a WOW64 hardware
  divergence. `DataBpWriteWatched` keeps a throwaway statement ahead of the
  watched write for exactly this reason.
- **`Win32_ExceptionStop_NamesClassAndMessage` needs `-run-exception-test`**;
  without the argument the target exits without raising and the test passes
  vacuously.
- **Do not assert `proven:true` on raw-stack hits from an x64 fixture** — the
  call-site decoder is x86 only, so on x64 every hit is honestly `proven:false`.
- **`Format('%x', ...)` emits UPPERCASE hex.** Every debugger-rendered address or
  value string (`$2A`, not `$2a`) follows it, so an assertion written in lowercase
  fails on a feature that works. Cost one full build+run round on the
  data-breakpoint description tests.

## What the suite cannot prove

- **The field failure condition for the x86 walk cannot be reproduced**: it needs a
  caller in a module dbghelp knows nothing about, and dbghelp knows every test
  module.
- **`HandleSmOverStep`'s entry-RSP handling is defensive, not covered** — stepping
  over from the RAW function-entry address is no longer reachable (neither a
  breakpoint nor a step-into parks there).
- **`Win32_RecordAndDynArrayExpansion_MatchWin64` asserts cross-bitness PARITY of
  the result, not that the live-RTTI path served it** — the record could have been
  expanded via TD32 members instead. The RTTI table-walk fixes are correct by
  construction against the RTL's declarations in `System.TypInfo`, not by test.
- **The "symbols still indexing" retry path has no fixture.** The window is real at
  a `stopAtEntry` stop, but the blank frames there are `kernel32` / `ntdll` —
  genuinely `saNoSymbols` — so no name was ever observed to appear on retry. A
  green run is not evidence the retry works.
- **A named-frame-count improvement cannot be measured in the fixtures**: every
  fixture stop has a breakpoint in the module it stops in, and the conservative
  `ContainsSourceFile` makes any breakpoint load every module, so old and new code
  behave identically.
- **The live-attach test is gated by `HaveDebugPrivilege` and silently SKIPS when
  not elevated.** A green run does not prove attach was exercised.

## Symbol providers and concurrency

- **Any provider the adapter queries is hit from two threads and runs under
  `{$R+}`.** Serialize lazily-mutating caches and bounds-check every incoming
  address before answering.
- **Never set `SYMOPT_DEFERRED_LOADS`**: the function-table callback does not
  reliably materialise a deferred module, unwind info goes missing, and the whole
  `Test_ClosureParam_*` BPL set fails with a DIFFERENT subset each run — looks
  flaky, is not. Only `SYMOPT_FAIL_CRITICAL_ERRORS` is set.
- **A module's `.rsm` OLDER than its binary is IGNORED** (the log warns). Types and
  locals then come from TD32 only until the package is rebuilt. After touching
  target sources, rebuild the target or alias/main-block behaviour silently
  degrades.
- **`WaitForDebugEvent` thread affinity**: Launch, Attach and Pump must all stay on
  the Run thread.
- **Frame-cache keys must be captured from the SEED `Rip`/`Rsp`/`Rbp` before the
  `StackWalk64` loop.** `StackWalk64` mutates the context into each unwound frame,
  so keying off it makes healthy walks always miss and degenerate 1-frame walks
  always hit.
- **When adding a provider interface, assign a fresh unique GUID.** A reused GUID
  makes `Supports` hand back the wrong vtable silently — a `...0011` clash once
  wrote a `TArray` result through the address of a `Boolean`, erroring 13 tests
  far from the cause. Next free suffix is recorded at the declaration;
  `TProviderInterfaceTests.ProviderInterfaceGuids_AreUnique` pins distinctness.
- **`listedBy: null` from `get_source_files` means UNKNOWN** (the format carries no
  file index), never "this module has no source files". An empty list beside a
  loaded module reads as authoritative.
- **Do not chunk or parallelize `IndexClassMemberRecords`**: measured to change
  output on 1 of 4 inputs (a chunk boundary lands inside a record the serial scan
  skipped). Needs a boundary-arbitration rule first.
- **The symbol prefetcher stays SINGLE-WORKER on purpose**: `TRsmFile` fans its
  index build out with `TParallel` and `TMapFile` forks its own thread, so extra
  workers oversubscribe the shared pool against the very stop they exist to speed
  up.
- **`DapLog` needs `GLogPath` set in unit initialization**, not in `TDapIO.Create`,
  or every non-DAP consumer (probes, tests, MCP) logs nowhere even with
  `DAP_LOG=1`.

## Engine and language gotchas

- **Sample `DR6` BEFORE anything else touches the thread context.** On a WOW64
  target the slot bits were already gone by the time the pump had cleared the trap
  flag through `Wow64SetThreadContext`; on native x64 they survived, so the whole
  data-breakpoint feature looked like "the target never wrote the cell" on one
  bitness only. Read the cause of a trap first, mutate the thread afterwards.
- **`DR6` reads back with its RESERVED bits SET** — measured `$FFFF4FF0` for a
  plain single step and `$FFFF0FF1` for a slot-0 hit, on BOTH bitnesses. Mask the
  fields you want (`$F` for `B0..B3`, `$4000` for `BS`); never compare `DR6` whole
  and never test it for "non-zero".
- **The CPU never clears `DR6`.** Leave it and the next trap on that thread carries
  the same bits, so every later step looks like a watchpoint hit.
- **Never name a Delphi method `Continue`** — it shadows the loop keyword. Use
  `ContinueExecution`.
- `for var x in ['a','b']` is fine, but `Exit(['a'])` parses as a set ("Ordinal
  type required"). Use `TArray<string>.Create(...)`.
- **Never use `IsLibrary` or `HInstance` to decide whether code executes inside a
  BPL** — use `RunningInsidePackageModule` (`VirtualQuery` on a local proc
  address).
- **A prologue-matcher miss must mean "refuse to report locals", never "has
  none"** — a pure-`asm` body is frameless yet debug info still lists its params,
  and the RTL is full of these.
- **Anchor VMT reads on an identity-tested `SelfPtr` plus per-bitness deltas**,
  never on absolute offsets.
- **Do not mechanically sweep the ~70 pointer-read sites in `DelphiRtti` /
  `ExprEval`**: many `ReadU64` calls are genuine 8-byte values, so a blanket pass
  introduces silent wrong numbers.
- **When reading the FNSAVE image, index the saved register area in STACK order**
  (ST(0) first), never by `TOP * offset`.
- **Never use `UNWIND_INFO.SizeOfProlog` as the step-into stop boundary** — derive
  it from the line table; `SizeOfProlog` is only the fallback for a routine written
  on one line.
- **DAP `variablesReference` ints are OPAQUE in the tests** (only `>0` expandable /
  `=0` leaf / pass-back-to-expand is asserted), so a handle bimap need not
  reproduce emission-order values.
- **When driving the MCP server, set breakpoints while parked at entry, before
  `continue_and_wait`** — the Run loop pumps continuously.

## Diagnosing a report

- **Read `%TEMP%\dap_adapter.log` FIRST.** It is append-only and survives the
  session; three defects were diagnosed from it without re-running anything.
- **When a step hangs, first distinguish**: the process RUNS but never stops (a
  breakpoint planted at the wrong address — grep the log for `PlantStepBp`) versus
  everything FREEZES (main-thread deadlock, see the MCP findings).
- **To find WHICH provider produced a bad symbol name, ask each directly**:
  `DevTools\Td32AliasProbe -rvaname <rva> <bpl>`, and `-proc <name>` to dump a
  routine's locals with raw TypeIds.
- **Field cases that need a human to trigger the stop**:
  `DevTools\LiveSessionProbe.exe <host.exe> <srcdir> file:line,... -seconds N
  -eval <expr>` keeps the session alive and reports breakpoint verification
  transitions.
- **x86 frame-1-and-up walk investigation**: `DevTools\Wow64StackProbe.exe
  <32-bit exe> -rva <hex RVA> [-step|-nopatch]`.
- **Reusable probes belong in `DevTools\`** as argv-driven tools with no hardcoded
  target. One-off scratch probes must not be cited by the docs — the probes and
  scripts referenced by the old journal lived in a volatile scratchpad and are
  GONE. Re-derive with DevTools rather than hunting for them.
- **Do not read or resurrect out-of-tree copies of `WinDebuggerBase.pas` /
  `DebugInfoSet.pas`.** The repo copies are authoritative; stale forks were deleted
  for exactly this reason.
- **Per-phase TD32/RSM load timing is no longer reproducible**: the env-gated
  `TD32_TIME` / `RSM_TIME` instrumentation was temporary and has been removed from
  the shipped readers. New timing work needs fresh instrumentation or
  `PrebuildIdx`.

## Real targets

- **Never run `hydra_2\Win32\Debug\Hydra2.exe` unattended** — it is a real ERP
  client and may hit a production database. Use the 497 MB `Hydra2SingleEXE.exe`
  for static validation.
- Reaching Hydra2 post-logon unattended needs the auto-logon command line
  `u=dev p=dev d=lxoracle` via `-targetargs`; otherwise it exits 0 at logon, which
  is not a debugger fault.
- **Running `DevTools\PrebuildIdx` next to a live debug session is the way to hit
  the sidecar write-contention path.** Use it to exercise that code deliberately,
  not as a background convenience.

## Already evaluated and rejected — do not re-walk

- Container-aware `ParseUserTypeTable`; pointer-cursor sidecar decoder;
  hand-written sidecar encoder / buffer pre-sizing; moving `SaveProcIndexToSidecar`
  after `FIndexReady`.
- A TD32 sidecar mirroring the RSM `.idx`: only 2.1-2.4x faster than a full TD32
  parse, and 2.6-3.8x LARGER than the section it replaces (105 MB for a 44 MB
  package).
- Moving `TD32FileReader.LoadFromFile` to a background thread: it would need
  `WaitForIndex` in ~20 consumers (missing one yields incomplete-data corruption),
  and the first `stackTrace` needs TD32 immediately, so the stall relocates rather
  than disappears.
- Turning `FindBreakpointByVA` into a VA->index hash map: it returns a LIST INDEX
  used for mutation and `.Delete(idx)`, and every per-step one-shot delete shifts
  indices. Any O(1) lookup must key on identity, not position — not worth the risk
  below ~100 breakpoints.
- **Three decodings of the wide main-block TypeId have been tried and refuted.** Do
  not guess a fourth; the two undumped candidate tables are logged in
  `KNOWN_UNKNOWNS.md`.
- The prefetcher 30 s-timeout investigation ruled out: the dispatch thread waiting
  for the worker, per-module repost churn, locals re-parse storms, and publishing
  while the debuggee runs. Nothing was ever OBSERVED; the undone step is
  `DAP_LOG=1` + `RUNTESTS_ONLY=TDebuggerTestsBpl` in a loop, then the largest
  timestamp gap in the log.
