// The manifest and the code that backs it, checked against each other.
//
//   node test/manifest.test.js      (from the extension folder)
//
// The failure this guards is silent in a way the other tests are not: a button
// contributed in `menus` whose command nobody registers still renders, and
// clicking it produces an error toast rather than nothing -- and neither the
// packaging step nor VS Code's own activation complains. The reverse (a handler
// with no contribution) is invisible instead: the feature simply cannot be
// reached. Both are cheap to catch here and expensive to notice by hand.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const source = fs.readFileSync(path.join(root, 'extension.js'), 'utf8');

let failures = 0;

function ok(cond, what) {
  if (cond) console.log('ok    ' + what);
  else { failures++; console.log('FAIL  ' + what); }
}

const contributes = manifest.contributes || {};
const commands = contributes.commands || [];
const declared = commands.map((c) => c.command);

ok(declared.length > 0, 'the manifest contributes at least one command');

for (const c of commands) {
  ok(typeof c.title === 'string' && c.title.length > 0,
    `${c.command} has a title`);
}

// Every menu entry must point at a declared command, in every menu group.
for (const [menu, entries] of Object.entries(contributes.menus || {})) {
  for (const entry of entries) {
    if (!entry.command) continue;
    ok(declared.includes(entry.command),
      `${menu} entry "${entry.command}" is a declared command`);
  }
}

// Every declared command must have a handler. `registerCommand('id'` is the
// only way this extension binds one, so a plain source search is exact enough
// and does not need the extension loaded.
for (const id of declared) {
  const bound = source.includes(`registerCommand('${id}'`) ||
                source.includes(`registerCommand("${id}"`);
  ok(bound, `${id} is registered in extension.js`);
}

// The raw stack scan is reached from the Call Stack title bar. It is the one
// contribution whose location is the feature: put anywhere else, a user hunting
// for it when a stack came up short would not find it.
const viewTitle = (contributes.menus && contributes.menus['view/title']) || [];
const rawEntry = viewTitle.find((e) => e.command === 'delphi-win64.toggleRawStackScan');
ok(!!rawEntry, 'the raw stack scan toggle is on a view title bar');
if (rawEntry) {
  ok(/workbench\.debug\.callStackView/.test(rawEntry.when || ''),
    'the raw stack scan toggle sits on the Call Stack view');
  // Without the debugType guard the button would appear during every debug
  // session, including other extensions' -- where the custom request 404s.
  ok(/debugType\s*==\s*'delphi-win64'/.test(rawEntry.when || ''),
    'the raw stack scan toggle is limited to delphi-win64 sessions');
}

console.log(failures === 0 ? '\nall manifest checks passed'
                           : `\n${failures} manifest check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
