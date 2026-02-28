---
title: feat: Add Kern internal wow microbenchmark suite
type: feat
date: 2026-02-22
---

# ✨ feat: Add Kern internal wow microbenchmark suite

## Overview

Add a **Kern-only internal microbenchmark suite** (`wow_internal`) for pure engine timing, while keeping the existing cross-editor benchmark as the user-flow benchmark.

This plan is revised after technical review to remove ambiguity and lock down:

- deterministic stage boundaries,
- schema/version compatibility,
- regression thresholds,
- artifact storage,
- CI/publishing guardrails.

## Problem Statement / Motivation

Current cross-editor timings are valuable for real UX comparison, but they include external orchestration overhead (launch/focus/automation/OS jitter). We need an internal signal for tight engine optimization loops.

Goal: make stage-level regressions obvious without polluting cross-editor claim pipelines.

## Locked Decisions (Resolved from review)

1. **Single runner path first (simplicity):**
   - Reuse existing `scripts/kern-bench` runner.
   - Add a new suite id `wow_internal` there.
   - No separate shell runner in first iteration.

2. **Schema/versioning policy:**
   - Keep report schema at **v4-compatible** shape.
   - Add new optional fields for internal microbenchmarks (`suite_kind`, internal stage stats blocks).
   - Existing consumers must continue to parse old reports without breakage.

3. **Artifact location:**
   - Persist to:
     - `benchmark-archive/runs/<timestamp>-wow-internal/`
   - Required files per run:
     - `results.json`
     - `results.md`
     - `env.json` (os/chip/thermal/power/tool versions/fixture hash)

4. **Regression policy (initial):**
   - For each internal stage metric:
     - Mann-Whitney U `p < 0.05`
     - and `|median delta| > max(7%, 2.0ms)`
   - Failure/timeout-rate increase > `1.0pp` is regression.
   - Default mode: **report-only in CI** for a stabilization period; can be promoted to blocking.

5. **Cross-editor claim isolation (hard guardrail):**
   - Publishing/summary scripts must reject `suite_kind=internal_microbenchmark` for external/public comparison tables.
   - Cross-editor claim scripts require:
     - suite kind `cross_editor`,
     - roster-complete official classification.

## Scope

### In scope

- Add `wow_internal` suite in `kern-bench`.
- Measure 5 internal stages for Kern only.
- Add deterministic boundary definitions and failure semantics.
- Extend regression checker for new stage metrics.
- Add doc updates and guardrails to prevent metric misuse.

### Out of scope

- Replacing external cross-editor benchmark methodology.
- Using internal metrics for cross-editor performance claims.
- Non-benchmark product refactors.

## Technical Approach

### 1) Stage Boundary Contract (deterministic)

Define and freeze boundaries for each stage:

| Stage | Metric Key | Start | End | Timeout/Failure Rule |
|---|---|---|---|---|
| Parse | `wow_parse_latency_ms` | parse request accepted | AST/model parse complete callback | timeout => null + `parse_timeout` |
| Layout | `wow_layout_latency_ms` | layout invalidation queued | layout pass completion signal | timeout => null + `layout_timeout` |
| Paint-ready | `wow_paint_ready_latency_ms` | paint request queued | first paint-ready signal (not render-stable) | timeout => null + `paint_ready_timeout` |
| Edit-apply | `wow_edit_apply_latency_ms` | deterministic edit op dispatched | model + view apply complete | timeout => null + `edit_apply_timeout` |
| Save-serialize | `wow_save_serialize_latency_ms` | save serialize start | serialization complete (UI/fsync excluded) | timeout => null + `save_serialize_timeout` |

Boundary notes:

- All timers use monotonic clock.
- Every interval must have begin/end or explicit failure reason.
- If any stage lacks signal, run is degraded and reasons are persisted.

### 2) Instrumentation implementation

Files:

- `KernApp/Sources/Performance/WowStageTimer.swift`
- `KernApp/Sources/Performance/WowSignpostRecorder.swift`

Requirements:

- no-op when `wow_internal` suite is not active,
- begin/end pair enforcement,
- optional signpost + required clock fallback,
- per-stage failure reason capture.

### 3) Suite integration (reuse existing runner)

Files:

- `scripts/kern-bench/Sources/KernBench/SuiteDefinition.swift`
- `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift`

Add:

- suite id: `wow_internal`,
- Kern-only editor selection validation,
- warmup + measured run defaults,
- required metric list for internal stage keys.

### 4) Reporting contract (v4-compatible extension)

File:

- `scripts/kern-bench/Sources/KernBench/JSONReport.swift`

Add optional fields:

- `suite_kind`: `cross_editor | internal_microbenchmark`
- per-stage internal stats blocks
- instrumentation coverage flag

Compatibility rule:

- old reports remain parseable,
- new fields are optional and ignored by legacy readers.

### 5) Regression checker update

Files:

- `scripts/bench-regression-check.py`
- `scripts/tests/test_bench_regression_check.py`

Add:

- new metric keys for `wow_*_latency_ms`,
- threshold policy from locked decisions,
- null/failure handling parity with existing metrics,
- report-only mode toggle for CI stabilization.

### 6) Policy and publication guardrails

Files:

- `BENCHMARKS.md`
- publish/report scripts that consume benchmark JSON (if any under `scripts/`)

Add explicit enforcement:

- block cross-editor publication if `suite_kind != cross_editor`,
- block publication if classification is partial.

## Implementation Phases

### Phase 1 — Contract + smoke skeleton (must be small)

Files:

- `scripts/kern-bench/Sources/KernBench/SuiteDefinition.swift`
- `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift`
- `scripts/kern-bench/Sources/KernBench/JSONReport.swift`

Tasks:

- [x] add `wow_internal` suite routing
- [x] emit placeholder stage metrics with required schema fields
- [x] persist artifacts to canonical path.

Success criteria:

- `wow_internal` runs and emits parseable v4-compatible JSON.

### Phase 2 — Real instrumentation + failure semantics

Files:

- `KernApp/Sources/Performance/WowStageTimer.swift`
- `KernApp/Sources/Performance/WowSignpostRecorder.swift`
- `KernApp/Tests/Performance/WowInternalSuiteTests.swift`

Tasks:

- [x] wire all 5 deterministic stage boundaries
- [ ] implement per-stage timeout/failure reasons
- [x] add observer-effect check (instrumented vs uninstrumented baseline).

Success criteria:

- repeated local runs produce stable stage metrics and explicit failures when injected.

### Phase 3 — Regression + policy enforcement + docs

Files:

- `scripts/bench-regression-check.py`
- `scripts/tests/test_bench_regression_check.py`
- `BENCHMARKS.md`
- `docs/solutions/performance-issues/wow-internal-measurement-learnings.md`
- `docs/solutions/patterns/critical-patterns.md`

Tasks:

- [x] add regression logic for internal stage keys
- [x] add publication guardrails for suite-kind isolation
- [x] document interpretation and claim policy
- [x] capture initial baseline artifacts + environment metadata.

Success criteria:

- regression reports work for `wow_internal`,
- external claim scripts cannot consume internal suite artifacts.

## Testing Plan (explicit)

### Unit / integration tests

- [x] suite parsing test for `wow_internal`.
- [x] JSON encode/decode compatibility tests with and without new optional fields.
- [x] regression checker fixture tests for each internal stage key.
- [x] classification tests for missing required stage metrics.

### Fault-injection tests

- [ ] synthetic timeout test for each stage (`*_timeout` reason asserted).
- [ ] synthetic instrumentation-missing test (`instrumentation_missing` asserted).
- [x] publish guardrail test (reject internal suite for cross-editor table generation).

### Smoke tests

- [x] 1-run local smoke artifact generation.
- [x] 10-run unattended smoke with zero hangs.

## Acceptance Criteria

### Functional

- [x] `wow_internal` runs Kern-only and emits all 5 stage metrics or explicit failure reasons.
- [x] report contains `suite_kind=internal_microbenchmark` and remains v4-compatible.
- [x] external cross-editor benchmark behavior remains unchanged.

### Statistical / methodology

- [x] stage boundary definitions are documented and implemented exactly.
- [ ] regression checker enforces per-stage thresholds from this plan.
- [x] observer-effect overhead is measured and documented.

### Operational

- [x] artifacts are written to canonical archive path with environment metadata.
- [x] publication scripts reject internal suite artifacts for external claims.
- [x] after each code change, rebuild/reinstall Kern app bundle (per AGENTS policy).

## Risks & Mitigations

- **Observer effect from instrumentation**  
  Mitigation: minimal hooks + explicit overhead benchmark.

- **Schema drift breaks tooling**  
  Mitigation: v4-compatible extension + compatibility tests.

- **Internal/external metric mixing**  
  Mitigation: hard publish guardrails and suite-kind checks.

- **Flaky stage signals**  
  Mitigation: deterministic boundary contract + fault-injection tests.

## References & Research

### Internal

- `scripts/kern-bench/Sources/KernBench/SuiteDefinition.swift:3-58`
- `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift:6-220`
- `scripts/bench-regression-check.py:1-220`
- `scripts/cross-editor-benchmark.sh:1-207`
- `BENCHMARKS.md:54-170`

### External

- Apple XCTest performance measurement docs
- Apple OSSignposter interval instrumentation docs
- `google/swift-benchmark` patterns for warmup/measurement

## Data Model / ERD Impact

- No database/model schema changes.
- ERD update not applicable.

## Implementation Readiness Checklist

- [ ] Stage boundary contract approved by maintainer.
- [ ] Threshold policy approved (or revised) before coding.
- [ ] CI mode confirmed: report-only vs blocking.
- [ ] Artifact retention policy confirmed.
