# Disassembly and address breakpoints — plan

Status: **increment 2 landed, not committed** (2026-08-08). This document is the
agreed design; `PROJECT_STATE.md` carries only the one-line roadmap entry
pointing here.

Two features that share one prerequisite and are therefore planned together:

1. **Disassembly** of arbitrary target memory, exposed over MCP and DAP.
2. **Breakpoints at an address**, not only at a source line — which is what makes
   a disassembly view actionable rather than decorative.

## Why

The debugger today answers only in source terms. That is enough while the target
carries debug info, and it is nothing at all in the case that matters most here:
a frame inside a runtime package built without symbols (`vcl290.bpl` and friends
in the Hydra2 runs), where the stack shows an address and a module and stops.

Concrete uses, each already met in this project:

- naming what a symbol-less frame is doing;
- diagnosing a failed synthetic call (odd prologue, pure `asm` body, IMT thunk);
- validating the hand-written prologue decoders, which are checked today by
  reading `DumpFunc.exe` output by eye;
- the raw stack scan reports `proven` — "the instruction ending here was decoded
  as a call" — without being able to show WHICH call.

For an agent driving the MCP server the case is stronger, not weaker: raw bytes
from `read_memory` are not readable, and hand-decoding them produces a
confident wrong answer, which is the failure mode this project refuses
everywhere else.

## Coverage decision: complete, therefore a library

An earlier draft of this plan scoped the decoder to "what dcc32/dcc64 and the
RTL emit". **Rejected.** The requirement is to disassemble code that did not come
from a Delphi compiler — hand-written `asm`, MSVC-built DLLs, OS code, JIT'd or
injected code. A hand-written subset would reach ~80 % quickly and leave the tail
plausibly wrong.

A complete hand-written x86/x64 disassembler (VEX/EVEX, AVX-512, APX) is a
project in its own right. So: an external library.

### Chosen: Zydis (`zyantific/zydis`, MIT)

