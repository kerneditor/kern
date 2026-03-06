---
title: "feat: exhaustive markdown typing behavior test program"
type: feat
date: 2026-03-03
status: implemented
owner: forge-orchestrator
---

# ✨ Exhaustive Markdown Typing Behavior Test Program

## Execution Progress

- [x] Milestone 1 — Behavior Model + Coverage Contract
- [x] Milestone 2 — Deterministic Transition Matrix Implementation
- [x] Milestone 3 — Stateful + Differential Layer
- [x] Milestone 4 — CI Gate + Evidence
## Overview

Define and implement a behavior-exhaustive typing test system for KernTextKit’s native Markdown editor.

"Exhaustive" here means **exhaustive over behavior transitions**, not brute-force all possible character permutations.

This plan is grounded in the completed research artifact:
- `architect/research/exhaustive-markdown-typing-behavior-testing.md`

## Problem Statement

Current typing tests cover many cases but are not yet a formally complete behavior model with objective transition coverage gates.

We need a test strategy that:
1. covers all critical markdown typing behaviors (list/task/quote/code/table transitions),
2. gives measurable confidence (coverage + property checks + differential checks), and
3. remains maintainable and deterministic in CI.

## Scope

### In Scope
- Enter/Shift+Enter/Tab/Shift+Tab/Backspace/Space behavior transitions in markdown contexts.
- Deterministic matrix tests (context × action × marker/indent state).
- Stateful sequence tests with deterministic seeds and replay.
- Differential semantic checks against markdown export/import invariants.
- CI gate + reporting for behavior coverage.

### Out of Scope
- Micro-optimizing parser/rendering in this initiative.
- Full cursor-position permutation explosion.
- Non-typing UX features unrelated to typing behavior correctness.

## Behavioral Model Contract

### Core Context Classes
1. Paragraph
2. Bullet list item (empty/non-empty)
3. Ordered list item (empty/non-empty)
4. Task list item (unchecked/checked; empty/non-empty)
5. Blockquote (single/nested)
6. Code fence body
7. Table row/cell
8. Inline-code span context

### Core Actions
1. Enter
2. Shift+Enter
3. Tab
4. Shift+Tab
5. Backspace at structural boundaries
6. Space at marker boundary (task toggle path)
7. Prefix typing transforms (`- `, `1. `, `> `, fence markers)

### Required Invariants
- Marker correctness after transition (e.g., next bullet marker inserted when expected).
- Ordered numbering progression rules preserved.
- Indentation and nesting transitions are valid.
- Exit behavior from empty list items follows declared policy.
- Exported markdown remains semantically stable.

### Policy Profiles
- **GFM-like default profile**: list/task continuation and exit behaviors aligned to product defaults.
- **Strict profile**: conservative transform behavior with minimal auto-structural edits.

All behavior tests must declare which policy profile they assert.

### Negative Context Guarantees
Auto-structural transforms must *not* trigger in these contexts unless explicitly designed:
- inside fenced code bodies,
- inside inline code spans,
- inside link destination/reference literals,
- inside table cells when transform would corrupt cell structure.

## Coverage Contract (Release Gate)

### Must-Pass Thresholds

#### PR Lane (required on every PR)
- **Critical transition coverage:** 100%
- **Core context × action matrix coverage:** 100%
- **Pairwise factor coverage:** >=95%
- **Stateful deterministic sequence smoke:** >=24 seeded sequences (`KERN_TYPING_STATEFUL_SEEDS`)
- **Conformance drift:** zero regressions on selected core CommonMark/GFM-derived fixture subset

#### Nightly Lane (exhaustive lane)
- **Critical transition coverage:** 100%
- **Core context × action matrix coverage:** 100%
- **Pairwise factor coverage:** >=95%
- **3-way critical-factor coverage:** >=90%
- **Stateful deterministic stress:** >=120 seeded sequences × >=120 steps (`KERN_TYPING_STATEFUL_SEEDS`, `KERN_TYPING_STATEFUL_STEPS`)
- **Conformance drift:** zero regressions on full selected CommonMark/GFM-derived fixture set

### Critical Factors for t-way
- context class
- action
- marker state
- indentation bucket
- line emptiness
- continuation policy profile

## Milestone Plan

## Milestone 1 — Behavior Model + Coverage Contract

### Deliverables
- Finalized behavior model table and invariant map.
- Gate thresholds and factor definitions frozen.
- Test naming conventions and fixture taxonomy.

### Success Criteria
- Plan reviewed with no unresolved CRITICAL/HIGH findings.
- Stakeholder sign-off on coverage definitions and thresholds.

### Files
- `docs/plans/2026-03-03-feat-exhaustive-typing-behavior-test-program-plan.md`
- `architect/research/exhaustive-markdown-typing-behavior-testing.md`

## Milestone 2 — Deterministic Transition Matrix Implementation

