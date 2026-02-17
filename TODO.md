# KernTextKit — Task List

Persistent tracker for the native TextKit rewrite (no WebView).

## Done

- [x] Split into fresh repo at `Kern-textkit`
- [x] Rename app to `KernTextKit` and bundle id to `com.kern.textkit`
- [x] Make app native-only (remove WebKit/CoreEditor codepaths)
- [x] Update unit tests + scripts for `KernTextKit.xcodeproj` / `KernTextKit` schemes

## Next

- [ ] WYSIWYG: numbered list behavior (enter/exit/indent) aligned with Notion/GFM expectations
- [ ] WYSIWYG: task list behavior (toggle by clicking marker region, hit target sizing, ordered-task option)
- [ ] WYSIWYG: code block visuals (background, padding, font), copy button positioning and selection behavior
- [ ] WYSIWYG: tables editing UX (caret movement, row/column edits) + export correctness
- [ ] Preferences UI for native editor options (export dialect, extensions strategy, ordered numbering, checkbox hit target)
- [ ] CRITICAL: Replace global mutable statics in NativeMarkdownCodec with ImportContext parameter threading (review finding #5 — `activeReferenceDefinitions`, `activeImportBaseURL`, `activeImportOptions`, `activeStrictConformanceRoundTripMode` at lines 17-21 are non-reentrant; 6 methods read them: `parseInline`, `parseImage`, `parseLink`, `makeMarkdownImageAttached`, `stripHardBreakMarker`; model fix on export path which already passes `options` as a parameter)
- [ ] HIGH: Load local images asynchronously in MarkdownRichAttachments (review finding #10 — `loadImageIfNeeded` at lines 124-134 calls `NSImage(contentsOf:)` synchronously on @MainActor; dispatch to background queue matching the existing async pattern used for remote images at lines 140+)

## Testing

- [ ] Expand `KernUITests/NativeEditorE2ETests.swift` scenario matrix (more permutations + edge cases)
- [ ] Add always-on screenshot baselines and pixel-level comparison gates for alignment regressions
- [ ] Add fuzz/property tests for editing operations (import -> edit ops -> export) where feasible

## Benchmarks

- [ ] Define benchmark protocol: cold start, file open latency, scroll/selection responsiveness, memory on huge docs
- [ ] Implement benchmark runners for:
  - KernTextKit (this repo)
  - Legacy Kern (WebKit) for comparison
  - External editors (VS Code, MarkText) where automatable
