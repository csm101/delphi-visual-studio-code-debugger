'use strict';

/*
 * delphi-devkit (DDK) as the source of a debug configuration.
 *
 * DDK describes a project's DEBUG TARGET in a debugger-agnostic shape: the
 * executable to launch (the program, or the Host Application of a package or
 * DLL), its .map/.rsm, the project's own .bpl/.dll with their symbol files, the
 * source root and the search paths (dproj + IDE library and browsing paths),
 * the run arguments, and warnings about missing or stale artefacts. A debug
 * configuration that names a project -
 *
 *     { "type": "delphi", "request": "launch", "ddkProject": "MyApp" }
 *
 * - is what DDK's own Debug / Attach gestures start, and what a hand-written
 * launch.json entry can say instead of a couple of hundred paths. This module
 * turns that into the attributes the adapter understands.
 *
 * Three ways to obtain the target, tried in this order:
 *   1. the DDK extension's `ddk.debug.getDebugTarget` command, when the
 *      extension is installed (activated on demand);
 *   2. `ddk.exe debug-target <ref> --json` - the CLI, located through the
 *      DDK_EXE environment variable, then PATH, then the packaged extension's
 *      bundled copy;
 *   3. otherwise a clear error naming what to install.
 *
 * The mapping itself (`configurationFromDebugTarget`) is a pure function so
 * the tests in install/extension-tests can drive it with a fixture: a value the
 * user wrote explicitly in the configuration is NEVER overwritten by DDK's.
 */

const path = require('path');

const DDK_EXTENSION_ID = 'Snowcaloid.delphi-devkit';
const DDK_COMMAND = 'ddk.debug.getDebugTarget';
const DDK_EXE = 'ddk.exe';

const NOT_INSTALLED_MESSAGE =
  'This configuration names a delphi-devkit (DDK) project, but DDK was not found: ' +
  'install the "Delphi DevKit" extension (' + DDK_EXTENSION_ID + '), or put ddk.exe on PATH, ' +
  'or point the DDK_EXE environment variable at it.';

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

/** A configuration whose target is to be asked from DDK. */
function needsDebugTarget(config) {
  if (!config || typeof config !== 'object') return false;
  if (config.ddkProject !== undefined && config.ddkProject !== null && String(config.ddkProject).trim() !== '') {
    return true;
  }
  return isNonEmptyString(config.delphiProjectFile) && !isNonEmptyString(config.program);
}

/**
 * What to ask DDK for. `ddkProject` (an id, a name or a project-file path) takes
 * precedence; `delphiProjectFile` is passed as the path reference otherwise.
 * `ddkCompiler` picks the compiler for a path DDK does not manage.
 */
function targetReference(config) {
  const project = (config.ddkProject !== undefined && config.ddkProject !== null &&
                   String(config.ddkProject).trim() !== '')
    ? String(config.ddkProject).trim()
    : String(config.delphiProjectFile).trim();
  const reference = { project: project };
  if (isNonEmptyString(config.ddkCompiler)) reference.compiler = config.ddkCompiler.trim();
  return reference;
}

function warningsOf(target) {
  if (!target || !Array.isArray(target.warnings)) return [];
  return target.warnings.filter(isNonEmptyString);
}

function baseName(filePath) {
  return String(filePath).split(/[\\/]/).pop();
}

/**
 * The modules DDK found on disk, in the adapter's `modules` shape. A module
 * without a binary is dropped: there is nothing to bind symbols to, and DDK
 * already reports it as a warning.
 */
function modulesFromTarget(target) {
  const modules = Array.isArray(target.modules) ? target.modules : [];
  return modules
    .filter((module) => module && isNonEmptyString(module.binary))
    .map((module) => {
      const entry = { name: isNonEmptyString(module.name) ? module.name : baseName(module.binary) };
      ['map', 'rsm', 'dcp'].forEach((key) => {
        if (isNonEmptyString(module[key])) entry[key] = module[key];
      });
      return entry;
    });
}

