# Data breakpoints (watchpoints) — plan

Status: **designed, not built** (2026-08-08). Nothing exists today: no `DR0`/`DR7`
handling in the engine, no `supportsDataBreakpoints` / `dataBreakpointInfo` /
`setDataBreakpoints` in the DAP layer, no MCP tool, and no prior mention in any
document or commit message. Every breakpoint the debugger plants is a software
`INT3` on code.

"Stop when THIS address is written" is one of the few questions only a debugger
can answer. Ranked against the other two address-oriented features
(`DISASSEMBLY_PLAN.md`), disassembly and address breakpoints are convenience;
this one is diagnostic power that is simply absent.

## Mechanism: hardware debug registers

x86/x64 provides four hardware slots, `DR0..DR3`, controlled by `DR7`:

- per slot: enable bits (local/global), an access type, and a length;
- access type: `00` execute, `01` write, `11` read-or-write, `10` I/O;
- length: 1, 2, 4 or 8 bytes (8 only in 64-bit mode);
- **the address must be aligned to the length.**

Two consequences that must reach the user rather than be smoothed over:

- **There is no read-only watchpoint on x86.** DAP's `read` access type has no
  hardware equivalent; it maps to read-or-write. The tool must SAY the breakpoint
  will also fire on writes instead of silently pretending it filtered.
- **Four slots, process-wide.** Exhaustion is refused explicitly with a message
  naming what already holds the slots. Never silently drop the fifth.

Bonus already visible in the design: access type `00` is a hardware EXECUTE
breakpoint, which can plant a code breakpoint in read-only or self-checking
memory where writing an `INT3` is not an option. Same slots, so the same
allocator. Out of scope for v1, worth not designing away.

## The hard part: debug registers are per-thread

`DR0..DR7` live in the THREAD context, not the process. A watchpoint that is
armed on the thread that reads the variable and not on the one that writes it is
worse than no watchpoint, because it reports success.

So a "process-wide" data breakpoint is a bookkeeping entry that must be
REPLICATED onto every thread:

- every thread live at set time (the engine already enumerates threads);
- every thread created afterwards — `HandleCreateThread`
  (`WinDebuggerBase.pas:2338`) becomes an arming site;
- every thread already running at ATTACH, which is the same enumeration but a
  different entry path;
- and they must be CLEARED on detach (`WinDebuggerBase` detach path). A detached
  target left with `DR7` armed keeps trapping into nothing.

## Interaction with the existing single-step machinery — the real trap

A data breakpoint hit is delivered as a SINGLE-STEP exception, i.e. exactly the
event the stepping engine already consumes at `WinDebuggerBase.pas:2823`
(`EXCEPTION_SINGLE_STEP, STATUS_WX86_SINGLE_STEP` — the WOW64 code `$4000001E`
that Phase 0 of the Win32 work measured).

Telling the two apart is not optional and cannot be done from the exception code:
**read `DR6`.** Bits `B0..B3` name the slot that fired; a step completion has none
of them set. `DR6` must then be CLEARED, or the next event carries stale bits and
every step afterwards looks like a watchpoint hit.

This is a change to the event pump's most delicate path — the one that took three
measurement rounds to get right for Win32 — so it lands with its own tests before
anything user-facing is wired.

Second interaction: a synthetic call runs real code in the debuggee. A watchpoint
can fire inside it. The existing abort-on-raise machinery
(`FLastSyntheticCallError`, see the memory note on `RunMethodCall`) is the model:
decide deliberately whether a watchpoint hit during a synthetic call aborts the
call or is suppressed, and say which. Silently swallowing it would make an
evaluation that trips the user's own watchpoint behave differently from the same
code running normally.

## WOW64

The 32-bit path reads and writes debug registers through
`Wow64Get/SetThreadContext` with `WOW64_CONTEXT_DEBUG_REGISTERS`
(`WinDebuggerX86.pas` already owns every `Wow64GetThreadContext` call site).

MEASURED (`DevTools\DataBpProbe.dpr`, both `TestTarget.exe` builds): WOW64 debug
registers set via `Wow64Get/SetThreadContext` with `WOW64_CONTEXT_DEBUG_REGISTERS`
work exactly like the native x64 path. Arming at `CREATE_PROCESS_DEBUG_EVENT`
does NOT work on EITHER bitness — the initial thread hasn't run user code yet
and the watchpoint never fires. Arm instead after the loader's own initial
system breakpoint (`EXCEPTION_BREAKPOINT` $80000003 for native,
`STATUS_WX86_BREAKPOINT` $4000001F for WOW64 — the WOW64 target raises the
native one first, then its own; arm on the bitness-matching one). Once armed
there:

- the trap arrives every time, reported as `STATUS_WX86_SINGLE_STEP`
  ($4000001E) on WOW64 vs `EXCEPTION_SINGLE_STEP` ($80000004) natively;
- `DR6` correctly names the slot (`B0`) on both, read via `Wow64GetThreadContext`
  for the WOW64 target;
- the watched write was already visible in `ReadProcessMemory` at the trap on
  both (traps after the store completes, as documented above);
