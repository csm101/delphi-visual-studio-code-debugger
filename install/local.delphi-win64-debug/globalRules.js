'use strict';

/*
 * The machine-wide (shared) exception-rules file.
 *
 * The adapter reads a baseline rule list from
 * `%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json` (overridable per
 * launch configuration through `globalExceptionRulesPath`, switchable through
 * `useGlobalExceptionRules`). Project rules are evaluated first, then these.
 *
 * Two shapes are accepted by the adapter and both must survive a round-trip
 * through the editor:
 *
 *   { "exceptionRules": [ ... ], "anythingElse": ... }   <- object
 *   [ ... ]                                              <- bare array
 *
 * So this module never re-serializes the whole file: it computes a single text
 * edit (exactly like jsonc.js does for launch.json) that replaces only the rule
 * array, leaving comments, formatting and any sibling key untouched. An object
 * file stays an object, an array file stays an array.
 *
 * No `vscode` dependency: plain Node, so install/extension-tests can exercise
 * it directly.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const jsonc = require('./jsonc');
const rules = require('./rules');

const GLOBAL_RULES_DIRECTORY = '.DelphiWinDebugger';
const GLOBAL_RULES_FILE = 'exceptionRules.json';
const DEFAULT_EOL = '\r\n';

/** `%USERPROFILE%\.DelphiWinDebugger\exceptionRules.json` by default. */
function defaultGlobalRulesPath(homeDirectory) {
  const home = homeDirectory || process.env.USERPROFILE || os.homedir();
  return path.join(home, GLOBAL_RULES_DIRECTORY, GLOBAL_RULES_FILE);
}

/**
 * Expands the subset of VS Code variables that can plausibly appear in
 * `globalExceptionRulesPath`. An unknown variable is left as-is rather than
 * replaced by an empty string: a visibly unresolved path is easier to diagnose
 * than a silently wrong one.
 */
function expandVariables(text, values) {
  const scope = values || {};
  return String(text).replace(/\$\{([^}]+)\}/g, (whole, name) => {
    if (name.indexOf('env:') === 0) {
      const value = process.env[name.slice(4)];
      return value === undefined ? whole : value;
    }
    const value = scope[name];
    return value === undefined ? whole : value;
  });
}

/**
 * Which shared file a set of launch configurations points at.
 *
 * `configurations` are the parsed `delphi-win64` configurations, in the order
 * they were found. The first one that overrides `globalExceptionRulesPath`
 * wins; if none does, the default location is used. A configuration that sets
 * `useGlobalExceptionRules: false` does not veto the file - other
 * configurations (and other projects) may still use it - but it is reported so
 * the UI can say so.
 */
function resolveGlobalRulesPath(configurations, options) {
  const settings = options || {};
  const list = configurations || [];
  const override = list.find((configuration) =>
    typeof configuration.globalExceptionRulesPath === 'string' &&
    configuration.globalExceptionRulesPath.trim() !== '');
  const usedBy = list.filter((configuration) => configuration.useGlobalExceptionRules !== false);
  if (override) {
    const expanded = expandVariables(override.globalExceptionRulesPath, {
      workspaceFolder: override.workspaceFolder || settings.workspaceFolder,
      workspaceFolderBasename: override.workspaceFolderBasename || settings.workspaceFolderBasename,
      userHome: settings.homeDirectory || os.homedir()
    });
    return {
      filePath: path.normalize(expanded),
      overriddenBy: override.name,
      enabledConfigurations: usedBy.length,
      totalConfigurations: list.length
    };
  }
  return {
    filePath: defaultGlobalRulesPath(settings.homeDirectory),
    overriddenBy: undefined,
    enabledConfigurations: usedBy.length,
    totalConfigurations: list.length
  };
}

/**
 * Reads the rule array out of the file text and remembers its shape.
 * Returns { shape: 'object' | 'array' | 'empty', rules }. Throws JsoncError on
 * malformed JSON, and a plain Error when the root is neither object nor array.
 */
