# Research + Master Plan (Mode 2 Refined): Kern 500ms Open-Ready & Beat-Zed Program
Date: 2026-02-22
Mode: forging-plans / Mode 2 (finalized)
Owner: kern-editor


## Execution Checklist
- [x] Phase 0 — Baseline lock + statistical protocol
- [x] Phase 1 — Zed fork + bench hook integration
- [x] Phase 2 — Benchmark hardening + methodology finalization
- [x] Phase 3 — Kern vs Zed benchmark matrix
- [x] Phase 4 — Kern 500ms optimization track
- [x] Phase 5 — Optimization backlog formalization
- [x] Phase 6 — Regression-safe implementation loop
- [x] Phase 7 — Bug/regression + new-gap discovery loop
- [x] Phase 8 — Final master run + sign-off

## Executive Summary
This is a two-track program:
- **Track A (methodology credibility):** apples-to-apples Kern vs Zed via a deterministic Zed bench hook + hardened benchmark harness.
- **Track B (product performance):** drive Kern `benchmark_open_ready` to **~500ms p50** on the target fixture regardless of Zed’s result.

The critical insight is sequencing: benchmark correctness and anti-gaming guardrails must land before optimization claims. Then open-path optimization proceeds with instrumentation-first, viewport-first, and regression-safe rollout.

Confidence:
- **High**: harness hardening path and near-term Kern wins.
- **Medium**: deeper architectural work (piece-table/rope/TextKit2-first spike).

---

## Sub-Questions Investigated
1. Can Zed be made apples-to-apples measurable? → **Yes**, via fork hook emitting deterministic bench-ready events.
2. What invalidates current comparisons? → Hidden readiness caps, helper-window bias, asymmetric launch hygiene, deadline-coupled timeout artifacts.
3. Kern’s biggest open-path costs? → Full-document parse/import + early layout pressure + frequent export/chrome/layout work.
4. Most applicable optimization patterns? → Viewport-first + deferred non-visible work + incremental parsing/export + main-thread budget discipline.
5. How to avoid regression during aggressive optimization? → Phase-level attribution, strict statistical gates, and per-batch tests.

---

## Final Methodology Contract (locked)

## Primary KPI
- `benchmark_open_ready` for Kern on target fixture.

## Anti-gaming guardrails (required)
- `time_to_stable_layout_ms` (ready -> visually/layout stable for target document)
- `post_ready_export_quiescence_ms` (ready -> export/serialize quiet)

A run cannot be called successful if open-ready improves while guardrails regress materially.

## Statistical claim policy
For any “target achieved” claim:
- **Warmup:** fixed warmup count (documented per suite)
- **Sample size:** >=30 official measured runs per condition (minimum)
- **Report:** p50, p95, and 95% CI
- **Comparison test:** Mann-Whitney + bootstrap CI vs frozen baseline
- **Noise control:** baseline and candidate must be run in alternating A/B blocks within the same session

## Official vs Partial (non-negotiable)
- Official requires: fixture hash match, required metrics present, roster/mode policy pass, no fatal stage failures.
- Partial must carry machine-readable reasons and is non-claimable.

---

## Execution Dependencies & Gates (new)
1. **Gate G1:** Phase 2 (harness hardening) complete before Phase 3 matrix.
2. **Gate G2:** Phase 4A instrumentation complete before optimization batches are judged.
3. **Gate G3:** Phase 4C pipeline redesign uses sub-steps; each sub-step must pass tests before next sub-step.
4. **Gate G4:** Phase 8 final run only after all prior gates are green.

---

## Detailed Findings

### 1) Zed fork + hook feasibility
Current Zed CLI `--wait` behavior is close/exit-oriented, not explicit open-ready. Fork hook is the most reliable parity path.

**Hook contract:**
- `--bench-target-file <abs-path>`
- `--bench-ready-signal <json-path|fd|unix-socket>`
- `--bench-ready-mode <first_editable|first_content|styled_stable>`

Event example:
```json
{
  "event": "bench_ready",
  "target": "/abs/path/file.md",
  "mode": "first_editable",
  "timestamp_monotonic_ns": 123,
  "pid": 999,
  "window_id": 12345
}
```

### 2) Benchmark harness/code gaps to close first
1. `documentLoadBudgetNs = min(timeout, 2.5s)` can force false `document_not_loaded` failures.
2. Window-visible currently risks helper-window false-fast values.
3. Launch cleanliness is asymmetric (VS Code has clean profile; Zed does not).
4. Stage timeout shrinking from run/suite budget can create downstream false degradations.

