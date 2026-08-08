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

**`DISASSEMBLY_PLAN.md` increment 2 — `IDisassembler` seam + Zydis backend +
symbolication + `DevTools\Disasm.exe`. DONE, not committed; left in the tree
for review.**

Deliverables, all present:

- `DebuggerCore\Disassembler.pas` — the seam: `IDisassembler`,
  `TDisasmInstruction`, `TDisasmMachineMode`, `TDisasmByteReader`. No
  third-party reference.
- `DebuggerCore\ZydisDisassembler.pas` — `TZydisDisassembler`, the only unit
  besides `ZydisApi.pas` allowed to reference Zydis.
- `DebuggerCore\DebugTarget.pas` / `WinDebuggerBase.pas` — new
  `IDebugTarget.ReadCodeMemoryAt` (restores planted-breakpoint bytes,
  truncates at the `VirtualQueryEx` region boundary; shared unchanged by
  `TWin32Debugger`). This is an interface addition beyond what the plan's
  seam section specified — the plan named the need ("the engine already
  keeps OrigByte") but not the shape; decided in favour of the smallest
  addition reusing existing engine state, flagged in the report rather than
  silently assumed.
- `DebuggerTests\ValueReaderTests.pas` — `TFakeMemTarget` (the only other
  `IDebugTarget` implementer) got a trivial `ReadCodeMemoryAt`.
- `DebuggerTests\DisassemblerTests.pas` — 3 new tests, registered in
  `RunTests.dpr`. Both negative-controlled RED (breakpoint-restore loop
  disabled -> `Expected [204] equals actual [204]`; fail-closed guard
  disabled -> "byte reader must never be invoked..."), then reverted green.
- `DevTools\Disasm.dpr` — static file+RVA mode AND live-session mode (via
  `TDebugSession`), argv-driven, no hardcoded target. Symbolication verified
  on both bitnesses against `TestTarget.exe` with real resolved call
  targets (`_InitExe`, `RunAllScenarios`, `TWidget.Create`, ...).
- Docs updated in this change set: `DISASSEMBLY_PLAN.md` ("Verified in
  increment 2"), `DAP_DEBUGGER_ARCHITECTURE.md` ("Disassembly seam"),
  `DevTools\README.md` (`Disasm` tool entry), `TEST_CATALOG.md` ("M.
  Disassembly"), `TRAPS.md` (ZydisApi one-shot-latch trap),
  `PROJECT_STATE.md` (one-line roadmap pointer updated).

Full suite (`DebuggerTests\build_and_run.bat`, run once via the test-runner
agent): **1084 found / 1080 passed / 0 failed / 0 errored / 4 ignored** —
exact +3 delta over the 1081/1077/0/0/4 baseline, matching the 3 new tests.
Both mono and BPL fixtures compiled and ran (parametrized into the single
count).

### Real bug caught during manual verification (not by a test)

First cut of call-target symbolication matched any `[A-Za-z]+ 0x<hex>` in
Zydis's formatted text. `push 0x2A` (a plain immediate push) has that exact
shape, and got mislabelled with a fabricated call-target symbol. Caught by
eyeballing `DevTools\Disasm.exe` output, not by a unit test. Fixed with a
CLOSED whitelist of the actual Zydis control-transfer mnemonics
(`call`/`jmp`/every `Jcc`/`loop` family) in `ZydisDisassembler.pas`. No
automated regression test guards this specific case — noted as a gap in
`TEST_CATALOG.md` "M. Disassembly".

### What is NOT covered by an automated test (documented gaps)

- Trap 2 (truncate at a page/section boundary) — no fixture; exercised
  manually only.
- The positive Zydis decode path (real DLL, correct output) — deliberately
  excluded from `RunTests.exe` because `ZydisApi.ZydisTryLoad` is a
  one-shot process-wide latch (see `TRAPS.md`); proven via
  `DevTools\Disasm.exe` instead.
- Call-target symbolication / mnemonic-whitelist correctness — no
  regression test.

### Next action

Increment 3 (`DISASSEMBLY_PLAN.md` "Increments"): differential coverage tool
vs. an independent oracle (XED and/or `dumpbin /DISASM`), over fixtures and
real binaries — record measured divergence counts in the plan. "Open, to
verify before writing code" in the plan already flags the XED-vs-iced
oracle choice as unresolved. Not started.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with THIS increment, the prior disassembly increment 1, and
  the prior data-breakpoints increment (6/6) all uncommitted. Release
  **0.3.0 is committed but NOT tagged and NOT pushed**; no GitHub release
  exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Traps

`TRAPS.md`. The one that bit this session:

- `ZydisApi.ZydisTryLoad` is a one-shot process-wide latch — a negative-DLL
  test and a positive-decode test can never safely share a process. Full
  detail now in `TRAPS.md`.
- Rebuild EVERY consumer (`build_runner.bat`, `build_dap.bat`,
  `build_mcp.bat`, `DevTools\build_all.bat`) before trusting a measurement —
  all four were rebuilt clean in this session after the `IDebugTarget`
  interface change.
