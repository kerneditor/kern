# AGENTS.md (KernTextKit)

This repository is **KernTextKit**: a fully native macOS WYSIWYG Markdown editor (Swift + AppKit + TextKit, **no WebView**).

## Canonical Test Suite Plan

Read and follow:

- `docs/plans/native-editor-test-suite.md`

This plan is the source of truth for what “exhaustive” means. If tests are green but the app is missing features, the plan requires adding tests that fail until the feature is implemented.

## Where To Work

- Work only in this repo: `/Users/aaaaa/Projects/Kern-textkit`
- Do not modify the legacy repo at `/Users/aaaaa/Projects/Kern` unless explicitly requested.

## Core Commands

Build + run (opens a file):

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

Tests:

```bash
# Fast (unit only)
./scripts/test-native-editor.sh --unit-only

# Full (unit + UI; UI requires unlocked screen + Automation permissions)
./scripts/test-native-editor.sh

# Exhaustive (expected to fail until full-spec features are implemented)
./scripts/test-native-editor.sh --exhaustive

# Pixel-level snapshots
./scripts/test-native-editor.sh --unit-only --snapshots --exhaustive
```

## Testing Philosophy

- Prefer **unit + snapshot** tests for broad coverage and speed.
- Use **UI tests** only for interaction behaviors that can’t be validated otherwise.
- Prefer **generator-backed matrices** (preferences, fixtures, edge cases) over hand-written repetition.
- Always attach artifacts that an agent can use to self-repair: screenshots, snapshot diffs, markdown outputs, and minimal diffs.

