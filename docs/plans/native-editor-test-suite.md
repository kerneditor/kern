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
  - Strict spec conformance must run in a profile where Kern extensions are off.
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
  - `KERN_ENABLE_SPEC_CONFORMANCE_TESTS=1` enables official CommonMark/GFM conformance tests.

## Strict Markdown Spec Lane (Separate From Kern Extensions)

- Use official fixtures generated from:
  - CommonMark spec JSON (`spec.commonmark.org`)
  - cmark-gfm `test/spec.txt`
- Compare semantics with an oracle renderer (`cmarkgfm`) using HTML equivalence.
- Keep this lane strict:
  - `orderedTasksEnabled = false`
  - `headingCheckboxesEnabled = false`
  - `taskRendering = gfm`
- Kern-specific syntax support (`[] task`, heading task checkbox, ordered task checkbox) must stay in separate option/profile tests and must not be counted as strict conformance behavior.

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
- Marker vertical alignment vs adjacent text (bullets, ordered markers, bulleted-tasks)
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

### “Ultimate + Mega” Dataset (generator-backed)

We will generate:

- `test-fixtures/ultimate-stress-test.md`
  - permutation-dense canonical source for feature/action combinations
  - deterministic content and section anchors
  - generated by `scripts/gen_ultimate_stress_test.py` (do not hand-edit)

- `test-fixtures/mega-stress-test.md`
  - volume-dense **and** permutation-dense single-file corpus
  - includes an embedded permutation appendix synced from ultimate
  - synced by `scripts/sync_mega_permutation_appendix.py` (do not hand-edit appendix block)

Additionally, we keep *small, targeted* per-feature fixtures so snapshot tests stay readable:

- `test-fixtures/native-editor-spec/blocks/*.md`
- `test-fixtures/native-editor-spec/inline/*.md`
- `test-fixtures/native-editor-spec/edge/*.md`

### Existing fixtures (keep using)

- `test-fixtures/stress-test.md` (medium)
- `test-fixtures/mega-stress-test.md` (single-file exhaustive corpus)
- `test-fixtures/native-editor-benchmark.md` (large, supported subset)

## Test Implementation Plan (Concrete)

### 1) Spec-First Full-Spec Tests (Exhaustive)

Add tests that intentionally **fail today** under `KERN_ENABLE_EXHAUSTIVE_TESTS=1`:

- Codec full-spec: import should hide syntax; export should preserve syntax.
- Rendering full-spec: snapshot and/or layout metric assertions for every block.
- Preference matrix: generator enumerates all preference combinations across representative fixtures.
- Full live typing matrix (non-UI): `NativeEditorMegaStressTypingMatrixTests`
  - types `mega-stress-test.md` character-by-character (canonical profiles)
  - types `mega-stress-test.md` with **interleaved editing action programs** (canonical profiles)
  - types `ultimate-stress-test.md` character-by-character (full preference permutations)
  - types `ultimate-stress-test.md` with **interleaved editing action programs** (selection/replace/cut-paste/undo-redo)
  - applies generated action permutations on feature seeds (full preference permutations)
- Notion-style list behavior regression matrix: `NativeEditorNotionListBehaviorRegressionTests`
  - nested bullet / ordered / task / ordered-task backspace recovery (outdent + keep typing alive)
  - tab / shift-tab round-trip for nested list flavors without semantic degradation
- Notion-style behavior-program matrix: `NativeEditorNotionTypingBehaviorProgramTests`
  - deterministic action programs over list contexts (newline, indent/outdent, backspace, paste, selection-replace, undo/redo)
  - invariant checks after each action to prevent malformed markers or semantic loss

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
- one exhaustive full-fixture live typing loop (chunked typing + generated UI action permutations + save assertions)
  - default mode is character-by-character typing (`KERN_UI_TYPING_MODE=character`)
  - optional `chunked` mode exists for faster debugging

Avoid “render verification” here; use snapshots instead.

Prereq (macOS): UI tests require Accessibility trust for `KernTextKitUITests-Runner`.
If tests are skipped for missing permissions, run:

- `./scripts/open-ui-test-permissions.sh`

If macOS refuses to show/add the runner in the Accessibility list (common TCC/UI corruption):

- Try drag-and-drop of the Runner.app from Finder into the list (the `+` picker can fail silently on some OS versions).
- Reset just Accessibility permissions, then reboot:
  - `tccutil reset Accessibility`
- If the Accessibility list is blank and adding fails silently, delete this file and reboot:
  - `rm ~/Library/Preferences/com.apple.security.KCN.plist`
- If `tccd` is disabled, re-enable it:
  - `launchctl load -wF /System/Library/LaunchAgents/com.apple.tccd.plist`

### 4) Bench/Perf Harness

- Keep engine-level perf tests in XCTest (already partially done).
- Keep perf workloads aligned with exhaustive correctness workloads:
  - stress/ultimate/mega render timings
  - ultimate + mega char-by-char typing timing
  - ultimate + mega interleaved action-burst typing timing
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
- Exhaustive UI full-fixture typing must attach:
  - config report (fixture, mode, chunk size, action depth/limit)
  - action-program count report
  - periodic screenshots during typing/action passes

## Done When

We can say the suite is “good enough to drive development” when:

- Full-spec exhaustive run produces **many meaningful failures** for currently missing features.
- Each missing feature has at least:
  - 1 codec spec test
  - 1 snapshot (or layout metric test)
  - 1 interaction test if user interaction is required
- Perf suite provides stable numbers for `stress-test.md` and `mega-stress-test.md`.

## Commanded Runs

- Typing behavior gate (matrix + stateful + typing reliability):
  - `./scripts/run-typing-behavior-gate.sh --lane pr`
  - `./scripts/run-typing-behavior-gate.sh --lane nightly`
  - PR lane scheme/profile: `KernTextKitExhaustive` (`KERN_TYPING_STATEFUL_SEEDS=24`, `KERN_TYPING_STATEFUL_STEPS=50`, `KERN_TYPING_STATEFUL_ENFORCE=1`)
  - Nightly lane scheme/profile: `KernTextKitUltraExhaustive` (`KERN_TYPING_STATEFUL_SEEDS=120`, `KERN_TYPING_STATEFUL_STEPS=120`, `KERN_TYPING_STATEFUL_ENFORCE=1`)
  - Artifacts emitted under `test-results/typing-behavior/<timestamp>-<lane>/`

- Exhaustive native suite orchestrator:
  - `./scripts/run-exhaustive-native-suite.sh`
- Include bounded ultra mega all-profile matrix:
  - `KERN_RUN_ULTRA=1 ./scripts/run-exhaustive-native-suite.sh`
- Include full mega all-profile matrix (very slow):
  - `KERN_RUN_ULTRA_FULL=1 ./scripts/run-exhaustive-native-suite.sh`
- Include exhaustive UI automation:
  - `KERN_RUN_UI_EXHAUSTIVE=1 ./scripts/run-exhaustive-native-suite.sh`
