import AppKit
import Foundation
import XCTest
@testable import KernTextKit

@MainActor
final class NativeRichBlockEvalCorpusTests: XCTestCase {
    private struct MathCorpus: Decodable { let version: Int; let cases: [MathCase] }
    private struct MathCase: Decodable {
        let id: String
        let title: String
        let display: Bool
        let latex: String
        let features: [String]
        let expectation: String
    }

    private struct MermaidCorpus: Decodable { let version: Int; let cases: [MermaidCase] }
    private struct MermaidCase: Decodable {
        let id: String
        let title: String
        let kind: String
        let source: String
        let features: [String]
        let expectedNativeCoverage: String
    }

    private struct Report: Codable {
        let generatedAt: String
        let notes: [String]
        let mathSummary: Summary
        let mermaidSummary: Summary
        let mathResults: [MathResult]
        let mermaidResults: [MermaidResult]
    }

    private struct Summary: Codable {
        let total: Int
        let semanticPass: Int
        let fidelityGap: Int
        let mustNotCrashPass: Int
        let featureCoverage: [String: Int]
    }

    private struct MathResult: Codable {
        let id: String
        let title: String
        let display: Bool
        let expectation: String
        let features: [String]
        let semanticPass: Bool
        let fidelityGap: Bool
        let rawDelimiterVisible: Bool
        let inlineRunCount: Int
        let blockAttachmentCount: Int
        let renderedTextSample: String
        let exportPreservedSource: Bool
        let exportedMarkdownSample: String
        let notes: [String]
    }

    private struct MermaidResult: Codable {
        let id: String
        let title: String
        let kind: String
        let expectedNativeCoverage: String
        let features: [String]
        let semanticPass: Bool
        let fidelityGap: Bool
        let rawFenceVisible: Bool
        let attachmentCount: Int
        let richNodeCount: Int
        let richEdgeCount: Int
        let richEffectiveMode: String?
        let autoEffectiveMode: String?
        let asciiEffectiveMode: String?
        let officialRequestedMode: String?
        let officialEffectiveMode: String?
        let richBounds: String?
        let exportPreservedSource: Bool
        let exportedMarkdownSample: String
        let notes: [String]
    }

    private struct VisualScenario {
        let name: String
        let theme: NativeEditorThemeMode
        let appearance: NSAppearance.Name
    }

    func testRichBlockEvalCorpus() throws {
        try XCTSkipUnless(
            TestRuntimeConfig.bool("KERN_ENABLE_RICH_BLOCK_EVALS"),
            "Set KERN_ENABLE_RICH_BLOCK_EVALS=1 to run rich-block corpus eval"
        )

        let root = repoRoot()
        let fixtureRoot = root.appendingPathComponent("test-fixtures/rich-block-eval", isDirectory: true)
        let mathCorpus: MathCorpus = try loadJSON(fixtureRoot.appendingPathComponent("math-renderer-corpus.json"))
        let mermaidCorpus: MermaidCorpus = try loadJSON(fixtureRoot.appendingPathComponent("mermaid-renderer-corpus.json"))

        XCTAssertGreaterThanOrEqual(mathCorpus.cases.count, 12, "Math eval corpus is too small to drive renderer selection")
        XCTAssertGreaterThanOrEqual(mermaidCorpus.cases.count, 16, "Mermaid eval corpus is too small to drive renderer selection")

        let mathResults = mathCorpus.cases.map(evaluateMathCase(_:))
        let mermaidResults = mermaidCorpus.cases.map(evaluateMermaidCase(_:))

        let report = Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            notes: [
                "This is a correctness/fidelity corpus eval, not a timing benchmark.",
                "Semantic pass means Kern produced math semantics or Mermaid attachments and preserved export source.",
                "Fidelity gap means the case is intentionally beyond the current lightweight native renderer or needs a candidate/official renderer for full quality.",
                "Official Mermaid parity is not expected from Kern's current rich/ascii/auto native fallback modes."
            ],
            mathSummary: summarize(mathResults),
            mermaidSummary: summarize(mermaidResults),
            mathResults: mathResults,
            mermaidResults: mermaidResults
        )

        try writeReport(report, root: root)
        try writeVisualArtifacts(mathCorpus: mathCorpus, mermaidCorpus: mermaidCorpus, root: root)

