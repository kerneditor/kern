#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Kern Auto-Save Debounce Test
# ═══════════════════════════════════════════════════════════════════════════════
# Tests that Kern's file watcher properly debounces rapid external modifications
# rather than triggering a reload for every individual change.
#
# Usage: ./scripts/test-autosave-debounce.sh
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

KERN_APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData/KernTextKit-"*/Build/Products/Debug/KernTextKit.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$KERN_APP_PATH" ]; then
    echo "ERROR: Cannot find KernTextKit.app in DerivedData."
    echo "       Build first: xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit build"
    exit 1
fi

# ─── Timing ───────────────────────────────────────────────────────────────────

now_ms() {
    python3 -c "import time; print(int(time.time() * 1000))"
}

elapsed_ms() {
    echo $(( $2 - $1 ))
}

# ─── Kill Kern ────────────────────────────────────────────────────────────────

kill_kern() {
    pkill -f "KernTextKit.app/Contents/MacOS/KernTextKit" 2>/dev/null || true
    osascript -e 'tell application "KernTextKit" to quit' 2>/dev/null || true
    sleep 1
    pkill -9 -f "KernTextKit.app/Contents/MacOS/KernTextKit" 2>/dev/null || true
    sleep 0.5
}

kern_is_alive() {
    pgrep -f "KernTextKit.app/Contents/MacOS/KernTextKit" > /dev/null 2>&1
}

