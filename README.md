# Delphi Win64 Debugger

Debug Delphi Win64 applications outside the Embarcadero IDE — a real debugger
built on the Windows Debug API, written in Delphi.

The repository contains **three programs** that share one debugger engine:

| | What it is | Where it lives |
|---|---|---|
| **Debug adapter** | A **Debug Adapter Protocol (DAP)** server. This is the debugger itself: breakpoints, stepping, call stacks, variables, expression evaluation. Any DAP client can drive it. | `VisualStudioCodeDelphiDebugger\` |
| **VS Code extension** | The client that makes it usable in the editor: the `delphi-win64` debug type, the process picker for attaching, status-bar progress, and an editor for the exception rules. | `install\local.delphi-win64-debug\` |
| **MCP server** | The same engine exposed to an **AI agent** over the Model Context Protocol — 31 tools (`set_breakpoint`, `step_into`, `get_locals`, `evaluate_expression`, `get_call_stack`, …). It lets an agent run a program, stop it, and read its actual state instead of guessing from the source. | `MCPDebugger\` |

The engine is shared: `DebuggerCore\` holds the Windows Debug API loop, the
symbol readers (`.rsm`, TD32, `.map`, `.dcp`, JCL) and the expression evaluator.
The three front ends are thin.

> **You will almost certainly also want the [Delphi IDE plugin](https://github.com/csm101/EditInVsCodeDelphiPlugin).**
> It adds an *Open in VS Code* command to the Delphi IDE that generates the
> workspace and the launch configuration for the current project: output paths,
> source root, unit search paths, and the package list for a BPL project. A real
> Delphi project carries a couple of hundred search paths, and nobody wants to
> write that by hand. The debugger works without it if you write `launch.json`
> yourself, but the plugin is what makes it practical — install it first.

> ⚠️ **Compile the program you want to debug with full debug information, or
> most of this will not work.** A debugger can only show what the compiler
> emitted. In the Delphi project options, for the **Win64 Debug** configuration:
>
> - *Compiling* → **Optimization off**, **Debug information** on, **Local symbols** on;
> - *Linking* → **Debug information** on, **Include remote debug symbols** on
>   (this is the `.rsm`), and **Map file: Detailed**.
>
> On the command line that is `-$O- -V -VN -VR`, which is what `Debugme.cfg` in
> this repository uses. Measured on that project: those four flags alone already
> emit the `.exe` with its TD32 section, the `.map` **and** the `.rsm` — `-GD`
> (Map file: Detailed) turned out not to be required for a `.map` to appear,
> though it is what the IDE sets and it does no harm. Keep the `.map` and `.rsm`
> next to the `.exe`.
>
> To step **into the RTL and VCL** rather than over them, also enable
> *Compiling* → **Use debug .dcus**.
>
> What each one buys you:
>
> | Artefact | Without it |
> |---|---|
> | TD32 section, `.map`, or JCL data — **any one** | no source lines: no breakpoints, no stepping |
> | **`.rsm`** | breakpoints and stepping still work, but local variables, types and expression evaluation are severely limited |
> | optimizations **off** | breakpoints land on the wrong line and locals read as garbage, because the code no longer matches the source |
>
> The same applies to every **runtime package** you want to step into: a BPL
> compiled without debug information stays a black box even when the host has
> full symbols.

> **Status**: working and feature-rich. Launch and attach, breakpoints
> (line / conditional / hit-count / log-points), stepping (over/into/out)
> and set-next-statement, call stack with function names, variable
> inspection (locals, registers, globals, nested object / record /
> dynamic-array expansion) with type-aware formatting, a full Pascal
> expression evaluator for watch/hover/REPL, `setVariable` (primitives,
> strings, enums, sets, `var` parameters), and a configurable exception
> engine (filters + per-exception rules) are all functional. See
> [What works](#what-works) for the full list.

---

## Prerequisites

| Tool | Purpose |
|---|---|
| **Delphi 10.3 Rio or later** (`dcc64` in PATH after `rsvars.bat`) | Compiling the adapter and the debug target |
| **VS Code** | The editor the extension plugs into |
| **[Delphi IDE plugin](https://github.com/csm101/EditInVsCodeDelphiPlugin)** | Generates the workspace and launch configuration from a Delphi project. Not strictly required, but see the note above |
| **DelphiLSP extension** (`embarcaderotechnologies.delphilsp`) | Delphi language support in VS Code (syntax, autocomplete). A separate Embarcadero extension; this one only debugs |
| **JCL sources** (optional) | Only for the default JCL debug-info support; build with `JCL_DEBUG_OFF` to omit it — see [Optional: JCL debug-info support](#optional-jcl-debug-info-support) |

---

## Quick start

> **Just want to use it?** Do not build anything. Grab
> `delphi-win64-debugger-setup-*.zip` from the
> [latest release](https://github.com/csm101/delphi-visual-studio-code-debugger/releases),
> extract it anywhere and run `Setup.exe`. The debug adapter, the MCP server and
> the VS Code extension are already compiled inside it, so no Delphi toolchain
> and no build step are needed on that machine. Windows will warn that the
> executables are unsigned — see the notes in the release.
>
> The rest of this section is for working **on** the debugger from a source
> checkout.

Assumes Delphi (Athens or later) is installed and `dcc64` is on PATH after
`rsvars.bat`, plus VS Code.

This is the path for working **on** the debugger from a source checkout — it
installs the extension in development mode, where VS Code launches the adapter
straight from the compiler output, so rebuilding is enough to pick up changes
(no copy step). To install the debugger only to *use* it, or to ship it to a
machine without the sources, see the alternatives right after.

```bat
:: 1. Get the repository
git clone <repository-url> Win64Debugger
cd Win64Debugger

