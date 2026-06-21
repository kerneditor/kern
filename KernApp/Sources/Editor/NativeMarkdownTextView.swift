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
    var currentHoverCodeBlockRange: NSRange? { lastHoverCodeBlockRange }

    static let kernMarkdownPasteboardType = NSPasteboard.PasteboardType("com.gradigit.kern.markdown")

    struct DebugCheckboxDecoration {
        let characterRange: NSRange
        let rect: NSRect
        let checked: Bool
    }

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
        drawInlineCodeBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
        drawCheckboxDecorations(in: dirtyRect)
    }

    private func drawCheckboxDecorations(in dirtyRect: NSRect) {
        for decoration in checkboxDecorations(in: dirtyRect) {
            drawCheckbox(in: decoration.rect, checked: decoration.checked)
        }
    }

    func _debugCheckboxDecorationsForTests(in dirtyRect: NSRect? = nil) -> [DebugCheckboxDecoration] {
        checkboxDecorations(in: dirtyRect ?? bounds)
    }

    func _debugCalloutGroupRangeForTests(containing location: Int) -> NSRange? {
        guard let storage = textStorage,
              location >= 0,
              location < storage.length else { return nil }
        let quoteDepth = (storage.attribute(.kernQuoteDepth, at: location, effectiveRange: nil) as? Int) ?? 0
        guard quoteDepth > 0 else { return nil }

        let ns = storage.string as NSString
        guard let group = calloutGroup(containing: location, quoteDepth: quoteDepth, storage: storage, ns: ns) else {
            return nil
        }
        return NSRange(location: group.start, length: max(0, group.end - group.start))
    }

    private func checkboxDecorations(in dirtyRect: NSRect) -> [DebugCheckboxDecoration] {
        guard let storage = textStorage,
              let lm = layoutManager,
              let tc = textContainer,
              storage.length > 0 else { return [] }

        let sourceRect = visibleRect.isEmpty ? bounds : visibleRect
        let containerRect = sourceRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let clampedVisibleChars = NSIntersectionRange(visibleChars, NSRange(location: 0, length: storage.length))
        guard clampedVisibleChars.length > 0 else { return [] }

        var decorations: [DebugCheckboxDecoration] = []
        storage.enumerateAttribute(.kernCheckbox, in: clampedVisibleChars, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            guard let glyphRange = glyphRangeForCheckboxCharacter(range, layoutManager: lm),
                  glyphRange.length > 0 else { return }

            let checked = (storage.attribute(.kernCheckboxChecked, at: range.location, effectiveRange: nil) as? Bool) ?? false
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let rect = checkboxRect(forGlyphRange: glyphRange, font: font, layoutManager: lm, textContainer: tc)
            guard !rect.isNull, rect.intersects(dirtyRect) else { return }

            decorations.append(DebugCheckboxDecoration(characterRange: range, rect: rect, checked: checked))
        }
        return decorations
    }

    private func glyphRangeForCheckboxCharacter(_ range: NSRange, layoutManager: NSLayoutManager) -> NSRange? {
        var actualCharRange = NSRange(location: 0, length: 0)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: range.location, length: min(1, range.length)),
            actualCharacterRange: &actualCharRange
        )
        return glyphRange.length > 0 ? glyphRange : nil
    }

    private func checkboxRect(
        forGlyphRange glyphRange: NSRange,
        font: NSFont?,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect {
        var lineGlyphRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: &lineGlyphRange
        )
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let pointSize = font?.pointSize ?? self.font?.pointSize ?? NSFont.systemFontSize
        let side = max(12, min(17, pointSize * 0.86))
        let origin = textContainerOrigin
        let midX = origin.x + (glyphRect.isEmpty ? glyphRect.origin.x + side / 2 : glyphRect.midX)
        let midY = origin.y + (lineRect.isEmpty ? glyphRect.midY : lineRect.midY)
        return NSRect(
            x: (midX - side / 2).rounded(.toNearestOrAwayFromZero) + 0.5,
            y: (midY - side / 2).rounded(.toNearestOrAwayFromZero) + 0.5,
            width: side.rounded(.toNearestOrAwayFromZero),
            height: side.rounded(.toNearestOrAwayFromZero)
        )
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let accent = NativeEditorAppearance.linkColor().usingColorSpace(.deviceRGB) ?? .systemBlue
        let secondary = NativeEditorAppearance.secondaryTextColor().usingColorSpace(.deviceRGB) ?? .secondaryLabelColor
        let background = NativeEditorAppearance.editorBackgroundColor(appearance: effectiveAppearance)
            .usingColorSpace(.deviceRGB) ?? .textBackgroundColor
        let radius = min(4.5, rect.width * 0.30)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if checked {
            accent.setFill()
            path.fill()
            accent.blended(withFraction: 0.18, of: .white)?.setStroke()
            path.lineWidth = 1
            path.stroke()

            let check = NSBezierPath()
            check.lineWidth = max(1.7, rect.width * 0.14)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.55))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.72))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.32))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            background.withAlphaComponent(0.96).setFill()
            path.fill()
            secondary.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
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

    override func copy(_ sender: Any?) {
        if let markdown = markdownStringForCopySelection(),
           !markdown.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(markdown, forType: .string)
            pasteboard.setString(markdown, forType: Self.kernMarkdownPasteboardType)
            return
        }
        super.copy(sender)
    }

    /// Test seam: simulates pasting rich text while ensuring only plain text is inserted.
    func _debugPasteAttributedStringForTests(_ attributed: NSAttributedString) {
        insertPlainPastedText(attributed.string)
    }

    /// Test seam: simulates plain-text paste handling without touching the system pasteboard.
    func _debugPastePlainStringForTests(_ text: String) {
        insertPlainPastedText(text)
    }

    /// Test seam: returns the markdown payload that `copy(_:)` would publish when copy-fidelity
    /// override is active for the current selection.
    func _debugCopyMarkdownStringForCurrentSelectionForTests() -> String? {
        markdownStringForCopySelection()
    }

    /// Test seam: convert attributed rich text into markdown-like semantic text without
    /// touching pasteboard state.
    func _debugMarkdownFromAttributedPasteForTests(_ attributed: NSAttributedString) -> String {
        markdownFromAttributedForPaste(attributed)
    }

    private func insertPlainPastedText(_ text: String) {
        let normalized = normalizePastedText(text)
        guard !normalized.isEmpty else { return }
        suppressNextAutoNewlineContinuation = true
        let insertionAttributes = normalizedPasteInsertionAttributes()
        let attributed = NSAttributedString(string: normalized, attributes: insertionAttributes)
        let replacementRange = selectedRange()
        guard shouldChangeText(in: replacementRange, replacementString: normalized) else { return }
        textStorage?.replaceCharacters(in: replacementRange, with: attributed)
        didChangeText()
        setSelectedRange(NSRange(location: replacementRange.location + attributed.length, length: 0))
        typingAttributes = insertionAttributes
    }

    private func normalizePastedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func markdownStringForCopySelection() -> String? {
        guard let storage = textStorage else { return nil }
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return nil }
        let selection = selectedRange()
        guard NSEqualRanges(selection, fullRange) else { return nil }
        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        return NativeMarkdownCodec.exportMarkdown(storage, options: options)
    }

    private func plainTextFromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        if let markdown = pasteboard.string(forType: Self.kernMarkdownPasteboardType), !markdown.isEmpty {
            return normalizePastedText(markdown)
        }
        if let rich = attributedStringFromPasteboard(pasteboard), rich.length > 0 {
            let semanticMarkdown = markdownFromAttributedForPaste(rich)
            if !semanticMarkdown.isEmpty {
                return normalizePastedText(semanticMarkdown)
            }
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return normalizePastedText(string)
        }
        return nil
    }

    private func attributedStringFromPasteboard(_ pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ),
           attributed.length > 0 {
            return attributed
        }
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtfd],
               documentAttributes: nil
           ),
           attributed.length > 0 {
            return attributed
        }
        if let data = pasteboard.data(forType: .html),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ),
           attributed.length > 0 {
            return attributed
        }
        return nil
    }

    private func normalizedPasteInsertionAttributes() -> [NSAttributedString.Key: Any] {
        var attrs = typingAttributes
        attrs[.font] = insertionContextFont()
        attrs[.foregroundColor] = NSColor.labelColor
        attrs.removeValue(forKey: .backgroundColor)
        attrs.removeValue(forKey: .underlineStyle)
        attrs.removeValue(forKey: .underlineColor)
        attrs.removeValue(forKey: .strikethroughStyle)
        attrs.removeValue(forKey: .strikethroughColor)
        attrs.removeValue(forKey: .link)
        return attrs
    }

    private func insertionContextFont() -> NSFont {
        if let storage = textStorage,
           storage.length > 0 {
            let selection = selectedRange()
            if selection.location > 0 {
                let previousIndex = min(storage.length - 1, selection.location - 1)
                if let font = storage.attribute(.font, at: previousIndex, effectiveRange: nil) as? NSFont {
                    return font
                }
            }

            if selection.location < storage.length,
               let font = storage.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont {
                return font
            }
        }

        if let font = self.font {
            return font
        }

        return NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    private func markdownFromAttributedForPaste(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let ns = attributed.string as NSString
        var out = ""
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, range, _ in
            guard range.length > 0 else { return }
            let raw = ns.substring(with: range)
            out += markdownInlineFragment(raw: raw, attributes: attrs)
        }
        return out
    }

    private func markdownInlineFragment(raw: String, attributes: [NSAttributedString.Key: Any]) -> String {
        if raw.isEmpty { return raw }

        let font = attributes[.font] as? NSFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let isBold = traits.contains(.bold)
        let isItalic = traits.contains(.italic)
        let isMonospace = traits.contains(.monoSpace) || (font?.fontName.lowercased().contains("mono") ?? false)
        let hasStrike = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
        let linkURL = normalizedLinkURL(attributes[.link])

        if isMonospace {
            return wrapCorePreservingBoundaryWhitespace(raw) { core in
                let delimiter = core.contains("`") ? "``" : "`"
                return "\(delimiter)\(core)\(delimiter)"
            }
        }

        if let url = linkURL {
            return wrapCorePreservingBoundaryWhitespace(raw) { core in
                let escaped = escapeMarkdownText(core)
                if escaped == url {
                    return "<\(url)>"
                }
                return "[\(escaped)](\(url))"
            }
        }

        var result = wrapCorePreservingBoundaryWhitespace(raw) { core in
            var escaped = escapeMarkdownText(core)
            if isBold, isItalic {
                escaped = "***\(escaped)***"
            } else if isBold {
                escaped = "**\(escaped)**"
            } else if isItalic {
                escaped = "*\(escaped)*"
            }
            if hasStrike {
                escaped = "~~\(escaped)~~"
            }
            return escaped
        }

        // If there is only strike and boundary-preserving wrapper returned the original text
        // (all-whitespace case), preserve original as-is.
        if hasStrike, result == raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = raw
        }
        return result
    }

    private func normalizedLinkURL(_ value: Any?) -> String? {
        if let url = value as? URL {
            return url.absoluteString
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func wrapCorePreservingBoundaryWhitespace(_ text: String, _ transform: (String) -> String) -> String {
        guard !text.isEmpty else { return text }
        let chars = Array(text)
        var start = 0
        while start < chars.count, chars[start].isWhitespaceOrNewline {
            start += 1
        }
        var end = chars.count
        while end > start, chars[end - 1].isWhitespaceOrNewline {
            end -= 1
        }
        if start >= end { return text }
        let leading = String(chars[0..<start])
        let core = String(chars[start..<end])
        let trailing = String(chars[end..<chars.count])
        return leading + transform(core) + trailing
    }

    private func escapeMarkdownText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\\", "`", "*", "_", "[", "]", "(", ")", "~":
                out.append("\\")
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Hover Code Block Detection

    /// Used by tests to simulate hover without relying on WindowServer mouse-move plumbing.
    func _debugSimulateHover(at pointInTextView: NSPoint) {
        updateHover(at: pointInTextView)
    }

    func _debugSimulateHoverExit() {
        updateHoverRange(nil)
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
                let start = para.location
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

    private func drawInlineCodeBackgrounds(in dirtyRect: NSRect) {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let nsLength = storage.length
        guard nsLength > 0 else { return }

        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let dirtyGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let dirtyChars = lm.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)
        let start = max(0, dirtyChars.location)
        let end = min(nsLength, dirtyChars.location + dirtyChars.length)
        guard start < end else { return }

        let background = NativeEditorAppearance.inlineCodeBackgroundColor(appearance: effectiveAppearance)
        background.setFill()

        storage.enumerateAttribute(.kernInlineCode, in: NSRange(location: start, length: end - start), options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            lm.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, textContainer, lineGlyphRange, _ in
                let segment = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard segment.length > 0 else { return }

                var rect = lm.boundingRect(forGlyphRange: segment, in: textContainer)
                rect.origin.x += self.textContainerOrigin.x
                rect.origin.y += self.textContainerOrigin.y

                var line = lineRect
                line.origin.x += self.textContainerOrigin.x
                line.origin.y += self.textContainerOrigin.y

                let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                let fontHeight = font.map { ceil($0.ascender - $0.descender) } ?? ceil(rect.height)
                let height = min(line.height - 2, max(fontHeight + 4, rect.height + 4))
                let y = line.minY + ((line.height - height) / 2).rounded(.down)
                let pill = NSRect(
                    x: floor(rect.minX - 3),
                    y: y,
                    width: ceil(rect.width + 6),
                    height: ceil(height)
                )

                guard pill.intersects(dirtyRect) else { return }
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func drawCodeBlockBackgrounds(in dirtyRect: NSRect) {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let ns = storage.string as NSString

        let bg = NativeEditorAppearance.codeBlockBackgroundColor(appearance: effectiveAppearance)
        let stroke = NativeEditorAppearance.codeBlockStrokeColor(appearance: effectiveAppearance)

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
                let start = para.location
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

        let barColor = NativeEditorAppearance.quoteBarColor(appearance: effectiveAppearance).withAlphaComponent(0.85)
        let fillColor = NativeEditorAppearance.quoteFillColor(appearance: effectiveAppearance)
        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 16
        let minBarHeight: CGFloat = 10

        // Restrict work to paragraphs intersecting the dirty rect.
        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let dirtyGlyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let dirtyChars = lm.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)

        let startLimit = max(0, dirtyChars.location)
        let endLimit = min(ns.length, dirtyChars.location + dirtyChars.length)

        var drawnCalloutStarts = Set<Int>()
        var idx = startLimit
        while idx < endLimit {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard para.length > 0 else { break }
            guard para.location < storage.length else { break }

            let quoteDepth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0
            if quoteDepth > 0 {
                if let callout = calloutGroup(containing: para.location, quoteDepth: quoteDepth, storage: storage, ns: ns) {
                    if !drawnCalloutStarts.contains(callout.start) {
                        drawnCalloutStarts.insert(callout.start)
                        drawCalloutGroup(callout, quoteDepth: quoteDepth, dirtyRect: dirtyRect)
                    }
                    idx = para.location + para.length
                    continue
                }

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

    private struct CalloutGroup {
        let start: Int
        let end: Int
        let kind: KernCalloutKind
    }

    private func calloutGroup(containing location: Int, quoteDepth: Int, storage: NSTextStorage, ns: NSString) -> CalloutGroup? {
        guard location >= 0, location < storage.length else { return nil }
        var groupStart = location
        var scan = location
        while scan > 0 {
            let previousLocation = max(0, scan - 1)
            let previousPara = ns.paragraphRange(for: NSRange(location: previousLocation, length: 0))
            if previousPara.location == scan || previousPara.length == 0 { break }
            guard previousPara.location < storage.length else { break }
            let previousDepth = (storage.attribute(.kernQuoteDepth, at: previousPara.location, effectiveRange: nil) as? Int) ?? 0
            if previousDepth != quoteDepth { break }
            groupStart = previousPara.location
            scan = previousPara.location
        }

        var calloutStart: Int?
        var calloutKind: KernCalloutKind?
        scan = groupStart
        while scan < storage.length {
            let para = ns.paragraphRange(for: NSRange(location: scan, length: 0))
            guard para.length > 0, para.location < storage.length else { break }
            let depth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0
            if depth != quoteDepth { break }
            if let raw = storage.attribute(.kernCalloutKind, at: para.location, effectiveRange: nil) as? String,
               let kind = KernCalloutKind(rawValue: raw) {
                calloutStart = para.location
                calloutKind = kind
                break
            }
            scan = para.location + para.length
        }

        guard let start = calloutStart, let kind = calloutKind, location >= start else { return nil }

        var end = start
        scan = start
        while scan < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: scan, length: 0))
            guard para.length > 0, para.location < storage.length else { break }
            let depth = (storage.attribute(.kernQuoteDepth, at: para.location, effectiveRange: nil) as? Int) ?? 0
            if depth != quoteDepth { break }
            if para.location != start,
               storage.attribute(.kernCalloutKind, at: para.location, effectiveRange: nil) as? String != nil {
                break
            }
            end = para.location + para.length
            scan = end
        }

        return CalloutGroup(start: start, end: max(start, end), kind: kind)
    }

    private func drawCalloutGroup(_ callout: CalloutGroup, quoteDepth: Int, dirtyRect: NSRect) {
        guard let storage = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let charRange = NSRange(location: callout.start, length: max(0, callout.end - callout.start))
        guard charRange.length > 0 else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }

        var used = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        used.origin.x += textContainerOrigin.x
        used.origin.y += textContainerOrigin.y

        var line = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        line.origin.x += textContainerOrigin.x
        line.origin.y += textContainerOrigin.y

        let style = storage.attribute(.paragraphStyle, at: callout.start, effectiveRange: nil) as? NSParagraphStyle
        let quoteIndent: CGFloat = CGFloat(quoteDepth) * 16
        let baseIndent = max(0, (style?.headIndent ?? 0) - quoteIndent)
        let x = textContainerOrigin.x + baseIndent + 6
        let right = max(used.maxX + 14, line.maxX - 6)
        var rect = NSRect(
            x: x,
            y: used.minY - 7,
            width: max(32, right - x),
            height: used.height + 14
        ).integral
        if rect.height < 30 {
            rect.size.height = 30
            rect.origin.y = used.midY - 15
        }
        guard rect.intersects(dirtyRect) else { return }

        let styleColors = NativeEditorAppearance.calloutStyle(kind: callout.kind, appearance: effectiveAppearance)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        styleColors.fill.setFill()
        path.fill()
        styleColors.stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let accentRect = NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
        let accentPath = NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5)
        styleColors.accent.setFill()
        accentPath.fill()
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

private extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
