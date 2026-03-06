---
status: complete
priority: p2
issue_id: "015"
tags: [code-review, native-editor, wysiwyg, markdown, codec]
dependencies: []
---

# Heading styling overrides inline rendering (inline code/bold/italic not truly WYSIWYG in headings)

## Problem Statement

Headings apply a single bold font to the entire paragraph, which overrides inline font choices produced by the inline parser (e.g. monospaced inline code). This means headings are not fully WYSIWYG for inline formatting: the exported Markdown may contain backticks/asterisks, but the editor does not visually reflect the styling inside heading blocks.

## Findings

- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:149-157`
  - Heading import: `parseInline(...)` produces per-span fonts.
  - Then `applyBlockAttributes(... kind: .heading ...)` is applied to the full paragraph.
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:761-779`
  - In `.heading`, `applyBlockAttributes` sets `.font` over the full range, overriding any inline font differences.
- Same pattern applies to `makeHeadingWithCheckbox`: checkbox font is set, then heading font overwrites it.

## Proposed Solutions

### Option 1: Preserve inline fonts; only apply heading font where no explicit inline font exists

**Approach:**
- For headings, avoid writing `.font` across the full range.
- Instead, set paragraph-level styling (paragraphStyle, spacing, maybe default typing attributes) and leave inline fonts intact.
- If necessary, set a "base heading font" attribute key and compute effective fonts during rendering.

**Pros:**
- True WYSIWYG for inline code and emphasis inside headings.

**Cons:**
- Requires careful definition of precedence between block font and inline styles.

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Explicitly disallow inline formatting inside headings for MVP

**Approach:**
- Strip/ignore inline style attributes within headings and document it.

**Pros:**
- Simpler.

**Cons:**
- Not really WYSIWYG and surprising for users.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] Add fixture/test for heading containing inline code and/or emphasis
- [x] Editor visually renders inline code as monospaced inside heading
- [x] Export remains deterministic and round-trips the fixture

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Traced heading import path and found full-range font overwrite breaks inline styling in headings.



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

