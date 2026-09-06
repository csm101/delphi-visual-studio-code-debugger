'use strict';

/*
 * The auto-release switch as the Call Stack title bar shows it. The button
 * must SAY what is selected: VS Code gives a command one icon and one title,
 * so there is one command per state -- ON (unlock icon), OFF (lock icon),
 * "none" (never frozen) -- and the manifest picks the one to show by the
 * context key `delphiStepAutoRelease`, which the extension publishes from the
 * adapter's `delphiStepIsolation` event (session start, every change) and from
 * the reply to a toggle. Also the status-bar sentence for each state.
 *
 *   node install\extension-tests\test-step-isolation.js
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const Module = require('module');

const extensionDir = path.join(__dirname, '..', 'mca-software.delphi-debugger');
const manifest = JSON.parse(fs.readFileSync(path.join(extensionDir, 'package.json'), 'utf8'));
const vscodeStub = require(path.join(extensionDir, 'test', 'vscode-stub.js'));

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  return originalLoad.call(this, request, parent, isMain);
};
const extension = require(path.join(extensionDir, 'extension.js'));

let passed = 0;
let failed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log('  ok   ' + name);
  } catch (error) {
    failed++;
    console.log('  FAIL ' + name);
    console.log('       ' + (error && error.message));
  }
}

const ON = 'delphi-win64.toggleStepIsolationRelease';
const OFF = 'delphi-win64.enableStepIsolationRelease';
const NONE = 'delphi-win64.stepIsolationNoneInfo';
const KEY = extension.STEP_ISOLATION_CONTEXT_KEY;
const commands = manifest.contributes.commands;
const viewTitle = manifest.contributes.menus['view/title'] || [];
const palette = manifest.contributes.menus.commandPalette || [];
const source = fs.readFileSync(path.join(extensionDir, 'extension.js'), 'utf8');

console.log('step isolation: the auto-release button');

test('one command per state, each declared, registered, with its own icon and a hint that states the state', () => {
  const on = commands.find((c) => c.command === ON);
  const off = commands.find((c) => c.command === OFF);
  const none = commands.find((c) => c.command === NONE);
  assert.ok(on && off && none, 'a state command is not declared');
  [ON, OFF, NONE].forEach((id) =>
    assert.ok(source.indexOf("registerCommand('" + id + "'") !== -1, 'not registered: ' + id));
  assert.notStrictEqual(on.icon, off.icon, 'ON and OFF must look different');
  assert.notStrictEqual(none.icon, on.icon);
  assert.match(on.title, /Auto-Release of Frozen Threads: ON/);
  assert.match(on.title, /click to keep every other thread frozen/i, 'the hint says what the click does');
  assert.match(off.title, /Auto-Release of Frozen Threads: OFF/);
  assert.match(off.title, /stay frozen for the whole step/);
  assert.match(off.title, /Pause/, 'the OFF hint names Pause');
  assert.match(none.title, /never freezes/);
});

test('the Call Stack title bar shows exactly the command of the current state, for both debug types', () => {
  const entries = viewTitle.filter((e) => [ON, OFF, NONE].indexOf(e.command) !== -1);
  assert.strictEqual(entries.length, 3);
  const expected = { [ON]: "'on'", [OFF]: "'off'", [NONE]: "'none'" };
  entries.forEach((e) => {
    assert.match(e.when, /view == workbench\.debug\.callStackView/);
    assert.match(e.when, /debugType == 'delphi'/);
    assert.match(e.when, /debugType == 'delphi-win64'/);
    assert.ok(e.when.indexOf(KEY + ' == ' + expected[e.command]) !== -1,
      e.command + ' must be gated on ' + KEY + ' == ' + expected[e.command] + ': ' + e.when);
    assert.match(e.group || '', /^navigation/);
  });
  // Same slot as each other, next to the raw-stack toggle.
  const groups = new Set(entries.map((e) => e.group));
  assert.strictEqual(groups.size, 1, 'the three states share one slot');
  const raw = viewTitle.find((e) => e.command === 'delphi-win64.toggleRawStackScan');
  assert.ok(raw && raw.group !== entries[0].group, 'the raw-stack toggle keeps its own slot');
});

test('the palette offers the switch for the current state only; the "none" notice is not a palette command', () => {
  const on = palette.find((e) => e.command === ON);
  const off = palette.find((e) => e.command === OFF);
  const none = palette.find((e) => e.command === NONE);
  assert.ok(on && on.when.indexOf(KEY + " == 'on'") !== -1);
  assert.ok(off && off.when.indexOf(KEY + " == 'off'") !== -1);
  assert.ok(none && none.when === 'false');
});

test('the context value comes from the adapter\'s state: on / off / none', () => {
  assert.strictEqual(extension.stepIsolationContextValue({ enabled: true, frozenPerStep: true }), 'on');
  assert.strictEqual(extension.stepIsolationContextValue({ enabled: false, frozenPerStep: true }), 'off');
  assert.strictEqual(extension.stepIsolationContextValue({ enabled: true, frozenPerStep: false }), 'none');
  assert.strictEqual(extension.stepIsolationContextValue(undefined), 'off');
});

test('the tracker publishes the active session\'s state and clears it when the session ends', () => {
  const published = [];
  const tracker = new extension.StepIsolationTracker((v) => published.push(v));
  tracker.handleEvent('s1', { enabled: true, frozenPerStep: true });
  assert.deepStrictEqual(published, ['on'], 'the first session becomes the active one');
  tracker.handleEvent('s1', { enabled: false, frozenPerStep: true });
  assert.deepStrictEqual(published, ['on', 'off']);
  tracker.handleEvent('s1', { enabled: false, frozenPerStep: true });
  assert.deepStrictEqual(published, ['on', 'off'], 'an unchanged state is not republished');
  // A second session with its own state: the active one decides.
  tracker.handleEvent('s2', { enabled: true, frozenPerStep: false });
  assert.strictEqual(published[published.length - 1], 'off', 's1 is still active');
  tracker.setActive('s2');
  assert.strictEqual(published[published.length - 1], 'none');
  tracker.endSession('s2');
  assert.strictEqual(published[published.length - 1], 'off', 'the remaining session shows again');
  tracker.endSession('s1');
  assert.strictEqual(published[published.length - 1], '', 'no session: no button');
});

test('the status-bar sentence: ON names the threshold, OFF names Pause, none says never frozen', () => {
  const on = extension.stepIsolationReleaseText({ enabled: true, releaseMs: 3000, frozenPerStep: true });
  assert.match(on, /^Auto-release of frozen threads: ON/);
  assert.match(on, /released after 3\.0 s/);
  assert.match(on, /at once when the lock's owner is known/);
  const off = extension.stepIsolationReleaseText({ enabled: false, releaseMs: 3000, frozenPerStep: true });
  assert.match(off, /^Auto-release of frozen threads: OFF/);
  assert.match(off, /use Pause to break in/);
  assert.match(extension.stepIsolationReleaseText({ enabled: true, frozenPerStep: false }), /never freezes other threads/);
  assert.strictEqual(extension.stepIsolationReleaseText({ enabled: true, text: 'Auto-release of frozen threads: ON - custom' }),
    'Auto-release of frozen threads: ON - custom', 'the adapter\'s own sentence wins');
});

Module._load = originalLoad;
console.log('');
console.log(passed + ' passed, ' + failed + ' failed');
process.exit(failed === 0 ? 0 : 1);
