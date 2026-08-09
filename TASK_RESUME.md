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

**An exception stop must keep the faulting frame AND still answer with the right
frame's locals. DONE, not committed; left in the tree for review.**

The reported defect: an access violation inside OS code did not stop AT the
fault — the debugger reported the calling Delphi frame and the ntdll frame was
missing from the stack entirely. Cause (found, fixed):
`TSourceResolver.TrimRaisePlumbing` dropped every leading frame whose source did
not resolve on disk, and the trimmed array was assigned to `FLastFrames`, so the
frames were not hidden, they were REMOVED.

The trim was load-bearing for THREE things — which frames exist, where the editor
points, and which frame locals come from. They are now separate:

- `TSourceResolver.TrimRaisePlumbing` trims by NAME only (`IsRaisePlumbingFrame`),
  never the whole stack. `GetCallStack` keeps every frame.
- `TDebugSession.DefaultFrameIndex` (new) decides which frame ANSWERS: 0 for an
  ordinary stop, the first frame with a source file at an exception stop. Set
  once per stop in `HandleTargetStopped`, recomputed by the new `SetLastFrames`
  on every re-walk, applied by `GetLocals` / frame-less `Evaluate` /
  `GetCurrentLocation` via `ApplyDefaultFrame`.
- `SelectFrame(Index)` is now EXPLICIT for every index including 0 and always
  beats the default. `DEFAULT_FRAME_INDEX` (= -1) is how a frontend says its
  client named no frame; both frontends decide by the PRESENCE of the field
  (`Args.FindValue('frameId'/'frameIndex')`), never its value.

Rationale and the full rule table: `DAP_DEBUGGER_ARCHITECTURE.md`, "Frames versus
the active frame".

### Files changed (all uncommitted)

- `DebuggerCore/DebugSession.pas` — `DEFAULT_FRAME_INDEX`, `FDefaultFrameIndex` +
  `DefaultFrameIndex` property, `DefaultFrameIndexFor`, `SetLastFrames`,
  `ApplyDefaultFrame`; `HandleTargetStopped`, `GetCallStack`, `SelectFrame`,
  `GetLocals`, `Evaluate`, `EvaluateForFrame`, `GetCurrentLocation` updated.
- `DebuggerCore/SourceResolver.pas` — the by-name trim (was already in the tree
  when this task started; unchanged by it).
- `VisualStudioCodeDelphiDebugger/DapServer.pas` — `HandleScopes` and
  `HandleEvaluate` distinguish an absent `frameId` from `frameId: 0`.
- `MCPDebugger/McpServer.pas` — `FrameArgGiven`; `BeginSelectedFrame` /
  `EndSelectedFrame` / `evaluate_expression` distinguish absent `frameIndex`
  from `frameIndex: 0`.
- `DebuggerTests/DebugSessionTests.pas` — new
  `ExceptionStop_DefaultFrameServesLocals_ExplicitSelectionWins` (both
  bitnesses, failures collected).
- `DebuggerTests/DebuggerTests.pas` — new
  `Test_ExceptionStop_LocalsDefaultToRaisingFrame_ScopesFrameWins` (DAP wire,
  runs in both the mono and BPL fixtures).
- `DevTools/ExceptionStopProbe.dpr` (new, untracked) — drives a session to the
  first exception stop and prints the raw walk, the reported stack, the
  no-selection locals and the per-frame locals side by side.
- Docs: `DAP_DEBUGGER_ARCHITECTURE.md` (new section), `TRAPS.md` (old entry
  replaced by two), `TEST_CATALOG.md` (new section U + three corrected
  references), `KNOWN_UNKNOWNS.md` (the "exception stop's frame 0" entry
  REMOVED — resolved), `PROJECT_STATE.md`, `ASSEMBLY_LEVEL_DEBUGGING.md`
  (its "plan assumption that did not hold" now records the resolution),
  `DevTools/README.md`, this file.

### Gates

- **Full suite green**: 1184 found / 1180 passed / 0 failed / 0 errored / 4
  ignored (`build_and_run.bat`, both fixtures). Baseline before the task was
  1182/1178/0/0/4 plus one in-tree test and one in-tree failure; +1 new session
  test here, +1 new DAP test added after that run and verified filtered in both
  fixtures.
- **RED control**: `git stash push -- DebuggerCore/DebugSession.pas` leaves the
  new by-name trim in place, reproducing exactly the broken intermediate state.
  The new session test then fails with `Win64: RnInnerVal missing with no frame
  selected -- locals did not come from the default frame | Win32: <same>`. The
  `DefaultFrameIndex` assertion must be commented out for the control to
  compile.
- Every consumer rebuilt: `build_dap.bat`, `build_mcp.bat`,
  `DevTools\build_all.bat`, `build_runner.bat`.

### Open — a DESIGN DECISION deliberately NOT taken

The by-name trim removes NOTHING from an ordinary Delphi `raise` stack: frame 0
is a nameless `kernelbase.dll` frame (measured, both bitnesses), which stops the
trim before it reaches `_RaiseExcept`. So VS Code's Call Stack at ANY Delphi
exception now opens on that frame with the placeholder disassembly document,
where it used to open on the raise site. Locals are correct either way (the
default frame), but the focus is not.

A deterministic fix exists and was not applied because it redesigns work the
brief declared settled: **gate the trim on the exception KIND, which the engine
already knows** (`FExceptionObjAddr` / `LastExceptionClass` distinguish a Delphi
raise from a hardware fault). A Delphi raise trims to the raise site; a fault
trims nothing, so frame 0 stays the fault. That satisfies both cases without a
name list and without the frame-0 ambiguity. Decide before committing.

## State of the tree

- `public-main`, everything above UNCOMMITTED by instruction — **DO NOT COMMIT.**
- **A concurrent session committed `58f5961` (`feat(devtools): ExcHandlerProbe`)
  during this work.** It swept this task's `DevTools/README.md` section into its
  own commit, and it DELETED `DevTools/ExceptionStopProbe.dpr` as "an earlier
  draft ... never documented" — which was no longer true by then. The probe has
  been restored (untracked again) and the README now says how it differs from
  `ExcHandlerProbe`: that one measures where an exception is DISPATCHED to, this
  one measures what the session REPORTS at the stop. If the maintainer still
  wants only one, delete the probe AND its references in `DevTools/README.md`
  and `TEST_CATALOG.md` section U together.
- Next: review; then decide the trim-gating question above.
