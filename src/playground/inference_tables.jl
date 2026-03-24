# === Hash Table Entry ===

struct HashEntry
    hash::UInt32
    func_id::Int32
    arg_type_ids::Vector{Int32}
    return_type_id::Int32
end

# === Inference Hash Table (FNV-1a + linear probe) ===

const MAX_ARGS = 4       # Max args per entry (fixed-size slots)
const ENTRY_INTS = 8     # Ints per slot: [hash, func_id, nargs, arg0..arg3, return_type]

mutable struct InferenceHashTable
    capacity::Int32
    count::Int32
    data::Vector{Int32}   # Flat array: capacity * ENTRY_INTS
end

function InferenceHashTable(capacity::Int)
    # Round up to next power of 2
    cap = 1
    while cap < capacity
        cap <<= 1
    end
    InferenceHashTable(Int32(cap), Int32(0), zeros(Int32, cap * ENTRY_INTS))
end

function insert!(table::InferenceHashTable, entry::HashEntry)
    length(entry.arg_type_ids) > MAX_ARGS && return false
    # Ensure load factor < 75%
    if table.count >= table.capacity * 3 ÷ 4
        _resize!(table)
    end
    _insert_entry!(table, entry)
    return true
end

function _insert_entry!(table::InferenceHashTable, entry::HashEntry)
    idx = Int(entry.hash % UInt32(table.capacity))
    for _ in 1:table.capacity
        base = idx * ENTRY_INTS + 1  # 1-based
        if table.data[base] == 0     # Empty slot (hash==0 means empty)
            table.data[base]     = reinterpret(Int32, entry.hash)
            table.data[base + 1] = entry.func_id
            table.data[base + 2] = Int32(length(entry.arg_type_ids))
            for (i, aid) in enumerate(entry.arg_type_ids)
                table.data[base + 2 + i] = aid
            end
            table.data[base + 7] = entry.return_type_id
            table.count += 1
            return
        end
        idx = (idx + 1) % Int(table.capacity)
    end
    error("Hash table full — should not happen with resize")
end

function _resize!(table::InferenceHashTable)
    old_data = table.data
    old_cap = table.capacity
    new_cap = old_cap * 2
    table.capacity = new_cap
    table.count = 0
    table.data = zeros(Int32, new_cap * ENTRY_INTS)
    # Re-insert all entries
    for i in 0:(old_cap - 1)
        base = i * ENTRY_INTS + 1
        old_data[base] == 0 && continue
        nargs = Int(old_data[base + 2])
        entry = HashEntry(
            reinterpret(UInt32, old_data[base]),
            old_data[base + 1],
            old_data[(base + 3):(base + 2 + nargs)],
            old_data[base + 7]
        )
        _insert_entry!(table, entry)
    end
end

function lookup(table::InferenceHashTable, func_id::Int32, arg_type_ids::Vector{Int32})::Int32
    hash = composite_hash(func_id, arg_type_ids)
    idx = Int(hash % UInt32(table.capacity))
    hash_i32 = reinterpret(Int32, hash)
    nargs = Int32(length(arg_type_ids))
    for _ in 1:table.capacity
        base = idx * ENTRY_INTS + 1
        table.data[base] == 0 && return Int32(-1)  # empty → not found
        if table.data[base] == hash_i32 && table.data[base + 1] == func_id && table.data[base + 2] == nargs
            match = true
            for (i, aid) in enumerate(arg_type_ids)
                if table.data[base + 2 + i] != aid
                    match = false
                    break
                end
            end
            match && return table.data[base + 7]
        end
        idx = (idx + 1) % Int(table.capacity)
    end
    return Int32(-1)
end

# === Method Enumeration ===

# Core numeric types for cross-product testing
const CORE_NUMERIC = [Int32, Int64, Float32, Float64]
const ALL_INT = [Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128]
const ALL_FLOAT = [Float16, Float32, Float64]
const ALL_NUMERIC = [ALL_INT; ALL_FLOAT]

