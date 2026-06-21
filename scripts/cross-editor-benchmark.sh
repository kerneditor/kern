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
PREFLIGHT_ONLY=false
KERN_OPEN_METRIC_SOURCE=""
ZED_BENCH_HOOK=""
ZED_READY_MODE=""
SELECTED_EDITORS=()
USES_ALL_EDITORS=false
NEEDS_ZED=false
NEEDS_KERN=false
ZED_CLI_SOURCE=""
KERN_APP_SOURCE=""
BENCH_PROFILE=""
INJECTED_OVERRIDE_PAIRS=()
declare -a CLEANUP_APP_NAMES=()
declare -a CLEANUP_PROCESS_NAMES=()
declare -a CLEANUP_BUNDLE_IDS=()
declare -a CLEANUP_FULL_PATHS=()
declare -a CLEANUP_OWNED_PIDS=()
declare -a CLEANUP_BASELINE_PATHS=()
declare -a CLEANUP_BASELINE_SNAPSHOTS=()
CLEANUP_REAPER_PID=""
CLEANUP_REAPER_STATE_FILE=""

set_cleanup_baseline_snapshot() {
  local full_path="$1"
  local snapshot="$2"
  local idx
  local count="${#CLEANUP_BASELINE_PATHS[@]}"
  for ((idx = 0; idx < count; idx++)); do
    if [[ "${CLEANUP_BASELINE_PATHS[$idx]}" == "$full_path" ]]; then
      CLEANUP_BASELINE_SNAPSHOTS[$idx]="$snapshot"
      return 0
    fi
  done
  CLEANUP_BASELINE_PATHS+=("$full_path")
  CLEANUP_BASELINE_SNAPSHOTS+=("$snapshot")
}

get_cleanup_baseline_snapshot() {
  local full_path="$1"
  local idx
  local count="${#CLEANUP_BASELINE_PATHS[@]}"
  for ((idx = 0; idx < count; idx++)); do
    if [[ "${CLEANUP_BASELINE_PATHS[$idx]}" == "$full_path" ]]; then
      printf '%s' "${CLEANUP_BASELINE_SNAPSHOTS[$idx]}"
      return 0
    fi
  done
  return 1
}

append_unique_value() {
  local array_name="$1"
  local value="$2"
  local existing
  local current_values
  [[ -n "$value" ]] || return 0
  eval "current_values=(\"\${${array_name}[@]-}\")"
  for existing in "${current_values[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  eval "${array_name}+=(\"\$value\")"
}

register_cleanup_target_for_editor() {
  local editor_name="$1"
  local normalized
  normalized="$(echo "$editor_name" | tr '[:upper:]' '[:lower:]' | xargs)"

  case "$normalized" in
    kern)
      append_unique_value CLEANUP_APP_NAMES "Kern"
      append_unique_value CLEANUP_PROCESS_NAMES "Kern"
      append_unique_value CLEANUP_BUNDLE_IDS "com.gradigit.kern"
      ;;
    "vs code"|"visual studio code")
      append_unique_value CLEANUP_APP_NAMES "Visual Studio Code"
      append_unique_value CLEANUP_PROCESS_NAMES "Code"
      append_unique_value CLEANUP_BUNDLE_IDS "com.microsoft.VSCode"
      ;;
    zed)
      append_unique_value CLEANUP_APP_NAMES "Zed"
      append_unique_value CLEANUP_PROCESS_NAMES "zed"
      append_unique_value CLEANUP_BUNDLE_IDS "dev.zed.Zed"
      ;;
    "sublime text")
      append_unique_value CLEANUP_APP_NAMES "Sublime Text"
      append_unique_value CLEANUP_PROCESS_NAMES "sublime_text"
      append_unique_value CLEANUP_BUNDLE_IDS "com.sublimetext.4"
      ;;
    textedit)
      append_unique_value CLEANUP_APP_NAMES "TextEdit"
      append_unique_value CLEANUP_PROCESS_NAMES "TextEdit"
      append_unique_value CLEANUP_BUNDLE_IDS "com.apple.TextEdit"
      ;;
    typora)
      append_unique_value CLEANUP_APP_NAMES "Typora"
      append_unique_value CLEANUP_PROCESS_NAMES "Typora"
      append_unique_value CLEANUP_BUNDLE_IDS "abnerworks.Typora"
      ;;
  esac
}

