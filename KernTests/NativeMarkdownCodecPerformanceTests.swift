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

    private struct ImportPhaseCaseSpec {
        let name: String
        let markdown: String
        let syntaxHighlightingEnabled: Bool
        let reuseReferenceDefinitions: Bool
    }

    private struct ImportPhaseCaseResult: Codable {
        let name: String
        let utf16Count: Int
        let lineCount: Int
        let runs: Int
        let syntaxHighlightingEnabled: Bool
        let referenceDefinitionsMode: String
        let totalP50Ms: Double
        let totalP95Ms: Double
        let totalMeanMs: Double
        let phaseP50Ms: [String: Double]
        let phaseP95Ms: [String: Double]
        let phaseMeanMs: [String: Double]
        let phaseCounts: [String: Int]
        let totalInlineUTF16: Int
        let maxInlineUTF16: Int
    }

    private struct ImportPhaseProfileReport: Codable {
        let generatedAt: String
        let fixture: String
        let fixtureBytes: Int
        let runsPerCase: Int
        let notes: [String]
        let results: [ImportPhaseCaseResult]
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
    func testParseInlineRepeatedShortFragmentsBenchmark() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let fragments = buildRepeatedShortInlineFragments()
        XCTAssertGreaterThan(fragments.count, 2_000)

        let baseFont = NSFont.systemFont(ofSize: 16)

        measure(metrics: [XCTClockMetric()], options: defaultPerformanceOptions()) {
            NativeMarkdownCodec.resetCachesForTesting()

            var totalLength = 0
            for fragment in fragments {
                totalLength &+= NativeMarkdownCodec.parseInline(fragment, baseFont: baseFont).length
            }

            XCTAssertGreaterThan(totalLength, 0, "Repeated short-fragment benchmark should produce attributed output")
        }
    }

    @MainActor
    func testImageAttachmentImportAndBoundsPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let markdown = buildImageAttachmentBenchmarkMarkdown()
        let baseURL = perfFixtureRootURL()
        let lineFragment = NSRect(x: 0, y: 0, width: 760, height: 28)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            MarkdownImageAttachment.resetImageCacheForTesting()
            let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: baseURL)
            let images = collectImageAttachments(in: attributed)
            XCTAssertGreaterThanOrEqual(images.count, 24, "Image benchmark should create local image attachments")

            var areaAccumulator: CGFloat = 0
            for attachment in images {
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
            XCTAssertGreaterThan(areaAccumulator, 0)
        }
    }

    @MainActor
    func testMathBlockImportAndBoundsPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let markdown = buildMathBlockBenchmarkMarkdown()
        let lineFragment = NSRect(x: 0, y: 0, width: 760, height: 28)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: nil)
            let mathBlocks = collectMathBlockAttachments(in: attributed)
            XCTAssertGreaterThanOrEqual(mathBlocks.count, 24, "Math benchmark should create block math attachments")

            var areaAccumulator: CGFloat = 0
            for attachment in mathBlocks {
                for _ in 0..<4 {
                    let bounds = attachment.attachmentBounds(
                        for: nil,
                        proposedLineFragment: lineFragment,
                        glyphPosition: .zero,
                        characterIndex: 0
                    )
                    areaAccumulator += bounds.width * bounds.height
                }
            }
            XCTAssertGreaterThan(areaAccumulator, 0)
        }
    }

    @MainActor
    func testMermaidImportAndBoundsPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let sourceFixture = try loadPerfFixture(name: "native-editor-benchmark.md")
        let markdown = benchmarkMarkdown(from: sourceFixture)
        let lineFragment = NSRect(x: 0, y: 0, width: 760, height: 28)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            var options = NativeMarkdownCodec.Options.fromUserDefaults()
            options.mermaidRenderMode = .auto
            let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
            let mermaids = collectMermaidAttachments(in: attributed)
            XCTAssertGreaterThanOrEqual(mermaids.count, 12, "Mermaid benchmark should create Mermaid attachments")

            var areaAccumulator: CGFloat = 0
            for attachment in mermaids {
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
            XCTAssertGreaterThan(areaAccumulator, 0)
        }
    }

    @MainActor
    func testImportPhaseProfileBenchmark() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadPerfFixture(name: "native-editor-benchmark.md")
        let referenceDefinitions = NativeMarkdownCodec.collectReferenceDefinitions(in: source)
        let runs = max(3, TestRuntimeConfig.int("KERN_IMPORT_PHASE_PROFILE_RUNS", default: 3) ?? 3)
        let specs = try buildImportPhaseCaseSpecs(from: source)

        var results: [ImportPhaseCaseResult] = []
        for spec in specs {
            NativeMarkdownCodec.resetCachesForTesting()
            var options = NativeMarkdownCodec.Options.fromUserDefaults()
            options.syntaxHighlightingEnabled = spec.syntaxHighlightingEnabled

            var totalSamples: [Double] = []
            var phaseSamples: [String: [Double]] = [:]
            var latestProfile: NativeMarkdownCodec.ImportProfileSnapshot?
            let precomputedReferenceDefinitions = spec.reuseReferenceDefinitions ? referenceDefinitions : nil

            for _ in 0..<runs {
                autoreleasepool {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let profiled = NativeMarkdownCodec.importMarkdownProfiled(
                        spec.markdown,
                        options: options,
                        precomputedReferenceDefinitions: precomputedReferenceDefinitions
                    )
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                    let elapsedMs = Double(elapsedNs) / 1_000_000
                    totalSamples.append(elapsedMs)
                    XCTAssertGreaterThan(profiled.attributed.length, 0, "Profiled import should still build attributed output for \(spec.name)")

                    for (phase, sample) in profiled.profile.phaseDurationsMs {
                        phaseSamples[phase, default: []].append(sample)
                    }
                    latestProfile = profiled.profile
                }
            }

            let profile = try XCTUnwrap(latestProfile, "Expected a profile snapshot for \(spec.name)")
            let phaseP50 = aggregatePhaseSamples(phaseSamples, percentile: 0.50)
            let phaseP95 = aggregatePhaseSamples(phaseSamples, percentile: 0.95)
            let phaseMean = aggregatePhaseMeans(phaseSamples)

            results.append(
                ImportPhaseCaseResult(
                    name: spec.name,
                    utf16Count: spec.markdown.utf16.count,
                    lineCount: spec.markdown.split(separator: "\n", omittingEmptySubsequences: false).count,
                    runs: runs,
                    syntaxHighlightingEnabled: spec.syntaxHighlightingEnabled,
                    referenceDefinitionsMode: spec.reuseReferenceDefinitions ? "precomputed" : "scan-on-import",
                    totalP50Ms: percentile(totalSamples, 0.50),
                    totalP95Ms: percentile(totalSamples, 0.95),
                    totalMeanMs: totalSamples.reduce(0, +) / Double(max(totalSamples.count, 1)),
                    phaseP50Ms: phaseP50,
                    phaseP95Ms: phaseP95,
                    phaseMeanMs: phaseMean,
                    phaseCounts: profile.phaseCounts,
                    totalInlineUTF16: profile.totalInlineUTF16,
                    maxInlineUTF16: profile.maxInlineUTF16
                )
            )
        }

        let report = ImportPhaseProfileReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            fixture: "native-editor-benchmark.md",
            fixtureBytes: source.utf8.count,
            runsPerCase: runs,
            notes: [
                "Profiles NativeMarkdownCodec.importMarkdown with the internal ImportProfiler.",
                "Caches are reset before each case so later cases do not inherit warmed parser state from earlier ones.",
                "Cases marked `precomputed` reuse benchmark-fixture reference definitions to better match staged promotion reality; `scan-on-import` cases measure the reference scan directly.",
                "Phase timings are inclusive rather than additive: parent phases (for example `importLoop`) already include nested block and inline work.",
                "Phase timings are collected outside the official benchmark claim path."
            ],
            results: results
        )

        try writeImportPhaseProfileReport(report)
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

    private func alignedWindow(_ markdown: String, centerUTF16: Int, widthUTF16: Int) -> String {
        let ns = markdown as NSString
        guard ns.length > widthUTF16 else { return markdown }

        let halfWidth = max(1, widthUTF16 / 2)
        var startLocation = max(0, centerUTF16 - halfWidth)
        var endLocation = min(ns.length, centerUTF16 + halfWidth)

        if startLocation > 0 {
            let searchRange = NSRange(location: max(0, startLocation - min(startLocation, 8_192)), length: min(startLocation, 8_192))
            let newlineRange = ns.range(of: "\n", options: .backwards, range: searchRange)
            if newlineRange.location != NSNotFound {
                startLocation = newlineRange.location + newlineRange.length
            }
        }

        if endLocation < ns.length {
            let searchRange = NSRange(location: endLocation, length: min(ns.length - endLocation, 8_192))
            let newlineRange = ns.range(of: "\n", options: [], range: searchRange)
            if newlineRange.location != NSNotFound {
                endLocation = newlineRange.location + newlineRange.length
            }
        }

        guard startLocation < endLocation else { return markdown }
        let start = String.Index(utf16Offset: startLocation, in: markdown)
        let end = String.Index(utf16Offset: endLocation, in: markdown)
        return String(markdown[start..<end])
    }

    private func buildImportPhaseCaseSpecs(from markdown: String) throws -> [ImportPhaseCaseSpec] {
        let initialPrefix = alignedPrefix(markdown, utf16Count: 250_000)
        let largePrefix = alignedPrefix(markdown, utf16Count: 2_000_000)
        let midWindow = alignedWindow(markdown, centerUTF16: markdown.utf16.count / 2, widthUTF16: 128_000)
        let denseParagraphs = try extractSection(named: "Dense Paragraph Blocks", from: markdown)
        let codeFenceMatrix = try extractSection(named: "Code Fence Matrix", from: markdown)
        let tableMatrix = try extractSection(named: "Table Matrix", from: markdown)
        let attachmentRange = try extractSectionRange(startHeading: "Math Blocks", endHeading: "Dense Paragraph Blocks", from: markdown)

        return [
            ImportPhaseCaseSpec(name: "initial-prefix-250k-cold-scan", markdown: initialPrefix, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: false),
            ImportPhaseCaseSpec(name: "initial-prefix-250k-staged", markdown: initialPrefix, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "large-prefix-2m-staged", markdown: largePrefix, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "mid-window-128k", markdown: midWindow, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "full-fixture-highlight-on", markdown: markdown, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "full-fixture-highlight-off", markdown: markdown, syntaxHighlightingEnabled: false, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "dense-paragraph-blocks", markdown: denseParagraphs, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "code-fence-matrix-highlight-on", markdown: codeFenceMatrix, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "code-fence-matrix-highlight-off", markdown: codeFenceMatrix, syntaxHighlightingEnabled: false, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "table-matrix", markdown: tableMatrix, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
            ImportPhaseCaseSpec(name: "math-image-mermaid-range", markdown: attachmentRange, syntaxHighlightingEnabled: true, reuseReferenceDefinitions: true),
        ]
    }

    private func buildRepeatedShortInlineFragments() -> [String] {
        var fragments: [String] = []
        fragments.reserveCapacity(3_600)

        for i in 0..<1_200 {
            fragments.append("row\(i) **b\(i % 11)** `c\(i % 7)`")
            fragments.append("[label\(i)](https://example.com/\(i)?q=\(i % 13))")
            fragments.append("cell\(i) *em\(i % 9)* ~~s\(i % 5)~~ $x_{\(i % 6)}$")
        }

        return fragments
    }

    private func buildImageAttachmentBenchmarkMarkdown() -> String {
        let localImages = [
            "screenshots/01-default-sample.png",
            "screenshots/02-checklist-strikethrough-test.png",
            "screenshots/03-checklist-deep-nesting.png",
            "screenshots/04-mermaid-flowchart.png",
        ]
        var lines: [String] = ["# Image Attachment Benchmark", ""]
        for cycle in 1...8 {
            lines.append("## Image cycle \(cycle)")
            lines.append("")
            for (index, image) in localImages.enumerated() {
                lines.append("![Local image \(cycle)-\(index)](\(image))")
                lines.append("")
                lines.append("Paragraph after image \(cycle)-\(index) with **bold**, `inline code`, and a [link](https://example.com/\(cycle)/\(index)).")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func buildMathBlockBenchmarkMarkdown() -> String {
        let formulas = [
            "\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\epsilon_0}",
            "\\int_{0}^{1} x^2\\,dx = \\frac{1}{3}",
            "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            "\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}\\begin{bmatrix} x \\\\ y \\end{bmatrix} = \\begin{bmatrix} ax + by \\\\ cx + dy \\end{bmatrix}",
            "E = mc^2",
            "\\frac{\\partial u}{\\partial t} = \\alpha \\nabla^2 u",
        ]
        var lines: [String] = ["# Math Block Benchmark", ""]
        for cycle in 1...8 {
            lines.append("## Math cycle \(cycle)")
            lines.append("")
            for (index, formula) in formulas.enumerated() {
                lines.append("Paragraph with inline math $x_\(cycle)_\(index)^2$ before the block.")
                lines.append("")
                lines.append("$$")
                lines.append(formula)
                lines.append("$$")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func perfFixtureRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("test-fixtures", isDirectory: true)
    }

    private func extractSection(named heading: String, from markdown: String) throws -> String {
        let fullHeading = "## \(heading)"
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let startIndex = lines.firstIndex(of: fullHeading) else {
            XCTFail("Missing heading \(fullHeading) in benchmark fixture")
            throw NSError(domain: "NativeMarkdownCodecPerformanceTests", code: 1, userInfo: nil)
        }

        var endIndex = lines.count
        if let relativeEnd = lines[(startIndex + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) {
            endIndex = relativeEnd
        }
        return lines[startIndex..<endIndex].joined(separator: "\n")
    }

    private func extractSectionRange(startHeading: String, endHeading: String, from markdown: String) throws -> String {
        let start = "## \(startHeading)"
        let end = "## \(endHeading)"
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let startIndex = lines.firstIndex(of: start) else {
            XCTFail("Missing heading \(start) in benchmark fixture")
            throw NSError(domain: "NativeMarkdownCodecPerformanceTests", code: 2, userInfo: nil)
        }
        guard let endIndex = lines[(startIndex + 1)...].firstIndex(of: end) else {
            XCTFail("Missing heading \(end) in benchmark fixture")
            throw NSError(domain: "NativeMarkdownCodecPerformanceTests", code: 3, userInfo: nil)
        }
        return lines[startIndex..<endIndex].joined(separator: "\n")
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

    private func collectImageAttachments(in attributed: NSAttributedString) -> [MarkdownImageAttachment] {
        var out: [MarkdownImageAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            if let attachment = value as? MarkdownImageAttachment {
                out.append(attachment)
            }
        }
        return out
    }

    private func collectMathBlockAttachments(in attributed: NSAttributedString) -> [MarkdownMathBlockAttachment] {
        var out: [MarkdownMathBlockAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            if let attachment = value as? MarkdownMathBlockAttachment {
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

    private func aggregatePhaseSamples(_ samples: [String: [Double]], percentile p: Double) -> [String: Double] {
        samples.reduce(into: [String: Double]()) { partial, entry in
            partial[entry.key] = percentile(entry.value, p)
        }
    }

    private func aggregatePhaseMeans(_ samples: [String: [Double]]) -> [String: Double] {
        samples.reduce(into: [String: Double]()) { partial, entry in
            partial[entry.key] = entry.value.reduce(0, +) / Double(max(entry.value.count, 1))
        }
    }

    private func writeImportPhaseProfileReport(_ payload: ImportPhaseProfileReport) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let archiveDir = root
            .appendingPathComponent("benchmark-archive", isDirectory: true)
            .appendingPathComponent("import-phase-profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let jsonURL = archiveDir.appendingPathComponent("\(stamp)-import-phase-profile.json")
        let mdURL = archiveDir.appendingPathComponent("\(stamp)-import-phase-profile.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: jsonURL)

        var lines: [String] = []
        lines.append("# Import Phase Profile Benchmark")
        lines.append("")
        lines.append("- Generated: \(payload.generatedAt)")
        lines.append("- Fixture: \(payload.fixture) (\(payload.fixtureBytes) bytes)")
        lines.append("- Runs per case: \(payload.runsPerCase)")
        lines.append("")
        lines.append("| Case | Highlighting | Ref defs | UTF16 | p50 total (ms) | p95 total (ms) | Inline UTF16 total | Max inline UTF16 |")
        lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |")
        for result in payload.results {
            lines.append(
                "| \(result.name) | \(result.syntaxHighlightingEnabled ? "on" : "off") | \(result.referenceDefinitionsMode) | \(result.utf16Count) | " +
                "\(formatMs(result.totalP50Ms)) | \(formatMs(result.totalP95Ms)) | \(result.totalInlineUTF16) | \(result.maxInlineUTF16) |"
            )
        }
        lines.append("")

        for result in payload.results {
            lines.append("## \(result.name)")
            lines.append("")
            lines.append("- Syntax highlighting: \(result.syntaxHighlightingEnabled ? "enabled" : "disabled")")
            lines.append("- Reference definitions: \(result.referenceDefinitionsMode)")
            lines.append("- UTF16 count: \(result.utf16Count)")
            lines.append("- Line count: \(result.lineCount)")
            lines.append("- Total p50 / p95 / mean: \(formatMs(result.totalP50Ms)) / \(formatMs(result.totalP95Ms)) / \(formatMs(result.totalMeanMs)) ms")
            lines.append("")
            lines.append("| Phase | count | p50 (ms) | p95 (ms) | mean (ms) |")
            lines.append("| --- | ---: | ---: | ---: | ---: |")

            let orderedPhases = result.phaseP50Ms.keys.sorted {
                (result.phaseP50Ms[$0] ?? 0) > (result.phaseP50Ms[$1] ?? 0)
            }
            for phase in orderedPhases.prefix(8) {
                lines.append(
                    "| \(phase) | \(result.phaseCounts[phase] ?? 0) | " +
                    "\(formatMs(result.phaseP50Ms[phase] ?? 0)) | " +
                    "\(formatMs(result.phaseP95Ms[phase] ?? 0)) | " +
                    "\(formatMs(result.phaseMeanMs[phase] ?? 0)) |"
                )
            }
            lines.append("")
        }

        lines.append("## Notes")
        lines.append("")
        for note in payload.notes {
            lines.append("- \(note)")
        }
        lines.append("")

        try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
        add(XCTAttachment(string: lines.joined(separator: "\n")))
        print("Import phase profile report: \(mdURL.path)")
        print("Import phase profile json: \(jsonURL.path)")
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
