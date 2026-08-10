# Data breakpoints (watchpoints) — plan

Status: **COMPLETE** (2026-08-08), all six increments done and gated on a green
suite. The engine can arm/disarm hardware watchpoints, tell a watchpoint hit
apart from a completed step, replicate a watchpoint onto every thread (present
and future), allocate/free the four slots with explicit exhaustion, a real
session-level API (`TDebugSession.SetDataBreakpoints` / `ListDataBreakpoints` /
`RemoveAllDataBreakpoints` / `GetDataBreakpointInfo`) that resolves an
expression or a live frame's local, arms it, and reports a genuine
`srDataBreakpoint` stop with old->new capture and the firing thread; the MCP
tool surface (`set_data_breakpoint` / `list_data_breakpoints` /
`remove_data_breakpoint`); and the DAP surface (`supportsDataBreakpoints`,
`dataBreakpointInfo`, `setDataBreakpoints`), which is what puts "Break on Value
Change" into VS Code's Variables context menu.

What did NOT get built, each with the reason, is in "Deferred" and in the
increment 6 section: a watchpoint on a FIELD of an expanded object, a
`setDataBreakpoints` that arrives while the target is running, and one
staleness case that is undetectable by construction.

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
**read `DR6`.** Bits `B0..B3` name the slot that fired; `BS` (bit 14) says the trap
flag caused this trap. `DR6` must then be CLEARED, or the next event carries stale
bits and every step afterwards looks like a watchpoint hit.

This is a change to the event pump's most delicate path — the one that took three
measurement rounds to get right for Win32 — so it lands with its own tests before
anything user-facing is wired.

**BUILT (increment 2).** `TWinDebugger.TakeDebugTrapCause` reads and clears `DR6`
at the top of the `EXCEPTION_SINGLE_STEP` / `STATUS_WX86_SINGLE_STEP` branch. What
was measured, and what it forced:

- `BS` **is** reported on both bitnesses, so the pump needs no state of its own:
  `B0..B3` alone mean "a watchpoint fired and no step of ours completed" and the
  event is recorded and resumed without the stepping engine ever seeing it;
  `BS` together with a slot bit means one instruction did both, and the step is
  allowed to complete normally. `DevTools\DataBpProbe -tfstep` measures the first,
  `-tfwalk <n>` the combined case (native x64 and WOW64 both report `BS|B0`).
- `DR6` reads back with every RESERVED bit set — `$FFFF4FF0` for a plain step,
  `$FFFF0FF1` for a slot-0 hit, identical on both bitnesses. It must be masked
  field by field and never tested for "non-zero".
- **`DR6` must be sampled BEFORE anything else touches the thread context.** On
  WOW64 the slot bits were gone by the time the pump had cleared the trap flag
  through `Wow64SetThreadContext`; on native x64 they survived. Reading the cause
  of a trap before mutating the thread is right in either case, but only the
  32-bit target made the ordering observable — the whole feature silently
  recorded no hits at all.
- The read is skipped entirely while no slot is armed, so ordinary stepping —
  which is single-step heavy — costs exactly what it did before.

Increment 2 has no stop reason yet, so a hit that completes no step of ours is
counted, logged (slot, address, thread, PC) and resumed. Tests:
`DataBp_*` / `Win32_DataBp_*` in `DebuggerTests\DebugSessionTests.pas`, three
scenarios per bitness over the `RunDataBpStepFixture` fixture.

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

Four inputs, decreasing order of safety. The fourth was added on 2026-08-10,
after the first three turned out to miss the question watchpoints are mostly
reached for — see "A computed address" below.

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

4. **A computed address** — `Arr[High(Arr)]`, `@Rec.Buf[0]`, or an address typed
   straight into VS Code's "Add Data Breakpoint at Address" panel. The target
   belongs to no variable, which is exactly why it matters: *"who is writing past
   the end of my array"* is the question a watchpoint is most often reached for,
   and the interesting byte is one outside the variable that has a name.

   One rule decides what an expression means, and it is the same at every
   surface:

   | written | watched |
   |---|---|
   | `GCounter` (a bare identifier) | the symbol's own storage |
   | `@X` | the address `@X` yields |
   | anything else (`Arr[3]`, `Rec.F`) | where that expression LIVES, via `@(...)` |

   A bare identifier that resolves to nothing stays "unresolved symbol" — an
   unknown NAME is never reinterpreted as arithmetic that happens to evaluate.

