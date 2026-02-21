# Implement Dual Cross-Editor Benchmark Suites (Roster-locked, publish-safe)

You are working in the KernTextKit repo. Implement a production-ready dual benchmark system for cross-editor comparisons.

## Goal

Introduce **two explicit benchmark suites**:

1. **Wow Suite** (headline/synthetic): optimized for clear, public-facing comparison tables.
2. **Real-Use Suite** (representative): optimized for realistic user workflows and practical decision-making.

The two suites must share core measurement primitives but have distinct scenario definitions and reporting labels.

Companion methodology spec to follow during implementation:
- `architect/dual-benchmark-methodology-plan.md`

---

## Non-negotiable product requirements

### A) Locked editor roster policy (v1)
Lock the official benchmark roster to exactly:
- Kern
- VS Code
- Zed
- Sublime Text
- TextEdit

Policy behavior:
- If any roster editor is unavailable/fails, classify run as **Partial**.
- Partial runs are **not eligible** for README/social headline claims.
- No silent substitution of editors.
- Record detected editor versions in output.

### B) Required metrics in BOTH suites
Both suites must collect and report:
- Cold start latency
- Warm start latency
- Load/open latency
- Save latency
- Typing performance
- RAM usage

Additional metrics:
- Keep existing startup/render metrics where available.
- Add real-use-centric metrics in Real-Use suite (below).

Metric definition guardrails (avoid ambiguity):
- `cold_start_latency_ms`: launch-to-usable metric under cold mode
- `warm_start_latency_ms`: launch-to-usable metric under warm mode
- `open_latency_ms`: command to open file -> first usable content state
- `save_ui_ack_latency_ms`: save command issued -> UI/save-complete confirmation
- `save_durable_latency_ms`: save command issued -> durable file commit probe completion
- `typing_latency_ms`: deterministic typing burst completion latency (fixed payload + fixed insertion pattern)
- RAM usage: `memory_phys_mb` (primary required metric for Official runs), `memory_rss_mb` (secondary compatibility metric)

### C) Real-Use minimum workflow
The Real-Use suite must include at least:
- Open document
- Scroll activity
- Typing/edit activity
- Find action(s)
- Save

For scroll, require one deterministic metric family:
- preferred: frame-time/jank metrics where capture is available
- fallback: scripted scroll-to-settle latency proxy (explicitly labeled as fallback)
- preferred metrics must include: effective FPS, p95 frame time, p99 frame time, and hitch/jank indicators

### D) Environment consistency
Design for controlled runs (not under synthetic stress/load):
- AC/Battery + thermal state must be recorded
- thermal throttle warnings remain mandatory
- output must explicitly state environment and run classification

Preflight checks for Official eligibility:
- no thermal throttle at start (`CPU_Speed_Limit == 100`)
- suite and fixture hash recorded
- roster completeness check passes
- required OS permissions available (e.g., Screen Recording / Accessibility where needed)
- thermal throttle remains acceptable across measured runs (else force Partial)

### E) Hang prevention / fail-fast behavior
Current suite can appear stuck after editor opens. Fix this:
- Add per-stage timeout + fallback behavior
- Emit progress logs for each stage
- Record missing metric as null + reason (instead of hanging indefinitely)

---

## Implementation scope and structure

Use existing benchmark code as base:
- `scripts/cross-editor-benchmark.sh`
- `scripts/kern-bench/Sources/KernBench/*`
- `scripts/bench-regression-check.py`

### 1) Add first-class suite model in `kern-bench`
Add suite abstraction (e.g., `wow`, `real_use`) with:
- scenario definitions
- required metrics set
- run counts / warmups defaults
- output disclaimers/labels

Recommended defaults:
- Wow: 30 measured runs, 3 warmup
- Real-Use: 20 measured runs, 2 warmup (longer scenario)

Add a single source-of-truth suite config structure (not duplicated across shell + Swift paths).

### 2) Implement standardized operation timers
Add/extend measurement primitives to capture these ops consistently:
- `open_latency_ms`
- `save_latency_ms`
- `typing_latency_ms` (defined as deterministic typed burst latency)
- existing startup metrics (`window_visible_ms`, and paint/stable when available)
- memory snapshots (`memory_rss_mb`, `memory_phys_mb` when available)

