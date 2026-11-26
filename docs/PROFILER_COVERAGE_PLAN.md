# Profiler and code coverage — plan

Decided 2026-11-26. **Nothing described here is built yet.**

Two kinds of statement appear below and they are not interchangeable.

- A statement about the code as it stands was read from the source on that date
  and names the unit or routine it came from.
- A statement about behaviour still to be built is a design assumption. The ones
  the design leans on are listed under "Assumptions to measure", each with the
  increment that settles it. Until that increment has run they are hypotheses.

The first draft of this plan was reviewed adversarially the same day, against
the source and against the documented behaviour of the operating system. Every
paragraph the review changed is marked "(review)".

## The product, in the order it will be built

1. **The MCP server gains a profiler and code coverage.** One server, one
   engine: debugger, coverage, sampling profiler, instrumenting profiler. This
   document plans this step.
2. **Command-line tools.** Coverage accumulated over several test executables of
   one codebase (console runners or interactive programs) with a report at the
   end, and a profiler run from a shell. Usable in CI, where "fail below N % line
   coverage" is the requirement that matters.
3. **VS Code.** Coverage shown in the editor after an explicit run, the way
   NCrunch marks lines; profiler results browsable in the editor.
4. **Much later: continuous testing.** Rebuild and re-run the affected tests on
   every change. Not planned here; step 3 is useful without it.

Step 1 comes first because it is the front end that will be used most. Steps 2
and 3 add front ends, not engines, so step 1 has to be built for them:

| later step | what it needs from step 1 |
|---|---|
| 2, coverage CLI | launch-time arming, a "run until exit" driver, accumulation of several runs into one session, the store as a file, exporters (Cobertura, LCOV, JSON, HTML), a threshold check |
| 2, profiler CLI | the same driver, the report text, exporters (`.cpuprofile`, collapsed stacks, callgrind) |
| 3, VS Code | the same engine API behind DAP custom requests, results readable while the session is alive, per-line figures keyed by source file |
| 4, continuous testing | coverage attributed per test, which needs a "reset and read" cycle cheap enough to run between tests |

## Rules that keep step 1 reusable

1. **Collection, aggregation, storage, queries and report text live in
   `DebuggerCore`, JSON-free.** `MCPDebugger\` adds argument parsing and
   transport, nothing else. The check: a new front end needs no code from
   `MCPDebugger\`.
2. **Results are keyed by source.** Inside one run a location is (module, RVA).
   Across runs and executables it is (source file, line) and (unit, routine).
   Step 2 merges runs of different executables, so nothing may depend on two
   runs sharing addresses.
3. **The session database is the interchange format.** A front end that wants
   the results of a finished collection opens the file; it does not ask the
   process that produced it.
4. **Arming at launch is part of the launch options**, not a sequence of tool
   calls. A collection that must see the first instruction of the process
   cannot be started by a second request.
5. **One driver for "run until exit or deadline, then finalize".** `profile_run`
   and both command-line tools are that driver with different arguments. Over
   MCP it is polled, never one request held open for the whole run.
6. **Inert when unused.** With no collection active the engine pays one
   predictable branch per breakpoint event and nothing else. The DAP adapter
   does not change in step 1.
7. **New engine entry points get interfaces of their own.** `IDebugTarget` is
   already large and has a second implementer in the tests (`TFakeMemTarget`,
   `ValueReaderTests.pas`); `TWinDebugger` implements the new interfaces and
   callers reach them with `Supports`.

## Requirements

- **Coverage at line level, by instrumentation.** Every line in scope carries a
  probe that counts, and the result is how many times each line ran, as in
  AQtime's coverage profiler. A first proposal built on breakpoints that are
  removed at their first hit, which can only say "ran" or "did not run", was
  turned down by the owner on 2026-11-26. That mechanism survives here in two
  subordinate roles only: as the fallback for a line that cannot take a
  counting probe, and as an intermediate stage on the way there (see
  "Coverage").
- Profiling in three forms: sampling, instrumentation of whole routines,
  instrumentation of single lines.
- AQtime is the reference for concepts (areas, hit count, time, time with
  children, get results, enable and disable). The maintainer's .NET-for-Android
  profiler (`net-android-debugger-profiler`, a sibling repository) is the
  reference for the tool vocabulary and the data model, so an agent finds the
  names it already knows.
- Real applications: both bitnesses, a single executable and runtime packages
  loaded at run time, several threads, exceptions as ordinary control flow.
- The target is the binary the developer already builds for debugging. No
  second build, no special compiler option.
- The debugger stays usable while a collection runs.

| AQtime | here |
|---|---|
| Areas (including, excluding) | scope: `include` / `exclude` |
| Hit Count | `hits` of a line, `calls` of a routine |
| Time / Time with Children | `self` / `total` |
| Get Results | `profile_snapshot` |
| Enable / Disable Profiling | `profile_resume` / `profile_pause` |
| Clear Results | `profile_clear` |
| Triggers and actions | not in step 1 (see "Accepted limits") |

## Starting point

Read from the source on 2026-11-26.

| need | what exists | what is missing |
|---|---|---|
| debug loop | `TWinDebugger.ProcessOneEvent`: `ProcessCommandQueue`, `WaitForDebugEvent(Ev, 10)`, dispatch. In the MCP server the same thread runs the tool handlers (`TMcpServer.Run`). Two nested pumps: `RunMethodCall` (100 ms) and `DrainUntilExit` (50 ms). Nothing in the repository raises the system timer resolution | a fast path for probe hits in the main pump and in `RunMethodCall`; a shorter wait, and a finer timer, while sampling |
| breakpoint bytes | `PlantInt3` / `RemoveInt3` / `WriteByte` (execute-read-write, flushes the instruction cache). `FBreakpoints` is a list with a linear `FindBreakpointByVA`, kept that way on purpose for fewer than about 100 entries (`TRAPS.md`) | a table for 10^5 to 10^6 sites, writes batched per page |
| reading code | `ReadCodeMemoryAt` returns the program's own bytes under planted breakpoints. Several readers of code bypass it and call `ReadProcessMemoryAt`: the x86 walker's call-site test and prologue probe (`WinDebuggerX86.pas`), `TWin32Debugger.PlanExceptionStep`, which refuses a handler stub whose first byte is not `$E9`, and the import-thunk test in `WinDebuggerBase.pas` | the same overlay for probes and patches, and every reader of code going through it |
| remote memory | `VirtualAllocEx` always with a nil address; `WriteMemoryAt` uses `PAGE_READWRITE` and does not flush | executable memory near a module; a code writer for more than one byte |
| line records | `ISourceLineProvider`: point lookups and `SortedRvas`. `TTD32FileReader` holds `FLineRows` (RVA, file, line), `FSourceFiles`, `FModIndexUnit`. RSM and DCP carry no line table. The JDBG reader walks the whole (address, line) stream to build `SortedRvas` and discards the line | enumeration of (RVA, file, line, owning unit) |
| routines | `TTD32FileReader.FProcs` (start, end, name), private. MAP publics have a start and no size | enumeration with ranges |
| disassembly | `IDisassembler` gives text and length. Zydis 4.1 writes the whole `ZydisDisassembledInstruction` (1232 bytes) into `ZydisApi`'s buffer; only the length (offset 16) and the text (offset 1136) are read | access to the displacement, immediate and branch fields already in that buffer. No encoder is needed |
| stack walk | `WalkRawFrames` (virtual), built for a stopped process. x64: dbghelp `StackWalk64`. x86: the EBP chain, recovery passes that consult the symbol providers, and a full dbghelp walk on every call for the tail; with a frameless routine on top it returns the leaf and then the caller's caller. `GetStackFrames` stops at `MAX_FRAMES = 30`, and dbghelp binds all of it to the pump thread | capture from a running process, deeper walks, on x86 a rule for a frameless top frame, eventually a walker that needs neither dbghelp nor the pump thread |
| process start | An MCP launch always stops at the PE entry point. A package's DLL entry (`_InitPkg`, `SysInit.pas`) only registers the module; unit initialization is driven later from the executable's own start-up. So at the entry stop no Delphi `initialization` section has run, in the executable or in a statically imported package. Only the start-up of statically imported DLLs that are not packages has | nothing. It is why a collection started at the entry stop loses almost nothing |
| modules | `HandleLoadDll` -> `TDebugSession.HandleDllLoaded`, which loads symbols synchronously only for a module that owns a pending breakpoint; everything else goes to the prefetcher and is published at the next stop | synchronous load for a module in the collection's scope. The cheap PACKAGEINFO membership test is in the DAP front end (`DapServer.pas`), not in the core |
| attach | With `KillOnDetach = False` the engine calls `DebugSetProcessKillOnExit(False)`, so that a debugger that dies does not take the attached process with it | a rule for breakpoint bytes left in such a process |
| persistence | none. No database anywhere in the repository | the store |
| MCP | about 50 tools in one `if` chain (`TMcpServer.DispatchToolsCall`), schemas in `McpToolSchemas.pas`, results are JSON serialised as text, one deferred-reply slot (`ArmWait`) that never holds a reply past its timeout (30 s by default), no cancellation, no progress, no `instructions` in `initialize` | a unit of its own for the new tools, text tables, a bounded wait for `profile_run`, an `instructions` string that teaches the workflow |

## Design

```
front ends     TMcpServer + McpProfilerTools      (step 2: CLI)   (step 3: TDapServer)
                        |                              |                  |
