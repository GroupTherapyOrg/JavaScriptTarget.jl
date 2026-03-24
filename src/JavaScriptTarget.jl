module JavaScriptTarget

using InteractiveUtils: subtypes

# === Public API ===
export compile, compile_module
export JSOutput
export build_inference_tables

# === Types ===
include("compiler/types.jl")

# === IR Extraction ===
include("compiler/ir.jl")

# === Code Generation ===
include("compiler/codegen.jl")

# === Runtime ===
include("compiler/runtime.jl")

# === Source Maps ===
include("compiler/sourcemap.jl")

# === Playground: Inference Tables ===
include("playground/type_registry.jl")
include("playground/inference_tables.jl")

end # module JavaScriptTarget