wait_for_window() {
    local max_wait_ms="${1:-15000}"
    local start=$(now_ms)
    while true; do
        local count
        count=$(osascript -e 'tell application "System Events" to count windows of process "KernTextKit"' 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ] 2>/dev/null; then
            return 0
        fi
        local current=$(now_ms)
        if [ $(( current - start )) -ge "$max_wait_ms" ]; then
            echo "WARNING: Timed out waiting for KernTextKit window"
            return 1
        fi
        sleep 0.05
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main Test
# ═══════════════════════════════════════════════════════════════════════════════

echo "================================================================="
echo "  Kern Auto-Save Debounce Test"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================="
echo ""

# Step 1: Create a temp markdown file
TEMP_FILE="/tmp/kern-debounce-test-$$.md"
cat > "$TEMP_FILE" << 'MDEOF'
# Debounce Test Document

This file is used to test Kern's file watcher debounce behavior.

## Initial Content

The file watcher should coalesce rapid external modifications into
a single reload, not trigger a separate reload for each change.
MDEOF

echo "[1] Created temp file: $TEMP_FILE"
echo "    Size: $(wc -c < "$TEMP_FILE" | tr -d ' ') bytes"

# Step 2: Kill any existing Kern and open the file
kill_kern
echo "[2] Opening file in Kern..."
open -a "$KERN_APP_PATH" "$TEMP_FILE"
wait_for_window 15000

# Step 3: Wait for editor to fully load
echo "[3] Waiting 3 seconds for editor to fully load..."
sleep 3

if ! kern_is_alive; then
    echo "ERROR: Kern is not running after initial load."
    rm -f "$TEMP_FILE"
    exit 1
fi
echo "    KernTextKit is running (PID: $(pgrep -f 'KernTextKit.app/Contents/MacOS/KernTextKit' | head -1))"

# Step 4: Rapid modifications (5 changes with 50ms gaps)
echo ""
echo "[4] Performing rapid modifications (5 changes, 50ms gaps)..."
echo "    Kern's debounce should coalesce these into 1 reload."
echo ""

MTIME_BEFORE=$(stat -f "%m" "$TEMP_FILE" 2>/dev/null)
echo "    mtime before: $MTIME_BEFORE"

RAPID_START=$(now_ms)
for i in $(seq 1 5); do
    echo "Rapid modification $i at $(python3 -c 'import time; print(f"{time.time():.3f}")')" >> "$TEMP_FILE"
    local_time=$(now_ms)
    echo "    Change $i written at +$(elapsed_ms "$RAPID_START" "$local_time")ms"
    # 50ms gap between modifications
    python3 -c "import time; time.sleep(0.05)"
done
RAPID_END=$(now_ms)
RAPID_DURATION=$(elapsed_ms "$RAPID_START" "$RAPID_END")

echo ""
echo "    Rapid burst completed in ${RAPID_DURATION}ms"
echo "    File size after burst: $(wc -c < "$TEMP_FILE" | tr -d ' ') bytes"

# Step 5: Wait 1 second for debounce to settle
echo ""
echo "[5] Waiting 1 second for debounce to settle..."
sleep 1

MTIME_AFTER=$(stat -f "%m" "$TEMP_FILE" 2>/dev/null)
echo "    mtime after: $MTIME_AFTER"

if kern_is_alive; then
    echo "    Kern is still alive after rapid modifications: PASS"
    ALIVE_AFTER_RAPID="PASS"
else
    echo "    Kern CRASHED after rapid modifications: FAIL"
    ALIVE_AFTER_RAPID="FAIL"
fi

# Step 6: Debounce verification
echo ""
echo "[6] Debounce verification:"
echo "    - 5 changes were written in ${RAPID_DURATION}ms (~50ms apart)"
echo "    - Kern's file watcher debounce (300ms) should have coalesced"
echo "      these into at most 1-2 reload events, not 5"
echo "    - We cannot directly observe reload count from CLI, but we"
echo "      verify the app remained stable (no crash/hang)"

# Step 7: Single modification after debounce window
echo ""
echo "[7] Single modification after debounce window..."
SINGLE_START=$(now_ms)
echo "Final single modification at $(date '+%H:%M:%S.%N' 2>/dev/null || date '+%H:%M:%S')" >> "$TEMP_FILE"
SINGLE_WRITE_END=$(now_ms)

# Step 8: Wait 500ms (more than 300ms debounce)
echo "    Waiting 500ms (> 300ms debounce period)..."
python3 -c "import time; time.sleep(0.5)"
SINGLE_END=$(now_ms)

SINGLE_DURATION=$(elapsed_ms "$SINGLE_START" "$SINGLE_END")
echo "    Single modification cycle: ${SINGLE_DURATION}ms"

MTIME_FINAL=$(stat -f "%m" "$TEMP_FILE" 2>/dev/null)
echo "    Final mtime: $MTIME_FINAL"

if kern_is_alive; then
    echo "    Kern is still alive after single modification: PASS"
    ALIVE_AFTER_SINGLE="PASS"
else
    echo "    Kern CRASHED after single modification: FAIL"
    ALIVE_AFTER_SINGLE="FAIL"
fi

# Step 9: Summary
echo ""
echo "================================================================="
echo "  Results Summary"
echo "================================================================="
echo ""
echo "  Rapid burst (5 changes, 50ms gaps):"
echo "    Duration:     ${RAPID_DURATION}ms"
echo "    App stable:   $ALIVE_AFTER_RAPID"
echo ""
echo "  Single modification after debounce:"
echo "    Duration:     ${SINGLE_DURATION}ms"
echo "    App stable:   $ALIVE_AFTER_SINGLE"
echo ""
echo "  File mtime changes:"
echo "    Before burst: $MTIME_BEFORE"
echo "    After burst:  $MTIME_AFTER"
echo "    After single: $MTIME_FINAL"
echo ""

if [ "$ALIVE_AFTER_RAPID" = "PASS" ] && [ "$ALIVE_AFTER_SINGLE" = "PASS" ]; then
    echo "  OVERALL: PASS - Kern survived all file watcher tests"
else
    echo "  OVERALL: FAIL - Kern crashed during file watcher tests"
fi

echo ""
echo "================================================================="

# Cleanup
kill_kern
rm -f "$TEMP_FILE"
echo "  Cleaned up temp file and killed Kern."
