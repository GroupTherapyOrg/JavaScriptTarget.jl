// lowerer.js — Julia AST → SSA IR for the browser playground
// Transforms parser.js AST into linear SSA IR consumed by infer.js and codegen.js
//
// Architecture:
//   1. Scope analysis: variable tracking (local, captured, global)
//   2. SSA construction: AST → flat statement array with phi nodes
//   3. Structure annotations: control flow hints for codegen.js
//
// In scope: Variable declarations, control flow, function calls, struct construction,
//           field access, array indexing, try/catch, closures, destructuring,
//           short-circuit, ternary, string interpolation, ranges, comprehensions.
// Out of scope: Macro expansion (pre-expanded), module system, eval, @generated.
//
// Pre-expanded macros (15): @show, @assert, @info, @warn, @error, @time, @elapsed,
//   @inbounds, @views, @., @debug, @simd, @inline, @noinline, @fastmath.
//
// Selfhost spec §4.

'use strict';

// ============================================================
// Statement Kinds — must match infer.js exactly
// ============================================================

var STMT_CALL      = 1;   // { callee: string, args: [ref...] }
var STMT_PHI       = 2;   // { edges: [{ from: int, val: ref }...] }
var STMT_GETFIELD  = 3;   // { obj: ref, field: string }
var STMT_NEW       = 4;   // { typeId: int, typeName: string, args: [ref...] }
var STMT_LITERAL   = 5;   // { typeId: int, value: any }
var STMT_RETURN    = 6;   // { val: ref }
var STMT_GOTO      = 7;   // { dest: int }
var STMT_GOTOIFNOT = 8;   // { cond: ref, dest: int }
var STMT_PINODE    = 9;   // { val: ref, typeId: int }

// ============================================================
// Type IDs — must match infer.js / type_registry.jl
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

// First user-defined struct type ID
var USER_TYPE_BASE = 100;

// ============================================================
// Ref Constructors — SSA value references
// ============================================================

/** Reference to an SSA slot (result of statement at index i). */
function ssaRef(i) { return { ssa: i }; }

/** Reference to a function argument by index. */
function argRef(i) { return { arg: i }; }

/** Literal type reference (for infer.js; value carried separately). */
function litRef(typeId) { return { lit: typeId }; }

// ============================================================
// Operator → callee name mapping
// ============================================================

var BINARY_OP_MAP = {
  '+': '+', '-': '-', '*': '*', '/': '/', '%': 'rem', '^': '^',
  '==': '==', '!=': '!=', '<': '<', '>': '>', '<=': '<=', '>=': '>=',
  '===': '===', '!==': '!==',
  '&': 'bitand', '|': 'bitor',
  '<<': '<<', '>>': '>>', '>>>': '>>>',
  'in': 'in', 'isa': 'isa',
  '÷': 'div', '|>': '|>',
  '.+': '.+', '.-': '.-', '.*': '.*', './': './', '.^': '.^',
};

var UNARY_OP_MAP = {
  '-': 'neg', '+': '+', '!': '!', '~': 'bitnot',
};

// ============================================================
// Type name → TypeID mapping for parameter annotations
// ============================================================

var TYPE_NAME_MAP = {
  'Any': TYPE_ANY, 'Nothing': TYPE_NOTHING, 'Missing': TYPE_MISSING,
  'Bool': TYPE_BOOL,
  'Int8': TYPE_INT8, 'Int16': TYPE_INT16, 'Int32': TYPE_INT32,
  'Int64': TYPE_INT64, 'Int128': TYPE_INT128,
  'UInt8': TYPE_UINT8, 'UInt16': TYPE_UINT16, 'UInt32': TYPE_UINT32,
  'UInt64': TYPE_UINT64, 'UInt128': TYPE_UINT128,
  'Float16': TYPE_FLOAT16, 'Float32': TYPE_FLOAT32, 'Float64': TYPE_FLOAT64,
  'Char': TYPE_CHAR, 'String': TYPE_STRING, 'Symbol': TYPE_SYMBOL,
  'Integer': TYPE_INT64, 'Number': TYPE_FLOAT64,
};

// ============================================================
// LoweringContext — manages SSA construction for one function
// ============================================================

/**
 * Tracks SSA state, variable scope, and control flow during lowering.
 * @param {string[]} argNames - Parameter names for the function being lowered.
 */
function LoweringContext(argNames) {
  this.code = [];             // Flat SSA statement array
  this.argNames = argNames;   // Parameter names
  this.argCount = argNames.length;
  this.structure = [];        // Control flow structure hints for codegen
  this.names = {};            // SSA index → variable name hint

  // Scope: stack of name→ref Maps; innermost is last
  this.scopes = [new Map()];

  // Register arguments in the outermost scope
  for (var i = 0; i < argNames.length; i++) {
    this.scopes[0].set(argNames[i], argRef(i));
  }

  // Loop context stack for break/continue
  this.loopStack = [];  // [{ breakPatches: int[], headerIdx: int }]
}

// --- SSA management ---

/** Emit a statement, return an SSA ref to it. */
LoweringContext.prototype.emit = function(stmt) {
  var idx = this.code.length;
  this.code.push(stmt);
  return ssaRef(idx);
};

/** Emit a statement, return its raw index (not a ref). */
LoweringContext.prototype.emitIdx = function(stmt) {
  var idx = this.code.length;
  this.code.push(stmt);
  return idx;
};

/** Current position (index of the next statement to be emitted). */
LoweringContext.prototype.pos = function() {
  return this.code.length;
};

/** Attach a variable name hint to an SSA slot. */
LoweringContext.prototype.setName = function(ref, name) {
  if (ref && typeof ref === 'object' && 'ssa' in ref) {
    this.names[ref.ssa] = name;
  }
};

// --- Scope management ---

LoweringContext.prototype.pushScope = function() {
  this.scopes.push(new Map());
};

LoweringContext.prototype.popScope = function() {
  this.scopes.pop();
};

/** Look up a variable in the scope chain (innermost first). */
LoweringContext.prototype.lookup = function(name) {
  for (var i = this.scopes.length - 1; i >= 0; i--) {
    var ref = this.scopes[i].get(name);
    if (ref !== undefined) return ref;
  }
  return null;
};

/** Set a variable: update existing binding, or create in innermost scope. */
LoweringContext.prototype.setVar = function(name, ref) {
  for (var i = this.scopes.length - 1; i >= 0; i--) {
    if (this.scopes[i].has(name)) {
      this.scopes[i].set(name, ref);
      return;
    }
  }
  // New variable — create in innermost scope
  this.scopes[this.scopes.length - 1].set(name, ref);
};

/** Declare a new local in the innermost scope (shadows outer). */
LoweringContext.prototype.declareLocal = function(name, ref) {
  this.scopes[this.scopes.length - 1].set(name, ref);
};

/**
 * Snapshot all variable bindings (flattened across all scopes).
 * Used before branching to compare environments after each branch.
 */
LoweringContext.prototype.snapshotEnv = function() {
  var snap = new Map();
  for (var i = 0; i < this.scopes.length; i++) {
    for (var it = this.scopes[i].entries(), e = it.next(); !e.done; e = it.next()) {
      snap.set(e.value[0], e.value[1]);
    }
  }
  return snap;
};

/** Restore a variable binding across all scopes (used after if/else merge). */
LoweringContext.prototype.restoreVar = function(name, ref) {
  for (var i = this.scopes.length - 1; i >= 0; i--) {
    if (this.scopes[i].has(name)) {
      this.scopes[i].set(name, ref);
      return;
    }
  }
  this.scopes[0].set(name, ref);
};

// --- Goto / patch management ---

/** Emit a GOTO with placeholder destination. Returns the statement index. */
LoweringContext.prototype.emitGoto = function() {
  var idx = this.code.length;
  this.code.push({ kind: STMT_GOTO, dest: -1 });
  return idx;
};

/** Emit a GOTOIFNOT with placeholder destination. Returns the statement index. */
LoweringContext.prototype.emitGotoIfNot = function(condRef) {
  var idx = this.code.length;
  this.code.push({ kind: STMT_GOTOIFNOT, cond: condRef, dest: -1 });
  return idx;
};

/** Patch a GOTO or GOTOIFNOT destination. */
LoweringContext.prototype.patch = function(idx, dest) {
  this.code[idx].dest = dest;
};

// --- Result ---

/** Return the completed IR function. */
LoweringContext.prototype.result = function() {
  return {
    code: this.code,
    argCount: this.argCount,
    argNames: this.argNames,
    structure: this.structure,
    names: this.names,
  };
};

// ============================================================
// ModuleContext — manages top-level module lowering
// ============================================================

