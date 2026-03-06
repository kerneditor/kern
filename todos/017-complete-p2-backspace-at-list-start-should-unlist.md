---
status: complete
priority: p2
issue_id: "017"
tags: [code-review, native-editor, ux, lists]
dependencies: []
---

# Backspace at start of list/task item should remove list formatting (expected editor behavior)

## Problem Statement

The editor prevents edits that touch marker regions (`kernMarker`) and supports exiting lists by pressing Enter on an empty item. However, common editors also support exiting/removing list formatting via Backspace at the start of the list item. Without this, list editing feels rigid and users can get "stuck" in list formatting.

## Findings

- `KernApp/Sources/Editor/NativeEditorViewController.swift:216-237`
  - `textView(_:shouldChangeTextIn:replacementString:)` blocks changes that touch marker ranges, but does not implement an alternative "unlist" behavior for backspace-at-start.
- `NATIVE-EDITOR-TEST-PLAN.md:180-185` explicitly calls out Backspace behavior as a target area, but no implementation/tests exist yet.

## Proposed Solutions

### Option 1: Special-case backspace at start-of-content to remove block kind + marker prefix

**Approach:**
- Detect backspace when selection is collapsed and caret is at the first non-marker character.
- Convert the paragraph to `.paragraph` by removing marker prefix characters and clearing block/list attributes.
- Preserve content and selection.

**Pros:**
- Matches user expectations (Notion/GitHub-like).

**Cons:**
- Requires careful handling to avoid corrupting marker attributes and undo stack.

**Effort:** Medium/Large

**Risk:** Medium

---

### Option 2: Add an explicit menu command "Remove list formatting"

**Approach:**
- Provide a deterministic command rather than key-event inference.

**Pros:**
- Simpler to implement correctly.

**Cons:**
- Worse UX than backspace behavior.

**Effort:** Medium

**Risk:** Low

## Acceptance Criteria

- [x] Unit test(s): backspace at list start removes list formatting and preserves text
- [x] UI test: create bullet, move caret to start of item content, backspace => becomes paragraph
- [x] Behavior works for bullet, task, ordered

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Noted marker protection without a corresponding "unlist" backspace path.


### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as completed: backspace-at-list-start unlist behavior implemented with dedicated tests.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
