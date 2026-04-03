#!/bin/bash
# run-typing-behavior-gate.sh
# Runs the behavior-focused typing gate and archives evidence artifacts.
#
# Usage:
#   ./scripts/run-typing-behavior-gate.sh [--lane pr|nightly]

set -euo pipefail
cd "$(dirname "$0")/.."

LANE="pr"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)
      LANE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$LANE" != "pr" && "$LANE" != "nightly" ]]; then
  echo "Invalid lane '$LANE' (expected pr|nightly)" >&2
  exit 2
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/test-results/typing-behavior/$TS-$LANE"
mkdir -p "$OUT_DIR"

if [[ "$LANE" == "pr" ]]; then
  SCHEME="KernTextKitExhaustive"
  export KERN_TYPING_COVERAGE_LANE="${KERN_TYPING_COVERAGE_LANE:-pr}"
  export KERN_TYPING_STATEFUL_ENFORCE="${KERN_TYPING_STATEFUL_ENFORCE:-1}"
  export KERN_TYPING_STATEFUL_SEEDS="${KERN_TYPING_STATEFUL_SEEDS:-24}"
  export KERN_TYPING_STATEFUL_STEPS="${KERN_TYPING_STATEFUL_STEPS:-50}"
else
  SCHEME="KernTextKitUltraExhaustive"
  export KERN_TYPING_COVERAGE_LANE="${KERN_TYPING_COVERAGE_LANE:-nightly}"
  export KERN_TYPING_STATEFUL_ENFORCE="${KERN_TYPING_STATEFUL_ENFORCE:-1}"
  export KERN_TYPING_STATEFUL_SEEDS="${KERN_TYPING_STATEFUL_SEEDS:-120}"
  export KERN_TYPING_STATEFUL_STEPS="${KERN_TYPING_STATEFUL_STEPS:-120}"
fi

cat > "$OUT_DIR/config.txt" <<EOF
lane=$LANE
scheme=$SCHEME
timestamp=$TS
KERN_TYPING_COVERAGE_LANE=$KERN_TYPING_COVERAGE_LANE
KERN_TYPING_STATEFUL_ENFORCE=$KERN_TYPING_STATEFUL_ENFORCE
KERN_TYPING_STATEFUL_SEEDS=$KERN_TYPING_STATEFUL_SEEDS
KERN_TYPING_STATEFUL_STEPS=$KERN_TYPING_STATEFUL_STEPS
EOF

echo "== Typing behavior gate ($LANE) =="
echo "Output: $OUT_DIR"

xcodegen generate >/dev/null

set +e
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -only-testing:KernTextKitTests/NativeEditorTypingBehaviorMatrixCoverageTests \
  -only-testing:KernTextKitTests/NativeEditorTypingStatefulSequenceTests \
  -only-testing:KernTextKitTests/NativeEditorTypingReliabilityTests \
  -only-testing:KernTextKitTests/NativeEditorBulletTaskInputRuleTests \
  -only-testing:KernTextKitTests/NativeEditorNotionListBehaviorRegressionTests \
  -only-testing:KernTextKitTests/NativeEditorNotionTypingBehaviorProgramTests \
  -only-testing:KernTextKitTests/NativeEditorHybridSyntaxModeTests \
  -only-testing:KernTextKitTests/NativeEditorBackspaceUnlistTests \
  test | tee "$OUT_DIR/xcodebuild.log"
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "result=FAIL" > "$OUT_DIR/summary.txt"
  echo "Typing behavior gate FAILED (see $OUT_DIR/xcodebuild.log)" >&2
  exit $STATUS
fi

{
  echo "result=PASS"
  coverage_block="$(python3 - "$OUT_DIR/xcodebuild.log" <<'PY'
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
start = None
end = None
for index, line in enumerate(lines):
    if line.strip() == "typing_behavior_matrix_coverage":
        start = index
for index in range(start or 0, len(lines)):
    if start is not None and lines[index].startswith("missing_required_edges="):
        end = index
if start is None:
    sys.exit(0)
block = lines[start:(end + 1 if end is not None else len(lines))]
print("\n".join(block))
PY
)"
  if [[ -n "$coverage_block" ]]; then
    echo "$coverage_block"
  fi
} > "$OUT_DIR/summary.txt"
echo "Typing behavior gate PASSED"
echo "Artifacts: $OUT_DIR"
