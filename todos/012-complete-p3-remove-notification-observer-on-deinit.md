---
status: complete
priority: p3
issue_id: "012"
tags: [code-review, native-editor, reliability]
dependencies: []
---

# Remove NotificationCenter observer in NativeEditorViewController deinit

## Problem Statement

`NativeEditorViewController` registers a `boundsDidChange` observer but does not remove it. While the controller likely lives for the window lifetime, cleaning up observers avoids accidental leaks and future refactor hazards.

## Findings

- `KernApp/Sources/Editor/NativeEditorViewController.swift:88-93`
  - Adds an observer for `NSView.boundsDidChangeNotification`.
  - No corresponding removal in `deinit`.

## Proposed Solutions

### Option 1: Remove observer in deinit

**Approach:**
- Store the observer token (or call `NotificationCenter.default.removeObserver(self, ...)` in `deinit`).

**Pros:**
- Safe and conventional.

**Cons:**
- Minimal.

**Effort:** Small

**Risk:** Low

## Acceptance Criteria

- [x] Observer is removed when the view controller is deallocated
- [x] No behavior change in normal use

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Noted missing observer cleanup.


### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as completed: NotificationCenter observer cleanup exists in deinit.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
