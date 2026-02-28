import Foundation
import XCTest
@testable import kern_bench

final class JSONReportSchemaTests: XCTestCase {
    func testRunResultDecodesPerRunExtraMetricsMap() throws {
        let json = """
        {
          "run_index": 1,
          "run_quality": "complete",
          "stage_timeout_count": 0,
          "stage_failure_count": 0,
          "metric_failure_reasons": {},
          "extra_metrics": {
            "wow_staged_promotion_compute_latency_ms_p95_ms": 43.21,
            "wow_staged_promotion_apply_latency_ms_max_ms": 78.9
          }
        }
        """

        let run = try JSONDecoder().decode(RunResult.self, from: Data(json.utf8))
        XCTAssertEqual(run.runIndex, 1)
        XCTAssertEqual(run.extraMetrics?["wow_staged_promotion_compute_latency_ms_p95_ms"], 43.21)
        XCTAssertEqual(run.extraMetrics?["wow_staged_promotion_apply_latency_ms_max_ms"], 78.9)
    }

    func testRunResultEncodingIncludesExtraMetricsWhenPresent() throws {
        let run = RunResult(
            runIndex: 2,
            coldStartLatencyMs: nil,
            warmStartLatencyMs: nil,
            openLatencyMs: 123.45,
            saveUiAckLatencyMs: nil,
            saveDurableLatencyMs: nil,
            quitLatencyMs: nil,
            typingLatencyMs: nil,
            findLatencyMs: nil,
            scrollSettleLatencyMs: nil,
            scrollEffectiveFPS: nil,
            scrollP95FrameTimeMs: nil,
            scrollP99FrameTimeMs: nil,
            scrollHitchMsPerS: nil,
            scrollJank33msCount: nil,
            scrollJank50msCount: nil,
            windowVisibleMs: 44.0,
            firstPaintMs: nil,
            renderStableMs: nil,
            memoryPhysMB: nil,
            memoryRssMB: nil,
            wowParseLatencyMs: nil,
            wowLayoutLatencyMs: nil,
            wowPaintReadyLatencyMs: nil,
            wowEditApplyLatencyMs: nil,
            wowSaveSerializeLatencyMs: nil,
            wowOpenReadyLatencyMs: nil,
            wowViewportSemanticReadyLatencyMs: nil,
            wowViewportFidelityReadyLatencyMs: nil,
            wowFullDocumentFidelityReadyLatencyMs: nil,
            fullFidelityEndToEndLatencyMs: nil,
            automationOverheadMs: nil,
            unattributedOpenBudgetMs: nil,
            timeToStableLayoutMs: nil,
            postReadyExportQuiescenceMs: nil,
            extraMetrics: [
                "wow_staged_promotion_compute_latency_ms_p99_ms": 55.5
            ],
            runQuality: "complete",
            stageTimeoutCount: 0,
            stageFailureCount: 0,
            metricFailureReasons: [:],
            scrollMetricMode: nil,
            thermalPct: nil,
            power: nil
        )

        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let extra = decoded?["extra_metrics"] as? [String: Any]
        XCTAssertEqual(extra?["wow_staged_promotion_compute_latency_ms_p99_ms"] as? Double, 55.5)
    }
}
