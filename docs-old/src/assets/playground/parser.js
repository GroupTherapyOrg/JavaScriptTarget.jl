// parser.js — Julia parser for the browser playground
// Hand-written recursive descent parser implementing the JuliaSyntax.jl algorithm.
// Produces an AST suitable for the lowerer (PG-004).
//
// Architecture:
//   1. Tokenizer: scans Julia source → token stream
//   2. Parser: recursive descent with Pratt-style precedence climbing
//   3. AST: plain JS objects with `kind` discriminator
//
// Supported Julia subset:
//   - Literals: integers, floats, strings (with interpolation), bools, nothing, chars
//   - Operators: arithmetic, comparison, logical, bitwise, range, ternary
//   - Expressions: function calls, field access, indexing, lambda, comprehension
//   - Statements: function def, struct, abstract type, if/elseif/else, while, for,
//                 try/catch/finally, return, break, continue, assignment
//   - Types: annotations (::T), parametric (T{P}), union (Union{A,B}), abstract hierarchy

'use strict';

// ============================================================================
// Token Kinds
// ============================================================================

const TK = Object.freeze({
  // Literals
  INTEGER:     'Integer',
  FLOAT:       'Float',
  STRING:      'String',
  CHAR:        'Char',
  CMD_STRING:  'CmdString',

  // Identifier & keywords
  IDENT:       'Ident',
  TRUE:        'true',
  FALSE:       'false',
  NOTHING:     'nothing',
  MISSING:     'missing',

  // Keywords
  FUNCTION:    'function',
  END:         'end',
  RETURN:      'return',
  IF:          'if',
  ELSEIF:      'elseif',
  ELSE:        'else',
  WHILE:       'while',
  FOR:         'for',
  IN:          'in',
  DO:          'do',
  BEGIN:       'begin',
  LET:         'let',
  LOCAL:       'local',
  GLOBAL:      'global',
  CONST:       'const',
  STRUCT:      'struct',
  MUTABLE:     'mutable',
  ABSTRACT:    'abstract',
  PRIMITIVE:   'primitive',
  TYPE:        'type',
  MODULE:      'module',
  BAREMODULE:  'baremodule',
  IMPORT:      'import',
  USING:       'using',
  EXPORT:      'export',
  TRY:         'try',
  CATCH:       'catch',
  FINALLY:     'finally',
  THROW:       'throw',
  BREAK:       'break',
  CONTINUE:    'continue',
  QUOTE:       'quote',
  MACRO:       'macro',
  ISA:         'isa',
  WHERE:       'where',

  // Operators
  PLUS:        '+',
  MINUS:       '-',
  STAR:        '*',
  SLASH:       '/',
  BACKSLASH:   '\\',
  CARET:       '^',
  PERCENT:     '%',
  AMPERSAND:   '&',
  PIPE:        '|',
  TILDE:       '~',
  BANG:        '!',
  LSHIFT:      '<<',
  RSHIFT:      '>>',
  URSHIFT:     '>>>',
  DOTPLUS:     '.+',
  DOTMINUS:    '.-',
  DOTSTAR:     '.*',
  DOTSLASH:    './',
  DOTCARET:    '.^',

  // Comparison
  EQ:          '==',
  NEQ:         '!=',
  LT:          '<',
  GT:          '>',
  LE:          '<=',
  GE:          '>=',
  EQEQEQ:     '===',
  NEQEQ:      '!==',

  // Assignment
  ASSIGN:      '=',
  PLUSEQ:      '+=',
  MINUSEQ:     '-=',
  STAREQ:      '*=',
  SLASHEQ:     '/=',
  CARETEQ:     '^=',
  AMPEQ:       '&=',
  PIPEEQ:      '|=',

  // Logical
  ANDAND:      '&&',
  OROR:        '||',

  // Punctuation
  LPAREN:      '(',
  RPAREN:      ')',
  LBRACKET:    '[',
  RBRACKET:    ']',
  LBRACE:      '{',
  RBRACE:      '}',
  COMMA:       ',',
  SEMICOLON:   ';',
  DOT:         '.',
  DOTDOT:      '..',
  ELLIPSIS:    '...',
  COLON:       ':',
  COLONCOLON:  '::',
  ARROW:       '->',
  FATARROW:    '=>',
  QUESTION:    '?',
  AT:          '@',
  DOLLAR:      '$',
  HASH:        '#',
  UNDERSCORE:  '_',
  PIPE_RIGHT:  '|>',
  PIPE_LEFT:   '<|',
  SUBTYPE:     '<:',
  SUPERTYPE:   '>:',

  // Special
  NEWLINE:     'Newline',
  EOF:         'EOF',
  ERROR:       'Error',
});

const KEYWORDS = new Set([
  'function', 'end', 'return', 'if', 'elseif', 'else', 'while', 'for',
  'in', 'do', 'begin', 'let', 'local', 'global', 'const', 'struct',
  'mutable', 'abstract', 'primitive', 'type', 'module', 'baremodule',
  'import', 'using', 'export', 'try', 'catch', 'finally', 'throw',
  'break', 'continue', 'quote', 'macro', 'isa', 'where',
  'true', 'false', 'nothing', 'missing',
]);

// ============================================================================
// Tokenizer
// ============================================================================

class Token {
  constructor(kind, value, start, end) {
    this.kind = kind;
    this.value = value;
    this.start = start;
    this.end = end;
  }
}

class Tokenizer {
  constructor(source) {
    this.source = source;
    this.pos = 0;
    this.length = source.length;
  }

  peek() {
    return this.pos < this.length ? this.source[this.pos] : '';
  }

  peekAt(offset) {
    const i = this.pos + offset;
    return i < this.length ? this.source[i] : '';
  }

  advance() {
    return this.source[this.pos++];
  }

  isAtEnd() {
    return this.pos >= this.length;
  }

  skipWhitespace() {
    while (this.pos < this.length) {
      const ch = this.source[this.pos];
      if (ch === ' ' || ch === '\t' || ch === '\r') {
        this.pos++;
      } else if (ch === '#') {
        // Skip line comment
        while (this.pos < this.length && this.source[this.pos] !== '\n') {
          this.pos++;
        }
      } else {
        break;
      }
    }
  }

  nextToken() {
    this.skipWhitespace();
    if (this.isAtEnd()) {
      return new Token(TK.EOF, '', this.pos, this.pos);
    }

    const start = this.pos;
    const ch = this.peek();

    // Newline
    if (ch === '\n') {
      this.advance();
      return new Token(TK.NEWLINE, '\n', start, this.pos);
    }

    // String literal
    if (ch === '"') {
      return this.readString(start);
    }

    // Char literal
    if (ch === '\'' && this.isCharLiteral()) {
      return this.readChar(start);
    }

    // Number
    if (isDigit(ch) || (ch === '.' && isDigit(this.peekAt(1)))) {
      return this.readNumber(start);
    }

    // Identifier or keyword
    if (isIdentStart(ch)) {
      return this.readIdentifier(start);
    }

    // Operators and punctuation
    return this.readOperator(start);
  }

