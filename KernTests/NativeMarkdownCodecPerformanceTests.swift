import Foundation
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecPerformanceTests: XCTestCase {
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
}
