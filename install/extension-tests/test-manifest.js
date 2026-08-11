'use strict';

/*
 * Guards the extension manifest against the mistakes that are invisible until
 * VS Code loads it: a menu entry for a command that was never declared, a
 * when-clause naming a context key nothing sets, a `${command:...}` reference
 * to a command that does not exist, a syntax error in package.json.
 *
 *   node install\extension-tests\test-manifest.js
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');
const manifestPath = path.join(extensionDir, 'package.json');

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

const manifestText = fs.readFileSync(manifestPath, 'utf8');
const manifest = JSON.parse(manifestText);
const contributes = manifest.contributes || {};
const declaredCommands = (contributes.commands || []).map((command) => command.command);

// The extension host module is not loaded here (it needs a vscode stub); the
// context key is read out of its source instead, so the two cannot drift.
const extensionSource = fs.readFileSync(path.join(extensionDir, 'extension.js'), 'utf8');
const contextKey = /EXCEPTION_CONTEXT_KEY = '([^']+)'/.exec(extensionSource)[1];

console.log('manifest');

test('package.json parses and keeps its identity', () => {
  assert.strictEqual(manifest.main, './extension.js');
  assert.ok(manifest.version);
  assert.deepStrictEqual(manifest.activationEvents,
    ['onDebugResolve:delphi-win64', 'onDebugDynamicConfigurations:delphi-win64']);
});

test('every command used by the extension is declared', () => {
  ['delphi-win64.editExceptionRules', 'delphi-win64.createRuleForException', 'delphi-win64.pickProcess']
    .forEach((command) => assert.ok(declaredCommands.indexOf(command) !== -1, 'not declared: ' + command));
  const registered = extensionSource.match(/registerCommand\('([^']+)'/g) || [];
  registered.forEach((match) => {
    const command = /registerCommand\('([^']+)'/.exec(match)[1];
    assert.ok(declaredCommands.indexOf(command) !== -1, 'registered but not declared: ' + command);
  });
});

test('every menu entry points at a declared command', () => {
  const menus = contributes.menus || {};
  Object.keys(menus).forEach((menu) => {
    menus[menu].forEach((entry) => {
      assert.ok(declaredCommands.indexOf(entry.command) !== -1,
        menu + ' references undeclared command ' + entry.command);
    });
  });
});

/*
 * VS Code registers menu ids in a fixed table and SILENTLY IGNORES anything
 * else - no warning in the UI, no missing-contribution error, just a button
 * that never appears. `debug/toolbar` (lowercase b) was in this manifest for
 * weeks; the id is `debug/toolBar`, so the "create a rule" button had never
 * once been rendered while the README described where to find it.
 *
 * These ids are therefore matched EXACTLY, against the list VS Code's own
 * bundle registers (verified in workbench.desktop.main.js:
 * `{key:"debug/toolBar",id:P.DebugToolBar,...}`).
 */
const KNOWN_MENU_IDS = [
  'commandPalette', 'view/title', 'debug/toolBar',
  // Both verified the same way, in workbench.desktop.main.js, before the memory
  // view contributed to them: `debug/variables/context` (a Variables row) and
  // `debug/watch/context` (a Watch row). Group "inline" renders the entry as an
  // icon on the row rather than as a context-menu item.
  'debug/variables/context', 'debug/watch/context',
  // Verified the same way, for rows of the extension's OWN tree views (the
  // modules tree). `viewItem` matches whatever the provider set as contextValue.
  'view/item/context'
];

test('every menu id is one VS Code actually registers', () => {
  Object.keys(contributes.menus || {}).forEach((menu) => {
    assert.ok(KNOWN_MENU_IDS.indexOf(menu) !== -1,
      'unknown menu id "' + menu + '" - VS Code ignores it silently. Known: ' + KNOWN_MENU_IDS.join(', '));
  });
});

/*
 * The Breakpoints entry is the one that matters. VS Code registers the Call
 * Stack view with `when: debugUx == 'default'`, and drops it entirely in the
 * "simple" UX (no session AND no selected configuration or no enabled
 * debugger). Breakpoints is gated `breakpointsExist || debugUx == 'default' ||
 * hasDebugged` - a strict superset - so it is where the button survives. It is
 * also where it belongs: exception rules sit next to the exception filters.
 */
