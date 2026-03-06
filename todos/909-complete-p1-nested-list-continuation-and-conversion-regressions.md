---
status: complete
priority: p1
issue_id: "909"
tags: [code-review, typing-regression, lists, native-editor]
dependencies: []
---

# Nested list continuation/conversion regressions in typing matrix

## Problem Statement

Nested list behaviors regress under current typing matrix: continuation markers and cross-list conversions fail for nested ordered/task/list combinations. This directly impacts typing reliability and perceived editor quality.

## Findings

- Failing tests from baseline run:
  - `NativeEditorNotionListBehaviorRegressionTests/testEnterInMiddleOfListItemContinuesMarkerMatrix_PRLane`
  - `NativeEditorTypingBehaviorMatrixCoverageTests/testCriticalTypingBehaviorTransitionMatrix_PRLane` (multiple assertion failures)
- Failure examples include:
  - nested ordered continuation drops to plain line
  - nested ordered → nested bullet task conversion fails
  - nested task → nested ordered task conversion fails

## Proposed Solutions

### Option 1: Normalize nested marker inference with explicit state machine

**Approach:**
- Introduce deterministic marker inference for nested contexts (depth + parent kind + target shortcut).
- Reuse for Enter continuation, Tab/Shift-Tab, and marker-shortcut conversions.

**Pros:**
- Prevents divergence across entry points.

**Cons:**
- More invasive refactor.

**Effort:** Medium/Large

**Risk:** Medium

---

### Option 2: Patch each failing transition path incrementally

**Approach:**
- Fix each failing path with focused condition updates and tests.

**Pros:**
- Faster short-term recovery.

**Cons:**
- Higher chance of future drift.

**Effort:** Medium

**Risk:** Medium

## Recommended Action

Start with Option 2 for immediate stability, then consolidate to Option 1 if additional drift appears.

## Acceptance Criteria

- [x] Nested ordered Enter continuation remains marked
- [x] Nested cross-list conversion cases pass
- [x] Full `testCriticalTypingBehaviorTransitionMatrix_PRLane` passes
- [x] Full list behavior regression suite passes

## Work Log

### 2026-03-04 - Validation Gate discovery

**By:** Codex

**Actions:**
- Baseline suite run surfaced matrix regressions in nested list transitions.

---


### 2026-03-05 - Completion validation

**By:** Codex

**Actions:**
- Re-validated against current native + typing gate suites and current benchmark evidence.
- Confirmed issue behavior no longer reproduces in current branch scope.
- Marked todo as complete in file-based portfolio.

**Evidence:**
- `./scripts/run-typing-behavior-gate.sh --lane pr` ✅
- `./scripts/test-native-editor.sh` ✅
- `benchmark_open_ready` and `benchmark_full_fidelity` reruns archived under `benchmark-archive/runs/20260304-163101-benchmark-open-ready/` and `benchmark-archive/runs/20260304-163144-benchmark-full-fidelity/`.