"""
Get the return type of a function with given argument types via Base.code_typed.
Returns nothing if the method doesn't exist or fails.
"""
function _get_return_type(f::Any, arg_types::Tuple)::Union{Type, Nothing}
    try
        results = Base.code_typed(f, Tuple{arg_types...}; optimize=true)
        isempty(results) && return nothing
        _, ret_type = results[1]
        # Unwrap Const types
        ret_type isa Core.Const && return typeof(ret_type.val)
        ret_type isa Type && return ret_type
        return nothing
    catch
        return nothing
    end
end

"""
Get the function name string for a Julia function.
"""
function _func_name(f::Function)::String
    n = string(nameof(f))
    # Strip module prefix if present
    idx = findlast('.', n)
    idx !== nothing && return n[idx+1:end]
    return n
end

"""
Enumerate all supported Base methods and compute their return types.
Returns a vector of HashEntry.
"""
function enumerate_base_methods(type_reg::TypeRegistry, func_reg::FuncRegistry; verbose::Bool=false)
    entries = HashEntry[]

    # Define function specs: (function, name, arg_type_combos)
    specs = _build_function_specs()

    for (f, name, combos) in specs
        fid = register_func!(func_reg, name)
        for arg_types in combos
            ret = _get_return_type(f, arg_types)
            ret === nothing && continue

            # Register return type if not known
            ret_id = ensure_type_id!(type_reg, ret)
            arg_ids = Int32[ensure_type_id!(type_reg, t) for t in arg_types]
            hash = composite_hash(fid, arg_ids)

            # Skip entries with hash == 0 (reserved for empty slots)
            hash == UInt32(0) && continue

            push!(entries, HashEntry(hash, fid, arg_ids, ret_id))

            verbose && println("  $(name)($(join(arg_types, ", "))) → $(ret)  [fid=$(fid), ret_id=$(ret_id)]")
        end
    end

    return entries
end

