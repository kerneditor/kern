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
- Full-spec case matrix (250+ generator-backed cases, expected-to-fail until implemented): `KernTests/NativeMarkdownCodecFullSpecCaseMatrixTests.swift`
- UI E2E (menus, clicking, typing, screenshots): `KernUITests/NativeEditorE2ETests.swift`
- Visual regression (optional): `KernTests/NativeEditorSnapshotTests.swift`

## Test Inventory (What Exists Today)

Smoke / always-on (fast correctness for supported subset):
- `KernTests/NativeMarkdownCodecTests.swift` (basic round-trip + tables)
- `KernTests/NativeMarkdownCodecAttributeTests.swift` (semantic attrs: checkbox + checked strike)
- `KernTests/NativeMarkdownCodecOptionsTests.swift` (preference branches: dialect, numbering, export strategies)
- `KernTests/NativeMarkdownCodecTableParsingTests.swift` (table import semantics)
- `KernTests/NativeEditorGoldenFixturesTests.swift` (fixture-driven round-trip)
- `KernTests/NativeMarkdownCodecIdempotencyTests.swift` (property-style stability across option permutations)
- `KernTests/NativeFindEngineTests.swift` (native find/replace engine)
- `KernTests/EditorDocumentTests.swift` (document/file IO)
- `KernTests/AnchorNavigationTests.swift` (in-document `#anchor` click/jump behavior)
- `KernTests/StressFixturesSanityTests.swift` (fixtures contain required feature sections + local assets exist)

Exhaustive / expected-to-fail until full spec is implemented:
- `KernTests/NativeMarkdownCodecFullSpecCaseMatrixTests.swift` (250+ cases across GFM/CommonMark edge patterns)
- `KernTests/NativeMarkdownCodecFutureSpecTests.swift` (hand-picked "obviously missing" full-spec features: images/mermaid/math/etc)
- `KernTests/NativeMarkdownCodecGfmMarkerCompatibilityTests.swift` (marker compatibility + in-doc anchor links)
- `KernTests/NativeMarkdownCodecFuzzTests.swift` (deterministic fuzz; generator-backed)
- `KernTests/NativeEditorStressFixtureFullSpecTests.swift` (integration spec: stress-test.md must import as WYSIWYG + export stable)
- `KernTests/NativeEditorCheckboxLayoutMetricSpecTests.swift` (pixel-level checkbox alignment + sizing)
- `KernTests/NativeEditorCodeBlockChromeSpecTests.swift` (code block chrome: language label, syntax highlight, copied feedback, placement)

Snapshots (visual regression; gated):
- `KernTests/NativeEditorSnapshotTests.swift` (AppKit view snapshots; record + verify modes)

Perf / benchmarks (gated behind `KERN_ENABLE_PERF_TESTS=1`):
- `KernTests/NativeMarkdownCodecPerformanceTests.swift` (import/export perf on benchmark fixture)
- `KernTests/NativeEditorRenderPerformanceTests.swift` (render/layout perf on benchmark fixture)
- `KernTests/NativeEditorMegaStressPerformanceTests.swift` (mega-stress render/scroll + incremental typing perf)

UI E2E (interaction; screenshots always attached by default):
- `KernUITests/NativeEditorE2ETests.swift`

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
| Code chrome (full spec) | Language label, syntax highlighting, copy feedback, correct placement | `NativeEditorCodeBlockChromeSpecTests` (gated) | None yet | Expected-failure until implemented |
| Tables (GFM) | `| a | b |` imports as real table (borders + alignment); export canonical table markdown | `tables.*` fixture | `testTypedTableConvertsAndExportsGfmTable`, `testOpenFileWithGfmTableRendersWysiwygAndExportsStable` (+ matrix includes table round-trip) | Rendered via TextKit `NSTextTableBlock` |
| File reload on disk change | External write triggers reload + toast; editor updates content | (N/A) | `testReloadOnDiskChangeShowsToastAndUpdatesContent` | Toast is labeled `NativeEditor.ReloadToast` for UI assertions |
| In-document anchors | Clicking `[Text](#anchor)` jumps within the document (no OSStatus errors) | `AnchorNavigationTests` | (optional; UI later) | Jump toast uses `NativeEditor.JumpToast` |
| Find / Replace | Find bar is native + testable; replace mutates document deterministically | (N/A) | `testFindReplaceReplacesMatchesInOrder` | Find UI is `NativeEditor.FindBar` (no system Find panel dependency) |
| Checkbox click hit-target | Clicking checkbox glyph toggles; optional marker-region toggles | options tests | `testCheckboxHitTargetGlyphTogglesByClick` (gated), `testCheckboxHitTargetMarkerTogglesWhenEnabled` (gated) | Coordinate-based clicks can be flaky; gated behind exhaustive UI |
| Visual regression | Stable rendering across changes | Snapshot tests (gated) | UI screenshots attached always | Enable with `./scripts/test-native-editor.sh --unit-only --snapshots` |
| Full Markdown features (full spec) | Blockquotes, HR, images, strikethrough, autolinks, nested lists, math, mermaid, etc. | `NativeMarkdownCodecFullSpecCaseMatrixTests` + `NativeMarkdownCodecFutureSpecTests` (gated + expected-failure) | None yet | Enable with `./scripts/test-native-editor.sh --unit-only --exhaustive` |
| Stress fixture (full spec) | `stress-test.md` must import as true WYSIWYG + export stable | `NativeEditorStressFixtureFullSpecTests` (gated + expected-failure) | None yet | Ensures "ultimate" fixture actually drives development |

## Known Gaps (Missing Tests / Not Yet Implemented)

These are called out in `docs/plans/native-editor-test-suite.md` and should graduate into either:
- a unit test (preferred, fast), or
- a UI E2E test (only when interaction is inherently UI-only).

- Backspace at start-of-list/task/ordered should “unlist” the block (`todos/017-*` tracks this)
- Undo/redo correctness across conversions and checkbox toggles (unit + UI)
- External link clicking behavior should open via a safe policy (likely behind a preference)
- Table editing navigation (arrow keys, tab/shift-tab, enter, selection across cells)
- Copy button UX (language label, “Copied” feedback, placement) is covered by full-spec tests but not implemented
- Syntax highlighting for code blocks (full-spec test exists; implementation missing)
- Images / Mermaid / Math rendering (full-spec tests exist; implementation missing)

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
  - `./scripts/test-native-editor.sh --unit-only --snapshots`
  - Record baselines (writes `KernTests/__Snapshots__/*`): `./scripts/test-native-editor.sh --unit-only --record-snapshots`
  - Exhaustive snapshot matrix: add `--exhaustive`
  - Direct (advanced): `xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKitSnapshots test`
