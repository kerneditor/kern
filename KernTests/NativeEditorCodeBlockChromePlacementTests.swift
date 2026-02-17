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
}
