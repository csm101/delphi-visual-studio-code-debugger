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
- **Never run the suite twice at once.** Two `build_and_run.bat` invocations
  clobber the same build outputs. This is still true with the parallel runner:
  concurrency inside ONE run is safe because each worker has its own report file
  and the `.idx` sidecars are published atomically, but two runs still rebuild
  the same binaries on top of each other.
- **A healthy full run is ~80 s** (~12 s build + ~68 s at 8 workers), or ~440 s
  with `RUNTESTS_JOBS=1`. It is latency-bound, not CPU-bound — low CPU is not a
  hang signal.
- **More workers is not automatically better.** Throughput keeps rising past 8
  on a 16C/32T machine (10.8x at 20 workers vs 6.4x at 8), but from 12 workers
  up, load-sensitive symbol lookups start missing their deadline and the suite
  goes intermittently red — `Test_RtlStringGetter_VarOutFromPropertyType` failing
  with "TStrings.GetTextStr not found" is the signature. The default cap of 8 is
  set by that, not by the speedup curve. If you raise `RUNTESTS_JOBS` past it and
  see an odd symbol-not-found failure, halve it before investigating the symbol.
- **The runner already re-checks its own failures — read the label before
  investigating.** Any failure in a parallel run is re-run once with a single
  worker. `FAILED in parallel AND again on the sequential re-check` is a real
  failure. `LOAD-SENSITIVE` means it passed alone: the machine could not sustain
  the worker count, the run stays green, and there is nothing to debug in the
  code under test. Do not start bisecting a `LOAD-SENSITIVE` line.
- **`load-sensitive="N"` with N > 0 in `TestResults.xml` is a signal about the
  MACHINE, not the code** — lower `RUNTESTS_JOBS`. It is also the recurrence of
  the open symbol-index question in `KNOWN_UNKNOWNS.md`; the evidence is in
  `Win64\Debug\RunTests_recheck.log`.
- **When a failure smells like interference, re-run with `RUNTESTS_JOBS=1`
  first.** Sequential is a fully supported mode and gives identical counts; a
  failure that survives it is a real failure. (`RUNTESTS_JOBS=1` also skips the
  re-check — there is nothing to compare against.)
- **A test that needs to be the only session on the machine must go in
  `NOT_PARALLEL_SAFE` in `RunTests.dpr`**, which holds it back for the serial
  tail. Two are there already: one attaches to a process found by NAME, the other
  asserts it can open `TestTarget.exe` EXCLUSIVELY. Both were silently correct
  only because nothing else used to run at the same time.
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
- **After touching ANY test-target source, rebuild with `build_and_run.bat`, not
  `build_target.bat` + `run_tests_parallel.bat`.** `build_target.bat` does not
  build the package/host fixtures, and a stale one fails as *"Timeout waiting for
  stopped event"* across a whole test class — which reads exactly like a
  regression in the code under test, and sends the next hour in the wrong
  direction. Editing even a COMMENT counts as touching it: it shifts the
  `{BP:MARKER}` lines away from the compiled binary's line table.
  Two artefacts in particular are missed, and they fail differently:
  `TestHost\...\TestSubject.bpl` (`build_host.bat`) recompiles the SAME
  `TestTarget\*.pas` units, so every `TDebuggerTestsBpl` case times out or
  reports `<local: not found>`; and `TestTarget.jdbg` (`build_jdbg.bat`) is a
  sidecar of the exe, so `JclDebugReaderTests` fails as a line-number/function
  DISAGREEMENT between JCL and TD32 rather than as a timeout — which looks like a
  reader bug and is not one. Re-verified the hard way in 2026-08; the sequential
  re-check does not rescue you, because a stale fixture is not load-sensitive.
- **Killing a suite mid-run leaves the adapter and `TestHost` alive**, holding the
  adapter exe open; the next build fails with `F2039 Could not create output
  file`. Kill them and move on — there is nothing to investigate.
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
- **Disabling one of several call sites that all post the same repost/rebind
  command is not automatically a valid negative control.** Address-breakpoint
  rebind-on-reload has TWO repost call sites (module load, module unload);
  disabling only the load-side one did not break
  `AddrBp_Bpl_UnloadReload_Rebinds`, because the unload-side call's queued
  command gets drained by the very next load event anyway. Disable every
  call site that could plausibly contribute before trusting a "still green"
  result as proof the mechanism is unnecessary.
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

