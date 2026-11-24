"""Shared paths and utilities for the Snap2Q Julia toolchain."""
module PharmaQBank

export REPO_ROOT, DEFAULT_DATA_DIR, DEFAULT_WEB_DIR, DEFAULT_DIST_DIR

const REPO_ROOT        = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_DATA_DIR = joinpath(REPO_ROOT, "data")
const DEFAULT_WEB_DIR  = joinpath(REPO_ROOT, "web")
const DEFAULT_DIST_DIR = joinpath(REPO_ROOT, "dist")

end # module