        XCTAssertEqual(mathResults.filter(\.semanticPass).count, mathResults.count, "All math corpus cases should at least import/export semantically")
        XCTAssertEqual(mermaidResults.filter(\.semanticPass).count, mermaidResults.count, "All Mermaid corpus cases should at least import/export semantically")
    }

    private func evaluateMathCase(_ item: MathCase) -> MathResult {
        let markdown: String
        if item.display {
            markdown = "Before block math.\n\n$$\n\(item.latex)\n$$\n\nAfter block math.\n"
        } else {
            markdown = "Before inline math $\(item.latex)$ after.\n"
        }

        let attributed = NativeMarkdownCodec.importMarkdown(markdown)
        let exported = NativeMarkdownCodec.exportMarkdown(attributed)
        var inlineRunCount = 0
        var blockAttachmentCount = 0
        var displaySamples: [String] = []

        attributed.enumerateAttribute(.kernInlineMath, in: NSRange(location: 0, length: attributed.length), options: []) { value, range, _ in
            if (value as? Bool) == true {
                inlineRunCount += 1
                displaySamples.append((attributed.string as NSString).substring(with: range))
            }
        }
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            if let math = value as? MarkdownMathBlockAttachment {
                blockAttachmentCount += 1
                displaySamples.append(math.displayText)
            }
        }

        let rawDelimiterVisible = attributed.string.contains("$$") || attributed.string.contains("$\(item.latex)$")
        let exportPreserved = exported.contains(item.latex) && (item.display ? exported.contains("$$") : exported.contains("$\(item.latex)$"))
        let semanticPass = !rawDelimiterVisible && exportPreserved && (item.display ? blockAttachmentCount > 0 : inlineRunCount > 0)
        let fidelityGap = item.expectation.contains("candidate") || item.expectation.contains("quality-gap")
        var notes: [String] = []
        if fidelityGap { notes.append("requires richer math renderer for visual-quality decision") }
        if displaySamples.contains(where: { $0.contains("\\") || $0.contains("begin") || $0.contains("operatorname") }) {
            notes.append("current fallback still exposes TeX-like tokens in rendered sample")
        }
        if item.features.contains("invalid") { notes.append("invalid-input case; pass means no crash plus source-preserving export") }

        return MathResult(
            id: item.id,
            title: item.title,
            display: item.display,
            expectation: item.expectation,
            features: item.features,
            semanticPass: semanticPass,
            fidelityGap: fidelityGap,
            rawDelimiterVisible: rawDelimiterVisible,
            inlineRunCount: inlineRunCount,
            blockAttachmentCount: blockAttachmentCount,
            renderedTextSample: sample(displaySamples.joined(separator: " | ")),
            exportPreservedSource: exportPreserved,
            exportedMarkdownSample: sample(exported),
            notes: notes
        )
    }

    private func evaluateMermaidCase(_ item: MermaidCase) -> MermaidResult {
        func importMode(_ mode: NativeMarkdownCodec.Options.MermaidRenderMode) -> (NSAttributedString, MarkdownMermaidAttachment?) {
            var options = NativeMarkdownCodec.Options()
            options.mermaidRenderMode = mode
            let markdown = "```mermaid\n\(item.source)\n```\n"
            let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options)
            var found: MarkdownMermaidAttachment?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
                if let mermaid = value as? MarkdownMermaidAttachment {
                    found = mermaid
                    stop.pointee = true
                }
            }
            return (attributed, found)
        }

        let (richAttributed, rich) = importMode(.rich)
        let (_, ascii) = importMode(.ascii)
        let (_, auto) = importMode(.auto)
        let (_, official) = importMode(.officialExternal)
        let exported = NativeMarkdownCodec.exportMarkdown(richAttributed)
        let rawFenceVisible = richAttributed.string.contains("```mermaid") || richAttributed.string.contains(item.source)
        let normalizedExport = exported.replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedSource = item.source.replacingOccurrences(of: "\r\n", with: "\n")
        let exportPreserved = normalizedExport.contains("```mermaid") && normalizedExport.contains(normalizedSource)
        let semanticPass = !rawFenceVisible && rich != nil && exportPreserved
        let fidelityGap = item.expectedNativeCoverage == "official-required"
        let bounds: String? = rich.map { attachment in
            let rect = attachment.attachmentBounds(
                for: nil,
                proposedLineFragment: NSRect(x: 0, y: 0, width: 760, height: 28),
                glyphPosition: .zero,
                characterIndex: 0
            )
            return "\(Int(rect.width))x\(Int(rect.height))"
        }
        var notes: [String] = []
        if fidelityGap { notes.append("official Mermaid renderer required for full parity") }
        if item.features.contains("invalid") { notes.append("invalid-input case; pass means no crash plus source-preserving export") }
        if rich != nil, item.expectedNativeCoverage == "official-required" {
            notes.append("current native path is evaluated as attachment/export fallback; official renderer needed for parity")
        }

        return MermaidResult(
            id: item.id,
            title: item.title,
            kind: item.kind,
            expectedNativeCoverage: item.expectedNativeCoverage,
            features: item.features,
            semanticPass: semanticPass,
            fidelityGap: fidelityGap,
            rawFenceVisible: rawFenceVisible,
            attachmentCount: rich == nil ? 0 : 1,
            richNodeCount: rich?.debugNodeCount ?? 0,
            richEdgeCount: rich?.debugEdgeCount ?? 0,
            richEffectiveMode: rich?.debugEffectiveRenderModeForTesting.rawValue,
            autoEffectiveMode: auto?.debugEffectiveRenderModeForTesting.rawValue,
            asciiEffectiveMode: ascii?.debugEffectiveRenderModeForTesting.rawValue,
            officialRequestedMode: official?.debugRequestedRenderModeForTesting.rawValue,
            officialEffectiveMode: official?.debugEffectiveRenderModeForTesting.rawValue,
            richBounds: bounds,
            exportPreservedSource: exportPreserved,
            exportedMarkdownSample: sample(exported),
            notes: notes
        )
    }

    private func summarize(_ results: [MathResult]) -> Summary {
        Summary(
            total: results.count,
            semanticPass: results.filter(\.semanticPass).count,
            fidelityGap: results.filter(\.fidelityGap).count,
            mustNotCrashPass: results.filter { $0.features.contains("invalid") && $0.semanticPass }.count,
            featureCoverage: featureCoverage(results.flatMap(\.features))
        )
    }

    private func summarize(_ results: [MermaidResult]) -> Summary {
        Summary(
            total: results.count,
            semanticPass: results.filter(\.semanticPass).count,
            fidelityGap: results.filter(\.fidelityGap).count,
            mustNotCrashPass: results.filter { $0.features.contains("invalid") && $0.semanticPass }.count,
            featureCoverage: featureCoverage(results.flatMap(\.features))
        )
    }

    private func featureCoverage(_ features: [String]) -> [String: Int] {
        features.reduce(into: [String: Int]()) { partial, feature in
            partial[feature, default: 0] += 1
        }
    }

    private func writeReport(_ report: Report, root: URL) throws {
        let outputDir = outputDirectory(root: root)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonURL = outputDir.appendingPathComponent("rich-block-eval.json")
        let mdURL = outputDir.appendingPathComponent("rich-block-eval.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        let markdown = renderMarkdown(report)
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        add(XCTAttachment(string: markdown))
        print("Rich block eval report: \(mdURL.path)")
        print("Rich block eval json: \(jsonURL.path)")
    }

    private func outputDirectory(root: URL) -> URL {
        if let configured = TestRuntimeConfig.string("KERN_RICH_BLOCK_EVAL_OUTPUT_DIR") {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return root
            .appendingPathComponent("test-results", isDirectory: true)
            .appendingPathComponent("rich-block-eval", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
    }

    private func renderMarkdown(_ report: Report) -> String {
        var lines: [String] = []
        lines.append("# Rich Block Renderer Eval")
        lines.append("")
        lines.append("- Generated: \(report.generatedAt)")
        lines.append("- Math cases: \(report.mathSummary.semanticPass)/\(report.mathSummary.total) semantic pass, \(report.mathSummary.fidelityGap) fidelity gaps")
        lines.append("- Mermaid cases: \(report.mermaidSummary.semanticPass)/\(report.mermaidSummary.total) semantic pass, \(report.mermaidSummary.fidelityGap) fidelity gaps")
        lines.append("")
        lines.append("## Notes")
        lines.append("")
        for note in report.notes { lines.append("- \(note)") }
        lines.append("")
        lines.append("## Math Results")
        lines.append("")
        lines.append("| Case | Semantic | Gap | Features | Rendered sample | Notes |")
        lines.append("|---|---:|---:|---|---|---|")
        for result in report.mathResults {
            lines.append("| `\(result.id)` | \(result.semanticPass ? "yes" : "no") | \(result.fidelityGap ? "yes" : "no") | \(result.features.joined(separator: ", ")) | \(escapeTable(result.renderedTextSample)) | \(escapeTable(result.notes.joined(separator: "; "))) |")
        }
        lines.append("")
        lines.append("## Mermaid Results")
        lines.append("")
        lines.append("| Case | Expected | Semantic | Gap | Rich nodes/edges | Modes rich/auto/ascii/official | Bounds | Notes |")
        lines.append("|---|---|---:|---:|---:|---|---:|---|")
        for result in report.mermaidResults {
            let officialSummary = "\(result.officialRequestedMode ?? "nil")->\(result.officialEffectiveMode ?? "nil")"
            let modeSummary = [result.richEffectiveMode, result.autoEffectiveMode, result.asciiEffectiveMode, officialSummary].map { $0 ?? "nil" }.joined(separator: "/")
            lines.append("| `\(result.id)` | \(result.expectedNativeCoverage) | \(result.semanticPass ? "yes" : "no") | \(result.fidelityGap ? "yes" : "no") | \(result.richNodeCount)/\(result.richEdgeCount) | \(modeSummary) | \(result.richBounds ?? "nil") | \(escapeTable(result.notes.joined(separator: "; "))) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func writeVisualArtifacts(mathCorpus: MathCorpus, mermaidCorpus: MermaidCorpus, root: URL) throws {
        let outputDir = outputDirectory(root: root)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let scenarios: [VisualScenario] = [
            .init(name: "light", theme: .kernPaper, appearance: .aqua),
            .init(name: "dark", theme: .kernGraphite, appearance: .darkAqua),
        ]
        var manifest: [String] = [
            "# Rich Block Visual Artifacts",
            "",
            "These PNGs are rendered from the same math and Mermaid corpora as the semantic eval.",
            "They use Kern's native TextKit attachment path, not a WebView.",
            "",
        ]

        for scenario in scenarios {
            let mathURL = outputDir.appendingPathComponent("math-\(scenario.name).png")
            try captureMarkdownContactSheet(
                title: "Math renderer corpus (\(scenario.name))",
                markdown: mathContactSheetMarkdown(mathCorpus),
                scenario: scenario,
                mermaidMode: .rich,
                root: root,
                destination: mathURL
            )
            manifest.append("- math-\(scenario.name): \(mathURL.path)")

            for mode in [
                NativeMarkdownCodec.Options.MermaidRenderMode.rich,
                .auto,
                .ascii,
                .officialExternal,
            ] {
                let mermaidURL = outputDir.appendingPathComponent("mermaid-\(mode.rawValue)-\(scenario.name).png")
                let expectedOfficialRenderCount = mode == .officialExternal
                    ? mermaidCorpus.cases.filter { !$0.features.contains("invalid") }.count
                    : nil
                try captureMarkdownContactSheet(
                    title: "Mermaid corpus \(mode.rawValue) mode (\(scenario.name))",
                    markdown: mermaidContactSheetMarkdown(mermaidCorpus, mode: mode),
                    scenario: scenario,
                    mermaidMode: mode,
                    root: root,
                    destination: mermaidURL,
                    expectedOfficialRenderCount: expectedOfficialRenderCount
                )
                manifest.append("- mermaid-\(mode.rawValue)-\(scenario.name): \(mermaidURL.path)")
            }
        }

        let manifestText = manifest.joined(separator: "\n") + "\n"
        try manifestText.write(
            to: outputDir.appendingPathComponent("visual-index.md"),
            atomically: true,
            encoding: .utf8
        )
        add(XCTAttachment(string: manifestText))
        print("Rich block visual artifacts: \(outputDir.appendingPathComponent("visual-index.md").path)")
    }

    private func mathContactSheetMarkdown(_ corpus: MathCorpus) -> String {
        var lines: [String] = [
            "# Math renderer corpus",
            "",
            "Rendered through Kern's native TextKit math attachment path.",
            "",
        ]
        for item in corpus.cases {
            lines.append("## \(item.id)")
            lines.append("")
            lines.append("**\(item.title)**")
            lines.append("")
            lines.append("Features: `\(item.features.joined(separator: "`, `"))`")
            lines.append("")
            if item.display {
                lines.append("$$")
                lines.append(item.latex)
                lines.append("$$")
            } else {
                lines.append("Inline sample: $\(item.latex)$")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func mermaidContactSheetMarkdown(_ corpus: MermaidCorpus, mode: NativeMarkdownCodec.Options.MermaidRenderMode) -> String {
        var lines: [String] = [
            "# Mermaid renderer corpus — \(mode.rawValue)",
            "",
            "Rendered through Kern's native TextKit Mermaid attachment path. The officialExternal mode is preference-gated: it uses cached official Mermaid PNGs when a renderer is configured and otherwise shows the native rich fallback.",
            "",
        ]
        for item in corpus.cases {
            lines.append("## \(item.id)")
            lines.append("")
            lines.append("**\(item.title)**")
            lines.append("")
            lines.append("Expected coverage: `\(item.expectedNativeCoverage)`")
            lines.append("")
            lines.append("Features: `\(item.features.joined(separator: "`, `"))`")
            lines.append("")
            lines.append("```mermaid")
            lines.append(item.source)
            lines.append("```")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func captureMarkdownContactSheet(
        title: String,
        markdown: String,
        scenario: VisualScenario,
        mermaidMode: NativeMarkdownCodec.Options.MermaidRenderMode,
        root: URL,
        destination: URL,
        expectedOfficialRenderCount: Int? = nil
    ) throws {
        var overrides: [String: Any] = [
            NativeEditorAppearance.themeModeKey: scenario.theme.rawValue,
            NativeEditorAppearance.fontFamilyKey: NativeEditorFontFamilyPreset.system.rawValue,
            NativeEditorAppearance.fontDesignKey: NativeEditorFontDesign.system.rawValue,
            NativeEditorAppearance.fontSizeKey: 16,
            "nativeEditor.exportDialect": "gfm",
            "nativeEditor.gfmExtensionExportStrategy": "preserve",
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.headingCheckboxesEnabled": true,
            "nativeEditor.orderedListNumbering": "gfmDefault",
            NativeEditorSyntaxVisibilityMode.userDefaultsKey: NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue,
            "nativeEditor.mermaidRenderMode": mermaidMode.rawValue,
            "nativeEditor.checkboxHitTarget": "glyph",
            MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey: false,
        ]
        if let command = TestRuntimeConfig.string("KERN_OFFICIAL_MERMAID_RENDERER_COMMAND") {
            overrides[MermaidOfficialExternalRenderer.commandUserDefaultsKey] = command
        }
        if let cacheDirectory = TestRuntimeConfig.string("KERN_OFFICIAL_MERMAID_CACHE_DIR") {
            overrides[MermaidOfficialExternalRenderer.cacheDirectoryUserDefaultsKey] = cacheDirectory
        }
        if let puppeteerConfigFile = TestRuntimeConfig.string("KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE") {
            overrides[MermaidOfficialExternalRenderer.puppeteerConfigFileUserDefaultsKey] = puppeteerConfigFile
        }
        if TestRuntimeConfig.string("KERN_OFFICIAL_MERMAID_USE_NPX") != nil {
            overrides[MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey] =
                TestRuntimeConfig.bool("KERN_OFFICIAL_MERMAID_USE_NPX")
        }

        try withTemporaryDefaults(overrides) {
            var options = NativeMarkdownCodec.Options.fromUserDefaults()
            options.mermaidRenderMode = mermaidMode
            let attributed = NativeMarkdownCodec.importMarkdown(
                markdown,
                options: options,
                baseURL: root.appendingPathComponent("test-fixtures", isDirectory: true)
            )
            let contactSheet = renderAttributedContactSheet(
                title: title,
                attributed: attributed,
                scenario: scenario,
                mermaidMode: mermaidMode,
                expectedOfficialRenderCount: expectedOfficialRenderCount
            )
            try writePNG(of: contactSheet, to: destination)
        }
    }

    private func renderAttributedContactSheet(
        title: String,
        attributed: NSAttributedString,
        scenario: VisualScenario,
        mermaidMode: NativeMarkdownCodec.Options.MermaidRenderMode,
        expectedOfficialRenderCount: Int? = nil
    ) -> NSView {
        let width: CGFloat = 1280
        let horizontalInset: CGFloat = 72
        let verticalInset: CGFloat = 64
        let contentWidth = width - horizontalInset * 2
        let textView = NativeMarkdownTextView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        textView.appearance = NSAppearance(named: scenario.appearance)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = true
        textView.backgroundColor = NativeEditorAppearance.editorBackgroundColor(appearance: NSAppearance(named: scenario.appearance))
        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let height = max(900, ceil(used.height + verticalInset * 2 + 48))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        textView.displayIfNeeded()
        if mermaidMode == .officialExternal {
            prepareOfficialMermaidVisuals(in: textView, scenario: scenario, contentWidth: contentWidth)
            waitForOfficialMermaidVisualsIfConfigured(
                in: textView,
                expectedOfficialRenderCount: expectedOfficialRenderCount
            )
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let refreshedUsed = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let refreshedHeight = max(900, ceil(refreshedUsed.height + verticalInset * 2 + 48))
            textView.frame = NSRect(x: 0, y: 0, width: width, height: refreshedHeight)
            textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.needsDisplay = true
            forceDisplay(textView)
        }
        _ = title
        return textView
    }

    private func prepareOfficialMermaidVisuals(in textView: NativeMarkdownTextView, scenario: VisualScenario, contentWidth: CGFloat) {
        let horizontalPadding: CGFloat = 12
        let availableWidth = max(280, min(920, contentWidth - 8))
        let maxContentWidth = max(220, availableWidth - horizontalPadding * 2)
        let themeIdentifier = scenario.appearance == .darkAqua ? "dark" : "default"
        for attachment in mermaidAttachments(in: textView.textStorage ?? NSAttributedString()) {
            attachment.debugPrepareOfficialExternalRenderForTesting(
                maxContentWidth: maxContentWidth,
                themeIdentifier: themeIdentifier
            )
        }
    }

    private func waitForOfficialMermaidVisualsIfConfigured(
        in textView: NativeMarkdownTextView,
        expectedOfficialRenderCount: Int?
    ) {
        let attachments = mermaidAttachments(in: textView.textStorage ?? NSAttributedString())
        guard !attachments.isEmpty else {
            forceDisplay(textView)
            return
        }
        guard MermaidOfficialExternalRenderer.isRendererConfigured else {
            if let expectedOfficialRenderCount, expectedOfficialRenderCount > 0 {
                XCTFail("Official Mermaid renderer was requested for visual eval, but no renderer was configured in the app/test process")
            }
            forceDisplay(textView)
            return
        }
        let timeout = Double(TestRuntimeConfig.int("KERN_OFFICIAL_MERMAID_VISUAL_TIMEOUT_SECONDS", default: 90) ?? 90)
        let deadline = Date().addingTimeInterval(max(5, timeout))
        repeat {
            forceDisplay(textView)
            let states = attachments.map(\.debugOfficialExternalRenderStateForTesting)
            let finished = attachments.allSatisfy { attachment in
                attachment.debugHasOfficialExternalImageForTesting
                    || attachment.debugOfficialExternalRenderStateForTesting == "failed"
                    || attachment.debugOfficialExternalRenderStateForTesting == "disabled"
            }
            if finished {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            if states.allSatisfy({ $0 == "disabled" }) {
                break
            }
        } while Date() < deadline
        for attachment in attachments where attachment.debugOfficialExternalRenderStateForTesting == "rendering" {
            attachment.debugMarkOfficialExternalRenderFailedForTesting()
        }
        if let expectedOfficialRenderCount {
            let imageCount = attachments.filter(\.debugHasOfficialExternalImageForTesting).count
            XCTAssertGreaterThanOrEqual(
                imageCount,
                expectedOfficialRenderCount,
                "Official Mermaid visual eval rendered \(imageCount) official images, expected at least \(expectedOfficialRenderCount)"
            )
        }
        forceDisplay(textView)
    }

    private func mermaidAttachments(in attributed: NSAttributedString) -> [MarkdownMermaidAttachment] {
        var attachments: [MarkdownMermaidAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            if let mermaid = value as? MarkdownMermaidAttachment {
                attachments.append(mermaid)
            }
        }
        return attachments
    }

    private func forceDisplay(_ view: NSView) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    private func writePNG(of view: NSView, to destination: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create bitmap representation for rich-block visual artifact")
            return
        }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode rich-block visual artifact PNG")
            return
        }
        try png.write(to: destination, options: .atomic)
    }

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let previous = overrides.keys.reduce(into: [String: Any?]()) { partial, key in
            partial[key] = defaults.object(forKey: key)
        }
        for (key, value) in overrides {
            defaults.set(value, forKey: key)
        }
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        defer {
            for key in overrides.keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }
        return try body()
    }

    private func loadJSON<T: Decodable>(_ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests
            .deletingLastPathComponent() // repo root
    }

    private func sample(_ value: String, limit: Int = 160) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private func escapeTable(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
