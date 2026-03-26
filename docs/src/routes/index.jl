() -> begin
    Div(:class => "space-y-16",
        # Hero
        Div(:class => "text-center space-y-6 pt-8",
            H1(:class => "no-rule text-5xl md:text-6xl font-serif font-bold text-warm-900 dark:text-warm-100",
                "Julia → JavaScript"
            ),
            H1(:class => "no-rule text-5xl md:text-6xl font-serif font-bold text-accent-500",
                "Compiler"
            ),
            P(:class => "text-lg text-warm-600 dark:text-warm-400 max-w-2xl mx-auto leading-relaxed",
                "Compile Julia functions to JavaScript via typed IR. ",
                "Arrays, strings, math, closures, structs — all compile to clean, efficient JS."
            ),
            Div(:class => "flex gap-4 justify-center pt-4",
                A(:href => "./getting-started/",
                    :class => "px-6 py-3 bg-accent-600 hover:bg-accent-700 text-white rounded-lg font-medium transition-colors",
                    "Get Started"
                ),
                A(:href => "https://github.com/GroupTherapyOrg/JavaScriptTarget.jl", :target => "_blank",
                    :class => "px-6 py-3 border border-warm-300 dark:border-warm-700 rounded-lg font-medium text-warm-700 dark:text-warm-300 hover:bg-warm-100 dark:hover:bg-warm-900 transition-colors",
                    "View on GitHub"
                )
            )
        ),
        # Code example
        Div(:class => "w-full max-w-3xl mx-auto",
            Pre(:class => "bg-warm-900 dark:bg-warm-950 text-warm-200 p-6 rounded-lg overflow-x-auto border border-warm-800",
                Code(:class => "language-julia text-sm font-mono", """using JavaScriptTarget

# Write Julia — compiles to JavaScript
function physics(x::Float64, v::Float64, dt::Float64)
    a = -9.81
    v_new = v + a * dt
    x_new = x + v_new * dt
    return (x_new, v_new)
end

# Compile to JS
result = compile(physics, (Float64, Float64, Float64))
println(result.js)  # Clean JS output""")
            )
        ),
        # Live Playground
        Div(:class => "space-y-4",
            H2(:class => "text-xl font-semibold text-warm-800 dark:text-warm-200 text-center", "Try it Live"),
            P(:class => "text-sm text-warm-600 dark:text-warm-400 text-center", "Write Julia in the left panel — see compiled JavaScript on the right. Runs entirely in your browser."),
            Div(:class => "w-full rounded-lg overflow-hidden border border-warm-200 dark:border-warm-800",
                RawHtml("""<iframe src="./playground/index.html" style="width:100%;height:500px;border:none;" title="JST Playground"></iframe>""")
            )
        ),

        # Feature cards
        Div(:class => "grid grid-cols-1 md:grid-cols-3 gap-6",
            Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-6 bg-warm-100/50 dark:bg-warm-900/50",
                H3(:class => "font-semibold mb-2 text-warm-900 dark:text-warm-100", "Typed IR"),
                P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed",
                    "Walks Julia's typed IR (", Code(:class => "text-accent-500", "code_typed"), ") to generate JS. Type-driven compilation — not string hacking.")
            ),
            Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-6 bg-warm-100/50 dark:bg-warm-900/50",
                H3(:class => "font-semibold mb-2 text-warm-900 dark:text-warm-100", "Package Registry"),
                P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed",
                    "Register custom compilations for any Julia package. PlotlyBase, DataFrames — they just compile.")
            ),
            Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-6 bg-warm-100/50 dark:bg-warm-900/50",
                H3(:class => "font-semibold mb-2 text-warm-900 dark:text-warm-100", "Tiny Output"),
                P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed",
                    "No framework runtime. Each compiled function is self-contained JS. Inline-able in ", Code(:class => "text-accent-500", "<script>"), " tags.")
            )
        )
    )
end
