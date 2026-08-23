# Delphi Debugger (Win32 and Win64)

Debug **Delphi 32-bit and 64-bit** applications directly in VS Code — no
Embarcadero IDE required.

This extension registers the `delphi-win64` debug type and ships a Debug Adapter
Protocol (DAP) server that drives the Windows Debug API. It reads the debug
information the Delphi compiler already emits (`.map`, `.rsm`, the TD32 `.debug`
PE section, `.dcp` for packages), so breakpoints, call stacks, watches and
variable inspection work against ordinary Delphi builds.

**The adapter is always a 64-bit process, whichever target it debugs.** A 32-bit
application is debugged across the WOW64 boundary, so the debugger neither
shares nor inherits a 32-bit address space — which is where a large project's
symbol data would otherwise run out of room. One binary handles both; the
target's PE header decides, and there is nothing to configure.

The debug type is still called `delphi-win64` because renaming it would break
every existing `launch.json`. It debugs both platforms.

---

## Features

**Run control**

- Launch a program, or attach to a process that is already running — by PID, by
  name, or chosen from a process picker at start
- Stop at the entry point before any user code runs (`stopAtEntry`)
- Step over, step into, step out; continue and pause
- Set next statement (DAP `gotoTargets` / `goto`)
- Per-thread stepping — step over/into/out act on the thread you selected in the
  **Call Stack** view, not just the thread that happened to stop

**Breakpoints**

- Line breakpoints from the editor gutter
- Conditional breakpoints (a Pascal expression)
- Hit-count breakpoints
- Log-points (message logged, execution continues)
- Verification state reported back, so VS Code shows unbound breakpoints honestly

**Call stack and threads**

- Full stack unwinding with function names and source lines, across the main
  executable *and* DLLs / runtime packages
- All threads listed with their names; the process stops as a whole
- Selecting any thread shows that thread's own stack, and its frames' locals and
  watches are inspectable
- **Raw stack scan** — see past code the unwinder cannot get through (see below)

**Variables**

- **Locals** scope: locals, parameters, `var` parameters, locals of the enclosing
  procedure when stopped inside a nested one, and locals of the program's main
  `begin…end` block
- **Registers** scope
- Object, record and dynamic-array expansion in the tree — all fields, including
  those inherited from ancestor classes, nested to any depth
- Type-aware formatting: integers, floats, `TDateTime`, chars, strings, enums,
  sets, Variants, C-string pointers, dynamic arrays in `[…]` notation
- Anonymous methods: captured variables and the anonymous method's own
  parameters are visible when stopped inside the body
- Generic containers such as `TList<T>` and `TDictionary<K, V>` expand and
  enumerate
- Global variables are resolved by name in watch/hover (unqualified, or
  `UnitName.Variable` when the name is ambiguous)
- `setVariable` — edit values in place: integers at the correct storage width,
  floats, dates, chars, strings (via the in-process RTL assignment helpers, so no
  refcount leak), enums by name or ordinal, sets by bitmask, and writes through
  the pointer for `var` parameters

**Expression evaluation**

A Pascal expression evaluator backs **Watch**, **hover data tips**, the **Debug
Console** (REPL) and breakpoint conditions:

- Qualified identifiers, arithmetic, comparison, boolean and set operators,
  string concatenation, indexing
- Type casts, `is` and `as`
- `Length`, `SizeOf`, `Ord`, `Low`, `High`
- Enum and set literals
- Method and property calls, executed inside the debuggee (an exception raised by
  the call is aborted cleanly instead of derailing the session)

**Exceptions**

- Break on first-chance exceptions with class name *and* message
  (`EOracleError: ORA-00942: table or view does not exist`)
