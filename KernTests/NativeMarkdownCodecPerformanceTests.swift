import Foundation
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecPerformanceTests: XCTestCase {
    private struct StagedSliceBenchmarkResult: Codable {
        let targetUTF16: Int
        let actualUTF16: Int
        let runs: Int
        let p50Ms: Double
        let p95Ms: Double
        let minMs: Double
        let maxMs: Double
        let meanMs: Double
        let samplesMs: [Double]
    }

    private struct StagedSliceBenchmarkReport: Codable {
        let generatedAt: String
        let fixture: String
        let fixtureBytes: Int
        let runsPerSlice: Int
        let syntaxHighlightingEnabled: Bool
        let results: [StagedSliceBenchmarkResult]
    }

    private struct MermaidModeResult: Codable {
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

    private struct MermaidReportPayload: Codable {
        let generatedAt: String
        let fixture: String
        let fixtureBytes: Int
        let runsPerMode: Int
        let notes: [String]
        let results: [MermaidModeResult]
    }

    @MainActor
    func testImportExportBenchmarkFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let md = try loadPerfFixture(name: "native-editor-benchmark.md")

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            let attr = NativeMarkdownCodec.importMarkdown(md)
            _ = NativeMarkdownCodec.exportMarkdown(attr)
        }
    }

    @MainActor
    func testImportOnlyBenchmarkFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let md = try loadPerfFixture(name: "native-editor-benchmark.md")

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            _ = NativeMarkdownCodec.importMarkdown(md)
        }
    }

    @MainActor
    func testExportOnlyBenchmarkFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let md = try loadPerfFixture(name: "native-editor-benchmark.md")
        let attr = NativeMarkdownCodec.importMarkdown(md)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            _ = NativeMarkdownCodec.exportMarkdown(attr)
        }
    }

    @MainActor
    func testParseInlineMicroBenchmark() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        // Build ~100KB of inline-dense text.
        var lines: [String] = []
        let patterns = [
            "**bold text** and *italic text* and `inline code` and [link](https://example.com)",
            "***bold italic*** then ~~strikethrough~~ then `code span` here",
            "Some text with $E=mc^2$ inline math and **nested *bold italic* end**",
            "[reference link](https://example.com/path?q=1#frag) and ~~**bold strike**~~",
            "`code` **bold** *italic* ~~strike~~ [link](url) $x^2$ normal text here",
            "**bold with `code inside` and *italic inside* too** end of line",
            "Start *italic **bold italic** italic* end ~~strike `code strike`~~ done",
            "Multiple [link1](url1) and [link2](url2) and [link3](url3) links",
            "Dense: **b***i*~~s~~`c`[l](u)**b***i*~~s~~`c`[l](u)**b***i*~~s~~`c`[l](u)",
            "Math: $\\alpha+\\beta=\\gamma$ and $\\sum_{i=1}^{n} i$ and $\\int_0^1 x dx$",
        ]
        var currentSize = 0
        let targetSize = 100_000
        var patternIndex = 0
        while currentSize < targetSize {
            let line = patterns[patternIndex % patterns.count]
            lines.append(line)
            currentSize += line.utf8.count + 1
            patternIndex += 1
        }
        let inlineText = lines.joined(separator: "\n")
        XCTAssertGreaterThan(inlineText.utf8.count, 90_000)

        let baseFont = NSFont.systemFont(ofSize: 16)

        measure(metrics: [XCTClockMetric()], options: defaultPerformanceOptions()) {
            _ = NativeMarkdownCodec.parseInline(inlineText, baseFont: baseFont)
        }
    }

    @MainActor
    func testStagedPromotionSliceParseBenchmark() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadPerfFixture(name: "native-editor-benchmark.md")
        let runs = max(3, TestRuntimeConfig.int("KERN_STAGED_SLICE_BENCH_RUNS", default: 7) ?? 7)
        let targets = [128_000, 256_000, 512_000, 1_000_000]
        var options = NativeMarkdownCodec.Options.fromUserDefaults()
        options.syntaxHighlightingEnabled = false

        var results: [StagedSliceBenchmarkResult] = []
        for target in targets {
            let slice = alignedPrefix(source, utf16Count: target)
            var samples: [Double] = []
            samples.reserveCapacity(runs)
            for _ in 0..<runs {
                autoreleasepool {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = NativeMarkdownCodec.importMarkdown(slice, options: options)
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                    samples.append(Double(elapsedNs) / 1_000_000)
                }
            }

            let result = StagedSliceBenchmarkResult(
                targetUTF16: target,
                actualUTF16: slice.utf16.count,
                runs: runs,
                p50Ms: percentile(samples, 0.50),
                p95Ms: percentile(samples, 0.95),
                minMs: samples.min() ?? .zero,
                maxMs: samples.max() ?? .zero,
                meanMs: samples.reduce(0, +) / Double(max(samples.count, 1)),
                samplesMs: samples
            )
            results.append(result)
        }

        let report = StagedSliceBenchmarkReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixture: "native-editor-benchmark.md",
            fixtureBytes: source.utf8.count,
            runsPerSlice: runs,
            syntaxHighlightingEnabled: options.syntaxHighlightingEnabled,
            results: results
        )
        try writeStagedSliceBenchmarkReport(report)
    }

    @MainActor
    func testMermaidRenderModeBenchmarkMatrix() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_MERMAID_MODE_BENCHMARKS") else {
            throw XCTSkip("Set KERN_ENABLE_MERMAID_MODE_BENCHMARKS=1 to run Mermaid render-mode benchmark")
        }

        let sourceFixture = try loadPerfFixture(name: "native-editor-benchmark.md")
        let markdown = benchmarkMarkdown(from: sourceFixture)
        let runs = max(3, TestRuntimeConfig.int("KERN_MERMAID_BENCH_RUNS", default: 9) ?? 9)

        let modes: [NativeMarkdownCodec.Options.MermaidRenderMode] = [.rich, .ascii, .auto]
        var results: [MermaidModeResult] = []

        for mode in modes {
            let result = runMermaidMode(mode, markdown: markdown, runs: runs)
            results.append(result)
        }

        let payload = MermaidReportPayload(
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

        try writeMermaidModeReport(payload)
    }

    @MainActor
    private func runMermaidMode(
        _ mode: NativeMarkdownCodec.Options.MermaidRenderMode,
        markdown: String,
        runs: Int
    ) -> MermaidModeResult {
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

        return MermaidModeResult(
            mode: mode.rawValue,
            runs: runs,
            mermaidAttachmentsPerRun: perRunAttachmentCount,
            effectiveModeCounts: effectiveModeCounts,
            p50Ms: percentile(samples, 0.50),
            p95Ms: percentile(samples, 0.95),
            minMs: samples.min() ?? .zero,
            maxMs: samples.max() ?? .zero,
            meanMs: samples.reduce(0, +) / Double(max(samples.count, 1)),
            samplesMs: samples
        )
    }

    private func benchmarkMarkdown(from sourceFixture: String) -> String {
        let blocks = extractMermaidBodies(from: sourceFixture)
        let seedBlocks: [String]
        if blocks.isEmpty {
            seedBlocks = [
                "flowchart TD\nA[Start] --> B[Parse] --> C[Render]",
                "sequenceDiagram\nparticipant User\nparticipant Kern\nUser->>Kern: Open file\nKern-->>User: Ready",
            ]
        } else {
            seedBlocks = Array(blocks.prefix(10))
        }
        let heavyBlocks = [heavySequenceBlock(), heavyFlowchartBlock()]

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
            for (index, block) in heavyBlocks.enumerated() {
                out.append("## Mermaid Heavy Case \(cycle)-\(index + 1)")
                out.append("")
                out.append("```mermaid")
                out.append(block)
                out.append("```")
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    private func alignedPrefix(_ markdown: String, utf16Count: Int) -> String {
        let ns = markdown as NSString
        if ns.length <= utf16Count { return markdown }
        var endLocation = max(0, min(utf16Count, ns.length))
        if endLocation < ns.length {
            let searchRange = NSRange(location: endLocation, length: min(ns.length - endLocation, 8_192))
            let newlineRange = ns.range(of: "\n", options: [], range: searchRange)
            if newlineRange.location != NSNotFound {
                endLocation = newlineRange.location + newlineRange.length
            }
        }
        let end = String.Index(utf16Offset: endLocation, in: markdown)
        return String(markdown[..<end])
    }

    private func heavySequenceBlock() -> String {
        var lines: [String] = ["sequenceDiagram"]
        for i in 0..<20 {
            lines.append("  participant P\(i) as Participant \(i)")
        }
        for i in 0..<36 {
            let from = i % 14
            let to = (i + 3) % 14
            lines.append("  P\(from)->>P\(to): long message label \(i) for complexity scoring")
        }
        return lines.joined(separator: "\n")
    }

    private func heavyFlowchartBlock() -> String {
        var lines: [String] = ["flowchart TD"]
        for i in 0..<22 {
            lines.append("  N\(i)[Node \(i) with descriptive label for benchmark complexity]")
        }
        for i in 0..<21 {
            lines.append("  N\(i) -->|transition \(i)| N\(i + 1)")
        }
        for i in 0..<10 {
            let from = i + 2
            let to = max(0, i - 1)
            lines.append("  N\(from) -->|feedback \(i)| N\(to)")
        }
        return lines.joined(separator: "\n")
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

    private func writeMermaidModeReport(_ payload: MermaidReportPayload) throws {
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
        let data = try encoder.encode(payload)
        try data.write(to: jsonURL)

        let markdown = renderMermaidModeMarkdownReport(payload: payload, jsonFilename: jsonURL.lastPathComponent)
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        add(XCTAttachment(string: markdown))
        print("Mermaid mode benchmark report: \(mdURL.path)")
        print("Mermaid mode benchmark json: \(jsonURL.path)")
    }

    private func writeStagedSliceBenchmarkReport(_ payload: StagedSliceBenchmarkReport) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let archiveDir = root
            .appendingPathComponent("benchmark-archive", isDirectory: true)
            .appendingPathComponent("staged-slice-benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let jsonURL = archiveDir.appendingPathComponent("\(stamp)-staged-slice-benchmark.json")
        let mdURL = archiveDir.appendingPathComponent("\(stamp)-staged-slice-benchmark.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: jsonURL)

        var lines: [String] = []
        lines.append("# Staged Promotion Slice Parse Benchmark")
        lines.append("")
        lines.append("- Generated: \(payload.generatedAt)")
        lines.append("- Fixture: \(payload.fixture) (\(payload.fixtureBytes) bytes)")
        lines.append("- Runs per slice: \(payload.runsPerSlice)")
        lines.append("- Syntax highlighting: \(payload.syntaxHighlightingEnabled ? "enabled" : "disabled")")
        lines.append("")
        lines.append("| Target UTF16 | Actual UTF16 | p50 (ms) | p95 (ms) | min (ms) | max (ms) | mean (ms) |")
        lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for result in payload.results {
            lines.append(
                "| \(result.targetUTF16) | \(result.actualUTF16) | \(formatMs(result.p50Ms)) | " +
                "\(formatMs(result.p95Ms)) | \(formatMs(result.minMs)) | " +
                "\(formatMs(result.maxMs)) | \(formatMs(result.meanMs)) |"
            )
        }
        lines.append("")
        try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)

        print("Staged slice benchmark report: \(mdURL.path)")
        print("Staged slice benchmark json: \(jsonURL.path)")
    }

    private func renderMermaidModeMarkdownReport(payload: MermaidReportPayload, jsonFilename: String) -> String {
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
            lines.append("| \(result.mode) | \(formatMs(result.p50Ms)) | \(formatMs(result.p95Ms)) | \(formatMs(result.meanMs)) | \(effective) |")
        }
        lines.append("")

        if let rich = payload.results.first(where: { $0.mode == "rich" }),
           let ascii = payload.results.first(where: { $0.mode == "ascii" }),
           let auto = payload.results.first(where: { $0.mode == "auto" }) {
            let asciiGain = percentageGain(baseline: rich.p50Ms, candidate: ascii.p50Ms)
            let autoGain = percentageGain(baseline: rich.p50Ms, candidate: auto.p50Ms)
            lines.append("## Recommendation")
            lines.append("")
            lines.append("- ASCII vs Rich p50 gain: \(formatMs(asciiGain))%")
            lines.append("- Auto vs Rich p50 gain: \(formatMs(autoGain))%")
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

    private func formatMs(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
