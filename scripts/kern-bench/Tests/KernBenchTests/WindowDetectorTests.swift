import CoreGraphics
import XCTest
@testable import kern_bench

final class WindowDetectorTests: XCTestCase {
    func testWindowCandidateRejectsTinyHelperWindow() {
        let info = makeWindowInfo(pid: 99, windowID: 7, width: 80, height: 60, layer: 0, name: "helper")
        XCTAssertNil(windowCandidate(from: info, ownerPID: 99))
    }

    func testWindowCandidateRejectsNonZeroLayer() {
        let info = makeWindowInfo(pid: 99, windowID: 7, width: 600, height: 400, layer: 3, name: "doc")
        XCTAssertNil(windowCandidate(from: info, ownerPID: 99))
    }

    func testSelectWindowCandidatePrefersExpectedFileNameMatch() {
        let a = WindowCandidate(windowID: 1, bounds: CGRect(x: 0, y: 0, width: 900, height: 700), name: "notes.md — Zed")
        let b = WindowCandidate(windowID: 2, bounds: CGRect(x: 0, y: 0, width: 1200, height: 900), name: "Welcome")

        let selected = selectWindowCandidate([a, b], expectedName: "notes.md")
        XCTAssertEqual(selected?.windowID, 1)
    }

    func testSelectWindowCandidateFallsBackToLargestArea() {
        let small = WindowCandidate(windowID: 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 400), name: "A")
        let large = WindowCandidate(windowID: 2, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), name: "B")

        let selected = selectWindowCandidate([small, large], expectedName: nil)
        XCTAssertEqual(selected?.windowID, 2)
    }

    private func makeWindowInfo(
        pid: Int32,
        windowID: UInt32,
        width: CGFloat,
        height: CGFloat,
        layer: Int,
        name: String
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowNumber as String: windowID,
            kCGWindowLayer as String: layer,
            kCGWindowName as String: name,
            kCGWindowBounds as String: [
                "X": 0,
                "Y": 0,
                "Width": width,
                "Height": height,
            ],
        ]
    }
}
