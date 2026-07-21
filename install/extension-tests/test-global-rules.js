'use strict';

/*
 * Tests for the machine-wide (shared) exception-rules file: path resolution,
 * shape-preserving writes, and the create-on-demand path.
 *
 *   node install\extension-tests\test-global-rules.js
 *
 * The point of most of these is the promise made in globalRules.js: a bare
 * array file stays a bare array, an object file keeps every other key and every
 * comment, and nothing outside the rule list is rewritten.
 */

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');
const globalRules = require(path.join(extensionDir, 'globalRules.js'));

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
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'delphi-rules-'));
  try {
    return fn(directory);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

const RULES = [{ class: 'EAbort', action: 'ignore' }, { messageRegex: 'ORA-\\d+', action: 'logStack' }];

console.log('shared rules file - location');

test('defaults to %USERPROFILE%\\.DelphiWinDebugger\\exceptionRules.json', () => {
  const resolved = globalRules.defaultGlobalRulesPath('C:\\Users\\Tester');
  assert.strictEqual(resolved, path.join('C:\\Users\\Tester', '.DelphiWinDebugger', 'exceptionRules.json'));
});

test('resolveGlobalRulesPath uses the default when no configuration overrides it', () => {
  const resolved = globalRules.resolveGlobalRulesPath(
    [{ name: 'A' }, { name: 'B' }], { homeDirectory: 'C:\\Users\\Tester' });
  assert.match(resolved.filePath, /\.DelphiWinDebugger[\\/]exceptionRules\.json$/);
  assert.strictEqual(resolved.overriddenBy, undefined);
  assert.strictEqual(resolved.enabledConfigurations, 2);
});

test('globalExceptionRulesPath overrides the location and expands ${workspaceFolder}', () => {
  const resolved = globalRules.resolveGlobalRulesPath([
    { name: 'A' },
    { name: 'Shared', globalExceptionRulesPath: '${workspaceFolder}/team/rules.json', workspaceFolder: 'C:\\proj' }
  ], { homeDirectory: 'C:\\Users\\Tester' });
  assert.strictEqual(resolved.filePath, path.normalize('C:\\proj/team/rules.json'));
  assert.strictEqual(resolved.overriddenBy, 'Shared');
});

test('an unknown variable is left visible instead of silently emptied', () => {
  assert.strictEqual(globalRules.expandVariables('${nope}/x.json', {}), '${nope}/x.json');
  assert.strictEqual(globalRules.expandVariables('${here}/x.json', { here: 'C:\\a' }), 'C:\\a/x.json');
});

test('useGlobalExceptionRules:false in every configuration is reported', () => {
  const resolved = globalRules.resolveGlobalRulesPath(
    [{ name: 'A', useGlobalExceptionRules: false }], { homeDirectory: 'C:\\Users\\Tester' });
  assert.strictEqual(resolved.enabledConfigurations, 0);
  assert.strictEqual(resolved.totalConfigurations, 1);
});

console.log('shared rules file - parsing');

test('reads the object shape', () => {
  const parsed = globalRules.parseGlobalRules('{ "exceptionRules": [ { "action": "break" } ] }');
  assert.strictEqual(parsed.shape, 'object');
  assert.deepStrictEqual(parsed.rules, [{ action: 'break' }]);
});

test('reads the bare-array shape', () => {
  const parsed = globalRules.parseGlobalRules('[ { "action": "ignore" } ]');
  assert.strictEqual(parsed.shape, 'array');
  assert.deepStrictEqual(parsed.rules, [{ action: 'ignore' }]);
});

test('an empty or whitespace-only file is not an error', () => {
  assert.deepStrictEqual(globalRules.parseGlobalRules('').rules, []);
  assert.strictEqual(globalRules.parseGlobalRules('   \r\n').shape, 'empty');
});

test('an object without exceptionRules yields an empty list', () => {
  assert.deepStrictEqual(globalRules.parseGlobalRules('{ "other": 1 }').rules, []);
});

test('comments are accepted', () => {
  const parsed = globalRules.parseGlobalRules('// header\r\n{ "exceptionRules": [] }');
  assert.strictEqual(parsed.shape, 'object');
});

test('malformed JSON and a scalar root are rejected', () => {
  assert.throws(() => globalRules.parseGlobalRules('{ "exceptionRules": '), /.+/);
  assert.throws(() => globalRules.parseGlobalRules('42'), /object or a JSON array/);
});

console.log('shared rules file - shape-preserving writes');

test('an object file stays an object and keeps its other keys and comments', () => {
  const text = [
    '{',
    '  // team baseline - do not remove',
    '  "note": "keep me",',
    '  "exceptionRules": [',
    '    { "class": "EOld", "action": "break" }',
    '  ],',
    '  "trailing": true',
    '}',
    ''
  ].join('\r\n');
  const updated = globalRules.applyGlobalRules(text, RULES);
  assert.ok(updated.trimStart().startsWith('{'), 'must stay an object');
  assert.match(updated, /\/\/ team baseline - do not remove/);
  assert.match(updated, /"note": "keep me"/);
  assert.match(updated, /"trailing": true/);
  assert.match(updated, /"class": "EAbort"/);
  assert.ok(updated.indexOf('EOld') === -1, 'old rules should be replaced');
  const reparsed = globalRules.parseGlobalRules(updated);
  assert.strictEqual(reparsed.shape, 'object');
  assert.deepStrictEqual(reparsed.rules, RULES);
});

test('a bare array file stays a bare array', () => {
  const text = '// shared rules\r\n[\r\n  { "class": "EOld", "action": "break" }\r\n]\r\n';
  const updated = globalRules.applyGlobalRules(text, RULES);
  const reparsed = globalRules.parseGlobalRules(updated);
  assert.strictEqual(reparsed.shape, 'array');
  assert.deepStrictEqual(reparsed.rules, RULES);
  assert.match(updated, /\/\/ shared rules/);
});

test('an object without exceptionRules gets the key added, not a rewrite', () => {
  const text = '{\r\n  "note": "keep me"\r\n}\r\n';
  const updated = globalRules.applyGlobalRules(text, RULES);
  assert.match(updated, /"note": "keep me"/);
  assert.deepStrictEqual(globalRules.parseGlobalRules(updated).rules, RULES);
});

test('an empty file becomes an object file with CRLF', () => {
  const updated = globalRules.applyGlobalRules('', RULES);
  assert.ok(!/[^\r]\n/.test(updated), 'must not contain a bare LF');
  assert.strictEqual(globalRules.parseGlobalRules(updated).shape, 'object');
  assert.deepStrictEqual(globalRules.parseGlobalRules(updated).rules, RULES);
});

test('the existing EOL style is preserved', () => {
  const crlf = globalRules.applyGlobalRules('{\r\n  "exceptionRules": []\r\n}\r\n', RULES);
  assert.ok(!/[^\r]\n/.test(crlf), 'introduced a bare LF into a CRLF file');
  const lf = globalRules.applyGlobalRules('{\n  "exceptionRules": []\n}\n', RULES);
  assert.ok(lf.indexOf('\r\n') === -1, 'introduced CRLF into an LF file');
});

test('an empty rule list writes []', () => {
  assert.match(globalRules.applyGlobalRules('{ "exceptionRules": [ { "action": "break" } ] }', []),
    /"exceptionRules": \[\]/);
});

test('only the rule array range is touched', () => {
  const text = '{\r\n  "a": 1,\r\n  "exceptionRules": [],\r\n  "b": 2\r\n}\r\n';
  const edit = globalRules.computeGlobalRulesEdit(text, RULES);
  assert.strictEqual(text.substr(edit.offset, edit.length), '[]');
});

console.log('shared rules file - disk');

test('reading a missing file reports exists:false and no rules', () => {
  withTempDirectory((directory) => {
    const file = path.join(directory, 'nope', 'exceptionRules.json');
    const read = globalRules.readGlobalRulesFile(file);
    assert.strictEqual(read.exists, false);
    assert.deepStrictEqual(read.rules, []);
  });
});

test('a malformed file is reported, not thrown', () => {
  withTempDirectory((directory) => {
    const file = path.join(directory, 'exceptionRules.json');
    fs.writeFileSync(file, '{ oops', 'utf8');
    const read = globalRules.readGlobalRulesFile(file);
    assert.strictEqual(read.shape, 'invalid');
    assert.ok(read.error);
  });
});

test('a BOM does not break parsing', () => {
  withTempDirectory((directory) => {
    const file = path.join(directory, 'exceptionRules.json');
    fs.writeFileSync(file, '﻿{ "exceptionRules": [ { "action": "break" } ] }', 'utf8');
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(file).rules, [{ action: 'break' }]);
  });
});

