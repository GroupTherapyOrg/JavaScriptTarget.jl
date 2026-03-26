() -> begin
    card = "border border-warm-200 dark:border-warm-800 rounded-lg p-5 space-y-3"
    code_block = "mt-2 bg-warm-900 dark:bg-warm-950 text-warm-200 p-3 rounded text-xs font-mono overflow-x-auto"

    Div(:class => "space-y-10",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "API Reference"),

        # ── Core API ──
        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Core"),
        Div(:class => "space-y-4",
            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "compile(f, arg_types; kwargs...)"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400", "Compile a Julia function to JavaScript. Returns a ", Code(:class => "text-accent-500", "JSOutput"), " with the JS code, TypeScript declarations, and exports."),
                Pre(:class => code_block, Code(:class => "language-julia", """result = compile(sin, (Float64,))
println(result.js)       # JavaScript code
println(result.exports)  # ["sin"]"""))),

            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "compile_module(functions; kwargs...)"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400", "Compile multiple functions into a single JS module with shared runtime."),
                Pre(:class => code_block, Code(:class => "language-julia", """result = compile_module([
    (add, (Int32, Int32)),
    (mul, (Float64, Float64))
])""")))
        ),

        # ── What Compiles ──
        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Supported Operations"),
        Div(:class => "space-y-4",
            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "Math"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400",
                    "sin, cos, tan, asin, acos, atan, exp, log, log2, log10, sqrt, abs, min, max, floor, ceil, round, trunc, sign, hypot"),
                Pre(:class => code_block, Code(:class => "language-julia", """f(x::Float64) = sin(x) * exp(-x) + sqrt(abs(x))
# → Math.sin(x) * Math.exp(-x) + Math.sqrt(Math.abs(x))"""))),

            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "Arrays"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400",
                    "push!, pop!, append!, length, getindex, setindex!, copy, reverse, sort, filter, map, any, all, in"),
                Pre(:class => code_block, Code(:class => "language-julia", """f(arr) = sort(filter(x -> x > 0, arr))
# → arr.filter(x => x > 0).slice().sort()"""))),

            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "Strings"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400",
                    "lowercase, uppercase, contains, startswith, endswith, split, join, replace, strip, repeat, reverse"),
                Pre(:class => code_block, Code(:class => "language-julia", """f(s) = contains(lowercase(s), "hello")
# → s.toLowerCase().includes("hello")"""))),

            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "Broadcasting"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400",
                    "Dot syntax compiles to ", Code(:class => "text-accent-500", ".map()"), " chains. Nested broadcasting works."),
                Pre(:class => code_block, Code(:class => "language-julia", """f(x) = sin.(x .* 2.0)
# → x.map(_b => _b * 2.0).map(_b => Math.sin(_b))"""))),

            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "Structs & Closures"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400",
                    "Julia structs compile to ES6 classes. Closures compile to JS functions with captured variables."),
                Pre(:class => code_block, Code(:class => "language-julia", """struct Point; x::Float64; y::Float64; end
dist(p::Point) = sqrt(p.x^2 + p.y^2)
# → class Point { constructor(x, y) {...} }
# → function dist(p) { return Math.sqrt(p.x*p.x + p.y*p.y); }""")))
        ),

        # ── Package Registry ──
        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Package Registry"),
        Div(:class => "space-y-4",
            Div(:class => card,
                H3(:class => "font-mono font-semibold text-warm-900 dark:text-warm-100", "register_package_compilation!(fn, mod, name)"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400",
                    "Register a custom JS compilation for a Julia function. When JST encounters a call to ", Code(:class => "text-accent-500", "mod.name"), ", it calls your compiler function instead of trying to compile the Julia implementation."),
                Pre(:class => code_block, Code(:class => "language-julia", """using JavaScriptTarget

# Register a custom compilation for MyPkg.my_func
register_package_compilation!(MyPkg, :my_func) do ctx, kwargs, pos_args
    items_js = pos_args[1]
    return "\$(items_js).customMethod()"
end""")))
        ),

        # ── IO ──
        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "IO & Escape Hatch"),
        Div(:class => card,
            P(:class => "text-sm text-warm-600 dark:text-warm-400",
                Code(:class => "text-accent-500", "println"), " compiles to ", Code(:class => "text-accent-500", "console.log"),
                ". The ", Code(:class => "text-accent-500", "js()"),
                " escape hatch emits raw JavaScript for browser APIs."),
            Pre(:class => code_block, Code(:class => "language-julia", """println("hello")  # → console.log("hello")
js("document.title = 'My App'")  # raw JS""")))
    )
end