function ModuleContext() {
  this.functions = {};      // name → IR function
  this.structDefs = {};     // name → { name, fields, mutable, supertype, typeId, abstract? }
  this.nextTypeId = USER_TYPE_BASE;
  this.globals = new Map(); // name → ref (module-level constants)
  this.diagnostics = [];    // Warnings/errors
}

/** Register a struct type, returning its assigned TypeID. */
ModuleContext.prototype.registerStruct = function(name, fields, mutable, supertype) {
  var typeId = this.nextTypeId++;
  this.structDefs[name] = {
    name: name,
    fields: fields,
    mutable: mutable,
    supertype: supertype,
    typeId: typeId,
  };
  return typeId;
};

// ============================================================
// Macro Expansion — pre-expand 15 supported macros
// ============================================================

/**
 * Expand a MacroCall AST node into plain AST.
 * Unknown macros produce a diagnostic and pass through the first argument.
 */
function expandMacro(node, diagnostics) {
  var name = node.name;
  var args = node.args || [];

  switch (name) {
    // @show expr → println(string("expr = ", expr))
    case 'show': {
      if (args.length === 0) return { kind: 'Nothing' };
      var expr = args[0];
      var text = exprToString(expr);
      return {
        kind: 'Call',
        func: { kind: 'Identifier', name: 'println' },
        args: [{
          kind: 'Call',
          func: { kind: 'Identifier', name: 'string' },
          args: [
            { kind: 'StringLit', value: text + ' = ' },
            expr,
          ],
        }],
      };
    }

    // @assert cond [msg] → if !cond; error(msg); end
    case 'assert': {
      if (args.length === 0) return { kind: 'Nothing' };
      var cond = args[0];
      var msg = args.length > 1 ? args[1]
        : { kind: 'StringLit', value: 'AssertionError: assertion failed' };
      return {
        kind: 'If',
        condition: { kind: 'UnaryOp', op: '!', operand: cond },
        then: [{
          kind: 'Throw',
          expr: { kind: 'Call', func: { kind: 'Identifier', name: 'error' }, args: [msg] },
        }],
        elseifs: [],
        else: null,
      };
    }

    // @info/@warn/@error msg → println("[ LEVEL: msg ]")
    case 'info':
    case 'warn':
    case 'error': {
      var level = name.toUpperCase();
      var msgArg = args.length > 0 ? args[0] : { kind: 'StringLit', value: '' };
      return {
        kind: 'Call',
        func: { kind: 'Identifier', name: 'println' },
        args: [{
          kind: 'Call',
          func: { kind: 'Identifier', name: 'string' },
          args: [
            { kind: 'StringLit', value: '[ ' + level + ': ' },
            msgArg,
            { kind: 'StringLit', value: ' ]' },
          ],
        }],
      };
    }

    // @time expr → expr (no timing in playground)
    case 'time':
      return args.length > 0 ? args[0] : { kind: 'Nothing' };

    // @elapsed expr → 0.0 (placeholder)
    case 'elapsed':
      return { kind: 'Float', value: 0.0 };

    // Transparent wrappers — pass through the expression unchanged
    case 'inbounds':
    case 'views':
    case '.':
    case 'debug':
      return args.length > 0 ? args[0] : { kind: 'Nothing' };

    // Pure no-ops — drop the annotation, keep the expression
    case 'simd':
    case 'inline':
    case 'noinline':
    case 'fastmath':
      return args.length > 0 ? args[0] : { kind: 'Nothing' };

    default:
      diagnostics.push('Macro @' + name + ' is not available in the playground.');
      return args.length > 0 ? args[0] : { kind: 'Nothing' };
  }
}

/**
 * Convert an AST expression to a human-readable string (for @show).
 */
function exprToString(node) {
  if (!node) return '?';
  switch (node.kind) {
    case 'Identifier':  return node.name;
    case 'Integer':     return String(node.value);
    case 'Float':       return String(node.value);
    case 'StringLit':   return '"' + node.value + '"';
    case 'Bool':        return String(node.value);
    case 'Nothing':     return 'nothing';
    case 'BinaryOp':
      return exprToString(node.left) + ' ' + node.op + ' ' + exprToString(node.right);
    case 'UnaryOp':
      return node.op + exprToString(node.operand);
    case 'Call': {
      var fnStr = exprToString(node.func);
      var argStrs = (node.args || []).map(exprToString);
      return fnStr + '(' + argStrs.join(', ') + ')';
    }
    case 'DotAccess':
      return exprToString(node.object) + '.' + node.field;
    case 'Index': {
      var idxStrs = (node.indices || []).map(exprToString);
      return exprToString(node.object) + '[' + idxStrs.join(', ') + ']';
    }
    default:
      return '...';
  }
}

// ============================================================
// Expression Lowering — AST expression → SSA ref
// ============================================================

/**
 * Lower an expression AST node to SSA.
 * @param {Object} node - AST expression node from parser.js
 * @param {LoweringContext} ctx - Current function's lowering state
 * @param {ModuleContext} mod - Module-level context (structs, globals)
 * @returns {Object} An SSA ref ({ ssa: int }, { arg: int }, or { lit: typeId })
 */
function lowerExpr(node, ctx, mod) {
  if (!node) return litRef(TYPE_NOTHING);

  switch (node.kind) {
    // --- Literals ---

    case 'Integer':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_INT64, value: node.value });

    case 'Float':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_FLOAT64, value: node.value });

    case 'StringLit':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_STRING, value: node.value });

    case 'CharLit':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_CHAR, value: node.value });

    case 'Bool':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_BOOL, value: node.value });

    case 'Nothing':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_NOTHING, value: null });

    case 'Missing':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_MISSING, value: undefined });

    case 'Symbol':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_SYMBOL, value: node.name });

    // --- Identifier (variable reference) ---

    case 'Identifier': {
      var ref = ctx.lookup(node.name);
      if (ref !== null) return ref;
      // Check module-level globals
      if (mod && mod.globals.has(node.name)) return mod.globals.get(node.name);
      // Unknown variable — emit as unresolved global reference
      return ctx.emit({
        kind: STMT_CALL, callee: '$global', args: [],
        _name: node.name,
      });
    }

    // --- Binary operators ---

    case 'BinaryOp':
      return lowerBinaryOp(node, ctx, mod);

    // --- Unary operators ---

    case 'UnaryOp': {
      var operand = lowerExpr(node.operand, ctx, mod);
      var callee = UNARY_OP_MAP[node.op] || node.op;
      return ctx.emit({ kind: STMT_CALL, callee: callee, args: [operand] });
    }

    // --- Function call ---

    case 'Call':
      return lowerCall(node, ctx, mod);

    // --- Broadcast dot call: f.(args) ---

    case 'DotCall': {
      var funcRef = lowerExpr(node.func, ctx, mod);
      var bArgs = [];
      for (var i = 0; i < node.args.length; i++) {
        bArgs.push(lowerExpr(node.args[i], ctx, mod));
      }
      return ctx.emit({ kind: STMT_CALL, callee: 'broadcast', args: [funcRef].concat(bArgs) });
    }

    // --- Field access: obj.field ---

    case 'DotAccess': {
      var obj = lowerExpr(node.object, ctx, mod);
      return ctx.emit({ kind: STMT_GETFIELD, obj: obj, field: node.field });
    }

    // --- Array/Dict indexing: obj[idx] ---

    case 'Index': {
      var objRef = lowerExpr(node.object, ctx, mod);
      var idxRefs = [];
      for (var j = 0; j < node.indices.length; j++) {
        idxRefs.push(lowerExpr(node.indices[j], ctx, mod));
      }
      return ctx.emit({ kind: STMT_CALL, callee: 'getindex', args: [objRef].concat(idxRefs) });
    }

    // --- Ternary: cond ? a : b ---

    case 'Ternary':
      return lowerTernary(node, ctx, mod);

    // --- Short-circuit: a && b ---

    case 'And':
      return lowerAnd(node, ctx, mod);

    // --- Short-circuit: a || b ---

    case 'Or':
      return lowerOr(node, ctx, mod);

    // --- Chained comparison: a < b < c ---

    case 'Comparison':
      return lowerComparison(node, ctx, mod);

    // --- Range: start:stop or start:step:stop ---

    case 'Range':
      return lowerRange(node, ctx, mod);

    // --- Tuple literal: (a, b, c) ---

    case 'Tuple': {
      var elems = [];
      for (var k = 0; k < node.elements.length; k++) {
        elems.push(lowerExpr(node.elements[k], ctx, mod));
      }
      return ctx.emit({ kind: STMT_CALL, callee: 'tuple', args: elems });
    }

    // --- Array literal: [a, b, c] ---

    case 'ArrayLit': {
      var aelems = [];
      for (var m = 0; m < node.elements.length; m++) {
        aelems.push(lowerExpr(node.elements[m], ctx, mod));
      }
      return ctx.emit({ kind: STMT_CALL, callee: 'vect', args: aelems });
    }

    // --- Array comprehension: [expr for x in iter] ---

    case 'Comprehension':
      return lowerComprehension(node, ctx, mod);

    // --- Lambda: (x, y) -> expr ---

    case 'Lambda':
      return lowerLambda(node, ctx, mod);

    // --- String interpolation: "Hello $name!" ---

    case 'StringInterp':
      return lowerStringInterp(node, ctx, mod);

    // --- Type annotation: expr::T (strip annotation, keep value) ---

    case 'TypeAnnotation':
      return lowerExpr(node.expr, ctx, mod);

    // --- Type application: T{P} (treat as type name) ---

    case 'TypeApply':
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_ANY, value: node.name });

    // --- Splat: expr... ---

    case 'Splat': {
      var inner = lowerExpr(node.expr, ctx, mod);
      return ctx.emit({ kind: STMT_CALL, callee: '$splat', args: [inner] });
    }

    // --- Block: begin ... end ---

    case 'Block':
      return lowerBlock(node.stmts, ctx, mod);

    // --- Assignment as expression ---

    case 'Assignment':
      return lowerAssignment(node, ctx, mod);

    // --- If as expression ---

    case 'If':
      return lowerIf(node, ctx, mod);

    // --- Let block ---

    case 'Let':
      return lowerLet(node, ctx, mod);

    // --- Keyword argument: name=value ---

    case 'KwArg': {
      // Lower the value; the name is metadata
      return lowerExpr(node.value, ctx, mod);
    }

    // --- Macro call ---

    case 'MacroCall': {
      var expanded = expandMacro(node, mod ? mod.diagnostics : []);
      return lowerExpr(expanded, ctx, mod);
    }

    default:
      // Unknown node kind — emit nothing
      return ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_NOTHING, value: null });
  }
}