test('the rules editor is on the Breakpoints view title, and on Call Stack too', () => {
  const entries = (contributes.menus['view/title'] || [])
    .filter((item) => item.command === 'delphi-win64.editExceptionRules');
  const views = entries.map((entry) => entry.when);
  assert.ok(views.indexOf('view == workbench.debug.breakPointsView') !== -1,
    'the button must be on the Breakpoints view, which survives with no session');
  assert.ok(views.indexOf('view == workbench.debug.callStackView') !== -1,
    'and on the Call Stack view, where it sits during a session');
  entries.forEach((entry) => assert.match(entry.group || '', /^navigation/,
    'anything but a navigation group hides the command in the "..." overflow menu'));
});

/*
 * The raw stack sweep is reached from the Call Stack title bar, and where it
 * sits IS the feature: it is wanted at the moment a stack has just come up
 * short, so anywhere else is a button nobody finds in time. Unlike the rules
 * editor it is meaningless without a session, hence the debugType gate -- and
 * without that gate it would also appear during other extensions' debug
 * sessions, where the custom request it sends does not exist.
 */
test('the raw stack scan toggle is on the Call Stack view, gated on our debug type', () => {
  const entry = (contributes.menus['view/title'] || [])
    .find((item) => item.command === 'delphi-win64.toggleRawStackScan');
  assert.ok(entry, 'missing view/title entry for the raw stack scan toggle');
  assert.match(entry.when, /view == workbench\.debug\.callStackView/);
  assert.match(entry.when, /debugType == 'delphi-win64'/);
  assert.match(entry.group || '', /^navigation/,
    'anything but a navigation group hides the command in the "..." overflow menu');
});

test('the rule wizard is on the debug toolbar, gated on our type and on an exception stop', () => {
  const entry = (contributes.menus['debug/toolBar'] || [])
    .find((item) => item.command === 'delphi-win64.createRuleForException');
  assert.ok(entry, 'missing debug/toolBar entry (note the capital B - VS Code ignores any other spelling)');
  assert.match(entry.when, /debugType == 'delphi-win64'/);
  assert.ok(entry.when.indexOf(contextKey) !== -1,
    'when clause does not use the context key the extension sets (' + contextKey + ')');
});

test('the rule wizard is hidden from the palette unless stopped on an exception', () => {
  const entry = (contributes.menus.commandPalette || [])
    .find((item) => item.command === 'delphi-win64.createRuleForException');
  assert.ok(entry && entry.when === contextKey, 'palette entry must be gated on ' + contextKey);
});

test('the process picker is not offered as a palette command', () => {
  const entry = (contributes.menus.commandPalette || [])
    .find((item) => item.command === 'delphi-win64.pickProcess');
  assert.ok(entry && entry.when === 'false');
});

test('every ${command:...} reference resolves to a declared command', () => {
  const references = manifestText.match(/\$\{command:([^}]+)\}/g) || [];
  assert.ok(references.length > 0, 'the attach snippet should reference the process picker');
  references.forEach((reference) => {
    const command = /\$\{command:([^}]+)\}/.exec(reference)[1];
    assert.ok(declaredCommands.indexOf(command) !== -1, 'unknown command variable: ' + command);
  });
});

test('the attach snippet uses the process picker', () => {
  const debugger_ = contributes.debuggers[0];
  const snippet = (debugger_.configurationSnippets || [])
    .find((entry) => /attach/i.test(entry.label));
  assert.ok(snippet, 'missing attach snippet');
  assert.strictEqual(snippet.body.request, 'attach');
  assert.match(String(snippet.body.processId), /delphi-win64\.pickProcess/);
});

// With two instances of one application running, `processName` alone cannot
// identify a target: the filtered snippet is the discoverable answer, so it must
// carry both the name and the picker command.
test('a snippet offers the filtered attach form', () => {
  const debugger_ = contributes.debuggers[0];
  const snippet = (debugger_.configurationSnippets || [])
    .find((entry) => entry.body && entry.body.processName && entry.body.processId);
  assert.ok(snippet, 'missing a snippet combining processName with the picker');
  assert.strictEqual(snippet.body.request, 'attach');
  assert.match(String(snippet.body.processId), /delphi-win64\.pickProcess/);
});

// A byte-order mark makes VS Code reject the manifest outright: the extension
// then shows as "<name> ... is not valid JSON" and loses its display name, its
// icon and every contribution. It has happened once, written by a PowerShell
// `Set-Content -Encoding UTF8` under Windows PowerShell 5.1, where that encoding
// means "UTF-8 with BOM".
test('the manifest has no byte-order mark', () => {
  const bytes = fs.readFileSync(manifestPath);
  const hasBom = bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
  assert.ok(!hasBom, 'package.json starts with a UTF-8 BOM; VS Code will not parse it');
});

console.log('');
console.log(passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
