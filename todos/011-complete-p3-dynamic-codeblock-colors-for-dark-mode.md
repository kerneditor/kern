---
status: complete
priority: p3
issue_id: "011"
tags: [code-review, native-editor, ui]
dependencies: []
---

# Code block background colors should adapt to light/dark mode

## Problem Statement

`NativeMarkdownTextView` draws code block backgrounds using fixed grayscale colors based on `NSColor(white: 0, alpha: ...)`. This may have poor contrast in dark mode and can look inconsistent with system appearance.

## Findings

- `KernApp/Sources/Editor/NativeMarkdownTextView.swift:89-90`
  - Uses `NSColor(white: 0, alpha: 0.08)` and `0.10` for stroke.

## Proposed Solutions

### Option 1: Use dynamic system colors

**Approach:**
- Use `NSColor.textBackgroundColor`/`windowBackgroundColor` mixes, or resolve colors via `effectiveAppearance`.

**Pros:**
- Automatically matches system themes.

**Cons:**
- Requires design tuning.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] In both light and dark appearances, code block background has clear but subtle contrast
- [x] Snapshot tests (gated) updated/added to lock visual styling

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Flagged fixed-color code block backgrounds as potential dark-mode issue.



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