- **For anything the LANGUAGE defines, let the compiler compute the expected
  value.** A hand-written `Assert.AreEqual` is worth exactly as much as its
  author's reading of Delphi, and a wrong reading produces an evaluator and an
  assertion built from the same misunderstanding: they agree with each other,
  the test is green, and nothing has been proved. Measured cost of this: of the
  232 expressions the whole suite evaluated, none contained `and`, `or`, `xor`,
  `not`, `div`, `mod`, `shl`, `shr`, `<>`, `<`, `>`, `<=` or `>=`, and exactly
  one contained `=` -- while `TEST_CATALOG.md` said "[x] Boolean ops,
  comparisons, precedence". `S = 'abc'` compared heap pointers and `Flags and
  MASK = 0` grouped C-style for as long as the project had existed, and both
  surfaced only when someone read the evaluator against the language while
  writing the user manual. `RunExprOracle` + `ExprOracle_DebuggerAgreesWithThe`
  `Compiler` is the pattern: the fixture assigns the expression to a Boolean
  local, the test evaluates the same source text, the two must match.
- **A `[x]` in `TEST_CATALOG.md` must NAME the test that backs it.** A ticked box
  with no test name is a claim, and it actively prevents the test from being
  written -- nobody writes a test for something the catalog says is covered. An
  empty `[ ]` would have been better than the line above.

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
- **A `{BP:MARKER}` comment must sit on the statement's FIRST source line.** The
  line table has an entry for the line a statement STARTS on, not for its
  continuation lines, so a marker parked on the second line of a wrapped call
  resolves to a line no address maps to: the breakpoint is accepted, never binds,
  and the test fails with a bare "did not stop" that says nothing about why. Cost
  one build+run round on `EXPR_SEMANTICS`; the fix was to fold the `GSink.Use([…])`
  call back onto one line (the repo allows up to 130 columns for exactly this
  kind of case).
- **`Format('%x', ...)` emits UPPERCASE hex.** Every debugger-rendered address or
  value string (`$2A`, not `$2a`) follows it, so an assertion written in lowercase
  fails on a feature that works. Cost one full build+run round on the
  data-breakpoint description tests.
- **`TDapIO.SendErrorResponse`'s reason lives at `body.error.format`, NOT a
  top-level `message` field.** The DAP spec's `ErrorResponse` puts it there
  (`DapProtocol.pas`); a test that reads `Resp.GetValue<string>('message', '')`
  against a `*Raw` response reads a field that was never populated and always
  gets `''`. Cost one full-suite run on
  `Refused_WhenNotLaunched_ReachesClientAsFailedRequest`
  (ASSEMBLY_LEVEL_DEBUGGING.md increment 2) before the assertion was fixed to
  drill into `body.error.format`.

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

## Cleanup that silently never happens

- **A test that LAUNCHES a copied exe cannot delete its directory in the same
  breath.** Windows releases the image section shortly AFTER the process object
  goes, so the delete removes the small files, fails on the exe, and leaves the
  directory — every run, silently, because a cleanup failure is not a test
  failure. Measured: 438 directories / 1.28 GB in a TEMP that is a RAMDISK. Use
  `TestTempDirs`: one scratch root, `MakeTestScratchDir`, end the session first,
  `DeleteTempDirWithRetry`, and `PurgeLeftoverTempDirs` on the way in.
- **`TerminateProcess` only ASKS.** Closing the handle right after it leaves the
  process (and its mapped exe) alive for a while. Wait on the handle when
  anything downstream depends on the process being gone — deleting its exe does.
- **A per-PROCESS quota on a file opened for APPEND is not a cap.** The adapter
  log had a 256 MB "cap" counted per adapter run and reached 1.5 GB: every
  session restarted the count on top of what was already there. Measure the
  FILE. (`DapProtocol`: cap + one rotation, `DAP_LOG_MAX_MB`.)
- **A new adapter command-line switch must be registered in
  `ProcessListJson.UnrecognizedSwitch` too.** The `.dpr` rejects an unknown
  switch before the DAP loop starts, deliberately — so a switch the DAP layer
  understands but that guard does not makes the adapter exit at startup, which
  the client reports as "timeout waiting for response to seq=1".
- **Never keep a second copy of a build list.** `build_and_run.bat` had its own
  inline TestTarget block; it went stale and stopped building four fixtures, and
  a stale fixture fails as "Timeout waiting for stopped event" — which reads as a
  debugger defect. It calls `build_target.bat` now.

## Releases

- **`gh release delete` deletes a PUBLISHED release as readily as a draft, and
  prints nothing that tells them apart.** Check `isDraft` (`gh release view
  <tag> --json isDraft`) before any delete. This was learned by deleting a
  release the user had published hours earlier, on a stale "it is still my
  draft" assumption.
- **The remote tag is the proof of publication.** A draft has no tag; publishing
  creates one; `gh release delete` (without `--cleanup-tag`) leaves it behind.
  `git ls-remote --tags origin` therefore settles "was this ever published"
  even after the release page is gone — and the surviving tag plus the zip in
  `dist\` (verify its SHA-256 against the published notes) is what makes a
  byte-identical restore possible: `gh release create <tag> --verify-tag
  --latest=false --notes-file <notes> <zip>`, then `--latest` if it was latest.

## Session notes and the resume cursor

- **`TASK_RESUME.md` is erased by `githooks/post-commit`, and that is the
  feature.** It holds only uncommitted, mid-step state. Anything durable belongs
  in the commit message, `PROJECT_STATE.md`, `TRAPS.md` or a format document —
  written in the same change set as the code. Do not rewrite the cursor after
  committing to "keep the history": the file's whole failure mode was a
  confident "next action" that described work finished weeks earlier.
- **The hook does not run until `core.hooksPath` is set, and a fresh clone does
  not set it.** `git config core.hooksPath githooks`, once per clone. Without it
  nothing errors — the cursor simply starts rotting again, silently.
- **A hook script must stay LF.** `.gitattributes` checks this tree out as CRLF;
  `githooks/*` is exempted explicitly, because Git's POSIX shell reads
  `#!/bin/sh\r` as a missing interpreter.

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
- **Embedded TD32 keeps the debuggee's own binary memory-mapped for the loader's
  whole life** (`TTD32FileReader.OpenMappedFile`, `FILE_SHARE_READ`, no write/delete
  share). TD32 lives INSIDE the `.exe`/`.bpl`, so the binary is locked on disk while
  the reader is alive. On a LAUNCH that is invisible — the session ends with the
  target and frees the reader — but on an ATTACH the session outlives the target, so
  the file stays locked and a rebuild fails until the server exits. Released now in
  `TModuleSymbolLoader.ReleaseMainSymbolMapping`, called from
  `TDebugSession.HandleTargetExited`; the next launch/attach reloads a fresh reader.
  Do NOT try to fix this by closing the debuggee PROCESS handle or `DebugActiveProcessStop`
  — both were tried and the file stayed locked; the mapping is the lock, not the
  zombie. Adding write/delete share is also insufficient: a held mapping blocks the
  linker's truncate (`ERROR_USER_MAPPED_FILE`) regardless. Runtime BPL readers
  (`TModuleSymbols.Td32`) hold the identical lock on each `.bpl`; they are released the
  same way in `ReleaseModuleSymbolMappings`, which FIRST calls `ShutdownPrefetch` — the
  worker, not the dispatch thread, owns module readers, so freeing one it is mid-parse
  would crash. Both releases are ARC-driven: the readers are owned solely by their
  provider ref in `FDebugInfo` (freeing the raw object is a double-free — see
  `TModuleSymbolLoader.Destroy`), so `RemoveProvider` (main) / `RemoveProvider` +
  `FModules.Clear` (modules) drops the last ref and the destructor unmaps. Regressions:
  `TDebugSessionTests.NaturalExit_ReleasesThe{Image,Bpl}FileLock`. A side effect worth
  knowing: `ShutdownPrefetch` on exit disables prefetch for the rest of THAT session, so
  a re-attach in the same session loads module symbols synchronously (slower first stop,
  still correct); no-op when prefetch is off, which is the default.

## RTL routines in a packaged application

- **An RTL routine resolved BY NAME can be the wrong copy.** A process split
  into runtime packages holds the RTL in `rtl<version>.bpl`, but an exe that
  links the RTL statically has a second one, and per-thread RTL state is NOT
  shared between them. Resolving `System.ExceptObject` by name in
  `TestHost.exe` + `TestSubject.bpl` finds the host's static copy, whose raise
  list is empty, and calling it says "nothing is being handled" while the
  package is inside a handler. Resolve in the module the code is EXECUTING in
  (compare `SymGetModuleBase64` of the candidate against that of the PC), and
  fall back to `TWinDebugger.TryResolveExportedRoutine` — `rtl290.bpl` has no
  debug information at all, and its export directory is the only thing left
  that names a routine.
- The same hazard applies to every other by-name RTL lookup in the engine
  (`@UStrAsg` and friends in `SetStringVariable`). Not yet re-measured there.

## Synthetic calls into the debuggee

- **Aborting a call does not give the thread back.** The abort hijacks RIP to the
  INT3 trap, which only works when the thread is executing code. A thread parked
  in a kernel wait (`Sleep`, a lock, an I/O) does not reach the trap until the
  wait ends, so the pump falls through to its 2 s hard-restore and the call
  reports failure — but the thread stays inside the blocking operation for as
  long as it was going to. Every later call on that thread fails until then.
  A test that cuts a blocking getter short and then evaluates something else on
  the same thread is measuring the leftover block, not the thing it named. Read
  everything you need out of the SAME expansion, or wait the block out.

## Engine and language gotchas

- **When a reported stop disagrees with the exception event's own address, suspect
  the REPORTING layer before the stack walker.** An exception stop in code with no
  debug info was reported at the CALLING Delphi frame — real source, real line,
  ~0x1FE00 bytes from the true fault — while the exception event's own
  `ExceptionAddress` was correct. That looked like a stack-walk defect, and
  `TWinDebugger.GetStackFrames` (which forces frame 0's IP to the freshly-read
  `GetThreadContext` RIP) was traced at length on that assumption. The walker was
  right the whole time: `TSourceResolver.TrimRaisePlumbing` was dropping every
  leading frame whose source could not be opened, and the trimmed array was
  assigned to `FLastFrames`, so the frames were not hidden, they were gone. Read
  what the layers ABOVE the measurement do to it before instrumenting the
  measurement.
- **`GetCallStack` keeps every frame; `DefaultFrameIndex` decides which one
  answers.** These are separate on purpose (`DAP_DEBUGGER_ARCHITECTURE.md`,
  "Frames versus the active frame"). Do not "fix" a wrong-frame answer by
  removing frames from the stack — that is exactly the defect above. And a
  frame index is only explicit if the CLIENT named it: `frameIndex: 0` and no
  `frameIndex` at all mean different things at an exception stop, so test the
  presence of the key (`Args.FindValue`), never its value.
- **The WOW64 loader breakpoint (the process's FIRST stop, before `-rva` or a
  planted `INT3`) is NOT a representative state for measuring native-vs-WOW64
  context behaviour.** `DevTools\Wow64RegWriteProbe.dpr` measured a native
  `GetThreadContext`/`SetThreadContext` register write as genuinely invisible
  to `Wow64GetThreadContext` there (native `Rax` even read back as literal
  zero before any write) — but at a REAL application breakpoint (an `INT3`
  planted in already-running 32-bit code, exactly how every breakpoint in
  this debugger works), the native and WOW64 views ALIASED EXACTLY for every
  register tested, including `Rip`/`Rsp`/`Rbp`. A defect measured only at the
  loader breakpoint may not be reachable through any state this debugger
  actually reports to a user as "stopped" (`stopAtEntry` plants its OWN
  breakpoint at the real entry point, never relying on the raw loader break).
  Plant an `INT3` at real application code (`-rva`, same mechanism
  `Wow64StackProbe.dpr` uses) before trusting a WOW64-context finding.
  (ASSEMBLY_LEVEL_DEBUGGING.md increment 6.)
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
- **A `rep`-prefixed instruction traps ONCE PER ITERATION.** Measured on both
  bitnesses: a trap-flag step at `rep movsb` leaves the PC at the *same address*
  it started from, having retired one iteration. Anything that single-steps such
  an instruction, or loops until the PC moves, produces one stop per byte moved
  and reads as a hang. Run past it with a one-shot at PC + the decoded length,
  exactly like a `call`.
- **A transient step breakpoint rejected by the recursion guard must be STEPPED
  OFF before the INT3 goes back.** The hit handler has already restored the
  original byte and rewound the PC onto that address, so re-planting in place
  re-traps on the same instruction forever — an unbounded `BP hit / PlantInt3 OK`
  loop in `%TEMP%\dap_adapter.log`, with the target apparently running and no
  stop ever arriving. `RearmStepBpAfterForeignHit` is the one place that does it
  correctly (leave unplanted, trap-step off, re-plant), and `FSteppingOffStepBp`
  marks that trap as deciding nothing so no step mode reads it as progress.
- **`FPendingContinueStatus` is CONSUMED, never overwritten.** At a first-chance
  exception stop it holds `DBG_EXCEPTION_NOT_HANDLED` so the program's own
  handler runs. `ckContinue` read it correctly; `ckStepInto`, `ckStepOver` and
  `ckStepOut` each assigned `DBG_CONTINUE` over it before resuming — five
  `ReleasePendingEvent(DBG_CONTINUE)` call sites across the three. The intent was
  written down in `HandleException` ("so ckContinue/step use the right status")
  and then overwritten in three places. For a HARDWARE fault the effect is an
  infinite loop: `DBG_CONTINUE` swallows the exception, the faulting instruction
  re-executes, and it faults again. Reported from the field as "step at an
  exception stop fills the log forever". A Delphi `raise` does NOT loop (it is a
  software `RaiseException` call, so swallowing it merely lets the call return) —
  so a repro must use an access violation, or it proves nothing.
- **Never single-step out of an exception stop; there is nothing to step.**
  Measured on both bitnesses (`DevTools\ExcHandlerProbe -tf`,
  `EH_FORMAT_NOTES.md`): arming `EFLAGS.TF` and resuming with
  `DBG_EXCEPTION_NOT_HANDLED` produces NO single-step event at all on native
  x64, and on WOW64 only for a software raise, one instruction into
  `ntdll32!KiUserExceptionDispatcher`. A one-shot breakpoint at a DERIVED handler
  block is the only mechanism.
- **Never decode a scope entry's `Handler` as a Delphi clause table before
  checking the language handler is `_DelphiExceptionHandler`.** Under MSVC's
  `__C_specific_handler` that field is a FILTER FUNCTION and the decode produces
  confident nonsense. Every `ntdll` / `kernelbase` frame in any exception walk is
  one of these.
- **Never plant a breakpoint on a scope entry's `Handler` field.** When it is a
  clause-table RVA the `$CC` overwrites the clause COUNT and derails dispatch.
  Only DECODED BLOCK addresses are plantable. This already contaminated one probe
  run.
- **`PlantStepBp` silently does nothing when a breakpoint already occupies the
  address**, so an address it was asked to plant may never appear in
  `FStepBpVAs`. Any step whose LANDING is decided by membership of that list
  therefore misses when the landing carries a user breakpoint. `smInstr` keeps
  its resume address in `FStepOverVA` and `smToHandler` keeps its blocks in
  `FExcStepVAs` for exactly this reason; both also answer from the PERSISTENT-BP
  hit path, not only the one-shot path.
- **Never name a Delphi method `Continue`** — it shadows the loop keyword. Use
  `ContinueExecution`.
- **The main-exe module-name sentinel differs by layer.** `TWinDebugger`'s own
  convention for "the main exe" is `''` (`FDllBases` is populated only for
  runtime-loaded DLLs/BPLs by `HandleLoadDll`, never the main exe, whose base
  comes from `FImageBase` instead). `TDebugSession.GetModules` names the main
  exe by its real lowercase filename, for sensible reporting. Any code that
  builds a `TAddrBpSpec`/similar engine-facing spec must translate through
  `TDebugSession.EngineModuleNameFor` first, or a main-exe address resolves
  fine at the session layer (`Verified=True`) while the engine silently drops
  the plant. Found by `AddrBp_MainExe_SetAtKnownAddress_StopsThere`'s first
  run (DISASSEMBLY_PLAN.md increment 5), not by inspection.
- **An evaluated function ADDRESS renders as the bare type name `"Pointer"`**
  through this codebase's value formatter — `@FuncName` and
  `NativeUInt(@FuncName)` both do this, in both DAP `evaluate` and (by the
  same formatter) MCP `evaluate_expression`. Read the DAP Registers scope
  (`RIP`/`EIP` via `scopes` + `variables`, stripping the same
  `"  (<decimal>)"` display decoration `ExtractDisplayValue` already strips
  elsewhere) instead when a test needs a real code address and no
  purpose-built address-echoing field exists yet.
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
