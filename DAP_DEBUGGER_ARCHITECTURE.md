# DAP Debugger Architecture

Living specification for the Delphi Win64 DAP adapter implemented under
`VisualStudioCodeDelphiDebugger/`. Source of truth is the code; if this document and the
code disagree, the code wins. Update this file whenever a module's
responsibilities, threading model, or external contract changes.

Companion documents:
- `RSM_FORMAT_NOTES.md`, `RSM_RECORD_TYPES.md`, `RSM_FIELD_OFFSETS.md` —
  symbol-information format we consume.
- `KNOWN_UNKNOWNS.md` — open questions blocking further work.

## High-level wiring

```
VS Code ── DAP (JSON over stdio) ── VisualStudioCodeDelphiDebugger.exe ── Win32 Debug API ── Debuggee.exe
                                          │
                                          └── reads .map, .rsm, source files
```

The adapter is a single Win64 process. VS Code spawns it via the local
debug-type extension and exchanges DAP messages on stdin/stdout. The
adapter spawns the debuggee with `DEBUG_ONLY_THIS_PROCESS`.

## Two frontends over one core (DAP + MCP)

The debugger engine is exposed through two frontends:

```
                 TDebugSession  (DebugSession.pas — JSON-free core facade)
                 owns: IDebugTarget engine + symbols + source + state machine
                  │                                   │
        TDapServer (VS Code, DAP)          TMcpServer (agent, JSON-RPC/MCP)
```

- `IDebugTarget` (`DebugTarget.pas`) is the low-level, frontend-neutral engine
  contract; `TWinDebugger` implements it.
- `TDebugSession` (`DebugSession.pas`) is a higher-level, still JSON-free facade
  that owns the engine plus the aggregate debug-info set, symbol readers, the
  `TSourceResolver`, the evaluator/value-formatter, and an explicit
  `TDebugSessionState` machine. It returns the neutral records in
  `DebugSessionTypes.pas` (no DAP ids) and drives async waits via a monotonic
  `StopGeneration` bumped on every stop/exit.
- `TMcpServer` (`McpServer.pas`) is a second frontend: newline-delimited JSON-RPC
  2.0 over stdio, exposing semantic tools to an autonomous agent. It shares the
  engine via `TDebugSession`; it does NOT round-trip through DAP. Shipped as a
  separate exe (`DelphiDebuggerMcp.exe`, `build_mcp.bat`). See `MCP_SERVER.md`.
- **Current status:** the MCP frontend is built on `TDebugSession` and covers
  launch/attach, breakpoints (incl. conditional/hit/logpoint), stepping, stack,
  locals + nested expansion (class/record/dynamic-array), evaluate, and multi-
  module/BPL symbols (see `MCP_SERVER.md`).
- **Phase B (delete DAP↔core duplication) — in progress.** `TDapServer` is being
  rewritten to delegate to the shared core instead of keeping its own copies:
  - **Source resolution: DONE.** `TDapServer.ResolveSourcePath` /
    `ResolveUnitToSource` now delegate to a shared `TSourceResolver`
    (`DebuggerCore\SourceResolver.pas`), configured from the source roots in
    `SetupDebugSession` / `HandleLaunch`. The ~230-line inline search +
    `FSourcePathCache` were removed; DAP suite stays byte-compatible.
  - **Remaining (blocked on session feature-parity):** the variable-expansion
    orchestration (the `Append*` family) can only move down once `TDebugSession`
    matches the DAP's expansion features (getter properties, Variant arrays), else
    the DAP would regress. Symbol-loading delegation is complicated by the DAP's
    background loader vs the session's synchronous loader. These stay as follow-up.
  Protocol-free coverage: `DebuggerTests\DebugSessionTests.pas`; MCP end-to-end:
  `DebuggerTests\McpE2ETests.pas`.

## Modules

- `VisualStudioCodeDelphiDebugger.dpr` — entry point. Calls
  `DapServer.RunDapServer`, unless the command line asks for the one-shot
  `--list-processes [name]` query (see `ProcessListJson.pas`), in which case it
  prints the process list and exits without starting the DAP loop.
- `ProcessListJson.pas` — `--list-processes [name]`: `ProcessEnum` serialized as
  a single line of UTF-8 JSON on stdout
  (`pid`, `parentPid`, `sessionId`, `name`, `path`, `commandLine`, `arch`,
  `canDebug`, `reason`). This is what the VS Code extension's attach process
  picker reads. It replaced parsing `tasklist` output in the extension, which
  was localized (the `N/A` placeholder is `N/D` on an Italian Windows), could
  not report a target's architecture, and did not expose the command line — the
  field that distinguishes two instances of one application. `tasklist /V` also
  measured 82 s for a full enumeration against 66 ms for this mode.
- `DapProtocol.pas` — DAP framing (`Content-Length` headers, JSON
  parsing), stdin/stdout I/O, log file at `%TEMP%\dap_adapter.log`,
  shared `TBpSpec` / `TCommand` types used by both layers.
- `DapServer.pas` — DAP request dispatcher. Owns the DAP-side state
  (capabilities, pending breakpoints, source paths) and the DAP message
  loop. Translates each DAP request into either an immediate JSON
  response or a `TCommand` posted to the debug thread.
- `Win64Debugger.pas` — Windows debug loop. Drives `WaitForDebugEvent`,
  manages INT3 plant/remove, single-step, breakpoint reactivation,
  StackWalk64-based unwinding, synthetic remote calls into the
  debuggee, and the local/global variable readout.
- `MapFileReader.pas` — parses the Delphi `.map`. Supplies
  `ISourceLineProvider` (RVA ↔ source line), `IFunctionNameProvider`
  (RVA ↔ public symbol, lookup by name, enclosing-procedure mapping
  via Itanium-mangled `_ZZ…E…` symbols).
- `RsmFileReader.pas` — parses the Delphi `.rsm`. Supplies
  `ILocalSymbolProvider` and `IGlobalSymbolProvider`.
- `DebugInfoSet.pas` / `DebugInfoTypes.pas` — aggregate provider
  registry plus the shared types (`TSourceLocation`, `TLocalSymbol`,
  `TGlobalSymbol`, `TLocalKind`).
- `ModuleSymbolLoader.pas` — the shared, SYNCHRONOUS symbol/module loader
  (`TModuleSymbolLoader`) both frontends delegate to. Owns the runtime-module
  registry (`TModuleSymbols`; the DAP subclasses it as `TDllModule` for the
  PACKAGEINFO membership test via `ModuleClass`) and every per-module load
  primitive: `LoadMainModule` (RSM→TD32-primary→MAP), `RegisterModuleRecord` /
  `RemoveModuleRecord`, `EnsureModule{Rsm,TD32,Map,Dcp}`, `LoadModuleSymbols`,
  `ModuleForPC` / `EnsureModuleForPC`, `ModuleRvaRange`, `AddModuleProvider`.
  It is thread-agnostic and adds no thread/queue: all provider mutation runs on
  the caller's debug-loop/dispatch thread (`FDebugInfo` is not thread-safe).
  Frontend behaviour is injected as hooks — `OnSymbolsLoaded` (breakpoint
  re-post/re-colour), `ShouldRetryModule` (DAP = launch-config retry, session =
  none), `RequiresFor` (DAP = PACKAGEINFO requires, session = none), plus
  diagnostic/console log sinks. The invariants preserved verbatim: provider
  order RSM-before-TD32-before-MAP-before-DCP with the main TD32 front-inserted
  as Primary; RVA shift = `Base − exeImageBase` under `{$Q-}`; DLL MAP added
  UNSCOPED while RSM/TD32/DCP are RVA-range-scoped; the per-module `*Tried`
  probe-once negative cache; `SymbolFileIsStale`'s 2 s grace. The DAP keeps its
  background loader (still off by default), progress/spinner, and evaluate
  warm-up caches on top of the shared synchronous primitives.

## Threading model

Two threads run inside the adapter:

1. **Main / debug thread** — owns the `TWin64Debugger` instance, calls
   `WaitForDebugEvent`, mutates breakpoint state, invokes
   `ContinueDebugEvent`. Also drains the request queue and writes DAP
   responses on stdout.
2. **Stdin reader thread** — created in `TDapServer.Run` as an anonymous
   `TThread`. Reads framed DAP messages from stdin and pushes them as
   `TJSONObject` instances into a `TThreadedQueue`.

The reader pushes; the main thread pops. The queue itself synchronises;
no other shared mutable state crosses threads.

