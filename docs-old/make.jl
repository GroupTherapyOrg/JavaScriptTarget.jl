using Documenter
using JavaScriptTarget

# Build the playground into docs/src/assets/playground/
playground_dir = joinpath(@__DIR__, "src", "assets", "playground")
mkpath(playground_dir)
build_playground(playground_dir; verbose=false)

makedocs(;
    modules=[JavaScriptTarget],
    sitename="JavaScriptTarget.jl",
    remotes=nothing,
    warnonly=[:missing_docs, :docs_block],
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "API Reference" => "api.md",
        "Supported Functions" => "supported_functions.md",
        "Architecture" => "architecture.md",
    ],
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        assets=["assets/playground-embed.css"],
    ),
)

# Deployment handled by GitHub Actions (actions/deploy-pages)
# No deploydocs() needed — workflow uploads docs/build/ directly

# Create stub files that Documenter.jl HTML expects but deploydocs() normally creates
build_dir = joinpath(@__DIR__, "build")
write(joinpath(build_dir, "siteinfo.js"), "var defined = 'dev';")
write(joinpath(build_dir, "versions.js"), "var defined = 'dev';")
