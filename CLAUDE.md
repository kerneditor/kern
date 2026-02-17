# CLAUDE.md

Guidance for working in this repository.

## What Is KernTextKit

KernTextKit is the primary Kern codebase: a native macOS WYSIWYG Markdown editor built with Swift + AppKit + TextKit (no WebView).

Primary goal: true WYSIWYG editing with deterministic Markdown round-trip (default: GFM, optional Kern extensions).

## Read First

1. AGENTS.md
2. docs/plans/native-editor-test-suite.md
3. docs/plans/markdown-spec-failure-tracker.md
4. docs/plans/native-editor-missing-features-implementation-plan.md
5. NATIVE-EDITOR-TEST-MATRIX.md
6. docs/reviews/codebase-review-2026-02-17.md

## Build And Run

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

Manual build:

```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -configuration Debug -destination 'platform=macOS' build
```

## Test Commands

Unit tests (the only test mode — XCUI target was removed):

```bash
./scripts/test-native-editor.sh
```

Exhaustive suites:

```bash
./scripts/test-native-editor.sh --exhaustive
./scripts/test-native-editor.sh --snapshots --exhaustive
```

Strict markdown conformance:

```bash
./scripts/test-markdown-spec-conformance.sh
```

## Key Code

- KernApp/Sources/App/main.swift: entry point and test-env overrides
- KernApp/Sources/App/AppDelegate.swift: app lifecycle, menus, save hooks
- KernApp/Sources/Editor/EditorDocument.swift: NSDocument load/save/autosave/reload
- KernApp/Sources/Editor/EditorWindowController.swift: window and tab setup
- KernApp/Sources/Editor/NativeEditorViewController.swift: native editor behavior and UI orchestration
- KernApp/Sources/Editor/NativeMarkdownCodec.swift: markdown import/export semantics
- KernApp/Sources/Editor/NativeMarkdownTextView.swift: text interaction and rendering behavior
- KernApp/Sources/Editor/MarkdownRichAttachments.swift: images/mermaid/math attachment rendering

## Session Learnings

- `kern://editor` is legacy WebKit routing (Kern-webkit), not TextKit.
- Memory-check loop that worked well:
  - open stress fixture + many tabs
  - sample RSS over time with `ps`
  - run `leaks <pid>` for leak report
- Native image cache is now bounded in MarkdownRichAttachments:
  - `NSCache.totalCostLimit = 128MB`
  - `NSCache.countLimit = 256`
  - `setObject(..., cost: estimatedImageCostBytes(...))`
- Packaging script avoids broad `rm -rf` patterns; use guarded directory deletion helper in `scripts/package-kern-app.sh`.
- XCUI test target (`KernUITests/`) was removed; all tests are unit tests now. `--unit-only` is a no-op compat flag.
- Simulating Enter in unit tests: `textView.insertNewline(nil)` (not key events). Shift+Enter: `textView.insertLineBreak(nil)`.

## Key Environment Flags

- `KERN_ENABLE_EXHAUSTIVE_TESTS=1`: unlocks exhaustive test gates
- `KERN_ENABLE_PERF_TESTS=1`: unlocks performance benchmarks
- `KERN_ENABLE_SPEC_CONFORMANCE_TESTS=1`: unlocks strict CommonMark/GFM oracle

## Known Issues (from 2026-02-17 review)

See full report: docs/reviews/codebase-review-2026-02-17.md

Critical data-loss paths (remaining):
- Reference definitions inside blockquotes silently missed during import pre-scan
- Global mutable static state makes `importMarkdown` non-reentrant (review finding #5)

Fixed (2026-02-18):
- ~~`windowWillClose` does not flush export debounce~~ (f85145d)
- ~~`applicationShouldTerminate` drops unflushed edits~~ (f85145d)
- ~~`lastKnownFileModDate` data race~~ (b58ed02)
- ~~`NSTextStorage` mutations lack `beginEditing`/`endEditing`~~ (c80b9e4)
- ~~No `undoManager.beginUndoGrouping()`~~ (92d2280)
- ~~`handleBackspaceAtListStartIfNeeded` re-triggers input rules~~ (8a0185b)
- ~~No encoding detection — UTF-8 hard failure~~ (530f4da)

Remaining codec/editor bugs:
- `toggleInlineAttribute` hardcodes 16pt base font, losing heading size
- Soft line break join uses `"\n"` — intentionally kept (2da10d7 revert); see TODO.md for deferred bugs

## Swift 6 Concurrency Notes

- EditorDocument is intentionally not `@MainActor`; NSDocument I/O can run off-main.
- UI/controller types are `@MainActor`.

## Working Rules

- Prefer fixing behavior via the native codec and attributed-text model, not markdown string hacks.
- Keep defaults fast and deterministic; gate optional behavior via preferences/env flags.
- Always check `git status --short` before starting to avoid mixing unrelated edits.