`PostCommand` enqueues `TCommand` records onto a separate queue
(`FCommandQueue`, guarded by `FQueueLock`) consumed by the debug thread
in `ProcessCommandQueue`. This is how DAP-side intent (continue, step,
setBreakpoints) reaches the debug loop without blocking the reader.

The Windows debug API requires that all `WaitForDebugEvent` /
`ContinueDebugEvent` calls happen on the thread that called
`CreateProcess`. Both happen on the main thread; the reader thread
never touches them.

### Symbol index build (`TRsmFile.LoadFromFile`)

A third, transient thread exists per symbol file: `LoadFromFile` memory-maps
the container, parses the user-type table synchronously, then forks an
anonymous thread that builds the index (`BuildIndexAndPublish`) and persists it
to the `<file>.idx` sidecar.

The tail of that thread has a fixed order: **serialise → publish readiness →
write the file**.

- Serialisation happens under `FLock`, before `FIndexReady`, and must stay
  there: once the index is ready, lazy lookups mutate the very containers the
  serialiser enumerates (`FProcLocals` above all), so serialising afterwards
  would make the sidecar depend on which lookups happened to land first — and
  a `TDictionary` rehash under a `for-in` is an access violation, not a wrong
  answer.
- `FIndexReady` is set *before* the file write, so symbol availability is not
  coupled to I/O latency on a shared or network output directory.
- `FIndexReady` is set in a `finally` that also covers the phase waves. A
  reader that never publishes readiness makes every subsequent `WaitForIndex`
  burn its full 60 s budget — that is how a failed sidecar write used to hang
  the debugger for a minute per lookup.

That build runs in **two waves**, and the split is load-bearing:

- **Wave 1 (producers)** — `ParsePerUnitImports`, `ParseTypeDeclarationSection`,
  `ParseTypeInfoSection`, `IndexClassMemberRecords`. Each walks the whole byte
  buffer and fills containers no other wave-1 phase reads, so they fan out
  across cores and cost ~max(phase) rather than the sum.
- **Wave 2 (consumers)** — `ScanForProcOffsets` (via `TryParseGlobalAt`) and
  `CollectMainBlockLocals`. Both resolve type hints through
  `OwningUnitContext` + `ResolveTypeIdInUnit`, which read `FUnitAnchors`,
  `FUnitImports`, `FTypeIdToName`, `FClassHashCandidates` and `FUserTypes` —
  all wave-1 output.

Running all six in one flat fan-out (the shape before 2026-07-20) made the
build both lossy and non-deterministic: hints were resolved against
half-filled dictionaries, so three consecutive cold builds of the same
`.rsm` produced three different sidecars, each missing a different subset of
the resolved type hints — and the degraded index was then cached in the
`.idx` and reused by every later session. It also read `FTypeIdToName` /
`FClassHashCandidates` without `FLock` while a sibling task wrote them under
it, which is an access-violation risk on a `TDictionary` rehash, not merely a
wrong answer. Any new phase must be classified as producer or consumer and
placed in the right wave.

The sidecar is serialised into a `TMemoryStream` (`SerializeIndexToStream`) and
that buffer is written to disk in one go. The encoder emits one field at a
time; against a raw `TFileStream` that is one `WriteFile` syscall per field
(~246,000 of them for a 45 MB `.dcp`) and it dominated the whole cold build.
Never swap that sink back for an unbuffered stream. `TMapFile`'s unit-index
sidecar uses a `TBufferedFileStream` for the same reason.

Publication (`PublishSidecar`) writes a per-process/per-thread `.tmp` next to
the target and renames it into place with `MoveFileEx(...,
MOVEFILE_REPLACE_EXISTING)`, so no reader can observe a half-written index.
Losing the rename race is fine — whatever is already there was published by
another writer and is complete. A writer must **never** delete or truncate a
sidecar it did not write, and no failure in this path may escape into the index
thread (`DevTools\PrebuildIdx` running alongside a live session is the everyday
way to hit it).

Sidecar strings are UTF-8 with a 16-bit length prefix and a `$FFFF` escape that
introduces a 32-bit length. The escape exists because the length used to be a
silently truncating `UInt16` assignment: a payload over 64 KB desynchronised
the rest of the stream undetectably. Files under 64 KB per string encode
exactly as before, so `RSM_SIDECAR_MAGIC` is unchanged.

**F14 invariant.** The freeze recorded as F14 was caused by unbounded
*waiting*, not by the work: the build was already off-thread and the dispatch
thread was asleep in `WaitForIndex`. The invariant to preserve is *the
dispatch thread never blocks unboundedly on symbol state* (enforced by
`InteractiveDeadlineTicks` / `TInteractiveWaitGuard`). Starting symbol work
earlier, fire-and-forget, does not violate it.

`TRsmFile.InteractiveDeadlineTicks` and `TInteractiveWaitGuard`'s nesting
depth are **thread-local**. They were process-wide class vars, which meant any
non-dispatch thread inherited the stop budget (abandoning its own index build
half-way) and cleared it when its own scope ended (disarming F14 protection in
the middle of a stop). Covered by
`RsmReaderTests.InteractiveDeadline_IsPerThread`.

## Symbol prefetcher (built, DISABLED by default)

**Status:** `SetSymbolPrefetchEnabled` defaults to False; `SYMBOL_PREFETCH=1`
enables it. With it on, the full suite intermittently loses a request to a 30 s
timeout in the BPL fixture -- unexplained, see TASK_RESUME. The rules below are
the design as built and must be preserved by whoever finishes it.

`TSymbolPrefetcher`, inside `DebuggerCore\ModuleSymbolLoader.pas`, so BOTH
frontends get it (the earlier, shelved, environment-variable-gated loader lived
in `DapServer.pas` and MCP had nothing).

Why it exists: with no breakpoint set — the normal state right after attach —
`HandleDllLoaded`'s eager gate never fires and nothing is parsed for any
module. The first stop then paid a full synchronous parse per module on the
stack, measured at 98–652 ms per real BPL, and until it finished those frames
had no names.

Shape:

```
LOAD_DLL  --(dispatch thread)--> EnqueuePrefetch: CLAIM the module, push a
                                 VALUE SNAPSHOT of it onto the queue
worker    --(one thread)-------> build brand-new readers from the snapshot
Pump      --(dispatch thread)--> DrainPrefetch -> PublishPrefetch: register
                                 the finished readers, clear the claim
```

Rules, each of which is load-bearing:

- **One writer.** The worker never touches a `TModuleSymbols`, the registry,
  the `TDebugInfoSet` or any already-registered reader. It gets a
  `TPrefetchRequest` value copy and returns objects nothing else has seen.
  `TDebugInfoSet` therefore still needs no lock.
- **Claim before parse.** `PrefetchInFlight` is set at enqueue and cleared at
  publication, both on the dispatch thread, so it needs no lock. While it is
  set no `EnsureModule*` may parse that module. The shelved loader omitted this
  and both threads parsed the same file concurrently.
- **Never mark a claimed module as tried.** An `EnsureModule*` that declines
  because of a claim must not set the `*Tried` flag, or a transient gap becomes
  a permanent nameless frame.
- **Steal back, never wait.** `PrefetchBlocks` tries `TryRevoke`: if the
  request is still queued the dispatch thread takes it and parses in-line,
  which is exactly the pre-prefetch cost. If the worker has already started, the
  caller DECLINES — the frame is nameless for that one request and refills on
  the next. An earlier revision waited briefly instead (750 ms, further capped
  by the interactive budget) and that alone reproduced the failure that got the
  previous background loader disabled: one request per full-suite run timing out
  in the BPL fixture, invisible in isolation and invisible in the mono fixture.
  A bound is not sufficient, because publication, breakpoint reposting and
  further module loads all run on the same thread and compound. Do not put a
  wait back.
- **Publish only while stopped** (`TDebugSession.PublishPrefetchedSymbols`,
  called from `Pump` on both sides of `ProcessOneEvent`). Registering providers
  leads to re-posting breakpoint specs, and re-posting rewrites planted INT3s.
  Doing that while the debuggee is actually executing opens an unplant/replant
  window it can run straight through — an intermittently missed breakpoint.
  Results simply queue until the next stop.
- **One repost per drain, not per module.** A drain can publish a dozen modules
  at once; reposting every spec a dozen times is pure churn on the very thread
  this feature exists to unload.
- **Enqueue last in `HandleDllLoaded`**, after the eager gate and after
  `OnDllLoadedHook`. Both are synchronous breakpoint-binding paths that must
  bind before the debuggee is resumed; claiming the module first would demote
  that hard requirement to best-effort.
- **The stop path does not enqueue.** A module needed *now* is cheaper to parse
  in-line than to hand over and wait for. Prefetch is for modules needed later.
