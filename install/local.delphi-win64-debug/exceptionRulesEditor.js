'use strict';

/*
 * Webview editor for exception rules.
 *
 * Two kinds of target can be edited:
 *
 *   - a `delphi-win64` launch configuration in `.vscode/launch.json` or in a
 *     `.code-workspace` file (the project's own `exceptionRules`);
 *   - the machine-wide shared file, `%USERPROFILE%\.DelphiWinDebugger\
 *     exceptionRules.json` by default, or wherever `globalExceptionRulesPath`
 *     points (see globalRules.js).
 *
 * Writing back is deliberately conservative in both cases. `launch.json` is
 * JSONC and is normally full of the user's own comments; re-serializing the
 * whole `configurations` array (which is what
 * `workspace.getConfiguration('launch').update('configurations', ...)` does)
 * would silently delete every comment inside it. Instead we parse the file
 * ourselves, locate the exact character range of the value to replace, and
 * apply a single-range WorkspaceEdit. Everything outside that range - comments
 * included - is left byte-for-byte identical. The shared file gets the same
 * treatment, and additionally keeps its shape: a bare array stays an array, an
 * object keeps every key other than `exceptionRules`.
 *
 * See install/extension-tests/test-jsonc-edit.js and test-global-rules.js for
 * the regression tests that prove this.
 */

const vscode = require('vscode');
const jsonc = require('./jsonc');
const rules = require('./rules');
const globalRules = require('./globalRules');

const DEBUG_TYPE = 'delphi-win64';

/** Files that may declare launch configurations, with the path to reach them. */
function launchDocumentCandidates() {
  const candidates = [];
  for (const folder of vscode.workspace.workspaceFolders || []) {
    candidates.push({
      uri: vscode.Uri.joinPath(folder.uri, '.vscode', 'launch.json'),
      rootPath: ['configurations'],
      label: `${folder.name}/.vscode/launch.json`,
      workspaceFolder: folder.uri.fsPath,
      workspaceFolderBasename: folder.name
    });
  }
  const workspaceFile = vscode.workspace.workspaceFile;
  if (workspaceFile && workspaceFile.scheme !== 'untitled') {
    candidates.push({
      uri: workspaceFile,
      rootPath: ['launch', 'configurations'],
      label: workspaceFile.path.split('/').pop(),
      workspaceFolder: (vscode.workspace.workspaceFolders || [])[0]
        ? vscode.workspace.workspaceFolders[0].uri.fsPath
        : undefined,
      workspaceFolderBasename: (vscode.workspace.workspaceFolders || [])[0]
        ? vscode.workspace.workspaceFolders[0].name
        : undefined
    });
  }
  return candidates;
}

/**
 * Collects every delphi-win64 configuration found in the candidate documents.
 * Parse failures are reported but do not abort the scan.
 */
async function findDelphiConfigurations() {
  const found = [];
  const parseErrors = [];
  for (const candidate of launchDocumentCandidates()) {
    let document;
    try {
      document = await vscode.workspace.openTextDocument(candidate.uri);
    } catch (error) {
      continue; // file does not exist - normal
    }
    let configurationsNode;
    try {
      const root = jsonc.parseTree(document.getText());
      configurationsNode = jsonc.findNodeAtPath(root, candidate.rootPath);
    } catch (error) {
      parseErrors.push(`${candidate.label}: ${error.message}`);
      continue;
    }
    if (!configurationsNode || configurationsNode.type !== 'array') continue;
    configurationsNode.children.forEach((configurationNode, index) => {
      if (configurationNode.type !== 'object') return;
      const configuration = jsonc.getNodeValue(configurationNode);
      if (configuration.type !== DEBUG_TYPE) return;
      found.push({
        kind: 'launch',
        uri: candidate.uri,
        rootPath: candidate.rootPath,
        documentLabel: candidate.label,
        index: index,
        name: configuration.name || `configuration #${index + 1}`,
        exceptionRules: Array.isArray(configuration.exceptionRules) ? configuration.exceptionRules : [],
        useGlobalExceptionRules: configuration.useGlobalExceptionRules,
        globalExceptionRulesPath: configuration.globalExceptionRulesPath,
        workspaceFolder: candidate.workspaceFolder,
        workspaceFolderBasename: candidate.workspaceFolderBasename
      });
    });
  }
  return { found: found, parseErrors: parseErrors };
}

/**
 * The shared-rules target, honouring a `globalExceptionRulesPath` override from
 * any of the workspace's configurations. The file does not have to exist yet;
 * it is created on demand when the user saves.
 */
