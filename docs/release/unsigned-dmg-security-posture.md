# Unsigned DMG security posture

Kern's current public binary distribution path is intentionally simple:

- GitHub-hosted `Kern-macOS-Release.dmg`
- matching `Kern-macOS-Release.dmg.sha256`
- no Apple signing
- no Apple notarization

## What the checksum proves

The published `.sha256` file lets you check that the downloaded DMG matches the published sidecar from the same GitHub release.

It does **not** authenticate publisher identity the way Apple signing/notarization would.

If you want the stronger-trust path, build Kern from source instead of using the GitHub binary.

## Current network surface

- local file images render from disk
- remote image loading is **off by default**
- when enabled, remote image loading is limited to **HTTPS**

## Release-integrity incidents

Use the private security reporting path in `SECURITY.md` instead of a public issue if you see:

- checksum mismatches
- suspicious DMG or app bundle contents
- a published release asset that appears replaced or tampered with