- **No RTL synchronize queue.** Publication is drained from
  `TDebugSession.Pump`, not `TThread.Queue`: the DAP loop calls
  `CheckSynchronize` but the MCP loop does not, so a `TThread.Queue` handoff
  would pass every DAP test and never register anything under MCP.

`SYMBOL_PREFETCH=1` enables it; it is off otherwise.

## Main loop

`TDapServer.Run`:

```
while not exited do
  if launched then FDebugger.ProcessOneEvent              // 10 ms timeout
  drain MsgQueue (non-blocking) → ProcessRequest          // DAP requests
  if FDebugger.HasExited then drain remaining queue and exit
```

Each iteration handles at most one debug event followed by every
queued DAP request. The 10 ms timeout caps latency when both ends are
quiet.

### Run loop / disconnect robustness

The Run loop must terminate cleanly and never burn CPU when idle.
Three guards enforce this (`DapServer.pas`):

- **Quit on disconnect.** `HandleDisconnect` sets `FQuit := True` after
  sending its response and calling `FDebugger.Terminate`. The loop checks
  `FQuit` at the top of each iteration and after draining the queue, so it
  exits even when the target never reports exit (detached, kill-on-detach,
  or already dead). Relying on `FDebugger.HasExited` alone left orphaned
  adapters running forever.
- **No busy-spin.** `PopItem` uses a 0 ms timeout, so when there is no
  debug event to process (`FDebugger` nil / pre-launch) and the queue is
  empty, the iteration would spin a core at 100%. A `DidWork` flag tracks
  whether the iteration processed an event or a request; if not, the loop
  `Sleep(10)`s. The `ProcessOneEvent` 10 ms timeout still throttles the
  active-debugging case (so there is no added latency there).
- **No empty responses.** `ProcessRequest` ignores any message whose
  `command` is empty (logs once, sends nothing). A message with no command
  is not a DAP request; answering it with an empty success response
  (`command:""`) was the amplification vector that, fed back in a loopback
  condition, once drove a multi-million-line `dap_adapter.log` (7.3 GB,
  filled the scratch disk). Genuinely-unknown but *named* commands still
  get the success response (with the real command name) the spec expects.

`stdin` EOF (client closed the pipe) flows through `ReadMessage` → nil →
stdin thread `DoShutDown` → `PopItem` returns `wrAbandoned`, which sends a
`terminated` event, sets `FQuit`, and exits. The 256 MB per-process
`DapLog` cap (`DapProtocol.pas`) remains as a last-resort disk guard.
Covered by `Test_EmptyCommandMessage_Ignored_AdapterStaysResponsive`.

`TWin64Debugger.ProcessOneEvent`:

```
ProcessCommandQueue                                       // DAP → debugger
WaitForDebugEvent(10)                                     // OS → debugger
dispatch by event code
```

## DLL / BPL candidate detection

During `LOAD_DLL_DEBUG_EVENT` storms, the adapter must decide quickly whether
the newly loaded module can host any pending source breakpoint.

- For Delphi packages (`.bpl`), `TDllModule.ContainsSourceFile` uses the
  standard package metadata (`PACKAGEINFO` resource, `RT_RCDATA`) and parses
  the contained unit list once per module. This is the same metadata surfaced
  by RTL `System.SysUtils.GetPackageInfo`.
- Lookup key is the source basename without extension (`Foo.pas -> foo`), with
  support for namespaced units by indexing both the full unit name and the last
  segment (`Vcl.Forms` and `Forms`).
- For BPLs, `PACKAGEINFO` is authoritative: if the unit is not present (or
  package metadata cannot be read), the module is rejected immediately with no
  MAP fallback.
- Fallback (non-BPL only): MAP sidecar membership index, then TD32 source-file
  list.

`launch.json` `modules` also acts as an eager-probing allow-list: when non-empty,
non-listed modules are tracked but skipped by the startup probe.

## Breakpoints

Stored in `FBreakpoints: TList<TBreakpointRec>`. Each record carries:

- `Rva` — symbol-resolved offset, stable across runs.
- `VA` — runtime address, recomputed when `FImageBase` becomes known.
- `OrigByte` — byte saved before planting `0xCC`.
- `SourceFile`, `SourceLine` — for reporting.
- `IsOneShot`, `IsPlanted`.

Plant lifecycle:

1. DAP `setBreakpoints` arrives. `DapServer` resolves each line via
   `FDebugInfo.SourceLineToRva`, builds a `TBpSpec`, and posts it via
   `ckSetBreakpoints` (or queues to `FPendingBps` if launch hasn't
   happened yet).
2. `DoSetBreakpoints` clears existing breakpoints in the file, then for
   each line either plants `INT3` immediately (post-startup) or simply
   registers the spec (pre-startup).
3. The OS startup `EXCEPTION_BREAKPOINT` triggers
   `ApplyAllBreakpoints`, which recomputes VA from `Rva + ImageBase`
   and plants every registered persistent breakpoint.

Hit lifecycle:

1. `EXCEPTION_BREAKPOINT` at `ExceptionAddress = VA`. `RIP` is already
   `VA + 1`.
2. If `FPendingReactivateVA = VA`, the prior single-step came back —
   replant `INT3` and resume silently. (See "Persistent breakpoint
   re-arming" below.)
3. Otherwise, find the breakpoint, `RemoveInt3`, set `RIP := VA`,
   record `FStoppedTid`.
4. One-shot: delete from list. If it matched a pending step-over /
   step-out target, fire `srStep`; if `FStopAtEntry`, fire `srEntry`.
5. Persistent: set `FPendingReactivateVA := VA`, set TF, fire
   `srBreakpoint`. The next single-step landing at the same site
   replants.

## Stepping

**Per-thread targeting.** A step command carries the thread to step
(`TCommand.ThreadId`, 0 = the currently-stopped thread). The DAP `next`/`stepIn`/
`stepOut` handlers read `Args.threadId` (validated against the live thread set);
the MCP `step_*` tools read a `threadId` arg; both pass it through
`TDebugSession.Step*`. In the debug loop the step case resolves `StepTid`
(`Cmd.ThreadId` else `FStoppedTid`) and reads RIP/RSP, arms TF, and computes the
return address for THAT thread. `FreezeThreadsForStep(StepTid)` then
`SuspendThread`s every other thread before the resume, so only the stepped thread
runs (its single-step / one-shot step BP is the only trap that can fire) — the
Win32 debug API resumes all threads on `ContinueDebugEvent`, but the explicit
suspend survives it. `ReportStopped` is the single choke point that thaws them
(`ThawStepFrozenThreads`) on every stop path. Threads born mid-step are frozen
(`HandleCreateThread`); a thread that exits is dropped from the freeze set, and if
the stepped thread itself exits mid-step everything is thawed to avoid an
all-frozen deadlock. The persistent-BP re-arm carries the owning thread
(`FReactivateTid`) and both re-arm checks are gated on it, so stepping a different
thread neither steals nor drops another thread's pending re-arm. After the step,
the single-step handler sets `FStoppedTid := StepTid`, so run control keeps
targeting the stepped thread. (`ResumeTid` — the thread whose pending event is
released — stays the event thread, not `StepTid`.)

Three modes plus a none state:

- `smOver`: **range-based single-step.** Capture the current function's start
  RVA (`RvaToFunctionStart` → `FStepFuncStart`) and the start source line, then
  enable TF. On each single-step:
  - **Inside the function, not at its entry RVA** (`RvaInStepFunc` and
    `Rva <> FStepFuncStart`): a new source line is the landing → stop; otherwise
    keep single-stepping.
  - **Outside the function, or back at its entry RVA** (a recursive self-call):
    the RSP delta across the single instruction that crossed the boundary tells a
    CALL (pushed a return address → RSP decreased) from a RET (popped → RSP
    increased). On a call, plant a one-shot resume BP at `[RSP]` (the return into
    the function) and run full-speed; when it fires, resume single-stepping. On a
    return, the step completed in the caller → stop.

  The per-step decision lives in one place (`HandleSmOverStep`), called from the
  single-step handler **and** from the persistent-BP re-arm path. The latter
  matters: when the step starts on a line that carries a user BP, the re-arm
  consumes the step that executed the line's `call` and lands at the callee
  **entry** — `HandleSmOverStep` must evaluate there (where `[RSP]` is still the
  return address); one more blind step would be past the callee's prologue push
  and read a corrupted `[RSP]`, planting the resume BP on a stack address and
  running free. When a resume BP fires, the return address is re-checked for a
  new line first: a line that is a single parameterless call (`Foo;`) returns
  straight onto the next line's `call`, and stepping that instruction blindly
  would step over it too, chaining through the whole block.

  Membership is decided by RVA range, **not** by RSP magnitude, so stepping from
  a function's `begin` (entry RSP, before the prologue allocates the frame) works
  — the earlier RSP-recursion-guard approach treated every post-prologue
  same-frame line as a deeper recursive frame, skipped them all, and ran free out
  of the function (the debugger appeared to freeze). Following the actual taken
  branch also means a not-taken `if cond then raise` can no longer let execution
  run away.

  **Raise during step-over:** a `raise` does not return to the call's return
  address — it unwinds into this function's `except`/`finally` handler. When a
  genuine unwinding exception (Delphi raise / access violation) passes through
  while a run-to-return is in flight, `PlantInFuncStepBps` arms one-shot BPs on
  every line of the stepped function (binary-search to `FStepFuncStart` in the
  sorted line RVAs, then a windowed forward scan — cost is the function's own line
  count, never the whole program) so the step lands on the handler. Armed once per
  step, only for real unwinds, never for first-chance noise.

  `FStepBpVAs` tracks the transient one-shot BPs (resume + raise-catch);
  `ClearStepBps` drops them on the landing, on a user BP that pre-empts the step,
  or on an exception. The `FPendingReactivateVA` re-arm path re-enables TF for
  `smOver` as well as `smInto` — otherwise stepping off a line that carried a
  persistent BP would consume the trap-step and run free. Fallback when the
  function range is unavailable (import thunk, publics not yet parsed): the
  caller's return address, else `smInto` single-step.
- `smInto`: enable TF, walk single-step events until the source
  location changes or a 10000-step safety cap fires. The "from"
  source location is captured before the first step.

  **Entry-preamble skip.** A callee's ENTRY address already maps to a source
  line, so the "new source line" test is satisfied by the callee's very first
  instruction — before its prologue has established the frame and before the
  register arguments (RCX/RDX/R8/R9, XMM0..3) have been spilled to their home
  slots. Reported there, `Self` and every by-register parameter are read out of
  the CALLER's frame: plausible values, correct-looking types, no warning. So
  when a would-be landing is still inside the entry preamble, the step runs on to
  `FunctionBodyStartVA` instead — a one-shot BP + full-speed resume, reported as
  a step by the existing run-to-`FStepOverVA` path (single-stepping would dive
  into the sourceless RTL helpers a preamble may call). Breakpoints were never
  affected: they bind to the line-table address of the statement, which is
  exactly the address this computes.

  `FunctionBodyStartVA` derives the boundary from the binary, never from
  instruction guessing: `.pdata`/`UNWIND_INFO` gives the function's exact extent
  and `SizeOfProlog`, and the line table gives the real boundary — the first
  address inside the function whose line record differs from the ENTRY's record.
  `SizeOfProlog` alone is **not** enough: it covers only the unwind-relevant
  frame setup (`push rbp; push regs; sub rsp,N; mov rbp,rsp`), while Delphi's
  `mov [rbp+home],rcx` argument spills come after it and are attributed to the
  routine's `begin` line. When no differing record exists (a routine written
  entirely on one line) the prologue end is used, which for a leaf/frameless
  routine (`SizeOfProlog` 0, as for a chained `UNWIND_INFO`) is the entry itself —
  so a routine with no prologue still stops at its first instruction. No unwind
  info, unreadable memory or an unknown `UNWIND_INFO` version all yield 0 and the
  step falls back to the previous behaviour.
