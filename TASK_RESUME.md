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

**`DISASSEMBLY_PLAN.md` increment 7 — packaging. DONE, not committed; left in
the tree for review.** This closes the disassembly plan end to end (all 7
increments). Full detail in `DISASSEMBLY_PLAN.md` "Verified in increment 7"
and `ThirdParty\Zydis\PROVENANCE.md` "Runtime library: /MD vs /MT" — this
cursor is a pointer, not a repeat.

### What changed

- `ThirdParty\Zydis\build_zydis.bat`: added `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`.
  Committed `bin\x64\Zydis.dll` + `.sha256` regenerated from it (`/MT`,
  670,720 bytes, was 576,512 `/MD`; `dumpbin /DEPENDENTS` now shows
  `KERNEL32.dll` only). `ThirdParty\Zydis\PROVENANCE.md` carries the measured
  `/MD` vs `/MT` table and the decision reasoning.
- `update-install.bat`: copies `Zydis.dll` + `LICENSE` (as
  `Zydis-LICENSE.txt`) into `install\local.delphi-win64-debug\` right after
  the adapter exe. Missing source DLL = printed NOTE, not a failure.
- `install\Install.dpr`: new `ZydisDllSourcePath` / `ZydisLicenseSourcePath` /
  `CopyZydisIfAvailable` (next-to-exe first, else repo-relative — same
  pattern `ResolveZydisDllPath` already uses in `DapServer.pas`/
  `McpServer.pas`, which needed NO code change). Called once for the
  extension `StageDir`, once for `McpInstallDir`
  (`%LOCALAPPDATA%\DelphiWin64Debugger\`) inside `RegisterMcp`.
- `build_setup_zip.bat`: stages `Zydis.dll` + `Zydis-LICENSE.txt` at the zip
  root, next to `Setup.exe`/`DelphiDebuggerMcp.exe`. Missing = WARNING, zip
  build still succeeds.
- Docs: `DISASSEMBLY_PLAN.md` (increment 7 status + "Verified in increment
  7"), `ThirdParty\Zydis\PROVENANCE.md`, `PROJECT_STATE.md`,
  `install\INSTALL_INSTRUCTIONS.md` (feature line + troubleshooting entry),
  `HOW_TO_CREATE_A_NEW_RELEASE.md` (zip contents + size note).
- No change needed: `install-dev.bat`/`build_dap.bat`/`build_mcp.bat` stay
  Delphi-only — dev mode's build-output paths already sit exactly where
  `DefaultZydisDllPath`'s existing repo-relative fallback resolves. No
  `.gitattributes`/`.gitignore` change — staged DLL copies are build output,
  same as the adapter exe that already lived un-committed in that folder.

### Proven, not just implemented

- `/MT` functional parity: rebuilt DevTools, ran `DisasmProbe.exe` against
  `TestTarget.exe`'s entry (RVA `$167FC0`) through the new DLL —
  byte-identical decode to the known-good `/MD` output from increments 1/2.
- Packaged result verified LIVE, both frontends independently, from a scratch
  directory on `X:\` with no relationship to the repo (confirmed the
  repo-relative fallback path does not exist there before each run, so a pass
  can only mean next-to-exe resolution worked): hand-rolled PowerShell
  clients speaking each exe's own wire protocol (MCP: JSON-RPC over
  newline-stdio; DAP: Content-Length-framed JSON) drove a real
  `launch`/`launch_debuggee` -> stop -> `disassemble` round trip. Both
  returned real decoded instructions (`push rbp` at the entry address,
  symbolicated), not a refusal. Scripts left in
  `X:\Temp\claude\...\scratchpad\verify_{mcp,dap}_disasm_packaged.ps1` for
  reference (session-scratch, not part of the repo).
- `build_setup_zip.bat` run end to end: `dist\delphi-win64-debugger-setup-
  v0.3.0.zip` (4.59 MB) inspected directly — `Zydis.dll` (670,720 bytes,
  matching the `/MT` rebuild) + `Zydis-LICENSE.txt` present BOTH inside
  `local.delphi-win64-debug/` and at the zip root.

### Full suite

Run via the `test-runner` agent (`build_and_run.bat`): **1118 found / 1114
passed / 0 failed / 0 errored / 4 ignored** — exact match to the increment-6
baseline, as expected for a packaging-only change (no
`DebuggerCore`/`DapServer.pas`/`McpServer.pas` code touched, no test
added/removed). Gate satisfied.

### Not done / not verified

- Ran `install\extension-tests\run.bat` for due diligence even though nothing
  inside `install\local.delphi-win64-debug\` (the JS extension code itself)
  was touched — all green (13+22+23+19+15+24+46+8+20 cases across every
  suite), as expected.
- Did not run `Setup.exe`/`Install.exe` interactively end-to-end (would touch
  this machine's real VS Code extension state and `claude mcp add`
  registration for no additional proof beyond what the direct protocol-level
  verification above already gives — `BuildVsix` zips `StageDir` recursively,
  already confirmed to contain `Zydis.dll`).

## State of the tree

- `public-main`. Disassembly increments 1-6 and the data-breakpoints
  increment are already committed (`git log`: `af917fe` is increment 6,
  HEAD at session start). This session's increment 7 (packaging) is
  UNCOMMITTED by instruction — **DO NOT COMMIT**, left in the tree for
  review. `git status --porcelain` at the end of this session: only the
  files this session touched (see "What changed" above) plus `.gitignore`.
  Release **0.3.0 is committed but NOT tagged and NOT pushed**; no GitHub
  release exists.
- Win32 support is functionally complete for `-$O-` targets. Debug-info format
  coverage (TD32, RSM, MAP, JCL, DCP, `.tds`) is closed; DCU is WON'T DO.

## Traps

`TRAPS.md` has full detail. New for this session, not yet promoted there:
**`cmd /c "<batch file>"` from the Bash tool produced no output and no error
in this session** (just a fresh cmd banner) — root cause not diagnosed, but
`PowerShell`'s call operator (`& "<path>"`) ran every batch file correctly
throughout. Prefer PowerShell for `.bat` invocation if Bash's `cmd /c`
mysteriously no-ops again.
