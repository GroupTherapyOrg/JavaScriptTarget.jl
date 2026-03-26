// codegen.js — Julia SSA IR → JavaScript code generator for browser playground
// Takes IR from lowerer.js + type info from infer.js → executable JavaScript.
//
// Architecture:
//   1. Structure hint analysis: identify if/while/for/try regions from lowerer
//   2. SSA walking: emit JS for each statement, using structure hints for control flow
//   3. Type-directed emission: integer coercion (| 0), Math.imul, etc.
//
// Input: lowerer.js IR (functions, structDefs) + infer.js type tables (optional)
// Output: JavaScript string ready for eval()
//
// Selfhost spec §5 — the browser-side codegen.

'use strict';

// ============================================================
// Statement Kinds — must match lowerer.js / infer.js
// ============================================================

var STMT_CALL      = 1;
var STMT_PHI       = 2;
var STMT_GETFIELD  = 3;
var STMT_NEW       = 4;
var STMT_LITERAL   = 5;
var STMT_RETURN    = 6;
var STMT_GOTO      = 7;
var STMT_GOTOIFNOT = 8;
var STMT_PINODE    = 9;

// ============================================================
// Type IDs — must match lowerer.js / infer.js / type_registry.jl
// ============================================================

var TYPE_ANY      = 0;
var TYPE_BOTTOM   = 1;
var TYPE_NOTHING  = 2;
var TYPE_MISSING  = 3;
var TYPE_BOOL     = 4;
var TYPE_INT8     = 5;
var TYPE_INT16    = 6;
var TYPE_INT32    = 7;
var TYPE_INT64    = 8;
var TYPE_INT128   = 9;
var TYPE_UINT8    = 10;
var TYPE_UINT16   = 11;
var TYPE_UINT32   = 12;
var TYPE_UINT64   = 13;
var TYPE_UINT128  = 14;
var TYPE_FLOAT16  = 15;
var TYPE_FLOAT32  = 16;
var TYPE_FLOAT64  = 17;
var TYPE_CHAR     = 18;
var TYPE_STRING   = 19;
var TYPE_SYMBOL   = 20;

var USER_TYPE_BASE = 100;

// ============================================================
// Type Helpers
// ============================================================

function isIntType(t) {
  return (t >= TYPE_INT8 && t <= TYPE_INT128) || (t >= TYPE_UINT8 && t <= TYPE_UINT128);
}

function isFloatType(t) {
  return t >= TYPE_FLOAT16 && t <= TYPE_FLOAT64;
}

function isNumericType(t) {
  return isIntType(t) || isFloatType(t);
}

function isStringType(t) {
  return t === TYPE_STRING;
}

// Type name → TypeID mapping (for paramTypes from lowerer)
var TYPE_NAME_MAP = {
  'Any': TYPE_ANY, 'Nothing': TYPE_NOTHING, 'Missing': TYPE_MISSING,
  'Bool': TYPE_BOOL,
  'Int8': TYPE_INT8, 'Int16': TYPE_INT16, 'Int32': TYPE_INT32,
  'Int64': TYPE_INT64, 'Int128': TYPE_INT128, 'Int': TYPE_INT64,
  'UInt8': TYPE_UINT8, 'UInt16': TYPE_UINT16, 'UInt32': TYPE_UINT32,
  'UInt64': TYPE_UINT64, 'UInt128': TYPE_UINT128,
  'Float16': TYPE_FLOAT16, 'Float32': TYPE_FLOAT32,
  'Float64': TYPE_FLOAT64, 'Float': TYPE_FLOAT64,
  'Char': TYPE_CHAR, 'String': TYPE_STRING, 'Symbol': TYPE_SYMBOL,
};

