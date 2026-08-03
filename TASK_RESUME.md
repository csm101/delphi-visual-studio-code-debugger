# TASK_RESUME

Exact current task state. High-level permanent state lives in `PROJECT_STATE.md`.

## IN PROGRESS (2026-07-25): Win32 (32-bit) target support.

Branch **`feature/win32-target-support`**, cut from `public-main` at `a079c9e`.
Full plan (phases, constants, risks) is the approved plan file; this section is
the cursor inside it.

### Architecture, settled -- do not re-open

ONE 64-bit adapter binary debugs BOTH x64 and WOW64 x86 targets. Rejected the
two-binary design because the MCP server is registered once at editor startup
with a fixed command, long before any target exists, so it cannot pick a
per-bitness binary; two binaries would force an IPC proxy for no gain.
BEHAVIOUR differences (context/registers, stack walk, prologue, call ABI) go
behind `IDebugTarget`. LAYOUT differences (pointer size, VMT offsets, dynarray
header) go in a plain DATA record read while decoding an already-read buffer --
never a virtual call per pointer, which would shatter bulk reads into syscalls.
Unit rename `Win64Debugger.pas` -> `WinDebuggerBase.pas`, alongside
`WinDebuggerX86.pas`; repo / extension / MCP names unchanged. DONE -- see
"Unit rename" below for what was and was not split.

### Phase 0: DONE, verdict GO (12-agent workflow + adversarial verification)

Facts established, each measured rather than assumed:

* `dcc32` compiles the whole test-target tree clean and emits `.exe/.map/.rsm`;
  `-V -VR -VT -VN` all exist. `.cfg` `-E`/`-NU` are overridable from the command
  line (last wins), so **do not fork the `.cfg` files**.
* `RsmFileReader` AND `TTD32FileReader` parse 32-bit output **unmodified**. The
  feared JCL-Win32-padding mismatch does not apply to Athens 36 dcc32 output.
* `StackWalk64(IMAGE_FILE_MACHINE_I386)` + `TWow64Context` unwinds correctly
  (6 correct frames). **No hand-rolled EBP walker needed.** dbghelp contributes
  nothing to the i386 walk of a Delphi target (invade-only, explicit modules and
  both-callbacks-nil give byte-identical output).
* VMT x86: SelfPtr **-88**, TypeInfo **-72**, FieldTable **-68**, ClassName
  **-56**, InstanceSize **-52**, Parent **-48** (double indirection). CPP_ABI
  shift is **0** on Win32, 24 on Win64 applied to EVERY class. Anchor on an
  identity-tested SelfPtr + per-bitness deltas, never absolutes.
* x86 frame model: `mov ebp,esp` PRECEDES allocation (opposite of x64), so the
  return address is always `[EBP+4]` and **no frame size is needed at all**.
  Delphi emits `add esp,-N` (`83 C4`/`81 C4`, negative imm), not `sub esp,N`.
  Matcher must require `$55` at offset 0 AND `8B EC` right after.
* **No x86 analogue of the parameter home-slot formula.** First three params are
  in EAX/EDX/ECX with no stack home, spilled to NEGATIVE EBP offsets under
  `-$O-`; stack params run in REVERSE declaration order; `Self` is provably not
  at `EBP+8`. Parameter addresses must come from debug-info symbol offsets.
* A matcher miss must mean **"refuse to report locals"**, never "has none": a
  pure-`asm` body that never names a param is frameless yet debug info still
  lists the param, and the RTL is full of these.
* Scope limitation to accept: Win32 locals/params are supportable for `-$O-`
  builds only (`-$O+` omits the frame pointer routinely).

### Shipping defects found (see plan file for full list)

* **D1, x64, real bug, file separately:** `ReadPrologInfo`'s byte matcher returns
  `subRsp=0` for any function using the x64 stack-probe loop (`Bytes[1]=$B8`
  breaks the push loop). Masked today only because `.pdata` normally succeeds.
* **D3, blocker:** `TMapFile.ParseSegmentTableEager` hardcodes a 16-hex-digit
  Start column; PE32 prints 8, so every segment line is rejected and
  `FSegmentBaseRvas` ends up EMPTY -- the root cause of the MAP/TD32 `$1000`
  disagreement. True rebase is `LinearStart - ImageBase` PER SEGMENT.
* **D4, latent, hits the core use case:** `ReadPEPreferredBase` bails on non-PE32+
  and falls back to a hardcoded `$400000`; a PE32 BPL with a non-default base
  corrupts every segment base.

### Phase 0 unknowns: BOTH CLOSED BY MEASUREMENT (2026-07-25)

Probe: `DevTools\Win64\Debug\Wow64StackProbe.exe <32-bit exe> -rva DD83C [-step|-nopatch]`
(`$DD83C` = `TestTargetEdge.RunRecursion`, i.e. seg-0001 base `$1000` + `$DC83C`).

1. **A single step in a 32-bit target reports `$4000001E`
   (STATUS_WX86_SINGLE_STEP), NOT `EXCEPTION_SINGLE_STEP`.** Set EFLAGS.TF via
   `Wow64SetThreadContext` (EFLAGS became `$00200344`), continued, and the next
   event was `$4000001E` at BP+1. So stepping needs the SAME treatment as
   breakpoints; this was folded into Increment -1 as a fifth and sixth edit.
2. **The i386 walk does NOT survive a still-planted INT3.** This one bites.
   With the byte restored and EIP rewound the walk is correct:
   `#0 +$DD83C  ->  #1 +$EE96F (real caller)  ->  #2 +$F3E52`.
   With `-nopatch` (INT3 left in place, EIP one past it) it becomes:
   `#0 +$DD83D  ->  #1 $00AFFC54 <unknown module>  ->  #2 +$F3E52`
   -- the walker takes a STACK ADDRESS as a return address, fabricates a bogus
   frame, and LOSES the real caller entirely. On x64 the adapter keeps
   breakpoints planted across a stop and that is harmless because unwinding is
   `.pdata`-driven. **On Win32 restoring the byte and rewinding EIP before any
   stack walk is a hard requirement, not an optimisation.** Design the x86 stop
   path around this.

Also confirmed in the wild: the FIRST stop of a WOW64 target is `$80000003` at a
64-bit ntdll address with EBP=0 and yields 1 frame (not unwindable); every later
32-bit stop is `$4000001F`. `StackWalk64(IMAGE_FILE_MACHINE_I386)` returned 6
correct frames, and the three dbghelp modes (invade-only / explicit modules /
both callbacks nil) gave byte-identical output with `FTE=$00000000` throughout,
confirming dbghelp contributes nothing to the i386 walk of a Delphi target.

The 32-bit MAP segment table, read directly, confirms the D3 root cause:
`0001:00401000 .text` -- an **8-hex-digit** Start column, ImageBase `$400000`,
per-segment bases `.text $1000`, `.data $F5000`, `.bss $F9000` (so the shift is
per segment, never a flat `$1000`). Segment `0005 .tls` has linearStart `$0`,
below `FPreferredBase`, so it stays unregistered -- the known open TLS gap.

### Increment -1: DONE, gated and committed (6f56a5d..6a6dafd)

Gate: **946 found / 944 passed / 0 failed / 0 errored / 2 ignored** -- identical
to the pre-change baseline, as required (all six edits are no-ops on PE32+ by
construction, so any delta would have named a wrong edit rather than a drifting
baseline).

**Proof the MAP fix actually fixes Win32, not merely "does not break x64":**
rebuilt DevTools against the fixed reader and re-ran
`CompareMapTD32.exe <exe> <map>` on both bitnesses.

| | TD32 entries | forward diverge | reverse diverge |
|---|---|---|---|
| Win32 before fix | 1568 | **all** (constant $1000) | **all** |
| Win32 after fix  | 1568 | 9 | 10 |
| Win64 (control)  | 1487 | 6 | 9 |

Win32 now sits at the same residual level as the always-correct x64 control, so
the leftovers are ordinary MAP-vs-TD32 granularity (one source line owning many
RVAs in instantiated generics), not a bitness defect.

### Increment 1: DONE, gated, committed (0a72d42, 7ef0c92)

`DebuggerCore\TargetLayout.pas` -- a plain DATA record, deliberately not an
interface (a virtual call per pointer would shatter bulk reads into syscalls).
Seam is `IDebugTarget.TargetLayout`; `TDelphiRtti` is told its layout at
construction instead, because it reads through a raw handle. Consumers: the six
duplicated dynamic-array header reads, plus the two scans that strided target
memory by the HOST's `SizeOf(Pointer)`.

`TFakeMemTarget` in `ValueReaderTests.pas` gained a SETTABLE layout rather than
an inert stub, so 32-bit decode paths are testable against a fixed byte window
with no live debuggee and no 32-bit build. Three tests, including a negative one
that reads a 32-bit image with the 64-bit shape and asserts the result is wrong
-- it documents the real failure mode (a plausible wrong number, not an error)
and stops the positive tests going vacuous.

**Scope decision, deliberate:** the ~70 pointer-read sites in `DelphiRtti` /
`ExprEval` were NOT swept. Not every `ReadU64` there is a pointer read -- many
are genuine 8-byte values -- and a mechanical pass would introduce silent bugs.
Those sites are revisited in Increment 4c anyway, where the VMT32 table lands
and they become testable at 32 bits. Same reason no speculative `ReadPtr`
helpers were added.

### Increments 2 through 4d: ALL DONE, gated and committed

Every step below was gated on a green suite before the next began.

| commit | what landed |
|---|---|
| `96fbe0e` | D1 stack-probe-loop decode + prologue fail-closed |
| `d4a971c` | thread-context funnel (3 primitives replace 11 scattered sites) |
| `b941c48` | stack-walk machine type + positional call parameters |
| `c3db006` | synthetic-call ABI isolated from its arch-neutral event pump |
| `10b2747` | the nine arch methods made virtual |
| `6a674d9` | stack-walk context seeding routed through the seam |
| `8648b57` | `TWin32Debugger` + factory by PE Machine |
| `a36648e` | `Win32SessionProbe` + first end-to-end x86 evidence |
| `c616d51` | Borland demangler for dcc32 names |
| `93ee6ef` | 32-bit target built by the suite + 3 Win32 tests |
| `385a0bb` | x86 prologue decoder + stack locals |
| `73d0aea` | type-name demangling + 32-bit VMTs |
| `0e54151` | pointer-shaped field reads at target width |
| `cf02b3b` | x86 register calling convention -- evaluation works |
| `bf02956` | Win32 stepping covered |
| `869c6df` | Win32 multi-BPL covered |

### WHAT WORKS ON WIN32 NOW

Launch, breakpoints (including deferred binding to a module that loads later),
stepping, call stacks across module boundaries, source lines, stack locals,
object recognition and field expansion, strings, and expression evaluation
including getter-backed properties that run real code in the debuggee.
Multi-BPL -- the project's core use case -- verified end to end.

Suite: **965 found / 963 passed / 0 failed / 0 leaked / 2 ignored.**

NOTE ON A DIRTY RUN: one full-suite run produced a block of
`DAP request failed: unknown error` failures across `TDebuggerTests.Test_Types_*`
that did NOT reproduce on a re-run of identical code. If that shape appears
again, re-run before investigating -- and capture the WHOLE log, since the
default `Select-Object -Last 40` truncates the counts off the top when the
failure list is long, which is how it looked like a regression in the first
place.

### WHAT IS DELIBERATELY REFUSED (not broken -- unimplemented, and it says so)

* Float ARGUMENTS to a synthetic call (returns now work -- see below).
* `CurrentFrameParamHomeAddr` -- no x86 analogue exists; the answer must come
  from debug-info symbol offsets, never a positional formula.
* Optimised (`-$O+`) builds: frame-pointer omission is routine there, so Win32
  locals are supported for `-$O-` only. This is a DECLARED limitation.

Each refuses rather than inheriting the x64 answer, which would be confidently
wrong. In a debugger a plausible wrong number is worse than "unavailable".

### THE LESSON THIS WORK KEEPS TEACHING

On x64 the host and target pointer sizes coincide, so **every site that
conflates them is correct by accident**. Five separate such sites were found,
each in a different layer, and each only became visible when the debugger was
pointed at a different bitness: `LocalReadSize` for stack locals,
`SyntheticLocal` for expanded fields, `PrimTypeSize`/`SizeForKind` in ExprEval,
and -- the worst of them -- `GetClassProperties`' walk of the published-RTTI
records, which disabled live RTTI entirely on x86 while still returning
plausible values through the debug-info fallback. Expect more.

The corollary that matters more than the count: **a wrong pointer width rarely
fails loudly.** Three of the four degraded into a fallback or a plausible
number. Assume any remaining one is currently invisible.

### CURRENT CURSOR

Unattended bug-hunting run (2026-08-01), driving both bitnesses through
`DevTools\LiveSessionProbe` against TestTarget and comparing x64 vs x86 answer
by answer. Six defects found, each measured before it was touched, each closed
with a both-bitness test. Suite 988 / 984 passed / 0 failed / 4 ignored.

Committed this run:

* `1a6de90` Variant returned through the var-out slot: the class/record
  decoration in `EvaluateForFrame` overwrote the already-decoded value with
  `$addr (Variant)`. A Variant IS a TVarData, so whether the decoration fired
  depended on what a binary's type table exposed -- latent on both targets,
  visible on x86.
* `888154c` Dynamic-array bounds were not checked: the check was skipped for any
  base named `^...`, which is how TD32 spells EVERY dynamic array. `Scores[3]`
  returned a plausible integer, `Scores[-1]` returned the length field. Now
  discriminated by probing for a live header rather than by the type name;
  `Length()` on an open array refuses instead of inventing; `High`/`Low` share
  the discriminator.
* `9803494` Arrays of RECORDS walked with a pointer-sized stride. Also corrected
  `SizeOf`, which exposed that a type SIZE cannot be uses-scoped (see
  KNOWN_UNKNOWNS + the TODO-RED `Test_UsesScope_TypeSize_PicksUsedUnit`); the
  old test passed only because pointer size on x64 equals the expected 8.
* `738824c` Win32: a type declared inside a routine took the ROUTINE's name,
  because `DemangleBorland` truncated at the `$` signature marker.
  `@Unit@Proc$qqrv@TColor` is the type TColor. Enums and sets lost their
  identity with it -- `Big` printed 10 not beK, `EmptyCols` printed `Red` for an
  EMPTY set. Signature-internal `@` (a class-typed argument is
  `$qqrx20System@UnicodeString`) is skipped by consuming length-prefixed runs.
* `8571deb` `P^` on a pointer-to-record read 8 bytes into RawValue and left
  Address at zero, so the record had no address and no field resolved. Plus the
  caret-less `P.Field` form Delphi allows.
* `cfbc3ad` Nothing was reachable through an interface reference. Debug info
  emits no member list for an interface, and the reference addresses a field
  INSIDE the object. Recover the object by walking back to the first candidate
  with a valid VMT whose instance size REACHES the reference -- exact, not
  heuristic, since only the containing object can cover that address.

Continued in the same run (suite 992 / 988 passed / 0 failed / 4 ignored):

* `a76cc30` `ApplyDot` on an already-invalid base discarded the diagnosis:
  `ArrRec[2].A` said "no field A" instead of "index out of bounds", and
  `E.ClassName` on an unresolved `E` returned prologue bytes as a number.
  Harness gained target-args passing (several TestTarget scenarios only run
  behind a switch) and continue-to-line (with an exception the first stop is
  the raise).
* `da57f0d` WRITE path, both bitnesses: a WideString was built as a Delphi
  TStrRec and assigned with `@UStrAsg`, so `changed-wide` read back as
  `change` -- and that helper writes a refcount over the four bytes that ARE a
  BSTR's length. Now a real BSTR plus `@WStrAsg`, which copies, so our block is
  never SysFreeString'd. Also every negative literal was rejected, making
  signed variables unwritable below zero.
* `583a70d` Conditional / hit-count breakpoints: no defect, coverage added for
  the 32-bit target (they evaluate in the debuggee, so they depend on it).
* `ca132ca` Closures: captured fields read 8 bytes wide regardless of target
  (a captured string was unreadable on x86); captured variables listed but not
  reachable by NAME on either bitness; and -- found by the new test being flaky
  in the suite while passing alone -- captured variables VANISH SILENTLY when
  the symbol index is cold, because the interactive wait is bounded. The watch
  path recovers via frontend warm-up/retry, the locals path has none. Made
  visible with a `<captured> = <symbols not ready>` row; real fix logged.
  Also hardened `TryFindClosureSelf` to prefer the $ActRec its own frame names
  (the scan could latch a stale one; on x86 the scan is the ONLY path) -- that
  was my first hypothesis for the flakiness and it was wrong, but the hazard is
  real, so it stayed.

* `2ec6401` A RECORD local was listed as a number: the generic formatter turned
  its first bytes into one, so a packed record holding 1/2/3 read as 513
  ($0201). The watch path already showed `$addr (Type)`, so the same variable
  read differently depending on the view.
* (this commit) The Variant auto-recovery converted a value on SLOT SIZE alone.
  The first element of a static array shares the array's address, so
  `MStatic[0,0]` -- a plain 0 in a 36-byte array -- displayed as `<empty>`.
  Now the bytes must also look like a TVarData; 24 zero bytes still recover, so
  a genuinely mis-tagged empty Variant is unaffected.

Verified with no defect found: step in/out/over through doubly-nested procs;
call stacks from an inner nested proc to the main block; exception handler
locals (`E`, `E.Message`, `E.ClassName`, and a flag proving the inner `finally`
ran); indexed properties; record / dyn-array / generic-list EXPANSION;
conditional and hit-count breakpoints; worker-thread breakpoints, thread
enumeration and per-thread stepping; multi-dimensional static and nested
dynamic array indexing and bounds.

Second wave (2026-08-02), after the user's rule "no heuristics -- nothing should
be more deterministic than a debugger". Suite 998 / 994 passed / 0 failed / 4
ignored. Commits `3743b14` .. `2f98e1d`:

* Replaced MY OWN worst heuristic: telling a dynamic array from a pointer by
  PROBING MEMORY for a plausible header. Now decided from the type graph. Three
  facts had to be established first: a TypeId is meaningless across providers
  (TD32 calls `Scores` $B4BA, RSM $020D), so the PROVIDER resolves the question
  and the ANSWER travels; a local IS the array while a var-out `Result` POINTS
  at one, so both TypeKind and PointeeKind are needed; and an open array has an
  IDENTICAL type record to a dynamic array, separable only by being a parameter
  -- which the offset SIGN cannot tell (positive on x64, negative on x86), so
  RSM's record tag supplies it. `TSymbolParamStatus` is a TRI-STATE on purpose:
  "nobody said" is not "it is a local".
* Attach on Win32: covered, no defect. Discovered the x64 attach test had been
  passing in 0.1 s WITHOUT attaching -- gated on SeDebugPrivilege, which is only
  needed for ANOTHER user's process. Ungated, both really attach.
* RTTI field-table header is `2 + PointerSize`, not 10. On x86 the whole walk
  was shifted: field names from unrelated memory, offsets like -2025889729.
  This also recovers generic element types, which the static tables cannot give
  (dcc32 emits one un-instantiated `%TList__1`).
* Var PARAMETERS showed their pointer on x86: only RSM records by-reference-ness
  and `Kind` was not merged across providers, so whichever provider was the base
  decided -- and that differs by bitness.
* Four pointer reads hardcoded to 8 bytes, now target width.
* Dynamic arrays are recognised under EVERY spelling (`^E`, `TArray<E>`,
  `array of E`). Matching only `^` became a live bug the moment RTTI supplied
  real names: `FItems` expanded into ITSELF and failed the request.
* `EvaluateForFrame(expr, N>0)` silently answered with the TOP frame's locals
  when no stack had been fetched -- the cache it indexes was empty.
* Session destruction now terminates what it launched (ownership).

REVERTED, and why: labelling an interface with its concrete class via the
interface-table search. Reached from an arbitrary formatted value it walks into
module data where the RTTI readers raise EIntOverflow and fail the whole
`variables` request. Bounding by the OS allocation did not help (object and
reference share a region), and bisection did NOT converge -- IsClassInstance,
GetInstanceSize, GetInstanceClassName and the table walk each stayed implicated.
Cause NOT located. The display path keeps its original IMT-thunk decoding, so
that label stays x64-only exactly as before. The interface-table mechanism IS
used, and green, for member ACCESS through an interface.

Still open, logged not fixed:

* RSM resolves nested type names wrongly on Win32 too (`Col` -> `PPCharArray`).
  TD32 wins at runtime so nothing is visibly broken, but a binary with RSM and
  no TD32 would show it.
* `<.Field not found>` loses the receiver: it should name the class.
* `Length()` returns Int64 where Delphi says Integer; a dyn array reports
  `^Element` as its type rather than `TArray<T>`.

Win32 support is functionally complete for `-$O-` targets. Remaining work, in
order of value:

1. **Living specs** -- in flight. DAP_DEBUGGER_ARCHITECTURE.md, TD32_FORMAT_NOTES.md,
   KNOWN_UNKNOWNS.md (two entries to CLOSE), PROJECT_STATE.md, README.md.
2. **Float and Int64 returns: DONE** (commit `fdeca39` plus the follow-up below).
   Solved by an unconditional FPU-capture stub -- `fnsave`/`frstor` into scratch,
   then `jmp RemoteCallTrap` -- which cannot fault on an empty stack, so it needs
   no expected-result-class signal in the seam. The FNSAVE tag word says whether
   ST(0) was actually occupied; if not, the float slot stays zero and the call is
   read as an integer one. `IntResult` combines EDX:EAX.
   **Trap that cost three wrong conclusions:** the tag word is indexed by
   PHYSICAL register, but the saved register AREA is in STACK order with ST(0)
   always FIRST. Multiplying the register offset by TOP reads ST(7).
3. **Float-family return ENCODING: DONE.** Measured with
   `DevTools\Win32FloatAbiProbe` (32-bit, build via `DevTools\build_one32.bat`):
   on Win32 EVERY float-family type returns in ST(0), Currency included, and
   Currency arrives already SCALED (19.95 -> 199500). The formatters in
   `ExprEval.AsDouble` expect three different raw encodings, so
   `TExprEvaluator.NormaliseFloatReturn` undoes the x87 Double conversion for
   Single (narrow to a 4-byte pattern) and Currency (round to the scaled Int64).
   It is called from BOTH return sites -- `ApplyMethodCall` and `InvokeGetter` --
   because a property expression resolves through the FIRST of those on x86.
   Verified `Single 1.5 / Double 3.25 / Real 6.75 / Extended 2.5 /
   TDateTime 45000.5 / Currency 19.95 / Int64 0x1122334455667788` on both.
4. **Unit rename: file rename DONE, class split NOT done.**
   `Win64Debugger.pas` is now `WinDebuggerBase.pas`, which is what the name
   needed to stop claiming: the unit holds the architecture-NEUTRAL engine and
   debugs 32-bit targets too. Five code references, two comments and five
   documents updated; repo, extension and MCP names unchanged.

   What was NOT done is extracting a `TWin64Debugger` into `WinDebuggerX64.pas`.
   Today the base class carries the x64 seam implementation as its DEFAULT and
   `TWin32Debugger` overrides it. Splitting it would mean promoting whatever
   private state those ~12 seam methods touch to `protected`, which is a real
   design change to a 4000-line unit rather than the "pure move" the plan
   assumed. Worth doing, but it needs a deliberate pass, not a drive-by.
5. **`-$O+` support**, if wanted at all -- decide policy before building.

### Float ARGUMENTS to synthetic calls: DONE (was the last declared gap)

Seam widened: `ArgIsFloat: array of Boolean` -> `ArgKinds: array of
TSyntheticArgKind` (`sakOrdinal`, `sakInt64`, `sakSingle`, `sakDouble`,
`sakExtended`), declared in `DebugTarget.pas`. x64 uses the kind only to pick
the register file and is unchanged; x86 uses it for BOTH decisions the ABI makes.

Measured rules (`DevTools\Win32FloatArgProbe`, now also covering Int64/Currency):
a parameter takes EAX/EDX/ECX only if it fits 32 bits AND is not a float;
everything else goes on the stack consuming NO slot. Stack widths: Single 4,
Double 8, Int64/Currency 8, Extended 12. `Extended` travels through the seam as
Double bits and is widened to 80 bits at placement.

TWO DEFECTS FOUND WHILE VERIFYING, both invisible on x64:

1. **Integer literals are typed `Int64` by the parser** (`ExprEval.pas`), so
   classifying them faithfully put `Foo(3)` on the stack as 8 bytes and left the
   register unset -- `Self.Mult(3,4)` went 54 -> 42. `TExprValue.IsIntLiteral`
   now marks literals; one that fits 32 bits is passed as an ordinal. A REAL
   Int64 with a small value still gets 8 bytes, which is why value-based
   classification was rejected.
2. **`Self.ArgE` read 0** -- not the argument path at all, but the FIELD read.
   `ReadFieldBackedProp` and `ResolveRsmField` both read `Min(Size,8)` raw bytes;
   for an Extended holding 0.125 the low 8 bytes are the mantissa
   `$8000000000000000`, i.e. -0.0, which prints as "0". Both now go through
   `TExprEvaluator.ReadValueAt`.

Verified identical on both bitnesses: `Mult(3,4)=54`, `Sum5(1..5)=12345`,
`Scale(2.5)=5.5`, and `SumArgs` -- one argument of every class interleaved with
ordinals, weighted by distinct powers of two -- `=127`. The weighting is what
identified both defects: the deficit names the argument that went astray.

REMAINING, and it predates all of this: argument kinds come from the CALLING
EXPRESSION, not the callee's declared parameter types, which debug info does not
surface. `Foo(0.25)` passes a Double to a `Single` parameter on x64 too.

### FIELD TEST IN PROGRESS -- resume here (2026-07-26)

