'use strict';

/*
 * Schema, validation and serialization for `exceptionRules`.
 *
 * Loaded twice: as a CommonJS module by the extension host (for validation
 * before writing launch.json) and as a plain <script> by the rules-editor
 * webview (for live validation while typing). Keep it free of both `vscode`
 * and DOM APIs.
 */

var RULE_ACTIONS = ['ignore', 'log', 'logStack', 'break'];

var ACTION_DESCRIPTIONS = {
  ignore: 'Resume immediately - no stop, no log',
  log: 'Write "class: message" to the debug console, then resume',
  logStack: 'Like log, plus the formatted call stack',
  break: 'Pause the debuggee in the debugger'
};

// Ordered: this is also the key order used when writing rules back out.
var MATCH_FIELDS = [
  { name: 'class', kind: 'names', label: 'Class (exact)', hint: 'Exact runtime class name, leaf only. Comma-separate for any-of.' },
  { name: 'classIs', kind: 'names', label: 'Class is (inherits)', hint: 'Runtime class or any ancestor (Delphi "is"). Comma-separate for any-of.' },
  { name: 'code', kind: 'codes', label: 'Exception code (native)', hint: 'Win32 exception code: 0xC0000005, $C0000005 or decimal. Comma-separate for any-of. The only criterion that can match a NATIVE exception - those carry no class and no message.' },
  { name: 'message', kind: 'string', label: 'Message contains', hint: 'Case-insensitive substring of the exception message.' },
  { name: 'messageRegex', kind: 'regex', label: 'Message matches regex', hint: 'Regular expression against the message (ignore-case).' },
  { name: 'unit', kind: 'string', label: 'Unit', hint: 'Unit where raised, e.g. OracleData. Use *unknown* for unresolvable source.' },
  { name: 'line', kind: 'integer', label: 'Line (exact)', hint: 'Exact source line of the raise site.' },
  { name: 'lineFrom', kind: 'integer', label: 'Line from', hint: 'Inclusive lower bound of the source-line range.' },
  { name: 'lineTo', kind: 'integer', label: 'Line to', hint: 'Inclusive upper bound of the source-line range.' }
];

var FIELD_ORDER = MATCH_FIELDS.map(function (field) { return field.name; }).concat(['action']);

function fieldByName(name) {
  for (var i = 0; i < MATCH_FIELDS.length; i++) {
    if (MATCH_FIELDS[i].name === name) return MATCH_FIELDS[i];
  }
  return undefined;
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

function validateNames(fieldName, value, report) {
  if (typeof value === 'string') {
    if (!isNonEmptyString(value)) report(fieldName, 'must not be empty');
    return;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      report(fieldName, 'must list at least one name');
      return;
    }
    var allStrings = value.every(isNonEmptyString);
    if (!allStrings) report(fieldName, 'must contain only non-empty class names');
    return;
  }
  report(fieldName, 'must be a class name or an array of class names');
}

/*
 * A Win32 exception code, in the same spellings the adapter accepts:
 * "0xC0000005" / "0XC0000005", "$C0000005", decimal ("3221225477") or the
 * signed decimal a JSON producer may emit ("-1073741819"). 0 is not a real
 * exception code and is rejected. Returns the code as an unsigned number, or
 * undefined when the text is not a valid code.
 */
function parseExceptionCode(value) {
  if (typeof value === 'number') {
    if (!isFinite(value) || Math.floor(value) !== value) return undefined;
    return normalizeCodeNumber(value);
  }
  if (typeof value !== 'string') return undefined;
  var text = value.trim();
  var parsed;
  if (/^\$[0-9a-fA-F]+$/.test(text)) {
    parsed = parseInt(text.substring(1), 16);
  } else if (/^0[xX][0-9a-fA-F]+$/.test(text)) {
    parsed = parseInt(text.substring(2), 16);
  } else if (/^-?\d+$/.test(text)) {
    parsed = parseInt(text, 10);
  } else {
    return undefined;
  }
  return normalizeCodeNumber(parsed);
}

function normalizeCodeNumber(parsed) {
  if (!isFinite(parsed)) return undefined;
  // Accept both the unsigned (3221225477) and signed (-1073741819) spelling of
  // a code whose high bit is set.
  if (parsed < 0) {
    if (parsed < -2147483648) return undefined;
    parsed = parsed + 4294967296;
  }
  if (parsed > 4294967295 || parsed === 0) return undefined;
  return parsed;
}

function validateCodes(fieldName, value, report) {
  var entries = Array.isArray(value) ? value : [value];
  if (Array.isArray(value) && value.length === 0) {
    report(fieldName, 'must list at least one exception code');
    return;
  }
  for (var i = 0; i < entries.length; i++) {
    if (parseExceptionCode(entries[i]) === undefined) {
      report(fieldName, 'is not a valid Win32 exception code: ' + JSON.stringify(entries[i]) +
        ' - use 0xC0000005, $C0000005 or a decimal number');
      return;
    }
  }
}

