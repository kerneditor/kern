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

        let source = try loadPerfFixture(name: "native-editor-benchmark.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_BENCHMARK_RENDER_CHAR_LIMIT",
            defaultLimit: 24_000
        )

        // Measure end-to-end render in TextKit (import + view layout).
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            let vc = NativeEditorViewController()
            vc.disablesDebouncedExportsForTesting = true
            _ = vc.view
            vc.stringValue = md
            vc.view.layoutSubtreeIfNeeded()
        }
    }
}
