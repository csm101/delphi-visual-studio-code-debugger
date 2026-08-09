# TASK_RESUME

The cursor inside the task in flight, and nothing else.

**This file is OVERWRITTEN, not appended to, and stays under ~150 lines.** It grew
to 3343 lines (~91k tokens) by being used as a lab journal, until reading it cost
more than reading the code it described — and by then its "next action" pointed at
work finished weeks earlier, which is worse than having no cursor at all.

Where everything else goes:

| content | home |
|---|---|
| a measured fact about a format | `RSM_*.md`, `TD32_FORMAT_NOTES.md`, `EH_FORMAT_NOTES.md` |
| an architectural decision or mechanism | `DAP_DEBUGGER_ARCHITECTURE.md` |
| an open question or a refuted hypothesis | `KNOWN_UNKNOWNS.md` |
| a rule that prevents wasted work | `TRAPS.md` |
| what is done / what is next, at project scale | `PROJECT_STATE.md` |
| the narrative of a change that landed | the commit message |

If a paragraph here is still true once the current task ends, move it. If it is no
longer true, delete it.

---

## Current task (2026-08-09)

**Step at a first-chance exception stop. DONE, not committed; left in the tree.**

Full suite green: **1200 found / 1196 passed / 0 failed / 0 errored / 4 ignored**
(baseline was 1188/1184/0/0/4; the 12 new tests are the whole delta).

### What it does now

A step of ANY kind at an exception stop runs to the first `except` / `finally`
block up the stack that really receives the exception, and reports `srStep`
there. Mechanism: a one-shot breakpoint at a handler address DERIVED from the
binary, then release the pending event with `DBG_EXCEPTION_NOT_HANDLED`. The
trap flag is not usable — measured, `EH_FORMAT_NOTES.md`.

Refuses, with a reason that names what is missing, for: x86 `try/finally`, x86
bare `except` (the `fs:[0]` record carries no table — only the dispatch stub,
and a hit there is the SEH search pass), a non-Delphi language handler, an
undecodable scope table, and "no frame protects this code".

### Where it lives

- `DebugTarget.pas` — `TExceptionStepPlan`, `ckStepToHandler`, three new
  `IDebugTarget` members (`StoppedOnUndeliveredException`,
  `StepToExceptionHandler`, `LastStepNote`).
- `WinDebuggerBase.pas` — `smToHandler`, `PlanExceptionStep` (x64, virtual),
  `DoStepToHandler`, `ExcStepBlock` / `ExcStepLandedAt` / `EndExceptionStep`,
  the re-fire guard in `HandleException`, and the `FPendingContinueStatus`
  consume-not-overwrite fix in `ckStepInto` / `ckStepOver` / `ckStepOut`.
- `WinDebuggerX86.pas` — `PlanExceptionStep` override (fs:[0] walk) + `Teb32Base`.
- `DebugSession.pas` — `PostSourceStep` routes all three steps; `StepOver` /
  `StepInto` / `StepOut` gained `out RefusalReason` overloads.
- `DapServer.pas` — `HandleSourceStep` (response ordering differs by stop kind).
- `McpServer.pas` — `HandleStepTool` reports the refusal instead of arming a wait.
- `DebuggerTests\ExceptionStepTests.pas` (new, registered in `RunTests.dpr`).
- `DevTools\Fixtures\ExcNestFixture.dpr` — new orthogonal `-nofinally` switch.
- `build_and_run.bat` / `build_target.bat` now call `build_exc_fixture.bat`.

Docs updated in the same change set: `EH_FORMAT_NOTES.md` (new living spec,
listed in `CLAUDE.md`), `DAP_DEBUGGER_ARCHITECTURE.md`, `TRAPS.md`,
`TEST_CATALOG.md` section V + three coverage-honesty notes, `PROJECT_STATE.md`,
`DevTools\README.md`.

### Two decisions worth not re-litigating

1. **Plant every clause block of every covering scope entry; first hit wins.**
   Class-matching the exception against `ClassVmtRva` would be a second
   implementation of Delphi's rules (ancestors, re-raise, interfaces) and a wrong
   match plants in a block that never runs, which reads as a hang.
2. **x86 `finally` / bare `except` REFUSE rather than stopping on the stub.** The
   stub's address does resolve to the `finally` line, so stopping there looks
   right — but the hit is the SEH SEARCH pass, not the block running.

### Next if interrupted

Nothing is half-done. Optional follow-ups, in value order:

1. A step whose planted block is never reached does not stop at all (possible
   only when a covering `on` clause set is exhaustive against the raised class,
   so dispatch moves to a frame the plan did not cover). Not wrong, not a
   refusal, and untested — `TEST_CATALOG.md`, "What the suite does NOT prove".
2. Three x64 refusal branches have no fixture (non-Delphi handler on a frame WITH
   source, invalid scope table, no protecting frame at all). Correct by
   construction only.
3. The pre-existing suite-speed follow-ups: skip the 10 ms `WaitForDebugEvent`
   while the debuggee is stopped; `McpE2ETests.TMcpTestClient.ReadLine` still
   polls with `Sleep(2)` and reads one byte per `ReadFile`.

## State of the tree

- `public-main`; everything UNCOMMITTED by instruction — **DO NOT COMMIT.**
- Rebuilt and green: `build_dap.bat`, `build_mcp.bat`, `build_runner.bat`,
  `DevTools\build_all.bat`, `DevTools\build_exc_fixture.bat`, and the full
  `build_and_run.bat`.
- The earlier suite-speed work (parallel runner, event-driven `Dequeue` /
  `DapServer` idle wait) is also still uncommitted in this tree.
