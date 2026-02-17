#!/bin/bash
# run-exhaustive-native-suite.sh — Orchestrate the full native editor exhaustive + benchmark suite.
#
# Usage:
#   ./scripts/run-exhaustive-native-suite.sh
#
# Optional env:
#   KERN_RUN_UI_EXHAUSTIVE=1   Include exhaustive UI tests (requires Accessibility trust + unlocked screen)
#   KERN_RUN_ULTRA=1           Include bounded ultra non-UI mega all-profile matrix
#   KERN_RUN_ULTRA_FULL=1      Include full ultra non-UI mega all-profile matrix (very slow)
#   KERN_RUN_SPEC_CONFORMANCE=0 Skip strict CommonMark/GFM conformance lane (default: run)
#   KERN_FAIL_ON_SKIPPED=1     Treat any skipped XCTest as a failure (default: enabled)

set -euo pipefail
cd "$(dirname "$0")/.."

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/bench-results/native-editor-exhaustive/$TS"
mkdir -p "$OUT_DIR"

SUMMARY="$OUT_DIR/summary.txt"
FAILURES=()

: "${KERN_FAIL_ON_SKIPPED:=1}"
: "${KERN_ENABLE_MEGA_CHAR_BY_CHAR:=1}"
: "${KERN_ENABLE_MEGA_ALL_PROFILE_MATRIX:=1}"
: "${KERN_EXHAUSTIVE_ACTION_FULL:=1}"
: "${KERN_EXHAUSTIVE_ACTION_PROGRESS_EVERY:=500}"
: "${KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_COUNT:=1}"
: "${KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_INDEX:=0}"
: "${KERN_EXHAUSTIVE_ULTIMATE_FULL:=1}"
: "${KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_FULL:=1}"
: "${KERN_ENABLE_PERF_TESTS:=1}"
: "${KERN_PERF_ENABLE_ULTIMATE_RENDER:=1}"
: "${KERN_PERF_RENDER_FULL:=1}"
: "${KERN_UI_SCREENSHOTS:=always}"
: "${KERN_EXPORT_UI_ATTACHMENTS:=1}"

export KERN_FAIL_ON_SKIPPED
export KERN_ENABLE_MEGA_CHAR_BY_CHAR
export KERN_ENABLE_MEGA_ALL_PROFILE_MATRIX
export KERN_EXHAUSTIVE_ACTION_FULL
export KERN_EXHAUSTIVE_ACTION_PROGRESS_EVERY
export KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_COUNT
export KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_INDEX
export KERN_EXHAUSTIVE_ULTIMATE_FULL
export KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_FULL
export KERN_ENABLE_PERF_TESTS
export KERN_PERF_ENABLE_ULTIMATE_RENDER
export KERN_PERF_RENDER_FULL
export KERN_UI_SCREENSHOTS
export KERN_EXPORT_UI_ATTACHMENTS

log() {
  echo "$*" | tee -a "$SUMMARY"
}

run_step() {
  local name="$1"
  shift
  local log_file="$OUT_DIR/$name.log"

  log ""
  log "== $name =="
  log "cmd: $*"

  set +e
  "$@" 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  set -e

  if [ $status -ne 0 ]; then
    FAILURES+=("$name (exit $status)")
    log "status: FAIL ($status)"
  else
    if [ "${KERN_FAIL_ON_SKIPPED}" = "1" ]; then
      case "$name" in
        spec_conformance|unit_*|perf_bench|ui_*)
          local skipped_count
          skipped_count="$(rg -c "Test skipped -" "$log_file" || true)"
          if [ "${skipped_count:-0}" -gt 0 ]; then
            FAILURES+=("$name (contains $skipped_count skipped tests)")
            log "status: FAIL (skipped tests detected: $skipped_count)"
            log "first skipped lines:"
            rg -n "Test skipped -" "$log_file" | head -20 | tee -a "$SUMMARY" || true
            return
          fi
          ;;
      esac
    fi
    log "status: PASS"
  fi
}

log "KernTextKit exhaustive native suite"
log "output: $OUT_DIR"

run_step generate_ultimate_fixture python3 scripts/gen_ultimate_stress_test.py
run_step sync_mega_appendix python3 scripts/sync_mega_permutation_appendix.py
run_step xcodegen xcodegen

if [ "${KERN_RUN_SPEC_CONFORMANCE:-1}" = "1" ]; then
  run_step spec_fixtures_update python3 scripts/update_markdown_spec_fixtures.py
  run_step spec_conformance ./scripts/test-markdown-spec-conformance.sh --skip-fixture-update --skip-xcodegen
fi

run_step unit_exhaustive ./scripts/test-native-editor.sh --unit-only --exhaustive --skip-xcodegen
run_step perf_bench ./scripts/bench-native-editor.sh

if [ "${KERN_RUN_ULTRA:-0}" = "1" ]; then
  run_step unit_ultra ./scripts/test-native-editor.sh --unit-only --ultra --skip-xcodegen
fi

if [ "${KERN_RUN_ULTRA_FULL:-0}" = "1" ]; then
  run_step unit_ultra_full ./scripts/test-native-editor.sh --unit-only --ultra-full --skip-xcodegen
fi

if [ "${KERN_RUN_UI_EXHAUSTIVE:-0}" = "1" ]; then
  run_step ui_exhaustive ./scripts/test-native-editor.sh --ui-only --exhaustive --export-ui-attachments --skip-xcodegen
fi

log ""
if [ ${#FAILURES[@]} -gt 0 ]; then
  log "Result: FAIL"
  log "Failed steps:"
  for f in "${FAILURES[@]}"; do
    log " - $f"
  done
  exit 1
fi

log "Result: PASS"
log "All requested steps completed."
