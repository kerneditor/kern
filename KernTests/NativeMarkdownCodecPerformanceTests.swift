import Foundation
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecPerformanceTests: XCTestCase {
    @MainActor
    func testImportExportBenchmarkFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root

        let url = root.appendingPathComponent("test-fixtures/native-editor-benchmark.md")
        let md = try String(contentsOf: url, encoding: .utf8)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let attr = NativeMarkdownCodec.importMarkdown(md)
            _ = NativeMarkdownCodec.exportMarkdown(attr)
        }
    }
}
