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

**Data breakpoints (watchpoints), increment 3 of 6 — DONE and gated.** Plan,
what was built, and the negative controls run are all in
`DATA_BREAKPOINTS_PLAN.md` (increment 3 section) and `PROJECT_STATE.md`'s
roadmap entry. Full suite green before and after: 1052 found / 1048 passed /
0 failed / 0 errored / 4 ignored.

### Next action

Start **increment 4: session API + stop reason + old/new capture.**
`SetDataWatchpoint`/`ClearDataWatchpoint` currently exist only on
`IDebugTarget` and are called directly by tests/probes — there is no
session-level entry point and no stop reason yet, so a watchpoint hit today is
just logged and resumed (`TakeDebugTrapCause` in `WinDebuggerBase.pas`).

Per `DATA_BREAKPOINTS_PLAN.md` §"Where it plugs into the existing
architecture":
- **Command queue** (`DebugTarget.pas:185`, `TCommandKind`): new
  `ckSetDataBreakpoints` kind with its own spec record, so arming runs on the
  debug thread like `ckSetBreakpoints`.
- **Session** (`DebugSession.pas:220`): `SetDataBreakpoints` /
  `ListDataBreakpoints` / removal, mirroring the source-breakpoint API.
- **Stop reporting**: a new `TStopReason` value — a watchpoint stop is not a
  breakpoint stop and must not be reported as one.
- **Old/new capture**: a write watchpoint traps AFTER the store completes, so
  "new" reads at the stop; "old" must be captured when the watchpoint is armed
  and refreshed at every hit.
- Second interaction to decide deliberately (not default-swallow): a
  watchpoint firing during a synthetic call — abort the call or suppress the
  hit? The `RunMethodCall` abort-on-raise machinery
  (`FLastSyntheticCallError`) is the model to follow or deviate from,
  consciously.

No code has been written for increment 4 yet — this is a cold start.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, clean. Release **0.3.0 is committed but NOT tagged and NOT
  pushed**; no GitHub release exists. The push is the outward-facing step and
  waits on the maintainer.
- Last full suite: **1052 found / 1048 passed / 0 failed / 0 errored / 4
  ignored.** Extension suite: 152 passed / 0 failed. One unrelated flake seen
  during the increment-3 session (`Test_RtlStringGetter_VarOutFromPropertyType`
  in the BPL scenario, failed once in a full run, passed 3/3 in isolation) —
  logged, not chased.
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
