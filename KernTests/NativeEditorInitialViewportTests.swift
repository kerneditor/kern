import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorInitialViewportTests: XCTestCase {
    @MainActor
    func testInitialRenderStartsAtDocumentTopWithCaretAtZero() {
        let markdown = """
        # Title

        Intro paragraph.

        ## Section

        Paragraph 1.

        Paragraph 2.

        Paragraph 3.

        ```typescript
        const x: number = 42
        console.log(x)
        ```

        Final paragraph.
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }
        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        XCTAssertEqual(textView.selectedRange().location, 0, "Initial caret should be at document start")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5, "Initial viewport should start at top")

        // Ensure the first paragraph is visible on initial render.
        guard let lm = textView.layoutManager, let tc = textView.textContainer, textView.string.utf16.count > 0 else {
            XCTFail("Missing layout components")
            return
        }
        let firstGlyph = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
        var firstRect = lm.boundingRect(forGlyphRange: firstGlyph, in: tc)
        firstRect.origin.x += textView.textContainerOrigin.x
        firstRect.origin.y += textView.textContainerOrigin.y
        XCTAssertTrue(textView.visibleRect.intersects(firstRect), "First paragraph should be visible at initial render")
    }

    @MainActor
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) {
                return found
            }
        }
        return nil
    }
}

