'use strict';

/*
 * Tests for "create a rule for this exception":
 *
 *   - the `delphiWin64StoppedOnException` context-key lifecycle. A button that
 *     is still there after the user resumed would offer to write a rule for an
 *     exception that is no longer current, so every way a stop can end is
 *     covered here: another stop, a resume request, a `continued` event,
 *     session end.
 *   - the rule suggestions built from the exception;
 *   - the QuickPick flow, end to end, against a stubbed vscode and a real
 *     temporary shared-rules file.
 *
 *   node install\extension-tests\test-exception-rule.js
 */

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const extensionDir = path.join(__dirname, '..', 'local.delphi-win64-debug');

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

const recorded = {
  contextCalls: [],
  information: [],
  warnings: [],
  errors: [],
  quickPicks: [],
  panels: []
};

/** Each entry answers one showQuickPick call: a function of (items, options). */
let quickPickAnswers = [];

function positionAt(text, offset) {
  const before = text.slice(0, offset);
  const line = (before.match(/\n/g) || []).length;
  const lineStart = before.lastIndexOf('\n') + 1;
  return { line: line, character: offset - lineStart, offset: offset };
}

function readFileText(fsPath) {
  return fs.existsSync(fsPath) ? fs.readFileSync(fsPath, 'utf8') : '';
}

const vscodeStub = {
  StatusBarAlignment: { Left: 1, Right: 2 },
  ViewColumn: { Active: -1, Beside: -2 },
  TextEditorRevealType: { InCenter: 2 },
  Uri: {
    file: (fsPath) => ({ scheme: 'file', fsPath: fsPath, path: String(fsPath).replace(/\\/g, '/') }),
    joinPath: (base, ...parts) => ({
      scheme: 'file',
      fsPath: path.join(base.fsPath || base.path, ...parts),
      path: [base.path].concat(parts).join('/')
    })
  },
  Range: function Range(a, b, c, d) {
    if (typeof a === 'number') {
      this.start = { line: a, character: b };
      this.end = { line: c, character: d };
    } else {
      this.start = a;
      this.end = b;
    }
  },
  WorkspaceEdit: function WorkspaceEdit() {
    this.edits = [];
    this.replace = (uri, range, newText) => this.edits.push({ uri: uri, range: range, newText: newText });
  },
  window: {
    createStatusBarItem: () => ({
      text: '', tooltip: undefined, name: '', show() {}, hide() {}, dispose() {}
    }),
    showQuickPick: async (items, options) => {
      recorded.quickPicks.push({ items: items, options: options });
      const answer = quickPickAnswers.shift();
      return answer ? answer(items, options) : undefined;
    },
    showInformationMessage: (message) => recorded.information.push(message),
    showWarningMessage: (message) => recorded.warnings.push(message),
    showErrorMessage: (message) => recorded.errors.push(message),
    showTextDocument: async () => ({ revealRange() {} }),
    createWebviewPanel: (id, title) => {
      const panel = {
        id: id,
        title: title,
        webview: {
          cspSource: 'vscode-resource:',
          html: '',
          asWebviewUri: (uri) => uri,
          onDidReceiveMessage() {},
          postMessage() {}
        },
        dispose() {}
      };
      recorded.panels.push(panel);
      return panel;
    }
  },
  debug: {
    activeDebugSession: undefined,
    activeStackItem: undefined,
    onDidReceiveDebugSessionCustomEvent: makeEvent(),
    onDidTerminateDebugSession: makeEvent(),
    registerDebugAdapterTrackerFactory(type, factory) {
      vscodeStub.debug.trackerFactory = { type: type, factory: factory };
      return { dispose() {} };
    },
    registerDebugConfigurationProvider(type, provider) {
      vscodeStub.debug.configurationProvider = { type: type, provider: provider };
      return { dispose() {} };
    }
  },
  commands: {
    registeredCommands: {},
    registerCommand(id, handler) {
      vscodeStub.commands.registeredCommands[id] = handler;
      return { dispose() {} };
    },
    executeCommand(command, key, value) {
      if (command === 'setContext') recorded.contextCalls.push([key, value]);
      return Promise.resolve();
    }
  },
  workspace: {
    workspaceFolders: [],
    workspaceFile: undefined,
    isTrusted: true,
    async openTextDocument(uri) {
      const fsPath = uri.fsPath || uri.path;
      if (!fs.existsSync(fsPath)) throw new Error('not found: ' + fsPath);
      const text = readFileText(fsPath);
      return {
        uri: uri,
        getText: () => text,
        positionAt: (offset) => positionAt(text, offset)
      };
    },
    async applyEdit(workspaceEdit) {
      workspaceEdit.edits.forEach((edit) => {
        const fsPath = edit.uri.fsPath || edit.uri.path;
        const text = readFileText(fsPath);
        const start = edit.range.start.offset;
        const end = edit.range.end.offset;
        fs.writeFileSync(fsPath, text.slice(0, start) + edit.newText + text.slice(end), 'utf8');
      });
      return true;
    }
  },
  env: { clipboard: { writeText: async () => {} } }
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  return originalLoad.call(this, request, parent, isMain);
};

