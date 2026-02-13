#!/bin/bash
# test-native-editor.sh — Run native-editor unit + UI tests and collect artifacts.
#
# Usage:
#   ./scripts/test-native-editor.sh [--unit-only] [--ui-only] [--skip-xcodegen] [--export-ui-attachments] [--exhaustive] [--snapshots] [--record-snapshots]
#
# Notes:
# - UI tests require the Mac to be unlocked and Xcode to have the necessary Automation permissions.
# - Results are written under test-results/native-editor/<timestamp>/

set -euo pipefail
cd "$(dirname "$0")/.."

RUN_UNIT=true
RUN_UI=true
SKIP_XCODEGEN=false
EXPORT_UI_ATTACHMENTS=false
ENABLE_EXHAUSTIVE=false
ENABLE_SNAPSHOTS=false
RECORD_SNAPSHOTS=false

for arg in "$@"; do
  case "$arg" in
    --unit-only) RUN_UI=false ;;
    --ui-only) RUN_UNIT=false ;;
    --skip-xcodegen) SKIP_XCODEGEN=true ;;
    --export-ui-attachments) EXPORT_UI_ATTACHMENTS=true ;;
    --exhaustive) ENABLE_EXHAUSTIVE=true ;;
    --snapshots) ENABLE_SNAPSHOTS=true ;;
    --record-snapshots) ENABLE_SNAPSHOTS=true; RECORD_SNAPSHOTS=true ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/test-results/native-editor/$TS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/kern-derived-data-tests}"

mkdir -p "$OUT_DIR"

echo "=== Kern Native Editor Tests ==="
echo "Output: $OUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo ""
echo "Modes:"
echo "  --snapshots          Run snapshot tests (via scheme: KernTextKitSnapshots)"
echo "  --record-snapshots   Record snapshot baselines (via scheme: KernTextKitRecordSnapshots)"
echo "  --exhaustive         Enable exhaustive (slow) tests (via *Exhaustive schemes)"
echo ""
echo "Env toggles (optional):"
echo "  KERN_EXPORT_UI_ATTACHMENTS=1   Always export UI attachments (otherwise only on failure)"
echo "  KERN_UI_SCREENSHOTS=always     Keep UI screenshots on success (default)"
echo "  KERN_UI_SCREENSHOTS=failure    Only keep UI screenshots on failure (faster)"
echo "  KERN_UI_SCREENSHOTS=off        Disable UI screenshots (fastest)"
echo "  KERN_UI_SCREENSHOT_DIR=/path   Write UI PNGs to disk (runner sets automatically)"
echo ""

UNIT_SCHEME="KernTextKit"
if [ "$RECORD_SNAPSHOTS" = true ] && [ "$ENABLE_EXHAUSTIVE" = true ]; then
  UNIT_SCHEME="KernTextKitRecordSnapshotsExhaustive"
elif [ "$RECORD_SNAPSHOTS" = true ]; then
  UNIT_SCHEME="KernTextKitRecordSnapshots"
elif [ "$ENABLE_SNAPSHOTS" = true ] && [ "$ENABLE_EXHAUSTIVE" = true ]; then
  UNIT_SCHEME="KernTextKitSnapshotsExhaustive"
elif [ "$ENABLE_SNAPSHOTS" = true ]; then
  UNIT_SCHEME="KernTextKitSnapshots"
elif [ "$ENABLE_EXHAUSTIVE" = true ]; then
  UNIT_SCHEME="KernTextKitExhaustive"
fi

UI_SCHEME="KernTextKitUI"
if [ "$ENABLE_EXHAUSTIVE" = true ]; then
  UI_SCHEME="KernTextKitUIExhaustive"
fi

NEED_XCODEGEN=true
if [ "$SKIP_XCODEGEN" = true ]; then
  NEED_XCODEGEN=false
fi
if [ -f "KernTextKit.xcodeproj/project.pbxproj" ] && [ "KernTextKit.xcodeproj/project.pbxproj" -nt "project.yml" ]; then
  NEED_XCODEGEN=false
fi

if [ "$NEED_XCODEGEN" = true ]; then
  echo "▸ Generating Xcode project (xcodegen)..."
  xcodegen 2>&1 | tail -1
else
  echo "▸ Skipping xcodegen (project up-to-date)."
fi

echo ""