build_cleanup_targets() {
  CLEANUP_APP_NAMES=()
  CLEANUP_PROCESS_NAMES=()
  CLEANUP_BUNDLE_IDS=()
  CLEANUP_FULL_PATHS=()

  if [[ "$USES_ALL_EDITORS" == true ]]; then
    local all_editor
    for all_editor in "Kern" "VS Code" "Zed" "Sublime Text" "TextEdit" "Typora"; do
      register_cleanup_target_for_editor "$all_editor"
    done
  else
    local selected_editor
    for selected_editor in "${SELECTED_EDITORS[@]}"; do
      register_cleanup_target_for_editor "$selected_editor"
    done
  fi

  if [[ -n "${KERN_BENCH_ZED_CLI:-}" ]]; then
    local zed_cli_path
    local zed_binary_path
    zed_cli_path="$(expand_tilde_path "$KERN_BENCH_ZED_CLI")"
    append_unique_value CLEANUP_FULL_PATHS "$zed_cli_path"

    zed_binary_path="$(cd "$(dirname "$zed_cli_path")" && pwd)/zed"
    if [[ -x "$zed_binary_path" ]]; then
      append_unique_value CLEANUP_FULL_PATHS "$zed_binary_path"
    fi
  fi
}

list_pids_for_exact_command_path() {
  local exact_path="$1"
  [[ -n "$exact_path" ]] || return 0
  python3 - "$exact_path" <<'PY'
import subprocess
import sys

target = sys.argv[1]
try:
    proc = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        text=True,
        capture_output=True,
        check=False,
    )
except Exception:
    sys.exit(0)
if proc.returncode != 0:
    sys.exit(0)
out = proc.stdout
for line in out.splitlines():
    line = line.rstrip()
    if not line:
        continue
    parts = line.lstrip().split(None, 1)
    if len(parts) != 2:
        continue
    pid, command = parts
    if command == target or command.startswith(target + " "):
        print(pid)
PY
}

snapshot_exact_path_pids() {
  local exact_path="$1"
  local out=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    out+=("$pid")
  done < <(list_pids_for_exact_command_path "$exact_path")
  printf '%s\n' "${out[@]-}"
}

record_cleanup_baseline_pids() {
  local full_path
  local snapshot
  for full_path in "${CLEANUP_FULL_PATHS[@]-}"; do
    snapshot="$(snapshot_exact_path_pids "$full_path" | awk 'NF' | sort -u | tr '\n' ' ')"
    set_cleanup_baseline_snapshot "$full_path" "$snapshot"
  done
}

capture_owned_cleanup_pids() {
  CLEANUP_OWNED_PIDS=()
  local full_path
  local pid
  local baseline
  local current
  for full_path in "${CLEANUP_FULL_PATHS[@]-}"; do
    baseline=" $(get_cleanup_baseline_snapshot "$full_path" || true) "
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      current=" $pid "
      if [[ "$baseline" != *"$current"* ]]; then
        append_unique_value CLEANUP_OWNED_PIDS "$pid"
      fi
    done < <(snapshot_exact_path_pids "$full_path")
  done
}

kill_owned_cleanup_pids() {
  local pid
  for pid in "${CLEANUP_OWNED_PIDS[@]-}"; do
    [[ -n "$pid" ]] || continue
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  done

  /bin/sleep 0.35

  for pid in "${CLEANUP_OWNED_PIDS[@]-}"; do
    [[ -n "$pid" ]] || continue
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  done
}

