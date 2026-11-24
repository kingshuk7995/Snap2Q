#!/usr/bin/env julia
"""Extract questions, masked options, answers, and explanations from a QBank screenshot PDF in pure Julia."""

if !isdefined(@__MODULE__, :PharmaQBank)
    include(joinpath(@__DIR__, "PharmaQBank.jl"))
end
using .PharmaQBank

using ColorTypes: RGB
using FFTW
using FixedPointNumbers: N0f8
using JpegTurbo
using JSON3
using WebP

const BG_VAL = UInt8(247)
const BG_F32 = 247.0f0
const NEUTRAL_INK_GRAY = 126.0f0

struct Templates
    bookmark::Matrix{Float32}
    bm_x0::Int
    opt_letters::Dict{String, Matrix{Float32}}
    opt_x0::Int
    pct_close::Matrix{Float32}
    open_bracket::Matrix{Float32}
end

"""
Scan the PDF byte stream and return (offset, length) of every embedded /DCTDecode page image
in exact PDF page order.
"""
function index_pdf_jpegs(pdf_path::AbstractString)::Vector{Tuple{Int, Int}}
    data = read(pdf_path)
    n = length(data)
    ranges = Tuple{Int, Int}[]
    needle = Vector{UInt8}("/Subtype /Image")
    dict_open = Vector{UInt8}("<<")
    dict_close = Vector{UInt8}(">>")
    stream_kw = Vector{UInt8}("stream")
    pos = 1
    while true
        rng = findnext(needle, data, pos)
        rng === nothing && break
        d0 = findprev(dict_open, data, first(rng))
        d1 = findnext(dict_close, data, last(rng))
        if d0 !== nothing && d1 !== nothing
            hdr_str = String(data[first(d0):last(d1)])
            if occursin("/DCTDecode", hdr_str)
                m_len = match(r"/Length\s+(\d+)", hdr_str)
                m_stream = findnext(stream_kw, data, last(d1))
                if m_len !== nothing && m_stream !== nothing
                    stream_len = parse(Int, m_len.captures[1])
                    s_idx = last(m_stream) + 1
                    if s_idx <= n && data[s_idx] == UInt8('\r')
                        s_idx += 1
                    end
                    if s_idx <= n && data[s_idx] == UInt8('\n')
                        s_idx += 1
                    end
                    e_idx = min(n, s_idx + stream_len - 1)
                    # Trim any trailing whitespace after JPEG EOI marker (0xFF 0xD9)
                    while e_idx > s_idx + 1 && (data[e_idx] == UInt8('\n') || data[e_idx] == UInt8('\r'))
                        e_idx -= 1
                    end
                    push!(ranges, (s_idx, e_idx - s_idx + 1))
                    pos = e_idx + 1
                    continue
                end
            end
        end
        pos = last(rng) + 1
    end
    return ranges
end

function _unpack_rgb(img::AbstractMatrix{RGB{N0f8}})
    h, w = size(img)
    R = Matrix{UInt8}(undef, h, w)
    G = Matrix{UInt8}(undef, h, w)
    B = Matrix{UInt8}(undef, h, w)
    @inbounds for j in 1:w, i in 1:h
        c = img[i, j]
        R[i, j] = reinterpret(UInt8, c.r)
        G[i, j] = reinterpret(UInt8, c.g)
        B[i, j] = reinterpret(UInt8, c.b)
    end
    return R, G, B
end

function load_page_rgb_channels(pdf_path::AbstractString, offset::Int, len::Int)
    buf = Vector{UInt8}(undef, len)
    open(pdf_path, "r") do io
        seek(io, offset - 1)
        readbytes!(io, buf, len)
    end
    img = JpegTurbo.jpeg_decode(RGB{N0f8}, buf)
    return _unpack_rgb(img)
end

function safe_webp_encode(img::Matrix{RGB{N0f8}}, quality::Int)::Vector{UInt8}
    img_t = permutedims(img, (2, 1))
    return GC.@preserve img_t WebP.encode(img_t; lossy=true, quality=Float32(quality), transpose=true)
