# AGENTS.md (Kern)

This repository is **Kern**: a fully native macOS WYSIWYG Markdown editor (Swift + AppKit + TextKit, **no WebView**).

## Canonical Test Suite Plan

Read and follow:

- `docs/plans/native-editor-test-suite.md`
- `docs/plans/native-editor-missing-features-implementation-plan.md`
- `docs/plans/markdown-spec-failure-tracker.md`

This plan is the source of truth for what “exhaustive” means. If tests are green but the app is missing features, the plan requires adding tests that fail until the feature is implemented.

## Where To Work

- Work only in this repository checkout.
- Do not modify the legacy WebKit repo unless explicitly requested.
- If a compatibility symlink exists in your local environment, treat this repository as the source of truth.

## Core Commands

Build + run (opens a file):

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

Tests:

```bash
# Unit tests (the only test mode — XCUI target was removed)
./scripts/test-native-editor.sh

# Exhaustive (expected to fail until full-spec features are implemented)
./scripts/test-native-editor.sh --exhaustive

# Strict official CommonMark/GFM conformance (Kern extensions disabled)
./scripts/test-markdown-spec-conformance.sh

# Pixel-level snapshots
./scripts/test-native-editor.sh --snapshots --exhaustive
```

## Testing Philosophy

- Prefer **unit + snapshot** tests for broad coverage and speed.
- Prefer **generator-backed matrices** (preferences, fixtures, edge cases) over hand-written repetition.
- Always attach artifacts that an agent can use to self-repair: screenshots, snapshot diffs, markdown outputs, and minimal diffs.

## Build Discipline

- After **every code change**, always rebuild the app before handing work back for review so the user does not need to rebuild manually.
