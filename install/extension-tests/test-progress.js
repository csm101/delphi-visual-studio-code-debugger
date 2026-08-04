'use strict';

/*
 * Tests the status-bar rendering of the adapter's custom `delphiProgress`
 * event, by loading extension.js against a stub `vscode` module.
 *
 *   node install\extension-tests\test-progress.js
 *
 * Contract under test:
 *   event "delphiProgress", body { id, state: start|update|end, text }
 */

const assert = require('assert');
const path = require('path');
const Module = require('module');

// ------------------------------------------------------------ vscode stub --

function makeEvent() {
  const handlers = [];
  const register = (handler) => {
    handlers.push(handler);
    return { dispose() {} };
  };
  register.fire = (...args) => handlers.forEach((handler) => handler(...args));
  return register;
}

const statusBarItems = [];
const registeredCommands = {};
const configurationProviders = [];

const vscodeStub = {
  StatusBarAlignment: { Left: 1, Right: 2 },
  ViewColumn: { Active: -1, Beside: -2 },
  window: {
    createStatusBarItem() {
      const item = {
        text: '',
        tooltip: undefined,
        name: '',
        visible: false,
        show() { this.visible = true; },
        hide() { this.visible = false; },
        dispose() { this.disposed = true; }
      };
      statusBarItems.push(item);
      return item;
    },
    showQuickPick: async () => undefined,
    showErrorMessage() {},
    showWarningMessage() {},
    showInformationMessage() {},
    showTextDocument: async () => ({ revealRange() {} }),
    createWebviewPanel() { throw new Error('not used by these tests'); }
  },
  debug: {
    activeDebugSession: undefined,
    onDidReceiveDebugSessionCustomEvent: makeEvent(),
    onDidTerminateDebugSession: makeEvent(),
    registerDebugAdapterTrackerFactory() { return { dispose() {} }; },
    registerDebugConfigurationProvider(type, provider) {
      configurationProviders.push({ type: type, provider: provider });
      return { dispose() {} };
    }
  },
  commands: {
    registerCommand(id, handler) {
      registeredCommands[id] = handler;
      return { dispose() {} };
    },
    executeCommand: async () => undefined
  },
  // Present so activate() takes its REAL path. The extension guards this call
  // (an editor without the API must still get a working debug type), and a
  // double that omitted it would make every test here exercise the guard
  // instead of the code.
  languages: { registerEvaluatableExpressionProvider() { return { dispose() {} }; } },
  workspace: { workspaceFolders: [], isTrusted: true, openTextDocument: async () => { throw new Error('none'); } },
  Uri: { joinPath: (...parts) => ({ path: parts.join('/') }), file: (fsPath) => ({ path: fsPath, fsPath: fsPath }) },
  Range: function Range() {},
  WorkspaceEdit: function WorkspaceEdit() {},
  env: { clipboard: { writeText: async () => {} } }
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  return originalLoad.call(this, request, parent, isMain);
};

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');
const extension = require(path.join(extensionDir, 'extension.js'));

// ------------------------------------------------------------------ tests --

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

function newBar() {
  return new extension.ProgressStatusBar();
}

const SESSION = { id: 's1', type: 'delphi-win64' };
const OTHER_SESSION = { id: 's2', type: 'delphi-win64' };

console.log('status-bar progress');

test('start shows a spinner with the text, end hides it', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'Loading symbols' });
  assert.strictEqual(bar.item.visible, true);
  assert.match(bar.item.text, /^\$\(sync~spin\) Loading symbols$/);
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'end' });
  assert.strictEqual(bar.item.visible, false);
});

test('update replaces the text of the same id', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'Loading symbols' });
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'update', text: 'Loading symbols (60%)' });
  assert.match(bar.item.text, /Loading symbols \(60%\)$/);
  assert.strictEqual(bar.activeOperations().length, 1);
});

