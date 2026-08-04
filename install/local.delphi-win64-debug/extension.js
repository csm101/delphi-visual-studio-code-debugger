'use strict';

/*
 * Delphi Win64 Debugger - VS Code extension host code.
 *
 * Two jobs:
 *
 * 1. Status-bar progress. VS Code renders the standard DAP progress events
 *    (progressStart/progressUpdate/progressEnd) as notification toasts and
 *    offers no way to relocate them (see microsoft/vscode#204750). So when the
 *    launch config asks for `progressLocation: "statusBar"` the adapter emits a
 *    custom `delphiProgress` event instead, and this extension renders it.
 *
 *      event: "delphiProgress"
 *      body:  { id: string, state: "start" | "update" | "end", text: string }
 *
 *    The adapter emits either the custom events or the standard DAP progress
 *    events, never both, so a DAP client that is not this extension keeps
 *    working.
 *
 * 2. The `Delphi Win64: Edit Exception Rules` command (see
 *    exceptionRulesEditor.js) and `Delphi Win64: Create a Rule for This
 *    Exception` (exceptionRuleWizard.js).
 *
 * 3. The `delphiWin64StoppedOnException` context key, which decides whether the
 *    "create a rule" button is on the debug toolbar. VS Code has no built-in
 *    key for "the current stop is an exception", so it is derived from the DAP
 *    traffic through a debug adapter tracker (see ExceptionStopTracker).
 *
 * 4. `delphi-win64.pickProcess`, the process picker an attach configuration
 *    references as `"processId": "${command:delphi-win64.pickProcess}"`. The
 *    command argument VS Code supplies is forwarded untouched, because it
 *    carries the name filter (see processPicker.js).
 *
 * 5. A debug configuration provider that runs the same picker for an attach
 *    configuration which names a `processName` but no `processId` - the shape
 *    every previously generated or hand-written attach entry has (see
 *    resolveAttachTarget).
 */

const vscode = require('vscode');
const { openExceptionRulesEditor } = require('./exceptionRulesEditor');
const wizard = require('./exceptionRuleWizard');
const processPicker = require('./processPicker');

const DEBUG_TYPE = 'delphi-win64';
const PROGRESS_EVENT = 'delphiProgress';
const MAX_STATUS_TEXT = 60;
const EXCEPTION_CONTEXT_KEY = 'delphiWin64StoppedOnException';

/*
 * Requests that resume the debuggee. Seen on the way *to* the adapter, so the
 * button disappears the moment the user hits continue/step instead of one
 * round-trip later.
 */
const RESUME_REQUESTS = ['continue', 'next', 'stepIn', 'stepOut', 'stepBack',
  'reverseContinue', 'goto', 'restart', 'restartFrame', 'disconnect', 'terminate'];

/**
 * True when a `processId` value actually identifies a process.
 *
 * Absent, 0, empty and whitespace all mean "not chosen". A `${command:...}` or
 * `${input:...}` string counts as chosen: this runs BEFORE variable
 * substitution, so leaving it alone is what lets VS Code expand it - resolving
 * it here as well would prompt twice.
 */
