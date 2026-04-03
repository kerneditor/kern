---
title: "Deep study: ascii-mermaid + beautiful-mermaid for KernTextKit integration"
date: "2026-02-25"
depth: "full"
author: "codex"
status: "completed"
---

# Deep study: ascii-mermaid + beautiful-mermaid for KernTextKit integration

## Scope and input

User requested parallel deep research on three links; two are unique repositories:

1. `kais-radwan/ascii-mermaid` (listed twice)
2. `lukilabs/beautiful-mermaid`

Both repositories were cloned locally and analyzed at code level. Tests/benchmarks were run locally where possible.

## Study execution

### Decomposition (Self-Ask)

Main question: what can KernTextKit reuse from these repos, and what should be discarded?

Sub-questions:
1. What each repo *actually* implements vs README claims.
2. Architecture and algorithmic components reusable in a native Swift/AppKit editor.
3. Runtime/tooling constraints and blocker risks.
4. Maturity and reliability signals (tests, CI, docs, release hygiene).
5. ROI: direct integration vs algorithm port vs discard.

### Sources and quality

| Source | Type | Quality | Notes |
|---|---|---|---|
| cloned code in `.study/2026-02-25-mermaid-repos/ascii-mermaid` | primary | high | direct inspection of parser/renderer/plugin code |
| cloned code in `.study/2026-02-25-mermaid-repos/beautiful-mermaid` | primary | high | direct inspection of parser/layout/renderer/tests |
| local test runs (`node --test`, `bun test`) | primary | high | validated runtime behavior and maturity |
| local benchmark run (`bun run bench.ts`) | primary | high | measured repo-reported perf profile |
| GitHub API metadata | primary | medium-high | stars/forks/activity/license signals |

## Repo A: ascii-mermaid (kais-radwan)

### What it is

A Neovim plugin with a TypeScript rendering engine that converts Mermaid text to ASCII/Unicode diagrams.

- Lua side: detects Mermaid blocks + manages extmarks/overlay behavior.
- Node side: pure TypeScript parser + ASCII renderer.

### Architecture map

- Public TS entry: `ts/src/index.ts`
- Core parser (flowchart/state): `ts/src/parser.ts`
- Diagram-specific parsers:
  - sequence: `ts/src/sequence/parser.ts`
  - class: `ts/src/class/parser.ts`
  - ER: `ts/src/er/parser.ts`
  - gantt: `ts/src/gantt/parser.ts`
  - pie: `ts/src/pie/parser.ts`
  - timeline: `ts/src/timeline/parser.ts`
- ASCII pipeline:
  - dispatch: `ts/src/ascii/index.ts`
  - graph conversion: `ts/src/ascii/converter.ts`
  - grid placement: `ts/src/ascii/grid.ts`
  - pathfinding/routing: `ts/src/ascii/pathfinder.ts`, `ts/src/ascii/edge-routing.ts`
  - drawing: `ts/src/ascii/draw.ts`, `ts/src/ascii/canvas.ts`
- Neovim integration:
  - setup/commands: `lua/ascii-mermaid/init.lua`
  - detection: `lua/ascii-mermaid/detect.lua`
  - node bridge: `lua/ascii-mermaid/render.lua`
  - display overlay: `lua/ascii-mermaid/display.lua`

### Maturity signals

- License: MIT.
- Commit history: small, single primary author.
- Tests:
  - TS tests (`node --test`) pass: 80/80.
  - Neovim integration tests exist.
- CI: lightweight (limited visible automation compared with larger libs).

### Strengths for Kern

1. Clear, understandable ASCII rendering pipeline.
2. Good small-scale fixture set for diagram correctness.
3. Useful UX ideas from display modes (`inline` / `replace` / `hybrid`).

### Limitations for Kern

1. Runtime model assumes Node + Lua + Neovim APIs.
2. Architecture optimized for in-editor virtual text overlays, not native attributed rendering.
3. Smaller coverage and ecosystem depth than `beautiful-mermaid`.

## Repo B: beautiful-mermaid (lukilabs)

### What it is

A TypeScript Mermaid renderer producing both SVG and ASCII output, built around synchronous rendering and rich theming.

### Architecture map

- Public API/router: `src/index.ts`
- Flowchart/state parser: `src/parser.ts`
- Type model: `src/types.ts`
- ELK-backed layout:
  - adapter/engine: `src/layout-engine.ts`
  - sync ELK worker bypass: `src/elk-instance.ts`
- SVG renderer/theming:
  - renderer: `src/renderer.ts`
  - theme model + derived color system: `src/theme.ts`
  - typography metrics: `src/text-metrics.ts`
- ASCII subsystem:
  - entry: `src/ascii/index.ts`
  - converter/grid/pathfinder/routing/draw modules under `src/ascii/*`
  - added edge bundling: `src/ascii/edge-bundling.ts`
- Specialized diagram stacks:
  - sequence: `src/sequence/*`
  - class: `src/class/*`
  - ER: `src/er/*`
