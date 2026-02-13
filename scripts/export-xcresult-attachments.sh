#!/bin/bash
# export-xcresult-attachments.sh — Export screenshots/logs from an .xcresult bundle.
#
# Usage:
#   ./scripts/export-xcresult-attachments.sh path/to/TestResults.xcresult [output-dir]

set -euo pipefail

XCRESULT_PATH="${1:-}"
if [ "$XCRESULT_PATH" = "" ]; then
  echo "Usage: $0 path/to/TestResults.xcresult [output-dir]" >&2
  exit 2
fi

if [ ! -e "$XCRESULT_PATH" ]; then
  echo "ERROR: xcresult not found: $XCRESULT_PATH" >&2
  exit 1
fi

OUT_DIR="${2:-$(cd "$(dirname "$XCRESULT_PATH")" && pwd)/xcresult-attachments}"
mkdir -p "$OUT_DIR"

echo "Exporting attachments..."
echo "  xcresult: $XCRESULT_PATH"
echo "  output:   $OUT_DIR"

xcrun xcresulttool export attachments \
  --path "$XCRESULT_PATH" \
  --output-path "$OUT_DIR" \
  >/dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# xcresulttool can export screenshots as HEIC depending on the Xcode/macOS version.
# Convert to PNG so tools that can't read HEIC can still inspect the artifacts.
if ls "$OUT_DIR"/*.heic "$OUT_DIR"/*.HEIC >/dev/null 2>&1; then
  "$SCRIPT_DIR/convert-heic-to-png.sh" "$OUT_DIR" >/dev/null || true
fi

echo "Done."