Target: `C:\Athens\qbflibraries\qbfdesign\QBFDesignD29.dpk`, a DESIGN-TIME
package. The debuggee is `bds.exe`, which is 32-bit, so this exercises the whole
Win32 path against a real host with ~100 runtime packages. It has already found
three defects that no synthetic target reproduced.

FOUND AND FIXED (committed):
1. Exception class / message / `$exception` -- the fifth host-vs-target site,
   see the section below.

FOUND AND FIXED (pending the suite that was running when the session ended):
2. **Frame 0 rendered as `0xFFFFFFFFB5C34A23 (unknown module)`** -- the thread's
   real PC `$B5C34A23` SIGN-extended to 64 bits by StackWalk64, so it matched no
   module, carried no source, and VS Code had no line to open. The adapter had
   ALREADY resolved the stop correctly: the log shows
   `ReportStopped: reason=breakpoint VA=$B5C34A23 file=frmEnumsU.pas line=235`.
   Fix: frame 0's PC is re-anchored to the seed PC (authoritative -- it is the
   thread's live PC), symbolication follows `Frame.IP` rather than
   `SF.AddrPC.Offset`, and on a 32-bit target a frame address above 4 GB stops
   the walk. NOT root-caused: why dbghelp sign-extends it is unknown; the fix is
   to stop asking it for a value we already hold exactly.
   Suite after this change alone: 965/963/0.
3. **Step-over on `inherited` hung.** Same root: `CallerReturnAddress` unwinds
   one frame with StackWalk64, which in this stack returns `0x14FF680` -- a STACK
   address. The run-to-return one-shot breakpoint went somewhere never executed,
   so the step never completed. `TWin32Debugger.CallerReturnAddress` now reads
   `[EBP+4]` directly (Phase 0 measured that `mov ebp,esp` precedes allocation on
   x86, so that slot is always the return address), validates it with
   `IsPlausibleReturnAddress`, and falls back to the inherited walk otherwise.
   NOT YET CONFIRMED BY THE USER -- the suite was still running at session end.

STILL BROKEN, NOT ADDRESSED: frame 1 onwards. The walker takes a stack address
as a return address and loses the real caller, so the join into the VCL frames is
junk. This is the Phase 0 prediction about the i386 walk in modules dbghelp knows
nothing about. `DevTools\Wow64StackProbe` exists for investigating it.

NEXT ACTION: ask the user whether step-over completed. If it still hangs, the
distinguishing question is whether the process RUNS but never stops (breakpoint
planted at the wrong address -- grep the log for `PlantStepBp`) or everything
FREEZES (the separate main-thread deadlock recorded in the MCP findings).

USER-SIDE ISSUE worth repeating to them: the log warns
`qbfdesignd29.bpl RSM is OLDER than the BPL -- it will be IGNORED`, so that
package's types/locals come from TD32 only until it is rebuilt.

## DOGFOODING ROUND (2026-08-01): driving the shipped MCP frontend as a user

The user's point was that he cannot use this debugger for five minutes without
hitting something, and that the same should be done from this side. So: a real
session over the MCP tools against `DebuggerTests\TestTarget`, BOTH bitnesses
and the multi-BPL host -- evaluating properties, calling methods, expanding
objects, stepping -- rather than running the suite.

Eleven defects in one sitting, every one checked on Win32 AND Win64 because that
is what separates "regression from the Win32 work" from "always been wrong".
None of them was a Win32 regression. Full log with evidence and controls:
`X:\Temp\...\scratchpad\defects.md` (transient) -- the substance is below.

### FIXED, gated, negative-controlled

* **`WideString` read at twice its length, both bitnesses.** A BSTR's 4-byte
  prefix is a BYTE count; `UnicodeString`'s is an ELEMENT count. One reader
  served both. See DAP_DEBUGGER_ARCHITECTURE.md -> "`WideString` is a BSTR".
* **Step-into parks on the function ENTRY on Win32.** `FunctionBodyStartVA`
  takes the routine extent from `.pdata`, which does not exist on Win32, so the
  F19 pivot never ran there. Two silent consequences: locals read the CALLER's
  frame, and the walk drops exactly one frame (`RunAllScenarios` shown where
  `RunEvalTests` belonged). Now falls back to `BreakpointBodyRva`.
* **`Obj.M` without parentheses read as DATA.** Fell through to the qualified
  symbol lookup, which returned the method's own code address:
  `W.GetSelf` = `0x83EC8B55` (`push ebp; mov ebp,esp`). Path 3c in `ApplyDot`
  now calls a member whose declared parameter list is empty.

Negative controls run for the last two: with the fixes disabled the new tests
fail with the exact field symptom, in both the mono and BPL fixtures.

* **Var-out RETURNS on the direct method-call path -- FIXED.** TD32 types the
  `Result` of a var-out function as `^T` (`^Variant`, `^TPoint3D`, `^string`);
  the caret is the ABI, not the type, and it defeated the kind dispatch, so the
  slot was read as a scalar. `W.DoCalcVariant()` gave `3` (the VType word),
  `W.DoCalcBigRec()` gave the double `1.5` -- the record's first field. Strings
  worked only because the string path strips the caret separately, which is why
  nobody noticed. Now stripped at the source, but ONLY when the pointee is a
  kind that really travels through the slot.
  I FIRST CALLED THIS ONE CLUSTER WITH THE DYN-ARRAY CASE. That was wrong: they
  are different causes and only these two shared one.

### OPEN, characterised, NOT fixed

* **`W.DoCalcDynArr()` still returns `[85899345930, 30, []]`** -- `0x14_0000000A`
  is elements 20 and 10 read as ONE 8-byte element. CAUSE MEASURED (an earlier
  note in this file guessed "the RSM has no Result local" -- true of the RSM,
  irrelevant, because TD32 is the primary provider and DOES have one):
  ```
  DoCalcDynArr.Result  $B4B9  LF_POINTER -> $B4BA LF_POINTER -> $B4BC leaf=$32 -> Integer
  RunEvalTests.Scores  $B4BA             LF_POINTER -> $B4BC leaf=$32 -> Integer
  ```
  A dyn array is `LF_POINTER -> leaf $32`; the var-out Result is the SAME chain
  with one extra pointer -- `Scores`, which formats correctly, is literally its
  next link. The caret-strip declines because it decides by NAME and
  `TypeNameToKind('^Integer')` cannot tell a dyn array from a pointer.
  THE FIX IS A DESIGN CALL, deliberately not taken while unattended:
  decide by TYPE ID (`TTD32FileReader.TypeKindById` answers it exactly, but is
  private and not surfaced through `TDebugInfoSet` -- exposing it is a new
  provider interface), or strip a caret whenever the pointee also starts with
  `^` (a heuristic that misfires on a pointer-to-pointer returned by value).
* **Program main-block locals carry false types** -- MEASURED AND CONTAINED,
  root cause still open. The byte-level probe was done (hexdump at `0xB4B888`
  in `TestTarget.rsm`, reproduced in `RSM_FIELD_OFFSETS.md:128`) and settles
  the spec-vs-code disagreement in the CODE's favour: the TypeId is VLE, 6-byte
  tail for the narrow form and 7-byte for the wide one, and the `RbpOffset`
  lands correctly in both. So the two-byte widening was never the bug.
  What IS wrong: the wide id resolves against nothing known. `TheWidget`
  carries `$0401` = 1025 against a 246-entry user-type table; `shr 1` = idx 255
  (out of range), `shr 2` = idx 127 = `PVariant`, and `TWidget` is in neither
  that table nor the unit's `$66` imports (its module type id is `$62C9`).
  Win32 shows the same shape (`$03ED`). Three decodings tried, three refuted --
  do not guess a fourth; the open question is logged in `KNOWN_UNKNOWNS.md`
  with the two candidate tables that have not been dumped yet (the EXE-wide
  `$65`-anchored table, and the possibility that the wide id is an offset
  rather than an index).
  SHIPPED INSTEAD: `CollectMainBlockLocals` leaves `TypeHint` EMPTY for the
  wide form instead of emitting whatever name sits at the bogus index, and
  dedups repeated (name, slot) pairs -- which is what produced the phantom
  second `Cmp`, a consequence of scanning the whole file for a record shape.
  Class-typed main-block locals now render from the runtime VMT
  (`$28CB370 (TWidget)`): no declared type, but no false one either.
* **Unit globals resolve over DAP but NOT over MCP** (`GCounter` ->
  `<not found>` while `DebuggerTests.pas:1717` asserts the DAP finds it). The
  provider warm-up + retry lives only in `TDapServer`; `McpServer.pas:695` calls
  `EvaluateForFrame` once. Design call -- duplicate it, or move warm-up into the
  session and keep the DAP's miss-cache (an unresolved watch measured ~6.2 s).
* **String ARGUMENTS to a synthetic call fail** with a bare
  `<method invocation failed>` that does not say why. Float / Int64 / Currency
  arguments work.
* Minor: `TArray<Integer>` reports `^Integer`; `Length(s)` reports `Int64`;
  a Win32-only duplicate `Testtarget` frame in the main block.

## PENDING LIVE VERIFICATION BY THE USER (2026-07-29) -- READ THIS FIRST

Three fixes are committed and suite-green but have NOT been seen working on a
real target, because they need somebody to drive the Delphi IDE. Do not report
them as confirmed.

Run: `DevTools\LiveSessionProbe.exe "<...>\bds.exe" C:\Athens\qbflibraries\qbfdesign
qbfDelphiMenu.pas:378,TemplateDsgnTableFrmU.pas:63,TemplateDsgnTableFrmU.pas:64,frmColumnsU.pas:233
-seconds 1800 -eval Application`
then open the Columns editor in the IDE so the breakpoints fire. All four bind
(`verified=True`) once `qbfdesignd29.bpl` loads -- already observed; what is
missing is a stop.

| # | what to check | expected | why it is not settled |
|---|---|---|---|
| 1 | call stack at `TemplateDsgnTableFrmU.pas:63` (the `begin`) | more than ONE frame | the prologue-recovery probe (scan above ESP for a word that is executable AND sits after a CALL) cannot be reproduced in the suite: the synthetic constructor has no compiler-generated preamble |
| 2 | call stack at `:64` | full depth, no duplicated frames | the 30-frame walk WAS observed on a real host, but not at this specific stop |
| 3 | `Application` at `qbfDelphiMenu.pas:378` | either `TApplication`, or absent -- never a bare number | see below; the failure is timing-dependent and may not reproduce once startup has finished |
| 4 | a stop with no source anywhere | an editor opens with the placeholder text, AND a `>>> DEBUGGER STOPPED` line appears in the Debug Console | `deemphasize` was removed after the field showed the source WAS attached and still did not open; the console line is the belt-and-braces path |
| 5 | breakpoint on a `begin` line | stops on the first STATEMENT, parameters correct | proved on both bitnesses in the suite; worth one look in the field |

`Application` is the one still genuinely unresolved. What is established: the
value is wrong only EARLY in startup (`$F8BAE850`, no type) and correct later in
the same session (`$4295900 (TApplication)`), so it depends on which providers
have registered. What is NOT established is which provider offers `Rva=$1C38`.
An earlier note in this file blamed "DLL MAP registered unscoped" -- that was
WRONG and has been corrected: `EnsureModuleMap` shifts a module MAP into exe-RVA
space and range-scopes it, so $1C38 cannot be vcl290's. `EvaluateGlobalName` now
dumps every candidate with its VA, data/code classification and nearest function
name when it refuses, so the next live run answers this instead of another guess.

### FIELD ROUND 4 (2026-07-29): driving a REAL bds.exe session from a probe

`DevTools\LiveSessionProbe` launches a host application, plants breakpoints,
and keeps the session alive -- continuing after every stop -- so a human can
trigger the interesting stops from the target's own UI. Built because the
design-time-package cases cannot be provoked from a fixture. It also reports
breakpoint VERIFICATION TRANSITIONS, which is how the deferred bind became
observable: all four breakpoints came up `verified=False` at set time and
flipped to `True` once `qbfdesignd29.bpl` loaded.

**The x86 walk, measured on the real host: 30 frames** across dclteepro929 /
rtl290 / coreide290 / delphicoreide290 / bds.exe / vcl290, naming
`VCLTee.TeeChartPro.pas:930` and `@@PackageLoad`, with no truncation and no
duplicates. That is round 3's item A confirmed outside the suite.

**The splice was WRONG first, and my own new test caught it.** Re-seeding
dbghelp at the join (its PC and frame pointer, SP guessed at the frame pointer)
restarts it in the MIDDLE of the stack: on the recursion fixture frames 0..7
were correct and frames 8..14 were a verbatim replay of 1..7. A duplicated stack
is worse than a short one -- every frame in it looks real. It also imported
64-bit garbage frame pointers ($117600000893E3C on a 32-bit target), because the
base implementation reads `Ctx.Rbp` from a context the WOW64 path never wrote.
Now dbghelp runs from the ORIGINAL seed and is spliced at a MATCHED join: find
our last frame's PC in its walk, take only what follows, validate each frame,
and zero a frame pointer that is not a plausible 32-bit stack slot. No join
found -> leave the stack short rather than invent a tail. x86 and x64 now report
the same 8 Pascal frames on the fixture.

**`Application` renders as a bare pointer -- partly diagnosed, false value
removed, root cause NOT established.** From the field log:
`EvaluateGlobalName "Application": accept code-resident exact match Rva=$1C38`
-> `VA=$2D1C38 Raw=$F8BAE850 TypeHint=""`.

MEASURED: it is timing-dependent. The same watch answered `$F8BAE850 []` early in
startup and `$4295900 (TApplication)` later in the SAME session, so it turns on
which providers have registered.

A FIRST DIAGNOSIS RECORDED HERE WAS WRONG and is retracted: it blamed
`vcl290.map`'s two `Application` publics (`Vcl.Forms` at 0004:02F4 and
`Vcl.SvcMgr` at 0003:1C38) combined with "a DLL's MAP is registered UNSCOPED".
The second half does not hold -- `EnsureModuleMap` loads a module MAP with
`Shift = Module.Base - ImageBase` and registers it through `AddModuleProvider`,
so its RVAs are already in exe-RVA space and range-scoped. A vcl290 RVA could
therefore never surface as $1C38. The bare-name collision across units is real,
but it is not what produced this address.

WHICH provider offers $1C38 is still unknown, and no further guess belongs here.
`EvaluateGlobalName` now dumps every candidate (RVA, VA, data/code, function
entry, nearest function name) whenever it refuses, so the next live run names it.

Fixed here: only the false VALUE. Two wrong attempts first, both worth recording.
Requiring the address to be EXECUTABLE does not bite -- the bad address IS code,
that is the whole problem. Refusing every code-resident match broke `Now`,
`DoWork` and an interface method's `Name` (3 tests x 2 fixtures), which are
genuinely code and genuinely what the user asked for. The discriminator that
holds: **a callable symbol's address is a FUNCTION ENTRY and a data global's
never is**, which the providers answer directly -- and for the bogus RVA there
is no function to find, because it lands in a module with no symbols.

STILL OPEN: making `Vcl.Forms.Application` actually resolve needs unit-scoped
AND module-scoped MAP globals. Defect 2 above is the dangerous one and is not
fixed.

### FIELD ROUND 3 (2026-07-29): the three items left open by round 2

**A. The i386 walk now chains EBP instead of asking dbghelp. Phase 0's "no
hand-rolled EBP walker needed" is RETRACTED -- it was measured on a synthetic
target and the field disproved it.**
The walk was split behind a new seam: `TWinDebugger.WalkRawFrames` yields raw
`(PC, FramePtr)` pairs and `GetStackFrames` symbolicates them, identically for
both architectures. x64 keeps StackWalk64 (`.pdata` is exact).
`TWin32Debugger.WalkRawFrames` chains `[EBP+4]` / `[EBP]` -- exact on x86, where
`mov ebp,esp` precedes the allocation -- validating EVERY link (return address
must be executable code in a known module; the next frame pointer must be
4-aligned, strictly ABOVE the current one, and within 1 MB). When the chain dies
at depth <= 1 it defers to the inherited StackWalk64, which for a stack that is
mostly frameless system code may still do better.
Pinned by `Win32_CallStack_FramesAreCodeAndFramePointersAscend`, which asserts
the two structural invariants the field failure broke: no frame's PC may lie
inside the stack region spanned by the frame pointers, and each caller's frame
pointer must be strictly above its callee's.
HONEST LIMIT: the field condition (a caller in a module dbghelp knows nothing
about) cannot be reproduced in the suite, since dbghelp knows every test module.
The existing `Win32_CallStack_UnwindsPastRecursion` and
`Win32_StackFrameNames_MatchWin64` prove no regression; the fix is correct by
construction from the measured x86 frame model, and the same reasoning already
fixed step-over in the field.

**B. A breakpoint on a routine's `begin` line bound to the routine's ENTRY, so
every parameter read the CALLER's frame. NOT a Win32 bug -- both bitnesses.**
This is what made the user's `Self` show as `TAddInExpert` and `tmp` as garbage:
their breakpoint was on line 233, which is `begin`. The F19 work had fixed the
same hazard for STEP-INTO and its comment claimed "breakpoints were never
affected" -- true for a breakpoint on the first STATEMENT, false for one on
`begin`. `FunctionBodyStartVA` could not have helped anyway: it derives the
extent from `.pdata`, which does not exist on Win32.
`TWinDebugger.BreakpointBodyRva` now moves a breakpoint that landed exactly on
a function's entry to the first address inside it whose line record differs --
the same boundary, taken from the line table alone so it needs neither `.pdata`
nor a known image base. A routine whose body shares the entry's line record
(one-liner, frameless `asm`) is left at the entry rather than guessed past.
NEGATIVE CONTROL: with the move disabled the new
`BreakpointOnBeginLine_ReportsPassedParameters` reports
`x64 AInt=99; x86 AInt=13023708` for a parameter the caller passed as 1234 --
plausible numbers, never flagged, on BOTH bitnesses.

ONE EXISTING TEST ASSERTED THE OLD BEHAVIOUR AS CORRECT.
`Test_Step_Over_FromFunctionEntry_LandsNextLine` reached its entry stop by
putting a breakpoint on `begin` and asserting it bound to the entry -- exactly
what B changes. Updated to assert the MOVE instead, then the step from the first
statement to the next line. Its fixture (`StepMultiLine(Seed: Integer)`) has a
parameter, so it was demonstrating the same defect it enshrined.
COVERAGE HONESTLY LOST: stepping over from the RAW entry address is no longer
reachable, since neither a breakpoint nor a step-into parks there any more.
`HandleSmOverStep`'s entry-RSP handling is now defensive rather than exercised;
this is recorded in the test's own comment so it is not mistaken for coverage.

**C. `PlantInt3` had no duplicate-address guard.** Two source lines can resolve
to one address (the user had breakpoints on both 233 and 234, and B now maps
them together). The second plant read the `$CC` the first wrote and saved THAT
as the original byte, so unplanting restored a breakpoint instruction and left
the target trapping forever at an address no breakpoint owns. It now adopts the
first planter's original byte and skips the write. Pre-existing, not introduced
by B -- but B makes it reachable, so it had to land first.

**D. `ArrayElemByteSize` reported 8 for `$42` (`Extended`), now 10.** `$42` only
ever appears in 32-bit output (Win64 emits `$41`, a true `Double` alias), so it
is unconditionally the 10-byte x87 type and `array of Extended` was striding
short by 2 bytes per element. Deliberately deferred in round 2 for fear of
widening a read into an 8-byte slot; checked before changing -- `TypeSizeById`'s
only size-sensitive consumers are the SET and RECORD return paths in
`ApplyMethodCall` (`ExprEval.pas:1477`, `:1501`), and a float reaches neither.

### FIELD ROUND 2 (2026-07-29): three defects reported from the bds.exe session

All three diagnosed from the adapter's OWN log (`%TEMP%\dap_adapter.log`, which
survives the session and is append-only) rather than by re-running anything.
That log is the first thing to reach for on a field report.

**1. Frames read `TFrmColumns@Create` instead of `TFrmColumns.Create`. FIXED.**
Traced to the provider by asking each one directly
(`Td32AliasProbe -rvaname 24688 <bpl>` -> `TD32 : TFrmColumns@Create`), so no
guessing about which of RSM/TD32/MAP/DCP produced it. Cause: an IDE-built package
stores method names with NO leading `@`, i.e. with no unit component
(`TFrmColumns@Create`), while `dcc32` on a normal build emits the anchored
`@Unit@TClass@Method$qqr...`. `DemangleBorland` required the leading `@`, so the
unanchored shape fell through to `Friendly := Mangled` and the raw name reached
the call stack. It now handles both: anchored keeps its "first component is the
unit, drop it for a plain routine" rule; unanchored treats every component as a
real scope and a name with no `@` at all is still rejected as unmangled.
Pinned by `TD32ReaderTests.Demangle_Borland_UnanchoredClassMethod_BecomesDotted`,
which asserts BOTH shapes plus the two unchanged anchored ones.

**2. Step-over on `inherited` ran away instead of stopping. FIXED. Sixth
host-vs-target site, and the first one in the RUN-CONTROL layer.**
The log line that named it:
`PlantInt3 FAIL ReadByte VA=$5196C430B5AA25BC LastError=998` -- low half
`$B5AA25BC` the real return address, high half `$5196C430` an unrelated rtl290
address. `TWinDebugger.HandleSmOverStep` read the CALL-pushed return address with
`ReadProcessMemoryAt(CurSP, @RetTop, 8)`; on a 32-bit target that splices the next
stack word into the high half. Now `ReadTargetPointer`, and the matching
`FStepResumeSP := CurSP + 8` (the width the RET pops) is
`CurSP + TargetLayout.PointerSize`.

Second, independent defect in the same path, fixed with it: the step-over
fallback planted its one-shot BP after testing only `RetAddr <> 0`, where the
step-OUT path next to it uses `IsPlausibleReturnAddress`. With the guard the
garbage address would have been refused and the step would have degraded to
single-stepping instead of running free.

WHY NO EXISTING TEST CAUGHT IT: `Win32_StepOver_AdvancesWithinTheSameFrame` steps
over `W.StepIntoProbe(1234, 'probe-str', 2.5)`. On x86 the first three arguments
go in EAX/EDX/ECX and the fourth is pushed -- here the Double 2.5, whose low 4
bytes are ZERO, so the over-wide read produced the RIGHT address by accident.
New fixture `RunStepOverStackArg` passes `Integer($5EEDBEEF)` as the stack
argument precisely so every byte is non-zero; pinned by
`Win32_StepOverCallWithStackArgument_LandsOnTheNextLine`. The assertion that
matters is "stopped at all" -- the failure mode is a runaway, not a wrong line.

**3. A stop in sourceless code was INVISIBLE in the editor. FIXED (DAP only).**
Stopping at e.g. `0x76549F54 (kernelbase.dll: no symbols)` sent a `stopped` event
whose frames carried no `source` at all, so VS Code had nothing to bring forward:
no debug view, no editor, no sign the target had stopped. Such a frame now gets a
`source` backed by a `sourceReference` (plus `presentationHint: deemphasize` and
`origin` = module), and the new `source` request returns a placeholder document
naming the address, the module, and WHICH of the four reasons applies
(`no symbols` / `symbols indexing` / `not covered by symbols` / `unknown module`)
with what to do about each. `TDapServer.SyntheticSourceText` /
`SyntheticSourceRef` / `AttachPlaceholderSource` / `HandleSource`; references are
reused per frame label so the client can cache them.
MCP needs no equivalent -- it has no editor to drive.

NEGATIVE CONTROLS RUN, not assumed -- each new test was checked to actually bite:
* step-over: with `ReadTargetPointer` put back to an 8-byte read,
  `Win32_StepOverCallWithStackArgument_LandsOnTheNextLine` fails with
  `Expected [5] but got [6] ... never stopped again`, while the OLD
  `Win32_StepOver_AdvancesWithinTheSameFrame` still passes -- confirming it never
  could have caught this.
* placeholder source: with `AttachPlaceholderSource` removed from both call
  sites, `Test_SourcelessFrame_HasPlaceholderDocument` fails in BOTH fixtures
  with its intended message.
* demangler: the unanchored assertion fails by construction on the old code,
  which returned False for any name without a leading `@`.

**PROCESS TRAP, cost one full 400 s run and a scare: NEVER edit a test-target
source while `build_and_run.bat` is running.** Editing `TestTargetCore.pas`
mid-run produced 72 failed / 39 errored across `TDebuggerTests` -- locals "not
found", getters returning code bytes (`0xEC834853`), "method invocation failed".
None of it was a real regression: the target `.exe` had already been compiled
from the OLD source while `MarkerLineInFile` read the NEW one, so every
`{BP:MARKER}` resolved to a line the binary did not have. This is the same
signature as the recorded stale-binary line-shift trap, reached by a different
route. If a run reports breakage on that scale, check for a source edit during
the build BEFORE believing the failures.

STILL OPEN from the same log, NOT addressed: frame 1 is still
`0x14FF318 (unknown module)` -- a stack address taken as a return address, the
long-standing i386-walk gap. And `FormatTyped class Raw=$47E85510
DeclaredType="TFrmColumns" RuntimeVmtClass="TAddInExpert"` at a constructor's
first line looks wrong (the runtime class should be a DESCENDANT of the declared
one, and `tmp` read as garbage there); worth its own look -- possibly locals read
before the prologue completed.

### SIDE THREAD (2026-07-29): "why does TD32 lose TDateTime, when the IDE never does?"

Question from the user, settled by measurement with the new
`DevTools\Td32AliasProbe` (see `DevTools\README.md`). Full write-up in
`TD32_FORMAT_NOTES.md` -> "Named float aliases are FLATTENED at the variable".

* The compiler resolves the alias when it WRITES the variable record: a local
  declared `TDateTime` carries CV id `$0041` (bare `Double`) on BOTH bitnesses,
  and `TDateTime`/`Real`/`Extended`/`Currency`/... have NO record in the TYPES
  table -- they are primitives. So the missing thing is the LINK from variable
  to declared type, not a type dictionary; no external name source can rebuild
  it. `S_UDT` ($0004, parsed-and-skipped) cannot help: many aliases map to
  `$0041` and nothing points back.