function validateInteger(fieldName, value, report) {
  if (typeof value !== 'number' || !isFinite(value) || Math.floor(value) !== value) {
    report(fieldName, 'must be an integer line number');
    return;
  }
  if (value < 1) report(fieldName, 'must be 1 or greater');
}

/** Returns an array of { index, field, message } problems for one rule. */
function validateRule(rule, index) {
  var problems = [];
  function report(field, message) {
    problems.push({ index: index, field: field, message: message });
  }

  if (!rule || typeof rule !== 'object' || Array.isArray(rule)) {
    report('', 'rule must be a JSON object');
    return problems;
  }

  Object.keys(rule).forEach(function (key) {
    if (FIELD_ORDER.indexOf(key) === -1) {
      report(key, 'unknown field "' + key + '" - allowed: ' + FIELD_ORDER.join(', '));
    }
  });

  if (rule.action === undefined) {
    report('action', 'action is required');
  } else if (RULE_ACTIONS.indexOf(rule.action) === -1) {
    report('action', 'invalid action "' + rule.action + '" - must be one of ' + RULE_ACTIONS.join(', '));
  }

  MATCH_FIELDS.forEach(function (field) {
    var value = rule[field.name];
    if (value === undefined) return;
    if (field.kind === 'names') {
      validateNames(field.name, value, report);
    } else if (field.kind === 'codes') {
      validateCodes(field.name, value, report);
    } else if (field.kind === 'integer') {
      validateInteger(field.name, value, report);
    } else if (field.kind === 'regex') {
      if (!isNonEmptyString(value)) {
        report(field.name, 'must not be empty');
      } else {
        try {
          new RegExp(value, 'i');
        } catch (error) {
          report(field.name, 'is not a valid regular expression: ' + error.message);
        }
      }
    } else if (!isNonEmptyString(value)) {
      report(field.name, 'must not be empty');
    }
  });

  if (typeof rule.lineFrom === 'number' && typeof rule.lineTo === 'number' && rule.lineFrom > rule.lineTo) {
    report('lineTo', 'lineTo must be greater than or equal to lineFrom');
  }

  return problems;
}

function validateRules(rules) {
  if (!Array.isArray(rules)) return [{ index: -1, field: '', message: 'exceptionRules must be an array' }];
  var problems = [];
  rules.forEach(function (rule, index) {
    problems = problems.concat(validateRule(rule, index));
  });
  return problems;
}

/** Drops empty fields and returns a new object with the canonical key order. */
function normalizeRule(rule) {
  var result = {};
  FIELD_ORDER.forEach(function (key) {
    var value = rule[key];
    if (value === undefined || value === null || value === '') return;
    if (Array.isArray(value) && value.length === 0) return;
    result[key] = value;
  });
  Object.keys(rule).forEach(function (key) {
    if (FIELD_ORDER.indexOf(key) === -1) result[key] = rule[key];
  });
  return result;
}

/** One rule per line - the evaluation order stays obvious in the file. */
function serializeRules(rules, baseIndent, eol) {
  if (!rules.length) return '[]';
  var itemIndent = baseIndent + '  ';
  var lines = rules.map(function (rule) {
    var normalized = normalizeRule(rule);
    var pairs = Object.keys(normalized).map(function (key) {
      return JSON.stringify(key) + ': ' + JSON.stringify(normalized[key]);
    });
    return itemIndent + '{ ' + pairs.join(', ') + ' }';
  });
  return '[' + eol + lines.join(',' + eol) + eol + baseIndent + ']';
}

/** "EAbort, EMyError" <-> "EAbort" | ["EAbort","EMyError"] */
function namesToText(value) {
  if (value === undefined || value === null) return '';
  if (Array.isArray(value)) return value.join(', ');
  return String(value);
}

function textToNames(text) {
  var parts = String(text).split(',').map(function (part) { return part.trim(); })
    .filter(function (part) { return part !== ''; });
  if (parts.length === 0) return undefined;
  if (parts.length === 1) return parts[0];
  return parts;
}

/** "0xC0000005, $406D1388" <-> "0xC0000005" | ["0xC0000005","$406D1388"] */
function codesToText(value) {
  if (value === undefined || value === null) return '';
  if (Array.isArray(value)) return value.join(', ');
  return String(value);
}

function textToCodes(text) {
  var parts = String(text).split(',').map(function (part) { return part.trim(); })
    .filter(function (part) { return part !== ''; });
  // Plain decimal stays a JSON number so a numeric launch.json entry survives a
  // round-trip through the editor unchanged; everything else stays a string.
  var values = parts.map(function (part) {
    return /^-?\d+$/.test(part) ? Number(part) : part;
  });
  if (values.length === 0) return undefined;
  if (values.length === 1) return values[0];
  return values;
}

/**
 * What a rule MATCHES, in plain English, with the criteria it does not set left
 * out entirely - which is the point: a rule that names a class and a message is
 * two clauses long, not ten blank fields.
 *
 * Separate from the action so a caller with limited width can truncate the
 * criteria and still show the action in full. In a collapsed card the action is
 * the half you cannot afford to lose.
 */
