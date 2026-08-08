# TASK_RESUME

The cursor inside the task in flight, and nothing else.

**This file is OVERWRITTEN, not appended to, and stays under ~150 lines.** It grew
to 3343 lines (~91k tokens) by being used as a lab journal, until reading it cost
more than reading the code it described — and by then its "next action" pointed at
work finished weeks earlier, which is worse than having no cursor at all. It was
cut back on 2026-08-08; the content it held was triaged into the documents below,
and the rest is in the commit history.

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

**Data breakpoints (watchpoints), increment 1.** Plan:
`DATA_BREAKPOINTS_PLAN.md`. Nothing implemented yet.

Increment 1 is a DevTools probe that arms a hardware debug register by hand and
observes the hit, on BOTH bitnesses. It deliberately does not touch the event
pump; it exists to answer the one question that could invalidate the plan.

**The question to answer first:** do debug registers set through
`Wow64Get/SetThreadContext` with `WOW64_CONTEXT_DEBUG_REGISTERS` survive on a
WOW64 target, and do they survive a context switch? The x64 answer is frequently
correct by accident and wrong under emulation — that is the standing lesson of the
Win32 port.

### Next action if interrupted right now

Write `DevTools\DataBpProbe.dpr`: launch a 32-bit and a 64-bit `TestTarget`, arm
`DR0` for write on a known global, continue, and report whether the hit arrives,
which `DR6` bit is set, and whether the write completed before the trap. Build via
`DevTools\build_all.bat`.

### Chosen sequencing

Data breakpoints first, to completion; disassembly (`DISASSEMBLY_PLAN.md`)
afterwards. Not interleaved: both end at the same gate (the suite, ~400 s, never
run twice at once), so two open features make any red ambiguous.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented. This has already forced two rewrites (dynamic-array detection by
memory probing, nested-type detection by name shape) and it applies to everything
written here.

## State of the tree

- `public-main`, clean. Release **0.3.0 is committed but NOT tagged and NOT
  pushed**; no GitHub release exists. The push is the outward-facing step and
  waits on the maintainer.
- Last full suite: **1040 found / 1036 passed / 0 failed / 0 errored / 4 ignored.**
  Extension suite: 152 passed / 0 failed.
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
