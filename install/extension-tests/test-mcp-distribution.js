'use strict';

/*
 * Tests for mcpServer.js: the stable copy of DelphiDebuggerMcp.exe the
 * extension maintains for agents outside VS Code (rename-then-copy, because a
 * running exe cannot be overwritten but can be renamed), the guarded VS Code
 * MCP registration, and the "Register MCP Server with Claude Code" command.
 *
 * The refresh runs against a REAL temporary directory: the whole point is the
 * filesystem sequence, and a locked file is simulated by a rename/unlink that
 * refuses.
 *
 *   node install\extension-tests\test-mcp-distribution.js
 */

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const extensionDir = path.join(__dirname, '..', 'mca-software.delphi-debugger');
const mcp = require(path.join(extensionDir, 'mcpServer.js'));

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

function scratch() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'delphi-mcp-dist-'));
  return {
    bundled: (() => { const d = path.join(dir, 'ext'); fs.mkdirSync(d); return d; })(),
    stable: path.join(dir, 'stable'),
    root: dir
  };
}

function write(dir, name, content, mtime) {
  const p = path.join(dir, name);
  fs.writeFileSync(p, content);
  if (mtime) fs.utimesSync(p, mtime, mtime);
  return p;
}

test('-- mcpServer: deciding whether to refresh', () => {});

test('no stable copy -> refresh; identical size and time -> not; newer or different size -> refresh', () => {
  const bundled = { exists: true, size: 100, mtimeMs: 2000 };
  assert.strictEqual(mcp.needsRefresh(bundled, undefined), true);
  assert.strictEqual(mcp.needsRefresh(bundled, { exists: false }), true);
  assert.strictEqual(mcp.needsRefresh(bundled, { exists: true, size: 100, mtimeMs: 2000 }), false);
  assert.strictEqual(mcp.needsRefresh(bundled, { exists: true, size: 100, mtimeMs: 3000 }), false, 'a newer stable copy (from Setup.exe) is kept');
  assert.strictEqual(mcp.needsRefresh(bundled, { exists: true, size: 100, mtimeMs: 1000 }), true);
  assert.strictEqual(mcp.needsRefresh(bundled, { exists: true, size: 101, mtimeMs: 2000 }), true);
  assert.strictEqual(mcp.needsRefresh({ exists: false }, undefined), false, 'nothing bundled, nothing to do');
});

test('the parked name is the first .oldN not taken', () => {
  const taken = new Set(['C:\\s\\x.exe.old1', 'C:\\s\\x.exe.old2']);
  assert.strictEqual(mcp.nextFreeOldName('C:\\s', 'x.exe', (p) => taken.has(p)), 'C:\\s\\x.exe.old3');
  assert.strictEqual(mcp.nextFreeOldName('C:\\s', 'y.exe', () => false), 'C:\\s\\y.exe.old1');
});

test('the stable folder is %LOCALAPPDATA%\\DelphiWin64Debugger, the one Setup.exe uses', () => {
  assert.strictEqual(mcp.stableServerPath({ LOCALAPPDATA: 'C:\\Users\\me\\AppData\\Local' }),
    'C:\\Users\\me\\AppData\\Local\\DelphiWin64Debugger\\DelphiDebuggerMcp.exe');
  assert.strictEqual(mcp.stableServerPath({}), undefined);
});

test('-- mcpServer: the refresh on disk', () => {});

test('first activation: the server and its companions are copied, and the copy carries the bundle\'s mtime', () => {
  const s = scratch();
  const old = new Date(Date.now() - 3600 * 1000);
  write(s.bundled, mcp.SERVER_EXE, 'server v2', old);
  write(s.bundled, 'Zydis.dll', 'zydis', old);
  write(s.bundled, 'Zydis-LICENSE.txt', 'mit', old);
  const outcome = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable });
  assert.deepStrictEqual(outcome.refreshed.map((p) => path.basename(p)).sort(), ['DelphiDebuggerMcp.exe', 'Zydis-LICENSE.txt', 'Zydis.dll']);
  assert.deepStrictEqual(outcome.renamed, []);
  assert.strictEqual(fs.readFileSync(path.join(s.stable, mcp.SERVER_EXE), 'utf8'), 'server v2');
  const copied = fs.statSync(path.join(s.stable, mcp.SERVER_EXE)).mtimeMs;
  const source = fs.statSync(path.join(s.bundled, mcp.SERVER_EXE)).mtimeMs;
  assert.ok(Math.abs(copied - source) < 2000, 'mtime stamped from the bundle: ' + copied + ' vs ' + source);
  // Second activation with the same bundle: nothing happens.
  const again = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable });
  assert.deepStrictEqual(again.refreshed, []);
  fs.rmSync(s.root, { recursive: true, force: true });
});

