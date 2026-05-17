#!/bin/bash
# test-native-editor.sh — Run native-editor unit tests and collect artifacts.
#
# Usage:
#   ./scripts/test-native-editor.sh [--unit-only] [--skip-xcodegen] [--exhaustive] [--snapshots|--no-snapshots] [--record-snapshots] [--snapshots-only] [--ultra] [--ultra-full]
#
# Notes:
# - Results are written under test-results/native-editor/<timestamp>/

set -euo pipefail
cd "$(dirname "$0")/.."

RUN_UNIT=true
SKIP_XCODEGEN=false
ENABLE_EXHAUSTIVE=false
ENABLE_SNAPSHOTS=true
RECORD_SNAPSHOTS=false
SNAPSHOTS_ONLY=false
ENABLE_ULTRA=false
ENABLE_ULTRA_FULL=false
SPEC_VENV_PATH="${KERN_SPEC_VENV_PATH:-$(pwd)/.venv-spec}"
SPEC_REQUIREMENTS_FILE="${KERN_SPEC_REQUIREMENTS_FILE:-$(pwd)/spec-requirements.txt}"
DEFAULTS_DOMAIN="com.gradigit.kern.tests"
declare -a DEFAULT_KEYS=()

for arg in "$@"; do
  case "$arg" in
    --unit-only) ;; # kept for backwards compat (unit is the only mode now)
    --skip-xcodegen) SKIP_XCODEGEN=true ;;
    --exhaustive) ENABLE_EXHAUSTIVE=true ;;
    --snapshots) ENABLE_SNAPSHOTS=true ;;
    --no-snapshots) ENABLE_SNAPSHOTS=false ;;
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
  if [ ! -f "$SPEC_REQUIREMENTS_FILE" ]; then
    echo "Missing markdown spec oracle requirements file: $SPEC_REQUIREMENTS_FILE" >&2
    exit 2
  fi
  if ! "$py" - "$SPEC_REQUIREMENTS_FILE" <<'PY' >/dev/null 2>&1
import importlib.metadata
import pathlib
import re
import sys

requirements = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pins = re.findall(r"^([A-Za-z0-9_.-]+)==([^\s#]+)", requirements, re.MULTILINE)
if not pins:
    raise SystemExit(1)
for package, expected in pins:
    try:
        actual = importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError:
        raise SystemExit(1)
    if actual != expected:
        raise SystemExit(1)
raise SystemExit(0)
PY
  then
    echo "▸ Installing markdown spec oracle dependencies..."
    "$py" -m pip install --upgrade pip >/dev/null
    "$py" -m pip install --quiet -r "$SPEC_REQUIREMENTS_FILE"
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

write_skip_summary() {
  local log_file="$1"
  local out_file="$2"

  if [ ! -f "$log_file" ]; then
    return 0
  fi

  python3 - "$log_file" "$out_file" <<'PY'
from pathlib import Path
import re
import sys

log_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
reason_re = re.compile(r"Test skipped - (.*)$")

counts = {
    "perf": 0,
    "exhaustive": 0,
    "snapshots": 0,
    "spec": 0,
    "report": 0,
    "other": 0,
}

for line in log_path.read_text(errors="ignore").splitlines():
    match = reason_re.search(line)
    if not match:
        continue
    reason = match.group(1)
    if "KERN_ENABLE_EXHAUSTIVE_TESTS" in reason:
        counts["exhaustive"] += 1
    elif "KERN_ENABLE_SNAPSHOT_TESTS" in reason:
        counts["snapshots"] += 1
    elif "KERN_ENABLE_SPEC_CONFORMANCE_TESTS" in reason:
        counts["spec"] += 1
    elif "KERN_ENABLE_PERF_TESTS" in reason or "KERN_ENABLE_MERMAID_MODE_BENCHMARKS" in reason:
        counts["perf"] += 1
    elif "alignment report" in reason:
        counts["report"] += 1
    else:
        counts["other"] += 1

total = sum(counts.values())
lines = [
    f"total_skipped={total}",
    f"perf={counts['perf']}",
    f"exhaustive={counts['exhaustive']}",
    f"snapshots={counts['snapshots']}",
    f"spec={counts['spec']}",
    f"report={counts['report']}",
    f"other={counts['other']}",
]
if total > 0:
    lines.append("note=default green coverage excludes snapshot/perf/exhaustive/spec lanes unless explicitly enabled")
out_path.write_text("\n".join(lines) + "\n")
PY
}