- `smOut`: call `CallerReturnAddress` (`StackWalk64` consumed once for
  the current frame, then once for the caller; the second
  `AddrPC.Offset` is the resume RIP). The result is accepted only if
  `IsPlausibleReturnAddress` holds (executable, inside a module dbghelp
  knows) — without unwind info `StackWalk64` returns whatever `[RSP]`
  held, and planting an INT3 on that would patch unrelated data. Plant a
  one-shot INT3 there. Reading `[RSP]` directly is **not** correct — only
  at function entry, before the prologue moves RSP.

  Fallback when no caller can be found: `smInto` single-step, but with
  `FStepFromLoc` seeded and `FStepMinSP` set to the current RSP. The
  single-step stop is accepted only at a strictly HIGHER RSP, i.e. once
  the frame really was left. Without both, the first trap satisfied the
  new-line test a few bytes into the same function and a failed step-out
  reported success.

## Stack walking

Uses `StackWalk64` with `IMAGE_FILE_MACHINE_AMD64` and `dbghelp.dll`'s
`SymFunctionTableAccess64` / `SymGetModuleBase64`. `SymInitialize` is
invoked lazily (`EnsureSymInitialized`) with `fInvadeProcess = True`,
which enumerates only the modules mapped **at that instant** — including
the main exe, which never produces a `LOAD_DLL` event.

Every module mapped later is registered explicitly:
`HandleLoadDll` → `RegisterModuleWithDbgHelp` (`SymLoadModuleExW`), and
`HandleUnloadDll` → `SymUnloadModule64`. This is required, not optional:
without it a runtime-loaded BPL has no dbghelp entry,
`SymFunctionTableAccess64` returns nil for every address inside it, and
`StackWalk64` silently degrades to the AMD64 leaf convention
(`return address := [RSP]`). Just past a Delphi prologue RSP equals RBP,
so `[RSP]` is an uninitialised local and the walk stops after one frame.
The symptom depended purely on when the first stack walk happened: a
client that walked the stack at the entry stop (VS Code does) froze the
module list before any package existed.

The frame walk reports source/file via `FDebugInfo.RvaToSourceLine` and
function names via `RvaToFunctionName`, both stopping at 30 frames.

`GetStackFrames` caches its result keyed by the walked thread's TID and its
SEED `RIP+RSP`, and by `TDebugInfoSet.Revision`. The seed values must be
captured before the walk: `StackWalk64` mutates the `TContext` it is given
into each unwound frame's register state, so writing the key from `Ctx`
after the loop stored the LAST frame's registers under a key compared
against the live seed — a healthy walk never matched it.
VS Code issues `stackTrace` twice per stop and `scopes`/`evaluate` also need the
frames; without the cache each call re-walks the whole stack. The key
auto-invalidates (any step/goto/continue changes RIP or RSP); RSP is part of the
key so a recursive function stopping at the same RIP at different depths is not
served stale frames. The revision part invalidates cached unresolved frames when
new module providers (TD32/MAP/RSM/DCP) are loaded after a stop.

While `TDebugInfoSet.AnyBackgroundIndexingPending` is True the cache is neither
served nor stored. A walk made against an index that is still building yields
names that are missing only because the answer was not ready yet; caching it
pinned that outcome for the entire stop, so every later `stackTrace` in the same
stop replayed the same blank frames and the client could not retry short of
resuming. Re-walking during that bounded window costs a repeated `StackWalk64`,
never blocks, and stops as soon as the indexes are ready — the first complete
result is the one that gets pinned.

## Frame symbol attribution

Every `TSessionFrame` carries `ModuleName` and
`Symbols: TSymbolAvailability` (`DebugInfoTypes.pas`:
`saUnknownModule` / `saNoSymbols` / `saIndexing` / `saLoaded`), filled in
`TDebugSession.FrameToSession` from `TModuleSymbolLoader.DescribeAddress`.
`DescribeAddress` covers the main exe (matched against `IDebugTarget.ImageBase`
plus the PE `SizeOfImage`, since the exe is deliberately absent from the runtime
module registry) as well as every registered DLL/BPL, and is purely descriptive —
it never triggers a symbol load, so it is safe to call while rendering a stack.

This exists because a frame the providers cannot name used to render identically
in three different situations: an address in no known module, a module built
without debug info, and a module whose index is still building. The DAP frontend
emits `moduleId` and names such a frame `0x… (module: reason)`; the MCP frontend
emits `module` plus a `symbols` field on every frame.

## Local variable readout

`GetLocalValues`:

1. Read `RIP`, look up the enclosing function name and entry RVA.
2. `CollectLocalsForFrame` — for each `TLocalSymbol`, compute
   `Address = RBP + ((RbpOffset div 2) + FrameSize)`, read 8 bytes,
   and for `lkVarParam` follow the pointer to also read the
   dereferenced value.
3. Walk the lexical-scope chain via
   `IFunctionNameProvider.GetEnclosingProcedure`. Each parent's RBP is
   recovered from the hidden parent-frame pointer at
   `ChildRBP + ChildFrameSize + 0x10` (Win64 home slot for RCX).
   Locals from each parent are surfaced with a `parent.` prefix; cap
   at depth 32.

