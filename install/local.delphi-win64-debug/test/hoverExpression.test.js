// What a debug hover should evaluate, on the lines that got it wrong.
//
//   node test/hoverExpression.test.js      (from the extension folder)
//
// Without a provider, VS Code hovers one identifier: hovering
// `IsModuleEnabled('X')` evaluated `IsModuleEnabled` alone, and hovering the
// string literal sent a fragment that the expression parser rejected as an
// unterminated string. These cases pin the growth rule that replaced it.

const path = require('path');
const Module = require('module');

// Redirect `require('vscode')` to the stub before loading the extension.
const stubPath = require.resolve('./vscode-stub.js');
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'vscode') return stubPath;
  return origResolve.call(this, request, ...rest);
};

const ext = require(path.join(__dirname, '..', 'extension.js'));

let failures = 0;

function check(line, word, expected) {
  const start = line.indexOf(word);
  if (start < 0) throw new Error('test bug: "' + word + '" not in the line');
  const span = ext.pascalExpressionSpan(line, start, start + word.length);
  const got = line.slice(span.start, span.end);
  if (got === expected) {
    console.log('ok    hover "' + word + '" -> ' + JSON.stringify(got));
  } else {
    failures++;
    console.log('FAIL  hover "' + word + '" -> ' + JSON.stringify(got) +
                '   expected ' + JSON.stringify(expected));
  }
}

// A call with a string literal: the whole call, not the routine name, and not
// a fragment of the literal.
const call = "  if IsModuleEnabled('INTEGRAZIONE_DA_RIFORNIMENTO') then";
check(call, 'IsModuleEnabled', "IsModuleEnabled('INTEGRAZIONE_DA_RIFORNIMENTO')");

// An indexed property: hovering either half yields the whole indexed access,
// which is the only spelling that HAS a value.
const indexed = '  Result := DictModules.Enabled[ModuleName];';
check(indexed, 'Enabled', 'DictModules.Enabled[ModuleName]');
check(indexed, 'DictModules', 'DictModules.Enabled[ModuleName]');
// ...while the index variable on its own is just itself.
check(indexed, 'ModuleName', 'ModuleName');

// A chain that walks back THROUGH a closing bracket. Requiring an identifier
// before the dot stopped this dead at the last dot.
const chain = '  x := Self.FList[i].Name;';
check(chain, 'Name', 'Self.FList[i].Name');
check(chain, 'FList', 'Self.FList[i].Name');

// Dereference.
check('  y := P^.Field;', 'P', 'P^.Field');

// A bracket inside a string literal must not unbalance the scan.
check("  z := Lookup('a[b').Value;", 'Lookup', "Lookup('a[b').Value");

console.log(failures === 0 ? '\nall cases pass' : '\n' + failures + ' case(s) FAILED');
process.exit(failures === 0 ? 0 : 1);