/** Sanitize Julia names for JS identifiers. */
function sanitizeName(name) {
  if (!name) return '_';
  return name.replace(/!/g, '_b').replace(/#/g, '_').replace(/[^a-zA-Z0-9_$]/g, '_');
}

// ============================================================
// Runtime Helpers (inline JS source strings, tree-shakeable)
// ============================================================

var RUNTIME = {};

RUNTIME.jl_println = 'function jl_println() {\n' +
  '  var a = []; for (var i = 0; i < arguments.length; i++) {\n' +
  '    var v = arguments[i]; a.push(v === null ? "nothing" : v === undefined ? "missing" : String(v));\n' +
  '  }\n  console.log(a.join(""));\n}';

RUNTIME.jl_print = 'function jl_print() {\n' +
  '  var a = []; for (var i = 0; i < arguments.length; i++) {\n' +
  '    var v = arguments[i]; a.push(v === null ? "nothing" : v === undefined ? "missing" : String(v));\n' +
  '  }\n  var s = a.join("");\n' +
  '  if (typeof process !== "undefined" && process.stdout) process.stdout.write(s);\n' +
  '  else console.log(s);\n}';

RUNTIME.jl_string = 'function jl_string() {\n' +
  '  var s = ""; for (var i = 0; i < arguments.length; i++) {\n' +
  '    var v = arguments[i]; s += (v === null ? "nothing" : v === undefined ? "missing" : String(v));\n' +
  '  }\n  return s;\n}';

RUNTIME.jl_egal = 'function jl_egal(a, b) {\n' +
  '  if (a === b) return true;\n' +
  '  if (a === null || b === null) return false;\n' +
  '  if (typeof a !== "object" || typeof b !== "object") return false;\n' +
  '  var ka = Object.keys(a), kb = Object.keys(b);\n' +
  '  if (ka.length !== kb.length) return false;\n' +
  '  for (var i = 0; i < ka.length; i++) { if (!jl_egal(a[ka[i]], b[ka[i]])) return false; }\n' +
  '  return true;\n}';

RUNTIME.JlError = 'function JlError(msg) {\n' +
  '  this.message = String(msg); this.name = "JlError";\n' +
  '}\nJlError.prototype = Object.create(Error.prototype);\n' +
  'JlError.prototype.constructor = JlError;';

RUNTIME.jl_div = 'function jl_div(a, b) { return (a / b) | 0; }';
RUNTIME.jl_fld = 'function jl_fld(a, b) { return Math.floor(a / b); }';
RUNTIME.jl_mod = 'function jl_mod(a, b) { return a - jl_fld(a, b) * b; }';
RUNTIME.jl_cld = 'function jl_cld(a, b) { return Math.ceil(a / b) | 0; }';

var RUNTIME_DEPS = {
  jl_mod: ['jl_fld'],
};

// ============================================================
// CodegenContext — holds state for generating one function
// ============================================================

/**
 * @param {Object} func - IR function from lowerer.js
 * @param {Array} ssaTypes - Type per SSA slot (from infer.js), may be empty
 * @param {Array} argTypes - TypeID per argument
 * @param {Object} structDefs - Struct definitions from lowerer
 * @param {Object} allFunctions - All functions in the module (for cross-calls)
 */
function CodegenContext(func, ssaTypes, argTypes, structDefs, allFunctions) {
  this.code = func.code || [];
  this.structure = func.structure || [];
  this.ssaTypes = ssaTypes || [];
  this.argTypes = argTypes || [];
  this.argNames = func.argNames || [];
  this.names = func.names || {};
  this.structDefs = structDefs || {};
  this.allFunctions = allFunctions || {};

  // Output
  this.lines = [];
  this.indent = 1;

  // SSA index → JS variable name
  this.ssaVars = {};
  this.varCounter = 0;
  this.declaredVars = {};

  // Reserve argument names so phi variables don't shadow them
  for (var ai = 0; ai < this.argNames.length; ai++) {
    this.declaredVars[this.argNames[ai]] = true;
  }

  // Runtime helper tracking
  this.requiredRuntime = {};

  // Loop stack for break/continue detection
  this.loopStack = [];

  // Build structure hint index: entry position → hint
  this.structIndex = {};
  for (var i = 0; i < this.structure.length; i++) {
    var h = this.structure[i];
    var entry;
    if (h.kind === 'if') entry = h.condIdx;
    else if (h.kind === 'while' || h.kind === 'for') entry = h.headerIdx;
    else if (h.kind === 'try') entry = h.tryStart;
    else continue;
    this.structIndex[entry] = h;
  }
}

/** Emit an indented line of JS code. */
CodegenContext.prototype.line = function(text) {
  var prefix = '';
  for (var i = 0; i < this.indent; i++) prefix += '  ';
  this.lines.push(prefix + text);
};

/** Track a runtime helper as needed. Resolves dependencies. */
CodegenContext.prototype.requireRuntime = function(name) {
  if (this.requiredRuntime[name]) return;
  this.requiredRuntime[name] = true;
  var deps = RUNTIME_DEPS[name];
  if (deps) {
    for (var i = 0; i < deps.length; i++) this.requireRuntime(deps[i]);
  }
};

/** Allocate a fresh unique JS variable name. */
CodegenContext.prototype.freshVar = function(hint) {
  var name;
  if (hint) {
    name = sanitizeName(hint);
    if (!this.declaredVars[name]) {
      this.declaredVars[name] = true;
      return name;
    }
  }
  do {
    name = '_v' + this.varCounter++;
  } while (this.declaredVars[name]);
  this.declaredVars[name] = true;
  return name;
};

/** Ensure SSA slot idx has a JS variable name. */
CodegenContext.prototype.ensureVar = function(idx) {
  if (this.ssaVars[idx]) return this.ssaVars[idx];
  var hint = this.names[idx];
  var name = this.freshVar(hint);
  this.ssaVars[idx] = name;
  return name;
};

// ============================================================
// Ref and Type Resolution
// ============================================================

/** Resolve an SSA ref's inferred type. */
CodegenContext.prototype.resolveType = function(ref) {
  if (!ref) return TYPE_NOTHING;
  if ('ssa' in ref) {
    var t = this.ssaTypes[ref.ssa];
    if (Array.isArray(t)) return TYPE_ANY; // Union → treat as Any
    return (t !== undefined && t !== null && t !== -1) ? t : TYPE_ANY;
  }
  if ('arg' in ref) return this.argTypes[ref.arg] || TYPE_ANY;
  if ('lit' in ref) return ref.lit;
  return TYPE_ANY;
};

/** Resolve an SSA ref to a JS expression string. */
CodegenContext.prototype.ref = function(r) {
  if (!r) return 'null';

  if ('ssa' in r) {
    // Already has a variable?
    if (this.ssaVars[r.ssa]) return this.ssaVars[r.ssa];

    // Inline literals and pi nodes
    var stmt = this.code[r.ssa];
    if (stmt) {
      if (stmt.kind === STMT_LITERAL) return this.literalExpr(stmt);
      if (stmt.kind === STMT_PINODE) return this.ref(stmt.val);
    }

    // Needs a variable (will be assigned when emitStatement runs)
    return this.ensureVar(r.ssa);
  }

  if ('arg' in r) {
    return this.argNames[r.arg] || ('_arg' + r.arg);
  }

  if ('lit' in r) {
    // Lit refs carry type info, not values — used for isa checks etc.
    return 'null';
  }

  return 'null';
};

/** Convert a STMT_LITERAL to its JS expression string. */
CodegenContext.prototype.literalExpr = function(stmt) {
  if (stmt._isFunction) return sanitizeName(stmt.value);
  if (stmt._isCatchVar) return '_err';

  var v = stmt.value;
  if (v === null || v === undefined) {
    if (stmt.typeId === TYPE_NOTHING) return 'null';
    if (stmt.typeId === TYPE_MISSING) return 'undefined';
    return 'null';
  }

  switch (stmt.typeId) {
    case TYPE_BOOL: return v ? 'true' : 'false';
    case TYPE_NOTHING: return 'null';
    case TYPE_MISSING: return 'undefined';
    case TYPE_STRING: return JSON.stringify(String(v));
    case TYPE_CHAR: return JSON.stringify(String(v));
    case TYPE_SYMBOL: return JSON.stringify(String(v));
    default:
      if (typeof v === 'number') {
        if (v !== v) return 'NaN';
        if (v === Infinity) return 'Infinity';
        if (v === -Infinity) return '-Infinity';
        return String(v);
      }
      if (typeof v === 'string') return JSON.stringify(v);
      if (typeof v === 'boolean') return v ? 'true' : 'false';
      return String(v);
  }
};

// ============================================================
// Region Walking — the main code emission loop
// ============================================================

/**
 * Walk statements from `start` to `end` (exclusive), emitting JS.
 * Structure hints divert control flow to structured emission.
 */
CodegenContext.prototype.emitRegion = function(start, end) {
  var pos = start;
  while (pos < end && pos < this.code.length) {
    var hint = this.structIndex[pos];
    if (hint) {
      switch (hint.kind) {
        case 'if':
          this.emitIfStructure(hint);
          pos = hint.mergeIdx + 1;
          break;
        case 'while':
        case 'for':
          this.emitLoopStructure(hint);
          pos = hint.exitIdx;
          break;
        case 'try':
          this.emitTryStructure(hint);
          pos = hint.afterIdx;
          break;
        default:
          this.emitStatement(pos);
          pos++;
      }
    } else {
      this.emitStatement(pos);
      pos++;
    }
  }
};

// ============================================================
// Statement Emission
// ============================================================

CodegenContext.prototype.emitStatement = function(idx) {
  var stmt = this.code[idx];
  if (!stmt) return;

  switch (stmt.kind) {
    case STMT_CALL:
      this.emitCall(stmt, idx);
      break;

    case STMT_LITERAL:
      // Literals are inlined via ref(). Only emit var if it has a name hint.
      if (this.names[idx] && !stmt._isFunction && !stmt._isCatchVar) {
        var name = this.ensureVar(idx);
        this.line('var ' + name + ' = ' + this.literalExpr(stmt) + ';');
      }
      break;

    case STMT_RETURN:
      this.line('return ' + this.ref(stmt.val) + ';');
      break;

    case STMT_GETFIELD:
      this.emitGetfield(stmt, idx);
      break;

    case STMT_NEW:
      this.emitNew(stmt, idx);
      break;

    case STMT_PINODE:
      // Type narrowing — alias to the underlying value
      this.ssaVars[idx] = this.ref(stmt.val);
      break;

    case STMT_GOTO:
      // May be break or continue inside a loop
      if (this.loopStack.length > 0) {
        var loop = this.loopStack[this.loopStack.length - 1];
        if (stmt.dest >= loop.exitIdx) {
          this.line('break;');
        } else if (stmt.dest <= loop.headerIdx) {
          this.line('continue;');
        }
      }
      break;

    case STMT_GOTOIFNOT:
      // Handled by structure hints — skip
      break;

    case STMT_PHI:
      // Handled by control flow structures — skip
      break;
  }
};

// ============================================================
// Call Emission
// ============================================================

CodegenContext.prototype.emitCall = function(stmt, idx) {
  var callee = stmt.callee;
  var args = stmt.args || [];

  // --- Statement-level calls (emit as statements, set SSA to null) ---

  if (callee === 'error') {
    this.requireRuntime('JlError');
    var errMsg = args.length > 0 ? this.ref(args[0]) : '""';
    this.line('throw new JlError(' + errMsg + ');');
    this.ssaVars[idx] = 'null';
    return;
  }
  if (callee === 'throw') {
    this.line('throw ' + this.ref(args[0]) + ';');
    this.ssaVars[idx] = 'null';
    return;
  }
  if (callee === 'println') {
    this.requireRuntime('jl_println');
    var plArgs = [];
    for (var pi = 0; pi < args.length; pi++) plArgs.push(this.ref(args[pi]));
    this.line('jl_println(' + plArgs.join(', ') + ');');
    this.ssaVars[idx] = 'null';
    return;
  }
  if (callee === 'print') {
    this.requireRuntime('jl_print');
    var prArgs = [];
    for (var pri = 0; pri < args.length; pri++) prArgs.push(this.ref(args[pri]));
    this.line('jl_print(' + prArgs.join(', ') + ');');
    this.ssaVars[idx] = 'null';
    return;
  }
  if (callee === 'show') {
    this.requireRuntime('jl_println');
    this.line('jl_println(' + this.ref(args[0]) + ');');
    this.ssaVars[idx] = 'null';
    return;
  }
  if (callee === 'setindex!') {
    var si_c = this.ref(args[0]), si_v = this.ref(args[1]), si_k = this.ref(args[2]);
    var si_t = this.resolveType(args[0]);
    if (si_t >= USER_TYPE_BASE) {
      this.line(si_c + '.set(' + si_k + ', ' + si_v + ');');
    } else {
      this.line(si_c + '[' + si_k + ' - 1] = ' + si_v + ';');
    }
    this.ssaVars[idx] = si_c;
    return;
  }
  if (callee === 'setfield!') {
    var sf_obj = this.ref(args[0]);
    var sf_field = 'unknown';
    if (args.length > 1 && 'ssa' in args[1]) {
      var sf_stmt = this.code[args[1].ssa];
      if (sf_stmt && sf_stmt.kind === STMT_LITERAL) sf_field = String(sf_stmt.value);
    }
    var sf_val = args.length > 2 ? this.ref(args[2]) : 'undefined';
    this.line(sf_obj + '.' + sanitizeName(sf_field) + ' = ' + sf_val + ';');
    this.ssaVars[idx] = sf_obj;
    return;
  }
  if (callee === 'push!') {
    this.line(this.ref(args[0]) + '.push(' + this.ref(args[1]) + ');');
    this.ssaVars[idx] = this.ref(args[0]);
    return;
  }
  if (callee === 'append!') {
    this.line(this.ref(args[0]) + '.push.apply(' + this.ref(args[0]) + ', ' + this.ref(args[1]) + ');');
    this.ssaVars[idx] = this.ref(args[0]);
    return;
  }
  if (callee === 'empty!') {
    this.line(this.ref(args[0]) + '.length = 0;');
    this.ssaVars[idx] = this.ref(args[0]);
    return;
  }
  if (callee === 'sort!') {
    this.line(this.ref(args[0]) + '.sort(function(x, y) { return x - y; });');
    this.ssaVars[idx] = this.ref(args[0]);
    return;
  }
  if (callee === 'reverse!') {
    this.line(this.ref(args[0]) + '.reverse();');
    this.ssaVars[idx] = this.ref(args[0]);
    return;
  }
  if (callee === 'delete!') {
    this.line(this.ref(args[0]) + '.delete(' + this.ref(args[1]) + ');');
    this.ssaVars[idx] = this.ref(args[0]);
    return;
  }

  // --- Expression-level calls (assigned to var) ---
  var expr = this.compileCall(callee, args, idx);
  if (expr !== null) {
    var varName = this.ensureVar(idx);
    this.line('var ' + varName + ' = ' + expr + ';');
  }
};

/** Compile a call expression to a JS string (not a statement). */
CodegenContext.prototype.compileCall = function(callee, args, idx) {
  var a = args.length > 0 ? this.ref(args[0]) : 'undefined';
  var b = args.length > 1 ? this.ref(args[1]) : 'undefined';
  var c = args.length > 2 ? this.ref(args[2]) : 'undefined';

  var t0 = args.length > 0 ? this.resolveType(args[0]) : TYPE_ANY;
  var t1 = args.length > 1 ? this.resolveType(args[1]) : TYPE_ANY;

  switch (callee) {
    // ---- Arithmetic ----
    case '+':
      if (args.length === 1) return isIntType(t0) ? '(+' + a + ' | 0)' : '+' + a;
      if (isIntType(t0) && isIntType(t1)) return '((' + a + ' + ' + b + ') | 0)';
      if (isStringType(t0) || isStringType(t1)) return '(' + a + ' + ' + b + ')';
      return '(' + a + ' + ' + b + ')';

    case '-':
      if (args.length === 1) return isIntType(t0) ? '((-' + a + ') | 0)' : '(-' + a + ')';
      if (isIntType(t0) && isIntType(t1)) return '((' + a + ' - ' + b + ') | 0)';
      return '(' + a + ' - ' + b + ')';

    case 'neg':
      return isIntType(t0) ? '((-' + a + ') | 0)' : '(-' + a + ')';

    case '*':
      if (isIntType(t0) && isIntType(t1)) return 'Math.imul(' + a + ', ' + b + ')';
      if (isStringType(t0) && isIntType(t1)) return a + '.repeat(' + b + ')';
      if (isStringType(t0) && isStringType(t1)) return '(' + a + ' + ' + b + ')';
      return '(' + a + ' * ' + b + ')';

    case '/':
      return '(' + a + ' / ' + b + ')';

    case '^':
      if (isIntType(t0) && isIntType(t1)) return '(Math.pow(' + a + ', ' + b + ') | 0)';
      return 'Math.pow(' + a + ', ' + b + ')';

    case 'rem': case '%':
      if (isIntType(t0)) return '((' + a + ' % ' + b + ') | 0)';
      return '(' + a + ' % ' + b + ')';

    case 'div': case '÷':
      return '((' + a + ' / ' + b + ') | 0)';

    case 'fld':
      this.requireRuntime('jl_fld');
      return 'jl_fld(' + a + ', ' + b + ')';

    case 'mod':
      this.requireRuntime('jl_mod');
      return 'jl_mod(' + a + ', ' + b + ')';

    case 'cld':
      this.requireRuntime('jl_cld');
      return 'jl_cld(' + a + ', ' + b + ')';

    // ---- Comparisons ----
    case '==':  return '(' + a + ' === ' + b + ')';
    case '!=':  return '(' + a + ' !== ' + b + ')';
    case '<':   return '(' + a + ' < ' + b + ')';
    case '>':   return '(' + a + ' > ' + b + ')';
    case '<=':  return '(' + a + ' <= ' + b + ')';
    case '>=':  return '(' + a + ' >= ' + b + ')';

    case '===':
      if (isNumericType(t0) || isStringType(t0) || t0 === TYPE_BOOL || t0 === TYPE_NOTHING) {
        return '(' + a + ' === ' + b + ')';
      }
      this.requireRuntime('jl_egal');
      return 'jl_egal(' + a + ', ' + b + ')';

    case '!==':
      return '(' + a + ' !== ' + b + ')';

    // ---- Logical ----
    case '!': return '(!' + a + ')';

    // ---- Bitwise ----
    case 'bitand': return '(' + a + ' & ' + b + ')';
    case 'bitor':  return '(' + a + ' | ' + b + ')';
    case 'bitnot': return '(~' + a + ')';
    case '<<':     return '((' + a + ' << ' + b + ') | 0)';
    case '>>':     return '((' + a + ' >> ' + b + ') | 0)';
    case '>>>':    return '(' + a + ' >>> ' + b + ')';

    // ---- Math functions ----
    case 'sin':    return 'Math.sin(' + a + ')';
    case 'cos':    return 'Math.cos(' + a + ')';
    case 'tan':    return 'Math.tan(' + a + ')';
    case 'asin':   return 'Math.asin(' + a + ')';
    case 'acos':   return 'Math.acos(' + a + ')';
    case 'atan':
      return args.length >= 2 ? 'Math.atan2(' + a + ', ' + b + ')' : 'Math.atan(' + a + ')';
    case 'exp':    return 'Math.exp(' + a + ')';
    case 'log':
      return args.length >= 2 ? '(Math.log(' + b + ') / Math.log(' + a + '))' : 'Math.log(' + a + ')';
    case 'log2':   return 'Math.log2(' + a + ')';
    case 'log10':  return 'Math.log10(' + a + ')';
    case 'sqrt':   return 'Math.sqrt(' + a + ')';
    case 'abs':    return 'Math.abs(' + a + ')';
    case 'floor':  return isIntType(t0) ? a : 'Math.floor(' + a + ')';
    case 'ceil':   return isIntType(t0) ? a : 'Math.ceil(' + a + ')';
    case 'trunc':  return isIntType(t0) ? a : 'Math.trunc(' + a + ')';
    case 'round':  return isIntType(t0) ? a : 'Math.round(' + a + ')';
    case 'sign':   return 'Math.sign(' + a + ')';
    case 'min':    return 'Math.min(' + a + ', ' + b + ')';
    case 'max':    return 'Math.max(' + a + ', ' + b + ')';
    case 'clamp':  return 'Math.min(Math.max(' + a + ', ' + b + '), ' + c + ')';
    case 'copysign': return '(Math.sign(' + b + ') * Math.abs(' + a + '))';
    case 'flipsign': return '((' + b + ' >= 0) ? ' + a + ' : -' + a + ')';
    case 'zero':   return '0';
    case 'one':    return '1';
    case 'typemin': return isFloatType(t0) ? '-Infinity' : '(-2147483648)';
    case 'typemax': return isFloatType(t0) ? 'Infinity' : '2147483647';
    case 'isnan':  return '(' + a + ' !== ' + a + ')';
    case 'isinf':  return '(!isFinite(' + a + '))';
    case 'isfinite': return 'isFinite(' + a + ')';

    // ---- String operations ----
    case 'string':
      if (args.length === 0) return '""';
      if (args.length === 1 && isStringType(t0)) return a;
      if (args.length === 1) return 'String(' + a + ')';
      this.requireRuntime('jl_string');
      var sArgs = [];
      for (var si = 0; si < args.length; si++) sArgs.push(this.ref(args[si]));
      return 'jl_string(' + sArgs.join(', ') + ')';

    case 'length':
      return a + '.length';
    case 'ncodeunits':
      return a + '.length';
    case 'sizeof':
      return a + '.length';
    case 'startswith':
      return a + '.startsWith(' + b + ')';
    case 'endswith':
      return a + '.endsWith(' + b + ')';
    case 'uppercase':
      return a + '.toUpperCase()';
    case 'lowercase':
      return a + '.toLowerCase()';
    case 'strip':
      return a + '.trim()';
    case 'lstrip':
      return a + '.trimStart()';
    case 'rstrip':
      return a + '.trimEnd()';
    case 'split':
      return args.length >= 2 ? a + '.split(' + b + ')' : a + '.split("")';
    case 'join':
      return args.length >= 2 ? a + '.join(' + b + ')' : a + '.join("")';
    case 'replace':
      return args.length >= 3
        ? a + '.replace(' + b + ', ' + c + ')'
        : a + '.replace(' + b + ', "")';
    case 'occursin': case 'contains':
      // occursin(needle, haystack) — note arg order
      return b + '.includes(' + a + ')';
    case 'chop':
      return a + '.slice(0, -1)';
    case 'chomp':
      return a + '.replace(/\\n$/, "")';
    case 'reverse':
      if (isStringType(t0)) return a + '.split("").reverse().join("")';
      return a + '.slice().reverse()';
    case 'repeat':
      return a + '.repeat(' + b + ')';
    case 'repr':
      return 'JSON.stringify(' + a + ')';
    case 'isempty':
      return '(' + a + '.length === 0)';
    case 'lpad':
      return a + '.padStart(' + b + (args.length >= 3 ? ', ' + c : '') + ')';
    case 'rpad':
      return a + '.padEnd(' + b + (args.length >= 3 ? ', ' + c : '') + ')';

    // ---- Collection operations ----
    case 'getindex':
      return a + '[' + b + ' - 1]';
    case 'pop!':
      return a + '.pop()';
    case 'first':
      return a + '[0]';
    case 'last':
      return a + '[' + a + '.length - 1]';
    case 'sort':
      return a + '.slice().sort(function(x, y) { return x - y; })';
    case 'keys':
      return 'Array.from(' + a + '.keys())';
    case 'values':
      return 'Array.from(' + a + '.values())';
    case 'haskey':
      return a + '.has(' + b + ')';
    case 'size':
      return args.length >= 2 ? a + '.length' : '[' + a + '.length]';
    case 'in':
      // x in collection → collection.includes(x)
      return b + '.includes(' + a + ')';
    case 'vect':
      var ve = [];
      for (var vi = 0; vi < args.length; vi++) ve.push(this.ref(args[vi]));
      return '[' + ve.join(', ') + ']';
    case 'tuple':
      var te = [];
      for (var ti = 0; ti < args.length; ti++) te.push(this.ref(args[ti]));
      return '[' + te.join(', ') + ']';
    case 'Dict':
      return 'new Map()';
    case 'Set':
      return 'new Set()';
    case 'collect':
      return a + '.slice()';

    // ---- Type operations ----
    case 'isa':
      return this.compileIsa(args);
    case 'typeof':
      return 'typeof ' + a;
    case 'convert':
      return args.length >= 2 ? this.ref(args[1]) : a;
    case 'Float64': case 'Float32': case 'float':
      return '(+(' + a + '))';
    case 'Int64': case 'Int32': case 'Int':
      return '((' + a + ') | 0)';

    // ---- Range ----
    case ':': case 'range':
      if (args.length === 2) {
        return '(function() { var r = []; for (var _ri = ' + a +
               '; _ri <= ' + b + '; _ri++) r.push(_ri); return r; })()';
      }
      if (args.length === 3) {
        return '(function() { var r = [], _rs = ' + b +
               '; for (var _ri = ' + a + '; _rs > 0 ? _ri <= ' + c +
               ' : _ri >= ' + c + '; _ri += _rs) r.push(_ri); return r; })()';
      }
      return '[]';

    // ---- Pipe ----
    case '|>':
      return b + '(' + a + ')';

    // ---- Broadcasting ----
    case 'broadcast':
      if (args.length >= 2) {
        var bf = this.ref(args[0]), ba = this.ref(args[1]);
        return ba + '.map(' + bf + ')';
      }
      return 'undefined';
    case '.+': return '(' + a + ' + ' + b + ')';
    case '.-': return '(' + a + ' - ' + b + ')';
    case '.*': return '(' + a + ' * ' + b + ')';
    case './': return '(' + a + ' / ' + b + ')';
    case '.^': return 'Math.pow(' + a + ', ' + b + ')';

    // ---- Special ----
    case '$global':
      var gname = stmt._name || (args.length > 0 ? String(args[0]) : 'undefined');
      return sanitizeName(gname);

    case '$apply':
      // Higher-order call: first arg = function, rest = arguments
      var hof = this.ref(args[0]);
      var hofArgs = [];
      for (var hi = 1; hi < args.length; hi++) hofArgs.push(this.ref(args[hi]));
      return hof + '(' + hofArgs.join(', ') + ')';

    // ---- Default: generic function call ----
    default:
      var fArgs = [];
      for (var fi = 0; fi < args.length; fi++) fArgs.push(this.ref(args[fi]));
      return sanitizeName(callee) + '(' + fArgs.join(', ') + ')';
  }
};

/** Compile an isa() check to JS. */
CodegenContext.prototype.compileIsa = function(args) {
  if (args.length < 2) return 'false';
  var val = this.ref(args[0]);
  var typeRef = args[1];
  var typeId = ('lit' in typeRef) ? typeRef.lit : TYPE_ANY;

  if (typeId === TYPE_NOTHING) return '(' + val + ' === null)';
  if (typeId === TYPE_MISSING) return '(' + val + ' === undefined)';
  if (typeId === TYPE_BOOL) return '(typeof ' + val + ' === "boolean")';
  if (typeId === TYPE_STRING || typeId === TYPE_CHAR) return '(typeof ' + val + ' === "string")';
  if (isIntType(typeId) || isFloatType(typeId)) return '(typeof ' + val + ' === "number")';

  // User-defined struct
  if (typeId >= USER_TYPE_BASE) {
    var sn = this.findStructByTypeId(typeId);
    if (sn) return '(' + val + ' instanceof ' + sanitizeName(sn) + ')';
  }

  return 'true';
};

/** Find struct name by TypeID. */
CodegenContext.prototype.findStructByTypeId = function(typeId) {
  for (var name in this.structDefs) {
    if (this.structDefs[name].typeId === typeId) return name;
  }
  return null;
};

// ============================================================
// Getfield Emission
// ============================================================

CodegenContext.prototype.emitGetfield = function(stmt, idx) {
  var obj = this.ref(stmt.obj);
  var field = sanitizeName(stmt.field);
  var varName = this.ensureVar(idx);
  this.line('var ' + varName + ' = ' + obj + '.' + field + ';');
};

// ============================================================
// New Emission
// ============================================================

CodegenContext.prototype.emitNew = function(stmt, idx) {
  var varName = this.ensureVar(idx);
  var typeName = stmt.typeName || '';
  var newArgs = [];
  for (var i = 0; i < (stmt.args || []).length; i++) {
    newArgs.push(this.ref(stmt.args[i]));
  }

  // Built-in collection types
  if (typeName === 'Vector' || typeName === 'Array') {
    this.line('var ' + varName + ' = [' + newArgs.join(', ') + '];');
    return;
  }
  if (typeName === 'Dict' || typeName === 'Map') {
    this.line('var ' + varName + ' = new Map();');
    return;
  }
  if (typeName === 'Set') {
    this.line('var ' + varName + ' = new Set();');
    return;
  }

  // User-defined struct
  this.line('var ' + varName + ' = new ' + sanitizeName(typeName) + '(' + newArgs.join(', ') + ');');
};

// ============================================================
// If Structure
// ============================================================

CodegenContext.prototype.emitIfStructure = function(hint) {
  var condIdx = hint.condIdx;
  var mergeIdx = hint.mergeIdx;
  var code = this.code;

  var gotoIfNot = code[condIdx];
  if (!gotoIfNot || gotoIfNot.kind !== STMT_GOTOIFNOT) {
    // Malformed — skip
    return;
  }

  var elseDest = gotoIfNot.dest;
  var condExpr = this.ref(gotoIfNot.cond);

  // Detect if there's an else branch:
  // The GOTO at elseDest-1 (end of then body) skips over the else.
  // If GOTO.dest > elseDest, there are else statements between elseDest and GOTO.dest.
  var gotoMergeIdx = elseDest - 1;
  var hasElse = false;
  var thenStart = condIdx + 1;
  var thenEnd, elseStart, elseEnd, phiStart;

  if (gotoMergeIdx > condIdx && code[gotoMergeIdx] &&
      code[gotoMergeIdx].kind === STMT_GOTO) {
    var gotoMergeDest = code[gotoMergeIdx].dest;
    if (gotoMergeDest > elseDest) {
      hasElse = true;
      thenEnd = gotoMergeIdx;     // exclusive (skip the GOTO)
      elseStart = elseDest;
      phiStart = gotoMergeDest;
      elseEnd = phiStart;         // exclusive
    } else {
      thenEnd = gotoMergeIdx;     // exclusive
      phiStart = elseDest;
    }
  } else {
    thenEnd = elseDest;
    phiStart = elseDest;
  }

  // Collect phi nodes at merge point
  var phis = [];
  for (var pi = phiStart; pi <= mergeIdx; pi++) {
    if (code[pi] && code[pi].kind === STMT_PHI) {
      phis.push({ idx: pi, stmt: code[pi] });
    }
  }

  // Declare phi variables before the if
  for (var di = 0; di < phis.length; di++) {
    var pv = this.ensureVar(phis[di].idx);
    this.line('var ' + pv + ';');
  }

  // Emit if
  this.line('if (' + condExpr + ') {');
  this.indent++;

  // Then body
  this.emitRegion(thenStart, thenEnd);

  // Phi assignments from then branch (edges[0] = then value)
  for (var ti = 0; ti < phis.length; ti++) {
    var thenEdge = phis[ti].stmt.edges && phis[ti].stmt.edges[0];
    if (thenEdge) {
      this.line(this.ssaVars[phis[ti].idx] + ' = ' + this.ref(thenEdge.val) + ';');
    }
  }

  this.indent--;

  if (hasElse || phis.length > 0) {
    this.line('} else {');
    this.indent++;

    if (hasElse) {
      this.emitRegion(elseStart, elseEnd);
    }

    // Phi assignments from else/fallthrough branch (edges[1] = else value)
    for (var ei = 0; ei < phis.length; ei++) {
      var elseEdge = phis[ei].stmt.edges && phis[ei].stmt.edges[1];
      if (elseEdge) {
        this.line(this.ssaVars[phis[ei].idx] + ' = ' + this.ref(elseEdge.val) + ';');
      }
    }

    this.indent--;
  }

  this.line('}');
};

/** Find a phi edge whose `from` is in [start, end). */
CodegenContext.prototype.findPhiEdge = function(phiStmt, start, end) {
  var edges = phiStmt.edges || [];
  for (var i = 0; i < edges.length; i++) {
    if (edges[i].from >= start && edges[i].from < end) return edges[i];
  }
  return null;
};

// ============================================================
// While/For Loop Structure
// ============================================================

CodegenContext.prototype.emitLoopStructure = function(hint) {
  var headerIdx = hint.headerIdx;
  var exitIdx = hint.exitIdx;
  var code = this.code;

  // Collect phi nodes at loop header
  var headerPhis = [];
  var pos = headerIdx;
  while (pos < code.length && code[pos] && code[pos].kind === STMT_PHI) {
    headerPhis.push({ idx: pos, stmt: code[pos] });
    pos++;
  }
  var afterPhis = pos; // first non-phi statement after header

  // Find the GOTOIFNOT (loop condition exit)
  var condIdx = -1;
  for (var ci = afterPhis; ci < exitIdx; ci++) {
    if (code[ci] && code[ci].kind === STMT_GOTOIFNOT && code[ci].dest >= exitIdx) {
      condIdx = ci;
      break;
    }
  }

  // Find the back-edge GOTO (last GOTO to headerIdx before exitIdx)
  var backEdgeIdx = -1;
  for (var bi = exitIdx - 1; bi > headerIdx; bi--) {
    if (code[bi] && code[bi].kind === STMT_GOTO && code[bi].dest === headerIdx) {
      backEdgeIdx = bi;
      break;
    }
  }
  var bodyEnd = backEdgeIdx >= 0 ? backEdgeIdx : exitIdx;

  // Initialize phi variables from pre-loop edges (edges[0] = init)
  for (var ip = 0; ip < headerPhis.length; ip++) {
    var phi = headerPhis[ip];
    var phiVar = this.ensureVar(phi.idx);
    var initEdge = phi.stmt.edges && phi.stmt.edges[0];
    var initVal = initEdge ? this.ref(initEdge.val) : 'undefined';
    this.line('var ' + phiVar + ' = ' + initVal + ';');
  }

  // Emit while (true) { ... }
  this.line('while (true) {');
  this.indent++;
  this.loopStack.push({ headerIdx: headerIdx, exitIdx: exitIdx });

  if (condIdx >= 0) {
    // Emit condition computation (between phis and the GOTOIFNOT)
    this.emitRegion(afterPhis, condIdx);

    // Emit break condition
    var condExpr = this.ref(code[condIdx].cond);
    this.line('if (!(' + condExpr + ')) break;');

    // Emit loop body
    this.emitRegion(condIdx + 1, bodyEnd);
  } else {
    // No condition (while true) — emit everything
    this.emitRegion(afterPhis, bodyEnd);
  }

  // Update phi variables from back-edge (edges[1] = back)
  // Use temps for simultaneous assignment (prevents cross-reference bugs)
  if (headerPhis.length >= 2) {
    var temps = [];
    for (var up = 0; up < headerPhis.length; up++) {
      var upPhi = headerPhis[up];
      var backEdge = upPhi.stmt.edges && upPhi.stmt.edges[1];
      if (backEdge) {
        var tmp = this.freshVar();
        temps.push({ phiVar: this.ssaVars[upPhi.idx], tmp: tmp });
        this.line('var ' + tmp + ' = ' + this.ref(backEdge.val) + ';');
      }
    }
    for (var ta = 0; ta < temps.length; ta++) {
      this.line(temps[ta].phiVar + ' = ' + temps[ta].tmp + ';');
    }
  } else if (headerPhis.length === 1) {
    var backEdge1 = headerPhis[0].stmt.edges && headerPhis[0].stmt.edges[1];
    if (backEdge1) {
      this.line(this.ssaVars[headerPhis[0].idx] + ' = ' + this.ref(backEdge1.val) + ';');
    }
  }

  this.loopStack.pop();
  this.indent--;
  this.line('}');
};

/** Find phi edge with `from` < headerIdx (pre-loop init). */
CodegenContext.prototype.findPhiEdgeBefore = function(phiStmt, headerIdx) {
  var edges = phiStmt.edges || [];
  for (var i = 0; i < edges.length; i++) {
    if (edges[i].from < headerIdx) return edges[i];
  }
  return edges.length > 0 ? edges[0] : null;
};

/** Find phi edge with `from` >= headerIdx (back-edge update). */
CodegenContext.prototype.findPhiEdgeAfter = function(phiStmt, headerIdx) {
  var edges = phiStmt.edges || [];
  for (var i = 0; i < edges.length; i++) {
    if (edges[i].from >= headerIdx) return edges[i];
  }
  return edges.length > 1 ? edges[1] : null;
};

// ============================================================
// Try/Catch Structure
// ============================================================

CodegenContext.prototype.emitTryStructure = function(hint) {
  // Remove from structIndex to prevent infinite recursion
  delete this.structIndex[hint.tryStart];

  this.line('try {');
  this.indent++;
  var tryEnd = (hint.tryEnd !== undefined) ? hint.tryEnd + 1 : hint.tryStart + 1;
  this.emitRegion(hint.tryStart, tryEnd);
  this.indent--;

  if (hint.catchStart !== undefined) {
    this.line('} catch (_err) {');
    this.indent++;
    var catchEnd = (hint.catchEnd !== undefined) ? hint.catchEnd + 1 : hint.catchStart + 1;
    this.emitRegion(hint.catchStart, catchEnd);
    this.indent--;
  }

  if (hint.finallyStart !== undefined && hint.finallyEnd !== undefined &&
      hint.finallyStart <= hint.finallyEnd) {
    this.line('} finally {');
    this.indent++;
    this.emitRegion(hint.finallyStart, hint.finallyEnd + 1);
    this.indent--;
  }

  if (hint.catchStart === undefined && hint.finallyStart === undefined) {
    this.line('} catch (_err) {}');
  } else {
    this.line('}');
  }
};

// ============================================================
// Struct Class Generation
// ============================================================

function generateStruct(def) {
  if (def.abstract) return '';
  var name = sanitizeName(def.name);
  var fields = def.fields || [];
  var lines = [];

  var params = [];
  for (var i = 0; i < fields.length; i++) params.push(sanitizeName(fields[i].name));

  lines.push('function ' + name + '(' + params.join(', ') + ') {');
  for (var j = 0; j < fields.length; j++) {
    var fn = sanitizeName(fields[j].name);
    lines.push('  this.' + fn + ' = ' + fn + ';');
  }
  lines.push('}');

  if (def.typeId !== undefined) {
    lines.push(name + '.prototype.$type = ' + def.typeId + ';');
  }

  return lines.join('\n');
}

// ============================================================
// Function Generation
// ============================================================

function generateFunction(name, func, ssaTypes, argTypes, structDefs, allFunctions) {
  var ctx = new CodegenContext(func, ssaTypes, argTypes, structDefs, allFunctions);
  var safeName = sanitizeName(name);
  var params = [];
  for (var i = 0; i < func.argCount; i++) {
    params.push(func.argNames[i] || ('_arg' + i));
  }

  ctx.lines.push('function ' + safeName + '(' + params.join(', ') + ') {');
  ctx.emitRegion(0, func.code.length);
  ctx.lines.push('}');

  return {
    js: ctx.lines.join('\n'),
    requiredRuntime: ctx.requiredRuntime,
  };
}

// ============================================================
// Module Generation — full pipeline from lowered IR to JS
// ============================================================

/**
 * Generate a complete JS module from lowered IR.
 * @param {Object} lowered - Output of lowerer.lowerModule() or lowerer.lower()
 * @param {Object} [tables] - Loaded inference tables (from infer.js loadTables)
 * @returns {{ js: string, diagnostics: string[] }}
 */
function generateModule(lowered, tables) {
  var functions = lowered.functions || {};
  var structDefs = lowered.structDefs || {};
  var diagnostics = (lowered.diagnostics || []).slice();

  var parts = [];
  var allRuntime = {};

  // 1. Optionally run inference for all functions
  var inferEngine = null;
  try {
    if (typeof JuliaInfer !== 'undefined') inferEngine = JuliaInfer;
    else if (typeof require !== 'undefined') inferEngine = require('./infer.js');
  } catch (e) { /* inference optional */ }

  var funcTypes = {};
  for (var fname in functions) {
    var func = functions[fname];
    var argTypes = [];
    if (func.paramTypes) {
      for (var ai = 0; ai < func.paramTypes.length; ai++) {
        argTypes.push(TYPE_NAME_MAP[func.paramTypes[ai]] || TYPE_ANY);
      }
    }
    var ssaTypes = [];
    if (inferEngine && tables) {
      try {
        ssaTypes = inferEngine.inferFunction(func, argTypes, tables);
      } catch (e) {
        diagnostics.push('Inference failed for ' + fname + ': ' + e.message);
      }
    }
    funcTypes[fname] = { ssaTypes: ssaTypes, argTypes: argTypes };
  }

  // 2. Generate struct class definitions
  for (var sname in structDefs) {
    var sdef = structDefs[sname];
    if (!sdef.abstract) {
      var sCode = generateStruct(sdef);
      if (sCode) parts.push(sCode);
    }
  }

  // 3. Generate functions (excluding $main)
  for (var fn in functions) {
    if (fn === '$main') continue;
    var ft = funcTypes[fn];
    var res = generateFunction(fn, functions[fn], ft.ssaTypes, ft.argTypes, structDefs, functions);
    parts.push(res.js);
    for (var rt in res.requiredRuntime) allRuntime[rt] = true;
  }

  // 4. Generate $main and invoke it
  if (functions['$main']) {
    var mt = funcTypes['$main'];
    var mres = generateFunction('$main', functions['$main'], mt.ssaTypes, mt.argTypes, structDefs, functions);
    parts.push(mres.js);
    for (var mrt in mres.requiredRuntime) allRuntime[mrt] = true;
    parts.push('$main();');
  }

  // 5. Prepend required runtime helpers (in dependency order)
  var ordered = [];
  var visited = {};
  function addRuntime(name) {
    if (visited[name]) return;
    visited[name] = true;
    var deps = RUNTIME_DEPS[name];
    if (deps) {
      for (var i = 0; i < deps.length; i++) addRuntime(deps[i]);
    }
    if (RUNTIME[name]) ordered.push(RUNTIME[name]);
  }
  for (var rname in allRuntime) addRuntime(rname);

  var js = '';
  if (ordered.length > 0) js = ordered.join('\n') + '\n\n';
  js += parts.join('\n\n');

  return { js: js, diagnostics: diagnostics };
}

// ============================================================
// Convenience: full pipeline parse → lower → codegen → JS
// ============================================================

/**
 * Compile Julia source code to JavaScript.
 * Requires parser.js and lowerer.js to be available.
 *
 * @param {string} source - Julia source code
 * @param {Object} [tables] - Inference tables (optional, from infer.js loadTables)
 * @returns {{ js: string, diagnostics: string[] }}
 */
function compile(source, tables) {
  var parser, lowerer;
  if (typeof JuliaParser !== 'undefined') parser = JuliaParser;
  else if (typeof require !== 'undefined') {
    try { parser = require('./parser.js'); } catch (e) {}
  }
  if (typeof JuliaLowerer !== 'undefined') lowerer = JuliaLowerer;
  else if (typeof require !== 'undefined') {
    try { lowerer = require('./lowerer.js'); } catch (e) {}
  }

  if (!parser) throw new Error('JuliaParser not available — load parser.js first');
  if (!lowerer) throw new Error('JuliaLowerer not available — load lowerer.js first');

  var parsed = parser.parse(source);
  var lowered = lowerer.lowerModule(parsed.ast);
  lowered.diagnostics = (parsed.diagnostics || []).concat(lowered.diagnostics || []);

  return generateModule(lowered, tables);
}

// ============================================================
// Exports
// ============================================================

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    // Public API
    compile: compile,
    generateModule: generateModule,
    generateFunction: generateFunction,
    generateStruct: generateStruct,

    // Classes (for testing)
    CodegenContext: CodegenContext,

    // Statement kinds
    STMT_CALL: STMT_CALL, STMT_PHI: STMT_PHI, STMT_GETFIELD: STMT_GETFIELD,
    STMT_NEW: STMT_NEW, STMT_LITERAL: STMT_LITERAL, STMT_RETURN: STMT_RETURN,
    STMT_GOTO: STMT_GOTO, STMT_GOTOIFNOT: STMT_GOTOIFNOT, STMT_PINODE: STMT_PINODE,

    // Type IDs
    TYPE_ANY: TYPE_ANY, TYPE_NOTHING: TYPE_NOTHING, TYPE_BOOL: TYPE_BOOL,
    TYPE_INT32: TYPE_INT32, TYPE_INT64: TYPE_INT64,
    TYPE_FLOAT64: TYPE_FLOAT64, TYPE_STRING: TYPE_STRING,

    // Helpers
    sanitizeName: sanitizeName, isIntType: isIntType,
    isFloatType: isFloatType, isNumericType: isNumericType,
    TYPE_NAME_MAP: TYPE_NAME_MAP,
  };
}

if (typeof globalThis !== 'undefined') {
  globalThis.JuliaCodegen = {
    compile: compile,
    generateModule: generateModule,
    generateFunction: generateFunction,
    generateStruct: generateStruct,
  };
}
