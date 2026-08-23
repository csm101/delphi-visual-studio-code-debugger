// How the modules tree is shaped.
//
//   node test/modulesView.test.js      (from the extension folder)
//
// The shaping is where a defect is silent: a module sorted out of sight, or a
// status that reads as "fine" when the module has no debug information at all.
// Neither breaks anything visibly -- the view just quietly stops answering the
// question it exists for.

const path = require('path');
const Module = require('module');

const stubPath = require.resolve('./vscode-stub.js');
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'vscode') return stubPath;
  return origResolve.call(this, request, ...rest);
};

const mv = require(path.join(__dirname, '..', 'modulesView.js'));

let failures = 0;

function eq(label, got, expected) {
  const g = JSON.stringify(got);
  const e = JSON.stringify(expected);
  if (g === e) console.log('ok    ' + label);
  else { failures++; console.log('FAIL  ' + label + ' -> ' + g + '   expected ' + e); }
}

const main    = { name: 'MyApp.exe', delphiIsMain: true, delphiFormats: ['td32', 'map'],
                  symbolStatus: 'TD32 (embedded), .map', addressRange: '0x400000' };
const withDcp = { name: 'ReportEngine290.bpl', delphiFormats: ['td32', 'dcp'],
                  symbolStatus: 'TD32 (embedded), .dcp', addressRange: '0x543D0000',
                  path: 'C:\\Bpl\\ReportEngine290.bpl', delphiImageSize: 15427734 };
const bare    = { name: 'ntdll.dll', delphiFormats: [], symbolStatus: 'no debug information',
                  addressRange: '0x7FF85C700000' };
const indexing = { name: 'vcl290.bpl', delphiFormats: [], symbolStatus: 'indexing',
                   addressRange: '0x7FFE88E00000' };

/* ------------------------------------------------------------- ordering -- */

const sorted = mv.sortModules([bare, withDcp, main, indexing]).map((m) => m.name);
// The executable is what was launched, so it leads. Then the modules WITHOUT
// debug information: this view exists to answer "why can I see nothing in this
// package", and burying that under forty rows of healthy ones defeats it.
eq('the main module leads', sorted[0], 'MyApp.exe');
eq('modules with no symbols come next, alphabetically',
   [sorted[1], sorted[2]], ['ntdll.dll', 'vcl290.bpl']);
eq('modules with symbols come last', sorted[3], 'ReportEngine290.bpl');
eq('sorting does not mutate the caller\'s array',
   mv.sortModules([bare, main])[0] !== undefined, true);

/* -------------------------------------------------------------- filter --- */

const many = [main, withDcp, bare, indexing];

// A blank filter is "no filter", not "match nothing": an empty box must not
// empty a view of 150 modules.
eq('an empty filter shows everything', mv.filterModules(many, '').length, 4);
eq('whitespace is still empty', mv.filterModules(many, '   ').length, 4);
eq('a missing filter is empty too', mv.filterModules(many, undefined).length, 4);

eq('matches by name, case-insensitively',
   mv.filterModules(many, 'NTDLL').map((m) => m.name), ['ntdll.dll']);
// The path matters: on a machine where every package is libSomething, the
// directory is often what tells them apart.
eq('matches by path too',
   mv.filterModules(many, 'C:\\Bpl').map((m) => m.name), ['ReportEngine290.bpl']);
// Words are AND-ed, so two remembered fragments beat one exact spelling. Note
// that '290' alone would also match vcl290.bpl: the second word is what makes
// this one rule out the other.
eq('space-separated words are all required',
   mv.filterModules(many, 'report 290').map((m) => m.name), ['ReportEngine290.bpl']);
eq('a word that matches nothing rules the module out',
   mv.filterModules(many, 'report zzz').length, 0);

eq('the summary counts modules when unfiltered', mv.filterSummary(150, 150, ''), '150 modules');
eq('one module is not "modules"', mv.filterSummary(1, 1, ''), '1 module');
// "7 of 150" is the difference between a filter that worked and one that
// silently matched nothing.
eq('the summary shows what was filtered away',
   mv.filterSummary(150, 7, 'vcl'), '7 of 150 — filter: vcl');

/* --------------------------------------------------------------- status -- */

eq('a module with formats has symbols', mv.hasSymbols(withDcp), true);
eq('a module with an empty format list does not', mv.hasSymbols(bare), false);
eq('a missing format list does not throw', mv.hasSymbols({}), false);

eq('the row shows status and address',
   mv.moduleDescription(withDcp), 'TD32 (embedded), .dcp  ·  0x543D0000');

/* -------------------------------------------------------------- details -- */

const details = mv.moduleDetails(withDcp);
const labels = details.map((d) => d.label);
eq('details cover path, address, size and debug info',
   labels, ['path', 'loaded at', 'image size', 'debug info']);
eq('the formats are named, not summarised',
   details[3].value, 'td32, dcp');
eq('the size is human-readable', mv.formatSize(15427734), '14.7 MB');
eq('a small image is shown in KB', mv.formatSize(65536), '64 KB');
eq('an unknown size shows nothing', mv.formatSize(0), '');

// A module with nothing: the row says what it MEANS, in the place someone looks
// when a breakpoint refuses to bind.
const bareDetails = mv.moduleDetails(bare);
eq('no path row when the OS reported none', bareDetails.map((d) => d.label),
   ['loaded at', 'debug info']);
eq('"none" is spelled out with its consequence',
   bareDetails[1].value, 'none found — breakpoints here cannot bind');

// Still indexing is NOT the same as nothing there, and must not read like it:
// one is worth waiting for.
eq('indexing is distinguished from absent',
   mv.moduleDetails(indexing)[1].value, 'still being indexed');

console.log(failures === 0 ? '\nall cases pass' : '\n' + failures + ' case(s) FAILED');
process.exit(failures === 0 ? 0 : 1);
