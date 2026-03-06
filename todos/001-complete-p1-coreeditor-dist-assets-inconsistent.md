---
status: complete
priority: p1
issue_id: "001"
tags: [code-review, build, coreeditor, release]
dependencies: []
---

# CoreEditor/dist assets are inconsistent (risk: broken app in clean checkout)

## Problem Statement

`CoreEditor/dist` is embedded as an app resource (`project.yml` includes it as a resources folder), but the working tree shows large churn with many deleted tracked files and many new hashed assets that are currently untracked. If this state is committed incorrectly (or if a clean checkout/build is done without regenerating assets), Kern will ship a broken web editor bundle.

This is a P1 because it can break basic app functionality outside the native-editor prototype.

## Findings

- `project.yml:40-42` bundles `CoreEditor/dist` as app resources. If those files are missing or mismatched, the WebView editor path will fail at runtime.
- `CoreEditor/dist/index.html:24-26` references hashed assets (e.g. `app-CUBi3BsH.js`, `chunks/mermaid-DO6BT0ek.js`) that currently appear as untracked files in `git status` while older hashed assets are staged for deletion.
- Current `git status` shows dozens of `D CoreEditor/dist/...` (deleted) and corresponding `?? CoreEditor/dist/...` (new) files; this is a classic "built output updated but not staged" situation.

## Proposed Solutions

### Option 1: Keep tracking dist, enforce a deterministic build + staging

**Approach:**
- Define the canonical build command for `CoreEditor` (e.g. `pnpm build`/`npm run build`) and run it before commits/releases.
- Ensure *all* new hashed assets are added and old ones removed in the same commit.
- Add a CI check that fails if `CoreEditor/dist/index.html` references missing files.

**Pros:**
- Simple packaging model (no runtime build).
- Works offline; app bundle is self-contained.

**Cons:**
- Large diffs; review noise.
- Easy to forget staging; breaks releases.

**Effort:** Medium

**Risk:** Medium

---

### Option 2: Stop tracking dist; build it during app build (or via CI artifact)

**Approach:**
- Remove `CoreEditor/dist` from git (keep `CoreEditor/src` only).
- Add an Xcode build phase (or prebuild script) to build CoreEditor into `dist` deterministically.
- Or fetch a pinned artifact from CI.

**Pros:**
- No dist churn in PRs.
- Source-of-truth stays in TS source.

**Cons:**
- More complex build; requires Node tooling at build time.
- Harder for contributors without Node.

**Effort:** Large

**Risk:** Medium/High (build pipeline changes)

---

### Option 3: Hybrid: track dist but rename to stable filenames

**Approach:**
- Configure bundler to emit stable filenames (avoid content-hash) for app shipping.

**Pros:**
- Still self-contained.
- Smaller diffs.

**Cons:**
- Cache-busting semantics change.
- Might not be supported depending on bundler setup.

**Effort:** Medium

**Risk:** Medium

## Recommended Action

## Technical Details

**Affected files:**
- `project.yml:40`
- `CoreEditor/dist/index.html:24`
- `CoreEditor/dist/*` (many)

## Resources

- Branch: `rewrite`

## Acceptance Criteria

- [x] Decide on whether `CoreEditor/dist` is tracked or built as part of the app build
- [x] In the chosen approach, a clean checkout can build and run Kern without missing `dist` resources
- [x] Add a guardrail (CI or script) that prevents `index.html` from referencing missing assets

## Work Log

### 2026-02-13 - Code Review Finding

**By:** Codex

**Actions:**
- Identified inconsistent `CoreEditor/dist` state (tracked deletions + untracked new hashed assets).
- Verified app bundle includes `CoreEditor/dist` via `project.yml`.

**Learnings:**
- If dist remains tracked, we need strong guardrails to prevent partial commits.


### 2026-03-04 - Portfolio triage cleanup

**By:** Codex

**Actions:**
- Closed as stale: repository is now native-only and CoreEditor/dist premise is obsolete.

**Learnings:**
- Todo metadata should be kept synchronized with actual completion state.
