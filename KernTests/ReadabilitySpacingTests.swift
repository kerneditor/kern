import XCTest
@testable import KernTextKit

final class ReadabilitySpacingTests: XCTestCase {
    @MainActor
    func testParagraphsUseComfortableSpacingDefaults() {
        let attr = NativeMarkdownCodec.importMarkdown("Paragraph one\n\nParagraph two\n")
        let ns = attr.string as NSString
        let firstRange = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        guard let style = attr.attribute(.paragraphStyle, at: firstRange.location, effectiveRange: nil) as? NSParagraphStyle else {
            XCTFail("Missing paragraph style")
            return
        }

        XCTAssertGreaterThanOrEqual(style.paragraphSpacingBefore, 5)
        XCTAssertGreaterThanOrEqual(style.paragraphSpacing, 5)
        XCTAssertGreaterThan(style.lineHeightMultiple, 1.0)
    }

    @MainActor
    func testEditorBaseTypingAttributesUseComfortableSpacingDefaults() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "x"

        guard let style = vc.attributedTextForTesting().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            XCTFail("Missing paragraph style after insertion")
            return
        }
        XCTAssertGreaterThanOrEqual(style.paragraphSpacingBefore, 5)
        XCTAssertGreaterThanOrEqual(style.paragraphSpacing, 5)
    }
}
