# Public repo health

This document explains the tracked public-repo health posture for Kern.

## Support routing

Public support routing lives in:
- `SUPPORT.md`
- `.github/ISSUE_TEMPLATE/config.yml`
- `SECURITY.md`

Use those paths to distinguish:
- support/install/build questions
- bug reports
- security disclosures

## Ownership metadata

Conservative ownership metadata lives in:
- `.github/CODEOWNERS`

The current mapping is intentionally minimal. It is meant to provide a clear default reviewer/owner path until path-specific ownership becomes necessary.

## Release-note hygiene

This repository currently uses GitHub generated release notes categories via:
- `.github/release.yml`

A hand-maintained `CHANGELOG.md` is not part of the current release process.

## Tracked vs external-only security controls

Tracked in this repository:
- `SECURITY.md`
- `.github/dependabot.yml`
- issue-template routing

External-only GitHub settings that are not asserted by tracked files here:
- Dependabot alerts
- secret scanning
- push protection
- code scanning / CodeQL settings
- private vulnerability reporting

Those controls may be enabled at the GitHub repo/org settings level, but this repository does not claim their status unless maintainers verify them directly in GitHub.

## Community profile note

The GitHub community profile API may still report `issue_template: null` even though issue forms are present under `.github/ISSUE_TEMPLATE/`.

For this repository, treat the tracked issue forms as the source of truth. The `null` result is recorded as an observed GitHub API/profile limitation or cache discrepancy, not as evidence that issue forms are absent.

## Tracked generated-artifact policy

Generated local artifacts are ignored by project policy. This includes Xcode generated projects, DerivedData, xcresult bundles, Python virtualenvs, release DMGs, checksums, dSYMs, benchmark outputs, and maintainer-local Forge/session files.

The root handoff file, legacy `architect/` notes, and root `research-*.md` history were reviewed during open-source cleanup and are intentionally removed from the tracked public repo surface. Maintainer-local replacements should stay in ignored local paths.
