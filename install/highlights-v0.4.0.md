## What's new

- Disassembler window
- Disassembler window breakpoints (machine-level instruction breakpoints and stepping)
- Data breakpoints (break when the code reads or writes a given address or variable)
- Read and write debuggee memory, with **View Binary Data** on any variable
- Where the debugger stops when an exception is raised: on the faulting instruction, or on the `raise` itself
- Step out from an exception (follow execution through `except` and `finally` blocks)
- Correct handling of hardware registers (register names now follow the target: x86 or x64)
- Change hardware register values while stopped
- New MCP tools for machine-level debugging: `disassemble`, `get_registers` / `set_register`, `read_memory` / `write_memory`, `set_breakpoint_at_address`, `set_data_breakpoint`, instruction-granularity stepping
- The integration test suite runs much faster: 568 seconds before, 68 now

---

## What each of these means

### Disassembler window

Any frame can be opened as machine instructions, decoded by Zydis and annotated with the symbol and the source line each instruction belongs to. Win32 and Win64 targets alike.

This also means a stop with no source is no longer a dead end. Where no frame carries debug information — inside the RTL, inside Windows — the adapter opens a document stating what is known (module, address, symbol) followed by the disassembly at the stop.

### Disassembler window breakpoints

Breakpoints can be set in the Disassembly View's gutter, and `F10` / `F11` there advance by one instruction instead of one line. A `rep`-prefixed instruction is stepped as a whole, so a string move does not take a million steps to leave.

Address breakpoints are stored as module + offset rather than as a bare address, so they survive a relaunch and a rebased package.

### Data breakpoints

Right-click a variable in the Variables view: *Break on Value Change* or *Break on Value Access*. Backed by the CPU's debug registers.

The stop names the thread that wrote, with the old and the new value — frequently the whole answer.

The target does not have to be a named variable. It can be an expression: `Arr[High(Arr)]` for the last element of a buffer, `@Rec.Buf[0]` for its first byte. That is the case watchpoints are mostly reached for — who is writing past the end of my array — where the interesting byte belongs to no variable at all. From the Breakpoints panel, *Add Data Breakpoint at Address* takes an address and a byte count directly.

What it refuses, and why:

- Only four hardware slots exist in the whole process. The fifth request is refused naming what holds the others, never silently dropped.
- A width the hardware cannot express is refused, not widened — the CPU ignores the low address bits, so a widened watch would cover a neighbouring cell.
- x86 and x64 have no read-only watchpoint. *Break on Value Access* says plainly that it also fires on writes rather than pretending to filter them out.
- A watchpoint on a local is withdrawn, and announced, when its frame exits, instead of being left watching stack that now belongs to someone else.

### Read and write debuggee memory

Every variable the debugger has an address for carries a memory reference, so **View Binary Data** opens the memory inspector on it, and edits are written back into the running process.

This needs Microsoft's Hex Editor extension (`ms-vscode.hexeditor`): the memory view comes from there, not from VS Code, and without it the menu entry is simply absent. The installer installs it; by hand it is `code --install-extension ms-vscode.hexeditor`.

### Where the debugger stops when an exception is raised

The call stack now keeps every frame, and which frame is opened is a separate decision from which frames exist — nothing is discarded to make the view tidy.

The two kinds of exception get opposite treatment, because they are different questions:

- A hardware fault (an access violation, say) opens on the faulting instruction. It no longer opens somewhere plausible-looking further up the stack.
- A Delphi `raise` opens on the `raise` itself, with the RTL plumbing above it trimmed away.

### Step out from an exception

`F10` at an exception stop continues to the first `except` or `finally` up the stack that really receives the exception, derived from the binary's own exception tables.

Where it cannot be derived — an x86 `try/finally`, a handler belonging to another language — it refuses and says which, rather than landing somewhere that merely looks right.

### Hardware registers

The Registers scope reports the machine the debuggee is actually running on. A 32-bit target shows `EIP`, `ESP`, `EAX`..`EDI` at 32-bit width and no `R8`..`R15`; a 64-bit target shows the full register file. Previously both showed 64-bit names, with the extended registers reading zero on a 32-bit target — registers that do not exist at that width.

Registers are writable on both, and a write to a register the target has no such thing for is refused with a reason instead of quietly reaching nothing.

### MCP tools

The Model Context Protocol server gained the same ground as the GUI: `disassemble`, `get_registers` / `set_register`, `read_memory` / `write_memory`, `set_breakpoint_at_address`, `set_data_breakpoint` and instruction-granularity stepping. An agent can now read a stopped program's machine state, not only its source-level one.

### Test suite

The suite runs as concurrent worker processes. Measured on a 16-core / 32-thread machine, for the same tests: **568 seconds before, 68 now** at 8 workers, plus about 12 seconds of build. Sequentially, after the same fixes, it is 426 seconds — so roughly a quarter of the gain came from removing two polling loops that slept, and the rest from running the shards side by side.

The worker count adapts to the machine it finds rather than to the one it was written on, and a failure is automatically re-checked sequentially, so a test that only fails under load is reported as load-sensitive rather than as a defect.

---

1,211 tests, 1,207 passing, 4 ignored, on both Win32 and Win64 targets.
