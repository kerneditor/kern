# Dependency policy

This document is the public dependency inventory and update policy for Kern.

## Summary

Kern's shipped macOS app target is intentionally small:

- no Electron or Tauri shell
- no WebView or browser runtime
- no npm or Node runtime dependency in the shipped app
- no third-party Swift package linked into the app target
- Swift, AppKit, TextKit, and Apple platform frameworks for the editor implementation

The current third-party dependency surface is test and tooling oriented.

## Direct dependencies

| Area | Dependency | Current policy | Where it is declared |
|---|---|---|---|
| App runtime | Apple SDK frameworks via Xcode | Provided by the selected Xcode/macOS SDK. Do not vendor. | `project.yml`, `KernApp/` |
| Snapshot tests | Point-Free SnapshotTesting | Exact direct version pin. Update only with snapshot test validation. | `project.yml` |
| Strict Markdown oracle | `cmarkgfm` plus transitive Python packages | Exact Python requirement pins for reproducible CommonMark/GFM semantic checks. | `spec-requirements.txt` |
| Benchmark CLI | Apple frameworks: ScreenCaptureKit, CoreGraphics, CoreMedia, ApplicationServices | System frameworks only; no external Swift packages. | `scripts/kern-bench/Package.swift` |
| CI action | `actions/checkout` | Major-version Dependabot updates. | `.github/workflows/ci.yml` |
| Project generation | XcodeGen | Minimum version enforced by `project.yml`; CI installs from Homebrew when missing. | `project.yml`, `.github/workflows/ci.yml` |
| Release upload/verification | GitHub CLI | Maintainer-only release tool. Not required for normal contributors. | `docs/release/github-release-checklist.md`, `scripts/verify-github-release-asset.sh` |

## Swift package policy

`project.yml` is the source of truth for XcodeGen-generated project structure.

`KernTextKit.xcodeproj/` is generated and intentionally ignored, so Xcode's generated `Package.resolved` inside that bundle is not tracked. The direct SnapshotTesting dependency is therefore pinned in `project.yml` with an exact version. If SwiftPM reproducibility becomes a release blocker, prefer one of these explicit changes instead of quietly committing generated project output:

1. keep the generated project ignored and pin direct package versions in `project.yml`, or
2. introduce a dedicated tracked Swift package/test manifest with a tracked lockfile, or
3. deliberately unignore and track the generated Xcode SwiftPM resolution file with a documented maintenance rule.

Do not commit the whole generated Xcode project just to preserve package resolution.

## Python oracle policy

Strict CommonMark/GFM conformance tests use `scripts/spec_oracle_render.py`, which imports `cmarkgfm`.

The required Python parser stack is pinned in `spec-requirements.txt`. Test scripts install that file into the local `.venv-spec/` environment and reinstall it when any pinned package drifts.

When Dependabot proposes a Python oracle dependency bump:

1. run `./scripts/test-markdown-spec-conformance.sh`
2. update `docs/plans/markdown-spec-failure-tracker.md` with the latest run evidence if behavior changed or if the release gate depends on the run
3. do not merge the bump if semantic output changes without a deliberate tracker update

## Tooling policy

Required contributor tools are:

- macOS 14+
- Xcode 26.2+
- XcodeGen 2.45+
- Python 3 with `venv` and `pip` for strict spec checks

Release maintainers additionally need:

- GitHub CLI for release asset upload/download verification
- `hdiutil`, `spctl`, and `shasum` from macOS command-line tools

## Update workflow

For dependency updates:

1. update the manifest or requirement file
2. regenerate the Xcode project with `xcodegen`
3. run the contributor baseline from `docs/release/release-validation-gate.md`
4. run any dependency-specific lane listed above
5. update this document if the dependency surface or policy changed

## What does not belong in the repo

Do not commit:

- generated Xcode projects or DerivedData
- local Python virtualenvs
- benchmark outputs
- packaged app artifacts, DMGs, archives, dSYMs, or xcresult bundles
- local Forge/session/handoff files
- maintainer-private research scratch files
