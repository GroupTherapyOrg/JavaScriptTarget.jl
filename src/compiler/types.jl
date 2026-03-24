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
Map a Julia type to its JS type representation for .d.ts generation.
"""
function js_type_string(t::Type)
    if t === Int32 || t === Int64 || t === Float64 || t === Float32 || t === UInt32 || t === UInt64
        return "number"
    elseif t === Bool
        return "boolean"
    elseif t === String
        return "string"
    elseif t === Nothing
        return "null"
    else
        return "any"
    end
end
