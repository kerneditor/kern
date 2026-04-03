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
        XCTAssertEqual(openReady.defaultRuns, 10)
        XCTAssertEqual(openReady.defaultWarmupRuns, 1)
        XCTAssertEqual(openReady.claimSafeMinimumRuns, 10)
        XCTAssertEqual(openReady.claimSafeMinimumWarmupRuns, 1)
        XCTAssertEqual(openReady.claimSafeMinimumInterEditorCooldownMs, 1500)
        XCTAssertEqual(openReady.requiredMetrics, ["open_latency_ms"])
        XCTAssertEqual(openReady.claimSafeRoster, ["Kern", "Zed"])

        let fullFidelity = SuiteDefinition.forID(.benchmarkFullFidelity)
        XCTAssertEqual(fullFidelity.defaultRuns, 10)
        XCTAssertEqual(fullFidelity.defaultWarmupRuns, 1)
        XCTAssertEqual(fullFidelity.claimSafeMinimumRuns, 10)
        XCTAssertEqual(fullFidelity.claimSafeMinimumWarmupRuns, 1)
        XCTAssertEqual(fullFidelity.claimSafeMinimumInterEditorCooldownMs, 1500)
        XCTAssertEqual(fullFidelity.requiredMetrics, ["full_fidelity_end_to_end_latency_ms"])
        XCTAssertEqual(fullFidelity.suiteKind, "cross_editor_full_fidelity")
        XCTAssertEqual(fullFidelity.claimSafeRoster, ["Kern", "Zed"])

        let wowInternal = SuiteDefinition.forID(.wowInternal)
        XCTAssertEqual(wowInternal.requiredRoster, ["Kern"])
        XCTAssertEqual(wowInternal.claimSafeRoster, ["Kern"])
        XCTAssertTrue(wowInternal.requiredMetrics.contains("wow_parse_latency_ms"))
        XCTAssertTrue(wowInternal.requiredMetrics.contains("wow_full_document_fidelity_ready_latency_ms"))
        XCTAssertTrue(wowInternal.optionalMetrics.contains("wow_save_serialize_latency_ms"))
    }
}
