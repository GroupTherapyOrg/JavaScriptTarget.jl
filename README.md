# JavaScriptTarget.jl

[![CI](https://github.com/GroupTherapyOrg/JavaScriptTarget.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/GroupTherapyOrg/JavaScriptTarget.jl/actions/workflows/ci.yml)
[![Docs](https://github.com/GroupTherapyOrg/JavaScriptTarget.jl/actions/workflows/docs.yml/badge.svg)](https://grouptherapyorg.github.io/JavaScriptTarget.jl/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Compile Julia functions to JavaScript.

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
