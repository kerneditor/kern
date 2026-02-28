---
title: "feat: Beat Zed open latency with viewport-first pipeline"
type: feat
date: 2026-02-22
status: forged-mode-2
owner: kern-editor
mode: forging-plans-2
---

# feat: Beat Zed open latency with viewport-first pipeline

## Overview
Ship a reproducible, benchmark-valid performance program that makes Kern faster than Zed on the agreed open workflow metric(s), without gaming methodology or sacrificing correctness.

This plan is the Mode 2 refinement of the original draft and incorporates:
- prior local methodology (`architect/dual-benchmark-methodology-plan.md`)
- benchmark policy/constraints from `architect/prompt.md`
- external best-practice and official docs research (TextKit 2, signposts, incremental parsing, viewport-first rendering)

## Objective and explicit targets

### Primary objective
On the agreed huge markdown fixture, Kern must beat Zed on:
- `open_ready_ms` (p50 by default target margin: >= 100ms faster)
- `open_ready_ms` (p95 faster, not just median)

### Secondary objectives
- Reduce Kern `window_visible_ms`
- Reduce Kern `first_editable_ms`
- Keep `full_format_complete_ms` bounded and non-blocking
- Preserve markdown correctness and save/export reliability

### Hard constraints
- No benchmark-only hacks.
- No comparing against non-document screens (e.g., welcome pages).
- Same fixture, same run protocol, same environment metadata for every editor.

## Research-backed conclusions (2026-02-22)
1. **Viewport-first and deferred work are mandatory** for fast perceived open on large docs.
2. **Incremental parsing/reparse is the scalable path**; eager full-doc transformation dominates cost.
3. **TextKit 2 can regress if TextKit 1 compatibility APIs are used in the open path**; open-path API hygiene matters.
4. **Benchmark credibility depends on phase-level attribution and failure-aware reporting**, not one opaque number.

## Scope

### In scope
- Kern open-path performance architecture and instrumentation.
- Benchmark harness updates needed to remove measurement pollution.
- Cross-editor protocol hardening required for fair comparisons.

### Out of scope
- New product features unrelated to open/save responsiveness.
- Broad refactors outside perf-critical code paths.

## Measurement contract (source of truth)

All latency metrics must be wall-clock monotonic (`ContinuousClock`) and emitted per run.

### Required split metrics
- `window_visible_ms`: launch dispatch -> first editor window visible
- `open_ready_ms`: file-open dispatch -> target document loaded and ready
- `first_editable_ms`: file-open dispatch -> deterministic edit probe succeeds
- `type_apply_ms` (optional for analysis, not headline): keyburst dispatch -> expected buffer delta
- `save_ui_ack_ms`: save dispatch -> UI ack/operation completion signal
- `save_durable_ms`: save dispatch -> durable file write probe complete
- `full_format_complete_ms`: open dispatch -> background formatting completion

### Measurement pollution controls
- Always report separate `automation_overhead_ms`.
- Report `unattributed_ms = total_cycle_ms - sum(known_phases)`; require <=5% for official claims.
- No fixed sleeps in critical path; replace with event/predicate waits plus strict timeout.

### Valid sample rules
A sample is invalid (excluded from official aggregates) if any occurs:
- wrong surface (welcome/start page instead of fixture file)
- open action timeout
- edit probe timeout
- fixture hash mismatch
- preflight failure (permissions/thermal/roster)

Invalid samples must still be archived with explicit reason.

## Benchmark protocol hardening (cross-editor)

### Fixture guarantees
- Fixture files are immutable/frozen by hash.
- Every editor opens the same absolute file path.
- Post-open verification confirms visible content fingerprint and document title/path.

### Cold/warm protocol
- Cold: terminate editor, clear app state as allowed, wait settle window, run open.
- Warm: editor previously launched in session; run open after fixed warmup count.
- Report cold and warm separately; no mixed aggregates.

### Editor lifecycle rules
- One run = launch/open/ready-probe/edit/save/quit/cleanup.
- No accumulating windows between runs.
- Force process cleanup with bounded retries.

### Timeout model
Per-stage timeout with fail-fast continuation:
- timeout => metric `null` + `failure_reason`
- run continues where safe
- classification downgraded (`degraded`/`partial`)

## Kern performance program

## WS1 — Observability first (must complete before optimization)

### Tasks
1. Add signposts/spans around open pipeline phases:
   - launch
   - file read/decode
   - block parse
   - inline parse
   - attributed transform
   - text storage assign
   - initial layout
   - first paint
   - first editable probe
2. Emit per-phase JSON + summarized markdown report.
3. Add frame-budget counters for main-thread blocks (>16ms, >50ms, >100ms).

### Acceptance
- >=95% of `open_ready_ms` attributed to named phases.
- Reproducible traces for baseline and each major change batch.

---

## WS2 — Open pipeline redesign (viewport-first)

### Phase A (critical path)
- Open plain text rapidly.
- Apply minimal styling needed for immediate usability.
- Declare ready as soon as deterministic edit probe succeeds.

### Phase B (near-term deferred)
- Format/render current viewport first.
- Prioritize visible blocks and immediate surroundings.

### Phase C (background)
- Full-document enhancement and heavy passes.
- Interruptible and cancellable on user edits.

