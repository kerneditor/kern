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
```

### Cross-Editor Comparison

#### Phase 1: Shell script (window detection, ~50ms resolution)

```bash
# All detected editors, 30 runs, warm
./scripts/cross-editor-benchmark.sh

# Specific editors, cold starts, JSON output
./scripts/cross-editor-benchmark.sh --editors "Kern,Zed,TextEdit" --cold --runs 30 --json results.json

# Fewer runs for quick comparison
./scripts/cross-editor-benchmark.sh --runs 5 --verbose
```

#### Phase 2: Swift CLI (ScreenCaptureKit, ~16ms resolution)

```bash
# Build once
cd scripts/kern-bench && swift build -c release && cd ../..

# Run with all editors (default: 30 runs, shuffled order, 3 warmup)
scripts/kern-bench/.build/release/kern-bench --all --verbose

# Specific editor with JSON output
scripts/kern-bench/.build/release/kern-bench --editor "TextEdit" --runs 30 --json results.json

# Quick test (fewer runs)
scripts/kern-bench/.build/release/kern-bench --all --runs 5 --verbose

# Cold starts (requires sudo for purge)
sudo scripts/kern-bench/.build/release/kern-bench --all --cold --runs 30 --json results.json
```

#### Phase 3: Regression Detection

```bash
# Compare baseline vs latest (uses Mann-Whitney U for v3 JSON)
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json

# Custom thresholds
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json \
  --threshold 5 --min-abs-ms 50 --verbose

# JSON output for CI
python3 scripts/bench-regression-check.py --baseline baseline.json --latest latest.json \
  --json regression-report.json
```

## Statistical Methodology

### Measurement Protocol

- **Default: 30 runs** per editor (minimum for reliable percentile estimates)
- **3 warmup runs** (discarded, not counted)
- **Interleaved editor order**: editors are shuffled each round to eliminate thermal ordering bias
- **5-second cooldown** between editors within each round
- **No outlier removal**: raw data is preserved; the slow tail IS the user experience

### Reported Statistics

| Metric | Description |
| --- | --- |
| Median (p50) | Primary comparison metric |
| p25, p75 | Interquartile range |
| p95, p99 | Tail latency |
| Mean, Std Dev, CV% | Distribution shape |
| 95% Bootstrap CI | Confidence interval for the median (10,000 resamples, seeded PRNG) |

Both Swift (kern-bench) and Python (shell script) use **R Type 7 linear interpolation** for percentiles, producing identical results.

### Regression Detection (v3)

- **Primary test**: Mann-Whitney U (non-parametric, no distribution assumptions)
- **Secondary**: Bootstrap 95% CI for difference in medians
- **Regression gate**: `p < 0.05` AND `|median difference| > max(5%, 50ms)`
- Requires v3 JSON with raw run data. Falls back to legacy threshold check for v1/v2.

### Environment Requirements

Before any benchmark run:

- [ ] Plugged into AC power (macOS throttles CPU on battery)
- [ ] Close all non-essential apps (browsers, Docker, Spotlight-heavy apps)
- [ ] `pmset -g therm` shows `CPU_Speed_Limit = 100`
- [ ] Do Not Disturb enabled
- [ ] Wait 10+ minutes after boot
- [ ] Same test file for all editors (committed to repo)
- [ ] Screen Recording permission granted (for Phase 2 ScreenCaptureKit)

## JSON Schema (v3)

```json
{
  "version": 3,
  "tool": "kern-bench",
  "timestamp": "2026-02-19T12:00:00Z",
  "environment": {
    "chip": "Apple M4",
    "macos": "26.2",
    "ram_gb": 24,
    "power": "AC",
    "thermal_pct": 100,
    "thermal_pct_end": 100,
    "screencapture_available": true
  },
  "config": {
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

### Tools

| Tool | Resolution | Metrics | Usage |
| --- | --- | --- | --- |
| `scripts/cross-editor-benchmark.sh` | ~50ms | Window visible, RSS, phys_footprint | Quick comparison, bash 3.2 compatible |
| `scripts/kern-bench/` | ~16ms | Window visible, first paint, render stable, memory | Precise frame-level detection via ScreenCaptureKit |
| `scripts/bench-regression-check.py` | — | Mann-Whitney U, bootstrap CI | Compare baseline vs latest JSON |

### JSON Result History

Store benchmark results in `benchmark-history/` for trend tracking. Only v3 JSON is supported for regression detection with Mann-Whitney U.

### Test Files

| File | Size | Purpose |
| --- | --- | --- |
| `cross-editor-benchmark.md` | ~18KB | GFM-only, content-neutral cross-editor comparison |
| `stress-test.md` | ~24KB | Medium document |
| `mega-stress-test.md` | ~800KB | Large document |
| `native-editor-benchmark.md` | ~3.6MB | Extreme stress test |
