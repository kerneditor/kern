#!/bin/bash
# test-markdown-spec-conformance.sh — Strict CommonMark/GFM conformance checks (Kern extensions disabled).
#
# Usage:
#   ./scripts/test-markdown-spec-conformance.sh [--mode all|commonmark|gfm] [--limit N] [--section-regex REGEX] [--skip-fixture-update] [--skip-xcodegen]

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="all"
CASE_LIMIT="${KERN_SPEC_CASE_LIMIT:-}"
SECTION_REGEX="${KERN_SPEC_SECTION_REGEX:-}"
SKIP_FIXTURE_UPDATE=false
SKIP_XCODEGEN=false
VENV_PATH="${KERN_SPEC_VENV_PATH:-$(pwd)/.venv-spec}"
SPEC_REQUIREMENTS_FILE="${KERN_SPEC_REQUIREMENTS_FILE:-$(pwd)/spec-requirements.txt}"
SCHEME="${KERN_SPEC_SCHEME:-KernTextKitExhaustive}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --mode=*)
      MODE="${1#*=}"
      shift
      ;;
    --limit)
      CASE_LIMIT="${2:-}"
      shift 2
      ;;
    --limit=*)
      CASE_LIMIT="${1#*=}"
      shift
      ;;
    --section-regex)
      SECTION_REGEX="${2:-}"
      shift 2
      ;;
    --section-regex=*)
      SECTION_REGEX="${1#*=}"
      shift
      ;;
    --skip-fixture-update)
      SKIP_FIXTURE_UPDATE=true
      shift
      ;;
    --skip-xcodegen)
      SKIP_XCODEGEN=true
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "all" && "$MODE" != "commonmark" && "$MODE" != "gfm" ]]; then
  echo "Invalid --mode: $MODE (expected all|commonmark|gfm)" >&2
  exit 2
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/test-results/native-editor/$TS/spec-conformance"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/.derived-data/tests}"
mkdir -p "$OUT_DIR"

echo "=== Kern Strict Markdown Spec Conformance ==="
echo "Mode: $MODE"
echo "Output: $OUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo "Scheme: $SCHEME"
echo ""

if [[ "$SKIP_XCODEGEN" = false ]]; then
  echo "▸ Generating Xcode project (xcodegen)..."
  xcodegen 2>&1 | tail -1
fi

if [[ "$SKIP_FIXTURE_UPDATE" = false ]]; then
  echo "▸ Updating official spec fixtures..."
  python3 scripts/update_markdown_spec_fixtures.py | tee "$OUT_DIR/fixture-update.log"
fi

echo "▸ Preparing python oracle environment..."
if [[ ! -f "$SPEC_REQUIREMENTS_FILE" ]]; then
  echo "Missing markdown spec oracle requirements file: $SPEC_REQUIREMENTS_FILE" >&2
  exit 2
fi
if [[ ! -f "$VENV_PATH/bin/python3" ]]; then
  python3 -m venv "$VENV_PATH"
fi
if ! "$VENV_PATH/bin/python3" - "$SPEC_REQUIREMENTS_FILE" <<'PY' >/dev/null 2>&1
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
  "$VENV_PATH/bin/python3" -m pip install --upgrade pip >/dev/null
  "$VENV_PATH/bin/python3" -m pip install --quiet -r "$SPEC_REQUIREMENTS_FILE"
fi

ONLY_TESTING_ARGS=()
case "$MODE" in
  all)
    ONLY_TESTING_ARGS+=("-only-testing:KernTextKitTests/NativeMarkdownSpecConformanceTests")
    ;;
  commonmark)
    ONLY_TESTING_ARGS+=("-only-testing:KernTextKitTests/NativeMarkdownSpecConformanceTests/testKernExtensionsRemainExplicitlySeparateFromStrictProfile")
    ONLY_TESTING_ARGS+=("-only-testing:KernTextKitTests/NativeMarkdownSpecConformanceTests/testCommonMarkStrictProfileConformance_NoKernExtensions")
    ;;
  gfm)
    ONLY_TESTING_ARGS+=("-only-testing:KernTextKitTests/NativeMarkdownSpecConformanceTests/testKernExtensionsRemainExplicitlySeparateFromStrictProfile")
    ONLY_TESTING_ARGS+=("-only-testing:KernTextKitTests/NativeMarkdownSpecConformanceTests/testGfmStrictProfileConformance_NoKernExtensions")
    ;;
esac

DEFAULTS_DOMAIN="com.gradigit.kern.tests"
DEFAULT_KEYS=()

write_suite_value() {
  local key="$1"
  local value="$2"
  /usr/bin/defaults write "$DEFAULTS_DOMAIN" "$key" -string "$value"
  DEFAULT_KEYS+=("$key")
}

cleanup_suite_values() {
  for key in "${DEFAULT_KEYS[@]}"; do
    /usr/bin/defaults delete "$DEFAULTS_DOMAIN" "$key" >/dev/null 2>&1 || true
  done
}

trap cleanup_suite_values EXIT INT TERM

write_suite_value "KERN_ENABLE_SPEC_CONFORMANCE_TESTS" "1"
write_suite_value "KERN_SPEC_ORACLE_PYTHON" "$VENV_PATH/bin/python3"
# Mirror spec oracle config into environment for reliability in XCTest runtime.
export KERN_ENABLE_SPEC_CONFORMANCE_TESTS="1"
export KERN_SPEC_ORACLE_PYTHON="$VENV_PATH/bin/python3"
# Clear stale optional knobs from previous interrupted runs.
/usr/bin/defaults delete "$DEFAULTS_DOMAIN" "KERN_SPEC_CASE_LIMIT" >/dev/null 2>&1 || true
/usr/bin/defaults delete "$DEFAULTS_DOMAIN" "KERN_SPEC_SECTION_REGEX" >/dev/null 2>&1 || true
if [[ -n "$CASE_LIMIT" ]]; then
  write_suite_value "KERN_SPEC_CASE_LIMIT" "$CASE_LIMIT"
fi
if [[ -n "$SECTION_REGEX" ]]; then
  write_suite_value "KERN_SPEC_SECTION_REGEX" "$SECTION_REGEX"
fi

echo "▸ Running strict spec conformance tests..."
set +e
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$OUT_DIR/KernMarkdownSpecConformance.xcresult" \
  "${ONLY_TESTING_ARGS[@]}" \
  test \
  2>&1 | tee "$OUT_DIR/spec-conformance.log"
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "Spec conformance tests failed (exit $STATUS). See: $OUT_DIR/spec-conformance.log" >&2
  exit $STATUS
fi

echo "✓ Strict markdown spec conformance tests passed."
