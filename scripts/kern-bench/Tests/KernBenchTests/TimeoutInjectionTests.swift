import XCTest
@testable import kern_bench

final class TimeoutInjectionTests: XCTestCase {
    func testWithTimeoutReturnsValueBeforeDeadline() async throws {
        let value = try await withTimeout(seconds: 0.2) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    func testWithTimeoutThrowsStageTimeoutWhenOperationStalls() async {
        do {
            _ = try await withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return 1
            }
            XCTFail("Expected timeout")
        } catch let error as StageError {
            switch error {
            case let .timeout(reason):
                XCTAssertEqual(reason, "stage_timeout")
            default:
                XCTFail("Expected timeout StageError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNormalizeStageTimeoutReasonKeepsNonTimeoutStageUnchanged() {
        let stage = StageResult(valueMs: 12.0, failureReason: nil, timedOut: false)
        let normalized = normalizeStageTimeoutReason(
            stage,
            nowNs: 10,
            runDeadlineNs: 20,
            suiteDeadlineNs: 30,
            replacementReason: "run_timeout"
        )

        XCTAssertEqual(normalized.valueMs, 12.0)
        XCTAssertNil(normalized.failureReason)
        XCTAssertFalse(normalized.timedOut)
    }

    func testNormalizeStageTimeoutReasonAppliesRunDeadlineReason() {
        let stage = StageResult(valueMs: nil, failureReason: "open_timeout", timedOut: true)
        let normalized = normalizeStageTimeoutReason(
            stage,
            nowNs: 200,
            runDeadlineNs: 100,
            suiteDeadlineNs: 300,
            replacementReason: "run_timeout"
        )

        XCTAssertTrue(normalized.timedOut)
        XCTAssertEqual(normalized.failureReason, "run_timeout")
    }

    func testNormalizeStageTimeoutReasonAppliesSuiteDeadlineReason() {
        let stage = StageResult(valueMs: nil, failureReason: "open_timeout", timedOut: true)
        let normalized = normalizeStageTimeoutReason(
            stage,
            nowNs: 200,
            runDeadlineNs: 300,
            suiteDeadlineNs: 100,
            replacementReason: "suite_timeout"
        )

        XCTAssertTrue(normalized.timedOut)
        XCTAssertEqual(normalized.failureReason, "suite_timeout")
    }

    func testNormalizeStageTimeoutReasonKeepsOriginalBeforeDeadlineExhaustion() {
        let stage = StageResult(valueMs: nil, failureReason: "open_timeout", timedOut: true)
        let normalized = normalizeStageTimeoutReason(
            stage,
            nowNs: 50,
            runDeadlineNs: 100,
            suiteDeadlineNs: 200,
            replacementReason: "run_timeout"
        )

        XCTAssertTrue(normalized.timedOut)
        XCTAssertEqual(normalized.failureReason, "open_timeout")
    }
}
