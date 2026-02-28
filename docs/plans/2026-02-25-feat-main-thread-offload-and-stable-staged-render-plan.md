# Plan: Main-Thread Offload + Stable Staged Rendering (Kern)
Date: 2026-02-25
Owner: kern-editor
Type: feat/perf

## 1) Problem Statement
Kern currently reaches competitive open-ready latency, but real-world UX still degrades on very large files:
- delayed full styling/highlighting,
- viewport jump/drift while staged formatting catches up,
- occasional macOS spinner during aggressive scroll/drag,
- user-visible lag even when typing should remain instantly interactive.

This indicates we are still spending too much work on the UI thread during staged promotion + layout application.

## 2) Goals (Non-Negotiable)
1. Keep all WYSIWYG features enabled (no disabling parsing/styling/highlighting).
2. Make editor interaction immediately responsive (type/scroll/select) after open.
3. Eliminate visible viewport jumping during deferred styling.
4. Prevent spinner hangs during rapid scrollbar drags.
5. Preserve/beat current open-ready target while improving full-fidelity time.

## 3) Success Metrics
Primary:
- `benchmark_open_ready` (large fixture): Kern p50 <= 500ms (official lane).

User-experience gates:
- `wow_full_document_fidelity_ready_latency_ms` (large fixture):
  - p50 <= 5s
  - p95 <= 8s
- Scroll-jank gate during promotion:
  - no >100ms main-thread stall events in test run
  - bounded viewport drift and no oscillation/jump-back loops
- Typing under background promotion:
  - p95 key-to-render latency remains within existing internal target band

Correctness:
- full unit suite green
- no markdown round-trip regressions
- no feature parity regressions in syntax highlighting / attachments / tasks / tables

## 4) Root-Cause Hypotheses
H1. Promotion parse/highlight computation is still too coupled to main-thread cadence.
H2. Promotion apply batches are too heavy or too frequent for current TextKit layout behavior.
H3. Viewport anchoring is not stable under concurrent layout growth + replacement.
H4. Work prioritization favors completion over interactivity; user input must preempt background work harder.

## 5) Architecture Direction
Principle: **Compute off-main, apply minimally on-main, always prioritize interactivity.**

### 5.1 Threading Model
Off-main workers:
- markdown segment parse,
- syntax token/highlight computation,
- promotion diff planning (what range to replace),
- priority queue planning (viewport-first).

Main actor only:
- `NSTextStorage` mutation,
- TextKit layout APIs,
- selection/anchor restore,
- view/frame updates.

### 5.2 Scheduling Model
- Priority queue with classes:
  1. Critical: user input/scroll/selection changes
  2. High: visible viewport styling
  3. Medium: near-viewport lookahead
  4. Low: far-tail full-fidelity catch-up
- Cancellation tokens per render generation + per scroll epoch.
- Strict preemption: input/scroll cancels or pauses low-priority work immediately.

### 5.3 Apply Strategy
- Replace giant promotions with micro-batches (small, bounded apply slices).
- Coalesce layout height recomputation (single timer/epoch-based flush).
- Apply only if generation/token still current.
- Commit to stable anchor policy before and after each batch.

## 6) Implementation Phases

## Phase 0 — Instrumentation & Guardrails (must land first)
- Add per-stage timing and counters:
  - background parse latency,
  - main-thread apply slice duration,
  - queue backlog depth,
  - cancellation/preemption counts,
  - anchor correction deltas.
- Add spinner-risk proxy metric: main-thread slice >16ms/>33ms/>100ms counts.
- Expand benchmark output to include full-fidelity readiness quality gates in large-fixture lane.

Deliverable: measurable baseline with before/after comparability.

## Phase 1 — Background Promotion Compute Pipeline
- Introduce background promotion worker service.
- Move promotion parse/highlight/diff planning off-main.
- Keep results immutable; only final apply on main.
- Enforce generation-token checks at every handoff.

Deliverable: no promotion parsing on main thread.

## Phase 2 — Viewport-First Priority Engine
- Build prioritized work queue keyed by visible range.
- On scroll:
  - re-rank queue,
  - cancel stale far-range work,
  - immediately schedule visible-range styling.
