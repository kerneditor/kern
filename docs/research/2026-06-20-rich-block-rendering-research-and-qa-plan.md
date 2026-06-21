# Rich block rendering research and QA plan

Date: 2026-06-20

Scope: images, block math, inline math, and Mermaid diagrams in Kern’s native
TextKit editor.

## Summary recommendation

1. **Images should center by default** when they are narrower than the readable
   document column. Full-width/wide images should still naturally fill the
   available column. Longer term, expose per-block image alignment
   left/center/right, with center as the default.
2. **Math should move from source-normalization to a real typesetting pipeline.**
   The current renderer is intentionally lightweight and deterministic, but it
   cannot match KaTeX, MathJax, GitHub, or Typora quality.
3. **Mermaid should be treated as two renderers, not one.**
   Keep Kern’s native mini renderer as a fast, no-runtime fallback for simple
   diagrams, but add a cached canonical SVG pipeline for complex diagrams.
4. **Math/Mermaid rendering must be async and cache-backed.**
   No cold rendering work should run on the keystroke hot path. TextKit should
   draw already-resolved attachments, placeholders, or cached vectors.
5. **Before merging a higher-fidelity renderer, build a dedicated rich-block
   visual QA suite.** Existing snapshot and benchmark tests are useful, but they
   do not yet prove broad Mermaid syntax fidelity or pixel-level math quality.

## External platform findings

### Images

Notion treats images/media as block-level content that can be resized and aligned
left, center, or right. The practical product lesson for Kern is:

- default center alignment feels polished for document/writing use;
- alignment should not be forced globally forever;
- when the media already fills the content width, separate alignment controls are
  less meaningful.

Kern should preserve Markdown source portability. Alignment should therefore be:

- editor-local presentation by default;
- optionally persisted only if Kern introduces explicit extension metadata or
  supports source-level HTML/image attributes.

### Math

Observed platform patterns:

- GitHub renders mathematical expressions from LaTeX-style Markdown using
  MathJax.
- MathJax emphasizes high-quality typography, SVG/HTML output modes,
  accessibility, copying, zooming, and broad TeX/MathML/AsciiMath support.
- KaTeX emphasizes speed, synchronous rendering, no dependencies, server-side
  rendering to strings, and TeX-quality layout.
- Typora continuously updates math package/macro support and treats math as a
  first-class WYSIWYG/document feature.

Kern’s current math renderer is not in the same class. It normalizes a subset of
TeX-ish source to readable plain text. That is valuable as a safe fallback, but
not as the final visual renderer.

#### Math options for Kern

| Option | Fidelity | Performance | Native fit | Risk |
|---|---:|---:|---:|---|
| Current plain/native renderer | Low | Excellent | Excellent | Low |
| More native Swift parser/layout | Medium | Excellent if scoped | Excellent | High implementation effort |
| KaTeX-generated HTML/MathML | High | Good | Medium because AppKit HTML/CSS mapping is awkward | Medium |
| MathJax-generated SVG | Very high | Medium | Good if treated as vector attachment | Medium/high |
| External render worker to SVG/PDF/PNG | High/very high | Cold path slower, warm path good | Good with cache | Medium |

Recommended path:

1. Keep the current renderer as fallback.
2. Add a high-fidelity cached renderer for block math first.
3. Prefer SVG/vector attachments over bitmap PNG so zoom and retina rendering
   stay sharp.
4. Use KaTeX as the first renderer candidate for speed, and evaluate MathJax
   where compatibility/accessibility is more important.
5. For inline math, start with carefully sized cached vector attachments only
   after block math is stable, because inline baseline alignment is much harder.

### Mermaid

Observed platform patterns:

- GitHub supports Mermaid in fenced code blocks and documents Mermaid version
  visibility through an `info` diagram.
- Mermaid is a JavaScript diagramming engine with a Markdown-like syntax.
- Mermaid CLI generates SVG/PNG/PDF from Mermaid definitions, but the CLI path is
  Chromium/Puppeteer-heavy.