Size comes from the type when the symbol is known, and must be one of 1/2/4/8 with
a correctly aligned address. Anything else is refused with the reason, not rounded
into a watchpoint on a neighbouring byte.

**A width the caller did not name is CHOSEN, not defaulted.** A literal address
originally took the pointer width and was then refused unless 8-aligned, which
rejected almost every byte-sized target — including the byte after a buffer, odd
as often as not. `WidthFittingAddress` now picks the widest of 1/2/4/8 the address
is naturally aligned to, so an unspecified width never produces a refusal. A width
the caller DID name is honoured strictly: a misalignment against it is refused
rather than narrowed behind the caller's back, because the hardware ignores the
low address bits and a silently widened watch covers a neighbouring cell.

### What this needed from the evaluator

Three gaps surfaced when the resolver started handing it real expressions. All
three were in `ExprEval` and are fixed there, so `evaluate` and every watch
expression gained them too:

- `@` parsed only a bare `Primary`, so `@Rec.Field`, `@Arr[I]` and `@(expr)` all
  stopped after the first identifier and reported the rest as an unexpected
  token. The suffix chain belongs to the operand: `@` now takes
  `ApplySuffixes(ParsePrimary)`.
- `Rec.Buf[1]`, where `Buf` is a STATIC array field, fell through to
  accessor-call dispatch and was reported as `<Buf not found>` — a member that
  had resolved, one step earlier, as an array. The "is this value indexable"
  test listed strings, `TArray<>`, `array of` and `^Elem`, but not static arrays.
- `High` / `Low` / `Length` did not know static arrays, whose bounds are IN the
  type and need no target read at all (`ParseStaticArrayDims` already existed for
  indexing). `High(Arr)` is how a user names the last element without hard-coding
  an index that the next edit invalidates.

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

1. **DONE.** Debug-register access behind the thread-context funnel + the x86/WOW64
   variant. A DevTools probe arms a slot by hand and proves a hit is delivered, on
   BOTH bitnesses, before any of it is wired to a feature.
2. **DONE.** `DR6` disambiguation in the exception handler, with tests that a normal
   step still completes with a watchpoint armed, and vice versa. The engine
   primitive is `IDebugTarget.ArmHardwareWatchpoint` / `DisarmHardwareWatchpoint`
   plus `HardwareWatchpointHitCount` / `LastHardwareWatchpointHit`; arming refuses
   a bad slot, size or alignment rather than rounding it. `ReadDebugRegisters` /
   `WriteDebugRegisters` are the fourth role behind the thread-context funnel,
   with the `Wow64Get/SetThreadContext` variant in `WinDebuggerX86`.
