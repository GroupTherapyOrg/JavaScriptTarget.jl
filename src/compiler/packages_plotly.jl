# packages_plotly.jl — Plotly compilation mappings
#
# Maps PlotlyBase/PlotlyJS API functions to Plotly.js browser calls.
# Users write standard Julia plotting code, JST compiles it to JS.
#
# Supported:
#   scatter(x=x, y=y, mode="lines")  → {type:"scatter", x:x, y:y, mode:"lines"}
#   bar(x=x, y=y)                    → {type:"bar", x:x, y:y}
#   Layout(title="...", xaxis=...)   → {title:"...", xaxis:...}
#   plot(traces, layout; id="plot")  → Plotly.newPlot(el, traces, layout)

# ─── Trace constructors: scatter, bar, heatmap, etc. ───

function _plotly_trace_compiler(trace_type::String)
    return (ctx, kwargs, pos_args) -> begin
        pairs = Dict{String, String}()
        pairs["type"] = repr(trace_type)
        for (k, v) in kwargs
            pairs[string(k)] = v
        end
        return build_js_object(pairs)
    end
end

# ─── Layout constructor ───

function _plotly_layout_compiler(ctx, kwargs, pos_args)
    pairs = Dict{String, String}()
    for (k, v) in kwargs
        pairs[string(k)] = v
    end
    return build_js_object(pairs)
end

# ─── Plot function: creates/updates a Plotly chart ───

function _plotly_plot_compiler(ctx, kwargs, pos_args)
    # Positional: plotly(divid, traces, layout) OR plot(traces, layout)
    # Detect by checking if first arg looks like a string (divid)
    el_id = "\"therapy-plot\""
    traces_js = "[]"
    layout_js = "{}"

    if length(pos_args) >= 3
        # plotly(divid, traces, layout)
        el_id = pos_args[1]
        traces_js = pos_args[2]
        layout_js = pos_args[3]
    elseif length(pos_args) >= 2
        # plot(traces, layout) or plotly(divid, traces)
        traces_js = pos_args[1]
        layout_js = pos_args[2]
    elseif length(pos_args) >= 1
        traces_js = pos_args[1]
    end

    # Override with kwargs if present
    if haskey(kwargs, :divid)
        el_id = kwargs[:divid]
    end

    return "(function() { var _el = document.getElementById($(el_id)); if (_el && typeof Plotly !== 'undefined') { Plotly.react(_el, $(traces_js), $(layout_js), {responsive: true, displayModeBar: false}); } else if (_el) { var _s = document.createElement('script'); _s.src = 'https://cdn.plot.ly/plotly-2.35.2.min.js'; _s.onload = function() { Plotly.newPlot(_el, $(traces_js), $(layout_js), {responsive: true, displayModeBar: false}); }; document.head.appendChild(_s); } }())"
end

# ─── Registration function (called when a module that has these names is available) ───

"""
    register_plotly_compilations!(mod::Module)

Register Plotly trace/layout/plot compilation mappings for a module.
Call with the module that exports scatter, bar, Layout, plot etc.
"""
function register_plotly_compilations!(mod::Module)
    # Trace types
    for trace_type in [:scatter, :bar, :heatmap, :contour, :surface,
                       :histogram, :box, :violin, :pie, :scatter3d,
                       :scattergl, :scatterpolar, :choropleth, :mesh3d]
        if isdefined(mod, trace_type)
            register_package_compilation!(_plotly_trace_compiler(string(trace_type)), mod, trace_type)
        end
    end

    # Layout
    if isdefined(mod, :Layout)
        register_package_compilation!(_plotly_layout_compiler, mod, :Layout)
    end

    # Plot
    if isdefined(mod, :plot)
        register_package_compilation!(_plotly_plot_compiler, mod, :plot)
    end
    if isdefined(mod, :plotly)
        register_package_compilation!(_plotly_plot_compiler, mod, :plotly)
    end
end
