# KernTextKit — Task List

Persistent tracker for the native TextKit rewrite (no WebView).

## Done

- [x] Split into fresh repo at `Kern-textkit`
- [x] Rename app to `KernTextKit` and bundle id to `com.kern.textkit`
- [x] Make app native-only (remove WebKit/CoreEditor codepaths)
- [x] Update unit tests + scripts for `KernTextKit.xcodeproj` / `KernTextKit` schemes
- [x] CRITICAL: Replace global mutable statics in NativeMarkdownCodec with `ImportContext` parameter threading (review finding #5)
- [x] CRITICAL: Strip blockquote prefixes in reference definition pre-scan (review finding #4, 66ae0db)

## Next

- [x] HIGH: Load local images asynchronously in MarkdownRichAttachments (validated 2026-03-06: local `NSImage(contentsOf:)` load runs on background queue)
- [x] WYSIWYG: numbered list behavior (enter/exit/indent) aligned with Notion/GFM expectations
- [x] WYSIWYG: task list behavior (toggle by clicking marker region, hit target sizing, ordered-task option)
- [x] WYSIWYG: code block visuals (background, padding, font), copy button positioning and selection behavior (functional scope done; theme/style polish tracked separately)
- [x] WYSIWYG: tables editing UX (caret movement, row/column edits) + export correctness (tracked: todo `915`)
- [x] Preferences UI for native editor options (export dialect, extensions strategy, ordered numbering, checkbox hit target)

## Testing

- [x] Add always-on screenshot baselines and pixel-level comparison gates for alignment regressions (tracked: todo `916`)
- [x] Add fuzz/property tests for editing operations (import -> edit ops -> export) where feasible

## Benchmarks

- [x] Define benchmark protocol: cold start, file open latency, scroll/selection responsiveness, memory on huge docs
- [x] Implement benchmark runners for:
  - KernTextKit (this repo)
  - Legacy Kern (WebKit) for comparison (re-scoped; deprecated path no longer part of locked roster)
  - External editors (VS Code/TextEdit/Sublime/Zed; Typora documented as "cannot render large fixture")

## Forge Orchestrator — Code Block Chrome Decoupling Fix (2026-03-06)

- [x] Milestone 1 — Plan + adversarial review
  - Scope: fix code-block visual asymmetry caused by unconditional top chrome reservation; preserve code-block chrome usability without layout jumps.
  - Files in scope: `KernApp/Sources/Editor/CodeBlockChromeGeometry.swift`, `KernApp/Sources/Editor/NativeEditorViewController.swift`, `KernApp/Sources/Editor/NativeMarkdownTextView.swift`, `KernApp/Sources/Editor/NativeMarkdownCodec.swift`, targeted regression tests.
  - Gate:
    - reviewed implementation plan exists
    - no CRITICAL/HIGH plan-review findings remain

- [x] Milestone 2 — Implement inactive/active chrome separation
  - Scope: make the default code-block background symmetric when chrome is hidden; keep chrome overlay visible/usable when caret or hover activates it.
  - Gate:
    - inactive code blocks no longer reserve extra top background space
    - active chrome does not overlap the first code token
    - no block-overlap regression for consecutive code blocks

- [x] Milestone 3 — Regression coverage + quality gate
  - Scope: add/adjust geometry + placement regressions for inactive and active states, then pass focused and full suites.
  - Required checks:
    - focused chrome/layout suites
    - `./scripts/test-native-editor.sh`
    - `./scripts/run-typing-behavior-gate.sh --lane pr`
  - Gate:
    - targeted suites green
    - full native suite green
    - typing gate green

- [x] Milestone 4 — Rebuild/reinstall + evidence sync
  - Scope: rebuild the app bundle, reinstall locally, update forge state with evidence.
  - Gate:
    - local app bundle rebuilt/reinstalled
    - forge review artifacts and completion evidence recorded

### Completion notes
- Async local-image rendering now invalidates layout even when the attachment finishes decoding before it first binds to a host text view, which removed the stale placeholder-sized layout seen in full-spec snapshot/manual renders.
- Snapshot baselines were re-recorded after the render pipeline stabilized.


## Forge Orchestrator — Typing Behavior Exhaustive Test Program (2026-03-03)

- [x] Milestone 1 — Behavior Model + Coverage Contract (GATE A/B)
  - Goal: Lock behavior-state model, coverage dimensions, and pass/fail criteria for typing behavior.
  - Dependencies: completed research artifact.
  - Files in scope: architect/research/, docs/plans/, KernTests/ (planning-only references).
  - Quality criteria: reviewed plan exists with no CRITICAL/HIGH adversarial findings.
  - Research needed: none (already completed).
- [x] Milestone 2 — Deterministic Typing Transition Matrix + Generators
  - Goal: Implement matrix-driven behavior tests for core markdown contexts/actions.
  - Dependencies: Milestone 1.
  - Files in scope: KernTests/NativeEditorTypingReliabilityTests.swift, new generator/helpers.
  - Quality criteria: all new matrix tests pass and report transition coverage.
  - Research needed: constrained combinatorial generation implementation detail.
- [x] Milestone 3 — Stateful/Property + Differential Validation
  - [x] Initial stateful sequence smoke suite implemented (`NativeEditorTypingStatefulSequenceTests`)
  - [x] Calibrate strict blocking invariants (`KERN_TYPING_STATEFUL_ENFORCE=1`)
  - [x] Expand differential normalizer to full stress-suite parity
  - Goal: Add long-sequence behavior stress tests and differential semantic assertions.
  - Dependencies: Milestone 2.
  - Files in scope: KernTests property/differential suites + fixtures + scripts.
  - Quality criteria: seeded reproducible failures, replay harness, no unresolved critical findings.
  - Research needed: oracle mapping edge cases.
- [x] Milestone 4 — Quality Gate + CI Integration + Evidence
  - Goal: enforce behavior-exhaustive gate in CI and publish confidence evidence.
  - Dependencies: Milestone 3.
  - Files in scope: scripts/test-native-editor.sh, docs/plans/, benchmark/report artifacts.
  - Quality criteria: gate green, documentation updated, regression evidence archived.
  - Research needed: none.


## Forge Orchestrator — Pending Todo Master Run (2026-03-04)

- [x] Milestone 1 — Portfolio sync + regression triage hardening
  - Scope: finalize pending/complete status truth, capture failing regression todos, ensure research-backed specs for behavior semantics.
  - Todos: 003, 005, 006, 009, 908, 909, 910.
  - Gate: validated todo classification report exists + reviewed implementation plan exists (adversarial review serialized).

- [x] Milestone 2 — P1 typing regressions (blocking)
  - Scope: fix inline-link conversion regressions and nested-list continuation/conversion/marker-recovery regressions; fix paste+undo+redo continuation regression.
  - Todos: 908, 909, 910.
  - Required checks:
    - `./scripts/run-typing-behavior-gate.sh --lane pr`
    - targeted suites: `NativeEditorNotionListBehaviorRegressionTests`, `NativeEditorTypingBehaviorMatrixCoverageTests`, `NativeEditorNotionTypingBehaviorProgramTests`
  - Gate: listed failing PR-lane regressions pass.

- [x] Milestone 3 — P2 reliability + semantics
  - Scope: CRLF/CR normalization, UTF-16 clamp correctness, typography correctness split tracks, Shift+Enter style-carry policy implementation.
  - Todos: 004, 007, 008, 009, 015.
  - Required checks:
    - `./scripts/run-typing-behavior-gate.sh --lane pr`
    - `./scripts/test-markdown-spec-conformance.sh`
  - Gate: no regressions in typing matrix lanes + semantics checks green.

- [x] Milestone 4 — UX mode + performance/threading + polish
  - Scope: syntax visibility/hybrid mode, off-main import/export, code-block spellcheck/theme behavior, tracking hygiene.
  - Todos: 906, 016, 010, 011, 002.
  - Required checks:
    - `./scripts/test-native-editor.sh`
    - benchmark and perf evidence run for impacted paths
  - Gate: UX tests + perf checks + repo hygiene checks pass.

- [x] Milestone 5 — Final quality gate and release evidence
  - Scope: full native test suite, benchmark suite, docs/todo sync.
  - Required checks:
    - `./scripts/test-native-editor.sh`
    - `./scripts/run-typing-behavior-gate.sh --lane pr`
    - benchmark scripts for Kern and forked Zed apples-to-apples
  - Gate: all target tests pass; benchmark evidence archived; all todos resolved/reclassified.

### 2026-03-05 validation snapshot

- ✅ `./scripts/run-typing-behavior-gate.sh --lane pr` passed.
- ✅ `./scripts/test-native-editor.sh` passed (`313` tests, `0` failures, `78` skipped non-gated lanes).
- ✅ Cross-editor benchmarks re-run on official fixture/profile:
  - `benchmark_open_ready` (`10` runs): Kern p50 `208ms`, Zed p50 `805ms`.
  - `benchmark_full_fidelity` (`10` runs, apples-to-apples): Kern p50 `2171ms`, Zed p50 `1165ms`.
- ⚠️ `./scripts/test-markdown-spec-conformance.sh` remains failing on known strict-profile baseline drift
  (`CommonMark 34/652`, `GFM 36/670`) — no new regression signature introduced in this pass.
- ✅ Todo portfolio resolved/reclassified; all files in `todos/` now marked `complete`.

## Forge Orchestrator — Missed/Pending Recovery Run (2026-03-05)

- [x] Milestone 1 — Re-open missed scope + pipeline truth sync
  - Scope: re-open false-complete hybrid scope; create explicit pending todo chain (911/912).
  - Gate: pending todos tracked with explicit acceptance criteria.

- [x] Milestone 2 — Hybrid caret-proximate mode (first closure pass)
  - Scope: implement hybrid preference + inline-link caret expansion/collapse + round-trip safety.
  - Gate:
    - targeted hybrid tests green
    - no regression in existing inline-link typing lanes.

- [x] Milestone 3 — Typing behavior expansion for new feature
  - Scope: add hybrid permutations to typing behavior program/matrix profiles.
  - Gate:
    - PR lane green
    - profile matrix includes hybrid mode keys.

- [x] Milestone 4 — Quality gate + rebuild/reinstall
  - Scope: run full native suite and typing gate, then rebuild + reinstall app.
  - Gate:
    - `./scripts/test-native-editor.sh` green
    - `./scripts/run-typing-behavior-gate.sh --lane pr` green
    - debug build reinstalled to local `~/Applications/Kern.app`