session        TDebugSession.Profiler : TProfilerHost  -- one collection at a time
                        |
collectors     TCoverageCollector   TInstrumentingProfiler   TSamplingProfiler
                        |                   |                       |
engine              ICodePatchTarget (line probes)         IStackSampleTarget
               (TWinDebugger: patch map, trampolines, hooks in the event pump)
                        |
symbols        ILineRecordProvider, IRoutineRangeProvider -> TModuleCodeMap
               routine analysis: which records are instruction boundaries
results        TProfileStore (SQLite) -> report text, exporters
```

Unit and type names in this document are proposals; the first increment that
touches one fixes it.

### One collection per debug session

A collection has a mode, a scope and a state.

- Modes: `coverage` (a hit count for every line in scope), `sampling`,
  `instrumenting` with `level` `routine` or `line` (time as well as counts).
- States: `Idle -> Armed -> Collecting <-> Paused -> Finalizing -> Ready`, or
  `Failed`. `Armed` is a collection started paused.
- One at a time per debug session. Mixing modes is refused by name, not queued.
- A collection is armed either at launch (`TLaunchOptions` carries the
  specification, so the first instruction of the process is already measured) or
  on a live session ("from now on").
- The debugger keeps working. What a stop or an evaluation does to the figures
  is recorded with the session (`stops`, `syntheticCalls`) so a report can say
  it was disturbed instead of presenting disturbed figures as clean.

### Code map

Coverage needs every line record of a module, sampling needs to name any
address, instrumentation needs routine boundaries. Today the providers answer
point lookups only.

- Two optional provider interfaces, `ILineRecordProvider` and
  `IRoutineRangeProvider` (GUID suffixes `0014` and `0015`; the "NEXT FREE"
  note in `DebugInfoTypes.pas` and `ProviderInterfaceGuids_AreUnique` move with
  them). Each returns its whole table and a `Complete` flag, like
  `ISourceFileListProvider`.
- TD32 and `.tds` first: the data is already in `FLineRows`, `FSourceFiles`,
  `FProcs` and `FModIndexUnit`. MAP second, with routine ends marked
  approximate (the next public). JDBG third: its reader already walks every
  (address, line) pair. A module whose only formats are `.rsm` or `.dcp` is
  reported as not measurable, by name.
- `TModuleCodeMap` is built once per loaded module from those tables, in
  **module-relative** RVAs (the engine's RVA space is anchored at the main
  executable and shifted per module; a stored result must not be). It adds what
  the collectors need: the routine of each line record, the length of each
  record's code (next record or routine end), the owning unit, the source path
  resolved through `TSourceResolver`.
- A line record is used only when it lies inside a routine range. Records that
  do not are counted and reported; nothing is planted on them. `KNOWN_UNKNOWNS.md`
  already documents MAP records that are not where they claim to be. Increment
  0 has to say what such records are before this rule drops anything: on x64 a
  `finally` block also exists as a separate piece of code the exception
  dispatch calls, and the clause table of an `except ... on` sits in the code
  section next to it (`EH_FORMAT_NOTES.md`); whether a procedure record's range
  reaches them has not been looked at.
- **A record gets a probe only when it is confirmed as an instruction
  boundary** (review). See "Routine analysis" below for what confirms it.

### Scope

What to measure, in the role AQtime gives to areas.

- `include` and `exclude` are lists of `kind:pattern` with `*` and `?`:
  `module:`, `unit:`, `file:`, `class:`, `routine:`. A bare pattern is a unit.
  Exclusion wins.
- Default with no `include`: every line whose source file resolves under the
  session's source root (not under the additional search paths). That is "the
  project's own code", including generic code written there and instantiated
  elsewhere. With no source root: the main module.
- A module that cannot contain anything in scope is never parsed for it. For a
  package that decision comes from PACKAGEINFO, which means moving that reader
  from the DAP front end into the core. A module that can is loaded
  synchronously at its load event, exactly as a module that owns a pending
  breakpoint is today.
- The scope is project knowledge, so taking its default from a launch
  configuration or from DDK is consistent with the rule that the MCP server
  never reads the user's run-control settings.

### Line probes

Coverage and the instrumenting profiler both put a probe on a line. A probe
that counts must survive its own hit, so whatever it overwrites has to run
somewhere else. Five forms:

| form | what is written into the code | cost of a hit | what it yields | where it can go |
|---|---|---|---|---|
| retargeted call | the target field of a `call` that is already there | a few instructions | count, and time | a direct `call` in the line's first block |
| jump | a five-byte `jmp` to a trampoline | a few instructions | count, and time | where all six points of the jump rule hold |
| call | a five-byte `call` to a trampoline | a mispredicted return | count, and time | where the first five points hold |
| entered by `$CC` | one `$CC`; the debugger sends the thread to the trampoline on every hit | one debug event | count, and time | a confirmed boundary whose instruction can be relocated |
| one-shot | one `$CC`, taken away at the first hit | one debug event, once | "ran at least once" | a confirmed boundary |

**Site, span, trampoline.** A site is an address where a probe goes: a line
start, a routine entry, a routine exit. In the jump and call forms the site is
overwritten with five bytes that lead to a trampoline:

```
T:  payload                   count the hit, or call the runtime
    relocated instructions    the instructions the patch displaced, re-based
    jmp A + n                 back to the first instruction that was not displaced
