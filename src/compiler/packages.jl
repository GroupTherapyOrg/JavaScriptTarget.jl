# packages.jl — Package compilation registry
#
# Enables JST to compile calls to registered Julia packages into JS equivalents.
# Instead of compiling a package's internal implementation (which often uses
# complex Julia internals), registered packages have their API functions
# mapped directly to JS code generators.
#
# Example:
#   register_package_compilation!(PlotlyBase, :scatter) do ctx, kwargs, args
#       # kwargs is Dict{Symbol, String} of compiled kwarg values
#       # args is Vector{String} of compiled positional args
#       build_js_object(Dict("type" => "\"scatter\"", kwargs...))
#   end

# Registry: (Module, Symbol) → compiler function
# Compiler function signature: (ctx, kwargs::Dict{Symbol,String}, args::Vector{String}) → String
const PACKAGE_COMPILATIONS = Dict{Tuple{Module, Symbol}, Function}()

"""
    register_package_compilation!(compiler_fn, mod::Module, name::Symbol)

Register a JS compilation mapping for a Julia package function.

The `compiler_fn` receives:
- `ctx::JSCompilationContext` — compilation context
- `kwargs::Dict{Symbol, String}` — keyword arguments (name → compiled JS expression)
- `pos_args::Vector{String}` — positional arguments (compiled JS expressions)

And should return a JS code string.

# Example
```julia
register_package_compilation!(MyPlotLib, :scatter) do ctx, kwargs, pos_args
    pairs = ["\\"\\$(k)\\": \\$(v)" for (k, v) in kwargs]
    push!(pairs, "\\"type\\": \\"scatter\\"")
    return "{\\$(join(pairs, ", "))}"
end
```
"""
function register_package_compilation!(compiler_fn::Function, mod::Module, name::Symbol)
    PACKAGE_COMPILATIONS[(mod, name)] = compiler_fn
end

"""
    register_package_compilations!(mod::Module, mappings::Dict{Symbol, Function})

Register multiple compilation mappings for a package at once.
"""
function register_package_compilations!(mod::Module, mappings::Dict{Symbol, Function})
    for (name, compiler_fn) in mappings
        PACKAGE_COMPILATIONS[(mod, name)] = compiler_fn
    end
end

"""
    lookup_package_compilation(mod::Module, name::Symbol)

Look up a registered compilation mapping. Returns the compiler function or nothing.
"""
function lookup_package_compilation(mod::Module, name::Symbol)
    get(PACKAGE_COMPILATIONS, (mod, name), nothing)
end

# ─── Helper: build JS object literal from key-value pairs ───

"""
    build_js_object(pairs::Dict{String, String}) → String

Build a JS object literal from string key → compiled JS value pairs.
"""
function build_js_object(pairs)
    if isempty(pairs)
        return "{}"
    end
    entries = ["$(repr(k)): $(v)" for (k, v) in pairs]
    return "{$(join(entries, ", "))}"
end

"""
    build_js_object_from_kwargs(kwargs::Dict{Symbol, String}; extras...) → String

Build a JS object from compiled kwargs, with optional extra static fields.
"""
function build_js_object_from_kwargs(kwargs::Dict{Symbol, String}; extras...)
    pairs = Dict{String, String}()
    for (k, v) in kwargs
        pairs[string(k)] = v
    end
    for (k, v) in extras
        pairs[string(k)] = v isa String ? repr(v) : string(v)
    end
    return build_js_object(pairs)
end
