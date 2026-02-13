import AppKit
import Foundation
import XCTest
@testable import KernTextKit

/// Performance/scale tests for huge real-world Markdown files.
///
/// These run only when `KERN_ENABLE_PERF_TESTS=1` is set.
final class NativeEditorMegaStressPerformanceTests: XCTestCase {
    @MainActor
    func testRenderMegaStressFilePerformance() throws {
        guard ProcessInfo.processInfo.environment["KERN_ENABLE_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let md = try loadFixture(name: "mega-stress-test.md")

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = md
            vc.view.layoutSubtreeIfNeeded()
            vc.view.displayIfNeeded()
        }
    }

    @MainActor
    func testScrollMegaStressFilePerformance() throws {
        guard ProcessInfo.processInfo.environment["KERN_ENABLE_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let md = try loadFixture(name: "mega-stress-test.md")

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                _ = vc.view
                vc.stringValue = md
                vc.view.layoutSubtreeIfNeeded()

                guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
                    XCTFail("Missing NativeEditor.ScrollView")
                    return
                }

                // Simulate a few rapid scroll jumps.
                let clip = scrollView.contentView
                let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
                let steps: [CGFloat] = [0, maxY * 0.25, maxY * 0.5, maxY * 0.75, maxY, maxY * 0.1, maxY * 0.9, 0]
                for y in steps {
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    scrollView.reflectScrolledClipView(clip)
                    vc.view.layoutSubtreeIfNeeded()
                }
            }
        }
    }

    @MainActor
    func testIncrementalTypingPerformance_LiveAppend() throws {
        guard ProcessInfo.processInfo.environment["KERN_ENABLE_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let lineCount = Int(ProcessInfo.processInfo.environment["KERN_PERF_TYPING_LINES"] ?? "") ?? 2000

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                _ = vc.view
                vc.stringValue = ""
                vc.view.layoutSubtreeIfNeeded()

                guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                    XCTFail("Missing NativeEditor.TextView")
                    return
                }

                // Simulate a user typing many lines quickly. This is intentionally "live" (incremental),
                // not a single huge paste, to stress input rules and layout updates.
                for i in 0..<lineCount {
                    textView.insertText("Line \(i)\n", replacementRange: textView.selectedRange())
                }
                vc.view.layoutSubtreeIfNeeded()
            }
        }
    }

    // MARK: - Helpers

    private func loadFixture(name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) { return found }
        }
        return nil
    }
}
