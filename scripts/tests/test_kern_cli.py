import os
import pathlib
import subprocess
import tempfile
import unittest


class KernCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = pathlib.Path(__file__).resolve().parents[2]
        cls.cli = cls.repo_root / "scripts" / "kern"
        if not cls.cli.exists():
            raise unittest.SkipTest("scripts/kern not found")

    def run_cli(self, *args):
        env = dict(os.environ)
        env.setdefault("LC_ALL", "C")
        return subprocess.run(
            [str(self.cli), *args],
            cwd=self.repo_root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_path_returns_absolute_path(self):
        fixture = self.repo_root / "test-fixtures" / "native-editor-benchmark.md"
        result = self.run_cli("path", str(fixture))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(fixture.resolve()))

    def test_search_finds_case_insensitive_matches(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = pathlib.Path(tmpdir)
            (root / "Notes.md").write_text("hi\n", encoding="utf-8")
            (root / "native-editor-benchmark.md").write_text("bench\n", encoding="utf-8")
            (root / "another.txt").write_text("x\n", encoding="utf-8")

            result = self.run_cli("search", "NATIVE-EDITOR", str(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
            self.assertEqual(len(lines), 1)
            self.assertTrue(lines[0].endswith("native-editor-benchmark.md"), lines[0])

    def test_unknown_command_returns_error(self):
        result = self.run_cli("does-not-exist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown command", result.stderr)


if __name__ == "__main__":
    unittest.main()
