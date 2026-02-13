# Native Editor Test Plan (TextKit WYSIWYG, No WebView)

This document defines an *exhaustive* (as in: systematically enumerated + generator-backed) test suite for Kern’s native TextKit-based Markdown WYSIWYG editor.

It is designed to be used agentically:
- run tests
- collect logs + screenshots
- localize failures
- implement fixes
- re-run targeted tests
- run full suite
- commit

## Scope

**System under test:** native editor prototype (AppKit `NSTextView` + `NativeMarkdownCodec`).

**Goals:**
- True WYSIWYG: users edit rendered semantics, not Markdown syntax.
- Deterministic `.md` export: save is stable and predictable.
- Editor behaviors match real-world expectations (Notion + GitHub Markdown editor as UX benchmarks; GFM/CommonMark as syntax ground truth).
- Regression safety: every fix adds/updates a test.

**Non-goals (for the test suite itself):**
- Proving full CommonMark compliance today. The suite can be broader than current implementation and gate future work.

## Test Layers

### 1) Unit: Codec Spec Tests

These tests validate Markdown import/export determinism and the attributed-string semantic encoding.

Files:
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernTests/NativeMarkdownCodecTests.swift`
- `KernTests/NativeEditorGoldenFixturesTests.swift`
- `KernTests/NativeMarkdownCodecIdempotencyTests.swift` (idempotence across option permutations)
- `KernTests/NativeMarkdownCodecFuzzTests.swift` (deterministic generator-backed fuzzing; exhaustive gate)

**Golden fixtures (generator-backed, preference-aware):**
- Inputs: `test-fixtures/native-editor-golden/*.in.md`
- Cases:
  - Legacy cases (auto-detected):
    - `*.gfm.out.md` (run with `exportDialect=gfm`, other options default)
    - `*.kern.out.md` (run with `exportDialect=kern`, other options default)
  - Extended cases:
    - `*.case.json` files next to the input
    - each case file specifies:
      - editor/export options (dialect + Kern-extension toggles)
      - an expected output file path (relative to the fixtures directory)

Rules:
- Every fixture must be stable across runs.
- Add fixtures whenever a bug is found.

### 2) Unit: Attribute Semantics Tests

Verify that import produces expected `kern.*` attributes:
- `.kernBlockKind` correct per paragraph
- `.kernMarker` spans only the marker region
- `.kernCheckbox` and `.kernCheckboxChecked` set only on the checkbox glyph
- `.kernHeadingLevel` stored for headings
- `.kernOrderedIndex` stored for ordered items

Purpose:
- ensures export doesn’t rely on fragile string heuristics
- avoids pixel-level snapshot flakiness

### 3) Unit: Editing Behavior (Input Rules + Newline Continuation)

Target behaviors (baseline: Notion-type “type to convert”; GitHub list continuation):
- typed markers convert to blocks (headings, bullets, ordered, tasks)
- Enter continues list when item has content
- Enter on an empty list item exits list (removes marker)
- Enter after heading exits to paragraph (resets typing attrs)
- Shift+Enter inserts a line break without list continuation (serialize as a Markdown hard break on export)

Implementation note:
- These are currently implemented inside `NativeEditorViewController` and should be extracted to testable pure functions as the suite grows.

### 4) UI: End-to-End Editor Tests (XCUITest)

Files:
- `KernUITests/NativeEditorE2ETests.swift`

Coverage:
- open a temp `.md`
- type shortcuts -> WYSIWYG conversion
- save -> disk contains expected markdown
- code block copy button copies correct text
- preference toggles via env vars (GFM default, Kern extensions optional)
- screenshots attached to `.xcresult` (kept on success by default for visual review; can opt-out for speed)
  - `KERN_UI_SCREENSHOTS=always|failure|off` (default: `always`)
  - `KERN_UI_SCREENSHOT_DIR=/path` (write PNGs to disk; runner sets this automatically)

KernTextKit is native-only (TextKit). There is no WebView editor path to force in tests.

### 5) Visual Confirmation

Two modes:

1. **UI test attachments** (today):
- each critical UI test attaches screenshots
- artifacts can be exported via `xcresulttool` (runner exports on failure by default; opt-in to always export)

2. **Snapshot regression** (planned):
- add deterministic AppKit view snapshots for:
  - checkbox rendering
  - code block styling
  - list marker alignment/wrapping
- store baselines under a dedicated directory
- add an explicit “record mode” to update baselines

Implemented (gated):
- `KernTests/NativeEditorSnapshotTests.swift` (SnapshotTesting)
- Env vars:
  - `KERN_ENABLE_SNAPSHOT_TESTS=1` to run
  - `KERN_RECORD_SNAPSHOTS=1` to record baselines
  - `KERN_ENABLE_EXHAUSTIVE_TESTS=1` to run the full snapshot matrix

### 6) Performance

Add performance tests for:
- import/export on large fixtures (`native-editor-benchmark.md`)
- render/layout cost for large fixtures (`NativeEditorViewController`)
- newline continuation/edit operations on long documents
- scroll performance (UI test + instrumentation)

### 7) Robustness / Security-Style Inputs

Even for a local editor, we want robustness against:
- very large files
- extremely deep nesting / indentation
- pathological inline markers (hundreds of `*`/`[`/backticks)
- invalid UTF-8 replacement characters
- mixed newlines (CRLF/LF)

## Running Tests

Unit tests:
```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit test
```

UI tests:
```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKitUI test
```

Recommended runner (collects xcresults + attachments):
```bash
./scripts/test-native-editor.sh
```
  - Always export UI attachments: `--export-ui-attachments` (or `KERN_EXPORT_UI_ATTACHMENTS=1`)
  - Export attachments after the fact:
    - `./scripts/export-xcresult-attachments.sh test-results/native-editor/<timestamp>/KernUI.xcresult`
  - Exhaustive UI matrix: `./scripts/test-native-editor.sh --ui-only --exhaustive`
  - Pixel-level snapshots: `./scripts/test-native-editor.sh --unit-only --snapshots`
  - Record snapshot baselines: `./scripts/test-native-editor.sh --unit-only --record-snapshots`

Non-UI benchmarks:
```bash
./scripts/bench-native-editor.sh
```

### UI Test “System Auth” / Permissions

UI tests can fail or hang if:
- the Mac is locked
- Xcode doesn’t have Automation permission to drive UI
- Accessibility permission prompts appear mid-run

When this happens:
- unlock the Mac
- re-run UI tests once to trigger prompts
- approve prompts, then re-run again

## Exhaustive Coverage Matrix (Planned)

This is the *inventory* of tests we will implement. Many of these will be skipped initially and enabled as features land.

### Blocks

- Paragraph
- Heading (H1-H6)
- Bullet list
- Ordered list
- Task list (standalone + bulleted + ordered)
- Blockquote
- Thematic break (`---`)
- Code block (fenced + indented)
- Tables (GFM) (import/export + TextKit render implemented; editing/navigation TBD)
- Images
- Horizontal scrolling blocks (tables/code)

For each block type, test:
- import -> WYSIWYG text + attributes
- typed creation (input rules)
- Enter behavior
- Backspace at start-of-block behavior
- export correctness
- round-trip idempotence

### Inline

- Strong / emphasis nesting
- Inline code
- Strikethrough (GFM)
- Links
- Autolinks
- Escapes

For each inline feature, test:
- parsing at boundaries (word edges)
- nested combinations
- copy/paste stability
- export escapes are correct and minimal

### Lists (GFM / CommonMark edge cases)

- tight vs loose lists
- blank line handling inside lists
- indentation rules for nested lists
- list-marker width interactions (`9.` vs `10.` vs `100.`)
- mixing bullets and ordered lists
- code blocks inside list items
- blockquotes inside list items

### Editor Behaviors

- undo/redo correctness
- selection formatting
- find/replace
- caret movement across markers
- paste of markdown text vs rich text
- IME composition (Korean) correctness

## Next Implementation Steps

1. Expand golden fixtures with list/task/code edge cases.
2. Add attribute-level assertions per fixture (not just export string equality).
3. Add a “future tests” mechanism (skip by default unless `KERN_ENABLE_EXHAUSTIVE_TESTS=1`).
4. Add optional snapshot testing for deterministic visual regression.
5. Add a log collector (app writes structured events to a file during UI tests).