start_cleanup_reaper() {
  if ((${#CLEANUP_FULL_PATHS[@]} == 0)); then
    return 0
  fi

  local parent_pid="$$"
  CLEANUP_REAPER_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/kern-bench-cleanup-reaper.XXXXXX")"

  python3 - "$CLEANUP_REAPER_STATE_FILE" <<'PY'
import json
import sys

state_path = sys.argv[1]
payload = {"paths": []}
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

  python3 - "$CLEANUP_REAPER_STATE_FILE" "${CLEANUP_FULL_PATHS[@]-}" <<'PY'
import json
import sys

state_path = sys.argv[1]
paths = sys.argv[2:]
payload = {"paths": paths}
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

  local full_path
  local snapshot
  for full_path in "${CLEANUP_FULL_PATHS[@]-}"; do
    snapshot="$(get_cleanup_baseline_snapshot "$full_path" || true)"
    python3 - "$CLEANUP_REAPER_STATE_FILE" "$full_path" "$snapshot" <<'PY'
import json
import sys

state_path, path, snapshot = sys.argv[1], sys.argv[2], sys.argv[3]
with open(state_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
baselines = payload.setdefault("baselines", {})
baselines[path] = [pid for pid in snapshot.split() if pid]
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  done

  nohup python3 - "$parent_pid" "$CLEANUP_REAPER_STATE_FILE" <<'PY' >/dev/null 2>&1 &
import json
import os
import signal
import subprocess
import sys
import time

parent_pid = int(sys.argv[1])
state_path = sys.argv[2]

try:
    os.setsid()
except OSError:
    pass

def parent_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def list_pids_for_path(target: str) -> list[str]:
    try:
        proc = subprocess.run(
            ["ps", "-axo", "pid=,command="],
            text=True,
            capture_output=True,
            check=False,
        )
    except Exception:
        return []
    if proc.returncode != 0:
        return []
    out = proc.stdout
    matches: list[str] = []
    for line in out.splitlines():
        parts = line.lstrip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, command = parts
        if command == target or command.startswith(target + " "):
            matches.append(pid)
    return matches

try:
    with open(state_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except FileNotFoundError:
    sys.exit(0)

paths = payload.get("paths", [])
baselines = {path: set(pids) for path, pids in payload.get("baselines", {}).items()}

while parent_alive(parent_pid):
    time.sleep(0.25)

for _ in range(24):
    owned: set[int] = set()
    for path in paths:
        baseline = baselines.get(path, set())
        current = set(list_pids_for_path(path))
        owned.update(int(pid) for pid in current - baseline)
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    time.sleep(0.35)
    for pid in owned:
        try:
            os.kill(pid, 0)
        except OSError:
            continue
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    time.sleep(0.25)

try:
    os.remove(state_path)
except OSError:
    pass
PY

  CLEANUP_REAPER_PID="$!"
}

stop_cleanup_reaper() {
  if [[ -n "${CLEANUP_REAPER_PID:-}" ]]; then
    /bin/kill -TERM "$CLEANUP_REAPER_PID" >/dev/null 2>&1 || true
    /bin/wait "$CLEANUP_REAPER_PID" 2>/dev/null || true
    CLEANUP_REAPER_PID=""
  fi
  if [[ -n "${CLEANUP_REAPER_STATE_FILE:-}" ]]; then
    /bin/rm -f "$CLEANUP_REAPER_STATE_FILE" >/dev/null 2>&1 || true
    CLEANUP_REAPER_STATE_FILE=""
  fi
}

list_running_cleanup_targets() {
  local name
  for name in "${CLEANUP_APP_NAMES[@]-}"; do
    if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then
      printf 'app:%s\n' "$name"
    fi
  done
  for name in "${CLEANUP_PROCESS_NAMES[@]-}"; do
    if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then
      printf 'process:%s\n' "$name"
    fi
  done
  for name in "${CLEANUP_BUNDLE_IDS[@]-}"; do
    if /usr/bin/pgrep -f "$name" >/dev/null 2>&1; then
      printf 'bundle:%s\n' "$name"
    fi
  done
  for name in "${CLEANUP_FULL_PATHS[@]-}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      printf 'path:%s pid:%s\n' "$name" "$pid"
    done < <(list_pids_for_exact_command_path "$name")
  done
}

ensure_cleanup_targets_idle() {
  local conflicts=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && conflicts+=("$entry")
  done < <(list_running_cleanup_targets)

  if [[ ${#conflicts[@]} -gt 0 ]]; then
    echo "Error: benchmark cleanup targets are already running." >&2
    echo "Refusing to run because the wrapper must not kill existing user/editor sessions." >&2
    printf '  %s\n' "${conflicts[@]}" >&2
    echo "Close those apps/processes first, then rerun the benchmark." >&2
    exit 1
  fi
}

cleanup_editors() {
  stop_cleanup_reaper

  if ((${#CLEANUP_FULL_PATHS[@]} > 0)); then
    capture_owned_cleanup_pids
  fi

  kill_owned_cleanup_pids
}

expand_tilde_path() {
  local path="$1"
  if [[ "$path" == "~"* ]]; then
    printf '%s' "${HOME}${path:1}"
    return 0
  fi
  printf '%s' "$path"
}

inject_profile_override_if_unset() {
  local key="$1"
  local value="$2"
  if [[ -z "${!key:-}" ]]; then
    export "$key=$value"
    INJECTED_OVERRIDE_PAIRS+=("${key}=${value}")
  fi
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

editor_list_includes_kern() {
  local editor_name
  for editor_name in "$@"; do
    local normalized
    normalized="$(echo "$editor_name" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ "$normalized" == "kern" ]]; then
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

resolve_release_kern_app() {
  local candidates=(
    "$(pwd)/dist/Kern.app"
    "$(pwd)/dist/KernTextKit.app"
    "$(pwd)/.derived-data/native/Build/Products/Release/Kern.app"
    "$(pwd)/.derived-data/native/Build/Products/Release/KernTextKit.app"
    "${HOME}/Applications/Kern.app"
    # Legacy location kept last only as a fallback because it can become stale across
    # packaging-script revisions and benchmark the wrong branch build.
    "$(pwd)/.derived-data-release/Build/Products/Release/Kern.app"
    "$(pwd)/.derived-data-release/Build/Products/Release/KernTextKit.app"
  )

  resolve_candidate_mtime() {
    local candidate="$1"
    local probes=(
      "$candidate/Contents/MacOS/KernTextKit"
      "$candidate/Contents/MacOS/Kern"
      "$candidate/Contents/Info.plist"
      "$candidate"
    )

    local probe
    for probe in "${probes[@]}"; do
      if [[ -e "$probe" ]]; then
        /usr/bin/stat -f '%m' "$probe"
        return 0
      fi
    done
    printf '0'
  }

  local best_candidate=""
  local best_mtime=0
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      local candidate_mtime
      candidate_mtime="$(resolve_candidate_mtime "$candidate")"
      if [[ -z "$best_candidate" || "$candidate_mtime" -gt "$best_mtime" ]]; then
        best_candidate="$candidate"
        best_mtime="$candidate_mtime"
      fi
    fi
  done
  if [[ -n "$best_candidate" ]]; then
    printf '%s' "$best_candidate"
    return 0
  fi
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
    --preflight-only) PREFLIGHT_ONLY=true; shift ;;
    --kern-open-metric-source) KERN_OPEN_METRIC_SOURCE="$2"; shift 2 ;;
    --zed-bench-hook) ZED_BENCH_HOOK="$2"; shift 2 ;;
    --zed-ready-mode) ZED_READY_MODE="$2"; shift 2 ;;
    --profile) BENCH_PROFILE="$2"; shift 2 ;;
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
  --preflight-only       Validate build, roster, app/CLI resolution, and idle cleanup targets without launching editors
  --kern-open-metric-source MODE
                        Kern open metric source: auto|wow|probe
  --zed-bench-hook MODE  Zed hook mode: auto|off|required
  --zed-ready-mode MODE  Zed bench-ready mode label
  --profile NAME         Benchmark profile (default|full-fidelity-stable)
  --verbose, -v         Verbose output
  --file PATH           Benchmark fixture file

Policy:
  - benchmark suite uses locked roster v1: Kern, VS Code, Zed, Sublime Text, TextEdit
  - benchmark_open_ready is an optional aside mode (open-readiness only; defaults to Kern+Zed)
  - benchmark_full_fidelity is an optional aside mode (full-fidelity completion; defaults to Kern+Zed)
  - aside suites default to 10 measured runs, 1 warmup run, and 1500ms inter-editor cooldown
  - single-editor or non-Kern+Zed aside runs are diagnostic-only and do not qualify as OFFICIAL head-to-head claim evidence
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

if [[ "$SUITE" == "benchmark_full_fidelity" ]]; then
  if [[ -z "$ZED_BENCH_HOOK" ]]; then ZED_BENCH_HOOK="required"; fi
  if [[ -z "$ZED_READY_MODE" ]]; then ZED_READY_MODE="styled_stable"; fi
  if [[ -z "$KERN_OPEN_METRIC_SOURCE" ]]; then KERN_OPEN_METRIC_SOURCE="wow"; fi
fi

if [[ "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ]]; then
  if [[ -z "$RUNS" ]]; then RUNS="10"; fi
  if [[ -z "$WARMUP_RUNS" ]]; then WARMUP_RUNS="1"; fi
  if [[ -z "$INTER_EDITOR_DELAY_MS" ]]; then INTER_EDITOR_DELAY_MS="1500"; fi
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

case "$BENCH_PROFILE" in
  ""|default)
    ;;
  full-fidelity-stable|full_fidelity_stable|ff-stable|ff_stable)
    BENCH_PROFILE="full-fidelity-stable"
    ;;
  *)
    echo "Error: unsupported --profile '$BENCH_PROFILE'. Supported: default, full-fidelity-stable" >&2
    exit 1
    ;;
esac

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
  NEEDS_KERN=true
elif editor_list_includes_zed "${SELECTED_EDITORS[@]}"; then
  NEEDS_ZED=true
fi

if [[ "$USES_ALL_EDITORS" != true ]] && editor_list_includes_kern "${SELECTED_EDITORS[@]}"; then
  NEEDS_KERN=true
fi

if [[ "$NEEDS_KERN" == true ]]; then
  if [[ -n "${KERN_BENCH_KERN_APP:-}" ]]; then
    resolved_kern_override="$(expand_tilde_path "${KERN_BENCH_KERN_APP}")"
    if [[ ! -d "$resolved_kern_override" ]]; then
      echo "Error: KERN_BENCH_KERN_APP is set but app bundle not found: $resolved_kern_override" >&2
      exit 1
    fi
    export KERN_BENCH_KERN_APP="$resolved_kern_override"
    KERN_APP_SOURCE="env"
  elif resolved_release_kern_app="$(resolve_release_kern_app)"; then
    export KERN_BENCH_KERN_APP="$resolved_release_kern_app"
    KERN_APP_SOURCE="auto-release"
  fi
fi

if [[ "$BENCH_PROFILE" == "full-fidelity-stable" ]]; then
  if [[ "$SUITE" != "benchmark_full_fidelity" ]]; then
    echo "Error: --profile full-fidelity-stable requires --suite benchmark_full_fidelity" >&2
    exit 1
  fi
  # Deterministic/stable profile knobs for large-document staged promotion behavior.
  # Respect explicit caller env overrides.
  inject_profile_override_if_unset "KERN_STAGED_PROMOTION_VIEWPORT_MICRO_STEP_CHARS" "2000000"
  inject_profile_override_if_unset "KERN_STAGED_PROMOTION_CONTEXT_CHARS" "1000"
  inject_profile_override_if_unset "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS" "2"
  inject_profile_override_if_unset "KERN_STAGED_PROMOTION_TURBO_FOLLOWUP_DELAY_MS" "2"
  inject_profile_override_if_unset "KERN_STAGED_PROMOTION_TURBO_IDLE_MS" "120"
fi

export KERN_BENCH_PROFILE_LABEL="${BENCH_PROFILE:-default}"
if [[ ${#INJECTED_OVERRIDE_PAIRS[@]} -gt 0 ]]; then
  export KERN_BENCH_INJECTED_OVERRIDES="$(IFS=';'; printf '%s' "${INJECTED_OVERRIDE_PAIRS[*]}")"
else
  unset KERN_BENCH_INJECTED_OVERRIDES || true
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

build_cleanup_targets
ensure_cleanup_targets_idle

if [[ "$PREFLIGHT_ONLY" == true ]]; then
  echo "=== Cross-Editor Benchmark Preflight ==="
  echo "Suite: $SUITE"
  echo "File:  $FILE"
  echo "Mode:  $MODE"
  if [[ ( "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ) && -z "$EDITORS_FILTER" && ${#EDITOR_ARGS[@]} -eq 0 && "$EXPLICIT_ALL" != true ]]; then
    echo "Editors default: Kern, Zed (override with --editors or --all)"
  fi
  if [[ "$NEEDS_ZED" == true ]]; then
    echo "Zed CLI: fork ($ZED_CLI_SOURCE)"
  fi
  if [[ -n "${KERN_BENCH_KERN_APP:-}" ]]; then
    if [[ -n "$KERN_APP_SOURCE" ]]; then
      echo "Kern app: $KERN_BENCH_KERN_APP ($KERN_APP_SOURCE)"
    else
      echo "Kern app: $KERN_BENCH_KERN_APP"
    fi
  elif [[ "$NEEDS_KERN" == true ]]; then
    echo "Kern app: unresolved (kern-bench registry fallback will decide at runtime)"
  fi
  echo "Cleanup targets: idle"
  echo "Policy: suite-specific roster/classification policy enforced"
  echo "Claims: README/social headline claims require Official runs"
  if [[ "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ]]; then
    echo "Claim-safe defaults: 10 measured runs, 1 warmup, 1500ms inter-editor cooldown"
  fi
  if [[ -n "$BENCH_PROFILE" ]]; then
    echo "Profile: $BENCH_PROFILE"
  fi
  printf 'Command:'
  printf ' %q' "${CMD[@]}"
  echo ""
  exit 0
fi

record_cleanup_baseline_pids
start_cleanup_reaper

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
if [[ -n "${KERN_BENCH_KERN_APP:-}" ]]; then
  if [[ -n "$KERN_APP_SOURCE" ]]; then
    echo "Kern app: $KERN_BENCH_KERN_APP ($KERN_APP_SOURCE)"
  else
    echo "Kern app: $KERN_BENCH_KERN_APP"
  fi
fi
echo "Policy: suite-specific roster/classification policy enforced"
echo "Claims: README/social headline claims require Official runs"
if [[ "$SUITE" == "benchmark_open_ready" || "$SUITE" == "benchmark_full_fidelity" ]]; then
  echo "Claim-safe defaults: 10 measured runs, 1 warmup, 1500ms inter-editor cooldown"
fi
if [[ -n "$BENCH_PROFILE" ]]; then
  echo "Profile: $BENCH_PROFILE"
fi
echo ""

set +e
"${CMD[@]}"
status=$?
set -e

if ((${#CLEANUP_FULL_PATHS[@]} > 0)); then
  capture_owned_cleanup_pids
  cleanup_editors
fi

exit "$status"
