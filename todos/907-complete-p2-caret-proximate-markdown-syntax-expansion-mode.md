---
status: complete
priority: p2
issue_id: "907"
tags: [editor, ux, markdown, preferences, typing]
dependencies: []
---

# Add caret-proximate markdown syntax expansion mode

Add a preference mode where markdown span syntax expands near the caret (hybrid source/rendered editing), while keeping current WYSIWYG mode available.

## Problem Statement

Power users often need direct source-level edits for inline markdown spans (links, emphasis, code, etc.) but still want rendered readability most of the time. Current behavior is WYSIWYG-first and does not offer a caret-proximate syntax expansion experience.

## Findings

- User requested this as a preference-mode feature.
- Existing roadmap already tracks a global syntax visibility toggle (todo #906).
- Caret-proximate expansion is complementary (finer-grained than a full source-visible mode).

## Proposed Solutions

### Option 1: Inline span expansion near caret (preferred)

**Approach:** On caret enter/focus for inline semantic runs, reveal corresponding markdown syntax tokens for that span only; collapse back on caret leave.

**Pros:**
- Keeps document readable
- Enables precise inline syntax edits
- Closer to hybrid editor UX expectations

**Cons:**
- Higher state complexity at boundaries/selections
- Needs strict anti-leak typing attribute safeguards

**Effort:** Medium-Large

**Risk:** Medium

---

### Option 2: Per-line expansion near caret

**Approach:** Reveal markdown syntax for the active line instead of just the active span.

**Pros:**
- Simpler than token-level transitions
- More discoverable behavior

**Cons:**
- More visual churn
- Potentially noisier than span-only model

**Effort:** Medium

**Risk:** Medium

## Recommended Action

Merged into issue 906 as Phase 2 (caret-proximate syntax expansion after baseline syntax-visible mode).


## Technical Details

**Likely affected files:**
- `KernApp/Sources/Editor/NativeEditorViewController.swift`
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernApp/Sources/Editor/KernTextAttributes.swift`
- `KernApp/Sources/App/NativeEditorPreferencesWindowController.swift`
- `KernTests/NativeEditorNotionListBehaviorRegressionTests.swift`
- `KernTests/NativeEditorTypingBehaviorMatrixCoverageTests.swift`
- `KernTests/NativeMarkdownCodecTests.swift`

## Test Expansion Plan

- Add span-boundary expansion/collapse tests:
  - `KernTests/NativeEditorNotionListBehaviorRegressionTests.swift`
  - caret enter/leave, selection expand/shrink, delete/retype near link/emphasis/code spans.
- Add caret-proximate rendering unit checks:
  - `KernTests/NativeMarkdownCodecTests.swift`
  - ensure markdown tokens reappear only for active span context and collapse correctly.
- Add cross-context typing behavior coverage:
  - `KernTests/NativeEditorTypingBehaviorMatrixCoverageTests.swift`
  - `KernTests/NativeEditorNotionTypingBehaviorProgramTests.swift`
  - cover paragraph/bullet/ordered/task/nested contexts with span expansion enabled.
- Add reliability + no-leak assertions:
  - `.link` / underline / destination attrs never leak beyond active span after collapse.
- Gate commands required for completion:
  - `./scripts/run-typing-behavior-gate.sh --lane pr`
  - `./scripts/test-native-editor.sh`
  - `./scripts/test-markdown-spec-conformance.sh`

## Resources

- User request: hybrid model where markdown span expands near caret, as preference setting.
- Related todo: `906-pending-p2-markdown-syntax-visibility-toggle.md`

## Acceptance Criteria

- [x] Preference exists to enable/disable caret-proximate syntax expansion
- [x] Inline spans (links/emphasis/code) expand syntax near caret and collapse when leaving
- [x] Round-trip export fidelity remains unchanged
- [x] No link/style leakage after expand/collapse transitions
- [x] Typing behavior gate passes
- [x] Regression tests cover span-boundary editing and mixed list contexts
- [x] Typing matrix/program tests include caret-proximate mode permutations
- [x] Strict spec conformance remains green after feature merge

## Work Log

### 2026-03-04 - Todo created from user request

**By:** Codex

**Actions:**
- Added tracked todo for hybrid caret-proximate syntax expansion mode.
- Captured option space, risks, and acceptance criteria.

**Learnings:**
- This should be developed together with #906 to avoid overlapping mode-state complexity.

## Notes

- Keep existing WYSIWYG behavior as default unless user changes preference.

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as merged into todo 906 (Phase 2).

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