```

**Routine analysis.** Everything about a site is decided per routine, not per
site. The routine is decoded by following control flow from its entry, from
every direct branch target, from every jump-table entry and from every
exception-handler entry (`EH_FORMAT_NOTES.md`). The result is the set of
instruction boundaries, the set of addresses control can reach other than by
falling through, the call sites and their return addresses, and the `ret`
instructions and jumps that leave the routine.

It also says which line records can be trusted (review). A record is
**confirmed** when a decode that started at one of those proven places arrives
exactly at it. A decode started AT a record proves nothing: x86 decoding falls
back into step within a few instructions, so a record in the middle of an
instruction would pass. An unconfirmed record gets no probe of any form. A
`$CC` there would sit in an operand, never run, never be restored, and
silently change a constant of the program being measured. Code sections hold
tables as well as code: `case` jump tables, and on both bitnesses the clause
tables of handlers; `TRAPS.md` records what a single `$CC` on one of those did
to a probe run.

A routine the analysis cannot finish — a byte that does not decode, an indirect
jump that is not a recognised jump table — keeps the records confirmed before
the break and loses the rest, and none of its sites gets a jump or call patch.

**The jump rule.** A site at `A` takes a jump only when all of these hold:

1. the routine was analysed completely;
2. the instructions starting at `A` cover at least five bytes inside the
   routine: the span `[A, A + n)`;
3. nothing can transfer control strictly inside the span: no direct branch
   target, no line start, no jump-table entry, no exception-handler entry (the
   blocks named by the x64 scope and clause tables; on x86 the handler stubs,
   the entries of a clause table, and whatever the RTL's handlers jump to
   relative to a stub, to be read from the RTL source in increment 4), no
   address inside the routine that appears in it as an immediate or a
   displacement;
4. every instruction in the span can be relocated and none is a `call`;
5. no breakpoint is planted inside the span, and no thread's program counter is
   strictly inside it at the moment of the write;
6. on x64, `A` is not where the system unwinder looks: it is not inside the
   window of any return address (below).

**Never a jump where the system unwinder looks.** Rule 6 is about the operating
system's unwinder, not about ours. On x64, when an exception travels through a
frame, `RtlVirtualUnwind` reads the code at that frame's return address to
decide whether the frame is in its epilogue. It accepts an optional
`add rsp` or `lea rsp`, any number of `pop`, and then a `ret` or a `jmp` that
leaves the function; having matched, it replays what it read and takes the
frame for released. Call the instructions it may read from a return address
that address's **window**: the `add`/`lea`, the pops, and the one instruction
after them.

A jump patch anywhere in a window is read as that final `jmp`. Two shapes, both
common:

```
   E8 ..            call Foo
R: E9 ..            <- patch on the next line's first instruction: the unwinder
                       sees a tail call and takes [rsp] for the return address

   E8 ..            call Bar
R: 48 8D 65 28      lea rsp,[rbp+28h]         ; left alone
   E9 ..            <- patch over "pop ...; ret": the unwinder replays the lea,
                       pops nothing, and takes a saved register for the address
