# PROJECT_STATE

High-level permanent state of the Delphi Win64 DAP debugger for VS Code.
Transient task cursors live in `TASK_RESUME.md`, not here.

## Architecture status

```
VS Code  ── DAP (JSON over stdio) ──>  VisualStudioCodeDelphiDebugger.exe  ── Win32 Debug API ──>  Debuggee.exe
```

- `VisualStudioCodeDelphiDebugger\VisualStudioCodeDelphiDebugger.dpr`: entry point, message loop.
- `DebuggerCore\DapProtocol.pas`: DAP framing (`Content-Length`), JSON I/O, log file.
- `VisualStudioCodeDelphiDebugger\DapServer.pas`: request dispatcher (launch, breakpoints, stepping,
  stackTrace, variables, evaluate, setVariable).
- **Two frontends over one core.** `DebugSession.pas` (`TDebugSession`) is a
  JSON-free core facade that owns the engine + symbols + `TSourceResolver` +
  a `TDebugSessionState` machine and returns the neutral records in
  `DebugSessionTypes.pas`. Two frontends sit on it: `TDapServer` (VS Code / DAP)
  and `TMcpServer` (`McpServer.pas`, `McpJson.pas`, `McpToolSchemas.pas`) — a
  Model Context Protocol stdio server (`DelphiDebuggerMcp.exe`, `build_mcp.bat`)
  exposing semantic tools to an autonomous agent (Claude Code). `ProcessEnum.pas`
  backs process listing + a pre-attach architecture gate. See `MCP_SERVER.md` and
  the "Two frontends" section of `DAP_DEBUGGER_ARCHITECTURE.md`. Status: the MCP
  frontend covers a monolithic-target vertical slice + most inspection and is the
  first consumer of `TDebugSession`; `TDapServer` is not yet rewritten onto the
  facade (Phase B). Tests: `DebuggerTests\DebugSessionTests.pas` (protocol-free),
  `DebuggerTests\McpE2ETests.pas` (end-to-end over MCP stdio).
- `DebuggerCore\DebugTarget.pas`: target-agnostic
  `IDebugTarget` interface and the shared types (`TStopReason`,
  `TRegisterSnapshot`, `TLocalValue`, `TStackFrame`, `TBreakpointRec`,
  `TBpSpec`, `TCommand`, callback signatures). DapServer + ExprEval
  talk only to `IDebugTarget`; concrete back-ends register themselves
  by implementing it.
- `DebuggerCore\WinDebuggerBase.pas`: Windows debug loop, INT3 plant/remove,
  single-step, thread context hijack for synthetic remote calls,
  StackWalk64-based unwinding. `TWinDebugger = class(TInterfacedObject,
  IDebugTarget)` — lifetime managed by the interface refcount. Architecture
  neutral except for a virtual seam, of which it is also the x64
  implementation.
- `DebuggerCore\WinDebuggerX86.pas`: `TWin32Debugger = class(TWinDebugger)` —
  debugs a 32-bit (WOW64) target from the same 64-bit adapter. Overrides only
  the seam (target layout, stack-walk machine type, WOW64 thread context,
  prologue decode, offset bases, synthetic-call ABI) and inherits the event
  loop, breakpoints, stepping, module handling and the synthetic-call pump.
  The class is chosen in `TDebugSession.BuildAndWireDebugger` from the target
  PE's `IMAGE_FILE_HEADER.Machine`. See "Target architecture" in
  `DAP_DEBUGGER_ARCHITECTURE.md`.
- `DebuggerCore\TargetLayout.pas`: `TTargetLayout` — the DEBUGGEE's pointer
  size, dynamic-array header shape and VMT slot offsets, as a plain data
  record (a virtual call per pointer would shatter bulk reads into syscalls).
  `SizeOf(Pointer)` describes the adapter, not the process being decoded.
- `DebuggerCore\MapFileReader.pas`: parses Delphi `.map`, RVA <-> source line.
  Still used for nested-procedure parent linkage (`_ZZ` mangled publics) and as
  a secondary line/function provider. BPL candidate detection no longer depends on MAP.
- `DebuggerCore\TD32FileReader.pas`: Borland TD32 reader for the `.debug`
  PE section emitted by `dcc64 -V`. Implements ISourceLineProvider + IFunctionNameProvider +
  IGlobalSymbolProvider + ILocalSymbolProvider (last one gated by `ExposeLocals` so RSM keeps
  primacy for variable typing) + IClassMemberProvider + IEnumInfoProvider +
  IMethodSignatureProvider (`TryGetMethodParams`: on-demand decode of a class
  method's declared params via FIELDLIST -> LF_METHOD -> LF_METHODLIST ->
  LF_MFUNCTION -> LF_ARGLIST; used to surface anon-method-body params).
  Now parses the SST_TYPES / SST_GLOBAL_TYPES type tables (LF_POINTER /
  LF_CLASS / LF_STRUCTURE / LF_ENUM / LF_PROCEDURE), so globals and
  locals carry resolved TypeHints (`Globals : TGlobals`) without
  relying on a live VMT or RSM fallback. FIELDLIST sub-record decoding
  is deferred (Borland $0030..$003A leaves; tracked in
  `KNOWN_UNKNOWNS.md`). Registered before MAP in the provider chain.
  Also reads an EXTERNAL `.tds` (dcc64 -VT) via `LoadFromTdsFile` when the exe has
  no embedded `.debug` (second file mapping for the CodeView blob + the companion
  exe's PE section table; `.tds` offsets are ImageBase-biased, handled by
  `SegOffsetToRva`). Stale-gated. See `DEBUG_INFO_FORMATS_TODO.md` (P3, DONE).
  See `TD32_FORMAT_NOTES.md`.
- `DebuggerCore\RsmFileReader.pas`: reverse-engineered Delphi `.rsm`/`.dcp` reader
  for type/local/global metadata (`TRsmFile` parses BOTH formats). NO LONGER
  REQUIRED for a mono exe -- see "RSM is optional" below. Still the reader for a
  BPL's `.dcp` (the package's rich debug info).
- `DebuggerCore\JclDebugReader.pas`: JCL (JEDI Code Library) debug-info provider.
  Reads the MAP-derived symbol table JCL stores as a linked `JCLDEBUG` PE section
  or a sidecar `.jdbg`, via JCL's `TJclBinDebugScanner`. Implements
  ISourceLineProvider + IFunctionNameProvider (address->location + proc name),
  registered BELOW TD32 and ABOVE MAP. No line->address (BP binding stays on
  TD32) and no `_ZZ` nested-proc linkage (JCL drops the mangled EH publics).
  Opt-in via the `JCL_DEBUG` define, DEFAULT ON; `-D JCL_DEBUG_OFF` compiles it
  out with zero JclDebug dependency. See `DEBUG_INFO_FORMATS_TODO.md` (P1, DONE).
- `DebuggerCore\DebugInfoSet.pas` / `DebugInfoTypes.pas`: aggregate debug info
  view consumed by the rest of the adapter.
- `DebuggerCore\DelphiValueReaders.pas`: leaf value
  readers / formatters extracted from `DapServer` to shrink the god-class.
  `TDelphiValueReader` (Variant decode `FormatVariantAt` / `LooksLikeVariantAt`,
  Delphi long-string + null-terminated readers, interface-reference recovery)
  plus standalone `FormatFloatNicely` / `FormatDelphiDateTime` /
  `FormatHexAscii` and the `var*` VType constants. Depends only on
  `IDebugTarget` + `TDelphiRtti`; no callback into `DapServer`. The `Readers`
  getter in `DapServer` creates it lazily and refreshes Debugger/Rtti on each
  access. `FormatLocalValue` / `FormatTyped` / `FormatLocalType` stay in
  `DapServer` (they drive the variables view) and call into this unit.
  Stage 1 of the `DapServer` de-god-classing (4894 → ~4350 lines).
- `Debugme.dpr`: trivial test target. Extended on demand to validate features.
  Never used as ground truth — every feature must work on real Delphi Win64
  binaries.
