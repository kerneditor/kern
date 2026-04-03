# Contributing to Kern

Kern is a native macOS Markdown editor built with AppKit + TextKit.

## Before you start

- Use macOS 14+.
- Use Xcode 16+.
- Install XcodeGen.

## Setup

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

Use this as the public contribution gate.

CI runs these baseline checks on pushes and pull requests:

```bash
./scripts/test-native-editor.sh --unit-only
./scripts/test-markdown-spec-conformance.sh
./scripts/run-typing-behavior-gate.sh --lane pr
cd scripts/kern-bench && swift test -c release
```

In addition to CI, make sure you ran the change-specific validation lanes below when they apply:

### Docs-only changes

- no app/test run required unless you changed commands or behavior claims

### General code changes

```bash
./scripts/test-native-editor.sh --unit-only
```

### Editing behavior changes

```bash
./scripts/run-typing-behavior-gate.sh --lane pr
```

### Markdown semantic changes

```bash
./scripts/test-markdown-spec-conformance.sh
```

### Rendering/layout changes

- run the relevant snapshot or focused visual validation before review

### Benchmark harness changes

```bash
cd scripts/kern-bench && swift test -c release
```

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