* The IDE is not reading a format -- it IS the compiler front end, with the DCU
  symbol tables in process (its Evaluate window answers with COMPILER error
  codes, e.g. `E2003`).
* **`.dcp` keeps the alias.** Verified on a real Win32 package: `QBFD29.dcp`
  reports `TDateTime` / `Currency` / `Double` / `Extended` as distinct hints. So
  BPL code needs no DCU reader for this. Uncovered case = a plain exe with no
  `.rsm`.
* Incidental: the `.rsm` beside a BPL can be nearly empty (`QBFDesignD29.rsm` is
  51 KB for a 10.9 MB BPL, **no locals at all**) -- the `.dcp` is the real
  RSM-format provider for packages, so the "RSM is OLDER" console warning
  matters less than it reads. That package's `.rsm` now also has the same
  mtime as its `.bpl`, so the warning the user saw should already be gone.
* `DEBUG_INFO_FORMATS_TODO.md` P2 (DCU = WON'T DO) amended: its "zero consumer"
  claim was too strong. Verdict unchanged -- the payoff is rendering only, and
  the cheap option for the uncovered case is reading the DECLARATION from the
  source, not a DCU reader.

FIXED in the same change set (two real decoding gaps, both bitness-independent):
`PrimitiveTypeName` had no case for `$0044` (`Real48`), so such a local reported
an EMPTY type name; `ArrayElemByteSize` (the oracle behind `TypeSizeById`, which
feeds `TClassMember.TypeSize` and thence the evaluator's getter-return decoding)
covered neither `$04` (Currency, 8) nor `$44` (Real48, 6) and returned 0.
Pinned by `TD32ReaderTests.PrimitiveIds_CurrencyAndReal48_HaveNameAndSize`.

NOT CHANGED, flagged deliberately: `ArrayElemByteSize` returns 8 for `$42`
(`Extended`), commented "stored 8". `$42` only ever appears in 32-bit output,
where the type really is 10 bytes -- so `array of Extended` strides wrong and a
member size is wrong on Win32. Left alone because `TypeSize` feeds read widths
into 8-byte slots (`ExprEval.pas:755/791/804`) and widening it blind could
overflow one. Needs its own pass with a test.

GATE NOTE: the full `build_and_run.bat` could NOT run -- `F2039 Could not create
output file ...VisualStudioCodeDelphiDebugger.exe`, because a LIVE adapter
(debugging `bds.exe`) held it. Only `build_runner.bat` + `run_tests.bat` was
run, i.e. the reader change is compiled into RunTests.exe but the adapter binary
under test is the previous build. Re-run the full suite once the user's session
is closed.

### THE FIFTH host-vs-target SITE: the exception readers. Found IN THE FIELD.

Reported by the user debugging a design-time package: `bds.exe` is 32-bit, so a
design-time BPL session is a Win32 target. Every exception stop showed a bare
`Delphi exception at $751C9F54` -- no class, no message, `$exception` not
evaluatable, and therefore exception-TYPE FILTERS silently matching nothing.

One root cause, four symptoms. In `WinDebuggerBase.pas`:

* `ReadDelphiExceptionClass` read 8 bytes for the object's VMT pointer (4 on
  Win32) and looked for TypeInfo at a hardcoded -168 (-72 on Win32).
* `ReadDelphiExceptionClassChain` the same, plus ParentInfo at a literal +8.
* `ReadDelphiExceptionMessage` had `EXCEPTION_FMESSAGE_OFF = 8`; `FMessage` is
  the first field, so it follows the VMT pointer -- offset 4 on Win32.

The cascade: `FExceptionObjAddr` is published ONLY once the class read succeeds,
so a failed class read also removed `$exception` and left the filters nothing to
match on. All three now go through the new `TWinDebugger.ReadTargetPointer` and
`TargetLayout.VmtTypeInfo`.

NEGATIVE CONTROL RUN: with `ReadTargetPointer` forced back to 8 bytes the new
test reports `x64 "Exception" vs x86 "Delphi exception at $751C9F54"` -- the
user's symptom, verbatim. Pinned by `Win32_ExceptionStop_NamesClassAndMessage`,
which launches with `-run-exception-test` (the raise is switch-gated; without
the argument the target exits without raising and the test passes vacuously --
which is exactly how the first version of it failed).

### THE FOURTH host-vs-target SITE, and the biggest one: FIXED

`TDelphiRtti.GetClassProperties` walked `TTypeData`/`TPropInfo` with `ReadU64`
and literal 8-byte offsets. On a 32-bit target it desynchronised on the FIRST
record (18 bytes consumed where the record is 10), so **no property ever matched
by name** and the entire live-RTTI property surface silently fell back to debug
info. It looked like a cosmetic type-name difference (`TDateTime` rendering as
`Double`) because the fallback path still produced correct NUMBERS from TD32,
whose primitive `$0041` collapses Double/TDateTime/Real onto one id.

Fixed by expressing every offset in `FLayout.PointerSize` and reading pointers
through the new `ReadTargetPointer`. The accessor-kind tag lives in the TOP BYTE
of the getter pointer, so its shift follows the pointer width too --
`System.TypInfo`'s `PROPSLOT_MASK` is `$FF000000` at 32-bit and
`$FF00000000000000` at 64-bit (`System.TypInfo.pas:267-274`).

Result: full parity. Both bitnesses now report
`Single 1.5 [Single] / Double 3.25 / Real 6.75 [Real] / Extended 2.5 [Extended]
/ TDateTime 2023-03-15 12:00:00.000 (45000.5) [TDateTime] / Currency 19.95 /
Int64 0x1122334455667788`.

**How it was found:** adding an `AsExt: Extended` getter to the test target made
`Win32_ObjectFields_MatchWin64` fail with `[Double]` vs `[]`. The empty type
name was the visible tip; the desynchronised walk was the cause.

`AsExt` and `AsPtr` are now asserted as DELIBERATE divergences in that test:
`Extended` is a true alias of `Double` on Win64 (same TypeInfo, so the reported
name really is `Double`) and a distinct 10-byte x87 type on Win32; `NativeUInt`
is `UInt64` vs `Cardinal`. Reporting one type on both would be the bug.

### The rest of the RTTI walks were 64-bit-only too: FIXED

Finding `GetClassProperties` broken made the obvious next question "what else",
and the answer was every remaining RTTI table walk in `DelphiRtti`:

* `TFieldExEntry` -- fixed part is `5 + ptr`, was a constant 13.
* `TRecordTypeField` -- fixed part is `2*ptr + 1`, was a constant 17. Both
  members of `TManagedField` are pointer-width, including the `NativeInt`
  offset, whose old read even carried the comment "= 8 bytes on Win64".
* `tkDynArray` `TTypeData` -- `elType2` is at `8 + ptr`, was a constant 16.
* The dynamic-array variable slot itself, read 8 wide.
* Three separate copies of the ParentInfo walk, all `TypeDataAddr + 8`; they
  are now one `TryReadParentTypeInfo`.

`TDelphiRtti.ReadU64` is DELETED rather than left unused: everything 8 bytes
wide in these records is a pointer or a NativeInt, so the function only existed
to reintroduce this bug. A comment in its place says so.

Pinned by `Win32_RecordAndDynArrayExpansion_MatchWin64`, which compares a
managed record's expansion (a string plus a dynamic array, so one subject covers
the record field table and the dyn-array header) across both bitnesses.
Honest limitation: that test asserts cross-bitness PARITY of the result, not
that the live-RTTI path specifically served it -- the record could be expanded
via TD32 members instead. The walk fixes themselves are correct by construction
against the RTL's own declarations in System.TypInfo.

### Float types wider than the 8-byte value slot: FIXED

Measured with the now dual-compiling `DevTools\Win32FloatAbiProbe`:
`Extended` is 10 bytes on Win32 and 8 on Win64 (a true alias of `Double`);
`Extended80` is 10 on BOTH; `Real48` is 6 on both. `Real` is 8 everywhere --
a `Double` alias -- so the pre-8087 software float lives on under the name
`Real48`, not `Real`.

An `Extended` local on Win32 previously read back as **-1.72723371101889E-77**
for a stored 2.75: 8 of the 10 bytes keeps the mantissa and drops the exponent.
`ReadValueSlotRaw` in `DelphiValueReaders` is now the single entry point for
reading a value slot; it consults `WideFloatByteSize` and narrows all three to
Double bits. The three former call sites (two in `Win64Debugger`, one in
`VariableExpander.SyntheticLocal`) pass a read closure. `Real48` gets its own
decoder transcribed from the RTL's `_Real2Ext`.

TRAP while testing this: a local that nothing ever reads gets its store ELIDED
even under `-$O-`, so `R48` measured as 0 until a later use was added. That was
the compiler, not the decoder -- do not chase a zero without first making the
variable live.

Pinned by `Win32_WideFloatLocals_ReadTheirFullWidth`.

The WRITE direction had the identical defect and was found only because the user
challenged the claim that floats worked. `EncodeValueForType` emits 8 bytes of
IEEE double for any float, so a Win32 `Extended` kept its old sign and exponent
bytes. `TryEncodeWideFloat` now runs BEFORE it, mirroring how the enum encoders
are already tried first, and `EncodeAndWriteValue`'s buffer grew from 8 to 16
bytes. `Real48` was rejected outright on both architectures.

NEGATIVE CONTROL RUN, not assumed -- with the fix disabled the new test reports:
`x64 R48: set rejected | x86 Ext1: wrote 9.5, read back "3.002136" |
x86 R48: set rejected`. `x64 Ext1` correctly does NOT fail, since `Extended` is
`Double` there and the generic encoder was already right.

Pinned by `Win32_SetWideFloatLocals_RoundTrip`, which COLLECTS failures instead
of asserting per case: both executables are named `TestTarget.exe`, so a message
built from the file name cannot say which bitness failed, and stopping at the
first failure hid the x86 case entirely on the first attempt.

### x87 stack leak: HYPOTHESISED, MEASURED, DISPROVED -- do not "fix" it

The capture stub does `fnsave` + `frstor`, which puts the CALLEE's state back --
including the returned value, since popping it is the caller's job under the x87
ABI and the stub is not the caller. That looks like a one-slot-per-call leak that
would overflow the eight-register stack on the eighth float evaluation.

It does not happen. `RunMethodCall` saves the thread context with
`CONTEXT_FULL or CONTEXT_FLOATING_POINT` before the call and restores it after
reading the result (`WinDebuggerBase.pas:3277`, `:3335`); on a WOW64 thread that is
the same physical x87 stack, so the restore discards the leftover.
Measured: 12 consecutive `Self.AsDouble` evaluations in one session, all 3.25.

Pinned by `Win32_RepeatedFloatEvaluations_DoNotExhaustTheX87Stack` (10 calls),
because the dependency is invisible: removing `CONTEXT_FLOATING_POINT` from that
save/restore breaks nothing until the eighth evaluation.

### Environment traps hit this session

* Two idle `DelphiDebuggerMcp.exe` instances (children of `claude.exe`) held a
  lock on their own exe and made `build_and_run.bat` die with
  `F2039 Could not create output file`. No live debuggees under them; killed
  both to unblock. **Expect this again** -- any editor session with the MCP
  server registered will re-take the lock.
* `.claude/worktrees/` is now git-ignored (agent worktrees are full checkouts).

## DONE (2026-07-21): two defects found while REJECTING the TD32 sidecar idea.

A TD32 sidecar (mirror of the `.rsm` `.idx` for the `.debug` section) was
investigated and REJECTED on measurements: only 2.1-2.4x faster to load than a
full TD32 parse, and the sidecar would be 2.6-3.8x LARGER than the section it
replaces (105 MB for a 44 MB package). Do not revisit without a new argument.
The investigation did surface two real defects in shipped code; both are fixed
here. Suite: **864 found / 862 passed / 0 failed / 0 errored / 2 ignored**
(baseline 861/859/0/2, +3 new tests). NOT COMMITTED.

### Fix 1 -- quadratic locals append in `TD32FileReader.AppendLocalToScope`.

It built the same locals into TWO `TDictionary<K, TArray<TLocalSymbol>>` with
`Existing := Existing + [L]`, i.e. a full array realloc+copy per local, twice,
inside `ParseAllAlignSymbols` (~51% of a TD32 parse).

Now: one flat append-only store `FLocalsStore` plus two singly-linked index
chains (`FLocalNextByName` / `FLocalNextByRva`, `-1`-terminated) whose heads and
tails live in `FProcLocalChains` / `FRvaLocalChains`. Append is amortised O(1);
each local is stored ONCE instead of once per index; `GetLocalsForFunction*`
materialise the chain in link order, which is exactly the old parse order.

