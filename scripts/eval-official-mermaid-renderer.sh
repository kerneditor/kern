#!/usr/bin/env bash
set -euo pipefail

# Evaluate an optional official Mermaid renderer against Kern's tracked Mermaid
# corpus. This is intentionally outside the shipped app target: Kern stays native
# by default, and official Mermaid is treated as an external/cached renderer path.
#
# Renderer discovery:
#   1. KERN_OFFICIAL_MERMAID_RENDERER_COMMAND="mmdc"
#   2. command -v mmdc
#   3. KERN_OFFICIAL_MERMAID_USE_NPX=1 to run npx -y @mermaid-js/mermaid-cli@<version>
#
# The script exits 0 with status=skipped when no renderer is configured, unless
# KERN_OFFICIAL_MERMAID_REQUIRE_RENDERER=1 is set.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CORPUS_JSON="${KERN_OFFICIAL_MERMAID_CORPUS_JSON:-$ROOT_DIR/test-fixtures/rich-block-eval/mermaid-renderer-corpus.json}"
OUT_DIR="${KERN_OFFICIAL_MERMAID_OUTPUT_DIR:-$ROOT_DIR/benchmark-archive/official-mermaid-renderer/$TIMESTAMP}"
MERMAID_CLI_VERSION="${KERN_OFFICIAL_MERMAID_CLI_VERSION:-11.15.0}"
USE_NPX="${KERN_OFFICIAL_MERMAID_USE_NPX:-0}"
REQUIRE_RENDERER="${KERN_OFFICIAL_MERMAID_REQUIRE_RENDERER:-0}"
RENDER_FORMAT="${KERN_OFFICIAL_MERMAID_FORMAT:-svg}"
RENDER_THEME="${KERN_OFFICIAL_MERMAID_THEME:-default}"
RENDER_WIDTH="${KERN_OFFICIAL_MERMAID_WIDTH:-}"
PUPPETEER_CONFIG_FILE="${KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE:-}"

mkdir -p "$OUT_DIR/cases"

renderer_kind=""
renderer_command=""
if [ -n "${KERN_OFFICIAL_MERMAID_RENDERER_COMMAND:-}" ]; then
  renderer_kind="custom"
  renderer_command="$KERN_OFFICIAL_MERMAID_RENDERER_COMMAND"
elif command -v mmdc >/dev/null 2>&1; then
  renderer_kind="mmdc"
  renderer_command="$(command -v mmdc)"
elif [ "$USE_NPX" = "1" ]; then
  renderer_kind="npx"
  renderer_command="npx -y @mermaid-js/mermaid-cli@$MERMAID_CLI_VERSION"
fi

if [ -z "$renderer_command" ]; then
  cat > "$OUT_DIR/official-mermaid-renderer.json" <<JSON
{
  "generatedAt": "$TIMESTAMP",
  "status": "skipped",
  "reason": "No official Mermaid renderer configured. Install mmdc, set KERN_OFFICIAL_MERMAID_RENDERER_COMMAND, or set KERN_OFFICIAL_MERMAID_USE_NPX=1.",
  "corpus": "$CORPUS_JSON",
  "results": []
}
JSON
  cat > "$OUT_DIR/official-mermaid-renderer.md" <<MD
# Official Mermaid Renderer Eval

- Generated: $TIMESTAMP
- Status: skipped
- Reason: no renderer configured
- Corpus: $CORPUS_JSON

Configure mmdc or set KERN_OFFICIAL_MERMAID_USE_NPX=1 to run the official renderer comparison.
MD
  echo "Official Mermaid renderer eval skipped: $OUT_DIR/official-mermaid-renderer.md"
  if [ "$REQUIRE_RENDERER" = "1" ]; then
    exit 69
  fi
  exit 0
fi

python3 - "$CORPUS_JSON" "$OUT_DIR" "$renderer_kind" "$renderer_command" "$RENDER_FORMAT" "$RENDER_THEME" "$RENDER_WIDTH" "$PUPPETEER_CONFIG_FILE" <<'PY'
import json, os, pathlib, shlex, subprocess, sys, time

