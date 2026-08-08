# Disassembly and address breakpoints — plan

Status: **increment 5 landed, not committed** (2026-08-09). This document is the
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
  **DONE, increment 4.** Shipped as `disassemble(address?, frameIndex?,
  threadId?, count?, before?)` in `MCPDebugger\McpServer.pas`
  (`TMcpServer.HandleDisassemble`) — `frameId` became `frameIndex`+`threadId`
  (see "Verified in increment 4" for why), everything else matches.
- `set_breakpoint_at_address(address)` / the address form of `remove`.
  Increment 5, not started.
- Frames and raw-stack hits should carry the address they already have in a field
  an agent can feed straight back into `disassemble` — no re-parsing of display
  text. **Already true before increment 4 started**: `McpJson.FrameListToJson`
  (used by both `get_call_stack` and `get_raw_stack_scan`) has emitted
  `"address": "0x..."` from `TSessionFrame.IP` since the raw-stack-scan work —
  no new field was needed.

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

**Resolved, not anticipated by the plan text above — the two points the task
flagged as likely STOP candidates:**

- **Identity to a client that only knows VAs.** The client-facing input and
  output are both a plain absolute address string; the module+RVA pair is
  purely an internal identity, never exposed as a separate parameter a caller
  must track. `TSessionBreakpoint` carries `ModuleName`/`Rva` for
  introspection (`list_breakpoints` reports them) and `Address` as the
  currently-resolved VA, but `set_breakpoint_at_address`/
  `setInstructionBreakpoints` take and echo only the address.
- **What happens when the owning module unloads.** Resolved by PRECEDENT, not
  by invention: `TWinDebugger.HandleUnloadDll` already unplants ANY
  breakpoint (source or address) whose VA falls in the unloading module's
  range — kind-agnostic, unchanged by this increment. The session-level
  identity (`ModuleName`, `Rva`) is NOT dropped on unload, exactly like a
  source breakpoint's `(SourceFile, Line)` spec survives a module unload in
  `FBpSpecs` today; `HandleDllUnloaded` only flips `Verified` to `False` and
  records a reason. A later `HandleDllLoaded` for the SAME module name
  reposts and replants at whatever base it reloads at — proven in
  `AddrBp_Bpl_UnloadReload_Rebinds` and the DAP/MCP mirrors of it. No live
  gutter-recolour DAP event fires on this transition (unlike the source-line
  verified-flip, which fires `OnBreakpointChanged`) — a follow-up, not a
  correctness gap: `list_breakpoints`/a fresh `setInstructionBreakpoints`
  call still report the current truth.

## Verified in increment 5

- **The engine seam.** `DebugTarget.pas`: `TBreakpointKind` (`bkSource` /
  `bkAddress`), `TBreakpointRec` gained `Kind` + `ModuleName`, `TAddrBpSpec`
  (mirrors `TBpSpec`: `ModuleName` + parallel `Rvas`/`Conditions`/
  `HitConditions`/`LogMessages` arrays, replaced as a whole per module on
  repost), `ckSetAddressBreakpoints` added to `TCommandKind`.
  `WinDebuggerBase.pas`: `TWinDebugger.DoSetAddressBreakpoints` mirrors
  `DoSetBreakpoints` — `ClearAddressBreakpointsByModule` first (identity =
  `Kind=bkAddress AND ModuleName`, so a same-named module never collides with
  an unrelated source breakpoint that happens to have `ModuleName=''` by
  default), then resolves the module's CURRENT live base (`FImageBase` for
  `''`, `FDllBases` otherwise — both already existed for other purposes) and
  plants at `Base + Rva`, or drops the whole spec silently if the module
  cannot be resolved right now. Wired into both `ProcessCommandQueue` and
  `DrainBreakpointCommands` (the latter is what plants BEFORE a freshly
  loaded module's init code can run past it, same reason source breakpoints
  need it). `TWinDebugger.HandleUnloadDll` needed NO change — its VA-range
  unplant sweep was already kind-agnostic.
- **The session layer.** `DebugSession.pas`: `TDebugSession.SetAddressBreakpoint`
  resolves the caller's absolute address against `GetModules` (same module
  table `disassemble`'s `ModuleNameForVA` already uses) to `(ModuleName, Rva)`,
  refusing outright with a reason when no loaded module owns the address;
  `RemoveAddressBreakpoint` by id. Both kinds share ONE list
  (`FBreakpoints: TList<TSessionBreakpoint>`), so `ListBreakpoints` needed no
  change to include both — `TSessionBreakpoint` gained `Kind`/`ModuleName`/
  `Rva`/`Address`/`Message`, defaulting to `bkSource` so every pre-existing
  source-breakpoint code path is unaffected. `RepostAddressBreakpoints`
  (called from `SetAddressBreakpoint`, `RemoveAddressBreakpoint`,
  `HandleDllLoaded` and `HandleDllUnloaded`) re-derives `Verified`/`Address`/
  `Message` against the CURRENT module table and reposts each affected
  module's whole set — the one mechanism that makes rebind-on-reload work,
  mirroring `RepostBreakpoints`'s role for source breakpoints exactly.
