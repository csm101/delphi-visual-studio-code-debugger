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

## Current task (2026-08-08)

**Data breakpoints (watchpoints), increment 5 of 6 — DONE, not yet committed.**
MCP tool surface (`set_data_breakpoint` / `list_data_breakpoints` /
`remove_data_breakpoint` in `MCPDebugger\McpServer.pas` / `McpToolSchemas.pas`,
JSON shape in `McpJson.pas`) over the increment-4 session API. Also fixed a
real bug found while wiring it: `McpJson.ReasonName` had no case for
`srDataBreakpoint`, so a watchpoint stop reported `stopReason:"unknown"` over
MCP. Full detail (including the granularity mismatch between the session's
whole-set-replace API and the MCP tools' add/remove-one shape, and how it was
resolved without touching the session) in `DATA_BREAKPOINTS_PLAN.md`
(increment 5 section) and `TEST_CATALOG.md`. 6 new tests in
`DebuggerTests\McpE2ETests.pas` (`DataBreakpoint_*`); two negative controls run
(revert `ReasonName` case, revert the `access="read"` refusal) — both failed
exactly as expected, then reverted back and reconfirmed green. Full suite:
1065 found / 1061 passed / 0 failed / 0 errored / 4 ignored (delta vs the
increment-4 baseline of 1059/1055 is exactly the 6 new tests).

**Not committed yet** — left in the tree for review, per instruction.

### Next action

Start **increment 6: DAP capabilities and requests** (not started).
`supportsDataBreakpoints`, request `dataBreakpointInfo` (variable reference ->
`dataId` + supported access types, needed for LOCALS which increment 5
explicitly refused), request `setDataBreakpoints`, the `stopped` event with
the new reason/description, and address-form persistence across relaunch. See
`DATA_BREAKPOINTS_PLAN.md` §"Surfaces" (DAP half) and increment 5's own
section for what the MCP side already proved works (old->new capture, thread
attribution, the read-only-watchpoint caveat) so increment 6 does not
re-derive it.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, clean. Release **0.3.0 is committed but NOT tagged and NOT
  pushed**; no GitHub release exists. The push is the outward-facing step and
  waits on the maintainer.
- Last full suite: **1065 found / 1061 passed / 0 failed / 0 errored / 4
  ignored.** One unrelated flake seen during the increment-3 session
  (`Test_RtlStringGetter_VarOutFromPropertyType` in the BPL scenario, failed
  once in a full run, passed 3/3 in isolation) — logged, not chased, not seen
  again in increment 4 or 5's runs.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Open, not failing

Two items carried in `KNOWN_UNKNOWNS.md`, both still true:

- x86 loses a framed caller when a FRAMELESS routine sits between two framed ones
  (`StackAcrossRtlCallback_...`, still `[Ignore]` TODO-RED). The design for the
  recovery is written down there; the previous attempt failed because the
  `finally`-handler address from the try/finally exception record sits in the same
  gap and passed the old byte-scan test. It should now be rejected by
  `X86Decode.CallSiteEndsAt`, which proves a candidate follows a real `call`.
- Interface concrete-class label, x86 only: reverted after `EIntOverflow` inside
  the RTTI readers failed the whole `variables` request. Cause NOT located, and
  bisection did not converge — do not retry blindly.

The remaining open defects (string arguments to a synthetic call, `Length()`
returning `Int64`, `^Element` instead of `TArray<T>`, the unresolved-local binding
to a garbage global, the MCP-vs-DAP warm-up asymmetry) are listed in
`KNOWN_UNKNOWNS.md` and `MCP_LIVE_FINDINGS_TODO.md`.

## Traps

`TRAPS.md`. The four that bite most often, repeated here because they cost whole
sessions:

- Rebuild EVERY consumer of `DebuggerCore` before trusting a measurement —
  `build_runner.bat` rebuilds neither the adapter nor the probes.
- Never edit `DebuggerTests\TestTarget\*.pas` while the suite runs.
- Never run the suite twice at once; a healthy run is ~400 s and is I/O-bound.
- Prove a fix with a negative control, on both bitnesses and both fixtures.