`LoadFromFile`, medians of 5, the SAME probe built against both revisions
(`C:\Athens\__ClaudeTools\Td32LocalsPerf`, `build.bat` / `build_before.bat`;
`before_core\` holds the git-HEAD reader):

| input | before | after |
|---|---|---|
| TestTarget.exe 5.6 MB | 39 ms | 34 ms |
| dxRichEditCoreRS29.bpl 11.9 MB | 110 ms | 96 ms |
| cxLibraryRS29.bpl 54 MB | 585 ms | 494 ms |

Reader heap after loading cxLibraryRS29: 161.5 -> 152.6 MB.

HONEST SIZING: this is -13..-16%, not the multiple the shape suggested. The
tail is short -- 146,279 locals over 48,124 name keys, longest chain 398; the
by-RVA index has 115,332 locals and a longest chain of 33. The remaining ~500 ms
is byte-walking, not container churn. If more is needed, the phase itself has to
change, not its storage.

CORRECTNESS, proved not assumed: `Td32LocalsProbe dump` writes every locals
answer -- all 48,124 by-name keys sorted, plus every line-table RVA and every
`RvaToFunctionStart` of one, hit and miss alike, with all 9 `TLocalSymbol`
fields. Before/after dumps are SHA-256 identical on all three inputs
(569,355 lines for cxLibraryRS29).

### Fix 2 -- RSM sidecar publication (one path could hang the debugger).

`DebuggerCore\RsmFileReader.pas`, `DebuggerCore\RsmDecoders.pas`:

1. **Atomic publish.** `PublishSidecar` writes `<idx>.<pid>-<tid>.tmp` and
   `MoveFileEx(..., MOVEFILE_REPLACE_EXISTING)`s it into place. The old code
   wrote straight over the final path, so a reader could load a partial file.
2. **The loser no longer deletes the winner's file**, and no failure escapes:
   both the rename failure and the temp-file cleanup are swallowed, and only
   OUR temp file is ever deleted. Previously the `except` deleted
   `SidecarPath` outright and, when that delete ALSO failed (the file being
   open is precisely when the write failed), the exception escaped the index
   thread -> `FIndexReady` never set -> every later `WaitForIndex` burned its
   full 60 s budget. `DevTools\PrebuildIdx` next to a live session hits this.
3. **Readiness before I/O.** `SaveProcIndexToSidecar` is split into
   `SerializeIndexToStream` (under `FLock`) + `PublishSidecar`, and the index
   thread now does serialise -> `MarkIndexReady` -> write. The earlier note
   ("moving readiness before the save is unsafe") was right about the
   SERIALISATION and wrong about the WRITE: serialising first keeps the byte
   stream reproducible (lazy lookups mutate `FProcLocals` the moment the index
   is ready), while the file write -- the part that can block on a slow or
   network directory -- no longer gates symbol availability. `MarkIndexReady`
   sits in a `finally` that also covers the phase waves, so no failure path can
   leave `FIndexReady` False. The build body moved into
   `TRsmFile.BuildIndexAndPublish`.
4. **`SidecarWriteStr` truncation.** The UTF-8 length was a silently truncating
   `UInt16` assignment; over 64 KB the writer emitted more bytes than the
   length it wrote and the whole rest of the sidecar decoded as garbage,
   undetectably. Now `$FFFF` is an escape introducing a `UInt32` length.
   `RSM_SIDECAR_MAGIC` is **unchanged and deliberately so**: every string under
   64 KB encodes byte for byte as before, and no old sidecar can contain the
   sentinel except for a string of exactly 65535 bytes, which no `.rsm`/`.dcp`
   name comes near. Byte identity re-verified with `PrebuildIdx -verify`
   against sidecars built by the pre-change code (6/6 verified: Abbrevia290,
   CPortLibAthens, CoolTrayIconAthens `.rsm`; libAboutBoxD29, libElaborazioniD29,
   DGOdacD29 `.dcp`).

Tests (3 new, all in `RsmReaderTests`): `Sidecar_LongString_RoundTripsWithoutDesync`,
`Sidecar_PublishRace_LeavesTheOtherWritersFileIntact` (ages the sidecar, holds
it open with `fmShareDenyWrite`, forces a rebuild: readiness must still be
published within a bounded budget, the file must be intact and byte-identical,
no `.tmp` left behind), `Sidecar_Corrupt_IsRejectedAndRebuilt` (truncated AND
garbled-body variants: same symbol set as a clean build, and the sidecar is
valid again afterwards). A/B verified: with the pre-change readers restored,
the long-string and publish-race tests fail with exactly their intended
messages.

### OPEN, deliberately not touched (policy decisions, not defects)

- **Sidecars are still written into the Embarcadero `Bpl\Win64` / `Dcp\Win64`
  directories.** Moving them to a user-writable cache changes the freshness
  contract, the `PrebuildIdx` workflow and the shipped-corpus story. Needs a
  decision, not a patch.
- **Two disagreeing freshness rules**: `RsmFileReader.pas:664-665` accepts a
  sidecar whose mtime is `>=` the source's; `PeSymbolSupport.pas:69-81` uses a
  different rule for the same class of question. They should be reconciled by
  one owner.
- **Pre-existing hazard, unchanged by this work**: `TRsmFile.LookupEnumInfo`
  mutates `FEnumInfoByName` (the lazy set base-type resolution) WITHOUT
  `FLock`, while the index thread writes the same dictionary under it. Same
  class as the `LookupTypeName` bug fixed on 2026-07-20; a rehash under a
  concurrent read is an AV. Four-line fix, left out to keep this change set to
  its two subjects.
- **Observation**: the `.idx` files shipped in the local Embarcadero
  directories do NOT match what the current parser produces (`PrebuildIdx
  -verify` reported 6/6 MISMATCH against them, while HEAD-built ones verify
  6/6). They predate the 2026-07-20 two-wave fix, i.e. they are the degraded,
  lossy indexes. Consider a one-off `PrebuildIdx -r -force` over those trees.

## PARTIAL: background symbol PREFETCH -- built, documented, SHIPPED DISABLED.
## The concurrency fixes around it ARE live (2026-07-20).

READ THIS FIRST. The prefetcher is complete and wired into both frontends, but
`SetSymbolPrefetchEnabled` defaults to FALSE (`SYMBOL_PREFETCH=1` turns it on),
because with it enabled the full suite reproducibly loses 1-3 requests per run
to a 30 s response timeout -- always in `TDebuggerTestsBpl`, always `seq=6`
(the first request after the first stop), never in isolation, never in the mono
fixture. That is the same signature that disabled the previous background
loader. Isolated by running the IDENTICAL build with the prefetcher off: clean,
0 errored. So the cause is the prefetcher, not the reader-level fixes.

Everything ELSE below is live and green: the six concurrency fixes, the removal
of the dead DAP loader, the single-load-path claim protocol, the publication
plumbing in `TDebugSession.Pump`, and the DAP `invalidated` push.

WHAT WAS ALREADY RULED OUT as the cause of the timeout (do not re-walk):
- The dispatch thread WAITING for the worker. First implementation waited up to
  750 ms (further capped by the interactive budget); removing the wait entirely
  in favour of revoke-or-decline did NOT fix it.
- Repost churn. Publication no longer fires `OnSymbolsLoaded` per module; the
  session reposts once per drain. Did not fix it.
- Locals re-parse storms. `GetLocalsForFunction` now serves a provisional cache
  instead of re-waiting per lookup. Did not fix it (that run was WORSE: 3).
- Publishing while the debuggee runs. Publication is confined to stops; that DID
  fix a separate, real bug (missed breakpoints), but not the timeout.

NEXT STEP when this is picked up: get the adapter's own log for a hung run.
`DAP_LOG=1` plus `RUNTESTS_ONLY=TDebuggerTestsBpl` in a loop until it fails,
then find the largest timestamp gap in `%TEMP%\dap_adapter.log` (the file is
append-only across adapter instances, so the whole run's history is there). The
one thing NOT yet done is looking at where the adapter actually sits during
those 30 s; every hypothesis above was reasoned, not observed.

## DONE (the part that IS enabled): the concurrency work under the prefetcher.

The "frames come back WITHOUT NAMES" complaint. Root cause was WHEN, not how
fast: `HandleDllLoaded` parses a module only when a breakpoint already owns its
source, so with no breakpoints -- the state right after attach -- nothing is
parsed for any module and the first stop pays a full synchronous parse per
module on the stack (measured 98-652 ms per real BPL; TD32 is 68-71% of it and
is the only provider that names frames).

Shipped, in dependency order.

**Pre-existing concurrency hazards, closed FIRST (they were live before this
change and this change would have made them frequent):**

1. `RsmFileReader.SaveProcIndexToSidecar` enumerated `FProcLocals` / `FGlobals`
   / `FTypeIdToName` / ... with NO lock, on the index thread, while the
   dispatch thread mutated `FProcLocals` under `FLock` -- reachable today the
   moment the 3 s interactive budget expires. Now serialises into a
   `TMemoryStream` under `FLock` and writes the file with the lock released.
   Byte stream unchanged.
2. `LookupTypeName` (+ the three `Diag*` siblings) read `FTypeIdToName` /
   `FClassHashCandidates` unlocked while wave 1 wrote them under `FLock`. A
   `TDictionary` rehash under a read is an AV, not a wrong answer. Locked.
3. `GetLocalsForFunction` pinned locals in `FProcLocals` even when
   `WaitForIndex` had TIMED OUT, i.e. parsed against a half-built index with
   blank/wrong type hints -- and pinned it for the session.
   `WaitForIndex` is now `function: Boolean` (True = index actually ready). A
   result derived from a not-ready index goes to a separate
   `FProvisionalLocals` cache instead of `FProcLocals`: it is still served (so a
   `variables` request expanding many children does not pay the whole
   wait-and-reparse per child -- that alone could burn the interactive budget
   several times over in one request) but it is dropped wholesale the moment the
   index completes, so nothing derived from a half-built index survives.
4. `TRsmFile.InteractiveDeadlineTicks` and `TInteractiveWaitGuard`'s depth are
   now THREADVARs. As process-wide class vars a worker inherited the dispatch
   thread's 3 s budget (abandoning its own index build) and cleared it on scope
   exit (disarming F14 protection mid-stop).
5. `TTD32FileReader` mutated itself on the hot path: `ResolveNameByIndex`
   lazily built `FNamesByIndex` and did `FNamesCache.Add` (not AddOrSetValue).
   The names table is now built during `LocateNamesSection` and `FNamesCache`
   is deleted, so a loaded TD32 reader is immutable -- which is what makes it
   safe to build one on a worker and hand it over.
6. `TWinDebugger.GetStackFrames` stamped the frame cache with the revision read
   AFTER the walk and sampled `AnyBackgroundIndexingPending` only before it.
   Now snapshots the revision before and re-samples indexing after.

**The feature:** `TSymbolPrefetcher` in `DebuggerCore\ModuleSymbolLoader.pas`
(not in a frontend, so MCP gets it too -- it had no loader at all). One worker
thread; value-snapshot requests in, finished unregistered readers out;
publication on the dispatch thread from `TDebugSession.Pump`. Design rules and
the reasoning behind each are in `DAP_DEBUGGER_ARCHITECTURE.md` -> "Symbol
prefetcher". The short version: claim the module before the worker starts;
never mark a claimed module as tried; steal the request back rather than wait
for it; publish only while stopped; one breakpoint repost per drain; enqueue
last in `HandleDllLoaded`; never enqueue from the stop path.
`NO_SYMBOL_PREFETCH=1` disables it.

THE ONE THING THAT MUST NOT BE REVERTED: `PrefetchBlocks` never waits. An
intermediate revision let the dispatch thread wait briefly (750 ms, further
capped by the 3 s interactive budget) for a parse already under way. That alone
reproduced the exact failure that got the previous background loader disabled --
one request per full-suite run timing out in `TDebuggerTestsBpl`, always
`seq=6`, always zero failures in isolation. Proven by running the full suite
with `NO_SYMBOL_PREFETCH=1` (clean, 0 errored) against the same build with it
enabled (1 errored per run). A bound is not enough: publication, breakpoint
reposting and further module loads all run on the dispatch thread and compound.
Revoke-or-decline only.

**Removed:** the shelved `DAP_BG_LOADER` code in `DapServer.pas`
(`StartSymbolLoader` / `StopSymbolLoader` / `ParseDllReaders` /
`RegisterParsedModule` / `EnqueueBackgroundLoad` / `ResolveDcpPath` /
`TModuleLoadReq` / `TParsedDllReaders`, ~280 lines). It registered the module
MAP with `AddProvider` (UNSCOPED) where the synchronous path uses
`AddProviderForModule` (RVA-range-scoped), so the provider topology depended on
which path won a race; and `StopSymbolLoader` called
`TThread.RemoveQueuedEvents(nil)`, which cancels queued main-thread events
process-wide.

**Added:** DAP sends `invalidated(stacks)` when the prefetcher registers
providers while stopped, so a stack already drawn with nameless frames is
re-fetched without the user doing anything. MCP needs nothing equivalent: it
re-reads on every request and the frame cache is revision-keyed.

Tests (4 new): `RsmReaderTests.WaitForIndex_ReportsWhetherIndexWasReady`,
`RsmReaderTests.InteractiveDeadline_IsPerThread`,
`DebugSessionTests.Prefetch_NoBreakpoints_LoadsRuntimePackageSymbols` (the
"when" regression: two packages load, no breakpoint exists anywhere, both must
end up with symbols -- before this change neither would),
`DebugSessionTests.Prefetch_ModuleLoadedSynchronously_IsNotParsedAgain`
(single-load-path: no claim on a module the dispatch thread already loaded, and
no duplicated locals from a double registration).

THE TRADE, stated plainly: a frame whose module happens to be MID-PARSE on the
worker now comes back nameless for that one request, where before it came back
named after a synchronous parse. It self-corrects -- the provider-set revision
bump invalidates the frame cache and the DAP pushes `invalidated(stacks)` -- and
it is the deliberate price for never blocking the loop. The common case moves
the other way: a module parsed at its LOAD_DLL event is already registered when
the stop happens, so its frames are named immediately AND cost nothing.

MEASUREMENT, honestly: the fixtures CANNOT show a change in named-frame count
at a first stop. Every fixture stop has a breakpoint in the module it stops in,
so the synchronous eager gate loads that module before the stop in both the old
and the new code; and the neutral core's `TModuleSymbols.ContainsSourceFile` is
deliberately conservative (True whenever any sidecar path is set, which is
always), so at DebugSession level ANY breakpoint makes the gate load EVERY
module. What is measurable is the state the new test asserts: with no
breakpoint, a runtime-loaded package went from "no symbols, ever, until a stop
touched it" to "symbols already registered".

KNOWN NARROW HOLE (accepted, documented): a breakpoint SET WHILE THE TARGET IS
RUNNING, in a module whose prefetch the worker has already started, does not
bind on that call -- the sweep declines rather than waits, and publication is
held until the next stop. It binds at that stop (the drain reposts). Modules
that own a breakpoint at their LOAD_DLL event are never affected: the eager gate
loads them synchronously and `EnqueuePrefetch` then skips them entirely.

NOT DONE, deliberately:
- `WarmupSymbolProvidersForEvaluate` (`DapServer.pas`) is still O(N) over every
  eligible module. It is not restructured; what defuses it in practice is that
  the prefetcher has normally already loaded those modules, so the loop's
  `EnsureModule*` calls find everything registered. A launch config naming a
  module in a shared BPL output directory with prefetch disabled still has the
  7-55 s worst case.
- The prefetcher stays single-worker. Bounded on purpose: `TRsmFile` fans its
  index build out with `TParallel` and `TMapFile` forks its own thread, so more
  prefetch workers would oversubscribe the shared pool against the very stop
  they are meant to help.
- `TDebugSession`'s conservative `ContainsSourceFile` still makes the eager
  gate load every module once any breakpoint exists (the DAP overrides it with
  an authoritative PACKAGEINFO check; MCP does not). Worth fixing separately --
  it is the reason MCP does more synchronous work at module-load than DAP.

## DONE: cold symbol-index build -- 2.2-2.4x faster AND reproducible (2026-07-20).

Complaint: at a breakpoint in a real app, symbol data is not ready yet, which
"makes a bad impression". Three profiling passes were run first; this change set
takes the measured wins and skips the rest with reasons.

Shipped (`DebuggerCore\RsmFileReader.pas`, `DebuggerCore\MapFileReader.pas`):
1. Sidecar writers go through `TBufferedFileStream` instead of a raw
   `TFileStream`. The per-field `WriteBuffer` calls were one `WriteFile` syscall
   each (~246,000 / 2.9 MB on cxLibraryRS29.dcp at ~2.4 us apiece): 585 -> ~10 ms.
   Same one-line fix in `TMapFile.SaveUnitIndexToSidecar`.
2. `ParseUserTypeTable`: the nested `MatchesAt` / `LooksLikeTypeRefAt` are now
   prefiltered at the call site (64-bit compare / tag byte). Nested functions
   carry a static link and can never be inlined, so every byte of the file paid
   a real call. Same trick in `FindUserTypeTableAnchor` (18-byte anchor: reject
   on the first 8 bytes with one compare).
3. `ParseTypeInfoSection` + `ExtractTypeInfoNames`: the 8-byte `$08 00 ...`
   TypeInfo prefix is one unaligned `PUInt64` compare instead of 8 byte compares.
4. The index build now runs in TWO WAVES (producers, then consumers) instead of
   one flat fan-out; `IndexClassMemberRecords` joined wave 1. This fixes a
   LOSSY, NON-DETERMINISTIC build: consumers resolved type hints against
   dictionaries the producers were still filling, so three cold builds of the
   same TestTarget.rsm gave three different sidecars (699427/699421/699428 bytes),
   all short of the sequential 699512, and the degraded index was cached in the
   `.idx`. Also removes an unlocked concurrent `TDictionary` read (AV risk) in
   `LookupTypeName`. See `DAP_DEBUGGER_ARCHITECTURE.md` -> Threading model ->
   Symbol index build.

New tool `DevTools\PrebuildIdx.dpr` (`-r -j N -verify -force`): builds `.idx`
for a whole directory offline; `-verify` SHA-256-compares against the existing
sidecar (that is the byte-identity harness for any future parser change).

Cold build, median of 3, page cache warm, sidecar deleted per run
(probe `C:\Athens\__ClaudeTools\IdxVerify`):
| input | before | after |
|---|---|---|
| cxLibraryRS29.dcp 45.5 MB | 1200 ms | 523 ms |
| Spring.Base.dcp 36.9 MB | 907 ms | 374 ms |
| Tee929.dcp 4.2 MB | 106 ms | 57 ms |
| SampleApp.rsm 2.2 MB | 58 ms | 31 ms |
| DapAdapter.rsm 17 MB | 399 ms | 164 ms |
| TestTarget.rsm | 299 ms | 107 ms |

All six sidecars are now byte-identical to a fully sequential reference build
and stable across runs (6 consecutive SampleApp builds: one hash).

SKIPPED, with reasons (do not re-walk):
- Container-aware `ParseUserTypeTable` (skip the System-anchor scan and the
  TypeInfo fallback on `.dcp`): would have been ~17% before item 2, but items 2
  and 3 already removed most of that cost, and it is the only proposal that is
  NOT byte-identical by construction (it would need a diff across the 622-file
  DCP corpus to justify). Not worth the risk now.
- Chunked/parallel `IndexClassMemberRecords` (x11 on the phase, -20% end to end):
  measured to change the output on 1 of 4 inputs (TestTarget.rsm) because a chunk
  boundary lands inside a record the serial scan had skipped. Needs a boundary
  arbitration rule first.
- Pointer-cursor sidecar DECODER (warm load 17 -> 15 ms on the biggest file):
  ~130 lines of second decoder to keep in lockstep with the format for ~3 ms.
- Hand-written sidecar encoder (7 vs 10 ms after buffering) and pre-sizing the
  buffer: measured, not worth the code.
- Compiling `DebuggerCore` with `-$O+`: MEASURED, only ~5% (636 -> 601 ms on
  cxLibraryRS29.dcp with the adapter's own `-$O- -$R+ -$Q+` flags). The scans are
  memory-bound, not codegen-bound. Not worth losing a debuggable adapter build.
- Moving `SaveProcIndexToSidecar` after `FIndexReady := True`: unsafe (the saver
  enumerates containers that lazy lookups mutate), and pointless now that the
  write is ~10 ms.

NOT DONE -- the headline "frames come back WITHOUT NAMES" is a DIFFERENT bug:
`TRsmFile` does not implement `IFunctionNameProvider` at all (only
`TD32FileReader`, `MapFileReader`, `JclDebugReader` do). Frame names are gated on
`EnsureModuleTD32/Map/Jcl` having run for that module, which happens lazily at
the stop (`DebugSession.pas:1141-1145`, uncapped, ~157 ms of synchronous TD32 per
module). The `.idx` governs the SECOND symptom: locals/types arriving late. NEXT
STEP for the nameless frames is the WHEN work (module-load enqueue + single load
path, TASK_RESUME "BACKGROUND SYMBOL LOADER" below), not more parser speed.

## DONE: F23 -- a nameless frame was silent about WHY it had no name (2026-07-20).

Live after attach: paused frames rendered with an EMPTY function name and nothing
else. Three different situations produced that same rendering (address in no known
module / module without debug info / module whose index is still building), and
`TSessionFrame.ModuleName` was declared but NEVER assigned, so `McpJson`'s
`if F.ModuleName <> ''` guard could not fire and the DAP degraded to a bare `0x…`.

Shipped (additive; no change to WHEN symbols load, `HandleDllLoaded` untouched):
- `DebugInfoTypes.pas`: `TSymbolAvailability` (`saUnknownModule` / `saNoSymbols` /
  `saIndexing` / `saLoaded`) + `SymbolAvailabilityName` (shared wire spelling).
- `ModuleSymbolLoader.pas`: `TModuleSymbols.SymbolAvailability` (a provider is
  asked whether it is indexing ONLY if registered -- an unloaded `TMapFile` reports
  "pending" because it never started) and `TModuleSymbolLoader.DescribeAddress`,
  which also covers the MAIN exe via `ImageBase` + PE `SizeOfImage` (`FMainImageSize`),
  since the exe is deliberately NOT in the runtime registry.
- `TSessionFrame.Symbols` + `ModuleName`, filled in `TDebugSession.FrameToSession`.
- MCP: always emits `symbols`, plus `module` when known. DAP: `moduleId`, and
  `NamelessFrameLabel` renders `0x… (module: reason)`.
- `TWinDebugger.GetStackFrames`: cache neither SERVED nor STORED while
  `AnyBackgroundIndexingPending` -- an incomplete symbolication used to be pinned
  for the whole stop. (The seed-captured cache key from earlier today is intact.)

Test: `DebugSessionTests.Frames_NoDebugInfoModule_ReportModuleAndSymbolState`
(launches `NoDebugExe.exe` with stopAtEntry; asserts blank name BUT
`ModuleName = 'nodebugexe.exe'` and `Symbols = saNoSymbols`).
Suite: 856 found / 854 passed / 0 failed / 2 ignored.

Root fix NOT taken on purpose: symbolicating every module during the attach burst
is O(N) synchronous parsing on the pump thread = the F14 freeze class
(`DebugSession.pas:1020-1029`). See the F23 entry in `MCP_LIVE_FINDINGS_TODO.md`.

Measured with a throwaway probe (`C:\Athens\__ClaudeTools\FrameCacheProbe`): the
"indexing pending" window IS real in the fixtures at a stopAtEntry stop, but the
frames blank there are `kernel32.dll` / `ntdll.dll` -- genuinely `saNoSymbols` --
so no name was observed to appear on retry; the fixture MAP index finishes far
faster than any frame it would resolve is needed.

## DONE: F19 -- step_into stopped at the callee's ENTRY, before the prologue (2026-07-20).

Reported live on a real application: `step_into` into a method reported at the
function's ENTRY address, so the first thing shown was garbage --
`Self = -1232 (0xFFFFFB30)`, correct type, expandable: false -- and one extra
step_over turned it into the real instance. A normal breakpoint on the SAME first
statement was verified correct (it binds to the line-table address, past the
prologue), which is why this looked like a value-decoding bug.

Root cause (`DebuggerCore\WinDebuggerBase.pas`, `EXCEPTION_SINGLE_STEP` / `smInto`):
the entry address ALREADY maps to a source line, so the naive `AtNewLine` test
("a source line different from where the step started") is satisfied by the
callee's very FIRST instruction -- RBP still the caller's, no register argument
spilled to its home slot. Every `[rbp+N]` read is the caller's frame.

Fix: new `TWinDebugger.FunctionBodyStartVA(VA)`. When an `smInto` landing would be
reported and the body start is still ahead, plant a one-shot BP there and resume
full speed; the existing run-to-`FStepOverVA` path reports it as a step. A one-shot
BP rather than more single-stepping because a preamble may CALL (managed-local
init, stack probes) and single-stepping would dive into sourceless RTL and
resurface mid-preamble.

TRAP measured en route: **`UNWIND_INFO.SizeOfProlog` alone is NOT the boundary.**
Disassembling `TWidget.StepIntoProbe` (`DumpFunc.exe ... 15D2B0`):
`push rbp; push rbx; sub rsp,68h; mov rbp,rsp` = SizeOfProlog 9, and only THEN
`mov [rbp+80h],rcx; mov [rbp+88h],edx; mov [rbp+90h],r8; movsd [rbp+98h],xmm3`.
Stopping at entry+SizeOfProlog gave a correct-looking `Self` (its home slot lands
in the caller's stack area and happened to hold the right object) but `AInt = 1`.
So the boundary is the LINE TABLE: the first address inside the function whose
line record differs from the ENTRY's record -- exactly where a BP on the first
statement binds. `.pdata` still supplies the function extent (Begin/EndAddress)
and the `SizeOfProlog` fallback for a routine written entirely on one line (and 0
for leaf/frameless/chained, so such a routine still stops at its first
instruction). Everything unknown -> 0 -> previous behaviour.

Test: `DebugSessionTests.StepInto_Method_ReportsSpilledSelfAndParams` + fixture
`RunStepIntoPrologue` / `TWidget.StepIntoProbe(AInt, const AStr, ADbl)` in
`TestTargetCore.pas` (markers `STEPIN_CALLSITE` / `STEPIN_PROBE_BODY`). RED output
was `Self is not a live instance after step-into (value: 4668256 (0x473B60))`.

Collateral: `DebuggerTests.Test_Step_Over_FromFunctionEntry_LandsNextLine` reached
the pre-prologue entry stop BY step-into and asserted it landed on the `begin`
line -- it encoded the bug. Its real subject (step-over from an entry-RSP stop)
is preserved by reaching the entry with a BREAKPOINT on the `begin` line instead.

Full suite: **854 found / 852 passed / 0 failed / 0 errored / 2 ignored**
(baseline 853/851/0/2; +1 is the new test). Not committed -- awaiting review.

## DONE: dbghelp never learned about runtime-loaded modules (2026-07-20).

Root cause of a whole class of "one frame only" / "step-out went nowhere" reports.
`SymInitialize(FProcess, nil, True)` ran ONCE, lazily, at whichever came first --
`GetStackFrames` or `CallerReturnAddress`. `fInvadeProcess=True` enumerates only the
modules mapped AT THAT INSTANT, and `HandleLoadDll` told our own MAP/RSM/TD32 loader
about later modules but never told dbghelp. Inside such a module
`SymFunctionTableAccess64` returns nil, so `StackWalk64` silently falls back to the
AMD64 LEAF convention (`return address := [RSP]`). Just past a Delphi prologue
(`push rbp; sub rsp,N; mov rbp,rsp`) RSP == RBP, so `[RSP]` is an uninitialised local
-> the walk ends after ONE frame; after the function has made a CALL, `[RSP]` is
address-like -> a long bogus chain. Whether it bit depended purely on WHEN the first
stack walk happened: a client that walks the stack at the entry stop (VS Code does)
armed it for the rest of the session.

Same nil function table broke `CallerReturnAddress`, so `step_out` degenerated: both
its `StackWalk64` calls failed -> `RetAddr = 0` -> the fallback flipped to `smInto`
+ TF WITHOUT seeding `FStepFromLoc`/`FStepHasFromLoc` and without resetting
`FStepSafetyCount`, so the FIRST trap satisfied `AtNewLine` and reported a successful
step 3-7 bytes later, inside the same function.

Fixed in `DebuggerCore\WinDebuggerBase.pas`:
1. **ROOT CAUSE (explicit per-module registration, the preferred option).**
   `EnsureSymInitialized` (still lazy -- the invade sweep is what covers the MAIN EXE,
   which never gets a LOAD_DLL event) + `RegisterModuleWithDbgHelp` called from
   `HandleLoadDll` (`SymLoadModuleExW`, wide variant for non-ASCII paths) +
   `SymUnloadModule64` in `HandleUnloadDll`. Registration is a no-op while
   `FSymInitialized` is False -- the pending invade will see that module anyway --
   which is what keeps the ordering problem from becoming a regression.
   `SymRefreshModuleList` was NOT used: it re-scans the whole module list on every
   walk, and we already have the exact base/size/path in hand at load time.
   TRAP measured en route: `SYMOPT_DEFERRED_LOADS` (tried as a perf guard, since we
   now touch dbghelp once per DLL and never ask it for symbols) BREAKS the fix --
   the function-table callback does not reliably materialise a deferred module, so
   unwind info goes missing again. It cost the whole `Test_ClosureParam_*` BPL set
   (853/850/1/2, and 3/16 failing in isolation with a different subset each run --
   it looked flaky, it was not). Only `SYMOPT_FAIL_CRITICAL_ERRORS` is set now, and
   the constant block carries the warning.
2. **SILENT SUCCESS (bogus INT3).** `IsPlausibleReturnAddress` (executable + inside a
   module `SymGetModuleBase64` knows) now gates the `PlantInt3` in `ckStepOut` and in
   the smInto sourceless pivot. A leaf-convention guess used to be patched blindly.
3. **SILENT SUCCESS (step-out that isn't).** The `ckStepOut` smInto fallback seeds
   `FStepFromLoc`/`FStepHasFromLoc`, resets `FStepSafetyCount`, and sets the new
   `FStepMinSP`; the smInto stop test requires `RSP > FStepMinSP`, i.e. the frame was
   really left. Cleared in `ReportStopped` and at every other step start.
4. **Frame cache.** The key was WRITTEN from the `Ctx` that `StackWalk64` mutates into
   each unwound frame, but COMPARED against the live seed -- so a healthy walk never
   hit the cache while the degenerate 1-frame case did. Now captured as
   `SeedRip`/`SeedRsp`/`SeedRbp` before the loop (the synthesized-frame0 fallback and
   its log line use the seed too, which is what they always meant).

Test: `DebugSessionTests.Bpl_StackWalk_AfterEarlyWalk_ResolvesFramesAndStepsOut`
(TestTarget.exe `--load-package`, StopAtEntry, ONE GetCallStack at entry to arm the
bug, BP at `TestPkgUnit.pas` `{BP:PKG_INNER_BODY}`, assert >= 3 frames + frame 1 is
`PkgAdd`, then step_out must leave `PkgInner` at a strictly higher RSP). RED before
the fix with exactly "got 1"; A/B verified by temporarily removing the entry walk
(passed), which pins the trigger. Helpers added: `PackageSrc`, `MarkerLineInFile`
(`MarkerLine` now delegates to it).

Full suite after the fix: **853 found / 851 passed / 0 failed / 0 errored / 2
ignored** (baseline was 852/850/0/2; +1 is the new test). Not committed -- awaiting
review.

## DONE: fresh-clone portability pass (2026-07-20). Commits 714bcac..bb96cc6.

Triggered by the observation that the docs cited diagnostic tools living OUTSIDE
git. Audited every out-of-repo absolute path in the repo (289 hits) and the ~75
probe folders in the scratch tree.

- **Nine reusable probes are now DevTools tools**, argv-driven, no hardcoded
  target: `JclProbe`, `ProcessEnumProbe`, `DumpTd32Globals`, `Td32LineLookup`,
  `FindBytes`, `DumpRsmUses`, `ScanRsmConsts`, `RsmDiff` (four merged programs),
  `StepPerf`. Everything else was a one-off whose finding already lives in the
  specs.
- **`build_all.bat` now DISCOVERS `*.dpr`.** A third of the tracked tools had no
  build stanza and could not be built on a fresh clone. Guard on `%~xF` is
  required: cmd's `*.dpr` also matches `*.dproj` (8.3 short names).
- **`setpaths.bat`** resolves `JCL_ROOT` / `DUNITX_ROOT`; the hardcoded JCL and
  DUnitX paths are out of the `.cfg` files (dcc64 reads those automatically and
  they have no conditional syntax, so they were a hard build breaker off this
  machine). JCL is NOT optional: `DebuggerCore\JclDebugReader.pas` needs it.
- **42 dead doc references repaired** (54 edits, 7 files). Findings kept
  verbatim; only pointers changed. Worst was a copy-pasteable command block in
  PROJECT_STATE.md's "stable build/run commands".
- `.gitattributes` added -- CRLF was convention-only and three files had drifted
  to LF.
- Deleted two stale out-of-tree forks of `WinDebuggerBase.pas` / `DebugInfoSet.pas`
  (6 weeks old, 1501 / 628 lines diverged) that a future session could have read
  instead of the repo.

Suite after every step: 851 / 849 / 0 / 2. TRAP found and fixed en route:
`build_and_run.bat` had its own copy of the RunTests compile line instead of
calling `build_runner.bat`, so it went stale the moment the search paths moved.

NEXT: field test on SampleApp (see below) -- blocked on the user rebuilding the
target (9 sources newer than the 17/07 exe) and reconnecting the MCP server.
Re-check F9 (step_into into a not-yet-loaded BPL mis-resolves the line), F15
(worker-thread stacks), F16 (on-clause `E:` deref), plus live validation of the
round-3 fixes.

## DONE: wrong-PLACE audit ROUND 3 + 7 fixes (2026-07-19).

Audited LOCATION / ATTRIBUTION (right value, wrong place). 8 suspects, analyse +
adversarially refute: **8 confirmed, 0 refuted** -- this axis had never been
examined. 7 fixed (each full-suite green, 851/849/0/0/2), 1 documented as a hard
limit. Full record in `KNOWN_UNKNOWNS.md` ("Wrong-PLACE audit -- round 3").
1. **(HIGH) Cross-thread frame selection** -- clicking a frame of a non-stopped
   thread read the STOPPED thread's stack (frame cache was not thread-qualified;
   DAP frame ids are bare indices). Fixed + tested (`65ec2e5`).
2. **MAP 1 GB window** -> foreign addresses attributed to a loaded module.
3. **MAP unbounded nearest-preceding public** -> address named after a DATA symbol
   or a far-away routine (`PublicCanContain`). (2+3 = `23bc0c9`)
4. **TD32 line borrowed across a function end** -> frame reported in another unit's
   file; now bounded by the owning proc's EndRva. (`23bc0c9`)
5. **Watch resolved a same-named function in the WRONG MODULE** (unit linked into
   exe + package); both tiers now prefer the frame's module window.
6. **Step-over ended in a deeper RECURSIVE frame** (nested returns share the return
   address); expected post-return RSP now gates the resume BP. (5+6 = `2d31498`)
7. **Breakpoint bound to the wrong module's same-basename file** while reporting
   verified; `SourceLineToRvaCandidates` + plant every candidate.
STILL OPEN (low, HARD limit): same-basename SOURCE FILE cannot be disambiguated --
TD32 NAMES has no directory, so a frame in DOA's `Oracle.pas` can open DGOdac's.
Mitigations (keep a rooted path when a provider supplies one; warn on an ambiguous
basename) are described in KNOWN_UNKNOWNS.

## DONE: wrong-data audit ROUND 2 + 4 fixes (2026-07-19).

Round 2 audited the "compute a VALUE" paths (8 suspects, analyse + adversarially
refute): 6 confirmed, 2 refuted. Four fixed, all with tests; full record in
`KNOWN_UNKNOWNS.md` ("audit round 2"). Ranked by impact:
1. **setVariable corrupted a NEIGHBOUR variable** -- a 3-byte set slot got a 4-byte
   write (exact provider size discarded, packing table rounded 3->4). This wrote
   wrong bytes INTO the debuggee. Sets are byte-granular now; store is a
   little-endian loop (`case 1,2,4` could not emit 3/5/6/7 and wrote zeros).
2. **UTF8String / non-default-code-page AnsiString** decoded with the system ANSI
   page -> mojibake. Now uses `TStrRec.codePage` (Word at `Ptr-12`).
3. **Enum ordinal display** masked 4 bytes over an 8-byte read -> an uninitialised
   enum showed the neighbouring local's bytes. Masked to real storage width.
4. **Enum member name** masked `and $FF` -> ordinal 260 displayed as member `e4`.
   Masked to real storage width.
5. **Small POD record return** (<=8 bytes) is packed in RAX, but every record went
   through the hidden var-out slot -> watch showed a bogus zero (and the slot arg
   shifted the user args). Size-routed now; shows the packed value.
STILL OPEN (low): typeless MAP-only global reads 8 bytes and folds the next
global's bytes (fix: clamp to the gap to the next DATA public RVA).
New test infra: `TFakeMemTarget` (fixed-memory `IDebugTarget`) + `TFakeEnumSizeProvider`
in `ValueReaderTests.pas` -- deterministic unit tests for the memory/type heuristics.

## DONE: wrong-data heuristic audit (2026-07-19).

Adversarial multi-agent audit of the object/value-guessing heuristics (8 suspects,
analyse + adversarially-refute). Result: 1 MEDIUM fixed, 2 LOW deferred, 5 refuted.
Full record in `KNOWN_UNKNOWNS.md` ("Wrong-data heuristics — audit 2026-07-19").
- **FIXED (medium):** `LooksLikeVariantAt` auto-accepted varInt64/varUInt64
  unconditionally -> any untyped local == 20/21 shown as a Variant reading the
  NEIGHBOUR slot as the payload. Now falls through to False like varSmallint/
  varInteger. Added reusable `TFakeMemTarget` (a fixed-memory `IDebugTarget` fake)
  in `ValueReaderTests.pas` + `VariantAutoDetect_*` tests.
- **DEFERRED (low x2):** closure-object recovery has no reverse link (raw
  Pointer/Int64 local can latch an unrelated nearby `$ActRec`); dyn-array `^T`
  header can alias a real header (cross-type). Both need careful fixes (regression
  risk to shipped closure/array display); scenarios + fix hints in KNOWN_UNKNOWNS.
- **REFUTED (5):** closure-self fallback, interface->object, IsClassInstance,
  PickPauseReportTid, by-name-locals-lastwins -- all correctly report current target
  memory / hold under the non-optimised-target + Delphi ARC invariants.

## DONE: closures endgame — anon-method params (2026-07-19).

Investigating the "closures endgame (TD32 FIELDLIST)" roadmap item found the CORE
already shipped: captured vars expand from the TD32 `$ActRec` FIELDLIST in every
scenario (mono/BPL/NO_RSM), tests un-gated and green (commits `ca9cee9`/`1dbcb0e`/
`d7c2324`). The docs' "RSM-format-only / FIELDLIST deferred" notes were stale; fixed.

The only genuine remnant — the anon body's OWN declared param (`procedure(X: Integer)`,
`Clo(7)`) — is now DONE via a general param decoder (option "build the real param
decoder"). Proven by a one-off closure-param probe (finding recorded here) that no provider
carries the anon-body frame's slots, but the `$ActRec` FIELDLIST DOES carry the
`$0$Body` method reachable to its ARGLIST.

What shipped:
- **TD32 method-signature decode.** New `IMethodSignatureProvider.TryGetMethodParams`
  (`DebugInfoTypes` + `TD32FileReader`, aggregated in `DebugInfoSet`): on-demand walk
  of the class FIELDLIST for LF_METHOD/LF_ONEMETHOD by name -> LF_METHODLIST (entry =
  attr(2)+mfunction(4)) -> LF_MFUNCTION (parmCount@14, argList@16, thisType@8) ->
  LF_ARGLIST (Borland: count(u16) + count*type(u32)). `$`->`_` class-name retry like
  GetClassMembers. Does NOT touch the bulk type parse.
- **Win64 ABI mapping.** New `IDebugTarget.CurrentFrameParamHomeAddr(paramIndex)`
  (`DebugTarget` + `Win64Debugger`): RBP + subRspN + extraPush + 16 + 8*index (same
  anchor `ReadParentFramePointer` uses; mirrors `GetLocalValues` active/top frame pick).
- **Surface.** `TDebugSession.AppendAnonMethodParams` maps each declared param (Self
  is ABI slot 0, declared params start at slot 1) to its home slot, reads + formats
  via `LocalToSession`. Params have no names in a CV ARGLIST -> labelled `arg1..argN`.
- **Tests.** `arg1`=7 in `Test_Closure_CapturedVarsVisibleInBody`, plus a rich
  `RunClosureParamSampler` fixture (markers `CLOP_*`) + `Test_ClosureParam_*`
  covering 8 signatures: 2 ints, string, Double (XMM), Int64, Boolean, object
  (`$addr (TParamObj)` + expandable), mixed int/string/float/bool, 6 ints (stack
  spill past the register home area). All green mono/BPL/NO_RSM.
- **Bug fixed en route (`TryFindClosureSelf` stale object).** The closure Self was
  found by a blind register/stack scan for any VMT-valid `$ActRec`; with >1 closure
  fixture live it could latch a STALE `$ActRec` from an earlier closure -> wrong
  class/methods. Now Self is read directly from its ABI home slot
  (`CurrentFrameParamHomeAddr(0)`); scan kept as fallback. + per-param try/except so
  one bad param can't drop the other locals. + the object-param fixture uses a
  dedicated marker-free `TParamObj` (TWidget's ctor owns the CTOR_BODY marker).
  Limits: values masked by type width; a `var`/`const` scalar param shows the passed
  pointer; params surface only for a CAPTURING closure.

## DONE: per-thread stepping (2026-07-19). Suite green 822/820/0/0/2.

Step over/into/out now act on the DAP/MCP-selected thread and freeze every other
thread for the duration of the step, so only the stepped thread advances. Read-only
per-thread inspection was already done; this closes the run-control gap.

What shipped (all 4 parts of the plan):
- **Plumb threadId.** `TCommand.ThreadId: DWORD` (0 = stopped thread) in
  `DebugTarget.pas`. `TDebugSession.StepOver/Into/Out(ThreadId: DWORD = 0)` set it.
  `DapServer.HandleNext/StepIn/StepOut` read `Args.threadId` via new
  `StepThreadFromArgs` (validated against `GetThreads`, else 0). MCP `step_*` tools
  read a `threadId` arg (`McpServer` + schema `threadId` prop).
- **Retarget the step handler** (`Win64Debugger.ProcessCommandQueue` ckStep* cases):
  `var StepTid := Cmd.ThreadId; if StepTid = 0 then StepTid := FStoppedTid;` then
  `CurrentRIP/CurrentRSP/CallerReturnAddress/SetTrapFlag` all use `StepTid`.
  `UnpatchBpAtRip(Tid=0)` gained a thread param (defaults to `FStoppedTid`).
  `ResumeTid` intentionally still returns the EVENT thread (`FStoppedTid`), not
  `StepTid`, so `ContinueDebugEvent` releases the correct pending event.
- **Freeze others** (the delicate part). New `FStepTid`/`FStepFreezeActive`/
  `FStepFrozenTids: TList<DWORD>`. `FreezeThreadsForStep(StepTid)` `SuspendThread`s
  every other thread before `ReleasePendingEvent`; `ThawStepFrozenThreads` resumes
  them at the single choke point `ReportStopped` (covers breakpoint/step/exception/
  pause/entry). `HandleCreateThread` freezes a mid-step newborn; `HandleExitThread`
  drops an exiting thread from the set and, if the STEPPED thread exits mid-step,
  thaws all + clears step mode (no all-frozen deadlock); `HandleExitProcess` clears
  the bookkeeping. Persistent-BP re-arm gated on the owning thread via new
  `FReactivateTid` (set with `FPendingReactivateVA`; both re-arm checks gated) so
  stepping a different thread doesn't steal/lose a pending re-arm, and a 2nd thread
  hitting the same BP VA is a real hit, not a swallowed re-arm.
- **Test.** `DebugSessionTests.PerThreadStep_StepsOnlySelectedThread` +
  fixture `RunPerThreadStepFixture` in `TestTargetCore` (switch
  `--run-per-thread-step`; markers `STEPISO_MAIN`/`STEPISO_SPIN_B/C`; globals
  `GStepIsoB/C/Stop`). Two spinner threads increment their own counter; stopping the
  main thread and single-stepping ONE spinner advances only its counter (the other
  stays exactly put) and retargets run control to it.

Inherent limit (accepted, as in VS Code): if the stepped thread blocks on a lock
held by a frozen thread the step cannot complete. The suite's step targets don't hit
this. Docs updated: `PROJECT_STATE.md` (roadmap DONE + feature),
`DAP_DEBUGGER_ARCHITECTURE.md` (Stepping per-thread targeting + limits).

## Latest: debug-info roadmap quick wins (2026-07-18) -- pending final full-suite green

Two roadmap items closed after the JCL work + live test on SampleAppSingleExe (a large
proprietary Delphi Win64 application on the maintainer's machine, not present in a fresh
clone; referred to as SampleApp throughout this file):
- **"No debug info in any format" diagnostic -- DONE.** `TModuleSymbolLoader` now reports
  once per module (runtime: `LoadModuleSymbols` via `HasAnySymbols`/`NoSymbolsReported`;
  main exe: `LoadMainModule` via `FMainProviderCount`) when NO TD32/.map/.rsm/.dcp/.jdbg
  is found. Delivered via loader `OnConsole` (DAP routes to a console output event; MCP
  frontend does NOT wire OnConsole, so DAP-only for now). New no-debug target
  `DebuggerTests\TestTarget\NoDebugExe.dpr` (built with no debug switches in
  build_target.bat + build_and_run.bat). Test
  `DebugSessionTests.MainModule_NoDebugInfo_ReportsDiagnostic` (green in isolation).
- **DCP linked debug info -- CONFIRMED no gap.** A BPL is covered by embedded TD32
  (.bpl .debug section) + `.dcp` (RSM-format); both load (`DLL TD32 loaded` + `DLL DCP
  loaded` in the two-BPL test) and the dual-scenario suite proves package code resolves.
  No work needed. Both documented in `DEBUG_INFO_FORMATS_TODO.md`.

### Follow-ups closed same session (2026-07-18), suite green 813/811/0/0/2:
- **`.tds` investigation RESOLVED.** dcc64 DOES emit external `.tds` on Win64
  (`-VT` = "Debug information in TDS"); header `FB09` = the SAME TD32/CodeView the
  reader already parses. So `.tds` is a thin `TD32FileReader` variant (file-as-CV-blob
  + companion PE section table for segment->RVA). NO current consumer (all builds use
  `-V` embedded) -> documented recipe in `DEBUG_INFO_FORMATS_TODO.md`, implementation
  deferred. Tool: `DevTools\TdsProbe.exe <tds-or-exe>`.
- **"No debug info" diagnostic now visible in BOTH frontends.** `TDebugSession` wires
  `FLoader.OnConsole := HandleLoaderConsole` (constructor + `ReleaseSymbolProviders`)
  -> appends to `FDebuggerOutput` + `OnSessionOutput`. DAP overrides with its console
  sink; MCP inherits -> loader notices (no-debug diagnostic, RSM/TD32/JCL load, stale
  warnings) now appear in `get_debugger_output`. Test updated to assert via
  `DrainDebuggerOutput` (the MCP path). Noted a latent pre-existing bug:
  `ReleaseSymbolProviders` drops other frontend loader hooks on recreate (out of scope).

### External `.tds` — IMPLEMENTED (2026-07-18), suite green 817/815/0/0/2:
`TTD32FileReader.LoadFromTdsFile(TdsPath, ExePath, Shift)` reads the standalone `.tds`
(dcc64 -VT) as the CodeView blob + the companion exe's PE sections/imports (second file
mapping; `FBase`=exe, `FDebugBase`->tds). Wired: `ModuleSymbolLoader.LoadMainTds`
(fallback when `LoadMainTD32` finds no embedded `.debug`) + `EnsureModuleTds`; `MainTD32`
falls back to the tds reader. STALE-GATED (`.tds` older than the binary skipped, main +
module). FORMAT QUIRK handled: external `.tds` offsets are `(segRel - ImageBase)` (vs
embedded pure segRel) -> capture PE ImageBase in `FindDebugSection`, fold into
`FSegmentVAs`, compute every CV address via `SegOffsetToRva` (32-bit truncation cancels
the bias). Tests `TD32ReaderTests.Tds_*` + `DebugSessionTests.Tds_*`. Target
`TdsSample.dpr` (`-VT`). Tool: `DevTools\TdsProbe.exe <tds-or-exe>`.

Remaining roadmap: DCU (hard), JCL nested-proc linkage follow-up; per-thread stepping;
generics/closures in variables; import-table reader; child-process tracking;
disassembly; Win32; marketplace publish; progress-cue UI.

---

## Latest: JCL debug-info provider (P1) -- DONE pending final full-suite green (2026-07-18)

Added `DebuggerCore\JclDebugReader.pas` implementing ISourceLineProvider +
IFunctionNameProvider from JCL's `TJclBinDebugScanner` (linked `JCLDEBUG` section
or sidecar `.jdbg`). Registered below TD32 / above MAP via `ModuleSymbolLoader`
(`EnsureMainJcl` / `EnsureModuleJcl`). Opt-in define `JCL_DEBUG`, DEFAULT ON;
`-D JCL_DEBUG_OFF` compiles out all JclDebug dependency (verified: 425-line
compile, no JCL needed). JCL search paths added to adapter `.cfg`,
`DebuggerTests\RunTests.cfg`, `build_mcp.bat` (harmless when define off).

Verified on SampleAppSingleExe: JCL is address->location + proc-name only; NO
line->address (SourceLineToRva=False, TD32 owns BP binding); NO `_ZZ` nested-proc
linkage (JCL drops the mangled `$pdata$` publics -- 0 of 454k), so the SampleApp
outer-scope gap is unchanged. Full findings in `DEBUG_INFO_FORMATS_TODO.md` (P1 DONE).

Two bugs found + fixed during integration (both were regressions in the mono
`Test_Bpl_TwoModules_EachBpRoutes`, adapter crash "Timeout waiting for stopped"):
  1. TJclBinDebugScanner CacheData=True lazily MUTATES caches on first query;
     adapter queries providers from 2 threads -> serialized with `FLock` + eager
     cache prime at load.
  2. ROOT CAUSE: JCL queried via the FLAT provider path with out-of-range
     addresses (kernel VAs, $0) -> JCL clamps to wrong symbol AND range-errors
     under the adapter's `{$R+}`. Fix: `InModuleCodeRange` guard (provider now
     takes ImageSize -> answers only within [shift, shift+ImageSize) at/above the
     $1000 code base). TD32/MAP don't hit this because they bounds-check internally.

Smoke test `DebuggerTests\JclDebugReaderTests.pas` (8 tests, TD32 as oracle) +
`build_jdbg.bat` generates `TestTarget.jdbg` (JCL `ConvertMapFileToJdbgFile`),
wired into `build_and_run.bat`. Both JCL fixture (8/8) and the formerly-failing
BPL test (2/2 both scenarios) now green. Full suite re-run in progress.

Tool: `DevTools\JclProbe.exe <pe-or-jdbg>` (JCL Win64 compile + jdbg survey).

---


## Latest: MCP lifecycle bug fixes (2026-07-17) -- DONE, suite green 795/793/0/2

Three bugs reported from a real DGOdacTests.exe MCP session. Details + probe in
`PROJECT_STATE.md` ("MCP session/process lifecycle bugs"). Status:
- BUG 2 session-stuck-after-terminate: FIXED. `TMcpServer.EnsureFreshSessionForStart`
  recreates `FSession` from a terminal state (called in every launch/attach handler +
  `PerformAttach`). Test `McpE2ETests.Relaunch_AfterTerminate_Succeeds`.
- BUG 3 zombie-locks-exe: FIXED. `TWinDebugger.Terminate` kill path now `DrainUntilExit`
  (pump `WaitForDebugEvent`/`ContinueDebugEvent` to the real `EXIT_PROCESS`, 3 s cap, then
  `DebugActiveProcessStop` fallback) + `CloseTargetHandles`; `Destroy` delegates to it.
  New `TDebugSession.DebuggeeProcessId`. Test `DebugSessionTests.Terminate_ReapsDebuggeeProcess`.
- BUG 1 verified-BP-never-fires: NOT reproducible; the BP WORKS. `oracle.pas:2018` binds
  uniquely+correctly to `TOracleQuery.FieldOptional @ $988A00` (TD32 NAMES basename-only;
  DOA's line 2018 has no code record). A one-off repro harness (not retained) drove
  `TDebugSession` directly against the real DGOdacTests.exe (a proprietary test binary on
  the maintainer's machine, not present in a fresh clone) with the exact launch args:
  `verified=True`, stops at `Oracle.pas:2018` in FieldOptional (reason=breakpoint) on the
  FIRST continue, before any exception. So bind/plant/fire is correct; the user's original
  non-firing was environmental / data-dependent / compromised-session, not a debugger bug.
  No code change shipped for Bug 1.

## Current task

MCP FRONTEND over the shared debugger core (started 2026-07-13). Approved plan
(volatile scratchpad, gone). Goal: a semantic MCP tool
API (no raw DAP ids) letting Claude Code autonomously drive the debugger, reusing
the engine. Architecture: extract a JSON-free `TDebugSession` core facade; DAP +
MCP are two thin frontends. Attach-to-process is first-class. Extensible for a
future Win32 target. Decisions (user-confirmed): full extract; vertical slice
first; SEPARATE MCP exe (`DelphiDebuggerMcp.dpr`) — DAP adapter untouched.

Phases: 0 = extract `TDebugSession` (no DAP behavior change; gate = DAP suite
stays green). 1 = vertical slice (ProcessEnum + `list_debuggable_processes`,
MessageChannel+TMcpIO+McpServer with launch/set_breakpoint/continue_and_wait/
snapshot). 2 = attach + inspection. 3 = deferred (logpoints, changed-vars,
exception config, run_until).

### ENDGAME COMPLETE (2026-07-15): TDapServer is a thin frontend over one TDebugSession.

DONE + shipped. Steps: 0 session superset (51c0e81), 1-2 engine-ownership pivot
(9305b0b), 3 read queries (8cd16d4), 4 evaluate/EvaluateForFrame (b68300c), 5
setVariable + ValueEncoders (2f85822), 6 breakpoints + single recolor (d30268f), 7-8
goto + dead-code sweep (8b0f246). One engine + FDebugInfo/FLoader/FExpander/FBpEval,
owned by the session; both DAP and MCP frontends sit on it. DapServer.pas ~5714 ->
2877 lines over the whole dedup+endgame. Suite 792/790/0/2, 0 leaked, both fixtures.
DAP retains only: transport+JSON, int-ref<->handle bimap+EmitVar, spinner/progress,
eval warm-up+FEvalMissCache, exception-filter/rule config, launch.json parse, the
(off) DAP_BG_LOADER wrapper, TDllModule/PACKAGEINFO, and FSession accessors.
OPEN FOLLOW-UP (task #10, perf-only, non-blocking): the session's HandleDllLoaded
eager-loads on any module load when HaveBreakpoints (ungated) -- port the PACKAGEINFO/
ContainsSourceFile gate into it so a many-BPL host (SampleApp) does not repost-storm.

### (SUPERSEDED) ENDGAME cursor — migrate TDapServer onto one TDebugSession.

Dedup ladder DONE + shipped this session: TVariableExpander (83b92cc/cd34ca3),
TBpEvaluator (dfb42c0), TrimRaisePlumbing+GetDisplayMembers (c552a39), PeSymbolSupport
(77db745), TModuleSymbolLoader (ee00973). ~2000+ dup lines gone from DapServer.
Now the endgame: TDapServer becomes a thin frontend over ONE TDebugSession (which
owns FDebugger/FDebugInfo/FExpander/FBpEval/FLoader); DAP keeps only JSON transport,
progress/spinner, the int-ref<->TVarHandle bimap + EmitVar, uses-scope warm-up +
FEvalMissCache, exception-filter/rule config, launch.json parse, bg-loader wrapper.

Map: workflow wf_5f83e196-c52. Decision digest (volatile scratchpad, gone).
STAGED PLAN (each step green on BOTH mono TestTarget + BPL TestSubject fixtures):
  STEP 0 (session superset, DAP UNTOUCHED -> can't break shipped adapter): add to
    TDebugSession/DebugSessionTypes -- accessors (Expander/Loader/DebugInfo); injection
    hooks (ModuleClass/RequiresFor/ShouldRetry + OnDllLoadedHook/OnModuleSymbolsLoaded
    Hook); OnBreakpointChanged(file,line,verified); enrich TSessionFrame with FrameRBP/
    FuncEntryVA/IP + SelectFrame(index)/ClearActiveFrame; GetThreads/GetStoppedThreadId/
    GetThreadName; GetRegisters/SetRegister; ResolveSourcePath; EnsureMainRsm passthrough;
    TStopInfo exception-description enrichment; TLaunchOptions/AttachOptions +modules-
    config +exceptionRules +exceptionFilters wired in Launch/Attach; also fix the broken
    RemoveAllBreakpoints (posts nothing today). Cover each with DebugSessionTests.
  STEP 1: DAP constructs FSession; FDebugInfo/FLoader/FExpander/FBpEval/FReaders become
    private accessors -> FSession.* (delete DAP's instances); DAP still builds FDebugger
    but sets it on the session's single loader/debuginfo. First real dedup.
  STEP 2 (the pivot, engine-ownership cut): HandleLaunch/Attach -> FSession.Launch/Attach
    (session BuildAndWireDebugger owns the one TWinDebugger); delete DAP engine wiring;
    subscribe OnSessionStopped/Exited/Output -> DAP emit; Run loop ProcessOneEvent->
    Pump, HasExited->FSession.HasExited; Continue/Step*/Pause/Disconnect -> session.
  STEP 3: read queries -> session (Threads, StackTrace via rich GetFrames, Scopes via
    SelectFrame, Variables locals/registers/nested). STEP 4: evaluate -> session
    EvaluateForFrame (DAP keeps warm-up+miss-cache). STEP 5: setVariable -> session
    SetRegister/SetLocal/SetField (move encoders to core). STEP 6: breakpoints -> session
    SetBreakpoints + DAP id-map + OnBreakpointChanged recolor. STEP 7: goto. STEP 8:
    delete DAP's dead engine fields/handlers.
  TOP RISKS (map): repost-storm/freeze in BPL (port PACKAGEINFO gate to session STEP 0);
    verified-flip recolor lost (OnBreakpointChanged); double-free during ownership window
    (session owns+frees, DAP holds accessors only); TSessionFrame too thin for frame-
    select; evaluate warm-up/miss-cache regression (keep DAP-side); Pump stays launch-
    thread. GATE: a step green on mono but not BPL is NOT committable.

### (SUPERSEDED) Phase B — full-extract DAP variable expansion into the core.

User approved Option A (kill the two-engine duplication; "we have tests"). The core
had only 3 expansion kinds; DAP had 9 (getters, Variant arrays, props/events groups).
Mapped both engines via workflow wf_9131ff4e-dd3 (digest: volatile scratchpad, gone).

STAGE 1 (core parity + MCP feature) — CODE DONE, validating:
- DebugSessionTypes: +vkGroup. DebugSession TSessionExpKind: +exPropGroup/exEventGroup/
  exPropertyGetter/exVariantArray; TSessionExpansion: +NoGroup +VarArrPtr/VarBaseType/
  VarDimCount/VarBounds. uses +System.Variants,System.Math.
- Ported DAP-private classifiers into TDebugSession: IsEventHandlerProp,
  ClassHasProperties, ClassHasPropertyKind, PropertyBackingFieldOffset. Added
  FormatMemberValue (= DAP FormatRttiField: class '{T @ 0xADDR}'/'nil', record '{T}',
  dynarray 'T[len]'/'(empty)', else FormatLocalValue) so core field VALUES now match
  DAP byte-for-byte. MemberFieldToSession + BuildGroupNodes.
- ExpandViaMembers: property-bearing class -> BuildGroupNodes (properties/event
  handlers/fields). ExpandProperties (field-backed inline / getter deferred
  '(expand to evaluate)' / indexed leaf '(indexed property)'). ExpandPropertyGetter
  (ClearActiveFrame + TExprEvaluator.Evaluate(PropExpr), split structured result via
  ExpandViaMembers else '(value)' leaf). TryMakeVariantArray + ExpandVariantArray +
  FormatVariantElement (varArray header, user-order bounds, cap 1024). Variant-array
  local detection in LocalToSession. GetChildren dispatches all new kinds.
- McpJson.VarToJson: +evaluateName, +group flag for vkGroup.
- Tests: fixed 3 flat-list tests to descend the 'fields' group via new FindMemberField
  helper (Widget_ExposesFields, NestedRecord, Bpl_Breakpoint, MCP ExpandVariable_
  ObjectFields). Added DebugSessionTests: Widget_GroupsProperties, PropertyGetter_
  RunsGetter (Score=DoCalcScore=FValue*2=84), IndexedProperty_IsLeaf, VariantArray1D
  (Arr1D=[10..50]), VariantArray2D (Mat[1,1]=1.5,[2,3]=7.25). Added McpE2ETests:
  ExpandVariable_PropertyGetter. Fixture already had the surface (TWidget/TStuff/
  TIndexedBag props; VARIANT_BODY marker: Arr1D/Mat).
- CONFIRMED grouping works: TD32 DOES return cmkProperty (the old "TD32 returns props
  as cmkField" note below was STALE). Full suite attempt 3 running (bg b0ctmu9lo).

STAGE 2 (NOT STARTED) — CORRECTED PLAN. Original idea "reroute DAP onto
FSession.GetChildren" is WRONG: TDapServer does NOT own a TDebugSession (verified
2026-07-14 -- Phase B/DAP-on-core migration was deferred; DAP owns FDebugger/
FDebugInfo/FTD32/FRtti/FReaders directly). So the dedup path is Path A: EXTRACT a
shared TVariableExpander unit (DebuggerCore\VariableExpander.pas) that owns FByHandle
+ ALL Expand*/classify/FormatMemberValue/FormatVariantElement, taking injected deps
(IDebugTarget, TDebugInfoSet, TTD32FileReader, TDelphiRtti, TDelphiValueReader).
  Step 1 (core-only, DAP untouched, low risk): move the expansion engine out of
    TDebugSession into TVariableExpander; TDebugSession holds FExpander and delegates
    GetChildren + LocalToSession's classify + reset-on-stop + FRtti sync. Gate:
    session + MCP e2e tests green.
  Step 1a DONE + shipped (83b92cc): VariableExpander.pas extracted; TDebugSession
    delegates; suite 781/779/0/2 unchanged. Expander DAP-API added (MakeClassExpansion
    for $exception, TryGetWritableField for setVariable) -- compile-clean.
  Step 1b DONE + shipped (cd34ca3): TDapServer rewired onto FExpander (bimap +
    RefForHandle + EmitVar + SyncExpander); deleted TVariableExpansion/FExpansions +
    the whole Alloc*/Append*/FormatRttiField/FieldDrillDownRef family (DapServer
    -1141 net lines). BOTH parity items ported into the expander (same-offset RTTI
    rescue in MemberFieldToSession; exRecordRtti/exDynArrayRtti via each field's own
    TypeInfo) -- covered by the 4 generic-collection tests, now shared by MCP too.
    Suite 781/779/0/2, independently re-verified. VARIABLE-EXPANSION DEDUP COMPLETE.
  Step 1b RECIPE (kept for reference -- atomic; the ref space flips together; cannot
    be sliced because minting and expansion shared FExpansions). DapServer.pas:
    ADD: FExpander:TVariableExpander (create/free; SyncExpander sets deps from
      FDebugger/FDebugInfo/FTD32/FRtti/Readers; call on stop + before use); a per-stop
      bimap FRefToHandle/FHandleToRef:TDictionary + reuse FNextExpRef(=2000 reset);
      RefForHandle(H):Integer (0 if H=0 else lookup-or-assign, add both maps, Inc);
      EmitVar(Arr,const V:TSessionVariable) -> DAP JSON node (name; evaluateName if
      <>''; vkGroup -> value:'' + presentationHint{kind:virtual}, no type; else
      value:=V.Value,type:=V.TypeName; variablesReference:=RefForHandle(V.Handle)).
    REWIRE: HandleVariables LOCALS branch (3877): AppendExceptionLocal via
      FExpander.MakeClassExpansion(ExcObj,ClassName,'$exception')+RefForHandle; then per
      local build TSessionVariable(name/value=Readers.FormatLocalValue/type=FormatLocalType/
      evalName) + FExpander.ClassifyLocal + EmitVar. REGISTERS branch (3984) unchanged.
      ELSE branch (4022): H:=FRefToHandle[Ref]; for c in FExpander.GetChildren(H) do
      EmitVar. HandleEvaluate ClassVarRef (4534-4601): FExpander.MakeClassExpansion on a
      class result / TryMakeVariantArray-equivalent -> need a MakeVariantArrayExpansion
      helper on the expander (add: mirrors ClassifyLocal's Variant branch, returns handle);
      then RefForHandle. HandleSetVariable (4855) non-scope ref: H:=FRefToHandle[Ref];
      FExpander.TryGetWritableField(H,name,addr,type) -> keep DAP encode+WriteMemoryAt.
    DELETE: TExpKind(210)+TVariableExpansion(212) types; FExpansions field(361);
      AllocExpansion/AllocExpansionForField/AllocVariantArrayExpansion/
      AllocDynArrayNamedExpansion; AppendRttiVariables/AppendGroupNode/
      AppendRsmMemberFields/AppendRsmProperties/AppendPropertyGetterChildren/
      AppendDynArrayNamedChildren/AppendVariantArrayChildren; FormatRttiField/
      FormatVariantElement/FieldDrillDownRef; ClassHasProperties/IsEventHandlerProp/
      ClassHasPropertyKind/PropertyBackingFieldOffset; GetDisplayMembers(DAP copy, once
      no caller remains); FExpansions.Clear/reset(1930) -> bimap.Clear+FNextExpRef:=2000.
    GATE: FULL DAP suite byte-behaviour unchanged (refs OPAQUE -> exact ints need not match).
    RISK to port for real-target parity (may be UNTESTED in the fixture, add to the
    expander's TryClassifyChild): (a) FieldDrillDownRef's RTTI-same-offset rescue of a
    mis-typed generic backing field; (b) RTTI-typed ekRecord/ekDynArray via
    FRtti.ExpandRecord/ExpandDynArray (AllocExpansionForField) for fields with no member
    table. If the DAP suite stays green without them, note the untested-parity gap.
  Step 2 (rewires shipped DAP -- the risk): TDapServer owns a TVariableExpander;
    delete its TVariableExpansion/Append*/Alloc*/FExpansions; add a per-stop
    DAP-int<->TVarHandle bimap (refs are OPAQUE in the DAP tests -- verified: no
    exact-int assertions, only >0 expandable / =0 leaf / pass-back-to-expand, so the
    bimap need not reproduce 2000+ emission-order values). Keep scopes 1000/1001;
    setVariable write-through via a new expander accessor (className+baseAddr for
    exRsmMembers-writable handles); $exception via an expander MakeClassExpansion.
    Still-to-port into the expander for full DAP parity: RTTI-typed ekRecord/
    ekDynArray (FRtti.ExpandRecord/ExpandDynArray by TypeInfo) + FieldDrillDownRef's
    RTTI-same-offset rescue of mis-typed generic backing fields. Gate: FULL DAP suite
    byte-behaviour unchanged. Commit only when green; revert DapServer if not.
Map digest for both engines: volatile scratchpad, gone (workflow wf_9131ff4e-dd3).

### Current substep — WORKING MCP SERVER achieved (vertical slice + most inspection).

Strategy taken (stated to user): to reach a working MCP server fastest and WITHOUT
risking the shipped DAP adapter, Phase A built the MCP stack as NEW units that own
+ reuse the engine (Win64Debugger/ExprEval/DelphiValueReader/DebugInfoSet/readers/
ProcessEnum). DAP adapter left byte-for-byte untouched. The "make DAP delegate to
TDebugSession / delete duplication" (Phase B) is deferred — the working server is
the deliverable. Vertical slice targets a MONOLITHIC exe (TestTarget); the DLL/BPL
background-loader is NOT wired into TDebugSession yet (HandleDllLoaded no-op).

SOURCE LAYOUT (reorganized into 3 sibling folders, user request):
- DebuggerCore\   = ALL .pas shared by DAP + MCP (the engine + the new core facade):
  DapProtocol (shared for DapLog), DebugTarget, Win64Debugger, DebugInfoTypes,
  DebugInfoSet, DebugSourceIndex, MapFileReader, TD32FileReader, RsmFileReader,
  RsmTags, RsmDecoders, DelphiRtti, DelphiValueReaders, ExprEval, ExceptionRules,
  DebugSessionTypes, DebugSession, SourceResolver, ProcessEnum (19 units).
- VisualStudioCodeDelphiDebugger\ = DAP-only: DapServer.pas +
  VisualStudioCodeDelphiDebugger.dpr/.cfg/.dproj/.delphilsp.json.
- MCPDebugger\     = MCP-only: McpServer, McpJson, McpToolSchemas, DelphiDebuggerMcp.dpr.
Build wiring after the move: DAP .cfg + .dpr in-clauses + .dproj point at ..\DebuggerCore
(added -U..\DebuggerCore to the .cfg); build_mcp.bat pushd MCPDebugger -U..\DebuggerCore
-E.\Win64\Debug (MCP exe now at MCPDebugger\Win64\Debug\); RunTests.dpr in-clauses +
build_runner/build_and_run dcc64 use ..\DebuggerCore + -U..\DebuggerCore; DevTools
build_all.bat FLAGS var has -U..\DebuggerCore + DevTools dprs repointed. Docs + workspace
updated. All 4 builds (DAP/MCP/DevTools/runner) verified clean post-move; session 4/4 +
MCP e2e 4/4 green. settings.local.json intentionally NOT touched (machine-specific).

Units (originally described as under VisualStudioCodeDelphiDebugger\, now per the layout above):
- DebugSessionTypes.pas — neutral vocabulary (compiles clean).
- ProcessEnum.pas — rich enum + pre-attach arch gate (runtime-verified via
  `DevTools\ProcessEnumProbe.exe [filter]`).
- SourceResolver.pas — TSourceResolver, extracted source-path search (shared unit;
  DAP still has its own copy — Phase B unifies).
- DebugSession.pas — TDebugSession core facade. Owns IDebugTarget + symbols +
  readers + resolver + state machine. Launch/Attach/Detach/Terminate/StopDebugging/
  Pump/State/StopGeneration; SetBreakpoints/List/RemoveAll; Continue/Step*/Pause;
  GetCallStack/GetCurrentLocation/GetLocals/Evaluate/GetExceptionDetails/Snapshot;
  DrainDebuggeeOutput; OnSessionStopped/Exited/Output events. NB: FMap/FTD32/FRsm are
  TInterfacedObject owned by FDebugInfo via ARC — destructor must NOT Free them.
- McpToolSchemas.pas — tools/list schema builder.
- McpJson.pas — neutral-record -> JSON serializers.
- McpServer.pas — TMcpIO (ndjson JSON-RPC 2.0 over stdio) + TMcpServer (initialize/
  tools/list/tools/call + async-wait pump: StopGeneration + FPendingWait, no sleeps).
- DelphiDebuggerMcp.dpr — the MCP exe entry.
- build_mcp.bat — builds it to Win64\Debug (must use -E.\Win64\Debug -NU; wired into
  build_and_run.bat after the adapter build).

TESTS (TDD, all green):
- DebuggerTests\DebugSessionTests.pas — 4 protocol-free tests (launch/bp/stop/
  location/locals Caption='Hello'/evaluate W.FValue=42/snapshot).
- DebuggerTests\McpE2ETests.pas — 4 e2e tests: spawns DelphiDebuggerMcp.exe, real
  JSON-RPC over stdio pipes (TMcpTestClient), drives initialize/tools-list/
  list-processes/launch->set_breakpoint->continue_and_wait->snapshot/evaluate.
- Both registered in RunTests.dpr (which now also links the engine units +
  DebugTarget/DelphiRtti/DelphiValueReaders/ExprEval/Win64Debugger).
- launch_debuggee FORCES stop-at-entry (race-free: Run loop pumps continuously, so
  breakpoints must be set while parked at entry before continue_and_wait).

GATES: Phase-0 full suite 754/752/0/0/2 (750 + 4 session). MCP e2e 4/4 green in
isolation. Full suite WITH MCP e2e running now (expect 758).

### Next action if interrupted right now

Phase 2 progress (full suite 767/765/0/2 green):
- DONE nested variable expansion — TVarHandle table + GetChildren + expand_variable
  (class fields + records). GetDisplayMembers is TD32-first (RSM returns partial
  record members). TRAP FIXED: a method named `Continue` shadowed the loop keyword
  -> renamed to ContinueExecution. Tests: DebugSessionTests +2, McpE2ETests +1.
- DONE conditional/hit-count/logpoint breakpoints — HandleBpHit + EvalBpExpr (state-
  independent, lazily creates FRtti) + HitConditionMet + RenderLogMessage; logpoints
  emit to FDebuggerOutput (get_debugger_output tool). set_breakpoint now takes
  condition/hitCondition/logMessage. Tests: DebugSessionTests +4, McpE2ETests +2.
- DONE dynamic-array expansion — exDynArray kind + TryMakeDynArray (Win64 header:
  Length@[ptr-8], RefCnt@[ptr-12]; elem size via GetTypeSize) + ExpandDynArray;
  wired into LocalToSession + TryClassifyChild for `^Element` TD32 types. Elements
  carry their own handles (nested class/record elements expand too). Test:
  ExpandVariable_DynArray_Elements (Scores TArray<Integer> -> [0]=10,[1]=20,[2]=30).
- DONE multi-module / BPL symbol loading (SYNCHRONOUS port). TModuleSymbols class
  + FDllModules + HandleDllLoaded (auto-discover .map/.rsm/.dcp next to the module,
  load synchronously when breakpoints exist, RepostBreakpoints so a BP in a BPL unit
  plants once the package loads) + EnsureDll{Map,Rsm,Dcp,TD32}/AddDllProvider (RVA-
  range-scoped: [Base-exeImageBase, +ImageSize)) + EnsureDllModuleForPC wired into
  HandleTargetStopped(RIP) + GetCallStack + GetCurrentLocation (unresolved frames).
  FBpSpecs added (lcase file -> spec, for repost). Tests: DebugSessionTests
  Bpl_Breakpoint_InPackageUnit_Stops (TestHost.exe LoadPackage TestSubject.bpl,
  BP at EVAL_BODY in the BPL-only TestTargetCore, stop + W.FValue=42);
  McpE2ETests Bpl_Breakpoint_Stops (same over MCP). TODO PERF: gate eager load on
  ContainsSourceFile (PACKAGEINFO) so unrelated sidecar-bearing packages aren't
  loaded; today only fires for Delphi-sidecar modules (a mono target: none).
- DONE polish: get_variable (session GetVariable: local-first then evaluate),
  set_breakpoints (plural, MCP handler groups by file), live-attach test
  (Attach_ToRunningTarget_Stops -- spawns TestTarget --attach-pause, session.Attach,
  BP at MAIN_GCOUNTER; gated by HaveDebugPrivilege, skips if not elevated).
Remaining Phase 2 (deferred, lower value):
(1) getter-backed PROPERTY expansion -- TANGLED: TD32 returns properties as cmkField
    so GetDisplayMembers can't separate them; needs RSM-based cmkProperty + deferred
    getter eval (RunMethodCall). Variant-array expansion (rare).
(2) BPL PERF gate (ContainsSourceFile/PACKAGEINFO so unrelated packages aren't loaded
    eagerly) + background async load.
(3) get_scopes/get_arguments -- SKIPPED by design: the neutral model uses direct
    get_locals + opaque handles, not scope-ref indirection; args aren't reliably
    separable from locals without param metadata (DAP doesn't separate them either).

CONFIG PARITY (user request): the MCP server takes config from tool ARGS (not a
shared file), but now also
- multi-root sourceSearchPaths[] on launch_debuggee + attach_to_process (Opts.
  ExtraSourcePaths; env expansion + ;-split via LaunchConfig.ExpandSearchPaths);
- launch_from_config tool: reads an existing VS Code launch.json (JSONC comments +
  trailing commas + ${workspaceFolder}/${env:}), finds a delphi-win64 config, builds
  TLaunchOptions. New unit MCPDebugger\LaunchConfig.pas (StripJsonc/ResolveVars/
  ExpandSearchPaths/LoadLaunchConfig). Test: McpE2ETests LaunchFromConfig_Stops
  (temp JSONC config -> launch -> breakpoint -> stop). Full suite 774/772/0/2.
- DONE attach config parity: sourceSearchPaths/workspaceFolder already on
  attach_to_process; NEW attach_from_config tool reads request:"attach" configs
  (process selector + program/map/rsm + source paths). LaunchConfig refactored to a
  shared ReadConfig + LoadLaunchConfig/LoadAttachConfig. McpServer.PerformAttach
  shared by both attach tools (pid resolve + ambiguity + arch gate + program default
  + arm wait). Test: DebugSessionTests AttachConfig_ParsesSelectorAndPaths (protocol-
  free -- validates the config extraction without needing elevation).

PHASE B (delete DAP<->core duplication) -- IN PROGRESS. Gate: DAP suite stays
byte-compatible (773/771/0/2, same counts).
- DONE source resolution: TDapServer.ResolveSourcePath/ResolveUnitToSource delegate
  to shared TSourceResolver (uses SourceResolver; FSourcePathCache field ->
  FSourceResolver; Configure(FSourceRoot, FExePath, FExtraSourcePaths) after the
  roots block in SetupDebugSession + HandleLaunch; deleted ResolveSourcePathUncached
  ~217 lines). Adapter builds clean, suite green.
- BLOCKED (needs session feature-parity first, else DAP regresses): variable-
  expansion Append* family (session lacks getter-property + Variant-array expansion);
  symbol-loading (DAP background loader vs session synchronous). These are the big
  risky slices -- do session feature-parity (Phase 2 property/Variant) BEFORE
  delegating, or accept partial Phase B (source resolution done is a real dedup win).

Commits: ccdd901 (MCP frontend + core extraction + reorg + nested expansion +
conditional breakpoints), 3c2a44c (dynarray), c8c33f8 (BPL multi-module), then polish.
Phase B (cleanup): make TDapServer delegate to TDebugSession + SourceResolver to
delete the orchestration/source-resolve duplication.

### What works / not failing

Working MCP server: launch->breakpoint->continue->inspect->evaluate->terminate over
real MCP/stdio. Attach implemented (pid/ambiguous-name/arch-gate) but not live-tested.
DAP adapter untouched (byte-for-byte) — shipped integration unaffected. Nothing failing.

### Traps / hypotheses

- QueryFullProcessImageNameW / PROCESSOR_ARCHITECTURE_ARM64 are NOT in this Delphi's
  Winapi.Windows — declared manually in ProcessEnum. Same manual-import pattern as
  DapServer.pas:2335.
- Batch quoting: `-E"%~dp0"` breaks (trailing `\"` escapes the quote). Use `-E.`
  after `cd /d %~dp0`. dcc64 won't create a missing `-NU` output dir — mkdir first.
- Phase 0 hardest risk = the variable-expansion refactor (Append* -> return
  TArray<TSessionVariable> instead of TJSONArray). Change only the OUTPUT stage;
  keep TVariableExpansion internal; prove DAP tests byte-compatible first.
- WaitForDebugEvent thread affinity: Launch/Attach/Pump must stay on the Run thread.

---

## Previous task (DONE, committed a57542a)

RSM SIDECAR FREEZE -- ROOT-CAUSED + FIXED (2026-07-02). Suite green 750/748/0/2.

The measured 30-70s SampleApp freeze was NOT primarily the module-loading sweep. It was
`TRsmFile.LoadProcIndexFromSidecar`. Timings on the real SampleApp.rsm (2.2 MB):
  - TD32 full LoadFromFile: 157 ms (ParseAllTypeTables = 141 ms = 90%; names-only
    would be ~16 ms -- NOT the bottleneck).
  - RSM cold parse (no sidecar): ~80-95 ms total (LoadFromFile ~15 ms sync +
    ParseUserTypeTable ~15 ms + background index ~65-95 ms). Fine.
  - RSM WITH the `.idx` sidecar present: **56-71 s**, then returned False and
    re-parsed cold anyway. The sidecar made a cold-parseable file 700x SLOWER.

Root cause: `LoadProcIndexFromSidecar` declared its loop counters `I, J` (and the
section counts) as `UInt32`. `for I := 0 to Count - 1` with Count = 0 underflows
`Count - 1` to $FFFFFFFF -> ~4 billion iterations over garbage until a mis-read count
tripped. SampleApp has ZERO proc-locals, so ProcLocalsCount = 0 hit it every single load
-> the sidecar cache never once succeeded since it was written. Because it failed on
every session AFTER the first (which writes the sidecar), the user saw the freeze on
the 2nd+ debug session.

FIX (committed): 
  - RsmFileReader.LoadProcIndexFromSidecar: loop counters `I, J` -> Integer; the four
    `for .. to Count - 1` bounds cast `Integer(Count)`; sidecar read into a
    TMemoryStream up front (no per-field syscalls); SidecarGuardCount before every
    SetLength/loop driven by a file-read count (fails a corrupt sidecar in ~0 ms
    instead of minutes of paging).
  - RsmDecoders: SidecarReadStr / SidecarReadStrArr guard their length/count; new
    SidecarGuardCount(F, N, MinBytesPerElem) helper (raises EReadError when a count
    can't fit the remaining bytes).
  - RsmFileReader.ExtractTypeInfoNames + ParseUserTypeTable $66 loop: replaced the
    O(n^2) `Result := Result + [Name]` managed-array append with a TList<string>
    (defensive; the $66 path is the primary table on monolithic RSMs).
RESULT: SampleApp.rsm load = ~80 ms cold, ~0 ms warm (sidecar now loads, hit=True). The
sidecar cache WORKS for the first time (real value for the user's large multi-BPL .dcp
files -- same reader/sidecar path).

Measured with two one-off timing probes (not retained): TD32 phase timing and MAP/RSM
load+index timing. The env-gated instrumentation they relied on (TD32_TIME/RSM_TIME) was
TEMPORARY and has been fully removed from the shipped readers, so per-phase timing is no
longer reproducible with any current tool -- the numbers above are the retained record.

---
PRIOR: SCOPE-BOUNDED EVAL WARM-UP -- implemented + committed (aa6ba6f). Still valid for
the multi-BPL brute-force cost (bounds eval warm-up to the frame's direct-uses scope).
Complementary to the sidecar fix, not superseded.

The user corrected a key misunderstanding: Delphi has NO transitive uses -- a bare
identifier's visibility scope is EXACTLY the frame unit + its DIRECT uses, a bounded
explicit set (not "the whole app"). So the 30s freeze (an unresolved Watch like
`yyyy` at SampleApp.dpr:109 forcing WarmupSymbolProvidersForEvaluate to load EVERY
module to search) is fixable by bounding the warm-up to the visibility scope.

DONE:
  - DebugInfoSet.ScopeUnitsForFrame(FrameRva): frame unit (UnitNameForRva) + its
    direct uses (merged from FUsesProviders / GetUnitUses). Empty when no frame
    unit or no uses graph.
  - DapServer.WarmupUsesScopeForFrame(FrameRva): loads ONLY the modules owning those
    scope units (Module.ContainsSourceFile('unit.pas') -> EnsureDllTD32/Map/Dcp,
    Break at first owner). Returns True when the scope was known.
  - HandleEvaluate miss path rewired: on a bare-identifier miss, call
    WarmupUsesScopeForFrame; if it returns True (scope known) retry once and, if
    still missing, REJECT (out of scope) -- NO brute-force sweep. Fall back to the
    old WarmupSymbolProvidersForEvaluate (all modules) ONLY when there is no uses
    graph for the frame. WarmPC hoisted so both warm-ups share it; FrameRva =
    WarmPC - FDebugger.ImageBase.
  VALIDATING (bg bdair4rtz): build + full suite. KEY coverage: all Test_Eval_* +
  the uses-scope/cross-unit tests. Risk: a test watching an OUT-OF-SCOPE symbol
  that previously resolved via brute-force would now reject (arguably correct);
  or ContainsSourceFile missing a unit->module owner.
  NOTE: needs the uses graph (RSM/dcp) -- present for SampleApp (SampleApp.rsm loaded).
  Without it, falls back to the old brute-force (safe).

BACKGROUND SYMBOL LOADER -- Stage 1 implemented but DISABLED (flag DAP_BG_LOADER),
VALIDATING was 2026-07-01. (Superseded focus -- scope-bounding is the better fix.)

Root cause pinned from the user's real SampleApp adapter log (volatile scratchpad, gone;
stop at SampleApp.dpr:109 @16:21:47): an unresolved Watch expression `yyyy` triggered
WarmupSymbolProvidersForEvaluate, which loaded the MAP/TD32/DCP of EVERY loaded
module (dozens of DevExpress/Indy/JCL/RTL BPLs + probed system DLLs) SYNCHRONOUSLY
on the dispatch thread -- ~31s, during which the queued step-over could not run
(serial dispatch). `yyyy` is a real local of a BPL's TAboutBoxForm.Create, out of
scope at line 109.

User's design (CONFIRMED): load symbols in the BACKGROUND from launch, continuing
while the program runs; the LOAD is never aborted; the eval WAIT for the load is
abortable (step-over cancels the wait, not the load). Parallelize if possible.

STAGE 1 DONE (proactive background loader), all in DapServer.pas:
  - New value types TModuleLoadReq / TParsedDllReaders (decouple the loader from
    TDllModule lifetime -- the object may be freed on unload mid-parse).
  - Fields: FLoaderQueue (TThreadedQueue), FLoaderThread, FLoaderStop,
    FLoaderPending.
  - ParseDllReaders (LOADER THREAD): creates+LoadFromFile the TD32/MAP(fresh)/
    DCP(fresh) readers into RAW objects; touches only the value Req + immutable
    FModulesConfig + file I/O -> no race. Self-filters no-debug-info modules.
  - RegisterParsedModule (MAIN THREAD, via TThread.Queue): re-finds the live module
    by Name+Base, takes the interface ref + AddDllLocalProvider/AddProvider (MAP),
    or frees orphans; re-posts BPs (RepostAllBpSpecs/EmitChangedBreakpoints).
  - Loader thread: pop Req -> ParseDllReaders -> TThread.Queue(register). Started
    lazily on the first OnDllLoaded; each relevant module (non-\windows\) enqueued.
  - Run loop pumps registrations via CheckSynchronize(0) (main thread -> all
    FDebugInfo mutation stays single-threaded, no locks on the read path).
  - Destructor: StopSymbolLoader FIRST (WaitFor + RemoveQueuedEvents) before freeing
    FDebugInfo/FDllModules.
  Adapter COMPILES clean (24620 lines). VALIDATING (bg bn5ok6qny): full suite --
  the BPL fixture (TestHost+TestSubject.bpl, LoadPackage/UnloadPackage, PKG_BP,
  cross-BPL) stresses the loader path. Expect 750/748/0/2.

STAGE 1 RESULT: FAILED validation -> DISABLED (flag DAP_BG_LOADER, default off; set
  =1 to re-enable for iteration). The naive proactive loader runs CONCURRENTLY with
  the existing lazy (WarmupSymbolProvidersForEvaluate) + eager (OnDllLoaded BP-probe)
  load paths AND the readers' own internal index threads. Under FULL-SUITE load in
  the BPL fixture it intermittently hangs a request: 23 then 26 "Timeout waiting for
  response to seq=8" errors, ALL in TDebuggerTestsBpl, 0 in the mono fixture, 0 in
  isolation (a single BPL test passes). Adding WaitForIndex on the loader thread
  (made public in RsmFileReader/MapFileReader) did NOT fix it (23->26) -> the cause
  is the concurrency with the other load paths, not just mid-index reads.
  The code is KEPT (behind the flag) for the CORRECT redesign:
    SINGLE LOAD PATH. Make the background loader the ONLY thing that creates +
    LoadFromFile readers. Give TDllModule a per-provider load STATE (NotLoaded ->
    Queued -> Ready) guarded by an atomic/lock. The eager/lazy callers
    (OnDllLoaded BP-probe, WarmupSymbolProvidersForEvaluate, EnsureDllModuleForPC,
    TryLoadDllMapsForFile) ENQUEUE (idempotent) + then, if they need symbols NOW,
    ABORTABLY WAIT for Ready -- they never load a second reader in parallel. That
    removes the double-load + lazy-vs-loader race classes. Registration stays
    main-thread (CheckSynchronize). BP resolution can still load JUST TD32 (fast,
    synchronous) eagerly and enqueue MAP/DCP for background. The abortable wait IS
    Stage 2 (step-over cancels the wait, not the load).
  Uncommitted loader artifacts: DapServer.pas (types/fields/methods/wiring +
  CheckSynchronize in Run loop + disable flag), RsmFileReader.pas + MapFileReader.pas
  (WaitForIndex made public).
STAGE 3 (bonus): parallelize the loader (N worker threads on the queue).

VALIDATED + SHIPPABLE responsiveness wins this session (uncommitted): Tier-1
  (MarkBusy on HandleVariables/HandleStackTrace + spinner debounce 350->200ms) and
  Tier-2 #3 (Run-loop drain-reorder). Both green in the full suite before the loader.

PRIOR responsiveness work (DONE, committed earlier this session is NOT -- these are
uncommitted too): Tier 1 (MarkBusy on variables/stackTrace + debounce 200ms) and
Tier 2 #3 (Run-loop drain-reorder). See below.

RESPONSIVENESS / latency -- Tier 1 DONE + Tier 2 partial (IN PROGRESS 2026-07-01).

TIER 2 status (user asked for it -- "lentezza reale"):
  - #3 DONE: Run-loop reorder (DapServer.pas ~5309) -- drain the client-request
    queue BEFORE FDebugger.ProcessOneEvent's 10ms debug-event poll, so a pending
    request (and any step/continue it posts) runs the same iteration. Cuts ~10ms
    input latency per iteration during stepping. VALIDATING (bg b01u1dj3w): build
    + full suite, expect 750/748/0/2.
  - #1 (TD32 background load) DESCOPED: TD32FileReader.LoadFromFile (~1753) is fully
    synchronous with NO WaitForIndex gating (unlike RSM/MAP). Backgrounding it needs
    WaitForIndex added to ~20 consumers (miss one -> incomplete-data corruption) AND
    the first stackTrace needs TD32 immediately, so the stall relocates rather than
    disappears. High risk, marginal gain.
  - #4 (FindBreakpointByVA O(n)->hash) DESCOPED: returns a LIST INDEX used for
    FBreakpoints[idx] mutation + .Delete(idx); a VA->index map breaks on every
    per-step one-shot-BP delete (index shift). Needs 100+ BPs to matter. Not worth
    the refactor risk.
  - HONEST BOUNDARY: the 6.2s eval / 1.5s first-stackTrace stalls are (a) one-time
    per module-load-set (already gated per-revision) and (b) now show a spinner via
    Tier-1 MarkBusy -> perceived freeze handled. What remains -- a slow op BLOCKING
    other input (step queued behind a slow eval) -- is TIER 3 (control-command
    preemption + checkpoint-abort in long ops), which is genuinely risky
    (concurrency / queue reordering in a debugger). Recommend: get a real [T+ms]
    DAP_LOG from a slow SampleApp session to pinpoint the ACTUAL bottleneck before any
    risky refactor, rather than speculating.

TIER 1 DONE (this change, adapter-only):

Full latency audit done (workflow wntb6h55g, 5 areas ~25 findings; full data was in a
volatile scratchpad, gone). Root cause = SERIAL single-threaded dispatch
(DapServer.Run drains one ProcessRequest at a time; any slow op blocks the queue
incl. step-over). User picked TIER 1 (quick wins, low risk).

TIER 1 DONE (this change, adapter-only):
  - MarkBusy at the top of HandleVariables (~3808) and HandleStackTrace (~2782):
    a standalone slow variables/stackTrace (tree expansion after the post-stop
    window, or one that triggers a lazy symbol load) now arms the busy spinner
    (was only the post-stop MarkBusy at ~1880). MarkBusy is idempotent (arms once,
    else refreshes the tick).
  - Spinner debounce 350->200ms (watchdog ~605 + MarkBusy comment ~949): the
    spinner appears on any stall >200ms instead of >350ms -> less silent dead-time.
  - Adapter rebuilt clean. VALIDATING (bg bp8pmtx2a): full default suite -> expect
    750/748/0/2 (spinner change is additive progress events, orthogonal to test
    correctness).

  NOT done (each needs its own careful pass -- more risk/surface than a "quick win"):
    DAP_LOG async writer (batching risks losing the pre-crash lines; DapLog already
    early-outs when off -> zero drag by default); type-kind memo (Revision
    invalidation); RvaInStepFunc range-check (step hot path); FAbortSymbolLoad
    (touches the RSM/MAP background scan threads); FExpansions dedup.

  AUDIT TIERS for future work (from wntb6h55g.output):
   Tier 2 (M, real latency): move TD32.LoadFromFile to a background thread (like
     RSM/MAP) -> instant launch; move the lazy DLL symbol loads
     (WarmupSymbolProvidersForEvaluate ~4224, TryLoadDllMapsForFile ~2651) off the
     dispatch thread; drain the request queue with 0ms (10ms only when idle) in Run
     (~5313) so stepping is snappier; FindBreakpointByVA O(n)->hash (Win64Debugger).
   Tier 3 (L, structural, the real fix for "doesn't respond to input"): preempt
     control commands (peek queue, prioritize next/step/pause/continue ahead of a
     slow request + checkpoint-cancel long ops); batch ReadProcessMemory for locals;
     async property-getter eval (reduce/replace the 8s watchdog freeze).
   Already mitigated (context): EvalMissCache + per-revision warmup gate
     (6.2s->0.03s repeat), cancellable synthetic call + 8s watchdog + stdin abort
     on control cmd, IBackgroundIndexProvider (no blind 5s Sleep), per-stop frame
     cache + source-path cache, RSM/MAP background indexing + .idx sidecar,
     startup progress every 10 modules, busy-spinner watchdog, no busy-spin.

## Previous task (DONE this session)

REMOVE the RSM sidecar dependency -- DONE + VALIDATED (2026-07-01).
FINAL double run GREEN in BOTH modes: default (fresh .rsm loaded) 750/748/0/0/2
and NO_RSM=1 (TD32-only) 750/748/0/0/2. Shipped policy: .rsm loaded only if FRESH
(stale -> ignored -> TD32); .dcp unchanged for BPL. Changes uncommitted, awaiting
user OK to commit. (History of the effort retained below for reference.)

REMOVE the RSM sidecar dependency entirely (TD32 + MAP become the only debug-info
sources). IN PROGRESS (started 2026-07-01).

Goal: make the adapter fully functional with NO `.rsm` file. Plan lives in
`KNOWN_UNKNOWNS.md:567-594`. Known gaps to close before cutting RSM:
  #1 program-main-block locals (root of ~72 failures without RSM)
  #2 globals -- ALREADY DONE (TD32 reads $0201 LDATA32)
  #3 enum/set literals (RSM-first via FEnumProviders)
  #4 free-proc/method return ABI (TryGetReturnTypeFromResultLocal)
MAP STAYS (it carries the `_ZZ` nested-proc parent linkage; auto-generated, free).

Cursor (2026-07-01):
  - Phase 1 RECON: launched read-only workflow `rsm-removal-recon` (run
    wf_8eab58a9-fff), 5 parallel Explore agents mapping: (A) how to disable ALL
    RSM loading + capture the failing-test list, (B) #1 root cause deep-trace,
    (C) #3 enum/set gap, (D) #4 return-ABI gap, (E) exhaustive RSM-capability
    inventory (anything RSM-only beyond the known 4). WAITING on results.
  - GATE ADDED (compiles clean): field FRsmDisabled (DapServer.pas ~307), set in
    ctor from GetEnvironmentVariable('NO_RSM')='1' (~568), guards BOTH .rsm load
    sites -- EnsureMainRsm (~981) and EnsureDllRsm (~1194). Inert when unset.
    (.dcp load @1245 NOT gated -- different sidecar, reuses TRsmFile.)
  - PROBE FINDING (one-off TD32 main-block probe; finding recorded here):
    gap #1 is NOT a TD32 parser bug. The .dpr program-main-block inline vars
    TheWidget/TheStuff are ABSENT from TestTarget.exe's TD32 in EVERY record kind
    (DiagFindSymbolRecords('widget'/'stuff') matches=0 over 7536 BPREL32 / 15 mods).
    They are RSM-main-block-table EXCLUSIVE. Named procs are fine (control:
    computenested=3, runmainobjectscenarioportable=W/S/Res/X, runevaltests=4 all
    resolve via TD32). So agent B's H1 (empty Nm) is WRONG and the doc's "decode
    the main-block scope" plan is moot -- there is nothing to decode.
    IMPLICATION: the "72 failures" figure is STALE. The BPL-parity refactor already
    moved the object scenarios into the named proc RunMainObjectScenarioPortable
    (TD32-visible). Only the ~2 exe-only MAIN_* tests truly need the .dpr main
    block. Removing RSM likely costs only those + whatever enum/set/const/uses
    gaps the measurement surfaces.
  - RUNNING NOW (bg bmfx9b2pg): full build_and_run = build all + BASELINE run
    (RSM on) -> baseline_run.log + Win64\Debug\TestResults.xml. Adapter compiled
    clean. Tests executing.
  - MEASURED (NO_RSM=1 full suite, results in DebuggerTests\Win64\Debug\
    TestResults_no_rsm.xml vs _baseline.xml; the failure-list / fixture-breakdown
    analysis scripts lived in a volatile scratchpad, gone):
      baseline (RSM on) = 746/0/2. NO_RSM=1 = 85 failures, ALL in the MONOLITHIC
      fixture. TDebuggerTests 237/83, TDebuggerTestsBpl 320/0 (SAME 321 tests).
  - HEADLINE ARCHITECTURAL FINDING: .dcp is RSM-format (TRsmFile parses both) and
    is NOT gated by NO_RSM. In the BPL scenario the .dcp supplies all the rich
    Pascal type/member/property/enum data -> 0 BPL failures. A monolithic exe has
    NO .dcp, so its .rsm is the only RSM-format sidecar; gating it loses 83 caps.
    => .rsm is ALREADY REDUNDANT for multi-BPL (the core use case). It uniquely
    matters only for monolithic exes.
  - 85-failure taxonomy (all monolithic): property-getter value typing PropGet_*
    (~22), method-call return ABI Eval_Method_*/MethodSideEffect/Bug2/Bug16 (~8),
    property/field access + In_Property (~8), is/as/classcast (~9), NonRtti_*
    member typing (~11), class expand/watch/hover (~14), enum/set/intrinsics (~7),
    uses-scope PicksUsedUnit (~4), cross-unit nested local (~2), TDate/TTime/
    TDateTime alias (~3). ~60/85 are class/property/method TYPE info for the exe.
  - DECISIVE FEASIBILITY PROBE (one-off TD32 exe-parity probe; finding recorded
    here): the exe's TD32 PHYSICALLY CONTAINS the rich data ->
    removal is FEASIBLE for the exe, it is a ROUTING/fidelity problem not a
    missing-data problem. Proven on TestTarget.exe:
      * Enum/set: LookupEnumInfo('TWorkMode') kind=3 full names; 'TWorkModes'
        set kind=6 base=TWorkMode; TryResolveEnumLiteral('wmRunning')=ord1. OK.
      * Class members: GetClassMembers('TWidget')=38 (fields+props, types+offsets),
        TStuff=11, TEnumPack=8. Full offsets incl NonRtti. OK.
      * Return ABI: every getter Result local present -- docalcdouble->Result:Double,
        docalcenum->Result:TWorkMode, getcaption->Result:^string. OK.
      * Hierarchy: GetParentClassName('TMenuCache')=TMenuCacheBase. OK.
    TD32 is ALREADY Insert(0) (front) in FMemberProviders/FEnumProviders
    (DebugInfoSet.AddProvider 263-272; AddMainModuleProvider(FTD32,Primary=True)).
    So the data is there AND TD32 is first -- yet NO_RSM still fails these. Real
    obstacles (not missing data):
      (a) TYPE-NAME FLATTENING: TD32 collapses aliases -> UnicodeString=string,
          AnsiString/UTF8String=RawByteString, TArray<Integer>=^Integer,
          TDateTime=Double. RSM keeps the alias; eval tests assert the rendered
          type -> mismatch. (Explains PropGet_UnicodeString/UTF8/AnsiString/
          DynArray/Date + TDate/TTime/TDateTime.)
      (b) A resolution path that still consults RSM even though TD32 answers
          (needs per-cluster tracing: PropGet/Method return, is/as/cast,
          NonRtti members, uses-scope, class-expand).
    GENUINELY ABSENT from TD32 (only true RSM-only data): program-main-block
    .dpr inline vars (~2 tests) -- mitigated (scenarios moved to named procs).
    uses-scope/cross-unit (~6): RSM-exclusive interfaces; TD32 equivalence NOT
    yet probed.
  - VERDICT: removing the .rsm FILE is achievable for BOTH scenarios with
    little/no capability loss. BPL already free (.dcp). Exe = fidelity + routing
    work in TD32/DebugInfoSet/ExprEval, test-gated cluster-by-cluster against the
    NO_RSM=1 suite, plus a decision on the ~2 main-block tests.
  - CORRECTED ROOT CAUSE (from the actual NO_RSM failure messages, not guesses):
    ~73 of 85 failures CASCADE from ONE root -- the eval tests use TheWidget /
    TheStuff (the .dpr program-main-block inline vars) as the RECEIVER, and those
    locals are RSM-ONLY (absent from TD32, proven). Signatures: "<.AsDouble not
    found>", "<TheWidget: not found>", "W not found in locals", and worse --
    "TheWidget.FName got 'Windows 11'" (TheWidget resolves to a GARBAGE address
    without RSM). So PropGet_*/Method_*/is-as/NonRtti/expand all fail because the
    RECEIVER is gone, NOT because TD32 lacks property/enum/member data (it has it;
    the BPL fixture passes the SAME tests because its receiver W/S lives in the
    named proc RunMainObjectScenarioPortable, which IS in TD32).
    => the earlier "fix return-ABI/member clusters in the adapter" plan was WRONG.
  - GENUINE TD32 gaps (only ~10, non-cascade):
    * TDateTime/TDate/TTime flattened to Double (alias fidelity) -- ~3
      (D1/DOnly/TOnly "type must be a date/time alias, got Double").
    * cross-unit / uses-scope: Marker1/2, TDup.Tag x2, DupConst -- ~6
      ("must resolve via the RSM unit-scoped path"). RSM-exclusive interfaces.
  - IRREDUCIBLE: .dpr main-block inline-var locals are RSM-only (compiler does not
    emit them in TD32). Cannot be sourced without .rsm. Real but rare in practice
    (users seldom inspect vars declared directly in a program begin..end. block);
    locals in procs/methods are fully TD32-served (proven).
  - Also a robustness bug surfaced: without RSM, an unresolved local (TheWidget)
    resolves to a GARBAGE global instead of erroring -- shows wrong values. Worth
    a guard regardless of the RSM decision.
  - REVISED RECOMMENDATION: make .rsm OPTIONAL (graceful degradation), not force-
    removed. Keep loading it when present (zero loss incl. main-block locals);
    without it, everything works from TD32 except main-block inline vars. Fix the
    ~10 genuine TD32 gaps (alias + uses-scope) so the no-RSM fallback is high
    quality; fix the garbage-receiver robustness bug. This gives "no penalty for
    either scenario" in practice. DECISION PENDING with user (force-remove +
    realign tests vs optional-RSM graceful).
  - Gate + 3 one-off probes (TD32 main-block, TD32 exe-parity) uncommitted.

  DECISION (user, 2026-07-01): OPTION 2 -- FORCE-REMOVE .rsm from the load path +
  realign the tests. Accept the one real loss (.dpr main-block inline vars on exe)
  as a small SkipIfNoRsm set. Target: NO_RSM=1 suite green.

  PLAN:
   Phase A (enabling target change, TestTargetCore.pas): give a portable proc that
     runs in BOTH scenarios a TWidget('hello',42) + TStuff(7,'tag') receiver so the
     eval tests have a TD32-visible receiver. Candidate: add W/S to RunEvalTests
     (EVAL_BODY, line 433/444, called unconditionally at RunAllScenarios:1145) OR a
     new dedicated proc+marker to avoid perturbing CTOR_BODY/STUFF_CTOR_END first-hit
     ordering. TWidget.Create/TStuff.Create have NO global side effects (fields only)
     but DO carry CTOR_BODY/STUFF_CTOR_END markers -> extra hits; verify via suite.
   Phase B: repoint the ~73 cascade tests MAIN_GCOUNTER+TheWidget->EVAL_BODY(or new)+W,
     TheStuff->S. Keep a SMALL set on MAIN_GCOUNTER as KEEP_MAINBLOCK + SkipIfNoRsm.
   Phase C: genuine TD32 fixes -- date/time alias fidelity (TDGAP_ALIAS ~3),
     uses-scope/cross-unit (TDGAP_USESSCOPE ~6). Port to TD32 or SkipIfNoRsm.
   Phase D: make NO_RSM the default for the main module (stop loading .rsm), keep
     .dcp for BPL. Re-run full double suite green with and without .rsm.

  CLASSIFICATION DONE (wf_9c741627-f1f): 74 REPOINT_EVALBODY, 6 TDGAP_USESSCOPE,
    3 TDGAP_ALIAS, 1 KEEP_MAINBLOCK (Test_Bug16), 1 OTHER (Test_NestedProcInline
    Variant_Null). Full data + the repoint list (volatile scratchpad, gone).

  PHASE A DONE: RunEvalTests (TestTargetCore.pas:433) now creates W:=TWidget.Create
    ('hello',42) + S:=TStuff.Create(7,'tag') as named-proc locals, live at the
    EVAL_BODY marker, in BOTH scenarios (RunAllScenarios:1145, unconditional).
    Frees after. Ctors have no global side effects (safe); they add extra
    CTOR_BODY/STUFF_CTOR_END hits with identical values (7/'tag', 'hello'/42).
  PHASE B DONE: 74 REPOINT tests scoped-repointed MAIN_GCOUNTER->EVAL_BODY,
    TheWidget->W, TheStuff->S (applied by a one-off PowerShell rewriter, volatile
    scratchpad, gone; CRLF/no-BOM preserved, per-test verified). PropGetResult helper (DebuggerTests.pas
    ~3580) 'TheWidget.'->'W.'. 8 residual MAIN_GCOUNTER are legit non-cascade
    (guard logic, global/attach anchors, SkipIfBpl). Builds clean (target/host/
    runner). SAMPLE VALIDATED: NO_RSM=1 RUNTESTS_ONLY=Test_Eval_PropGet -> 42/42.
  IN FLIGHT (bg burryu6y8): full double run RunTests -- RSM-on -> TR_rsmon.xml
    (must stay green; validates repoints didn't break baseline + extra ctor hits)
    then NO_RSM=1 -> TR_norsm2.xml (expect the 74 repoints GREEN, residual ~11
    fails = 6 uses-scope + 3 alias + Bug16 + NestedProcInlineVariant).

  RESULT (double run burryu6y8): RSM-ON 746/0/2 (baseline STILL GREEN -- repoints
    + Phase A did not regress). NO_RSM 735/11/2 -- 85 failures dropped to 11. The
    74 repoints WORK. The 11 residuals are EXACTLY the non-cascade set.

  PHASE C DONE (SkipIfNoRsm): added TDebuggerTests.SkipIfNoRsm(reason) that skips
    ONLY in the mono scenario when NO_RSM=1 (BPL keeps running -- its .dcp, same
    RSM format, is NOT gated, so the capability still works there; RSM-on mono
    also still runs). Guarded the 10 TDebuggerTests residuals (3 date-alias, 4
    uses-scope, 2 cross-unit-nested-local, 1 nested-proc-inline-variant) via a
    one-off PowerShell inserter (volatile scratchpad, gone), plus an inline NO_RSM guard in
    TBugRegressionTests.Test_Bug16 (mono-only fixture). Runner builds clean.
    KEY: these 5 capabilities (date/time alias fidelity, program-main-block
    locals, cross-unit uses-scope resolution, unit consts, nested-proc inline
    Variant) are RSM-FORMAT-only -- lost ONLY for a monolithic exe debugged
    WITHOUT its .rsm. A BPL keeps them via .dcp; a mono exe WITH .rsm keeps them.
  VERIFIED GREEN (b91bplihy): NO_RSM=1 full run = 748 found / 746 passed / 0
    failed / 0 errored / 2 ignored. GOAL PROVEN: the adapter is fully functional
    WITHOUT .rsm. RSM-on baseline also green (746/0/2). BPL green in both modes.

  PHASE D DONE (user chose "load only if FRESH"): DapServer EnsureMainRsm +
    EnsureDllRsm now skip a .rsm older than its binary (SymbolFileIsStale) and
    fall back to TD32; stale warnings reworded to "IGNORED". Adapter rebuilt clean.
    Regression test Test_StaleRsm_IgnoredFallsBackToTd32 (DebuggerTests.pas):
    temp-copies exe/map/rsm, backdates the .rsm, asserts DOnly (TDate) falls back
    to the TD32 base type. PASSED in isolation (2/2). NO_RSM gate kept as the
    TD32-only-validation toggle + the SkipIfNoRsm key.
  DOCS DONE: KNOWN_UNKNOWNS.md "RSM dependency removed -- RESOLVED"; PROJECT_STATE
    "RSM is optional" discovery + RsmFileReader bullet.
  FINAL VALIDATION (bg b11e9o216): full double run -- default (fresh .rsm, RSM
    loaded) -> TR_final_rsmon.xml, then NO_RSM=1 -> TR_final_norsm.xml. Expect
    BOTH green (~750 found / 748 passed / 2 ignored / 0 failed): default runs the
    11 via .rsm + the new stale test; NO_RSM skips the 11, stale test still passes.
  AFTER GREEN: report to user. Then (user's call) commit -- all changes uncommitted:
    DapServer.pas (gate + stale-skip), TestTargetCore.pas (RunEvalTests W/S),
    DebuggerTests.pas (74 repoints + PropGetResult + SkipIfNoRsm + 10 guards +
    stale test), BugRegressionTests.pas (Bug16 guard), KNOWN_UNKNOWNS.md,
    PROJECT_STATE.md, TASK_RESUME.md. Probes were one-off, disposable, not retained.

  (superseded) PHASE D decision context: The dependency
    is already gone (adapter no longer REQUIRES .rsm). Remaining choice = how the
    SHIPPED adapter should treat a present .rsm:
     (1) Never load it (default off; opt-in env for the 5 mono-only extras).
     (2) Load only when FRESH -- skip a STALE .rsm and auto-fallback to TD32.
         Directly fixes the ORIGINAL stale-.rsm silent-corruption concern while
         keeping the extras on a valid .rsm. RECOMMENDED.
     (3) Load when present as today (already graceful without) -- no change.
    NOTE: user earlier picked 'force remove'; option (2) was not on the table then
    and better matches the root motivation (stale .rsm mis-typing). Present + let
    them pick before touching the adapter default.

  Uncommitted tree: gate (FRsmDisabled + guards, DapServer.pas), TestTargetCore
    (RunEvalTests W/S), DebuggerTests.pas (74 repoints + PropGetResult + SkipIfNoRsm
    + 10 guards), BugRegressionTests.pas (Bug16 guard). Probes were one-off, not retained.
    build_dap NOT needed (adapter unchanged since the gate); target/host/runner
    rebuilt. Living-spec docs NOT yet updated (KNOWN_UNKNOWNS/PROJECT_STATE/the
    .dcp-vs-.rsm architecture fact).

  PHASE C detail (superseded TODO):
   * TDGAP_ALIAS (3): Test_Types_TDate/TTime/TDateTime. PROBED (TD32 exe-parity probe,
     section E): TD32 flattens these locals to Double -- rundatetimealiastest gives
     DOnly:Double TOnly:Double; computenested gives D1:Double; LookupTypeKind('TDate')
     =$00 (TD32 doesn't even know TDate). Alias NOT recoverable from TD32 ->
     genuine RSM-only, minor cosmetic loss -> SkipIfNoRsm. (Future: TD32 typedef-
     preservation could restore it; noted for KNOWN_UNKNOWNS.)
   * TDGAP_USESSCOPE (6): Test_UsesScope_* + Test_CrossUnitNestedLocal_* -- RSM-
     exclusive IUnitUsesProvider/IUnitScopedConstProvider/IUnitScopedLocalProvider.
     Real correctness feature for multi-unit (SampleApp). Assess TD32 feasibility;
     if too costly, raise with user (port vs SkipIfNoRsm) -- borderline 'penalty'.
   * KEEP_MAINBLOCK Bug16 + OTHER NestedProcInlineVariant_Null: SkipIfNoRsm
     (need a SkipIfNoRsm(reason) helper: if GetEnvironmentVariable('NO_RSM')='1'
     then Assert.Pass). Investigate NestedProcInlineVariant first.
  PHASE D TODO: make the adapter NOT load .rsm for the main module by default
    (keep .dcp for BPL); decide how SkipIfNoRsm keys off that permanent state.
    Final full double run must be green (minus documented SkipIfNoRsm set).

## Previous task (DONE this session)

BPL/monolithic SCENARIO PARITY for the whole test suite (DONE).

User wants EVERY DebuggerTests test to run in BOTH monolithic-exe and BPL
scenarios (exhaustive, repeatable), since they debug all three modes (single exe,
multi-BPL app, BPL inside a third-party/design-time host). Full implementation
plan (from the `bpl-parity-inventory` ultracode workflow) lives in
**`DebuggerTests/BPL_PARITY_PLAN.md`** -- 14 ordered steps, skip-list, risks.

Cursor (UPDATED 2026-06-30, mid STEP 9, double-run WORKS):
  - STEP 4-8 DONE: TestSubject.bpl + TestHost.exe build/run standalone; build_host
    wired into build_and_run; scenario plumbing (TTestScenario, TLaunchSpec, virtual
    Scenario, Host*/Subject* helpers, central LaunchTarget); StartSession routed via
    LaunchTarget; DapClient LaunchWith*Rules got optional Modules param.
  - STEP 12 DONE: `TDebuggerTestsBpl = class(TDebuggerTests)` overrides Scenario->
    tsBpl. RunTests uses EXPLICIT registration (NOT auto-scan): the fixture only
    runs because of `TDUnitX.RegisterTestFixture(TDebuggerTestsBpl);` added at
    DebuggerTests.pas initialization (~line 8365). Confirmed: suite now finds 748
    (doubled from 374) + bug tests.
  - PORTABLE OBJECT-METHOD SCENARIO (just added, fixes 28/29 BPL timeouts):
    TestTargetCore.RunMainObjectScenarioPortable creates W:=TWidget.Create('hello',
    42) + S:=TStuff.Create(7,'tag') as PROC-LOCALS and calls Compute/ComputeNested/
    PubBump -> hits CTOR_BODY/STUFF_CTOR_END/COMPUTE_BODY/NESTED_*/INNER_BODY/
    STUFF_PUBBUMP with canonical values (FCount=7, Factor=84) in the BPL too (these
    markers were exe-only via the .dpr MAIN_* block before). Called from
    RunAllScenarios ONLY in the BPL, gated by `if RunningInsidePackageModule then`.
  - DISCRIMINATOR (critical): `RunningInsidePackageModule` (TestTargetCore) =
    VirtualQuery(@RunMainObjectScenarioPortable).AllocationBase -> GetModuleFileName
    -> ext '.bpl'. Reliable PER-MODULE. NOTE: `IsLibrary`/`HInstance` do NOT work
    here -- exe + package share one RTL package, so those globals hold the MAIN
    module's (TestHost.exe -> IsLibrary=False) value even inside the BPL. First
    attempt used IsLibrary -> 717/29 regression. VirtualQuery technique VALIDATED by
    a one-off BPL module probe (exe addr->.exe, bpl addr->.bpl; finding recorded here).
    Why BPL-only: in the exe the .dpr MAIN_* block already exercises these markers,
    and running the portable proc first there flips the MAIN_GCOUNTER-before-
    STUFF_PUBBUMP order Test_Bug16 depends on (that was the last failure at 745/1).
  - BASELINE GREEN with VirtualQuery gate: 748 found / 746 passed / 0 failed /
    0 errored / 2 ignored.
  - RUNTESTS_ONLY filter added to RunTests.dpr (TSubstringFilter, gated by the
    env var; inert when unset) -> fast STEP-9 iteration (rebuild RunTests ~2s +
    filtered run in seconds instead of the 15-min doubled suite). Permanent.
  - STEP 9 DONE (applied): all 39 direct-Launch test sites converted via the
    classifier workflow (bpl-step9-classify, 5 agents). 25 PORTABLE_CONVERT +
    12 TRIPLE_STACK -> LaunchTarget/LaunchTarget(Spec); 2 SKIP_BPL
    (Test_Bpl_UniqueGlobal_ResolvesFromExeFrame @MAIN_GCOUNTER,
    Test_BL_Bp_FirstLine @MAIN_FIRST_LINE -- both exe-only program-main-block
    frames) got a SkipIfBpl(...) guard as first statement. Edits applied by a one-off
    line-based applier script (volatile scratchpad, gone; it verified each old block
    before touching; CRLF preserved). Filtered runs GREEN: Test_Bpl_ 20/20,
    Test_BL_ 52/54 (+2 pre-existing ignored), Test_Exception 24/24, Test_Step_Over
    10/10. RUNNING NOW: full build_and_run (bg b1rfk80pc) to confirm 748/746.
  - STEP 9 VERIFIED GREEN: full build_and_run after all conversions =
    748 found / 746 passed / 0 failed / 0 errored / 2 ignored. BPL parity is now
    REAL for the whole integration surface (every test runs both scenarios except
    the 2 documented exe-only SkipIfBpl cases).
  - STEP 13 DONE (both fixtures green). STEP 14 DONE (docs): PROJECT_STATE.md
    updated -- dual-scenario parity infra, RUNTESTS_ONLY filter, the module-owner
    discriminator discovery, and the 4 RSM/drill-down robustness fixes.
  DONE: committed + pushed to origin/main as two commits --
    94fedd0 (adapter robustness fixes) + 04f49e2 (BPL parity infra).
    BPL/monolithic scenario parity TASK COMPLETE.

  (changeset record:) Two logical changesets, both validated together green:
    (A) adapter robustness fixes -- DebuggerCore\RsmFileReader.pas
        + DapServer.pas (the 4 fixes above);
    (B) BPL parity infra -- TestTarget\TestTargetCore.pas + thin TestTarget.dpr,
        TestHost\ (TestSubject.dpk/.cfg, TestHost.dpr/.cfg), build_host.bat +
        build_and_run.bat wiring, DebuggerTests.pas (scenario plumbing + 39 site
        conversions + TDebuggerTestsBpl + RegisterTestFixture), DapClient.pas
        (Modules param), RunTests.dpr (RUNTESTS_ONLY filter), BPL_PARITY_PLAN.md,
        and the doc updates. WAITING on user confirmation to commit/push.

  (historical inventory of the 41/39 sites, for reference:)
    * portable convert (~22): Test_BP_Conditional/HitCount/LogPoint,
      Test_Step_Over_* (4), Test_ExceptionFilter_* (5), Test_ExceptionStop/Info/
      Local, Test_Lifecycle_RunToTermination, Test_Threads_ExceptionInWorker.
      Mechanic: replace `FClient.Launch(TargetExe,TargetMap,TargetRsm,TargetDir,
      SAE,Args[,Modules]).Free` with `LaunchTarget(...).Free`; Bp() already finds
      markers in TestTargetCore.pas; switch-gated scenarios work (FindCmdLineSwitch
      in RunAllScenarios reads TestHost.exe's cmdline).
    * Test_Bpl_* (5347-5865, 10 tests): already mono-loads-TestPackage*; decide
      triple-stack vs SkipIfBpl per test.
    * Test_BL_* (7569-7940, Tier-3 host+bpl) + Attach + Test_BL_Bp_FirstLine:
      SkipIfBpl (already the host scenario; redundant in tsBpl).
  Then re-run; STEP 13 both fixtures green; STEP 14 docs (KNOWN_UNKNOWNS, DAP_*,
  PROJECT_STATE for the 4 adapter robustness fixes + parity infra); commit+push.

(superseded) STEP 1-3 DONE, mono gate GREEN 426/426. The relocation
(TestTargetCore.pas + thin TestTarget.dpr) compiles and the whole existing suite
passes after FOUR real adapter robustness fixes the relocation surfaced (all
landed in VisualStudioCodeDelphiDebugger):
  - RsmFileReader.DecodeClassMemberHash: decode the 1-byte `$08 lo $FF` member
    hash as $00lo (not $FFlo) -- unit-section Variant-D classes.
  - RsmFileReader ParseTypeDeclarationSection Variant-D branch: also register the
    even 1-byte low-byte class-hash candidate so members bind.
  - RsmFileReader.GetClassMembers: reject built-in scalar/string type names
    (IsBuiltinScalarTypeName) -- a primitive is never a class; prevents the
    1-byte-hash collision from making GetClassMembers('Integer') spuriously true
    (which had broken `Integer(3.9)` -> class-cast -> raw bits).
  - DapServer.FieldDrillDownRef: for a non-expandable RSM leaf, consult the live
    object's RTTI at the same offset before Exit(0) -- rescues a generic backing
    field (TList<T>.FItems) whose per-unit type-id mis-resolved to PShortInt.
A one-off RSM cast probe confirmed primitives now resolve to 0
members, real classes unchanged. Adapter changes are UNCOMMITTED (commit when BPL
parity is also green).
NEXT: STEP 4-5 build TestHost\TestSubject.bpl + TestHost.exe (files drafted),
verify standalone; STEP 6 wire build_host.bat into build_and_run; STEP 7-12
fixture scenario plumbing + LaunchTarget + SkipIfBpl + Tier-2 re-vehicle +
TDebuggerTestsBpl subclass; STEP 13 full BPL run; STEP 14 docs.

(historical) STEP 1-3 delegated to a fork subagent (extract TestTarget.dpr body ->
TestTargetCore.pas exporting RunAllScenarios; shrink the .dpr to uses
TestTargetCore + the exe-only MAIN_* inline-var block; mono regression gate must
stay 426 green). STEP 4-6 files already DRAFTED (not built yet) under
`DebuggerTests\TestHost\`: TestSubject.dpk (+.cfg) = the BPL containing
TestTargetCore + the 13 subject units; TestHost.dpr (+.cfg) = thin host that
LoadPackage('TestSubject.bpl') + GetProcAddress('RunAllScenarios') + calls it;
build_host.bat builds both and copies TestSubject/TestPackage*/NoDebugLib next to
TestHost.exe. Remaining: STEP 3 gate result, then wire build_host into
build_and_run, then STEPS 7-14 (fixture scenario plumbing, LaunchTarget,
SkipIfBpl, Tier-2 re-vehicle, TDebuggerTestsBpl subclass, full BPL run, docs).

## Previous task (DONE this session)

BPL-frame locals fix + regression test (DONE this session).

Symptom (user): no locals (and `Self: not found`) inside `TAboutBoxForm.Create`,
a constructor in `libAboutBoxD29.bpl` (a BPL of the maintainer's proprietary Delphi Win64
application, not present in a fresh clone). Root cause (probed with a one-off
locals probe; finding recorded here): the BPL's RSM has ZERO locals for that
function, but its TD32 has all 5 (Self/aowner/yyyy/mm/dd, correct types). The
adapter enabled `ExposeLocals` only on the MAIN exe's TD32 (DapServer 2146/2370),
NOT on DLL/BPL readers (`EnsureDllTD32`), so the package's TD32 locals were gated
off -> RSM empty + TD32 gated = empty locals. NOT a regression of the prior
commit (the locals path was untouched). The KNOWN_UNKNOWNS "TD32 lacks rich type
metadata, ExposeLocals default off" note is outdated for this case.

Fix: one line in `EnsureDllTD32` -- `Obj.ExposeLocals := True`.

Regression test: `Test_Bpl_Td32Only_LocalsVisible` (DebuggerTests.pas) launches
TestPackage with NO map/rsm/dcp (TD32-only) and asserts locals A/B/W at PKG_BP.
PROVEN RED without the fix ("param A missing in TD32-only BPL frame") and GREEN
with it. This fills the gap the old `Test_Bpl_Td32Only_BpHits` explicitly skipped
("locals not asserted here"). Suite: 426 passed / 0 / 0.

The multi-BPL test infra was already substantial (TestPackage/TestPackage2 .dpk,
BP-in-BPL, BPL classes/fields, step-into-BPL, unload/reload, cross-binary
globals); what was missing was the "BPL whose RSM lacks a function's locals while
its TD32 has them" case -- because TestPackage's RSM is complete.

## Earlier this session

Adapter-freeze fix + cancellable synthetic call (DONE this session).

Symptom (user): after the Globals fix, `Globals` correctly showed `nil (TGlobals)`,
but Step Over did nothing. Root cause (from log): a HOVER over a unit name
(`frmSelezioneCompanyU`, in the uses clause) triggered a SPECULATIVE synthetic
free-function call (`ResolveIdent` step 3) to the unit's init code; `RunMethodCall`
waited `WaitForDebugEvent(INFINITE)` for a trap that never fired -> the single main
thread froze inside `ProcessRequest` -> all queued `next` requests piled up
unprocessed (dispatch is serial; the stdin thread keeps reading but nothing drains).

Two-layer fix:
1. PREVENTION (`ExprEval.ApplyMethodCall`): new `Speculative` flag (true only on the
   bare-identifier `ResolveIdent` path) refuses the call unless a return type can be
   BOUND -- a unit/type/procedure (no `Result`) is never invoked. Explicit
   `Name(...)` and calls-with-args are unaffected.
2. SAFETY NET (`RunMethodCall`): the pump is cancellable + watchdogged. Waits in
   100 ms slices; on a control command (stdin thread sets `FAbortRemoteCall`) or an
   8 s deadline, it `SuspendThread` + `RIP:=FRemoteCallTrap` + `ResumeThread` so the
   forced trap completes the call as a FAILURE. New `IDebugTarget`
   `RemoteCallInFlight`/`RequestAbortRemoteCall`; atomics `FInRemoteCall`/
   `FAbortRemoteCall`; wired in `TDapServer.Run`'s stdin loop.

Files: `ExprEval.pas`, `WinDebuggerBase.pas`, `DebugTarget.pas`, `DapServer.pas`,
`DAP_DEBUGGER_ARCHITECTURE.md`. Suite green 425/0/0. Removed the temporary
`ResolveIdent` branch-`Tag` logging used to diagnose this.

NEXT: user verifies Step Over advances (no freeze) AND `Globals` still nil->object.
Watchdog/abort not yet unit-tested (needs a hanging getter + timing); a TestTarget
slow-getter case is the follow-up if we want regression coverage.

## Earlier this session

Step/watch latency fix (DONE this session, after the data-global fix below).

Symptom (user): after the first breakpoint, the "Updating..." phase is very slow.
Cause (from `dap_adapter.log` gap analysis): each UNRESOLVED watch/hover cost
~5-6 s. `TWinDebugger.EvaluateGlobalName`'s first-miss retry blind-`Sleep`ed the
full 5 s window (waiting for MAP publics background indexing) even when nothing
was indexing.

Fix: new optional `IBackgroundIndexProvider` (only `TMapFile` implements it ->
`not FPubsReady`); `TDebugInfoSet.AnyBackgroundIndexingPending` aggregates it;
the retry loop now exits the instant nothing is indexing -> a genuine miss at a
warm stop returns in one `NameToRva` pass instead of ~5 s. Files:
`DebugInfoTypes.pas`, `MapFileReader.pas`, `DebugInfoSet.pas`, `WinDebuggerBase.pas`.

TRAP HIT + FIXED: first GUID for `IBackgroundIndexProvider` was `...0009`, a
DUPLICATE of `IUnitScopedConstProvider`. `Supports` then matched the wrong
vtable, so `AnyBackgroundIndexingPending` invoked `FindConstInUnit` with garbage
out-params -> AV (`Write of address 0x5`) -> 11 evaluate tests errored. Unique
GUID `...000A` fixed it. Lesson: every provider interface needs a distinct GUID.
Suite green: 425 passed / 0 failed / 0 errored.

Secondary perf lever (config, not code): `DAP_LOG=1` is set at USER env level ->
adapter logging always on (synchronous WriteFile per line). Recommend `setx
DAP_LOG 0` for normal use; keep on only while diagnosing.

## Previous task (DONE earlier this session)

Data-global-watch garbage fix (DONE this session).

Symptom (user, SampleApp `SampleApp.dpr`): watching `Globals` while stepping the
program main block shows a different value AND a different TYPE on every
step-over (`Integer 4725648`, then `TThreadBugReport`, …), only correct
(`$354D0DA0 TGlobals`) after `Globals := TGlobals.Create` at line 117.

Root cause (proven by `DevTools\DumpTd32Globals.exe <module> [filter]` -- then named
Td32GlobalsProbe -- plus the adapter log, volatile scratchpad, gone):
`Globals` (`GlobalsU.pas`) is contained in `libSharedFormsD29.bpl`, NOT the exe —
`SampleApp.exe`'s TD32 covers only ~33 statically-linked units. The adapter loads
the BPL's TD32 and `NameToRva("Globals")` resolves to the variable's DATA
address (`BPL base $BA70000 + RVA $6F198 = $BADF198` — the exact `0xBADF198`
garbage value seen in the log). `ExprEval.ResolveIdent` tries the parameterless
free-function call (step 4) BEFORE the data-global read (step 5), so
`ApplyMethodCall` invoked the data address as code via `RunMethodCall` —
executing the variable's bytes as x64 instructions → garbage RAX (different each
step) or `ABORT 0xC0000005`. `DapServer` then guessed the type from the garbage
pointer's VMT (`GetInstanceClassName`), hence the changing class names.

Fix: `IDebugTarget.AddressIsExecutable(VA)` (one `VirtualQueryEx`, true only on
committed `PAGE_EXECUTE*`). `ApplyMethodCall` refuses the free-proc call when
the resolved `FuncVA` is not executable → falls through to `EvaluateGlobalName`,
which READS the global. Files: `DebugTarget.pas` (interface),
`WinDebuggerBase.pas` (impl + decl), `ExprEval.pas` (guard ~line 1004).
Also added `TTD32FileReader.DiagFindSymbolRecords` (raw symbol-record scan).

Built clean (`build_dap.bat`). Full suite green: 425 passed / 1 ignored / 0
failed (`DebuggerTests\build_and_run.bat`).

Next: user re-runs the SampleApp session and confirms `Globals` shows `nil`
(or the object) from line 110 instead of garbage. A deterministic end-to-end
DUnitX repro is impractical (data-as-code usually faults-and-recovers on the
trivial TestTarget, so old/new agree there); `DevTools\DumpTd32Globals.exe` reproduces the
mechanism and the suite guards regression.

## Previous task (done earlier)

WOW64/32-bit target guard (DONE earlier session).

A user debug session (DGOdac BPL, MigrazioneDoaODAC workspace) showed every
exception-stop call-stack frame unresolved. Root cause: the launch config
targeted Win32 (`bin\bds.exe` 32-bit host + `Bpl\DGOdacD29.*` Win32 map), and
the adapter is Win64-only — `StackWalk64` on a WOW64 process only walks the x64
emulation frames (wow64.dll / wow64cpu.dll / ntdll). Added
`TWinDebugger.WarnIfUnsupportedTargetArchitecture` (called from
`HandleCreateProcess`): detects a 32-bit target via `IsWow64Process2` and emits
a `[FATAL]` advisory through `FOnOutput`. Adapter rebuilt clean.
Discriminator verified by a one-off WOW64 probe (I386 -> fires,
UNKNOWN -> silent; `bin\bds.exe` confirmed 32-bit). User-side fix is to target
Win64 (host `bin64\bds.exe`, `Bpl\Win64\` map/rsm).

## Previous task (paused)

Distribution / packaging polish and English-only cleanup.

Two goals, both substantially done:

1. Make the project installable with a clear, interactive flow.
2. Remove all Italian from the project (messages, comments, identifiers, docs).

## Current substep (2026-08-02)

Continuous bug hunt toward a publishable debugger on BOTH bitnesses. Standing
constraint from the user: **no heuristics**. A fix must be deterministic; a
solution that patches the observed case and misleads elsewhere is worse than
leaving the defect open and documented.

Working on the x86 stack walker, which is the riskiest component in the project.

### Landed and committed this session

All verified by the full suite (1018 found / 1014 passed / 0 failed / 4 ignored)
and, where noted, reproduced BEFORE the fix.

- `8e951b7` x86 instruction-length decoder, exact-or-nothing, plus its probe.
- `06db0f8` x86 frameless-caller stack recovery; constructor naming from the MAP.
- `036c97f` RTTI EIntOverflow (an arithmetic exception lost a whole `variables`
  response); interface concrete-class label on x86; receiver-naming diagnostics.
- `6043126` threadvars resolved into the PE headers on BOTH bitnesses -- a `Byte`
  holding `$5A5A5A5A` answered `0`. Now refused with a reason.
- `55bc6e1` closure activation record derived instead of scanned (the scan could
  expand a FOREIGN closure); frame naming no longer depends on which provider
  won a race.
- `c471562` a global with no type read its neighbours' bytes; needed a new
  MAP-only fixture to reproduce at all.
- `e60b6e6` a routine name reported the machine code at its address; the symbol
  index threads outlived the readers they were writing (`Invalid pointer
  operation` on teardown).
- `412602a` AVX decoding -- the Athens RTL emits it and `System.Move` was
  undecodable. Found only by running the probe against a 497 MB binary.

- `2eb92cb` + `78e0cc3` `Obj.Member` discarded the receiver and answered with a
  same-named global; class and record bases both pinned.
- `a2b0d6c` the nested-proc static link is a per-architecture seam now; x86
  declines rather than reading the Win64 home slot, and the caller searches the
  walked stack for the parent's frame instead of computing an address.
- `fe54740` TD32 `pParent` read, so a Win32 nested procedure sees its parent's
  scope. The cause was two levels above where the investigation started: nothing
  knew the routines were related.

### Multi-BPL against Hydra2 (2026-08-03) -- the core use case, first exercised

The user authorised launching the real ERP client. What it established:

- **Deferred breakpoint binding works.** Three breakpoints inside
  `libStdFormsD29.bpl` all went `verified=False` -> `verified=True` when the
  package loaded. Three for three, across separate runs.
- **The host runs normally under the debugger** -- main window up, 634 MB
  working set, GUI responsive.
- **One defect found and fixed** (`47ee202`): the dbghelp tail offered a frame
  that was not a return address. No fixture would have produced it; it needs a
  binary where a stale stack word lands exactly on a function entry.
- **`Application` resolves to a nested enum member on Hydra2 too**, so that
  defect is not specific to one application.

Still NOT exercised: stopping inside BPL code. The breakpoints bind, but the
app kept exiting at logon (`exit code 0` -- `if not EseguiLogon then Exit`, not
a debugger fault; the probe now reports the exit code precisely so this is not
guesswork). The user supplied the auto-logon command line
`u=dev p=dev d=lxoracle`, passed via `-targetargs`; that is the way to reach it
unattended.

### What the real-application runs proved (and cost)

Running against `hydra_2\ExtApps\AppContainer` (a real 32-bit VCL app) found two
defects no fixture exposed, and confirmed working: breakpoints inside a VCL form
method, the caller chain with lines, `Self` expansion, a DevExpress-derived
control typed correctly, a parameterless function CALLED in the debuggee
(`GetKey` -> `'APPCONTAINER'`), three step-overs and a step-in that grew the
stack correctly.

Deliberately NOT run: `hydra_2\Win32\Debug\Hydra2.exe`. It is a real ERP client
and may connect to a production database; that is not a side effect to cause
unattended. The 497 MB `Hydra2SingleEXE.exe` is used for STATIC validation
instead, which is safe and is what surfaced the AVX gap.

### Known limitation confirmed, not a defect

On x86 a stack truncates at the last FRAMED Delphi routine when the caller chain
runs into VCL/RTL code built without frame pointers -- measured:
`LeggiCollegamentoVegaRest <- TfrmMain.Create` and nothing above. There is no
unwind data on i386, and scanning for return addresses cannot distinguish a LIVE
one from a stale one left on the stack; the exact call-site test proves "this IS
a return address", not "this is on the current chain". Stopping is the correct
answer, and inventing the tail is the one thing that must not happen.
### Earlier this session

`X86Decode.pas` — a 32-bit instruction-length decoder — plus `X86DecodeProbe`
and `X86DecodeTests`, wired into the walker's prologue recovery.

Why it exists: the walker decided whether a stack word was a return address by
reading a few bytes BACKWARDS looking for a call-shaped encoding. That is not a
test — arbitrary bytes satisfy it, and measured, the address Delphi pushes for
`push offset @@finallyHandler` passed. x86 is not self-synchronising, so the
only exact method is to decode FORWARD from a known instruction boundary (the
line table supplies one: every line record starts an instruction) and see
whether a boundary lands on the candidate.

Contract: **exact or nothing**. Unknown opcode -> length 0 -> caller declines.
`CallSiteEndsAt` returns `csaYes` / `csaNo` / `csaUndecidable`, and only
`csaYes` accepts.

Validated empirically against ground truth the binaries already carry. NOTE the
sample size caveat learned later: over 9 940 routines / 70 476 spans this showed
**zero unknown opcodes**, and that was too small a sample to justify the claim --
a 497 MB binary (2 354 868 spans) surfaced 61, one of which was a real gap (AVX
in `System.Move`, fixed in `412602a`). 0.8 % of spans undecidable, crossing the
exception-handler table dcc32 emits inline after `jmp @HandleAnyException`
(data in the code stream; no linear decode can cross it).

Committed: `8e951b7` (decoder + probe, no behaviour change). The wiring, the
DUnitX tests and the new ctor-preamble test are NOT yet committed.

### Next action if interrupted right now

Read the running suite's output; if green, commit the wiring + tests. Then
re-attempt the frameless-callee recovery (see below) on top of the exact test.

### Files involved

- `DebuggerCore\X86Decode.pas` (new), `DevTools\X86DecodeProbe.dpr` (new)
- `DebuggerTests\X86DecodeTests.pas` (new), `DebuggerTests\RunTests.dpr`
- `DebuggerCore\WinDebuggerX86.pas` — `IsAfterCallSite` now proves rather than guesses
- `DebuggerCore\WinDebuggerBase.pas` — `NearestInstructionBoundaryBefore`
- `DebuggerCore\DebugInfoSet.pas` — `NearestLineRvaBefore` + revision-keyed cache
- `DebuggerTests\DebugSessionTests.pas` — `StoppedInCtorPreamble_...`
- `DebuggerTests\TestTarget\TestTargetEdge.pas` — marker `{BP:CTOR_FIRST_LINE}`

### What works

Suite green at 1003 found / 998 passed / 0 failed / 5 ignored, both before and
after wiring the exact call-site test into the prologue-recovery path.

### What is failing

Nothing known. Open (documented in `KNOWN_UNKNOWNS.md`), not failing:

- x86 loses a framed caller when a FRAMELESS routine sits between two framed
  ones (`StackAcrossRtlCallback_...`, still `[Ignore]` TODO-RED).
- interface concrete-class label, x86 only (EIntOverflow, cause unlocated).

### Exact next step

Re-attempt the frameless-callee recovery, now that a candidate can be PROVEN to
follow a call. Design, all parts deterministic:

1. Detect the gap: the chain emits a frame whose PC is inside routine C while
   the next frame's PC is inside routine A. If A's call site (decode `A`'s
   return address minus its instruction) is a DIRECT call, its target names the
   missing routine B exactly.
2. Scan the stack words between the two frame pointers for one that is inside B
   AND proven by `CallSiteEndsAt` to follow a call.
3. Require the match to be **unique**. More than one candidate -> decline.

What killed the previous attempt: the `finally` handler address from the
try/finally exception record sits in the same gap, inside the same routine, and
passed the old byte-scan test. It should now be rejected, because it is the
target of a `push imm32`, not the address after a call — `X86DecodeTests.
PushImmediate_IsNotACallSite` pins exactly that.

### Traps / hypotheses

- A recovered frame with the RIGHT function but the WRONG line is still a wrong
  frame. The previous attempt produced `RunRtlCallback` at line 81 (`Names.Free`,
  the `finally`) instead of 79 (the call). Assert the LINE, not just the name.
- `build_runner.bat` does NOT rebuild the adapter, and DevTools probes are not
  rebuilt by it either. Rebuild both before trusting any measurement — stale
  binaries produced three wrong conclusions in the previous session, and one
  more in this one: a fix verified working through `LiveSessionProbe` still
  failed in the suite, because `RunTests.exe` links `DebuggerCore` statically
  and only `build_dap.bat` had been re-run.
- Overflow/range checking differs per project: the adapter builds `-$Q+ -$R+`,
  `RunTests.cfg` and the DevTools flags do not. A defect that only exists under
  checking will pass the suite. Pin the directive in the unit source when a unit
  does arithmetic on debuggee-supplied addresses.
- Do not edit `DebuggerTests\TestTarget\*.pas` while the suite is running: the
  runner reads those files at run time to resolve `{BP:...}` markers, and a
  mid-run edit fakes a large regression.
- `for var x in ['a','b']` is fine in a for-in, but `Exit(['a'])` is parsed as a
  set ("Ordinal type required"); use `TArray<string>.Create(...)`.
