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

The adapter is a single Win64 process, and that one binary debugs both x64 and
32-bit (WOW64) targets — see "Target architecture" below. VS Code spawns it via
the local debug-type extension and exchanges DAP messages on stdin/stdout. The
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
- `WinDebuggerBase.pas` — `TWinDebugger`: the Windows debug loop. Drives
  `WaitForDebugEvent`, manages INT3 plant/remove, single-step, breakpoint
  reactivation, StackWalk64-based unwinding, synthetic remote calls into the
  debuggee, and the local/global variable readout. Everything here except the
  architecture seam (see "Target architecture" below) is bitness-neutral; the
  class doubles as the x64 implementation of that seam.
- `WinDebuggerX86.pas` — `TWin32Debugger`, a descendant of `TWinDebugger` that
  debugs a 32-bit (WOW64) target. It overrides only the architecture seam and
  inherits the event loop, breakpoints, stepping, module handling and the
  synthetic-call pump unchanged.
- `TargetLayout.pas` — `TTargetLayout`, the memory layout of the DEBUGGEE
  (pointer size, dynamic-array header shape, VMT slot offsets) as a plain data
  record. `SizeOf(Pointer)` describes the adapter and says nothing about the
  address space being decoded.
- `Disassembler.pas` — the disassembly seam (`DISASSEMBLY_PLAN.md` increment
  2): `IDisassembler`, `TDisasmInstruction`, `TDisasmMachineMode`,
  `TDisasmByteReader`. No third-party reference — see "Disassembly seam"
  below.
- `ZydisDisassembler.pas` — `TZydisDisassembler`, the Zydis-backed
  `IDisassembler` implementation. The only unit besides `ZydisApi.pas` itself
  allowed to reference Zydis.
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
  RANGE-SCOPED like RSM/TD32/DCP — `EnsureModuleMap` registers it through
  `AddModuleProvider` (`ModuleSymbolLoader.pas:1216`), which adds it to the flat
  name/line lists AND to the ranged RVA lists, so an RVA the module owns that its
  ranged TD32 cannot name (an anonymous-method body, for which TD32 emits no proc
  symbol) falls through to the MAP instead of being blocked by an "owned but none"
  answer. (This line previously stated the opposite, "DLL MAP added UNSCOPED".
  That was a diagnosis from a field round, later RETRACTED — it was the wrong
  explanation for the bogus `Application` RVA `$1C38`, and it survived here after
  the code had moved on. A module MAP's RVAs are shifted into exe-RVA space and
  range-scoped, so a `vcl290` RVA cannot surface as a bare `$1C38`.); the
  per-module `*Tried`
  probe-once negative cache; `SymbolFileIsStale`'s 2 s grace. The DAP keeps its
  background loader (still off by default), progress/spinner, and evaluate
  warm-up caches on top of the shared synchronous primitives.

## Disassembly seam

Full design and verification detail lives in `DISASSEMBLY_PLAN.md`
("The seam", "Verified in increment 2"); this section is the pointer to where
it sits in the module graph and the one engine primitive it added.

- `IDisassembler` (`Disassembler.pas`) is frontend- and library-neutral, same
  discipline as `IDebugTarget`: no third-party type crosses it.
  `TZydisDisassembler` (`ZydisDisassembler.pas`) is the only implementation
  and the only unit outside `ZydisApi.pas` that references Zydis. Both
  frontends consume it now: MCP's `disassemble` tool (increment 4,
  `MCPDebugger\McpServer.pas`, `TMcpServer.HandleDisassemble`) and DAP's
  `disassemble` request (increment 6, `VisualStudioCodeDelphiDebugger\
  DapServer.pas`, `TDapServer.HandleDisassemble`) build the SAME
  `TZydisDisassembler` the same way — `FDebugger.TargetLayout.PointerSize`
  picks the machine mode, `FDebugger.ReadCodeMemoryAt` is the byte reader,
  `FDebugInfo` + `FDebugger.ImageBase` drive symbolication — each frontend
  keeping its own small `ResolveZydisDllPath`/`DefaultZydisDllPath` pair
  rather than sharing a unit across the two separate executables.