end

function channels_to_rgb_matrix(R::AbstractMatrix{UInt8}, G::AbstractMatrix{UInt8}, B::AbstractMatrix{UInt8})
    h, w = size(R)
    out = Matrix{RGB{N0f8}}(undef, h, w)
    @inbounds for j in 1:w, i in 1:h
        out[i, j] = RGB{N0f8}(reinterpret(N0f8, R[i, j]), reinterpret(N0f8, G[i, j]), reinterpret(N0f8, B[i, j]))
    end
    return out
end

function to_ink_alpha(R::AbstractMatrix{UInt8}, G::AbstractMatrix{UInt8}, B::AbstractMatrix{UInt8})
    h, w = size(R)
    ink = Matrix{Float32}(undef, h, w)
    @inbounds for j in 1:w, i in 1:h
        d = max(abs(Float32(R[i, j]) - BG_F32),
                abs(Float32(G[i, j]) - BG_F32),
                abs(Float32(B[i, j]) - BG_F32))
        ink[i, j] = clamp(d / 118.0f0, 0.0f0, 1.0f0)
    end
    return ink
end

function build_templates(R0::Matrix{UInt8}, G0::Matrix{UInt8}, B0::Matrix{UInt8})::Templates
    bm_x0 = 977
    bm_h, bm_w = 54, 34
    bookmark = Matrix{Float32}(undef, bm_h, bm_w)
    @inbounds for j in 1:bm_w, i in 1:bm_h
        y = 447 + i
        x = bm_x0 - 1 + j
        bookmark[i, j] = (Float32(R0[y, x]) + Float32(G0[y, x]) + Float32(B0[y, x])) / 3.0f0
    end

    opt_x0 = 121
    opt_w = 46
    opt_h = 34
    opt_starts = Dict("A" => 706, "B" => 777, "C" => 848, "D" => 958)
    opt_letters = Dict{String, Matrix{Float32}}()
    for (k, y0) in opt_starts
        yr = y0:(y0 + opt_h - 1)
        xr = opt_x0:(opt_x0 + opt_w - 1)
        opt_letters[k] = to_ink_alpha(@view(R0[yr, xr]), @view(G0[yr, xr]), @view(B0[yr, xr]))
    end

    pct_close = to_ink_alpha(@view(R0[712:743, 956:985]), @view(G0[712:743, 956:985]), @view(B0[712:743, 956:985]))
    open_bracket = to_ink_alpha(@view(R0[712:743, 929:938]), @view(G0[712:743, 929:938]), @view(B0[712:743, 929:938]))

    return Templates(bookmark, bm_x0, opt_letters, opt_x0, pct_close, open_bracket)
end

function find_bookmarks(R::Matrix{UInt8}, G::Matrix{UInt8}, B::Matrix{UInt8}, tpl::Templates)::Vector{Int}
    h, _ = size(R)
    bm_h, bm_w = size(tpl.bookmark)
    h < bm_h && return Int[]

    x0 = tpl.bm_x0
    strip = Matrix{Float32}(undef, h, bm_w)
    @inbounds for j in 1:bm_w, i in 1:h
        x = x0 + j - 1
        strip[i, j] = (Float32(R[i, x]) + Float32(G[i, x]) + Float32(B[i, x])) / 3.0f0
    end

    out_h = h - bm_h + 1
    inv_area = 1.0f0 / Float32(bm_h * bm_w)
    maes = Vector{Float32}(undef, out_h)
    @inbounds for y in 1:out_h
        acc = 0.0f0
        for j in 1:bm_w, i in 1:bm_h
            acc += abs(strip[y + i - 1, j] - tpl.bookmark[i, j])
        end
        maes[y] = acc * inv_area
    end

    hits = findall(<(12.0f0), maes)
    isempty(hits) && return Int[]

    result = Int[]
    grp_start = 1
    for k in 2:(length(hits) + 1)
        if k > length(hits) || hits[k] - hits[k - 1] > 30
            grp = @view hits[grp_start:(k - 1)]
            best_i = argmin(@view maes[grp])
            push!(result, grp[best_i])
            grp_start = k
        end
    end
    return result
