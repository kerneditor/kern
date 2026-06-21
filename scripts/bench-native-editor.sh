#!/bin/bash
# bench-native-editor.sh — Run non-UI performance benchmarks for the native editor prototype.
#
# Usage:
#   ./scripts/bench-native-editor.sh [--quick] [--include-mermaid] [--fail-on-regression]
#
# Notes:
# - This runs XCTest perf tests only (no UI automation).
# - Results are written under bench-results/native-editor/<timestamp>/
# - Render/scroll perf cases are bounded by default to avoid pathological hangs.
#   Set KERN_PERF_RENDER_FULL=1 to force full-fixture render/scroll perf.
# - The xcodebuild process is time-bounded. Override with
#   KERN_PERF_XCODEBUILD_TIMEOUT_SECONDS=<seconds>.

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=false
INCLUDE_MERMAID=false
FAIL_ON_REGRESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)
      QUICK=true
      shift
      ;;
    --include-mermaid)
      INCLUDE_MERMAID=true
      shift
      ;;
    --fail-on-regression)
      FAIL_ON_REGRESSION=true
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/bench-results/native-editor/$TS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/kern-derived-data-bench}"
XCODEBUILD_TIMEOUT_SECONDS="${KERN_PERF_XCODEBUILD_TIMEOUT_SECONDS:-1800}"
if ! [[ "$XCODEBUILD_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$XCODEBUILD_TIMEOUT_SECONDS" -le 0 ]; then
  echo "KERN_PERF_XCODEBUILD_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
DEFAULTS_DOMAIN="com.gradigit.kern.tests"
declare -a DEFAULT_KEYS=()
declare -a SOURCE_DIRS=("KernApp/Sources" "KernTests")
if [ -d "KernUITests" ]; then
  SOURCE_DIRS+=("KernUITests")
fi
XCODEBUILD_PID=""
ARCHIVED=false
ARCHIVE_DIR=""

mkdir -p "$OUT_DIR"

write_suite_value() {
  local key="$1"
  local value="$2"
  /usr/bin/defaults write "$DEFAULTS_DOMAIN" "$key" -string "$value"
  DEFAULT_KEYS+=("$key")
}

cleanup_suite_values() {
  for key in "${DEFAULT_KEYS[@]-}"; do
    [ -n "$key" ] || continue
    /usr/bin/defaults delete "$DEFAULTS_DOMAIN" "$key" >/dev/null 2>&1 || true
  done
}

owned_kern_pids() {
  local app_exec="$DERIVED_DATA_PATH/Build/Products/Debug/Kern.app/Contents/MacOS/Kern"
  local app_exec_real
  app_exec_real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$app_exec" 2>/dev/null || printf '%s' "$app_exec")"
  ps -axo pid=,args= | python3 -c '
import os
import sys

needle_a = sys.argv[1]
needle_b = sys.argv[2]
self_pid = str(os.getpid())
for line in sys.stdin:
    stripped = line.strip()
    if not stripped:
        continue
    pid, _, args = stripped.partition(" ")
    if pid == self_pid:
        continue
    if needle_a in args or needle_b in args:
        print(pid)
' "$app_exec" "$app_exec_real"
}

terminate_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

cleanup_benchmark_processes() {
  if [ -n "${XCODEBUILD_PID:-}" ]; then
    terminate_pid "$XCODEBUILD_PID"
    XCODEBUILD_PID=""
  fi
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    terminate_pid "$pid"
  done < <(owned_kern_pids || true)
}

capture_process_snapshot() {
  local output="$1"
  {
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "owned_kern_pids=$(owned_kern_pids | tr '\n' ' ' || true)"
    echo ""
    ps -axo pid,ppid,etime,state,pcpu,pmem,comm,args | grep -E 'xcodebuild|Kern\\.app|KernTextKitPerf|KernTextKitTests' | grep -v grep || true
  } > "$output"
}

archive_run_artifacts() {
  local status="$1"
  local archive_root baseline_display
  if [ "$ARCHIVED" = true ]; then
    return 0
  fi
  archive_root="$(pwd)/benchmark-archive/native-editor"
  ARCHIVE_DIR="$archive_root/$TS"
  mkdir -p "$ARCHIVE_DIR"
  [ -f "$OUT_DIR/perf.log" ] && cp "$OUT_DIR/perf.log" "$ARCHIVE_DIR/perf.log"
  [ -f "$OUT_DIR/run-manifest.txt" ] && cp "$OUT_DIR/run-manifest.txt" "$ARCHIVE_DIR/run-manifest.txt"
  [ -f "$OUT_DIR/perf-tests.txt" ] && cp "$OUT_DIR/perf-tests.txt" "$ARCHIVE_DIR/perf-tests.txt"
  [ -f "$OUT_DIR/baseline-selection.log" ] && cp "$OUT_DIR/baseline-selection.log" "$ARCHIVE_DIR/baseline-selection.log"
  [ -f "$OUT_DIR/metrics-summary.json" ] && cp "$OUT_DIR/metrics-summary.json" "$ARCHIVE_DIR/metrics-summary.json"
  [ -f "$OUT_DIR/summary.md" ] && cp "$OUT_DIR/summary.md" "$ARCHIVE_DIR/summary.md"
  [ -f "$OUT_DIR/processes-before.txt" ] && cp "$OUT_DIR/processes-before.txt" "$ARCHIVE_DIR/processes-before.txt"
  [ -f "$OUT_DIR/processes-after-success.txt" ] && cp "$OUT_DIR/processes-after-success.txt" "$ARCHIVE_DIR/processes-after-success.txt"
  [ -f "$OUT_DIR/failure.txt" ] && cp "$OUT_DIR/failure.txt" "$ARCHIVE_DIR/failure.txt"
  [ -f "$OUT_DIR/processes-at-failure.txt" ] && cp "$OUT_DIR/processes-at-failure.txt" "$ARCHIVE_DIR/processes-at-failure.txt"

  if [ ! -f "$archive_root/INDEX.md" ]; then
    {
      echo "| Timestamp | Status | Commit | Baseline | Run directory | Archive directory |"
      echo "| --- | --- | --- | --- | --- | --- |"
    } > "$archive_root/INDEX.md"
  fi

  baseline_display="none"
  if [ -n "${BASELINE_LOG:-}" ]; then
    baseline_display="$(dirname "$BASELINE_LOG")"
  fi
  echo "| $TS | $status | $(git rev-parse --short HEAD 2>/dev/null || true) | $baseline_display | $OUT_DIR | $ARCHIVE_DIR |" >> "$archive_root/INDEX.md"
  ARCHIVED=true
}

cleanup_all() {
  local status=$?
  cleanup_suite_values
  cleanup_benchmark_processes
  exit "$status"
}

reset_suite_domain() {
  /usr/bin/defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  DEFAULT_KEYS=()
}

sync_kernel_env_to_suite() {
  while IFS='=' read -r key value; do
    case "$key" in
      KERN_*)
        write_suite_value "$key" "$value"
        ;;
    esac
  done < <(/usr/bin/env)
}