// ============================================================
// Binary Operator Lowering
// ============================================================

function lowerBinaryOp(node, ctx, mod) {
  var left = lowerExpr(node.left, ctx, mod);
  var right = lowerExpr(node.right, ctx, mod);
  var callee = BINARY_OP_MAP[node.op] || node.op;
  return ctx.emit({ kind: STMT_CALL, callee: callee, args: [left, right] });
}

// ============================================================
// Function Call Lowering
// ============================================================

function lowerCall(node, ctx, mod) {
  // Special-case: struct constructor — Name(args...)
  if (node.func.kind === 'Identifier' && mod && mod.structDefs[node.func.name]) {
    var sdef = mod.structDefs[node.func.name];
    if (!sdef.abstract) {
      var cArgs = [];
      for (var i = 0; i < node.args.length; i++) {
        cArgs.push(lowerExpr(node.args[i], ctx, mod));
      }
      return ctx.emit({
        kind: STMT_NEW, typeId: sdef.typeId,
        typeName: sdef.name, args: cArgs,
      });
    }
  }

  // Special-case: TypeApply constructor — Vector{Int}() etc.
  if (node.func.kind === 'TypeApply' && mod && mod.structDefs[node.func.name]) {
    var sdef2 = mod.structDefs[node.func.name];
    if (!sdef2.abstract) {
      var cArgs2 = [];
      for (var j = 0; j < node.args.length; j++) {
        cArgs2.push(lowerExpr(node.args[j], ctx, mod));
      }
      return ctx.emit({
        kind: STMT_NEW, typeId: sdef2.typeId,
        typeName: sdef2.name, args: cArgs2,
      });
    }
  }

  // Regular function call
  var calleeName;
  if (node.func.kind === 'Identifier') {
    calleeName = node.func.name;
  } else if (node.func.kind === 'DotAccess') {
    // Qualified call: Math.sin or obj.method
    calleeName = exprToString(node.func);
  } else {
    // Higher-order call: f(args...) where f is a variable
    var calleeRef = lowerExpr(node.func, ctx, mod);
    var hoArgs = [calleeRef];
    for (var k = 0; k < node.args.length; k++) {
      hoArgs.push(lowerExpr(node.args[k], ctx, mod));
    }
    return ctx.emit({ kind: STMT_CALL, callee: '$apply', args: hoArgs });
  }

  var argRefs = [];
  for (var m = 0; m < node.args.length; m++) {
    argRefs.push(lowerExpr(node.args[m], ctx, mod));
  }
  return ctx.emit({ kind: STMT_CALL, callee: calleeName, args: argRefs });
}

// ============================================================
// Short-circuit && and ||
// ============================================================

/**
 * a && b:
 *   If a is false → result = false.
 *   If a is true → result = b.
 */
function lowerAnd(node, ctx, mod) {
  var leftRef = lowerExpr(node.left, ctx, mod);
  var gotoFalse = ctx.emitGotoIfNot(leftRef);

  // Left was true → evaluate right
  var rightRef = lowerExpr(node.right, ctx, mod);
  var gotoMerge = ctx.emitGoto();

  // Left was false
  ctx.patch(gotoFalse, ctx.pos());
  var falseRef = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_BOOL, value: false });
  var falseEnd = ctx.pos() - 1;

  // Merge
  ctx.patch(gotoMerge, ctx.pos());
  return ctx.emit({
    kind: STMT_PHI,
    edges: [
      { from: gotoMerge, val: rightRef },
      { from: falseEnd, val: falseRef },
    ],
  });
}

/**
 * a || b:
 *   If a is true → result = true.
 *   If a is false → result = b.
 */
function lowerOr(node, ctx, mod) {
  var leftRef = lowerExpr(node.left, ctx, mod);
  var gotoRight = ctx.emitGotoIfNot(leftRef);

  // Left was true
  var trueRef = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_BOOL, value: true });
  var gotoMerge = ctx.emitGoto();

  // Left was false → evaluate right
  ctx.patch(gotoRight, ctx.pos());
  var rightRef = lowerExpr(node.right, ctx, mod);
  var rightEnd = ctx.pos() - 1;

  // Merge
  ctx.patch(gotoMerge, ctx.pos());
  return ctx.emit({
    kind: STMT_PHI,
    edges: [
      { from: gotoMerge, val: trueRef },
      { from: rightEnd, val: rightRef },
    ],
  });
}

// ============================================================
// Ternary (if-else expression)
// ============================================================

function lowerTernary(node, ctx, mod) {
  var condRef = lowerExpr(node.condition, ctx, mod);
  var gotoElse = ctx.emitGotoIfNot(condRef);

  // Then branch
  var thenRef = lowerExpr(node.then, ctx, mod);
  var gotoMerge = ctx.emitGoto();

  // Else branch
  ctx.patch(gotoElse, ctx.pos());
  var elseRef = lowerExpr(node['else'], ctx, mod);
  var elseEnd = ctx.pos() - 1;

  // Merge with phi
  ctx.patch(gotoMerge, ctx.pos());
  return ctx.emit({
    kind: STMT_PHI,
    edges: [
      { from: gotoMerge, val: thenRef },
      { from: elseEnd, val: elseRef },
    ],
  });
}

// ============================================================
// Chained Comparison: a < b < c → (a < b) && (b < c)
// ============================================================

function lowerComparison(node, ctx, mod) {
  var operands = [];
  for (var i = 0; i < node.operands.length; i++) {
    operands.push(lowerExpr(node.operands[i], ctx, mod));
  }
  var ops = node.ops;

  if (ops.length === 1) {
    var callee = BINARY_OP_MAP[ops[0]] || ops[0];
    return ctx.emit({ kind: STMT_CALL, callee: callee, args: [operands[0], operands[1]] });
  }

  // Chain: a < b && b < c && c < d ...
  var result = ctx.emit({
    kind: STMT_CALL,
    callee: BINARY_OP_MAP[ops[0]] || ops[0],
    args: [operands[0], operands[1]],
  });
  for (var j = 1; j < ops.length; j++) {
    var next = ctx.emit({
      kind: STMT_CALL,
      callee: BINARY_OP_MAP[ops[j]] || ops[j],
      args: [operands[j], operands[j + 1]],
    });
    // Combine with && (simplified — not short-circuit for chained comparisons)
    result = ctx.emit({ kind: STMT_CALL, callee: '&&', args: [result, next] });
  }
  return result;
}

// ============================================================
// Range: start:stop or start:step:stop
// ============================================================

function lowerRange(node, ctx, mod) {
  var start = lowerExpr(node.start, ctx, mod);
  var stop = lowerExpr(node.stop, ctx, mod);
  if (node.step) {
    var step = lowerExpr(node.step, ctx, mod);
    return ctx.emit({ kind: STMT_CALL, callee: 'colon', args: [start, step, stop] });
  }
  return ctx.emit({ kind: STMT_CALL, callee: 'colon', args: [start, stop] });
}

