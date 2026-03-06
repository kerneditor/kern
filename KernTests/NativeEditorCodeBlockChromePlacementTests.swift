import AppKit
import XCTest
@testable import KernTextKit

/// Non-exhaustive tests for code-block chrome placement (runs in default `--unit-only` mode).
final class NativeEditorCodeBlockChromePlacementTests: XCTestCase {
    @MainActor
    func testLanguageLabelDoesNotOverlayCodeText_WhenCaretInsideCodeBlock() {
        let md = """
        ```js
        console.log(\"hi\")
        console.log(2)
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

        // Put caret inside the code block to show chrome.
        let ns = textView.string as NSString
        let tokenRange = ns.range(of: "console.log")
        XCTAssertNotEqual(tokenRange.location, NSNotFound)
        textView.setSelectedRange(NSRange(location: tokenRange.location, length: 0))

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        guard let copyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton", in: vc.view) as? NSButton else {
            XCTFail("Missing NativeEditor.CodeCopyButton")
            return
        }
        guard let languageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField else {
            XCTFail("Missing NativeEditor.CodeLanguageLabel")
            return
        }

        XCTAssertFalse(copyButton.isHidden, "Copy button should be visible when caret is in a code block")
        XCTAssertFalse(languageLabel.isHidden, "Language label should be visible for fenced code blocks")

        // Frames are in the chrome overlay view's coordinate space; convert to the editor container.
        let copyFrame = copyButton.convert(copyButton.bounds, to: vc.view)
        let labelFrame = languageLabel.convert(languageLabel.bounds, to: vc.view)

        // Language label should be placed next to the Copy button (top-right chrome), not over the code.
        XCTAssertFalse(labelFrame.intersects(copyFrame), "Language label should not overlap the Copy button")
        XCTAssertLessThanOrEqual(labelFrame.maxX, copyFrame.minX - 4, "Language label should sit to the left of the Copy button")

        // Validate the label does not overlay the first code token near the start of the block.
        guard let tokenRectText = rect(forCharacterRange: tokenRange, in: textView) else {
            XCTFail("Could not compute token rect")
            return
        }
        let tokenRectContainer = vc.view.convert(tokenRectText, from: textView)
        XCTAssertFalse(labelFrame.intersects(tokenRectContainer), "Language label should not overlay code text at the start of the block")

        // Copy button should live in the top half of the code block (top-right chrome).
        if let storage = textView.textStorage {
            var eff = NSRange(location: 0, length: 0)
            let kindRaw = storage.attribute(.kernBlockKind, at: tokenRange.location, effectiveRange: &eff) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .codeBlock, let codeRectText = rect(forCharacterRange: eff, in: textView) {
                let codeRectContainer = vc.view.convert(codeRectText, from: textView)
                let dTop = abs(copyFrame.midY - codeRectContainer.maxY)
                let dBottom = abs(copyFrame.midY - codeRectContainer.minY)
                XCTAssertLessThan(dTop, dBottom, "Copy button should be positioned closer to the top of the code block than the bottom")
            } else {
                XCTFail("Could not resolve code-block rect for copy-button placement check")
            }
        } else {
            XCTFail("Missing text storage")
        }
    }

    @MainActor
    func testCaretChromeDoesNotIntersectHeadingAbove() {
        let md = """
        ## Heading Above

        ```js
        console.log(\"hi\")
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
        let ns = textView.string as NSString
        let codeToken = ns.range(of: "console.log")
        let headingToken = ns.range(of: "Heading Above")
        XCTAssertNotEqual(codeToken.location, NSNotFound)
        XCTAssertNotEqual(headingToken.location, NSNotFound)

        textView.setSelectedRange(NSRange(location: codeToken.location, length: 0))
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        guard let copyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton", in: vc.view) as? NSButton,
              let languageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField,
              let headingRectText = paragraphRect(forCharacterRange: headingToken, in: textView) else {
            XCTFail("Missing chrome or heading rect")
            return
        }

        let headingRectContainer = vc.view.convert(headingRectText, from: textView)
        let copyFrame = copyButton.convert(copyButton.bounds, to: vc.view)
        let labelFrame = languageLabel.convert(languageLabel.bounds, to: vc.view)

        XCTAssertFalse(copyFrame.intersects(headingRectContainer), "Copy chrome should not collide with the heading above")
        XCTAssertFalse(labelFrame.intersects(headingRectContainer), "Language pill should not collide with the heading above")
    }

    @MainActor
    func testCaretChromeDoesNotIntersectParagraphAbove() {
        let md = """
        Paragraph above the block.

        ```js
        console.log(\"hi\")
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
        let ns = textView.string as NSString
        let codeToken = ns.range(of: "console.log")
        let paragraphToken = ns.range(of: "Paragraph above the block.")
        XCTAssertNotEqual(codeToken.location, NSNotFound)
        XCTAssertNotEqual(paragraphToken.location, NSNotFound)

        textView.setSelectedRange(NSRange(location: codeToken.location, length: 0))
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        guard let copyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton", in: vc.view) as? NSButton,
              let languageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view) as? NSTextField,
              let paragraphRectText = paragraphRect(forCharacterRange: paragraphToken, in: textView) else {
            XCTFail("Missing chrome or paragraph rect")
            return
        }

        let paragraphRectContainer = vc.view.convert(paragraphRectText, from: textView)
        let copyFrame = copyButton.convert(copyButton.bounds, to: vc.view)
        let labelFrame = languageLabel.convert(languageLabel.bounds, to: vc.view)

        XCTAssertFalse(copyFrame.intersects(paragraphRectContainer), "Copy chrome should not collide with the paragraph above")
        XCTAssertFalse(labelFrame.intersects(paragraphRectContainer), "Language pill should not collide with the paragraph above")
    }

