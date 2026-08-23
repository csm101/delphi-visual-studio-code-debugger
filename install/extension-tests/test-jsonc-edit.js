'use strict';

/*
 * Regression tests for the extension's JSONC editing and exceptionRules
 * validation. Plain Node, no dependencies, no build step:
 *
 *   node install\extension-tests\test-jsonc-edit.js
 *
 * The important one is "comments survive": it proves that writing rules back
 * into a comment-heavy launch.json leaves every comment - and every byte
 * outside the exceptionRules value - untouched.
 */

const assert = require('assert');
const path = require('path');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');
const jsonc = require(path.join(extensionDir, 'jsonc.js'));
const rules = require(path.join(extensionDir, 'rules.js'));

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

// A launch.json that looks like a real user's: comments before, inside and
// after the configurations array, a trailing comma, and a block comment.
const LAUNCH_JSON = [
  '{',
  '  // See https://go.microsoft.com/fwlink/?linkid=830387',
  '  "version": "0.2.0",',
  '',
  '  /* Two configurations: the GUI host and the console tool.',
  '     Keep the console one last, F5 picks the first. */',
  '  "configurations": [',
  '    {',
  '      "name": "Debug SampleApp",',
  '      "type": "delphi-win64",',
  '      "request": "launch",',
  '      // The exe is produced by scripts/build_debug.bat',
  '      "program": "${workspaceFolder}/Win64/Debug/SampleApp.exe",',
  '      "exceptionRules": [',
  '        // EAbort is control-flow noise.',
  '        { "class": "EAbort", "action": "ignore" }',
  '      ],',
  '      "stopAtEntry": false',
  '    },',
  '    {',
  '      // Second config: no exception rules at all.',
  '      "name": "Debug Console Tool",',
  '      "type": "delphi-win64",',
  '      "request": "launch",',
  '      "program": "${workspaceFolder}/Win64/Debug/Tool.exe" // note the path',
  '    },',
  '  ]',
  '  // trailing comment at the end of the object',
  '}',
  ''
].join('\r\n');

const ALL_COMMENTS = [
  '// See https://go.microsoft.com/fwlink/?linkid=830387',
  '/* Two configurations: the GUI host and the console tool.',
  'Keep the console one last, F5 picks the first. */',
  '// The exe is produced by scripts/build_debug.bat',
  '// Second config: no exception rules at all.',
  '// note the path',
  '// trailing comment at the end of the object'
];

function configurationNodeAt(text, index) {
  const root = jsonc.parseTree(text);
  const configurations = jsonc.findNodeAtPath(root, ['configurations']);
  assert.ok(configurations && configurations.type === 'array', 'configurations array not found');
  return configurations.children[index];
}

function setRules(text, configIndex, newRules) {
  const node = configurationNodeAt(text, configIndex);
  const edit = jsonc.computeSetPropertyEdit(text, node, 'exceptionRules',
    (baseIndent, eol) => rules.serializeRules(newRules, baseIndent, eol));
  return jsonc.applyEdit(text, edit);
}

console.log('jsonc parser');

test('parses comments, trailing commas and nested values', () => {
  const value = jsonc.getNodeValue(jsonc.parseTree(LAUNCH_JSON));
  assert.strictEqual(value.version, '0.2.0');
  assert.strictEqual(value.configurations.length, 2);
  assert.strictEqual(value.configurations[0].name, 'Debug SampleApp');
  assert.deepStrictEqual(value.configurations[0].exceptionRules,
    [{ class: 'EAbort', action: 'ignore' }]);
  assert.strictEqual(value.configurations[1].exceptionRules, undefined);
});

test('parses escapes, unicode, numbers and literals', () => {
  const value = jsonc.getNodeValue(jsonc.parseTree(
    '{ "a": "x\\ty\\u0041", "b": -12.5e2, "c": true, "d": null, "e": [] }'));
  assert.deepStrictEqual(value, { a: 'x\tyA', b: -1250, c: true, d: null, e: [] });
});

test('rejects malformed JSON', () => {
  assert.throws(() => jsonc.parseTree('{ "a": }'), /Unexpected token|Expected/);
  assert.throws(() => jsonc.parseTree('{ "a": 1 '), /Unterminated object/);
});

console.log('targeted edit');