`FrameSize` is read by disassembling the prologue:
- `55 48 83 EC NN`               → `NN` (frame < 128)
- `55 48 81 EC NN NN NN NN`      → `imm32`

### Cross-unit local disambiguation

`TDebugInfoSet.GetLocalsForFunctionByRva` prefers each provider's RVA-keyed
lookup (TD32). On a miss it falls back to the name-keyed lookup, which is
ambiguous when a proc name is declared in more than one unit of a binary:
RSM's `FProcOffsets` is last-wins, so it can surface the wrong unit's locals.

The miss-path resolves the frame's source unit (`RvaToSourceLine` →
basename) and, for any provider implementing `IUnitScopedLocalProvider`,
tries `GetLocalsForFunctionInUnit(name, unit)` first. `TRsmFile` implements
it by scanning only that unit's RSM section (located via the unit anchors —
no RVA index required) for a matching proc header. This is gated by
`NameCollidesAcrossUnits`, an O(1) check after a one-time lazy scan
(`EnsureCollisionSet`, reads the mapped file so it works on the sidecar
fast path), so names that do not collide pay nothing and the prior perf
regression cannot recur. The unit-scoped result is used only when it
returns locals; otherwise the existing by-name path runs unchanged, so the
fallback is never worse. Covered by
`UnitScopedLocals_PicksRightUnitForCollidingProc`.

### Cross-unit / cross-binary global disambiguation

`TDebugInfoSet.FindGlobalForRva(Rva, Name)` resolves a global the way Delphi
scope rules would at the current stop, in three tiers:

1. **Cross-unit, same binary (Layer 1).** `UnitNameForRva(Rva)` gives the
   frame's source unit. For the provider whose RVA range contains `Rva` (the
   frame's owning binary), `TryUnitScopedGlobal` asks any
   `IUnitScopedGlobalProvider` (TD32) for the copy declared in that unit,
   gated by the O(1) `GlobalNameCollidesAcrossUnits` check so non-colliding
   names cost nothing. TD32 attributes each per-module GDATA32/LDATA32 global
   to its unit via `FModIndexUnit` (built in `ParseSourceModule`). Covered by
   `TD32ReaderTests.Globals_UnitScoped_DisambiguatesCollidingGlobal` +
   `Test_CrossUnitGlobal_Unit1/2_PicksOwnType`.
2. **Cross-binary collision (Layer 2).** Globals are registered per binary via
   `AddProviderForModule` into `FRangedGlobals` (provider + `[Lo, Hi)` RVA
   range). `FindGlobalForRva` queries the provider whose range contains `Rva`
   — the frame's OWNING binary — and returns its `FindGlobal` hit BEFORE the
   flat fallback. So when the same global name is declared in several loaded
   binaries (exe + BPLs), the in-scope binary's copy wins regardless of load
   order. Covered by `Test_Bpl_CrossBinaryGlobalCollision_PicksOwnBinary`
   (GCrossBinAmbiguous = Integer in TestPackage, Double in TestPackage2; at a
   TestPackage2 frame it resolves to Double, never TestPackage's Integer).
   The unique-name cross-BPL case (watch a BPL global from another frame) is
   covered by `Test_Bpl_UniqueGlobal_ResolvesFromExeFrame`.
3. **Uses-graph (`TryRequiresClosureGlobal`).** When the global is not in the
   frame's own binary, the binaries it `requires` (transitively) are queried
   before the flat fallback, so a required package's global beats an unrelated
   module's same-named one — in particular the always-loaded main exe, which
   would otherwise shadow every package global by load order. The requires
   graph comes from each BPL's `PACKAGEINFO` (`TDllModule.RequiredPackages`),
   threaded into the ranged-global providers via `AddProviderForModule`
   (`ModuleName` + `Requires`). Because symbol providers load lazily (a package
   the debuggee never stopped in has none registered), `DapServer` warms the
   frame-binary's requires-closure on identifier watches in a package frame
   (`WarmupRequiresClosureForPC`) so the required package's global is available.
   Covered by `Test_Bpl_UsesGraphGlobal_PrefersRequiredPackage` (GUsesGraph =
   333 in the required TestPackage, 444 in the unrelated host; at a TestPackage2
   frame it resolves to 333).
4. **Flat fallback.** `FindGlobal` across all providers, first hit. Reached
   only when the frame's binary and its requires-closure do not declare the name.

Remaining finer point (not a correctness gap today): when two different
required packages both declare the name, tier 3 returns the first in requires
order, not the frame source-unit's exact uses last-wins. Tracked in
`KNOWN_UNKNOWNS.md`.

### Per-unit `uses` scoping of watch identifiers

When the user types an UNQUALIFIED name in a watch/hover, it must resolve the
way the Delphi compiler would at the current source unit: the frame's own unit
shadows everything it `uses`; among the units it uses, last-wins on a collision.
The same SAME-NAME-in-many-units problem the globals tiers solve for data also
applies to functions, classes/types, class methods, and constants. The uses
graph is the RSM `63 35` clusters (`IUnitUsesProvider.GetUnitUses`; the compiler
already resolved each cluster to the owning unit + its dependency set).

Resolution is keyed on the frame's source unit (`UnitNameForRva`) plus that
graph, with a flat first-hit fallback so non-colliding names are unaffected:

- **Free functions / qualified `Class.Method`** — `TWinDebugger.TryResolveSymbolVA`
  routes through `TDebugInfoSet.NameToRvaScoped`. Per-unit proc/method
  attribution is `IUnitScopedFuncProvider.FindFuncRvaInUnit` (TD32 `FUnitProcs`,
  keyed `unit|name` incl. `unit|class.method`, built from the proc record's
  owning `ModIndex`).
- **Class reference / class methods** — `TFoo.ClassMethod` in a watch resolves
  the class to the in-scope unit's VMT. The Delphi MAP emits a class VMT as the
  public `Unit..Class` (double dot), so `TryResolveClassVmtScoped` picks the
  frame-visible unit's `Unit..ClassName` for the `Self`/`TClass` argument, while
  the method symbol is scoped as above. ExprEval treats a bare class name
  followed by `.` as a type reference (`TExprValue.IsTypeRef`) and invokes the
  class function via `ApplyMethodCall(..., ClassRefSelf, ForceClassMethod)`.
- **Constants** — untyped ordinal consts (`const X = 1`) are compile-time
  inlined: no storage, no public symbol. The value comes from the RSM `$25`
  records (`IUnitScopedConstProvider`, `EnsureUnitConstsParsed`), attributed to
  the unit whose `63 35` cluster opened the surrounding block.
  `TryResolveConstScoped` applies the same own-unit-shadows / uses-last-wins /
  flat-fallback policy; ExprEval resolves it as the last `ResolveIdent` tier.

Covered by `Test_UsesScope_Type/ClassMethod/Const_PicksUsedUnit` (host unit uses
A,B — not C — so type/function/class-method/const each resolve to unit B's copy:
`SizeOf(TDupRec)`=8, `DupFunc`=2, `TDup.Tag`=2, `DupConst`=2).

## Variables / scopes (DAP side)

Two scopes returned by `scopes`:

- `Locals` — `LOCALS_VAR_REF = 1000`. Backed by `GetLocalValues`.
- `Registers` — `REGISTERS_VAR_REF = 1001`. Backed by `GetRegisters`.

`variables` for a scope formats each value via `FormatLocalValue` /
`FormatLocalType`, type-aware: integers, floats, `TDateTime`, chars,
ANSI/Unicode/RawByte/UTF8 strings, `Variant` (16-byte `TVarData`),
C-string pointers (`PChar`/`PAnsiChar`), Delphi aliases (`Real`,
`Extended` → Double, etc.).

The variant decode is wrapped in `{$Q-}{$R-}` because raw-bit casts like
`Int32(Raw and $FFFFFFFF)` would trip overflow checks under `{$Q+}`.

### Class / record member grouping

Expanding a class or record whose type exposes **properties** splits the
children into synthetic group rows (`presentationHint.kind = "virtual"`):

- `properties` (first) — `ekRsmProps`. Regular (non event-handler) properties.
  The consumer of a class usually cares about the exposed interface, so
  properties lead.
- `event handlers` — `ekRsmEvents`. Properties whose type is a method pointer
  (`procedure(...) of object`, e.g. `TNotifyEvent` / `OnClick`). `IsEventHandlerProp`
  detects them via `TypeKind = tkMethod` or the `procedure of object` label.
  Only emitted when at least one such property exists.
- `fields` — `ekRsmMembers` with `NoGroup = True`. Lists the backing fields
  flat; keeps `setVariable` working (it resolves a field by name through this
  ref).

Types **without** properties keep the flat field list (no pointless single
`fields` wrapper). The split happens at expand time in `AppendRttiVariables`
(`ekRsmMembers`, `NoGroup = False`) once the member table is known.

Property value resolution (`AppendRsmProperties`):

- **indexed (array) property** (`property P[Index]: T`): a leaf, never
  auto-evaluated. Its getter needs an index argument and there is no general way
  to enumerate the valid indices — the index type is arbitrary (Integer, string,
  anything), there is no standard count property, and no guaranteed 0/1 base.
  Shown as value `(indexed property)`, type `T [indexed]`, `variablesReference`
  0. The user can still read a specific element with an explicit watch
  (`Obj.P[i]`, handled by the evaluator's indexed-accessor path). Detected in
  TD32: the property descriptor record carries a non-zero index-args type at
  offset +6 (a plain scalar property — field- or getter-backed — leaves it zero);
  surfaced as `TClassMember.IsIndexed`.
- **field-backed** (`read FX`, resolved via `PropertyBackingFieldOffset` — getter
  hash → sibling field, or the TD32 `FieldOffset`): read inline like a field,
  labelled with the property name/type.
- **getter-backed** (`read GetX`): deferred. The row is an `ekPropertyGetter`
  node with a placeholder value; the getter runs in the target **only when the
  user expands the row** (`AppendPropertyGetterChildren` re-evaluates the
  property expression via `TExprEvaluator`, top frame). A scalar result becomes
  a single `(value)` leaf; a class/record result expands into its own grouped
  members. Writing properties is not supported (use the `fields` group).
  The getter call needs the method's address: `ResolveRsmMethodProp` asks
  `TryResolveSymbolVA(ClassName + '.' + Method)`. The MAP qualifies methods
  with the unit but **without** the dotted namespace
  (`Forms.TApplication.GetMainFormHandle`), so `NameToRva` matches the
  `Class.Method` pair via a last-two-segments index (ignoring the unit prefix,
  and precisely — the bare last segment collides across classes, e.g.
  `TcxControlHintHelper.GetHintControl`).

## Evaluate / watch

`evaluate` accepts:
- bare identifiers: register, local (own or parent via short-name
  lookup), then global by `NameToRva`.
- `@identifier` → address of.
- `[expr]` → read 8 bytes at the resolved address.
- numeric literals (`0x…`, `$…`, decimal).

`evaluateForHovers` is advertised so VS Code uses the same path for
hover data tips.

### Bare-identifier resolution order (`ExprEval.ResolveIdent`)

A bare name is resolved in this order, matching Delphi scope rules:

1. CPU register (`rax`, `rbp`, …).
2. Local (own frame, then parent frames by short name).
3. `Self.<name>` when stopped inside a method.
4. **Parameterless free-function call** — a bare function name in Delphi *is*
   a call (`Now` ≡ `Now()`), so `ApplyMethodCall` is tried before the data
   global lookup.
5. Data global / public symbol (`EvaluateGlobalName` → `NameToRva`).
6. Named constant (`$25` RSM records), then enum literal, then type name.

**Data-global-not-callable guard.** Step 4 resolves the name via
`TryResolveSymbolVA` → `NameToRva`, which indexes data globals as well as
procedures (a global's storage address is looked up the same way a proc's
entry is). Without a guard, a watch on a unit `var` (e.g. SampleApp's `Globals`,
which lives cross-binary in `libSharedFormsD29.bpl` at RVA `$6F198`) resolves to
the variable's **data address** and `RunMethodCall` then executes the
variable's bytes as x64 code — returning garbage in RAX (a different value, and
a different runtime-VMT-guessed type, on every step) or faulting
(`RunMethodCall: ABORT 0xC0000005`). `ApplyMethodCall` now refuses the
free-proc call when `IDebugTarget.AddressIsExecutable(FuncVA)` is false (the
target is not on a committed `PAGE_EXECUTE*` page), so resolution falls through
to step 5 and the global is *read* instead of *called*. Methods (step 3 paths)
are unaffected. `AddressIsExecutable` is a single `VirtualQueryEx`, paid only
on the free-proc path of an otherwise-unresolved bare name.

> Why the global was unresolved on SampleApp in the first place: the main
> `SampleApp.exe` is a with-runtime-packages build; its embedded TD32 covers only
> ~33 statically-linked units. `GlobalsU` is not one — it is contained in
> `libSharedFormsD29.bpl`, so `Globals` is absent from the exe's symbols and is
> resolved cross-binary from the package's TD32 (diagnose unit coverage with
> `TTD32FileReader.DiagFindSymbolRecords`).

