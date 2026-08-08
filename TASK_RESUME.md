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

**Data breakpoints (watchpoints), increment 6 of 6 — DONE. The plan is now
COMPLETE. Not committed; left in the tree for review.**

Increment 6 is the DAP surface plus the case increments 4 and 5 both refused: a
watchpoint on a **LOCAL**. Capability `supportsDataBreakpoints`, requests
`dataBreakpointInfo` / `setDataBreakpoints`, and the `stopped` reason
`"data breakpoint"` (which was MISSING — a watchpoint stop arrived with no
`reason` at all, the DAP twin of the `McpJson.ReasonName` gap increment 5 found).

Full detail, including the `dataId` encoding, the frame-lifetime rule and every
deliberate refusal, is in `DATA_BREAKPOINTS_PLAN.md` (increment 6 section) and
`DAP_DEBUGGER_ARCHITECTURE.md` ("Data breakpoints: the request flows"). Test
inventory in `TEST_CATALOG.md`.

Files changed:
`DebuggerCore\DebugSessionTypes.pas`, `DebuggerCore\DebugSession.pas`,
`VisualStudioCodeDelphiDebugger\DapServer.pas`,
`DebuggerTests\TestTarget\TestTargetCore.pas`, `DebuggerTests\DapClient.pas`,
`DebuggerTests\DebuggerTests.pas`, `DebuggerTests\DebugSessionTests.pas`,
plus the docs above and `PROJECT_STATE.md` / `README.md`.

Full suite: **1081 found / 1077 passed / 0 failed / 0 errored / 4 ignored**
(delta vs the increment-5 baseline of 1065/1061 is exactly the 16 new tests:
5 DAP tests × 2 fixtures, 4 session tests, 2 Win32 mirrors).

Negative controls run and reverted, each RED with the intended message:
removed `stopped` reason case; `read` access accepted instead of refused;
Registers-scope branch dropped; `PruneStaleDataBreakpoints` disabled;
arm-time frame-liveness test disabled.

### Next action

Nothing pending on data breakpoints. The next roadmap item is the operator's
choice — `DISASSEMBLY_PLAN.md` (disassembly + address breakpoints, DESIGNED, not
built) is the ranked successor, and the two smaller gaps this increment left
open, both written up in `DATA_BREAKPOINTS_PLAN.md` §"Deferred", are:

- a watchpoint on a FIELD of an expanded object/record (needs expansion handles
  to carry the address of what they expanded, not a heuristic);
- applying a `setDataBreakpoints` that arrives while the target is RUNNING
  (needs a pending-set queue plus a corrective `breakpoint` event).

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with the increment 5 AND increment 6 work uncommitted. Release
  **0.3.0 is committed but NOT tagged and NOT pushed**; no GitHub release exists.
  The push is the outward-facing step and waits on the maintainer.
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
