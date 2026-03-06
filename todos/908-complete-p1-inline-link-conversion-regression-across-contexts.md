---
status: complete
priority: p1
issue_id: "908"
tags: [code-review, typing-regression, links, native-editor]
dependencies: []
---

# Inline markdown link conversion regressed across paragraph/list contexts

## Problem Statement

Typing or pasting inline markdown links (for example `[docs](https://example.com/docs)`) no longer converts reliably to WYSIWYG link attributes across paragraph, bullet, ordered, task, ordered-task, and heading contexts. This is user-facing and easy to reproduce.

## Findings

- Failing tests from baseline run:
  - `NativeEditorNotionListBehaviorRegressionTests/testInlineLinkTypingConvertsAcrossParagraphAndListContexts_PRLane`
  - `NativeEditorNotionListBehaviorRegressionTests/testInlineLinkPasteConvertsAcrossParagraphAndListContexts_PRLane`
  - `NativeEditorNotionListBehaviorRegressionTests/testTypedBareDomainInlineLinkClickNormalizesToHTTPS_PRLane`
- Failure evidence captured in:
  - `test-results/native-editor/20260304-223045/unit.log`

## Proposed Solutions

### Option 1: Rewire inline-link conversion trigger pipeline (typing + paste)

**Approach:**
- Ensure markdown-link conversion pipeline runs after both typed and pasted text mutations in all block kinds.
- Centralize link conversion pass so it cannot be bypassed by specific contexts.

**Pros:**
- Directly addresses regression source.
- Restores expected WYSIWYG behavior.

**Cons:**
- Touches hot typing paths.

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Context-specific fallback conversion pass

**Approach:**
- Add explicit fallback pass for list/task/heading blocks only.

**Pros:**
- Smaller blast radius.

**Cons:**
- More fragmented logic.

**Effort:** Small/Medium

**Risk:** Medium

## Recommended Action

Implement Option 1 with targeted regression tests first, then verify with typing matrix suites.

## Acceptance Criteria

- [x] Typed inline link converts in all target contexts
- [x] Pasted inline link converts in all target contexts
- [x] Bare-domain links normalize to `https://` on click behavior
- [x] Regression tests above pass in CI suite

## Work Log

### 2026-03-04 - Validation Gate discovery

**By:** Codex

**Actions:**
- Ran baseline native suite and captured multi-context link regression failures.

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

