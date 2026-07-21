'use strict';

/*
 * Minimal JSONC (JSON with comments and trailing commas) parser that keeps
 * source ranges, plus helpers to compute a *targeted* text edit for a single
 * property.
 *
 * Why this exists: `launch.json` belongs to the user and is normally full of
 * comments. Rewriting the whole `configurations` array through the VS Code
 * configuration API would re-serialize it and drop every comment inside it.
 * By locating the exact character range of one property value we can replace
 * only that range and leave the rest of the file byte-for-byte untouched.
 *
 * No VS Code dependency: this module is plain Node/CommonJS so it can be unit
 * tested with `node` alone.
 */

class JsoncError extends Error {
  constructor(message, offset) {
    super(offset === undefined ? message : `${message} (at offset ${offset})`);
    this.name = 'JsoncError';
    this.offset = offset;
  }
}

function makeNode(type, offset, length, extra) {
  return Object.assign({ type: type, offset: offset, length: length }, extra || {});
}

/**
 * Parses JSONC text into a node tree.
 *
 * Node shapes:
 *   object   { type:'object',   offset, length, children:[property...] }
 *   array    { type:'array',    offset, length, children:[value...] }
 *   property { type:'property', offset, length, children:[keyNode, valueNode] }
 *   string / number / boolean / null: { type, offset, length, value }
 */
function parseTree(text) {
  let pos = 0;

  function skipTrivia() {
    while (pos < text.length) {
      const ch = text[pos];
      if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') {
        pos++;
        continue;
      }
      if (ch === '/' && text[pos + 1] === '/') {
        pos += 2;
        while (pos < text.length && text[pos] !== '\n') pos++;
        continue;
      }
      if (ch === '/' && text[pos + 1] === '*') {
        pos += 2;
        while (pos < text.length && !(text[pos] === '*' && text[pos + 1] === '/')) pos++;
        pos = Math.min(pos + 2, text.length);
        continue;
      }
      break;
    }
  }

  function parseStringLiteral() {
    const start = pos;
    pos++; // opening quote
    let value = '';
    while (pos < text.length) {
      const ch = text[pos];
      if (ch === '"') {
        pos++;
        return makeNode('string', start, pos - start, { value: value });
      }
      if (ch === '\\') {
        const esc = text[pos + 1];
        pos += 2;
        switch (esc) {
          case '"': value += '"'; break;
          case '\\': value += '\\'; break;
          case '/': value += '/'; break;
          case 'b': value += '\b'; break;
          case 'f': value += '\f'; break;
          case 'n': value += '\n'; break;
          case 'r': value += '\r'; break;
          case 't': value += '\t'; break;
          case 'u': {
            const hex = text.substr(pos, 4);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new JsoncError('Invalid \\u escape', pos);
            value += String.fromCharCode(parseInt(hex, 16));
            pos += 4;
            break;
          }
          default:
            throw new JsoncError('Invalid escape sequence', pos - 2);
        }
        continue;
      }
      if (ch === '\n') throw new JsoncError('Unterminated string', start);
      value += ch;
      pos++;
    }
    throw new JsoncError('Unterminated string', start);
  }

  function parseLiteral() {
    const start = pos;
    for (const [word, value] of [['true', true], ['false', false], ['null', null]]) {
      if (text.startsWith(word, pos)) {
        pos += word.length;
        return makeNode(word === 'null' ? 'null' : 'boolean', start, pos - start, { value: value });
      }
    }
    const match = /^-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?/.exec(text.slice(pos));
    if (!match) throw new JsoncError('Unexpected token', pos);
    pos += match[0].length;
    return makeNode('number', start, pos - start, { value: Number(match[0]) });
  }

  function parseObject() {
    const start = pos;
    pos++; // '{'
    const children = [];
    for (;;) {
      skipTrivia();
      if (pos >= text.length) throw new JsoncError('Unterminated object', start);
      if (text[pos] === '}') {
        pos++;
        return makeNode('object', start, pos - start, { children: children });
      }
      if (text[pos] !== '"') throw new JsoncError('Expected property name', pos);
      const key = parseStringLiteral();
      skipTrivia();
      if (text[pos] !== ':') throw new JsoncError('Expected ":"', pos);
      pos++;
      const value = parseValue();
      children.push(makeNode('property', key.offset, value.offset + value.length - key.offset,
        { children: [key, value] }));
      skipTrivia();
      if (pos >= text.length) throw new JsoncError('Unterminated object', start);
      if (text[pos] === ',') {
        pos++;
        continue;
      }
      if (text[pos] === '}') continue;
      throw new JsoncError('Expected "," or "}"', pos);
    }
  }

  function parseArray() {
    const start = pos;
    pos++; // '['
    const children = [];
    for (;;) {
      skipTrivia();
      if (pos >= text.length) throw new JsoncError('Unterminated array', start);
      if (text[pos] === ']') {
        pos++;
        return makeNode('array', start, pos - start, { children: children });
      }
      children.push(parseValue());
      skipTrivia();
      if (pos >= text.length) throw new JsoncError('Unterminated array', start);
      if (text[pos] === ',') {
        pos++;
        continue;
      }
      if (text[pos] === ']') continue;
      throw new JsoncError('Expected "," or "]"', pos);
    }
  }

  function parseValue() {
    skipTrivia();
    if (pos >= text.length) throw new JsoncError('Unexpected end of input', pos);
    const ch = text[pos];
    if (ch === '{') return parseObject();
    if (ch === '[') return parseArray();
    if (ch === '"') return parseStringLiteral();
    return parseLiteral();
  }

  skipTrivia();
  if (pos >= text.length) return undefined;
  const root = parseValue();
  skipTrivia();
  if (pos < text.length) throw new JsoncError('Trailing content after top-level value', pos);
  return root;
}

