# Assembly-level debugging — plan

Status: **increments 1-2 BUILT (2026-08-09); increments 3-5 designed, not built.**
Wanted in the next release.

Debugging at the instruction level, in the Disassembly View and over MCP: plant a
breakpoint on an instruction, step one instruction at a time, read and write
registers, read and write memory. Everything below is the gap between that and
what shipped with `DISASSEMBLY_PLAN.md`.

## What already exists — verified, not assumed (2026-08-09)

| capability | DAP | MCP |
|---|---|---|
| disassemble | yes (`disassemble`, `instructionPointerReference`) | yes (`disassemble`) |
| breakpoint at an address | yes (`setInstructionBreakpoints`) | yes |
| registers, read AND write | yes (a `Registers` scope, writable by name) | **no** |
| read / write memory | **no** | yes (`read_memory`, `write_memory`) |
| **step one instruction** | **no** | **no** |

Two surfaces, each missing something the other has, and instruction stepping
missing from both. The engine underneath is largely present: it already
single-steps with the trap flag, and `TWinDebugger` already knows how to plant a
one-shot breakpoint at a return address.

## Increment 1 — the engine primitive — **BUILT**

A real single-instruction step, exposed rather than buried inside the line-step
logic. Today stepping means "advance until the source line changes", which has no
natural terminating condition in code that has no line table — which is exactly
the code someone steps through instruction by instruction.

The rules, and they are the substance of this plan:

- **step-into = one trap-flag step.** Land wherever the instruction goes,
  including into a callee. Nothing else to decide.
- **step-over must not single-step through a `call`.** Decode the instruction at
  the PC; if it is a call, plant a one-shot breakpoint at PC + length and run.
  The length is exact — the disassembler just produced it — which makes this
  *more* reliable than the source-level equivalent, not less. Everything that is
  not a call is a single trap-flag step.
- **step-over must survive a callee that re-enters.** The one-shot is thread-
  scoped and must also compare the stack pointer, or a recursive callee hitting
  the same address at a deeper level ends the step early. The existing
  source-level step-over already faces this; reuse its answer rather than
  inventing a second one.
- **step-out at instruction granularity is the same problem already solved
  twice**: the return address comes from `.pdata` on x64 and from `[EBP+4]` on
  x86. Where neither is available — x64 code with no unwind data — it must
  REFUSE rather than run to somewhere plausible.

### Traps this touches, all of them already paid for once

- **`rep`-prefixed instructions trap PER ITERATION.** A single trap-flag step
  over `rep movsb` stops thousands of times, which reads as a hang. A
  rep-prefixed instruction must be stepped like a call — one-shot at PC + length
  — or the user watches a progress bar made of stops. This is the one genuinely
  new hazard here.
- **A watchpoint hit arrives as a single-step exception too.** `DR6`
  disambiguation already exists (`DATA_BREAKPOINTS_PLAN.md`, increment 2) and the
  new stepping MUST go through it. A watchpoint that fires during an instruction
  step must not be reported as the step completing.
- **On WOW64 a single step reports `STATUS_WX86_SINGLE_STEP` (`$4000001E`)**, not
  `EXCEPTION_SINGLE_STEP`. Measured during the Win32 port.
- **Stepping over an address that carries a planted `INT3`** must restore the
  original byte, step, and re-plant — the engine already does this for source
  stepping; the instruction path must not bypass it.
- **On x86, the stack walk does not survive a still-planted breakpoint.** Also
  measured during the Win32 port: restore the byte and rewind EIP before any walk
  taken during an instruction step.

### What increment 1 actually built, and the three rules it had to sharpen

The surface is `IDebugTarget.StepInstruction(Kind, ThreadId, out RefusalReason)`
(`TInstructionStepKind = (iskInto, iskOver, iskOut)`) with a `TDebugSession`
facade of the same shape. The mechanism is in
`DAP_DEBUGGER_ARCHITECTURE.md`, "Instruction granularity"; only the decisions the
plan left open are recorded here.

**1. `rep` is completed as a whole by step-INTO as well as step-over.** The plan
listed the rep hazard under step-over. Measured (negative control, both
bitnesses): a trap-flag step at `rep movsb` leaves the PC *exactly where it was*
— `$46B34C` before and after — having retired one iteration. So "step one
instruction" would appear not to advance at all, and any caller looping until the
PC moves takes 65536 stops, which is the hang the rule exists to prevent. A
string move has no callee, so entering it is not a thing a user can want:
both kinds run to a one-shot at PC + length. The count register proves it —
`REP_BLOCK_SIZE` before the step, zero after.

**2. Refusing when the disassembler backend is unavailable covers ALL THREE
kinds**, including `iskOut`, which decodes nothing itself. A surface where two of
three kinds refuse and the third silently works is a worse contract than one
sentence naming what is missing. `IDisassembler.StatusText` is quoted in the
refusal.

**3. A rejected transient step breakpoint has to be STEPPED OFF, not re-planted
in place.** Found while building this, and it was a latent hang in the
*source-level* step-over too (fixed in the same change): when the recursion guard
rejects a hit, the thread is parked ON that address with the original byte
already restored, so writing the INT3 straight back re-traps on the same
instruction the instant the thread resumes. Measured as an unbounded
trap/re-plant loop in the debug log before the fix. `RearmStepBpAfterForeignHit`
now does the same dance a persistent breakpoint hit does — leave it unplanted,
single-step off it, re-plant on that trap — and `FSteppingOffStepBp` marks that
trap as deciding nothing, so neither step mode mistakes it for progress.