- Typora documents Mermaid diagrams as non-standard Markdown/CommonMark/GFM and
  recommends exporting/using images when portability matters.

Kern’s current Mermaid renderer is a native mini renderer. It parses a subset of
flowchart and sequence syntax, caps nodes/edges, falls back for generic syntax,
and uses a simplified layout. That is a good fast preview, but it cannot be
described as full Mermaid compatibility.

#### Mermaid options for Kern

| Option | Fidelity | Performance | Native fit | Risk |
|---|---:|---:|---:|---|
| Current native mini renderer | Low/medium | Excellent | Excellent | Low |
| Improve Swift mini parser/layout | Medium | Good/excellent | Excellent | Medium/high for diminishing returns |
| Mermaid CLI to SVG | Canonical/high | Heavy cold path | Medium | High dependency/packaging cost |
| Bundled JS render worker to SVG | Canonical/high | Medium after warmup | Medium | Medium/high |
| Require user-installed renderer | High if installed | Variable | Medium | Bad first-run UX |

Recommended path:

1. Keep fast native mini rendering for simple diagrams.
2. Add an explicit support boundary: “Native preview supports common flowchart
   and sequence diagrams; canonical mode handles broader Mermaid syntax.”
3. Add optional canonical SVG renderer behind a setting:
   - Fast native
   - Canonical SVG
   - Auto
4. In Auto mode, use native rendering for simple parsed diagrams and canonical
   SVG for complex or unsupported syntax.
5. Cache by source hash, theme, scale factor, render mode, and content width.

## Performance model

### Hot path rules

- Do not spawn Node, Chromium, or any external process synchronously during
  editing.
- Do not parse/render Mermaid fully on every keystroke.
- Do not decode large images on the main thread.
- Do not block TextKit layout waiting for a cold math/Mermaid render.

### Expected performance profile

These are initial budgets to validate with benchmarks, not claims.

| Surface | Warm/cache-hit target | Cold target | Notes |
|---|---:|---:|---|
| Local image draw | paint-only | async decode | current image cache direction is correct |
| Inline math | < 1-2 ms | async if complex | baseline alignment risk is the hard part |
| Block math | paint-only | tens of ms async for KaTeX-like path | SVG/vector cache preferred |
| Native Mermaid mini | low ms | low ms | okay for simple diagrams |
| Canonical Mermaid SVG | paint-only | hundreds of ms to seconds if Chromium-backed | must be async/cache-backed |

### Cache keys

Use distinct cache keys for:

- normalized source;
- renderer type and version;
- theme/color mode;
- content width bucket;
- backing scale factor;
- font family/size where relevant;
- error/fallback state.

## Rich-block QA and eval pipeline

### Fixture corpus

Create a dedicated fixture directory for rich blocks with small, named cases:

#### Images

- small local PNG
- wide local PNG
- tall local PNG
- transparent PNG
- SVG if supported
- broken local image
- remote image disabled
- remote image enabled with test protocol
- alt text/caption behavior
- left/center/right alignment once supported
- image in list, quote, table, and near headings

#### Math

- inline simple expressions
- inline baseline stress next to text with descenders/ascenders
- fractions
- roots
- sums/products/integrals
- matrices
- cases/aligned equations
- multiline block equations
- macros
- invalid TeX
- escaped dollar signs
- math in list, quote, table, callout, and heading-adjacent contexts

#### Mermaid

- flowchart TD and LR
- graph aliases
- sequence diagrams
- class diagrams
- state diagrams
- ER diagrams
- pie charts
- journey
- Gantt
- Gitgraph
- mindmap
- timeline
- quadrant
- Sankey
- requirement
- C4
- long labels
- unicode labels
- Markdown/HTML-ish labels
- links/click directives
- init/theme directives
- invalid syntax
- huge graph stress case
- cyclic graph case

### Oracle generation

Do not make Kern’s mini renderer the oracle for correctness.

- Math oracle:
  - generate KaTeX SVG/HTML references;
  - generate MathJax SVG references for broader compatibility samples;
  - store normalized expected dimensions and reference renders.
