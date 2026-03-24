# === Type kind constants ===
const TYPE_KIND_SPECIAL   = UInt8(0)  # Any, Nothing, Missing, Bottom, Union
const TYPE_KIND_PRIMITIVE = UInt8(1)  # Int32, Float64, Bool, String, etc.
const TYPE_KIND_ABSTRACT  = UInt8(2)  # Number, Integer, etc.
const TYPE_KIND_CONTAINER = UInt8(3)  # Vector{T}, Dict{K,V}, etc.
const TYPE_KIND_STRUCT    = UInt8(4)  # User-defined structs

# === FNV-1a constants ===
const FNV_OFFSET = UInt32(0x811c9dc5)
const FNV_PRIME  = UInt32(0x01000193)

"""
    TypeRegistry

Maps Julia types to compact Int32 IDs for the browser inference engine.
Pre-registers all built-in types with stable IDs.
"""
mutable struct TypeRegistry
    type_to_id::Dict{Any, Int32}
    id_to_name::Dict{Int32, String}
    id_to_kind::Dict{Int32, UInt8}
    next_id::Int32
end

function TypeRegistry()
    reg = TypeRegistry(
        Dict{Any, Int32}(),
        Dict{Int32, String}(),
        Dict{Int32, UInt8}(),
        Int32(0)
    )
    _register_builtin_types!(reg)
    return reg
end

"""
Register a type and return its ID. If already registered, return existing ID.
"""
function register_type!(reg::TypeRegistry, t::Any; name::String="", kind::UInt8=TYPE_KIND_PRIMITIVE)
    haskey(reg.type_to_id, t) && return reg.type_to_id[t]
    id = reg.next_id
    reg.next_id += 1
    reg.type_to_id[t] = id
    reg.id_to_name[id] = isempty(name) ? string(t) : name
    reg.id_to_kind[id] = kind
    return id
end

"""
Get the TypeID for a Julia type. Returns -1 if not registered.
"""
function get_type_id(reg::TypeRegistry, t::Any)::Int32
    get(reg.type_to_id, t, Int32(-1))
end

"""
Get or register a type, returning its ID.
"""
function ensure_type_id!(reg::TypeRegistry, t::Any)::Int32
    id = get_type_id(reg, t)
    id >= 0 && return id
    kind = _infer_kind(t)
    name = _type_display_name(t)
    return register_type!(reg, t; name=name, kind=kind)
end

function _infer_kind(t::Any)::UInt8
    (t === Any || t === Nothing || t === Missing || t === Union{}) && return TYPE_KIND_SPECIAL
    t isa Union && return TYPE_KIND_SPECIAL
    !(t isa DataType) && return TYPE_KIND_SPECIAL
    isabstracttype(t) && return TYPE_KIND_ABSTRACT
    (t <: AbstractArray || t <: AbstractDict || t <: AbstractSet || t <: Tuple) && return TYPE_KIND_CONTAINER
    (t <: Number || t === Bool || t === String || t === Char || t === Symbol) && return TYPE_KIND_PRIMITIVE
    return TYPE_KIND_STRUCT
end

function _type_display_name(t::Any)::String
    t isa Union && return _union_display_name(t)
    return string(t)
end

function _union_display_name(t::Union)::String
    parts = Any[]
    _flatten_union_for_name!(parts, t)
    return "Union{" * join(sort([string(p) for p in parts]), ",") * "}"
end

function _flatten_union_for_name!(parts::Vector{Any}, t::Union)
    _flatten_union_for_name!(parts, t.a)
    _flatten_union_for_name!(parts, t.b)
end
function _flatten_union_for_name!(parts::Vector{Any}, t::Any)
    push!(parts, t)
end

