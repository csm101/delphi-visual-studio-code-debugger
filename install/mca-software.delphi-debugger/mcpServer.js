'use strict';

/*
 * The MCP server (DelphiDebuggerMcp.exe) as distributed by the extension.
 *
 * The server serves agents OUTSIDE VS Code too (Claude Code, Claude Desktop),
 * so the extension folder - whose path carries the version and changes on
 * every update - cannot be the address they are registered with. Two things
 * happen on activation:
 *
 *   1. VS Code-hosted agents get the server through
 *      `vscode.lm.registerMcpServerDefinitionProvider` (VS Code 1.101+; the API
 *      is absent on older builds and on some editors of the family, so it is
 *      guarded). That definition points at the BUNDLED exe, so it updates with
 *      the extension and needs no mcp.json.
 *
 *   2. A STABLE copy is kept at %LOCALAPPDATA%\DelphiWin64Debugger\ - the same
 *      folder Setup.exe installs into - and refreshed when the bundled exe is
 *      newer. Windows refuses to overwrite or delete a running executable but
 *      allows RENAMING it, so the running file is renamed to the first free
 *      `.oldN` name, the new one copied under the original name, and every
 *      `*.old*` deleted where possible; whatever is still locked goes at a
 *      later activation. Silent by design: at most a line in the output
 *      channel.
 *
 * Plus the command "Delphi: Register MCP Server with Claude Code", which runs
 * the same `claude mcp add` the setup zip's register-mcp.ps1 performs, against
 * the stable copy.
 */

const path = require('path');

const SERVER_EXE = 'DelphiDebuggerMcp.exe';
// Files the server needs next to itself: the optional disassembly backend and
// its licence. Both are looked for beside the exe (McpServer.pas), so the
// stable copy must carry them too or disassembly reports UNAVAILABLE there.
const COMPANION_FILES = ['Zydis.dll', 'Zydis-LICENSE.txt'];
const STABLE_DIR_NAME = 'DelphiWin64Debugger';
const SERVER_NAME = 'delphi-debugger';
// The name register-mcp.ps1 used before the rename; removed when found so two
// registrations do not point at two copies of the same server.
const LEGACY_SERVER_NAME = 'delphi-win64-debugger';
const PROVIDER_ID = 'delphi-debugger';

function stableInstallDir(env) {
  const base = (env || process.env).LOCALAPPDATA;
  return base ? path.join(base, STABLE_DIR_NAME) : undefined;
}

function stableServerPath(env) {
  const dir = stableInstallDir(env);
  return dir ? path.join(dir, SERVER_EXE) : undefined;
}

/**
 * Whether the stable copy must be refreshed from the bundled file. Stats are
 * `{ exists, size, mtimeMs }` (or undefined for a missing file). Decided from
 * the timestamps and sizes alone, without reading either file: "newer" means
 * newer, and the copy below stamps the stable file with the bundled mtime, so
 * an unchanged bundle is a no-op at every later activation.
 */
function needsRefresh(bundled, stable) {
  if (!bundled || !bundled.exists) return false;
  if (!stable || !stable.exists) return true;
  if (bundled.size !== stable.size) return true;
  return bundled.mtimeMs > stable.mtimeMs;
}

/** `name.old1`, `name.old2`, ... - the first not taken. */
function nextFreeOldName(dir, fileName, exists) {
  for (let n = 1; ; n++) {
    const candidate = path.join(dir, fileName + '.old' + n);
    if (!exists(candidate)) return candidate;
  }
}

function statOf(fs, filePath) {
  try {
    const st = fs.statSync(filePath);
    return { exists: st.isFile(), size: st.size, mtimeMs: st.mtimeMs, mtime: st.mtime, atime: st.atime };
  } catch (e) {
    return { exists: false };
  }
}

/**
 * Refreshes the stable copy of the server and its companion files from the
 * extension folder. Returns what happened, for the log line. Never throws: a
 * refresh that cannot happen (a locked file, a missing LOCALAPPDATA) is a
 * later activation's problem, not a failed activation.
 */
function refreshStableCopy(options) {
  const fs = options.fs || require('fs');
  const bundledDir = options.bundledDir;
  const stableDir = options.stableDir;
  const outcome = { refreshed: [], renamed: [], purged: [], failed: [] };
  if (!stableDir || !bundledDir) return outcome;

  const exists = (p) => statOf(fs, p).exists;

  for (const fileName of [SERVER_EXE].concat(COMPANION_FILES)) {
    const source = path.join(bundledDir, fileName);
    const target = path.join(stableDir, fileName);
    const bundled = statOf(fs, source);
    const stable = statOf(fs, target);
    if (!needsRefresh(bundled, stable)) continue;
    try {
      fs.mkdirSync(stableDir, { recursive: true });
      if (stable.exists) {
        const parked = nextFreeOldName(stableDir, fileName, exists);
        fs.renameSync(target, parked);
        outcome.renamed.push(parked);
      }
      fs.copyFileSync(source, target);
      // Stamp the copy with the bundle's time, so "bundled newer than stable"
      // stays false until the bundle actually changes.
      try { fs.utimesSync(target, bundled.atime || new Date(), bundled.mtime || new Date()); } catch (e) { /* cosmetic */ }
      outcome.refreshed.push(target);
    } catch (error) {
      outcome.failed.push(fileName + ': ' + (error && error.message ? error.message : String(error)));
    }
  }

  // Parked files from this or any earlier refresh: delete what is no longer
  // running. A still-locked one simply stays for next time.
  let entries = [];
  try { entries = fs.readdirSync(stableDir); } catch (e) { entries = []; }
  for (const name of entries) {
    if (!/\.old\d+$/i.test(name)) continue;
    const parked = path.join(stableDir, name);
    try {
      fs.unlinkSync(parked);
      outcome.purged.push(parked);
    } catch (e) {
      // locked by a session that is still running
    }
  }
  return outcome;
}

