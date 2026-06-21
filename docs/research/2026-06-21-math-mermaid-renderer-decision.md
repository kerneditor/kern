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
- Mermaid render mode preference values: `rich`, `ascii`, and `auto`;
- rich-block performance plans that already call out future math/Mermaid
  renderer benchmark cases.

The current renderer is fast and native, but it is not full TeX layout and it is
not full Mermaid parity.

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

## Math recommendation

Prototype both SwiftMath and iosMath behind a narrow internal interface before
committing to either dependency:

```swift
protocol NativeMathRenderingBackend {
    var name: String { get }
    func measure(expression: String, displayMode: MathDisplayMode, maxWidth: CGFloat) -> CGSize
    func draw(expression: String, displayMode: MathDisplayMode, in rect: CGRect, context: CGContext)
}
```

Evaluation gates:

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

Initial bias: try iosMath first for maturity and current release activity; try
SwiftMath immediately after for Swift-native integration. Choose the one that
wins the actual integration + visual + perf gates, not by repo description.

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

## Mermaid recommendation

Add a new preference value, not a replacement:

- `Native rich` — current native drawn renderer;
- `ASCII` — current fast fallback;
- `Auto` — current complexity-based choice;
- `Official Mermaid (external, cached)` — optional high-fidelity renderer when a
  configured `mmdc` executable is available.

Runtime behavior:

1. Hash key: Mermaid source + render mode + theme + width bucket + renderer
   version.
2. If official cache hit exists, display cached SVG/PDF/image attachment.
3. If missing, render asynchronously off-main; show native fallback immediately.
4. If render fails, keep native fallback and expose a non-blocking diagnostic.
5. Never block initial document open on official rendering.

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
