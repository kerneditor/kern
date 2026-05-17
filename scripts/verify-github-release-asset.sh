#!/bin/bash
# verify-github-release-asset.sh — download a published GitHub release asset and
# compare its SHA-256 digest to a recorded local sidecar.
#
# Usage:
#   ./scripts/verify-github-release-asset.sh <tag> [asset-name] [sha-file] [repo]
#
# Defaults:
#   asset-name: Kern-macOS-Release.dmg
#   sha-file:   dist/Kern-macOS-Release.dmg.sha256
#   repo:       derived from remote.origin.url

set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify-github-release-asset.sh <tag> [asset-name] [sha-file] [repo]

Arguments:
  tag         Git tag or release tag name to download from
  asset-name  Release asset filename (default: Kern-macOS-Release.dmg)
  sha-file    Local SHA-256 sidecar file (default: dist/Kern-macOS-Release.dmg.sha256)
  repo        GitHub repo in owner/name form (default: parsed from remote.origin.url)

Environment:
  GH_BIN      Override the gh executable path for testing
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 4 ]; then
  usage >&2
  exit 1
fi

TAG="$1"
ASSET_NAME="${2:-Kern-macOS-Release.dmg}"
SHA_FILE="${3:-dist/Kern-macOS-Release.dmg.sha256}"
GH_BIN="${GH_BIN:-gh}"

parse_repo_from_remote() {
  local remote
  remote="$(git config --get remote.origin.url || true)"
  case "$remote" in
    git@github.com:*.git)
      remote="${remote#git@github.com:}"
      remote="${remote%.git}"
      ;;
    git@github.com:*)
      remote="${remote#git@github.com:}"
      ;;
    https://github.com/*.git)
      remote="${remote#https://github.com/}"
      remote="${remote%.git}"
      ;;
    https://github.com/*)
      remote="${remote#https://github.com/}"
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n' "$remote"
}

REPO="${4:-}"
if [ -z "$REPO" ]; then
  if ! REPO="$(parse_repo_from_remote)"; then
    echo "ERROR: could not determine GitHub repo from remote.origin.url; pass owner/name explicitly." >&2
    exit 1
  fi
fi

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found at: $GH_BIN" >&2
  exit 1
fi

if [ ! -f "$SHA_FILE" ]; then
  echo "ERROR: SHA sidecar not found: $SHA_FILE" >&2
  exit 1
fi

EXPECTED_LINE="$(head -n 1 "$SHA_FILE" | tr -d '\r')"
EXPECTED_HASH="$(printf '%s\n' "$EXPECTED_LINE" | awk '{print $1}')"
EXPECTED_NAME="$(printf '%s\n' "$EXPECTED_LINE" | awk '{print $2}')"
EXPECTED_NAME="${EXPECTED_NAME#\*}"
SHA_ASSET_NAME="$(basename "$SHA_FILE")"

if ! printf '%s\n' "$EXPECTED_HASH" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "ERROR: invalid SHA-256 line in: $SHA_FILE" >&2
  exit 1
fi

if [ "$EXPECTED_NAME" != "$ASSET_NAME" ]; then
  echo "ERROR: SHA sidecar names '$EXPECTED_NAME' but requested asset is '$ASSET_NAME'." >&2
  exit 1
fi

DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kern-release-verify.XXXXXX")"
cleanup() {
  find "$DOWNLOAD_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$DOWNLOAD_DIR" 2>/dev/null || true
}
trap cleanup EXIT

"$GH_BIN" release download "$TAG" --repo "$REPO" --pattern "$ASSET_NAME" --dir "$DOWNLOAD_DIR"
"$GH_BIN" release download "$TAG" --repo "$REPO" --pattern "$SHA_ASSET_NAME" --dir "$DOWNLOAD_DIR"

DOWNLOADED_ASSET="$DOWNLOAD_DIR/$ASSET_NAME"
if [ ! -f "$DOWNLOADED_ASSET" ]; then
  echo "ERROR: downloaded asset not found after gh release download: $DOWNLOADED_ASSET" >&2
  exit 1
fi

DOWNLOADED_SHA_FILE="$DOWNLOAD_DIR/$SHA_ASSET_NAME"
if [ ! -f "$DOWNLOADED_SHA_FILE" ]; then
  echo "ERROR: downloaded SHA sidecar not found after gh release download: $DOWNLOADED_SHA_FILE" >&2
  exit 1
fi

DOWNLOADED_SHA_LINE="$(head -n 1 "$DOWNLOADED_SHA_FILE" | tr -d '\r')"
if [ "$DOWNLOADED_SHA_LINE" != "$EXPECTED_LINE" ]; then
  echo "ERROR: published SHA sidecar does not match the reviewed local sidecar." >&2
  echo "  local:     $EXPECTED_LINE" >&2
  echo "  published: $DOWNLOADED_SHA_LINE" >&2
  exit 1
fi

ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$DOWNLOADED_ASSET" | awk '{print $1}')"
if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
  echo "ERROR: SHA-256 mismatch for uploaded asset." >&2
  echo "  expected: $EXPECTED_HASH" >&2
  echo "  actual:   $ACTUAL_HASH" >&2
  exit 1
fi

printf 'Verified GitHub release asset digest.\n'
printf '  repo:  %s\n' "$REPO"
printf '  tag:   %s\n' "$TAG"
printf '  asset: %s\n' "$ASSET_NAME"
printf '  sidecar: %s\n' "$SHA_ASSET_NAME"
printf '  sha:   %s\n' "$ACTUAL_HASH"
