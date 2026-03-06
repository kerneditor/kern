---
title: "feat: Full-fidelity performance optimization and no-hang hardening"
type: feat
date: 2026-03-01
status: draft
owner: kern-editor
---

# feat: Full-fidelity performance optimization and no-hang hardening

## Overview

Kern now meets the open-ready KPI lane, but full-document styled convergence remains too slow on large fixtures and still feels risky under aggressive user interaction.

This plan defines a complete optimization program focused on:

1. preserving full WYSIWYG feature fidelity,
2. eliminating hangs/spinners during scroll/edit interactions,
3. reducing full-fidelity completion latency to competitive levels vs Zed,
4. keeping benchmark methodology trustworthy and reproducible.

## Current Baseline (locked)

As of **March 1, 2026**:

- Open-ready target lane (Kern-only, official 30-run):
  - p50: **217.39ms**
  - p95: **246.49ms**
- Open-ready apples-to-apples (Kern vs Zed, official 30-run, probe-symmetric):
  - Kern p50: **347.05ms**, p95: **386.20ms**
  - Zed p50: **1073.79ms**, p95: **1106.45ms**
- Full-fidelity apples-to-apples (official 10-run):
  - Kern p50: **10327.96ms**
  - Zed p50: **4264.65ms**
- Kern internal (wow_internal, native benchmark fixture, 5-run):
  - `wow_open_ready_latency_ms` p50: **74.47ms**
  - `wow_full_document_fidelity_ready_latency_ms` p50: **9457.65ms**
  - staged promotion parse total dominates tail latency.

## Problem Statement

Full-fidelity completion is slow primarily because staged promotion performs repeated expensive parse work across large chunks, with parse cost dominating total completion time. Main-thread safety fixes improved stability but reduced available concurrency. The result is a fast open-ready experience but long styled-completion tail.

## Goals and Success Criteria

## Primary Goals

- [ ] Maintain open-ready KPI lane:
  - Kern `benchmark_open_ready` (target fixture) p50 <= **500ms** official.
- [ ] Achieve full-fidelity competitive target:
  - Kern `benchmark_full_fidelity` p50 <= **4500ms** official on `native-editor-benchmark.md`.
- [ ] Achieve parity/lead goal:
  - Kern full-fidelity p50 <= Zed full-fidelity p50 + **5%** (official apples-to-apples).
- [ ] No-hang UX guarantee:
  - 0 crashes in soak suite,
  - 0 benchmark stage timeouts in official lanes,
  - no persistent UI stalls (spinner/hang) under scripted scroll/edit stress.

## Secondary Guardrails

- [ ] Preserve complete feature fidelity (no disabling parsing/styling/highlighting/markdown features).
- [ ] Keep regression suites green:
  - `./scripts/test-native-editor.sh`
  - `swift test` in `scripts/kern-bench`
  - `python3 -m pytest scripts/tests/test_bench_regression_check.py`
- [ ] Maintain benchmark claim quality:
  - official classification,
  - required metric coverage,
  - no methodology shortcuts.

## Research Findings to Encode

1. Full-fidelity tail is parse-dominated; apply/layout cost is comparatively small.
2. Promotion slices are currently large by default; parse total scales badly.
3. Adaptive promotion tuning reacts more strongly to apply timing than parse timing.
4. Existing anti-jank/anchor protections are valuable and must stay intact.
5. Benchmark quality policy (official vs partial, event-driven readiness) is already strong and must remain unchanged.

## Scope

## In Scope

- Staged-promotion pipeline improvements in native editor.
- Parse workload shaping and batching strategy.
- Safe concurrency redesign for promotion parse/compute path.
- Parser/import performance work that preserves rendering fidelity.
- Performance-focused tests, stress tests, and benchmark artifacts.

## Out of Scope (for this plan)

- Disabling syntax highlighting/styling/features for normal use.
- Benchmark policy downgrades or “partial” claim shortcuts.
- Replacing the entire editor architecture in one shot.

## Technical Strategy

### Phase 0 — Baseline and Instrumentation Lock

- Freeze benchmark fixtures and commands for this run.
- Expand internal metrics for staged promotion:
  - parse total, parse per-slice p50/p95/p99,
  - slices/run,
  - idle delay/followup debt,
  - stuck-recovery count,
  - cancel/close latency under in-flight work.
- Ensure per-run `extra_metrics` is emitted and consumed in report tooling.

Deliverables:
- baseline report bundle,
- metric dictionary update,
- explicit target dashboard table in markdown.

### Phase 1 — Low-Risk Tail Reduction (Fast Iteration)

1. **Parse-aware slice control**
   - make adaptive tuner parse-latency-first (not apply-first),
   - dynamically shrink slices when parse p95 exceeds budget,
   - quicker grow-back only after stable parse windows.

2. **Chunk sizing policy revision**
   - reduce default micro-step for very large docs,
   - bound catch-up chunk size by parse budget and interaction recency,
   - tighten turbo mode so it does not create giant parse spikes.

3. **Promotion scheduling debt cleanup**
   - reduce unnecessary delay compounding,
   - prefer frequent small promotions over rare giant promotions,
   - keep viewport anchoring stable.

Exit gate:
- >=20% full-fidelity p50 improvement from locked baseline,
- zero regressions in open-ready p50 > +10%.

### Phase 2 — Mid-Risk Parser Workload Optimization

1. **Avoid redundant parse duplication per promotion cycle**
   - reduce old/new dual parsing overhead where possible,
   - cache/retain reusable parse artifacts for adjacent slices,
   - reuse precomputed reference-definition and other line-level metadata.

