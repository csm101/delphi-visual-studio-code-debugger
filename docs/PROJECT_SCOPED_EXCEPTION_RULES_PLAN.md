# Project-scoped exception rules — plan

Status: **DONE** (2026-08-23), shipped in v0.6.4. Every acceptance criterion
below is covered by a test, and the removal of the launch-configuration scope
is pinned by one of its own (`RulesInTheLaunchRequest_AreNotRead`) so a revival
of the field reads as the regression it would be. Companion change:
`EditInVsCodeDelphiPlugin` writes the `delphiProjectFile` line this plan reads
(separate repository).

What landed differs from the spec below in one place worth knowing. The plan
kept `exceptionRules` in a launch configuration as a third tier "for backward
compatibility"; it was then removed outright, because its whole effect was to
let "Debug X" and "Attach to X" -- one project, started two ways -- disagree
about which exceptions matter. See `DAP_DEBUGGER_ARCHITECTURE.md` ->
"The precedence chain" for what the code actually does.

## The problem, stated precisely

`exceptionRules` today lives only in `launch.json`, at two possible scopes:
one array per individual launch/attach **configuration**, or one array in the
machine-wide global file. Neither is the scope a Delphi developer actually
thinks in.

Verified against a real multi-package scenario the user described: a host
application (e.g. `hydra2.exe`) loads dozens of BPLs, each its own `.dpk`
project with its own developer. The debugger has **no concept of "which
Delphi project the programmer is working on"** — checked against
`DebuggerCore`, which never references `.dproj`/`.dpk`/`.dpr` anywhere. All it
knows is: the launched/attached executable (`program`), the modules that
happen to be loaded in that process at runtime, and source files resolved by
unit basename. None of that is "the project the developer opened in the IDE."

The one place that information genuinely exists is the RAD Studio IDE itself,
at the moment a developer clicks *Open in Visual Studio Code* —
`EditInVsCodeDelphiPlugin` already resolves the **active project** via
`(BorlandIDEServices as IOTAModuleServices).GetActiveProject` and its
`.FileName` (`DGVisualStudioCodeIntegration.pas`, confirmed at the call sites
building `BuildProgramLaunchConfig`/`BuildPackageLaunchConfig`). That plugin
already writes the generated `launch.json`; it is a small, low-risk change to
have it also write down *which project this configuration is for* — see the
companion instructions for that repo.

## What this plan adds

A new **optional** launch/attach argument, supplied by the plugin (or by
hand): `delphiProjectFile` — the absolute path to the `.dpr` or `.dpk` the
configuration was generated for (the file the plugin's existing dpr/dpk
sibling-file check already discriminates).

When present, it names two sidecar files, sitting next to the project itself
— not in `.vscode/`, not in the user profile — so they travel with the
project in whatever VCS it lives in:

```
<dir of delphiProjectFile>\<ProjectBaseName>.ExceptionSettings.json         (shared — commit this)
<dir of delphiProjectFile>\<ProjectBaseName>.ExceptionSettings.local.json   (personal — gitignore this)
```

E.g. for `C:\...\hydra_2\TabAnag\libTabAnagD29.dpk`:
`libTabAnagD29.ExceptionSettings.json` and
`libTabAnagD29.ExceptionSettings.local.json` in that same folder — the
package's own rules, readable by every developer on that package regardless
of which host `.exe` they launch or attach to test it, and independent of
every other package sharing the same host process.

Same file shape as the existing global file: a bare array of rules, or an
object with an `exceptionRules` key. Same strict-JSON rule (no JSONC) — do
not special-case these two files, reuse whatever the global file's loader
already does.

## Precedence

**`exceptionRules` in `launch.json` is removed, not kept.** Decided
explicitly: there is no scenario where debugging the *same* program should
apply different rules depending on whether the session launched it or
attached to an already-running instance — "launch vs. attach" and "which
rules apply" are orthogonal, and conflating them was the whole problem this
plan exists to fix. No migration warning either — the field simply stops
being read. This is a deliberate breaking change for anyone with rules
directly in a launch configuration today; the user made that call knowingly
and does not want it softened.

`BuildAllExceptionRules` becomes one ordered list, most specific first:

1. `<Project>.ExceptionSettings.local.json` — personal, this machine only
2. `<Project>.ExceptionSettings.json` — the project's own, shared with the team
3. The global machine-wide file — unchanged, still last

