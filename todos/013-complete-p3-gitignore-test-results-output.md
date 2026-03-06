---
status: complete
priority: p3
issue_id: "013"
tags: [code-review, repo-hygiene, tests]
dependencies: []
---

# Ignore native-editor test output directory (test-results/)

## Problem Statement

The native editor test runner writes artifacts under `test-results/native-editor/...`, but `test-results/` is not currently ignored. This creates persistent untracked churn and increases the chance of committing test artifacts accidentally.

## Findings

- `scripts/test-native-editor.sh:26-27` writes output under `test-results/native-editor/<timestamp>/...`.
- `.gitignore` currently ignores `CoreEditor/test-results/` but not top-level `test-results/`.

## Proposed Solutions

### Option 1: Add `test-results/` to `.gitignore`

**Approach:**
- Add a rule for `test-results/` in `.gitignore`.

**Pros:**
- Eliminates noise and accidental commits.

**Cons:**
- None.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] Running `./scripts/test-native-editor.sh` does not create new untracked files in git status
- [x] CI/local still preserves artifacts as needed (outside git)

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Observed `test-results/` untracked output from test runner.


### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as completed: top-level test-results/ is already gitignored.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
