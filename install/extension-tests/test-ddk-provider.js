'use strict';

/*
 * Tests for the two pieces of extension.js that sit between VS Code and the
 * pure modules: the configuration-provider step that completes a DDK
 * configuration (and then runs the attach picker on it), and the warning about
 * the old sideloaded copy of the extension. Both drive extension.js against a
 * stub `vscode` module, the way test-progress.js does.
 *
 *   node install\extension-tests\test-ddk-provider.js
 */

const assert = require('assert');
const path = require('path');
const Module = require('module');

const recorded = { errors: [], warnings: [], infos: [], executed: [] };
let installedExtensions = {};
let warningAnswer = undefined;
let infoAnswer = undefined;

function makeEvent() {
  const register = () => ({ dispose() {} });
  return register;
}

const vscodeStub = {
  StatusBarAlignment: { Left: 1 },
  EventEmitter: class {
    constructor() { this.listeners = []; }
    get event() { return (fn) => { this.listeners.push(fn); return { dispose() {} }; }; }
    fire(value) { this.listeners.forEach((fn) => fn(value)); }
  },
  window: {
    createStatusBarItem: () => ({ show() {}, hide() {}, dispose() {} }),
    showErrorMessage: (text) => { recorded.errors.push(text); return Promise.resolve(undefined); },
    showWarningMessage: (text) => { recorded.warnings.push(text); return Promise.resolve(warningAnswer); },
    showInformationMessage: (text) => { recorded.infos.push(text); return Promise.resolve(infoAnswer); },
    createTreeView: () => ({ message: '', dispose() {} }),
    registerTreeDataProvider() { return { dispose() {} }; }
  },
  extensions: { getExtension: (id) => installedExtensions[id] },
  commands: {
    registerCommand: () => ({ dispose() {} }),
    executeCommand: async (id, ...args) => {
      recorded.executed.push({ id: id, args: args });
      if (id === 'ddk.debug.getDebugTarget') return installedExtensions.__target(args[0]);
      return undefined;
    }
  },
  debug: {
    activeDebugSession: undefined,
    onDidReceiveDebugSessionCustomEvent: makeEvent(),
    onDidTerminateDebugSession: makeEvent(),
    onDidStartDebugSession: makeEvent(),
    onDidChangeActiveDebugSession: makeEvent(),
    registerDebugAdapterTrackerFactory: () => ({ dispose() {} }),
    registerDebugConfigurationProvider: () => ({ dispose() {} })
  },
  languages: { registerEvaluatableExpressionProvider: () => ({ dispose() {} }) },
  workspace: { workspaceFolders: [], getConfiguration: () => ({ get: (_k, d) => d }) },
  Uri: { file: (fsPath) => ({ fsPath: fsPath }) },
  env: { clipboard: { writeText: async () => {} } }
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  return originalLoad.call(this, request, parent, isMain);
};

const extensionDir = path.join(__dirname, '..', 'mca-software.delphi-debugger');
const extension = require(path.join(extensionDir, 'extension.js'));

let passed = 0;
let failed = 0;
const queue = [];
function test(name, fn) { queue.push({ name: name, fn: fn }); }
async function runQueue() {
  for (const entry of queue) {
    recorded.errors.length = 0; recorded.warnings.length = 0; recorded.infos.length = 0; recorded.executed.length = 0;
    try {
      await entry.fn();
      passed++;
      console.log('  ok   ' + entry.name);
    } catch (error) {
      failed++;
      console.log('  FAIL ' + entry.name);
      console.log('       ' + (error && error.message));
    }
  }
}

const TARGET = {
  project: 'App', project_file: 'C:/p/App.dproj', kind: 'program',
  executable: 'C:/p/Win64/Debug/App.exe', host_application: null, bitness: 64, platform: 'Win64',
  symbols: { map: 'C:/p/Win64/Debug/App.map', rsm: 'C:/p/Win64/Debug/App.rsm' },
  source_root: 'C:/p', source_search_paths: ['C:/p'], modules: [], args: [],
  warnings: ['App.rsm is older than App.exe; rebuild for up-to-date locals.']
};

function withDdkExtension(targetFn) {
  installedExtensions = {
    'Snowcaloid.delphi-devkit': { isActive: true },
    __target: targetFn
  };
}

test('-- provider: completing a DDK configuration', () => {});

test('a plain configuration passes through as the same object, DDK untouched', async () => {
  withDdkExtension(() => { throw new Error('must not be asked'); });
  const config = { type: 'delphi', request: 'launch', program: 'C:/x.exe' };
  assert.strictEqual(await extension.resolveDdkTarget(config), config);
});

test('a launch naming a project is filled in, and DDK\'s warnings are shown as non-blocking warnings', async () => {
  withDdkExtension(() => TARGET);
  const result = await extension.resolveDdkTarget({ type: 'delphi', request: 'launch', ddkProject: 'App' });
  assert.strictEqual(result.program, 'C:/p/Win64/Debug/App.exe');
  assert.strictEqual(result.delphiProjectFile, 'C:/p/App.dproj');
  assert.deepStrictEqual(recorded.executed.map((e) => e.id), ['ddk.debug.getDebugTarget']);
  assert.deepStrictEqual(recorded.executed[0].args, [{ project: 'App' }]);
  assert.deepStrictEqual(recorded.warnings, ['Delphi Debugger (DDK): App.rsm is older than App.exe; rebuild for up-to-date locals.']);
  assert.deepStrictEqual(recorded.errors, []);
});

