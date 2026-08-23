## What's new

New in 0.6.3:

- **The exception you are looking at is now in the Variables panel.** Stop anywhere inside an `except` block and the exception being handled is a **Locals** row — under the handler's own name where it has one (`on E: Exception do`), as **`$exception`** where it does not (a bare `except .. end`). Before, it was there only at the instant of the raise and vanished at the next breakpoint.
- **`$exception` works in expressions and in breakpoint conditions.** `$exception.Message` in Watch, and conditions such as `$exception.Message = 'ORA-00942'`, now parse. They never had.
- Fixed: an `on E:` handler written in a program's `begin .. end.` block never listed `E` in Locals, although a watch on the same name answered.
- On a 32-bit target the two handler-scoped features say plainly that they cannot work there, instead of showing nothing.

---

## What each of these means

### The exception is in Locals for as long as the handler runs

Stopping inside an exception handler is the normal way to look at an exception: you set a breakpoint a few lines into the `except` block, or you continue from the raise and land there. Until now that was the one place the exception object was *not* reachable.

`$exception` was populated only at the exception stop itself. Continue past it — still inside the same handler, still holding the same object — and it read `<no current exception>`. The workaround was to stop on the `raise` line instead, which is often deep in the RTL or in a package with no debug information, where there is no useful frame to select.

Now the object is available for the whole lexical extent of the block, and it is presented under the name your source uses:

- `on E: Exception do` — the row is called **`E`**, expandable like any object.
- `except .. end` with no `on` — the row is called **`$exception`**, because your code gave it no name.

Never both for one handler: one object under two names in a single Locals scope reads as two variables. And when execution leaves the block the row goes away, rather than lingering as a pointer to an object the runtime has already freed.

### `E` inside a program's `begin .. end.`

An `on E:` handler written in the program's main block never listed `E` in Locals, while a watch on `E` in the very same stop answered correctly — the kind of disagreement that makes you distrust both panels.

The cause was not a missing lookup: the compiler does not give a main-block handler alias a stack slot at all. It allocates it as a module-level variable, so every symbol reader in the debugger classified it as a program-wide global and none of them classified it as a local of that block. The debugger now finds the handler block in the binary's own exception-dispatch tables, reads which variable the block stores the exception into, and lists it — for that block only.

### `$exception` in expressions and conditions

`$` opens a hexadecimal literal in Pascal, and `$e` is a valid one, so the expression parser used to consume the first two characters of `$exception` and report the rest as a syntax error. The name appeared to work only because the Variables panel recognised that exact string before the parser ever saw it.

Anything else did not. `$exception.Message` failed. A **breakpoint condition** — which the adapter evaluates with no panel involved, and which is the main reason to want the name at all — failed. Both work now, along with `$exception is EMyError` and the rest of the expression language.

### 32-bit targets say so

Locating a handler block means knowing where it begins and ends, and a 32-bit binary carries nothing that states it — there is no `.pdata`, and the `fs:[0]` chain answers a different question. Rather than guess a range and show a value that might belong to a previous exception, Win32 declines and names the limitation when you ask for `$exception`.

An `on E:` handler inside an ordinary procedure is unaffected on both bitnesses: there the alias is a normal local and always was listed.

---

1,301 tests, 1,297 passing, 4 ignored, on both Win32 and Win64 targets.
