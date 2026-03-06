---
status: complete
priority: p2
issue_id: "003"
tags: [code-review, native-editor, markdown, codec]
dependencies: []
---

# Link export drops inline styles (bold/italic/code) within links

## Problem Statement

`NativeMarkdownCodec.exportInline` serializes links as `[text](url)` but does not preserve `kernStrong`/`kernEmphasis`/`kernInlineCode` styling for the linked text. This can cause data loss on save: the editor can represent a bold link, but export strips the bold markup.

## Findings

- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:1117-1124`
  - When `next.link != nil`, the serializer closes the current style, resets `current`, and outputs `[escapedText](url)` without any consideration for `next.strong/emphasis/code`.
  - The "close/reset" behavior also risks breaking style continuity across link boundaries.
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:872-887`
  - `parseInline` allows links to inherit the surrounding style (it copies `style` then sets `nextStyle.link = url`), so styled links can exist in the attributed representation.

## Proposed Solutions

### Option 1: Serialize link label with nested markers based on attributes

**Approach:**
- When exporting a link run, derive a label string that includes inline markers for bold/italic/code (and escapes accordingly), then output `[label](url)`.
- Keep link runs compatible with GFM/CommonMark.

**Pros:**
- Preserves semantics; avoids data loss.
- Keeps export as Markdown, not HTML.

**Cons:**
- Requires careful escaping rules (avoid escaping `*`/`` ` `` when they represent markup).

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Disallow inline styling inside links in the editor (explicitly)

**Approach:**
- Enforce that selecting a link and applying bold/italic/code removes link attribute or blocks the operation.
- Document as limitation.

**Pros:**
- Much simpler.

**Cons:**
- Worse UX and surprising limitation.

**Effort:** Small

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:1089`

## Resources

- Branch: `rewrite`

## Acceptance Criteria

- [x] Add unit test(s) demonstrating styled link round-trip (bold link label at minimum)
- [x] Export preserves link label styles without corrupting surrounding inline styles
- [x] Golden fixture added for the case

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Reviewed link parsing/export paths and identified style loss during export.

**Learnings:**
- Links are treated as a special-case run; needs to become composable with inline style markers.


### 2026-03-04 - Validation Gate: Mark Complete

**By:** Codex

**Actions:**
- Re-ran targeted tests:
  - `NativeMarkdownCodecGfmMarkerCompatibilityTests/testLinkLabelWithNestedFormattingExportsAsSingleLink`
  - `NativeMarkdownCodecGfmMarkerCompatibilityTests/testComplexInlineLinkLabelFallsBackToLiteralRoundTrip`
- Verified exporter handles nested inline styles within link labels in `NativeMarkdownCodec.exportInline`.

**Learnings:**
- This issue is fixed in current branch state; keeping it pending would create stale portfolio noise.

---