set_default_kernel_value() {
  local key="$1"
  local value="$2"
  if [ -z "${!key+x}" ]; then
    export "$key=$value"
  fi
  write_suite_value "$key" "${!key}"
}

trap cleanup_all EXIT INT TERM
reset_suite_domain
sync_kernel_env_to_suite
set_default_kernel_value "KERN_ENABLE_PERF_TESTS" "1"
set_default_kernel_value "KERN_PERF_ENABLE_ULTIMATE_RENDER" "1"
if [ "$QUICK" = true ]; then
  export KERN_PERF_QUICK=1
  write_suite_value "KERN_PERF_QUICK" "1"
fi
if [ "$INCLUDE_MERMAID" = true ]; then
  set_default_kernel_value "KERN_ENABLE_MERMAID_MODE_BENCHMARKS" "1"
fi

echo "=== Kern Native Editor Benchmarks ==="
echo "Output: $OUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo "Quick: $QUICK"
echo "Include Mermaid mode matrix: $INCLUDE_MERMAID"
echo "xcodebuild timeout: ${XCODEBUILD_TIMEOUT_SECONDS}s"
echo ""

COMMAND_LINE="DERIVED_DATA_PATH=$DERIVED_DATA_PATH KERN_PERF_ITERATIONS=${KERN_PERF_ITERATIONS:-scheme-default} ./scripts/bench-native-editor.sh"
if [ "$QUICK" = true ]; then COMMAND_LINE="$COMMAND_LINE --quick"; fi
if [ "$INCLUDE_MERMAID" = true ]; then COMMAND_LINE="$COMMAND_LINE --include-mermaid"; fi
if [ "$FAIL_ON_REGRESSION" = true ]; then COMMAND_LINE="$COMMAND_LINE --fail-on-regression"; fi

GIT_STATUS="$(git status --porcelain 2>/dev/null || true)"
{
  echo "timestamp=$TS"
  echo "command=$COMMAND_LINE"
  echo "derived_data_path=$DERIVED_DATA_PATH"
  echo "quick=$QUICK"
  echo "include_mermaid=$INCLUDE_MERMAID"
  echo "xcodebuild_timeout_seconds=$XCODEBUILD_TIMEOUT_SECONDS"
  echo "git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "git_commit=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "git_dirty=$([ -n "$GIT_STATUS" ] && echo 1 || echo 0)"
  echo "xcodebuild_version<<EOF"
  xcodebuild -version 2>/dev/null || true
  echo "EOF"
  echo "kern_env<<EOF"
  env | sort | grep '^KERN_' || true
  echo "EOF"
  echo "fixture_hashes<<EOF"
  for fixture in test-fixtures/native-editor-benchmark.md test-fixtures/stress-test.md test-fixtures/ultimate-stress-test.md test-fixtures/mega-stress-test.md; do
    if [ -f "$fixture" ]; then
      shasum -a 256 "$fixture"
    fi
  done
  echo "EOF"
} > "$OUT_DIR/run-manifest.txt"
capture_process_snapshot "$OUT_DIR/processes-before.txt"

