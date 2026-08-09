# Delphi exception-dispatch data

Where a Delphi binary records "this range of code is protected, and here is the
block that receives an exception raised inside it", on both bitnesses, and which
parts of it a debugger can read.

Everything here was **measured** against live debuggees with
`DevTools\ExcHandlerProbe.exe` (fixture `DevTools\Fixtures\ExcNestFixture.dpr`,
built for both bitnesses by `DevTools\build_exc_fixture.bat`). The probe's
`-plant` mode is what turns a decoded address into a fact: it plants an `INT3`
on every candidate, resumes with `DBG_EXCEPTION_NOT_HANDLED`, and reports which
one is actually reached.

This is the reference for `TWinDebugger.PlanExceptionStep` (x64) and
`TWin32Debugger.PlanExceptionStep` (x86); see
`DAP_DEBUGGER_ARCHITECTURE.md` → "Stepping at an exception stop" for what the
debugger does with it.

## The trap flag is not a stop mechanism here

At a first-chance exception stop, arming `EFLAGS.TF` and resuming with
`DBG_EXCEPTION_NOT_HANDLED` does **not** give you a single-step event to follow
the dispatch with. Measured, two runs each, the write to `EFLAGS` read back as
having taken in every case:

| target | exception | resume | next debug event |
|---|---|---|---|
| x64 | Delphi raise `$0EEDFADE` | deliver | **none** — ran through the finally and the except to exit |
| x64 | Delphi raise | swallow (control) | single step at the stop RIP + 5 |
| x64 | access violation | deliver | **none** |
| x86 WOW64 | Delphi raise | deliver | `STATUS_WX86_SINGLE_STEP` at `ntdll32!KiUserExceptionDispatcher+1` |
| x86 WOW64 | Delphi raise | swallow (control) | single step at the stop EIP + 4 |
| x86 WOW64 | access violation | deliver | **none** |

The `swallow` rows are the control: same stop, same thread, same arming code,
only the continue status differs — so the absence of a step with `deliver`
isolates the dispatch path rather than the arming.

Consequence: **"deliver the exception and watch where we land" does not exist as
a design.** A one-shot breakpoint planted at the handler block is the only
mechanism, which is why the block address has to be *derived* rather than
observed.

## x64 — the handler address is derivable exactly

The chain, all of it read out of the debuggee's own mapped image (never the file
on disk, so a relocated module is described correctly):

1. **`RUNTIME_FUNCTION`** for the frame's PC. `.pdata` is
   `DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION]`, an address-ordered array of
   `{ BeginAddress, EndAddress, UnwindData }` DWORD RVAs — binary-searchable.
   The engine gets it from `SymFunctionTableAccess64` instead, which is the same
   table via dbghelp.
2. **`UNWIND_INFO`** at `ModuleBase + UnwindData`:
   `Version:3 | Flags:5` byte, `SizeOfProlog` byte, `CountOfCodes` byte,
   `FrameRegister:4 | FrameOffset:4` byte, then `((CountOfCodes + 1) and not 1) * 2`
   bytes of unwind codes — the array is padded to an EVEN number of 2-byte slots.
3. After the codes:
   - `UNW_FLAG_EHANDLER ($01)` or `UNW_FLAG_UHANDLER ($02)` → a DWORD
     **LanguageHandler RVA**, then that handler's own data;
   - `UNW_FLAG_CHAININFO ($04)` → a `RUNTIME_FUNCTION` to follow instead;
   - neither → **this routine cannot receive the exception**.
4. dcc64 emits `_DelphiExceptionHandler` as the language handler, and an
   MSVC-shaped **scope table** as its data:

   ```
   DWORD Count;
   Count x { DWORD BeginRva; DWORD EndRva; DWORD Handler; DWORD Target }
   ```

   Delphi overloads the third field:

   | `Handler` | construct | where the block is |
   |---|---|---|
   | `0` | `try .. finally` | `Target` is the finally funclet |
   | `1` or `2` | bare `except` (no `on` clause) | `Target` is the block |
   | `> 2` | `except` with `on` clauses | `Handler` is the RVA of a **clause table**; `Target` is 0 |

   The clause table is `DWORD Count; Count x { DWORD ClassVmtRva; DWORD BlockRva }`,
   where each `BlockRva` is the address of that `on <Class> do` block.

**Frame selection.** Verified on four routines: only the scope entry whose
`[Begin, End)` contains the frame's own PC can receive this exception. For
frames above 0 the "frame's own PC" is the **return address** — which is what
`StackWalk64` reports for those frames anyway.