end

function find_white_bars(R::Matrix{UInt8}, G::Matrix{UInt8}, B::Matrix{UInt8})::Vector{Tuple{Int, Int}}
    h, w = size(R)
    x0, x1 = 1021, min(w, 1075)
    inv_cnt = 1.0f0 / Float32(3 * (x1 - x0 + 1))
    white_ys = Int[]
    @inbounds for y in 261:h
        s = 0.0f0
        for x in x0:x1
            s += Float32(R[y, x]) + Float32(G[y, x]) + Float32(B[y, x])
        end
        if s * inv_cnt > 252.5f0
            push!(white_ys, y)
        end
    end

    bars = Tuple{Int, Int}[]
    isempty(white_ys) && return bars
    grp_start = 1
    for k in 2:(length(white_ys) + 1)
        if k > length(white_ys) || white_ys[k] - white_ys[k - 1] > 10
            len = k - grp_start
            if 80 <= len <= 145
                push!(bars, (white_ys[grp_start], white_ys[k - 1]))
            end
            grp_start = k
        end
    end
    return bars
end

function find_option_ys(qR::AbstractMatrix{UInt8}, qG::AbstractMatrix{UInt8}, qB::AbstractMatrix{UInt8}, tpl::Templates)
    h, _ = size(qR)
    opt_h, opt_w = size(tpl.opt_letters["A"])
    found = Pair{String, Int}[]
    h < opt_h + 10 && return found

    x_pad = 4
    x_start = tpl.opt_x0 - x_pad
    x_end = tpl.opt_x0 + opt_w - 1 + x_pad
    strip = to_ink_alpha(@view(qR[:, x_start:x_end]), @view(qG[:, x_start:x_end]), @view(qB[:, x_start:x_end]))
    max_y = h - opt_h + 1
    nx = 2 * x_pad + 1
    inv_area = 1.0f0 / Float32(opt_h * opt_w)

    min_y = 61
    for letter in ("A", "B", "C", "D")
        min_y > max_y && break
        t = tpl.opt_letters[letter]
        best_mae = Inf32
        best_y = min_y
        @inbounds for y in min_y:max_y
            row_best = Inf32
            for dx in 0:(nx - 1)
                acc = 0.0f0
                for j in 1:opt_w, i in 1:opt_h
                    acc += abs(strip[y + i - 1, dx + j] - t[i, j])
                end
                m = acc * inv_area
                if m < row_best
                    row_best = m
                end
            end
            if row_best < best_mae
                best_mae = row_best
                best_y = y
            end
        end
        if best_mae < 0.19f0
            push!(found, letter => best_y)
            min_y = best_y + 38
        end
    end
    return found
end

function detect_correct_answer(qR::AbstractMatrix{UInt8}, qG::AbstractMatrix{UInt8}, qB::AbstractMatrix{UInt8}, opt_ys::Vector{Pair{String, Int}})
    isempty(opt_ys) && return (nothing, 0.0)
    h, w = size(qR)

    gutter_scores = Dict{String, Int}()
    text_scores = Dict{String, Int}()
    for idx in eachindex(opt_ys)
        letter, oy = opt_ys[idx]
        y0 = max(1, oy - 18)
        y1 = idx < length(opt_ys) ? (opt_ys[idx + 1][2] - 18) : h
        gs = 0
        ts = 0
        @inbounds for x in 56:min(w, 1050), y in y0:y1
            r = Int(qR[y, x]); g = Int(qG[y, x]); b = Int(qB[y, x])
            if (g - r > 12) && (g - b > 38)
                if x <= 115
                    gs += 1
                elseif x >= 119
                    ts += 1
                end
            end
        end
        gutter_scores[letter] = gs
        text_scores[letter] = ts
    end

    letters = [p[1] for p in opt_ys]
    best_gutter = letters[argmax([gutter_scores[l] for l in letters])]
    best_text = letters[argmax([text_scores[l] for l in letters])]

    if gutter_scores[best_gutter] >= 150
        return (best_gutter, best_gutter == best_text ? 1.0 : 0.85)
    elseif text_scores[best_text] >= 150
        return (best_text, 0.8)
    end
    return (nothing, 0.0)
