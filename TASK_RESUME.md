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

**Data breakpoints (watchpoints), increment 4 of 6 — DONE and gated.** Session
API (`SetDataBreakpoints`/`ListDataBreakpoints`/`RemoveAllDataBreakpoints`), the
new `srDataBreakpoint` stop reason with old->new capture, and the
synthetic-call abort interaction are all built, tested (mono + Win32) and
green. Full detail in `DATA_BREAKPOINTS_PLAN.md` (increment 4 section) and
`PROJECT_STATE.md`'s roadmap entry — both updated in this change set. Full
suite: 1059 found / 1055 passed / 0 failed / 0 errored / 4 ignored.

### Next action

Start **increment 5: MCP tool surface.** Per `DATA_BREAKPOINTS_PLAN.md`
§"Surfaces": `set_data_breakpoint(address | expression, size, access)` with
`access` one of `write`/`readWrite` (`read` refused, explained — x86 has no
read-only watchpoint), `list_data_breakpoints`, `remove_data_breakpoint`; the
stop payload names the watched address, the firing thread, and old/new. The
session-level plumbing this needs already exists (`SetDataBreakpoints` etc. in
`DebugSession.pas`) — this increment is the MCP tool schema + handler wiring
(`McpServer.pas`, `McpToolSchemas.pas`) plus surfacing `srDataBreakpoint` /
`DataBreakpointDescription` through `get_compact_debug_snapshot` and whatever
stop-notification path MCP uses (check how `srException` is surfaced there
today and mirror it). No code written yet for increment 5 — cold start.

DAP surfaces (increment 6: `supportsDataBreakpoints`, `dataBreakpointInfo`,
`setDataBreakpoints`, address-form persistence across relaunch) are also not
started.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, clean. Release **0.3.0 is committed but NOT tagged and NOT
  pushed**; no GitHub release exists. The push is the outward-facing step and
  waits on the maintainer.
- Last full suite: **1059 found / 1055 passed / 0 failed / 0 errored / 4
  ignored.** One unrelated flake seen during the increment-3 session
  (`Test_RtlStringGetter_VarOutFromPropertyType` in the BPL scenario, failed
  once in a full run, passed 3/3 in isolation) — logged, not chased, not seen
  again in increment 4's runs.
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