test('an attach naming a project gets processName from DDK and then goes through the picker', async () => {
  withDdkExtension(() => TARGET);
  const picks = [];
  const result = await extension.resolveDdkTarget(
    { type: 'delphi', request: 'attach', ddkProject: 'App' },
    { pick: async (argument) => { picks.push(argument); return 4242; } });
  assert.deepStrictEqual(picks, [{ processName: 'App.exe' }], 'the picker is filtered to the executable');
  assert.strictEqual(result.processId, 4242);
  assert.strictEqual(result.program, 'C:/p/Win64/Debug/App.exe');
});

test('cancelling the picker aborts the session (undefined), as for any attach', async () => {
  withDdkExtension(() => TARGET);
  const result = await extension.resolveDdkTarget(
    { type: 'delphi', request: 'attach', ddkProject: 'App' }, { pick: async () => undefined });
  assert.strictEqual(result, undefined);
});

test('a DDK failure is shown as an error and the session is aborted', async () => {
  withDdkExtension(() => { throw new Error('Ambiguous project "App": [1] App, [2] App'); });
  const result = await extension.resolveDdkTarget({ type: 'delphi', request: 'launch', ddkProject: 'App' });
  assert.strictEqual(result, undefined);
  assert.deepStrictEqual(recorded.errors, ['Delphi Debugger: Ambiguous project "App": [1] App, [2] App']);
});

test('a target this debugger cannot run (bitness null) is refused with DDK\'s text', async () => {
  withDdkExtension(() => Object.assign({}, TARGET, { bitness: null, platform: 'OSX64', warnings: ['Platform "OSX64" is not supported by this debugger.'] }));
  const result = await extension.resolveDdkTarget({ type: 'delphi', request: 'launch', ddkProject: 'App' });
  assert.strictEqual(result, undefined);
  assert.match(recorded.errors[0], /OSX64.*not supported/);
});

test('the alias type resolves a DDK project the same way', async () => {
  withDdkExtension(() => TARGET);
  const result = await extension.resolveDdkTarget({ type: 'delphi-win64', request: 'launch', ddkProject: 'App' });
  assert.strictEqual(result.program, 'C:/p/Win64/Debug/App.exe');
  assert.strictEqual(result.type, 'delphi-win64');
});

test('-- the old sideloaded copy', () => {});

test('not installed: nothing is shown', async () => {
  installedExtensions = {};
  assert.strictEqual(await extension.warnAboutOldCopy(), false);
  assert.deepStrictEqual(recorded.warnings, []);
});

test('installed: one warning naming it, with a "Remove old version" button; dismissed -> nothing else', async () => {
  installedExtensions = { 'local.delphi-win64-debug': { id: 'local.delphi-win64-debug' } };
  warningAnswer = undefined;
  assert.strictEqual(await extension.warnAboutOldCopy(), true);
  assert.strictEqual(recorded.warnings.length, 1);
  assert.match(recorded.warnings[0], /older copy of this debugger \(local\.delphi-win64-debug\) is still installed; both contribute the same debug types/);
  assert.deepStrictEqual(recorded.executed, [], 'nothing is uninstalled without the click');
});

test('the button uninstalls the old id through VS Code and offers a reload', async () => {
  installedExtensions = { 'local.delphi-win64-debug': { id: 'local.delphi-win64-debug' } };
  warningAnswer = 'Remove old version';
  infoAnswer = 'Reload Window';
  await extension.warnAboutOldCopy();
  assert.deepStrictEqual(recorded.executed, [
    { id: 'workbench.extensions.uninstallExtension', args: ['local.delphi-win64-debug'] },
    { id: 'workbench.action.reloadWindow', args: [] }
  ]);
  assert.match(recorded.infos[0], /Removed local\.delphi-win64-debug/);
});

test('an editor without the extensions API: nothing shown, nothing thrown', async () => {
  const saved = vscodeStub.extensions;
  vscodeStub.extensions = undefined;
  try {
    assert.strictEqual(await extension.warnAboutOldCopy(), false);
  } finally {
    vscodeStub.extensions = saved;
  }
});

test('-- activation with both types', () => {});

test('activate registers adapter, tracker and provider for delphi AND delphi-win64', () => {
  const registered = { descriptors: [], trackers: [], providers: [] };
  vscodeStub.debug.registerDebugAdapterDescriptorFactory = (type) => { registered.descriptors.push(type); return { dispose() {} }; };
  vscodeStub.DebugAdapterExecutable = function () {};
  vscodeStub.debug.registerDebugAdapterTrackerFactory = (type) => { registered.trackers.push(type); return { dispose() {} }; };
  vscodeStub.debug.registerDebugConfigurationProvider = (type, provider) => {
    registered.providers.push({ type: type, provider: provider });
    return { dispose() {} };
  };
  installedExtensions = {};
  extension.activate({ subscriptions: [], extensionUri: { path: '/ext' } });
  assert.deepStrictEqual(registered.descriptors, ['delphi', 'delphi-win64']);
  assert.deepStrictEqual(registered.trackers, ['delphi', 'delphi-win64']);
  assert.deepStrictEqual(registered.providers.map((p) => p.type), ['delphi', 'delphi-win64']);
  registered.providers.forEach((p) => {
    assert.strictEqual(typeof p.provider.resolveDebugConfiguration, 'function');
    assert.strictEqual(typeof p.provider.resolveDebugConfigurationWithSubstitutedVariables, 'function',
      'the DDK step must run after variable substitution');
  });
});

runQueue().then(() => {
  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  Module._load = originalLoad;
  process.exit(failed === 0 ? 0 : 1);
});