test('concurrent operations show the newest plus a counter', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'Loading symbols' });
  bar.handleCustomEvent(SESSION, { id: 'b', state: 'start', text: 'Evaluating' });
  assert.match(bar.item.text, /Evaluating \(\+1\)$/);
  assert.match(String(bar.item.tooltip), /Loading symbols[\s\S]*Evaluating/);
  bar.handleCustomEvent(SESSION, { id: 'b', state: 'end' });
  assert.match(bar.item.text, /Loading symbols$/);
  assert.strictEqual(bar.item.visible, true);
});

test('an update for an unknown id is treated as a start', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'ghost', state: 'update', text: 'Still working' });
  assert.strictEqual(bar.item.visible, true);
  assert.match(bar.item.text, /Still working$/);
});

test('an end for an unknown id is harmless', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'nope', state: 'end' });
  assert.strictEqual(bar.item.visible, false);
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'x' });
  bar.handleCustomEvent(SESSION, { id: 'nope', state: 'end' });
  assert.strictEqual(bar.item.visible, true);
});

test('missing or blank text falls back to a placeholder', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start' });
  assert.match(bar.item.text, /Working/);
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'update', text: '   ' });
  assert.match(bar.item.text, /Working/);
});

test('malformed bodies are ignored', () => {
  const bar = newBar();
  [undefined, null, 'text', {}, { id: 'a' }, { state: 'start' }, { id: 1, state: 'start' },
    { id: 'a', state: 'bogus' }].forEach((body) => bar.handleCustomEvent(SESSION, body));
  assert.strictEqual(bar.item.visible, false);
});

test('long text is truncated', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'x'.repeat(200) });
  assert.ok(bar.item.text.length < 80, 'status bar text too long: ' + bar.item.text.length);
});

test('operations from different sessions are tracked separately', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'Session one' });
  bar.handleCustomEvent(OTHER_SESSION, { id: 'a', state: 'start', text: 'Session two' });
  assert.strictEqual(bar.activeOperations().length, 2);
  bar.clearSession(OTHER_SESSION.id);
  assert.strictEqual(bar.activeOperations().length, 1);
  assert.match(bar.item.text, /Session one$/);
});

test('a session that dies without "end" does not leave a stuck spinner', () => {
  const bar = newBar();
  bar.handleCustomEvent(SESSION, { id: 'a', state: 'start', text: 'Loading symbols' });
  bar.handleCustomEvent(SESSION, { id: 'b', state: 'start', text: 'Evaluating' });
  bar.clearSession(SESSION.id);
  assert.strictEqual(bar.item.visible, false);
  assert.strictEqual(bar.activeOperations().length, 0);
});

console.log('activation wiring');

test('activate subscribes to the custom event and terminate, and registers the command', () => {
  statusBarItems.length = 0;
  const context = { subscriptions: [], extensionUri: { path: '/ext' } };
  extension.activate(context);
  assert.ok(context.subscriptions.length >= 4);
  assert.ok(registeredCommands['delphi-win64.editExceptionRules']);
  assert.ok(registeredCommands['delphi-win64.createRuleForException']);
  assert.ok(registeredCommands['delphi-win64.pickProcess']);

  const item = statusBarItems[statusBarItems.length - 1];
  vscodeStub.debug.onDidReceiveDebugSessionCustomEvent.fire({
    event: 'delphiProgress', session: SESSION, body: { id: 'a', state: 'start', text: 'Stepping' }
  });
  assert.strictEqual(item.visible, true);

  // Events from other debug types or other event names must be ignored.
  vscodeStub.debug.onDidReceiveDebugSessionCustomEvent.fire({
    event: 'delphiProgress', session: { id: 'x', type: 'node' }, body: { id: 'z', state: 'start', text: 'Nope' }
  });
  vscodeStub.debug.onDidReceiveDebugSessionCustomEvent.fire({
    event: 'somethingElse', session: SESSION, body: { id: 'q', state: 'start', text: 'Nope' }
  });
  assert.match(item.text, /Stepping$/);

  vscodeStub.debug.onDidTerminateDebugSession.fire(SESSION);
  assert.strictEqual(item.visible, false);
});

// ------------------------------------------- attach: resolving the target --