| candidate | licence | coverage | verdict |
|---|---|---|---|
| **Zydis** | MIT | x86/x64 complete through AVX-512 (APX in recent versions — VERIFY) | **chosen** |
| iced (`icedland/iced`) | MIT | complete, richest instruction metadata, round-trip validated | best output, but Rust: needs a `cdylib` + C FFI shim and a Rust toolchain in the build |
| Capstone (`capstone-engine/capstone`) | BSD-3 | x86/x64 + ARM64 + others | only if one dependency must also cover ARM64; larger, heavier API |
| XED (`intelxed/xed`) | Apache-2.0 | the authoritative one (Intel's own) | **as a test oracle, not shipped** |
| distorm3, BeaEngine, udis86 | — | x86/x64 | maintenance stalled or thin. Rejected |

Zydis over iced is an integration call, not a quality call: on real compiled code
the text output of the two will agree almost everywhere, while Zydis is C (a DLL
and a `cdecl` import) and iced would add a Rust toolchain to a build that is
"install Delphi, run a `.bat`". Zydis is also the disassembler inside x64dbg,
i.e. proven under exactly this load — Windows, PE, real code.

iced's advantage that would genuinely matter here is its `InstructionInfoFactory`
(per-operand register/memory access, flags read/written, control-flow category).
It is not claimable anyway, because the one path that would use it — proving a
call site — must stay free of native dependencies. See "X86Decode stays".

### ONE DLL, x64 only

The machine mode is a DECODER PARAMETER (`ZYDIS_MACHINE_MODE_LEGACY_32` vs
`ZYDIS_MACHINE_MODE_LONG_64`), not a separate build. The adapter is a single
64-bit binary that already debugs both bitnesses, so it disassembles 32-bit code
with the same x64 DLL. Roughly 0.5 MB, shipped once.

(A 32-bit DevTools probe would need a 32-bit DLL. Build such probes as x64.)

## Dependency layout

```
ThirdParty\Zydis\
  zydis.submodule\        git submodule on zyantific/zydis, pinned
  bin\x64\Zydis.dll       committed binary, reproducible from the submodule
  bin\x64\Zydis.dll.sha256
  LICENSE                 MIT, copied for redistribution
  PROVENANCE.md           tag + commit hash, MSVC version, CMake flags, date, builder
  build_zydis.bat         regenerates the DLL from the submodule (needs CMake + MSVC)
DebuggerCore\ZydisApi.pas import unit — NOT a full header translation
```

Rationale per item:

- **Submodule pinned** — provenance and byte-for-byte rebuildability. Without it
  the committed DLL is a blob taken on trust.
- **DLL committed** (approved by the maintainer 2026-08-08) — `build_all.bat` and
  `build_dap.bat` stay Delphi-only. `build_zydis.bat` is run by whoever bumps the
  dependency, never by whoever builds the project.
- **`ZydisApi.pas` minimal** — import only what is used (`ZydisDisassembleIntel`,
  `ZydisGetVersion`). A small surface is less to repair across library versions.
- **Explicit `LoadLibrary`, never a static import.** Missing or mismatched DLL
  (checked at load via `ZydisGetVersion`) means the feature reports UNAVAILABLE;
  the rest of the debugger must not notice. A static import turns an optional
  feature into an adapter that does not start.
- **Fail-closed output**: an instruction Zydis cannot decode renders as
  `db XX XX`, never a guess — the same exact-or-nothing contract `X86Decode.pas`
  already has.
- **Packaging**: the DLL sits next to `VisualStudioCodeDelphiDebugger.exe`;
  `install\Install.exe` and the extension folder need one entry each. The MIT
  licence text ships with it.
- `.gitattributes`: `*.dll binary`.

## Validation: measure the coverage, do not claim it

"Complete coverage" is a claim, and this project measures claims. With a single
disassembler there is no way to know where it is wrong.

Differential test in `DevTools`: feed the same bytes to Zydis and to an
independent oracle (XED, and/or `dumpbin /DISASM`, which is already on the
machine), over real binaries — the exe, its packages, the RTL — and report every
divergence. Each divergence is a bug in one of the two and gets looked at.

The precedent is `X86Decode`: zero unknown opcodes over 70 476 spans, which
looked like proof, then 61 over 2 354 868 spans, one of them a real gap (AVX in
`System.Move`). Sample size was the whole story.

## X86Decode stays

`DebuggerCore\X86Decode.pas` is NOT replaced. It has a different contract (exact
instruction LENGTHS, 32-bit, no dependencies) and lives in the raw-stack-scan
call-site proving path, which must not depend on an optional DLL. Zydis serves
display and inspection; `X86Decode` serves proof.

## The seam

```pascal
IDisassembler = interface
  function Available: Boolean;                 // backend loaded and version-checked
  function Disassemble(VA: UInt64; Count: Integer): TArray<TDisasmInstruction>;
end;

TDisasmInstruction = record
  VA:       UInt64;
  Length:   Integer;
  Bytes:    TArray<Byte>;
  Text:     string;        // 'db XX' when undecodable
  Decoded:  Boolean;
  Symbol:   string;        // nearest function + offset, when a provider knows one
  SrcFile:  string;        // when line info exists for this VA
  SrcLine:  Integer;
end;
```

Same discipline as `IDebugTarget`: the library must not appear outside the
backend unit. Machine mode comes from `IDebugTarget.TargetLayout` / the target's
PE machine, never from the host.

Symbolication of branch/call targets goes through the existing provider set, so a
`call` into a module with symbols shows a name and one without shows an address —
consistent with how frames already render.

## MCP surface

- `disassemble(address | frameId, count, [before])` → instructions with VA, bytes,
  text, and symbol/source when known. Explicit in the tool description: an
  undecodable instruction is reported as such, never guessed.
- `set_breakpoint_at_address(address)` / the address form of `remove`.
- Frames and raw-stack hits should carry the address they already have in a field
  an agent can feed straight back into `disassemble` — no re-parsing of display
  text.

## DAP surface

- capability `supportsDisassembleRequest`, request `disassemble`
  (`memoryReference` + `instructionOffset` + `instructionCount`), which is what
  makes the VS Code Disassembly View work;
- `instructionPointerReference` on stack frames, so "Open Disassembly View" is
  enabled from the call stack;
- capability `supportsInstructionBreakpoints` + request `setInstructionBreakpoints`
  — VS Code's own address-breakpoint channel, and the one the Disassembly View
  gutter uses.

## Address breakpoints — the design point

Today a breakpoint's IDENTITY is `(SourceFile, Line)`: `TBpSpec` carries
`SourceFile` + `Lines[]`, and `TDebugSession.SetBreakpoints` is keyed by source
file. `TBreakpointRec` already holds `VA` and `Rva`, so PLANTING at an address is
not the problem — identity and rebinding are.

Decisions:

- An address breakpoint is stored as **module + RVA**, not as a bare VA. A VA is
  meaningless across a relaunch or an ASLR-rebased package; module+RVA re-resolves
  on load, exactly like the existing deferred line binding. The user-facing input
  is still an absolute address, resolved to module+RVA at set time against the
  module table.
- An address in a module that is **not yet loaded** cannot be attributed. That is
  reported as such and NOT planted, rather than planted at a VA that will belong
  to something else later.
- Conditions, hit counts and log messages reuse the existing per-breakpoint
  machinery; nothing about them is source-specific.
- One-shot / step breakpoints keep their own internal path — they are not
  user breakpoints and must not appear in `list_breakpoints`.
- `list_breakpoints` gains the address form, and each entry states which kind it
  is. A source breakpoint that resolved to an address and an address breakpoint
  are different objects with the same plant.

## Increments (each gated on a green suite before the next)

1. **DONE, not committed (2026-08-08).** `ThirdParty\Zydis` layout, submodule
   pinned to `v4.1.1`, committed DLL, `ZydisApi.pas`, dynamic load + version
   check. No feature wired in yet — `DevTools\DisasmProbe.exe` proves the
   pipeline decodes real bytes from a real binary in both machine modes
   through the one x64 DLL. Full detail (exact build invocation, SHA-256,
   struct-layout measurement) in `ThirdParty\Zydis\PROVENANCE.md`. Full suite
   run afterward: 1081 found / 1077 passed / 0 failed / 0 errored / 4 ignored —
   exact match to baseline, as expected since nothing new is wired into any
   existing consumer.
2. **DONE, not committed (2026-08-08).** `IDisassembler` + Zydis backend +
   symbolication of the output. `DevTools\Disasm.exe`. Full detail in
   "Verified in increment 2" below.
3. Differential coverage tool vs the oracle, over the fixtures and the real
   binaries. Record the measured numbers in this file.
4. MCP `disassemble`.
5. Address breakpoints in `DebugSession` (module+RVA identity, deferred bind),
   then the MCP tool, then `setInstructionBreakpoints` over DAP.
6. DAP `disassemble` + `instructionPointerReference`.

## Traps

- The adapter builds with `-$Q+ -$R+` while DevTools and `RunTests.cfg` do not.
  Address arithmetic on debuggee-supplied values must be pinned per unit or a
  defect will exist only in the adapter.
- Reading instruction bytes across a page boundary into unmapped memory must
  truncate, not fail the whole request: a disassembly window near the end of a
  section is a normal case.
- **Planted breakpoints corrupt disassembly.** An `INT3` we wrote reads back as
  `$CC` — the disassembler must be fed memory with our own breakpoint bytes
  restored, or it will show `int3` where the user's code is. The engine already
  keeps `OrigByte` per breakpoint.
- Do not merge disassembly-derived call targets into the call stack, for the same
  reason raw stack hits are kept separate: they are positions, not frames.

## Verified in increment 1

- **Version and API shape.** Pinned `v4.1.1` (commit `a2278f1d2`).
  `ZydisDisassembleIntel` exists exactly as assumed
  (`include/Zydis/Disassembler.h`) and is exported by the built DLL, confirmed
  with `dumpbin /exports`. One surprise: `ZydisGetVersion()` reports `4.1.0.0`
  on this exact pinned commit — the `ZYDIS_VERSION` macro was not bumped for
  the 4.1.1 patch release (verified against `src/Zydis.c`, which returns the
  macro literally). `ZydisApi.pas`'s load-time check therefore compares
  major.minor only. Full detail in `ThirdParty\Zydis\PROVENANCE.md`.
- **Maintained Pascal bindings.** `zyantific/zydis-pascal` exists and is listed
  as an official binding (MIT), supporting both static and dynamic linkage. Not
  adopted: it is a full header translation of the whole API surface (the
  opposite of the decided minimal-import-unit design), and its last commit
  (2023-11-20) predates the pinned `v4.1.1` tag (2025-02-16) — it was not
  re-verified against it. `ZydisApi.pas` is hand-written, importing only
  `ZydisDisassembleIntel` and `ZydisGetVersion`.
- **One DLL, both machine modes.** Confirmed both by the CMake config (Zydis
  has no per-machine-mode build option — `ZYDIS_BUILD_SHARED_LIB` builds one
  DLL) and empirically: `DevTools\DisasmProbe.exe`, unmodified, decoded correct
  x64 code from the 64-bit `TestTarget.exe` (auto-detected `long64` from its PE
  header) and correct x86 code from the 32-bit `TestTarget.exe` (auto-detected
  `legacy32`) through the same built `Zydis.dll`.

## Verified in increment 2

- **The seam.** `DebuggerCore\Disassembler.pas` declares `IDisassembler`,
  `TDisasmInstruction`, `TDisasmMachineMode` (`dmmLong64` / `dmmLegacy32`) and
  a `TDisasmByteReader` callback (`reference to function(VA; Buf; Size):
  Integer`, returning bytes actually placed — never failing outright, so a
  short read at a boundary is the reader's own truncation contract, not an
  exception). No third-party reference in this unit.
  `DebuggerCore\ZydisDisassembler.pas` (`TZydisDisassembler`) is the only
  other unit allowed to reference `ZydisApi` — DevTools and any future
  MCP/DAP surface depend on `IDisassembler` only.
- **Memory comes through a caller-supplied reader, not `IDebugTarget`
  directly.** `IDisassembler` takes bytes from whatever
  `TDisasmByteReader` the caller wires up — a live process, a PE file on
  disk, or a test double — so the backend itself has no notion of
  breakpoints, live sessions, or file formats. Decoupling choice beyond what
  this document specified; see the two traps below for how each caller
  satisfies its side of the contract.
- **Trap 1 (planted breakpoints) — solved with a new engine primitive.**
  `IDebugTarget.ReadCodeMemoryAt(VA, Buf, Size): NativeUInt`
  (`DebugTarget.pas`, implemented once in `TWinDebuggerBase.pas` and shared
  unchanged by `TWin32Debugger`) reads like `ReadProcessMemoryAt` but restores
  any of the debugger's own planted `INT3` bytes found in the returned window
  from `FBreakpoints[].OrigByte`, and truncates at the end of the committed
  `VirtualQueryEx` region instead of failing (this doubles as trap 2's fix for
  the live-session path). This is an interface addition the plan named the
  need for ("the engine already keeps `OrigByte` per breakpoint") but did not
  specify the shape of — flagged here per the task's "STOP on an
  unanticipated design decision" instruction, decided in favour of the
  smallest addition that reuses existing engine state, matching how
  `ReadProcessMemoryAt` already sits directly on `IDebugTarget`.
  `DebuggerTests\ValueReaderTests.pas`'s `TFakeMemTarget` (the only other
  `IDebugTarget` implementer) got a trivial truncating implementation with no
  breakpoint concept, since it has no live process.
