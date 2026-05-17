# Markdown Spec Failure Tracker (Strict CommonMark/GFM)

This file tracks strict Markdown spec conformance gaps for the native TextKit engine.

Scope:
- Strict profile only (no Kern extensions): `orderedTasksEnabled=false`, `headingCheckboxesEnabled=false`.
- Sources:
  - CommonMark: `commonmark-0.31.2.json`
  - GFM: `gfm-0.29.0.gfm.13.json`

## Latest Run

- Timestamp: `2026-05-17 23:19 KST`
- Command:
  - `./scripts/test-markdown-spec-conformance.sh`
- Result bundle:
  - `test-results/native-editor/20260517-231911/spec-conformance/KernMarkdownSpecConformance.xcresult`
- Release evidence:
  - `docs/release/v0.1.2-validation-evidence.md`

## Current Score

| Mode | Passed | Total | Failed | Pass Rate |
|---|---:|---:|---:|---:|
| CommonMark | 652 | 652 | 0 | 100.00% |
| GFM | 670 | 670 | 0 | 100.00% |

## Status

All strict conformance sections are currently `done` (no mismatches in this run).

## Historical Baseline (for context)

Previous failure baseline:
- Timestamp: `2026-02-16 20:45:38`
- Path: `test-results/native-editor/20260216-204538/spec-conformance`

Previous score:
- CommonMark: `491 / 652` (161 failed)
- GFM: `508 / 670` (162 failed)

## Tracking Workflow

1. Run strict conformance:
   - `./scripts/test-markdown-spec-conformance.sh`
2. If failures appear, update this file with:
   - failing sections,
   - fail counts by mode,
   - representative examples and artifact paths.
3. Keep Kern-extension behavior tracked separately in option/profile tests (never counted as strict conformance).

## Separate Typing Behavior Gate (Non-Spec)

Typing behavior exhaustiveness is tracked separately from strict CommonMark/GFM conformance.

- Gate script:
  - `./scripts/run-typing-behavior-gate.sh --lane pr`
  - `./scripts/run-typing-behavior-gate.sh --lane nightly`
- Latest release-gate evidence (2026-05-17):
  - `test-results/typing-behavior/20260517-231923-pr/summary.txt`
- Latest historical nightly evidence (2026-03-04):
  - `test-results/typing-behavior/20260304-003815-nightly/summary.txt`