- `DR7` survived three consecutive hits, each separated by real target
  execution (multiple nested CALL/RET reusing the same stack slot) — i.e. it
  survives ordinary OS scheduling/context switches on WOW64 exactly as on x64.
  Native x64 readback showed one extra bit (bit 10, architecturally
  reserved-as-1) that WOW64 readback did not — cosmetic, not a persistence
  difference.

Conclusion: the WOW64 path is NOT the risk this section anticipated. The real
trap for both bitnesses is arming too early (at `CREATE_PROCESS_DEBUG_EVENT`);
the production implementation must arm after the process's own initial
breakpoint, not at process creation.

## Where it plugs into the existing architecture

- **Thread-context funnel** (`WinDebuggerBase.pas:1103`, `ReadThreadRegisters` and
  friends): debug registers are a fourth ROLE alongside PC / SP / trap flag, and
  belong behind the same funnel for exactly the reason the comment there gives —
  a caller wanting "arm slot 2 for write on this address" must not know that a
  32-bit target needs a different API and different field names.
- **Command queue** (`DebugTarget.pas:185`, `TCommandKind`): arming touches thread
  contexts, so it must run on the debug thread like `ckSetBreakpoints`. New kind
  `ckSetDataBreakpoints` with its own spec record.
- **Session** (`DebugSession.pas:220`): `SetDataBreakpoints` / `ListDataBreakpoints`
  / removal, mirroring the source-breakpoint API, plus the stop reason.
- **Stop reporting**: a new `TStopReason` value. A watchpoint stop is not a
  breakpoint stop and must not be reported as one.

## Scoping an address: what the user actually names

Three inputs, decreasing order of safety:

1. **A literal address** (from `disassemble`, a frame, or a previous evaluation).
   Unambiguous. Stored as module+RVA where it falls inside a known module, for the
   same reason address breakpoints are (`DISASSEMBLY_PLAN.md`): a bare VA does not
   survive a relaunch or a rebased package.
2. **A global / unit variable.** Resolved through the existing global resolution,
   then treated as case 1. This is the high-value case: "who writes `GCounter`".
3. **A local or a field of a live object.** The address exists only while the
   frame or the object does. DAP models this with `dataBreakpointInfo` returning a
   `dataId` derived from a variable reference; the debugger must invalidate the
   watchpoint when the frame is gone rather than keep watching reused stack.
   Detection is only possible at a stop (compare the recorded frame base against
   the current stack), so the honest behaviour is: mark it STALE at the first stop
   where the frame is gone, remove it, and TELL the user. Not silently.

Size comes from the type when the symbol is known, and must be one of 1/2/4/8 with
a correctly aligned address. Anything else is refused with the reason, not rounded
into a watchpoint on a neighbouring byte.

## Reporting a hit

A write watchpoint traps AFTER the store completes, so "the new value" is readable
at the stop, and "the old value" is only available if it was captured when the
watchpoint was armed and refreshed at every hit. Do that: `old -> new` is the
whole point of the feature, and DAP has a `description` field for it.

The stop must also name the thread that did it. That is frequently the ANSWER.

## Surfaces

**MCP** (the surface an agent drives):

- `set_data_breakpoint(address | expression, size, access)` — `access` one of
  `write` / `readWrite`, with `read` refused and explained;
- `list_data_breakpoints`, `remove_data_breakpoint`;
- the stop payload names the watched address, the firing thread, and old/new.

**DAP** (VS Code's own channel — "Break on Value Change" in the Variables context
menu appears once the capabilities are declared):

- `supportsDataBreakpoints`, request `dataBreakpointInfo` (variable reference ->
  `dataId` + supported access types), request `setDataBreakpoints`;
- the `stopped` event with the new reason and a description.

## Increments (each gated on a green suite)

1. Debug-register access behind the thread-context funnel + the x86/WOW64 variant.
   A DevTools probe arms a slot by hand and proves a hit is delivered, on BOTH
   bitnesses, before any of it is wired to a feature.
2. `DR6` disambiguation in the exception handler, with tests that a normal step
   still completes with a watchpoint armed, and vice versa.
3. Per-thread replication: arm-on-create, arm-on-attach, clear-on-detach, plus the
   slot allocator with explicit exhaustion.
4. Session API + stop reason + old/new capture.
5. MCP tools.
6. DAP capabilities and requests.

## Tests to write (both bitnesses, mono and BPL fixtures)

- A worker thread writes a global the main thread never touches: the stop must
  name the WORKER thread. This is the test that proves per-thread replication and
  the one a single-threaded fixture would pass while the feature is broken.
- A thread created AFTER the watchpoint is set trips it.
- Slot exhaustion refuses the fifth with a message, and the first four still work.
- Misaligned or odd-sized request is refused, not rounded.
- Stepping still works with a watchpoint armed (the `DR6` case), and a watchpoint
  hit during a step is not reported as a step completion.
- Detach leaves the target unarmed — verified by continuing it afterwards.
- A local-scoped watchpoint is reported stale after its frame exits.

## Deferred, with the reason

**Software (page-guard) watchpoints** for regions larger than 8 bytes or beyond
four slots. `PAGE_GUARD` traps the whole page, so every access to anything else on
that page must be filtered, re-armed and single-stepped past. That machinery sits
on top of the same single-step path this plan already touches. Not in v1; revisit
only if the four-slot limit proves binding in real use.