if [ "$RUN_UNIT" = true ]; then
  if [ "$RECORD_SNAPSHOTS" = true ]; then
    # SnapshotTesting intentionally fails tests while recording, so we:
    # 1) run record mode (expected failure, but writes baselines)
    # 2) re-run in verify mode (must pass)
    if [ "$ENABLE_EXHAUSTIVE" = true ]; then
      VERIFY_SCHEME="KernTextKitSnapshotsExhaustive"
    else
      VERIFY_SCHEME="KernTextKitSnapshots"
    fi

    echo "▸ Recording snapshot baselines (scheme: $UNIT_SCHEME)..."
    set +e
    xcodebuild \
      -project KernTextKit.xcodeproj \
      -scheme "$UNIT_SCHEME" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -resultBundlePath "$OUT_DIR/KernTextKitTests.record.xcresult" \
      test \
      2>&1 | tee "$OUT_DIR/unit-record.log"
    RECORD_STATUS=${PIPESTATUS[0]}
    set -e
    echo "  (record mode exit $RECORD_STATUS is expected)"
    echo ""

    echo "▸ Verifying snapshots (scheme: $VERIFY_SCHEME)..."
    set +e
    xcodebuild \
      -project KernTextKit.xcodeproj \
      -scheme "$VERIFY_SCHEME" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -resultBundlePath "$OUT_DIR/KernTextKitTests.xcresult" \
      test \
      2>&1 | tee "$OUT_DIR/unit.log"
    UNIT_STATUS=${PIPESTATUS[0]}
    set -e
    if [ $UNIT_STATUS -ne 0 ]; then
      echo "Snapshot verification failed (exit $UNIT_STATUS). See: $OUT_DIR/unit.log" >&2
      exit $UNIT_STATUS
    fi
    echo "  ✓ Snapshot verification passed"
    echo ""
  else
    echo "▸ Running unit tests (scheme: $UNIT_SCHEME)..."
    set +e
    xcodebuild \
      -project KernTextKit.xcodeproj \
      -scheme "$UNIT_SCHEME" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -resultBundlePath "$OUT_DIR/KernTextKitTests.xcresult" \
      test \
      2>&1 | tee "$OUT_DIR/unit.log"
    UNIT_STATUS=${PIPESTATUS[0]}
    set -e
    if [ $UNIT_STATUS -ne 0 ]; then
      echo "Unit tests failed (exit $UNIT_STATUS). See: $OUT_DIR/unit.log" >&2
      exit $UNIT_STATUS
    fi
    echo "  ✓ Unit tests passed"
    echo ""
  fi
fi

if [ "$RUN_UI" = true ]; then
  echo "▸ Running UI tests (scheme: $UI_SCHEME)..."
  echo "  Preflight: Ensure the Mac is unlocked and Automation permissions are granted."

  set +e
  UI_SCREENSHOT_DIR="$OUT_DIR/ui-screenshots"
  mkdir -p "$UI_SCREENSHOT_DIR"

  env KERN_UI_SCREENSHOT_DIR="$UI_SCREENSHOT_DIR" xcodebuild \
    -project KernTextKit.xcodeproj \
    -scheme "$UI_SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$OUT_DIR/KernTextKitUI.xcresult" \
    test \
    2>&1 | tee "$OUT_DIR/ui.log"
  UI_STATUS=${PIPESTATUS[0]}
  set -e

  if [ $UI_STATUS -ne 0 ]; then
    echo "UI tests failed (exit $UI_STATUS). See: $OUT_DIR/ui.log" >&2
  else
    echo "  ✓ UI tests passed"
  fi

  echo ""
  ALWAYS_EXPORT_ATTACHMENTS=false
  if [ "${KERN_EXPORT_UI_ATTACHMENTS:-}" = "1" ] || [ "$EXPORT_UI_ATTACHMENTS" = true ]; then
    ALWAYS_EXPORT_ATTACHMENTS=true
  fi

  if [ $UI_STATUS -ne 0 ] || [ "$ALWAYS_EXPORT_ATTACHMENTS" = true ]; then
    echo "▸ Exporting UI test attachments (screenshots/logs)..."
    ATT_DIR="$OUT_DIR/ui-attachments"
    mkdir -p "$ATT_DIR"
    xcrun xcresulttool export attachments \
      --path "$OUT_DIR/KernTextKitUI.xcresult" \
      --output-path "$ATT_DIR" \
      2>&1 | tee "$OUT_DIR/xcresult-attachments.log" >/dev/null || true
    # xcresulttool can export screenshots as HEIC depending on Xcode/macOS.
    # Convert to PNG for tooling compatibility (keeps original .heic files).
    if ls "$ATT_DIR"/*.heic "$ATT_DIR"/*.HEIC >/dev/null 2>&1; then
      "$(pwd)/scripts/convert-heic-to-png.sh" "$ATT_DIR" >/dev/null || true
    fi
    echo "  Attachments: $ATT_DIR"
  else
    echo "▸ Skipping UI attachment export (set KERN_EXPORT_UI_ATTACHMENTS=1 or pass --export-ui-attachments)"
  fi

  if [ $UI_STATUS -ne 0 ]; then
    exit $UI_STATUS
  fi
fi

echo "All selected test suites completed."