  isCharLiteral() {
    // Heuristic: 'c' is a char if followed by a single char then closing quote
    // But 'identifier is a symbol, so we check carefully
    if (this.pos + 2 < this.length && this.source[this.pos + 2] === '\'') {
      return true; // 'x' pattern
    }
    if (this.pos + 3 < this.length && this.source[this.pos + 1] === '\\' && this.source[this.pos + 3] === '\'') {
      return true; // '\n' pattern
    }
    return false;
  }

  readString(start) {
    this.advance(); // skip opening "

    // Check for triple-quoted string
    if (this.peek() === '"' && this.peekAt(1) === '"') {
      this.advance(); this.advance(); // skip ""
      return this.readTripleString(start);
    }

    let value = '';
    let hasInterp = false;
    const parts = [];

    while (!this.isAtEnd() && this.peek() !== '"') {
      if (this.peek() === '\\') {
        this.advance();
        value += this.readEscapeChar();
      } else if (this.peek() === '$') {
        hasInterp = true;
        if (value.length > 0) {
          parts.push({ kind: 'literal', value });
          value = '';
        }
        this.advance(); // skip $
        if (this.peek() === '(') {
          this.advance(); // skip (
          parts.push({ kind: 'expr', tokens: this.readInterpolatedExpr() });
        } else {
          // Simple variable: $name
          const nameStart = this.pos;
          while (!this.isAtEnd() && isIdentContinue(this.peek())) {
            this.advance();
          }
          parts.push({ kind: 'name', value: this.source.slice(nameStart, this.pos) });
        }
      } else {
        value += this.advance();
      }
    }

    if (!this.isAtEnd()) this.advance(); // skip closing "

    if (hasInterp) {
      if (value.length > 0) parts.push({ kind: 'literal', value });
      return new Token(TK.STRING, parts, start, this.pos);
    }
    return new Token(TK.STRING, value, start, this.pos);
  }

  readTripleString(start) {
    let value = '';
    while (!this.isAtEnd()) {
      if (this.peek() === '"' && this.peekAt(1) === '"' && this.peekAt(2) === '"') {
        this.advance(); this.advance(); this.advance();
        return new Token(TK.STRING, value, start, this.pos);
      }
      if (this.peek() === '\\') {
        this.advance();
        value += this.readEscapeChar();
      } else {
        value += this.advance();
      }
    }
    return new Token(TK.STRING, value, start, this.pos);
  }

  readEscapeChar() {
    if (this.isAtEnd()) return '';
    const ch = this.advance();
    switch (ch) {
      case 'n': return '\n';
      case 't': return '\t';
      case 'r': return '\r';
      case '\\': return '\\';
      case '"': return '"';
      case '\'': return '\'';
      case '0': return '\0';
      case '$': return '$';
      case 'a': return '\x07';
      case 'b': return '\b';
      case 'f': return '\f';
      case 'v': return '\v';
      default: return '\\' + ch;
    }
  }

  readInterpolatedExpr() {
    // Read tokens until matching )
    const tokens = [];
    let depth = 1;
    while (!this.isAtEnd() && depth > 0) {
      const tok = this.nextToken();
      if (tok.kind === TK.LPAREN) depth++;
      else if (tok.kind === TK.RPAREN) {
        depth--;
        if (depth === 0) break;
      }
      tokens.push(tok);
    }
    return tokens;
  }

  readChar(start) {
    this.advance(); // skip opening '
    let value;
    if (this.peek() === '\\') {
      this.advance();
      value = this.readEscapeChar();
    } else {
      value = this.advance();
    }
    if (this.peek() === '\'') this.advance(); // skip closing '
    return new Token(TK.CHAR, value, start, this.pos);
  }

  readNumber(start) {
    let isFloat = false;

    // Check for hex/octal/binary prefix
    if (this.peek() === '0' && this.pos + 1 < this.length) {
      const next = this.peekAt(1);
      if (next === 'x' || next === 'X') return this.readHexNumber(start);
      if (next === 'o' || next === 'O') return this.readOctalNumber(start);
      if (next === 'b' || next === 'B') return this.readBinaryNumber(start);
    }

    // Integer part
    while (!this.isAtEnd() && (isDigit(this.peek()) || this.peek() === '_')) {
      this.advance();
    }

    // Decimal part
    if (this.peek() === '.' && isDigit(this.peekAt(1))) {
      isFloat = true;
      this.advance(); // skip .
      while (!this.isAtEnd() && (isDigit(this.peek()) || this.peek() === '_')) {
        this.advance();
      }
    }

    // Exponent
    if (this.peek() === 'e' || this.peek() === 'E') {
      isFloat = true;
      this.advance();
      if (this.peek() === '+' || this.peek() === '-') this.advance();
      while (!this.isAtEnd() && (isDigit(this.peek()) || this.peek() === '_')) {
        this.advance();
      }
    }

    const raw = this.source.slice(start, this.pos);
    const cleaned = raw.replace(/_/g, '');

    if (isFloat) {
      return new Token(TK.FLOAT, parseFloat(cleaned), start, this.pos);
    }
    return new Token(TK.INTEGER, parseInt(cleaned, 10), start, this.pos);
  }

  readHexNumber(start) {
    this.advance(); this.advance(); // skip 0x
    while (!this.isAtEnd() && (isHexDigit(this.peek()) || this.peek() === '_')) {
      this.advance();
    }
    const raw = this.source.slice(start + 2, this.pos).replace(/_/g, '');
    return new Token(TK.INTEGER, parseInt(raw, 16), start, this.pos);
  }

  readOctalNumber(start) {
    this.advance(); this.advance(); // skip 0o
    while (!this.isAtEnd() && (isOctalDigit(this.peek()) || this.peek() === '_')) {
      this.advance();
    }
    const raw = this.source.slice(start + 2, this.pos).replace(/_/g, '');
    return new Token(TK.INTEGER, parseInt(raw, 8), start, this.pos);
  }

  readBinaryNumber(start) {
    this.advance(); this.advance(); // skip 0b
    while (!this.isAtEnd() && (this.peek() === '0' || this.peek() === '1' || this.peek() === '_')) {
      this.advance();
    }
    const raw = this.source.slice(start + 2, this.pos).replace(/_/g, '');
    return new Token(TK.INTEGER, parseInt(raw, 2), start, this.pos);
  }

  readIdentifier(start) {
    while (!this.isAtEnd() && isIdentContinue(this.peek())) {
      this.advance();
    }
    // Allow trailing ! or ? for Julia identifiers (push!, isempty?)
    if (this.peek() === '!' || this.peek() === '?') {
      this.advance();
    }

    const name = this.source.slice(start, this.pos);

    if (KEYWORDS.has(name)) {
      return new Token(name, name, start, this.pos); // kind = keyword itself
    }
    return new Token(TK.IDENT, name, start, this.pos);
  }