function parseGlobalRules(text) {
  if (typeof text !== 'string' || text.trim() === '') {
    return { shape: 'empty', rules: [] };
  }
  const root = jsonc.parseTree(text);
  if (!root) return { shape: 'empty', rules: [] };
  if (root.type === 'array') {
    return { shape: 'array', rules: jsonc.getNodeValue(root) };
  }
  if (root.type !== 'object') {
    throw new Error('the shared rules file must contain a JSON object or a JSON array');
  }
  const value = jsonc.getNodeValue(root);
  const found = value.exceptionRules;
  return { shape: 'object', rules: Array.isArray(found) ? found : [] };
}

/**
 * The single text edit that stores `newRules` in the file, preserving its
 * shape. Returns { offset, length, newText } - the same contract as
 * jsonc.computeSetPropertyEdit, so it can drive a WorkspaceEdit.
 */
function computeGlobalRulesEdit(text, newRules) {
  const source = typeof text === 'string' ? text : '';
  const serialize = (baseIndent, eol) => rules.serializeRules(newRules, baseIndent, eol);

  if (source.trim() === '') {
    const eol = DEFAULT_EOL;
    return {
      offset: 0,
      length: source.length,
      newText: '{' + eol + '  "exceptionRules": ' + serialize('  ', eol) + eol + '}' + eol
    };
  }

  const eol = jsonc.detectEol(source);
  const root = jsonc.parseTree(source);
  if (root && root.type === 'array') {
    // Bare array file: replace the array itself and nothing else, so a header
    // comment above it survives.
    return {
      offset: root.offset,
      length: root.length,
      newText: serialize(jsonc.lineIndentAt(source, root.offset), eol)
    };
  }
  if (!root || root.type !== 'object') {
    throw new Error('the shared rules file must contain a JSON object or a JSON array');
  }
  return jsonc.computeSetPropertyEdit(source, root, 'exceptionRules', serialize);
}

/** Convenience for tests and for the non-VS-Code write path. */
function applyGlobalRules(text, newRules) {
  return jsonc.applyEdit(typeof text === 'string' ? text : '', computeGlobalRulesEdit(text, newRules));
}

function readGlobalRulesFile(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    return { exists: false, shape: 'empty', rules: [], text: '' };
  }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  try {
    const parsed = parseGlobalRules(text);
    return { exists: true, shape: parsed.shape, rules: parsed.rules, text: text };
  } catch (error) {
    return { exists: true, shape: 'invalid', rules: [], text: text, error: error.message || String(error) };
  }
}

/**
 * Makes sure the file (and its directory) exist, so it can be opened as a
 * document and edited like any other. A file that is already there is left
 * exactly as it is. Returns true when it had to be created.
 */
function ensureGlobalRulesFile(filePath) {
  if (fs.existsSync(filePath)) return false;
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const eol = DEFAULT_EOL;
  fs.writeFileSync(filePath,
    '{' + eol + '  "exceptionRules": []' + eol + '}' + eol, 'utf8');
  return true;
}

/** Writes the rules straight to disk, preserving the file's shape. */
function writeGlobalRulesFile(filePath, newRules) {
  const created = ensureGlobalRulesFile(filePath);
  const text = fs.readFileSync(filePath, 'utf8');
  fs.writeFileSync(filePath, applyGlobalRules(text, newRules), 'utf8');
  return created;
}

module.exports = {
  GLOBAL_RULES_DIRECTORY: GLOBAL_RULES_DIRECTORY,
  GLOBAL_RULES_FILE: GLOBAL_RULES_FILE,
  defaultGlobalRulesPath: defaultGlobalRulesPath,
  expandVariables: expandVariables,
  resolveGlobalRulesPath: resolveGlobalRulesPath,
  parseGlobalRules: parseGlobalRules,
  computeGlobalRulesEdit: computeGlobalRulesEdit,
  applyGlobalRules: applyGlobalRules,
  readGlobalRulesFile: readGlobalRulesFile,
  ensureGlobalRulesFile: ensureGlobalRulesFile,
  writeGlobalRulesFile: writeGlobalRulesFile
};