function describeRuleCriteria(rule) {
  var criteria = [];
  MATCH_FIELDS.forEach(function (field) {
    var value = rule[field.name];
    if (value === undefined || value === '') return;
    if (field.name === 'class') criteria.push('class = ' + namesToText(value));
    else if (field.name === 'classIs') criteria.push('is ' + namesToText(value));
    else if (field.name === 'code') criteria.push('code = ' + codesToText(value));
    else if (field.name === 'message') criteria.push('message contains "' + value + '"');
    else if (field.name === 'messageRegex') criteria.push('message =~ /' + value + '/i');
    else if (field.name === 'unit') criteria.push('unit ' + value);
    else if (field.name === 'line') criteria.push('line ' + value);
    else if (field.name === 'lineFrom') criteria.push('line >= ' + value);
    else if (field.name === 'lineTo') criteria.push('line <= ' + value);
  });
  return criteria.length ? criteria.join(' AND ') : 'any exception';
}

/** Short plain-English summary: what it matches, then what it does. */
function describeRule(rule) {
  return describeRuleCriteria(rule) + '  ->  ' + (rule.action || '(no action)');
}

/** Trims a message to something that fits on one QuickPick line. */
function shortenMessage(text, limit) {
  var max = limit || 60;
  var single = String(text === undefined || text === null ? '' : text).replace(/\s+/g, ' ').trim();
  if (single.length <= max) return single;
  return single.slice(0, max - 1) + '…';
}

/**
 * The candidate rules a developer plausibly wants while stopped on an
 * exception, pre-filled from that exception.
 *
 * Pure data: the QuickPick that shows these lives in exceptionRuleWizard.js.
 * `info` is { exceptionClass, message, unitName, line }; anything unknown is
 * simply left out of the generated rules, and options that would carry no
 * criterion at all are not offered.
 *
 * Every entry is { id, label, description, detail, rule, openEditor }.
 */
function suggestRulesForException(info) {
  var data = info || {};
  var className = isNonEmptyString(data.exceptionClass) ? data.exceptionClass.trim() : '';
  var message = isNonEmptyString(data.message) ? data.message.trim() : '';
  var unitName = isNonEmptyString(data.unitName) ? data.unitName.trim() : '';
  var line = typeof data.line === 'number' && isFinite(data.line) && data.line > 0
    ? Math.floor(data.line) : undefined;
  var subject = className || 'this exception';
  var suggestions = [];

  function add(id, label, detail, rule, openEditor) {
    suggestions.push({
      id: id,
      label: label,
      description: rule.action,
      detail: detail,
      rule: normalizeRule(rule),
      openEditor: openEditor === true
    });
  }

  if (className) {
    add('ignore-class', 'Ignore ' + className + ' everywhere',
      'Never stop on this class again, in any unit.',
      { class: className, action: 'ignore' });
  }
  if (className && unitName) {
    add('ignore-in-unit', 'Ignore ' + className + ' raised in ' + unitName,
      'Other units keep breaking on ' + className + '.',
      { class: className, unit: unitName, action: 'ignore' });
  }
  if (unitName && line !== undefined) {
    var atLine = { unit: unitName, line: line, action: 'ignore' };
    if (className) atLine = { class: className, unit: unitName, line: line, action: 'ignore' };
    add('ignore-at-line', 'Ignore ' + subject + ' at ' + unitName + ':' + line,
      'Only this exact raise site.', atLine);
  }
  if (className) {
    add('log-stack', 'Log ' + className + ' with its call stack instead of breaking',
      'Written to the Debug Console, then the debuggee resumes.',
      { class: className, action: 'logStack' });
  }
  if (message) {
    var byMessage = { message: message, action: 'ignore' };
    if (className) byMessage = { class: className, message: message, action: 'ignore' };
    add('ignore-message', 'Ignore ' + subject + ' when the message contains "' + shortenMessage(message, 40) + '"',
      'Case-insensitive substring match on the message.', byMessage);
  }

  var prefilled = { action: 'break' };
  if (className) prefilled.class = className;
  if (unitName) prefilled.unit = unitName;
  if (line !== undefined) prefilled.line = line;
  add('custom', 'Edit a pre-filled rule in the rules editor…',
    'Opens the editor with every criterion from this exception filled in.',
    prefilled, true);

  return suggestions;
}

var api = {
  RULE_ACTIONS: RULE_ACTIONS,
  ACTION_DESCRIPTIONS: ACTION_DESCRIPTIONS,
  MATCH_FIELDS: MATCH_FIELDS,
  FIELD_ORDER: FIELD_ORDER,
  fieldByName: fieldByName,
  validateRule: validateRule,
  validateRules: validateRules,
  normalizeRule: normalizeRule,
  serializeRules: serializeRules,
  namesToText: namesToText,
  textToNames: textToNames,
  codesToText: codesToText,
  textToCodes: textToCodes,
  parseExceptionCode: parseExceptionCode,
  describeRuleCriteria: describeRuleCriteria,
  describeRule: describeRule,
  shortenMessage: shortenMessage,
  suggestRulesForException: suggestRulesForException
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
} else if (typeof window !== 'undefined') {
  window.DelphiRules = api;
}
