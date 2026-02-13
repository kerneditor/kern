import AppKit

/// Native TextKit-based editor prototype (no WebView).
///
/// Goal: prove the "true WYSIWYG + .md only" approach by:
/// - importing Markdown into an attributed-string representation that hides syntax
/// - letting the user edit rich text directly
/// - exporting back to deterministic Markdown
@MainActor
final class NativeEditorViewController: NSViewController, NSTextViewDelegate, NativeMarkdownTextViewDelegate {

    private let scrollView = NSScrollView()
    private let textView = NativeMarkdownTextView()
    private let codeCopyButton = NSButton(title: "Copy", target: nil, action: nil)

    private var isApplyingExternalUpdate = false
    private var isApplyingInputRules = false
    private var isApplyingAutoNewline = false
    private var exportWorkItem: DispatchWorkItem?
    private var codeCopyCharacterRange: NSRange?

    /// Markdown source (import/export). Setting this re-renders the text view.
    var stringValue: String = "" {
        didSet {
            guard !isApplyingExternalUpdate else { return }
            // Treat programmatic updates as external: do not mark the document dirty.
            isApplyingExternalUpdate = true
            renderMarkdown(stringValue, preserveSelection: false)
            isApplyingExternalUpdate = false
        }
    }

    /// Called when Markdown changes due to user editing.
    var onContentChanged: ((String) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.setAccessibilityIdentifier("NativeEditor.Container")

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityIdentifier("NativeEditor.ScrollView")

        textView.nativeDelegate = self
        textView.delegate = self
        textView.setAccessibilityIdentifier("NativeEditor.TextView")
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false

        let baseFont = NSFont.systemFont(ofSize: 16)
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        scrollView.documentView = textView
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        // Code block copy button (shown only when the caret is inside a code block).
        codeCopyButton.target = self
        codeCopyButton.action = #selector(copyActiveCodeBlock(_:))
        codeCopyButton.setAccessibilityIdentifier("NativeEditor.CodeCopyButton")
        codeCopyButton.bezelStyle = .rounded
        codeCopyButton.controlSize = .small
        codeCopyButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        codeCopyButton.isHidden = true
        container.addSubview(codeCopyButton)

        // Track scroll to keep the copy button positioned.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        view = container
    }

    // MARK: - External Updates

    /// Apply a Markdown update that originated outside the editor (file reload, initial load, etc).
    /// Preserves selection and scroll position where possible.
    func applyExternalMarkdownUpdate(_ markdown: String) {
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }

        let selection = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin

        // Update backing value without triggering didSet re-render twice.
        stringValue = markdown
        renderMarkdown(markdown, preserveSelection: false)

