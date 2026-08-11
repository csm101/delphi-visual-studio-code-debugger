// The Delphi modules tree.
//
// A multi-package Delphi application loads dozens of BPLs, and the question
// that decides whether debugging works at all -- "does THIS module have debug
// information, and from which file" -- had no answer in the UI. It could be
// read out of the diagnostic log, which is off by default, or inferred from a
// breakpoint refusing to verify. Both are the long way round.
//
// The data comes from the adapter's `modules` request (the standard DAP one),
// which reports every loaded image with the formats actually registered for it:
// TD32 (embedded), .map, .rsm, .dcp, .jdbg, .tds. Naming the formats rather
// than saying "symbols" is the point -- "TD32" and ".map only" are different
// situations, and the second explains a missing local where a yes/no could not.
//
// The tree-shaping functions at the top are pure and unit-tested
// (test/modulesView.test.js); everything below them is VS Code plumbing.

'use strict';

// Sorted for reading rather than for the order the loader happened to report:
// the executable first (it is what you launched), then modules WITHOUT debug
// information -- the ones worth noticing -- then the rest alphabetically.
//
// Modules with no symbols are deliberately near the top: this view exists to
// answer "why can I not see anything in this package", and burying that at the
// bottom of forty rows would defeat it.
function sortModules(modules) {
  const rank = (m) => {
    if (m.delphiIsMain) return 0;
    return hasSymbols(m) ? 2 : 1;
  };
  return (modules || []).slice().sort((a, b) => {
    const ra = rank(a), rb = rank(b);
    if (ra !== rb) return ra - rb;
    return String(a.name || '').localeCompare(String(b.name || ''));
  });
}

function hasSymbols(module) {
  return !!(module && module.delphiFormats && module.delphiFormats.length > 0);
}

// What the row says next to the name. The symbolStatus the adapter computed is
// already written for a human ("TD32 (embedded), .map"); this only adds the
// address, because two loads of the same package at different bases is a real
// situation and the base is how you tell them apart.
function moduleDescription(module) {
  const parts = [];
  if (module.symbolStatus) parts.push(module.symbolStatus);
  if (module.addressRange) parts.push(module.addressRange);
  return parts.join('  ·  ');
}

function formatSize(bytes) {
  if (!(bytes > 0)) return '';
  if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  if (bytes >= 1024) return Math.round(bytes / 1024) + ' KB';
  return bytes + ' bytes';
}

// The detail rows under a module. Only what is known: a module the OS gave no
// path for shows no path row rather than an empty one.
function moduleDetails(module) {
  const rows = [];
  if (module.path) rows.push({ label: 'path', value: module.path, kind: 'path' });
  if (module.addressRange) rows.push({ label: 'loaded at', value: module.addressRange });
  const size = formatSize(module.delphiImageSize);
  if (size) rows.push({ label: 'image size', value: size });
  if (hasSymbols(module)) {
    rows.push({ label: 'debug info', value: module.delphiFormats.join(', ') });
  } else {
    // Said as a sentence, not as an empty list: the reason a breakpoint in this
    // module will not verify, in the place someone looks for it.
    rows.push({
      label: 'debug info',
      value: module.symbolStatus === 'indexing'
        ? 'still being indexed'
        : 'none found — breakpoints here cannot bind'
    });
  }
  return rows;
}

/* ------------------------------------------------------------------ view -- */

const vscode = require('vscode');

const DEBUG_TYPE = 'delphi-win64';

class DelphiModulesProvider {
  constructor() {
    this._emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._emitter.event;
    this.modules = [];
    this.error = '';
  }

  refresh() {
    const session = vscode.debug.activeDebugSession;
    if (!session || session.type !== DEBUG_TYPE) {
      this.modules = [];
      this.error = '';
      this._emitter.fire();
      return Promise.resolve();
    }
    return session.customRequest('modules', {}).then(
      (reply) => {
        this.modules = sortModules(reply && reply.modules);
        this.error = '';
        this._emitter.fire();
      },
      (err) => {
        // Reported in the tree rather than as a toast: a failure to list
        // modules is information about the session, and it belongs where the
        // list would have been.
        this.modules = [];
        this.error = err && err.message ? err.message : String(err);
        this._emitter.fire();
      });
  }

  getTreeItem(node) {
    if (node.kind === 'message') {
      const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.None);
      item.iconPath = new vscode.ThemeIcon('info');
      return item;
    }
    if (node.kind === 'detail') {
      const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.None);
      item.description = node.value;
      item.tooltip = node.value;
      if (node.detailKind === 'path') item.contextValue = 'delphiModulePath';
      return item;
    }
    const m = node.module;
    const item = new vscode.TreeItem(m.name, vscode.TreeItemCollapsibleState.Collapsed);
    item.description = moduleDescription(m);
    item.tooltip = (m.path || m.name) + '\n' + (m.symbolStatus || '');
    item.contextValue = 'delphiModule';
    // The icon carries the one fact worth seeing without reading: symbols or
    // not. A main module is marked separately because it is the thing launched.
    if (m.delphiIsMain)
      item.iconPath = new vscode.ThemeIcon('rocket');
    else if (hasSymbols(m))
      item.iconPath = new vscode.ThemeIcon('symbol-file');
    else
      item.iconPath = new vscode.ThemeIcon('warning');
    return item;
  }

  getChildren(node) {
    if (!node) {
      if (this.error)
        return [{ kind: 'message', label: 'Could not list modules: ' + this.error }];
      if (this.modules.length === 0)
        return [{ kind: 'message', label: 'No modules — start a Delphi debug session.' }];
      return this.modules.map((m) => ({ kind: 'module', module: m }));
    }
    if (node.kind === 'module')
      return moduleDetails(node.module).map((d) =>
        ({ kind: 'detail', label: d.label, value: d.value, detailKind: d.kind }));
    return [];
  }
}

function register(context) {
  const provider = new DelphiModulesProvider();
  context.subscriptions.push(
    vscode.window.registerTreeDataProvider('delphiModules', provider));

  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.refreshModules', () => provider.refresh()));

  context.subscriptions.push(
    vscode.commands.registerCommand('delphi-win64.copyModulePath', (node) => {
      const value = node && (node.value || (node.module && node.module.path));
      if (value) vscode.env.clipboard.writeText(value);
    }));

  // Refresh on the three things that change the answer: a session starting or
  // ending, a stop (symbols are commonly registered by then), and the adapter
  // saying the table moved -- which is what covers a package loaded while the
  // target is RUNNING, the case a stop-only refresh would miss entirely.
  context.subscriptions.push(
    vscode.debug.onDidStartDebugSession(() => provider.refresh()),
    vscode.debug.onDidTerminateDebugSession(() => provider.refresh()),
    vscode.debug.onDidChangeActiveDebugSession(() => provider.refresh()));

  return provider;
}

module.exports = {
  register: register,
  DelphiModulesProvider: DelphiModulesProvider,
  // Exported for the unit tests: the shaping is where a defect would be silent
  // (a module sorted out of sight, a status that reads as "fine" when it is not).
  sortModules: sortModules,
  hasSymbols: hasSymbols,
  moduleDescription: moduleDescription,
  moduleDetails: moduleDetails,
  formatSize: formatSize
};
