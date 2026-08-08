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

**`DISASSEMBLY_PLAN.md` increment 6 — DAP `disassemble` + `instructionPointerReference`.
DONE, not committed; left in the tree for review.** This closes the FUNCTIONAL
plan: increments 1-6 are all landed. Only increment 7 (packaging: ship
`Zydis.dll` with the installed adapter/MCP server, decide `/MD` vs `/MT`)
remains. Full detail (the DAP-spec-mandated refusal shape, every proof, every
negative control) is in `DISASSEMBLY_PLAN.md` "Verified in increment 6" and
"Functional plan closed" — this cursor is a pointer, not a repeat.

### The one design question resolved without a maintainer STOP

The task flagged "how a refusal reaches VS Code" as possibly ambiguous. It was
not: the DAP spec ITSELF answers it. `DisassembleArguments.instructionCount`
(`debugAdapterProtocol.json`) requires returning EXACTLY that many entries,
"any unavailable instructions ... replaced with an implementation-defined
'invalid instruction' value"; `DisassembledInstruction.presentationHint:
'invalid'` is documented as exactly that mechanism ("filler ... cannot be
reached by the program"). Confirmed by fetching the schema directly, not
recalled from memory. `BuildInvalidDapInstruction` in `DapServer.pas`
implements it: no `instructionBytes`, `instruction: '??'`, a synthetic filler
`address` anchored on the nearest thing actually proven.

### Files changed this session

`VisualStudioCodeDelphiDebugger\DapServer.pas`: `supportsDisassembleRequest`
capability; `instructionPointerReference` on every `StackFrame`
(`HandleStackTrace`); `HandleDisassemble` (+ `BuildDapInstruction` /
`BuildInvalidDapInstruction` / local `ResolveZydisDllPath`); dispatch wiring.
Reuses `Disassembler.DisassembleBackward` +
`IDebugTarget.NearestInstructionBoundaryBefore`/`NearestExportedEntryBefore`
exactly as increment 4's decision required — no second backward mechanism.
`DebuggerTests\DapClient.pas`: `Disassemble`/`DisassembleRaw` helpers.
`DebuggerTests\DebuggerTests.pas`: `ParseHex64`/`TopInstructionPointerRef`
helpers, 5 new `[Test]` methods (each runs under mono + BPL).
Docs: `DISASSEMBLY_PLAN.md`, `DAP_DEBUGGER_ARCHITECTURE.md`, `TEST_CATALOG.md`,
`PROJECT_STATE.md`, `KNOWN_UNKNOWNS.md` (removed the now-resolved
"Disassembly view unimplemented" entry), `README.md`.

### Proven, not just implemented

All 5 new tests negative-controlled (revert the fix, rebuild the adapter,
rerun via `RUNTESTS_ONLY`, confirm the intended failure text, revert back) —
5 independent controls: capability flag forced False, the
`instructionPointerReference` `AddPair` commented out, the `disassemble`
dispatch line commented out, `HaveBoundary` forced False in the backward-slot
builder, `presentationHint` omitted from the invalid-slot builder. Exact
failure text for each in `DISASSEMBLY_PLAN.md` "Verified in increment 6".

### Full suite

Filtered runs (`RUNTESTS_ONLY`) during development: all green, 22/22 on the
"Disassemble" substring, 2/2 on each of the two standalone tests, both before
AND after each negative control's revert (i.e. both the RED and the
re-GREEN were observed, not assumed).

Full unfiltered suite via the `test-runner` agent (`build_and_run.bat`):
**1118 found / 1114 passed / 0 failed / 0 errored / 4 ignored** — exact +10
delta over the increment-5 baseline (1108/1104/0/0/4), matching the 5 new
tests × 2 fixtures (mono + BPL). (First guess while writing this cursor was
"6 new tests / +12" — miscounted; the actual test list only ever had 5
`[Test]` declarations. Caught by the delta not matching the guess, not by
re-reading the source — a live example of why this section states the
MEASURED number, not the expected one.)

### Not done, not blocking

No test drives an actual VS Code Disassembly View — every assertion is at the
DAP protocol layer (`DapClient.pas`). No DAP-layer Win32 coverage for
`disassemble` (bitness proven at the MCP layer, same scoping choice increment
5 made for `setInstructionBreakpoints`). The mixed
backward-and-forward-straddling `instructionOffset` case is covered by
construction (the `TrueNegCount`/`PosCount` split in `HandleDisassemble`
handles it uniformly) but has no dedicated test. Full list in
`DISASSEMBLY_PLAN.md` "Verified in increment 6".

### Next action

**Increment 7 — packaging** (`DISASSEMBLY_PLAN.md` "Increments", item 7). Not
started. Three parts: ship `Zydis.dll` next to the installed adapter AND the
MCP server build (`install\Install.exe`, the extension folder, `build_mcp.bat`
output); ship the MIT licence text alongside it; decide `/MD` vs `/MT` for the
committed DLL (currently `/MD`, needs the VC++ redistributable on the user's
machine — the honest-but-not-acceptable-default failure mode the plan already
names). Until increment 7 lands, disassembly/address-breakpoints pass every
test in this build tree but report UNAVAILABLE (or fail cleanly on DAP) on an
installed user's machine.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with disassembly increments 1-6 (this session's increment 6
  included) and the prior data-breakpoints increment (6/6) all uncommitted.
  Release **0.3.0 is committed but NOT tagged and NOT pushed**; no GitHub
  release exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Traps

`TRAPS.md` has full detail; no new entries were needed this session — every
mechanism increment 6 relies on (`DisassembleBackward`, the boundary lookups,
the main-exe module-name sentinel) was already documented from increments 2-5.
