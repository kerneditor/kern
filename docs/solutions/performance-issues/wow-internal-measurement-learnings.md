# WOW internal measurement learnings (2026-02-23)

## What we locked

- Internal microbenchmarks (`suite_kind=internal_microbenchmark`) are strictly non-claim metrics.
- Cross-editor claims only accept `suite_kind=cross_editor` and official classification.
- Open-only guardrails now include:
  - `time_to_stable_layout_ms`
  - `post_ready_export_quiescence_ms`

## Failure semantics

- Stage timeout classification now preserves deadline ownership:
  - `run_timeout`
  - `suite_timeout`
  - stage-local timeout reason (when deadline was not exhausted)
- WOW metrics missing for a required stage are treated as degraded/partial with explicit reasons.

## Zed parity hook path

- Runner supports hook-based ready events for Zed forks:
  - launch args: `--bench-target-file`, `--bench-ready-signal`, `--bench-ready-mode`
  - mode control: `--zed-bench-hook auto|off|required`
- `auto` mode retries without hook args for compatibility with non-hooked Zed builds.

## Observer-effect workflow

- To quantify instrumentation overhead use:
  - `./scripts/observer-effect-benchmark.sh <runs> <fixture>`
- Compare p50 open-latency and automation-overhead with WOW metrics on vs off.
- Keep the instrumentation delta near zero and monitor trend across commits.
