#!/usr/bin/env python3
"""
bench-regression-check.py — Detect performance regressions between benchmark runs.

Supports legacy v1/v2/v3 and v4 benchmark reports (cross-editor + internal microbenchmark).
- Primary: Mann-Whitney U test + bootstrap CI when raw runs are present.
- Secondary: threshold fallback when only medians exist.
- Adds failure/timeout-rate comparisons and Official/Partial policy gating.
"""

import argparse
import json
import math
import random
import sys
from pathlib import Path


METRICS = {
    # Startup / latency metrics (lower is better)
    "cold_start_latency": {"run_key": "cold_start_latency_ms", "lower_is_better": True},
    "warm_start_latency": {"run_key": "warm_start_latency_ms", "lower_is_better": True},
    "open_latency": {"run_key": "open_latency_ms", "lower_is_better": True},
    "typing_latency": {"run_key": "typing_latency_ms", "lower_is_better": True},
    "save_ui_ack_latency": {"run_key": "save_ui_ack_latency_ms", "lower_is_better": True},
    "save_durable_latency": {"run_key": "save_durable_latency_ms", "lower_is_better": True},
    "quit_latency": {"run_key": "quit_latency_ms", "lower_is_better": True},
    "find_latency": {"run_key": "find_latency_ms", "lower_is_better": True},
    "scroll_settle_latency": {"run_key": "scroll_settle_latency_ms", "lower_is_better": True},
    "scroll_p95_frame_time": {"run_key": "scroll_p95_frame_time_ms", "lower_is_better": True},
    "scroll_p99_frame_time": {"run_key": "scroll_p99_frame_time_ms", "lower_is_better": True},
    "scroll_hitch_ms_per_s": {"run_key": "scroll_hitch_ms_per_s", "lower_is_better": True},
    "window_visible": {"run_key": "window_visible_ms", "lower_is_better": True},
    "first_paint": {"run_key": "first_paint_ms", "lower_is_better": True},
    "render_stable": {"run_key": "render_stable_ms", "lower_is_better": True},
    "automation_overhead": {"run_key": "automation_overhead_ms", "lower_is_better": True},
    "unattributed_open_budget": {"run_key": "unattributed_open_budget_ms", "lower_is_better": True},
    "time_to_stable_layout": {"run_key": "time_to_stable_layout_ms", "lower_is_better": True},
    "post_ready_export_quiescence": {"run_key": "post_ready_export_quiescence_ms", "lower_is_better": True},
    "full_fidelity_end_to_end_latency": {"run_key": "full_fidelity_end_to_end_latency_ms", "lower_is_better": True},
    # Memory (lower is better)
    "memory_phys": {"run_key": "memory_phys_mb", "lower_is_better": True},
    "memory_rss": {"run_key": "memory_rss_mb", "lower_is_better": True},
    # Smoothness signal where higher is better.
    "scroll_effective_fps": {"run_key": "scroll_effective_fps", "lower_is_better": False},
    "scroll_jank_33ms_count": {"run_key": "scroll_jank_33ms_count", "lower_is_better": True},
    "scroll_jank_50ms_count": {"run_key": "scroll_jank_50ms_count", "lower_is_better": True},
    # Kern internal microbenchmark stages (lower is better)
    "wow_parse_latency": {"run_key": "wow_parse_latency_ms", "lower_is_better": True},
    "wow_layout_latency": {"run_key": "wow_layout_latency_ms", "lower_is_better": True},
    "wow_paint_ready_latency": {"run_key": "wow_paint_ready_latency_ms", "lower_is_better": True},
    "wow_edit_apply_latency": {"run_key": "wow_edit_apply_latency_ms", "lower_is_better": True},
    "wow_save_serialize_latency": {"run_key": "wow_save_serialize_latency_ms", "lower_is_better": True},
    "wow_open_ready_latency": {"run_key": "wow_open_ready_latency_ms", "lower_is_better": True},
    "wow_viewport_semantic_ready_latency": {"run_key": "wow_viewport_semantic_ready_latency_ms", "lower_is_better": True},
    "wow_viewport_fidelity_ready_latency": {"run_key": "wow_viewport_fidelity_ready_latency_ms", "lower_is_better": True},
    "wow_full_document_fidelity_ready_latency": {"run_key": "wow_full_document_fidelity_ready_latency_ms", "lower_is_better": True},
}

