// The memory view's arithmetic, diff and hex parsing.
//
//   node test/memoryView.test.js      (from the extension folder)
//
// These are the parts where a defect is SILENT: a wrong address renders exactly
// like a right one, a missed diff simply shows no highlight, and a sloppy hex
// parse writes a plausible byte into a live process. The rendering itself is
// left to the eye; this is not.

const path = require('path');
const Module = require('module');

const stubPath = require.resolve('./vscode-stub.js');
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'vscode') return stubPath;
  return origResolve.call(this, request, ...rest);
};

const mv = require(path.join(__dirname, '..', 'memoryView.js'));

let failures = 0;

function eq(label, got, expected) {
  const g = JSON.stringify(got);
  const e = JSON.stringify(expected);
  if (g === e) {
    console.log('ok    ' + label);
  } else {
    failures++;
    console.log('FAIL  ' + label + ' -> ' + g + '   expected ' + e);
  }
}

/* -------------------------------------------------- window arithmetic ----- */

// Scrolling BACK past the reference is the whole point: VS Code's own pane
// cannot express a negative offset, which is why this view exists.
const win = mv.makeWindow(0, 4);
eq('window starts at the value', win.start, 0);
eq('window covers whole rows', win.count, 4 * mv.BYTES_PER_ROW);
eq('scrolling back goes negative', mv.scrollWindow(win, -2).start, -2 * mv.BYTES_PER_ROW);
eq('scrolling forward advances', mv.scrollWindow(win, 3).start, 3 * mv.BYTES_PER_ROW);
eq('back then forward returns', mv.scrollWindow(mv.scrollWindow(win, -5), 5).start, 0);

/* ------------------------------------------- shape: rows and columns ------ */

// Rows follow the pane's height and columns are the user's choice. A row width
// that matches a 2D array's own is what makes the block read as a matrix -- the
// reason columns are adjustable at all.
const wide = mv.makeWindow(0, 3, 24);
eq('a chosen width is kept', wide.columns, 24);
eq('the read size follows rows x columns', wide.count, 3 * 24);
eq('scrolling advances by ONE row of the CURRENT width',
   mv.scrollWindow(wide, 1).start, 24);
eq('reshaping keeps the top-left byte', mv.reshapeWindow(mv.scrollWindow(wide, 2), 5, 8).start, 48);
eq('reshaping applies the new shape', mv.reshapeWindow(wide, 5, 8).count, 40);
// Nonsense shapes are clamped rather than propagated: a zero-column window
// would divide by zero when laying out rows, and a zero-row one would read
// nothing while looking like a working pane.
eq('zero columns is clamped to one', mv.makeWindow(0, 2, 0).columns, mv.BYTES_PER_ROW);
eq('negative rows is clamped to one', mv.makeWindow(0, -3, 8).rows, 1);
eq('an absurd width is capped', mv.makeWindow(0, 1, 100000).columns <= 256, true);

// Rows are laid out at the CHOSEN width, so a 4-wide window is what a 4-column
// matrix looks like.
const square = [];
for (let i = 0; i < 16; i++) square.push(i);
const grid4 = mv.buildRows('0x2000', mv.makeWindow(0, 4, 4), square, 0, new Set());
eq('four rows of four', grid4.length, 4);
eq('second row starts one width in', grid4[1].address, '0x2004');
eq('the last cell is the last byte', grid4[3].cells[3].value, 15);

/* ------------------------------------------------- how many rows fit ------ */

eq('a normal pane fits its rows', mv.rowsThatFit(320, 16), 20);
eq('a partial row is not counted', mv.rowsThatFit(327, 16), 20);
eq('a pane with no height still shows one row', mv.rowsThatFit(0, 16), 1);
// The defect this came from: the table was a stretched flex item, so its single
// row measured as tall as the whole pane, the fit collapsed to one row, and one
// row keeps measuring itself as correct -- the pane never recovers on its own.
eq('a row as tall as the pane is refused as a measurement',
   mv.rowsThatFit(900, 900), Math.floor(900 / 16));
eq('a sub-pixel row height is refused too', mv.rowsThatFit(320, 0.2), 20);
eq('the row count is capped', mv.rowsThatFit(1e7, 8) <= 512, true);

/* ------------------------------------------------------ addresses --------- */

// 64-bit addresses do not survive JavaScript number arithmetic; these would be
// silently rounded without BigInt (0x7FF6A1B2C3D4E5F6 + 1 is not representable).
eq('address of a negative offset', mv.formatAddress('0x1000', -16), '0xFF0');
eq('address of a forward offset', mv.formatAddress('0x1000', 32), '0x1020');
eq('a 64-bit address keeps its low bits',
   mv.formatAddress('0x7FF6A1B2C3D4E5F6', 1), '0x7FF6A1B2C3D4E5F7');

/* ----------------------------------------------------------- diff --------- */

