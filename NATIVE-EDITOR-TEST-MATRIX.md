# Native Editor Test Matrix (Coverage Inventory)

This is the canonical inventory of the native (no WebView) editor test suite: what we test, where we test it, and what remains.

Defaults (per your prefs):
- Export dialect default: `gfm`
- Kern extensions: optional settings (still tested)
- Strict spec conformance lane: runs with Kern extensions disabled (`orderedTasksEnabled=0`, `headingCheckboxesEnabled=0`)
- Ordered list numbering default: `gfmDefault` (sequential normalization), optional `preserveTyped`
- Shift+Enter: line break inside the same block/list item (Notion/GitHub-style)

## Test Layers

- Golden fixtures (import -> attributed -> export): `KernTests/NativeEditorGoldenFixturesTests.swift`
- Unit option/attribute specs: `KernTests/NativeMarkdownCodec*Tests.swift`
- Full-spec case matrix (250+ generator-backed cases, expected-to-fail until implemented): `KernTests/NativeMarkdownCodecFullSpecCaseMatrixTests.swift`
- Strict Markdown spec conformance (official corpora; Kern extensions explicitly separated): `KernTests/NativeMarkdownSpecConformanceTests.swift`
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
- `KernTests/NativeFindReplaceIntegrationTests.swift` (find/replace UI wiring + behavior; no Accessibility needed)
- `KernTests/EditorDocumentTests.swift` (document/file IO)
- `KernTests/AnchorNavigationTests.swift` (in-document `#anchor` click/jump behavior)
- `KernTests/StressFixturesSanityTests.swift` (fixtures contain required feature sections + local assets exist)

Exhaustive / expected-to-fail until full spec is implemented:
- `KernTests/NativeMarkdownCodecFullSpecCaseMatrixTests.swift` (250+ cases across GFM/CommonMark edge patterns)
- `KernTests/NativeMarkdownCodecFutureSpecTests.swift` (hand-picked "obviously missing" full-spec features: images/mermaid/math/etc)
- `KernTests/NativeMarkdownCodecGfmMarkerCompatibilityTests.swift` (marker compatibility + in-doc anchor links)
- `KernTests/NativeMarkdownCodecFuzzTests.swift` (deterministic fuzz; generator-backed)
- `KernTests/NativeEditorStressFixtureFullSpecTests.swift` (integration spec: stress-test.md must import as WYSIWYG + export stable)
- `KernTests/NativeEditorMegaStressTypingMatrixTests.swift` (live typing: full mega char-by-char + ultimate permutation matrix + mega all-profile matrix [gated] + interleaved action programs + action permutations)
- `KernTests/NativeEditorCheckboxLayoutMetricSpecTests.swift` (pixel-level checkbox alignment + sizing)
- `KernTests/NativeEditorMarkerAlignmentMetricSpecTests.swift` (pixel-level marker alignment: bullets + ordered + bulleted-tasks)
- `KernTests/NativeEditorCodeBlockChromeSpecTests.swift` (code block chrome: language label, syntax highlight, copied feedback, placement)
- `KernTests/NativeMarkdownSpecConformanceTests.swift` (official CommonMark + cmark-gfm fixtures, semantic HTML oracle via `cmarkgfm`; strict profile disables Kern extensions)

Snapshots (visual regression; gated):
- `KernTests/NativeEditorSnapshotTests.swift` (AppKit view snapshots; record + verify modes)

Perf / benchmarks (gated behind `KERN_ENABLE_PERF_TESTS=1`):
- `KernTests/NativeMarkdownCodecPerformanceTests.swift` (import/export perf on benchmark fixture)
- `KernTests/NativeEditorRenderPerformanceTests.swift` (render/layout perf on benchmark fixture)
- `KernTests/NativeEditorMegaStressPerformanceTests.swift` (stress/ultimate/mega render + mega scroll + incremental typing + ultimate/mega char-by-char + ultimate/mega interleaved action bursts)

## Preferences Under Test

Preferences are controlled via:
- Unit tests: `NativeMarkdownCodec.Options(...)`

## Coverage Matrix

