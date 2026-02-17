import AppKit
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecMermaidLayoutTests: XCTestCase {
    @MainActor
    func testStressFixtureMermaidAttachmentsUseReadableBounds() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("test-fixtures", isDirectory: true)
            .appendingPathComponent("stress-test.md", isDirectory: false)
        let markdown = try String(contentsOf: fixtureURL, encoding: .utf8)

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: fixtureURL)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertGreaterThanOrEqual(mermaids.count, 2, "Expected at least two Mermaid diagrams in stress fixture")

        let lineFragment = NSRect(x: 0, y: 0, width: 760, height: 28)
        for attachment in mermaids {
            let bounds = attachment.attachmentBounds(
                for: nil,
                proposedLineFragment: lineFragment,
                glyphPosition: .zero,
                characterIndex: 0
            )
            XCTAssertGreaterThanOrEqual(bounds.width, 280, "Mermaid bounds are too narrow for readability")
            XCTAssertLessThanOrEqual(bounds.width, 760, "Mermaid bounds overflow the available line width")
            XCTAssertGreaterThanOrEqual(bounds.height, 150, "Mermaid bounds are too short and risk clipped content")
            XCTAssertLessThanOrEqual(bounds.height, 560, "Mermaid bounds are too tall and risk large blank regions")
        }
    }

    @MainActor
    func testSequenceDiagramParsingKeepsParticipantNodesCompact() {
        let markdown = """
        ```mermaid
        sequenceDiagram
          participant User
          participant Kern
          participant FileSystem
          User->>Kern: Open file.md
          Kern->>FileSystem: Read file
          FileSystem-->>Kern: File contents
          Kern-->>User: Render WYSIWYG
          User->>Kern: Edit
        ```
        """

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")

        guard let mermaid = mermaids.first else { return }
        XCTAssertGreaterThanOrEqual(mermaid.debugNodeCount, 3, "Expected participant nodes to be parsed")
        XCTAssertLessThanOrEqual(mermaid.debugNodeCount, 8, "Sequence parser should not explode node count")
        XCTAssertGreaterThanOrEqual(mermaid.debugEdgeCount, 4, "Expected message edges to be parsed")

        let bounds = mermaid.attachmentBounds(
            for: nil,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 700, height: 28),
            glyphPosition: .zero,
            characterIndex: 0
        )
        XCTAssertGreaterThan(bounds.width, 300)
        XCTAssertGreaterThan(bounds.height, 150)
        XCTAssertLessThan(bounds.height, 520)
    }

    @MainActor
    func testCyclicMermaidLayoutTerminatesQuickly() {
        let markdown = """
        ```mermaid
        sequenceDiagram
          participant User
          participant Kern
          User->>Kern: Type markdown
          Kern->>Kern: Apply input rules
          Kern-->>User: Render output
        ```
        """

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        let lineFragment = NSRect(x: 0, y: 0, width: 760, height: 28)
        let start = CFAbsoluteTimeGetCurrent()
        var lastBounds = NSRect.zero
        for _ in 0..<200 {
            lastBounds = mermaid.attachmentBounds(
                for: nil,
                proposedLineFragment: lineFragment,
                glyphPosition: .zero,
                characterIndex: 0
            )
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.50, "Cyclic mermaid layout is too slow (\(elapsed)s)")
        XCTAssertGreaterThan(lastBounds.width, 280)
        XCTAssertLessThan(lastBounds.height, 520)
    }

    @MainActor
    func testLongMermaidLabelsWrapInsteadOfTruncating() {
        let markdown = """
        ```mermaid
        flowchart TD
          A[This node label is intentionally very long so the renderer must wrap it into multiple lines rather than truncating]
          A --> B[Done]
        ```
        """

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        let longestLabel = mermaid.nodes.map(\.label).max(by: { $0.count < $1.count }) ?? ""
        XCTAssertGreaterThan(longestLabel.count, 70, "Long label should be preserved for wrapping")

        let tallestNode = mermaid.debugNodeHeightsForTesting.max() ?? 0
        XCTAssertGreaterThan(tallestNode, 34, "At least one node should grow taller for wrapped text")
    }

    @MainActor
    func testSequenceDiagramSuppressesEdgeLabelsToAvoidGhostTextOverdraw() {
        let markdown = """
        ```mermaid
        sequenceDiagram
          participant User
          participant Kern
          User->>Kern: Type markdown
          Kern-->>User: Rendered output
        ```
        """

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        XCTAssertFalse(mermaid.debugShowsEdgeLabelsForTesting, "Sequence diagrams should suppress edge labels to prevent overdraw")
        XCTAssertGreaterThan(
            mermaid.edges.compactMap(\.label).count,
            0,
            "Parser should still keep labels in model; suppression is a rendering choice"
        )
    }

    private func collectMermaidAttachments(in attributed: NSAttributedString) -> [MarkdownMermaidAttachment] {
        var out: [MarkdownMermaidAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            if let attachment = value as? MarkdownMermaidAttachment {
                out.append(attachment)
            }
        }
        return out
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
