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

### Where a handler block ENDS

The scope table names a block's first instruction and never its last. The end is
still exact, because dcc wraps every handler BODY in a compiler-generated
`try .. finally` -- that finally is what calls `System.@DoneExcept` -- and that
wrapper has a scope entry of its own. So:

> a handler block's extent is `[BlockRva, End)` of the **narrowest** scope entry
> of the same routine that covers `BlockRva + 1`.

The `+ 1` is what makes the bare form work: a bare `except`'s block address is
the previous entry's EXCLUSIVE `End`, so the block address itself is not inside
the wrapper, while the byte after it is.

Measured on `Debugme.dpr`'s main block (7 entries, abridged):

```
[0] Begin=$2FC09 End=$2FCCD Handler=$2FE30 Target=0      try body, clause table
      clause[0] vmt=$1D748 block=$2FCCE                  the `on E:` block
[1] Begin=$2FCCE End=$2FD6F Handler=0      Target=$2FE40 wrapper for that block
[2] Begin=$2FD70 End=$2FD90 Handler=2      Target=$2FD90 bare try; block = End
[3] Begin=$2FD91 End=$2FDF7 Handler=0      Target=$2FE50 wrapper for THAT block
```

so the `on E:` block is `[$2FCCE, $2FD6F)` and the bare one `[$2FD90, $2FDF7)` --
entries `[4]` and `[5]`, the routine-wide finally and except, cover both and lose
to the narrower ones.

If no entry covers `BlockRva + 1`, the end is NOT derivable and the caller must
decline. Widening to the end of the routine would keep a handler-scoped name
alive past its own block, which reads as a live variable and is a dangling one.

### A bare `except` keeps the object NOWHERE

The table above has no row for a bare `except .. end`, and that is the finding,
not an omission. Measured on both a program main block and an ordinary
procedure, the block's first instruction is a `nop`: `RAX` still holds the
exception object on entry and the compiler simply does not store it. There is no
slot to read and no name to read it under.

```
$2FD90  90                      nop                     ; Debugme.dpr:112   (main block)
$2B8C5  90                      nop                     ; ExcNestFixture.dpr:95 (procedure)
```

So for a bare handler the exception exists, for a debugger's purposes, only on
the RTL's own per-thread raise list -- `RaiseListPtr`, pushed by the handler
prologue and popped by `System.@DoneExcept`. `System.ExceptObject` returns
`RaiseListPtr^.ExceptObject` and is the only always-correct source: it is right
under nesting, and it goes empty exactly when the handler ends.

Reading `RaiseListPtr` directly is not an option -- it is a threadvar in
Delphi's own TLS block at an offset no symbol carries -- so it is reached by
CALLING `System.ExceptObject` in the target.

**Which copy of it.** A process can hold more than one RTL, and they do not
share a raise list: an exe that links the RTL statically has its own, while a
package that `requires rtl` uses the one in `rtl<version>.bpl`. Calling the
wrong copy reads an empty raise list and reports, with complete confidence, that
nothing is being handled -- measured on `TestHost.exe` + `TestSubject.bpl`,
where the host's static copy answers nil for an exception being handled inside
the package. The copy in the module the HANDLER is executing in is the right
one. When that module has none of its own -- the packaged case, and `rtl290.bpl`
ships without debug information -- the export directory still names it:

| bitness | export name in `rtl290.bpl` |
|---|---|
| x64 | `_ZN6System12ExceptObjectEv` |
| x86 | `@System@ExceptObject$qqrv` |

### The `on` alias, and where the compiler puts it

`on <X>: <Class> do` allocates X, and the block's FIRST instruction stores the
exception object (in `RAX`) into it. That instruction is how a debugger learns
which slot X is:

| first instruction of the block | where the alias lives |
|---|---|
| `48 89 45 xx` / `48 89 85 xx xx xx xx` (`mov [rbp+disp], rax`) | an ordinary stack local -- every symbol reader already lists it |
| `48 89 05 xx xx xx xx` (`mov [rip+disp32], rax`) | a module-level static at `BlockRva + 7 + disp32` |

The second row is not an optimisation artifact: it is what dcc emits for a
handler in a **program main block**, on both bitnesses. Measured, `Debugme.dpr`
line 102 -> `48 89 05 F3 52 01 00` -> RVA `$44FC8`, which TD32 carries as the
LDATA32 `_ZN7Debugme1EE`, sitting immediately after the program's own
`Debugme.data` and `Debugme.x` globals. `dcc32` does the same
(`@Testtarget@E`). The static has **no lexical scope in TD32 and no record in
the RSM main-block table at all**, so to every symbol reader the alias is a
program-wide global and not a local of the block -- which is why `evaluate E`
answered there long before `get_locals` listed it.

Consequence for a debugger: the alias of a main-block handler can only be
surfaced by locating the block first and reading the store, and it must be
withdrawn again at the block's end. Standing ON the block's first instruction is
also outside its lifetime -- the store has not retired, and the slot still holds
a pointer to the PREVIOUS exception, which was freed when its handler finished.

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
