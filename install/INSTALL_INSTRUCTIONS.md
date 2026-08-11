# Delphi Win64 Debugger — Installation Instructions

## Prerequisites

- **Visual Studio Code** 1.80 or later
- Windows x64
- A **Delphi Win64** application compiled with debug information
  (`-V -VN -VR`, optimizations off), which emits a `.map` and a `.rsm` beside
  the `.exe`:
  - **Source lines** for breakpoints and stepping come from any one of three
    independent sources — the TD32 `.debug` section inside the executable, a
    `.map` beside it, or JCL debug data (`JCLDEBUG` section or `.jdbg` sidecar).
    Any one is enough.
  - **The `.rsm`** is what local-variable and type inspection is built on.
    Without it, breakpoints and stepping still work but variable inspection is
    limited.
- The [Delphi IDE plugin](https://github.com/csm101/EditInVsCodeDelphiPlugin) is
  strongly recommended: it generates the workspace and launch configuration from
  your Delphi project, which is otherwise a lot of paths to write by hand.

## Quick install (distributed zip)

If you received the `delphi-win64-debugger-setup-*.zip`:

1. Extract it anywhere.

   > **Windows will warn you.** These executables are not code-signed, so
   > SmartScreen shows "Windows protected your PC" and some browsers flag the
   > download. If you obtained the zip from the project's GitHub releases page,
   > choose *More info → Run anyway*. If you would rather not trust a binary
   > from the internet — a reasonable position for a debugger, which by nature
   > attaches to other processes — build it yourself from the repository
   > instead: `build_setup_zip.bat` produces this exact zip.
2. Run `Setup.exe`. It packages the extension into a `.vsix` and installs it
   through the VS Code CLI (`code --install-extension`), which registers it
   properly and updates any previous version in place. It then offers to install
   and register the **MCP debug server** (see below).
3. Reload VS Code (Ctrl+Shift+P -> "Developer: Reload Window").

### Memory inspection needs nothing else

Right-click a variable — in **Variables** or in **Watch** — and use the memory
icon on the row. The view is part of this extension: it reads the debuggee
through the adapter and draws the bytes itself.

Earlier versions relied on Microsoft's Hex Editor extension, because VS Code's
own **View Binary Data** pane comes from there. That pane treats the variable's
address as byte 0 of a file, so it cannot scroll to what lies before the value,
mark which bytes belong to it, or show what changed since the last stop — which
is why this view exists, and why the built-in one is switched off by default.

To have the built-in pane back, set `"delphi-win64.stockMemoryView": true` and
install `ms-vscode.hexeditor` yourself:

```
code --install-extension ms-vscode.hexeditor
```

No repository, Delphi toolchain, or build step is required — the adapter is
already compiled and bundled inside the zip.

### MCP debug server (Claude Code + VS Code)

The zip also bundles `DelphiDebuggerMcp.exe` (a Model Context Protocol stdio
server that lets an AI agent drive the debugger) and `register-mcp.ps1`. When you
answer "yes" to the MCP prompt, `Setup.exe` copies the server to
`%LOCALAPPDATA%\DelphiWin64Debugger\` and registers it with **Claude Code**
(`claude mcp add … -s user`) and **VS Code / VS Code Insiders** (user `mcp.json`).
Restart Claude Code / reload VS Code to pick it up. To (un)register later:

```
powershell -ExecutionPolicy Bypass -File register-mcp.ps1 "%LOCALAPPDATA%\DelphiWin64Debugger\DelphiDebuggerMcp.exe"
powershell -ExecutionPolicy Bypass -File register-mcp.ps1 -Unregister
```

The tool surface is documented at
<https://github.com/csm101/delphi-visual-studio-code-debugger/blob/main/MCP_SERVER.md>
(`MCP_SERVER.md` is not bundled in this zip).

> **`code` must be on PATH.** Recent VS Code builds (1.96+) no longer load
> extensions that are merely copied into the extensions directory; a real VSIX
> install is required. The system-setup VS Code installer adds `code` to PATH by
> default. If `code` is not found, `Setup.exe` falls back to a folder copy and
> prints the manual command to finish the install:
> `code --install-extension "<path-to>.vsix" --force`.

## Installation from source

The `local.delphi-win64-debug` folder must contain the built
`VisualStudioCodeDelphiDebugger.exe`. From a clean checkout, build and stage it
first by running `update-install.bat` at the repository root (or use the
interactive installer below, which builds and stages for you).

To produce the distributable zip described above, run `build_setup_zip.bat` at
the repository root; the result lands in `dist\`.

For interactive day-to-day development, run `install-dev.bat` instead: it builds
the adapter and points the installed extension's `program` directly at the build
output, so a rebuild plus a VS Code reload is enough to pick up changes (no copy).

Choose one of:

- **Interactive installer (recommended)** — from the repository root run
  `build_installer.bat` then `install\Install.exe`. It builds the adapter if
  needed, packages the extension into a `.vsix`, and installs it via the VS Code
  CLI (`code --install-extension`). If `code` is not on PATH it falls back to a
  folder copy and prints the manual VSIX command.
- **Manual VSIX** — `code --install-extension "<path-to>.vsix" --force` using the
  `.vsix` that `Install.exe` writes to your `%TEMP%` directory.
- **Manual folder copy (legacy, may be ignored by VS Code 1.96+)** — copy the
  entire `local.delphi-win64-debug` folder into `%USERPROFILE%\.vscode\extensions\`.

Then **reload VS Code** (Ctrl+Shift+P → "Developer: Reload Window").

Verify the extension is active: open the Run and Debug panel (Ctrl+Shift+D) — the debug type dropdown should include **Delphi Win64**.

## Configuring a debug session

Add a launch configuration to your project's `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "delphi-win64",
      "request": "launch",
      "name": "Debug MyApp",
      "program": "${workspaceFolder}/Win64/Debug/MyApp.exe"
    }
  ]
}
```

The debugger automatically looks for `MyApp.map` and `MyApp.rsm` next to the executable.
If they are in a different location, specify them explicitly:

```json
{
  "type": "delphi-win64",
  "request": "launch",
  "name": "Debug MyApp",
  "program":  "C:/path/to/MyApp.exe",
  "mapFile":  "C:/path/to/MyApp.map",
  "rsmFile":  "C:/path/to/MyApp.rsm",
  "sourceRoot": "C:/path/to/your/source"
}
```

## Optional: Delphi source stepping

To step into Delphi RTL or library units, add `sourceSearchPaths` pointing at the
Delphi source tree. If the `BDS` environment variable is set, its `source` subdirectory
is searched automatically. You can add extra paths explicitly:

```json
"sourceSearchPaths": [
  "${env:BDS}/source",
  "C:/path/to/other/libraries"
]
```

## Supported features

- Breakpoints: line, conditional, hit-count, and log-points
- Launch and attach; step over / into / out / continue / pause; set next statement
- Call stack inspection with function names
- Local, global, and register inspection (locals/globals require the `.rsm` file)
- Object / record / dynamic-array expansion in the Variables tree
- Watch / hover with a full Pascal expression evaluator
- Exception filters and a per-exception rule engine (project and machine-wide)
- Disassembly View (`instructionPointerReference` on stack frames) and
  instruction breakpoints, backed by the bundled `Zydis.dll` (installed next
  to the adapter automatically; MIT licence, `Zydis-LICENSE.txt`, ships
  alongside it). If that DLL is ever missing, disassembly reports itself
  unavailable rather than failing the session — everything else keeps working.

## Troubleshooting

**Extension not listed in debug type dropdown** (or "Configured debug type 'delphi-win64' is not supported")
The extension was not loaded. On VS Code 1.96+ a folder copy is not enough — the
extension must be installed from a VSIX so it is registered in the extensions
cache. Re-run `Setup.exe`/`Install.exe` (which installs via `code --install-extension`),
or run `code --install-extension "<path-to>.vsix" --force` manually, then reload
VS Code. Confirm a versioned `local.delphi-win64-debug-<version>` folder exists
under `%USERPROFILE%\.vscode\extensions\`.

**Breakpoints not hit**
Ensure the executable was compiled with `-V -VN -VR` flags and that the `.map` file is present next to the executable or specified via `mapFile`.

**Variables show as unavailable**
The `.rsm` file is missing or not found. Check the `rsmFile` setting in your launch configuration.

**Disassembly / Disassembly View reports unavailable**
`Zydis.dll` (the disassembly backend) is missing next to the adapter or MCP
server executable. It is staged automatically by `Setup.exe`/`Install.exe`
and `update-install.bat`; if it is absent, re-run the installer, or copy
`Zydis.dll` from `ThirdParty\Zydis\bin\x64\` (in a source checkout) next to
`VisualStudioCodeDelphiDebugger.exe`. Everything else in the debugger works
without it — this is an optional feature by design.
