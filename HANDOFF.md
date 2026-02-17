# HANDOFF — KernTextKit Is Now Primary Kern

Last updated: 2026-02-17 15:50:00 KST

This is the only file a new agent needs to read first.

## 1) Canonical Repos And Roles

### Primary product repo (active development)
- Path: `/Users/aaaaa/Projects/Kern-textkit`
- Branch: `main`
- Product: native TextKit app (no WebView)
- Primary app identity: `Kern` (bundle id `com.kern.textkit`)

### Legacy archive repo (WebKit/CoreEditor)
- Path: `/Users/aaaaa/Projects/Kern-webkit`
- Branch checked out: `rewrite`
- Branch divergence vs `main`: none (`main` and `rewrite` both at `a909792`)
- Archive marker tag: `archive-kern-webkit-2026-02-17`
- Active legacy worktree path:
  - `/Users/aaaaa/Projects/Kern-webkit-worktrees/walkthree`

## 2) Mandatory Read Order (Fresh Agent)

1. `HANDOFF.md` (this file)
2. `AGENTS.md`
3. `docs/plans/native-editor-test-suite.md`
4. `docs/plans/markdown-spec-failure-tracker.md`
5. `docs/plans/native-editor-missing-features-implementation-plan.md`
6. `NATIVE-EDITOR-TEST-MATRIX.md`

## 3) Promotion Changes Completed In This Session

1. Legacy repo directory switched from `Kern` to `Kern-webkit`.
2. Legacy archive decision made:
   - keep (do not merge into TextKit; no unique commit divergence on `rewrite`).
3. Legacy `walkthree` git worktree moved to stable path:
   - `/Users/aaaaa/Projects/Kern-webkit-worktrees/walkthree`
   - this removed dependency on `/Users/aaaaa/Projects/Kern` alias.
4. TextKit app installed as:
   - `/Users/aaaaa/Applications/Kern.app`
5. Legacy WebKit app preserved as:
   - `/Users/aaaaa/Applications/Kern-webkit.app`
6. Markdown default app association set to TextKit:
   - `duti -s com.kern.textkit net.daringfireball.markdown all`
7. Launch behavior verified:
   - `open -a Kern <file.md>` opens `/Users/aaaaa/Applications/Kern.app`
   - `open <file.md>` opens `/Users/aaaaa/Applications/Kern.app`
   - `open -a Kern-webkit <file.md>` opens `/Users/aaaaa/Applications/Kern-webkit.app`
8. Current compatibility symlink target:
   - `/Users/aaaaa/Projects/Kern -> /Users/aaaaa/Projects/Kern-textkit`

## 4) Current Critical Commands

Run from:
- `/Users/aaaaa/Projects/Kern-textkit`

Build:
```bash
xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit -configuration Debug -destination 'platform=macOS' build
```

Open app (primary Kern):
```bash
open -a Kern test-fixtures/stress-test.md
```

Open app (legacy WebKit archive):
```bash
open -a Kern-webkit test-fixtures/stress-test.md
```

Fast tests:
```bash
./scripts/test-native-editor.sh --unit-only
```

Exhaustive tests:
```bash
./scripts/test-native-editor.sh --unit-only --exhaustive
./scripts/test-native-editor.sh --unit-only --snapshots --exhaustive
./scripts/test-native-editor.sh --ui-only --exhaustive
```

Full orchestrated gate:
```bash
./scripts/run-exhaustive-native-suite.sh
```

## 5) App Association Verification Commands

```bash
duti -x md
open -a Kern /Users/aaaaa/Projects/Kern-textkit/test-fixtures/stress-test.md
open /Users/aaaaa/Projects/Kern-textkit/test-fixtures/stress-test.md
open -a Kern-webkit /Users/aaaaa/Projects/Kern-textkit/test-fixtures/stress-test.md
```

Expected:
- `duti -x md` points to `/Users/aaaaa/Applications/Kern.app` and `com.kern.textkit`.

## 6) Test/Fixture Assets (Primary)

- Exhaustive typed fixture:
  - `test-fixtures/ultimate-stress-test.md`
- Volume/permutation fixture:
  - `test-fixtures/mega-stress-test.md`
- Generator:
  - `scripts/gen_ultimate_stress_test.py`
- Permutation appendix sync:
  - `scripts/sync_mega_permutation_appendix.py`

## 7) Priority Functional Areas (Continue From Here)

- Task permutations and GFM/Kern profile behavior
- Ordered task numbering semantics
- Heading checkbox extension behavior
- Code block chrome + copy/language interactions
- Image attachments (local/remote/broken)
- Mermaid rendering quality/layout
- Math block/inline rendering
- Anchor navigation behavior
- Find/replace overlay non-obstruction
- Exhaustive typing behavior (real keystroke newline/exit rules)

## 8) Wrap Skill Note

Requested wrap chain was: sync-docs -> claude-md-improver -> handoff.

- `syncing-docs` exists.
- `handoff` exists.
- `claude-md-improver` was missing at:
  - `/Users/aaaaa/.claude/skills/claude-md-improver/SKILL.md`

Fallback used:
- comprehensive `HANDOFF.md` rewrite (this file) with exact state and continuation instructions.

## 9) Safety And Rollback

No destructive repo history operations were used.

Rollback options:
1. Use legacy app directly:
   - `open -a Kern-webkit <file.md>`
2. If you must restore old path naming:
   - move `/Users/aaaaa/Projects/Kern-webkit` back to `/Users/aaaaa/Projects/Kern` and remove symlink.
3. Re-point markdown association back to legacy (if needed):
   - `duti -s com.kern.app net.daringfireball.markdown all`

## 10) Completion Checklist For This Migration

- [x] Single-file handoff prepared for fresh agent
- [x] Legacy `rewrite` branch evaluated
- [x] Legacy repo preserved under `Kern-webkit`
- [x] Legacy worktree moved off `/Users/aaaaa/Projects/Kern` alias path
- [x] TextKit promoted as default `Kern` app for open commands
- [x] Markdown default association moved to TextKit
- [x] Legacy WebKit app remains available as explicit option (`Kern-webkit`)

Detailed migration report:
- `docs/legacy/repo-promotion-report-2026-02-17.md`
