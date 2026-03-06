import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorPasteNormalizationTests: XCTestCase {
    @MainActor
    func testPasteRichTextInsertsUsingEditorTypingAttributes() {
        let (_, textView) = makeController(markdown: "Hello")
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        guard let storage = textView.textStorage,
              let contextFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            XCTFail("Missing context font")
            return
        }

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

        let pastedFont = storage.attribute(.font, at: pastedRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(pastedFont?.fontName, contextFont.fontName)
        XCTAssertEqual(pastedFont?.pointSize ?? 0, contextFont.pointSize, accuracy: 0.01)

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

    @MainActor
    func testPlainPasteSanitizesContaminatedTypingAttributes() {
        let (_, textView) = makeController(markdown: "Hello")
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        guard let storage = textView.textStorage,
              let contextFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            XCTFail("Missing context font")
            return
        }

        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.black,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .link: URL(string: "https://example.com/contaminated")!,
        ]

        textView._debugPastePlainStringForTests(" world")

        let ns = textView.string as NSString
        let pastedRange = ns.range(of: "world")
        XCTAssertNotEqual(pastedRange.location, NSNotFound)

        let pastedFont = storage.attribute(.font, at: pastedRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(pastedFont?.fontName, contextFont.fontName)
        XCTAssertEqual(pastedFont?.pointSize ?? 0, contextFont.pointSize, accuracy: 0.01)

        let pastedColor = storage.attribute(.foregroundColor, at: pastedRange.location, effectiveRange: nil) as? NSColor
        XCTAssertTrue(pastedColor?.isEqual(NSColor.labelColor) ?? false)

        let pastedUnderline = (storage.attribute(.underlineStyle, at: pastedRange.location, effectiveRange: nil) as? Int) ?? 0
        XCTAssertEqual(pastedUnderline, 0)
        XCTAssertNil(storage.attribute(.link, at: pastedRange.location, effectiveRange: nil))
    }

    @MainActor
    func testSemanticMarkdownConversionFromRichTextAttributes() {
        let (_, textView) = makeController(markdown: "")
        let rich = NSMutableAttributedString()

        rich.append(NSAttributedString(
            string: "Bold",
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold)]
        ))
        rich.append(NSAttributedString(string: " "))
        rich.append(NSAttributedString(
            string: "Italic",
            attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)]
        ))
        rich.append(NSAttributedString(string: " "))
        rich.append(NSAttributedString(
            string: "Link",
            attributes: [.link: URL(string: "https://example.com/docs")!]
        ))

        let markdown = textView._debugMarkdownFromAttributedPasteForTests(rich)
        XCTAssertEqual(markdown, "**Bold** *Italic* [Link](https://example.com/docs)")
    }

    @MainActor
    func testCopyFullDocumentSelectionExportsMarkdownSource() {
        let markdown = """
        # Heading

        - [ ] task
        """
        let (_, textView) = makeController(markdown: markdown)
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))

        let copied = textView._debugCopyMarkdownStringForCurrentSelectionForTests()
        XCTAssertEqual(copied, markdown)
    }

    @MainActor
    func testBulkMarkdownPasteRehydratesWysiwygAfterFlush() {
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousForcePlain = getenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousAllowPlain = getenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE").map { String(cString: $0) }
        setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", "1", 1)
        unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
        unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")
        defer {
            if let previousForceFull {
                setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", previousForceFull, 1)
            } else {
                unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
            }
            if let previousForcePlain {
                setenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT", previousForcePlain, 1)
            } else {
                unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
            }
            if let previousAllowPlain {
                setenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE", previousAllowPlain, 1)
            } else {
                unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")
            }
        }

        let (vc, textView) = makeController(markdown: "")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let pasted = """
        ### Paste Heading

        Paragraph with **bold** text.
        """
        textView._debugPastePlainStringForTests(pasted)

        XCTAssertTrue(
            textView.string.contains("**bold**"),
            "Before export flush, bulk paste may still be raw markdown"
        )

        vc.flushPendingExport()

        XCTAssertFalse(textView.string.contains("### Paste Heading"))
        XCTAssertFalse(textView.string.contains("**bold**"))
        XCTAssertTrue(textView.string.contains("Paste Heading"))
        XCTAssertTrue(textView.string.contains("bold"))

        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }
        let headingRange = (textView.string as NSString).range(of: "Paste Heading")
        XCTAssertNotEqual(headingRange.location, NSNotFound)
        let headingLevel = storage.attribute(.kernHeadingLevel, at: headingRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(headingLevel, 3, "Heading metadata should be restored after rehydration")
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
