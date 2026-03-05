---
status: complete
priority: p2
issue_id: "913"
tags: [editor, ux, theme, fonts, preferences]
dependencies: []
---

# Expand theme system to popular presets + custom theme/font support

## Problem Statement

Current implementation ships only baseline theme modes (System, Kern Dark, Kern Light) and basic font design/size toggles. This does not satisfy the requested scope for multiple popular editor themes, custom theme creation, and richer font customization.

## Findings

- Requested scope included broader theme parity versus popular markdown editors.
- Current preferences expose only:
  - 3 theme modes
  - 4 font-design presets
  - fixed point-size list
- “theme system hardening” was marked complete in planning docs, but broad theme-pack/custom-theme scope is still open.

## Proposed Solutions

### Option 1: Theme pack + custom JSON theme files (preferred)

**Approach:** Add bundled preset themes (e.g., GitHub-like Dark/Light, Solarized variants, Dracula-like) and user-importable custom themes (JSON schema with live preview + validation).

**Pros:**
- Matches user expectation for practical theme variety.
- Allows future theme sharing/import without app rebuild.
- Enables deterministic tests against theme tokens.

**Cons:**
- Requires schema/versioning and migration handling.
- More UI state and validation paths.

**Effort:** Medium-Large  
**Risk:** Medium

---

### Option 2: Presets-only (no custom theme files)

**Approach:** Ship a larger set of built-in themes and defer custom theme import/export.

**Pros:**
- Faster to ship.
- Lower risk than custom file parsing.

**Cons:**
- Still misses explicit custom-theme requirement.
- Less extensible.

**Effort:** Medium  
**Risk:** Low-Medium

## Technical Details

**Likely affected files:**
- `KernApp/Sources/Editor/NativeEditorAppearance.swift`
- `KernApp/Sources/App/NativeEditorPreferencesWindowController.swift`
- `KernApp/Sources/Editor/NativeEditorViewController.swift`
- `KernTests/NativeEditorAppearanceTests.swift`
- `KernTests/NativeEditorPreferencesTests.swift`

## Acceptance Criteria

- [x] Add at least 6 bundled theme presets (light + dark families).
- [x] Add custom theme import path with schema validation and fallback behavior.
- [x] Add richer font selection (named families + custom family fallback).
- [x] Preferences apply live to open documents without relaunch.
- [x] Add regression tests for theme token mapping and persistence.
- [x] No measurable typing-latency regression in PR typing gate.

## Work Log

### 2026-03-06 - Re-opened scope as pending todo

**By:** Codex  
**Actions:**
- Re-opened unimplemented theme scope that was previously treated as complete in high-level planning.

### 2026-03-06 - Implemented theme pack + custom theme/font support

**By:** Codex  
**Actions:**
- Expanded appearance presets to include major dark/light families and custom mode.
- Added custom theme JSON import with schema validation + graceful fallback.
- Added richer font family preset support (including custom family fallback).
- Wired preference changes to live-apply on open editors.
- Verified through full native suite + typing gate.
