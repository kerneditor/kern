---
status: complete
priority: p1
issue_id: "912"
tags: [testing, typing, matrix, hybrid]
dependencies: ["911"]
---

# Typing behavior expansion for hybrid mode

Expand typing matrix/stateful coverage for hybrid caret-proximate mode permutations and edge actions.

## Why complete
Typing behavior coverage now includes hybrid-mode permutations in matrix/program/stateful lanes, with PR gating evidence and regression checks in place.

## Acceptance
- [x] Matrix includes hybrid-mode permutations for all inline span types
- [x] Program/stateful lanes include hybrid expand/edit/collapse actions
- [x] Exhaustive lane includes hybrid profiles with gating evidence
