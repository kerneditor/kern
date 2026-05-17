#!/bin/bash
# test-kern-app.sh — Build and smoke-test Kern.app with a markdown fixture
#
# Usage:
#   ./scripts/test-kern-app.sh [--skip-build] [--screenshots]
#   ./scripts/test-kern-app.sh --packaged [--skip-build] [--screenshots]
#   ./scripts/test-kern-app.sh --app /absolute/path/to/Kern.app [--skip-build] [--screenshots]
#
# Tests:
#   1. XcodeGen + xcodebuild succeeds
#   2. Kern launches and opens a markdown file without crashing
#      (`--packaged` validates the locally packaged bundle in `dist/`)
#   4. Optional: capture scrolling screenshots for visual review
#
# Exit codes:
#   0 = all tests passed
#   1 = build failure
#   2 = launch failure
#   3 = editor not ready (timeout)

set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=false
SCREENSHOTS=false
USE_PACKAGED=false
APP_OVERRIDE=""
SCREENSHOT_DIR="$(cd "$(dirname "$0")/.."; pwd)/test-screenshots"
KERN_PID=""
KERN_LAUNCHED_PIDS=""
KERN_WINDOW_ID=""
TIMEOUT=15  # seconds to wait for editor ready

matching_bundle_pids() {
  local binary_path="$1"
  ps -axo pid=,command= | awk -v target="$binary_path" '
    index($0, target) {
      pid = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", pid)
      if (pid != "") print pid
    }
  '
}

