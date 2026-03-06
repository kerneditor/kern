---
title: "feat: Editor UX clipboard + hotkeys + navigation roadmap"
type: feat
date: 2026-03-02
owner: codex
status: completed
---

# feat: Editor UX clipboard + hotkeys + navigation roadmap

## Overview

This plan defines a UX-first hardening pass for Kern’s day-to-day editing ergonomics, starting with clipboard behavior and hotkeys, then extending to navigation, typography/readability polish, and reliability fixes (typing/undo/autosave).

Primary trigger:
- Pasted content can temporarily inherit foreign black text / wrong font.
- Clipboard behavior does not yet clearly guarantee Markdown-fidelity copy/paste workflows.
- Several shortcuts and file actions are missing or non-obvious.

## Problem Statement

Kern is a WYSIWYG Markdown editor. That means UX must satisfy both:
1. Visual consistency and readability on paste (no foreign style pollution), and
2. Markdown fidelity for authoring/browsing workflows (especially AI-generated Markdown docs and repo files).

At the same time, core editor ergonomics (Save As shortcut clarity, copy path, reveal in folder, tab navigation, quick open, etc.) must be discoverable and aligned with user expectations from macOS and modern editors.

## Research Summary

### Internal codebase findings

- Paste is currently handled in `NativeMarkdownTextView` and was recently normalized to plain text insertion to prevent foreign style pollution.
- There is no generalized “copy Markdown source for selection” path for standard copy commands.
- Menu bar is built in `AppDelegate.buildMenuBar()` and currently includes basic File/Edit/Format/View/Window items but lacks several requested commands (copy full path, reveal in Finder, explicit tab switching shortcuts, etc.).

### External UX/shortcut references

- Apple Support keyboard shortcuts page confirms `Shift-Command-S` as the Save As / duplicate pattern on macOS.
- Apple finder/terminal shortcuts include `Option-Command-C` for copying pathnames (good precedent for “Copy Full Path”).
- VS Code default keybindings confirm common discoverability patterns:
  - Save As: `Shift+Cmd+S`
  - Quick Open: `Cmd+P`
  - Switch tabs/editors: `Ctrl+Tab` / `Ctrl+Shift+Tab`
- Zed keybindings docs similarly use `Cmd+P` for file finder and support next/previous tab traversal behavior.

## Design Principles

- No style corruption: foreign font/color from paste must never pollute document style.
- Markdown is first-class: Kern should support a reliable Markdown-fidelity copy/paste workflow.
- Progressive UX: safe defaults now; advanced preference toggles later.
- Command parity: expose critical actions in menu + shortcuts + command validation.
- Test-first for regressions: clipboard behavior and shortcuts must have automated coverage where feasible.

## Scope

### In scope (this roadmap)

- Clipboard UX and fidelity behavior.
- Core hotkeys and file actions.
- Planning + prioritization for broader UX backlog items listed below.

### Out of scope (this immediate execution pass)

- Full quick-open implementation.
- Full multi-tab multi-select/mass-close/mass-reorder.
- Permanent undo history across relaunches.
- Complete visual redesign/theme system.

## Phases

### Phase 1 — Clipboard correctness + markdown fidelity baseline (execute now)

- [x] Keep default paste style-safe (already fixed) and extend to semantic-safe behavior path.
- [x] Add explicit Markdown-fidelity copy path for “Select All + Copy” so full document round-trip preserves Markdown syntax.
- [x] Ensure plain-text and rich-text paste normalization tests remain green.
- [x] Add tests for new clipboard fidelity behavior.

### Phase 2 — Hotkey and file action baseline (execute now)

- [x] Make Save As shortcut explicit and intuitive (`Shift+Cmd+S`).
- [x] Add “Copy Full Path” command and shortcut (`Option+Cmd+C`).
- [x] Add “Reveal in Finder” command and shortcut (`Shift+Cmd+R`).
- [x] Add tab traversal shortcuts (`Ctrl+Tab`, `Ctrl+Shift+Tab`).
- [x] Add menu validation gates for file-dependent actions.

### Phase 3 — Typing/undo/autosave reliability

