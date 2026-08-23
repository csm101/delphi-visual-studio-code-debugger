# Exception-handler scope — plan

Status: **increments 1 and 2 DONE. Increment 3 open.** Spec'd 2026-08-23 from a live MCP repro against
`Debugme.exe` and `TestTarget.exe` (not guessed — see the table below). User-
requested: today's `$exception`/`on E:` behavior in an exception handler reads
as a bug wearing a "by design" comment, not an actual design choice.

The ask, restated as acceptance criteria: while stopped anywhere lexically
inside an exception handler,

1. the exception object must be inspectable **without typing anything into
   Watch** — it must already be a row in Locals;
2. if the handler aliases it (`on E: Exception do`), it appears in Locals
   **under that alias name**, for as long as the stop is inside that clause;
3. if the handler does **not** alias it (bare `except .. end`), it appears in
   Locals as **`$exception`** instead — mutually exclusive with (2), never
   both for the same handler;
4. either one stays valid for **every** stop while still lexically inside the
   handler, not only at the instant of the original raise/break;
5. both are usable inside **arbitrary expressions**, specifically a
   conditional breakpoint's condition.

## What was verified today (2026-08-23, live MCP, not assumed)

| capability | today |
|---|---|
| `on E:` alias in Locals, inside an ordinary procedure | **works** — `TestTargetCore.pas` `RunExceptionHandlerProbe`, stop at `{BP:EXC_HANDLER}` (line 1921, one line *past* the raise): `get_locals` lists `E` as a normal expandable `Exception` local. |
| `on E:` alias in Locals, inside the **program's main block** | **BROKEN** — `Debugme.dpr` line 103 (`on E: Exception do Writeln(E.ClassName, ...)`, a plain breakpoint one line past the raise): `get_locals` returns only `localdata` and `foo`. `evaluate_expression("E")` resolves it correctly in the same stop (`$…7760 (Exception)`, expandable) — so the *value* is reachable, only the automatic Locals listing misses it. |
| `E` (or any alias) as an arbitrary expression / breakpoint condition | Already works wherever `E` resolves as an ordinary local — i.e. everywhere except the main-block case above. |
| `$exception` populated at the **initial** exception stop (first/second-chance break) | **works** — `DebugTarget.CurrentExceptionObject`. |
| `$exception` still valid after continuing **past** that stop, while still inside the same handler | **BROKEN** — repro: stop on the raise (line 99) → `continue` → stop on a plain breakpoint one line into the `on E:` block (line 103, still inside the handler) → `$exception` is already `<no current exception>` in the Watch view. |
| `$exception` as a general expression (e.g. a breakpoint condition) | **BROKEN**, unconditionally — `evaluate_expression("$exception")` fails to parse: `"unexpected token at 3: \"xception\""`. Works today only because the DAP Watch panel special-cases the literal string `$exception` before it ever reaches the expression parser. |

Repro commands used (for whoever picks this up — re-run to confirm before
changing anything):

```
launch_debuggee  Win64\Debug\Debugme.exe, stopAtEntry
set_breakpoints  Debugme.dpr:103
continue_and_wait   -> stops on the raise itself (line 99, stopReason=exception)
continue_and_wait   -> stops on the breakpoint (line 103, stopReason=breakpoint)
get_locals          -> localdata, foo only; no E
evaluate_expression("E")           -> resolves fine
evaluate_expression("$exception")  -> parse error
```

```
launch_debuggee  DebuggerTests\TestTarget\Win64\Debug\TestTarget.exe,
                 args="--run-exception-handler", exceptionFilters=["unhandled"]
set_breakpoints  TestTargetCore.pas:1921   ({BP:EXC_HANDLER}, inside RunExceptionHandlerProbe)
continue_and_wait -> stops there
get_locals        -> E present, expandable Exception
```

## Increment 1 — `on E:` alias in Locals inside the program main block

**DONE.** What follows is the plan as written, then what measuring it actually
found. The two disagree, and the second one is the truth.

### What it turned out to be

