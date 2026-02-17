import AppKit
import Foundation
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecRichVisualFeatureTests: XCTestCase {
    @MainActor
    func testFullSpecVisualFixtureImportsRichBlocksAndQuoteStyling() throws {
        let fixtureURL = fixture(path: "test-fixtures/native-editor-golden/full-spec-visual.fixture.md")
        let markdown = try String(contentsOf: fixtureURL, encoding: .utf8)

        let attr = NativeMarkdownCodec.importMarkdown(markdown, options: .init(), baseURL: fixtureURL)

        var hasImage = false
        var hasMath = false
        var hasMermaid = false
        var hasThematicBreak = false
        var hasQuoteDepth = false
        var quoteHasStrong = false
        var quoteHasEmphasis = false
        var quoteHasInlineCode = false

        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length), options: []) { attrs, range, _ in
            if attrs[.attachment] is MarkdownImageAttachment { hasImage = true }
            if (attrs[.kernAttachmentKind] as? String) == "mathBlock" { hasMath = true }
            if (attrs[.kernAttachmentKind] as? String) == "mermaid" { hasMermaid = true }

            if let kindRaw = attrs[.kernBlockKind] as? Int,
               KernBlockKind(rawValue: kindRaw) == .thematicBreak {
                hasThematicBreak = true
            }

            let quoteDepth = (attrs[.kernQuoteDepth] as? Int) ?? 0
            if quoteDepth > 0 {
                hasQuoteDepth = true
                if attrs[.kernStrong] as? Bool == true { quoteHasStrong = true }
                if attrs[.kernEmphasis] as? Bool == true { quoteHasEmphasis = true }
                if attrs[.kernInlineCode] as? Bool == true { quoteHasInlineCode = true }
            }

            // Skip the newline-only runs where style attributes are often absent by design.
            if range.length == 1, attr.attributedSubstring(from: range).string == "\n" {
                return
            }
        }

        XCTAssertTrue(hasImage, "Expected local image attachment to render from fixture")
        XCTAssertTrue(hasMath, "Expected block math attachment kind in fixture import")
        XCTAssertTrue(hasMermaid, "Expected mermaid attachment kind in fixture import")
        XCTAssertTrue(hasThematicBreak, "Expected thematic break block in fixture import")
        XCTAssertTrue(hasQuoteDepth, "Expected blockquote depth attributes in fixture import")
        XCTAssertTrue(quoteHasStrong, "Expected bold formatting inside blockquote")
        XCTAssertTrue(quoteHasEmphasis, "Expected italic formatting inside blockquote")
        XCTAssertTrue(quoteHasInlineCode, "Expected inline code formatting inside blockquote")
    }

    @MainActor
    func testFullSpecVisualFixtureAttachmentsSurviveTextStorageTransfer() throws {
        let fixtureURL = fixture(path: "test-fixtures/native-editor-golden/full-spec-visual.fixture.md")
        let markdown = try String(contentsOf: fixtureURL, encoding: .utf8)

        let imported = NativeMarkdownCodec.importMarkdown(markdown, options: .init(), baseURL: fixtureURL)
        let storage = NSTextStorage(attributedString: imported)

        var imageAttachment: MarkdownImageAttachment?
        var mathAttachment: MarkdownMathBlockAttachment?
        var mermaidAttachment: MarkdownMermaidAttachment?
        var thematicBreakAttachment: ThematicBreakAttachment?

        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attrs, range, _ in
            guard let attachment = attrs[.attachment] as? NSTextAttachment else { return }
            if let a = attachment as? MarkdownImageAttachment { imageAttachment = a }
            if let a = attachment as? MarkdownMathBlockAttachment { mathAttachment = a }
            if let a = attachment as? MarkdownMermaidAttachment { mermaidAttachment = a }
            if let a = attachment as? ThematicBreakAttachment { thematicBreakAttachment = a }

            // All semantic attachments must keep an attachment cell after storage transfer.
            XCTAssertNotNil(attachment.attachmentCell, "Attachment lost cell after NSTextStorage transfer at range \(range)")
        }

        XCTAssertNotNil(imageAttachment, "Image attachment should survive NSTextStorage transfer")
        XCTAssertNotNil(mathAttachment, "Math attachment should survive NSTextStorage transfer")
        XCTAssertNotNil(mermaidAttachment, "Mermaid attachment should survive NSTextStorage transfer")
        XCTAssertNotNil(thematicBreakAttachment, "Thematic break attachment should survive NSTextStorage transfer")

        let tc = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        let lineFrag = NSRect(x: 0, y: 0, width: 800, height: 24)

        if let imageAttachment {
            let b = imageAttachment.attachmentBounds(for: tc, proposedLineFragment: lineFrag, glyphPosition: .zero, characterIndex: 0)
            XCTAssertGreaterThan(b.width, 100)
            XCTAssertGreaterThan(b.height, 40)
        }
        if let mathAttachment {
            let b = mathAttachment.attachmentBounds(for: tc, proposedLineFragment: lineFrag, glyphPosition: .zero, characterIndex: 0)
            XCTAssertGreaterThan(b.width, 200)
            XCTAssertGreaterThan(b.height, 30)
        }
        if let mermaidAttachment {
            let b = mermaidAttachment.attachmentBounds(for: tc, proposedLineFragment: lineFrag, glyphPosition: .zero, characterIndex: 0)
            XCTAssertGreaterThan(b.width, 200)
            XCTAssertGreaterThan(b.height, 120)
        }
        if let thematicBreakAttachment {
            let b = thematicBreakAttachment.attachmentBounds(for: tc, proposedLineFragment: lineFrag, glyphPosition: .zero, characterIndex: 0)
            XCTAssertGreaterThan(b.width, 20)
            XCTAssertGreaterThan(b.height, 10)
        }
    }

    private func fixture(path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(path)
    }
}