end

function fft_ssd(img::Matrix{Float32}, tpl::Matrix{Float32})::Matrix{Float32}
    ih, iw = size(img)
    th, tw = size(tpl)
    oh, ow = ih - th + 1, iw - tw + 1

    # 2D integral image of img.^2
    cs = zeros(Float64, ih + 1, iw + 1)
    @inbounds for j in 1:iw, i in 1:ih
        v = Float64(img[i, j])
        cs[i + 1, j + 1] = v * v + cs[i, j + 1] + cs[i + 1, j] - cs[i, j]
    end

    fh = nextpow(2, ih + th - 1)
    fw = nextpow(2, iw + tw - 1)

    pad_img = zeros(Float32, fh, fw)
    pad_img[1:ih, 1:iw] .= img

    pad_tpl = zeros(Float32, fh, fw)
    @inbounds for j in 1:tw, i in 1:th
        pad_tpl[i, j] = tpl[th - i + 1, tw - j + 1]
    end

    corr_full = irfft(rfft(pad_img) .* rfft(pad_tpl), fh)
    tpl_energy = sum(abs2, tpl)

    ssd = Matrix{Float32}(undef, oh, ow)
    @inbounds for j in 1:ow, i in 1:oh
        win_e = cs[i + th, j + tw] - cs[i, j + tw] - cs[i + th, j] + cs[i, j]
        c = Float64(corr_full[i + th - 1, j + tw - 1])
        ssd[i, j] = Float32(max(0.0, win_e + tpl_energy - 2.0 * c))
    end
    return ssd
end

function erase_percentages!(oR::AbstractMatrix{UInt8}, oG::AbstractMatrix{UInt8}, oB::AbstractMatrix{UInt8}, tpl::Templates)::Int
    h, w = size(oR)
    th, tw = size(tpl.pct_close)
    (h < th + 4 || w < tw + 120) && return 0

    ink = to_ink_alpha(oR, oG, oB)
    sub_ink = ink[:, 116:w]
    mse = fft_ssd(sub_ink, tpl.pct_close) ./ Float32(th * tw)

    hits = Tuple{Float32, Int, Int}[]
    oh, ow = size(mse)
    @inbounds for j in 1:ow, i in 1:oh
        v = mse[i, j]
        if v < 0.045f0
            push!(hits, (v, i, j + 115))
        end
    end
    isempty(hits) && return 0
    sort!(hits, by = first)

    erased = Tuple{Int, Int}[]
    ob_h, ob_w = size(tpl.open_bracket)
    inv_ob = 1.0f0 / Float32(ob_h * ob_w)

    for (_, y, x) in hits
        any(p -> abs(y - p[1]) < 20 && abs(x - p[2]) < 40, erased) && continue
        push!(erased, (y, x))

        search_x0 = max(116, x - 95)
        search_x1 = max(search_x0 + ob_w - 1, x - 12)
        left_x = max(116, x - 62)
        if search_x1 - search_x0 + 1 >= ob_w && y + ob_h - 1 <= h
            best_mae = Inf32
            best_x = search_x0
            @inbounds for sx in search_x0:(search_x1 - ob_w + 1)
                acc = 0.0f0
                for j in 1:ob_w, i in 1:ob_h
                    acc += abs(ink[y + i - 1, sx + j - 1] - tpl.open_bracket[i, j])
                end
                m = acc * inv_ob
                if m < best_mae
                    best_mae = m
                    best_x = sx
                end
            end
            if best_mae < 0.18f0
                left_x = best_x
            end
        end

        ry0 = max(1, y - 4)
        ry1 = min(h, y + th + 3)
        rx0 = max(116, left_x - 5)
        rx1 = min(w, x + tw + 4)
        oR[ry0:ry1, rx0:rx1] .= BG_VAL
        oG[ry0:ry1, rx0:rx1] .= BG_VAL
        oB[ry0:ry1, rx0:rx1] .= BG_VAL
    end
    return length(erased)
