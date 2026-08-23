'use strict';

/*
 * Tests for `delphi-win64.pickProcess`.
 *
 * The list comes from the debug adapter's one-shot `--list-processes` mode
 * (JSON on stdout), not from `tasklist` - see processPicker.js for why. So what
 * is exercised here is: locating the adapter through the extension manifest,
 * parsing its JSON, the architecture / canDebug handling, the name filter and
 * where it comes from, and the two outcomes of the QuickPick - a pid, or
 * `undefined` so VS Code aborts the session instead of attaching to a garbage
 * pid.
 *
 *   node install\extension-tests\test-process-picker.js
 */

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');

// ------------------------------------------------- vscode / exec stubbing --

const recorded = { quickPicks: [], errors: [] };
let quickPickAnswer = () => undefined;
let adapterResult = { error: null, stdout: '' };
let adapterCalls = [];

const vscodeStub = {
  window: {
    showQuickPick: async (items, options) => {
      recorded.quickPicks.push({ items: items, options: options });
      return quickPickAnswer(items, options);
    },
    showErrorMessage: (message) => recorded.errors.push(message)
  },
  workspace: { workspaceFolders: [] }
};

const childProcessStub = {
  execFile(file, args, options, callback) {
    adapterCalls.push({ file: file, args: args, options: options });
    setImmediate(() => callback(adapterResult.error, adapterResult.stdout, ''));
  }
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  if (request === 'child_process') return childProcessStub;
  return originalLoad.call(this, request, parent, isMain);
};

const picker = require(path.join(extensionDir, 'processPicker.js'));

// A stand-in extension folder: a manifest that declares the adapter, and a file
// where it says the adapter is. Nothing is executed - execFile is stubbed - but
// the picker refuses to run an adapter that is not on disk, which is the point.
const fakeExtensionDir = fs.mkdtempSync(path.join(os.tmpdir(), 'delphi-picker-test-'));
const fakeAdapterPath = path.join(fakeExtensionDir, 'VisualStudioCodeDelphiDebugger.exe');

function writeFakeManifest(program) {
  fs.writeFileSync(path.join(fakeExtensionDir, 'package.json'), JSON.stringify({
    name: 'delphi-win64-debug',
    contributes: { debuggers: [{ type: 'delphi-win64', program: program }] }
  }), 'utf8');
}
writeFakeManifest('./VisualStudioCodeDelphiDebugger.exe');
fs.writeFileSync(fakeAdapterPath, 'not a real executable', 'utf8');

const pickerOptions = { extensionDir: fakeExtensionDir };

// ------------------------------------------------------------------ tests --

let passed = 0;
let failed = 0;

function test(name, fn) {
  const finish = (error) => {
    if (error) {
      failed++;
      console.log('  FAIL ' + name);
      console.log('       ' + (error && (error.stack ? error.stack.split('\n').slice(0, 2).join(' | ') : error)));
    } else {
      passed++;
      console.log('  ok   ' + name);
    }
  };
  try {
    const result = fn();
    if (result && typeof result.then === 'function') return result.then(() => finish(), finish);
    finish();
  } catch (error) {
    finish(error);
  }
  return Promise.resolve();
}

function processEntry(overrides) {
  return Object.assign({
    pid: 1000, parentPid: 1, sessionId: 1, name: 'Sample.exe',
    path: 'C:\\Apps\\Sample.exe', commandLine: 'C:\\Apps\\Sample.exe',
    arch: 'x64', canDebug: true, reason: ''
  }, overrides);
}

/* One line of JSON, exactly as the adapter writes it. */
function adapterOutput(entries) {
  return JSON.stringify(entries) + '\n';
}