The classification (`call`, `rep`-family) is read from the DECODER'S OWN
mnemonic text, the same discipline `ZydisDisassembler`'s direct-branch whitelist
already uses; nothing re-derives from raw bytes what the decoder was asked to
produce. An instruction that does not decode is refused, never given a guessed
length.

## Increment 2 — DAP: stepping granularity — **BUILT**

- capability `supportsSteppingGranularity`;
- `granularity: "instruction"` honoured on `next`, `stepIn` and `stepOut`. VS Code
  sends it when the Disassembly View has focus, and before this increment the
  adapter ignored the field, so a step in that view behaved like a source step —
  the least predictable thing it could do in code with no line table.

Mechanism: `DAP_DEBUGGER_ARCHITECTURE.md`, "Instruction granularity (DAP) —
increment 2". Coverage: `TEST_CATALOG.md` "P.".

Thin plumbing on purpose, and it stayed thin: `TDapServer.
WantsInstructionGranularity` reads the field, `HandleInstructionStep` maps
`next`/`stepIn`/`stepOut` to `iskOver`/`iskInto`/`iskOut` and calls
`TDebugSession.StepInstruction` — increment 1's facade, unmodified. No new
engine code. Two decisions worth recording because a plausible-looking
alternative was available and wrong:

1. **The decision has to happen BEFORE the response is sent, not after.** The
   pre-existing `next`/`stepIn`/`stepOut` handlers send `success: true`
   unconditionally, then fire the (always-accepted) source-level step as a
   side effect. Instruction-granularity stepping can genuinely be refused, so
   copying that shape would have meant either a refusal arriving as a silent
   no-op (the client sees `success: true` and then nothing happens) or —
   worse — a silent fallback to a source-level step, exactly the "quiet
   substitution" the standing no-heuristics rule exists to prevent.
   `HandleInstructionStep` calls `StepInstruction` FIRST and only then
   answers, so a refusal is a real DAP error response (`success: false`,
   `message: RefusalReason`).
2. **Reachable refusals from a real DAP client are a strict subset of
   increment 1's refusal set.** `StepThreadFromArgs` (pre-existing, built for
   the source-level steppers) folds any `threadId` that does not match a live
   thread back to 0 — "the stopped thread" — the same defensive fallback
   `stackTrace` uses. That means a bogus DAP thread id can never reach the
   engine's "thread is not live" refusal; it silently retargets instead, by a
   design decision made before this increment, not a gap in it. Similarly,
   there is no launch-config knob to force the Zydis backend unavailable from
   outside the process — that seam (`SetInstructionDisassembler`) is
   in-process only, used by `InstructionStepTests.pas`. The one refusal a real
   client can trigger is "not running" (before `launch`), which is what the
   new negative control proves.

## Increment 3 — DAP: memory

- `readMemory` / `writeMemory` with `supportsReadMemoryRequest` /
  `supportsWriteMemoryRequest`;
- `memoryReference` on variables, so "View Binary Data" opens the memory
  inspector on the right address.

The engine work exists — MCP's `read_memory` / `write_memory` are built and
tested. This is surface.

## Increment 4 — MCP: registers and instruction stepping

- `get_registers` / `set_register`. DAP has had a writable `Registers` scope for a
  long time; the MCP surface never gained an equivalent, which means an agent
  driving this debugger cannot see a register today.
- instruction-granularity stepping, either as `step_instruction` or as a
  granularity argument on the existing step tools. Match whatever shape reads
  better against the existing surface rather than importing DAP's vocabulary.

## Increment 5 — the placeholder document becomes useful

MEASURED 2026-08-09, in VS Code, and it settles the question `KNOWN_UNKNOWNS.md`
was holding open: **selecting a sourceless frame shows the adapter's placeholder
document, not the Disassembly View.** The client opens what the adapter hands it,
so the placeholder does not merely compete with disassembly — it precludes it.

The placeholder is a virtual document served by the adapter, so its content is
entirely ours to choose. Rather than deleting it and depending on client
behaviour, fill it with what the reader actually wants:

- a header naming the address, module and function, and why there is no source;
- the disassembly around the frame's PC, annotated with symbol + offset, with the
  current instruction marked;
- a pointer to the real Disassembly View for interaction (gutter breakpoints,
  scrolling) — **conditional on that view actually being reachable from the Call
  Stack context menu, which must be confirmed before the sentence is written.**

Keep separate, because they call for different answers:
- **no line information at all** — disassembly is the only truth available;
- **a line is known but the file is not on disk** — the actionable answer is the
  file name and line, and how to fix the search path. Assembly there hides a
  configuration problem behind what looks like a debugger limitation. Note that
  the DAP disassembly output already carries `location.name` and `line` even when
  the path cannot be resolved, so the two can be shown together.

## Order

1, then 2 and 4 in either order (they are the two surfaces over the same
primitive), then 3, then 5. Increment 5 last on purpose: it is the only one whose
content depends on everything above already working.

## Gate

Same as every other plan here: full suite green at each increment, every consumer
rebuilt, each new test proven RED without its fix, both bitnesses where behaviour
can differ. `TRAPS.md` applies in full.
