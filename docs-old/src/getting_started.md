# Getting Started

## Installation

```julia
using Pkg
Pkg.add("JavaScriptTarget")
```

## Basic Usage

### Compiling a Single Function

```julia
import JavaScriptTarget as JST

# Define a Julia function with type annotations
f(x::Int32, y::Int32) = x * y + 1

# Compile to JavaScript
result = JST.compile(f, (Int32, Int32))
println(result.js)
```

Output:
```javascript
function f(x, y) {
  return (Math.imul(x, y) + 1) | 0;
}
```

### Compiling Multiple Functions

```julia
helper(x::Float64) = x * x
main(x::Float64) = helper(x) + 1.0

result = JST.compile_module([
    (helper, (Float64,)),
    (main, (Float64,)),
]; module_format=:esm)

println(result.js)
```

Output:
```javascript
function helper(x) {
  return x * x;
}
function main(x) {
  return helper(x) + 1.0;
}
export { helper, main };
```

### TypeScript Definitions

Every compilation automatically generates `.d.ts` TypeScript definitions:

```julia
result = JST.compile(f, (Int32, Int32))
println(result.dts)
```

Output:
```typescript
export declare function f(x: number, y: number): number;
```

### Module Formats

The `module_format` option controls the output format:

- `:esm` (default) — ES modules with `export`
- `:cjs` — CommonJS with `module.exports`
- `:iife` — Immediately-invoked function expression
- `:none` — Raw function definitions (useful for testing)

```julia
# CommonJS output
result = JST.compile(f, (Int32, Int32); module_format=:cjs)

# IIFE output
result = JST.compile(f, (Int32, Int32); module_format=:iife)
```

### Source Maps

Enable source maps to map JavaScript output back to Julia source:

```julia
result = JST.compile(f, (Int32, Int32); sourcemap=true)
println(result.sourcemap)  # V3 JSON source map
```

## Working with Structs

Julia structs compile to ES6 classes:

```julia
struct Point
    x::Float64
    y::Float64
end

distance(p::Point) = sqrt(p.x^2 + p.y^2)

result = JST.compile_module([
    (distance, (Point,)),
])
```

Output:
```javascript
class Point {
  constructor(x, y) { this.x = x; this.y = y; }
}
Point.prototype.$type = 100;

function distance(p) {
  return Math.sqrt(p.x * p.x + p.y * p.y);
}
```

## Building the Playground

Generate a self-contained browser playground:

```julia
JST.build_playground("./playground_output"; verbose=true)
```

This creates a directory with all files needed to run Julia in the browser:
- `parser.js` — Julia parser
- `lowerer.js` — AST to SSA IR
- `infer.js` — Type inference engine
- `codegen.js` — IR to JavaScript
- `runtime.js` — Browser runtime helpers
- `worker.js` — Web Worker orchestration
- `types.bin` — Pre-computed type inference tables
- `index.html` — CodeMirror-based playground page