  readOperator(start) {
    const ch = this.advance();

    switch (ch) {
      case '(':  return new Token(TK.LPAREN,    ch, start, this.pos);
      case ')':  return new Token(TK.RPAREN,    ch, start, this.pos);
      case '[':  return new Token(TK.LBRACKET,  ch, start, this.pos);
      case ']':  return new Token(TK.RBRACKET,  ch, start, this.pos);
      case '{':  return new Token(TK.LBRACE,    ch, start, this.pos);
      case '}':  return new Token(TK.RBRACE,    ch, start, this.pos);
      case ',':  return new Token(TK.COMMA,     ch, start, this.pos);
      case ';':  return new Token(TK.SEMICOLON, ch, start, this.pos);
      case '@':  return new Token(TK.AT,        ch, start, this.pos);
      case '$':  return new Token(TK.DOLLAR,    ch, start, this.pos);
      case '~':  return new Token(TK.TILDE,     ch, start, this.pos);
      case '\\': return new Token(TK.BACKSLASH, ch, start, this.pos);

      case '+':
        if (this.peek() === '=') { this.advance(); return new Token(TK.PLUSEQ, '+=', start, this.pos); }
        return new Token(TK.PLUS, '+', start, this.pos);

      case '-':
        if (this.peek() === '>') { this.advance(); return new Token(TK.ARROW, '->', start, this.pos); }
        if (this.peek() === '=') { this.advance(); return new Token(TK.MINUSEQ, '-=', start, this.pos); }
        return new Token(TK.MINUS, '-', start, this.pos);

      case '*':
        if (this.peek() === '=') { this.advance(); return new Token(TK.STAREQ, '*=', start, this.pos); }
        return new Token(TK.STAR, '*', start, this.pos);

      case '/':
        if (this.peek() === '=') { this.advance(); return new Token(TK.SLASHEQ, '/=', start, this.pos); }
        return new Token(TK.SLASH, '/', start, this.pos);

      case '^':
        if (this.peek() === '=') { this.advance(); return new Token(TK.CARETEQ, '^=', start, this.pos); }
        return new Token(TK.CARET, '^', start, this.pos);

      case '%':
        return new Token(TK.PERCENT, '%', start, this.pos);

      case '&':
        if (this.peek() === '&') { this.advance(); return new Token(TK.ANDAND, '&&', start, this.pos); }
        if (this.peek() === '=') { this.advance(); return new Token(TK.AMPEQ, '&=', start, this.pos); }
        return new Token(TK.AMPERSAND, '&', start, this.pos);

      case '|':
        if (this.peek() === '|') { this.advance(); return new Token(TK.OROR, '||', start, this.pos); }
        if (this.peek() === '>') { this.advance(); return new Token(TK.PIPE_RIGHT, '|>', start, this.pos); }
        if (this.peek() === '=') { this.advance(); return new Token(TK.PIPEEQ, '|=', start, this.pos); }
        return new Token(TK.PIPE, '|', start, this.pos);

      case '!':
        if (this.peek() === '=') {
          this.advance();
          if (this.peek() === '=') { this.advance(); return new Token(TK.NEQEQ, '!==', start, this.pos); }
          return new Token(TK.NEQ, '!=', start, this.pos);
        }
        return new Token(TK.BANG, '!', start, this.pos);

      case '=':
        if (this.peek() === '=') {
          this.advance();
          if (this.peek() === '=') { this.advance(); return new Token(TK.EQEQEQ, '===', start, this.pos); }
          return new Token(TK.EQ, '==', start, this.pos);
        }
        if (this.peek() === '>') { this.advance(); return new Token(TK.FATARROW, '=>', start, this.pos); }
        return new Token(TK.ASSIGN, '=', start, this.pos);

      case '<':
        if (this.peek() === '=') { this.advance(); return new Token(TK.LE, '<=', start, this.pos); }
        if (this.peek() === '<') { this.advance(); return new Token(TK.LSHIFT, '<<', start, this.pos); }
        if (this.peek() === ':') { this.advance(); return new Token(TK.SUBTYPE, '<:', start, this.pos); }
        if (this.peek() === '|') { this.advance(); return new Token(TK.PIPE_LEFT, '<|', start, this.pos); }
        return new Token(TK.LT, '<', start, this.pos);

      case '>':
        if (this.peek() === '=') { this.advance(); return new Token(TK.GE, '>=', start, this.pos); }
        if (this.peek() === '>') {
          this.advance();
          if (this.peek() === '>') { this.advance(); return new Token(TK.URSHIFT, '>>>', start, this.pos); }
          return new Token(TK.RSHIFT, '>>', start, this.pos);
        }
        if (this.peek() === ':') { this.advance(); return new Token(TK.SUPERTYPE, '>:', start, this.pos); }
        return new Token(TK.GT, '>', start, this.pos);

      case ':':
        if (this.peek() === ':') { this.advance(); return new Token(TK.COLONCOLON, '::', start, this.pos); }
        return new Token(TK.COLON, ':', start, this.pos);

      case '.':
        if (this.peek() === '.') {
          this.advance();
          if (this.peek() === '.') { this.advance(); return new Token(TK.ELLIPSIS, '...', start, this.pos); }
          return new Token(TK.DOTDOT, '..', start, this.pos);
        }
        if (this.peek() === '+') { this.advance(); return new Token(TK.DOTPLUS, '.+', start, this.pos); }
        if (this.peek() === '-') { this.advance(); return new Token(TK.DOTMINUS, '.-', start, this.pos); }
        if (this.peek() === '*') { this.advance(); return new Token(TK.DOTSTAR, '.*', start, this.pos); }
        if (this.peek() === '/') { this.advance(); return new Token(TK.DOTSLASH, './', start, this.pos); }
        if (this.peek() === '^') { this.advance(); return new Token(TK.DOTCARET, '.^', start, this.pos); }
        return new Token(TK.DOT, '.', start, this.pos);

      case '?':
        return new Token(TK.QUESTION, '?', start, this.pos);

      default:
        return new Token(TK.ERROR, ch, start, this.pos);
    }
  }

  // Tokenize all at once (for debugging/testing)
  tokenizeAll() {
    const tokens = [];
    while (true) {
      const tok = this.nextToken();
      if (tok.kind === TK.EOF) {
        tokens.push(tok);
        break;
      }
      tokens.push(tok);
    }
    return tokens;
  }
}

// ============================================================================
// Character predicates
// ============================================================================

function isDigit(ch) {
  return ch >= '0' && ch <= '9';
}

function isHexDigit(ch) {
  return isDigit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}

function isOctalDigit(ch) {
  return ch >= '0' && ch <= '7';
}

function isIdentStart(ch) {
  if (ch >= 'a' && ch <= 'z') return true;
  if (ch >= 'A' && ch <= 'Z') return true;
  if (ch === '_') return true;
  // Unicode letters
  if (ch.charCodeAt(0) > 127) return true;
  return false;
}