function describeOutcome(outcome) {
  const parts = [];
  if (outcome.refreshed.length) parts.push('refreshed ' + outcome.refreshed.join(', '));
  if (outcome.purged.length) parts.push('removed ' + outcome.purged.length + ' parked file(s)');
  if (outcome.failed.length) parts.push('could not refresh ' + outcome.failed.join('; '));
  return parts.length ? 'MCP server: ' + parts.join('; ') : '';
}

/**
 * Registers the server with VS Code's own MCP registry, when the API exists.
 * Returns the disposable, or undefined when the host has no such API - which
 * is not an error: the stable copy and the Claude command still work.
 */
function registerDefinitionProvider(vscode, serverPath, version) {
  const lm = vscode && vscode.lm;
  if (!lm || typeof lm.registerMcpServerDefinitionProvider !== 'function' ||
      typeof vscode.McpStdioServerDefinition !== 'function') {
    return undefined;
  }
  return lm.registerMcpServerDefinitionProvider(PROVIDER_ID, {
    provideMcpServerDefinitions: () =>
      [new vscode.McpStdioServerDefinition('Delphi Debugger', serverPath, [], {}, version)]
  });
}

/**
 * The `claude mcp add` register-mcp.ps1 performs, as command lines: the legacy
 * name and any previous registration are removed first so a re-run updates in
 * place. Quoting is for cmd.exe, which is what `exec` uses on Windows.
 */
function claudeCommandLines(serverPath) {
  return [
    'claude mcp remove ' + LEGACY_SERVER_NAME + ' -s user',
    'claude mcp remove ' + SERVER_NAME + ' -s user',
    'claude mcp add ' + SERVER_NAME + ' -s user -- "' + serverPath + '"'
  ];
}

/**
 * Runs the registration. `deps.exec(commandLine, callback)` is child_process
 * exec in production; `deps.hasClaude()` says whether the CLI is on PATH.
 * Reports through `deps.showInformation` / `deps.showWarning`.
 */
async function registerWithClaudeCode(serverPath, deps) {
  const d = deps || {};
  if (!serverPath) {
    d.showWarning('The MCP server has no stable install location (LOCALAPPDATA is not set).');
    return false;
  }
  if (!(await d.hasClaude())) {
    d.showInformation('The claude CLI is not on PATH, so the MCP server was not registered. ' +
      'Install Claude Code, then run this command again - or register by hand: ' +
      claudeCommandLines(serverPath)[2]);
    return false;
  }
  const lines = claudeCommandLines(serverPath);
  // The two removals may legitimately fail (nothing to remove).
  await runIgnoringFailure(d.exec, lines[0]);
  await runIgnoringFailure(d.exec, lines[1]);
  const result = await runCollecting(d.exec, lines[2]);
  if (result.error) {
    d.showWarning('claude mcp add failed: ' + (result.stderr || result.stdout || result.error.message).trim());
    return false;
  }
  d.showInformation('Registered the Delphi MCP server with Claude Code as "' + SERVER_NAME + '" (' +
    serverPath + '). Restart Claude Code to pick it up.');
  return true;
}

function runCollecting(exec, commandLine) {
  return new Promise((resolve) => {
    exec(commandLine, (error, stdout, stderr) =>
      resolve({ error: error, stdout: String(stdout || ''), stderr: String(stderr || '') }));
  });
}

function runIgnoringFailure(exec, commandLine) {
  return runCollecting(exec, commandLine).then(() => undefined);
}

module.exports = {
  SERVER_EXE: SERVER_EXE,
  COMPANION_FILES: COMPANION_FILES,
  SERVER_NAME: SERVER_NAME,
  LEGACY_SERVER_NAME: LEGACY_SERVER_NAME,
  PROVIDER_ID: PROVIDER_ID,
  stableInstallDir: stableInstallDir,
  stableServerPath: stableServerPath,
  needsRefresh: needsRefresh,
  nextFreeOldName: nextFreeOldName,
  refreshStableCopy: refreshStableCopy,
  describeOutcome: describeOutcome,
  registerDefinitionProvider: registerDefinitionProvider,
  claudeCommandLines: claudeCommandLines,
  registerWithClaudeCode: registerWithClaudeCode
};
