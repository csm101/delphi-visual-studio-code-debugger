# Documentation

Two kinds of document live here, and the difference matters when you read one.

**Living specifications** are maintained continuously alongside the code. They
describe what is currently known and true; when the code and the document
disagree, the code wins and the document gets corrected.

| | |
|---|---|
| [PROJECT_STATE.md](PROJECT_STATE.md) | Where the project stands: architecture, what works, open milestones, the build and run commands |
| [DAP_DEBUGGER_ARCHITECTURE.md](DAP_DEBUGGER_ARCHITECTURE.md) | Modules, threading model, the breakpoint / evaluate / setVariable flows, the capability list |
| [WHAT_WORKS_WHERE.md](WHAT_WORKS_WHERE.md) | Which features hold on Win64, on Win32, in a single exe and across runtime packages |
| [TRAPS.md](TRAPS.md) | Operational rules that prevent wasted work. Every entry is here because it already cost time once |
| [KNOWN_UNKNOWNS.md](KNOWN_UNKNOWNS.md) | Open questions that block or condition the work. Answered ones move out, they are not kept for history |
| [TEST_CATALOG.md](TEST_CATALOG.md) | What the test suite covers, and what it does not |

**Format notes** are the results of reading real bytes. They are how the symbol
readers were written, and they are the reason a change to one can be checked
against something other than the code that produced it.

| | |
|---|---|
| [RSM_FORMAT_NOTES.md](RSM_FORMAT_NOTES.md) | Overall structure of the Delphi `.rsm` remote debug symbol file |
| [RSM_RECORD_TYPES.md](RSM_RECORD_TYPES.md) | Its record kinds, each marked confirmed / inferred / conjectured |
| [RSM_FIELD_OFFSETS.md](RSM_FIELD_OFFSETS.md) | Byte-level layout of each record |
| [TD32_FORMAT_NOTES.md](TD32_FORMAT_NOTES.md) | The TD32 `.debug` PE section and the `.tds` file |
| [EH_FORMAT_NOTES.md](EH_FORMAT_NOTES.md) | Where a Delphi binary records its exception-handling scopes, per bitness |

**Everything else** is either a procedure or the plan behind a feature that has
since landed. A plan is kept only while it still explains something the code
does not say for itself.

| | |
|---|---|
| [HOW_TO_CREATE_A_NEW_RELEASE.md](HOW_TO_CREATE_A_NEW_RELEASE.md) | The release procedure, end to end |
| [MCP_SERVER.md](MCP_SERVER.md) | The MCP server: its tools, and how to point an agent at it |
| [DISASSEMBLY_PLAN.md](DISASSEMBLY_PLAN.md) · [ASSEMBLY_LEVEL_DEBUGGING.md](ASSEMBLY_LEVEL_DEBUGGING.md) | Disassembly, memory, registers, instruction-granularity stepping |
| [DATA_BREAKPOINTS_PLAN.md](DATA_BREAKPOINTS_PLAN.md) | Watchpoints on a computed address |
| [EXCEPTION_HANDLER_SCOPE_PLAN.md](EXCEPTION_HANDLER_SCOPE_PLAN.md) | Stepping at an exception stop |
| [DEBUG_INFO_FORMATS_TODO.md](DEBUG_INFO_FORMATS_TODO.md) | Debug-information formats not yet read |
| [TASK_RESUME.md](TASK_RESUME.md) | A cursor for work interrupted mid-step. Erased on every commit, so a stub here means nothing is in flight |

The user-facing documentation — installation, a first debug session, the
12-chapter tutorial — is not here. It is at
[mcasoftware.dev](https://mcasoftware.dev/products/delphi-debugger/index.html).