function isIdentContinue(ch) {
  if (isIdentStart(ch)) return true;
  if (isDigit(ch)) return true;
  return false;
}

// ============================================================================
// AST Node constructors
// ============================================================================

function mkModule(body) { return { kind: 'Module', body }; }
function mkBlock(stmts) { return { kind: 'Block', stmts }; }
function mkInteger(value) { return { kind: 'Integer', value }; }
function mkFloat(value) { return { kind: 'Float', value }; }
function mkStringLit(value) { return { kind: 'StringLit', value }; }
function mkStringInterp(parts) { return { kind: 'StringInterp', parts }; }
function mkCharLit(value) { return { kind: 'CharLit', value }; }
function mkBool(value) { return { kind: 'Bool', value }; }
function mkNothing() { return { kind: 'Nothing' }; }
function mkMissing() { return { kind: 'Missing' }; }
function mkIdentifier(name) { return { kind: 'Identifier', name }; }
function mkBinaryOp(op, left, right) { return { kind: 'BinaryOp', op, left, right }; }
function mkUnaryOp(op, operand) { return { kind: 'UnaryOp', op, operand }; }
function mkCall(func, args) { return { kind: 'Call', func, args }; }
function mkDotCall(func, args) { return { kind: 'DotCall', func, args }; }
function mkDotAccess(object, field) { return { kind: 'DotAccess', object, field }; }
function mkIndex(object, indices) { return { kind: 'Index', object, indices }; }
function mkTernary(cond, then, els) { return { kind: 'Ternary', condition: cond, then, else: els }; }
function mkAnd(left, right) { return { kind: 'And', left, right }; }
function mkOr(left, right) { return { kind: 'Or', left, right }; }
function mkComparison(ops, operands) { return { kind: 'Comparison', ops, operands }; }
function mkRange(start, step, stop) { return { kind: 'Range', start, step, stop }; }
function mkTuple(elements) { return { kind: 'Tuple', elements }; }
function mkArrayLit(elements) { return { kind: 'ArrayLit', elements }; }
function mkComprehension(expr, generators) { return { kind: 'Comprehension', expr, generators }; }
function mkTypedExpr(expr, type) { return { kind: 'TypeAnnotation', expr, type }; }
function mkTypeApply(name, params) { return { kind: 'TypeApply', name, params }; }
function mkLambda(params, body) { return { kind: 'Lambda', params, body }; }
function mkSplat(expr) { return { kind: 'Splat', expr }; }
function mkKwArg(name, value) { return { kind: 'KwArg', name, value }; }

function mkAssignment(target, op, value) { return { kind: 'Assignment', target, op, value }; }
function mkFunctionDef(name, params, returnType, body, isShort) {
  return { kind: 'FunctionDef', name, params, returnType, body, isShort: !!isShort };
}
function mkParam(name, type, default_) { return { kind: 'Param', name, type, default: default_ || null }; }
function mkStructDef(name, mutable, supertype, params, fields) {
  return { kind: 'StructDef', name, mutable: !!mutable, supertype, params, fields };
}
function mkField(name, type) { return { kind: 'Field', name, type }; }
function mkAbstractTypeDef(name, supertype, params) {
  return { kind: 'AbstractTypeDef', name, supertype, params };
}
function mkIf(condition, then_, elseifs, else_) {
  return { kind: 'If', condition, then: then_, elseifs, else: else_ };
}
function mkWhile(condition, body) { return { kind: 'While', condition, body }; }
function mkFor(var_, iter, body) { return { kind: 'For', var: var_, iter, body }; }
function mkTryCatch(tryBody, catchVar, catchBody, finallyBody) {
  return { kind: 'TryCatch', tryBody, catchVar, catchBody, finallyBody };
}
function mkReturn(value) { return { kind: 'Return', value }; }
function mkBreak() { return { kind: 'Break' }; }
function mkContinue() { return { kind: 'Continue' }; }
function mkThrow(expr) { return { kind: 'Throw', expr }; }
function mkMacroCall(name, args) { return { kind: 'MacroCall', name, args }; }
function mkLocal(names) { return { kind: 'Local', names }; }
function mkConst(name, value) { return { kind: 'Const', name, value }; }

// ============================================================================
// Parser
// ============================================================================

class Parser {
  constructor(source) {
    this.tokenizer = new Tokenizer(source);
    this.tokens = [];
    this.pos = 0;
    this.diagnostics = [];
    // Pre-tokenize all tokens (filtering newlines into a flag)
    this._tokenize();
  }

  _tokenize() {
    let prevWasNewline = false;
    while (true) {
      const tok = this.tokenizer.nextToken();
      if (tok.kind === TK.NEWLINE) {
        // Mark previous token as having trailing newline
        prevWasNewline = true;
        continue;
      }
      tok.newlineBefore = prevWasNewline;
      prevWasNewline = false;
      this.tokens.push(tok);
      if (tok.kind === TK.EOF) break;
    }
  }

  // --- Token access ---

  peek() {
    return this.tokens[this.pos];
  }

  peekKind() {
    return this.tokens[this.pos].kind;
  }

  peekAt(offset) {
    const i = this.pos + offset;
    return i < this.tokens.length ? this.tokens[i] : this.tokens[this.tokens.length - 1];
  }

  advance() {
    const tok = this.tokens[this.pos];
    if (tok.kind !== TK.EOF) this.pos++;
    return tok;
  }

  expect(kind) {
    const tok = this.peek();
    if (tok.kind !== kind) {
      this.error(`Expected '${kind}', got '${tok.kind}' (${JSON.stringify(tok.value)})`);
      return tok;
    }
    return this.advance();
  }

  match(kind) {
    if (this.peekKind() === kind) {
      return this.advance();
    }
    return null;
  }

  atEnd() {
    return this.peekKind() === TK.EOF;
  }

  error(msg) {
    const tok = this.peek();
    this.diagnostics.push({ message: msg, start: tok.start, end: tok.end });
  }

  // --- Statement separator ---

  isStatementSeparator() {
    const tok = this.peek();
    return tok.kind === TK.SEMICOLON || tok.kind === TK.EOF || tok.newlineBefore;
  }

  skipSemicolons() {
    while (this.peekKind() === TK.SEMICOLON) this.advance();
  }

  // --- Parse entry points ---

  parseModule() {
    const body = this.parseStatements();
    if (!this.atEnd()) {
      this.error(`Unexpected token: ${this.peek().kind}`);
    }
    return mkModule(body);
  }

  parseStatements(closingTokens) {
    const stmts = [];
    const closers = closingTokens || new Set([TK.EOF]);

    while (!closers.has(this.peekKind())) {
      this.skipSemicolons();
      if (closers.has(this.peekKind())) break;
      const stmt = this.parseStatement();
      if (stmt) stmts.push(stmt);
      this.skipSemicolons();
    }
    return stmts;
  }

