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

**`DISASSEMBLY_PLAN.md` increment 4 — MCP `disassemble`. DONE, not
committed; left in the tree for review.** Full detail (exact code shape, the
backward-disassembly decision, every proof) lives in `DISASSEMBLY_PLAN.md`
"Decision: backward disassembly is proven-boundary-only" and "Verified in
increment 4" — this cursor is a pointer, not a repeat.

Mid-task design decision, taken by the maintainer (not decided
unilaterally): the plan named a `before` parameter without specifying HOW to
compute "instructions preceding an address" on a variable-length ISA that
cannot be decoded backwards. Resolved as **proven-boundary-only**: answer
`before` only when a PROVEN earlier instruction boundary (debug info, or a
module's PE export table when it has none) decodes forward to land EXACTLY
on the address; refuse with a stated reason otherwise, while the forward
`instructions` are still returned untouched. `frameId` (also unspecified in
shape) became `frameIndex`+`threadId`, reusing the convention
`get_locals`/`get_variable`/`evaluate_expression` already use.

### Files changed this session

- `DebuggerCore\DebugTarget.pas` — `IDebugTarget` gained
  `NearestInstructionBoundaryBefore` (promoted from `TWinDebugger`-only
  `protected`, no body change) and `NearestExportedEntryBefore` (new).
- `DebuggerCore\WinDebuggerBase.pas` — `TWinDebugger.NearestExportedEntryBefore`:
  PE export-table lookup read from the LIVE mapped image.
- `DebuggerCore\Disassembler.pas` — `DisassembleBackward` (library-free,
  reusable by increment 6): forward-decode-and-verify-exact-landing.
- `DebuggerTests\ValueReaderTests.pas` — `TFakeMemTarget` trivial
  `False`-returning implementations of both new `IDebugTarget` methods.
- `DebuggerTests\DisassemblerTests.pas` — `TDisassembleBackwardTests` (2
  tests), registered.
- `MCPDebugger\McpJson.pas` — `DisasmInstructionToJson` /
  `DisasmInstructionListToJson`.
- `MCPDebugger\McpServer.pas` — `TMcpServer.HandleDisassemble` +
  `ResolveZydisDllPath`/`DefaultZydisDllPath`/`ModuleNameForVA` helpers;
  dispatch wired for tool name `disassemble`.
- `MCPDebugger\McpToolSchemas.pas` — `disassemble` tool schema/description.
- `DebuggerTests\McpE2ETests.pas` — 5 new tests (`Disassemble_Forward_...`,
  `..._ViaFrameIndex_...`, `..._Before_...`, `..._Win32_...`,
  `..._ReportsUnavailable_...`), `TargetExe32` helper, registered (existing
  fixture, no new `RegisterTestFixture` needed).
- Docs in this change set: `DISASSEMBLY_PLAN.md` (increment 4 status +
  "Decision: backward disassembly is proven-boundary-only" +
  "Verified in increment 4"), `MCP_SERVER.md` (`disassemble` tool entry,
  documents the address-field reuse), `TEST_CATALOG.md` ("M. Disassembly"
  extended), `PROJECT_STATE.md` (roadmap pointer updated).

### Proven, not just implemented

- Both new `DisassembleBackward` unit tests and 2 of the 5 new MCP E2E tests
  negative-controlled (fix reverted, failure text matches the intended
  defect exactly) — full messages in `DISASSEMBLY_PLAN.md` "Verified in
  increment 4".
- `Disassemble_Win32_Forward_ReturnsDecodedInstructions` — genuine x86
  bitness coverage at the MCP layer (Zydis decoding through the same x64
  DLL, `machineMode:"x86"`).
- `Disassemble_ReportsUnavailable_WhenZydisDllNotFound` — real isolated copy
  of `DelphiDebuggerMcp.exe`, not simulated.

### Not done, not blocking

- `NearestExportedEntryBefore`'s PE-export path has no automated fixture
  (kernel32/ntdll's export tables are too large for a targeted regression;
  see `TEST_CATALOG.md` "M. Disassembly"). Exercised only by construction
  (same byte layout `DevTools\DisasmCoverage.dpr`'s `TPEImage` already
  validates against real binaries).
- `set_breakpoint_at_address` (increment 5) and DAP `disassemble` /
  `instructionPointerReference` (increment 6) not started. Increment 6 MUST
  call `Disassembler.DisassembleBackward` +
  `IDebugTarget.NearestInstructionBoundaryBefore`/`NearestExportedEntryBefore`
  for its negative `instructionOffset`, not re-derive backward disassembly —
  the decision is recorded in `DISASSEMBLY_PLAN.md`.

### Full suite

`DebuggerTests\build_and_run.bat`, run once via the test-runner agent:
**1094 found / 1090 passed / 0 failed / 0 errored / 4 ignored** — exact +7
delta over the increment-3 baseline (1087/1083/0/0/4), matching the 7 new
tests (2 `TDisassembleBackwardTests` + 5 `TMcpE2ETests.Disassemble_*`).
Every consumer rebuilt first: `build_mcp.bat`, `DevTools\build_all.bat`,
`build_dap.bat`, `DebuggerTests\build_runner.bat`.

### Next action

Increment 5 (`DISASSEMBLY_PLAN.md` "Increments"): address breakpoints in
`DebugSession` (module+RVA identity, deferred bind), then the MCP tool, then
`setInstructionBreakpoints` over DAP. Not started.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with THIS increment, disassembly increments 1-3, and the
  prior data-breakpoints increment (6/6) all uncommitted. Release **0.3.0
  is committed but NOT tagged and NOT pushed**; no GitHub release exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Traps

`TRAPS.md` has full detail. New this session:

- **A `protected` method on a class already satisfies a `public` interface
  method with the same signature in Delphi** — no visibility change needed
  to add `NearestInstructionBoundaryBefore` to `IDebugTarget`; it was already
  implemented, just not yet declared on the interface.
- **Every `IDebugTarget` implementer must gain a new interface method** —
  only two exist (`TWinDebugger`, `TFakeMemTarget` in
  `DebuggerTests\ValueReaderTests.pas`); grep `, IDebugTarget)` to find them
  both before adding one.
- Rebuild EVERY consumer (`build_mcp.bat`, `DevTools\build_all.bat`,
  `build_dap.bat`, `build_runner.bat`) before trusting a measurement — all
  four rebuilt clean this session after the `IDebugTarget` change.
