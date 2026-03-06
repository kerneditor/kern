# AGENTS.md (KernTextKit)

This repository is **KernTextKit**: a fully native macOS WYSIWYG Markdown editor (Swift + AppKit + TextKit, **no WebView**).

## Canonical Test Suite Plan

Read and follow:

- `docs/plans/native-editor-test-suite.md`
- `docs/plans/native-editor-missing-features-implementation-plan.md`
- `docs/plans/markdown-spec-failure-tracker.md`

This plan is the source of truth for what “exhaustive” means. If tests are green but the app is missing features, the plan requires adding tests that fail until the feature is implemented.

## Where To Work

- Work only in this repo: `/Users/aaaaa/Projects/Kern-textkit`
- Do not modify the legacy repo at `/Users/aaaaa/Projects/Kern-webkit` unless explicitly requested.
  - Compatibility symlink currently exists at `/Users/aaaaa/Projects/Kern -> /Users/aaaaa/Projects/Kern-textkit`.

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

# Editing-UX regression gate
./scripts/run-typing-behavior-gate.sh --lane pr

# Pixel-level snapshots
./scripts/test-native-editor.sh --snapshots --exhaustive
```

## Testing Philosophy

- Prefer **unit + snapshot** tests for broad coverage and speed.
- Prefer **generator-backed matrices** (preferences, fixtures, edge cases) over hand-written repetition.
- Always attach artifacts that an agent can use to self-repair: screenshots, snapshot diffs, markdown outputs, and minimal diffs.
- For every new feature/behavior change, **expand tests in the same PR** (do not rely on existing coverage alone).
- Any editing UX change must include **typing-behavior expansion** (matrix/program/reliability or targeted regressions) and run:
  - `./scripts/run-typing-behavior-gate.sh --lane pr`
  - `./scripts/test-markdown-spec-conformance.sh` (when markdown semantics are touched)
- If attachment/image rendering changes, also run snapshot re-record + verification before final full-suite validation because async host-view binding can affect layout timing.

## Build Discipline

- After **every code change**, always rebuild the app and, when relevant, reinstall/update the Kern app bundle before handing work back so the user does not need to rebuild or reinstall manually.
