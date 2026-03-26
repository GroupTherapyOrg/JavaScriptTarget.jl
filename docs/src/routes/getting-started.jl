() -> begin
    Div(:class => "space-y-8",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "Getting Started"),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Installation"),
        Pre(:class => "bg-warm-900 dark:bg-warm-950 p-4 rounded border border-warm-800", Code(:class => "language-julia", """using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/JavaScriptTarget.jl")""")),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Basic Usage"),
        P(:class => "text-warm-600 dark:text-warm-400", "Write a Julia function with typed arguments, then compile it to JavaScript:"),
        Pre(:class => "bg-warm-900 dark:bg-warm-950 p-4 rounded border border-warm-800", Code(:class => "language-julia", """using JavaScriptTarget

# Define a Julia function with typed arguments
function add(a::Int32, b::Int32)::Int32
    return a + b
end

# Compile to JavaScript
result = compile(add, (Int32, Int32))
println(result.js)
# Output: function add(a, b) { return (a + b) | 0; }""")),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "What Compiles"),
        P(:class => "text-warm-600 dark:text-warm-400", "JST compiles Julia's typed IR to JavaScript. Types map naturally:"),
        Div(:class => "overflow-x-auto",
            Table(:class => "w-full text-sm",
                Thead(Tr(
                    Th(:class => "text-left px-4 py-2 border-b-2 border-warm-200 dark:border-warm-700 text-warm-700 dark:text-warm-300", "Julia"),
                    Th(:class => "text-left px-4 py-2 border-b-2 border-warm-200 dark:border-warm-700 text-warm-700 dark:text-warm-300", "JavaScript")
                )),
                Tbody(
                    Tr(:class => "border-b border-warm-100 dark:border-warm-900",
                        Td(:class => "px-4 py-2 font-mono text-accent-600 dark:text-accent-400", "Int32, Int64"),
                        Td(:class => "px-4 py-2 font-mono", "number | 0")),
                    Tr(:class => "border-b border-warm-100 dark:border-warm-900",
                        Td(:class => "px-4 py-2 font-mono text-accent-600 dark:text-accent-400", "Float64"),
                        Td(:class => "px-4 py-2 font-mono", "number")),
                    Tr(:class => "border-b border-warm-100 dark:border-warm-900",
                        Td(:class => "px-4 py-2 font-mono text-accent-600 dark:text-accent-400", "String"),
                        Td(:class => "px-4 py-2 font-mono", "string")),
                    Tr(:class => "border-b border-warm-100 dark:border-warm-900",
                        Td(:class => "px-4 py-2 font-mono text-accent-600 dark:text-accent-400", "Vector{T}"),
                        Td(:class => "px-4 py-2 font-mono", "Array")),
                    Tr(:class => "border-b border-warm-100 dark:border-warm-900",
                        Td(:class => "px-4 py-2 font-mono text-accent-600 dark:text-accent-400", "Dict{K,V}"),
                        Td(:class => "px-4 py-2 font-mono", "Map")),
                    Tr(:class => "border-b border-warm-100 dark:border-warm-900",
                        Td(:class => "px-4 py-2 font-mono text-accent-600 dark:text-accent-400", "struct"),
                        Td(:class => "px-4 py-2 font-mono", "class"))
                )
            )
        ),

        H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "With Therapy.jl"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "JST powers ", A(:href => "https://grouptherapyorg.github.io/Therapy.jl/", :target => "_blank", :class => "text-accent-500 hover:text-accent-600 underline", "Therapy.jl"),
            "'s ", Code(:class => "font-mono text-accent-500", "@island"),
            " components. Write Julia → JST compiles to inline JS → browser hydrates."),
        Pre(:class => "bg-warm-900 dark:bg-warm-950 p-4 rounded border border-warm-800", Code(:class => "language-julia", """using Therapy

@island function Counter(; initial::Int = 0)
    count, set_count = create_signal(initial)
    return Div(
        Button(:on_click => () -> set_count(count() + 1), "+"),
        Span(count)
    )
end
# → Compiles to ~500 bytes of inline JavaScript"""))
    )
end
