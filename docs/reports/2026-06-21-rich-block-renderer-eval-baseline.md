# Rich Block Renderer Eval Baseline — 2026-06-21

## Scope

This is the first structured correctness/fidelity corpus run for Kern's math and
Mermaid rich-block rendering pipeline.

It is **not** a timing benchmark. Performance decisions use the native benchmark
report, and quiet-machine reruns are still required before product claims.

## Command

```bash
./scripts/eval-rich-block-rendering.sh
```

For official external visual QA, the latest run used a pre-seeded official
Mermaid cache and an intentionally failing renderer command so valid diagrams
came from cached official PNGs while the invalid case exercised failure fallback:

```bash
KERN_OFFICIAL_MERMAID_RENDERER_COMMAND=/usr/bin/false \
KERN_OFFICIAL_MERMAID_CACHE_DIR="$PWD/test-results/official-mermaid-cache/20260621-width896-visual" \
KERN_OFFICIAL_MERMAID_VISUAL_TIMEOUT_SECONDS=8 \
./scripts/eval-rich-block-rendering.sh
```

## Result

- Xcode result: passed.
- XCTest target: `KernTextKitTests/NativeRichBlockEvalCorpusTests/testRichBlockEvalCorpus`.
- Test execution: 1 targeted test, 0 failures.
- Visual artifacts: 10 PNG contact sheets generated and inspected.
- Latest generated local artifacts:
  - `test-results/rich-block-eval/20260621-223840/rich-block-eval.md`
  - `test-results/rich-block-eval/20260621-223840/rich-block-eval.json`
  - `test-results/rich-block-eval/20260621-223840/visual-index.md`
  - `test-results/rich-block-eval/20260621-223840/math-dark.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-rich-dark.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-ascii-dark.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-officialExternal-dark.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-officialExternal-light.png`
  - `test-results/rich-block-eval/20260621-223840/mermaid-officialExternal-dark-invalid-crop.png`
- These raw artifacts are intentionally ignored by Git under `test-results/`.

## Corpus coverage

| Corpus | Cases | Semantic pass | Fidelity gaps |
|---|---:|---:|---:|
| Math | 14 | 14 | 12 |
| Mermaid | 17 | 17 | 14 |

## Visual QA interpretation

### Official Mermaid external mode

The final visual run shows that `officialExternal` now works as intended:

- valid official-rendered diagrams display cached Mermaid CLI PNGs in both light
  and dark mode;
- cache keys are width-aware and theme-aware;
- invalid Mermaid does not hang and does not stay stuck in the rendering state;
- failed official render displays the native rich fallback and the diagnostic
  `Official renderer failed; showing native rich fallback.`

### Mermaid ASCII

ASCII mode renders parsed flowcharts and sequence diagrams as compact
Unicode-grid diagrams with boxes, connectors, arrows, edge labels, and sequence
lifelines. Unsupported Mermaid families render through a source-preserving ASCII
panel with parsed node/edge counts. The previous double-window visual effect is
removed.

ASCII is now a readable fallback. It should not be described as official Mermaid
parity or as a proven performance win.

### Math

Kern currently preserves math source and produces semantic inline/block math
representations for the eval corpus, but most non-trivial TeX cases remain visual
fidelity gaps.

Expected gaps for the current lightweight native renderer:

- nested fractions;
- stretchy delimiters;
- matrices;
- aligned equations;
- `\operatorname` / text-heavy formulas;
- accents and vector notation;
- high-quality limit placement.

This supports the current renderer-decision plan: keep Kern's current renderer as
fallback, then compare iosMath and SwiftMath through the same corpus before
choosing a dependency.

### Mermaid

Kern preserves Mermaid source and produces attachments for all cases in the eval
corpus, including unsupported or invalid syntax. Full official Mermaid parity is
available only through the optional official external renderer cache path.

Known native fallback gaps:

- subgraphs;
- HTML/Markdown labels and Notion-style line breaks;
- advanced sequence constructs;
- class/state/ER/Gantt/gitGraph/pie/mindmap/timeline/journey/sankey diagrams;
- official layout/theme fidelity.

## Follow-up gates

1. Run quiet-machine baseline timing for current math and Mermaid renderers.
2. Re-run iosMath and SwiftMath candidates against the math corpus with 7-15
   iterations and visual contact sheets.
3. Add deterministic snapshot coverage only for renderer states that can be made
   stable in CI.
4. Store future run summaries as tracked reports and keep raw generated artifacts
   under ignored `test-results/` or `benchmark-archive`.
