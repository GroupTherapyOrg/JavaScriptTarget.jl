# Supported Julia Functions in JavaScriptTarget.jl

## Status Legend
- **Supported**: Compiles and runs correctly in Node.js
- **Partial**: Compiles but with limitations
- **Excluded**: Cannot be compiled (depends on C runtime, FFI, etc.)

---

## Arithmetic

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `+` (Int32) | Supported | `(a + b) \| 0` | Always coerced to 32-bit |
| `-` (Int32) | Supported | `(a - b) \| 0` | |
| `*` (Int32) | Supported | `Math.imul(a, b)` | Handles 32-bit overflow |
| `+` (Float64) | Supported | `a + b` | No coercion needed |
| `-` (Float64) | Supported | `a - b` | |
| `*` (Float64) | Supported | `a * b` | |
| `/` (Float64) | Supported | `a / b` | |
| `-` (unary, Float64) | Supported | `-a` | |
| `div(a, b)` | Supported | `(a / b) \| 0` | Julia inlines to intrinsic |
| `fld(a, b)` | Supported | Inlined arithmetic | Floor division |
| `mod(a, b)` | Supported | Inlined arithmetic | Same sign as divisor |
| `cld(a, b)` | Supported | Inlined arithmetic | Ceiling division |
| `rem(a, b)` | Supported | `a % b` | |

## Math Functions

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `sin(x)` | Supported | `Math.sin(x)` | |
| `cos(x)` | Supported | `Math.cos(x)` | |
| `tan(x)` | Supported | `Math.tan(x)` | |
| `asin(x)` | Supported | `Math.asin(x)` | |
| `acos(x)` | Supported | `Math.acos(x)` | |
| `atan(x)` | Supported | `Math.atan(x)` | |
| `exp(x)` | Supported | `Math.exp(x)` | |
| `log(x)` | Supported | `Math.log(x)` | |
| `log2(x)` | Supported | `Math.log2(x)` | |
| `log10(x)` | Supported | `Math.log10(x)` | |
| `sqrt(x)` | Supported | `Math.sqrt(x)` | |
| `abs(x)` (Float64) | Supported | `Math.abs(x)` | |
| `abs(x)` (Int32) | Partial | — | Uses `flipsign_int` (not yet mapped) |
| `floor(x)` | Supported | `Math.floor(x)` | |
| `ceil(x)` | Supported | `Math.ceil(x)` | |
| `trunc(x)` | Supported | `Math.trunc(x)` | |
| `round(x)` | Supported | `Math.round(x)` | |
| `sign(x)` | Supported | Ternary with `Core.ifelse` | |
| `min(a, b)` | Supported | `Math.min(a, b)` | |
| `max(a, b)` | Supported | `Math.max(a, b)` | |
| `hypot(a, b)` | Supported | `Math.hypot(a, b)` | |

## Comparisons

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `==` | Supported | `===` | |
| `!=` | Supported | `!==` | |
| `<` | Supported | `<` | |
| `<=` | Supported | `<=` | |
| `>` | Supported | `>` | |
| `>=` | Supported | `>=` | |
| `===` | Supported | `===` (primitives), `jl_egal` (immutable structs) | |

## Boolean

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `!x` | Supported | `!x` | |
| `&&` | Supported | Short-circuit pattern | |
| `\|\|` | Supported | Short-circuit pattern | |
| `&` (bitwise on Bool) | Partial | `a & b` | Returns number in JS, not boolean |
| `\|` (bitwise on Bool) | Partial | `a \| b` | Returns number in JS, not boolean |

## Bitwise (Int32)

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `&` | Supported | `a & b` | |
| `\|` | Supported | `a \| b` | |
| `xor(a, b)` | Supported | `a ^ b` | |
| `~a` | Supported | `~a` | |
| `<<` | Supported (intrinsic) | `a << b` | Complex IR when used via operators |
| `>>` | Supported (intrinsic) | `a >> b` | |
| `>>>` | Supported (intrinsic) | `a >>> b` | |

## Type Conversions

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `Float64(x::Int32)` | Supported | `+x` | sitofp intrinsic |
| `unsafe_trunc(Int32, x)` | Supported | `Math.trunc(x) \| 0` | fptosi intrinsic |
| `Int32(x::Float64)` | Supported | `Math.trunc(x) \| 0` | |