function _build_function_specs()
    specs = Tuple{Any, String, Vector{Tuple}}[]

    # --- Binary arithmetic ---
    for (f, name) in [(+, "+"), (-, "-"), (*, "*")]
        combos = Tuple[]
        # All same-type numeric
        for t in ALL_NUMERIC
            push!(combos, (t, t))
        end
        # Cross-type core numeric
        for t1 in CORE_NUMERIC, t2 in CORE_NUMERIC
            t1 === t2 && continue
            push!(combos, (t1, t2))
        end
        push!(specs, (f, name, combos))
    end

    # Division (always returns float for int inputs)
    let combos = Tuple[]
        for t in ALL_NUMERIC
            push!(combos, (t, t))
        end
        for t1 in CORE_NUMERIC, t2 in CORE_NUMERIC
            t1 === t2 && continue
            push!(combos, (t1, t2))
        end
        push!(specs, (/, "/", combos))
    end

    # Integer division ops
    for (f, name) in [(div, "div"), (fld, "fld"), (mod, "mod"), (cld, "cld"), (rem, "rem")]
        combos = Tuple[]
        for t in ALL_INT
            push!(combos, (t, t))
        end
        # Float div/mod too
        for t in ALL_FLOAT
            push!(combos, (t, t))
        end
        push!(specs, (f, name, combos))
    end

    # --- Unary arithmetic ---
    let combos = [(-,) for _ in 1:0]  # just for type
        combos_neg = Tuple[(t,) for t in ALL_NUMERIC]
        push!(specs, (-, "-_unary", combos_neg))
    end

    # --- Unary math ---
    for (f, name) in [
        (sin, "sin"), (cos, "cos"), (tan, "tan"),
        (asin, "asin"), (acos, "acos"), (atan, "atan"),
        (exp, "exp"), (log, "log"), (log2, "log2"), (log10, "log10"),
        (sqrt, "sqrt"), (abs, "abs"),
        (floor, "floor"), (ceil, "ceil"), (trunc, "trunc"), (round, "round"),
        (sign, "sign")
    ]
        combos = Tuple[(t,) for t in ALL_NUMERIC]
        push!(specs, (f, name, combos))
    end

    # min/max (binary)
    for (f, name) in [(min, "min"), (max, "max")]
        combos = Tuple[]
        for t in ALL_NUMERIC
            push!(combos, (t, t))
        end
        push!(specs, (f, name, combos))
    end

    # hypot, atan (2-arg)
    push!(specs, (hypot, "hypot", Tuple[(Float64, Float64), (Float32, Float32)]))
    push!(specs, (atan, "atan2", Tuple[(Float64, Float64), (Float32, Float32)]))

    # --- Comparisons ---
    for (f, name) in [(==, "=="), (!=, "!="), (<, "<"), (<=, "<="), (>, ">"), (>=, ">=")]
        combos = Tuple[]
        for t in ALL_NUMERIC
            push!(combos, (t, t))
        end
        push!(combos, (String, String))
        push!(combos, (Char, Char))
        push!(specs, (f, name, combos))
    end
    push!(specs, (===, "===", Tuple[(Any, Any), (Int64, Int64), (String, String), (Nothing, Nothing)]))

    # --- Boolean ---
    push!(specs, (!, "!", Tuple[(Bool,)]))
    for (f, name) in [(&, "&"), (|, "|"), (xor, "xor")]
        push!(specs, (f, name, Tuple[(Bool, Bool), (Int32, Int32), (Int64, Int64)]))
    end
    push!(specs, (~, "~", Tuple[(Int32,), (Int64,), (UInt32,), (UInt64,)]))

    # --- Bitwise shifts ---
    for (f, name) in [(<<, "<<"), (>>, ">>"), (>>>, ">>>")]
        combos = Tuple[(Int32, Int64), (Int64, Int64), (UInt32, Int64), (UInt64, Int64)]
        push!(specs, (f, name, combos))
    end

    # --- Type conversions ---
    push!(specs, (Float64, "Float64", Tuple[(Int32,), (Int64,), (Float32,), (Bool,)]))
    push!(specs, (Float32, "Float32", Tuple[(Int32,), (Int64,), (Float64,), (Bool,)]))
    push!(specs, (Int64, "Int64", Tuple[(Int32,), (Float64,), (Bool,), (Char,)]))
    push!(specs, (Int32, "Int32", Tuple[(Int64,), (Float64,), (Bool,)]))

    # --- String operations ---
    push!(specs, (*, "*_str", Tuple[(String, String)]))
    push!(specs, (^, "^_str", Tuple[(String, Int64), (String, Int32)]))
    push!(specs, (string, "string", Tuple[(String,), (Int64,), (Float64,), (Bool,), (String, String), (String, Int64)]))
    push!(specs, (startswith, "startswith", Tuple[(String, String), (String, Char)]))
    push!(specs, (endswith, "endswith", Tuple[(String, String), (String, Char)]))
    push!(specs, (length, "length_str", Tuple[(String,)]))
    push!(specs, (ncodeunits, "ncodeunits", Tuple[(String,)]))
    push!(specs, (isempty, "isempty_str", Tuple[(String,)]))
    push!(specs, (occursin, "occursin", Tuple[(String, String), (Char, String)]))
    push!(specs, (contains, "contains", Tuple[(String, String)]))
    push!(specs, (uppercase, "uppercase", Tuple[(String,), (Char,)]))
    push!(specs, (lowercase, "lowercase", Tuple[(String,), (Char,)]))
    push!(specs, (strip, "strip", Tuple[(String,)]))
    push!(specs, (lstrip, "lstrip", Tuple[(String,)]))
    push!(specs, (rstrip, "rstrip", Tuple[(String,)]))
    push!(specs, (chomp, "chomp", Tuple[(String,)]))
    push!(specs, (chop, "chop", Tuple[(String,)]))
    push!(specs, (reverse, "reverse_str", Tuple[(String,)]))
    push!(specs, (repr, "repr", Tuple[(Int64,), (Float64,), (String,), (Bool,)]))

    # --- Collection operations ---
    # Vector
    for T in [Int64, Float64, String, Bool, Any]
        vt = Vector{T}
        push!(specs, (length, "length", Tuple[(vt,)]))
        push!(specs, (isempty, "isempty", Tuple[(vt,)]))
        push!(specs, (getindex, "getindex", Tuple[(vt, Int64)]))
        push!(specs, (first, "first", Tuple[(vt,)]))
        push!(specs, (last, "last", Tuple[(vt,)]))
    end
    # Dict
    for (K, V) in [(String, Int64), (String, String), (Symbol, Any), (String, Any)]
        dt = Dict{K,V}
        push!(specs, (length, "length", Tuple[(dt,)]))
        push!(specs, (isempty, "isempty", Tuple[(dt,)]))
        push!(specs, (getindex, "getindex", Tuple[(dt, K)]))
        push!(specs, (haskey, "haskey", Tuple[(dt, K)]))
    end
    # Set
    for T in [Int64, String]
        st = Set{T}
        push!(specs, (length, "length", Tuple[(st,)]))
        push!(specs, (isempty, "isempty", Tuple[(st,)]))
        push!(specs, (in, "in", Tuple[(T, st)]))
    end

    # Tuple
    push!(specs, (length, "length", Tuple[(Tuple{Int64,Int64},), (Tuple{Int64,Int64,Int64},)]))

    # --- Type operations ---
    push!(specs, (typeof, "typeof", Tuple[(Int64,), (Float64,), (String,), (Bool,), (Nothing,)]))

    # --- IO ---
    push!(specs, (println, "println", Tuple[(String,), (Int64,), (Float64,)]))
    push!(specs, (print, "print", Tuple[(String,), (Int64,)]))

    # --- Range ---
    push!(specs, ((:), "colon", Tuple[(Int64, Int64), (Int64, Int64, Int64)]))

    # --- Misc ---
    push!(specs, (zero, "zero", Tuple[(Type{Int64},), (Type{Float64},), (Type{Int32},)]))
    push!(specs, (one, "one", Tuple[(Type{Int64},), (Type{Float64},), (Type{Int32},)]))
    push!(specs, (typemin, "typemin", Tuple[(Type{Int32},), (Type{Int64},), (Type{Float64},)]))
    push!(specs, (typemax, "typemax", Tuple[(Type{Int32},), (Type{Int64},), (Type{Float64},)]))

    return specs
