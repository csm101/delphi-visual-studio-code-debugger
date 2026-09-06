// Minimal stand-in for the `vscode` module so extension.js can be required
// outside VS Code. Only what the module body touches at load time needs to
// exist; the tests exercise pure functions, not the API surface.
class Range {
  constructor(sl, sc, el, ec) { this.sl = sl; this.sc = sc; this.el = el; this.ec = ec; }
}
class EvaluatableExpression {
  constructor(range, expression) { this.range = range; this.expression = expression; }
}
// A webview panel that records what was posted to it, so a test can assert what
// the pane would have DRAWN. Everything the memory view touches on a panel is
// here and nothing else.
function createWebviewPanel() {
  const panel = {
    title: '',
    posted: [],
    disposed: false,
    webview: {
      html: '',
      postMessage(msg) { panel.posted.push(msg); return Promise.resolve(true); },
      onDidReceiveMessage(handler) { panel.messageHandler = handler; return { dispose() {} }; }
    },
    onDidDispose(handler) { panel.disposeHandler = handler; return { dispose() {} }; },
    reveal() {},
    dispose() { panel.disposed = true; }
  };
  return panel;
}

class TreeItem {
  constructor(label, collapsibleState) {
    this.label = label;
    this.collapsibleState = collapsibleState;
  }
}
class ThemeIcon {
  constructor(id) { this.id = id; }
}
class EventEmitter {
  constructor() { this.listeners = []; }
  get event() { return (fn) => { this.listeners.push(fn); return { dispose() {} }; }; }
  fire(value) { this.listeners.forEach((fn) => fn(value)); }
}

module.exports = {
  Range: Range,
  EvaluatableExpression: EvaluatableExpression,
  TreeItem: TreeItem,
  ThemeIcon: ThemeIcon,
  EventEmitter: EventEmitter,
  TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
  ViewColumn: { Beside: -2 },
  env: { clipboard: { writeText: () => Promise.resolve() } },
  window: {
    activeTextEditor: undefined,
    createStatusBarItem: () => ({ dispose() {} }),
    createWebviewPanel: createWebviewPanel,
    registerTreeDataProvider: () => ({ dispose() {} }),
    createTreeView: () => ({ message: '', dispose() {} }),
    showInformationMessage: () => Promise.resolve(undefined),
    showWarningMessage: () => Promise.resolve(undefined),
    showInputBox: () => Promise.resolve(undefined)
  },
  workspace: { getConfiguration: () => ({ get: (_k, d) => d }) },
  languages: { registerEvaluatableExpressionProvider: () => ({ dispose() {} }) },
  debug: {
    activeDebugSession: undefined,
    registerDebugAdapterTrackerFactory: () => ({ dispose() {} }),
    onDidReceiveDebugSessionCustomEvent: () => ({ dispose() {} }),
    onDidTerminateDebugSession: () => ({ dispose() {} }),
    onDidStartDebugSession: () => ({ dispose() {} }),
    onDidChangeActiveDebugSession: () => ({ dispose() {} })
  },
  commands: { registerCommand: () => ({ dispose() {} }), executeCommand: () => {} },
  StatusBarAlignment: { Left: 1, Right: 2 },
  Uri: { parse: (s) => s }
};
