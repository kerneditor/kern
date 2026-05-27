# Contributing to Kern

Kern is a fully native macOS WYSIWYG Markdown editor built with Swift, AppKit, and TextKit. It does not use Electron, Tauri, or a WebView.

If you want end-user install instructions instead of contributor setup, use [Installing Kern from a GitHub release](docs/release/installing-kern-from-github-release.md).

## Before you start

- Use macOS 14+.
- Use Xcode 26.2+.
- Install XcodeGen 2.45+.
- Use Python 3 with `venv`/`pip` for strict Markdown spec validation.
- CI is pinned to Xcode 26.x because the GitHub Actions default Xcode can lag behind the toolchain this repo currently requires.

## Setup

This document is only for source contributors. For full source-build instructions, see [Building Kern from source](docs/release/building-kern-from-source.md).

For support paths beyond contribution workflow questions, see [SUPPORT.md](SUPPORT.md).

```bash
xcodegen
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -configuration Debug -destination 'platform=macOS' build
```

Run the app against a fixture:

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

## Change scope

- For larger behavior or architecture changes, open an issue first.
- Keep changes aligned with the native test-suite plans under `docs/plans/`.
- Expand tests in the same PR when behavior changes.

## Required validation

Use [Kern release validation gate](docs/release/release-validation-gate.md) as the canonical public gate definition.

CI runs these baseline checks on pushes and pull requests:

```bash
./scripts/test-native-editor.sh --no-snapshots
./scripts/test-markdown-spec-conformance.sh
./scripts/run-typing-behavior-gate.sh --lane pr
cd scripts/kern-bench && swift test -c release
```

Release packaging and GitHub asset verification are maintainer release checks, not part of the contributor PR baseline. Those steps live in [GitHub release checklist](docs/release/github-release-checklist.md) and are summarized in [Kern release validation gate](docs/release/release-validation-gate.md).

In addition to CI, make sure you ran the change-specific validation lanes below when they apply:

### Docs-only changes

- no app/test run required unless you changed commands or behavior claims

### General code changes

Fast non-snapshot lane:

```bash
./scripts/test-native-editor.sh --no-snapshots
```

Default unit + snapshot lane when rendering or snapshots may be affected:

```bash
./scripts/test-native-editor.sh
```

### Editing behavior changes

```bash
./scripts/run-typing-behavior-gate.sh --lane pr
```

### Markdown semantic changes

```bash
./scripts/test-markdown-spec-conformance.sh
```

This lane installs the pinned Python oracle stack from `spec-requirements.txt` into `.venv-spec/`.

### Rendering/layout changes

- run the relevant snapshot or focused visual validation before review

### Benchmark harness changes

```bash
cd scripts/kern-bench && swift test -c release
```

Dependency update policy is documented in [Dependency policy](docs/dependencies.md).

## Pull requests

Include:

- a concise summary of the change
- the test commands you ran
- relevant artifacts for behavior changes when useful
  - snapshot diffs
  - benchmark results
  - strict spec output
  - screenshots

Keep PRs narrow. Small changes are easier to verify and less likely to regress editor behavior.

For general support and issue-routing guidance, see [SUPPORT.md](SUPPORT.md).
