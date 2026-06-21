import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "xctest-perf-report.py"


def sample_log(
    clock_average: float = 1.0,
    memory_average_kb: float = 2048.0,
    *,
    include_clock: bool = True,
    include_memory: bool = True,
) -> str:
    lines = []
    if include_memory:
        lines.append(
            f"""
/Repo/KernTests/Foo.swift:10: Test Case '-[KernTextKitTests.NativeEditorMegaStressPerformanceTests testTypingMegaStressCharacterByCharacterPerformance]' measured [Memory Peak Physical, kB] average: {memory_average_kb:.3f}, relative standard deviation: 1.000%, values: [{memory_average_kb:.3f}, {memory_average_kb:.3f}], performanceMetricID:com.apple.dt.XCTMetric_Memory.physical_peak, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
"""
        )
    if include_clock:
        lines.append(
            f"""
/Repo/KernTests/Foo.swift:10: Test Case '-[KernTextKitTests.NativeEditorMegaStressPerformanceTests testTypingMegaStressCharacterByCharacterPerformance]' measured [Clock Monotonic Time, s] average: {clock_average:.3f}, relative standard deviation: 2.000%, values: [{clock_average:.3f}, {clock_average + 0.1:.3f}], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
"""
        )
    lines.append(
        """
Test Case '-[KernTextKitTests.NativeEditorMegaStressPerformanceTests testTypingMegaStressCharacterByCharacterPerformance]' passed (1.234 seconds).
"""
    )
    return "".join(lines)


class XCTestPerfReportTests(unittest.TestCase):
    def run_report(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), *args],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_parses_xctest_performance_log_to_json_and_markdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "perf.log"
            out_json = root / "summary.json"
            out_md = root / "summary.md"
            log.write_text(sample_log(clock_average=1.5, memory_average_kb=4096), encoding="utf-8")

            proc = self.run_report(
                "--log",
                str(log),
                "--out-json",
                str(out_json),
                "--out-md",
                str(out_md),
                "--label",
                "test run",
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            payload = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(payload["suite_kind"], "xctest_native_performance")
            self.assertEqual(len(payload["metrics"]), 2)
            clock = next(m for m in payload["metrics"] if m["metric"] == "Clock Monotonic Time")
            self.assertEqual(clock["average_ms"], 1500.0)
            memory = next(m for m in payload["metrics"] if m["metric"] == "Memory Peak Physical")
            self.assertEqual(memory["average_mb"], 4.0)
            self.assertIn("# test run", out_md.read_text(encoding="utf-8"))

    def test_detects_regression_against_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / "baseline.log"
            latest = root / "latest.log"
            out_json = root / "summary.json"
            out_md = root / "summary.md"
            baseline.write_text(sample_log(clock_average=1.0, memory_average_kb=2048), encoding="utf-8")
            latest.write_text(sample_log(clock_average=2.0, memory_average_kb=4096), encoding="utf-8")

            proc = self.run_report(
                "--log",
                str(latest),
                "--baseline-log",
                str(baseline),
                "--out-json",
                str(out_json),
                "--out-md",
                str(out_md),
                "--fail-on-regression",
                "--max-time-regression-pct",
                "10",
                "--max-memory-regression-pct",
                "10",
                "--min-time-regression-s",
                "0.01",
                "--min-memory-regression-mb",
                "0.1",
            )

            self.assertNotEqual(proc.returncode, 0)
            payload = json.loads(out_json.read_text(encoding="utf-8"))
            regressions = [c for c in payload["comparisons"] if c["regression"]]
            self.assertEqual(len(regressions), 2)

    def test_allows_small_absolute_deltas_below_minimum(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / "baseline.log"
            latest = root / "latest.log"
            out_json = root / "summary.json"
            out_md = root / "summary.md"
            baseline.write_text(sample_log(clock_average=1.0, memory_average_kb=2048), encoding="utf-8")
            latest.write_text(sample_log(clock_average=1.01, memory_average_kb=2050), encoding="utf-8")

            proc = self.run_report(
                "--log",
                str(latest),
                "--baseline-log",
                str(baseline),
                "--out-json",
                str(out_json),
                "--out-md",
                str(out_md),
                "--fail-on-regression",
                "--max-time-regression-pct",
                "0.1",
                "--max-memory-regression-pct",
                "0.1",
                "--min-time-regression-s",
                "0.02",
                "--min-memory-regression-mb",
                "1.0",
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_fail_on_regression_rejects_missing_candidate_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / "baseline.log"
            latest = root / "latest.log"
            out_json = root / "summary.json"
            out_md = root / "summary.md"
            baseline.write_text(sample_log(clock_average=1.0, memory_average_kb=2048), encoding="utf-8")
            latest.write_text(
                sample_log(clock_average=1.0, memory_average_kb=2048, include_memory=False),
                encoding="utf-8",
            )

            proc = self.run_report(
                "--log",
                str(latest),
                "--baseline-log",
                str(baseline),
                "--out-json",
                str(out_json),
                "--out-md",
                str(out_md),
                "--fail-on-regression",
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Baseline metrics were missing", proc.stderr)
            payload = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(len(payload["comparisons"]), 1)
            self.assertEqual(len(payload["missing_baseline_metrics"]), 1)
            self.assertEqual(
                payload["missing_baseline_metrics"][0]["metric_id"],
                "com.apple.dt.XCTMetric_Memory.physical_peak",
            )

    def test_missing_candidate_metrics_are_reported_without_strict_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / "baseline.log"
            latest = root / "latest.log"
            out_json = root / "summary.json"
            out_md = root / "summary.md"
            baseline.write_text(sample_log(clock_average=1.0, memory_average_kb=2048), encoding="utf-8")
            latest.write_text(
                sample_log(clock_average=1.0, memory_average_kb=2048, include_memory=False),
                encoding="utf-8",
            )

            proc = self.run_report(
                "--log",
                str(latest),
                "--baseline-log",
                str(baseline),
                "--out-json",
                str(out_json),
                "--out-md",
                str(out_md),
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            payload = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(len(payload["missing_baseline_metrics"]), 1)
            self.assertIn("Missing baseline metrics", out_md.read_text(encoding="utf-8"))

    def test_rejects_logs_without_performance_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "perf.log"
            out_json = root / "summary.json"
            out_md = root / "summary.md"
            log.write_text("Test Suite started\nTest Suite passed\n", encoding="utf-8")

            proc = self.run_report(
                "--log",
                str(log),
                "--out-json",
                str(out_json),
                "--out-md",
                str(out_md),
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no XCTest performance metrics", proc.stderr)
            self.assertFalse(out_json.exists())


if __name__ == "__main__":
    unittest.main()