print_skip_summary_if_present() {
  local summary_file="$1"
  [ -f "$summary_file" ] || return 0

  local total_skipped
  total_skipped="$(grep '^total_skipped=' "$summary_file" | cut -d= -f2)"
  if [ -z "${total_skipped:-}" ]; then
    return 0
  fi

  echo "▸ Skipped test summary..."
  echo "  total: $total_skipped"
  echo "  perf: $(grep '^perf=' "$summary_file" | cut -d= -f2)"
  echo "  exhaustive: $(grep '^exhaustive=' "$summary_file" | cut -d= -f2)"
  echo "  snapshots: $(grep '^snapshots=' "$summary_file" | cut -d= -f2)"
  echo "  spec: $(grep '^spec=' "$summary_file" | cut -d= -f2)"
  echo "  report-only: $(grep '^report=' "$summary_file" | cut -d= -f2)"
  echo "  other: $(grep '^other=' "$summary_file" | cut -d= -f2)"
  local note
  note="$(grep '^note=' "$summary_file" | cut -d= -f2- || true)"
  if [ -n "${note:-}" ]; then
    echo "  note: $note"
  fi
  echo "  artifact: $summary_file"
  echo ""
}

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/test-results/native-editor/$TS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/.derived-data/tests}"

mkdir -p "$OUT_DIR"

trap 'cleanup_suite_values' EXIT INT TERM

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
    set_default_kernel_value "KERN_TYPING_STATEFUL_ENFORCE" "1"
    set_default_kernel_value "KERN_TYPING_STATEFUL_SEEDS" "24"
    set_default_kernel_value "KERN_TYPING_STATEFUL_STEPS" "50"
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

if [ "$ENABLE_ULTRA" = true ]; then
  set_default_kernel_value "KERN_TYPING_STATEFUL_ENFORCE" "1"
  set_default_kernel_value "KERN_TYPING_STATEFUL_SEEDS" "120"
  set_default_kernel_value "KERN_TYPING_STATEFUL_STEPS" "120"
fi

if [ "$ENABLE_ULTRA_FULL" = true ]; then
  set_default_kernel_value "KERN_TYPING_STATEFUL_ENFORCE" "1"
  set_default_kernel_value "KERN_TYPING_STATEFUL_SEEDS" "500"
  set_default_kernel_value "KERN_TYPING_STATEFUL_STEPS" "200"
fi

echo "=== Kern Native Editor Tests ==="
echo "Output: $OUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo ""
echo "Modes:"
echo "  --snapshots          Run snapshot tests (enabled by default)"
echo "  --no-snapshots       Disable snapshot tests for this run"
echo "  --record-snapshots   Record snapshot baselines (via scheme: KernTextKitRecordSnapshots)"
echo "  --exhaustive         Enable exhaustive (slow) tests (via *Exhaustive schemes)"
echo "  --snapshots-only     Run only snapshot tests (skips non-snapshot unit tests)"
echo ""
echo "Env toggles (optional):"
echo "  KERN_EXHAUSTIVE_PROFILE_LIMIT=N                Cap non-UI exhaustive profile permutations"
echo "  KERN_TYPING_STATEFUL_ENFORCE=1                 Make stateful typing sequence lane blocking"
echo "  KERN_TYPING_STATEFUL_SEEDS=N                   Stateful sequence seed count"
echo "  KERN_TYPING_STATEFUL_STEPS=N                   Stateful sequence max steps per seed"
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
  if find KernApp/Sources KernTests -type f \( -name "*.swift" -o -name "*.xcassets" \) -newer "$PBXPROJ" 2>/dev/null | grep -q .; then
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
  done < <(find KernApp/Sources KernTests -type f -name "*.swift" | sort)
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

    # Clear record mode before verification. Snapshot record mode can be
    # sourced from both environment and defaults suite, and if left enabled
    # the verify lane will intentionally fail every snapshot assertion.
    unset KERN_RECORD_SNAPSHOTS || true
    /usr/bin/defaults delete "$DEFAULTS_DOMAIN" "KERN_RECORD_SNAPSHOTS" >/dev/null 2>&1 || true

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
    write_skip_summary "$OUT_DIR/unit.log" "$OUT_DIR/skip-summary.txt"
    print_skip_summary_if_present "$OUT_DIR/skip-summary.txt"
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
    write_skip_summary "$OUT_DIR/unit.log" "$OUT_DIR/skip-summary.txt"
    print_skip_summary_if_present "$OUT_DIR/skip-summary.txt"
    echo "  ✓ Unit tests passed"
    echo ""
  fi
fi

if [ "${KERN_ENFORCE_TODO_CHECKLIST_HYGIENE:-1}" = "1" ]; then
  echo "▸ Checking complete-todo checklist hygiene..."
  python3 scripts/check-todo-complete-checklists.py
  echo "  ✓ Todo checklist hygiene passed"
  echo ""
fi

echo "All selected test suites completed."
