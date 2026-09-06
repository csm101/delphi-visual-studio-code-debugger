'use strict';

/*
 * Project-scoped exception-rule files.
 *
 * A launch/attach configuration may name the Delphi project it debugs, through
 * `delphiProjectFile` (the `.dpr`, `.dpk` or `.dproj` the RAD Studio plugin
 * writes automatically). When it does, the adapter reads two rule files sitting
 * next to that project, AHEAD of the configuration's own `exceptionRules` and
 * ahead of the machine-wide file:
 *
 *   <dir>\<Project>.ExceptionSettings.json         shared - committed with the project
 *   <dir>\<Project>.ExceptionSettings.local.json   personal - gitignored
 *
 * This module is what lets the rules editor offer those two files as edit
 * targets. It only has to agree with `ExceptionRules.pas` about where they live
 * and with `globalRules.js` about what is inside them - the file shape, the
 * shape-preserving write and the create-on-demand path are all reused from
 * there, because these files ARE the same kind of file.
 *
 * No `vscode` dependency: plain Node, so install/extension-tests can exercise
 * it directly.
 */

const fs = require('fs');
const path = require('path');
const globalRules = require('./globalRules');

const PROJECT_RULES_SUFFIX = '.ExceptionSettings.json';
const LOCAL_PROJECT_RULES_SUFFIX = '.ExceptionSettings.local.json';

/** `C:\proj\Debugme.dproj` -> `C:\proj\Debugme`. Only the LAST dot is an extension. */
function withoutExtension(projectFile) {
  const text = String(projectFile || '').trim();
  if (text === '') return '';
  const extension = path.extname(text);
  return extension ? text.slice(0, text.length - extension.length) : text;
}

function projectRulesPath(projectFile) {
  const base = withoutExtension(projectFile);
  return base === '' ? '' : base + PROJECT_RULES_SUFFIX;
}

function localProjectRulesPath(projectFile) {
  const base = withoutExtension(projectFile);
  return base === '' ? '' : base + LOCAL_PROJECT_RULES_SUFFIX;
}

/** `C:\proj\My.Company.Widgets.dpk` -> `My.Company.Widgets`. */
function projectBaseName(projectFile) {
  return path.basename(withoutExtension(projectFile));
}

/**
 * How a project's rule files are named in the picker. The project is named the
 * way the developer knows it -- `Debugme.dproj`, not `Debugme` -- because that is
 * the file they opened in the IDE, and the whole point of the entry is that the
 * rules belong to THAT project rather than to whatever launch configuration
 * happens to start it.
 */
function projectTargetName(projectFile, kind) {
  return path.basename(projectFile) + ' rules (' + (kind === 'projectLocal' ? 'local' : 'shared') + ')';
}

/**
 * The absolute project path a configuration points at, or '' when it names
 * none - or names one through a variable nothing here can expand. Unlike the
 * adapter, which is handed a path VS Code has already substituted, the editor
 * reads launch.json as text and has to do the substitution itself.
 */
function resolveProjectFile(configuration, options) {
  const settings = options || {};
  const declared = configuration && configuration.delphiProjectFile;
  if (typeof declared !== 'string' || declared.trim() === '') return '';
  const workspaceFolder = configuration.workspaceFolder || settings.workspaceFolder || '';
  const expanded = globalRules.expandVariables(declared, {
    workspaceFolder: workspaceFolder,
    workspaceFolderBasename: configuration.workspaceFolderBasename || settings.workspaceFolderBasename,
    userHome: settings.homeDirectory
  });
  // A path that still carries a variable is not a path. Leaving it out is the
  // only honest answer: deriving sidecar names from the literal `${...}` would
  // offer to create rule files in a folder that does not exist.
  if (expanded.indexOf('${') >= 0 || expanded.indexOf('$(') >= 0) return '';
  return path.normalize(workspaceFolder ? path.resolve(workspaceFolder, expanded) : path.resolve(expanded));
}

/**
 * The project-scoped edit targets for a set of launch configurations, most
 * specific first (local, then shared) and one pair per DISTINCT project - a
 * project's launch and attach configurations name the same project and must not
 * produce the same entry twice.
 *
 * A configuration whose project directory does not exist is skipped: it is a
 * stale path, and offering it would only invite creating rule files in a folder
 * conjured for the occasion.
 */
function collectProjectTargets(configurations, options) {
  const settings = options || {};
  const exists = settings.directoryExists || ((directory) => fs.existsSync(directory));
  const readFile = settings.readRulesFile || globalRules.readGlobalRulesFile;
  const byProject = new Map();

  for (const configuration of configurations || []) {
    const projectFile = resolveProjectFile(configuration, settings);
    if (projectFile === '') continue;
    if (!exists(path.dirname(projectFile))) continue;
    const key = projectFile.toLowerCase();
    if (!byProject.has(key)) byProject.set(key, { projectFile: projectFile, declaredBy: [] });
    byProject.get(key).declaredBy.push(configuration.name);
  }

  const targets = [];
  for (const entry of byProject.values()) {
    const tiers = [
      { kind: 'projectLocal',  filePath: localProjectRulesPath(entry.projectFile) },
      { kind: 'projectShared', filePath: projectRulesPath(entry.projectFile) }
    ];
    for (const tier of tiers) {
      const file = readFile(tier.filePath);
      targets.push({
        kind: tier.kind,
        filePath: tier.filePath,
        documentLabel: tier.filePath,
        name: projectTargetName(entry.projectFile, tier.kind),
        projectFile: entry.projectFile,
        declaredBy: entry.declaredBy.slice(),
        exceptionRules: file.rules,
        exists: file.exists,
        shape: file.shape,
        parseError: file.error
      });
    }
  }
  return targets;
}

module.exports = {
  PROJECT_RULES_SUFFIX: PROJECT_RULES_SUFFIX,
  LOCAL_PROJECT_RULES_SUFFIX: LOCAL_PROJECT_RULES_SUFFIX,
  withoutExtension: withoutExtension,
  projectRulesPath: projectRulesPath,
  localProjectRulesPath: localProjectRulesPath,
  projectBaseName: projectBaseName,
  projectTargetName: projectTargetName,
  resolveProjectFile: resolveProjectFile,
  collectProjectTargets: collectProjectTargets
};
