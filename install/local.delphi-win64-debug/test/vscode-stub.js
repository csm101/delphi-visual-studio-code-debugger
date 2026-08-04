// Minimal stand-in for the `vscode` module so extension.js can be required
// outside VS Code. Only what the module body touches at load time needs to
// exist; the tests exercise pure functions, not the API surface.
class Range {
  constructor(sl, sc, el, ec) { this.sl = sl; this.sc = sc; this.el = el; this.ec = ec; }
}
class EvaluatableExpression {
  constructor(range, expression) { this.range = range; this.expression = expression; }
}
module.exports = {
  Range: Range,
  EvaluatableExpression: EvaluatableExpression,
  window: { activeTextEditor: undefined, createStatusBarItem: () => ({ dispose() {} }) },
  languages: { registerEvaluatableExpressionProvider: () => ({ dispose() {} }) },
  debug: {
    registerDebugAdapterTrackerFactory: () => ({ dispose() {} }),
    onDidReceiveDebugSessionCustomEvent: () => ({ dispose() {} }),
    onDidTerminateDebugSession: () => ({ dispose() {} })
  },
  commands: { registerCommand: () => ({ dispose() {} }), executeCommand: () => {} },
  StatusBarAlignment: { Left: 1, Right: 2 },
  Uri: { parse: (s) => s }
};
