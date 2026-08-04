// Tells the user when a newer release exists on GitHub.
//
// Why this is here at all: the extension is distributed by an installer rather
// than through a marketplace -- deliberately, because that reaches Cursor,
// Windsurf, VSCodium and Trae, which the Microsoft marketplace does not. The
// cost of that choice is that nothing otherwise tells someone already running
// an old build that a new one exists.
//
// The whole design is shaped by one rule: an update check must never become a
// nuisance. It fails silently, it asks at most once a day, and it can be turned
// off. A check that nags when GitHub is unreachable is worse than no check.

const https = require('https');

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

module.exports = {
  DEFAULT_INTERVAL_MS: DEFAULT_INTERVAL_MS,
  compareVersions: compareVersions,
  shouldCheck: shouldCheck,
  fetchLatestRelease: fetchLatestRelease
};
