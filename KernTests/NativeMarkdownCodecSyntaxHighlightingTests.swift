import AppKit
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecSyntaxHighlightingTests: XCTestCase {
    @MainActor
    func testSyntaxHighlighting_ProvidesMultipleColorsForCommonLanguages() {
        let cases: [(name: String, markdown: String)] = [
            (
                "javascript",
                """
                ```javascript
                // comment
                function greet(name) { return \"hi\" + name }
                console.log(2)
                ```
                """
            ),
            (
                "python",
                """
                ```python
                # comment
                def fibonacci(n: int) -> list[int]:
                    \"\"\"Generate Fibonacci sequence.\"\"\"
                    return [0, 1, 2]
                print(fibonacci(10))
                ```
                """
            ),
            (
                "typescript",
                """
                ```typescript
                interface EditorConfig { theme: \"light\" | \"dark\" }
                const x: number = 2
                ```
                """
            ),
            (
                "bash",
                """
                ```bash
                # comment
                for file in *.md; do
                  echo \"Processing: $file\"
                done
                ```
                """
            ),
        ]

        for (name, md) in cases {
            let attr = NativeMarkdownCodec.importMarkdown(md)
            guard let range = firstCodeBlockRange(in: attr) else {
                XCTFail("(\(name)) missing code-block range")
                continue
            }

            XCTAssertTrue(hasMultipleForegroundColors(attr: attr, range: range), "(\(name)) expected multiple foreground colors for syntax highlighting")
        }
    }

    private func firstCodeBlockRange(in attr: NSAttributedString) -> NSRange? {
        guard attr.length > 0 else { return nil }
        var start: Int?
        var end: Int?
        for i in 0..<attr.length {
            let kindRaw = attr.attribute(.kernBlockKind, at: i, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .codeBlock {
                if start == nil { start = i }
                end = i
            } else if start != nil {
                break
            }
        }
        guard let s = start, let e = end else { return nil }
        return NSRange(location: s, length: max(0, e - s + 1))
    }

    private func hasMultipleForegroundColors(attr: NSAttributedString, range: NSRange) -> Bool {
        guard range.location + range.length <= attr.length else { return false }
        var colors = Set<NSColor>()
        attr.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
            if let c = value as? NSColor {
                colors.insert(c)
            }
        }
        return colors.count >= 2
    }
}

