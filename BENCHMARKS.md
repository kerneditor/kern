# Benchmark Suite (Native Editor Prototype)

This repo contains two kinds of benchmarks:

1. **Engine-level benchmarks** (fast, deterministic, no UI automation):
   - Markdown import/export throughput and memory
   - TextKit render cost for large `.md` files
2. **App-level benchmarks** (slower, closer to real UX; may require UI automation):
   - Cold start + file open + first render
   - Scroll responsiveness on huge documents
   - Save latency (flush + write)

The goal is to make performance comparisons reproducible between:
- Kern **Native TextKit** prototype
- Kern **WebKit** editor (current)
- External editors (Electron and native)

## Datasets

Primary benchmark files (committed so results are comparable across machines):
- `test-fixtures/native-editor-benchmark.md` (large, supported subset)
- `test-fixtures/stress-test.md` (medium)
- `test-fixtures/ultimate-stress-test.md` (permutation-dense canonical source)
- `test-fixtures/mega-stress-test.md` (very large, includes embedded permutation appendix)

Fixture maintenance:
- `scripts/gen_ultimate_stress_test.py`
- `scripts/sync_mega_permutation_appendix.py`

Guideline:
- Use the same file(s) for all editors.
- Record whether the run is **cold** (after reboot / app not in memory) or **warm** (second run).

## Engine-Level (Recommended)

These benchmarks run as XCTest performance tests, so they do not require UI automation permissions.

### Run (Fast, Non-UI)

```bash
./scripts/bench-native-editor.sh
```

### What It Runs

- `KernTests/NativeMarkdownCodecPerformanceTests.swift`
  - Import + export `test-fixtures/native-editor-benchmark.md`
- `KernTests/NativeEditorRenderPerformanceTests.swift`
  - Render `test-fixtures/native-editor-benchmark.md` into a `NativeEditorViewController` and force layout
- `KernTests/NativeEditorMegaStressPerformanceTests.swift`
  - Render `stress-test.md`, `ultimate-stress-test.md`, and `mega-stress-test.md`
  - Scroll jumps on `mega-stress-test.md`
  - Incremental live typing benchmark
  - Full char-by-char typing of `ultimate-stress-test.md` and `mega-stress-test.md`
  - Interleaved action-burst typing + export on `ultimate-stress-test.md` and `mega-stress-test.md`

Fast subset:

```bash
KERN_PERF_QUICK=1 ./scripts/bench-native-editor.sh

Ultra exhaustive (non-UI, mega all-profile matrix + shardable):

```bash
./scripts/test-native-editor.sh --unit-only --exhaustive --ultra
```

Ultra full (all mega profiles/programs, very slow):

```bash
./scripts/test-native-editor.sh --unit-only --exhaustive --ultra-full
```
```

Artifacts are written under `bench-results/native-editor/<timestamp>/` as `.xcresult` bundles plus logs.

## App-Level (Design)

These are the benchmarks that matter most to users, but they are harder to make foolproof without
app-level instrumentation.

Planned harness (not implemented yet):
- `KERN_BENCHMARK_MODE=1`
  - app opens a file passed on argv
  - records JSON metrics to a specified path
  - quits automatically
- `hyperfine` wrapper scripts to run N cold/warm iterations and summarize results

Suggested metrics:
- `launch_ms`: process start -> first window visible
- `open_ms`: file open -> editor content rendered
- `export_ms`: current document -> `.md` string produced
- `save_ms`: `Cmd+S` -> write complete
- `rss_mb`: resident set size after open + after 30s idle

## External Editor Comparisons (Design)

Baseline comparisons that are actually measurable without deep instrumentation:
- Cold start time to open a file (AppleScript-driven open + wait for front window)
- RSS after file open
- Manual scroll test (qualitative, but repeatable if done with the same trackpad gesture)

Notes:
- Many Electron apps do significant background work; record CPU spikes in Activity Monitor if needed.
- Some editors lazily render; always wait a fixed “settle time” (ex: 5s) before measuring memory.
