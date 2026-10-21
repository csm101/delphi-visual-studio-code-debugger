// Tells the user when a newer release exists on GitHub.
//
// Why this is here at all: besides the VS Code Marketplace, the extension is
// distributed by an installer (the setup zip) -- because that reaches Cursor,
// Windsurf, VSCodium and Trae, which the Microsoft marketplace does not. A
// .vsix installed that way is pinned by the editor and never updated by it, so
// nothing else tells someone running an old build that a new one exists. A
// Marketplace install is the opposite case: the editor updates it, and the
// check must stay silent there (see installSourceFrom).
//
// The whole design is shaped by one rule: an update check must never become a
// nuisance. It fails silently, it asks at most once a day, and it can be turned
// off. A check that nags when GitHub is unreachable is worse than no check.

const fs = require('fs');
const https = require('https');
const path = require('path');

const DEFAULT_INTERVAL_MS = 24 * 60 * 60 * 1000;   // once a day
const REQUEST_TIMEOUT_MS = 5000;

// Compares dotted numeric versions. Returns >0 when a is newer, <0 when b is,
// 0 when equal. String comparison is NOT good enough: '0.10.0' < '0.9.0'
// lexically, which would hide every release after the ninth.
function compareVersions(a, b) {
  const parse = (v) => String(v || '')
    .trim()
    .replace(/^v/i, '')
    // Drop any pre-release / build suffix: 1.2.3-beta.1 compares as 1.2.3.
    .split(/[-+]/)[0]
    .split('.')
    .map((part) => parseInt(part, 10))
    .map((n) => (Number.isFinite(n) ? n : 0));

  const left = parse(a);
  const right = parse(b);
  const len = Math.max(left.length, right.length);
  for (let i = 0; i < len; i++) {
    const l = left[i] === undefined ? 0 : left[i];
    const r = right[i] === undefined ? 0 : right[i];
    if (l !== r) return l < r ? -1 : 1;
  }
  return 0;
}

// Is it time to ask GitHub again? `lastCheck` is whatever was persisted, which
// may be undefined (never checked) or junk (state written by an older build).
function shouldCheck(lastCheck, now, intervalMs) {
  const interval = intervalMs === undefined ? DEFAULT_INTERVAL_MS : intervalMs;
  const previous = Number(lastCheck);
  if (!Number.isFinite(previous) || previous <= 0) return true;
  // A clock that moved backwards (timezone change, NTP correction) must not
  // park the next check a day in the future.
  if (previous > now) return true;
  return (now - previous) >= interval;
}

// Fetches the latest release. Resolves with {version, url} or null -- never
// rejects, because every failure mode here is one the user must not see: no
// network, a proxy, GitHub rate-limiting an unauthenticated call, a repository
// that is private, or a body that is not the JSON we expected.
function fetchLatestRelease(repoUrl, httpGet) {
  const get = httpGet || https.get;
  const match = /github\.com[/:]([^/]+)\/([^/.]+)/i.exec(String(repoUrl || ''));
  if (!match) return Promise.resolve(null);
  const api = 'https://api.github.com/repos/' + match[1] + '/' + match[2] + '/releases/latest';

  return new Promise((resolve) => {
    let settled = false;
    const done = (value) => { if (!settled) { settled = true; resolve(value); } };
    try {
      const req = get(api, {
        // GitHub rejects unauthenticated calls without a User-Agent.
        headers: { 'User-Agent': 'delphi-win64-debug-extension', 'Accept': 'application/vnd.github+json' },
        timeout: REQUEST_TIMEOUT_MS
      }, (res) => {
        if (res.statusCode !== 200) { res.resume(); done(null); return; }
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { body += chunk; });
        res.on('end', () => {
          try {
            const json = JSON.parse(body);
            if (!json || !json.tag_name) { done(null); return; }
            done({ version: String(json.tag_name), url: String(json.html_url || '') });
          } catch (e) { done(null); }
        });
        res.on('error', () => done(null));
      });
      req.on('error', () => done(null));
      req.on('timeout', () => { req.destroy(); done(null); });
    } catch (e) {
      done(null);
    }
  });
}

// Where the editor says this copy came from: 'gallery' for a Marketplace
// install, which the editor keeps updated itself; 'vsix' for Setup.exe or a
// .vsix installed by hand, which the editor pins and never updates; undefined
// when it cannot be told. The answer is the `metadata.source` of this copy's
// entry in the extensions.json the editor keeps beside the extension folders
// (VS Code and its family alike). The entry is found by folder name, which
// names exactly this copy, and failing that by id and version.
function installSourceFrom(extensionsJsonText, folderName, id, version) {
  let entries;
  try { entries = JSON.parse(extensionsJsonText); } catch (e) { return undefined; }
  if (!Array.isArray(entries)) return undefined;

  const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
  const isThisFolder = (e) => same(e.relativeLocation, folderName);
  const isThisVersion = (e) => e.identifier && same(e.identifier.id, id) && e.version === version;
  const entry = entries.find((e) => e && isThisFolder(e)) || entries.find((e) => e && isThisVersion(e));
  if (!entry || !entry.metadata || typeof entry.metadata.source !== 'string') return undefined;
  return entry.metadata.source;
}

// installSourceFrom, reading the file. Never throws: an editor that keeps no
// such file, or a copy run from a development folder, is simply "unknown".
function readInstallSource(extensionPath, id, version, readFile) {
  if (typeof extensionPath !== 'string' || extensionPath === '') return undefined;
  const read = readFile || ((file) => fs.readFileSync(file, 'utf8'));
  try {
    const text = read(path.join(path.dirname(extensionPath), 'extensions.json'));
    return installSourceFrom(text, path.basename(extensionPath), id, version);
  } catch (e) {
    return undefined;
  }
}

module.exports = {
  DEFAULT_INTERVAL_MS: DEFAULT_INTERVAL_MS,
  compareVersions: compareVersions,
  shouldCheck: shouldCheck,
  fetchLatestRelease: fetchLatestRelease,
  installSourceFrom: installSourceFrom,
  readInstallSource: readInstallSource
};
