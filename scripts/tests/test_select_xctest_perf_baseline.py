import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "select-xctest-perf-baseline.py"


MEASURED_LOG = """
Test Case '-[KernTextKitTests.NativeEditorMegaStressPerformanceTests testTypingMegaStressCharacterByCharacterPerformance]' measured [Clock Monotonic Time, s] average: 1.000, relative standard deviation: 2.000%, values: [1.000, 1.100], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
"""


class SelectXCTestPerfBaselineTests(unittest.TestCase):
    def run_selector(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), *args],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def write_manifest(
        self,
        run_dir: Path,
        *,
        quick: str = "false",
        include_mermaid: str = "false",
        fixture_hash: str = "abc123",
        fake_xcode: bool = False,
    ) -> None:
        xcode_version = "Xcode 17.0\nBuild version FAKE" if fake_xcode else "Xcode 17.0\nBuild version 17A000"
        (run_dir / "run-manifest.txt").write_text(
            f"""timestamp={run_dir.name}
quick={quick}
include_mermaid={include_mermaid}
xcodebuild_version<<EOF
{xcode_version}
EOF
fixture_hashes<<EOF
{fixture_hash}  test-fixtures/native-editor-benchmark.md
EOF
""",
            encoding="utf-8",
        )

    def write_run(
        self,
        root: Path,
        name: str,
        *,
        measured: bool = True,
        failure: bool = False,
        metrics_summary: bool = True,
        quick: str = "false",
        include_mermaid: str = "false",
        fixture_hash: str = "abc123",
        fake_xcode: bool = False,
    ) -> Path:
        run_dir = root / name
        run_dir.mkdir(parents=True)
        (run_dir / "perf.log").write_text(MEASURED_LOG if measured else "no metrics\n", encoding="utf-8")
        self.write_manifest(
            run_dir,
            quick=quick,
            include_mermaid=include_mermaid,
            fixture_hash=fixture_hash,
            fake_xcode=fake_xcode,
        )
        if metrics_summary:
            (run_dir / "metrics-summary.json").write_text('{"metrics":[{"ok":true}]}\n', encoding="utf-8")
        if failure:
            (run_dir / "failure.txt").write_text("status=failed\n", encoding="utf-8")
        return run_dir

    def test_auto_selects_newest_compatible_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            current = root / "20260620-010000"
            current.mkdir()
            self.write_manifest(current)
            old = self.write_run(root, "20260619-010000")
            newest = self.write_run(root, "20260619-020000")

            proc = self.run_selector(
                "--root",
                str(root),
                "--current-run-dir",
                str(current),
                "--current-manifest",
                str(current / "run-manifest.txt"),
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(Path(proc.stdout.strip()), newest / "perf.log")
            self.assertNotEqual(Path(proc.stdout.strip()), old / "perf.log")

    def test_rejects_fake_failed_unmeasured_and_incompatible_candidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            current = root / "20260620-010000"
            current.mkdir()
            self.write_manifest(current)
            self.write_run(root, "20260619-060000", fake_xcode=True)
            self.write_run(root, "20260619-050000", failure=True)
            self.write_run(root, "20260619-040000", measured=False)
            self.write_run(root, "20260619-030000", quick="true")
            self.write_run(root, "20260619-020000", fixture_hash="different")
            valid = self.write_run(root, "20260619-010000")

            proc = self.run_selector(
                "--root",
                str(root),
                "--current-run-dir",
                str(current),
                "--current-manifest",
                str(current / "run-manifest.txt"),
                "--explain",
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(Path(proc.stdout.strip()), valid / "perf.log")
            self.assertIn("synthetic or fake", proc.stderr)
            self.assertIn("failure.txt", proc.stderr)
            self.assertIn("no XCTest measured metrics", proc.stderr)
            self.assertIn("quick lane mismatch", proc.stderr)
            self.assertIn("fixture hash mismatch", proc.stderr)

    def test_explicit_incompatible_candidate_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            current = root / "20260620-010000"
            current.mkdir()
            self.write_manifest(current)
            fake = self.write_run(root, "20260619-010000", fake_xcode=True)

            proc = self.run_selector(
                "--candidate-log",
                str(fake / "perf.log"),
                "--current-run-dir",
                str(current),
                "--current-manifest",
                str(current / "run-manifest.txt"),
                "--explain",
            )

            self.assertEqual(proc.returncode, 1)
            self.assertEqual(proc.stdout.strip(), "")
            self.assertIn("synthetic or fake", proc.stderr)

    def test_returns_empty_success_when_no_auto_candidate_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            current = root / "20260620-010000"
            current.mkdir()
            self.write_manifest(current)

            proc = self.run_selector(
                "--root",
                str(root),
                "--current-run-dir",
                str(current),
                "--current-manifest",
                str(current / "run-manifest.txt"),
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
