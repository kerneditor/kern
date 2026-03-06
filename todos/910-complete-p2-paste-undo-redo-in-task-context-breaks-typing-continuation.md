---
status: complete
priority: p2
issue_id: "910"
tags: [code-review, typing-regression, undo-redo, native-editor]
dependencies: []
---

# Paste + undo/redo in task context breaks typing continuation

## Problem Statement

After paste then undo/redo in task-list context, typing may stop continuing correctly. This impacts reliability of editing sessions with frequent corrections.

## Findings

- Failing test from baseline run:
  - `NativeEditorNotionTypingBehaviorProgramTests/testPasteThenUndoRedoAcrossListContexts_PRLane`
- Failure signal:
  - `[task] typing should continue after paste/undo/redo`

## Proposed Solutions

### Option 1: Repair selection/typing-attribute restoration after undo group replay

**Approach:**
- Audit post-undo caret and typing-attributes restoration in task contexts.
- Ensure continuation logic runs with stable marker-aware selection ranges.

**Pros:**
- Targets likely root cause.

**Cons:**
- Requires careful interaction with existing flush/debounce behavior.

**Effort:** Medium

**Risk:** Medium

## Recommended Action

Implement Option 1 with focused regression tests for task, ordered-task, and nested task variants.

## Acceptance Criteria

- [x] Task-context paste+undo+redo keeps typing continuation working
- [x] Related program test passes
- [x] No regression in undo/autosave suites

## Work Log

### 2026-03-04 - Validation Gate discovery

**By:** Codex

**Actions:**
- Baseline suite run revealed continuation failure in task context after paste/undo/redo sequence.

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