- **A real cross-layer identity bug, caught by the FIRST positive test, not
  designed around in advance.** `TWinDebugger`'s own convention for "the
  main exe" is the empty string `''` (matching `FDllBases`, which is
  populated only by `HandleLoadDll` for runtime-loaded DLLs/BPLs and NEVER
  carries an entry for the main exe — the main exe's base comes from
  `FImageBase` instead, checked separately everywhere else in the engine).
  `TDebugSession.GetModules`/`ResolveModuleForAddress`, however, name the
  main exe by its REAL lowercase filename (`TSessionModule.Name`), for
  sensible reporting. The first cut of `RepostAddressBreakpoints` sent that
  friendly name straight through as `TAddrBpSpec.ModuleName`, so
  `TWinDebugger.DoSetAddressBreakpoints`'s `FDllBases.TryGetValue('testtarget.exe',
  ...)` failed for every main-exe address breakpoint — silently: `Verified`
  came back `True` at the SESSION layer (which resolved the address fine
  against `GetModules`), the command was posted, but the ENGINE dropped it
  with nothing planted, and the target ran straight to exit.
  `AddrBp_MainExe_SetAtKnownAddress_StopsThere` failed with
  `Expected [5] but got [6] address breakpoint did not stop the target (not
  planted?)` (`5`=`dsStopped`, `6`=`dsExited`) — caught on the FIRST run of
  a brand-new test, not found later by inspection. Fixed with
  `TDebugSession.EngineModuleNameFor`, the ONE translation point (used by
  `RepostAddressBreakpoints` and `RemoveAllBreakpoints`'s address-clear loop)
  that maps the friendly main-exe name to the engine's `''` sentinel;
  `TSessionBreakpoint.ModuleName` keeps the friendly name for reporting.
  Confirms the task's own prediction that address-breakpoint identity was
  the likely place to hit something unanticipated — the unanticipated part
  was a naming-convention mismatch BETWEEN two already-existing, independently
  correct conventions, not a new design question.
- **Every new test negative-controlled**, fix reverted (or the relevant call
  site short-circuited) and the SAME test re-run to confirm it fails with the
  intended message, then reverted back:
  - `AddrBp_MainExe_SetAtKnownAddress_StopsThere` / `AddrBp_HitCondition_
    SkipsEarlyHits` — both caught the `EngineModuleNameFor` bug above
    directly (that bug WAS the negative control); reverting the fix
    reproduces `Expected [5] but got [6] address breakpoint did not stop the
    target (not planted?)` for both.
  - `AddrBp_RefusedWhenAddressNotInAnyLoadedModule` — `ResolveModuleForAddress`
    forced to always succeed: `Condition is True when False expected.
    address 0x1 must not resolve to any loaded module`.
  - `AddrBp_ListBreakpoints_ReportsBothKinds` — `FBreakpoints.Add(Result)`
    removed from `SetAddressBreakpoint`: `Condition is False when True
    expected. [the address breakpoint must be listed, Kind=bkAddress]`.
  - `AddrBp_Remove_UnplantsAndDoesNotStopAgain` — the repost call removed
    from `RemoveAddressBreakpoint`: `Condition is False when True expected.
    [after removal the target must run to exit (INT3 not cleared)]`.
  - `AddrBp_Bpl_UnloadReload_Rebinds` — BOTH `HandleDllLoaded`'s and
    `HandleDllUnloaded`'s `RepostAddressBreakpoints` calls disabled together
    (disabling only the load-side one was not enough — see "traps" below):
    `Expected [5] but got [6] address breakpoint did not re-bind and fire
    after unload + reload`.
  - DAP: the `setInstructionBreakpoints` dispatch line commented out —
    `Value 'breakpoints' not found` (the unknown-command fallback response
    has no `breakpoints` key), proving the wire-up itself, not just the
    session mechanism underneath it, is exercised.
- **The BPL fixture, where module+RVA identity earns its keep.**
  `AddrBp_Bpl_UnloadReload_Rebinds` (`DebugSessionTests.pas`),
  `Test_SetInstructionBreakpoints_Bpl_UnloadReload_Rebinds`
  (`DebuggerTests.pas`, DAP) both drive `TestPackage.bpl`'s existing
  `--reload-package` lifecycle (load #1 → BP fires, `UnloadPackage`, load #2
  → BP fires again — the same infrastructure `Test_Bpl_UnloadReload_
  BpRebinds` already proved for source breakpoints) with ONE
  `SetAddressBreakpoint`/`setInstructionBreakpoints` call made during the
  FIRST stop and never repeated: the second stop only happens if the engine
  actually rebinds, since `HandleUnloadDll`'s VA-range sweep unconditionally
  removes the plant on unload regardless of kind. Compared against the
  breakpoint's CURRENTLY resolved address (not the first stop's VA), so the
  assertion holds whether or not the reload happens to rebase the module.
- **MCP tool.** `set_breakpoint_at_address` (singular ADD/idempotent-replace
  semantics, matching the task's own naming suggestion and giving an agent
  incremental control an all-or-nothing replace would not) and
  `remove_breakpoint_at_address`, in `McpServer.pas`/`McpToolSchemas.pas`.
  `McpJson.BreakpointListToJson` gained `kind`, and the address form's
  `address`/`module`/`rva`/`message` fields (mirroring
  `DataBreakpointToJson`'s existing module+rva shape). Proven on BOTH
  bitnesses (`SetBreakpointAtAddress_UsingDisassembledAddress_StopsAgain` x64,
  `SetBreakpointAtAddress_Win32_StopsAgain` x86) using the documented
  workflow — feeding a real stop's own echoed `frames[0].address` straight
  back in, the same convention `disassemble` already established — plus a
  refusal test and a remove-unplants test. `McpE2ETests.pas`.
- **DAP `setInstructionBreakpoints` + `supportsInstructionBreakpoints`.**
  `DapServer.pas`: replaces the WHOLE address-breakpoint set on every call
  (per the DAP spec — there is no per-file scoping for an instruction
  reference), tracking the ids the PREVIOUS call planted (`FInstrBpIds`,
  mirroring `FDataBpOwnIds`'s role in the MCP server) so a shrinking set
  actually shrinks. `supportsInstructionBreakpoints: true` added to the
  `initialize` response capabilities — a pure SERVER→CLIENT capability
  advertisement; checked against the DAP spec and this codebase's own
  `supportsInvalidatedEvent` precedent, and confirmed there is no
  CLIENT-declared capability gating this specific request the way
  `supportsInvalidatedEvent` gates an event the SERVER sends, so the test
  client (`DapClient.pas`) needed no new capability flag to exercise the
  path — only a new `SetInstructionBreakpoints` helper method.
- **No DAP surface exists yet to echo a stop's raw address** (that is
  increment 6's `instructionPointerReference`), so the DAP tests read the
  exact stop address off the **Registers scope** (`RIP`/`EIP` via `scopes` +
  `variables`) instead — proven to need the SAME `"  (<decimal>)"` display-
  decoration stripping (`ExtractDisplayValue`, already used elsewhere in
  `DebuggerTests.pas`) that a rendered value carries everywhere else in this
  codebase; the first attempt (raw register `value` string) failed
  `setInstructionBreakpoints` with `invalid instructionReference:
  0x00000000740431B4  (1946431924)` before the fix. A single `NativeUInt(@Func)`
  evaluate was tried first and rejected empirically: it renders as the bare
  type name `"Pointer"`, not a hex value, through this codebase's value
  formatter — recorded here so a future increment does not re-try it.
- **Full suite**: see `TASK_RESUME.md` for the exact counts from this
  session's run.

### Traps found in this increment

- **The main-exe module-name sentinel is `''` at the ENGINE layer
  (`FDllBases` has no entry for it) but the REAL lowercase filename at the
  SESSION layer (`GetModules`).** Any new code that builds a `TAddrBpSpec`
  to post to the engine must translate through `TDebugSession.
  EngineModuleNameFor` first, or a main-exe address breakpoint resolves
  (`Verified=True`) at the session layer while silently never planting.
- **Disabling only `HandleDllLoaded`'s address-bp repost is not a sufficient
  negative control for rebind-on-reload.** `HandleDllUnloaded`'s OWN repost
  call posts a `ckSetAddressBreakpoints` command that stays QUEUED (there is
  no `DrainBreakpointCommands` call after `UNLOAD_DLL_DEBUG_EVENT`, unlike
  after `LOAD_DLL_DEBUG_EVENT`) until the NEXT `LOAD_DLL_DEBUG_EVENT` drains
  it — by which point `FDllBases` already holds the module's NEW base, so it
  plants correctly anyway. Both repost call sites had to be disabled
  together to prove the rebind mechanism is load-bearing at all. This is not
  a bug — it mirrors how a source breakpoint's repost survives the same
  unload/reload race — but it means the two call sites are NOT independently
  redundant only by accident; do not remove one assuming the other alone
  is enough.
- **An evaluated function ADDRESS renders as the bare type name `"Pointer"`
  through this codebase's value formatter**, not a hex string — `@FuncName`
  and `NativeUInt(@FuncName)` both do this. A register's OWN value (read via
  the DAP Registers scope) is the reliable way to get a real address out of
  a stop when no purpose-built address-echoing field exists yet.

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
3. **DONE, not committed (2026-08-08).** Two halves, both about honesty of
   coverage rather than new decoder features:
   - **Half A** closed the coverage hole increment 2 left: the positive
     (real-DLL) Zydis decode path and the call-target mnemonic whitelist had
     no automated regression coverage, because `ZydisApi.ZydisTryLoad`'s
     one-shot latch made a negative-DLL test and a positive-decode test
     mutually exclusive within one process. `ZydisApi.ZydisResetForTests`
     (test-only) removes that constraint. Full detail in "Verified in
     increment 3 — Half A" below.
   - **Half B** built `DevTools\DisasmCoverage.exe`, a differential sweep
     against dumpbin (chosen over XED — see "Open, to verify before writing
     code" below, now resolved) over real binaries at real scale: both
     `TestTarget.exe` bitnesses, `TestSubject.bpl` both bitnesses,
     `rtl290.bpl` + `vcl290.bpl`, and both bitnesses of a 500+ MB real
     production single-EXE build (Hydra2SingleEXE.exe). Full detail,
     including the sampling disclosure and a genuine dumpbin-scale artifact
     it surfaced, in "Verified in increment 3 — Half B" below and
     `DevTools\README.md`'s `DisasmCoverage` entry.
   - Full suite after both halves: see "Verified in increment 3 — Half A".
4. **DONE, not committed (2026-08-09).** MCP `disassemble`. Full detail,
   including the backward-disassembly decision and what it cost, in
   "Decision: backward disassembly is proven-boundary-only" and "Verified in
   increment 4" below.
5. **DONE, not committed (2026-08-09).** Address breakpoints: engine + session
   (module+RVA identity, deferred bind), the MCP tool
   (`set_breakpoint_at_address` / `remove_breakpoint_at_address`), and DAP
   `setInstructionBreakpoints` + `supportsInstructionBreakpoints`. Full detail,
   including a genuine bug the tests caught (not merely designed around), in
   "Verified in increment 5" below.
6. DAP `disassemble` + `instructionPointerReference`.
7. **Packaging — and it decides whether any of this works on a user's machine.**
   Until it is done, every increment above is a feature that reports UNAVAILABLE
   in the field while passing every test here, because the tests run out of the
   build tree where `Zydis.dll` happens to be reachable. Three parts:
   * `install\Install.exe` and the extension folder ship the DLL next to
     `VisualStudioCodeDelphiDebugger.exe`, and the MCP server build gets it too —
     `disassemble` over MCP is useless without it.
   * the MIT licence text ships with it.
   * **decide `/MD` vs `/MT`.** The committed DLL is a `/MD` build, so it needs
     the VC++ runtime installed. `/MT` removes that dependency at the cost of a
     larger DLL. A user without the redistributable currently gets a correct but
     permanently unavailable feature — which is the honest failure mode, but not
     an acceptable default.

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

## Verified in increment 3 — Half A (coverage hole closed)

- **`ZydisApi.ZydisResetForTests`** (test-only, documented as such in its own
  comment) frees the loaded module if any and clears `GLoadAttempted` /
  `GDisassembleIntel` / `GGetVersionFunc` / `GStatusText`, so the ONE-SHOT
  latch can be re-driven from a clean state. Production code never calls it;
  `ZydisTryLoad`'s one-shot contract is unchanged for every other caller.
- **`DebuggerTests\DisassemblerTests.pas`** gained three fixtures, each
  calling `ZydisResetForTests` as its OWN first statement (not relying on
  fixture setup/teardown ordering across different classes) so every test's
  outcome depends only on what IT does, never on what ran before it in the
  same process:
  - `TZydisPositiveDecodeTests` — two tests, real `Zydis.dll`, hand-picked
    byte sequences whose correct decode was already measured in increment 1
    (`DevTools\README.md`'s `DisasmProbe` entry): the x64 prologue
    `55 53 48 81 EC 98 00 00 00 48 8B EC` decodes to `push rbp` / `push rbx`
    / `sub rsp, 0x98` / `mov rbp, rsp`; the x86 prologue
    `55 8B EC 83 C4 C8 53` decodes to `push ebp` / `mov ebp, esp` /
    `add esp, 0xFFFFFFC8` / `push ebx`.
  - `TCallTargetWhitelistTests` — one test, the exact bug increment 2 found
    by hand: `push 0x2A` ($6A $2A) fed to `TZydisDisassembler` with a fake
    `IFunctionNameProvider` that answers a name for EVERY RVA (so a
    regression has something concrete to wrongly annotate with) must never
    grow a `"; <name>"` comment.
- **Order-independence, proven, not assumed.** All 6 Zydis-touching fixtures
  in the file (the pre-existing negative-DLL test, the two new positive-
  decode tests, the new whitelist test, and the two `ReadCodeMemoryAt`
  fixtures) run in ONE `RunTests.exe` process via
  `RUNTESTS_ONLY=DisassemblerTests`: 6 found / 6 passed, regardless of
  DUnitX's own execution order (not registration order — the negative test
  did not run first).
- **Negative-controlled, both fixes.**
  - `ZydisResetForTests` turned into a no-op (`Exit;` as its first
    statement): the same 6-test combined run drops to 5 passed / 1 failed —
    `TDisassemblerBackendTests.Unavailable_WhenDllMissing_DisassembleReturnsEmptyAndNeverReads`
    fails with `Condition is True when False expected. a missing DLL must
    report Available=False`, because an earlier positive-decode test in the
    same process left the latch pointed at the real DLL. This is the exact
    cross-contamination the fix removes, reproduced by removing the fix.
  - `ZydisDisassembler.pas`'s `FBranchTargetRe` reverted to the pre-increment-2
    open pattern `^([A-Za-z]+) 0x([0-9A-Fa-f]+)$`: `TCallTargetWhitelistTests`
    fails with `Condition is True when False expected. a plain immediate push
    must NEVER be annotated as a resolved call/jmp target -- 'push 0x2A' has
    the exact 'mnemonic 0x<hex>' shape a direct branch target does, and an
    open [A-Za-z]+ 0x<hex> match mislabelled it during increment 2
    development (fixed with the closed control-transfer whitelist in
    ZydisDisassembler.pas)`.
  - Both reverted back afterward; `DevTools\build_all.bat` and
    `build_runner.bat` rebuilt clean.
- Full suite (`DebuggerTests\build_and_run.bat`, run once via the
  test-runner agent): **1087 found / 1083 passed / 0 failed / 0 errored /
  4 ignored** — exact +3 delta over the increment 2 baseline
  (1084/1080/0/0/4), matching the three new tests. Both mono and BPL
  fixtures compiled and ran (parametrized into the single count).

## Verified in increment 3 — Half B (differential coverage sweep)

**Oracle: dumpbin `/DISASM:BYTES`, not XED.** XED (`intelxed/xed`) is not
installed on this machine and building it needs a Python + `mbuild`
toolchain this project does not otherwise depend on — a real cost, not a
preference. dumpbin ships with Visual Studio 2026
(`C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\
14.51.36231\bin\Hostx64\x64\dumpbin.exe`, not on `PATH` by default — reached
through `VsDevCmd.bat`, see `DevTools\run_disasm_coverage.bat`), is already
used elsewhere in this repo (`dumpbin /exports`, `PROVENANCE.md`), and is an
independent x86/x64 decoder built by a different vendor with a different
opcode table implementation, satisfying the plan's "independent oracle"
requirement.

**Methodology.** `dumpbin /DISASM` has no "decode this byte range" mode — it
disassembles an entire PE section LINEARLY with no notion of instruction
boundaries beyond its own decode, and Delphi binaries embed real DATA
directly inside `.text` (RTTI/typeinfo string literals, jump tables,
exception-handler tables), so a blind whole-image run walks into that data,
decodes garbage, and its address cursor desyncs from real code permanently.
`DevTools\DisasmCoverage.exe` anchors every span to a KNOWN instruction
boundary instead — the same idea `X86DecodeProbe` already uses for a
different purpose, extended to a second, independent decoder:

- **Line-verified spans** (when the module carries embedded TD32 debug
  info): every line-table RVA is a proven boundary, so consecutive RVAs
  within one routine bound a span whose START and END are both real code.
  Highest confidence.
- **Export-anchored spans** (modules with NO debug info at all — the shipped
  RTL/VCL packages): a PE export is a proven START, but the END is capped at
  the next export or a fixed byte budget (default 256), NOT verified, so the
  window may run into data before either decoder would stop on its own.
  Lower confidence, reported separately.

Every span's bytes are copied verbatim out of the real module and
concatenated into ONE synthetic buffer, each span followed by 20 bytes of
`$CC` (`INT3` — unconditionally a 1-byte decode as the first byte read in
both engines, so a run more than the 15-byte legal instruction-length
ceiling guarantees both decoders resynchronise to the same address by the
next span's start regardless of how far either drifted inside the span
itself). The buffer is wrapped in a minimal hand-built PE (one `.text`
section) so dumpbin has something to load; only mnemonic identity and
instruction length are ever compared, never the resolved (synthetic)
operand addresses.

**Formatting normalisation, built empirically from real divergences, not
guessed ahead of evidence** (all documented with the measured example at the
point of definition in `DisasmCoverage.dpr`): Jcc/SETcc/CMOVcc condition-code
synonyms (`sete`/`setz`, `jc`/`jb`, ...); `stosq`/`stos qword ptr [rdi]` and
the rest of the string-op family; `sal`/`shl` (genuinely the same opcode);
x87 duplicate-encoding digit suffixes (`fcomp3`/`fcomp5`/`fcomp`); legacy
8087/80287 no-op opcodes (`feni8087_nop`/`feni`, `fsetpm287_nop`/`fsetpm`);
`int3`/`int 3`; `ret far`/`retf`; `wait`/`fwait`; `aamb`/`aam`,
`aadb`/`aad`. One measured bug in this normalisation itself is recorded
below, because it was found by the tool's own first full-scale run, not by
inspection.

**Measured coverage (2026-08-08), after normalisation converged to zero
mnemonic divergences everywhere below:**

| binary | bitness | methodology | spans | positions compared | clean spans | boundary | length | refusal | mnemonic |
|---|---|---|---|---|---|---|---|---|---|
| `TestTarget.exe` | x64 | line-verified, full sweep | 1 303 | 7 812 | 100.00% | 0 | 0 | 0 | 0 |
| `TestTarget.exe` | x86 | line-verified, full sweep | 1 253 | 8 248 | 99.92% | 0 | 0 | 1 | 0 |
| `TestSubject.bpl` | x64 | line-verified, full sweep | 1 276 | 7 509 | 99.84% | 0 | 2 | 0 | 0 |
| `TestSubject.bpl` | x86 | line-verified, full sweep | 1 233 | 8 190 | 100.00% | 0 | 0 | 0 | 0 |
| `rtl290.bpl` | x86 | export-anchored, full sweep | 49 564 | 1 535 973 | 81.22% | 0 | 8 902 | 396 | 0 |
| `vcl290.bpl` | x86 | export-anchored, full sweep | 13 922 | 503 753 | 90.18% | 0 | 1 262 | 384 | 0 |
| `Hydra2SingleEXE.exe` (505 MB) | x86 | line-verified, **33% sample** (every 3rd span; disclosed) | 792 554 of 2 377 660 | 5 294 297 | 99.98% | 0 | 76 | 101 | 0 |
| `Hydra2SingleEXE.exe` (582 MB) | x64 | line-verified, **33% sample** (every 3rd span; disclosed) | 803 805 of 2 411 415 | 5 807 612 | 99.99% | 0 | 66 | 7 | 0 |

Grand total across every row: **13 173 394 instruction positions compared,
zero mnemonic-identity divergences.**

**Every non-mnemonic divergence, classified:**

- **`length` (Delphi test targets and BPL, 2 total)** — manually inspected
  with `DumpFunc.exe`: both sit inside a Delphi inline exception-handler
  table (`count DWORD` / `Exception VMT RVA DWORD` / `handler address DWORD`
  triples emitted after a `jmp @HandleAnyException`) that a line-to-line span
  can straddle — the EXACT pattern `X86DecodeProbe`'s own README entry
  documents ("dcc32 emits the exception-handler table inline in the code
  stream ... That is data, and no linear decode can cross it"). Not a
  decoder disagreement; both engines are decoding non-code bytes.
- **`length` (`rtl290.bpl`/`vcl290.bpl`, 10 164 total, 0.50%)** — manually
  inspected: the first one (`rtl290.bpl` RVA `$116F`) is the literal ASCII
  bytes `...Extended80...Extended...`, RTTI type-name string data embedded
  directly in `.text`. This is the DISCLOSED weakness of the export-anchored
  methodology (unverified span end) doing exactly what its own description
  says it might: running past a short exported routine into adjacent data.
  Not attributable to either decoder.
- **`refusal` (all binaries, 780 in RTL/VCL + 1 in `TestTarget.exe` x86 +
  108 in the Hydra2SingleEXE.exe samples)** — every single one is Zydis
  decoding `$D6` (`SALC`) or `$F1` (`INT1`/`ICEBP`), two real, well-known
  UNDOCUMENTED x86 opcodes, while dumpbin's decoder does not recognise
  either at all (dumpbin advances one byte and prints nothing). Zydis has
  broader legacy-opcode coverage than MASM's disassembler — a genuine
  decoder CAPABILITY difference, not a bug: Zydis is not wrong here, it
  knows something dumpbin's table does not.
- **`boundary`, the one tooling artifact this sweep surfaced.** A single
  UNSAMPLED full sweep of `Hydra2SingleEXE.exe` x86 (all 2 377 660 spans,
  13 161 805 positions) was also run. It reported 478 083 `boundary`
  divergences (3.63%) — dumpbin had NO instruction at all at many span-start
  addresses Zydis decoded as utterly ordinary code (`push ebp`,
  `xor eax, eax`, `mov edx, [ebp-0x08]`). The SAME binary's 33% sample
  (5 294 297 positions, the row in the table above) shows ZERO boundary
  divergences, and a 5% sample (810 480 positions) also shows zero — a sharp
  scale threshold, not a uniform per-instruction rate, which rules out a
  real per-instruction Zydis/dumpbin disagreement (that would scale with the
  sample). Traced to dumpbin.exe itself silently omitting disassembly output
  somewhere beyond an internal capacity threshold when fed the ~100+ MB
  single-section synthetic image the full sweep produces — a genuine, newly
  measured LIMIT OF THE ORACLE at extreme scale, not a Zydis defect. This
  full-sweep run is reported here as a secondary, informational data point;
  the 33%-sample row in the table above is the trustworthy measurement for
  this binary. `RunAndCapture`'s original in-memory pipe capture also failed
  outright at this scale first (`EEncodingError: Invalid count
  (-1158168115)`, an overflowed Delphi string length) before being replaced
  with `RunToFile` + streamed `TStreamReader` parsing — see
  `DevTools\README.md`.
- **One normalisation bug, found by the tool's own full-scale run, not by
  inspection.** An early version of the `int3`/`int 3` alias matched on the
  operand's literal TEXT (`'3'`), which only fired for dumpbin's decimal
  spelling and silently missed Zydis's hex spelling of the SAME instruction
  (`int 0x03`) — invisible on every fixture and sample up to 33%, and only
  showed up as a nonzero `mnemonic` count on the one 100%-scale run. Fixed
  by collapsing Zydis's fused `int3` token to plain `int` instead of trying
  to detect dumpbin's operand value; re-verified at 0 mnemonic divergences
  across every row in the table above.

**Sampling, stated plainly per the standing "no silent capping" rule:** every
row above is a FULL, unsampled sweep of the named binary EXCEPT the two
`Hydra2SingleEXE.exe` rows, which are a disclosed 33% sample (every 3rd
span) chosen after `RunToFile`'s streaming fix made a full sweep succeed
technically but take ~5.7 minutes and surface the dumpbin-scale artifact
above; the 33% sample was independently confirmed clean of that artifact.
Re-running `DevTools\run_disasm_coverage.bat <exe>` with no `-sample` flag
performs a full, unsampled sweep of any binary, `Hydra2SingleEXE.exe`
included — the tool's default is always the full sweep; sampling is an
explicit, disclosed opt-in via `-sample N`, never a silent cap.

## Decision: backward disassembly is proven-boundary-only

Increment 4's MCP surface names a `before` parameter ("instructions preceding
an address") without specifying HOW to compute it — flagged mid-increment per
this project's "STOP on an unanticipated design decision" rule, and resolved
by the maintainer rather than guessed, because it collides directly with the
standing "no heuristics" constraint.

**The problem.** x86/x64 is a variable-length ISA with no way to find
instruction boundaries walking backward from an arbitrary byte. Every tool
that offers this (x64dbg, IDA, VS Code's own Disassembly View via a negative
DAP `instructionOffset`) picks some earlier byte offset, decodes forward, and
keeps whichever interpretation's last instruction happens to end exactly at
the target — a search over candidate alignments. More than one alignment can
legitimately land exactly on the target byte for different, both "valid"
instruction streams: an inherent ambiguity, not a decoder gap. That is a
heuristic by construction.

**The three options weighed:**

- **A — proven-boundary-only.** Answer `before` only when a PROVEN earlier
  boundary exists (the containing function's start — from debug info, or
  from the module's PE export table when it has none at all — or a nearer
  line-table boundary) AND decoding forward from it lands EXACTLY on the
  requested address. Refuse, naming the cause, otherwise. Deterministic by
  construction, at the cost of refusing whenever no such boundary exists.
- **B — defer `before` to increment 6.** Ship forward-only now; decide the
  backward algorithm once, when DAP's negative `instructionOffset` forces the
  identical question anyway.
- **C — best-effort backward scan, labelled unproven.** Scan-and-realign like
  x64dbg/IDA, but mark the result as unproven. Rejected outright: this tool
  exists to stop an agent constructing a confident wrong answer from raw
  bytes, and producing one INSIDE the debugger and merely labelling it is the
  same failure moved one layer up, not removed.

**Chosen: A.** It is the answer increment 6 would have reached anyway (B only
sequences the work, it does not avoid the question), and shipping the
refusal now means it is tested at the MCP layer before DAP depends on it.
Two hard constraints on how the refusal must appear, both honoured by
`Disassembler.DisassembleBackward` and `TMcpServer.HandleDisassemble`:

- the result must NEVER mix proven and unproven instructions in one list —
  `DisassembleBackward` returns either the FULL exact chain or nothing at
  all, never a partial one;
- a refusal of `before` is not a failure of the call — the forward
  `instructions` are still returned, untouched, alongside a `before.refused`
  object that names the cause.

Proven boundaries, in preference order (mirrors
`WinDebuggerBase.NearestInstructionBoundaryBefore`'s own existing
preference, extended with one new source):

1. the nearest line-table RVA within the same routine (tightest span, least
   chance of meeting an inline exception-handler table);
2. the routine's own entry (from debug info) when no line record exists
   there;
3. **new for increment 4**: the nearest PE export-table entry at or before
   the address, scoped to the owning module — the boundary source of last
   resort for a module with NO debug info at all (a package built by someone
   else, or an OS DLL). An export entry is still a genuinely PROVEN
   instruction boundary — the exact address `GetProcAddress` would return —
   just not a named one.

**Increment 6 must call the same mechanism, not re-derive it.** DAP's
`disassemble` request answers "instructions before the current PC" through
exactly the same negative-offset shape VS Code's Disassembly View already
uses; re-implementing backward disassembly there instead of calling
`IDebugTarget.NearestInstructionBoundaryBefore` /
`NearestExportedEntryBefore` + `Disassembler.DisassembleBackward` would
re-open an argument this document already settled.

## Verified in increment 4

- **The seam extension.** `IDebugTarget` (`DebugTarget.pas`) gained two
  methods: `NearestInstructionBoundaryBefore` (already implemented on
  `TWinDebugger` since increment 2 for the raw-stack-scan call-site-proving
  path, but declared only `protected` there and not part of the interface —
  promoted to the interface with NO change to its body, since Delphi lets a
  non-public method satisfy an interface) and `NearestExportedEntryBefore`
  (new: the PE-export fallback described above).
  `DebuggerTests\ValueReaderTests.pas`'s `TFakeMemTarget` (the only other
  `IDebugTarget` implementer) got trivial `False`-returning implementations
  of both — it has no debug info and no PE image to answer from.
- **`NearestExportedEntryBefore` reads the LIVE mapped image**
  (`ReadProcessMemoryAt`), never a file on disk: the loaded image is already
  relocated, so RVA-within-the-image equals VA-within-the-image directly,
  with no section/raw-offset translation to get wrong (unlike
  `DevTools\DisasmCoverage.dpr`'s file-based `TPEImage`, whose export-parsing
  byte offsets this method otherwise mirrors exactly — same
  `IMAGE_EXPORT_DIRECTORY` layout, same forwarder-entry exclusion). Anchored
  on `VA - 1` (not `VA`), for the identical reason
  `NearestInstructionBoundaryBefore` anchors on `TargetRva - 1`: if `VA` is
  itself an export's entry point, `before` must still be answerable by
  walking through whatever precedes it in the module — the byte stream does
  not stop meaning anything at a routine boundary.
- **`Disassembler.DisassembleBackward`** (library-free, like the rest of
  `Disassembler.pas`) is the ONE mechanism both the MCP tool and (later)
  increment 6 call: decodes one instruction at a time forward from
  `BoundaryVA`, and returns the whole chain trimmed to the last `Before`
  entries ONLY if the running cursor lands EXACTLY on `TargetVA`; any
  overshoot (or the reader running dry) returns nothing. Proven both ways in
  `DebuggerTests\DisassemblerTests.pas`'s `TDisassembleBackwardTests`, x64,
  against the same known 12-byte prologue increment 1 measured
  (`push rbp`/`push rbx`/`sub rsp,0x98`/`mov rbp,rsp`):
  `ProvenBoundary_LandsExactly_ReturnsExactPrecedingInstructions` (exact
  landing, most-recent-instructions-last, both a full-chain and a
  shorter-than-chain request) and
  `Misalignment_DoesNotLandExactly_RefusesWithEmptyResult` (`TargetVA`
  pointed mid-instruction, inside the 7-byte `sub rsp, 0x98` — forward decode
  necessarily overshoots it). Negative-controlled: commenting out the
  `Cursor <> TargetVA` refusal made the misalignment test fail with
  `Expected [0] but got [3]`, i.e. it silently returned 3 instructions that
  do NOT end at the requested address — exactly the guessed/misaligned
  result the design forbids.
- **`frameId` → `frameIndex` + `threadId`.** The plan named a `frameId`
  parameter without specifying its shape. The MCP surface has no existing
  opaque-frame-id concept anywhere — `get_locals`, `get_variable` and
  `evaluate_expression` all already select a frame via `frameIndex` (from
  `get_call_stack`) plus `threadId`, so `disassemble` reuses that exact
  convention instead of inventing a second one.
  `TMcpE2ETests.Disassemble_ViaFrameIndex_MatchesAddressForm` proves the two
  forms agree: `disassemble` with no `address` (resolving via
  `frameIndex:0`/`threadId:0`) and `disassemble` with `address` set to the
  first call's own echoed address decode to the identical first instruction.
- **The address round trip needed no new field, confirmed by test, not just
  inspection.** `McpJson.FrameListToJson` already emits `"address"` from
  `TSessionFrame.IP` for both `get_call_stack` frames and
  `get_raw_stack_scan` hits (present since the raw-stack-scan work, unrelated
  to this increment). `Disassemble_Forward_ReturnsDecodedInstructionsAtStopAddress`
  takes a real breakpoint stop's `frames[0].address` string from
  `continue_and_wait`'s snapshot UNMODIFIED and passes it straight into
  `disassemble`'s `address` argument, asserting the tool's own echoed
  `address` and the first decoded instruction's `address` both equal it
  exactly.
- **Fail-closed `available:false`, proven against a REAL isolated process,
  not simulated.** `Disassemble_ReportsUnavailable_WhenZydisDllNotFound`
  copies the built `DelphiDebuggerMcp.exe` to a scratch directory outside the
  repo (so neither its own-directory `Zydis.dll` check nor its
  repo-relative fallback — `..\..\..\ThirdParty\Zydis\bin\x64\Zydis.dll`,
  the same three-levels-below-repo-root convention `DevTools\Disasm.exe`
  uses — can resolve), launches THAT copy, and asserts `available:false`
  with a non-empty `reason` and — critically — no `instructions` key and no
  `before` key at all. Negative-controlled: temporarily short-circuiting the
  `if not Disasm.Available` guard let the call fall through to
  `Obj.AddPair('instructions', ...)` with an EMPTY array attached anyway,
  failing the "no `instructions` key at all" assertion with
  `available:false ... "instructions":[]` visible in the failure message —
  exactly the fabricated-partial-result shape the guard exists to prevent.
- **Bitness coverage.** `Disassemble_Forward_ReturnsDecodedInstructionsAtStopAddress`
  (x64, `machineMode:"x64"`) and `Disassemble_Win32_Forward_ReturnsDecodedInstructions`
  (x86, `machineMode:"x86"`, plus an explicit check that every decoded
  instruction's address fits an 8-hex-digit 32-bit VA) both drive the SAME
  built `DelphiDebuggerMcp.exe` and the SAME `Zydis.dll` against the two
  `TestTarget.exe` bitnesses, mirroring how `TZydisPositiveDecodeTests`
  already covered both machine modes at the seam level.
- **Never presents disassembly-derived call targets as call-stack frames —
  satisfied by construction**, same as increment 2: `disassemble`'s result
  type is a fresh JSON object with its own `instructions` array; nothing in
  this increment writes into `FrameListToJson`, `GetCallStack`, or
  `GetRawStackScan`.
- Full suite (`DebuggerTests\build_and_run.bat`): see `TASK_RESUME.md` for
  the exact counts from this session's run.

## Open, to verify before writing code

(none remaining for increment 4 — resolved above)

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