  // --- Statement parsing ---

  parseStatement() {
    const tok = this.peek();

    switch (tok.kind) {
      case TK.FUNCTION: return this.parseFunctionDef();
      case TK.STRUCT:   return this.parseStructDef(false);
      case TK.MUTABLE:  return this.parseMutableStruct();
      case TK.ABSTRACT: return this.parseAbstractType();
      case TK.IF:       return this.parseIf();
      case TK.WHILE:    return this.parseWhile();
      case TK.FOR:      return this.parseFor();
      case TK.TRY:      return this.parseTryCatch();
      case TK.RETURN:   return this.parseReturn();
      case TK.BREAK:    this.advance(); return mkBreak();
      case TK.CONTINUE: this.advance(); return mkContinue();
      case TK.THROW:    return this.parseThrow();
      case TK.BEGIN:    return this.parseBeginBlock();
      case TK.LET:      return this.parseLetBlock();
      case TK.LOCAL:    return this.parseLocal();
      case TK.GLOBAL:   return this.parseGlobal();
      case TK.CONST:    return this.parseConst();
      case TK.AT:       return this.parseMacroCall();
      default:          return this.parseExpressionStatement();
    }
  }

  parseFunctionDef() {
    this.expect(TK.FUNCTION);
    const name = this.expect(TK.IDENT).value;
    let params = [];
    let typeParams = [];
    let returnType = null;

    // Optional type parameters: f{T}(...)
    if (this.peekKind() === TK.LBRACE) {
      typeParams = this.parseTypeParams();
    }

    if (this.peekKind() === TK.LPAREN) {
      params = this.parseParamList();
    }

    // Optional where clause
    if (this.peekKind() === TK.WHERE) {
      this.advance();
      // Parse where type constraints — skip for now, just consume
      this.parseWhereClause();
    }

    // Optional return type: function f(x)::Int32
    if (this.peekKind() === TK.COLONCOLON) {
      this.advance();
      returnType = this.parseTypeExpr();
    }

    const body = this.parseStatements(new Set([TK.END]));
    this.expect(TK.END);

    const fn = mkFunctionDef(name, params, returnType, body, false);
    fn.typeParams = typeParams;
    return fn;
  }

  parseParamList() {
    this.expect(TK.LPAREN);
    const params = [];
    while (this.peekKind() !== TK.RPAREN && this.peekKind() !== TK.EOF) {
      params.push(this.parseParam());
      if (!this.match(TK.COMMA)) break;
    }
    this.expect(TK.RPAREN);
    return params;
  }

  parseParam() {
    let name = null;
    let type = null;
    let defaultVal = null;

    // Handle both `x` and `x::T` and `x::T = default`
    if (this.peekKind() === TK.IDENT) {
      name = this.advance().value;
    } else if (this.peekKind() === TK.COLONCOLON) {
      // ::T (anonymous typed param)
      name = '_';
    }

    if (this.peekKind() === TK.COLONCOLON) {
      this.advance();
      type = this.parseTypeExpr();
    }

    if (this.peekKind() === TK.ASSIGN) {
      this.advance();
      defaultVal = this.parseExpr();
    }

    return mkParam(name, type, defaultVal);
  }

  parseTypeExpr() {
    // Parse type expression: T, T{P}, Union{A,B}, Tuple{A,B}
    let type;

    if (this.peekKind() === TK.IDENT) {
      const name = this.advance().value;
      if (this.peekKind() === TK.LBRACE) {
        const params = this.parseTypeParams();
        type = mkTypeApply(name, params);
      } else {
        type = mkIdentifier(name);
      }
    } else {
      // Fallback: parse as expression
      type = this.parseUnary();
    }

    return type;
  }

  parseTypeParams() {
    this.expect(TK.LBRACE);
    const params = [];
    while (this.peekKind() !== TK.RBRACE && this.peekKind() !== TK.EOF) {
      params.push(this.parseTypeExpr());
      if (!this.match(TK.COMMA)) break;
    }
    this.expect(TK.RBRACE);
    return params;
  }

  parseWhereClause() {
    // Simplified: just consume type constraints like `where {T<:Number, S}`
    if (this.peekKind() === TK.LBRACE) {
      this.advance();
      while (this.peekKind() !== TK.RBRACE && this.peekKind() !== TK.EOF) {
        this.advance();
      }
      this.match(TK.RBRACE);
    } else {
      // Single constraint: where T<:Number
      this.parseTypeExpr();
      if (this.peekKind() === TK.SUBTYPE) {
        this.advance();
        this.parseTypeExpr();
      }
    }
  }

  parseStructDef(isMutable) {
    this.expect(TK.STRUCT);
    const name = this.expect(TK.IDENT).value;
    let supertype = null;
    let typeParams = [];

    // Type parameters: struct Point{T}
    if (this.peekKind() === TK.LBRACE) {
      typeParams = this.parseTypeParams();
    }

    // Supertype: struct Circle <: Shape
    if (this.peekKind() === TK.SUBTYPE) {
      this.advance();
      supertype = this.parseTypeExpr();
    }

    // Fields
    const fields = [];
    this.skipSemicolons();
    while (this.peekKind() !== TK.END && this.peekKind() !== TK.EOF) {
      const fieldName = this.expect(TK.IDENT).value;
      let fieldType = null;
      if (this.peekKind() === TK.COLONCOLON) {
        this.advance();
        fieldType = this.parseTypeExpr();
      }
      fields.push(mkField(fieldName, fieldType));
      this.skipSemicolons();
    }
    this.expect(TK.END);
    return mkStructDef(name, isMutable, supertype, typeParams, fields);
  }

  parseMutableStruct() {
    this.expect(TK.MUTABLE);
    return this.parseStructDef(true);
  }

  parseAbstractType() {
    this.expect(TK.ABSTRACT);
    this.expect(TK.TYPE);
    const name = this.expect(TK.IDENT).value;
    let supertype = null;
    let params = [];

    if (this.peekKind() === TK.LBRACE) {
      params = this.parseTypeParams();
    }

    if (this.peekKind() === TK.SUBTYPE) {
      this.advance();
      supertype = this.parseTypeExpr();
    }

    this.expect(TK.END);
    return mkAbstractTypeDef(name, supertype, params);
  }

  parseIf() {
    this.expect(TK.IF);
    const condition = this.parseExpr();
    const then_ = this.parseStatements(new Set([TK.ELSEIF, TK.ELSE, TK.END]));
    const elseifs = [];
    let else_ = [];

    while (this.peekKind() === TK.ELSEIF) {
      this.advance();
      const eifCond = this.parseExpr();
      const eifBody = this.parseStatements(new Set([TK.ELSEIF, TK.ELSE, TK.END]));
      elseifs.push({ condition: eifCond, body: eifBody });
    }

    if (this.peekKind() === TK.ELSE) {
      this.advance();
      else_ = this.parseStatements(new Set([TK.END]));
    }

    this.expect(TK.END);
    return mkIf(condition, then_, elseifs, else_);
  }

