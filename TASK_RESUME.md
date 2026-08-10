# TASK_RESUME

The cursor inside the task in flight, and nothing else.

**This file is OVERWRITTEN, not appended to, and stays under ~150 lines.** It grew
to 3343 lines (~91k tokens) by being used as a lab journal, until reading it cost
more than reading the code it described — and by then its "next action" pointed at
work finished weeks earlier, which is worse than having no cursor at all.

Where everything else goes:

| content | home |
|---|---|
| a measured fact about a format | `RSM_*.md`, `TD32_FORMAT_NOTES.md`, `EH_FORMAT_NOTES.md` |
| an architectural decision or mechanism | `DAP_DEBUGGER_ARCHITECTURE.md` |
| an open question or a refuted hypothesis | `KNOWN_UNKNOWNS.md` |
| a rule that prevents wasted work | `TRAPS.md` |
| what is done / what is next, at project scale | `PROJECT_STATE.md` |
| the narrative of a change that landed | the commit message |

If a paragraph here is still true once the current task ends, move it. If it is no
longer true, delete it.

---

## Current task (2026-08-10)

**Pre-release verification pass, driven by the user in VS Code.** Each defect they
report is fixed here, with a test that is RED without the fix, before moving on.

Suite green at the cursor: **1204 found / 1200 passed / 0 failed / 0 errored /
4 ignored**, 65 s at 8 workers. Last commit `8af8c82`. Nothing pushed yet
(~37 local commits on `public-main`).

### Fixed so far in this pass

- `e4e2b35` — `setVariable` on a register answered with an EMPTY body, so VS Code
  blanked the row it was showing (name left standing, no value). The write itself
  had always worked. Response now re-reads the register and formats it through
  `DescribeRegister`, shared with the `variables` listing.
- `8af8c82` — a 32-bit target now reports EIP/ESP/EBP/EAX..EDI/EFlags at size 4
  and no R8..R15, instead of the 64-bit shape of `TRegisterSnapshot`. Both
  spellings stay accepted on either bitness (`SameRegisterName`, `DebugTarget.pas`);
  `TDebugSession.TryGetRegister` is the shared lookup both frontends answer writes
  with.

### Still to verify (the user does this in VS Code; nothing here is blocked on code)

1. **Disassembly View** — whether "Open Disassembly View" appears in the Call Stack
   context menu or only in the command palette. One sentence of the no-source
   placeholder text is conditioned on this answer. Then: `F10`/`F11` stepping one
   INSTRUCTION inside the view, and a gutter breakpoint in it.
2. **Memory inspector** — "View Binary Data" on a variable; a byte write.
3. **Exception-kind gate, case B** — launch config "Delphi raise: deep nested
   (TestTarget)": frame 0 must be `RnInner` in `TestTargetCore.pas`, `RnInnerVal`
   = 277. Case A (ntdll fault) already confirmed.
4. **Step at an exception** (`5b932c3`) — `F10` at an exception stop lands on the
   `except`/`finally` that receives it; on x86 `try/finally` it must REFUSE with a
   visible reason (the refusal is the correct behaviour, not a bug).
5. **Data breakpoints** — "Break on Value Change" on a real variable, both bitnesses.
6. **Hydra2** — breakpoint in a BPL loaded after startup, locals, evaluate. The only
   core use case the suite does not reproduce.

### Then, to release

- Rewrite the release notes: they still describe 0.3.0, from before disassembly,
  assembly-level debugging, data breakpoints, the exception-stop work and the
  suite rewrite.
- Version: 0.4.0 recommended.
- Push.

### Traps that already cost time in this pass

- The `Edit` tool can write a whole Delphi file back as LF. Check and normalize to
  CRLF before committing (project rule; `git status` will not always show it as a
  content change).
- Asserting a 32-bit register rendering by a leading-zeros prefix is wrong: `EAX`
  is legitimately small and `0x00000000` contains `0x0000000`. Assert the rendered
  LENGTH (10 for 32-bit, longer for the 64-bit form with its decimal suffix).
- Every `DebuggerCore` consumer needs rebuilding: adapter (`build_dap.bat`), MCP
  (`build_mcp.bat`), runner (`build_runner.bat`). A stale MCP binary silently
  passes the DAP tests.