```

In both, an exception raised below the call unwinds the frame wrongly and the
process dies in the dispatcher. The second shape (review) is the exit of every
routine whose last statement is a call or that finalizes managed locals. A
`$CC` or a `call` in the same place is harmless: neither matches the pattern,
so the unwinder falls back to the unwind codes, which are right there because
nothing of the epilogue has run. The published description of epilogues admits
a `ret` or an indirect `jmp`; that a relative `jmp` out of the function counts
too is knowledge of the implementation, not documentation. Measured in
increment 1, on both shapes, before anything depends on it. On x86 there is no
table unwinder and rule 6 does not apply.

**The call form.** A five-byte `call` to the trampoline, whose first act is to
drop the address the call pushed, in a way that leaves the processor's return
prediction paired. It may sit inside a window, so it is the form for an exit
whose epilogue starts at a return address and for a line start in the same
position with nowhere better to put the probe. It costs a mispredicted return
per hit, tens of cycles against the hundred thousand of a debug event.

**The probe may sit anywhere in the line's first straight-line block.** Every
instruction from the line start up to its first branch, its first call, or the
first address a branch can reach — whichever comes first — runs exactly once
per entry into the line, so a probe on any of them counts the same thing.
(Past a branch target it does not: in `for I := 1 to N do Foo(I);` written on
one line, the line is entered once and `Foo` is called N times.) That freedom
is what keeps rule 6 and short first instructions from pushing most sites to
the slow forms:

- a line start that is a return address is left untouched and the patch goes on
  a later instruction of the block;
- **a direct `call` in that block is retargeted instead of displaced.** The
  five bytes stay a `call` and only its target changes, to a trampoline that
  counts and jumps on to the real callee. The return address is the original
  one, nothing is relocated, the bytes are still a `call` to anyone who reads
  them, and the processor's return prediction stays paired. When the call is
  the line's first instruction this needs no routine analysis beyond a
  confirmed boundary.

**Calls are never displaced** (review). A span ends before the first `call`,
and a call that should carry the probe is retargeted. So the bytes in front of
every return address are still a call instruction and the return address is
the one the compiler emitted. That matters to three readers: the exception
dispatch, which compares return addresses against `try` ranges; the program's
own stack tracers, which keep a stack word only when a call precedes it (JCL's
`ValidCallSite` does exactly this, and a Delphi application that logs its
exceptions usually has one); and the engine's x86 walker, which proves return
addresses the same way. A six-byte indirect call through memory could be
re-encoded as a five-byte call and a `nop`, at the price of a return address
one byte earlier; that is tried in increment 1 and used only if dispatch does
not notice.

**The two forms that start with a `$CC`.** A site that can take none of the
patches above still has two options, and which one is used is the collector's
decision, not the engine's:

- *Entered by `$CC`.* The debugger answers the breakpoint by pointing the
  thread at the trampoline. Exact, and one debug event per hit, so a hot loop
  through such a line is slow.
- *One-shot.* The first thread that reaches the byte traps; the debugger
  records the hit, puts the original byte back, rewinds the program counter and
  continues. Nothing is relocated, no memory is allocated in the target, and
  after the first hit the line runs at full speed. It tells that the line ran,
  not how often.

**Relocation.** Most instructions are copied unchanged. A relative branch is
re-encoded in its long form towards the same target; a RIP-relative operand
gets a new displacement to the same address, which is why trampolines are
allocated within 2 GB of the module on x64. No assembler is involved: bytes
are copied and one field is rewritten, at the offset Zydis reports.

**A fault in a trampoline is sent back.** The debugger sees a first-chance
exception before the program does. When the faulting address is in a
trampoline, the debugger withdraws that site (original bytes back) and
continues with `DBG_CONTINUE` after putting the thread where the program
expects it: at the original address of the relocated instruction that faulted,
or, for a fault in the payload, at the site with the stack pointer the payload
found. The instruction then runs, and faults if it must, at the address the
program's exception tables, its error messages and its own stack traces
expect. The site stays withdrawn and is reported.

**One map of patched bytes.** Breakpoints stay in `FBreakpoints`. Everything
else that is not the program's own code is in one map (`TCodePatchMap`):

- It gives the program's bytes for a window. Every reader of code goes through
  it: `ReadCodeMemoryAt`, the raw readers listed under "Starting point", and
  `StackWalk64`, which is given a read routine instead of `nil` because dbghelp
  applies the same epilogue test and must not see a patch.
- It tells `PlantInt3` which byte a breakpoint must save: the byte of the layer
  beneath it (review). On a jump, call or retargeted site that is the patch's
  first byte, so the existing re-arm path steps the patch itself and nothing
  else changes. On a `$CC` site it is the program's own byte, and the hit is
  handed to both owners: the probe is recorded and the breakpoint path runs the
  instruction in place.
- It tells `RemoveInt3` whether a breakpoint that is being DELETED may put its
  byte back. The transient removal inside the hit path is a different
  operation and is never suppressed: suppressing it re-traps on the same byte
  and the re-arm branch of `HandleException` continues one byte into the
  instruction.
- It maps a trampoline address to the original address it stands for.
- A breakpoint asked for inside a span withdraws the site first.

**In the event pump.** All in `TWinDebugger`, behind `ICodePatchTarget`:

- A hook at the top of the breakpoint case of `HandleException`, ahead of the
  breakpoint list and ahead of the unconditional `DapLog(Format(...))` there,
  and the same in `RunMethodCall`'s pump.
- The map never forgets an address it once gave a `$CC` while the process
  lives (review). A thread can trap on the byte just before it is restored, by
  a second thread at a one-shot or by `profile_stop`, and its event arrives
  afterwards; without the tombstone it falls into "not our breakpoint" and is
  handed to the program as an exception.
- A record whose own first byte is already `$CC` is the program's breakpoint
  instruction, not a place for ours: restore, rewind and "already fired" would
  loop on it for ever.
- Every restore compares first, in every form: a byte that is no longer ours
  was overwritten by the program and is left alone.
- A one-shot hit caused by the debugger's own synthetic call is consumed, not
  recorded, and the byte is planted again when the call ends: evaluating a
  getter is not the program executing that line. Counters cannot make that
  distinction; the session records that evaluations happened.
- Module unload drops the module's patches without writing. Results are kept by
  (module, RVA), so a package that is unloaded and loaded again is patched
  afresh and keeps what it had already counted.
- Clean detach restores every patched byte before `DebugActiveProcessStop`, in
  the block of `TWinDebugger.Terminate` that already restores breakpoints, with
  the threads suspended and the queued breakpoint events drained first.
- **A debugger that dies cannot take its `$CC` bytes back** (review). In a
  launched process that does not matter, the process dies with it. In a process
  attached with `killOnDetach` false it does: the engine has told Windows to
  let that process live, and it would then die at its next unexecuted line. A
  collection that would leave `$CC` bytes in such a process is refused unless
  the request accepts that in so many words.
- A breakpoint instruction at an address the debugger did not plant is still
  handed to the program, as today. While a collection is active the debugger
  output also says so and why it matters: a program that copies its own code (a
  hooking library relocating the first bytes of a routine in scope) copies a
  `$CC` of ours with it, to an address no table knows.

**A trampoline address is never shown.** A stop, a stack-walk seed, a data
breakpoint report, an exception report: each maps a trampoline address back to
the original instruction, or to the site for payload bytes. A trap-flag step
that lands in a trampoline keeps stepping until it leaves; a retargeted call
arrives at its callee with the original return address on the stack, which is
the state the stepper expects there. Instruction-granularity steps are
refused, with the reason, while trampolines are installed.

**When patches go in and come out.** A `$CC` can be planted the moment a module
is mapped: loader relocations rewrite operand fields and never the first byte
of an instruction. A multi-byte patch cannot be planted before the loader has
finished relocating the module, or the loader would add its delta to the middle
of it. One rule for both bitnesses (review): the main executable is patched at
the process's first breakpoint event, when it is mapped and relocated and none
of its code has run; every other module at a one-shot on its own entry point.
On a WOW64 target that first event is the 64-bit loader's, with the 32-bit
imports not yet mapped, which is why "everything at the loader breakpoint" is
not the rule. Trampolines are never freed while the process lives, because a
thread or a foreign hook may still pass through one.

**Payloads.**

- Hit count: an atomic increment of a counter. No call, no per-thread state.
  The flags are saved around it unless the routine analysis proves them dead at
  the site, which at the start of a compiled statement is the usual case and
  inside a hand-written `asm` body is not. The debugger can hijack a paused
  thread anywhere, inside a payload too; a payload keeps nothing below the
  stack pointer, so it resumes intact.
- Routine entry and exit, and timed lines: a call into a runtime that lives in
  the target.

### Coverage: a hit count for every line

A coverage collection puts a counting probe on every confirmed line record in
scope and reports, per source line, how many times it ran. `covered` is
`hits > 0`.

**Which form each line gets.** The cheapest counting form that fits: a
retargeted call, a jump, the call form. A line where none fits — too short, a
branch target in the way, a routine the analysis could not finish — gets a
one-shot by default: the line is still known to have run, its count is reported
as `1+` ("ran, not counted"), and the program does not pay a debug event for
every pass. A collection that asks for `exactCounts` gets the `$CC`-entered
form on those lines instead, and pays for it. Increment 0 measures how many
lines fall into this case; the design assumes a minority.

**Two stages.** The one-shot form is needed for the fallback anyway, it is the
simplest thing the patch map has to carry, and it exercises everything around
the probes: the code map, the analysis, the scope, the store, the tools. So it
is built first:

- *Stage 1 (increments 5 to 8):* every line in scope carries a one-shot. A
  coverage session answers which lines ran. Every hit count reads `1+`.
- *Stage 2 (increment 11):* counting probes replace one-shots wherever the
  rules above allow. Hit counts become real. The tools, the store and the
  sessions do not change shape; a stage 1 database stays readable.

Stage 1 is not the coverage the owner asked for. It is a step towards it that
happens to be usable. Whether it is released on its own is the first of the
"Decisions for the owner".

**Pausing and clearing.** `profile_pause` leaves every patch in place. A
one-shot that fires while paused is restored, not recorded, and planted again
at `profile_resume`; a counter's increase over the paused interval is read at
both ends and subtracted. `profile_clear` re-plants the one-shots that fired
and takes the counters' current values as the new zero.

**What a line's state means.** A source line is `covered` when any of its
records ran, in any instantiation, module or accumulated run, and its `hits`
are the sum over its records. The store also keeps, per line and routine, how
many records the line has and how many ran. Whether "some but not all" is shown
as a third state is decided after increment 0 has shown which constructs give
one line several records: a `for` is one, where it would mean a body that never
ran; the exception-path copy of a `finally` block may be another, where it
would mark nearly every `finally` in a codebase and say little. One kind of
record is never probed: on x86 the handler stub of a `try` is a line record
that runs only while an exception is being dispatched, and it is machinery, not
a statement. This is line coverage. It is not branch or condition coverage, and
reports say so.

### Sampling

At a fixed interval, for each thread: has it consumed CPU since the last tick,
and where is it.

- **Which threads to look at.** A thread that has not run since the last tick
  need not be suspended: its stack is the one captured before. With fifty idle
  threads that is the difference between fifty queries and fifty suspensions
  per tick. The candidate test is the thread's cycle counter. Whether that
  counter moves for a thread that is running on another core between two
  context switches is not documented (review); if it does not, the test skips
  exactly the busiest thread. It is the first thing increment 12 measures, and
  the fallback is to suspend every thread whose last sample was not a wait.
- A thread that ran is suspended, its context read, its raw stack captured, and
  resumed. Raw means addresses: a sample is stored as (module, RVA) frames in
  an aggregated tree, and named when the collection is finalized or
  snapshotted. A sample whose stack pointer lies outside the thread's own stack
  is discarded and counted: a WOW64 thread caught between its 32-bit and 64-bit
  halves can report a stale one.
- **x64** captures through the existing `WalkRawFrames`.
- **x86 needs a walk of its own from the start** (review). The existing one is
  built for stops: it runs dbghelp on every call and asks the symbol providers,
  and with a frameless routine on top — the usual shape of a hot sample, think
  of `Move` — it loses the direct caller. The sampling walk finds the return
  address of a frameless or not-yet-framed top routine near the stack pointer,
  with the call-site test the engine already has, then follows the EBP chain,
  validating each link against the module table. No dbghelp per sample.
- Figures are sample counts with the measured mean interval beside them, in
  four columns as in the reference profiler: inclusive, exclusive, and the
  `_cpu` variants that count only ticks in which the thread consumed CPU.
  Leaf frames in the kernel's wait and message stubs are marked as wait frames
  for display.
- Ticks while the session is stopped, and while a synthetic call is in flight,
  are not taken.
- The pump's wait is a field, shortened while a sampling collection runs, and
  the collection raises the system timer resolution for its duration: without
  that a shortened wait still returns on 15.6 ms ticks.
- A native target gives what MonoVM could not: samples per line. The exclusive
  samples of a routine are split by the line of the program counter, and the
  inclusive ones by the line of each call site.

Two increments, because the walker decides the achievable interval:

1. Sampling on the pump thread. The interval is whatever the measured cost of
   a walk allows.
2. A sampler thread with a walker of its own on x64 as well: one bulk read of
   the stack, the module's `.pdata` and unwind information read once and
   cached, unwinding done locally. This is what makes a 1 ms interval
   affordable, and it stops a slow tool handler from opening gaps in the
   samples.

Sampling depends on nothing in "Line probes". It is scheduled after coverage
has its counts because that is what the owner asked for first; it can be pulled
forward, or built in parallel, without touching the rest.

### The runtime in the target

Routine time, time with children and the call tree cannot be aggregated on the
debugger's side: a hot loop produces events faster than any buffer drains. The
aggregation has to happen where the events are.

- Per thread: a shadow stack of open routine frames (routine, stack pointer at
  entry, timestamp, time spent in children) and that thread's tree of call
  paths with `calls`, `total`, `self`, `min`, `max`.
- **Not every `ret` is an exit** (review). On x86 a `finally` block ends in a
  `ret` that returns into the same routine or into the RTL, and an x64 funclet
  ends in one too. The exit probe therefore sits on every `ret` and on every
  jump that leaves the routine, and closes the frame only when the stack
  pointer equals the one recorded at entry.
- An exception that unwinds past instrumented frames skips their exit probes.
  The next entry or exit event reconciles: every shadow frame whose recorded
  stack pointer is no longer above the current one is closed and counted as an
  exception exit.
- **Re-entry is dropped, not served** (review). A thread already inside the
  runtime that enters it again records nothing. That is what happens when the
  debugger pauses a thread there and then evaluates an expression on it: the
  evaluation runs instrumented code over a half-updated shadow stack.
- Time is `rdtsc`, converted with a frequency the debugger measures between the
  start and the end of the collection. It is elapsed time; see "Accepted
  limits".
- The debugger owns all allocation. It assigns a thread its context at the
  thread's create event, while the process is frozen, and harvests it at the
  exit event. The runtime finds its context from the thread id in the TEB and
  never allocates, locks or calls the operating system.
- While a thread is inside the runtime its context records the site and the
  stack pointer it came from, so a stop that finds it there walks the stack
  from the site.

How the runtime gets into the target. Two candidates:

- **Loaded DLL (preferred).** A synthetic call to `LoadLibraryW` at the entry
  stop, which the engine can already make. The operating system maps it,
  relocates it and registers its unwind data, so a thread stopped inside it
  walks like any other. At the entry stop no unit initialization has run
  ("Starting point"), so nothing of the program's own code escapes it; what
  does is the start-up of statically imported DLLs that are not packages, whose
  routine events go to a stub until the runtime is there. The first draft
  preferred the other candidate on the belief that static packages initialize
  before the entry stop. They do not (review).
- **Mapped image.** The same image mapped by the debugger itself: sections
  copied, base relocations applied. It exists before the first instruction and
  needs no call into the target, at the price of a mapper and of frames no
  unwinder knows.

Either way the runtime is written in Pascal, built for both bitnesses, uses no
import on its hot paths, and its logic is unit-tested in-process by loading the
same image normally. The choice is made before increment 14.

### Results store

SQLite, one database per collection, in a session directory.

- Sessions root: `%LOCALAPPDATA%\DelphiWin64Debugger\sessions`, overridable with
  `DELPHI_DEBUGGER_SESSIONS_ROOT`. A session can also be created in, and opened
  from, an explicit directory: the command-line tools will.
- Session id: `yyyyMMdd-HHmmss-<name or executable>-<mode>`. A name can be
  changed; the id never does. Every query tool takes `sessionId` and defaults
  to the session most recently created by this process, then to the newest on
  disk.
- The engine is the SQLite that ships with Windows (`winsqlite3.dll`), bound
  dynamically like Zydis and failing closed the same way: no library, tools
  report unavailable with the reason. No new build dependency. The copy on the
  development machine is 3.53.4, from an Insider build; the version follows
  Windows Update, so the store uses only SQL an old release accepts.
- Aggregation happens when results are written. Queries filter, sort and limit.
- Units are never mixed in one table: sample counts, nanoseconds and coverage
  each have their own.
- **What identifies a source file across runs** (review). TD32 interns base
  names, and the resolver turns a name into the first path it finds, so two
  different `Utils.pas` in two executables would merge. The key is the path the
  debug information recorded when it has one, otherwise unit and file name, and
  the store keeps a hash of the resolved file: runs whose hashes differ are not
  merged silently.

Tables. Where the concept exists in the reference profiler (schema version 4)
the table and column names are the same, so one viewer can read both:

| table | content |
|---|---|
| `schema_info`, `session`, `segment` | as in the reference: what was collected and how, and when the results were refreshed (snapshot, clear, final) |
| `module` | name, path, size, timestamp, bitness, symbol formats |
| `source_file` | name and path as recorded, resolved path, content hash, whether it is in scope |
| `method` | the reference's dictionary, read natively: `namespace` is the unit, `type_name` the class, `runtime_method_id` the module-relative RVA; `source_file`, `source_start_line`, `source_end_line` filled from the code map |
| `thread` | as in the reference |
| `sample_stat`, `sample_tree`, `sample_edge` | as in the reference |
| `sample_line` | exclusive and inclusive samples per (file, line, method) |
| `timing_stat`, `timing_tree` | as in the reference: calls, total, self, min, max, exception exits |
| `line_stat` | hits, self and total nanoseconds per (file, line, method) |
| `coverage_line` | per (file, line, method): records, records that ran, hits, and whether the hits are exact or `1+` |
| `coverage_method`, `coverage_file` | lines, lines covered, calls |

Accumulation and merge are one store operation: `appendTo` on a collection and
the merge of step 2 both call it.

## MCP tool surface

Names follow the reference profiler wherever the concept is the same. Query
tools return fixed-width text tables with a header, as the reference does,
because a table of forty rows costs a fraction of the same rows as JSON
objects. Lifecycle tools return JSON like every other tool of this server.

Arming:

| tool | arguments | notes |
|---|---|---|
| every launch and attach tool | optional `profile` object: `mode`, `level`, `include`, `exclude`, `exactCounts`, `intervalMs`, `name`, `appendTo`, `startPaused` | the collection exists before the first instruction. Still stops at entry |
| `profile_start` | the same fields | on the live session, "from now on". At the entry stop of a launch that loses only the start-up of statically imported DLLs that are not packages |
| `profile_run` | one of `program` / `project` / `configFile`, `args`, the `profile` fields, `waitSeconds` (default 30), `durationSeconds` (0: until the program exits), `keepRunning` | launch, arm, run. Answers within `waitSeconds`: the summary if the run has ended, otherwise the session and its state |
| `profile_wait` | `sessionId`, `waitSeconds` | waits again, bounded the same way |

`profile_run` does not hold its reply for the whole run (review). The server's
own wait tools never hold one past their timeout, it handles no cancellation
and reports no progress, and a client is entitled to give up on a silent
request. The run is a state that `profile_wait`, `profile_status` and
`profile_stop` observe; the command-line tools drive the same state without
the bound.

Control: `profile_stop`, `profile_pause`, `profile_resume`, `profile_snapshot`,
`profile_clear`, `profile_status`. `get_debug_session_status` and the compact
snapshot name the active collection and its state, so an agent that only
debugs still learns one is running.

Sessions: `profile_sessions`, `profile_rename_session`,
`profile_delete_session`, `profile_archive`, `profile_archives`.

Queries, all with `sessionId`, `top`, `filter`:

| tool | sessions | columns |
|---|---|---|
| `profile_hotspots`, `profile_flat` | sampling | `incl excl incl_cpu excl_cpu %cpu routine [wait]` |
| `profile_tree` | sampling, instrumenting | children of a node, largest first |
| `profile_callers`, `profile_callees` | sampling, instrumenting | the edges of one routine |
| `profile_timings` | instrumenting | `calls total_ms self_ms avg_us min_us max_us exc routine` |
| `profile_threads` | sampling, instrumenting | per thread |
| `profile_annotate_source` | all | a source file with the figures of the session beside each line: hits (`1+` where not counted), or hits and time, or samples. `routine` and `onlyUncovered` narrow it |
| `coverage_summary` | coverage, line-level instrumenting | `by`: module, unit, file, class, routine. `lines covered % calls`; sorted by uncovered lines, percentage, hits or name |
| `coverage_uncovered` | the same | the uncovered line ranges of a file, unit or routine, grouped by routine: what a test still has to reach |
| `coverage_diff` | the same | lines covered in one session and not in another |
| `profile_report` | all | the summary of a session and where its database is |

`TMcpServer.DispatchToolsCall` does not grow: the new tools live in
`McpProfilerTools.pas` with schemas in `McpProfilerToolSchemas.pas`, and the
chain delegates to them by name prefix. `initialize` gains an `instructions`
string that carries the workflow, as the reference server's does.

## Increments

Each one ends with the full suite green on both fixtures, the documents that
own its facts updated in the same change set, and its measured numbers written
into this file under a "Verified in increment N" heading.

A release can follow increment 8 (coverage that tells which lines ran, if the
owner wants it on its own), 11 (coverage with hit counts), 13 (sampling) and
15 (the instrumenting profiler).

### Increment 0 — Measure before building

No engine change. Two DevTools.

- `LineSiteSurvey` (static, one binary with TD32), both bitnesses:
  - line records and routines; records outside every routine range and what
    they are; whether procedure ranges reach funclets and clause tables;
  - records the forward decode confirms as boundaries, by the rule under
    "Routine analysis", and the unconfirmed ones with the reason;
  - records that point at a table rather than at code;
  - source lines with more than one record, by construct;
  - the share of lines that could take each counting form, the share left to a
    `$CC`, and the same for routine exits;
  - every indirect jump with the code around it.
- `ProbeCostProbe` (dynamic, drives `TDebugSession`): the cost of one hit that
  goes through a debug event; the cost of one stack capture through
  `WalkRawFrames` at several depths.
- Run on the fixtures and on a large real binary. Static runs only against
  `Hydra2SingleEXE`. For dynamic runs, a real program that can run unattended:
  `DevTools\PrebuildIdx.exe` over a symbol directory, and the test runner
  itself with a filter.
- Exit: assumptions 1, 2, 8, 9, 10 and 17 answered with numbers. Assumption 9
  matters most here: it says how much of a coverage run will be counted and
  how much will read `1+`.

### Increment 1 — Is instrumentation feasible as designed

No engine change. One DevTool with hand-built patches on a fixture, both
bitnesses. It comes this early because coverage with hit counts, the thing
actually asked for, stands or falls with it.

- Relocation at `LOAD_DLL_DEBUG_EVENT` (assumptions 3 and 4). The test is
  vacuous on an image the kernel relocated before the event, which is any image
  with a dynamic base, and on x64, where Delphi code has almost no relocated
  fields. It needs a module without a dynamic base that collides, on x86, and
  the proof is an operand seen to change between the load event and the entry
  point.
- What has run at the first breakpoint event and at the entry stop, on both
  bitnesses (assumption 5).
- A fault sent back from a relocated instruction and from a payload:
  `try..except` and `try..finally` around it behave as in the plain run
  (assumption 6).
- An exception raised in a callee reached through a retargeted call, and
  through an indirect call re-encoded with a `nop`; the call-site test of a
  stack tracer on both (assumption 7).
- The unwinder (assumption 14): a jump patch on both shapes shown under "Never
  a jump where the system unwinder looks" is expected to break; a `$CC` and the
  call form in the same places are expected to work. The first half is the
  negative control for rule 6.
- Whether dbghelp reads code through the read routine it is given
  (assumption 16).
- A routine that the program itself hooks after it was patched.
- Exit: the install points, the fault redirect, call retargeting, rule 6 and
  the call form confirmed or redesigned.

### Increment 2 — Code map

- `ILineRecordProvider`, `IRoutineRangeProvider` on TD32 and `.tds`, then MAP,
  then JDBG. `TModuleCodeMap`. DevTool `CodeMapDump`.
- Tests: reader tests on the fixtures, both bitnesses, executable and package;
  every breakpoint marker of `TestTargetCore.pas` present as a line record with
  the routine the debugger already names for it.
- Exit: `PrebuildIdx -verify` unchanged (no sidecar format moved); the map of a
  large real binary built and its memory measured.

### Increment 3 — Scope

- The pattern grammar, the default scope, PACKAGEINFO membership in the core.
- Tests: unit tests of the grammar; the default scope on the mono and the
  package fixture.

### Increment 4 — Decoding and routine analysis

Ahead of the first probe, because no probe goes on a record the analysis has
not confirmed.

- `ZydisApi`: the fields the analysis and the relocator need, at offsets
  measured as `PROVENANCE.md` describes, pinned by tests on known encodings.
- `RoutineAnalysis.pas`: boundaries, branch targets, jump tables, handler
  entries on both bitnesses, call sites and return-address windows, exits,
  confirmed records.
- DevTool `RoutineAnalysisSweep`: over a whole binary, no two decoded
  instructions overlap, and the unconfirmed records and unfinished routines are
  listed with the reason.
- Exit: the sweep on large real binaries of both bitnesses, with both shares
  recorded.

### Increment 5 — The patch map and the one-shot form

- `TCodePatchMap`, `ICodePatchTarget` with the one-shot form only, the hooks
  listed under "In the event pump", and every raw reader of code moved onto the
  overlay.
- Tests, protocol-free (`DebugSessionTests.pas`), both bitnesses unless noted:
  - a fixture that records which of its own marked lines ran; the probes must
    agree with the program's own record, line for line;
  - a breakpoint and a probe on one address, planted in both orders, and the
    breakpoint removed before and after the probe fires;
  - step over, into and out across lines that have not fired; a step at an
    exception stop on x86, whose handler stub is read as code;
  - two threads released together through a long run of lines that have never
    executed, so that the race exists at every one of them and not once;
  - a trap that arrives after `profile_stop` restored its byte;
  - a line record that is the program's own `int 3`;
  - a package loaded, unloaded and loaded again (`TestPackage.bpl`);
  - an evaluation that executes probed lines leaves them unrecorded and armed;
  - attach, arm, detach: the program keeps running through armed lines; attach
    with `killOnDetach` false is refused without the explicit acceptance;
  - negative control for each hook: remove it and see its test fail.
- New fixture `DebuggerTests\TestTarget\ProfilerSample.dpr`, a `.dpr` of its
  own as `TRAPS.md` requires, built for both bitnesses.

### Increment 6 — Store and session registry

- `SqliteApi.pas`, `TProfileStore` with the dictionary and coverage tables,
  the registry (root, ids, names, default session, archives), accumulation,
  source identity.
- Tests: in-memory and on-disk databases; two different files of the same name
  kept apart; a database written by this code opened by the reference viewer,
  if the schema is to be shared (decision 4).

### Increment 7 — Coverage, stage 1, over MCP: which lines ran

- `TCoverageCollector` on one-shots, `TProfilerHost`, the `profile` launch
  option, `profile_start`, `profile_stop`, `profile_status`,
  `profile_sessions`, `coverage_summary`, `coverage_uncovered`,
  `profile_annotate_source`, `profile_report`. `McpProfilerTools.pas`. The
  `instructions` string.
- Tests in `McpE2ETests.pas`: mono, package and 32-bit. A collection started at
  the entry stop sees the `initialization` sections of the executable and of a
  statically required package; one armed at launch also sees the start-up of a
  statically imported DLL that is not a package. Both need fixtures the suite
  does not have: `TestHost.exe` loads its package at run time.
- Documents: `MCP_SERVER.md`, the tool counts in `README.md`,
  `WHAT_WORKS_WHERE.md` rows, `TEST_CATALOG.md`.

### Increment 8 — The collection lifecycle, complete

- `profile_run` and `profile_wait`; `appendTo`; `profile_snapshot`,
  `profile_clear`, `profile_pause`, `profile_resume`; archives; `coverage_diff`.
- The deferred-reply slot: `ArmWait` overwrites a pending wait without
  answering it. The new wait gets its own kind and a second wait-class call
  while one is pending is refused.
- Tests: two executables sharing units accumulated into one session; a run
  longer than `waitSeconds` observed to its end through `profile_wait`.

### Increment 9 — Relocation

- `InsnRelocator.pas`.
- Tests: differential over every instruction of a large binary. Relocate to
  another address, decode both, require the same instruction with the same
  absolute operands and targets. The decoder is the oracle; nothing is
  compared against expectations written by hand.

### Increment 10 — Trampolines in the engine

- `ICodePatchTarget` grows the counting forms: near allocation, the retargeted
  call, the jump, the call form, the `$CC`-entered form, install and withdraw,
  the fault redirect, address mapping, stepping through, the counting payload.
- Tests: the equivalence test first. A fixture that exercises loops, `case`,
  nested routines, exceptions through instrumented frames (raised below a call
  that is the last statement of a line, and of a routine), recursion, threads
  and a package prints a digest of what it computed; with a counting probe on
  every line it must print the same digest, on both bitnesses. Counts are
  checked against counters the fixture keeps itself. Then: a breakpoint on a
  site of each form, hit and resumed; steps across patched sites; a stop inside
  a trampoline; an evaluation on a thread paused inside a payload; detach.
- Real binary: `PrebuildIdx -verify` over a symbol directory, with a counting
  probe on every line, still verifies.

### Increment 11 — Coverage, stage 2: a hit count for every line

The coverage the owner asked for.

- `TCoverageCollector` chooses a form per line as described under "Coverage";
  `exactCounts`; `hits` in the store, in `profile_annotate_source` and in
  `coverage_summary`; pausing and clearing over counters.
- Tests: hit counts against the fixture's own counters, per line, including
  lines on the one-shot fallback (`1+`) and the same lines under `exactCounts`;
  a one-line loop, whose count is the entries into the line; mono, package and
  32-bit; a stage 1 database still opens.
- Exit: overhead measured on the real workloads and recorded, with the share of
  lines in each form.

### Increment 12 — Sampling

- First, the measurement the design waits for: a spinning thread pinned to a
  core, its cycle counter read from another at 1 ms; how many readings do not
  move (assumption 15).
- `IStackSampleTarget` (capture a raw stack from a running thread, the x86
  sampling walk), the pump's wait as a field and the timer resolution,
  `TSamplingProfiler`, the sample tables, `profile_hotspots`, `profile_flat`,
  `profile_tree`, `profile_callers`, `profile_callees`, `profile_threads`,
  per-line samples in `profile_annotate_source`.
- Tests, both bitnesses:
  - two busy routines in a known ratio, within a stated tolerance, never
    absolute counts;
  - one spinning thread has `excl_cpu` close to `excl`: the test that fails if
    the busiest thread is being skipped;
  - a blocked thread has wall samples and no CPU samples;
  - a frameless leaf called in a loop shows its framed caller above it;
  - no samples during a stop; a package frame is named.

### Increment 13 — Sampling at 1 ms

- The x64 walker and the sampler thread described under "Sampling". Built only
  if increment 12's numbers say the pump-thread sampler cannot hold the
  interval.
- Tests: differential against `StackWalk64` on x64, at every instruction of
  single-stepped runs through the fixtures — prologues, epilogues and leaves
  are where samples land and where stops never do. x86 has no independent
  oracle; its walk is checked against fixtures whose call chains are known.

### Increment 14 — Runtime, routine-level profiling

- The runtime, its delivery, thread contexts, entry and exit sites,
  `timing_stat`, `timing_tree`, `profile_timings`.
- Tests: call counts against the fixture's own; total and self time ordered as
  the fixture's known busy loops dictate; routines with managed locals and
  `try..finally`, whose inner `ret` must not close the frame; exits by
  exception counted; a thread created and ended during the collection; an
  evaluation on a thread paused inside the runtime.

### Increment 15 — Line-level time

- Timed line payloads on top of increment 14; `self` and `total` per line in
  `line_stat` and in `profile_annotate_source`.

### Later, in the order demand decides

Counting probes armed on an already running process (until then a collection on
an attached process uses one-shots); routine-bound triggers; compensation of
the probes' own cost; merged spans or short-jump islands if increment 11 shows
too many lines left without a count.

## Assumptions to measure

| # | assumption | settled in | if it is false |
|---|---|---|---|
| 1 | TD32 line records are instruction boundaries; the ones that are not are few and the analysis catches them | 0, 4 | nothing: unconfirmed records are never probed. It decides how much coverage that costs |
| 2 | a hit that goes through a debug event costs tens of microseconds | 0 | drain bursts of events without returning to the host loop |
| 3 | a `$CC` planted when a module is mapped survives the loader's relocation, and so does the saved original byte | 1, 5 | plant at the module's entry point as well |
| 4 | whether base relocations are applied before or after `LOAD_DLL_DEBUG_EVENT` | 1 | nothing: patches wait for the entry point either way. It says whether they could go in earlier |
| 5 | the first breakpoint event precedes any code of the main executable on both bitnesses, and at the entry stop no `initialization` section has run | 1, 7 | patch the main executable at its entry point; arm earlier |
| 6 | a fault sent back from a trampoline is dispatched as in the plain run | 1 | sites that can fault are entered through `$CC` and stepped in place |
| 7 | a retargeted call is indistinguishable from the original, to dispatch and to a stack tracer's call-site test; a re-encoded indirect call may or may not be | 1 | indirect calls are never touched |
| 8 | the jump tables dcc32 and dcc64 emit are all recognised | 0, 4 | routines with a `case` lose the records after the table |
| 9 | lines that can take a retargeted call, a jump or the call form are the large majority, and so are routine exits | 0, 11 | merged spans, short-jump islands; until then more lines read `1+` |
| 10 | a stack capture on the pump thread is cheap enough for the first interval | 0, 12 | increment 13 moves ahead of the sampling release |
| 11 | `winsqlite3.dll` is present and sufficient on every supported Windows | 6 | ship `sqlite3.dll` beside the server |
| 12 | executable memory can always be had within 2 GB of a module | 10 | that module's lines use the `$CC` forms |
| 13 | `rdtsc` is invariant and consistent across cores on supported machines | 14 | refuse timed modes with the reason |
| 14 | on x64 a `jmp` patch inside the window of a return address makes the system unwinder take the frame for one in its epilogue; a `$CC` or a `call` there does not | 1 | if a jump is harmless after all, rule 6 goes and the call form is not needed |
| 15 | a thread's cycle counter moves while the thread runs on another core between context switches | 12 | suspend every thread whose last sample was not a wait |
| 16 | dbghelp reads code through the read routine it is given, not from the image file | 1 | nothing to do if it reads the file: it then never sees a patch |
| 17 | a TD32 procedure range covers the routine's funclets and clause tables | 0 | attribute them through the scope tables |

## Accepted limits

- **Line coverage only.** No branch or condition coverage.
- **A hit count is exact where a counting probe fits and `1+` elsewhere,**
  unless the collection asks for `exactCounts`.
- **Code the linker removed does not exist.** A routine nothing references has
  no line records, so it is neither covered nor uncovered and the percentage
  does not see it. Step 2 can take the denominator from the production
  executable instead of from the test executable.
- **Inlined routines** are measured as lines of their caller. A routine-level
  figure for them does not exist.
- **Before attach is unknown.** A collection on an attached process starts at
  the attach.
- **Elapsed time, not CPU time,** in the instrumenting modes. The sampling
  modes have both.
- **Stops and evaluations disturb a collection that counts or times.** They are
  counted and reported, not corrected.
- **No triggers in step 1.** A breakpoint plus `profile_resume` and
  `profile_pause` does the same job from an agent.
- **A module without TD32, MAP or JDBG is not measured.**
- **Memory.** Every patched code page becomes private to the process, and each
  probed line costs a trampoline. On a 32-bit target a wide scope competes
  with the program for address space.
- **A program that copies or inspects its own code sees the patches.** A copied
  `$CC` traps at an address nobody can map back; a stack tracer inside the
  program that samples a thread parked on a patch can misread that one frame.
  The remedy is to exclude the routine from the scope.
- **No call form on a process with hardware shadow stacks enabled.** It returns
  to an address no call pushed. Those sites fall back to the `$CC` forms.

## Not chosen

- **One-shot breakpoints as the design of coverage.** Proposed first, turned
  down by the owner: they answer "ran or not", and the reference answers "how
  many times". Kept as the fallback and as stage 1 only.
- **Displacing a call and emulating it** (push the return address, jump). It
  leaves bytes that are not a call in front of a return address, which the
  program's own stack tracers and the engine's x86 walker both check, and it
  unpairs the processor's return prediction. Calls are retargeted instead.
- **A second build with instrumentation compiled in.** It is another binary
  than the one being shipped and debugged, it cannot be attached to, and Delphi
  has no such option to lean on.
- **Counting with ordinary breakpoints** (restore, single step, plant again).
  Two debug events per hit, and while the byte is restored other threads run
  through the line uncounted.
- **Replacing the return address to catch routine exit.** The unwinder and the
  exception dispatch read that address.
- **A log of events aggregated by the debugger.** A hot loop outruns it.
- **ETW sampling.** Administrator rights, a system-wide session, and nothing
  shared with the engine.

## Decisions for the owner

1. **Release coverage stage 1 on its own?** After increment 8 a coverage
   session tells which lines ran and nothing more. The code is needed either
   way; the question is only whether it ships before increment 11 gives it hit
   counts. Recommended: yes, it already answers "what is untested".
2. **Lines that cannot take a cheap counting probe** read `1+` by default, with
   `exactCounts` on request. The alternative is exact always, at one debug
   event per pass through such a line.
3. **Sampling after coverage has its counts**, as planned here, or before the
   trampoline work (increments 12 and 13 moved ahead of 9)? It is independent
   and small.
4. **Share the schema with the reference profiler**, so its Delphi viewer
   (`gui\NapGui.dpr` there) can open a native session? This plan assumes yes
   for table and column names; reading a native database there is a change in
   that repository.
5. **SQLite from Windows (`winsqlite3.dll`)** rather than FireDAC in the server.
   This plan assumes yes: no build dependency and nothing added to the
   executable.
6. **Text tables for query tools** while the rest of the server answers in
   JSON. This plan assumes yes.
7. **The runtime as a DLL loaded into the target**, as now preferred, or mapped
   by the debugger without the loader knowing. Open until increment 1 has
   reported; needed by increment 14.
8. **The default scope** is the source root of the session. A project whose
   units live in several trees then needs `include` every time, unless the
   default is widened to the project's own search paths as DDK reports them.
