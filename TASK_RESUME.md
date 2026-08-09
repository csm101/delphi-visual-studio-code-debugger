# TASK_RESUME

The cursor inside the task in flight, and nothing else.

**This file is OVERWRITTEN, not appended to, and stays under ~150 lines.** It grew
to 3343 lines (~91k tokens) by being used as a lab journal, until reading it cost
more than reading the code it described — and by then its "next action" pointed at
work finished weeks earlier, which is worse than having no cursor at all.

Where everything else goes:

| content | home |
|---|---|
| a measured fact about a format | `RSM_*.md`, `TD32_FORMAT_NOTES.md` |
| an architectural decision or mechanism | `DAP_DEBUGGER_ARCHITECTURE.md` |
| an open question or a refuted hypothesis | `KNOWN_UNKNOWNS.md` |
| a rule that prevents wasted work | `TRAPS.md` |
| what is done / what is next, at project scale | `PROJECT_STATE.md` |
| the narrative of a change that landed | the commit message |

If a paragraph here is still true once the current task ends, move it. If it is no
longer true, delete it.

---

## Current task (2026-08-09)

**`ASSEMBLY_LEVEL_DEBUGGING.md` increment 3 — DAP: memory. DONE, not
committed; left in the tree for review.** DAP `readMemory`/`writeMemory` +
`memoryReference` on variables, reusing the same engine primitive MCP's
`read_memory`/`write_memory` and `disassemble` already use
(`IDebugTarget.ReadCodeMemoryAt`) — one new engine primitive,
`IDebugTarget.WriteMemoryPartial`, added for `writeMemory`'s `allowPartial`
byte-count reporting.

Mechanism, the full "which variables carry a memoryReference" decision
record, and the `allowPartial` wire contract: `DAP_DEBUGGER_ARCHITECTURE.md`,
"DAP memory: readMemory/writeMemory, memoryReference — increment 3".
Decisions: `ASSEMBLY_LEVEL_DEBUGGING.md` increment 3. Coverage:
`TEST_CATALOG.md` section R. This cursor is a pointer, not a repeat.

### Files changed

- `DebuggerCore\DebugTarget.pas` — `IDebugTarget.WriteMemoryPartial` (new).
- `DebuggerCore\WinDebuggerBase.pas` — `TWinDebugger.WriteMemoryPartial`
  (separate body from `WriteMemoryAt`, not a wrapper — see the comment at
  its definition for the `Size=0` edge case that makes a wrapper wrong).
- `DebuggerCore\DebugSessionTypes.pas` — `TSessionVariable.Address: UInt64`
  (0 = no real address, the same sentinel `TLocalValue.Address` already
  established).
- `DebuggerCore\DebugSession.pas` — `LocalToSession` sets `Result.Address :=
  LV.Address`.
- `DebuggerCore\VariableExpander.pas` — five sites set `.Address` from a
  value already used for a real memory read one line away:
  `MemberFieldToSession`, `ExpandRttiTyped`, `ExpandProperties` (field-backed
  branch only), `ExpandDynArray`, `ExpandVariantArray`.
- `VisualStudioCodeDelphiDebugger\DapServer.pas` — `uses System.NetEncoding`;
  `HandleInitialize` advertises `supportsReadMemoryRequest`/
  `supportsWriteMemoryRequest`; new `HandleReadMemory`/`HandleWriteMemory`
  + `ProcessRequest` dispatch; `EmitVar` emits `memoryReference` when
  `V.Address <> 0`; `BuildCurrentExceptionRef` grew an `out ObjAddr` param,
  threaded into `AppendExceptionLocal` and the `$exception` branch of
  `HandleEvaluate`.
- `DebuggerTests\DapClient.pas` — `ReadMemory`/`ReadMemoryRaw`/
  `WriteMemory`/`WriteMemoryRaw`; `Initialize` now declares
  `supportsMemoryReferences` (mirrors real VS Code; the adapter does not
  currently gate emission on it, same as the pre-existing
  `instructionPointerReference`).
- `DebuggerTests\ValueReaderTests.pas` — `TFakeMemTarget.WriteMemoryPartial`
  (interface completeness only; not exercised).