- Bytes reach the backend through a caller-supplied `TDisasmByteReader`
  callback, not through `IDebugTarget` directly, so the backend itself knows
  nothing about live sessions, breakpoints, or file formats. A live-session
  caller wires the callback to `IDebugTarget.ReadCodeMemoryAt`; a static-file
  caller (`DevTools\Disasm.exe`'s file+RVA mode) wires it to a plain
  file read.
- **`IDebugTarget.ReadCodeMemoryAt(VA, Buf, Size): NativeUInt`**
  (`DebugTarget.pas`, implemented once in `WinDebuggerBase.pas` and shared
  unchanged by `TWin32Debugger` — breakpoint planting and `FProcess` are
  already architecture-neutral) is the one new engine primitive this
  increment added. It behaves like `ReadProcessMemoryAt` except: any of the
  debugger's OWN planted `INT3` bytes in the returned window are restored to
  `FBreakpoints[].OrigByte`, and a request running past the end of the
  committed `VirtualQueryEx` region truncates instead of failing. Both
  properties matter beyond disassembly — any future caller that wants to
  read CODE rather than data should reach for this over
  `ReadProcessMemoryAt`.
- Symbolication (`Symbol`, `SrcFile`, `SrcLine` on `TDisasmInstruction`, and
  the inline `; Name+offset` comment appended to a resolvable direct
  call/jmp/jcc's `Text`) goes through `TDebugInfoSet.RvaToFunctionName` /
  `RvaToFunctionStart` / `RvaToSourceLine` — the exact calls
  `WinDebuggerBase.pas` makes to name an ordinary stack frame (see "Frame
  symbol attribution" below). A live session hands the disassembler its own
  `TDebugInfoSet` (multi-module aware); a static-file probe builds one from
  the sibling `.rsm`/`.map` in the same provider order
  `TModuleSymbolLoader.LoadMainModule` uses for a main exe.

### DAP `disassemble` and `instructionPointerReference`

Full design/decision detail and every proof lives in `DISASSEMBLY_PLAN.md`
("Decision: backward disassembly is proven-boundary-only", "Verified in
increment 6"); this is the pointer to where it sits and the one thing worth
restating here: **the DAP spec itself, not a project convention, decides how
an unprovable instruction is expressed.**

- `instructionPointerReference` (`'0x' + IntToHex(F.IP, 1)`) is added to
  EVERY `StackFrame` `HandleStackTrace` emits, including raw-scan and
  nameless frames — `TSessionFrame.IP` is always populated. This is what
  enables VS Code's "Open Disassembly View" action from the Call Stack.
- `HandleDisassemble` splits `instructionOffset` into a backward span
  (`TrueNegCount = -instructionOffset`, when negative) and a forward span
  (`PosSkip = instructionOffset`, when positive) — mutually exclusive. The
  backward span is answered by `Disassembler.DisassembleBackward`, called
  with the FULL span length (never pre-clamped to `instructionCount`) so that
  the landing proof covers every slot the response might need, then sliced
  client-side to the requested window — this is what makes a "far" backward
  request (one that never reaches `memoryReference`) return the earliest
  provable/unprovable slots rather than the ones nearest the current PC. The
  forward span is a plain `IDisassembler.Disassemble` call.
- **Every slot the backend could not produce — an unproven backward span
  (no boundary, or a decode that does not land exactly), or a forward read
  that ran off unmapped memory — is filled by
  `BuildInvalidDapInstruction`: `presentationHint: 'invalid'`, no
  `instructionBytes`, `instruction: '??'`, and a synthetic filler `address`
  anchored on the nearest thing actually proven** (the real boundary address
  when the natural chain from it is shorter than asked; `memoryReference`
  itself when nothing at all could be proven). This is not an adapter
  convention invented for this feature: `DisassembleArguments
  .instructionCount` in the DAP spec (`debugAdapterProtocol.json`) states an
  adapter "must return exactly this number of instructions - any unavailable
  instructions should be replaced with an implementation-defined 'invalid
  instruction' value", and `DisassembledInstruction.presentationHint`'s
  `invalid` value is documented for exactly this: "filler" that "cannot be
  reached by the program". A genuine `db XX` (real bytes, unrecognised
  encoding) is NOT marked `invalid` — that distinction is preserved through
  this path exactly as it already is over MCP.
- **Not verified by this codebase: real VS Code behaviour.** Every assertion
  is at the DAP protocol layer through the same synchronous test client
  (`DebuggerTests\DapClient.pas`) every other integration test in this suite
  uses. No test drives an actual VS Code Disassembly View against the
  adapter.

### DAP memory: readMemory/writeMemory, memoryReference — increment 3

`ASSEMBLY_LEVEL_DEBUGGING.md` increment 3 owns the decision record (which
variables carry a `memoryReference` and why); this is the mechanism and the
wire contract. Handlers: `TDapServer.HandleReadMemory`/`HandleWriteMemory`
(`DapServer.pas`), dispatched from `ProcessRequest` on `'readMemory'`/
`'writeMemory'`. Coverage: `TEST_CATALOG.md` section R.

- **`readMemory`** reuses `IDebugTarget.ReadCodeMemoryAt` — the SAME call
  `disassemble` already makes, not a second read path. That primitive
  restores the debugger's own planted `INT3` bytes within the returned
  window and truncates at the end of the committed `VirtualQueryEx` region
  instead of failing. The DAP response mirrors that truncation directly: a
  short (or zero-length) read is a `success: true` response with
  `unreadableBytes = count - bytesActuallyRead` and `data` covering only
  what was read (the `data` key is omitted entirely, not sent empty, when
  nothing was readable). `count` and `memoryReference` are DAP-required
  fields; a request missing `count` is refused (`Args.FindValue('count') =
  nil`), never silently treated as `count = 0` — an absent required field is
  a malformed request, not "read nothing". `data` is base64 via
  `TNetEncoding.Base64String` specifically: the default
  `TNetEncoding.Base64`/`TBase64Encoding.Create` wraps output at 76
  characters with embedded CRLFs, which is wrong for a JSON string field;
  `Base64String` (`TBase64StringEncoding`) is the single-line variant.

- **`writeMemory`** uses a new engine primitive,
  `IDebugTarget.WriteMemoryPartial(VA, Buf, Size): NativeUInt`
  (`WinDebuggerBase.pas`, shared by `TWin32Debugger` unchanged — same
  inheritance as `WriteMemoryAt`/`ReadProcessMemoryAt`). It performs the
  identical `VirtualProtectEx(PAGE_READWRITE)` / `WriteProcessMemory` /
  `VirtualProtectEx(restore)` sequence `WriteMemoryAt` already used, but
  returns the actual byte count `WriteProcessMemory` reports instead of
  collapsing every outcome to a Boolean. It is a SEPARATE function body
  rather than `WriteMemoryAt` rewritten in terms of it, because
  `WriteMemoryAt`'s `if FProcess = 0 then Exit(False)` guard fires
  unconditionally (even for `Size = 0`), and a `Result = Size` wrapper
  around `WriteMemoryPartial` would get that one edge case wrong (`0 = 0`
  reads as success). MCP's `write_memory` keeps using the plain, unchanged
  `WriteMemoryAt` — no reason for it to change shape.

  The DAP `allowPartial` contract (`WriteMemoryArguments`, DAP spec):
  - **absent/false**: the response is `success: false` whenever fewer than
    `Length(data)` bytes actually landed. This adapter ATTEMPTS the write
    first and reports what happened, rather than pre-verifying writability
    across the whole requested range before touching anything (the shape
    the spec suggests for this case). Consequence, stated plainly because it
    is the one place behaviour does not match the spec's suggested
    *implementation strategy* (though it does match its *observable
    contract* — never a false "succeeded"): a refused write can already have
    changed however many bytes were writable before the boundary
    (`WriteProcessMemory` is not transactional). The refusal message states
    that count explicitly (`"... N bytes were already changed in the
    debuggee ..."`) so the caller is not left assuming zero effect.
  - **true**: `success: true`; body carries `bytesWritten` (the true count)
    and `offset` (always `0` — this handler only ever attempts ONE
    contiguous write starting at the requested address; it never skips a
    leading unwritable span, only truncates a trailing one).
  - `data` is a required field; a request missing it is refused
    (`Args.FindValue('data') = nil`), never treated as "write zero bytes".

- **`memoryReference` on variables**: `TSessionVariable` (`DebugSessionTypes.pas`)
  gained an `Address: UInt64` field, `0` meaning "no real address" — the
  exact convention `TLocalValue.Address <> 0` already established throughout
  this codebase. `EmitVar` (`DapServer.pas`) adds `memoryReference` to a
  `variables` row only when `V.Address <> 0`; a missing reference is silence,
  never a fabricated `0x0`. Producers, and the reasoning for each:
  - `TDebugSession.LocalToSession` sets it from `LV.Address` — covers every
    top-level Locals-scope row (plain locals, closure-captured fields,
    anon-method params, all of which already flow through this one
    function).
  - `VariableExpander.pas`, five sites, each setting `.Address` from a value
    the SAME function already dereferences to produce the displayed value —
    `MemberFieldToSession` (`FieldAddr`), `ExpandRttiTyped`
    (`F.FieldAddr`), `ExpandProperties`'s field-backed branch only
    (`FieldAddr` — the getter-backed branch deliberately does not),
    `ExpandDynArray` (`ElemAddr`), `ExpandVariantArray` (`ElemAddr`).
  - `TDapServer.BuildCurrentExceptionRef` grew an `out ObjAddr: UInt64`
    (the live exception object's own address), threaded into both the
    `$exception` row `AppendExceptionLocal` builds and the `evaluate`
    response for the literal expression `"$exception"`.
  - Never set (stays the record's zero default): a register-resident local
    (no provider sets `LV.Address` for one); the `Registers` scope (built
    directly in `HandleVariables`, never through `EmitVar` — a CPU register
    is not a byte-addressable location at all); a synthetic group row
    (`Kind = vkGroup`); a getter-backed property's evaluated SCALAR result
    (`ExpandPropertyGetter`'s `'(value)'` leaf — the value came from a
    synthetic method CALL, not a read of an existing slot); an indexed
    property leaf. A getter that returns a STRUCTURED value is the one
    non-obvious case: `ExpandPropertyGetter` hands a class/record result off
    to `ExpandViaMembers` on the real address the getter returned, so THOSE
    fields still get `memoryReference` — they are genuine memory regardless
    of how the base address was obtained; only the getter's own un-expanded
    result is addressless.
  - Not extended to `evaluate`/watch results beyond the `$exception` special
    case: DAP's `EvaluateResponse.body` has its own optional
    `memoryReference` field and a plain evaluated expression could honestly
    carry one, but wiring every branch of `HandleEvaluate` was out of scope
    for this increment.

- **Not verified**: no test drives a real VS Code memory inspector against
  the adapter (same caveat `disassemble`'s own section already records for
  the Disassembly View) or exercises the "debuggee is running" refusal gate
  on either request (racy to construct reliably; the gate itself
  `FSession.State <> dsStopped` is the same shape `HandleDisassemble` already
  uses). `memoryReference` on a nested field/array/Variant-array element has
  no DAP-level end-to-end test — only the top-level Locals case is driven
  through a real adapter session; the five `VariableExpander.pas` sites are
  covered by inspection (each sets `.Address` from a value already used for
  a real read one line away), not by a dedicated fixture.

## Target architecture: one adapter, x64 and WOW64 x86

**One 64-bit adapter binary debugs both bitnesses.** A 64-bit process can debug
a 32-bit one; the reverse is impossible. A second, 32-bit build was rejected on
a concrete constraint rather than on taste: the MCP server is registered once at
editor startup with a fixed command, long before any target exists, so it could
never pick a per-bitness binary — two binaries would force an IPC proxy for no
gain.

The split runs along one line:

- **Behaviour** differences — thread context and registers, stack walking,
  prologue decoding, the call ABI — go behind `IDebugTarget`, as virtual methods
  overridden by `TWin32Debugger`.
- **Layout** differences — pointer size, dynamic-array header, VMT slot offsets
  — go in `TTargetLayout`, a plain data record consulted while decoding a buffer
  that has already been read.

### The architecture seam

`TWin32Debugger` (`DebuggerCore\WinDebuggerX86.pas`) overrides exactly these and
nothing else:

| Method | What the x86 override does |
|---|---|
| `TargetLayout` | returns `TTargetLayout.For32Bit` |
| `StackWalkMachineType` | `IMAGE_FILE_MACHINE_I386` |
| `ReadThreadRegisters` | `Wow64GetThreadContext` |
| `SetThreadPc` | `Wow64SetThreadContext` |
| `SetRegisterByName` | `Wow64Get/SetThreadContext` by name; refuses `R8`..`R15` (ASSEMBLY_LEVEL_DEBUGGING.md increment 6) |
| `SetThreadTrapFlag` | `Wow64SetThreadContext`, EFLAGS bit `$100` |
| `ReadDebugRegisters` / `WriteDebugRegisters` | `Wow64Get/SetThreadContext` with `WOW64_CONTEXT_DEBUG_REGISTERS`; the registers are 32 bits wide, so the widening is the whole difference |
| `FillStackWalkContext` | seeds `StackWalk64` from a WOW64 context |
| `ReadPrologInfo` | x86 byte-pattern decoder (x86 has no `.pdata`) |
| `LocalsOffsetBase` / `ParamsOffsetBase` | 0 — see "x86 frame model" |
| `PrepareSyntheticCall` | EAX/EDX/ECX, no shadow space |
| `ReadSyntheticCallResult` | EAX |
| `CurrentFrameParamHomeAddr` | 0 — there is no x86 analogue |

Everything else is inherited unchanged, which is the point: the debug event
loop, breakpoint planting, stepping, module handling and the synthetic-call
event pump (with its abort-on-raise path and watchdog) are architecture neutral.

`FillStackWalkContext` takes a buffer typed `TContext` because that is the
larger and correctly aligned of the two structures; the smaller WOW64 context is
written at its start, and `StackWalk64` mutates it opaquely as it unwinds, so
the walk never reads the buffer's declared fields again.

### Choosing the class

The factory is `TDebugSession.BuildAndWireDebugger`, the single construction
site. It picks by reading `IMAGE_FILE_HEADER.Machine` from the **on-disk** PE
(`MapFileReader.ReadPEMachine`).

`IsWow64Process2` cannot be used here: it needs a live process handle and cannot
answer until `CREATE_PROCESS_DEBUG_EVENT`, which is long after the object has
been built. `TWinDebugger`'s own WOW64 probe at that event still runs, but it is
now only a redundant confirmation that the live process agrees with what was
constructed (its advisory console text predates Win32 support and is stale —
noted in `PROJECT_STATE.md`).

### `TTargetLayout` is data, not an interface

Deliberately a plain record: a virtual call per pointer would shatter bulk reads
into syscalls, and these values are consulted inside decode loops where a branch
is free but a dispatch is not. **The rule it encodes: read a region once, then
decode the local buffer with these numbers — never ask the target a question per
field.**

`IDebugTarget` exposes `TargetLayout`. `TDelphiRtti` reads through a raw process
handle rather than through the interface, so it is told its layout at
construction instead (at each of the three sites where `TDebugSession` creates
it).

Consumers so far: the dynamic-array header reads, the closure/`$ActRec` and
`Self` stack scans, VMT slot reads, the published-RTTI walk (below), and every
"pointer-shaped" value read (`LocalReadSize` in `DelphiValueReaders`, which
separates genuinely 8-byte types — `Int64`, `Double`, `Currency`, `TDateTime` —
from pointer-sized ones that take the target's pointer size).

#### Walking `TTypeData` / `TPropInfo`

`TDelphiRtti.GetClassProperties` enumerates a class's published properties by
walking the RTTI records in target memory. Every pointer in them is a **target**
pointer, so the record stride and each field offset are expressed in
`FLayout.PointerSize`. Getting this wrong does not fail loudly: a 64-bit walk of
a 32-bit target consumes 18 bytes where the record is 10, desynchronises on the
first entry, and simply matches no property by name — which looks like "this
class has no published properties" and quietly routes every property expression
to the debug-info fallback instead.

The accessor kind (field / virtual / static) is encoded in the **top byte of the
getter pointer**, so its shift follows the pointer width too: `System.TypInfo`
defines `PROPSLOT_MASK` as `$FF000000` at 32-bit and `$FF00000000000000` at
64-bit.

The same rule governs every other RTTI table `TDelphiRtti` walks, and each one
has a fixed part whose size is a function of the pointer width rather than a
constant:

| Record | Fixed part |
|---|---|
| `TPropInfo` | `4*ptr + 10` |
| `TFieldExEntry` | `ptr + 5` |
| `TRecordTypeField` | `2*ptr + 1` (both `TManagedField` members are pointer-width, the offset included) |
| `tkDynArray` `TTypeData` | `elType` at `+4`, `elType2` at `+8+ptr` |

There is deliberately **no `ReadU64`** on `TDelphiRtti`. Everything eight bytes
wide in these records is a pointer or a `NativeInt`, so a fixed-width read is
wrong on a 32-bit target — and wrong quietly, by splicing the neighbouring field
into the high half and desynchronising the remainder of the walk. `ReadVmtSlot`
and `ReadTargetPointer` are the only ways in.

That fallback is why the symptom presented as a *type-name* difference rather
than as missing properties: TD32 still produced correct values, but its
primitive `$0041` collapses `Double`, `TDateTime` and `Real` onto one id, so a
`TDateTime` property came back typed `Double` and lost its date rendering. The
alias survives only in the debuggee's live RTTI (and in the `.rsm` type table);
TD32 cannot express it.

#### A var-out `Result` is typed `^T`, and the caret is the ABI

TD32 renders the `Result` local of a function that returns through the hidden
var-out slot as a POINTER to the real return type — measured on TestTarget:

| function | declared return | TD32 `Result` hint |
|---|---|---|
| `DoCalcUStr` | `UnicodeString` | `^string` |
| `DoCalcVariant` | `Variant` | `^Variant` |
| `DoCalcBigRec` | `TPoint3D` | `^TPoint3D` |

That is faithful — the slot really does hold a pointer the routine writes
through — but it is the calling convention, not the type. `TryGetReturnTypeFromResultLocal`
fed the hint straight to `TypeNameToKind`, which resolves nothing for `^Variant`
or `^TPoint3D`, so the return kind stayed unknown and the slot was read as an
8-byte scalar: `W.DoCalcVariant()` showed `3` (the `varInteger` VType word) and
`W.DoCalcBigRec()` showed `0x3FF8000000000000`, the double `1.5`, which is the
record's FIRST FIELD. Strings escaped it only because the caret is stripped
separately further down the string path — which is precisely why the defect
survived: the one case anybody tried worked.

The caret is now stripped at the source, but ONLY when the pointee's kind is one
that genuinely travels through the var-out slot (managed families plus records).
A function returning a pointer BY VALUE in RAX also has a caret in its `Result`
hint, and stripping that one would read the pointee instead of the pointer.

Pinned by `Test_Eval_VarOutReturn_DirectCall_IsDecoded`, which asserts the
Variant's value, the record's type AND expandability, and keeps the string case
as a control.

STILL OPEN: `W.DoCalcDynArr()` returns `[85899345930, 30, []]` (`0x14_0000000A`
= elements 20 and 10 read as one 8-byte element). The cause is now measured, and
it is NOT the same one:

```
DoCalcDynArr.Result  $B4B9  LF_POINTER -> $B4BA LF_POINTER -> $B4BC leaf=$32 -> Integer
RunEvalTests.Scores  $B4BA             LF_POINTER -> $B4BC leaf=$32 -> Integer
```

A dynamic array is `LF_POINTER -> leaf $32` in TD32, and the var-out `Result`
carries exactly ONE extra `LF_POINTER` — it is literally the next link of the
same chain as the working local. So stripping one caret would be right here too;
the caret-strip above declines to do it because it decides by NAME, and
`TypeNameToKind('^Integer')` cannot tell a dyn array from a pointer.

Fixing it properly means deciding by the TYPE ID rather than the name.
`TTD32FileReader.TypeKindById` already answers exactly this question, but it is
private and not surfaced through `TDebugInfoSet`; exposing it is a new provider
interface, i.e. a cross-cutting change rather than a patch. The alternative — 
strip a caret whenever the pointee itself starts with `^` — is a heuristic that
would misfire on a function returning a pointer-to-pointer by value. Deliberately
left for a reviewed decision.

#### `WideString` is a BSTR, not a Delphi long string

The two look identical — a pointer to UTF-16 data with a 4-byte prefix below it
— and the prefix means different things:

| Type | Prefix at `Ptr-4` | Read as |
|---|---|---|
| `UnicodeString` | `TStrRec.length`, in **elements** | `len` chars |
| `WideString` | `SysAllocStringLen` byte count, in **BYTES** | `len div 2` chars |

One reader served both, so every `WideString` came back at exactly twice its
length: `'w_hello'` (7 chars) rendered as `'w_hello'` + the NUL terminator +
three words of `BAADF00D` heap fill, on both bitnesses. `AnsiString`,
`UTF8String` and `RawByteString` were unaffected, which is what isolated it to
the BSTR rule rather than to the UTF-16 decode.

`ReadDelphiWideString` and `ReadDelphiUnicodeString` now share
`ReadUtf16Prefixed(Ptr, LengthIsBytes)` and `FormatStringByPointer` dispatches
`TK_WSTRING` to the former. Pinned by
`Test_Eval_WideStringProperty_HasNoTrailingGarbage`, which asserts the EXACT
rendering — a `Contains('w_hello')` check passed happily while the garbage was
still there.

#### Float types wider than the value slot

Every value is decoded from an 8-byte `RawValue`. Three float types do not fit
it, and each fails silently rather than loudly if read at the wrong width:

| Type | Win32 | Win64 |
|---|---|---|
| `Extended` | **10** (x87) | 8 (a true alias of `Double`) |
| `Extended80` | 10 | **10** |
| `Real48` | 6 | 6 |

Sizes measured with `DevTools\Win32FloatAbiProbe`, which dual-compiles so both
columns come from the compiler rather than from documentation.

`ReadValueSlotRaw` (`DelphiValueReaders`) is the single entry point for reading a
value slot. It consults `WideFloatByteSize` first and narrows those three to
`Double` bits — the encoding every formatter downstream expects — before falling
back to `LocalReadSize` for everything else. Precision beyond a `Double` is lost,
which is the price of the slot and vastly better than the alternative: reading 8
of an `Extended`'s 10 bytes keeps the **mantissa** and discards the **exponent**,
reporting 2.75 as `-1.7E-77`.

`Real48` is the pre-8087 Borland software float — 8-bit exponent biased by 129 in
the **lowest** byte, 39-bit fraction, one sign bit. Nothing about it resembles an
IEEE double, so it gets its own decoder, transcribed from the RTL's `_Real2Ext`
rather than reconstructed.

**Writing has the same problem and needs the same table.** `setVariable` encodes
the new value into the target's own representation, and the generic
`EncodeValueForType` emits 8 bytes of IEEE double for anything it classifies as a
float. Into a 10-byte Win32 `Extended` that leaves the top two bytes — the sign
and exponent — holding the variable's *previous* contents. Measured, by disabling
the fix and re-running the round-trip test: setting a Win32 `Extended` to `9.5`
read back as `3.002136`. `TryEncodeWideFloat` is therefore tried **before**
`EncodeValueForType`, exactly as the enum encoders already are, and builds the
80-bit or Real48 pattern by hand — the adapter is a 64-bit binary where
`Extended` *is* `Double`, so the FPU cannot widen it for us.

`TDynArrayRec` is the clearest case, since unlike the string header Delphi did
not make it bitness-neutral:

```
Win64   _Padding(4) RefCnt(4) Length: NativeInt(8)   -> length at data-8, 8 wide
Win32               RefCnt(4) Length: NativeInt(4)   -> length at data-4, 4 wide
```

Reading one with the other's shape does not fail; it splices the refcount into
the length and returns a plausible wrong number.

### `TRegisterSnapshot` is a superset, and roles beat physical names

`TRegisterSnapshot` is a 64-bit **superset of both register files**. A 32-bit
target fills the same fields from EIP/ESP/EBP and leaves R8..R15 zero. That is
why the role accessors `Pc` / `StackPtr` / `FramePtr` exist: a consumer asking
for a role gets a correct answer on both bitnesses, while one reading a physical
64-bit name gets a meaningless one on x86. Physical register names are
legitimate in exactly two places — the x64 implementation itself, and the DAP
Registers view.

### WOW64 debug events

Measured against a live WOW64 target (`DevTools\Wow64StackProbe.dpr`), not taken
from documentation:

- An INT3 in 32-bit code arrives as `STATUS_WX86_BREAKPOINT` (`$4000001F`), not
  `EXCEPTION_BREAKPOINT`. A loop testing only the native code never sees a user
  breakpoint and re-dispatches the target's own trap forever.
- A single step raises `STATUS_WX86_SINGLE_STEP` (`$4000001E`), **not**
  `EXCEPTION_SINGLE_STEP`. This is the half that was at risk of being assumed:
  it does not follow from the breakpoint half. The probe set EFLAGS.TF through
  `Wow64SetThreadContext` and observed the code on the next event.
- The **first** stop of a WOW64 target is a native `$80000003` at a 64-bit
  `ntdll` address, with the 32-bit side still at `EBP = 0`; it yields one frame
  and is not unwindable. Every later 32-bit stop is `$4000001F`.

Both codes are accepted at all four sites (the two `HandleException` case labels
and the two comparisons in the synthetic-call pump). The constants are untyped,
because a typed constant is not a compile-time constant in Delphi and cannot
appear as a case label. Win64 is unaffected: a native x64 target cannot raise
them.

### x86 stack walking

`StackWalk64` with `IMAGE_FILE_MACHINE_I386` plus a WOW64 context unwinds a
32-bit Delphi target correctly — no hand-rolled EBP walker is needed. dbghelp
contributes **nothing** to that walk: invade-only, every module registered
explicitly, and both callbacks nil all give byte-identical output with a nil
`FuncTableEntry` throughout. The result rests on `StackWalk64`'s built-in
frame-pointer chain plus its first-frame `[ESP]` heuristic.

The i386 walk does not survive a still-planted INT3 (the walker takes a stack
address as a return address and loses the real caller), but that is not a state
the adapter is ever in: at a breakpoint hit it already restores the original
byte and rewinds the program counter before anything walks. The corrupted walk
is reproducible only with the probe's `-nopatch` mode.

### x86 frame model

The opposite of x64 in the one way that matters: **`mov ebp,esp` PRECEDES the
allocation**. Consequences:

- The return address is always at `[EBP+4]` and the caller's frame at `[EBP]`,
  so **no frame size is needed to walk**.
- A debug-info offset is already relative to the frame pointer — locals at
  negative offsets, parameters at positive ones — so `LocalsOffsetBase` and
  `ParamsOffsetBase` are 0. The x64 bases exist only because its frame pointer
  is established *after* the allocation, so an offset needs re-anchoring.

The prologue decoder (ported verbatim from the candidate `PrologProbe` validated
across 17 deliberately shaped routines, not adapted from the x64 matcher):

- Delphi allocates with `add esp,-N` (`83 C4` / `81 C4`, **negative
  immediate**), not `sub esp,N`. A decoder looking only for `sub` reports frame
  size zero on nearly every routine.
- The matcher must require `$55` (`push ebp`) followed **immediately** by
  `8B EC` (`mov ebp,esp`; `89 E5` is the alternate encoding). That adjacency is
  what rejects an optimised frame in which EBP was pushed as an ordinary
  callee-saved register.
- Pushes and allocations appear in either order and may repeat, so the decode
  accumulates rather than expecting a fixed sequence. `push ecx` reserving a
  slot and `push ebx` saving a register are the same instruction.
- A frame larger than a page uses a 16-byte stack-probe loop carrying its page
  count as an immediate (plus 4 bytes for the EAX it saves).

### x86 calling convention (synthetic calls)

Delphi's 32-bit `register` convention: the first three arguments travel in
**EAX, EDX, ECX** in declaration order; the rest go on the stack. No shadow
space, no 16-byte alignment requirement. The result comes back in EAX.

The stack **order** was measured, not read: documentation disagrees with itself
here. `PrologProbe` compiled an eight-parameter routine with `dcc32` and found
A/B/C spilled to EBP−4/−8/−12 (the register three) and the rest at D=+24,
E=+20, F=+16, G=+12, H=+8. H sitting closest to the return address means H was
pushed **last**, so stack arguments are pushed **left to right** — the opposite
of cdecl. Laying the frame out by hand, argument *i* of *n* lands at
`[ESP + 4 + 4*(n-1-i)]`.

### Argument placement, and why the seam carries a kind

Measured with `DevTools\Win32FloatArgProbe`, which reports each parameter's
offset from EBP under `-$O-` (negative = spilled from a register, positive =
passed on the stack):

```
IntDoubleInt(A: Integer; B: Double; C: Integer)
    A    EBP-8    REGISTER
    B    EBP+8    stack
    C    EBP-12   REGISTER
```

- **A parameter takes one of EAX/EDX/ECX only if it fits 32 bits AND is not a
  float.** Everything else goes on the stack and consumes *no* slot, so ordinals
  declared after it keep taking registers: `C` above, declared third, still gets
  the *second* register. `Int64` and `Currency` behave exactly like floats here.
- **Stack widths are not uniform:** `Single` 4, `Double` 8, `Int64` and
  `Currency` 8, `Extended` **12** (10 bytes padded to a 4-byte boundary).

Hence `IDebugTarget.RunMethodCall` carries `ArgKinds: array of
TSyntheticArgKind` rather than a plain "is it a float" Boolean. On x64 the kind
only chooses the register file — every argument occupies one 8-byte slot by
position — so that side is unchanged. On x86 it decides both whether the
argument competes for a register and how many stack bytes it occupies, and the
placement runs as two passes: register slots to the ordinals in declaration
order, then the stack in declaration order with the first argument at the
*highest* address.

`Extended` travels through the seam as **Double bits**, because that is all an
8-byte `ArgValues` slot can carry; the x86 placement widens it to 80 bits.

**Known limitation:** the kind is derived from the *calling expression's* type,
not the callee's *declared parameter* type, which the debug info does not
surface. Passing `0.25` (typed `Double` by the evaluator) to a `Single`
parameter is therefore still wrong — and was equally wrong on x64 before any of
this. Integer literals are typed `Int64` for storage, so `TExprValue.IsIntLiteral`
marks them and a literal that fits 32 bits is passed as an ordinal; without that,
`Foo(3)` put a 4-byte ordinal parameter on the stack as 8 bytes and the callee
read a register that was never set.

### x86 return values: EDX:EAX and the x87 stack

A 64-bit integer result comes back in **EDX:EAX**, which
`ReadSyntheticCallResult` combines into `IntResult`. Putting the EDX half into
the high 32 bits of a 32-bit result is harmless — it is exactly what x64 does
with the upper bytes of RAX, and every consumer masks by the declared type.

Float results come back on the **x87 stack**, which no thread context exposes:
the WOW64 context reports FP state as of the last WOW64 transition, not the
live stack, so ST(0) reads back as a reset image no matter which context flags
are requested. The engine therefore returns the synthetic call into a small
**capture stub** planted in the debuggee:

```
DD 35 <abs32>   fnsave  [scratch]     ; 108-byte image; cannot fault
DD 25 <abs32>   frstor  [scratch]     ; put the debuggee's FPU state straight back
E9  <rel32>     jmp     RemoteCallTrap
```

`fnsave` was chosen over `fstp` precisely because it **cannot fault on an empty
stack**. An `fstp` stub would raise invalid-operation on an integer-returning
call, so it could only be planted when a float result is expected — and the seam
never learns what the callee returns, only which *arguments* are floats. The
unconditional stub removes that requirement entirely: the saved FNSAVE tag word
says whether ST(0) was occupied, and when it was not, the float slot stays zero
and the result is read as an integer one.

**The trap in reading that image:** the tag word is indexed by **physical**
register number (via TOP), but the saved register **area** is in **stack order**
with ST(0) always in the first slot. Scaling the register offset by TOP reads
ST(7) and yields a plausible wrong number.

#### Return encodings differ per type, and the formatters expect the x64 ones

Measured with `DevTools\Win32FloatAbiProbe` (32-bit; build it with
`DevTools\build_one32.bat`, since `build_all.bat` is a dcc64 sweep): on Win32
**every** float-family type returns in ST(0) — `Currency` included, where Win64
instead returns a scaled `Int64` in RAX. `Currency` arrives already **scaled**
(19.95 comes back as 199500.0).

The value formatters in `ExprEval.AsDouble` read three different raw encodings —
a `Single` as its 4-byte pattern, a `Currency` as the scaled `Int64` it divides
by 10000, everything else as `Double` bits. Since the x86 engine converts the
80-bit register to `Double` bits on the way out, two of those have to be undone.
`TExprEvaluator.NormaliseFloatReturn` does it in one place, called from **both**
return sites (`ApplyMethodCall` and `InvokeGetter`) because a property
expression resolves through the first of those on x86 and the second on x64.
Skipping it does not produce an error — a `Single` reads as 0 (the low half of a
`Double` that narrows exactly is all zeroes) and a `Currency` as a trillions
figure.

### No x86 parameter home slot

`CurrentFrameParamHomeAddr` returns 0 (its documented "unavailable") on x86, and
that is not a gap to be filled with a positional formula. The first three
parameters have no stack home at all, they are spilled to **negative** EBP
offsets, and stack parameters run in **reverse** declaration order — `Self` is
provably not at `EBP+8`. The answer has to come from debug-info symbol offsets.

### Declared scope limitation

Win32 locals and parameters are supported for **`-$O-` builds only**. `-$O+`
omits the frame pointer routinely, and without it the EBP-relative offsets in
debug info have nothing to anchor to.

### MAP segment tables and the target's pointer width

Delphi prints the MAP segment-table `Start` column at the **target's** pointer
width: 8 hex digits for PE32, 16 for PE32+.

```
0001:00401000          .text   CODE     (PE32)
0001:0000000000401000  .text   CODE     (PE32+)
```

Body addresses in a MAP are segment-relative and must be rebased **per
segment** (`LinearStart − ImageBase` for that segment), never by a flat
constant. A derived base is trustworthy because it can be checked: it must equal
the `VirtualAddress` of the PE section with the same name — with `.tls` the
known exception on both platforms (its MAP `Start` is not that section's
`VirtualAddress`; on a 32-bit build it is 0, i.e. below the preferred base, so
the segment stays unregistered). `DevTools\MapSegBaseProbe.dpr` performs exactly
that identity check.

Assuming one width is not a loud failure. `ParseSegmentTableEager` sliced a
fixed 16 characters, so on a PE32 MAP the slice ran past the address into the
next column, failed the hex test, and **every** segment line was skipped —
leaving `FSegmentBaseRvas` empty. All three consumers read that dictionary with
`TryGetValue` defaulting to 0, so nothing raised: every emitted RVA silently
degraded into a bare segment offset, which landed inside a neighbouring function
and made the MAP report a different source file than TD32 for the same address.
The parse now scans the hex run and accepts 8 or 16 digits terminated by
whitespace or end of line. `MAP_SIDECAR_MAGIC` was bumped `MIX2` → `MIX3` at the
same time: sidecars written by an earlier build baked `MinRva` values computed
from an empty segment table and must not be reused.

`ReadPEPreferredBase` must read the right field for the right magic: PE32+ keeps
`ImageBase` at optional header `+$18` as 8 bytes, PE32 at `+$1C` as 4 bytes
(PE32+ widened the field and dropped the preceding `BaseOfData`). Falling back
to a hardcoded `$400000` for PE32 is not harmless — a module with a non-default
preferred base then gets every segment base wrong, and a runtime BPL is exactly
where that arises.

## Threading model

Two threads run inside the adapter:

1. **Main / debug thread** — owns the `TWinDebugger` instance, calls
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

That thread is **kept and joined**, not detached. `TRsmFile` and `TMapFile` both
used to start it with `TThread.CreateAnonymousThread(...).Start` and drop the
reference, so the worker outlived nothing in particular — including the object
whose dictionaries, critical section and mapped view it was writing. The
destructor freed all three while the worker was inside them.

That surfaced as an intermittent `Invalid pointer operation` during teardown, in
`FreeingASession_TerminatesWhatItLaunchedOnBothBitnesses`: it errored once in a
full suite run and then passed 6/6 in isolation, because in isolation the parse
finishes before the session is freed. Freeing a critical section another thread
is inside is not a race that shows up reliably — it shows up when the machine is
busy, which is exactly when a user is debugging.

Both readers now keep the reference (`FIndexThread`, `FreeOnTerminate := False`)
and join it first thing in the destructor, with an interlocked cancel flag the
MAP worker checks per line so the join returns promptly instead of waiting out a
multi-megabyte scan. `TSymbolPrefetcher` already did exactly this; the two file
readers did not. A re-load also joins before starting a second worker.

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

`TWinDebugger.ProcessOneEvent`:

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

**A breakpoint on `begin` is moved to the body** (`BreakpointBodyRva`). A
routine's `begin` line resolves to its ENTRY address, where the prologue has not
yet spilled `Self` or any by-register parameter — so every local read there
returns the CALLER's frame bytes, correctly typed and flagged as nothing.
Measured on a parameter the caller passed as 1234: without the move it reads 99
on x64 and 13023708 on x86. The destination is the first address inside the
routine whose line record differs from the entry's — the same boundary
`FunctionBodyStartVA` derives for the step-into pivot, but taken from the line
table alone, because this runs before the image base is known and a 32-bit
target has no `.pdata` to consult. A routine whose body shares the entry's line
record (a one-liner, a frameless `asm` body) has no such address and is left at
the entry rather than guessed past.

**Planting is duplicate-safe.** Two source lines can resolve to one address (and
the move above maps `begin` onto the first statement). A second plant would read
the `$CC` the first wrote and save THAT as its original byte, so unplanting
would restore a breakpoint instruction and leave the target trapping forever at
an address no breakpoint owns. `PlantInt3` adopts the first planter's original
byte and skips the write.

### Address breakpoints (DISASSEMBLY_PLAN.md increment 5)

A second breakpoint IDENTITY alongside `(SourceFile, Line)`: `(ModuleName, Rva)`,
where `ModuleName` is the friendly lowercase file name (`''` reserved at the
ENGINE layer only, for the main exe — see the trap below) and `Rva` is the
offset from THAT module's own base, resolved once from the caller's absolute
address against `TDebugSession.GetModules` (the same table `disassemble`'s
symbolication already uses).

- `TBreakpointKind` (`bkSource` / `bkAddress`) on both `TBreakpointRec`
  (engine) and `TSessionBreakpoint` (session), defaulting to `bkSource` so
  every pre-existing code path is unaffected.
- **Refuse, never plant unresolved.** An address inside a module that is not
  currently loaded cannot be attributed to anything and is refused outright
  (`Verified=False` + a reason) — unlike a source breakpoint, there is no
  "register now, plant later" pending state for an address breakpoint.
- **Rebind on reload reuses the source-breakpoint mechanism's SHAPE, not its
  code.** `TDebugSession.RepostAddressBreakpoints` (called from
  `SetAddressBreakpoint`, `RemoveAddressBreakpoint`, `HandleDllLoaded` and
  `HandleDllUnloaded`) re-derives `Verified`/`Address`/`Message` against the
  CURRENT module table and reposts each affected module's whole address-bp
  set to the engine (`ckSetAddressBreakpoints` → `TWinDebugger.
  DoSetAddressBreakpoints`, which mirrors `DoSetBreakpoints`: clear this
  module's existing address breakpoints first, then resolve the module's
  LIVE base — `FImageBase` for `''`, `FDllBases` otherwise — and plant, or
  drop the whole spec silently if the module cannot be resolved right now).
- **Module unload needed no new engine code.**
  `TWinDebugger.HandleUnloadDll`'s existing VA-range unplant sweep is
  kind-agnostic and already removes an address breakpoint's plant when its
  module unloads; only the SESSION-level `Verified` flag needs updating
  (`HandleDllUnloaded` → `RepostAddressBreakpoints`), because the identity
  `(ModuleName, Rva)` survives the unload and rebinds on the next load of
  the same module name — proven with `TestPackage.bpl`'s existing
  `--reload-package` load/unload/load lifecycle (`AddrBp_Bpl_UnloadReload_
  Rebinds` in `DebuggerTests\DebugSessionTests.pas`).
- **Trap: the main-exe module-name sentinel differs between layers.** The
  ENGINE's own convention for "the main exe" is `''` (`FDllBases` is
  populated only for runtime-loaded DLLs/BPLs by `HandleLoadDll`, never for
  the main exe, whose base comes from `FImageBase` instead — checked
  separately everywhere else in the engine). The SESSION's `GetModules`
  names the main exe by its real lowercase filename instead, for sensible
  reporting. `TDebugSession.EngineModuleNameFor` is the ONE translation
  point between the two conventions, used wherever a `TAddrBpSpec` is built
  for the engine. Missing this translation resolves the address FINE at the
  session layer (`Verified=True`) while the engine silently drops the plant
  — caught by the first positive test in this increment, not by inspection;
  full detail in `DISASSEMBLY_PLAN.md` "Verified in increment 5".
- **DAP**: `setInstructionBreakpoints` replaces the WHOLE address-breakpoint
  set on every call (per the DAP spec — there is no per-file scoping for an
  instruction reference), using `FInstrBpIds` to remove exactly what the
  PREVIOUS call planted before adding the new list (mirrors `FDataBpOwnIds`'s
  role in the MCP server for data breakpoints). Capability
  `supportsInstructionBreakpoints: true` is a pure SERVER→CLIENT
  advertisement with no corresponding CLIENT-declared capability to check
  (unlike `supportsInvalidatedEvent`), confirmed against the DAP spec.
- **MCP**: `set_breakpoint_at_address` (singular ADD/idempotent-replace,
  keyed by the resolved `(module, rva)`) and `remove_breakpoint_at_address`.
  See `MCP_SERVER.md`.

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

    That `[RSP]` read is **one TARGET pointer wide** (`ReadTargetPointer`), and
    the resume-SP guard advances by `TargetLayout.PointerSize`, not a literal 8 —
    the width the matching RET pops. Reading 8 bytes on a 32-bit target splices
    the next stack word into the high half; observed in the field as a resume BP
    planted at `$5196C430B5AA25BC` (low half the real return address, high half an
    unrelated `rtl290.bpl` address), which failed to plant and let the step-over
    run free. The step-over FALLBACK path (import thunk / no function range)
    validates its return address with `IsPlausibleReturnAddress`, the same guard
    `smOut` uses, so a bad unwind degrades to single-stepping instead of patching
    an INT3 into an arbitrary byte.

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

### A rejected transient step breakpoint must be stepped OFF, not re-planted

Both the `smOver` recursion guard and its `smInstr` twin can decide that a
one-shot step breakpoint fired for someone else — a deeper recursive incarnation
returning to the very same address, or another thread. The breakpoint has to stay
armed, and the obvious move (plant the INT3 straight back and resume) does not
work: the hit handler has already restored the original byte and rewound the PC
onto that address, so the thread re-traps on the same instruction the instant it
resumes, forever. Measured as an unbounded `BP hit / PlantInt3 OK` loop in
`%TEMP%\dap_adapter.log` while building instruction stepping; the identical
defect was latent in the source-level `smOver` guard and is fixed with it.

`RearmStepBpAfterForeignHit` does the dance a persistent breakpoint hit already
does: re-add the record UNPLANTED, set `FPendingReactivateVA` / `FReactivateTid`,
arm the trap flag, and let the re-arm path plant it after one step.
`FSteppingOffStepBp` marks that trap as one that DECIDES NOTHING, so the re-arm
path resumes the in-flight step untouched instead of letting `HandleSmOverStep`
(or the instruction step) read it as progress.

## Instruction granularity (ASSEMBLY_LEVEL_DEBUGGING.md increment 1)

`smInstr` is a mode of its own, not a flag on `smInto`/`smOver`: those terminate
on a new SOURCE LINE, and the code instruction stepping exists for has no line
table at all. The engine surface is
`IDebugTarget.StepInstruction(Kind, ThreadId, out RefusalReason): Boolean` with
`TInstructionStepKind = (iskInto, iskOver, iskOut)`, mirrored by
`TDebugSession.StepInstruction`. No DAP or MCP surface yet — increments 2 and 4.

**Two phases, because the two constraints pull apart.** A refusal has to be
synchronous (the caller must learn "this cannot be stepped exactly" rather than
wait for a stop that never comes), but `ContinueDebugEvent` must be called from
the thread that called `WaitForDebugEvent`. So the REQUESTING thread decides —
read-only: registers, `ReadCodeMemoryAt`, `CallerReturnAddress` — and produces a
`TInstrStepPlan`; the Run thread executes an already-decided plan through
`ckStepInstruction` and decides nothing. The plan is `UseTrapFlag` (one trap-flag
step) or a `ResumeVA` to run to, plus `MinResumeSP`.

**The rules:**

- `iskInto` — one trap-flag step, landing wherever it goes including inside a
  callee.
- `iskOver` — the same, except for an instruction that must not be single-stepped:
  a `call`, and a `rep`-prefixed string instruction. Both run to a one-shot
  breakpoint at PC + the DECODED length, which is exact because the disassembler
  just produced it.
- `rep` is completed as a whole by `iskInto` TOO. A trap-flag step at a
  `rep`-prefixed instruction traps once per ITERATION and leaves the PC exactly
  where it was (measured, both bitnesses), so "one instruction" would appear not
  to advance and a caller looping until it does would take one stop per byte
  moved. A string move has no callee, so nothing is lost.
- `iskOut` — `CallerReturnAddress` (`.pdata` on x64, `[EBP+4]` on x86 — the seam
  already exists) filtered through `IsPlausibleReturnAddress`, then a one-shot
  there. Where neither can prove an address it REFUSES; unlike source `smOut` it
  never degrades to single-stepping, which has no terminating condition without a
  line table.
- Everything refuses when the disassembler backend is unavailable, quoting
  `IDisassembler.StatusText` — including `iskOut`, which decodes nothing itself:
  a surface where two of three kinds refuse and the third silently works is a
  worse contract than one sentence. There is no fallback decoder in this project
  and an instruction length is never guessed; bytes that do not decode are
  refused too.

**Reused rather than reinvented:** `FStepOverVA` holds the resume address,
`FStepResumeSP` the stack-pointer guard, and `PlantStepBp`/`ClearStepBps`/
`FreezeThreadsForStep` are the same one-shot and per-thread machinery source
stepping uses. The one-shot is thread-scoped twice over — every other thread is
frozen for the duration, and `InstrStepLandedAt` re-checks the thread AND
requires `RSP >= MinResumeSP` (the RSP at decision time for a call/rep, since
call+ret nets to zero; plus one target pointer for a step-out, the minimum the
matching RET pops). Without that, a recursive callee returning to the same
address one frame deeper ends the step at the right instruction in the wrong
incarnation.

**Classification comes from the decoder's own mnemonic text** (`call`, `rep` /
`repe` / `repz` / `repne` / `repnz` as the leading token), the same discipline
`ZydisDisassembler`'s direct-branch whitelist already applies — nothing
re-derives from raw bytes what the decoder was asked to produce. The decode goes
through `ReadCodeMemoryAt`, so an instruction carrying one of our own planted
INT3 bytes decodes as the user's opcode rather than as `int3`. The disassembler
is built lazily per engine instance (mode from `TargetLayout.PointerSize`, no
symbolication — stepping needs lengths, not names) and can be replaced through
`SetInstructionDisassembler`, which is how a test injects an unavailable backend
without touching the process-wide one-shot Zydis load latch.

**Watchpoints are handled by the existing DR6 branch, unchanged**: a slot bit
without `BS` while `FStepMode <> smNone` is recorded and resumed, so a watchpoint
firing inside a stepped-over call cannot be reported as the instruction step
completing.

### Instruction granularity (DAP) — increment 2

`supportsSteppingGranularity: true` (`HandleInitialize`). `next` / `stepIn` /
`stepOut` each check `arguments.granularity` first
(`TDapServer.WantsInstructionGranularity`, an exact case-insensitive match on
`"instruction"` — absent, `"statement"`, or `"line"` all take the untouched
pre-increment-2 path). A match routes to `HandleInstructionStep`, which maps
the command to the engine's `TInstructionStepKind` (`next` → `iskOver`,
`stepIn` → `iskInto`, `stepOut` → `iskOut`) and calls
`TDebugSession.StepInstruction` — the SAME facade `DebuggerTests\
InstructionStepTests.pas` drives directly, increment 1's engine primitive,
unmodified.

**Threading stays exactly as increment 1 required.** `ProcessRequest` — and
therefore every `Handle*` method, including `HandleInstructionStep` — runs on
the adapter's single request-processing loop (`TDapServer.Run`), the same
thread `HandleStackTrace` already calls dbghelp from. `TDebugSession.
StepInstruction`'s decision phase (decode, refuse, or choose trap-flag vs
one-shot) is synchronous and read-only, so it executes inline on that thread;
only an ACCEPTED plan crosses to the Run thread (`ckStepInstruction`), exactly
as increment 1 built it. No third thread was introduced.

**A refusal reaches the client as a failed request, not a silent no-op.**
This is the point of doing the call BEFORE answering, unlike the pre-existing
`HandleNext`/`HandleStepIn`/`HandleStepOut`, which send `success: true`
unconditionally and only THEN attempt the (fire-and-forget, always-succeeds)
source-level step. `HandleInstructionStep` calls `StepInstruction` first; a
`False` result sends `FIO.SendErrorResponse(Seq, Cmd, RefusalReason)`
(`success: false`, `message: RefusalReason`) and returns without touching
`FSession` state or emitting a `stopped` event. The one refusal reliably
reachable from OUTSIDE the process (a real DAP client, not the engine test
harness) is "not running" — `HandleInstructionStep` checks `FLaunched` itself,
matching the idiom every other stop-dependent handler already uses
(`HandleStackTrace`, `HandleDisassemble`, `HandleSetVariable`), before
`TDebugSession.StepInstruction` would in any case refuse the same way with its
own message (`FDebugger = nil`). The other two increment-1 refusal reasons
are NOT reachable through the DAP wire protocol: `StepThreadFromArgs` folds
any `threadId` that does not match a live thread back to 0 ("the currently
stopped thread"), so a bogus DAP thread id can never reach the engine's
"thread is not live" refusal; and there is no launch-config knob to force the
Zydis backend unavailable from outside the process (only the in-process
`SetInstructionDisassembler` seam `InstructionStepTests.pas` uses). Both
remain fully covered at the engine level.

Test coverage: `DebuggerTests\InstructionStepDapTests.pas` (mono fixture,
`InstructionStepSample.exe`/`.map`/`.rsm` — the same fixture increment 1
built). See `TEST_CATALOG.md`.

### Registers and instruction stepping (MCP) — increment 4

**Registers.** `TMcpServer` (`MCPDebugger\McpServer.pas`) adds `get_registers`
and `set_register`, going through the exact session-level path DAP's
`Registers` scope (`REGISTERS_VAR_REF` in `DapServer.pas`) has used for a long
time — `TDebugSession.GetRegisters` / `SetRegister`, which themselves call
`IDebugTarget.GetRegisters` / `SetRegisterByName`. No second read/write
mechanism was introduced; the MCP tools are a thin JSON frontend over the same
facade, gated on `FSession.State = dsStopped` the same way every other
stop-only MCP tool is (`get_call_stack`, `get_locals`, ...) even though the
underlying session call degrades quietly (an empty array) rather than refusing
on its own — the explicit gate is what turns that into a readable refusal
instead of an empty, ambiguous result.

`McpJson.RegisterToJson`/`RegisterListToJson` format each register as
`{name, value, size}`, `value` a variable-width hex string (`'0x' +
IntToHex(Value, 1)`), the same convention `DisasmInstructionToJson` and
`DataBreakpointToJson` already use for addresses — never a bare JSON number,
since a 64-bit register does not fit an IEEE double without loss. `size` is 8
for the 64-bit registers, 4 for `EFlags`. `set_register` parses its `value`
argument with the MCP-local `ParseAddress` helper (the same `"0x.."`/`"$.."`/
decimal parsing `read_memory`/`write_memory`/`disassemble`/
`set_breakpoint_at_address` already share — a plain string, not
`DebuggerCore`'s `TryStrToUInt64Lit` DAP happens to use for the same job, so
no cross-project dependency was added for it), then calls
`FSession.SetRegister` and re-reads the register from a fresh
`FSession.GetRegisters` call to build the response, so the response proves the
write reached the thread context instead of merely echoing the request back.
An unrecognised name is refused (`isError:true`, `"Unknown register
\"<name>\"."`), never silently ignored — matching `TWinDebugger.
SetRegisterByName`'s own case-insensitive name set (`RIP`, `RSP`, `RBP`,
`RAX`..`RDI`, `R8`..`R15`, `EFlags`).

Bitness note, measured not assumed
(`GetRegisters_Win32_MatchesRipAndZeroExtendsUpperRegisters`): on a WOW64
target `TWin32Debugger.ReadThreadRegisters` (`WinDebuggerX86.pas`) reads
`Wow64GetThreadContext` and never sets `R8`..`R15` (`TRegisterSnapshot` starts
zeroed), so `get_registers` reports them as literal `"0x0"` — not fabricated,
not omitted, exactly what the engine has.

`SetRegisterByName` originally had NO WOW64 override — resolved in
`ASSEMBLY_LEVEL_DEBUGGING.md` increment 6, which is the authoritative writeup
(what was measured, both outcomes considered, why Outcome 1 was taken even
though the round-trip defect turned out not to reproduce at a real stop —
only R8..R15 did). Summary: `TWin32Debugger.SetRegisterByName` now overrides
the base with `Wow64Get/SetThreadContext`, using the same name vocabulary
`ReadThreadRegisters` reports (`RIP`/`RSP`/`RBP`/`RAX`..`RDI`/`EFlags`), and
refuses `R8`..`R15` outright (no logical register exists on x86 at that
width). DAP's `setVariable`-on-`Registers`-scope path shares the identical
fix, proven by a dedicated test file (`RegisterWriteDapTests.pas`) — the two
surfaces do not diverge.

**Instruction-granularity stepping** is a `granularity` argument
(`"statement"`, default; `"instruction"`) on the EXISTING `step_over`/
`step_into`/`step_out` MCP tools, not a fourth `step_instruction` tool — see
`ASSEMBLY_LEVEL_DEBUGGING.md` increment 4 for why that shape was chosen over a
separate tool. `TMcpServer.HandleStepTool` is the single dispatch point all
three funnel through: an unrecognised `granularity` value is refused
(`isError:true`) before anything else runs; `"instruction"` calls
`TDebugSession.StepInstruction` (Kind = `iskOver`/`iskInto`/`iskOut` per
tool, the SAME 1:1 mapping increment 2's `HandleInstructionStep` uses) and
only arms the async wait (`ArmWait`) when it returns `True` — exactly
increment 2's "decide before answering" ordering, and for the analogous
reason: `step_over`/`step_into`/`step_out` were fire-and-forget before this
(they always succeed at the source-level), so a refusal has to be surfaced
explicitly rather than read as a wait that silently never resolves.
`"statement"` (default or explicit) is the pre-existing fire-and-forget
`FSession.StepOver`/`StepInto`/`StepOut` call, untouched.

**RED control that mattered**: the naive negative control for the `step_out`
Kind mapping — reverting the dispatch so `granularity` is never read — does
NOT fail `StepOut_Instruction_LandsInTheCaller`, for the identical reason
`TASK_RESUME.md` already recorded for the DAP version of this same test in
increment 2: in this non-recursive fixture scenario the pre-existing
STATEMENT-level `step_out` also lands correctly in the immediate caller (same
`FStepOverVA`/`FStepResumeSP` one-shot machinery `iskOut` reuses), so
disabling the granularity check alone changes nothing observable. The valid
control, proven instead: swap the `Kind` passed to `HandleStepTool` for the
`step_out` tool from `iskOut` to `iskInto` — the step then stays inside the
callee, and the "landed in caller" assertion fails on both bitnesses.

Test coverage: `DebuggerTests\McpE2ETests.pas` (registers + stepping
sections), reusing increment 1's `InstructionStepSample.exe`/`.map`/`.rsm`
fixture for the stepping tests. See `TEST_CATALOG.md`, section Q.

## Stack walking

Uses `StackWalk64` with `dbghelp.dll`'s `SymFunctionTableAccess64` /
`SymGetModuleBase64`. The machine type comes from the virtual
`StackWalkMachineType` (`IMAGE_FILE_MACHINE_AMD64`, or
`IMAGE_FILE_MACHINE_I386` for a WOW64 target — see "Target architecture"); the
seed context comes from `FillStackWalkContext`. Everything below describes the
x64 path, where dbghelp does the unwinding; on i386 it contributes nothing and
`StackWalk64`'s own frame-pointer chain carries the walk. `SymInitialize` is
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

### The walk is a seam; x86 chains EBP

`TWinDebugger.WalkRawFrames` yields the raw `(PC, FramePtr)` pairs and
`GetStackFrames` symbolicates them. Separating the two lets a target
architecture replace the unwind strategy without touching the (identical)
source/function/line resolution that follows.

- **x64** drives StackWalk64. `.pdata`/UNWIND_INFO is exact, and dbghelp's
  context copy carries the unwound RBP each frame's BPREL decode needs.
- **x86** chains the frame pointer directly: `[EBP+4]` is the return address and
  `[EBP]` the caller's EBP, because `mov ebp,esp` runs BEFORE the frame
  allocation. Phase 0 concluded from a synthetic target that dbghelp's i386
  unwind was good enough; the field disproved it. Debugging a design-time
  package inside `bds.exe`, dbghelp returned `0x14FF318` — a **stack address** —
  as the caller of a Delphi frame, fabricating a bogus frame and losing the real
  caller, so the join into the VCL frames was junk. The same defect made
  step-over hang until `CallerReturnAddress` started reading `[EBP+4]`.

Every x86 link is validated, never trusted: the return address must be
executable code inside a known module, and the next frame pointer must be
4-byte aligned, strictly ABOVE the current one (the stack grows down) and within
1 MB of it. The chain genuinely does end — system DLLs are routinely built with
the frame pointer omitted — so when it dies at depth ≤ 1 the walk asks the
inherited StackWalk64 and appends what it offers.

"Inside a known module" means the debugger's OWN module table, built from the
`CREATE_PROCESS` / `LOAD_DLL` debug events, not dbghelp's. On a WOW64 target
dbghelp claims no module for the 32-bit `kernel32`/`ntdll`, so asking it refused
every OS return address and truncated the stack at the last framed Delphi
routine. That behaviour was recorded for a while as an inherent i386 limitation.
It was not: measured on Hydra2, the EBP chain walks straight through the OS
frames once the module test stops lying.

Both consumers of dbghelp output — the tail splice below a verified join, and
the "chain produced nothing, take dbghelp's answer" path — go through one
routine that applies the same validation. They did not: the second copied
dbghelp's array verbatim, checked by nothing, which is where the fabricated
frame below the OS tail was coming from. Frame provenance is carried on every
frame (`TFrameOrigin`, printed by `LiveSessionProbe` as `origin=`) precisely so
that question is answerable by measurement rather than by inference; three
earlier fixes were aimed at the wrong producer.

### Proving a stack word is a return address (x86)

One x86 path cannot use the chain at all: when execution is inside a routine's
prologue the frame is not established yet, so `[EBP+4]` belongs to the CALLER
and the walk yields a single frame. Delphi makes this ordinary rather than
exotic, because a constructor's compiler-generated preamble is already
attributed to the routine's first source line. The pushed return address is
still near the top of the stack, so the walker probes a small window above ESP.

That probe is only sound if it can tell a live return address from any other
code address lying on the stack, and the test for that is exact:

- `X86Decode.CallSiteEndsAt` decodes FORWARD from a known instruction boundary
  and reports whether a boundary lands on the candidate with a `call` ending
  there. x86 is not self-synchronising, so reading backwards cannot answer this.
- The boundary comes from the line table (every line record starts an
  instruction), restricted to the routine that contains the byte **before** the
  candidate — which is where the instruction ENDING at the candidate lives. The
  routine entry is the fallback when the module has symbols but no lines.
- That `-1` is load-bearing. Anchoring on the routine containing the candidate
  itself has no answer when the candidate IS a function entry: no boundary
  exists before it inside its own routine, so the verdict came back
  `csaUndecidable` and the frame was kept unproven. Measured on Hydra2, the
  impossible frame below the OS tail was exactly that case — the entry of the
  program's main block, whose preceding byte is a `ret`.
- Only addresses inside the MAIN image are judged at all. RVAs are relative to
  it, so an address in any other module would become a meaningless offset that
  can land on an unrelated routine of the executable; refusing outright is what
  keeps the OS frames undecidable, and therefore kept.
- Three outcomes, and only `csaYes` accepts. `csaUndecidable` is deliberately
  distinct from `csaNo`: an opcode the decoder does not know, or a span it
  cannot resolve, must never be read as "not a call".

The earlier version scanned a few bytes backwards for a call-shaped encoding.
It accepted the address Delphi pushes with `push offset @@finallyHandler`, and
the recovered frame named the right routine while pointing at its `finally`
block — a wrong frame is worse than a missing one, because every frame on
screen looks equally real.

### Raw stack scan (opt-in)

`IDebugTarget.GetRawStackFrames` / `TDebugSession.GetRawStackScan` sweep a
thread's whole stack for words that could be return addresses. Nothing calls
them from the ordinary walk, and their results are never merged into it.

Why, given that the walk is exact: **the exact walk stops**. On i386 there is no
unwind data, so when the chain reaches a routine built without a frame pointer
there is nothing left to follow. Truncating is the right answer to "what is the
call stack"; it is the wrong answer to "which of my routines is underneath
this", which is the question a bug report actually asks.

How it differs from the JCL/madExcept equivalent: those accept a word if it
points at executable memory, which any function pointer, VMT slot or dead frame
satisfies. Here every candidate goes to `CallSiteVerdictAt`, and `foRawProven`
means the instruction ending at that address was **decoded** and is a `call`.
The boundary to decode from comes from the line table, so the modules the user
builds — including their BPLs — get proven answers. Foreign code with no line
table comes back `foRawUnproven` and is reported rather than dropped, because
dropping it loses the shape of the chain.

What stays unknowable is **liveness**. A return address left by a call that has
already returned still sits in the popped frame and still decodes as
call-adjacent; nothing distinguishes it from a live one without the frame chain
that is missing by assumption. Measured on the recursion fixture, the sweep
returns the live chain *and* `InitUnits` / `@StartExe` / `TObject.Create` from
unit initialisation, which finished long before. So the sweep reports where
return addresses ARE, `FrameRBP` is 0 throughout (no locals can be read off a
position), and `TFrameOrigin` carries the distinction to the frontend so it
cannot be lost by accident.

Cost is bounded: the stack extent comes from the target's memory map (one
allocation, walked upward while the allocation base holds — no TEB needed),
reads are 64 KB at a time, module containment is a binary search over a sorted
snapshot, page protection is cached per region, and the sweep caps at 4 MB and
logs when it does. Each sweep logs its size, hit count and duration.

Measured on Hydra2 (real 32-bit multi-BPL ERP client), the sweep surfaced
`QBFCreateForm` in `qbfd29.bpl`, four DevExpress routines in `cxlibraryrs29.bpl`
and `CheckSize` / `CMVisibleChanged` in the executable — user code the walked
stack did not show.

**DAP surface.** `"rawStackScan": true` in the launch/attach config appends the
sweep BELOW the walked frames — appended, never interleaved, so the real call
stack still reads top-to-bottom. Each appended frame is marked twice, because
either marker alone can be lost: the name is prefixed `[raw]` (decoded as a
call) or `[raw?]` (no line table to decode from), which survives a copy-paste
into a bug report, and `presentationHint: "subtle"` greys the row. Default off:
a user who has not asked for the sweep must never see a position sitting next
to a real frame. Raw frames go into the same `FLastFrames` array so a `frameId`
still indexes one list; selecting one is harmless because its `FrameRBP` is 0,
so locals come back empty rather than decoded off an unrelated frame.

**Toggling it mid-session.** The flag used to be read once, at launch, so
reaching for the sweep meant editing `launch.json` and restarting — losing the
very stop that motivated it. The custom request `delphiSetRawStackScan`
(`{"enabled": bool}`, or no argument to toggle) flips it in place and echoes the
resulting state in its response body, so a client labels its button from what
the adapter did rather than from what it assumed. VS Code caches the call stack
and will not re-request it because a setting changed, so an `invalidated` event
(`areas: ["stacks"]`) follows — sent only to a client that declared
`supportsInvalidatedEvent`, and only while stopped. The extension binds this to
a Call Stack title-bar button whose confirmation restates, every single time,
that raw entries are POSITIONS on the stack rather than callers.

One trap this uncovered: `NearestInstructionBoundaryBefore` had been bounded to
the main image. RVAs are a single space anchored at the main image and every
module's provider registers inside it, so that bound made code in a runtime
package permanently undecidable — and the user's own code mostly lives in
packages. Containment is decided by whether a provider owns the address; an
address none covers (kernel32, ntdll) still fails `RvaToFunctionStart` and stays
undecidable, which is what preserves the OS tail.

### Recovering a caller the chain stepped over (x86)

A FRAMELESS routine between two framed ones is invisible to the chain: it never
pushed EBP, so the link from its callee steps straight over it to its caller.
What goes missing is not the frameless routine — its PC is still reported, as
the return address its callee saved — but the FRAMED CALLER above it, whose own
return address nobody stored. `TStringList.CustomSort` is exactly this shape:
stopped in a comparer the RTL calls back into, the routine that started the sort
was absent while every frame on screen was real. dbghelp does not know the frame
either, so there is nothing to defer to.

The walker recovers it by identifying the routine from the other side and then
confirming it on the stack — three conditions, all required:

1. the frame ABOVE the gap sits at the return address of a call; if that call is
   DIRECT, its target names the missing routine exactly (an indirect call names
   nothing, and the hole is left alone);
2. the missing routine's own return address is one of the stack words the chain
   skipped, and `CallSiteEndsAt` PROVES which word follows a call;
3. the match must be UNIQUE — two candidates mean decline.

Measured on the RTL-callback fixture, the recovered x86 stack is now identical
to the x64 one frame for frame, including the caller's line number (79, the
call site) rather than 81 (the `finally`), which is what the first, unsound
attempt produced.

Validation is empirical, against ground truth the binaries already carry: every
line-table address is an instruction boundary, so decoding must land on each one
(`DevTools\X86DecodeProbe.exe`).

Scale mattered. Over 9 940 routines and 70 476 spans there were zero unknown
opcodes — and that was misleading. A 497 MB production binary (393 124 routines,
2 354 868 spans) surfaced 61, of which one was a genuine gap rather than data:
the Athens RTL emits **AVX**, so `System.Move` opens `C5 FC 10 08`
(`vmovups xmm1,[eax]`) and ends `C5 F8 77` (`vzeroupper`). Refusing there would
blind the walker inside one of the most-stepped routines in any program. VEX is
now decoded — the prefix changes the opcode map and the operand size, never the
modrm/SIB/displacement/immediate structure that determines LENGTH, so the
existing maps are reused and any form outside them still refuses.

The remaining unresolved spans (0.28 % at scale) are DATA in the code stream:
the exception-handler table after `jmp @HandleAnyException`, and the jump table
of every large `case`. No linear decode can cross either, and there the decoder
reports undecidable. That is why the probe reports counts rather than a verdict:
adding coverage lowers unknowns without raising broken spans, whereas a WRONG
length desynchronises and raises them — which is how the VEX work was confirmed
(6 528 → 6 502 broken).

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

### Placeholder source for a frame with no source file (DAP)

Naming such a frame is not enough. A DAP `stackFrame` with **no `source` at all**
gives the client nothing to open, so a stop in sourceless code is
indistinguishable in the editor from no stop at all: the debug view does not come
forward, no editor appears, and the only sign the target stopped is that it went
quiet. Reported from the field on a design-time package session, where the IDE
stopped at `0x76549F54 (kernelbase.dll: no symbols)` and the editor did nothing.

Every frame that would otherwise carry no `source` now gets one built on a
**`sourceReference`** rather than a path (`TDapServer.AttachPlaceholderSource`),
with `presentationHint: deemphasize` (the client greys it and keeps it out of
recent files — it is a diagnostic, not a file the user opened) and `origin` set
to the module. The `source` request (`HandleSource`) returns a generated document
that names the address, the module and the function, states plainly that the
debugger IS stopped there, and spells out which of the four
`TSymbolAvailability` reasons applies together with what to do about it.

References are minted per frame LABEL and reused (`FSynthSourceRefs` /
`FSynthSourceTexts`), so the client can cache content and a long session does not
mint a reference per stack request. They start at 1 because 0 means "use the
path".

MCP needs no equivalent: it has no editor to drive, and it already reports
`module` + `symbols` on every frame.

Pinned by `Test_SourcelessFrame_HasPlaceholderDocument`, which uses the parked
worker thread (`Sleep(INFINITE)`, so the bottom of its stack is always
ntdll/kernel32) and fails loudly if no sourceless frame is present rather than
passing vacuously.

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

The read width per local comes from `LocalReadSize` (`DelphiValueReaders`),
which distinguishes genuinely 8-byte types from pointer-sized ones; the latter
take the TARGET's pointer size, so a pointer local on a 32-bit target reads its
own 4-byte slot instead of that slot plus its neighbour.

`FrameSize` is read by disassembling the prologue (`ReadPrologInfo`, virtual —
the x86 decoder is described under "Target architecture"). On x64:
- `55 48 83 EC NN`               → `NN` (frame < 128)
- `55 48 81 EC NN NN NN NN`      → `imm32`
- a frame larger than a page inserts a fixed 22-byte stack-probe loop between
  the pushes and the real `sub rsp`, which the matcher steps over after
  verifying its signature at the expected offsets.

`ReadPrologInfo` also reports whether the prologue was **understood**, and all
four callers are obliged to check it. A failed match used to return zero, which
is indistinguishable from a function with no locals, so every address derived
from the frame size was silently wrong rather than absent. "No frame
recognised" now means refuse: the parameter home slot returns its documented
"unavailable" 0, the parent-frame walk stops, and `CollectLocalsForFrame`
reports no locals. This matters beyond large frames — a pure-`asm` routine that
never names a parameter compiles without a frame at all while debug info still
lists the parameter, and the RTL is full of them.

The offset bases (`LocalsOffsetBase` / `ParamsOffsetBase`) are virtual too: the
x64 anchors below exist because its frame pointer is established after the
allocation, and they are 0 on x86.

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

#### A member lookup stays scoped to its receiver

`ApplyDot`'s step 4 resolves a nested-proc parent local (`ComputeNested.X`) by
looking the LEAF name up on its own, because there is no receiver in that form —
`ComputeNested` is a routine name.

That step must not run when there IS a receiver, or `Obj.Member` and a bare
`Member` become the same query. Measured on a live VCL form,
`Self.HandleAllocated` and `HandleAllocated` both answered 1362375204 with no
type: the VCL method name also exists as a symbol, so the leaf lookup found it
and read it as data. `Self.Perform` did the same, and it is the same mechanism
that made `Application.Title` answer with code bytes. The user is shown a number
about an object that has no such member.

It is now gated on the base being a class instance. `ComputeNested.X` keeps
working because a routine name is not one. A RECORD base is not covered yet — it
is not a class instance either, so it still reaches the leaf lookup. Asserted by
`MemberLookup_DoesNotFallBackToAGlobalOnBothBitnesses`, which also checks a real
member still resolves, so the guard cannot degenerate into a blanket refusal.

#### A callable reports its ADDRESS, not the code at it

Step 5 may legitimately land on a CODE address: a routine referenced by name is
in an executable page and is the symbol the user asked for. The resolver already
distinguishes that from a mis-match — it accepts a code-resident hit only when
the address is a FUNCTION ENTRY, which a data global's address never is.

What it then reports has to differ, because a callable is not a variable: there
is nothing at its address to read as a value, only its machine code. Reading it
anyway produced, measured on a real 32-bit VCL application, `VCL` = 1796744703
(`FF 25 18 6B`, the start of an import thunk) and, in the test target on both
bitnesses, `0xEC834855` (`push rbp; sub rsp`) and `0x55EC8B55`
(`push ebp; mov ebp,esp`). Prologues presented as values, with nothing marking
them.

The address is reported instead, typed `Pointer`. Nothing is inferred: the
branch is only reached once the resolver has established the symbol is a
function entry and that no data candidate exists. Asserted by
`ProcedureName_ReportsItsAddressNotItsCodeOnBothBitnesses`.

#### A typeless global reads only its own bytes

Step 5 can also resolve an address with no TYPE, which is what a release build
gives — a detailed MAP and no embedded debug info. With no type there is no
width, and the fallback read a full pointer's worth, folding the following
globals into the value: on the `MapOnlyGlobals` fixture a `Byte` holding 5 read
back as -1091589627 on both bitnesses.

The read is bounded by the distance to the next symbol (`ISymbolExtentProvider`,
answered by the MAP). That is a fact rather than an estimate — two symbols
cannot overlap — and it only ever narrows, so a known type still decides the
width. The query blocks on the publics parse on purpose: an answer that depended
on whether a background thread had finished would make the VALUE depend on
timing.

**The same rule on a MEMBER (`ExprEval.ApplyDot`).** `Obj.M` with no
parentheses is a call too, and for a long time it was not treated as one: a
member that matched no property (path 1), no field (path 2) and no RSM class
member (path 3) fell through to the qualified-name lookup, which found the
METHOD'S OWN CODE ADDRESS and read it as data. `W.GetSelf` returned
`0x83EC8B55` on Win32 and `0xEC834855` on Win64 — the `push ebp; mov ebp,esp`
and `push rbp; sub rsp` of `GetSelf` itself — and every chain built on it
(`W.GetSelf.Name`) inherited the garbage. Path **3c** now calls a member whose
declared parameter list is EMPTY, using `TryGetMethodParams` as the guard, so a
method that takes arguments is still never auto-called. Properties and fields
resolve first, so a member sharing a method's name is unaffected. Pinned by
`Test_Eval_ParameterlessMethod_NoParens_IsCalled`.

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
`TWinDebugger.SetStringVariable`, which:

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

The calling convention and the event pump are separate concerns, and only the
first is architecture-specific:

- `PrepareSyntheticCall` marshals the arguments, lays out the stack and points
  the thread at the callee; `ReadSyntheticCallResult` reads the result from the
  thread that has just hit the return trap. Both are virtual — the x86 versions
  are described under "Target architecture".
- Everything between them is shared, because it is architecture neutral: the
  abort-on-raise path, the watchdog, the skip-and-single-step handling for
  planted breakpoints hit inside the injected call, and `EXIT_PROCESS`.

Arguments across the boundary are **positional** (`Arg0..Arg3`, `IntResult`,
`FloatResultLow`). The earlier signature announced the physical register each
argument lands in, which is the implementation's business and is simply false on
Win32.

`RunRemoteCall(FuncVA, Arg0, Arg1)`:

1. Lazy-allocate a single-byte `0xCC` trap page (`FRemoteCallTrap`).
2. Save full thread context.
3. Build a Win64 ABI call frame (`PrepareSyntheticCall`, x64):
   - `RSP := (saved.RSP and not 15) - 40` — 16-byte aligned + 32 bytes
     shadow space + 8 bytes return address. RSP at callee entry must
     be `8 mod 16`.
   - Write the trap address at `[RSP]` so the callee's `RET` jumps to
     our trap.
   - `RIP := FuncVA`, `RCX := Arg0`, `RDX := Arg1` (floats to XMM0..3;
     arguments five onward at `[RSP+40]`).
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

## Hardware watchpoints and the single-step branch

A hardware data breakpoint hit is delivered as a SINGLE-STEP exception —
`$80000004`, or `$4000001E` under WOW64 — which is the same event the whole
sequence above consumes. The exception code cannot separate them; `DR6` can, and
nothing else can:

- `B0..B3` name the slot(s) that fired;
- `BS` (bit 14) says the trap flag caused this trap;
- both are set when one instruction did both.

`TWinDebugger.TakeDebugTrapCause` is the FIRST thing the branch does, before the
trap flag is cleared and before any other state is touched — on WOW64 the slot
bits do not survive an intervening `Wow64SetThreadContext`. It reads `DR6`, masks
it (the reserved bits read back as ones), and writes zero back, because the CPU
never clears `DR6` itself.

The branch then behaves as follows:

- no slot bit → exactly the pre-existing path, and while no slot is armed the
  register file is never opened at all, so stepping costs what it always did;
- a slot bit without `BS` → a watchpoint fired while the target was running free.
  It is recorded (`HardwareWatchpointHitCount` / `LastHardwareWatchpointHit`) and
  resumed; the stepping engine never sees the event, and any in-flight step is
  left to its own resume breakpoint;
- a slot bit with `BS` → one instruction both completed our step and tripped the
  watchpoint. The hit is recorded and the step is allowed to complete.

Arming is `ArmHardwareWatchpoint(TID, Slot, Address, SizeBytes, WriteOnly)`,
which REFUSES a bad slot, an unsupported size, an 8-byte watch on a 32-bit
target or a misaligned address rather than rounding it — the hardware ignores the
low address bits, so a rounded request would silently watch a neighbouring cell
and report success. The DR7 bit maths is architecture-neutral and lives once in
`TWinDebugger`; only the register access is behind the funnel.

### Data breakpoints: the request flows

Complete as of 2026-08-08; the full record of what was measured and what was
deliberately not built is in `DATA_BREAKPOINTS_PLAN.md`.

**`dataBreakpointInfo`** (adapter: `HandleDataBreakpointInfo`; engine:
`TDebugSession.GetDataBreakpointInfo`). The client sends a `name` plus either
the CONTAINER's `variablesReference` (what VS Code does from the Variables
tree) or a `frameId`. A container reference carries no frame, so the Locals
scope resolves against `FLastScopeFrameId` — the frame the `scopes` request was
last made for, which is the same frame the following `variables` request
resolves against. The session tries a literal address, then a LOCAL of that
frame, then a global, derives the watch width from the declared type, and
returns either a `dataId` or a refusal with the reason in `description`.
Refused (never guessed): a register-allocated local, a frame with no frame
pointer, a type with no 1/2/4/8 width, a misaligned address, the Registers
scope, and an expansion handle (an object/record field — the expander answers
in values, not addresses).