function hasExplicitProcessId(value) {
  if (typeof value === 'number') return isFinite(value) && value > 0;
  if (typeof value !== 'string') return false;
  const trimmed = value.trim();
  if (trimmed === '') return false;
  return /^\$\{/.test(trimmed) || Number(trimmed) > 0;
}

/**
 * Fills in `processId` for an attach configuration that names only a
 * `processName`.
 *
 * That is the shape of every attach entry written before the picker existed,
 * including the ones the Delphi IDE plugin generates: name only. Without this
 * the picker is unreachable from them - the user gets no choice, and with two
 * instances of the application running the adapter can only refuse. Resolving
 * it here means an existing configuration gains the picker with no edit.
 *
 * The picker prompts only when it has to: one match attaches straight away.
 * Cancelling returns `undefined`, which VS Code reads as "abort the session"
 * (the correct outcome - attaching to an arbitrary instance would be worse).
 */
async function resolveAttachTarget(config, pick) {
  if (!config || config.request !== 'attach') return config;
  if (hasExplicitProcessId(config.processId)) return config;

  const name = typeof config.processName === 'string' ? config.processName.trim() : '';
  if (name === '') return config;

  const pid = await pick({ processName: name });
  if (pid === undefined) return undefined;

  return Object.assign({}, config, { processId: Number(pid) });
}

function truncate(text, limit) {
  if (text.length <= limit) return text;
  return text.slice(0, limit - 1) + '…';
}

/**
 * Renders the currently running `delphiProgress` operations in the status bar.
 *
 * Several operations can be in flight at once (and several debug sessions),
 * so state is keyed by session id and then by operation id. The bar shows the
 * most recently updated operation plus a "+n" counter; the tooltip lists all
 * of them.
 *
 * Nothing here trusts the adapter to be well behaved: an operation that never
 * sends "end" is dropped when its debug session terminates, so a crashed
 * adapter cannot leave a spinner pinned to the status bar forever.
 */
class ProgressStatusBar {
  constructor() {
    this.item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    this.item.name = 'Delphi Debugger Progress';
    this.sessions = new Map(); // sessionId -> Map(operationId -> { text, order })
    this.counter = 0;
  }

  handleCustomEvent(session, body) {
    if (!body || typeof body !== 'object') return;
    const id = typeof body.id === 'string' ? body.id : undefined;
    const state = body.state;
    if (!id || (state !== 'start' && state !== 'update' && state !== 'end')) return;

    if (state === 'end') {
      const operations = this.sessions.get(session.id);
      if (operations) {
        operations.delete(id);
        if (operations.size === 0) this.sessions.delete(session.id);
      }
    } else {
      let operations = this.sessions.get(session.id);
      if (!operations) {
        operations = new Map();
        this.sessions.set(session.id, operations);
      }
      const text = typeof body.text === 'string' && body.text.trim() !== ''
        ? body.text.trim()
        : 'Working…';
      const previous = operations.get(id);
      // An "update" for an unknown id is treated as a "start": never lose an
      // operation just because the start event was missed.
      operations.set(id, { text: text, order: previous ? previous.order : ++this.counter });
    }
    this.render();
  }

  clearSession(sessionId) {
    if (this.sessions.delete(sessionId)) this.render();
  }

  activeOperations() {
    const all = [];
    for (const [sessionId, operations] of this.sessions) {
      for (const [id, operation] of operations) {
        all.push({ sessionId: sessionId, id: id, text: operation.text, order: operation.order });
      }
    }
    all.sort((a, b) => a.order - b.order);
    return all;
  }

  render() {
    const operations = this.activeOperations();
    if (operations.length === 0) {
      this.item.hide();
      this.item.text = '';
      this.item.tooltip = undefined;
      return;
    }
    const newest = operations[operations.length - 1];
    const extra = operations.length > 1 ? ` (+${operations.length - 1})` : '';
    this.item.text = `$(sync~spin) ${truncate(newest.text, MAX_STATUS_TEXT)}${extra}`;
    this.item.tooltip = operations.length === 1
      ? newest.text
      : 'Delphi debugger:\n' + operations.map((operation) => '• ' + operation.text).join('\n');
    this.item.show();
  }

  dispose() {
    this.sessions.clear();
    this.item.dispose();
  }
}

/**
 * Tracks, per debug session, whether the debuggee is stopped on an exception,
 * and publishes the answer as the `delphiWin64StoppedOnException` context key.
 *
 * A button that lies is worse than no button, so the state is cleared
 * aggressively: on any non-exception stop, on any resume request, on
 * `continued`, on session end. It is set only by a `stopped` event whose
 * reason is `exception`, which also gives us the thread id the rule wizard
 * needs (never assume there is only one thread).
 */
class ExceptionStopTracker {
  constructor(setContext) {
    this.setContext = setContext;
    this.exceptionStops = new Map(); // sessionId -> threadId
    this.published = undefined;
  }

  /** Publishes the initial `false`, so the key always exists in when-clauses. */
  initialize() {
    this.sync();
  }

  /** Messages the adapter sends to VS Code. */
  handleAdapterMessage(sessionId, message) {
    if (!message || message.type !== 'event') return;
    if (message.event === 'stopped') {
      const body = message.body || {};
      if (body.reason === 'exception') {
        this.exceptionStops.set(sessionId, typeof body.threadId === 'number' ? body.threadId : undefined);
      } else {
        this.exceptionStops.delete(sessionId);
      }
    } else if (message.event === 'continued' || message.event === 'terminated' || message.event === 'exited') {
      this.exceptionStops.delete(sessionId);
    }
    this.sync();
  }

  /** Messages VS Code sends to the adapter. */
  handleClientMessage(sessionId, message) {
    if (!message || message.type !== 'request') return;
    if (RESUME_REQUESTS.indexOf(message.command) === -1) return;
    this.exceptionStops.delete(sessionId);
    this.sync();
  }

  endSession(sessionId) {
    this.exceptionStops.delete(sessionId);
    this.sync();
  }

  isStoppedOnException(sessionId) {
    if (sessionId === undefined) return this.exceptionStops.size > 0;
    return this.exceptionStops.has(sessionId);
  }

  /** The thread of the exception stop, for the given session or any session. */
  threadIdFor(sessionId) {
    if (sessionId !== undefined && this.exceptionStops.has(sessionId)) {
      return this.exceptionStops.get(sessionId);
    }
    if (sessionId !== undefined) return undefined;
    for (const threadId of this.exceptionStops.values()) return threadId;
    return undefined;
  }

  sync() {
    const value = this.exceptionStops.size > 0;
    if (value === this.published) return;
    this.published = value;
    this.setContext(value);
  }
}

// --- What a debug hover evaluates -------------------------------------------
//
// Without a provider, VS Code hovers whatever its word heuristic finds, which
// for Pascal is one identifier. Hovering `IsModuleEnabled('X')` evaluated
// `IsModuleEnabled` alone; hovering the string literal sent a fragment of it
// and the evaluator answered `<unterminated string>`. Neither is what the user
// pointed at.
//
// Two rules, in order:
//   1. If there IS a selection and the mouse is inside it, that selection is
//      the expression -- the Delphi IDE behaviour the maintainer expected, and
//      the only way to hover something the heuristic could never guess.
//   2. Otherwise grow the identifier under the cursor into a whole Pascal
//      expression: qualified names, indexers, calls, dereferences.
//
// Growing across `(` is deliberate even though a hover will not RUN a call:
// the adapter refuses with "evaluating this would CALL it", which tells the
// truth, whereas evaluating half the text produces a parse error about a
// string that is not really unterminated.

const IDENT_CHAR = /[A-Za-z0-9_]/;

// Scans from `from` in `text` over a balanced (...) or [...] group, skipping
// Pascal string literals so a bracket inside 'a[b]' cannot unbalance it.
// Returns the index just past the closing bracket, or -1 if it never closes.
function scanBalanced(text, from) {
  const open = text[from];
  const close = open === '(' ? ')' : ']';
  let depth = 0;
  let i = from;
  while (i < text.length) {
    const ch = text[i];
    if (ch === "'") {
      i++;
      while (i < text.length) {
        if (text[i] === "'") {
          // '' inside a literal is an escaped quote, not the end.
          if (text[i + 1] === "'") { i += 2; continue; }
          break;
        }
        i++;
      }
      if (i >= text.length) return -1;
      i++;
      continue;
    }
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return i + 1;
    }
    i++;
  }
  return -1;
}

