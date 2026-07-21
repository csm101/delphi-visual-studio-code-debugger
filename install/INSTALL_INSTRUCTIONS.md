# Delphi Win64 Debugger — Installation Instructions

## Prerequisites

- **Visual Studio Code** 1.80 or later
- A **Delphi Win64** application compiled with debug information:
  - Map file (`.map`) — required for breakpoints and source stepping
  - RSM file (`.rsm`) — required for local variable inspection
  - Both files are produced automatically when you compile with `-V -VN -VR` flags

## Quick install (distributed zip)

If you received the `delphi-win64-debugger-setup-*.zip`:

1. Extract it anywhere.
2. Run `Setup.exe`. It packages the extension into a `.vsix` and installs it
   through the VS Code CLI (`code --install-extension`), which registers it
   properly and updates any previous version in place. It then offers to install
   and register the **MCP debug server** (see below).
3. Reload VS Code (Ctrl+Shift+P -> "Developer: Reload Window").

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

See `MCP_SERVER.md` for the tool surface.

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