test('comments survive a rewrite of exceptionRules', () => {
  const updated = setRules(LAUNCH_JSON, 0, [
    { classIs: 'EDatabaseError', action: 'ignore' },
    { messageRegex: 'ORA-\\d+', action: 'logStack' },
    { action: 'break' }
  ]);
  for (const comment of ALL_COMMENTS) {
    assert.ok(updated.includes(comment), 'lost comment: ' + comment);
  }
  // The only comment that may disappear is the one that lived *inside* the old
  // exceptionRules array, because that array is what we replaced.
  assert.ok(!updated.includes('// EAbort is control-flow noise.'));
  const reparsed = jsonc.getNodeValue(jsonc.parseTree(updated));
  assert.deepStrictEqual(reparsed.configurations[0].exceptionRules, [
    { classIs: 'EDatabaseError', action: 'ignore' },
    { messageRegex: 'ORA-\\d+', action: 'logStack' },
    { action: 'break' }
  ]);
});

test('everything outside the edited range is byte-identical', () => {
  const node = configurationNodeAt(LAUNCH_JSON, 0);
  const edit = jsonc.computeSetPropertyEdit(LAUNCH_JSON, node, 'exceptionRules',
    (baseIndent, eol) => rules.serializeRules([{ action: 'break' }], baseIndent, eol));
  const updated = jsonc.applyEdit(LAUNCH_JSON, edit);
  assert.strictEqual(updated.slice(0, edit.offset), LAUNCH_JSON.slice(0, edit.offset));
  assert.strictEqual(updated.slice(edit.offset + edit.newText.length),
    LAUNCH_JSON.slice(edit.offset + edit.length));
});

test('other configurations are not touched', () => {
  const updated = setRules(LAUNCH_JSON, 0, [{ action: 'ignore' }]);
  const secondConfig = '      "program": "${workspaceFolder}/Win64/Debug/Tool.exe" // note the path';
  assert.ok(updated.includes(secondConfig));
  const reparsed = jsonc.getNodeValue(jsonc.parseTree(updated));
  assert.strictEqual(reparsed.configurations[1].name, 'Debug Console Tool');
  assert.strictEqual(reparsed.configurations[1].program,
    '${workspaceFolder}/Win64/Debug/Tool.exe');
});

test('inserts exceptionRules when the property is absent', () => {
  const updated = setRules(LAUNCH_JSON, 1, [{ class: 'EAbort', action: 'ignore' }]);
  const reparsed = jsonc.getNodeValue(jsonc.parseTree(updated));
  assert.deepStrictEqual(reparsed.configurations[1].exceptionRules,
    [{ class: 'EAbort', action: 'ignore' }]);
  assert.strictEqual(reparsed.configurations[0].exceptionRules.length, 1);
  for (const comment of ALL_COMMENTS) {
    assert.ok(updated.includes(comment), 'lost comment: ' + comment);
  }
});

test('keeps the file EOL style', () => {
  const updated = setRules(LAUNCH_JSON, 0, [{ action: 'break' }, { action: 'log' }]);
  assert.ok(!/[^\r]\n/.test(updated), 'introduced a bare LF into a CRLF file');
});

test('an empty rule list writes []', () => {
  const updated = setRules(LAUNCH_JSON, 0, []);
  assert.ok(/"exceptionRules": \[\]/.test(updated));
});

test('handles an empty configuration object', () => {
  const text = '{\r\n  "configurations": [\r\n    {}\r\n  ]\r\n}\r\n';
  const updated = setRules(text, 0, [{ action: 'break' }]);
  const reparsed = jsonc.getNodeValue(jsonc.parseTree(updated));
  assert.deepStrictEqual(reparsed.configurations[0].exceptionRules, [{ action: 'break' }]);
});

console.log('rule validation');

test('accepts the README examples', () => {
  const problems = rules.validateRules([
    { class: 'EAbort', action: 'ignore' },
    { messageRegex: 'ORA-\\d+', action: 'logStack' },
    { class: 'EAccessViolation', unit: 'OracleData', lineFrom: 2700, lineTo: 2800, action: 'break' },
    { unit: '*unknown*', action: 'log' },
    { classIs: 'EDatabaseError', action: 'ignore' },
    { class: ['EMyDomainError', 'EValidationError'], action: 'break' },
    { action: 'break' }
  ]);
  assert.deepStrictEqual(problems, []);
});

test('accepts every spelling of a native exception code', () => {
  assert.deepStrictEqual(rules.validateRules([
    { code: '0xC0000005', action: 'ignore' },
    { code: '$406D1388', action: 'log' },
    { code: 3221225477, action: 'break' },
    { code: -1073741819, action: 'break' },
    { code: ['0x406D1388', '$C0000005', 1073807364], action: 'ignore' }
  ]), []);
  assert.strictEqual(rules.parseExceptionCode('0xC0000005'), 3221225477);
  assert.strictEqual(rules.parseExceptionCode('$C0000005'), 3221225477);
  assert.strictEqual(rules.parseExceptionCode('3221225477'), 3221225477);
  assert.strictEqual(rules.parseExceptionCode(-1073741819), 3221225477);
});