    @MainActor
    func testHoverChromeForLowerStackedBlockDoesNotIntersectUpperBlock() {
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
        guard let hoverCopyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton.Hover", in: vc.view) as? NSButton,
              let hoverLanguageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel.Hover", in: vc.view) as? NSTextField else {
            XCTFail("Missing hover chrome")
            return
        }

        let blocks = codeBlockRects(in: textView)
        XCTAssertEqual(blocks.count, 2, "Expected 2 fenced code blocks")
        guard blocks.count == 2 else { return }

        let lowerBlock = blocks[1]
        let hoverPoint = NSPoint(
            x: min(lowerBlock.maxX - 6, max(lowerBlock.minX + 6, lowerBlock.midX)),
            y: min(lowerBlock.maxY - 6, max(lowerBlock.minY + 6, lowerBlock.midY))
        )
        textView._debugSimulateHover(at: hoverPoint)
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        let upperBlockContainer = vc.view.convert(blocks[0], from: textView)
        let hoverCopyFrame = hoverCopyButton.convert(hoverCopyButton.bounds, to: vc.view)
        let hoverLabelFrame = hoverLanguageLabel.convert(hoverLanguageLabel.bounds, to: vc.view)

        XCTAssertFalse(hoverCopyFrame.intersects(upperBlockContainer), "Lower-block hover copy button should not collide with the upper block")
        XCTAssertFalse(hoverLabelFrame.intersects(upperBlockContainer), "Lower-block hover language pill should not collide with the upper block")
    }

    @MainActor
    func testShowingCaretChromeDoesNotChangeCodeBlockRect() {
        let md = """
        ```js
        console.log(\"hi\")
        console.log(2)
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
        let blocksBefore = codeBlockRects(in: textView)
        XCTAssertEqual(blocksBefore.count, 1)
        guard let before = blocksBefore.first else { return }

        let ns = textView.string as NSString
        let codeToken = ns.range(of: "console.log")
        XCTAssertNotEqual(codeToken.location, NSNotFound)
        textView.setSelectedRange(NSRange(location: codeToken.location, length: 0))
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        let blocksAfter = codeBlockRects(in: textView)
        XCTAssertEqual(blocksAfter.count, 1)
        guard let after = blocksAfter.first else { return }

        XCTAssertEqual(before.origin.x, after.origin.x, accuracy: 0.5)
        XCTAssertEqual(before.origin.y, after.origin.y, accuracy: 0.5)
        XCTAssertEqual(before.size.width, after.size.width, accuracy: 0.5)
        XCTAssertEqual(before.size.height, after.size.height, accuracy: 0.5)
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

    private func rect(forCharacterRange range: NSRange, in textView: NSTextView) -> NSRect? {
        guard range.location != NSNotFound else { return nil }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    private func paragraphRect(forCharacterRange range: NSRange, in textView: NSTextView) -> NSRect? {
        guard range.location != NSNotFound else { return nil }
        guard let storage = textView.textStorage, let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        guard storage.length > 0 else { return nil }
        let ns = storage.string as NSString
        let paragraphRange = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: paragraphRange, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
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

            let codeBlockID = storage.attribute(.kernCodeBlockID, at: para.location, effectiveRange: nil) as? Int
            let quoteDepth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0
            let start = para.location
            var end = para.location + para.length
            var scan = end
            while scan < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: scan, length: 0))
                if next.length == 0 { break }
                if next.location >= storage.length { break }
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
