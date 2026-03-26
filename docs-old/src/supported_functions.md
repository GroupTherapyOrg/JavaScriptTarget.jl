# Supported Functions

This page lists every Base function's compilation status: **Supported** (compiles and runs correctly), **Partial** (compiles with limitations), or **Excluded** (cannot be compiled).

Each supported function includes a runnable example you can paste into the [Playground](index.md).

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
| `-` (unary) | Supported | `-a` | |
| `div(a, b)` | Supported | `(a / b) \| 0` | Julia inlines to intrinsic |
| `fld(a, b)` | Supported | Inlined arithmetic | Floor division |
| `mod(a, b)` | Supported | Inlined arithmetic | Same sign as divisor |
| `cld(a, b)` | Supported | Inlined arithmetic | Ceiling division |
| `rem(a, b)` | Supported | `a % b` | |

**Example:**
```julia
function arithmetic_demo(a, b)
    println(a + b)
    println(a * b)
    println(a / b)
    println(a ^ 2)
end
arithmetic_demo(3, 4)
```

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

**Example:**
```julia
function math_demo(x)
    println(sin(x))
    println(sqrt(x))
    println(floor(x))
    println(abs(-x))
    println(min(x, 10.0))
end
math_demo(3.14)
```

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

**Example:**
```julia
println(3 > 2)
println(3 == 3)
println(3 != 4)
println(5 <= 5)
```

## Boolean

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `!x` | Supported | `!x` | |
| `&&` | Supported | Short-circuit pattern | |
| `\|\|` | Supported | Short-circuit pattern | |
| `&` (bitwise on Bool) | Partial | `a & b` | Returns number in JS, not boolean |
| `\|` (bitwise on Bool) | Partial | `a \| b` | Returns number in JS, not boolean |

**Example:**
```julia
println(!false)
println(true)
function check(x)
    if x > 0
        return true
    else
        return false
    end
end
println(check(5))
println(check(-3))
```

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

**Example (compiler):**
```julia
import JavaScriptTarget as JST

greet(name::String) = "Hello " * name * "!"
result = JST.compile(greet, (String,))
println(result.js)
```

**Example (playground):**
```julia
println(string("Hello", " ", "World"))
println(uppercase("abc"))
println(startswith("foobar", "foo"))
println(length("test"))
```

!!! note "Playground vs Compiler"
    The playground's codegen handles `uppercase`, `lowercase`, `strip`, `split`, and `replace` as named function calls mapped to JS builtins. These work in the playground but not via `compile()` where Julia inlines them.

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

**Example:**
```julia
a = [10, 20, 30, 40, 50]
println(a[1])
println(a[3])
println(length(a))
```

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

**Example:**
```julia
function fizzbuzz(n)
    for i in 1:n
        if i > 15 * (i / 15 |> floor)
            if i > 3 * (i / 3 |> floor)
                if i > 5 * (i / 5 |> floor)
                    println(i)
                else
                    println("Buzz")
                end
            else
                println("Fizz")
            end
        else
            println("FizzBuzz")
        end
    end
end
fizzbuzz(15)
```

## Structs

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `struct` construction | Supported | `new ClassName(...)` | ES6 class |
| `obj.field` | Supported | `obj.field` | |
| `obj.field = val` | Supported | `obj.field = val` | Mutable only |
| `isa(x, T)` | Supported | `instanceof` / `$type` range | |
| Parametric types | Supported | Type erasure | `Box{Int32}` → `Box` |
| Abstract type hierarchies | Supported | DFS pre-order type IDs | |

**Example:**
```julia
struct Point
    x
    y
end

function distance(p)
    return sqrt(p.x * p.x + p.y * p.y)
end

p = Point(3.0, 4.0)
println(p.x)
println(p.y)
println(distance(p))
```

## Functions

| Function | Status | JS Output | Notes |
|---|---|---|---|
| Multi-function modules | Supported | ESM/CJS/IIFE | |
| Closures | Supported | JS function expressions | |
| Higher-order (concrete callee) | Supported | Direct call | |
| Pipe operator (`\|>`) | Supported | `f(x)` | |

**Example:**
```julia
function square(x)
    return x * x
end

function sum_of_squares(n)
    s = 0
    for i in 1:n
        s = s + square(i)
    end
    return s
end

println(sum_of_squares(10))
```

## IO

| Function | Status | JS Output | Notes |
|---|---|---|---|
| `println(args...)` | Supported | `jl_println(...)` → `console.log` | Runtime helper |
| `print(args...)` | Supported | `jl_print(...)` → `process.stdout.write` | Runtime helper |

## Known Limitations

1. **Deeply inlined Base functions**: `push!`, `pop!`, `haskey`, `uppercase`, `lowercase`, `strip`, `occursin`, `split`, `replace` get inlined by Julia into internal operations that can't be mapped to JS via `compile()`. The playground handles these as named functions.
2. **Bool bitwise ops**: `&` and `|` on Bool produce numbers (0/1) in JS, not booleans.
3. **Int32 abs**: Uses `flipsign_int` intrinsic not yet mapped.
4. **String length**: Julia counts codepoints, JS `.length` counts UTF-16 code units.
5. **Nested try/catch**: Single-level try/catch works; nested try/catch may not work correctly in the playground.