const TWO_INSTANCES = [
  processEntry({ pid: 9012, name: 'SampleApp.exe', path: 'C:\\Apps\\SampleApp.exe',
    commandLine: 'C:\\Apps\\SampleApp.exe /project=Invoices',
    windowTitle: 'SampleApp - Invoices' }),
  processEntry({ pid: 7788, name: 'SampleApp.exe', path: 'C:\\Apps\\SampleApp.exe',
    commandLine: 'C:\\Apps\\SampleApp.exe /project=Customers',
    windowTitle: 'SampleApp - Customers' }),
  processEntry({ pid: 6001, name: 'SampleAppHelper.exe', path: 'C:\\Apps\\SampleAppHelper.exe',
    commandLine: 'C:\\Apps\\SampleAppHelper.exe' }),
  processEntry({ pid: 4321, name: 'Notepad.exe', path: 'C:\\Windows\\Notepad.exe',
    commandLine: 'notepad.exe readme.txt' }),
  processEntry({ pid: 1120, name: 'svchost.exe', commandLine: 'svchost.exe -k netsvcs' }),
  processEntry({ pid: 2500, name: 'LegacyApp.exe', arch: 'x86', canDebug: false,
    reason: 'target is x86; this debugger is x64 and cannot debug a different architecture' }),
  processEntry({ pid: 4, name: 'System', arch: 'unknown', canDebug: false,
    reason: 'cannot determine target architecture' }),
  processEntry({ pid: 0, name: '[System Process]', arch: 'unknown', canDebug: false,
    reason: 'cannot determine target architecture' })
];

function resetStubs() {
  recorded.quickPicks.length = 0;
  recorded.errors.length = 0;
  adapterCalls = [];
  adapterResult = { error: null, stdout: adapterOutput(TWO_INSTANCES) };
  quickPickAnswer = () => undefined;
}