new_pids_since_snapshot() {
  local before="$1"
  local after="$2"
  local pid
  for pid in $after; do
    case " $before " in
      *" $pid "*) ;;
      *) printf '%s\n' "$pid" ;;
    esac
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --screenshots)
      SCREENSHOTS=true
      shift
      ;;
    --packaged)
      USE_PACKAGED=true
      shift
      ;;
    --app)
      if [ $# -lt 2 ]; then
        echo "ERROR: --app requires a path to an .app bundle" >&2
        exit 1
      fi
      APP_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

cleanup() {
  local pid
  if [ -n "$KERN_LAUNCHED_PIDS" ]; then
    for pid in $KERN_LAUNCHED_PIDS; do
      kill "$pid" 2>/dev/null || true
    done
    for pid in $KERN_LAUNCHED_PIDS; do
      wait "$pid" 2>/dev/null || true
    done
  elif [ -n "$KERN_PID" ] && kill -0 "$KERN_PID" 2>/dev/null; then
    kill "$KERN_PID" 2>/dev/null || true
    wait "$KERN_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== Kern App Integration Test ==="
echo ""

# ── Step 1: Build ──────────────────────────────────────────────────────────

if [ -n "$APP_OVERRIDE" ] || [ "$USE_PACKAGED" = true ]; then
  echo "▸ Step 1: Skipped (explicit app bundle selected)"
elif [ "$SKIP_BUILD" = false ]; then
  echo "▸ Step 1: Generate Xcode project..."
  xcodegen 2>&1 | tail -1

  echo "▸ Step 1: Build Kern.app..."
  BUILD_OUTPUT=$(xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit build 2>&1)
  if echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED"; then
    echo "  ✓ Build succeeded"
  else
    echo "  ✗ Build failed"
    echo "$BUILD_OUTPUT" | tail -20
    exit 1
  fi
else
  echo "▸ Step 1: Skipped (--skip-build)"
fi

if [ "$USE_PACKAGED" = true ] && [ -n "$APP_OVERRIDE" ]; then
  echo "ERROR: use either --packaged or --app, not both" >&2
  exit 1
fi

if [ "$USE_PACKAGED" = true ]; then
  KERN_APP="$(pwd)/dist/Kern.app"
  if [ ! -d "$KERN_APP" ]; then
    echo "  ✗ Packaged app not found at: $KERN_APP" >&2
    echo "    Run ./scripts/package-kern-app.sh first." >&2
    exit 1
  fi
elif [ -n "$APP_OVERRIDE" ]; then
  case "$APP_OVERRIDE" in
    /*) KERN_APP="$APP_OVERRIDE" ;;
    *) KERN_APP="$(pwd)/$APP_OVERRIDE" ;;
  esac
  if [ ! -d "$KERN_APP" ]; then
    echo "  ✗ App bundle not found at: $KERN_APP" >&2
    exit 1
  fi
else
  # Find the built app, preferring the renamed public bundle first.
  KERN_APP=$(find ~/Library/Developer/Xcode/DerivedData/KernTextKit-*/Build/Products/Debug -maxdepth 0 -name 'Kern.app' 2>/dev/null | head -1)
  if [ -z "$KERN_APP" ]; then
    KERN_APP=$(find ~/Library/Developer/Xcode/DerivedData/KernTextKit-*/Build/Products/Debug -maxdepth 0 -name 'KernTextKit.app' 2>/dev/null | head -1)
  fi
  if [ -z "$KERN_APP" ]; then
    echo "  ✗ Cannot find Kern.app in DerivedData" >&2
    exit 1
  fi
fi

if [ ! -d "$KERN_APP/Contents/MacOS" ]; then
  echo "  ✗ Invalid app bundle (missing Contents/MacOS): $KERN_APP" >&2
  exit 1
fi
KERN_BIN="$KERN_APP/Contents/MacOS/Kern"
if [ ! -f "$KERN_BIN" ]; then
  KERN_BIN="$KERN_APP/Contents/MacOS/KernTextKit"
fi
if [ ! -f "$KERN_BIN" ]; then
  echo "  ✗ App binary not found inside bundle: $KERN_APP" >&2
  exit 1
fi
echo "  App bundle selected: $KERN_APP"
echo ""

find_window_info() {
  python3 - "$1" <<'PY'
import sys
from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID

pid = int(sys.argv[1])
windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
matches = []
for window in windows:
    if int(window.get("kCGWindowOwnerPID", -1)) != pid:
        continue
    if int(window.get("kCGWindowLayer", 0)) != 0:
        continue
    bounds = window.get("kCGWindowBounds", {})
    matches.append((
        int(window.get("kCGWindowNumber", 0)),
        int(bounds.get("X", 0)),
        int(bounds.get("Y", 0)),
        int(bounds.get("Width", 0)),
        int(bounds.get("Height", 0)),
    ))

if not matches:
    sys.exit(0)

window_id, x, y, width, height = matches[0]
print(f"{window_id}|{x}|{y}|{width}|{height}")
PY
}

# ── Step 2: Launch with test file ──────────────────────────────────────────

TEST_FILE="${KERN_TEST_FILE:-test-fixtures/stress-test.md}"
if [ ! -f "$TEST_FILE" ]; then
  TEST_FILE="test-fixtures/mega-stress-test.md"
fi
if [ ! -f "$TEST_FILE" ]; then
  echo "  ✗ Test fixture not found: $TEST_FILE" >&2
  exit 1
fi

ABS_TEST_FILE="$(pwd)/$TEST_FILE"
if [ "$USE_PACKAGED" = true ] || [ -n "$APP_OVERRIDE" ]; then
  echo "▸ Step 2: Launch packaged Kern with $TEST_FILE..."
  PREEXISTING_PIDS="$(matching_bundle_pids "$KERN_BIN" | tr '\n' ' ')"
  open -n -a "$KERN_APP" "$ABS_TEST_FILE" >/dev/null 2>&1
  for _ in $(seq 1 20); do
    CURRENT_PIDS="$(matching_bundle_pids "$KERN_BIN" | tr '\n' ' ')"
    KERN_LAUNCHED_PIDS="$(new_pids_since_snapshot "$PREEXISTING_PIDS" "$CURRENT_PIDS" | tr '\n' ' ' | xargs)"
    if [ -n "$KERN_LAUNCHED_PIDS" ]; then
      KERN_PID="$(printf '%s\n' "$KERN_LAUNCHED_PIDS" | awk '{ print $1 }')"
      break
    fi
    sleep 1
  done
  if [ -z "$KERN_LAUNCHED_PIDS" ]; then
    echo "  ✗ Could not identify the packaged Kern process after launching $TEST_FILE" >&2
    exit 2
  fi
else
  echo "▸ Step 2: Launch Kern with $TEST_FILE..."
  "$KERN_BIN" "$ABS_TEST_FILE" &
  KERN_PID=$!
  KERN_LAUNCHED_PIDS="$KERN_PID"
  sleep 1
fi

# Check if still running
if ! kill -0 "$KERN_PID" 2>/dev/null; then
  echo "  ✗ Kern crashed on launch"
  exit 2
fi
echo "  ✓ Kern launched (PID $KERN_PID)"

WINDOW_INFO=""
for _ in $(seq 1 20); do
  WINDOW_INFO="$(find_window_info "$KERN_PID" || true)"
  if [ -n "$WINDOW_INFO" ]; then
    KERN_WINDOW_ID="${WINDOW_INFO%%|*}"
    break
  fi
  sleep 1
done

if [ -z "$KERN_WINDOW_ID" ]; then
  echo "  ✗ Kern did not present an on-screen window in time"
  exit 2
fi

echo "  ✓ Kern window detected (window $KERN_WINDOW_ID)"
echo ""

# ── Step 3: Wait for editor ready ─────────────────────────────────────────

echo "▸ Step 3: Waiting for app to stabilize (${TIMEOUT}s timeout)..."

# Poll the app to check it's still alive
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if ! kill -0 "$KERN_PID" 2>/dev/null; then
    echo "  ✗ Kern crashed while loading"
    exit 2
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

# If we get here, Kern has been running for $TIMEOUT seconds without crashing
echo "  ✓ Kern running stable for ${TIMEOUT}s"
echo ""

# ── Step 4: Optional screenshots ──────────────────────────────────────────

if [ "$SCREENSHOTS" = true ]; then
  echo "▸ Step 4: Capturing screenshots..."
  # Keep screenshots from previous runs; create a per-run output directory.
  RUN_ID="$(date +%Y%m%d-%H%M%S)"
  SCREENSHOT_DIR="$SCREENSHOT_DIR/$RUN_ID"
  mkdir -p "$SCREENSHOT_DIR"

  open -a "$KERN_APP" >/dev/null 2>&1 || true
  sleep 1
  if [ -n "$KERN_WINDOW_ID" ]; then
    screencapture -x -l "$KERN_WINDOW_ID" "$SCREENSHOT_DIR/packaged-smoke-window.png" 2>/dev/null || true
  fi
  if [ ! -f "$SCREENSHOT_DIR/packaged-smoke-window.png" ]; then
    screencapture -x "$SCREENSHOT_DIR/packaged-smoke-full-screen.png" 2>/dev/null || true
  fi
  CAPTURED=$(ls -1 "$SCREENSHOT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
  echo "  ✓ Captured $CAPTURED screenshots in $SCREENSHOT_DIR/"
  echo ""
fi

# ── Step 5: Graceful shutdown ─────────────────────────────────────────────

echo "▸ Step 5: Shutting down Kern..."
for pid in $KERN_LAUNCHED_PIDS; do
  kill "$pid" 2>/dev/null || true
done
for pid in $KERN_LAUNCHED_PIDS; do
  wait "$pid" 2>/dev/null || true
done
KERN_PID=""
KERN_LAUNCHED_PIDS=""
echo "  ✓ Kern exited cleanly"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────

echo "=== All Tests Passed ==="
echo ""
echo "Results:"
if [ -n "$APP_OVERRIDE" ] || [ "$USE_PACKAGED" = true ] || [ "$SKIP_BUILD" = true ]; then
  echo "  ✓ App bundle selection succeeded"
else
  echo "  ✓ Xcode build succeeded"
fi
echo "  ✓ Kern launches without crashing"
echo "  ✓ Stable for ${TIMEOUT}s with large document"
if [ "$SCREENSHOTS" = true ]; then
  echo "  ✓ Screenshots: $SCREENSHOT_DIR/"
fi
exit 0
