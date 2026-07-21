'use strict';

/*
 * "Delphi Win64: Create a rule for this exception".
 *
 * Only meaningful while the debuggee is stopped ON an exception, which is what
 * the `delphiWin64StoppedOnException` context key (extension.js) gates on.
 *
 * The flow:
 *   1. find the thread that is stopped - from the tracker's `stopped` event,
 *      else `vscode.debug.activeStackItem`, else a `threads` request. Never
 *      assume a single thread;
 *   2. ask the adapter for `exceptionInfo` (exceptionId = class name,
 *      details.message) and `stackTrace` (top frame = the raise site);
 *   3. offer the intents a developer actually has, pre-filled from that
 *      exception (rules.suggestRulesForException);
 *   4. ask where to write it - project launch configuration or the shared file;
 *   5. insert the rule at the TOP of the list, because matching is
 *      first-match-wins.
 */

const vscode = require('vscode');
const rules = require('./rules');
const editor = require('./exceptionRulesEditor');

const DEBUG_TYPE = 'delphi-win64';

function unitNameFromSource(source) {
  if (!source) return '';
  const name = source.name || source.path || '';
  const base = String(name).split(/[\\/]/).pop();
  return base.replace(/\.[^.]*$/, '');
}

/**
 * The thread the exception stopped on. `hintThreadId` is what the debug
 * adapter tracker saw in the `stopped` event and is the most reliable source;
 * everything after it is a fallback for the case where the tracker missed it.
 */
async function resolveThreadId(session, hintThreadId) {
  if (typeof hintThreadId === 'number') return hintThreadId;

  const stackItem = vscode.debug.activeStackItem;
  if (stackItem && typeof stackItem.threadId === 'number' &&
      (!stackItem.session || stackItem.session.id === session.id)) {
    return stackItem.threadId;
  }

  let response;
  try {
    response = await session.customRequest('threads');
  } catch (error) {
    return undefined;
  }
  const threads = (response && response.threads) || [];
  if (threads.length === 0) return undefined;
  if (threads.length === 1) return threads[0].id;

  const picked = await vscode.window.showQuickPick(
    threads.map((thread) => ({
      label: thread.name || ('Thread ' + thread.id),
      description: String(thread.id),
      threadId: thread.id
    })),
    { placeHolder: 'Which thread is stopped on the exception?' }
  );
  return picked ? picked.threadId : undefined;
}

/** exceptionInfo + the top stack frame, with everything optional. */
async function readExceptionContext(session, threadId) {
  const context = { exceptionClass: '', message: '', unitName: '', line: undefined };

  try {
    const info = await session.customRequest('exceptionInfo', { threadId: threadId });
    if (info) {
      context.exceptionClass = info.exceptionId || '';
      const details = info.details || {};
      context.message = details.message || info.description || '';
    }
  } catch (error) {
    context.exceptionInfoFailed = String((error && error.message) || error);
  }

  try {
    const stack = await session.customRequest('stackTrace', { threadId: threadId, startFrame: 0, levels: 1 });
    const frame = stack && stack.stackFrames && stack.stackFrames[0];
    if (frame) {
      context.unitName = unitNameFromSource(frame.source);
      if (typeof frame.line === 'number' && frame.line > 0) context.line = frame.line;
      context.frameName = frame.name;
    }
  } catch (error) {
    context.stackTraceFailed = String((error && error.message) || error);
  }

  return context;
}

function describeException(context) {
  const head = context.exceptionClass || 'Exception';
  const message = context.message ? ': ' + rules.shortenMessage(context.message, 70) : '';
  const site = context.unitName
    ? '  —  ' + context.unitName + (context.line !== undefined ? ':' + context.line : '')
    : '';
  return head + message + site;
}

async function pickSuggestion(context) {
  const suggestions = rules.suggestRulesForException(context);
  const picked = await vscode.window.showQuickPick(suggestions, {
    placeHolder: 'New rule for ' + describeException(context) +
      ' — it is inserted first, and the first matching rule wins',
    matchOnDetail: true
  });
  return picked;
}

/**
 * Runs the whole flow. `hintThreadId` comes from the debug adapter tracker.
 * Returns the rule that was created (for tests); undefined when the user
 * cancelled or nothing could be read.
 */
async function createRuleForCurrentException(context, hintThreadId) {
  const session = vscode.debug.activeDebugSession;
  if (!session || session.type !== DEBUG_TYPE) {
    vscode.window.showErrorMessage(
      'No Delphi Win64 debug session is active. This command works while stopped on an exception.');
    return undefined;
  }

  const threadId = await resolveThreadId(session, hintThreadId);
  if (threadId === undefined) {
    vscode.window.showErrorMessage('Could not determine which thread is stopped on the exception.');
    return undefined;
  }

  const exceptionContext = await readExceptionContext(session, threadId);
  if (!exceptionContext.exceptionClass && !exceptionContext.unitName) {
    vscode.window.showErrorMessage(
      'The debugger reported no exception for this stop. Use it while stopped on an exception.');
    return undefined;
  }

  const suggestion = await pickSuggestion(exceptionContext);
  if (!suggestion) return undefined;

  const scan = await editor.collectTargets();
  if (scan.parseErrors.length) {
    vscode.window.showWarningMessage('Could not parse: ' + scan.parseErrors.join('; '));
  }
  const target = await editor.pickTarget(scan.targets,
    'Where should the new rule go? It is inserted first — the first matching rule wins');
  if (!target) return undefined;

  // First-match-wins: a new, more specific rule is worthless at the bottom.
  const newRules = [suggestion.rule].concat(target.exceptionRules);

  if (suggestion.openEditor) {
    editor.openEditorPanel(context, target, newRules);
    return suggestion.rule;
  }

  try {
    await editor.writeRules(target, newRules.map(rules.normalizeRule));
    target.exceptionRules = newRules;
    vscode.window.showInformationMessage(
      'Added as rule #1 in ' + target.documentLabel + ': ' + rules.describeRule(suggestion.rule) +
      '. Review and save the file.');
  } catch (error) {
    vscode.window.showErrorMessage('Could not add the rule: ' + ((error && error.message) || error));
    return undefined;
  }
  return suggestion.rule;
}

module.exports = {
  createRuleForCurrentException: createRuleForCurrentException,
  readExceptionContext: readExceptionContext,
  resolveThreadId: resolveThreadId,
  unitNameFromSource: unitNameFromSource,
  describeException: describeException
};
