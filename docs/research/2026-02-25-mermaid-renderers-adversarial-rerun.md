---
title: "Adversarial rerun: ascii-mermaid, beautiful-mermaid, mermaid-ascii"
date: "2026-02-25"
depth: "full"
mode: "adversarial"
author: "codex"
status: "completed"
---

# Adversarial rerun: ascii-mermaid, beautiful-mermaid, mermaid-ascii

## Scope

This rerun re-investigated all three repositories with an adversarial lens:

1. kais-radwan/ascii-mermaid (listed twice in original input)
2. lukilabs/beautiful-mermaid
3. AlexanderGrooff/mermaid-ascii

Work performed:
- Fresh local clone/update of each repository.
- Deep code reading of parser/layout/renderer/test/tooling modules.
- Test execution where available.
- Cross-check of README claims against implementation.
- Adversarial synthesis (arguments for and against adoption).

## Verified execution artifacts

### Local test/benchmark reruns

- `ascii-mermaid`: TypeScript tests passed (`80` tests, `0` failures).
- `beautiful-mermaid`: Bun test suite passed (`637` tests, `0` failures).
- `beautiful-mermaid`: benchmark script executed (`70` samples, aggregate timing output).
- `mermaid-ascii`: `go test ./...` passed.

### Notable metadata snapshot

- `ascii-mermaid`: low-star, very new repo, single primary maintainer pattern.
- `beautiful-mermaid`: much larger adoption signal and active push cadence.
- `mermaid-ascii`: older, stable Go codebase with release workflow.

## Claims-vs-reality (high-signal summary)

### ascii-mermaid

- **Claim:** broad direction support and robust Mermaid rendering in Neovim.
- **Reality:** core rendering pipeline is real and works, but ASCII path has known constraints (e.g., RL handling caveat in TS code comments/logic). Neovim UX layer is tightly coupled to extmarks and Node process invocation.
- **Impact:** algorithmic ideas are reusable; runtime integration is not.

### beautiful-mermaid

- **Claim:** synchronous, fast SVG/ASCII rendering with broad diagram support and rich theming.
- **Reality:** feature breadth and tests are strong, but sync ELK path uses internal worker mechanics that increase fragility risk across dependency upgrades; ASCII path has direction caveats for RL.
- **Impact:** strong source for algorithms/themes/fixtures; weak candidate for direct embedding.

### mermaid-ascii

- **Claim:** CLI/web renderer with robust graph/sequence support and configurable output.
- **Reality:** graph/sequence rendering works and tests pass, but architecture relies on package-level mutable state in cmd path and is CLI/web oriented. Some docs lag implementation (e.g., TODO mentions that are partially outdated).
- **Impact:** good for algorithm reference and fixture corpus; poor direct runtime fit for native AppKit editor.

## Adversarial findings by severity

### P1 (critical)

1. **Direct runtime embedding risk is high for all three** due to language/runtime mismatch with Kern (Swift/AppKit/TextKit) and dependency/runtime side effects.
2. **beautiful-mermaid sync-ELK coupling risk**: uses internal worker-path assumptions to force sync layout; this is fragile under upstream changes.

### P2 (important)

1. **Direction support caveats in ASCII paths** (notably RL behavior in TS implementations) can create correctness mismatches vs user expectation.
2. **State/config mutation concerns in mermaid-ascii cmd/web path** reduce confidence for library-style embedding without refactor.

### P3 (nice-to-have)

1. Docs/README claim drift exists in places (e.g., TODOs vs implemented pieces).
2. Some test suites are excellent (`beautiful-mermaid`), others are lighter/less CI-enforced.

## What to take, what to reject

## Take (recommended)

1. **Theme derivation approach** from `beautiful-mermaid/src/theme.ts`.
2. **Layout post-processing heuristics** (edge clipping/bundling/alignment) from `beautiful-mermaid` layout stack.
3. **ASCII/grid/pathfinding concepts** from both TS and Go repos as algorithm references.
4. **Fixture/benchmark methodology** from `beautiful-mermaid` and `mermaid-ascii` testdata.

## Reject (recommended)

1. Directly embedding Node/Bun/Lua pipelines into Kern runtime.
2. Reusing Neovim display/overlay code as-is.
3. Shipping external CLI dependency as core renderer path for live editing.

## Decision matrix (adversarial synthesis)

Scored options:

- Direct integration: **No-Go**
- Partial algorithm port into native Swift: **Best option**
- Fixture-only reuse: useful but insufficient alone
- Full discard: leaves valuable algorithm/test insights on table

## Final recommendation

Proceed with **partial algorithm port** only:

1. Port theme model + color derivation first.
2. Import fixture corpora and establish snapshot/perf gates.
3. Port layout post-processing heuristics selectively.
4. Keep rendering runtime fully native in Swift; avoid JS/Lua/CLI runtime dependencies.

Confidence: **High** on architectural fit/no-fit conclusions; **Medium** on exact engineering effort until target Swift layout implementation details are fixed.

## Primary local evidence paths

- `.study/2026-02-25-mermaid-repos/ascii-mermaid`
- `.study/2026-02-25-mermaid-repos/beautiful-mermaid`
- `.study/2026-02-25-mermaid-repos/mermaid-ascii`
