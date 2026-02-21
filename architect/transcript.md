# Forging Prompts Transcript
## Project: KernTextKit
## Raw Input
User wants a dual cross-editor benchmarking strategy:

1) A "Wow" benchmark for README/social messaging.
2) A second, more realistic benchmark intended to represent real usage.

Both suites should evaluate cold/warm start, save/load latency, typing performance, RAM usage, and other high-value metrics. User prefers consistency over loaded-system realism (run in controlled/no-load conditions).

Locked editor roster requested:
- Kern
- VS Code
- Zed
- Sublime Text
- TextEdit

User confirmed Sublime is installed and wants roster + policy lock-in.

Additional concern from current implementation:
- Bench runs can appear stuck after editor opens (observed hang/wait behavior around capture/measurement stages).

---
## Questionnaire

## Questionnaire

### Category 1: Core Vision
Q: What exactly should be built?
A: Two cross-editor benchmark suites: (1) "Wow" for public-facing claims, (2) "Real-Use" for realistic, representative results.

Q: Who is this for and what problem does it solve?
A: For potential Kern users evaluating alternatives. It solves "is Kern actually fast?" while preserving methodological honesty.

Q: What does success look like?
A: Public claims come from a clearly-labeled headline suite, while realistic decisions reference a separate real-use suite with explicit disclaimer.

Q: Most important behavior?
A: Trustworthy comparisons across a fixed editor roster with consistent conditions.

### Category 2: Requirements & Constraints
Q: Which editor roster should be benchmarked?
A: Locked roster v1: Kern, VS Code, Zed, Sublime Text, TextEdit.

Q: Which metrics are mandatory in both suites?
A: Cold/warm start latency, save/load latency, typing performance, RAM usage.

Q: Any additional desired metrics?
A: Include additional high-value metrics already present or recommended (e.g., scroll smoothness where feasible).

Q: Environment constraints?
A: Run in controlled/no-load conditions for consistency (not under synthetic machine load).

Q: Policy constraints?
A: If roster is incomplete/failing, mark run as partial; do not use partial runs for README/social headline claims.

### Category 3: Prior Art & Context
Q: What existing context should be preserved?
A: Existing cross-editor toolchain in `scripts/cross-editor-benchmark.sh` and `scripts/kern-bench/` with stats/regression infrastructure.

Q: What known pain must be fixed?
A: Current run behavior can appear hung after editor opens; capture/measurement stages need fail-fast and visible progress.

Q: Preferred rollout style?
A: Single implementation prompt (not phased prompt set).

### Adaptive Category Selection (4-12)

| Category | Recommendation | Reason |
|---|---|---|
| 4. Architecture & Structure | Ask | Requires clear suite boundaries and file ownership |
| 5. Edge Cases & Error Handling | Ask | Must address hang/timeout/failure behavior |
| 6. Scale & Performance | Ask | Benchmark sample sizes, timing precision, run duration trade-offs |
| 7. Security & Privacy | Skip | Local benchmark tooling; no new auth/PII scope |
| 8. Integration & Dependencies | Ask | Integrates with existing scripts, JSON schema, regression checker |
| 9. Testing & Verification | Ask | Needs reproducibility and acceptance gates |
| 10. Deployment & Operations | Ask | Defines "official" vs "partial" publishing policy |
| 11. Trade-offs & Priorities | Ask | Must balance marketing clarity with methodological rigor |
| 12. Scope & Boundaries | Ask | Must prevent scope creep and keep implementation shippable |

User choices from this forge implicitly confirm categories 4,5,6,8,9,10,11,12 as relevant.

### Category 4: Architecture & Structure
- Keep existing benchmark stack; introduce explicit suite abstraction (wow vs real-use) with shared core measurement primitives.
- Keep roster policy and suite metadata in code + docs, not ad hoc command-line folklore.

### Category 5: Edge Cases & Error Handling
- Add per-stage fail-fast timeouts and progress logs.
- If a metric cannot be captured for a run, record null + reason; continue run classification.
- If any roster editor fails, mark run Partial.

### Category 6: Scale & Performance
- Maintain robust sample sizes for wow suite (n=30 + warmup), lighter but still meaningful for real-use due longer scenario runtime.
- Keep no-outlier-removal approach; expose tail metrics.

### Category 8: Integration & Dependencies
- Integrate with existing `kern-bench` JSON v3 + `bench-regression-check.py`.
- Keep shell script as wrapper/compatibility path.

### Category 9: Testing & Verification
- Add deterministic suite tests for config validation, roster lock enforcement, run classification, and timeout behavior.
- Validate JSON schema output and regression checker compatibility.

### Category 10: Deployment & Operations
- Publish rules: only Official runs can power README/social claims.
- Official run requires all 5 editors, controlled env checks, and complete required metrics.

### Category 11: Trade-offs & Priorities
- Priority order: trustworthiness > reproducibility > headline simplicity > implementation speed.
- Explicitly separate marketing-friendly and realism-friendly outputs to avoid mixed messaging.

### Category 12: Scope & Boundaries
In scope: dual-suite architecture, locked roster policy, metrics coverage, stability fixes, docs/publishing policy.
Out of scope: new external paid tools, multi-machine benchmark fleet, cloud telemetry ingestion.

## Prior-Art Research