### Deliverables
- Matrix-driven test scaffolding and generators.
- Core behavior transition tests for all required context × action pairs.
- Coverage report emitted as machine-readable artifact.

### Success Criteria
- 100% critical transition and core context × action coverage reached.
- All matrix tests deterministic and green in CI.

### Candidate Files
- `KernTests/NativeEditorTypingReliabilityTests.swift`
- `KernTests/NativeEditorMegaStressTypingMatrixTests.swift`
- `KernTests/Support/TypingBehaviorMatrix.swift` (new)
- `KernTests/Support/TypingBehaviorGenerators.swift` (new)
- `KernTests/NativeEditorTypingBehaviorMatrixCoverageTests.swift` (new, implemented)

## Milestone 3 — Stateful + Differential Layer

### Deliverables
- Seeded stateful action-sequence suite.
- Shrinkable/replayable failing trace harness.
- Differential semantic assertions (import/export equivalence classes).

### Success Criteria
- Deterministic replay for every failure seed.
- No unresolved critical differential mismatch.

### Candidate Files
- `KernTests/NativeEditorTypingStatefulTests.swift` (new)
- `KernTests/Support/TypingBehaviorStateMachine.swift` (new)
- `scripts/tests/typing_behavior_replay.py` (optional helper)

## Milestone 4 — CI Gate + Evidence

### Deliverables
- CI gate wiring for behavior-exhaustive profile.
- Human-readable and machine-readable evidence reports.
- Documentation updates in test plan docs.

### Success Criteria
- Gate passes locally and in CI.
- Regression artifacts available for self-repair loops.

### Candidate Files
- `scripts/test-native-editor.sh`
- `docs/plans/native-editor-test-suite.md`
- `docs/plans/markdown-spec-failure-tracker.md`
- `test-results/typing-behavior/` (artifact dir)

## Risks and Mitigations

1. **State-space explosion**
   - Mitigation: equivalence classes + constrained t-way generation.
2. **Flaky sequence tests**
   - Mitigation: deterministic seeds, strict replay, isolated fixtures.
3. **False confidence from narrow assertions**
   - Mitigation: combine structural assertions + round-trip invariants + differential checks.
4. **CI runtime growth**
   - Mitigation: tiered profiles (PR core vs nightly exhaustive).
5. **Oracle ambiguity between intended UX policy and parser semantics**
   - Mitigation: explicit policy profiles + per-test declared expectation profile.

## Quality Gate Checklist

- [x] Deterministic matrix suite green.
- [x] Stateful suite green with replay support.
- [x] Coverage thresholds met in PR and nightly lanes.
- [x] Conformance fixture drift = 0.
- [x] Negative-context guarantees covered and green.
- [x] Failure artifacts include seed + minimal replay trace.
- [x] Docs updated.

## Execution Evidence (2026-03-04)

- PR lane gate pass:
  - `test-results/typing-behavior/20260304-003743-pr/summary.txt`
  - `test-results/typing-behavior/20260304-003743-pr/xcodebuild.log`
- Nightly lane gate pass:
  - `test-results/typing-behavior/20260304-003815-nightly/summary.txt`
  - `test-results/typing-behavior/20260304-003815-nightly/xcodebuild.log`
- CI script:
  - `scripts/run-typing-behavior-gate.sh`
- Exhaustive env wiring:
  - `scripts/test-native-editor.sh`
  - `project.yml`

## Self-Critique (Pre-Adversarial)

Potential weak points in this draft:
1. 3-way threshold may be costly on PR runs; likely needs nightly-only enforcement.
2. Differential oracle definition needs explicit tolerance rules for intentional UX policies.
3. Table/code-fence contexts may need dedicated negative tests to prevent false transforms.

Planned adjustment after adversarial review:
- split gates into PR/nightly lanes,
- define policy-profile abstraction for expected divergence,
- force explicit negative-context transition tests.


## Adversarial Review Log (Milestone 1 / GATE B)

Reviewer mode: sequential main-thread adversarial pass (fresh-agent spawn unavailable due thread limit at runtime).

### Findings
- **CRITICAL:** none
- **HIGH:** none
- **MEDIUM:**
  1. Coverage thresholds needed PR-vs-nightly split to avoid impractical PR latency.
  2. Policy ambiguity risk between parser semantics and editor UX defaults.
  3. Negative-context guards were implied but not explicit in acceptance gates.
- **LOW:** naming and artifact granularity improvements.

### Resolutions Applied
1. Added PR lane + nightly lane threshold split.
2. Added explicit policy profiles section and requirement to declare policy per test.
3. Added negative-context guarantees and gate item for explicit validation.
4. Added replay artifact requirement to quality gate checklist.

### Gate B Result
Milestone 1 planning gate **PASS** (no unresolved CRITICAL/HIGH findings).
