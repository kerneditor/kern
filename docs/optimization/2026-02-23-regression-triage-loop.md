# Regression triage loop artifact (2026-02-23)

## Observed regressions/events

1. `benchmark` suite open stage frequently timed out under AX probe path.
2. Zed launch/open remained partial without forked bench hook emission.
3. Observer-effect disabled path produced degraded open-only runs.

## Classification

- #1: **measurement path regression** (probe method brittle), not product parse/layout latency.
- #2: **external dependency gap** (no fork hook signal from upstream Zed build).
- #3: **measurement/instrumentation coupling** (open-only lane relies on reliable ready signal path).

## Patches applied

- Added Kern open-latency computation from WOW metrics for `benchmark` and `benchmark_open_ready` suites.
- Added Zed hook consumer path with compatibility fallback and strict payload validation.
- Added timeout normalization helper + tests.
- Added helper-window filter/select tests and expanded regression checker tests.

## Rejoin gate outcome

- `scripts/kern-bench`: green.
- `scripts/tests/test_bench_regression_check.py`: green.
- `./scripts/test-native-editor.sh`: green.
- Target KPI lane (`benchmark_open_ready` + cross-editor fixture + Kern): official p50 < 500ms.
