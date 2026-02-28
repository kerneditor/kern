# Benchmark Suite (Native Editor)

## Datasets

Primary benchmark files (committed so results are comparable across machines):
- `test-fixtures/native-editor-benchmark.md` (~3.6MB, ~64K lines, feature-dense — no filler)
- `test-fixtures/cross-editor-benchmark.md` (~18KB, ~580 lines, GFM-only for fair cross-editor comparison)
- `test-fixtures/stress-test.md` (medium, 342 lines)
- `test-fixtures/ultimate-stress-test.md` (permutation-dense, 1493 lines)
- `test-fixtures/mega-stress-test.md` (very large, 11456 lines)

Fixture maintenance:
- `scripts/gen_ultimate_stress_test.py`
- `scripts/sync_mega_permutation_appendix.py`

Guideline:
- Use the same file(s) for all editors.
- Record whether the run is **cold** (after reboot / app not in memory) or **warm** (second run).
- The cross-editor benchmark fixture is content-neutral — no editor names, no benchmark results, no editor-specific paths.

## Baselines

### Environment

- **Date**: 2026-02-18
- **Hardware**: Apple M4
- **macOS**: 26.2
- **Commit**: 9238540 (pre-benchmark-overhaul)

### Codec (native-editor-benchmark.md, ~3.6MB)

| Benchmark | Time | Test Method |
| --- | --- | --- |
| Import+Export round-trip | ~12.1s | `testImportExportBenchmarkFilePerformance` |
| Import only | ~3.5s | `testImportOnlyBenchmarkFilePerformance` |
| Export only | — | `testExportOnlyBenchmarkFilePerformance` |
| parseInline micro (100KB inline-dense) | ~0.13s | `testParseInlineMicroBenchmark` |

### Editor

| Benchmark | Time | Test Method |
| --- | --- | --- |
| Render stress-test.md (24K chars) | — | `testRenderStressFilePerformance` |
| Render mega-stress-test.md (50K chars) | — | `testRenderMegaStressFilePerformance` |
| Render benchmark file (24K chars) | — | `testRenderBenchmarkFilePerformance` |
| Scroll mega-stress-test.md (70K chars) | — | `testScrollMegaStressFilePerformance` |
| Edit-in-middle mega (50K chars) | ~0.016s | `testEditInMiddleOfLargeDocumentPerformance` |
| Incremental typing (2K lines) | — | `testIncrementalTypingPerformance_LiveAppend` |
| Char-by-char ultimate (15K chars) | — | `testTypingUltimateStressCharacterByCharacterPerformance` |
| Char-by-char mega (30K chars) | — | `testTypingMegaStressCharacterByCharacterPerformance` |
| Interleaved action ultimate (12K chars) | — | `testInterleavedActionBurstOnUltimateStressPerformance` |
| Interleaved action mega (20K chars) | — | `testInterleavedActionBurstOnMegaStressPerformance` |

## How to Run

### Engine-Level Benchmarks (XCTest)

```bash
# Quick: run engine benchmarks
./scripts/bench-native-editor.sh

# All codec benchmarks
KERN_ENABLE_PERF_TESTS=1 xcodebuild test \
  -project KernTextKit.xcodeproj -scheme KernTextKit \
  -destination 'platform=macOS' \
  -only-testing:KernTextKitTests/NativeMarkdownCodecPerformanceTests

# All editor benchmarks
KERN_ENABLE_PERF_TESTS=1 xcodebuild test \
  -project KernTextKit.xcodeproj -scheme KernTextKit \
  -destination 'platform=macOS' \
  -only-testing:KernTextKitTests/NativeEditorMegaStressPerformanceTests

# Render benchmark
KERN_ENABLE_PERF_TESTS=1 xcodebuild test \
  -project KernTextKit.xcodeproj -scheme KernTextKit \
  -destination 'platform=macOS' \
  -only-testing:KernTextKitTests/NativeEditorRenderPerformanceTests

# Mermaid render-mode benchmark (rich vs ascii vs auto)
defaults write com.gradigit.kern.tests KERN_ENABLE_MERMAID_MODE_BENCHMARKS -bool YES
defaults write com.gradigit.kern.tests KERN_MERMAID_BENCH_RUNS -int 7
xcodebuild test \
  -project KernTextKit.xcodeproj -scheme KernTextKit \
  -destination 'platform=macOS' \
  -only-testing:KernTextKitTests/NativeMarkdownCodecPerformanceTests/testMermaidRenderModeBenchmarkMatrix

# Cleanup benchmark gate after run
defaults delete com.gradigit.kern.tests KERN_ENABLE_MERMAID_MODE_BENCHMARKS
defaults delete com.gradigit.kern.tests KERN_MERMAID_BENCH_RUNS
```