eq('no previous read marks nothing', mv.diffBytes(null, [1, 2, 3], 0).size, 0);
eq('an unchanged read marks nothing', Array.from(mv.diffBytes([1, 2, 3], [1, 2, 3], 0)), []);
eq('one changed byte', Array.from(mv.diffBytes([1, 2, 3], [1, 9, 3], 0)), [1]);
// A byte that became unreadable (or readable) changes what is DISPLAYED, so it
// counts -- otherwise a region that got unmapped would look untouched.
eq('a byte that disappeared counts', Array.from(mv.diffBytes([1, 2], [1], 0)), [1]);
// Marks are OFFSETS from the reference, not indices into the read: the pane
// re-renders at a different size right after drawing (it measures itself), and
// an index-keyed mark does not survive that.
eq('marks are offsets, not indices',
   Array.from(mv.diffBytes([1, 2, 3], [1, 9, 3], -32)), [-31]);

/* ------------------------------------------------------ hex parsing ------- */

eq('plain byte', mv.parseHexByte('4f'), 0x4F);
eq('0x-prefixed byte', mv.parseHexByte('0x4F'), 0x4F);
eq('single digit', mv.parseHexByte('7'), 7);
eq('surrounding space', mv.parseHexByte(' 1a '), 0x1A);
// Everything a half-typed cell can contain must be REFUSED, not rounded into a
// value that then lands in a live process.
eq('empty is refused', mv.parseHexByte(''), null);
eq('three digits is refused', mv.parseHexByte('1AF'), null);
eq('non-hex is refused', mv.parseHexByte('zz'), null);
eq('decimal-looking overflow is refused', mv.parseHexByte('256'), null);

/* ------------------------------------------------------------ rows -------- */

const bytes = [];
for (let i = 0; i < 2 * mv.BYTES_PER_ROW; i++) bytes.push(i);
const rows = mv.buildRows('0x1000', mv.makeWindow(0, 2), bytes, 4, mv.diffBytes(null, bytes));
eq('two rows', rows.length, 2);
eq('first row address', rows[0].address, '0x1000');
eq('second row address', rows[1].address, '0x1010');
// The extent: exactly the declared bytes are marked, and the byte after it is
// not -- claiming one byte too many would attribute a neighbour's storage to
// this variable.
eq('extent marks byte 3', rows[0].cells[3].inValue, true);
eq('extent stops at byte 4', rows[0].cells[4].inValue, false);

// A window that starts BEFORE the value: nothing at a negative offset can be
// part of it, however large the extent is.
const back = mv.buildRows('0x1000', mv.makeWindow(-mv.BYTES_PER_ROW, 1), bytes, 64, new Set());
eq('nothing before the value is in the value', back[0].cells.some((c) => c.inValue), false);

// An unknown extent (size 0) marks nothing at all.
const noExtent = mv.buildRows('0x1000', mv.makeWindow(0, 1), bytes, 0, new Set());
eq('unknown extent highlights nothing', noExtent[0].cells.some((c) => c.inValue), false);

// The variable's own address is marked whether or not the extent is known --
// scrolled two pages down, it is the only thing that says where the value you
// came for actually is.
const unknownExtent = mv.buildRows('0x1000', mv.makeWindow(0, 1), bytes, 0, new Set());
eq('the first byte is marked as the origin', unknownExtent[0].cells[0].isOrigin, true);
eq('no other byte is', unknownExtent[0].cells[1].isOrigin, false);
eq('the row carrying it says so', unknownExtent[0].hasOrigin, true);

// Scrolled backward, the origin lands mid-pane and the rows before it are not
// the origin row.
const twoRows = mv.buildRows('0x1000', mv.makeWindow(-mv.BYTES_PER_ROW, 2), bytes, 0, new Set());
eq('the row before the value is not the origin row', twoRows[0].hasOrigin, false);
eq('the row the value starts in is', twoRows[1].hasOrigin, true);
eq('and it is its first byte', twoRows[1].cells[0].isOrigin, true);

// Changes are marked ACROSS THE WHOLE BLOCK, not only within the value: what
// else moved next to a variable is most of the reason to watch memory.
const before = [];
const after  = [];
for (let i = 0; i < mv.BYTES_PER_ROW; i++) { before.push(0); after.push(0); }
after[2]  = 0xFF;   // inside a 4-byte extent
after[11] = 0xFF;   // well outside it
const withChanges = mv.buildRows('0x1000', mv.makeWindow(0, 1), after, 4,
                                 mv.diffBytes(before, after));
eq('a change inside the value is marked', withChanges[0].cells[2].changed, true);
eq('a change OUTSIDE the value is marked too', withChanges[0].cells[11].changed, true);
eq('an unchanged byte is not', withChanges[0].cells[5].changed, false);
eq('the outside change is still not part of the value', withChanges[0].cells[11].inValue, false);

// A short read leaves the tail as unreadable rather than as zeroes: `??` in the
// pane, not a byte that looks like data.
const short = mv.buildRows('0x1000', mv.makeWindow(0, 1), [1, 2, 3], 0, new Set());
eq('missing bytes are null', short[0].cells[3].value, null);
eq('present bytes survive', short[0].cells[2].value, 3);

console.log(failures === 0 ? '\nall cases pass' : '\n' + failures + ' case(s) FAILED');
process.exit(failures === 0 ? 0 : 1);