end

function mask_question_spoilers(qR::AbstractMatrix{UInt8}, qG::AbstractMatrix{UInt8}, qB::AbstractMatrix{UInt8},
                                opt_ys::Vector{Pair{String, Int}}, tpl::Templates)
    outR = copy(qR); outG = copy(qG); outB = copy(qB)
    isempty(opt_ys) && return (outR, outG, outB, 0)

    h, w = size(outR)
    opt_top = max(1, minimum(p[2] for p in opt_ys) - 22)

    # 1. Erase green checkmark & red X icons in left gutter (ONLY in options zone)
    outR[opt_top:h, 46:116] .= BG_VAL
    outG[opt_top:h, 46:116] .= BG_VAL
    outB[opt_top:h, 46:116] .= BG_VAL

    # 2. Smoothly recolor green option text to neutral grey matching A/B/D stroke weight
    # Pure green ink has B ≈ 50 (span 197 from bg=247); a slight gamma corrects 4:2:0 chroma
    # bleed so recolored letters don't appear heavier/bolder than the other options.
    @inbounds for x in 117:w, y in opt_top:h
        r = Float32(outR[y, x])
        g = Float32(outG[y, x])
        b = Float32(outB[y, x])
        if (g - r > 4.0f0) && (g - b > 10.0f0) && (b < 244.0f0)
            alpha = clamp((BG_F32 - b) / 197.0f0, 0.0f0, 1.0f0) ^ 1.35f0
            gray = round(UInt8, BG_F32 * (1.0f0 - alpha) + NEUTRAL_INK_GRAY * alpha)
            outR[y, x] = gray
            outG[y, x] = gray
            outB[y, x] = gray
        end
    end

    # 3. Erase '[XX%]' poll badges in options zone
    n_pct = erase_percentages!(@view(outR[opt_top:h, :]), @view(outG[opt_top:h, :]), @view(outB[opt_top:h, :]), tpl)
    return (outR, outG, outB, n_pct)
end

function detect_has_diagram(qR::AbstractMatrix{UInt8}, qG::AbstractMatrix{UInt8}, qB::AbstractMatrix{UInt8},
                            opt_ys::Vector{Pair{String, Int}})::Bool
    isempty(opt_ys) && return false
    stem_bottom = max(0, minimum(p[2] for p in opt_ys) - 20)
    stem_bottom < 120 && return false

    sat_cnt = 0
    dense_rows = 0
    @inbounds for y in 41:stem_bottom
        dark_in_row = 0
        for x in 41:950
            r = Int(qR[y, x]); g = Int(qG[y, x]); b = Int(qB[y, x])
            if max(r, g, b) - min(r, g, b) > 25
                sat_cnt += 1
            end
            if r + g + b < 540
                dark_in_row += 1
            end
        end
        if dark_in_row > 80
            dense_rows += 1
        end
    end
    return sat_cnt > 1200 || (stem_bottom > 450 && dense_rows > 180)
end

function trim_trailing_bg(R::AbstractMatrix{UInt8}, G::AbstractMatrix{UInt8}, B::AbstractMatrix{UInt8}; pad::Int=24)
    h, w = size(R)
    last_row = h
    @inbounds for y in h:-1:1
        cnt = 0
        for x in 1:w
            if max(abs(Int(R[y, x]) - 247), abs(Int(G[y, x]) - 247), abs(Int(B[y, x]) - 247)) > 15
                cnt += 1
                cnt > 10 && break
            end
        end
        if cnt > 10
            last_row = min(h, y + pad)
            break
        end
    end
    return (@view(R[1:last_row, :]), @view(G[1:last_row, :]), @view(B[1:last_row, :]))
