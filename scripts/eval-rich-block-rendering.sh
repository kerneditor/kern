#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${KERN_RICH_BLOCK_EVAL_OUTPUT_DIR:-$ROOT_DIR/test-results/rich-block-eval/$TIMESTAMP}"
DERIVED_DATA_PATH="${KERN_RICH_BLOCK_EVAL_DERIVED_DATA:-$ROOT_DIR/.derived-data/rich-block-eval}"
SKIP_XCODEGEN="${KERN_RICH_BLOCK_EVAL_SKIP_XCODEGEN:-0}"
DEFAULTS_DOMAIN="com.gradigit.kern.tests"
DEFAULT_KEYS=()

mkdir -p "$OUT_DIR"
COMMAND_LINE="./scripts/eval-rich-block-rendering.sh"
GIT_BRANCH="$(cd "$ROOT_DIR" && git branch --show-current 2>/dev/null || true)"
GIT_REV="$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || true)"
GIT_DIRTY="$(cd "$ROOT_DIR" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
LOAD_SNAPSHOT="$(uptime | sed 's/^ *//')"

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

trap cleanup_suite_values EXIT INT TERM

# XCTest runners launched by xcodebuild do not always inherit shell-set KERN_* vars,
# especially for app-hosted tests. Mirror the eval controls into the shared test
# defaults suite so TestRuntimeConfig can read them reliably.
export KERN_ENABLE_RICH_BLOCK_EVALS=1
export KERN_RICH_BLOCK_EVAL_OUTPUT_DIR="$OUT_DIR"
write_suite_value "KERN_ENABLE_RICH_BLOCK_EVALS" "1"
write_suite_value "KERN_RICH_BLOCK_EVAL_OUTPUT_DIR" "$OUT_DIR"
for key in \
  KERN_OFFICIAL_MERMAID_RENDERER_COMMAND \
  KERN_OFFICIAL_MERMAID_CACHE_DIR \
  KERN_OFFICIAL_MERMAID_USE_NPX \
  KERN_OFFICIAL_MERMAID_CLI_VERSION \
  KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE \
  KERN_OFFICIAL_MERMAID_VISUAL_TIMEOUT_SECONDS
do
  if [ -n "${!key:-}" ]; then
    # xcodebuild-hosted macOS tests do not consistently propagate every
    # inherited shell variable into the app/test process. Keep both channels:
    # explicit export for direct inheritance, and the shared test defaults suite
    # as a fallback read by TestRuntimeConfig.
    export "$key"
    write_suite_value "$key" "${!key}"
  fi
done

if [ "$SKIP_XCODEGEN" != "1" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && xcodegen >/dev/null)
  else
    echo "xcodegen not found; using existing KernTextKit.xcodeproj" >&2
  fi
fi

set +e
(
  cd "$ROOT_DIR"
  xcodebuild \
    -project KernTextKit.xcodeproj \
    -scheme KernTextKit \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -only-testing:KernTextKitTests/NativeRichBlockEvalCorpusTests/testRichBlockEvalCorpus \
    test
) 2>&1 | tee "$OUT_DIR/xcodebuild.log"
status=${PIPESTATUS[0]}
set -e

POST_PROCESS_SNAPSHOT="$OUT_DIR/process-snapshot.txt"
ps -axo pid,ppid,stat,pcpu,pmem,comm,args   | grep -E 'Kern\.app|/Contents/MacOS/Kern|KernTextKitTests|xcodebuild.*KernTextKit|mmdc|mermaid-cli|puppeteer|Chromium|chrome.*mermaid'   | grep -v grep > "$POST_PROCESS_SNAPSHOT" || true

cat > "$OUT_DIR/summary.txt" <<EOF
status=$status
output_dir=$OUT_DIR
derived_data=$DERIVED_DATA_PATH
xcodebuild_log=$OUT_DIR/xcodebuild.log
report_md=$OUT_DIR/rich-block-eval.md
report_json=$OUT_DIR/rich-block-eval.json
visual_index=$OUT_DIR/visual-index.md
process_snapshot=$POST_PROCESS_SNAPSHOT
git_branch=$GIT_BRANCH
git_rev=$GIT_REV
git_dirty_file_count=$GIT_DIRTY
load_snapshot=$LOAD_SNAPSHOT
official_mermaid_use_npx=${KERN_OFFICIAL_MERMAID_USE_NPX:-0}
official_mermaid_renderer_command=${KERN_OFFICIAL_MERMAID_RENDERER_COMMAND:-}
EOF

python3 - "$OUT_DIR" "$status" "$DERIVED_DATA_PATH" "$GIT_BRANCH" "$GIT_REV" "$GIT_DIRTY" "$LOAD_SNAPSHOT" "$COMMAND_LINE" <<'PYJSON'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
status = int(sys.argv[2])
payload = {
    "status": status,
    "outputDir": str(out),
    "derivedData": sys.argv[3],
    "git": {
        "branch": sys.argv[4],
        "rev": sys.argv[5],
        "dirtyFileCount": int(sys.argv[6] or 0),
    },
    "loadSnapshot": sys.argv[7],
    "command": sys.argv[8],
    "artifacts": {
        "xcodebuildLog": str(out / "xcodebuild.log"),
        "reportMarkdown": str(out / "rich-block-eval.md"),
        "reportJSON": str(out / "rich-block-eval.json"),
        "visualIndex": str(out / "visual-index.md"),
        "processSnapshot": str(out / "process-snapshot.txt"),
        "pngs": sorted(p.name for p in out.glob("*.png")),
    },
}
(out / "run-manifest.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PYJSON

if [ "$status" -ne 0 ]; then
  echo "Rich-block eval failed. See $OUT_DIR/xcodebuild.log" >&2
  exit "$status"
fi

if [ ! -f "$OUT_DIR/rich-block-eval.json" ] || [ ! -f "$OUT_DIR/rich-block-eval.md" ]; then
  echo "Rich-block eval did not produce expected report artifacts in $OUT_DIR" >&2
  exit 66
fi

if [ ! -f "$OUT_DIR/visual-index.md" ] || ! ls "$OUT_DIR"/*.png >/dev/null 2>&1; then
  echo "Rich-block eval did not produce expected visual artifacts in $OUT_DIR" >&2
  exit 67
fi

python3 -m json.tool "$OUT_DIR/rich-block-eval.json" >/dev/null
python3 -m json.tool "$OUT_DIR/run-manifest.json" >/dev/null

if [ -s "$POST_PROCESS_SNAPSHOT" ]; then
  echo "Warning: rich-block eval process snapshot is not empty; inspect $POST_PROCESS_SNAPSHOT" >&2
fi

echo "Rich-block eval complete: $OUT_DIR/rich-block-eval.md"
echo "Rich-block visuals complete: $OUT_DIR/visual-index.md"
