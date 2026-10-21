'use strict';

/*
 * Claude Code follows the extension's lifecycle: the stable copy of the MCP
 * server is registered with it when the extension is installed or reinstalled
 * (without asking), keeps the same registration across an update, and is
 * unregistered and deleted by the uninstall hook - but only when no editor
 * still has the extension, and never a registration that points elsewhere.
 *
 * The claude CLI is a fake that keeps a registry and answers `mcp get` in the
 * format Claude Code 2.x prints. The uninstall hook runs against a REAL
 * temporary profile (USERPROFILE, LOCALAPPDATA, APPDATA).
 *
 *   node install\extension-tests\test-claude-lifecycle.js
 */

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const extensionDir = path.join(__dirname, '..', 'mca-software.delphi-debugger');
const stubPath = require.resolve(path.join(extensionDir, 'test', 'vscode-stub.js'));
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'vscode') return stubPath;
  return origResolve.call(this, request, ...rest);
};

const mcp = require(path.join(extensionDir, 'mcpServer.js'));
const ext = require(path.join(extensionDir, 'extension.js'));
const hook = require(path.join(extensionDir, 'uninstall.js'));

let passed = 0;
let failed = 0;
const queue = [];
function test(name, fn) { queue.push({ name: name, fn: fn }); }
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

const STABLE = 'C:\\Users\\u\\AppData\\Local\\DelphiWin64Debugger\\DelphiDebuggerMcp.exe';
const DEV_BUILD = 'C:\\src\\Win64Debugger\\MCPDebugger\\Win64\\Debug\\DelphiDebuggerMcp.exe';

// A claude CLI with a registry: name -> command.
function fakeClaude(initial, options) {
  const o = options || {};
  const registry = Object.assign({}, initial);
  const calls = [];
  const ok = (stdout) => ({ error: null, stdout: stdout || '', stderr: '' });
  return {
    registry: registry,
    calls: calls,
    hasClaude: async () => o.absent !== true,
    run: async (line) => {
      calls.push(line);
      let m = /^claude mcp get (\S+)$/.exec(line);
      if (m) {
        if (!(m[1] in registry))
          return { error: new Error('exit 1'), stdout: '', stderr: 'No MCP server named "' + m[1] + '".' };
        return ok(m[1] + ':\n  Scope: User config (available in all your projects)\n  Status: Connected\n' +
          '  Type: stdio\n  Command: ' + registry[m[1]] + '\n  Args:\n  Environment:\n');
      }
      m = /^claude mcp remove (\S+) -s user$/.exec(line);
      if (m) { delete registry[m[1]]; return ok(); }
      m = /^claude mcp add (\S+) -s user -- "(.*)"$/.exec(line);
      if (m) {
        if (o.addFails) return { error: new Error('exit 1'), stdout: '', stderr: o.addFails };
        registry[m[1]] = m[2];
        return ok();
      }
      return { error: new Error('unexpected command: ' + line), stdout: '', stderr: '' };
    }
  };
}

// --------------------------------------------------------------- parsing --
test('-- reading a registration', () => {});

test('the Command line of `claude mcp get` is the registered executable', () => {
  const out = 'delphi-debugger:\n  Scope: User config\n  Type: stdio\n  Command: ' + STABLE + '\n  Args:\n';
  assert.strictEqual(mcp.registeredCommandFrom(out), STABLE);
  assert.strictEqual(mcp.registeredCommandFrom('  Command: "' + STABLE + '"\r\n'), STABLE, 'quotes and CR are dropped');
  assert.strictEqual(mcp.registeredCommandFrom('No MCP server named "x".'), undefined);
  assert.strictEqual(mcp.registeredCommandFrom(''), undefined);
});

test('paths compare as Windows does: case, slashes and quotes do not matter, empty never matches', () => {
  assert.ok(mcp.samePath(STABLE, STABLE.toLowerCase().replace(/\\/g, '/')));
  assert.ok(mcp.samePath('"' + STABLE + '"', STABLE));
  assert.ok(!mcp.samePath(STABLE, DEV_BUILD));
  assert.ok(!mcp.samePath('', ''));
  assert.ok(!mcp.samePath(undefined, STABLE));
});

// ------------------------------------------------------------------ sync --
test('-- registering without asking', () => {});

test('not registered -> added on the stable copy', async () => {
  const claude = fakeClaude({});
  const result = await mcp.syncClaudeRegistration(STABLE, claude);
  assert.strictEqual(result.outcome, 'added');
  assert.strictEqual(claude.registry['delphi-debugger'], STABLE);
});