:: 2. Build the adapter and install the extension in DEVELOPMENT mode. It writes
::    a manifest whose "program" points directly at the build-output exe, so a
::    rebuild is reflected on the next debug session with no copy. Run once.
call install-dev.bat

:: 3. Build the bundled sample so there is something to debug. A fresh clone
::    has no .exe/.map/.rsm (they are gitignored), so build them once.
call rsvars.bat
dcc64 Debugme.dpr
```

Now open the project and start a session:

1. If VS Code prompts to install the recommended **DelphiLSP** extension
   (`embarcaderotechnologies.delphilsp`, from `.vscode/extensions.json`), accept.
2. Open **`Win64DebuggerProj.code-workspace`** — open the *workspace file*, not
   the folder; it wires up DelphiLSP and the compiler settings.
3. Reload the window (`Ctrl+Shift+P` → *Developer: Reload Window*).
4. In **Run and Debug** (`Ctrl+Shift+D`) pick **"Debug Debugme (Delphi DAP)"**
   and press `F5`. You should hit the entry point and be able to step, set
   breakpoints, and inspect variables.

After a change to the adapter source, the edit/test loop is just:

1. Stop the running debug session (`Shift+F5`) — the exe is locked while it runs.
2. `call build_dap.bat`
3. `F5` — VS Code relaunches the freshly built adapter. No re-install, no copy.

To debug your **own** application instead, compile it with debug info
(`-V -VN -VR`, optimizations off) so it emits `.map` and `.rsm` next to the
`.exe`, then add a launch configuration — see
[Launch configuration](#launch-configuration).

> **Install to use, not develop** — to copy the adapter into the extensions
> folder (so it no longer depends on the checkout) run `build_installer.bat`
> then `install\Install.exe`. It is interactive: builds the adapter if needed,
> detects VS Code / VS Code Insiders, updates an existing install in place after
> confirmation. See [VS Code extension setup](#vs-code-extension-setup).

> **Ship to another machine** — to install on a machine **without** the
> repository or a Delphi toolchain, build a self-contained zip with
> `build_setup_zip.bat` and ship it — see
> [Distributable zip](#distributable-zip-no-repo-no-delphi-on-the-target).

---

## Build

### One-shot: build everything

```bat
call build_debug.bat
```

This initializes the Delphi compiler environment (`rsvars.bat`), compiles `Debugme.exe` (emitting its `.map` and `.rsm`), and compiles `VisualStudioCodeDelphiDebugger.exe`.

### Adapter only (faster iteration)

```bat
call build_dap.bat
```

### Compiler flags for the debug target

Key flags that must be active when compiling the program you want to debug:

| Flag | Purpose |
|---|---|
| `-$O-` | Disable optimizations |
| `-V -VN -VR` | Generate debug info and `.map` file |
| `-DDEBUG` | Optional conditional define |
| `-E.\Win64\Debug` | Output directory |

For `Debugme` these are set in `Debugme.cfg` (one per line, without the leading `-`).

### Optional: JCL debug-info support

The adapter can additionally read **JCL** (JEDI Code Library) debug data — the
MAP-derived symbol table JCL stores either as a linked `JCLDEBUG` PE section or a
sidecar `.jdbg` file — as an address→location and procedure-name fallback for
modules that ship JCL data but no embedded TD32 / no `.map`. It is implemented in
`DebuggerCore\JclDebugReader.pas` and gated by the `JCL_DEBUG` conditional.

`JCL_DEBUG` is **ON by default**, which requires the JCL sources to be present.
The build configurations point at the default install location
`C:\Athens\jcl\jcl\source` (subdirectories `windows`, `common`, `include`); adjust
those paths if your JCL lives elsewhere. The affected configs are the adapter
`VisualStudioCodeDelphiDebugger\VisualStudioCodeDelphiDebugger.cfg`, the test
runner `DebuggerTests\RunTests.cfg`, and `build_mcp.bat`.

**To build without JCL** (e.g. JCL is not installed): compile with the
`JCL_DEBUG_OFF` conditional defined. This removes the `uses JclDebug` entirely, so
JCL need not be installed and the JCL search paths are ignored (they are harmless
when the define is off). Add the define to the relevant `.cfg` files, e.g.:

```text
-DJCL_DEBUG_OFF
```

into `VisualStudioCodeDelphiDebugger.cfg`, `DebuggerTests\RunTests.cfg`, and pass
`-DJCL_DEBUG_OFF` on the `dcc64` command line in `build_mcp.bat`. With the define
off, `JclDebugReader` compiles to a no-op factory (it never registers a provider);
everything else — TD32, `.map`, `.rsm`/`.dcp` symbol resolution — is unaffected.

> If you build the adapter, MCP server, or test runner from the **IDE** (msbuild
> via the `.dproj`) rather than these command-line scripts, apply the same choice
> there: add the JCL search paths (to keep it on) or the `JCL_DEBUG_OFF` define (to
> turn it off) in the project options, since an IDE build regenerates the `.cfg`
> from the `.dproj`.

### Optional: pre-build the symbol-index sidecars

The first time the debugger reads a module's `.rsm` or `.dcp`, it scans the whole
container to build a lookup index, then caches that index in a `<file>.idx`
sidecar next to it. The scan costs roughly half a second for a 45 MB package;
every later session reloads the sidecar in a few milliseconds instead.

The catch is *when* that scan happens: lazily, at a stop, on the thread the
debugger answers requests on. Stopping somewhere that first touches several
runtime packages therefore pauses the session while they are indexed.

The RTL and third-party packages never change between your builds, so their
sidecars can be built once, offline:

```bat
cmd /c "C:\Athens\GitHub\Win64Debugger\DevTools\build_all.bat"