INTERNAL_METRIC_KEYS = {
    "wow_parse_latency",
    "wow_layout_latency",
    "wow_paint_ready_latency",
    "wow_edit_apply_latency",
    "wow_save_serialize_latency",
    "wow_open_ready_latency",
    "wow_viewport_semantic_ready_latency",
    "wow_viewport_fidelity_ready_latency",
    "wow_full_document_fidelity_ready_latency",
}


def metric_allowlist_for_suite(report: dict) -> set[str]:
    suite_kind = report.get("suite_kind")
    if suite_kind == "internal_microbenchmark":
        return set(INTERNAL_METRIC_KEYS)
    if suite_kind == "cross_editor_open_only":
        return {
            "cold_start_latency",
            "warm_start_latency",
            "open_latency",
            "window_visible",
            "first_paint",
            "render_stable",
            "automation_overhead",
            "unattributed_open_budget",
            "time_to_stable_layout",
            "post_ready_export_quiescence",
        }
    if suite_kind == "cross_editor_full_fidelity":
        return {
            "cold_start_latency",
            "warm_start_latency",
            "open_latency",
            "window_visible",
            "first_paint",
            "render_stable",
            "automation_overhead",
            "unattributed_open_budget",
            "time_to_stable_layout",
            "post_ready_export_quiescence",
            "full_fidelity_end_to_end_latency",
            "wow_open_ready_latency",
            "wow_full_document_fidelity_ready_latency",
        }
    if suite_kind == "cross_editor":
        return set(METRICS.keys()) - INTERNAL_METRIC_KEYS
    return set(METRICS.keys())


