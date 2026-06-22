# Native Rich Block Baseline Benchmark — 2026-06-21

## Scope

This is a diagnostic baseline for Kern's current native editor, math, Mermaid,
and optional official Mermaid cache-hit rendering paths.

This is **not** a final renderer-selection benchmark. It used the quick lane and
3 iterations on a machine that still had unrelated load. Treat it as a harness
and regression-smoke run until a quiet-machine run with more iterations is
available.

## Command

```bash
KERN_PERF_ITERATIONS=3 KERN_MERMAID_BENCH_RUNS=3 ./scripts/bench-native-editor.sh --quick --include-mermaid
```

The benchmark script recorded the run as:

```bash
DERIVED_DATA_PATH=/tmp/kern-derived-data-bench KERN_PERF_ITERATIONS=3 ./scripts/bench-native-editor.sh --quick --include-mermaid
```

## Result

Latest final-tree artifact: `bench-results/native-editor/20260621-224301/`.

- Xcode result: passed.
- XCTest selection: 6 performance tests, 0 failures.
- Parsed performance metrics: 12.
- Git state: `codex/kern-release-design-benchmark-readiness` at `7d0553c`, dirty.
- Process hygiene check after success: no matching Kern, KernTextKitTests, Mermaid
  CLI, npx, Chromium, or Kern xcodebuild processes remained.
- Baseline comparison: 2 timing regressions were flagged against the immediately
  previous same-session quick run. Because load was still high and the baseline
  was itself noisy, this is a smoke signal, not a product regression conclusion.

## Local artifacts

Raw benchmark artifacts are intentionally ignored by Git.

- Native benchmark summary: `bench-results/native-editor/20260621-224301/summary.md`
- Native benchmark metrics: `bench-results/native-editor/20260621-224301/metrics-summary.json`
- Native benchmark archive: `benchmark-archive/native-editor/20260621-224301/`
- Mermaid heavy fixture report: `benchmark-archive/mermaid-render-modes/20260621-224452-mermaid-render-modes.md`
- Mermaid smaller fixture report: `benchmark-archive/mermaid-render-modes/20260621-224457-mermaid-render-modes.md`

## Current native benchmark metrics

| Test | Metric | Average | p95 sample | RSD | Samples |
|---|---|---:|---:|---:|---|
| Render ultimate stress | Clock | 0.050 s | 0.052 s | 3.60% | `[0.048, 0.048, 0.052]` |
| Render ultimate stress | Peak physical memory | 33.8 MB | 34.3 MB | 1.47% | `[33964.944, 34653.072, 35210.128]` kB |
| Typing ultimate stress | Clock | 9.479 s | 9.815 s | 3.15% | `[9.125, 9.855, 9.457]` |
| Typing ultimate stress | Peak physical memory | 98.2 MB | 108.4 MB | 8.68% | `[112559.136, 91997.216, 97207.328]` kB |
| Render benchmark file | Clock | 0.077 s | 0.078 s | 1.03% | `[0.079, 0.077, 0.077]` |
| Render benchmark file | Peak physical memory | 111.4 MB | 111.7 MB | 0.28% | `[113656.888, 114033.720, 114443.320]` kB |
| Import/export benchmark file | Clock | 10.503 s | 11.239 s | 6.49% | `[11.316, 9.648, 10.546]` |
| Import/export benchmark file | Peak physical memory | 189.2 MB | 190.7 MB | 1.12% | `[190661.880, 195167.480, 195331.320]` kB |

Memory delta metrics from XCTest include noisy/negative samples and should not
be used for decisions from this run. Peak physical memory is the more useful
memory signal here.

## Mermaid mode microbenchmarks

Two Mermaid mode benchmark tests ran because both
`NativeMarkdownCodecPerformanceTests` and `NativeMermaidRenderModeBenchmarkTests`
include Mermaid matrix coverage.

### Heavy generated fixture

| Mode | p50 ms | p95 ms | Mean ms | Effective modes |
|---|---:|---:|---:|---|
| `rich` | 204.18 | 219.62 | 206.39 | rich:360 |
| `ascii` | 250.56 | 253.37 | 247.06 | ascii:360 |
| `auto` | 239.82 | 244.98 | 236.65 | ascii:60, rich:300 |

Interpretation: rich remains the right default for this fixture. ASCII is slower
in this quick run; auto is also slower because it only switches a small subset.

### Smaller generated fixture

| Mode | p50 ms | p95 ms | Mean ms | Effective modes |
|---|---:|---:|---:|---|
| `rich` | 74.99 | 77.17 | 75.50 | rich:300 |
| `ascii` | 103.39 | 110.75 | 105.33 | ascii:300 |
| `auto` | 88.87 | 88.88 | 86.56 | rich:300 |
| `officialExternalDisabledFallback` | 85.60 | 87.90 | 85.79 | rich:300 |
| `officialExternalCacheHit` | 67.65 | 67.82 | 67.46 | rich:300 |

Interpretation: official cache hit is competitive in this microbenchmark, but it
uses a fake pre-seeded renderer cache and should not be generalized to cold
external rendering. ASCII and auto should not be claimed as faster from this run.

## Interpretation

- The benchmark harness is working: it produced XCTest result bundles, parsed
  metrics, summaries, archives, and process hygiene evidence.
- The optional official external mode is correctly measured as disabled fallback
  and cache-hit paths; cold external renderer timing still needs a separate
  explicit benchmark.
- `rich` should remain the default Mermaid mode.
- `officialExternal` is suitable as an optional fidelity mode when users configure
  or pre-seed the renderer/cache.
- `auto` needs threshold tuning before it should be used as a performance claim.
- Timing remains noisy enough that final renderer-selection decisions need a
  quiet-machine run with 7-15 iterations.

## Follow-up gates

1. Re-run the same baseline on a quiet machine with at least 7 to 15 iterations.
2. Add a stable baseline-selection policy so quick same-session runs do not
   overinterpret noise from the immediately previous run.
3. Add explicit official cold-process and warm-process benchmarks if we want to
   make claims about first render latency.
4. Run iosMath and SwiftMath candidate benchmarks against the rich-block corpus
   and compare visual/contact-sheet quality before choosing a math renderer.
