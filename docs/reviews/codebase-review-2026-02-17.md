# KernTextKit Codebase Review — 2026-02-17

Comprehensive review conducted by 5 parallel analysis agents covering:
editor core, markdown codec, test coverage, scripts/tooling, and architecture.

## CRITICAL (Data Loss / Correctness)

### 1. `windowWillClose` does not flush export debounce — last 150ms of edits silently lost

If the user closes a window within 150ms of their last keystroke, the autosave
triggered by the "Save?" sheet uses stale `stringValue`. The debounced export
never fires.

- EditorWindowController.swift: `windowWillClose` is a no-op
- NativeEditorViewController.swift: `exportWorkItem` has 150ms debounce

**Fix:** Call `flushPendingExport()` in `windowWillClose`.

### 2. `applicationShouldTerminate` drops edits in background-mode path

When `keepRunning` is true, all windows close and the app hides. The debounced
`exportWorkItem` is cancelled when the VC deallocates — the last 150ms of typing
is silently lost.

- AppDelegate.swift lines 233-245

**Fix:** Call `flushNativeEditorExportIfNeeded()` before closing windows.

### 3. Data race on `lastKnownFileModDate`

`writeSafely` runs on a background thread and writes this `var`; the main-queue
debounced `presentedItemDidChange` workItem reads it. `EditorDocument` is
intentionally not `@MainActor`. This is an unguarded concurrent access.

- EditorDocument.swift lines 10-13, 109-116, 136-148

**Fix:** Use an actor-isolated property or a lock.

### 4. Reference definitions inside blockquotes are silently missed

The pre-scan at import time calls `parseReferenceDefinition` on raw lines
including `>` prefixes, but `parseReferenceDefinition` doesn't strip `>`.
Reference-style links/images inside blockquotes resolve to plain text.

- NativeMarkdownCodec.swift lines 120-124

**Fix:** Strip blockquote prefixes before the reference pre-scan.

### 5. Global mutable static state makes `importMarkdown` non-reentrant

`activeReferenceDefinitions`, `activeImportBaseURL`, `activeImportOptions`,
`activeStrictConformanceRoundTripMode` are static vars. Any overlapping call
overwrites the first call's context.

- NativeMarkdownCodec.swift lines 18-21

**Fix:** Thread context as parameters through the parse stack.

### 6. Soft line breaks joined with `"\n"` corrupt export

Paragraph continuation lines are joined with `"\n"` which passes through to
export as a literal newline, changing the markdown semantics in other renderers.

- NativeMarkdownCodec.swift line 929

**Fix:** Use `"\u{2028}"` or normalize to space on export.

---

## HIGH (Bugs / Significant Issues)

### 7. `NSTextStorage` mutations without `beginEditing`/`endEditing`

Checkbox toggle makes ~14 attribute changes without grouping. All direct
`storage.replaceCharacters`/`addAttribute` calls across the codebase lack batch
brackets, causing excessive layout invalidation.

- NativeEditorViewController.swift lines 388-418, 877, 910, 935, 987, 1186, 1289, 1356

### 8. `handleBackspaceAtListStartIfNeeded` calls `didChangeText()` without `isApplyingInputRules`

Triggers the full input-rule pipeline a second time and can double-schedule exports.

- NativeEditorViewController.swift line 989

### 9. Undo grouping is completely absent

Input rules (heading conversion, list continuation, checkbox toggle) create
multiple separate undo items for what should be a single user action. No
`beginUndoGrouping`/`endUndoGrouping` anywhere in the codebase.

### 10. Synchronous file I/O on main thread for local images

`MarkdownImageAttachment.loadImageIfNeeded` calls `NSImage(contentsOf:)`
synchronously on `@MainActor`. Large local images freeze the UI.

- MarkdownRichAttachments.swift lines 124-134

### 11. `serializeLinkDestination` escapes `>` but not `<` inside angle brackets

Produces malformed output for destinations containing `<`.

- NativeMarkdownCodec.swift lines 4325-4327

### 12. No encoding detection — UTF-8 hard failure

`EditorDocument.read` only attempts UTF-8. Non-UTF-8 files (Latin-1, UTF-16 BOM)
hard-fail with a misleading error (`unimpErr` / "function not implemented").

