import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorCodeBlockLanguagePillLayoutTests: XCTestCase {
    @MainActor
    func testCaretLanguagePillDoesNotTruncateTypeScriptOrBash() {
        let md = """
        ```typescript
        interface Foo { bar: string }
        ```

        ```bash
        echo \"hi\"
        ```
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = md

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        func assertLanguageNotTruncated(token: String, expected: String) {
            let ns = storage.string as NSString
            let r = ns.range(of: token)
            XCTAssertNotEqual(r.location, NSNotFound, "Missing token: \(token)")
            textView.setSelectedRange(NSRange(location: r.location, length: 0))

            vc.view.layoutSubtreeIfNeeded()
            vc.viewDidLayout()

            guard let label = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField else {
                XCTFail("Missing NativeEditor.CodeLanguageLabel")
                return
            }

            XCTAssertEqual(label.stringValue, expected)
            XCTAssertEqual(label.lineBreakMode, .byClipping)
            XCTAssertEqual(label.cell?.lineBreakMode, .byClipping)
            XCTAssertEqual(label.cell?.truncatesLastVisibleLine, false)

            let required = label.intrinsicContentSize.width
            let available = label.frame.width
            XCTAssertGreaterThanOrEqual(
                available + 0.5,
                required,
                "Language label should not truncate (available: \(available), required: \(required), value: \(label.stringValue))"
            )
        }

        assertLanguageNotTruncated(token: "interface", expected: "typescript")
        assertLanguageNotTruncated(token: "echo", expected: "bash")
    }

    @MainActor
    func testLanguagePillUsesFenceLanguageTokenOnly_WithInfoString() {
        let md = """
        ```typescript title=\"editor-config\"
        interface EditorConfig { theme: string }
        ```

        ```bash linenums=on
        echo \"hi\"
        ```
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = md

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NativeMarkdownTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        func assertCaretLanguage(token: String, expected: String) {
            let ns = storage.string as NSString
            let r = ns.range(of: token)
            XCTAssertNotEqual(r.location, NSNotFound, "Missing token: \(token)")
            textView.setSelectedRange(NSRange(location: r.location, length: 0))
            vc.view.layoutSubtreeIfNeeded()
            vc.viewDidLayout()

            guard let label = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField else {
                XCTFail("Missing NativeEditor.CodeLanguageLabel")
                return
            }
            XCTAssertEqual(label.stringValue, expected)
            XCTAssertEqual(label.lineBreakMode, .byClipping)
            XCTAssertEqual(label.cell?.lineBreakMode, .byClipping)
            XCTAssertEqual(label.cell?.truncatesLastVisibleLine, false)
            XCTAssertGreaterThanOrEqual(
                label.frame.width + 0.5,
                label.intrinsicContentSize.width,
                "Caret language label should have enough width (value: \(label.stringValue))"
            )
        }

        assertCaretLanguage(token: "interface", expected: "typescript")
        assertCaretLanguage(token: "echo", expected: "bash")

        // Hover second block while caret remains in first block: hover chrome should also show full token.
        let ns = storage.string as NSString
        let firstToken = ns.range(of: "interface")
        XCTAssertNotEqual(firstToken.location, NSNotFound)
        textView.setSelectedRange(NSRange(location: firstToken.location, length: 0))
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        guard let hoverLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel.Hover", in: vc.view) as? NSTextField else {
            XCTFail("Missing NativeEditor.CodeLanguageLabel.Hover")
            return
        }

        guard let secondRect = codeBlockRects(in: textView).dropFirst().first else {
            XCTFail("Missing second code block rect")
            return
        }
        let hoverPoint = NSPoint(x: min(secondRect.maxX - 6, max(secondRect.minX + 6, secondRect.midX)),
                                 y: min(secondRect.maxY - 6, max(secondRect.minY + 6, secondRect.midY)))
        textView._debugSimulateHover(at: hoverPoint)
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        XCTAssertEqual(hoverLabel.stringValue, "bash")
        XCTAssertEqual(hoverLabel.lineBreakMode, .byClipping)
        XCTAssertEqual(hoverLabel.cell?.lineBreakMode, .byClipping)
        XCTAssertEqual(hoverLabel.cell?.truncatesLastVisibleLine, false)
        XCTAssertGreaterThanOrEqual(
            hoverLabel.frame.width + 0.5,
            hoverLabel.intrinsicContentSize.width,
            "Hover language label should have enough width (value: \(hoverLabel.stringValue))"
        )
    }

    @MainActor
    func testLanguagePillDoesNotTruncateInNarrowWindow_ForLongLanguageTokens() {
        let md = """
        ```typescript
        interface EditorConfig { theme: string }
        ```

        ```dockerfile
        FROM swift:6.0
        ```
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = md

        let window = hostInWindow(vc: vc, size: NSSize(width: 560, height: 480), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        func assertLanguageNotTruncated(token: String, expected: String) {
            let ns = storage.string as NSString
            let r = ns.range(of: token)
            XCTAssertNotEqual(r.location, NSNotFound, "Missing token: \(token)")
            textView.setSelectedRange(NSRange(location: r.location, length: 0))

            vc.view.layoutSubtreeIfNeeded()
            vc.viewDidLayout()

            guard let label = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField else {
                XCTFail("Missing NativeEditor.CodeLanguageLabel")
                return
            }

            XCTAssertEqual(label.stringValue, expected)
            XCTAssertEqual(label.lineBreakMode, .byClipping)
            XCTAssertEqual(label.cell?.lineBreakMode, .byClipping)
            XCTAssertEqual(label.cell?.truncatesLastVisibleLine, false)
            XCTAssertGreaterThanOrEqual(
                label.frame.width + 0.5,
                label.intrinsicContentSize.width,
                "Language label should fit fully without truncation (value: \(label.stringValue))"
            )
        }

        assertLanguageNotTruncated(token: "interface", expected: "typescript")
        assertLanguageNotTruncated(token: "FROM", expected: "dockerfile")
    }

    // MARK: - Helpers

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
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) { return found }
        }
        return nil
    }

    private func codeBlockRects(in textView: NSTextView) -> [NSRect] {
        guard let storage = textView.textStorage else { return [] }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return [] }
        guard storage.length > 0 else { return [] }

        let ns = storage.string as NSString
        var rects: [NSRect] = []
        var idx = 0
        while idx < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            if para.length == 0 { break }
            if para.location >= storage.length { break }

            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            guard kind == .codeBlock else {
                idx = para.location + para.length
                continue
            }

            let quoteDepth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0
            let codeBlockID = storage.attribute(.kernCodeBlockID, at: para.location, effectiveRange: nil) as? Int
            let start = para.location
            var end = para.location + para.length
            var scan = end
            while scan < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: scan, length: 0))
                if next.length == 0 { break }
                guard next.location < storage.length else { break }

                let kRaw = storage.attribute(.kernBlockKind, at: next.location, effectiveRange: nil) as? Int
                let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                if k != .codeBlock { break }

                let nextQuoteDepth = (storage.attribute(.kernQuoteDepth, at: next.location, effectiveRange: nil) as? Int) ?? 0
                if nextQuoteDepth != quoteDepth { break }

                if let codeBlockID {
                    let nextID = storage.attribute(.kernCodeBlockID, at: next.location, effectiveRange: nil) as? Int
                    if nextID != codeBlockID { break }
                } else if (storage.attribute(.kernCodeBlockID, at: next.location, effectiveRange: nil) as? Int) != nil {
                    break
                }

                end = next.location + next.length
                scan = end
            }

            let charRange = NSRange(location: start, length: max(0, end - start))
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            var lineSpanRect: NSRect?
            if glyphRange.length > 0 {
                var effective = NSRange(location: 0, length: 0)
                var lf = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
                lf.origin.x += textView.textContainerOrigin.x
                lf.origin.y += textView.textContainerOrigin.y
                let left = rect.minX
                let right = lf.maxX
                lineSpanRect = NSRect(x: left, y: lf.minY, width: max(0, right - left), height: lf.height)
            }
            rects.append(CodeBlockChromeGeometry.backgroundRect(forGlyphBoundingRect: rect, lineFragmentRect: lineSpanRect, isFlipped: textView.isFlipped))
            idx = end
        }

        return rects
    }
}
