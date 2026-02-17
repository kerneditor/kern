import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorCodeBlockBackgroundSpacingTests: XCTestCase {
    @MainActor
    func testCodeBlockBackgroundDoesNotOverlapHeadingAbove() {
        let md = """
        ## Heading Above

        ```javascript
        console.log(\"hi\")
        ```
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = md

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .aqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let lm = textView.layoutManager, let tc = textView.textContainer, let storage = textView.textStorage else {
            XCTFail("Missing TextKit components")
            return
        }

        let ns = storage.string as NSString
        let headingToken = ns.range(of: "Heading Above")
        XCTAssertNotEqual(headingToken.location, NSNotFound)

        let headingPara = ns.paragraphRange(for: NSRange(location: headingToken.location, length: 0))
        let headingGlyphs = lm.glyphRange(forCharacterRange: headingPara, actualCharacterRange: nil)
        var headingRect = lm.boundingRect(forGlyphRange: headingGlyphs, in: tc)
        headingRect.origin.x += textView.textContainerOrigin.x
        headingRect.origin.y += textView.textContainerOrigin.y

        let blocks = codeBlockRects(in: textView)
        XCTAssertEqual(blocks.count, 1, "Expected 1 fenced code block")
        XCTAssertFalse(blocks[0].intersects(headingRect), "Code block background should not overlap the heading above")
    }

    @MainActor
    func testAdjacentCodeBlockBackgroundsDoNotOverlap() {
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

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .aqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        let blocks = codeBlockRects(in: textView)
        XCTAssertEqual(blocks.count, 2, "Expected 2 fenced code blocks")
        guard blocks.count == 2 else { return }
        let r0 = blocks[0]
        let r1 = blocks[1]
        XCTAssertFalse(r0.intersects(r1), "Adjacent code block backgrounds should not overlap. r0=\(r0) r1=\(r1)")
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

    @MainActor
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

                    // Stop at boundaries between back-to-back fenced blocks.
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
            } else {
                idx = para.location + para.length
            }
        }

        return rects
    }
}
