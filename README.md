<div align="center">

# JavaScriptTarget.jl

Julia-to-JavaScript transpiler.

[![CI](https://github.com/GroupTherapyOrg/JavaScriptTarget.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/GroupTherapyOrg/JavaScriptTarget.jl/actions/workflows/ci.yml)
[![Docs](https://github.com/GroupTherapyOrg/JavaScriptTarget.jl/actions/workflows/docs.yml/badge.svg)](https://grouptherapyorg.github.io/JavaScriptTarget.jl/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

```julia
import JavaScriptTarget as JST

f(x::Int32) = x * x + 1
result = JST.compile(f, (Int32,))

println(result.js)
# function f(x) {
#   return (Math.imul(x, x) + 1) | 0;
# }
```

Includes a self-hosted [browser playground](https://grouptherapyorg.github.io/JavaScriptTarget.jl/) — type Julia, run it as JS, no server needed.

## Transpilation Coverage

### Fully Transpiled

| Category | Julia | JavaScript |
|----------|-------|-----------|
| **Types** | `Int32`, `Int64` | `number` (integer ops use `\|0`) |
| | `Float64` | `number` |
| | `String` | `string` |
| | `Bool` | `boolean` |
| | `Nothing` | `null` |
| | `struct` / `mutable struct` | ES6 `class` |
| | `Tuple` | `Array` |
| **1D Arrays** | `Vector{T}`, `T[]` | `Array` |
| | `push!`, `pop!`, `append!` | `.push()`, `.pop()`, `.push(...other)` |
| | `length`, `getindex`, `setindex!` | `.length`, `[i-1]`, `[i-1] = v` |
| | `copy`, `reverse`, `empty!` | `.slice()`, `[...a].reverse()`, `.length=0` |
| | `deleteat!` | `.splice(i-1, 1)` |
| | `sort` (with `by=`, `rev=`) | `.slice().sort(compareFn)` |
| | `in` / `∈` | `.includes()` |
| **ND Arrays** | `zeros(m,n)`, `ones(m,n)`, `fill(v,m,n)` | Nested `Array` of `Array`: `[[0,0],[0,0]]` |
| | `A[i,j]`, `A[i,j,k]` | `A[i-1][j-1]`, `A[i-1][j-1][k-1]` |
| | `A[i,j] = val` | `A[i-1][j-1] = val` |
| | `size(A)`, `size(A,d)` | `[A.length, A[0].length]`, dimension walk |
| | `length(A)` | `A.length` (outer dimension) |
| **Higher-Order** | `map(f, arr)` | `arr.map(f)` |
| | `filter(f, arr)` | `arr.filter(f)` |
| | `any(f, arr)`, `all(f, arr)` | `arr.some(f)`, `arr.every(f)` |
| | `findfirst(f, arr)` | `arr.findIndex(f)+1` |
| | `reduce(f, arr)` | `arr.reduce(f)` |
| **Strings** | `lowercase`, `uppercase` | `.toLowerCase()`, `.toUpperCase()` |
| | `contains`, `occursin` | `.includes()` |
| | `startswith`, `endswith` | `.startsWith()`, `.endsWith()` |
| | `split`, `join` | `.split()`, `.join()` |
| | `replace` | `.replaceAll()` |
| | `strip`, `lstrip`, `rstrip` | `.trim()`, `.trimStart()`, `.trimEnd()` |
| | `repeat`, `chop`, `chomp`, `reverse` | `.repeat()`, `.slice(0,-1)`, etc. |
| | `string(...)` concatenation | Template literals |
| **Math** | `sin`, `cos`, `tan`, `asin`, `acos`, `atan` | `Math.sin`, `Math.cos`, etc. |
| | `exp`, `log`, `log2`, `log10` | `Math.exp`, `Math.log`, etc. |
| | `sqrt`, `abs`, `min`, `max` | `Math.sqrt`, `Math.abs`, etc. |
| | `floor`, `ceil`, `round`, `trunc`, `sign` | `Math.floor`, etc. |
| | `hypot`, `atan2` | `Math.hypot`, `Math.atan2` |
| **Arithmetic** | `+`, `-`, `*`, `/`, `%` | Same (integers use `\|0`) |
| | `<`, `<=`, `>`, `>=`, `==`, `!=` | `<`, `<=`, `>`, `>=`, `===`, `!==` |
| | `&`, `\|`, `⊻`, `<<`, `>>`, `>>>` | Bitwise ops |
| **Broadcasting** | `sin.(x)` | `x.map(v => Math.sin(v))` |
| | `x .* y` (scalar-array) | `x.map(v => v * y)` |
| | `x .* y` (array-array) | `x.map((v,i) => v * y[i])` |
| | Nested: `sin.(x .* f)` | Chained `.map()` |
| **Control Flow** | `if`/`elseif`/`else` | `if`/`else if`/`else` |
| | `for i in 1:n` (single + nested) | `while(true)` loops |
| | `while` loops | `while` loops |
| | Short-circuit `&&`, `\|\|` | Same |
| | Ternary `a ? b : c` | Same |
| **Functions** | Named functions | `function name() {}` |
| | Closures (captured variables) | JS closures |
| | `@noinline` functions | Preserved as `:invoke` in IR |
| **Structs** | `struct` fields + constructor | `class` with `constructor` |
| | Field access `obj.field` | `obj.field` |
| | `setfield!` (mutable) | `obj.field = val` |
| **Collections** | `Dict{K,V}` | `Map` |
| | `Set{T}` | `Set` |
| | Dict: `setindex!`, `getindex`, `delete!`, `get`, `haskey` | `.set()`, `.get()`, `.delete()`, `.has()` |
| | Set: `push!`, `delete!`, `in` | `.add()`, `.delete()`, `.has()` |
| **IO** | `println(...)` | `console.log(...)` |
| | `print(...)` | `console.log(...)` (no newline) |
| **Parsing** | `parse(Int, s)` | `parseInt(s, 10)` |
| | `parse(Float64, s)` | `parseFloat(s)` |
| **Construction** | `zeros(n)`, `ones(n)`, `fill(v,n)` | `new Array(n).fill(...)` |
| | `zeros(m,n)`, `ones(m,n)`, `fill(v,m,n)` | `jl_ndarray(val, [m,n])` → nested arrays |
| **Other** | `isempty(x)` | `x.length === 0` |
| | `convert(T, x)` | `x` (identity) |
| | `Float64(x)`, `Int(x)` | `+(x)`, `(x)\|0` |
| | `typeof`, `isa` | `typeof`, `instanceof` |
| | `try`/`catch` | `try`/`catch` |
| | `js("raw code")` | Raw JS emission |
| | Package registry | Custom JS for registered packages |

### Not Yet Transpiled (planned)

| Category | Julia | Status |
|----------|-------|--------|
| **Linear Algebra** | `A * B` (matrix multiply) | Use manual loops for now |
| | `transpose(A)`, `A'` | Planned |
| | `det`, `inv`, `eigen` | Planned (via package registry) |
| **Array Ops** | `reshape(A, m, n)` | Planned |
| | `hcat`, `vcat` | Planned |
| | `view`, `@view` | Planned |
| | `enumerate` (standalone) | Works in for-loop context |
| **Strings** | Regex matching | Planned |
| | Unicode operations | Basic support via runtime helpers |
| **Numbers** | `rand()`, `randn()` | Planned (`Math.random()`) |
| | `Complex{T}` | Planned |
| | `Rational{T}` | Not planned |

### Will Not Transpile

| Category | Reason |
|----------|--------|
| File I/O (`open`, `read`, `write`) | No filesystem in browser |
| Networking (`HTTP`, sockets) | Browser security model |
| Multi-threading (`Threads`, `@spawn`) | JS is single-threaded (use Web Workers separately) |
| Metaprogramming (`@eval`, `eval`, `Meta.parse`) | No Julia runtime in browser |
| C interop (`ccall`, `@ccall`) | No native binaries |
| Package loading (`using`, `import` at runtime) | Static transpilation only |

## Arrays and Broadcasting

Use `optimize=false` for functions that build arrays:

```julia
function make_data(n::Int, freq::Float64)
    x = Float64[]
    for i in 1:n
        push!(x, Float64(i) * 0.1)
    end
    y = sin.(x .* freq)
    return (x, y)
end

result = JST.compile(make_data, (Int, Float64); optimize=false)
```

JST auto-detects when `optimize=false` is needed and falls back automatically when used via [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl).

## Package Compilation Registry

Register custom JS output for any Julia package function:

```julia
import JavaScriptTarget as JST

JST.register_package_compilation!(MyPkg, :my_func) do ctx, kwargs, pos_args
    # Return JS code string
    JST.build_js_object_from_kwargs(kwargs)
end
```

Built-in Plotly support: `JST.register_plotly_compilations!(MyModule)`

## `js()` Escape Hatch

For browser APIs that can't be expressed in Julia:

```julia
js("document.title = 'Hello'")
js("console.log('value:', \$1)", my_value)  # $1 substituted with compiled expression
```

## Related

- [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl) — Signals-based web framework using JST for transpilation
- [Sessions.jl](https://github.com/GroupTherapyOrg/Sessions.jl) — Notebook IDE with JST-powered export

## License

MIT
