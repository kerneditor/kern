---
title: Todo Portfolio Revalidation
date: 2026-03-06
scope:
  - TODO.md unchecked items
  - todos/ pending + complete status drift
  - current test/typing gate evidence
---

## Executive summary

- Revalidation completed against current branch state and fresh test runs.
- Main gates are green:
  - `./scripts/test-native-editor.sh` ✅ (322 executed, 0 failed, 78 skipped)
  - `./scripts/run-typing-behavior-gate.sh --lane pr` ✅ (44 executed, 0 failed)
- `TODO.md` was stale; it now has only **2** unchecked items (down from 10):
  - table editing/export UX depth
  - always-on snapshot gate
- File-based todo portfolio currently:
  - `complete`: 30
  - `pending`: 2 (`913`, `914`)

## Revalidation decisions

### 1) TODO.md items

| Item | Decision | Notes |
|---|---|---|
| Load local images async | **Close** | Already implemented in `MarkdownRichAttachments.loadImageIfNeeded` via background queue. |
| Numbered list behavior (Notion/GFM) | **Close** | Covered by regression/program/matrix suites; PR typing gate is green. |
| Task list behavior + hit target | **Close** | Marker/glyph hit target + ordered task behavior covered by tests and preferences. |
| Code block visuals/copy behavior | **Close (functional)** | Core behavior implemented/tested; visual polish continues via theme scope. |
| Preferences UI options | **Close** | Export dialect, numbering, syntax visibility, checkbox hit target, etc. implemented. |
| Fuzz/property editing tests | **Close** | Stateful + fuzz/differential style tests exist and pass in current suite. |
| Benchmark protocol/runners | **Close (re-scoped)** | Protocol documented and runners implemented for current roster. Legacy WebKit lane is deprecated. |
| Tables editing/export depth | **Keep Open** | Needs deeper row/column editing UX + additional export semantics coverage. |
| Always-on snapshot baseline gate | **Keep Open** | Snapshots exist, but gate is opt-in, not always-on by default. |

### 2) File todo portfolio

- Keep pending scope:
  - `913-pending-p2-theme-pack-and-custom-theme-support.md`
  - `914-pending-p2-theme-font-test-expansion.md`
- No additional P1 blocking regressions reproduced in this validation pass.

### 3) Status drift found in complete todos

16 `*-complete-*` todo files still contain unchecked acceptance boxes. This is metadata drift (documentation hygiene), not evidence of failing runtime behavior in this pass.

Affected IDs: `002, 004, 005, 006, 007, 008, 009, 010, 011, 015, 016, 906, 907, 908, 909, 910`

## Evidence pointers

- Local image async load:
  - `KernApp/Sources/Editor/MarkdownRichAttachments.swift`
- Typing/list/hybrid regression coverage:
  - `KernTests/NativeEditorNotionListBehaviorRegressionTests.swift`
  - `KernTests/NativeEditorNotionTypingBehaviorProgramTests.swift`
  - `KernTests/NativeEditorTypingBehaviorMatrixCoverageTests.swift`
  - `KernTests/NativeEditorHybridSyntaxModeTests.swift`
- Table overflow coverage:
  - `KernTests/NativeEditorTableOverflowTests.swift`
- Preferences surface:
  - `KernApp/Sources/App/NativeEditorPreferencesWindowController.swift`
- Test artifacts:
  - `test-results/native-editor/20260306-013653/`
  - `test-results/typing-behavior/20260306-013751-pr/`

## Recommended next execution order

1. `913` Theme packs + custom theme/font support.
2. `914` Theme/font test-matrix + snapshot expansion.
3. Table-editing/export depth (new dedicated todo from open `TODO.md` item).
4. Make snapshot verification always-on in CI lane (new dedicated todo from open `TODO.md` item).
5. Clean checklist drift in complete todos (one-time consistency pass).

---

## Completion addendum (2026-03-06, same session)

- All five queued follow-up todos were completed and renamed:
  - `913`, `914`, `915`, `916`, `917`
- Snapshot baselines were refreshed for updated rendering and new theme/font snapshot cases.
- Snapshot lane hardening fix applied:
  - `scripts/test-native-editor.sh` now clears `KERN_RECORD_SNAPSHOTS` before verify pass after a record run.
- Verification evidence:
  - `./scripts/test-native-editor.sh` ✅ (333 executed, 0 failed, 74 skipped)
  - `./scripts/run-typing-behavior-gate.sh --lane pr` ✅ (44 executed, 0 failed)
- Todo hygiene check:
  - `scripts/check-todo-complete-checklists.py` ✅ clean
- `TODO.md` checkboxes for table editing and always-on snapshot gate are now checked.
