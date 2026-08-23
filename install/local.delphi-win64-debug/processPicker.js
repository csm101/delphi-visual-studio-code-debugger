'use strict';

/*
 * `delphi-win64.pickProcess` - the process picker used by an attach
 * configuration:
 *
 *   { "type": "delphi-win64", "request": "attach",
 *     "processId": "${command:delphi-win64.pickProcess}" }
 *
 * ------------------------------------------------------------ where the list
 *                                                               comes from
 *
 * The debug adapter, not `tasklist`. `VisualStudioCodeDelphiDebugger.exe
 * --list-processes [name]` prints one line of JSON and exits, built on the
 * Win32 APIs the debugger already uses (DebuggerCore\ProcessEnum.pas).
 *
 * The extension host cannot call Win32 itself without a native module, which is
 * a dependency this extension refuses to take - but the native binary is
 * already there, shipped beside this file, so the right answer is to ask it.
 * `tasklist` was the wrong source: its output is localized (the "N/A"
 * placeholder is "N/D" on an Italian Windows, and parsing a translated table by
 * column position is a latent bug on every non-English machine), it cannot
 * report a process's architecture, and it does not expose the command line -
 * the field that actually distinguishes two instances of one application.
 * `tasklist /V`, which does give window titles, took 82 seconds to enumerate a
 * real workstation; the adapter answers for 563 processes in 66 ms.
 *
 * There is deliberately no fallback to `tasklist`: falling back silently would
 * reintroduce exactly the localization bug this replaced. A failure is
 * reported, and the session is aborted.
 *
 * ------------------------------------------------------------------ filtering
 *
 * Listing every process is the wrong question when the user already knows the
 * executable and only has to say *which instance*. The command takes an
 * optional name filter, from whichever of these arrives:
 *
 *   1. `args.nameFilter` on an `inputs` entry of type `command`:
 *
 *        "processId": "${input:pickMyApp}",
 *        "inputs": [
 *          { "id": "pickMyApp", "type": "command",
 *            "command": "delphi-win64.pickProcess",
 *            "args": { "nameFilter": "SampleApp.exe" } }
 *        ]
 *
 *      VS Code passes an input's `args` value straight through as the command
 *      argument.
 *
 *   2. `processName` on the debug configuration, when the command variable is
 *      used directly:
 *
 *        "processName": "SampleApp.exe",
 *        "processId": "${command:delphi-win64.pickProcess}"
 *
 *      VS Code passes the *enclosing launch configuration object* as the
 *      argument of a `${command:...}` variable, so no `inputs` block is needed.
 *
 *   3. Nothing - every process is listed.
 *
 * With a filter, one match is returned without prompting (there is nothing to
 * choose), and several matches are listed with their window caption and command
 * line: two instances of one application are indistinguishable by name and pid
 * alone, and the caption is what a user can match against a window on screen.
 *
 * Processes that cannot be debugged (a 32-bit target, an unreadable one) are
 * shown with the adapter's own reason rather than hidden, so a user hunting for
 * their application learns why it is not a candidate instead of concluding the
 * picker is broken.
 */

const vscode = require('vscode');
const childProcess = require('child_process');
const path = require('path');
const fs = require('fs');

/* The listing is a snapshot of the process table; it must never hang a start. */
const LISTING_TIMEOUT_MS = 20000;

/*
 * Pseudo-processes that can never be attached to. Everything else stays in the
 * list - hiding a process the user is actually looking for is worse than
 * showing one that will fail.
 */
const NOT_ATTACHABLE = ['[system process]', 'system idle process', 'system', 'secure system',
  'registry', 'memory compression'];

