# Native Editor Test Suite v2 (Full-Spec, Pixel-Level, Perf)

This is the canonical plan for **KernTextKit’s** native (no WebView) Markdown WYSIWYG test suite.

If you are an agent working in this repo: read this file first, then follow it.

## Goal

Build a test suite that:

- **Fails when features are missing** (so we can’t fool ourselves with “green tests, broken app”).
- Tests **correctness**, **WYSIWYG UX rules**, **export determinism**, **pixel-level alignment**, and **performance**.
- Enumerates **preference permutations** and **edge cases** systematically (generator-backed), not by hand.
- Produces **high-signal artifacts** (screenshots, snapshots, dumps, logs) that an agent can read and act on.

## Ground Rules / Definitions

- “True WYSIWYG” means: the *editing surface* shows and manipulates **rendered semantics**, not raw Markdown syntax.
  - Syntax may exist in a “source mode”, but **WYSIWYG is the default**.
- **Default compatibility** is GitHub Flavored Markdown (GFM).
  - Kern extensions exist, but are optional and must be tested as an explicit setting.
- A “full” test suite must cover:
  - Import: `.md` -> attributed model/layout
  - Editing rules: typing, enter/backspace behaviors, toggles, selection
  - Export: model -> `.md` (stable + deterministic)
  - Rendering: visual appearance + layout (pixel-level)
  - Scale/perf: open/scroll/edit on huge docs

## Test Tiers (Fast -> Slow)

We will maintain three tiers and run them differently:

1. **Smoke (fast, always-green)**: validates the currently supported subset.
2. **Full Spec (exhaustive, expected-to-fail until implemented)**: validates the intended end-state.
3. **Perf/Bench (measured, non-flaky)**: tracks regressions and compares vs other editors.

Implementation detail:
- Tier selection is controlled by env gates and schemes:
  - `KERN_ENABLE_EXHAUSTIVE_TESTS=1` enables full-spec tests.
  - `KERN_ENABLE_SNAPSHOT_TESTS=1` enables snapshot assertions.
  - `KERN_ENABLE_PERF_TESTS=1` enables perf tests.

## Coverage Inventory (What Must Be Tested)

### Markdown Blocks

- Paragraphs
- Headings H1–H6 (including “exit heading on Enter” behavior)
- Bullet lists:
  - markers: `-`, `*`, `+`
  - nesting, wrapping, indentation
  - enter/exit behaviors
- Ordered lists:
  - nesting
  - numbering strategy: `gfmDefault` vs `preserveTyped`
  - enter/exit behaviors
- Task lists:
  - bullet markers: `- [ ]`, `* [ ]`, `+ [ ]`
  - standalone shortcut: `[] text`, `[ ] text`, `[x] text` (Kern option)
  - ordered tasks: `1. [ ]` (Kern option)
  - heading tasks: `## [ ]` (Kern option)
  - toggle behavior: keyboard + click hit-target (glyph vs marker region)
- Blockquotes:
  - nesting
  - mixed with lists and code
- Code blocks:
  - fenced + indented
  - language label visibility
  - syntax highlighting presence/absence (explicitly tested)
  - copy button: placement, hit target, “Copied” affordance + timeout
- Horizontal rules (thematic breaks): `---`, `***`, `___`
- Tables (GFM):
  - import/export correctness
  - editing navigation (future)
  - wrapping + horizontal scroll
- Images:
  - local file images
  - remote images (optional; behind setting)
  - broken images and fallback UI
- Links:
  - standard `[text](url)`
  - autolinks (`<https://…>` and bare `https://…` depending on policy)
- Math:
  - inline `$…$`
  - block `$$…$$`