function _register_builtin_types!(reg::TypeRegistry)
    # ID 0-3: Special types
    register_type!(reg, Any;     name="Any",     kind=TYPE_KIND_SPECIAL)   # 0
    register_type!(reg, Union{}; name="Bottom",   kind=TYPE_KIND_SPECIAL)   # 1
    register_type!(reg, Nothing; name="Nothing",  kind=TYPE_KIND_SPECIAL)   # 2
    register_type!(reg, Missing; name="Missing",  kind=TYPE_KIND_SPECIAL)   # 3

    # ID 4-20: Primitive types
    register_type!(reg, Bool;    name="Bool",    kind=TYPE_KIND_PRIMITIVE)  # 4
    register_type!(reg, Int8;    name="Int8",    kind=TYPE_KIND_PRIMITIVE)  # 5
    register_type!(reg, Int16;   name="Int16",   kind=TYPE_KIND_PRIMITIVE)  # 6
    register_type!(reg, Int32;   name="Int32",   kind=TYPE_KIND_PRIMITIVE)  # 7
    register_type!(reg, Int64;   name="Int64",   kind=TYPE_KIND_PRIMITIVE)  # 8
    register_type!(reg, Int128;  name="Int128",  kind=TYPE_KIND_PRIMITIVE)  # 9
    register_type!(reg, UInt8;   name="UInt8",   kind=TYPE_KIND_PRIMITIVE)  # 10
    register_type!(reg, UInt16;  name="UInt16",  kind=TYPE_KIND_PRIMITIVE)  # 11
    register_type!(reg, UInt32;  name="UInt32",  kind=TYPE_KIND_PRIMITIVE)  # 12
    register_type!(reg, UInt64;  name="UInt64",  kind=TYPE_KIND_PRIMITIVE)  # 13
    register_type!(reg, UInt128; name="UInt128", kind=TYPE_KIND_PRIMITIVE)  # 14
    register_type!(reg, Float16; name="Float16", kind=TYPE_KIND_PRIMITIVE)  # 15
    register_type!(reg, Float32; name="Float32", kind=TYPE_KIND_PRIMITIVE)  # 16
    register_type!(reg, Float64; name="Float64", kind=TYPE_KIND_PRIMITIVE)  # 17
    register_type!(reg, Char;    name="Char",    kind=TYPE_KIND_PRIMITIVE)  # 18
    register_type!(reg, String;  name="String",  kind=TYPE_KIND_PRIMITIVE)  # 19
    register_type!(reg, Symbol;  name="Symbol",  kind=TYPE_KIND_PRIMITIVE)  # 20

    # ID 21-28: Abstract types
    register_type!(reg, Number;         name="Number",         kind=TYPE_KIND_ABSTRACT)  # 21
    register_type!(reg, Real;           name="Real",           kind=TYPE_KIND_ABSTRACT)  # 22
    register_type!(reg, Integer;        name="Integer",        kind=TYPE_KIND_ABSTRACT)  # 23
    register_type!(reg, Signed;         name="Signed",         kind=TYPE_KIND_ABSTRACT)  # 24
    register_type!(reg, Unsigned;       name="Unsigned",       kind=TYPE_KIND_ABSTRACT)  # 25
    register_type!(reg, AbstractFloat;  name="AbstractFloat",  kind=TYPE_KIND_ABSTRACT)  # 26
    register_type!(reg, AbstractString; name="AbstractString",  kind=TYPE_KIND_ABSTRACT) # 27
    register_type!(reg, AbstractChar;   name="AbstractChar",   kind=TYPE_KIND_ABSTRACT)  # 28

    # ID 29+: Common container instantiations
    register_type!(reg, Vector{Int64};       name="Vector{Int64}",       kind=TYPE_KIND_CONTAINER)  # 29
    register_type!(reg, Vector{Float64};     name="Vector{Float64}",     kind=TYPE_KIND_CONTAINER)  # 30
    register_type!(reg, Vector{String};      name="Vector{String}",      kind=TYPE_KIND_CONTAINER)  # 31
    register_type!(reg, Vector{Bool};        name="Vector{Bool}",        kind=TYPE_KIND_CONTAINER)  # 32
    register_type!(reg, Vector{Any};         name="Vector{Any}",         kind=TYPE_KIND_CONTAINER)  # 33
    register_type!(reg, Dict{String,Int64};  name="Dict{String,Int64}",  kind=TYPE_KIND_CONTAINER)  # 34
    register_type!(reg, Dict{String,String}; name="Dict{String,String}", kind=TYPE_KIND_CONTAINER)  # 35
    register_type!(reg, Dict{String,Any};    name="Dict{String,Any}",    kind=TYPE_KIND_CONTAINER)  # 36
    register_type!(reg, Dict{Symbol,Any};    name="Dict{Symbol,Any}",    kind=TYPE_KIND_CONTAINER)  # 37
    register_type!(reg, Set{Int64};          name="Set{Int64}",          kind=TYPE_KIND_CONTAINER)  # 38
    register_type!(reg, Set{String};         name="Set{String}",         kind=TYPE_KIND_CONTAINER)  # 39
    register_type!(reg, UnitRange{Int64};    name="UnitRange{Int64}",    kind=TYPE_KIND_CONTAINER)  # 40

    # Common tuple types
    register_type!(reg, Tuple{};                 name="Tuple{}",                 kind=TYPE_KIND_CONTAINER)  # 41
    register_type!(reg, Tuple{Int64};            name="Tuple{Int64}",            kind=TYPE_KIND_CONTAINER)  # 42
    register_type!(reg, Tuple{Int64,Int64};      name="Tuple{Int64,Int64}",      kind=TYPE_KIND_CONTAINER)  # 43
    register_type!(reg, Tuple{Float64,Float64};  name="Tuple{Float64,Float64}",  kind=TYPE_KIND_CONTAINER)  # 44
    register_type!(reg, Tuple{String,Int64};     name="Tuple{String,Int64}",     kind=TYPE_KIND_CONTAINER)  # 45

    # Common union types
    register_type!(reg, Union{Nothing,Int64};   name="Union{Int64,Nothing}",   kind=TYPE_KIND_SPECIAL)  # 46
    register_type!(reg, Union{Nothing,String};  name="Union{Nothing,String}",  kind=TYPE_KIND_SPECIAL)  # 47
    register_type!(reg, Union{Nothing,Float64}; name="Union{Float64,Nothing}", kind=TYPE_KIND_SPECIAL)  # 48
