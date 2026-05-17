# Installing Kern from a GitHub release

This guide applies when a tagged GitHub release includes binary assets for Kern. The latest published release evidence currently tracked in this repository is [`v0.1.2`](v0.1.2-validation-evidence.md).

## Expected assets

Download both files from the release page:

- `Kern-macOS-Release.dmg`
- `Kern-macOS-Release.dmg.sha256`

## Check release-asset integrity

Run checksum verification in the directory that contains both files:

```bash
shasum -a 256 -c Kern-macOS-Release.dmg.sha256
```

Expected result:

```text
Kern-macOS-Release.dmg: OK
```

If the checksum does not match, discard the download and fetch the assets again.

This checksum only proves the downloaded DMG matches the published checksum sidecar from the same GitHub release. It does **not** authenticate publisher identity the way Apple signing/notarization would. If you want the stronger-trust path, build Kern from source instead.

## Install the app

1. Open `Kern-macOS-Release.dmg`
2. Drag `Kern.app` into `Applications`
3. Eject the mounted disk image
4. Launch `Kern.app` from `Applications`

Do not run Kern directly from the mounted disk image. Copy it into `Applications` first.

## First launch on macOS

The binary distributed from this repository is currently:

- unsigned
- not notarized

That means macOS may block first launch.

If that happens:

1. In Finder, right-click `Kern.app`
2. Choose `Open`
3. Confirm the open prompt

If macOS still blocks launch:

1. Open **System Settings → Privacy & Security**
2. Find the Kern launch warning
3. Choose **Open Anyway**

## Build from source instead

If you prefer not to run the GitHub release binary, use the source-build guide instead:

- [Build Kern from source](building-kern-from-source.md)
