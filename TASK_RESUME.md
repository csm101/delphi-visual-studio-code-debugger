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

**`DISASSEMBLY_PLAN.md` increment 5 — address breakpoints. DONE, not
committed; left in the tree for review.** Full detail (identity design, the
cross-layer bug caught by the tests, every proof) lives in
`DISASSEMBLY_PLAN.md` "Address breakpoints — the design point" and "Verified
in increment 5" — this cursor is a pointer, not a repeat.

Both design points the task flagged as likely STOP candidates were resolved
without a maintainer decision, because the plan text already answered them:
identity stays module+RVA internally but the client-facing surface (MCP tool,
`setInstructionBreakpoints`) only ever sees a plain address; module unload
needed no new engine code (the existing VA-range unplant sweep in
`TWinDebugger.HandleUnloadDll` is kind-agnostic), only a session-level
`Verified` flip, and the plan's own words ("Deferred binding when the module
loads should follow the path source breakpoints already use") pointed
directly at reusing `RepostBreakpoints`'s SHAPE for `RepostAddressBreakpoints`.

### Files changed this session

Engine/session: `DebuggerCore\DebugTarget.pas` (`TBreakpointKind`,
`TAddrBpSpec`, `ckSetAddressBreakpoints`), `WinDebuggerBase.pas`
(`ClearAddressBreakpointsByModule`, `DoSetAddressBreakpoints`, mirrors the
source-bp equivalents, wired into `ProcessCommandQueue` +
`DrainBreakpointCommands` — `HandleUnloadDll` needed NO change),
`DebugSessionTypes.pas` (`TSessionBreakpoint` gained
`Kind`/`ModuleName`/`Rva`/`Address`/`Message`), `DebugSession.pas`
(`SetAddressBreakpoint`, `RemoveAddressBreakpoint`, `ResolveModuleForAddress`,
`EngineModuleNameFor`, `RepostAddressBreakpoints`, hooked into
`HandleDllLoaded`/`HandleDllUnloaded`/`RemoveAllBreakpoints`).
MCP: `McpJson.pas`, `McpServer.pas` (`set_breakpoint_at_address` /
`remove_breakpoint_at_address`), `McpToolSchemas.pas`.
DAP: `DapServer.pas` (`HandleSetInstructionBreakpoints`, `FInstrBpIds`
mirrors `FDataBpOwnIds`, `supportsInstructionBreakpoints: true`).
Tests: `DapClient.pas` (`SetInstructionBreakpoints` helper),
`DebugSessionTests.pas` (6 `AddrBp_*`), `McpE2ETests.pas` (4 tests, both
bitnesses), `DebuggerTests.pas` (2 `Test_SetInstructionBreakpoints_*`,
inherited by `TDebuggerTestsBpl` too → 4 instances; `CurrentRipHex` helper).
Docs: `DISASSEMBLY_PLAN.md`, `DAP_DEBUGGER_ARCHITECTURE.md`, `MCP_SERVER.md`,
`TEST_CATALOG.md`, `PROJECT_STATE.md`, `TRAPS.md` (3 new entries).

### A real bug the tests caught, not designed around in advance

The main-exe module-name SENTINEL differs by layer (`''` at the engine,
matching `FDllBases`; the real lowercase filename at the session, from
`GetModules`). The first cut sent the friendly name straight to the engine,
so every main-exe address breakpoint resolved `Verified=True` at the session
layer but the engine silently dropped the plant.
`AddrBp_MainExe_SetAtKnownAddress_StopsThere` caught it on its FIRST run:
`Expected [5] but got [6] address breakpoint did not stop the target (not
planted?)`. Fixed with `TDebugSession.EngineModuleNameFor`. Full trail in
`DISASSEMBLY_PLAN.md` "Verified in increment 5"; the trap itself in
`TRAPS.md`.

### Proven, not just implemented

All 6 new `DebugSessionTests` tests plus the DAP dispatch wiring
negative-controlled (revert/disable, re-run, confirm the intended failure
text, revert back) — exact messages in `DISASSEMBLY_PLAN.md`. One control
needed a second try: disabling only `HandleDllLoaded`'s repost did NOT break
`AddrBp_Bpl_UnloadReload_Rebinds`, because `HandleDllUnloaded`'s own queued
command gets drained by the next load event anyway — both sites had to be
disabled together (now recorded in `TRAPS.md`).

### Not done, not blocking

No mid-flight fixture for the unload `Verified` transition (only the
eventual refire is asserted); no live DAP `breakpoint`-changed event on an
address breakpoint's verified-flip (a follow-up, not a correctness gap —
`list_breakpoints` still reports the truth); no DAP-layer Win32 test
(bitness proven at the MCP layer instead, a scoping choice recorded in
`TEST_CATALOG.md`). Full list in `DISASSEMBLY_PLAN.md` "Verified in
increment 5".

### Full suite

`DebuggerTests\build_and_run.bat`, run once via the test-runner agent:
**1108 found / 1104 passed / 0 failed / 0 errored / 4 ignored** — exact +14
delta over the increment-4 baseline (1094/1090/0/0/4), matching the 14 new
tests (6 `AddrBp_*` + 4 `McpE2ETests` + 2 `Test_SetInstructionBreakpoints_*`
× 2 fixtures). Every consumer rebuilt first: `build_mcp.bat`,
`DevTools\build_all.bat`, `build_dap.bat`, `DebuggerTests\build_runner.bat`.

### Next action

Increment 6 (`DISASSEMBLY_PLAN.md` "Increments"): DAP `disassemble` +
`instructionPointerReference`. Not started. MUST reuse
`Disassembler.DisassembleBackward` + `IDebugTarget
.NearestInstructionBoundaryBefore`/`NearestExportedEntryBefore` for its
negative `instructionOffset`, per the increment-4 decision already recorded.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with THIS increment, disassembly increments 1-4, and the
  prior data-breakpoints increment (6/6) all uncommitted. Release **0.3.0
  is committed but NOT tagged and NOT pushed**; no GitHub release exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.
- `DebuggerTests\DebugSessionTests.pas` and `DebuggerTests\DebuggerTests.pas`
  are LF-only line endings end to end (confirmed pre-existing at HEAD, not
  introduced this session — `.gitattributes` will normalize on the next git
  operation regardless). Not touched further; out of scope for this task.

## Traps

`TRAPS.md` has full detail; this session added three entries there (the
main-exe module-name sentinel mismatch, `@FuncName` rendering as `"Pointer"`,
and the two-repost-call-sites negative control) rather than repeating them
here.
