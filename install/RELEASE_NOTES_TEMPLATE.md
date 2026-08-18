Debug Delphi Win32 and Win64 applications from VS Code, or from an AI agent over
MCP. No Delphi toolchain and no build step needed to install: the adapter, the
MCP server and the VS Code extension are all compiled and bundled.

The adapter is always a 64-bit process, whichever target it debugs — a 32-bit
application is debugged across the WOW64 boundary, so the debugger does not work
inside a 32-bit address space, which is where a large project's symbol data
would otherwise run out of room.

## Important: set up your project with the companion Delphi IDE plugin

To debug your own application, VS Code must first know about your project —
launch configuration, LSP settings, workspace layout. The
[EditInVsCodeDelphiPlugin](https://github.com/csm101/EditInVsCodeDelphiPlugin)
generates all of that from inside the Delphi IDE, so install it first:

1. `git clone https://github.com/csm101/EditInVsCodeDelphiPlugin`
2. Open `EditInVSCode.dpk` in the Delphi IDE
3. Right-click the project in the Project Manager and choose **Install**

Once installed, choose **Tools → Edit in Visual Studio Code** from the Delphi
IDE: your project opens in VS Code already configured for this debugger.

{{HIGHLIGHTS}}

## Install

1. Download `delphi-win64-debugger-setup-v{{VERSION}}.zip` below and extract it anywhere.
2. Run `Setup.exe`. It packages the extension into a `.vsix` and installs it
   through the VS Code CLI, updating any previous version in place, then offers
   to register the MCP debug server with Claude Code and VS Code.
3. Reload VS Code.

**Windows will warn you**: these executables are not code-signed, so SmartScreen
shows "Windows protected your PC". Choose *More info -> Run anyway*, or build the
identical zip yourself from source with `build_setup_zip.bat` — a reasonable
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
| `local.delphi-win64-debug/` | The VS Code extension plus the DAP adapter |
| `DelphiDebuggerMcp.exe` | MCP server — {{MCP_TOOL_COUNT}} tools that let an agent set breakpoints, step, and read locals |
| `register-mcp.ps1` | Registers or unregisters the MCP server |

SHA-256 of the zip:
`{{SHA256}}`