For Real-Use, add:
- `find_latency_ms`
- `scroll_*` metrics (at minimum a deterministic smoothness proxy; ideally frame/jank stats where available)

Operational probes must be explicit and deterministic:
- define what constitutes “open done,” “save done,” and “typing done”
- keep editor action adapters explicit (no implicit assumptions per editor)

### 3) Define robust fallback behavior
For each measurement stage:
- if stage timeout is exceeded, continue run
- store metric null + `failure_reason` entry
- classify run quality (`complete` / `degraded`)

Never block indefinitely waiting for frame idle/paint signals.

### 4) Enforce roster lock + run classification
Implement explicit run classification fields:
- `run_classification`: `official` or `partial`
- `partial_reasons`: array of machine-readable reasons

`official` requires:
- all 5 roster editors measured
- all required metrics present for each suite’s required set
- no fatal measurement stage failures
- preflight eligibility checks pass

Add explicit decision table in code/docs:
- Required metric missing/null -> `run_quality=degraded`, `run_classification=partial`
- Optional metric missing/null -> `run_quality=degraded`, classification unchanged unless policy says otherwise
- Timeout/failure counts above threshold -> forced `partial`

### 5) Keep shell path aligned
Update `scripts/cross-editor-benchmark.sh` to support suite selection or clearly delegate to `kern-bench` while preserving compatibility.

Minimum:
- support running both Wow and Real-Use suites from a stable public entrypoint
- include suite label + classification in output

### 6) Regression tool compatibility
Update `scripts/bench-regression-check.py` to:
- understand new metric keys
- ignore null metrics safely
- continue nonparametric comparisons for supported metrics
- preserve current statistical methodology
- explicitly include timeout/failure-rate comparisons so missing metrics cannot silently hide regressions
- include effect-size reporting in output and gate decisions

---

## Output/reporting requirements

### JSON
Extend schema (version bump if needed) with:
- `suite`: `wow` or `real_use`
- `run_classification`
- `partial_reasons`
- new operation metrics
- per-metric failure reason when missing
- `run_quality` and timeout/failure counters

### Human-readable output
Every report must clearly label:
- suite name
- intended usage
  - Wow: “headline/synthetic comparison”
  - Real-Use: “representative practical comparison”
- classification (Official/Partial)

Statistical output contract (both suites):
- median (p50) + p95 + p99 for timing metrics
- no outlier deletion
- sample counts per metric
- include failure/timeout rate per metric and per editor

### Policy text for docs
Add explicit policy sections:
- roster lock policy
- Official vs Partial criteria
- README/social claim rule (Official only)

---

## Testing and verification

Add automated checks for:
1. suite selection/config parsing
2. roster lock enforcement
3. classification logic (official vs partial)
4. timeout/fallback behavior (no indefinite hangs)
5. JSON schema integrity for new fields
6. regression checker handling of new/null metrics
7. timeout/failure-rate treatment in regression comparisons
8. permission/preflight failure classification

Run and report:
- build success
- unit tests for affected modules/scripts
- one sample Wow run and one sample Real-Use run (single-run smoke mode acceptable for dev verification)

---

## Deliverables checklist

- [ ] Dual suites implemented in code (`wow`, `real_use`)
- [ ] Locked roster v1 enforced
- [ ] Required metrics in both suites implemented
- [ ] Real-Use workflow includes open/scroll/type/find/save
- [ ] Hang prevention + fail-fast stage timeouts implemented
- [ ] Official vs Partial classification implemented
- [ ] shell entrypoint updated and aligned
- [ ] regression checker updated for new metrics/nulls
- [ ] docs updated with policy + disclaimers
- [ ] tests added/updated
- [ ] rebuild app and include verification output summary

---

## Constraints and guardrails

- Do not silently remove existing useful metrics.
- Do not hardcode claims in docs; claims should derive from official run outputs.
- Keep behavior deterministic where practical (fixed action counts, deterministic typing payloads).
- Prefer extending existing architecture over one-off scripts.
- For multi-process editors, memory measurement must account for child/helper processes consistently.
