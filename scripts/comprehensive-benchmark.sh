#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# KernTextKit Comprehensive Benchmark Script
# ═══════════════════════════════════════════════════════════════════════════════
# Tests cold start, multi-tab open, memory, file open latency, auto-save/file
# watcher debounce, and rapid tab switching.
#
# Usage: ./scripts/comprehensive-benchmark.sh
#
# Results are saved to: test-fixtures/benchmark-results.md
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$PROJECT_DIR/test-fixtures"
TABS_DIR="$FIXTURES_DIR/tabs"
RESULTS_FILE="$FIXTURES_DIR/benchmark-results.md"
STRESS_FILE="$FIXTURES_DIR/stress-test.md"
MEGA_STRESS_FILE="$FIXTURES_DIR/mega-stress-test.md"

# Find KernTextKit.app from DerivedData
KERN_APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData/KernTextKit-"*/Build/Products/Debug/KernTextKit.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$KERN_APP_PATH" ]; then
    echo "ERROR: Cannot find KernTextKit.app in DerivedData."
    echo "       Build first: xcodebuild -project KernTextKit.xcodeproj -scheme KernTextKit build"
    exit 1
fi

KERN_BINARY="$KERN_APP_PATH/Contents/MacOS/KernTextKit"
KERN_NAME="KernTextKit"

RUNS=3
SMALL_FILE=""
MEDIUM_FILE=""
LARGE_FILE=""

# ─── Timing Function ─────────────────────────────────────────────────────────
# Uses python3 for millisecond precision since macOS date doesn't support %N

now_ms() {
    python3 -c "import time; print(int(time.time() * 1000))"
}

now_s() {
    python3 -c "import time; print(f'{time.time():.3f}')"
}

elapsed_ms() {
    local start_ms="$1"
    local end_ms="$2"
    echo $(( end_ms - start_ms ))
}

elapsed_s() {
    python3 -c "print(f'{($2 - $1) / 1000:.3f}')" 2>/dev/null || echo "scale=3; ($2 - $1) / 1000" | bc
}

average_ms() {
    local vals="$1"
    python3 -c "
vals = [int(v) for v in '$vals'.split() if v.strip() and v != 'timeout']
if vals:
    print(int(sum(vals) / len(vals)))
else:
    print('timeout')
"
}

ms_to_s() {
    python3 -c "print(f'{int(\"$1\") / 1000:.3f}')" 2>/dev/null || echo "error"
}

# ─── Kill Kern ────────────────────────────────────────────────────────────────

kill_kern() {
    pkill -f "KernTextKit.app/Contents/MacOS/KernTextKit" 2>/dev/null || true
    osascript -e 'tell application "KernTextKit" to quit' 2>/dev/null || true
    sleep 1
    pkill -9 -f "KernTextKit.app/Contents/MacOS/KernTextKit" 2>/dev/null || true
    sleep 0.5
}

# ─── Wait for Kern process to be running ──────────────────────────────────────

wait_for_process() {
    local max_wait_ms="${1:-10000}"
    local start=$(now_ms)
    while true; do
        if pgrep -f "KernTextKit.app/Contents/MacOS/KernTextKit" > /dev/null 2>&1; then
            local end=$(now_ms)
            echo $(elapsed_ms "$start" "$end")
            return 0
        fi
        local current=$(now_ms)
        if [ $(( current - start )) -ge "$max_wait_ms" ]; then
            echo "timeout"
            return 1
        fi
        sleep 0.05
    done
}

# ─── Wait for Kern window to appear ──────────────────────────────────────────

wait_for_window() {
    local max_wait_ms="${1:-15000}"
    local start=$(now_ms)
    while true; do
        local count
        count=$(osascript -e 'tell application "System Events" to count windows of process "KernTextKit"' 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ] 2>/dev/null; then
            local end=$(now_ms)
            echo $(elapsed_ms "$start" "$end")
            return 0
        fi
        local current=$(now_ms)
        if [ $(( current - start )) -ge "$max_wait_ms" ]; then
            echo "timeout"
            return 1
        fi
        sleep 0.05
    done
}

