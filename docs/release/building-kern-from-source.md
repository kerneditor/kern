# Building Kern from source

Use this path if you do not want to run a GitHub release binary or if you want to modify Kern locally.

If you just want to install a tagged binary release, use [Installing Kern from a GitHub release](installing-kern-from-github-release.md).

## Requirements

- macOS 14+
- Xcode 26.2+
- XcodeGen

Install XcodeGen if needed:

```bash
brew install xcodegen
```

CI is pinned to Xcode 26.x because the default GitHub Actions Xcode can lag behind the toolchain this repository currently requires.

## Generate the project and build

```bash
xcodegen
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -configuration Debug -destination 'platform=macOS' build
```

## Run Kern against a fixture

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

## Package a local development DMG

```bash
./scripts/package-kern-app.sh
```

Expected outputs:

- `dist/Kern.app`
- `dist/Kern-macOS-Release.dmg`
- `dist/Kern-macOS-Release.dmg.sha256`

The packager regenerates `KernTextKit.xcodeproj` with XcodeGen before building, so you do not need to run `xcodegen` separately just for the packaging step.

These artifacts are still unsigned and not notarized.

## Baseline validation

At minimum, run:

```bash
./scripts/test-native-editor.sh --unit-only
```

When markdown semantics changed, also run:

```bash
./scripts/test-markdown-spec-conformance.sh
```

When typing/editing behavior changed, also run:

```bash
./scripts/run-typing-behavior-gate.sh --lane pr
```

For the benchmark harness package:

```bash
cd scripts/kern-bench && swift test -c release
```
