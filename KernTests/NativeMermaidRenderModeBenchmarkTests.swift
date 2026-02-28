import AppKit
import Foundation
import XCTest
@testable import KernTextKit

final class NativeMermaidRenderModeBenchmarkTests: XCTestCase {
    private struct ModeResult: Codable {
        let mode: String
        let runs: Int
        let mermaidAttachmentsPerRun: Int
        let effectiveModeCounts: [String: Int]
        let p50Ms: Double
        let p95Ms: Double
        let minMs: Double
        let maxMs: Double
        let meanMs: Double
        let samplesMs: [Double]
    }

    private struct ReportPayload: Codable {
        let generatedAt: String
        let fixture: String
        let fixtureBytes: Int
        let runsPerMode: Int
        let notes: [String]
        let results: [ModeResult]
    }

    @MainActor
    func testMermaidRenderModeBenchmarkMatrix() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") || TestRuntimeConfig.bool("KERN_ENABLE_MERMAID_MODE_BENCHMARKS") else {
            throw XCTSkip("Set KERN_ENABLE_MERMAID_MODE_BENCHMARKS=1 (or KERN_ENABLE_PERF_TESTS=1) to run")
        }

        let sourceFixture = try loadPerfFixture(name: "native-editor-benchmark.md")
        let markdown = benchmarkMarkdown(from: sourceFixture)
        let runs = max(3, TestRuntimeConfig.int("KERN_MERMAID_BENCH_RUNS", default: 9) ?? 9)

        let modes: [NativeMarkdownCodec.Options.MermaidRenderMode] = [.rich, .ascii, .auto]
        var results: [ModeResult] = []

        for mode in modes {
            let result = runMode(mode, markdown: markdown, runs: runs)
            results.append(result)
        }

        XCTAssertEqual(results.count, 3)

        let payload = ReportPayload(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixture: "generated-mermaid-mode-benchmark",
            fixtureBytes: markdown.utf8.count,
            runsPerMode: runs,
            notes: [
                "Measures import + mermaid attachment bounds computation.",
                "Uses a generated heavy Mermaid-only fixture derived from native-editor-benchmark.md.",
                "Auto mode chooses rich/ascii per-diagram by complexity score."
            ],
            results: results
        )

        try writeReport(payload)
    }

    @MainActor
    private func runMode(
        _ mode: NativeMarkdownCodec.Options.MermaidRenderMode,
        markdown: String,
        runs: Int
    ) -> ModeResult {
        let lineFragment = NSRect(x: 0, y: 0, width: 760, height: 28)
        var samples: [Double] = []
        samples.reserveCapacity(runs)
        var perRunAttachmentCount = 0
        var effectiveModeCounts: [String: Int] = [:]

        for _ in 0..<runs {
            autoreleasepool {
                var options = NativeMarkdownCodec.Options()
                options.mermaidRenderMode = mode

                let start = DispatchTime.now().uptimeNanoseconds
                let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options)
                let mermaids = collectMermaidAttachments(in: attributed)
                perRunAttachmentCount = max(perRunAttachmentCount, mermaids.count)

                var areaAccumulator: CGFloat = 0
                for attachment in mermaids {
                    let effective = attachment.debugEffectiveRenderModeForTesting.rawValue
                    effectiveModeCounts[effective, default: 0] += 1
                    for _ in 0..<3 {
                        let bounds = attachment.attachmentBounds(
                            for: nil,
                            proposedLineFragment: lineFragment,
                            glyphPosition: .zero,
                            characterIndex: 0
                        )
                        areaAccumulator += bounds.width * bounds.height
                    }
                }
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                let elapsedMs = Double(elapsedNs) / 1_000_000
                samples.append(elapsedMs + Double(areaAccumulator) * 0.0)
            }
        }

        XCTAssertGreaterThan(perRunAttachmentCount, 0, "Benchmark fixture should include Mermaid attachments")

        let p50 = percentile(samples, 0.50)
        let p95 = percentile(samples, 0.95)
        let minV = samples.min() ?? .zero
        let maxV = samples.max() ?? .zero
        let mean = samples.reduce(0, +) / Double(max(samples.count, 1))

        return ModeResult(
            mode: mode.rawValue,
            runs: runs,
            mermaidAttachmentsPerRun: perRunAttachmentCount,
            effectiveModeCounts: effectiveModeCounts,
            p50Ms: p50,
            p95Ms: p95,
            minMs: minV,
            maxMs: maxV,
            meanMs: mean,
            samplesMs: samples
        )
    }

    private func benchmarkMarkdown(from sourceFixture: String) -> String {
        let blocks = extractMermaidBodies(from: sourceFixture)
        let seedBlocks: [String]
        if blocks.isEmpty {
            seedBlocks = [
                "flowchart TD\nA[Start] --> B[Parse] --> C[Render]",
                "sequenceDiagram\nparticipant User\nparticipant Kern\nUser->>Kern: Open file\nKern-->>User: Ready"
            ]
        } else {
            seedBlocks = Array(blocks.prefix(10))
        }

        var out: [String] = ["# Mermaid Render Mode Benchmark Fixture", ""]
        for cycle in 1...10 {
            for (index, block) in seedBlocks.enumerated() {
                out.append("## Mermaid Case \(cycle)-\(index + 1)")
                out.append("")
                out.append("```mermaid")
                out.append(block)
                out.append("```")
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    private func extractMermaidBodies(from markdown: String) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var bodies: [String] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.hasPrefix("```mermaid") else {
                index += 1
                continue
            }

            index += 1
            var bodyLines: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                    break
                }
                bodyLines.append(line)
                index += 1
            }
            if !bodyLines.isEmpty {
                bodies.append(bodyLines.joined(separator: "\n"))
            }

            while index < lines.count, lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != "```" {
                index += 1
            }
            if index < lines.count {
                index += 1
            }
        }

        return bodies
    }

    private func collectMermaidAttachments(in attributed: NSAttributedString) -> [MarkdownMermaidAttachment] {
        var out: [MarkdownMermaidAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            if let attachment = value as? MarkdownMermaidAttachment {
                out.append(attachment)
            }
        }
        return out
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .zero }
        if values.count == 1 { return values[0] }
        let sorted = values.sorted()
        let clamped = min(1, max(0, p))
        let rank = clamped * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = rank - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    private func writeReport(_ payload: ReportPayload) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let archiveDir = root
            .appendingPathComponent("benchmark-archive", isDirectory: true)
            .appendingPathComponent("mermaid-render-modes", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let jsonURL = archiveDir.appendingPathComponent("\(stamp)-mermaid-render-modes.json")
        let mdURL = archiveDir.appendingPathComponent("\(stamp)-mermaid-render-modes.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: jsonURL)

        let markdown = renderMarkdownReport(payload: payload, jsonFilename: jsonURL.lastPathComponent)
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        add(XCTAttachment(string: markdown))
        print("Mermaid mode benchmark report: \(mdURL.path)")
        print("Mermaid mode benchmark json: \(jsonURL.path)")
    }

    private func renderMarkdownReport(payload: ReportPayload, jsonFilename: String) -> String {
        var lines: [String] = []
        lines.append("# Mermaid Render Mode Benchmark")
        lines.append("")
        lines.append("- Generated: \(payload.generatedAt)")
        lines.append("- Runs per mode: \(payload.runsPerMode)")
        lines.append("- Fixture bytes: \(payload.fixtureBytes)")
        lines.append("- JSON: \(jsonFilename)")
        lines.append("")
        lines.append("| Mode | p50 (ms) | p95 (ms) | Mean (ms) | Effective mode counts |")
        lines.append("| --- | ---: | ---: | ---: | --- |")
        for result in payload.results {
            let effective = result.effectiveModeCounts
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ", ")
            lines.append("| \(result.mode) | \(format(result.p50Ms)) | \(format(result.p95Ms)) | \(format(result.meanMs)) | \(effective) |")
        }
        lines.append("")

        if let rich = payload.results.first(where: { $0.mode == "rich" }),
           let ascii = payload.results.first(where: { $0.mode == "ascii" }),
           let auto = payload.results.first(where: { $0.mode == "auto" }) {
            let asciiGain = percentageGain(baseline: rich.p50Ms, candidate: ascii.p50Ms)
            let autoGain = percentageGain(baseline: rich.p50Ms, candidate: auto.p50Ms)
            lines.append("## Recommendation")
            lines.append("")
            lines.append("- ASCII vs Rich p50 gain: \(format(asciiGain))%")
            lines.append("- Auto vs Rich p50 gain: \(format(autoGain))%")
            lines.append("- Suggested default for heavy Mermaid docs: \(ascii.p50Ms < rich.p50Ms ? "ASCII or Auto" : "Rich")")
            lines.append("")
        }

        lines.append("## Notes")
        lines.append("")
        for note in payload.notes {
            lines.append("- \(note)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func percentageGain(baseline: Double, candidate: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return ((baseline - candidate) / baseline) * 100
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
