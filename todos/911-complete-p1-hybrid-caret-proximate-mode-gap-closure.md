---
status: complete
priority: p1
issue_id: "911"
tags: [editor, ux, typing, markdown, hybrid]
dependencies: []
---

# Hybrid caret-proximate mode gap closure

Implement true Typora-like caret-proximate markdown syntax expansion across inline spans (links, emphasis, inline code, strikethrough), with preference support and stable collapse/round-trip behavior.

## Why complete
Hybrid caret-proximate mode now supports links, emphasis, inline code, strikethrough, and strong+emphasis spans with stable expand/collapse and export round-trip behavior.

## Acceptance
- [x] Hybrid mode covers links, emphasis, inline code, strikethrough
- [x] Expand near caret; collapse on leave
- [x] No style leak after collapse
- [x] Round-trip markdown fidelity preserved
