'use strict';

/*
 * Smoke test for the rules-editor webview script (media/rulesEditor.js).
 *
 * VS Code cannot be launched here, so the script is executed against a minimal
 * DOM stub. This does not prove the UI looks right - it proves the render,
 * reorder, edit, validate and save paths execute without errors and produce the
 * expected model.
 *
 *   node install\extension-tests\test-webview.js
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');

// ---------------------------------------------------------------- DOM stub --

class StubElement {
  constructor(tagName) {
    this.tagName = tagName;
    this.childNodes = [];
    this.dataset = {};
    this.className = '';
    this.listeners = {};
    this.attributes = {};
    this._text = '';
    this.disabled = false;
  }
  set textContent(value) {
    this._text = String(value);
    this.childNodes = [];
  }
  get textContent() {
    return this._text + this.childNodes.map((child) => child.textContent).join('');
  }
  appendChild(child) {
    this.childNodes.push(child);
    return child;
  }
  addEventListener(type, handler) {
    (this.listeners[type] = this.listeners[type] || []).push(handler);
  }
  setAttribute(name, value) {
    this.attributes[name] = value;
  }
  get classList() {
    const self = this;
    return {
      toggle(name, on) {
        const parts = self.className.split(' ').filter((part) => part && part !== name);
        if (on) parts.push(name);
        self.className = parts.join(' ');
      },
      contains(name) {
        return self.className.split(' ').indexOf(name) !== -1;
      }
    };
  }
  fire(type) {
    (this.listeners[type] || []).forEach((handler) => handler({ target: this }));
  }
  walk(visit) {
    visit(this);
    this.childNodes.forEach((child) => child.walk(visit));
  }
  querySelectorAll(selector) {
    const match = /^\[data-([a-z-]+)(?:="([^"]*)")?\]$/.exec(selector);
    assert.ok(match, 'stub supports only [data-*] selectors, got: ' + selector);
    const key = match[1].replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
    const wanted = match[2];
    const found = [];
    this.walk((node) => {
      const value = node.dataset[key];
      if (value === undefined) return;
      if (wanted === undefined || value === wanted) found.push(node);
    });
    return found;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
}

function createDocument() {
  const root = new StubElement('body');
  const app = new StubElement('div');
  app.id = 'app';
  root.appendChild(app);
  return {
    createElement: (tag) => new StubElement(tag),
    getElementById(id) {
      let found = null;
      root.walk((node) => {
        if (node.id === id && !found) found = node;
      });
      return found;
    },
    querySelectorAll: (selector) => root.querySelectorAll(selector),
    querySelector: (selector) => root.querySelector(selector),
    root: root
  };
}

function findByTitle(document, title) {
  const found = [];
  document.root.walk((node) => {
    if (node.title === title) found.push(node);
  });
  return found;
}

function findAll(document, predicate) {
  const found = [];
  document.root.walk((node) => {
    if (predicate(node)) found.push(node);
  });
  return found;
}

// ------------------------------------------------------------------- setup --

function loadWebview(initialState) {
  const document = createDocument();
  const posted = [];
  const messageListeners = [];
  const context = {
    console: console,
    JSON: JSON,
    RegExp: RegExp,
    Number: Number,
    Object: Object,
    Array: Array,
    String: String,
    Math: Math,
    isFinite: isFinite,
    document: document,
    acquireVsCodeApi: () => ({ postMessage: (message) => posted.push(message) })
  };
  context.window = {
    INITIAL_STATE: initialState,
    DelphiRules: require(path.join(extensionDir, 'rules.js')),
    addEventListener: (type, handler) => {
      if (type === 'message') messageListeners.push(handler);
    }
  };
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(extensionDir, 'media', 'rulesEditor.js'), 'utf8'),
    context, { filename: 'rulesEditor.js' });
  return {
    document: document,
    posted: posted,
    post: (message) => messageListeners.forEach((handler) => handler({ data: message }))
  };
}

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
    console.log('       ' + (error && error.stack ? error.stack.split('\n')[0] : error));
  }
}

const SAMPLE = {
  configurationName: 'Debug SampleApp',
  documentLabel: 'SampleApp/.vscode/launch.json',
  readOnly: false,
  rules: [
    { class: 'EAbort', action: 'ignore' },
    { messageRegex: 'ORA-\\d+', action: 'logStack' },
    { action: 'break' }
  ]
};

console.log('rules editor webview');

test('renders one card per rule, numbered in evaluation order', () => {
  const view = loadWebview(SAMPLE);
  const cards = view.document.querySelectorAll('[data-rule-index]');
  assert.strictEqual(cards.length, 3);
  const badges = findAll(view.document, (node) => node.className === 'order-badge');
  assert.deepStrictEqual(badges.map((badge) => badge.textContent), ['#1', '#2', '#3']);
});

test('save posts the rules in the displayed order', () => {
  const view = loadWebview(SAMPLE);
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.strictEqual(view.posted.length, 1);
  assert.strictEqual(view.posted[0].type, 'save');
  assert.deepStrictEqual(view.posted[0].rules, SAMPLE.rules);
});

test('moving a rule down changes the evaluation order', () => {
  const view = loadWebview(SAMPLE);
  findByTitle(view.document, 'Move down (evaluated later)')[0].fire('click');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.deepStrictEqual(view.posted[0].rules.map((rule) => rule.action),
    ['logStack', 'ignore', 'break']);
});

test('the first rule cannot move up and the last cannot move down', () => {
  const view = loadWebview(SAMPLE);
  const up = findByTitle(view.document, 'Move up (evaluated earlier)');
  const down = findByTitle(view.document, 'Move down (evaluated later)');
  assert.deepStrictEqual(up.map((b) => b.disabled), [true, false, false]);
  assert.deepStrictEqual(down.map((b) => b.disabled), [false, false, true]);
});

test('delete and duplicate keep the model consistent', () => {
  const view = loadWebview(SAMPLE);
  findByTitle(view.document, 'Duplicate this rule')[0].fire('click');
  findByTitle(view.document, 'Delete this rule')[2].fire('click');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.deepStrictEqual(view.posted[0].rules.map((rule) => rule.action),
    ['ignore', 'ignore', 'break']);
});

test('typing an invalid regex blocks saving and shows the problem', () => {
  const view = loadWebview(SAMPLE);
  const input = view.document.querySelector('[data-input-for="1:messageRegex"]');
  input.value = 'ORA-(\\d+';
  input.fire('input');
  const saveButton = view.document.getElementById('save-button');
  assert.strictEqual(saveButton.disabled, true);
  const errorHost = view.document.querySelector('[data-error-for="1:messageRegex"]');
  assert.match(errorHost.textContent, /not a valid regular expression/);
  assert.match(view.document.getElementById('problems').textContent, /Rule #2/);
});

test('a comma-separated class list becomes an array', () => {
  const view = loadWebview(SAMPLE);
  const input = view.document.querySelector('[data-input-for="0:class"]');
  input.value = 'EAbort, EMyError';
  input.fire('input');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.deepStrictEqual(view.posted[0].rules[0].class, ['EAbort', 'EMyError']);
});

test('a native exception code round-trips instead of being dropped on save', () => {
  const view = loadWebview({
    configurationName: 'X', documentLabel: 'y', readOnly: false,
    rules: [{ code: '0x406D1388', action: 'ignore' }, { action: 'break' }]
  });
  // It must load as a known criterion (not as an "unknown field" to be removed).
  assert.strictEqual(view.document.getElementById('save-button').disabled, false);
  const input = view.document.querySelector('[data-input-for="0:code"]');
  assert.strictEqual(input.value, '0x406D1388');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.deepStrictEqual(view.posted[0].rules[0], { code: '0x406D1388', action: 'ignore' });
});

test('a comma-separated code list becomes an array and an invalid code blocks saving', () => {
  const view = loadWebview({
    configurationName: 'X', documentLabel: 'y', readOnly: false,
    rules: [{ action: 'ignore' }]
  });
  const input = view.document.querySelector('[data-input-for="0:code"]');
  input.value = '0x406D1388, $C0000005';
  input.fire('input');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.deepStrictEqual(view.posted[0].rules[0].code, ['0x406D1388', '$C0000005']);

  input.value = 'C0000005';   // no 0x / $ prefix: not a code
  input.fire('input');
  assert.strictEqual(view.document.getElementById('save-button').disabled, true);
  assert.match(view.document.querySelector('[data-error-for="0:code"]').textContent,
    /not a valid Win32 exception code/);
});

test('changing the action updates the model and the help text', () => {
  const view = loadWebview(SAMPLE);
  const select = view.document.querySelector('[data-input-for="2:action"]');
  select.value = 'log';
  select.fire('change');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.strictEqual(view.posted[0].rules[2].action, 'log');
});

test('unknown fields loaded from launch.json are reported, not silently kept', () => {
  const view = loadWebview({
    configurationName: 'X', documentLabel: 'y', readOnly: false,
    rules: [{ clazz: 'EAbort', action: 'ignore' }]
  });
  assert.strictEqual(view.document.getElementById('save-button').disabled, true);
  assert.match(view.document.getElementById('problems').textContent, /unknown field "clazz"/);
  findByTitle(view.document, 'Drop the unrecognised fields from this rule')[0].fire('click');
  assert.strictEqual(view.document.getElementById('save-button').disabled, false);
});

test('read-only mode disables editing but still allows Copy JSON', () => {
  const view = loadWebview({
    configurationName: 'X', documentLabel: 'y', readOnly: true,
    readOnlyReason: 'Workspace is not trusted.', rules: SAMPLE.rules
  });
  assert.strictEqual(view.document.getElementById('save-button').disabled, true);
  findByTitle(view.document, 'Copy the exceptionRules array to the clipboard')[0].fire('click');
  assert.strictEqual(view.posted[0].type, 'copy');
  assert.match(view.posted[0].text, /"class": "EAbort"/);
});

test('adding a rule appends a break rule at the end', () => {
  const view = loadWebview({ configurationName: 'X', documentLabel: 'y', readOnly: false, rules: [] });
  assert.match(view.document.getElementById('app').textContent, /No exception rules yet/);
  findByTitle(view.document, 'Append a new rule at the end')[0].fire('click');
  findByTitle(view.document, 'Write these rules back into the launch configuration')[0].fire('click');
  assert.deepStrictEqual(view.posted[0].rules, [{ action: 'break' }]);
});

test('the save button names the file it writes, shared file included', () => {
  const shared = loadWebview({
    configurationName: 'Shared rules (all projects)',
    documentLabel: 'C:\\Users\\x\\.DelphiWinDebugger\\exceptionRules.json',
    fileNoun: 'the shared rules file',
    saveLabel: 'Save to the shared rules file',
    saveTitle: 'Write these rules back into the machine-wide shared rules file',
    readOnly: false,
    rules: SAMPLE.rules
  });
  const saveButton = shared.document.getElementById('save-button');
  assert.strictEqual(saveButton.textContent, 'Save to the shared rules file');
  saveButton.fire('click');
  assert.strictEqual(shared.posted[0].type, 'save');

  // Without the override the launch.json wording is unchanged.
  const project = loadWebview(SAMPLE);
  assert.strictEqual(project.document.getElementById('save-button').textContent, 'Save to launch.json');
});

test('a rejected save from the extension host is displayed', () => {
  const view = loadWebview(SAMPLE);
  view.post({ type: 'saveRejected', problems: [{ index: 0, field: 'action', message: 'nope' }] });
  assert.match(view.document.getElementById('problems').textContent, /Rule #1 - action: nope/);
  view.post({ type: 'saveFailed', message: 'disk on fire' });
  assert.match(view.document.getElementById('status').textContent, /disk on fire|problem/);
});

console.log('');
console.log(passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
