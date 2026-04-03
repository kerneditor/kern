import Foundation
import XCTest
@testable import kern_bench

final class ZedBenchHookTests: XCTestCase {
    func testLoadZedBenchReadyPayloadDecodes() throws {
        let tmp = try makeTempFilePath(name: "zed-hook-decode.json")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let payload = ZedBenchReadyPayload(
            event: "bench_ready",
            target: "/tmp/doc.md",
            mode: "first_editable",
            timestampMonotonicNs: 123,
            pid: 42,
            windowID: 7
        )
        try writePayload(payload, to: tmp)

        let loaded = loadZedBenchReadyPayload(from: tmp)
        XCTAssertEqual(loaded?.event, "bench_ready")
        XCTAssertEqual(loaded?.target, "/tmp/doc.md")
        XCTAssertEqual(loaded?.mode, "first_editable")
        XCTAssertEqual(loaded?.timestampMonotonicNs, 123)
    }

    func testValidateRejectsModeMismatch() {
        let payload = ZedBenchReadyPayload(
            event: "bench_ready",
            target: "/tmp/doc.md",
            mode: "styled_stable",
            timestampMonotonicNs: 123,
            pid: 42,
            windowID: nil
        )

        let reason = validateZedBenchReadyPayload(
            payload,
            expectedTargetPath: "/tmp/doc.md",
            expectedMode: "first_editable",
            expectedPID: 42
        )
        XCTAssertEqual(reason, "zed_bench_hook_mode_mismatch")
    }

    func testValidateRejectsTargetMismatch() {
        let payload = ZedBenchReadyPayload(
            event: "bench_ready",
            target: "/tmp/other.md",
            mode: "first_editable",
            timestampMonotonicNs: 123,
            pid: 42,
            windowID: nil
        )

        let reason = validateZedBenchReadyPayload(
            payload,
            expectedTargetPath: "/tmp/doc.md",
            expectedMode: "first_editable",
            expectedPID: 42
        )
        XCTAssertEqual(reason, "zed_bench_hook_target_mismatch")
    }

    func testValidateAllowsPidMismatchWhenTargetAndModeMatch() {
        let payload = ZedBenchReadyPayload(
            event: "bench_ready",
            target: "/tmp/doc.md",
            mode: "first_editable",
            timestampMonotonicNs: 123,
            pid: 99,
            windowID: nil
        )

        let reason = validateZedBenchReadyPayload(
            payload,
            expectedTargetPath: "/tmp/doc.md",
            expectedMode: "first_editable",
            expectedPID: 42
        )
        XCTAssertNil(reason)
    }

    func testWaitForZedBenchReadyReturnsValidationFailureAfterTimeout() async throws {
        let tmp = try makeTempFilePath(name: "zed-hook-timeout.json")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let payload = ZedBenchReadyPayload(
            event: "bench_ready",
            target: "/tmp/not-expected.md",
            mode: "first_editable",
            timestampMonotonicNs: 123,
            pid: 42,
            windowID: nil
        )
        try writePayload(payload, to: tmp)

        let result = await waitForZedBenchReady(
            path: tmp,
            timeout: 0.05,
            expectedTargetPath: "/tmp/doc.md",
            expectedMode: "first_editable",
            expectedPID: 42
        )

        XCTAssertNil(result.payload)
        XCTAssertEqual(result.failureReason, "zed_bench_hook_target_mismatch")
    }

    func testWaitForZedBenchReadyReturnsPayloadWhenValid() async throws {
        let tmp = try makeTempFilePath(name: "zed-hook-valid.json")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let expectedPath = "/tmp/doc.md"
        let payload = ZedBenchReadyPayload(
            event: "bench_ready",
            target: expectedPath,
            mode: "first_editable",
            timestampMonotonicNs: 999,
            pid: 42,
            windowID: 3
        )
        try writePayload(payload, to: tmp)

        let result = await waitForZedBenchReady(
            path: tmp,
            timeout: 0.05,
            expectedTargetPath: expectedPath,
            expectedMode: "first_editable",
            expectedPID: 42
        )

        XCTAssertNotNil(result.payload)
        XCTAssertNil(result.failureReason)
    }

    private func makeTempFilePath(name: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name).path
    }

    private func writePayload(_ payload: ZedBenchReadyPayload, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