test('rejects a code that is not a Win32 exception code', () => {
  assert.match(rules.validateRules([{ code: 'C0000005', action: 'break' }])[0].message,
    /not a valid Win32 exception code/);
  assert.match(rules.validateRules([{ code: '0xZZ', action: 'break' }])[0].message,
    /not a valid Win32 exception code/);
  assert.match(rules.validateRules([{ code: 0, action: 'break' }])[0].message,
    /not a valid Win32 exception code/);
  assert.match(rules.validateRules([{ code: [], action: 'break' }])[0].message,
    /at least one exception code/);
});

test('a code rule survives a round-trip through the editor representation', () => {
  // The rules editor keeps every field as text; a `code` that came back as a
  // bare string must not be dropped or turned into something else.
  assert.strictEqual(rules.codesToText('0x406D1388'), '0x406D1388');
  assert.strictEqual(rules.codesToText(['0x406D1388', 1073807364]), '0x406D1388, 1073807364');
  assert.strictEqual(rules.textToCodes('0x406D1388'), '0x406D1388');
  assert.deepStrictEqual(rules.textToCodes(' 0x406D1388 , $C0000005 '), ['0x406D1388', '$C0000005']);
  assert.strictEqual(rules.textToCodes('1073807364'), 1073807364);
  assert.strictEqual(rules.textToCodes('  '), undefined);
  assert.deepStrictEqual(
    rules.normalizeRule({ action: 'ignore', code: '0x406D1388' }),
    { code: '0x406D1388', action: 'ignore' });
});

test('rejects an unknown field', () => {
  const problems = rules.validateRules([{ clazz: 'EAbort', action: 'ignore' }]);
  assert.strictEqual(problems.length, 1);
  assert.match(problems[0].message, /unknown field "clazz"/);
});

test('rejects a missing or invalid action', () => {
  assert.match(rules.validateRules([{ class: 'EAbort' }])[0].message, /action is required/);
  assert.match(rules.validateRules([{ action: 'stop' }])[0].message, /invalid action "stop"/);
});

test('rejects a regex that does not compile', () => {
  const problems = rules.validateRules([{ messageRegex: 'ORA-(\\d+', action: 'log' }]);
  assert.strictEqual(problems.length, 1);
  assert.strictEqual(problems[0].field, 'messageRegex');
  assert.match(problems[0].message, /not a valid regular expression/);
});

test('rejects bad line numbers and inverted ranges', () => {
  assert.match(rules.validateRules([{ line: 'abc', action: 'break' }])[0].message, /integer/);
  assert.match(rules.validateRules([{ lineFrom: 0, action: 'break' }])[0].message, /1 or greater/);
  assert.match(rules.validateRules([{ lineFrom: 90, lineTo: 10, action: 'break' }])[0].message,
    /greater than or equal to lineFrom/);
});

test('rejects empty class lists and non-string names', () => {
  assert.match(rules.validateRules([{ class: [], action: 'break' }])[0].message, /at least one name/);
  assert.match(rules.validateRules([{ classIs: [1, 2], action: 'break' }])[0].message, /non-empty class names/);
});

console.log('serialization');

test('writes match criteria before the action, one rule per line', () => {
  const text = rules.serializeRules(
    [{ action: 'ignore', class: 'EAbort' }, { action: 'break' }], '      ', '\n');
  assert.strictEqual(text, [
    '[',
    '        { "class": "EAbort", "action": "ignore" },',
    '        { "action": "break" }',
    '      ]'
  ].join('\n'));
});

test('names round-trip through the comma-separated UI representation', () => {
  assert.strictEqual(rules.textToNames('EAbort'), 'EAbort');
  assert.deepStrictEqual(rules.textToNames(' EA , EB '), ['EA', 'EB']);
  assert.strictEqual(rules.textToNames('   '), undefined);
  assert.strictEqual(rules.namesToText(['EA', 'EB']), 'EA, EB');
});

test('normalizeRule drops blanks and orders keys', () => {
  const normalized = rules.normalizeRule({ action: 'break', message: '', unit: 'Foo', class: 'EBar' });
  assert.deepStrictEqual(Object.keys(normalized), ['class', 'unit', 'action']);
});

console.log('');
console.log(passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
