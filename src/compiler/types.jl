"""
Output of the JavaScriptTarget compiler.
"""
struct JSOutput
    js::String
    dts::String
    sourcemap::String
    exports::Vector{String}
    runtime_bytes::Int
end

"""
Compilation context for a single function.
"""
mutable struct JSCompilationContext
    code_info::Core.CodeInfo
    arg_types::Tuple
    arg_names::Vector{String}
    return_type::Type
    func_name::String
    ssa_types::Vector{Any}
    js_locals::Dict{Int, String}
    local_counter::Int
    indent::Int
    captured_vars::Dict{Symbol, String}  # For closures: field_name → JS expression
    struct_types::Set{DataType}          # Struct types that need class definitions
    type_ids::Dict{DataType, Int}        # Concrete type → DFS pre-order type ID
    abstract_ranges::Dict{Type, Tuple{Int,Int}}  # Abstract type → (lo, hi) range
    type_id_counter::Int
    required_runtime::Set{Symbol}        # Runtime helpers needed by compiled code
    callable_overrides::Dict{DataType, Function}  # Callable struct type → (recv_js, args_js) → JS
end

function JSCompilationContext(code_info::Core.CodeInfo, arg_types::Tuple, return_type::Type, func_name::String)
    # Extract argument names from code_info slotnames
    nargs = length(arg_types)
    arg_names = String[]
    for i in 1:nargs
        # slotnames[1] is #self#, arguments start at index 2
        slot_idx = i + 1
        if slot_idx <= length(code_info.slotnames)
            name = string(code_info.slotnames[slot_idx])
            push!(arg_names, name)
        else
            push!(arg_names, "arg$i")
        end
    end

    JSCompilationContext(
        code_info,
        arg_types,
        arg_names,
        return_type,
        func_name,
        ndims(code_info.ssavaluetypes) == 0 ? Any[] : collect(Any, code_info.ssavaluetypes),
        Dict{Int, String}(),
        0,
        1,
        Dict{Symbol, String}(),
        Set{DataType}(),
        Dict{DataType, Int}(),
        Dict{Type, Tuple{Int,Int}}(),
        0,
        Set{Symbol}(),
        Dict{DataType, Function}(),
    )
end

"""
Get a JS variable name for an SSA value, creating one if needed.
"""
function get_local!(ctx::JSCompilationContext, ssa_id::Int)
    get!(ctx.js_locals, ssa_id) do
        ctx.local_counter += 1
        "_v$(ctx.local_counter)"
    end
end

"""
Sanitize a Julia name for use as a JS identifier.
"""
function sanitize_js_name(name::String)
    # Replace ! with _b (bang)
    name = replace(name, "!" => "_b")
    # Replace # with _
    name = replace(name, "#" => "_")
    return name
end

"""
Map a Julia type to its TypeScript type representation for .d.ts generation.
Handles primitives, unions, containers, tuples, and struct types.
"""
function js_type_string(t::Type)
    # Primitives
    if t === Int8 || t === Int16 || t === Int32 || t === Int64 ||
       t === UInt8 || t === UInt16 || t === UInt32 || t === UInt64 ||
       t === Float32 || t === Float64
        return "number"
    elseif t === Bool
        return "boolean"
    elseif t === String || t === Char || t === Symbol
        return "string"
    elseif t === Nothing
        return "null"
    elseif t === Missing
        return "undefined"
    elseif t === Any
        return "any"
    end

    # Union types
    if t isa Union
        parts = _collect_union_types(t)
        ts_parts = unique([js_type_string(p) for p in parts])
        return join(ts_parts, " | ")
    end

    # Container types
    if t isa DataType
        tn = t.name.wrapper
        if tn === Vector || tn === Array
            if !isempty(t.parameters)
                elem_ts = js_type_string(t.parameters[1])
                return "Array<$(elem_ts)>"
            end
            return "Array<any>"
        elseif tn === Dict
            if length(t.parameters) >= 2
                k_ts = js_type_string(t.parameters[1])
                v_ts = js_type_string(t.parameters[2])
                return "Map<$(k_ts), $(v_ts)>"
            end
            return "Map<any, any>"
        elseif tn === Set
            if !isempty(t.parameters)
                elem_ts = js_type_string(t.parameters[1])
                return "Set<$(elem_ts)>"
            end
            return "Set<any>"
        end
    end

    # Tuple types
    if t isa DataType && t <: Tuple
        if !isempty(t.parameters)
            elem_types = [js_type_string(p) for p in t.parameters]
            return "readonly [$(join(elem_types, ", "))]"
        end
        return "readonly any[]"
    end

    # Struct types (user-defined concrete types)
    if t isa DataType && !isabstracttype(t) &&
       !(t <: Number) && !(t <: AbstractString) && t !== Bool && t !== Nothing &&
       !(t <: Function) && !(t <: AbstractArray) && !(t <: AbstractDict) &&
       !(t <: AbstractSet) && !(t <: Tuple) && !(t <: IO) &&
       t.name.module !== Base && t.name.module !== Core
        return string(nameof(t))
    end

    return "any"
end

"""
Collect all types in a Union into a flat vector.
"""
function _collect_union_types(t::Union)
    result = Type[]
    _flatten_union!(result, t)
    return result
end

function _flatten_union!(result::Vector{Type}, t::Union)
    _flatten_union!(result, t.a)
    _flatten_union!(result, t.b)
end

function _flatten_union!(result::Vector{Type}, t::Type)
    push!(result, t)
end

"""
Generate a TypeScript .d.ts branded class declaration for a Julia struct type.
Immutable structs get readonly fields and a branded type marker.
Mutable structs get writable fields.
"""
function generate_struct_dts(T::DataType)
    name = string(nameof(T))
    fnames = fieldnames(T)
    ftypes = [fieldtype(T, f) for f in fnames]
    is_mutable = ismutabletype(T)

    buf = IOBuffer()
    print(buf, "declare class $(name) {\n")

    # Fields
    for (i, fname) in enumerate(fnames)
        ts_type = js_type_string(ftypes[i])
        if is_mutable
            print(buf, "  $(fname): $(ts_type);\n")
        else
            print(buf, "  readonly $(fname): $(ts_type);\n")
        end
    end

    # Branded type marker for nominal safety (immutable structs)
    if !is_mutable
        print(buf, "  private readonly __brand: unique symbol;\n")
    end

    # Constructor
    params = join(["$(fnames[i]): $(js_type_string(ftypes[i]))" for i in 1:length(fnames)], ", ")
    print(buf, "  constructor($(params));\n")

    print(buf, "}\n")
    return String(take!(buf))
end
