import AppKit
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
    func testInlineAbsoluteLocalLinkStaysUnresolvedForNavigation() {
        let md = "[Secret](/etc/passwd)\n"

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: URL(fileURLWithPath: "/tmp/kern/current.md"))
        let ns = attr.string as NSString
        let range = ns.range(of: "Secret")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
            "Absolute local markdown links should not become clickable file URLs"
        )
        XCTAssertEqual(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? String,
            "/etc/passwd",
            "Absolute local markdown links should preserve raw destination semantics for round-trip without resolving to a file URL"
        )
        XCTAssertEqual(
            NativeMarkdownCodec.exportMarkdown(attr),
            md,
            "Absolute local markdown links should still round-trip through markdown export"
        )
    }

    @MainActor
    func testInlineTildeLocalLinkStaysUnresolvedForNavigation() {
        let md = "[Home](~/Documents/private.md)\n"

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: URL(fileURLWithPath: "/tmp/kern/current.md"))
        let ns = attr.string as NSString
        let range = ns.range(of: "Home")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
            "Tilde local markdown links should not become clickable file URLs"
        )
        XCTAssertEqual(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? String,
            "~/Documents/private.md",
            "Tilde local markdown links should preserve raw destination semantics for round-trip without resolving to a file URL"
        )
        XCTAssertEqual(
            NativeMarkdownCodec.exportMarkdown(attr),
            md,
            "Tilde local markdown links should still round-trip through markdown export"
        )
    }

    @MainActor
    func testInlineRelativeTraversalLinkOutsideDocumentRootStaysUnresolved() {
        let md = "[Escape](../secret.md)\n"
        let baseURL = URL(fileURLWithPath: "/tmp/kern/docs/current.md")

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: baseURL)
        let ns = attr.string as NSString
        let range = ns.range(of: "Escape")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
            "Relative traversal outside the document root should not become a clickable file URL"
        )
        XCTAssertEqual(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? String,
            "../secret.md",
            "Out-of-root relative links should preserve raw destination semantics for round-trip without resolving to a file URL"
        )
        XCTAssertEqual(
            NativeMarkdownCodec.exportMarkdown(attr),
            md,
            "Out-of-root relative links should still round-trip through markdown export"
        )
    }

    @MainActor
    func testInlineRelativeSymlinkLinkOutsideDocumentRootStaysUnresolved() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-link-symlink-\(UUID().uuidString)", isDirectory: true)
        let docsDir = tempDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outsideFile = tempDir.appendingPathComponent("secret.md", isDirectory: false)
        try "# secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkURL = docsDir.appendingPathComponent("inside.md", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        let baseURL = docsDir.appendingPathComponent("current.md", isDirectory: false)
        let md = "[Escape](./inside.md)\n"

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: baseURL)
        let ns = attr.string as NSString
        let range = ns.range(of: "Escape")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
            "Symlinked relative markdown links that escape the document root should not become clickable file URLs"
        )
        XCTAssertEqual(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? String,
            "./inside.md",
            "Symlink-escape links should preserve raw destination semantics for round-trip without resolving to a file URL"
        )
        XCTAssertEqual(
            NativeMarkdownCodec.exportMarkdown(attr),
            md,
            "Symlink-escape links should still round-trip through markdown export"
        )
    }

    @MainActor
    func testInlineRelativeSymlinkLinkInsideDocumentRootStillResolves() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-link-symlink-safe-\(UUID().uuidString)", isDirectory: true)
        let docsDir = tempDir.appendingPathComponent("docs", isDirectory: true)
        let assetsDir = docsDir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realFile = assetsDir.appendingPathComponent("safe.md", isDirectory: false)
        try "# safe".write(to: realFile, atomically: true, encoding: .utf8)

        let symlinkURL = docsDir.appendingPathComponent("inside.md", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realFile)

        let baseURL = docsDir.appendingPathComponent("current.md", isDirectory: false)
        let md = "[Safe](./inside.md)\n"

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: baseURL)
        let ns = attr.string as NSString
        let range = ns.range(of: "Safe")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        guard let link = attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL else {
            return XCTFail("Expected clickable file URL for in-root symlink target")
        }
        XCTAssertTrue(link.isFileURL)
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
    func testInlineCustomSchemeLinkStaysUnresolvedForNavigation() {
        let md = "[Prefs](x-apple.systempreferences:com.apple.preference.security)\n"

        let attr = NativeMarkdownCodec.importMarkdown(md, baseURL: URL(fileURLWithPath: "/tmp/kern/current.md"))
        let ns = attr.string as NSString
        let range = ns.range(of: "Prefs")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
            "Custom-scheme markdown links should not become clickable navigation targets"
        )
        XCTAssertEqual(
            attr.attribute(.link, at: range.location, effectiveRange: nil) as? String,
            "x-apple.systempreferences:com.apple.preference.security",
            "Custom-scheme markdown links should preserve raw destination semantics for round-trip without becoming a navigable URL"
        )
        XCTAssertEqual(
            NativeMarkdownCodec.exportMarkdown(attr),
            md,
            "Custom-scheme markdown links should still round-trip through markdown export"
        )
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

    @MainActor
    func testParagraphBoundaryMemoizationPreservesTableBoundary() {
        let md = """
        Intro line
        still intro
        | A | B |
        | --- | --- |
        | 1 | 2 |
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("Intro line"))
        XCTAssertTrue(out.contains("still intro"))
        XCTAssertTrue(out.contains("| A | B |"))
        XCTAssertTrue(out.contains("| --- | --- |"))
        XCTAssertTrue(out.contains("| 1 | 2 |"))
    }

    @MainActor
    func testParagraphBoundaryMemoizationKeepsNestedBlockquoteSeparate() {
        let md = """
        > first line
        > second line
        > > nested quote
        > back to outer
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("> first line"))
        XCTAssertTrue(out.contains("> second line"))
        XCTAssertTrue(out.contains("> > nested quote"))
        XCTAssertTrue(out.contains("> back to outer"))
    }

    @MainActor
    func testParagraphAndListContinuationsPreserveHardBreakSemanticsAfterBuilderRefactor() {
        let md = """
        paragraph tail\\
        next line

        - bullet tail\\
          next bullet line
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("paragraph tail\\\nnext line"))
        XCTAssertTrue(out.contains("- bullet tail\\\n  next bullet line"))
    }

    @MainActor
    func testSingleLineParagraphRetainsTerminalHardBreakMarkerAfterFastPath() {
        let md = "paragraph tail\\\\\n"

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("paragraph tail\\\\"))
    }

    @MainActor
    func testSingleLineParagraphFastPathPreservesHardBreakMarkersAtEOFBlankAndBoundary() {
        let cases: [(markdown: String, expectedSnippet: String)] = [
            ("tail\\\\\n", "tail\\\\"),
            ("tail  \n\nnext\n", "tail  \n\nnext"),
            ("tail\t\n# heading\n", "tail\t\n\n# heading")
        ]

        for testCase in cases {
            let attr = NativeMarkdownCodec.importMarkdown(testCase.markdown)
            let out = NativeMarkdownCodec.exportMarkdown(attr)
            XCTAssertTrue(
                out.contains(testCase.expectedSnippet),
                "Expected exported markdown to preserve hard-break marker context for: \(testCase.markdown.debugDescription)"
            )
        }
    }

    @MainActor
    func testSingleLineParagraphFastPathPreservesQuoteBoundaryWithTerminalHardBreak() {
        let md = """
        > quote tail\\
        plain
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        let nonEmptyLines = out.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(nonEmptyLines.count, 2)
        XCTAssertTrue(nonEmptyLines[0].hasPrefix("> quote tail"))
        XCTAssertEqual(nonEmptyLines.last, "plain")
    }

    @MainActor
    func testStrictModeSingleLineParagraphDoesNotStripTerminalHardBreakMarker() {
        var options = NativeMarkdownCodec.Options.fromUserDefaults()
        options.strictConformanceRoundTripMode = true
        let md = "strict tail\\\\\n"

        let attr = NativeMarkdownCodec.importMarkdown(md, options: options)
        let out = NativeMarkdownCodec.exportMarkdown(attr, options: options)

        XCTAssertTrue(out.contains("strict tail\\\\"))
    }

    @MainActor
    func testSingleLineParagraphFastPathPreservesRichReferenceLinkAttributes() {
        let markdown = "[alpha *beta*][docs]\n\n[docs]: https://example.com/ref"
        let attr = NativeMarkdownCodec.importMarkdown(markdown)

        let ns = attr.string as NSString
        let alphaRange = ns.range(of: "alpha")
        let betaRange = ns.range(of: "beta")
        XCTAssertNotEqual(alphaRange.location, NSNotFound)
        XCTAssertNotEqual(betaRange.location, NSNotFound)
        guard alphaRange.location != NSNotFound, betaRange.location != NSNotFound else { return }

        let alphaLink = attr.attribute(.link, at: alphaRange.location, effectiveRange: nil) as? URL
        let betaLink = attr.attribute(.link, at: betaRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(alphaLink?.absoluteString, "https://example.com/ref")
        XCTAssertEqual(betaLink?.absoluteString, "https://example.com/ref")
        XCTAssertEqual(attr.attribute(.kernLinkReferenceID, at: betaRange.location, effectiveRange: nil) as? String, "docs")
        XCTAssertEqual(attr.attribute(.kernLinkReferenceURL, at: betaRange.location, effectiveRange: nil) as? String, "https://example.com/ref")
        XCTAssertEqual(attr.attribute(.kernEmphasis, at: betaRange.location, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testUnbalancedBackticksKeepTrailingSpacesLiteralInsteadOfBecomingHardBreak() {
        let md = "`unterminated code" + String(repeating: " ", count: 2) + "\nnext line"

        let attr = NativeMarkdownCodec.importMarkdown(md)
        XCTAssertFalse(
            attr.string.contains("\u{2028}"),
            "Odd backtick parity should keep the line as a normal paragraph continuation, not convert it into a hard break"
        )
        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("`unterminated code  "))
        XCTAssertFalse(out.contains("`unterminated code\\\n"))
    }

    @MainActor
    func testWhitespaceOnlyBlankLineStillSeparatesParagraphs() {
        let md = "first paragraph\n \t \nsecond paragraph\n"

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertEqual(out, "first paragraph\n\nsecond paragraph\n")
    }

    @MainActor
    func testTopLevelParagraphContinuationPreservesTrailingSpaceHardBreakMarker() {
        let md = "first line" + String(repeating: " ", count: 2) + "\nsecond line"

        let attr = NativeMarkdownCodec.importMarkdown(md)
        XCTAssertTrue(attr.string.contains("first line"))
        XCTAssertTrue(attr.string.contains("second line"))
        XCTAssertTrue(attr.string.contains("\u{2028}"))

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertEqual(out, "first line\\\nsecond line")
    }

    @MainActor
    func testInlineHtmlBreakRendersAsLineSeparatorAndRoundTripsSource() {
        let md = "alpha<br />beta"

        let attr = NativeMarkdownCodec.importMarkdown(md)

        XCTAssertEqual(attr.string, "alpha\u{2028}beta")
        XCTAssertFalse(attr.string.contains("<br"))
        XCTAssertEqual(NativeMarkdownCodec.exportMarkdown(attr), md)
    }

    @MainActor
    func testInlineHtmlBreakVariantsRenderAsLineSeparators() {
        let parsed = NativeMarkdownCodec.parseInline(
            "one<br>two<BR/>three<br />four",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "one\u{2028}two\u{2028}three\u{2028}four")
        XCTAssertFalse(parsed.string.contains("<br"))
        XCTAssertEqual(NativeMarkdownCodec.exportMarkdown(parsed), "one<br>two<BR/>three<br />four")
    }

    @MainActor
    func testListPlaceholderHtmlBreakDoesNotRenderRawTag() {
        let md = """
        - <br />

          1. [x] Nested checked
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)

        XCTAssertFalse(attr.string.contains("<br"))
        XCTAssertTrue(attr.string.contains("\u{2028}"))
        XCTAssertTrue(attr.string.contains("Nested checked"))
        XCTAssertTrue(NativeMarkdownCodec.exportMarkdown(attr).contains("- <br />"))
    }

    @MainActor
    func testParseInlineIntrawordUnderscoresStayLiteral() {
        let parsed = NativeMarkdownCodec.parseInline(
            "foo_bar_baz",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "foo_bar_baz")
        XCTAssertNil(parsed.attribute(.kernEmphasis, at: 3, effectiveRange: nil))
        XCTAssertNil(parsed.attribute(.kernStrong, at: 3, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineNestedStrongAndEmphasisPreserveSubrangeAttributes() {
        let parsed = NativeMarkdownCodec.parseInline(
            "**alpha _beta_ gamma**",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "alpha beta gamma")

        let ns = parsed.string as NSString
        let alphaRange = ns.range(of: "alpha")
        let betaRange = ns.range(of: "beta")
        let gammaRange = ns.range(of: "gamma")
        XCTAssertNotEqual(alphaRange.location, NSNotFound)
        XCTAssertNotEqual(betaRange.location, NSNotFound)
        XCTAssertNotEqual(gammaRange.location, NSNotFound)
        guard alphaRange.location != NSNotFound,
              betaRange.location != NSNotFound,
              gammaRange.location != NSNotFound else { return }

        XCTAssertEqual(parsed.attribute(.kernStrong, at: alphaRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(parsed.attribute(.kernStrong, at: betaRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(parsed.attribute(.kernStrong, at: gammaRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(parsed.attribute(.kernEmphasis, at: alphaRange.location, effectiveRange: nil))
        XCTAssertEqual(parsed.attribute(.kernEmphasis, at: betaRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(parsed.attribute(.kernEmphasis, at: gammaRange.location, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineUnderscoreEmphasisRecognizesASCIIParenthesisBoundaries() {
        let parsed = NativeMarkdownCodec.parseInline(
            "(_foo_)",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "(foo)")

        let ns = parsed.string as NSString
        let fooRange = ns.range(of: "foo")
        XCTAssertNotEqual(fooRange.location, NSNotFound)
        guard fooRange.location != NSNotFound else { return }

        XCTAssertEqual(parsed.attribute(.kernEmphasis, at: fooRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(parsed.attribute(.kernStrong, at: fooRange.location, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineUnderscoreEmphasisRecognizesUnicodePunctuationBoundaries() {
        let parsed = NativeMarkdownCodec.parseInline(
            "“_foo_”",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "“foo”")

        let ns = parsed.string as NSString
        let fooRange = ns.range(of: "foo")
        XCTAssertNotEqual(fooRange.location, NSNotFound)
        guard fooRange.location != NSNotFound else { return }

        XCTAssertEqual(parsed.attribute(.kernEmphasis, at: fooRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(parsed.attribute(.kernStrong, at: fooRange.location, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineNestedLinkLabelPreservesSingleLinkAndNestedEmphasis() {
        let parsed = NativeMarkdownCodec.parseInline(
            "[alpha *beta*](https://example.com/docs)",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "alpha beta")

        let ns = parsed.string as NSString
        let alphaRange = ns.range(of: "alpha")
        let betaRange = ns.range(of: "beta")
        XCTAssertNotEqual(alphaRange.location, NSNotFound)
        XCTAssertNotEqual(betaRange.location, NSNotFound)
        guard alphaRange.location != NSNotFound, betaRange.location != NSNotFound else { return }

        let alphaLink = parsed.attribute(.link, at: alphaRange.location, effectiveRange: nil) as? URL
        let betaLink = parsed.attribute(.link, at: betaRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(alphaLink?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(betaLink?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(
            parsed.attribute(.kernLinkDestination, at: betaRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertEqual(parsed.attribute(.kernEmphasis, at: betaRange.location, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testParseInlineReferenceLinkRichLabelPreservesSingleLinkAndNestedEmphasis() {
        let markdown = "[alpha *beta*][docs]\n\n[docs]: https://example.com/ref"
        let attr = NativeMarkdownCodec.importMarkdown(markdown)
        let exported = NativeMarkdownCodec.exportMarkdown(attr)
        let reparsed = NativeMarkdownCodec.importMarkdown(exported)

        let ns = reparsed.string as NSString
        let alphaRange = ns.range(of: "alpha")
        let betaRange = ns.range(of: "beta")
        XCTAssertNotEqual(alphaRange.location, NSNotFound)
        XCTAssertNotEqual(betaRange.location, NSNotFound)
        guard alphaRange.location != NSNotFound, betaRange.location != NSNotFound else { return }

        let alphaLink = reparsed.attribute(.link, at: alphaRange.location, effectiveRange: nil) as? URL
        let betaLink = reparsed.attribute(.link, at: betaRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(alphaLink?.absoluteString, "https://example.com/ref")
        XCTAssertEqual(betaLink?.absoluteString, "https://example.com/ref")
        XCTAssertEqual(
            reparsed.attribute(.kernLinkReferenceID, at: betaRange.location, effectiveRange: nil) as? String,
            "docs"
        )
        XCTAssertEqual(
            reparsed.attribute(.kernLinkReferenceURL, at: betaRange.location, effectiveRange: nil) as? String,
            "https://example.com/ref"
        )
        XCTAssertEqual(reparsed.attribute(.kernEmphasis, at: betaRange.location, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testParseInlineDoubleBacktickCodeSpanPreservesOriginalSourceMarkdown() {
        let parsed = NativeMarkdownCodec.parseInline(
            "prefix ``code `tick` span`` suffix",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        let ns = parsed.string as NSString
        let codeRange = ns.range(of: "code `tick` span")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        guard codeRange.location != NSNotFound else { return }

        XCTAssertEqual(parsed.attribute(.kernInlineCode, at: codeRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(
            parsed.attribute(.kernSourceMarkdown, at: codeRange.location, effectiveRange: nil) as? String,
            "``code `tick` span``"
        )
    }

    @MainActor
    func testParseInlineCodeSpanNormalizesCRLFToSingleSpaceAndTrimsOneOuterSpace() {
        let parsed = NativeMarkdownCodec.parseInline(
            "prefix `` foo\r\nbar `` suffix",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        let ns = parsed.string as NSString
        let codeRange = ns.range(of: "foo")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        guard codeRange.location != NSNotFound else { return }

        XCTAssertEqual(parsed.attribute(.kernInlineCode, at: codeRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertFalse(parsed.string.contains("\r"))
        XCTAssertFalse(parsed.string.contains("\n"))
        XCTAssertEqual(
            parsed.attribute(.kernSourceMarkdown, at: codeRange.location, effectiveRange: nil) as? String,
            "`` foo\r\nbar ``"
        )
    }

    @MainActor
    func testParseInlineSimpleCodeSpanDoesNotAttachSourceMarkdown() {
        let parsed = NativeMarkdownCodec.parseInline(
            "prefix `code` suffix",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        let ns = parsed.string as NSString
        let codeRange = ns.range(of: "code")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        guard codeRange.location != NSNotFound else { return }

        XCTAssertEqual(parsed.attribute(.kernInlineCode, at: codeRange.location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(parsed.attribute(.kernSourceMarkdown, at: codeRange.location, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineUnmatchedBacktickRunStaysLiteral() {
        let parsed = NativeMarkdownCodec.parseInline(
            "prefix ``code suffix",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "prefix ``code suffix")
        let ns = parsed.string as NSString
        let tickRange = ns.range(of: "``")
        XCTAssertNotEqual(tickRange.location, NSNotFound)
        guard tickRange.location != NSNotFound else { return }
        XCTAssertNil(parsed.attribute(.kernInlineCode, at: tickRange.location, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineEscapedPunctuationPreservesEscapedLiteralAttribute() {
        let parsed = NativeMarkdownCodec.parseInline(
            #"prefix \*literal\* suffix"#,
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        let ns = parsed.string as NSString
        let firstStar = ns.range(of: "*")
        XCTAssertNotEqual(firstStar.location, NSNotFound)
        guard firstStar.location != NSNotFound else { return }

        XCTAssertEqual(parsed.string, "prefix *literal* suffix")
        XCTAssertEqual(parsed.attribute(.kernEscapedLiteral, at: firstStar.location, effectiveRange: nil) as? Bool, true)

        let secondStar = ns.range(of: "*", options: [], range: NSRange(location: firstStar.location + 1, length: ns.length - firstStar.location - 1))
        XCTAssertNotEqual(secondStar.location, NSNotFound)
        guard secondStar.location != NSNotFound else { return }
        XCTAssertEqual(parsed.attribute(.kernEscapedLiteral, at: secondStar.location, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testParseInlineBufferedEscapedLiteralsPreserveOnlyEscapedSubranges() {
        let parsed = NativeMarkdownCodec.parseInline(
            #"prefix \*literal\_ suffix"#,
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "prefix *literal_ suffix")

        let ns = parsed.string as NSString
        let star = ns.range(of: "*")
        XCTAssertNotEqual(star.location, NSNotFound)
        guard star.location != NSNotFound else { return }
        XCTAssertEqual(parsed.attribute(.kernEscapedLiteral, at: star.location, effectiveRange: nil) as? Bool, true)

        let underscore = ns.range(of: "_")
        XCTAssertNotEqual(underscore.location, NSNotFound)
        guard underscore.location != NSNotFound else { return }
        XCTAssertEqual(parsed.attribute(.kernEscapedLiteral, at: underscore.location, effectiveRange: nil) as? Bool, true)

        let middleLetter = ns.range(of: "l")
        XCTAssertNotEqual(middleLetter.location, NSNotFound)
        guard middleLetter.location != NSNotFound else { return }
        XCTAssertNil(parsed.attribute(.kernEscapedLiteral, at: middleLetter.location, effectiveRange: nil))
    }

    @MainActor
    func testParseInlineAutolinkPreservesDirectAppendLinkAttributes() {
        let parsed = NativeMarkdownCodec.parseInline(
            "<https://example.com/docs>",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "https://example.com/docs")
        let range = NSRange(location: 0, length: parsed.length)
        let url = parsed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(url?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(parsed.attribute(.kernAutolink, at: range.location, effectiveRange: nil) as? Bool, true)
    }

    @MainActor
    func testParseInlineEmailAutolinkUsesMailtoURLAndRoundTripsAsAngleAutolink() {
        let parsed = NativeMarkdownCodec.parseInline(
            "<me@example.com>",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "me@example.com")
        let range = NSRange(location: 0, length: parsed.length)
        let url = parsed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(url?.absoluteString, "mailto:me@example.com")
        XCTAssertEqual(parsed.attribute(.kernAutolink, at: range.location, effectiveRange: nil) as? Bool, true)

        let exported = NativeMarkdownCodec.exportMarkdown(parsed)
        XCTAssertEqual(exported, "<me@example.com>")
    }

    @MainActor
    func testParseInlineInvalidAutolinkWithWhitespaceStaysLiteral() {
        let parsed = NativeMarkdownCodec.parseInline(
            "<https://example.com docs>",
            baseFont: NSFont.systemFont(ofSize: 16)
        )

        XCTAssertEqual(parsed.string, "<https://example.com docs>")
        XCTAssertNil(parsed.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(parsed.attribute(.kernAutolink, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testInlineImageWithTitlePreservesOriginalSourceMarkdown() {
        let markdown = "![alt](https://example.com/image.png \"Alt title\")\n"
        let imported = NativeMarkdownCodec.importMarkdown(markdown)

        let full = NSRange(location: 0, length: imported.length)
        var foundSource: String?
        imported.enumerateAttribute(.attachment, in: full, options: []) { value, range, stop in
            guard value is MarkdownImageAttachment else { return }
            foundSource = imported.attribute(.kernSourceMarkdown, at: range.location, effectiveRange: nil) as? String
            stop.pointee = true
        }

        XCTAssertEqual(foundSource, "![alt](https://example.com/image.png \"Alt title\")")
    }

    @MainActor
    func testReferenceImagePreservesOriginalSourceMarkdown() {
        let markdown = "![alt][img]\n\n[img]: https://example.com/image.png\n"
        let imported = NativeMarkdownCodec.importMarkdown(markdown)

        let full = NSRange(location: 0, length: imported.length)
        var foundSource: String?
        imported.enumerateAttribute(.attachment, in: full, options: []) { value, range, stop in
            guard value is MarkdownImageAttachment else { return }
            foundSource = imported.attribute(.kernSourceMarkdown, at: range.location, effectiveRange: nil) as? String
            stop.pointee = true
        }

        XCTAssertEqual(foundSource, "![alt][img]")
    }

    @MainActor
    func testLargeDocumentInlineCacheSeparatesRemoteImageLoadingPolicy() {
        let fragment = "![Remote](https://example.com/mock-remote-image.png)\n"
        let repeats = max(3_000, (100_000 / max(fragment.utf16.count, 1)) + 32)
        let markdown = String(repeating: fragment, count: repeats)
        XCTAssertGreaterThan(markdown.utf16.count, 100_000)

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        var enabled = NativeMarkdownCodec.Options()
        enabled.remoteImageLoadingEnabled = true
        _ = NativeMarkdownCodec.importMarkdown(markdown, options: enabled)

        var disabled = NativeMarkdownCodec.Options()
        disabled.remoteImageLoadingEnabled = false
        let imported = NativeMarkdownCodec.importMarkdown(markdown, options: disabled)

        guard let image = firstImageAttachment(in: imported) else {
            return XCTFail("Expected image attachment in imported large document")
        }
        XCTAssertFalse(image.allowsRemoteLoading, "Inline parse cache should not reuse remote-loading-enabled image attachments after the policy is disabled")
    }

    @MainActor
    func testTableAttributedCacheSeparatesBaseURLContext() {
        let markdown = """
        | Link |
        | --- |
        | [docs](./guide.md) |
        """

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        let baseA = URL(fileURLWithPath: "/tmp/kern-table-a/doc.md")
        let baseB = URL(fileURLWithPath: "/tmp/kern-table-b/doc.md")

        _ = NativeMarkdownCodec.importMarkdown(markdown, baseURL: baseA)
        let imported = NativeMarkdownCodec.importMarkdown(markdown, baseURL: baseB)

        let link = linkURL(in: imported, matching: "docs")
        XCTAssertEqual(link?.standardizedFileURL.path, "/tmp/kern-table-b/guide.md")
    }

    @MainActor
    func testTableAttributedCacheSeparatesReferenceDefinitionContext() {
        let markdownA = """
        | Link |
        | --- |
        | [docs][ref] |

        [ref]: https://example.com/a
        """
        let markdownB = """
        | Link |
        | --- |
        | [docs][ref] |

        [ref]: https://example.com/b
        """

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        _ = NativeMarkdownCodec.importMarkdown(markdownA)
        let imported = NativeMarkdownCodec.importMarkdown(markdownB)

        let link = linkURL(in: imported, matching: "docs")
        XCTAssertEqual(link?.absoluteString, "https://example.com/b")
    }

    @MainActor
    func testTableAttributedCacheSeparatesRemoteImageLoadingPolicy() {
        let markdown = """
        | Image |
        | --- |
        | ![Remote](https://example.com/mock-remote-image.png) |
        """

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        var enabled = NativeMarkdownCodec.Options()
        enabled.remoteImageLoadingEnabled = true
        _ = NativeMarkdownCodec.importMarkdown(markdown, options: enabled)

        var disabled = NativeMarkdownCodec.Options()
        disabled.remoteImageLoadingEnabled = false
        let imported = NativeMarkdownCodec.importMarkdown(markdown, options: disabled)

        guard let image = firstImageAttachment(in: imported) else {
            return XCTFail("Expected table image attachment in imported markdown")
        }
        XCTAssertFalse(image.allowsRemoteLoading, "Table attributed cache should not reuse remote-loading-enabled attachments after the policy is disabled")
    }

    @MainActor
    func testLargeDocumentInlineCacheSeparatesThemeDependentFragments() {
        let fragment = "`code` and **bold** [link](https://example.com/docs)\n"
        let repeats = max(3_000, (100_000 / max(fragment.utf16.count, 1)) + 32)
        let markdown = String(repeating: fragment, count: repeats)
        XCTAssertGreaterThan(markdown.utf16.count, 100_000)

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        withTemporaryDefaults([
            NativeEditorAppearance.themeModeKey: NativeEditorThemeMode.githubDark.rawValue,
        ]) {
            _ = NativeMarkdownCodec.importMarkdown(markdown)
        }

        withTemporaryDefaults([
            NativeEditorAppearance.themeModeKey: NativeEditorThemeMode.solarizedLight.rawValue,
        ]) {
            let imported = NativeMarkdownCodec.importMarkdown(markdown)
            let ns = imported.string as NSString
            let codeRange = ns.range(of: "code")
            XCTAssertNotEqual(codeRange.location, NSNotFound)
            guard codeRange.location != NSNotFound else { return }

            let actualForeground = imported.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
            let expectedForeground = NativeEditorAppearance.inlineCodeTextColor()
            assertColorsEqual(
                actualForeground,
                expectedForeground,
                "Shared inline cache should not reuse inline-code text colors across theme changes"
            )
            XCTAssertEqual(imported.attribute(.kernInlineCode, at: codeRange.location, effectiveRange: nil) as? Bool, true)
        }
    }

    @MainActor
    func testLargeDocumentInlineCacheSeparatesRelativeLinksByBaseURL() {
        let fragment = "[doc](notes/readme.md) and **bold**\n"
        let repeats = max(3_500, (100_000 / max(fragment.utf16.count, 1)) + 64)
        let markdown = String(repeating: fragment, count: repeats)
        XCTAssertGreaterThan(markdown.utf16.count, 100_000)

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        let baseURL1 = URL(fileURLWithPath: "/tmp/kern-inline-cache-doc-a/source.md")
        let baseURL2 = URL(fileURLWithPath: "/tmp/kern-inline-cache-doc-b/source.md")

        _ = NativeMarkdownCodec.importMarkdown(markdown, baseURL: baseURL1)
        let imported = NativeMarkdownCodec.importMarkdown(markdown, baseURL: baseURL2)

        let ns = imported.string as NSString
        let linkRange = ns.range(of: "doc")
        XCTAssertNotEqual(linkRange.location, NSNotFound)
        guard linkRange.location != NSNotFound else { return }

        let resolved = imported.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(
            resolved,
            baseURL2.deletingLastPathComponent().appendingPathComponent("notes/readme.md"),
            "Shared inline cache must not reuse relative-link resolution from another document base URL"
        )
        XCTAssertNotEqual(
            resolved,
            baseURL1.deletingLastPathComponent().appendingPathComponent("notes/readme.md"),
            "Relative-link cache reuse across documents would leak the wrong base URL"
        )
    }

    @MainActor
    func testLargeDocumentInlineCacheSeparatesReferenceDefinitionsByDocumentContext() {
        let fragment = "[doc][ref] and **bold**\n"
        let repeats = max(3_500, (100_000 / max(fragment.utf16.count, 1)) + 64)
        let prefix = String(repeating: fragment, count: repeats)
        XCTAssertGreaterThan(prefix.utf16.count, 100_000)

        let markdownA = prefix + "\n[ref]: https://example.com/a\n"
        let markdownB = prefix + "\n[ref]: https://example.com/b\n"

        NativeMarkdownCodec.resetCachesForTesting()
        defer { NativeMarkdownCodec.resetCachesForTesting() }

        _ = NativeMarkdownCodec.importMarkdown(markdownA)
        let imported = NativeMarkdownCodec.importMarkdown(markdownB)

        let ns = imported.string as NSString
        let linkRange = ns.range(of: "doc")
        XCTAssertNotEqual(linkRange.location, NSNotFound)
        guard linkRange.location != NSNotFound else { return }

        let resolved = imported.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(
            resolved,
            URL(string: "https://example.com/b"),
            "Shared inline cache must not reuse reference-link resolution from another document's definitions"
        )
        XCTAssertNotEqual(
            resolved,
            URL(string: "https://example.com/a"),
            "Reference-definition cache reuse across documents would leak the wrong destination"
        )
    }

    @MainActor
    func testListContinuationKeepsNestedBulletAsSeparateBlock() {
        let md = """
        - parent
          continuation
          - child
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("- parent"))
        XCTAssertTrue(out.contains("continuation"))
        XCTAssertNotNil(
            out.range(of: #"\n\s+- child"#, options: .regularExpression),
            "Indented nested bullet should stay a separate child list item instead of being swallowed into the parent continuation"
        )
    }

    @MainActor
    func testListFenceContinuationPreservesBlankLineWithoutIndentPrefix() {
        let md = """
        - item
          ```swift

          print("hi")
          ```
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)
        let out = NativeMarkdownCodec.exportMarkdown(attr)

        XCTAssertTrue(out.contains("- item"))
        XCTAssertTrue(
            out.contains("```swift\n\nprint(\"hi\")\n```"),
            "Blank lines inside list-contained fenced code should survive even when the blank line itself has no list-indent prefix"
        )
    }

    func testInlineParseCacheThresholdDefaultsToConservativeBudget() {
        withTemporaryEnvironment(["KERN_INLINE_PARSE_CACHE_MAX_UTF16": nil]) {
            XCTAssertEqual(NativeMarkdownCodec.inlineParseCacheMaxUTF16ForTesting(), 384)
        }
    }

    func testInlineParseCacheThresholdRespectsEnvironmentOverride() {
        withTemporaryEnvironment(["KERN_INLINE_PARSE_CACHE_MAX_UTF16": "2048"]) {
            XCTAssertEqual(NativeMarkdownCodec.inlineParseCacheMaxUTF16ForTesting(), 2_048)
        }
    }

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        var saved: [String: Any?] = [:]
        for (key, value) in overrides {
            saved[key] = defaults.object(forKey: key)
            defaults.set(value, forKey: key)
        }
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        defer {
            for (key, previous) in saved {
                if let previous {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }
        return try body()
    }

    private func withTemporaryEnvironment<T>(_ overrides: [String: String?], _ body: () throws -> T) rethrows -> T {
        var saved: [String: String?] = [:]
        for (key, value) in overrides {
            saved[key] = ProcessInfo.processInfo.environment[key]
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        defer {
            for (key, previous) in saved {
                if let previous {
                    setenv(key, previous, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        return try body()
    }

    private func assertColorsEqual(
        _ actual: NSColor?,
        _ expected: NSColor,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected color attribute. \(message())", file: file, line: line)
        }
        let actualRGBA = rgbaComponents(for: actual)
        let expectedRGBA = rgbaComponents(for: expected)
        XCTAssertEqual(actualRGBA.red, expectedRGBA.red, accuracy: 0.001, message(), file: file, line: line)
        XCTAssertEqual(actualRGBA.green, expectedRGBA.green, accuracy: 0.001, message(), file: file, line: line)
        XCTAssertEqual(actualRGBA.blue, expectedRGBA.blue, accuracy: 0.001, message(), file: file, line: line)
        XCTAssertEqual(actualRGBA.alpha, expectedRGBA.alpha, accuracy: 0.001, message(), file: file, line: line)
    }

    private func rgbaComponents(for color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        return (
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }

    private func firstImageAttachment(in attributed: NSAttributedString) -> MarkdownImageAttachment? {
        var found: MarkdownImageAttachment?
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.attachment, in: full, options: []) { value, _, stop in
            guard let attachment = value as? MarkdownImageAttachment else { return }
            found = attachment
            stop.pointee = true
        }
        return found
    }

    private func linkURL(in attributed: NSAttributedString, matching text: String) -> URL? {
        let ns = attributed.string as NSString
        let range = ns.range(of: text)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
    }
}
