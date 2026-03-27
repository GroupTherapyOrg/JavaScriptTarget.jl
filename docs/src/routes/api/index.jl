() -> begin
    card = "border border-warm-200 dark:border-warm-800 rounded-lg p-5 space-y-3"
    code_block = "mt-2 bg-warm-900 dark:bg-warm-950 text-warm-200 p-3 rounded text-xs font-mono overflow-x-auto"
    row = "border-b border-warm-100 dark:border-warm-900"
    jl = "px-4 py-2 font-mono text-accent-600 dark:text-accent-400 text-sm"
    js_col = "px-4 py-2 font-mono text-sm"
    th_cls = "text-left px-4 py-2 border-b-2 border-warm-200 dark:border-warm-700 font-semibold text-warm-700 dark:text-warm-300 text-sm"
    cat_cls = "text-left px-4 py-2 border-b-2 border-warm-200 dark:border-warm-700 font-semibold text-warm-700 dark:text-warm-300 text-sm"
    note = "text-sm text-warm-500 dark:text-warm-500 italic mt-2"

    Div(:class => "space-y-10",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "API Reference"),
        P(:class => "text-warm-600 dark:text-warm-400", "Complete transpilation coverage for JavaScriptTarget.jl. This page documents every supported operation, type mapping, and compilation pattern. For a quick overview, see the ", A(:href => "../getting-started/", :class => "text-accent-500 hover:text-accent-600 underline", "Getting Started"), " guide."),

        # ── Core API ──
        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Core API"),
        Div(:class => "space-y-4",
            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "compile(f, arg_types; kwargs...)"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400", "Transpile a Julia function to JavaScript. Returns a ", Code(:class => "text-accent-500", "JSOutput"), " with ", Code(:class => "text-accent-500", ".js"), ", ", Code(:class => "text-accent-500", ".ts"), ", and ", Code(:class => "text-accent-500", ".exports"), " fields."),
                Pre(:class => code_block, Code(:class => "language-julia", """import JavaScriptTarget as JST

f(x::Int32) = x * x + 1
result = JST.compile(f, (Int32,))

println(result.js)       # JavaScript code
println(result.exports)  # ["f"]""")),
                P(:class => note, "Use optimize=false for functions that build arrays or use broadcasting on constructed arrays.")),

            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "compile_module(functions; kwargs...)"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400", "Transpile multiple functions into a single JS module with shared runtime helpers."),
                Pre(:class => code_block, Code(:class => "language-julia", """result = JST.compile_module([
    (add, (Int32, Int32)),
    (mul, (Float64, Float64))
])""")))
        ),

        # ══════════════════════════════════════════════════════
        # FULLY TRANSPILED
        # ══════════════════════════════════════════════════════
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-200 border-b border-warm-200 dark:border-warm-800 pb-2", "Transpilation Coverage"),
        P(:class => "text-warm-600 dark:text-warm-400", "Everything below is fully transpiled from Julia to JavaScript. Integer operations use ", Code(:class => "text-accent-500", "|0"), " to maintain 32-bit semantics."),

        # ── Types ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Types"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "Int32, Int64"), Td(:class => js_col, "number (integer ops use |0)")),
                    Tr(:class => row, Td(:class => jl, "Float64"), Td(:class => js_col, "number")),
                    Tr(:class => row, Td(:class => jl, "String"), Td(:class => js_col, "string")),
                    Tr(:class => row, Td(:class => jl, "Bool"), Td(:class => js_col, "boolean")),
                    Tr(:class => row, Td(:class => jl, "Nothing"), Td(:class => js_col, "null")),
                    Tr(:class => row, Td(:class => jl, "struct / mutable struct"), Td(:class => js_col, "ES6 class")),
                    Tr(:class => row, Td(:class => jl, "Tuple"), Td(:class => js_col, "Array"))
                )
            )
        ),

        # ── Arithmetic ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Arithmetic & Comparison"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "+, -, *, /, %"), Td(:class => js_col, "Same (integers use |0)")),
                    Tr(:class => row, Td(:class => jl, "<, <=, >, >=, ==, !="), Td(:class => js_col, "<, <=, >, >=, ===, !==")),
                    Tr(:class => row, Td(:class => jl, "&, |, ⊻, <<, >>, >>>"), Td(:class => js_col, "Bitwise ops")),
                    Tr(:class => row, Td(:class => jl, "div(a, b)"), Td(:class => js_col, "jl_div(a, b) — truncating")),
                    Tr(:class => row, Td(:class => jl, "fld(a, b)"), Td(:class => js_col, "jl_fld(a, b) — floor division")),
                    Tr(:class => row, Td(:class => jl, "mod(a, b)"), Td(:class => js_col, "jl_mod(a, b) — sign of b")),
                    Tr(:class => row, Td(:class => jl, "cld(a, b)"), Td(:class => js_col, "jl_cld(a, b) — ceiling division"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """f(a::Int32, b::Int32) = a * b + 1
# → function f(a, b) { return (Math.imul(a, b) + 1) | 0; }""")),

        # ── Math ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Math"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "sin, cos, tan, asin, acos, atan"), Td(:class => js_col, "Math.sin, Math.cos, etc.")),
                    Tr(:class => row, Td(:class => jl, "exp, log, log2, log10"), Td(:class => js_col, "Math.exp, Math.log, etc.")),
                    Tr(:class => row, Td(:class => jl, "sqrt, abs, min, max"), Td(:class => js_col, "Math.sqrt, Math.abs, etc.")),
                    Tr(:class => row, Td(:class => jl, "floor, ceil, round, trunc, sign"), Td(:class => js_col, "Math.floor, Math.ceil, etc.")),
                    Tr(:class => row, Td(:class => jl, "hypot, atan2"), Td(:class => js_col, "Math.hypot, Math.atan2")),
                    Tr(:class => row, Td(:class => jl, "copysign(a, b)"), Td(:class => js_col, "jl_copysign(a, b)"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """f(x::Float64) = sin(x) * exp(-x) + sqrt(abs(x))
# → Math.sin(x) * Math.exp(-x) + Math.sqrt(Math.abs(x))""")),

        # ── 1D Arrays ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "1D Arrays"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "Vector{T}, T[]"), Td(:class => js_col, "Array")),
                    Tr(:class => row, Td(:class => jl, "push!, pop!, append!"), Td(:class => js_col, ".push(), .pop(), .push(...other)")),
                    Tr(:class => row, Td(:class => jl, "length, getindex, setindex!"), Td(:class => js_col, ".length, [i-1], [i-1] = v")),
                    Tr(:class => row, Td(:class => jl, "copy, reverse, empty!"), Td(:class => js_col, ".slice(), [...a].reverse(), .length=0")),
                    Tr(:class => row, Td(:class => jl, "deleteat!"), Td(:class => js_col, ".splice(i-1, 1)")),
                    Tr(:class => row, Td(:class => jl, "sort (with by=, rev=)"), Td(:class => js_col, ".slice().sort(compareFn)")),
                    Tr(:class => row, Td(:class => jl, "in / ∈"), Td(:class => js_col, ".includes()"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """function process(arr::Vector{Int32})::Vector{Int32}
    filtered = filter(x -> x > 0, arr)
    return sort(filtered; rev=true)
end
# → arr.filter(x => x > 0).slice().sort((a, b) => b - a)""")),

        # ── ND Arrays ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "ND Arrays"),
        P(:class => "text-sm text-warm-600 dark:text-warm-400", "Multi-dimensional arrays transpile to nested JavaScript arrays — the native format for JS libraries like Plotly, D3, and TensorFlow.js."),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "zeros(m,n), ones(m,n), fill(v,m,n)"), Td(:class => js_col, "Nested arrays: [[0,0],[0,0]]")),
                    Tr(:class => row, Td(:class => jl, "A[i,j], A[i,j,k]"), Td(:class => js_col, "A[i-1][j-1], A[i-1][j-1][k-1]")),
                    Tr(:class => row, Td(:class => jl, "A[i,j] = val"), Td(:class => js_col, "A[i-1][j-1] = val")),
                    Tr(:class => row, Td(:class => jl, "size(A), size(A,d)"), Td(:class => js_col, "[A.length, A[0].length]")),
                    Tr(:class => row, Td(:class => jl, "length(A)"), Td(:class => js_col, "A.length"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """function make_matrix(m::Int, n::Int)
    A = zeros(m, n)
    for i in 1:m
        for j in 1:n
            A[i,j] = Float64(i + j)
        end
    end
    return A
end
# → [[2,3,4,...],[3,4,5,...],...]  (nested JS arrays)""")),

        # ── Higher-Order ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Higher-Order Functions"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "map(f, arr)"), Td(:class => js_col, "arr.map(f)")),
                    Tr(:class => row, Td(:class => jl, "filter(f, arr)"), Td(:class => js_col, "arr.filter(f)")),
                    Tr(:class => row, Td(:class => jl, "any(f, arr), all(f, arr)"), Td(:class => js_col, "arr.some(f), arr.every(f)")),
                    Tr(:class => row, Td(:class => jl, "findfirst(f, arr)"), Td(:class => js_col, "arr.findIndex(f)+1")),
                    Tr(:class => row, Td(:class => jl, "reduce(f, arr)"), Td(:class => js_col, "arr.reduce(f)"))
                )
            )
        ),

        # ── Strings ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Strings"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "lowercase, uppercase"), Td(:class => js_col, ".toLowerCase(), .toUpperCase()")),
                    Tr(:class => row, Td(:class => jl, "contains, occursin"), Td(:class => js_col, ".includes()")),
                    Tr(:class => row, Td(:class => jl, "startswith, endswith"), Td(:class => js_col, ".startsWith(), .endsWith()")),
                    Tr(:class => row, Td(:class => jl, "split, join"), Td(:class => js_col, ".split(), .join()")),
                    Tr(:class => row, Td(:class => jl, "replace"), Td(:class => js_col, ".replaceAll()")),
                    Tr(:class => row, Td(:class => jl, "strip, lstrip, rstrip"), Td(:class => js_col, ".trim(), .trimStart(), .trimEnd()")),
                    Tr(:class => row, Td(:class => jl, "repeat, chop, chomp, reverse"), Td(:class => js_col, ".repeat(), .slice(0,-1), etc.")),
                    Tr(:class => row, Td(:class => jl, "string(...) concatenation"), Td(:class => js_col, "Template literals"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """f(s::String) = contains(lowercase(s), "hello")
# → s.toLowerCase().includes("hello")""")),

        # ── Broadcasting ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Broadcasting"),
        P(:class => "text-sm text-warm-600 dark:text-warm-400", "Julia's dot-syntax broadcasts compile to chained ", Code(:class => "text-accent-500", ".map()"), " calls. Scalar-array, array-array, and nested broadcasting all work."),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "sin.(x)"), Td(:class => js_col, "x.map(v => Math.sin(v))")),
                    Tr(:class => row, Td(:class => jl, "x .* y (scalar-array)"), Td(:class => js_col, "x.map(v => v * y)")),
                    Tr(:class => row, Td(:class => jl, "x .* y (array-array)"), Td(:class => js_col, "x.map((v,i) => v * y[i])")),
                    Tr(:class => row, Td(:class => jl, "Nested: sin.(x .* f)"), Td(:class => js_col, "Chained .map()"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """f(x::Vector{Float64}, freq::Float64) = sin.(x .* freq)
# → x.map(_b => _b * freq).map(_b => Math.sin(_b))""")),

        # ── Control Flow ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Control Flow"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "if/elseif/else"), Td(:class => js_col, "if/else if/else")),
                    Tr(:class => row, Td(:class => jl, "for i in 1:n (single + nested)"), Td(:class => js_col, "while(true) loops")),
                    Tr(:class => row, Td(:class => jl, "while loops"), Td(:class => js_col, "while loops")),
                    Tr(:class => row, Td(:class => jl, "Short-circuit &&, ||"), Td(:class => js_col, "Same")),
                    Tr(:class => row, Td(:class => jl, "Ternary a ? b : c"), Td(:class => js_col, "Same")),
                    Tr(:class => row, Td(:class => jl, "try/catch"), Td(:class => js_col, "try/catch"))
                )
            )
        ),

        # ── Functions & Structs ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Functions & Structs"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "Named functions"), Td(:class => js_col, "function name() {}")),
                    Tr(:class => row, Td(:class => jl, "Closures (captured variables)"), Td(:class => js_col, "JS closures")),
                    Tr(:class => row, Td(:class => jl, "@noinline functions"), Td(:class => js_col, "Preserved as :invoke in IR")),
                    Tr(:class => row, Td(:class => jl, "struct fields + constructor"), Td(:class => js_col, "class with constructor")),
                    Tr(:class => row, Td(:class => jl, "Field access obj.field"), Td(:class => js_col, "obj.field")),
                    Tr(:class => row, Td(:class => jl, "setfield! (mutable)"), Td(:class => js_col, "obj.field = val"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """struct Point; x::Float64; y::Float64; end
dist(p::Point) = sqrt(p.x^2 + p.y^2)
# → class Point { constructor(x, y) { this.x = x; this.y = y; } }
# → function dist(p) { return Math.sqrt(p.x*p.x + p.y*p.y); }""")),

        # ── Collections ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Collections"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "Dict{K,V}"), Td(:class => js_col, "Map")),
                    Tr(:class => row, Td(:class => jl, "Set{T}"), Td(:class => js_col, "Set")),
                    Tr(:class => row, Td(:class => jl, "Dict: setindex!, getindex, delete!, get, haskey"), Td(:class => js_col, ".set(), .get(), .delete(), .has()")),
                    Tr(:class => row, Td(:class => jl, "Set: push!, delete!, in"), Td(:class => js_col, ".add(), .delete(), .has()"))
                )
            )
        ),

        # ── IO & Escape Hatch ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "IO & Escape Hatch"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "println(...)"), Td(:class => js_col, "console.log(...)")),
                    Tr(:class => row, Td(:class => jl, "print(...)"), Td(:class => js_col, "console.log(...)")),
                    Tr(:class => row, Td(:class => jl, "parse(Int, s)"), Td(:class => js_col, "parseInt(s, 10)")),
                    Tr(:class => row, Td(:class => jl, "parse(Float64, s)"), Td(:class => js_col, "parseFloat(s)")),
                    Tr(:class => row, Td(:class => jl, "typeof, isa"), Td(:class => js_col, "typeof, instanceof")),
                    Tr(:class => row, Td(:class => jl, "convert(T, x)"), Td(:class => js_col, "x (identity)")),
                    Tr(:class => row, Td(:class => jl, "Float64(x), Int(x)"), Td(:class => js_col, "+(x), (x)|0")),
                    Tr(:class => row, Td(:class => jl, "isempty(x)"), Td(:class => js_col, "x.length === 0")),
                    Tr(:class => row, Td(:class => jl, "js(\"raw code\")"), Td(:class => js_col, "Raw JS emission"))
                )
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """js(\"document.title = 'Hello'\")
js(\"console.log('value:', \\\$1)\", my_value)  # \$1 substituted with compiled expression""")),

        # ── Construction ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Construction Helpers"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "zeros(n), ones(n), fill(v,n)"), Td(:class => js_col, "new Array(n).fill(...)")),
                    Tr(:class => row, Td(:class => jl, "zeros(m,n), ones(m,n), fill(v,m,n)"), Td(:class => js_col, "jl_ndarray(val, [m,n]) → nested arrays"))
                )
            )
        ),

        # ── Package Registry ──
        H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-200 mt-6", "Package Registry"),
        P(:class => "text-sm text-warm-600 dark:text-warm-400", "Register custom JavaScript output for any Julia package function. When JST encounters a call to a registered function, it invokes your compiler instead of trying to transpile the Julia implementation."),
        Pre(:class => code_block, Code(:class => "language-julia", """import JavaScriptTarget as JST

JST.register_package_compilation!(MyPkg, :my_func) do ctx, kwargs, pos_args
    items_js = pos_args[1]
    return \"\$(items_js).customMethod()\"
end""")),
        P(:class => note, "Built-in Plotly support: JST.register_plotly_compilations!(MyModule)"),

        # ══════════════════════════════════════════════════════
        # NOT YET TRANSPILED
        # ══════════════════════════════════════════════════════
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-200 border-b border-warm-200 dark:border-warm-800 pb-2 mt-10", "Not Yet Transpiled"),
        P(:class => "text-warm-600 dark:text-warm-400", "These operations are planned but not yet implemented. Contributions welcome."),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Category"), Th(:class => th_cls, "Julia"), Th(:class => th_cls, "Status"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "Linear Algebra"), Td(:class => js_col, "A * B (matrix multiply)"), Td(:class => js_col, "Use manual loops for now")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "transpose(A), A'"), Td(:class => js_col, "Planned")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "det, inv, eigen"), Td(:class => js_col, "Planned (via package registry)")),
                    Tr(:class => row, Td(:class => jl, "Array Ops"), Td(:class => js_col, "reshape(A, m, n)"), Td(:class => js_col, "Planned")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "hcat, vcat"), Td(:class => js_col, "Planned")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "view, @view"), Td(:class => js_col, "Planned")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "enumerate (standalone)"), Td(:class => js_col, "Works in for-loop context")),
                    Tr(:class => row, Td(:class => jl, "Strings"), Td(:class => js_col, "Regex matching"), Td(:class => js_col, "Planned")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "Unicode operations"), Td(:class => js_col, "Basic support via runtime")),
                    Tr(:class => row, Td(:class => jl, "Numbers"), Td(:class => js_col, "rand(), randn()"), Td(:class => js_col, "Planned (Math.random())")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "Complex{T}"), Td(:class => js_col, "Planned")),
                    Tr(:class => row, Td(:class => jl, ""), Td(:class => js_col, "Rational{T}"), Td(:class => js_col, "Not planned"))
                )
            )
        ),

        # ══════════════════════════════════════════════════════
        # WILL NOT TRANSPILE
        # ══════════════════════════════════════════════════════
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-200 border-b border-warm-200 dark:border-warm-800 pb-2 mt-10", "Will Not Transpile"),
        P(:class => "text-warm-600 dark:text-warm-400", "These Julia features cannot be transpiled to browser JavaScript due to fundamental platform constraints."),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Category"), Th(:class => th_cls, "Reason"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "File I/O (open, read, write)"), Td(:class => js_col, "No filesystem in browser")),
                    Tr(:class => row, Td(:class => jl, "Networking (HTTP, sockets)"), Td(:class => js_col, "Browser security model")),
                    Tr(:class => row, Td(:class => jl, "Multi-threading (Threads, @spawn)"), Td(:class => js_col, "JS is single-threaded (use Web Workers separately)")),
                    Tr(:class => row, Td(:class => jl, "Metaprogramming (@eval, eval, Meta.parse)"), Td(:class => js_col, "No Julia runtime in browser")),
                    Tr(:class => row, Td(:class => jl, "C interop (ccall, @ccall)"), Td(:class => js_col, "No native binaries")),
                    Tr(:class => row, Td(:class => jl, "Package loading (using, import at runtime)"), Td(:class => js_col, "Static transpilation only"))
                )
            )
        ),

        # ── optimize=false ──
        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200 mt-10", "optimize=false"),
        P(:class => "text-warm-600 dark:text-warm-400", "Use ", Code(:class => "text-accent-500", "optimize=false"), " for functions that build arrays dynamically. Optimized IR can eliminate array allocations that are needed at runtime."),
        Pre(:class => code_block, Code(:class => "language-julia", """function make_data(n::Int, freq::Float64)
    x = Float64[]
    for i in 1:n
        push!(x, Float64(i) * 0.1)
    end
    y = sin.(x .* freq)
    return (x, y)
end

result = JST.compile(make_data, (Int, Float64); optimize=false)""")),
        P(:class => note, "JST auto-detects when optimize=false is needed and falls back automatically when used via Therapy.jl.")
    )
end
