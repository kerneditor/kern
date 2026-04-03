#!/bin/bash
# package-kern-app.sh — Build and package Kern as a standalone .app.
#
# Outputs:
# - dist/Kern.app
# - dist/Kern-macOS-Release.zip
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

delete_dir_if_exists() {
  local dir="$1"
  if [ -d "$dir" ]; then
    # Avoid broad rm -rf patterns; delete contents depth-first, then the directory.
    find "$dir" -depth -mindepth 1 -delete
    rmdir "$dir" 2>/dev/null || true
  fi
}

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
cp -R "$APP_SRC" "$APP_DST"

ZIP_DST="$DIST_DIR/Kern-macOS-Release.zip"
rm -f "$ZIP_DST"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DST" "$ZIP_DST"

echo ""
echo "Packaged artifacts:"
echo "  App: $APP_DST"
echo "  Zip: $ZIP_DST"