### Existing Solutions (internal project prior-art)
| Solution | Path | Relevance | Quality | Notes |
|---|---|---|---|---|
| Existing benchmark architecture plan | `architect/cross-editor-benchmark-plan.md` | High | Accepted | Defines phase model + timing layers |
| Editor metrics research | `architect/research-editor-metrics.md` | High | Accepted | Confirms T1/T2/T3, warm/cold definitions, user-meaningful metrics |
| macOS benchmarking research | `architect/research-macos-benchmarking.md` | High | Accepted | Confirms thermal/power controls and memory metric caveats |
| Statistics research | `architect/research-statistics.md` | High | Accepted | Supports no outlier removal + CI + nonparametric tests |
| ScreenCapture/Electron research | `architect/research-screencapture-electron.md` | High | Accepted | Explains idle detection pitfalls and hang-like behavior |
| Existing editor benchmark landscape | `architect/research-existing-benchmarks.md` | Medium | Accepted | Provides comparative methodology context |

### Key Findings
1. Startup-only metrics are necessary but insufficient; workflow benchmarks are needed for realistic user experience evaluation.
2. Warm vs cold must be reported separately; warm often reflects day-to-day use better.
3. Screen/frame pipelines can stall for some editors; timeout/fallback behavior must be explicit to avoid hanging runs.
4. Report medians + tail percentiles and keep raw slow tails (no outlier deletion) for user-experience honesty.
5. Public benchmark claims require a strict policy gate to avoid cherry-picking and credibility loss.

### Unverified Claims
- None introduced in this forge; plan relies on repository-local prior-art and existing benchmark docs.

### Conflicts
- Marketing simplicity vs methodological realism: resolved by explicit dual-suite design and labeled outputs.

## Self-Critique Results

| # | Severity | Category | Issue | Suggested Fix | Status |
|---|---|---|---|---|---|
| 1 | High | Clarity | Metric names were listed without strict measurement semantics. | Add metric definition guardrails for cold/warm/open/save/typing/RAM. | Fixed in prompt v2 |
| 2 | High | Feasibility | Scroll smoothness requirement could be interpreted as mandatory high-fidelity capture even when unavailable. | Add preferred + fallback model with explicit labeling. | Fixed in prompt v2 |
| 3 | Medium | Completeness | Official-run policy lacked explicit preflight requirements. | Add preflight checks (thermal, fixture hash, roster completeness). | Fixed in prompt v2 |
| 4 | Medium | Consistency | Suite behavior might diverge across shell and Swift paths. | Require single source-of-truth suite config. | Fixed in prompt v2 |
| 5 | Medium | Adversarial | Implementer might classify runs official despite bad preflight state. | Add preflight pass requirement to official criteria. | Fixed in prompt v2 |

## Sub-Agent Challenge Review (Phase B)

### Findings surfaced by sub-agent
- Needed explicit mapping between missing metrics and official/partial classification.
- Memory metric priority was inverted for macOS realism (phys_footprint should be primary).
- Tail-stat reporting requirements were not explicit in prompt output contract.
- Thermal checks needed per-run handling, not start-only checks.
- Shell/entrypoint expectations needed clearer parity across both suites.
- Timeout/null handling needed explicit regression treatment to avoid hiding failures.
- Fixture/permission/process-accounting clarity needed tightening.

### Reconciliation and actions

| Issue | Action |
|---|---|
| Classification ambiguity | Added decision table requirements (`run_quality` + `run_classification` mapping). |
| Memory priority mismatch | Updated prompt to require `memory_phys_mb` as primary required metric for Official runs; RSS secondary. |
| Tail reporting gap | Added mandatory p50/p95/p99 + no outlier deletion output contract. |
| Thermal gating weakness | Added per-run thermal/power capture requirement and preflight checks. |
| Shell parity ambiguity | Updated to require both suites runnable via stable public entrypoint. |
| Timeout masking risk | Added timeout/failure-rate comparison requirement for regression checks. |
| Missing preflight concerns | Added required permission checks and explicit partial reasons. |
| Multi-process memory fairness | Added guardrail requiring child/helper process accounting. |

### Intentionally kept as-is
- Dual-suite architecture and locked roster policy remain unchanged.
- Single large implementation prompt approach preserved per user choice.

## Iteration Update: Methodology Deepening Request

User requested deeper refinement including:
- actual benchmarking methods,
- language choice for benchmark implementation,
- concrete code logic for how benchmarks will run.

Actions taken:
1. Created `architect/dual-benchmark-methodology-plan.md` with research-grounded method decisions.
2. Added explicit language/tooling decision (Swift core runner, Bash wrapper, Python regression checker).
3. Added concrete metric definitions and measurement logic for start/open/save/type/memory/find/scroll.
4. Added timeout/failure handling model and official/partial classification rules.
5. Linked implementation prompt to the new methodology plan.

## Parallel Study Fact-Check (Independent Research)

At user request, a parallel /study-style research pass was run across four independent tracks:
- Track A: core startup/open/save/typing metric validity
- Track B: realistic workflow benchmarking methods
- Track C: scroll smoothness/jank measurement on macOS
- Track D: statistical and regression-gating methodology

Synthesis output:
- `architect/research-dual-benchmark-independent-2026-02-21.md`

Net changes made after fact-check:
- strengthened save metric definitions (`ui_ack` + `durable`)
- strengthened scroll metric stack with hitch/jank fields
- strengthened official-run policy with throughout-run thermal validity
- strengthened reporting contract with failure/timeout rates
- strengthened regression requirements with effect-size reporting

