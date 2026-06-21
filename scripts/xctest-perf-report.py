#!/usr/bin/env python3
"""Parse XCTest performance logs into durable JSON/Markdown reports.

This is intentionally log-based rather than xcresult-private-API-based so it
keeps working in local agent runs, CI logs, and archived benchmark folders.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any


MEASURE_RE = re.compile(
    r"Test Case '-\[(?P<suite>[^ ]+) (?P<method>[^\]]+)\]' measured "
    r"\[(?P<metric>[^\]]+)\] average: (?P<average>[-0-9.]+), "
    r"relative standard deviation: (?P<rsd>[-0-9.]+)%, values: "
    r"\[(?P<values>[^\]]*)\], performanceMetricID:(?P<metric_id>[^,]+), "
    r"baselineName: \"(?P<baseline_name>[^\"]*)\", baselineAverage: "
    r"(?P<baseline_average>[^,]*), polarity: (?P<polarity>[^,]+)"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate XCTest perf summary reports")
    parser.add_argument("--log", required=True, help="Path to xcodebuild XCTest perf log")
    parser.add_argument("--baseline-log", default=None, help="Optional baseline perf log")
    parser.add_argument("--out-json", required=True, help="Output metrics summary JSON")
    parser.add_argument("--out-md", required=True, help="Output Markdown summary")
    parser.add_argument("--command", default="", help="Command used for the run")
    parser.add_argument("--label", default="", help="Human label for the run")
    parser.add_argument("--run-dir", default="", help="Benchmark run directory")
    parser.add_argument("--fail-on-regression", action="store_true")
    parser.add_argument("--allow-empty", action="store_true", help="Allow logs with no XCTest performance metrics")
    parser.add_argument("--max-time-regression-pct", type=float, default=15.0)
    parser.add_argument("--max-memory-regression-pct", type=float, default=25.0)
    parser.add_argument("--min-time-regression-s", type=float, default=0.02)
    parser.add_argument("--min-memory-regression-mb", type=float, default=10.0)
    return parser.parse_args()


def run_text(command: list[str]) -> str | None:
    try:
        proc = subprocess.run(command, text=True, capture_output=True, check=False)
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def git_metadata() -> dict[str, Any]:
    branch = run_text(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    commit = run_text(["git", "rev-parse", "HEAD"])
    short = run_text(["git", "rev-parse", "--short", "HEAD"])
    status = run_text(["git", "status", "--porcelain"])
    return {
        "branch": branch,
        "commit": commit,
        "short_commit": short,
        "dirty": bool(status),
        "status_porcelain": status or "",
    }


def environment_metadata() -> dict[str, Any]:
    xcodebuild = run_text(["xcodebuild", "-version"])
    sw_vers = run_text(["sw_vers"])
    sysctl_model = run_text(["sysctl", "-n", "hw.model"])
    sysctl_chip = run_text(["sysctl", "-n", "machdep.cpu.brand_string"])
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "xcodebuild_version": xcodebuild,
        "sw_vers": sw_vers,
        "hardware_model": sysctl_model,
        "cpu_brand": sysctl_chip,
    }


def parse_metric_label(label: str) -> tuple[str, str | None]:
    if "," not in label:
        return label.strip(), None
    name, unit = label.rsplit(",", 1)
    return name.strip(), unit.strip()


def parse_float_list(raw: str) -> list[float]:
    out: list[float] = []
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        try:
            out.append(float(piece))
        except ValueError:
            pass
    return out


def p95(values: list[float]) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    pos = 0.95 * (len(ordered) - 1)
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    frac = pos - lo
    return ordered[lo] * (1 - frac) + ordered[hi] * frac


def normalize_test_name(suite: str, method: str) -> str:
    class_name = suite.split(".")[-1]
    return f"{class_name}.{method}"


def parse_log(path: Path) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    metrics: list[dict[str, Any]] = []
    for match in MEASURE_RE.finditer(text):
        metric_name, unit = parse_metric_label(match.group("metric"))
        suite = match.group("suite")
        method = match.group("method")
        values = parse_float_list(match.group("values"))
        average = float(match.group("average"))
        rsd_pct = float(match.group("rsd"))
        metric_id = match.group("metric_id").strip()
        polarity = match.group("polarity").strip()
        normalized: dict[str, Any] = {
            "suite": suite,
            "class": suite.split(".")[-1],
            "method": method,
            "test": normalize_test_name(suite, method),
            "metric": metric_name,
            "unit": unit,
            "average": average,
            "relative_standard_deviation_pct": rsd_pct,
            "values": values,
            "p95": p95(values),
            "metric_id": metric_id,
            "polarity": polarity,
        }
        if unit == "s":
            normalized["average_ms"] = average * 1000.0
            normalized["p95_ms"] = None if normalized["p95"] is None else normalized["p95"] * 1000.0
        elif unit == "kB":
            normalized["average_mb"] = average / 1024.0
            normalized["p95_mb"] = None if normalized["p95"] is None else normalized["p95"] / 1024.0
        metrics.append(normalized)
    return metrics


def metric_key(metric: dict[str, Any]) -> tuple[str, str]:
    return metric["test"], metric["metric_id"]


def build_comparisons(
    current: list[dict[str, Any]],
    baseline: list[dict[str, Any]],
    *,
    max_time_regression_pct: float,
    max_memory_regression_pct: float,
    min_time_regression_s: float,
    min_memory_regression_mb: float,
) -> list[dict[str, Any]]:
    baseline_by_key = {metric_key(metric): metric for metric in baseline}
    comparisons: list[dict[str, Any]] = []
    for metric in current:
        base = baseline_by_key.get(metric_key(metric))
        if not base:
            continue
        base_avg = float(base["average"])
        cur_avg = float(metric["average"])
        delta = cur_avg - base_avg
        delta_pct = None if base_avg == 0 else (delta / base_avg) * 100.0
        unit = metric.get("unit")
        threshold_pct = max_time_regression_pct if unit == "s" else max_memory_regression_pct
        min_abs = min_time_regression_s if unit == "s" else (min_memory_regression_mb * 1024.0 if unit == "kB" else 0.0)
        lower_is_better = "prefers smaller" in metric.get("polarity", "")
        regression = False
        if delta_pct is not None and lower_is_better:
            regression = delta > min_abs and delta_pct > threshold_pct
        elif delta_pct is not None and not lower_is_better:
            regression = delta < -min_abs and abs(delta_pct) > threshold_pct
        comparisons.append(
            {
                "test": metric["test"],
                "metric": metric["metric"],
                "unit": unit,
                "metric_id": metric["metric_id"],
                "baseline_average": base_avg,
                "current_average": cur_avg,
                "delta": delta,
                "delta_pct": delta_pct,
                "baseline_rsd_pct": base["relative_standard_deviation_pct"],
                "current_rsd_pct": metric["relative_standard_deviation_pct"],
                "regression": regression,
            }
        )
    return comparisons


def build_missing_baseline_metrics(
    current: list[dict[str, Any]],
    baseline: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Return baseline metrics that are absent from the current candidate run.

    A/B benchmark gates must not pass just because a candidate stopped emitting
    an expensive or unstable metric. These entries are separate from normal
    comparisons because there is no current average to compare.
    """

    current_keys = {metric_key(metric) for metric in current}
    missing: list[dict[str, Any]] = []
    for base in baseline:
        if metric_key(base) in current_keys:
            continue
        missing.append(
            {
                "test": base["test"],
                "metric": base["metric"],
                "unit": base.get("unit"),
                "metric_id": base["metric_id"],
                "baseline_average": base["average"],
                "baseline_rsd_pct": base["relative_standard_deviation_pct"],
                "reason": "missing_from_current_run",
            }
        )
    return sorted(missing, key=lambda item: (item["test"], item["metric_id"]))


