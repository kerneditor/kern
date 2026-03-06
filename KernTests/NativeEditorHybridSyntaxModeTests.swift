import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorHybridSyntaxModeTests: XCTestCase {
    private struct HybridSpanCase {
        let id: String
        let markdown: String
        let visibleToken: String
        let expectedExpandedSource: String
        let expectedExportSource: (String) -> String
    }

    @MainActor
    func testHybridModeExpandsInlineLinkNearCaretAndCollapsesWhenCaretLeaves() {
        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "[docs](https://example.com/docs)\n\ntail"

            let textView = vc.textViewForTesting()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

            XCTAssertFalse(textView.string.contains("[docs]("), "Hybrid mode should start in WYSIWYG form")

            let visible = textView.string as NSString
            let docs = visible.range(of: "docs")
            XCTAssertNotEqual(docs.location, NSNotFound)
            guard docs.location != NSNotFound else { return }

            textView.setSelectedRange(NSRange(location: docs.location + 1, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertTrue(
                textView.string.contains("[docs](https://example.com/docs)"),
                "Hybrid mode should expand inline link syntax when caret enters link label"
            )

            let expanded = textView.string as NSString
            let tail = expanded.range(of: "tail")
            XCTAssertNotEqual(tail.location, NSNotFound)
            guard tail.location != NSNotFound else { return }

            textView.setSelectedRange(NSRange(location: tail.location, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

            XCTAssertFalse(
                textView.string.contains("[docs]("),
                "Hybrid mode should collapse back to WYSIWYG when caret leaves expanded span"
            )

            let collapsed = textView.string as NSString
            let collapsedDocs = collapsed.range(of: "docs")
            XCTAssertNotEqual(collapsedDocs.location, NSNotFound)
            if collapsedDocs.location != NSNotFound {
                let link = textView.textStorage?.attribute(.link, at: collapsedDocs.location, effectiveRange: nil)
                XCTAssertNotNil(link, "Collapsed hybrid state should restore link semantics")
            }
        }
    }

    @MainActor
    func testHybridModeEditsInsideExpandedInlineLinkRoundTripToWysiwyg() {
        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "[docs](https://example.com/docs)\n\ntail"

            let textView = vc.textViewForTesting()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

            let visible = textView.string as NSString
            let docs = visible.range(of: "docs")
            XCTAssertNotEqual(docs.location, NSNotFound)
            guard docs.location != NSNotFound else { return }

            textView.setSelectedRange(NSRange(location: docs.location + 1, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertTrue(textView.string.contains("[docs](https://example.com/docs)"))

            let expanded = textView.string as NSString
            let expandedDocs = expanded.range(of: "docs")
            XCTAssertNotEqual(expandedDocs.location, NSNotFound)
            guard expandedDocs.location != NSNotFound else { return }

            textView.insertText("", replacementRange: expandedDocs)
            textView.insertText("guide", replacementRange: textView.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

            let tail = (textView.string as NSString).range(of: "tail")
            XCTAssertNotEqual(tail.location, NSNotFound)
            guard tail.location != NSNotFound else { return }
            textView.setSelectedRange(NSRange(location: tail.location, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))

            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(
                exported.contains("[guide](https://example.com/docs)"),
                "Edited inline-link label in hybrid mode should round-trip through export"
            )
            XCTAssertFalse(textView.string.contains("[guide]("), "After leaving caret context, hybrid should collapse to WYSIWYG")
            XCTAssertTrue(textView.string.contains("guide"), "Updated label should remain visible after collapse")
        }
    }

    @MainActor
    func testHybridModeExpandsAndCollapsesInlineSpanSyntaxNearCaret() {
        let cases: [HybridSpanCase] = [
            .init(
                id: "emphasis",
                markdown: "prefix *italic* tail",
                visibleToken: "italic",
                expectedExpandedSource: "*italic*",
                expectedExportSource: { "*\($0)*" }
            ),
            .init(
                id: "strong",
                markdown: "prefix **bold** tail",
                visibleToken: "bold",
                expectedExpandedSource: "**bold**",
                expectedExportSource: { "**\($0)**" }
            ),
            .init(
                id: "strong-emphasis",
                markdown: "prefix ***both*** tail",
                visibleToken: "both",
                expectedExpandedSource: "***both***",
                expectedExportSource: { "***\($0)***" }
            ),
            .init(
                id: "inline-code",
                markdown: "prefix `codeValue` tail",
                visibleToken: "codeValue",
                expectedExpandedSource: "`codeValue`",
                expectedExportSource: { "`\($0)`" }
            ),
            .init(
                id: "strikethrough",
                markdown: "prefix ~~gone~~ tail",
                visibleToken: "gone",
                expectedExpandedSource: "~~gone~~",
                expectedExportSource: { "~~\($0)~~" }
            ),
        ]

        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
        ]) {
            for testCase in cases {
                let vc = NativeEditorViewController()
                _ = vc.view
                vc.stringValue = "\(testCase.markdown)\n\nafter"

                let textView = vc.textViewForTesting()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

                XCTAssertFalse(
                    textView.string.contains(testCase.expectedExpandedSource),
                    "[\(testCase.id)] should start in collapsed WYSIWYG form"
                )

                let visible = textView.string as NSString
                let tokenRange = visible.range(of: testCase.visibleToken)
                XCTAssertNotEqual(tokenRange.location, NSNotFound, "[\(testCase.id)] visible token missing before expansion")
                guard tokenRange.location != NSNotFound else { continue }

                textView.setSelectedRange(NSRange(location: tokenRange.location + 1, length: 0))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

                XCTAssertTrue(
                    textView.string.contains(testCase.expectedExpandedSource),
                    "[\(testCase.id)] should expose markdown syntax near caret"
                )

                let afterRange = (textView.string as NSString).range(of: "after")
                XCTAssertNotEqual(afterRange.location, NSNotFound, "[\(testCase.id)] anchor token missing")
                guard afterRange.location != NSNotFound else { continue }

                textView.setSelectedRange(NSRange(location: afterRange.location, length: 0))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))

                XCTAssertFalse(
                    textView.string.contains(testCase.expectedExpandedSource),
                    "[\(testCase.id)] should collapse syntax after caret leaves span"
                )
            }
        }
    }

    @MainActor
    func testHybridModeEditsExpandedInlineSpansRoundTripViaExport() {
        let cases: [HybridSpanCase] = [
            .init(
                id: "emphasis",
                markdown: "prefix *italic* tail",
                visibleToken: "italic",
                expectedExpandedSource: "*italic*",
                expectedExportSource: { "*\($0)*" }
            ),
            .init(
                id: "strong",
                markdown: "prefix **bold** tail",
                visibleToken: "bold",
                expectedExpandedSource: "**bold**",
                expectedExportSource: { "**\($0)**" }
            ),
            .init(
                id: "inline-code",
                markdown: "prefix `codeValue` tail",
                visibleToken: "codeValue",
                expectedExpandedSource: "`codeValue`",
                expectedExportSource: { "`\($0)`" }
            ),
            .init(
                id: "strikethrough",
                markdown: "prefix ~~gone~~ tail",
                visibleToken: "gone",
                expectedExpandedSource: "~~gone~~",
                expectedExportSource: { "~~\($0)~~" }
            ),
        ]

        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
        ]) {
            for testCase in cases {
                let vc = NativeEditorViewController()
                _ = vc.view
                vc.stringValue = "\(testCase.markdown)\n\nafter"

                let textView = vc.textViewForTesting()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

                let visible = textView.string as NSString
                let tokenRange = visible.range(of: testCase.visibleToken)
                XCTAssertNotEqual(tokenRange.location, NSNotFound, "[\(testCase.id)] visible token missing before edit")
                guard tokenRange.location != NSNotFound else { continue }

                textView.setSelectedRange(NSRange(location: tokenRange.location + 1, length: 0))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                XCTAssertTrue(textView.string.contains(testCase.expectedExpandedSource), "[\(testCase.id)] expected expanded source before edit")

                let replacement = "edited-\(testCase.id)"
                let expandedRange = (textView.string as NSString).range(of: testCase.visibleToken)
                XCTAssertNotEqual(expandedRange.location, NSNotFound, "[\(testCase.id)] token missing after expansion")
                guard expandedRange.location != NSNotFound else { continue }

                textView.insertText("", replacementRange: expandedRange)
                textView.insertText(replacement, replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

                let afterRange = (textView.string as NSString).range(of: "after")
                XCTAssertNotEqual(afterRange.location, NSNotFound, "[\(testCase.id)] anchor token missing after edit")
                guard afterRange.location != NSNotFound else { continue }
                textView.setSelectedRange(NSRange(location: afterRange.location, length: 0))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(
                    exported.contains(testCase.expectedExportSource(replacement)),
                    "[\(testCase.id)] edited span should round-trip through export. got=\(exported)"
                )
                XCTAssertFalse(
                    textView.string.contains(testCase.expectedExportSource(replacement)),
                    "[\(testCase.id)] collapsed WYSIWYG should hide markdown syntax after edit"
                )
                XCTAssertTrue(
                    textView.string.contains(replacement),
                    "[\(testCase.id)] edited visible token should persist after collapse"
                )
            }
        }
    }

    @MainActor
    func testHybridModeTypedInlineLinkBoundaryKeepsTailPlainAndRoundTrips() {
        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = ""

            let textView = vc.textViewForTesting()
            for ch in "[link](example.com)" {
                textView.insertText(String(ch), replacementRange: textView.selectedRange())
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            vc.flushPendingExport()

            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            textView.insertText(" tail", replacementRange: textView.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

            textView.setSelectedRange(NSRange(location: 0, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))

            let visible = textView.string as NSString
            let tailRange = visible.range(of: "tail")
            XCTAssertNotEqual(tailRange.location, NSNotFound, "typed tail token should remain visible")
            if tailRange.location != NSNotFound {
                let attrs = textView.textStorage?.attributes(at: tailRange.location, effectiveRange: nil) ?? [:]
                XCTAssertNil(attrs[.link], "tail token must not inherit .link in hybrid mode")
                XCTAssertNil(attrs[.kernLinkDestination], "tail token must not inherit link destination metadata")
            }

            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(exported.contains("[link](example.com)"), "link markdown should round-trip in hybrid mode. got=\(exported)")
            XCTAssertTrue(exported.contains(" tail"), "plain tail text should remain outside link. got=\(exported)")
        }
    }

    @MainActor
    func testSwitchingPreferenceToHybridAppliesImmediatelyAtCurrentCaret() {
        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue,
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "prefix **bold** tail"

            let textView = vc.textViewForTesting()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

            let visible = textView.string as NSString
            let bold = visible.range(of: "bold")
            XCTAssertNotEqual(bold.location, NSNotFound)
            guard bold.location != NSNotFound else { return }

            textView.setSelectedRange(NSRange(location: bold.location + 1, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertFalse(textView.string.contains("**bold**"), "WYSIWYG should hide markdown syntax before switching mode")

            UserDefaults.standard.set(
                NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
                forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey
            )
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))

            XCTAssertTrue(
                textView.string.contains("**bold**"),
                "Switching to hybrid mode should expand inline syntax at current caret without extra cursor movement"
            )
        }
    }

    @MainActor
    func testHybridCollapseDoesNotJumpViewportWhenCaretLeavesExpandedSpan() {
        withTemporaryDefaults([
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.hybrid.rawValue,
        ]) {
            var lines = (0..<260).map { "line \($0) plain content for viewport stability" }
            lines[140] = "line 140 [docs](https://example.com/docs) tail"
            lines[141] = "line 141 anchor"

            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = lines.joined(separator: "\n")

            let textView = vc.textViewForTesting()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

            vc.setScrollOriginYForTesting(2_000)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

            let visible = textView.string as NSString
            let docsRange = visible.range(of: "docs")
            XCTAssertNotEqual(docsRange.location, NSNotFound)
            guard docsRange.location != NSNotFound else { return }

            textView.setSelectedRange(NSRange(location: docsRange.location + 1, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            XCTAssertTrue(textView.string.contains("[docs](https://example.com/docs)"))
            let beforeCollapseY = vc.scrollOriginYForTesting()

            let anchorRange = (textView.string as NSString).range(of: "line 141 anchor")
            XCTAssertNotEqual(anchorRange.location, NSNotFound)
            guard anchorRange.location != NSNotFound else { return }

            textView.setSelectedRange(NSRange(location: anchorRange.location + 3, length: 0))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            XCTAssertFalse(textView.string.contains("[docs](https://example.com/docs)"))
            let afterY = vc.scrollOriginYForTesting()
            XCTAssertEqual(
                afterY,
                beforeCollapseY,
                accuracy: 6.0,
                "Hybrid collapse should preserve viewport position (avoid jump when caret leaves expanded syntax span)"
            )
        }
    }

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        var saved: [String: Any?] = [:]
        for (key, value) in overrides {
            saved[key] = defaults.object(forKey: key)
            defaults.set(value, forKey: key)
        }
        defer {
            for (key, previous) in saved {
                if let previous {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }
        return try body()
    }
}