async function main() {
  console.log('locating the adapter');

  await test('the adapter comes from contributes.debuggers[0].program', () => {
    writeFakeManifest('./VisualStudioCodeDelphiDebugger.exe');
    assert.strictEqual(picker.adapterExecutablePath(fakeExtensionDir), fakeAdapterPath);
  });

  await test('a dev-mode absolute program path is used as it stands', () => {
    // scripts/install-dev.ps1 rewrites `program` to the build output, with forward
    // slashes; the picker must follow the manifest rather than assume a layout.
    writeFakeManifest(fakeAdapterPath.replace(/\\/g, '/'));
    assert.strictEqual(path.resolve(picker.adapterExecutablePath(fakeExtensionDir)), fakeAdapterPath);
    writeFakeManifest('./VisualStudioCodeDelphiDebugger.exe');
  });

  await test('a missing adapter is reported by path, not as a mystery', () => {
    writeFakeManifest('./NotBuiltYet.exe');
    assert.throws(() => picker.adapterExecutablePath(fakeExtensionDir), /NotBuiltYet\.exe/);
    assert.throws(() => picker.adapterExecutablePath(fakeExtensionDir), /build_dap/);
    writeFakeManifest('./VisualStudioCodeDelphiDebugger.exe');
  });

  await test('an unreadable manifest is reported by path', () => {
    assert.throws(() => picker.adapterExecutablePath(path.join(fakeExtensionDir, 'nowhere')),
      /cannot read the extension manifest/);
  });

  await test('the shipped manifest really does declare the adapter', () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(extensionDir, 'package.json'), 'utf8'));
    assert.match(String(manifest.contributes.debuggers[0].program), /VisualStudioCodeDelphiDebugger\.exe$/);
  });

  console.log('the JSON listing');

  await test('the adapter line is parsed into processes', () => {
    const processes = picker.parseProcessListJson(adapterOutput(TWO_INSTANCES));
    // The idle process reports pid 0, which is not something to attach to.
    assert.strictEqual(processes.length, TWO_INSTANCES.length - 1);
    const sampleApp = processes.find((entry) => entry.pid === 7788);
    assert.strictEqual(sampleApp.name, 'SampleApp.exe');
    assert.strictEqual(sampleApp.commandLine, 'C:\\Apps\\SampleApp.exe /project=Customers');
    assert.strictEqual(sampleApp.arch, 'x64');
    assert.strictEqual(sampleApp.canDebug, true);
    assert.strictEqual(sampleApp.sessionId, 1);
  });

  await test('architecture and the reason it cannot be debugged survive', () => {
    const legacy = picker.parseProcessListJson(adapterOutput(TWO_INSTANCES))
      .find((entry) => entry.pid === 2500);
    assert.strictEqual(legacy.arch, 'x86');
    assert.strictEqual(legacy.canDebug, false);
    assert.match(legacy.reason, /cannot debug a different architecture/);
  });

  await test('the JSON line is found even with other output around it', () => {
    const noisy = 'warning: something\r\n' + adapterOutput(TWO_INSTANCES) + 'trailing\r\n';
    assert.strictEqual(picker.parseProcessListJson(noisy).length, TWO_INSTANCES.length - 1);
  });

  await test('an empty list is a valid answer, not an error', () => {
    assert.deepStrictEqual(picker.parseProcessListJson('[]\n'), []);
  });

  await test('output that is not a process list is rejected, never guessed at', () => {
    assert.throws(() => picker.parseProcessListJson(''), /did not return a process list/);
    assert.throws(() => picker.parseProcessListJson('Fatal: something broke\n'), /did not return a process list/);
    assert.throws(() => picker.parseProcessListJson('[not json]\n'), /not valid JSON/);
    assert.throws(() => picker.parseProcessListJson('{"pid":1}\n'), /did not return a process list/);
  });

  await test('unusable entries are dropped and missing fields default safely', () => {
    const processes = picker.parseProcessListJson(JSON.stringify([
      { pid: 'nonsense', name: 'Bad.exe' },
      { pid: 0, name: 'Zero.exe' },
      null,
      { pid: 77 }
    ]));
    assert.strictEqual(processes.length, 1);
    assert.deepStrictEqual(processes[0], {
      pid: 77, parentPid: 0, sessionId: 0, name: '', path: '', commandLine: '',
      windowTitle: '', startTime: '', arch: 'unknown', canDebug: false, reason: ''
    });
  });

  await test('canDebug is believed only when it is literally true', () => {
    const processes = picker.parseProcessListJson(JSON.stringify([
      { pid: 10, canDebug: 'true' }, { pid: 11, canDebug: 1 }, { pid: 12, canDebug: true }
    ]));
    assert.deepStrictEqual(processes.map((entry) => entry.canDebug), [false, false, true]);
  });

  console.log('ranking');

  await test('pseudo-processes that cannot be attached to are dropped', () => {
    const names = picker.rankProcesses(picker.parseProcessListJson(adapterOutput(TWO_INSTANCES)), {})
      .map((entry) => entry.name);
    assert.ok(names.indexOf('System') === -1);
    assert.ok(names.indexOf('[System Process]') === -1);
    assert.ok(names.indexOf('svchost.exe') !== -1, 'ordinary processes must stay in the list');
  });

  await test('a process matching the workspace name comes first', () => {
    const ranked = picker.rankProcesses(picker.parseProcessListJson(adapterOutput(TWO_INSTANCES)),
      { hints: ['SampleApp'] });
    assert.strictEqual(ranked[0].name, 'SampleApp.exe');
  });

  await test('what can be debugged outranks what cannot, and infrastructure sinks', () => {
    const ranked = picker.rankProcesses(picker.parseProcessListJson(adapterOutput(TWO_INSTANCES)), {});
    const names = ranked.map((entry) => entry.name);
    assert.ok(names.indexOf('Notepad.exe') < names.indexOf('LegacyApp.exe'),
      'a 32-bit process is still listed, but below the ones that can be attached to');
    assert.ok(names.indexOf('Notepad.exe') < names.indexOf('svchost.exe'));
  });

  await test('the extension host itself is never offered', () => {
    const ranked = picker.rankProcesses(picker.parseProcessListJson(adapterOutput(TWO_INSTANCES)),
      { ownPid: 4321 });
    assert.ok(ranked.every((entry) => entry.pid !== 4321));
  });

  await test('the order is deterministic for equal scores', () => {
    const input = [
      processEntry({ pid: 20, name: 'b.exe' }),
      processEntry({ pid: 30, name: 'a.exe' }),
      processEntry({ pid: 10, name: 'a.exe' })
    ];
    assert.deepStrictEqual(picker.rankProcesses(input, {}).map((entry) => entry.pid), [10, 30, 20]);
  });

  console.log('the name filter argument');

  // What VS Code actually passes, verified against its documentation and its
  // source (baseConfigurationResolverService): an `inputs` entry of type
  // "command" hands the command its own `args` value, while a bare
  // `${command:...}` variable hands it the enclosing debug configuration.
  await test('an explicit args.nameFilter is used', () => {
    assert.strictEqual(picker.resolveNameFilter({ nameFilter: 'SampleApp.exe' }), 'SampleApp.exe');
    assert.strictEqual(picker.resolveNameFilter({ args: { nameFilter: 'SampleApp.exe' } }), 'SampleApp.exe');
    assert.strictEqual(picker.resolveNameFilter('SampleApp.exe'), 'SampleApp.exe');
  });

  await test('a debug-configuration argument filters on its processName', () => {
    assert.strictEqual(picker.resolveNameFilter({
      type: 'delphi-win64', request: 'attach', name: 'Attach to SampleApp',
      processName: 'SampleApp.exe', processId: '${command:delphi-win64.pickProcess}'
    }), 'SampleApp.exe');
  });

  await test('an explicit nameFilter outranks a processName on the same object', () => {
    assert.strictEqual(picker.resolveNameFilter({ nameFilter: 'A.exe', processName: 'B.exe' }), 'A.exe');
  });

  await test('no usable argument means no filter', () => {
    [undefined, null, {}, '', '   ', 42, { processName: '' }, { processName: 123 }, { args: {} }]
      .forEach((argument) => assert.strictEqual(picker.resolveNameFilter(argument), '',
        'expected no filter for ' + JSON.stringify(argument)));
  });

  console.log('filtering by name');

  await test('the name matches with and without the .exe suffix, either way round', () => {
    const all = picker.parseProcessListJson(adapterOutput(TWO_INSTANCES));
    ['SampleApp.exe', 'SampleApp', 'SampleApp.exe', 'SAMPLEAPP'].forEach((filter) => {
      assert.deepStrictEqual(picker.filterByName(all, filter).map((entry) => entry.pid), [7788, 9012],
        'filter ' + filter + ' must select both instances, oldest pid first');
    });
  });

  await test('the match is on the whole name, not a prefix', () => {
    const all = picker.parseProcessListJson(adapterOutput(TWO_INSTANCES));
    assert.ok(picker.filterByName(all, 'SampleApp').every((entry) => entry.name !== 'SampleAppHelper.exe'),
      'SampleAppHelper.exe is a different application');
  });

  await test('what can be attached to is offered before what cannot', () => {
    const mixed = [
      processEntry({ pid: 100, name: 'App.exe', canDebug: false, arch: 'x86', reason: 'target is x86' }),
      processEntry({ pid: 200, name: 'App.exe' })
    ];
    assert.deepStrictEqual(picker.filterByName(mixed, 'App').map((entry) => entry.pid), [200, 100]);
  });

  await test('an empty filter keeps every process', () => {
    const all = picker.parseProcessListJson(adapterOutput(TWO_INSTANCES));
    assert.strictEqual(picker.filterByName(all, '').length, all.length);
  });

  console.log('quick pick items');

  await test('the window caption and the command line tell two instances apart', () => {
    const items = picker.toQuickPickItems(
      picker.filterByName(picker.parseProcessListJson(adapterOutput(TWO_INSTANCES)), 'SampleApp.exe'));
    assert.deepStrictEqual(items.map((item) => item.label), ['SampleApp.exe', 'SampleApp.exe']);
    assert.deepStrictEqual(items.map((item) => item.detail),
      ['$(window) SampleApp - Customers  ·  C:\\Apps\\SampleApp.exe /project=Customers',
       '$(window) SampleApp - Invoices  ·  C:\\Apps\\SampleApp.exe /project=Invoices']);
    assert.match(items[0].description, /^PID 7788/);
    assert.match(items[0].description, /x64/);
    assert.match(items[0].description, /session 1/);
  });

  // The caption comes first because it is the one field a user can compare with
  // what is on their screen; the command line stays because a service, a console
  // process or an instance still starting up has no caption at all.
  await test('a process with no window keeps showing its command line', () => {
    const item = picker.toQuickPickItems([processEntry({ windowTitle: '' })])[0];
    assert.strictEqual(item.detail, 'C:\\Apps\\Sample.exe');
    assert.ok(item.detail.indexOf('$(window)') === -1, 'no window icon without a window');
  });

  // SampleApp names both of its windows after the connected database, so on the
  // machine this was built for the caption does NOT separate the two instances.
  // The start time does.
  await test('the start time is offered when even the caption is ambiguous', () => {
    const items = picker.toQuickPickItems([
      processEntry({ pid: 640, windowTitle: 'Sample App', startTime: '2026-07-21T09:14:02' }),
      processEntry({ pid: 10108, windowTitle: 'Sample App', startTime: '2026-07-21T17:05:44' })
    ]);
    assert.match(items[0].description, /started 2026-07-21 09:14:02/);
    assert.match(items[1].description, /started 2026-07-21 17:05:44/);
  });

  await test('a process with no start time shows none', () => {
    const item = picker.toQuickPickItems([processEntry({ startTime: '' })])[0];
    assert.ok(item.description.indexOf('started') === -1);
  });

  await test('the refusal still comes before the caption', () => {
    const item = picker.toQuickPickItems([processEntry({
      canDebug: false, reason: 'target is x86', windowTitle: 'Legacy'
    })])[0];
    assert.match(item.detail, /^cannot attach - target is x86  ·  \$\(window\) Legacy/);
  });

  await test('a process that cannot be debugged says so, with the adapter\'s reason', () => {
    const item = picker.toQuickPickItems(
      picker.parseProcessListJson(adapterOutput(TWO_INSTANCES)).filter((entry) => entry.pid === 2500))[0];
    assert.match(item.label, /^\$\(circle-slash\) LegacyApp\.exe$/);
    assert.match(item.detail, /cannot attach - target is x86/);
    assert.match(item.description, /x86/);
    assert.strictEqual(item.canDebug, false);
  });

  await test('a process with no command line falls back to its image path', () => {
    const item = picker.toQuickPickItems([processEntry({ commandLine: '', path: 'C:\\Apps\\Sample.exe' })])[0];
    assert.strictEqual(item.detail, 'C:\\Apps\\Sample.exe');
  });

  console.log('the command');

  await test('the adapter is run in listing mode, with the filter as its own argument', async () => {
    resetStubs();
    quickPickAnswer = (items) => items[0];
    await picker.pickProcess({ nameFilter: 'SampleApp.exe' }, pickerOptions);
    assert.strictEqual(adapterCalls.length, 1);
    assert.strictEqual(adapterCalls[0].file, fakeAdapterPath);
    assert.deepStrictEqual(adapterCalls[0].args, ['--list-processes', 'SampleApp.exe']);
    assert.ok(adapterCalls[0].options.timeout > 0, 'a hung adapter must not hang the session start');
    assert.ok(adapterCalls.every((call) => !/tasklist/i.test(call.file)),
      'the picker must never shell out to tasklist again');
  });

  await test('with no filter the adapter lists everything', async () => {
    resetStubs();
    quickPickAnswer = (items) => items.find((item) => item.label === 'Notepad.exe');
    const pid = await picker.pickProcess(undefined, pickerOptions);
    assert.strictEqual(pid, '4321');
    assert.deepStrictEqual(adapterCalls[0].args, ['--list-processes']);
    assert.strictEqual(recorded.quickPicks[0].items.length, 6,
      'everything except the two pseudo-processes');
  });

  await test('exactly one match is returned without prompting', async () => {
    resetStubs();
    const pid = await picker.pickProcess({ nameFilter: 'Notepad' }, pickerOptions);
    assert.strictEqual(pid, '4321');
    assert.strictEqual(recorded.quickPicks.length, 0, 'there is nothing to choose from');
  });

  await test('a processName-carrying configuration filters with no inputs block', async () => {
    resetStubs();
    const pid = await picker.pickProcess({
      type: 'delphi-win64', request: 'attach', processName: 'Notepad.exe'
    }, pickerOptions);
    assert.strictEqual(pid, '4321');
    assert.deepStrictEqual(adapterCalls[0].args, ['--list-processes', 'Notepad.exe']);
    assert.strictEqual(recorded.quickPicks.length, 0);
  });

  await test('several matches are offered, told apart by their command lines', async () => {
    resetStubs();
    quickPickAnswer = (items) => items.find((item) => /Invoices/.test(item.detail));
    const pid = await picker.pickProcess({ nameFilter: 'SampleApp.exe' }, pickerOptions);
    assert.strictEqual(pid, '9012');
    const offered = recorded.quickPicks[0].items;
    assert.deepStrictEqual(offered.map((item) => item.pid), [7788, 9012]);
    assert.match(recorded.quickPicks[0].options.placeHolder, /SampleApp\.exe/);
    assert.strictEqual(recorded.quickPicks[0].options.matchOnDetail, true,
      'typing part of the caption or the command line must filter the list');
  });

  await test('a window caption can be picked by typing it', async () => {
    resetStubs();
    quickPickAnswer = (items) => items.find((item) => /SampleApp - Customers/.test(item.detail));
    assert.strictEqual(await picker.pickProcess({ nameFilter: 'SampleApp.exe' }, pickerOptions), '7788');
  });

  await test('the single match of an executable that cannot be debugged is refused', async () => {
    resetStubs();
    assert.strictEqual(await picker.pickProcess({ nameFilter: 'LegacyApp.exe' }, pickerOptions), undefined);
    assert.strictEqual(recorded.quickPicks.length, 0);
    assert.match(recorded.errors[0], /LegacyApp\.exe \(PID 2500\) cannot be debugged/);
    assert.match(recorded.errors[0], /x86/);
  });

  await test('choosing a process that cannot be debugged aborts with the reason', async () => {
    resetStubs();
    quickPickAnswer = (items) => items.find((item) => /LegacyApp/.test(item.label));
    assert.strictEqual(await picker.pickProcess(undefined, pickerOptions), undefined);
    assert.match(recorded.errors[0], /cannot be debugged/);
  });

  await test('no match names the filter and returns undefined', async () => {
    resetStubs();
    quickPickAnswer = (items) => items[0];
    assert.strictEqual(await picker.pickProcess({ nameFilter: 'NotRunning.exe' }, pickerOptions), undefined);
    assert.strictEqual(recorded.quickPicks.length, 0);
    assert.match(recorded.errors[0], /NotRunning\.exe/);
  });

  await test('cancelling returns undefined so VS Code aborts the session', async () => {
    resetStubs();
    quickPickAnswer = () => undefined;
    assert.strictEqual(await picker.pickProcess({ nameFilter: 'SampleApp.exe' }, pickerOptions), undefined);
    assert.strictEqual(recorded.quickPicks.length, 1);
    assert.strictEqual(recorded.errors.length, 0, 'a deliberate Esc is not an error');
  });

  await test('an adapter failure is reported and nothing is picked', async () => {
    resetStubs();
    adapterResult = { error: new Error('spawn ENOENT'), stdout: '' };
    quickPickAnswer = (items) => items[0];
    assert.strictEqual(await picker.pickProcess({ nameFilter: 'SampleApp.exe' }, pickerOptions), undefined);
    assert.strictEqual(recorded.quickPicks.length, 0);
    assert.match(recorded.errors[0], /Could not list running processes/);
    assert.match(recorded.errors[0], /spawn ENOENT/);
  });

  await test('unusable adapter output is an error, never a silent tasklist fallback', async () => {
    resetStubs();
    adapterResult = { error: null, stdout: 'Fatal: access denied\r\n' };
    assert.strictEqual(await picker.pickProcess({ nameFilter: 'SampleApp.exe' }, pickerOptions), undefined);
    assert.strictEqual(adapterCalls.length, 1, 'exactly one attempt, and no second source');
    assert.match(recorded.errors[0], /did not return a process list/);
  });

  await test('an adapter that is not built is reported before anything is run', async () => {
    resetStubs();
    writeFakeManifest('./NotBuiltYet.exe');
    assert.strictEqual(await picker.pickProcess(undefined, pickerOptions), undefined);
    assert.strictEqual(adapterCalls.length, 0);
    assert.match(recorded.errors[0], /Could not list running processes/);
    assert.match(recorded.errors[0], /NotBuiltYet\.exe/);
    writeFakeManifest('./VisualStudioCodeDelphiDebugger.exe');
  });

  await test('an empty machine does not open an empty picker', async () => {
    resetStubs();
    adapterResult = { error: null, stdout: '[]\n' };
    assert.strictEqual(await picker.pickProcess(undefined, pickerOptions), undefined);
    assert.strictEqual(recorded.quickPicks.length, 0);
    assert.match(recorded.errors[0], /No running processes/);
  });

  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  Module._load = originalLoad;
  fs.rmSync(fakeExtensionDir, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

main();
