#!/bin/bash
# test-native-editor.sh — Run native-editor unit + UI tests and collect artifacts.
#
# Usage:
#   ./scripts/test-native-editor.sh [--unit-only] [--ui-only] [--skip-xcodegen] [--export-ui-attachments] [--exhaustive] [--snapshots] [--record-snapshots] [--snapshots-only] [--ultra] [--ultra-full]
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
SNAPSHOTS_ONLY=false
ENABLE_ULTRA=false
ENABLE_ULTRA_FULL=false
SPEC_VENV_PATH="${KERN_SPEC_VENV_PATH:-$(pwd)/.venv-spec}"
DEFAULTS_DOMAIN="com.gradigit.kern.tests"
declare -a DEFAULT_KEYS=()

for arg in "$@"; do
  case "$arg" in
    --unit-only) RUN_UI=false ;;
    --ui-only) RUN_UNIT=false ;;
    --skip-xcodegen) SKIP_XCODEGEN=true ;;
    --export-ui-attachments) EXPORT_UI_ATTACHMENTS=true ;;
    --exhaustive) ENABLE_EXHAUSTIVE=true ;;
    --snapshots) ENABLE_SNAPSHOTS=true ;;
    --record-snapshots) ENABLE_SNAPSHOTS=true; RECORD_SNAPSHOTS=true ;;
    --snapshots-only) ENABLE_SNAPSHOTS=true; SNAPSHOTS_ONLY=true ;;
    --ultra) ENABLE_ULTRA=true; ENABLE_EXHAUSTIVE=true ;;
    --ultra-full) ENABLE_ULTRA=true; ENABLE_ULTRA_FULL=true; ENABLE_EXHAUSTIVE=true ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

prepare_spec_oracle_env() {
  local py="$SPEC_VENV_PATH/bin/python3"
  if [ ! -x "$py" ]; then
    echo "▸ Creating markdown spec oracle venv..."
    python3 -m venv "$SPEC_VENV_PATH"
  fi
  if ! "$py" -c "import cmarkgfm" >/dev/null 2>&1; then
    echo "▸ Installing markdown spec oracle dependency (cmarkgfm)..."
    "$py" -m pip install --upgrade pip >/dev/null
    "$py" -m pip install --quiet cmarkgfm
  fi
  # Pass spec oracle configuration through environment so XCTest always sees it,
  # even when UserDefaults suite propagation is delayed or unavailable.
  export KERN_SPEC_ORACLE_PYTHON="$py"
  export KERN_ENABLE_SPEC_CONFORMANCE_TESTS="1"
  write_suite_value "KERN_SPEC_ORACLE_PYTHON" "$py"
  write_suite_value "KERN_ENABLE_SPEC_CONFORMANCE_TESTS" "1"
}

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
  # XCTest runners launched by xcodebuild do not always inherit shell-set KERN_* vars.
  # Mirror all explicit KERN_* overrides into the shared test defaults suite so tests
  # can read deterministic runtime config via UserDefaults fallback.
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

fail_on_skipped_tests() {
  local log_file="$1"
  local lane="$2"

  if [ "${KERN_FAIL_ON_SKIPPED:-0}" != "1" ]; then
    return 0
  fi

  if [ ! -f "$log_file" ]; then
    return 0
  fi

  local skipped_count
  skipped_count="$(grep -c "Test skipped -" "$log_file" || true)"
  if [ "${skipped_count:-0}" -gt 0 ]; then
    echo "$lane contains skipped tests ($skipped_count) while KERN_FAIL_ON_SKIPPED=1." >&2
    echo "First skipped entries:" >&2
    grep -n "Test skipped -" "$log_file" | head -20 >&2 || true
    return 1
  fi

  return 0
}

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/test-results/native-editor/$TS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/.derived-data/tests}"

mkdir -p "$OUT_DIR"

ALWAYS_EXPORT_ATTACHMENTS=false
if [ "${KERN_EXPORT_UI_ATTACHMENTS:-}" = "1" ] || [ "$EXPORT_UI_ATTACHMENTS" = true ]; then
  ALWAYS_EXPORT_ATTACHMENTS=true
