'use strict';

/*
 * Tests for the project-scoped rule files: where they are derived from, which
 * ones the editor offers, and how the QuickPick entry describes them.
 *
 *   node install\extension-tests\test-project-rules.js
 *
 * The naming has to agree with `ExceptionRules.pas` exactly -- the adapter reads
 * these files, the extension writes them, and neither asks the other where they
 * are. The cases below are the ones where a plausible implementation disagrees:
 * a `.dproj` rather than a `.dpr`, a project name containing dots, a launch and
 * an attach configuration naming the same project, and a `${workspaceFolder}`
 * that only the editor has to expand (the adapter is handed it already
 * substituted).
 */

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');

// describeTarget needs no vscode API, but the module it lives in requires the
// module at load time.
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') {
    return { workspace: { workspaceFolders: [], workspaceFile: undefined, isTrusted: true }, Uri: { file: (p) => ({ fsPath: p }) } };
  }
  return originalLoad.call(this, request, parent, isMain);
};

const projectRules = require(path.join(extensionDir, 'projectRules.js'));
const globalRules = require(path.join(extensionDir, 'globalRules.js'));
const editor = require(path.join(extensionDir, 'exceptionRulesEditor.js'));

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

function withTempDirectory(fn) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'delphi-project-rules-'));
  try {
    return fn(directory);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

console.log('project rule files - naming');

test('the two files sit next to the project and are named after it', () => {
  const project = path.join('C:', 'work', 'TabAnag', 'libTabAnagD29.dpk');
  assert.strictEqual(projectRules.projectRulesPath(project),
    path.join('C:', 'work', 'TabAnag', 'libTabAnagD29.ExceptionSettings.json'));
  assert.strictEqual(projectRules.localProjectRulesPath(project),
    path.join('C:', 'work', 'TabAnag', 'libTabAnagD29.ExceptionSettings.local.json'));
});

test('.dpr, .dpk and .dproj name the same pair of files', () => {
  const expected = projectRules.projectRulesPath('C:\\proj\\Debugme.dpr');
  assert.strictEqual(projectRules.projectRulesPath('C:\\proj\\Debugme.dpk'), expected);
  assert.strictEqual(projectRules.projectRulesPath('C:\\proj\\Debugme.dproj'), expected);
});

test('a dotted project name keeps all of itself', () => {
  assert.strictEqual(projectRules.projectRulesPath('C:\\proj\\My.Company.Widgets.dpk'),
    'C:\\proj\\My.Company.Widgets.ExceptionSettings.json');
  assert.strictEqual(projectRules.projectBaseName('C:\\proj\\My.Company.Widgets.dpk'),
    'My.Company.Widgets');
});

test('no project means no path', () => {
  assert.strictEqual(projectRules.projectRulesPath(''), '');
  assert.strictEqual(projectRules.localProjectRulesPath('   '), '');
});

console.log('project rule files - resolving what a configuration declares');

test('${workspaceFolder} is expanded, unlike in the adapter where VS Code already did it', () => {
  const resolved = projectRules.resolveProjectFile({
    delphiProjectFile: '${workspaceFolder}/Debugme.dproj',
    workspaceFolder: 'C:\\repo'
  });
  assert.strictEqual(resolved, path.normalize('C:\\repo\\Debugme.dproj'));
});

test('a relative path is resolved against the workspace folder', () => {
  const resolved = projectRules.resolveProjectFile({
    delphiProjectFile: 'packages/libFoo.dpk',
    workspaceFolder: 'C:\\repo'
  });
  assert.strictEqual(resolved, path.normalize('C:\\repo\\packages\\libFoo.dpk'));
});

test('a variable nothing here can expand yields no project at all', () => {
  assert.strictEqual(projectRules.resolveProjectFile({
    delphiProjectFile: '${command:pickProject}',
    workspaceFolder: 'C:\\repo'
  }), '');
});

test('a configuration that declares nothing yields no project', () => {
  assert.strictEqual(projectRules.resolveProjectFile({ name: 'Debug' }), '');
  assert.strictEqual(projectRules.resolveProjectFile({ delphiProjectFile: '   ' }), '');
});

console.log('project rule files - the targets offered');

test('one project yields local first, then shared', () => {
  const targets = projectRules.collectProjectTargets(
    [{ name: 'Debug Debugme', delphiProjectFile: 'C:\\repo\\Debugme.dproj', workspaceFolder: 'C:\\repo' }],
    { directoryExists: () => true, readRulesFile: () => ({ exists: false, shape: 'empty', rules: [] }) });
  assert.deepStrictEqual(targets.map((t) => t.kind), ['projectLocal', 'projectShared']);
  // Named after the project FILE, which is what the developer opened in the IDE.
  assert.strictEqual(targets[0].name, 'Debugme.dproj rules (local)');
  assert.strictEqual(targets[1].name, 'Debugme.dproj rules (shared)');
});

test('a launch and an attach configuration for the same project give ONE pair, naming both', () => {
  const targets = projectRules.collectProjectTargets([
    { name: 'Debug Debugme',      delphiProjectFile: '${workspaceFolder}/Debugme.dproj', workspaceFolder: 'C:\\repo' },
    { name: 'Attach to Debugme',  delphiProjectFile: '${workspaceFolder}/Debugme.dproj', workspaceFolder: 'C:\\repo' }
  ], { directoryExists: () => true, readRulesFile: () => ({ exists: true, shape: 'object', rules: [] }) });
  assert.strictEqual(targets.length, 2);
  assert.deepStrictEqual(targets[0].declaredBy, ['Debug Debugme', 'Attach to Debugme']);
});

test('two different projects give a pair each', () => {
  const targets = projectRules.collectProjectTargets([
    { name: 'A', delphiProjectFile: 'C:\\repo\\A.dpk', workspaceFolder: 'C:\\repo' },
    { name: 'B', delphiProjectFile: 'C:\\repo\\B.dpk', workspaceFolder: 'C:\\repo' }
  ], { directoryExists: () => true, readRulesFile: () => ({ exists: false, shape: 'empty', rules: [] }) });
  assert.strictEqual(targets.length, 4);
});

test('a stale project path (directory gone) is not offered', () => {
  const targets = projectRules.collectProjectTargets(
    [{ name: 'Renamed', delphiProjectFile: 'C:\\gone\\Old.dproj', workspaceFolder: 'C:\\repo' }],
    { directoryExists: () => false, readRulesFile: () => ({ exists: false, shape: 'empty', rules: [] }) });
  assert.deepStrictEqual(targets, []);
});

test('the rules already in the files are carried into the target', () => withTempDirectory((directory) => {
  const project = path.join(directory, 'Debugme.dproj');
  fs.writeFileSync(projectRules.projectRulesPath(project),
    '{ "exceptionRules": [ { "class": "EAbort", "action": "ignore" } ] }', 'utf8');
  const targets = projectRules.collectProjectTargets(
    [{ name: 'Debug', delphiProjectFile: project, workspaceFolder: directory }]);
  const shared = targets.find((t) => t.kind === 'projectShared');
  const local = targets.find((t) => t.kind === 'projectLocal');
  assert.strictEqual(shared.exists, true);
  assert.deepStrictEqual(shared.exceptionRules, [{ class: 'EAbort', action: 'ignore' }]);
  assert.strictEqual(local.exists, false);
  assert.deepStrictEqual(local.exceptionRules, []);
}));

test('a sidecar written through the shared-file writer keeps its shape', () => withTempDirectory((directory) => {
  const sidecar = projectRules.projectRulesPath(path.join(directory, 'Debugme.dproj'));
  fs.writeFileSync(sidecar, '// the team\'s rules\n[\n]\n', 'utf8');
  globalRules.writeGlobalRulesFile(sidecar, [{ class: 'EAbort', action: 'ignore' }]);
  const text = fs.readFileSync(sidecar, 'utf8');
  assert.ok(text.startsWith('// the team\'s rules'), 'the header comment must survive: ' + text);
  assert.ok(text.trimEnd().endsWith(']'), 'a bare array file must stay a bare array: ' + text);
  assert.deepStrictEqual(globalRules.parseGlobalRules(text).rules, [{ class: 'EAbort', action: 'ignore' }]);
}));

console.log('project rule files - which launch configurations still get an entry');

// The user-visible point of the whole change: with a project on offer, "Debug X"
// and "Attach to X" stop being two ways to disagree with each other.
test('a project on offer replaces the per-configuration entries', () => {
  const configurations = [
    { name: 'Debug Debugme', exceptionRules: [] },
    { name: 'Attach to Debugme.exe', exceptionRules: [] }
  ];
  const offered = editor.launchTargetsToOffer(configurations, [{ kind: 'projectShared' }]);
  assert.deepStrictEqual(offered, []);
});

test('a configuration that already has rules is never hidden', () => {
  const withRules = { name: 'Debug Debugme', exceptionRules: [{ action: 'ignore' }] };
  const offered = editor.launchTargetsToOffer(
    [withRules, { name: 'Attach to Debugme.exe', exceptionRules: [] }],
    [{ kind: 'projectShared' }]);
  assert.deepStrictEqual(offered.map((c) => c.name), ['Debug Debugme']);
});

test('with no project named, the list is exactly what it always was', () => {
  const configurations = [
    { name: 'Debug Debugme', exceptionRules: [] },
    { name: 'Attach to Debugme.exe', exceptionRules: [] }
  ];
  assert.deepStrictEqual(editor.launchTargetsToOffer(configurations, []).map((c) => c.name),
    ['Debug Debugme', 'Attach to Debugme.exe']);
  assert.deepStrictEqual(editor.launchTargetsToOffer(configurations, undefined).map((c) => c.name),
    ['Debug Debugme', 'Attach to Debugme.exe']);
});

console.log('project rule files - how the picker describes them');

function describeKind(kind, overrides) {
  return editor.describeTarget(Object.assign({
    kind: kind,
    name: 'Debugme rules',
    filePath: 'C:\\repo\\Debugme.ExceptionSettings.json',
    documentLabel: 'C:\\repo\\Debugme.ExceptionSettings.json',
    exceptionRules: [],
    exists: true
  }, overrides || {}));
}

test('the local file is described as personal, the shared one as committed', () => {
  assert.match(describeKind('projectLocal').detail, /gitignore/);
  assert.match(describeKind('projectShared').detail, /commit/);
});

test('a file that does not exist yet says so instead of looking broken', () => {
  assert.match(describeKind('projectShared', { exists: false }).detail, /will be created/);
});

test('the entry names the configurations that use it', () => {
  assert.match(describeKind('projectShared', { declaredBy: ['Debug Debugme', 'Attach to Debugme'] }).detail,
    /used by Debug Debugme, Attach to Debugme/);
});

test('a launch configuration entry keeps its name and says how far it reaches', () => {
  const described = editor.describeTarget({
    kind: 'launch', name: 'Debug Debugme', documentLabel: 'repo/.vscode/launch.json',
    exceptionRules: [{ action: 'break' }]
  });
  assert.strictEqual(described.label, 'Debug Debugme');
  assert.match(described.detail, /^repo\/\.vscode\/launch\.json/);
  assert.match(described.detail, /this configuration only/);
  assert.strictEqual(described.description, '1 rule(s)');
});

test('the machine-wide entry keeps its own notes', () => {
  const described = editor.describeTarget({
    kind: 'global', name: 'Shared rules (all projects)',
    filePath: 'C:\\Users\\T\\.DelphiWinDebugger\\exceptionRules.json',
    documentLabel: 'C:\\Users\\T\\.DelphiWinDebugger\\exceptionRules.json',
    exceptionRules: [], exists: true, overriddenBy: 'Debug Debugme'
  });
  assert.ok(described.label.startsWith('$(globe)'), described.label);
  assert.match(described.detail, /path from "Debug Debugme"/);
});

console.log('');
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
