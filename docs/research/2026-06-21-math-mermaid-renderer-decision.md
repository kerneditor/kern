# Math and Mermaid renderer decision notes

Date: 2026-06-21

This note records the dependency and architecture decision for improving Kern's
math and Mermaid rendering without compromising the product identity: fully
native macOS editor, AppKit/TextKit, no Electron/Tauri/WebView editor shell.

## Current state

Kern currently has:

- a lightweight native math text renderer in `MathTextRenderer`;
- block math as `MarkdownMathBlockAttachment`;
- inline math as styled attributed text;
- a native mini Mermaid parser/layout/drawing path;
- Mermaid render mode preference values: `rich`, `ascii`, `auto`, and `officialExternal`;
- rich-block performance plans that already call out future math/Mermaid
  renderer benchmark cases.

The current renderer is fast and native, but it is not full TeX layout and it is
not full Mermaid parity.

## Decision rule

Do not choose a math or Mermaid renderer from repository popularity or visual
preference alone.

For math:

1. A renderer can replace the current default only if it is **strictly better**
   on visual correctness and does not regress editor-open/typing performance
   after caching.
2. If no candidate clears that bar, the current native renderer remains the
   default fast fallback and the richer renderer stays behind a preference.
3. "Fastest" is measured in Kern's TextKit attachment path, not only in an
   upstream demo app.

For Mermaid:

1. `rich`, `ascii`, and `auto` are Kern-native modes and can be benchmarked
   directly today.
2. Official Mermaid parity is a different renderer class: it requires the
   Mermaid JavaScript renderer and SVG output. It must be optional, async, and
   cached so it cannot block first open.
3. The official renderer can win on fidelity, but it cannot replace the native
   fallback unless the benchmark shows no first-open regression and a cache-hit
   path that is competitive.

## Math renderer options

### Option A: continue building our own math renderer

Pros:

- maximum control;
- no new runtime dependency;
- potentially fastest for the small subset already supported.

Cons:

- full beautiful TeX-quality math is a substantial rendering engine: parser,
  atom model, box layout, stretchy delimiters, fractions, radicals, matrices,
  accents, operators with limits, font metrics, error handling, line breaking;
- easy to be fast but wrong;
- high maintenance burden for a feature that mature native libraries already
  cover.

Decision: keep Kern's current renderer as a fallback/fast path, but do not try
to build full TeX-quality math from scratch unless we intentionally scope it to
a small subset.

### Option B: SwiftMath