- `DebuggerTests\MemoryDapTests.pas` (new, 14 tests) — capability, read/write
  round-trip on a real local (both bitnesses), memoryReference presence
  (local) vs. absence (Registers scope), unmapped-address partial-read,
  invalid-reference refusal, missing-required-field refusals (`count`/
  `data`, via raw JSON), not-launched refusals, unwritable-address refusal
  with/without `allowPartial`.
- `DebuggerTests\RunTests.dpr` — registers `MemoryDapTests`.
- Docs (same change set): `ASSEMBLY_LEVEL_DEBUGGING.md` (increment 3 status +
  capability table + full write-up), `DAP_DEBUGGER_ARCHITECTURE.md` (new
  subsection + capability table rows), `TEST_CATALOG.md` (section R), this
  file.

### Design decision made (not left open, per the task's own anticipation)

Which variables carry a `memoryReference`: anything whose displayed value
was read from a real, already-known target address (locals, fields, array/
Variant-array elements, the live `$exception` object) carries one; anything
computed (a getter's scalar CALL result), synthetic (a group row), or not
memory at all (a register) does not. Full list with the reasoning per case
is in `DAP_DEBUGGER_ARCHITECTURE.md`, not repeated here.

`writeMemory`'s `allowPartial=false` path ATTEMPTS the write and reports
what happened, rather than pre-verifying writability across the whole range
first (the DAP spec's suggested shape) — a rejected write can therefore
already have changed however many bytes were writable before the boundary,
and the refusal message says so explicitly. Traded a multi-region
pre-flight walk against reusing one already-simple mechanism.

### Gates

- **Isolated filtered run, GREEN**: `RUNTESTS_ONLY=MemoryDapTests` — 14/14.
- **Full suite (`build_and_run.bat`) — CONFIRMED GREEN**: 1173 found / 1169
  passed / 0 failed / 0 errored / 4 ignored — baseline 1159/1155/0/0/4 plus
  exactly the 14 new `[Test]` procedures, ignored count unchanged.
- Every consumer rebuilt: `build_dap.bat`, `build_mcp.bat`,
  `DevTools\build_all.bat`, `DebuggerTests\build_runner.bat` — all clean
  (only pre-existing hints/warnings). `DevTools\ValueReaderTests.pas`'s
  `TFakeMemTarget` needed `WriteMemoryPartial` added to compile
  (interface-completeness fallout from the new `IDebugTarget` method, not a
  behaviour change).
- **Four RED controls, all reverted and reconfirmed clean** (`grep
  RED_CONTROL DapServer.pas` empty afterward; final rebuild byte-for-byte
  the same size as the pre-mutation build):
  1. Disable `EmitVar`'s `memoryReference` emission → the 5 tests that start
     from a variable's own reference fail (`*_ReadMemory_LocalVariable_*`
     both bitnesses, `*_WriteMemory_LocalVariable_*` both bitnesses,
     `Variables_LocalCarriesMemoryReference_...`).
  2. Disable the `readMemory`/`writeMemory` dispatch cases in
     `ProcessRequest` → 12 of 14 fail (only the capability test and the
     memoryReference-presence half of one control survive, neither of which
     sends either request).
  3. Force the `writeMemory` partial-refusal check to `False` →
     `WriteMemory_UnwritableAddress_RefusedWithoutAllowPartial` fails alone
     (the refused write wrongly succeeds).
  4. Disable the `unreadableBytes`-computing branch in `HandleReadMemory` →
     `ReadMemory_UnmappedAddress_ReportsUnreadableBytesNotFailure` fails
     alone (`Expected [16] but got [0]`).
- **Not verified**: the "debuggee is running" refusal gate on either
  request (racy to construct; same gate shape `disassemble` already uses,
  itself also untested this way); `memoryReference` on a nested field/array/
  Variant-array element has no dedicated DAP-level fixture (covered by
  inspection — each site reuses a value already proven for a real read).

## State of the tree

- `public-main`. Increments 1, 2, 3 and 4 are all UNCOMMITTED by
  instruction. **DO NOT COMMIT.**
- Next per `ASSEMBLY_LEVEL_DEBUGGING.md`'s order: increment 5 (the
  placeholder document for a sourceless frame becomes useful) — the last
  remaining increment, and depends on everything above already working.
