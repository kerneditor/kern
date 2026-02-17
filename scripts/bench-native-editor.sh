#!/bin/bash
# bench-native-editor.sh — Run non-UI performance benchmarks for the native editor prototype.
#
# Usage:
#   ./scripts/bench-native-editor.sh
#
# Notes:
# - This runs XCTest perf tests only (no UI automation).
# - Results are written under bench-results/native-editor/<timestamp>/
# - Render/scroll perf cases are bounded by default to avoid pathological hangs.
#   Set KERN_PERF_RENDER_FULL=1 to force full-fixture render/scroll perf.

set -euo pipefail
cd "$(dirname "$0")/.."

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/bench-results/native-editor/$TS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/kern-derived-data-bench}"
DEFAULTS_DOMAIN="com.gradigit.kern.tests"
declare -a DEFAULT_KEYS=()

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

trap 'cleanup_suite_values' EXIT INT TERM
reset_suite_domain
sync_kernel_env_to_suite
set_default_kernel_value "KERN_ENABLE_PERF_TESTS" "1"
set_default_kernel_value "KERN_PERF_ENABLE_ULTIMATE_RENDER" "1"

echo "=== Kern Native Editor Benchmarks ==="
echo "Output: $OUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo ""

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
  done < <(find KernApp/Sources KernTests KernUITests -type f -name "*.swift" | sort)
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
  )
fi

echo "  Perf test count: ${#PERF_TESTS[@]}"

set +e
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme KernTextKitPerf \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$OUT_DIR/KernTextKitPerf.xcresult" \
  test \
  "${PERF_TESTS[@]/#/-only-testing:}" \
  2>&1 | tee "$OUT_DIR/perf.log"
STATUS=${PIPESTATUS[0]}
set -e

if [ $STATUS -ne 0 ]; then
  echo "Perf tests failed (exit $STATUS). See: $OUT_DIR/perf.log" >&2
  exit $STATUS
fi

echo ""
echo "✓ Benchmarks completed"
echo "Result bundle: $OUT_DIR/KernTextKitPerf.xcresult"
echo "Log: $OUT_DIR/perf.log"
