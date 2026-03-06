---
title: "feat: Full-fidelity parser throughput phase 3"
type: feat
date: 2026-03-02
status: in_progress
owner: kern-editor
---

# feat: Full-fidelity parser throughput phase 3

## Objective

Close the remaining full-fidelity p50 gap against Zed without disabling WYSIWYG features, while preserving interactivity and eliminating scroll-hang risk.

## Baseline and blocker

- Current open-ready target is met (Kern << 500ms).
- Full-fidelity remains behind Zed in official apples-to-apples runs.
- Measured dominant cost is staged promotion parse total (~2.0s on benchmark fixture).
- Staged-slice microbench shows near-linear parse scaling (~52ms @128k, ~442ms @1M), indicating parser throughput (not scheduler variance) is the hard blocker.

## Adversarial constraints

1. No feature disablement hacks (parsing/styling must remain functionally complete).
2. No user-visible freezes from heavy main-thread parse slices.
3. No benchmark-only behavior that diverges from production defaults.
4. Any performance gain must survive variance gates and regression suites.

## Phase 3A — Throughput instrumentation hardening

- [x] Add deterministic full-fidelity profile in benchmark wrapper.
- [x] Add variance gate script (`p95/p50`, CV, failures/timeouts).
- [x] Add staged-slice parse microbench with artifact export.
- [ ] Add parser throughput budget gate (chars/ms floor) from staged-slice report.
- [ ] Add benchmark runbook section for 10-run + 30-run final sign-off protocol.

## Phase 3B — Parser hot-path optimization (safe/refactor-only)

- [ ] Replace repeated per-line newline attributed allocations with reusable baseline artifacts.
- [ ] Audit inline parser hot path for avoidable allocations (character-array construction, repeated temporary strings).
- [ ] Introduce targeted fast path for common markdown line shapes in benchmark fixture while preserving semantics.
- [ ] Add per-function microbench checks (inline parse + paragraph assembly).

## Phase 3C — Staged promotion architecture optimization

- [ ] Prototype incremental promotion parsing that avoids reparsing unchanged prefix regions.
- [ ] Validate correctness for tricky boundary constructs (lists, blockquotes, fences, tables, math, links).
- [ ] Add regression matrix for boundary-crossing promotions.
- [ ] Keep live-scroll deferral and anchor stability guards active.

## Phase 3D — Quality and sign-off gates

- [ ] `./scripts/test-native-editor.sh` pass.
- [ ] `(cd scripts/kern-bench && swift test)` pass.
- [ ] Full-fidelity apples-to-apples official 10-run pass with variance gate.
- [ ] Full-fidelity apples-to-apples official 30-run pass with variance gate.
- [ ] Open-ready official 30-run remains <= 500ms p50.
- [ ] No new scroll-jump / spinner regressions in manual validation.

## Exit criteria

1. Kern leads or ties Zed on official full-fidelity p50 in sign-off runs.
2. Kern stays <=500ms open-ready p50 in official 30-run.
3. Test suites pass and no critical regressions.
4. Release build is rebuilt and reinstalled.

