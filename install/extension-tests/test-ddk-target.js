'use strict';

/*
 * Tests for ddkTarget.js: the mapping of a delphi-devkit (DDK) debug target
 * onto the adapter's launch/attach attributes, the decision of WHEN a
 * configuration is sent to DDK, where ddk.exe is looked for, and how the
 * target is obtained (the DDK extension's command when installed, the CLI
 * otherwise, a clear error when neither exists).
 *
 * The fixture is the reply shape DDK documents for `debug-target --json`
 * (snake_case, forward slashes), for a program and for a package with a Host
 * Application.
 *
 *   node install\extension-tests\test-ddk-target.js
 */

const assert = require('assert');
const path = require('path');

const extensionDir = path.join(__dirname, '..', 'mca-software.delphi-debugger');
const ddk = require(path.join(extensionDir, 'ddkTarget.js'));

let passed = 0;
let failed = 0;

const queue = [];
function test(name, fn) {
  queue.push({ name: name, fn: fn });
}

async function runQueue() {
  for (const entry of queue) {
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

// -------------------------------------------------------------- fixtures --

const PROGRAM_TARGET = {
  project_id: 869, project: 'CVSTreeGraph',
  project_file: 'c:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/CVSTreeGraph.dproj',
  main_source: 'C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/CVSTreeGraph.dpr',
  kind: 'program',
  executable: 'C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/Win64/Debug/CVSTreeGraph.exe',
  host_application: null,
  compiler: 'Delphi 12.0 Athens', config: 'Debug', platform: 'Win64', bitness: 64,
  symbols: {
    map: 'C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/Win64/Debug/CVSTreeGraph.map',
    rsm: 'C:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources/Win64/Debug/CVSTreeGraph.rsm'
  },
  source_root: 'c:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources',
  source_search_paths: [
    'c:/Athens/GitHub/CVSTreeGraph/CVSTreeGraphSources',
    'C:/Program Files (x86)/Embarcadero/Studio/23.0/source/rtl/common'
  ],
  modules: [],
  args: ['-verbose', 'C:/data/input file.txt'],
  warnings: []
};

const PACKAGE_TARGET = {
  project_id: 596, project: 'libAboutD29',
  project_file: 'c:/Athens/hydra_2/About/libAboutD29.dproj',
  main_source: 'C:/Athens/hydra_2/About/libAboutD29.dpk',
  kind: 'package',
  executable: 'c:/Athens/hydra_2/Win64/Debug/Hydra2.exe',
  host_application: 'c:/Athens/hydra_2/Win64/Debug/Hydra2.exe',
  compiler: 'Delphi 12.0 Athens', config: 'Debug', platform: 'Win64', bitness: 64,
  symbols: { map: 'c:/Athens/hydra_2/Win64/Debug/Hydra2.map', rsm: 'c:/Athens/hydra_2/Win64/Debug/Hydra2.rsm' },
  source_root: 'c:/Athens/hydra_2/About',
  source_search_paths: ['c:/Athens/hydra_2/About'],
  modules: [
    {
      name: 'libAboutD29.bpl',
      binary: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.bpl',
      map: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.map',
      rsm: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.rsm',
      dcp: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Dcp/Win64/libAboutD29.dcp'
    },
    { name: 'libNotBuilt.bpl', binary: null, map: null, rsm: null, dcp: null },
    {
      name: 'libNoSidecars.bpl',
      binary: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libNoSidecars.bpl',
      map: null, rsm: null, dcp: null
    }
  ],
  args: [],
  warnings: ['libNotBuilt.bpl was not found; build the package first.']
};

test('-- ddkTarget: when a configuration goes to DDK', () => {});

test('ddkProject set -> yes, whatever else is there', () => {
  assert.strictEqual(ddk.needsDebugTarget({ type: 'delphi', request: 'launch', ddkProject: 'MyApp' }), true);
  assert.strictEqual(ddk.needsDebugTarget({ type: 'delphi', request: 'launch', ddkProject: 596, program: 'x.exe' }), true);
});

test('delphiProjectFile without program -> yes; with program -> no (the IDE plugin writes both)', () => {
  assert.strictEqual(ddk.needsDebugTarget({ request: 'launch', delphiProjectFile: 'C:/p/App.dproj' }), true);
  assert.strictEqual(ddk.needsDebugTarget({ request: 'launch', delphiProjectFile: 'C:/p/App.dproj', program: 'C:/p/App.exe' }), false);
});

test('a plain configuration is left alone', () => {
  assert.strictEqual(ddk.needsDebugTarget({ request: 'launch', program: 'C:/p/App.exe' }), false);
  assert.strictEqual(ddk.needsDebugTarget({ request: 'launch', ddkProject: '  ' }), false);
  assert.strictEqual(ddk.needsDebugTarget(undefined), false);
});

test('ddkProject takes precedence as the reference; delphiProjectFile is the path reference otherwise', () => {
  assert.deepStrictEqual(ddk.targetReference({ ddkProject: 'MyApp', delphiProjectFile: 'C:/p/App.dproj' }),
    { project: 'MyApp' });
  assert.deepStrictEqual(ddk.targetReference({ ddkProject: 596 }), { project: '596' });
  assert.deepStrictEqual(ddk.targetReference({ delphiProjectFile: 'C:/p/App.dproj', ddkCompiler: '12.0' }),
    { project: 'C:/p/App.dproj', compiler: '12.0' });
});

test('-- ddkTarget: mapping a target onto the configuration', () => {});

test('a program: program, symbols, sources, args and delphiProjectFile come from DDK', () => {
  const config = { type: 'delphi', request: 'launch', name: 'Debug CVSTreeGraph (DDK)', ddkProject: 'CVSTreeGraph' };
  const result = ddk.configurationFromDebugTarget(config, PROGRAM_TARGET);
  assert.strictEqual(result.program, PROGRAM_TARGET.executable);
  assert.strictEqual(result.mapFile, PROGRAM_TARGET.symbols.map);
  assert.strictEqual(result.rsmFile, PROGRAM_TARGET.symbols.rsm);
  assert.strictEqual(result.sourceRoot, PROGRAM_TARGET.source_root);
  assert.deepStrictEqual(result.sourceSearchPaths, PROGRAM_TARGET.source_search_paths);
  assert.deepStrictEqual(result.args, ['-verbose', 'C:/data/input file.txt']);
  assert.strictEqual(result.delphiProjectFile, PROGRAM_TARGET.project_file);
  assert.strictEqual(result.modules, undefined, 'no modules for a plain program');
  assert.strictEqual(result.processName, undefined, 'a launch names no process');
  // The input is not mutated, and the identifying fields survive.
  assert.strictEqual(config.program, undefined);
  assert.strictEqual(result.type, 'delphi');
  assert.strictEqual(result.request, 'launch');
  assert.strictEqual(result.ddkProject, 'CVSTreeGraph');
});

test('a package: the host application is launched and the built module is pre-bound', () => {
  const result = ddk.configurationFromDebugTarget(
    { type: 'delphi', request: 'launch', ddkProject: 'libAboutD29' }, PACKAGE_TARGET);
  assert.strictEqual(result.program, 'c:/Athens/hydra_2/Win64/Debug/Hydra2.exe');
  assert.strictEqual(result.mapFile, 'c:/Athens/hydra_2/Win64/Debug/Hydra2.map');
  assert.deepStrictEqual(result.modules, [
    {
      name: 'libAboutD29.bpl',
      map: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.map',
      rsm: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Bpl/Win64/libAboutD29.rsm',
      dcp: 'C:/Users/Public/Documents/Embarcadero/Studio/23.0/Dcp/Win64/libAboutD29.dcp'
    },
    { name: 'libNoSidecars.bpl' }
  ], 'a module without a binary is dropped; null sidecars are omitted, not passed as null');
  assert.strictEqual(result.args, undefined, 'an empty args array is not written');
  assert.strictEqual(result.delphiProjectFile, 'c:/Athens/hydra_2/About/libAboutD29.dproj',
    'exception rules are scoped to the PACKAGE project, not the host');
});

test('attach: processName is the executable basename and program is the executable', () => {
  const result = ddk.configurationFromDebugTarget(
    { type: 'delphi', request: 'attach', ddkProject: 'libAboutD29' }, PACKAGE_TARGET);
  assert.strictEqual(result.processName, 'Hydra2.exe');
  assert.strictEqual(result.program, 'c:/Athens/hydra_2/Win64/Debug/Hydra2.exe');
  assert.strictEqual(result.processId, undefined, 'the picker decides the pid, not this mapping');
  assert.strictEqual(result.modules.length, 2);
});

test('a value the user wrote explicitly is never overwritten', () => {
  const config = {
    type: 'delphi', request: 'launch', ddkProject: 'CVSTreeGraph',
    program: 'C:/other/build/CVSTreeGraph.exe',
    args: ['--test'],
    sourceSearchPaths: [],
    stopAtEntry: true
  };
  const result = ddk.configurationFromDebugTarget(config, PROGRAM_TARGET);
  assert.strictEqual(result.program, 'C:/other/build/CVSTreeGraph.exe');
  assert.deepStrictEqual(result.args, ['--test']);
  assert.deepStrictEqual(result.sourceSearchPaths, [], 'an explicit empty array is a decision too');
  assert.strictEqual(result.stopAtEntry, true);
  assert.strictEqual(result.mapFile, PROGRAM_TARGET.symbols.map, 'what was not written is still filled');
});

test('a non-Windows platform (bitness null) is refused with the warning text', () => {
  const target = Object.assign({}, PROGRAM_TARGET, {
    platform: 'Linux64', bitness: null,
    warnings: ['Platform "Linux64" is not a Windows platform; this project cannot be debugged here.']
  });
  assert.throws(() => ddk.configurationFromDebugTarget({ request: 'launch', ddkProject: 'x' }, target),
    /Linux64.*cannot be debugged/);
});

test('a target with no executable is refused rather than launched as an empty string', () => {
  const target = Object.assign({}, PROGRAM_TARGET, { executable: null, warnings: ['CVSTreeGraph.exe was not found; compile first.'] });
  assert.throws(() => ddk.configurationFromDebugTarget({ request: 'launch', ddkProject: 'x' }, target),
    /no executable.*compile first/);
});

test('warnings are the non-empty strings of the warnings array', () => {
  assert.deepStrictEqual(ddk.warningsOf(PACKAGE_TARGET), ['libNotBuilt.bpl was not found; build the package first.']);
  assert.deepStrictEqual(ddk.warningsOf({ warnings: ['', null, 'x'] }), ['x']);
  assert.deepStrictEqual(ddk.warningsOf({}), []);
});

test('-- ddkTarget: locating ddk.exe', () => {});

function diskWith(files) {
  const set = new Set(files.map((f) => f.toLowerCase()));
  return {
    exists: (p) => set.has(String(p).toLowerCase()),
    listDir: (dir) => {
      const prefix = String(dir).toLowerCase().replace(/\//g, '\\') + '\\';
      const names = new Set();
      files.forEach((f) => {
        const lower = f.toLowerCase().replace(/\//g, '\\');
        if (lower.startsWith(prefix)) names.add(f.replace(/\//g, '\\').slice(prefix.length).split('\\')[0]);
      });
      return Array.from(names);
    }
  };
}

test('DDK_EXE wins when it points at a file', () => {
  const disk = diskWith(['D:\\tools\\ddk.exe', 'C:\\bin\\ddk.exe']);
  const found = ddk.locateDdkExe(Object.assign({ env: { DDK_EXE: 'D:\\tools\\ddk.exe', PATH: 'C:\\bin' } }, disk));
  assert.strictEqual(found, 'D:\\tools\\ddk.exe');
});

test('then PATH, in order', () => {
  const disk = diskWith(['C:\\second\\ddk.exe', 'C:\\first\\ddk.exe']);
  const found = ddk.locateDdkExe(Object.assign({ env: { PATH: 'C:\\nothing;C:\\first;C:\\second' } }, disk));
  assert.strictEqual(found, 'C:\\first\\ddk.exe');
});

test('then the newest packaged DDK extension under ~/.vscode/extensions', () => {
  const home = 'C:\\Users\\me';
  const disk = diskWith([
    home + '\\.vscode\\extensions\\snowcaloid.delphi-devkit-1.9.0\\server\\ddk.exe',
    home + '\\.vscode\\extensions\\snowcaloid.delphi-devkit-1.10.2\\server\\ddk.exe'
  ]);
  const found = ddk.locateDdkExe(Object.assign({ env: { USERPROFILE: home, PATH: 'C:\\nothing' } }, disk));
  assert.strictEqual(found, home + '\\.vscode\\extensions\\snowcaloid.delphi-devkit-1.10.2\\server\\ddk.exe');
});

test('nowhere -> undefined, and a DDK_EXE that does not exist does not win', () => {
  const disk = diskWith([]);
  assert.strictEqual(ddk.locateDdkExe(Object.assign({ env: { DDK_EXE: 'X:\\gone.exe', PATH: 'C:\\x', USERPROFILE: 'C:\\Users\\me' } }, disk)), undefined);
});

test('the CLI is asked for JSON, with the compiler only when given', () => {
  assert.deepStrictEqual(ddk.ddkArguments({ project: 'MyApp' }), ['debug-target', 'MyApp', '--json']);
  assert.deepStrictEqual(ddk.ddkArguments({ project: 'C:/p/App.dpr', compiler: 'Delphi 12' }),
    ['debug-target', 'C:/p/App.dpr', '--json', '--compiler', 'Delphi 12']);
});

test('-- ddkTarget: obtaining the target', () => {});

test('the DDK extension, when installed, is activated and asked through its command', async () => {
  let activated = false;
  const calls = [];
  const vscode = {
    extensions: { getExtension: (id) => id === ddk.DDK_EXTENSION_ID ? { isActive: false, activate: async () => { activated = true; } } : undefined },
    commands: { executeCommand: async (id, args) => { calls.push({ id: id, args: args }); return PROGRAM_TARGET; } }
  };
  const target = await ddk.fetchDebugTarget({ project: 'CVSTreeGraph' }, { vscode: vscode });
  assert.strictEqual(activated, true);
  assert.deepStrictEqual(calls, [{ id: ddk.DDK_COMMAND, args: { project: 'CVSTreeGraph' } }]);
  assert.strictEqual(target, PROGRAM_TARGET);
});

test('an ambiguous reference: the command\'s error (with its candidate list) is passed on verbatim', async () => {
  const vscode = {
    extensions: { getExtension: () => ({ isActive: true }) },
    commands: { executeCommand: async () => { throw new Error('Ambiguous project "App": [12] App (C:\\a), [34] App (C:\\b)'); } }
  };
  await assert.rejects(ddk.fetchDebugTarget({ project: 'App' }, { vscode: vscode }), /Ambiguous project "App".*\[34\]/);
});

test('without the extension, ddk.exe is run with debug-target --json and its stdout parsed', async () => {
  const runs = [];
  const execFile = (file, args, options, callback) => {
    runs.push({ file: file, args: args });
    setImmediate(() => callback(null, JSON.stringify(PACKAGE_TARGET), ''));
  };
  const target = await ddk.fetchDebugTarget({ project: '596' }, {
    vscode: { extensions: { getExtension: () => undefined } },
    locate: () => 'C:\\tools\\ddk.exe',
    execFile: execFile
  });
  assert.deepStrictEqual(runs, [{ file: 'C:\\tools\\ddk.exe', args: ['debug-target', '596', '--json'] }]);
  assert.strictEqual(target.project, 'libAboutD29');
});

test('a failing ddk.exe: its stderr is the error message', async () => {
  const execFile = (file, args, options, callback) =>
    setImmediate(() => callback(new Error('Command failed'), '', 'Error: No project matches "Nope". Use `list` to see available projects.\n'));
  await assert.rejects(
    ddk.fetchDebugTarget({ project: 'Nope' }, { vscode: {}, locate: () => 'ddk.exe', execFile: execFile }),
    /No project matches "Nope"/);
});

test('neither the extension nor ddk.exe: one clear error naming what to install', async () => {
  await assert.rejects(
    ddk.fetchDebugTarget({ project: 'x' }, { vscode: {}, locate: () => undefined }),
    (error) => error.message === ddk.NOT_INSTALLED_MESSAGE && /Snowcaloid\.delphi-devkit/.test(error.message) && /DDK_EXE/.test(error.message));
});

test('-- ddkTarget: the whole resolution step', () => {});

test('a configuration that does not name a project comes back as the same object', async () => {
  const config = { type: 'delphi', request: 'launch', program: 'C:/p/App.exe' };
  const result = await ddk.resolveDdkConfiguration(config, { vscode: {}, locate: () => { throw new Error('must not be called'); } });
  assert.strictEqual(result, config);
});

test('a configuration naming a project is filled in and DDK\'s warnings are shown one by one', async () => {
  const shown = [];
  const result = await ddk.resolveDdkConfiguration(
    { type: 'delphi', request: 'launch', ddkProject: 'libAboutD29' },
    {
      vscode: { extensions: { getExtension: () => ({ isActive: true }) }, commands: { executeCommand: async () => PACKAGE_TARGET } },
      showWarning: (text) => shown.push(text)
    });
  assert.strictEqual(result.program, 'c:/Athens/hydra_2/Win64/Debug/Hydra2.exe');
  assert.deepStrictEqual(shown, ['libNotBuilt.bpl was not found; build the package first.']);
});

runQueue().then(() => {
  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
});
