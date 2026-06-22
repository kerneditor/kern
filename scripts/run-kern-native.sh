#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/.derived-data/native}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID_DEFAULT="${KERN_BUNDLE_ID:-com.gradigit.kern}"

MODE="run"
REPLACE_RUNNING=false
FILE_PATH=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-kern-native.sh [--debug|--logs|--telemetry|--verify] [--replace-running] [file.md]

Modes:
  --debug         Build, then launch the app binary under lldb
  --logs          Build, launch the app bundle, then stream process logs
  --telemetry     Build, launch the app bundle, then stream unified logs for the app subsystem
  --verify        Build, launch the app bundle, then verify the app process is running
  --replace-running
                  Opt-in: terminate existing Kern/KernTextKit processes before launch

Notes:
  - Default behavior preserves the current non-destructive launcher contract and uses `open -F -n`.
  - CONFIGURATION and DERIVED_DATA_PATH can be overridden via environment variables.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --debug|--logs|--telemetry|--verify)
      MODE="${1#--}"
      shift
      ;;
    --replace-running)
      REPLACE_RUNNING=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$FILE_PATH" ]; then
        echo "ERROR: only one markdown file path is supported." >&2
        usage >&2
        exit 2
      fi
      FILE_PATH="$1"
      shift
      ;;
  esac
done

ensure_xcode_project() {
  local pbxproj="KernTextKit.xcodeproj/project.pbxproj"
  local need_xcodegen=true

  if [ -f "$pbxproj" ] && [ "$pbxproj" -nt "project.yml" ]; then
    need_xcodegen=false

    if [ -f "KernApp/Info.plist" ] && [ "KernApp/Info.plist" -nt "$pbxproj" ]; then
      need_xcodegen=true
    fi

    if [ -f "KernApp/Kern.entitlements" ] && [ "KernApp/Kern.entitlements" -nt "$pbxproj" ]; then
      need_xcodegen=true
    fi

    if find KernApp/Sources KernApp/Resources -type f \( -name "*.swift" -o -name "*.xcassets" -o -name "*.plist" \) -newer "$pbxproj" 2>/dev/null | grep -q .; then
      need_xcodegen=true
    fi
  fi

  if [ "$need_xcodegen" = true ]; then
    echo "▸ Generating Xcode project (xcodegen)..."
    xcodegen 2>&1 | tail -1
  else
    echo "▸ Skipping xcodegen (project up-to-date)."
  fi
}

resolve_absolute_file_path() {
  local candidate="$1"
  if [ ! -f "$candidate" ]; then
    echo "ERROR: file not found: $candidate" >&2
    exit 1
  fi
  (
    cd "$(dirname "$candidate")"
    printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")"
  )
}

build_app() {
  local arch destination
  arch="$(uname -m)"
  destination="platform=macOS,arch=${arch}"

  echo "▸ Building Kern (${CONFIGURATION}) to: ${DERIVED_DATA_PATH}"
  xcodebuild \
    -project KernTextKit.xcodeproj \
    -scheme KernTextKit \
    -configuration "$CONFIGURATION" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

resolve_app_path() {
  local app_path
  app_path="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Kern.app"
  if [ ! -d "$app_path" ]; then
    app_path="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/KernTextKit.app"
  fi
  if [ ! -d "$app_path" ]; then
    echo "ERROR: built app not found under: $DERIVED_DATA_PATH/Build/Products/$CONFIGURATION" >&2
    exit 1
  fi
  printf '%s\n' "$app_path"
}

resolve_app_binary() {
  local app_path="$1"
  local app_bin
  app_bin="$app_path/Contents/MacOS/Kern"
  if [ ! -f "$app_bin" ]; then
    app_bin="$app_path/Contents/MacOS/KernTextKit"
  fi
  if [ ! -f "$app_bin" ]; then
    echo "ERROR: app binary not found inside bundle: $app_path" >&2
    exit 1
  fi
  printf '%s\n' "$app_bin"
}

read_plist_value() {
  local plist_path="$1"
  local key="$2"
  if [ -f "$plist_path" ]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
  fi
}

replace_running_instances() {
  echo "▸ Replacing running Kern instances..."
  pkill -x "Kern" >/dev/null 2>&1 || true
  pkill -x "KernTextKit" >/dev/null 2>&1 || true
  sleep 1
}

launch_bundle() {
  local app_path="$1"
  local absolute_file_path="${2:-}"

  echo "▸ Launching: $app_path"
  echo "  note: default behavior uses 'open -F -n' and does not terminate existing sessions."

  if [ -n "$absolute_file_path" ]; then
    /usr/bin/open -F -n -a "$app_path" "$absolute_file_path"
  else
    /usr/bin/open -F -n "$app_path"
  fi
}

stream_logs() {
  local process_name="$1"
  /usr/bin/log stream --info --style compact --predicate "process == \"$process_name\""
}

stream_telemetry() {
  local bundle_id="$1"
  /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
}

verify_process() {
  local process_name="$1"
  sleep 1
  if pgrep -x "$process_name" >/dev/null 2>&1; then
    echo "▸ Verified running process: $process_name"
  else
    echo "ERROR: expected process not found after launch: $process_name" >&2
    exit 1
  fi
}

ABSOLUTE_FILE_PATH=""
if [ -n "$FILE_PATH" ]; then
  ABSOLUTE_FILE_PATH="$(resolve_absolute_file_path "$FILE_PATH")"
fi

ensure_xcode_project
build_app

APP_PATH="$(resolve_app_path)"
APP_BIN="$(resolve_app_binary "$APP_PATH")"
PROCESS_NAME="$(basename "$APP_BIN")"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
BUNDLE_ID="$(read_plist_value "$INFO_PLIST" "CFBundleIdentifier")"
if [ -z "$BUNDLE_ID" ]; then
  BUNDLE_ID="$BUNDLE_ID_DEFAULT"
fi

if [ "$REPLACE_RUNNING" = true ]; then
  replace_running_instances
fi

case "$MODE" in
  run)
    launch_bundle "$APP_PATH" "$ABSOLUTE_FILE_PATH"
    ;;
  debug)
    echo "▸ Launching under lldb: $APP_BIN"
    if [ -n "$ABSOLUTE_FILE_PATH" ]; then
      lldb -- "$APP_BIN" "$ABSOLUTE_FILE_PATH"
    else
      lldb -- "$APP_BIN"
    fi
    ;;
  logs)
    launch_bundle "$APP_PATH" "$ABSOLUTE_FILE_PATH"
    stream_logs "$PROCESS_NAME"
    ;;
  telemetry)
    launch_bundle "$APP_PATH" "$ABSOLUTE_FILE_PATH"
    stream_telemetry "$BUNDLE_ID"
    ;;
  verify)
    launch_bundle "$APP_PATH" "$ABSOLUTE_FILE_PATH"
    verify_process "$PROCESS_NAME"
    ;;
  *)
    echo "ERROR: unsupported mode: $MODE" >&2
    exit 2
    ;;
esac
