---
status: complete
priority: p2
issue_id: "904"
tags: [code-review, benchmarking, architecture]
dependencies: ["902"]
---

# Extra WOW metrics are only in stats.extra_metrics, not per-run output

## Problem Statement

New metrics are currently surfaced via `RunStats.extraMetrics`, but not represented in `RunResult` per-run fields. This makes run-by-run debugging and variance analysis harder and reduces report consistency.

## Findings

- `scripts/kern-bench/Sources/KernBench/JSONReport.swift` adds `extra_metrics` to `RunStats` only.
- `RunResult` schema remains fixed and does not include extensible extra metrics map.
- Consumers needing per-run tails/jumps cannot access these new signals without additional schema work.

## Proposed Solutions

### Option 1: Add `extra_metrics` map to `RunResult`

**Approach:** Extend run payload with `[String: Double]` for unknown/new metrics.

**Pros:**
- Preserves per-run observability
- Future metric additions need no schema churn

**Cons:**
- Slight schema expansion

**Effort:** 2-3 hours

**Risk:** Low

---

### Option 2: Promote specific new metrics to first-class RunResult fields

**Approach:** Add explicit properties for currently added metrics.

**Pros:**
- Strong typing and discoverability

**Cons:**
- Repeated schema edits for future metrics

**Effort:** 3-4 hours

**Risk:** Low

---

### Option 3: Document stats-only contract and keep as-is

**Approach:** Accept stats-only exposure and update docs/tooling.

**Pros:**
- No code churn

**Cons:**
- Limits debugging fidelity
- Weakens per-run forensic capability

**Effort:** 1 hour

**Risk:** Medium

## Recommended Action
Implemented Option 1: `RunResult` now carries an extensible per-run `extra_metrics` map.

## Technical Details

**Affected files:**
- `scripts/kern-bench/Sources/KernBench/JSONReport.swift`
- `scripts/kern-bench/Sources/KernBench/KernBenchMain.swift`

## Resources

- Review of current result JSON shape and metric propagation path.

## Acceptance Criteria

- [x] New metrics available at per-run level (or explicitly justified/documented otherwise)
- [x] Backward-compatible decoding for existing consumers
- [x] Tests added for encode/decode and regression classification compatibility

## Work Log

### 2026-02-25 - Review discovery

**By:** Codex

**Actions:**
- Reviewed report schema and run/stats aggregation flow
- Identified asymmetry between run and aggregate metric visibility

**Learnings:**
- Extensible per-run metric maps reduce repeated schema churn.

### 2026-03-01 - Completed

**By:** Codex

**Actions:**
- Added `extra_metrics` optional map to `RunResult` JSON schema.
- Wired unknown WOW metrics into per-run payload emission in `KernBenchMain`.
- Added schema tests for decode/encode behavior and updated classification test initializer callsites.

**Learnings:**
- Per-run extra metric emission materially improves forensic analysis when aggregate-only stats hide variance/outliers.

## Notes

- Depends on issue 902 for correct full payload capture first.

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Filename normalized to match complete status in frontmatter.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
