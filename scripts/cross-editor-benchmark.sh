#!/usr/bin/env bash
# cross-editor-benchmark.sh — Stable entrypoint wrapper for kern-bench single benchmark mode.

set -euo pipefail
cd "$(dirname "$0")/.."

SUITE="benchmark"
FILE=""
RUNS=""
WARMUP_RUNS=""
STARTUP_PROBES=""
MODE="warm"
JSON_PATH=""
MARKDOWN_PATH=""
EDITORS_FILTER=""
EDITOR_ARGS=()
EXPLICIT_ALL=false
TIMEOUT=""
RUN_TIMEOUT=""
SUITE_TIMEOUT=""
INTER_EDITOR_DELAY_MS=""
VERBOSE=false
NO_SCREENCAPTURE=false
ENABLE_FRAME_MONITOR=false
SAVE_DURABLE=false
DISABLE_WOW_METRICS=false
KERN_OPEN_METRIC_SOURCE=""
ZED_BENCH_HOOK=""
ZED_READY_MODE=""
SELECTED_EDITORS=()
USES_ALL_EDITORS=false
NEEDS_ZED=false
ZED_CLI_SOURCE=""

cleanup_editors() {
  local app_names=("Kern" "Visual Studio Code" "Zed" "Sublime Text" "TextEdit")
  local process_names=("Kern" "Code" "zed" "cli" "sublime_text" "TextEdit")
  local bundle_ids=("com.gradigit.kern" "com.microsoft.VSCode" "dev.zed.Zed" "com.sublimetext.4" "com.apple.TextEdit")

  for name in "${app_names[@]}"; do
    /usr/bin/killall -9 "$name" >/dev/null 2>&1 || true
  done
  for pname in "${process_names[@]}"; do
    /usr/bin/pkill -9 -x "$pname" >/dev/null 2>&1 || true
  done
  for bid in "${bundle_ids[@]}"; do
    /usr/bin/pkill -9 -f "$bid" >/dev/null 2>&1 || true
  done
  /usr/bin/pkill -9 -f "zed-fork-bench/target/.*/cli" >/dev/null 2>&1 || true
}

expand_tilde_path() {
  local path="$1"
  if [[ "$path" == "~"* ]]; then
    printf '%s' "${HOME}${path:1}"
    return 0
  fi
  printf '%s' "$path"
}

editor_list_includes_zed() {
  local editor_name
  for editor_name in "$@"; do
    local normalized
    normalized="$(echo "$editor_name" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ "$normalized" == "zed" ]]; then
      return 0
    fi
  done
  return 1
}

resolve_forked_zed_cli() {
  local candidates=(
    "${HOME}/Projects/zed-fork-bench/target/release/cli"
    "${HOME}/Projects/zed-fork-bench/target/debug/cli"
    "$(pwd)/../zed-fork-bench/target/release/cli"
    "$(pwd)/../zed-fork-bench/target/debug/cli"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) SUITE="$2"; shift 2 ;;
    --cold) MODE="cold"; shift ;;
    --warm) MODE="warm"; shift ;;
    --json) JSON_PATH="$2"; shift 2 ;;
    --markdown) MARKDOWN_PATH="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --warmup-runs) WARMUP_RUNS="$2"; shift 2 ;;
    --startup-probes) STARTUP_PROBES="$2"; shift 2 ;;
    --all) EXPLICIT_ALL=true; shift ;;
    --editors) EDITORS_FILTER="$2"; shift 2 ;;
    --editor) EDITOR_ARGS+=("$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --run-timeout) RUN_TIMEOUT="$2"; shift 2 ;;
    --suite-timeout) SUITE_TIMEOUT="$2"; shift 2 ;;
    --inter-editor-delay-ms) INTER_EDITOR_DELAY_MS="$2"; shift 2 ;;
    --save-durable) SAVE_DURABLE=true; shift ;;
    --no-screencapture) NO_SCREENCAPTURE=true; shift ;;
    --enable-frame-monitor) ENABLE_FRAME_MONITOR=true; shift ;;
    --disable-wow-metrics) DISABLE_WOW_METRICS=true; shift ;;
    --kern-open-metric-source) KERN_OPEN_METRIC_SOURCE="$2"; shift 2 ;;
    --zed-bench-hook) ZED_BENCH_HOOK="$2"; shift 2 ;;
    --zed-ready-mode) ZED_READY_MODE="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --file) FILE="$2"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: ./scripts/cross-editor-benchmark.sh [options] [file]

