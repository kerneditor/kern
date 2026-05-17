# Native Editor Missing Features Implementation Plan

Date: 2026-02-15
Scope: Close all currently known full-spec gaps in KernTextKit (native AppKit/TextKit, no WebView).

## Live Fix Log (2026-02-17)

- [x] Find/replace bar no longer centered over top content; now anchored top-right with compact width.
  - Implementation:
    - `KernApp/Sources/Editor/NativeEditorViewController.swift` (`layoutFindBar`)
  - Verification:
    - `KernTests/NativeFindReplaceIntegrationTests.swift`
    - `testShowFindReplace_AnchorsBarTopRight_WithCompactWidth`
    - `xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -derivedDataPath .derived-data/tests -only-testing:KernTextKitTests/NativeFindReplaceIntegrationTests test`
    - `11 passed / 0 failed` (2026-02-17 03:41 local)
    - Log: `test-results/native-editor/find-replace-regression-20260217-034059.log`
    - xcresult: `.derived-data/tests/Logs/Test/Test-KernTextKit-2026.02.17_03-41-02-+0900.xcresult`
    - Build: `xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -derivedDataPath .derived-data/tests build`
    - Build log: `test-results/native-editor/build-20260217-034316.log`
    - Built app: `.derived-data/tests/Build/Products/Debug/KernTextKit.app`

- [x] Exhaustive typing behavior coverage moved to unit-driven matrix/program/stateful gates.
  - Implementation:
    - `KernTests/NativeEditorTypingBehaviorMatrixCoverageTests.swift`
    - `KernTests/NativeEditorNotionTypingBehaviorProgramTests.swift`
    - `KernTests/NativeEditorTypingStatefulSequenceTests.swift`
  - Status:
    - XCUI runner was removed; exhaustive typing coverage now lives in the PR/nightly typing-behavior lanes plus targeted AppKit interaction tests.

## 1) Current Gap Inventory (from latest exhaustive run)

Source run:
- `./scripts/test-native-editor.sh --exhaustive`
- Result bundle: `test-results/native-editor/20260215-070135/KernTextKitTests.xcresult`

Primary failing areas:
- Rendering features missing:
  - images as attachments (local + remote + reference-style)
  - mermaid diagram rendering
  - math rendering (inline + block)
- Markdown compatibility gaps:
  - reference links and link-title syntax leak as raw markdown in WYSIWYG
  - underscore emphasis/strong edge cases (`_`, `__`, mixed nesting) not normalized
  - inline code with embedded backticks
  - `~~~` fenced code and indented code normalization
  - image titles exported URL-encoded where quoted title is expected
- UI behavior gaps:
  - anchor jump does not reliably place target near top when already visible
  - code-block chrome placement still fails full-spec geometry assertions
- Test/fixture drift:
  - `StressFixturesSanityTests` expects strings that no longer match `stress-test.md`

## 2) Syntax Highlighting Coverage Gap (Mega Stress)

Languages currently in `mega-stress-test.md`:
- Frequent: `mermaid`, `python`, `swift`, `go`, `javascript`, `rust`, `typescript`, `ruby`, `java`, `bash`
- Also present: `c`, `cpp`, `clojure`, `css`, `dart`, `dockerfile`, `elixir`, `graphql`, `haskell`, `html`, `json`, `kotlin`, `lua`, `makefile`, `ocaml`, `perl`, `php`, `powershell`, `protobuf`, `r`, `scala`, `scss`, `sql`, `terraform`, `toml`, `xml`, `yaml`, `zig`

Current highlighter supports only:
- `javascript/typescript`, `python`, `bash`, `swift`

## 3) Implementation Workstreams

### Workstream A — Markdown AST/Codec Completeness

Goals:
- Make import/export deterministic across full-spec syntax cases.
- Remove raw syntax leakage in WYSIWYG for supported features.

