# AGENTS.md (Kern)

This repository is **Kern**: a fully native macOS WYSIWYG Markdown editor (Swift + AppKit + TextKit, **no WebView**).

The source project is still named `KernTextKit` in XcodeGen/project metadata, but the public product and app name are **Kern**.

## Canonical Test Suite Plan

Read and follow:

- `docs/plans/native-editor-test-suite.md`
- `docs/plans/native-editor-missing-features-implementation-plan.md`
- `docs/plans/markdown-spec-failure-tracker.md`

This plan is the source of truth for what “exhaustive” means. Exhaustive gates should be treated as active regression gates. If future work exposes an unsupported feature gap, add the failing test and implement the behavior in the same change before calling the work complete.

## Where To Work

- Work only in this repository checkout.
- Do not modify sibling or legacy repositories unless explicitly requested.
- If a compatibility symlink exists in your local environment, treat this repository as the source of truth.
- Maintainer-local operational docs may exist under `docs/internal/` in local maintainer worktrees; tracked root bootstrap files are public-safe stubs.

## Core Commands

Build + run (opens a file):

```bash
./scripts/run-kern-native.sh test-fixtures/stress-test.md
```

Tests:

```bash
# Default unit + snapshot suite
./scripts/test-native-editor.sh

# Fast non-snapshot local lane
./scripts/test-native-editor.sh --no-snapshots

# Exhaustive native unit/snapshot lanes
./scripts/test-native-editor.sh --exhaustive
./scripts/test-native-editor.sh --snapshots --exhaustive

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
  - `./scripts/test-markdown-spec-conformance.sh` when markdown semantics are touched
- If attachment/image rendering changes, also run snapshot re-record + verification before final full-suite validation because async host-view binding can affect layout timing.

## Dependency Discipline

- Dependency policy lives in `docs/dependencies.md`.
- Do not commit generated dependency/runtime state such as virtualenvs, Xcode generated projects, DerivedData, package build directories, release artifacts, or xcresult bundles.
- For Markdown oracle dependency updates, update `spec-requirements.txt` and run `./scripts/test-markdown-spec-conformance.sh`.

## Build Discipline

- After **every code change**, always rebuild the app and, when relevant, reinstall/update the Kern app bundle before handing work back so the user does not need to rebuild or reinstall manually.
