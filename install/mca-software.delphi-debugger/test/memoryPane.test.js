// What the memory pane DOES across a stop, as opposed to what its arithmetic
// computes. Run it with:
//
//   node test/memoryPane.test.js      (from the extension folder)
//
// The changed-byte highlight was reported broken three times and "fixed" twice
// against the wrong cause, because every test covered pure functions and none
// covered the sequence. The sequence is the defect: a single stop delivers TWO
// triggers -- the `stopped` event, and the `memory` event the adapter emits so
// open panes know their bytes are stale. Run as two comparisons, the first marks
// what changed and the second compares the new bytes against THEMSELVES, finds
// nothing, and wipes the marks within milliseconds.

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
  if (g === e) console.log('ok    ' + label);
  else { failures++; console.log('FAIL  ' + label + ' -> ' + g + '   expected ' + e); }
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

// A debuggee whose memory the test can change under the pane's feet.
function fakeSession(id, memory) {
  return {
    id: id,
    customRequest(command, args) {
      if (command === 'delphiMemoryExtent')
        return Promise.resolve({ address: '0x1000', name: 'X', type: 'Integer', size: 4 });
      if (command === 'evaluate')
        return Promise.resolve({ result: '0', memoryReference: '0x1000' });
      if (command === 'readMemory') {
        const start = args.offset | 0;
        const out = [];
        for (let i = 0; i < args.count; i++) {
          const at = start + i;
          out.push(at >= 0 && at < memory.length ? memory[at] : 0);
        }
        return Promise.resolve({ data: Buffer.from(out).toString('base64') });
      }
      if (command === 'writeMemory') return Promise.resolve({});
      return Promise.resolve({});
    }
  };
}

function lastRender(pane) {
  const renders = pane.panel.posted.filter((m) => m && m.type === 'render');
  return renders[renders.length - 1];
}

function changedOffsets(payload) {
  const out = [];
  for (const row of payload.rows)
    for (const cell of row.cells)
      if (cell.changed) out.push(cell.offset);
  return out;
}

async function run() {
  const memory = new Array(512).fill(0);
  const session = fakeSession('s1', memory);
  const context = { subscriptions: [] };

  const pane = new mv.__internals.MemoryPane(context, session, '0x1000',
                 { size: 4, name: 'X', type: 'Integer' }, 'X');
  mv.__internals.panels.set(mv.__internals.keyFor('s1', '0x1000'), pane);

  // The pane opens: bytes read, nothing to compare against yet.
  await pane.refresh({ markChanges: false });
  eq('opening marks nothing as changed', changedOffsets(lastRender(pane)), []);

  // The debuggee runs and writes one byte inside the value and one outside it.
  memory[2]  = 0xFF;
  memory[20] = 0xFF;

  // A stop, as the adapter actually reports it: `stopped` and then `memory`,
  // milliseconds apart. THE case that was broken.
  mv.refreshSession('s1');
  mv.refreshSession('s1');
  await delay(300);

  eq('a stop marks both changed bytes, once',
     changedOffsets(lastRender(pane)), [2, 20]);

  // The pane measures itself after drawing and asks for a different shape. That
  // redraw must not erase what the comparison just found.
  await pane.onMessage({ type: 'shape', rows: 6, columns: 16 });
  await delay(50);
  eq('the pane\'s own re-measure keeps the marks',
     changedOffsets(lastRender(pane)), [2, 20]);

  // Scrolling is LOOKING, not a new comparison. The marks are offsets: they go
  // off screen and must come back, because scrolling around a highlighted byte
  // is the first thing anyone does after seeing it.
  await pane.onMessage({ type: 'scroll', rows: 2 });
  await delay(50);
  eq('scrolled past them, nothing marked on screen',
     changedOffsets(lastRender(pane)), []);

  await pane.onMessage({ type: 'home' });
  await delay(50);
  eq('scrolling back brings the marks back',
     changedOffsets(lastRender(pane)), [2, 20]);

  // A stop at which NOTHING changed replaces them with nothing: no stale marks.
  mv.refreshSession('s1');
  await delay(300);
  eq('a stop with no change marks nothing', changedOffsets(lastRender(pane)), []);

  // And a further change is marked again, so the clearing above was not the
  // highlight quietly dying.
  memory[7] = 0x42;
  mv.refreshSession('s1');
  await delay(300);
  eq('the next real change is marked', changedOffsets(lastRender(pane)), [7]);

  // A byte written THROUGH the pane is a comparison point of its own: the user
  // changed memory, and the pane must show which byte that was.
  await pane.onMessage({ type: 'write', offset: 9, text: '5A' });
  memory[9] = 0x5A;                       // the fake debuggee's side of the write
  await pane.refresh({ markChanges: true });
  await delay(50);
  eq('a byte written through the pane is marked',
     changedOffsets(lastRender(pane)), [9]);

  // A region seen only while scrolling is still compared at the next stop: the
  // baseline is keyed by offset, not by "the window as it was".
  await pane.onMessage({ type: 'scroll', rows: 4 });   // records that region
  await delay(50);
  memory[70] = 0x77;
  await pane.onMessage({ type: 'home' });
  await delay(50);
  await pane.onMessage({ type: 'scroll', rows: 4 });   // back to it
  await delay(50);
  mv.refreshSession('s1');
  await delay(300);
  eq('a change where the pane had only scrolled is caught too',
     changedOffsets(lastRender(pane)).includes(70), true);

  console.log(failures === 0 ? '\nall cases pass' : '\n' + failures + ' case(s) FAILED');
  process.exit(failures === 0 ? 0 : 1);
}

run().catch((err) => {
  console.log('FAIL  unexpected error: ' + (err && err.stack ? err.stack : err));
  process.exit(1);
});
