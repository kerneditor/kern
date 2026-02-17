#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/.derived-data/native}"
CONFIGURATION="${CONFIGURATION:-Debug}"

ARCH="$(uname -m)"
DESTINATION="platform=macOS,arch=${ARCH}"

echo "Building KernTextKit ($CONFIGURATION) to: $DERIVED_DATA_PATH"
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme KernTextKit \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/KernTextKit.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Built app not found at: $APP_PATH" >&2
  exit 1
fi

echo "Launching: $APP_PATH"
echo "Note: this uses 'open -n' to force launching the built app even if another KernTextKit is already running."
if [ "${1:-}" != "" ]; then
  # Resolve relative paths from repo root.
  FILE_PATH="$1"
  if [ ! -f "$FILE_PATH" ]; then
    echo "ERROR: file not found: $FILE_PATH" >&2
    exit 1
  fi
  open -n -a "$APP_PATH" "$(cd "$(dirname "$FILE_PATH")" && pwd)/$(basename "$FILE_PATH")"
else
  open -n "$APP_PATH"
fi
