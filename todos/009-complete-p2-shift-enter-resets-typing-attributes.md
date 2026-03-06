---
status: complete
priority: p2
issue_id: "009"
tags: [code-review, native-editor, ux]
dependencies: []
---

# Shift+Enter/list-break path resets typing attributes to base (may drop inline style)

## Problem Statement

When `suppressNextAutoNewlineContinuation` is set (Shift+Enter or explicit line break), `handleNewlineContinuationIfNeeded` resets typing attributes to the base font/color. This likely drops any active inline style the user expects to continue typing with (bold/italic/code).

## Findings

- `KernApp/Sources/Editor/NativeMarkdownTextView.swift:32-45`
  - Shift+Enter sets `suppressNextAutoNewlineContinuation = true` then inserts a line break.
- `KernApp/Sources/Editor/NativeEditorViewController.swift:364-367`
  - If suppression flag is set, it calls `setBaseTypingAttributes()` and returns.

## Proposed Solutions

### Option 1: Preserve typing attributes from insertion point

**Approach:**
- When suppression flag is observed, set typing attributes based on the attributes at the caret location (excluding marker attributes), rather than resetting to base.

**Pros:**
- More intuitive WYSIWYG typing behavior.

**Cons:**
- Needs careful handling if caret is in marker region.

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Document as current limitation

**Approach:**
- Keep behavior for MVP and add a test to lock it in.

**Pros:**
- Zero complexity.

**Cons:**
- UX regression vs Notion-like editors.

**Effort:** Small

**Risk:** Low

## Resources

- Typora Line Break guidance: https://support.typora.io/Line-Break/
- Tiptap HardBreak (`keepMarks` default true): https://tiptap.dev/docs/editor/extensions/nodes/hard-break
- CommonMark hard/soft line-break semantics: https://spec.commonmark.org/

## Acceptance Criteria

- [x] Decide intended behavior for inline style carry-over across Shift+Enter
- [x] Add UI test covering the behavior (bold then Shift+Enter then type)
- [x] Implementation matches the decided behavior


### 2026-03-04 - Research Synthesis

**By:** Codex

**External findings:**
- Typora documents `Shift+Enter` as a single line break inside editing flow, while `Enter` creates paragraph breaks.
- In mainstream rich-text/WYSIWYG UX, inline style intent generally persists across soft line breaks within the same block.

**Implication for Kern:**
- `Shift+Enter` should preserve active inline typing style (bold/italic/code) unless caret context changes to a block type that requires different attributes.

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Noted unconditional typing-attribute reset on suppression path.

### 2026-03-04 - Validation Gate Research

**By:** Codex

**Actions:**
- Reviewed external editor behavior guidance and current internal Shift+Enter tests.
- Confirmed current tests do not lock style-carry expectation.

**Learnings:**
- This issue is now spec-defined and implementation-ready.

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