`accessTypes` is `["write","readWrite"]` and never contains `read`: x86/x64 has
no read-only watchpoint, so listing one would advertise a filter that cannot be
applied. `canPersist` is `false` for a frame-scoped local and `true` otherwise.

**The `dataId` is adapter-private and self-contained**, because
`setDataBreakpoints` sends nothing but the id and an access type, and VS Code
persists data breakpoints across sessions:

- `d1|g|<size>|<name>` — a global by NAME, re-resolved at set time;
- `d1|a|<size>|<module>|<rva>` — an address as module+RVA (bare VA outside every
  image), so it survives a rebased package;
- `d1|l|<size>|<nonce>|<tid>|<base>|<entry>|<addr>|<name>` — a frame-scoped
  local, stamped with a per-run nonce so an id from a previous process is
  refused by name instead of re-armed at whatever now lives at that address.

**`setDataBreakpoints`** (adapter: `HandleSetDataBreakpoints`) is a whole-set
replace, which is exactly what `TDebugSession.SetDataBreakpoints` already was.
Entries that fail to decode, and `accessType:"read"`, are answered per entry
without being sent to the session. The whole request is refused per entry while
the target is RUNNING — arming touches live thread contexts — rather than
letting the session refuse everything with one sentence, which would make
already-armed watchpoints look newly broken.

