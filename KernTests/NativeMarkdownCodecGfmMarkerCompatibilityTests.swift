import XCTest
@testable import KernTextKit

/// GFM compatibility tests that *must* pass for real-world Markdown files.
///
/// These are gated behind `KERN_ENABLE_EXHAUSTIVE_TESTS=1` because some are not implemented yet.
final class NativeMarkdownCodecGfmMarkerCompatibilityTests: XCTestCase {
    @MainActor
    func testBulletMarkersDashAsteriskPlusRoundTrip() throws {
        try TestGates.skipUnlessExhaustive()

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
        try TestGates.skipUnlessExhaustive()

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
        try TestGates.skipUnlessExhaustive()

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
}