// Start of the qualified chain ending at `end` (exclusive): walks back over
// `Ident`, `.`, and balanced groups, so `A.B[0].C` starts at `A`.
function chainStart(text, end) {
  let i = end;
  for (;;) {
    while (i > 0 && IDENT_CHAR.test(text[i - 1])) i--;
    if (i > 0 && (text[i - 1] === ']' || text[i - 1] === ')')) {
      // Walk back over the group by scanning forward from each candidate
      // opener -- cheaper to find than to reverse-parse.
      const closeAt = i - 1;
      const opener = text[closeAt] === ']' ? '[' : '(';
      let j = closeAt - 1;
      let found = -1;
      while (j >= 0) {
        if (text[j] === opener && scanBalanced(text, j) === closeAt + 1) { found = j; break; }
        j--;
      }
      if (found < 0) break;
      i = found;
      continue;
    }
    // A `.` may follow an identifier OR a closing bracket -- `Self.FList[i].Name`
    // walks back through `]` on its way to `Self`. Requiring an identifier here
    // stopped the chain dead at the last dot.
    if (i > 1 && text[i - 1] === '.' &&
        (IDENT_CHAR.test(text[i - 2]) || text[i - 2] === ']' || text[i - 2] === ')')) {
      i--;
      continue;
    }
    break;
  }
  return i;
}

// The whole rule, on plain text, so it can be tested without VS Code.
// `wordStart`/`wordEnd` bound the identifier the cursor is on.
function pascalExpressionSpan(line, wordStart, wordEnd) {
  let start = chainStart(line, wordStart);
  let end = wordEnd;

  // Grow right over `.Ident`, `[...]`, `(...)` and `^`.
  for (;;) {
    if (end < line.length && (line[end] === '[' || line[end] === '(')) {
      const past = scanBalanced(line, end);
      if (past < 0) break;
      end = past;
      continue;
    }
    if (end < line.length && line[end] === '^') { end++; continue; }
    if (end + 1 < line.length && line[end] === '.' && IDENT_CHAR.test(line[end + 1])) {
      end++;
      while (end < line.length && IDENT_CHAR.test(line[end])) end++;
      continue;
    }
    break;
  }
  return { start: start, end: end };
}