        // Best-effort restore.
        let maxLocation = max(0, textView.string.count)
        let safeLoc = min(selection.location, maxLocation)
        textView.setSelectedRange(NSRange(location: safeLoc, length: 0))

        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func renderMarkdown(_ markdown: String, preserveSelection: Bool) {
        let selection = preserveSelection ? textView.selectedRange() : nil
        let scrollOrigin = preserveSelection ? scrollView.contentView.bounds.origin : nil

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let attr = NativeMarkdownCodec.importMarkdown(markdown, options: opt)
        textView.textStorage?.setAttributedString(attr)

        if let selection {
            let maxLocation = max(0, textView.string.count)
            let safeLoc = min(selection.location, maxLocation)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
        }
        if let scrollOrigin {
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Checkbox Toggle

    func nativeTextViewToggleCheckbox(at characterIndex: Int) {
        guard let storage = textView.textStorage, characterIndex < storage.length else { return }

        // Preserve semantic attributes that might be stored only on the checkbox character
        // (ex: standalone task style uses index 0 == checkbox).
        let existingTaskStyle = storage.attribute(.kernTaskStyle, at: characterIndex, effectiveRange: nil)
        let existingBlockKind = storage.attribute(.kernBlockKind, at: characterIndex, effectiveRange: nil)
        let existingHeadingLevel = storage.attribute(.kernHeadingLevel, at: characterIndex, effectiveRange: nil)
        let existingOrderedIndex = storage.attribute(.kernOrderedIndex, at: characterIndex, effectiveRange: nil)
        let existingOrderedIsTask = storage.attribute(.kernOrderedIsTask, at: characterIndex, effectiveRange: nil)
        let existingParagraphStyle = storage.attribute(.paragraphStyle, at: characterIndex, effectiveRange: nil)

        let checked = (storage.attribute(.kernCheckboxChecked, at: characterIndex, effectiveRange: nil) as? Bool) ?? false
        let newChecked = !checked

        // Preserve visual attributes (font/baseline) so toggling doesn't shrink/misalign the checkbox.
        let existingFont = storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
        let existingBaseline = storage.attribute(.baselineOffset, at: characterIndex, effectiveRange: nil)
        let existingColor = storage.attribute(.foregroundColor, at: characterIndex, effectiveRange: nil) as? NSColor

        let newChar = newChecked ? "\u{2611}" : "\u{2610}" // ☑ / ☐
        storage.replaceCharacters(in: NSRange(location: characterIndex, length: 1), with: newChar)

        if let existingFont {
            storage.addAttribute(.font, value: existingFont, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingBaseline {
            storage.addAttribute(.baselineOffset, value: existingBaseline, range: NSRange(location: characterIndex, length: 1))
        } else {
            storage.addAttribute(.baselineOffset, value: -1, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingColor {
            storage.addAttribute(.foregroundColor, value: existingColor, range: NSRange(location: characterIndex, length: 1))
        }

        // Restore semantic attributes that are not re-applied elsewhere.
        if let existingTaskStyle {
            storage.addAttribute(.kernTaskStyle, value: existingTaskStyle, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingBlockKind {
            storage.addAttribute(.kernBlockKind, value: existingBlockKind, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingHeadingLevel {
            storage.addAttribute(.kernHeadingLevel, value: existingHeadingLevel, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingOrderedIndex {
            storage.addAttribute(.kernOrderedIndex, value: existingOrderedIndex, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingOrderedIsTask {
            storage.addAttribute(.kernOrderedIsTask, value: existingOrderedIsTask, range: NSRange(location: characterIndex, length: 1))
        }
        if let existingParagraphStyle {
            storage.addAttribute(.paragraphStyle, value: existingParagraphStyle, range: NSRange(location: characterIndex, length: 1))
        }

        storage.addAttribute(.kernCheckbox, value: true, range: NSRange(location: characterIndex, length: 1))
        storage.addAttribute(.kernCheckboxChecked, value: newChecked, range: NSRange(location: characterIndex, length: 1))
        storage.addAttribute(.kernMarker, value: true, range: NSRange(location: characterIndex, length: 1))

        // Apply/remove strikethrough on the task's content.
        applyTaskCheckedStyle(checkboxCharacterIndex: characterIndex, checked: newChecked)

        scheduleExport()
    }

    private func applyTaskCheckedStyle(checkboxCharacterIndex: Int, checked: Bool) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        guard checkboxCharacterIndex < ns.length else { return }

        let paraRange = ns.paragraphRange(for: NSRange(location: checkboxCharacterIndex, length: 0))
        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length > 0 else { return }

        // Skip marker prefix.
        var start = contentRange.location
        while start < contentRange.location + contentRange.length {
            let isMarker = (storage.attribute(.kernMarker, at: start, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            start += 1
        }
        let bodyRange = NSRange(location: start, length: max(0, contentRange.location + contentRange.length - start))
        guard bodyRange.length > 0 else { return }

        if checked {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: bodyRange)
        } else {
            storage.removeAttribute(.strikethroughStyle, range: bodyRange)
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalUpdate else { return }
        guard !isApplyingInputRules else { return }
        guard !isApplyingAutoNewline else { return }

        // Mark the document edited immediately so Save is enabled even if export is debounced.
        // The markdown string itself is still produced by export (debounced or flushed on save).
        if let doc = view.window?.windowController?.document {
            doc.updateChangeCount(.changeDone)
        }

        applyMarkdownInputRulesIfNeeded()
        handleNewlineContinuationIfNeeded()
        updateCodeCopyButtonVisibilityAndPosition()
        scheduleExport()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isApplyingExternalUpdate else { return true }
        guard let storage = textView.textStorage, storage.length > 0 else { return true }

        // Keyboard shortcut: space toggles a checkbox when the caret is on (or immediately after)
        // the checkbox marker. This avoids fragile click targeting and matches common editor UX.
        if affectedCharRange.length == 0, replacementString == " " {
            let caret = affectedCharRange.location
            if caret < storage.length,
               ((storage.attribute(.kernCheckbox, at: caret, effectiveRange: nil) as? Bool) ?? false) {
                nativeTextViewToggleCheckbox(at: caret)
                return false
            }
            if caret > 0, caret - 1 < storage.length,
               ((storage.attribute(.kernCheckbox, at: caret - 1, effectiveRange: nil) as? Bool) ?? false) {
                nativeTextViewToggleCheckbox(at: caret - 1)
                return false
            }
        }

        // Disallow edits that touch marker regions (bullet + checkbox prefix).
        if affectedCharRange.length == 0 {
            // Insertion: block if insertion point is on a marker character.
            if affectedCharRange.location < storage.length {
                let isMarker = (storage.attribute(.kernMarker, at: affectedCharRange.location, effectiveRange: nil) as? Bool) ?? false
                if isMarker { return false }
            }
        } else {
            var hitsMarker = false
            storage.enumerateAttribute(.kernMarker, in: affectedCharRange, options: []) { value, _, stop in
                if (value as? Bool) == true {
                    hitsMarker = true
                    stop.pointee = true
                }
            }
            if hitsMarker { return false }
        }

        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCodeCopyButtonVisibilityAndPosition()
    }

    // MARK: - Export

    private func scheduleExport() {
        exportWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let opt = NativeMarkdownCodec.Options.fromUserDefaults()
            let markdown = NativeMarkdownCodec.exportMarkdown(self.textView.attributedString(), options: opt)
            self.onContentChanged?(markdown)
        }

        exportWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    /// Force an immediate export of the current editor state, cancelling any pending debounce.
    /// Used for correctness on explicit Save operations.
    func flushPendingExport() {
        exportWorkItem?.cancel()
        exportWorkItem = nil

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let markdown = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: opt)
        onContentChanged?(markdown)
    }

    // MARK: - Input Rules (Very Small MVP)

    /// Converts a tiny subset of typed Markdown into WYSIWYG blocks on the current paragraph:
    /// - `# ` .. `###### ` -> heading
    /// - `- ` -> bullet
    /// - `- [ ] ` / `- [x] ` -> task
    ///
    /// This intentionally does not attempt full incremental Markdown parsing.
    private func applyMarkdownInputRulesIfNeeded() {
        guard let storage = textView.textStorage else { return }

        let caret = textView.selectedRange().location
        let ns = storage.string as NSString
        let safeLoc = min(max(0, caret), ns.length)
        let paraRange = ns.paragraphRange(for: NSRange(location: safeLoc, length: 0))

        // Drop trailing newline from the paragraph content range.
        var contentLen = paraRange.length
        if contentLen > 0 {
            let last = paraRange.location + contentLen - 1
            if last < ns.length, ns.character(at: last) == 10 { // '\n'
                contentLen -= 1
            }
        }
        let contentRange = NSRange(location: paraRange.location, length: max(0, contentLen))
        guard contentRange.length > 0 else { return }

        // Don't convert inside code blocks or tables.
        let kindRaw = storage.attribute(.kernBlockKind, at: contentRange.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        if kind == .codeBlock || kind == .tableCell { return }

        let line = storage.attributedSubstring(from: contentRange).string
        guard shouldConvertTypedMarkdown(line) else { return }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }

        // Reuse our importer to hide typed syntax and apply attributes deterministically.
        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let imported = NativeMarkdownCodec.importMarkdown(line, options: opt)
        let delta = imported.length - contentRange.length
        storage.replaceCharacters(in: contentRange, with: imported)

        // Keep the caret reasonably close (best-effort).
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
    }

    private func shouldConvertTypedMarkdown(_ line: String) -> Bool {
        // Headings
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        if level >= 1, level <= 6 {
            let i = line.index(line.startIndex, offsetBy: level)
            if i < line.endIndex, line[i] == " " {
                return true
            }
        }

        // Tasks (standard + Kern/Notion-style)
        if line.hasPrefix("- ["), line.count >= 6 {
            // Only convert tasks once the full marker is present: "- [ ] " / "- [x] "
            let chars = Array(line)
            if chars[0] == "-", chars[1] == " ", chars[2] == "[", chars[4] == "]", chars[5] == " " {
                let c = chars[3]
                if c == " " || c == "x" || c == "X" {
                    return true
                }
            }
        }
        if line.hasPrefix("[] ") { return true }
        if line.hasPrefix("[ ] ") { return true }
        if line.hasPrefix("[x] ") || line.hasPrefix("[X] ") { return true }

        // Ordered list: "1. "
        if isOrderedListPrefix(line) { return true }

        // Bullet list: "- "
        if line == "- " { return true }

        return false
    }

    private func isOrderedListPrefix(_ line: String) -> Bool {
        // Trigger once the user has typed the space after the dot: "12. "
        guard line.count >= 3 else { return false }
        var digits = ""
        for ch in line {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard !digits.isEmpty else { return false }
        let i = line.index(line.startIndex, offsetBy: digits.count)
        guard i < line.endIndex, line[i] == "." else { return false }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return false }
        return true
    }

    private func handleNewlineContinuationIfNeeded() {
        guard let storage = textView.textStorage else { return }
        if textView.suppressNextAutoNewlineContinuation {
            textView.suppressNextAutoNewlineContinuation = false
            setBaseTypingAttributes()
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }

        let caret = selection.location
        let ns = storage.string as NSString
        guard caret > 0, caret <= ns.length else { return }
        guard ns.character(at: caret - 1) == 10 else { return } // '\n'

        let prevPara = ns.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let prevKindRaw = storage.attribute(.kernBlockKind, at: max(0, prevPara.location), effectiveRange: nil) as? Int
        let prevKind = KernBlockKind(rawValue: prevKindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph

        let currPara = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let currContentRange = paragraphContentRange(ns: ns, paraRange: currPara)

        // Helper: compute content in previous paragraph (excluding marker + trailing newline).
        let prevContent = previousParagraphContent(storage: storage, ns: ns, paraRange: prevPara)
        let prevContentIsEmpty = prevContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Headings: pressing Enter should exit to a normal paragraph.
        if prevKind == .heading {
            setBaseTypingAttributes()
            return
        }

        // Lists: continue on Enter; exit on empty item (i.e. second Enter).
        if prevKind == .bullet || prevKind == .task || prevKind == .ordered {
            if prevContentIsEmpty {
                isApplyingAutoNewline = true
                defer { isApplyingAutoNewline = false }

                // Remove the marker-only list item above and turn it into an empty paragraph.
                let removed = removeMarkerPrefix(in: prevPara, storage: storage, ns: ns)
                // Deleting characters above the caret shifts the caret left.
                let newCaret = max(0, caret - removed)
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))

                setBaseTypingAttributes()
                return
            }

            // Only continue if the new paragraph is still empty.
            if currContentRange.length == 0 {
                isApplyingAutoNewline = true
                defer { isApplyingAutoNewline = false }

                let markerLine: String
                switch prevKind {
                case .bullet:
                    markerLine = "- "
                case .task:
                    let styleRaw = storage.attribute(.kernTaskStyle, at: prevPara.location, effectiveRange: nil) as? Int
                    let style = KernTaskStyle(rawValue: styleRaw ?? KernTaskStyle.bulleted.rawValue) ?? .bulleted
                    markerLine = style == .standalone ? "[] " : "- [ ] "
                case .ordered:
                    let prevN = (storage.attribute(.kernOrderedIndex, at: prevPara.location, effectiveRange: nil) as? Int) ?? 1
                    let orderedIsTask = (storage.attribute(.kernOrderedIsTask, at: prevPara.location, effectiveRange: nil) as? Bool) ?? false
                    markerLine = orderedIsTask ? "\(max(1, prevN + 1)). [ ] " : "\(max(1, prevN + 1)). "
                default:
                    markerLine = ""
                }

                let opt = NativeMarkdownCodec.Options.fromUserDefaults()
                let imported = NativeMarkdownCodec.importMarkdown(markerLine, options: opt)
                storage.replaceCharacters(in: currContentRange, with: imported)

                let markerLen = markerPrefixLength(in: imported)
                let newCaret = min(storage.length, currContentRange.location + markerLen)
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                return
            }
        }

        // Tables (GFM): if the user just finished typing a valid table block, convert it to a TextKit table.
        // This is intentionally conservative: it triggers only after a newline and only when we see a
        // header + delimiter + at least one body row.
        if prevKind == .paragraph {
            applyTableInputRulesIfNeeded(caret: caret, prevParagraph: prevPara, storage: storage, ns: ns)
        }
    }

    private func applyTableInputRulesIfNeeded(caret: Int, prevParagraph: NSRange, storage: NSTextStorage, ns: NSString) {
        // Collect contiguous plain paragraphs above the caret (ending at prevParagraph).
        // Stop at the first blank line or non-paragraph block kind.
        var paras: [NSRange] = []
        var p = prevParagraph
        var steps = 0
        while true {
            steps += 1
            if steps > 20 { break } // prevent runaway scanning

            let kindRaw = storage.attribute(.kernBlockKind, at: max(0, min(p.location, max(0, storage.length - 1))), effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind != .paragraph { break }

            let contentRange = paragraphContentRange(ns: ns, paraRange: p)
            let line = contentRange.length > 0 ? storage.attributedSubstring(from: contentRange).string : ""
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }

            paras.insert(p, at: 0)

            if p.location == 0 { break }
            let prevLoc = max(0, p.location - 1)
            let prevP = ns.paragraphRange(for: NSRange(location: prevLoc, length: 0))
            if prevP.location == p.location { break }
            p = prevP
        }

        guard paras.count >= 3 else { return }

        // Extract lines, aligned with paras (drop trailing newline).
        var lines: [String] = []
        lines.reserveCapacity(paras.count)
        for r in paras {
            let cr = paragraphContentRange(ns: ns, paraRange: r)
            let s = cr.length > 0 ? storage.attributedSubstring(from: cr).string : ""
            lines.append(s)
        }

        // Find the last delimiter row in this block.
        var delimiterIndex: Int?
        if lines.count >= 2 {
            for i in stride(from: lines.count - 1, through: 1, by: -1) {
                if isGfmTableDelimiterRow(lines[i]), looksLikeGfmTableRow(lines[i - 1]) {
                    delimiterIndex = i
                    break
                }
            }
        }

        guard let d = delimiterIndex else { return }
        let headerIndex = d - 1
        let firstBodyIndex = d + 1
        guard firstBodyIndex < lines.count else { return } // require at least one body row
        guard looksLikeGfmTableRow(lines[firstBodyIndex]) else { return }

        // Extend through contiguous body rows.
        var lastRowIndex = firstBodyIndex
        var j = firstBodyIndex
        while j < lines.count {
            if looksLikeGfmTableRow(lines[j]) {
                lastRowIndex = j
                j += 1
                continue
            }
            break
        }

        // Replace exactly the table lines (header..lastRowIndex).
        let startLoc = paras[headerIndex].location
        let endLoc = paras[lastRowIndex].location + paras[lastRowIndex].length
        guard endLoc >= startLoc else { return }
        let replaceRange = NSRange(location: startLoc, length: endLoc - startLoc)

        // Convert with the same importer used for file-open. This ensures table attrs match export logic.
        let markdown = storage.attributedSubstring(from: replaceRange).string
        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let imported = NativeMarkdownCodec.importMarkdown(markdown, options: opt)

        let kRaw = imported.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
        let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        guard k == .tableCell else { return }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }

        let delta = imported.length - replaceRange.length
        storage.replaceCharacters(in: replaceRange, with: imported)

        // Keep caret location stable relative to the replaced block (best-effort).
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
    }

    private func looksLikeGfmTableRow(_ line: String) -> Bool {
        // A very loose heuristic: must contain at least one pipe.
        // (We rely on a strict delimiter-row check to avoid false positives.)
        return line.contains("|")
    }

    private func isGfmTableDelimiterRow(_ line: String) -> Bool {
        // Example:
        // | :--- | :---: | ---: |
        // Left/Right pipes are optional in GFM.
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }

        // Must have at least 2 columns.
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return false }

        for p in parts {
            guard !p.isEmpty else { return false }
            // Match ^:?-{3,}:?$
            var t = p
            let hasLeadingColon = t.hasPrefix(":")
            let hasTrailingColon = t.hasSuffix(":")
            if hasLeadingColon { t.removeFirst() }
            if hasTrailingColon, !t.isEmpty { t.removeLast() }

            let dashes = t.filter { $0 == "-" }.count
            if dashes < 3 { return false }
            if t.contains(where: { $0 != "-" }) { return false }
        }
        return true
    }

    private func previousParagraphContent(storage: NSTextStorage, ns: NSString, paraRange: NSRange) -> String {
        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        if contentRange.length == 0 { return "" }

        var start = contentRange.location
        while start < contentRange.location + contentRange.length {
            let isMarker = (storage.attribute(.kernMarker, at: start, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            start += 1
        }
        let bodyRange = NSRange(location: start, length: max(0, contentRange.location + contentRange.length - start))
        return storage.attributedSubstring(from: bodyRange).string
    }

    private func removeMarkerPrefix(in paraRange: NSRange, storage: NSTextStorage, ns: NSString) -> Int {
        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length > 0 else { return 0 }

        var markerLen = 0
        while markerLen < contentRange.length {
            let idx = contentRange.location + markerLen
            let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            markerLen += 1
        }
        if markerLen > 0 {
            storage.deleteCharacters(in: NSRange(location: contentRange.location, length: markerLen))
        }
        return markerLen
    }

    private func paragraphContentRange(ns: NSString, paraRange: NSRange) -> NSRange {
        var len = paraRange.length
        if len > 0 {
            let last = paraRange.location + len - 1
            if last < ns.length, ns.character(at: last) == 10 { // '\n'
                len -= 1
            }
        }
        return NSRange(location: paraRange.location, length: max(0, len))
    }

    private func markerPrefixLength(in attributed: NSAttributedString) -> Int {
        var len = 0
        while len < attributed.length {
            let isMarker = (attributed.attribute(.kernMarker, at: len, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            len += 1
        }
        return len
    }

    private func setBaseTypingAttributes() {
        let baseFont = NSFont.systemFont(ofSize: 16)
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    // MARK: - Menu Actions

    @objc func toggleBold(_ sender: Any?) {
        toggleInlineAttribute(.kernStrong)
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggleInlineAttribute(.kernEmphasis)
    }

    @objc func toggleCode(_ sender: Any?) {
        toggleInlineAttribute(.kernInlineCode)
    }

    private func toggleInlineAttribute(_ key: NSAttributedString.Key) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        // Determine if we're turning on or off based on the first character.
        let existing = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Bool) ?? false
        let newValue = !existing

        storage.addAttribute(key, value: newValue, range: range)

        // Update fonts/background for our prototype attributes.
        let baseFont = NSFont.systemFont(ofSize: 16)
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            let strong = (attrs[.kernStrong] as? Bool) ?? false
            let emphasis = (attrs[.kernEmphasis] as? Bool) ?? false
            let code = (attrs[.kernInlineCode] as? Bool) ?? false

            var font = baseFont
            var background: NSColor? = nil

            if code {
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                background = NSColor(white: 0, alpha: 0.06)
            } else {
                if strong {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if emphasis {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
            }

            storage.addAttribute(.font, value: font, range: subrange)
            if let background {
                storage.addAttribute(.backgroundColor, value: background, range: subrange)
            } else {
                storage.removeAttribute(.backgroundColor, range: subrange)
            }
        }

        scheduleExport()
    }

    @objc func showFind(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(item)
    }

    // MARK: - Code Block Copy

    @objc private func copyActiveCodeBlock(_ sender: Any?) {
        guard let range = codeCopyCharacterRange else { return }
        let ns = textView.string as NSString
        guard range.location + range.length <= ns.length else { return }
        let code = ns.substring(with: range)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        updateCodeCopyButtonVisibilityAndPosition()
    }

    private func updateCodeCopyButtonVisibilityAndPosition() {
        guard isViewLoaded else { return }
        guard let storage = textView.textStorage else {
            codeCopyButton.isHidden = true
            codeCopyCharacterRange = nil
            return
        }

        let selection = textView.selectedRange()
        let caret = selection.location
        guard selection.length == 0, caret <= storage.length, storage.length > 0 else {
            codeCopyButton.isHidden = true
            codeCopyCharacterRange = nil
            return
        }

        let idx = min(max(0, caret), max(0, storage.length - 1))
        let kindRaw = storage.attribute(.kernBlockKind, at: idx, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        guard kind == .codeBlock else {
            codeCopyButton.isHidden = true
            codeCopyCharacterRange = nil
            return
        }

        // Expand to the contiguous code block range around the caret.
        var start = idx
        while start > 0 {
            let prev = start - 1
            let kRaw = storage.attribute(.kernBlockKind, at: prev, effectiveRange: nil) as? Int
            let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if k != .codeBlock { break }
            start = prev
        }
        var end = idx
        while end < storage.length - 1 {
            let next = end + 1
            let kRaw = storage.attribute(.kernBlockKind, at: next, effectiveRange: nil) as? Int
            let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if k != .codeBlock { break }
            end = next
        }
        let range = NSRange(location: start, length: max(0, end - start + 1))
        codeCopyCharacterRange = range

        // Position the button near the top-right of the visible portion of the code block.
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            codeCopyButton.isHidden = true
            return
        }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let visible = textView.visibleRect
        let size = codeCopyButton.intrinsicContentSize

        var x = min(rect.maxX, visible.maxX) - size.width - 12
        var y = min(rect.maxY, visible.maxY) - size.height - 8
        x = max(x, visible.minX + 12)
        y = max(y, visible.minY + 12)

        // Convert from textView coords to the container view coords.
        let originInContainer = view.convert(NSPoint(x: x, y: y), from: textView)
        codeCopyButton.frame = NSRect(origin: originInContainer, size: size)
        codeCopyButton.isHidden = false
    }

    @objc func showFindReplace(_ sender: Any?) {
        // AppKit's NSFindPanelAction does not have a dedicated "show replace panel" tag.
        // For the prototype, just open the standard Find panel.
        showFind(sender)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.setFindString.rawValue)
        textView.performFindPanelAction(item)
    }

    // MARK: - Toast

    private var toastView: NSView?

    func showReloadToast() {
        toastView?.removeFromSuperview()

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        container.layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: "File reloaded from disk")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let hPad: CGFloat = 12
        let vPad: CGFloat = 6
        container.frame = NSRect(
            x: 0, y: 0,
            width: label.frame.width + hPad * 2,
            height: label.frame.height + vPad * 2
        )
        label.frame.origin = NSPoint(x: hPad, y: vPad)
        container.addSubview(label)

        container.frame.origin = NSPoint(
            x: (view.bounds.width - container.frame.width) / 2,
            y: view.bounds.height - container.frame.height - 12
        )
        container.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]

        view.addSubview(container)
        toastView = container

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.dismissToast()
        }
    }

    private func dismissToast() {
        guard let toast = toastView else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            toast.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.toastView?.removeFromSuperview()
                self?.toastView = nil
            }
        })
    }
}

// MARK: - NSMenuItemValidation

extension NativeEditorViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleBold), #selector(toggleItalic), #selector(toggleCode):
            return textView.selectedRange().length > 0
        default:
            return true
        }
    }
}