// ============================================================
// String Interpolation: "Hello $name!" → string("Hello ", name, "!")
// ============================================================

function lowerStringInterp(node, ctx, mod) {
  var args = [];
  for (var i = 0; i < node.parts.length; i++) {
    var part = node.parts[i];
    if (part.kind === 'literal') {
      args.push(ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_STRING, value: part.value }));
    } else if (part.kind === 'name') {
      var ref = ctx.lookup(part.value);
      if (ref) {
        args.push(ref);
      } else {
        args.push(ctx.emit({ kind: STMT_CALL, callee: '$global', args: [], _name: part.value }));
      }
    } else if (part.kind === 'expr') {
      // Expression interpolation $(expr) — tokens need re-parsing
      // Attempt to use JuliaParser if available
      if (part.ast) {
        args.push(lowerExpr(part.ast, ctx, mod));
      } else {
        args.push(ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_ANY, value: null }));
      }
    }
  }
  return ctx.emit({ kind: STMT_CALL, callee: 'string', args: args });
}

// ============================================================
// Comprehension: [expr for x in iter]
// ============================================================

function lowerComprehension(node, ctx, mod) {
  // [expr for var in iter] → result=[]; for var in iter; push!(result, expr); end
  var resultRef = ctx.emit({ kind: STMT_CALL, callee: 'vect', args: [] });
  var resultName = '$comp_' + ctx.pos();
  ctx.setVar(resultName, resultRef);
  ctx.setName(resultRef, resultName);

  // Support first generator (single-loop comprehensions)
  var gen = node.generators && node.generators[0];
  if (gen) {
    var varNode = gen['var'] || gen.name;
    var iterNode = gen.iter;

    // Build a for loop that pushes into result
    var forNode = {
      kind: 'For',
      'var': typeof varNode === 'string' ? { kind: 'Identifier', name: varNode } : varNode,
      iter: iterNode,
      body: [{
        kind: 'Call',
        func: { kind: 'Identifier', name: 'push!' },
        args: [
          { kind: 'Identifier', name: resultName },
          node.expr,
        ],
      }],
    };

    // Add filter condition if present
    if (gen.condition) {
      forNode.body = [{
        kind: 'If',
        condition: gen.condition,
        then: forNode.body,
        elseifs: [],
        'else': null,
      }];
    }

    lowerFor(forNode, ctx, mod);
  }

  return ctx.lookup(resultName) || resultRef;
}

// ============================================================
// Lambda: (x, y) -> expr
// ============================================================

function lowerLambda(node, ctx, mod) {
  var lambdaName = '$lambda_' + ctx.pos();
  var paramNames = [];
  var params = node.params;

  // Handle params: can be array of Param/Identifier/string, or a single Identifier
  if (!Array.isArray(params)) {
    params = [params];
  }
  for (var i = 0; i < params.length; i++) {
    var p = params[i];
    if (typeof p === 'string') paramNames.push(p);
    else if (p && p.kind === 'Identifier') paramNames.push(p.name);
    else if (p && p.kind === 'Param') paramNames.push(p.name);
    else paramNames.push('_a' + i);
  }

  // Lower body in a new context
  var lambdaCtx = new LoweringContext(paramNames);
  var bodyItems = Array.isArray(node.body) ? node.body : [node.body];
  var lastRef = litRef(TYPE_NOTHING);
  for (var j = 0; j < bodyItems.length; j++) {
    // Treat each body item as either a statement or expression
    lastRef = lowerStmt(bodyItems[j], lambdaCtx, mod);
  }

  // Ensure a return at the end
  var lastCode = lambdaCtx.code[lambdaCtx.code.length - 1];
  if (!lastCode || lastCode.kind !== STMT_RETURN) {
    lambdaCtx.emit({ kind: STMT_RETURN, val: lastRef });
  }

  // Register in module
  if (mod) {
    var ir = lambdaCtx.result();
    ir.name = lambdaName;
    mod.functions[lambdaName] = ir;
  }

  return ctx.emit({
    kind: STMT_LITERAL, typeId: TYPE_ANY,
    value: lambdaName, _isFunction: true,
  });
}

// ============================================================
// Statement Lowering — AST statement → SSA ref to last value
// ============================================================

/**
 * Lower a statement AST node. Returns a ref to the last value produced.
 */
function lowerStmt(node, ctx, mod) {
  if (!node) return litRef(TYPE_NOTHING);

  switch (node.kind) {
    // --- Control flow ---

    case 'Assignment':
      return lowerAssignment(node, ctx, mod);

    case 'If':
      return lowerIf(node, ctx, mod);

    case 'While':
      return lowerWhile(node, ctx, mod);

    case 'For':
      return lowerFor(node, ctx, mod);

    case 'TryCatch':
      return lowerTryCatch(node, ctx, mod);

    case 'Return': {
      var val = node.value ? lowerExpr(node.value, ctx, mod) : litRef(TYPE_NOTHING);
      return ctx.emit({ kind: STMT_RETURN, val: val });
    }

    case 'Break': {
      if (ctx.loopStack.length > 0) {
        var loop = ctx.loopStack[ctx.loopStack.length - 1];
        var gotoIdx = ctx.emitGoto();
        loop.breakPatches.push(gotoIdx);
      }
      return litRef(TYPE_NOTHING);
    }

    case 'Continue': {
      if (ctx.loopStack.length > 0) {
        var cloop = ctx.loopStack[ctx.loopStack.length - 1];
        ctx.emit({ kind: STMT_GOTO, dest: cloop.headerIdx });
      }
      return litRef(TYPE_NOTHING);
    }

    case 'Throw': {
      var throwVal = lowerExpr(node.expr, ctx, mod);
      return ctx.emit({ kind: STMT_CALL, callee: 'throw', args: [throwVal] });
    }

    // --- Declarations ---

    case 'Local': {
      for (var li = 0; li < node.names.length; li++) {
        var lref = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_NOTHING, value: null });
        ctx.declareLocal(node.names[li], lref);
        ctx.setName(lref, node.names[li]);
      }
      return litRef(TYPE_NOTHING);
    }

    case 'Global':
      return litRef(TYPE_NOTHING);

    case 'Const': {
      var cval = lowerExpr(node.value, ctx, mod);
      ctx.declareLocal(node.name, cval);
      ctx.setName(cval, node.name);
      return cval;
    }

    // --- Blocks ---

    case 'Block':
      return lowerBlock(node.stmts, ctx, mod);

    case 'Let':
      return lowerLet(node, ctx, mod);

    // --- Definitions ---

    case 'FunctionDef':
      return lowerNestedFunction(node, ctx, mod);

    case 'StructDef': {
      if (mod) lowerStructDef(node, mod);
      return litRef(TYPE_NOTHING);
    }

    case 'AbstractTypeDef': {
      if (mod) {
        mod.structDefs[node.name] = {
          name: node.name, fields: [], mutable: false,
          supertype: node.supertype ? typeExprToName(node.supertype) : null,
          typeId: mod.nextTypeId++, abstract: true,
        };
      }
      return litRef(TYPE_NOTHING);
    }

    // --- Macro ---

    case 'MacroCall': {
      var mexp = expandMacro(node, mod ? mod.diagnostics : []);
      if (Array.isArray(mexp)) {
        var mlast = litRef(TYPE_NOTHING);
        for (var mi = 0; mi < mexp.length; mi++) mlast = lowerStmt(mexp[mi], ctx, mod);
        return mlast;
      }
      return lowerStmt(mexp, ctx, mod);
    }

    // --- Anything else is an expression-as-statement ---

    default:
      return lowerExpr(node, ctx, mod);
  }
}

// ============================================================
// Assignment
// ============================================================

function lowerAssignment(node, ctx, mod) {
  var target = node.target;
  var op = node.op;

  // Compound assignment: x += 1 → x = x + 1
  if (op && op !== '=') {
    var baseOp = op.slice(0, -1); // '+=' → '+'
    var curVal = lowerExpr(target, ctx, mod);
    var rhsVal = lowerExpr(node.value, ctx, mod);
    var callee = BINARY_OP_MAP[baseOp] || baseOp;
    var compVal = ctx.emit({ kind: STMT_CALL, callee: callee, args: [curVal, rhsVal] });
    return assignToTarget(target, compVal, ctx, mod);
  }

  // Tuple destructuring: (a, b) = expr
  if (target.kind === 'Tuple') {
    var tupleRhs = lowerExpr(node.value, ctx, mod);
    for (var i = 0; i < target.elements.length; i++) {
      var elemIdx = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_INT64, value: i + 1 });
      var elemVal = ctx.emit({ kind: STMT_CALL, callee: 'getindex', args: [tupleRhs, elemIdx] });
      assignToTarget(target.elements[i], elemVal, ctx, mod);
    }
    return tupleRhs;
  }

  // Simple assignment
  var val = lowerExpr(node.value, ctx, mod);
  return assignToTarget(target, val, ctx, mod);
}

