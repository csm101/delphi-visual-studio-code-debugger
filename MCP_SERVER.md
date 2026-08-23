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
- `list_breakpoints`, `remove_all_breakpoints` — return/clear BOTH source and
  address breakpoints (see below); each entry carries `kind: "source"` or
  `"address"`.

**Breakpoint conditions.** A `condition` that evaluates to zero suppresses the
stop. A condition that **cannot be evaluated at all** — a typo, a name that is
not in scope on that line — makes the breakpoint **stop anyway**, and the stop
carries `breakpointConditionError` naming the condition and the reason. The
opposite policy (treat a failed evaluation as false) is the one failure nothing
reveals: the breakpoint silently never fires and the caller concludes the code
path is dead. The hit-count gate is skipped on that path, so a `"%100"` hit
condition cannot swallow the report, and the same text is appended once per
breakpoint to `get_debugger_output`.
- `set_breakpoint_at_address` — a breakpoint at an ABSOLUTE ADDRESS rather
  than a source line (`DISASSEMBLY_PLAN.md` increment 5), for a frame with no
  symbols or an address found by inspection (`disassemble`, `get_call_stack`,
  `get_raw_stack_scan` all echo an `address` field made exactly for this).
  Args: `address` (`"0x..."` or decimal, required), `condition`,
  `hitCondition`, `logMessage` (same semantics as `set_breakpoint`). The
  address is resolved to `(module, rva)` against the CURRENTLY LOADED modules
  and stored as that pair, never as the bare address: an address is
  meaningless across a relaunch or an ASLR-rebased package, so it re-resolves
  to a fresh address whenever that module (re)loads. An address inside a
  module that is NOT currently loaded is refused (`verified:false` with a
  `message`) rather than planted somewhere that may belong to something else
  once a module maps there. Setting the same address again REPLACES the
  prior entry (idempotent, keyed by the resolved module+rva), rather than
  duplicating it. Returns a one-element array, same shape as `set_breakpoint`.
- `remove_breakpoint_at_address` — remove one address breakpoint by `id`
  (from `set_breakpoint_at_address` or `list_breakpoints`). Returns the
  remaining breakpoints (source and address).

### Data breakpoints (watchpoints)
Hardware watchpoints (`DR0`-`DR3`): stop when a memory location is written (or
read-or-written — there is no read-only watchpoint on x86/x64). Only 4 slots
exist, shared by the whole process; the 5th request is refused by name (what
already holds the slots), never silently dropped. The session must be
`stopped` to set or remove one (arming touches live thread contexts).
- `set_data_breakpoint` — `expression` (a literal address like `"0x1234"`, a
  global/unit variable name — locals named bare are refused with a reason, their
  address is only valid for the frame's lifetime — or an EXPRESSION, resolved by
  one rule: a bare identifier is watched at its own storage, `@X` is already an
  address, anything else is watched where IT lives. So `Arr[High(Arr)]` watches
  the last element and `@Rec.Buf[0]` the first byte of a buffer: the targets a
  "who writes past my array" hunt needs, which belong to no variable at all),
  `size` (1/2/4/8, address must
  already be aligned), `access` (`"write"`, or `"readWrite"` to also catch
  reads — it ALSO fires on writes, it does not filter them out; `"read"`
  alone is refused outright, never silently downgraded). Returns the new
  watchpoint: `id`, `expression`, `size`, `access`, `verified`, `address`
  (plus `module`/`rva` when resolved inside a known module), `slot` (0-3, or
  `-1` when refused), and `message` (a refusal reason, or the read-or-write
  caveat when `access` is `"readWrite"`).
- `list_data_breakpoints` — every tracked watchpoint in the same shape.
- `remove_data_breakpoint` — by `id`; frees the hardware slot and returns the
  remaining list.