2. **Inline parser hotspot optimization**
   - reduce repeated allocation patterns in dense inline parsing,
   - benchmark inline parser corpus and enforce time budget targets.

3. **Code-block highlighting cost shaping**
   - keep highlighting fully enabled,
   - prioritize visible/caret-near code blocks,
   - stage deep offscreen highlighting without blocking interactivity.

Exit gate:
- additional >=25% reduction over Phase 1 median full-fidelity,
- correctness/snapshot/spec tests unchanged.

### Phase 3 — Safe Concurrency Upgrade (High Impact)

1. **De-main-thread parse preparation path**
   - move pure markdown analysis/segmentation work off main,
   - keep UI mutations/main-thread attributed application minimal.

2. **Promotion execution model**
   - background compute produces deterministic deltas,
   - main thread applies bounded updates with generation/token guards,
   - strict cancellation on superseded generations.

3. **Crash-safety hardening**
   - no actor/isolation violations,
   - queue assertions added in debug,
   - kill-switch/fallback path retained.

Exit gate:
- no crash in 100-cycle stress open/scroll/edit loop,
- full-fidelity p50 <= 6000ms on official lane.

### Phase 4 — Final Competitive Optimization Pass

- tune with apples-to-apples full-fidelity benchmarks vs Zed,
- optimize remaining tail contributors in descending ROI order,
- lock thresholds and freeze release candidate.

Exit gate:
- full-fidelity target achieved (primary goals section),
- all tests and official benchmarks green.

## Test and Validation Plan

## Unit / Integration

- Extend viewport/promotion tests:
  - parse-latency budget reactions,
  - no-starvation convergence,
  - anchor stability during style promotion,
  - edit/save/quit with in-flight promotions.
- Extend recorder tests:
  - aux sample stress/coalescing,
  - correctness of deferred percentile aggregation.
- Extend benchmark schema tests:
  - per-run extra metrics encode/decode,
  - backward compatibility behavior.

## Performance / Stress

- Add staged slice-size matrix test harness:
  - 64k / 128k / 256k / 512k slices on large fixture.
- Add full-fidelity convergence perf tests with explicit metric gates.
- Add soak runs:
  - repeated open/scroll/edit/close cycles,
  - long scrollbar drag stress,
  - no-hang assertions + crash report checks.

## Benchmark Matrix (required)

- `benchmark_open_ready` (target fixture): Kern-only official 30-run.
- `benchmark_open_ready` apples-to-apples (Kern/Zed): official 30-run.
- `benchmark_full_fidelity` apples-to-apples (Kern/Zed): official 10-run per iteration, 30-run final sign-off.
- `wow_internal` Kern-only: 10-run per major phase for root-cause attribution.

## Regression Policy

Any of the following is an automatic rollback trigger for the current batch:

- crash introduced,
- stage timeout increase,
- open-ready p50 regression >10%,
- style/snapshot/spec conformance regressions,
- measurable jump/jank regression in scroll stability tests.

## Risk Register

1. **Concurrency regression risk** (actor isolation / queue misuse)  
   Mitigation: staged rollout + strict tokenization + fallback path.

2. **Feature fidelity regression risk**  
   Mitigation: exhaustive snapshot + spec suites at every phase gate.

3. **Observer-effect / measurement distortion**  
   Mitigation: keep instrumentation overhead tracked and separated.

4. **Over-tuning to one fixture**  
   Mitigation: include target + native large fixture + mixed stress fixture lanes.

## File/Component Focus Map

- `KernApp/Sources/Editor/NativeEditorViewController.swift`
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernApp/Sources/Editor/WowInternalMetricsRecorder.swift`
- `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift`
- `scripts/kern-bench/Sources/KernBench/JSONReport.swift`
- `scripts/cross-editor-benchmark.sh`

Test focus:

- `KernTests/NativeEditorInitialViewportTests.swift`
- `KernTests/NativeMarkdownCodecPerformanceTests.swift`
- `KernTests/NativeEditorMegaStressPerformanceTests.swift`
- `KernTests/WowInternalMetricsRecorderTests.swift`
- `scripts/kern-bench/Tests/KernBenchTests/WowMetricsSelectionTests.swift`
- `scripts/kern-bench/Tests/KernBenchTests/JSONReportSchemaTests.swift`

## Execution Checklist

- [x] Phase 0 baseline lock complete
- [x] Phase 1 low-risk tail reduction complete
- [x] Phase 2 parser workload optimization complete
- [ ] Phase 3 safe concurrency upgrade complete
- [x] Phase 4 competitive final pass complete
- [x] Full tests green
- [ ] Official benchmark targets met
- [x] Final sign-off report generated

### Latest measured status (2026-03-01)

- `benchmark_open_ready` (Kern-only, official 30-run, `native-editor-benchmark.md`)
  - p50 **305.31ms** (target <= 500ms ✅)
- `benchmark_open_ready` apples-to-apples (Kern vs Zed, official 30-run)
  - Kern p50 **391.99ms**
  - Zed p50 **3419.76ms**
- `benchmark_full_fidelity` apples-to-apples (Kern vs Zed, official 10-run)
  - Kern p50 **4175.83ms** (target <= 4500ms ✅)
  - Zed p50 **3549.55ms** (parity goal pending)

## References (internal)

- `docs/solutions/performance-issues/wow-internal-measurement-learnings.md`
- `docs/solutions/patterns/critical-patterns.md`
- `docs/optimization/2026-02-23-regression-triage-loop.md`
- `docs/optimization/2026-02-23-kern-optimization-venue-backlog.md`
- `docs/optimization/2026-02-25-phase0-baseline.md`
- `docs/optimization/2026-02-25-scroll-jump-frame-analysis.md`
