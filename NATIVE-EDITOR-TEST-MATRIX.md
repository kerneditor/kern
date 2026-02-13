# Native Editor Test Matrix (Coverage Inventory)

This is the canonical inventory of the native (no WebView) editor test suite: what we test, where we test it, and what remains.

Defaults (per your prefs):
- Export dialect default: `gfm`
- Kern extensions: optional settings (still tested)
- Ordered list numbering default: `gfmDefault` (sequential normalization), optional `preserveTyped`
- Shift+Enter: line break inside the same block/list item (Notion/GitHub-style)

## Test Layers

- Golden fixtures (import -> attributed -> export): `KernTests/NativeEditorGoldenFixturesTests.swift`
- Unit option/attribute specs: `KernTests/NativeMarkdownCodec*Tests.swift`
- UI E2E (menus, clicking, typing, screenshots): `KernUITests/NativeEditorE2ETests.swift`
- Visual regression (optional): `KernTests/NativeEditorSnapshotTests.swift`

## Preferences Under Test

Preferences are controlled via:
- Unit tests: `NativeMarkdownCodec.Options(...)`
- UI tests: env vars consumed in `KernApp/Sources/App/main.swift`
  - `KERN_NATIVE_EXPORT_DIALECT=gfm|kern`
  - `KERN_NATIVE_GFM_EXTENSION_EXPORT=preserve|portable|lint`
  - `KERN_NATIVE_TASK_RENDERING=gfm|kern`
  - `KERN_NATIVE_ORDERED_TASKS=0|1`
  - `KERN_NATIVE_HEADING_CHECKBOXES=0|1`
  - `KERN_NATIVE_ORDERED_NUMBERING=gfmDefault|preserveTyped`
  - `KERN_NATIVE_CHECKBOX_HIT_TARGET=glyph|marker`

## Coverage Matrix

| Area | What “Correct” Means | Unit/Golden Coverage | UI Coverage | Notes |
|---|---|---|---|---|
| Headings H1-H6 | Syntax hidden in editor; exports stable `#` markdown | `basic.*` fixture | `testHeadingExitsToParagraphOnEnter` | |
| Bullets | `- ` imported as bullet; Enter continues; empty exits | `basic.*` fixture | `testBulletListContinuesAndExitsOnBlankItem` | |
| Ordered lists | Enter continues; empty exits; numbering preference works | `ordered-numbering.*` fixture + options tests | `testOrderedListAutoContinues` | |
| Tasks (GFM) | `- [ ]` imported; checkbox toggles; exports `- [ ]` | `basic.*` fixture + options tests | `testTodoShortcutConvertsAndExportsMarkdown` | |
| Tasks (standalone shortcut) | `[] ` becomes checkbox; export depends on dialect | `extensions.*` fixture + options tests | `testKernDialectExportsStandaloneTasksAsBracketOnly` | |
| Task rendering style | Bulleted tasks optionally show `• ☐` in WYSIWYG | options tests | `testTaskRenderingKernShowsBulletDotForBulletedTasks` | Rendering-only preference (export unchanged) |
| Ordered tasks (Kern option) | `1. [ ]` treated as ordered task when enabled | `extensions.*` fixture + options tests | `testOrderedTasksEnabledRendersAndExportsOrderedTasks` | Toggle-by-click for ordered tasks is not fully covered yet |
| Heading checkboxes (Kern option) | `## [ ]` treated as heading checkbox when enabled | `extensions.*` fixture + options tests | `testHeadingCheckboxesEnabledRendersAndExportsHeadingTasks` | Toggle-by-click for heading checkboxes is not fully covered yet |
| Soft line breaks | Shift+Enter creates in-item line break (export uses hard breaks + indents) | `soft-breaks.*` fixture | `testShiftEnterInBulletDoesNotContinueList` | |
| Code fences | Fenced blocks render monospaced + background; export fences | `basic.*` fixture | `testCodeBlockCopyButtonCopiesWholeBlock` | Copy button tested; styling snapshot gated |
| Tables (GFM) | `| a | b |` imports as real table (borders + alignment); export canonical table markdown | `tables.*` fixture | `testTypedTableConvertsAndExportsGfmTable` (+ matrix includes table round-trip) | Rendered via TextKit `NSTextTableBlock` |
| Visual regression | Stable rendering across changes | Snapshot tests (gated) | UI screenshots attached always | Enable with `KERN_ENABLE_SNAPSHOT_TESTS=1` |
| Future Markdown features | Blockquotes, images, strikethrough, autolinks, nested lists, etc. | `KernTests/NativeMarkdownCodecFutureSpecTests.swift` (gated + expected-failure) | None yet | Enable with `KERN_ENABLE_EXHAUSTIVE_TESTS=1` |

## Running

- Full unit suite (includes golden fixtures): `./scripts/test-native-editor.sh --unit-only`
- Full UI suite: `./scripts/test-native-editor.sh --ui-only`
  - Default screenshot mode: keep on success (for visual review)
  - Faster modes:
    - `KERN_UI_SCREENSHOTS=failure` (keep only on failures)
    - `KERN_UI_SCREENSHOTS=off` (disable screenshots)
  - Export attachments (pngs/logs) to disk:
    - pass `--export-ui-attachments` or set `KERN_EXPORT_UI_ATTACHMENTS=1`
    - or run: `./scripts/export-xcresult-attachments.sh test-results/native-editor/<ts>/KernUI.xcresult`
  - UI screenshots are also written to disk during the run:
    - `test-results/native-editor/<ts>/ui-screenshots/` (via `KERN_UI_SCREENSHOT_DIR`)
  - Exhaustive UI matrix:
    - `./scripts/test-native-editor.sh --ui-only --exhaustive`
- Snapshots (optional):
  - `KERN_ENABLE_SNAPSHOT_TESTS=1 xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit test`
  - `KERN_ENABLE_SNAPSHOT_TESTS=1 KERN_RECORD_SNAPSHOTS=1 xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit test`