- EditorDocument.swift lines 29-38

### 13. Hardcoded `/Users/aaaaa/` paths in 2 scripts

`comprehensive-benchmark.sh` and `test-autosave-debounce.sh` are completely
broken for any other user.

- scripts/comprehensive-benchmark.sh line 26
- scripts/test-autosave-debounce.sh line 15

### 14. `test-markdown-spec-conformance.sh` recreates venv on every run

Always runs `python3 -m venv` + `pip install` — slow, network-dependent, can
corrupt venv if interrupted.

- scripts/test-markdown-spec-conformance.sh lines 87-89

### 15. Two scripts missing `set -e`

`comprehensive-benchmark.sh` and `test-autosave-debounce.sh` omit `-e`, silently
proceeding past failures.

### 16. `run-exhaustive-native-suite.sh` depends on undeclared `rg` (ripgrep)

Uses `rg` where all other scripts use `grep`. On systems without ripgrep,
skipped-test detection silently reports 0 due to `|| true`.

- scripts/run-exhaustive-native-suite.sh lines 80, 85

---

## MEDIUM (Correctness / Design Issues)

### 17. `toggleInlineAttribute` hardcodes base font size 16

Toggling bold/italic/code on heading text resets it to 16pt, losing heading size.

- NativeEditorViewController.swift lines 1516-1535

### 18. `setFindQueryFromSelection(allowEmpty:)` — dead parameter

Both branches return early identically; `allowEmpty` has no effect.

- NativeEditorViewController.swift lines 1889-1898

### 19. `isGfmTableDelimiterRow` requires 3+ dashes; GFM spec requires 1+

Tables with `| - | - |` or `| -- | -- |` are silently rejected.

- NativeEditorViewController.swift line 1324

### 20. Table cell backtick tracking broken for odd counts

Single backtick toggles `inCodeSpan`, so a cell with an odd number of literal
backticks merges with the next cell.

- NativeMarkdownCodec.swift lines 1518-1521

### 21. Single-column GFM tables rejected

`guard headerCells.count >= 2` — valid single-column GFM tables become paragraphs.

- NativeMarkdownCodec.swift lines 1443-1449

### 22. `*`, `_`, `[`, `]` not escaped in paragraph export

User typing `*not bold*` in the editor exports as `*not bold*` without escaping
— re-imports as bold.

- NativeMarkdownCodec.swift lines 4542-4565

### 23. Reference definition title regex allows mismatched delimiters

`["']([^"']+)["']` accepts `"title'` — violates CommonMark.

- NativeMarkdownCodec.swift line 2027

### 24. `NSArgumentDomain` override discards xcodebuild defaults overrides

`setVolatileDomain` replaces the entire domain, silently dropping test runner
`-DefaultsKey` arguments.

- main.swift line 46

### 25. `NSCoding init` on attachments loses content

`required init?(coder:)` restores hardcoded defaults. Undo manager, pasteboard,
and autosave paths using NSCoding silently destroy attachment content.

- MarkdownPlaceholderAttachment.swift, MarkdownRichAttachments.swift (multiple)

### 26. Mermaid layout cache is `nonisolated(unsafe)` without synchronization

`layoutResult(maxContentWidth:)` is `nonisolated` but reads/writes
`nonisolated(unsafe)` vars.

- MarkdownRichAttachments.swift lines 473-474, 514

### 27. `estimatedImageCostBytes` called on background thread for NSImage

`NSBitmapImageRep.representations` accessed off-main-thread before the
`@MainActor` hop.

- MarkdownRichAttachments.swift line 152

### 28. `\leftarrow` silently destroyed by `\left` replacement in math renderer

Regex replaces `\left` as a substring of `\leftarrow`, leaving `arrow`.

- MarkdownRichAttachments.swift lines 817-818

### 29. `characterIndex(at:)` maps clicks in empty space to nearest glyph

Clicking whitespace to the right of a short line can trigger checkbox toggle on
the last character.

- NativeMarkdownTextView.swift lines 406-415

### 30. `mouseDown` consumes click without calling `super` for checkbox toggle

The caret does not move, selection is not updated, first-responder is not set.

- NativeMarkdownTextView.swift lines 88-92

### 31. Selection restoration after external update loses selection length

Always restores with `length: 0`.

