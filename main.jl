#!/usr/bin/env julia
"""
Unified CLI entry point for Snap2Q.

Usage:
  julia --project=. -t auto main.jl --build=standalone --pdf="path/to/qbank.pdf" [options]
  julia --project=. -t auto main.jl --build=serve      --pdf="path/to/qbank.pdf" [options]
"""

include(joinpath(@__DIR__, "analysis", "PharmaQBank.jl"))
include(joinpath(@__DIR__, "analysis", "extract.jl"))
include(joinpath(@__DIR__, "analysis", "build_standalone.jl"))
include(joinpath(@__DIR__, "analysis", "server.jl"))

using .PharmaQBank

const HELP_TEXT = """
Snap2Q — Unified Julia CLI

USAGE:
  julia --project=. -t auto main.jl --build=<serve|standalone> [OPTIONS]

REQUIRED:
  --build=serve|standalone   Target mode:
                               serve      -> Launch local HTTP server (http://127.0.0.1:8765)
                               standalone -> Build single self-contained offline HTML file

INPUT / EXTRACTION OPTIONS:
  --pdf=PATH                 Path to QBank screenshot PDF to extract into data/
                             (Required if data/questions.json does not exist yet)
  --skip-extract             Reuse existing data/ without re-extracting even if --pdf is given
  --data=DIR                 Data directory (default: data/)
  --pages=1,2,3              Comma-separated 1-based page numbers to extract (default: all)
  --extract-quality=85       WebP quality (1-100) for extracted images in data/ (default: 85)

STANDALONE OPTIONS (--build=standalone):
  --out=FILE                 Output HTML file path (default: dist/snap2q-standalone.html)
  --max-width=680            Max image width in px for embedded HTML (0 = original 1080px, default: 680)
  --quality=65               WebP quality (1-100) for embedded HTML images (default: 65)

SERVER OPTIONS (--build=serve):
  --host=127.0.0.1           Host to bind (default: 127.0.0.1)
  --port=8765                Port to bind (default: 8765)
  --no-open                  Do not auto-open the browser

OTHER:
  -h, --help                 Show this help message

EXAMPLES:
  julia --project=. -t auto main.jl --build=standalone --pdf="path/to/qbank.pdf"
  julia --project=. -t auto main.jl --build=serve --pdf="path/to/qbank.pdf" --port=8080
  julia --project=. -t auto main.jl --build=serve --no-open
"""

function parse_cli(args::Vector{String})
    opts = Dict{String, Any}(
        "build" => nothing,
        "pdf" => nothing,
        "skip_extract" => false,
        "data" => DEFAULT_DATA_DIR,
        "pages" => nothing,
        "extract_quality" => 85,
        "out" => joinpath(DEFAULT_DIST_DIR, "pharma-qbank-standalone.html"),
        "max_width" => 680,
        "quality" => 65.0f0,
        "host" => "127.0.0.1",
        "port" => 8765,
        "no_open" => false,
        "help" => false,
    )

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "-h" || arg == "--help"
            opts["help"] = true
            return opts
        elseif arg == "--skip-extract"
            opts["skip_extract"] = true
            i += 1
            continue
        elseif arg == "--no-open"
            opts["no_open"] = true
            i += 1
            continue
        end

        # Support both --key=value and --key value
        if startswith(arg, "--")
            if occursin("=", arg)
                k, v = split(arg[3:end], "="; limit=2)
                i += 1
            else
                k = arg[3:end]
                i < length(args) || error("Missing value for --$k")
                v = args[i + 1]
                i += 2
            end

            if k == "build"
                opts["build"] = lowercase(String(v))
            elseif k == "pdf"
                opts["pdf"] = String(v)
            elseif k == "data"
                opts["data"] = String(v)
            elseif k == "pages"
                opts["pages"] = [parse(Int, strip(s)) for s in split(v, ",") if !isempty(strip(s))]
            elseif k == "extract-quality"
                opts["extract_quality"] = parse(Int, v)
            elseif k == "out"
                opts["out"] = String(v)
            elseif k == "max-width"
                opts["max_width"] = parse(Int, v)
            elseif k == "quality"
                opts["quality"] = parse(Float32, v)
            elseif k == "host"
                opts["host"] = String(v)
            elseif k == "port"
                opts["port"] = parse(Int, v)
            else
                error("Unknown option: --$k (run with --help to see valid options)")
            end
        else
            error("Unexpected positional argument: $arg (run with --help)")
        end
    end
    return opts
end

function run_cli(args::Vector{String})
    opts = parse_cli(args)
    if opts["help"] || isempty(args)
        print(HELP_TEXT)
        return
    end

    build_mode = opts["build"]
    if !(build_mode in ("serve", "standalone"))
        error("--build must be either 'serve' or 'standalone' (got: $(something(build_mode, "none"))). Run with --help.")
    end

    data_dir = opts["data"]
    pdf_path = opts["pdf"]
    q_json = joinpath(data_dir, "questions.json")

    # Run extraction if --pdf is provided (unless --skip-extract), or require --pdf if data/ is missing
    if pdf_path !== nothing && !opts["skip_extract"]
        isfile(pdf_path) || error("PDF file not found: $pdf_path")
        extract_pdf(
            pdf_path,
            data_dir;
            pages = opts["pages"],
            quality = opts["extract_quality"],
        )
    elseif !isfile(q_json)
        error("No extracted data found at $q_json. Pass --pdf=\"path/to/qbank.pdf\" to extract first.")
    else
        println("Using existing extracted data in $data_dir")
    end

    if build_mode == "standalone"
        build_single_html(
            data_dir,
            DEFAULT_WEB_DIR,
            opts["out"];
            max_width = opts["max_width"],
            quality = opts["quality"],
        )
    elseif build_mode == "serve"
        serve_qbank(
            host = opts["host"],
            port = opts["port"],
            data_dir = data_dir,
            no_open = opts["no_open"],
        )
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        run_cli(ARGS)
    catch e
        println(stderr, "Error: ", sprint(showerror, e))
        exit(1)
    end
end