const extension = require(path.join(extensionDir, 'extension.js'));
const rules = require(path.join(extensionDir, 'rules.js'));
const globalRules = require(path.join(extensionDir, 'globalRules.js'));
const wizard = require(path.join(extensionDir, 'exceptionRuleWizard.js'));

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

function newTracker() {
  const calls = [];
  const tracker = new extension.ExceptionStopTracker((value) => calls.push(value));
  tracker.initialize();
  tracker.calls = calls;
  return tracker;
}

const EXCEPTION_STOP = { type: 'event', event: 'stopped', body: { reason: 'exception', threadId: 7 } };
const BREAKPOINT_STOP = { type: 'event', event: 'stopped', body: { reason: 'breakpoint', threadId: 7 } };

async function main() {
  console.log('context key: ' + extension.EXCEPTION_CONTEXT_KEY);

  await test('starts false, an exception stop turns it on', () => {
    const tracker = newTracker();
    assert.deepStrictEqual(tracker.calls, [false]);
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    assert.deepStrictEqual(tracker.calls, [false, true]);
    assert.strictEqual(tracker.isStoppedOnException('s1'), true);
    assert.strictEqual(tracker.threadIdFor('s1'), 7);
  });

  await test('a second exception stop does not re-publish the same value', () => {
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    assert.deepStrictEqual(tracker.calls, [false, true]);
  });

  await test('the next non-exception stop clears it', () => {
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    tracker.handleAdapterMessage('s1', BREAKPOINT_STOP);
    assert.deepStrictEqual(tracker.calls, [false, true, false]);
    assert.strictEqual(tracker.threadIdFor('s1'), undefined);
  });

  await test('every resume request clears it', () => {
    extension.RESUME_REQUESTS.forEach((command) => {
      const tracker = newTracker();
      tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
      tracker.handleClientMessage('s1', { type: 'request', command: command });
      assert.deepStrictEqual(tracker.calls, [false, true, false], 'not cleared by ' + command);
    });
  });

  await test('requests that do not resume leave it alone', () => {
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    ['stackTrace', 'scopes', 'variables', 'evaluate', 'exceptionInfo', 'threads', 'setBreakpoints']
      .forEach((command) => tracker.handleClientMessage('s1', { type: 'request', command: command }));
    assert.deepStrictEqual(tracker.calls, [false, true]);
  });

  await test('a continued event clears it', () => {
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    tracker.handleAdapterMessage('s1', { type: 'event', event: 'continued', body: { threadId: 7 } });
    assert.deepStrictEqual(tracker.calls, [false, true, false]);
  });

  await test('terminated / exited events and endSession clear it', () => {
    ['terminated', 'exited'].forEach((event) => {
      const tracker = newTracker();
      tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
      tracker.handleAdapterMessage('s1', { type: 'event', event: event });
      assert.deepStrictEqual(tracker.calls, [false, true, false], 'not cleared by ' + event);
    });
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    tracker.endSession('s1');
    assert.deepStrictEqual(tracker.calls, [false, true, false]);
  });

  await test('two sessions are independent and the key stays on until both resume', () => {
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', EXCEPTION_STOP);
    tracker.handleAdapterMessage('s2', { type: 'event', event: 'stopped', body: { reason: 'exception', threadId: 11 } });
    tracker.handleClientMessage('s1', { type: 'request', command: 'continue' });
    assert.deepStrictEqual(tracker.calls, [false, true]);
    assert.strictEqual(tracker.isStoppedOnException('s1'), false);
    assert.strictEqual(tracker.threadIdFor('s2'), 11);
    tracker.endSession('s2');
    assert.deepStrictEqual(tracker.calls, [false, true, false]);
  });

  await test('noise on the wire is ignored', () => {
    const tracker = newTracker();
    [undefined, null, {}, { type: 'response', command: 'continue' }, { type: 'event' },
      { type: 'event', event: 'output', body: { category: 'stdout' } }]
      .forEach((message) => {
        tracker.handleAdapterMessage('s1', message);
        tracker.handleClientMessage('s1', message);
      });
    assert.deepStrictEqual(tracker.calls, [false]);
  });

  await test('a stopped event without a threadId still enables the button', () => {
    const tracker = newTracker();
    tracker.handleAdapterMessage('s1', { type: 'event', event: 'stopped', body: { reason: 'exception' } });
    assert.strictEqual(tracker.isStoppedOnException(), true);
    assert.strictEqual(tracker.threadIdFor('s1'), undefined);
  });

  console.log('activation wiring');

  await test('activate registers the tracker factory and the three commands', () => {
    recorded.contextCalls.length = 0;
    const context = { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') };
    extension.activate(context);
    const commands = vscodeStub.commands.registeredCommands;
    ['delphi-win64.editExceptionRules', 'delphi-win64.createRuleForException', 'delphi-win64.pickProcess']
      .forEach((id) => assert.ok(commands[id], 'command not registered: ' + id));
    assert.strictEqual(vscodeStub.debug.trackerFactory.type, 'delphi-win64');
    assert.deepStrictEqual(recorded.contextCalls[0], [extension.EXCEPTION_CONTEXT_KEY, false]);

    const session = { id: 'live', type: 'delphi-win64' };
    const tracker = vscodeStub.debug.trackerFactory.factory.createDebugAdapterTracker(session);
    tracker.onDidSendMessage(EXCEPTION_STOP);
    assert.deepStrictEqual(recorded.contextCalls[recorded.contextCalls.length - 1],
      [extension.EXCEPTION_CONTEXT_KEY, true]);
    tracker.onWillReceiveMessage({ type: 'request', command: 'continue' });
    assert.deepStrictEqual(recorded.contextCalls[recorded.contextCalls.length - 1],
      [extension.EXCEPTION_CONTEXT_KEY, false]);

    // ... and a session that dies while stopped on an exception clears it too.
    tracker.onDidSendMessage(EXCEPTION_STOP);
    vscodeStub.debug.onDidTerminateDebugSession.fire(session);
    assert.deepStrictEqual(recorded.contextCalls[recorded.contextCalls.length - 1],
      [extension.EXCEPTION_CONTEXT_KEY, false]);
  });

  console.log('rule suggestions');

  const SAMPLE_CONTEXT = {
    exceptionClass: 'EOracleError',
    message: 'ORA-00942: table or view does not exist',
    unitName: 'OracleData',
    line: 214
  };

  await test('every suggestion is a valid rule', () => {
    const suggestions = rules.suggestRulesForException(SAMPLE_CONTEXT);
    suggestions.forEach((suggestion) => {
      assert.deepStrictEqual(rules.validateRule(suggestion.rule, 0), [], suggestion.id);
    });
  });

  await test('the class, unit, line and message intents are all offered', () => {
    const byId = {};
    rules.suggestRulesForException(SAMPLE_CONTEXT).forEach((s) => { byId[s.id] = s; });
    assert.deepStrictEqual(byId['ignore-class'].rule, { class: 'EOracleError', action: 'ignore' });
    assert.deepStrictEqual(byId['ignore-in-unit'].rule,
      { class: 'EOracleError', unit: 'OracleData', action: 'ignore' });
    assert.deepStrictEqual(byId['ignore-at-line'].rule,
      { class: 'EOracleError', unit: 'OracleData', line: 214, action: 'ignore' });
    assert.strictEqual(byId['log-stack'].rule.action, 'logStack');
    assert.strictEqual(byId['ignore-message'].rule.message, SAMPLE_CONTEXT.message);
  });

  await test('the last option opens the editor on a fully pre-filled rule', () => {
    const suggestions = rules.suggestRulesForException(SAMPLE_CONTEXT);
    const last = suggestions[suggestions.length - 1];
    assert.strictEqual(last.id, 'custom');
    assert.strictEqual(last.openEditor, true);
    assert.deepStrictEqual(last.rule,
      { class: 'EOracleError', unit: 'OracleData', line: 214, action: 'break' });
  });

  await test('unknown criteria are simply left out', () => {
    const suggestions = rules.suggestRulesForException({ exceptionClass: 'EAbort' });
    const ids = suggestions.map((suggestion) => suggestion.id);
    assert.deepStrictEqual(ids, ['ignore-class', 'log-stack', 'custom']);
    const nothing = rules.suggestRulesForException({});
    assert.deepStrictEqual(nothing.map((suggestion) => suggestion.id), ['custom']);
  });

  console.log('the wizard');

  const temporaryHome = fs.mkdtempSync(path.join(os.tmpdir(), 'delphi-wizard-'));
  const originalUserProfile = process.env.USERPROFILE;
  process.env.USERPROFILE = temporaryHome;
  const sharedFile = globalRules.defaultGlobalRulesPath();

  function resetWizardState(existingRules) {
    recorded.errors.length = 0;
    recorded.information.length = 0;
    recorded.quickPicks.length = 0;
    recorded.panels.length = 0;
    quickPickAnswers = [];
    fs.rmSync(path.dirname(sharedFile), { recursive: true, force: true });
    if (existingRules) globalRules.writeGlobalRulesFile(sharedFile, existingRules);
  }

  function makeSession(overrides) {
    const answers = Object.assign({
      exceptionInfo: {
        exceptionId: 'EOracleError',
        description: 'ORA-00942: table or view does not exist',
        details: { typeName: 'EOracleError', message: 'ORA-00942: table or view does not exist' }
      },
      stackTrace: {
        stackFrames: [{ id: 1, name: 'TDataModule1.Load', line: 214, source: { name: 'OracleData.pas' } }]
      },
      threads: { threads: [{ id: 7, name: 'Main Thread' }, { id: 9, name: 'Worker' }] }
    }, overrides || {});
    const calls = [];
    const session = {
      id: 's1',
      type: 'delphi-win64',
      calls: calls,
      customRequest: async (command, args) => {
        calls.push({ command: command, args: args });
        const answer = answers[command];
        if (answer instanceof Error) throw answer;
        return answer;
      }
    };
    vscodeStub.debug.activeDebugSession = session;
    return session;
  }

  await test('reads the class, message and raise site from the adapter', async () => {
    const session = makeSession();
    const context = await wizard.readExceptionContext(session, 7);
    assert.strictEqual(context.exceptionClass, 'EOracleError');
    assert.match(context.message, /ORA-00942/);
    assert.strictEqual(context.unitName, 'OracleData');
    assert.strictEqual(context.line, 214);
    assert.deepStrictEqual(session.calls[0], { command: 'exceptionInfo', args: { threadId: 7 } });
  });

  await test('the thread comes from the stopped event, then activeStackItem, then threads', async () => {
    const session = makeSession();
    vscodeStub.debug.activeStackItem = undefined;
    assert.strictEqual(await wizard.resolveThreadId(session, 42), 42);

    vscodeStub.debug.activeStackItem = { threadId: 13, session: session };
    assert.strictEqual(await wizard.resolveThreadId(session, undefined), 13);

    vscodeStub.debug.activeStackItem = undefined;
    quickPickAnswers = [(items) => items[1]];
    assert.strictEqual(await wizard.resolveThreadId(session, undefined), 9);

    // A single-threaded target needs no question.
    const single = makeSession({ threads: { threads: [{ id: 3, name: 'Main' }] } });
    assert.strictEqual(await wizard.resolveThreadId(single, undefined), 3);
  });

  await test('the new rule is written first, above the existing ones', async () => {
    resetWizardState([{ class: 'EExisting', action: 'break' }]);
    makeSession();
    quickPickAnswers = [(items) => items[0]]; // "ignore EOracleError everywhere"
    const created = await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, 7);
    assert.deepStrictEqual(created, { class: 'EOracleError', action: 'ignore' });
    const stored = globalRules.readGlobalRulesFile(sharedFile);
    assert.deepStrictEqual(stored.rules,
      [{ class: 'EOracleError', action: 'ignore' }, { class: 'EExisting', action: 'break' }]);
    assert.strictEqual(recorded.errors.length, 0);
    assert.match(recorded.information[0], /rule #1/);
  });

  await test('the shared file is created when it does not exist yet', async () => {
    resetWizardState();
    makeSession();
    assert.strictEqual(fs.existsSync(sharedFile), false);
    quickPickAnswers = [(items) => items[0]];
    await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, 7);
    assert.strictEqual(fs.existsSync(sharedFile), true);
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(sharedFile).rules,
      [{ class: 'EOracleError', action: 'ignore' }]);
  });

  await test('the placeholder says the rule is inserted first', async () => {
    resetWizardState();
    makeSession();
    quickPickAnswers = [(items) => items[0]];
    await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, 7);
    assert.match(String(recorded.quickPicks[0].options.placeHolder), /first matching rule wins/);
    assert.match(String(recorded.quickPicks[0].options.placeHolder), /EOracleError/);
  });

  await test('cancelling the QuickPick writes nothing', async () => {
    resetWizardState([{ class: 'EExisting', action: 'break' }]);
    makeSession();
    quickPickAnswers = [];  // cancel
    const created = await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, 7);
    assert.strictEqual(created, undefined);
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(sharedFile).rules,
      [{ class: 'EExisting', action: 'break' }]);
  });

  await test('the "edit a pre-filled rule" option opens the editor and writes nothing yet', async () => {
    resetWizardState([{ class: 'EExisting', action: 'break' }]);
    makeSession();
    quickPickAnswers = [(items) => items[items.length - 1]];
    await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, 7);
    assert.strictEqual(recorded.panels.length, 1);
    const html = recorded.panels[0].webview.html;
    const payload = JSON.parse(/window\.INITIAL_STATE = (.*);/.exec(html)[1]);
    assert.deepStrictEqual(payload.rules[0],
      { class: 'EOracleError', unit: 'OracleData', line: 214, action: 'break' });
    assert.deepStrictEqual(payload.rules[1], { class: 'EExisting', action: 'break' });
    assert.deepStrictEqual(globalRules.readGlobalRulesFile(sharedFile).rules,
      [{ class: 'EExisting', action: 'break' }]);
  });

  await test('a stop that is not an exception is refused', async () => {
    resetWizardState();
    makeSession({ exceptionInfo: {}, stackTrace: { stackFrames: [] } });
    const created = await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, 7);
    assert.strictEqual(created, undefined);
    assert.match(recorded.errors[0], /no exception/i);
  });

  await test('no active Delphi session is refused', async () => {
    resetWizardState();
    vscodeStub.debug.activeDebugSession = { id: 'x', type: 'node' };
    const created = await wizard.createRuleForCurrentException(
      { subscriptions: [], extensionUri: vscodeStub.Uri.file('C:\\ext') }, undefined);
    assert.strictEqual(created, undefined);
    assert.match(recorded.errors[0], /No Delphi Win64 debug session/);
  });

  process.env.USERPROFILE = originalUserProfile;
  fs.rmSync(temporaryHome, { recursive: true, force: true });

  console.log('');
  console.log(passed + ' passed, ' + failed + ' failed');
  Module._load = originalLoad;
  process.exit(failed ? 1 : 0);
}

main();
