---
status: complete
priority: p3
issue_id: "905"
tags: [code-review, simplicity, maintainability]
dependencies: []
---

# Remove stale staged promotion parse state fields left from reverted off-main attempt

## Problem Statement

`NativeEditorViewController` still carries `stagedPromotionParseWorkItem`-related state even though parse now runs on main and those fields are no longer operationally meaningful. This increases cognitive load and maintenance overhead.

## Findings

- Parse work item state is cancelled/reset in multiple places.
- Current promotion implementation is synchronous main-thread parse/apply path.
- Leftover state suggests off-main behavior that is not actually active.

## Proposed Solutions

### Option 1: Remove unused parse work-item state now

**Approach:** Delete stale fields and associated cancellation/reset calls.

**Pros:**
- Simpler code
- Reduced confusion

**Cons:**
- Must ensure no hidden future hooks rely on it

**Effort:** 1-2 hours

**Risk:** Low

---

### Option 2: Keep but document as reserved future state

**Approach:** Add comments and guard flags clarifying it's disabled.

**Pros:**
- Preserves scaffolding for future off-main work

**Cons:**
- Ongoing complexity remains

**Effort:** <1 hour

**Risk:** Low

## Recommended Action
Implemented Option 1: removed stale staged parse work-item state and related cancellation/reset branches.

## Technical Details

**Affected files:**
- `KernApp/Sources/Editor/NativeEditorViewController.swift`

## Resources

- Review inspection of staged promotion state-reset blocks.

## Acceptance Criteria

- [x] Dead/unused state removed or clearly documented as intentional
- [x] All related tests still pass
- [x] No behavior change in staged promotion flow

## Work Log

### 2026-02-25 - Review discovery

**By:** Codex

**Actions:**
- Audited staged promotion state lifecycle
- Confirmed parse path currently executes on main actor path

**Learnings:**
- Cleanup opportunity with low risk and maintainability upside.

### 2026-03-01 - Completed

**By:** Codex

**Actions:**
- Removed `stagedPromotionParseWorkItem` state field and associated cancel/reset/cleanup branches.
- Kept active promotion flow on main-thread parse path only (stability-first).
- Revalidated with full native + benchmark test suites.

**Learnings:**
- Eliminating dead queue-state branches reduces confusion and lowers risk of accidental reintroduction of unsafe off-main parse paths.

## Notes

- Nice-to-have cleanup after higher priority metric correctness issues.

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Filename normalized to match complete status in frontmatter.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
