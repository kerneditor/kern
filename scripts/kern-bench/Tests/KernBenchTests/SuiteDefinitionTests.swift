import XCTest
@testable import kern_bench

final class SuiteDefinitionTests: XCTestCase {
    func testSuiteParsing() {
        XCTAssertEqual(SuiteID.parse("benchmark"), .benchmark)
        XCTAssertEqual(SuiteID.parse("bench"), .benchmark)
        XCTAssertNil(SuiteID.parse("wow"))
        XCTAssertNil(SuiteID.parse("real_use"))
        XCTAssertNil(SuiteID.parse("real-use"))
        XCTAssertEqual(SuiteID.parse("benchmark_open_ready"), .benchmarkOpenReady)
        XCTAssertEqual(SuiteID.parse("open_ready"), .benchmarkOpenReady)
        XCTAssertEqual(SuiteID.parse("benchmark_full_fidelity"), .benchmarkFullFidelity)
        XCTAssertEqual(SuiteID.parse("full_fidelity"), .benchmarkFullFidelity)
        XCTAssertEqual(SuiteID.parse("full-fidelity"), .benchmarkFullFidelity)
        XCTAssertEqual(SuiteID.parse("wow_internal"), .wowInternal)
        XCTAssertEqual(SuiteID.parse("wow-internal"), .wowInternal)
        XCTAssertNil(SuiteID.parse("unknown"))
    }

    func testSuiteDefaults() {
        let benchmark = SuiteDefinition.forID(.benchmark)
        XCTAssertEqual(benchmark.defaultRuns, 30)
        XCTAssertEqual(benchmark.defaultWarmupRuns, 3)
        XCTAssertTrue(benchmark.requiredMetrics.contains("open_latency_ms"))
        XCTAssertTrue(benchmark.requiredMetrics.contains("quit_latency_ms"))

        let openReady = SuiteDefinition.forID(.benchmarkOpenReady)
        XCTAssertEqual(openReady.defaultRuns, 5)
        XCTAssertEqual(openReady.defaultWarmupRuns, 0)
        XCTAssertEqual(openReady.requiredMetrics, ["open_latency_ms"])

        let fullFidelity = SuiteDefinition.forID(.benchmarkFullFidelity)
        XCTAssertEqual(fullFidelity.defaultRuns, 5)
        XCTAssertEqual(fullFidelity.defaultWarmupRuns, 0)
        XCTAssertEqual(fullFidelity.requiredMetrics, ["full_fidelity_end_to_end_latency_ms"])
        XCTAssertEqual(fullFidelity.suiteKind, "cross_editor_full_fidelity")

        let wowInternal = SuiteDefinition.forID(.wowInternal)
        XCTAssertEqual(wowInternal.requiredRoster, ["Kern"])
        XCTAssertTrue(wowInternal.requiredMetrics.contains("wow_parse_latency_ms"))
        XCTAssertTrue(wowInternal.requiredMetrics.contains("wow_save_serialize_latency_ms"))
    }
}
