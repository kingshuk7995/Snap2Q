#!/usr/bin/env julia
"""Build a single self-contained offline HTML file with all questions & WebP images embedded (pure Julia)."""

if !isdefined(@__MODULE__, :PharmaQBank)
    include(joinpath(@__DIR__, "PharmaQBank.jl"))
end
using .PharmaQBank

using Base64
using ColorTypes: RGB
using FixedPointNumbers: N0f8
using JSON3
using WebP

"""Crisp bilinear downscaler for RGB{N0f8} screenshot matrices (zero extra dependencies)."""
function resize_rgb(img::Matrix{RGB{N0f8}}, new_w::Int)::Matrix{RGB{N0f8}}
    h, w = size(img)
    new_w >= w && return img
    new_h = max(1, round(Int, h * (new_w / w)))
    out = Matrix{RGB{N0f8}}(undef, new_h, new_w)
    scale_y = Float32(h) / Float32(new_h)
    scale_x = Float32(w) / Float32(new_w)

    @inbounds for j in 1:new_w
        src_x = (Float32(j) - 0.5f0) * scale_x + 0.5f0
        x0 = clamp(floor(Int, src_x), 1, w)
        x1 = clamp(x0 + 1, 1, w)
        fx = clamp(src_x - Float32(x0), 0.0f0, 1.0f0)
        for i in 1:new_h
            src_y = (Float32(i) - 0.5f0) * scale_y + 0.5f0
            y0 = clamp(floor(Int, src_y), 1, h)
            y1 = clamp(y0 + 1, 1, h)
            fy = clamp(src_y - Float32(y0), 0.0f0, 1.0f0)

            c00 = img[y0, x0]; c01 = img[y0, x1]
            c10 = img[y1, x0]; c11 = img[y1, x1]

            w00 = (1.0f0 - fy) * (1.0f0 - fx)
            w01 = (1.0f0 - fy) * fx
            w10 = fy * (1.0f0 - fx)
            w11 = fy * fx

            r = w00 * Float32(c00.r) + w01 * Float32(c01.r) + w10 * Float32(c10.r) + w11 * Float32(c11.r)
            g = w00 * Float32(c00.g) + w01 * Float32(c01.g) + w10 * Float32(c10.g) + w11 * Float32(c11.g)
            b = w00 * Float32(c00.b) + w01 * Float32(c01.b) + w10 * Float32(c10.b) + w11 * Float32(c11.b)
            out[i, j] = RGB{N0f8}(clamp(r, 0.0f0, 1.0f0), clamp(g, 0.0f0, 1.0f0), clamp(b, 0.0f0, 1.0f0))
        end
    end
    return out
end

function encode_image_b64(img_path::String, max_width::Int, quality::Float32)::String
    raw = read(img_path)
    img = WebP.decode(RGB{N0f8}, raw)
    if max_width > 0 && size(img, 2) > max_width
        img = resize_rgb(img, max_width)
    end
    img_t = permutedims(img, (2, 1))
    webp_bytes = GC.@preserve img_t WebP.encode(img_t; lossy=true, quality=quality, transpose=true)
    return base64encode(webp_bytes)
end

function build_single_html(
    data_dir::AbstractString = DEFAULT_DATA_DIR,
    web_dir::AbstractString = DEFAULT_WEB_DIR,
    out_file::AbstractString = joinpath(DEFAULT_DIST_DIR, "pharma-qbank-standalone.html");
    max_width::Int = 680,
    quality::Float32 = 65.0f0,
)
    t0 = time()
    q_json_path = joinpath(data_dir, "questions.json")
    isfile(q_json_path) || error("Missing $q_json_path. Extract PDF first.")

    qdata = JSON3.read(read(q_json_path, String))
    rel_paths = String[]
    seen = Set{String}()
    for q in qdata.questions
        for key in (:q_img, :e_img)
            rel = String(q[key])
            if !(rel in seen)
                push!(seen, rel)
                push!(rel_paths, rel)
            end
        end
    end

    println("Embedding $(length(rel_paths)) images (max_width=$(max_width)px, quality=$(Int(quality)), threads=$(Threads.nthreads())) into $out_file ...")

    b64_vals = Vector{String}(undef, length(rel_paths))
    done_cnt = Threads.Atomic{Int}(0)
    Threads.@threads for idx in eachindex(rel_paths)
        rel = rel_paths[idx]
        b64_vals[idx] = encode_image_b64(joinpath(data_dir, rel), max_width, quality)
        c = Threads.atomic_add!(done_cnt, 1) + 1
        if c % 500 == 0 || c == length(rel_paths)
            println("  Encoded $c/$(length(rel_paths)) images ($(round(time() - t0; digits=1))s)")
        end
    end

    b64_map = Dict{String, String}(rel_paths[i] => b64_vals[i] for i in eachindex(rel_paths))

    html = read(joinpath(web_dir, "index.html"), String)
    css = read(joinpath(web_dir, "styles.css"), String)
    js = read(joinpath(web_dir, "app.js"), String)

    inline_style = "<style>\n$(css)\n</style>"
    embedded_data = string(
        "<script>\n",
        "window.QBANK_DATA = ", JSON3.write(qdata), ";\n",
        "window.QBANK_IMAGES = ", JSON3.write(b64_map), ";\n",
        "</script>\n",
        "<script>\n", js, "\n</script>"
    )

    html = replace(html, "<link rel=\"stylesheet\" href=\"/styles.css\" />" => inline_style)
    html = replace(html, "<script src=\"/app.js\"></script>" => embedded_data)

    mkpath(dirname(out_file))
    write(out_file, html)
    size_mb = round(filesize(out_file) / (1024 * 1024); digits=2)
    println("Built single-file app: $out_file ($size_mb MB) in $(round(time() - t0; digits=1))s")
    return out_file
end

function _parse_build_args(args::Vector{String})
    data_dir = DEFAULT_DATA_DIR
    out_file = joinpath(DEFAULT_DIST_DIR, "pharma-qbank-standalone.html")
    max_width = 680
    quality = 65.0f0
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--data=")
            data_dir = String(a[8:end]); i += 1
        elseif a == "--data" && i < length(args)
            data_dir = args[i + 1]; i += 2
        elseif startswith(a, "--out=")
            out_file = String(a[7:end]); i += 1
        elseif a == "--out" && i < length(args)
            out_file = args[i + 1]; i += 2
        elseif startswith(a, "--max-width=")
            max_width = parse(Int, a[13:end]); i += 1
        elseif a == "--max-width" && i < length(args)
            max_width = parse(Int, args[i + 1]); i += 2
        elseif startswith(a, "--quality=")
            quality = parse(Float32, a[11:end]); i += 1
        elseif a == "--quality" && i < length(args)
            quality = parse(Float32, args[i + 1]); i += 2
        else
            i += 1
        end
    end
    return data_dir, out_file, max_width, quality
end

if abspath(PROGRAM_FILE) == @__FILE__
    data_dir, out_file, max_width, quality = _parse_build_args(ARGS)
    build_single_html(data_dir, DEFAULT_WEB_DIR, out_file; max_width=max_width, quality=quality)
end
