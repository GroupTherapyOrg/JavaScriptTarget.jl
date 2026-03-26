# JavaScriptTarget.jl

A standalone Julia-to-JavaScript transpiler. Compile Julia functions to JavaScript that runs in Node.js or the browser.

## Try it

```@raw html
<div class="playground-embed">
<iframe src="assets/playground/index.html" title="Julia Playground"></iframe>
</div>
```

## Features

- **`compile(f, types)`** — Compile a single Julia function to JavaScript
- **`compile_module(functions)`** — Compile multiple functions into an ES module
- **`.d.ts` generation** — TypeScript definitions with branded types for structs
- **Source maps** — Map JS output back to Julia source lines
- **Self-hosted playground** — Browser-based Julia editor and runner
- **Tree-shakeable runtime** — Only includes helpers your code actually uses

## Quick Start

```julia
import JavaScriptTarget as JST

# Compile a function
f(x::Int32) = x * x + 1
result = JST.compile(f, (Int32,))
println(result.js)
# function f(x) {
#   return (Math.imul(x, x) + 1) | 0;
# }

# Compile multiple functions into a module
helper(x::Float64) = sin(x) + cos(x)
main(x::Float64) = helper(x) * 2.0
result = JST.compile_module([
    (helper, (Float64,)),
    (main, (Float64,)),
]; module_format=:esm)
```

## Installation

```julia
using Pkg
Pkg.add("JavaScriptTarget")
```

## Type Mapping

| Julia Type | JavaScript | Notes |
|---|---|---|
| `Int32` | `number` | All arithmetic gets `\| 0` coercion |
| `Float64` | `number` | No coercion needed |
| `String` | `string` | Direct mapping |
| `Bool` | `boolean` | Direct mapping |
| `Nothing` | `null` | |
| `struct` | ES6 class | `$type` on prototype for dispatch |
| `Vector{T}` | `Array` | 1-indexed access compiled to 0-indexed |
| `Dict{K,V}` | `Map` | |
| `Tuple` | `Array` (readonly) | |
