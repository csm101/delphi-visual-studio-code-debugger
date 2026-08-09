# Assembly-level debugging — plan

Status: **all six increments BUILT (2026-08-09). Plan complete.**
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

## Increment 6 — WOW64 register writes — **BUILT** (2026-08-09)

Added 2026-08-09, surfaced while building increment 4 rather than predicted.
`SetRegisterByName` had **no WOW64 override**, unlike every other member of the
thread-context funnel — it always used the native `GetThreadContext`/
`SetThreadContext` pair. This predates the assembly work — DAP's own
`setVariable` on the `Registers` scope shares the same path — so it was not a
regression, but it was on a surface being shipped as a feature, unverified
either way.

### What was actually measured, before deciding anything

New probe `DevTools\Wow64RegWriteProbe.dpr`, modeled on `Wow64StackProbe.dpr`.
It reproduces `SetRegisterByName`'s exact mechanism (read native `TContext`,
mutate one field, write it back with native `SetThreadContext`) and then asks
`Wow64GetThreadContext` whether the guest-visible register actually changed —
first at the WOW64 loader breakpoint (the first stop a debugger sees, with no
`-rva`), then, after that result turned out to be misleading, at a REAL
application breakpoint (`-rva`, an `INT3` planted in running 32-bit code, the
same mechanism every real breakpoint in this debugger uses).

**First measurement — at the WOW64 loader breakpoint** — reproduced the
suspected defect exactly: `SetThreadContext` reports success and a
subsequent NATIVE `GetThreadContext` even reads back the sentinel, but
`Wow64GetThreadContext` never changes, and a single step afterward resyncs the
native side back to the true value (the sentinel is gone even there). A write
that appears to succeed and touches nothing.

**This result did not hold at a real breakpoint, and that gap mattered.**
`TestTargetCore.TWidget.StepIntoProbe`'s entry (RVA `$E97C4` in the 32-bit
`TestTarget.exe`) is a genuine, representative stop: an `INT3` planted in
already-running application code, exactly how this debugger's own breakpoints
work. There, `CompareAllFields` (dumping `Rip`/`Rsp`/`Rbp` and every
general-purpose register both ways, unmodified) showed the native and WOW64
views ALIASING EXACTLY, for every field, on this measured Windows build
(Windows 11, build 26200) — and a native write of `Rbp` (the field
specifically flagged as suspect) landed correctly through to
`Wow64GetThreadContext`, stable across a subsequent single step. **The
originally-suspected "silent wrong-register write" is not reproducible at any
state this debugger actually reports to a user as stopped** — `stopAtEntry`
plants its OWN breakpoint at the real entry point (`WinDebuggerBase.pas`,
`HandleCreateProcess`), never relying on the raw WOW64 loader break, so a user
never sees the anomalous transitional state where the defect is real.

**R8..R15 remained a genuine, reachable defect independent of that finding.**
They do not exist on x86 at any width; the unfixed base class's name matching
accepted `"R8"`..`"R15"` and reported success while writing a native-context
field that means nothing on a WOW64 target — never reproduced-as-fine, unlike
the general-purpose case above.

### Outcome taken, and why

**Outcome 1** (WOW64 override, mirroring the read path) — taken anyway,
despite the round-trip defect not reproducing at a real stop, because:

- the write path was UNVERIFIED either way; replacing it with the
  documented-correct `Wow64Get/SetThreadContext` API removes reliance on OS
  aliasing behaviour that is an implementation detail, not a guaranteed
  contract, and might not hold on a different Windows version;
- it makes `SetRegisterByName` consistent with every other member of the
  thread-context funnel, which already all have WOW64 overrides;
- it is REQUIRED to fix the R8..R15 defect, which is real regardless of the
  aliasing question.

`TWin32Debugger.SetRegisterByName` (`WinDebuggerX86.pas`) now uses
`Wow64Get/SetThreadContext` with the same name vocabulary
`ReadThreadRegisters`/`GetRegisters` already use (`RIP`/`RSP`/`RBP`/
`RAX`..`RDI`/`EFlags`, case-insensitive), and refuses `R8`..`R15` outright —
no heuristics, no silent no-op: there is no logical register for the value to
go to.

