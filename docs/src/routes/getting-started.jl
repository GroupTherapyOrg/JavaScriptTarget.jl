() -> begin
    row = "border-b border-warm-100 dark:border-warm-900"
    jl = "px-4 py-2 font-mono text-accent-600 dark:text-accent-400"
    js_col = "px-4 py-2 font-mono"
    th_cls = "text-left px-4 py-2 border-b-2 border-warm-200 dark:border-warm-700 font-semibold text-warm-700 dark:text-warm-300"

    Div(:class => "space-y-8",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "Getting Started"),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Installation"),
        Pre(:class => "bg-warm-900 dark:bg-warm-950 p-4 rounded border border-warm-800", Code(:class => "language-julia", """using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/JavaScriptTarget.jl")""")),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Basic Usage"),
        P(:class => "text-warm-600 dark:text-warm-400", "Write a Julia function with typed arguments, then transpile to JavaScript:"),
        Pre(:class => "bg-warm-900 dark:bg-warm-950 p-4 rounded border border-warm-800", Code(:class => "language-julia", """using JavaScriptTarget

function add(a::Int32, b::Int32)::Int32
    return a + b
end

result = compile(add, (Int32, Int32))
println(result.js)
# Output: function add(a, b) { return (a + b) | 0; }""")),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Type Mappings"),
        P(:class => "text-warm-600 dark:text-warm-400", "Julia types map naturally to JavaScript. This table shows the core type mappings — see the ", A(:href => "./api/", :class => "text-accent-500 hover:text-accent-600 underline", "full API reference"), " for comprehensive coverage of 80+ supported operations across math, strings, arrays, broadcasting, structs, and more."),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(Th(:class => th_cls, "Julia"), Th(:class => th_cls, "JavaScript"))),
                Tbody(
                    Tr(:class => row, Td(:class => jl, "Int32, Int64"), Td(:class => js_col, "number | 0")),
                    Tr(:class => row, Td(:class => jl, "Float64"), Td(:class => js_col, "number")),
                    Tr(:class => row, Td(:class => jl, "String"), Td(:class => js_col, "string")),
                    Tr(:class => row, Td(:class => jl, "Bool"), Td(:class => js_col, "boolean")),
                    Tr(:class => row, Td(:class => jl, "Vector{T}"), Td(:class => js_col, "Array")),
                    Tr(:class => row, Td(:class => jl, "Matrix{T} (ND arrays)"), Td(:class => js_col, "Nested Array: [[row1], [row2]]")),
                    Tr(:class => row, Td(:class => jl, "Dict{K,V}"), Td(:class => js_col, "Map")),
                    Tr(:class => row, Td(:class => jl, "Set{T}"), Td(:class => js_col, "Set")),
                    Tr(:class => row, Td(:class => jl, "struct"), Td(:class => js_col, "ES6 class")),
                    Tr(:class => row, Td(:class => jl, "Tuple"), Td(:class => js_col, "Array")),
                    Tr(:class => row, Td(:class => jl, "Nothing"), Td(:class => js_col, "null"))
                )
            )
        ),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "With Therapy.jl"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "JST powers ", A(:href => "https://grouptherapyorg.github.io/Therapy.jl/", :target => "_blank", :class => "text-accent-500 hover:text-accent-600 underline", "Therapy.jl"),
            "'s ", Code(:class => "font-mono text-accent-500", "@island"),
            " components. Write Julia → JST transpiles to inline JS → browser hydrates."),
        Pre(:class => "bg-warm-900 dark:bg-warm-950 p-4 rounded border border-warm-800", Code(:class => "language-julia", """using Therapy

@island function Counter(; initial::Int = 0)
    count, set_count = create_signal(initial)
    return Div(
        Button(:on_click => () -> set_count(count() + 1), "+"),
        Span(count)
    )
end
# → Transpiles to ~500 bytes of inline JavaScript"""))
    )
end
