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

**`ASSEMBLY_LEVEL_DEBUGGING.md` increment 2 — DAP stepping granularity. DONE, not
committed; left in the tree for review.** Thin plumbing on top of increment 1's
engine primitive (`TDebugSession.StepInstruction`) — no new engine code.

Mechanism: `DAP_DEBUGGER_ARCHITECTURE.md`, "Instruction granularity (DAP) —
increment 2". Decisions + RED controls: `ASSEMBLY_LEVEL_DEBUGGING.md`, increment 2.
Coverage: `TEST_CATALOG.md` "P.". This cursor is a pointer, not a repeat.

### Files changed

- `VisualStudioCodeDelphiDebugger\DapServer.pas` — `supportsSteppingGranularity`
  capability; `WantsInstructionGranularity`; `HandleInstructionStep` (maps
  next/stepIn/stepOut → iskOver/iskInto/iskOut, calls
  `TDebugSession.StepInstruction` BEFORE answering so a refusal reaches the
  client as `success: false`); `HandleNext`/`HandleStepIn`/`HandleStepOut` each
  gained a one-line dispatch to it, unchanged otherwise.
- `DebuggerTests\DapClient.pas` — `StepIn`/`StepOut`/`StepOver` gained an
  optional `Granularity` parameter (default `''` = field omitted, matching a
  pre-capability client); added `StepInRaw`/`StepOutRaw`/`StepOverRaw` (no
  raise on `success:false`, for refusal tests).
- `DebuggerTests\InstructionStepDapTests.pas` (NEW, 11 tests) — DAP-layer
  plumbing tests, driving the real adapter process against the SAME
  `InstructionStepSample.exe` fixture increment 1 built (no new fixture).
- `DebuggerTests\RunTests.dpr` — registers the new unit.
- Docs: `ASSEMBLY_LEVEL_DEBUGGING.md`, `DAP_DEBUGGER_ARCHITECTURE.md`,
  `TEST_CATALOG.md`, `TRAPS.md` (one new entry: `SendErrorResponse`'s reason
  lives at `body.error.format`, not a top-level `message` field — cost one
  full-suite run before the test assertion was fixed).

### Gates

- Full suite, CONFIRMED GREEN: **1145 found / 1141 passed / 0 failed /
  0 errored / 4 ignored** — baseline 1134/1130/0/0/4 plus exactly the 11 new
  tests, all passing, both fixtures (mono + BPL, `build_and_run.bat` runs
  both). One intermediate run (1145/1140/**1 failed**/0/4) hit a TEST bug in
  `Refused_WhenNotLaunched_ReachesClientAsFailedRequest` — it read the DAP
  response's non-existent top-level `message` field instead of
  `body.error.format` (see the new TRAPS.md entry) — NOT a production defect;
  fixed and reconfirmed both in isolation and in this full run.
- Adapter, MCP, runner and DevTools all rebuilt after every source change,
  including after each RED-control mutation and its revert.
- Three RED controls, all reverted after measurement (verified via
  `RUNTESTS_ONLY`, not assumed):
  1. Comment out the `WantsInstructionGranularity` dispatch in `HandleNext`
     AND `HandleStepIn` → 5 failures: both bitnesses of the "stays on the
     same line" tests for stepIn and next (line advanced 63→64), PLUS
     `Refused_WhenNotLaunched...` (removing the dispatch also removes the
     `FLaunched` guard on that path, reintroducing the old silent-success
     shape — a bonus confirmation, not a separate control).
  2. Swap the mapped kind in `HandleStepOut` from `iskOut` to `iskInto` →
     both bitnesses of `*_StepOut_Instruction_LandsInTheCaller` fail
     (`"landed in InstrStepCallee, not in the caller"`) — a Kind-mapping
     mutation was needed here, not a plain revert: in this non-recursive
     scenario the pre-existing source-level `stepOut` already lands
     correctly in the immediate caller (same `FStepOverVA`/`FStepResumeSP`
     machinery `iskOut` reuses), so disabling the dispatch alone would not
     have changed the observable outcome.
  3. Make `HandleInstructionStep` send `success: true` unconditionally
     before calling `StepInstruction` (the pre-existing handlers' shape) →
     `Refused_WhenNotLaunched...` fails in isolation (`Condition is True
     when False expected`).
- Both bitnesses: engine primitive already both-bitness (increment 1); the
  DAP positive scenarios (stepIn/next same-line, stepOut lands in caller) run
  on both Win64 and Win32. The granularity-absent/`"statement"` regression
  controls and the refusal-routing test run once (Win64) — plain JSON-field
  parsing, no bitness-sensitive content, same scoping call already recorded
  for `setInstructionBreakpoints`' DAP layer (TEST_CATALOG.md section N).

### Not proven

- The other two increment-1 refusal reasons ("thread is not live",
  "disassembler unavailable") are UNREACHABLE through the DAP wire protocol
  by construction (`StepThreadFromArgs` folds any unmatched threadId back to
  0; there is no launch-config knob for an unavailable backend) — fully
  covered at the engine level (section O), not re-provable here.

## State of the tree

- `public-main`. Increment 1 (engine primitive) and increment 2 (this task,
  DAP plumbing) are both UNCOMMITTED by instruction. **DO NOT COMMIT.**
- Next obvious step per `ASSEMBLY_LEVEL_DEBUGGING.md`'s order: increment 4
  (MCP: registers + instruction stepping) can go in either order relative to
  increment 2; increments 3 (DAP memory) and 5 (placeholder doc) come after.
