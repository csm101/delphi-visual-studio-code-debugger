# Delphi Win64 Debugger — MCP Server

`DelphiDebuggerMcp.exe` exposes the debugger as a set of **semantic MCP tools** so
an autonomous agent (Claude Code) can drive it without touching the Debug Adapter
Protocol. It is a second frontend over the same engine as the VS Code DAP adapter:

```
                 TDebugSession  (DebugSession.pas — JSON-free core facade)
                 owns: IDebugTarget engine + symbols + source + state machine
                  │                                   │
        TDapServer (VS Code, DAP)          TMcpServer (agent, JSON-RPC/MCP)
```

The MCP server speaks **JSON-RPC 2.0 over stdio, newline-delimited** (the MCP
stdio transport — one compact JSON message per line). `stdout` carries only
protocol traffic; diagnostics go to `%TEMP%\mcp_adapter.log`.

## Build

```bat
call build_mcp.bat
```

Output: `MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe`.
(The full test pipeline `DebuggerTests\build_and_run.bat` also builds it.)

## Register (automatic)

The installer and the dev-install register the MCP server for you, in **both
Claude Code and VS Code** (stable + Insiders):

- **From the distributable zip:** run `Setup.exe` and accept "Also install and
  register the MCP debug server?". It copies `DelphiDebuggerMcp.exe` to
  `%LOCALAPPDATA%\DelphiWin64Debugger\` and registers that stable path.
- **From source (dev):** `install-dev.bat` builds the MCP server and registers
  the build-output exe (so a `build_mcp.bat` rebuild is picked up on restart).
- **Directly:** `powershell -ExecutionPolicy Bypass -File register-mcp.ps1
  <path-to-DelphiDebuggerMcp.exe>` — idempotent; `-Unregister` removes it.

Registration writes the Claude Code user config via `claude mcp add … -s user`
and merges each VS Code user `mcp.json`. Restart Claude Code / reload VS Code to
pick it up.

## Register manually

Stdio MCP server, no arguments. Either add a `.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "delphi-debugger": {
      "command": "C:\\Athens\\GitHub\\Win64Debugger\\MCPDebugger\\Win64\\Debug\\DelphiDebuggerMcp.exe"
    }
  }
}
```

or register it from the CLI:

```
claude mcp add delphi-debugger -- "C:\Athens\GitHub\Win64Debugger\MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe"
```

To attach to processes owned by another user or elevated targets, run the client
(and thus the server) elevated so `SeDebugPrivilege` is available.

## Tool surface

### Session & process
- `list_debuggable_processes` — pid, exe name/path, command line, parent pid,
  start time, architecture. Optional `nameFilter`.
- `launch_debuggee` — start a target under the debugger. **Always stops at entry**
  so you can set breakpoints before any user code runs; then `continue_and_wait`.
  Args: `program` (required), `args`, `mapFile`, `rsmFile`, `sourceRoot`,
  `sourceSearchPaths` (array of additional source roots — `;`-separated and
  `${env:VAR}` supported), `workspaceFolder`.
- `launch_from_config` — launch from an existing VS Code `launch.json` (the same
  file the DAP debugger uses), so you need not restate program / map / rsm / source
  paths. Reads a `delphi-win64` configuration; JSONC (comments, trailing commas)
  and `${workspaceFolder}` / `${env:VAR}` are handled. Args: `configFile`
  (defaults to `.vscode\launch.json` under the current directory), `configName`
  (defaults to the first `delphi-win64` entry), `workspaceFolder`.
- `attach_to_process` — by `processId` or `processName`. An ambiguous name returns
  the candidate list instead of guessing; a different-architecture target is
  rejected. `killOnDetach` (default false).
- `detach_debugger` — leave the process running.
- `terminate_debuggee` — kill it.
- `stop_debugging` — detach an attached session, terminate a launched one.
- `get_debug_session_status` — state + current location when stopped.

### Breakpoints
- `set_breakpoint` — `sourceFile`, `line`, plus optional `condition` (stop only
  when a Pascal expression is true, e.g. `"i = 3"`), `hitCondition`
  (`"5"`/`">5"`/`">=5"`/`"%5"`), and `logMessage` (a logpoint: does not stop,
  emits the message with `{expr}` substituted to the debugger output). Returns
  `verified`.
- `set_breakpoints` — set several at once (`breakpoints` array of the same
  fields); each listed file's set is replaced, unlisted files untouched.
- `list_breakpoints`, `remove_all_breakpoints`.

### Execution (event-driven — the stop is folded into the response, no sleeps)
- `continue_and_wait` (optional `timeoutMs`), `step_over`, `step_into`,
  `step_out`, `pause_execution`, `wait_until_stopped`. Each returns a compact
  snapshot of the new state.

### Inspection (valid while stopped)
- `get_compact_debug_snapshot` — state, stop reason, thread, current location,
  top frames, top-frame locals, exception info if any (one round trip).
- `get_current_source_location`, `get_call_stack`, `get_locals`,
  `get_variable` (`name` — one named variable, with an expansion handle when it is
  a local class/record/array), `evaluate_expression` (`expression`),
  `get_exception_details`,
  `get_debuggee_output` (program stdout), `get_debugger_output` (logpoint
  messages and debugger notices).
- `get_loaded_modules` — every image mapped in the debuggee (executable first,
  then each DLL / runtime package) with `base`, `size`, `symbols` and
  `formats`. `symbols` uses the same vocabulary as the frames (`loaded`,
  `noSymbols`, `indexing`); `formats` lists what actually REGISTERED (`td32`,
  `map`, `rsm`, `dcp`, `jdbg`, `tds`), not what was looked for — so an empty
  list beside `noSymbols` means the binary carries none, rather than a sidecar
  merely being absent. Answers the two questions a nameless frame raises, and
  tells whether a breakpoint that has not bound is waiting for a package that
  is not loaded yet. Valid while running, not only while stopped.
- `get_raw_stack_scan` (`threadId`, `maxItems`) — **last resort, and not a call
  stack.** Brute-force sweep of the thread's stack for words that could be
  return addresses, for when `get_call_stack` stops short: a 32-bit target
  carries no unwind data, so the walk ends at the first routine built without a
  frame pointer. Every hit is marked `kind:"rawStackHit"` plus `proven` —
  `true` means the instruction ending there was decoded and is a `call`, `false`
  means there was no line table to decode from. Neither value says the routine
  is still on the current chain: a call that has already returned leaves its
  return address behind. Report these as places the program *has been*, never as
  callers. (On x64 every hit is `proven:false` — the call-site decoder is x86
  only.)
- `expand_variable` (`handle`) — read the child fields of a class instance or
  record. `get_locals` / `get_compact_debug_snapshot` mark an expandable value
  with `expandable:true` and a `handle`; pass that handle here. Nested
  classes/records in the result carry their own handles, so object graphs are
  walked step by step. Handles are valid until the next stop.

No raw DAP identifiers cross the boundary: frames carry a semantic `index`,
breakpoints a `file|line` id, variables a formatted value.

## Typical workflow

1. `list_debuggable_processes` → find or confirm a target (or skip for launch).
2. `launch_debuggee { program, sourceRoot }` → stops at entry.
3. `set_breakpoint { sourceFile, line }`.
4. `continue_and_wait` → snapshot at the breakpoint.
5. `get_call_stack`, `get_locals`, `evaluate_expression`.
6. `step_over` / `step_into` / `continue_and_wait` to progress.
7. `terminate_debuggee` (launched) or `detach_debugger` (attached).

## Current limitations (Phase A)

- **Multi-module / BPL** targets are supported: when a package (`.bpl`/DLL) loads
  at runtime, its symbols (TD32 in the module, plus adjacent `.map`/`.rsm`/`.dcp`
  sidecars) are loaded and breakpoints set in its units plant once it is in
  memory. Sidecars are auto-discovered next to the module. Load is currently
  synchronous and eager (every sidecar-bearing module when breakpoints exist);
  a source-membership gate to avoid loading unrelated packages is a follow-up.
- Nested variable expansion covers **class fields, records, and dynamic arrays**
  (`expand_variable`; array elements carry their own handles). Getter-backed
  **properties** and **Variant arrays** are not yet expanded.
- `attach_to_process` is implemented (pid, ambiguous-name rejection, pre-attach
  architecture gate). The live-attach stop handshake is covered by an
  elevation-gated test (`DebugActiveProcess` needs `SeDebugPrivilege`), so it is
  exercised when the runner is elevated and skipped otherwise.

These are tracked for the next phase. The DAP adapter is unaffected by any of the
above — it is untouched by the MCP work.
