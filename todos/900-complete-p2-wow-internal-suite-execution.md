---
status: complete
priority: p2
issue_id: "900"
tags: [benchmark, maintenance]
dependencies: []
---

# 900 — wow_internal suite execution

- [x] Implement wow_internal suite plumbing (suite id, report schema, required metrics)
- [x] Wire Kern app instrumentation hooks for parse/layout/paint/edit/save-serialize
- [x] Fix env propagation for Kern launch in wow_internal runs
- [x] Add canonical archive artifacts (results.json/results.md/env.json)
- [x] Add regression checker suite-kind policy guardrail + tests
- [x] Update benchmark docs and wrapper defaults for wow_internal
- [x] Rebuild and reinstall Kern app bundle after code changes
- [x] Run smoke benchmarks for benchmark and wow_internal suites
- [x] Add per-stage timeout fault-injection tests
- [x] Add observer-effect overhead benchmark and docs
- [x] Run unattended 10-run stability smoke


## Work Log

### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Normalized to canonical todo format and closed; checklist already complete.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