function pascalExpressionRange(document, position) {
  const line = document.lineAt(position.line).text;
  const wordRange = document.getWordRangeAtPosition(position, /[A-Za-z_][A-Za-z0-9_]*/);
  if (!wordRange) return undefined;
  const span = pascalExpressionSpan(line, wordRange.start.character, wordRange.end.character);
  return new vscode.Range(position.line, span.start, position.line, span.end);
}

const pascalEvaluatableExpressionProvider = {
  provideEvaluatableExpression(document, position) {
    const editor = vscode.window.activeTextEditor;
    if (editor && editor.document === document) {
      const sel = editor.selection;
      if (!sel.isEmpty && sel.contains(position))
        return new vscode.EvaluatableExpression(sel, document.getText(sel).trim());
    }
    const range = pascalExpressionRange(document, position);
    if (!range) return undefined;
    return new vscode.EvaluatableExpression(range);
  }
};

function activate(context) {
  const progress = new ProgressStatusBar();
  context.subscriptions.push(progress);

  // Same language ids the breakpoint contribution uses.
  context.subscriptions.push(
    vscode.languages.registerEvaluatableExpressionProvider(
      [{ language: 'objectpascal' }, { language: 'pascal' }, { language: 'delphi' }],
      pascalEvaluatableExpressionProvider)
  );

  const exceptionStops = new ExceptionStopTracker((value) =>
    vscode.commands.executeCommand('setContext', EXCEPTION_CONTEXT_KEY, value));
  exceptionStops.initialize();

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory(DEBUG_TYPE, {
      createDebugAdapterTracker(session) {
        return {
          onWillReceiveMessage: (message) => exceptionStops.handleClientMessage(session.id, message),
          onDidSendMessage: (message) => exceptionStops.handleAdapterMessage(session.id, message),
          onWillStopSession: () => exceptionStops.endSession(session.id),
          onExit: () => exceptionStops.endSession(session.id)
        };
      }
    })
  );

  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((event) => {
      if (event.event !== PROGRESS_EVENT) return;
      if (!event.session || event.session.type !== DEBUG_TYPE) return;
      progress.handleCustomEvent(event.session, event.body);
    })
  );

  context.subscriptions.push(
    vscode.debug.onDidTerminateDebugSession((session) => {
      progress.clearSession(session.id);
      exceptionStops.endSession(session.id);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.editExceptionRules', () =>
      openExceptionRulesEditor(context))
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.createRuleForException', () => {
      const session = vscode.debug.activeDebugSession;
      return wizard.createRuleForCurrentException(context,
        exceptionStops.threadIdFor(session ? session.id : undefined));
    })
  );

  context.subscriptions.push(
    // The argument is whatever VS Code chose to pass: an input entry's `args`
    // object, or - for a bare `${command:...}` variable - the enclosing debug
    // configuration. The picker sorts out which; see processPicker.js.
    vscode.commands.registerCommand('delphi-win64.pickProcess',
      (commandArgument) => processPicker.pickProcess(commandArgument))
  );

  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider(DEBUG_TYPE, {
      resolveDebugConfiguration: (folder, config) =>
        resolveAttachTarget(config, (argument) => processPicker.pickProcess(argument))
    })
  );

  return { exceptionStops: exceptionStops };
}

function deactivate() {
  // Everything is registered through context.subscriptions.
}

// ProgressStatusBar and ExceptionStopTracker are exported for the unit tests in
// install/extension-tests.
module.exports = {
  activate: activate,
  deactivate: deactivate,
  ProgressStatusBar: ProgressStatusBar,
  ExceptionStopTracker: ExceptionStopTracker,
  resolveAttachTarget: resolveAttachTarget,
  hasExplicitProcessId: hasExplicitProcessId,
  EXCEPTION_CONTEXT_KEY: EXCEPTION_CONTEXT_KEY,
  RESUME_REQUESTS: RESUME_REQUESTS,
  // Exported for tests: the hover-expression rule is plain text in, span out.
  pascalExpressionSpan: pascalExpressionSpan
};