A watchpoint stop reports `stopReason: "dataBreakpoint"` (from
`get_compact_debug_snapshot` / `continue_and_wait` / any wait-class tool) plus
`dataBreakpointDescription`: `"expression: $old -> $new (thread N)"` — the
watched expression, the old and new values, and the THREAD that wrote it
(also in the snapshot's own `thread` field) in one string, since which thread
did it is frequently the whole answer.

### Registers (`ASSEMBLY_LEVEL_DEBUGGING.md` increment 4)
The MCP equivalent of DAP's long-standing writable `Registers` scope — same
`TDebugSession.GetRegisters`/`SetRegister` path, no second mechanism. Requires
the session to be stopped.
- `get_registers` — the general-purpose registers of the currently stopped
  thread, NAMED for the target's bitness: RIP, RSP, RBP, RAX..RDI, R8..R15,
  EFlags (18 rows, `size` 8 except 4 for `EFlags`) on a 64-bit target; EIP,
  ESP, EBP, EAX..EDI, EFlags (10 rows, `size` 4) on a 32-bit one, with no
  `R8`..`R15` at all — there is no such register at that width. Each row is
  `{name, value, size}`; `value` is a hex string (`"0x..."`, never a bare
  number — a 64-bit register does not fit a JSON/IEEE double without loss).
- `set_register` — `name` (case-insensitive; either spelling works on either
  bitness, so `EAX` and `RAX` name the same register, and on a 64-bit target
  an `E`-name writes the low 32 bits and zero-extends as the hardware does)
  and `value` (decimal or `0x`-hex). Returns the register's NEW value, RE-READ
  from the thread so the response proves the write rather than echoing the
  request back — which is also how a value truncated to a 32-bit register
  becomes visible. A name the target has no such register for is refused
  (`isError:true`), never silently ignored: `R8`..`R15` on a 32-bit target are
  an error, not an alias.

### Execution (event-driven — the stop is folded into the response, no sleeps)
- `continue_and_wait` (optional `timeoutMs`), `step_over`, `step_into`,
  `step_out`, `pause_execution`, `wait_until_stopped`. Each returns a compact
  snapshot of the new state.
- `step_over`/`step_into`/`step_out` take an optional `granularity`:
  `"statement"` (default) is the pre-existing source-level step; `"instruction"`
  (`ASSEMBLY_LEVEL_DEBUGGING.md` increment 4) steps exactly ONE machine
  instruction instead — landing wherever it goes for `step_into`, running to
  PC + the decoded length without single-stepping a `call` or a `rep`-prefixed
  string instruction for `step_over`, and running to a PROVEN return address
  (`.pdata` on x64, `[EBP+4]` on x86) for `step_out`. Unlike the statement-level
  step (which always succeeds), an instruction-granularity step CAN BE REFUSED
  — no disassembler backend available, bytes that do not decode, or (for
  `step_out`) no provable return address — and a refusal comes back as
  `isError:true` with the reason instead of a snapshot; nothing moves. Useful
  in code with no line table (a runtime package built without debug info),
  where a source-level step has no terminating condition.

### Inspection (valid while stopped)
- `get_compact_debug_snapshot` — state, stop reason, thread, current location,
  top frames, top-frame locals, exception info if any,
  `dataBreakpointDescription` when the stop reason is `dataBreakpoint`, and
  `breakpointConditionError` when the stop happened BECAUSE the breakpoint's
  condition could not be evaluated (one round trip). Without that last field the
  stop looks unconditional, which is the one thing this snapshot could not
  otherwise tell you — see "Breakpoint conditions" below.
- `get_current_source_location`, `get_call_stack`, `get_locals`,
  `get_variable` (`name` — one named variable, with an expansion handle when it is
  a local class/record/array), `evaluate_expression` (`expression` — Pascal,
  with **Delphi's own operator precedence**: `and` binds with `*`, `or`/`xor`
  with `+`, both tighter than any comparison, so `(a > 1) and (b < 2)` needs its
  parentheses here exactly as in source. String comparison compares characters,
  not heap pointers),
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
- `get_source_files` (`module`, `nameOnly`) — the source files the loaded debug
  info can name, grouped by owning module. This is the file spelling
  `set_breakpoint` expects, so it replaces guessing a name from a unit or a
  path. Each group carries `listedBy` (the format that produced the list:
  `td32`, `tds` or `map`), `complete` (`false` while an index is still filling —
  the list is partial, re-ask shortly) and `fileCount`. `listedBy: null` means
  the module's loaded formats **cannot enumerate** — `.rsm`, `.dcp` and `.jdbg`
  map addresses but hold no file index — which is *unknown*, not "this module
  has no source files"; a breakpoint there may still bind. Only formats already
  loaded are consulted, so enumerating never triggers a parse and a module whose
  sidecars have not been probed yet can be absent; `get_loaded_modules` says
  which those are. Valid while running, not only while stopped.
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
- `disassemble` (`address` | `frameIndex`/`threadId`, `count`, `before`) —
  machine-code disassembly (Zydis, x86/x64, either bitness) for the case an
  agent cannot safely do by hand: a frame inside a package with no symbols,
  diagnosing a failed synthetic call, or naming which call a raw-stack-scan
  hit follows. `address` is the exact `"0x..."` string a stack frame
  (`get_call_stack`) or a raw-stack-scan hit (`get_raw_stack_scan`) **already
  carries in its own `address` field** — no separate lookup, no re-parsing of
  display text; feed it straight back in. `frameIndex`/`threadId` (the same
  convention `get_locals`/`get_variable`/`evaluate_expression` use, not a
  separate opaque frameId) resolves to that frame's instruction pointer
  instead. Each instruction reports `address`, `bytes`, Intel-syntax `text`,
  `decoded` (false → `text` is `"db XX"`, never a guessed mnemonic — the
  exact-or-nothing contract `X86Decode.pas` already has), and `symbol`/
  `sourceFile`/`sourceLine` when a provider knows one. `available:false` with
  a `reason` and no `instructions`/`before` at all means Zydis could not load
  (missing DLL, wrong version, no VC++ runtime) — the ORDINARY case on a
  machine without it, never an error and never a partial result. Optional
  `before` asks for instructions PRECEDING the address; x86/x64 cannot be
  decoded backwards, so it is answered ONLY from a PROVEN earlier instruction
  boundary (debug info, or a module's PE export table when it has none) that
  decodes forward to land EXACTLY on the address — otherwise it comes back
  `refused:true` with a reason, while the forward `instructions` are
  untouched (a refused `before` is not a failed call). Requires the session
  to be stopped. Full design and the "no heuristics" reasoning behind
  `before` are in `DISASSEMBLY_PLAN.md`.

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

## Design decision: no `get_scopes` / `get_arguments` (recorded 2026-08-08)

Both are intentionally absent. The neutral model exposes a direct `get_locals`
plus opaque variable handles instead of scope-reference indirection, and arguments
are not reliably separable from locals without parameter metadata — DAP does not
separate them either, so the indirection would buy nothing and imply a distinction
the debug info cannot back.