### Negative-result index for unresolved identifier watches

VS Code re-evaluates every WATCH entry (and every hovered identifier) on
*every* stop. On a large multi-module target an UNRESOLVED bare identifier
used to cost seconds each, repeated per watch per step — the dominant
step-over latency (measured ~6.2 s/miss on SampleApp, ~13 s wall per F10 with
two failing watches). Two layered causes, both fixed:

- `TWinDebugger.EvaluateGlobalName` ran a blind 5 s `Sleep`-retry loop on
  each miss (added to let MAP publics finish background indexing after a
  module warm-up). It now consults `FGlobalMissCache` (lcase name →
  `TDebugInfoSet.Revision` at which the name was confirmed absent) and
  returns immediately on a repeat miss. The miss is recorded only AFTER the
  full retry window elapses, so a symbol that resolves once indexing
  finishes is never cached as missing prematurely.
  The *first* miss of a name no longer blind-sleeps the whole 5 s either: the
  retry exits the instant no provider is still building its index
  (`TDebugInfoSet.AnyBackgroundIndexingPending`, aggregating the optional
  `IBackgroundIndexProvider` — only `TMapFile` implements it, returning
  `not FPubsReady`). So a genuinely-absent name at a *warm* stop (every
  publics table already parsed — the common case) returns in one `NameToRva`
  pass instead of ~5 s; the 5 s cap only bounds the wait while a MAP publics
  parse is actually in flight. NB: `IBackgroundIndexProvider` must keep a
  GUID distinct from every other provider interface — a duplicate makes
  `Supports` hand back the wrong vtable and the aggregator calls a
  mismatched method (a `...0009` clash with `IUnitScopedConstProvider` made
  `AnyBackgroundIndexingPending` invoke `FindConstInUnit` with garbage
  out-params → AV).
- `TDapServer.HandleEvaluate` keeps an `FEvalMissCache` (key
  `lcase(name)|funcEntryVA|revision` → the `<name: not found>` string). A
  bare single identifier that fully misses ExprEval's whole resolution
  chain (global + enum-literal + constant tiers) is served from this O(1)
  index on the next identical watch instead of re-scanning the symbol
  tables. Only bare identifiers are cached (compound expressions can have
  side effects or frame-sensitive values); only confirmed misses
  (`not Val.IsValid`) are stored, so a resolvable name is never suppressed.
- `WarmupSymbolProvidersForEvaluate` (the lazy module symbol warm-up on a
  failed evaluate) is gated on the provider revision: it iterates the DLL
  module list at most once per revision instead of on every miss.

All three keys are the provider revision, so a module load (which bumps
`Revision` via `AddProviderForModule`) transparently invalidates the caches
and a newly-loadable symbol is retried. Net: repeated unresolved watches
drop from ~6.2 s to ~0.03 s; per-step wall on the SampleApp repro from ~13 s
to ~0.7 s (the residual is the genuine work of the *resolving* watch plus
the locals readout, not lookup).

## setVariable

Backed by `EncodeValueForType` for primitives, dates, floats, chars,
booleans, sized integers. Strings hand off to
`TWin64Debugger.SetStringVariable`, which:

1. Allocates an immortal Delphi string buffer (RefCnt = -1) in the
   debuggee via `VirtualAllocEx` and `WriteProcessMemory`.
2. Resolves `@UStrAsg` (UnicodeString family) or `@LStrAsg` (AnsiString
   family) via the debug info.
3. Hijacks the stopped thread to invoke that helper through
   `RunRemoteCall`.

Var/reference parameters: write through the dereferenced address
(`V.RawValue`) so the caller's variable is modified rather than the
parameter slot.

## Synthetic remote call

`RunRemoteCall(FuncVA, ArgRcx, ArgRdx)`:

