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

**`ASSEMBLY_LEVEL_DEBUGGING.md` increment 1 — the engine primitive for stepping
ONE INSTRUCTION. DONE, not committed; left in the tree for review.** No DAP and
no MCP surface, by design — those are increments 2 and 4, and they are the
obvious next step.

Mechanism: `DAP_DEBUGGER_ARCHITECTURE.md` "Instruction granularity".
Decisions + their negative controls: `ASSEMBLY_LEVEL_DEBUGGING.md`, increment 1.
Coverage: `TEST_CATALOG.md` "O.". This cursor is a pointer, not a repeat.

### Files changed

- `DebuggerCore\DebugTarget.pas` — `TInstructionStepKind`, `TInstrStepPlan`,
  `ckStepInstruction`, `IDebugTarget.StepInstruction` / `SetInstructionDisassembler`.
- `DebuggerCore\WinDebuggerBase.pas` — `smInstr`; the two-phase decide/execute
  split; `RearmStepBpAfterForeignHit` + `FSteppingOffStepBp` (also fixes the
  source-level `smOver` guard).
- `DebuggerCore\ZydisDisassembler.pas` — `ResolveZydisDllPathForThisExe`.
- `DebuggerCore\DebugSession.pas` — `StepInstruction` facade.
- `DebuggerTests\` — `InstructionStepTests.pas` (NEW, 16 tests),
  `TestTarget\InstructionStepSample.dpr` (NEW fixture), `build_target.bat`,
  `RunTests.dpr`, `ValueReaderTests.pas` (`TFakeMemTarget` stubs).
- Docs: `ASSEMBLY_LEVEL_DEBUGGING.md`, `DAP_DEBUGGER_ARCHITECTURE.md`,
  `TRAPS.md`, `TEST_CATALOG.md`, `PROJECT_STATE.md`.

### Gates, all met

- Full suite: **1134 found / 1130 passed / 0 failed / 0 errored / 4 ignored** —
  the 1118/1114 baseline plus exactly the 16 new tests.
- Adapter, MCP, runner and DevTools all rebuilt AFTER the last revert.
- Every new test proven RED by removing its own rule (failure text recorded in
  `ASSEMBLY_LEVEL_DEBUGGING.md` / `TEST_CATALOG.md`). One control is weaker and
  is labelled as such: deleting the `Available` check still refuses (the decode
  check catches it), only with a reason that no longer names the backend.
- Both bitnesses, as separate test cases.

### Not proven

- The `iskOut` refusal branch for "no return address can be proven at all" has no
  fixture — dbghelp knows every test module, the same limitation `TRAPS.md`
  already records for the x86 walk. The refusal MECHANISM is covered by the
  unavailable-backend test.
- `StepInstruction`'s decision phase runs on the REQUESTING thread and calls
  `CallerReturnAddress` (dbghelp) for `iskOut`. That matches what `stackTrace`
  already does from the request thread, but increments 2/4 should keep the call
  on that same thread rather than introducing a third.

## State of the tree

- `public-main`, clean at session start (increment 7 packaging is committed:
  `2022242`). Everything above is UNCOMMITTED by instruction. **DO NOT COMMIT.**
