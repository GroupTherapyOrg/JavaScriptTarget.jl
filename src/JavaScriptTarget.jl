module JavaScriptTarget

using InteractiveUtils: subtypes

# === Public API ===
export compile, compile_module
export JSOutput
export build_inference_tables
export build_playground
export register_package_compilation!, register_package_compilations!
export lookup_package_compilation, build_js_object, build_js_object_from_kwargs
export register_plotly_compilations!

# === Types ===
include("compiler/types.jl")

# === IR Extraction ===
include("compiler/ir.jl")

# === Package Registry ===
include("compiler/packages.jl")
include("compiler/packages_plotly.jl")

# === Code Generation ===
include("compiler/codegen.jl")

# === Runtime ===
include("compiler/runtime.jl")

# === Source Maps ===
include("compiler/sourcemap.jl")

# === Playground: Inference Tables ===
include("playground/type_registry.jl")
include("playground/inference_tables.jl")

# === Playground: Build ===
include("playground/build.jl")

end # module JavaScriptTarget
