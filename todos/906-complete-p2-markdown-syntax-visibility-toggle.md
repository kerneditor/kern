---
status: complete
priority: p2
issue_id: "906"
tags: [editor, ux, markdown, preferences]
dependencies: []
---

# Add markdown syntax visibility toggle

Add a user preference to toggle between current WYSIWYG rendering and a mode that shows raw markdown syntax markers for direct source editing.

## Problem Statement

Users currently cannot quickly switch to a syntax-visible view when they want to directly edit markdown markers (for example, brackets/parentheses in links, list markers, emphasis markers, fences, or heading hashes). This slows down power-user workflows and makes certain precise edits harder than in editors that offer a source-visible mode.

## Findings

- Current editor experience is WYSIWYG-first; syntax markers are mostly hidden after semantic conversion.
- Recent QA reports repeatedly surface edge cases where users want direct control over raw markdown syntax during editing.
- A preference-level toggle is the right UX shape because user intent differs by workflow (reading vs source authoring).

## Proposed Solutions

### Option 1: Global preference toggle (WYSIWYG <-> Syntax Visible)

**Approach:** Add a preferences setting and runtime toggle that changes rendering behavior in-place for the active document/editor.

**Pros:**
- Simple user model
- Minimal UI complexity
- Fast to ship

**Cons:**
- Coarse granularity (all docs use same mode)
- May require careful migration of typing attributes when switching modes

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Per-document/view toggle + persisted default

**Approach:** Add a per-window/per-document toggle, with a default preference for new windows.

**Pros:**
- More flexible for mixed workflows
- Better for side-by-side editing patterns

**Cons:**
- More state management complexity
- Higher testing matrix

**Effort:** Medium-Large

**Risk:** Medium

---

### Option 3: Temporary "show syntax while modifier held" mode

**Approach:** Hold a modifier key (or use command) to temporarily reveal syntax markers.

**Pros:**
- Very fast temporary inspection
- Keeps WYSIWYG as default behavior

**Cons:**
- Harder discoverability
- More implementation complexity in render pipeline

**Effort:** Large

**Risk:** Medium-High

## Recommended Action


## Technical Details

**Likely affected files (initial):**
- `KernApp/Sources/App/NativeEditorPreferencesWindowController.swift`
- `KernApp/Sources/Editor/NativeEditorViewController.swift`
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernApp/Sources/Editor/KernTextAttributes.swift`
- `KernTests/NativeEditorPreferencesTests.swift`
- `KernTests/NativeEditorNotionListBehaviorRegressionTests.swift`
- `KernTests/NativeMarkdownCodecTests.swift`

**Key design constraints:**
- Must preserve round-trip markdown fidelity
- Must not regress typing latency or open-ready behavior
- Must avoid style/attribute leakage when switching modes


## Phase Sequencing (907 merged)

- **Phase 1:** Global syntax-visibility toggle (preference + runtime switching + fidelity safeguards).
- **Phase 2:** Caret-proximate span expansion mode (links/emphasis/code reveal near caret) merged from issue 907.
- **Phase 3:** Optimization and polish (mode transitions, anti-leak guards, typing reliability/perf validation).

## Test Expansion Plan

- Add/extend preference tests:
  - `KernTests/NativeEditorPreferencesTests.swift`
  - verify default mode, persisted mode, runtime toggle application.
- Add mode-switch typing regressions:
  - `KernTests/NativeEditorNotionListBehaviorRegressionTests.swift`
  - link typing/editing after mode switch; list continuation/tab/backspace behavior unchanged.
- Add codec fidelity checks:
  - `KernTests/NativeMarkdownCodecTests.swift`
  - syntax-visible edits still round-trip without export drift.
- Expand matrix/stateful coverage:
  - `KernTests/NativeEditorTypingBehaviorMatrixCoverageTests.swift`
  - `KernTests/NativeEditorTypingStatefulSequenceTests.swift`
  - include transitions that toggle mode mid-sequence.
- Gate commands required for completion:
  - `./scripts/run-typing-behavior-gate.sh --lane pr`
  - `./scripts/test-markdown-spec-conformance.sh`

## Resources

- Merged scope from issue 907 (caret-proximate expansion).
- User request: add toggle to show markdown syntax for direct editing
- Related ongoing work: typing behavior reliability and link editing regressions

## Acceptance Criteria

- [x] Preference exists for syntax visibility mode
- [x] User can toggle without restarting app
- [x] In syntax-visible mode, markdown markers are editable directly
- [x] Switching modes preserves content fidelity (import/export round-trip unchanged)
- [x] No link-style leakage after mode switches and edits
- [x] Typing behavior gate passes
- [x] Relevant targeted tests added/updated and passing
- [x] Typing matrix + stateful sequences include mode-switch transition cases
- [x] Strict spec conformance remains green after feature merge

## Work Log

### 2026-03-04 - Todo created from user request

**By:** Codex

**Actions:**
- Created tracked todo for markdown syntax visibility toggle request.
- Captured approach options, risks, and acceptance criteria.

**Learnings:**
- This should be integrated with current typing-behavior quality gates to prevent regressions.

## Notes

- Priority is set to P2 because this is a major UX improvement and reliability aid for power users.


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

