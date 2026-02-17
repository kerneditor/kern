import AppKit
import XCTest
@testable import KernTextKit

/// On-demand diagnostic report for marker/checkbox alignment in points + pixels.
///
/// This is *not* a baseline snapshot. It prints geometric deltas derived from TextKit glyph bounds
/// and is meant to help debug "it looks off by a few pixels" reports quickly.
final class NativeEditorAlignmentReportTests: XCTestCase {
    @MainActor
    func testReportBasicFixtureMarkerAndCheckboxAlignment() throws {
        try TestGates.skipUnlessExhaustive("Run via the exhaustive scheme to emit the alignment report")

        let md = try loadFixtureMarkdown(name: "basic.in.md")

        var gfm = NativeMarkdownCodec.Options()
        gfm.taskRendering = .gfm
        gfm.orderedTasksEnabled = false
        gfm.headingCheckboxesEnabled = false
        gfm.orderedListNumbering = .gfmDefault

        var kern = NativeMarkdownCodec.Options()
        kern.taskRendering = .kern
        kern.orderedTasksEnabled = true
        kern.headingCheckboxesEnabled = true
        kern.orderedListNumbering = .preserveTyped

        let profiles: [(name: String, options: NativeMarkdownCodec.Options)] = [
            ("gfmDefault", gfm),
            ("kernExtensions", kern),
        ]

        for profile in profiles {
            let attr = NativeMarkdownCodec.importMarkdown(md, options: profile.options)
            let textView = makeLaidOutTextView(attr: attr, width: 900, height: 650)
            let scale = guessBackingScaleFactor()

            let rows = computeParagraphMarkerDeltas(textView: textView)

            print("")
            print("=== Alignment Report (\(profile.name)) ===")
            print("scaleFactor≈\(String(format: "%.1f", scale))  (pixels = points * scaleFactor)")
            print("rows=\(rows.count)")
            for r in rows {
                let px = r.deltaMidYPoints * scale
                print(
                    String(
                        format: "kind=%@ marker=%@ content=%@ deltaMidY=%.4fpt (%.2fpx)",
                        r.kind,
                        r.marker,
                        r.contentPreview,
                        r.deltaMidYPoints,
                        px
                    )
                )
            }
        }
    }

    // MARK: - Fixture

    private func loadFixtureMarkdown(name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures/native-editor-golden", isDirectory: true)
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Layout

    @MainActor
    private func makeLaidOutTextView(attr: NSAttributedString, width: CGFloat, height: CGFloat) -> NSTextView {
        let textStorage = NSTextStorage(attributedString: attr)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: textContainer)
        tv.textContainerInset = NSSize(width: 32, height: 24)
        tv.isEditable = false
        tv.drawsBackground = false

        layoutManager.ensureLayout(for: textContainer)
        return tv
    }

    @MainActor
    private func glyphRect(atCharIndex charIndex: Int, in textView: NSTextView) -> NSRect {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return .zero }
        let glyphIndex = lm.glyphIndexForCharacter(at: charIndex)
        var rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    // MARK: - Report

    private struct Row {
        var kind: String
        var marker: String
        var contentPreview: String
        var deltaMidYPoints: CGFloat
    }

    @MainActor
    private func computeParagraphMarkerDeltas(textView: NSTextView) -> [Row] {
        guard let storage = textView.textStorage else { return [] }
        let ns = storage.string as NSString
        var rows: [Row] = []

        var idx = 0
        while idx < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            if para.length == 0 { break }

            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            let shouldCheck = (kind == .bullet || kind == .task || kind == .ordered)
            if shouldCheck {
                if let (contentIndex, markerIndices) = markerAndContentIndices(storage: storage, ns: ns, para: para) {
                    let contentRect = glyphRect(atCharIndex: contentIndex, in: textView)
                    let contentPreview = snippet(ns: ns, at: contentIndex, maxLen: 24)
                    for mi in markerIndices {
                        let markerRect = glyphRect(atCharIndex: mi, in: textView)
                        let delta = abs(markerRect.midY - contentRect.midY)
                        let marker = snippet(ns: ns, at: mi, maxLen: 1)
                        rows.append(Row(kind: "\(kind)", marker: marker, contentPreview: contentPreview, deltaMidYPoints: delta))
                    }
                }
            }

            idx = para.location + para.length
        }

        return rows
    }

    @MainActor
    private func markerAndContentIndices(
        storage: NSTextStorage,
        ns: NSString,
        para: NSRange
    ) -> (contentIndex: Int, markerIndices: [Int])? {
        let end = min(ns.length, para.location + para.length)

        func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        func shouldCheckMarkerChar(_ scalar: UnicodeScalar) -> Bool {
            if scalar == "•" || scalar == "☐" || scalar == "☑" { return true }
            // For ordered markers like "1." we use the first digit/letter.
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            return false
        }

        // First content character (non-marker, non-whitespace).
        var contentIndex: Int?
        for i in para.location..<end {
            let scalar = UnicodeScalar(ns.character(at: i))!
            if isWhitespace(scalar) { continue }
            let isMarker = (storage.attribute(.kernMarker, at: i, effectiveRange: nil) as? Bool) ?? false
            if !isMarker {
                contentIndex = i
                break
            }
        }
        guard let contentIndex else { return nil }

        // Marker glyph indices in prefix (cap scan length).
        var markerIndices: [Int] = []
        let scanEnd = min(end, para.location + 48)
        for i in para.location..<scanEnd {
            let scalar = UnicodeScalar(ns.character(at: i))!
            if isWhitespace(scalar) { continue }
            let isMarker = (storage.attribute(.kernMarker, at: i, effectiveRange: nil) as? Bool) ?? false
            if isMarker, shouldCheckMarkerChar(scalar) {
                markerIndices.append(i)
            }
        }

        if markerIndices.isEmpty { return nil }
        return (contentIndex, markerIndices)
    }

    private func snippet(ns: NSString, at i: Int, maxLen: Int) -> String {
        guard i >= 0, i < ns.length else { return "" }
        let len = min(maxLen, ns.length - i)
        return ns.substring(with: NSRange(location: i, length: len))
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func guessBackingScaleFactor() -> CGFloat {
        // Unit tests may not have a window; this is "good enough" for converting pt->px.
        // Most modern Macs are 2.0; many external monitors are 1.0.
        // We prefer a deterministic number instead of reading whatever the test host happens to be on.
        if ProcessInfo.processInfo.environment["KERN_ASSUME_1X"] == "1" { return 1.0 }
        return 2.0
    }
}