- Add starvation protection for tail completion.

Deliverable: visible region converges first, far content never blocks interaction.

## Phase 3 — Stable Apply + Anchor Pinning
- Apply micro-batches with strict max-size and max-time budget per tick.
- Replace coarse anchor correction with deterministic viewport pinning:
  - lock top visible semantic anchor,
  - adjust only if net drift exceeds threshold,
  - prohibit oscillation (one-way stabilization logic).
- Batch selection adjustments only when overlapping replaced range.

Deliverable: no jumpy scroll behavior during catch-up.

## Phase 4 — Input/Scroll Preemption
- Add explicit scheduler states: idle, applying, preempted, draining.
- During active user interaction:
  - pause low-priority promotions,
  - allow only tiny visible-safety slices,
  - resume after quiet window.
- Ensure quit/close fast-path cancels all deferred/background work quickly.

Deliverable: typing/scrolling remains fluid under all background activity.

## Phase 5 — Full-Fidelity Completion Optimization
- Tune chunk sizing adaptively using observed frame and apply latency.
- Introduce dynamic throttling:
  - increase batch size when idle/smooth,
  - shrink immediately on jank signal.
- Optimize far-tail promotion context window reuse to reduce redundant parse work.

Deliverable: faster time-to-fully-styled without regressing interactivity.

## Phase 6 — Benchmark + Regression Gate Hardening
- Enforce official run policy for key claims.
- Add fail gates for:
  - missing full-fidelity metric,
  - scroll-jank budget breach,
  - input-latency regression.
- Run matrix:
  - Kern vs Zed (`benchmark_open_ready`) on large fixture,
  - Kern-only `wow_internal` on large + standard fixtures.

Deliverable: trustworthy, repeatable pass/fail criteria.

## 7) Test Plan

### 7.1 Unit Tests
- Scheduler priority ordering and preemption.
- Cancellation token invalidation (generation/scroll epoch mismatch).
- Anchor mapping correctness through replacement ranges.
- Batch-apply invariants (no out-of-bounds replace, monotonic promotion boundaries).

### 7.2 Integration/UI Tests
- Open large fixture, immediate scrollbar drag to deep region:
  - assert no severe jump drift,
  - assert styling converges in viewport first.
- Scroll while background catch-up active:
  - assert no spinner-risk stall events.
- Type during heavy promotion:
  - assert typing latency within threshold.

### 7.3 Benchmark Tests
- `benchmark_open_ready`: Kern vs Zed (large fixture, official run set).
- `wow_internal`: verify full metric presence and stable p50/p95.
- Observer-effect check: instrumentation on/off delta stays bounded.

## 8) Risks and Mitigations
- Risk: race conditions between worker results and current editor state.
  - Mitigation: strict tokening + main-thread validation before apply.
- Risk: more complexity in scheduler logic.
  - Mitigation: keep state machine minimal; test-first for invariants.
- Risk: TextKit apply churn still expensive even with off-main parse.
  - Mitigation: bounded micro-batches + adaptive throttling.

## 9) Rollout Strategy
1. Land behind feature flags (default on in dev builds, guarded fallback).
2. Run full test suite and benchmark matrix.
3. Enable by default once all gates pass.
4. Keep immediate rollback path (single env flag to disable async promotion engine).

## 10) Concrete Work Breakdown (Execution Order)
- [ ] P0 instrumentation spans + counters
- [ ] P1 background promotion worker + token plumbing
- [ ] P2 priority queue + viewport-first scheduling
- [ ] P3 micro-batch apply + stable anchor pinning
- [ ] P4 interaction preemption and quiet-window resume
- [ ] P5 adaptive throttle + parse context reuse
- [ ] P6 tests (unit + integration + perf)
- [ ] P6 benchmark matrix + report
- [ ] default-on + cleanup of obsolete staged-promotion paths

## 11) References (Current Code Hotspots)
- `KernApp/Sources/Editor/NativeEditorViewController.swift`
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift`
- `KernTests/NativeEditorInitialViewportTests.swift`
- `scripts/cross-editor-benchmark.sh`
- `scripts/kern-bench/Sources/KernBench/`
