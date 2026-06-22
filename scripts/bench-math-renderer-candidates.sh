#!/usr/bin/env bash
set -euo pipefail

# Bench native math-renderer candidates without adding either dependency to the
# shipped Kern app target. The script creates throwaway SwiftPM packages under
# ignored tmp/ and writes JSON/Markdown reports under ignored benchmark-archive/.
#
# Usage:
#   KERN_MATH_BENCH_RUNS=7 ./scripts/bench-math-renderer-candidates.sh
#   KERN_MATH_BENCH_CANDIDATES="iosMath SwiftMath" ./scripts/bench-math-renderer-candidates.sh
#   KERN_MATH_BENCH_PREPARE_ONLY=1 ./scripts/bench-math-renderer-candidates.sh
#
# Timing output is only decision-quality on a quiet machine. On a busy system,
# use the output only as an integration smoke test.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORK_ROOT="${KERN_MATH_BENCH_WORK_ROOT:-$ROOT_DIR/tmp/math-renderer-candidates/$TIMESTAMP}"
OUT_ROOT="${KERN_MATH_BENCH_OUTPUT_ROOT:-$ROOT_DIR/benchmark-archive/math-renderer-candidates/$TIMESTAMP}"
RUNS="${KERN_MATH_BENCH_RUNS:-7}"
WARMUPS="${KERN_MATH_BENCH_WARMUPS:-2}"
CANDIDATES="${KERN_MATH_BENCH_CANDIDATES:-iosMath SwiftMath}"
SWIFT_BIN="${SWIFT_BIN:-swift}"
PREPARE_ONLY="${KERN_MATH_BENCH_PREPARE_ONLY:-0}"
MATH_CORPUS_JSON="${KERN_MATH_BENCH_CORPUS_JSON:-$ROOT_DIR/test-fixtures/rich-block-eval/math-renderer-corpus.json}"
FORMULAS_JSON="$WORK_ROOT/math-benchmark-formulas.json"

mkdir -p "$WORK_ROOT" "$OUT_ROOT"

prepare_formula_corpus() {
  python3 - "$MATH_CORPUS_JSON" "$FORMULAS_JSON" <<'PYFORMULAS'
import json, pathlib, sys
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
corpus = json.loads(src.read_text())
formulas = []
for case in corpus.get("cases", []):
    features = set(case.get("features", []))
    display = bool(case.get("display"))
    width = 720.0 if display else 520.0
    if "long-wrap" in features:
        width = 260.0
    formulas.append({
        "name": case["id"],
        "latex": case["latex"],
        "display": display,
        "width": width,
    })
if len(formulas) < 12:
    raise SystemExit(f"Math benchmark corpus is too small: {len(formulas)} cases")
dst.write_text(json.dumps(formulas, indent=2, sort_keys=True) + "\n")
PYFORMULAS
}

write_package() {
  local candidate="$1"
  local dir="$WORK_ROOT/${candidate}-candidate"
  mkdir -p "$dir/Sources/MathCandidateBench"

  local package_url version product import_name
  case "$candidate" in
    iosMath)
      package_url="https://github.com/kostub/iosMath.git"
      version="2.3.1"
      product="iosMath"
      import_name="iosMath"
      ;;
    SwiftMath)
      package_url="https://github.com/mgriebling/SwiftMath.git"
      version="1.7.1"
      product="SwiftMath"
      import_name="SwiftMath"
      ;;
    *)
      echo "Unknown candidate: $candidate" >&2
      exit 64
      ;;
  esac

  cat > "$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernMathCandidateBench_$candidate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MathCandidateBench", targets: ["MathCandidateBench"]),
    ],
    dependencies: [
        .package(url: "$package_url", exact: "$version"),
    ],
    targets: [
        .executableTarget(
            name: "MathCandidateBench",
            dependencies: ["$product"]
        ),
    ]
)
EOF

  cat > "$dir/Sources/MathCandidateBench/main.swift" <<EOF
import AppKit
import Foundation
import $import_name

struct Formula: Codable {
    let name: String
    let latex: String
    let display: Bool
    let width: Double
}