### 3) Kern rendering pipeline gaps
Open path still does broad parse/layout work before first-editable. Major opportunities are in splitting critical-path vs deferred work and reducing full-document churn in early render and post-edit loops.

### 4) Optimization venue tiers
- **Tier 1:** harness correctness + layout/chrome/export coalescing + launch/profile symmetry.
- **Tier 2:** viewport-first open + deferred formatting + dirty-range parse/export.
- **Tier 3:** deeper text storage and TextKit strategy experiments under flags.

---

## Hypothesis Assessment

| Hypothesis | Confidence | Support | Contradiction |
|---|---|---|---|
| H1: Harness artifacts still distort Kern-vs-Zed comparisons | High | Known cap/bias/asymmetry in current code paths | Existing classification protections reduce but do not remove distortion |
| H2: Kern can reach ~500ms without deep architecture rewrite | Medium-High | Existing path already has thresholding + instrumentation hooks | Large markdown feature surface may still require deeper incremental model |
| H3: Zed fork hook is required for strong parity | High | `--wait` semantics are not open-ready semantics | External probing can approximate but lower confidence |
| H4: Piece-table/rope is near-term mandatory | Medium-Low | Long-term scalability benefit | Near-term wins likely from pipeline/harness fixes first |

---

## Refined Execution Plan (maps to requested 1–9)

## Phase 0 — Baseline lock + statistical protocol (Day 0-1)
- Freeze fixture hashes + command templates + environment capture.
- Record baseline manifests and run metadata.
- Define claim thresholds:
  - Primary: Kern `benchmark_open_ready` p50 <= 500ms.
  - Secondary: p95 guardrail and no quality downgrade.
- Lock statistical protocol:
  - >=30 official runs/condition,
  - 95% CI,
  - Mann-Whitney + bootstrap CI vs baseline,
  - A/B alternating blocks to limit drift.

## Phase 1 — Zed fork + bench hook (Requested #1)
1. Fork Zed and add bench-ready interface.
2. Emit deterministic event for target file/mode.
3. Add fork tests:
   - exact-once semantics,
   - target-file correctness,
   - mode correctness.
4. Integrate `kern-bench` consumer path with fallback to external probe.

## Phase 2 — Benchmark hardening + methodology finalization (Requested #2)
1. Remove hard 2.5s document-load cap.
2. Replace first-window heuristic with target-document-aware readiness filter.
3. Add Zed clean-launch profile/isolation.
4. Separate `run_budget_exhausted` vs stage-timeout reasons.
5. Add `automation_overhead_ms` + unattributed budget reporting.
6. Add anti-gaming guardrails (`time_to_stable_layout_ms`, `post_ready_export_quiescence_ms`).
7. Finalize official/partial policy in docs + checker.

### Phase 2 Tests (required)
- Unit: delayed document load succeeds within stage timeout (no premature `document_not_loaded`).
- Unit: helper windows are rejected.
- Integration: induced slow-open and failure scenarios produce correct reasons.
- Regression-checker: quality downgrade, failure-rate deltas, guardrail regression alerts.

## Phase 3 — Kern vs Zed benchmark matrix (Requested #3)
Execute matrix only after Gate G1:
- cold + warm,
- small + target + huge fixtures,
- 1-run smoke, 10-run stability, 50-run official.

Add mandatory rows:
- alternating A/B baseline-vs-candidate blocks,
- warmup-sensitivity row (early vs late run drift),
- deferred-work watchdog row,
- post-ready completion row,
- controlled background-load stress row (documentation-only, not claim lane).

## Phase 4 — Kern 500ms performance track (Requested #4, primary)

### 4A. Instrumentation-first (Gate G2)
- Expand internal spans for decode/parse/apply/layout/first-editable.
- Require >=95% attribution for open path.
- Define per-phase budgets from baseline traces.

### 4B. Quick wins
- Reduce unnecessary full layout on first open for large docs.
- Coalesce repetitive post-edit UI work (height/chrome/export triggers).
- Cache hot option/style lookups.

### 4C. Pipeline redesign (gated sub-steps)
- 4C.1 viewport-first rendering stub behind flag.
- 4C.2 deferred non-visible formatting.
- 4C.3 dirty-range parse/export where safe.
- 4C.4 guardrail validation (stable-layout + export-quiescence).

Each sub-step requires tests + benchmark check before advancing.

### 4D. Deep candidates (flagged)
- piece-table/rope prototype,
- TextKit2-first spike with rollback switch.