**Frame lifetime.** A local's address is a stack slot. `TDataBpSpec` carries
`TDataBpFrameScope` (thread + frame base + function entry VA), and
`TDebugSession.PruneStaleDataBreakpoints` runs at EVERY stop — the only moment
a stack is readable — walking the owning thread RAW (`GetStackFrames(Tid)`: no
symbolication, no trim, no cache write) for a frame matching that pair. Gone →
the slot is cleared, the watchpoint dropped, and `OnDataBreakpointRemoved`
fires; the adapter turns that into a Debug Console line and a `breakpoint`
removed event. `ArmOneDataBreakpoint` runs the same test, so the client's next
whole-set replace cannot put it back. One case is undetectable by construction
and is documented rather than guessed at: the same routine re-entered at the
same stack depth reproduces the same frame identity, so the watchpoint follows
the same local of a new invocation — it can never drift onto a different
variable.

**The stop.** `srDataBreakpoint` maps to DAP reason `"data breakpoint"`, with
`description`/`text` = `expr: $old -> $new (thread N)`. The reason case was
missing until increment 6, which made a watchpoint stop arrive with no `reason`
at all — the DAP twin of the `McpJson.ReasonName` gap increment 5 fixed.

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
| `supportsDataBreakpoints`               | true  |
| `supportsInstructionBreakpoints`        | true  |
| `supportsDisassembleRequest`            | true  |
| `supportsSteppingGranularity`            | true  |
| `supportsReadMemoryRequest`             | true  |
| `supportsWriteMemoryRequest`            | true  |
| `supportsProgressReporting`             | true  |

