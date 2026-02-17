import AppKit
import XCTest
@testable import KernTextKit

/// Pixel-level layout metric tests for list markers (bullets + ordered markers) and their alignment
/// with adjacent text.
///
/// Snapshot tests can miss misalignment if a bad baseline is recorded. These metric tests are
/// baseline-independent and assert concrete geometry.
final class NativeEditorMarkerAlignmentMetricSpecTests: XCTestCase {
    @MainActor
    func testOrderedTaskCheckboxesShareColumnForSingleDigitDecimalMarkers() throws {
        var opt = NativeMarkdownCodec.Options()
        opt.orderedTasksEnabled = true

        let md = """
        1. [ ] ordered unchecked
        2. [x] ordered checked
        """

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        let textView = makeLaidOutTextView(attr: attr, width: 700, height: 180)

        guard let storage = textView.textStorage else {
            XCTFail("Missing textStorage")
            return
        }

        let ns = storage.string as NSString
        var checkboxIndices: [Int] = []
        var idx = 0
        while idx < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            if para.length == 0 { break }

            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .ordered {
                for i in para.location..<(para.location + para.length) where i < storage.length {
                    let isCheckbox = (storage.attribute(.kernCheckbox, at: i, effectiveRange: nil) as? Bool) ?? false
                    if isCheckbox {
                        checkboxIndices.append(i)
                        break
                    }
                }
            }
            idx = para.location + para.length
        }

        XCTAssertEqual(checkboxIndices.count, 2, "Expected two ordered-task checkbox markers")
        guard checkboxIndices.count == 2 else { return }

        let firstRect = glyphRect(atCharIndex: checkboxIndices[0], in: textView)
        let secondRect = glyphRect(atCharIndex: checkboxIndices[1], in: textView)
        let deltaX = abs(firstRect.minX - secondRect.minX)