1. Lazy-allocate a single-byte `0xCC` trap page (`FRemoteCallTrap`).
2. Save full thread context.
3. Build a Win64 ABI call frame:
   - `RSP := (saved.RSP and not 15) - 40` — 16-byte aligned + 32 bytes
     shadow space + 8 bytes return address. RSP at callee entry must
     be `8 mod 16`.
   - Write the trap address at `[RSP]` so the callee's `RET` jumps to
     our trap.
   - `RIP := FuncVA`, `RCX := ArgRcx`, `RDX := ArgRdx`.
   - Clear TF in `EFlags` — inheriting it from a breakpoint handler
     causes a single-step exception per instruction inside the helper
     and hangs the pump loop.
4. `ContinueDebugEvent`, then pump `WaitForDebugEvent(100ms)` until a
   breakpoint fires at the trap on our thread. Unrelated events are
   passed through with `DBG_CONTINUE`.
5. Restore the saved context.

This path is used today for `@UStrAsg`/`@LStrAsg`. Any future feature
that wants to run debuggee code (remote `Format`, custom getters, etc.)
should reuse it.

### Cancellation + watchdog (a hung call must never freeze the adapter)

The injected call runs on the debuggee's stopped THREAD, driven by the single
debug-loop thread; you cannot kill it as an adapter worker. If the call never
returns to the trap (a getter that blocks on a wait, spins, or pumps a message
loop), an `INFINITE` wait would hang the whole adapter -- and because request
dispatch is single-threaded (`Run` drains one `ProcessRequest` at a time), every
later request, **step-over included**, queues behind it. The stdin reader thread
keeps reading but nothing drains.

So the pump is cancellable:

- It waits with a 100 ms slice, not `INFINITE`.
- `FInRemoteCall`/`FAbortRemoteCall` are atomics. While a call is in flight the
  **stdin thread** (`TDapServer.Run`) sets `FAbortRemoteCall` the instant it
  reads a control command (`next`/`stepIn`/`stepOut`/`continue`/`pause`/
  `disconnect`/`terminate`) -- the user pressing step-over IS the cancel signal.
- On an abort request, or an 8 s watchdog deadline, the pump `SuspendThread`s the
  call thread, sets its `RIP := FRemoteCallTrap`, and `ResumeThread`s it. The
  forced INT3 surfaces as the trap event, so the existing completion path runs
  (restore `SavedCtx`) but returns `False` -- the watch shows the call failed
  rather than a garbage value. A 2 s secondary deadline guards the forced-trap
  window; if even that doesn't surface, the pump restores `SavedCtx` and bails.
  `RemoteCallInFlight`/`RequestAbortRemoteCall` expose this on `IDebugTarget`.