test('ensureGlobalRulesFile creates the directory and an empty rules file', () => {
  withTempDirectory((directory) => {
    const file = path.join(directory, '.DelphiWinDebugger', 'exceptionRules.json');
    assert.strictEqual(globalRules.ensureGlobalRulesFile(file), true);
    assert.ok(fs.existsSync(file));
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(file).rules, []);
    // Second call must not touch it.
    fs.writeFileSync(file, '[ { "action": "break" } ]', 'utf8');
    assert.strictEqual(globalRules.ensureGlobalRulesFile(file), false);
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(file).rules, [{ action: 'break' }]);
  });
});

test('writeGlobalRulesFile creates on demand and preserves an array file', () => {
  withTempDirectory((directory) => {
    const file = path.join(directory, 'sub', 'exceptionRules.json');
    assert.strictEqual(globalRules.writeGlobalRulesFile(file, RULES), true);
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(file).rules, RULES);

    const arrayFile = path.join(directory, 'array.json');
    fs.writeFileSync(arrayFile, '[]\r\n', 'utf8');
    globalRules.writeGlobalRulesFile(arrayFile, RULES);
    const read = globalRules.readGlobalRulesFile(arrayFile);
    assert.strictEqual(read.shape, 'array');
    assert.deepStrictEqual(read.rules, RULES);
  });
});

console.log('');
console.log(passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
