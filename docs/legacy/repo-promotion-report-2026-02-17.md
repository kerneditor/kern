# Kern Promotion Migration Report (2026-02-17)

## Scope

Promote TextKit repo/app as primary `Kern`, preserve WebKit repo/app as legacy, and safely repoint `/Users/aaaaa/Projects/Kern` to TextKit without losing legacy worktree state.

## Pre-Migration Snapshot

- Snapshot directory:
  - `/Users/aaaaa/Projects/Kern-textkit/test-results/migration/20260217-154606`
- Pre-state log:
  - `/Users/aaaaa/Projects/Kern-textkit/test-results/migration/20260217-154606/pre-migration-state.txt`
- Backed up legacy worktree admin metadata:
  - `/Users/aaaaa/Projects/Kern-textkit/test-results/migration/20260217-154606/backup/walkthree-admin`
  - `/Users/aaaaa/Projects/Kern-textkit/test-results/migration/20260217-154606/backup/walkthree-dotgit-file`

## Safety-Critical Actions Performed

1. Legacy branch divergence check:
   - `main...rewrite` = `0 0` (no commit divergence).
2. Legacy archive marker tag created:
   - `archive-kern-webkit-2026-02-17` on commit `a909792`.
3. Legacy worktree moved off `/Users/aaaaa/Projects/Kern` alias:
   - from `/Users/aaaaa/Projects/Kern/.worktrees/walkthree`
   - to `/Users/aaaaa/Projects/Kern-webkit-worktrees/walkthree`
4. Legacy hardcoded script paths converted to repo-relative paths:
   - `/Users/aaaaa/Projects/Kern-webkit/scripts/measure-cold-start.sh`
   - `/Users/aaaaa/Projects/Kern-webkit/scripts/benchmark.sh`
   - `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_tab_files.py`
   - `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_stress_test.py`
   - `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_stress_test_p2.py`
   - `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_stress_test_p3.py`
5. Script syntax validation:
   - `bash -n` checks passed for shell scripts
   - `python3 -m py_compile` passed for Python scripts
6. Symlink repointed:
   - `/Users/aaaaa/Projects/Kern -> Kern-textkit`

## App/Association State

- Primary app:
  - `/Users/aaaaa/Applications/Kern.app`
  - bundle id: `com.kern.textkit`
- Legacy app:
  - `/Users/aaaaa/Applications/Kern-webkit.app`
  - bundle id: `com.kern.app`
- Markdown default association:
  - `duti -x md` resolves to `Kern.app` at `/Users/aaaaa/Applications/Kern.app`
- Verified launch behavior:
  - `open -a Kern ...` -> TextKit app
  - `open -a Kern-webkit ...` -> legacy app

## Post-Migration Verification

- Post-state log:
  - `/Users/aaaaa/Projects/Kern-textkit/test-results/migration/20260217-154606/post-migration-state.txt`
- Key checks recorded there:
  - symlink target
  - repo roots/branches
  - legacy worktree list
  - markdown app association
  - running bundle paths
  - archive tag presence

## Files Updated In Primary Repo (TextKit)

- `/Users/aaaaa/Projects/Kern-textkit/AGENTS.md`
- `/Users/aaaaa/Projects/Kern-textkit/HANDOFF.md`
- `/Users/aaaaa/Projects/Kern-textkit/docs/legacy/repo-promotion-report-2026-02-17.md`

## Files Updated In Legacy Repo (WebKit)

- `/Users/aaaaa/Projects/Kern-webkit/scripts/measure-cold-start.sh`
- `/Users/aaaaa/Projects/Kern-webkit/scripts/benchmark.sh`
- `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_tab_files.py`
- `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_stress_test.py`
- `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_stress_test_p2.py`
- `/Users/aaaaa/Projects/Kern-webkit/scripts/gen_stress_test_p3.py`

## Residual Risks / Notes

- Rebuilding legacy `Kern-webkit` from Xcode can reintroduce `Kern.app` artifacts in DerivedData. Current LaunchServices mapping is correct, but if ambiguity returns, re-run:
  - `duti -s com.kern.textkit net.daringfireball.markdown all`
- Legacy repos/worktrees are intentionally dirty; this migration preserved their state and did not reset history.

## Rollback

1. Repoint symlink back to legacy:
   - `cd /Users/aaaaa/Projects && rm Kern && ln -s Kern-webkit Kern`
2. Repoint markdown association to legacy app:
   - `duti -s com.kern.app net.daringfireball.markdown all`
3. Worktree admin backup available in migration backup folder if manual repair is ever needed.

