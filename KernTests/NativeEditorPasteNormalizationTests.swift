import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorPasteNormalizationTests: XCTestCase {
    @MainActor
    func testPasteRichTextInsertsUsingEditorTypingAttributes() {
        let (_, textView) = makeController(markdown: "Hello")
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        let expectedFont = NSFont.systemFont(ofSize: 17, weight: .medium)
        let expectedColor = NSColor.labelColor
        textView.typingAttributes = [
            .font: expectedFont,
            .foregroundColor: expectedColor,
        ]

        let pasted = NSAttributedString(
            string: " Pasted",
            attributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        textView._debugPasteAttributedStringForTests(pasted)

        let ns = textView.string as NSString
        let pastedRange = ns.range(of: "Pasted")
        XCTAssertNotEqual(pastedRange.location, NSNotFound)

        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }
        let pastedFont = storage.attribute(.font, at: pastedRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(pastedFont?.pointSize ?? 0, expectedFont.pointSize, accuracy: 0.01)

        let pastedColor = storage.attribute(.foregroundColor, at: pastedRange.location, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(pastedColor)
        XCTAssertFalse(pastedColor?.isEqual(NSColor.black) ?? false)
    }

    @MainActor
    func testPasteNormalizesCarriageReturnLineEndings() {
        let (_, textView) = makeController(markdown: "")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView._debugPastePlainStringForTests("a\r\nb\rc")
        XCTAssertEqual(textView.string, "a\nb\nc")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(markdown: String) -> (NativeEditorViewController, NativeMarkdownTextView) {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        return (vc, textView)
    }

    @MainActor
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView {
            return tv
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) {
                return found
            }
        }
        return nil
    }
}
