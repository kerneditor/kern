# Kern optimization venue backlog (L1/L2/L3)

## L1 — immediate

| ID | Venue | Expected KPI impact | Risk | Required test gate | Rollback condition |
| --- | --- | --- | --- | --- | --- |
| L1-01 | Open-path option/style cache reuse | -20 to -60ms p50 open_ready | Low | native editor tests + benchmark_open_ready smoke | Any markdown styling mismatch |
| L1-02 | Coalesce post-open layout/chrome updates | -15 to -45ms p50 open_ready | Low-Med | layout snapshot + open-only guardrails | `time_to_stable_layout_ms` regression >10% |
| L1-03 | Reduce redundant export triggers | -10 to -40ms automation overhead | Med | save/quit tests + guardrail checks | save/export correctness regression |

## L2 — medium complexity

| ID | Venue | Expected KPI impact | Risk | Required test gate | Rollback condition |
| --- | --- | --- | --- | --- | --- |
| L2-01 | Viewport-first open rendering | -100 to -300ms p50 on large fixture | Med-High | exhaustive visual snapshots + open-ready correctness tests | visual correctness or accessibility regressions |
| L2-02 | Deferred non-visible formatting queue | -80 to -220ms p50 open_ready | Med-High | deferred-work watchdog + stable-layout guardrail | `time_to_stable_layout_ms` tail blow-up |
| L2-03 | Dirty-range parse/export in edit loop | typing/save latency reduction and less churn | High | markdown round-trip + targeted edit invariants | data-loss or export mismatch risk |

## L3 — exploratory/deep

| ID | Venue | Expected KPI impact | Risk | Required test gate | Rollback condition |
| --- | --- | --- | --- | --- | --- |
| L3-01 | Piece-table / rope storage prototype | major large-doc scalability gain | High | full spec conformance + stress benchmarks | memory/correctness regressions |
| L3-02 | TextKit2-first open-path spike | lower open/layout latency on large docs | High | side-by-side snapshot + behavior parity suite | unsupported behavior or rendering regressions |
| L3-03 | Background parse worker with cancellation | tail-latency and responsiveness gains | High | thread-safety + save/quit stress tests | races/deadlocks/crashes |
