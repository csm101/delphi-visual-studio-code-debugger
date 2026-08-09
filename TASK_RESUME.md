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

**`ASSEMBLY_LEVEL_DEBUGGING.md` increment 6 — WOW64 register writes. DONE, not
committed; left in the tree for review.** `TWinDebugger.SetRegisterByName` had
no WOW64 override; gave it one (`TWin32Debugger.SetRegisterByName`,
`WinDebuggerX86.pas`, `Wow64Get/SetThreadContext` by name, refuses `R8`..`R15`).
DAP `setVariable`/MCP `set_register` share the fix (same engine path).

**The measurement reversed the task's own starting premise, and that is the
finding that matters most.** At the WOW64 loader breakpoint a native register
write is genuinely invisible to `Wow64GetThreadContext` — but at a REAL
application breakpoint (an `INT3` planted in running 32-bit code, every stop
this debugger actually reports to a user) the native and WOW64 views alias
exactly for every register including `Rip`/`Rsp`/`Rbp`, on this measured
Windows build (11, build 26200). The write path was kept fixed anyway
(documented-correct API, funnel consistency, and it's REQUIRED to close the
one genuinely real defect: `R8`..`R15` don't exist on x86 and the unfixed
base silently "wrote" them). Full writeup, both measurements, both probe runs:
`ASSEMBLY_LEVEL_DEBUGGING.md` increment 6. Coverage and which tests are RED
controls vs. regression guards: `TEST_CATALOG.md` section S. New TRAPS.md
entry: the loader breakpoint is not a representative WOW64-context state.

### Files changed

- `DebuggerCore\WinDebuggerBase.pas` — `SetRegisterByName` now `virtual`.
- `DebuggerCore\WinDebuggerX86.pas` — `TWin32Debugger.SetRegisterByName`
  override (public, matching base visibility).
- `DevTools\Wow64RegWriteProbe.dpr` (new probe) — reproduces the base's exact
  mechanism; `-rva` plants a real breakpoint instead of relying on the loader
  break; `CompareAllFields` dumps native-vs-WOW64 for every role register.
- `DebuggerTests\DebugSessionTests.pas` (`TWin32RunControlTests`) —
  `Win32_SetRegister_WritesAndReadsBack`, `Win32_SetRegister_
  ExtendedRegister_Refused` (+ file-scope `FindRegister` helper).
- `DebuggerTests\McpE2ETests.pas` — `SetRegister_Win32_WritesAndReadsBack`,
  `SetRegister_Win32_ExtendedRegister_Refused`.
- `DebuggerTests\RegisterWriteDapTests.pas` (new file, 3 tests) —
  `X64_SetVariable_Register_WritesAndReadsBack`, `Win32_SetVariable_
  Register_WritesAndReadsBack`, `Win32_SetVariable_Register_
  ExtendedRegister_Refused`. Registered in `RunTests.dpr`.
- Docs (same change set): `ASSEMBLY_LEVEL_DEBUGGING.md` (increment 6, full
  writeup), `DAP_DEBUGGER_ARCHITECTURE.md` (funnel table row + increment 4's
  register section corrected), `TEST_CATALOG.md` (section S + Q's stale
  bullet resolved), `TRAPS.md` (new entry), `PROJECT_STATE.md` (one-line
  status correction), this file.

### Gates

- **Full suite green**: 1180 found / 1176 passed / 0 failed / 0 errored / 4
  ignored — baseline 1173/1169/0/0/4 plus exactly the 7 new tests (2 session +
  2 MCP + 3 DAP), ignored count unchanged.
- Every consumer rebuilt: `build_dap.bat`, `build_mcp.bat`,
  `DevTools\build_all.bat`, `DebuggerTests\build_and_run.bat` — all clean.
- **RED control, confirmed**: temporarily made `TWin32Debugger.
  SetRegisterByName` fall back to `inherited` (`Result := inherited
  SetRegisterByName(Name, Value); Exit;`), reran the Win32 register tests —
  the two `*ExtendedRegister_Refused` tests failed (`Condition is True when
  False expected`), the two `*WritesAndReadsBack` tests still PASSED (the
  aliasing finding above, not a broken control). Reverted before the final
  build.
- **Not verified**: on any Windows version other than the one measured here;
  the "debuggee is running" refusal gate on `setVariable`/`set_register`
  (same racy-to-construct precedent as `disassemble`/`readMemory`).

## State of the tree

- `public-main`. Increments 1, 2, 3, 4 and 6 are all UNCOMMITTED by
  instruction. **DO NOT COMMIT.**
- Next per `ASSEMBLY_LEVEL_DEBUGGING.md`'s order: increment 5 (the
  placeholder document for a sourceless frame becomes useful) — the last
  remaining increment, and depends on everything above already working.