test('already registered on the stable copy (any spelling) -> nothing changes', async () => {
  const claude = fakeClaude({ 'delphi-debugger': STABLE.toUpperCase() });
  const result = await mcp.syncClaudeRegistration(STABLE, claude);
  assert.strictEqual(result.outcome, 'registered');
  assert.ok(!claude.calls.some((c) => / add | remove /.test(c)), claude.calls.join(' | '));
});

test('registered on a development build -> left alone, reported as foreign', async () => {
  const claude = fakeClaude({ 'delphi-debugger': DEV_BUILD });
  const result = await mcp.syncClaudeRegistration(STABLE, claude);
  assert.strictEqual(result.outcome, 'foreign');
  assert.strictEqual(result.detail, DEV_BUILD);
  assert.strictEqual(claude.registry['delphi-debugger'], DEV_BUILD);
});

test('the legacy name on the stable copy is dropped; on anything else it is kept', async () => {
  let claude = fakeClaude({ 'delphi-win64-debugger': STABLE });
  await mcp.syncClaudeRegistration(STABLE, claude);
  assert.ok(!('delphi-win64-debugger' in claude.registry));
  assert.strictEqual(claude.registry['delphi-debugger'], STABLE);

  claude = fakeClaude({ 'delphi-win64-debugger': DEV_BUILD });
  await mcp.syncClaudeRegistration(STABLE, claude);
  assert.strictEqual(claude.registry['delphi-win64-debugger'], DEV_BUILD);
});

test('no claude CLI -> no-claude, and not a single command is run', async () => {
  const claude = fakeClaude({}, { absent: true });
  const result = await mcp.syncClaudeRegistration(STABLE, claude);
  assert.strictEqual(result.outcome, 'no-claude');
  assert.strictEqual(claude.calls.length, 0);
});

test('a refused add -> failed, with the CLI\'s own text', async () => {
  const claude = fakeClaude({}, { addFails: 'Invalid scope' });
  const result = await mcp.syncClaudeRegistration(STABLE, claude);
  assert.strictEqual(result.outcome, 'failed');
  assert.strictEqual(result.detail, 'Invalid scope');
});

test('removing touches only the registrations on the stable copy', async () => {
  const claude = fakeClaude({ 'delphi-debugger': STABLE, 'delphi-win64-debugger': DEV_BUILD });
  const removed = await mcp.removeClaudeRegistrations(STABLE, claude);
  assert.deepStrictEqual(removed, ['delphi-debugger']);
  assert.deepStrictEqual(claude.registry, { 'delphi-win64-debugger': DEV_BUILD });
});

// ------------------------------------------------- once per installation --
test('-- once per installation of a copy', () => {});

function makeContext(version) {
  const store = {};
  return {
    extension: { id: 'mca-software.delphi-debugger', packageJSON: { version: version } },
    extensionPath: 'C:\\Users\\u\\.vscode\\extensions\\mca-software.delphi-debugger-' + version,
    globalState: {
      get: (k) => store[k],
      update: (k, v) => { store[k] = v; return Promise.resolve(); }
    },
    _store: store
  };
}
function makeVscode(shown) {
  return { window: { showInformationMessage: (text) => { shown.push(text); return Promise.resolve(); } } };
}
function syncOnce(ctx, claude, installedAt, extra) {
  const shown = [];
  const log = [];
  const deps = Object.assign({
    vscode: makeVscode(shown),
    installEntry: { metadata: { installedTimestamp: installedAt } },
    serverPath: STABLE,
    serverExists: () => true,
    claude: claude
  }, extra || {});
  return ext.syncClaudeOncePerInstall(ctx, (t) => log.push(t), deps).then(() => ({ shown: shown, log: log }));
}

test('an install registers once and says so; the next start does not even ask claude', async () => {
  const ctx = makeContext('0.7.3');
  const claude = fakeClaude({});
  const first = await syncOnce(ctx, claude, 111);
  assert.strictEqual(claude.registry['delphi-debugger'], STABLE);
  assert.strictEqual(first.shown.length, 1);
  assert.match(first.shown[0], /registered with Claude Code/);
  assert.strictEqual(ctx._store[ext.CLAUDE_SYNC_KEY], '0.7.3|111');

  const before = claude.calls.length;
  await syncOnce(ctx, claude, 111);
  assert.strictEqual(claude.calls.length, before, 'no claude call on a later start of the same install');
});

