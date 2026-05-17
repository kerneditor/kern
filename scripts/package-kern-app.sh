#!/bin/bash
# package-kern-app.sh — Build and package Kern as a standalone .app.
#
# Outputs:
# - dist/Kern.app
# - dist/Kern-macOS-Release.dmg
# - dist/Kern-macOS-Release.dmg.sha256
#
# Usage:
#   ./scripts/package-kern-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA_APP="${DERIVED_DATA_APP:-$(pwd)/.derived-data/native}"
DIST_DIR="${DIST_DIR:-$(pwd)/dist}"
ARCH="$(uname -m)"
DESTINATION="platform=macOS,arch=${ARCH}"

mkdir -p "$DIST_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen is required to generate KernTextKit.xcodeproj. Install it with: brew install xcodegen" >&2
  exit 1
fi

delete_dir_if_exists() {
  local dir="$1"
  if [ -d "$dir" ]; then
    # Avoid broad rm -rf patterns; delete contents depth-first, then the directory.
    find "$dir" -depth -mindepth 1 -delete
    rmdir "$dir" 2>/dev/null || true
  fi
}

echo "▸ Generating Xcode project (xcodegen)..."
xcodegen generate >/dev/null

echo "▸ Building Release app (DerivedData: $DERIVED_DATA_APP)..."
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme KernTextKit \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_APP" \
  build \
  >/dev/null

APP_SRC="$DERIVED_DATA_APP/Build/Products/Release/Kern.app"
if [ ! -d "$APP_SRC" ]; then
  APP_SRC="$DERIVED_DATA_APP/Build/Products/Release/KernTextKit.app"
fi
APP_DST="$DIST_DIR/Kern.app"
if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: release app not found at: $APP_SRC" >&2
  exit 1
fi
delete_dir_if_exists "$APP_DST"
/usr/bin/ditto "$APP_SRC" "$APP_DST"

DMG_DST="$DIST_DIR/Kern-macOS-Release.dmg"
DMG_SHA_DST="$DMG_DST.sha256"
rm -f "$DMG_DST" "$DMG_SHA_DST"

DMG_STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kern-dmg.XXXXXX")"
cleanup() {
  delete_dir_if_exists "${DMG_STAGING_ROOT:-}"
}
trap cleanup EXIT

DMG_CONTENT_DIR="$DMG_STAGING_ROOT/Kern"
mkdir -p "$DMG_CONTENT_DIR"
/usr/bin/ditto "$APP_DST" "$DMG_CONTENT_DIR/Kern.app"
ln -s /Applications "$DMG_CONTENT_DIR/Applications"

hdiutil create \
  -quiet \
  -ov \
  -volname "Kern" \
  -srcfolder "$DMG_CONTENT_DIR" \
  -format UDZO \
  "$DMG_DST"

hdiutil verify -quiet "$DMG_DST"
(cd "$DIST_DIR" && /usr/bin/shasum -a 256 "$(basename "$DMG_DST")") > "$DMG_SHA_DST"

echo ""
echo "Packaged artifacts:"
echo "  App: $APP_DST"
echo "  DMG: $DMG_DST"
echo "  SHA256: $DMG_SHA_DST"