function getNodeValue(node) {
  if (!node) return undefined;
  switch (node.type) {
    case 'object': {
      const result = {};
      for (const property of node.children) {
        result[property.children[0].value] = getNodeValue(property.children[1]);
      }
      return result;
    }
    case 'array':
      return node.children.map(getNodeValue);
    case 'property':
      return getNodeValue(node.children[1]);
    default:
      return node.value;
  }
}

function findProperty(objectNode, name) {
  if (!objectNode || objectNode.type !== 'object') return undefined;
  return objectNode.children.find((property) => property.children[0].value === name);
}

/** Walks a path of object keys / array indices and returns the value node. */
function findNodeAtPath(root, path) {
  let current = root;
  for (const segment of path) {
    if (!current) return undefined;
    if (typeof segment === 'number') {
      if (current.type !== 'array') return undefined;
      current = current.children[segment];
    } else {
      const property = findProperty(current, segment);
      current = property ? property.children[1] : undefined;
    }
  }
  return current;
}

/** Leading whitespace of the line containing `offset`. */
function lineIndentAt(text, offset) {
  let lineStart = text.lastIndexOf('\n', Math.max(0, offset - 1)) + 1;
  let end = lineStart;
  while (end < text.length && (text[end] === ' ' || text[end] === '\t')) end++;
  return text.slice(lineStart, end);
}

function detectEol(text) {
  return text.indexOf('\r\n') !== -1 ? '\r\n' : '\n';
}

/**
 * Computes the single text edit that sets `propertyName` of `objectNode` to
 * `serializedValue`.
 *
 * - Property present -> replaces only the value node's range. Everything else,
 *   including comments before/after and inside sibling properties, is untouched.
 * - Property absent  -> inserts `"name": value` after the last existing
 *   property, using that property's indentation.
 *
 * `serializeValue(baseIndent, eol)` must return the already-indented literal.
 * Returns { offset, length, newText }.
 */
function computeSetPropertyEdit(text, objectNode, propertyName, serializeValue) {
  if (!objectNode || objectNode.type !== 'object') {
    throw new JsoncError('Target is not a JSON object');
  }
  const eol = detectEol(text);
  const existing = findProperty(objectNode, propertyName);
  if (existing) {
    const valueNode = existing.children[1];
    const baseIndent = lineIndentAt(text, existing.offset);
    return {
      offset: valueNode.offset,
      length: valueNode.length,
      newText: serializeValue(baseIndent, eol)
    };
  }

  const objectIndent = lineIndentAt(text, objectNode.offset);
  const last = objectNode.children[objectNode.children.length - 1];
  if (!last) {
    const innerIndent = objectIndent + '  ';
    return {
      offset: objectNode.offset + 1,
      length: objectNode.length - 2,
      newText: eol + innerIndent + JSON.stringify(propertyName) + ': ' +
        serializeValue(innerIndent, eol) + eol + objectIndent
    };
  }
  const memberIndent = lineIndentAt(text, last.offset);
  return {
    offset: last.offset + last.length,
    length: 0,
    newText: ',' + eol + memberIndent + JSON.stringify(propertyName) + ': ' +
      serializeValue(memberIndent, eol)
  };
}

function applyEdit(text, edit) {
  return text.slice(0, edit.offset) + edit.newText + text.slice(edit.offset + edit.length);
}

module.exports = {
  JsoncError: JsoncError,
  parseTree: parseTree,
  getNodeValue: getNodeValue,
  findProperty: findProperty,
  findNodeAtPath: findNodeAtPath,
  computeSetPropertyEdit: computeSetPropertyEdit,
  lineIndentAt: lineIndentAt,
  detectEol: detectEol,
  applyEdit: applyEdit
};
