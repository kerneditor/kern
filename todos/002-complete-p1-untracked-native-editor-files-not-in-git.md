---
status: complete
priority: p1
issue_id: "002"
tags: [code-review, repo-hygiene, native-editor]
dependencies: []
---

# Native editor prototype has many untracked files (risk: feature not actually in repo)

## Problem Statement

Large parts of the native editor prototype (source files, tests, scripts, fixtures, docs) currently exist as untracked files. If a commit/PR is created without adding them, the native editor and its test suite will be incomplete or missing in other environments.

This is a P1 because it blocks reliable collaboration and CI.

## Findings

- `git status` shows core source files as untracked:
  - `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
  - `KernApp/Sources/Editor/NativeEditorViewController.swift`
  - `KernApp/Sources/Editor/NativeMarkdownTextView.swift`
  - `KernApp/Sources/Editor/KernTextAttributes.swift`
- Many unit/UI tests and fixtures are also untracked:
  - `KernTests/Native*`
  - `KernUITests/*`
  - `test-fixtures/native-editor-golden/*`
  - `scripts/test-native-editor.sh`, `scripts/run-kern-native.sh`
- `test-results/` is also untracked output; should be ignored rather than committed.

## Proposed Solutions

### Option 1: Add all relevant prototype files + ignore build outputs

**Approach:**
- `git add` all native-editor sources, tests, scripts, fixtures, and docs that are part of the feature.
- Ensure outputs like `test-results/` remain ignored.
- Add a minimal CI job that runs unit tests (`./scripts/test-native-editor.sh --unit-only`).

**Pros:**
- Makes the work real and reviewable.
- Enables CI and team collaboration.

**Cons:**
- Requires a cleanup pass to avoid committing artifacts accidentally.

**Effort:** Small/Medium

**Risk:** Low

---

### Option 2: Split into multiple commits

**Approach:**
- Commit in logical chunks:
  1. Native editor sources
  2. Unit tests + golden fixtures
  3. UI tests + scripts
  4. Docs

**Pros:**
- Easier review.

**Cons:**
- Takes a bit longer.

**Effort:** Medium

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files (examples):**
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernUITests/NativeEditorE2ETests.swift`
- `scripts/test-native-editor.sh`

## Resources

- Branch: `rewrite`

## Acceptance Criteria

- [x] All native-editor sources required to build are tracked
- [x] All tests/fixtures/scripts required to run `./scripts/test-native-editor.sh --unit-only` are tracked
- [x] Output directories (ex: `test-results/`) are ignored and not committed

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Observed many native-editor sources/tests/scripts present as untracked files.

**Learnings:**
- Without staging these, collaborators/CI will not see the native editor feature.



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

