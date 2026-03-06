import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorCodeBlockHoverBehaviorTests: XCTestCase {
    @MainActor
    func testHoverAndCaretShowIndependentCodeBlockChromeOverlays() {
        let md = """
        ```javascript
        console.log(\"one\")
        ```

        ```python
        print(\"two\")
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

        // Put caret inside the first code block.
        let ns = textView.string as NSString
        let firstToken = ns.range(of: "one")
        XCTAssertNotEqual(firstToken.location, NSNotFound)
        textView.setSelectedRange(NSRange(location: firstToken.location, length: 0))

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        guard let caretCopyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton", in: vc.view) as? NSButton else {
            XCTFail("Missing NativeEditor.CodeCopyButton")
            return
        }
        guard let caretLanguageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField else {
            XCTFail("Missing NativeEditor.CodeLanguageLabel")
            return
        }
        guard let hoverCopyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton.Hover", in: vc.view) as? NSButton else {
            XCTFail("Missing NativeEditor.CodeCopyButton.Hover")
            return
        }
        guard let hoverLanguageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel.Hover", in: vc.view) as? NSTextField else {
            XCTFail("Missing NativeEditor.CodeLanguageLabel.Hover")
            return
        }
        guard let hoverChrome = findSubview(withAXIdentifier: "NativeEditor.CodeBlockChrome.Hover", in: vc.view) as? CodeBlockChromeView else {
            XCTFail("Missing NativeEditor.CodeBlockChrome.Hover")
            return
        }

        let blocks = codeBlockRects(in: textView)
        XCTAssertEqual(blocks.count, 2, "Expected 2 fenced code blocks")

        let firstRectContainer = vc.view.convert(blocks[0], from: textView)
        let caretCopyFrame = caretCopyButton.convert(caretCopyButton.bounds, to: vc.view)
        XCTAssertFalse(caretCopyButton.isHidden)
        XCTAssertTrue(caretCopyFrame.intersects(firstRectContainer), "Caret chrome should be on the caret code block")
        XCTAssertEqual(caretLanguageLabel.stringValue, "javascript")

        XCTAssertTrue(hoverChrome.isHidden, "Hover chrome should be hidden before hover")

        // Hover the second code block; hover chrome should appear there while caret chrome stays on the first block.
        let secondRect = blocks[1]
        let hoverPoint = NSPoint(x: min(secondRect.maxX - 6, max(secondRect.minX + 6, secondRect.midX)),
                                 y: min(secondRect.maxY - 6, max(secondRect.minY + 6, secondRect.midY)))
        textView._debugSimulateHover(at: hoverPoint)

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        let secondRectContainer = vc.view.convert(secondRect, from: textView)
        let updatedCaretCopyFrame = caretCopyButton.convert(caretCopyButton.bounds, to: vc.view)
        XCTAssertTrue(updatedCaretCopyFrame.intersects(firstRectContainer), "Caret chrome should remain on the caret code block")
        XCTAssertEqual(caretLanguageLabel.stringValue, "javascript")

        XCTAssertFalse(hoverChrome.isHidden, "Hover chrome should be visible when hovering")
        let hoverCopyFrame = hoverCopyButton.convert(hoverCopyButton.bounds, to: vc.view)
        XCTAssertTrue(hoverCopyFrame.intersects(secondRectContainer), "Hover chrome should be on the hovered code block")
        XCTAssertEqual(hoverLanguageLabel.stringValue, "python", "Hover language label should reflect the hovered code block")

        // Guard against visual truncation for common short languages like PYTHON.
        vc.view.layoutSubtreeIfNeeded()
        let required = hoverLanguageLabel.intrinsicContentSize.width
        let available = hoverLanguageLabel.frame.width
        XCTAssertGreaterThanOrEqual(
            available + 0.5,
            required,
            "Language label should have enough width to avoid truncation (available: \(available), required: \(required))"
        )
    }

    @MainActor
    func testHoverChromeRemainsVisibleWhenMovingOntoHoverCopyButton() {
        let md = """
        Intro

        ```python
        print(\"two\")
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
        guard let hoverCopyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton.Hover", in: vc.view) as? NSButton,
              let hoverChrome = findSubview(withAXIdentifier: "NativeEditor.CodeBlockChrome.Hover", in: vc.view) as? CodeBlockChromeView else {
            XCTFail("Missing hover chrome")
            return
        }

        let blocks = codeBlockRects(in: textView)
        XCTAssertEqual(blocks.count, 1, "Expected 1 fenced code block")
        guard let block = blocks.first else { return }

        let hoverPoint = NSPoint(x: min(block.maxX - 6, max(block.minX + 6, block.midX)),
                                 y: min(block.maxY - 6, max(block.minY + 6, block.midY)))
        textView._debugSimulateHover(at: hoverPoint)

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        XCTAssertFalse(hoverChrome.isHidden, "Hover chrome should be visible after hovering the block")

        textView._debugSimulateHoverExit()
        hoverChrome._debugSimulatePointerInside(true)

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        XCTAssertFalse(hoverChrome.isHidden, "Hover chrome should stay visible when the pointer leaves the text view and enters the hover chrome")

        NSPasteboard.general.clearContents()
        hoverCopyButton.performClick(nil)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("print(\"two\")"), "Hover copy button should remain reachable after moving onto the button")
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

            if kind == .codeBlock {
                var start = para.location
                var end = para.location + para.length
                var scan = end
                while scan < ns.length {
                    let next = ns.paragraphRange(for: NSRange(location: scan, length: 0))
                    if next.length == 0 { break }
                    if next.location >= storage.length { break }
                    let kRaw = storage.attribute(.kernBlockKind, at: next.location, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    if k != .codeBlock { break }
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
            } else {
                idx = para.location + para.length
            }
        }

        return rects
    }
}
