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
            XCTAssertEqual(bounds.width, 752, accuracy: 0.5, "Mermaid blocks should align to the readable column, not shrink to diagram content width")
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
        XCTAssertEqual(bounds.width, 692, accuracy: 0.5, "Mermaid sequence blocks should align with the containing column")
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
    func testMermaidKindDetectionSkipsLeadingCommentsBeforeRenderableDiagram() {
        let markdown = """
        ```mermaid
        %%{init: {'theme': 'dark'}}%%
        %% user comment before the diagram keyword
        flowchart TD
          A[Start] --> B[End]
        ```
        """

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        XCTAssertEqual(mermaid.debugDiagramKindForTesting, "flowchart")
        XCTAssertTrue(mermaid.debugSupportsNativeRichMermaidForTesting)
        XCTAssertEqual(mermaid.debugNodeCount, 2)
        XCTAssertEqual(mermaid.debugEdgeCount, 1)
    }

    @MainActor
    func testSequenceDiagramAllowsEdgeLabelsWithRowLayout() {
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

        XCTAssertTrue(mermaid.debugShowsEdgeLabelsForTesting, "Sequence diagrams should allow labels once messages are placed on separate rows")
        XCTAssertGreaterThan(
            mermaid.edges.compactMap(\.label).count,
            0,
            "Parser should keep labels in the model for sequence message rows"
        )
    }

    @MainActor
    func testSequenceDiagramDoesNotTreatArrowSyntaxAsParticipantNames() {
        let markdown = """
        ```mermaid
        sequenceDiagram
          participant User
          participant Kern
          participant Cache
          User->>Kern: Open file
          Kern->>Cache: Lookup render cache
          Cache-->>Kern: SVG
          Kern-->>User: Draw block
        ```
        """

        var options = NativeMarkdownCodec.Options()
        options.mermaidRenderMode = .ascii
        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        XCTAssertEqual(mermaid.debugNodeCount, 3, "Sequence parser should keep only declared/used participants")
        let ascii = mermaid.debugASCIILinesForTesting.joined(separator: "\n")
        XCTAssertFalse(ascii.contains("Cache--"), "Sequence ASCII should not let the flowchart parser create fake participants from arrows")
        XCTAssertFalse(ascii.contains("Kern--"), "Sequence ASCII should not let the flowchart parser create fake participants from arrows")
    }

    @MainActor
    func testMermaidASCIIRenderModeUsesCompactBounds() {
        let markdown = """
        ```mermaid
        flowchart TD
          A[Start] --> B[Load]
          B --> C[Parse]
          C --> D[Render]
        ```
        """

        var options = NativeMarkdownCodec.Options()
        options.mermaidRenderMode = .ascii
        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        XCTAssertEqual(mermaid.debugEffectiveRenderModeForTesting, .ascii)
        XCTAssertEqual(mermaid.debugNodeCount, 4)
        XCTAssertEqual(mermaid.debugEdgeCount, 3, "ASCII flowcharts should parse edges whose endpoints include Mermaid shape labels")
        let asciiLines = mermaid.debugASCIILinesForTesting
        let ascii = asciiLines.joined(separator: "\n")
        XCTAssertTrue(ascii.contains("Start"), "ASCII mode should render parsed node labels")
        XCTAssertTrue(ascii.contains("Load"), "ASCII mode should render downstream node labels")
        XCTAssertTrue(
            ascii.contains("┌") || ascii.contains("+"),
            "ASCII mode should render diagram boxes, not only source text"
        )
        XCTAssertTrue(
            ascii.contains("▼") || ascii.contains("▶") || ascii.contains("v") || ascii.contains(">"),
            "ASCII mode should render directional connectors"
        )
        XCTAssertFalse(ascii.contains("flowchart TD"), "Renderable flowcharts should be rendered as diagrams, not source text")
        XCTAssertFalse(ascii.contains("nodes:"), "ASCII mode should not render only an internal parser inventory")
        let bounds = mermaid.attachmentBounds(
            for: nil,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 700, height: 28),
            glyphPosition: .zero,
            characterIndex: 0
        )
        XCTAssertEqual(bounds.width, 692, accuracy: 0.5, "ASCII Mermaid blocks should align with the containing column")
        XCTAssertGreaterThanOrEqual(bounds.width, 280)
        XCTAssertLessThan(bounds.height, 420, "ASCII mode should remain compact")
    }


    @MainActor
    func testMermaidASCIIGenericDiagramUsesStructuredFallback() {
        let markdown = """
        ```mermaid
        classDiagram
          class Document {
            +String path
            +save() void
          }
          class Renderer {
            +render(markdown)
          }
          Document --> Renderer
        ```
        """

        var options = NativeMarkdownCodec.Options()
        options.mermaidRenderMode = .ascii
        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        let asciiLines = mermaid.debugASCIILinesForTesting
        let ascii = asciiLines.joined(separator: "\n")
        XCTAssertTrue(ascii.contains("classDiagram"), "Generic ASCII fallback should identify the unsupported Mermaid family")
        XCTAssertTrue(ascii.contains("Document"), "Generic ASCII fallback should preserve parsed nodes")
        XCTAssertTrue(ascii.contains("Renderer"), "Generic ASCII fallback should preserve parsed destination nodes")
        XCTAssertTrue(ascii.contains("nodes"), "Generic ASCII fallback should summarize parsed diagram structure")
        XCTAssertFalse(ascii.contains("nodes:"), "Generic ASCII fallback should not expose internal parser inventory")
        XCTAssertLessThanOrEqual(asciiLines.map(\.count).max() ?? 0, 96, "Generic ASCII fallback should stay within a bounded card width")
    }

    @MainActor
    func testMindmapUsesSourceFallbackInsteadOfFakeFlowchartRoot() {
        let markdown = """
        ```mermaid
        mindmap
          root((Kern))
            Native
              TextKit
              AppKit
            Rich blocks
              Math
              Mermaid
        ```
        """

        var options = NativeMarkdownCodec.Options()
        options.mermaidRenderMode = .rich
        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        guard let mermaid = mermaids.first else { return }

        XCTAssertEqual(mermaid.debugDiagramKindForTesting, "mindmap")
        XCTAssertFalse(mermaid.debugSupportsNativeRichMermaidForTesting, "Mindmap needs official Mermaid for full-fidelity layout")
        XCTAssertEqual(mermaid.debugNodeCount, 0, "Mindmap should not be reduced to only the root node by flowchart regexes")
        XCTAssertEqual(mermaid.debugEdgeCount, 0, "Mindmap indentation should not be fabricated into flowchart edges")

        let sourceFallback = mermaid.debugASCIILinesForTesting.joined(separator: "\n")
        XCTAssertTrue(sourceFallback.contains("mindmap"), "Fallback should identify the Mermaid family")
        XCTAssertTrue(sourceFallback.contains("TextKit"), "Fallback should preserve source content for review")
        XCTAssertTrue(sourceFallback.contains("AppKit"), "Fallback should preserve source content for review")

        let bounds = mermaid.attachmentBounds(
            for: nil,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 760, height: 28),
            glyphPosition: .zero,
            characterIndex: 0
        )
        XCTAssertEqual(bounds.width, 752, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(bounds.height, 128)
        XCTAssertLessThan(bounds.height, 420)
    }

    @MainActor
    func testOfficialOnlyMermaidFamiliesDoNotUseGenericChains() {
        let samples: [(String, String)] = [
            (
                "timeline",
                """
                ```mermaid
                timeline
                    title Kern Development Timeline
                    2025-01 : Native TextKit prototype
                             : WYSIWYG Markdown codec
                    2025-02 : Preferences and fixtures
                ```
                """
            ),
            (
                "journey",
                """
                ```mermaid
                journey
                    title User Opens a Markdown File in Kern
                    section Discovery
                      Open file from Finder: 5: User
                      Kern renders native document: 4: Kern
                ```
                """
            ),
            (
                "sankey",
                """
                ```mermaid
                sankey-beta
                Markdown,TextKit,30
                TextKit,Native WYSIWYG,25
                Native WYSIWYG,Export,20
                ```
                """
            ),
        ]

        for (expectedKind, markdown) in samples {
            var options = NativeMarkdownCodec.Options()
            options.mermaidRenderMode = .rich
            let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
            let mermaid = collectMermaidAttachments(in: attributed).first
            XCTAssertNotNil(mermaid, "Expected one Mermaid attachment for \(expectedKind)")

            XCTAssertEqual(mermaid?.debugDiagramKindForTesting, expectedKind)
            XCTAssertFalse(mermaid?.debugSupportsNativeRichMermaidForTesting ?? true)
            XCTAssertEqual(mermaid?.debugNodeCount, 0, "\(expectedKind) should not fabricate native-rich nodes")
            XCTAssertEqual(mermaid?.debugEdgeCount, 0, "\(expectedKind) should not fabricate native-rich edges")

            let sourceFallback = mermaid?.debugASCIILinesForTesting.joined(separator: "\n") ?? ""
            XCTAssertTrue(sourceFallback.contains(expectedKind), "Fallback should show \(expectedKind) source")
            XCTAssertFalse(sourceFallback.contains("L1"), "Fallback should not expose synthetic generic chain node identifiers")
        }
    }

    @MainActor
    func testMermaidAutoModeUsesSourceFallbackForOfficialOnlyFamilies() {
        let markdown = """
        ```mermaid
        journey
            title User Opens a Markdown File in Kern
            section Loading
              File read from disk: 5: Kern
              TextKit layout prepared: 4: Kern
        ```
        """

        var options = NativeMarkdownCodec.Options()
        options.mermaidRenderMode = .auto
        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let mermaid = collectMermaidAttachments(in: attributed).first

        XCTAssertEqual(mermaid?.debugDiagramKindForTesting, "journey")
        XCTAssertEqual(mermaid?.debugEffectiveRenderModeForTesting, .ascii)
        let sourceFallback = mermaid?.debugASCIILinesForTesting.joined(separator: "\n") ?? ""
        XCTAssertTrue(sourceFallback.contains("journey"))
        XCTAssertTrue(sourceFallback.contains("TextKit layout prepared"))
    }

    @MainActor
    func testMermaidAutoRenderModeCanSelectASCIIForHeavyDiagram() {
        var lines: [String] = [
            "```mermaid",
            "sequenceDiagram",
        ]
        for i in 0..<18 {
            lines.append("  participant P\(i) as Participant \(i)")
        }
        for i in 0..<32 {
            let a = i % 12
            let b = (i + 1) % 12
            lines.append("  P\(a)->>P\(b): very long edge label \(i) to increase complexity score")
        }
        lines.append("```")
        let markdown = lines.joined(separator: "\n")

        var options = NativeMarkdownCodec.Options()
        options.mermaidRenderMode = .auto
        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let mermaids = collectMermaidAttachments(in: attributed)
        XCTAssertEqual(mermaids.count, 1, "Expected one Mermaid attachment")
        XCTAssertEqual(mermaids.first?.debugEffectiveRenderModeForTesting, .ascii)
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
