# Assembly-level debugging — plan

Status: **increments 1, 2, 3 and 4 BUILT (2026-08-09); increment 5 designed, not
built.**
Wanted in the next release.

Debugging at the instruction level, in the Disassembly View and over MCP: plant a
breakpoint on an instruction, step one instruction at a time, read and write
registers, read and write memory. Everything below is the gap between that and
what shipped with `DISASSEMBLY_PLAN.md`.

## What already exists — verified, not assumed (2026-08-09, MCP columns updated 2026-08-09)

| capability | DAP | MCP |
|---|---|---|
| disassemble | yes (`disassemble`, `instructionPointerReference`) | yes (`disassemble`) |
| breakpoint at an address | yes (`setInstructionBreakpoints`) | yes |
| registers, read AND write | yes (a `Registers` scope, writable by name) | yes (`get_registers`, `set_register`) |
| read / write memory | yes (`readMemory`/`writeMemory`, `memoryReference`) | yes (`read_memory`, `write_memory`) |
| step one instruction | yes (`granularity: "instruction"` on `next`/`stepIn`/`stepOut`) | yes (`granularity: "instruction"` on `step_over`/`step_into`/`step_out`) |

Two surfaces, each missing something the other has when this table was first
measured, and instruction stepping missing from both. The engine underneath was
largely present already: it already single-steps with the trap flag, and
`TWinDebugger` already knew how to plant a one-shot breakpoint at a return
address. Increment 4 closed the last two MCP gaps by exposing that engine
surface; increment 3 closed the last DAP gap the same way.

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

## Increment 3 — DAP: memory — **BUILT**

- `readMemory` / `writeMemory` with `supportsReadMemoryRequest` /
  `supportsWriteMemoryRequest`;
- `memoryReference` on variables, so "View Binary Data" opens the memory
  inspector on the right address.

The engine primitives already existed (`IDebugTarget.ReadCodeMemoryAt`, used
by MCP's `read_memory`/`write_memory` and by `disassemble`) and are reused
as-is; this increment is DAP surface plus one new engine primitive
`writeMemory`'s `allowPartial` semantics needed
(`IDebugTarget.WriteMemoryPartial`, mechanism below). Mechanism, decisions,
and the exact base64/`unreadableBytes`/`allowPartial` wire contract:
`DAP_DEBUGGER_ARCHITECTURE.md`, "DAP memory: readMemory/writeMemory,
memoryReference — increment 3". Coverage: `TEST_CATALOG.md` section R.

**Which variables carry a `memoryReference`, decided rather than left open.**
The plan flagged this as the likely design question; the answer follows the
convention this codebase already uses everywhere else for "does this value
have a real address" (`TLocalValue.Address <> 0`, tested at a dozen call
sites before this increment):

- **Carries one**: a stack-resident local/parameter (`TDebugSession.
  LocalToSession`, from `TLocalValue.Address`); a class/record field
  (`VariableExpander.MemberFieldToSession`, `FieldAddr`); an RTTI-typed
  field rescue (`ExpandRttiTyped`, `F.FieldAddr`); a field-backed property
  (`ExpandProperties`, the field-backed branch only); a dynamic-array element
  (`ExpandDynArray`, `ElemAddr`); a Variant-array element (`ExpandVariantArray`,
  `ElemAddr`); the live `$exception` object (`BuildCurrentExceptionRef`'s new
  `ObjAddr` out param, threaded into both the Locals-scope row and the
  `evaluate` response for the literal expression `$exception`). Every one of
  these is an address the SAME code already dereferences with
  `ReadProcessMemoryAt`/`ReadCodeMemoryAt` two lines away to produce the
  displayed value — not a new computation, just exposing what was already
  known.
