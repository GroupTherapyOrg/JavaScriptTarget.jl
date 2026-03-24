// runtime.js — Browser runtime for the Julia playground
// Provides output capture, execution sandbox, and additional helpers.
// NOT transpiled from Julia — hand-written JS.
//
// Selfhost spec §6. Target: ~10 KB gzip.

'use strict';

// ============================================================
// Output Capture
// ============================================================

var _jl_output = [];

/**
 * Capture output from compiled code. Used by the playground to
 * display results instead of writing to console.
 */
function jl_capture_reset() {
  _jl_output = [];
}

function jl_capture_get() {
  return _jl_output.join('');
}

/**
 * Override jl_println/jl_print to capture output.
 * The codegen inlines its own jl_println, but we redefine it here
 * so the playground captures output instead of just console.log.
 */
function jl_println() {
  var a = [];
  for (var i = 0; i < arguments.length; i++) {
    var v = arguments[i];
    a.push(v === null ? 'nothing' : v === undefined ? 'missing' : String(v));
  }
  _jl_output.push(a.join('') + '\n');
}

function jl_print() {
  var a = [];
  for (var i = 0; i < arguments.length; i++) {
    var v = arguments[i];
    a.push(v === null ? 'nothing' : v === undefined ? 'missing' : String(v));
  }
  _jl_output.push(a.join(''));
}

// ============================================================
// String Helpers
// ============================================================

function jl_string() {
  var s = '';
  for (var i = 0; i < arguments.length; i++) {
    var v = arguments[i];
    s += (v === null ? 'nothing' : v === undefined ? 'missing' : String(v));
  }
  return s;
}

function jl_strlen(s) {
  var n = 0;
  for (var _c of s) n++;
  return n;
}

function jl_strindex(s, i) {
  var k = 0;
  for (var c of s) {
    if (++k === i) return c;
  }
  throw new Error('BoundsError: string index ' + i);
}

function jl_substring(s, i, j) {
  var r = '', k = 0;
  for (var c of s) {
    k++;
    if (k >= i && k <= j) r += c;
    if (k > j) break;
  }
  return r;
}

// ============================================================
// Struct Equality (immutable ===)
// ============================================================

function jl_egal(a, b) {
  if (a === b) return true;
  if (a === null || b === null) return false;
  if (typeof a !== 'object' || typeof b !== 'object') return false;
  var ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (var i = 0; i < ka.length; i++) {
    if (!jl_egal(a[ka[i]], b[ka[i]])) return false;
  }
  return true;
}

// ============================================================
// Error Types
// ============================================================

function JlError(msg) {
  this.message = String(msg);
  this.name = 'JlError';
}
JlError.prototype = Object.create(Error.prototype);
JlError.prototype.constructor = JlError;

// ============================================================
// Math Helpers
// ============================================================

function jl_div(a, b) { return (a / b) | 0; }
function jl_fld(a, b) { return Math.floor(a / b); }
function jl_mod(a, b) { return a - jl_fld(a, b) * b; }
function jl_cld(a, b) { return Math.ceil(a / b) | 0; }

function jl_copysign(a, b) {
  var abs_a = Math.abs(a);
  return b >= 0 ? abs_a : -abs_a;
}

// ============================================================
// Checked Arithmetic
// ============================================================

function jl_checked_add(a, b) {
  var r = a + b;
  if (((r ^ a) & (r ^ b)) < 0) throw new Error('OverflowError: + overflow');
  return r | 0;
}

function jl_checked_sub(a, b) {
  var r = a - b;
  if (((a ^ b) & (a ^ r)) < 0) throw new Error('OverflowError: - overflow');
  return r | 0;
}

function jl_checked_mul(a, b) {
  var r = Math.imul(a, b);
  if (a !== 0 && (r / a | 0) !== b) throw new Error('OverflowError: * overflow');
  return r;
}

// ============================================================
// Execution Sandbox
// ============================================================

/**
 * Execute compiled JavaScript code and capture output.
 * Returns { output: string, result: any, error: string|null }.
 */
function jl_execute(jsCode) {
  jl_capture_reset();
  var result = undefined;
  var error = null;
  try {
    // The compiled code may redefine jl_println etc., but our versions
    // above take precedence when we prepend the runtime.
    // Use Function constructor for sandboxed execution.
    var fn = new Function(jsCode);
    result = fn();
  } catch (e) {
    error = e.name + ': ' + e.message;
  }
  return {
    output: jl_capture_get(),
    result: result,
    error: error
  };
}

// ============================================================
// Exports
// ============================================================

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    jl_capture_reset: jl_capture_reset,
    jl_capture_get: jl_capture_get,
    jl_println: jl_println,
    jl_print: jl_print,
    jl_string: jl_string,
    jl_strlen: jl_strlen,
    jl_strindex: jl_strindex,
    jl_substring: jl_substring,
    jl_egal: jl_egal,
    JlError: JlError,
    jl_div: jl_div,
    jl_fld: jl_fld,
    jl_mod: jl_mod,
    jl_cld: jl_cld,
    jl_copysign: jl_copysign,
    jl_checked_add: jl_checked_add,
    jl_checked_sub: jl_checked_sub,
    jl_checked_mul: jl_checked_mul,
    jl_execute: jl_execute,
  };
}

if (typeof globalThis !== 'undefined') {
  globalThis.JuliaRuntime = {
    execute: jl_execute,
    captureReset: jl_capture_reset,
    captureGet: jl_capture_get,
  };
}