function buildGlobalTarget(configurations) {
  const resolved = globalRules.resolveGlobalRulesPath(configurations);
  const file = globalRules.readGlobalRulesFile(resolved.filePath);
  const disabledEverywhere = resolved.totalConfigurations > 0 && resolved.enabledConfigurations === 0;
  return {
    kind: 'global',
    filePath: resolved.filePath,
    documentLabel: resolved.filePath,
    name: 'Shared rules (all projects)',
    exceptionRules: file.rules,
    exists: file.exists,
    shape: file.shape,
    parseError: file.error,
    overriddenBy: resolved.overriddenBy,
    disabledEverywhere: disabledEverywhere
  };
}

/** Everything the user may pick in the target QuickPick. */
async function collectTargets() {
  const scan = await findDelphiConfigurations();
  const targets = scan.found.slice();
  targets.push(buildGlobalTarget(scan.found));
  return { targets: targets, parseErrors: scan.parseErrors, launchCount: scan.found.length };
}

function describeTarget(target) {
  if (target.kind !== 'global') {
    return {
      label: target.name,
      description: `${target.exceptionRules.length} rule(s)`,
      detail: target.documentLabel,
      target: target
    };
  }
  const notes = [];
  if (!target.exists) notes.push('will be created');
  if (target.shape === 'invalid') notes.push('unreadable: ' + target.parseError);
  if (target.overriddenBy) notes.push('path from "' + target.overriddenBy + '"');
  if (target.disabledEverywhere) notes.push('useGlobalExceptionRules is false in every configuration');
  return {
    label: '$(globe) ' + target.name,
    description: `${target.exceptionRules.length} rule(s)`,
    detail: target.filePath + (notes.length ? '  —  ' + notes.join('; ') : ''),
    target: target
  };
}

async function pickTarget(targets, placeHolder) {
  if (targets.length === 1) return targets[0];
  const picked = await vscode.window.showQuickPick(
    targets.map(describeTarget),
    { placeHolder: placeHolder || 'Select where the exception rules live' }
  );
  return picked ? picked.target : undefined;
}

function makeNonce() {
  let nonce = '';
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 32; i++) nonce += alphabet[Math.floor(Math.random() * alphabet.length)];
  return nonce;
}