/* Ordinary Windows infrastructure: shown, but pushed below real applications. */
const SYSTEM_NOISE = [
  'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'lsass.exe', 'smss.exe',
  'svchost.exe', 'dwm.exe', 'fontdrvhost.exe', 'conhost.exe', 'runtimebroker.exe',
  'sihost.exe', 'taskhostw.exe', 'ctfmon.exe', 'spoolsv.exe', 'searchindexer.exe',
  'wmiprvse.exe', 'dllhost.exe', 'audiodg.exe', 'explorer.exe', 'shellexperiencehost.exe',
  'startmenuexperiencehost.exe', 'textinputhost.exe', 'searchhost.exe', 'msmpeng.exe'
];

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function baseName(name) {
  return text(name).toLowerCase().replace(/\.exe$/, '');
}

/**
 * The adapter executable, taken from this extension's own manifest.
 *
 * `contributes.debuggers[0].program` is the single place the adapter's location
 * is declared, and scripts/install-dev.ps1 rewrites it to point at the build output, so
 * reading it keeps the picker and the debug sessions on the same binary in both
 * a released install and a development one.
 */
function adapterExecutablePath(extensionDir) {
  const directory = extensionDir || __dirname;
  const manifestPath = path.join(directory, 'package.json');

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error('cannot read the extension manifest ' + manifestPath + ': ' +
      ((error && error.message) || error));
  }

  const debuggers = (manifest.contributes || {}).debuggers || [];
  const program = debuggers.length > 0 ? text(debuggers[0].program) : '';
  if (program === '') throw new Error('the extension manifest declares no debug adapter program');

  const resolved = path.isAbsolute(program) ? program : path.resolve(directory, program);
  if (!fs.existsSync(resolved)) {
    throw new Error('the debug adapter was not found at ' + resolved +
      ' (build it with scripts/build_dap.bat, or reinstall the extension)');
  }
  return resolved;
}

function normalizeProcess(entry) {
  const pid = Number(entry.pid);
  if (!isFinite(pid) || pid <= 0) return undefined;
  return {
    pid: pid,
    parentPid: isFinite(Number(entry.parentPid)) ? Number(entry.parentPid) : 0,
    sessionId: isFinite(Number(entry.sessionId)) ? Number(entry.sessionId) : 0,
    name: text(entry.name),
    path: text(entry.path),
    commandLine: text(entry.commandLine),
    windowTitle: text(entry.windowTitle),
    startTime: text(entry.startTime),
    arch: text(entry.arch) || 'unknown',
    canDebug: entry.canDebug === true,
    reason: text(entry.reason)
  };
}

/**
 * Reads the adapter's answer.
 *
 * The adapter writes exactly one line of JSON, but the parser looks for it
 * rather than assuming it is the whole of stdout: should anything else ever
 * reach that stream, a picker that silently misparsed it would be worse than
 * one that says so.
 */
function parseProcessListJson(stdout) {
  const line = String(stdout || '').split(/\r?\n/)
    .map((candidate) => candidate.trim())
    .find((candidate) => candidate.startsWith('[') && candidate.endsWith(']'));
  if (line === undefined) {
    throw new Error('the debug adapter did not return a process list' +
      (String(stdout || '').trim() === '' ? ' (no output)' : ': ' + String(stdout).trim().slice(0, 200)));
  }

  let parsed;
  try {
    parsed = JSON.parse(line);
  } catch (error) {
    throw new Error('the process list from the debug adapter is not valid JSON: ' +
      ((error && error.message) || error));
  }
  if (!Array.isArray(parsed)) throw new Error('the process list from the debug adapter is not an array');

  return parsed
    .filter((entry) => entry && typeof entry === 'object')
    .map(normalizeProcess)
    .filter((entry) => entry !== undefined);
}

/**
 * Runs the adapter in its one-shot listing mode.
 *
 * The name filter is passed on as its own argv entry: the adapter matches it
 * with or without the `.exe` suffix, and there is no shell in the way, so a
 * name needs no quoting and can carry no injection.
 */