Benchmark artifacts are written to:
- `benchmark-archive/mermaid-render-modes/`

### Cross-Editor Comparison

#### Phase 1: Stable wrapper entrypoint

```bash
# All detected editors, 30 runs, warm
./scripts/cross-editor-benchmark.sh

# Specific editors, cold starts, JSON output
./scripts/cross-editor-benchmark.sh --editors "Kern,Zed,TextEdit" --cold --runs 30 --json results.json

# Internal microbenchmark (Kern-only)
./scripts/cross-editor-benchmark.sh --suite wow_internal --runs 30

# Optional large-fixture open-ready aside (defaults to Kern+Zed)
./scripts/cross-editor-benchmark.sh --suite benchmark_open_ready --runs 10

# Optional large-fixture full-fidelity aside (defaults to Kern+Zed)
# - Real-usage behavior (no forced full import)
# - Defaults: Zed hook required + styled_stable mode
./scripts/cross-editor-benchmark.sh --suite benchmark_full_fidelity --runs 10

# Fewer runs for quick comparison
./scripts/cross-editor-benchmark.sh --runs 5 --verbose

# Optional: include durable-save probe (off by default for speed)
./scripts/cross-editor-benchmark.sh --runs 10 --save-durable

# Optional: disable WOW metric env injection (observer-effect checks)
./scripts/cross-editor-benchmark.sh --suite benchmark_open_ready --editor Kern --disable-wow-metrics --runs 10

# Optional: force Kern open metric source (auto|wow|probe)
./scripts/cross-editor-benchmark.sh --suite benchmark_open_ready --editor Kern --kern-open-metric-source probe --runs 10

# Optional: Zed fork hook mode (auto|off|required)
./scripts/cross-editor-benchmark.sh --suite benchmark_open_ready --editor Zed --zed-bench-hook auto --runs 10

# Observer-effect report (instrumentation enabled vs disabled)
./scripts/observer-effect-benchmark.sh 10 test-fixtures/cross-editor-benchmark.md
# (script forces --kern-open-metric-source probe for both variants)
```

#### Phase 2: Swift CLI core runner

```bash
# Build once
cd scripts/kern-bench && swift build -c release && cd ../..

# Run with all editors (default: 30 runs, shuffled order, 3 warmup)
scripts/kern-bench/.build/release/kern-bench --all --verbose

# Run internal suite (Kern-only)
scripts/kern-bench/.build/release/kern-bench --suite wow_internal --editor Kern --verbose

# Specific editor with JSON output
scripts/kern-bench/.build/release/kern-bench --editor "TextEdit" --runs 30 --json results.json

# Quick test (fewer runs)
scripts/kern-bench/.build/release/kern-bench --all --runs 5 --verbose

# Cold starts (requires sudo for purge)
sudo scripts/kern-bench/.build/release/kern-bench --all --cold --runs 30 --json results.json
```

#### Phase 3: Regression Detection

```bash
# Compare baseline vs latest (supports v4 + legacy fallback)
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json

# Custom thresholds
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json \
  --threshold 5 --min-abs-ms 50 --verbose

# JSON output for CI
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json \
  --json regression-report.json

# Enforce cross-editor-only policy for publish/claim comparisons
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json \
  --require-cross-editor

# Stabilization mode (report regressions without failing CI)
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json \
  --report-only
```

## Statistical Methodology

### Measurement Protocol

