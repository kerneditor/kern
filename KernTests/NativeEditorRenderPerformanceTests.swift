import AppKit
import Foundation
import XCTest
@testable import KernTextKit

final class NativeEditorRenderPerformanceTests: XCTestCase {
    @MainActor
    func testRenderBenchmarkFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root

        let url = root.appendingPathComponent("test-fixtures/native-editor-benchmark.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_BENCHMARK_RENDER_CHAR_LIMIT",
            defaultLimit: 24_000
        )

        // Measure end-to-end render in TextKit (import + view layout).
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            let vc = NativeEditorViewController()
            vc.disablesDebouncedExportsForTesting = true
            _ = vc.view
            vc.stringValue = md
            vc.view.layoutSubtreeIfNeeded()
        }
    }

    private func performanceOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions.default
        let iterations = max(1, TestRuntimeConfig.int("KERN_PERF_ITERATIONS", default: 3) ?? 3)
        options.iterationCount = iterations
        return options
    }

    private func boundedRenderFixture(_ source: String, envLimitKey: String, defaultLimit: Int) -> String {
        if TestRuntimeConfig.bool("KERN_PERF_RENDER_FULL") {
            return source
        }
        let limit = max(1, TestRuntimeConfig.int(envLimitKey, default: defaultLimit) ?? defaultLimit)
        guard source.count > limit else { return source }
        let end = source.index(source.startIndex, offsetBy: limit)
        var bounded = String(source[..<end])
        if let lastNewline = bounded.lastIndex(of: "\n") {
            bounded = String(bounded[...lastNewline])
        }
        return bounded
    }
}
