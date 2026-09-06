Debug Delphi Win32 and Win64 applications from VS Code, or from an AI agent over
MCP. No Delphi toolchain and no build step needed to install: the adapter, the
MCP server and the VS Code extension are all compiled and bundled.

## 📖 [Documentation, tutorial and feature tour → mcasoftware.dev](https://mcasoftware.dev/products/delphi-debugger/index.html)

New here? **Start there rather than with this page.** It covers installation, a
first debug session, a 12-chapter VS Code tutorial, the MCP / AI-agent guide and
the architecture notes, with screenshots.

The adapter is always a 64-bit process, whichever target it debugs — a 32-bit
application is debugged across the WOW64 boundary, so the debugger does not work
inside a 32-bit address space, which is where a large project's symbol data
would otherwise run out of room.

## Important: let something that knows your project describe it

To debug your own application, VS Code must first know about your project —
the executable (or the host application of a package), the symbol files, the
source search paths, the packages. Two things can supply that:

- **[delphi-devkit (DDK)](https://marketplace.visualstudio.com/items?itemName=Snowcaloid.delphi-devkit)**,
  from inside VS Code. With DDK installed there is no `launch.json` to write:
  right-click a project in DDK's tree and choose **Debug** or **Attach
  Debugger**, or write the two-line configuration
  `{ "type": "delphi", "request": "launch", "ddkProject": "MyApp" }`.
- The **[EditInVsCodeDelphiPlugin](https://github.com/csm101/EditInVsCodeDelphiPlugin)**,
  from inside the Delphi IDE: `git clone` it, open `EditInVSCode.dpk`, install
  it from the Project Manager, then **Tools → Edit in Visual Studio Code**
  opens your project in VS Code already configured for this debugger.

{{HIGHLIGHTS}}

## Install

1. Download `delphi-win64-debugger-setup-v{{VERSION}}.zip` below and extract it anywhere.
2. Run `Setup.exe`. It installs the bundled `.vsix` through the VS Code CLI
   (`code --install-extension`), updating any previous version in place, then
   offers to register the MCP debug server with Claude Code and VS Code.
3. Reload VS Code.

**The extension is now `mca-software.delphi-debugger`.** Earlier releases
installed it under the id `local.delphi-win64-debug`; the two must not coexist,
because both contribute the same debug types and VS Code would ask which one to
use at every session start. `Setup.exe` uninstalls the old copy and deletes any
leftover folder before installing the new one. If you install the `.vsix` by
hand instead, remove the old copy first:
`code --uninstall-extension local.delphi-win64-debug`. The extension also
detects a leftover copy on activation and offers to remove it.

**Windows will warn you**: these executables are not code-signed, so SmartScreen
shows "Windows protected your PC". Choose *More info -> Run anyway*, or build the
identical zip yourself from source with `scripts/build_setup_zip.bat` — a reasonable
preference for a debugger, which by nature attaches to other processes.

## Requirements

- Windows x64, VS Code 1.80 or later.
- **The program you want to debug must be compiled with full debug information**,
  or most of this will not work — a debugger can only show what the compiler
  emitted. In the Delphi project options, for the Debug configuration of the
  platform you are building (Win32 or Win64):
  - *Compiling* -> **Optimization off**, **Debug information** on, **Local symbols** on
  - *Linking* -> **Debug information** on, **Include remote debug symbols** on
    (this is the `.rsm`), **Map file: Detailed**

  On the command line: `-$O- -V -VN -VR`. Keep the `.map` and `.rsm` beside the `.exe`.

What each artefact buys you:

| Artefact | Without it |
|---|---|
| TD32 section, `.map`, or JCL data — **any one** | no source lines: no breakpoints, no stepping |
| **`.rsm`** | breakpoints and stepping still work, but local variables, types and expression evaluation are severely limited |
| optimizations **off** | breakpoints land on the wrong line and locals read as garbage, because the code no longer matches the source |

The same applies to every **runtime package** you want to step into: a BPL
compiled without debug information stays a black box even when the host has full
symbols. To step into the RTL and VCL, also enable *Use debug .dcus*.

## What is in the box

| | |
|---|---|
| `Setup.exe` | Installer and updater |
| `mca-software.delphi-debugger-{{VERSION}}.vsix` | The VS Code extension, packaged: the DAP adapter, the MCP server and the extension code. What `Setup.exe` installs; also attached to this release on its own |
| `mca-software.delphi-debugger/` | The same, as a folder (`Setup.exe` packages it itself when no `.vsix` is next to it) |
| `DelphiDebuggerMcp.exe` | MCP server — {{MCP_TOOL_COUNT}} tools that let an agent set breakpoints, step, and read locals; installed to `%LOCALAPPDATA%\DelphiWin64Debugger` and registered as `delphi-debugger` |
| `register-mcp.ps1` | Registers or unregisters the MCP server |

SHA-256 of the zip:
`{{SHA256}}`