  parseWhile() {
    this.expect(TK.WHILE);
    const condition = this.parseExpr();
    const body = this.parseStatements(new Set([TK.END]));
    this.expect(TK.END);
    return mkWhile(condition, body);
  }

  parseFor() {
    this.expect(TK.FOR);
    const varName = this.expect(TK.IDENT).value;

    // `in` or `=` or `∈`
    if (this.peekKind() === TK.IN || this.peekKind() === TK.ASSIGN) {
      this.advance();
    } else {
      this.expect(TK.IN);
    }

    const iter = this.parseExpr();
    const body = this.parseStatements(new Set([TK.END]));
    this.expect(TK.END);
    return mkFor(varName, iter, body);
  }

  parseTryCatch() {
    this.expect(TK.TRY);
    const tryBody = this.parseStatements(new Set([TK.CATCH, TK.FINALLY, TK.END]));
    let catchVar = null;
    let catchBody = [];
    let finallyBody = [];

    if (this.peekKind() === TK.CATCH) {
      this.advance();
      // Optional catch variable
      if (this.peekKind() === TK.IDENT && !this.peek().newlineBefore) {
        catchVar = this.advance().value;
      }
      catchBody = this.parseStatements(new Set([TK.FINALLY, TK.END]));
    }

    if (this.peekKind() === TK.FINALLY) {
      this.advance();
      finallyBody = this.parseStatements(new Set([TK.END]));
    }

    this.expect(TK.END);
    return mkTryCatch(tryBody, catchVar, catchBody, finallyBody);
  }

  parseReturn() {
    this.advance(); // skip 'return'
    // Return with no value (at end of line or before end/else/etc.)
    if (this.isStatementSeparator() || isBlockCloser(this.peekKind())) {
      return mkReturn(null);
    }
    return mkReturn(this.parseExpr());
  }

  parseThrow() {
    this.advance(); // skip 'throw'
    return mkThrow(this.parseExpr());
  }

  parseBeginBlock() {
    this.advance(); // skip 'begin'
    const stmts = this.parseStatements(new Set([TK.END]));
    this.expect(TK.END);
    return mkBlock(stmts);
  }

  parseLetBlock() {
    this.advance(); // skip 'let'
    // Simplified: let x = 1, y = 2; body; end
    const bindings = [];
    while (this.peekKind() !== TK.EOF) {
      if (this.peek().newlineBefore) break;
      if (this.peekKind() === TK.SEMICOLON) { this.advance(); break; }
      const name = this.expect(TK.IDENT).value;
      let value = null;
      if (this.peekKind() === TK.ASSIGN) {
        this.advance();
        value = this.parseExpr();
      }
      bindings.push({ name, value });
      if (!this.match(TK.COMMA)) break;
    }
    const body = this.parseStatements(new Set([TK.END]));
    this.expect(TK.END);
    return { kind: 'Let', bindings, body };
  }

  parseLocal() {
    this.advance(); // skip 'local'
    const names = [];
    while (this.peekKind() === TK.IDENT) {
      names.push(this.advance().value);
      if (!this.match(TK.COMMA)) break;
    }
    return mkLocal(names);
  }

  parseGlobal() {
    this.advance(); // skip 'global'
    const names = [];
    while (this.peekKind() === TK.IDENT) {
      names.push(this.advance().value);
      if (!this.match(TK.COMMA)) break;
    }
    return { kind: 'Global', names };
  }

  parseConst() {
    this.advance(); // skip 'const'
    const name = this.expect(TK.IDENT).value;
    this.expect(TK.ASSIGN);
    const value = this.parseExpr();
    return mkConst(name, value);
  }

  parseMacroCall() {
    this.advance(); // skip @
    const name = this.expect(TK.IDENT).value;
    // Parse macro arguments until newline or semicolon
    const args = [];
    while (!this.isStatementSeparator() && !isBlockCloser(this.peekKind())) {
      args.push(this.parseExpr());
      if (this.peekKind() === TK.COMMA) this.advance();
      else break;
    }
    return mkMacroCall(name, args);
  }

  // --- Expression statement or short-form function ---

  parseExpressionStatement() {
    const expr = this.parseExpr();

    // Check for short-form function: f(x) = expr
    if (this.peekKind() === TK.ASSIGN && expr.kind === 'Call' && expr.func.kind === 'Identifier') {
      this.advance(); // skip =
      const body = this.parseExpr();
      const params = expr.args.map(arg => {
        if (arg.kind === 'Identifier') return mkParam(arg.name, null, null);
        if (arg.kind === 'TypeAnnotation') {
          const name = arg.expr.kind === 'Identifier' ? arg.expr.name : '_';
          return mkParam(name, arg.type, null);
        }
        return mkParam('_', null, null);
      });
      return mkFunctionDef(expr.func.name, params, null, [mkReturn(body)], true);
    }

    // Check for assignment: x = expr, x += expr, etc.
    const assignOps = new Set([TK.ASSIGN, TK.PLUSEQ, TK.MINUSEQ, TK.STAREQ, TK.SLASHEQ, TK.CARETEQ, TK.AMPEQ, TK.PIPEEQ]);
    if (assignOps.has(this.peekKind())) {
      const op = this.advance().kind;
      const value = this.parseExpr();
      return mkAssignment(expr, op, value);
    }

    return expr;
  }

  // --- Expression parsing (precedence climbing) ---

  parseExpr() {
    return this.parseTernary();
  }

  parseTernary() {
    let expr = this.parseOr();

    if (this.peekKind() === TK.QUESTION) {
      this.advance();
      const then_ = this.parseExpr();
      this.expect(TK.COLON);
      const else_ = this.parseExpr();
      return mkTernary(expr, then_, else_);
    }

    return expr;
  }

  parseOr() {
    let left = this.parseAnd();
    while (this.peekKind() === TK.OROR) {
      this.advance();
      const right = this.parseAnd();
      left = mkOr(left, right);
    }
    return left;
  }

  parseAnd() {
    let left = this.parseArrow();
    while (this.peekKind() === TK.ANDAND) {
      this.advance();
      const right = this.parseArrow();
      left = mkAnd(left, right);
    }
    return left;
  }

  parseArrow() {
    let left = this.parseComparison();
    if (this.peekKind() === TK.ARROW) {
      this.advance();
      const body = this.parseExpr(); // right-associative
      // `left -> body` is a lambda
      const params = [];
      if (left.kind === 'Identifier') {
        params.push(mkParam(left.name, null, null));
      } else if (left.kind === 'Tuple') {
        for (const el of left.elements) {
          if (el.kind === 'Identifier') params.push(mkParam(el.name, null, null));
          else if (el.kind === 'TypeAnnotation') {
            const n = el.expr.kind === 'Identifier' ? el.expr.name : '_';
            params.push(mkParam(n, el.type, null));
          }
          else params.push(mkParam('_', null, null));
        }
      } else if (left.kind === 'TypeAnnotation' && left.expr.kind === 'Identifier') {
        params.push(mkParam(left.expr.name, left.type, null));
      }
      return mkLambda(params, body);
    }
    return left;
  }

