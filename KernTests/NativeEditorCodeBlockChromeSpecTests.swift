import AppKit
import XCTest
@testable import KernTextKit

/// Full-spec (exhaustive) tests for code-block chrome and UX.
///
/// These tests are expected to FAIL until the UI implements:
/// - a language label
/// - syntax highlighting
/// - "Copied" feedback on copy
/// - correct copy-button placement
final class NativeEditorCodeBlockChromeSpecTests: XCTestCase {
    @MainActor
    func testCopyButtonPlacementAndCopiedFeedback_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        ```js
        console.log("hi")
        console.log(2)
        ```
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = md

        // Host the VC in a window so TextKit layout metrics are available.
        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .aqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        // Put caret inside the code block.
        let ns = textView.string as NSString
        let r = ns.range(of: "console.log")
        XCTAssertNotEqual(r.location, NSNotFound)
        textView.setSelectedRange(NSRange(location: r.location, length: 0))

        // Force another layout pass so the copy button is repositioned after selection changes.
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        guard let copyButton = findSubview(withAXIdentifier: "NativeEditor.CodeCopyButton", in: vc.view) as? NSButton else {
            XCTFail("Missing NativeEditor.CodeCopyButton")
            return
        }

        XCTAssertFalse(copyButton.isHidden, "Copy button should be visible when caret is in a code block")

        // Full-spec: copy button should be placed near the TOP-RIGHT of the *code block*, not bottom-right of the window.
        guard let (codeRectInTextView, codeRange) = firstCodeBlockRect(in: textView) else {
            XCTFail("Could not compute code block rect")
            return
        }

        // Convert code rect to the container coordinate space (vc.view).
        let codeRectInContainer = vc.view.convert(codeRectInTextView, from: textView)

        // The button should overlap the code block area (with some padding).
        XCTAssertTrue(copyButton.frame.intersects(codeRectInContainer), "Copy button should live within the code block area")

        // The button's midY should be closer to the code block's top edge than its bottom edge.
        let dTop = abs(copyButton.frame.midY - codeRectInContainer.maxY)
        let dBottom = abs(copyButton.frame.midY - codeRectInContainer.minY)
        XCTAssertLessThan(dTop, dBottom, "Copy button should be positioned closer to top of the code block than bottom")

        // Clicking copy should provide immediate UI feedback ("Copied"), then revert back to "Copy".
        XCTAssertEqual(copyButton.title, "Copy")
        NSPasteboard.general.clearContents()
        copyButton.performClick(nil)

        // Copy should still work.
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("console.log(\"hi\")"))
        XCTAssertTrue(copied.contains("console.log(2)"))

        // Full-spec feedback (not implemented yet).
        XCTAssertEqual(copyButton.title, "Copied", "Copy button should show feedback after click")

        // Keep the test deterministic: allow a short grace period for the revert.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(copyButton.title, "Copy", "Copy button should revert after a short delay")

        // Full-spec: language label should be visible for fenced code blocks.
        let languageLabel = findSubview(withAXIdentifier: "NativeEditor.CodeLanguageLabel", in: vc.view)
        XCTAssertNotNil(languageLabel, "Code block should display a language label")

        // Full-spec: syntax highlighting should apply (detect via multiple distinct colors in the code range).
        XCTAssertTrue(hasMultipleForegroundColors(textView: textView, range: codeRange), "Code block should be syntax highlighted")
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

    private func firstCodeBlockRect(in textView: NSTextView) -> (NSRect, NSRange)? {
        guard let storage = textView.textStorage else { return nil }
        guard storage.length > 0 else { return nil }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }

        // Find the first contiguous range where kernBlockKind == .codeBlock
        var start: Int?
        var end: Int?
        for i in 0..<storage.length {
            let kindRaw = storage.attribute(.kernBlockKind, at: i, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .codeBlock {
                if start == nil { start = i }
                end = i
            } else if start != nil {
                break
            }
        }
        guard let s = start, let e = end else { return nil }
        let range = NSRange(location: s, length: max(0, e - s + 1))

        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return (rect, range)
    }

    private func hasMultipleForegroundColors(textView: NSTextView, range: NSRange) -> Bool {
        guard let storage = textView.textStorage else { return false }
        guard range.location + range.length <= storage.length else { return false }

        var colors = Set<NSColor>()
        storage.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
            if let c = value as? NSColor {
                colors.insert(c)
            }
        }
        return colors.count >= 2
    }
}
