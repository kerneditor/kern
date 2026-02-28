import Foundation
import XCTest
@testable import kern_bench

final class WowMetricsSelectionTests: XCTestCase {
    func testSelectFinalWowMetricsPayloadPrefersFreshMetricsFile() async throws {
        let tempURL = try makeTemporaryMetricsURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let preloaded = WowInternalMetricsPayload(
            version: 1,
            metrics: ["wow_full_document_fidelity_ready_latency_ms": 7_083.63],
            failureReasons: [:]
        )
        let fresh = WowInternalMetricsPayload(
            version: 1,
            metrics: ["wow_full_document_fidelity_ready_latency_ms": 3_884.45],
            failureReasons: [:]
        )
        try write(payload: fresh, to: tempURL)

        let selected = await selectFinalWowMetricsPayload(
            preloaded: preloaded,
            path: tempURL.path,
            timeout: 0.2,
            requireAllMetrics: false
        )

        XCTAssertEqual(
            selected?.metrics["wow_full_document_fidelity_ready_latency_ms"],
            3_884.45
        )
    }

    func testSelectFinalWowMetricsPayloadFallsBackToPreloadedWhenFileUnavailable() async {
        let preloaded = WowInternalMetricsPayload(
            version: 1,
            metrics: ["wow_full_document_fidelity_ready_latency_ms": 7_083.63],
            failureReasons: [:]
        )

        let selected = await selectFinalWowMetricsPayload(
            preloaded: preloaded,
            path: "/tmp/non-existent-wow-metrics-\(UUID().uuidString).json",
            timeout: 0.05,
            requireAllMetrics: false
        )

        XCTAssertEqual(
            selected?.metrics["wow_full_document_fidelity_ready_latency_ms"],
            7_083.63
        )
    }

    func testSelectFinalWowMetricsPayloadAllowsSubsetRequiredKeys() async throws {
        let tempURL = try makeTemporaryMetricsURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let fresh = WowInternalMetricsPayload(
            version: 1,
            metrics: ["wow_full_document_fidelity_ready_latency_ms": 3_884.45],
            failureReasons: [:]
        )
        try write(payload: fresh, to: tempURL)

        setenv("KERN_WOW_METRICS_SETTLE_MS", "0", 1)
        defer { unsetenv("KERN_WOW_METRICS_SETTLE_MS") }

        let selected = await selectFinalWowMetricsPayload(
            preloaded: nil,
            path: tempURL.path,
            timeout: 0.2,
            requireAllMetrics: false,
            requiredMetricKeys: ["wow_full_document_fidelity_ready_latency_ms"]
        )

        XCTAssertEqual(
            selected?.metrics["wow_full_document_fidelity_ready_latency_ms"],
            3_884.45
        )
    }

    func testSelectFinalWowMetricsPayloadTreatsFailureReasonAsCompletion() async throws {
        let tempURL = try makeTemporaryMetricsURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let fresh = WowInternalMetricsPayload(
            version: 1,
            metrics: [:],
            failureReasons: ["wow_full_document_fidelity_ready_latency_ms": "stage_timeout"]
        )
        try write(payload: fresh, to: tempURL)

        setenv("KERN_WOW_METRICS_SETTLE_MS", "0", 1)
        defer { unsetenv("KERN_WOW_METRICS_SETTLE_MS") }

        let selected = await selectFinalWowMetricsPayload(
            preloaded: nil,
            path: tempURL.path,
            timeout: 0.2,
            requireAllMetrics: false,
            requiredMetricKeys: ["wow_full_document_fidelity_ready_latency_ms"]
        )

        XCTAssertEqual(
            selected?.failureReasons["wow_full_document_fidelity_ready_latency_ms"],
            "stage_timeout"
        )
    }

    private func makeTemporaryMetricsURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kern-bench-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wow-metrics.json")
    }

    private func write(payload: WowInternalMetricsPayload, to url: URL) throws {
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