Tasks:
1. Inline parsing upgrades:
   - support `_..._` and `__...__` as emphasis/strong equivalents to `*`/`**`
   - fix nested emphasis precedence (`***`, mixed strong/emphasis)
   - support inline code with variable backtick fence lengths (``code with `tick```).
2. Link parsing/export:
   - add title handling for inline links `[text](url "title")`
   - support reference links `[text][id]` + definitions
   - preserve/normalize export form according to dialect settings.
3. Code block normalization:
   - parse `~~~` fences
   - parse indented code blocks
   - export canonical fenced blocks in GFM mode.
4. Image syntax normalization:
   - parse title-bearing image syntax without percent-encoding the title segment.

Done criteria:
- `NativeMarkdownCodecFullSpecCaseMatrixTests` passes for all inline/link/code-fence/image-title cases above.

### Workstream B — Native Renderers for Missing Blocks

Goals:
- True WYSIWYG renderers for image, mermaid, math in native TextKit.

Tasks:
1. Image renderer:
   - parse image nodes into attachment-backed blocks/runs
   - local file loader + async remote loader (setting-gated)
   - broken-image placeholder with alt text
   - cache + resize policy for performance.
2. Mermaid renderer:
   - parse mermaid fenced blocks into diagram attachments
   - render pipeline abstraction:
     - provider interface (`DiagramRenderer`)
     - fallback placeholder if renderer unavailable
   - export must preserve original mermaid source fence.
3. Math renderer:
   - parse inline `$...$` and block `$$...$$` into math attachments/spans
   - preserve original source for export
   - fallback placeholder when parse/render fails.

Done criteria:
- `NativeMarkdownCodecFutureSpecTests` passes for images/math/mermaid.
- `NativeEditorStressFixtureFullSpecTests` no longer shows raw math delimiters.

### Workstream C — Code Block Chrome + UX

Goals:
- Finish code-block UX behavior to full-spec quality.

Tasks:
1. Fix copy/language chrome geometry:
   - guarantee chrome remains inside code-block background bounds
   - preserve top-right placement in all window sizes and wrapped layouts.
2. Keep dual visibility behavior:
   - show pills for caret block and hovered block simultaneously.
3. “Copied” feedback:
   - copy button transitions `Copy -> Copied -> Copy` with deterministic timeout
   - add explicit test timing hooks.

Done criteria:
- `NativeEditorCodeBlockChromeSpecTests` fully green.

### Workstream D — Anchor Navigation Reliability

Goals:
- Deterministic TOC/anchor behavior matching expected editor UX.

Tasks:
1. Remove snap-back to source link after jump.
2. Ensure target lands near top even when target is already in view.
3. Keep cursor focus behavior predictable after jump.

Done criteria:
- `AnchorNavigationScrollTests` green.
- No manual repro of “jump then return to TOC”.

### Workstream E — Syntax Highlighting Expansion

Goals:
- Cover all major languages in mega-stress fixture with at least baseline token coloring.

Tasks:
1. Refactor current switch into pluggable highlighter registry:
   - `languageAliases` normalization
   - `TokenPatternSet` per language
   - shared token classes (comment/string/keyword/number/type/function/variable).
2. Implement Tier 1 languages first (highest practical value):
   - `go`, `rust`, `java`, `ruby`, `sql`, `c`, `cpp`, `json`, `yaml`, `toml`, `xml`, `html`, `css`, `powershell`, `dockerfile`, `terraform`, `kotlin`, `php`.
3. Implement Tier 2 coverage:
   - `scala`, `r`, `graphql`, `protobuf`, `lua`, `dart`, `clojure`, `elixir`, `haskell`, `ocaml`, `perl`, `makefile`, `zig`, `scss`.
4. Add “unsupported language” fallback:
   - monospaced code style with consistent color, no truncation/pill issues.

Done criteria:
- New highlighting matrix test over mega-stress languages.
- For each listed language, test verifies at least 2 foreground color classes in code range.

### Workstream F — Test Suite Integrity + Drift Prevention