- Mermaid:
  - fenced ` ```mermaid ` blocks render (optional setting)

### Preferences / Settings Matrix

At minimum, full-spec tests must enumerate:

- `exportDialect`: `gfm`, `kern`
- `gfmExtensionExportStrategy`: `preserve`, `portable`, `lint`
- `taskRendering`: `gfm`, `kern`
- `orderedTasksEnabled`: `0|1`
- `headingCheckboxesEnabled`: `0|1`
- `orderedListNumbering`: `gfmDefault`, `preserveTyped`
- `checkboxHitTarget`: `glyph`, `marker`

### Pixel-Level Rendering

We will verify:

- Checkbox glyph vertical alignment vs baseline/line fragment
- Marker spacing and indentation (bullets, numbers, tasks)
- Code block chrome:
  - background radius/padding
  - copy button placement
  - language label placement
- Table grid alignment and cell padding

### Performance

We will measure (cold + warm where relevant):

- Launch -> first window visible
- File open -> first render complete (stress + mega)
- Scroll responsiveness on large docs (automated scroll harness)
- Export latency on large docs
- Save latency (including export flush)
- Memory (RSS) after opening mega doc + after idle

## Datasets / Fixtures

### “Ultimate Stress” Dataset (generator-backed)

We will generate:

- `test-fixtures/ultimate-stress-test.md`
  - contains all features, many permutations, and known edge cases
  - deterministic content and section anchors

Additionally, we will generate *small, targeted* per-feature fixtures so snapshot tests stay readable:

- `test-fixtures/native-editor-spec/blocks/*.md`
- `test-fixtures/native-editor-spec/inline/*.md`
- `test-fixtures/native-editor-spec/edge/*.md`

### Existing fixtures (keep using)

- `test-fixtures/stress-test.md` (medium)
- `test-fixtures/mega-stress-test.md` (very large)
- `test-fixtures/native-editor-benchmark.md` (large, supported subset)

## Test Implementation Plan (Concrete)

### 1) Spec-First Full-Spec Tests (Exhaustive)

Add tests that intentionally **fail today** under `KERN_ENABLE_EXHAUSTIVE_TESTS=1`:

- Codec full-spec: import should hide syntax; export should preserve syntax.
- Rendering full-spec: snapshot and/or layout metric assertions for every block.
- Preference matrix: generator enumerates all preference combinations across representative fixtures.

Key requirement: full-spec tests must include stress/mega fixtures and assert “obviously missing” features
like blockquote/hr/images/mermaid/math cause a failure until implemented.

### 2) Snapshot Matrix (Pixel-Level)

Use SnapshotTesting (AppKit view snapshots) because it’s fast and doesn’t require UI automation.

- Snapshots always include:
  - Light + dark appearance
  - 2 window sizes (sm, lg)
  - Representative fixtures per block type
- Exhaustive snapshot matrix:
  - Adds preference combinations for rendering-affecting settings

### 3) UI E2E (Interaction, Not Rendering)

Keep UI tests focused on what only UI can validate:

- click hit-targets
- selection/caret movement
- find/replace
- copy button interaction + pasteboard
- save menu + disk rewrite behavior

Avoid “render verification” here; use snapshots instead.

### 4) Bench/Perf Harness

- Keep engine-level perf tests in XCTest (already partially done).
- Add scroll/edit perf harness that runs without XCUITest:
  - instantiate `NativeEditorViewController`
  - load mega doc
  - programmatically scroll text view / layout manager
  - measure time and memory

## Artifacts / Logging Requirements

- UI tests must always emit screenshots (already default).
- Snapshot failures must preserve:
  - reference image
  - failure image
  - diff image
- Full-spec failures should attach:
  - exported markdown
  - a minimal diff summary
  - a dump of key attributes for the failing region

## Done When

We can say the suite is “good enough to drive development” when:

- Full-spec exhaustive run produces **many meaningful failures** for currently missing features.
- Each missing feature has at least:
  - 1 codec spec test
  - 1 snapshot (or layout metric test)
  - 1 interaction test if user interaction is required
- Perf suite provides stable numbers for `stress-test.md` and `mega-stress-test.md`.

