---
status: complete
priority: p3
issue_id: "014"
tags: [code-review, ui-tests, flakiness, native-editor]
dependencies: []
---

# UI tests rely on normalized coordinate clicks for checkbox toggling (potential flakiness)

## Problem Statement

UI tests toggle checkboxes by clicking a hard-coded normalized coordinate inside the text view. This can become flaky across different window sizes, font metrics, or content insets.

## Findings

- `KernUITests/NativeEditorE2ETests.swift:26-28` uses `coordinate(withNormalizedOffset: ...)` to click near the start of the line.
- Default product behavior is `checkboxHitTarget=glyph`; a near-start click may or may not land on the checkbox glyph depending on layout. (Today it likely works because the hit test maps to nearest glyph.)

## Proposed Solutions

### Option 1: Set checkbox hit-target to marker region for UI tests only

**Approach:**
- Add `app.launchEnvironment["KERN_NATIVE_CHECKBOX_HIT_TARGET"] = "marker"` in relevant UI tests.
- Keep product default as `glyph`.

**Pros:**
- Simple; reduces flake risk.

**Cons:**
- UI test no longer asserts the stricter "glyph-only" default behavior.

**Effort:** Small

**Risk:** Low

---

### Option 2: Compute a coordinate based on text layout (more robust)

**Approach:**
- Expose an accessibility element for the checkbox (hard in NSTextView), or add a test-only hook to click the checkbox reliably.

**Pros:**
- Tests the actual default behavior.

**Cons:**
- More engineering effort.

**Effort:** Medium

**Risk:** Medium

## Acceptance Criteria

- [x] UI tests have stable checkbox toggling across window sizes and appearances
- [x] If using test-only hit-target override, add a unit test that still verifies the default hit-target behavior separately

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Identified coordinate-based checkbox clicks as a common source of UI-test flakiness.


### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as obsolete: XCUI test target path referenced by this todo is no longer active.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