The RSM is not involved and never was. `dcc` does not give a main-block `on E:`
alias a stack slot at all: it allocates a **module-level static** — measured,
`_ZN7Debugme1EE` at RVA `$44FC8`, an LDATA32 sitting immediately after the
program's own `Debugme.data` / `Debugme.x` globals, with no lexical scope in
TD32 and no record in the RSM main-block table. `dcc32` does the same
(`@Testtarget@E`), so this is not bitness-specific either. To every symbol
reader the alias is therefore a program-wide global and not a local of the
block — which is exactly why `evaluate E` answered in the repro while
`get_locals` did not, and why "give `CollectMainBlockLocals` a scope walk" would
have searched for a record that does not exist.

What made it fixable was a different measurement: the routine's own scope table
states the handler block's extent exactly (the compiler-generated `try..finally`
that calls `@DoneExcept` wraps the block, and it has a scope entry of its own),
and the block's FIRST instruction is the store of the exception object into the
alias slot — `48 89 05 <disp32>` for a static, `48 89 45/85 <disp>` for the
ordinary stack case. Both are now written up in `EH_FORMAT_NOTES.md`.

So the shipped shape is: locate the `on`-clause block from `.pdata` →
`UNWIND_INFO` → scope table → clause table, decode the store to learn the slot,
name it from the globals table, and publish it as a Locals row for the block's
extent and no further. `TWinDebugger.TryGetExceptHandlerBlockAt` /
`TryGetHandlerAliasLocal`. x86 declines (no `.pdata`, so no block extents);
a handler inside a PROCEDURE was already correct on both bitnesses and has a
regression test now.

Requirement 5 fell out for the aliased case and was verified rather than
assumed, in BOTH directions: a `E.Message = 'main-aliased'` condition lets the
breakpoint through, and a condition naming the wrong message swallows it (so a
condition that merely failed to evaluate could not pass the test).

### The plan as written (premise refuted, kept for the record)

**Root cause, found not guessed:** `RsmFileReader.pas`,
`TRsmFile.CollectMainBlockLocals` (~line 1389). Unlike the per-procedure
locals path (`TryParseProcedureAt`, ~line 2199), this one does a **flat byte
scan for `$20`/`$46` "VAR record" shapes across the entire main-block RSM
data**, with no PC-range or lexical-scope awareness at all. It only ever
finds top-level `var`-section declarations — which is exactly the set that
already works (`localdata`, `foo`, and the `TheWidget`/`TheStuff` case the
RSM-main-block-locals work already documented in `TestTarget.dpr`'s driver
comments). A compiler-synthesized `on E:` local, scoped to a nested
`try/except` inside that same main block, is invisible to a flat scan with no
notion of "which block is this record inside."

**Direction to investigate** (not prescribed — verify before committing to
it): give locals-listing for a main-block stop the same PC-range-aware scope
walk that `TryParseProcedureAt` already applies correctly for ordinary
procedures — reuse that logic rather than re-deriving it, since the
procedure-scope case (see repro above) already gets this right. Whether that
means teaching `CollectMainBlockLocals` about nested scope offsets, or routing
main-block locals-listing through the same walker procedures already use,
is an implementation call — measure both before picking.

This increment also closes requirement 5 for the aliased case as a side
effect: `evaluate_expression` already resolves `E` correctly wherever the
debug info places it, so a breakpoint condition like `E.Message = 'x'` should
start working the moment `get_locals` does. **Verify this explicitly with a
conditional-breakpoint test — do not assume it falls out for free.**

## Increment 2 — `$exception` live for the whole handler, not just the initial stop

**DONE.** The plan below was right about the mechanism; two things it flagged as
unverified came back with answers.

- The RTL entry point is `System.ExceptObject`, confirmed against the shipped
  System.pas (`TABLE_BASED_EXCEPTIONS` branch: it returns
  `RaiseListPtr^.ExceptObject`) and present as a public symbol in a Win64 and a
  Win32 Delphi binary. `AcquireExceptionObject` is the wrong one -- it TAKES
  ownership of the object, which a debugger must never do to a running program.
  The threadvar cannot be read directly: it lives in Delphi's own TLS block at
  an offset no symbol carries, so the value is fetched by CALLING the routine.