Anything else is currently absent (function breakpoints, `modules`,
`setExpression`).

## Known assumptions and limits

- Multi-thread aware. Every live thread is reported (`threads`), any thread's
  stack + locals/watches are inspectable read-only at a stop, and step
  over/into/out act on the selected thread while the others are frozen (see
  "Stepping" and `PROJECT_STATE.md`). Synthetic-call evaluation still runs on the
  stopped thread (frame-independent, so it needs no per-thread targeting).
- Both x64 and 32-bit (WOW64) targets are supported from the same 64-bit
  adapter binary; the class is chosen from the target's PE header (see "Target
  architecture"). On a 32-bit target, locals and parameters require a `-$O-`
  build, and a synthetic call refuses float arguments rather than approximating
  them.
- `.rsm` is the only source of local/global variable metadata; if it
  isn't present, locals/globals scopes are empty but stepping and
  source mapping still work via `.map`.
- `FrameSize` derivation relies on the standard Delphi prologue. JIT
  or hand-rolled native code without `push rbp; sub rsp, NN` will
  return `FrameSize = 0` and the locals readout will be wrong for
  that frame.

## Mechanisms recovered from the task journal (2026-08-08)

Facts that lived only in `TASK_RESUME.md` until it was cut back to a cursor. Each
was measured when it was written; none is restated elsewhere in this document.