| Area | What "Correct" Means | Unit/Golden Coverage | Notes |
|---|---|---|---|
| Headings H1-H6 | Syntax hidden in editor; exports stable `#` markdown | `basic.*` fixture | |
| Bullets | `- ` imported as bullet; Enter continues; empty exits | `basic.*` fixture | |
| Ordered lists | Enter continues; empty exits; numbering preference works | `ordered-numbering.*` fixture + options tests | |
| Tasks (GFM) | `- [ ]` imported; checkbox toggles; exports `- [ ]` | `basic.*` fixture + options tests | |
| Tasks (standalone shortcut) | `[] ` becomes checkbox; export depends on dialect | `extensions.*` fixture + options tests | |
| Task rendering style | Bulleted tasks optionally show `• ☐` in WYSIWYG | options tests | Rendering-only preference (export unchanged) |
| Ordered tasks (Kern option) | `1. [ ]` treated as ordered task when enabled | `extensions.*` fixture + options tests | Toggle-by-click for ordered tasks is not fully covered yet |
| Heading checkboxes (Kern option) | `## [ ]` treated as heading checkbox when enabled | `extensions.*` fixture + options tests | Toggle-by-click for heading checkboxes is not fully covered yet |
| Soft line breaks | Shift+Enter creates in-item line break (export uses hard breaks + indents) | `soft-breaks.*` fixture | |
| Code fences | Fenced blocks render monospaced + background; export fences | `basic.*` fixture | Copy button tested; styling snapshot gated |
| Code chrome (full spec) | Language label, syntax highlighting, copy feedback, correct placement | `NativeEditorCodeBlockChromeSpecTests` (gated) | Expected-failure until implemented |
| Tables (GFM) | `| a | b |` imports as real table (borders + alignment); export canonical table markdown | `tables.*` fixture | Rendered via TextKit `NSTextTableBlock` |
| File reload on disk change | External write triggers reload + toast; editor updates content | (N/A) | Toast is labeled `NativeEditor.ReloadToast` for UI assertions |
| In-document anchors | Clicking `[Text](#anchor)` jumps within the document (no OSStatus errors) | `AnchorNavigationTests` | Jump toast uses `NativeEditor.JumpToast` |
| Find / Replace | Find bar is native + testable; replace mutates document deterministically | `NativeFindEngineTests`, `NativeFindReplaceIntegrationTests` | Find UI is `NativeEditor.FindBar` (no system Find panel dependency) |
| Checkbox click hit-target | Clicking checkbox glyph toggles; optional marker-region toggles | options tests | Coordinate-based clicks can be flaky; gated behind exhaustive |
| Visual regression | Stable rendering across changes | Snapshot tests (gated) | Enable with `./scripts/test-native-editor.sh --snapshots` |
| Full Markdown features (full spec) | Blockquotes, HR, images, strikethrough, autolinks, nested lists, math, mermaid, etc. | `NativeMarkdownCodecFullSpecCaseMatrixTests` + `NativeMarkdownCodecFutureSpecTests` (gated + expected-failure) | Enable with `./scripts/test-native-editor.sh --exhaustive` |
| Stress fixture (full spec) | `stress-test.md` must import as true WYSIWYG + export stable | `NativeEditorStressFixtureFullSpecTests` (gated + expected-failure) | Ensures "ultimate" fixture actually drives development |
| Live typing permutation matrix | Character-by-character typing + action permutations across preference combinations | `NativeEditorMegaStressTypingMatrixTests` (gated) | Primary exhaustive engine loop |

## Known Gaps (Missing Tests / Not Yet Implemented)

These are called out in `docs/plans/native-editor-test-suite.md` and should graduate into unit tests.

- Backspace at start-of-list/task/ordered should “unlist” the block (`todos/017-*` tracks this)
- Undo/redo correctness across conversions and checkbox toggles
- External link clicking behavior should open via a safe policy (likely behind a preference)
- Table editing navigation (arrow keys, tab/shift-tab, enter, selection across cells)
- Copy button UX (language label, “Copied” feedback, placement) is covered by full-spec tests but not implemented
- Syntax highlighting for code blocks (full-spec test exists; implementation missing)
- Images / Mermaid / Math rendering (full-spec tests exist; implementation missing)

## Running

- Full unit suite (includes golden fixtures): `./scripts/test-native-editor.sh`
- Strict spec conformance lane (official CommonMark + GFM fixtures):
  - `./scripts/test-markdown-spec-conformance.sh`
  - optional bounds: `--mode commonmark|gfm|all`, `--limit N`, `--section-regex REGEX`
- Full orchestrated exhaustive + benchmark run:
  - `./scripts/run-exhaustive-native-suite.sh`
- Ultra matrix mode (all-profile mega permutation run + shardable):
  - `./scripts/test-native-editor.sh --exhaustive --ultra`
- Ultra full mode (runs all profiles/programs in mega matrix; very slow):
  - `./scripts/test-native-editor.sh --exhaustive --ultra-full`
  - Optional sharding:
    - `KERN_EXHAUSTIVE_PROFILE_SHARD_COUNT=N`
    - `KERN_EXHAUSTIVE_PROFILE_SHARD_INDEX=I`
- Snapshots (optional):
  - `./scripts/test-native-editor.sh --snapshots`
  - Record baselines (writes `KernTests/__Snapshots__/*`): `./scripts/test-native-editor.sh --record-snapshots`
  - Exhaustive snapshot matrix: add `--exhaustive`
  - Direct (advanced): `xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKitSnapshots test`
