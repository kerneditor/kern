# Mermaid ASCII Renderer Improvement — 2026-06-21

## Scope

Kern's Mermaid `ascii` mode was upgraded from a parser-inventory/source fallback
into an actual native Unicode-grid renderer for the Mermaid subsets Kern already
parses locally.

The implementation is native Swift/AppKit/TextKit code. It does not add a Node,
JavaScript, WebView, Electron, or Tauri dependency.

## Inspirations reviewed

- kais-radwan/ascii-mermaid
- AlexanderGrooff/mermaid-ascii
- lukilabs/beautiful-mermaid

The useful design pattern from these projects is graph-to-grid rendering:
construct a character canvas, render boxes/shapes, route edges, draw arrows, and
preserve readable source fallback for unsupported Mermaid.

Kern did not vendor or copy these implementations. The current change implements
a Kern-native renderer around the existing `MermaidMiniParser` and attachment
pipeline.

## Implemented behavior

- Flowcharts render as compact Unicode-grid diagrams.
- Sequence diagrams render participant boxes, lifelines, and message arrows.
- Edge labels are shown when the mini parser extracts them.
- Sequence ASCII now keeps sequence parsing isolated from flowchart parsing, so
  arrows such as `Cache-->>Kern` do not create fake participant names like
  `Cache--`.
- Sequence participants are spread across the available attachment width, which
  reduces message-label clipping.
- HTML `<br>` label fragments are compacted into readable slash-separated text.
- Unsupported Mermaid families render as a source-preserving ASCII panel with
  parsed node/edge counts. The panel uses the outer Mermaid attachment chrome
  only, so it avoids a fake nested window and avoids clipped raw source text.
- Invalid Mermaid still does not crash.
- ASCII drawing now respects flipped AppKit/TextKit coordinates, fixing the
  previous upside-down visual rendering issue.
- Shaped edge endpoints such as `A[Start] --> B{Decision}` now parse as real
  edges for layout/ranking.
- ASCII canvas sizing now uses safer monospace width rounding and extra padding
  to reduce edge clipping.
- ASCII mode now draws directly inside the Mermaid attachment chrome instead of
  adding a second rounded AppKit canvas. This removes the visual "double window"
  effect while keeping the ASCII/unicode diagram content centered.

## Validation

Targeted regression:

```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -derivedDataPath .derived-data/rich-block-eval -only-testing:KernTextKitTests/NativeMarkdownCodecMermaidLayoutTests/testMermaidASCIIRenderModeUsesCompactBounds test
```

Result: passed, 1 test, 0 failures.

Visual eval:

```bash
./scripts/eval-rich-block-rendering.sh
```

Result: passed, 1 targeted eval test, 0 failures.

Latest visual artifact:

```text
test-results/rich-block-eval/20260621-202239/mermaid-ascii-dark.png
```

Final app rebuild:

```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -configuration Debug -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .derived-data/native build
```

Result: build succeeded.

Process hygiene check after validation found no matching Kern, KernTextKitTests,
or Kern xcodebuild processes left running.

## Focused Mermaid benchmark smoke

Command path:

```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -derivedDataPath .derived-data/rich-block-eval -only-testing:KernTextKitTests/NativeMermaidRenderModeBenchmarkTests/testMermaidRenderModeBenchmarkMatrix test
```

The benchmark gate was enabled through the `com.gradigit.kern.tests` defaults
domain for this run and then cleaned up.

Artifact:

```text
benchmark-archive/mermaid-render-modes/20260621-195512-mermaid-render-modes.md
```

3-run smoke results:

| Mode | p50 ms | p95 ms | Mean ms | Effective modes |
|---|---:|---:|---:|---|
| `rich` | 38.60 | 40.70 | 39.33 | rich:300 |
| `ascii` | 50.52 | 52.28 | 51.12 | ascii:300 |
| `auto` | 39.13 | 39.87 | 39.34 | rich:300 |

Interpretation:

- The upgraded visual ASCII renderer is more useful visually, but this smoke
  benchmark shows it is slower than rich for import + attachment-bounds on this
  generated fixture.
- This is acceptable for a readability/fallback mode.
- Do not claim ASCII is a performance win until it is optimized and re-run on a
  quiet machine with more iterations.
- `auto` remained near rich because it selected rich for this fixture.

## Follow-up clipping/generic fallback pass

After visual QA, the initial Unicode-grid pass still had two quality issues:

1. unsupported Mermaid families looked blank/not rendered because they were just
   source fallback; and
2. tight canvas sizing could visually clip long labels or border-adjacent text.

The first follow-up pass added generic fallback rendering and extra canvas
width/height safety. A second follow-up removed the inner AppKit rounded canvas
used by ASCII drawing and changed unsupported Mermaid families to a readable
source panel, so ASCII content now has one attachment card rather than an outer
card plus inner card. Validation reran successfully at:

```text
test-results/rich-block-eval/20260621-202239/mermaid-ascii-dark.png
```

## Remaining work

1. Add a dedicated pure-ASCII glyph option if we want terminal-only output in
   addition to Unicode box drawing.
2. Add shape-aware rendering for decision diamonds, database cylinders, rounded
   nodes, and subgraph grouping.
3. Improve edge routing for crowded multi-rank graphs.
4. Add quiet-machine benchmark comparison after any routing optimization.