### Tests, and what they actually prove

Given the round-trip defect does not reproduce at a real stop, the
round-trip tests (`Win32_SetRegister_WritesAndReadsBack` at three layers) are
REGRESSION GUARDS, not RED controls — they pass with or without the fix on
this measured Windows build. The R8..R15 refusal tests
(`*_ExtendedRegister_Refused`, also at three layers) ARE the RED controls:
confirmed failing without the fix (temporarily falling back to
`inherited SetRegisterByName` in `TWin32Debugger.SetRegisterByName`), passing
with it. Full detail, including which layer proves what and the exact RED
failure text: `TEST_CATALOG.md` section S.

DAP `setVariable` on the `Registers` scope and MCP `set_register` were
confirmed to share the identical defect and the identical fix — both funnel
through `TDebugSession.SetRegister` -> `IDebugTarget.SetRegisterByName`, and
both are directly tested (`RegisterWriteDapTests.pas`, `McpE2ETests.pas`).
They do not diverge.

### Mechanism

`DAP_DEBUGGER_ARCHITECTURE.md`, "Registers and instruction stepping (MCP) —
increment 4" carried the "not measured" caveat this increment resolves; see
that section (now updated) for the funnel's shape.

### Follow-up, measured 2026-08-09: leaving the frame with no source at all

The obvious challenge to increment 5 is "why serve a fabricated page instead of
letting the editor open its real Disassembly View?" The adapter cannot open that
view — DAP has no request for it — so the only thing it can do is stop attaching
a `source` and leave the client to its own devices. `noSourcePlaceholder: false`
in `launch.json` does exactly that, and a paired launch configuration exists for
the comparison.

**Measured result: with no source attached, double-clicking a sourceless frame in
VS Code does NOTHING.** No fallback view, no message. So the placeholder never
displaced a better client behaviour; it replaced silence. Keep the flag — it is
the instrument that produced this answer and the one that will re-produce it on
another editor, where it may come out differently.

## Increment 5 — the placeholder document becomes useful — **BUILT** (2026-08-09)

MEASURED 2026-08-09, in VS Code, and it settled the question `KNOWN_UNKNOWNS.md`
was holding open (entry removed — the answer lives here and in
`DAP_DEBUGGER_ARCHITECTURE.md`, "The document's content — increment 5"):
**selecting a sourceless frame shows the adapter's placeholder document, not the
Disassembly View.** The client opens what the adapter hands it, so the
placeholder does not merely compete with disassembly — it precludes it.

`TDapServer.SyntheticSourceText` now appends a real disassembly section below
the unchanged explanatory header: up to 8 PROVEN backward instructions
(`NearestInstructionBoundaryBefore`, falling back to `NearestExportedEntryBefore`,
via `DisassembleBackward` — proven-boundary-only, never a guessed span) plus 16
forward instructions starting exactly at the frame's PC (`BuildPlaceholderDisassembly`,
`FormatPlaceholderInstruction`), reusing the EXACT mechanism `disassemble`
(increment 6) uses: the same `TZydisDisassembler` construction, the same
`IDebugTarget.ReadCodeMemoryAt` reader (restores this debugger's own planted
`INT3` bytes — never a raw read), the same symbol/line lookups. Each line
carries the nearest symbol + offset or an explicit `(no symbol)`, and — when the
line table has one for THAT instruction's own address, independently of whether
the frame's own PC has one — the source file and line: the resolved path when
found, or the bare name plus "(not found in the source path)" when not. The
current instruction gets both a `=>` marker and a `<-- current instruction`
suffix.

**Zydis is optional**: when `IDisassembler.Available` is False the section is one
line naming the real reason (`Disasm.StatusText`); when nothing at the PC was
readable at all, it says so instead of an empty list. Never blank, never a
guessed listing, never a claim of failure for a reason that was not the real
one.

