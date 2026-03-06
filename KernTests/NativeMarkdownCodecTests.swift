import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecTests: XCTestCase {
    @MainActor
    func testRoundTripBasic() {
        let md = """
        # Title

        - [x] done
        - [ ] todo

        Paragraph with **bold** and *italic* and `code`.

        ```js
        console.log("hi")
        ```
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("# Title"))
        XCTAssertTrue(out.contains("- [x] done"))
        XCTAssertTrue(out.contains("- [ ] todo"))
        XCTAssertTrue(out.contains("**bold**"))
        XCTAssertTrue(out.contains("*italic*"))
        XCTAssertTrue(out.contains("`code`"))
        XCTAssertTrue(out.contains("```js"))
        XCTAssertTrue(out.contains("console.log(\"hi\")"))
        XCTAssertTrue(out.contains("```"))
    }

    @MainActor
    func testTodoShortcutExportsAsGfmTaskList() {
        let md = """
        [] first
        [x] second
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("- [ ] first"))
        XCTAssertTrue(out.contains("- [x] second"))
    }

    @MainActor
    func testOrderedListRoundTrip() {
        let md = """
        1. one
        2. two

        10. ten
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("1. one"))
        XCTAssertTrue(out.contains("2. two"))
        XCTAssertTrue(out.contains("10. ten"))
    }

    @MainActor
    func testTablesRoundTrip_Gfm() {
        let md = """
        | Left | Center | Right |
        | :--- | :---: | ---: |
        | a | b | c |
        | escaped \\| pipe | `code|span` | **bold** |
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), md)
    }

    @MainActor
    func testFencedCodeInfoStringRoundTripsWithoutLosingMetadata() {
        let md = """
        ```typescript title=\"editor-config\" linenums=on
        interface EditorConfig { theme: string }
        ```
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(
            out.contains("```typescript title=\"editor-config\" linenums=on"),
            "Fenced code export should preserve the full authored info string"
        )
    }

    @MainActor
    func testReferenceDefinitionInsideBlockquote() {
        let md = """
        > [id]: https://example.com "Title"
        >
        > Click [here][id].
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        // The reference link should resolve — export should contain the actual URL
        XCTAssertTrue(out.contains("https://example.com"), "Reference definition inside blockquote should resolve")
    }

    @MainActor
    func testReferenceDefinitionInsideNestedBlockquote() {
        let md = """
        > > [nested]: https://nested.example.com
        > >
        > > See [nested].
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("https://nested.example.com"), "Reference definition inside nested blockquote should resolve")
    }

    @MainActor
    func testInlineRelativeLinkResolvesAgainstBaseURLForNavigation() {
        let md = "[Guide](docs/guide.md)\n"
        let baseURL = URL(fileURLWithPath: "/tmp/kern/current.md")

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: baseURL)
        let ns = attr.string as NSString
        let range = ns.range(of: "Guide")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        guard let link = attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL else {
            return XCTFail("Expected URL .link attribute for relative markdown link")
        }
        XCTAssertTrue(link.isFileURL, "Relative markdown links should resolve to file URLs when baseURL is available")
        XCTAssertEqual(link.standardizedFileURL.path, "/tmp/kern/docs/guide.md")
    }

    @MainActor
    func testInlineAnchorLinkRemainsAnchorURLForInDocumentJumpHandling() {
        let md = "[Jump](#section-1)\n"
        let baseURL = URL(fileURLWithPath: "/tmp/kern/current.md")

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: baseURL)
        let ns = attr.string as NSString
        let range = ns.range(of: "Jump")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        guard let link = attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL else {
            return XCTFail("Expected URL .link attribute for anchor markdown link")
        }
        XCTAssertNil(link.scheme, "In-document anchors should remain fragment URLs so anchor navigation handles them")
        XCTAssertEqual(link.fragment, "section-1")
    }

    @MainActor
    func testInlineBareDomainLinkNormalizesToHTTPSForNavigation() {
        let md = "[Link](example.com)\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let ns = attr.string as NSString
        let range = ns.range(of: "Link")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        guard let link = attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL else {
            return XCTFail("Expected URL .link attribute for bare-domain markdown link")
        }
        XCTAssertEqual(link.scheme?.lowercased(), "https")
        XCTAssertEqual(link.host?.lowercased(), "example.com")

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("[Link](example.com)"), "Export should preserve the user's original markdown destination")
    }

    @MainActor
    func testImportNormalizesCRLFAndCRLineEndings() {
        let crlf = "# Title\r\n\r\n- [ ] one\r\n- [ ] two\r\n"
        let cr = "# Title\r\r- [ ] one\r- [ ] two\r"

        let crlfAttr = NativeMarkdownCodec.importMarkdown(crlf)
        let crAttr = NativeMarkdownCodec.importMarkdown(cr)

        let crlfOut = NativeMarkdownCodec.exportMarkdown(crlfAttr)
        let crOut = NativeMarkdownCodec.exportMarkdown(crAttr)

        XCTAssertFalse(crlfOut.contains("\r"), "Export should normalize CRLF input to LF")
        XCTAssertFalse(crOut.contains("\r"), "Export should normalize CR input to LF")
        XCTAssertTrue(crlfOut.contains("Title"))
        XCTAssertTrue(crlfOut.contains("- [ ] one"))
        XCTAssertTrue(crOut.contains("- [ ] two"))
    }

    @MainActor
    func testExportUsesBlankLineBetweenParagraphBlocksByDefault() {
        let md = "First paragraph\nSecond paragraph\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertEqual(out, "First paragraph\n\nSecond paragraph\n")
    }

    @MainActor
    func testExportKeepsTightListItemsWithSingleNewlineByDefault() {
        let md = "- one\n- two\n- three\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertEqual(out, "- one\n- two\n- three\n")
    }

    @MainActor
    func testExportCanDisableParagraphBlockSeparation() {
        let md = "First paragraph\nSecond paragraph\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        var options = NativeMarkdownCodec.Options()
        options.paragraphBlockSeparationEnabled = false

        let out = NativeMarkdownCodec.exportMarkdown(attr, options: options)
        XCTAssertEqual(out, "First paragraph\nSecond paragraph\n")
    }
}
