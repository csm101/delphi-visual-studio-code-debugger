# How to create a new release

Everything is driven by `scripts/make_release.bat`. It builds the distributable zip,
renders the release notes from a template and creates a **draft** release on
GitHub with the zip attached. It never publishes: the last step is always a
human reading the draft.

---

## Before you start

You need:

- the Delphi toolchain on PATH (`rsvars.bat`, `dcc64`) — the release is built
  from source, not from whatever is lying in `dist\`;
- the GitHub CLI, authenticated: `gh auth login`. The script checks this before
  building, so an expired login costs you a message rather than a wasted build;
- push rights on `csm101/delphi-visual-studio-code-debugger`.

Nothing else. The script refuses to start rather than half-produce a release.

---

## 1. Decide the version

The version lives in **one** place:

```
install\local.delphi-win64-debug\package.json  ->  "version": "0.2.3"
```

Bump it there and nowhere else. The script reads it from that file, so the tag,
the zip name and the manifest VS Code registers cannot disagree — a release
whose tag says one thing and whose payload says another is very hard to support
afterwards.

Which digit to move:

| Change | Bump |
|---|---|
| Bug fixes, documentation, internal work | patch — `0.2.3` -> `0.2.4` |
| New capability, new launch property, new MCP tool | minor — `0.2.3` -> `0.3.0` |
| A launch configuration that used to work no longer does | major |

There is no way to override the version on the command line. That is deliberate.

---

## 2. Make sure the thing works

The release is a binary other people run, so this is not the moment to skip the
suite:

```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\DebuggerTests\build_and_run.bat"
cmd /c "C:\Athens\GitHub\Win64Debugger\install\extension-tests\run.bat"
```

A healthy full run is around 400 seconds and ends with `Tests Failed : 0`. Only
one suite may run at a time on a machine.

---

## 3. Commit and push

```powershell
git add -A
git commit -m "..."
git push
```

The release is tagged at the exact commit HEAD is on. If the remote does not
have that commit there is nothing for the tag to point at, so the script now
REFUSES rather than warning. Commits behind HEAD being unpushed is still only a
warning: that one is a judgement call, HEAD is not.

---

## 4. Write the "What's new"

Everything in the notes except this section is boilerplate and comes from
`install\RELEASE_NOTES_TEMPLATE.md`. Write only what changed, in a file:

```markdown
## What's new

- Attach: the process picker now shows each instance's main window caption
  and start time, so two copies of one application can be told apart.
- Fixed: the debug toolbar menu id was misspelled (`debug/toolbar` instead of
  `debug/toolBar`), so the "create a rule" button had never appeared.
```

Write it for someone who has not read the commits. "Fixed a bug in the picker"
tells a user nothing; naming the symptom they saw tells them whether to upgrade.

Keep the file wherever you like — it is an input, not part of the repository.

---

## 5. Build the draft

Dry run first. It renders the notes, prints the numbers and sends nothing:

```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\scripts\make_release.bat -DryRun -Highlights whatsnew.md"
```

Read the output. Then, for real:

```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\scripts\make_release.bat -Highlights whatsnew.md"
```

What happens, in order:

1. checks `gh` is installed and authenticated;
2. reads the version from the extension manifest;
3. refuses if a release or draft with that tag already exists;
4. warns about unpushed commits, and REFUSES if HEAD itself is not on the
   upstream branch — the tag is created at that exact commit;
5. runs `scripts/build_setup_zip.bat` — which rebuilds the adapter, the MCP server, the
   installer, and stages the extension (including `Zydis.dll`, the optional
   disassembly backend, and its MIT licence text — a missing
   `ThirdParty\Zydis\bin\x64\Zydis.dll` at build time is a printed warning,
   not a failed build, since disassembly degrades to unavailable without it
   rather than blocking anything else);
6. computes the zip's SHA-256;
7. renders the template, substituting the version, the hash, the MCP tool count
   (read from `MCPDebugger\McpToolSchemas.pas`) and your "What's new";
8. refuses to continue if any `{{PLACEHOLDER}}` survived;
9. creates the **draft** release and uploads the zip.

Options:

| Flag | Effect |
|---|---|
| `-DryRun` | Render and report only. Nothing is sent to GitHub |
| `-SkipBuild` | Reuse the zip already in `dist\`. For a second attempt after a notes-only fix |
| `-Highlights <file>` | The "What's new" text. Omitting it produces a release with no such section, and the script says so |
| `-Verify` | Run AFTER publishing. Checks the tag landed on the commit the release was built from. Does nothing else |

---

## 6. Read the draft, then publish

The draft is visible only to people with write access. Open it from the
**Releases** tab and check:

- the "What's new" reads like something written for a user;
- the version in the title matches the zip name;
- the zip is attached and its size is plausible (about 4.5-5 MB, including
  `Zydis.dll` staged twice — once inside the extension folder, once next to
  `Setup.exe` for the MCP server install).

Then publish:

```powershell
gh release edit v0.2.4 --draft=false
```

or press **Publish release** on the page. The tag is created at that moment —
which is why the draft's URL contains `untagged-...` and changes every time you
edit it. Do not paste that URL anywhere; after publishing the address is
`/releases/tag/v0.2.4` and stable.

---

## 7. Check where the tag landed

**This is the step that did not exist, and its absence let one mistake ship four
times.**

```powershell
cmd /c "C:\Athens\GitHub\Win64Debugger\scripts\make_release.bat -Verify"
```

The tag does not exist until you publish: GitHub creates it then, from the
release's target. So this is the first moment it can be checked at all, and it
must be checked here rather than assumed at step 5.

It prints the target recorded on the release and the commit the tag actually
points at, and fails if they differ — or if the target is a BRANCH NAME rather
than a commit, which is how the two drift apart. Between 0.5.0 and 0.6.2 the
script passed `--target main` while releases were being built from another
branch; every draft, every zip and every set of notes was correct, and all four
tags landed on the same eleven-day-old commit. `gh release view` showed nothing
wrong, because it does not compare those two things. Nothing did.

---

## 8. Check what a stranger sees

```powershell
gh release view v0.2.4
```

Better, download the zip from the release page into an empty folder and run
`Setup.exe` there. That is the only way to test what you actually shipped rather
than what is on your build machine.

---

## If something is wrong after publishing

A published release can be pulled back:

```powershell
gh release edit v0.2.4 --draft=true      # hide it again
gh release delete v0.2.4 --yes           # remove it entirely
git push --delete origin v0.2.4          # and its tag
```

Anyone who already downloaded the zip still has it, so for a serious defect
prefer releasing a fixed version over quietly deleting the broken one.

---

## Notes

- **The executables are not signed.** Users will see SmartScreen's "Windows
  protected your PC". The release notes say so and point at building from
  source; do not remove that paragraph to make the release look tidier.
- `dist\` is gitignored. The zip and the rendered notes are build output; the
  release page is where they live, not the repository.
- Changing the boilerplate for every future release means editing
  `install\RELEASE_NOTES_TEMPLATE.md`. Its placeholders are `{{VERSION}}`,
  `{{SHA256}}`, `{{MCP_TOOL_COUNT}}` and `{{HIGHLIGHTS}}`; adding a new one
  requires teaching `scripts/make_release.ps1` to substitute it, or the guard in step 8
  will stop the release.