end

function process_page(page_num::Int, pdf_path::String, offset::Int, len::Int, tpl::Templates, images_dir::String, quality::Int)
    R, G, B = load_page_rgb_channels(pdf_path, offset, len)
    h, _ = size(R)
    bms = find_bookmarks(R, G, B, tpl)
    bars = find_white_bars(R, G, B)

    warnings = String[]
    items = Dict{String, Any}[]

    if length(bms) != length(bars)
        push!(warnings, "Page $page_num: bookmark count ($(length(bms))) != white bar count ($(length(bars)))")
    end

    for (q_i, bm_y) in enumerate(bms)
        next_bm = q_i < length(bms) ? bms[q_i + 1] : h
        matching = [b for b in bars if bm_y < b[1] < next_bm]
        if isempty(matching)
            push!(warnings, "Page $page_num Q$q_i: no white bar found, skipped")
            continue
        end
        bar_start = matching[1][1]

        q_top = max(256, bm_y - 42)
        qR = @view R[q_top:(bar_start - 1), :]
        qG = @view G[q_top:(bar_start - 1), :]
        qB = @view B[q_top:(bar_start - 1), :]

        e_bottom = q_i < length(bms) ? (next_bm - 48) : h
        eR, eG, eB = trim_trailing_bg(@view(R[bar_start:e_bottom, :]), @view(G[bar_start:e_bottom, :]), @view(B[bar_start:e_bottom, :]))

        opt_ys = find_option_ys(qR, qG, qB, tpl)
        ans, conf = detect_correct_answer(qR, qG, qB, opt_ys)
        if ans === nothing
            push!(warnings, "Page $page_num Q$q_i: could not detect answer")
        end

        mR, mG, mB, n_pct = mask_question_spoilers(qR, qG, qB, opt_ys, tpl)
        has_diag = detect_has_diagram(qR, qG, qB, opt_ys)

        stem = "p$(lpad(page_num, 3, '0'))_q$(lpad(q_i, 2, '0'))"
        q_rel = "images/$(stem)_q.webp"
        e_rel = "images/$(stem)_e.webp"

        write(joinpath(images_dir, "$(stem)_q.webp"), safe_webp_encode(channels_to_rgb_matrix(mR, mG, mB), quality))
        write(joinpath(images_dir, "$(stem)_e.webp"), safe_webp_encode(channels_to_rgb_matrix(eR, eG, eB), quality))

        push!(items, Dict{String, Any}(
            "page" => page_num,
            "index_on_page" => q_i,
            "answer" => something(ans, "?"),
            "confidence" => conf,
            "options" => isempty(opt_ys) ? ["A", "B", "C", "D"] : [p[1] for p in opt_ys],
            "has_diagram" => has_diag,
            "pct_masked" => n_pct,
            "q_img" => q_rel,
            "e_img" => e_rel,
            "q_width" => size(mR, 2),
            "q_height" => size(mR, 1),
            "e_height" => size(eR, 1),
        ))
    end
    return items, warnings
end