        XCTAssertLessThan(
            deltaX,
            1.0,
            "Ordered-task checkbox column should align between '1.' and '2.' markers (deltaX=\(deltaX))"
        )
    }

    @MainActor
    func testOrderedTaskCheckboxesHaveStableSingleDigitColumn_AndBoundedDoubleDigitOffset() throws {
        var opt = NativeMarkdownCodec.Options()
        opt.orderedTasksEnabled = true

        let md = """
        1. [ ] first
        2. [x] second
        9. [ ] ninth
        10. [x] tenth
        """

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        let textView = makeLaidOutTextView(attr: attr, width: 760, height: 220)

        guard let storage = textView.textStorage else {
            XCTFail("Missing textStorage")
            return
        }

        let ns = storage.string as NSString
        var checkboxIndices: [Int] = []
        var idx = 0
        while idx < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            if para.length == 0 { break }

            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .ordered {
                for i in para.location..<(para.location + para.length) where i < storage.length {
                    let isCheckbox = (storage.attribute(.kernCheckbox, at: i, effectiveRange: nil) as? Bool) ?? false
                    if isCheckbox {
                        checkboxIndices.append(i)
                        break
                    }
                }
            }
            idx = para.location + para.length
        }

        XCTAssertEqual(checkboxIndices.count, 4, "Expected four ordered-task checkbox markers")
        guard checkboxIndices.count == 4 else { return }

        let rects = checkboxIndices.map { glyphRect(atCharIndex: $0, in: textView) }
        let singleDigitX = [rects[0].minX, rects[1].minX, rects[2].minX]

        // Single-digit markers (1, 2, 9) should align to the same checkbox column.
        let referenceX = singleDigitX[0]
        for (i, x) in singleDigitX.enumerated() {
            let deltaX = abs(x - referenceX)
            XCTAssertLessThan(
                deltaX,
                1.0,
                "Single-digit ordered-task checkbox at row \(i) should share a consistent column (deltaX=\(deltaX))"
            )
        }

        // A two-digit marker (10.) may shift checkbox start; keep the shift bounded.
        let twoDigitDelta = rects[3].minX - referenceX
        XCTAssertGreaterThan(twoDigitDelta, 0.0, "Two-digit ordered marker should not shift checkbox left")
        XCTAssertLessThan(twoDigitDelta, 16.0, "Two-digit ordered marker shift should stay bounded (deltaX=\(twoDigitDelta))")
    }

    @MainActor
    func testBulletMarkerVerticallyCenteredWithText_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let md = "- item\n"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        let textView = makeLaidOutTextView(attr: attr, width: 600, height: 140)

        let bulletIndex = try requireFirstIndex(of: "•", in: textView.string)
        let letterIndex = try requireFirstIndex(of: "item", in: textView.string)

        let bulletRect = glyphRect(atCharIndex: bulletIndex, in: textView)
        let letterRect = glyphRect(atCharIndex: letterIndex, in: textView)

        let deltaMidY = abs(bulletRect.midY - letterRect.midY)
        XCTAssertLessThan(deltaMidY, 2.0, "Bullet marker should be vertically centered with adjacent text (deltaMidY=\(deltaMidY))")
    }

    @MainActor
    func testOrderedMarkerVerticallyCenteredWithText_AcrossDepthStyles_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        // Depth is derived from leading indent (indent/3). The display marker varies by depth:
        // 0 -> 1., 1 -> a., 2 -> i.
        let cases: [(name: String, md: String)] = [
            ("decimal", "1. item\n"),
            ("alpha", """
            1. parent
               1. item
            """),
            ("roman", """
            1. parent
               1. child
                  1. item
            """),
        ]

        for c in cases {
            let attr = NativeMarkdownCodec.importMarkdown(c.md)
            let textView = makeLaidOutTextView(attr: attr, width: 600, height: 140)

            guard let storage = textView.textStorage else {
                XCTFail("[\(c.name)] Missing textStorage")
                continue
            }
            let ns = storage.string as NSString
            let itemRange = ns.range(of: "item")
            XCTAssertNotEqual(itemRange.location, NSNotFound, "[\(c.name)] Missing target content token")
            guard itemRange.location != NSNotFound else { continue }

            let para = ns.paragraphRange(for: NSRange(location: itemRange.location, length: 0))
            var markerIndex: Int?
            for i in para.location..<itemRange.location where i < storage.length {
                let isMarker = (storage.attribute(.kernMarker, at: i, effectiveRange: nil) as? Bool) ?? false
                guard isMarker else { continue }
                let scalar = UnicodeScalar(ns.character(at: i))!
                if CharacterSet.alphanumerics.contains(scalar) {
                    markerIndex = i
                    break
                }
            }
            guard let markerIndex else {
                XCTFail("[\(c.name)] Expected an ordered marker glyph in paragraph: \(storage.string)")
                continue
            }

            let letterIndex = itemRange.location

            let markerRect = glyphRect(atCharIndex: markerIndex, in: textView)
            let letterRect = glyphRect(atCharIndex: letterIndex, in: textView)

            let deltaMidY = abs(markerRect.midY - letterRect.midY)
            XCTAssertLessThan(
                deltaMidY,
                2.0,
                "[\(c.name)] Ordered marker should be vertically centered with adjacent text (deltaMidY=\(deltaMidY))"
            )
        }
    }

    @MainActor
    func testBulletedTaskBulletAndCheckboxVerticallyCenteredWithText_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        // Kern-style task rendering includes both a bullet and a checkbox: "• ☐ item".
        var opt = NativeMarkdownCodec.Options()
        opt.taskRendering = .kern

        let md = "- [ ] item\n"
        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        let textView = makeLaidOutTextView(attr: attr, width: 600, height: 140)

        let bulletIndex = try requireFirstIndex(of: "•", in: textView.string)
        let checkboxIndex = try requireFirstIndex(with: .kernCheckbox, in: textView)
        let letterIndex = try requireFirstIndex(of: "item", in: textView.string)

        let bulletRect = glyphRect(atCharIndex: bulletIndex, in: textView)
        let checkboxRect = glyphRect(atCharIndex: checkboxIndex, in: textView)
        let letterRect = glyphRect(atCharIndex: letterIndex, in: textView)

        let deltaBullet = abs(bulletRect.midY - letterRect.midY)
        XCTAssertLessThan(deltaBullet, 2.0, "Task bullet marker should be vertically centered with adjacent text (deltaMidY=\(deltaBullet))")

        let deltaCheckbox = abs(checkboxRect.midY - letterRect.midY)
        XCTAssertLessThan(deltaCheckbox, 2.0, "Task checkbox glyph should be vertically centered with adjacent text (deltaMidY=\(deltaCheckbox))")

        let deltaBulletCheckbox = abs(bulletRect.midY - checkboxRect.midY)
        XCTAssertLessThan(deltaBulletCheckbox, 2.0, "Task bullet and checkbox should share a common vertical center (deltaMidY=\(deltaBulletCheckbox))")
    }

    /// Broad, fixture-backed alignment sweep: for each list paragraph (bullet/task/ordered), ensure
    /// marker glyph(s) share the same vertical center as the first content glyph.
    ///
    /// This catches subtle per-paragraph regressions even if snapshot baselines were recorded poorly.
    @MainActor
    func testListMarkersAlignedAcrossFixturesAndProfiles_FullSpec() throws {
        try TestGates.skipUnlessExhaustive()

        let fixtures = [
            "basic.in.md",
            "task-permutations.fixture.md",
            "extensions.in.md",
            "ordered-numbering.in.md",
            "soft-breaks.in.md",
        ]

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

        for fixture in fixtures {
            let md = try loadFixtureMarkdown(name: fixture)
            for profile in profiles {
                let attr = NativeMarkdownCodec.importMarkdown(md, options: profile.options)
                let textView = makeLaidOutTextView(attr: attr, width: 900, height: 1400)
                try assertListMarkerAlignment(textView: textView, context: "\(profile.name):\(fixture)")
            }
        }
    }

    // MARK: - TextKit helpers

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

    @MainActor
    private func requireFirstIndex(of needle: String, in haystack: String) throws -> Int {
        let ns = haystack as NSString
        let r = ns.range(of: needle)
        if r.location == NSNotFound {
            XCTFail("Expected to find substring '\(needle)' in '\(haystack)'")
            throw NSError(domain: "NativeEditorMarkerAlignmentMetricSpecTests", code: 1)
        }
        return r.location
    }

    @MainActor
    private func requireFirstIndex(with key: NSAttributedString.Key, in textView: NSTextView) throws -> Int {
        guard let storage = textView.textStorage else {
            XCTFail("Missing textStorage")
            throw NSError(domain: "NativeEditorMarkerAlignmentMetricSpecTests", code: 2)
        }
        var found: Int?
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            if (value as? Bool) == true {
                found = range.location
                stop.pointee = true
            }
        }
        guard let found else {
            XCTFail("Expected to find attribute \(key.rawValue)")
            throw NSError(domain: "NativeEditorMarkerAlignmentMetricSpecTests", code: 3)
        }
        return found
    }

    // MARK: - Fixture loading

    private func loadFixtureMarkdown(name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures/native-editor-golden", isDirectory: true)
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Alignment sweep

    @MainActor
    private func assertListMarkerAlignment(textView: NSTextView, context: String) throws {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString

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
                    for mi in markerIndices {
                        let markerRect = glyphRect(atCharIndex: mi, in: textView)
                        let deltaMidY = abs(markerRect.midY - contentRect.midY)
                        XCTAssertLessThan(
                            deltaMidY,
                            2.0,
                            "[\(context)] kind=\(kind) marker='\(ns.substring(with: NSRange(location: mi, length: 1)))' not vertically centered (deltaMidY=\(deltaMidY))"
                        )
                    }
                }
            }

            idx = para.location + para.length
        }
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
            return CharacterSet.alphanumerics.contains(scalar)
        }

        // Find the first content character (non-marker, non-whitespace).
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

        // Collect marker glyph indices in the prefix region (marker + non-whitespace + "interesting" chars).
        var markerIndices: [Int] = []
        let scanEnd = min(end, para.location + 32) // marker prefixes should be tiny
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
}
