#!/usr/bin/env julia
"""Lightweight local Julia HTTP server for the Snap2Q interactive app."""

if !isdefined(@__MODULE__, :PharmaQBank)
    include(joinpath(@__DIR__, "PharmaQBank.jl"))
end
using .PharmaQBank

using HTTP
using JSON3
using Sockets

const MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".js"   => "application/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".webp" => "image/webp",
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".svg"  => "image/svg+xml",
)

function serve_file(path::String; cache_seconds::Int=0)::HTTP.Response
    isfile(path) || return HTTP.Response(404, "Not Found")
    ext = lowercase(splitext(path)[2])
    ctype = get(MIME_TYPES, ext, "application/octet-stream")
    cc = cache_seconds > 0 ? "public, max-age=$cache_seconds" : "no-cache"
    return HTTP.Response(200, ["Content-Type" => ctype, "Cache-Control" => cc], read(path))
end

function safe_join(root::String, rel::String)::Union{String, Nothing}
    root_abs = normpath(abspath(root))
    target = normpath(abspath(joinpath(root_abs, lstrip(rel, '/'))))
    return startswith(target, root_abs) ? target : nothing
end

function open_browser(url::String)
    try
        if Sys.iswindows()
            run(`cmd /c start "" $url`; wait=false)
        elseif Sys.isapple()
            run(`open $url`; wait=false)
        else
            run(`xdg-open $url`; wait=false)
        end
    catch
    end
end

function serve_qbank(;
    host::String = "127.0.0.1",
    port::Int = 8765,
    data_dir::AbstractString = DEFAULT_DATA_DIR,
    no_open::Bool = false,
)
    web_dir = DEFAULT_WEB_DIR
    data_dir_str = String(data_dir)
    progress_file = joinpath(data_dir_str, "progress.json")
    progress_lock = ReentrantLock()

    if !isfile(joinpath(data_dir_str, "questions.json"))
        println("Warning: $(joinpath(data_dir_str, "questions.json")) not found yet. Extract a PDF first.")
    end

    handler = function (req::HTTP.Request)
        try
            uri = HTTP.URI(req.target)
            path = HTTP.URIs.unescapeuri(uri.path)

            if path == "/api/progress"
                if req.method == "GET"
                    body = lock(progress_lock) do
                        isfile(progress_file) ? read(progress_file, String) : "{}"
                    end
                    return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"], body)
                elseif req.method == "POST"
                    try
                        parsed = JSON3.read(String(req.body))
                        lock(progress_lock) do
                            mkpath(data_dir_str)
                            open(progress_file, "w") do io
                                JSON3.pretty(io, parsed)
                            end
                        end
                        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], "{\"ok\":true}")
                    catch
                        return HTTP.Response(400, ["Content-Type" => "application/json; charset=utf-8"], "{\"error\":\"Invalid JSON\"}")
                    end
                end
            end

            if startswith(path, "/data/")
                rel = String(path[7:end])
                target = safe_join(data_dir_str, rel)
                target === nothing && return HTTP.Response(403, "Forbidden")
                cache = startswith(rel, "images/") ? 86400 : 0
                return serve_file(target; cache_seconds=cache)
            end

            if path == "" || path == "/"
                return serve_file(joinpath(web_dir, "index.html"))
            end

            target = safe_join(web_dir, String(path))
            target === nothing && return HTTP.Response(403, "Forbidden")
            return serve_file(target)
        catch e
            msg = sprint(showerror, e, catch_backtrace())
            println(stderr, "Request error on $(req.target):\n$msg")
            return HTTP.Response(500, ["Content-Type" => "text/plain"], msg)
        end
    end

    url = "http://$host:$port"
    println("Pharmacology QBank (Julia) running at $url (Ctrl+C to stop)")
    if !no_open
        @async begin
            sleep(0.5)
            open_browser(url)
        end
    end

    HTTP.serve(handler, host, port; verbose=false)
end

function _parse_server_args(args::Vector{String})
    host = "127.0.0.1"
    port = 8765
    data_dir = DEFAULT_DATA_DIR
    no_open = false
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--host=")
            host = String(a[8:end]); i += 1
        elseif a == "--host" && i < length(args)
            host = args[i + 1]; i += 2
        elseif startswith(a, "--port=")
            port = parse(Int, a[8:end]); i += 1
        elseif a == "--port" && i < length(args)
            port = parse(Int, args[i + 1]); i += 2
        elseif startswith(a, "--data=")
            data_dir = String(a[8:end]); i += 1
        elseif a == "--data" && i < length(args)
            data_dir = args[i + 1]; i += 2
        elseif a == "--no-open"
            no_open = true; i += 1
        else
            i += 1
        end
    end
    return host, port, data_dir, no_open
end

if abspath(PROGRAM_FILE) == @__FILE__
    host, port, data_dir, no_open = _parse_server_args(ARGS)
    serve_qbank(; host=host, port=port, data_dir=data_dir, no_open=no_open)
end
