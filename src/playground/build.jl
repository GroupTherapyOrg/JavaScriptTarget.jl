# build.jl — Assemble the browser playground bundle
# Copies JS pipeline files, generates types.bin, writes index.html.
# Exported as build_playground().

"""
    build_playground(output_dir::String; verbose=false, bundle=false) → NamedTuple

Build the browser playground into `output_dir/`.

Creates:
- `parser.js`, `lowerer.js`, `infer.js`, `codegen.js` — compilation pipeline
- `runtime.js` — browser runtime (output capture, helpers)
- `worker.js` — Web Worker orchestrating the pipeline
- `types.bin` — pre-computed inference tables
- `index.html` — playground page with CodeMirror editor

If `bundle=true`, also creates `playground-bundle.js` concatenating all JS files.

Returns a NamedTuple with build statistics.
"""
function build_playground(output_dir::String; verbose::Bool=false, bundle::Bool=false)
    mkpath(output_dir)

    playground_src = joinpath(@__DIR__)
    docs_playground = joinpath(@__DIR__, "..", "..", "docs", "playground")

    # --- Step 1: Copy JS pipeline files ---
    js_files = ["parser.js", "lowerer.js", "infer.js", "codegen.js", "runtime.js", "worker.js"]
    total_js_bytes = 0

    for f in js_files
        src = joinpath(playground_src, f)
        dst = joinpath(output_dir, f)
        if !isfile(src)
            error("Missing playground file: $src")
        end
        cp(src, dst; force=true)
        sz = filesize(dst)
        total_js_bytes += sz
        verbose && println("  Copied $f ($(round(sz/1024, digits=1)) KB)")
    end

    # --- Step 2: Generate types.bin ---
    types_path = joinpath(output_dir, "types.bin")
    verbose && println("Generating types.bin...")
    tables_info = build_inference_tables(types_path; verbose=verbose)
    types_bytes = filesize(types_path)
    verbose && println("  types.bin: $(round(types_bytes/1024, digits=1)) KB")

    # --- Step 3: Copy index.html ---
    html_src = joinpath(docs_playground, "index.html")
    html_dst = joinpath(output_dir, "index.html")
    if isfile(html_src)
        cp(html_src, html_dst; force=true)
        verbose && println("  Copied index.html")
    else
        verbose && println("  Warning: index.html not found at $html_src")
    end

    # --- Step 4: Optional bundle ---
    bundle_bytes = 0
    if bundle
        bundle_path = joinpath(output_dir, "playground-bundle.js")
        verbose && println("Creating playground-bundle.js...")
        open(bundle_path, "w") do io
            println(io, "// playground-bundle.js — JavaScriptTarget.jl playground")
            println(io, "// Auto-generated bundle. Do not edit.")
            println(io, "// Components: $(join(js_files[1:end-1], ", "))")
            println(io)
            # Bundle all pipeline files except worker.js (it loads them via importScripts)
            for f in js_files
                f == "worker.js" && continue
                src = joinpath(playground_src, f)
                println(io, "// === $f ===")
                println(io, "(function() {")
                write(io, read(src, String))
                println(io)
                println(io, "})();")
                println(io)
            end
        end
        bundle_bytes = filesize(bundle_path)
        verbose && println("  playground-bundle.js: $(round(bundle_bytes/1024, digits=1)) KB")
    end

    total_bytes = total_js_bytes + types_bytes
    verbose && println("\nPlayground built in $output_dir/")
    verbose && println("  Total: $(round(total_bytes/1024, digits=1)) KB ($(length(js_files)) JS files + types.bin)")

    return (
        output_dir = output_dir,
        js_files = js_files,
        js_bytes = total_js_bytes,
        types_bytes = types_bytes,
        total_bytes = total_bytes,
        bundle_bytes = bundle_bytes,
        tables_info = tables_info,
    )
end