end

# === Parametric Rules ===

"""
Generate parametric rules for the browser inference engine.
Rules capture type relationships that the hash table can't express
(e.g., getindex(Vector{T}, Int) → T for any T).
"""
function generate_parametric_rules()
    rules = Dict{String, Any}[]

    # --- Arithmetic: same-type returns same type ---
    for op in ["+", "-", "*"]
        push!(rules, Dict(
            "func" => op,
            "args" => [Dict("var" => "T", "bound" => "Number"), Dict("var" => "T")],
            "returns" => Dict("var" => "T"),
            "desc" => "Same-type $(op)"
        ))
    end

    # Division of same int type → Float64
    push!(rules, Dict(
        "func" => "/",
        "args" => [Dict("var" => "T", "bound" => "Integer"), Dict("var" => "T")],
        "returns" => Dict("type" => "Float64"),
        "desc" => "Int division promotes to Float64"
    ))
    # Division of floats → same float
    push!(rules, Dict(
        "func" => "/",
        "args" => [Dict("var" => "T", "bound" => "AbstractFloat"), Dict("var" => "T")],
        "returns" => Dict("var" => "T"),
        "desc" => "Float division"
    ))

    # Integer ops return same int type
    for op in ["div", "fld", "mod", "cld", "rem"]
        push!(rules, Dict(
            "func" => op,
            "args" => [Dict("var" => "T", "bound" => "Integer"), Dict("var" => "T")],
            "returns" => Dict("var" => "T"),
            "desc" => "$(op) preserves int type"
        ))
    end

    # --- Promotion: int + float → float ---
    for op in ["+", "-", "*", "/"]
        push!(rules, Dict(
            "func" => op,
            "args" => [Dict("var" => "T1", "bound" => "Integer"), Dict("var" => "T2", "bound" => "AbstractFloat")],
            "returns" => Dict("var" => "T2"),
            "desc" => "Int $(op) Float promotes to Float"
        ))
        push!(rules, Dict(
            "func" => op,
            "args" => [Dict("var" => "T2", "bound" => "AbstractFloat"), Dict("var" => "T1", "bound" => "Integer")],
            "returns" => Dict("var" => "T2"),
            "desc" => "Float $(op) Int promotes to Float"
        ))
    end

    # --- Unary: preserves type ---
    push!(rules, Dict(
        "func" => "-_unary",
        "args" => [Dict("var" => "T", "bound" => "Number")],
        "returns" => Dict("var" => "T"),
        "desc" => "Unary negation preserves type"
    ))

    # Unary math functions: Number → same type (approximately)
    for fname in ["abs", "sign"]
        push!(rules, Dict(
            "func" => fname,
            "args" => [Dict("var" => "T", "bound" => "Number")],
            "returns" => Dict("var" => "T"),
            "desc" => "$(fname) preserves type"
        ))
    end

    # Float-only math: AbstractFloat → same float type
    for fname in ["sin", "cos", "tan", "asin", "acos", "atan",
                   "exp", "log", "log2", "log10", "sqrt",
                   "floor", "ceil", "trunc", "round"]
        push!(rules, Dict(
            "func" => fname,
            "args" => [Dict("var" => "T", "bound" => "AbstractFloat")],
            "returns" => Dict("var" => "T"),
            "desc" => "$(fname) preserves float type"
        ))
    end

    # Math on integers typically promotes to Float64
    for fname in ["sin", "cos", "tan", "asin", "acos", "atan",
                   "exp", "log", "log2", "log10", "sqrt"]
        push!(rules, Dict(
            "func" => fname,
            "args" => [Dict("var" => "T", "bound" => "Integer")],
            "returns" => Dict("type" => "Float64"),
            "desc" => "$(fname)(Int) → Float64"
        ))
    end

    # floor/ceil/trunc/round on integers → same integer
    for fname in ["floor", "ceil", "trunc", "round"]
        push!(rules, Dict(
            "func" => fname,
            "args" => [Dict("var" => "T", "bound" => "Integer")],
            "returns" => Dict("var" => "T"),
            "desc" => "$(fname)(Int) → Int"
        ))
    end

    # --- Comparisons: always return Bool ---
    for op in ["==", "!=", "<", "<=", ">", ">=", "==="]
        push!(rules, Dict(
            "func" => op,
            "args" => [Dict("type" => "Any"), Dict("type" => "Any")],
            "returns" => Dict("type" => "Bool"),
            "desc" => "$(op) → Bool"
        ))
    end

    # --- Boolean ops ---
    push!(rules, Dict("func" => "!", "args" => [Dict("type" => "Bool")],
        "returns" => Dict("type" => "Bool"), "desc" => "! → Bool"))
    for op in ["&", "|", "xor"]
        push!(rules, Dict("func" => op,
            "args" => [Dict("var" => "T", "bound" => "Integer"), Dict("var" => "T")],
            "returns" => Dict("var" => "T"), "desc" => "$(op) preserves type"))
    end

    # --- Type conversions ---
    for target in ["Int8", "Int16", "Int32", "Int64", "Int128",
                    "UInt8", "UInt16", "UInt32", "UInt64",
                    "Float16", "Float32", "Float64"]
        push!(rules, Dict("func" => target,
            "args" => [Dict("type" => "Any")],
            "returns" => Dict("type" => target),
            "desc" => "Convert to $(target)"))
    end

    # --- String operations ---
    push!(rules, Dict("func" => "*_str",
        "args" => [Dict("type" => "String"), Dict("type" => "String")],
        "returns" => Dict("type" => "String"), "desc" => "String concatenation"))
    push!(rules, Dict("func" => "^_str",
        "args" => [Dict("type" => "String"), Dict("type" => "Any")],
        "returns" => Dict("type" => "String"), "desc" => "String repeat"))
    push!(rules, Dict("func" => "string",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "String"), "desc" => "string() → String"))
    for fname in ["startswith", "endswith", "occursin", "contains"]
        push!(rules, Dict("func" => fname,
            "args" => [Dict("type" => "Any"), Dict("type" => "Any")],
            "returns" => Dict("type" => "Bool"), "desc" => "$(fname) → Bool"))
    end
    for fname in ["uppercase", "lowercase", "strip", "lstrip", "rstrip",
                   "chomp", "chop", "reverse_str", "repr"]
        push!(rules, Dict("func" => fname,
            "args" => [Dict("type" => "String")],
            "returns" => Dict("type" => "String"), "desc" => "$(fname) → String"))
    end
    for fname in ["length_str", "ncodeunits"]
        push!(rules, Dict("func" => fname,
            "args" => [Dict("type" => "String")],
            "returns" => Dict("type" => "Int64"), "desc" => "$(fname) → Int64"))
    end
    push!(rules, Dict("func" => "isempty_str",
        "args" => [Dict("type" => "String")],
        "returns" => Dict("type" => "Bool"), "desc" => "isempty(String) → Bool"))

    # --- Collection operations ---
    # Vector indexing: getindex(Vector{T}, Int) → T
    push!(rules, Dict("func" => "getindex",
        "args" => [Dict("container" => "Vector", "typevar" => "T"), Dict("type" => "Int64")],
        "returns" => Dict("var" => "T"), "desc" => "Vector indexing"))
    # Vector push!/setindex! → Vector{T}
    push!(rules, Dict("func" => "setindex!",
        "args" => [Dict("container" => "Vector", "typevar" => "T"), Dict("var" => "T"), Dict("type" => "Int64")],
        "returns" => Dict("container" => "Vector", "typevar" => "T"), "desc" => "Vector setindex!"))
    push!(rules, Dict("func" => "push!",
        "args" => [Dict("container" => "Vector", "typevar" => "T"), Dict("var" => "T")],
        "returns" => Dict("container" => "Vector", "typevar" => "T"), "desc" => "push! → Vector{T}"))
    push!(rules, Dict("func" => "pop!",
        "args" => [Dict("container" => "Vector", "typevar" => "T")],
        "returns" => Dict("var" => "T"), "desc" => "pop! → T"))
    push!(rules, Dict("func" => "first",
        "args" => [Dict("container" => "Vector", "typevar" => "T")],
        "returns" => Dict("var" => "T"), "desc" => "first(Vector{T}) → T"))
    push!(rules, Dict("func" => "last",
        "args" => [Dict("container" => "Vector", "typevar" => "T")],
        "returns" => Dict("var" => "T"), "desc" => "last(Vector{T}) → T"))

    # Dict operations
    push!(rules, Dict("func" => "getindex",
        "args" => [Dict("container" => "Dict", "typevars" => ["K", "V"]), Dict("var" => "K")],
        "returns" => Dict("var" => "V"), "desc" => "Dict getindex"))
    push!(rules, Dict("func" => "haskey",
        "args" => [Dict("container" => "Dict", "typevars" => ["K", "V"]), Dict("var" => "K")],
        "returns" => Dict("type" => "Bool"), "desc" => "haskey → Bool"))
    push!(rules, Dict("func" => "get",
        "args" => [Dict("container" => "Dict", "typevars" => ["K", "V"]), Dict("var" => "K"), Dict("var" => "V")],
        "returns" => Dict("var" => "V"), "desc" => "get(dict, key, default) → V"))
    push!(rules, Dict("func" => "keys",
        "args" => [Dict("container" => "Dict", "typevars" => ["K", "V"])],
        "returns" => Dict("container" => "Vector", "typevar" => "K"), "desc" => "keys → Vector{K}"))
    push!(rules, Dict("func" => "values",
        "args" => [Dict("container" => "Dict", "typevars" => ["K", "V"])],
        "returns" => Dict("container" => "Vector", "typevar" => "V"), "desc" => "values → Vector{V}"))
    push!(rules, Dict("func" => "delete!",
        "args" => [Dict("container" => "Dict", "typevars" => ["K", "V"]), Dict("var" => "K")],
        "returns" => Dict("container" => "Dict", "typevars" => ["K", "V"]), "desc" => "delete! → Dict{K,V}"))

    # Set operations
    push!(rules, Dict("func" => "in",
        "args" => [Dict("var" => "T"), Dict("container" => "Set", "typevar" => "T")],
        "returns" => Dict("type" => "Bool"), "desc" => "in(T, Set{T}) → Bool"))
    push!(rules, Dict("func" => "push!",
        "args" => [Dict("container" => "Set", "typevar" => "T"), Dict("var" => "T")],
        "returns" => Dict("container" => "Set", "typevar" => "T"), "desc" => "push!(Set{T}, T) → Set{T}"))

    # Container length/isempty
    push!(rules, Dict("func" => "length",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "Int64"), "desc" => "length → Int64"))
    push!(rules, Dict("func" => "isempty",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "Bool"), "desc" => "isempty → Bool"))

    # --- Struct field access ---
    push!(rules, Dict("func" => "getfield",
        "args" => [Dict("var" => "S", "bound" => "Any"), Dict("type" => "Symbol")],
        "returns" => Dict("fieldof" => "S"), "desc" => "getfield → field type"))
    push!(rules, Dict("func" => "setfield!",
        "args" => [Dict("var" => "S", "bound" => "Any"), Dict("type" => "Symbol"), Dict("type" => "Any")],
        "returns" => Dict("type" => "Any"), "desc" => "setfield! → Any"))

    # --- Type operations ---
    push!(rules, Dict("func" => "isa",
        "args" => [Dict("type" => "Any"), Dict("type" => "Any")],
        "returns" => Dict("type" => "Bool"), "desc" => "isa → Bool"))
    push!(rules, Dict("func" => "typeof",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "Type"), "desc" => "typeof → Type"))

    # --- IO ---
    push!(rules, Dict("func" => "println",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "Nothing"), "desc" => "println → Nothing"))
    push!(rules, Dict("func" => "print",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "Nothing"), "desc" => "print → Nothing"))

    # --- Range ---
    push!(rules, Dict("func" => "colon",
        "args" => [Dict("var" => "T", "bound" => "Integer"), Dict("var" => "T")],
        "returns" => Dict("container" => "UnitRange", "typevar" => "T"), "desc" => "a:b → UnitRange{T}"))
    push!(rules, Dict("func" => "colon",
        "args" => [Dict("var" => "T", "bound" => "Integer"), Dict("var" => "T"), Dict("var" => "T")],
        "returns" => Dict("container" => "StepRange", "typevar" => "T"), "desc" => "a:s:b → StepRange{T}"))

    # --- Control flow ---
    push!(rules, Dict("func" => "error",
        "args" => [Dict("type" => "String")],
        "returns" => Dict("type" => "Bottom"), "desc" => "error → Bottom"))
    push!(rules, Dict("func" => "throw",
        "args" => [Dict("type" => "Any")],
        "returns" => Dict("type" => "Bottom"), "desc" => "throw → Bottom"))

    # --- zero/one/typemin/typemax ---
    for fname in ["zero", "one", "typemin", "typemax"]
        push!(rules, Dict("func" => fname,
            "args" => [Dict("typeparam" => "T")],
            "returns" => Dict("var" => "T"), "desc" => "$(fname)(T) → T"))
    end

    return rules