Options:
  --suite benchmark|benchmark_open_ready|benchmark_full_fidelity|wow_internal
                        Benchmark mode (default: benchmark)
  --cold                Purge cache between measured runs
  --warm                Warm mode (default)
  --runs N              Measured run count
  --warmup-runs N       Warmup run count
  --startup-probes N    Cold+warm startup probes per editor (default: 0)
  --all                 Benchmark all installed roster editors (default behavior)
  --json PATH           Write JSON report
  --markdown PATH       Write markdown report
  --editors LIST        Comma-separated roster editor names
  --timeout SEC         Per-stage timeout
  --run-timeout SEC     Per editor-run timeout budget
  --suite-timeout SEC   Overall suite timeout budget
  --inter-editor-delay-ms N
                        Delay between editors in a round (default: 0)
  --save-durable      Collect durable-save metric (disabled by default)
  --no-screencapture    Disable ScreenCaptureKit
  --enable-frame-monitor
                        Enable optional first-paint/render-stable probes
  --disable-wow-metrics  Disable Kern WOW metric env injection
  --kern-open-metric-source MODE
                        Kern open metric source: auto|wow|probe
  --zed-bench-hook MODE  Zed hook mode: auto|off|required
  --zed-ready-mode MODE  Zed bench-ready mode label
  --verbose, -v         Verbose output
  --file PATH           Benchmark fixture file

Policy:
  - benchmark suite uses locked roster v1: Kern, VS Code, Zed, Sublime Text, TextEdit
  - benchmark_open_ready is an optional aside mode (open-readiness only; defaults to Kern+Zed)
  - benchmark_full_fidelity is an optional aside mode (full-fidelity completion; defaults to Kern+Zed)
  - Any run that includes Zed enforces the forked Zed CLI (auto-detected or KERN_BENCH_ZED_CLI)
  - Partial runs are not eligible for README/social headline claims
EOF
      exit 0
      ;;
    -* )
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$FILE" ]]; then
        FILE="$1"
      elif [[ -z "$RUNS" ]]; then
        RUNS="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

case "$SUITE" in
  benchmark|bench)
    ;;
  benchmark_open_ready|benchmark-open-ready|benchmarkopenready|open_ready|open-ready|openonly|open_only)
    SUITE="benchmark_open_ready"
    ;;
  benchmark_full_fidelity|benchmark-full-fidelity|benchmarkfullfidelity|full_fidelity|full-fidelity|fidelity)
    SUITE="benchmark_full_fidelity"
    ;;
  wow_internal|wow-internal|wowinternal)
    SUITE="wow_internal"
    ;;
  wow|real_use|real-use|realuse)
    echo "Error: legacy suite alias '$SUITE' is no longer accepted. Use benchmark, benchmark_open_ready, benchmark_full_fidelity, or wow_internal." >&2
    exit 1
    ;;
  *)
    echo "Error: --suite must be benchmark, benchmark_open_ready, benchmark_full_fidelity, or wow_internal" >&2
    exit 1
    ;;
esac

