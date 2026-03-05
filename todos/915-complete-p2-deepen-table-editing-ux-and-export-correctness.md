---
status: complete
priority: p2
issue_id: "915"
tags: [editor, tables, wysiwyg, export, typing]
dependencies: []
---

# Deepen table editing UX and export correctness

## Problem Statement

Table support currently covers detection/rendering and overflow behavior, but editing ergonomics are still behind the expected WYSIWYG experience for wide and complex tables.

## Findings

- `TODO.md` still had this item open after revalidation.
- Existing coverage confirms overflow behavior (`NativeEditorTableOverflowTests`) but does not fully enforce richer row/column authoring workflows.
- User feedback indicates table usability expectations closer to Notion/GitHub-style practical editing.

## Proposed Solutions

### Option 1: Incremental table-editing rules + focused regression suites (preferred)

**Approach:** Add deterministic editing rules for row/column navigation/edits first, then add export round-trip assertions.

**Pros:**
- Lower risk than full table editor rewrite.
- Fastest route to visible UX gains.

**Cons:**
- May need multiple iterations to match full parity expectations.

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Full dedicated table editor interaction model

**Approach:** Build richer table model/interactions (insert/delete row/column commands, structured navigation state).

**Pros:**
- Best long-term architecture.

**Cons:**
- Large scope and regression surface.

**Effort:** Large

**Risk:** Medium-High

## Recommended Action

## Technical Details

**Likely affected files:**
- `KernApp/Sources/Editor/NativeEditorViewController.swift`
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernTests/NativeEditorTableOverflowTests.swift`
- `KernTests/NativeEditorNotionTypingBehaviorProgramTests.swift`

## Resources

- `TODO.md`
- `docs/reports/2026-03-06-todo-portfolio-revalidation.md`

## Acceptance Criteria

- [x] Table editing behaviors for key scenarios are explicitly specified and implemented.
- [x] Row/column edit workflows have deterministic regression tests.
- [x] Export round-trip for edited tables is verified in tests.
- [x] Typing behavior PR lane remains green.

## Work Log

### 2026-03-06 - Created from revalidation

**By:** Codex

**Actions:**
- Converted remaining open `TODO.md` table UX item into file-based pending todo.

### 2026-03-06 - Completed incremental table editing UX pass

**By:** Codex

**Actions:**
- Added deterministic table-cell navigation behavior for Tab / Shift-Tab.
- Added append-row-on-last-cell-tab workflow with export preservation.
- Added `NativeEditorTableEditingTests` regression coverage for navigation + export round-trip.
- Verified table updates do not regress typing lane behavior.
