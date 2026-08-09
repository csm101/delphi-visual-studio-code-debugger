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

**`ASSEMBLY_LEVEL_DEBUGGING.md` increment 4 — MCP: registers and instruction
stepping. DONE, not committed; left in the tree for review.** Thin plumbing on
top of increment 1's engine primitive (`TDebugSession.StepInstruction`,
`GetRegisters`/`SetRegister`) — no new engine code.

Mechanism, both refusal surfaces, the WOW64 `set_register` caveat, and the
non-obvious `step_out` RED control: `DAP_DEBUGGER_ARCHITECTURE.md`, "Registers
and instruction stepping (MCP) — increment 4". Decisions (why `granularity` on
the existing tools, not a `step_instruction` tool): `ASSEMBLY_LEVEL_DEBUGGING.md`
increment 4. Coverage: `TEST_CATALOG.md` "Q.". This cursor is a pointer, not a
repeat.

### Files changed

- `MCPDebugger\McpServer.pas` — `get_registers`/`set_register` dispatch (gated
  on `Stopped`, going through `FSession.GetRegisters`/`SetRegister`); new
  `TMcpServer.HandleStepTool` (shared by `step_over`/`step_into`/`step_out`,
  reads an optional `granularity` arg, calls `TDebugSession.StepInstruction`
  BEFORE arming the wait so a refusal reaches the caller as `isError:true`);
  forward-declared `ParseAddress` (was previously only referenced after its
  own definition; `set_register` now calls it earlier in the file).
- `MCPDebugger\McpJson.pas` — `RegisterToJson`/`RegisterListToJson`
  (`{name, value, size}`, `value` a variable-width hex string).
- `MCPDebugger\McpToolSchemas.pas` — `get_registers`/`set_register` tool
  schemas; `granularity` documented on `step_over`/`step_into`/`step_out`.
- `DebuggerTests\McpE2ETests.pas` (+22 tests, +2 free-function helpers
  `McpExePath`/`OpenInstrSampleAt`, +3 snapshot readers
  `SnapshotLine`/`SnapshotFunction`/`SnapshotIp`) — registers (5) + stepping
  (8 procedures, 2 run on both bitnesses = ~10 test cases). No other files
  in `DebuggerTests\` changed; `RunTests.dpr` already registers
  `McpE2ETests`.
- Docs (same change set): `ASSEMBLY_LEVEL_DEBUGGING.md` (increment 4 status +
  capability table), `MCP_SERVER.md` (Registers section, `granularity` on the
  step tools), `DAP_DEBUGGER_ARCHITECTURE.md` (new subsection), this file.

### Design decision made (not left open)

`granularity` argument on the EXISTING `step_over`/`step_into`/`step_out`,
not a `step_instruction` tool — the three tool names already name the three
`TInstructionStepKind` values 1:1; a fourth tool would have reintroduced that
choice as a `kind` argument, duplicating a distinction the surface already
makes by which tool is called.

### Gates

- **Isolated filtered runs, all GREEN after the final rebuild**: `RUNTESTS_ONLY`
  passes for `Register` (10/10), `StepInto_Instruction` (4/4), `StepOut_
  Instruction` (4/4), `StepOver_` (5/5), `GranularityAbsent` (3/3).
- **Full suite (`build_and_run.bat`) — CONFIRMED GREEN**: 1159 found / 1155
  passed / 0 failed / 0 errored / 4 ignored — baseline 1145/1141/0/0/4 plus
  exactly the 14 new `[Test]` procedures (5 registers + 9 stepping), all
  passing, ignored count unchanged.
- Every consumer rebuilt after the final revert: `build_mcp.bat`,
  `build_dap.bat`, `DevTools\build_all.bat` — all clean (only pre-existing
  hints/warnings).
- **Four RED controls, all reverted and reconfirmed clean** (verified via
  `RUNTESTS_ONLY`, mutation source diffed clean afterward — no stray
  `RED_CONTROL` markers left):
  1. Rename the `get_registers`/`set_register` dispatch strings → 3 fail
     outright (`Unknown tool: ...` surfaces in the assertion message) + 2
     error with "Invalid class typecast" (array expected, got the plain-text
     error).
  2. Force `HandleStepTool`'s `"instruction"` branch to `if False and ...` →
     3 of 4 `StepInto_Instruction_*` tests fail (both bitness "same line"
     assertions, plus the disassembler-unavailable refusal test, which now
     silently succeeds instead of refusing). The 4th
     (`RefusedBeforeLaunch`) is NOT a valid control for this mutation — see
     TEST_CATALOG.md section Q for why.
  3. Swap `Kind` from `iskOut` to `iskInto` in the `step_out` dispatch call
     → both `StepOut_Instruction_LandsInTheCaller` cases fail. A plain
     dispatch-disable revert does NOT fail this test (measured before
     settling on this control) — same non-obvious-negative-control shape
     increment 2's DAP `HandleStepOut` test already hit.
  4. Disable the unknown-granularity validation branch → `StepOver_
     UnknownGranularity_Refused` fails: the bogus value is silently accepted
     and the program counter visibly advances.
- **Not verified**: `set_register` on a WOW64 (32-bit) target.
  `SetRegisterByName` has no WOW64 override, unlike `ReadThreadRegisters`
  (which does, and IS verified both-bitness via `get_registers`). If a
  WOW64 write turns out wrong, that is a pre-existing engine gap shared
  identically by DAP's Registers-scope `setVariable`, not introduced here.
  The `iskOut` "no provable return address" refusal still has no fixture
  (same reason as section O: needs unwind-data-less x64 code; dbghelp knows
  every test module).

## State of the tree

- `public-main`. Increments 1, 2 and 4 are all UNCOMMITTED by instruction.
  **DO NOT COMMIT.**
- Next obvious step per `ASSEMBLY_LEVEL_DEBUGGING.md`'s order: increment 3
  (DAP: `readMemory`/`writeMemory`, `memoryReference` on variables) — the
  engine work already exists (MCP's `read_memory`/`write_memory`), this is
  surface only. Increment 5 (placeholder doc) comes last.