if [[ -z "$FILE" ]]; then
  if [[ "$SUITE" == "wow_internal" ]]; then
    FILE="test-fixtures/cross-editor-benchmark.md"
  elif [[ "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ]]; then
    FILE="test-fixtures/native-editor-benchmark.md"
  else
    FILE="test-fixtures/cross-editor-benchmark.md"
  fi
fi
if [[ ! -f "$FILE" ]]; then
  echo "Error: file not found: $FILE" >&2
  exit 1
fi

KERN_BENCH_BIN="scripts/kern-bench/.build/release/kern-bench"
NEEDS_KERN_BENCH_BUILD=false
if [[ ! -x "$KERN_BENCH_BIN" ]]; then
  NEEDS_KERN_BENCH_BUILD=true
elif [[ "scripts/kern-bench/Package.swift" -nt "$KERN_BENCH_BIN" ]]; then
  NEEDS_KERN_BENCH_BUILD=true
elif [[ -n "$(find scripts/kern-bench/Sources scripts/kern-bench/Tests -type f -newer "$KERN_BENCH_BIN" -print -quit 2>/dev/null)" ]]; then
  NEEDS_KERN_BENCH_BUILD=true
fi

if [[ "$NEEDS_KERN_BENCH_BUILD" == true ]]; then
  echo "Building kern-bench..."
  (cd scripts/kern-bench && swift build -c release)
fi

CMD=("$KERN_BENCH_BIN" "--suite" "$SUITE" "--file" "$FILE")

if [[ "$MODE" == "cold" ]]; then
  CMD+=("--cold")
else
  CMD+=("--warm")
fi

if [[ -n "$RUNS" ]]; then CMD+=("--runs" "$RUNS"); fi
if [[ -n "$WARMUP_RUNS" ]]; then CMD+=("--warmup-runs" "$WARMUP_RUNS"); fi
if [[ -n "$STARTUP_PROBES" ]]; then CMD+=("--startup-probes" "$STARTUP_PROBES"); fi
if [[ -n "$JSON_PATH" ]]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  CMD+=("--json" "$JSON_PATH")
fi
if [[ -n "$MARKDOWN_PATH" ]]; then
  mkdir -p "$(dirname "$MARKDOWN_PATH")"
  CMD+=("--markdown" "$MARKDOWN_PATH")
fi
if [[ -n "$TIMEOUT" ]]; then CMD+=("--timeout" "$TIMEOUT"); fi
if [[ -n "$RUN_TIMEOUT" ]]; then CMD+=("--run-timeout" "$RUN_TIMEOUT"); fi
if [[ -n "$SUITE_TIMEOUT" ]]; then CMD+=("--suite-timeout" "$SUITE_TIMEOUT"); fi
if [[ -n "$INTER_EDITOR_DELAY_MS" ]]; then CMD+=("--inter-editor-delay-ms" "$INTER_EDITOR_DELAY_MS"); fi
if [[ "$SAVE_DURABLE" == true ]]; then CMD+=("--save-durable"); fi
if [[ "$NO_SCREENCAPTURE" == true ]]; then CMD+=("--no-screencapture"); fi
if [[ "$ENABLE_FRAME_MONITOR" == true ]]; then CMD+=("--enable-frame-monitor"); fi
if [[ "$DISABLE_WOW_METRICS" == true ]]; then CMD+=("--disable-wow-metrics"); fi

if [[ "$SUITE" == "benchmark_full_fidelity" ]]; then
  if [[ -z "$ZED_BENCH_HOOK" ]]; then ZED_BENCH_HOOK="required"; fi
  if [[ -z "$ZED_READY_MODE" ]]; then ZED_READY_MODE="styled_stable"; fi
  if [[ -z "$KERN_OPEN_METRIC_SOURCE" ]]; then KERN_OPEN_METRIC_SOURCE="wow"; fi
fi

if [[ -n "$KERN_OPEN_METRIC_SOURCE" ]]; then CMD+=("--kern-open-metric-source" "$KERN_OPEN_METRIC_SOURCE"); fi
if [[ -n "$ZED_BENCH_HOOK" ]]; then CMD+=("--zed-bench-hook" "$ZED_BENCH_HOOK"); fi
if [[ -n "$ZED_READY_MODE" ]]; then CMD+=("--zed-ready-mode" "$ZED_READY_MODE"); fi
if [[ "$VERBOSE" == true ]]; then CMD+=("--verbose"); fi

if [[ ${#EDITOR_ARGS[@]} -gt 0 ]]; then
  for editor in "${EDITOR_ARGS[@]}"; do
    CMD+=("--editor" "$editor")
  done
elif [[ -n "$EDITORS_FILTER" ]]; then
  IFS=',' read -ra EDITOR_LIST <<< "$EDITORS_FILTER"
  for editor in "${EDITOR_LIST[@]}"; do
    trimmed="$(echo "$editor" | xargs)"
    if [[ -n "$trimmed" ]]; then
      CMD+=("--editor" "$trimmed")
    fi
  done
elif [[ "$EXPLICIT_ALL" == true ]]; then
  USES_ALL_EDITORS=true
  CMD+=("--all")
elif [[ "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ]]; then
  SELECTED_EDITORS=("Kern" "Zed")
  CMD+=("--editor" "Kern" "--editor" "Zed")
else
  USES_ALL_EDITORS=true
  CMD+=("--all")
fi

if [[ ${#EDITOR_ARGS[@]} -gt 0 ]]; then
  SELECTED_EDITORS=("${EDITOR_ARGS[@]}")
elif [[ -n "$EDITORS_FILTER" ]]; then
  IFS=',' read -ra FILTER_EDITORS <<< "$EDITORS_FILTER"
  SELECTED_EDITORS=()
  for editor in "${FILTER_EDITORS[@]}"; do
    trimmed="$(echo "$editor" | xargs)"
    if [[ -n "$trimmed" ]]; then
      SELECTED_EDITORS+=("$trimmed")
    fi
  done
fi

if [[ "$USES_ALL_EDITORS" == true ]]; then
  if [[ "$SUITE" != "wow_internal" ]]; then
    NEEDS_ZED=true
  fi
elif editor_list_includes_zed "${SELECTED_EDITORS[@]}"; then
  NEEDS_ZED=true
fi

if [[ "$NEEDS_ZED" == true ]]; then
  if [[ -n "${KERN_BENCH_ZED_CLI:-}" ]]; then
    resolved_override="$(expand_tilde_path "${KERN_BENCH_ZED_CLI}")"
    if [[ ! -x "$resolved_override" ]]; then
      echo "Error: KERN_BENCH_ZED_CLI is set but not executable: $resolved_override" >&2
      exit 1
    fi
    export KERN_BENCH_ZED_CLI="$resolved_override"
    ZED_CLI_SOURCE="env"
  else
    if ! resolved_fork_cli="$(resolve_forked_zed_cli)"; then
      echo "Error: forked Zed CLI not found." >&2
      echo "Expected one of:" >&2
      echo "  $HOME/Projects/zed-fork-bench/target/release/cli" >&2
      echo "  $HOME/Projects/zed-fork-bench/target/debug/cli" >&2
      echo "  ../zed-fork-bench/target/release/cli (relative to Kern-textkit)" >&2
      echo "  ../zed-fork-bench/target/debug/cli (relative to Kern-textkit)" >&2
      echo "Build your forked Zed first, then rerun the benchmark." >&2
      exit 1
    fi
    export KERN_BENCH_ZED_CLI="$resolved_fork_cli"
    ZED_CLI_SOURCE="auto-fork"
  fi
fi

trap cleanup_editors INT TERM ERR

echo "=== Cross-Editor Benchmark Wrapper ==="
echo "Suite: $SUITE"
echo "File:  $FILE"
echo "Mode:  $MODE"
if [[ ( "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ) && -z "$EDITORS_FILTER" && ${#EDITOR_ARGS[@]} -eq 0 && "$EXPLICIT_ALL" != true ]]; then
  echo "Editors default: Kern, Zed (override with --editors or --all)"
fi
if [[ "$NEEDS_ZED" == true ]]; then
  echo "Zed CLI: fork ($ZED_CLI_SOURCE)"
fi
echo "Policy: suite-specific roster/classification policy enforced"
echo "Claims: README/social headline claims require Official runs"
echo ""

set +e
"${CMD[@]}"
status=$?
set -e

if /usr/bin/pgrep -f "com.gradigit.kern|com.microsoft.VSCode|dev.zed.Zed|com.sublimetext.4|com.apple.TextEdit" >/dev/null 2>&1; then
  cleanup_editors
fi

exit "$status"