test('a newer bundle: the running exe is renamed to .old1, the new one takes its name, the parked one is purged', () => {
  const s = scratch();
  fs.mkdirSync(s.stable);
  write(s.stable, mcp.SERVER_EXE, 'server v1', new Date(Date.now() - 7200 * 1000));
  write(s.bundled, mcp.SERVER_EXE, 'server v2', new Date(Date.now() - 60 * 1000));
  const renames = [];
  const realFs = Object.assign({}, fs, {
    renameSync: (a, b) => { renames.push(path.basename(b)); return fs.renameSync(a, b); }
  });
  const outcome = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable, fs: realFs });
  assert.deepStrictEqual(renames, ['DelphiDebuggerMcp.exe.old1']);
  assert.strictEqual(fs.readFileSync(path.join(s.stable, mcp.SERVER_EXE), 'utf8'), 'server v2');
  assert.strictEqual(outcome.purged.length, 1, 'the parked file was not locked, so it went at once');
  assert.deepStrictEqual(fs.readdirSync(s.stable), ['DelphiDebuggerMcp.exe']);
  fs.rmSync(s.root, { recursive: true, force: true });
});

test('a locked parked file survives, and the next refresh parks under .old2 and purges what it can', () => {
  const s = scratch();
  fs.mkdirSync(s.stable);
  write(s.stable, mcp.SERVER_EXE, 'server v1', new Date(Date.now() - 7200 * 1000));
  write(s.bundled, mcp.SERVER_EXE, 'server v2', new Date(Date.now() - 3600 * 1000));
  // .old1 is "still running": its unlink refuses.
  const locked = new Set([path.join(s.stable, mcp.SERVER_EXE + '.old1')]);
  const lockingFs = Object.assign({}, fs, {
    unlinkSync: (p) => { if (locked.has(p)) throw new Error('EBUSY'); return fs.unlinkSync(p); }
  });
  let outcome = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable, fs: lockingFs });
  assert.deepStrictEqual(outcome.purged, [], '.old1 is locked');
  assert.ok(fs.existsSync(path.join(s.stable, mcp.SERVER_EXE + '.old1')));

  // A second update while the old session still runs: .old1 is taken.
  write(s.bundled, mcp.SERVER_EXE, 'server v3', new Date(Date.now() - 60 * 1000));
  outcome = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable, fs: lockingFs });
  assert.deepStrictEqual(outcome.renamed.map((p) => path.basename(p)), ['DelphiDebuggerMcp.exe.old2']);
  assert.deepStrictEqual(outcome.purged.map((p) => path.basename(p)), ['DelphiDebuggerMcp.exe.old2'], 'v2 was not locked');
  assert.strictEqual(fs.readFileSync(path.join(s.stable, mcp.SERVER_EXE), 'utf8'), 'server v3');

  // The old session ends; a later activation with an unchanged bundle purges .old1.
  locked.clear();
  outcome = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable, fs: lockingFs });
  assert.deepStrictEqual(outcome.refreshed, []);
  assert.deepStrictEqual(outcome.purged.map((p) => path.basename(p)), ['DelphiDebuggerMcp.exe.old1']);
  assert.deepStrictEqual(fs.readdirSync(s.stable), ['DelphiDebuggerMcp.exe']);
  fs.rmSync(s.root, { recursive: true, force: true });
});

test('a copy that fails is reported, not thrown, and the other files still go', () => {
  const s = scratch();
  write(s.bundled, mcp.SERVER_EXE, 'server');
  write(s.bundled, 'Zydis.dll', 'zydis');
  const failingFs = Object.assign({}, fs, {
    copyFileSync: (a, b) => { if (/Zydis\.dll$/.test(b)) throw new Error('EACCES'); return fs.copyFileSync(a, b); }
  });
  const outcome = mcp.refreshStableCopy({ bundledDir: s.bundled, stableDir: s.stable, fs: failingFs });
  assert.deepStrictEqual(outcome.refreshed.map((p) => path.basename(p)), ['DelphiDebuggerMcp.exe']);
  assert.deepStrictEqual(outcome.failed, ['Zydis.dll: EACCES']);
  assert.match(mcp.describeOutcome(outcome), /refreshed .*DelphiDebuggerMcp\.exe; could not refresh Zydis\.dll: EACCES/);
  assert.strictEqual(mcp.describeOutcome({ refreshed: [], renamed: [], purged: [], failed: [] }), '', 'nothing happened, nothing logged');
  fs.rmSync(s.root, { recursive: true, force: true });
});

test('no stable dir (LOCALAPPDATA unset) -> nothing happens, nothing thrown', () => {
  const outcome = mcp.refreshStableCopy({ bundledDir: 'C:\\x', stableDir: undefined });
  assert.deepStrictEqual(outcome.refreshed, []);
});

test('-- mcpServer: VS Code registration', () => {});