fi

UI_RESULT_BUNDLE="$OUT_DIR/KernTextKitUI.xcresult"

export_ui_attachments() {
  if [ ! -d "$UI_RESULT_BUNDLE" ]; then
    return 0
  fi

  echo "▸ Exporting UI test attachments (screenshots/logs)..."
  ATT_DIR="$OUT_DIR/ui-attachments"
  mkdir -p "$ATT_DIR"
  xcrun xcresulttool export attachments \
    --path "$UI_RESULT_BUNDLE" \
    --output-path "$ATT_DIR" \
    >/dev/null 2>&1 || true
  # xcresulttool can export screenshots as HEIC depending on Xcode/macOS.
  # Convert to PNG for tooling compatibility (keeps original .heic files).
  "$(pwd)/scripts/convert-heic-to-png.sh" "$ATT_DIR" >/dev/null 2>&1 || true
  echo "  Attachments: $ATT_DIR"
}

# If the UI runner (or the system) crashes mid-test (e.g., WindowServer restarts), still try to
# export whatever artifacts were produced so failures are diagnosable.
trap 'cleanup_suite_values; if [ "$RUN_UI" = true ] && [ "$ALWAYS_EXPORT_ATTACHMENTS" = true ]; then export_ui_attachments; fi' EXIT INT TERM

reset_suite_domain
sync_kernel_env_to_suite

# Exhaustive mode should be strict by default: no skipped tests and full matrices enabled.
if [ "$ENABLE_EXHAUSTIVE" = true ]; then
  if [ -z "${KERN_FAIL_ON_SKIPPED+x}" ]; then
    export KERN_FAIL_ON_SKIPPED=1
  fi
  write_suite_value "KERN_FAIL_ON_SKIPPED" "${KERN_FAIL_ON_SKIPPED}"
  set_default_kernel_value "KERN_ENABLE_EXHAUSTIVE_TESTS" "1"

  if [ "$RUN_UNIT" = true ]; then
    set_default_kernel_value "KERN_EXHAUSTIVE_ACTION_FULL" "1"
    set_default_kernel_value "KERN_EXHAUSTIVE_ULTIMATE_FULL" "1"
    set_default_kernel_value "KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_FULL" "1"
    set_default_kernel_value "KERN_ENABLE_MEGA_CHAR_BY_CHAR" "1"
    set_default_kernel_value "KERN_ENABLE_MEGA_ALL_PROFILE_MATRIX" "1"
    set_default_kernel_value "KERN_ENABLE_SNAPSHOT_TESTS" "1"
    set_default_kernel_value "KERN_ENABLE_PERF_TESTS" "1"
    set_default_kernel_value "KERN_PERF_RENDER_FULL" "1"
    set_default_kernel_value "KERN_PERF_ENABLE_ULTIMATE_RENDER" "1"
  fi
fi

if [ "$ENABLE_SNAPSHOTS" = true ] || [ "$RECORD_SNAPSHOTS" = true ]; then
  set_default_kernel_value "KERN_ENABLE_SNAPSHOT_TESTS" "1"
fi

if [ "$RECORD_SNAPSHOTS" = true ]; then
  set_default_kernel_value "KERN_RECORD_SNAPSHOTS" "1"
fi

# UI runs should be deterministic and match manual validation defaults.
# Keep appearance explicit to avoid accidental light/dark drift between runs.
if [ "$RUN_UI" = true ]; then
  if [ -z "${KERN_UI_TEST_APPEARANCE+x}" ]; then
    if [ -n "${KERN_TEST_APPEARANCE+x}" ]; then
      export KERN_UI_TEST_APPEARANCE="$KERN_TEST_APPEARANCE"
    else
      export KERN_UI_TEST_APPEARANCE="dark"
    fi
  fi
  write_suite_value "KERN_UI_TEST_APPEARANCE" "${KERN_UI_TEST_APPEARANCE}"
fi

