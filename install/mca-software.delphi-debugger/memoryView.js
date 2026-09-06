// Delphi memory view.
//
// VS Code's own "View Binary Data" pane is a file abstraction: the
// memoryReference IS byte 0 of the file, so it cannot scroll BEFORE the value,
// it cannot mark which bytes belong to the variable, and it cannot show what
// changed between two stops -- the hex editor has no API for any of that, and
// DAP has no way to annotate a memory range. This view is ours end to end: it
// reads through the adapter's `readMemory` (which accepts NEGATIVE offsets),
// asks the adapter what the reference actually refers to (`delphiMemoryExtent`,
// a custom request -- no standard one carries a value's byte extent), and draws
// the rest itself.
//
// The pure functions at the top carry the logic worth testing without a running
// VS Code: window arithmetic, the byte diff, and hex parsing. They are exported
// and covered by test/memoryView.test.js.

'use strict';

const BYTES_PER_ROW = 16;   // the default width, not a fixed one
const DEFAULT_ROWS  = 24;   // used only until the pane reports its own height
const MAX_COLUMNS   = 256;
// How many bytes the pane remembers for the change comparison. Generous -- a
// pane full of rows is a couple of kilobytes and scrolling adds more -- but
// bounded, so a long session cannot end up tracking an address space.
const MAX_BASELINE_BYTES = 1 << 20;

// Byte window currently displayed, in offsets RELATIVE TO the memoryReference.
// `start` is signed on purpose: negative means "before the variable", which is
// exactly the thing the stock pane cannot express. Rows follow the pane's
// height and columns are the user's choice -- a 2D array reads as one when the
// row width matches its own, and nothing about 16 makes it the right number.
function makeWindow(start, rows, columns) {
  const r = Math.max(1, rows || DEFAULT_ROWS);
  const c = Math.min(MAX_COLUMNS, Math.max(1, columns || BYTES_PER_ROW));
  return { start: start | 0, rows: r, columns: c, count: r * c };
}

// Scroll by whole rows, positive or negative. No clamping at 0: an address
// before the variable is a legitimate place to look (a string's length header
// lives at -4, a dynamic array's at -8).
function scrollWindow(win, rowDelta) {
  return makeWindow(win.start + rowDelta * win.columns, win.rows, win.columns);
}

// Same top-left byte, different shape. Scrolling position is preserved because
// the offset is what the user is looking at, not the row index.
function reshapeWindow(win, rows, columns) {
  return makeWindow(win.start, rows, columns);
}

// Which bytes changed between two reads of the SAME window, as OFFSETS from the
// memoryReference (windowStart + index), not as indices into the read. Offsets
// survive what indices do not: a scroll, a change of row width, a re-render at
// a different size. The highlight used to be index-based and was wiped by the
// very next render -- the pane re-measures itself after drawing, and that
// second render carried no diff.
//
// A byte that became unreadable (or readable) counts as changed: the display
// for it changes either way.
function diffBytes(previous, next, windowStart) {
  const base = windowStart | 0;
  const changed = new Set();
  if (!previous || !next) return changed;
  const len = Math.max(previous.length, next.length);
  for (let i = 0; i < len; i++) {
    const a = i < previous.length ? previous[i] : null;
    const b = i < next.length     ? next[i]     : null;
    if (a !== b) changed.add(base + i);
  }
  return changed;
}

// How many rows fit in the space the pane has left. Shared with the webview by
// injecting this very function's source into the page, so the rule cannot be
// implemented twice and drift.
//
// The guards are not defensive noise: an implausible row height IS the failure
// that happened. A stretched table distributed its height over its rows, one
// row measured as tall as the pane, the fit collapsed to a single row -- and a
// single row then measures itself as correct, so the pane never recovers.
function rowsThatFit(availableHeight, rowHeight) {
  const h = (rowHeight >= 6 && rowHeight <= 200) ? rowHeight : 16;
  if (!(availableHeight > 0)) return 1;
  return Math.min(512, Math.max(1, Math.floor(availableHeight / h)));
}

// Accepts '4f', '0x4F', '4F ' -- returns null for anything that is not exactly
// one byte. Deliberately strict: a half-typed cell must not be written as a
// plausible value.
function parseHexByte(text) {
  if (typeof text !== 'string') return null;
  const t = text.trim().replace(/^0x/i, '');
  if (!/^[0-9a-fA-F]{1,2}$/.test(t)) return null;
  return parseInt(t, 16);
}

