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

**`DISASSEMBLY_PLAN.md` increment 1 — Zydis dependency landed. DONE, not
committed; left in the tree for review.**

No feature or engine behaviour changed. Deliverables, all present:

- `ThirdParty\Zydis\zydis.submodule` — submodule on `zyantific/zydis`, pinned
  to tag `v4.1.1` (commit `a2278f1d2`), nested `dependencies/zycore` at
  `0b2432ced`.
- `ThirdParty\Zydis\bin\x64\Zydis.dll` (+ `.sha256`) — built via
  `build_zydis.bat` (VS2026/MSVC 14.51.36231, CMake `NMake Makefiles`,
  `ZYDIS_BUILD_SHARED_LIB=ON`). SHA-256
  `f81ca7d636d4679a0794da84dc32790d270b9c9bf293722844cd3ac4302ea745`.
- `ThirdParty\Zydis\LICENSE`, `PROVENANCE.md` (exact invocation, struct-layout
  measurement, the three verification answers).
- `DebuggerCore\ZydisApi.pas` — dynamic-load import unit (`ZydisDisassembleIntel`
  + `ZydisGetVersion` only). The output struct has C bitfields/unions that
  cannot be safely hand-transcribed, so its layout (1232 bytes total, length
  at offset 16, text at offset 1136/96 bytes) was MEASURED with a throwaway
  `offsetof`/`sizeof` C probe compiled against the pinned headers (probe was
  scratch-only, not kept in the repo — the measured constants live as
  commented facts in `ZydisApi.pas` and `PROVENANCE.md`).
- `DevTools\DisasmProbe.dpr` — argv-driven, no hardcoded target. Auto-detects
  machine mode from the target's own PE header (never the host), with a
  `-mode` override proven to actually change decoding (fed the same x64 bytes
  as `legacy32`: `push rbp`→`push ebp`, then desyncs at the REX prefix exactly
  as expected). Ran clean against both `DebuggerTests\TestTarget\Win64\Debug\
  TestTarget.exe` (`long64`, entry `$167FC0`) and `...\Win32\Debug\TestTarget.exe`
  (`legacy32`, entry `$F4E78`) — same DLL, both modes, correct Delphi
  prologues decoded in each.
- `.gitattributes` (`*.dll binary`) and `.gitignore`
  (`!ThirdParty/Zydis/bin/x64/*.dll`, `ThirdParty/Zydis/build/` ignored) —
  verified with `git check-ignore` / `git status` that the DLL is trackable
  and the CMake scratch dir is not.
- `DISASSEMBLY_PLAN.md` and `DevTools\README.md` updated in this change set.

Full suite (`DebuggerTests\build_and_run.bat`, run once via the test-runner
agent): **1081 found / 1077 passed / 0 failed / 0 errored / 4 ignored** —
exact match to baseline. Expected: nothing new is referenced by any existing
consumer.

### Verification answers (also in `DISASSEMBLY_PLAN.md`)

1. `ZydisDisassembleIntel` exists as assumed. `ZydisGetVersion()` on this
   pinned commit reports `4.1.0.0` (patch digit stuck at the last macro bump,
   not the tag) — version check compares major.minor only.
2. `zyantific/zydis-pascal` exists (official, MIT) but is a full header
   translation predating this pin (last commit 2023-11-20 vs. tag
   2025-02-16) and contradicts the decided minimal-surface design. Not used.
3. One DLL genuinely serves both machine modes — confirmed by CMake (no
   per-mode build knob) and empirically by the probe.

### Next action

Nothing pending on increment 1. Increment 2 (`IDisassembler` interface + Zydis
backend + symbolication, `DevTools\Disasm.exe`) is next, per
`DISASSEMBLY_PLAN.md` "Increments" and "The seam". Not started.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with this increment AND the prior data-breakpoints increment
  (6/6, also DONE) both uncommitted. Release **0.3.0 is committed but NOT
  tagged and NOT pushed**; no GitHub release exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Traps

`TRAPS.md`. The ones that bit this session:

- Batch files need CRLF, not LF — an LF-only `.bat` tokenizes as garbage word
  by word instead of erroring cleanly. `build_zydis.bat` hit this first.
- A Delphi unit's `finalization` section requires a preceding `initialization`
  section (even empty) — `finalization` alone is a parse error.
- `ZydisGetVersion()` under-reports the patch digit of a patch release (see
  above) — never gate DLL compatibility on an exact version match.
- Rebuild EVERY consumer of `DebuggerCore` before trusting a measurement.
- Never edit `DebuggerTests\TestTarget\*.pas` while the suite runs; never run
  the suite twice at once (~400 s, I/O-bound).