3. **DONE.** Per-thread replication and the slot allocator. `IDebugTarget` gained
   `SetDataWatchpoint(Address, SizeBytes, WriteOnly, OwnerDescription; out Slot,
   RefusalReason): Boolean` and `ClearDataWatchpoint(Slot): Boolean` — the real
   allocator, built on top of increment 2's raw per-thread
   `ArmHardwareWatchpoint`/`DisarmHardwareWatchpoint` (now thin wrappers around
   private `ArmWatchRegistersOnThread`/`DisarmWatchRegistersOnThread`, pure
   register I/O with no bookkeeping). `SetDataWatchpoint` finds the first free
   slot (0..3), arms it on every thread in `FThreads`, rolls back threads already
   armed on partial failure, and only records bookkeeping once every thread
   succeeded. `FWatchSlots: array[0..3] of TWatchSlotState`
   (InUse/Address/SizeBytes/WriteOnly/Description) replaces the old
   `FWatchArmedSlots`/`FWatchAddr` pair, which was process-wide state that was
   only correct by accident of every increment-2 test using one thread;
   `FWatchArmedSlots` (byte bitmask) survives as a cached derivative for the
   zero-cost fast path in `TakeDebugTrapCause`. `HandleCreateThread` re-arms
   every in-use slot on a newly-seen thread, best-effort with a loud `DapLog` on
   failure. `Terminate`'s clean-detach branch (`FKillOnDetach=False`) clears
   every in-use slot on every thread before `DebugActiveProcessStop`; the kill
   branch does not need it because the target is terminated anyway.

   **No separate attach code path was needed.** `DebugActiveProcess` makes
   Windows synthesize a `CREATE_THREAD_DEBUG_EVENT` for every thread already
   running in the target, alongside the synthesized `CREATE_PROCESS_DEBUG_EVENT`
   — both arrive through the normal event pump, so `HandleCreateThread` covers
   attach for free. This was verified against the synthesized-event behaviour
   already documented in `Attach()`'s own comment, not assumed.

   Negative controls run and reverted (`TRAPS.md` "Proving a fix"):
   * `Break` after arming only the first thread in the replication loop →
     `DataBp_WorkerThreadWrite_NamesTheWorkerThread` and its Win32 mirror both
     failed ("Expected [1] but got [0]", no hit recorded on the worker thread).
   * Exhaustion refusal changed to silently steal slot 0 instead of refusing →
     `DataBp_SlotExhaustion_RefusesTheFifth` failed ("the fifth watchpoint was
     armed").
   * Clean-detach branch changed to skip clearing watchpoints →
     `DataBp_CleanDetach_LeavesTargetUnarmed` failed with `WAIT_TIMEOUT` (258),
     and the detached target process was confirmed genuinely hung (force-killed
     to clean up).

   Tests: `DataBp_WorkerThreadWrite_NamesTheWorkerThread`,
   `DataBp_ThreadCreatedAfterArm_StillTrips` (both mirrored into
   `TWin32RunControlTests`), `DataBp_SlotExhaustion_RefusesTheFifth` and
   `DataBp_CleanDetach_LeavesTargetUnarmed` (x64 only — exhaustion needs four
   distinct globals to be interesting, and clean-detach needs the attach path)
   in `DebuggerTests\DebugSessionTests.pas`, over a new TestTarget fixture
   `RunDataBpThreadFixture` (`-run-databp-thread`) with two worker threads
   writing separate globals (`DataBpThreadWorkerA`, created before the READY
   stop; `DataBpThreadWorkerB`, created after resume) so each test arms only
   the global it cares about.
4. **DONE.** Session API + stop reason + old/new capture. `TStopReason` gained
   `srDataBreakpoint`. `TWatchpointHit` gained `SizeBytes`/`OldValue`/`NewValue`/
   `Description`; `OldValue` is captured at arm time in `SetDataWatchpoint` and
   refreshed at every hit in `RecordWatchpointHit` (which now also reads
   `NewValue` and stamps `Description` from the slot's `OwnerDescription`).

   **Command queue.** `TCommandKind` gained `ckSetDataBreakpoints` with its own
   spec record (`TDataBpArmSpec`: Address/SizeBytes/WriteOnly/OwnerDescription,
   or Clear+Slot to disarm). `IDebugTarget.ApplyDataBreakpointCommand` posts the
   command and drains it in the same call (`TWinDebugger.DrainDataBreakpointCommand`
   mirrors the existing `DrainBreakpointCommands` dequeue-execute-reenqueue
   shape), so the caller gets the REAL arming outcome synchronously -- slot
   exhaustion and misalignment are refused with a reason at the call site, not
   discovered later. The adapter's main loop is single-threaded (Pump and
   request handling interleave on one thread -- see `DebugSession.pas`'s own
   threading note), so this is not a race fix today; it is the same shape
   `ckSetBreakpoints` uses and keeps arming correct if that ever changes.

   **Session** (`DebugSession.pas`): `SetDataBreakpoints` / `ListDataBreakpoints`
   / `RemoveAllDataBreakpoints`. Unlike source breakpoints there is no per-file
   grouping for an address, so `SetDataBreakpoints` replaces the WHOLE set on
   every call, matching DAP's own `setDataBreakpoints` semantics, and only
   works while `State = dsStopped` (thread contexts are only stable there --
   the same reason DAP's own `dataBreakpointInfo`/`setDataBreakpoints` only
   make sense at a stop). `ResolveDataBpAddress` accepts a literal address
   (`$hex` / `0xhex` / decimal) or a global/unit variable name through the
   same resolution the evaluator uses, and tells "no such symbol" apart from
   "that IS a symbol, but a LOCAL" -- locals are refused explicitly, naming
   why (their lifetime is tied to a stack frame; needs `dataBreakpointInfo`,
   increment 6), never silently accepted as a stale address. `ArmOneDataBreakpoint`
   validates size (1/2/4/8) and alignment, resolves module+RVA when the address
   falls inside a known module (via `GetModules`), and notes the
   no-read-only-watchpoint caveat in the result `Message` when `WriteOnly=False`
   rather than letting a surprise write-hit look like a bug.

   **Stop reporting.** The main event pump's free-run watchpoint branch (the
   `not Trap.TrapFlagStep` case) now reports a real stop, `ReportStopped(srDataBreakpoint,
   ExcAddr)`, but ONLY when `FStepMode = smNone` -- i.e. only for a genuine
   `ContinueExecution`, never for an in-flight step. This was a load-bearing
   constraint discovered while implementing, not originally written down here:
   the already-committed increment 2/3 test
   `RunWatchpointHitDuringStepIsNotAStepCompletion` asserts a watchpoint hit
   inside a stepped-over CALL must NOT redirect the step into the callee --
   the step's own resume breakpoint still owns that thread and must be allowed
   to finish normally. Increment 4's new stop only fires in the complementary
   case: nothing of the debugger's own is in flight on that thread.
   `HandleTargetStopped` and `Snapshot` both format "expr: old -> new (thread
   N)" through one shared helper, `BuildDataBreakpointDescription`, reading
   `IDebugTarget.LastHardwareWatchpointHit`, so a polled snapshot and the
   original stop event never disagree.

   **Synthetic-call interaction, decided:** a watchpoint hit during a
   `RunMethodCall` aborts the call, exactly like a raise -- the model the
   function already follows for a Delphi exception or an AV. This was
   necessary, not optional: `RunMethodCall` runs its OWN private event-pump
   loop (separate from the main pump), and before this change a watchpoint
   trap reaching that loop fell through to a bare `DBG_CONTINUE` with DR6
   never read -- a latent bug increment 4 would otherwise have INTRODUCED,
   because the CPU never clears DR6 on its own (TRAPS.md) and the next
   ordinary step after ANY synthetic call would then misread as a watchpoint
   hit. The loop now samples/clears DR6 on every single-step exception and, if
   a slot fired, restores the pre-call context, sets
   `FLastSyntheticCallError` to a message naming the firing thread and the
   watchpoint's description, and fails the call.

   Tests (mono + Win32 where noted): `DataBp_SessionApi_StopsWithOldNewAndThread`
   (+ Win32 mirror) -- arms via the session API, continues, asserts a REAL stop
   with `srDataBreakpoint`, the correct firing thread, and an old->new
   description naming the watchpoint. `DataBp_SessionApi_RejectsLocalWithReason`
   -- a local (`W` at the eval fixture) is refused with a reason mentioning
   "local", not armed. `DataBp_SessionApi_SlotExhaustion_PerSpecResults` -- five
   specs through one `SetDataBreakpoints` call, per-spec Verified/Message (four
   armed, the fifth refused), matching `ListDataBreakpoints`.
   `DataBp_SessionApi_RemoveAll_StopsWatching` -- after `RemoveAllDataBreakpoints`
   the target runs PAST the write it used to stop on, proving the hardware slot
   was genuinely cleared, not just forgotten by the session. `DataBp_DuringSyntheticCall_AbortsEvaluation`
   (+ Win32 mirror) -- `Evaluate('DataBpWriteWatched()')` is aborted mid-call;
   the error text names the data breakpoint, the session stays usable
   afterward, and a follow-up read of `GDataBpOther` proves the call really
   stopped at the trap (only the statement BEFORE the watched write ran, not
   the one after).