### Target architecture and pointer width

- **One 64-bit adapter binary debugs both x64 and WOW64 x86 targets, and the
  two-binary alternative was rejected on a concrete constraint**: the MCP server
  is registered once at editor startup with a fixed command, long before any
  target exists, so it cannot pick a per-bitness binary. Two binaries would force
  an IPC proxy for no gain. `Win64Debugger.pas` was renamed `WinDebuggerBase.pas`
  alongside `WinDebuggerX86.pas`; the repository, extension and MCP names are
  deliberately unchanged.
- **Host and target pointer size are different things, and on x64 every site that
  conflates them is correct by accident.** Five such sites were found, each in a
  different layer: `LocalReadSize` (stack locals), `SyntheticLocal` (expanded
  fields), `PrimTypeSize` and `SizeForKind` (ExprEval), and — the worst —
  `GetClassProperties`' walk of the published-RTTI records, which disabled live
  RTTI entirely on x86 while still returning plausible values through the
  debug-info fallback. **A wrong pointer width rarely fails loudly**: three of the
  four degraded into a fallback or a plausible number rather than an error. Assume
  any remaining one is currently invisible.
- **Exception readers are pointer-width sensitive.** `Exception.FMessage` is the
  first field after the VMT pointer, so offset 4 on Win32 and 8 on Win64;
  `VMT -> TypeInfo` is at -72 (Win32) / -168 (Win64); `ParentInfo` follows at
  `+PointerSize`, not a literal `+8`. All of it must go through
  `ReadTargetPointer` / `TargetLayout.VmtTypeInfo`.
