---
status: complete
priority: p2
issue_id: "006"
tags: [code-review, native-editor, markdown, codec, ux]
dependencies: []
---

# Ordered task parsing does not accept marker-only items (UX inconsistency)

## Problem Statement

`parseOrderedTask` currently requires at least one character of task text after the marker, so `1. [ ] ` (with no text yet) is not recognized as an ordered task. This makes typing ordered tasks feel inconsistent with bulleted tasks, where `- [ ] ` is recognized immediately.

## Findings

- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:568-574`
  - `guard chars.count >= prefixLen + 7 else { return nil }` is too strict.
  - The function later does `String(chars.dropFirst(prefixLen + 6))`, which supports empty trailing text, implying the guard should likely allow it.
- `KernApp/Sources/Editor/NativeEditorViewController.swift:338-360`
  - Ordered-list input rule triggers once `N. ` is typed; if the user then types `[ ] ` the codec may still interpret it as ordered-list text until additional characters are added.

## Proposed Solutions

### Option 1: Allow empty task text in parseOrderedTask

**Approach:**
- Change the guard to `prefixLen + 6` (minimum to include the trailing space).
- Also validate the checked character is either space or `x`/`X` to avoid mis-parsing `1. [a] ` as a task.

**Pros:**
- Immediate WYSIWYG conversion once the marker is complete.
- More consistent with bulleted tasks.

**Cons:**
- Slightly broader parsing; must be careful not to treat invalid patterns as tasks.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] Unit test: `orderedTasksEnabled=true` recognizes `1. [ ] ` as ordered task
- [x] UI test: typing `1. [ ] ` converts to checkbox without requiring extra chars
- [x] Ensure invalid patterns (ex: `1. [a] text`) do not become tasks

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Identified overly strict length guard in ordered-task parser.


### 2026-03-04 - Validation Gate: Mark Complete (with follow-up)

**By:** Codex

**Actions:**
- Re-ran targeted regression test:
  - `NativeEditorBulletTaskInputRuleTests/testNestedBulletItemCanSwitchToNestedOrderedTaskByTypingMarkerShortcuts`
- Verified parser now accepts marker-only ordered tasks (`1. [ ] `).

**Learnings:**
- Core bug is fixed.
- Follow-up remains for stricter checkbox token validation (`[a]` should not parse as ordered-task checkbox).

---