- Which copy of it matters, and this was not anticipated. A process split into
  runtime packages holds the RTL in `rtl<version>.bpl` while a statically-linked
  exe has a second one, and the two do not share a raise list. Resolving by name
  in the BPL scenario found `TestHost.exe`'s static copy and it answered nil for
  an exception being handled inside the package -- a confident wrong answer, and
  the core use case of this project. Fixed by resolving in the module the
  handler is executing in and falling back to that module's EXPORT DIRECTORY,
  which is the only thing that still names a routine in a package shipped
  without debug information (`TWinDebugger.TryResolveExportedRoutine`).

Also measured, and it is why the RTL is involved at all: a bare `except` stores
the exception object NOWHERE. Its block's first instruction is a `nop` on both a
main block and a procedure; `RAX` holds the object on entry and is simply
dropped. Written up in `EH_FORMAT_NOTES.md`.

The gate is the block locator increment 1 built, restricted to
`ehbBareExcept` -- which is what makes requirement 3's exclusion structural
rather than a rule someone has to remember. x86 refuses with a reason naming the
limitation; `Win32_BareHandlerException_RefusesWithAReason` asserts both halves
against an x64 control at the same marker.

### The plan as written

Applies only to the **unaliased** case (bare `except .. end`, no `on`) — once
increment 1 lands, the aliased case is already correct for the handler's full
lexical extent for free, because `E` is just an ordinary local with the
ordinary local's scope lifetime, not something that needs separate tracking.

Today, `DebugTarget.CurrentExceptionObject` returns a value captured at the
raw exception debug event and goes to 0 the instant execution resumes,
regardless of whether the new stop is still lexically inside the same
handler. That is the thing to stop doing.

**Investigate:** the RTL's own per-thread "currently handled exception"
bookkeeping — the mechanism a bare `except` block with no `on` clause already
relies on when it calls `ExceptObject`/`AcquireExceptionObject` to get the
object without an alias. That is a live, always-correct source of truth for
exactly as long as the thread is really inside the handler, which is what
requirement 4 asks for — much more directly than trying to keep the original
raw exception-stop data alive across further stops. It could be read live via
the same function-call-evaluation machinery the adapter already has
(`KNOWN_UNKNOWNS.md` notes implicit function evaluation as a settable
behavior — start there for the mechanism). **Confirm the exact RTL entry
point, its owning unit, and its signature before relying on it — the name
above is the general shape of the API, not a verified fact; do not commit
code against an unconfirmed symbol.**

Gate **when** `$exception` is offered/synthesized using the x64 EH scope
table, already fully reverse-engineered in `EH_FORMAT_NOTES.md`: a scope
entry with `Handler = 1` or `Handler = 2` gives `[Target, <block end>)` as the
bare-except block's range. Only synthesize `$exception` in Locals when the
stopped PC falls inside one of those ranges for the current frame's function
— and only when there is **no** clause table (`Handler > 2` means an `on`
clause exists; that's increment 1's territory, not this one, and the two must
stay mutually exclusive per requirement 3).

`EH_FORMAT_NOTES.md` already states x86 cannot derive a handler-block address
for `@HandleAnyException` at all (no `.pdata`, and the `fs:[0]` stub's target
is the RTL dispatcher, not the block). **This increment is x64-only until
that changes.** Make the adapter say so on x86 rather than silently doing
nothing — a Watch/Locals row that just never appears, with no explanation,
is indistinguishable from a bug from the outside.

## Increment 3 — `$exception` as a parseable expression token