**Measured examples** (`ExcNestFixture`, Win64, Delphi raise):

```
#4 Level2Finally    UNWIND_INFO flags=UHANDLER   scope[0] Begin=$2B7E0 End=$2B7EB
                    Handler=0  Target=$2B800  -> ExcNestFixture.dpr:63  (the finally)
#5 Level1Except     UNWIND_INFO flags=EHANDLER|UHANDLER
                    scope[0] Begin=$2B853 End=$2B865 Handler=$2B880 Target=0
                    clause[0] vmt=$1B238 block=$2B866 -> ExcNestFixture.dpr:84
#5 Level1BareExcept scope[0] Handler=$00000002 Target=$2B8C5 -> ExcNestFixture.dpr:95
#5 Level1TwoClauses clause[0] vmt=$1D230 block=$2B916 -> :108   (EAccessViolation)
                    clause[1] vmt=$1B238 block=$2B92B -> :110   (Exception)
```

Two attribution details that look like bugs and are not:

- A clause block's first instruction is attributed to the **`on` line**
  (`:84`, `:110`), not to the statement inside the block.
- A bare `except`'s `Target` equals the scope entry's `End`, and the line table
  attributes that address to the **last line of the `try` body** (`:95`), not to
  the statement in the `except`. It is still the first instruction of the
  handler; only the line record is coarse.

## x86 — partial, and the negative half is load-bearing

There is no `.pdata` on a 32-bit target. The dispatch data is the `fs:[0]`
registration chain, walked innermost-first.

**Reaching it.** `Wow64GetThreadSelectorEntry` on the thread's own `FS`
selector, falling back to `TEB64 + $2000` (the fixed WOW64 layout) — *verified*,
not assumed, by reading `TEB32 + $18` (`Self`) back and requiring it to point at
itself. The `TEB64` comes from
`NtQueryInformationThread(ThreadBasicInformation)`, which must be passed
**exactly 48 bytes** (`ExitStatus` + pad 8, `TebBaseAddress` 8, `ClientId` 16,
`AffinityMask` 8, `Priority` + `BasePriority` 8); any other length returns
`STATUS_INFO_LENGTH_MISMATCH` and the fallback silently never works.

**The records.** `{ DWORD Next; DWORD Handler }`. A Delphi record's `Handler`
does not point at RTL code: it is an `E9 rel32` **stub inside the protected
routine**. The stub's jump target names the construct:

| stub jumps to | construct | table? |
|---|---|---|
| `@System@@HandleOnException` | `except` with `on` clauses | **yes**, at `stub + 5` |
| `@System@@HandleFinally` | `try .. finally` | **no** |
| `@System@@HandleAnyException` | bare `except` | **no** |

The clause table at `stub + 5` has the same shape as the x64 one but holds
**absolute VAs, not RVAs**: `DWORD Count; Count x { DWORD ClassVmtVA; DWORD BlockVA }`.

**Measured** (`ExcNestFixture`, Win32, Delphi raise, default arguments):

```
[0] record@$7FF868 Handler=$32E210 -> Level2Finally (:63)
    E9 63 84 FE FF  -> @System@@HandleFinally      no table
[1] record@$7FF880 Handler=$32E248 -> Level1Except (:82)
    E9 A3 82 FE FF  -> @System@@HandleOnException  clause[0] vmt=$324004 block=$32E259 -> :84
[2] record@$7FF8AC Handler=$316904 -> @System@@ExceptionHandler   (RTL, no source line)
[3..4] ntdll handlers
```

So for `@HandleFinally` and `@HandleAnyException` **the block address is not
derivable at all** — only the stub is. And a hit on the stub is the SEH **search
pass**: it fires before that frame is known to receive the exception and before
the block runs, unlike x64 where the block executes only if it really executes.
The stub's address does resolve to the `finally`/`except` line through the line
table, which makes stopping there *look* right; it names the wrong execution
phase.

## Two traps

- **Never decode a scope entry's `Handler` as a Delphi clause table without
  first checking that the language handler is `_DelphiExceptionHandler`.** Under
  MSVC's `__C_specific_handler` the same field is a **filter function** and the
  decode yields confident nonsense. Every `ntdll` / `kernelbase` frame in any run
  is one of these.
- **Never plant a breakpoint on a `Handler` field that IS a clause-table RVA.**
  The `$CC` overwrites the clause `Count` and derails dispatch. Only *decoded
  block addresses* are plantable. (This already contaminated one probe run.)
