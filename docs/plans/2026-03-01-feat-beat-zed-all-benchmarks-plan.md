---
title: "feat: Beat Zed on benchmark stability and full-fidelity performance"
type: feat
date: 2026-03-01
status: in_progress
owner: kern-editor
---

# feat: Beat Zed on benchmark stability and full-fidelity performance

## North Star

- Beat Zed on official apples-to-apples benchmark lanes while preserving full WYSIWYG fidelity.
- Keep Kern open-ready p50 <= 500ms on benchmark fixture.
- Eliminate hangs/spinners during large-file scrolling and staged styling catch-up.

## Current measured baseline (latest official runs in this iteration)

> Updated: **March 2, 2026**

### Open-ready apples-to-apples (Kern vs Zed)
- Run: `benchmark-archive/runs/20260301-160801-benchmark-open-ready`
- Kern open p50: **410.98ms**
- Zed open p50: **2913.54ms**
- Classification: **official**

### Full-fidelity apples-to-apples (Kern vs Zed)
- Run: `benchmark-archive/runs/20260301-160835-benchmark-full-fidelity` (10-run)
- Kern full-fidelity end-to-end p50: **3558.02ms**
- Zed full-fidelity end-to-end p50: **3316.84ms**
- Gap: Kern is **~7.3% slower** at p50
- Classification: **official**

### Release-app benchmark profile (methodology hardening)
- Run: `benchmark-archive/runs/20260302-073502-benchmark-full-fidelity` (official 5-run)
- Kern full-fidelity end-to-end p50: **2408.89ms**
- Zed full-fidelity end-to-end p50: **1693.37ms**
- Open-ready remains strong (Kern p50 **235.12ms**)
- Classification: **official**

### Latest auto-release wrapper verification
- Full-fidelity run: `benchmark-archive/runs/20260302-074516-benchmark-full-fidelity` (official 3-run)
  - Kern p50 **2255.22ms**
  - Zed p50 **1557.82ms**
- Open-ready run: `benchmark-archive/runs/20260302-074552-benchmark-open-ready` (official 3-run)
  - Kern p50 **177.03ms**
  - Zed p50 **1217.05ms**

### Latest official validation runs (March 2, 2026)
- Full-fidelity run: `benchmark-archive/runs/20260302-075019-benchmark-full-fidelity` (official 5-run)
  - Kern p50 **2242.90ms**
  - Zed p50 **1551.05ms**
  - Kern staged-promotion parse total remains dominant (~**1.89s** p50)
- Open-ready run: `benchmark-archive/runs/20260302-075617-benchmark-open-ready` (official 5-run)
  - Kern p50 **170.24ms**
  - Zed p50 **1203.08ms**
  - Target status: **PASS** (Kern <= 500ms)

### Deterministic full-fidelity profile run (March 2, 2026)
- Run: `benchmark-archive/runs/20260302-080256-benchmark-full-fidelity` (official 5-run, `--profile full-fidelity-stable`)
  - Kern p50 **2192.05ms**
  - Zed p50 **1553.84ms**
  - Kern variance improved materially:
    - `p95/p50 = 1.003`
    - `CV = 0.80%`
  - Remaining blocker: absolute p50 gap (**~638ms**) vs Zed.

### Latest optimization validation (March 2, 2026)
- Run: `benchmark-archive/runs/20260302-091246-benchmark-full-fidelity` (official 3-run, stable profile)
  - Kern p50 **2338.24ms**
  - Zed p50 **1678.92ms**
  - Variance still good (`p95/p50 ≈ 1.006`, low CV), but absolute gap persists.
- Open-ready check: `benchmark-archive/runs/20260302-091334-benchmark-open-ready`
  - Kern p50 **210.40ms**
  - Zed p50 **1358.20ms**
  - Target status remains **PASS** (<= 500ms).

### Full-fidelity volatility observed (same codepath, different official runs)
- `benchmark-archive/runs/20260301-160711-benchmark-full-fidelity` → Kern p50 **4605.08ms**
- `benchmark-archive/runs/20260301-162101-benchmark-full-fidelity` → Kern p50 **6433.70ms**
- Zed also varies, but Kern variance remains too large for reliable “beat Zed every run” claims.

## Research summary (repo + benchmark artifacts)

1. **Dominant cost is staged promotion parse total** on large docs.
2. **Inter-run variance is large**; outcomes depend strongly on promotion chunk behavior and machine state.
3. **Fixed chunking can regress badly** under some conditions; adaptive behavior helps median but still has tail instability.
4. **Scroll lag risk correlates with promotion work during/after user scrolling**, not with open-ready parse itself.
5. **Apples-to-apples harness is valid for forked Zed** (hooked full-fidelity mode + required hook in full-fidelity suite), but benchmark stability controls need tightening.
6. **Benchmark build profile had major impact**: benchmarking installed Debug app inflated latency and variance versus explicit Release app path.

## Adversarial review (failure modes)

### A. “Looks fast in one run, regresses in next run”
- Risk: overfitting chunk size to one thermal/power state.
- Mitigation:
  - require 10-run official confirmation for promotion parameter changes,
  - record and compare p95/p99 + CV, not only p50.

