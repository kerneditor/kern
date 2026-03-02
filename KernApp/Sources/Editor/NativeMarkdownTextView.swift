import AppKit

@MainActor
protocol NativeMarkdownTextViewDelegate: AnyObject {
    func nativeTextViewToggleCheckbox(at characterIndex: Int)
}

/// NSTextView subclass for the native editor prototype.
/// Handles hit-testing for checkboxes.
@MainActor
final class NativeMarkdownTextView: NSTextView {
    weak var nativeDelegate: NativeMarkdownTextViewDelegate?
    var suppressNextAutoNewlineContinuation = false
    var onHoverCodeBlockRangeChanged: ((NSRange?) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var lastHoverCodeBlockRange: NSRange?

    private enum CheckboxHitTarget: String {
        /// Toggle only when clicking directly on the checkbox glyph (Notion/GitHub-like).
        case glyph
        /// Toggle when clicking anywhere in the marker prefix (Kern preference).
        case marker
    }

    private func checkboxHitTarget() -> CheckboxHitTarget {
        let raw = UserDefaults.standard.string(forKey: "nativeEditor.checkboxHitTarget") ?? "glyph"
        return CheckboxHitTarget(rawValue: raw) ?? .glyph
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBlockquoteDecorations(in: dirtyRect)
        drawCodeBlockBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        super.updateTrackingAreas()

        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoverRange(nil)
        super.mouseExited(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            suppressNextAutoNewlineContinuation = true
            // Notion/GitHub-style: Shift+Enter inserts a soft line break (not a new list item).
            super.insertLineBreak(sender)
            return
        }
        super.insertNewline(sender)
    }

    override func insertLineBreak(_ sender: Any?) {
        suppressNextAutoNewlineContinuation = true
        super.insertLineBreak(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let pointInWindow = event.locationInWindow
        let point = convert(pointInWindow, from: nil)

        if let idx = characterIndex(at: point), let storage = textStorage {
            let attrs = storage.attributes(at: idx, effectiveRange: nil)
            let target = checkboxHitTarget()

            // Always allow direct checkbox clicks to toggle.
            if (attrs[.kernCheckbox] as? Bool) == true {
                nativeDelegate?.nativeTextViewToggleCheckbox(at: idx)
                return
            }

            // Optional: marker-prefix click toggles (bullet dot / ordered marker / space prefix).
            if target == .marker, (attrs[.kernMarker] as? Bool) == true {
                let ns = storage.string as NSString
                let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
                if paraRange.location < storage.length {
                    let searchLen = min(paraRange.length, 64)
                    let searchRange = NSRange(location: paraRange.location, length: searchLen)
                    var checkboxIndex: Int?
                    storage.enumerateAttribute(.kernCheckbox, in: searchRange, options: []) { value, range, stop in
                        guard (value as? Bool) == true else { return }
                        checkboxIndex = range.location
                        stop.pointee = true
                    }
                    if let checkboxIndex {
                        nativeDelegate?.nativeTextViewToggleCheckbox(at: checkboxIndex)
                        return
                    }
                }
            }
        }

        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let plainText = plainTextFromPasteboard(NSPasteboard.general) {
            insertPlainPastedText(plainText)
            return
        }
        super.paste(sender)
    }

    /// Test seam: simulates pasting rich text while ensuring only plain text is inserted.
    func _debugPasteAttributedStringForTests(_ attributed: NSAttributedString) {
        insertPlainPastedText(attributed.string)
    }

    /// Test seam: simulates plain-text paste handling without touching the system pasteboard.
    func _debugPastePlainStringForTests(_ text: String) {
        insertPlainPastedText(text)
    }

    private func insertPlainPastedText(_ text: String) {
        let normalized = normalizePastedText(text)
        guard !normalized.isEmpty else { return }
        suppressNextAutoNewlineContinuation = true
        insertText(normalized, replacementRange: selectedRange())
    }

    private func normalizePastedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func plainTextFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return normalizePastedText(string)
        }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ),
           !attributed.string.isEmpty {
            return normalizePastedText(attributed.string)
        }
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtfd],
               documentAttributes: nil
           ),
           !attributed.string.isEmpty {
            return normalizePastedText(attributed.string)
        }
        return nil
    }

    // MARK: - Hover Code Block Detection

    /// Used by tests to simulate hover without relying on WindowServer mouse-move plumbing.
    func _debugSimulateHover(at pointInTextView: NSPoint) {
        updateHover(at: pointInTextView)
    }

    private func updateHover(at pointInTextView: NSPoint) {
        // If the mouse is outside the visible rect (e.g. during scroll), treat as not-hovering.
        guard visibleRect.contains(pointInTextView) else {
            updateHoverRange(nil)
            return
        }
        let range = codeBlockCharacterRange(containing: pointInTextView)
        updateHoverRange(range)
    }

    private func updateHoverRange(_ range: NSRange?) {
        if rangesEqual(lhs: lastHoverCodeBlockRange, rhs: range) { return }
        lastHoverCodeBlockRange = range
        onHoverCodeBlockRangeChanged?(range)
    }

    private func rangesEqual(lhs: NSRange?, rhs: NSRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.location == r.location && l.length == r.length
        default:
            return false
        }
    }

    /// Returns the character range for the code block whose rounded background contains the point.
    /// This matches the code-block background drawing logic, so hovering in padding still counts.
    private func codeBlockCharacterRange(containing pointInTextView: NSPoint) -> NSRange? {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return nil }
        let ns = storage.string as NSString

        // Scan only the visible glyph range.
        let containerRect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        let startLimit = max(0, visibleChars.location)
        let endLimit = min(ns.length, visibleChars.location + visibleChars.length)

        var idx = startLimit
        while idx < endLimit {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard para.length > 0 else { break }
            guard para.location < storage.length else { break }

            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph

            if kind == .codeBlock {
                let codeBlockID = storage.attribute(.kernCodeBlockID, at: para.location, effectiveRange: nil) as? Int
                let quoteDepth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0

                // Group consecutive codeBlock paragraphs (represents one fenced block).
                var start = para.location
                var end = para.location + para.length
                var scan = end
                while scan < ns.length {
                    let next = ns.paragraphRange(for: NSRange(location: scan, length: 0))
                    if next.length == 0 { break }
                    guard next.location < storage.length else { break }
                    let kRaw = storage.attribute(.kernBlockKind, at: next.location, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    if k != .codeBlock { break }

                    let nextQuoteDepth = (storage.attribute(.kernQuoteDepth, at: next.location, effectiveRange: nil) as? Int) ?? 0
                    if nextQuoteDepth != quoteDepth { break }

                    // Stop at boundaries between back-to-back fenced blocks.
                    if let codeBlockID {
                        let nextID = storage.attribute(.kernCodeBlockID, at: next.location, effectiveRange: nil) as? Int
                        if nextID != codeBlockID { break }
                    } else if (storage.attribute(.kernCodeBlockID, at: next.location, effectiveRange: nil) as? Int) != nil {
                        break
                    }

                    end = next.location + next.length
                    scan = end
                }

                let charRange = NSRange(location: start, length: max(0, end - start))
                let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                rect.origin.x += textContainerOrigin.x
                rect.origin.y += textContainerOrigin.y
                var lineSpanRect: NSRect?
                if glyphRange.length > 0 {
                    var effective = NSRange(location: 0, length: 0)
                    var lf = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
                    lf.origin.x += textContainerOrigin.x
                    lf.origin.y += textContainerOrigin.y

                    let left = rect.minX
                    let right = lf.maxX
                    lineSpanRect = NSRect(x: left, y: lf.minY, width: max(0, right - left), height: lf.height)
                }
                rect = CodeBlockChromeGeometry.backgroundRect(forGlyphBoundingRect: rect, lineFragmentRect: lineSpanRect, isFlipped: isFlipped)

                if rect.contains(pointInTextView) {
                    return charRange
                }

                idx = end
                continue
            }

            idx = para.location + para.length
        }

        return nil
    }

    private func drawCodeBlockBackgrounds(in dirtyRect: NSRect) {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let ns = storage.string as NSString

        let bg = NSColor(white: 0, alpha: 0.08)
        let stroke = NSColor(white: 0, alpha: 0.10)

        // Only scan paragraphs that intersect the dirty rect (TextKit coordinates).
        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let dirtyGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let dirtyChars = lm.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)

        let startLimit = max(0, dirtyChars.location)
        let endLimit = min(ns.length, dirtyChars.location + dirtyChars.length)

        var idx = startLimit
        while idx < endLimit {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard para.length > 0 else { break }

            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph

            if kind == .codeBlock {
                let codeBlockID = storage.attribute(.kernCodeBlockID, at: para.location, effectiveRange: nil) as? Int
                let quoteDepth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0

                // Group consecutive codeBlock paragraphs (represents one fenced block).
                var start = para.location
                var end = para.location + para.length
                var scan = end
                while scan < ns.length {
                    let next = ns.paragraphRange(for: NSRange(location: scan, length: 0))
                    if next.length == 0 { break }
                    let kRaw = storage.attribute(.kernBlockKind, at: next.location, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    if k != .codeBlock { break }

                    let nextQuoteDepth = (storage.attribute(.kernQuoteDepth, at: next.location, effectiveRange: nil) as? Int) ?? 0
                    if nextQuoteDepth != quoteDepth { break }

                    // Stop at boundaries between back-to-back fenced blocks.
                    if let codeBlockID {
                        let nextID = storage.attribute(.kernCodeBlockID, at: next.location, effectiveRange: nil) as? Int
                        if nextID != codeBlockID { break }
                    } else if (storage.attribute(.kernCodeBlockID, at: next.location, effectiveRange: nil) as? Int) != nil {
                        break
                    }

                    end = next.location + next.length
                    scan = end
                }

                let charRange = NSRange(location: start, length: max(0, end - start))
                let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                rect.origin.x += textContainerOrigin.x
                rect.origin.y += textContainerOrigin.y
                var lineSpanRect: NSRect?
                if glyphRange.length > 0 {
                    var effective = NSRange(location: 0, length: 0)
                    var lf = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
                    lf.origin.x += textContainerOrigin.x
                    lf.origin.y += textContainerOrigin.y

                    let left = rect.minX
                    let right = lf.maxX
                    lineSpanRect = NSRect(x: left, y: lf.minY, width: max(0, right - left), height: lf.height)
                }
                rect = CodeBlockChromeGeometry.backgroundRect(forGlyphBoundingRect: rect, lineFragmentRect: lineSpanRect, isFlipped: isFlipped)

                if rect.intersects(dirtyRect) {
                    let path = NSBezierPath(
                        roundedRect: rect,
                        xRadius: CodeBlockChromeGeometry.cornerRadius,
                        yRadius: CodeBlockChromeGeometry.cornerRadius
                    )
                    bg.setFill()
                    path.fill()

                    stroke.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }

                idx = end
                continue
            }

            idx = para.location + para.length
        }
    }

    private func drawBlockquoteDecorations(in dirtyRect: NSRect) {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let ns = storage.string as NSString

        let barColor = NSColor.separatorColor.withAlphaComponent(0.75)
        let fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 16
        let minBarHeight: CGFloat = 10

        // Restrict work to paragraphs intersecting the dirty rect.
        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let dirtyGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let dirtyChars = lm.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)

        let startLimit = max(0, dirtyChars.location)
        let endLimit = min(ns.length, dirtyChars.location + dirtyChars.length)

        var idx = startLimit
        while idx < endLimit {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard para.length > 0 else { break }
            guard para.location < storage.length else { break }

            let quoteDepth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0
            if quoteDepth > 0 {
                let glyphRange = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
                if glyphRange.length > 0 {
                    var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                    rect.origin.x += textContainerOrigin.x
                    rect.origin.y += textContainerOrigin.y

                    if rect.height < minBarHeight {
                        var effective = NSRange(location: 0, length: 0)
                        var line = lm.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
                        line.origin.x += textContainerOrigin.x
                        line.origin.y += textContainerOrigin.y
                        rect = line
                    }

                    if rect.intersects(dirtyRect) {
                        let style = storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
                        let quoteIndent = CGFloat(quoteDepth) * barSpacing
                        let baseIndent = max(0, (style?.headIndent ?? 0) - quoteIndent)
                        let firstBarX = textContainerOrigin.x + baseIndent + 4

                        let fillX = firstBarX + 8
                        let fillWidth = max(0, rect.maxX - fillX + 4)
                        if fillWidth > 2 {
                            let fillRect = NSRect(x: fillX, y: rect.minY, width: fillWidth, height: rect.height).integral
                            if fillRect.height > 1 {
                                fillColor.setFill()
                                NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
                            }
                        }

                        let barHeight = max(minBarHeight, rect.height - 2)
                        let barY = rect.minY + max(1, (rect.height - barHeight) / 2)
                        for level in 0..<quoteDepth {
                            let x = firstBarX + CGFloat(level) * barSpacing + 0.5
                            let path = NSBezierPath()
                            path.move(to: NSPoint(x: x, y: barY))
                            path.line(to: NSPoint(x: x, y: barY + barHeight))
                            path.lineWidth = barWidth
                            barColor.setStroke()
                            path.stroke()
                        }
                    }
                }
            }

            idx = para.location + para.length
        }
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        // TextKit uses textContainerOrigin offsets for padding/insets.
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard charIndex >= 0, let storage = textStorage, charIndex < storage.length else { return nil }
        return charIndex
    }
}
