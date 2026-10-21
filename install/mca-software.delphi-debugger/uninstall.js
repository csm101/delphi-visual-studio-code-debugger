'use strict';

/*
 * The extension's `vscode:uninstall` hook (package.json "scripts"). VS Code runs
 * it with plain Node - no `vscode` API, no window - once the extension is
 * COMPLETELY uninstalled, never for an update: at a restart after the
 * uninstall, when VS Code deletes the folders listed in `.obsolete`, just
 * before deleting this one (after `code --uninstall-extension`, VS Code 1.142
 * marks the folder at the first start and runs this at the second). It undoes
 * what the extension set up outside the editor, so Claude Code does not keep
 * starting a debugger that is no longer installed:
 *
 *   - Claude Code's user-scope registration `delphi-debugger` (and the legacy
 *     name), when it points at the stable copy;
 *   - the entries an older Setup.exe wrote into VS Code's user mcp.json, again
 *     only when they point at the stable copy;
 *   - the stable copy itself, %LOCALAPPDATA%\DelphiWin64Debugger.
 *
 * Nothing at all is touched while the extension is still installed in any
 * VS Code-family editor of this user: the stable copy and the registration
 * serve all of them. A registration on any other executable - a development
 * build, a hand-made entry - is someone's decision and is never removed.
 *
 * What it did goes to %TEMP%\delphi-debugger-uninstall.log, the only place a
 * hook without a window can report to.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const mcpServer = require('./mcpServer');

const EXTENSION_ID = 'mca-software.delphi-debugger';
// The per-user profile folders of the editors Install.dpr installs into
// (its FamilyEditors table); each keeps an `extensions` folder.
const EDITOR_PROFILE_DIRS = ['.vscode', '.vscode-insiders', '.cursor', '.windsurf', '.vscode-oss', '.trae'];
// User data folders under %APPDATA% whose User\mcp.json register-mcp.ps1 wrote.
const VSCODE_USER_DATA_DIRS = ['Code', 'Code - Insiders'];

/** The extensions folders to look in: this copy's own, then every editor's. */
function extensionsDirsToCheck(env, ownExtensionsDir) {
  const dirs = [];
  const add = (dir) => {
    if (dir && !dirs.some((known) => mcpServer.samePath(known, dir))) dirs.push(dir);
  };
  add(ownExtensionsDir);
  if (env.USERPROFILE)
    EDITOR_PROFILE_DIRS.forEach((profile) => add(path.join(env.USERPROFILE, profile, 'extensions')));
  return dirs;
}

/**
 * Whether an extensions folder still lists this extension. The editor drops
 * the entry from extensions.json at uninstall time and parks the folder in
 * `.obsolete` until it restarts, so the entry - not the folder - is the answer.
 */
function stillInstalledIn(extensionsDir, readFile) {
  let entries;
  try { entries = JSON.parse(readFile(path.join(extensionsDir, 'extensions.json'))); } catch (e) { return false; }
  if (!Array.isArray(entries)) return false;
  return entries.some((e) => e && e.identifier && typeof e.identifier.id === 'string' &&
    e.identifier.id.toLowerCase() === EXTENSION_ID);
}

/**
 * Removes this server's entries from one VS Code user mcp.json, when they point
 * at `serverPath`. Only a file that is plain JSON is rewritten (register-mcp.ps1
 * writes it that way); a file with comments is left alone rather than
 * reformatted. Returns the names removed.
 */
