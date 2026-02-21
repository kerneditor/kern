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

        let source = try loadPerfFixture(name: "stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_STRESS_RENDER_CHAR_LIMIT",
            defaultLimit: 24_000
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "mega-stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_MEGA_RENDER_CHAR_LIMIT",
            defaultLimit: 50_000
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "ultimate-stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_ULTIMATE_RENDER_CHAR_LIMIT",
            defaultLimit: 32_000
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "mega-stress-test.md")
        let md = boundedRenderFixture(
            source,
            envLimitKey: "KERN_PERF_MEGA_SCROLL_CHAR_LIMIT",
            defaultLimit: 70_000
        )

        measure(metrics: [XCTClockMetric()], options: defaultPerformanceOptions()) {
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

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "ultimate-stress-test.md")
        XCTAssertGreaterThan(source.count, 15_000)
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_ULTIMATE_CHAR_LIMIT", defaultLimit: 15_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "mega-stress-test.md")
        XCTAssertGreaterThan(source.count, 100_000)
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_MEGA_CHAR_LIMIT", defaultLimit: 30_000)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "ultimate-stress-test.md")
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_ULTIMATE_INTERLEAVED_CHAR_LIMIT", defaultLimit: 12_000)
        let interval = max(31, TestRuntimeConfig.int("KERN_PERF_ACTION_INTERVAL", default: 151) ?? 151)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

        let source = try loadPerfFixture(name: "mega-stress-test.md")
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_MEGA_INTERLEAVED_CHAR_LIMIT", defaultLimit: 20_000)
        let interval = max(31, TestRuntimeConfig.int("KERN_PERF_ACTION_INTERVAL", default: 151) ?? 151)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
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

    @MainActor
    func testEditInMiddleOfLargeDocumentPerformance() throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run performance tests")
        }

        let source = try loadPerfFixture(name: "mega-stress-test.md")
        let md = boundedFixture(source, envLimitKey: "KERN_PERF_EDIT_MIDDLE_CHAR_LIMIT", defaultLimit: 50_000)

        // Pre-create the VC and load content once outside measure.
        let vc = NativeEditorViewController()
        vc.disablesDebouncedExportsForTesting = true
        _ = vc.view
        vc.stringValue = md
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        textView.allowsUndo = false
        textView.undoManager?.removeAllActions()

        let midPoint = textView.string.count / 2

        // Content to insert and then delete — exercises headings, lists, inline formatting.
        let editLines = [
            "## Inserted Heading During Edit\n",
            "- [ ] New task item inserted mid-document\n",
            "- [x] Completed task with **bold** and *italic*\n",
            "1. Ordered item with `inline code`\n",
            "   - Nested bullet with [a link](https://example.com)\n",
            "### Another heading level 3\n",
            "> Blockquote inserted in the middle\n",
            "Paragraph with ~~strikethrough~~ and $E=mc^2$ math\n",
            "- Plain bullet item\n",
            "  - Nested level 1\n",
            "    - Nested level 2\n",
            "```swift\nlet x = 42\n```\n",
            "| Col A | Col B |\n| --- | --- |\n| data | data |\n",
            "Another paragraph with **bold *nested italic* bold**\n",
            "---\n",
            "#### H4 with `code` and **bold**\n",
            "- [ ] Final unchecked task\n",
            "- [x] Final checked task\n",
            "*Italic paragraph* followed by ~~strike~~ text\n",
            "Last inserted line before cleanup\n",
        ]
        let editBlock = editLines.joined()
        let editBlockLength = editBlock.count

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: defaultPerformanceOptions()) {
            // Position caret at ~50% of text length.
            let caretPos = min(midPoint, textView.string.count)
            textView.setSelectedRange(NSRange(location: caretPos, length: 0))

            // Insert mixed content.
            textView.insertText(editBlock, replacementRange: textView.selectedRange())
            vc.view.layoutSubtreeIfNeeded()

            // Delete what we just inserted (backspace char by char would be too slow — select and delete).
            let deleteStart = caretPos
            let deleteEnd = min(deleteStart + editBlockLength, textView.string.count)
            textView.setSelectedRange(NSRange(location: deleteStart, length: deleteEnd - deleteStart))
            textView.delete(nil)
            vc.view.layoutSubtreeIfNeeded()
        }
    }
}