corpus_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
renderer_kind = sys.argv[3]
renderer_command = sys.argv[4]
render_format = sys.argv[5].lstrip('.').lower()
render_theme = sys.argv[6].strip() or "default"
render_width = sys.argv[7].strip()
puppeteer_config_file = sys.argv[8].strip()
corpus = json.loads(corpus_path.read_text())
case_dir = out_dir / "cases"
case_dir.mkdir(parents=True, exist_ok=True)
results = []

def command_parts(command):
    return shlex.split(command)

for case in corpus.get("cases", []):
    case_id = case["id"]
    source_path = case_dir / f"{case_id}.mmd"
    output_path = case_dir / f"{case_id}.{render_format}"
    stderr_path = case_dir / f"{case_id}.stderr.txt"
    source_path.write_text(case["source"] + "\n")
    cmd = command_parts(renderer_command) + ["-i", str(source_path), "-o", str(output_path), "-b", "transparent", "-t", render_theme]
    if render_width:
        cmd += ["-w", render_width]
    if puppeteer_config_file:
        cmd += ["-p", puppeteer_config_file]
    start = time.perf_counter()
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    stderr_path.write_text((proc.stderr or "") + ("\nSTDOUT:\n" + proc.stdout if proc.stdout else ""))
    output_exists = output_path.exists() and output_path.stat().st_size > 0
    expected_invalid = (
        case.get("expectedNativeCoverage") == "must-not-crash"
        or "invalid" in case.get("features", [])
    )
    if proc.returncode == 0 and output_exists:
        status = "passed"
    elif expected_invalid:
        status = "expected-failure"
    else:
        status = "failed"
    results.append({
        "id": case_id,
        "kind": case.get("kind"),
        "features": case.get("features", []),
        "expectedNativeCoverage": case.get("expectedNativeCoverage"),
        "status": status,
        "expectedInvalid": expected_invalid,
        "exitCode": proc.returncode,
        "elapsedMs": round(elapsed_ms, 3),
        "outputBytes": output_path.stat().st_size if output_path.exists() else 0,
        "source": str(source_path),
        "output": str(output_path),
        "stderr": str(stderr_path),
    })

passed = sum(1 for r in results if r["status"] == "passed")
expected_failures = sum(1 for r in results if r["status"] == "expected-failure")
failed = sum(1 for r in results if r["status"] == "failed")
payload = {
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": "passed" if failed == 0 else "failed",
    "rendererKind": renderer_kind,
    "rendererCommand": renderer_command,
    "format": render_format,
    "theme": render_theme,
    "width": render_width or None,
    "puppeteerConfigFile": puppeteer_config_file or None,
    "corpus": str(corpus_path),
    "total": len(results),
    "passed": passed,
    "expectedFailures": expected_failures,
    "failed": failed,
    "results": results,
}
(out_dir / "official-mermaid-renderer.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
lines = [
    "# Official Mermaid Renderer Eval",
    "",
    f"- Generated: {payload['generatedAt']}",
    f"- Status: {payload['status']}",
    f"- Renderer: `{renderer_kind}`",
    f"- Format: `{render_format}`",
    f"- Theme: `{render_theme}`",
    f"- Width: `{render_width or 'default'}`",
    f"- Puppeteer config: `{puppeteer_config_file or 'none'}`",
    f"- Cases: {passed}/{len(results)} rendered, {expected_failures} expected failures, {failed} unexpected failures",
    "",
    "| Case | Expected | Status | ms | bytes | stderr |",
    "|---|---|---:|---:|---:|---|",
]
for r in results:
    lines.append(f"| `{r['id']}` | {r['expectedNativeCoverage']} | {r['status']} | {r['elapsedMs']:.3f} | {r['outputBytes']} | `{pathlib.Path(r['stderr']).name}` |")
lines.append("")
(out_dir / "official-mermaid-renderer.md").write_text("\n".join(lines))
if failed != 0:
    sys.exit(1)
PY

python3 -m json.tool "$OUT_DIR/official-mermaid-renderer.json" >/dev/null
echo "Official Mermaid renderer eval complete: $OUT_DIR/official-mermaid-renderer.md"
