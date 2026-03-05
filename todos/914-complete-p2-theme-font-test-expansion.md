---
status: complete
priority: p2
issue_id: "914"
tags: [editor, testing, theme, fonts, regression]
dependencies: ["913"]
---

# Expand automated tests for theme/font behavior and visual regressions

## Problem Statement

Theme/font coverage is currently shallow relative to requested UX scope. We need stronger automated tests so new theme/font features do not regress rendering, readability spacing, or clipboard/typing behavior.

## Findings

- Existing typing gates are strong for behavior but not comprehensive for theme permutations.
- Theme/font preference combinations need matrix and snapshot coverage.

## Proposed Solutions

### Option 1: Matrix + snapshot suite for theme/font permutations (preferred)

**Approach:** Add deterministic test matrix over theme × font-family × size × syntax-visibility modes, with targeted snapshots and attribute assertions.

**Pros:**
- Prevents silent visual regressions.
- Gives confidence for richer theme pack rollout.

**Cons:**
- More baseline artifacts to manage.

**Effort:** Medium  
**Risk:** Low-Medium

## Technical Details

**Likely affected files:**
- `KernTests/NativeEditorAppearanceTests.swift`
- `KernTests/NativeEditorPreferencesTests.swift`
- `KernTests/NativeEditorSnapshotTests.swift`
- `scripts/test-native-editor.sh`

## Acceptance Criteria

- [x] Add theme/font permutation matrix tests with deterministic assertions.
- [x] Add focused snapshot baselines for top preset themes.
- [x] Verify copy/paste and typing attributes remain stable across theme switches.
- [x] Ensure full typing gate remains green after test expansion.

## Work Log

### 2026-03-06 - Created pending test-expansion todo

**By:** Codex  
**Actions:**
- Added explicit pending item for theme/font test-depth expansion tied to theme implementation scope.

### 2026-03-06 - Expanded theme/font test depth and baselines

**By:** Codex  
**Actions:**
- Added expanded appearance + preference tests for theme/font persistence and live rerender behavior.
- Added theme/font snapshot lane (`testThemeAndFontPresetSnapshots`) and recorded baselines.
- Updated default test lane to run snapshots by default and validated no typing behavior regressions.
- Verified with `./scripts/test-native-editor.sh` and `./scripts/run-typing-behavior-gate.sh --lane pr`.