- **One root cause, four symptoms**: `FExceptionObjAddr` is published ONLY when the
  exception-class read succeeds, so any failure of that read also removes
  `$exception` from the evaluator AND leaves exception-TYPE filters nothing to
  match.

### Stack walking

- **`NearestInstructionBoundaryBefore` must not be bounded to the main image.**
  RVAs are one space anchored there and every module registers inside it, so the
  bound made runtime-package code permanently undecidable — and the user's own
  code mostly lives in packages. Separately: when the candidate IS a function
  entry there is no boundary before it, so the decode must anchor on the routine
  containing the byte BEFORE the candidate. That decode proves `ret`, not `call`,
  and correctly rejects the fabricated frame.
- **On a 32-bit target `StackWalk64` can return frame 0's PC SIGN-EXTENDED to 64
  bits** (`$B5C34A23` -> `$FFFFFFFFB5C34A23`), matching no module and losing the
  source line — even when the adapter had already resolved the stop correctly.
  Frame 0's PC is therefore re-anchored to the authoritative seed PC,
  symbolication follows `Frame.IP` rather than `SF.AddrPC.Offset`, and a 32-bit
  frame address above 4 GB stops the walk. Why dbghelp sign-extends is NOT
  root-caused; the fix is to stop asking it for a value already held exactly.

