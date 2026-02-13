import XCTest
@testable import KernTextKit

/// Full-spec tests for Markdown features the native TextKit codec must support for a "real" editor.
///
/// These are gated behind `KERN_ENABLE_EXHAUSTIVE_TESTS=1` and are intentionally allowed to FAIL
/// until the corresponding features are implemented (so we don't end up with "green tests, broken app").
final class NativeMarkdownCodecFutureSpecTests: XCTestCase {
    @MainActor
    func testBlockquoteRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        > quote line 1
        > quote line 2
        """
        let attr = NativeMarkdownCodec.importMarkdown(md)

        // A true WYSIWYG import should hide the literal `> ` markers.
        XCTAssertEqual(attr.string.trimmingCharacters(in: .whitespacesAndNewlines), "quote line 1\nquote line 2")

        // Export should preserve blockquote syntax.
        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), md)
    }

    @MainActor
    func testThematicBreakRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        Before

        ---

        After
        """
        let attr = NativeMarkdownCodec.importMarkdown(md)

        // WYSIWYG should render the rule without leaving the raw `---` in the visible text.
        XCTAssertFalse(attr.string.contains("---"))

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("---"))
    }

    @MainActor
    func testImagesRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = "![alt](https://example.com/image.png)"
        let attr = NativeMarkdownCodec.importMarkdown(md)

        // A native WYSIWYG import should not show the raw image syntax; it should create an attachment
        // or a non-syntax placeholder.
        XCTAssertFalse(attr.string.contains("![alt]("))
        var hasAttachment = false
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, _, stop in
            if value != nil {
                hasAttachment = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(hasAttachment)

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("![alt]("))
    }

    @MainActor
    func testStrikethroughRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = "This is ~~deleted~~ text."
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let ns = attr.string as NSString
        let r = ns.range(of: "deleted")
        XCTAssertNotEqual(r.location, NSNotFound)

        // WYSIWYG should apply strikethrough style rather than showing `~~`.
        let style = attr.attribute(.strikethroughStyle, at: r.location, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("~~deleted~~"))
    }

    @MainActor
    func testAutolinksRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = "Visit <https://example.com>."
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let ns = attr.string as NSString
        let r = ns.range(of: "https://example.com")
        XCTAssertNotEqual(r.location, NSNotFound)

        // WYSIWYG should apply a link attribute, not just leave literal `<` `>` markers.
        let link = attr.attribute(.link, at: r.location, effectiveRange: nil)
        XCTAssertNotNil(link)

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("<https://example.com>"))
    }

    @MainActor
    func testNestedListsRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        - one
          - nested
        - two
        """
        let attr = NativeMarkdownCodec.importMarkdown(md)

        // WYSIWYG should render nested list markers as bullets, not leave raw `- ` visible.
        XCTAssertFalse(attr.string.contains("- nested"))
        XCTAssertTrue(attr.string.contains("nested"))

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("nested"))
    }

    @MainActor
    func testNestedOrderedListsRenderWithDepthAwareMarkers_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        1. Top
           1. Nested
        2. Top2
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)

        // Full-spec: nested ordered lists should be represented as nested list items in WYSIWYG.
        // For readability, we want depth-aware marker styles (Notion-like): 1. -> a. -> i. ...
        XCTAssertTrue(attr.string.contains("1. Top"))
        XCTAssertTrue(attr.string.contains("a. Nested"), "Nested ordered items should render with a letter marker at depth 1")

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("1. Top"))
        XCTAssertTrue(out.contains("   1. Nested"))
        XCTAssertTrue(out.contains("2. Top2"))
    }

    @MainActor
    func testMathInlineAndBlockRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        Inline math $E = mc^2$ should render.

        $$
        \\int_0^1 x^2 \\, dx
        $$
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)

        // Full-spec: WYSIWYG should hide raw `$` delimiters (render math as a semantic unit).
        XCTAssertFalse(attr.string.contains("$E = mc^2$"))
        XCTAssertFalse(attr.string.contains("$$"))

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("$E = mc^2$"))
        XCTAssertTrue(out.contains("$$"))
    }

    @MainActor
    func testMermaidFenceRendersAsDiagramAndExportsMarkdown() throws {
        try TestGates.skipUnlessExhaustive()

        let md = """
        ```mermaid
        graph TD
          A[Start] --> B{Decision}
          B -->|Yes| C[OK]
          B -->|No| D[Retry]
        ```
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)

        // Full-spec: mermaid blocks should be rendered as a diagram attachment (or other non-syntax placeholder),
        // not shown as raw mermaid source in the editor.
        var hasAttachment = false
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, _, stop in
            if value != nil {
                hasAttachment = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(hasAttachment, "Expected mermaid to render as an attachment/diagram placeholder")

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("```mermaid"))
        XCTAssertTrue(out.contains("graph TD"))
        XCTAssertTrue(out.contains("```"))
    }
}