def group_by_test(metrics: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for metric in metrics:
        grouped.setdefault(metric["test"], []).append(metric)
    return grouped


def format_value(value: float | None, unit: str | None) -> str:
    if value is None:
        return "n/a"
    if unit == "s":
        return f"{value:.3f}s"
    if unit == "kB":
        return f"{value / 1024.0:.1f} MB"
    return f"{value:.3f}"


def format_delta(value: float | None, unit: str | None) -> str:
    if value is None:
        return "n/a"
    prefix = "+" if value > 0 else ""
    if unit == "s":
        return f"{prefix}{value:.3f}s"
    if unit == "kB":
        return f"{prefix}{value / 1024.0:.1f} MB"
    return f"{prefix}{value:.3f}"


def metric_sort_key(metric: dict[str, Any]) -> tuple[str, str]:
    order = {
        "Clock Monotonic Time": "0",
        "Memory Peak Physical": "1",
        "Memory Physical": "2",
    }
    return metric["test"], order.get(metric["metric"], metric["metric"])


def write_markdown(payload: dict[str, Any], path: Path) -> None:
    lines: list[str] = []
    label = payload.get("label") or "XCTest performance run"
    lines.append(f"# {label}")
    lines.append("")
    lines.append(f"- Generated: {payload['generated_at']}")
    if payload.get("command"):
        lines.append(f"- Command: `{payload['command']}`")
    if payload.get("run_dir"):
        lines.append(f"- Run directory: `{payload['run_dir']}`")
    git = payload.get("git", {})
    if git:
        dirty = "dirty" if git.get("dirty") else "clean"
        lines.append(f"- Git: `{git.get('branch')}` `{git.get('short_commit')}` ({dirty})")
    lines.append(f"- Metrics parsed: {len(payload['metrics'])}")
    lines.append("")

    comparisons = payload.get("comparisons") or []
    missing_metrics = payload.get("missing_baseline_metrics") or []
    if comparisons:
        regressions = [c for c in comparisons if c.get("regression")]
        lines.append("## Baseline comparison")
        lines.append("")
        lines.append(f"- Comparable metrics: {len(comparisons)}")
        lines.append(f"- Regressions over configured threshold: {len(regressions)}")
        lines.append("")
        lines.append("| Test | Metric | Current | Baseline | Delta | Delta % | Current RSD | Regression |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |")
        for cmp in comparisons:
            pct = cmp.get("delta_pct")
            pct_s = "n/a" if pct is None else f"{pct:+.1f}%"
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"`{cmp['test']}`",
                        cmp["metric"],
                        format_value(cmp["current_average"], cmp.get("unit")),
                        format_value(cmp["baseline_average"], cmp.get("unit")),
                        format_delta(cmp["delta"], cmp.get("unit")),
                        pct_s,
                        f"{cmp['current_rsd_pct']:.2f}%",
                        "YES" if cmp.get("regression") else "",
                    ]
                )
                + " |"
            )
        lines.append("")

    if missing_metrics:
        lines.append("## Missing baseline metrics")
        lines.append("")
        lines.append(
            "These metrics were present in the selected baseline but were not emitted by the current run. "
            "Treat this as a failed A/B gate when `--fail-on-regression` is enabled."
        )
        lines.append("")
        lines.append("| Test | Metric | Baseline | RSD | Reason |")
        lines.append("| --- | --- | ---: | ---: | --- |")
        for metric in missing_metrics:
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"`{metric['test']}`",
                        metric["metric"],
                        format_value(metric["baseline_average"], metric.get("unit")),
                        f"{metric['baseline_rsd_pct']:.2f}%",
                        metric["reason"],
                    ]
                )
                + " |"
            )
        lines.append("")

    lines.append("## Current metrics")
    lines.append("")
    lines.append("| Test | Metric | Average | p95 sample | RSD | Samples |")
    lines.append("| --- | --- | ---: | ---: | ---: | --- |")
    for metric in sorted(payload["metrics"], key=metric_sort_key):
        sample_values = metric.get("values") or []
        sample_preview = ", ".join(f"{v:.3f}" for v in sample_values[:8])
        if len(sample_values) > 8:
            sample_preview += ", ..."
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{metric['test']}`",
                    metric["metric"],
                    format_value(metric["average"], metric.get("unit")),
                    format_value(metric.get("p95"), metric.get("unit")),
                    f"{metric['relative_standard_deviation_pct']:.2f}%",
                    f"`[{sample_preview}]`",
                ]
            )
            + " |"
        )
    lines.append("")

    if comparisons:
        lines.append("## Interpretation notes")
        lines.append("")
        lines.append("- Timing metrics and memory metrics are compared independently.")
        lines.append("- XCTest process-level peak physical memory can inherit previous test high-water state; isolate per-test runs before treating peak memory as a product claim.")
        lines.append("- A/B claims should cite the JSON plus the raw log, not only this Markdown summary.")
        lines.append("")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    log_path = Path(args.log)
    if not log_path.exists():
        print(f"error: log not found: {log_path}", file=sys.stderr)
        return 2

    current = parse_log(log_path)
    if not current and not args.allow_empty:
        print(f"error: no XCTest performance metrics found in {log_path}", file=sys.stderr)
        return 1

    baseline_metrics: list[dict[str, Any]] = []
    if args.baseline_log:
        baseline_path = Path(args.baseline_log)
        if not baseline_path.exists():
            print(f"error: baseline log not found: {baseline_path}", file=sys.stderr)
            return 2
        baseline_metrics = parse_log(baseline_path)
        if not baseline_metrics:
            print(f"error: no XCTest performance metrics found in baseline log: {baseline_path}", file=sys.stderr)
            return 1

    comparisons = build_comparisons(
        current,
        baseline_metrics,
        max_time_regression_pct=args.max_time_regression_pct,
        max_memory_regression_pct=args.max_memory_regression_pct,
        min_time_regression_s=args.min_time_regression_s,
        min_memory_regression_mb=args.min_memory_regression_mb,
    ) if baseline_metrics else []
    missing_baseline_metrics = build_missing_baseline_metrics(current, baseline_metrics) if baseline_metrics else []

    payload = {
        "version": 1,
        "suite_kind": "xctest_native_performance",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "label": args.label,
        "command": args.command,
        "run_dir": args.run_dir,
        "log": str(log_path),
        "baseline_log": args.baseline_log,
        "git": git_metadata(),
        "environment": environment_metadata(),
        "metrics": current,
        "tests": group_by_test(current),
        "comparisons": comparisons,
        "missing_baseline_metrics": missing_baseline_metrics,
        "thresholds": {
            "max_time_regression_pct": args.max_time_regression_pct,
            "max_memory_regression_pct": args.max_memory_regression_pct,
            "min_time_regression_s": args.min_time_regression_s,
            "min_memory_regression_mb": args.min_memory_regression_mb,
        },
    }

    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_markdown(payload, out_md)

    regressions = [c for c in comparisons if c.get("regression")]
    print(f"Parsed {len(current)} metrics from {log_path}")
    if comparisons:
        print(f"Compared {len(comparisons)} metrics against baseline; regressions={len(regressions)}")
    if missing_baseline_metrics:
        print(f"Missing baseline metrics in current run: {len(missing_baseline_metrics)}")
    print(f"Wrote JSON: {out_json}")
    print(f"Wrote Markdown: {out_md}")

    if (regressions or missing_baseline_metrics) and args.fail_on_regression:
        if regressions:
            print("Performance regressions exceeded configured thresholds:", file=sys.stderr)
        for regression in regressions[:20]:
            pct = regression.get("delta_pct")
            print(
                f"  - {regression['test']} {regression['metric']}: "
                f"{pct:+.1f}%",
                file=sys.stderr,
            )
        if missing_baseline_metrics:
            print("Baseline metrics were missing from the current run:", file=sys.stderr)
            for metric in missing_baseline_metrics[:20]:
                print(
                    f"  - {metric['test']} {metric['metric']} ({metric['metric_id']})",
                    file=sys.stderr,
                )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