test('a reinstall registers again what the uninstall hook removed', async () => {
  const ctx = makeContext('0.7.3');
  const claude = fakeClaude({});
  await syncOnce(ctx, claude, 111);
  delete claude.registry['delphi-debugger'];           // the uninstall hook
  await syncOnce(ctx, claude, 222);                    // reinstalled: new timestamp
  assert.strictEqual(claude.registry['delphi-debugger'], STABLE);
});

test('a registration removed by hand stays removed until the next install', async () => {
  const ctx = makeContext('0.7.3');
  const claude = fakeClaude({});
  await syncOnce(ctx, claude, 111);
  delete claude.registry['delphi-debugger'];           // the user
  await syncOnce(ctx, claude, 111);                    // same install, VS Code restarted
  assert.ok(!('delphi-debugger' in claude.registry));
});

test('an update needs no new registration: same name, same path, newer file', async () => {
  const ctx = makeContext('0.7.3');
  const claude = fakeClaude({});
  await syncOnce(ctx, claude, 111);
  const ctx2 = makeContext('0.7.4');
  Object.assign(ctx2._store, ctx._store);
  const update = await syncOnce(ctx2, claude, 333);
  assert.strictEqual(claude.registry['delphi-debugger'], STABLE);
  assert.strictEqual(update.shown.length, 0, 'nothing to announce');
  assert.strictEqual(ctx2._store[ext.CLAUDE_SYNC_KEY], '0.7.4|333');
});

test('without claude, or before the stable copy exists, nothing is stored: the next start tries again', async () => {
  let ctx = makeContext('0.7.3');
  await syncOnce(ctx, fakeClaude({}, { absent: true }), 111);
  assert.ok(!(ext.CLAUDE_SYNC_KEY in ctx._store));

  ctx = makeContext('0.7.3');
  const claude = fakeClaude({});
  await syncOnce(ctx, claude, 111, { serverExists: () => false });
  assert.strictEqual(claude.calls.length, 0);
  assert.ok(!(ext.CLAUDE_SYNC_KEY in ctx._store));
});

test('a development build\'s registration is kept, logged, and not announced', async () => {
  const ctx = makeContext('0.7.3');
  const claude = fakeClaude({ 'delphi-debugger': DEV_BUILD });
  const outcome = await syncOnce(ctx, claude, 111);
  assert.strictEqual(claude.registry['delphi-debugger'], DEV_BUILD);
  assert.strictEqual(outcome.shown.length, 0);
  assert.match(outcome.log.join('\n'), /points at .*Debug\\DelphiDebuggerMcp\.exe, not at this installation/);
});

// ------------------------------------------------------- uninstall hook --
test('-- the uninstall hook', () => {});

const profileRoots = [];
function makeProfile() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'delphi-uninstall-'));
  profileRoots.push(root);
  const env = {
    USERPROFILE: path.join(root, 'home'),
    LOCALAPPDATA: path.join(root, 'local'),
    APPDATA: path.join(root, 'roaming')
  };
  const stableDir = path.join(env.LOCALAPPDATA, 'DelphiWin64Debugger');
  fs.mkdirSync(stableDir, { recursive: true });
  ['DelphiDebuggerMcp.exe', 'Zydis.dll', 'Zydis-LICENSE.txt', 'DelphiDebuggerMcp.exe.old1']
    .forEach((name) => fs.writeFileSync(path.join(stableDir, name), 'x'));
  const ownExtensionsDir = path.join(env.USERPROFILE, '.vscode', 'extensions');
  fs.mkdirSync(ownExtensionsDir, { recursive: true });
  // VS Code already dropped the uninstalled copy from its list.
  fs.writeFileSync(path.join(ownExtensionsDir, 'extensions.json'),
    JSON.stringify([{ identifier: { id: 'someone.else' }, version: '1.0.0', relativeLocation: 'someone.else-1.0.0' }]));
  const stableExe = path.join(stableDir, 'DelphiDebuggerMcp.exe');
  return { root: root, env: env, stableDir: stableDir, stableExe: stableExe, ownExtensionsDir: ownExtensionsDir };
}
function writeMcpJson(profile, servers, raw) {
  const dir = path.join(profile.env.APPDATA, 'Code', 'User');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'mcp.json');
  fs.writeFileSync(file, raw !== undefined ? raw : JSON.stringify({ servers: servers }, null, 4));
  return file;
}

