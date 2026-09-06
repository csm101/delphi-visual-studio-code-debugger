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
 *
 * 6. The same provider fills in a configuration that names a delphi-devkit
 *    (DDK) project - `{ "type": "delphi", "request": "launch", "ddkProject":
 *    "MyApp" }` - from DDK's debug target: executable or host application,
 *    symbols, sources, packages, arguments (see ddkTarget.js). It runs after
 *    variable substitution, so a hand-written entry may still use `${...}`.
 *
 * 7. Distribution of the MCP server: a VS Code MCP registration on the bundled
 *    exe, a stable copy for agents outside VS Code, and a command that
 *    registers that copy with Claude Code (see mcpServer.js).
 *
 * 8. A one-time warning when the old sideloaded copy of this extension
 *    (`local.delphi-win64-debug`) is still installed beside the Marketplace
 *    one - both would contribute the same debug types.
 *
 * Two debug types are contributed: `delphi`, the primary one, and
 * `delphi-win64`, the original name kept as an alias so every existing
 * launch.json and the RAD Studio plugin's output keep working. They share the
 * adapter, the trackers, the provider and every command.
 */

const vscode = require('vscode');
const { openExceptionRulesEditor } = require('./exceptionRulesEditor');
const wizard = require('./exceptionRuleWizard');
const processPicker = require('./processPicker');
const memoryView = require('./memoryView');
const modulesView = require('./modulesView');
const ddkTarget = require('./ddkTarget');
const mcpServer = require('./mcpServer');

const DEBUG_TYPE = 'delphi';
const LEGACY_DEBUG_TYPE = 'delphi-win64';
const DEBUG_TYPES = [DEBUG_TYPE, LEGACY_DEBUG_TYPE];
// The id the sideloaded extension had before it was published under
// `mca-software.delphi-debugger`. Install.exe removes it; a Marketplace install
// cannot, so activation checks for it.
const OLD_EXTENSION_ID = 'local.delphi-win64-debug';

function isDelphiSession(session) {
  return !!session && DEBUG_TYPES.indexOf(session.type) !== -1;
}
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

/**
 * The second provider pass, after variable substitution: a configuration that
 * names a DDK project is completed from DDK's debug target, then - for an
 * attach - goes through the process picker like any other attach entry (the
 * first pass saw no `processName` yet, DDK has just supplied it). A failure
 * is shown and the session is aborted (`undefined`): starting the adapter
 * with a half-empty configuration would only produce a less clear error.
 */
async function resolveDdkTarget(config, deps) {
  const d = deps || {};
  const vs = d.vscode || vscode;
  if (!ddkTarget.needsDebugTarget(config)) return config;
  let resolved;
  try {
    resolved = await ddkTarget.resolveDdkConfiguration(config, {
      vscode: vs,
      execFile: d.execFile,
      showWarning: (text) => vs.window.showWarningMessage('Delphi Debugger (DDK): ' + text)
    });
  } catch (error) {
    vs.window.showErrorMessage('Delphi Debugger: ' + (error && error.message ? error.message : String(error)));
    return undefined;
  }
  return resolveAttachTarget(resolved, d.pick || ((argument) => processPicker.pickProcess(argument)));
}

/**
 * A Marketplace install cannot remove the sideloaded copy the way Install.exe
 * does, and two extensions contributing `delphi-win64` means every session
 * start asks which one to use. So: one warning, with the fix on a button.
 * Nothing is uninstalled without that click.
 */
async function warnAboutOldCopy(deps) {
  const d = deps || {};
  const vs = d.vscode || vscode;
  if (!vs.extensions || typeof vs.extensions.getExtension !== 'function') return false;
  if (!vs.extensions.getExtension(OLD_EXTENSION_ID)) return false;
  const remove = 'Remove old version';
  const choice = await vs.window.showWarningMessage(
    'An older copy of this debugger (' + OLD_EXTENSION_ID + ') is still installed; both contribute ' +
    'the same debug types. Remove the old one and keep the Marketplace version.',
    remove);
  if (choice !== remove) return true;
  try {
    await vs.commands.executeCommand('workbench.extensions.uninstallExtension', OLD_EXTENSION_ID);
  } catch (error) {
    vs.window.showErrorMessage('Could not uninstall ' + OLD_EXTENSION_ID + ': ' +
      (error && error.message ? error.message : String(error)));
    return true;
  }
  const reload = 'Reload Window';
  const next = await vs.window.showInformationMessage(
    'Removed ' + OLD_EXTENSION_ID + '. Reload the window to finish.', reload);
  if (next === reload) vs.commands.executeCommand('workbench.action.reloadWindow');
  return true;
}