First match wins, same as today. When `delphiProjectFile` is absent
(hand-written `launch.json`, or an older plugin version) no sidecar tier is
looked for — only the global file applies, same as a fresh install that has
never had `exceptionRules` in a launch config at all. A missing sidecar file
is not an error, exactly like the existing global file's "file may not exist
yet" handling.

Remove the `exceptionRules`-in-launch-config path everywhere it's read
(`DapServer.ParseExceptionRules` and wherever `BuildAllExceptionRules`
currently takes project rules as an argument) — do not leave dead code that
still parses a key nobody can act on. Grep the docs site
(`mca-software.github.io`, chapter 4) for `exceptionRules` too when this
ships; that's a separate follow-up repo, but flag it as stale once this
lands so it doesn't get missed.

## Open questions to resolve while building, not to guess now

- **Hot-reload.** The global file is already re-read on every resume, which
  is explicitly documented as a deliberate workflow ("edit the shared file,
  press F5, and it is gone"). Decide whether the two new sidecar files get
  the same treatment — probably yes, for the same reason, but verify the
  actual re-read mechanism (`ApplyExceptionRules` /
  `Test_GlobalExceptionRules_HotReloadOnResume`) generalizes cleanly to a
  per-session file path rather than one fixed global path.
- **GUI editor's "Select where the exception rules live" picker**
  (`exceptionRulesEditor.js`) loses its per-launch-configuration entries
  entirely — there is no `exceptionRules`-in-launch-config target left to
  point at — and gains "`<Project>` rules (shared)" and "`<Project>` rules
  (local)" when a session's `delphiProjectFile` is known, alongside the
  unchanged global entry. Check whether the editor currently has any
  live-session awareness at all (it reads `launch.json` statically today per
  `install\local.delphi-win64-debug\exceptionRulesEditor.js`) or whether it
  needs a new way to learn the resolved `delphiProjectFile` of a running
  session — do not assume a wiring path that does not exist yet. With no
  session running and no project file resolvable, the picker's only choice
  left may be the global file — decide whether that means skipping the
  picker prompt entirely in that case, consistent with the existing "only
  one possible target" skip behavior.
- **What if two configurations in the same file disagree** on
  `delphiProjectFile` (e.g. a stale one after a project rename)? Match
  whichever configuration is actually being launched/attached — this is a
  per-launch resolved value, not a file-level one, so there is nothing to
  reconcile; just don't cache it across sessions.

## Explicitly out of scope here

The same `launch.json` also duplicates `sourceSearchPaths`, `mapFile`,
`rsmFile` verbatim between a project's launch and attach configurations
(confirmed: 260+ identical lines in `Win64Debugger\.vscode\launch.json`
itself, between "Debug Debugme" and "Attach to Debugme.exe"). That is a real,
related problem, but a different one — solving it is deferred; do not fold a
general launch-config-inheritance mechanism into this plan.

## Acceptance criteria

- `Debugme.dpr` itself is the first test case: a
  `Debugme.ExceptionSettings.json` next to it, exercised via both the launch
  and the attach configuration in `Win64Debugger\.vscode\launch.json`,
  proving the same project-level rule applies regardless of which
  configuration reaches it.
- A second, real package scenario: `DebuggerTests\TestPackage\TestPkgUnit.pas`
  already has a package-scoped exception marker (`{BP:PKG_EXC_HANDLER}`) — if
  a `.dpk` exists for that fixture, add its sidecar file and prove a rule
  scoped to the package fires regardless of the host executable.
- Precedence proven in both directions: a local sidecar rule overriding a
  project sidecar rule for the same exception, and a project sidecar rule
  overriding what the global file would have done, exactly as the ordering
  above states — not assumed from the ordering alone.
- A rule still present under `exceptionRules` in a launch configuration is
  proven to have **no effect at all** — a test that plants one there and
  confirms it does not fire, so a silent leftover "removal" of this code
  path does not quietly resurrect itself.
- `delphiProjectFile` absent: resolution falls back to the global file only
  — the same as a fresh install that has never used the launch-config path.
  Regression-test this explicitly.
- Full suite green: `cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_and_run.bat" 2>&1`.
- Document the new field, the sidecar file shape, and the precedence order in
  chapter 4 of the docs site (`mca-software.github.io`) once shipped — that
  is a separate follow-up, not part of this repo's work.