test('uninstalled everywhere: Claude registration, VS Code mcp.json entry and stable copy go; nothing else', async () => {
  const p = makeProfile();
  const claude = fakeClaude({ 'delphi-debugger': p.stableExe, 'delphi-win64-debugger': DEV_BUILD });
  const mcpJson = writeMcpJson(p, {
    'delphi-debugger': { type: 'stdio', command: p.stableExe, args: [] },
    'someone-else': { type: 'stdio', command: 'C:\\other.exe', args: [] }
  });
  const log = await hook.cleanUpAfterUninstall({ env: p.env, ownExtensionsDir: p.ownExtensionsDir, claude: claude });
  assert.deepStrictEqual(claude.registry, { 'delphi-win64-debugger': DEV_BUILD }, 'only the stable-copy registration');
  assert.deepStrictEqual(Object.keys(JSON.parse(fs.readFileSync(mcpJson, 'utf8')).servers), ['someone-else']);
  assert.ok(!fs.existsSync(p.stableDir), 'the stable folder is gone: ' + log.join(' / '));
});

test('still installed in another editor (Cursor): nothing at all is touched', async () => {
  const p = makeProfile();
  const cursorDir = path.join(p.env.USERPROFILE, '.cursor', 'extensions');
  fs.mkdirSync(cursorDir, { recursive: true });
  fs.writeFileSync(path.join(cursorDir, 'extensions.json'),
    JSON.stringify([{ identifier: { id: 'MCA-Software.Delphi-Debugger' }, version: '0.7.3' }]));
  const claude = fakeClaude({ 'delphi-debugger': p.stableExe });
  const log = await hook.cleanUpAfterUninstall({ env: p.env, ownExtensionsDir: p.ownExtensionsDir, claude: claude });
  assert.strictEqual(claude.calls.length, 0);
  assert.ok(fs.existsSync(p.stableExe));
  assert.match(log[0], /Still installed in .*\.cursor/);
});

test('reinstalled before the restart (e.g. Setup.exe after a Marketplace uninstall): nothing is touched', async () => {
  const p = makeProfile();
  fs.writeFileSync(path.join(p.ownExtensionsDir, 'extensions.json'),
    JSON.stringify([{ identifier: { id: 'mca-software.delphi-debugger' }, version: '0.7.3', metadata: { source: 'vsix' } }]));
  const claude = fakeClaude({ 'delphi-debugger': p.stableExe });
  await hook.cleanUpAfterUninstall({ env: p.env, ownExtensionsDir: p.ownExtensionsDir, claude: claude });
  assert.strictEqual(claude.registry['delphi-debugger'], p.stableExe);
  assert.ok(fs.existsSync(p.stableExe));
});

test('a registration on a development build and an mcp.json with comments are left as they are', async () => {
  const p = makeProfile();
  const claude = fakeClaude({ 'delphi-debugger': DEV_BUILD });
  const raw = '{\n  // mine\n  "servers": { "delphi-debugger": { "type": "stdio", "command": "' +
    p.stableExe.replace(/\\/g, '\\\\') + '" } }\n}\n';
  const mcpJson = writeMcpJson(p, null, raw);
  await hook.cleanUpAfterUninstall({ env: p.env, ownExtensionsDir: p.ownExtensionsDir, claude: claude });
  assert.strictEqual(claude.registry['delphi-debugger'], DEV_BUILD);
  assert.strictEqual(fs.readFileSync(mcpJson, 'utf8'), raw);
});

test('a file someone else put in the stable folder survives, and so does the folder', async () => {
  const p = makeProfile();
  fs.writeFileSync(path.join(p.stableDir, 'notes.txt'), 'keep me');
  await hook.cleanUpAfterUninstall({ env: p.env, ownExtensionsDir: p.ownExtensionsDir, claude: fakeClaude({}) });
  assert.deepStrictEqual(fs.readdirSync(p.stableDir), ['notes.txt']);
});

test('the folders checked are this copy\'s own and every editor Setup.exe knows', () => {
  const dirs = hook.extensionsDirsToCheck({ USERPROFILE: 'C:\\Users\\u' }, 'D:\\portable\\extensions');
  assert.strictEqual(dirs[0], 'D:\\portable\\extensions');
  ['.vscode', '.vscode-insiders', '.cursor', '.windsurf', '.vscode-oss', '.trae']
    .forEach((profile) => assert.ok(dirs.indexOf(path.join('C:\\Users\\u', profile, 'extensions')) > 0, profile));
});

runQueue().then(() => {
  profileRoots.forEach((root) => { try { fs.rmSync(root, { recursive: true, force: true }); } catch (e) { /* TEMP */ } });
  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
});
