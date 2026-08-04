# What works where

A per-configuration account of what this debugger can and cannot do, across two
axes the field actually varies along:

* **shape** — a monolithic executable built entirely with debug information, vs.
  an application that loads runtime packages at run time, some of which carry no
  debug information at all;
* **bitness** — Win64 (x64) vs. Win32 (WOW64 x86).

## How to read this

| mark | meaning |
|---|---|
| `yes` | measured working in this configuration |
| `yes*` | measured working, with a stated limit — the limit is named in the notes |
| `no` | measured NOT working (and, where it matters, refusing rather than answering wrongly) |
| `n/a` | the capability does not exist in this configuration |
| — | **not measured in this configuration.** Not a prediction, not an inference |

The last row of that table is the one that keeps this document worth reading. A
dash is never filled in by reasoning from the neighbouring column: the whole
point of the Win32 work was that behaviour which "obviously must be the same"
repeatedly was not. Where a cell is blank, nobody has run it.

Configurations:

| | mono | packages |
|---|---|---|
| **x64** | **A** — one exe, full debug info | **C** — host + runtime packages |
| **x86** | **B** — one exe, full debug info | **D** — host + runtime packages |

## Where the evidence comes from

| source | configuration | kind |
|---|---|---|
| `DebuggerTests.TDebuggerTests` (full DAP suite, `TestTarget.exe`) | A | fixture, every run |
| `DebuggerTests.TDebuggerTestsBpl` (the same suite against `TestHost.exe` + `TestSubject.bpl`) | C | fixture, every run |
| `DebugSessionTests.TWin32RunControlTests` (~54 tests; many run BOTH bitnesses in one test) | B, and one test in D | fixture, every run |
| `Win32_Bpl_BreakpointInPackage_FiresWithLocals` | D | fixture, every run |
| Hydra2 (real ERP client, multi-BPL) — 64-bit run 2026-07-17, 32-bit run 2026-08-03 | C, D | live, one-off |
| `AppContainer` (real 32-bit VCL application) | B | live, one-off |
| `Hydra2SingleEXE` (real single-exe build, 497 MB x86 / x64) | A, B | live (x64) + static analysis |
| `SampleAppSingleExe` (780 MB RSM) | A | live, one-off |

The fixture rows are the ones that stay true: they run on every build. The live
rows are single observations of a moving target and are cited as such.

The subject code of the A and C fixtures is compiled **once** into
`TestTarget\TestTargetCore.pas` and linked into both the exe and the BPL, so a
difference between those two columns is the debugger's, not the fixture's. The
same holds for B: `dcc32` builds the identical sources.

## Capability matrix

| capability | A mono/x64 | B mono/x86 | C pkgs/x64 | D pkgs/x86 |
|---|---|---|---|---|
| Launch, stop at a source breakpoint | yes | yes | yes | yes |
| Attach to a running process | yes | yes | — | — |
| Deferred binding into a not-yet-loaded package | n/a | n/a | yes | yes |
| Call stack: names + source lines | yes | yes\* | yes | yes\* |
| Stack continues through the OS frames | yes | yes | yes | yes |
| Raw stack sweep (opt-in) | yes | yes | yes | yes |
| Locals and parameters | yes | yes\* | yes | yes\* |
| Nested procedure sees the parent scope | yes | yes | yes | — |
| Locals of the program's main `begin..end` | yes | yes\* | n/a | n/a |
| Object / record / dynamic-array expansion | yes | yes | yes | — |
| Expression evaluation (arithmetic, casts, `is`/`as`, intrinsics) | yes | yes | yes | — |
| Calling a method or property getter in the debuggee | yes | yes | yes | — |
| `setVariable` (primitives, floats, enums, sets, strings) | yes | yes | yes | — |
| Conditional breakpoints, hit counts, log points | yes | yes | yes | — |
| Exception stop names the class and the message | yes | yes | yes | — |
| Step into / over / out | yes | yes | yes | — |
| Per-thread stepping (others frozen) | yes | — | — | — |
| Interface local labelled with its concrete class | yes | yes | yes | — |
| Reading a `threadvar` | no | no | no | no |

Notes on the starred cells:

* **Call stack, x86.** A FRAMELESS routine sitting between two framed ones still
  loses its framed caller. The recovery is designed and its exact call-site test
  is in place (`X86Decode.CallSiteEndsAt`), but the case remains an `[Ignore]`
  TODO-RED test (`StackAcrossRtlCallback_KeepsTheCallerOnBothBitnesses`). x64
  does not have the problem: it unwinds from `.pdata`.
* **Locals, x86.** Supported for `-$O-` builds. `-$O+` omits the frame pointer
  routinely, and whether an optimised 32-bit build still carries anchorable
  offsets has **not been measured**.
* **Main-block locals, x86.** What is asserted is that they never carry an
  invented type. Full parity with x64 for that scope is not claimed.
* **`threadvar`.** Not resolved on any configuration — but it refuses with a
  reason instead of answering. It used to read the PE headers and report `0` for
  a variable holding `$5A5A5A5A`, on both bitnesses, with nothing marking the
  answer as wrong.

Two things the raw sweep is not, worth restating wherever it appears: its hits
are POSITIONS on the stack, never callers — a call that has already returned
leaves its return address behind and no sweep can tell the difference — and on
x64 every hit comes back `proven:false`, because the call-site decoder that
proves a hit is x86-only. The sweep is most useful on x86 for exactly that
reason: x64 rarely needs it, since `.pdata` unwinds properly.

## The axis that actually decides most of it