- [x] Build reproducible test matrix for typing bugs reported in stress flows.
- [x] Define undo/autosave interaction guarantees (including autosave boundaries and deep undo behavior).
- [x] Implement targeted fixes and regression tests.
  - [x] Add regression coverage for bulk markdown paste rehydration (raw markdown -> styled WYSIWYG after flush/export).
  - [x] Add undo/autosave regression coverage for multi-step undo/redo across flush boundaries.
  - [x] Expand typing bug matrix (newline/list/task toggle/undo/redo/autosave boundaries).

### Phase 4 — Navigation and markdown browsing UX

- [x] Quick Open (`Cmd+P`) baseline via file picker (current document directory by default).
- [x] Sidebar anchors/outline for headings and jump navigation.
- [x] Open-containing-folder improvements and related commands.

### Phase 5 — Visual polish and readability

- [x] Tune line-height/paragraph spacing (Notion-like readability delta, slight increase only).
- [x] Theme/font system hardening (default dark/light presets + custom theme hooks).
- [x] Verify code block/chrome spacing and overlap edge cases.

### Phase 6 — Advanced document interaction

- [x] Large table horizontal interaction model (scroll container / overflow strategy, preference-backed).
- [x] Tab management upgrades baseline (close other tabs + move tab to new window; multi-select/reorder follow-up tracked separately).
- [x] CLI-first workflows (open/search/automation support) and command parity.
- [x] Cmd+1..9 baseline shortcuts for tab selection.

## Backlog capture from user brainstorm (tracked)

- Easy copy full file path.
- Typing behavior bugs.
- Copy/paste Markdown fidelity and selection semantics.
- Open containing folder.
- Ctrl-tab / ctrl-shift-tab tab switch.
- Fast file search/open.
- CLI tool mode.
- Readability spacing tweak.
- Themes/fonts support.
- Better default dark/light themes.
- Beautification pass.
- Heading anchors sidebar / markdown browsing UX.
- Sensible hotkeys for everything.
- Stronger persistent undo/redo model.
- Autosave + deep undo expectations.
- Wide-table rendering UX.
- Multi-tab selection/close/reorder.
- Cmd+1..9 tab selection.
- Verify code/text block spacing collisions.

## Acceptance Criteria (for current execution pass)

- [x] Copy/paste no longer imports foreign font/color artifacts.
- [x] Select-all copy can round-trip Markdown syntax through pasteboard.
- [x] Save As shortcut is explicit `Shift+Cmd+S`.
- [x] Copy path + reveal in Finder commands exist and work on saved docs.
- [x] Ctrl-tab and ctrl-shift-tab switch tabs.
- [x] Native unit tests pass.
- [x] App rebuilt and reinstalled after changes.

## Verification

- Unit: `./scripts/test-native-editor.sh`
- Manual:
  - Open Markdown fixture, `Cmd+A`, `Cmd+C`, paste into new doc and external editor.
  - Copy rich content from external source and paste into Kern; verify no foreign style pollution.
  - Test `Shift+Cmd+S`, `Option+Cmd+C`, `Shift+Cmd+R`, `Ctrl+Tab`, `Ctrl+Shift+Tab`.

## Risks and mitigations

- Risk: Overly aggressive copy override could surprise users on partial selections.
  - Mitigation: Limit Markdown-fidelity override to full-document selection first.
- Risk: Shortcut conflicts.
  - Mitigation: Use common macOS/editor precedents and validate in menu.
- Risk: Paste semantics regressions in edge cases.
  - Mitigation: add focused unit tests for round-trip and style normalization.

## Status

- [x] Plan drafted and refined with local+external research.
- [x] Execute Phase 1.
- [x] Execute Phase 2.
- [x] Execute Phase 3 reliability pass (undo/autosave + typing matrix regression hardening).
- [x] Execute Phase 4 partial pass (open-containing-folder command + hotkey + validation tests).
- [x] Execute Phase 4 complete pass (heading outline sidebar + jump navigation + menu state wiring).
- [x] Execute Phase 5 complete pass (spacing, theme/font controls, code-block spacing regression checks).
- [x] Execute Phase 6 baseline pass (wide-table overflow mode, tab-management baseline, CLI wrapper + tests).
- [x] Run tests + rebuild + reinstall.
