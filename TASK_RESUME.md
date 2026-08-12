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

## Current task (2026-08-12)

**0.5.0 draft is on GitHub, awaiting the user's review and publish**
(`gh release edit v0.5.0 --draft=false`). Everything below it is pushed
(`52d81a3`). Suite at the draft: 1237 / 1233 / 0 / 0 / 4. One flaky full-run
failure (`Test_RtlStringGetter_VarOutFromPropertyType`, machine under load,
159 s shards) passed 2/2 isolated and the rerun was green — matches the open
KNOWN_UNKNOWNS flake entry.

**Correction on 0.4.1** (the `52d81a3` commit message is WRONG about this):
0.4.1 HAD been published by the user. It was deleted in error on a stale
"still a draft" assumption, then restored 1:1 the same day — same tag (which
had survived, and is what proved the publication), byte-identical zip
(SHA `6DDA0377…` matches the published notes), original notes, Latest pointer
put back. Trap recorded in `TRAPS.md`. The 0.5.0 notes now split "New in
0.5.0" from "Shipped in 0.4.1".

**Next feature agreed with the user: the safe-getter whitelist** (auto-evaluate
side-effect-free getters instead of "expand to evaluate"). Design discussed and
settled 2026-08-12; increments, in order: (1) SafeCallPolicy engine + manual
archive + VS Code add/deny UI — no AI; (2) shorter budget for AUTO calls +
entry-byte hook sniff (E9/FF25 -> defer); (3) AI-agent contract + JSON schema +
lint probe, then the agent and a distributed RTL archive; (4) optional machine
screening for the hover tier. Key decisions: lookup key = SYMBOLICATED address
of the RESOLVED target (concrete-class VMT — covers virtuals/interfaces);
verdicts are categories (pure / mayRaise / lazyInit / conditional+dependsOn /
unsafe), lazyInit never auto (TWinControl.Handle creates the window); layered
JSON archives deny > user > project > shipped; runtime guards stay on always
(raise/AV abort + the existing 8 s watchdog, `REMOTE_CALL_TIMEOUT_MS`).

## Previous task (2026-08-11)

**Post-0.4.0 verification pass, driven by the user in VS Code.** They exercise the
debugger, report what is wrong, and each defect is fixed here with a test that is
RED without the fix before moving on.

Suite green at the cursor: **1229 found / 1225 passed / 0 failed / 0 errored /
4 ignored**, 69 s at 8 workers. 0.4.0 is published; everything below is
UNCOMMITTED work on top of `1a78954`.

### Uncommitted, all green

The memory-inspection work, which is most of this pass, is described where it
belongs: `PROJECT_STATE.md` -> "Memory inspection" and
`DAP_DEBUGGER_ARCHITECTURE.md` -> "Memory views". In one line: the extension has
its own memory view, the adapter tells it where a value lives and how big it is,
and the editor's built-in pane is withdrawn.

Also landed, each with its test:

- `SelectFrame(0)` no longer clears the active frame (`frameId: 0` answered
  `<name: not found>` for what no-frameId resolved). See
  `DAP_DEBUGGER_ARCHITECTURE.md` -> "Frames versus the active frame".
- The diagnostic log is capped per FILE with one rotation (`DAP_LOG_MAX_MB`,
  default 64 MB) — `DapLogTests.pas`.
- Test scratch directories live under one root and are actually removed —
  `TestTempDirs.pas`; the reasons are in `TRAPS.md` -> "Cleanup that silently
  never happens".
- `build_and_run.bat` calls `build_target.bat` instead of keeping a stale copy of
  the fixture build.
- The no-source placeholder names "Open Disassembly View" and F10/F11 instruction
  stepping, both confirmed by hand.

### Still to verify (the user does this in VS Code; nothing is blocked on code)

1. **Memory view** — the payload behaviour on a string / dynamic array in both
   panels, a byte WRITE through the `edit` toggle, and whether the changed-byte
   highlight now survives (it was being wiped by the pane's own re-measure).
2. **Step at an exception** (`5b932c3`) — `F10` at an exception stop lands on the
   `except`/`finally` that receives it; on x86 `try/finally` it must REFUSE with
   a visible reason (the refusal is the correct behaviour, not a bug).
3. **Data breakpoints** — "Break on Value Change" on a real variable, both
   bitnesses; and **Breakpoints panel -> "Add Data Breakpoint at Address"**,
   which has never been driven by hand.
4. **Hydra2** — breakpoint in a BPL loaded after startup, locals, evaluate. The
   only core use case the suite does not reproduce.

### Then

- Commit this pass (it is several independent changes; separate commits).
- Two extension folders are registered (`0.2.3` and `0.3.0`) while the repository
  stages `0.4.0`: run `install\Install.exe` once to re-register and drop the
  duplicate.

### Traps that already cost time in THIS pass

- The `Edit` tool can write a whole Delphi file back as LF, and a backtick in a
  comment inside a JS template literal ends the literal. Check both before
  building; `git status` does not always show the line-ending change.
- Every `DebuggerCore` consumer needs rebuilding: adapter (`build_dap.bat`), MCP
  (`build_mcp.bat`), runner (`build_runner.bat`). A stale MCP binary silently
  passes the DAP tests.
- After touching ANY test-target source, run `build_and_run.bat`. Editing even a
  COMMENT shifts the `{BP:MARKER}` lines away from the compiled binary.
- An extension change needs `install-dev.bat` AND a window reload; the adapter
  alone needs neither. Several "still broken" reports were an unreloaded window.
- Killing a suite mid-run leaves the adapter, `TestHost` and the MCP servers
  holding their exes; the next build fails with `F2039`. Kill them, do not
  investigate.
