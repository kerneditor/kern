#!/usr/bin/env python3
"""Fail if a `status: complete` todo file still has unchecked checklist entries."""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TODOS = ROOT / "todos"

if not TODOS.exists():
    print("[todo-check] no todos/ directory found; skipping")
    sys.exit(0)

violations: list[tuple[str, int, str]] = []
for path in sorted(TODOS.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    if not re.search(r"(?m)^status:\s*complete\s*$", text):
        continue
    for idx, line in enumerate(text.splitlines(), start=1):
        if line.startswith("- [ ]"):
            violations.append((path.name, idx, line.strip()))

if not violations:
    print("[todo-check] complete todo checklist hygiene: OK")
    sys.exit(0)

print("[todo-check] complete todo checklist hygiene: FAILED")
for name, line_no, line in violations:
    print(f"  - {name}:{line_no}: {line}")
sys.exit(1)