### B. “Open-ready stays fast but app hangs during scroll”
- Risk: staged promotions fire near active scroll and block interactivity.
- Mitigation:
  - hard gating during live scroll,
  - stricter quiet-period scheduling before promotion resume,
  - dedicated scroll-jank regression tests.

### C. “Benchmark says ready but user still sees delayed styling”
- Risk: semantic mismatch between measured readiness and perceived readiness.
- Mitigation:
  - keep full-fidelity definition explicit in benchmark docs,
  - add supplemental perceived-readiness probes for visibility (non-claim metrics).

### D. “Big wins from unsafe threading cause crashes”
- Risk: actor/isolation violations when moving parse work off main.
- Mitigation:
  - no unsafe actor bypass in production path without dedicated stress/crash gates.

## Execution phases

## Phase 0 — Lock reproducible methodology
- [x] Confirm forked Zed CLI enforcement in benchmark wrapper.
- [x] Run official open-ready and full-fidelity apples-to-apples baselines.
- [x] Capture run archive references in plan.
- [x] Auto-resolve Kern benchmark app to Release build when available (wrapper default).

## Phase 1 — Low-risk staged-promotion tuning (implemented)
- [x] Reduce promotion context window to cut repeated parse overhead.
- [x] Raise default viewport micro-step to improve idle convergence.
- [x] Cap turbo micro-step to avoid pathological huge parse spikes.
- [x] Add live-scroll guard to defer promotions while user is actively scrolling.
- [x] Add idle-only boosted micro-step behavior.
- [x] Make adaptive tuner parse-aware (not apply-only).

Files:
- `KernApp/Sources/Editor/NativeEditorViewController.swift`

## Phase 2 — Stability hardening + tail variance reduction
- [x] Add deterministic benchmark mode knobs (documented profile) to reduce variance.
- [x] Add automated variance report gate (`p95/p50`, CV thresholds) for full-fidelity lane.
- [x] Add production-path guard preventing promotion scheduling during active live scroll.
- [x] Add focused regression assertion covering “no promotion while live scroll active” path.

## Phase 3 — Parser-tail optimization (without feature disablement)
- [ ] Reduce redundant prelude parse misses (cache hit-rate improvement plan).
- [ ] Optimize context window behavior with correctness-backed thresholds.
- [x] Add targeted parser microbench for dense inline-heavy slices.

## Phase 4 — Final sign-off
- [ ] Official 30-run open-ready: Kern p50 <= 500ms.
- [ ] Official 10-run (and final 30-run) full-fidelity apples-to-apples.
- [ ] Verify all tests green and app reinstalled for manual validation.

## Validation checklist

- [x] `./scripts/test-native-editor.sh`
- [x] `(cd scripts/kern-bench && swift test)`
- [x] `benchmark_open_ready` official run after changes
- [x] `benchmark_full_fidelity` official run after changes
- [x] Release-app profile benchmark verification
- [x] Rebuilt Release app and reinstalled `/Users/aaaaa/Applications/Kern.app`
- [ ] 30-run final sign-off package (pending)
- [ ] Variance gate passing across repeated full-fidelity official runs (pending)

## Execution log (this iteration)

1. Implemented Phase 1 tuning in `NativeEditorViewController`.
2. Ran full native test suite — pass.
3. Ran kern-bench Swift tests — pass.
4. Ran multiple official apples-to-apples and wow-internal validation runs.
5. Achieved major median improvement in full-fidelity vs earlier degraded baselines, but not yet consistent Zed p50 lead in official lane.
6. Confirmed that benchmark volatility is now a primary blocker to trustworthy “always-beat-Zed” sign-off.
7. Updated benchmark wrapper to auto-select a Release Kern app bundle (when available) for more production-representative runs.
8. Added live-scroll regression test (`testStagedPromotionDefersWhileLiveScrollAndResumesAfterEnd`) and fixed actor-isolation compile issue via static metrics loader.
9. Added `scripts/benchmark-variance-gate.py` and documented gate usage in `BENCHMARKS.md`.
10. Added `--profile full-fidelity-stable` benchmark wrapper mode; validated lower variance on official 5-run lane.
11. Added staged-slice parser microbench (`testStagedPromotionSliceParseBenchmark`) and captured scaling data in `benchmark-archive/staged-slice-benchmark/20260302-170912-staged-slice-benchmark.md` (roughly linear parse cost: ~52ms @128k, ~442ms @1M).
12. Added newline-attributed-string reuse inside `importMarkdown` and validated no regressions; stability held but full-fidelity p50 leadership gap remains.

## Next concrete steps

1. Add deterministic benchmark profile + variance gate.
2. Land live-scroll gating regression tests.
3. Run targeted parser-tail optimization pass (single-parse boundary mapping strategy) and re-benchmark with 10-run official iterations.
4. Execute final 30-run sign-off once p50 and variance gates hold.
5. Execute focused Phase 3 plan: `docs/plans/2026-03-02-feat-full-fidelity-parser-throughput-phase3-plan.md`.