struct FormulaResult: Codable {
    let name: String
    let display: Bool
    let width: Double
    let runs: Int
    let warmups: Int
    let minMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let meanMs: Double
    let maxMs: Double
    let outputWidth: Double
    let outputHeight: Double
    let error: String?
    let samplesMs: [Double]
}

struct Report: Codable {
    let generatedAt: String
    let candidate: String
    let dependencyVersion: String
    let notes: [String]
    let results: [FormulaResult]
}

func loadFormulas() throws -> [Formula] {
    let env = ProcessInfo.processInfo.environment
    if let path = env["KERN_MATH_BENCH_FORMULAS_JSON"], !path.isEmpty {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([Formula].self, from: data)
    }

    // Fallback keeps the generated package runnable by hand, but the script
    // normally supplies the tracked rich-block math corpus via JSON.
    return [
        .init(name: "inline-einstein", latex: #"E=mc^2"#, display: false, width: 520),
        .init(name: "fraction-radical", latex: #"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#, display: true, width: 720),
        .init(name: "matrix", latex: #"\begin{bmatrix} a & b \\ c & d \end{bmatrix}"#, display: true, width: 720),
        .init(name: "invalid-command", latex: #"\badcommand{x}+1"#, display: false, width: 520),
    ]
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    if values.count == 1 { return values[0] }
    let sorted = values.sorted()
    let rank = max(0, min(1, p)) * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    if lower == upper { return sorted[lower] }
    let fraction = rank - Double(lower)
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
}

@MainActor
func draw(label: MTMathUILabel, size: CGSize) {
    let width = max(1, Int(ceil(size.width)))
    let height = max(1, Int(ceil(size.height)))
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
    label.draw(label.bounds)
    NSGraphicsContext.restoreGraphicsState()
}

@MainActor
func configure(label: MTMathUILabel, formula: Formula) {
    label.latex = formula.latex
    label.fontSize = formula.display ? 24 : 16
    label.textAlignment = .center
EOF

  if [ "$candidate" = "iosMath" ]; then
    cat >> "$dir/Sources/MathCandidateBench/main.swift" <<'EOF'
    label.mode = formula.display ? .display : .text
EOF
  else
    cat >> "$dir/Sources/MathCandidateBench/main.swift" <<'EOF'
    label.labelMode = formula.display ? .display : .text
EOF
  fi

  cat >> "$dir/Sources/MathCandidateBench/main.swift" <<EOF
}

@MainActor
func measure(formula: Formula, runs: Int, warmups: Int) -> FormulaResult {
    var samples: [Double] = []
    samples.reserveCapacity(runs)
    var lastSize = CGSize.zero
    var lastError: String? = nil

    for index in 0..<(warmups + runs) {
        autoreleasepool {
            let label = MTMathUILabel(frame: CGRect(x: 0, y: 0, width: formula.width, height: 240))
            configure(label: label, formula: formula)
            let start = DispatchTime.now().uptimeNanoseconds
            let measured = label.fittingSize
            let size = CGSize(width: max(1, ceil(measured.width)), height: max(1, ceil(measured.height)))
            label.frame = CGRect(origin: .zero, size: size)
            label.layoutSubtreeIfNeeded()
            draw(label: label, size: size)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            lastSize = size
            lastError = label.error?.localizedDescription
            if index >= warmups {
                samples.append(elapsed)
            }
        }
    }

    return FormulaResult(
        name: formula.name,
        display: formula.display,
        width: formula.width,
        runs: runs,
        warmups: warmups,
        minMs: samples.min() ?? 0,
        p50Ms: percentile(samples, 0.50),
        p95Ms: percentile(samples, 0.95),
        meanMs: samples.reduce(0, +) / Double(max(samples.count, 1)),
        maxMs: samples.max() ?? 0,
        outputWidth: Double(lastSize.width),
        outputHeight: Double(lastSize.height),
        error: lastError,
        samplesMs: samples
    )
}

@main
struct MathCandidateBench {
    @MainActor
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let runs = max(1, Int(env["KERN_MATH_BENCH_RUNS"] ?? "") ?? $RUNS)
        let warmups = max(0, Int(env["KERN_MATH_BENCH_WARMUPS"] ?? "") ?? $WARMUPS)
        let outputPath = env["KERN_MATH_BENCH_OUTPUT"] ?? "math-$candidate.json"
        _ = NSApplication.shared
        let formulas = try loadFormulas()

        let report = Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            candidate: "$candidate",
            dependencyVersion: "$version",
            notes: [
                "Measures MTMathUILabel LaTeX parse + fittingSize + offscreen draw.",
                "Standalone SwiftPM candidate benchmark; the dependency is not linked into Kern's app target.",
                "Use only as decision-quality timing on a quiet machine."
            ],
            results: formulas.map { formula in measure(formula: formula, runs: runs, warmups: warmups) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print(outputPath)
    }
}
EOF
}

write_markdown_summary() {
  local json_path="$1"
  local md_path="$2"
  python3 - "$json_path" "$md_path" <<'PY'
import json, sys, pathlib
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
report = json.loads(src.read_text())
lines = []
lines.append(f"# Math renderer candidate benchmark: {report['candidate']}\n")
lines.append(f"- Generated: {report['generatedAt']}")
lines.append(f"- Candidate: `{report['candidate']}`")
lines.append(f"- Dependency version: `{report['dependencyVersion']}`")
lines.append(f"- JSON: `{src.name}`")
lines.append("")
lines.append("| Formula | p50 ms | p95 ms | Mean ms | Output | Error |")
lines.append("|---|---:|---:|---:|---:|---|")
for row in report["results"]:
    err = (row.get("error") or "").replace("|", "\\|")
    output = f"{row['outputWidth']:.0f}x{row['outputHeight']:.0f}"
    lines.append(f"| `{row['name']}` | {row['p50Ms']:.3f} | {row['p95Ms']:.3f} | {row['meanMs']:.3f} | {output} | {err} |")
lines.append("")
lines.append("## Notes")
for note in report.get("notes", []):
    lines.append(f"- {note}")
dst.write_text("\n".join(lines) + "\n")
PY
}

prepare_formula_corpus

for candidate in $CANDIDATES; do
  echo "==> Preparing $candidate"
  write_package "$candidate"
  candidate_dir="$WORK_ROOT/${candidate}-candidate"
  json_path="$OUT_ROOT/$candidate.json"
  md_path="$OUT_ROOT/$candidate.md"

  if [ "$PREPARE_ONLY" = "1" ]; then
    echo "==> Prepared $candidate at $candidate_dir"
    continue
  fi

  echo "==> Running $candidate benchmark smoke/benchmark"
  (
    cd "$candidate_dir"
    KERN_MATH_BENCH_RUNS="$RUNS" \
    KERN_MATH_BENCH_WARMUPS="$WARMUPS" \
    KERN_MATH_BENCH_OUTPUT="$json_path" \
    KERN_MATH_BENCH_FORMULAS_JSON="$FORMULAS_JSON" \
    "$SWIFT_BIN" run -c release MathCandidateBench
  )
  write_markdown_summary "$json_path" "$md_path"
  echo "==> Wrote $json_path"
  echo "==> Wrote $md_path"
done

cat > "$OUT_ROOT/README.md" <<EOF
# Kern math renderer candidate benchmark run

- Generated: $TIMESTAMP
- Runs per formula: $RUNS
- Warmups per formula: $WARMUPS
- Work root: $WORK_ROOT
- Formula corpus: $MATH_CORPUS_JSON
- Generated formula JSON: $FORMULAS_JSON
- Candidates: $CANDIDATES
- Prepare only: $PREPARE_ONLY

This run benchmarks native math-renderer candidates in standalone SwiftPM
packages. It does not add either dependency to Kern's shipped app target.

Use timing results as a renderer-selection artifact only if the machine was
quiet during the run. Otherwise treat this as an integration smoke test.
EOF

echo "==> Complete: $OUT_ROOT"