/**
 * Maps a DDK debug target onto the adapter's launch/attach attributes.
 *
 * Pure: returns a new configuration and touches nothing else. Every attribute
 * the user wrote in `config` wins over DDK's value, whatever it is - a user who
 * pinned `program` to a different build, or `args` to a test flag, meant it.
 * Throws when the target cannot be debugged at all (no executable, or a
 * platform this debugger does not run: DDK reports `bitness: null` for those).
 */
function configurationFromDebugTarget(config, target) {
  if (!target || typeof target !== 'object') {
    throw new Error('DDK returned no debug target.');
  }
  const warnings = warningsOf(target);
  if (target.bitness !== 32 && target.bitness !== 64) {
    throw new Error(warnings.length > 0
      ? warnings.join(' ')
      : 'DDK reports no Windows bitness for this project (platform "' + target.platform + '"); ' +
        'this debugger runs Win32 and Win64 targets only.');
  }
  if (!isNonEmptyString(target.executable)) {
    throw new Error('DDK describes no executable for project "' + target.project + '".' +
      (warnings.length > 0 ? ' ' + warnings.join(' ') : ''));
  }

  const result = Object.assign({}, config);
  const setUnlessWritten = (key, value) => {
    if (config[key] !== undefined) return;
    if (value === undefined || value === null || value === '') return;
    if (Array.isArray(value) && value.length === 0) return;
    result[key] = value;
  };

  const symbols = target.symbols && typeof target.symbols === 'object' ? target.symbols : {};
  setUnlessWritten('program', target.executable);
  setUnlessWritten('mapFile', symbols.map);
  setUnlessWritten('rsmFile', symbols.rsm);
  setUnlessWritten('sourceRoot', target.source_root);
  setUnlessWritten('sourceSearchPaths',
    Array.isArray(target.source_search_paths) ? target.source_search_paths.filter(isNonEmptyString) : undefined);
  setUnlessWritten('modules', modulesFromTarget(target));
  setUnlessWritten('args', Array.isArray(target.args) ? target.args.slice() : undefined);
  setUnlessWritten('delphiProjectFile', target.project_file);
  if (config.request === 'attach') {
    // The existing single-instance / picker semantics then apply: one running
    // instance attaches straight away, several go through the process picker
    // filtered to this name.
    setUnlessWritten('processName', baseName(target.executable));
  }
  return result;
}

// ----------------------------------------------------------- locating ddk --

/**
 * Where `ddk.exe` is: DDK_EXE, then PATH, then the packaged DDK extension's
 * bundled copy (newest version when several are installed). Undefined when
 * none. Everything filesystem-related comes in through `deps` so the tests
 * can run it against a made-up disk.
 */
function locateDdkExe(deps) {
  const d = deps || {};
  const env = d.env || process.env;
  const exists = d.exists || ((p) => { try { return require('fs').statSync(p).isFile(); } catch (e) { return false; } });
  const listDir = d.listDir || ((p) => { try { return require('fs').readdirSync(p); } catch (e) { return []; } });

  if (isNonEmptyString(env.DDK_EXE) && exists(env.DDK_EXE)) return env.DDK_EXE;

  const pathEntries = String(env.PATH || env.Path || '').split(';').filter((entry) => entry.trim() !== '');
  for (const dir of pathEntries) {
    const candidate = path.join(dir.trim(), DDK_EXE);
    if (exists(candidate)) return candidate;
  }

  const home = env.USERPROFILE || env.HOME;
  if (isNonEmptyString(home)) {
    const extensionsDir = path.join(home, '.vscode', 'extensions');
    const installed = listDir(extensionsDir)
      .filter((name) => /^snowcaloid\.delphi-devkit-/i.test(name))
      .sort(compareVersionSuffix)
      .reverse();
    for (const folder of installed) {
      const candidate = path.join(extensionsDir, folder, 'server', DDK_EXE);
      if (exists(candidate)) return candidate;
    }
  }
  return undefined;
}