/*
 * An attach configuration that names only a `processName` is the shape every
 * entry the Delphi IDE plugin generates has, and the shape of every attach
 * entry written before the picker existed. Nothing in VS Code invokes a command
 * for it, so without the configuration provider the picker is unreachable from
 * those configurations: with two instances of the application running, the user
 * is never asked and the adapter can only refuse. Observed, not theorised.
 */
async function asyncTest(name, fn) {
  try {
    await fn();
    passed++;
    console.log('  ok   ' + name);
  } catch (error) {
    failed++;
    console.log('  FAIL ' + name);
    console.log('       ' + (error && error.message));
  }
}

async function runAttachTests() {
  console.log('');
  console.log('attach target resolution');

  const pickerCalls = [];
  const pickReturning = (value) => (argument) => {
    pickerCalls.push(argument);
    return Promise.resolve(value);
  };

  await asyncTest('processName without processId runs the picker, filtered by that name', async () => {
    pickerCalls.length = 0;
    const resolved = await extension.resolveAttachTarget(
      { type: 'delphi-win64', request: 'attach', processName: 'SampleApp.exe' }, pickReturning('640'));
    assert.strictEqual(resolved.processId, 640);
    assert.strictEqual(resolved.processName, 'SampleApp.exe');
    assert.deepStrictEqual(pickerCalls, [{ processName: 'SampleApp.exe' }]);
  });

  await asyncTest('cancelling the picker aborts the session', async () => {
    const resolved = await extension.resolveAttachTarget(
      { request: 'attach', processName: 'SampleApp.exe' }, pickReturning(undefined));
    assert.strictEqual(resolved, undefined);
  });

  await asyncTest('an explicit processId is left alone', async () => {
    pickerCalls.length = 0;
    const config = { request: 'attach', processName: 'SampleApp.exe', processId: 1234 };
    assert.strictEqual(await extension.resolveAttachTarget(config, pickReturning('99')), config);
    assert.strictEqual(pickerCalls.length, 0);
  });

  // This provider runs BEFORE variable substitution: a `${command:...}` value is
  // still literal text here. Prompting for it would ask the user twice.
  await asyncTest('a ${command:...} processId is left for VS Code to substitute', async () => {
    pickerCalls.length = 0;
    const config = { request: 'attach', processId: '${command:delphi-win64.pickProcess}' };
    assert.strictEqual(await extension.resolveAttachTarget(config, pickReturning('99')), config);
    assert.strictEqual(pickerCalls.length, 0);
  });

  await asyncTest('launch configurations are untouched', async () => {
    pickerCalls.length = 0;
    const config = { request: 'launch', program: 'C:/app/SampleApp.exe' };
    assert.strictEqual(await extension.resolveAttachTarget(config, pickReturning('99')), config);
    assert.strictEqual(pickerCalls.length, 0);
  });

  // Nothing to filter by and nothing to ask about: the adapter's own error
  // ("missing processId") is clearer than a picker listing every process.
  await asyncTest('attach with neither name nor id is passed through unchanged', async () => {
    pickerCalls.length = 0;
    const config = { request: 'attach' };
    assert.strictEqual(await extension.resolveAttachTarget(config, pickReturning('99')), config);
    assert.strictEqual(pickerCalls.length, 0);
  });

  await asyncTest('zero and blank count as no processId', async () => {
    ['', '  ', '0', 0, undefined, null].forEach((value) =>
      assert.strictEqual(extension.hasExplicitProcessId(value), false, 'should be unset: ' + JSON.stringify(value)));
    [1, '1', ' 4321 ', '${input:pickIt}'].forEach((value) =>
      assert.strictEqual(extension.hasExplicitProcessId(value), true, 'should be set: ' + JSON.stringify(value)));
  });

  await asyncTest('activate registers the provider for our debug type', async () => {
    const entry = configurationProviders.find((item) => item.type === 'delphi-win64');
    assert.ok(entry, 'no configuration provider registered');
    assert.strictEqual(typeof entry.provider.resolveDebugConfiguration, 'function');
  });

  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  Module._load = originalLoad;
  process.exit(failed ? 1 : 0);
}

runAttachTests();
