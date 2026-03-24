"""
    compile_function(ctx::JSCompilationContext) -> String

Compile a single function's IR to JavaScript source code.
Handles control flow: if/else, while loops, phi nodes.
"""
function compile_function(ctx::JSCompilationContext)
    code = ctx.code_info.code
    n = length(code)

    # === Pass 1: Analyze control flow ===
    # Find all jump targets (block start points)
    block_starts = Set{Int}([1])
    backward_edges = Dict{Int, Int}()   # source_idx → target_idx (loops)
    forward_gotos = Dict{Int, Int}()    # source_idx → target_idx

    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode
            push!(block_starts, stmt.label)
            if stmt.label <= i
                backward_edges[i] = stmt.label
            else
                forward_gotos[i] = stmt.label
            end
            # Statement after goto is a new block
            if i + 1 <= n
                push!(block_starts, i + 1)
            end
        elseif stmt isa Core.GotoIfNot
            push!(block_starts, stmt.dest)
            if i + 1 <= n
                push!(block_starts, i + 1)
            end
        end
    end

    loop_headers = Set(values(backward_edges))

    # === Pass 2: Collect phi nodes ===
    phi_info = Dict{Int, Core.PhiNode}()  # SSA idx → PhiNode
    for (i, stmt) in enumerate(code)
        if stmt isa Core.PhiNode
            get_local!(ctx, i)  # Allocate variable name
            phi_info[i] = stmt
        end
    end

    # === Pass 3: Pre-allocate locals for SSA values used across blocks ===
    # Any SSA value referenced from a different block needs a local
    for (i, stmt) in enumerate(code)
        if stmt isa Expr && stmt.head in (:call, :invoke, :new)
            # Check if this value is used anywhere
            for (j, other) in enumerate(code)
                if j != i && references_ssa(other, i)
                    get_local!(ctx, i)
                    break
                end
            end
        end
    end

    # === Pass 4: Emit structured code ===
    buf = IOBuffer()
    args_str = join(ctx.arg_names, ", ")
    print(buf, "function $(ctx.func_name)($(args_str)) {\n")

    # Declare all locals
    declared = sort(collect(keys(ctx.js_locals)))
    for idx in declared
        print(buf, "  let $(ctx.js_locals[idx]);\n")
    end

    # Emit the code body
    emit_structured!(ctx, buf, code, 1, n, loop_headers, backward_edges, forward_gotos, phi_info, 1)

    print(buf, "}\n")
    return String(take!(buf))
end

"""
Check if a statement references a given SSA value.
"""
function references_ssa(stmt, ssa_id::Int)
    target = Core.SSAValue(ssa_id)
    if stmt isa Core.ReturnNode
        return isdefined(stmt, :val) && stmt.val == target
    elseif stmt isa Core.GotoIfNot
        return stmt.cond == target
    elseif stmt isa Expr
        return any(a -> a == target, stmt.args)
    elseif stmt isa Core.PhiNode
        for k in 1:length(stmt.edges)
            if isassigned(stmt.values, k) && stmt.values[k] == target
                return true
            end
        end
        return false
    end
    return false
end