Separate, narrower bug, independent of whether an exception is actually
active right now: `evaluate_expression("$exception")` fails to parse at all
(`"unexpected token at 3: \"xception\""`). The `$` prefix is being claimed by
hex-literal lexing before anything gets a chance to recognize `$exception` as
a distinct pseudo-identifier. Find the expression lexer/parser (start in
`DebuggerCore\ExprEval.pas` and `DebuggerCore\VariableExpander.pas`) and make
`$exception` a token in its own right, checked before hex-literal parsing
claims the `$`.

This is what makes `$exception` usable in a **breakpoint condition**, not
only inside the DAP Watch panel's own special-cased interception path (which
is why it silently "works" there today despite the parser bug). Depends on
increment 2 for the *value* once parsed correctly; the parsing fix itself can
be built and tested independently of increment 2 (a fixed/stubbed VA is
enough to prove the token round-trips).

## Acceptance criteria

- Extend `Debugme.dpr` (per `CLAUDE.md`: "extend Debugme whenever needed to
  validate new debugger features" — do not rely on `TestTarget` alone, since
  the bug that matters most is main-block-specific and `TestTarget`'s
  `RunExceptionHandlerProbe` deliberately lives inside a procedure) with, in
  the program's main block: a bare `except .. end` (no `on`) **and** an
  `on E:` clause, each with a plain breakpoint a couple of lines into the
  handler body — not on the raise line, and not on the handler's first line,
  so the test actually exercises "still valid after continuing past the
  stop", not just "valid at the moment of the stop".
- At that stop, `get_locals` shows `E` (aliased case) or `$exception` (bare
  case) — **never both** for the same handler.
- `evaluate_expression("$exception")` and `evaluate_expression("E.Message")`
  both succeed at that stop.
- A conditional breakpoint using each as its condition actually gates on the
  real value (e.g. `E.Message = 'Test error'` only fires on the matching
  raise).
- Re-run the same four checks inside an ordinary procedure afterward — the
  procedure case already works today (see repro table); the point is to
  prove increments 1–3 did not regress it.
- Full suite green: `cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_and_run.bat" 2>&1`.
  Add new tests following the existing except-handler patterns —
  `DebuggerTests\BugRegressionTests.pas`, `DebuggerTests\DebuggerTests.pas`
  around line 3936 (`Test_Hover_ExceptionInHandler_Expandable`), and
  `DebuggerTests\TestTarget\TestTargetCore.pas`'s `RunExceptionHandlerProbe`
  are the closest existing anchors.
- x86: at minimum, confirm and explicitly document current behavior for
  increment 2 (it cannot reach parity per `EH_FORMAT_NOTES.md` — say so, do
  not claim otherwise). Increments 1 and 3 are not bitness-specific; verify
  both bitnesses for those.

## Traps already known and load-bearing here

- `EH_FORMAT_NOTES.md`: never decode a scope entry's `Handler` as a Delphi
  clause table without first checking the language handler is
  `_DelphiExceptionHandler` — under MSVC's `__C_specific_handler` the same
  field is a filter function, and every `ntdll`/`kernelbase` frame will look
  like one if this check is skipped.
- `EH_FORMAT_NOTES.md`: never plant a breakpoint on a `Handler` field that
  **is** a clause-table RVA — it overwrites the table's `Count` and derails
  dispatch. Only decoded block addresses are plantable. (Irrelevant to this
  plan directly, but the scope-table reader used for increment 2 is the same
  one that trap already bit once.)
- `EH_FORMAT_NOTES.md`: a bare except's `Target` equals the scope entry's
  `End`, and the **line table** attributes that address to the last line of
  the `try` body, not to the `except` statement. Don't let that mislead the
  "is PC inside the handler" range math in increment 2 — it is still the
  correct first instruction of the handler, only the line record is coarse.
- `KNOWN_UNKNOWNS.md`, "F16, `get_locals` disagreeing with `evaluate` on an
  `on E:` local" was closed as **does not reproduce** — but that
  investigation was a first-chance-stop garbage read inside an *ordinary
  procedure*, a different bug from the one this plan opens (main-block
  scope, not garbage-slot timing). Don't let this plan's increment 1 get
  read as reopening F16 — it isn't the same bug, and F16 stays closed.