function listProcesses(nameFilter, options) {
  const settings = options || {};
  const executable = adapterExecutablePath(settings.extensionDir);
  const args = ['--list-processes'];
  if (nameFilter !== '') args.push(nameFilter);

  return new Promise((resolve, reject) => {
    childProcess.execFile(executable, args,
      { windowsHide: true, maxBuffer: 16 * 1024 * 1024, timeout: LISTING_TIMEOUT_MS },
      (error, stdout) => {
        if (error && !String(stdout || '').trim()) {
          reject(new Error('the debug adapter failed to list processes (' + executable + '): ' +
            ((error && error.message) || error)));
          return;
        }
        try {
          resolve(parseProcessListJson(stdout));
        } catch (parseError) {
          reject(parseError);
        }
      });
  });
}

/**
 * Most plausible debug target first.
 *
 * A process the adapter can actually attach to outranks one it cannot, and the
 * strongest remaining signal is the workspace itself: a project named SampleApp
 * most likely wants SampleApp.exe. Ordinary Windows infrastructure is pushed down.
 * Ties break by name and pid so the list never reshuffles between invocations.
 */
function rankProcesses(processes, options) {
  const settings = options || {};
  const hints = (settings.hints || []).map(baseName).filter((hint) => hint !== '');
  const ownPid = settings.ownPid;

  function score(entry) {
    const lowerName = text(entry.name).toLowerCase();
    const stem = baseName(entry.name);
    let value = 0;
    hints.forEach((hint) => {
      if (stem === hint) value += 1000;
      else if (stem.indexOf(hint) !== -1 || hint.indexOf(stem) !== -1) value += 400;
    });
    if (entry.canDebug) value += 200;
    if (SYSTEM_NOISE.indexOf(lowerName) !== -1) value -= 300;
    return value;
  }

  return processes
    .filter((entry) => entry.pid > 4 && entry.pid !== ownPid &&
      NOT_ATTACHABLE.indexOf(text(entry.name).toLowerCase()) === -1)
    .map((entry) => Object.assign({}, entry, { score: score(entry) }))
    .sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      const byName = String(a.name).localeCompare(String(b.name));
      if (byName !== 0) return byName;
      return a.pid - b.pid;
    });
}

/**
 * The instances of one executable, attachable ones first and then by pid.
 *
 * The name matches case-insensitively and with or without the `.exe` suffix on
 * either side, so "SampleApp", "SampleApp.exe" and "SampleApp.EXE" all select the same
 * process. The adapter applies the same rule to its own filter; this one is
 * what makes the result true regardless of how the list was obtained.
 */
function filterByName(processes, nameFilter) {
  const wanted = baseName(nameFilter);
  if (wanted === '') return processes.slice();
  return processes
    .filter((entry) => baseName(entry.name) === wanted)
    .sort((a, b) => {
      if (a.canDebug !== b.canDebug) return a.canDebug ? -1 : 1;
      return a.pid - b.pid;
    });
}

/**
 * The name filter carried by the command argument, or '' for "list everything".
 *
 * Both shapes VS Code can deliver are accepted, plus a bare string for the
 * `"args": "SampleApp.exe"` spelling that an input entry invites.
 */
function resolveNameFilter(commandArgument) {
  if (typeof commandArgument === 'string') return commandArgument.trim();
  if (!commandArgument || typeof commandArgument !== 'object') return '';
  const candidates = [
    commandArgument.nameFilter,
    commandArgument.args && commandArgument.args.nameFilter,
    commandArgument.processName
  ];
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim() !== '') return candidate.trim();
  }
  return '';
}

/**
 * Quick-pick items.
 *
 * The window caption leads the detail line when the process has one: with two
 * instances of one application the name, the pid, the image path and often the
 * command line are all identical, and the caption is what the user can actually
 * match against a window on screen ("the one showing the Customers project").
 * The command line follows it, since a headless or freshly started instance has
 * no caption to show. A process that cannot be debugged says so first, in the
 * adapter's own words.
 */