### Evaluation and the synthetic call

- **Member access through an interface reference is exact, not heuristic.** Debug
  info emits no member list for an interface, and the reference addresses a field
  INSIDE the object; the containing object is recovered by walking back to the
  first candidate with a valid VMT whose instance size REACHES the reference
  address. Only the containing object can cover that address (`cfbc3ad`).
- **x87 capture stub, the trap that cost three wrong conclusions**: the FNSAVE tag
  word is indexed by PHYSICAL register, but the saved register AREA is in STACK
  order with ST(0) always FIRST. Multiplying the register offset by TOP reads
  ST(7). The tag word only reports whether ST(0) was occupied; if not, the float
  slot stays zero and the call is read as an integer one (`IntResult` = EDX:EAX).
- **The x87 stack does NOT leak across synthetic calls — do not "fix" it.** The
  `fnsave`/`frstor` capture stub restores the callee's state including the
  un-popped result, but `RunMethodCall` saves the thread context with
  `CONTEXT_FULL` / `CONTEXT_FLOATING_POINT` before the call and restores it after
  reading the result (`WinDebuggerBase.pas:3277` / `:3335`). On a WOW64 thread that
  is the same physical x87 stack. Measured: 12 consecutive float evaluations, all
  correct.
- **Win64 parameter home-slot address for the current frame** =
  `RBP + subRspN + extraPush + 16 + 8*paramIndex` (the same anchor
  `ReadParentFramePointer` uses). For a method, `Self` is ABI slot 0 and declared
  parameters start at slot 1.
- **A small POD record return (<= 8 bytes) is packed in RAX under the Win64 ABI**,
  not returned through the hidden var-out slot. Routing every record through the
  hidden slot yields a bogus zero AND shifts the user arguments by one, so return
  handling must be size-routed.
- **`AnsiString` / `UTF8String` decoding must read the code page from
  `TStrRec.codePage`** (a Word at `Ptr-12`). Using the system ANSI code page gives
  mojibake for any string whose code page is not the default.
- **Set-typed variables are byte-granular.** `setVariable` must write exactly the
  provider-reported size — 3, 5, 6 and 7 bytes are real — through a little-endian
  byte loop. A `case 1,2,4` store plus a packing table that rounds 3 -> 4 writes
  wrong bytes into the debuggee and corrupts the neighbouring variable.
- **Variant-array expansion** reads the `varArray` header, enumerates bounds in
  USER declaration order, and caps enumerated elements at 1024 (verified against
  `Arr1D=[10..50]` 1-D and `Mat[1,1]=1.5` / `Mat[2,3]=7.25` 2-D).
- **Evaluate warm-up is scope-bounded, and Delphi has NO transitive uses**: a bare
  identifier's visibility is exactly the frame's unit plus its DIRECT uses.
  `DebugInfoSet.ScopeUnitsForFrame(FrameRva)` returns that set, and
  `DapServer.WarmupUsesScopeForFrame` loads only the modules owning those units
  (`Module.ContainsSourceFile`). On a miss with a known scope the identifier is
  REJECTED as out of scope — no brute-force sweep. The all-modules
  `WarmupSymbolProvidersForEvaluate` runs only when no uses graph exists for the
  frame, and is still O(N) over eligible modules: a launch config naming a module
  in a shared BPL output directory WITH PREFETCH DISABLED still hits the 7-55 s
  worst case (prefetch is off by default).

### Symbol loading and the prefetcher

- **`TRsmFile` does NOT implement `IFunctionNameProvider`** — only
  `TD32FileReader`, `MapFileReader` and `JclDebugReader` do. Frame NAMES are
  therefore gated on `EnsureModuleTD32/Map/Jcl` having run for that module (~157 ms
  of synchronous TD32 per module, lazily at the stop). The `.idx` sidecar governs a
  different symptom: locals and types arriving late.
- **TD32 in a monolithic exe PHYSICALLY CONTAINS the rich data long assumed to be
  RSM-only**: enum info (kind 3 names, sets kind 6 with base type), full class
  member lists with offsets including non-RTTI members, `Result` locals for every
  getter (the return ABI), and the parent-class hierarchy. TD32 is already
  front-inserted as Primary in `FMemberProviders` / `FEnumProviders`. The NO_RSM
  gaps were routing and fidelity problems, not missing data.
- **Accepted narrow prefetch hole**: a breakpoint SET WHILE THE TARGET IS RUNNING,
  in a module whose prefetch the worker has already started, does not bind on that
  call — the sweep declines rather than waits, and publication is held until the
  next stop, where the drain repost binds it. Modules owning a breakpoint at their
  `LOAD_DLL` event are unaffected (the eager gate loads them synchronously and
  `EnqueuePrefetch` then skips them).

### Session and MCP behaviour

- **MCP `launch_debuggee` FORCES stop-at-entry by design.** The session Run loop
  pumps debug events continuously, so breakpoints must be set while the process is
  parked at entry, before `continue_and_wait`, or the target races past them.
- **Ownership in `TDebugSession`**: `FMap` / `FTD32` / `FRsm` are
  `TInterfacedObject` instances owned by `FDebugInfo` through ARC. The destructor
  must NOT free them.
- **`FindBreakpointByVA` cannot become a VA -> index hash map**: it returns a LIST
  INDEX used for `FBreakpoints[idx]` mutation and `.Delete(idx)`, and every
  per-step one-shot delete shifts indices. Any O(1) lookup must key on identity,
  not position. Descoped as not worth the refactor risk below ~100 breakpoints.
- **Pre-attach gate rule** (`ProcessEnum.CanDebug`): an x64 host accepts BOTH x64
  and x86 (WOW64) targets; ARM64 is refused as UNVERIFIED, which is a different
  claim from impossible. Demanding that the target match the debugger's
  architecture wrongly reported every 32-bit process as not attachable while the
  engine attached to them perfectly well. Pinned by
  `Json_Wow64Target_IsAttachableFromAnX64Debugger`.
- **`QueryFullProcessImageNameW` and `PROCESSOR_ARCHITECTURE_ARM64` are not
  declared in this Delphi's `Winapi.Windows`** and are imported manually in
  `ProcessEnum`, following the pattern already in `DapServer.pas`.
- **Provider-interface GUIDs share a prefix differing only in the last suffix**;
  the last allocated is `...0013` (`ISourceFileListProvider`) and the NEXT FREE is
  `0014`. A duplicate makes `Supports` hand back the wrong vtable silently — a
  `...0011` clash with `IThreadLocalNameProvider` wrote a `TArray` result through
  the address of a `Boolean` and errored 13 tests far from the cause.
  `TProviderInterfaceTests.ProviderInterfaceGuids_AreUnique` pins pairwise
  distinctness; its list is hand-maintained.
- **`get_source_files` contract**: `ISourceFileListProvider` + `TSourceFileEntry`
  (`DebugInfoTypes.pas`), implemented by `TTD32FileReader` (`Complete` always true)
  and `TMapFile` (`Complete` mirrors `FIndexReady` — the unit-section index IS the
  "Line numbers for" set). Exposed through `TModuleSymbols.SourceFileList`,
  `TModuleSymbolLoader.MainSourceFileList` (the exe sits outside the runtime module
  registry, so it needs its own) and `TDebugSession.GetModuleSources`. Only
  ALREADY-LOADED formats are queried, so enumeration never stalls a session parsing
  a 500 MB sidecar.
- **The extension's hover-provider registration must stay guarded**: an editor of
  the VS Code family lacking `registerEvaluatableExpressionProvider` would throw
  out of `activate()` and lose the DEBUG TYPE with it. The JS tests under
  `install/local.delphi-win64-debug/test/` are run by
  `install/extension-tests/run.bat`, which the release procedure calls.