function cleanVsCodeMcpJson(file, serverPath, fsApi) {
  let text;
  try { text = fsApi.readFileSync(file, 'utf8'); } catch (e) { return []; }
  let root;
  try { root = JSON.parse((text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text)); } catch (e) { return []; }
  const servers = root && root.servers;
  if (!servers || typeof servers !== 'object') return [];

  const removed = [];
  for (const name of [mcpServer.SERVER_NAME, mcpServer.LEGACY_SERVER_NAME]) {
    const entry = servers[name];
    if (entry && mcpServer.samePath(entry.command, serverPath)) {
      delete servers[name];
      removed.push(name);
    }
  }
  if (removed.length === 0) return removed;
  const indent = (/\n([ \t]+)"/.exec(text) || [null, '    '])[1];
  const eol = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
  fsApi.writeFileSync(file, JSON.stringify(root, null, indent).replace(/\n/g, eol) + eol, 'utf8');
  return removed;
}

/**
 * Deletes the stable copy: the server, its companions, anything a refresh
 * parked, then the folder. A file still locked by a running server is
 * reported and left; nothing would ever run again to retry, so the log says so.
 */
function removeStableCopy(dir, fsApi) {
  const outcome = { deleted: [], locked: [] };
  let names;
  try { names = fsApi.readdirSync(dir); } catch (e) { return outcome; }
  const ours = new Set([mcpServer.SERVER_EXE].concat(mcpServer.COMPANION_FILES).map((n) => n.toLowerCase()));
  for (const name of names) {
    if (!ours.has(name.toLowerCase()) && !/\.old\d+$/i.test(name)) continue;
    const file = path.join(dir, name);
    try { fsApi.unlinkSync(file); outcome.deleted.push(file); } catch (e) { outcome.locked.push(file); }
  }
  try { fsApi.rmdirSync(dir); } catch (e) { /* not empty: someone else's file, or a locked one */ }
  return outcome;
}

/**
 * The whole hook, with every outside dependency injectable. Resolves with the
 * lines of its log; never rejects.
 */
async function cleanUpAfterUninstall(options) {
  const o = options || {};
  const env = o.env || process.env;
  const fsApi = o.fs || fs;
  const readFile = (file) => fsApi.readFileSync(file, 'utf8');
  const log = [];

  const ownExtensionsDir = o.ownExtensionsDir || path.dirname(__dirname);
  const stillThere = extensionsDirsToCheck(env, ownExtensionsDir).filter((dir) => stillInstalledIn(dir, readFile));
  if (stillThere.length > 0) {
    log.push('Still installed in ' + stillThere.join(', ') + ': the MCP server and its registrations are kept.');
    return log;
  }

  const serverPath = mcpServer.stableServerPath(env);
  if (!serverPath) {
    log.push('LOCALAPPDATA is not set: no stable copy to clean up.');
    return log;
  }

  try {
    const removed = await mcpServer.removeClaudeRegistrations(serverPath, o.claude || mcpServer.claudeCliDeps());
    log.push(removed.length > 0
      ? 'Claude Code: removed ' + removed.join(', ') + '.'
      : 'Claude Code: no registration pointing at ' + serverPath + ' (or no claude CLI).');
  } catch (error) {
    log.push('Claude Code: not cleaned up: ' + (error && error.message ? error.message : String(error)));
  }

  if (env.APPDATA) {
    for (const userDataDir of VSCODE_USER_DATA_DIRS) {
      const file = path.join(env.APPDATA, userDataDir, 'User', 'mcp.json');
      const removed = cleanVsCodeMcpJson(file, serverPath, fsApi);
      if (removed.length > 0) log.push(file + ': removed ' + removed.join(', ') + '.');
    }
  }

  const stable = removeStableCopy(path.dirname(serverPath), fsApi);
  if (stable.deleted.length > 0) log.push('Deleted ' + stable.deleted.join(', ') + '.');
  if (stable.locked.length > 0)
    log.push('Could not delete (in use - close Claude Code, then delete by hand): ' + stable.locked.join(', ') + '.');
  return log;
}

if (require.main === module) {
  cleanUpAfterUninstall()
    .catch((error) => ['Failed: ' + (error && error.stack ? error.stack : String(error))])
    .then((lines) => {
      const text = new Date().toISOString() + ' Delphi Debugger uninstall hook\r\n' +
        lines.map((line) => '  ' + line).join('\r\n') + '\r\n';
      try { fs.appendFileSync(path.join(os.tmpdir(), 'delphi-debugger-uninstall.log'), text, 'utf8'); } catch (e) { /* nowhere left to say it */ }
    });
}

module.exports = {
  EXTENSION_ID: EXTENSION_ID,
  EDITOR_PROFILE_DIRS: EDITOR_PROFILE_DIRS,
  extensionsDirsToCheck: extensionsDirsToCheck,
  stillInstalledIn: stillInstalledIn,
  cleanVsCodeMcpJson: cleanVsCodeMcpJson,
  removeStableCopy: removeStableCopy,
  cleanUpAfterUninstall: cleanUpAfterUninstall
};