# Exhaustive UI should include full live-typing coverage by default. Allow explicit opt-out
# via KERN_UI_ENABLE_LIVE_TYPING=0 for faster local debugging loops.
if [ "$RUN_UI" = true ] && [ "$ENABLE_EXHAUSTIVE" = true ]; then
  if [ -z "${KERN_UI_ENABLE_LIVE_TYPING+x}" ]; then
    export KERN_UI_ENABLE_LIVE_TYPING=1
  fi
  write_suite_value "KERN_UI_ENABLE_LIVE_TYPING" "${KERN_UI_ENABLE_LIVE_TYPING}"

  # Use ultimate by default for exhaustive UI live typing: still permutation-dense,
  # but practical enough to finish and iterate in one session.
  if [ -z "${KERN_UI_TYPING_FIXTURE+x}" ]; then
    export KERN_UI_TYPING_FIXTURE="ultimate-stress-test.md"
  fi
  write_suite_value "KERN_UI_TYPING_FIXTURE" "${KERN_UI_TYPING_FIXTURE}"

  if [ -z "${KERN_UI_TYPING_CHUNK_SIZE+x}" ]; then
    export KERN_UI_TYPING_CHUNK_SIZE=16384
  fi
  write_suite_value "KERN_UI_TYPING_CHUNK_SIZE" "${KERN_UI_TYPING_CHUNK_SIZE}"

  # Prefer paste for runtime, with UI-test-level fallback to typed insertion if needed.
  if [ -z "${KERN_UI_CHUNK_INSERTION+x}" ]; then
    export KERN_UI_CHUNK_INSERTION=paste
  fi
  write_suite_value "KERN_UI_CHUNK_INSERTION" "${KERN_UI_CHUNK_INSERTION}"
fi