"""
Emit structured JS code for a range of IR statements.
Uses pattern matching to detect if/else and while loop structures.
"""
function emit_structured!(ctx, buf, code, start_idx, end_idx, loop_headers, backward_edges, forward_gotos, phi_info, depth)
    indent = "  " ^ depth
    i = start_idx

    while i <= end_idx
        stmt = code[i]

        # Skip nothing statements (loop entry edges, etc.)
        if stmt === nothing
            i += 1
            continue
        end

        # Check for loop header FIRST (before PhiNode, since loop headers start with phis)
        if i in loop_headers
            # Start of a while loop — find the backward edge that targets this
            loop_end = 0
            for (src, tgt) in backward_edges
                if tgt == i
                    loop_end = src
                    break
                end
            end

            # Initialize phi variables for loop entry
            for phi_idx in sort(collect(keys(phi_info)))
                if phi_idx >= i && phi_idx <= loop_end
                    phi = phi_info[phi_idx]
                    var_name = ctx.js_locals[phi_idx]
                    for (k, edge) in enumerate(phi.edges)
                        if edge < i  # Initial value from before loop
                            if isassigned(phi.values, k)
                                val = compile_value(ctx, phi.values[k])
                                print(buf, "$(indent)$(var_name) = $(val);\n")
                            end
                        end
                    end
                end
            end

            print(buf, "$(indent)while (true) {\n")

            # Emit loop body (skip phi nodes at header, they're handled above)
            loop_body_start = i
            while loop_body_start <= loop_end && code[loop_body_start] isa Core.PhiNode
                loop_body_start += 1
            end

            emit_loop_body!(ctx, buf, code, loop_body_start, loop_end, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, i)

            print(buf, "$(indent)}\n")
            i = loop_end + 1
            continue
        end

        # Non-loop PhiNode (merge point from if/else)
        if stmt isa Core.PhiNode
            if haskey(phi_info, i)
                phi = phi_info[i]
                var_name = ctx.js_locals[i]
                # Assign from the most recent edge
                for (k, edge) in enumerate(phi.edges)
                    if isassigned(phi.values, k)
                        val = compile_value(ctx, phi.values[k])
                        print(buf, "$(indent)$(var_name) = $(val);\n")
                        break  # Take first available
                    end
                end
            end
            i += 1
            continue
        end

        if stmt isa Core.GotoIfNot
            cond = compile_value(ctx, stmt.cond)
            target = stmt.dest

            # Forward branch: if (!cond) goto target
            # Find if there's a GotoNode at target-1 that jumps past target (if-else pattern)
            has_else = false
            merge_point = target
            if target - 1 >= i + 1 && target - 1 <= end_idx
                prev_stmt = code[target - 1]
                if prev_stmt isa Core.GotoNode && prev_stmt.label > target
                    has_else = true
                    merge_point = prev_stmt.label
                end
            end

            if has_else
                # if/else: true branch = i+1..target-2, false branch = target..merge-1
                print(buf, "$(indent)if ($(cond)) {\n")
                emit_structured!(ctx, buf, code, i + 1, target - 2, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                print(buf, "$(indent)} else {\n")
                emit_structured!(ctx, buf, code, target, merge_point - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                print(buf, "$(indent)}\n")
                i = merge_point
            else
                # if-then: GotoIfNot(cond, target) means if cond is true, fall through (i+1..target-1)
                # then continue at target
                print(buf, "$(indent)if ($(cond)) {\n")
                emit_structured!(ctx, buf, code, i + 1, target - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                print(buf, "$(indent)}\n")
                i = target
            end
            continue
        end

        if stmt isa Core.GotoNode
            # Forward goto: skip (handled by if/else structure)
            # Backward goto: handled by loop structure
            i += 1
            continue
        end

        # Regular statement
        emit_single_stmt!(ctx, buf, code, i, phi_info, indent, depth)
        i += 1
    end
end

"""
Emit the body of a while loop.
"""
function emit_loop_body!(ctx, buf, code, start_idx, end_idx, loop_headers, backward_edges, forward_gotos, phi_info, depth, loop_header)
    indent = "  " ^ depth
    i = start_idx

    while i <= end_idx
        stmt = code[i]

        if stmt isa Core.GotoIfNot
            cond = compile_value(ctx, stmt.cond)
            target = stmt.dest

            if target > end_idx
                # Loop exit condition
                print(buf, "$(indent)if (!($(cond))) break;\n")
                i += 1
                continue
            else
                # Inner if/else within loop
                has_else = false
                merge_point = target
                if target - 1 >= i + 1 && target - 1 <= end_idx
                    prev_stmt = code[target - 1]
                    if prev_stmt isa Core.GotoNode && prev_stmt.label > target && prev_stmt.label <= end_idx + 1
                        has_else = true
                        merge_point = prev_stmt.label
                    end
                end

                if has_else
                    print(buf, "$(indent)if ($(cond)) {\n")
                    emit_loop_body!(ctx, buf, code, i + 1, target - 2, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                    print(buf, "$(indent)} else {\n")
                    emit_loop_body!(ctx, buf, code, target, merge_point - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                    print(buf, "$(indent)}\n")
                    i = merge_point
                else
                    # if-then: true branch = i+1..target-1, continue at target
                    # Check if target is a PhiNode (merge point) — emit as if/else with phi assignment
                    if target <= length(code) && code[target] isa Core.PhiNode && haskey(phi_info, target)
                        phi = phi_info[target]
                        var_name = ctx.js_locals[target]
                        # Find the phi values for each branch
                        then_val = nothing
                        else_val = nothing
                        for (k, edge) in enumerate(phi.edges)
                            if isassigned(phi.values, k)
                                if edge >= i + 1 && edge < target  # from then branch
                                    then_val = compile_value(ctx, phi.values[k])
                                elseif edge == i || edge < i + 1  # from the GotoIfNot (skip branch)
                                    else_val = compile_value(ctx, phi.values[k])
                                end
                            end
                        end

                        # Emit as if/else to properly assign phi
                        print(buf, "$(indent)if ($(cond)) {\n")
                        inner_indent = "  " ^ (depth + 1)
                        emit_loop_body!(ctx, buf, code, i + 1, target - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                        if then_val !== nothing
                            print(buf, "$(inner_indent)$(var_name) = $(then_val);\n")
                        end
                        print(buf, "$(indent)} else {\n")
                        if else_val !== nothing
                            print(buf, "$(inner_indent)$(var_name) = $(else_val);\n")
                        end
                        print(buf, "$(indent)}\n")
                        i = target + 1  # Skip the phi node
                    else
                        print(buf, "$(indent)if ($(cond)) {\n")
                        emit_loop_body!(ctx, buf, code, i + 1, target - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                        print(buf, "$(indent)}\n")
                        i = target
                    end
                end
                continue
            end
        end

        if stmt isa Core.GotoNode
            if stmt.label <= i  # Backward edge = end of loop iteration
                # Update ONLY loop header phi variables (consecutive phis starting at loop_header)
                phi_idx = loop_header
                while phi_idx <= end_idx && haskey(phi_info, phi_idx) && code[phi_idx] isa Core.PhiNode
                    phi = phi_info[phi_idx]
                    var_name = ctx.js_locals[phi_idx]
                    for (k, edge) in enumerate(phi.edges)
                        if edge >= loop_header && edge <= end_idx  # Update from within loop
                            if isassigned(phi.values, k)
                                val = compile_value(ctx, phi.values[k])
                                print(buf, "$(indent)$(var_name) = $(val);\n")
                            end
                        end
                    end
                    phi_idx += 1
                end
            end
            i += 1
            continue
        end

        if stmt isa Core.PhiNode
            # Inner phi nodes (merge after if-then within loop)
            # These need to be resolved: the if-then already assigned the "then" value,
            # but we need to set the default "else" value when the if wasn't taken
            if haskey(phi_info, i)
                # The phi is already handled by the if-then block structure:
                # the "then" path sets the variable inside the if, and we set the default here
                # We need to emit this as a conditional assignment
                # Skip for now — the if-then block should handle assignment
            end
            i += 1
            continue
        end

        emit_single_stmt!(ctx, buf, code, i, phi_info, indent, depth)
        i += 1
    end
end

"""
Emit a single non-control-flow statement.
"""
function emit_single_stmt!(ctx, buf, code, idx, phi_info, indent, depth)
    stmt = code[idx]

    if stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            val = compile_value(ctx, stmt.val)
            print(buf, "$(indent)return $(val);\n")
        else
            # Unreachable return
            print(buf, "$(indent)return;\n")
        end
    elseif stmt isa Expr
        compile_expr_stmt!(ctx, buf, idx, stmt, indent)
    elseif stmt isa Core.PiNode
        # No-op
    elseif stmt === nothing
        # No-op
    elseif stmt isa Core.PhiNode
        # Handled elsewhere
    elseif stmt isa Core.GotoNode || stmt isa Core.GotoIfNot
        # Handled by control flow
    else
        # Literal
        if haskey(ctx.js_locals, idx)
            name = ctx.js_locals[idx]
            val = compile_value(ctx, stmt)
            print(buf, "$(indent)$(name) = $(val);\n")
        end
    end
end

"""
Emit an expression statement, assigning to local if needed.
"""
function compile_expr_stmt!(ctx, buf, idx, expr::Expr, indent::String)
    if expr.head === :call
        result = compile_call(ctx, expr)
        if haskey(ctx.js_locals, idx)
            name = ctx.js_locals[idx]
            print(buf, "$(indent)$(name) = $(result);\n")
        else
            # Side-effect only call
            print(buf, "$(indent)$(result);\n")
        end
    elseif expr.head === :invoke
        result = compile_invoke(ctx, expr)
        if haskey(ctx.js_locals, idx)
            name = ctx.js_locals[idx]
            print(buf, "$(indent)$(name) = $(result);\n")
        else
            print(buf, "$(indent)$(result);\n")
        end
    elseif expr.head === :new
        result = compile_new_expr(ctx, expr)
        if haskey(ctx.js_locals, idx)
            name = ctx.js_locals[idx]
            print(buf, "$(indent)$(name) = $(result);\n")
        else
            print(buf, "$(indent)$(result);\n")
        end
    elseif expr.head === :boundscheck
        # Bounds check: always false in JS (skip bounds checking)
        if haskey(ctx.js_locals, idx)
            name = ctx.js_locals[idx]
            print(buf, "$(indent)$(name) = false;\n")
        end
    end
end

"""
Compile a :call expression (intrinsics, builtins, generic calls).
"""
function compile_call(ctx::JSCompilationContext, expr::Expr)
    args = expr.args
    callee = args[1]

    # Check for Core.Intrinsics — may be referenced via Base.add_int etc.
    if callee isa GlobalRef
        resolved = try
            getfield(callee.mod, callee.name)
        catch
            nothing
        end
        if resolved isa Core.IntrinsicFunction
            return compile_intrinsic(ctx, callee.name, args[2:end])
        end
    end

    # Check for known builtins
    if callee isa GlobalRef
        bname = callee.name
        if bname === :ifelse
            cond = compile_value(ctx, args[2])
            t_val = compile_value(ctx, args[3])
            f_val = compile_value(ctx, args[4])
            return "($(cond) ? $(t_val) : $(f_val))"
        end

        # Base.string(...) → template literal
        if bname === :string && callee.mod === Base
            return compile_string_concat(ctx, args[2:end])
        end
    end

    # Handle Core.=== (egal)
    if callee isa typeof(Core.:(===)) || (callee isa GlobalRef && callee.name === :(===))
        a = compile_value(ctx, args[2])
        b = compile_value(ctx, args[3])
        return "$(a) === $(b)"
    end

    # Handle isa(x, T) type checks
    is_isa = callee isa typeof(isa) ||
             (callee isa GlobalRef && callee.name === :isa)
    if is_isa && length(args) >= 3
        x_val = compile_value(ctx, args[2])
        type_arg = args[3]
        # Resolve the type
        T = if type_arg isa GlobalRef
            try getfield(type_arg.mod, type_arg.name) catch; nothing end
        elseif type_arg isa Type || type_arg isa DataType
            type_arg
        else
            nothing
        end
        if T === Nothing
            return "$(x_val) === null"
        elseif T === Int32 || T === Int64 || T === UInt32 || T === UInt64 || T === Float64 || T === Float32
            return "typeof $(x_val) === \"number\""
        elseif T === String
            return "typeof $(x_val) === \"string\""
        elseif T === Bool
            return "typeof $(x_val) === \"boolean\""
        elseif T isa DataType && !(T <: Number) && !(T <: AbstractString) && T !== Bool && T !== Nothing
            # Struct type: use instanceof
            type_name = string(nameof(T))
            push!(ctx.struct_types, T)
            return "$(x_val) instanceof $(type_name)"
        end
    end

    # Handle Core.getfield / Base.getfield for captured closure variables and struct fields
    if callee isa GlobalRef && callee.name === :getfield && (callee.mod === Core || callee.mod === Base)
        obj = args[2]
        field_arg = args[3]
        # Closure captured variable: getfield(self, :name)
        if obj isa Core.Argument && obj.n == 1 && field_arg isa QuoteNode && field_arg.value isa Symbol
            fname = field_arg.value
            if haskey(ctx.captured_vars, fname)
                return ctx.captured_vars[fname]
            end
        end
        # Vector length: getfield(getfield(v, :size), 1, boundscheck) → v.length
        if obj isa Core.SSAValue && field_arg isa Int64
            obj_stmt = ctx.code_info.code[obj.id]
            if obj_stmt isa Expr && obj_stmt.head === :call
                obj_callee = obj_stmt.args[1]
                if obj_callee isa GlobalRef && obj_callee.name === :getfield
                    inner_field = obj_stmt.args[3]
                    if inner_field isa QuoteNode && inner_field.value === :size
                        # This is getfield(getfield(v, :size), 1) → v.length
                        arr_val = compile_value(ctx, obj_stmt.args[2])
                        return "$(arr_val).length"
                    end
                end
            end
        end

        # Skip internal Vector fields (ref, size, etc.)
        if field_arg isa QuoteNode && field_arg.value in (:ref, :size, :mem, :length)
            obj_type = _get_ssa_type(ctx, obj)
            if obj_type !== nothing && (obj_type <: AbstractArray || obj_type <: Memory)
                return "/* internal: $(field_arg.value) */ undefined"
            end
        end

        # General field access
        obj_val = compile_value(ctx, obj)
        field_name = if field_arg isa QuoteNode && field_arg.value isa Symbol
            string(field_arg.value)
        else
            compile_value(ctx, field_arg)
        end
        return "$(obj_val).$(field_name)"
    end

    # Handle array memory operations (Julia 1.12 memoryref model)
    if callee isa GlobalRef && callee.mod === Base
        if callee.name === :memoryrefget
            # memoryrefget(ref, :not_atomic, false) → array element read
            # Trace back: ref = memoryrefnew(base, idx, false), base = getfield(arr, :ref)
            ref_ssa = args[2]
            if ref_ssa isa Core.SSAValue
                ref_stmt = ctx.code_info.code[ref_ssa.id]
                if ref_stmt isa Expr && ref_stmt.head === :call
                    ref_callee = ref_stmt.args[1]
                    if ref_callee isa GlobalRef && ref_callee.name === :memoryrefnew
                        base_ref = ref_stmt.args[2]
                        idx_val = ref_stmt.args[3]
                        # base_ref should be getfield(arr, :ref)
                        arr_js = _trace_array_ref(ctx, base_ref)
                        if arr_js !== nothing
                            idx_js = compile_value(ctx, idx_val)
                            return "$(arr_js)[($(idx_js)) - 1]"
                        end
                    end
                end
            end
        elseif callee.name === :memoryrefset!
            # memoryrefset!(ref, val, :not_atomic, false) → array element write
            ref_ssa = args[2]
            new_val = args[3]
            if ref_ssa isa Core.SSAValue
                ref_stmt = ctx.code_info.code[ref_ssa.id]
                if ref_stmt isa Expr && ref_stmt.head === :call
                    ref_callee = ref_stmt.args[1]
                    if ref_callee isa GlobalRef && ref_callee.name === :memoryrefnew
                        base_ref = ref_stmt.args[2]
                        idx_val = ref_stmt.args[3]
                        arr_js = _trace_array_ref(ctx, base_ref)
                        if arr_js !== nothing
                            idx_js = compile_value(ctx, idx_val)
                            val_js = compile_value(ctx, new_val)
                            return "$(arr_js)[($(idx_js)) - 1] = $(val_js)"
                        end
                    end
                end
            end
        elseif callee.name === :memoryrefnew
            # Usually consumed by memoryrefget/set — skip
            return "undefined /* memoryrefnew */"
        elseif callee.name === :memoryrefoffset
            return "undefined /* memoryrefoffset */"
        end
    end

    # Handle Base.setfield! for mutable structs
    if callee isa GlobalRef && callee.name === :setfield! && (callee.mod === Core || callee.mod === Base)
        obj = compile_value(ctx, args[2])
        field_arg = args[3]
        field_name = if field_arg isa QuoteNode && field_arg.value isa Symbol
            string(field_arg.value)
        else
            compile_value(ctx, field_arg)
        end
        val = compile_value(ctx, args[4])
        return "$(obj).$(field_name) = $(val)"
    end

    # Handle Core.tuple
    if callee isa GlobalRef && callee.mod === Core && callee.name === :tuple
        vals = [compile_value(ctx, a) for a in args[2:end]]
        return "[$(join(vals, ", "))]"
    end

    # Handle not_int called as a builtin (boolean negation)
    if callee isa GlobalRef && callee.name === :not_int
        resolved = try getfield(callee.mod, callee.name) catch; nothing end
        if resolved isa Core.IntrinsicFunction
            return compile_intrinsic(ctx, :not_int, args[2:end])
        end
    end

    # Generic call — will be expanded later
    callee_name = compile_value(ctx, callee)
    call_args = [compile_value(ctx, a) for a in args[2:end]]
    return "$(callee_name)($(join(call_args, ", ")))"
end

"""
Compile an :invoke expression (direct method call).
"""
function compile_invoke(ctx::JSCompilationContext, expr::Expr)
    # In Julia 1.12, args[1] is CodeInstance; in earlier versions, MethodInstance
    ci_or_mi = expr.args[1]
    mi = if ci_or_mi isa Core.CodeInstance
        ci_or_mi.def
    else
        ci_or_mi
    end
    meth = mi.def
    func_name = string(meth.name)
    call_args = [compile_value(ctx, a) for a in expr.args[3:end]]

    # Known function mappings
    math_fns = Dict(
        "sin" => "Math.sin", "cos" => "Math.cos", "tan" => "Math.tan",
        "asin" => "Math.asin", "acos" => "Math.acos", "atan" => "Math.atan",
        "exp" => "Math.exp", "log" => "Math.log", "log2" => "Math.log2", "log10" => "Math.log10",
        "sqrt" => "Math.sqrt", "sqrt_llvm" => "Math.sqrt",
        "abs" => "Math.abs", "min" => "Math.min", "max" => "Math.max",
        "floor" => "Math.floor", "ceil" => "Math.ceil", "round" => "Math.round",
        "trunc" => "Math.trunc", "sign" => "Math.sign",
        "hypot" => "Math.hypot", "atan2" => "Math.atan2",
    )
    if haskey(math_fns, func_name)
        js_fn = math_fns[func_name]
        return "$(js_fn)($(join(call_args, ", ")))"
    end

    if func_name == "throw_complex_domainerror"
        return "(() => { throw new Error('DomainError') })()"
    end

    # String operations: _string and print_to_string → template literal
    if func_name == "_string" || func_name == "print_to_string"
        # args[3:end] are the values to concatenate (skip CodeInstance and GlobalRef)
        return compile_string_concat(ctx, expr.args[3:end])
    end

    # String repeat: s.repeat(n)
    if func_name == "repeat"
        s_val = compile_value(ctx, expr.args[3])
        n_val = compile_value(ctx, expr.args[4])
        return "$(s_val).repeat($(n_val))"
    end

    return "$(func_name)($(join(call_args, ", ")))"
end

"""
Compile a :new expression. Handles closure creation and struct construction.
"""
function compile_new_expr(ctx::JSCompilationContext, expr::Expr)
    T_ref = expr.args[1]
    field_args = expr.args[2:end]

    # Resolve type: could be a DataType, GlobalRef, or Argument
    T = if T_ref isa DataType
        T_ref
    elseif T_ref isa GlobalRef
        try getfield(T_ref.mod, T_ref.name) catch; nothing end
    elseif T_ref isa Core.Argument
        # In constructors, Argument(1) is the type — get from arg_types context
        nothing  # Can't resolve at compile time from within the constructor
    else
        nothing
    end

    if T isa DataType && T <: Function
        return compile_closure_creation(ctx, T, field_args)
    elseif T isa DataType
        # Struct construction: register the type and emit new
        push!(ctx.struct_types, T)
        type_name = string(nameof(T))
        args_js = [compile_value(ctx, a) for a in field_args]
        return "new $(type_name)($(join(args_js, ", ")))"
    else
        # Fallback: try to get type name from GlobalRef
        type_name = if T_ref isa GlobalRef
            string(T_ref.name)
        else
            "UnknownType"
        end
        args_js = [compile_value(ctx, a) for a in field_args]
        return "new $(type_name)($(join(args_js, ", ")))"
    end
end

"""
Compile closure creation: %new(ClosureType, captured...) → JS function expression.
"""
function compile_closure_creation(ctx::JSCompilationContext, T::DataType, captured_args::AbstractVector)
    # Get field names (= captured variable names)
    fnames = fieldnames(T)

    # Map captured field names to their JS values from the outer context
    captured_vals = Dict{Symbol, String}()
    for (i, arg) in enumerate(captured_args)
        captured_vals[fnames[i]] = compile_value(ctx, arg)
    end

    # Find the closure's method via _methods_by_ftype
    ftype = Tuple{T, Vararg{Any}}
    matches = Base._methods_by_ftype(ftype, -1, Base.get_world_counter())
    isempty(matches) && error("No method found for closure type $T")
    m = first(matches).method

    # Get the non-self parameter types from the method signature
    param_types = m.sig.parameters[2:end]

    # Get typed IR (use code_typed_by_type since code_typed(Method, ...) may return empty)
    ci, rt = Base.code_typed_by_type(Tuple{T, param_types...}; optimize=true)[1]

    # Build argument names for the closure (skip #self# at slot 1)
    nargs = length(param_types)
    closure_arg_names = String[]
    for i in 1:nargs
        slot_idx = i + 1
        if slot_idx <= length(ci.slotnames)
            push!(closure_arg_names, string(ci.slotnames[slot_idx]))
        else
            push!(closure_arg_names, "arg$i")
        end
    end

    # Create a context for the closure body
    closure_arg_types = tuple(param_types...)
    closure_ctx = JSCompilationContext(ci, closure_arg_types, rt, "")
    closure_ctx.arg_names = closure_arg_names
    closure_ctx.captured_vars = captured_vals

    # Compile the closure body
    js_body = compile_function(closure_ctx)

    # compile_function emits "function (args) { ... }\n" (empty name)
    return strip(js_body)
end

"""
Trace an SSA value back to find the array it references.
Returns a JS expression for the array, or nothing if can't trace.
"""
function _trace_array_ref(ctx::JSCompilationContext, val)
    if val isa Core.SSAValue
        stmt = ctx.code_info.code[val.id]
        if stmt isa Expr && stmt.head === :call
            callee = stmt.args[1]
            # getfield(arr, :ref) → the array
            if callee isa GlobalRef && callee.name === :getfield
                obj = stmt.args[2]
                field = stmt.args[3]
                if field isa QuoteNode && field.value === :ref
                    return compile_value(ctx, obj)
                end
            end
        end
    end
    return nothing
end

"""
Get the SSA type of a value from the context.
"""
function _get_ssa_type(ctx::JSCompilationContext, val)
    if val isa Core.SSAValue && val.id <= length(ctx.ssa_types)
        return ctx.ssa_types[val.id]
    elseif val isa Core.Argument
        idx = val.n - 1
        if idx >= 1 && idx <= length(ctx.arg_types)
            return ctx.arg_types[idx]
        end
    end
    return nothing
end

"""
Register struct types that need class definitions, decomposing Union types.
"""
function register_struct_types!(ctx::JSCompilationContext, T)
    if T isa Union
        register_struct_types!(ctx, T.a)
        register_struct_types!(ctx, T.b)
    elseif T isa DataType && !(T <: Number) && !(T <: AbstractString) && T !== Bool && T !== Nothing && !(T <: Function) && !(T <: AbstractArray) && !(T <: AbstractDict) && !(T <: AbstractSet) && !(T <: Tuple) && !(T <: IO) && T.name.module !== Base && T.name.module !== Core
        push!(ctx.struct_types, T)
    end
end

"""
Generate ES6 class definition for a Julia struct type.
"""
function generate_struct_class(T::DataType)
    name = string(nameof(T))
    fnames = fieldnames(T)
    buf = IOBuffer()
    print(buf, "class $(name) {\n")
    # Constructor
    args_str = join([string(f) for f in fnames], ", ")
    print(buf, "  constructor($(args_str)) {\n")
    for f in fnames
        print(buf, "    this.$(f) = $(f);\n")
    end
    print(buf, "  }\n")
    print(buf, "}\n")
    return String(take!(buf))
end

"""
Escape a string for use inside a JS template literal.
"""
function escape_template_literal(s::String)
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "`" => "\\`")
    s = replace(s, "\$" => "\\\$")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    return s
end

"""
Compile a string concatenation (from Base._string or Base.print_to_string) to a JS template literal.
"""
function compile_string_concat(ctx::JSCompilationContext, args::AbstractVector)
    buf = IOBuffer()
    print(buf, '`')
    for arg in args
        if arg isa String
            print(buf, escape_template_literal(arg))
        else
            val = compile_value(ctx, arg)
            print(buf, "\${", val, "}")
        end
    end
    print(buf, '`')
    return String(take!(buf))
end

"""
Compile a Core.Intrinsics call to JavaScript.
"""
function compile_intrinsic(ctx::JSCompilationContext, name::Symbol, args::AbstractVector)
    compiled_args = [compile_value(ctx, a) for a in args]

    if name === :add_int
        return "($(compiled_args[1]) + $(compiled_args[2])) | 0"
    elseif name === :sub_int
        return "($(compiled_args[1]) - $(compiled_args[2])) | 0"
    elseif name === :mul_int
        return "Math.imul($(compiled_args[1]), $(compiled_args[2]))"
    elseif name === :neg_int
        return "(-($(compiled_args[1]))) | 0"
    elseif name === :add_float
        return "$(compiled_args[1]) + $(compiled_args[2])"
    elseif name === :sub_float
        return "$(compiled_args[1]) - $(compiled_args[2])"
    elseif name === :mul_float
        return "$(compiled_args[1]) * $(compiled_args[2])"
    elseif name === :div_float
        return "$(compiled_args[1]) / $(compiled_args[2])"
    elseif name === :eq_int
        return "$(compiled_args[1]) === $(compiled_args[2])"
    elseif name === :ne_int
        return "$(compiled_args[1]) !== $(compiled_args[2])"
    elseif name === :slt_int
        return "$(compiled_args[1]) < $(compiled_args[2])"
    elseif name === :sle_int
        return "$(compiled_args[1]) <= $(compiled_args[2])"
    elseif name === :eq_float
        return "$(compiled_args[1]) === $(compiled_args[2])"
    elseif name === :ne_float
        return "$(compiled_args[1]) !== $(compiled_args[2])"
    elseif name === :lt_float
        return "$(compiled_args[1]) < $(compiled_args[2])"
    elseif name === :le_float
        return "$(compiled_args[1]) <= $(compiled_args[2])"
    elseif name === :and_int
        return "($(compiled_args[1]) & $(compiled_args[2]))"
    elseif name === :or_int
        return "($(compiled_args[1]) | $(compiled_args[2]))"
    elseif name === :xor_int
        return "($(compiled_args[1]) ^ $(compiled_args[2]))"
    elseif name === :shl_int
        return "($(compiled_args[1]) << $(compiled_args[2]))"
    elseif name === :lshr_int
        return "($(compiled_args[1]) >>> $(compiled_args[2]))"
    elseif name === :ashr_int
        return "($(compiled_args[1]) >> $(compiled_args[2]))"
    elseif name === :not_int
        return "(~$(compiled_args[1]))"
    elseif name === :abs_float
        return "Math.abs($(compiled_args[1]))"
    elseif name === :neg_float
        return "-($(compiled_args[1]))"
    elseif name === :sqrt_llvm
        return "Math.sqrt($(compiled_args[1]))"
    elseif name === :ceil_llvm
        return "Math.ceil($(compiled_args[1]))"
    elseif name === :floor_llvm
        return "Math.floor($(compiled_args[1]))"
    elseif name === :trunc_llvm
        return "Math.trunc($(compiled_args[1]))"
    elseif name === :sitofp
        return "+($(compiled_args[2]))"
    elseif name === :fptosi
        return "Math.trunc($(compiled_args[2])) | 0"
    elseif name === :bitcast
        return compiled_args[2]
    elseif name === :sext_int
        return "($(compiled_args[2])) | 0"
    elseif name === :trunc_int
        return "($(compiled_args[2])) | 0"
    elseif name === :zext_int
        return "($(compiled_args[2])) >>> 0"
    elseif name === :ult_int
        # Unsigned less than — used in bounds checking
        return "($(compiled_args[1]) >>> 0) < ($(compiled_args[2]) >>> 0)"
    else
        error("Unsupported intrinsic: $name")
    end
end

"""
Compile a value reference (SSAValue, Argument, literal, etc.) to a JS expression string.
"""
function compile_value(ctx::JSCompilationContext, val)
    if val isa Core.SSAValue
        id = val.id
        if haskey(ctx.js_locals, id)
            return ctx.js_locals[id]
        end
        # Try to inline the value
        stmt = ctx.code_info.code[id]
        if stmt isa Core.PiNode
            # PiNode is a type narrowing no-op: pass through the value
            return compile_value(ctx, stmt.val)
        elseif stmt isa Expr && stmt.head === :call
            return compile_call(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :invoke
            return compile_invoke(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :new
            return compile_new_expr(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :boundscheck
            return "false"
        end
        # Fallback: create a local
        return get_local!(ctx, id)
    elseif val isa Core.Argument
        idx = val.n - 1
        if idx >= 1 && idx <= length(ctx.arg_names)
            return ctx.arg_names[idx]
        end
        return "arg$(idx)"
    elseif val isa GlobalRef
        # Resolve well-known globals
        if val.name === :nothing
            return "null"
        end
        return string(val.name)
    elseif val isa QuoteNode
        return compile_value(ctx, val.value)
    elseif val isa Bool
        return val ? "true" : "false"
    elseif val isa Int32 || val isa Int64 || val isa Int
        return string(val)
    elseif val isa Float64 || val isa Float32
        if isinf(val)
            return val > 0 ? "Infinity" : "-Infinity"
        elseif isnan(val)
            return "NaN"
        end
        return string(val)
    elseif val isa String
        return repr(val)
    elseif val === nothing || val isa Nothing
        return "null"
    elseif val isa Symbol
        return repr(string(val))
    elseif val isa Type
        return string(val)
    elseif val isa Function
        # Singleton closure (no captures)
        T = typeof(val)
        if T <: Function && Base.issingletontype(T)
            return compile_closure_creation(ctx, T, Any[])
        end
        return "/* unsupported function: $(typeof(val)) */ undefined"
    else
        return "/* unsupported: $(typeof(val)) */ undefined"
    end
end

"""
    compile(f, arg_types::Tuple; options...) -> JSOutput

Compile a Julia function to JavaScript.
"""
function compile(f, arg_types::Tuple;
    optimize::Bool=true,
    module_format::Symbol=:esm,
    sourcemap::Bool=false,
    dts::Bool=true,
    func_name::Union{String, Nothing}=nothing,
)
    code_info, return_type = get_typed_ir(f, arg_types; optimize=optimize)
    name = sanitize_js_name(something(func_name, string(nameof(f))))
    ctx = JSCompilationContext(code_info, arg_types, return_type, name)

    # Register struct types from function arguments (including Union members)
    for T in arg_types
        register_struct_types!(ctx, T)
    end

    js_body = compile_function(ctx)

    # Prepend struct class definitions if any
    struct_defs = join([generate_struct_class(T) for T in ctx.struct_types], "\n")
    if !isempty(struct_defs)
        js_body = struct_defs * "\n" * js_body
    end

    js = if module_format === :esm
        "export " * js_body
    elseif module_format === :cjs
        js_body * "module.exports = { $(name) };\n"
    elseif module_format === :none
        js_body
    else
        "(function() {\n" * js_body * "  return { $(name) };\n})();\n"
    end

    dts_str = ""
    if dts
        arg_dts = [js_type_string(t) for t in arg_types]
        params = join(["$(ctx.arg_names[i]): $(arg_dts[i])" for i in 1:length(arg_types)], ", ")
        ret_dts = js_type_string(return_type)
        dts_str = "export declare function $(name)($(params)): $(ret_dts);\n"
    end

    return JSOutput(js, dts_str, "", [name], sizeof(js))
end

"""
    compile_module(functions; options...) -> JSOutput

Compile multiple Julia functions into a single JS module.
"""
function compile_module(functions::Vector;
    optimize::Bool=true,
    module_format::Symbol=:esm,
    sourcemap::Bool=false,
    dts::Bool=true,
)
    buf = IOBuffer()
    dts_buf = IOBuffer()
    export_names = String[]
    all_struct_types = Set{DataType}()

    for entry in functions
        f, arg_types, name = entry
        arg_tuple = arg_types isa Tuple ? arg_types : Tuple(arg_types)
        code_info, return_type = get_typed_ir(f, arg_tuple; optimize=optimize)
        ctx = JSCompilationContext(code_info, arg_tuple, return_type, name)
        js_body = compile_function(ctx)
        union!(all_struct_types, ctx.struct_types)
        print(buf, js_body)
        print(buf, "\n")
        push!(export_names, name)

        if dts
            arg_dts = [js_type_string(t) for t in arg_types]
            params = join(["$(ctx.arg_names[i]): $(arg_dts[i])" for i in 1:length(arg_types)], ", ")
            ret_dts = js_type_string(return_type)
            print(dts_buf, "export declare function $(name)($(params)): $(ret_dts);\n")
        end
    end

    if module_format === :esm
        print(buf, "export { $(join(export_names, ", ")) };\n")
    end

    # Prepend struct class definitions
    js_body_str = String(take!(buf))
    if !isempty(all_struct_types)
        struct_defs = join([generate_struct_class(T) for T in all_struct_types], "\n")
        js_body_str = struct_defs * "\n" * js_body_str
    end
    js = js_body_str
    dts_str = String(take!(dts_buf))
    return JSOutput(js, dts_str, "", export_names, sizeof(js))
end