/**
 * The status-bar text for the auto-release switch, from the adapter's reply to
 * delphiSetStepIsolationRelease ({ enabled, releaseMs, frozenPerStep, text }).
 * The adapter's own sentence is used when it sends one (the same text the MCP
 * tool reports); the fallback composes it, so both states stay explicit and the
 * OFF text names Pause as the escape hatch.
 */
function stepIsolationReleaseText(reply) {
  const r = reply || {};
  if (typeof r.text === 'string' && r.text.trim() !== '') return r.text;
  if (r.frozenPerStep === false) {
    return 'Auto-release of frozen threads: not applicable - this session never freezes other ' +
      'threads for a step (stepIsolation "none")';
  }
  if (r.enabled) {
    const seconds = (Number(r.releaseMs) > 0 ? Number(r.releaseMs) / 1000 : 3).toFixed(1);
    return 'Auto-release of frozen threads: ON - a step-over that waits on a thread this step ' +
      'froze is released after ' + seconds + " s, or at once when the lock's owner is known";
  }
  return 'Auto-release of frozen threads: OFF - other threads stay frozen for the whole step, ' +
    'even if the stepped-over call waits on one of them; use Pause to break in';
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

// The debugger's own diagnostics -- symbol loading, modules without debug
// info, warnings -- arrive as `delphiLog` custom events and go to a dedicated
// Output channel, which is why they no longer bury the program's output in the
// Debug Console. A multi-package application emits hundreds of "no debug info
// for X" lines before it prints anything of its own.
//
// A custom event rather than an `output` event on purpose: a debug adapter
// tracker can OBSERVE output events but cannot suppress them, so filtering
// here would have shown every line twice.
const DIAGNOSTIC_EVENT = 'delphiLog';
// Matches the command category and the settings title. The name is what a user
// scans the Output dropdown for, so having three spellings of the same product
// in three menus is a way to look absent while being present.
const DIAGNOSTIC_CHANNEL_NAME = 'Delphi Debugger';

const UPDATE_LAST_CHECK_KEY = 'delphiWin64.updateCheck.lastCheck';
const UPDATE_SKIPPED_KEY    = 'delphiWin64.updateCheck.skippedVersion';

// Asks GitHub, at most once a day, whether a newer release exists -- because
// this extension is installed by an installer rather than from a marketplace,
// so nothing else would ever tell the user.
//
// Everything here is written to stay out of the way: it never blocks
// activation, it says nothing at all when the check fails, and "Skip this
// version" is remembered so the same release is announced once and not every
// day until it is installed.
async function checkForUpdate(context, deps) {
  const d = deps || {};
  const vs = d.vscode || vscode;
  const updates = d.updateCheck || require('./updateCheck');
  const now = d.now === undefined ? Date.now() : d.now;

  const config = vs.workspace.getConfiguration('delphi-win64');
  if (!config.get('checkForUpdates', true)) return;

  const state = context.globalState;
  if (!updates.shouldCheck(state.get(UPDATE_LAST_CHECK_KEY), now)) return;
  // Stamp BEFORE the request, not after: a GitHub that is slow or unreachable
  // must not turn every activation into another attempt.
  await state.update(UPDATE_LAST_CHECK_KEY, now);

  const pkg = context.extension && context.extension.packageJSON;
  if (!pkg || !pkg.version) return;
  const repoUrl = pkg.repository && pkg.repository.url;

  const latest = await updates.fetchLatestRelease(repoUrl, d.httpGet);
  if (!latest) return;                                    // silent by design
  if (updates.compareVersions(latest.version, pkg.version) <= 0) return;
  if (state.get(UPDATE_SKIPPED_KEY) === latest.version) return;

  const download = 'Download';
  const skip = 'Skip this version';
  const choice = await vs.window.showInformationMessage(
    'Delphi Win64 Debugger ' + latest.version + ' is available (you have ' +
      pkg.version + ').',
    download, skip);
  if (choice === download && latest.url)
    vs.env.openExternal(vs.Uri.parse(latest.url));
  else if (choice === skip)
    await state.update(UPDATE_SKIPPED_KEY, latest.version);
}

// The adapter answers `readMemory` / `writeMemory` and puts a `memoryReference`
// on every variable that has an address -- but the view that USES them, the
// "View Binary Data" entry and the hex pane behind it, is not part of the
// editor: it comes from the Hex Editor extension. Without it the entry is simply
// absent from the menu, which reads as "this debugger cannot inspect memory"
// rather than as a missing companion extension. Measured on a real profile: the
// capability was advertised, the memoryReference was there, and the menu entry
// was nowhere.
//
// Offered, not enforced. Memory inspection is an addition, not a prerequisite,
// so this must never be an `extensionDependencies` entry: that would make a
// marketplace that cannot be reached block the debugger itself over an optional
// view. Shown at most once per installation -- a prompt that returns every
// session is a nuisance, and the answer "no" is a legitimate answer.
// The editor's built-in memory pane is a file abstraction in which the
// memoryReference IS byte 0: it cannot scroll before the value, mark which bytes
// belong to it, or show what changed between two stops. This extension ships its
// own view (memoryView.js), so the built-in one is redundant -- and it is not
// silent about being there: it puts an inline icon on every variable row that
// has an address.
//
// Withdrawing the two capabilities is what removes it. The REQUESTS stay: the
// adapter still serves readMemory/writeMemory, and the view reaches them through
// customRequest, which is not gated on an advertised capability. A client with
// no Delphi extension keeps the capabilities and its own pane, which is why the
// switch is passed here rather than defaulted in the adapter.
const STOCK_MEMORY_VIEW_SETTING = 'delphi-win64.stockMemoryView';

function adapterArguments() {
  const enabled = vscode.workspace.getConfiguration()
    .get(STOCK_MEMORY_VIEW_SETTING, false);
  return enabled ? [] : ['--no-stock-memory-view'];
}

// Where the adapter exe is, taken from the manifest rather than assumed: the
// dev-loop script (scripts/install-dev.ps1) REWRITES `program` to point at the compiler
// build output, and hardcoding the extension-relative copy here would silently
// run yesterday's adapter in a dev session.
function adapterExecutablePath(context) {
  const path = require('path');
  let program = './VisualStudioCodeDelphiDebugger.exe';
  try {
    const manifest = require(path.join(context.extensionPath, 'package.json'));
    const debuggers = (manifest.contributes && manifest.contributes.debuggers) || [];
    // Both debug types name the same adapter; the first that names one wins.
    const entry = debuggers.find((d) => d && DEBUG_TYPES.indexOf(d.type) !== -1 && d.program);
    if (entry && entry.program) program = entry.program;
  } catch (err) {
    // Fall through to the relative default: an unreadable manifest is not a
    // reason to fail to start a debug session.
  }
  return path.isAbsolute(program) ? program : path.join(context.extensionPath, program);
}

function activate(context) {
  const progress = new ProgressStatusBar();
  context.subscriptions.push(progress);

  // Created lazily on the first diagnostic: an empty channel in the dropdown
  // for a session that never logged anything is clutter.
  let diagnostics;
  const appendDiagnostic = (text) => {
    if (!text) return;
    if (!diagnostics) {
      diagnostics = vscode.window.createOutputChannel(DIAGNOSTIC_CHANNEL_NAME);
      context.subscriptions.push(diagnostics);
    }
    diagnostics.appendLine(String(text).replace(/\r?\n$/, ''));
  };

  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((event) => {
      if (event.event !== DIAGNOSTIC_EVENT) return;
      if (!isDelphiSession(event.session)) return;
      appendDiagnostic(event.body && event.body.text);
    })
  );

  // Deliberately not awaited: activation must not wait on the network, and a
  // failure here is not the user's problem. Any error is swallowed for the same
  // reason -- an update check that reports its own troubles is a nuisance.
  checkForUpdate(context).catch(() => {});
  warnAboutOldCopy().catch(() => {});

  // Launching the adapter ourselves is the only way to pass it a command-line
  // switch: the manifest's `program` takes no arguments. Guarded like the hover
  // provider -- if an editor of the VS Code family lacks this API, an unguarded
  // call would throw out of activate() and take the debug-type registration with
  // it, trading a redundant memory pane for a debugger that cannot start.
  if (vscode.debug.registerDebugAdapterDescriptorFactory && vscode.DebugAdapterExecutable) {
    DEBUG_TYPES.forEach((type) => context.subscriptions.push(
      vscode.debug.registerDebugAdapterDescriptorFactory(type, {
        createDebugAdapterDescriptor: () =>
          new vscode.DebugAdapterExecutable(adapterExecutablePath(context), adapterArguments())
      })
    ));
  }

  setUpMcpServerDistribution(context, appendDiagnostic);

  // Raw stack sweep, from the Call Stack title bar. It used to be a launch-time
  // flag only, which meant editing launch.json and restarting for something you
  // reach for exactly when a stack has just come up short.
  //
  // The message deliberately restates what the results ARE, every time it is
  // switched on: a raw hit is a POSITION on the stack, and one of them may be a
  // return address left behind by a call that already returned. A toggle that
  // quietly added plausible-looking frames to a call stack would undo the care
  // taken to mark them.
  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.toggleRawStackScan', async () => {
      const session = vscode.debug.activeDebugSession;
      if (!isDelphiSession(session)) {
        vscode.window.showInformationMessage(
          'Raw stack scan applies to a running Delphi Win64 debug session.');
        return;
      }
      try {
        const reply = await session.customRequest('delphiSetRawStackScan', {});
        const on = !!(reply && reply.enabled);
        vscode.window.setStatusBarMessage(
          on ? 'Delphi: raw stack scan ON — extra entries are POSITIONS on the stack, not callers'
             : 'Delphi: raw stack scan OFF',
          6000);
      } catch (err) {
        vscode.window.showWarningMessage(
          'Could not toggle the raw stack scan: ' + (err && err.message ? err.message : String(err)));
      }
    })
  );

  // The step-isolation deadlock detector, switched for the rest of the session.
  // A step keeps every other thread frozen; the detector releases them when the
  // stepped thread is found waiting on one of them. Someone debugging exactly
  // that contention, one thread at a time, turns it OFF -- and the message
  // states what is selected NOW, with Pause named as the way out of a strict
  // step that waits forever.
  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.toggleStepIsolationRelease', async () => {
      const session = vscode.debug.activeDebugSession;
      if (!isDelphiSession(session)) {
        vscode.window.showInformationMessage(
          'Auto-release of frozen threads applies to a running Delphi debug session.');
        return;
      }
      try {
        const reply = await session.customRequest('delphiSetStepIsolationRelease', {});
        vscode.window.setStatusBarMessage('Delphi: ' + stepIsolationReleaseText(reply), 10000);
      } catch (err) {
        vscode.window.showWarningMessage(
          'Could not switch the auto-release of frozen threads: ' + (err && err.message ? err.message : String(err)));
      }
    })
  );

  // Same language ids the breakpoint contribution uses.
  //
  // Guarded, and not out of superstition: this extension is installed into every
  // editor of the VS Code family (Cursor, Windsurf, VSCodium, Trae), and if one
  // of them lacks this API an unguarded call throws out of activate() and takes
  // the DEBUG TYPE REGISTRATION down with it -- trading richer hovers for an
  // extension that cannot start a session at all. Losing the hover is the
  // proportionate failure.
  if (vscode.languages && vscode.languages.registerEvaluatableExpressionProvider) {
    context.subscriptions.push(
      vscode.languages.registerEvaluatableExpressionProvider(
        [{ language: 'objectpascal' }, { language: 'pascal' }, { language: 'delphi' }],
        pascalEvaluatableExpressionProvider)
    );
  }

  const exceptionStops = new ExceptionStopTracker((value) =>
    vscode.commands.executeCommand('setContext', EXCEPTION_CONTEXT_KEY, value));
  exceptionStops.initialize();

  DEBUG_TYPES.forEach((type) => context.subscriptions.push(
    vscode.debug.registerDebugAdapterTrackerFactory(type, {
      createDebugAdapterTracker(session) {
        return {
          onWillReceiveMessage: (message) => exceptionStops.handleClientMessage(session.id, message),
          onDidSendMessage: (message) => {
            exceptionStops.handleAdapterMessage(session.id, message);
            // Both are "the bytes on screen may be from before": a stop means
            // the target ran, and `memory` is the adapter reporting a write it
            // performed itself (setVariable, writeMemory).
            if (message && message.type === 'event' &&
                (message.event === 'stopped' || message.event === 'memory')) {
              memoryView.refreshSession(session.id);
            }
            // The module table changed, or a stop makes it worth re-reading:
            // symbols are commonly registered by the time the target stops.
            if (message && message.type === 'event' &&
                (message.event === 'delphiModulesChanged' || message.event === 'stopped')) {
              modules.refresh();
            }
          },
          onWillStopSession: () => { exceptionStops.endSession(session.id);
                                     memoryView.closeSession(session.id); },
          onExit: () => { exceptionStops.endSession(session.id);
                          memoryView.closeSession(session.id); }
        };
      }
    })
  ));

  context.subscriptions.push(
    vscode.debug.onDidReceiveDebugSessionCustomEvent((event) => {
      if (event.event !== PROGRESS_EVENT) return;
      if (!isDelphiSession(event.session)) return;
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
    vscode.commands.registerCommand('delphi-win64.viewMemory',
      (commandArgument) => memoryView.openMemoryView(context, commandArgument))
  );

  // The safe-getter safelist. A getter-backed property row defers as "(expand
  // to evaluate)"; these actions write the user's decision through the adapter
  // (which owns the file and the reload), and the panel re-renders at once via
  // the invalidated event the adapter sends back. The row names its own
  // safelist entry (delphiSafelistKey), so what the user clicked and what the
  // file says cannot disagree.
  //
  // 'forget' is the way back out. Without it "Always Evaluate This Property"
  // was a one-way door: undoing it meant hand-editing a JSON file whose path
  // the UI never showed. The confirmation names that file too, so a decision
  // stays reversible even when the row it was made on is long gone.
  function safelistAction(verdict) {
    return async (commandArgument) => {
      const session = vscode.debug.activeDebugSession;
      if (!isDelphiSession(session)) return;
      // evaluateName, NOT a custom field: VS Code propagates a variable's
      // standard DAP fields into a context-menu command but drops the ones the
      // adapter added, so delphiSafelistKey never arrives here. The expression
      // does, and the adapter rebuilds the key from it exactly as the expansion
      // does. A row without one (a synthetic group, a scope) names nothing.
      const variable = commandArgument && (commandArgument.variable || commandArgument);
      const expression = variable &&
        (variable.evaluateName || (typeof variable.name === 'string' ? variable.name : ''));
      if (!expression) return;
      const command = verdict === 'forget' ? 'delphiSafelistRemove' : 'delphiSafelistAdd';
      try {
        const reply = await session.customRequest(command,
          { expression: expression, verdict: verdict });
        if (reply && reply.applicable === false) {
          vscode.window.showInformationMessage(
            '"' + expression + '" is read directly (not through a getter), so it ' +
            'needs no permission — it is always shown.');
          return;
        }
        const outcome = {
          deny:   'will never auto-evaluate',
          forget: 'is back to asking before it evaluates',
        }[verdict] || 'will auto-evaluate from now on';
        // The file is named because it is the only way to review or undo these
        // decisions in bulk; the adapter returns its path with every reply.
        const where = reply && reply.userFile ? ' — recorded in ' + reply.userFile : '';
        vscode.window.setStatusBarMessage(
          'Delphi: "' + expression + '" ' + outcome + where, 8000);
      } catch (err) {
        vscode.window.showWarningMessage(
          'Safelist update failed: ' + (err && err.message ? err.message : String(err)));
      }
    };
  }
  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.safelistAllow', safelistAction('allow')),
    vscode.commands.registerCommand('delphi-win64.safelistDeny', safelistAction('deny')),
    vscode.commands.registerCommand('delphi-win64.safelistForget', safelistAction('forget')));

  const modules = modulesView.register(context);

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

  // Two passes on purpose. The attach picker runs BEFORE variable substitution
  // (a `${command:...}` processId must stay unexpanded, or it would prompt
  // twice); the DDK step runs AFTER it, so `${workspaceFolder}` and friends in
  // a hand-written `ddkProject` or `delphiProjectFile` are already resolved.
  DEBUG_TYPES.forEach((type) => context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider(type, {
      resolveDebugConfiguration: (folder, config) =>
        resolveAttachTarget(config, (argument) => processPicker.pickProcess(argument)),
      resolveDebugConfigurationWithSubstitutedVariables: (folder, config) =>
        resolveDdkTarget(config)
    })
  ));

  return { exceptionStops: exceptionStops };
}