/**
 * Assign a value ref to a target AST node.
 */
function assignToTarget(target, val, ctx, mod) {
  if (target.kind === 'Identifier') {
    ctx.setVar(target.name, val);
    ctx.setName(val, target.name);
    return val;
  }

  if (target.kind === 'DotAccess') {
    // obj.field = val → setfield!(obj, :field, val)
    var sfObj = lowerExpr(target.object, ctx, mod);
    var sfSym = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_SYMBOL, value: target.field });
    return ctx.emit({ kind: STMT_CALL, callee: 'setfield!', args: [sfObj, sfSym, val] });
  }

  if (target.kind === 'Index') {
    // obj[idx] = val → setindex!(obj, val, idx)
    var siObj = lowerExpr(target.object, ctx, mod);
    var siIdxs = [];
    for (var i = 0; i < target.indices.length; i++) {
      siIdxs.push(lowerExpr(target.indices[i], ctx, mod));
    }
    return ctx.emit({ kind: STMT_CALL, callee: 'setindex!', args: [siObj, val].concat(siIdxs) });
  }

  if (target.kind === 'TypeAnnotation') {
    return assignToTarget(target.expr, val, ctx, mod);
  }

  return val;
}

// ============================================================
// If / Elseif / Else
// ============================================================

/**
 * Lower if/elseif/else to SSA with phi nodes at the merge point.
 * Elseif chains are desugared recursively into nested if-else.
 */
function lowerIf(node, ctx, mod) {
  // Desugar elseif chains into nested if-else
  if (node.elseifs && node.elseifs.length > 0) {
    var firstElseif = node.elseifs[0];
    var restElseifs = node.elseifs.slice(1);
    var nestedElse = {
      kind: 'If',
      condition: firstElseif.condition,
      then: firstElseif.then,
      elseifs: restElseifs,
      'else': node['else'],
    };
    return lowerIf({
      kind: 'If',
      condition: node.condition,
      then: node.then,
      elseifs: [],
      'else': [nestedElse],
    }, ctx, mod);
  }

  // Simple if / else (no elseifs)
  var condRef = lowerExpr(node.condition, ctx, mod);
  var gotoElse = ctx.emitGotoIfNot(condRef);

  // Save environment before branching
  var envBefore = ctx.snapshotEnv();

  // === Then branch ===
  var thenBody = Array.isArray(node.then) ? node.then : [node.then];
  var thenLast = litRef(TYPE_NOTHING);
  for (var i = 0; i < thenBody.length; i++) {
    thenLast = lowerStmt(thenBody[i], ctx, mod);
  }
  var thenEnd = ctx.pos() - 1;
  var envAfterThen = ctx.snapshotEnv();
  var gotoMerge = ctx.emitGoto();

  // === Else branch ===
  ctx.patch(gotoElse, ctx.pos());

  // Restore env to pre-branch state for else
  var it, e;
  for (it = envBefore.entries(), e = it.next(); !e.done; e = it.next()) {
    ctx.restoreVar(e.value[0], e.value[1]);
  }

  var elseLast = litRef(TYPE_NOTHING);
  var hasElse = node['else'] && (Array.isArray(node['else']) ? node['else'].length > 0 : true);
  if (hasElse) {
    var elseBody = Array.isArray(node['else']) ? node['else'] : [node['else']];
    for (var j = 0; j < elseBody.length; j++) {
      elseLast = lowerStmt(elseBody[j], ctx, mod);
    }
  }
  var elseEnd = ctx.pos() - 1;
  var envAfterElse = ctx.snapshotEnv();

  // === Merge point ===
  ctx.patch(gotoMerge, ctx.pos());

  // Emit phi nodes for any variables that differ between branches
  var allNames = new Set();
  for (it = envAfterThen.entries(), e = it.next(); !e.done; e = it.next()) {
    allNames.add(e.value[0]);
  }
  for (it = envAfterElse.entries(), e = it.next(); !e.done; e = it.next()) {
    allNames.add(e.value[0]);
  }

  for (it = allNames.values(), e = it.next(); !e.done; e = it.next()) {
    var name = e.value;
    var thenRef = envAfterThen.get(name);
    var elseRef = envAfterElse.get(name);
    if (!refsEqual(thenRef, elseRef)) {
      var phiEdges = [];
      if (thenRef) phiEdges.push({ from: gotoMerge, val: thenRef });
      if (elseRef) phiEdges.push({ from: elseEnd, val: elseRef });
      if (phiEdges.length >= 2) {
        var phiRef = ctx.emit({ kind: STMT_PHI, edges: phiEdges });
        ctx.restoreVar(name, phiRef);
        ctx.setName(phiRef, name);
      } else if (phiEdges.length === 1) {
        ctx.restoreVar(name, phiEdges[0].val);
      }
    } else {
      // Same in both branches — restore to that value
      ctx.restoreVar(name, thenRef || litRef(TYPE_NOTHING));
    }
  }

  ctx.structure.push({ kind: 'if', condIdx: gotoElse, mergeIdx: ctx.pos() - 1 });

  // If used as expression, return phi of then/else values
  if (hasElse) {
    return ctx.emit({
      kind: STMT_PHI,
      edges: [
        { from: gotoMerge, val: thenLast },
        { from: elseEnd, val: elseLast },
      ],
    });
  }
  return litRef(TYPE_NOTHING);
}

// ============================================================
// While Loop
// ============================================================

function lowerWhile(node, ctx, mod) {
  // Pre-scan body for assigned variable names (needed for phi nodes)
  var assignedNames = collectAssignedNames(node.body);

  // Loop header: emit phi nodes for loop-carried variables
  var headerIdx = ctx.pos();
  var loopPhis = [];  // [{ name, phiIdx, initRef }]

  for (var nameIt = assignedNames.values(), ne = nameIt.next(); !ne.done; ne = nameIt.next()) {
    var vname = ne.value;
    var initRef = ctx.lookup(vname);
    var phiIdx = ctx.emitIdx({ kind: STMT_PHI, edges: [] });
    loopPhis.push({ name: vname, phiIdx: phiIdx, initRef: initRef || litRef(TYPE_NOTHING) });
    ctx.setVar(vname, ssaRef(phiIdx));
    ctx.setName(ssaRef(phiIdx), vname);
  }

  // Lower condition
  var condRef = lowerExpr(node.condition, ctx, mod);
  var gotoExit = ctx.emitGotoIfNot(condRef);

  // Push loop context (for break/continue)
  var loopCtx = { breakPatches: [], headerIdx: headerIdx };
  ctx.loopStack.push(loopCtx);

  // Lower body
  var bodyStmts = Array.isArray(node.body) ? node.body : [node.body];
  for (var i = 0; i < bodyStmts.length; i++) {
    lowerStmt(bodyStmts[i], ctx, mod);
  }

  ctx.loopStack.pop();

  // Back-edge: jump to loop header
  var backEdge = ctx.emitIdx({ kind: STMT_GOTO, dest: headerIdx });

  // Patch phi edges: [init → body → header] loop
  for (var j = 0; j < loopPhis.length; j++) {
    var lp = loopPhis[j];
    var currentRef = ctx.lookup(lp.name) || litRef(TYPE_NOTHING);
    ctx.code[lp.phiIdx].edges = [
      { from: headerIdx > 0 ? headerIdx - 1 : 0, val: lp.initRef },
      { from: backEdge, val: currentRef },
    ];
  }

  // Exit point
  var exitPos = ctx.pos();
  ctx.patch(gotoExit, exitPos);
  for (var k = 0; k < loopCtx.breakPatches.length; k++) {
    ctx.patch(loopCtx.breakPatches[k], exitPos);
  }

  // Restore loop-carried variables to phi refs (not body's last assignments)
  for (var p = 0; p < loopPhis.length; p++) {
    ctx.setVar(loopPhis[p].name, ssaRef(loopPhis[p].phiIdx));
  }

  ctx.structure.push({ kind: 'while', headerIdx: headerIdx, exitIdx: exitPos });
  return litRef(TYPE_NOTHING);
}

// ============================================================
// For Loop — desugars to while
// ============================================================

