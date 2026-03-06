import XCTest
@testable import KernTextKit

final class CodeBlockSpacingRegressionTests: XCTestCase {
    @MainActor
    func testCodeBlockParagraphStylesPreserveExternalSpacingAndInternalCompactness() {
        let markdown = """
        Intro paragraph.

        ```swift
        let a = 1
        let b = 2
        ```

        Outro paragraph.
        """

        let attributed = NativeMarkdownCodec.importMarkdown(markdown)
        let ns = attributed.string as NSString

        var codeStyles: [NSParagraphStyle] = []

        var idx = 0
        while idx < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard paraRange.length > 0 else { break }

            let kindRaw = (attributed.attribute(.kernBlockKind, at: paraRange.location, effectiveRange: nil) as? Int)
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .codeBlock {
                let style = attributed.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle
                if let style {
                    codeStyles.append(style)
                }
            }

            idx = paraRange.location + paraRange.length
        }

        guard let firstCodeStyle = codeStyles.first,
              let lastCodeStyle = codeStyles.last else {
            XCTFail("Expected at least one code block paragraph")
            return
        }

        XCTAssertGreaterThanOrEqual(firstCodeStyle.paragraphSpacingBefore, 8)
        XCTAssertEqual(firstCodeStyle.firstLineHeadIndent, 12, accuracy: 0.01)
        XCTAssertEqual(firstCodeStyle.headIndent, 12, accuracy: 0.01)

        if codeStyles.count > 2 {
            for middleStyle in codeStyles.dropFirst().dropLast() {
                XCTAssertEqual(middleStyle.paragraphSpacingBefore, 0, accuracy: 0.01)
                XCTAssertEqual(middleStyle.paragraphSpacing, 0, accuracy: 0.01)
            }
        }

        XCTAssertGreaterThanOrEqual(lastCodeStyle.paragraphSpacing, 8)
        XCTAssertLessThanOrEqual(abs(firstCodeStyle.paragraphSpacingBefore - lastCodeStyle.paragraphSpacing), 2)
    }
}