5. **DONE.** MCP tool surface: `set_data_breakpoint(expression, size, access)`,
   `list_data_breakpoints`, `remove_data_breakpoint(id)` in `MCPDebugger\McpServer.pas`
   / `McpToolSchemas.pas`, JSON shape in `McpJson.pas`. `expression` accepts
   either form the session already resolves (a literal address or a
   global/unit variable name) -- "address | expression" in the plan above is
   one parameter, not two, matching `TDataBpSpec.Expression`.

   **Granularity mismatch, handled at the MCP layer, not the session.**
   `TDebugSession.SetDataBreakpoints` is whole-set-replace (increment 4,
   mirroring DAP's own `setDataBreakpoints`) and reassigns every entry a FRESH
   `Id` on every call, even to specs that did not change. The MCP tools want
   to add/remove ONE watchpoint at a time with an id that stays valid across
   later calls. Resolved by keeping the accumulated spec list and a parallel
   array of MCP-owned ids (`wp1`, `wp2`, ...) in `TMcpServer`
   (`FDataBpSpecs`/`FDataBpOwnIds`/`FNextDataBpOwnId`) -- source of truth for
   what SHOULD be armed. `set_data_breakpoint` appends and resends the whole
   list; `remove_data_breakpoint` splices by MCP id and resends the reduced
   list; both read the result back at the same array position, so the
   session's own regenerated `Id` never needs to be stable. `list_data_breakpoints`
   does not call `SetDataBreakpoints` (that would re-arm for no reason); it
   just zips `FSession.ListDataBreakpoints` with the cached own-ids array,
   which is safe because MCP is the only caller of the session's data-breakpoint
   API and both arrays are always mutated together. `EnsureFreshSessionForStart`
   clears both arrays exactly when it recreates `FSession`, so a relaunch
   starts with an empty tracked set instead of stale entries from a dead
   debuggee. This is an implementation choice made without changing the
   session API's shape -- a standard read-modify-write adapter over a
   replace-all primitive -- not a design decision that needed escalation.

   **Both mutating tools gate on `State = dsStopped` in the MCP handler**,
   before ever calling into the session, even though `SetDataBreakpoints`
   already refuses everything when not stopped on its own. Without the
   earlier gate, a `remove_data_breakpoint` call while running would resend
   the WHOLE reduced list through `SetDataBreakpoints`, which refuses every
   entry uniformly with "data breakpoints can only be set while stopped" --
   making already-armed watchpoints look newly broken instead of reporting
   the real reason (wrong state) plainly. `list_data_breakpoints` has no gate,
   matching `list_breakpoints`: it only reads cached state.

   **`access="read"` is refused OUTRIGHT at the MCP layer**, not passed
   through: `TDataBpSpec.WriteOnly` is a boolean with no "read-only" value to
   represent it, so there is nothing for the session to accept. The refusal
   names why (no hardware equivalent) and points at `"readWrite"`, which DOES
   arm and carries the already-built no-read-only-watchpoint caveat in its
   `message` (increment 4's `ArmOneDataBreakpoint`) -- surfaced verbatim, not
   reworded.

   **Bug found and fixed in the same change set**: `McpJson.ReasonName` had no
   case for `srDataBreakpoint` (added by increment 4's `TStopReason`), so
   `get_compact_debug_snapshot`/`continue_and_wait` reported `stopReason:
   "unknown"` for a real watchpoint hit -- silently indistinguishable from an
   actual unknown reason. Fixed by adding the case; `SnapshotToJson` also
   gained a `dataBreakpointDescription` field (only present when
   `stopReason = "dataBreakpoint"`), surfacing the session's own
   `BuildDataBreakpointDescription` string ("expression: $old -> $new (thread
   N)") verbatim -- no new session-layer plumbing needed, increment 4 already
   built the whole thing, increment 5 was purely wiring it into JSON.

   Tests (`DebuggerTests\McpE2ETests.pas`, mono fixture, x64 -- the underlying
   engine/session correctness is proven per-bitness by the increment 3/4
   `DataBp_SessionApi_*` tests, not re-proven here): `DataBreakpoint_StopsWithAddressThreadOldNew`
   (worker-thread scenario; also the negative control for the `ReasonName` fix
   -- reverting it fails this test's `stopReason` assertion),
   `DataBreakpoint_ReadWriteAccessCarriesCaveat`, `DataBreakpoint_ReadAccessRefusedExplicitly`,
   `DataBreakpoint_LocalRefusedWithReason`, `DataBreakpoint_SlotExhaustion_RefusesFifthWithEngineMessage`,
   `DataBreakpoint_ListAndRemove_ClearsHardwareSlotForReal`.
6. **DONE.** DAP capabilities and requests, and with them the case increments
   4 and 5 both refused: a watchpoint on a **LOCAL**.

   **Capability + requests.** `supportsDataBreakpoints` in the `initialize`
   response, `dataBreakpointInfo` and `setDataBreakpoints` in the dispatcher
   (`VisualStudioCodeDelphiDebugger\DapServer.pas`), and a `srDataBreakpoint`
   case in the `stopped` event that was MISSING -- exactly the DAP twin of the
   `McpJson.ReasonName` bug increment 5 found. Without it a watchpoint stop
   arrived with NO `reason` field at all, which VS Code renders as an unnamed
   pause. `description` and `text` carry the session's own
   `BuildDataBreakpointDescription` string ("V: $1 -> $2A (thread N)").

   **The neutral engine is in the session, not the adapter.**
   `TDebugSession.GetDataBreakpointInfo(Name, FrameIndex, ThreadId)` returns a
   `TDataBpTargetInfo`: it tries a literal address, then a LOCAL of the named
   frame, then a global (locals shadow globals, which is Delphi scope), derives
   the watch width from the declared type (`WatchWidthForType`: an explicit
   name table first -- bitness-aware, so `Pointer`/`NativeInt`/`string` are 4
   bytes on a WOW64 target -- then the type providers, then the pointer-width
   type KINDS), and refuses anything it cannot justify: a register-allocated
   local (`RegId > 0`, no address exists at all), a frame with no frame pointer,
   a type with no 1/2/4/8 width, a misaligned address, an unknown name. A
   `var` parameter is followed to its POINTEE, because the slot itself only
   holds the reference. Putting this in the session (rather than in DapServer)
   is what let the LOCAL behaviour be tested on BOTH bitnesses -- the DAP
   fixture is x64-only.

   **Frame lifetime, the hard part.** A local's address is a stack slot, so it
   names the user's variable only while the owning frame lives. `TDataBpSpec`
   gained `TDataBpFrameScope` (thread + frame base + function entry VA) and a
   `DisplayName` (a frame-scoped spec travels as a literal address, so without
   it every stop would read "$19FE44: ..." instead of "V: ..."). Two guards,
   both deterministic, both proven by their own negative control:

   * `PruneStaleDataBreakpoints` runs at EVERY stop, before the stop is
     reported -- a stop is the only moment a stack can be read, so it is the
     only moment staleness is detectable at all. It walks the owning thread
     RAW (`IDebugTarget.GetStackFrames(Tid)`: no symbolication, no
     raise-plumbing trim, no write to the stopped thread's frame cache) and
     looks for a frame matching (FrameBase, FuncEntryVA). Not found -> clear
     the hardware slot, drop the watchpoint, fire `OnDataBreakpointRemoved`.
     When the hit that CAUSED this stop belongs to the watchpoint just
     retired, the description gains a "STALE: ... this hit was on reused
     stack" note, so the old->new never reads as a genuine change.
   * `ArmOneDataBreakpoint` runs the same liveness test before arming. Without
     it, the client's next whole-set replace (VS Code sends the full set every
     time) would put the watchpoint straight back onto dead stack.

   **The residual case, undetectable BY CONSTRUCTION and therefore documented
   rather than guessed at:** the SAME routine re-entered at the SAME stack
   depth reproduces an identical (FrameBase, FuncEntryVA) pair. The watchpoint
   then follows the same local of a NEW invocation -- the same variable in the
   same routine, a different call. It can never drift onto a DIFFERENT
   variable, which is the failure this mechanism exists to prevent. Frame
   identity deliberately includes the entry VA and not just the base, because
   the base alone is shared by any routine reaching that depth.

   **`dataId` encoding.** DAP's `setDataBreakpoints` sends the id and an
   access type and nothing else -- no address, no width, no frame -- and VS
   Code PERSISTS data breakpoints in workspace state and re-sends them at the
   next launch. So the id carries everything, and carries the shape that
   survives a relaunch where one exists:
   * `d1|g|<size>|<name>` -- a global, by NAME, re-resolved at set time;
   * `d1|a|<size>|<module>|<rva>` -- an address as module+RVA (bare VA when
     outside every image), same reasoning as an address breakpoint;
   * `d1|l|<size>|<nonce>|<tid>|<base>|<entry>|<addr>|<name>` -- a
     frame-scoped local, stamped with a per-run nonce. A `dataId` from an
     earlier session is refused BY NAME ("...created for a stack frame of an
     earlier debug session"), never re-armed at whatever now lives there.
     `canPersist` is reported `false` for exactly this kind, so a
     well-behaved client does not even try.

   **Access types.** `accessTypes` is `["write","readWrite"]` and never
   contains `read`: there is no read-only watchpoint on x86/x64, and listing
   one would advertise a filter the hardware cannot apply. The `readWrite`
   caveat travels in the `dataBreakpointInfo` description and again in the
   armed breakpoint's `message`. `accessType:"read"` in `setDataBreakpoints`
   is refused per entry, pointing at `readWrite` -- same decision the MCP
   layer took in increment 5.

   **Refused, with the reason surfaced instead of a guess:**
   * a `variablesReference` that is an expansion handle (a field of an
     expanded object or record): the expander answers in values, not
     addresses, so there is no address to watch. This is a real gap -- "which
     assignment corrupts this field" is a question users have -- and closing
     it needs an address-bearing expansion handle, not a heuristic;
   * the Registers scope: a CPU register has no memory address;
   * `setDataBreakpoints` while the target is RUNNING: arming reads and writes
     live thread contexts, which are only stable at a stop. Every entry comes
     back `verified:false` with that reason (the same gate the MCP tools use,
     for the same reason: letting the session refuse them uniformly makes
     already-armed watchpoints look newly broken). Consequence to know about:
     a data breakpoint DELETED from the UI while the target runs stays armed
     until the next stop.

   Tests -- `Test_DataBp_*` in `DebuggerTests\DebuggerTests.pas` (5 tests, each
   run in BOTH the mono and the BPL fixture): capability advertised;
   info+set+continue stops with reason `data breakpoint` and `V: $1 -> $2A
   (thread N)`; the stale flow (announced, removed, and re-arming refused);
   `read` refused; the Registers scope refused with a reason. Session-level --
   `DataBp_Info_OffersWriteAndReadWriteButNeverRead`,
   `DataBp_Info_RefusesUnknownNameWithReason`,
   `DataBp_LocalWatch_FiresWithOldNew`,
   `DataBp_LocalWatch_GoesStaleWhenFrameExits` in
   `DebuggerTests\DebugSessionTests.pas`, the last two mirrored into
   `TWin32RunControlTests` (frame identity is EBP-based there and liveness runs
   over the x86 walk -- neither is exercised by the x64 pair). New TestTarget
   fixture `RunDataBpLocalFixture` (`-run-databp-local`): `DataBpLocalWriter`
   holds `V` live and writes it once; `DataBpLocalAfter` then runs at the SAME
   stack depth with a local of the same width, so the slot is genuinely reused.

   Negative controls run and reverted, all failing exactly as intended in both
   DAP fixtures and (where they exist) on both bitnesses:
   * remove the `srDataBreakpoint` case from the `stopped` event ->
     `Test_DataBp_LocalWrite_StopsWithOldNewAndThread` failed with
     `Expected [data breakpoint] but got []` -- i.e. the pre-fix wire really
     did carry no reason at all;
   * accept `accessType:"read"` as read-or-write ->
     `Test_DataBp_ReadAccessRefusedWithReason` failed with "a read-only
     watchpoint must be refused, not silently armed as readWrite";
   * drop the Registers-scope branch -> the refusal fell through to the
     expansion-handle message and `Test_DataBp_Info_RegisterScopeRefusedWithReason`
     failed;
   * disable `PruneStaleDataBreakpoints` -> `DataBp_LocalWatch_GoesStaleWhenFrameExits`
     and its Win32 mirror failed with "the watchpoint on a dead frame was NOT
     retired -- it is now watching reused stack", and both DAP stale tests
     timed out waiting for the announcement;
   * disable the arm-time liveness test -> all four stale tests failed with
     "re-arming a dead frame must be refused", confirming the client's next
     whole-set replace would indeed re-arm it.

7. **DONE (2026-08-10).** Watchpoints on a COMPUTED address — case 4 of "Scoping
   an address" above. `GetDataBreakpointInfo` gained `AsAddress` and
   `RequestedBytes`; `ResolveDataBpAddress` gained the same expression rule, so
   MCP and the re-arm path do not diverge from DAP; `WidthFittingAddress` chooses
   an unspecified width instead of defaulting to a pointer and refusing;
   `supportsDataBreakpointBytes` turns on VS Code's "Add Data Breakpoint at
   Address"; and the address-kind `dataId` carries a display name so a hit keeps
   reading as the expression the user wrote. Three evaluator defects fixed on the
   way (see above). Tests: `DataBpExpressionTests.pas`, seven cases,
   `TEST_CATALOG.md` section W.

## Tests to write (both bitnesses, mono and BPL fixtures)

- A worker thread writes a global the main thread never touches: the stop must
  name the WORKER thread. This is the test that proves per-thread replication and
  the one a single-threaded fixture would pass while the feature is broken.
  DONE, both bitnesses.
- A thread created AFTER the watchpoint is set trips it. DONE, both bitnesses.
- Slot exhaustion refuses the fifth with a message, and the first four still
  work — proved by freeing one slot and confirming its number is reused. DONE
  (x64 only).
- Misaligned or odd-sized request is refused, not rounded. DONE for the width
  half (`DataBp_Info_OffersWriteAndReadWriteButNeverRead` pins the derived
  width; `GetDataBreakpointInfo` refuses a type with no 1/2/4/8 width and a
  misaligned address). The alignment branch itself has no fixture: every local
  and global in the test targets is naturally aligned, and manufacturing a
  misaligned one would be a fixture about the fixture.
- Stepping still works with a watchpoint armed (the `DR6` case), and a watchpoint
  hit during a step is not reported as a step completion. DONE — and the negative
  controls are worth recording, because one of them says less than it looks:
  * removing the `DR6` read entirely fails both hit tests with "no watchpoint hit
    was recorded", but the step-over still LANDS correctly. The range-based
    step-over recovers from a stray single-step on its own, so on that path the
    disambiguation buys RECOGNITION rather than run-control correctness. The paths
    that are not self-correcting (the pending breakpoint re-arm, and every stop
    reason increment 4 will add) have no such luck.
  * ignoring `BS` and swallowing every slot-bit trap strands the step: the target
    resumes with no trap flag and runs to exit. Both bitnesses, symptom "the step
    whose own instruction tripped the watchpoint never completed".
- A watchpoint hit on an instruction that is ALSO a single step (`BS` + slot bit)
  must still complete the step. DONE, both bitnesses.
- Detach leaves the target unarmed — verified by continuing it afterwards. DONE
  (x64, attach-based, since only attach-mode detach takes the clean-detach path
  — a bounded `WaitForSingleObject` on the target process is the failure
  signature for a stray armed `DR7`, which would otherwise trap into no
  debugger and hang the process behind a modal RTL exception dialog).
- A local-scoped watchpoint is reported stale after its frame exits. DONE, both
  bitnesses at the session level and both fixtures at the DAP level
  (`DataBp_LocalWatch_GoesStaleWhenFrameExits`, `Win32_...`,
  `Test_DataBp_LocalGoesStale_RemovedAndAnnounced`).

## Deferred, with the reason

**A watchpoint on a FIELD of an expanded object or record.** DAP offers it --
VS Code puts "Break on Value Change" on every row of the Variables tree -- and
`dataBreakpointInfo` receives the expansion handle as `variablesReference`. The
expander (`VariableExpander`) answers in formatted VALUES, not addresses, so
there is nothing to derive an address from without either re-resolving the whole
`evaluateName` chain (which returns a value, not an lvalue) or teaching the
expansion handles to carry the address of what they expanded. The second is the
real fix; until then the request is refused with that sentence rather than
answered with an address that is not the field's.

**Applying a `setDataBreakpoints` that arrives while the target is running.**
Arming touches live thread contexts. A pending-set queue drained at the next
stop is buildable (the source-breakpoint path already has `FPendingBps`), but it
also needs the already-sent `verified:false` response to be corrected by a later
`breakpoint` event, so it is a whole async path rather than a small addition.
Deliberately not built; the refusal names the state instead.

**Following a local across ALL its activations — CONSIDERED AND REJECTED
(2026-08-08, maintainer's decision).** A frame-scoped watchpoint covers ONE
activation: the frame that was live when it was armed. The alternative — "watch
this variable every time the routine runs" — would need a breakpoint on the
routine's ENTRY to recompute the slot address per call, which stops the target
thousands of times on a hot routine; it collides with recursion, where many
activations are live at once and each has a different address against four
hardware slots in total; and it multiplies again per thread. It also answers a
question users rarely ask: "who corrupts this variable" almost always means *in
this activation, now*.

What makes the single-activation version honest is that a stale watchpoint
cannot lie quietly: the only way it misleads is by FIRING, and firing is a stop,
which is exactly when `PruneStaleDataBreakpoints` can see the frame is gone. The
worst case is one spurious stop, labelled as landing on reused stack — not a
stream of false hits. Do not reopen this without a concrete case the
single-activation form cannot serve.

**Software (page-guard) watchpoints** for regions larger than 8 bytes or beyond
four slots. `PAGE_GUARD` traps the whole page, so every access to anything else on
that page must be filtered, re-armed and single-stepped past. That machinery sits
on top of the same single-step path this plan already touches. Not in v1; revisit
only if the four-slot limit proves binding in real use.