- **Suite defaults**: 30 measured runs + 3 warmup
- **Core measured UX metrics**: `open_latency_ms`, `typing_latency_ms`, `save_ui_ack_latency_ms`, `quit_latency_ms`
- **Full-fidelity aside metric**: `full_fidelity_end_to_end_latency_ms` (launch → full-fidelity completion proxy)
- **Durable-save probe** (`save_durable_latency_ms`) is opt-in via `--save-durable` (disabled by default for runtime stability/speed)
- **Startup probes**: cold and warm startup sampled independently (not mixed into measured run mode)
- **Interleaved editor order**: editors are shuffled each round to eliminate thermal ordering bias
- **0ms inter-editor cooldown by default** (opt-in via `--inter-editor-delay-ms`)
- **No outlier removal**: raw data is preserved; the slow tail IS the user experience
- **Frame monitor probes are opt-in** (`--enable-frame-monitor`) to keep default suite runtime fast
- **Zed bench hook path**: `--zed-bench-hook auto|off|required` uses fork hook when available, with automatic fallback in `auto`
- **Full-fidelity aside defaults** (`--suite benchmark_full_fidelity`):
  - `--zed-bench-hook required`
  - `--zed-ready-mode styled_stable`
  - `--kern-open-metric-source probe`
- **Zed CLI override**: `KERN_BENCH_ZED_CLI=/abs/path/to/zed-wrapper` lets you route benchmark launches to a forked Zed build without changing roster definitions
- **WOW instrumentation toggle**: `--disable-wow-metrics` allows observer-effect comparison runs
- **Kern open metric source**: `--kern-open-metric-source auto|wow|probe` controls whether Kern open-ready uses WOW-derived phase timings or external probe timing

### Reported Statistics

| Metric | Description |
| --- | --- |
| Median (p50) | Primary comparison metric |
| p25, p75 | Interquartile range |
| p95, p99 | Tail latency |
| Mean, Std Dev, CV% | Distribution shape |
| 95% Bootstrap CI | Confidence interval for the median (10,000 resamples, seeded PRNG) |

Both Swift (kern-bench) and Python (shell script) use **R Type 7 linear interpolation** for percentiles, producing identical results.

### Regression Detection (v4)

- **Primary test**: Mann-Whitney U (non-parametric, no distribution assumptions)
- **Secondary**: Bootstrap 95% CI for difference in medians
- **Regression gate**: `p < 0.05` AND `|median difference| > max(5%, 50ms)`
- Failure-rate deltas are compared per metric and can independently trigger regressions
- Official/Partial policy downgrades are treated as regression signals
- Uses threshold fallback for legacy/sparse reports while preserving min-absolute gate logic

### Environment Requirements

Before any benchmark run:

- [ ] Plugged into AC power (macOS throttles CPU on battery)
- [ ] Close all non-essential apps (browsers, Docker, Spotlight-heavy apps)
- [ ] `pmset -g therm` shows `CPU_Speed_Limit = 100`
- [ ] Do Not Disturb enabled
- [ ] Wait 10+ minutes after boot
- [ ] Same test file for all editors (committed to repo)

## JSON Schema (v4)

```json
{
  "version": 4,
  "tool": "kern-bench",
  "timestamp": "2026-02-19T12:00:00Z",
  "suite": "benchmark",
  "suite_kind": "cross_editor",
  "run_classification": "official",
  "run_quality": "complete",
  "partial_reasons": [],
  "environment": {
    "chip": "Apple M4",
    "macos": "26.2",
    "ram_gb": 24,
    "power": "AC",
    "thermal_pct": 100,
    "thermal_pct_end": 100,
    "screencapture_available": true,
    "accessibility_available": true
  },
  "preflight": {
    "thermal_at_start_ok": true,
    "thermal_throughout_ok": true,
    "roster_complete": true,
    "screen_capture_permission_ok": true,
    "accessibility_permission_ok": true,
    "fixture_hash_recorded": true
  },
  "config": {
    "suite": "benchmark",
    "suite_kind": "cross_editor",
    "suite_intended_usage": "single benchmark comparison",
    "roster_policy": "locked_roster_v1_official_claims_only",
    "file": "test-fixtures/cross-editor-benchmark.md",
    "file_bytes": 18432,
    "file_hash": "<sha256>",
    "mode": "warm",
    "runs": 30,
    "warmup_runs": 3,
    "editor_order": "shuffled"
  },
  "results": [
    {
      "editor": "TextEdit",
      "architecture": "Native AppKit",
      "runs": [
        {
          "run_quality": "complete",
          "open_latency_ms": 322.5,
          "typing_latency_ms": 11.5,
          "save_ui_ack_latency_ms": 75.0,
          "quit_latency_ms": 140.0,
          "window_visible_ms": 245.3,
          "first_paint_ms": 310.1,
          "render_stable_ms": 520.5,
          "memory_phys_mb": 82.3,
          "memory_rss_mb": 95.1,
          "thermal_pct": 100,
          "power": "AC"
        }
      ],
      "stats": {
        "window_visible": {
          "n": 30, "min": 230.0, "max": 295.0,
          "median": 248.0, "mean": 255.0, "std": 18.0,
          "cv_pct": 7.1,
          "p25": 240.0, "p75": 265.0, "iqr": 25.0,
          "p95": 285.0, "p99": 293.0,
          "ci_lower": 242.0, "ci_upper": 258.0
        }
      }
    }
  ]
}
```