NB this is the safety net for the GENERAL case (a genuinely slow/blocking
getter). The common trigger -- a speculative bare-identifier "call" of a unit
name / type / procedure -- is refused upstream (see "Bare-identifier resolution
order": a speculative free call needs a bindable return type), so it never
reaches the pump.

## Persistent breakpoint re-arming

The single-step dance is necessary because we can't both leave `0xCC`
in place and execute the original instruction. Sequence:

1. INT3 hits → `RemoveInt3`, set `RIP := VA`, fire `srBreakpoint`,
   record `FPendingReactivateVA := VA`, set TF.
2. User issues continue → `ContinueDebugEvent`, the original byte
   executes one step, single-step exception fires.
3. In `EXCEPTION_SINGLE_STEP`, see `FPendingReactivateVA <> 0`,
   replant `INT3`, clear pending, resume.

When the user requested `stepInto` while a reactivation is pending,
the rearm consumes the trap step, so we re-enable TF before resuming
so the actual step still fires.

## Exception handling

- `EXCEPTION_BREAKPOINT` other than the OS startup break and our trap:
  treated as a missed BP and passed through with
  `DBG_EXCEPTION_NOT_HANDLED`.
- First-chance access violations (`0xC0000005`) and Delphi-raised
  language exceptions (`0x0EEDFADE`): always reported as `srException`
  with `DBG_EXCEPTION_NOT_HANDLED` so the program's `try..except` still
  has a shot.
- Other first-chance exceptions: silently passed through.
- Second-chance: always reported.

Which classes surface is governed by the `setExceptionBreakpoints` filters
(`delphi` / `av` / `all` / `unhandled`). VS Code sends the enabled ids two
ways: the legacy `filters: [string]` array, and — once any filter advertises
`supportsCondition` (the `delphi` filter does) — the richer
`filterOptions: [{ filterId, condition? }]` form, leaving `filters` EMPTY.
`HandleSetExceptionBreakpoints` reads BOTH, and inside `filterOptions` accepts
the spec key `filterId` (preferred) and the legacy `filter` key. Reading only
`filter` made every first-chance filter a no-op under real VS Code (only the
forced `unhandled` stayed on); the test client masked it by populating
`filters` and using `filter`. Regression: `Test_ExceptionFilter_ClassMatch_Stops`
now drives the real shape (empty `filters`, ids under `filterOptions.filterId`).

### Thread-name announcements (`0x406D1388`)

`MS_VC_EXCEPTION` is not a program error: it is a message addressed to the
debugger. A thread raises it to declare its own name — Delphi does so from
`TThread.NameThreadForDebugging`, guarded by `IsDebuggerPresent`.

`HandleException` has a dedicated `case` branch for it, placed **before** the
filter/rule machinery, so it can never surface as a stop: not with the `all`
first-chance filter on, and not via any user rule. `CaptureAnnouncedThreadName`
decodes it and the event is resumed with `DBG_CONTINUE` (which dismisses the
exception, exactly what `RaiseException`'s caller expects). The
`RunMethodCall` event pump consumes it too, since the main dispatch never sees
events raised during an injected call.

Decoding: `RaiseException` copies the raiser's `THREADNAME_INFO` verbatim into
`ExceptionInformation`, so the `ULONG_PTR` words *are* the structure —
`[0]` = `dwType` (must be `$1000`), `[1]` = `szName` (a `PAnsiChar` in the
**debuggee's** address space), `[2]` = `dwThreadID` in its low dword. On Win64
`dwFlags` shares `[2]`'s high dword (padding puts `szName` at offset 8); a
WOW64 raiser sends the same first three words zero-extended from its
4-byte-pointer struct, with `dwFlags` in `[3]` — so one decoding covers both
bitnesses. A producer that passes a *pointer to* the structure in `[1]` is
handled by a fallback that validates `dwType` before trusting anything.

The string is read cross-process by `ReadRemoteAnsiString`: chunked reads that
never cross a page boundary (`ReadProcessMemory` fails the whole request if any
byte is unmapped, which would lose a name sitting near the end of a mapped
page), scan stopping at the first control byte, hard cap of 255 chars, and an
unreadable pointer simply yields no name.

`dwThreadID` of `-1` means "the calling thread"; any other value is honoured
only when it names a thread already in `FThreads`, so a stray word can never
relabel an unrelated thread. Otherwise the event's own `dwThreadId` is used.

Names land in `FThreadNames` (id -> name) and are dropped on
`EXIT_THREAD_DEBUG_EVENT`, because the OS recycles thread ids.
`GetThreadName` prefers an announced name, then `GetThreadDescription` (the
Win10 1607+ API, only populated if the program called `SetThreadDescription`),
then the `Thread <id>` fallback. The lookup happens per request, so a name
announced long after the thread was created is reflected by the next `threads`
request. Covered by `Test_Threads_NameThreadForDebugging_SurfacesLive`
(unnamed at the first stop, named at the second) and
`Test_Threads_NameAnnouncement_NeverStops_WithAllFilter`.

### Class name and message on a stop

On an exception stop the adapter reports both the raised class and the message:

- **Class** — `ReadDelphiExceptionClass` reads the exception object (pointer in
  `ExceptionInformation[1]`, falling back to `[0]` on pre-Athens RTL), follows
  the VMT to TypeInfo (`VMT+(-168)`), and decodes the ShortString class name.
- **Message** — `ReadDelphiExceptionMessage` reads `Exception.FMessage`, the
  first field after the VMT pointer, so at offset 8 on Win64. It is a
  UnicodeString: pointer to the chars, element count at `[data-4]`.
- **Access violations** (`0xC0000005`, no Delphi object yet) get a synthesised
  message from the exception record: `Access violation at $RIP reading/writing
  address $fault` (`ExceptionInformation[0]` = 0 read / 1 write, `[1]` = fault
  address).

`TWinDebugger` exposes `LastExceptionClass`, `LastExceptionMessage`, and the
combined `LastExceptionDesc` (`"Class: Message"`). The `stopped` event carries
the combined form in both `description` and `text`. The adapter also advertises
`supportsExceptionInfoRequest` and answers `exceptionInfo` with
`exceptionId` = class, `description` = message, `breakMode` = `always`, and
`details` = `{ typeName, message }`, so VS Code fills the exception details
panel. Covered by `Test_ExceptionStop_DescriptionHasClassAndMessage` and
`Test_ExceptionInfo_ReportsClassAndMessage` (target raises
`Exception.Create('exc-test')`).

### Per-exception rule engine

`ExceptionRules.pas` is a pure matcher (no process state, independently
unit-tested in `ExceptionRulesTests`): an ordered `TArray<TExceptionRule>` plus
a decoded exception (class chain, message, raise-site unit/line) → first-match-wins
`TExceptionAction` (`eaIgnore` / `eaLog` / `eaLogStack` / `eaBreak`). A rule's
criteria (`ClassNames` any-of exact on the runtime/leaf class, `ClassIsNames`
any-of against the runtime class OR any ancestor, `Codes` any-of on the Win32
exception code, `MessageSub` substring,
`MessageRegex`, `UnitName`, `MatchUnknownUnit`, `LineFrom`/`LineTo`) are AND-ed;
an unset criterion is a wildcard. The matcher takes the class **chain** (runtime
class at index 0, then ancestors); `class` checks index 0 only, `classIs` checks
the whole chain. `TWinDebugger.ReadDelphiExceptionClassChain` builds it by walking
the RTTI `ParentInfo` links (each tkClass `TypeInfo` is Kind + ShortString name +
`TTypeData`, whose `ParentInfo` sits at TypeData + pointer size; `TObject`'s is
nil). A non-Delphi exception (access violation) has no object, so its chain is the
single synthetic class name. `RulesNeedRaiseSite` lets the caller skip the stack
walk when no rule references unit/line.

`code` is the only criterion that can target a NATIVE exception (raised through
`RaiseException`, e.g. `0xE06D7363` from a C++ DLL): those carry no exception
object, so class and message do not exist for them. `0x406D1388` is the one
native code rules cannot see -- it is consumed as thread-name protocol traffic
before the rule engine runs (see "Thread-name announcements"). The
matcher takes the raw `ExceptionCode` alongside the decoded fields; the overloads
without it pass `NO_EXCEPTION_CODE` (0), which never satisfies a `code` rule.
`ParseExceptionCode` accepts `0x…`, `$…`, decimal and signed decimal.

`DapServer.ParseExceptionRules` builds the table from the launch.json
`exceptionRules` array (`class`/`classIs` string|array, `code` string|number|
array, `message`, `messageRegex`, `unit`
with the `*unknown*` token, `line`/`lineFrom`/`lineTo`, mandatory `action`) and
hands it to the debugger via `IDebugTarget.SetExceptionRules` in both the launch
and attach paths.

`BuildAllExceptionRules` combines the per-project rules with a shared,
machine-wide file: project rules first, then `LoadGlobalExceptionRules` (default
`%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json` via
`DefaultGlobalExceptionRulesPath`, an object with an `exceptionRules` array or a
bare array). So a project overrides the shared baseline, which overrides the
filters. Toggled by launch args `useGlobalExceptionRules` (default true) and
`globalExceptionRulesPath`. The integration test client passes
`useGlobalExceptionRules:false` so the dev machine's real file can't perturb the
suite; `Test_GlobalExceptionRules_FileApplied` exercises the loader against a
temp file via `globalExceptionRulesPath`.

`ApplyExceptionRules` (called at launch/attach) captures the session's
`FProjectExceptionRules`, `FUseGlobalRules`, `FGlobalRulesPath` and the shared
file's `FGlobalRulesMTime`. The continue / step handlers call
`ReloadGlobalRulesIfChanged` before posting the resume command: when the shared
file's mtime changed it reloads only the shared rules, re-combines them with the
fixed project rules, pushes the table via `SetExceptionRules`, and logs to the
console. This hot-reload lets a user edit the shared file while stopped and have
it take effect on resume without restarting. Covered by
`Test_GlobalExceptionRules_HotReloadOnResume` (the re-raise flow: first event
breaks, the file is edited to ignore, the re-raise is suppressed on resume).

In `HandleException` the class/message/description are decoded unconditionally;
the filter selection yields a fallback `eaBreak`/`eaIgnore`; then if any rules
exist, a match overrides the action. The raise site (`RaiseSiteLocation`) is the
first stack frame with known source — for a Delphi `raise` the exception address
is in the RTL, so frame 0 is sourceless and the walk finds the user frame; for an
AV frame 0 is the faulting line. `eaBreak` keeps the existing stop path
(`ReportStopped` + pending `DBG_EXCEPTION_NOT_HANDLED`); `eaLog`/`eaLogStack`
emit to the console (stack via `FormatCallStackText`) then pass through;
`eaIgnore` passes through silently. The step-over raise-arming
(`PlantInFuncStepBps`) still runs on the pass-through path. Covered by
`Test_ExceptionRule_Ignore_Resumes`,
`Test_ExceptionRule_Break_OverridesFilterOff`,
`Test_ExceptionRule_Log_ResumesAndLogs`,
`Test_ExceptionRule_Code_MatchesNativeOnly` (target switch
`--run-native-exception-test`: a native `0xE0424242` raise followed by a Delphi
raise — the code rule must break on the first and leave the second to the
filters) and `Test_ExceptionRule_Code_Decimal_BreaksOnNative`.

### `$exception` pseudo-variable

The debugger records the live exception object's VA on a Delphi-raise break
(`FExceptionObjAddr`, exposed via `IDebugTarget.CurrentExceptionObject`).
`DapServer` tracks `FStoppedOnException` (set in `OnStopped` from the reason) and,
on an exception stop, prepends a synthetic `$exception` row to the Locals scope
via `AppendExceptionLocal`. The shared `BuildCurrentExceptionRef` builds the
inline `Class: Message` value and an expansion ref (`ekRsmMembers` when the class
is in RSM/TD32, else `ekClass` RTTI reader). `HandleEvaluate` short-circuits a
bare `$exception` through the same builder (frame-independent, resolved before
frame selection) so it works in Watch/hover and as the row's `evaluateName`.
Covered by `Test_ExceptionLocal_ShowsExceptionObject`.

## Source-file resolution

`ResolveSourcePath` searches roots for a basename, top-level + one
level deep (or two levels deep for any root whose basename happens to
be `source`, matching the Delphi install layout). Roots come from:

- `sourceRoot` in the launch config (one path).
- `sourceSearchPaths` array in the launch config (each entry may also contain
  `;`-separated sub-paths).
- `%BDS%\source` if `BDS` is set.

Nothing is hardcoded; the user must supply real paths via launch.json
or environment.

Results are cached (`FSourcePathCache`, keyed by lowercase basename; `''` =
known-missing). The roots are fixed for the session, so a name always resolves
the same way. The filesystem scan is the dominant `stackTrace` cost on a deep
stack: frames in RTL / VCL / third-party code carry a source basename whose file
is not under the roots, so each one triggers a full root scan that fails — ~1.5 s
across ~20 frames, repeated for every `stackTrace`. The cache makes every stop
after the first instant.

## DAP capabilities advertised

| Capability                              | Value |
|-----------------------------------------|-------|
| `supportsConfigurationDoneRequest`      | true  |
| `supportsFunctionBreakpoints`           | false |
| `supportsConditionalBreakpoints`        | true  |
| `supportsHitConditionalBreakpoints`     | true  |
| `supportsLogPoints`                     | true  |
| `exceptionBreakpointFilters`            | delphi / av / all / unhandled |
| `supportsExceptionFilterOptions`        | true  |
| `supportsExceptionInfoRequest`          | true  |
| `supportsStepInTargetsRequest`          | false |
| `supportsEvaluateForHovers`             | true  |
| `supportsSetVariable`                   | true  |
| `supportsGotoTargetsRequest`            | true  |
| `supportsProgressReporting`             | true  |

Anything else is currently absent (function breakpoints, attach,
disassembly, set-next-statement).

## Known assumptions and limits

- Multi-thread aware. Every live thread is reported (`threads`), any thread's
  stack + locals/watches are inspectable read-only at a stop, and step
  over/into/out act on the selected thread while the others are frozen (see
  "Stepping" and `PROJECT_STATE.md`). Synthetic-call evaluation still runs on the
  stopped thread (frame-independent, so it needs no per-thread targeting).
- Win64 ABI only; 32-bit targets are out of scope today.
- `.rsm` is the only source of local/global variable metadata; if it
  isn't present, locals/globals scopes are empty but stepping and
  source mapping still work via `.map`.
- `FrameSize` derivation relies on the standard Delphi prologue. JIT
  or hand-rolled native code without `push rbp; sub rsp, NN` will
  return `FrameSize = 0` and the locals readout will be wrong for
  that frame.
