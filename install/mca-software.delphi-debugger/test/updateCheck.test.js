// The update check, exercised without a network.
//
//   node test/updateCheck.test.js      (from the extension folder)
//
// Two things are worth testing here and they are not the HTTP call: comparing
// versions (where a string comparison hides every release after the ninth) and
// deciding when to ask again. The notification flow is covered with a fake
// `vscode` and a fake fetch, because the behaviour that matters is what it does
// when GitHub says nothing useful -- which must be: nothing at all.

const path = require('path');
const Module = require('module');

const stubPath = require.resolve('./vscode-stub.js');
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'vscode') return stubPath;
  return origResolve.call(this, request, ...rest);
};

const updates = require(path.join(__dirname, '..', 'updateCheck.js'));
const ext = require(path.join(__dirname, '..', 'extension.js'));

let failures = 0;

function ok(cond, what) {
  if (cond) console.log('ok    ' + what);
  else { failures++; console.log('FAIL  ' + what); }
}

// --- compareVersions ---------------------------------------------------------
const cmp = updates.compareVersions;
ok(cmp('0.2.4', '0.2.3') > 0, '0.2.4 is newer than 0.2.3');
ok(cmp('0.2.3', '0.2.4') < 0, '0.2.3 is older than 0.2.4');
ok(cmp('0.2.3', '0.2.3') === 0, 'equal versions compare equal');
// The case a string comparison gets wrong, which is the whole reason this
// function exists rather than `a > b`.
ok(cmp('0.10.0', '0.9.0') > 0, '0.10.0 is newer than 0.9.0 (not a string compare)');
ok(cmp('1.0.0', '0.99.99') > 0, 'a major bump beats any minor');
ok(cmp('v1.2.0', '1.2.0') === 0, 'a leading v is ignored');
ok(cmp('1.2.0-beta.1', '1.2.0') === 0, 'a pre-release suffix is ignored');
ok(cmp('1.2', '1.2.0') === 0, 'a missing patch counts as zero');
ok(cmp('nonsense', '0.0.1') < 0, 'an unparsable version loses rather than throwing');

// --- shouldCheck -------------------------------------------------------------
const DAY = updates.DEFAULT_INTERVAL_MS;
const now = 1000 * DAY;
ok(updates.shouldCheck(undefined, now) === true, 'never checked -> check');
ok(updates.shouldCheck('rubbish', now) === true, 'junk state -> check');
ok(updates.shouldCheck(now - DAY, now) === true, 'a full day later -> check');
ok(updates.shouldCheck(now - (DAY / 2), now) === false, 'half a day later -> do not check');
// A clock that moved backwards must not park the next check in the future.
ok(updates.shouldCheck(now + DAY, now) === true, 'a future timestamp -> check anyway');

// --- the notification flow ---------------------------------------------------
function makeContext(version, state) {
  const store = state || {};
  return {
    extension: { packageJSON: {
      version: version,
      repository: { url: 'https://github.com/csm101/delphi-visual-studio-code-debugger.git' }
    } },
    globalState: {
      get: (k, dflt) => (k in store ? store[k] : dflt),
      update: (k, v) => { store[k] = v; return Promise.resolve(); }
    },
    _store: store
  };
}

function makeVscode(settings, shown) {
  return {
    workspace: { getConfiguration: () => ({ get: (k, dflt) => (k in settings ? settings[k] : dflt) }) },
    window: { showInformationMessage: (msg, ...items) => { shown.push(msg); return Promise.resolve(undefined); } },
    env: { openExternal: () => {} },
    Uri: { parse: (s) => s }
  };
}

(async () => {
  // A newer release is announced.
  let shown = [];
  let ctx = makeContext('0.2.3');
  await ext.checkForUpdate(ctx, {
    vscode: makeVscode({}, shown),
    updateCheck: Object.assign({}, updates, {
      fetchLatestRelease: () => Promise.resolve({ version: '0.3.0', url: 'https://example/rel' })
    })
  });
  ok(shown.length === 1 && shown[0].indexOf('0.3.0') >= 0, 'a newer release is announced');

  // The same version installed says nothing.
  shown = [];
  await ext.checkForUpdate(makeContext('0.3.0'), {
    vscode: makeVscode({}, shown),
    updateCheck: Object.assign({}, updates, {
      fetchLatestRelease: () => Promise.resolve({ version: '0.3.0', url: '' })
    })
  });
  ok(shown.length === 0, 'the current version is not announced');

  // GitHub unreachable: silence. This is the case that decides whether the
  // feature is tolerable on a locked-down network.
  shown = [];
  await ext.checkForUpdate(makeContext('0.2.3'), {
    vscode: makeVscode({}, shown),
    updateCheck: Object.assign({}, updates, {
      fetchLatestRelease: () => Promise.resolve(null)
    })
  });
  ok(shown.length === 0, 'a failed fetch says nothing');

  // Turned off in settings: not even a request.
  shown = [];
  let asked = false;
  await ext.checkForUpdate(makeContext('0.2.3'), {
    vscode: makeVscode({ checkForUpdates: false }, shown),
    updateCheck: Object.assign({}, updates, {
      fetchLatestRelease: () => { asked = true; return Promise.resolve({ version: '9.9.9', url: '' }); }
    })
  });
  ok(shown.length === 0 && !asked, 'the setting suppresses the check entirely');

  // A skipped version is not announced again.
  shown = [];
  ctx = makeContext('0.2.3', { 'delphiWin64.updateCheck.skippedVersion': '0.3.0' });
  await ext.checkForUpdate(ctx, {
    vscode: makeVscode({}, shown),
    updateCheck: Object.assign({}, updates, {
      fetchLatestRelease: () => Promise.resolve({ version: '0.3.0', url: '' })
    })
  });
  ok(shown.length === 0, 'a skipped version is not announced again');

  // The timestamp is written even when the fetch fails, so an unreachable
  // GitHub is asked once a day rather than on every activation.
  ctx = makeContext('0.2.3');
  await ext.checkForUpdate(ctx, {
    vscode: makeVscode({}, []),
    updateCheck: Object.assign({}, updates, { fetchLatestRelease: () => Promise.resolve(null) }),
    now: 12345
  });
  ok(ctx._store['delphiWin64.updateCheck.lastCheck'] === 12345,
     'the check timestamp is stamped even on failure');

  console.log(failures === 0 ? '\nall cases pass' : '\n' + failures + ' case(s) FAILED');
  process.exit(failures === 0 ? 0 : 1);
})();