- Mermaid oracle:
  - generate official Mermaid SVG references;
  - record Mermaid engine version in the artifact manifest;
  - store unsupported-feature metadata for cases where native mini mode is
    expected to fall back.

### Automated checks

1. **Source preservation tests**
   - Import/export keeps original Markdown semantics.
   - Invalid math/Mermaid does not corrupt source.
2. **Geometry tests**
   - attachment width matches readable column policy;
   - image/math/Mermaid centering is within a one-pixel tolerance;
   - inline math baseline delta stays within a strict pixel threshold;
   - top badges/chrome do not overlap content.
3. **Pixel snapshots**
   - crop-level snapshots for each rich block, not only whole-window snapshots;
   - light/dark theme matrix;
   - full-width and centered-readable matrix;
   - 1x and 2x scale where feasible.
4. **Perceptual diff**
   - RGBA exact diff for deterministic native output;
   - perceptual/SSIM-style threshold for antialiased SVG output;
   - mandatory failure artifacts: actual, expected, diff heatmap, crop manifest.
5. **Performance benchmarks**
   - cold render;
   - warm cache draw;
   - repeated edit churn near a block;
   - scroll through a document with many rich blocks;
   - memory growth after opening/closing large rich-block documents.
6. **Fallback tests**
   - invalid syntax produces safe fallback;
   - renderer timeout produces safe fallback;
   - renderer process crash does not crash Kern;
   - renderer output cannot fetch remote resources unless explicitly allowed.

### Manual visual QA checklist

Before enabling canonical rendering by default:

- inspect contact sheets for all fixtures in light and dark themes;
- inspect 700, 900, 1120, and 1440 px windows;
- inspect centered max widths 560, 760, 1000, and 1400 px;
- verify images look intentional in both centered and full-width modes;
- verify math baselines next to normal text at 14, 16, 18, and 22 pt;
- verify Mermaid labels are legible and clipped only when expected;
- verify accessibility labels/source fallback are available for attachments;
- verify export still preserves original source.

## Implementation milestones

### Milestone 1: image centering

- Center image attachments within the readable line fragment when narrower than
  the content column.
- Add geometry tests for small/wide/tall images.
- Add snapshot crops for image alignment in full-width and centered modes.

### Milestone 2: rich-block visual QA harness

- Create fixture corpus and crop/contact-sheet generator.
- Add artifact manifest with theme, width, renderer version, and scale.
- Add geometry checks for current math/Mermaid renderers before changing
  renderer engines.

### Milestone 3: math renderer spike

- Prototype KaTeX-to-SVG or MathJax-to-SVG worker.
- Measure cold/warm/block/inline costs.
- Compare visual output to current fallback in screenshots.
- Keep fallback renderer in place.

### Milestone 4: Mermaid canonical renderer spike

- Prototype official Mermaid-to-SVG worker.
- Measure cold/warm/large-diagram costs.
- Define timeout and fallback behavior.
- Decide whether packaging cost is acceptable for v0.1 or should remain
  optional/experimental.

### Milestone 5: settings and defaults

- Add explicit user-facing render settings only after the renderer behavior is
  validated:
  - Image alignment: default center.
  - Math rendering: native fallback / high fidelity / auto.
  - Mermaid rendering: native fast / canonical SVG / auto.

## Current Kern-specific assessment

Current strengths:

- image loading already uses validation, asynchronous local/remote loading, and
  bounded cache limits;
- Mermaid mini renderer has a basic mode setting and benchmark hook;
- snapshot infrastructure exists and can be extended;
- recent layout work made math/Mermaid blocks use the readable column more
  consistently.

Current gaps:

- image attachments are sized but not intentionally centered as a product rule;
- math is not real math typesetting;
- Mermaid is subset rendering, not full Mermaid;
- QA does not yet include broad Mermaid syntax, oracle SVG references, crop
  snapshots, or pixel-level rich-block geometry checks;
- performance benchmarks do not yet cover canonical external renderers because
  those renderers do not exist.