NEED_XCODEGEN=true
if [ -f "KernTextKit.xcodeproj/project.pbxproj" ] && [ "KernTextKit.xcodeproj/project.pbxproj" -nt "project.yml" ]; then
  NEED_XCODEGEN=false
fi

# Ensure newly added source/test files are present in pbxproj; otherwise benchmarks can run with stale code.
if [ "$NEED_XCODEGEN" = false ] && [ -f "KernTextKit.xcodeproj/project.pbxproj" ]; then
  PBXPROJ="KernTextKit.xcodeproj/project.pbxproj"
  while IFS= read -r swift_file; do
    base="$(basename "$swift_file")"
    if ! grep -Fq "path = $base;" "$PBXPROJ"; then
      NEED_XCODEGEN=true
      echo "▸ Detected source not referenced in Xcode project: $swift_file"
      break
    fi
  done < <(find "${SOURCE_DIRS[@]}" -type f -name "*.swift" | sort)
fi

if [ "$NEED_XCODEGEN" = true ]; then
  echo "▸ Generating Xcode project (xcodegen)..."
  xcodegen 2>&1 | tail -1
else
  echo "▸ Skipping xcodegen (project up-to-date)."
fi

echo ""
echo "▸ Running performance tests (scheme: KernTextKitPerf)..."

if [ "${KERN_PERF_QUICK:-0}" = "1" ]; then
  PERF_TESTS=(
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testImportExportBenchmarkFilePerformance"
    "KernTextKitTests/NativeEditorRenderPerformanceTests/testRenderBenchmarkFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testRenderUltimateStressFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testTypingUltimateStressCharacterByCharacterPerformance"
  )
else
  PERF_TESTS=(
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testImportExportBenchmarkFilePerformance"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testImportOnlyBenchmarkFilePerformance"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testExportOnlyBenchmarkFilePerformance"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testParseInlineMicroBenchmark"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testParseInlineRepeatedShortFragmentsBenchmark"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testImageAttachmentImportAndBoundsPerformance"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testMathBlockImportAndBoundsPerformance"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testMermaidImportAndBoundsPerformance"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testImportPhaseProfileBenchmark"
    "KernTextKitTests/NativeMarkdownCodecPerformanceTests/testStagedPromotionSliceParseBenchmark"
    "KernTextKitTests/NativeEditorRenderPerformanceTests/testRenderBenchmarkFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testRenderStressFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testRenderUltimateStressFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testRenderMegaStressFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testScrollMegaStressFilePerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testIncrementalTypingPerformance_LiveAppend"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testTypingUltimateStressCharacterByCharacterPerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testTypingMegaStressCharacterByCharacterPerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testInterleavedActionBurstOnUltimateStressPerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testInterleavedActionBurstOnMegaStressPerformance"
    "KernTextKitTests/NativeEditorMegaStressPerformanceTests/testEditInMiddleOfLargeDocumentPerformance"
  )
fi

if [ "$INCLUDE_MERMAID" = true ]; then
  PERF_TESTS+=("KernTextKitTests/NativeMarkdownCodecPerformanceTests/testMermaidRenderModeBenchmarkMatrix")
  PERF_TESTS+=("KernTextKitTests/NativeMermaidRenderModeBenchmarkTests/testMermaidRenderModeBenchmarkMatrix")
fi

echo "  Perf test count: ${#PERF_TESTS[@]}"
printf "%s\n" "${PERF_TESTS[@]}" > "$OUT_DIR/perf-tests.txt"

BASELINE_LOG="${KERN_PERF_BASELINE_LOG:-}"
BASELINE_SELECTION_LOG="$OUT_DIR/baseline-selection.log"
: > "$BASELINE_SELECTION_LOG"
if [ -n "$BASELINE_LOG" ]; then
  set +e
  SELECTED_BASELINE_LOG="$(python3 scripts/select-xctest-perf-baseline.py \
    --candidate-log "$BASELINE_LOG" \
    --current-run-dir "$OUT_DIR" \
    --current-manifest "$OUT_DIR/run-manifest.txt" \
    --explain \
    2> "$BASELINE_SELECTION_LOG")"
  SELECT_STATUS=$?
  set -e
  if [ "$SELECT_STATUS" -ne 0 ]; then
    echo "Explicit baseline log is not compatible with this run. See: $BASELINE_SELECTION_LOG" >&2
    exit 2
  fi
  BASELINE_LOG="$SELECTED_BASELINE_LOG"