end

# === FNV-1a Hash Functions ===

"""
FNV-1a hash of a byte array.
"""
function fnv1a_hash(data::AbstractVector{UInt8})::UInt32
    h = FNV_OFFSET
    for b in data
        h = xor(h, UInt32(b))
        h *= FNV_PRIME
    end
    return h
end

"""
Composite FNV-1a hash of func_id + arg_type_ids (all Int32).
Deterministic on both Julia and JS sides.
"""
function composite_hash(func_id::Int32, arg_type_ids::AbstractVector{Int32})::UInt32
    h = FNV_OFFSET
    # Hash func_id as 4 little-endian bytes
    for shift in (0, 8, 16, 24)
        b = UInt8((reinterpret(UInt32, func_id) >> shift) & 0xff)
        h = xor(h, UInt32(b))
        h *= FNV_PRIME
    end
    # Hash each arg type id as 4 little-endian bytes
    for aid in arg_type_ids
        for shift in (0, 8, 16, 24)
            b = UInt8((reinterpret(UInt32, aid) >> shift) & 0xff)
            h = xor(h, UInt32(b))
            h *= FNV_PRIME
        end
    end
    return h
end

# === Function Registry ===

"""
Maps function names to compact Int32 IDs.
"""
mutable struct FuncRegistry
    name_to_id::Dict{String, Int32}
    id_to_name::Dict{Int32, String}
    next_id::Int32
end

function FuncRegistry()
    FuncRegistry(Dict{String,Int32}(), Dict{Int32,String}(), Int32(0))
end

function register_func!(reg::FuncRegistry, name::String)::Int32
    haskey(reg.name_to_id, name) && return reg.name_to_id[name]
    id = reg.next_id
    reg.next_id += 1
    reg.name_to_id[name] = id
    reg.id_to_name[id] = name
    return id
end

function get_func_id(reg::FuncRegistry, name::String)::Int32
    get(reg.name_to_id, name, Int32(-1))
end
