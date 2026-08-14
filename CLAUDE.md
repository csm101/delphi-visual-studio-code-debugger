This file provides guidance to Claude Code when working in this repository.

# Project purpose

Build a real Delphi Win64 debugger for VS Code using DAP + Windows Debug API.

Primary goal is progress on the debugger itself.
The sample target app exists only for testing.
It may be extended whenever needed to validate new debugger features.

# Operating mode

Use minimum tokens.

Be concise.
No filler.
No praise.
No motivational tone.
No repeating the request.
No long plans unless asked.
No unnecessary explanations.

If code requested: output code first.
If uncertain: say uncertain.
If idea is bad: say so directly.

Prefer practical solutions over academic ones.

# Critical token rules

Assume context window and usage budget are scarce.

Avoid re-reading many files unless necessary.
Avoid broad repo scans.
Inspect only files relevant to the current task.
Do not restate known project context.

Prefer direct edits over discussion.

When multiple approaches exist:
choose the smallest production-relevant step.
Do not implement shortcuts that only work for Debugme.
Every solution must be compatible with real Delphi Win64 applications unless explicitly marked as prototype-only.
Prefer incremental progress, but never hardcode assumptions from the test project.

# Prototype vs production

Debugme is only a test target.

Never design features around Debugme-specific assumptions.

Allowed:
- using Debugme to reproduce and validate behavior
- extending Debugme to cover newly implemented debugger features
- implementing narrow incremental pieces

Not allowed:
- hardcoded source paths
- hardcoded module names
- hardcoded symbol names
- assumptions about one unit, one source file, one thread, one stack frame, or one module
- solutions that work only because Debugme is trivial

If a temporary shortcut is unavoidable:
- mark it clearly with TODO PROTOTYPE
- document what must change for real projects
- update TASK_RESUME.md with the limitation

# Session continuity rules

The record of what happened is `git log`. The record of where the project stands
is `PROJECT_STATE.md`. Neither needs maintaining by hand as a side activity:
commit messages are written when committing, and `PROJECT_STATE.md` is updated in
the same change set as the work it describes.

`TASK_RESUME.md` covers the one case those two cannot: work that is **started and
not yet committed**, interrupted mid-step. Write into it what a new session cannot
get from the diff — the hypothesis being tested, what was already tried and
refuted, the exact next action — and only while that state is uncommitted.

**The `post-commit` hook in `githooks/` erases it on every commit.** That is
deliberate: once a commit exists the commit message is the record, and leftover
cursor text now describes finished work. This is not hypothetical — the file once
reached 3343 lines (~91k tokens) with a "next action" pointing at work finished
weeks earlier. A stale cursor is worse than no cursor: it sends the next session
in the wrong direction with confidence. Do not defeat the hook by rewriting the
cursor after committing.

Enable the hook once per clone:

```powershell
git config core.hooksPath githooks
```

**Never stage `TASK_RESUME.md` with the work.** `git add -A` will, so stage
explicitly. With the stub in `HEAD` the hook's rewrite matches what is committed
and the worktree stays clean; commit the cursor text once and `HEAD` holds a
cursor describing finished work, which `git checkout --` will happily restore.

Everything durable goes elsewhere, in the same change set as the code:

- a measured fact about a format -> `RSM_*.md`, `TD32_FORMAT_NOTES.md`
- an architectural decision or mechanism -> `DAP_DEBUGGER_ARCHITECTURE.md`
- an open question or a refuted hypothesis -> `KNOWN_UNKNOWNS.md`
- a rule that prevents wasted work -> `TRAPS.md`
- what is done / what is next at project scale -> `PROJECT_STATE.md`
- the narrative of a change that landed -> the commit message, not a file

PROJECT_STATE.md must contain:

- architecture status
- implemented features
- open milestones
- important technical discoveries
- stable build/run commands

# Living specifications

The following documents at the repository root are living specifications.
They describe state of knowledge about the project's formats and
architecture and are maintained continuously alongside the code:

- `RSM_FORMAT_NOTES.md` — overall structure of the Delphi `.rsm` file.
- `RSM_RECORD_TYPES.md` — catalog of tags / record kinds with confirmed /
  inferred / conjectured status.
- `RSM_FIELD_OFFSETS.md` — byte-level layout of each record.
- `DAP_DEBUGGER_ARCHITECTURE.md` — modules, threading model, breakpoint /
  evaluate / setVariable flows, capability list.