- **Trap 1, proven, not just implemented.** `DebuggerTests\DisassemblerTests.pas`
  plants TWO breakpoints on consecutive source lines of the same routine,
  stops at the first, and reads the SECOND (still-armed) breakpoint's address
  both raw (`ReadProcessMemoryAt`, must be `$CC`) and through
  `ReadCodeMemoryAt` (must be the restored original opcode) — on both
  bitnesses (`TReadCodeMemoryAtTests`, `TReadCodeMemoryAtWin32Tests`).
  Negative-controlled: with the restore loop commented out, both failed with
  `Expected [204] equals actual [204]` (`$CC` = 204) against the "must
  restore the ORIGINAL opcode" message.
- **Trap 2 (truncate, don't fail) — no shared automated fixture.** Static
  mode (`Disasm.dpr`) clamps its file read at EOF; live mode clamps inside
  `ReadCodeMemoryAt` at the `VirtualQueryEx` region boundary. Exercised
  manually (`TEST_CATALOG.md` "M. Disassembly"), not by a DUnitX test — a
  disassembly window genuinely crossing a section/page boundary is hard to
  provoke deterministically from a fixture without a purpose-built target.
- **Trap 3 (never merge into the call stack) — satisfied by construction.**
  `IDisassembler.Disassemble` returns `TDisasmInstruction`, not `TStackFrame`;
  nothing in this increment writes into `GetStackFrames` / `GetRawStackFrames`
  or any DAP/MCP stack-rendering path. There is nothing to opt out of because
  the two outputs share no type and no call path.
- **Fail-closed, proven.** `TDisassemblerBackendTests
  .Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads` points
  `TZydisDisassembler` at a DLL path guaranteed not to exist and asserts
  `Available=False`, `Disassemble` returns an empty array, AND the byte
  reader is never invoked at all (fail closed BEFORE touching memory).
  Negative-controlled: with the `if not Available then Exit` guard commented
  out, it failed with "the byte reader must never be invoked...". This is
  the ONLY Zydis-related test in the automated suite — `ZydisApi.ZydisTryLoad`
  is a one-shot, process-wide latch (first call decides the outcome for the
  process's whole lifetime), so a negative-DLL test sharing a process with a
  positive-decode test would poison the latter. The positive (real DLL,
  correct decode, real symbolication) path is proven manually via
  `DevTools\Disasm.exe`, not in `RunTests.exe`.
- **Symbolication reuses the production provider set exactly.** Both
  `Symbol` (nearest function+offset for the instruction's own address) and
  `SrcFile`/`SrcLine` go through `TDebugInfoSet.RvaToFunctionName` /
  `RvaToFunctionStart` / `RvaToSourceLine` — the same calls
  `WinDebuggerBase.pas` makes when naming an ordinary stack frame. Live mode
  hands the disassembler the session's own `TDebugInfoSet` (multi-module
  aware); static mode builds a fresh one from the file's sibling `.rsm`/`.map`
  in the same RSM-added / TD32-primary / MAP-last order
  `TModuleSymbolLoader.LoadMainModule` uses, so a standalone probe symbolicates
  the same way the adapter would for that one binary.
- **Call-target annotation needed a whitelist, not an open pattern — found by
  testing, not by inspection.** Zydis's default formatter resolves a direct
  near call/jmp/jcc's relative operand to an absolute address and prints it
  as `<mnemonic> 0x<hex>` (measured: `call 0x0000000000019F10` on x64,
  16 hex digits; `call 0x0001160C` on x86, 8 digits). An indirect form prints
  brackets or a bare register (`call [rbx]`) and never matches. The FIRST
  implementation matched any `[A-Za-z]+ 0x<hex>` and mislabelled `push 0x2A`
  (a plain immediate push, same text shape) as a resolved call target in the
  live smoke test — caught by manually eyeballing `Disasm.exe` output on
  `TestTarget.exe`, not by a unit test. Fixed with a CLOSED whitelist of every
  Zydis control-transfer mnemonic (`call`, `jmp`, every `Jcc`, the `loop`
  family) instead of an open word-class match. Missing a real branch here
  only loses one annotation (`Text` still shows Zydis's own raw address,
  which is the documented answer for an unresolved target); matching a
  NON-branch would print a fabricated symbol next to an unrelated operand,
  which the project's fail-closed rule forbids. No automated regression test
  guards this specific case (see `TEST_CATALOG.md` "M. Disassembly").
- **Sample output (`DevTools\Disasm.exe`, both bitnesses, symbolicated call
  targets):**
  ```
  $0000000000167FD8  E8 33 1F EB FF   call 0x0000000000019F10  ; _InitExe [Testtarget+0x18]  ; TestTarget.dpr:22
  $0000000000167FDD  E8 1E ED FF FF   call 0x0000000000166D00  ; RunAllScenarios [Testtarget+0x1D]  ; TestTarget.dpr:23
  ```
  ```
  $00000000000F4EA5  E8 5A 42 FF FF   call 0x000E9104  ; TWidget.Create [Testtarget+0x2D]  ; TestTarget.dpr:29
  ```

## Open, to verify before writing code

- Whether XED or iced is the more practical oracle to drive from a `.bat`
  (increment 3, differential coverage tool).

## Not in scope, deliberately

Windows ARM64. ARM64 instructions are fixed 4-byte with a regular encoding, so
disassembly is the EASY part of that port; the expensive parts are the `CONTEXT`,
ARM64 `.pdata` unwind codes, prologue analysis, AAPCS64 for synthetic calls,
`BRK #0` instead of `INT3`, and single-step via `MDSCR_EL1.SS` instead of
EFLAGS.TF — plus a natively built ARM64 adapter, since an emulated x64 debugger
asking for native ARM64 contexts is not a configuration to bet on. Choosing
Capstone today to "prepare" for it would buy the cheap part and pay for it in
size and API weight. Pick the ARM64 backend behind `IDisassembler` when a
`TWinArm64Debugger` actually exists — and first verify which Delphi version emits
Windows ARM64 and whether it emits TD32 / `.rsm` / MAP with the same structure.