else
  set +e
  BASELINE_LOG="$(python3 scripts/select-xctest-perf-baseline.py \
    --root bench-results/native-editor \
    --current-run-dir "$OUT_DIR" \
    --current-manifest "$OUT_DIR/run-manifest.txt" \
    --explain \
    2> "$BASELINE_SELECTION_LOG")"
  SELECT_STATUS=$?
  set -e
  if [ "$SELECT_STATUS" -ne 0 ]; then
    echo "Baseline auto-selection failed. See: $BASELINE_SELECTION_LOG" >&2
    exit "$SELECT_STATUS"
  fi
fi
if [ -n "$BASELINE_LOG" ] && [ -f "$BASELINE_LOG" ]; then
  echo "  Baseline log: $BASELINE_LOG"
else
  BASELINE_LOG=""
  echo "  Baseline log: none"
fi
if [ -s "$BASELINE_SELECTION_LOG" ]; then
  echo "  Baseline selection notes: $BASELINE_SELECTION_LOG"
fi

set +e
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme KernTextKitPerf \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$OUT_DIR/KernTextKitPerf.xcresult" \
  test \
  "${PERF_TESTS[@]/#/-only-testing:}" \
  > >(tee "$OUT_DIR/perf.log") 2>&1 &
XCODEBUILD_PID=$!

STATUS=0
START_SECONDS=$SECONDS
while kill -0 "$XCODEBUILD_PID" >/dev/null 2>&1; do
  if [ $((SECONDS - START_SECONDS)) -ge "$XCODEBUILD_TIMEOUT_SECONDS" ]; then
    STATUS=124
    {
      echo ""
      echo "error: xcodebuild timed out after ${XCODEBUILD_TIMEOUT_SECONDS}s"
    } | tee -a "$OUT_DIR/perf.log" >&2
    break
  fi
  sleep 2
done

if [ "$STATUS" -eq 124 ]; then
  TIMED_OUT_PID="$XCODEBUILD_PID"
  capture_process_snapshot "$OUT_DIR/processes-at-failure.txt"
  cleanup_benchmark_processes
  wait "$TIMED_OUT_PID" >/dev/null 2>&1 || true
  XCODEBUILD_PID=""
else
  wait "$XCODEBUILD_PID"
  STATUS=$?
  XCODEBUILD_PID=""
fi
set -e

if [ $STATUS -ne 0 ]; then
  capture_process_snapshot "$OUT_DIR/processes-at-failure.txt"
  {
    echo "status=failed"
    echo "xcodebuild_exit_status=$STATUS"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$STATUS" -eq 124 ]; then
      echo "failure_reason=xcodebuild_timeout"
    else
      echo "failure_reason=xcodebuild_failed"
    fi
  } > "$OUT_DIR/failure.txt"
  archive_run_artifacts "failed"
  echo "Perf tests failed (exit $STATUS). See: $OUT_DIR/perf.log" >&2
  exit $STATUS
fi
capture_process_snapshot "$OUT_DIR/processes-after-success.txt"

REPORT_ARGS=(
  "--log" "$OUT_DIR/perf.log"
  "--out-json" "$OUT_DIR/metrics-summary.json"
  "--out-md" "$OUT_DIR/summary.md"
  "--command" "$COMMAND_LINE"
  "--label" "Kern Native Performance Benchmark Report"
  "--run-dir" "$OUT_DIR"
)
if [ -n "$BASELINE_LOG" ]; then
  REPORT_ARGS+=("--baseline-log" "$BASELINE_LOG")
fi
if [ "$FAIL_ON_REGRESSION" = true ]; then
  REPORT_ARGS+=("--fail-on-regression")
fi

echo ""
echo "▸ Summarizing performance metrics..."
set +e
python3 scripts/xctest-perf-report.py "${REPORT_ARGS[@]}"
REPORT_STATUS=$?
set -e
if [ "$REPORT_STATUS" -ne 0 ]; then
  {
    echo "status=failed"
    echo "xcodebuild_exit_status=0"
    echo "report_exit_status=$REPORT_STATUS"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "failure_reason=performance_report_failed_or_regressed"
  } > "$OUT_DIR/failure.txt"
  archive_run_artifacts "failed"
  exit "$REPORT_STATUS"
fi
archive_run_artifacts "passed"

echo ""
echo "✓ Benchmarks completed"
echo "Result bundle: $OUT_DIR/KernTextKitPerf.xcresult"
echo "Log: $OUT_DIR/perf.log"
echo "Summary: $OUT_DIR/summary.md"
echo "Metrics JSON: $OUT_DIR/metrics-summary.json"
echo "Archive: $ARCHIVE_DIR"
