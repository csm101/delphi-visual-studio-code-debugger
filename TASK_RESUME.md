# TASK_RESUME

The cursor inside the task in flight, and nothing else.

**This file is OVERWRITTEN, not appended to, and stays under ~150 lines.** It grew
to 3343 lines (~91k tokens) by being used as a lab journal, until reading it cost
more than reading the code it described — and by then its "next action" pointed at
work finished weeks earlier, which is worse than having no cursor at all.

Where everything else goes:

| content | home |
|---|---|
| a measured fact about a format | `RSM_*.md`, `TD32_FORMAT_NOTES.md` |
| an architectural decision or mechanism | `DAP_DEBUGGER_ARCHITECTURE.md` |
| an open question or a refuted hypothesis | `KNOWN_UNKNOWNS.md` |
| a rule that prevents wasted work | `TRAPS.md` |
| what is done / what is next, at project scale | `PROJECT_STATE.md` |
| the narrative of a change that landed | the commit message |

If a paragraph here is still true once the current task ends, move it. If it is no
longer true, delete it.

---

## Current task (2026-08-09)

**Make the test suite fast. DONE, not committed; left in the tree for review.**

Full `build_and_run.bat`: **568 s → 80.5 s**, same counts (1188 found / 1184
passed / 0 failed / 0 errored / 4 ignored) on both fixtures.

### Where the time actually went (measured, not estimated)

- Build is ~12 s of the whole thing. It was never the problem.
- The run had **no long pole**: 1188 tests, mean 0.42 s, p50 0.39 s, p99 1.6 s,
  max 10.15 s; the 15 slowest together are ~51 s of 500 s. It was ~1100 debug
  sessions each paying the same fixed cost.
- `DevTools\DapSessionTiming.exe` broke that fixed cost down. Original:
  **425.5 ms/session**, of which every trivial round trip (`setBreakpoints`,
  `scopes`, `configurationDone`…) cost 27-36 ms — for work that takes ~1 ms.
  Two sleep loops in series explained it: `DapClient.Dequeue` polled on
  `Sleep(15)`, and the adapter's idle loop did `Sleep(10)`.

### What changed

1. `DebuggerTests/DapClient.pas` — `Dequeue` waits on a manual-reset `TEvent`
   signalled by `Enqueue` instead of polling. 425.5 → 325.4 ms/session.
2. `VisualStudioCodeDelphiDebugger/DapServer.pas` — the idle branch of `Run`
   waits on a new `MsgArrived` event (set by the stdin thread) instead of
   `Sleep(10)`. 325.4 → **256.1 ms/session**. This also cuts real VS Code
   latency, it is not a test-only change.
   Sequential suite after 1+2: 556.5 s → **426.2 s**.
3. `DebuggerTests/RunTests.dpr` — `TSubstringFilter` became `TSelectionFilter`:
   `RUNTESTS_ONLY` (unchanged), plus `RUNTESTS_SHARD=i/n` (stable FNV-1a hash of
   the full test name) and `RUNTESTS_SERIAL=exclude|only` over a
   `NOT_PARALLEL_SAFE` list.
4. `DebuggerTests/RunTestsParallel.dpr` + `build_parallel_runner.bat` +
   `run_tests_parallel.bat` (new) — N worker processes, own XML + own log each,
   then a serial tail, then a merged `TestResults.xml` carrying per-test timings
   AND failure messages. `build_and_run.bat` now goes through it.
5. Pid-scoped four fixed temp paths that two workers would have shared
   (`McpE2ETests.pas` ×3, `DebugSessionTests.pas` ×1, `DebuggerTests.pas` ×1).

### Measured scaling (16C/32T, 32 GB free, 1188 tests)

