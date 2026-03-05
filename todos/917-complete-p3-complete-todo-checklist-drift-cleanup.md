---
status: complete
priority: p3
issue_id: "917"
tags: [process, docs, todos, hygiene]
dependencies: []
---

# Cleanup checklist drift in complete todo files

## Problem Statement

Multiple `status: complete` todo files still have unchecked acceptance items, which creates confusion about completion quality and portfolio truth.

## Findings

- Revalidation found 16 complete files with unchecked checklist entries.
- Runtime tests are currently green, so this appears to be documentation/process drift rather than confirmed open regressions.

## Proposed Solutions

### Option 1: One-time checklist reconciliation pass (preferred)

**Approach:** Review each affected complete todo and either check fulfilled criteria or explicitly annotate exceptions.

**Pros:**
- Restores trust in todo status.
- Better auditability for future passes.

**Cons:**
- Manual review overhead.

**Effort:** Small-Medium

**Risk:** Low

---

### Option 2: Enforce template linting for complete status

**Approach:** Add a script/lint check preventing `status: complete` files from retaining unchecked acceptance criteria unless tagged as exception.

**Pros:**
- Prevents recurrence.

**Cons:**
- Requires process/tooling changes.

**Effort:** Medium

**Risk:** Low-Medium

## Recommended Action

## Technical Details

**Likely affected files:**
- `todos/*-complete-*.md` (targeted subset)
- Optional helper script in `scripts/` for future validation

## Resources

- `docs/reports/2026-03-06-todo-portfolio-revalidation.md`

## Acceptance Criteria

- [x] All complete todos are reconciled (checked/annotated) for acceptance criteria.
- [x] Portfolio status report has no checklist drift warnings.
- [x] Optional prevention check documented or implemented.

## Work Log

### 2026-03-06 - Created from revalidation

**By:** Codex

**Actions:**
- Added explicit hygiene todo after detecting checklist/status drift.

### 2026-03-06 - Reconciled and enforced checklist hygiene

**By:** Codex

**Actions:**
- Reconciled outstanding acceptance checklist drift in complete todo files.
- Added `scripts/check-todo-complete-checklists.py` guard.
- Wired hygiene check into default `scripts/test-native-editor.sh` quality lane.