- `EH_FORMAT_NOTES.md` — where a Delphi binary records its exception-handling
  scopes on each bitness (`.pdata` / `UNWIND_INFO` / scope + clause tables on
  x64, the `fs:[0]` registration chain on x86), and which parts of it a debugger
  can actually derive a handler address from.
- `KNOWN_UNKNOWNS.md` — open questions that block or condition the work.
- `TRAPS.md` — operational rules that prevent wasted work. Every entry is there
  because it already cost time once. Read it before an unfamiliar kind of change,
  and grep it when something behaves absurdly.

Rules:

- Before investigating anything related to `.rsm`, the adapter
  architecture, or open questions: read the relevant document first. Do
  not re-derive what is already written.
- When you discover or confirm a fact: update the relevant document in
  the same change set as the code or experiment that produced the fact.
- When an entry in `KNOWN_UNKNOWNS.md` is resolved: move the answer into
  whichever document now owns it (`RSM_*`, `DAP_DEBUGGER_*`,
  `PROJECT_STATE.md`) and remove the entry from `KNOWN_UNKNOWNS.md`. Do
  not leave resolved questions there for historical reference.
- If a document disagrees with the code: the code wins. Correct the
  document, do not bend the code to match the document.

# Resume behavior

When starting a new session:

1. `git log --oneline -15` and `git status` — what landed recently, and whether
   anything is uncommitted
2. Read PROJECT_STATE.md
3. Read TASK_RESUME.md. If it holds the stub, there is no interrupted work and
   the previous two steps are the whole picture.
4. Read the living specifications relevant to the next step — pick them from the
   list under "Living specifications" above, which is the ONLY list of those
   documents. `KNOWN_UNKNOWNS.md` and `TRAPS.md` are read in every session
   regardless of focus.
5. Inspect only referenced files first
6. Resume exactly from next step

Do not restart analysis from zero unless required.

# Code generation rules

Respect existing code style.

Use 2-space indentation.

For Delphi:

- never use with
- prefer explicit code
- minimum supported Delphi version is Delphi Athens for both this project and debug targets
- keep compatibility with Delphi Athens toolchain and generated binaries
- prefer modern Delphi libraries and language features when they improve clarity or robustness
- prefer current RTL facilities over old compatibility-era helpers
- examples: System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, System.Generics.Defaults, System.Math, System.DateUtils, System.JSON where appropriate
- use generics where appropriate
- use modern string helpers and extension-style helpers where available
- use anonymous methods, records with methods/operators, class helpers, scoped enums, inline variables, type inference, and other modern Delphi features when they make the code clearer
- avoid outdated pre-Unicode or legacy-era coding patterns
- avoid unnecessary abstractions
- prefer boring robust code

For Windows debugger code:

- correctness over cleverness
- log failures clearly
- keep state transitions understandable
- avoid hidden magic

# Documentation rules

For generated files, comments, README, docs, commit messages:

Use normal professional technical English.
Do not use caveman style.
Be concise but polished.

# Response format after edits

After coding work, respond with only:

- files changed
- what changed
- build/test executed
- result
- next step

# DevTools

Diagnostic tools are in `DevTools\` (versioned, in project group).
Build all:

```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\DevTools\build_all.bat" 2>&1
```

Run tools (after building):

```powershell
# Inspect RSM binary structure
DevTools\Win64\Debug\RsmAnalyzer.exe     Win64\Debug\Debugme.rsm

# Find a method/class name in RSM and show surrounding bytes
DevTools\Win64\Debug\ScanRsmMethods.exe  Win64\Debug\Debugme.rsm TWidget.Create

# Dump function bytes from PE at hex RVA
DevTools\Win64\Debug\DumpFunc.exe        Win64\Debug\Debugme.exe 2CCA0 64

# Smoke-test adapter RSM parser against any .rsm file
DevTools\Win64\Debug\TestRsmParser.exe   Win64\Debug\Debugme.rsm

# Test nested-proc detection in MAP reader
DevTools\Win64\Debug\TestNested.exe      Win64\Debug\Debugme.map

# Prebuild .idx symbol-index sidecars for a directory (offline warm-up),
# or -verify that a parser change kept the sidecar format byte-identical
DevTools\Win64\Debug\PrebuildIdx.exe     <dir> [-r] [-j N] [-verify] [-force]
```

See `DevTools\README.md` for full documentation.

`build_all.bat` uses `cd /d %~dp0` internally — call it as:
```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\DevTools\build_all.bat" 2>&1
```
This pattern is pre-approved in `.claude/settings.json` (committed).

# Shell command patterns

A hook blocks any Bash or PowerShell command that starts with `cd <path> &&` or uses `cd` compounded with a path operation. **Never** generate that pattern.

Instead, put `cd /d %~dp0` **inside** a `.bat` file and call the bat with its full path:

```powershell
# WRONG — triggers hook, requires manual approval every time
PowerShell(cmd /c "cd /d C:\some\path && rsvars.bat && dcc64 Foo.dpr")

