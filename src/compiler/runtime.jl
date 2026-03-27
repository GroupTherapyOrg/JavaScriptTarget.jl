# Runtime JS helpers that get included when needed.
# Tree-shakeable: only included if the compiled code actually uses them.
# Each helper is a self-contained JS snippet keyed by symbol.

"""
Request a runtime helper be included in the compiled output.
"""
function require_runtime!(ctx, sym::Symbol)
    push!(ctx.required_runtime, sym)
    # Handle dependencies between runtime helpers
    if sym === :jl_mod
        push!(ctx.required_runtime, :jl_fld)
    end
    if sym in (:BoundsError, :DomainError, :OverflowError, :ArgumentError, :KeyError, :DivideError)
        push!(ctx.required_runtime, :JlError)
    end
end

# === Runtime Helper Definitions ===
# Order matters for dependencies: base types first, then dependents.

const RUNTIME_HELPERS = Dict{Symbol, String}(

    # --- Error Types ---
    :JlError => """
class JlError extends Error {
  constructor(msg) { super(msg); this.name = "JlError"; }
}""",

    :BoundsError => """
class BoundsError extends JlError {
  constructor(msg) { super(msg || "BoundsError"); this.name = "BoundsError"; }
}""",

    :DomainError => """
class DomainError extends JlError {
  constructor(msg) { super(msg || "DomainError"); this.name = "DomainError"; }
}""",

    :OverflowError => """
class OverflowError extends JlError {
  constructor(msg) { super(msg || "OverflowError"); this.name = "OverflowError"; }
}""",

    :ArgumentError => """
class ArgumentError extends JlError {
  constructor(msg) { super(msg || "ArgumentError"); this.name = "ArgumentError"; }
}""",

    :KeyError => """
class KeyError extends JlError {
  constructor(msg) { super(msg || "KeyError"); this.name = "KeyError"; }
}""",

    :DivideError => """
class DivideError extends JlError {
  constructor(msg) { super(msg || "DivideError: integer division error"); this.name = "DivideError"; }
}""",

    # --- Struct Equality ---
    :jl_egal => """
function jl_egal(a, b) {
  if (a === b) return true;
  if (a === null || b === null) return false;
  if (typeof a !== "object" || typeof b !== "object") return false;
  if (a.\$type !== b.\$type) return false;
  const keys = Object.keys(a);
  for (let i = 0; i < keys.length; i++) {
    if (!jl_egal(a[keys[i]], b[keys[i]])) return false;
  }
  return true;
}""",

    # --- String Helpers ---
    # Julia length(s::String) counts Unicode codepoints, not UTF-16 code units
    :jl_strlen => """
function jl_strlen(s) {
  let n = 0;
  for (const _ of s) n++;
  return n;
}""",

    # Julia s[i] — 1-based codepoint indexing
    :jl_strindex => """
function jl_strindex(s, i) {
  let k = 0;
  for (const c of s) {
    if (++k === i) return c;
  }
  throw new RangeError("BoundsError: string index " + i);
}""",

    # Julia SubString(s, i, j) — 1-based codepoint range
    :jl_substring => """
function jl_substring(s, i, j) {
  let r = "", k = 0;
  for (const c of s) {
    k++;
    if (k >= i && k <= j) r += c;
    if (k > j) break;
  }
  return r;
}""",

    # --- Math Helpers ---
    # Julia div(a, b) — truncating integer division (same as trunc(a/b))
    :jl_div => """
function jl_div(a, b) {
  if (b === 0) throw new Error("DivideError: integer division error");
  return (a / b) | 0;
}""",

    # Julia fld(a, b) — floor division
    :jl_fld => """
function jl_fld(a, b) {
  if (b === 0) throw new Error("DivideError: integer division error");
  const d = (a / b) | 0;
  return ((a ^ b) < 0 && d * b !== a) ? (d - 1) | 0 : d;
}""",

    # Julia mod(a, b) — modulus (result has same sign as b)
    :jl_mod => """
function jl_mod(a, b) {
  return (a - jl_fld(a, b) * b) | 0;
}""",

    # Julia cld(a, b) — ceiling division
    :jl_cld => """
function jl_cld(a, b) {
  if (b === 0) throw new Error("DivideError: integer division error");
  const d = (a / b) | 0;
  return ((a ^ b) >= 0 && d * b !== a) ? (d + 1) | 0 : d;
}""",

    # Julia copysign(a, b)
    :jl_copysign => """
function jl_copysign(a, b) {
  const abs_a = Math.abs(a);
  return b >= 0 ? abs_a : -abs_a;
}""",

    # --- Bitwise Helpers ---
    # Count trailing zeros (no native JS equivalent)
    :jl_ctz32 => """
function jl_ctz32(a) {
  if (a === 0) return 32;
  let n = 0;
  if ((a & 0xFFFF) === 0) { n += 16; a >>>= 16; }
  if ((a & 0xFF) === 0) { n += 8; a >>>= 8; }
  if ((a & 0xF) === 0) { n += 4; a >>>= 4; }
  if ((a & 0x3) === 0) { n += 2; a >>>= 2; }
  if ((a & 0x1) === 0) { n += 1; }
  return n;
}""",

    # Population count (number of set bits)
    :jl_popcount32 => """
function jl_popcount32(a) {
  a = a - ((a >>> 1) & 0x55555555);
  a = (a & 0x33333333) + ((a >>> 2) & 0x33333333);
  return (((a + (a >>> 4)) & 0x0F0F0F0F) * 0x01010101) >>> 24;
}""",

    # Byte swap
    :jl_bswap32 => """
function jl_bswap32(a) {
  return ((a & 0xFF) << 24) | ((a & 0xFF00) << 8) |
         ((a >>> 8) & 0xFF00) | ((a >>> 24) & 0xFF);
}""",

    # --- Checked Arithmetic ---
    :jl_checked_add => """
function jl_checked_add(a, b) {
  const r = a + b;
  if (((r ^ a) & (r ^ b)) < 0) throw new Error("OverflowError: + overflow");
  return r | 0;
}""",

    :jl_checked_sub => """
function jl_checked_sub(a, b) {
  const r = a - b;
  if (((a ^ b) & (a ^ r)) < 0) throw new Error("OverflowError: - overflow");
  return r | 0;
}""",

    :jl_checked_mul => """
function jl_checked_mul(a, b) {
  const r = Math.imul(a, b);
  if (a !== 0 && (r / a | 0) !== b) throw new Error("OverflowError: * overflow");
  return r;
}""",

    # --- IO ---
    :jl_println => """
function jl_println() {
  const args = Array.prototype.slice.call(arguments);
  console.log(args.join(""));
}""",

    :jl_print => """
function jl_print() {
  const args = Array.prototype.slice.call(arguments);
  const s = args.join("");
  if (typeof process !== "undefined" && process.stdout) {
    process.stdout.write(s);
  } else {
    console.log(s);
  }
}""",

    # --- Object Identity ---
    :jl_objectid => """
const _jl_oid_map = new WeakMap();
let _jl_oid_ctr = 0;
function jl_objectid(x) {
  if (typeof x !== "object" || x === null) return 0;
  let id = _jl_oid_map.get(x);
  if (id === undefined) { id = ++_jl_oid_ctr; _jl_oid_map.set(x, id); }
  return id;
}""",

    :jl_ndarray => """
function jl_ndarray(fill_val, dims) {
  if (dims.length === 1) return new Array(dims[0]).fill(fill_val);
  var a = new Array(dims[0]);
  var rest = dims.slice(1);
  for (var i = 0; i < dims[0]; i++) a[i] = jl_ndarray(fill_val, rest);
  return a;
}""",
)

# Dependency-ordered list of symbols for deterministic output
const RUNTIME_ORDER = [
    :JlError, :BoundsError, :DomainError, :OverflowError, :ArgumentError, :KeyError, :DivideError,
    :jl_egal,
    :jl_strlen, :jl_strindex, :jl_substring,
    :jl_div, :jl_fld, :jl_mod, :jl_cld, :jl_copysign,
    :jl_ctz32, :jl_popcount32, :jl_bswap32,
    :jl_checked_add, :jl_checked_sub, :jl_checked_mul,
    :jl_println, :jl_print,
    :jl_objectid,
    :jl_ndarray,
]

"""
    get_runtime_code(required::Set{Symbol}) -> String

Return JS code for all required runtime helpers, in dependency order.
"""
function get_runtime_code(required::Set{Symbol})
    isempty(required) && return ""
    parts = String[]
    for sym in RUNTIME_ORDER
        if sym in required && haskey(RUNTIME_HELPERS, sym)
            push!(parts, RUNTIME_HELPERS[sym])
        end
    end
    isempty(parts) && return ""
    return "// JavaScriptTarget.jl runtime\n" * join(parts, "\n") * "\n"
end
