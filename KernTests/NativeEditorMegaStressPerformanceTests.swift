import AppKit
import Foundation
import XCTest
@testable import KernTextKit

/// Performance/scale tests for huge real-world Markdown files.
///
/// These run only when `KERN_ENABLE_PERF_TESTS=1` is set.
final class NativeEditorMegaStressPerformanceTests: XCTestCase {
    @MainActor
    func testRenderStressFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_STRESS_RENDER_CHAR_LIMIT",
            defaultLimit: 24_000
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            let vc = NativeEditorViewController()
            vc.disablesDebouncedExportsForTesting = true
            _ = vc.view
            vc.stringValue = md
            vc.view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    func testRenderMegaStressFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "mega-stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_MEGA_RENDER_CHAR_LIMIT",
            defaultLimit: 50_000
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            let vc = NativeEditorViewController()
            vc.disablesDebouncedExportsForTesting = true
            _ = vc.view
            vc.stringValue = md
            vc.view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    func testRenderUltimateStressFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }
        guard TestRuntimeConfig.bool("KERN_PERF_ENABLE_ULTIMATE_RENDER") || TestRuntimeConfig.bool("KERN_PERF_RENDER_FULL") else {
            throw XCTSkip("Set KERN_PERF_ENABLE_ULTIMATE_RENDER=1 (or KERN_PERF_RENDER_FULL=1) to run heavy ultimate render perf")
        }

        let source = try loadFixture(name: "ultimate-stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_ULTIMATE_RENDER_CHAR_LIMIT",
            defaultLimit: 32_000
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            let vc = NativeEditorViewController()
            vc.disablesDebouncedExportsForTesting = true
            _ = vc.view
            vc.stringValue = md
            vc.view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    func testScrollMegaStressFilePerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "mega-stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_MEGA_SCROLL_CHAR_LIMIT",
            defaultLimit: 70_000
        )

        measure(metrics: [XCTClockMetric()], options: performanceOptions()) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                vc.disablesDebouncedExportsForTesting = true
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
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let lineCount = TestRuntimeConfig.int("KERN_PERF_TYPING_LINES", default: 2000) ?? 2000

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                vc.disablesDebouncedExportsForTesting = true
                _ = vc.view
                vc.stringValue = ""
                vc.view.layoutSubtreeIfNeeded()

                guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                    XCTFail("Missing NativeEditor.TextView")
                    return
                }
                textView.allowsUndo = false
                textView.undoManager?.removeAllActions()

                // Simulate a user typing many lines quickly. This is intentionally "live" (incremental),
                // not a single huge paste, to stress input rules and layout updates.
                for i in 0..<lineCount {
                    textView.insertText("Line \(i)\n", replacementRange: textView.selectedRange())
                }
                vc.view.layoutSubtreeIfNeeded()
            }
        }
    }

    @MainActor
    func testTypingUltimateStressCharacterByCharacterPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "ultimate-stress-test.md")
        XCTAssertGreaterThan(source.count, 15_000)
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_ULTIMATE_CHAR_LIMIT", defaultLimit: 15_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                vc.disablesDebouncedExportsForTesting = true
                _ = vc.view
                vc.stringValue = ""
                vc.view.layoutSubtreeIfNeeded()

                guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                    XCTFail("Missing NativeEditor.TextView")
                    return
                }
                textView.allowsUndo = false
                textView.undoManager?.removeAllActions()

                for ch in md {
                    textView.insertText(String(ch), replacementRange: textView.selectedRange())
                }
                vc.view.layoutSubtreeIfNeeded()
            }
        }
    }

    @MainActor
    func testTypingMegaStressCharacterByCharacterPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "mega-stress-test.md")
        XCTAssertGreaterThan(source.count, 100_000)
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_MEGA_CHAR_LIMIT", defaultLimit: 30_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                vc.disablesDebouncedExportsForTesting = true
                _ = vc.view
                vc.stringValue = ""
                vc.view.layoutSubtreeIfNeeded()

                guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                    XCTFail("Missing NativeEditor.TextView")
                    return
                }
                textView.allowsUndo = false
                textView.undoManager?.removeAllActions()

                for ch in md {
                    textView.insertText(String(ch), replacementRange: textView.selectedRange())
                }
                vc.view.layoutSubtreeIfNeeded()
            }
        }
    }

    @MainActor
    func testInterleavedActionBurstOnUltimateStressPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "ultimate-stress-test.md")
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_ULTIMATE_INTERLEAVED_CHAR_LIMIT", defaultLimit: 12_000)
        let interval = max(31, TestRuntimeConfig.int("KERN_PERF_ACTION_INTERVAL", default: 151) ?? 151)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                vc.disablesDebouncedExportsForTesting = true
                _ = vc.view
                vc.stringValue = ""
                vc.view.layoutSubtreeIfNeeded()

                guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                    XCTFail("Missing NativeEditor.TextView")
                    return
                }
                textView.allowsUndo = false
                textView.undoManager?.removeAllActions()

                var typed = 0
                for ch in md {
                    textView.insertText(String(ch), replacementRange: textView.selectedRange())
                    typed += 1

                    // Reversible action bursts to exercise caret movement and edit routing
                    // while keeping final text mostly stable.
                    if typed % interval == 0 {
                        if textView.selectedRange().location > 0 {
                            textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1, length: 0))
                            textView.setSelectedRange(NSRange(location: textView.selectedRange().location + 1, length: 0))
                        }
                        textView.insertText("x", replacementRange: textView.selectedRange())
                        textView.deleteBackward(nil)
                        textView.insertText("\n", replacementRange: textView.selectedRange())
                        textView.deleteBackward(nil)
                    }
                }

                // Export in the perf test so we capture end-to-end typing -> markdown serialization cost.
                _ = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                vc.view.layoutSubtreeIfNeeded()
            }
        }
    }

    @MainActor
    func testInterleavedActionBurstOnMegaStressPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadFixture(name: "mega-stress-test.md")
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_MEGA_INTERLEAVED_CHAR_LIMIT", defaultLimit: 20_000)
        let interval = max(31, TestRuntimeConfig.int("KERN_PERF_ACTION_INTERVAL", default: 151) ?? 151)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: performanceOptions()) {
            autoreleasepool {
                let vc = NativeEditorViewController()
                vc.disablesDebouncedExportsForTesting = true
                _ = vc.view
                vc.stringValue = ""
                vc.view.layoutSubtreeIfNeeded()

                guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                    XCTFail("Missing NativeEditor.TextView")
                    return
                }
                textView.allowsUndo = false
                textView.undoManager?.removeAllActions()

                var typed = 0
                for ch in md {
                    textView.insertText(String(ch), replacementRange: textView.selectedRange())
                    typed += 1

                    if typed % interval == 0 {
                        if textView.selectedRange().location > 0 {
                            textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1, length: 0))
                            textView.setSelectedRange(NSRange(location: textView.selectedRange().location + 1, length: 0))
                        }
                        textView.insertText("x", replacementRange: textView.selectedRange())
                        textView.deleteBackward(nil)
                        textView.insertText("\n", replacementRange: textView.selectedRange())
                        textView.deleteBackward(nil)
                    }
                }

                _ = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
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

    private func performanceOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions.default
        let iterations = max(1, TestRuntimeConfig.int("KERN_PERF_ITERATIONS", default: 3) ?? 3)
        options.iterationCount = iterations
        return options
    }

    private func boundedRenderFixture(_ source: String, envLimitKey: String, defaultLimit: Int) -> String {
        if TestRuntimeConfig.bool("KERN_PERF_RENDER_FULL") {
            return source
        }
        return boundedFixture(source, envLimitKey: envLimitKey, defaultLimit: defaultLimit)
    }

    private func boundedFixture(_ source: String, envLimitKey: String, defaultLimit: Int) -> String {
        let limit = max(1, TestRuntimeConfig.int(envLimitKey, default: defaultLimit) ?? defaultLimit)
        guard source.count > limit else { return source }
        let end = source.index(source.startIndex, offsetBy: limit)
        var bounded = String(source[..<end])
        if let lastNewline = bounded.lastIndex(of: "\n") {
            bounded = String(bounded[...lastNewline])
        }
        return bounded
    }
}