  parseComparison() {
    let left = this.parsePipe();

    const compOps = new Set([TK.LT, TK.GT, TK.LE, TK.GE, TK.EQ, TK.NEQ, TK.EQEQEQ, TK.NEQEQ, TK.ISA, TK.IN, TK.SUBTYPE, TK.SUPERTYPE]);
    if (compOps.has(this.peekKind())) {
      const ops = [];
      const operands = [left];
      while (compOps.has(this.peekKind())) {
        ops.push(this.advance().kind);
        operands.push(this.parsePipe());
      }
      if (ops.length === 1) {
        return mkBinaryOp(ops[0], operands[0], operands[1]);
      }
      return mkComparison(ops, operands);
    }
    return left;
  }

  parsePipe() {
    let left = this.parseRange();
    while (this.peekKind() === TK.PIPE_RIGHT) {
      this.advance();
      const right = this.parseRange();
      left = mkCall(right, [left]);
    }
    return left;
  }

  parseRange() {
    let start = this.parseAddition();

    if (this.peekKind() === TK.COLON) {
      this.advance();
      let second = this.parseAddition();

      if (this.peekKind() === TK.COLON) {
        this.advance();
        let third = this.parseAddition();
        // start:step:stop
        return mkRange(start, second, third);
      }
      // start:stop
      return mkRange(start, null, second);
    }

    return start;
  }

  parseAddition() {
    let left = this.parseMultiplication();
    while (isAdditiveOp(this.peekKind())) {
      const op = this.advance().kind;
      const right = this.parseMultiplication();
      left = mkBinaryOp(op, left, right);
    }
    return left;
  }

  parseMultiplication() {
    let left = this.parseBitshift();
    while (isMultiplicativeOp(this.peekKind())) {
      const op = this.advance().kind;
      const right = this.parseBitshift();
      left = mkBinaryOp(op, left, right);
    }
    return left;
  }

  parseBitshift() {
    let left = this.parsePower();
    while (this.peekKind() === TK.LSHIFT || this.peekKind() === TK.RSHIFT || this.peekKind() === TK.URSHIFT) {
      const op = this.advance().kind;
      const right = this.parsePower();
      left = mkBinaryOp(op, left, right);
    }
    return left;
  }

  parsePower() {
    let base = this.parseUnary();
    if (this.peekKind() === TK.CARET || this.peekKind() === TK.DOTCARET) {
      const op = this.advance().kind;
      const exp = this.parsePower(); // right-associative
      return mkBinaryOp(op, base, exp);
    }
    return base;
  }

  parseUnary() {
    const kind = this.peekKind();
    if (kind === TK.MINUS || kind === TK.PLUS || kind === TK.BANG || kind === TK.TILDE) {
      const op = this.advance().kind;
      const operand = this.parseUnary();
      // Fold unary minus on literals
      if (op === TK.MINUS && operand.kind === 'Integer') {
        return mkInteger(-operand.value);
      }
      if (op === TK.MINUS && operand.kind === 'Float') {
        return mkFloat(-operand.value);
      }
      if (op === TK.PLUS && (operand.kind === 'Integer' || operand.kind === 'Float')) {
        return operand;
      }
      return mkUnaryOp(op, operand);
    }
    return this.parsePostfix();
  }

  parsePostfix() {
    let expr = this.parseAtom();

    while (true) {
      const kind = this.peekKind();

      // Function call: f(args...)
      if (kind === TK.LPAREN && !this.peek().newlineBefore) {
        this.advance();
        const args = [];
        while (this.peekKind() !== TK.RPAREN && this.peekKind() !== TK.EOF) {
          let arg = this.parseExpr();
          // Check for splat
          if (this.peekKind() === TK.ELLIPSIS) {
            this.advance();
            arg = mkSplat(arg);
          }
          // Check for keyword argument: name = value
          if (this.peekKind() === TK.ASSIGN && arg.kind === 'Identifier') {
            this.advance();
            const val = this.parseExpr();
            arg = mkKwArg(arg.name, val);
          }
          args.push(arg);
          if (!this.match(TK.COMMA)) break;
        }
        this.expect(TK.RPAREN);

        // do block: f(args...) do x ... end
        if (this.peekKind() === TK.DO) {
          this.advance();
          let doParams = [];
          if (this.peekKind() === TK.IDENT) {
            doParams.push(mkParam(this.advance().value, null, null));
            while (this.match(TK.COMMA)) {
              doParams.push(mkParam(this.expect(TK.IDENT).value, null, null));
            }
          }
          const doBody = this.parseStatements(new Set([TK.END]));
          this.expect(TK.END);
          args.unshift(mkLambda(doParams, doBody.length === 1 ? doBody[0] : mkBlock(doBody)));
        }

        expr = mkCall(expr, args);
        continue;
      }

      // Indexing: a[i]
      if (kind === TK.LBRACKET && !this.peek().newlineBefore) {
        this.advance();
        const indices = [];
        while (this.peekKind() !== TK.RBRACKET && this.peekKind() !== TK.EOF) {
          indices.push(this.parseExpr());
          if (!this.match(TK.COMMA)) break;
        }
        this.expect(TK.RBRACKET);
        expr = mkIndex(expr, indices);
        continue;
      }

      // Type parameters: T{P} (only when no space before)
      if (kind === TK.LBRACE && !this.peek().newlineBefore) {
        const params = this.parseTypeParams();
        expr = mkTypeApply(expr.kind === 'Identifier' ? expr.name : '?', params);
        continue;
      }

      // Field access: a.b
      if (kind === TK.DOT) {
        this.advance();
        if (this.peekKind() === TK.IDENT) {
          const field = this.advance().value;
          expr = mkDotAccess(expr, field);
        } else if (this.peekKind() === TK.LPAREN) {
          // Broadcasting: f.(args)
          this.advance();
          const args = [];
          while (this.peekKind() !== TK.RPAREN && this.peekKind() !== TK.EOF) {
            args.push(this.parseExpr());
            if (!this.match(TK.COMMA)) break;
          }
          this.expect(TK.RPAREN);
          expr = mkDotCall(expr, args);
        } else {
          this.error('Expected field name after .');
        }
        continue;
      }

      // Type annotation: expr::T
      if (kind === TK.COLONCOLON) {
        this.advance();
        const type = this.parseTypeExpr();
        expr = mkTypedExpr(expr, type);
        continue;
      }

      // Adjoint: x' (transpose)
      if (kind === TK.IDENT && this.peek().value === "'" && !this.peek().newlineBefore) {
        // Not implemented for now
        break;
      }

      break;
    }

    return expr;
  }

