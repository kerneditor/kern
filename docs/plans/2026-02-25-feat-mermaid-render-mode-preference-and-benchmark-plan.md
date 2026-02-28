---
title: "feat: Mermaid render mode preference + benchmark matrix"
type: feat
date: 2026-02-25
status: complete
---

# ✨ Mermaid render mode preference + benchmark matrix

## Objective
Provide a user-facing Mermaid render mode preference (`rich | ascii | auto`) and a dedicated benchmark so users can make an informed tradeoff decision.

## Success Criteria

- [x] Add Mermaid render mode option to native editor options and defaults pipeline
- [x] Add settings UI control for Mermaid render mode
- [x] Implement ASCII Mermaid render path while preserving full Mermaid parsing/export fidelity
- [x] Implement Auto mode (complexity-based rich/ascii selection)
- [x] Add behavior tests for option parsing, mode selection, and preference-driven rerender
- [x] Add dedicated benchmark test producing machine-readable + markdown artifacts
- [x] Run validation tests and benchmark run

## Implementation Phases

### Phase 1 — Option + preference plumbing

- [x] `NativeMarkdownCodec.Options` add `MermaidRenderMode`
- [x] `main.swift` add runtime/UI-test defaults and env override support
- [x] `NativeEditorPreferencesWindowController` add Mermaid render mode popup, persistence, restore defaults

### Phase 2 — Rendering implementation

- [x] Thread render mode through Mermaid fence import path
- [x] Extend `MarkdownMermaidAttachment` with requested/effective render mode
- [x] Add fast ASCII layout/render path with width-bucket caching
- [x] Add auto-mode complexity heuristic + threshold override (`nativeEditor.mermaidAutoAsciiThreshold` / `KERN_NATIVE_MERMAID_AUTO_ASCII_THRESHOLD`)

### Phase 3 — Test coverage

- [x] `NativeMarkdownCodecOptionsTests` add mode parsing/default/auto-selection tests
- [x] `NativeMarkdownCodecMermaidLayoutTests` add ASCII bounds + auto heavy-case coverage
- [x] `NativeEditorPreferencesTests` add live rerender test when Mermaid mode preference changes
- [x] Keep broader matrix/snapshot default profiles deterministic by setting `nativeEditor.mermaidRenderMode`

### Phase 4 — Dedicated benchmark

- [x] Add `testMermaidRenderModeBenchmarkMatrix` in `NativeMarkdownCodecPerformanceTests`
- [x] Benchmark `rich`, `ascii`, and `auto` on generated Mermaid-heavy fixture
- [x] Emit report artifacts to `benchmark-archive/mermaid-render-modes/`
- [x] Validate benchmark run and capture comparative p50/p95

## Validation Summary

- [x] Focused tests passed:
  - `NativeMarkdownCodecOptionsTests`
  - `NativeMarkdownCodecMermaidLayoutTests`
  - `NativeEditorPreferencesTests`
- [x] Benchmark test executed and report generated

## Artifacts

- Latest benchmark report and JSON are in:
  - `benchmark-archive/mermaid-render-modes/`
