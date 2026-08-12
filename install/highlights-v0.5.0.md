## What's new

- **A memory view of our own** — scrolls *before* a value as well as after it, marks the bytes that formally belong to it, and highlights what changed since the last stop. No Hex Editor extension needed any more.
- **A Delphi Modules tree** — every loaded BPL/DLL with the debug-info formats actually found for it, filterable, so "why can I see nothing in this package" is answered at a glance instead of from a log.
- Memory can be inspected from the **Watch** panel too, and inspecting a `string`, an array or an object shows **its data**, not the pointer that holds it — including fields inside an expanded object.
- MCP: every addressable variable now carries its **address and size**, so an agent can go straight to `read_memory` / `set_data_breakpoint`.
- Fixed: a package's `.dcp` was only looked for **beside the `.bpl`** — never found for IDE-installed packages, so a `TDateTime` local in a runtime-loaded BPL read as a bare `Double`.
- Fixed: a watch on a main-block variable said `<name: not found>` while the Variables view was displaying it.
- Fixed: `%TEMP%\dap_adapter.log` could grow without limit — 1.5 GB was measured. Now capped and rotated.

---

## What each of these means

### A memory view of our own

Right-click a variable — in **Variables** or in **Watch** — and pick the memory icon on the row.

VS Code's own *View Binary Data* pane treats the variable's address as byte 0 of a file, which means it cannot scroll to what lies *before* the value, cannot show where the value starts and ends, and cannot tell you which bytes just changed. This one is drawn by the extension, so it can:

- **Scroll backwards.** A string's length and reference count live at offset −4 and −12; a dynamic array's at −8. They are now reachable.
- **Mark the value's extent** — exactly the bytes that belong to it, with its first byte outlined so you still know where you are after scrolling. When the size cannot be established the view says so and marks only that first byte, rather than drawing a range it cannot justify.
- **Highlight what changed.** After every stop the bytes that differ from the previous one are flagged, anywhere in the block — inside the variable or right next to it, which is usually the interesting part. The marks stay until the target runs again or you write a byte yourself, so you can scroll around them and they come back.
- **Fit the window.** The row count follows the pane's height, and the row width is yours to set: match a two-dimensional array's own width and the block reads as a matrix.
- **Edit raw bytes**, behind an explicit toggle, written straight into the running process.

The editor's built-in pane is switched off, since this one replaces it. To have it back: `"delphi-win64.stockMemoryView": true` plus `ms-vscode.hexeditor`, which is no longer installed for you.

### The Delphi Modules tree

A real Delphi application loads dozens of packages, and whether debugging works in one of them comes down to a question that had no answer in the UI: *does this module have debug information, and from which file?* The new view in the Debug panel answers it per module — `TD32 (embedded)`, `.map`, `.rsm`, `.dcp`, `.jdbg`, `.tds` — because "TD32" and ".map only" are different situations: the second has no types and no locals, which is why a variable is missing.

The executable is listed first, then the modules **without** debug information — the ones worth noticing — then the rest alphabetically. A module with nothing says what that means where you look for it: *none found — breakpoints here cannot bind*. The view refreshes itself when a package loads while the target is running.

With many modules, the filter button takes space-separated words, all required, matched against name and path: `tab d29` finds `libTabAutomezziD29.bpl`. The count above the list ("7 of 150") tells a filter that worked from one that matched nothing.

### The `.dcp` that was never found

The `.dcp` is where a package's richest debug information lives (types, date/time aliases, unit-scoped constants). It was looked for beside the `.bpl` and nowhere else — but Delphi installs the two in sibling trees (`...\Bpl\Win64\` and `...\Dcp\Win64\`), so for every IDE-installed package it was silently never found. Nothing failed; values just came back less well typed. Measured on a real multi-BPL application: a local declared `TDateTime` displayed as `46245 [Double]`; it now displays as `2026-08-11 [TDateTime]`. The installed layout is probed automatically; a `dcp` path in `launch.json` still wins.

### The watch that said "not found"

A watch is evaluated against the selected stack frame, and selecting frame 0 threw away the frame's function name on the way. Variables declared in a program's `begin..end` block are keyed by that name, so the Variables view listed them while a watch on the very same name answered `<name: not found>`.

### The log that grew to 1.5 GB

`dap_adapter.log` (off unless you set `"diagnosticLog": true`) had a size cap that counted only what one debug session wrote, while the file is appended to across sessions — so it never once applied. The cap is now a property of the file: 64 MB by default, after which the log is rotated and one previous generation is kept. `DAP_LOG_MAX_MB` overrides it; `0` removes the limit.

If you have been running with diagnostics on, this is worth checking: `%TEMP%\dap_adapter.log`.

---

1,237 tests, 1,233 passing, 4 ignored, on both Win32 and Win64 targets.