function buildHtml(webview, extensionUri, initialState) {
  const nonce = makeNonce();
  const resource = (...parts) => webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, ...parts));
  // JSON embedded in a <script> block must not be able to close the block.
  const payload = JSON.stringify(initialState).replace(/</g, '\\u003c');
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource}; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="${resource('media', 'rulesEditor.css')}">
<title>Exception Rules</title>
</head>
<body>
<div id="app"></div>
<script nonce="${nonce}">window.INITIAL_STATE = ${payload};</script>
<script nonce="${nonce}" src="${resource('rules.js')}"></script>
<script nonce="${nonce}" src="${resource('media', 'rulesEditor.js')}"></script>
</body>
</html>`;
}

/**
 * Re-reads the document, re-locates the configuration and replaces exactly the
 * `exceptionRules` value range. Returns the number of the line that changed so
 * the caller can reveal it.
 */
async function writeLaunchRules(target, newRules) {
  const document = await vscode.workspace.openTextDocument(target.uri);
  const text = document.getText();
  const root = jsonc.parseTree(text);
  const configurationsNode = jsonc.findNodeAtPath(root, target.rootPath);
  if (!configurationsNode || configurationsNode.type !== 'array') {
    throw new Error('The configurations array is no longer present in ' + target.documentLabel + '.');
  }
  const configurationNode = configurationsNode.children[target.index];
  if (!configurationNode || configurationNode.type !== 'object') {
    throw new Error('The launch configuration moved in ' + target.documentLabel + '. Reopen the editor and try again.');
  }
  const configuration = jsonc.getNodeValue(configurationNode);
  if (configuration.type !== DEBUG_TYPE || (configuration.name || '') !== target.name) {
    throw new Error('"' + target.name + '" is no longer at the same position in ' +
      target.documentLabel + '. Reopen the editor and try again.');
  }

  const edit = jsonc.computeSetPropertyEdit(text, configurationNode, 'exceptionRules',
    (baseIndent, eol) => rules.serializeRules(newRules, baseIndent, eol));
  return applyRangeEdit(target.uri, document, edit, target.documentLabel);
}

/**
 * Same idea for the shared file. It is created first (empty) when missing, so
 * the change goes through the normal document/undo path instead of a blind
 * write to disk.
 */
async function writeGlobalRules(target, newRules) {
  globalRules.ensureGlobalRulesFile(target.filePath);
  const uri = vscode.Uri.file(target.filePath);
  const document = await vscode.workspace.openTextDocument(uri);
  const edit = globalRules.computeGlobalRulesEdit(document.getText(), newRules);
  return applyRangeEdit(uri, document, edit, target.documentLabel);
}

async function applyRangeEdit(uri, document, edit, label) {
  const workspaceEdit = new vscode.WorkspaceEdit();
  workspaceEdit.replace(
    uri,
    new vscode.Range(document.positionAt(edit.offset), document.positionAt(edit.offset + edit.length)),
    edit.newText
  );
  const applied = await vscode.workspace.applyEdit(workspaceEdit);
  if (!applied) throw new Error('VS Code refused the edit to ' + label + '.');
  return document.positionAt(edit.offset).line;
}

function writeRules(target, newRules) {
  return target.kind === 'global' ? writeGlobalRules(target, newRules) : writeLaunchRules(target, newRules);
}

function targetUri(target) {
  return target.kind === 'global' ? vscode.Uri.file(target.filePath) : target.uri;
}

/** Opens the webview on a target, optionally with rules it does not have yet. */
function openEditorPanel(context, target, initialRules) {
  const readOnly = !vscode.workspace.isTrusted;
  const panel = vscode.window.createWebviewPanel(
    'delphiExceptionRules',
    `Exception Rules — ${target.name}`,
    vscode.ViewColumn.Active,
    {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [context.extensionUri]
    }
  );
  const shared = target.kind === 'global';
  panel.webview.html = buildHtml(panel.webview, context.extensionUri, {
    configurationName: target.name,
    documentLabel: target.documentLabel,
    rules: initialRules || target.exceptionRules,
    readOnly: readOnly,
    readOnlyReason: readOnly ? 'This workspace is not trusted, so the rules file cannot be modified.' : '',
    fileNoun: shared ? 'the shared rules file' : 'launch.json',
    saveLabel: shared ? 'Save to the shared rules file' : 'Save to launch.json',
    saveTitle: shared
      ? 'Write these rules back into the machine-wide shared rules file'
      : 'Write these rules back into the launch configuration'
  });

  // The latest draft the webview has reported as unsaved, or null when it is
  // clean. A webview cannot cancel its own disposal -- onDidDispose fires after
  // the fact -- so keeping the draft here is what makes closing the tab
  // recoverable instead of a silent discard.
  let pendingDraft = null;

  panel.webview.onDidReceiveMessage(async (message) => {
    if (!message) return;
    if (message.type === 'dirty') {
      pendingDraft = message.dirty ? message.rules : null;
      return;
    }
    if (message.type === 'copy') {
      await vscode.env.clipboard.writeText(message.text);
      vscode.window.showInformationMessage('Exception rules copied to the clipboard.');
      return;
    }
    if (message.type !== 'save') return;

    const problems = rules.validateRules(message.rules);
    if (problems.length) {
      panel.webview.postMessage({ type: 'saveRejected', problems: problems });
      return;
    }
    try {
      const line = await writeRules(target, message.rules.map(rules.normalizeRule));
      target.exceptionRules = message.rules;
      panel.webview.postMessage({ type: 'saved' });
      const document = await vscode.workspace.openTextDocument(targetUri(target));
      const editor = await vscode.window.showTextDocument(document, {
        preview: false,
        viewColumn: vscode.ViewColumn.Beside
      });
      editor.revealRange(new vscode.Range(line, 0, line, 0), vscode.TextEditorRevealType.InCenter);
      vscode.window.showInformationMessage(
        `Exception rules updated in ${target.documentLabel}. Review and save the file.`);
    } catch (error) {
      panel.webview.postMessage({ type: 'saveFailed', message: String(error.message || error) });
      vscode.window.showErrorMessage('Could not update exception rules: ' + (error.message || error));
    }
  }, undefined, context.subscriptions);

  panel.onDidDispose(() => {
    if (!pendingDraft) return;
    const draft = pendingDraft;
    pendingDraft = null;
    vscode.window.showWarningMessage(
      `Exception rules for ${target.name} were closed with unsaved changes.`,
      'Reopen With Those Changes'
    ).then((choice) => {
      if (choice) openEditorPanel(context, target, draft);
    });
  }, undefined, context.subscriptions);

  context.subscriptions.push(panel);
  return panel;
}

async function openExceptionRulesEditor(context) {
  const scan = await collectTargets();
  if (scan.parseErrors.length) {
    vscode.window.showWarningMessage('Could not parse: ' + scan.parseErrors.join('; '));
  }
  const target = await pickTarget(scan.targets);
  if (!target) return;
  return openEditorPanel(context, target);
}

module.exports = {
  openExceptionRulesEditor: openExceptionRulesEditor,
  openEditorPanel: openEditorPanel,
  findDelphiConfigurations: findDelphiConfigurations,
  collectTargets: collectTargets,
  buildGlobalTarget: buildGlobalTarget,
  describeTarget: describeTarget,
  pickTarget: pickTarget,
  writeRules: writeRules
};
