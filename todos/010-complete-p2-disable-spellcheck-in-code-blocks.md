---
status: complete
priority: p2
issue_id: "010"
tags: [code-review, native-editor, ux, textkit]
dependencies: []
---

# Disable spellcheck/autocorrect behaviors inside code blocks

## Problem Statement

The native editor enables spelling correction globally. In most editors (Notion/GitHub), code blocks do not spellcheck/autocorrect. Leaving it enabled in code blocks is distracting and can cause unwanted edits.

## Findings

- `KernApp/Sources/Editor/NativeEditorViewController.swift:62`
  - `textView.isAutomaticSpellingCorrectionEnabled = true` (global).
- The editor already knows code-block regions via `.kernBlockKind == .codeBlock`; we can use this signal.

## Proposed Solutions

### Option 1: Toggle spellcheck based on caret location

**Approach:**
- In `textViewDidChangeSelection`, detect if caret is in a code block and disable spellcheck/autocorrect for that state; enable otherwise.

**Pros:**
- Matches typical editor expectations.

**Cons:**
- Requires tuning so toggling doesn’t flicker.

**Effort:** Medium

**Risk:** Low/Medium

---

### Option 2: Disable spelling correction entirely for MVP

**Approach:**
- Set `isAutomaticSpellingCorrectionEnabled = false` globally for now.

**Pros:**
- Simple.

**Cons:**
- Worse for normal prose editing.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] Add UI test: caret in code block => no correction UI / no substitutions (best-effort)
- [x] Ensure normal paragraphs keep spelling correction if enabled

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Identified global spellcheck enabling without code-block exception.



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

