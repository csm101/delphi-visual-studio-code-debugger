## What's new

- **A memory view of our own** — scrolls *before* a value as well as after it, marks the bytes that formally belong to it, and highlights what changed since the last stop. No Hex Editor extension needed any more.
- Memory can be inspected from the **Watch** panel too, not only from Variables
- Inspecting a `string`, an array or an object now shows **its data**, not the eight bytes of pointer that hold it
- Fixed: a watch on a main-block variable said `<name: not found>` while the Variables view was displaying it
- Fixed: `%TEMP%\dap_adapter.log` could grow without limit — 1.5 GB was measured. It is now capped and rotated
- Fixed: the test suite left hundreds of scratch directories in `%TEMP%`

---

## What each of these means

### A memory view of our own

Right-click a variable — in **Variables** or in **Watch** — and pick the memory icon on the row.

VS Code's own *View Binary Data* pane treats the variable's address as byte 0 of a file, which means it cannot scroll to what lies *before* the value, cannot show where the value starts and ends, and cannot tell you which bytes just changed. This one is drawn by the extension, so it can:

- **Scroll backwards.** A string's length and reference count live at offset −4 and −12; a dynamic array's at −8. They are now reachable.
- **Mark the value's extent** — exactly the bytes that belong to it, with its first byte outlined so you still know where you are after scrolling. When the size cannot be established the view says so and marks only that first byte, rather than drawing a range it cannot justify.
- **Highlight what changed.** After every stop the bytes that differ from the previous one are flagged, anywhere in the block — inside the variable or right next to it, which is usually the interesting part. The marks stay until the target runs again or you write a byte yourself, so you can scroll around them.
- **Fit the window.** The row count follows the pane's height, and the row width is yours to set: match a two-dimensional array's own width and the block reads as a matrix.
- **Edit raw bytes**, behind an explicit toggle, written straight into the running process.

The editor's built-in pane is switched off, since this one replaces it. To have it back: `"delphi-win64.stockMemoryView": true`.

### What "its data" means

A `string`, a dynamic array, a class instance and an interface all occupy exactly one pointer. Opening a memory view on the variable itself therefore showed a pointer, never the characters or the elements. It now opens on the payload — the text, the elements, the object — while a plain typed pointer still shows the pointer, because there that IS the value.

The same applies to a `var` parameter: you get the caller's variable, not the address of it.

### The watch that said "not found"

A watch is always evaluated against the selected stack frame, and selecting frame 0 threw away the frame's function name on the way. Variables declared in a program's `begin..end` block are keyed by that name, so the Variables view listed them while a watch on the very same name answered `<name: not found>`.

### The log that grew to 1.5 GB

`dap_adapter.log` (off unless you set `"diagnosticLog": true`) had a size cap that counted only what one debug session wrote, while the file is appended to across sessions — so it never once applied. The cap is now a property of the file: 64 MB by default, after which the log is rotated and one previous generation is kept. `DAP_LOG_MAX_MB` overrides it; `0` removes the limit.

If you have been running with diagnostics on, this is worth checking: `%TEMP%\dap_adapter.log`.

---

1,229 tests, 1,225 passing, 4 ignored, on both Win32 and Win64 targets.