# ─── Get Kern PID ────────────────────────────────────────────────────────────

get_kern_pid() {
    pgrep -f "KernTextKit.app/Contents/MacOS/KernTextKit" 2>/dev/null | head -1
}

# ─── Get memory in MB ────────────────────────────────────────────────────────

get_memory_mb() {
    local pid="$1"
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    local rss
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$rss" ] || [ "$rss" = "0" ]; then
        echo "0"
        return
    fi
    python3 -c "print(f'{int(\"$rss\") / 1024:.1f}')"
}

# ─── Check if Kern is still alive ────────────────────────────────────────────

kern_is_alive() {
    pgrep -f "KernTextKit.app/Contents/MacOS/KernTextKit" > /dev/null 2>&1
}

# ─── Generate Test Fixtures ──────────────────────────────────────────────────

generate_test_fixtures() {
    echo "[Setup] Generating test fixtures..."

    mkdir -p "$TABS_DIR"
    mkdir -p "$FIXTURES_DIR"

    # Generate tab files if they don't exist or are empty
    local tab_count
    tab_count=$(ls "$TABS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    if [ "$tab_count" -lt 55 ]; then
        echo "  Generating 55 tab files in $TABS_DIR..."
        for i in $(seq 1 55); do
            local padded
            padded=$(printf "%02d" "$i")
            local f="$TABS_DIR/tab-${padded}.md"
            cat > "$f" << TABEOF
# Tab $i - Test Document

This is test document number $i for the Kern benchmark suite.

## Content

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod
tempor incididunt ut labore et dolore magna aliqua.

### Code Block

\`\`\`javascript
function processTab${i}() {
    const items = Array.from({ length: 50 }, (_, idx) => ({
        id: idx,
        label: \`Item \${idx}\`,
        value: Math.random() * ${i}
    }));
    return items.filter(item => item.value > 0.5);
}
\`\`\`

### Table

| Property | Value |
|----------|-------|
| Tab Number | $i |
| Created | $(date '+%Y-%m-%d') |
| Purpose | Benchmark testing |

> This file is part of the Kern benchmark test fixtures.
TABEOF
        done
    fi

    # Generate mega stress test if it doesn't exist
    if [ ! -f "$MEGA_STRESS_FILE" ]; then
        echo "  Generating mega stress test file..."
        {
            echo "# Mega Stress Test Document"
            echo ""
            echo "This file is designed to stress-test the Kern editor with heavy content."
            echo ""
            for section in $(seq 1 100); do
                echo "## Section $section - Heavy Content Block"
                echo ""
                echo "Paragraph with **bold**, *italic*, ~~strikethrough~~, \`inline code\`, and [links](https://example.com/$section)."
                echo ""
                echo '```python'
                echo "class Section${section}Handler:"
                echo "    def __init__(self, data: list[dict]):"
                echo "        self.data = data"
                echo "        self.cache = {}"
                echo ""
                echo "    def process(self) -> dict:"
                echo "        results = {}"
                echo "        for item in self.data:"
                echo "            key = item.get('id', $section)"
                echo "            results[key] = self._transform(item)"
                echo "        return results"
                echo ""
                echo "    def _transform(self, item: dict) -> dict:"
                echo "        return {"
                echo "            'original': item,"
                echo "            'processed': True,"
                echo "            'section': $section,"
                echo "            'timestamp': '$(date -Iseconds)'"
                echo "        }"
                echo '```'
                echo ""
                if (( section % 5 == 0 )); then
                    echo "| Column A | Column B | Column C | Column D | Column E |"
                    echo "|----------|----------|----------|----------|----------|"
                    for row in $(seq 1 10); do
                        echo "| Row $row | Data $section-$row | Value $(( section * row )) | Status | Active |"
                    done
                    echo ""
                fi
                if (( section % 10 == 0 )); then
                    echo "- [ ] Task item $section-A: Review implementation"
                    echo "- [x] Task item $section-B: Write tests"
                    echo "- [ ] Task item $section-C: Update documentation"
                    echo ""
                    echo "1. First ordered item for section $section"
                    echo "2. Second ordered item with nested content"
                    echo "   - Nested bullet A"
                    echo "   - Nested bullet B"
                    echo "3. Third ordered item"
                    echo ""
                fi
                echo "---"
                echo ""
            done
        } > "$MEGA_STRESS_FILE"
    fi

    # Identify small/medium/large files
    SMALL_FILE="$TABS_DIR/tab-01.md"
    MEDIUM_FILE="$STRESS_FILE"
    LARGE_FILE="$MEGA_STRESS_FILE"

    local small_size medium_size large_size
    small_size=$(wc -c < "$SMALL_FILE" | tr -d ' ')
    medium_size=$(wc -c < "$MEDIUM_FILE" | tr -d ' ')
    large_size=$(wc -c < "$LARGE_FILE" | tr -d ' ')

    echo "  Small file:  $SMALL_FILE ($small_size bytes)"
    echo "  Medium file: $MEDIUM_FILE ($medium_size bytes)"
    echo "  Large file:  $LARGE_FILE ($large_size bytes)"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 1: Cold Start
# ═══════════════════════════════════════════════════════════════════════════════

benchmark_cold_start() {
    echo ""
    echo "================================================================="
    echo "  BENCHMARK 1: Cold Start"
    echo "================================================================="
    echo ""

    # Test A: No file
    echo "  [1a] Cold start with no file ($RUNS runs)"
    COLD_NOFILE_VALS=""
    for i in $(seq 1 "$RUNS"); do
        kill_kern
        sleep 1
        local start=$(now_ms)
        open -a "$KERN_APP_PATH"
        local process_time=$(wait_for_process 15000)
        local window_time=$(wait_for_window 15000)
        local end=$(now_ms)
        local total=$(elapsed_ms "$start" "$end")
        echo "    Run $i: process=${process_time}ms, window=${window_time}ms, total=${total}ms"
        COLD_NOFILE_VALS="$COLD_NOFILE_VALS $total"
        kill_kern
    done
    COLD_NOFILE_AVG=$(average_ms "$COLD_NOFILE_VALS")
    echo "    Average: ${COLD_NOFILE_AVG}ms ($(ms_to_s "$COLD_NOFILE_AVG")s)"

    # Test B: Small file
    echo ""
    echo "  [1b] Cold start with small file ($RUNS runs)"
    COLD_SMALL_VALS=""
    for i in $(seq 1 "$RUNS"); do
        kill_kern
        sleep 1
        local start=$(now_ms)
        open -a "$KERN_APP_PATH" "$SMALL_FILE"
        local window_time=$(wait_for_window 15000)
        local end=$(now_ms)
        local total=$(elapsed_ms "$start" "$end")
        echo "    Run $i: window=${window_time}ms, total=${total}ms"
        COLD_SMALL_VALS="$COLD_SMALL_VALS $total"
        kill_kern
    done
    COLD_SMALL_AVG=$(average_ms "$COLD_SMALL_VALS")
    echo "    Average: ${COLD_SMALL_AVG}ms ($(ms_to_s "$COLD_SMALL_AVG")s)"

    # Test C: Mega stress test
    echo ""
    echo "  [1c] Cold start with mega stress test ($RUNS runs)"
    COLD_MEGA_VALS=""
    for i in $(seq 1 "$RUNS"); do
        kill_kern
        sleep 1
        local start=$(now_ms)
        open -a "$KERN_APP_PATH" "$LARGE_FILE"
        local window_time=$(wait_for_window 20000)
        local end=$(now_ms)
        local total=$(elapsed_ms "$start" "$end")
        echo "    Run $i: window=${window_time}ms, total=${total}ms"
        COLD_MEGA_VALS="$COLD_MEGA_VALS $total"
        kill_kern
    done
    COLD_MEGA_AVG=$(average_ms "$COLD_MEGA_VALS")
    echo "    Average: ${COLD_MEGA_AVG}ms ($(ms_to_s "$COLD_MEGA_AVG")s)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 2: Multi-Tab Open
# ═══════════════════════════════════════════════════════════════════════════════

benchmark_multi_tab() {
    echo ""
    echo "================================================================="
    echo "  BENCHMARK 2: Multi-Tab Open"
    echo "================================================================="
    echo ""

    local tab_files=()
    for f in "$TABS_DIR"/tab-*.md; do
        tab_files+=("$f")
    done
    local total_files=${#tab_files[@]}
    echo "  Available tab files: $total_files"

    for count in 10 30 55; do
        if [ "$count" -gt "$total_files" ]; then
            echo "  [Skip] Not enough tab files for $count tabs"
            continue
        fi

        echo ""
        echo "  [2] Opening $count tabs..."
        kill_kern
        sleep 1

        # Launch Kern fresh
        open -a "$KERN_APP_PATH"
        wait_for_window 15000 > /dev/null
        sleep 2

        local start=$(now_ms)
        for i in $(seq 0 $(( count - 1 ))); do
            open -a "$KERN_APP_PATH" "${tab_files[$i]}"
            # Small delay to avoid overwhelming the system
            sleep 0.2
        done

        # Wait for all tabs to settle
        sleep 3

        local end=$(now_ms)
        local total=$(elapsed_ms "$start" "$end")

        # Count windows
        local window_count
        window_count=$(osascript -e 'tell application "System Events" to count windows of process "KernTextKit"' 2>/dev/null || echo "?")

        local pid=$(get_kern_pid)
        local mem=$(get_memory_mb "$pid")

        echo "    $count tabs opened in ${total}ms ($(ms_to_s "$total")s)"
        echo "    Window count: $window_count"
        echo "    Memory: ${mem} MB"

        eval "MULTI_TAB_${count}_TIME=\"$total\""
        eval "MULTI_TAB_${count}_MEM=\"$mem\""
        eval "MULTI_TAB_${count}_WINDOWS=\"$window_count\""

        kill_kern
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 3: Memory Benchmark
# ═══════════════════════════════════════════════════════════════════════════════

benchmark_memory() {
    echo ""
    echo "================================================================="
    echo "  BENCHMARK 3: Memory After 55 Tabs"
    echo "================================================================="
    echo ""

    kill_kern
    sleep 1

    open -a "$KERN_APP_PATH"
    wait_for_window 15000 > /dev/null
    sleep 2

    local tab_files=()
    for f in "$TABS_DIR"/tab-*.md; do
        tab_files+=("$f")
    done

    echo "  Opening 55 tabs..."
    for i in $(seq 0 54); do
        open -a "$KERN_APP_PATH" "${tab_files[$i]}"
        sleep 0.15
    done

    # Let everything settle
    echo "  Waiting for tabs to settle (10 seconds)..."
    sleep 10

    local pid=$(get_kern_pid)
    MEM_55_TABS=$(get_memory_mb "$pid")
    echo "  Memory after 55 tabs: ${MEM_55_TABS} MB (PID: $pid)"

    # Also get the RSS breakdown
    local rss_raw
    rss_raw=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    echo "  Raw RSS: ${rss_raw} KB"

    # Check total system memory used by Kern-related processes
    local all_kern_pids
    all_kern_pids=$(pgrep -f "Kern" 2>/dev/null || true)
    if [ -n "$all_kern_pids" ]; then
        local total_rss=0
        for p in $all_kern_pids; do
            local r
            r=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ' || echo "0")
            total_rss=$(( total_rss + r ))
        done
        MEM_55_TABS_TOTAL=$(python3 -c "print(f'{$total_rss / 1024:.1f}')")
        echo "  Total RSS (all Kern processes): ${MEM_55_TABS_TOTAL} MB"
    else
        MEM_55_TABS_TOTAL="$MEM_55_TABS"
    fi

    kill_kern
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 4: File Open Latency (with Kern already running)
# ═══════════════════════════════════════════════════════════════════════════════

benchmark_file_open_latency() {
    echo ""
    echo "================================================================="
    echo "  BENCHMARK 4: File Open Latency (Kern Already Running)"
    echo "================================================================="
    echo ""

    kill_kern
    sleep 1

    # Start Kern with a dummy file
    local dummy="/tmp/kern-bench-dummy.md"
    echo "# Dummy" > "$dummy"
    open -a "$KERN_APP_PATH" "$dummy"
    wait_for_window 15000 > /dev/null
    sleep 3

    for label_file in "small:$SMALL_FILE" "medium:$MEDIUM_FILE" "large:$LARGE_FILE"; do
        local label="${label_file%%:*}"
        local file="${label_file#*:}"
        local size
        size=$(wc -c < "$file" | tr -d ' ')

        echo "  [4] $label file ($size bytes, $RUNS runs)"
        local vals=""
        for i in $(seq 1 "$RUNS"); do
            # Get current window count
            local before_count
            before_count=$(osascript -e 'tell application "System Events" to count windows of process "KernTextKit"' 2>/dev/null || echo "0")

            local start=$(now_ms)
            open -a "$KERN_APP_PATH" "$file"

            # Wait for window count to increase or title to change
            local max_wait=10000
            local waited=0
            while [ "$waited" -lt "$max_wait" ]; do
                local current_count
                current_count=$(osascript -e 'tell application "System Events" to count windows of process "KernTextKit"' 2>/dev/null || echo "0")
                if [ "$current_count" -gt "$before_count" ] 2>/dev/null; then
                    break
                fi
                sleep 0.05
                waited=$(( waited + 50 ))
            done

            local end=$(now_ms)
            local latency=$(elapsed_ms "$start" "$end")
            echo "    Run $i: ${latency}ms"
            vals="$vals $latency"

            # Close the just-opened tab to keep things clean
            sleep 0.5
            osascript -e '
                tell application "System Events"
                    tell process "KernTextKit"
                        keystroke "w" using {command down}
                    end tell
                end tell
            ' 2>/dev/null || true
            sleep 0.5
        done

        local avg=$(average_ms "$vals")
        echo "    Average: ${avg}ms ($(ms_to_s "$avg")s)"
        eval "LATENCY_${label}_AVG=\"$avg\""
    done

    rm -f "$dummy"
    kill_kern
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 5: Auto-Save / File Watcher Test
# ═══════════════════════════════════════════════════════════════════════════════

benchmark_autosave() {
    echo ""
    echo "================================================================="
    echo "  BENCHMARK 5: Auto-Save / File Watcher Debounce"
    echo "================================================================="
    echo ""

    kill_kern
    sleep 1

    local temp_file="/tmp/kern-bench-autosave-$(date +%s).md"
    echo "# Auto-Save Test" > "$temp_file"
    echo "" >> "$temp_file"
    echo "Initial content for file watcher benchmark." >> "$temp_file"

    echo "  [5a] Opening temp file in Kern..."
    open -a "$KERN_APP_PATH" "$temp_file"
    wait_for_window 15000 > /dev/null
    echo "  Waiting 3 seconds for editor to fully load..."
    sleep 3

    # Single external modification
    echo "  [5b] Single external modification..."
    local start=$(now_ms)
    echo "Modified line 1 - $(date +%s%N)" >> "$temp_file"
    sleep 2
    local end=$(now_ms)
    local single_mod_time=$(elapsed_ms "$start" "$end")
    echo "    Single modification wait time: ${single_mod_time}ms"
    AUTOSAVE_SINGLE="${single_mod_time}"

    # Rapid modifications (5 times in ~100ms intervals)
    echo ""
    echo "  [5c] Rapid modifications (5 changes with 100ms gaps)..."
    local rapid_start=$(now_ms)
    for j in $(seq 1 5); do
        echo "Rapid change $j - $(date +%s%N)" >> "$temp_file"
        python3 -c "import time; time.sleep(0.1)"
    done
    local rapid_mod_end=$(now_ms)
    local rapid_mod_time=$(elapsed_ms "$rapid_start" "$rapid_mod_end")
    echo "    Rapid modification burst took: ${rapid_mod_time}ms"

    # Wait for debounce to settle
    sleep 2

    # Check file mtime
    local final_mtime
    final_mtime=$(stat -f "%m" "$temp_file" 2>/dev/null || stat -c "%Y" "$temp_file" 2>/dev/null)
    echo "    Final mtime: $final_mtime"
    echo "    File watcher should have coalesced rapid changes via debounce"
    AUTOSAVE_RAPID="${rapid_mod_time}"

    # Verify Kern is still alive
    if kern_is_alive; then
        echo "    Kern survived rapid modifications: YES"
        AUTOSAVE_SURVIVED="YES"
    else
        echo "    Kern survived rapid modifications: NO (CRASHED)"
        AUTOSAVE_SURVIVED="NO"
    fi

    rm -f "$temp_file"
    kill_kern
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 6: Rapid Tab Switch Simulation
# ═══════════════════════════════════════════════════════════════════════════════

benchmark_rapid_tab_switch() {
    echo ""
    echo "================================================================="
    echo "  BENCHMARK 6: Rapid Tab Switching (50 switches)"
    echo "================================================================="
    echo ""

    kill_kern
    sleep 1

    # Open multiple tabs first
    echo "  Opening 15 tabs for rapid switching test..."
    local tab_files=()
    for f in "$TABS_DIR"/tab-*.md; do
        tab_files+=("$f")
    done

    open -a "$KERN_APP_PATH" "${tab_files[0]}"
    wait_for_window 15000 > /dev/null
    sleep 2

    for i in $(seq 1 14); do
        open -a "$KERN_APP_PATH" "${tab_files[$i]}"
        sleep 0.3
    done
    sleep 3

    local pid_before=$(get_kern_pid)
    local mem_before=$(get_memory_mb "$pid_before")
    echo "  Memory before rapid switching: ${mem_before} MB"

    echo "  Performing 50 rapid tab switches via AppleScript..."
    local switch_start=$(now_ms)

    # Use Cmd+Shift+] for forward tab navigation (standard macOS)
    osascript << 'APPLESCRIPT_EOF' 2>/dev/null || true
tell application "System Events"
    tell process "KernTextKit"
        repeat 50 times
            -- Cmd+Shift+] to switch to next tab
            key code 30 using {command down, shift down}
            delay 0.05
        end repeat
    end tell
end tell
APPLESCRIPT_EOF

    local switch_end=$(now_ms)
    local switch_total=$(elapsed_ms "$switch_start" "$switch_end")
    echo "  50 tab switches completed in: ${switch_total}ms ($(ms_to_s "$switch_total")s)"
    RAPID_SWITCH_TIME="$switch_total"

    # Brief settle time
    sleep 2

    # Check if Kern is still alive
    if kern_is_alive; then
        echo "  Kern survived rapid switching: YES"
        RAPID_SWITCH_SURVIVED="YES"
        local pid_after=$(get_kern_pid)
        local mem_after=$(get_memory_mb "$pid_after")
        echo "  Memory after rapid switching: ${mem_after} MB"
        RAPID_SWITCH_MEM_BEFORE="$mem_before"
        RAPID_SWITCH_MEM_AFTER="$mem_after"

        # Calculate memory delta
        local mem_delta
        mem_delta=$(python3 -c "print(f'{float(\"$mem_after\") - float(\"$mem_before\"):+.1f}')")
        echo "  Memory delta: ${mem_delta} MB"
        RAPID_SWITCH_MEM_DELTA="$mem_delta"
    else
        echo "  Kern survived rapid switching: NO (CRASHED!)"
        RAPID_SWITCH_SURVIVED="NO"
        RAPID_SWITCH_MEM_BEFORE="$mem_before"
        RAPID_SWITCH_MEM_AFTER="N/A"
        RAPID_SWITCH_MEM_DELTA="N/A"
    fi

    kill_kern
}

# ═══════════════════════════════════════════════════════════════════════════════
# Generate Results Markdown
# ═══════════════════════════════════════════════════════════════════════════════

generate_results() {
    echo ""
    echo "================================================================="
    echo "  Generating Results"
    echo "================================================================="

    local small_size medium_size large_size mega_size
    small_size=$(wc -c < "$SMALL_FILE" | tr -d ' ')
    medium_size=$(wc -c < "$MEDIUM_FILE" | tr -d ' ')
    large_size=$(wc -c < "$LARGE_FILE" | tr -d ' ')

    cat > "$RESULTS_FILE" << RESULTS_EOF
# Kern Comprehensive Benchmark Results

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Machine:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
**macOS:** $(sw_vers -productVersion 2>/dev/null || echo "Unknown")
**RAM:** $(sysctl -n hw.memsize 2>/dev/null | python3 -c "import sys; print(f'{int(sys.stdin.read().strip()) / (1024**3):.0f} GB')" 2>/dev/null || echo "Unknown")
**Kern App:** $KERN_APP_PATH

---

## 1. Cold Start Benchmark

Time from \`open -a KernTextKit\` until the first window appears. Average of $RUNS runs.

| Scenario | Avg Time | Notes |
|----------|----------|-------|
| No file | $(ms_to_s "$COLD_NOFILE_AVG")s (${COLD_NOFILE_AVG}ms) | Empty launch |
| Small file ($small_size bytes) | $(ms_to_s "$COLD_SMALL_AVG")s (${COLD_SMALL_AVG}ms) | tab-01.md |
| Mega stress test ($large_size bytes) | $(ms_to_s "$COLD_MEGA_AVG")s (${COLD_MEGA_AVG}ms) | mega-stress-test.md |

## 2. Multi-Tab Open Benchmark

Fresh KernTextKit launch, then opening N files sequentially with \`open -a KernTextKit <file>\`.

| Tabs Opened | Total Time | Memory | Windows Reported |
|-------------|------------|--------|------------------|
| 10 | $(ms_to_s "${MULTI_TAB_10_TIME:-0}")s (${MULTI_TAB_10_TIME:-0}ms) | ${MULTI_TAB_10_MEM:-N/A} MB | ${MULTI_TAB_10_WINDOWS:-N/A} |
| 30 | $(ms_to_s "${MULTI_TAB_30_TIME:-0}")s (${MULTI_TAB_30_TIME:-0}ms) | ${MULTI_TAB_30_MEM:-N/A} MB | ${MULTI_TAB_30_WINDOWS:-N/A} |
| 55 | $(ms_to_s "${MULTI_TAB_55_TIME:-0}")s (${MULTI_TAB_55_TIME:-0}ms) | ${MULTI_TAB_55_MEM:-N/A} MB | ${MULTI_TAB_55_WINDOWS:-N/A} |

## 3. Memory Benchmark (55 Tabs)

Memory usage after opening 55 tabs and waiting 10 seconds for stabilization.

| Metric | Value |
|--------|-------|
| Main process RSS | ${MEM_55_TABS:-N/A} MB |
| All Kern processes RSS | ${MEM_55_TABS_TOTAL:-N/A} MB |

> Note: Kern virtualizes tabs beyond 5 live WKWebViews. Background tabs are stored as markdown strings.

## 4. File Open Latency (Kern Already Running)

Time to open an additional file while Kern is already running. Average of $RUNS runs.

| File Size | Avg Latency | Notes |
|-----------|-------------|-------|
| Small ($small_size bytes) | $(ms_to_s "${LATENCY_small_AVG:-0}")s (${LATENCY_small_AVG:-0}ms) | tab-01.md |
| Medium ($medium_size bytes) | $(ms_to_s "${LATENCY_medium_AVG:-0}")s (${LATENCY_medium_AVG:-0}ms) | stress-test.md |
| Large ($large_size bytes) | $(ms_to_s "${LATENCY_large_AVG:-0}")s (${LATENCY_large_AVG:-0}ms) | mega-stress-test.md |

## 5. Auto-Save / File Watcher Debounce

External file modification detection and debounce behavior.

| Test | Result |
|------|--------|
| Single modification (wait 2s) | ${AUTOSAVE_SINGLE:-N/A}ms total wait |
| Rapid burst (5 changes, 100ms gaps) | ${AUTOSAVE_RAPID:-N/A}ms burst duration |
| Kern survived rapid modifications | ${AUTOSAVE_SURVIVED:-N/A} |

> Note: Kern uses a file watcher with debounce. Rapid external changes should be coalesced
> into a single reload rather than triggering 5 separate reloads.

## 6. Rapid Tab Switching (50 switches)

Using AppleScript to send Cmd+Shift+] 50 times with 50ms delays across 15 open tabs.

| Metric | Value |
|--------|-------|
| Total time for 50 switches | $(ms_to_s "${RAPID_SWITCH_TIME:-0}")s (${RAPID_SWITCH_TIME:-0}ms) |
| Avg per switch | $(python3 -c "print(f'{int(\"${RAPID_SWITCH_TIME:-0}\") / 50:.0f}')" 2>/dev/null || echo "?")ms |
| Kern survived | ${RAPID_SWITCH_SURVIVED:-N/A} |
| Memory before | ${RAPID_SWITCH_MEM_BEFORE:-N/A} MB |
| Memory after | ${RAPID_SWITCH_MEM_AFTER:-N/A} MB |
| Memory delta | ${RAPID_SWITCH_MEM_DELTA:-N/A} MB |

---

## Summary

| Category | Key Metric | Value |
|----------|-----------|-------|
| Cold Start | No file | $(ms_to_s "$COLD_NOFILE_AVG")s |
| Cold Start | Small file | $(ms_to_s "$COLD_SMALL_AVG")s |
| Cold Start | Mega stress | $(ms_to_s "$COLD_MEGA_AVG")s |
| Multi-Tab | 55 tabs open time | $(ms_to_s "${MULTI_TAB_55_TIME:-0}")s |
| Memory | 55 tabs RSS | ${MEM_55_TABS_TOTAL:-N/A} MB |
| Latency | Small file (warm) | $(ms_to_s "${LATENCY_small_AVG:-0}")s |
| Latency | Large file (warm) | $(ms_to_s "${LATENCY_large_AVG:-0}")s |
| Stability | 50 rapid switches | ${RAPID_SWITCH_SURVIVED:-N/A} |
| Stability | Rapid file modifications | ${AUTOSAVE_SURVIVED:-N/A} |
RESULTS_EOF

    echo "  Results saved to: $RESULTS_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    echo "================================================================="
    echo "  Kern Comprehensive Benchmark"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Kern: $KERN_APP_PATH"
    echo "  Runs per measurement: $RUNS"
    echo "================================================================="

    generate_test_fixtures

    # Initialize all result variables with defaults
    COLD_NOFILE_AVG="0"
    COLD_SMALL_AVG="0"
    COLD_MEGA_AVG="0"
    MULTI_TAB_10_TIME="0"
    MULTI_TAB_10_MEM="N/A"
    MULTI_TAB_10_WINDOWS="0"
    MULTI_TAB_30_TIME="0"
    MULTI_TAB_30_MEM="N/A"
    MULTI_TAB_30_WINDOWS="0"
    MULTI_TAB_55_TIME="0"
    MULTI_TAB_55_MEM="N/A"
    MULTI_TAB_55_WINDOWS="0"
    MEM_55_TABS="0"
    MEM_55_TABS_TOTAL="0"
    LATENCY_small_AVG="0"
    LATENCY_medium_AVG="0"
    LATENCY_large_AVG="0"
    AUTOSAVE_SINGLE="0"
    AUTOSAVE_RAPID="0"
    AUTOSAVE_SURVIVED="N/A"
    RAPID_SWITCH_TIME="0"
    RAPID_SWITCH_SURVIVED="N/A"
    RAPID_SWITCH_MEM_BEFORE="0"
    RAPID_SWITCH_MEM_AFTER="0"
    RAPID_SWITCH_MEM_DELTA="0"

    benchmark_cold_start
    benchmark_multi_tab
    benchmark_memory
    benchmark_file_open_latency
    benchmark_autosave
    benchmark_rapid_tab_switch
    generate_results

    echo ""
    echo "================================================================="
    echo "  Benchmark Complete!"
    echo "  Results: $RESULTS_FILE"
    echo "================================================================="

    # Cleanup
    kill_kern
}

main "$@"