end

# === Serialization ===

const MAGIC = UInt8[0x4a, 0x4c, 0x54, 0x49]  # "JLTI"
const FORMAT_VERSION = UInt32(1)

"""
    serialize_tables(path, type_reg, func_reg, table, rules)

Write inference tables to a binary file.

Format:
  Header (24 bytes): magic(4) + version(4) + json_offset(4) + json_length(4) + hash_offset(4) + hash_length(4)
  Hash table section: capacity(4) + entry_size(4) + flat Int32 data
  JSON section: UTF-8 encoded JSON with type registry, function registry, and parametric rules
"""
function serialize_tables(path::String, type_reg::TypeRegistry, func_reg::FuncRegistry,
                          table::InferenceHashTable, rules::Vector{Dict{String,Any}})
    # Build JSON payload
    json_data = _build_json(type_reg, func_reg, rules)
    json_bytes = Vector{UInt8}(json_data)

    # Calculate offsets
    header_size = 24
    hash_section_size = 8 + length(table.data) * 4  # capacity + entry_size + flat data
    hash_offset = UInt32(header_size)
    hash_length = UInt32(hash_section_size)
    json_offset = UInt32(header_size + hash_section_size)
    json_length = UInt32(length(json_bytes))

    open(path, "w") do f
        # Header
        write(f, MAGIC)
        write(f, FORMAT_VERSION)
        write(f, json_offset)
        write(f, json_length)
        write(f, hash_offset)
        write(f, hash_length)

        # Hash table section
        write(f, table.capacity)
        write(f, Int32(ENTRY_INTS))
        write(f, table.data)

        # JSON section
        write(f, json_bytes)
    end