function lowerFor(node, ctx, mod) {
  var varNode = node['var'];
  var varName;
  if (typeof varNode === 'string') varName = varNode;
  else if (varNode && varNode.kind === 'Identifier') varName = varNode.name;
  else if (varNode && varNode.kind === 'Param') varName = varNode.name;
  else if (varNode && varNode.kind === 'Tuple') varName = null; // destructuring
  else varName = '_it';

  var iterExpr = node.iter;

  // Range loop: for i in start:stop or start:step:stop
  if (iterExpr && iterExpr.kind === 'Range') {
    return lowerForRange(varName, varNode, iterExpr, node.body, ctx, mod);
  }

  // Collection loop: for x in collection
  return lowerForCollection(varName, varNode, iterExpr, node.body, ctx, mod);
}

/**
 * for i in start:stop → while loop with counter.
 * for i in start:step:stop → while loop with step.
 */
function lowerForRange(varName, varNode, rangeExpr, body, ctx, mod) {
  var startRef = lowerExpr(rangeExpr.start, ctx, mod);
  var stopRef = lowerExpr(rangeExpr.stop, ctx, mod);
  var stepRef = rangeExpr.step
    ? lowerExpr(rangeExpr.step, ctx, mod)
    : ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_INT64, value: 1 });

  // If destructuring, use a temp variable name
  var iterVarName = varName || '$for_i_' + ctx.pos();

  // Initialize loop variable
  ctx.setVar(iterVarName, startRef);
  ctx.setName(startRef, iterVarName);

  // Collect assigned names from body
  var assignedNames = collectAssignedNames(body);
  assignedNames.add(iterVarName);

  // Loop header with phi nodes
  var headerIdx = ctx.pos();
  var loopPhis = [];

  for (var nameIt = assignedNames.values(), ne = nameIt.next(); !ne.done; ne = nameIt.next()) {
    var vn = ne.value;
    var initRef = ctx.lookup(vn);
    var phiIdx = ctx.emitIdx({ kind: STMT_PHI, edges: [] });
    loopPhis.push({ name: vn, phiIdx: phiIdx, initRef: initRef || litRef(TYPE_NOTHING) });
    ctx.setVar(vn, ssaRef(phiIdx));
    ctx.setName(ssaRef(phiIdx), vn);
  }

  // Condition: i <= stop
  var iRef = ctx.lookup(iterVarName);
  var condRef = ctx.emit({ kind: STMT_CALL, callee: '<=', args: [iRef, stopRef] });
  var gotoExit = ctx.emitGotoIfNot(condRef);

  // If destructuring, assign tuple elements
  if (varNode && varNode.kind === 'Tuple') {
    for (var ti = 0; ti < varNode.elements.length; ti++) {
      var elem = varNode.elements[ti];
      var tidx = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_INT64, value: ti + 1 });
      var tval = ctx.emit({ kind: STMT_CALL, callee: 'getindex', args: [iRef, tidx] });
      if (elem.kind === 'Identifier') {
        ctx.setVar(elem.name, tval);
        ctx.setName(tval, elem.name);
      }
    }
  }

  // Loop context
  var loopCtx = { breakPatches: [], headerIdx: headerIdx };
  ctx.loopStack.push(loopCtx);

  // Body
  var bodyStmts = Array.isArray(body) ? body : [body];
  for (var i = 0; i < bodyStmts.length; i++) {
    lowerStmt(bodyStmts[i], ctx, mod);
  }

  ctx.loopStack.pop();

  // Increment: i = i + step
  var curI = ctx.lookup(iterVarName);
  var nextI = ctx.emit({ kind: STMT_CALL, callee: '+', args: [curI, stepRef] });
  ctx.setVar(iterVarName, nextI);
  ctx.setName(nextI, iterVarName);

  // Back-edge
  var backEdge = ctx.emitIdx({ kind: STMT_GOTO, dest: headerIdx });

  // Patch phis
  for (var j = 0; j < loopPhis.length; j++) {
    var lp = loopPhis[j];
    var currentRef = ctx.lookup(lp.name) || litRef(TYPE_NOTHING);
    ctx.code[lp.phiIdx].edges = [
      { from: headerIdx > 0 ? headerIdx - 1 : 0, val: lp.initRef },
      { from: backEdge, val: currentRef },
    ];
  }

  // Exit
  var exitPos = ctx.pos();
  ctx.patch(gotoExit, exitPos);
  for (var k = 0; k < loopCtx.breakPatches.length; k++) {
    ctx.patch(loopCtx.breakPatches[k], exitPos);
  }

  // Restore loop-carried variables to phi refs
  for (var rp = 0; rp < loopPhis.length; rp++) {
    ctx.setVar(loopPhis[rp].name, ssaRef(loopPhis[rp].phiIdx));
  }

  ctx.structure.push({ kind: 'for', headerIdx: headerIdx, exitIdx: exitPos, varName: iterVarName });
  return litRef(TYPE_NOTHING);
}

/**
 * for x in collection → _arr=collection; _i=1; _len=length(_arr);
 *   while _i <= _len; x=_arr[_i]; body; _i+=1; end
 */
function lowerForCollection(varName, varNode, iterExpr, body, ctx, mod) {
  var arrRef = lowerExpr(iterExpr, ctx, mod);
  var oneRef = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_INT64, value: 1 });
  var lenRef = ctx.emit({ kind: STMT_CALL, callee: 'length', args: [arrRef] });

  var idxName = '$idx_' + ctx.pos();
  ctx.setVar(idxName, oneRef);

  var iterVarName = varName || '$for_x_' + ctx.pos();

  // Collect assigned names
  var assignedNames = collectAssignedNames(body);
  assignedNames.add(iterVarName);
  assignedNames.add(idxName);

  // Loop header with phis
  var headerIdx = ctx.pos();
  var loopPhis = [];

  for (var nameIt = assignedNames.values(), ne = nameIt.next(); !ne.done; ne = nameIt.next()) {
    var vn = ne.value;
    var initRef = ctx.lookup(vn);
    var phiIdx = ctx.emitIdx({ kind: STMT_PHI, edges: [] });
    loopPhis.push({ name: vn, phiIdx: phiIdx, initRef: initRef || litRef(TYPE_NOTHING) });
    ctx.setVar(vn, ssaRef(phiIdx));
    ctx.setName(ssaRef(phiIdx), vn);
  }

  // Condition: idx <= len
  var curIdx = ctx.lookup(idxName);
  var condRef = ctx.emit({ kind: STMT_CALL, callee: '<=', args: [curIdx, lenRef] });
  var gotoExit = ctx.emitGotoIfNot(condRef);

  // x = arr[idx]
  var elemRef = ctx.emit({ kind: STMT_CALL, callee: 'getindex', args: [arrRef, ctx.lookup(idxName)] });
  ctx.setVar(iterVarName, elemRef);
  ctx.setName(elemRef, iterVarName);

  // Destructuring: for (a, b) in collection
  if (varNode && varNode.kind === 'Tuple') {
    for (var ti = 0; ti < varNode.elements.length; ti++) {
      var elem = varNode.elements[ti];
      var tidx = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_INT64, value: ti + 1 });
      var tval = ctx.emit({ kind: STMT_CALL, callee: 'getindex', args: [elemRef, tidx] });
      if (elem.kind === 'Identifier') {
        ctx.setVar(elem.name, tval);
        ctx.setName(tval, elem.name);
      }
    }
  }

  // Loop context
  var loopCtx = { breakPatches: [], headerIdx: headerIdx };
  ctx.loopStack.push(loopCtx);

  // Body
  var bodyStmts = Array.isArray(body) ? body : [body];
  for (var i = 0; i < bodyStmts.length; i++) {
    lowerStmt(bodyStmts[i], ctx, mod);
  }

  ctx.loopStack.pop();

  // idx += 1
  var curIdxEnd = ctx.lookup(idxName);
  var nextIdx = ctx.emit({ kind: STMT_CALL, callee: '+', args: [curIdxEnd, oneRef] });
  ctx.setVar(idxName, nextIdx);

  // Back-edge
  var backEdge = ctx.emitIdx({ kind: STMT_GOTO, dest: headerIdx });

  // Patch phis
  for (var j = 0; j < loopPhis.length; j++) {
    var lp = loopPhis[j];
    var currentRef2 = ctx.lookup(lp.name) || litRef(TYPE_NOTHING);
    ctx.code[lp.phiIdx].edges = [
      { from: headerIdx > 0 ? headerIdx - 1 : 0, val: lp.initRef },
      { from: backEdge, val: currentRef2 },
    ];
  }

  // Exit
  var exitPos = ctx.pos();
  ctx.patch(gotoExit, exitPos);
  for (var k = 0; k < loopCtx.breakPatches.length; k++) {
    ctx.patch(loopCtx.breakPatches[k], exitPos);
  }

  // Restore loop-carried variables to phi refs
  for (var rp2 = 0; rp2 < loopPhis.length; rp2++) {
    ctx.setVar(loopPhis[rp2].name, ssaRef(loopPhis[rp2].phiIdx));
  }

  ctx.structure.push({ kind: 'for', headerIdx: headerIdx, exitIdx: exitPos, varName: iterVarName });
  return litRef(TYPE_NOTHING);
}