echo "=== Kern Native Editor Tests ==="
echo "Output: $OUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo ""
echo "Modes:"
echo "  --snapshots          Run snapshot tests (via scheme: KernTextKitSnapshots)"
echo "  --record-snapshots   Record snapshot baselines (via scheme: KernTextKitRecordSnapshots)"
echo "  --exhaustive         Enable exhaustive (slow) tests (via *Exhaustive schemes)"
echo "  --snapshots-only     Run only snapshot tests (skips non-snapshot unit tests)"
echo ""
echo "Env toggles (optional):"
echo "  KERN_EXPORT_UI_ATTACHMENTS=1   Always export UI attachments (otherwise only on failure)"
echo "  KERN_UI_SCREENSHOTS=always     Keep UI screenshots on success (default)"
echo "  KERN_UI_SCREENSHOTS=failure    Only keep UI screenshots on failure (faster)"
echo "  KERN_UI_SCREENSHOTS=off        Disable UI screenshots (fastest)"
echo "  KERN_UI_ENABLE_LIVE_TYPING=1   Enable long exhaustive UI live-typing matrix (default: enabled in --exhaustive)"
echo "  KERN_UI_ENABLE_LIVE_TYPING=0   Disable long exhaustive UI live-typing matrix"
echo "  KERN_UI_REQUIRE_AX_TRUST=1     Strict Accessibility preflight (skip UI tests when not trusted)"
echo "  KERN_UI_AX_PROMPT=1            Prompt for Accessibility trust during UI preflight"
echo "  KERN_UI_SCREENSHOT_DIR=/path   Write UI PNGs to disk (runner sets automatically)"
echo "  KERN_UI_TYPING_FIXTURE=...     Exhaustive UI full-typing fixture (default in --exhaustive: ultimate-stress-test.md)"
echo "  KERN_UI_TYPING_MODE=character|chunked  Exhaustive UI typing mode (default: chunked)"
echo "  KERN_UI_TYPING_CHUNK_SIZE=16384 Exhaustive UI typing chunk size (default in --exhaustive)"
echo "  KERN_UI_CHUNK_INSERTION=paste|type  Chunked insertion strategy (default: paste in --exhaustive, with fallback)"
echo "  KERN_UI_TEST_APPEARANCE=dark|light  UI test app appearance (default: dark)"
echo "  KERN_UI_ACTION_DEPTH=1|2|3     Exhaustive UI action permutation depth"
echo "  KERN_UI_ACTION_LIMIT=N         Exhaustive UI action program cap (unset = all)"
echo "  KERN_EXHAUSTIVE_PROFILE_LIMIT=N                Cap non-UI exhaustive profile permutations"
echo "  KERN_EXHAUSTIVE_ACTION_FULL=1                  Run full feature x action x profile matrix"
echo "  KERN_EXHAUSTIVE_ACTION_SCENARIO_BUDGET=N       Budget for bounded action matrix mode"
echo "  KERN_EXHAUSTIVE_ACTION_LOG_LIMIT=N             Max per-scenario action rows in report"
echo "  KERN_EXHAUSTIVE_ACTION_PROGRESS_EVERY=N        Emit action matrix progress rows every N scenarios"
echo "  KERN_EXHAUSTIVE_ACTION_EXPORT_INTERVAL=N       Export-check interval for action matrix scenarios"
echo "  KERN_EXHAUSTIVE_ACTION_ROUNDTRIP_INTERVAL=N    Round-trip check interval for action matrix scenarios"
echo "  KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_COUNT=N   Shard exhaustive action matrix profiles"
echo "  KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_INDEX=I   Action matrix shard index (0-based)"
echo "  KERN_EXHAUSTIVE_INTERLEAVED_PROFILE_LIMIT=N    Cap ultimate interleaved profile permutations"
echo "  KERN_EXHAUSTIVE_INTERLEAVED_PROGRAM_LIMIT=N    Cap ultimate interleaved action programs"
echo "  KERN_EXHAUSTIVE_ULTIMATE_PROFILE_LIMIT=N       Cap ultimate char-by-char profile permutations"
echo "  KERN_EXHAUSTIVE_ULTIMATE_CHAR_LIMIT=N          Cap bytes typed in ultimate char-by-char test"
echo "  KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_CHAR_LIMIT=N  Cap bytes typed in ultimate interleaved test"
echo "  KERN_EXHAUSTIVE_ULTIMATE_FULL=1                Run ultimate char-by-char across all profiles"
echo "  KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_FULL=1    Run ultimate interleaved across all profiles/programs"
echo "  KERN_EXHAUSTIVE_MEGA_INTERLEAVED_PROGRAM_LIMIT=N Cap mega interleaved action programs"
echo "  KERN_EXHAUSTIVE_MEGA_CHAR_LIMIT=N              Cap bytes typed in mega char-by-char test"
echo "  KERN_EXHAUSTIVE_MEGA_INTERLEAVED_CHAR_LIMIT=N  Cap bytes typed in mega interleaved tests"
echo "  KERN_ENABLE_MEGA_CHAR_BY_CHAR=1                Enable mega char-by-char typing test"
echo "  KERN_ENABLE_MEGA_ALL_PROFILE_MATRIX=1          Enable mega all-profile interleaved test"
echo "  KERN_EXHAUSTIVE_PROFILE_SHARD_COUNT=N          Shard non-UI profile matrix"
echo "  KERN_EXHAUSTIVE_PROFILE_SHARD_INDEX=I          Shard index (0-based)"
echo "  KERN_ENABLE_PERF_TESTS=1                       Enable perf-only benchmark tests"
echo "  KERN_PERF_ITERATIONS=N                         Perf measure iterations per case"
echo "  KERN_PERF_RENDER_FULL=1                        Run render/scroll perf on full fixtures"
echo "  KERN_PERF_ENABLE_ULTIMATE_RENDER=1             Enable heavy ultimate render perf case"
echo "  KERN_PERF_BENCHMARK_RENDER_CHAR_LIMIT=N        Cap chars for benchmark render perf case"
echo "  KERN_PERF_STRESS_RENDER_CHAR_LIMIT=N           Cap chars for stress render perf case"
echo "  KERN_PERF_ULTIMATE_RENDER_CHAR_LIMIT=N         Cap chars for ultimate render perf case"
echo "  KERN_PERF_MEGA_RENDER_CHAR_LIMIT=N             Cap chars for mega render perf case"
echo "  KERN_PERF_MEGA_SCROLL_CHAR_LIMIT=N             Cap chars for mega scroll perf case"
echo "  KERN_PERF_ULTIMATE_CHAR_LIMIT=N                Cap chars for ultimate typing perf case"
echo "  KERN_PERF_ULTIMATE_INTERLEAVED_CHAR_LIMIT=N    Cap chars for ultimate interleaved perf case"
echo "  KERN_PERF_MEGA_CHAR_LIMIT=N                    Cap chars for mega typing perf case"
echo "  KERN_PERF_MEGA_INTERLEAVED_CHAR_LIMIT=N        Cap chars for mega interleaved perf case"
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
if [ "$ENABLE_ULTRA" = true ] && [ "$ENABLE_SNAPSHOTS" = false ] && [ "$RECORD_SNAPSHOTS" = false ]; then
  UNIT_SCHEME="KernTextKitUltraExhaustive"
