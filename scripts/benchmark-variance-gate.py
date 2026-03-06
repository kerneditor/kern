#!/usr/bin/env python3
"""Validate benchmark stability thresholds from kern-bench results JSON."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark variance gate")
    parser.add_argument("--results", required=True, help="Path to kern-bench results.json")
    parser.add_argument("--editor", required=True, help="Editor name (e.g. Kern, Zed)")
    parser.add_argument(
        "--metric",
        required=True,
        help=(
            "Stats metric key in results[*].stats (e.g. full_fidelity_end_to_end_latency, "
            "open_latency, wow_full_document_fidelity_ready_latency)"
        ),
    )
    parser.add_argument("--max-p95-over-p50", type=float, default=None)
    parser.add_argument("--max-cv-pct", type=float, default=None)
    parser.add_argument("--max-failure-rate-pct", type=float, default=0.0)
    parser.add_argument("--max-timeouts", type=int, default=0)
    parser.add_argument("--max-failures", type=int, default=0)
    parser.add_argument(
        "--compare-editor",
        default=None,
        help="Optional competitor editor for p50 gap check",
    )
    parser.add_argument(
        "--compare-metric",
        default=None,
        help="Optional competitor metric key (defaults to --metric)",
    )
    parser.add_argument(
        "--max-p50-gap-ms",
        type=float,
        default=None,
        help=(
            "Optional max allowed (editor p50 - compare-editor p50) in ms. "
            "Set <= 0 to require parity/lead."
        ),
    )
    return parser.parse_args()


def fail(message: str) -> None:
    print(f"[FAIL] {message}")
    sys.exit(1)


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        fail(f"results file not found: {path}")
    try:
        return json.loads(path.read_text())
    except Exception as exc:  # pragma: no cover - defensive
        fail(f"unable to parse JSON: {exc}")


def find_editor_result(payload: dict[str, Any], editor: str) -> dict[str, Any]:
    results = payload.get("results")
    if not isinstance(results, list):
        fail("results JSON missing top-level 'results' array")

    normalized = editor.strip().lower()
    for entry in results:
        name = str(entry.get("editor", "")).strip().lower()
        if name == normalized:
            return entry

    known = ", ".join(str(entry.get("editor", "?")) for entry in results)
    fail(f"editor '{editor}' not found. available: {known}")


def get_metric_stats(editor_result: dict[str, Any], metric_key: str) -> dict[str, Any]:
    stats = editor_result.get("stats")
    if not isinstance(stats, dict):
        fail("editor result missing 'stats' object")

    metric = stats.get(metric_key)
    if not isinstance(metric, dict):
        available = ", ".join(sorted(stats.keys()))
        fail(f"metric '{metric_key}' missing in stats. available: {available}")

    required_fields = ["median", "p95", "cv_pct", "failure_rate_pct", "timeouts", "failures"]
    missing = [field for field in required_fields if field not in metric]
    if missing:
        fail(f"metric '{metric_key}' missing fields: {', '.join(missing)}")

    return metric


def main() -> None:
    args = parse_args()
    payload = load_json(Path(args.results))

    editor_result = find_editor_result(payload, args.editor)
    metric = get_metric_stats(editor_result, args.metric)

    p50 = float(metric["median"])
    p95 = float(metric["p95"])
    cv_pct = float(metric["cv_pct"])
    failure_rate_pct = float(metric["failure_rate_pct"])
    timeouts = int(metric["timeouts"])
    failures = int(metric["failures"])

    if p50 <= 0:
        fail(f"{args.editor}:{args.metric} p50 is non-positive ({p50})")

    ratio = p95 / p50 if p50 > 0 else math.inf

    print("[INFO] Variance gate input")
    print(f"  editor={args.editor}")
    print(f"  metric={args.metric}")
    print(f"  p50={p50:.2f}ms")
    print(f"  p95={p95:.2f}ms")
    print(f"  p95/p50={ratio:.3f}")
    print(f"  cv_pct={cv_pct:.2f}")
    print(f"  failure_rate_pct={failure_rate_pct:.2f}")
    print(f"  failures={failures}")
    print(f"  timeouts={timeouts}")

    violations: list[str] = []

    if args.max_p95_over_p50 is not None and ratio > args.max_p95_over_p50:
        violations.append(
            f"p95/p50 {ratio:.3f} exceeds max {args.max_p95_over_p50:.3f}"
        )

    if args.max_cv_pct is not None and cv_pct > args.max_cv_pct:
        violations.append(f"cv_pct {cv_pct:.2f} exceeds max {args.max_cv_pct:.2f}")

    if failure_rate_pct > args.max_failure_rate_pct:
        violations.append(
            f"failure_rate_pct {failure_rate_pct:.2f} exceeds max {args.max_failure_rate_pct:.2f}"
        )

    if failures > args.max_failures:
        violations.append(f"failures {failures} exceeds max {args.max_failures}")

    if timeouts > args.max_timeouts:
        violations.append(f"timeouts {timeouts} exceeds max {args.max_timeouts}")

    if args.compare_editor:
        compare_metric_key = args.compare_metric or args.metric
        compare_result = find_editor_result(payload, args.compare_editor)
        compare_metric = get_metric_stats(compare_result, compare_metric_key)
        compare_p50 = float(compare_metric["median"])
        gap_ms = p50 - compare_p50
        print("[INFO] Comparison")
        print(f"  against={args.compare_editor}:{compare_metric_key}")
        print(f"  compare_p50={compare_p50:.2f}ms")
        print(f"  gap_ms={gap_ms:.2f}")
        if args.max_p50_gap_ms is not None and gap_ms > args.max_p50_gap_ms:
            violations.append(
                f"p50 gap {gap_ms:.2f}ms exceeds max {args.max_p50_gap_ms:.2f}ms"
            )

    if violations:
        print("[FAIL] Variance gate failed")
        for violation in violations:
            print(f"  - {violation}")
        sys.exit(1)

    print("[PASS] Variance gate passed")


if __name__ == "__main__":
    main()