// ============================================================
// Try / Catch / Finally
// ============================================================

function lowerTryCatch(node, ctx, mod) {
  // Emit structure annotations for codegen; infer.js treats as linear flow.
  var structEntry = { kind: 'try', tryStart: ctx.pos() };

  // Try body
  var tryStmts = Array.isArray(node.tryBody) ? node.tryBody : [node.tryBody];
  for (var i = 0; i < tryStmts.length; i++) {
    lowerStmt(tryStmts[i], ctx, mod);
  }
  structEntry.tryEnd = ctx.pos() - 1;
  var gotoAfter = ctx.emitGoto();

  // Catch body
  if (node.catchBody) {
    structEntry.catchStart = ctx.pos();

    // Bind catch variable
    if (node.catchVar) {
      var catchVarName = typeof node.catchVar === 'string'
        ? node.catchVar
        : (node.catchVar.name || String(node.catchVar));
      var errRef = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_ANY, value: null, _isCatchVar: true });
      ctx.setVar(catchVarName, errRef);
      ctx.setName(errRef, catchVarName);
    }

    var catchStmts = Array.isArray(node.catchBody) ? node.catchBody : [node.catchBody];
    for (var j = 0; j < catchStmts.length; j++) {
      lowerStmt(catchStmts[j], ctx, mod);
    }
    structEntry.catchEnd = ctx.pos() - 1;
  }

  // Finally body
  if (node.finallyBody) {
    structEntry.finallyStart = ctx.pos();
    var finallyStmts = Array.isArray(node.finallyBody) ? node.finallyBody : [node.finallyBody];
    for (var k = 0; k < finallyStmts.length; k++) {
      lowerStmt(finallyStmts[k], ctx, mod);
    }
    structEntry.finallyEnd = ctx.pos() - 1;
  }

  // After point
  ctx.patch(gotoAfter, ctx.pos());
  structEntry.afterIdx = ctx.pos();
  ctx.structure.push(structEntry);

  return litRef(TYPE_NOTHING);
}

// ============================================================
// Block / Let
// ============================================================

function lowerBlock(stmts, ctx, mod) {
  var last = litRef(TYPE_NOTHING);
  for (var i = 0; i < stmts.length; i++) {
    last = lowerStmt(stmts[i], ctx, mod);
  }
  return last;
}

function lowerLet(node, ctx, mod) {
  ctx.pushScope();

  // Lower bindings
  if (node.bindings) {
    for (var i = 0; i < node.bindings.length; i++) {
      var b = node.bindings[i];
      if (b.kind === 'Assignment') {
        var val = lowerExpr(b.value, ctx, mod);
        var bname = b.target && b.target.kind === 'Identifier' ? b.target.name : String(b.target);
        ctx.declareLocal(bname, val);
        ctx.setName(val, bname);
      }
    }
  }

  // Lower body
  var bodyStmts = Array.isArray(node.body) ? node.body : [node.body];
  var last = litRef(TYPE_NOTHING);
  for (var j = 0; j < bodyStmts.length; j++) {
    last = lowerStmt(bodyStmts[j], ctx, mod);
  }

  ctx.popScope();
  return last;
}

// ============================================================
// Nested Function Definition
// ============================================================

function lowerNestedFunction(node, ctx, mod) {
  var name = node.name;
  var paramNames = [];
  for (var i = 0; i < node.params.length; i++) {
    var p = node.params[i];
    if (typeof p === 'string') paramNames.push(p);
    else if (p.kind === 'Param') paramNames.push(p.name);
    else if (p.kind === 'Identifier') paramNames.push(p.name);
    else paramNames.push('_a' + i);
  }

  // Lower in a new context
  var funcCtx = new LoweringContext(paramNames);
  var bodyStmts = Array.isArray(node.body) ? node.body : [node.body];
  var lastRef = litRef(TYPE_NOTHING);
  for (var j = 0; j < bodyStmts.length; j++) {
    lastRef = lowerStmt(bodyStmts[j], funcCtx, mod);
  }

  // Auto-return
  var lastCode = funcCtx.code[funcCtx.code.length - 1];
  if (!lastCode || lastCode.kind !== STMT_RETURN) {
    funcCtx.emit({ kind: STMT_RETURN, val: lastRef });
  }

  if (mod) {
    var ir = funcCtx.result();
    ir.name = name;
    ir.paramTypes = node.params.map(function(p) {
      if (p.kind === 'Param' && p.type) return typeExprToName(p.type);
      return 'Any';
    });
    mod.functions[name] = ir;
  }

  // Bind function name in outer scope
  var ref = ctx.emit({ kind: STMT_LITERAL, typeId: TYPE_ANY, value: name, _isFunction: true });
  ctx.setVar(name, ref);
  ctx.setName(ref, name);
  return ref;
}

// ============================================================
// Struct Definition
// ============================================================

function lowerStructDef(node, mod) {
  var fields = [];
  if (node.fields) {
    for (var i = 0; i < node.fields.length; i++) {
      var f = node.fields[i];
      fields.push({
        name: f.name,
        type: f.type ? typeExprToName(f.type) : 'Any',
      });
    }
  }
  mod.registerStruct(
    node.name,
    fields,
    node.mutable,
    node.supertype ? typeExprToName(node.supertype) : null
  );
}

// ============================================================
// Helpers
// ============================================================

/** Convert a type expression AST to a string name. */
function typeExprToName(node) {
  if (!node) return 'Any';
  if (typeof node === 'string') return node;
  if (node.kind === 'Identifier') return node.name;
  if (node.kind === 'TypeApply') {
    var params = (node.params || []).map(typeExprToName);
    return node.name + '{' + params.join(',') + '}';
  }
  return 'Any';
}

/**
 * Collect all variable names assigned anywhere in an AST subtree.
 * Used to determine which variables need phi nodes at loop headers.
 */
function collectAssignedNames(body) {
  var names = new Set();
  var stmts = Array.isArray(body) ? body : [body];
  for (var i = 0; i < stmts.length; i++) {
    _collectAssigned(stmts[i], names);
  }
  return names;
}

function _collectAssigned(node, names) {
  if (!node) return;
  switch (node.kind) {
    case 'Assignment':
      if (node.target) {
        if (node.target.kind === 'Identifier') names.add(node.target.name);
        else if (node.target.kind === 'Tuple') {
          for (var i = 0; i < node.target.elements.length; i++) {
            if (node.target.elements[i].kind === 'Identifier') {
              names.add(node.target.elements[i].name);
            }
          }
        }
      }
      if (node.value) _collectAssigned(node.value, names);
      break;
    case 'If':
      _collectInArray(node.then, names);
      if (node.elseifs) {
        for (var j = 0; j < node.elseifs.length; j++) {
          _collectInArray(node.elseifs[j].then, names);
        }
      }
      _collectInArray(node['else'], names);
      break;
    case 'While':
      _collectInArray(node.body, names);
      break;
    case 'For':
      if (node['var']) {
        if (typeof node['var'] === 'string') names.add(node['var']);
        else if (node['var'].kind === 'Identifier') names.add(node['var'].name);
        else if (node['var'].kind === 'Tuple') {
          for (var k = 0; k < node['var'].elements.length; k++) {
            if (node['var'].elements[k].kind === 'Identifier') {
              names.add(node['var'].elements[k].name);
            }
          }
        }
      }
      _collectInArray(node.body, names);
      break;
    case 'Block':
      _collectInArray(node.stmts, names);
      break;
    case 'TryCatch':
      _collectInArray(node.tryBody, names);
      _collectInArray(node.catchBody, names);
      break;
    case 'Let':
      _collectInArray(node.body, names);
      break;
  }
}

function _collectInArray(arr, names) {
  if (!arr) return;
  var items = Array.isArray(arr) ? arr : [arr];
  for (var i = 0; i < items.length; i++) {
    _collectAssigned(items[i], names);
  }
}

/** Compare two SSA refs for structural equality. */
function refsEqual(a, b) {
  if (a === b) return true;
  if (!a || !b) return false;
  if (typeof a !== 'object' || typeof b !== 'object') return false;
  if ('ssa' in a && 'ssa' in b) return a.ssa === b.ssa;
  if ('arg' in a && 'arg' in b) return a.arg === b.arg;
  if ('lit' in a && 'lit' in b) return a.lit === b.lit;
  return false;
}

// ============================================================
// Module Lowering — top-level entry point
// ============================================================