- **Never carries one** (default `TSessionVariable.Address = 0`, so `EmitVar`
  omits the field entirely rather than emitting a zero/placeholder address):
  a register-resident local (no provider ever sets `LV.Address` for one —
  the same sentinel the rest of the codebase already relies on); the
  `Registers` scope (a CPU register is not a byte-addressable location at
  all; `HandleVariables`' Registers branch builds its rows directly, never
  through `EmitVar`, so this is structural, not a value that happens to come
  out empty); a synthetic group row (`properties`/`event handlers`/`fields`,
  `Kind = vkGroup`, no value to back); a getter-backed property's evaluated
  result (`ExpandPropertyGetter`'s scalar `'(value)'` leaf) — the value came
  from a synthetic CALL, not a read of an existing slot, so there is no
  address that is honestly "where this value lives"; an indexed property
  leaf (no single backing slot exists to name). A getter that returns a
  STRUCTURED value (object/record) is the one subtle case: its OWN fields
  still get `memoryReference` once expanded (`ExpandPropertyGetter` hands off
  to `ExpandViaMembers` on the real object/record address the getter
  returned), because those fields are genuine memory regardless of how the
  base address was obtained — only the getter's un-expanded scalar result is
  addressless.
- Deliberately **not extended to `evaluate`/watch results** beyond the
  `$exception` special case above — DAP's `EvaluateResponse.body` has its own
  optional `memoryReference` field, and a plain evaluated expression (`p^`,
  `SomeGlobal.Field`) could honestly carry one the same way a `variables` row
  does, but wiring every branch of `HandleEvaluate` was out of scope for this
  increment and is not attempted. `$exception` was included because the
  DAP request handler already had every fact needed after the
  `BuildCurrentExceptionRef` signature change; nothing else did.

**`readMemory`.** Same primitive `disassemble` already uses
(`IDebugTarget.ReadCodeMemoryAt`): restores the debugger's own planted `INT3`
bytes within the window, and truncates at the end of the committed
`VirtualQueryEx` region instead of failing. A truncated (or entirely
unreadable) read comes back as a **partial success** — `unreadableBytes` set,
`data` covering whatever WAS read (omitted entirely when nothing was) — never
as a failed request. `data` is base64, encoded with
`TNetEncoding.Base64String` specifically (the default `TNetEncoding.Base64`
wraps at 76 characters with embedded CRLFs, wrong for a JSON string field).
`count` and `data`/`memoryReference` are required DAP fields; a request
missing one is refused rather than defaulted (a missing `count` is NOT
"read zero bytes" — it is a malformed request).

**`writeMemory` and `allowPartial`.** Writing into a live debuggee is
destructive and deliberate, but a write that only PARTLY lands must never be
reported the same way as one that fully lands. New primitive
`IDebugTarget.WriteMemoryPartial` (mirrors `WriteMemoryAt`'s
`VirtualProtectEx`/`WriteProcessMemory` mechanism exactly, as a SEPARATE
function body rather than `WriteMemoryAt` reimplemented on top of it — see
the comment at its definition for why the `Size=0`/`FProcess=0` edge case
makes that refactor wrong) reports the actual byte count
`WriteProcessMemory` transferred instead of collapsing every outcome to a
Boolean. The DAP handler's contract, decided rather than left as a TODO: this
adapter ATTEMPTS the write and reports what actually happened, rather than
pre-verifying writability across the whole range before touching anything
(the DAP spec's suggested shape for `allowPartial: false`). This means a
rejected (`allowPartial` absent/false) write CAN have already mutated
whatever bytes were writable before hitting the boundary — `WriteProcessMemory`
is not transactional — and the refusal message says exactly how many bytes
already changed rather than leaving the caller to assume zero effect. This
was a deliberate trade against building a multi-region pre-flight
writability walk (VS Code's memory editor writes one value at a time in
practice, so the multi-region case is rare) in exchange for reusing a single,
already-simple mechanism; it is documented here because it is the one place
this increment's behaviour does not literally match the spec's suggested
implementation strategy, only its observable contract (never a false
"succeeded", always an honest byte count).

## Increment 4 — MCP: registers and instruction stepping — **BUILT**

- `get_registers` / `set_register`, going through the SAME session-level path
  DAP's `Registers` scope has used for a long time
  (`TDebugSession.GetRegisters` / `SetRegister`, backed by
  `TWinDebugger`/`TWin32Debugger`'s `GetRegisters`/`SetRegisterByName`) — no
  second mechanism. `get_registers` returns the 18 rows DAP's scope emits
  (RIP, RSP, RBP, RAX..RDI, R8..R15, EFlags), each as `{name, value, size}`
  with `value` a variable-width hex string (`"0x..."`, never a bare JSON
  number — a 64-bit register does not fit an IEEE double without loss), the
  same convention `disassemble`/`read_memory`/`set_breakpoint_at_address`
  already use. On a WOW64 (32-bit) target `R8..R15` read back as literal
  `"0x0"` (`ReadThreadRegisters` in `WinDebuggerX86.pas` never sets them) —
  proven, not assumed, by `GetRegisters_Win32_MatchesRipAndZeroExtendsUpperRegisters`.
  `set_register` writes by name (case-insensitive, same names `get_registers`
  returns) and returns the register RE-READ from the thread context rather
  than echoing the request back, so the response proves the write instead of
  merely restating the ask; an unrecognised name is refused (`isError:true`),
  never silently ignored. Both require the session to be stopped, gated the
  same way every other stop-only MCP tool is (`get_call_stack`, `get_locals`,
  ...), even though the underlying `TDebugSession.GetRegisters` degrades
  quietly to an empty array instead of refusing on its own.

- Instruction-granularity stepping is a `granularity` argument on the
  EXISTING `step_over`/`step_into`/`step_out` tools (`"statement"`, the
  default, or `"instruction"`), not a fourth `step_instruction` tool. The
  three tool names already name the exact three kinds the engine's
  `TInstructionStepKind` distinguishes (`iskOver`/`iskInto`/`iskOut`), one to
  one; a `step_instruction` tool would have had to reintroduce that same
  three-way choice as a `kind` argument, duplicating a distinction the
  surface already makes by which tool is called, for no offsetting gain. This
  independently lands on the same shape DAP's increment 2 uses
  (`granularity` on `next`/`stepIn`/`stepOut`) because it is the same
  primitive underneath and the same three verbs on top — not because DAP
  happens to use that word.

  `TMcpServer.HandleStepTool` (`McpServer.pas`) is the single dispatch point
  all three tools funnel through. `"instruction"` calls
  `TDebugSession.StepInstruction` FIRST and only arms the async wait when it
  is ACCEPTED — the exact ordering increment 2's DAP `HandleInstructionStep`
  uses, and for the same reason: MCP tool calls are otherwise
  fire-and-forget (`step_over`/`step_into`/`step_out` never used to refuse),
  so a refusal has to be surfaced explicitly (`isError:true` with the reason)
  rather than either a silent no-op or a wait that never resolves. An
  unrecognised `granularity` value is refused the same way, never silently
  treated as `"statement"`. `"statement"` (default, or explicit) is the
  pre-existing fire-and-forget path, byte-for-byte unchanged.

  Mechanism, refusal-routing detail and both RED controls (Kind-mapping
  swap for `step_out`, following the same non-obvious-negative-control
  reasoning increment 2's `TASK_RESUME.md` already recorded for its own
  `HandleStepOut` test) are in `DAP_DEBUGGER_ARCHITECTURE.md`. Coverage:
  `TEST_CATALOG.md` "Q.".

## Increment 6 — WOW64 register WRITES are unverified, and may be wrong

Added 2026-08-09, surfaced while building increment 4 rather than predicted.

`SetRegisterByName` has **no WOW64 override**, while the read path has one and is
verified on both bitnesses. So writing a register on a 32-bit target may land on
the wrong logical register, and nothing reports it. This predates the assembly
work — DAP's own `setVariable` on the `Registers` scope shares the same path — so
it is not a regression, but it is now on a surface being shipped as a feature.

A write that silently hits the wrong register is precisely the class of defect
this project refuses everywhere else. Two acceptable outcomes, in order of
preference: give the write a WOW64 override mirroring the read path and prove it
on both bitnesses; or REFUSE the write on a 32-bit target with the reason, until
someone can. What is not acceptable is leaving it to be discovered by a user
whose register write appeared to succeed.

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
primitive), then 3 — all now done — then 5. Increment 5 last on purpose: it is
the only one whose content depends on everything above already working.

## Gate

Same as every other plan here: full suite green at each increment, every consumer
rebuilt, each new test proven RED without its fix, both bitnesses where behaviour
can differ. `TRAPS.md` applies in full.