- NativeEditorViewController.swift line 278

### 32. `gfmDefault` ordered numbering for tasks is a dead branch

Both `.preserveTyped` and `.gfmDefault` produce the same `normalizedIndex`.

- NativeMarkdownCodec.swift lines 598-603

### 33. Find and Replace shortcut Cmd+Shift+H conflicts with macOS system

Standard macOS shortcut for Find and Replace is Cmd+Option+F.

- AppDelegate.swift lines 326-328

---

## SCRIPTS & TOOLING

| # | Script | Issue | Severity |
|---|--------|-------|----------|
| 1 | comprehensive-benchmark.sh, test-autosave-debounce.sh | Hardcoded `/Users/aaaaa/` path | HIGH |
| 2 | test-markdown-spec-conformance.sh | Venv + pip always re-run | HIGH |
| 3 | comprehensive-benchmark.sh, test-autosave-debounce.sh | Missing `set -e` | HIGH |
| 4 | run-exhaustive-native-suite.sh | Undeclared `rg` dependency | HIGH |
| 5 | test-markdown-spec-conformance.sh | Empty array unsafe under nounset | MEDIUM |
| 6 | benchmark.sh | `run_bench` wrong `$3` post-shift; eval injection | MEDIUM |
| 7 | bench-native-editor.sh | `/tmp` DerivedData default | MEDIUM |
| 8 | test-native-editor.sh | Empty `KERN_UI_TEST_APPEARANCE` | MEDIUM |
| 9 | measure-cold-start.sh | Unquoted array in `sort_and_median` | MEDIUM |
| 10 | comprehensive-benchmark.sh, test-autosave-debounce.sh | `local var=$(cmd)` masks exits | MEDIUM |
| 11 | benchmark.sh, comprehensive-benchmark.sh | No trap for temp cleanup | MEDIUM |
| 12 | test-kern-app.sh | `~` instead of `$HOME`; stale .app risk | LOW |
| 13 | export-xcresult-attachments.sh | `ls` glob for HEIC detection | LOW |
| 14 | benchmark.sh | `run_bench` function is dead code | LOW |
| 15 | comprehensive-benchmark.sh | `RESULTS_FILE` overwrites checked-in fixture | LOW |

---

## TEST COVERAGE GAPS (Top 10)

1. **Zero undo/redo unit tests** — no assertion that undo after any edit restores prior state
2. **Blockquote and thematic break round-trips are exhaustive-gated only** — never run in default CI
3. **Table tests are stubs** — 2 tests checking only pipe-absence; no alignment, navigation, or round-trip
4. **Preferences tests cover 1 of 7 options** — `NativeEditorPreferencesTests` is a stub
5. **No Tab/Shift+Tab indent/de-indent tests** anywhere
6. **No paste or cut tests** — no test covers paste into a list item or cut leaving coherent state
7. **Syntax highlighting assertions are too weak** — only checks `distinctColors.count >= 2`
8. **No empty document test** — `importMarkdown("")` / `exportMarkdown(empty)` untested
9. **No RTL, combining character, or NUL byte tests**
10. **Performance bounds are too loose** — 12s open time, 250K height upper bound

---

## ARCHITECTURAL CONCERNS

1. **NativeMarkdownCodec is 4,626 lines with no AST** — parses directly to `NSAttributedString`, making export fragile and individual rules untestable in isolation
2. **NativeEditorViewController is 2,286 lines** — massive view controller handling layout, input rules, find/replace, checkbox interaction, anchor navigation, toast, chrome, and export
3. **No app sandbox** — `com.apple.security.app-sandbox: false` plus `NSAllowsArbitraryLoads: true` globally
4. **No printing, no Versions.app browser, no drag-to-insert image, no Escape to close find bar**
5. **Zero localization support** — all strings hardcoded English
6. **Zero VoiceOver semantic support** — no accessibility labels on custom views, empty checkbox titles in preferences
7. **Appearance-baked syntax highlighting** — colors computed at import time, not dynamically adapted on mode switch
8. **Preference key duplication** — hardcoded string literals in 4+ files with no centralized constants
9. **OSSignposter `launchInterval` never ended** — will never appear correctly in Instruments
10. **`app.activate(ignoringOtherApps: true)` is deprecated on macOS 14+**
