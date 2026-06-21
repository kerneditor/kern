#!/usr/bin/env python3
"""Select or validate a compatible XCTest performance baseline log.

The native benchmark runner uses this helper to avoid false A/B confidence from
failed, synthetic, stale-lane, or fixture-incompatible benchmark artifacts.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

MEASURED_RE = re.compile(r"\bmeasured \[")
SYNTHETIC_RE = re.compile(r"\b(FAKE|STUB|SYNTHETIC)\b", re.IGNORECASE)


@dataclass(frozen=True)
class Manifest:
    path: Path
    values: dict[str, str]

    @property
    def quick(self) -> str | None:
        return self.values.get("quick")

    @property
    def include_mermaid(self) -> str | None:
        return self.values.get("include_mermaid")

    @property
    def fixture_hashes(self) -> dict[str, str]:
        raw = self.values.get("fixture_hashes", "")
        hashes: dict[str, str] = {}
        for line in raw.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            digest = parts[0]
            fixture = parts[-1]
            hashes[fixture] = digest
        return hashes

    @property
    def xcodebuild_version(self) -> str:
        return self.values.get("xcodebuild_version", "")

    @property
    def is_synthetic(self) -> bool:
        if self.values.get("synthetic", "").strip().lower() in {"1", "true", "yes"}:
            return True
        return bool(SYNTHETIC_RE.search(self.xcodebuild_version))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Select a compatible XCTest perf baseline log")
    parser.add_argument("--root", default="bench-results/native-editor", help="Root containing timestamped native perf runs")
    parser.add_argument("--candidate-log", default=None, help="Validate this explicit candidate instead of auto-selecting")
    parser.add_argument("--current-run-dir", required=True, help="Current run directory to exclude from auto-selection")
    parser.add_argument("--current-manifest", required=True, help="Manifest for the current run")
    parser.add_argument("--explain", action="store_true", help="Print skip reasons to stderr")
    return parser.parse_args()


def explain(enabled: bool, message: str) -> None:
    if enabled:
        print(message, file=sys.stderr)


def parse_manifest(path: Path) -> Manifest:
    values: dict[str, str] = {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if "<<EOF" in line:
            key = line.split("<<EOF", 1)[0]
            i += 1
            block: list[str] = []
            while i < len(lines) and lines[i] != "EOF":
                block.append(lines[i])
                i += 1
            values[key] = "\n".join(block)
        elif "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
        i += 1
    return Manifest(path=path, values=values)


def load_summary_metrics(run_dir: Path) -> tuple[bool, str]:
    summary_path = run_dir / "metrics-summary.json"
    if not summary_path.exists():
        return False, "missing metrics-summary.json"
    try:
        payload: dict[str, Any] = json.loads(summary_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return False, f"invalid metrics-summary.json: {exc}"
    metrics = payload.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        return False, "metrics-summary.json contains no metrics"
    return True, ""


def has_measured_metrics(log_path: Path) -> bool:
    try:
        text = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return bool(MEASURED_RE.search(text))


def compatible_fixture_hashes(current: Manifest, candidate: Manifest) -> tuple[bool, str]:
    current_hashes = current.fixture_hashes
    candidate_hashes = candidate.fixture_hashes
    if not current_hashes:
        return False, "current manifest has no fixture hashes"
    if not candidate_hashes:
        return False, "candidate manifest has no fixture hashes"
    mismatches: list[str] = []
    for fixture, digest in current_hashes.items():
        candidate_digest = candidate_hashes.get(fixture)
        if candidate_digest != digest:
            mismatches.append(fixture)
    if mismatches:
        preview = ", ".join(mismatches[:4])
        return False, f"fixture hash mismatch: {preview}"
    return True, ""


def validate_candidate(log_path: Path, current_run_dir: Path, current_manifest: Manifest) -> tuple[bool, str]:
    if not log_path.exists():
        return False, "perf.log does not exist"
    try:
        if log_path.resolve().is_relative_to(current_run_dir.resolve()):
            return False, "candidate is the current run"
    except OSError:
        pass

    run_dir = log_path.parent
    if (run_dir / "failure.txt").exists():
        return False, "candidate run has failure.txt"
    if not has_measured_metrics(log_path):
        return False, "perf.log has no XCTest measured metrics"

    manifest_path = run_dir / "run-manifest.txt"
    if not manifest_path.exists():
        return False, "missing run-manifest.txt"
    candidate_manifest = parse_manifest(manifest_path)
    if candidate_manifest.is_synthetic:
        return False, "candidate manifest appears synthetic or fake"

    if current_manifest.quick != candidate_manifest.quick:
        return False, f"quick lane mismatch: current={current_manifest.quick!r} candidate={candidate_manifest.quick!r}"
    if current_manifest.include_mermaid != candidate_manifest.include_mermaid:
        return False, (
            "include_mermaid lane mismatch: "
            f"current={current_manifest.include_mermaid!r} candidate={candidate_manifest.include_mermaid!r}"
        )

    fixtures_ok, fixture_reason = compatible_fixture_hashes(current_manifest, candidate_manifest)
    if not fixtures_ok:
        return False, fixture_reason

    summary_ok, summary_reason = load_summary_metrics(run_dir)
    if not summary_ok:
        return False, summary_reason

    return True, ""


def candidate_logs(args: argparse.Namespace) -> list[Path]:
    if args.candidate_log:
        return [Path(args.candidate_log)]
    root = Path(args.root)
    if not root.exists():
        return []
    return sorted(root.glob("*/perf.log"), key=lambda item: str(item), reverse=True)


def main() -> int:
    args = parse_args()
    current_manifest_path = Path(args.current_manifest)
    if not current_manifest_path.exists():
        print(f"error: current manifest not found: {current_manifest_path}", file=sys.stderr)
        return 2

    current_manifest = parse_manifest(current_manifest_path)
    current_run_dir = Path(args.current_run_dir)

    for log_path in candidate_logs(args):
        ok, reason = validate_candidate(log_path, current_run_dir, current_manifest)
        if ok:
            print(str(log_path))
            return 0
        explain(args.explain, f"skip {log_path}: {reason}")

    if args.candidate_log:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
