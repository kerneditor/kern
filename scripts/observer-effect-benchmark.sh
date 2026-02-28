#!/usr/bin/env bash
# observer-effect-benchmark.sh — compare open-ready latency with WOW instrumentation on vs off.

set -euo pipefail
cd "$(dirname "$0")/.."

RUNS="${1:-10}"
FIXTURE="${2:-test-fixtures/cross-editor-benchmark.md}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="benchmark-archive/runtime-check/observer-effect-${STAMP}"
mkdir -p "$OUT_DIR"

if [[ ! -f "$FIXTURE" ]]; then
  echo "Error: fixture not found: $FIXTURE" >&2
  exit 1
fi

echo "== Observer-effect benchmark =="
echo "Runs:    $RUNS"
echo "Fixture: $FIXTURE"
echo "Out:     $OUT_DIR"

echo "\n[1/2] Instrumentation enabled"
./scripts/cross-editor-benchmark.sh \
  --suite benchmark_open_ready \
  --editor Kern \
  --file "$FIXTURE" \
  --runs "$RUNS" \
  --warmup-runs 0 \
  --warm \
  --kern-open-metric-source probe \
  --zed-bench-hook off \
  --json "$OUT_DIR/enabled.json" \
  --markdown "$OUT_DIR/enabled.md"

echo "\n[2/2] Instrumentation disabled"
./scripts/cross-editor-benchmark.sh \
  --suite benchmark_open_ready \
  --editor Kern \
  --file "$FIXTURE" \
  --runs "$RUNS" \
  --warmup-runs 0 \
  --warm \
  --disable-wow-metrics \
  --kern-open-metric-source probe \
  --zed-bench-hook off \
  --json "$OUT_DIR/disabled.json" \
  --markdown "$OUT_DIR/disabled.md"

python3 - "$OUT_DIR/enabled.json" "$OUT_DIR/disabled.json" "$OUT_DIR/summary.md" <<'PY'
import json
import statistics
import sys

enabled_path, disabled_path, summary_path = sys.argv[1:4]

def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def metric_runs(report, key):
    runs = report.get("results", [{}])[0].get("runs", [])
    return [float(r[key]) for r in runs if r.get(key) is not None]

enabled = load(enabled_path)
disabled = load(disabled_path)

enabled_open = metric_runs(enabled, "open_latency_ms")
disabled_open = metric_runs(disabled, "open_latency_ms")
enabled_overhead = metric_runs(enabled, "automation_overhead_ms")
disabled_overhead = metric_runs(disabled, "automation_overhead_ms")

def p50(vals):
    if not vals:
        return None
    return statistics.median(vals)

def fmt(v):
    return "n/a" if v is None else f"{v:.2f}"

enabled_p50 = p50(enabled_open)
disabled_p50 = p50(disabled_open)
delta = None if enabled_p50 is None or disabled_p50 is None else enabled_p50 - disabled_p50

enabled_overhead_p50 = p50(enabled_overhead)
disabled_overhead_p50 = p50(disabled_overhead)

delta_pct = None
if delta is not None and disabled_p50 and disabled_p50 != 0:
    delta_pct = (delta / disabled_p50) * 100

lines = [
    "# Observer-effect benchmark",
    "",
    "| Variant | open_latency p50 (ms) | automation_overhead p50 (ms) |",
    "| --- | ---: | ---: |",
    f"| WOW enabled | {fmt(enabled_p50)} | {fmt(enabled_overhead_p50)} |",
    f"| WOW disabled | {fmt(disabled_p50)} | {fmt(disabled_overhead_p50)} |",
    "",
    f"Delta (enabled - disabled): {fmt(delta)} ms" + ("" if delta_pct is None else f" ({delta_pct:+.2f}%)"),
    "",
    "Interpretation:",
    "- Positive delta means instrumentation adds latency.",
    "- Keep this delta near 0ms and watch changes across commits.",
]

with open(summary_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print("\nWrote summary:", summary_path)
PY

echo "Done. Artifacts in $OUT_DIR"
