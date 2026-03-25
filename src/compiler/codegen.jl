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
    # Skip globals, constants, slot reads — these always inline
    for (i, stmt) in enumerate(code)
        # Skip statements that should always inline (not get a local)
        if stmt isa GlobalRef || stmt isa Core.SlotNumber
            continue
        end
        # Skip slot assignments (the slot variable IS the local)
        if stmt isa Expr && stmt.head === :(=)
            continue
        end
        # Skip broadcasted descriptors (consumed by materialize, not real values)
        if i <= length(ctx.code_info.ssavaluetypes)
            stype = ctx.code_info.ssavaluetypes[i]
            if stype isa DataType && stype <: Base.Broadcast.Broadcasted
                continue
            end
        end
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

    # Declare slot variables (used in optimize=false IR for local variables)
    if hasproperty(ctx.code_info, :slotnames) && ctx.code_info.slotnames !== nothing
        slot_declared = Set{String}()
        for i in 2:length(ctx.code_info.slotnames)  # Skip slot 1 (#self#)
            name = string(ctx.code_info.slotnames[i])
            if startswith(name, "#") || startswith(name, "@") || isempty(name)
                name = "_tmp$(i)"
            end
            # Skip argument names (already declared as parameters)
            if name in ctx.arg_names || name in slot_declared
                continue
            end
            # Only declare slots that are actually assigned in the code
            is_assigned = any(s -> s isa Expr && s.head == :(=) && s.args[1] isa Core.SlotNumber && s.args[1].id == i, ctx.code_info.code)
            if is_assigned
                push!(slot_declared, name)
                print(buf, "  let $(name);\n")
            end
        end
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
Emit phi assignments for merge phis at merge_point within a branch.
Assigns values for edges in [edge_lo, edge_hi].
Returns the number of consecutive phi nodes consumed.
"""
function emit_merge_phi_assignments!(ctx, buf, code, phi_info, merge_point, end_idx, edge_lo, edge_hi, indent)
    count = 0
    mp = merge_point
    while mp <= end_idx && code[mp] isa Core.PhiNode && haskey(phi_info, mp)
        phi = phi_info[mp]
        var_name = ctx.js_locals[mp]
        for (k, edge) in enumerate(phi.edges)
            if isassigned(phi.values, k) && edge >= edge_lo && edge <= edge_hi
                val = compile_value(ctx, phi.values[k])
                print(buf, "$(indent)$(var_name) = $(val);\n")
            end
        end
        count += 1
        mp += 1
    end
    return count
end

"""
Count consecutive phi nodes starting at idx.
"""
function count_merge_phis(code, phi_info, idx, end_idx)
    count = 0
    while idx + count <= end_idx && code[idx + count] isa Core.PhiNode && haskey(phi_info, idx + count)
        count += 1
    end
    return count
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

        # try/catch: EnterNode(catch_label) → try { ... } catch (_e) { ... }
        if stmt isa Core.EnterNode
            catch_label = stmt.catch_dest
            print(buf, "$(indent)try {\n")
            emit_structured!(ctx, buf, code, i + 1, catch_label - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
            print(buf, "$(indent)} catch (_e) {\n")
            emit_structured!(ctx, buf, code, catch_label, end_idx, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
            print(buf, "$(indent)}\n")
            i = end_idx + 1
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
                n_merge_phis = count_merge_phis(code, phi_info, merge_point, end_idx)
                inner_indent = "  " ^ (depth + 1)
                print(buf, "$(indent)if ($(cond)) {\n")
                emit_structured!(ctx, buf, code, i + 1, target - 2, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                if n_merge_phis > 0
                    emit_merge_phi_assignments!(ctx, buf, code, phi_info, merge_point, end_idx, i + 1, target - 1, inner_indent)
                end
                print(buf, "$(indent)} else {\n")
                emit_structured!(ctx, buf, code, target, merge_point - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                if n_merge_phis > 0
                    emit_merge_phi_assignments!(ctx, buf, code, phi_info, merge_point, end_idx, target, merge_point - 1, inner_indent)
                end
                print(buf, "$(indent)}\n")
                i = merge_point + n_merge_phis
            else
                # if-then: GotoIfNot(cond, target) means if cond is true, fall through (i+1..target-1)
                # Check for merge phis at target
                n_merge_phis = count_merge_phis(code, phi_info, target, end_idx)
                if n_merge_phis > 0
                    inner_indent = "  " ^ (depth + 1)
                    print(buf, "$(indent)if ($(cond)) {\n")
                    emit_structured!(ctx, buf, code, i + 1, target - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                    emit_merge_phi_assignments!(ctx, buf, code, phi_info, target, end_idx, i + 1, target - 1, inner_indent)
                    print(buf, "$(indent)} else {\n")
                    emit_merge_phi_assignments!(ctx, buf, code, phi_info, target, end_idx, i, i, inner_indent)
                    print(buf, "$(indent)}\n")
                    i = target + n_merge_phis
                else
                    print(buf, "$(indent)if ($(cond)) {\n")
                    emit_structured!(ctx, buf, code, i + 1, target - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1)
                    print(buf, "$(indent)}\n")
                    i = target
                end
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
                    # Check for merge phis at merge_point
                    n_merge_phis = count_merge_phis(code, phi_info, merge_point, end_idx)
                    inner_indent = "  " ^ (depth + 1)
                    print(buf, "$(indent)if ($(cond)) {\n")
                    emit_loop_body!(ctx, buf, code, i + 1, target - 2, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                    if n_merge_phis > 0
                        emit_merge_phi_assignments!(ctx, buf, code, phi_info, merge_point, end_idx, i + 1, target - 1, inner_indent)
                    end
                    print(buf, "$(indent)} else {\n")
                    emit_loop_body!(ctx, buf, code, target, merge_point - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                    if n_merge_phis > 0
                        emit_merge_phi_assignments!(ctx, buf, code, phi_info, merge_point, end_idx, target, merge_point - 1, inner_indent)
                    end
                    print(buf, "$(indent)}\n")
                    i = merge_point + n_merge_phis
                else
                    # if-then: true branch = i+1..target-1, continue at target
                    # Check if target has merge phis
                    n_merge_phis = count_merge_phis(code, phi_info, target, end_idx)
                    if n_merge_phis > 0
                        inner_indent = "  " ^ (depth + 1)
                        print(buf, "$(indent)if ($(cond)) {\n")
                        emit_loop_body!(ctx, buf, code, i + 1, target - 1, loop_headers, backward_edges, forward_gotos, phi_info, depth + 1, loop_header)
                        emit_merge_phi_assignments!(ctx, buf, code, phi_info, target, end_idx, i + 1, target - 1, inner_indent)
                        print(buf, "$(indent)} else {\n")
                        emit_merge_phi_assignments!(ctx, buf, code, phi_info, target, end_idx, i, i, inner_indent)
                        print(buf, "$(indent)}\n")
                        i = target + n_merge_phis
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
    elseif expr.head === :foreigncall || expr.head === :gc_preserve_begin || expr.head === :gc_preserve_end
        # Low-level operations: no-op in JS
        if haskey(ctx.js_locals, idx)
            name = ctx.js_locals[idx]
            print(buf, "$(indent)$(name) = undefined;\n")
        end
    elseif expr.head === :leave || expr.head === :pop_exception
        # Exception frame management: no-op in JS (try/catch handles this)
    elseif expr.head === :(=)
        # Slot assignment (optimize=false IR): _var = expr
        lhs = expr.args[1]
        rhs = expr.args[2]
        lhs_name = compile_value(ctx, lhs)
        # RHS may be an Expr (call, invoke, etc.) or a plain value
        rhs_val = if rhs isa Expr
            if rhs.head === :call
                compile_call(ctx, rhs)
            elseif rhs.head === :invoke
                compile_invoke(ctx, rhs)
            elseif rhs.head === :new
                compile_new_expr(ctx, rhs)
            else
                compile_value(ctx, rhs)
            end
        else
            compile_value(ctx, rhs)
        end
        print(buf, "$(indent)$(lhs_name) = $(rhs_val);\n")
    end
end

"""
Compile a :call expression (intrinsics, builtins, generic calls).
"""
# Extract keyword arguments from a NamedTuple SSA in unoptimized IR.
# The IR pattern is: Core.apply_type(NamedTuple, (:x,:y,:mode)), Core.tuple(vals...), NamedTupleType(tuple)
# Returns Dict{Symbol, String} mapping kwarg names to compiled JS expressions.
function _extract_kwargs(ctx::JSCompilationContext, kwargs_ssa)
    kwargs = Dict{Symbol, String}()

    if !(kwargs_ssa isa Core.SSAValue)
        return kwargs
    end

    # The kwargs SSA points to a NamedTuple constructor call
    nt_stmt = ctx.code_info.code[kwargs_ssa.id]

    # Handle (:=) wrapping
    if nt_stmt isa Expr && nt_stmt.head === :(=)
        nt_stmt = nt_stmt.args[2]
    end

    # Pattern: (%apply_type_result)(%tuple_of_values)
    # Where apply_type_result = Core.apply_type(NamedTuple, (:x, :y, :mode))
    if !(nt_stmt isa Expr && nt_stmt.head === :call)
        return kwargs
    end

    # Get the NamedTuple type (has field names) from the callee
    type_ssa = nt_stmt.args[1]
    values_ssa = length(nt_stmt.args) >= 2 ? nt_stmt.args[2] : nothing

    # Resolve field names from the type
    field_names = Symbol[]
    if type_ssa isa Core.SSAValue
        type_type = ctx.code_info.ssavaluetypes[type_ssa.id]
        if type_type isa Core.Const
            nt_type = type_type.val
            if nt_type isa DataType && nt_type <: NamedTuple
                field_names = collect(nt_type.parameters[1])
            elseif nt_type isa UnionAll && nt_type <: NamedTuple
                # NamedTuple{(:x,:y)} is UnionAll — field names in .body.parameters[1]
                field_names = collect(nt_type.body.parameters[1])
            end
        end
    end

    if isempty(field_names) || values_ssa === nothing
        return kwargs
    end

    # Resolve values from the tuple
    if values_ssa isa Core.SSAValue
        vals_stmt = ctx.code_info.code[values_ssa.id]
        if vals_stmt isa Expr && vals_stmt.head === :call
            vals_callee = vals_stmt.args[1]
            if vals_callee isa GlobalRef && vals_callee.name === :tuple
                vals = vals_stmt.args[2:end]
                for (i, name) in enumerate(field_names)
                    if i <= length(vals)
                        kwargs[name] = compile_value(ctx, vals[i])
                    end
                end
            end
        end
    end

    return kwargs
end

# Compile Base.materialize(broadcasted_ssa) to JS .map() chains.
# sin.(x) -> x.map(_b => Math.sin(_b)), x.*f -> x.map(_b => _b*f), etc.
function _compile_broadcast_materialize(ctx::JSCompilationContext, bc_arg)
    # Resolve the broadcasted SSA
    bc_stmt = nothing
    if bc_arg isa Core.SSAValue
        bc_stmt = ctx.code_info.code[bc_arg.id]
        # Handle slot assignment wrapping
        if bc_stmt isa Expr && bc_stmt.head === :(=)
            bc_stmt = bc_stmt.args[2]
        end
    end

    if bc_stmt === nothing || !(bc_stmt isa Expr && bc_stmt.head === :call)
        # Can't resolve — fallback
        return "$(compile_value(ctx, bc_arg)).slice()"
    end

    # Parse broadcasted(fn, args...)
    bc_callee = bc_stmt.args[1]
    if !(bc_callee isa GlobalRef && bc_callee.name === :broadcasted)
        return "$(compile_value(ctx, bc_arg)).slice()"
    end

    bc_fn_arg = bc_stmt.args[2]  # The function being broadcast (sin, *, +, etc.)
    bc_data_args = bc_stmt.args[3:end]  # The data arguments

    # Resolve the broadcast function
    fn_name = nothing
    if bc_fn_arg isa Core.SSAValue
        fn_type = ctx.code_info.ssavaluetypes[bc_fn_arg.id]
        if fn_type isa Core.Const
            fn_val = fn_type.val
            if fn_val === sin; fn_name = "Math.sin"
            elseif fn_val === cos; fn_name = "Math.cos"
            elseif fn_val === sqrt; fn_name = "Math.sqrt"
            elseif fn_val === abs; fn_name = "Math.abs"
            elseif fn_val === exp; fn_name = "Math.exp"
            elseif fn_val === log; fn_name = "Math.log"
            elseif fn_val === (+); fn_name = "+"
            elseif fn_val === (-); fn_name = "-"
            elseif fn_val === (*); fn_name = "*"
            elseif fn_val === (/); fn_name = "/"
            elseif fn_val === (^); fn_name = "**"
            else fn_name = string(nameof(fn_val))
            end
        end
    elseif bc_fn_arg isa GlobalRef
        fn_name = string(bc_fn_arg.name)
    end

    if fn_name === nothing
        return "$(compile_value(ctx, bc_arg)).slice()"
    end

    # Find which argument is the array (Vector) and which is scalar
    # For unary: broadcasted(sin, x) → x.map(_b => Math.sin(_b))
    # For binary: broadcasted(*, x, freq) → x.map(_b => _b * freq)
    if length(bc_data_args) == 1
        # Unary broadcast: fn.(arr)
        inner = bc_data_args[1]
        # Check if inner is itself a broadcasted (nested: sin.(x .* f))
        inner_is_broadcast = false
        if inner isa Core.SSAValue
            inner_stmt = ctx.code_info.code[inner.id]
            if inner_stmt isa Expr && inner_stmt.head === :(=)
                inner_stmt = inner_stmt.args[2]
            end
            if inner_stmt isa Expr && inner_stmt.head === :call
                ic = inner_stmt.args[1]
                if ic isa GlobalRef && ic.name === :broadcasted
                    inner_is_broadcast = true
                end
            end
        end

        if inner_is_broadcast
            # Nested broadcast: fn.(inner_broadcast)
            # Compile inner as a .map() first, then apply outer
            inner_js = _compile_broadcast_materialize(ctx, inner)
            if fn_name in ("Math.sin", "Math.cos", "Math.sqrt", "Math.abs", "Math.exp", "Math.log")
                return "$(inner_js).map(function(_b) { return $(fn_name)(_b); })"
            else
                return "$(inner_js).map(function(_b) { return $(fn_name)(_b); })"
            end
        else
            arr_js = compile_value(ctx, inner)
            if fn_name in ("Math.sin", "Math.cos", "Math.sqrt", "Math.abs", "Math.exp", "Math.log")
                return "$(arr_js).map(function(_b) { return $(fn_name)(_b); })"
            elseif fn_name == "-"
                return "$(arr_js).map(function(_b) { return -_b; })"
            else
                return "$(arr_js).map(function(_b) { return $(fn_name)(_b); })"
            end
        end
    elseif length(bc_data_args) == 2
        # Binary broadcast: arr .op scalar or arr .op arr
        left = bc_data_args[1]
        right = bc_data_args[2]

        # Determine which is array and which is scalar
        left_type = if left isa Core.SSAValue
            ctx.code_info.ssavaluetypes[left.id]
        elseif left isa Core.SlotNumber && left.id <= length(ctx.code_info.slottypes)
            ctx.code_info.slottypes[left.id]
        elseif left isa Core.Argument && left.n <= length(ctx.arg_types) + 1
            left.n == 1 ? nothing : ctx.arg_types[left.n - 1]
        else
            nothing
        end

        right_type = if right isa Core.SSAValue
            ctx.code_info.ssavaluetypes[right.id]
        elseif right isa Core.SlotNumber && right.id <= length(ctx.code_info.slottypes)
            ctx.code_info.slottypes[right.id]
        elseif right isa Core.Argument && right.n <= length(ctx.arg_types) + 1
            right.n == 1 ? nothing : ctx.arg_types[right.n - 1]
        else
            nothing
        end

        left_is_array = left_type isa DataType && left_type <: AbstractArray
        right_is_array = right_type isa DataType && right_type <: AbstractArray

        left_js = compile_value(ctx, left)
        right_js = compile_value(ctx, right)

        op = fn_name  # +, -, *, /, **

        if left_is_array && !right_is_array
            # arr .op scalar → arr.map(_b => _b op scalar)
            return "$(left_js).map(function(_b) { return (_b $(op) $(right_js)); })"
        elseif !left_is_array && right_is_array
            # scalar .op arr → arr.map(_b => scalar op _b)
            return "$(right_js).map(function(_b) { return ($(left_js) $(op) _b); })"
        elseif left_is_array && right_is_array
            # arr .op arr → arr.map((_b, _i) => _b op other[_i])
            return "$(left_js).map(function(_b, _i) { return (_b $(op) $(right_js)[_i]); })"
        else
            # Both scalar? Shouldn't happen with broadcasting, but handle gracefully
            return "($(left_js) $(op) $(right_js))"
        end
    end

    # Fallback
    return "$(compile_value(ctx, bc_data_args[1])).slice()"
end

function compile_call(ctx::JSCompilationContext, expr::Expr)
    args = expr.args
    callee = args[1]

    # ─── Resolve SSA callees (from unoptimized IR) ───
    # In optimize=false IR, calls like push!(x, val) appear as (%20)(%21, %22)
    # where %20 is an SSA holding Core.Const(push!). Resolve and dispatch.
    if callee isa Core.SSAValue
        callee_type = ctx.code_info.ssavaluetypes[callee.id]

        # Check callable_overrides for struct types (SignalGetter, SignalSetter, etc.)
        if !isempty(ctx.callable_overrides)
            override_type = callee_type isa DataType ? callee_type : nothing
            if override_type !== nothing && haskey(ctx.callable_overrides, override_type)
                override_fn = ctx.callable_overrides[override_type]
                receiver_js = compile_value(ctx, callee)
                call_args_ov = [compile_value(ctx, a) for a in args[2:end]]
                return override_fn(receiver_js, call_args_ov)
            end
        end

        if callee_type isa Core.Const
            resolved_fn = callee_type.val
            fn_name = string(nameof(resolved_fn))
            call_args = [compile_value(ctx, a) for a in args[2:end]]

            # Handle Core.kwcall — keyword argument function calls
            if resolved_fn === Core.kwcall && length(args) >= 3
                kwargs_ssa = args[2]
                func_ssa = args[3]
                pos_raw = args[4:end]

                func_type = nothing
                if func_ssa isa Core.SSAValue
                    func_type = ctx.code_info.ssavaluetypes[func_ssa.id]
                end

                if func_type isa Core.Const
                    fn = func_type.val
                    fn_mod = parentmodule(fn)
                    fn_sym = nameof(fn)
                    compiler_fn = lookup_package_compilation(fn_mod, fn_sym)
                    if compiler_fn !== nothing
                        kwargs = _extract_kwargs(ctx, kwargs_ssa)
                        pos_args_kw = [compile_value(ctx, a) for a in pos_raw]
                        return compiler_fn(ctx, kwargs, pos_args_kw)
                    end
                end

                # Fallback for unregistered kwcall
                func_js = compile_value(ctx, func_ssa)
                pos_compiled = [compile_value(ctx, a) for a in pos_raw]
                return "$(func_js)($(join(pos_compiled, ", ")))"
            end

            # Check package registry for positional calls
            if resolved_fn isa Function
                fn_mod = parentmodule(resolved_fn)
                fn_sym = nameof(resolved_fn)
                compiler_fn = lookup_package_compilation(fn_mod, fn_sym)
                if compiler_fn !== nothing
                    return compiler_fn(ctx, Dict{Symbol,String}(), call_args)
                end
            end

            # Array literal: [1.0, 2.0, 3.0] → Base.vect(1.0, 2.0, 3.0) → [1.0, 2.0, 3.0]
            if resolved_fn === Base.vect
                return "[$(join(call_args, ", "))]"
            end

            # Array creation: Float64[] → getindex(Float64) → []
            # Also handles array indexing: arr[i] → arr[i-1]
            if resolved_fn === Base.getindex
                # Check if first arg is a Type (array construction)
                if length(args) >= 2
                    first_arg = args[2]
                    first_type = nothing
                    if first_arg isa Core.SSAValue
                        first_type = try ctx.code_info.ssavaluetypes[first_arg.id] catch; nothing end
                    elseif first_arg isa GlobalRef
                        first_type = try Core.Const(getfield(first_arg.mod, first_arg.name)) catch; nothing end
                    end
                    if first_type isa Core.Const && first_type.val isa DataType
                        return "[]"
                    end
                end
                # Array indexing: arr[i] → arr[i-1]
                if length(call_args) == 2
                    return "$(call_args[1])[($(call_args[2])) - 1]"
                end
                return "[]"
            end

            # push!(arr, val) → arr.push(val)
            if resolved_fn === Base.push! && length(call_args) >= 2
                return "$(call_args[1]).push($(call_args[2]))"
            end

            # length(arr) → arr.length
            if resolved_fn === Base.length && length(call_args) >= 1
                return "$(call_args[1]).length"
            end

            # Math functions
            if resolved_fn === Base.sin || resolved_fn === sin
                return "Math.sin($(call_args[1]))"
            end
            if resolved_fn === Base.cos || resolved_fn === cos
                return "Math.cos($(call_args[1]))"
            end
            if resolved_fn === Base.sqrt || resolved_fn === sqrt
                return "Math.sqrt($(call_args[1]))"
            end
            if resolved_fn === Base.abs || resolved_fn === abs
                return "Math.abs($(call_args[1]))"
            end
            if resolved_fn === Base.max || resolved_fn === max
                return "Math.max($(join(call_args, ", ")))"
            end
            if resolved_fn === Base.min || resolved_fn === min
                return "Math.min($(join(call_args, ", ")))"
            end

            # println → console.log
            if resolved_fn === Base.println || resolved_fn === println
                require_runtime!(ctx, :jl_println)
                return "jl_println($(join(call_args, ", ")))"
            end

            # Type constructors: Float64(x) → +(x) (identity for numbers)
            if resolved_fn === Float64
                return "+($(call_args[1]))"
            end
            if resolved_fn === Float32
                return "Math.fround($(call_args[1]))"
            end
            if resolved_fn === Int || resolved_fn === Int64
                return "(($(call_args[1])) | 0)"
            end

            # Colon constructor: (:)(start, stop) → range not needed, handled by iterate
            if resolved_fn === Base.Colon()
                # Range creation — this is just (:)(1, n), handled by iterate below
                return "({start: $(call_args[1]), stop: $(call_args[2])})"
            end

            # iterate(range) and iterate(range, state) for for-loops
            if resolved_fn === Base.iterate
                if length(call_args) == 1
                    # iterate(range) → { value: range.start, done: range.start > range.stop }
                    r = call_args[1]
                    return "($(r).start <= $(r).stop ? [$(r).start, $(r).start] : null)"
                else
                    # iterate(range, state) → { value: state+1, done: state+1 > range.stop }
                    r = call_args[1]
                    s = call_args[2]
                    return "(($(s) + 1) <= $(r).stop ? [($(s) + 1), ($(s) + 1)] : null)"
                end
            end

            # Multiplication, addition etc (when not inlined as intrinsics)
            if resolved_fn === Base.:(*) && length(call_args) == 2
                return "($(call_args[1]) * $(call_args[2]))"
            end
            if resolved_fn === Base.:(+) && length(call_args) == 2
                return "($(call_args[1]) + $(call_args[2]))"
            end
            if resolved_fn === Base.:(-) && length(call_args) == 2
                return "($(call_args[1]) - $(call_args[2]))"
            end
            if resolved_fn === Base.:(-) && length(call_args) == 1
                return "(-($(call_args[1])))"
            end
            if resolved_fn === Base.:(/) && length(call_args) == 2
                return "($(call_args[1]) / $(call_args[2]))"
            end

            # js() escape hatch
            if fn_name == "js"
                template_str = nothing
                if length(args) >= 2 && args[2] isa String
                    template_str = args[2]
                elseif length(call_args) >= 1
                    s = call_args[1]
                    if length(s) >= 2 && s[1] == '"' && s[end] == '"'
                        template_str = replace(replace(s[2:end-1], "\\\"" => "\""), "\\\\" => "\\")
                    end
                end
                if template_str !== nothing
                    result = template_str
                    for i in 2:length(call_args)
                        result = replace(result, "\$$(i-1)" => call_args[i])
                    end
                    return result
                end
            end

            # Fallback: emit as function call
            return "$(fn_name)($(join(call_args, ", ")))"
        end
    end

    # ─── Handle Core.kwcall (keyword argument function calls) ───
    # IR: Core.kwcall(NamedTuple{(:x,:y,:mode)}(vals...), func, pos_args...)
    # Check package registry for the target function
    if callee isa typeof(Core.kwcall) || (callee isa GlobalRef && callee.name === :kwcall && callee.mod === Core)
        if length(args) >= 3
            # args[2] = NamedTuple with kwargs, args[3] = function, args[4:end] = positional
            kwargs_ssa = args[2]
            func_ssa = args[3]
            pos_raw = args[4:end]

            # Resolve the function being called
            func_type = nothing
            if func_ssa isa Core.SSAValue
                func_type = ctx.code_info.ssavaluetypes[func_ssa.id]
            elseif func_ssa isa GlobalRef
                func_type = try Core.Const(getfield(func_ssa.mod, func_ssa.name)) catch; nothing end
            end

            if func_type isa Core.Const
                fn = func_type.val
                fn_mod = parentmodule(fn)
                fn_name = nameof(fn)

                # Check package registry
                compiler_fn = lookup_package_compilation(fn_mod, fn_name)
                if compiler_fn !== nothing
                    # Extract kwargs from NamedTuple construction
                    kwargs = _extract_kwargs(ctx, kwargs_ssa)
                    pos_args = [compile_value(ctx, a) for a in pos_raw]
                    return compiler_fn(ctx, kwargs, pos_args)
                end
            end
        end
        # Fallback: compile as regular call (strip kwargs)
        if length(args) >= 3
            func_js = compile_value(ctx, args[3])
            pos_args = [compile_value(ctx, a) for a in args[4:end]]
            kwargs = _extract_kwargs(ctx, args[2])
            all_args = vcat(pos_args, ["$(k)=$(v)" for (k, v) in kwargs])
            return "$(func_js)($(join(all_args, ", ")))"
        end
    end

    # ─── Skip type-level operations (dead code in unoptimized IR) ───
    # Core.apply_type(NamedTuple, ...) and NamedTuple constructors are compile-time
    # operations used for kwcall dispatch — they're consumed by _extract_kwargs
    if callee isa GlobalRef && callee.name === :apply_type && callee.mod === Core
        return ""
    end

    # NamedTuple constructor: (%apply_type_result)(%tuple) — skip, consumed by kwcall
    if callee isa Core.SSAValue
        ct = try ctx.code_info.ssavaluetypes[callee.id] catch; nothing end
        if ct isa Core.Const && ct.val isa Type && ct.val <: NamedTuple
            return ""
        end
        # Also catch the case where callee type is the NamedTuple type itself
        if ct isa DataType && ct <: NamedTuple
            return ""
        end
    end

    # Core.tuple used for kwargs assembly — skip if result feeds into NamedTuple
    if (callee isa GlobalRef && callee.name === :tuple && callee.mod === Core) ||
       (callee isa typeof(Core.tuple))
        # Check if result type is a plain Tuple (kwargs values) — keep it if it's used elsewhere
        # but suppress the line emission (it'll be inlined by compile_value)
    end

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

    # Handle specific Core.Builtin functions that aren't covered by later checks
    # (===, isa, ifelse, getfield, setfield! etc. are handled below)
    if callee isa Core.Builtin
        raw_name = string(nameof(typeof(callee)))
        bname = startswith(raw_name, "#") ? raw_name[2:end] : raw_name
        if bname == "sizeof"
            arg_val = compile_value(ctx, args[2])
            return "$(arg_val).length"
        elseif bname == "nfields"
            arg_val = compile_value(ctx, args[2])
            return "Object.keys($(arg_val)).length"
        elseif bname == "fieldtype" || bname == "apply_type"
            return "undefined"
        elseif bname == "ifelse"
            cond = compile_value(ctx, args[2])
            t_val = compile_value(ctx, args[3])
            f_val = compile_value(ctx, args[4])
            return "($(cond) ? $(t_val) : $(f_val))"
        elseif bname == "throw"
            arg_val = compile_value(ctx, args[2])
            return "(() => { throw $(arg_val) })()"
        end
        # Other builtins (===, isa, getfield, etc.) fall through to handlers below
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

        # Base.vect — array literal [1, 2, 3]
        if bname === :vect && callee.mod === Base
            call_args_v = [compile_value(ctx, a) for a in args[2:end]]
            return "[$(join(call_args_v, ", "))]"
        end

        # Base.getindex — array creation (Type[]) or array access (arr[i])
        if bname === :getindex && callee.mod === Base
            # Check if first arg is a Type → empty array creation
            if length(args) >= 2
                first_arg = args[2]
                first_type = nothing
                if first_arg isa Core.SSAValue
                    first_type = try ctx.code_info.ssavaluetypes[first_arg.id] catch; nothing end
                elseif first_arg isa GlobalRef
                    first_type = try Core.Const(getfield(first_arg.mod, first_arg.name)) catch; nothing end
                end
                if first_type isa Core.Const && first_type.val isa DataType
                    return "[]"
                end
            end
            # Array indexing
            call_args_gr = [compile_value(ctx, a) for a in args[2:end]]
            if length(call_args_gr) == 2
                return "$(call_args_gr[1])[($(call_args_gr[2])) - 1]"
            end
        end

        # Base.materialize — execute broadcasting: sin.(x) → x.map(v => Math.sin(v))
        if bname === :materialize && callee.mod === Base
            if length(args) >= 2
                return _compile_broadcast_materialize(ctx, args[2])
            end
        end

        # Base.broadcasted — lazy broadcast descriptor (compiled when materialize is called)
        # Returns empty string as these are consumed by materialize, not standalone
        if bname === :broadcasted && callee.mod === Base
            return ""
        end

        # Base.iterate — for-loop iteration
        if bname === :iterate && callee.mod === Base
            call_args_it = [compile_value(ctx, a) for a in args[2:end]]
            if length(call_args_it) == 1
                r = call_args_it[1]
                return "($(r).start <= $(r).stop ? [$(r).start, $(r).start] : null)"
            else
                r = call_args_it[1]
                s = call_args_it[2]
                return "(($(s) + 1) <= $(r).stop ? [($(s) + 1), ($(s) + 1)] : null)"
            end
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
        elseif T isa DataType && isabstracttype(T) && !(T <: Number) && !(T <: AbstractString) && T !== Bool && T !== Nothing
            # Abstract type: DFS pre-order type ID range check
            assign_type_ids!(ctx, T)
            if haskey(ctx.abstract_ranges, T)
                lo, hi = ctx.abstract_ranges[T]
                # Register all concrete subtypes for class generation
                for cst in concrete_subtypes(T)
                    push!(ctx.struct_types, cst)
                end
                if lo == hi
                    return "$(x_val).\$type === $(lo)"
                else
                    return "$(x_val).\$type >= $(lo) && $(x_val).\$type <= $(hi)"
                end
            end
            return "false"
        elseif T isa DataType && !(T <: Number) && !(T <: AbstractString) && T !== Bool && T !== Nothing
            # Concrete struct type: use instanceof
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
        # In optimized IR: Core.Argument(1), in unoptimized IR: Core.SlotNumber(1)
        is_self = (obj isa Core.Argument && obj.n == 1) || (obj isa Core.SlotNumber && obj.id == 1)
        if is_self && field_arg isa QuoteNode && field_arg.value isa Symbol
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

        # Skip internal Vector/Memory/Ptr fields
        if field_arg isa QuoteNode
            obj_type = _get_ssa_type(ctx, obj)
            if obj_type !== nothing
                if obj_type <: Memory || (obj_type isa DataType && obj_type <: Ptr)
                    return "/* memory internal */ undefined"
                end
                if (obj_type <: AbstractArray) && field_arg.value in (:ref, :size, :mem, :length)
                    return "/* internal: $(field_arg.value) */ undefined"
                end
            end
        end

        # Dict fields: count → .size, skip internal fields
        if field_arg isa QuoteNode
            obj_type = _get_ssa_type(ctx, obj)
            if obj_type !== nothing && obj_type <: AbstractDict
                if field_arg.value === :count
                    obj_val = compile_value(ctx, obj)
                    return "$(obj_val).size"
                elseif field_arg.value in (:slots, :keys, :vals, :maxprobe, :age, :idxfloor, :ndel)
                    return "/* dict internal: $(field_arg.value) */ undefined"
                end
            end
        end

        # Integer field access on tuples: getfield(t, 1) → t[0]
        if field_arg isa Int64 || field_arg isa Int32
            obj_val = compile_value(ctx, obj)
            return "$(obj_val)[$(field_arg - 1)]"
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

    # Handle Core.memorynew — internal memory allocation, no-op in JS
    if callee isa GlobalRef && callee.mod === Core && callee.name === :memorynew
        return "undefined /* memorynew */"
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

    # Callable overrides: intercept calls on overridden struct types
    # Used by Therapy.jl to map signal getter/setter calls to JS variable ops
    if !isempty(ctx.callable_overrides)
        sig_params = mi.specTypes.parameters
        if length(sig_params) >= 1
            receiver_type = sig_params[1]
            if receiver_type isa DataType && haskey(ctx.callable_overrides, receiver_type)
                override_fn = ctx.callable_overrides[receiver_type]
                receiver_js = compile_value(ctx, expr.args[2])
                return override_fn(receiver_js, call_args)
            end
        end
    end

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

    if func_name == "throw_boundserror"
        return "(() => { throw new RangeError('BoundsError') })()"
    end

    # error(msg) → throw new Error(msg)
    if func_name == "error"
        msg_val = length(call_args) > 0 ? call_args[1] : "\"error\""
        return "(() => { throw new Error($(msg_val)) })()"
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

    # Dict operations: setindex!, getindex, delete!, get, haskey
    sig_params = mi.specTypes.parameters
    if length(sig_params) >= 2
        first_arg_type = sig_params[2]
        if first_arg_type isa DataType && first_arg_type <: AbstractDict
            if func_name == "setindex!"
                # setindex!(d, val, key) → d.set(key, val)
                d_val = compile_value(ctx, expr.args[3])
                val_val = compile_value(ctx, expr.args[4])
                key_val = compile_value(ctx, expr.args[5])
                return "$(d_val).set($(key_val), $(val_val))"
            elseif func_name == "getindex"
                # getindex(d, key) → d.get(key)
                d_val = compile_value(ctx, expr.args[3])
                key_val = compile_value(ctx, expr.args[4])
                return "$(d_val).get($(key_val))"
            elseif func_name == "delete!"
                # delete!(d, key) → d.delete(key)
                d_val = compile_value(ctx, expr.args[3])
                key_val = compile_value(ctx, expr.args[4])
                return "$(d_val).delete($(key_val))"
            elseif func_name == "get"
                # get(d, key, default) → (d.has(key) ? d.get(key) : default)
                d_val = compile_value(ctx, expr.args[3])
                key_val = compile_value(ctx, expr.args[4])
                def_val = compile_value(ctx, expr.args[5])
                return "($(d_val).has($(key_val)) ? $(d_val).get($(key_val)) : $(def_val))"
            end
        end

        # Set operations
        if first_arg_type isa DataType && first_arg_type <: AbstractSet
            if func_name == "push!"
                s_val = compile_value(ctx, expr.args[3])
                val_val = compile_value(ctx, expr.args[4])
                return "$(s_val).add($(val_val))"
            elseif func_name == "delete!"
                s_val = compile_value(ctx, expr.args[3])
                val_val = compile_value(ctx, expr.args[4])
                return "$(s_val).delete($(val_val))"
            elseif func_name == "in" || func_name == "∈"
                val_val = compile_value(ctx, expr.args[3])
                s_val = compile_value(ctx, expr.args[4])
                return "$(s_val).has($(val_val))"
            end
        end

        # Vector operations
        if first_arg_type isa DataType && first_arg_type <: AbstractArray
            if func_name == "push!" || func_name == "_push!"
                arr_val = compile_value(ctx, expr.args[3])
                val_val = compile_value(ctx, expr.args[4])
                return "$(arr_val).push($(val_val))"
            elseif func_name == "pop!"
                arr_val = compile_value(ctx, expr.args[3])
                return "$(arr_val).pop()"
            elseif func_name == "append!" || func_name == "_append!"
                arr_val = compile_value(ctx, expr.args[3])
                other_val = compile_value(ctx, expr.args[4])
                return "$(arr_val).push(...$(other_val))"
            elseif func_name == "empty!"
                arr_val = compile_value(ctx, expr.args[3])
                return "($(arr_val).length = 0, $(arr_val))"
            end
        end

        # String operations (first arg is String)
        if first_arg_type === String || (first_arg_type isa DataType && first_arg_type <: AbstractString)
            if func_name == "occursin" || func_name == "contains"
                # occursin(needle, haystack) — note arg order: pattern first, string second
                needle = compile_value(ctx, expr.args[3])
                haystack = compile_value(ctx, expr.args[4])
                return "$(haystack).includes($(needle))"
            elseif func_name == "startswith"
                s_val = compile_value(ctx, expr.args[3])
                prefix = compile_value(ctx, expr.args[4])
                return "$(s_val).startsWith($(prefix))"
            elseif func_name == "endswith"
                s_val = compile_value(ctx, expr.args[3])
                suffix = compile_value(ctx, expr.args[4])
                return "$(s_val).endsWith($(suffix))"
            elseif func_name == "uppercase"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).toUpperCase()"
            elseif func_name == "lowercase"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).toLowerCase()"
            elseif func_name == "strip"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).trim()"
            elseif func_name == "lstrip"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).trimStart()"
            elseif func_name == "rstrip"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).trimEnd()"
            elseif func_name == "split"
                s_val = compile_value(ctx, expr.args[3])
                if length(expr.args) >= 4
                    delim = compile_value(ctx, expr.args[4])
                    return "$(s_val).split($(delim))"
                else
                    return "$(s_val).split(\"\")"
                end
            elseif func_name == "replace"
                s_val = compile_value(ctx, expr.args[3])
                # replace(s, pair) — pair is a Pair, but in IR it may be separate args
                if length(expr.args) >= 5
                    pattern = compile_value(ctx, expr.args[4])
                    replacement = compile_value(ctx, expr.args[5])
                    return "$(s_val).replaceAll($(pattern), $(replacement))"
                end
            elseif func_name == "join"
                # join(arr, sep) — arr is first arg for join
                arr_val = compile_value(ctx, expr.args[3])
                if length(expr.args) >= 4
                    sep = compile_value(ctx, expr.args[4])
                    return "$(arr_val).join($(sep))"
                else
                    return "$(arr_val).join(\"\")"
                end
            elseif func_name == "chop"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).slice(0, -1)"
            elseif func_name == "chomp"
                s_val = compile_value(ctx, expr.args[3])
                return "$(s_val).replace(/\\n\$/, \"\")"
            elseif func_name == "reverse"
                s_val = compile_value(ctx, expr.args[3])
                return "[...$(s_val)].reverse().join(\"\")"
            end
        end
    end

    # IO: println → console.log, print → jl_print
    if func_name == "println"
        require_runtime!(ctx, :jl_println)
        return "jl_println($(join(call_args, ", ")))"
    end
    if func_name == "print"
        require_runtime!(ctx, :jl_print)
        return "jl_print($(join(call_args, ", ")))"
    end

    # JS escape hatch: js("raw code") or js("template with \$1", val) → raw JavaScript
    # Used by Therapy.jl to call browser APIs (document, localStorage, etc.)
    # Supports value passing: js("Plotly.react(el, \$1)", data()) substitutes $1 with compiled JS
    if func_name == "js"
        # Extract template string from IR (most reliable) or compiled args
        template_str = nothing
        if length(expr.args) >= 3 && expr.args[3] isa String
            template_str = expr.args[3]
        elseif length(call_args) >= 1
            s = call_args[1]
            if length(s) >= 2 && s[1] == '"' && s[end] == '"'
                template_str = replace(replace(s[2:end-1], "\\\"" => "\""), "\\\\" => "\\")
            end
        end

        if template_str === nothing
            return "/* js() called with no string template */"
        end

        # Substitute $1, $2, etc. with compiled JS expressions for additional args
        result = template_str
        for i in 2:length(call_args)
            result = replace(result, "\$$(i-1)" => call_args[i])
        end

        return result
    end

    # Math: div, fld, mod, cld, rem
    if func_name == "div" && length(call_args) >= 2
        require_runtime!(ctx, :jl_div)
        return "jl_div($(call_args[1]), $(call_args[2]))"
    end
    if func_name == "fld" && length(call_args) >= 2
        require_runtime!(ctx, :jl_fld)
        return "jl_fld($(call_args[1]), $(call_args[2]))"
    end
    if func_name == "mod" && length(call_args) >= 2
        require_runtime!(ctx, :jl_mod)
        return "jl_mod($(call_args[1]), $(call_args[2]))"
    end
    if func_name == "cld" && length(call_args) >= 2
        require_runtime!(ctx, :jl_cld)
        return "jl_cld($(call_args[1]), $(call_args[2]))"
    end
    if func_name == "rem" && length(call_args) >= 2
        return "($(call_args[1]) % $(call_args[2])) | 0"
    end

    # isempty(collection) → collection.length === 0
    if func_name == "isempty" && length(call_args) >= 1
        return "$(call_args[1]).length === 0"
    end

    # convert(T, x) → just x (type conversions are compile-time in JS)
    if func_name == "convert" && length(call_args) >= 2
        return call_args[2]
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
    elseif T isa DataType && T <: AbstractDict
        return "new Map()"
    elseif T isa DataType && T <: AbstractSet
        return "new Set()"
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
    closure_ctx.callable_overrides = ctx.callable_overrides

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
    elseif T isa DataType && !isabstracttype(T) && !(T <: Number) && !(T <: AbstractString) && T !== Bool && T !== Nothing && !(T <: Function) && !(T <: AbstractArray) && !(T <: AbstractDict) && !(T <: AbstractSet) && !(T <: Tuple) && !(T <: IO) && T.name.module !== Base && T.name.module !== Core
        push!(ctx.struct_types, T)
    end
end

"""
Find all concrete (leaf) subtypes of a type via recursive DFS.
"""
function concrete_subtypes(T::Type)
    if Base.isconcretetype(T)
        return DataType[T]
    end
    result = DataType[]
    for S in subtypes(T)
        append!(result, concrete_subtypes(S))
    end
    return result
end

"""
Assign DFS pre-order type IDs to all concrete subtypes of an abstract type.
Updates ctx.type_ids and ctx.abstract_ranges.
"""
function assign_type_ids!(ctx::JSCompilationContext, abstract_type::Type)
    haskey(ctx.abstract_ranges, abstract_type) && return

    function dfs!(T::Type)
        if Base.isconcretetype(T)
            if !haskey(ctx.type_ids, T)
                ctx.type_id_counter += 1
                ctx.type_ids[T] = ctx.type_id_counter
            end
            id = ctx.type_ids[T]
            return (id, id)
        else
            lo = typemax(Int)
            hi = 0
            for S in subtypes(T)
                (s_lo, s_hi) = dfs!(S)
                lo = min(lo, s_lo)
                hi = max(hi, s_hi)
            end
            if lo <= hi
                ctx.abstract_ranges[T] = (lo, hi)
            end
            return (lo, hi)
        end
    end

    dfs!(abstract_type)
end

"""
Generate ES6 class definition for a Julia struct type.
"""
function generate_struct_class(T::DataType; type_id::Union{Int,Nothing}=nothing)
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
    if type_id !== nothing
        print(buf, "$(name).prototype.\$type = $(type_id);\n")
    end
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
        # Bool: use logical NOT; integers: use bitwise NOT
        arg_type = _get_ssa_type(ctx, args[1])
        is_bool = arg_type === Bool || (arg_type isa Core.Const && arg_type.val isa Bool)
        if is_bool
            return "!($(compiled_args[1]))"
        end
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
    elseif name === :rint_llvm
        return "Math.round($(compiled_args[1]))"
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
    elseif name === :checked_sdiv_int
        return "($(compiled_args[1]) / $(compiled_args[2]) | 0)"
    elseif name === :checked_srem_int
        return "($(compiled_args[1]) % $(compiled_args[2]) | 0)"
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
        elseif stmt isa Core.SlotNumber
            # Slot read in unoptimized IR — resolve to slot variable name
            return compile_value(ctx, stmt)
        elseif stmt isa GlobalRef
            # Global reference — resolve directly
            return compile_value(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :call
            return compile_call(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :invoke
            return compile_invoke(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :new
            return compile_new_expr(ctx, stmt)
        elseif stmt isa Expr && stmt.head === :boundscheck
            return "false"
        elseif stmt isa Expr && stmt.head === :(=)
            # Slot assignment — the SSA value is the RHS result
            rhs = stmt.args[2]
            if rhs isa Expr
                if rhs.head === :call
                    return compile_call(ctx, rhs)
                elseif rhs.head === :invoke
                    return compile_invoke(ctx, rhs)
                end
            end
            return compile_value(ctx, rhs)
        end
        # Fallback: create a local
        return get_local!(ctx, id)
    elseif val isa Core.SlotNumber
        # Local variable (used in optimize=false IR)
        slot_id = val.id
        if slot_id == 1
            # Slot 1 is #self# (the function)
            return "null"
        end
        # Use slot name from CodeInfo if available
        slot_names = ctx.code_info.slotnames
        if slot_id <= length(slot_names)
            name = string(slot_names[slot_id])
            # Clean up generated names (remove # prefixes, @ etc.)
            if startswith(name, "#") || startswith(name, "@") || isempty(name)
                return "_tmp$(slot_id)"
            end
            return name
        end
        return "_tmp$(slot_id)"
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
    elseif val isa Core.Builtin || val isa Core.IntrinsicFunction
        # Core builtins/intrinsics as values — emit their name
        return string(nameof(typeof(val)))
    elseif val isa Function
        # Singleton closure (no captures)
        T = typeof(val)
        if T <: Function && Base.issingletontype(T)
            # Skip Core builtins that masquerade as singleton functions
            if T.name.module === Core
                return "/* core function */ undefined"
            end
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
    captured_vars::Dict{Symbol, String}=Dict{Symbol, String}(),
    callable_overrides::Dict{DataType, Function}=Dict{DataType, Function}(),
)
    code_info, return_type = get_typed_ir(f, arg_types; optimize=optimize)
    name = sanitize_js_name(something(func_name, string(nameof(f))))
    ctx = JSCompilationContext(code_info, arg_types, return_type, name)

    # Apply caller-provided captured_vars and callable_overrides
    # (used for compiling closures directly, e.g., island event handlers)
    if !isempty(captured_vars)
        merge!(ctx.captured_vars, captured_vars)
    end
    if !isempty(callable_overrides)
        merge!(ctx.callable_overrides, callable_overrides)
    end

    # Register struct types from function arguments (including Union members)
    for T in arg_types
        register_struct_types!(ctx, T)
        # For abstract type arguments, register all concrete subtypes and assign type IDs
        if T isa DataType && isabstracttype(T)
            for S in concrete_subtypes(T)
                register_struct_types!(ctx, S)
            end
            assign_type_ids!(ctx, T)
        end
    end

    js_body = compile_function(ctx)

    # Prepend struct class definitions if any
    struct_defs = join([generate_struct_class(T; type_id=get(ctx.type_ids, T, nothing)) for T in ctx.struct_types], "\n")
    if !isempty(struct_defs)
        js_body = struct_defs * "\n" * js_body
    end

    # Prepend runtime helpers if any were required
    runtime_code = get_runtime_code(ctx.required_runtime)
    if !isempty(runtime_code)
        js_body = runtime_code * "\n" * js_body
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
        dts_buf = IOBuffer()
        # Emit struct type declarations (branded types)
        for T in ctx.struct_types
            print(dts_buf, generate_struct_dts(T))
            print(dts_buf, "\n")
        end
        # Emit function declaration
        arg_dts = [js_type_string(t) for t in arg_types]
        params = join(["$(ctx.arg_names[i]): $(arg_dts[i])" for i in 1:length(arg_types)], ", ")
        ret_dts = js_type_string(return_type)
        print(dts_buf, "export declare function $(name)($(params)): $(ret_dts);\n")
        dts_str = String(take!(dts_buf))
    end

    # Generate source map if requested
    sm_str = ""
    if sourcemap
        source_file, source_line = get_source_location(f, arg_types)
        if source_file != "unknown"
            sm_str = generate_sourcemap(source_file, source_line, js, name)
        end
    end

    return JSOutput(js, dts_str, sm_str, [name], sizeof(js))
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
    all_type_ids = Dict{DataType, Int}()
    all_required_runtime = Set{Symbol}()

    all_fn_dts = IOBuffer()  # Function declarations only
    for entry in functions
        f, arg_types, name = entry
        arg_tuple = arg_types isa Tuple ? arg_types : Tuple(arg_types)
        code_info, return_type = get_typed_ir(f, arg_tuple; optimize=optimize)
        ctx = JSCompilationContext(code_info, arg_tuple, return_type, name)

        # Register struct types from arguments (same as compile())
        for T in arg_tuple
            register_struct_types!(ctx, T)
            if T isa DataType && isabstracttype(T)
                for S in concrete_subtypes(T)
                    register_struct_types!(ctx, S)
                end
                assign_type_ids!(ctx, T)
            end
        end

        js_body = compile_function(ctx)
        union!(all_struct_types, ctx.struct_types)
        merge!(all_type_ids, ctx.type_ids)
        union!(all_required_runtime, ctx.required_runtime)
        print(buf, js_body)
        print(buf, "\n")
        push!(export_names, name)

        if dts
            arg_dts = [js_type_string(t) for t in arg_types]
            params = join(["$(ctx.arg_names[i]): $(arg_dts[i])" for i in 1:length(arg_types)], ", ")
            ret_dts = js_type_string(return_type)
            print(all_fn_dts, "export declare function $(name)($(params)): $(ret_dts);\n")
        end
    end

    if module_format === :esm
        print(buf, "export { $(join(export_names, ", ")) };\n")
    end

    # Prepend struct class definitions
    js_body_str = String(take!(buf))
    if !isempty(all_struct_types)
        struct_defs = join([generate_struct_class(T; type_id=get(all_type_ids, T, nothing)) for T in all_struct_types], "\n")
        js_body_str = struct_defs * "\n" * js_body_str
    end

    # Prepend runtime helpers
    runtime_code = get_runtime_code(all_required_runtime)
    if !isempty(runtime_code)
        js_body_str = runtime_code * "\n" * js_body_str
    end

    js = js_body_str

    # Build .d.ts: struct declarations first, then function declarations
    if dts
        for T in all_struct_types
            print(dts_buf, generate_struct_dts(T))
            print(dts_buf, "\n")
        end
        print(dts_buf, String(take!(all_fn_dts)))
    end
    dts_str = String(take!(dts_buf))
    return JSOutput(js, dts_str, "", export_names, sizeof(js))
end
