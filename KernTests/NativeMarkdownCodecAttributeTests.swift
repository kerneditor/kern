import AppKit
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecAttributeTests: XCTestCase {
    @MainActor
    func testCheckboxAttributesAndCheckedStyle() {
        let md = "[x] done"
        let attr = NativeMarkdownCodec.importMarkdown(md)

        // Find the checkbox glyph.
        let ns = attr.string as NSString
        var checkboxIndex: Int?
        for i in 0..<ns.length {
            if (attr.attribute(.kernCheckbox, at: i, effectiveRange: nil) as? Bool) == true {
                checkboxIndex = i
                break
            }
        }
        guard let checkboxIndex else {
            XCTFail("No checkbox glyph found")
            return
        }

        XCTAssertEqual(ns.substring(with: NSRange(location: checkboxIndex, length: 1)), "☑")

        let checked = (attr.attribute(.kernCheckboxChecked, at: checkboxIndex, effectiveRange: nil) as? Bool) ?? false
        XCTAssertTrue(checked)

        // Checkbox should be slightly larger for visibility.
        let font = attr.attribute(.font, at: checkboxIndex, effectiveRange: nil) as? NSFont
        XCTAssertEqual(Double(font?.pointSize ?? 0), 20, accuracy: 0.01)

        let baseline = attr.attribute(.baselineOffset, at: checkboxIndex, effectiveRange: nil) as? NSNumber
        XCTAssertNotNil(baseline, "Checkbox glyph should have a baseline offset applied")

        // Baseline offset is computed dynamically from font metrics. Validate it matches the current
        // algorithm rather than hard-coding a magic constant.
        let doneRange = ns.range(of: "done")
        XCTAssertNotEqual(doneRange.location, NSNotFound)
        let textFont = (doneRange.location != NSNotFound)
            ? (attr.attribute(.font, at: doneRange.location, effectiveRange: nil) as? NSFont)
            : nil
        let expected = CheckboxStyle.baselineOffset(
            textFont: textFont ?? NSFont.systemFont(ofSize: 16),
            checkboxFont: font ?? CheckboxStyle.preferredFont(pointSize: 20)
        )
        XCTAssertEqual(baseline?.doubleValue ?? 0, Double(expected), accuracy: 0.01)

        // Body should be struck through when checked.
        var sawStrike = false
        attr.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: attr.length), options: []) { value, range, _ in
            guard let value else { return }
            if range.length > 0, (value as? Int) == NSUnderlineStyle.single.rawValue {
                sawStrike = true
            }
        }
        XCTAssertTrue(sawStrike)
    }

    @MainActor
    func testOnlyCheckedItemsAreStruckThroughAcrossTaskVariants() {
        let md = """
        - [x] BULLET_CHECKED
        - [ ] BULLET_UNCHECKED
        1. [x] ORDERED_CHECKED
        2. [ ] ORDERED_UNCHECKED
        ## [x] HEADING_CHECKED
        ## [ ] HEADING_UNCHECKED
        """
        var options = NativeMarkdownCodec.Options()
        options.orderedTasksEnabled = true
        options.headingCheckboxesEnabled = true

        let attr = NativeMarkdownCodec.importMarkdown(md, options: options)

        XCTAssertTrue(hasSingleStrike(attr, token: "BULLET_CHECKED"))
        XCTAssertFalse(hasSingleStrike(attr, token: "BULLET_UNCHECKED"))

        XCTAssertTrue(hasSingleStrike(attr, token: "ORDERED_CHECKED"))
        XCTAssertFalse(hasSingleStrike(attr, token: "ORDERED_UNCHECKED"))

        XCTAssertTrue(hasSingleStrike(attr, token: "HEADING_CHECKED"))
        XCTAssertFalse(hasSingleStrike(attr, token: "HEADING_UNCHECKED"))
    }

    @MainActor
    func testCheckedChildInsideUncheckedParentIsStruckThroughButParentIsNot() {
        let md = """
        - [ ] PARENT_UNCHECKED
           - [x] CHILD_CHECKED
           - [ ] CHILD_UNCHECKED
        """
        let attr = NativeMarkdownCodec.importMarkdown(md)

        XCTAssertFalse(hasSingleStrike(attr, token: "PARENT_UNCHECKED"))
        XCTAssertTrue(hasSingleStrike(attr, token: "CHILD_CHECKED"))
        XCTAssertFalse(hasSingleStrike(attr, token: "CHILD_UNCHECKED"))
    }

    @MainActor
    func testHeadingInlineCodeUsesMonospacedFontAtHeadingSize() {
        let md = "# Heading `Code` text\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let ns = attr.string as NSString

        let headingRange = ns.range(of: "Heading")
        let codeRange = ns.range(of: "Code")
        XCTAssertNotEqual(headingRange.location, NSNotFound)
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        guard headingRange.location != NSNotFound, codeRange.location != NSNotFound else { return }

        let headingFont = attr.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        let codeFont = attr.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertNotNil(codeFont)
        guard let headingFont, let codeFont else { return }

        XCTAssertEqual(codeFont.pointSize, headingFont.pointSize, accuracy: 0.01, "Inline code in headings should keep heading size")
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace), "Inline code should remain monospaced inside headings")
    }

    @MainActor
    func testHeadingInlineEmphasisRetainsHeadingScale() {
        let md = "## Plain **Bold** *Italic*\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let ns = attr.string as NSString

        let plainRange = ns.range(of: "Plain")
        let boldRange = ns.range(of: "Bold")
        let italicRange = ns.range(of: "Italic")
        guard plainRange.location != NSNotFound, boldRange.location != NSNotFound, italicRange.location != NSNotFound else {
            XCTFail("Expected heading text tokens to exist in attributed output")
            return
        }

        let plainFont = attr.attribute(.font, at: plainRange.location, effectiveRange: nil) as? NSFont
        let boldFont = attr.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let italicFont = attr.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(plainFont)
        XCTAssertNotNil(boldFont)
        XCTAssertNotNil(italicFont)
        guard let plainFont, let boldFont, let italicFont else { return }

        XCTAssertEqual(boldFont.pointSize, plainFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(italicFont.pointSize, plainFont.pointSize, accuracy: 0.01)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.italic))
    }

    @MainActor
    func testCodeFenceStoresFullInfoStringSeparatelyFromLanguageToken() {
        let md = """
        ```typescript title=\"editor-config\" linenums=on
        interface EditorConfig { theme: string }
        ```
        """
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let ns = attr.string as NSString
        let tokenRange = ns.range(of: "interface")
        XCTAssertNotEqual(tokenRange.location, NSNotFound)
        guard tokenRange.location != NSNotFound else { return }

        let language = attr.attribute(.kernCodeLanguage, at: tokenRange.location, effectiveRange: nil) as? String
        let infoString = attr.attribute(.kernCodeFenceInfoString, at: tokenRange.location, effectiveRange: nil) as? String

        XCTAssertEqual(language, "typescript")
        XCTAssertEqual(infoString, "typescript title=\"editor-config\" linenums=on")
    }

    private func hasSingleStrike(_ attr: NSAttributedString, token: String) -> Bool {
        let ns = attr.string as NSString
        let range = ns.range(of: token)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing token in rendered text: \(token)")
        guard range.location != NSNotFound else { return false }

        var sawSingle = false
        attr.enumerateAttribute(.strikethroughStyle, in: range, options: []) { value, _, stop in
            guard let intValue = value as? Int else { return }
            if intValue == NSUnderlineStyle.single.rawValue {
                sawSingle = true
                stop.pointee = true
            }
        }
        return sawSingle
    }
}