test('registered through vscode.lm when the API exists, as a stdio definition on the bundled exe', () => {
  const registrations = [];
  class McpStdioServerDefinition {
    constructor(label, command, args, env, version) { Object.assign(this, { label, command, args, env, version }); }
  }
  const vscode = {
    lm: { registerMcpServerDefinitionProvider: (id, provider) => { registrations.push({ id, provider }); return { dispose() {} }; } },
    McpStdioServerDefinition: McpStdioServerDefinition
  };
  const disposable = mcp.registerDefinitionProvider(vscode, 'C:\\ext\\DelphiDebuggerMcp.exe', '0.7.0');
  assert.ok(disposable);
  assert.strictEqual(registrations[0].id, 'delphi-debugger');
  const defs = registrations[0].provider.provideMcpServerDefinitions();
  assert.strictEqual(defs.length, 1);
  assert.strictEqual(defs[0].label, 'Delphi Debugger');
  assert.strictEqual(defs[0].command, 'C:\\ext\\DelphiDebuggerMcp.exe');
  assert.deepStrictEqual(defs[0].args, []);
  assert.strictEqual(defs[0].version, '0.7.0');
});

test('an editor without vscode.lm (pre-1.101, or another editor of the family) -> undefined, no throw', () => {
  assert.strictEqual(mcp.registerDefinitionProvider({}, 'x', '1'), undefined);
  assert.strictEqual(mcp.registerDefinitionProvider({ lm: {} }, 'x', '1'), undefined);
  assert.strictEqual(mcp.registerDefinitionProvider({ lm: { registerMcpServerDefinitionProvider() {} } }, 'x', '1'), undefined,
    'the definition class is needed too');
});

test('-- mcpServer: registering with Claude Code', () => {});

test('the command lines mirror register-mcp.ps1: remove the legacy name, remove, add under delphi-debugger', () => {
  assert.deepStrictEqual(mcp.claudeCommandLines('C:\\Users\\me\\AppData\\Local\\DelphiWin64Debugger\\DelphiDebuggerMcp.exe'), [
    'claude mcp remove delphi-win64-debugger -s user',
    'claude mcp remove delphi-debugger -s user',
    'claude mcp add delphi-debugger -s user -- "C:\\Users\\me\\AppData\\Local\\DelphiWin64Debugger\\DelphiDebuggerMcp.exe"'
  ]);
});

test('with claude on PATH: the three commands run in order and success is reported', async () => {
  const ran = [];
  const shown = { info: [], warn: [] };
  const ok = await mcp.registerWithClaudeCode('C:\\s\\DelphiDebuggerMcp.exe', {
    hasClaude: async () => true,
    exec: (line, cb) => { ran.push(line); setImmediate(() => cb(/remove/.test(line) ? new Error('No MCP server found') : null, '', '')); },
    showInformation: (t) => shown.info.push(t),
    showWarning: (t) => shown.warn.push(t)
  });
  assert.strictEqual(ok, true);
  assert.deepStrictEqual(ran, mcp.claudeCommandLines('C:\\s\\DelphiDebuggerMcp.exe'));
  assert.strictEqual(shown.warn.length, 0, 'a failing remove is not an error');
  assert.match(shown.info[0], /Registered .* "delphi-debugger"/);
});

test('without claude on PATH: skipped with a message that shows the manual command', async () => {
  const shown = { info: [], warn: [] };
  let execCalled = false;
  const ok = await mcp.registerWithClaudeCode('C:\\s\\DelphiDebuggerMcp.exe', {
    hasClaude: async () => false,
    exec: () => { execCalled = true; },
    showInformation: (t) => shown.info.push(t),
    showWarning: (t) => shown.warn.push(t)
  });
  assert.strictEqual(ok, false);
  assert.strictEqual(execCalled, false);
  assert.match(shown.info[0], /claude CLI is not on PATH/);
  assert.match(shown.info[0], /claude mcp add delphi-debugger -s user -- "C:\\s\\DelphiDebuggerMcp\.exe"/);
});

test('a failing add is reported with claude\'s own text', async () => {
  const shown = { info: [], warn: [] };
  const ok = await mcp.registerWithClaudeCode('C:\\s\\DelphiDebuggerMcp.exe', {
    hasClaude: async () => true,
    exec: (line, cb) => setImmediate(() => cb(/ add /.test(line) ? new Error('exit 1') : null, '', /add/.test(line) ? 'Invalid scope' : '')),
    showInformation: (t) => shown.info.push(t),
    showWarning: (t) => shown.warn.push(t)
  });
  assert.strictEqual(ok, false);
  assert.match(shown.warn[0], /claude mcp add failed: Invalid scope/);
});

runQueue().then(() => {
  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  process.exit(failed === 0 ? 0 : 1);
});
