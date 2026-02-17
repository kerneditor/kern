# Kern

Kern is a native macOS WYSIWYG Markdown editor. You open a local `.md` file and edit rendered content directly, without living in raw markdown syntax.

This repository is the native TextKit implementation (`Kern-textkit`), now the primary Kern codebase.

## Why Kern Exists

Most local markdown workflows break down in one of these ways:

- You get a preview pane, but editing still happens in raw syntax.
- You get a rich editor, but it wants a project/workspace model instead of opening plain files.
- You get a web stack wrapped in desktop chrome, with bridge and runtime edge cases.

Kern is built for a simpler workflow: open any local markdown file, edit in true WYSIWYG, save back to deterministic markdown.

## Why This Rewrite Happened

The first Kern implementation (`Kern-webkit`) used WKWebView + Milkdown and proved the workflow. It also inherited web-runtime complexity: a Swift<->JavaScript bridge, split debugging surface, and integration overhead.

This repo rewrites the editor in AppKit + TextKit (no WebView) to keep the editing path native, reduce moving parts, and make behavior easier to test at unit/snapshot depth.

## What Kern Does Today

- True WYSIWYG as the default editing mode.
- GFM-first markdown behavior, with optional Kern extensions.
- Deterministic import/export via native markdown codec.
- Checkboxes in multiple forms (standalone, bulleted tasks, ordered tasks, heading tasks).
- Native code block chrome (language pill + copy affordance).
- Native rendering paths for images, Mermaid, and math.
- File watching, autosave, and standard macOS window/tab behavior.

## Quick Start (Installed App)

Open a markdown file in Kern:

```bash
open -a Kern /absolute/path/to/file.md
```

Optional shell helper:

```bash
kern() { open -a Kern "$@"; }
```

## Build And Run From Source

Requirements:

- macOS 14+
- Xcode 16+
- XcodeGen (`brew install xcodegen`)

Build:

```bash
xcodegen
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -configuration Debug -destination 'platform=macOS' build
```

Build + run with fixture:

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

## Test Commands

Fast unit tests:

```bash
./scripts/test-native-editor.sh --unit-only
```

Full default suite (unit + UI):

```bash
./scripts/test-native-editor.sh
```

Exhaustive lanes:

```bash
./scripts/test-native-editor.sh --unit-only --exhaustive
./scripts/test-native-editor.sh --unit-only --snapshots --exhaustive
./scripts/test-native-editor.sh --ui-only --exhaustive
```

Strict markdown spec conformance (CommonMark/GFM lane):

```bash
./scripts/test-markdown-spec-conformance.sh
```

Orchestrated exhaustive gate:

```bash
./scripts/run-exhaustive-native-suite.sh
```

Notes:

- UI tests require an unlocked screen and Automation/Accessibility permissions.
- Exhaustive lanes are intentionally strict and slower.

## Documentation Map

- docs/plans/native-editor-test-suite.md
- docs/plans/markdown-spec-failure-tracker.md
- docs/plans/native-editor-missing-features-implementation-plan.md
- NATIVE-EDITOR-TEST-MATRIX.md
- KERN-MARKDOWN.md

## Current Focus Areas

- Task permutation and GFM/Kern profile behavior
- Ordered task numbering semantics
- Heading checkbox behavior
- Code block chrome interactions
- Image attachment edge cases
- Mermaid and math layout quality
- Anchor navigation behavior
- Find/replace overlay non-obstruction
- Exhaustive real-typing behavior

## Contributing

If you want to contribute:

1. Open an issue first for larger behavior or architecture changes.
2. Keep changes aligned with the native test-suite plan documents.
3. Run at least `./scripts/test-native-editor.sh --unit-only` before opening a PR.

For review requests, include failing/passing test evidence and any snapshot or UI artifacts that explain behavior changes.

## Status

- As of 2026-02-17, this TextKit repo is the primary Kern app.
- The older WKWebView implementation is preserved separately as a legacy archive.
- This repository is currently private and does not yet declare an open-source license.