"Monolithic vs. packages" is the wrong question about two thirds of the time.
The question that predicts behaviour is:

> **does the module whose code you are standing in carry debug information?**

A monolithic executable linked against a VCL built without debug info hits the
same wall as a package host, in the same place. The measured example, taken on a
live `TfrmMain` in a real application:

| expression | result | why |
|---|---|---|
| `Self.ClassName` | `'TfrmMain'` | virtual — address from the VMT |
| `Self.Caption` | `'Gestione Allestimenti…'` | virtual getter |
| `Self.Name` | `'frmMain'` | virtual getter |
| `Self.Width` | `1081` | field-backed, read directly |
| `Self.Owner` | `$21D9E8B0 (TComponent)` | field-backed |
| `Self.ComponentCount` | `<method invocation failed>` | **non-virtual getter, no symbol** |
| `Self.ControlCount` | `<method invocation failed>` | **non-virtual getter, no symbol** |

`TComponent.GetComponentCount` and `TWinControl.GetControlCount` are not
virtual, so invoking them requires a symbol, and that VCL was linked without
one. The failure is honest rather than wrong, and there is no fix short of
symbols for the VCL. It is recorded because "why does `Caption` work and
`ComponentCount` not" is otherwise a baffling report.

What a symbol-less module costs you, precisely:

| | with debug info | without |
|---|---|---|
| frame appears in the call stack | yes | yes — as an address |
| frame carries a name | yes | no |
| frame carries a source line | yes | no |
| breakpoint can be set in it | yes | no |
| its locals | yes | no |
| **fields of its objects** | yes | **yes** — expansion is RTTI-driven, not symbol-driven |
| **virtual methods callable** | yes | **yes** — the address comes from the VMT |
| non-virtual methods callable | yes | no |

The two bold rows are why a package host is far more usable than "some packages
have no symbols" suggests: object inspection keeps working across the boundary,
because it reads the Delphi RTTI in the running process rather than the debug
info on disk.

Which modules are in which state is not guesswork — `get_loaded_modules` (MCP)
reports every mapped image with `symbols` (`loaded` / `noSymbols` / `indexing`)
and `formats` (the formats that actually REGISTERED, not the ones that were
looked for), so an empty format list beside `noSymbols` means the binary carries
none, rather than a sidecar merely being absent.

## What the debug-info format changes, independently of shape and bitness

| fact | consequence |
|---|---|
| No `.map` next to the binary | A constructor's declared name is unavailable. `dcc32` mangles it as `@Unit@TClass@$bctr$qqrv` with the name component EMPTY; only the `$bctr` marker survives. With TD32 and no MAP, the stack shows the mangled form. Mapping `$bctr` onto `Create` is refused deliberately — a constructor may be declared with any name, and the guess would print something the source does not contain. |
| No `.map` next to the binary | Nested-procedure OUTER-scope variables were unreachable on x64 (measured on Hydra2, which ships no `.map`). x86 now resolves them from CodeView `pParent` instead. |
| `.rsm` older than the `.exe` | Ignored, with a message. A stale RSM describes a previous build and would silently mis-type variables. |
| `{$SCOPEDENUMS ON}` | The scoping is invisible in TD32 — the debug info records the members exactly as an unscoped enum. |
| Optimised RTL (`-$O+`) | No body locals for those routines, in any configuration. Standing in `TStringList.Find` and asking for `L` is not a debugger defect. |
| Only `.rsm` / `.dcp` / `.jdbg` for a module | Those map addresses but hold **no source-file index**, so `get_source_files` reports `listedBy: null` for that module — meaning *unknown*, not "this module has no source files". |

## Scale and cost

Measured on `Hydra2SingleEXE.rsm`, a 523 MB RSM from a real single-exe build
(configuration A), using the same `TRsmFile` path the adapter uses:

| | time | peak working set | sidecar |
|---|---|---|---|
| cold (no `.idx`) | 7.7 s | 692 MB | 36 MB written |
| warm (`.idx` present) | 0.06 s | — | reused |

The one-time cost is seconds, not minutes; later sessions pay a freshness check.
Peak working set is ~1.3× the file, which matters when several large containers
are indexed at once (`PrebuildIdx` defaults to 2 workers).

Not measured: adapter memory after an hour of stepping through a many-package
application, and the latency of an individual symbol resolution at a stop.
Nothing times those today.

## Deliberately not measured, and why

* **The 32-bit Hydra2 under a live debugging session beyond the recorded run.**
  It is a real ERP client that may connect to a production database; that is not
  a side effect to cause unattended. Static validation against the 497 MB
  single-exe build is used instead — which is what surfaced the AVX gap in
  `System.Move`.
* **Column D beyond breakpoints, locals and the stack.** The 32-bit package
  fixture exists and one test uses it. Extending the dual-bitness fixture to the
  rest of the D column is the single largest remaining gap in this table.
* **`-$O+` local variables on x86.** See above; unknown, not assumed absent.

## If you are choosing what to debug with this

* **A monolithic exe built with full debug info is the best-covered
  configuration**, on either bitness, and it is what most applications are.
* **A package host is a first-class case, not an edge case** — it is the shape
  the project was written for, and column C is measured on every build by the
  full suite running a second time.
* **Packages without debug info degrade gracefully rather than fail**: the stack
  still walks through them, object inspection still works through RTTI, and only
  names, lines, breakpoints and non-virtual calls are lost inside them.
* **x86 is real but younger.** Everything in column B is measured; column D is
  thin. If you are on 32-bit packages, expect to find things this table cannot
  yet answer for you — and please report them, because that is exactly how the
  x86 column got filled in.