- Four exception filters in the **BREAKPOINTS** view
- A per-exception rule engine for finer control (see
  [Exception handling](#exception-handling)), editable in a dedicated rules
  editor — per project, or in a machine-wide file shared by every project
- While stopped on an exception, one button turns it into a rule
  (ignore / log / break) without leaving the debugger
- `$exception` — the live exception object, inspectable in **Locals**, **Watch**
  and on hover

**Multi-module**

- DLLs and runtime packages (BPLs), including packages loaded at runtime with
  `LoadPackage`
- Symbols are loaded lazily, per module, as each one is touched
- Debug-info files can be pre-bound per module with the `modules` property when
  they do not sit next to the binary

**Housekeeping**

- Tells you when a newer release exists on GitHub, once a day at most, with a
  link — because an installer-delivered extension has nothing else to announce
  it (see [Staying up to date](#staying-up-to-date); switch it off with
  `delphi-win64.checkForUpdates`)
- The debugger's own diagnostics go to a **Delphi Debugger** channel in the
  Output panel, leaving the Debug Console for your program's output (see
  [Where the debugger's own logging goes](#where-the-debuggers-own-logging-goes))

---

## Raw stack scan: seeing past code you have no debug information for

You stop deep inside something you did not compile — an exception in the VCL, a
callback out of a third-party control suite, an access violation under the RTL —
and the call stack shows a couple of frames and stops. Everything below was
built without debug information, or without a frame pointer, so there is nothing
to unwind through. And the one thing worth knowing is exactly what is hidden:
**which of your own routines is underneath all that?**

This is the ordinary case on 32-bit targets, which carry no unwind data at all,
so the walk ends at the first routine compiled without a frame pointer. It also
happens on 64-bit in any application assembled largely from packages that were
not built with debug information.

**Press `Toggle Raw Stack Scan`** in the **Call Stack** title bar (the magnifier
icon; also `Delphi Debugger: Toggle Raw Stack Scan` in the Command Palette). The
debugger sweeps the thread's stack word by word for values that could be return
addresses, resolves each against every module it knows — the executable and
every loaded runtime package — and appends what it finds below the real frames.
Your own routines come back with names and source lines even though nothing
could unwind to them.

It takes effect on the stop you are already looking at. No restart, no editing
`launch.json`. (`"rawStackScan": true` in the launch configuration turns it on
from the start, if you would rather not press anything.)

### How much to trust a hit

Every appended entry is marked twice, because either marker on its own can be
lost — the prefix survives a copy-paste into a bug report, the grey row is what
you see at a glance:

| | meaning |
|---|---|
| `[raw]` | the instruction ending at that address was decoded and **is a call** |
| `[raw?]` | there was no line table to decode from, so the hit rests on the address being executable code and nothing more |

**Neither of them means the routine is still on the current chain.** A call that
has already returned leaves its return address behind on the stack, and no sweep
can tell that apart from a live one. Read these as places the program *has
been* — which is usually enough to answer "how did execution get here" — and
never as callers.

That is also why they are **appended below** the real stack instead of being
mixed into it, and why the feature is **off by default**: a stack you did not
ask to have swept must never show a position sitting next to a real frame.

On 64-bit every hit is `[raw?]`: the call-site decoder that proves a hit is
x86-only. It is also needed far less there, since 64-bit code unwinds properly
from `.pdata`.

---

## Requirements

**1. Compile the program you want to debug with debug information.**

| Flag | Purpose |
|---|---|
| `-V -VN -VR` | Emit debug info, `.map` and `.rsm` |
| `-$O-` | Disable optimizations |

The `.exe`, `.map` and `.rsm` should end up in the same directory. Without the
`.rsm` / TD32 information, breakpoints and stepping still work, but variable
inspection is limited.

Source lines have three independent sources, and any one of them is enough for
breakpoints and stepping: the TD32 `.debug` section inside the executable, a
`.map` beside it, or JCL debug data. JCL is worth knowing about if you ship
binaries: a `.jdbg` sidecar — or a `JCLDEBUG` section linked into the executable
itself — lets the debugger resolve lines and procedure names with no `.map` to
distribute. It is generated *from* a `.map` at build time, so you still produce
one; you just do not have to deliver it.

**2. Install the [Delphi IDE plugin](https://github.com/csm101/EditInVsCodeDelphiPlugin).**

This is the piece that makes the debugger usable in practice. It adds an
*Open in VS Code* command to the Delphi IDE which, for the current project or
project group, generates the workspace and the launch configuration — output
paths, source root, the unit search paths, and the package list for a BPL
project. A real Delphi project can carry a couple of hundred search paths; that
configuration is not something anyone wants to write by hand.

The debugger works without it if you write `launch.json` yourself — see
[Getting started](#getting-started) — but with it, debugging a project is one
command from the IDE you already have open.

**3. Install [DelphiLSP](https://marketplace.visualstudio.com/items?itemName=embarcaderotechnologies.delphilsp)**
(`embarcaderotechnologies.delphilsp`) for Delphi language support — syntax
highlighting, navigation and completion. It is a separate extension from
Embarcadero; this one only debugs.

Windows x64 only.

---

## Getting started

Add a configuration to your project's `.vscode/launch.json`:

```jsonc
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug my app",
      "type": "delphi-win64",
      "request": "launch",
      "program": "${workspaceFolder}/Win64/Debug/MyApp.exe",
      "sourceRoot": "${workspaceFolder}",
      "stopAtEntry": false
    }
  ]
}
```

Press `F5`. Set breakpoints in the gutter of any `.pas` file.

### Launch properties

| Property | Description |
|---|---|
| `program` | **Required.** Path to the `.exe` to debug |
| `args` | Command-line arguments passed to the debuggee |
| `mapFile` | `.map` path. Defaults to `program` with a `.map` extension |
| `rsmFile` | `.rsm` path. Defaults to `program` with a `.rsm` extension |
| `sourceRoot` | Root directory for source-file lookup |
| `sourceSearchPaths` | Extra directories (searched two levels deep) for units outside the project — typically the Delphi source tree, e.g. `"${env:BDS}/source"`. If `BDS` is set, its `source` subdirectory is searched automatically |
| `stopAtEntry` | Break at the process entry point. Default `false` |
| `modules` | Pre-bind debug info for DLLs/BPLs — see below |
| `progressLocation` | `statusBar` (default) or `notification` |
| `diagnosticLog` | Write a verbose adapter log to `%TEMP%\dap_adapter.log`. Default `false` |

Source files are resolved by searching `sourceRoot` and one level of
subdirectories; the first match wins.

### DLLs and runtime packages

The adapter normally finds a module's debug info next to the loaded binary on
disk. When it lives elsewhere, bind it explicitly:

```jsonc
"modules": [
  {
    "name": "MyPackage.bpl",
    "map": "C:/build/out/MyPackage.map",
    "rsm": "C:/build/out/MyPackage.rsm",
    "dcp": "C:/build/dcp/MyPackage.dcp"
  }
]
```

`name` is the module's file name; `map`, `rsm` and `dcp` are optional paths.

---

## Attach to a running process

Use `"request": "attach"` and identify the process by PID or by name:

```jsonc
{
  "name": "Attach to my app",
  "type": "delphi-win64",
  "request": "attach",
  "processName": "MyApp.exe",
  "sourceRoot": "${workspaceFolder}",
  "killOnDetach": false
}
```

| Property | Description |
|---|---|
| `processId` | PID of the process to attach to |
| `processName` | File name of the process (used when `processId` is absent or `0`). One instance running: attached to with no prompt. Several: the extension lists them and asks which |
| `program` | Optional. Path to the `.exe` whose `.map` / `.rsm` should be used. Defaults to the image path reported by the OS |
| `killOnDetach` | See below. Default `false` |

The source, `modules` and exception properties from the launch table apply to
attach as well.

> **Two instances running?** `processName` alone still works: the extension
> notices there is a choice to make and opens the picker described below,
> narrowed to that executable. It is deliberately not first-come-first-served —
> silently attaching to whichever instance Windows happened to enumerate first is
> a trap, not a convenience. Cancelling the prompt aborts the session.
>
> Spelling the picker out with `"processId": "${command:delphi-win64.pickProcess}"`
> is equivalent and remains supported; it is what an `inputs` block needs (see
> below), and it makes the behaviour visible in `launch.json` rather than
> implicit.

### Picking the process from a list

Hardcoding a PID means editing `launch.json` every time the target restarts. Set
`processId` to the picker command instead and choose the process when the
session starts:

```jsonc
{
  "name": "Attach to a Delphi Win64 process",
  "type": "delphi-win64",
  "request": "attach",
  "processId": "${command:delphi-win64.pickProcess}",
  "sourceRoot": "${workspaceFolder}"
}
```

A quick pick opens with the running processes — type part of the name, the PID or
the command line to filter. Candidates whose name matches the workspace folder
come first, then ordinary applications, with Windows infrastructure last.
Cancelling it (`Esc`) aborts the session instead of attaching to something
arbitrary.

### Choosing between instances of one executable

When you already know the executable, hunting for it among three hundred system
processes is busywork. Add `processName` next to the picker command and the list
narrows to the instances of that executable:

```jsonc
{
  "name": "Attach to SampleApp",
  "type": "delphi-win64",
  "request": "attach",
  "processName": "SampleApp.exe",
  "processId": "${command:delphi-win64.pickProcess}",
  "sourceRoot": "${workspaceFolder}"
}
```

This works because VS Code passes the enclosing launch configuration to a
`${command:...}` variable, so the picker can read `processName` itself — no
`inputs` block needed. Then:

- **one instance running** — it is attached to immediately, with no prompt;
- **several** — only those are listed, each showing its **main window caption**
  and its **command line**, with the PID, architecture, start time and session
  alongside. Two instances of one application are indistinguishable by name and
  PID, and usually by image path too; the caption is what you can match against a
  window on screen. Type any part of it to filter. When an application titles all
  its windows the same way, and the command lines are identical too, the start
  time is what remains;
- **none** — an error naming the executable, and the session is aborted rather
  than attached to something else.

The name matches case-insensitively, with or without the `.exe` suffix, so
`"SampleApp"` and `"SampleApp.exe"` select the same thing.

To keep the filter out of the configuration's own properties — for instance to
pick an executable unrelated to `processName` — pass it explicitly through an
input instead:

```jsonc
{
  "configurations": [
    {
      "name": "Attach to SampleApp",
      "type": "delphi-win64",
      "request": "attach",
      "processId": "${input:pickSampleApp}",
      "sourceRoot": "${workspaceFolder}"
    }
  ],
  "inputs": [
    {
      "id": "pickSampleApp",
      "type": "command",
      "command": "delphi-win64.pickProcess",
      "args": { "nameFilter": "SampleApp.exe" }
    }
  ]
}
```

An explicit `args.nameFilter` wins over `processName`; with neither, every
process is listed as before.

### Where the list comes from

The debug adapter builds it. `VisualStudioCodeDelphiDebugger.exe
--list-processes [name]` prints the running processes as JSON and exits, using
the same Win32 process APIs the debugger itself uses, so the picker needs no
native VS Code module and no extra tooling — and no elevation to list, although
attaching still has the usual requirements below.

That also means the picker knows each process's **architecture**, and shows it.
Both 32-bit and 64-bit processes are attachable — the adapter is 64-bit and
debugs a 32-bit target across the WOW64 boundary. A process the adapter has not
been verified against (ARM64) is still listed, but marked with the adapter's own
reason rather than offered as a candidate that fails on selection.

If the adapter cannot be found or fails, the picker says so and the session is
aborted. It never falls back to a second source.

Attaching requires `SeDebugPrivilege`; the adapter enables it in its own process
token before calling `DebugActiveProcess`. As usual on Windows, a target running
at a higher integrity level than VS Code itself cannot be attached to.

**`killOnDetach`** decides what happens to the target when the debug session
ends:

- `false` (default) — the debugger detaches and **the process keeps running**.
  This is what you normally want when attaching to an application someone is
  using.
- `true` — the process is **terminated** when you stop the session, exactly as
  if you had launched it from VS Code.

Note that stopping the session while the target is paused at a breakpoint still
resumes it before detaching, so the application continues from where it stopped.

---

## Exception handling

### Filters

The **BREAKPOINTS** view offers four filters:

| Filter | Meaning |
|---|---|
| `delphi` | First-chance Delphi exceptions (`$0EEDFADE`). Accepts a condition: a comma-separated class-name list |
| `av` | First-chance access violations |
| `all` | Every other first-chance exception (noisy) |
| `unhandled` | Unhandled / second-chance exceptions |

### `$exception`

While stopped on a Delphi exception, the live exception object appears as
`$exception` at the top of the **Locals** scope. Expand it to read `Message`,
the class, and any other field or property, exactly like a normal object. It
also works in **Watch** and on hover, and disappears at the next non-exception
stop. Access violations have no Delphi object, so `$exception` is not offered
for them — the class and message summary still is.

### Per-exception rules

Filters are coarse. For real control, add an `exceptionRules` array. Rules are
evaluated **top-down, first match wins**; a matching rule overrides the filters,
and if nothing matches the filters decide.

```jsonc
"exceptionRules": [
  // EAbort is control-flow noise: never break on it.
  { "class": "EAbort", "action": "ignore" },

  // Log every Oracle error with its stack, but keep running.
  { "messageRegex": "ORA-\\d+", "action": "logStack" },

  // Break only for AVs raised in one method's line range.
  { "class": "EAccessViolation", "unit": "OracleData",
    "lineFrom": 2700, "lineTo": 2800, "action": "break" },

  // Catch-all.
  { "action": "break" }
]
```

**Match criteria** — all the ones you specify must hold; omitted means "any":

| Field | Matches |
|---|---|
| `class` | Exact runtime class name, or an array of names (any-of), case-insensitive. Leaf only — does not match descendants |
| `classIs` | The runtime class **or any ancestor** (Delphi `is` semantics); name or array, case-insensitive |
| `code` | The **Win32 exception code**, or an array of codes (any-of). Hex (`"0xC0000005"`, `"$C0000005"`) or decimal (`3221225477`, signed `-1073741819`), string or number |
| `message` | Case-insensitive substring of the exception message |
| `messageRegex` | Regular expression against the message (ignore-case) |
| `unit` | Unit where the exception was raised. `"*unknown*"` matches raises with no resolvable source |
| `line` | Exact source line where raised |
| `lineFrom` / `lineTo` | Inclusive source-line range |

Unit and line refer to the **raise site** — the first stack frame with known
source, since a Delphi `raise` faults inside the RTL.

`code` is the only criterion that can match a **native** Windows exception (one
raised through `RaiseException`, not by a Delphi `raise`). Such an exception has
no exception object, therefore no class and no message, so `class`, `classIs`,
`message` and `messageRegex` can never match it — before `code` existed, the only
way to silence one was to switch the whole "all first-chance exceptions" filter
off:

```jsonc
"exceptionRules": [
  { "code": "0xE06D7363", "action": "ignore" },   // C++ exception from a C++ DLL
  { "code": "0xC0000094", "action": "logStack" }  // integer divide by zero
]
```

The one native code you never need a rule for is `0x406D1388`, the thread-name
announcement `TThread.NameThreadForDebugging` raises: it is debugger protocol
traffic and the adapter consumes it before the rules run.

**Actions:**

| Action | Effect |
|---|---|
| `ignore` | Resume immediately — no stop, no log |
| `log` | Write `class: message` to the Debug Console, then resume |
| `logStack` | Like `log`, plus the formatted call stack |
| `break` | Pause in the debugger |

### The rules editor

Editing rule tables by hand in JSON gets old quickly, and order is semantic. Use:

**Command Palette (`Ctrl+Shift+P`) → `Delphi Debugger: Edit Exception Rules...`**

That route always works — no session, no open Delphi file, nothing else
required. It is the one to reach for if you cannot find the button.

The same command is also a **numbered-list icon** (`☰`) in the title bar of the
**BREAKPOINTS** section, inside the Run and Debug view — not in the "RUN AND
DEBUG" header at the top of the panel, but in the header of the section itself,
where it appears on hover next to VS Code's own icons. It is on the **CALL
STACK** section header too, for when you are already in a session.

Two reasons it can be missing there while the palette command still works:

- the section is collapsed or was hidden through the panel's `...` menu;
- the panel is in its "simple" state — VS Code drops the Call Stack section
  entirely when no session is running *and* no launch configuration is selected.
  Breakpoints survives as soon as one breakpoint exists or you have debugged
  once in that workspace, which is why the button lives there as well.

First pick where the rules live. The list is ordered the way the debugger
evaluates them — narrowest scope first:

- **`<Project>.dproj` rules (local)** and **`<Project>.dproj` rules (shared)**
  — the two files belonging to the Delphi project the configuration debugs,
  described under *Rules that belong to a project* below. Offered as soon as a
  configuration names its project through `delphiProjectFile`;
- **Shared rules (all projects)** — the machine-wide file described below.

Both are created, together with their directory, the first time you save.

Individual launch configurations are **not** offered once the project itself is:
*Debug X* and *Attach to X* are the same project debugged two ways, and a
separate exception policy per configuration is mostly a way to make the two
disagree. A configuration that already contains rules keeps its entry, so
nothing written before this existed becomes unreachable — and the adapter still
honours `exceptionRules` in launch.json either way, whether or not the picker
proposes it. Where no configuration names a project, the list is unchanged: one
entry per configuration, plus the shared file.

The editor then opens with one card per rule, numbered in evaluation order,
match criteria separated from the action, and up/down buttons to reorder. Rules
are validated as you type — unknown fields, invalid actions, regular expressions
that do not compile, inverted line ranges — and saving is blocked while the
table is invalid.

**Save** replaces only the rule array of the selected target; every other byte of
the file, comments included, is left untouched, and the shared file keeps its
shape (a bare array stays a bare array, an object keeps its other keys). The file
is left open and unsaved so you can review or undo before it hits disk. In an
untrusted workspace the editor is read-only and offers **Copy JSON** instead.

### Creating a rule from the exception you are looking at

While the debugger is stopped **on an exception**, a scales-of-justice button
appears in the floating debug toolbar, next to continue/step, and the command
`Delphi Debugger: Create a Rule for This Exception...` becomes available in the
Command Palette. Both disappear as soon as you resume or stop somewhere else —
the rule is about the exception you are looking at, so it is offered only while
you are looking at one.

It reads the current exception (class and message) and its raise site (unit and
line from the top stack frame) and offers the decisions you actually want to
make, pre-filled:

- ignore this class everywhere;
- ignore it when raised in this unit;
- ignore it at this exact unit and line;
- log it with its call stack instead of breaking;
- ignore it when the message contains this text;
- open the rules editor on a fully pre-filled rule, to adjust it first.

Then choose the target — one of the project's own files, the launch
configuration, or the shared file. The new rule is inserted **first**, because
matching is first-match-wins: a more specific rule appended at the bottom would
never be reached. As with the editor, the file is left open and unsaved for
review.

### Rules that belong to a project

A launch configuration is the wrong home for a rule that belongs to a
**package**. If you maintain one `.dpk` inside a host application that loads
dozens of them, your rules have nothing to do with which host `.exe` anyone
launches to test it — and copying them into every configuration that starts that
host is how they go stale.

So a configuration may name the Delphi project it debugs:

```jsonc
"delphiProjectFile": "${workspaceFolder}/packages/libTabAnagD29.dpk"
```

The RAD Studio plugin writes this line for you when it generates the launch
configuration; there is nothing to maintain by hand. It may name the `.dpr`,
the `.dpk` or the `.dproj` — only the folder and the base name matter.

Two rule files next to that project then join the chain:

| File | Who it is for |
|---|---|
| `<Project>.ExceptionSettings.json` | the project's own rules, **commit them** — every developer on the package gets them |
| `<Project>.ExceptionSettings.local.json` | your own overrides, **gitignore it** |

Both have the same shape as the shared file (an object with an `exceptionRules`
array, or a bare array), are hot-reloaded on resume like it, and are ignored if
missing or malformed.

Without `delphiProjectFile` nothing project-scoped is looked for, and rules
resolve exactly as they did before this existed — an older launch.json keeps
working untouched.

### Which rule wins

Rules are evaluated top-down across all four scopes, narrowest first, and the
**first match wins**:

| # | Scope | Where |
|---|---|---|
| 1 | your own, for this project | `<Project>.ExceptionSettings.local.json` |
| 2 | the project's, shared with its team | `<Project>.ExceptionSettings.json` |
| 3 | one launch configuration | `exceptionRules` in launch.json |
| 4 | every project on this machine | the shared file below |

If nothing matches, the exception filters decide.

### Shared rules across projects

A machine-wide baseline can live in
`%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json` — a JSON object with an
`exceptionRules` array (a bare array is accepted too):

```jsonc
{
  "exceptionRules": [
    { "class": "EAbort", "action": "ignore" },
    { "messageRegex": "ORA-\\d+", "action": "logStack" }
  ]
}
```

| Property | Description |
|---|---|
| `useGlobalExceptionRules` | Load the shared file. Default `true` |
| `globalExceptionRulesPath` | Use a different shared-rules file |

The shared file is the widest scope: everything in the table under *Which rule
wins* is consulted before it. A missing or malformed shared file is ignored — it
never breaks debugging. It is **hot-reloaded**, as are the project files: edit
one while stopped, resume, and the new rules apply without restarting the
session. Creating a file that was not there when the session started counts too.

The rules editor and the "create a rule for this exception" command can both
write to this file — pick **Shared rules (all projects)** when they ask for a
target. If a configuration in the workspace sets `globalExceptionRulesPath`, they
follow it rather than the default location.

---

## Progress indicator

Symbol loading, expression evaluation and stepping can take a moment on large
applications, so the adapter reports what it is doing.

| `progressLocation` | Behaviour |
|---|---|
| `statusBar` *(default)* | A spinner in the status bar, out of the way. Several concurrent operations collapse into one item with a `+n` counter and a tooltip listing them all |
| `notification` | Standard DAP progress events, which VS Code renders as notification toasts |

Only one mechanism is active at a time, so a DAP client other than this
extension still gets standard progress events.

---

## Debug information it reads

| Format | Where it comes from |
|---|---|
| **TD32** | The `.debug` section embedded in the PE by the Delphi compiler — source lines, symbols, types |
| **`.map`** | Delphi MAP file — line numbers and symbol addresses |
| **`.rsm`** | Delphi remote-debug symbol file — types, locals, globals |
| **`.dcp`** | Delphi compiled package — locals for BPLs |
| **JCL** | JEDI Code Library debug data, either a linked `JCLDEBUG` PE section or a sidecar `.jdbg` — source lines and procedure names, so a module carrying it needs no `.map` beside it |

ASLR is handled: the running `ImageBase` is compared against the PE preferred
base at load time, so addresses resolve correctly for the executable and every
loaded module.

### What are the `.idx` files next to my binaries?

`MyApp.rsm.idx`, `MyPackage.dcp.idx` and friends are **symbol-index caches**.
The first time the debugger reads a `.rsm` or `.dcp` it has to scan the whole
container to build a lookup index — about half a second for a 45 MB package —
and writes the result next to the file so every later session loads it in
milliseconds instead.

- **Safe to delete.** The next session rebuilds the one it needs.
- **Build artifacts.** Ignore them in version control, next to `.map` and
  `.rsm`: `*.idx`.
- **Self-invalidating.** A sidecar older than its source file, or written in an
  older index format, is ignored and rebuilt — a stale one is never used.
- **Can be built ahead of time.** `DevTools\PrebuildIdx.exe <directory>` indexes
  a whole directory offline, so the first debug session does not pay the scan:

  ```bat
  DevTools\Win64\Debug\PrebuildIdx.exe "C:\Users\Public\Documents\Embarcadero\Studio\23.0\Dcp\Win64" -j 2
  ```

  Worth doing for the RTL and third-party packages, which never change between
  your builds. Your own packages are recompiled constantly, which invalidates
  their sidecars by design.

---

## Limitations

- **32-bit locals need an unoptimised build.** Win32 locals and parameters are
  supported for `-$O-` builds; `-$O+` omits the frame pointer routinely. This is
  the usual Debug configuration, but it is a real constraint on an optimised
  build. (64-bit targets are not affected: they unwind from `.pdata`.)
- **32-bit call stacks can stop short.** 32-bit code carries no unwind data, so
  the stack is walked by the saved-EBP chain, and a routine built without a
  frame pointer sitting between two framed ones still hides its caller. The
  **Toggle Raw Stack Scan** button in the Call Stack title bar is the fallback —
  it reports positions on the stack, not callers.
- **Single process.** The debuggee is launched with `DEBUG_ONLY_THIS_PROCESS`;
  child processes it spawns are not tracked.
- **No disassembly view.**
- **Variable inspection needs `.rsm` / TD32.** With only a `.map` file you get
  breakpoints, stepping and a named call stack, but limited variable data.
- If the stepped thread blocks on a lock held by another thread, the step cannot
  complete — the same constraint VS Code has with other debuggers.

---

## Where the debugger's own logging goes

The **Debug Console** is for your program. Everything the debugger says about
itself — symbol loading, module events, breakpoint binding, timings — goes to a
separate channel instead:

> **Output** panel (`Ctrl+Shift+U`) → the dropdown on the right → **Delphi Debugger**

It used to be interleaved with the debuggee's own output, which made a
`Writeln` from your program hard to find among the debugger's chatter and vice
versa. They are now two panels and neither drowns the other.

The channel appears once a Delphi debug session has started — VS Code lists an
Output channel only after something has created it, so an empty dropdown before
the first session is expected rather than a fault.

For a much more verbose record, set `"diagnosticLog": true` in the launch
configuration; that writes every DAP request, response and debug event to
`%TEMP%\dap_adapter.log`. Leave it off for normal use.

---

## Staying up to date

This extension is installed by an installer, not from a marketplace, so nothing
in VS Code would otherwise tell you a new version exists — and in practice that
means people run an old one for months without knowing.

So it checks. Once a day at most, the extension asks GitHub for the latest
release of this project and, if it is newer than what you have, shows one
notification with a link to the download page.

What it does **not** do, deliberately:

- it never downloads or installs anything — the link opens the release page and
  you decide;
- it does not send anything about you, your code or your projects. The request
  is an anonymous read of a public releases endpoint;
- it stays silent when the check fails, when GitHub is unreachable, or when the
  answer is not newer. A version check that reports its own troubles is a
  nuisance;
- it does not nag: **Skip this version** is remembered, and the check is rate
  limited to once a day whatever happens.

Turn it off entirely with the setting **`delphi-win64.checkForUpdates`**
(*Settings → Extensions → Delphi Debugger*), or in `settings.json`:

```jsonc
"delphi-win64.checkForUpdates": false
```

---

## Troubleshooting

**Breakpoints do not bind, or land on the wrong line** — the binary is usually
older than the source. Check that the `.exe`, `.map` and `.rsm` timestamps match
your last build, and rebuild.

**Variables show garbage or "unavailable"** — the target was probably compiled
with optimizations on, or without `-V -VN -VR`.

**Something else** — set `"diagnosticLog": true` in the launch configuration and
inspect `%TEMP%\dap_adapter.log`. It records every DAP request and response and
every debug event, so it is verbose; leave it off for normal use.

---

## Related

**Delphi IDE integration** — see [Requirements](#requirements): the companion IDE
plugin generates the workspace and launch configurations this debugger consumes.
<https://github.com/csm101/EditInVsCodeDelphiPlugin>

**Source code** — <https://github.com/csm101/delphi-visual-studio-code-debugger>

## License

MIT. See `LICENSE` in the repository.