## Phase 5 — Full optimization venue backlog (Requested #5, #6)
- Convert all venues into tracked tickets (L1/L2/L3).
- Every ticket must include:
  - expected KPI impact,
  - regression risk,
  - required test gate,
  - rollback condition.

## Phase 6 — Regression-safe implementation loop (Requested #7)
For each batch:
1. Add/update targeted tests first.
2. Implement smallest viable change.
3. Rebuild/reinstall app.
4. Run standard validation:
   - native editor tests,
   - `kern-bench` tests,
   - smoke benchmark.
5. Archive artifacts and compare statistically to baseline.

Required new tests:
- per-stage timeout fault injection,
- observer-effect overhead benchmark,
- open-ready correctness with delayed formatting,
- save/quit stress while deferred tasks active,
- phase-budget compliance checks.

## Phase 7 — Bug/regression + new-gap discovery loop (Requested #8)
Per regression event:
- classify: measurement vs product vs infra,
- isolate first bad batch (bisect workflow),
- patch + targeted test,
- reduced matrix rerun,
- rejoin full run only when green.

Weekly venue discovery from traces:
- unattributed residuals,
- phase budget drift,
- guardrail regressions,
- failure-rate anomalies.

## Phase 8 — Final master run and sign-off (Requested #9)
### Exit Criteria (Go/No-Go)
- Kern p50 <= 500ms on target fixture.
- p95 and guardrail metrics within agreed bounds.
- Statistical significance vs baseline shown.
- No increase in partial/failure rates.
- All gating tests pass.

### Deliverable Checklist (required)
- finalized methodology doc,
- Zed fork hook patchset,
- Kern optimization PR stack with per-batch evidence,
- final comparison report with raw artifacts,
- reproducibility manifest (commands, environment, fixture hashes, versions).

---

## Risk Register (expanded)
1. **Hook drift risk (Zed upstream changes)**  
   Mitigation: isolate hook, version guard, fallback probe mode.
2. **False-fast helper-window measurement**  
   Mitigation: target-document readiness checks before window-visible acceptance.
3. **Deferred-work metric gaming risk**  
   Mitigation: enforce stable-layout/export-quiescence guardrails.
4. **Incremental parse/export correctness drift**  
   Mitigation: dirty-range correctness tests + full-fallback path.
5. **Accessibility/UX regressions from viewport-first**  
   Mitigation: snapshot + interaction regression suite on representative fixtures.
6. **Overfitting to single fixture/machine**  
   Mitigation: secondary fixtures and multi-machine validation for sign-off.

---

## Source Index

### External research sources
1. Zed CLI docs (`--wait` semantics): https://zed.dev/docs/cli
2. Zed source (`open_listener.rs` wait behavior): https://raw.githubusercontent.com/zed-industries/zed/main/crates/zed/src/zed/open_listener.rs
3. Apple WWDC19 Optimizing App Launch: https://developer.apple.com/videos/play/wwdc2019/423/
4. Apple WWDC21 Meet TextKit 2: https://developer.apple.com/videos/play/wwdc2021/10061/
5. Tree-sitter Basic Parsing: https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html
6. VS Code v1.21 update: https://code.visualstudio.com/updates/v1_21
7. VS Code text buffer reimplementation: https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation
8. Google Benchmark user guide: https://raw.githubusercontent.com/google/benchmark/main/docs/user_guide.md
9. Criterion docs: https://docs.rs/criterion/latest/criterion/struct.Criterion.html
10. BenchmarkDotNet jobs docs: https://benchmarkdotnet.org/articles/configs/jobs.html
11. SciPy bootstrap docs: https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.bootstrap.html
12. SciPy Mann-Whitney docs: https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.mannwhitneyu.html

### Internal anchors
- Kern editor path: `KernApp/Sources/Editor/EditorDocument.swift`, `NativeEditorViewController.swift`, `NativeMarkdownCodec.swift`, `WowInternalMetricsRecorder.swift`
- Harness path: `scripts/kern-bench/Sources/KernBench/{SuiteDefinition.swift,ActionRunner.swift,KernBenchMain.swift,EditorRegistry.swift,WindowDetector.swift}`
- Regression checker: `scripts/bench-regression-check.py`

---

## Limitations & Remaining Unknowns
- Final Zed tap-point for “first editable” must be validated in fork implementation.
- 500ms on one machine/fixture is not sufficient for broad product claim; cross-device verification remains required.
- Piece-table/TextKit2 decisions require spike evidence before commitment.