fi
if [ "$ENABLE_ULTRA_FULL" = true ] && [ "$ENABLE_SNAPSHOTS" = false ] && [ "$RECORD_SNAPSHOTS" = false ]; then
  UNIT_SCHEME="KernTextKitUltraExhaustiveFull"
fi

UI_SCHEME="KernTextKitUI"
if [ "$ENABLE_EXHAUSTIVE" = true ]; then
  UI_SCHEME="KernTextKitUIExhaustive"
fi
if [ "$ENABLE_ULTRA" = true ]; then
  UI_SCHEME="KernTextKitUIUltraExhaustive"
fi

NEED_XCODEGEN=true
if [ "$SKIP_XCODEGEN" = true ]; then
  NEED_XCODEGEN=false
fi

# Xcodegen needs to run whenever the set of source files changes (new tests, new files, etc.).
# Relying only on `project.yml` mtime is insufficient because adding a new file doesn't touch it.
PBXPROJ="KernTextKit.xcodeproj/project.pbxproj"
if [ -f "$PBXPROJ" ] && [ "$PBXPROJ" -nt "project.yml" ]; then
  NEED_XCODEGEN=false

  # If any sources/tests/ui-tests/resources are newer than the generated pbxproj,
  # re-run xcodegen so the project includes them.
  if find KernApp/Sources KernTests KernUITests -type f \( -name "*.swift" -o -name "*.xcassets" \) -newer "$PBXPROJ" 2>/dev/null | grep -q .; then
    NEED_XCODEGEN=true
  fi
fi

# Guard against silent false-green runs when files exist on disk but are missing from the Xcode project.
# This can happen when a file was added before the current pbxproj timestamp.
if [ "$SKIP_XCODEGEN" = false ] && [ "$NEED_XCODEGEN" = false ] && [ -f "$PBXPROJ" ]; then
  MISSING_REF=false
  while IFS= read -r swift_file; do
    base="$(basename "$swift_file")"
    if ! grep -Fq "path = $base;" "$PBXPROJ"; then
      MISSING_REF=true
      echo "▸ Detected source not referenced in Xcode project: $swift_file"
      break
    fi
  done < <(find KernApp/Sources KernTests KernUITests -type f -name "*.swift" | sort)
  if [ "$MISSING_REF" = true ]; then
    NEED_XCODEGEN=true
  fi
fi

if [ "$NEED_XCODEGEN" = true ]; then
  echo "▸ Generating Xcode project (xcodegen)..."
  xcodegen 2>&1 | tail -1
else
  echo "▸ Skipping xcodegen (project up-to-date)."
fi

echo ""

