'use strict';

/*
 * The "Toggle Auto-Release of Frozen Threads" command: its wiring in the
 * manifest (declared, on the palette and on the Call Stack title bar next to
 * the raw-stack toggle, for both debug types) and the status-bar text, which
 * must state the behaviour CURRENTLY selected -- and, when OFF, name Pause as
 * the way out of a step that waits forever.
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

const COMMAND = 'delphi-win64.toggleStepIsolationRelease';

console.log('step isolation: the auto-release toggle');

test('the command is declared with a title that names what it toggles', () => {
  const entry = manifest.contributes.commands.find((c) => c.command === COMMAND);
  assert.ok(entry, 'command not declared');
  assert.strictEqual(entry.title, 'Toggle Auto-Release of Frozen Threads');
  assert.ok(fs.readFileSync(path.join(extensionDir, 'extension.js'), 'utf8').indexOf("registerCommand('" + COMMAND + "'") !== -1,
    'the extension does not register it');
});

test('it sits next to the raw-stack toggle: Call Stack title bar and palette, both debug types', () => {
  const view = (manifest.contributes.menus['view/title'] || []).find((e) => e.command === COMMAND);
  assert.ok(view, 'missing view/title entry');
  assert.match(view.when, /view == workbench\.debug\.callStackView/);
  assert.match(view.when, /debugType == 'delphi'/);
  assert.match(view.when, /debugType == 'delphi-win64'/);
  assert.match(view.group || '', /^navigation/);
  const raw = (manifest.contributes.menus['view/title'] || []).find((e) => e.command === 'delphi-win64.toggleRawStackScan');
  assert.strictEqual(view.when, raw.when, 'same placement rule as the raw-stack toggle');
  const palette = (manifest.contributes.menus.commandPalette || []).find((e) => e.command === COMMAND);
  assert.ok(palette, 'missing palette entry');
  assert.match(palette.when, /debugType == 'delphi'/);
  assert.match(palette.when, /debugType == 'delphi-win64'/);
});

test('ON text states the release rule with the threshold that applies', () => {
  const text = extension.stepIsolationReleaseText({ enabled: true, releaseMs: 3000, frozenPerStep: true });
  assert.match(text, /^Auto-release of frozen threads: ON/);
  assert.match(text, /released after 3\.0 s/);
  assert.match(text, /at once when the lock's owner is known/);
  assert.match(extension.stepIsolationReleaseText({ enabled: true, releaseMs: 750, frozenPerStep: true }), /0\.8 s/);
});

test('OFF text says threads stay frozen for the whole step and names Pause as the way out', () => {
  const text = extension.stepIsolationReleaseText({ enabled: false, releaseMs: 3000, frozenPerStep: true });
  assert.match(text, /^Auto-release of frozen threads: OFF/);
  assert.match(text, /stay frozen for the whole step/);
  assert.match(text, /use Pause to break in/);
});

test('under stepIsolation "none" the text says nothing is ever frozen, whatever the switch', () => {
  [true, false].forEach((enabled) => {
    const text = extension.stepIsolationReleaseText({ enabled: enabled, releaseMs: 3000, frozenPerStep: false });
    assert.match(text, /never freezes other threads/);
  });
});

test('the adapter\'s own sentence wins when it sends one', () => {
  assert.strictEqual(extension.stepIsolationReleaseText({ enabled: true, text: 'Auto-release of frozen threads: ON - custom' }),
    'Auto-release of frozen threads: ON - custom');
});

Module._load = originalLoad;
console.log('');
console.log(passed + ' passed, ' + failed + ' failed');
process.exit(failed === 0 ? 0 : 1);
