"""
    get_typed_ir(f, arg_types; optimize=true)

Extract typed IR from Julia's compiler via `Base.code_typed()`.
Returns `(CodeInfo, return_type)`.
"""
function get_typed_ir(f, arg_types::Tuple; optimize::Bool=true)
    results = Base.code_typed(f, arg_types; optimize=optimize)
    code_info, return_type = results[1]
    return code_info, return_type
end
