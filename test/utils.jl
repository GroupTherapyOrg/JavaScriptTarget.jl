using JavaScriptTarget

"""
    run_js(js_code::String) -> String

Execute JavaScript code in Node.js and return stdout.
"""
function run_js(js_code::String)
    temp = tempname() * ".js"
    try
        write(temp, js_code)
        output = read(`node $temp`, String)
        return strip(output)
    finally
        isfile(temp) && rm(temp)
    end
end

"""
    compile_and_run(f, arg_types::Tuple, args...; kwargs...) -> String

Compile a Julia function to JS, call it with the given args, and return the
result as a string (via console.log in Node.js).
"""
function compile_and_run(f, arg_types::Tuple, args...; func_name=nothing, kwargs...)
    result = compile(f, arg_types; module_format=:none, func_name=func_name, kwargs...)

    # Build the call expression
    js_args = join([js_literal(a) for a in args], ", ")
    name = something(func_name, string(nameof(f)))

    # Wrap: define function + call + print result
    test_code = """
$(result.js)
const __result = $(name)($(js_args));
if (typeof __result === 'boolean') {
  process.stdout.write(__result ? 'true' : 'false');
} else if (__result === null || __result === undefined) {
  process.stdout.write(String(__result));
} else {
  process.stdout.write(String(__result));
}
"""
    return run_js(test_code)
end

"""
    compile_module_and_run(functions, call_name, args...) -> String

Compile multiple functions into a module, call one by name, return result.
"""
function compile_module_and_run(functions, call_name::String, args...)
    result = compile_module(functions; module_format=:none)
    js_args = join([js_literal(a) for a in args], ", ")

    test_code = """
$(result.js)
const __result = $(call_name)($(js_args));
if (typeof __result === 'boolean') {
  process.stdout.write(__result ? 'true' : 'false');
} else if (__result === null || __result === undefined) {
  process.stdout.write(String(__result));
} else {
  process.stdout.write(String(__result));
}
"""
    return run_js(test_code)
end

"""
Convert a Julia value to a JS literal string for use in test calls.
"""
function js_literal(val)
    if val isa Bool
        return val ? "true" : "false"
    elseif val isa Integer
        return string(val)
    elseif val isa AbstractFloat
        if isinf(val)
            return val > 0 ? "Infinity" : "-Infinity"
        elseif isnan(val)
            return "NaN"
        end
        return string(val)
    elseif val isa String
        return repr(val)  # JSON-compatible string escaping
    elseif val === nothing
        return "null"
    else
        return string(val)
    end
end
