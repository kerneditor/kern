# Kern Promotion Migration Report (2026-02-17)

Historical maintainer note preserved for repo archaeology. Contributors and end users can ignore this file.

## Scope

Promote the TextKit repo/app as primary `Kern`, preserve the older WebKit repo/app as legacy, and safely repoint the local `Kern` alias to TextKit without losing legacy worktree state.

## Pre-Migration Snapshot

- Snapshot directory:
  - `test-results/migration/20260217-154606`
- Pre-state log:
  - `test-results/migration/20260217-154606/pre-migration-state.txt`
- Backed up legacy worktree admin metadata:
  - `test-results/migration/20260217-154606/backup/walkthree-admin`
  - `test-results/migration/20260217-154606/backup/walkthree-dotgit-file`

## Safety-Critical Actions Performed

1. Legacy branch divergence check:
   - `main...rewrite` = `0 0` (no commit divergence).
2. Legacy archive marker tag created:
   - `archive-kern-webkit-2026-02-17` on commit `a909792`.
3. Legacy worktree moved off the local `Kern` alias:
   - from `Kern/.worktrees/walkthree`
   - to `legacy-webkit-worktrees/walkthree`
4. Legacy hardcoded script paths converted to repo-relative paths:
   - `scripts/measure-cold-start.sh`
   - `scripts/benchmark.sh`
   - `scripts/gen_tab_files.py`
   - `scripts/gen_stress_test.py`
   - `scripts/gen_stress_test_p2.py`
   - `scripts/gen_stress_test_p3.py`
5. Script syntax validation:
   - `bash -n` checks passed for shell scripts
   - `python3 -m py_compile` passed for Python scripts
6. Symlink repointed:
   - `Kern -> Kern-textkit`

## App/Association State

- Primary app:
  - `local Applications/Kern.app`
  - bundle id: `com.kern.textkit`
- Legacy app:
  - `local Applications/legacy-webkit.app`
  - bundle id: `com.kern.app`
- Markdown default association:
  - `duti -x md` resolves to `Kern.app` at `local Applications/Kern.app`
- Verified launch behavior:
  - `open -a Kern ...` -> TextKit app
  - `open -a <legacy-webkit-app> ...` -> legacy app

## Post-Migration Verification

- Post-state log:
  - `test-results/migration/20260217-154606/post-migration-state.txt`
- Key checks recorded there:
  - symlink target
  - repo roots/branches
  - legacy worktree list
  - markdown app association
  - running bundle paths
  - archive tag presence

## Files Updated In Primary Repo (TextKit)

- `AGENTS.md`
- `HANDOFF.md`
- `docs/legacy/repo-promotion-report-2026-02-17.md`

## Files Updated In Legacy Repo (WebKit)

- `scripts/measure-cold-start.sh`
- `scripts/benchmark.sh`
- `scripts/gen_tab_files.py`
- `scripts/gen_stress_test.py`
- `scripts/gen_stress_test_p2.py`
- `scripts/gen_stress_test_p3.py`

## Residual Risks / Notes

- Rebuilding the legacy WebKit app from Xcode can reintroduce `Kern.app` artifacts in DerivedData. Current LaunchServices mapping is correct, but if ambiguity returns, re-run:
  - `duti -s com.kern.textkit net.daringfireball.markdown all`
- Legacy repos/worktrees are intentionally dirty; this migration preserved their state and did not reset history.

## Rollback

1. Repoint symlink back to legacy:
   - `cd <projects-dir> && rm Kern && ln -s <legacy-webkit-repo> Kern`
2. Repoint markdown association to legacy app:
   - `duti -s com.kern.app net.daringfireball.markdown all`
3. Worktree admin backup available in migration backup folder if manual repair is ever needed.
