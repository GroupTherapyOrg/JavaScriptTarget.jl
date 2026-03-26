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

## What Transpiles

| Julia | JavaScript |
|---|---|
| `Int32`, `Int64` | `number` (integer ops use `\|0`) |
| `Float64` | `number` |
| `String` | `string` |
| `Bool` | `boolean` |
| `Vector{T}` | `Array` (`push!`, `getindex`, `length`) |
| `Dict{K,V}` | `Map` |
| `struct` | ES6 `class` |
| `sin`, `cos`, `sqrt`, ... | `Math.sin`, `Math.cos`, `Math.sqrt` |
| `println` | `console.log` |
| `sin.(x)` | `x.map(v => Math.sin(v))` |
| `x .* freq` | `x.map(v => v * freq)` |
| `for i in 1:n` | `while` loop |

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

Produces:
```javascript
function make_data(n, freq) {
  x = [];
  // ... for loop with x.push() ...
  y = x.map(_b => _b * freq).map(_b => Math.sin(_b));
  return [x, y];
}
```

JST auto-detects when `optimize=false` is needed (when the optimized IR contains Julia's internal memory management) and falls back automatically when used via [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl).

## Package Compilation Registry

JST can transpile calls to registered Julia packages into their JavaScript equivalents — instead of transpiling the package's internal implementation.

### Registering a Package

```julia
import JavaScriptTarget as JST

# Register a function: (module, function_name) → JS compiler
JST.register_package_compilation!(MyPlotLib, :scatter) do ctx, kwargs, pos_args
    # kwargs: Dict{Symbol, String} — compiled keyword argument values
    # pos_args: Vector{String} — compiled positional argument values
    # Return a JS code string
    JST.build_js_object_from_kwargs(kwargs; type="scatter")
end
```

The compiler function receives:
- `ctx` — compilation context
- `kwargs` — keyword arguments as `Dict{Symbol, String}` (kwarg name → compiled JS expression)
- `pos_args` — positional arguments as `Vector{String}` (compiled JS expressions)

### Built-in: Plotly

JST ships with Plotly mappings. Register them for any module that exports `scatter`, `Layout`, etc.:

```julia
# Register your module's Plotly-compatible functions
JST.register_plotly_compilations!(MyModule)
```

This maps:

| Julia | JavaScript |
|---|---|
| `scatter(x=x, y=y, mode="lines")` | `{"type":"scatter", "x":x, "y":y, "mode":"lines"}` |
| `Layout(title="Test", xaxis=...)` | `{"title":"Test", "xaxis":...}` |
| `plotly("div-id", traces, layout)` | `Plotly.newPlot(el, traces, layout)` / `Plotly.react(...)` |

### Adding Your Own Package

```julia
module MyPackage
    import JavaScriptTarget as JST

    # Define Julia functions
    my_chart(; data, options=nothing) = Dict("data" => data, "options" => options)

    # Register compilation
    function __init__()
        JST.register_package_compilation!(@__MODULE__, :my_chart) do ctx, kwargs, pos_args
            JST.build_js_object_from_kwargs(kwargs)
        end
    end
end
```

When JST encounters `MyPackage.my_chart(data=x, options=cfg)` in compiled code, it emits `{"data": x, "options": cfg}` instead of trying to compile the function's Julia implementation.

### How It Works

1. Julia's `code_typed` lowers keyword calls to `Core.kwcall(NamedTuple{names}(values), func)`
2. JST extracts the kwarg names from the NamedTuple type parameters
3. The registered compiler function receives the compiled kwarg values
4. The compiler emits the JS equivalent (object literals, function calls, etc.)

The registry is checked for both keyword calls (`Core.kwcall`) and positional calls. Functions are matched by `(parentmodule(fn), nameof(fn))`.

## `js()` Escape Hatch

For direct browser API access, `js()` emits raw JavaScript:

```julia
js("document.title = 'Hello'")
js("console.log('value:', \$1)", my_value)  # $1 substituted with compiled expression
```

## Related

- [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl) — Signals-based web framework using JST for transpilation
- [Sessions.jl](https://github.com/GroupTherapyOrg/Sessions.jl) — Notebook IDE with JST-powered export

## License

MIT
