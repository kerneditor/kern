---
status: complete
priority: p1
issue_id: "901"
tags: [benchmark, performance, zed, open-ready, regression]
dependencies: []
---

# 901 — Kern 500ms master execution run

## Problem Statement
Execute all phases in architect/plan.md + docs/plans/2026-02-22-feat-kern-500ms-master-optimization-plan.md, including benchmark hardening, Zed parity hook integration path, Kern optimization, full tests, and benchmark validation.

## Recommended Action
Implement in gated sequence with continuous test/benchmark validation and self-repair loop until all phase gates pass.

## Acceptance Criteria
- [x] Phase 1 completed: Zed hook integration path in harness + tests
- [x] Phase 2 completed: harness hardening fixes + tests
- [x] Phase 3 completed: benchmark matrix runs captured
- [x] Phase 4 completed: Kern optimization changes + tests
- [x] Phase 5 completed: optimization venue backlog documented
- [x] Phase 6 completed: regression test suite green
- [x] Phase 7 completed: triage loop artifacts documented
- [x] Phase 8 completed: final benchmark report with 500ms target status
- [x] `./scripts/test-native-editor.sh` passes
- [x] `swift test` in `scripts/kern-bench` passes
- [x] `python3 -m pytest scripts/tests/test_bench_regression_check.py` passes

## Work Log
### 2026-02-22 - kickoff
**By:** Codex

**Actions:**
- Created master execution todo from user-approved workflows-work run.
- Bound execution to `architect/plan.md` and refined master plan doc.

**Learnings:**
- Existing branch already contains large benchmark refactor baseline, so work can proceed in-place with incremental repair.

### 2026-02-23 - execution complete
**By:** Codex

**Actions:**
- Added Zed bench-hook consumer path (`auto|off|required`) with compatibility fallback and validation tests.
- Added timeout fault-injection/unit tests (stage timeout normalization + timeout helper + window candidate filtering tests).
- Added observer-effect benchmarking script and documentation.
- Expanded regression-checker tests to cover all WOW stage metrics and report-only mode.
- Captured benchmark matrix artifacts (small/target/huge, warm/cold smoke, 10-run stability, 30-run official, 50-run extended).
- Added optimization venue backlog docs and critical benchmark-integrity pattern docs.
- Re-ran native editor tests, kern-bench tests, and regression-check tests to green.

**Learnings:**
- Kern meets the open-ready KPI lane on the target cross-editor fixture (`benchmark_open_ready` p50 ~195ms in 30/50-run official runs).
- Current local Zed build still times out under external probe path; harness now supports fork hook signaling, but upstream fork hook implementation is still required for true apples-to-apples official parity.
- Disabling WOW instrumentation currently degrades open-ready reliability in this harness path; observer-effect artifacts are retained with this caveat for follow-up.

### 2026-02-23 - continuation
**By:** Codex

**Actions:**
- Added additional non-AX CGWindow title fallback in open-readiness document-match checks.
- Ran targeted Zed diagnostics (`auto` and `required` hook modes) and archived proof artifacts.
- Re-validated kern-bench test suite after fallback patch.

**Learnings:**
- Local Zed still does not expose usable readiness via external probe path.
- `--zed-bench-hook required` fails at launch on current Zed binary, confirming fork hook support is required to complete parity.

### 2026-02-23 - continuation 2
**By:** Codex

**Actions:**
- Added `--kern-open-metric-source auto|wow|probe` to keep observer experiments apples-to-apples on measurement path.
- Updated wrapper + docs + observer script to use probe source for enabled/disabled comparison symmetry.
- Re-ran observer-effect benchmark (10-run each variant) and copied summary into master-run artifact directory.

**Learnings:**
- Observer-effect run no longer degrades to `n/a` in disabled mode; both sides are official and comparable.
- Measured delta is noisy and currently favors instrumentation-enabled runs, so this is a trend metric, not a one-shot claim metric.

### 2026-02-23 - continuation 3
**By:** Codex

**Actions:**
- Added a concrete Zed fork implementation checklist doc for bench-ready hook patchset execution.

**Learnings:**
- Harness side is feature-complete for consuming hook events; remaining parity blocker is upstream/fork implementation in Zed itself.

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as completed: acceptance checklist is fully done.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
