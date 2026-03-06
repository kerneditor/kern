---
status: complete
priority: p2
issue_id: "016"
tags: [code-review, performance, native-editor, textkit]
dependencies: []
---

# Move Markdown import/export off main thread (performance + responsiveness)

## Problem Statement

The editor currently imports Markdown and exports Markdown on the main thread. With large documents (e.g. `test-fixtures/native-editor-benchmark.md` is multi-megabyte), this risks UI hitches during typing, loading, and file reloads.

## Findings

- `KernApp/Sources/Editor/NativeEditorViewController.swift:122-129`
  - `renderMarkdown` calls `NativeMarkdownCodec.importMarkdown` directly on the main actor.
- `KernApp/Sources/Editor/NativeEditorViewController.swift:250-255`
  - Debounced export calls `NativeMarkdownCodec.exportMarkdown` on the main actor.
- `KernApp/Sources/Editor/NativeMarkdownCodec.swift:9`
  - Codec is annotated `@MainActor`, which prevents straightforward background execution and encourages main-thread work.

## Proposed Solutions

### Option 1: Make codec thread-safe and run import/export on a background queue

**Approach:**
- Remove `@MainActor` from `NativeMarkdownCodec` (or isolate only the AppKit calls that truly require main).
- Ensure any AppKit types used are safe off-main (or switch to CoreText-friendly representations for parsing).
- In `NativeEditorViewController`, perform import/export in a Task on a background executor, then apply results on main.

**Pros:**
- Better responsiveness on large files.
- Aligns with "most performant, lightweight" goal.

**Cons:**
- Requires careful thread-safety audit around NSAttributedString mutations and AppKit font/color usage.

**Effort:** Large

**Risk:** Medium/High

---

### Option 2: Keep codec on main but add stronger throttling and progress UI

**Approach:**
- Increase debounce interval for export on large docs.
- Add a background pre-render step for initial open.

**Pros:**
- Less refactor.

**Cons:**
- Still can hitch; not ideal long-term.

**Effort:** Medium

**Risk:** Medium

## Acceptance Criteria

- [x] Opening and typing in `native-editor-benchmark.md` does not freeze the UI noticeably
- [x] Perf test (gated) establishes a budget (time + memory) and stays under it
- [x] No race conditions in export/import pipeline

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Identified main-thread import/export paths and codec main-actor restriction.



### 2026-03-05 - Completion validation

**By:** Codex

**Actions:**
- Re-validated against current native + typing gate suites and current benchmark evidence.
- Confirmed issue behavior no longer reproduces in current branch scope.
- Marked todo as complete in file-based portfolio.

**Evidence:**
- `./scripts/run-typing-behavior-gate.sh --lane pr` ✅
- `./scripts/test-native-editor.sh` ✅
- `benchmark_open_ready` and `benchmark_full_fidelity` reruns archived under `benchmark-archive/runs/20260304-163101-benchmark-open-ready/` and `benchmark-archive/runs/20260304-163144-benchmark-full-fidelity/`.

