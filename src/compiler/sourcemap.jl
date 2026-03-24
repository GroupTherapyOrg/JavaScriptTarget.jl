# Source Map V3 generation for JavaScriptTarget.jl
# Maps JS output lines back to Julia source file/line.
# Uses VLQ Base64 encoding per the V3 source map specification.

const VLQ_BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

"""
    vlq_encode(value::Int) -> String

Encode an integer as a VLQ Base64 string (per Source Map V3 spec).
Positive values: n → n << 1
Negative values: n → (-n << 1) | 1
Then split into 5-bit groups (LSB first), set continuation bit on all but last.
"""
function vlq_encode(value::Int)
    # Convert signed to unsigned VLQ
    vlq = value >= 0 ? (value << 1) : ((-value) << 1 | 1)

    buf = IOBuffer()
    while true
        digit = vlq & 0x1f  # 5 bits
        vlq >>= 5
        if vlq > 0
            digit |= 0x20  # Continuation bit
        end
        write(buf, UInt8(VLQ_BASE64_CHARS[digit + 1]))
        vlq == 0 && break
    end
    return String(take!(buf))
end

"""
    generate_sourcemap(source_file, source_line, js_code, func_name) -> String

Generate a V3 source map JSON string that maps JS output lines back to Julia source.

Currently maps all JS lines to the function's starting line. Future enhancement:
per-statement line mapping using CodeInfo.debuginfo.codelocs.
"""
function generate_sourcemap(source_file::String, source_line::Int, js_code::String, func_name::String)
    js_lines = count('\n', js_code)
    if js_lines == 0 && !isempty(js_code)
        js_lines = 1
    end

    # Build mappings: each JS line maps to (col=0, source=0, line=offset, col=0)
    # V3 uses 0-indexed lines; Julia uses 1-indexed
    mappings_buf = IOBuffer()
    prev_gen_col = 0
    prev_source_idx = 0
    prev_source_line = 0
    prev_source_col = 0

    target_line = source_line - 1  # 0-indexed

    for i in 1:js_lines
        if i > 1
            print(mappings_buf, ";")
        end

        # Delta-encoded segment: (gen_col, source_idx, source_line, source_col)
        gen_col = 0
        gen_col_delta = gen_col - prev_gen_col
        source_idx_delta = 0 - prev_source_idx
        source_line_delta = target_line - prev_source_line
        source_col_delta = 0 - prev_source_col

        segment = vlq_encode(gen_col_delta) *
                  vlq_encode(source_idx_delta) *
                  vlq_encode(source_line_delta) *
                  vlq_encode(source_col_delta)
        print(mappings_buf, segment)

        # Update previous values
        prev_gen_col = gen_col
        prev_source_idx = 0
        prev_source_line = target_line
        prev_source_col = 0
    end

    mappings = String(take!(mappings_buf))

    # Escape the source file path for JSON
    escaped_file = replace(source_file, "\\" => "\\\\")
    escaped_file = replace(escaped_file, "\"" => "\\\"")

    return """{
  "version": 3,
  "file": "$(func_name).js",
  "sources": ["$(escaped_file)"],
  "sourcesContent": [null],
  "names": [],
  "mappings": "$(mappings)"
}"""
end

"""
Get the source file and line for a Julia function's method.
Returns (file::String, line::Int) or ("unknown", 0) if not available.
"""
function get_source_location(f, arg_types::Tuple)
    try
        ms = methods(f, arg_types)
        if !isempty(ms)
            m = first(ms)
            file = string(m.file)
            line = Int(m.line)
            if file != "none" && file != ""
                return (file, line)
            end
        end
    catch
    end
    return ("unknown", 0)
end
