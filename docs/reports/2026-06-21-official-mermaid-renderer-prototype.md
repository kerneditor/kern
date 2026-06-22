# Official Mermaid Renderer Prototype — 2026-06-21

## Scope

This records the first safe official-Mermaid renderer prototype step for Kern.
The shipped app remains native AppKit/TextKit and does not bundle Node, Mermaid
CLI, WebView, Electron, or Tauri.

## Implemented

- Added `officialExternal` to `nativeEditor.mermaidRenderMode` and to Settings
  as `Official External (cached)`.
- Added user preferences for an optional Mermaid CLI command, opt-in `npx`, and
  clearing the official Mermaid PNG cache.
- Added an optional Puppeteer config preference for Mermaid CLI via
  `nativeEditor.officialMermaidPuppeteerConfigFile` /
  `KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE`.
- Kept first-open behavior non-blocking: `officialExternal` checks the cache and
  falls back to native `rich` rendering while external rendering is missing,
  in-flight, disabled, or failed.
- Added a theme-aware and width-bucketed PNG cache key: Mermaid source + output
  format + light/dark Mermaid theme + width bucket + renderer/config
  fingerprint.
- Added an async renderer path on a utility queue with a render timeout and
  process cleanup for failed or hung external commands.
- Runs external renderer commands through `/usr/bin/env` with parsed arguments,
  not through a shell, so the preference supports `mmdc`, absolute paths, and
  `npx -y @mermaid-js/mermaid-cli@...` without shell interpolation.
- Supplies a stable renderer subprocess environment with Homebrew, `/usr/local`,
  and system tool paths so app-launched `npx` can find its `node` executable.
- Passes `-q` to Mermaid CLI and passes `-p <config>` when an optional
  Puppeteer config path is configured.
- Added visible diagnostics for disabled, rendering, and failed official-render
  states.
- Added regression tests for preference parsing, Settings persistence/cache
  clearing, no-renderer fallback, configured cache hit, and failed renderer
  behavior without hanging.
- Added `scripts/eval-official-mermaid-renderer.sh` to evaluate Mermaid CLI
  output against the tracked Mermaid corpus outside the app target.
- Added `scripts/eval-rich-block-rendering.sh` for visual QA contact sheets
  across math, native Mermaid, ASCII Mermaid, auto, and official external modes.
  The official-external visual gate now fails if a configured renderer silently
  falls back for all valid diagrams.

## Renderer discovery behavior

The app uses, in order:

1. `KERN_OFFICIAL_MERMAID_RENDERER_COMMAND` when present;
2. `nativeEditor.officialMermaidRendererCommand` when set in Settings;
3. an opt-in `npx` command only when `KERN_OFFICIAL_MERMAID_USE_NPX=1` or the
   Settings checkbox is enabled.

The opt-in `npx` path prefers `/opt/homebrew/bin/npx`, then `/usr/local/bin/npx`,
then `/usr/bin/npx`, then falls back to PATH lookup via `/usr/bin/env`.

Optional Puppeteer configuration is read from
`KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE` first, then
`nativeEditor.officialMermaidPuppeteerConfigFile`. When set, Kern passes the
path to Mermaid CLI with `-p`. This is useful for local Chromium/Puppeteer
configuration without bundling Chromium or Node into Kern.

The eval script uses the same safety posture: it does not silently install or run
Node tooling unless explicitly opted in.

## Local smoke and QA results

### Official Mermaid CLI corpus

Command:

```bash
KERN_OFFICIAL_MERMAID_USE_NPX=1 KERN_OFFICIAL_MERMAID_FORMAT=png KERN_OFFICIAL_MERMAID_WIDTH=896 ./scripts/eval-official-mermaid-renderer.sh
```

Results:

- Light/default theme: 16/17 corpus cases rendered; invalid syntax classified as
  expected failure.
- Dark theme: 16/17 corpus cases rendered; invalid syntax classified as expected
  failure.
- Artifacts:
  - `benchmark-archive/official-mermaid-renderer/20260621-221200-width896-default/official-mermaid-renderer.json`
  - `benchmark-archive/official-mermaid-renderer/20260621-221357-width896-dark/official-mermaid-renderer.json`

### In-app TextKit visual QA

Command:

```bash
KERN_OFFICIAL_MERMAID_RENDERER_COMMAND=/usr/bin/false \
KERN_OFFICIAL_MERMAID_CACHE_DIR="$PWD/test-results/official-mermaid-cache/20260621-width896-visual" \
KERN_OFFICIAL_MERMAID_VISUAL_TIMEOUT_SECONDS=8 \
./scripts/eval-rich-block-rendering.sh
```

Result:

- Xcode result: passed.
- XCTest target: `KernTextKitTests/NativeRichBlockEvalCorpusTests/testRichBlockEvalCorpus`.
- 10 PNG contact sheets generated.
- Official external sheets used pre-seeded official Mermaid PNGs for valid
  diagrams and deterministic failed-renderer fallback for the invalid case.
- Latest visual artifacts:
  - `test-results/rich-block-eval/20260621-223840/mermaid-officialExternal-light.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-officialExternal-dark.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-officialExternal-dark-invalid-crop.png`
  - `test-results/rich-block-eval/20260621-223840/visual-index.md`

Visual QA notes:

- Official external mode displays actual Mermaid CLI output on cache hits.
- Dark and light official sheets render with theme-appropriate Mermaid output.
- Invalid Mermaid no longer hangs or stays stuck on a transient rendering state;
  it shows native rich fallback plus a clear failure diagnostic.
- ASCII mode is readable and no longer shows the previous double-window frame.


### Strict app-side official-renderer visual QA refresh

Command:

```bash
KERN_OFFICIAL_MERMAID_RENDERER_COMMAND="/opt/homebrew/bin/npx -y @mermaid-js/mermaid-cli@11.15.0" \
KERN_OFFICIAL_MERMAID_CACHE_DIR="$PWD/test-results/official-mermaid-cache/live-fixed-20260621-230446" \
KERN_OFFICIAL_MERMAID_VISUAL_TIMEOUT_SECONDS=120 \
KERN_RICH_BLOCK_EVAL_OUTPUT_DIR="$PWD/test-results/rich-block-eval/live-fixed-20260621-230446" \
./scripts/eval-rich-block-rendering.sh
```

Result:

- Xcode result: passed.
- XCTest target: `KernTextKitTests/NativeRichBlockEvalCorpusTests/testRichBlockEvalCorpus`.
- Official Mermaid cache files created: 32 PNGs (16 valid corpus diagrams ×
  light/dark themes).
- Official external visual sheets generated from the app-hosted TextKit path:
  - `test-results/rich-block-eval/live-fixed-20260621-230446/mermaid-officialExternal-light.png`
  - `test-results/rich-block-eval/live-fixed-20260621-230446/mermaid-officialExternal-dark.png`
- Root-cause fix from this refresh: app-hosted renderer subprocesses had a
  minimal PATH, so Homebrew `npx` could start but its `/usr/bin/env node`
  shebang could not find `node`. Kern now supplies a stable subprocess PATH.

### Adversarial review refresh

The 2026-06-22 adversarial review found and fixed three implementation risks:

- Cache clearing originally removed the whole configured cache directory. It now
  creates/preserves the directory and deletes only Kern-generated artifacts:
  `.work-*` scratch directories and generated 64-character hash PNGs.
- Cache identity originally did not include renderer command/configuration. It
  now includes the resolved renderer command and Puppeteer config path, so
  renderer or Chromium config changes cannot silently reuse stale PNGs.
- Mermaid CLI argument handling now matches the documented/current CLI surface:
  quiet mode uses `-q`, and optional Puppeteer config uses `-p`.

Added regression coverage for quoted renderer commands, renderer/config cache
identity changes, safe cache clearing, Settings persistence for the Puppeteer
config field, and benchmark fake-renderer compatibility with `-q`/`-p`.

### Official Mermaid CLI corpus refresh

Command family:

```bash
KERN_OFFICIAL_MERMAID_RENDERER_COMMAND="/opt/homebrew/bin/npx -y @mermaid-js/mermaid-cli@11.15.0" \
KERN_OFFICIAL_MERMAID_FORMAT=png \
KERN_OFFICIAL_MERMAID_WIDTH=896 \
KERN_OFFICIAL_MERMAID_THEME=default ./scripts/eval-official-mermaid-renderer.sh

KERN_OFFICIAL_MERMAID_RENDERER_COMMAND="/opt/homebrew/bin/npx -y @mermaid-js/mermaid-cli@11.15.0" \
KERN_OFFICIAL_MERMAID_FORMAT=png \
KERN_OFFICIAL_MERMAID_WIDTH=896 \
KERN_OFFICIAL_MERMAID_THEME=dark ./scripts/eval-official-mermaid-renderer.sh
```

Results:

- Default theme: passed; 16 rendered, 1 expected invalid failure, 0 unexpected failures.
- Dark theme: passed; 16 rendered, 1 expected invalid failure, 0 unexpected failures.
- Artifacts:
  - `benchmark-archive/official-mermaid-renderer/20260621-230659-width896-default/official-mermaid-renderer.json`
  - `benchmark-archive/official-mermaid-renderer/20260621-230659-width896-dark/official-mermaid-renderer.json`

### 2026-06-22 app-side official-renderer visual QA

Command:

```bash
KERN_OFFICIAL_MERMAID_RENDERER_COMMAND="/opt/homebrew/bin/npx -y @mermaid-js/mermaid-cli@11.15.0" \
KERN_OFFICIAL_MERMAID_CACHE_DIR="$PWD/test-results/official-mermaid-cache/official-review-20260622-121630" \
KERN_OFFICIAL_MERMAID_VISUAL_TIMEOUT_SECONDS=140 \
KERN_RICH_BLOCK_EVAL_OUTPUT_DIR="$PWD/test-results/rich-block-eval/official-review-20260622-121630" \
./scripts/eval-rich-block-rendering.sh
```

Result:

- Xcode result: passed; 1 XCTest, 0 failures.
- Official Mermaid cache files created: 32 PNGs (16 valid corpus diagrams ×
  light/dark themes).
- Official external visual sheets generated from the app-hosted TextKit path:
  - `test-results/rich-block-eval/official-review-20260622-121630/mermaid-officialExternal-light.png`
  - `test-results/rich-block-eval/official-review-20260622-121630/mermaid-officialExternal-dark.png`

Standalone CLI smoke also passed for dark mode with 16 rendered cases, 1
expected invalid failure, and 0 unexpected failures:
`benchmark-archive/official-mermaid-renderer/review-20260622-121809-width896-dark/official-mermaid-renderer.json`.

Targeted implementation regression tests passed: 9 selected tests, 0 failures.
The non-snapshot native editor gate passed: 467 tests, 90 skipped, 0 failures.

## Performance status

The current quick benchmark command:

```bash
KERN_PERF_ITERATIONS=3 KERN_MERMAID_BENCH_RUNS=3 ./scripts/bench-native-editor.sh --quick --include-mermaid
```

Latest final-tree artifact after the app-hosted PATH fix:

- `bench-results/native-editor/20260621-231119/summary.md`
- `bench-results/native-editor/20260621-231119/metrics-summary.json`

Result: XCTest performance selection passed, 6 tests, 0 failures. The parser
compared 12 metrics against the previous same-session baseline and reported 0
regressions over the configured threshold. The machine was still moderately
loaded, so this is a regression smoke, not a quiet-machine product claim.

Mermaid microbenchmarks from that run:

- Heavy generated fixture: rich p50 204.02 ms, ASCII p50 241.77 ms, auto p50
  215.29 ms.
- Smaller generated fixture: rich p50 84.05 ms, ASCII p50 115.41 ms, auto p50
  88.62 ms, official disabled fallback p50 83.80 ms, official cache hit p50
  81.72 ms.

Interpretation: keep `rich` as the default. `officialExternal` is ready as an
optional cached fidelity mode, not as the default. ASCII is a readability fallback,
not a current performance win.

2026-06-22 quick benchmark refresh:

```bash
KERN_PERF_ITERATIONS=3 KERN_MERMAID_BENCH_RUNS=3 ./scripts/bench-native-editor.sh --quick --include-mermaid
```

Artifacts:

- `bench-results/native-editor/20260622-122227/summary.md`
- `bench-results/native-editor/20260622-122227/metrics-summary.json`
- `benchmark-archive/mermaid-render-modes/20260622-122315-mermaid-render-modes.md`
- `benchmark-archive/mermaid-render-modes/20260622-122318-mermaid-render-modes.md`

Result: XCTest performance selection passed, 6 tests, 0 failures. The parser
reported one peak-physical-memory regression on
`NativeMarkdownCodecPerformanceTests.testImportExportBenchmarkFilePerformance`
(282.7 MB current vs 208.1 MB baseline, +35.8%). A fresh isolated rerun of that
single test measured 167.4 MB average peak physical memory, below the stored
baseline, but with high RSD because the first iteration carried a higher peak.
Treat the full-suite memory regression as a noisy high-water warning, not a
confirmed product regression.

Mermaid microbenchmarks from the refresh:

- Heavy generated fixture: rich p50 102.86 ms, ASCII p50 122.99 ms, auto p50
  115.44 ms.
- Smaller generated fixture: rich p50 38.41 ms, ASCII p50 53.68 ms, auto p50
  41.12 ms, official disabled fallback p50 38.37 ms, official cache hit p50
  63.81 ms.

Interpretation remains unchanged: keep `rich` as the default. Official Mermaid
is a high-fidelity optional cached mode. On this run, official cache hits were
slower than native rich because cached PNG loading/raster attachment setup costs
more than the native mini renderer for the benchmark fixture.

## Remaining work

1. Re-run quiet-machine benchmarks with 7-15 iterations before making a renderer
   performance claim.
2. Decide whether PNG remains the right cache format or whether SVG/PDF
   rasterization is worth the implementation cost.
3. Add snapshot baselines for official external sheets only if we can keep the
   external tool deterministic in CI or fixture-seed the cache deterministically.
4. Tune `auto` thresholds only after quiet-machine data; current data does not
   justify using auto as a performance claim.
