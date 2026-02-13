import AppKit
import XCTest
@testable import KernTextKit

/// Pixel-level layout metric tests for checkbox glyph rendering.
///
/// These are spec-level tests (gated behind exhaustive) intended to prevent subtle visual regressions:
/// - checkbox is vertically aligned with the text on the same line
/// - checkbox hit target isn't comically small
final class NativeEditorCheckboxLayoutMetricSpecTests: XCTestCase {
    @MainActor
    func testTaskCheckboxIsVerticallyCenteredWithText_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let md = "- [ ] item\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)

        let textView = makeLaidOutTextView(attr: attr, width: 600, height: 120)

        guard let checkboxIndex = firstIndex(with: .kernCheckbox, in: textView) else {
            XCTFail("Expected a checkbox glyph for GFM task list")
            return
        }

        // Find a nearby normal letter to compare vertical centering.
        let ns = textView.string as NSString
        let r = ns.range(of: "item")
        XCTAssertNotEqual(r.location, NSNotFound)
        let letterIndex = r.location // 'i'

        let checkboxRect = glyphRect(atCharIndex: checkboxIndex, in: textView)
        let letterRect = glyphRect(atCharIndex: letterIndex, in: textView)

        XCTAssertGreaterThan(checkboxRect.height, 10, "Checkbox glyph is too small")
        XCTAssertGreaterThan(checkboxRect.width, 10, "Checkbox glyph is too small")

        let deltaMidY = abs(checkboxRect.midY - letterRect.midY)
        XCTAssertLessThan(deltaMidY, 2.0, "Checkbox glyph should be vertically centered with adjacent text (deltaMidY=\(deltaMidY))")
    }

    @MainActor
    func testHeadingCheckboxIsVerticallyCenteredWithHeadingText_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let md = "## [ ] Heading todo\n"
        let opt = NativeMarkdownCodec.Options(headingCheckboxesEnabled: true)
        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)

        let textView = makeLaidOutTextView(attr: attr, width: 800, height: 140)

        guard let checkboxIndex = firstIndex(with: .kernCheckbox, in: textView) else {
            XCTFail("Expected a checkbox glyph for heading checkbox syntax when enabled")
            return
        }

        let ns = textView.string as NSString
        let r = ns.range(of: "Heading")
        XCTAssertNotEqual(r.location, NSNotFound)
        let letterIndex = r.location

        let checkboxRect = glyphRect(atCharIndex: checkboxIndex, in: textView)
        let letterRect = glyphRect(atCharIndex: letterIndex, in: textView)

        let deltaMidY = abs(checkboxRect.midY - letterRect.midY)
        XCTAssertLessThan(deltaMidY, 2.0, "Heading checkbox glyph should be vertically centered with heading text (deltaMidY=\(deltaMidY))")
    }

    // MARK: - TextKit helpers

    @MainActor
    private func makeLaidOutTextView(attr: NSAttributedString, width: CGFloat, height: CGFloat) -> NSTextView {
        let textStorage = NSTextStorage(attributedString: attr)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: textContainer)
        tv.textContainerInset = NSSize(width: 32, height: 24)
        tv.isEditable = false

        // Force layout.
        layoutManager.ensureLayout(for: textContainer)
        return tv
    }

    @MainActor
    private func firstIndex(with key: NSAttributedString.Key, in textView: NSTextView) -> Int? {
        guard let storage = textView.textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            if (value as? Bool) == true {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    @MainActor
    private func glyphRect(atCharIndex charIndex: Int, in textView: NSTextView) -> NSRect {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return .zero }
        let glyphIndex = lm.glyphIndexForCharacter(at: charIndex)

        var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }
}