function extract_pdf(
    pdf_path::AbstractString,
    out_dir::AbstractString = DEFAULT_DATA_DIR;
    pages::Union{Nothing, Vector{Int}} = nothing,
    quality::Int = 85,
)
    t0 = time()
    FFTW.set_num_threads(1)
    isfile(pdf_path) || error("PDF file not found: $pdf_path")
    images_dir = joinpath(out_dir, "images")
    mkpath(images_dir)

    println("Indexing JPEG streams in $(basename(pdf_path)) ...")
    jpeg_ranges = index_pdf_jpegs(pdf_path)
    total_pages = length(jpeg_ranges)
    println("Found $total_pages pages. Calibrating templates from page 1 ...")

    R0, G0, B0 = load_page_rgb_channels(pdf_path, jpeg_ranges[1][1], jpeg_ranges[1][2])
    tpl = build_templates(R0, G0, B0)

    target_pages = pages === nothing ? collect(1:total_pages) : pages
    println("Extracting $(length(target_pages))/$total_pages pages -> $out_dir (threads=$(Threads.nthreads())) ...")

    results = Vector{Vector{Dict{String, Any}}}(undef, length(target_pages))
    warn_lists = Vector{Vector{String}}(undef, length(target_pages))
    done_cnt = Threads.Atomic{Int}(0)

    Threads.@threads for idx in eachindex(target_pages)
        pnum = target_pages[idx]
        off, len = jpeg_ranges[pnum]
        items, warns = process_page(pnum, String(pdf_path), off, len, tpl, images_dir, quality)
        results[idx] = items
        warn_lists[idx] = warns
        c = Threads.atomic_add!(done_cnt, 1) + 1
        if c % 20 == 0 || c == length(target_pages)
            println("  Processed $c/$(length(target_pages)) pages ($(round(time() - t0; digits=1))s)")
        end
    end

    questions = Dict{String, Any}[]
    all_warnings = String[]
    qid = 1
    for idx in eachindex(target_pages)
        append!(all_warnings, warn_lists[idx])
        for item in results[idx]
            item["id"] = qid
            push!(questions, item)
            qid += 1
        end
    end

    unknown_ans = count(q -> q["answer"] == "?", questions)
    diag_cnt = count(q -> q["has_diagram"] == true, questions)

    summary = Dict{String, Any}(
        "source_pdf" => basename(pdf_path),
        "total_pages" => total_pages,
        "extracted_pages" => length(target_pages),
        "total_questions" => length(questions),
        "diagram_questions" => diag_cnt,
        "unknown_answers" => unknown_ans,
        "questions" => questions,
    )

    out_json = joinpath(out_dir, "questions.json")
    open(out_json, "w") do io
        JSON3.pretty(io, summary)
    end

    println("Done in $(round(time() - t0; digits=1))s: $(length(questions)) questions ($diag_cnt with diagrams, $unknown_ans unknown answers). Saved to $out_json")
    if !isempty(all_warnings)
        println("Warnings ($(length(all_warnings))):")
        for w in first(all_warnings, 25)
            println("  - $w")
        end
    end
    return summary
end

function _parse_extract_args(args::Vector{String})
    pdf = nothing
    out = DEFAULT_DATA_DIR
    pages = nothing
    quality = 85
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--pdf=")
            pdf = String(a[7:end]); i += 1
        elseif a == "--pdf" && i < length(args)
            pdf = args[i + 1]; i += 2
        elseif startswith(a, "--out=")
            out = String(a[7:end]); i += 1
        elseif a == "--out" && i < length(args)
            out = args[i + 1]; i += 2
        elseif startswith(a, "--pages=")
            pages = [parse(Int, strip(s)) for s in split(a[9:end], ",") if !isempty(strip(s))]; i += 1
        elseif a == "--pages" && i < length(args)
            pages = [parse(Int, strip(s)) for s in split(args[i + 1], ",") if !isempty(strip(s))]; i += 2
        elseif startswith(a, "--quality=")
            quality = parse(Int, a[11:end]); i += 1
        elseif a == "--quality" && i < length(args)
            quality = parse(Int, args[i + 1]); i += 2
        else
            i += 1
        end
    end
    pdf === nothing && error("--pdf=\"path/to/file.pdf\" is required.")
    return pdf, out, pages, quality
end

if abspath(PROGRAM_FILE) == @__FILE__
    pdf_path, out_dir, pages, quality = _parse_extract_args(ARGS)
    extract_pdf(pdf_path, out_dir; pages=pages, quality=quality)
end