end

function _build_json(type_reg::TypeRegistry, func_reg::FuncRegistry, rules::Vector{Dict{String,Any}})
    buf = IOBuffer()
    print(buf, "{")

    # Types
    print(buf, "\"types\":[")
    type_entries = sort(collect(type_reg.type_to_id), by=x->x[2])
    for (i, (t, id)) in enumerate(type_entries)
        i > 1 && print(buf, ",")
        name = type_reg.id_to_name[id]
        kind = type_reg.id_to_kind[id]
        # Escape JSON string
        escaped_name = replace(replace(name, "\\" => "\\\\"), "\"" => "\\\"")
        print(buf, "{\"id\":$(id),\"name\":\"$(escaped_name)\",\"kind\":$(kind)}")
    end
    print(buf, "],")

    # Functions
    print(buf, "\"functions\":[")
    func_entries = sort(collect(func_reg.name_to_id), by=x->x[2])
    for (i, (name, id)) in enumerate(func_entries)
        i > 1 && print(buf, ",")
        escaped_name = replace(replace(name, "\\" => "\\\\"), "\"" => "\\\"")
        print(buf, "{\"id\":$(id),\"name\":\"$(escaped_name)\"}")
    end
    print(buf, "],")

    # Rules
    print(buf, "\"rules\":")
    _write_json_value(buf, rules)

    print(buf, "}")
    return String(take!(buf))