if [ "$RUN_UNIT" = true ]; then
  if [ "$ENABLE_EXHAUSTIVE" = true ]; then
    prepare_spec_oracle_env
  fi

  ONLY_TESTING_ARGS=()
  if [ "$SNAPSHOTS_ONLY" = true ]; then
    ONLY_TESTING_ARGS+=("-only-testing:KernTextKitTests/NativeEditorSnapshotTests")
  fi

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
      ${ONLY_TESTING_ARGS[@]+"${ONLY_TESTING_ARGS[@]}"} \
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
      ${ONLY_TESTING_ARGS[@]+"${ONLY_TESTING_ARGS[@]}"} \
      test \
      2>&1 | tee "$OUT_DIR/unit.log"
    UNIT_STATUS=${PIPESTATUS[0]}
    set -e
    if [ $UNIT_STATUS -ne 0 ]; then
      echo "Snapshot verification failed (exit $UNIT_STATUS). See: $OUT_DIR/unit.log" >&2
      exit $UNIT_STATUS
    fi
    if ! fail_on_skipped_tests "$OUT_DIR/unit.log" "Unit snapshot verification"; then
      exit 4
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
      ${ONLY_TESTING_ARGS[@]+"${ONLY_TESTING_ARGS[@]}"} \
      test \
      2>&1 | tee "$OUT_DIR/unit.log"
    UNIT_STATUS=${PIPESTATUS[0]}
    set -e
    if [ $UNIT_STATUS -ne 0 ]; then
      echo "Unit tests failed (exit $UNIT_STATUS). See: $OUT_DIR/unit.log" >&2
      exit $UNIT_STATUS
    fi
    if ! fail_on_skipped_tests "$OUT_DIR/unit.log" "Unit tests"; then
      exit 4
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

  env KERN_UI_SCREENSHOT_DIR="$UI_SCREENSHOT_DIR" KERN_UI_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" KERN_UI_TYPING_MODE="${KERN_UI_TYPING_MODE:-chunked}" KERN_UI_TEST_APPEARANCE="${KERN_UI_TEST_APPEARANCE}" xcodebuild \
    -project KernTextKit.xcodeproj \
    -scheme "$UI_SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$OUT_DIR/KernTextKitUI.xcresult" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    test \
    2>&1 | tee "$OUT_DIR/ui.log"
  UI_STATUS=${PIPESTATUS[0]}
  set -e

  if [ $UI_STATUS -ne 0 ]; then
    echo "UI tests failed (exit $UI_STATUS). See: $OUT_DIR/ui.log" >&2
  else
    echo "  ✓ UI tests passed"
  fi

  # Xcode reports success even when all UI tests are skipped, which is misleading for an "exhaustive"
  # suite. Treat "all skipped" as a failure so we don't get green runs without coverage.
  if [ $UI_STATUS -eq 0 ]; then
    if ! fail_on_skipped_tests "$OUT_DIR/ui.log" "UI tests"; then
      UI_STATUS=4
    fi

    SKIP_SUMMARY_LINE="$(grep -E "Executed [0-9]+ tests, with [0-9]+ tests skipped" "$OUT_DIR/ui.log" | tail -1 || true)"
    if [ -n "$SKIP_SUMMARY_LINE" ]; then
      EXECUTED_COUNT="$(echo "$SKIP_SUMMARY_LINE" | sed -E 's/.*Executed ([0-9]+) tests.*/\1/')"
      SKIPPED_COUNT="$(echo "$SKIP_SUMMARY_LINE" | sed -E 's/.*with ([0-9]+) tests skipped.*/\1/')"
      if [ "${EXECUTED_COUNT:-0}" -gt 0 ] && [ "${SKIPPED_COUNT:-0}" -eq "${EXECUTED_COUNT:-0}" ]; then
        echo "UI tests did not actually run (all tests were skipped)." >&2
        echo "See: $OUT_DIR/ui.log" >&2
        echo "Common fixes: unlock the Mac; grant Accessibility/Automation permissions to Xcode and KernTextKitUITests-Runner." >&2
        exit 3
      fi
    fi
  fi

  echo ""
  if [ $UI_STATUS -ne 0 ] || [ "$ALWAYS_EXPORT_ATTACHMENTS" = true ]; then
    export_ui_attachments
  else
    echo "▸ Skipping UI attachment export (set KERN_EXPORT_UI_ATTACHMENTS=1 or pass --export-ui-attachments)"
  fi

  if [ $UI_STATUS -ne 0 ]; then
    exit $UI_STATUS
  fi
fi

echo "All selected test suites completed."