/**
 * Lower a parsed Julia module/program to IR.
 *
 * Three passes:
 *   1. Register all struct/abstract type definitions
 *   2. Lower all function definitions to SSA IR
 *   3. Lower top-level expressions as a $main function
 *
 * @param {Object} ast - Parser output (kind: 'Module' with body array)
 * @returns {{ functions: Object, structDefs: Object, diagnostics: string[] }}
 */
function lowerModule(ast) {
  var mod = new ModuleContext();
  var stmts = ast.kind === 'Module' ? ast.body : (Array.isArray(ast) ? ast : [ast]);

  // --- Pass 1: Register types ---
  for (var i = 0; i < stmts.length; i++) {
    var s = stmts[i];
    if (s.kind === 'StructDef') {
      lowerStructDef(s, mod);
    } else if (s.kind === 'AbstractTypeDef') {
      mod.structDefs[s.name] = {
        name: s.name, fields: [], mutable: false,
        supertype: s.supertype ? typeExprToName(s.supertype) : null,
        typeId: mod.nextTypeId++, abstract: true,
      };
    }
  }

  // --- Pass 2: Lower function definitions ---
  for (var j = 0; j < stmts.length; j++) {
    var stmt = stmts[j];
    if (stmt.kind === 'FunctionDef') {
      var name = stmt.name;
      var paramNames = [];
      for (var k = 0; k < stmt.params.length; k++) {
        var p = stmt.params[k];
        if (typeof p === 'string') paramNames.push(p);
        else if (p.kind === 'Param') paramNames.push(p.name);
        else if (p.kind === 'Identifier') paramNames.push(p.name);
        else paramNames.push('_a' + k);
      }

      var paramTypes = stmt.params.map(function(pr) {
        if (pr.kind === 'Param' && pr.type) return typeExprToName(pr.type);
        return 'Any';
      });

      var ctx = new LoweringContext(paramNames);
      var bodyStmts = Array.isArray(stmt.body) ? stmt.body : [stmt.body];
      var lastRef = litRef(TYPE_NOTHING);
      for (var m = 0; m < bodyStmts.length; m++) {
        lastRef = lowerStmt(bodyStmts[m], ctx, mod);
      }

      // Auto-return last expression
      var lastCode = ctx.code[ctx.code.length - 1];
      if (!lastCode || lastCode.kind !== STMT_RETURN) {
        ctx.emit({ kind: STMT_RETURN, val: lastRef });
      }

      var ir = ctx.result();
      ir.name = name;
      ir.paramTypes = paramTypes;
      mod.functions[name] = ir;
    }
  }

  // --- Pass 3: Top-level script expressions → $main ---
  var topLevel = [];
  for (var n = 0; n < stmts.length; n++) {
    var ts = stmts[n];
    if (ts.kind !== 'FunctionDef' && ts.kind !== 'StructDef' && ts.kind !== 'AbstractTypeDef') {
      topLevel.push(ts);
    }
  }

  if (topLevel.length > 0) {
    var mainCtx = new LoweringContext([]);
    var mainLast = litRef(TYPE_NOTHING);
    for (var q = 0; q < topLevel.length; q++) {
      mainLast = lowerStmt(topLevel[q], mainCtx, mod);
    }
    var mainLastCode = mainCtx.code[mainCtx.code.length - 1];
    if (!mainLastCode || mainLastCode.kind !== STMT_RETURN) {
      mainCtx.emit({ kind: STMT_RETURN, val: mainLast });
    }
    var mainIr = mainCtx.result();
    mainIr.name = '$main';
    mainIr.paramTypes = [];
    mod.functions['$main'] = mainIr;
  }

  return {
    functions: mod.functions,
    structDefs: mod.structDefs,
    diagnostics: mod.diagnostics,
  };
}

/**
 * Lower a single FunctionDef AST node to IR (standalone, no module context).
 * @param {Object} funcDef - FunctionDef AST node
 * @returns {{ code: Object[], argCount: number, argNames: string[] }}
 */
function lowerFunction(funcDef) {
  var mod = new ModuleContext();
  var paramNames = [];
  for (var i = 0; i < funcDef.params.length; i++) {
    var p = funcDef.params[i];
    if (typeof p === 'string') paramNames.push(p);
    else if (p.kind === 'Param') paramNames.push(p.name);
    else if (p.kind === 'Identifier') paramNames.push(p.name);
    else paramNames.push('_a' + i);
  }

  var ctx = new LoweringContext(paramNames);
  var bodyStmts = Array.isArray(funcDef.body) ? funcDef.body : [funcDef.body];
  var lastRef = litRef(TYPE_NOTHING);
  for (var j = 0; j < bodyStmts.length; j++) {
    lastRef = lowerStmt(bodyStmts[j], ctx, mod);
  }

  var lastCode = ctx.code[ctx.code.length - 1];
  if (!lastCode || lastCode.kind !== STMT_RETURN) {
    ctx.emit({ kind: STMT_RETURN, val: lastRef });
  }

  return ctx.result();
}

// ============================================================
// Convenience: parse + lower in one step
// ============================================================

/**
 * Parse Julia source and lower to IR in one call.
 * Requires parser.js to be loaded (via require or globalThis.JuliaParser).
 *
 * @param {string} source - Julia source code
 * @returns {{ functions: Object, structDefs: Object, diagnostics: string[] }}
 */
function lower(source) {
  var parser;
  if (typeof JuliaParser !== 'undefined') {
    parser = JuliaParser;
  } else if (typeof require !== 'undefined') {
    parser = require('./parser.js');
  } else {
    throw new Error('JuliaParser not available — load parser.js first');
  }

  var parseResult = parser.parse(source);
  var result = lowerModule(parseResult.ast);
  result.diagnostics = (parseResult.diagnostics || []).concat(result.diagnostics);
  return result;
}

// ============================================================
// Exports
// ============================================================

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    // Public API
    lower: lower,
    lowerModule: lowerModule,
    lowerFunction: lowerFunction,
    expandMacro: expandMacro,

    // Classes (for testing/extension)
    LoweringContext: LoweringContext,
    ModuleContext: ModuleContext,

    // Statement kind constants
    STMT_CALL: STMT_CALL,
    STMT_PHI: STMT_PHI,
    STMT_GETFIELD: STMT_GETFIELD,
    STMT_NEW: STMT_NEW,
    STMT_LITERAL: STMT_LITERAL,
    STMT_RETURN: STMT_RETURN,
    STMT_GOTO: STMT_GOTO,
    STMT_GOTOIFNOT: STMT_GOTOIFNOT,
    STMT_PINODE: STMT_PINODE,

    // Type ID constants
    TYPE_ANY: TYPE_ANY,
    TYPE_BOTTOM: TYPE_BOTTOM,
    TYPE_NOTHING: TYPE_NOTHING,
    TYPE_MISSING: TYPE_MISSING,
    TYPE_BOOL: TYPE_BOOL,
    TYPE_INT8: TYPE_INT8,
    TYPE_INT16: TYPE_INT16,
    TYPE_INT32: TYPE_INT32,
    TYPE_INT64: TYPE_INT64,
    TYPE_FLOAT64: TYPE_FLOAT64,
    TYPE_STRING: TYPE_STRING,
    TYPE_CHAR: TYPE_CHAR,
    TYPE_SYMBOL: TYPE_SYMBOL,

    // Ref constructors
    ssaRef: ssaRef,
    argRef: argRef,
    litRef: litRef,

    // Helpers
    typeExprToName: typeExprToName,
    collectAssignedNames: collectAssignedNames,
    refsEqual: refsEqual,
    TYPE_NAME_MAP: TYPE_NAME_MAP,
  };
}

if (typeof globalThis !== 'undefined') {
  globalThis.JuliaLowerer = {
    lower: lower,
    lowerModule: lowerModule,
    lowerFunction: lowerFunction,
    expandMacro: expandMacro,
    STMT_CALL: STMT_CALL,
    STMT_PHI: STMT_PHI,
    STMT_GETFIELD: STMT_GETFIELD,
    STMT_NEW: STMT_NEW,
    STMT_LITERAL: STMT_LITERAL,
    STMT_RETURN: STMT_RETURN,
    STMT_GOTO: STMT_GOTO,
    STMT_GOTOIFNOT: STMT_GOTOIFNOT,
    STMT_PINODE: STMT_PINODE,
    TYPE_ANY: TYPE_ANY,
    TYPE_NOTHING: TYPE_NOTHING,
    TYPE_BOOL: TYPE_BOOL,
    TYPE_INT64: TYPE_INT64,
    TYPE_FLOAT64: TYPE_FLOAT64,
    TYPE_STRING: TYPE_STRING,
  };
}