# RIGHT — cd is inside the bat; call with full path; pre-approved by .claude/settings.json
cmd /c "C:\Athens\GitHub\Win64Debugger\DevTools\build_all.bat" 2>&1
```

For one-off scripts: put them in the repo, add them to `.claude/settings.json` as a wildcard.
Do NOT add individual command strings to `.claude/settings.local.json` — that file is
machine-specific and would need to be recreated on every new computer.

# Integration tests

The automated test suite lives in `DebuggerTests\`. It launches the DAP adapter, exercises breakpoints/locals/step, and asserts correctness.

Run from any working directory — scripts use `cd /d %~dp0` internally:

```powershell
# Build everything + run tests
cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_and_run.bat" 2>&1

# Build only the test target (TestTarget.exe)
cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_target.bat" 2>&1

# Build only the test runner (RunTests.exe)
cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_runner.bat" 2>&1

# Run already-built tests (parallel workers, adaptive count)
cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\run_tests_parallel.bat" 2>&1

# Run already-built tests sequentially, in one process (the escape hatch)
cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\run_tests.bat" 2>&1
```

These patterns are pre-approved in `.claude/settings.json` (committed).
Run the full suite after every change to the adapter or RSM parser.

## Parallel execution

`build_and_run.bat` runs the suite as several concurrent `RunTests.exe` worker
processes — not threads: `DebuggerCore` has process-wide state, so in-process
parallelism would be a flakiness generator. Each worker takes a shard (a stable
hash of the test's full name) and writes its own XML and console log into
`DebuggerTests\Win64\Debug\`; `RunTestsParallel.exe` merges them into the usual
`TestResults.xml`.

| Variable / flag | Meaning |
|---|---|
| `RUNTESTS_JOBS` / `--jobs N` | Worker count. Default adapts to logical CPUs and free memory, capped at 8. |
| `RUNTESTS_JOBS=1` | Sequential: one unsharded worker, identical results, ~6x slower. First thing to try when parallelism is suspected in a failure. |
| `RUNTESTS_ONLY` / `--only` | Substring filter; passed through to every worker unchanged. |

A few tests reach for a process by NAME or take an exclusive lock on a shared
binary, so they cannot run beside a sibling worker. They are listed in
`NOT_PARALLEL_SAFE` in `RunTests.dpr` and run alone in a serial tail after the
shards finish. Add to that list rather than weakening a test if a new one turns
out to depend on being the only session on the machine.

### Sequential re-check of failures

The worker count adapts to the machine; whether the machine can actually sustain
it does not become visible until the run. A slower or busier machine than this
one can miss the same symbol-lookup deadline at a much lower worker count, and a
stranger who has just cloned the repository would read that as "the project is
broken".

So **when a parallel run produces any failure, the failing tests — and only
those — are re-run once with a single worker, and the sequential outcome is
authoritative.** Three outcomes, reported distinctly:

| outcome | console | `TestResults.xml` | exit |
|---|---|---|---|
| fails in parallel **and** alone | `FAILED in parallel AND again on the sequential re-check` | `success="False"`, `<failure>`, counted in `failures` | 1 |
| fails in parallel, **passes** alone | `LOAD-SENSITIVE -- these are NOT code defects` + the names | `result="LoadSensitive"`, `success="True"`, `<reason>`, counted in `load-sensitive` | 0 |
| passes everywhere | nothing | nothing | 0 |

The root element also carries `workers`, `load-sensitive` and
`recheck="performed|skipped-sequential|not-needed"`, so a CI or an agent reading
only the XML reaches the same verdict as a human reading the console.

Rules it holds to: it runs **only** when something failed and **only** for what
failed, so a green run pays nothing; it re-runs **once** — a test that passes on
the third attempt is a flake, not a pass; and `RUNTESTS_JOBS=1` skips it, since
there is no parallel/alone distinction to draw. A load-sensitive classification
is green-with-a-warning rather than red, because the sequential verdict is the
authoritative one — but it is never silent, and it names the tests.

Measured on 16C/32T: 1188 tests in 426 s sequential, 66 s at 8 workers, plus
~12 s of build. Throughput keeps rising past 8, but load-sensitive symbol
lookups start missing their deadline at 12+, so the cap is set by correctness
rather than by throughput — see the comment on `MAX_WORKERS_CAP`.

# Build

Use the existing build scripts when possible.

Build everything:

```bat
call build_debug.bat
```

This initializes the Delphi compiler environment, compiles `Debugme.exe` (emitting its `.map` and `.rsm`), and compiles `VisualStudioCodeDelphiDebugger.exe`.

Build adapter only:

```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\build_dap.bat" 2>&1
```

**Critical:** `build_dap.bat` does `pushd VisualStudioCodeDelphiDebugger` before compiling, so DCUs and EXE land in
`VisualStudioCodeDelphiDebugger\Win64\Debug\`. Running `dcc64` directly from the repo root puts output in `Win64\Debug\`
(wrong location — VS Code extension expects `VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe`).
Never invoke `dcc64 VisualStudioCodeDelphiDebugger\VisualStudioCodeDelphiDebugger.dpr` from the repo root without explicit `-E` and `-NU` overrides.

Manual debug target build:

```bat
call rsvars.bat
dcc64 Debugme.dpr
```

Debug target outputs:

```text
Win64\Debug\Debugme.exe
Win64\Debug\Debugme.rsm
Win64\Debug\Debugme.map
```

Compiler flags for debug targets:

| Flag | Purpose |
|---|---|
| `-$O-` | Disable optimization |
| `-V -VN -VR` | Generate debug info / MAP / RSM |
| `-DDEBUG` | Define DEBUG conditional |
| `-E.\Win64\Debug` | Output directory |

`Debugme.cfg` contains direct command-line compiler options, one per line, without leading `-`.
`Debugme.delphilsp.json` contains LSP-driven compiler options in `dccOptions`.
In this workspace it is already wired through `delphiLsp.settingsFile` in `DelphiDebuggerProj.code-workspace`.

# VS Code setup

Open `DelphiDebuggerProj.code-workspace`, not the folder directly.

Relevant files:

- `DelphiDebuggerProj.code-workspace`
- `Debugme.delphilsp.json`
- `.vscode/launch.json`
- `install\local.delphi-win64-debug\package.json` (the single canonical extension manifest)

Required extension:

- `embarcaderotechnologies.delphilsp`

Optional, and no longer needed for memory inspection:

- `ms-vscode.hexeditor` — backs VS Code's OWN "View Binary Data" pane (an inline
  icon on a Variables row, not a context-menu item: hexeditor 1.11.1 no longer
  contributes to `debug/variables/context`). That pane treats the
  `memoryReference` as byte 0 of a file, so it cannot scroll before the value,
  mark the value's extent, or show what changed — which is why the extension
  ships its own view (`View Memory (Delphi)`, `memoryView.js`), and that one
  needs no other extension at all. Keep hexeditor only if you want the stock
  pane as well. Never make it an `extensionDependencies` entry: an unreachable
  marketplace would then block the debugger over an optional view.

Local debugger extension folder:

```text
%USERPROFILE%\.vscode\extensions\local.delphi-win64-debug\
```

Install (build first, then one of):

- `install\Install.exe` — interactive: builds if needed, packages the extension
  into a `.vsix` and installs it into every detected VS Code-family editor
  (VS Code, Insiders, Cursor, Windsurf, VSCodium, Trae) via that editor's
  `<cli> --install-extension` (required on 1.96+; a plain folder copy is no
  longer loaded). Per editor it falls back to a folder copy only when the editor
  is present but its CLI is not on PATH. When no editor is detected it prints
  download links and the manual install command instead of blocking on a prompt
  (the `FamilyEditors` table in `Install.dpr` is the editor list).
- `install-dev.bat` — development: builds, then points the extension `program`
  directly at the build output (no copy; fastest iteration).

`install\local.delphi-win64-debug\package.json` is the single source of truth
for the extension manifest. It registers the `delphi-win64` debug type, declares
the full launch-config schema, and references the adapter via the relative path
`./VisualStudioCodeDelphiDebugger.exe`. It has no `main`, so no `extension.js`
is needed (a pure debug-type contribution that launches the external adapter).

# Symbol/debug-info notes

Delphi `.map` files provide line numbers and symbol addresses, but no full type/variable metadata.
The `.rsm` file is Embarcadero's Win64 remote debug symbol map.
It is not a GDB/WinDbg symbol format.
Real variable inspection will require parsing richer debug/type information or deriving enough runtime metadata from other sources.

Do not assume MAP-only debugging is enough for variables/watches.