Source: [SwiftMath](https://github.com/mgriebling/SwiftMath)

Observed 2026-06-21 metadata:

- MIT license;
- latest release checked: 1.7.1, published 2024-12-18;
- repository pushed in June 2026;
- Swift Package Manager support;
- macOS support via AppKit/CoreGraphics/CoreText/QuartzCore;
- pure Swift translation of iosMath with bundled fonts and SwiftUI/AppKit usage
  examples.

Fit for Kern:

- strong native fit;
- pure Swift integration is attractive for a Swift/AppKit codebase;
- likely lowest-friction prototype for TextKit attachment drawing;
- lower adoption footprint than iosMath, so dependency risk should be measured.

### Option C: iosMath

Source: [iosMath](https://github.com/kostub/iosMath)

Observed 2026-06-21 metadata:

- MIT license;
- latest release checked: 2.3.1, published 2026-06-07;
- repository pushed in June 2026;
- larger adoption footprint than SwiftMath;
- Swift Package Manager only in 2.x;
- supports macOS and exposes a programmatic math model in addition to LaTeX
  parsing.

Fit for Kern:

- most mature/original native math option;
- better maintenance signal right now;
- Objective-C heritage may be less idiomatic in a Swift 6 codebase, so we need a
  compile/integration proof before adopting it.

### Option D: MathJax/KaTeX/Typst cached output

Sources:

- [MathJax SVG output](https://docs.mathjax.org/en/latest/output/svg.html)
- [MathJax direct Node rendering](https://docs.mathjax.org/en/v4.0/server/direct.html)
- [KaTeX](https://katex.org/)
- [Typst open source](https://typst.app/open-source/)

Fit for Kern:

- MathJax gives excellent SVG output and accessibility potential, but introduces
  a JavaScript/tooling renderer dependency;
- KaTeX is fast and server-side capable, but its natural output is HTML/CSS;
- Typst is high quality and embeddable, but it is not a transparent LaTeX drop-in.

Decision: these are good oracle/export/high-quality-cache candidates, not the
first native editor runtime dependency.

## Math benchmark and QA plan

Prototype both SwiftMath and iosMath behind a narrow internal interface before
committing to either dependency:

```swift
protocol NativeMathRenderingBackend {
    var name: String { get }
    func measure(expression: String, displayMode: MathDisplayMode, maxWidth: CGFloat) -> CGSize
    func draw(expression: String, displayMode: MathDisplayMode, in rect: CGRect, context: CGContext)
}
```

### Candidate set

| Candidate | Role | Notes |
|---|---|---|
| Current `MathTextRenderer` | baseline fast fallback | Native string normalization; very fast but not TeX layout. |
| `iosMath` | native candidate A | Mature native AppKit/UIKit library; current release activity is strong. |
| `SwiftMath` | native candidate B | Pure Swift port of iosMath; likely simpler Swift integration, smaller adoption footprint. |
| MathJax SVG / KaTeX SVG | oracle/future cached renderer | Useful as quality reference; not first default editor runtime because it adds JS/tooling. |

### Metrics to collect

Run every candidate through the same corpus and the same TextKit-like operations:

1. **Cold parse/layout**: first render of each unique formula.
2. **Warm cache layout**: repeated formula after renderer cache lookup.
3. **Attachment bounds**: repeated `attachmentBounds(...)` calls at width
   buckets used by the editor.
4. **Draw cost**: render to a bitmap/PDF graphics context for block math.
5. **Inline churn**: import and layout many short inline formulas in paragraphs.
6. **Large document open**: fixture with many inline and block formulas.
7. **Scroll-visible redraw**: visible block redraw after layout cache is warm.
8. **Memory/package cost**: binary size, font resources, peak RSS, cache growth.

### Visual corpus

The corpus must include:

- simple inline algebra: `E=mc^2`, `x_i`, `a_{n+1}`;
- fractions and nested fractions;
- radicals and nth roots;
- sums/products/integrals with limits;
- Greek symbols and operators;
- `\left...\right` delimiters;
- matrices and aligned equations;
- text nodes: `\text{...}`, `\operatorname{...}`;
- long wrapping formulas;
- invalid/unsupported commands.

Each candidate gets a contact sheet and snapshot/test artifacts. A candidate is
not "strictly better" if it is fast but visually loses matrices, delimiters,
limits, or invalid-input behavior.

### Benchmark acceptance gates

1. Build integration under Kern's XcodeGen project with Swift 6 strict
   concurrency enabled.
2. Visual corpus: inline, block, fractions, nested fractions, radicals, sums,
   integrals, matrices, aligned equations, Greek, accents, long lines, invalid
   commands.
3. Snapshot comparison against current renderer and source fixture screenshots.
4. Performance corpus: cold parse, warm cache, draw, attachment bounds, large
   document import, scroll with visible math blocks.
5. Dependency review: license, bundled fonts, package size, transitive deps,
   release activity, issue load, API surface.

The first standalone candidate runner is
`scripts/bench-math-renderer-candidates.sh`. It intentionally creates temporary
SwiftPM packages under ignored `tmp/` and writes reports under ignored
`benchmark-archive/`; it does not add iosMath or SwiftMath to Kern's shipped app
target.

Run only on a quiet machine for decision-quality timing:

```bash
KERN_MATH_BENCH_RUNS=7 KERN_MATH_BENCH_WARMUPS=2 ./scripts/bench-math-renderer-candidates.sh
```

Use this for source-generation smoke checks without compiling/downloading:

```bash
KERN_MATH_BENCH_PREPARE_ONLY=1 ./scripts/bench-math-renderer-candidates.sh
```

Initial compile/run smoke on 2026-06-21:

- `SwiftMath` 1.7.1 built and emitted JSON/Markdown artifacts in the standalone
  runner.
- `iosMath` 2.3.1 built and emitted JSON/Markdown artifacts in the standalone
  runner.
- Current upstream check on 2026-06-21 still shows iosMath 2.3.1 as the latest
  release, SwiftMath 1.7.1 as the latest release, and Mermaid CLI 11.15.0 as the
  current npm release.
- Timing from that smoke is not decision-quality because the machine was under
  high unrelated load.
- The updated corpus-driven smoke ran all 14 tracked math eval cases with one
  measured sample per formula. Both candidates built and emitted JSON/Markdown.
- Both candidates reported parser errors for `block-operatorname-softmax`
  (`\operatorname`) and for the intentionally invalid command sample. That is a
  quality signal: mature native libraries are still not automatic full-TeX
  parity for Kern's desired corpus.

Initial bias: try iosMath first for maturity and current release activity; try
SwiftMath immediately after for Swift-native integration. Choose the one that
wins the actual integration + visual + perf gates, not by repo description.

### Initial recommendation before new timing data

Keep the current renderer as the baseline/fallback. Prototype iosMath and
SwiftMath in that order:

- iosMath has the stronger maintenance/adoption signal and directly supports
  macOS AppKit via Swift Package Manager.
- SwiftMath may be easier to integrate because it is pure Swift, but it is a
  translation of an older iosMath base and has a smaller ecosystem signal.
- Building our own full TeX renderer is not recommended unless Kern accepts a
  narrowly scoped math subset. The implementation surface is large enough that
  "native and fast" would likely mean "fast but wrong" for too many formulas.

## Mermaid renderer options

### Current native renderer

Kern's current native renderer is the correct default/fallback because it is
fast, bundled, offline, and does not require a browser or Node runtime.

However, it is a mini renderer. It should not be described as full Mermaid
parity.

### Official Mermaid renderer

Sources:

- [Mermaid](https://mermaid.ai/open-source/intro/syntax-reference.html)
- [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli)
- [ELK for Mermaid](https://github.com/kieler/elkjs)

Full official Mermaid parity requires a JavaScript renderer with DOM/SVG
capabilities. Practically, that means one of:

1. external `mmdc`/Mermaid CLI process;
2. a bundled JS/DOM/Chromium-style renderer;
3. a WebView/offscreen browser renderer;
4. a network renderer.

Options 2-4 conflict with Kern's current product positioning unless we make the
tradeoff explicit. Option 1 preserves the shipped app's native/no-WebView/no-Node
runtime identity because the dependency is optional and external.

## Current Mermaid preference behavior

Kern's current Mermaid setting is stored at
`nativeEditor.mermaidRenderMode`. The valid values are:

| Preference | Current implementation | What it is good for | What it is not |
|---|---|---|---|
| `rich` | Parses a limited Mermaid subset with `MermaidMiniParser`, computes node frames with `MermaidMiniLayout`, and draws nodes/edges/sequence lifelines directly with AppKit. | Best bundled visual mode; fully native, offline, no JS/browser/Node runtime. | Not full Mermaid. It does not implement the official grammar/layout/rendering stack. |
| `ascii` | Renders parsed flowcharts and sequence diagrams into a native Unicode-grid diagram card with boxes, arrows, edge labels, and sequence lifelines; unsupported Mermaid families use a source-preserving ASCII panel with parsed node/edge counts. | Readable bundled fallback for complex or unsupported diagrams; no JS/browser/Node runtime. | Still not official Mermaid parity, and current visual ASCII rendering is not automatically faster than native rich mode. |
| `auto` | Computes a complexity score and chooses `ascii` when score is greater than or equal to the threshold; otherwise `rich`. | Keeps small diagrams visual and complex diagrams cheap. | It is a heuristic; it currently depends on the mini parser, not official Mermaid complexity. |
| `officialExternal` | Preference-gated official-renderer path. Current app behavior checks a theme-aware, width-bucketed, renderer/config-fingerprinted PNG cache, starts a configured external renderer asynchronously on cache miss, and falls back to native `rich` while the render is missing, in-flight, disabled, or failed. `scripts/eval-official-mermaid-renderer.sh` evaluates `mmdc`/Mermaid CLI outside the app target. Settings expose renderer command, optional Puppeteer config, opt-in `npx`, and safe cache clearing. | Lets us prototype official Mermaid fidelity without adding WebView, Electron, Tauri, Node, or Mermaid CLI to the shipped app. | Requires a user/configured renderer command or explicit npx opt-in; not a default bundled renderer. |

The current auto score is:

```text
kindWeight + nodes.count * 5 + edges.count * 7 + min(220, labelCharacterCount / 6)
```

with `kindWeight = 10` for flowchart, `16` for sequence, and `12` for generic.
The threshold defaults to `100` and can be overridden with
`nativeEditor.mermaidAutoAsciiThreshold` or
`KERN_NATIVE_MERMAID_AUTO_ASCII_THRESHOLD`. Values below `30` are clamped to
`30`.

The mini parser currently:

- recognizes flowchart/graph and sequence diagrams;
- extracts a bounded set of nodes and edges;
- caps final nodes at 18 and edges at 40 before layout;
- falls back to generic line nodes for unsupported diagram types.

That means `rich` is "rich native fallback," not "official Mermaid."

## Mermaid benchmark status

Existing historical Mermaid mode artifacts are under
`benchmark-archive/mermaid-render-modes/`. The latest recorded run in that
archive used 15 runs per mode and a generated 68 KB Mermaid-heavy fixture:

| Mode | p50 ms | p95 ms | Mean ms | Effective modes |
|---|---:|---:|---:|---|
| `rich` | 119.47 | 122.44 | 120.08 | rich:1800 |
| `ascii` | 105.29 | 106.99 | 105.51 | ascii:1800 |
| `auto` | 114.12 | 114.73 | 114.05 | ascii:300, rich:1500 |

Interpretation:

- ASCII was about 11.9% faster than rich on that fixture.
- Auto was about 4.5% faster than rich because only a subset crossed the
  complexity threshold.
- This benchmark measures import plus Mermaid attachment-bounds computation. It
  does **not** measure official Mermaid rendering because that path now runs
  asynchronously and needs separate cold/warm/cache-hit timing.

Current machine state on 2026-06-21 is not suitable for a fresh baseline:
system load was above 35 with unrelated Swift/Xcode work running in a sibling
project. New timing data collected under that load must be treated as a harness
smoke test, not a renderer decision.

Follow-up diagnostic baselines after fixing ASCII fallback and adding
`officialExternal` ran with
`KERN_PERF_ITERATIONS=3 KERN_MERMAID_BENCH_RUNS=3 ./scripts/bench-native-editor.sh --quick --include-mermaid`
and passed the 6 selected performance tests with 0 failures. The final-tree
artifact is recorded in
`docs/reports/2026-06-21-native-rich-block-baseline-benchmark.md` and
`bench-results/native-editor/20260621-224301/summary.md`.

The latest quick run after the official renderer PATH fix still had unrelated
system load and should be treated as a harness/regression smoke. It passed 6
selected performance tests with 0 failures and 0 parser-reported regressions
against the previous same-session baseline. Its Mermaid microbenchmarks showed:

- heavy generated fixture: `rich` p50 204.02 ms, `ascii` p50 241.77 ms,
  `auto` p50 215.29 ms;
- smaller generated fixture: `rich` p50 84.05 ms, `ascii` p50 115.41 ms,
  `auto` p50 88.62 ms, `officialExternalDisabledFallback` p50 83.80 ms,
  `officialExternalCacheHit` p50 81.72 ms.

Conclusion: the new ASCII mode is a readability/fallback improvement, not a
performance claim. `rich` should remain default. `officialExternal` is acceptable
as an optional cached fidelity mode, but cold external renderer timing still
needs a quiet-machine benchmark before any product claim.

2026-06-22 refresh after adversarial review:

- `KERN_PERF_ITERATIONS=3 KERN_MERMAID_BENCH_RUNS=3 ./scripts/bench-native-editor.sh --quick --include-mermaid`
  passed 6 selected performance tests with 0 XCTest failures.
- The parser reported one peak-physical-memory regression on
  `NativeMarkdownCodecPerformanceTests.testImportExportBenchmarkFilePerformance`
  (282.7 MB current vs 208.1 MB baseline, +35.8%). An isolated rerun of that
  single test measured 167.4 MB average peak physical memory, below the stored
  baseline, but with high RSD because the first iteration carried a higher peak.
  Treat this as a noisy high-water warning rather than a confirmed product
  regression.
- Heavy generated Mermaid fixture: `rich` p50 102.86 ms, `ascii` p50 122.99 ms,
  `auto` p50 115.44 ms.
- Smaller/generated cache fixture: `rich` p50 38.41 ms, `ascii` p50 53.68 ms,
  `auto` p50 41.12 ms, `officialExternalDisabledFallback` p50 38.37 ms,
  `officialExternalCacheHit` p50 63.81 ms.

Conclusion remains: keep `rich` as the default. `officialExternal` is a
high-fidelity optional mode, not a performance default. The current cache-hit
path can be slower than native rich on small fixtures because it loads cached
PNGs and creates image attachments.

## Official Mermaid renderer comparison

The official Mermaid renderer is JavaScript-based and renders text definitions
to SVG using `mermaid.render(...)`. Mermaid CLI (`mmdc`) wraps that renderer and
can output SVG, PNG, and PDF from Mermaid files.

Compared with Kern's native modes:

| Dimension | Kern `rich` | Kern `ascii` | Official Mermaid |
|---|---|---|---|
| Runtime | AppKit/TextKit only | AppKit/TextKit only | JavaScript renderer, usually through CLI/browser-like execution |
| Output | Native drawing | Monospaced text card | SVG/PNG/PDF |
| Fidelity | Limited subset | Summary/fallback | Full Mermaid grammar/layout/theme support |
| First-open cost | Low | Lowest | Potentially high unless async/cached |
| Offline app dependency | None | None | Optional external tool if using `mmdc`; bundled JS/browser would change dependency posture |
| Best use | Default visual fallback | Large/complex fallback | Optional high-fidelity cached mode |

The right product shape is a fourth optional mode, not replacing the existing
three modes immediately:

- `Native rich`
- `ASCII`
- `Auto`
- `Official Mermaid (external, cached)`

## Mermaid recommendation

Add a new preference value, not a replacement:

- `Native rich` — current native drawn renderer;
- `ASCII` — current fast fallback;
- `Auto` — current complexity-based choice;
- `Official Mermaid (external, cached)` — optional high-fidelity renderer when a
  configured `mmdc` executable is available.

Implementation status on 2026-06-22: the `officialExternal` preference value is
now parsed by `NativeMarkdownCodec.Options`, exposed in Settings, and backed by
an async PNG cache path. Settings expose the renderer command, optional
Puppeteer config path, opt-in `npx`, and safe cache clearing. It deliberately
falls back to native `rich` when the cache is empty, rendering is in flight, no
renderer command is configured, or the renderer fails. The external renderer
eval script is separate from the shipped app target.

Runtime behavior:

1. Hash key: Mermaid source + output format + width bucket + light/dark Mermaid theme + renderer/config fingerprint.
2. If official cache hit exists, display cached PNG attachment.
3. If missing and configured, render asynchronously off-main; show native fallback immediately.
4. Renderer subprocesses get a stable PATH including Homebrew, `/usr/local`, and system paths so app-launched `npx` can find `node`.
5. Optional Puppeteer config is passed to Mermaid CLI with `-p`.
6. If render fails or times out, terminate the renderer process, keep native fallback, and expose a non-blocking diagnostic.
7. Never block initial document open on official rendering.

Cache-clearing behavior:

- The configured cache directory is preserved.
- Generated 64-character hash PNGs and `.work-*` scratch directories are
  removed.
- Arbitrary user files in the configured cache directory are left untouched.

Follow-up validation on 2026-06-21 found and fixed one app-hosted renderer gap:
`npx` could be located by absolute path, but its `/usr/bin/env node` shebang
failed under Xcode/app-hosted tests because the subprocess PATH lacked Homebrew.
The strict app-side visual eval now requires at least the expected valid corpus
diagrams to render through officialExternal; the refreshed run produced 32 cache
PNGs (16 valid diagrams × light/dark) and passed.

QA/eval corpus must include:

- flowcharts with labels containing `<br>`, `<br/>`, escaped HTML, quoted labels,
  Markdown labels, and multi-line labels;
- sequence diagrams with messages, activations, notes, loops, alternatives;
- subgraphs and nested subgraphs;
- class/state/ER/Gantt/mindmap/timeline examples;
- large dependency graphs where ELK materially improves layout;
- invalid Mermaid syntax and unsupported diagram types;
- Notion-copy compatibility cases, especially labels that contain literal or
  escaped line-break markup.

Benchmark matrix:

- native rich cold/warm;
- ASCII cold/warm;
- auto cold/warm;
- official cold process;
- official warm process/cache;
- official missing executable fallback;
- large document initial open with many diagrams;
- visible-scroll draw cost with cached official diagrams.

Acceptance rule: official renderer can be merged only with both visual quality
snapshots and performance artifacts. It must not regress first-open latency
because official rendering is async and cached.

## Next implementation steps

Completed on 2026-06-21:

- Added math and Mermaid stress/eval corpora under `test-fixtures/rich-block-eval/`.
- Added `NativeRichBlockEvalCorpusTests` and `scripts/eval-rich-block-rendering.sh`.
- Added JSON/Markdown eval reports plus PNG contact sheets for math and Mermaid
  rich/auto/ascii visual review.
- Recorded the first tracked eval baseline in
  `docs/reports/2026-06-21-rich-block-renderer-eval-baseline.md`.
- Replaced Mermaid ASCII parser-inventory/source-only fallback with a native
  Unicode-grid renderer for flowcharts and sequence diagrams, plus a readable
  source-preserving panel for unsupported Mermaid families.
- Removed the nested AppKit canvas from ASCII drawing so Mermaid ASCII content
  appears inside a single attachment card instead of a double-framed window.
- Fixed sequence ASCII parsing so sequence arrows are not also parsed as
  flowchart edges, and widened sequence participant spacing to reduce label
  clipping.
- Ran a diagnostic native performance baseline and recorded it in
  `docs/reports/2026-06-21-native-rich-block-baseline-benchmark.md`.
- Added the `officialExternal` Mermaid preference value, Settings controls,
  async PNG cache path, timeout/process cleanup, visible diagnostics, and safe
  native-rich fallback semantics.
- Added optional Puppeteer config support for the external Mermaid CLI path and
  included renderer/config fingerprinting in official-rendered PNG cache keys.
- Hardened official Mermaid cache clearing so it removes only Kern-generated
  cache artifacts instead of deleting the whole configured directory.
- Added `scripts/eval-official-mermaid-renderer.sh` for official Mermaid CLI
  corpus evaluation without adding Mermaid CLI to the shipped app target.
- Added exact-width official Mermaid visual cache seeding and visual QA through
  `scripts/eval-rich-block-rendering.sh`; latest visual artifacts are in
  `test-results/rich-block-eval/20260621-223840/`.
- Updated `scripts/bench-math-renderer-candidates.sh` so iosMath/SwiftMath
  candidate timings use the tracked rich-block math corpus instead of a separate
  hard-coded subset.
- Ran the final quick native benchmark and Mermaid mode matrix; latest tracked
  summary is `docs/reports/2026-06-21-native-rich-block-baseline-benchmark.md`.
- Ran the 2026-06-22 adversarial review validation: targeted official Mermaid
  regression tests passed, app-side official visual QA generated 32 official
  Mermaid PNGs, the non-snapshot native gate passed, and a quick benchmark
  refresh preserved `rich` as the recommended default.

Remaining:

1. Re-run the current renderer baseline on a quiet machine with at least 7 to
   15 iterations.
2. Run iosMath and SwiftMath candidates with the tracked rich-block math corpus
   and emit JSON + Markdown summaries into the ignored benchmark archive.
3. Extend the Mermaid benchmark matrix with explicit cold-process and
   warm-process official renderer runs; the current matrix already covers
   disabled fallback and cache hit.
4. Re-run current renderer, official cache-hit, and math candidates on a quiet
   machine before changing defaults.
5. Only after those artifacts exist, pick the default behavior.
