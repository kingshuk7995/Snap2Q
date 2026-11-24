# Snap2Q — Interactive Screenshot-to-QBank App (Julia + JS)

An offline, zero-OCR-error interactive QBank app extracted from scrolling QBank screenshot PDFs using **Julia** (`JpegTurbo`, `WebP`, `FFTW`, `JSON3`, `HTTP`). It automatically masks answer spoilers (checkmarks, red Xs, green highlights matched to neutral stroke weight, and `[%]` poll badges), preserves all question & explanation diagrams, and builds either a **single self-contained offline HTML file** or runs a **local web server**.

## Repository Layout
- `main.jl` — Unified CLI controller (`--build=serve|standalone`, `--pdf="..."`, and all options).
- `Project.toml` / `Manifest.toml` — Julia environment & locked dependencies.
- `analysis/` — Pure Julia pipeline modules:
  - `PharmaQBank.jl` — Shared repo-root paths (`data/`, `web/`, `dist/`).
  - `extract.jl` — PDF JPEG stream extractor, template matching, FFT `[%]` masking, stroke-matched green de-coloring, and WebP writer.
  - `build_standalone.jl` — Single self-contained offline HTML bundler.
  - `server.jl` — Local `HTTP.jl` server with `/api/progress` persistence.
- `web/` — Frontend source (`index.html`, `styles.css`, `app.js`).
- `data/` — Extracted `questions.json` and WebP images.
- `dist/` — Single self-contained offline HTML file.

## Usage

1. **Install Julia dependencies (first time):**
   ```powershell
   julia --project=. -e "using Pkg; Pkg.instantiate()"
   ```

2. **Extract from a PDF & build the single self-contained offline HTML file:**
   ```powershell
   julia --project=. -t auto main.jl --build=standalone --pdf="path/to/qbank.pdf"
   ```

3. **Extract from a PDF & launch the local web server:**
   ```powershell
   julia --project=. -t auto main.jl --build=serve --pdf="path/to/qbank.pdf"
   ```

4. **Reuse already-extracted `data/` without re-extracting:**
   ```powershell
   julia --project=. -t auto main.jl --build=standalone
   julia --project=. main.jl --build=serve --port=8765
   ```

5. **See all CLI options:**
   ```powershell
   julia --project=. main.jl --help
   ```
