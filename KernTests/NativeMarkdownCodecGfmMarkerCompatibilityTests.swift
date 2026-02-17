import XCTest
@testable import KernTextKit

/// GFM compatibility tests that *must* pass for real-world Markdown files.
///
/// These run in default `--unit-only` mode so regressions are caught immediately.
final class NativeMarkdownCodecGfmMarkerCompatibilityTests: XCTestCase {
    @MainActor
    func testBulletMarkersDashAsteriskPlusRoundTrip() throws {
        let md = """
        - dash
        * star
        + plus
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)

        // WYSIWYG should hide the raw marker characters and render bullets consistently.
        XCTAssertFalse(attr.string.contains("- dash"))
        XCTAssertFalse(attr.string.contains("* star"))
        XCTAssertFalse(attr.string.contains("+ plus"))
        XCTAssertTrue(attr.string.contains("dash"))
        XCTAssertTrue(attr.string.contains("star"))
        XCTAssertTrue(attr.string.contains("plus"))

        let out = NativeMarkdownCodec.exportMarkdown(attr)

        // Export should canonicalize to `- ` to match common GFM conventions.
        XCTAssertTrue(out.contains("- dash"))
        XCTAssertTrue(out.contains("- star"))
        XCTAssertTrue(out.contains("- plus"))
        XCTAssertFalse(out.contains("* star"))
        XCTAssertFalse(out.contains("+ plus"))
    }

    @MainActor
    func testTaskMarkersDashAsteriskPlusRoundTrip() throws {
        let md = """
        - [ ] dash
        * [x] star
        + [ ] plus
        """

        let attr = NativeMarkdownCodec.importMarkdown(md)

        // WYSIWYG should render checkboxes, not show the raw `[ ]`/`[x]` syntax.
        XCTAssertTrue(attr.string.contains("☐ dash"))
        XCTAssertTrue(attr.string.contains("☑ star"))
        XCTAssertTrue(attr.string.contains("☐ plus"))
        XCTAssertFalse(attr.string.contains("[ ]"))
        XCTAssertFalse(attr.string.contains("[x]"))

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("- [ ] dash"))
        XCTAssertTrue(out.contains("- [x] star"))
        XCTAssertTrue(out.contains("- [ ] plus"))
        XCTAssertFalse(out.contains("* [x] star"))
        XCTAssertFalse(out.contains("+ [ ] plus"))
    }

    @MainActor
    func testInDocumentAnchorLinksParseAndExport() throws {
        let md = "* [Section 1](#section-1)\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)

        // The visible text should not include raw list/link syntax.
        XCTAssertFalse(attr.string.contains("* ["))
        XCTAssertTrue(attr.string.contains("Section 1"))

        // The rendered text should have a link attribute somewhere on "Section 1".
        let ns = attr.string as NSString
        let r = ns.range(of: "Section 1")
        XCTAssertNotEqual(r.location, NSNotFound)
        let link = attr.attribute(.link, at: r.location, effectiveRange: nil)
        XCTAssertNotNil(link)

        let out = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertTrue(out.contains("[Section 1](#section-1)"))
    }

    @MainActor
    func testEscapedLiteralsRemainEscapedOnRoundTrip() throws {
        let md = """
        \\*not emphasized*
        \\<br/> not a tag
        \\[not a link](/foo)
        \\`not code`
        1\\. not a list
        \\* not a list
        \\# not a heading
        \\[foo]: /url "not a reference"
        \\&ouml; not a character entity
        """

        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))

        XCTAssertTrue(out.contains("\\<br/> not a tag"))
        XCTAssertTrue(out.contains("\\[not a link](/foo)"))
        XCTAssertTrue(out.contains("1\\. not a list"))
        XCTAssertTrue(out.contains("\\# not a heading"))
        XCTAssertTrue(out.contains("\\[foo]: /url \"not a reference\""))
        XCTAssertTrue(out.contains("\\&ouml; not a character entity"))
    }

    @MainActor
    func testInlineLinkDestinationKeepsRawEscapesForExport() throws {
        let md = #"[foo](/bar\* "ti\*tle")"#
        let attr = NativeMarkdownCodec.importMarkdown(md)

        let ns = attr.string as NSString
        let range = ns.range(of: "foo")
        XCTAssertNotEqual(range.location, NSNotFound)

        let rawDestination = attr.attribute(.kernLinkDestination, at: range.location, effectiveRange: nil) as? String
        XCTAssertEqual(rawDestination, #"/bar\*"#)

        let exported = NativeMarkdownCodec.exportMarkdown(attr)
        XCTAssertEqual(exported, md)
    }

    @MainActor
    func testLinkLabelWithNestedFormattingExportsAsSingleLink() throws {
        let md = #"[link *foo **bar** `#`*](/uri)"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        let anchorSuffix = "](/uri)"
        let linkCount = out.components(separatedBy: anchorSuffix).count - 1
        XCTAssertEqual(linkCount, 1, "Nested formatting inside link labels should not fragment into multiple links")
        XCTAssertFalse(out.contains("[link ](/uri)["), "Exporter should not emit split adjacent links for one label")
    }

    @MainActor
    func testComplexInlineLinkLabelFallsBackToLiteralRoundTrip() throws {
        let md = #"[link *foo **bar** `#`*](/uri)"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testComplexReferenceLinkLabelFallsBackToLiteralRoundTrip() throws {
        let md = """
        [link *foo **bar** `#`*][ref]

        [ref]: /uri
        """
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testNestedReferenceLabelFallsBackToLiteralRoundTrip() throws {
        let md = """
        [foo *bar [baz][ref]*][ref]

        [ref]: /uri
        """
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testInvalidBareDestinationWithSpaceRemainsLiteral() throws {
        let md = #"[link](/my uri)"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testAngleDestinationWithSpaceStaysAngleWrapped() throws {
        let md = #"[link](</my uri>)"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testEscapedParenthesesDestinationDoesNotGetAngleWrapped() throws {
        let md = #"[link](\(foo\))"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testBalancedEscapedParenthesesDestinationRoundTrips() throws {
        let md = #"[link](foo\(and\(bar\))"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testAngleDestinationWithClosingParenInsideRoundTrips() throws {
        let md = #"[a](<b)c>)"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testAngleDestinationWithUnbalancedOpenParenRoundTrips() throws {
        let md = #"[link](<foo(and(bar)>)"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testOddBacktickInLinkLabelDoesNotForceEscapedTrailingBacktick() throws {
        let md = #"[foo`](/uri)`"#
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testOddBacktickInReferenceLinkLabelDoesNotForceEscapedTrailingBacktick() throws {
        let md = """
        [foo`][ref]`

        [ref]: /uri
        """
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }

    @MainActor
    func testEmptyLinkLabelDoesNotDisappearOnRoundTrip() throws {
        let md = "[](./target.md)\n"
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md))
        XCTAssertEqual(out, md)
    }
}
