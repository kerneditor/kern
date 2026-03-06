---
status: complete
priority: p1
issue_id: "902"
tags: [code-review, performance, data-integrity, benchmarking]
dependencies: []
---

# Bench run reuses stale preloaded WOW payload and drops late metrics

## Problem Statement

`kern-bench` can lock onto an early WOW payload captured at open-ready and then reuse it for final aggregation, causing late-emitted metrics to be missing from benchmark outputs. This invalidates final reporting for newly added promotion/jump metrics.

## Findings

- In `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift`, open-ready path sets `preloadedWowMetrics` with `requireAllMetrics: false`.
- Later aggregation path prefers `preloadedWowMetrics` over a fresh `waitForWowInternalMetrics(...)` call.
- Newly added metrics (`promotion_apply_slice_p99_ms`, jump/anchor counters, time aliases) are emitted later than open-ready and are therefore absent in results.
- Reproduced during review by inspecting generated JSON where these fields were missing despite unit-level recorder assertions passing.

## Proposed Solutions

### Option 1: Always re-read WOW payload at final aggregation

**Approach:** Ignore `preloadedWowMetrics` in the post-open aggregation phase and always call `waitForWowInternalMetrics` there.

**Pros:**
- Deterministic final payload capture
- Minimal conceptual complexity

**Cons:**
- Slight additional wait time per run

**Effort:** 1-2 hours

**Risk:** Low

---

### Option 2: Merge preloaded + final payload

**Approach:** Keep preloaded payload for open-latency logic, then fetch final payload and merge keys (final wins).

**Pros:**
- Preserves open-path behavior
- Captures late metrics

**Cons:**
- Merge semantics must be carefully documented

**Effort:** 2-4 hours

**Risk:** Medium

---

### Option 3: Add explicit "metrics finalized" marker in recorder

**Approach:** Recorder writes a completion marker; bench waits for marker before accepting payload for final aggregation.

**Pros:**
- Strong correctness contract
- Future-proof for new metrics

**Cons:**
- Requires app + bench protocol change

**Effort:** 4-6 hours

**Risk:** Medium

## Recommended Action

Implemented Option 1 with explicit regression coverage.

## Technical Details

**Affected files:**
- `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift`
- `KernApp/Sources/Editor/WowInternalMetricsRecorder.swift`

## Resources

- Local benchmark outputs produced during review showing missing late metrics in run-level output.

## Acceptance Criteria

- [x] Final aggregation does not reuse stale open-time payload for full metric set
- [x] Late WOW metrics appear consistently in benchmark JSON on large fixture runs
- [x] Add regression test in `scripts/kern-bench/Tests` covering late-metric availability
- [x] Verify with at least one `wow_internal` and one `benchmark_open_ready` run

## Work Log

### 2026-02-25 - Review discovery

**By:** Codex

**Actions:**
- Traced preloaded payload flow in `KernBenchMain.swift`
- Correlated with benchmark output missing newly-added keys
- Identified stale payload reuse as root cause

**Learnings:**
- Open-ready and final metric completeness need separate synchronization contracts.

### 2026-02-25 - Fix completed

**By:** Codex

**Actions:**
- Updated final metrics aggregation to always perform a fresh WOW metrics read and only fallback to preloaded payload when fresh data is unavailable.
- Added `WowMetricsSelectionTests` regression coverage for fresh-vs-preloaded selection behavior.
- Rebuilt `kern-bench` debug/release and verified benchmark runs:
  - `wow_internal` on `native-editor-benchmark.md`
  - `benchmark_open_ready` on `native-editor-benchmark.md`

**Learnings:**
- Explicit selection logic in a dedicated function made stale-payload behavior directly testable.

## Notes

- This is marked P1 because it can produce misleading benchmark conclusions.

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Filename normalized to match complete status in frontmatter.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