## Environment Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `KERN_ENABLE_PERF_TESTS` | `0` | Gate for all performance tests |
| `KERN_PERF_ITERATIONS` | `5` | Override iteration count for all benchmarks |
| `KERN_PERF_RENDER_FULL` | `0` | Bypass char-limit truncation for render tests |
| Various `KERN_PERF_*_CHAR_LIMIT` | per-test | Override truncation limit per benchmark |

## Cross-Editor Benchmark Suite

### Suite Policy

- **Cross-editor suite** (`--suite benchmark`): official external comparison
- **Open-ready aside** (`--suite benchmark_open_ready`): optional open-readiness comparison (defaults to Kern+Zed, large frozen fixture, no save/quit steps)
- **Full-fidelity aside** (`--suite benchmark_full_fidelity`): optional large-fixture full-fidelity completion comparison (defaults to Kern+Zed)
- **Internal suite** (`--suite wow_internal`): Kern-only stage microbenchmark (`suite_kind=internal_microbenchmark`)
- `wow_internal` defaults to the small frozen fixture (`cross-editor-benchmark.md`) for minimum-latency numbers.
- `wow_internal` defaults: 10 measured runs, 0 warmups.
- Legacy aliases (`wow`, `real_use`) map to `benchmark` only
- Lean cross-editor core path: startup/open, save UI ack, quit (typing off by default)
- `wow_internal` reports only in-app stage timings (parse/layout/paint-ready/edit-apply/save-serialize);
  external automation timings (open/save-ui/quit/typing) are excluded from internal-suite metrics.
- Internal summary tables use **min (best)** per metric for quick "fastest achievable" signal;
  full p50/p95/p99 stats remain in detailed output/JSON.
- Durable file-commit save probe is optional (`--save-durable`)
- Locked roster v1 (Official eligibility): **Kern, VS Code, Zed, Sublime Text, TextEdit**
- If any required roster editor or required metric is missing, run is classified **Partial**
- README/social headline claims must use **Official** runs only
- Publish/claim checks must reject `suite_kind=internal_microbenchmark` (use `--require-cross-editor`)
- See execution hardening checklist: `architect/benchmark-v2-execution-checklist.md`

### Artifact Persistence

- Every run writes canonical artifacts to:
  - `benchmark-archive/runs/<timestamp>-benchmark/` or
  - `benchmark-archive/runs/<timestamp>-wow-internal/`
- Required files:
  - `results.json`
  - `results.md`
  - `env.json`

### Tools

| Tool | Resolution | Metrics | Usage |
| --- | --- | --- | --- |
| `scripts/cross-editor-benchmark.sh` | wrapper | suite selection + classification output | Stable public entrypoint (delegates to kern-bench) |
| `scripts/kern-bench/` | ~16ms + action probes | startup/open + type + save + quit + classification | Primary runner |
| `scripts/bench-regression-check.py` | — | Mann-Whitney U, bootstrap CI | Compare baseline vs latest JSON |

### JSON Result History

Store benchmark results in `benchmark-history/` for trend tracking. v4 is the canonical schema; legacy reports remain readable via fallback paths.

### Test Files

| File | Size | Purpose |
| --- | --- | --- |
| `cross-editor-benchmark.md` | ~18KB | GFM-only, content-neutral cross-editor comparison |
| `stress-test.md` | ~24KB | Medium document |
| `mega-stress-test.md` | ~800KB | Large document |
| `native-editor-benchmark.md` | ~3.6MB | Extreme stress test |
