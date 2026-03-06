---
title: Pending Todo Validation Gate
date: 2026-03-04
scope: pending todos (002,003,004,005,006,007,008,009,010,011,015,016,906)
---

## Method

For each pending todo:
1. Re-check current code and tests.
2. Use objective evidence (failing test, targeted passing test, code path evidence).
3. Classify as one of:
   - Confirmed Open
   - Fixed Already
   - Needs Research
   - Stale/Invalid

## Baseline run

- Command: `./scripts/test-native-editor.sh`
- Result: failed (32 failures)
- Key failing suites include:
  - `NativeEditorNotionListBehaviorRegressionTests`
  - `NativeEditorTypingBehaviorMatrixCoverageTests`
  - `NativeEditorNotionTypingBehaviorProgramTests`

These failures indicate additional active regressions not fully captured by current pending todo list.

## Classification table

| Todo | Status | Why |
|---|---|---|
| 002 | Confirmed Open | Working tree still has many untracked source/test/script files used by tracked code. |
| 003 | Fixed Already | Link label nested formatting export logic present and targeted tests pass. |
| 004 | Confirmed Open | Import path still splits on `\n` without full CRLF/CR normalization semantics. |
| 005 | Needs Research | Paragraph-vs-softbreak policy is still underspecified; behavior exists but spec contract is incomplete. |
| 006 | Fixed Already | Ordered task parser accepts marker-only case and targeted scenario test passes. |
| 007 | Confirmed Open | Selection clamp still mixed (`String.count` vs UTF-16 length) across code paths. |
| 008 | Confirmed Open | Inline formatting toggle path still rewrites fonts from base and can override block typography. |
| 009 | Needs Research | Shift+Enter style-carry expectation not explicitly specified/tested; likely behavior issue but contract needs explicit rule. |
| 010 | Confirmed Open | Spellcheck/autocorrect is globally enabled with no code-block selective disable path. |
| 011 | Confirmed Open | Code-block background colors still use fixed grayscale constants instead of dynamic appearance-aware mapping. |
| 015 | Confirmed Open | Heading font application still overrides inline rendering choices in headings. |
| 016 | Confirmed Open | Import/export remains on main-thread paths in editor controller/codec. |
| 906 | Confirmed Open | Markdown syntax visibility toggle + hybrid caret-proximate mode not implemented in preferences/runtime/tests. |

## Evidence pointers

- Untracked files + references:
  - `KernApp/Sources/Editor/NativeEditorAppearance.swift`
  - `KernApp/Sources/Editor/NativeEditorViewController.swift`
- Link export formatting tests:
  - `KernTests/NativeMarkdownCodecGfmMarkerCompatibilityTests.swift`
  - `KernTests/NativeEditorBulletTaskInputRuleTests.swift`
- Core implementation evidence:
  - `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
  - `KernApp/Sources/Editor/NativeMarkdownTextView.swift`
  - `KernApp/Sources/App/NativeEditorPreferencesWindowController.swift`
  - `KernTests/NativeEditorPreferencesTests.swift`

## Immediate actions

1. Close/move to complete: 003, 006.
2. Keep open and prioritize: 002, 004, 007, 008, 010, 015, 016, 906.
3. Resolve spec first, then implement: 005, 009.
4. Add new todo(s) for currently failing list/link typing regressions observed in baseline suite.


## Follow-up actions completed (2026-03-04)

- Closed as fixed already:
  - `003` → `003-complete-p2-link-export-drops-inline-styles.md`
  - `006` → `006-complete-p2-ordered-task-marker-parsing-empty-text.md`
- Performed external research for prior "Needs Research" items:
  - `005` paragraph vs soft-break semantics now documented with explicit recommendation.
  - `009` Shift+Enter style-carry policy now documented with explicit recommendation.
- Added missing regression todos discovered in baseline suite:
  - `908-pending-p1-inline-link-conversion-regression-across-contexts.md`
  - `909-pending-p1-nested-list-continuation-and-conversion-regressions.md`
  - `910-pending-p2-paste-undo-redo-in-task-context-breaks-typing-continuation.md`