function toHex(n, width) {
  const s = (n >>> 0).toString(16).toUpperCase();
  return width ? s.padStart(width, '0') : s;
}

// Address arithmetic is done in BigInt: a 64-bit target address does not fit a
// JavaScript number without losing the low bits, and a memory view that shows
// the wrong address is worse than no memory view.
function addressAt(baseHex, offset) {
  const base = BigInt(baseHex);
  return base + BigInt(offset);
}

function formatAddress(baseHex, offset) {
  const a = addressAt(baseHex, offset);
  const s = a < 0n ? '-' + (-a).toString(16).toUpperCase() : a.toString(16).toUpperCase();
  return '0x' + s;
}

// Rows for the renderer: address label, the bytes (null where unreadable), and
// per-byte flags the view colours by.
function buildRows(baseHex, win, bytes, extentSize, changed) {
  const rows = [];
  const width = win.columns || BYTES_PER_ROW;
  const rowCount = Math.ceil(win.count / width);
  for (let r = 0; r < rowCount; r++) {
    const rowStart = win.start + r * width;
    const cells = [];
    for (let c = 0; c < width; c++) {
      const index  = r * width + c;
      const offset = rowStart + c;
      const value  = (bytes && index < bytes.length) ? bytes[index] : null;
      cells.push({
        index:    index,
        offset:   offset,
        value:    value,
        // "Formally part of the value": the adapter told us the extent, and
        // this offset falls inside it. Unknown extent marks nothing -- an
        // invented range would be a claim about a neighbouring variable.
        inValue:  extentSize > 0 && offset >= 0 && offset < extentSize,
        // Offset 0 IS the variable's address, and it is marked whether or not
        // the extent is known: once the pane has been scrolled, it is the only
        // thing that says which byte you came here to look at.
        isOrigin: offset === 0,
        // Keyed by OFFSET, so a re-render at a different size still marks the
        // same bytes rather than the same screen positions.
        changed:  !!(changed && changed.has(offset))
      });
    }
    rows.push({
      address:   formatAddress(baseHex, rowStart),
      offset:    rowStart,
      // The row the value starts in, so the address column can say so too --
      // a single marked byte is easy to lose in a full pane.
      hasOrigin: rowStart <= 0 && 0 < rowStart + width,
      cells:     cells
    });
  }
  return rows;
}

/* ------------------------------------------------------------------ view -- */

const vscode = require('vscode');

// One panel per (session, memoryReference). Opening the same variable twice
// brings the existing pane forward instead of stacking duplicates.
const panels = new Map();

function keyFor(sessionId, memoryReference) {
  return sessionId + '|' + memoryReference.toLowerCase();
}

function base64ToBytes(data) {
  if (!data) return [];
  const buf = Buffer.from(data, 'base64');
  const out = new Array(buf.length);
  for (let i = 0; i < buf.length; i++) out[i] = buf[i];
  return out;
}

