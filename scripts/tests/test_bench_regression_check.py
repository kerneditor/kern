import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "bench-regression-check.py"


def make_report(
    run_classification: str,
    open_vals: list[float],
    failure_rate: float = 0.0,
    suite_kind: str = "cross_editor",
) -> dict:
    stats = {
        "open_latency": {
            "n": len(open_vals),
            "median": sorted(open_vals)[len(open_vals) // 2],
            "mean": sum(open_vals) / len(open_vals),
            "std": 1.0,
            "min": min(open_vals),
            "max": max(open_vals),
            "cv_pct": 1.0,
            "p25": min(open_vals),
            "p75": max(open_vals),
            "iqr": max(open_vals) - min(open_vals),
            "p95": max(open_vals),
            "p99": max(open_vals),
            "ci_lower": min(open_vals),
            "ci_upper": max(open_vals),
            "failure_rate_pct": failure_rate,
        },
        "memory_phys": {
            "n": len(open_vals),
            "median": 100.0,
            "mean": 100.0,
            "std": 1.0,
            "min": 99.0,
            "max": 101.0,
            "cv_pct": 1.0,
            "p25": 99.0,
            "p75": 101.0,
            "iqr": 2.0,
            "p95": 101.0,
            "p99": 101.0,
            "ci_lower": 99.0,
            "ci_upper": 101.0,
            "failure_rate_pct": 0.0,
        },
    }
    runs = [
        {
            "open_latency_ms": v,
            "memory_phys_mb": 100.0,
            "automation_overhead_ms": max(0.0, v - 40.0),
        }
        for v in open_vals
    ]

    return {
        "version": 4,
        "suite": "wow",
        "suite_kind": suite_kind,
        "run_classification": run_classification,
        "partial_reasons": [] if run_classification == "official" else ["required_metric_missing:open_latency_ms"],
        "environment": {
            "chip": "Apple M4",
            "power": "AC",
            "thermal_pct": 100,
        },
        "results": [
            {
                "editor": "Kern",
                "runs": runs,
                "stats": stats,
            }
        ],
    }


class BenchRegressionCheckTests(unittest.TestCase):
    def test_detects_policy_regression_when_latest_partial(self):
        baseline = make_report("official", [100, 101, 102])
        latest = make_report("partial", [100, 101, 102])

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Policy issues", proc.stdout)

    def test_detects_failure_rate_regression(self):
        baseline = make_report("official", [100, 101, 102], failure_rate=0.0)
        latest = make_report("official", [100, 101, 102], failure_rate=10.0)

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("failure rate", proc.stdout)

    def test_report_only_mode_does_not_fail_exit_code(self):
        baseline = make_report("official", [100, 101, 102], failure_rate=0.0)
        latest = make_report("official", [200, 201, 202], failure_rate=10.0)

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--baseline",
                    str(baseline_path),
                    "--latest",
                    str(latest_path),
                    "--report-only",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertEqual(proc.returncode, 0)
            self.assertIn("Report-only mode enabled", proc.stdout)

    def test_passes_when_metrics_stable(self):
        baseline = make_report("official", [100, 101, 102], failure_rate=0.0)
        latest = make_report("official", [100, 101, 102], failure_rate=0.0)

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertEqual(proc.returncode, 0)

    def test_threshold_fallback_honors_min_abs(self):
        baseline = make_report("official", [1000, 1000, 1000], failure_rate=0.0)
        latest = make_report("official", [1030, 1030, 1030], failure_rate=0.0)

        # Force threshold mode by downgrading version metadata.
        baseline["version"] = 2
        latest["version"] = 2

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--baseline",
                    str(baseline_path),
                    "--latest",
                    str(latest_path),
                    "--threshold",
                    "1",
                    "--min-abs-ms",
                    "50",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            # Delta is 30ms (< min_abs 50ms), so no regression.
            self.assertEqual(proc.returncode, 0)

    def test_compares_when_stats_missing_but_runs_present(self):
        baseline = make_report("official", [100, 100, 100], failure_rate=0.0)
        latest = make_report("official", [300, 300, 300], failure_rate=0.0)
        baseline["results"][0]["stats"] = {}
        latest["results"][0]["stats"] = {}

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("REGRESSION", proc.stdout)

    def test_require_cross_editor_rejects_internal_suite_kind(self):
        baseline = make_report("official", [100, 101, 102], suite_kind="cross_editor")
        latest = make_report("official", [100, 101, 102], suite_kind="internal_microbenchmark")

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--baseline",
                    str(baseline_path),
                    "--latest",
                    str(latest_path),
                    "--require-cross-editor",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("suite_kind", proc.stdout)

    def test_internal_suite_ignores_external_open_metric_noise(self):
        baseline = make_report("official", [100, 100, 100], suite_kind="internal_microbenchmark")
        latest = make_report("official", [500, 500, 500], suite_kind="internal_microbenchmark")

        wow_stats = {
            "wow_parse_latency": {
                "n": 3, "median": 10.0, "mean": 10.0, "std": 1.0,
                "min": 9.0, "max": 11.0, "cv_pct": 10.0,
                "p25": 9.0, "p75": 11.0, "iqr": 2.0, "p95": 11.0, "p99": 11.0,
                "ci_lower": 9.0, "ci_upper": 11.0, "failure_rate_pct": 0.0,
            }
        }
        baseline["results"][0]["stats"].update(wow_stats)
        latest["results"][0]["stats"].update(wow_stats)
        baseline["results"][0]["runs"] = [
            {"open_latency_ms": 100.0, "wow_parse_latency_ms": 10.0},
            {"open_latency_ms": 100.0, "wow_parse_latency_ms": 10.0},
            {"open_latency_ms": 100.0, "wow_parse_latency_ms": 10.0},
        ]
        latest["results"][0]["runs"] = [
            {"open_latency_ms": 500.0, "wow_parse_latency_ms": 10.0},
            {"open_latency_ms": 500.0, "wow_parse_latency_ms": 10.0},
            {"open_latency_ms": 500.0, "wow_parse_latency_ms": 10.0},
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertEqual(proc.returncode, 0)

    def test_internal_stage_metric_regression_detected_for_each_wow_metric(self):
        metric_pairs = [
            ("wow_parse_latency", "wow_parse_latency_ms"),
            ("wow_layout_latency", "wow_layout_latency_ms"),
            ("wow_paint_ready_latency", "wow_paint_ready_latency_ms"),
            ("wow_edit_apply_latency", "wow_edit_apply_latency_ms"),
            ("wow_save_serialize_latency", "wow_save_serialize_latency_ms"),
        ]

        for stats_key, run_key in metric_pairs:
            with self.subTest(metric=stats_key):
                baseline = make_report("official", [100, 101, 102], suite_kind="internal_microbenchmark")
                latest = make_report("official", [100, 101, 102], suite_kind="internal_microbenchmark")

                baseline["results"][0]["stats"][stats_key] = {
                    "n": 3, "median": 10.0, "mean": 10.0, "std": 1.0,
                    "min": 9.0, "max": 11.0, "cv_pct": 10.0,
                    "p25": 9.0, "p75": 11.0, "iqr": 2.0, "p95": 11.0, "p99": 11.0,
                    "ci_lower": 9.0, "ci_upper": 11.0, "failure_rate_pct": 0.0,
                }
                latest["results"][0]["stats"][stats_key] = {
                    "n": 3, "median": 190.0, "mean": 190.0, "std": 1.0,
                    "min": 189.0, "max": 191.0, "cv_pct": 1.0,
                    "p25": 189.0, "p75": 191.0, "iqr": 2.0, "p95": 191.0, "p99": 191.0,
                    "ci_lower": 189.0, "ci_upper": 191.0, "failure_rate_pct": 0.0,
                }
                baseline["results"][0]["runs"] = [{run_key: 10.0} for _ in range(3)]
                latest["results"][0]["runs"] = [{run_key: 190.0} for _ in range(3)]

                with tempfile.TemporaryDirectory() as tmpdir:
                    baseline_path = Path(tmpdir) / "baseline.json"
                    latest_path = Path(tmpdir) / "latest.json"
                    baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
                    latest_path.write_text(json.dumps(latest), encoding="utf-8")

                    proc = subprocess.run(
                        ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                        cwd=REPO_ROOT,
                        capture_output=True,
                        text=True,
                    )

                    self.assertNotEqual(proc.returncode, 0)
                    self.assertIn(stats_key, proc.stdout)

    def test_open_only_guardrail_metric_regression_is_detected(self):
        baseline = make_report("official", [100, 101, 102], suite_kind="cross_editor_open_only")
        latest = make_report("official", [100, 101, 102], suite_kind="cross_editor_open_only")

        baseline["results"][0]["stats"]["time_to_stable_layout"] = {
            "n": 3, "median": 30.0, "mean": 30.0, "std": 1.0,
            "min": 29.0, "max": 31.0, "cv_pct": 1.0,
            "p25": 29.0, "p75": 31.0, "iqr": 2.0, "p95": 31.0, "p99": 31.0,
            "ci_lower": 29.0, "ci_upper": 31.0, "failure_rate_pct": 0.0,
        }
        latest["results"][0]["stats"]["time_to_stable_layout"] = {
            "n": 3, "median": 160.0, "mean": 160.0, "std": 1.0,
            "min": 159.0, "max": 161.0, "cv_pct": 1.0,
            "p25": 159.0, "p75": 161.0, "iqr": 2.0, "p95": 161.0, "p99": 161.0,
            "ci_lower": 159.0, "ci_upper": 161.0, "failure_rate_pct": 0.0,
        }
        baseline["results"][0]["runs"] = [
            {"open_latency_ms": 100.0, "time_to_stable_layout_ms": 30.0},
            {"open_latency_ms": 101.0, "time_to_stable_layout_ms": 30.0},
            {"open_latency_ms": 102.0, "time_to_stable_layout_ms": 30.0},
        ]
        latest["results"][0]["runs"] = [
            {"open_latency_ms": 100.0, "time_to_stable_layout_ms": 160.0},
            {"open_latency_ms": 101.0, "time_to_stable_layout_ms": 160.0},
            {"open_latency_ms": 102.0, "time_to_stable_layout_ms": 160.0},
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            baseline_path = Path(tmpdir) / "baseline.json"
            latest_path = Path(tmpdir) / "latest.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            latest_path.write_text(json.dumps(latest), encoding="utf-8")

            proc = subprocess.run(
                ["python3", str(SCRIPT), "--baseline", str(baseline_path), "--latest", str(latest_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("time_to_stable_layout", proc.stdout)


if __name__ == "__main__":
    unittest.main()