## String Operations

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `"Hello $x"` | Supported | `` `Hello ${x}` `` | Template literal |
| `string(a, b)` | Supported | `` `${a}${b}` `` | |
| `a * b` (concat) | Supported | `` `${a}${b}` `` | |
| `s ^ n` (repeat) | Supported | `s.repeat(n)` | |
| `==` | Supported | `===` | |
| `startswith(s, p)` | Supported | `s.startsWith(p)` | |
| `endswith(s, p)` | Supported | `s.endsWith(p)` | |
| `isempty(s)` | Supported | `s.length === 0` | Via Core.sizeof |
| `uppercase(s)` | Excluded | — | Julia inlines to `map()` which needs runtime |
| `lowercase(s)` | Excluded | — | Same issue |
| `strip(s)` | Excluded | — | Julia inlines to internal `lstrip`/`rstrip` |
| `occursin(a, b)` | Excluded | — | Julia inlines to `_searchindex` |
| `split(s, d)` | Excluded | — | Julia inlines deeply |
| `replace(s, p=>r)` | Excluded | — | Julia inlines deeply |
| `length(s)` | Partial | — | Julia's codepoint length differs from JS |

## Collections

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `v[i]` (Vector) | Supported | `v[i-1]` | Compile-time index offset |
| `v[i] = x` (Vector) | Supported | `v[i-1] = x` | |
| `length(v)` (Vector) | Supported | `v.length` | |
| `push!(v, x)` | Excluded | — | Julia inlines to 28+ memory ops |
| `pop!(v)` | Excluded | — | Julia inlines deeply |
| `Dict{K,V}()` | Supported | `new Map()` | |
| `d[k] = v` (Dict) | Supported | `d.set(k, v)` | |
| `d[k]` (Dict) | Supported | `d.get(k)` | |
| `delete!(d, k)` | Supported | `d.delete(k)` | |
| `haskey(d, k)` | Excluded | — | Julia inlines to 80-stmt hash probing |
| `Set{T}()` | Supported | `new Set()` | |
| `(a, b)` (Tuple) | Supported | `[a, b]` | |
| `t[1]` (Tuple) | Supported | `t[0]` | |

## Control Flow

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `if/else` | Supported | `if/else` | GotoIfNot pattern |
| `while` | Supported | `while (true) { ... break }` | Backward branch |
| `for i in 1:n` | Supported | While loop with counter | |
| `for x in v` | Supported | While loop with indexing | |
| `&&` / `\|\|` | Supported | Short-circuit chains | |
| `try/catch` | Supported | `try/catch` | |
| `error(msg)` | Supported | `throw new Error(msg)` | |

## Structs

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `struct` construction | Supported | `new ClassName(...)` | ES6 class |
| `obj.field` | Supported | `obj.field` | |
| `obj.field = val` | Supported | `obj.field = val` | Mutable only |
| `isa(x, T)` | Supported | `instanceof` / `$type` range | |
| Parametric types | Supported | Type erasure | `Box{Int32}` → `Box` |
| Abstract type hierarchies | Supported | DFS pre-order type IDs | |

## Functions

| Function | Status | JS Output | Notes |
|---|---|---|---|
| Multi-function modules | Supported | ESM/CJS/IIFE | |
| Closures | Supported | JS function expressions | |
| Higher-order (concrete callee) | Supported | Direct call | |

## IO

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `println(args...)` | Supported | `jl_println(...)` → `console.log` | Runtime helper |
| `print(args...)` | Supported | `jl_print(...)` → `process.stdout.write` | Runtime helper |

## Known Limitations

1. **Cross-referencing phi nodes in loops**: Functions with patterns like `a, b = b, a+b` (fibonacci) produce incorrect results due to sequential phi assignment. Needs temp variables.
2. **Deeply inlined Base functions**: `push!`, `pop!`, `haskey`, `uppercase`, `lowercase`, `strip`, `occursin`, `split`, `replace` get inlined by Julia into internal operations that can't be mapped to JS. These need either runtime wrappers or `optimize=false` mode.
3. **Bool bitwise ops**: `&` and `|` on Bool produce numbers (0/1) in JS, not booleans.
4. **Int32 abs**: Uses `flipsign_int` intrinsic not yet mapped.
5. **String length**: Julia counts codepoints, JS `.length` counts UTF-16 code units.
