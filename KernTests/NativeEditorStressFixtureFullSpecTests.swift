import Foundation
import XCTest
@testable import KernTextKit

/// Full-spec integration tests that exercise the canonical stress fixture end-to-end.
///
/// These tests are gated behind `KERN_ENABLE_EXHAUSTIVE_TESTS=1` because they are intended to
/// fail until "real editor" features (images, blockquotes, math, mermaid, HR, etc.) are implemented.
final class NativeEditorStressFixtureFullSpecTests: XCTestCase {
    @MainActor
    func testStressFixtureImportsAsWysiwygAndExportsStable_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let md = try loadFixture(name: "stress-test.md")
        let attr = NativeMarkdownCodec.importMarkdown(md, options: .init())
        let out = NativeMarkdownCodec.exportMarkdown(attr, options: .init())

        // WYSIWYG: the visible string should not contain literal Markdown syntax for these blocks.
        // This is intentionally "big picture" and complements the per-feature matrices.
        XCTAssertFalse(attr.string.contains("```"), "Fences should be hidden in WYSIWYG")
        XCTAssertFalse(attr.string.contains("| --- |"), "Table delimiter row should not be visible in WYSIWYG")
        XCTAssertFalse(attr.string.contains("![Local sample]("), "Image syntax should not be visible in WYSIWYG")
        XCTAssertFalse(attr.string.contains("```mermaid"), "Mermaid fence syntax should not be visible in WYSIWYG")
        XCTAssertFalse(attr.string.contains("$$"), "Math delimiters should not be visible in WYSIWYG")
        XCTAssertFalse(attr.string.contains("\n---\n"), "Thematic break syntax should not be visible in WYSIWYG")
        XCTAssertFalse(attr.string.contains("> \"The best way"), "Blockquote markers should not be visible in WYSIWYG")

        // Full-spec: images/mermaid/math should be represented as attachments (or equivalent).
        // Minimum 1 ensures "at least images" are supported before this suite can pass.
        XCTAssertGreaterThanOrEqual(countAttachments(in: attr), 1, "Expected at least one attachment from stress-test.md (images/diagrams)")

        // Export should preserve canonical Markdown syntax for the same blocks.
        XCTAssertTrue(out.contains("```mermaid"))
        XCTAssertTrue(out.contains("![Local sample]("))
        XCTAssertTrue(out.contains("$$"))
        XCTAssertTrue(out.contains("\n---\n"))
        XCTAssertTrue(out.contains("> \"The best way"))
    }

    // MARK: - Helpers

    private func loadFixture(name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func countAttachments(in attr: NSAttributedString) -> Int {
        var n = 0
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, _, _ in
            if value != nil { n += 1 }
        }
        return n
    }
}

