#!/bin/bash
# open-ui-test-permissions.sh — Build the UI test runner and open the right System Settings pane.
#
# This does NOT grant permissions automatically (macOS requires manual user approval),
# but it makes it easy to locate the correct Runner.app to add to Accessibility.
#
# Usage:
#   ./scripts/open-ui-test-permissions.sh

set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/.derived-data/tests}"

echo "▸ Building UI test runner (DerivedData: $DERIVED_DATA_PATH)..."

# Build-for-testing (not full test execution) so we can point System Settings at
# the correct Runner.app without running the suite.
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme KernTextKitUI \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing \
  >/dev/null

RUNNER="$DERIVED_DATA_PATH/Build/Products/Debug/KernTextKitUITests-Runner.app"
RUNNER_BIN="$RUNNER/Contents/MacOS/KernTextKitUITests-Runner"

if [ ! -d "$RUNNER" ]; then
  echo "ERROR: UI test runner not found at: $RUNNER" >&2
  echo "Try running: ./scripts/test-native-editor.sh --ui-only (it will build the runner too)." >&2
  exit 1
fi

echo ""
echo "Runner app:"
echo "  $RUNNER"
echo ""
echo "Runner binary (use this if the .app won't stay in the Accessibility list):"
echo "  $RUNNER_BIN"
echo ""
echo "Next:"
echo "1) System Settings > Privacy & Security > Accessibility"
echo "2) Add + enable:"
echo "   - Xcode"
echo "   - KernTextKitUITests-Runner"
echo "   If KernTextKitUITests-Runner doesn't appear after adding, try adding the Runner binary path above."
echo "   If the + file picker silently fails on your macOS version, drag-and-drop the Runner.app from Finder into the list instead."
echo ""

# Reveal runner in Finder.
open -R "$RUNNER" >/dev/null 2>&1 || true

# Open the relevant System Settings panes.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" >/dev/null 2>&1 || true