  parseAtom() {
    const tok = this.peek();

    switch (tok.kind) {
      case TK.INTEGER: {
        this.advance();
        return mkInteger(tok.value);
      }
      case TK.FLOAT: {
        this.advance();
        return mkFloat(tok.value);
      }
      case TK.STRING: {
        this.advance();
        if (Array.isArray(tok.value)) {
          // Interpolated string
          const parts = tok.value.map(part => {
            if (part.kind === 'literal') return mkStringLit(part.value);
            if (part.kind === 'name') return mkIdentifier(part.value);
            if (part.kind === 'expr') {
              // Re-parse the interpolated tokens
              const subParser = new SubParser(part.tokens);
              return subParser.parseExpr();
            }
            return mkStringLit('');
          });
          return mkStringInterp(parts);
        }
        return mkStringLit(tok.value);
      }
      case TK.CHAR: {
        this.advance();
        return mkCharLit(tok.value);
      }
      case TK.TRUE: {
        this.advance();
        return mkBool(true);
      }
      case TK.FALSE: {
        this.advance();
        return mkBool(false);
      }
      case TK.NOTHING: {
        this.advance();
        return mkNothing();
      }
      case TK.MISSING: {
        this.advance();
        return mkMissing();
      }
      case TK.IDENT: {
        this.advance();
        return mkIdentifier(tok.value);
      }
      case TK.LPAREN: {
        return this.parseParenExpr();
      }
      case TK.LBRACKET: {
        return this.parseArrayExpr();
      }
      case TK.COLON: {
        // Symbol literal :name
        this.advance();
        if (this.peekKind() === TK.IDENT) {
          const name = this.advance().value;
          return { kind: 'Symbol', name };
        }
        // Bare colon (used as range: 1:end)
        return mkIdentifier(':');
      }
      case TK.END: {
        // `end` as expression (inside indexing: a[end])
        this.advance();
        return mkIdentifier('end');
      }
      default: {
        this.error(`Unexpected token: ${tok.kind} (${JSON.stringify(tok.value)})`);
        this.advance(); // skip to avoid infinite loop
        return mkIdentifier('__error__');
      }
    }
  }

  parseParenExpr() {
    this.expect(TK.LPAREN);

    // Empty tuple
    if (this.peekKind() === TK.RPAREN) {
      this.advance();
      return mkTuple([]);
    }

    const first = this.parseExpr();

    // Tuple: (a, b, c)
    if (this.peekKind() === TK.COMMA) {
      const elements = [first];
      while (this.match(TK.COMMA)) {
        if (this.peekKind() === TK.RPAREN) break; // trailing comma
        elements.push(this.parseExpr());
      }
      this.expect(TK.RPAREN);
      return mkTuple(elements);
    }

    this.expect(TK.RPAREN);
    return first; // parenthesized expression
  }

  parseArrayExpr() {
    this.expect(TK.LBRACKET);

    // Empty array
    if (this.peekKind() === TK.RBRACKET) {
      this.advance();
      return mkArrayLit([]);
    }

    const first = this.parseExpr();

    // Check for comprehension: [expr for x in iter]
    if (this.peekKind() === TK.FOR) {
      const generators = this.parseGenerators();
      this.expect(TK.RBRACKET);
      return mkComprehension(first, generators);
    }

    // Array literal: [a, b, c]
    const elements = [first];
    while (this.match(TK.COMMA)) {
      if (this.peekKind() === TK.RBRACKET) break; // trailing comma
      elements.push(this.parseExpr());
    }

    // Check for semicolon-separated (vertical concatenation) — treat as array
    while (this.match(TK.SEMICOLON)) {
      if (this.peekKind() === TK.RBRACKET) break;
      elements.push(this.parseExpr());
    }

    this.expect(TK.RBRACKET);
    return mkArrayLit(elements);
  }

  parseGenerators() {
    const generators = [];
    while (this.peekKind() === TK.FOR) {
      this.advance();
      const varName = this.expect(TK.IDENT).value;
      if (this.peekKind() === TK.IN || this.peekKind() === TK.ASSIGN) {
        this.advance();
      }
      const iter = this.parseExpr();
      generators.push({ var: varName, iter });
    }
    // Optional if filter
    if (this.peekKind() === TK.IF) {
      this.advance();
      const filter = this.parseExpr();
      if (generators.length > 0) {
        generators[generators.length - 1].filter = filter;
      }
    }
    return generators;
  }
}

// ============================================================================
// SubParser — for re-parsing interpolated expression tokens
// ============================================================================

class SubParser extends Parser {
  constructor(tokens) {
    // Bypass Tokenizer by providing pre-tokenized input
    super(''); // empty source
    this.tokens = [...tokens, new Token(TK.EOF, '', 0, 0)];
    this.tokens.forEach(t => { if (t.newlineBefore === undefined) t.newlineBefore = false; });
    this.pos = 0;
  }

  // Override _tokenize to do nothing (tokens already provided)
  _tokenize() {}
}

// ============================================================================
// Operator classification helpers
// ============================================================================

function isAdditiveOp(kind) {
  return kind === TK.PLUS || kind === TK.MINUS || kind === TK.PIPE ||
         kind === TK.DOTPLUS || kind === TK.DOTMINUS;
}

function isMultiplicativeOp(kind) {
  return kind === TK.STAR || kind === TK.SLASH || kind === TK.PERCENT ||
         kind === TK.AMPERSAND || kind === TK.BACKSLASH ||
         kind === TK.DOTSTAR || kind === TK.DOTSLASH;
}

function isBlockCloser(kind) {
  return kind === TK.END || kind === TK.ELSE || kind === TK.ELSEIF ||
         kind === TK.CATCH || kind === TK.FINALLY || kind === TK.EOF;
}

// ============================================================================
// Public API
// ============================================================================

/**
 * Parse a Julia source string into an AST.
 * @param {string} source — Julia source code
 * @returns {{ ast: object, diagnostics: Array }} — AST root node and any parse errors
 */
function parse(source) {
  const parser = new Parser(source);
  const ast = parser.parseModule();
  return { ast, diagnostics: parser.diagnostics };
}

/**
 * Parse a single Julia expression.
 * @param {string} source — Julia expression
 * @returns {{ ast: object, diagnostics: Array }}
 */
function parseExpr(source) {
  const parser = new Parser(source);
  const ast = parser.parseExpr();
  return { ast, diagnostics: parser.diagnostics };
}

/**
 * Tokenize a Julia source string.
 * @param {string} source — Julia source code
 * @returns {Array<{kind: string, value: *, start: number, end: number}>}
 */
function tokenize(source) {
  const tokenizer = new Tokenizer(source);
  return tokenizer.tokenizeAll();
}

// ============================================================================
// Exports
// ============================================================================

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { parse, parseExpr, tokenize, TK };
}
if (typeof globalThis !== 'undefined') {
  globalThis.JuliaParser = { parse, parseExpr, tokenize, TK };
}
