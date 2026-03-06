---
status: complete
priority: p2
issue_id: "005"
tags: [code-review, native-editor, markdown, codec, wysiwyg]
dependencies: []
---

# Define paragraph vs soft-break semantics for Enter and export

## Problem Statement

The native editor uses TextKit paragraphs (newline-separated) as the primary block unit, but Markdown semantics require blank lines to separate paragraphs. Today, `exportMarkdown` joins blocks with a single newline (`\\n`), which in GFM/CommonMark is typically a softbreak inside one paragraph unless there is an empty line.

This is a design gap vs "true WYSIWYG + GFM syntax ground truth" and needs an explicit spec and tests.

## Findings

- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:396-402`
  - `outBlocks.joined(separator: "\\n")` means adjacent blocks are separated by one newline.
  - If a user presses Enter once between two paragraphs in the editor, export will output a single newline, not a blank line.
- `KernApp/Sources/Editor/NativeEditorViewController.swift:362-441`
  - Auto-newline continuation handles lists/headings but does not define paragraph separation semantics outside those cases.
- Test fixtures largely assume explicit blank lines already exist in the source; they do not yet specify editor-Enter behavior for paragraph separation.

## Proposed Solutions

### Option 1: Treat TextKit paragraph breaks as Markdown block breaks (export blank lines between block groups)

**Approach:**
- In export, group runs of list items and code blocks.
- Separate non-list blocks (paragraphs/headings) with blank lines (`\\n\\n`).
- Keep list items tight by default (single newline within list run).

**Pros:**
- Produces Markdown that renders closer to WYSIWYG expectations.
- Keeps output portable (GFM).

**Cons:**
- Requires grouping logic and careful handling of edge cases (loose lists, mixed blocks).

**Effort:** Medium/Large

**Risk:** Medium

---

### Option 2: Treat TextKit newline as Markdown softbreak (require blank line in editor for paragraph separation)

**Approach:**
- Document that "paragraphs are separated by an empty line" (Enter twice) to match Markdown source rules.
- Add tests to enforce.

**Pros:**
- Minimal code changes.
- Matches raw Markdown semantics.

**Cons:**
- Worse WYSIWYG UX vs Notion-style editors.

**Effort:** Small

**Risk:** Low

## Recommended Action

Adopt Typora-like semantics as product contract:
- `Enter` => new paragraph (export uses blank-line separation for paragraph blocks).
- `Shift+Enter` => in-paragraph hard line break (export as explicit Markdown hard-break form, with round-trip tests).


## Resources

- Typora Markdown Reference (paragraph + line break behavior): https://support.typora.io/Markdown-Reference/
- Typora Line Break guidance: https://support.typora.io/Line-Break/
- CommonMark line-break semantics: https://spec.commonmark.org/

## Acceptance Criteria

- [x] Decide and document the intended behavior (Notion-like vs Markdown-source-like)
- [x] Add unit/UI tests capturing Enter behavior and exported Markdown rendering expectations
- [x] Ensure round-trip stability for the decided behavior


### 2026-03-04 - Research Synthesis

**By:** Codex

**External findings:**
- Typora’s documented behavior is:
  - `Enter` creates a new paragraph (source mode shows a blank line between paragraphs).
  - `Shift+Enter` creates a single line break.
- CommonMark semantics define a single newline as a soft break; explicit hard line break uses trailing two spaces or a backslash (`\`) before newline.

**Implication for Kern:**
- For WYSIWYG parity and user expectation, `Enter` should map to paragraph separation (export as blank line between paragraphs).
- `Shift+Enter` should map to in-paragraph line break and export in an explicit, portable Markdown form.

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Flagged mismatch between TextKit paragraph model and GFM paragraph separation rules.

**Learnings:**
- This needs a product-level decision; implementation follows.

### 2026-03-04 - Validation Gate Research

**By:** Codex

**Actions:**
- Reviewed Typora line-break docs and CommonMark line-break semantics.
- Compared with current export behavior (`outBlocks.joined(separator: "\n")`).

**Learnings:**
- The issue is no longer “needs research”; the policy direction is now clear and implementation-ready.

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