- Tooling/quality:
  - tests: `src/__tests__/*`
  - perf harness: `bench.ts`
  - sample corpus: `samples-data.ts`
  - CI workflows in `.github/workflows/*`

### Maturity signals

- License: MIT.
- Community: high activity/signals (stars/forks and recency are substantially higher than ascii-mermaid).
- Tests: `bun test` passed 637 tests across 19 files.
- Benchmark harness: renders 70 samples with per-sample timings.

### Strengths for Kern

1. Much stronger test coverage and fixture breadth.
2. Cleanly modular parser/layout/renderer split.
3. Rich theming model with deterministic color derivation.
4. High-value layout post-processing ideas (bundling, clipping, routing adjustments).
5. Established performance harness and sample catalog that can be mirrored.

### Limitations for Kern

1. Core layout depends on ELK.js runtime assumptions.
2. Bun/TS-centric tooling is not directly portable to Xcode/Swift.
3. Direct code reuse is low due to language/runtime mismatch.

## Cross-repo comparison

| Dimension | ascii-mermaid | beautiful-mermaid | Better candidate |
|---|---|---|---|
| Primary target | Neovim plugin | General TS rendering library | beautiful-mermaid |
| Output modes | ASCII/Unicode | SVG + ASCII/Unicode | beautiful-mermaid |
| Test depth | moderate | very high | beautiful-mermaid |
| Architecture modularity | good | very good | beautiful-mermaid |
| Native Swift direct reuse | low | low | tie (both low) |
| Algorithmic reuse value | medium | high | beautiful-mermaid |
| Integration blockers | Node+Lua+Neovim | TS+Bun+ELK | both blocked for direct embed |

## What Kern should take vs discard

## Reuse candidates (recommended)

### 1) Theme derivation model (take)

Source:
- `beautiful-mermaid/src/theme.ts`

Why:
- Two-color base + derived tokens is ideal for deterministic, low-jitter theme behavior.
- Maps well to native `NSColor`/semantic palette generation.

Effort: Small.
Risk: Low.

### 2) Layout post-processing heuristics (take)

Source:
- `beautiful-mermaid/src/layout-engine.ts`
- `beautiful-mermaid/src/shape-clipping.ts`
- `beautiful-mermaid/src/ascii/edge-bundling.ts`

Why:
- Useful regardless of final layout engine.
- Can improve edge clarity and reduce overlaps in native rendering.

Effort: Medium.
Risk: Medium (requires strong regression tests).

### 3) ASCII routing/grid algorithms as reference (partial take)

Source:
- `ascii-mermaid/ts/src/ascii/*`
- `beautiful-mermaid/src/ascii/*`

Why:
- Strong reference implementations for deterministic text layout.
- Valuable for optional export/debug mode.

Effort: Large.
Risk: Medium-high.

### 4) Fixtures + benchmark methodology (take)

Source:
- `beautiful-mermaid/samples-data.ts`
- `beautiful-mermaid/bench.ts`
- `ascii-mermaid/ts/test/*.test.js`

Why:
- Immediate benefit for Kern performance/correctness validation.

Effort: Small.
Risk: Low.

## Discard candidates (do not integrate)

1. Neovim/Lua runtime layer from ascii-mermaid (`lua/ascii-mermaid/*`) — non-portable to AppKit.
2. Bun-specific dev/deploy tooling from beautiful-mermaid (`dev.ts`, `wrangler` flow) — not relevant to Kern shipping path.
3. Attempting direct JS runtime embedding just to reuse these engines — high complexity, poor ROI vs native port.

## Final verdict

- **Do not directly integrate either repo as runtime dependency in KernTextKit.**
- **Partially integrate concepts and assets**, prioritizing `beautiful-mermaid` as the primary reference.
- Treat `ascii-mermaid` as secondary reference for Neovim UX ideas and compact ASCII heuristics.

## Recommended implementation order for Kern

1. Import and normalize fixture corpus into Kern test fixtures (Small).
2. Implement native theme-derivation layer inspired by `beautiful-mermaid/theme.ts` (Small).
3. Add/extend snapshot + perf tests around Mermaid rendering path (Small).
4. Port selected post-layout heuristics (edge clipping/bundling/alignment) in Swift (Medium).
5. Evaluate optional ASCII export mode only if product requires it (Large, optional).

## Confidence and uncertainty

- Confidence: **High** on architectural and maturity conclusions (code + tests executed locally).
- Uncertainty: **Medium** on exact Swift port effort until chosen Kern diagram layout engine constraints are finalized.

## Appendices

### Local clone paths

- `.study/2026-02-25-mermaid-repos/ascii-mermaid`
- `.study/2026-02-25-mermaid-repos/beautiful-mermaid`

### Commands executed (high level)

- Clone/fetch both repos.
- Run ascii-mermaid TS tests: `node --test test/*.test.js`.
- Run beautiful-mermaid tests: `bun test src/__tests__/`.
- Run beautiful-mermaid benchmark: `bun run bench.ts`.
- Inspect key source files across parser/layout/renderer/ascii modules.