| jobs | wall | speedup | failures seen |
|---|---|---|---|
| 1 | 426.2 s | 1.00x | none |
| 2 | 220.4 s | 1.93x | none |
| 4 | 119.6 s | 3.56x | none (3 runs) |
| 6 | 85.8 s | 4.97x | none |
| **8** | **66.5 s** | **6.41x** | none (5 runs) |
| 10 | 61.7 s | 6.91x | none |
| 12 | 50.7 s | 8.41x | 1 in 3 runs |
| 16 | 42.1 s | 10.13x | none (1 run) |
| 20 | 39.4 s | 10.82x | 1 in 1 run |

Throughput does **not** flatten at 8. The cap is set by correctness: at 12+,
`Test_RtlStringGetter_VarOutFromPropertyType` intermittently fails with
`TStrings.GetTextStr not found` — a load-sensitive symbol-index deadline, not a
scheduling artefact. Default = `min(CPUs div 2, (availMB-1024) div 384, 8)`,
overridable with `RUNTESTS_JOBS`; `1` is exactly today's sequential behaviour.

### Sequential re-check (follow-up, same task)

The worker count adapts; whether the machine can SUSTAIN it does not show until
the run. On a smaller or busier machine the load-sensitive symbol lookup can miss
its deadline well below 12 workers, and a stranger would read that as a broken
project. So a parallel run that produces failures now re-runs **those tests
only**, once, with one worker, and the sequential verdict is authoritative:

- fails parallel AND alone → red, exit 1, `<failure>`, counted in `failures`.
- fails parallel, passes alone → `result="LoadSensitive"`, `success="True"`,
  `<reason>`, counted in `load-sensitive`; console says "NOT code defects" and
  names them; **exit 0**.
- passes everywhere → nothing.

Root element also carries `workers` / `load-sensitive` /
`recheck="performed|skipped-sequential|not-needed"` so the XML alone is
sufficient. Green runs pay nothing; exactly one re-run, never a retry loop;
`RUNTESTS_JOBS=1` skips it. `RUNTESTS_NAMES=a;b;c` (new, in `RunTests.dpr`)
is what lets one pass name an arbitrary set, overriding shard and serial split.

Verified with two temporary probes in `ProcessListJsonTests.pas` (added, used,
reverted — the file is clean): one failing unconditionally → red with the
"in parallel AND again on the re-check" heading, exit 1; one failing only when
more than one `RunTests.exe` is alive → `LoadSensitive`, exit 0, warning printed.
Also verified `--jobs 1` emits `recheck="skipped-sequential"` and spawns no
re-check. Re-check cost on the real suite: ~0.2 s.

### Next if interrupted

Nothing is half-done. Optional follow-ups, in value order:

1. The adapter still burns up to 10 ms per post-launch round trip inside
   `WaitForDebugEvent(Ev, 10)` in `TWinDebugger.ProcessOneEvent`, which is dead
   time while the debuggee is stopped and cannot produce an event. Skipping the
   pump while stopped would cut ~5 ms × ~6 round trips per session (~35 s of a
   sequential run, ~5 s at 8 workers). Debugger-loop surgery — measure before and
   after with `DapSessionTiming`.
2. `McpE2ETests.TMcpTestClient.ReadLine` still polls `PeekNamedPipe` with
   `Sleep(2)` and reads ONE byte per `ReadFile`. ~48 MCP tests; unmeasured.
3. Raising the worker cap requires fixing (1) the symbol-index wait under load —
   see `KNOWN_UNKNOWNS.md`.

## State of the tree

- `public-main`. The perf work is committed as `0539853`; the sequential
  re-check on top of it is UNCOMMITTED by instruction — **DO NOT COMMIT.**
  Uncommitted files: `DebuggerTests/RunTests.dpr`,
  `DebuggerTests/RunTestsParallel.dpr`, plus the doc updates.
- Rebuilt and green: `build_runner.bat`, `build_parallel_runner.bat`. Nothing in
  `DebuggerCore`, the adapter or the MCP server changed in the re-check work, so
  their binaries are current from `0539853`.