def load_report(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def percentile_r7(sorted_vals: list[float], p: float) -> float:
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    if n == 1:
        return sorted_vals[0]
    index = p * (n - 1)
    lower = int(math.floor(index))
    upper = int(math.ceil(index))
    if lower == upper:
        return sorted_vals[lower]
    frac = index - lower
    return sorted_vals[lower] * (1 - frac) + sorted_vals[upper] * frac


def mann_whitney_u(x: list[float], y: list[float]) -> tuple[float, float]:
    nx, ny = len(x), len(y)
    if nx == 0 or ny == 0:
        return (0.0, 1.0)

    combined = [(val, "x") for val in x] + [(val, "y") for val in y]
    combined.sort(key=lambda t: t[0])
    n = nx + ny

    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j < n and combined[j][0] == combined[i][0]:
            j += 1
        avg_rank = (i + j + 1) / 2.0
        for k in range(i, j):
            ranks[k] = avg_rank
        i = j

    r1 = sum(ranks[k] for k in range(n) if combined[k][1] == "x")
    u1 = r1 - nx * (nx + 1) / 2
    u2 = nx * ny - u1
    u = min(u1, u2)

    mu = nx * ny / 2
    tie_counts = {}
    for r in ranks:
        tie_counts[r] = tie_counts.get(r, 0) + 1
    tie_correction = sum(t ** 3 - t for t in tie_counts.values()) / (12 * (n * (n - 1)))
    sigma = math.sqrt(nx * ny * ((n + 1) / 12 - tie_correction))
    if sigma == 0:
        return (u, 1.0)

    z = (abs(u1 - mu) - 0.5) / sigma
    p = 2 * _norm_sf(z)
    return (u, p)


def _norm_sf(z: float) -> float:
    return 0.5 * math.erfc(z / math.sqrt(2))


def bootstrap_difference_ci(x: list[float], y: list[float], resamples: int = 10_000, seed: int = 42) -> tuple[float, float]:
    if not x or not y:
        return (0.0, 0.0)
    rng = random.Random(seed)
    diffs = []
    for _ in range(resamples):
        sx = sorted(rng.choices(x, k=len(x)))
        sy = sorted(rng.choices(y, k=len(y)))
        diffs.append(percentile_r7(sy, 0.5) - percentile_r7(sx, 0.5))
    diffs.sort()
    return (percentile_r7(diffs, 0.025), percentile_r7(diffs, 0.975))


def extract_raw_runs(result: dict, metric_key: str) -> list[float]:
    run_key = METRICS.get(metric_key, {}).get("run_key")
    if run_key is None:
        # Legacy fallback for known old names
        if metric_key in ("window_visible", "first_paint", "render_stable"):
            run_key = metric_key + "_ms"
        elif metric_key in ("memory_phys", "memory_rss"):
            run_key = metric_key + "_mb"
        else:
            return []

    runs = result.get("runs", [])
    values = []
    for run in runs:
        value = run.get(run_key)
        if value is not None:
            values.append(float(value))
    return values


def extract_metrics(result: dict) -> dict[str, dict]:
    metrics: dict[str, dict] = {}
    stats = result.get("stats", {})
    runs = result.get("runs", [])

    for metric in METRICS.keys():
        if metric in stats and stats[metric] is not None:
            metrics[metric] = stats[metric]
            continue

        raw = extract_raw_runs(result, metric)
        if raw:
            metrics[metric] = summarize_raw_metric(raw, attempts=len(runs) if runs else len(raw))

    # Legacy fallback keys
    for key in ("window_visible", "first_paint", "render_stable", "memory_phys", "memory_rss"):
        if key in stats and stats[key] is not None:
            metrics[key] = stats[key]

    if "memory_phys_mb" in stats and stats["memory_phys_mb"] is not None:
        metrics["memory_phys"] = {"median": stats["memory_phys_mb"], "std": 0, "failure_rate_pct": 0}
    if "memory_rss_mb" in stats and stats["memory_rss_mb"] is not None:
        metrics["memory_rss"] = {"median": stats["memory_rss_mb"], "std": 0, "failure_rate_pct": 0}

    return metrics


def summarize_raw_metric(values: list[float], attempts: int) -> dict:
    sorted_vals = sorted(values)
    n = len(sorted_vals)
    if n == 0:
        return {
            "n": 0,
            "median": 0.0,
            "mean": 0.0,
            "std": 0.0,
            "failure_rate_pct": 0.0,
        }

    mean = sum(sorted_vals) / n
    if n > 1:
        variance = sum((v - mean) ** 2 for v in sorted_vals) / (n - 1)
    else:
        variance = 0.0
    std = math.sqrt(variance)
    attempts = max(attempts, n)
    failures = max(0, attempts - n)
    failure_rate = (failures / attempts) * 100 if attempts else 0.0

    return {
        "n": n,
        "median": percentile_r7(sorted_vals, 0.5),
        "mean": mean,
        "std": std,
        "failure_rate_pct": failure_rate,
    }


def status_for_direction(effect_size: float, threshold: float, lower_is_better: bool) -> str:
    """
    effect_size = latest - baseline
    """
    if lower_is_better:
        if effect_size > threshold:
            return "REGRESSION"
        if effect_size < -threshold:
            return "IMPROVEMENT"
    else:
        if effect_size < -threshold:
            return "REGRESSION"
        if effect_size > threshold:
            return "IMPROVEMENT"
    return "OK"


def check_regression_statistical(
    metric_name: str,
    baseline_runs: list[float],
    latest_runs: list[float],
    threshold_pct: float,
    min_abs_threshold: float,
) -> tuple[str, str, dict]:
    b_sorted = sorted(baseline_runs)
    l_sorted = sorted(latest_runs)
    b_median = percentile_r7(b_sorted, 0.5)
    l_median = percentile_r7(l_sorted, 0.5)

    if b_median == 0:
        pct_change = 0.0
    else:
        pct_change = ((l_median - b_median) / b_median) * 100
    effect_size = l_median - b_median

    u_stat, p_value = mann_whitney_u(baseline_runs, latest_runs)
    ci_lo, ci_hi = bootstrap_difference_ci(baseline_runs, latest_runs)

    details = {
        "mann_whitney_u": round(u_stat, 2),
        "mann_whitney_p": round(p_value, 6),
        "bootstrap_ci_lower": round(ci_lo, 2),
        "bootstrap_ci_upper": round(ci_hi, 2),
        "effect_size": round(effect_size, 2),
        "baseline_median": round(b_median, 2),
        "latest_median": round(l_median, 2),
        "pct_change": round(pct_change, 1),
    }

    relative_threshold = abs(b_median) * threshold_pct / 100 if b_median != 0 else 0.0
    abs_threshold = max(relative_threshold, min_abs_threshold)
    direction = METRICS.get(metric_name, {}).get("lower_is_better", True)

    if p_value < 0.05:
        status = status_for_direction(effect_size, abs_threshold, lower_is_better=direction)
    else:
        status = "OK"

    message = (
        f"{metric_name}: {b_median:.2f} -> {l_median:.2f} "
        f"({pct_change:+.1f}%, p={p_value:.4f}, delta={effect_size:+.2f}, CI=[{ci_lo:.2f}, {ci_hi:.2f}])"
    )
    return status, message, details


def check_regression_threshold(
    metric_name: str,
    baseline: dict,
    latest: dict,
    threshold_pct: float,
    min_abs_threshold: float,
) -> tuple[str, str, dict]:
    b_median = baseline.get("median", 0)
    l_median = latest.get("median", 0)
    b_std = baseline.get("std", 0)

    if b_median == 0:
        pct_change = 0.0
    else:
        pct_change = ((l_median - b_median) / b_median) * 100
    effect_size = l_median - b_median
    relative_threshold = abs(b_median) * threshold_pct / 100 if b_median != 0 else 0.0
    abs_threshold = max(relative_threshold, min_abs_threshold)
    lower_is_better = METRICS.get(metric_name, {}).get("lower_is_better", True)

    status = status_for_direction(effect_size, abs_threshold, lower_is_better)

    # Keep std-based sanity gate for regression only in legacy mode.
    if status == "REGRESSION" and lower_is_better and (l_median - b_median) <= 2 * b_std:
        status = "OK"

    details = {
        "baseline_median": round(b_median, 2),
        "latest_median": round(l_median, 2),
        "pct_change": round(pct_change, 1),
        "effect_size": round(effect_size, 2),
    }

    message = f"{metric_name}: {b_median:.2f} -> {l_median:.2f} ({pct_change:+.1f}%)"
    return status, message, details


def compare_failure_rates(metric: str, baseline_stats: dict, latest_stats: dict) -> tuple[str, str, dict]:
    b_fail = float(baseline_stats.get("failure_rate_pct", 0) or 0)
    l_fail = float(latest_stats.get("failure_rate_pct", 0) or 0)
    delta = l_fail - b_fail

    details = {
        "baseline_failure_rate_pct": round(b_fail, 2),
        "latest_failure_rate_pct": round(l_fail, 2),
        "failure_rate_delta_pct": round(delta, 2),
    }

    # Any increase above 1 percentage point is treated as regression signal.
    if delta > 1.0:
        return (
            "REGRESSION",
            f"{metric} failure rate: {b_fail:.1f}% -> {l_fail:.1f}% (+{delta:.1f}pp)",
            details,
        )
    if delta < -1.0:
        return (
            "IMPROVEMENT",
            f"{metric} failure rate: {b_fail:.1f}% -> {l_fail:.1f}% ({delta:.1f}pp)",
            details,
        )
    return (
        "OK",
        f"{metric} failure rate: {b_fail:.1f}% -> {l_fail:.1f}% ({delta:+.1f}pp)",
        details,
    )


def check_environment_compat(baseline: dict, latest: dict):
    b_env = baseline.get("environment", {})
    l_env = latest.get("environment", {})

    warnings = []
    if b_env.get("chip") != l_env.get("chip"):
        warnings.append(f"  Hardware mismatch: {b_env.get('chip')} vs {l_env.get('chip')}")
    if b_env.get("power") != l_env.get("power"):
        warnings.append(f"  Power source differs: {b_env.get('power')} vs {l_env.get('power')}")
    b_thermal = b_env.get("thermal_pct", 100)
    l_thermal = l_env.get("thermal_pct", 100)
    if b_thermal < 100 or l_thermal < 100:
        warnings.append(f"  Thermal throttling: baseline={b_thermal}%, latest={l_thermal}%")

    if warnings:
        print("WARNING: Environment differences detected:")
        for warning in warnings:
            print(warning)
        print()


def classification_policy_issues(
    baseline: dict,
    latest: dict,
    require_cross_editor: bool = False,
) -> list[str]:
    issues: list[str] = []
    b_class = baseline.get("run_classification")
    l_class = latest.get("run_classification")
    b_suite_kind = baseline.get("suite_kind")
    l_suite_kind = latest.get("suite_kind")

    if b_class == "official" and l_class == "partial":
        issues.append("latest run downgraded from official to partial")

    if l_class == "partial":
        partial_reasons = latest.get("partial_reasons", [])
        if partial_reasons:
            issues.append("latest partial reasons: " + "; ".join(partial_reasons))
        else:
            issues.append("latest report is partial")

    if baseline.get("suite") and latest.get("suite") and baseline.get("suite") != latest.get("suite"):
        issues.append(f"suite mismatch: baseline={baseline.get('suite')} latest={latest.get('suite')}")

    if b_suite_kind and l_suite_kind and b_suite_kind != l_suite_kind:
        issues.append(f"suite_kind mismatch: baseline={b_suite_kind} latest={l_suite_kind}")

    if require_cross_editor:
        if b_suite_kind and b_suite_kind != "cross_editor":
            issues.append(f"baseline suite_kind must be cross_editor (got {b_suite_kind})")
        if l_suite_kind and l_suite_kind != "cross_editor":
            issues.append(f"latest suite_kind must be cross_editor (got {l_suite_kind})")

    return issues


def main():
    parser = argparse.ArgumentParser(description="Check benchmark regressions (supports v4 dual-suite)")
    parser.add_argument("--baseline", required=True, help="Path to baseline JSON")
    parser.add_argument("--latest", required=True, help="Path to latest JSON")
    parser.add_argument("--threshold", type=float, default=5.0, help="Regression threshold percentage")
    parser.add_argument("--min-abs-ms", type=float, default=50.0, help="Minimum absolute threshold")
    parser.add_argument(
        "--require-cross-editor",
        action="store_true",
        help="Fail policy checks unless both reports are suite_kind=cross_editor",
    )
    parser.add_argument("--json", help="Output results as JSON to this path")
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="Never fail exit code; print regressions for stabilization/reporting mode",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()

    if not Path(args.baseline).exists():
        print(f"Error: Baseline file not found: {args.baseline}", file=sys.stderr)
        sys.exit(1)
    if not Path(args.latest).exists():
        print(f"Error: Latest file not found: {args.latest}", file=sys.stderr)
        sys.exit(1)

    baseline = load_report(args.baseline)
    latest = load_report(args.latest)

    b_version = baseline.get("version", 1)
    l_version = latest.get("version", 1)

    print(f"Baseline: {args.baseline} (v{b_version})")
    print(f"Latest:   {args.latest} (v{l_version})")
    print(f"Threshold: {args.threshold}% / {args.min_abs_ms} absolute")

    use_statistical = b_version >= 3 and l_version >= 3
    if not use_statistical:
        print(
            f"WARNING: v{b_version}/v{l_version} JSON may lack full raw run data. "
            f"Using threshold fallback when necessary."
        )
    print()

    check_environment_compat(baseline, latest)

    policy_issues = classification_policy_issues(
        baseline,
        latest,
        require_cross_editor=args.require_cross_editor,
    )
    if policy_issues:
        print("Policy issues:")
        for issue in policy_issues:
            print(f"  - {issue}")
        print()

    baseline_by_editor = {r["editor"]: r for r in baseline.get("results", [])}
    latest_by_editor = {r["editor"]: r for r in latest.get("results", [])}
    baseline_allowlist = metric_allowlist_for_suite(baseline)
    latest_allowlist = metric_allowlist_for_suite(latest)
    shared_allowlist = baseline_allowlist & latest_allowlist

    regressions = []
    improvements = []
    stable = []
    json_results = []

    for editor_name in sorted(set(baseline_by_editor) & set(latest_by_editor)):
        b_result = baseline_by_editor[editor_name]
        l_result = latest_by_editor[editor_name]

        b_metrics = extract_metrics(b_result)
        l_metrics = extract_metrics(l_result)

        print(f"--- {editor_name} ---")

        for metric_name in sorted((set(b_metrics) & set(l_metrics)) & shared_allowlist):
            if use_statistical:
                b_runs = extract_raw_runs(b_result, metric_name)
                l_runs = extract_raw_runs(l_result, metric_name)
                if b_runs and l_runs:
                    status, message, details = check_regression_statistical(
                        metric_name,
                        b_runs,
                        l_runs,
                        args.threshold,
                        args.min_abs_ms,
                    )
                else:
                    status, message, details = check_regression_threshold(
                        metric_name,
                        b_metrics[metric_name],
                        l_metrics[metric_name],
                        args.threshold,
                        args.min_abs_ms,
                    )
            else:
                status, message, details = check_regression_threshold(
                    metric_name,
                    b_metrics[metric_name],
                    l_metrics[metric_name],
                    args.threshold,
                    args.min_abs_ms,
                )

            fail_status, fail_msg, fail_details = compare_failure_rates(
                metric_name,
                b_metrics[metric_name],
                l_metrics[metric_name],
            )

            if fail_status == "REGRESSION" and status != "REGRESSION":
                status = "REGRESSION"
                message = f"{message}; {fail_msg}"
            elif args.verbose:
                message = f"{message}; {fail_msg}"

            if status == "REGRESSION":
                regressions.append((editor_name, message))
                print(f"  *** REGRESSION *** {message}")
            elif status == "IMPROVEMENT":
                improvements.append((editor_name, message))
                print(f"  IMPROVED {message}")
            else:
                stable.append((editor_name, message))
                if args.verbose:
                    print(f"  OK {message}")

            record = {
                "editor": editor_name,
                "metric": metric_name,
                "status": status.lower(),
            }
            record.update(details)
            record.update(fail_details)
            json_results.append(record)

        print()

    for editor_name in sorted(set(latest_by_editor) - set(baseline_by_editor)):
        print(f"NEW: {editor_name} (no baseline for comparison)")
        print()

    if policy_issues:
        for issue in policy_issues:
            regressions.append(("policy", issue))

    print("=== Summary ===")
    print(f"  Regressions:  {len(regressions)}")
    print(f"  Improvements: {len(improvements)}")
    print(f"  Stable:       {len(stable)}")
    print()

    if regressions:
        print("REGRESSIONS DETECTED:")
        for editor, message in regressions:
            print(f"  [{editor}] {message}")
        print()

    if improvements:
        print("Improvements:")
        for editor, message in improvements:
            print(f"  [{editor}] {message}")
        print()

    if args.json:
        output = {
            "baseline": args.baseline,
            "latest": args.latest,
            "baseline_version": b_version,
            "latest_version": l_version,
            "threshold_pct": args.threshold,
            "min_abs": args.min_abs_ms,
            "statistical_test": "mann_whitney_u" if use_statistical else "threshold_fallback",
            "policy_issues": policy_issues,
            "regressions": len(regressions),
            "improvements": len(improvements),
            "stable": len(stable),
            "results": json_results,
        }
        with open(args.json, "w") as f:
            json.dump(output, f, indent=2)
        print(f"JSON results written to: {args.json}")

    if regressions and args.report_only:
        print("Report-only mode enabled: regressions reported but exit status forced to 0.")
        sys.exit(0)

    sys.exit(1 if regressions else 0)


if __name__ == "__main__":
    main()
