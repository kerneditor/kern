---
status: complete
priority: p2
issue_id: "903"
tags: [code-review, performance, quality]
dependencies: []
---

# WOW recorder sample aggregation can add avoidable main-thread overhead

## Problem Statement

`WowInternalMetricsRecorder.recordAuxSample` stores all samples and sorts on every call. Under heavy staged promotions, this can add avoidable CPU/memory pressure on the main thread and distort the very metrics it measures.

## Findings

- In `KernApp/Sources/Editor/WowInternalMetricsRecorder.swift`, `recordAuxSample` appends into arrays and sorts entire sample sets each invocation.
- Method is called during promotion parse/apply loops, which are latency-sensitive.
- Persist-to-disk is also invoked each sample update, amplifying overhead.

## Proposed Solutions

### Option 1: Incremental stats without full sample storage

**Approach:** Maintain rolling counters/histogram bins and approximate quantiles instead of sorting full arrays.

**Pros:**
- Bounded memory
- Lower CPU per sample

**Cons:**
- Quantiles become approximate

**Effort:** 3-5 hours

**Risk:** Medium

---

### Option 2: Sample decimation + periodic recompute

**Approach:** Record every Nth sample and recompute quantiles every M updates.

**Pros:**
- Minimal redesign
- Big overhead reduction

**Cons:**
- Less precise tails

**Effort:** 2-3 hours

**Risk:** Low

---

### Option 3: Keep exact samples but move aggregation off critical path

**Approach:** Accumulate samples cheaply; compute p50/p95/p99 during settle/finalize only.

**Pros:**
- Exact quantiles
- Lower per-event cost

**Cons:**
- Delayed intermediate visibility

**Effort:** 2-4 hours

**Risk:** Low

## Recommended Action
Implemented Option 3: keep exact samples, defer percentile materialization to flush/persist path.

## Technical Details

**Affected files:**
- `KernApp/Sources/Editor/WowInternalMetricsRecorder.swift`
- `KernApp/Sources/Editor/NativeEditorViewController.swift`

## Resources

- Review inspection of staged promotion instrumentation callsites.

## Acceptance Criteria

- [x] Quantile/counter instrumentation adds minimal overhead in promotion hot path
- [x] Recorder memory growth remains bounded on large files
- [x] No regression in required WOW metric completeness

## Work Log

### 2026-02-25 - Review discovery

**By:** Codex

**Actions:**
- Reviewed recorder internals and call frequency
- Identified repeated full-sort + persist pattern in hot path

**Learnings:**
- Instrumentation overhead must be explicitly budgeted to avoid observer effects.

### 2026-03-01 - Completed

**By:** Codex

**Actions:**
- Reworked `WowInternalMetricsRecorder.recordAuxSample` to append samples and mark keys dirty without per-sample full-array sorts.
- Added deferred percentile materialization at persist flush (`materializeDirtySampleMetrics`).
- Added/ran recorder regression test coverage.

**Learnings:**
- Moving quantile aggregation off the per-event hot path removes repeated O(n log n) churn during staged promotion loops while preserving exact percentile outputs.

## Notes

- Keep benchmark integrity principle: separate app performance from instrumentation noise.

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Filename normalized to match complete status in frontmatter.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
