module JavaScriptTarget

# === Public API ===
export compile, compile_module
export JSOutput

# === Types ===
include("compiler/types.jl")

# === IR Extraction ===
include("compiler/ir.jl")

# === Code Generation ===
include("compiler/codegen.jl")

# === Runtime ===
include("compiler/runtime.jl")

end # module JavaScriptTarget
