import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorNotionListBehaviorRegressionTests: XCTestCase {
    private struct BackspaceRecoveryScenario {
        let id: String
        let markdown: String
        let defaults: [String: Any]
    }

    private struct TabRoundTripScenario {
        let id: String
        let markdown: String
        let defaults: [String: Any]
        let expectedAfterTabContains: [String]
        let expectedAfterOutdentContains: [String]
    }

    private struct MidItemSplitScenario {
        let id: String
        let markdown: String
        let defaults: [String: Any]
        let expectedMarkedRemainders: [String]
    }

    private struct InlineLinkScenario {
        let id: String
        let markdown: String
        let defaults: [String: Any]
        let moveToSubstring: String?
    }

    @MainActor
    func testNestedListBackspaceTypingRecoveryMatrix_PRLane() throws {
        let scenarios: [BackspaceRecoveryScenario] = [
            .init(
                id: "nested-bullet",
                markdown: "1. parent\n   - child\n",
                defaults: [:]
            ),
            .init(
                id: "nested-ordered",
                markdown: "1. parent\n   1. child\n",
                defaults: [:]
            ),
            .init(
                id: "nested-task",
                markdown: "1. parent\n   - [ ] child\n",
                defaults: [:]
            ),
            .init(
                id: "nested-ordered-task",
                markdown: "1. parent\n   1. [ ] child\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                    "nativeEditor.exportDialect": "gfm",
                ]
            ),
        ]

        for scenario in scenarios {
            try withTemporaryDefaults(scenario.defaults) {
                let (vc, textView, window) = makeController(markdown: scenario.markdown)
                defer { closeHostedEditor(window) }

                moveCaretToSubstringStart("child", in: textView)
                let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                XCTAssertTrue(handled, "[\(scenario.id)] Expected list backspace command handling at list body start")
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

                textView.insertText("z", replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                textView.insertNewline(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                textView.insertText("next", replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

                vc.flushPendingExport()
                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(exported.contains("z"), "[\(scenario.id)] Expected typing recovery with inserted text. got=\(exported)")
                XCTAssertTrue(exported.contains("next"), "[\(scenario.id)] Expected newline+typing recovery. got=\(exported)")
                XCTAssertFalse(exported.contains("```"), "[\(scenario.id)] List recovery should not degrade into code block. got=\(exported)")
            }
        }
    }

    @MainActor
    func testNestedListTabOutdentRoundTripMatrix_PRLane() throws {
        let scenarios: [TabRoundTripScenario] = [
            .init(
                id: "nested-bullet",
                markdown: "1. parent\n   - child\n",
                defaults: [:],
                expectedAfterTabContains: ["- child"],
                expectedAfterOutdentContains: ["- child"]
            ),
            .init(
                id: "nested-ordered",
                markdown: "1. parent\n   1. child\n",
                defaults: [:],
                expectedAfterTabContains: ["1. child"],
                expectedAfterOutdentContains: ["1. child"]
            ),
            .init(
                id: "nested-task",
                markdown: "1. parent\n   - [ ] child\n",
                defaults: [:],
                expectedAfterTabContains: ["- [ ] child", "- ☐ child"],
                expectedAfterOutdentContains: ["- [ ] child", "- ☐ child"]
            ),
            .init(
                id: "nested-ordered-task",
                markdown: "1. parent\n   1. [ ] child\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                    "nativeEditor.exportDialect": "gfm",
                ],
                expectedAfterTabContains: ["1. [ ] child", "1. ☐ child"],
                expectedAfterOutdentContains: ["1. [ ] child", "1. ☐ child"]
            ),
        ]

        for scenario in scenarios {
            try withTemporaryDefaults(scenario.defaults) {
                let (vc, textView, window) = makeController(markdown: scenario.markdown)
                defer { closeHostedEditor(window) }

                moveCaretToSubstringStart("child", in: textView)
                XCTAssertTrue(
                    vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))),
                    "[\(scenario.id)] Expected Tab to indent nested list"
                )
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()
                let afterTab = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(
                    scenario.expectedAfterTabContains.contains { afterTab.contains($0) },
                    "[\(scenario.id)] Expected nested list semantic retention after Tab. got=\(afterTab)"
                )

                XCTAssertTrue(
                    vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))),
                    "[\(scenario.id)] Expected Shift+Tab to outdent nested list"
                )
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()
                let afterOutdent = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(
                    scenario.expectedAfterOutdentContains.contains { afterOutdent.contains($0) },
                    "[\(scenario.id)] Expected nested list semantic retention after Shift+Tab. got=\(afterOutdent)"
                )
                XCTAssertFalse(afterOutdent.contains("```"), "[\(scenario.id)] Outdent should not degrade into code block. got=\(afterOutdent)")
            }
        }
    }

    @MainActor
    func testEnterInMiddleOfListItemContinuesMarkerMatrix_PRLane() throws {
        let scenarios: [MidItemSplitScenario] = [
            .init(
                id: "ordered",
                markdown: "2. asdasd\n",
                defaults: [:],
                expectedMarkedRemainders: ["\n3. asd", "\n2. asd"]
            ),
            .init(
                id: "bullet",
                markdown: "- asdasd\n",
                defaults: [:],
                expectedMarkedRemainders: ["\n- asd", "\n* asd", "\n+ asd"]
            ),
            .init(
                id: "task",
                markdown: "- [ ] asdasd\n",
                defaults: [:],
                expectedMarkedRemainders: ["\n- [ ] asd", "\n- ☐ asd"]
            ),
            .init(
                id: "ordered-task",
                markdown: "2. [ ] asdasd\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                    "nativeEditor.exportDialect": "gfm",
                ],
                expectedMarkedRemainders: ["\n3. [ ] asd", "\n2. [ ] asd", "\n3. ☐ asd", "\n2. ☐ asd"]
            ),
            .init(
                id: "nested-ordered",
                markdown: "1. parent\n   2. asdasd\n",
                defaults: [:],
                expectedMarkedRemainders: ["\n   3. asd", "\n   2. asd"]
            ),
        ]

        for scenario in scenarios {
            try withTemporaryDefaults(scenario.defaults) {
                let (vc, textView, window) = makeController(markdown: scenario.markdown)
                defer { closeHostedEditor(window) }

                moveCaretToSubstringStart("asdasd", in: textView)
                textView.moveRight(nil)
                textView.moveRight(nil)
                textView.moveRight(nil)
                textView.insertNewline(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(exported.contains("asd"), "[\(scenario.id)] expected split content in export. got=\(exported)")
                XCTAssertTrue(
                    scenario.expectedMarkedRemainders.contains { exported.contains($0) },
                    "[\(scenario.id)] expected continued marker on split remainder. got=\(exported)"
                )
                XCTAssertFalse(
                    exported.contains("\nasd\n") || exported.contains("\n   asd\n"),
                    "[\(scenario.id)] split remainder should not become an unmarked plain line. got=\(exported)"
                )
            }
        }
    }

    @MainActor
    func testInlineLinkTypingConvertsAcrossParagraphAndListContexts_PRLane() throws {
        let inlineLink = "[docs](https://example.com/docs)"
        let scenarios: [InlineLinkScenario] = [
            .init(id: "paragraph", markdown: "prefix ", defaults: [:], moveToSubstring: nil),
            .init(id: "bullet", markdown: "- item ", defaults: [:], moveToSubstring: nil),
            .init(id: "ordered", markdown: "2. item ", defaults: [:], moveToSubstring: nil),
            .init(id: "task", markdown: "- [ ] item ", defaults: [:], moveToSubstring: nil),
            .init(
                id: "ordered-task",
                markdown: "2. [ ] item ",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                    "nativeEditor.exportDialect": "gfm",
                ],
                moveToSubstring: nil
            ),
            .init(id: "heading", markdown: "## heading ", defaults: [:], moveToSubstring: nil),
        ]

        for scenario in scenarios {
            try withTemporaryDefaults(scenario.defaults) {
                let (vc, textView, window) = makeController(markdown: scenario.markdown)
                defer { closeHostedEditor(window) }

                if let needle = scenario.moveToSubstring {
                    moveCaretToSubstringStart(needle, in: textView)
                } else {
                    moveCaretToEnd(textView)
                }

                typeCharacters(inlineLink, into: textView)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                let visible = textView.string
                XCTAssertTrue(visible.contains("docs"), "[\(scenario.id)] expected visible label text")
                XCTAssertFalse(visible.contains("[docs]("), "[\(scenario.id)] raw inline link syntax should be hidden after conversion. got=\(visible)")

                let ns = visible as NSString
                let docsRange = ns.range(of: "docs")
                XCTAssertNotEqual(docsRange.location, NSNotFound, "[\(scenario.id)] missing docs token in visible text")
                if docsRange.location != NSNotFound {
                    let linkAttr = textView.textStorage?.attribute(.link, at: docsRange.location, effectiveRange: nil)
                    XCTAssertNotNil(linkAttr, "[\(scenario.id)] expected link attribute on typed inline link label")
                }

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(
                    exported.contains(inlineLink),
                    "[\(scenario.id)] export should preserve inline markdown link syntax. got=\(exported)"
                )
            }
        }
    }

    @MainActor
    func testInlineLinkPasteConvertsAcrossParagraphAndListContexts_PRLane() throws {
        let inlineLink = "[docs](https://example.com/docs)"
        let scenarios: [InlineLinkScenario] = [
            .init(id: "paragraph", markdown: "prefix ", defaults: [:], moveToSubstring: nil),
            .init(id: "bullet", markdown: "- item ", defaults: [:], moveToSubstring: nil),
            .init(id: "ordered", markdown: "2. item ", defaults: [:], moveToSubstring: nil),
            .init(id: "task", markdown: "- [ ] item ", defaults: [:], moveToSubstring: nil),
            .init(
                id: "ordered-task",
                markdown: "2. [ ] item ",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                    "nativeEditor.exportDialect": "gfm",
                ],
                moveToSubstring: nil
            ),
            .init(id: "heading", markdown: "## heading ", defaults: [:], moveToSubstring: nil),
        ]

        for scenario in scenarios {
            try withTemporaryDefaults(scenario.defaults) {
                let (vc, textView, window) = makeController(markdown: scenario.markdown)
                defer { closeHostedEditor(window) }

                if let needle = scenario.moveToSubstring {
                    moveCaretToSubstringStart(needle, in: textView)
                } else {
                    moveCaretToEnd(textView)
                }

                textView.insertText(inlineLink, replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                let visible = textView.string
                XCTAssertTrue(visible.contains("docs"), "[\(scenario.id)] expected visible label text after paste")
                XCTAssertFalse(
                    visible.contains("[docs]("),
                    "[\(scenario.id)] raw inline link syntax should be hidden after paste conversion. got=\(visible)"
                )

                let ns = visible as NSString
                let docsRange = ns.range(of: "docs")
                XCTAssertNotEqual(docsRange.location, NSNotFound, "[\(scenario.id)] missing docs token in visible text")
                if docsRange.location != NSNotFound {
                    let linkAttr = textView.textStorage?.attribute(.link, at: docsRange.location, effectiveRange: nil)
                    XCTAssertNotNil(linkAttr, "[\(scenario.id)] expected link attribute on pasted inline link label")
                }

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(
                    exported.contains(inlineLink),
                    "[\(scenario.id)] export should preserve inline markdown link syntax after paste. got=\(exported)"
                )
            }
        }
    }

    @MainActor
    func testInlineLinkBoundaryTypingDoesNotLeakLinkStylingOrAttributes_PRLane() throws {
        let defaultsProfiles: [[String: Any]] = [[
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue,
        ]]

        for defaults in defaultsProfiles {
            try withTemporaryDefaults(defaults) {
                let (vc, textView, window) = makeController(markdown: "")
                defer { closeHostedEditor(window) }

                // Repro seed: user types a bare-domain inline link.
                typeCharacters("[link](example.com)", into: textView)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                // At the end boundary of the link label, new typing should be plain text, not leaked link style.
                moveCaretToEnd(textView)
                textView.insertText(" tail", replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                let visible = textView.string
                let ns = visible as NSString
                let tailRange = ns.range(of: "tail")
                XCTAssertNotEqual(tailRange.location, NSNotFound, "expected appended plain text")
                if tailRange.location != NSNotFound {
                    let attrs = textView.textStorage?.attributes(at: tailRange.location, effectiveRange: nil) ?? [:]
                    XCTAssertNil(attrs[.link], "plain text typed after a link boundary must not keep .link")
                    XCTAssertNil(attrs[.kernLinkDestination], "plain text typed after a link boundary must not keep link metadata")
                    if let underline = attrs[.underlineStyle] as? Int {
                        XCTAssertNotEqual(underline, NSUnderlineStyle.single.rawValue, "plain text should not leak link underline")
                    }
                }

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(exported.contains("[link](example.com)"), "link markdown should still round-trip")
                XCTAssertTrue(exported.contains(" tail"), "plain tail text should still export as plain content")
            }
        }
    }

    @MainActor
    func testInlineLinkEditThenRetypeDoesNotLeakStylingBeyondLinkBody_PRLane() throws {
        let defaultsProfiles: [[String: Any]] = [[
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue,
        ]]

        for defaults in defaultsProfiles {
            try withTemporaryDefaults(defaults) {
                let (vc, textView, window) = makeController(markdown: "")
                defer { closeHostedEditor(window) }

                typeCharacters("[link](example.com)", into: textView)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                let visible = textView.string as NSString
                let linkRange = visible.range(of: "link")
                XCTAssertNotEqual(linkRange.location, NSNotFound, "expected visible link label")
                guard linkRange.location != NSNotFound else { return }

                textView.insertText("", replacementRange: NSRange(location: linkRange.location + 1, length: 2))
                textView.setSelectedRange(NSRange(location: linkRange.location + 1, length: 0))
                textView.insertText("IN", replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                moveCaretToEnd(textView)
                textView.insertText(" plain-tail", replacementRange: textView.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                vc.flushPendingExport()

                let finalVisible = textView.string as NSString
                let tailRange = finalVisible.range(of: "plain-tail")
                XCTAssertNotEqual(tailRange.location, NSNotFound, "expected plain tail token")
                if tailRange.location != NSNotFound {
                    let attrs = textView.textStorage?.attributes(at: tailRange.location, effectiveRange: nil) ?? [:]
                    XCTAssertNil(attrs[.link], "plain text after link edits must not inherit link attr")
                    XCTAssertNil(attrs[.kernLinkDestination], "plain text after link edits must not inherit link destination")
                    if let underline = attrs[.underlineStyle] as? Int {
                        XCTAssertNotEqual(underline, NSUnderlineStyle.single.rawValue, "plain text should not leak link underline")
                    }
                }

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                XCTAssertTrue(exported.contains("example.com"), "edited link should still retain destination. got=\(exported)")
                XCTAssertTrue(exported.contains("plain-tail"), "tail token should remain plain export. got=\(exported)")
            }
        }
    }

    @MainActor
    func testTypedBareDomainInlineLinkClickNormalizesToHTTPS_PRLane() throws {
        let (vc, textView, window) = makeController(markdown: "")
        defer { closeHostedEditor(window) }

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        typeCharacters("[link](example.com)", into: textView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        vc.flushPendingExport()

        let ns = textView.string as NSString
        let linkRange = ns.range(of: "link")
        XCTAssertNotEqual(linkRange.location, NSNotFound, "expected visible link label")
        guard linkRange.location != NSNotFound else { return }

        let linkValue = textView.textStorage?.attribute(.link, at: linkRange.location, effectiveRange: nil)
        XCTAssertNotNil(linkValue, "expected .link attribute after inline link conversion")
        guard let linkValue else { return }

        let handled = vc.textView(textView, clickedOnLink: linkValue, at: linkRange.location)
        XCTAssertTrue(handled, "clicking inline bare-domain link should be handled")
        XCTAssertEqual(opened?.scheme?.lowercased(), "https")
        XCTAssertEqual(opened?.host?.lowercased(), "example.com")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(markdown: String) -> (NativeEditorViewController, NativeMarkdownTextView, NSWindow) {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()
        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        _ = window.makeFirstResponder(textView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        return (vc, textView, window)
    }

    @MainActor
    private func hostInWindow(vc: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.contentViewController = vc
        window.setFrame(rect, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func closeHostedEditor(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    @MainActor
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    @MainActor
    private func moveCaretToSubstringStart(_ substring: String, in textView: NSTextView) {
        let ns = textView.string as NSString
        let range = ns.range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing substring: \(substring)")
        if range.location == NSNotFound { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    @MainActor
    private func moveCaretToEnd(_ textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    @MainActor
    private func typeCharacters(_ text: String, into textView: NSTextView) {
        for ch in text {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
    }

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        var effectiveOverrides = overrides
        if effectiveOverrides[NativeEditorSyntaxVisibilityMode.userDefaultsKey] == nil {
            effectiveOverrides[NativeEditorSyntaxVisibilityMode.userDefaultsKey] = NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue
        }
        var saved: [String: Any?] = [:]
        for (key, value) in effectiveOverrides {
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
        }
        return try body()
    }
}
