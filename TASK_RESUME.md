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

**`DISASSEMBLY_PLAN.md` increment 3 — measured coverage. DONE, not committed;
left in the tree for review.** Full detail (exact numbers, methodology,
classification of every divergence) lives in `DISASSEMBLY_PLAN.md` "Verified
in increment 3 — Half A / Half B" — this cursor is a pointer, not a repeat.

Two halves, both landed:

- **Half A** — `ZydisApi.ZydisResetForTests` (test-only) makes the one-shot
  DLL-load latch resettable, so `DebuggerTests\DisassemblerTests.pas` gained
  `TZydisPositiveDecodeTests` (2 tests, real decode, both machine modes) and
  `TCallTargetWhitelistTests` (1 test, regression guard for the increment-2
  `push 0x2A` mislabelling bug) — all Zydis-touching fixtures now share
  `RunTests.exe` safely regardless of execution order. Both negative
  controls run and reverted (see the plan doc for exact failure text).
- **Half B** — `DevTools\DisasmCoverage.exe` (+ `run_disasm_coverage.bat`):
  differential sweep of Zydis vs dumpbin over real binaries. 13 173 394
  instruction positions compared across `TestTarget.exe`/`TestSubject.bpl`
  (both bitnesses, full sweep), `rtl290.bpl`/`vcl290.bpl` (full sweep,
  export-anchored), and `Hydra2SingleEXE.exe` (505/582 MB, both bitnesses,
  disclosed 33% sample) — **zero mnemonic-identity divergences** after
  normalisation converged. Every non-mnemonic divergence manually classified
  (data-in-code-stream, or Zydis correctly naming an undocumented opcode
  dumpbin doesn't know). One genuine tooling artifact found and documented:
  dumpbin itself silently drops output beyond an internal capacity threshold
  on a single UNSAMPLED full sweep of the largest binary (478 083 spurious
  "boundary" divergences that vanish at 33% sample) — not a Zydis defect.

Full suite (`build_and_run.bat`, run once via the test-runner agent):
**1087 found / 1083 passed / 0 failed / 0 errored / 4 ignored** — exact +3
delta over the 1084/1080/0/0/4 baseline, matching the 3 new tests.

### Files changed this session

- `DebuggerCore\ZydisApi.pas` — `ZydisResetForTests` added (test-only).
- `DebuggerCore\ZydisDisassembler.pas` — touched during a negative control,
  reverted to byte-identical (`git status` shows no diff for this file).
- `DebuggerTests\DisassemblerTests.pas` — 3 new tests + shared helpers
  (`RepoRoot`, `RealZydisDllPath`, `MakeFixedBytesReader`,
  `TAlwaysSymbolProvider`), registered in the `initialization` section.
- `DevTools\DisasmCoverage.dpr` (new) + `DevTools\run_disasm_coverage.bat`
  (new) — the differential sweep tool and its VS-toolset-initialising
  wrapper.
- Docs in this change set: `DISASSEMBLY_PLAN.md` (increment 3 status +
  both "Verified in increment 3" sections + resolved the XED-vs-dumpbin
  open question), `DevTools\README.md` (`DisasmCoverage` entry + measured
  baseline table), `TEST_CATALOG.md` ("M. Disassembly" + "what the suite
  does NOT prove" — the export-anchored methodology's weaker end-boundary
  guarantee and the dumpbin scale artifact), `TRAPS.md` (Zydis latch trap
  updated to mention the test-only reset; two new trap entries: oracle
  scale limits, and pipe-vs-file subprocess capture at scale),
  `PROJECT_STATE.md` (one-line roadmap pointer updated).

### Not done, not blocking

- Increment 3's own two disclosed weaknesses, already stated in the plan
  doc rather than hidden: the export-anchored methodology (RTL/VCL, no
  debug info) has an unverified span END, so its `length`-divergence count
  is dominated by spans running into data, not decoder disagreement; and
  the `Hydra2SingleEXE.exe` rows are a 33% sample, not a full sweep (the
  full sweep DOES complete now after the `RunToFile`/streaming fix, in
  ~5.7 minutes for the x86 binary, but hits the dumpbin scale artifact
  described above, so the sample is the trustworthy number).

### Next action

Increment 4 (`DISASSEMBLY_PLAN.md` "Increments"): MCP `disassemble`. Not
started.

## Standing constraint from the user

**No heuristics.** A fix must be deterministic. A solution that patches the
observed case and misleads elsewhere is worse than leaving the defect open and
documented.

## State of the tree

- `public-main`, with THIS increment, the prior disassembly increments 1-2,
  and the prior data-breakpoints increment (6/6) all uncommitted. Release
  **0.3.0 is committed but NOT tagged and NOT pushed**; no GitHub release
  exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Traps

`TRAPS.md` has full detail. The ones that bit this session:

- `ZydisApi.ZydisTryLoad`'s one-shot latch is now resettable in tests via
  `ZydisResetForTests` — production code must never call it.
- A second-decoder oracle (dumpbin here) can have its OWN scale limit;
  measure at a smaller sample before trusting a large divergence count.
- Capturing a large subprocess's stdout through an in-process pipe has a
  ceiling (`EEncodingError` on an overflowed string) — redirect to a file
  and stream it back instead.
- Rebuild EVERY consumer (`build_runner.bat`, `DevTools\build_all.bat`)
  before trusting a measurement — both rebuilt clean this session after the
  `ZydisApi.pas` change.