end

# Minimal JSON serializer for rules (nested Dicts/Vectors/Strings/Numbers)
function _write_json_value(buf::IOBuffer, v::Vector)
    print(buf, "[")
    for (i, item) in enumerate(v)
        i > 1 && print(buf, ",")
        _write_json_value(buf, item)
    end
    print(buf, "]")
end

function _write_json_value(buf::IOBuffer, d::Dict)
    print(buf, "{")
    for (i, (k, v)) in enumerate(sort(collect(d), by=x->x[1]))
        i > 1 && print(buf, ",")
        print(buf, "\"$(k)\":")
        _write_json_value(buf, v)
    end
    print(buf, "}")
end

function _write_json_value(buf::IOBuffer, s::AbstractString)
    escaped = replace(replace(s, "\\" => "\\\\"), "\"" => "\\\"")
    print(buf, "\"$(escaped)\"")
end

function _write_json_value(buf::IOBuffer, n::Number)
    print(buf, n)
end

# === Public API ===

"""
    build_inference_tables(output_path; verbose=false) → NamedTuple

Pre-compute inference tables for the browser inference engine.
Runs Base.code_typed() for all supported Base methods and produces:
- TypeID registry (type names → Int32)
- Return-type hash table (FNV-1a + linear probe)
- Parametric rules (~200+ rules for type patterns)

Output is a binary file (.bin) suitable for loading in JS.
"""
function build_inference_tables(output_path::String; verbose::Bool=false)
    type_reg = TypeRegistry()
    func_reg = FuncRegistry()

    verbose && println("Enumerating Base methods...")
    entries = enumerate_base_methods(type_reg, func_reg; verbose=verbose)
    verbose && println("  $(length(entries)) return-type entries")

    # Build hash table with 2x capacity for good load factor
    table = InferenceHashTable(max(64, length(entries) * 2))
    duplicates = 0
    for entry in entries
        # Check for duplicates (same func + args)
        existing = lookup(table, entry.func_id, entry.arg_type_ids)
        if existing >= 0
            duplicates += 1
            continue
        end
        insert!(table, entry)
    end
    verbose && println("  $(table.count) unique hash table entries ($(duplicates) duplicates skipped)")

    verbose && println("Generating parametric rules...")
    rules = generate_parametric_rules()
    verbose && println("  $(length(rules)) rules")

    verbose && println("Serializing to $(output_path)...")
    serialize_tables(output_path, type_reg, func_reg, table, rules)

    file_size = filesize(output_path)
    verbose && println("  $(file_size) bytes ($(round(file_size/1024, digits=1)) KB)")

    return (
        num_types = length(type_reg.type_to_id),
        num_entries = Int(table.count),
        num_rules = length(rules),
        file_size = file_size,
        hash_capacity = Int(table.capacity),
        num_functions = length(func_reg.name_to_id),
    )
end
