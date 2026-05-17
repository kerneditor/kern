# Release validation gate for unsigned DMG releases

This document defines the current release gate for Kern's public GitHub-hosted macOS binary path.

It separates:
- the **contributor baseline** enforced by CI
- the **release-only maintainer validation** required before a GitHub release is considered valid

## Scope of this gate

This gate applies to the current public release model:
- a GitHub-hosted `Kern-macOS-Release.dmg`
- a matching `Kern-macOS-Release.dmg.sha256`
- an unsigned, not-notarized macOS app

This gate does **not** require:
- Apple signing or notarization
- Homebrew support
- the deferred full-fidelity benchmark goal

## Contributor baseline enforced by CI

The contributor baseline is the PR/main gate. CI currently enforces these commands:

```bash
./scripts/test-native-editor.sh --unit-only
./scripts/test-markdown-spec-conformance.sh
./scripts/run-typing-behavior-gate.sh --lane pr
cd scripts/kern-bench && swift test -c release
```

These checks answer the question:

> Is the current tree healthy enough to merge as source code?

## Release-only maintainer validation

These checks are **not** part of the contributor PR baseline.

They are release-only because they depend on:
- locally generating the release artifact
- inspecting the packaged DMG
- and, after upload, verifying the published GitHub release asset against the recorded digest

Run these before calling a GitHub release ready:

### 1. Build the local release artifacts

```bash
./scripts/package-kern-app.sh
```

Expected outputs:
- `dist/Kern.app`
- `dist/Kern-macOS-Release.dmg`
- `dist/Kern-macOS-Release.dmg.sha256`

### 2. Verify the local checksum

```bash
(cd dist && shasum -a 256 -c Kern-macOS-Release.dmg.sha256)
```

### 3. Inspect the DMG contents

```bash
TMP_MOUNT_ROOT="$(mktemp -d /tmp/kern-release-mount.XXXXXX)"
ATTACH_OUT="$(hdiutil attach -nobrowse -readonly -mountroot "$TMP_MOUNT_ROOT" dist/Kern-macOS-Release.dmg)"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUT" | awk -F '\t' 'NF>=3 { print $3 }' | tail -n 1)"
ls -la "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT"
rmdir "$TMP_MOUNT_ROOT"
```

Expected mount contents:
- `Kern.app`
- `Applications` symlink

### 4. Verify the uploaded release assets after publication

After uploading the DMG to a GitHub release, verify the published DMG and published checksum sidecar match the recorded digest:

```bash
./scripts/verify-github-release-asset.sh <tag>
```

This step is required to bind the reviewed local artifact to the downloaded published assets.

### 5. Record the unsigned/Gatekeeper posture

Capture the current Gatekeeper posture:

```bash
spctl -a -vv dist/Kern.app
```

Expected result today: the app is rejected because it is unsigned and not notarized.

### 6. Complete the packaged-app manual checklist

Complete `MANUAL-TESTING.md` against the packaged release flow and archive the tested macOS version with the release evidence.

## Release-ready conditions

For the current unsigned DMG path, a GitHub release is ready only if **all** of the following are true:

1. the contributor baseline is green
2. the local packager produced the expected DMG and SHA sidecar
3. the local checksum passed
4. the DMG mount contents are correct
5. the release notes and install docs clearly state:
   - the app is unsigned
   - the app is not notarized
   - macOS may block first launch
   - the documented override path is Finder `Open`, then **Privacy & Security → Open Anyway** if needed
   - the published checksum only proves same-release integrity, not publisher authentication
   - building from source is the stronger-trust path when Apple signing/notarization is absent
6. after upload, the published DMG and the published `.sha256` sidecar both match the reviewed local digest
7. the unsigned `spctl` posture was recorded
8. the packaged-app manual checklist was completed and archived with the tested macOS version

## Related docs

- [Installing Kern from a GitHub release](installing-kern-from-github-release.md)
- [Building Kern from source](building-kern-from-source.md)
- [GitHub release checklist](github-release-checklist.md)
- [Unsigned DMG security posture](unsigned-dmg-security-posture.md)
