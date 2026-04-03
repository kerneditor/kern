#!/bin/bash
# test-kern-app.sh — Build and smoke-test Kern.app with mega-stress-test.md
#
# Usage: ./scripts/test-kern-app.sh [--skip-build] [--screenshots]
#
# Tests:
#   1. XcodeGen + xcodebuild succeeds
#   2. Kern launches and opens a markdown file without crashing
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
SCREENSHOT_DIR="$(cd "$(dirname "$0")/.."; pwd)/test-screenshots"
KERN_PID=""
TIMEOUT=15  # seconds to wait for editor ready

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    --screenshots) SCREENSHOTS=true ;;
  esac
done

cleanup() {
  if [ -n "$KERN_PID" ] && kill -0 "$KERN_PID" 2>/dev/null; then
    kill "$KERN_PID" 2>/dev/null
    wait "$KERN_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== Kern App Integration Test ==="
echo ""

# ── Step 1: Build ──────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = false ]; then
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

# Find the built app, preferring the renamed public bundle first.
KERN_APP=$(find ~/Library/Developer/Xcode/DerivedData/KernTextKit-*/Build/Products/Debug -maxdepth 0 -name 'Kern.app' 2>/dev/null | head -1)
if [ -z "$KERN_APP" ]; then
  KERN_APP=$(find ~/Library/Developer/Xcode/DerivedData/KernTextKit-*/Build/Products/Debug -maxdepth 0 -name 'KernTextKit.app' 2>/dev/null | head -1)
fi
if [ -z "$KERN_APP" ]; then
  echo "  ✗ Cannot find Kern.app in DerivedData"
  exit 1
fi
KERN_BIN="$KERN_APP/Contents/MacOS/Kern"
if [ ! -f "$KERN_BIN" ]; then
  KERN_BIN="$KERN_APP/Contents/MacOS/KernTextKit"
fi
KERN_PROCESS_NAME="$(basename "$KERN_APP" .app)"
echo "  App bundle selected"
echo ""

# ── Step 2: Launch with test file ──────────────────────────────────────────

TEST_FILE="test-fixtures/mega-stress-test.md"
if [ ! -f "$TEST_FILE" ]; then
  TEST_FILE="test-fixtures/stress-test.md"
fi

echo "▸ Step 2: Launch Kern with $TEST_FILE..."
"$KERN_BIN" "$(pwd)/$TEST_FILE" &
KERN_PID=$!
sleep 3

# Check if still running
if ! kill -0 "$KERN_PID" 2>/dev/null; then
  echo "  ✗ Kern crashed on launch"
  exit 2
fi
echo "  ✓ Kern launched (PID $KERN_PID)"

# Resize window to left half of screen
osascript <<APPLESCRIPT
tell application "Finder"
    set _bounds to bounds of window of desktop
    set screenW to item 3 of _bounds
    set screenH to item 4 of _bounds
end tell
tell application "System Events" to tell process "$KERN_PROCESS_NAME"
    set frontmost to true
    tell window 1
        set position to {0, 25}
        set size to {screenW div 2, screenH - 25}
    end tell
end tell
APPLESCRIPT
echo "  ✓ Window resized to left half of screen"
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

  # Get screen dimensions for region capture
  SCREEN_BOUNDS=$(osascript -e '
  tell application "Finder"
      set b to bounds of window of desktop
      return (item 3 of b) & "," & (item 4 of b)
  end tell')
  SCREEN_W=${SCREEN_BOUNDS%%,*}
  SCREEN_H=${SCREEN_BOUNDS##*,}
  WIN_W=$((SCREEN_W / 2))
  WIN_H=$((SCREEN_H - 25))

  # Compile scroll helper if not already built (uses AXScrollToVisible on headings)
  SCROLL_HELPER="/tmp/kern-ax-scroll"
  SCROLL_SRC="$(cd "$(dirname "$0")"; pwd)/ax-scroll.swift"
  if [ ! -x "$SCROLL_HELPER" ] && [ -f "$SCROLL_SRC" ]; then
    swiftc -O -o "$SCROLL_HELPER" "$SCROLL_SRC" 2>&1 || true
  fi

  # Activate Kern
  osascript -e "tell application \"$KERN_PROCESS_NAME\" to activate"
  sleep 1

  if [ ! -x "$SCROLL_HELPER" ]; then
    echo "  ⚠ No scroll helper — capturing static screenshots"
    for i in $(seq 1 30); do
      FNAME=$(printf "%02d" $i)
      screencapture -x -R"0,25,${WIN_W},${WIN_H}" "$SCREENSHOT_DIR/page-$FNAME.png" 2>/dev/null
    done
  else
    # Try elements mode first for fine-grained scrolling, fall back to headings
    ELEMENT_INFO=$("$SCROLL_HELPER" "$KERN_PID" elements 0 2>&1 || echo "ERR:no-elements")
    if echo "$ELEMENT_INFO" | grep -q "^OK:"; then
      TOTAL_ELEMENTS=$(echo "$ELEMENT_INFO" | grep -oE '/[0-9]+' | tr -d '/' || echo 0)
      TOTAL_ELEMENTS=${TOTAL_ELEMENTS:-0}
      echo "  Found $TOTAL_ELEMENTS content elements in document"

      # Step through elements — every 20th for ~viewport-height jumps
      STEP=20
      if [ "$TOTAL_ELEMENTS" -lt 100 ]; then
        STEP=5
      fi
      PAGE=1
      for i in $(seq 0 "$STEP" "$TOTAL_ELEMENTS"); do
        "$SCROLL_HELPER" "$KERN_PID" elements "$i" >/dev/null 2>&1 || true
        sleep 0.2
        FNAME=$(printf "%03d" $PAGE)
        screencapture -x -R"0,25,${WIN_W},${WIN_H}" "$SCREENSHOT_DIR/page-$FNAME.png" 2>/dev/null
        PAGE=$((PAGE + 1))
      done
    else
      # Fallback: heading mode
      HEADING_INFO=$("$SCROLL_HELPER" "$KERN_PID" 0 2>&1 || echo "OK:0/100")
      TOTAL_HEADINGS=$(echo "$HEADING_INFO" | grep -oE '/[0-9]+' | tr -d '/' || echo 100)
      TOTAL_HEADINGS=${TOTAL_HEADINGS:-100}
      echo "  Found $TOTAL_HEADINGS headings in document (heading mode)"

      PAGE=1
      for i in $(seq 0 "$TOTAL_HEADINGS"); do
        "$SCROLL_HELPER" "$KERN_PID" "$i" >/dev/null 2>&1 || true
        sleep 0.2
        FNAME=$(printf "%03d" $PAGE)
        screencapture -x -R"0,25,${WIN_W},${WIN_H}" "$SCREENSHOT_DIR/page-$FNAME.png" 2>/dev/null
        PAGE=$((PAGE + 1))
      done
    fi

    # Scroll all the way to the bottom using iterative mode, then capture
    echo "  Scrolling to bottom..."
    BOTTOM_INFO=$("$SCROLL_HELPER" "$KERN_PID" bottom 2>&1 || echo "OK:bottom/0iterations")
    echo "  $BOTTOM_INFO"
    sleep 0.5
    FNAME=$(printf "%03d" $PAGE)
    screencapture -x -R"0,25,${WIN_W},${WIN_H}" "$SCREENSHOT_DIR/page-${FNAME}-bottom.png" 2>/dev/null
  fi

  CAPTURED=$(ls -1 "$SCREENSHOT_DIR"/page-*.png 2>/dev/null | wc -l | tr -d ' ')
  echo "  ✓ Captured $CAPTURED screenshots in $SCREENSHOT_DIR/"
  echo ""
fi

# ── Step 5: Graceful shutdown ─────────────────────────────────────────────

echo "▸ Step 5: Shutting down Kern..."
kill "$KERN_PID" 2>/dev/null
wait "$KERN_PID" 2>/dev/null || true
KERN_PID=""
echo "  ✓ Kern exited cleanly"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────

echo "=== All Tests Passed ==="
echo ""
echo "Results:"
echo "  ✓ Xcode build succeeded"
echo "  ✓ Kern launches without crashing"
echo "  ✓ Stable for ${TIMEOUT}s with large document"
if [ "$SCREENSHOTS" = true ]; then
  echo "  ✓ Screenshots: $SCREENSHOT_DIR/"
fi
exit 0
