import Foundation
import XCTest
@testable import KernTextKit

@MainActor
final class WowInternalMetricsRecorderTests: XCTestCase {
    private struct Payload: Decodable {
        let metrics: [String: Double]
    }

    func testRecordAuxSamplePublishesPercentilesAfterDeferredFlush() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wow-recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("wow-metrics.json")
        let previousPath = getenv("KERN_WOW_INTERNAL_METRICS_PATH").map { String(cString: $0) }
        setenv("KERN_WOW_INTERNAL_METRICS_PATH", outputURL.path, 1)
        defer {
            if let previousPath {
                setenv("KERN_WOW_INTERNAL_METRICS_PATH", previousPath, 1)
            } else {
                unsetenv("KERN_WOW_INTERNAL_METRICS_PATH")
            }
        }

        let recorder = WowInternalMetricsRecorder.shared
        recorder.beginRun()
        recorder.recordAuxSample("wow_test_latency_ms", sample: 10)
        recorder.recordAuxSample("wow_test_latency_ms", sample: 20)
        recorder.recordAuxSample("wow_test_latency_ms", sample: 30)

        // Allow coalesced persist to run and serialize quantiles.
        let expectation = expectation(description: "recorder flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let data = try Data(contentsOf: outputURL)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(payload.metrics["wow_test_latency_ms_p50_ms"], 20)
        XCTAssertEqual(payload.metrics["wow_test_latency_ms_p95_ms"], 30)
        XCTAssertEqual(payload.metrics["wow_test_latency_ms_p99_ms"], 30)
        XCTAssertEqual(payload.metrics["wow_test_latency_ms_max_ms"], 30)
    }
}