/**
 * The MCP server as shipped inside the extension: registered with VS Code's
 * own MCP registry (bundled exe, updates with the extension), mirrored to the
 * stable per-user folder for agents outside VS Code, and a command to register
 * that copy with Claude Code. Every part is guarded: none of this may cost the
 * debug type.
 */
function setUpMcpServerDistribution(context, appendDiagnostic) {
  const path = require('path');
  const version = (context.extension && context.extension.packageJSON && context.extension.packageJSON.version) || '';
  const describe = (error) => (error && error.message ? error.message : String(error));

  // No extension path means no bundled exe to distribute (the unit tests
  // activate with a bare context); the Claude command is still registered.
  if (typeof context.extensionPath === 'string' && context.extensionPath !== '') {
    try {
      const outcome = mcpServer.refreshStableCopy({
        bundledDir: context.extensionPath,
        stableDir: mcpServer.stableInstallDir(process.env)
      });
      appendDiagnostic(mcpServer.describeOutcome(outcome));
    } catch (error) {
      appendDiagnostic('MCP server: stable copy not refreshed: ' + describe(error));
    }

    try {
      const bundledExe = path.join(context.extensionPath, mcpServer.SERVER_EXE);
      const registration = mcpServer.registerDefinitionProvider(vscode, bundledExe, version);
      if (registration) context.subscriptions.push(registration);
    } catch (error) {
      appendDiagnostic('MCP server: VS Code registration failed: ' + describe(error));
    }
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.registerMcpWithClaude', () => {
      const childProcess = require('child_process');
      return mcpServer.registerWithClaudeCode(mcpServer.stableServerPath(process.env), {
        hasClaude: () => new Promise((resolve) =>
          childProcess.exec('where claude', (error) => resolve(!error))),
        exec: (commandLine, callback) => childProcess.exec(commandLine, { windowsHide: true }, callback),
        showInformation: (text) => vscode.window.showInformationMessage(text),
        showWarning: (text) => vscode.window.showWarningMessage(text)
      });
    })
  );
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
  resolveDdkTarget: resolveDdkTarget,
  warnAboutOldCopy: warnAboutOldCopy,
  hasExplicitProcessId: hasExplicitProcessId,
  DEBUG_TYPES: DEBUG_TYPES,
  OLD_EXTENSION_ID: OLD_EXTENSION_ID,
  EXCEPTION_CONTEXT_KEY: EXCEPTION_CONTEXT_KEY,
  RESUME_REQUESTS: RESUME_REQUESTS,
  // Exported for tests: the hover-expression rule is plain text in, span out.
  pascalExpressionSpan: pascalExpressionSpan,
  stepIsolationReleaseText: stepIsolationReleaseText,
  checkForUpdate: checkForUpdate
};