function toQuickPickItems(processes) {
  return processes.map((entry) => {
    const parts = [];
    if (!entry.canDebug) parts.push('cannot attach - ' + (entry.reason || 'unsupported process'));
    if (entry.windowTitle) parts.push('$(window) ' + entry.windowTitle);
    const invocation = entry.commandLine || entry.path;
    if (invocation) parts.push(invocation);

    const description = ['PID ' + entry.pid];
    if (entry.arch && entry.arch !== 'unknown') description.push(entry.arch);
    // Two instances of one application can also share their window caption -
    // SampleApp names both of its windows after the connected database. Then the
    // only thing left that a user knows is which one they started first.
    if (entry.startTime) description.push('started ' + entry.startTime.replace('T', ' '));
    if (isFinite(entry.sessionId)) description.push('session ' + entry.sessionId);

    return {
      label: (entry.canDebug ? '' : '$(circle-slash) ') + entry.name,
      description: description.join('  ·  '),
      detail: parts.join('  ·  '),
      pid: entry.pid,
      canDebug: entry.canDebug,
      reason: entry.reason
    };
  });
}

function workspaceHints() {
  const hints = [];
  for (const folder of vscode.workspace.workspaceFolders || []) {
    if (folder && folder.name) hints.push(folder.name);
  }
  return hints;
}

/** Refuses a target the adapter has already said it cannot debug, with its reason. */
function refuseUndebuggable(entry) {
  vscode.window.showErrorMessage(entry.name + ' (PID ' + entry.pid + ') cannot be debugged: ' +
    (entry.reason || 'unsupported process') + '.');
  return undefined;
}

async function promptFor(processes, placeHolder) {
  const picked = await vscode.window.showQuickPick(toQuickPickItems(processes), {
    placeHolder: placeHolder,
    matchOnDescription: true,
    matchOnDetail: true
  });
  if (!picked) return undefined;
  if (!picked.canDebug) return refuseUndebuggable(picked);
  return String(picked.pid);
}

/**
 * The command body. Returns the pid as a string (what a `processId` string
 * property expects) or `undefined` when the user cancels: VS Code treats an
 * unresolved command variable as a cancelled session start, which is the only
 * safe outcome here - returning 0 or a stale pid would attach to the wrong
 * process or fail with a confusing error.
 *
 * `commandArgument` is whatever VS Code passed; see resolveNameFilter.
 */
async function pickProcess(commandArgument, options) {
  const nameFilter = resolveNameFilter(commandArgument);

  let listed;
  try {
    listed = await listProcesses(nameFilter, options);
  } catch (error) {
    vscode.window.showErrorMessage('Could not list running processes: ' + ((error && error.message) || error));
    return undefined;
  }

  const processes = rankProcesses(listed, {
    hints: workspaceHints(),
    ownPid: process.pid
  });

  if (nameFilter === '') {
    if (processes.length === 0) {
      vscode.window.showErrorMessage('No running processes were reported by the debug adapter.');
      return undefined;
    }
    return promptFor(processes, 'Select the process to attach to (type to filter by name, PID or command line)');
  }

  const matches = filterByName(processes, nameFilter);
  if (matches.length === 0) {
    vscode.window.showErrorMessage('No running process is named "' + nameFilter +
      '". Start the application first, or remove the process name from the attach configuration to choose from every running process.');
    return undefined;
  }
  if (matches.length === 1) {
    if (!matches[0].canDebug) return refuseUndebuggable(matches[0]);
    return String(matches[0].pid);
  }

  return promptFor(matches, 'Select which ' + matches[0].name + ' to attach to (' + matches.length + ' running)');
}

module.exports = {
  pickProcess: pickProcess,
  adapterExecutablePath: adapterExecutablePath,
  parseProcessListJson: parseProcessListJson,
  listProcesses: listProcesses,
  rankProcesses: rankProcesses,
  filterByName: filterByName,
  resolveNameFilter: resolveNameFilter,
  toQuickPickItems: toQuickPickItems
};