function compareVersionSuffix(a, b) {
  const va = versionOf(a);
  const vb = versionOf(b);
  for (let i = 0; i < 3; i++) {
    if (va[i] !== vb[i]) return va[i] - vb[i];
  }
  return a < b ? -1 : a > b ? 1 : 0;
}

function versionOf(folderName) {
  const match = /-(\d+)\.(\d+)\.(\d+)/.exec(folderName);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : [0, 0, 0];
}

/** The argv for `ddk.exe`: `debug-target <ref> --json`, plus the compiler. */
function ddkArguments(reference) {
  const args = ['debug-target', reference.project, '--json'];
  if (isNonEmptyString(reference.compiler)) args.push('--compiler', reference.compiler);
  return args;
}

/**
 * Runs `ddk.exe debug-target ... --json` and parses the reply. A non-zero exit
 * comes back as an error carrying ddk's own text (an ambiguous reference lists
 * the candidates, an unknown project says so) rather than a generic failure.
 */
function fetchTargetFromCli(exe, reference, execFile) {
  const run = execFile || require('child_process').execFile;
  return new Promise((resolve, reject) => {
    run(exe, ddkArguments(reference), { maxBuffer: 64 * 1024 * 1024, windowsHide: true },
      (error, stdout, stderr) => {
        const out = String(stdout || '');
        const err = String(stderr || '').trim();
        if (error) {
          reject(new Error(err || out.trim() || (error.message || String(error))));
          return;
        }
        try {
          resolve(JSON.parse(out));
        } catch (parseError) {
          reject(new Error('ddk.exe returned something that is not a debug target: ' +
            (err || out.slice(0, 200))));
        }
      });
  });
}

/**
 * Obtains the debug target: the DDK extension's command when the extension is
 * installed, `ddk.exe` otherwise. `deps.vscode` is the API (stubbed in tests).
 */
async function fetchDebugTarget(reference, deps) {
  const d = deps || {};
  const vs = d.vscode;
  const extension = vs && vs.extensions && vs.extensions.getExtension
    ? vs.extensions.getExtension(DDK_EXTENSION_ID)
    : undefined;
  if (extension) {
    if (!extension.isActive && typeof extension.activate === 'function') await extension.activate();
    return vs.commands.executeCommand(DDK_COMMAND, reference);
  }
  const exe = (d.locate || locateDdkExe)(d);
  if (!exe) throw new Error(NOT_INSTALLED_MESSAGE);
  return fetchTargetFromCli(exe, reference, d.execFile);
}

/**
 * The whole step: a configuration that names a DDK project comes back filled
 * in; any other configuration comes back untouched (the same object). DDK's
 * warnings are reported through `deps.showWarning`, one each, non-blocking.
 */
async function resolveDdkConfiguration(config, deps) {
  if (!needsDebugTarget(config)) return config;
  const target = await fetchDebugTarget(targetReference(config), deps);
  const resolved = configurationFromDebugTarget(config, target);
  const show = deps && deps.showWarning;
  if (typeof show === 'function') warningsOf(target).forEach((warning) => show(warning));
  return resolved;
}

module.exports = {
  DDK_EXTENSION_ID: DDK_EXTENSION_ID,
  DDK_COMMAND: DDK_COMMAND,
  NOT_INSTALLED_MESSAGE: NOT_INSTALLED_MESSAGE,
  needsDebugTarget: needsDebugTarget,
  targetReference: targetReference,
  configurationFromDebugTarget: configurationFromDebugTarget,
  modulesFromTarget: modulesFromTarget,
  warningsOf: warningsOf,
  locateDdkExe: locateDdkExe,
  ddkArguments: ddkArguments,
  fetchTargetFromCli: fetchTargetFromCli,
  fetchDebugTarget: fetchDebugTarget,
  resolveDdkConfiguration: resolveDdkConfiguration
};
