#!/usr/bin/env julia
# JavaScriptTarget.jl Documentation Site
#
# Built with Therapy.jl — same framework, different accent color.
#
# Usage (from JavaScriptTarget.jl root directory):
#   julia --project=docs docs/app.jl dev    # Development server
#   julia --project=docs docs/app.jl build  # Static site generation

if !haskey(ENV, "JULIA_PROJECT")
    using Pkg
    Pkg.activate(@__DIR__)
end

using Therapy

cd(@__DIR__)

app = App(
    routes_dir = "src/routes",
    components_dir = "src/components",
    title = "JavaScriptTarget.jl",
    output_dir = "dist",
    base_path = "/JavaScriptTarget.jl",
    layout = :Layout
)

Therapy.run(app)