- `DebuggerTests\`: DUnitX integration test suite. Launches the adapter,
  exercises BPs / locals / step / globals / evaluate.
  Run with `cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_and_run.bat"`.
  Current status: **958 found / 956 pass / 0 fail / 0 leaked / 2 ignored.**
  Attach/detach tests self-skip when SeDebugPrivilege
  isn't held; run elevated to exercise them. The count includes the TD32
  + RSM reader unit tests (`TD32ReaderTests`, `RsmReaderTests`), the
  code-review regression tests (`BugRegressionTests`) and the DAP
  integration surface. NOTE: new test fixtures must be registered in
  their unit's `initialization` (`TDUnitX.RegisterTestFixture`); RTTI
  discovery alone does not see otherwise-unreferenced fixture classes.
  - **Dual-scenario parity (monolithic exe + runtime BPL).** Every DAP
    integration test runs TWICE: `TDebuggerTests` launches the monolithic
    `TestTarget.exe`; its subclass `TDebuggerTestsBpl` (overrides
    `Scenario`->`tsBpl`, registered explicitly) launches `TestHost.exe`, which
    `LoadPackage`s `TestSubject.bpl`. The subject code is compiled ONCE into
    `TestTarget\TestTargetCore.pas` and linked into BOTH the exe and the BPL,
    so the same markers/values exercise both layouts. Tests route their launch
    through the scenario-aware `LaunchTarget` helper (which, under `tsBpl`,
    points at `TestHost.exe` and injects the `TestSubject.bpl` module ahead of
    any extra runtime packages the test loads). Genuinely exe-only cases
    (program-main-block RSM inline locals at `MAIN_*` markers, attach) self-skip
    under `tsBpl` via `SkipIfBpl` / a `StartSession` auto-skip. Build of the
    host+BPL is wired into `build_and_run.bat` via `build_host.bat`.
  - **Win32 coverage (`TWin32RunControlTests`).** `build_target.bat`,
    `build_host.bat` and `build_package.bat` also produce
    `TestTarget\Win32\Debug\` and 32-bit `TestSubject.bpl` / `TestHost.exe`
    from the SAME sources via `dcc32` — a behavioural difference is then the
    debugger's, not the fixture's. The `.cfg` files are not forked: `dcc` reads
    the config first and the command line second and the last `-E` / `-NU` /
    `-LE` / `-LN` wins, so the output is redirected by override rather than by
    a duplicate config that would go stale unnoticed. Deliberately a separate
    fixture, not a bitness subclass of `TDebuggerTests`: most of those tests
    assume features that arrived incrementally, so subclassing would have
    landed a large block of red that communicates nothing. Where a value
    legitimately differs per bitness (`NativeUInt`, addresses) the tests
    compare the SHAPE against the 64-bit control, and assert the difference
    where it is real — with a guard that fails if the member disappears from
    the fixture, so the check cannot go vacuous.
  - **`RUNTESTS_ONLY` env var** filters `RunTests.exe` to tests whose full name
    contains the substring (case-insensitive), for fast iteration on a subset
    instead of the full doubled suite. Inert when unset; full-suite behavior is
    unchanged.

VS Code side:
- `install\local.delphi-win64-debug\package.json`: the single canonical
  extension manifest. Registers the `delphi-win64` debug type, declares the
  full launch-config schema (including `exceptionRules`), and references the
  adapter via the relative path `./VisualStudioCodeDelphiDebugger.exe`. No
  `main` field, so no `extension.js` is required. Installed by
  `install\Install.exe`, which packages it into a `.vsix` and installs via
  `code --install-extension` (required on VS Code 1.96+; folder copy is no
  longer loaded), or `install-dev.bat` (points at build output).

IDE integration:
- `C:\Athens\sharedlibraries\shareddesign\IdeHooks\DGVisualStudioCodeIntegration.pas`
  (a separate proprietary repository on the maintainer's machine, not present in
  a fresh clone of this project):
  Delphi IDE plugin (installed via `IdeHooksD26/D28/D29.dpk`) that adds an
  "Open in Visual Studio Code" action (Ctrl+\) to the Tools menu.
  On trigger: saves all modules, generates/updates the `.code-workspace` (or
  `.vscode/settings.json` for folder mode), writes `launch.json` and
  `tasks.json`, then opens VS Code reusing an existing window for the same
  workspace or opening a new one.
  Generated `launch.json` config fields for `.dpr` projects:
  `type: delphi-win64`, `program`, `mapFile`, `rsmFile`, `sourceRoot`,
  `sourceSearchPaths` (collected from project DCC_UnitSearchPath + global
  Win64 registry library paths). For `.dpk` packages: adds `modules:
  [{name, map}]` and uses the configured host application as `program`.
  `sourceSearchPaths` always starts with `${env:BDS}/source`.

## What works in which configuration

`WHAT_WORKS_WHERE.md` is the per-configuration matrix: monolithic exe vs.
package host, crossed with x64 vs. x86, with every cell either measured or
explicitly left blank. Read it before answering "does the debugger support X" —
the answer usually depends on the configuration, and more often on whether the
module you are standing in carries debug information at all.

## Implemented features

Target architecture:
- **Win32 (32-bit / WOW64) targets — SHIPPED.** One 64-bit adapter binary
  debugs both bitnesses; a 64-bit process can debug a 32-bit one, and the
  reverse is impossible. Working on a 32-bit target and verified against the
  64-bit control: launch, breakpoint binding and firing (including deferred
  binding into a not-yet-loaded package), stepping (into / over), stack unwind
  past recursion with demangled Pascal names and source lines, locals and
  parameters, object expansion (fields, strings, nil references), expression
  evaluation including getter-backed properties (which means the debugger
  hijacks the stopped thread and runs code in the debuggee), and the multi-BPL
  case — a breakpoint inside a runtime package, unwinding across the module
  boundary into the host.
  Synthetic calls return the full float family (`Single`, `Double`, `Real`,
  `Extended`, `TDateTime`, `Currency`) and `Int64` correctly: results come off
  the x87 stack via an `fnsave` capture stub, and out of EDX:EAX for 64-bit
  integers. Variables of the float types that do not fit the 8-byte value slot
  read correctly too — `Extended` (10 bytes of x87 on Win32), `Extended80`
  (10 on both) and the pre-8087 `Real48` (6 on both).
  Synthetic calls also PASS every argument class correctly: Delphi's 32-bit
  `register` convention gives a register slot only to a non-float that fits 32
  bits, and puts everything else on the stack at 4, 8 or 12 bytes without
  consuming a slot.
  The x86 stack walk holds up in the two places a saved-EBP chain cannot
  answer on its own, and in both the answer is PROVEN rather than guessed, by
  decoding instruction lengths forward from a known boundary
  (`DebuggerCore\X86Decode.pas`, validated over 70 476 spans of production
  32-bit Delphi code with zero unknown opcodes): stopping inside a prologue,
  where the frame is not established yet and a constructor's preamble makes
  that ordinary; and a FRAMELESS routine between two framed ones, which hides
  its caller from the chain entirely. Constructors are named from the MAP,
  because dcc32 records no declared name for them.
  An interface local is labelled with the CONCRETE class behind it on both
  bitnesses, by decoding the IMT adjustor thunk — three reads at addresses the
  reference itself supplies, no search. The dcc32 encodings were measured
  (`DevTools\Win32ImtThunkProbe.dpr`), not inferred from the x64 ones.
  A nested procedure sees its enclosing routine's variables by bare name, as
  Delphi's lexical scoping says it should. That needed CodeView's `pParent`
  back-pointer: dcc32 emits every proc at top level in the symbol stream and a
  flat `Unit.Inner` in the MAP, so `pParent` is the only record that the two
  routines are related at all (`TD32_FORMAT_NOTES.md`).
- **Limitation:** Win32 locals and parameters are supported for `-$O-` builds
  only; `-$O+` omits the frame pointer routinely. Separately, and on both
  architectures, a synthetic call's argument types come from the calling
  expression rather than the callee's declared parameters, which the debug info
  does not surface. See `KNOWN_UNKNOWNS.md`.

Stepping / control:
- Launch with `DEBUG_ONLY_THIS_PROCESS`, optional `stopAtEntry`.
- Launch (CreateProcess + DEBUG_ONLY_THIS_PROCESS, hidden console) and
  Attach (DebugActiveProcess, requires SeDebugPrivilege; auto-elevation
  via AdjustTokenPrivileges if available). Disconnect mode configurable
  via launch.json `killOnDetach` (default False for attach,
  always-true for launch).
- Architecture check at CREATE_PROCESS_DEBUG_EVENT: the target's image machine
  is read via `IsWow64Process2` (fallback `IsWow64Process`). It predates Win32
  support and is now only meaningful as an assertion that the live process
  agrees with the class chosen from the on-disk PE header — the debugger class
  itself is selected earlier, in `TDebugSession.BuildAndWireDebugger`, because
  `IsWow64Process2` cannot answer until the process exists. **Stale:** the
  advisory `[FATAL]` text it prints
  (`WarnIfUnsupportedTargetArchitecture` in `WinDebuggerBase.pas`) still says a
  32-bit target is unsupported and its stacks will not resolve, which is no
  longer true. Nothing depends on the message; it should be rewritten or
  dropped.
- Source-line breakpoints from VS Code gutter, accurate verification state.
- Step over (F10), step into (F11, walks until next source line),
  step out (Shift+F11, uses `StackWalk64` for caller resume RIP).
- Continue (F5), pause (via `DebugBreakProcess` injected breakpoint).
- First-chance exception break with correct `DBG_EXCEPTION_NOT_HANDLED` passthrough.
- Exception filter UI (DAP `setExceptionBreakpoints`): four toggles
  surfaced in VS Code's BREAKPOINTS view — `delphi` (first-chance
  Delphi raises), `av` (first-chance access violations), `all` (every
  first-chance), `unhandled` (second-chance, force-on). Defaults match
  the legacy hardcoded behaviour.
- Per-class refinement of the `delphi` filter via the standard DAP
  `filterOptions` `condition` field: comma- or semicolon-separated
  class-name list (e.g. `EAccessViolation, EConvertError`); empty =
  every Delphi raise. The raised class name is read from the
  TypeInfo Kind+ShortString stored at VMT[-168] (Athens 36 layout —
  see `DelphiRtti.pas` for the full table).
- Set Next Statement via DAP `gotoTargets`/`goto`.

Symbol / source resolution:
- TD32 + MAP based RVA <-> line. TD32 is the primary provider, parsing
  the `.debug` PE section (SOURCE_MODULE / ALIGN_SYMBOLS / GLOBAL_SYMBOLS
  / NAMES subsections). MAP remains required for nested-proc parent linkage
  (`_ZZ` path) used by outer-scope locals in nested frames.
- Itanium-style demangler converts `dcc64`-emitted names (e.g.
  `_ZN10Testtarget7TWidget11DoCalcInt64Ev`) into MAP-style
  `Class.Method` strings, with special-case rewrites for
  `initialization`/`finalization` synthetic procedures (mapped to the
  unit name, which is the key RSM uses for main-block locals).
- ASLR: actual `ImageBase` from `CREATE_PROCESS_DEBUG_INFO` vs preferred base.
- Delphi RTL/VCL source resolution via `sourceSearchPaths` config and the
  `BDS` env var. No hardcoded Delphi install paths.
- Background symbol PREFETCH -- BUILT BUT DISABLED BY DEFAULT
  (`SetSymbolPrefetchEnabled` / `SYMBOL_PREFETCH=1`; see TASK_RESUME for why).
  (`TSymbolPrefetcher` in
  `DebuggerCore\ModuleSymbolLoader.pas`, shared by both frontends). A module's
  readers are built on a worker thread at its LOAD_DLL event and registered on
  the dispatch thread at the next stop, instead of being parsed synchronously by
  the first stop that needs them (98-652 ms per real BPL, TD32 being 68-71% of
  it). Single load path: a module is claimed before the worker starts, the
  dispatch thread steals a still-queued request back rather than waiting for it,
  and no `EnsureModule*` ever parses a claimed module. Provider registration
  stays single-threaded, so `TDebugInfoSet` still needs no lock. Design rules
  and the reason behind each are in `DAP_DEBUGGER_ARCHITECTURE.md` -> "Symbol
  prefetcher". `NO_SYMBOL_PREFETCH=1` restores the purely lazy behaviour.
- DAP emits `invalidated(stacks)` when prefetched symbols register while
  stopped, so a stack drawn with nameless frames refills without user action.

Variable inspection (RSM-driven):
- Local variables for the current procedure.
- Parent-procedure locals visible from inside nested procedures (walks
  scope chain to arbitrary depth).
- Locals declared in the program's main `begin..end` block (variant `$46`
  marker, attached to the proc named after the ExePath basename).
- Global variables with decoded `typeId`.
- Registers scope.
- Type-aware formatting: integers, floats, `TDateTime`, chars, ANSI/Unicode
  strings, Variants, C-string pointers, char literals, Delphi aliases.
- Dynamic-array locals render in Pascal `[...]` notation: an empty (nil)
  array shows `[]` (not `0  (0x0)`), a live one previews its elements
  (`[10, 20, 30]`, capped) instead of surfacing the raw data pointer as a
  giant integer. TD32 flattens `array of T` / `TArray<T>` to `^T`; the
  formatter validates the dyn-array header (len at ptr-8, refcount at
  ptr-12) before treating a `^T` body local as an array, so a genuine
  typed pointer still formats normally. Restricted to body locals
  (`lkLocal`); `^Char` families stay string pointers.

Variable expansion (RTTI-driven, `DelphiRtti.pas`):
- Class instance field expansion (all visibility levels, all ancestor classes)
  via VMT extended RTTI (`TFieldExEntry` records). Validated on `TFoo`.
- Record field expansion via TypeInfo `tkRecord`/`tkMRecord` field table.
- Dynamic-array element enumeration (up to 512 elements).
- Nested expansion: each expandable field gets its own `variablesReference`.

Class-member resolution (RSM-driven, `RsmFileReader.ParseClassMemberSection`):
- Parses `$2C` field, `$2E` method, `$2F` constructor, `$31` property records.
- Groups members by class via the trailing `08 <classHash> FF` block and the
  16-bit hash from the matching `$2A` class declaration.
- Property → accessor binding by 16-bit hash matching: property's
  `getterHash16` (after `$80`) ↔ field's `9C 09 hash16` or method's
  `E2 bodyHash16`.
- `ExprEval.ApplyDot` consults the RSM member table when TPropInfo /
  extended RTTI miss (covers `{$M-}` classes, private/public unpublished
  members, default-array indexed properties).

Evaluate / watch:
- Qualified identifiers (e.g. `Increment.d1`).
- Registers, address-of, memory dereference, literals.
- Pascal grammar with full precedence: `or` / `xor` < `and` < comparison
  (`=` `<>` `<` `<=` `>` `>=`) < add (`+` `-`) < mul (`*` `/` `div` `mod`
  `shl` `shr`) < unary (`-` `not` `@` `[]`) < primary.
- Mixed int / float arithmetic auto-promotes to Double; `/` always yields
  Double like Pascal source.
- String concat with `+` allocates a new immortal Delphi string in the
  debuggee.
- Boolean ops `and` / `or` / `xor` / `not` are logical for Boolean
  operands and bitwise for integer operands.
- Sub-8-byte primitives are sign-/zero-extended via `MaskByType` before
  arithmetic and comparison so `Integer` / `Boolean` / module enums
  behave as in source. Module enums consult `LookupEnumInfo` at
  comparison time to mask to their actual storage width.
- Pascal keyword literals: `True`, `False`, `nil` (recognised before
  generic identifier resolution).
- Bare enum values: `wmPaused`-style identifiers resolve through
  `IEnumInfoProvider.TryResolveEnumLiteral` when they don't match any
  local / global, so `Mode = wmPaused` works without a type qualifier.
- Type casts: `Integer(x)`, `Double(42)`, `Cardinal(p)`, etc.
  Numeric→numeric is a bit-reinterpret with width masking; int↔float
  converts. Class casts (`TFoo(p)`, `TObject(obj)`) preserve the
  pointer and stamp the new TypeHint; recognised module-class names
  resolve through `IClassMemberProvider.GetClassMembers`.
- `is` / `as` operators (RTTI-driven): walk the VMT/TypeInfo parent
  chain to compare class names. `is TObject` short-circuits True for
  any class instance. `as` failure surfaces as an error string in the
  watch (no debuggee crash, no silent pass-through).
- Built-in intrinsics: `Length(s | dynarray)`, `SizeOf(type)`,
  `Ord(enum)`, `Low(t)` / `High(t)` for ordinals / enums / arrays /
  strings.
- Set algebra on set operands: `+` union, `-` difference, `*`
  intersection (bitmask ops; `TExprValue.IsSet` routes them).
- Open-array parameter indexing: a `^Element` base (how `array of T`
  params are typed) is indexed as a direct pointer — no dyn-array length
  header, no up-front bounds. `TExprValue.DerefPtr` makes a var/ref-param
  base index through its pointer (Address), not the pointee.
- Method calls with side effects execute in the debuggee and the mutation
  persists across subsequent evaluations.
- A watch/hover that invokes a method which RAISES (or AVs) is aborted
  cleanly: `RunMethodCall` restores the pre-call context and returns
  failure on a Delphi raise / AV / second-chance during the synthetic
  call, so the watch shows an error instead of hanging the adapter.
  `RunRemoteCallEx` (TPropInfo property-getter path, @UStrAsg writes)
  delegates to `RunMethodCall`, so getters get the same abort + the
  EXIT_PROCESS handling (an AV in a getter used to livelock the event
  pump forever). Synthetic calls are REFUSED while stopped on an
  exception: consuming the pending event with DBG_CONTINUE swallowed the
  raise and corrupted the continue status of the trap event.
- A planted breakpoint (user BP or transient step BP) hit INSIDE the
  callee of a synthetic call is skipped transparently: restore byte,
  rewind RIP, single-step, re-plant, keep pumping (per-thread pending-skip
  map; skips still in flight when the pump exits are re-planted, the
  thread's RIP is still at the BP so nothing is lost). No nested stop is
  surfaced and HitCount is untouched. The BP keeps firing on normal
  execution afterwards.
- Deref of unmapped memory returns a graceful read-failure result; the
  session stays alive.
- Type names usable as values (no value, just TypeHint+Size). Drives
  `SizeOf(Integer)` / `Low(TWorkMode)`-style intrinsic calls.
- `evaluateForHovers` capability advertised; hover context handled
  identically to repl/watch.

Breakpoint kinds:
- Source-line BPs (always-on or conditional).
- Conditional BPs (DAP `condition`): expression evaluated at hit; non-zero =
  stop, zero / eval-failure = silent continue.
- Hit-count BPs (DAP `hitCondition`): supports `N`, `=N`, `>N`, `>=N`, `%N`.
- Log-points (DAP `logMessage`): never stops; emits `output` event with
  `{expr}` placeholders rendered through the same evaluator. `{{` / `}}`
  escape to literal braces.

setVariable:
- Primitives, floats, dates, chars, sized integer writes.
- Enum-by-name (`Gap := geC`): resolved type-scoped via
  `LookupEnumInfo(TypeHint)` (ordinal = MinValue + index in Names, so
  gapped enums map correctly); width from a type provider else Delphi
  default packing. A literal from an unrelated enum is rejected.
- Enum-by-ordinal (`Gap := 2`) and set-by-bitmask (`Modes := 6`): encoded
  at the type's true storage width (provider size, else Delphi default
  packing from the highest member ordinal; unknown width = write REFUSED).
  Enums are range-checked against MinValue..MaxValue; set bitmasks must
  fit the slot. These encoders run BEFORE the generic unknown-type
  fallback, which writes 8 bytes and used to clobber the fields following
  a 1/2-byte enum/set slot.
- Strings via in-process `@UStrAsg` / `@LStrAsg` (no refcount leak).
  Synthetic remote call hijacks the stopped thread, clears TF, aligns RSP.
- `var` parameters: dereferences `V.RawValue` so the caller's storage is
  modified, not the parameter slot.
- Invalid writes (type mismatch) return DAP `success:false` with an error
  message; the session is unaffected.

Call stack:
- `StackWalk64` with `SymInitialize(invade=True)` for `.pdata` unwind. The
  invade sweep sees only the modules mapped when it runs, so every later
  `LOAD_DLL` is registered with `SymLoadModuleExW` and every `UNLOAD_DLL` with
  `SymUnloadModule64` — without that, a runtime-loaded BPL has no unwind info
  and the walk collapses to a single frame (see DAP_DEBUGGER_ARCHITECTURE.md).
- Function names per frame, source line per frame when available.
- Caller frames (every frame but frame 0) are symbolicated at the return
  address MINUS 1, so the reported line/function is the call site rather than
  the instruction after it (an `Assert` call no longer reports the next line).
  Guarded against `VAToRva` returning 0 for frames outside known modules
  (overflow checks are on).
- Per-thread call stacks: `GetStackFrames(TID)` walks any thread read-only
  (the whole process is frozen at a stop), and `HandleStackTrace` honors the
  DAP `threadId`. Selecting a thread shows its own stack; its frames' locals
  and watches resolve from the frame RBP.
- Per-thread STEPPING / run control: step over/into/out act on the
  DAP/MCP-selected thread (`TCommand.ThreadId`; 0 = the stopped thread). While a
  step runs, every OTHER thread is `SuspendThread`-frozen so only the stepped
  thread advances -- the Win32 debug API resumes all threads on
  `ContinueDebugEvent`, but an explicit suspend survives the continue, so the
  others stay frozen until the next reported stop thaws them (single choke point:
  `ReportStopped`). Threads created mid-step are frozen too; the freeze set is
  kept consistent across thread exit, and if the stepped thread itself exits
  mid-step everything is thawed to avoid an all-frozen deadlock. The persistent-
  BP re-arm is gated on the owning thread (`FReactivateTid`) so stepping a
  different thread neither consumes nor loses another thread's pending re-arm,
  and a second thread hitting the same BP VA is a genuine hit, not a swallowed
  re-arm. After the step, run control targets the stepped thread (the single-step
  handler makes it `FStoppedTid`). Inherent limit (as in VS Code): if the stepped
  thread blocks on a lock held by a frozen thread, the step cannot complete.
  Covered by `DebugSessionTests.PerThreadStep_StepsOnlySelectedThread` (two
  spinner threads; stepping one advances only its counter, the other stays put).
- On an exception stop the leading RTL raise-plumbing frames (no locally
  resolvable source: `@RaiseExcept` / `@Assert` / `AssertErrorHandler` / ...)
  are trimmed so the call stack starts at the raise/assert site in user code.
  `TDapServer.TrimRaisePlumbingFrames`, gated by `FStoppedOnException`; keeps
  `FLastFrames` aligned so frameId→frame mapping for scopes/evaluate stays
  correct. Falls back to the full stack when no frame is navigable.

## Real-world production test target

`C:\Athens\sample_app\SampleAppSingleExe.dpr` — a large monolithic Delphi Win64 application.

Debug symbol file sizes (as of 2026-05-11):
- `Win64\Debug\SampleAppSingleExe.rsm` — **780.7 MB**
- `Win64\Debug\SampleAppSingleExe.map` — **353.2 MB**
- `Win64\Debug\SampleApp.rsm` — 2.2 MB (separate BPL or library RSM)

This is the primary scale stress test. Any feature that works on `Debugme`
must also work here. Known implications:
- RSM and MAP must **never** be fully loaded into memory eagerly at launch.
  Lazy/on-demand loading per-module is mandatory at this scale.
- Symbol lookup and source-line resolution must stay fast despite file size.
- Startup time (adapter launch to first BP hit) is a visible UX metric here.
- The adapter's working set at idle must remain reasonable.

The lazy MAP scan (`perf: skip DLL MAP load via fast text scan before full parse`)
and lazy RSM loading (`feat: lazy multi-module DLL/BPL debug symbol loading`)
were introduced specifically to handle this scale.

### Per-unit and per-binary symbol-type resolution

RSM TypeIds are **per-unit**, not global, so a symbol's type must be resolved
against its OWNING unit's import list (`ResolveTypeIdInUnit` / `OwningUnitContext`
in `RsmFileReader.pas`) before the global `FTypeIdToName` map (which collides
across units on big multi-unit binaries). This is applied uniformly to class
members, locals, unit/program globals and main-block locals. On the global map a
Variant local once mis-resolved to `Word` (SampleApp frmMainMdiU `v`).

Each binary (main exe + each BPL/DLL) has its OWN reader instance
(`TTD32FileReader`/`TRsmFile`) with its own unit tables, so resolution is
per-binary correct. TD32 routes locals by per-binary RVA (shifted keys). The RSM
by-name locals fallback (RSM has no RVA index) is routed to the binary that OWNS
the frame RVA via `TDebugInfoSet.AddProviderForModule` + the RVA-range check in
`GetLocalsForFunctionByRva`, so a same-named proc in another BPL cannot win the
cross-provider merge. The cross-UNIT same-binary by-name collision remains bounded
by RSM's name-keyed format (see `KNOWN_UNKNOWNS.md`).

## Open milestones (roadmap)

Debugger features:
- **Debug-info format coverage.** JCL debug info (`.jdbg` / linked `JCLDEBUG`
  section) — DONE (`JclDebugReader.pas`, registered below TD32 / above MAP; opt-in
  `JCL_DEBUG` define, default ON). Verified it does NOT carry the `_ZZ` nested-proc
  linkage (JCL drops the mangled EH publics), so the SampleApp outer-scope-locals gap
  is unchanged; JCL is a MAP-equivalent line/proc fallback for TD32/MAP-less
  modules. Remaining: DCU debug info, `.dcp`-linked (likely already covered), and
  external `.tds`. Full plan + decisions in `DEBUG_INFO_FORMATS_TODO.md`.
- PE import-table reader so MAP can be dropped entirely.
- Child process tracking.
- Disassembly view (DAP `disassemble`).
- Win32 (32-bit) targets — **DONE**. Run control, locals, object expansion,
  evaluation and the multi-BPL case all work on a WOW64 target from the same
  64-bit adapter binary. See "Target architecture" under Implemented features
  and in `DAP_DEBUGGER_ARCHITECTURE.md`; what is still open (x86 float / Int64
  synthetic-call results, `-$O+` locals, Win32 TLS segment bases) is in
  `KNOWN_UNKNOWNS.md`.
- Per-thread STEPPING / run-control — **DONE** (step over/into/out target the
  DAP/MCP-selected thread; read-only per-thread inspection was already done).
  Synthetic-call evaluation still targets `FStoppedTid` (frame-independent, so
  it does not need per-thread targeting). See "Per-thread stepping" under
  Implemented features and `DAP_DEBUGGER_ARCHITECTURE.md`.

Variable / type system:
- Generics: `TList<T>` / `TDictionary<K,V>` / nested generics already inspect +
  enumerate (tests `Test_Types_GenericList_*`, `Test_E2_*`). No known generic gap.
- **Anonymous methods / closure capture frames — DONE** (increments A, B1a, B1b,
  and anon-method params; all un-gated, mono/BPL/NO_RSM green). Expanding a live
  closure value shows its captured fields; stopping inside the anon body shows the
  captured vars AND the anon method's own declared params (`arg1`..`argN`). See the
  closure increments below and "Variable inspection" above. Reverse-engineering
  findings kept for reference:
  * An anon method value is a REFCOUNTED interface (`Invoke` + IInterface). The
    captured state lives in a compiler-generated `…$ActRec` class instance.
  * OBJECT RECOVERY: the local holds an interface pointer that points INTO the
    object (at the interface field), not at its header. `object = interfaceRef - K`
    (K=24 in the probe); recover by scanning `interfaceRef - K*8`, K=0..8, and
    validating the candidate VMT (readable ClassName ShortString, sane InstanceSize).
  * FIELD NAMES ARE NOT IN RUNTIME RTTI: `$ActRec` has `VMT[-160]=nil` (no extended
    field table), so DelphiRtti's VMT field enumeration finds nothing -- closure
    expansion must be DEBUG-INFO-driven (GetClassMembers on the `…$ActRec` class).
  * DEBUG INFO HAS IT EVERYWHERE (corrected): the captured field names/offsets are in
    the embedded TD32 (exe AND bpl) and the `.rsm`; TD32 already DECODES the class
    FIELDLIST. The only catch was a NAME-KEY mismatch: TD32 keys the class in the
    Itanium-mangled `_ActRec` form while the runtime VMT ClassName + RSM use the source
    `$ActRec` form. Fixed: `TTD32FileReader.GetClassMembers` retries `$`->`_`. So this
    is NOT RSM-format-only -- it works from TD32 (BPL + NO_RSM) too.
  * INCREMENT A -- DONE (2026-07-18). A live `reference to procedure/function` local
    is now EXPANDABLE: `TVariableExpander.TryRecoverClosureObject` recovers the
    `$ActRec` object (scan `interfaceRef - K*8`, VMT-validate, accept only a class
    whose name contains `$ActRec` with debug-info members), then mints an
    `exRsmMembers` expansion so the captured fields render from
    `GetClassMembers($ActRec)`. WORKS IN EVERY SCENARIO (mono / BPL / NO_RSM): TD32
    decodes the `$ActRec` FIELDLIST and `GetClassMembers` retries `$`->`_`
    (commit `d7c2324`), so the captured members come from TD32, not only the mono
    `.rsm`. Test `Test_Closure_ExpandsCapturedFields` (un-gated, all scenarios).
  * INCREMENT B -- still open, DEEP; FULLY CHARACTERIZED 2026-07-18. Stopped INSIDE
    the anon body (`CLOSURE_BODY`, line 453 -> RVA $15DE10), the frame mis-resolves and
    yields ZERO locals. Where the anon-body proc (`RunClosureSampler$ActRec.$0$Body`) is
    (and isn't), verified with a raw ALIGN_SYMBOLS dump + reader probes:
      - TD32 `.debug`: NO proc symbol for the anon body at all (the only ClosureSampler
        record is the OUTER proc $0204 at $15DE60). It has the LINE (453->$15DE10) from
        SOURCE_MODULE but no GPROC/LPROC, so RvaToFunctionName / GetLocalsForFunctionByRva
        return nothing. (Not the `Friendly=''` skip -- forcing raw names in changed the
        proc count by 0.)
      - MAP: also returns (none) for RvaToFunctionName($15DE10), but HAS the line AND the
        `$pdata$_ZN...RunClosureSampler_ActRec7_0_Body` mangled symbol -- the same shape
        MapFileReader already correlates for `_ZZ$pdata$` nested procs (FRvaToParent).
      - RSM/DCP: HAS the proc name `RunClosureSampler$ActRec.$0$Body` and its locals, but
        no RVA index (no line table), so it can't do RVA->proc by itself.
    B1a -- FRAME RESOLUTION: DONE (2026-07-18). It turned out the MAP already has a
    PLAIN code public `TestTargetCore.RunClosureSampler$ActRec.$0$Body` at the anon
    body's start RVA -- `MapFileReader` was just DROPPING every `$`-containing public
    (a too-broad `$pdata$`/`$unwind$` skip). Narrowed the skip to only `$pdata$` /
    `$unwind$`; now RvaToFunctionName($15DE10) -> `RunClosureSampler$ActRec.$0$Body`
    (was clamping to a neighbouring `TList<>`). No .pdata parsing needed after all.
    Suite still 819/817/0/0/2.
    B1b -- CAPTURED VARS INSIDE THE BODY: DONE (2026-07-18). No provider carries the
    anon proc's stack locals (TD32 has no proc symbol -> no BPREL32; RSM returns none
    for `RunClosureSampler$ActRec.$0$Body`), so `TDebugSession.GetLocals` now, when the
    frame is an anon body (`IsAnonBodyFunc`), locates the hidden Self via
    `TryFindClosureSelf` (scan the param registers + an RBP/RSP window for a VMT-valid
    object whose class contains `$ActRec` with debug-info members) and surfaces its
    captured fields as locals (read at Self+offset, formatted through LocalToSession).
    So stopped inside a closure the captured vars appear as locals (CapInt/CapStr).
    Works in EVERY scenario (mono / NO_RSM / BPL). Test
    `Test_Closure_CapturedVarsVisibleInBody`. The BPL case needed the module MAP
    to be RANGE-SCOPED: `EnsureModuleMap` now registers it via `AddModuleProvider`
    (was flat `AddProvider`), so the anon-body frame name -- which only the MAP has --
    falls through the ranged BPL-TD32 (owned-but-none) instead of being blocked.
  * ANON-METHOD PARAMS -- DONE (2026-07-19). The anon body's OWN declared params
    (e.g. `procedure(X: Integer)`, invoked `Clo(7)`) are now surfaced. No local/param
    provider carries their stack slots (the anon body frame has no BPREL/local
    record), but the method SIGNATURE does: new TD32 method-signature decoder
    (`IMethodSignatureProvider.TryGetMethodParams`) walks the class FIELDLIST
    LF_METHOD -> LF_METHODLIST -> LF_MFUNCTION -> LF_ARGLIST on demand
    (Borland ARGLIST = count(u16) + count*type(u32); methodlist entry = attr(2)+
    mfunction(4)). `TDebugSession.AppendAnonMethodParams` maps each declared param
    to its Win64 ABI home slot via `IDebugTarget.CurrentFrameParamHomeAddr`
    (RBP + subRspN + extraPush + 16 + 8*abiIndex; Self is slot 0, declared params
    start at slot 1) and reads the value. Names are unavailable (a CV ARGLIST is a
    bare type list) so params surface positionally as `arg1`..`argN`. General +
    ABI-correct (no hardcoding); works mono / BPL / NO_RSM. VERIFIED across 8
    signatures (`RunClosureParamSampler`, markers `CLOP_*`, tests
    `Test_ClosureParam_*`): 2 ints, string, **Double (XMM spilled to the home slot
    correctly)**, Int64, Boolean, **object (displays `$addr (TWidget)` + expandable**
    -- `GetTypeName` resolves the pointer-to-class param to the class), mixed
    int/string/float/bool (positional slot mapping), and **6 ints (args 5-6 spill
    past the 4-slot register home area onto the stack -- the positional formula still
    resolves them)**. Verified with a one-off closure-parameter probe (findings recorded
    here; the probe itself was not retained). A per-param try/except
    guard keeps one bad param from dropping the other locals. Limits: values masked
    by type width; a `var`/`const` scalar param shows the passed pointer, not the
    pointee; params surface only for a CAPTURING closure (a non-capturing lambda has
    no `$ActRec` Self to anchor from); assumes the standard Delphi prologue (the same
    assumption the whole local readout makes -- and we never debug optimised targets).
  * TryFindClosureSelf STALE-OBJECT FIX (2026-07-19). The closure Self was located
    by a blind register/stack scan for any VMT-valid `$ActRec`; with more than one
    closure fixture live it could latch onto a STALE `$ActRec` pointer left on the
    stack by an earlier closure -> wrong class -> wrong/absent methods. Now Self is
    read DIRECTLY from its Win64 ABI home slot (`CurrentFrameParamHomeAddr(0)` --
    Self is param 0), which is exact; the scan remains only as a fallback. Surfaced
    by the multi-signature param fixture (the string/mixed closures picked up the
    earlier `RunClosureSampler$ActRec`).
  * FIXTURE CAVEAT (learned the hard way): adding a CAPTURING closure INSIDE an
    existing proc (`RunTypeSampler`) broke 26 of its own `TYPES_BODY` local-inspection
    tests -- capturing a variable relocates the outer proc's frame layout, so its
    other locals no longer resolve at the expected RBP offsets. The closure fixture
    MUST live in its OWN dedicated proc. Reverted for now; re-add in a separate proc
    when implementing.
    Proven by one-off probes: an in-process closure-layout dumper plus a closure
    inspection probe driven through the adapter (findings above are the retained record).

Evaluate / expression grammar:
- All Pascal syntax wired and tested: array / string indexing, method
  calls, free-procedure / function calls, property access, comparison
  / arithmetic / boolean ops, string concat, enum literals + `[a, b]`
  set literals, `True` / `False` / `nil`, sub-8-byte type masking,
  type casts (primitive + class), `is` / `as`, `Length` / `SizeOf` /
  `Ord` / `Low` / `High` intrinsics. Return-type ABI dispatch is
  driven by reading the function's `Result` local out of the RSM
  `$28` record (var-out functions tag `Result` as `$23` instead of
  `$20`).

Project / packaging:
- Publish the VS Code extension instead of manual local install.

Rich VS Code GUI extension (future):
- Today the extension is a pure debug-type contribution: no `main`, no
  `extension.js`, just the `delphi-win64` launch-config schema pointing
  at the external DAP adapter. Standard DAP UI only.
- Goal: add a real activated extension (TS/JS with `main` +
  `activationEvents`) alongside the adapter to surface Delphi-specific
  views the standard debug UI cannot show.
- Bridge: the adapter already speaks DAP. Add custom DAP events/requests
  (e.g. `event: "delphiModulesChanged"`) that the extension consumes via
  `registerDebugAdapterTrackerFactory`, then renders.
- Candidate views: loaded modules / BPL map, RSM + TD32 symbol/type
  explorer, memory hex viewer, register grid, thread/stack dashboard,
  richer watch tables, inline value decorations.
- Build order: start cheap — one TreeView (`contributes.views`) fed by a
  custom modules/BPL DAP event. Proves the adapter↔extension custom-message
  channel before committing to webview complexity. Escalate to webview
  panels only where native TreeViews fall short.
- Cost: adds a real TS/JS build step, webview message protocol, and
  ongoing maintenance. Defer until core inspection (locals / globals /
  BPL frames) is solid.
- Related: ties into the status-bar / progress-cue UI-feedback item.

Diagnostic logging:
- `%TEMP%\dap_adapter.log` is opt-in via `"diagnosticLog": true` in
  launch.json (or env var `DAP_LOG=1`). Default: off.

Architecture / portability:
- **`IDebugTarget` abstraction** — DONE. Lives in `DebugTarget.pas`.
  `DapServer.FDebugger` and `TExprEvaluator.FDebugger` are typed as
  `IDebugTarget`; `TWinDebugger` is the only implementation today.
  Win32 / Windows-ARM (or attach-mode, remote, …) implementations
  plug in without touching the DAP layer or evaluator.

## Important technical discoveries

- **Host and target pointer size are not the same thing (2026-07-25).** On x64
  they coincide, so every site that conflates them is correct *by accident*.
  Pointing the debugger at a different bitness found three such sites that
  nothing else would have: the `$ActRec` closure scan and the `Self` stack scan
  strode target memory by the host's `SizeOf(Pointer)`; `LocalReadSize` returned
  8 for everything "pointer-sized or unknown"; and `ExprEval`'s own read path
  (`PrimTypeSize` / `SizeForKind`) did the same, independently, so a string
  handle read 8 bytes and rendered as a read failure. The failure mode is
  consistent and nasty: the neighbouring slot is spliced into the high half and
  the result is a *plausible* wrong value, not an error. The width rule now
  lives in one place, `LocalReadSize` in `DelphiValueReaders`, and the strides
  come from `TTargetLayout`.
- **Three latent x64 defects found while building Win32 support (2026-07-25),
  all independent of it:**
  1. The byte-pattern prologue matcher was blind to the x64 stack-probe loop
     emitted for frames larger than a page (`push rbp` then `B8 <size>`, not
     `sub rsp`), so it reported frame size 0. Measured with
     `DevTools\PrologProbe.exe`: a routine whose real frame is 16464 bytes read
     as 0, and its locals then resolved 16408 bytes below the frame. Masked in
     practice because the `.pdata` strategy normally answers first — but it
     breaks for any module without unwind data.
  2. An unrecognised prologue was indistinguishable from a zero-byte frame.
     `ReadPrologInfo` now reports whether the prologue was understood and all
     four callers refuse rather than guess (a pure-`asm` routine can be
     frameless while debug info still lists its parameters, and the RTL is full
     of them). See "Local variable readout" in `DAP_DEBUGGER_ARCHITECTURE.md`.
  3. `ReadPEPreferredBase` rejected any image that was not PE32+ and fell back
     to a hardcoded `$400000`. PE32 keeps `ImageBase` at a different offset
     (optional header `+$1C`) and a different width (4 bytes), so a PE32 module
     with a non-default preferred base had every segment base corrupted — and a
     runtime BPL is exactly where that arises.
- **Win32 tooling, kept as stable probes** (`DevTools\`, argv-driven, documented
  in `DevTools\README.md`). Each derives its constants by searching with an
  identity predicate the compiler can verify, and the ones that measure layout
  are compiled with both `dcc32` and `dcc64` so the `dcc64` column must
  reproduce the values already in the shipping code before the `dcc32` column is
  trusted — no 32-bit constant is a scaled 64-bit one.
  - `VmtProbe` — VMT metadata slot offsets by identity predicate.
  - `PrologProbe` — prologue shapes across 17 deliberately shaped routines, with
    the return-address slot located at run time so a wrong decoder shows up as a
    mismatch instead of a plausible number. Carries a verbatim copy of the
    shipping x64 matcher, updated in step, or it stops being evidence.
  - `Wow64StackProbe` — launches a 32-bit target under the debug API and walks
    it with `StackWalk64` / `IMAGE_FILE_MACHINE_I386`; `-step` reports which
    exception code a single step raises.
  - `MapSegBaseProbe` — cross-checks derived MAP segment bases against the PE
    section table.
  - `Td32ProcNesting` — walks TD32 proc records and their `pParent` links.
  - `Win32SessionProbe` — drives a real `TDebugSession` end to end (bind, fire,
    stop location, stack, locals, expansion, evaluation). Nothing in it is
    32-bit specific, which is the point: the same probe against either bitness
    makes a difference between two runs a real difference.

- **MCP session/process lifecycle bugs from a real DGOdacTests session (2026-07-17).**
  Three defects reported driving `DelphiDebuggerMcp.exe`; two fixed, one disproved:
  - **Session stuck after terminate (FIXED).** `TDebugSession.Launch/Attach` reject any
    state other than `dsNone`; after a debuggee ended the server kept the terminal-state
    session forever, so every later `launch_debuggee` failed with "A debug session is
    already active". Fix: `TMcpServer.EnsureFreshSessionForStart` recreates `FSession`
    when it is in `dsExited/dsDetached/dsTerminated` (or `HasExited`), called at the top
    of every launch/attach handler (and `PerformAttach`). A genuinely live session is left
    intact so a concurrent start is still rejected.
  - **Zombie debuggee locked the .exe (FIXED).** `TWinDebugger.Terminate`'s kill path
    called `TerminateProcess` but never consumed the resulting `EXIT_PROCESS` event, so the
    debug object held the killed process as a zombie -- image section mapped, `.exe` locked,
    rebuild `F2039` -- until the debugger process itself exited. Fix: `DrainUntilExit`
    pumps `WaitForDebugEvent`/`ContinueDebugEvent` until the terminal exit (3 s cap; falls
    back to `DebugActiveProcessStop`), then `CloseTargetHandles` closes the process/thread
    handles immediately. `Destroy` now delegates to `CloseTargetHandles` (idempotent).
    Regression: `DebugSessionTests.Terminate_ReapsDebuggeeProcess` (new
    `TDebugSession.DebuggeeProcessId` accessor + `OpenProcess`/`GetExitCodeProcess` poll).
  - **"verified breakpoint never fires" (NOT a wrong-file bind).** Reported on
    `Oracle.pas:2018` in a 57 MB DGOdacTests.exe; suspected basename collision with
    `doa\Oracle.pas`. Probed the real exe: TD32 `SourceLineToRva("oracle.pas",2018)` binds
    UNIQUELY to `$988A00 = TOracleQuery.FieldOptional`, round-tripping to `oracle.pas:2018`
    -- the correct DGOdac unit. TD32 NAMES stores only the BASENAME (`oracle.pas`, no
    directory), so full-path disambiguation is impossible AND unnecessary here (line 2018
    has code in only one unit; DOA's line 2018 is a type decl with no line record). The
    engine plants at the same RVA `DoSetBreakpoints` resolves, and BPs set at entry plant
    via `ApplyAllBreakpoints` (FFirstBreak already true). **Reproduced as WORKING
    (2026-07-17):** a probe driving `TDebugSession` directly against the real DGOdacTests.exe
    with the exact launch args (a one-off breakpoint-fire repro harness) reports `verified=True`
    and stops at `Oracle.pas:2018` in `TOracleQuery.FieldOptional` (reason=breakpoint) on the
    FIRST continue, before any exception. So bind/plant/fire is correct in the current build;
    the user's original non-firing was not reproducible -- most likely environmental /
    data-dependent, or a compromised session (the same session then hit the terminate/relaunch
    bugs above). Tooling: the TD32 line-binding check is now `DevTools\Td32LineLookup.exe
    <module> <src> <line>`; the fire repro itself was a one-off harness (not retained).


- **RSM sidecar `.idx` freeze -- root cause + fix (2026-07-02).** The multi-second
  (30-70 s) SampleApp stall before the first step was `TRsmFile.LoadProcIndexFromSidecar`,
  NOT the eval module-loading sweep. The sidecar deserializer declared its loop
  counters (`I, J`) and section counts as `UInt32`; `for I := 0 to Count - 1` with
  `Count = 0` underflows `Count - 1` to $FFFFFFFF -> ~4 billion iterations over garbage.
  SampleApp has zero proc-locals (`ProcLocalsCount = 0`), so the cache failed on EVERY
  load after the first (which writes the sidecar) -- the freeze hit the 2nd+ session.
  Fixes (in `RsmFileReader` + `RsmDecoders`): signed loop counters with `Integer(Count)`
  bounds; sidecar read into a `TMemoryStream` up front (no per-field syscalls);
  `SidecarGuardCount` rejects any count that can't fit the remaining bytes (corrupt
  sidecar fails in ~0 ms instead of minutes of paging); `ExtractTypeInfoNames` /
  `ParseUserTypeTable` swapped the O(n^2) `Result + [Name]` append for a `TList`.
  Measured on SampleApp.rsm (2.2 MB): load = ~80 ms cold, ~0 ms warm -- and the sidecar
  cache now succeeds for the first time (it had never once loaded). For reference,
  TD32 full LoadFromFile is 157 ms (90% in ParseAllTypeTables); RSM was the real cost.

- **Cold `.idx` build: 2.2-2.4x faster and now REPRODUCIBLE (2026-07-20).**
  cxLibraryRS29.dcp (45.5 MB) 1200 -> 523 ms, Spring.Base.dcp 907 -> 374,
  DapAdapter.rsm 399 -> 164, TestTarget.rsm 299 -> 107 (median of 3, warm page
  cache, sidecar deleted per run). Four things mattered, in order:
  (a) the sidecar writers wrote one field per `WriteFile` syscall — a
  `TBufferedFileStream` took cxLibrary's write from 585 ms to ~10 ms, and that
  write sits *before* `FIndexReady`, so it was half the time `WaitForIndex`
  blocks; (b) `ParseUserTypeTable` called NESTED functions once per byte, and a
  nested function carries a static link so it can never be inlined — prefilter
  at the call site (same fix as `ScanForProcOffsets`); (c) fixed multi-byte
  anchors are one unaligned `PUInt64` compare, not a byte-compare chain;
  (d) the phase fan-out is now two waves (producers, then the consumers that
  read their output). Before (d) the build was lossy and non-deterministic —
  three cold builds of one `.rsm` produced three different sidecars, each
  missing a different subset of resolved type hints, and the degraded index was
  what got cached. Compiling `DebuggerCore` with `-$O+` was measured and is NOT
  worth it (~5%): these scans are memory-bound. `DevTools\PrebuildIdx.exe`
  builds sidecars for a whole directory offline and `-verify` SHA-256-compares
  them, which is the byte-identity harness for future parser changes.

- **RSM is optional (2026-07-01).** The debugger is fully functional without a
  `.rsm` file; TD32 (embedded `.debug`, always in sync with the binary) is the
  primary debug-info source.
  - **Shipped `.rsm` policy: load only if FRESH.** `EnsureMainRsm` / `EnsureDllRsm`
    skip a `.rsm` that is older than its binary (`SymbolFileIsStale`) and fall
    back to TD32 -- a stale `.rsm` can no longer silently mis-type variables (the
    original motivation). Absent `.rsm` -> TD32. `NO_RSM=1` forces it off entirely
    (used to validate the TD32-only path).
  - **`.dcp` is the same format as `.rsm`** (both read by `TRsmFile`) and is NOT
    gated. A BPL target is fully served by its `.dcp` + TD32 -- it never needed
    `.rsm`. Only a monolithic exe (no `.dcp`) ever used `.rsm`.
  - **5 capabilities remain RSM-format-only** -- available on a BPL (via `.dcp`)
    or a mono exe with a fresh `.rsm`, lost only for a mono exe WITHOUT `.rsm`:
    `.dpr` program-main-block inline-var locals; date/time alias fidelity
    (`TDate`/`TTime`/`TDateTime`, else shown as `Double`); cross-unit uses-scope
    resolution; unit-scoped consts; a nested-proc inline `Variant`. Guarded in the
    suite by `SkipIfNoRsm` (skips only in the mono scenario under `NO_RSM=1`).
  - Eval/property/method/enum/is-as tests use a **portable named-proc receiver**
    (`W`/`S` in `RunEvalTests`, marker `EVAL_BODY`, both scenarios) instead of the
    `.dpr` main-block `TheWidget`/`TheStuff`, so they exercise the real TD32 path.
  - Regression: `Test_StaleRsm_IgnoredFallsBackToTd32` backdates a temp `.rsm` and
    asserts a `TDate` local falls back to the TD32 base type.
  - See `KNOWN_UNKNOWNS.md` ("RSM dependency removed -- RESOLVED") for the probes
    and the full analysis.

- Delphi `.rsm` is Embarcadero's own format. Reverse-engineered.
  - Local var record (classic): `20 [LEN] [NAME] 66 00 00 [TYPEID] [OFFSET]`
    (5-byte payload).
  - Local var record (inline format): `20 [LEN] [NAME] 66 00 01 [?]
    [TYPEID] [OFFSET]` (6-byte payload).
  - Main-block locals use marker `$46` instead of `$66`. Same payload.
  - Filter to `FormatFlag = 1` when scanning `$46` records to skip RTL
    globals that share the byte.
  - User type table is consecutive `66 [LEN] [NAME] [HASH4]` records right
    after the `65 06 System [3 bytes]` unit reference.
  - Procedure metadata between name and first local var is variable length
    (12 or 13 bytes observed); scan with an upper bound.
  - **Win64 RSM has no source line-number table.** Exhaustive search
    confirmed. Line<->RVA mapping comes from the TD32 SOURCE_MODULE
    subsection in the EXE's `.debug` PE section (preferred) or the
    MAP file's "Line numbers for" sections (fallback). The RSM was
    not designed to carry line info on Win64.
  - **`$2C` field with class type** -- carries an ODD 2-byte VLE
    TypeId equal to the matching `$2A` class declaration's TRAILER
    hash, not its declaration TypeId. `LookupTypeName` checks both
    `FTypeIdToName` (declaration TypeId) and `FClassHashCandidates`
    (trailer hash). Verified against `Exception.FInnerException` =
    `Exception`.
  - Tag `0x25` = named constant record (`const FOO = 'foo'` confirmed).
  - `63 9E` = EH/unwind symbol records (`$unwind$_`, `$pdata$_`); fill
    inter-procedure gaps in the symbol area.
  - `10 0F lo hi` = relocation/fixup entries for embedded stripped proc
    code; RVA = `(hi*256+lo)*32+16`; scattered through entire RSM.
  - Module record near end of RSM: `31 02 ED ED [flags][pathlen][path]
    [startRVA u4][codeLen u4][...]`.
- **Delphi Athens 36 Win64 VMT layout (empirical)** — the source constants
  in `System.pas` (`vmtTypeInfo=-144`, `vmtFieldTable=-136`) do NOT match
  what the compiled runtime actually uses:
  - VMT[-176] = SelfPtr (matches source `vmtSelfPtr`)
  - VMT[-168] = TypeInfo/ClassInfo address (source calls this `vmtIntfTable`)
  - VMT[-160] = pointer to `TVmtFieldTable` (source calls this `vmtAutoTable`)
  - VMT[-152] = InitTable (source `vmtInitTable`)
  - VMT[-144] = 0 for classes without `{$M+}` (source calls this `vmtTypeInfo`)
  - VMT[-136] = ShortString class-name + padding + TypeInfo pointer composite
  - VMT[-128] = raw `InstanceSize` integer (not a method table pointer)
  - VMT[-112..-96] = ClassName / InstanceSize / Parent (match source)
  `DelphiRtti.pas` uses `VMT64_TYPEINFO = -168` and `VMT64_FIELDTABLE = -160`.
  These offsets now live per target bitness in `TTargetLayout`; the Win32 values
  and the measurement method are in `TD32_FORMAT_NOTES.md` ("Runtime VMT slot
  offsets per target bitness"). A slot is one TARGET pointer wide, never a fixed
  8 bytes.
  The `TVmtFieldTable` at VMT[-160]^: `Count(2) + ClassTab(8) + ExCount(2) +
  TFieldExEntry[]`. For classes without `{$M+}`, Count=0; ExCount = number of
  extended fields. Each `TFieldExEntry` = Flags(1) + TypeRef:PPTypeInfo(8) +
  Offset(4) + Name:ShortString + AttrData(2).
- **Debug event loop — ContinueDebugEvent must be called for EVERY event**,
  including first-chance exceptions the debugger does not stop on. Failing to
  call it leaves the process permanently suspended. Non-stopping first-chance
  exceptions must use `DBG_EXCEPTION_NOT_HANDLED` so the program's own SEH
  handler runs. Stopping exceptions (AV, Delphi `$0EEDFADE`, second-chance)
  also store `DBG_EXCEPTION_NOT_HANDLED` in `FPendingContinueStatus` so that
  when the user presses Continue, the exception is passed to the program's
  `try/except` handler rather than being silently swallowed.
  Common "noise" first-chance codes seen in large Delphi apps:
  `STATUS_GUARD_PAGE_VIOLATION` ($80000001, fires on every stack/heap page
  growth), C++ SEH probing, CLR internal exceptions.
- **Pause button** — implemented via `DebugBreakProcess`, which injects a
  temporary thread that executes `INT3`. The resulting `EXCEPTION_BREAKPOINT`
  arrives with an unknown VA (not in our BP list). Detected by `FPauseRequested`
  flag. Do NOT rewind RIP: the injected thread resumes from RIP+1 and exits
  normally on `ContinueDebugEvent`.
- Synthetic remote call into the debuggee:
  - Allocate trap byte (single `0xCC`) once via `VirtualAllocEx`, reuse.
  - Save full context, set `RIP` to target, `RCX`/`RDX` to args.
  - `RSP := (saved.RSP and not 15) - 40` for 16-byte alignment + shadow space
    so RSP is `8 mod 16` at callee entry per Win64 ABI.
  - Clear TF in `EFlags` before resuming. Inheriting TF from a breakpoint
    handler causes a single-step exception per instruction (hung the
    debugger when called from inside `@UStrAsg`).
  - Stacked arguments (5th and later): with the return address written at
    [RSP], the callee's 32-byte home area is [RSP+8..RSP+39], so arg 5
    goes at [RSP+40], arg 6 at [RSP+48], ... Writing them at [RSP+32]
    lands arg 5 in R9's home slot (clobbered by callee spills) while the
    callee reads garbage from the real +40 slot.
  - The injected call's return address is a one-shot trap INT3. If the
    callee RAISES, the exception unwinds PAST the synthetic frame and the
    trap is never hit — the wait loop must detect this (Delphi raise / AV /
    second-chance on the call thread) and abort: restore the saved context
    and return failure, while the thread is cleanly stopped at the
    exception event. Without it a watch/hover on a raising method hangs the
    whole adapter. Benign first-chance noise (guard-page) is passed
    through so legitimate calls still complete. Note: a pure Delphi raise
    continued with DBG_CONTINUE makes RaiseException RETURN (the raise is
    silently suppressed and the callee completes); only an AV livelocks —
    that is why the abort matters for both, and why the regression test
    uses an AV getter.
- Delphi string layout (`TStrRec`): `CodePage(2) + ElemSize(2) + RefCnt(4) +
  Length(4) + chars + null`. `RefCnt = -1` marks an immortal literal — used
  for the buffer we hand to `@UStrAsg` so the runtime never tries to free it.
- `var` parameters in Win64 Delphi pass a pointer in the parameter slot. To
  edit the caller's variable, write through that pointer — overwriting the
  slot just makes the parameter point elsewhere for the rest of the callee.
- **`$66` / `$62` / `$46` local-offset uses Delphi's variable-length signed
  encoding (VLE)**. After the marker / FormatFlag / TypeId bytes the offset
  payload is one or two bytes:
  - LSB of byte[0] = 0  →  1-byte encoding, decoded value = `SAR(Int8(byte[0]), 1)`.
  - LSB of byte[0] = 1  →  2-byte encoding, decoded value =
    `SAR(Int16(byte[0] | byte[1] shl 8), 2)`.
  The decoded value is the RBP-relative displacement RELATIVE TO a per-direction
  base: locals (negative displacements) anchor to `N − ExtraPushBytes`,
  parameters (positive displacements, addressed in the caller's shadow space
  above the prologue saves) anchor to `N + ExtraPushBytes`, where `N` is the
  operand of `sub rsp, N` in the prologue and `ExtraPushBytes` is the total
  of extra `push r64` instructions between `push rbp` and `sub rsp`.
- **Delphi VarArray storage order**: `TVarArray.Bounds` is stored in REVERSE
  declaration order — `Bounds[0]` is the outermost (last declared, slowest
  varying) dim, `Bounds[DimCount-1]` is the innermost. Addressing is
  column-major in user dims (first user index varies fastest). For
  `VarArrayCreate([1,3,1,4], varDouble)`, `Mat[i,j]` lives at
  `(i-LB_i) + (j-LB_j) * EC_i` in element units.
- **Delphi Win64 prologue patterns** observed:
  - `push rbp; mov rbp, rsp; sub rsp, N` — small leaf procs without managed
    locals. RBP at top of locals.
  - `push rbp; [push rX...]; sub rsp, N; mov rbp, rsp` — procs with managed
    locals (Variants, strings, dynarrays) or callee-preserved registers in
    use. RBP at BOTTOM of locals; locals live at positive RBP offsets in
    `[0..N)`. ExtraPushBytes counts the inter `push r64`s.
  Both patterns end up with the same local-addressing convention because RSM
  encodes offsets relative to `N − ExtraPushBytes` regardless of which prolog
  pattern is used.
- **Anonymous proc record (`$28 $00`)** holds the main-block locals in the RSM;
  the named program proc (`$28 0A TestTarget`) has no locals. Parser searches
  backward ≤256 bytes for the anonymous record as fallback.
- **`ReadFrameSize` must skip extra `push r64` instructions** between `push rbp`
  and `sub rsp, N`. Each extra push adds 8 to the effective frame size so that
  RBP-relative offsets resolve correctly.
- Step-out: read `[RSP]` is only correct at function entry. After the
  prologue moves `RSP` for locals + shadow space, the return address is no
  longer at `[RSP]`. Use `StackWalk64` (which honours `.pdata`) to get the
  caller's resume RIP from anywhere in the callee.
- **Identifying the OWNING module of code under runtime-package sharing.** When
  an exe and its runtime packages share a single RTL package, the `System`
  globals `IsLibrary` and `HInstance` hold the MAIN module's values everywhere
  (an exe host -> `IsLibrary=False`), even inside a loaded BPL — so they CANNOT
  tell exe-hosted code apart from package-hosted code. The reliable test is to
  resolve the module from a CODE ADDRESS that physically lives in the unit:
  `VirtualQuery(@SomeLocalProc).AllocationBase` is that module's load base, and
  `GetModuleFileName(base, ...)` yields its path (`.exe` vs `.bpl`). Used by
  `TestTargetCore.RunningInsidePackageModule` to run the portable object-method
  scenario only inside `TestSubject.bpl` (validated by a one-off module-ownership
  probe that called `VirtualQuery`/`GetModuleFileName` from both hosts; the finding
  above is the retained record).
- **RSM robustness fixes the TestTargetCore relocation surfaced** (all in the
  adapter, all green): (1) `DecodeClassMemberHash` decodes the 1-byte
  `$08 lo $FF` member hash as `$00lo` for unit-section Variant-D classes;
  (2) `ParseTypeDeclarationSection` also registers the even 1-byte low-byte
  class-hash candidate so those members bind; (3) `GetClassMembers` rejects
  built-in scalar/string type names (`IsBuiltinScalarTypeName`) — a primitive is
  never a class, which stops the 1-byte-hash collision from making
  `GetClassMembers('Integer')` spuriously true (it had broken `Integer(3.9)` ->
  class-cast -> raw bits); (4) `DapServer.FieldDrillDownRef` consults the live
  object's RTTI at the same offset before refusing a non-expandable RSM leaf —
  rescues a generic backing field (`TList<T>.FItems`) whose per-unit type-id
  mis-resolved.

## Build / run commands (stable)

Full rebuild (Debugme + VisualStudioCodeDelphiDebugger):

```bat
call build_debug.bat
```

Adapter only (faster iteration):

```bat
call build_dap.bat
```

Manual debug target build:

```bat
call rsvars.bat
dcc64 Debugme.dpr
```

Outputs:

```
Win64\Debug\Debugme.exe
Win64\Debug\Debugme.rsm
Win64\Debug\Debugme.map
VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe
```

RSM smoke test (`DevTools` tree, sources include the project's
`RsmFileReader` directly):

```bat
cmd /c "C:\Athens\GitHub\Win64Debugger\DevTools\build_all.bat"
DevTools\Win64\Debug\TestRsmParser.exe Win64\Debug\Debugme.rsm
```

VS Code:
- Open `Win64DebuggerProj.code-workspace`, not the folder.
- Local extension lives in
  `%USERPROFILE%\.vscode\extensions\local.delphi-win64-debug\`.

## Diagnostic logging

`%TEMP%\dap_adapter.log`, line-timestamped. Always on today.
Make opt-in is a roadmap item.