Goals:
- Keep exhaustive suite trustworthy and aligned with fixtures/features.

Tasks:
1. Fix `StressFixturesSanityTests` expectations to match current canonical stress fixture sections/content.
2. Add fixture schema checks:
   - required sections declared in one fixture manifest
   - tests validate against manifest instead of hardcoded fragile strings.
3. Add missing full-spec tests for any new renderer behavior added in B/E.
4. Keep exhaustive failures feature-linked:
   - each failure maps to one capability (not vague regex mismatch).

Done criteria:
- No fixture drift failures when features are otherwise stable.

## 4) Execution Order (Recommended)

Phase 0 (Stabilize test harness):
1. Fix fixture drift in `StressFixturesSanityTests`.
2. Fix anchor and code-chrome regressions (fast wins, unblock UX confidence).

Phase 1 (Codec parity):
1. Inline emphasis/backtick/link/reference upgrades.
2. Fence normalization (`~~~`, indented code) and export normalization.

Phase 2 (Renderers):
1. Images (local first, then remote setting).
2. Math rendering.
3. Mermaid rendering.

Phase 3 (Highlight expansion):
1. Highlighter registry refactor.
2. Tier 1 languages.
3. Tier 2 languages.

Phase 4 (Hardening):
1. Full exhaustive run (unit + snapshots + orchestrated exhaustive gate).
2. Perf run on stress + mega fixtures.
3. Fix regressions and re-run until green.

## 4.1) Progress Status (2026-02-16)

- [x] Phase 0 (stabilize harness): anchor/code-chrome/fixture drift gates are green.
- [x] Phase 1 (codec parity): full-spec codec matrix gates are green.
- [x] Phase 2 (native renderers): image/math/mermaid/thematic-break renderers are active in native TextKit and validated by full-spec + layout regression tests.
- [x] Phase 3 (highlight expansion): multi-language highlighting added with exhaustive matrix coverage for mega-stress language set.
- [~] Phase 4 (hardening):
  - exhaustive unit (`--unit-only --exhaustive`) is green
  - exhaustive snapshots (`--unit-only --snapshots --exhaustive`) are green
  - exhaustive orchestration (`scripts/run-exhaustive-native-suite.sh`) is green (fixture generation + smoke + exhaustive + perf)
  - perf suite runs with bounded defaults for mega/ultimate typing and render/scroll workloads
  - heavy ultimate-render perf is explicit opt-in (`KERN_PERF_ENABLE_ULTIMATE_RENDER=1` or `KERN_PERF_RENDER_FULL=1`)
  - active exhaustive gates are unit/snapshot/orchestrated only; no XCUI runner remains in the release-hardening path

## 5) Test Gates Per Phase

Phase 0 gate:
- `AnchorNavigationScrollTests`
- `NativeEditorCodeBlockChromeSpecTests`
- `StressFixturesSanityTests`

Phase 1 gate:
- `NativeMarkdownCodecFullSpecCaseMatrixTests` (link/emphasis/code-fence related cases)

Phase 2 gate:
- `NativeMarkdownCodecFutureSpecTests`
- `NativeEditorStressFixtureFullSpecTests`

Phase 3 gate:
- new `NativeMarkdownCodecSyntaxHighlightingMatrixTests` over mega-stress language list

Final gate:
- `./scripts/test-native-editor.sh --exhaustive`
- `./scripts/test-native-editor.sh --snapshots --exhaustive`
- `./scripts/bench-native-editor.sh`
- `./scripts/run-exhaustive-native-suite.sh` (recommended orchestrated gate)

## 6) Non-Negotiable Quality Rules

- No WebView dependency.
- All rendering features must round-trip source markdown accurately.
- Any new feature must ship with:
  - unit codec tests
  - snapshot/layout metric checks
  - unit-driven interaction tests when interaction-specific
- No “green by skipping”: exhaustive failures must only disappear when feature behavior is implemented.