### Acceptance
- `open_ready_ms` no longer blocked by full-doc formatting completion.

---

## WS3 — Throughput optimization in parser/transform path

### Tasks
1. Replace eager full-materialization loops where possible with streaming iteration.
2. Reduce attributed-string churn:
   - batch edits
   - reduce per-line object creation
   - cache/reuse style instances
3. Gate expensive syntax work to viewport-first policy.
4. Add internal microbenchmarks:
   - markdown import MB/s
   - attributed transform ms/MB
   - layout ms/MB

### Acceptance
- Parse/transform combined p50 on huge fixture improves >=40% from baseline.

---

## WS4 — TextKit strategy decision gate

### Decision options
1. Optimize current stack only.
2. Migrate open path to TextKit 2-first architecture.

### Required evaluation
- Audit open path for TextKit 1 compatibility API usage.
- Build experimental branch for TextKit 2-first open path.
- Compare latency, correctness, and complexity risk.

### Acceptance
- ADR captured with evidence, chosen direction, rollback plan.

---

## WS5 — Save/quit responsiveness hardening

### Tasks
- Keep explicit save in critical flow, but move heavy post-save work off critical path.
- Ensure deterministic quit completion and process cleanup.
- Add per-stage quit/save failure reasons in benchmark outputs.

### Acceptance
- No hanging runs due to save/quit lifecycle bugs.

---

## WS6 — Harness runtime optimization

### Tasks
- Remove repeated click spam and fixed sleep polling.
- Use predicate/event-based waits with short polling intervals.
- Minimize pre/post delays while preserving determinism.
- Parallelize non-interfering archive/report tasks after runs.

### Acceptance
- Single-run smoke completes near true editor/runtime cost, not script waiting overhead.

## Statistical and reporting policy

### Aggregation
- Report p50/p95/p99 + n for each metric.
- Keep failure/timeout rates visible per editor.
- No outlier deletion for official reporting.

### Claim policy
Kern “wins” only when all hold:
1. official run classification
2. roster complete
3. fixture verification passes
4. Kern faster than Zed by agreed threshold on primary metric
5. p95 non-regression and correctness gates green

## Execution checklist (ordered)

### Phase 0 — Baseline lock
- [x] Confirm editor roster and fixture set.
- [x] Freeze fixture hashes and archive baseline manifest.
- [x] Run 1-run + 10-run baseline with full phase attribution.

### Phase 1 — Instrumentation
- [x] Implement WS1 signposts and JSON phase export.
- [x] Add unattributed-time guardrail and invalid-sample reasons.
- [x] Validate traces and attribution coverage.

### Phase 2 — Harness integrity
- [x] Replace sleep-heavy automation with event-driven waits.
- [x] Add strict open-surface verification (must be target markdown file).
- [x] Enforce lifecycle cleanup (no leaked windows/processes).

### Phase 3 — Kern latency optimization
- [ ] Implement viewport-first open path (WS2).
- [ ] Implement parser/transform throughput pass (WS3).
- [x] Run microbench + macrobench after each batch.

### Phase 4 — Decision gate
- [ ] Run TextKit strategy comparison (WS4).
- [ ] Publish ADR and choose path.

### Phase 5 — Full validation
- [ ] 50-run official comparison (Kern vs Zed at minimum; full roster for public claim).
- [x] Validate correctness suites and save/export behavior.
- [x] Archive artifacts + publish report.

## Artifact and reproducibility requirements
For each benchmark batch archive:
- commit SHA
- fixture manifest (path + sha256)
- editor versions
- machine/OS metadata
- thermal/power state
- raw per-run JSON
- aggregate summary markdown
- traces/signpost exports

## Risks and mitigations
1. **Progressive rendering correctness drift**
   - Mitigation: snapshot + conformance checks before/after optimization.
2. **Main-thread starvation from background passes**
   - Mitigation: strict priority scheduler + cancellation.
3. **Benchmark overfitting to one fixture**
   - Mitigation: include small/medium/huge validation set, keep huge as headline target.
4. **False fast results from invalid samples**
   - Mitigation: hard invalidation rules + explicit exclusions.

## Acceptance criteria
- At least one actionable improvement landed in each area:
  - reproducibility
  - statistical validity
  - adversarial robustness
- Kern beats Zed on agreed `open_ready_ms` metric under official run policy.
- Report includes full artifact bundle and rerun instructions.

## Execution handoff prompt (for workflows-work)
Use this plan as the only execution authority.

Required execution behavior:
1. Implement in small batches with benchmark re-check after each batch.
2. After each code change, rebuild and reinstall Kern before reporting status.
3. Keep fixture files frozen; never mutate benchmark fixtures in-place.
4. Preserve split metrics and classification policy; do not collapse into one opaque number.
5. If a run appears stalled, fail-fast via timeout and continue with explicit failure reason.
6. Keep `architect/` files as reference context only; do not treat old drafts as superseding this plan.

Verification commands (minimum):
- `./scripts/test-native-editor.sh`
- `./scripts/kern-bench/.build/release/kern-bench --suite wow --runs 1`
- `./scripts/kern-bench/.build/release/kern-bench --suite wow --runs 10`
- `./scripts/bench-regression-check.py --help`
