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

**`ASSEMBLY_LEVEL_DEBUGGING.md` increment 5 — the placeholder document for a
sourceless frame becomes useful. DONE, not committed; left in the tree for
review.** This was the last increment of the plan; the plan is now complete.

`TDapServer.SyntheticSourceText` (`DapServer.pas`) appends a real disassembly
section below the unchanged explanatory header: proven backward instructions
(`NearestInstructionBoundaryBefore`/`NearestExportedEntryBefore` +
`DisassembleBackward`) plus a forward decode from the frame's PC
(`BuildPlaceholderDisassembly`/`FormatPlaceholderInstruction`), reusing the
exact `disassemble`-request mechanism (increment 6): same `TZydisDisassembler`,
same `ReadCodeMemoryAt` reader (restores planted `INT3` bytes), same
symbol/line lookups. Current instruction marked `=>` plus a `<-- current
instruction` suffix; per-instruction source file/line shown where the line
table has one, with "(not found in the source path)" when the file cannot be
resolved. Zydis-unavailable falls back to naming `Disasm.StatusText`, never a
guess. The Disassembly View reference is hedged ("where it offers one") per
the plan's own constraint — no claim that a Call Stack menu entry exists.

**A plan assumption did not hold, and I stopped to report it rather than
routing around it silently (an explicit instruction for this task):**
`NoSourceStop.dpr`'s `-rtl`/`-os` fixture, driven through a normal DAP
exception stop, does NOT reach a sourceless placeholder frame — frame 0
resolves to the CALLING Delphi frame (real source), not the true fault
address, even though the exception event's own address is correct. Measured
twice independently (DAP session + `DevTools\LiveSessionProbe` against the
engine directly). Root cause NOT FOUND despite real investigation (traced
through `TWinDebugger.GetStackFrames`/`WalkRawFrames`/`FillStackWalkContext`,
which by their own code should make this impossible). Full writeup:
`KNOWN_UNKNOWNS.md`, "An exception stop's frame 0 does not reliably resolve to
the true faulting address..."; operational warning in `TRAPS.md`. Tests were
built against the ALREADY-PROVEN sourceless-frame path instead (parked worker
thread in ntdll, same fixture `Test_SourcelessFrame_HasPlaceholderDocument`
uses) — this proves the `saNoSymbols` case end-to-end; the `saLoaded` case
uses the identical code path but was not exercised by an automated fixture
(see `TEST_CATALOG.md` "T." for exactly what is and is not covered).

### Files changed

- `VisualStudioCodeDelphiDebugger\DapServer.pas` — `BuildPlaceholderDisassembly`,
  `FormatPlaceholderInstruction` (new), `SyntheticSourceText` (appends the
  disassembly section), a forward declaration for `ResolveZydisDllPath` (used
  earlier in the file than its existing definition).
- `DebuggerTests\PlaceholderDisassemblyTests.pas` (new, 2 tests) — registered
  in `RunTests.dpr`.
- Docs (same change set): `ASSEMBLY_LEVEL_DEBUGGING.md` (increment 5 writeup +
  closing status — plan complete), `DAP_DEBUGGER_ARCHITECTURE.md` ("The
  document's content — increment 5" + a `presentationHint` correction that was
  stale independent of this increment), `KNOWN_UNKNOWNS.md` (placeholder
  question removed — resolved; new exception-frame-0 entry added; a stale
  "readMemory/writeMemory on DAP — deferred" entry corrected to DONE, noticed
  while in this section), `TRAPS.md` (new entry), `TEST_CATALOG.md` (section
  T), `PROJECT_STATE.md`, `README.md` (two new feature bullets), this file.

### Gates

- **New tests RED confirmed**: `git stash` on `DapServer.pas` alone (increments
  1-4/6 are already committed as separate commits, so this reverts exactly the
  increment-5 diff), rebuilt the adapter, reran
  `Win64_WorkerParkedInNtdll_PlaceholderShowsDisassemblyWithCurrentMarker` —
  failed with `[placeholder must carry a disassembly section; got: No source
  available for this stack frame. ... Selecting a frame further down the call
  stack will open real source if any frame there has it.]` (the disassembly
  section simply absent). `git stash pop` restored the fix; rebuilt; both new
  tests green again.
- Every consumer rebuilt: `build_dap.bat`, `DevTools\build_all.bat`,
  `build_runner.bat` — all clean (only pre-existing hints).
- **Full suite green**: 1182 found / 1178 passed / 0 failed / 0 errored / 4
  ignored — baseline 1180/1176/0/0/4 plus exactly the 2 new tests, ignored
  count unchanged. Both fixtures (mono + BPL) ran (`build_and_run.bat`).
- **Not verified**: the `saLoaded` disassembly-section rendering (see above);
  the per-instruction "line known, file missing" annotation (implemented,
  reuses `disassemble`'s own tested `BuildDapInstruction` logic, but not
  independently exercised — no fixture surfaces that exact byte pattern); the
  Zydis-unavailable fallback at the DAP-process level (same limitation
  increment 1 already recorded — no external knob to force it).

## State of the tree

- `public-main`. Increments 1-4 and 6 are COMMITTED (separate commits,
  `c805e85`..`7ae434b`). Increment 5 (this task) is UNCOMMITTED by
  instruction — **DO NOT COMMIT.**
- `DebuggerTests\RunTests.dpr` modified (registers the new test file);
  `DebuggerTests\PlaceholderDisassemblyTests.pas` untracked.
- Next: review + commit increment 5 if accepted. Separately worth picking up:
  the exception-stop frame-0 finding in `KNOWN_UNKNOWNS.md` — it is a
  correctness question (a stack trace at an exception stop in unsymbolicated
  code cannot currently be trusted), independent of this plan, not chosen for
  me to fix.
