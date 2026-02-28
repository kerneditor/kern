# Kern ROI Optimization Roadmap v2 (No Feature Crippling)

## Goals
- Keep all WYSIWYG features enabled.
- Eliminate spinner/hangs during open/scroll/edit.
- Reduce open-ready latency and full-fidelity completion time.
- Beat Zed on open-ready and close the full-style latency gap.

## Non-Negotiables
- No disabling parsing/styling/features as a shortcut.
- No user-visible viewport jumps during staged promotion.
- Main-thread responsiveness takes priority over background completion speed.

## Phase 0 — Measurement hardening (Immediate)
### Deliverables
- Split metrics into:
  - time-to-interactive (open-ready)
  - time-to-full-fidelity (all styles/highlights complete)
  - worst-frame apply time during staged promotion
  - scroll-jump count and max jump magnitude
- Add run labels for "quiet machine" vs "contended machine".

### Exit criteria
- Bench output clearly distinguishes app cost vs launch/window variance.

## Phase 1 — Main-thread budget enforcement
### Deliverables
- Frame-budget scheduler for staged promotion apply (hard cap per tick).
- Coalesced UI apply queue with starvation protection.
- Keep input/scroll priority above style promotion.

### Exit criteria
- No rainbow spinner from staged promotion on large fixture.
- 99th percentile promotion-apply slice under target budget.

## Phase 2 — True incremental markdown pipeline
### Deliverables
- Dirty-region block graph and incremental parse/semantic update.
- Parse only affected blocks + bounded neighborhood.
- Stable IDs for blocks/ranges for deterministic remap.

### Exit criteria
- Edit latency on huge files no longer scales with full doc size.
- Significant reduction in parse work per keystroke.

## Phase 3 — Stable layout + anchor correctness
### Deliverables
- Block-identity-based viewport anchoring.
- Geometry-stable placeholders for yet-to-be-promoted regions.
- Reflow-safe remapping during promotion.

### Exit criteria
- Zero unexpected viewport jumps while styles stream in.

## Phase 4 — Incremental export/save
### Deliverables
- Incremental markdown export path from dirty block ranges.
- Background serialization queue with cancellation/restart.
- Save path that merges pending dirty ranges deterministically.

### Exit criteria
- Save/serialize latency drops materially on huge fixture.
- No correctness regressions in round-trip tests.

## Phase 5 — Decoration virtualization
### Deliverables
- Viewport virtualization for heavy decorations (chrome/attachments/pills).
- Distance-based activation and prefetch windows.

### Exit criteria
- Scrolling remains smooth regardless of offscreen heavy content.

## Phase 6 — Persistent caches for reopen speed
### Deliverables
- Optional disk cache for parse/style artifacts keyed by file hash + prefs + app version.
- Fast reopen from cache with background validation.

### Exit criteria
- Repeat opens improve while preserving correctness.

## Test Plan (applies to every phase)
- Unit: incremental parser, dirty-range remap, anchor math, export correctness.
- Integration: staged-promotion stability, no-jump assertions, large fixture flows.
- Perf: benchmark_open_ready + wow_internal + scroll stress trace.
- Regression gates: all existing tests green, no metric regressions beyond tolerance.

## Execution order (ROI-first)
1. Phase 0
2. Phase 1
3. Phase 3 (jump/stability guardrails)
4. Phase 2
5. Phase 4
6. Phase 5
7. Phase 6

## Current run plan
- Start with Phase 0 + Phase 1 in this cycle.
- Re-benchmark after each merged logical unit.
- Publish before/after metrics table each step.