rem the Delphi DCP corpus - a few hundred files, one pass, a few minutes
DevTools\Win64\Debug\PrebuildIdx.exe "C:\Users\Public\Documents\Embarcadero\Studio\23.0\Dcp\Win64" -j 2
```

Add `-force` when sidecars already exist but were written by an older build of
this project: a change to the index format or to the parser leaves them stale,
and a stale sidecar is ignored, so the cold scan is paid again in every session
until they are rebuilt.

This does **not** help your own packages — you recompile those constantly, which
invalidates their sidecars by design. If it is worth automating, run the tool
over your output directory as a post-build step.

Source is `DevTools\PrebuildIdx.dpr`; `DevTools\README.md` documents the full
flag list, including `-verify`, which rebuilds every sidecar and compares it by
SHA-256 against the one already on disk (useful after touching a parser).

---

## Tests

An automated integration suite lives in `DebuggerTests\`. It builds a dedicated
test target, launches the real DAP adapter against it, and asserts correctness of
breakpoints, stepping, locals, and the expression evaluator. Run the full suite
after any change to the adapter or the RSM/TD32 parsers.

```bat
:: build the target + the runner, then run everything
call DebuggerTests\build_and_run.bat
```

The scripts use `cd /d %~dp0` internally, so they can be called from any working
directory. Finer-grained entry points:

| Script | Purpose |
|---|---|
| `DebuggerTests\build_and_run.bat` | Build the test target and runner, then run the suite |
| `DebuggerTests\build_target.bat` | Build only the debuggee (`TestTarget.exe`) |
| `DebuggerTests\build_runner.bat` | Build only the test runner (`RunTests.exe`) |
| `DebuggerTests\run_tests.bat` | Run the already-built tests |

Separate diagnostic tools (RSM/TD32 inspectors, PE dumpers) live in `DevTools\`;
see `DevTools\README.md`.

---

## VS Code extension setup

The extension lives in a local directory under VS Code's extension folder. It is **not** published to the marketplace.

### Recommended: the installer

After building the adapter (`build_dap.bat`), run:

```bat
call build_installer.bat
install\Install.exe
```

`Install.exe` stages the freshly built adapter next to the extension
manifest, detects your VS Code installation(s), and copies the extension
into `%USERPROFILE%\.vscode\extensions\local.delphi-win64-debug\`. If a
previous version is already installed it updates it in place (after
confirmation). Reload VS Code afterwards.

### Scripted alternative

```bat
:: build the adapter and stage it into install\local.delphi-win64-debug\
call update-install.bat
:: copy the staged folder into your VS Code extensions directory
call install\install.bat
```

### Manual

1. Build the adapter (`build_dap.bat`).
2. Create the folder
   `%USERPROFILE%\.vscode\extensions\local.delphi-win64-debug\`.
3. Copy `install\local.delphi-win64-debug\package.json` and the built
   `VisualStudioCodeDelphiDebugger.exe`
   (`VisualStudioCodeDelphiDebugger\Win64\Debug\`) into it.
4. Reload VS Code (`Ctrl+Shift+P` → *Developer: Reload Window*).

The bundled `package.json` registers the `delphi-win64` debug type and
points at the adapter via the relative path `./VisualStudioCodeDelphiDebugger.exe`,
so no path editing is needed as long as the executable sits beside it.

### Where the adapter executable ends up

The build, the staging step and the install each hold a copy:

| Stage | Location |
|---|---|
| Build output | `VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe` |
| Staging (gitignored, inside the repo) | `install\local.delphi-win64-debug\VisualStudioCodeDelphiDebugger.exe` |
| Installed (what VS Code launches) | `%USERPROFILE%\.vscode\extensions\local.delphi-win64-debug\VisualStudioCodeDelphiDebugger.exe` |

### Distributable zip (no repo, no Delphi on the target)

To install the debugger on another machine that has neither the repository nor a
Delphi toolchain, build a self-contained zip on a development machine:

```bat
call build_setup_zip.bat
```

It builds the adapter, builds the portable installer, and bundles everything into
`dist\delphi-win64-debugger-setup-v<version>.zip`:

```text
Setup.exe                     ← portable installer / updater
local.delphi-win64-debug\     ← the extension (manifest + prebuilt adapter exe)
INSTALL_INSTRUCTIONS.md
```

On the target machine: extract the zip anywhere and run `Setup.exe`. It detects
the local VS Code installation(s) and copies the extension; **if a previous
version is already installed it updates it in place**. No build step is needed —
the adapter is already compiled inside the zip.

`Setup.exe` is the same program as `install\Install.exe`. It auto-detects its
context: with the adapter already staged beside it (the zip layout) it runs in
**portable** mode and installs the bundled files directly; inside the repository
it runs in **repository** mode and builds/stages from the build output first.

### Development install (fast iteration)

The installs above copy the adapter, which is right for distribution but
awkward while changing the adapter: every fix would need a rebuild plus a
re-copy. For development use `install-dev.bat` instead — it builds the adapter
(`build_dap.bat`) and then writes a `package.json` into the extensions folder
whose `program` points **directly** at the build-output executable (no copy).
On a fresh clone this single command is enough (no separate build step):

```bat
call install-dev.bat   :: builds + installs; run once
```

After that, the edit/test loop for the **adapter** is just:

1. Stop the running debug session in VS Code (`Shift+F5`) — the executable is locked while it runs.
2. `call build_dap.bat`
3. `F5`

No re-install, no copy: VS Code relaunches the freshly built adapter.

The **extension** is a different matter, because VS Code loads its code from the
installed folder rather than from the repository. `install-dev.bat` mirrors the
staged extension files (`extension.js`, the webview assets, the manifest) into
that folder, so after changing any of them the loop is:

1. `call install-dev.bat`
2. *Developer: Reload Window* in VS Code

A change to the extension's **version** is the one thing this cannot deliver. VS
Code registers an extension by id and version — the folder name and its own
registry both carry the version it was installed with, and only VS Code's
installer writes those. So the synced manifest deliberately keeps the registered
version and everything else in it (new commands, new launch properties) still
arrives; the script says so when the two differ. To move to a new version, run
`install\Install.exe` once, which installs the `.vsix` through VS Code and lets
it retire the previous folder itself.

Both modes use the same `local.delphi-win64-debug` folder, so switching is just a
matter of re-running `install-dev.bat` (dev) or `install\Install.exe`
(distribution copy).

| Mode | `program` points at | After a fix |
|---|---|---|
| `Install.exe` (local distribution copy) | a copy in the extensions folder | rebuild + re-run the installer + reload |
| `build_setup_zip.bat` (ship to another PC) | a copy from the extracted zip | rebuild the zip + re-run `Setup.exe` on the target |
| `install-dev.bat` (development) | the build output directly | stop session + rebuild + `F5` |

---

## Launch configuration

`.vscode/launch.json` for the project being debugged:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug Delphi Win64",
      "type": "delphi-win64",
      "request": "launch",
      "program": "${workspaceFolder}/Win64/Debug/MyApp.exe",
      "mapFile": "${workspaceFolder}/Win64/Debug/MyApp.map",
      "sourceRoot": "${workspaceFolder}",
      "stopAtEntry": true
    }
  ]
}
```

