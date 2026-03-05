---
status: complete
priority: p2
issue_id: "916"
tags: [testing, snapshots, ci, quality]
dependencies: []
---

# Enable always-on snapshot regression gate

## Problem Statement

Snapshot tests exist but are currently opt-in via environment flags. This leaves room for visual regressions to pass default CI/test runs.

## Findings

- `TODO.md` retained this as open after revalidation.
- Current suite includes snapshot tests and baseline artifacts, but they are gated behind `KERN_ENABLE_SNAPSHOT_TESTS=1`.

## Proposed Solutions

### Option 1: Add required snapshot lane in CI + local default gate mode (preferred)

**Approach:** Make snapshot verification mandatory in at least one default quality lane and wire it into standard pre-merge execution.

**Pros:**
- Catches visual regressions earlier.
- Improves trust in UI consistency.

**Cons:**
- Longer CI runtime.
- Snapshot churn management needed.

**Effort:** Medium

**Risk:** Low-Medium

---

### Option 2: Keep opt-in locally, enforce only on release branch

**Approach:** Preserve fast local defaults but require snapshot gate for release/hardening branches.

**Pros:**
- Lower day-to-day friction.

**Cons:**
- Regressions may survive longer before detection.

**Effort:** Small-Medium

**Risk:** Medium

## Recommended Action

## Technical Details

**Likely affected files:**
- `scripts/test-native-editor.sh`
- CI workflow definitions (if present)
- `KernTests/NativeEditorSnapshotTests.swift`

## Resources

- `TODO.md`
- `docs/reports/2026-03-06-todo-portfolio-revalidation.md`

## Acceptance Criteria

- [x] Snapshot verification runs in a required quality lane.
- [x] Baseline update flow is documented.
- [x] Visual regressions fail the required lane.
- [x] No false-positive churn beyond agreed tolerance.

## Work Log

### 2026-03-06 - Created from revalidation

**By:** Codex

**Actions:**
- Converted remaining open `TODO.md` snapshot gate item into file-based pending todo.

### 2026-03-06 - Snapshot regression gate enabled and hardened

**By:** Codex

**Actions:**
- Set `scripts/test-native-editor.sh` to run snapshot verification by default.
- Added explicit `--no-snapshots` opt-out and `--record-snapshots` documented flow.
- Fixed verification bug by clearing `KERN_RECORD_SNAPSHOTS` before post-record verify run.
- Validated gate behavior: snapshot diffs fail, recorded baselines pass on rerun.