class MemoryPane {
  constructor(context, session, memoryReference, extent, expression) {
    this.session   = session;
    this.reference = memoryReference;
    // The EXPRESSION the pane was opened on, when there is one. A reference
    // type's payload MOVES: assign a string and the characters live in a new
    // heap block, so re-reading the address the pane opened with shows the old
    // buffer indefinitely -- closing and reopening the pane was the only way to
    // see the current value. Kept so every refresh can re-resolve it.
    this.expression = expression || (extent && extent.name) || '';
    this.extent    = extent || { size: 0, name: '', type: '' };
    this.window    = makeWindow(0, DEFAULT_ROWS);
    this.bytes     = null;
    // Which window `bytes` came from. The diff is only meaningful against the
    // same one -- see refresh().
    this.bytesStart   = null;
    this.bytesColumns = null;
    // Offsets that changed at the last comparison point, kept until the next
    // one: scrolling and resizing do not disturb them.
    this.changedOffsets = new Set();
    // offset -> byte value as of the last comparison point. See refreshOnce.
    this.baseline = new Map();
    // Serialises refreshes; see refresh().
    this.refreshing    = false;
    this.redrawPending = false;
    this.editable  = false;

    const label = this.extent.name ? ('Memory: ' + this.extent.name) : ('Memory ' + memoryReference);
    this.panel = vscode.window.createWebviewPanel(
      'delphiMemoryView', label, { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
      { enableScripts: true, retainContextWhenHidden: true });

    this.panel.webview.onDidReceiveMessage((msg) => this.onMessage(msg),
      undefined, context.subscriptions);
    this.panel.onDidDispose(() => panels.delete(keyFor(session.id, memoryReference)),
      undefined, context.subscriptions);

    this.panel.webview.html = this.html();
  }

  async onMessage(msg) {
    if (!msg) return;
    if (msg.type === 'scroll') {
      this.window = scrollWindow(this.window, msg.rows | 0);
      await this.refresh({ markChanges: false });
      return;
    }
    if (msg.type === 'home') {
      this.window = reshapeWindow(makeWindow(0, this.window.rows, this.window.columns),
                                  this.window.rows, this.window.columns);
      await this.refresh({ markChanges: false });
      return;
    }
    // The pane measured itself: how many rows fit, and how wide the user wants
    // them. Only refetch when the SHAPE actually changed, or every resize event
    // during a drag would issue a read.
    if (msg.type === 'shape') {
      const rows = Math.max(1, msg.rows | 0);
      const columns = Math.max(1, msg.columns | 0);
      if (rows === this.window.rows && columns === this.window.columns) return;
      this.window = reshapeWindow(this.window, rows, columns);
      await this.refresh({ markChanges: false });
      return;
    }
    if (msg.type === 'refresh') {
      await this.refresh({ markChanges: true });
      return;
    }
    if (msg.type === 'setEditable') {
      this.editable = !!msg.value;
      this.post({ type: 'editable', value: this.editable });
      return;
    }
    if (msg.type === 'write') {
      await this.writeByte(msg.offset, msg.text);
      return;
    }
  }

  post(message) {
    try { this.panel.webview.postMessage(message); } catch (e) { /* pane gone */ }
  }

  async writeByte(offset, text) {
    const value = parseHexByte(text);
    if (value === null) {
      this.post({ type: 'error', message: '"' + text + '" is not a byte (expected 00..FF)' });
      await this.refresh({ markChanges: false });
      return;
    }
    try {
      await this.session.customRequest('writeMemory', {
        memoryReference: this.reference,
        offset: offset,
        data: Buffer.from([value]).toString('base64')
      });
      // The adapter emits a `memory` event for its own write, which routes back
      // here as a refresh -- but do not depend on the round trip for the pane
      // the user is looking at.
      await this.refresh({ markChanges: true });
    } catch (err) {
      this.post({ type: 'error',
        message: 'Write refused: ' + (err && err.message ? err.message : String(err)) });
      await this.refresh({ markChanges: false });
    }
  }

  // Re-resolve the expression and follow it if its storage moved. Returns true
  // when the pane is now looking somewhere else, which also means the previous
  // bytes describe a different address and must not be diffed against.
  async followExpression() {
    if (!this.expression) return false;
    let reply;
    try {
      reply = await this.session.customRequest('evaluate',
        { expression: this.expression, context: 'watch' });
    } catch (err) {
      return false;   // out of scope at this stop: keep showing the address we have
    }
    if (!reply || !reply.memoryReference) return false;
    if (reply.memoryReference.toLowerCase() === this.reference.toLowerCase()) {
      // Same storage, but the EXTENT can still have changed -- a string keeps
      // its buffer and grows, an array is resized in place.
      this.extent = await fetchExtent(this.session, this.reference);
      return false;
    }
    this.reference = reply.memoryReference;
    this.extent = await fetchExtent(this.session, this.reference);
    this.panel.title = 'Memory: ' + (this.extent.name || this.expression);
    return true;
  }

  async refresh(options) {
    const markChanges = !!(options && options.markChanges);
    // A refresh awaits several round trips to the adapter, and anything can
    // arrive meanwhile -- a resize, a second event, the user's own button. A
    // request that lands mid-flight is REDRAWN afterwards rather than run as a
    // second comparison: comparing the bytes a refresh has just read against
    // themselves finds nothing changed and would erase marks that are correct.
    if (this.refreshing) {
      this.redrawPending = true;
      return;
    }
    this.refreshing = true;
    try {
      await this.refreshOnce(markChanges);
    } finally {
      this.refreshing = false;
    }
    if (this.redrawPending) {
      this.redrawPending = false;
      await this.refresh({ markChanges: false });
    }
  }

  async refreshOnce(markChanges) {
    const moved = await this.followExpression();
    let bytes = null;
    let unreadable = 0;
    try {
      const reply = await this.session.customRequest('readMemory', {
        memoryReference: this.reference,
        offset: this.window.start,
        count:  this.window.count
      });
      bytes = base64ToBytes(reply && reply.data);
      unreadable = (reply && reply.unreadableBytes) || 0;
    } catch (err) {
      this.post({ type: 'error',
        message: 'Read failed: ' + (err && err.message ? err.message : String(err)) });
      return;
    }

    // The marks last until the next COMPARISON POINT -- the target ran, or a
    // write was made through this pane -- and nothing else disturbs them.
    // Scrolling, resizing the pane and changing the row width are all just
    // LOOKING: the marks are offsets from the reference, so they stay true, go
    // off screen and come back. Each of those used to clear them, which meant a
    // highlight could not survive the one thing anyone does after seeing it --
    // scroll around to look at what is next to it.
    //
    // The baseline is a map by OFFSET rather than the previous window, so
    // scrolling between two stops does not blind the comparison: a byte first
    // seen while scrolling is recorded, and the next stop can still say whether
    // it moved. Every byte read is compared, inside the value's extent or not --
    // "what else in this block moved" is most of the reason to watch memory.
    if (moved) {
      this.baseline.clear();
      this.changedOffsets = new Set();
    }
    if (markChanges) {
      const changedNow = new Set();
      for (var I = 0; I < bytes.length; I++) {
        const offset = this.window.start + I;
        const was = this.baseline.get(offset);
        if (was !== undefined && was !== bytes[I])
          changedNow.add(offset);
        this.baseline.set(offset, bytes[I]);   // this read becomes the new point
      }
      this.changedOffsets = changedNow;
    } else {
      // Just looking. Record bytes never seen before -- so a stop after a scroll
      // can still report what moved there -- but never overwrite a byte the last
      // comparison point recorded, or the change would be compared away.
      for (var J = 0; J < bytes.length; J++) {
        const offset = this.window.start + J;
        if (!this.baseline.has(offset))
          this.baseline.set(offset, bytes[J]);
      }
    }
    // A pane can be scrolled through a lot of memory; the baseline is bounded
    // rather than left to track an address space. Dropping it costs one stop's
    // worth of marks, never a wrong one.
    if (this.baseline.size > MAX_BASELINE_BYTES) {
      this.baseline.clear();
      for (var K = 0; K < bytes.length; K++)
        this.baseline.set(this.window.start + K, bytes[K]);
    }
    const changed = this.changedOffsets;

    this.bytes        = bytes;
    this.bytesStart   = this.window.start;
    this.bytesColumns = this.window.columns;
    this.post({
      type:  'render',
      rows:  buildRows(this.reference, this.window, bytes, this.extent.size, changed),
      header: {
        name:       this.extent.name,
        typeName:   this.extent.type,
        size:       this.extent.size,
        reference:  this.reference,
        start:      this.window.start,
        rows:       this.window.rows,
        columns:    this.window.columns,
        unreadable: unreadable,
        // Stated as a NUMBER, not left to the eye: a fading highlight that
        // nobody catches is indistinguishable from one that never fired.
        changed:    changed.size,
        moved:      moved,
        editable:   this.editable
      }
    });
  }

  html() {
    const nonce = String(Date.now()) + Math.random().toString(16).slice(2);
    const csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-" + nonce + "';";
    return `<!DOCTYPE html>
<html><head>
<meta http-equiv="Content-Security-Policy" content="${csp}">
<style>
  body { font-family: var(--vscode-editor-font-family, monospace); font-size: 12px;
         color: var(--vscode-editor-foreground); padding: 6px; }
  .bar { display: flex; gap: 6px; align-items: center; margin-bottom: 6px; flex-wrap: wrap; }
  button { font: inherit; color: var(--vscode-button-foreground);
           background: var(--vscode-button-background); border: none; padding: 2px 8px; cursor: pointer; }
  button.off { background: var(--vscode-button-secondaryBackground);
               color: var(--vscode-button-secondaryForeground); }
  table { border-collapse: collapse; }
  td { padding: 0 3px; white-space: pre; }
  td.addr { color: var(--vscode-descriptionForeground); padding-right: 10px; }
  td.ascii { padding-left: 10px; color: var(--vscode-descriptionForeground); }
  span.b { padding: 0 1px; }
  /* The variable's formal extent: where it starts and where it ends.
     Marked with an UNDERLINE rather than a background, deliberately: the change
     highlight owns the background, and two states that fight over the same
     property cannot both be shown on a byte that is in the value AND just
     changed -- which is the single most interesting byte on the screen. */
  span.inValue { border-bottom: 2px solid var(--vscode-charts-blue, var(--vscode-focusBorder)); }
  /* A byte that changed at the last refresh, ANYWHERE in the block -- inside
     the value or next to it. The fade is the point: it says "this just changed"
     without leaving the pane permanently striped. Long enough to be caught
     after a step, and it keeps the foreground colour to the end so a byte that
     changed stays legible as changed after the background has gone. */
  /* animation-fill-mode "forwards" matters: the flash ends on a state that still OVERRIDES the
     extent shading, and the bold warning colour stays until the next
     comparison. Without it the byte fell straight back to looking like every
     other byte inside the value. */
  span.changed { animation: fade 4s ease-out 1 forwards;
                 color: var(--vscode-editorWarning-foreground); font-weight: bold; }
  @keyframes fade {
    0%   { background: var(--vscode-editorWarning-foreground); color: var(--vscode-editor-background); }
    60%  { background: var(--vscode-editorWarning-foreground); color: var(--vscode-editor-background); }
    100% { background: transparent; color: var(--vscode-editorWarning-foreground); }
  }
  /* BOTH at once -- inside the value and changed at this stop. It gets its own
     rule rather than being left to whichever declaration happens to win: the
     blue underline (in the value) stays and thickens, the text is warning-bold
     (changed), and the flash background is shared with any other changed byte.
     The three cases are then distinguishable at a glance: underline only = part
     of the value; warning text only = changed, outside the value; both = the
     value's own bytes just moved. */
  span.inValue.changed { border-bottom-width: 3px; }

  /* The variable's own address: the anchor once the pane has been scrolled. */
  span.origin { outline: 1px solid var(--vscode-charts-blue, var(--vscode-focusBorder)); }
  td.addr.origin { color: var(--vscode-charts-blue, var(--vscode-focusBorder)); font-weight: bold; }
  span.gap { color: var(--vscode-disabledForeground); }
  span.b[contenteditable="true"]:focus { outline: 1px solid var(--vscode-focusBorder); }
  /* The header line: what is on screen, and where. Each part carries its own
     weight -- the variable and its address are what the eye returns to, the
     rest is context. */
  .note { color: var(--vscode-descriptionForeground); margin-bottom: 4px;
          padding: 2px 4px; background: var(--vscode-editorWidget-background, transparent);
          border-left: 3px solid var(--vscode-charts-blue, var(--vscode-focusBorder)); }
  .note .who        { color: var(--vscode-editor-foreground); font-weight: bold; }
  .note .ofType     { color: var(--vscode-descriptionForeground); }
  .note .at         { color: var(--vscode-charts-blue, var(--vscode-focusBorder)); font-weight: bold; }
  .note .extent     { color: var(--vscode-editor-foreground); }
  .note .noextent   { font-style: italic; }
  .note .didchange  { color: var(--vscode-editorWarning-foreground); font-weight: bold; }
  .note .unreadable { color: var(--vscode-errorForeground); }
  .note .sep        { opacity: 0.5; }
  .err  { color: var(--vscode-errorForeground); margin-bottom: 4px; min-height: 1em; }
  .cols { display: inline-flex; gap: 3px; align-items: center;
          color: var(--vscode-descriptionForeground); }
  .cols input { width: 4em; font: inherit; text-align: right;
                color: var(--vscode-input-foreground);
                background: var(--vscode-input-background);
                border: 1px solid var(--vscode-input-border, transparent); }
  /* The WRAPPER owns the leftover height and the row count is derived from it.
     The table must NOT be the flex item: a stretched table distributes its
     height across its rows, so one row grew to fill the pane, the measured row
     height became the pane height, and the fit collapsed to a single row that
     then kept measuring itself as correct. */
  html, body { height: 100%; }
  body { display: flex; flex-direction: column; margin: 0; padding: 6px; }
  #gridwrap { flex: 1 1 auto; overflow: hidden; min-height: 0; }
  #grid { width: max-content; }
</style>
</head><body>
<div class="bar">
  <button id="up">▲ back</button>
  <button id="down">▼ forward</button>
  <button id="home">value start</button>
  <button id="refresh">refresh</button>
  <button id="edit" class="off">edit: off</button>
  <span class="cols">columns:
    <button id="fewer" title="Narrower rows">−</button>
    <input id="columns" type="number" min="1" max="256" step="1" value="16"
           title="Bytes per row. Match it to a 2D array's row width and the block reads as one.">
    <button id="more" title="Wider rows">+</button>
  </span>
</div>
<div class="note" id="note"></div>
<div class="err" id="err"></div>
<div id="gridwrap"><table id="grid"></table></div>
<script nonce="${nonce}">
  const vscodeApi = acquireVsCodeApi();
  const grid = document.getElementById('grid');
  const note = document.getElementById('note');
  const err  = document.getElementById('err');
  let editable = false;

  const colsInput = document.getElementById('columns');
  let columns = 16;
  let visibleRows = 1;

  // A page is what is on screen minus one row of overlap, so the eye keeps a
  // line of context across a jump. It follows the pane's height like everything
  // else here.
  function pageRows() { return Math.max(1, visibleRows - 1); }

  document.getElementById('up').onclick      = () => vscodeApi.postMessage({ type: 'scroll', rows: -pageRows() });
  document.getElementById('down').onclick    = () => vscodeApi.postMessage({ type: 'scroll', rows: pageRows() });
  document.getElementById('home').onclick    = () => vscodeApi.postMessage({ type: 'home' });
  document.getElementById('refresh').onclick = () => vscodeApi.postMessage({ type: 'refresh' });
  document.getElementById('edit').onclick    = () => vscodeApi.postMessage({ type: 'setEditable', value: !editable });
  document.getElementById('fewer').onclick   = () => setColumns(columns - 1);
  document.getElementById('more').onclick    = () => setColumns(columns + 1);
  colsInput.addEventListener('change', () => setColumns(parseInt(colsInput.value, 10)));

  function setColumns(n) {
    if (!isFinite(n)) return;
    columns = Math.min(256, Math.max(1, n | 0));
    colsInput.value = String(columns);
    sendShape();
  }

  // Rows are DERIVED from the pane: measure one rendered row and divide the
  // space left under the header by it. Measured rather than assumed, because
  // the font is the editor's and the user can change it at any time.
  // Injected verbatim from the module so the fit rule has ONE implementation,
  // and the one that is unit-tested.
  ${rowsThatFit.toString()}

  function rowHeight() {
    // Averaged over the rows actually drawn: one row can be taller than the
    // rest while the pane is settling, and rowsThatFit refuses an implausible
    // value anyway.
    const rendered = grid.querySelectorAll('tr');
    if (rendered.length === 0) return 16;
    return grid.getBoundingClientRect().height / rendered.length;
  }

  function sendShape() {
    const wrap = document.getElementById('gridwrap');
    const rows = rowsThatFit(wrap.getBoundingClientRect().height, rowHeight());
    visibleRows = rows;
    vscodeApi.postMessage({ type: 'shape', rows: rows, columns: columns });
  }

  // Scrolling with the wheel is what a hex pane is expected to do; the buttons
  // stay for keyboard-only use and for whole-page jumps.
  window.addEventListener('wheel', (e) => {
    const step = e.deltaY > 0 ? 1 : -1;
    vscodeApi.postMessage({ type: 'scroll', rows: step * (e.shiftKey ? pageRows() : 1) });
  }, { passive: true });

  let resizeTimer = null;
  window.addEventListener('resize', () => {
    // Debounced: a drag fires this continuously, and each one would otherwise
    // be a read of the debuggee's memory.
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(sendShape, 120);
  });

  function applyEditable(on) {
    editable = on;
    const b = document.getElementById('edit');
    b.textContent = 'edit: ' + (on ? 'ON' : 'off');
    b.className = on ? '' : 'off';
    render(lastPayload);
  }

  let lastPayload = null;

  function printable(v) {
    if (v === null) return '.';
    return (v >= 32 && v < 127) ? String.fromCharCode(v) : '.';
  }

  function render(payload) {
    if (!payload) return;
    lastPayload = payload;
    const h = payload.header;
    if (typeof h.columns === 'number' && h.columns !== columns) {
      columns = h.columns;
      colsInput.value = String(columns);
    }
    if (typeof h.rows === 'number') visibleRows = h.rows;
    // Built as elements rather than one string: this line is the pane's only
    // statement of WHAT is on screen, and a flat grey sentence made the name,
    // the address and a change count read as equally unimportant.
    note.textContent = '';
    function part(text, cls) {
      const s = document.createElement('span');
      if (cls) s.className = cls;
      s.textContent = text;
      note.appendChild(s);
    }
    function sep() { part('  ·  ', 'sep'); }

    if (h.name) {
      part(h.name, 'who');
      if (h.typeName) part(' : ' + h.typeName, 'ofType');
      sep();
    }
    part(h.reference, 'at');
    sep();
    if (h.size > 0) part(h.size + ' byte(s) of the value', 'extent');
    else            part('extent unknown — only its first byte is marked', 'noextent');
    if (h.changed)    { sep(); part(h.changed + ' byte(s) changed', 'didchange'); }
    if (h.moved)      { sep(); part('the value moved: now at this address', 'didchange'); }
    // Said as "past the end", because that is what it is: the pane asks for a
    // full screen of bytes and the mapped region ends before that. It is not a
    // statement about the variable's size.
    if (h.unreadable) { sep(); part(h.unreadable + ' byte(s) past the end of the mapped region', 'unreadable'); }

    grid.textContent = '';
    for (const row of payload.rows) {
      const tr = document.createElement('tr');
      const addr = document.createElement('td');
      addr.className = 'addr' + (row.hasOrigin ? ' origin' : '');
      addr.textContent = row.address;
      tr.appendChild(addr);

      const hex = document.createElement('td');
      for (const cell of row.cells) {
        const s = document.createElement('span');
        s.className = 'b' + (cell.inValue ? ' inValue' : '') + (cell.changed ? ' changed' : '') +
                      (cell.isOrigin ? ' origin' : '') + (cell.value === null ? ' gap' : '');
        if (cell.isOrigin) s.title = 'the variable starts here';
        s.textContent = cell.value === null ? '??' :
          cell.value.toString(16).toUpperCase().padStart(2, '0');
        if (editable && cell.value !== null) {
          s.contentEditable = 'true';
          // A typed cell commits on Enter AND on losing focus. Before, only
          // Enter wrote: clicking away left the typed text sitting in the cell
          // until the next render, so the pane was showing a byte that is not
          // in the debuggee and the user had no way to tell whether the write
          // had happened. Escape is the way out without writing.
          let committed = s.textContent;
          const commit = () => {
            const text = s.textContent.trim();
            if (text === committed) return;
            committed = text;
            vscodeApi.postMessage({ type: 'write', offset: cell.offset, text: text });
          };
          s.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              commit();
              s.blur();
            } else if (e.key === 'Escape') {
              e.preventDefault();
              s.textContent = committed;
              s.blur();
            }
          });
          s.addEventListener('blur', commit);
        }
        hex.appendChild(s);
        hex.appendChild(document.createTextNode(' '));
      }
      tr.appendChild(hex);

      const ascii = document.createElement('td');
      ascii.className = 'ascii';
      ascii.textContent = row.cells.map((c) => printable(c.value)).join('');
      tr.appendChild(ascii);
      grid.appendChild(tr);
    }

    // Re-measure once the rows exist: the first render happens against an empty
    // grid, so the row height was a fallback. sendShape is a no-op at the
    // adapter when the shape has not changed, so this settles after one pass
    // instead of looping.
    requestAnimationFrame(sendShape);
  }

  window.addEventListener('message', (event) => {
    const msg = event.data;
    if (!msg) return;
    if (msg.type === 'render')   { err.textContent = ''; render(msg); }
    if (msg.type === 'error')    { err.textContent = msg.message; }
    if (msg.type === 'editable') { applyEditable(msg.value); }
  });

  // Fit the pane before the first bytes arrive, so the opening read is already
  // the right size rather than a default that is immediately replaced.
  sendShape();
</script>
</body></html>`;
  }
}

// What the reference refers to, straight from the adapter. A failure here is
// not fatal: the view still draws bytes, it just marks no extent.
async function fetchExtent(session, memoryReference) {
  try {
    const reply = await session.customRequest('delphiMemoryExtent',
      { memoryReference: memoryReference });
    if (!reply || reply.unknownReference) return { size: 0, name: '', type: '' };
    return {
      size: typeof reply.size === 'number' ? reply.size : 0,
      name: reply.name || '',
      type: reply.type || ''
    };
  } catch (err) {
    return { size: 0, name: '', type: '' };
  }
}

// The memoryReference for whatever the command was invoked on. Three routes,
// in order: the Variables-view context object VS Code passes to the menu item;
// an expression the user types (which is how a WATCH row is reached -- the
// menu contribution point for the watch view is not one we can rely on); and
// nothing, which is an honest refusal rather than a guess.
// The expression a menu context names, if it names one. `evaluateName` is the
// spelling that resolves in the debuggee (`Self.FList[2].Name`), which is what
// re-resolution needs; a bare `name` is the fallback for rows that carry none.
function expressionOf(commandArgument) {
  const variable = commandArgument && (commandArgument.variable || commandArgument);
  if (!variable) return '';
  return variable.evaluateName || variable.expression ||
         (typeof variable.name === 'string' ? variable.name : '');
}

async function resolveReference(session, commandArgument) {
  const variable = commandArgument && (commandArgument.variable || commandArgument);
  if (variable && typeof variable.memoryReference === 'string' && variable.memoryReference) {
    return variable.memoryReference;
  }

  // A row that carries no reference in the menu context but does name something
  // evaluable -- a WATCH row is the case -- is resolved by evaluating it, not by
  // asking the user to retype what they are already pointing at.
  let expression = variable &&
    (variable.evaluateName || variable.expression ||
     (typeof variable.name === 'string' ? variable.name : ''));
  if (!expression) {
    expression = await vscode.window.showInputBox({
      prompt: 'Delphi memory view: expression to inspect',
      placeHolder: 'e.g. Text, Buf, Self.FName, @Rec'
    });
  }
  if (!expression) return null;

  const reply = await session.customRequest('evaluate',
    { expression: expression, context: 'watch' });
  if (reply && reply.memoryReference) return reply.memoryReference;

  vscode.window.showWarningMessage(
    '"' + expression + '" has no address in the debuggee, so there is nothing to dump. ' +
    'A computed value (an arithmetic result, a function return) exists nowhere in memory.');
  return null;
}

async function openMemoryView(context, commandArgument) {
  const session = vscode.debug.activeDebugSession;
  if (!session) {
    vscode.window.showInformationMessage('The Delphi memory view needs a running debug session.');
    return;
  }
  const reference = await resolveReference(session, commandArgument);
  if (!reference) return;

  const key = keyFor(session.id, reference);
  const existing = panels.get(key);
  if (existing) {
    existing.panel.reveal(vscode.ViewColumn.Beside, true);
    await existing.refresh({ markChanges: true });
    return;
  }

  const extent = await fetchExtent(session, reference);
  const pane = new MemoryPane(context, session, reference, extent,
                              expressionOf(commandArgument));
  panels.set(key, pane);
  await pane.refresh({ markChanges: false });
}

// Coalescing timers, one per session. See refreshSession.
const pendingRefreshes = new Map();

// Refresh every open pane of a session. Called for the adapter's `memory` event
// and at every stop: the target ran, so the bytes on screen are from before.
//
// COALESCED, and that is not a performance tweak -- it is what makes the
// changed-byte highlight work at all. A single stop produces TWO triggers
// milliseconds apart: the `stopped` event, and the `memory` event the adapter
// emits at every stop to tell open panes their bytes may be stale. Run as two
// comparisons, the first diffs the previous bytes against the new ones and
// marks what changed, and the second diffs the new bytes against THEMSELVES,
// finds nothing, and wipes the marks before they can be seen. Two triggers
// describing one change must produce one comparison.
function refreshSession(sessionId) {
  const existing = pendingRefreshes.get(sessionId);
  if (existing) clearTimeout(existing);
  pendingRefreshes.set(sessionId, setTimeout(() => {
    pendingRefreshes.delete(sessionId);
    for (const [key, pane] of panels) {
      if (key.startsWith(sessionId + '|')) pane.refresh({ markChanges: true });
    }
  }, 80));
}

function closeSession(sessionId) {
  for (const [key, pane] of Array.from(panels)) {
    if (key.startsWith(sessionId + '|')) {
      panels.delete(key);
      try { pane.panel.dispose(); } catch (e) { /* already gone */ }
    }
  }
}

module.exports = {
  openMemoryView: openMemoryView,
  refreshSession: refreshSession,
  closeSession: closeSession,
  // Exported for the unit tests -- the arithmetic and the diff are where a
  // defect would be silent (a wrong address renders exactly like a right one).
  makeWindow: makeWindow,
  scrollWindow: scrollWindow,
  reshapeWindow: reshapeWindow,
  rowsThatFit: rowsThatFit,
  diffBytes: diffBytes,
  parseHexByte: parseHexByte,
  buildRows: buildRows,
  formatAddress: formatAddress,
  BYTES_PER_ROW: BYTES_PER_ROW,
  // For the tests only. The pane's BEHAVIOUR -- what survives a second refresh,
  // what a stop's two events add up to -- is where the defects actually were,
  // and none of it is reachable through the pure functions above.
  __internals: {
    MemoryPane: MemoryPane,
    panels: panels,
    keyFor: keyFor
  }
};