**The Disassembly View reference is deliberately hedged**, per the plan's own
constraint: "An editor's own Disassembly View, **where it offers one**, can show
more of this routine than this snippet, with gutter breakpoints and scrolling" —
true whether or not a "jump to disassembly" command exists in the Call Stack
context menu, which was never confirmed and is not claimed.

**The two "why is there no source" cases stay apart**, as the plan required, but
at a finer grain than expected: at the FRAME level, the placeholder is ALWAYS
the "no line information at all for this exact address" case — `TSessionFrame.
SourceFile` empty is precisely what triggers the placeholder
(`TDapServer.HandleStackTrace`; confirmed by reading `TDebugSession.
FrameToSession` and `TWinDebugger.SymbolicateAddress`), so a frame whose file is
merely unresolvable-on-disk never reaches this code path at all — it takes the
direct `source: {name, ...}` branch instead. The "line known, file missing" case
therefore shows up only PER INSTRUCTION, inside the disassembly window, for an
address near (but not at) the frame's own PC that the line table does cover.

### A plan assumption that did not hold: `NoSourceStop.dpr` via an exception stop

The plan pointed at `DebuggerTests\TestTarget\NoSourceStop.dpr` (`-rtl` faults
inside `System.Move`, `-os` faults inside ntdll's `RtlMoveMemory`) to exercise
both cases. Measured, independently, twice (a DAP session and
`DevTools\LiveSessionProbe` driving the engine directly): an exception stop on
either scenario does **not** reach a sourceless frame at all — frame 0 resolves
to the CALLING Delphi frame (real source, real line), not the true fault
address, even though the exception EVENT's own `ExceptionAddress` is correct.
Full writeup: `KNOWN_UNKNOWNS.md`, "An exception stop's frame 0 does not
reliably resolve to the true faulting address in code with no debug info";
`TRAPS.md` carries the operational warning. This is a pre-existing property of
`TWinDebugger.GetStackFrames` for exception stops, unrelated to this increment
and not fixed here — the root cause was not found within the time spent
investigating it, and deciding whether/how to fix it is a separate task.

Because of this, the increment's tests use the ALREADY-PROVEN sourceless-frame
path instead (`Test_SourcelessFrame_HasPlaceholderDocument`'s parked-worker-thread
fixture — `Sleep(INFINITE)` bottoms out in ntdll/kernel32, `saNoSymbols`), new
file `DebuggerTests\PlaceholderDisassemblyTests.pas`. That proves the
`saNoSymbols` case (real decoded syscall stub, current instruction marked,
every line honestly `(no symbol)`) end-to-end; the `saLoaded` case ("debug info
loaded, this address not covered") runs through the identical
`BuildPlaceholderDisassembly` code path — only the header's `Reason`/`Advice`
text differs, unchanged pre-increment-5 code — but was not exercised by an
automated fixture in this increment, for the reason above.

### Coverage

`TEST_CATALOG.md`, section T.

## Order

1, then 2 and 4 in either order (they are the two surfaces over the same
primitive), then 3, then 6, then 5 last — it was the only one whose content
depended on everything above already working. All six now built.

## Gate

Same as every other plan here: full suite green at each increment, every consumer
rebuilt, each new test proven RED without its fix, both bitnesses where behaviour
can differ. `TRAPS.md` applies in full.

## Closing status (2026-08-09)

All six increments built, tested and documented. The plan is complete:
instruction-level stepping (into/over/out, with the `rep`/recursion/re-plant
hazards it required), DAP stepping granularity, DAP memory read/write, MCP
registers and instruction stepping, the WOW64 register-write fix increment 4's
work surfaced, and the placeholder document that makes a sourceless stop
inspectable instead of merely acknowledged. What is left is not part of this
plan: the exception-stop frame-0 finding above (`KNOWN_UNKNOWNS.md`), and the
other open DAP-adapter items already tracked independently in
`KNOWN_UNKNOWNS.md`'s "DAP adapter / debugger" section (`setExpression`,
`modules`/`loadedSources` on DAP, hover-safety, and the rest).
