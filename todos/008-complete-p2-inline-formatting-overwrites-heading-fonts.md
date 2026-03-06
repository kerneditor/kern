---
status: complete
priority: p2
issue_id: "008"
tags: [code-review, native-editor, wysiwyg, formatting]
dependencies: []
---

# Inline formatting toggles overwrite block fonts (headings/code blocks)

## Problem Statement

`toggleInlineAttribute` recalculates fonts from a fixed base font (16pt system) and applies them across the selected range. If the selection is inside a heading or other block with a different font size, this can accidentally reset the block font, breaking WYSIWYG fidelity.

## Findings

- `KernApp/Sources/Editor/NativeEditorViewController.swift:528-556`
  - Uses `let baseFont = NSFont.systemFont(ofSize: 16)` and then writes `.font` for each subrange.
  - This ignores the existing `.font` at the selection range, including heading sizes set by `NativeMarkdownCodec.applyBlockAttributes`.

## Proposed Solutions

### Option 1: Use the existing font as the base when applying traits

**Approach:**
- For each subrange, start from `attrs[.font] as? NSFont` (fallback to 16pt).
- Apply bold/italic traits via `NSFontManager` and preserve point size.
- For inline code, switch family to monospaced while preserving size.

**Pros:**
- Preserves heading sizes and any future typography.
- More "true WYSIWYG".

**Cons:**
- Slightly more code.

**Effort:** Medium

**Risk:** Medium (font edge cases)

---

### Option 2: Disable inline formatting inside headings (explicit limitation)

**Approach:**
- In `validateMenuItem`, disable bold/italic/code when caret/selection intersects heading block kind.

**Pros:**
- Simple.

**Cons:**
- Restrictive UX.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] Unit/UI test: selecting text inside a heading and toggling bold does not shrink/reset heading font size
- [x] Formatting behavior is documented (either supported correctly or explicitly disabled)

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Identified fixed base font usage in inline formatting toggles.



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