| Property | Default | Description |
|---|---|---|
| `program` | *(required)* | Path to the `.exe` to debug |
| `mapFile` | same path as `program` with `.map` extension | Delphi MAP file |
| `sourceRoot` | *(empty)* | Root directory for source file lookup |
| `stopAtEntry` | `false` | Break at the process entry point before any user code runs |
| `exceptionRules` | *(empty)* | Per-exception rule table — see [Exception handling](#exception-handling) |
| `useGlobalExceptionRules` | `true` | Also load the shared machine-wide rules file — see [Shared rules across projects](#shared-rules-across-projects) |
| `globalExceptionRulesPath` | `%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json` | Custom location for the shared rules file |

Source files are resolved by searching `sourceRoot` and one level of subdirectories. If a source file appears in multiple locations, the first match wins.

---

## Exception handling

### Filters and what is shown

The **BREAKPOINTS** view exposes four exception filters:

| Filter | Meaning |
|---|---|
| `delphi` | First-chance Delphi-raised exceptions (`$0EEDFADE`). Accepts an optional condition: a comma-separated class-name list. |
| `av` | First-chance access violations |
| `all` | Every other first-chance exception (noisy) |
| `unhandled` | Unhandled / second-chance exceptions (always on) |

When the debugger stops on an exception it reports both the **class name** and the
**message** (read from `Exception.FMessage`), e.g. `EOracleError: ORA-00942: table
or view does not exist`. VS Code shows this in the exception widget and, via the
`exceptionInfo` request, in the details panel.

### Inspecting the current exception (`$exception`)

While stopped on a Delphi exception, the live exception object is available as a
synthetic **`$exception`** pseudo-variable:

- **Variables panel** — it appears at the top of the **Locals** scope. Its value is
  `Class: Message`; click the chevron to expand it and inspect the class, `Message`,
  and any fields/properties, exactly like a normal object.
- **Watch** — add an entry `$exception` (drag the Locals row into Watch, or type it),
  then expand it. For a specific member, expand the object — e.g. open `$exception`
  and read its `Message` child.
- **Hover** — hovering `$exception` in the editor shows the same value.

It is present only on an exception stop (it disappears on the next breakpoint/step
stop) and reflects the Delphi exception object; access violations have no Delphi
object, so `$exception` is not shown for them (the class/message summary still is).

### Per-exception rules (`exceptionRules`)

The four filters are coarse. For fine-grained control add an `exceptionRules`
array to the launch config. Each rule matches an exception on any combination of
criteria and selects an **action**. Rules are evaluated top-down, **first match
wins**; if no rule matches, the filter selection above decides (so existing setups
keep working).

**Match criteria** (all specified criteria must hold; omitted = wildcard):

| Field | Matches |
|---|---|
| `class` | Exact match on the **runtime** class name, or an array of names (any-of), case-insensitive. Leaf-only — does not match descendants |
| `classIs` | Matches the runtime class **or any ancestor** (Delphi `is` semantics), single name or array, case-insensitive — e.g. `"classIs": "Exception"` catches every `Exception` descendant |
| `code` | The **Win32 exception code**, or an array of codes (any-of). Hexadecimal (`"0xC0000005"`, `"$C0000005"`) or decimal (`3221225477`, or the signed form `-1073741819`), as a JSON string or number |
| `message` | Case-insensitive substring of the exception message |
| `messageRegex` | Regular expression against the message (ignore-case) |
| `unit` | Source unit where the exception was raised (`OracleData` or `OracleData.pas`). The special value `"*unknown*"` matches raises with no resolvable source |
| `line` | Exact source line where raised |
| `lineFrom` / `lineTo` | Inclusive source-line range |

> Unit/line refer to the **raise site** — the first stack frame with known source.
> For a Delphi `raise` the OS exception address is inside the RTL, so the debugger
> walks to the first user frame; for access violations it is the faulting line.

> **`code` is the only criterion that can match a native Windows exception.**
> A native exception — one raised through `RaiseException` rather than by a
> Delphi `raise` — carries no exception object, so it has no class and no
> message: the Delphi criteria (`class`, `classIs`, `message`, `messageRegex`)
> can never match it, and without `code` the only way to silence one was to turn
> off the whole `all` filter. Typical cases are `0xE06D7363` (a C++ exception
> thrown inside a C++ DLL), `0xC0000094` (integer divide by zero) and any
> customer-defined code a third-party library raises. Delphi's own raise is
> `0x0EEDFADE` and an access violation is `0xC0000005`, so `code` works for those
> too.
>
> One native code needs no rule: the thread-name announcement `0x406D1388` that
> `TThread.NameThreadForDebugging` raises is debugger protocol traffic, and the
> adapter consumes it before the rules run — it never surfaces as a stop, not
> even with the `all` filter on.

**Actions:**

| Action | Effect |
|---|---|
| `ignore` | Resume immediately — no stop, no log |
| `log` | Write `class: message` to the debug console, then resume |
| `logStack` | Like `log`, plus the formatted call stack |
| `break` | Pause the debuggee in the debugger (the default behaviour) |

**Examples:**

```jsonc
{
  "type": "delphi-win64",
  "request": "launch",
  "program": "${workspaceFolder}/Win64/Debug/MyApp.exe",
  "exceptionRules": [
    // EAbort is control-flow noise: never break on it.
    { "class": "EAbort", "action": "ignore" },

    // Log every Oracle error (with stack) but keep running.
    { "messageRegex": "ORA-\\d+", "action": "logStack" },

    // Break only for AVs raised inside a hot method's line range.
    { "class": "EAccessViolation", "unit": "OracleData",
      "lineFrom": 2700, "lineTo": 2800, "action": "break" },

    // Quietly log anything raised from code with no source mapping.
    { "unit": "*unknown*", "action": "log" },

    // Catch-all: break on everything else.
    { "action": "break" }
  ]
}
```

```jsonc
// "Allow-list" style: ignore everything, break only on what you list.
"exceptionRules": [
  { "class": ["EMyDomainError", "EValidationError"], "action": "break" },
  { "action": "ignore" }
]
```

```jsonc
// classIs (inheritance): ignore EDatabaseError and every descendant.
"exceptionRules": [
  { "classIs": "EDatabaseError", "action": "ignore" }
]
```

```jsonc
// code: keep the "all first-chance" filter on while silencing native exceptions
// that are normal traffic for a third-party library. They have no class and no
// message, so only `code` can express this.
"exceptionRules": [
  { "code": "0xE06D7363", "action": "ignore" },                   // C++ exception inside a C++ DLL
  { "code": ["0xC0000094", "0xC0000095"], "action": "logStack" }  // int divide by zero / overflow
]
```

### Shared rules across projects

A machine-wide rules file lets you define a baseline once and have it apply to
every project without per-project config. By default the adapter reads:

```text
%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json
```

It is a JSON object with an `exceptionRules` array (a bare array is also
accepted), using the same rule schema as above:

```jsonc
// %USERPROFILE%\.DelphiWinDebugger\exceptionRules.json
{
  "exceptionRules": [
    { "class": "EAbort", "action": "ignore" },
    { "messageRegex": "ORA-\\d+", "action": "logStack" }
  ]
}
```

Precedence: a project's `exceptionRules` (in `launch.json`) are evaluated
**first**, then the shared file's rules — so a project can override the shared
baseline, and anything it doesn't address falls back to the shared rules (and
finally to the exception filters). Control it from `launch.json`:

| Property | Default | Description |
|---|---|---|
| `useGlobalExceptionRules` | `true` | Load the shared rules file |
| `globalExceptionRulesPath` | *(the path above)* | Use a custom shared-rules file location |

A missing or malformed shared file is ignored (it never breaks debugging).

The shared file is **hot-reloaded**: edit it while stopped on a breakpoint or
exception, then resume (continue / step) and the new rules apply to subsequent
exceptions — no need to restart the session. The adapter re-reads the file on
resume only when its timestamp changed, and logs a line to the debug console
when it does. (Project `exceptionRules` come from `launch.json` and are not
hot-reloaded.)

### Editing rules from the UI

VS Code's native exception UI offers only on/off checkboxes for the four
filters, so the extension ships a dedicated editor for the rule table:

**Command Palette (`Ctrl+Shift+P`) → `Delphi Win64: Edit Exception Rules...`**

This is the route that always works: it is contributed unconditionally, so it is
there with no debug session, no open Delphi file and no launch configuration.

The same command also sits as a numbered-list icon in the title bar of the
**BREAKPOINTS** section of the Run and Debug view — the section's own header,
which is where its icons appear on hover, not the panel header above it — and in
the **CALL STACK** section header during a session. Breakpoints is the primary
home: VS Code removes the Call Stack section when no session is running and no
launch configuration is selected, whereas Breakpoints stays as soon as one
breakpoint exists or the workspace has been debugged once.

While stopped on an exception, `Delphi Win64: Create a Rule for This
Exception...` also appears as a button in the floating debug toolbar, pre-filled
from the exception in front of you.

Pick a `delphi-win64` launch configuration and the editor opens with one card
per rule, numbered in evaluation order. Each card separates the **match
criteria** from the **action**, and the up/down buttons reorder rules — order is
semantic, because the first match wins. Rules are validated as you type
(unknown fields, invalid actions, regular expressions that do not compile,
inverted line ranges); saving is blocked until the table is valid.

**Save to launch.json** replaces only the `exceptionRules` value of the selected
configuration; every other byte of the file — comments included — is left
untouched. The file is left open and unsaved so the change can be reviewed or
undone before it hits disk. If the workspace is not trusted the editor is
read-only and offers **Copy JSON** instead.

---

## MCP server: debugging from an AI agent

The same engine is exposed over the **Model Context Protocol**, so an agent can
debug a Delphi program the way a developer does — run it, stop it, and read the
real state — instead of inferring behaviour from the source.

```powershell
cmd /c build_mcp.bat
powershell -ExecutionPolicy Bypass -File register-mcp.ps1 MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe
```

The script registers the server as `delphi-win64-debugger` with Claude Code (via
the `claude` CLI, user scope) and with VS Code by merging the user `mcp.json`.
It is idempotent, and `-Unregister` removes it. `install\Install.exe` offers the
same registration at the end of an install.

The 31 tools cover the debugging cycle:

| Group | Tools |
|---|---|
| Session | `launch_debuggee`, `launch_from_config`, `attach_to_process`, `attach_from_config`, `list_debuggable_processes`, `detach_debugger`, `terminate_debuggee`, `stop_debugging`, `get_debug_session_status` |
| Breakpoints | `set_breakpoint`, `set_breakpoints`, `list_breakpoints`, `remove_all_breakpoints`, `set_exception_filters` |
| Execution | `continue_and_wait`, `step_over`, `step_into`, `step_out`, `pause_execution`, `wait_until_stopped` |
| State | `get_call_stack`, `get_threads`, `get_locals`, `get_variable`, `expand_variable`, `evaluate_expression`, `get_current_source_location`, `get_exception_details`, `get_compact_debug_snapshot` |
| Output | `get_debuggee_output`, `get_debugger_output` |

`launch_from_config` and `attach_from_config` read the `launch.json` the IDE
plugin generated, so an agent starts a session with the project's real symbol
and source paths rather than a hand-built approximation.
`get_compact_debug_snapshot` returns location, stack and locals in one call,
which is usually what an agent wants after a stop and costs far fewer tokens
than three round trips.

---

## Architecture

```
VS Code                                  AI agent (Claude Code, …)
  │  DAP (JSON over stdin/stdout)          │  MCP (JSON-RPC over stdin/stdout)
  ▼                                        ▼
VisualStudioCodeDelphiDebugger.exe     DelphiDebuggerMcp.exe
  │                                        │
  └────────────────┬───────────────────────┘
                   ▼
              DebuggerCore\            ← the engine: debug loop, symbols, evaluator
                   │  Windows Debug API (CreateProcess, WaitForDebugEvent, INT3)
                   ▼
        the process being debugged
```

Two front ends, one engine. Neither owns any debugging logic of its own: they
translate a protocol into calls on the same core, so a fix to stepping or to
symbol resolution reaches both.

| Component | Description |
|---|---|
| `DebuggerCore\` | The debugger proper: Windows debug loop, symbol readers (`.rsm`, TD32, `.map`, `.dcp`, JCL), expression evaluator, exception rules |
| `VisualStudioCodeDelphiDebugger\` | DAP server: reads DAP from stdin, drives the engine |
| `MCPDebugger\` | MCP server: the same engine as 32 tools an agent can call |
| `install\local.delphi-win64-debug\` | VS Code extension: registers the `delphi-win64` debug type, the attach picker and the exception-rules editor, and bundles the adapter |
| `Debugme.dpr` | A small program used as a debug target while developing the debugger |

### Key source files

| File | Responsibility |
|---|---|
| `DebuggerCore\DapProtocol.pas` | DAP framing: `Content-Length` header, JSON send/receive, logging |
| `VisualStudioCodeDelphiDebugger\DapServer.pas` | DAP request dispatcher: launch, setBreakpoints, stackTrace, next, continue… |
| `DebuggerCore\DebugTarget.pas` | `IDebugTarget` abstraction shared by the DAP layer and the evaluator |
| `DebuggerCore\Win64Debugger.pas` | Windows x64 debug loop: `WaitForDebugEvent`, INT3 plant/remove, single-step, synthetic calls |
| `DebuggerCore\TD32FileReader.pas` | Borland TD32 reader for the `.debug` PE section: source lines, symbols, types |
| `DebuggerCore\RsmFileReader.pas` | Reverse-engineered Delphi `.rsm` reader for type / local / global metadata |
| `DebuggerCore\MapFileReader.pas` | Parses Delphi `.map` files, translates RVA ↔ source line (nested-proc linkage, fallback) |
| `DebuggerCore\ExprEval.pas` | Pascal expression grammar for watch / hover / REPL and conditional breakpoints |

---

## Technology notes

### DAP protocol
JSON messages over stdin/stdout with HTTP-style `Content-Length` framing. VS Code sends requests; the adapter sends responses and events. The full spec is at <https://microsoft.github.io/debug-adapter-protocol/>.

### Windows Debug API
`CreateProcess` with `DEBUG_ONLY_THIS_PROCESS`. The adapter loops on `WaitForDebugEvent` / `ContinueDebugEvent`. Breakpoints are planted as INT3 bytes; the original byte is restored on first hit and re-planted after single-step.

### Delphi MAP files
The Delphi compiler emits a `.map` file with segment base addresses and line-number tables. The MAP format uses segment-relative offsets (not RVAs from ImageBase), so this adapter parses the `Start` section to obtain each segment's base RVA, then adds the per-line offset to get the correct RVA.

At runtime the adapter compares the debuggee's actual `ImageBase` (from `CREATE_PROCESS_DEBUG_INFO`) against the PE preferred base to compute the correct virtual address for each symbol.

---

## What works

- [x] Launch (Windows Debug API, `DEBUG_ONLY_THIS_PROCESS`)
- [x] Attach to a running process (`request: attach`, requires SeDebugPrivilege; auto-elevates when possible)
- [x] Stop at entry point (`stopAtEntry: true`)
- [x] Breakpoints in source files (set from VS Code gutter)
- [x] Conditional breakpoints, hit-count breakpoints, and log-points
- [x] Step over (`F10`), step into (`F11`), step out (`Shift+F11`)
- [x] Continue (`F5`), pause (injected `DebugBreakProcess`)
- [x] Set next statement (DAP `gotoTargets` / `goto`)
- [x] Current source line highlighted in editor
- [x] Multi-module debugging: DLLs and runtime-loaded BPLs (lazy per-module symbol loading)
- [x] All threads enumerated (with names); the whole process stops together (`allThreadsStopped`)
- [x] Per-thread inspection: selecting any thread shows that thread's own call stack, and its frames' locals/watches are inspectable (read-only)
- [x] RVA/address resolution from Delphi `.map` files (segment-relative offsets handled correctly)
- [x] ASLR: actual ImageBase vs. preferred base handled at runtime
- [x] Call stack with function names (frame unwinding beyond the current frame)
- [x] Local variable inspection from reverse-engineered Delphi `.rsm` files
- [x] Parent-procedure locals visible from inside nested procedures
- [x] Locals declared in the program's main `begin..end` block
- [x] Global variable inspection (with decoded `typeId`)
- [x] Registers scope in the Variables panel
- [x] Type-aware value formatting (integers, floats, `TDateTime`, chars, strings, Variants, C-string pointers, dynamic arrays in `[...]` notation)
- [x] Object / record / dynamic-array expansion in the Variables tree (all fields, all ancestor classes, nested)
- [x] Hover data tips in the editor (`evaluateForHovers`)
- [x] Full Pascal expression evaluator: qualified identifiers, arithmetic / comparison / boolean / set ops, string concat, indexing, type casts, `is` / `as`, `Length` / `SizeOf` / `Ord` / `Low` / `High`, enum / set literals, method and property calls (executed in the debuggee, raises aborted cleanly)
- [x] `setVariable` for primitives, floats, dates, chars, sized integer writes
- [x] `setVariable` for enums (by name / ordinal) and sets (by bitmask) at the correct storage width
- [x] `setVariable` for strings via in-process `@UStrAsg` / `@LStrAsg` (no refcount leak)
- [x] `setVariable` writes through the pointer for `var` parameters
- [x] First-chance exception break (continue past handled exceptions)
- [x] Exception class name and message shown on stop (`exceptionInfo` details panel)
- [x] `$exception` pseudo-variable: live exception object inspectable in Locals and Watch
- [x] Exception filter UI (`delphi` / `av` / `all` / `unhandled`, with per-class condition)
- [x] Per-exception rule engine (`exceptionRules`): match on class / message / regex / unit / line, act with ignore / log / logStack / break
- [x] Shared machine-wide exception rules (`%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json`) applied across projects
- [x] Accurate breakpoint verification state reported back to VS Code
- [x] Delphi RTL/VCL source resolution via `sourceSearchPaths` and the `BDS` env var

## Roadmap / not yet implemented

Debugger features:

- [ ] Child process tracking (currently `DEBUG_ONLY_THIS_PROCESS` only)
- [ ] Disassembly view (DAP `disassemble` request)
- [ ] 32-bit (Win32) targets

Variable / type system:

- [ ] Generics, anonymous methods, closure capture frames
- [ ] Pretty-printing for more RTL types beyond what's already handled

Tooling / UI:

- [ ] Visual editor for `exceptionRules` — a dedicated TypeScript VS Code
  extension with a Webview UI (add/reorder rules, action dropdowns, live
  match preview), persisting back to `launch.json`. The current thin
  debug-type registration has no extension code; the JSON schema already
  provides launch.json autocompletion/validation, so this is only needed for
  a form-style editor.

Project / packaging:

- [ ] PE import-table reader so the `.map` file can be dropped entirely
- [ ] Publish the VS Code extension to the marketplace instead of the local install

---

## Known limitations

- **Type information comes from `.rsm` + TD32, not `.map`**: Delphi `.map` files
  carry only line numbers and symbol addresses. Full variable/type inspection
  is driven by the reverse-engineered `.rsm` file and the TD32 `.debug` PE
  section, so a target must be compiled with `-V -VN -VR` to emit them. Without
  the `.rsm`, breakpoints and stepping still work but variable inspection is
  limited.
- **Single process**: only `DEBUG_ONLY_THIS_PROCESS` is used. Child processes launched by the debuggee are not tracked.
- **Whole-process stops**: the process stops as a unit — there is no "freeze one thread and let the others run". Stepping does target the thread you selected (the others are suspended for the duration of the step), and any thread's call stack and variables can be inspected.
- **x64 only**: the Win64 calling convention and stack layout are assumed throughout.

---

## Diagnostic logging

The adapter can write a timestamped log to `%TEMP%\dap_adapter.log`. It is
**off by default**; enable it per session with `"diagnosticLog": true` in the
launch configuration (or the `DAP_LOG=1` environment variable). The log is
verbose — every DAP request/response and debug event — so use it only when
diagnosing adapter behavior.

---

## License

MIT — see [LICENSE](LICENSE).

The debugger depends on, but does not redistribute, third-party components:

- **JEDI Code Library (JCL)** — used to read `JCLDEBUG` / `.jdbg` line
  information. Mozilla Public License 1.1 / GPL. Set `JCL_ROOT` (see
  `setpaths.bat`) to point at your own checkout.
- **DUnitX** — the integration test suite only. Apache License 2.0. Set
  `DUNITX_ROOT`.
- **Embarcadero Delphi RTL/VCL** — required to build; covered by your own
  Delphi licence.

The `.rsm` and TD32 format notes in this repository are the result of
independent analysis of files produced by the Delphi compiler on the author's
own machine.
