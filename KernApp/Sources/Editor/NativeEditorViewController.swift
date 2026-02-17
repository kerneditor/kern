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

    // Code block chrome (two independent overlays):
    // - caret chrome: shown when the caret is inside a code block
    // - hover chrome: shown when the mouse hovers a (different) code block
    private let caretCodeBlockChrome = CodeBlockChromeView(
        copyButtonAccessibilityIdentifier: "NativeEditor.CodeCopyButton",
        languageLabelAccessibilityIdentifier: "NativeEditor.CodeLanguageLabel"
    )
    private let hoverCodeBlockChrome = CodeBlockChromeView(
        copyButtonAccessibilityIdentifier: "NativeEditor.CodeCopyButton.Hover",
        languageLabelAccessibilityIdentifier: "NativeEditor.CodeLanguageLabel.Hover"
    )
    private var caretCodeCopyFeedbackWorkItem: DispatchWorkItem?
    private var hoverCodeCopyFeedbackWorkItem: DispatchWorkItem?
    private var hoveredCodeBlockRange: NSRange?
    private var caretCodeCopyCharacterRange: NSRange?
    private var hoverCodeCopyCharacterRange: NSRange?
    private var caretLastCodeBlockBackgroundRect: NSRect?
    private var hoverLastCodeBlockBackgroundRect: NSRect?
    private var isUpdatingCodeBlockChrome = false
    private var codeBlockChromeNeedsRefresh = false

    private struct AnchorJumpGuard {
        let anchor: String
        let linkCharIndex: Int
        var targetParagraphLocation: Int?
        var lastJumpedAt: Date
        var remainingRejumps: Int
        let expiresAt: Date
    }

    private var pendingAnchorJumpWorkItem: DispatchWorkItem?
    private var anchorJumpGuard: AnchorJumpGuard?

    /// If this editor is hosted by an `NSDocument`, the owning document's URL.
    /// Used to correctly handle in-document `#anchor` links that may arrive as `file:///path/to/doc.md#anchor`.
    var documentURL: URL?
    /// Test seam for external URL opening. When nil, uses `NSWorkspace.shared.open`.
    var openExternalURLHandler: ((URL) -> Bool)?

    // Find / Replace (native, testable; avoids depending on the system Find panel UI).
    private let findBarView = NSView()
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let findMatchLabel = NSTextField(labelWithString: "")
    private let findPrevButton = NSButton(title: "", target: nil, action: nil)
    private let findNextButton = NSButton(title: "", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let findCloseButton = NSButton(title: "", target: nil, action: nil)

    private var isFindReplaceMode = false
    private var findMatches: [NSRange] = []
    private var findCurrentIndex: Int = 0
    private var findAnchorLocation: Int = 0
    private var findUpdateWorkItem: DispatchWorkItem?

    private var isApplyingExternalUpdate = false
    private var isApplyingInputRules = false
    private var isApplyingAutoNewline = false
    private var exportWorkItem: DispatchWorkItem?
    /// Avoid full-document layout forcing on very large files; it can stall UI on open/edit.
    private let fullLayoutForceCharThreshold = 60_000
    private var largeDocumentLightLayoutWorkItem: DispatchWorkItem?
    /// Test seam: disables debounced background export work while keeping explicit flush/save behavior.
    /// This avoids runaway async work during exhaustive non-UI typing matrices.
    var disablesDebouncedExportsForTesting = false

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
        textView.allowsUndo = ProcessInfo.processInfo.environment["KERN_TEST_DISABLE_UNDO"] == "1" ? false : true
        textView.isRichText = true
        // Required for NSTextAttachment rendering (images, mermaid, block math, thematic breaks).
        // When false, TextKit shows fallback replacement glyphs instead of attachment cells.
        textView.importsGraphics = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.onHoverCodeBlockRangeChanged = { [weak self] range in
            guard let self else { return }
            self.hoveredCodeBlockRange = range
            self.updateCodeBlockChrome()
        }
        // Ensure the document view grows with content (and provides bottom whitespace so anchor jumps can
        // land headings near the top, even close to EOF).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let baseFont = NSFont.systemFont(ofSize: 16)
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        scrollView.documentView = textView
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        syncTextContainerSizeToScrollViewWidth()

        // Code-block chrome overlays (caret + hover).
        caretCodeBlockChrome.setAccessibilityIdentifier("NativeEditor.CodeBlockChrome.Caret")
        caretCodeBlockChrome.copyButton.target = self
        caretCodeBlockChrome.copyButton.action = #selector(copyCaretCodeBlock(_:))
        caretCodeBlockChrome.isHidden = true
        container.addSubview(caretCodeBlockChrome)

        hoverCodeBlockChrome.setAccessibilityIdentifier("NativeEditor.CodeBlockChrome.Hover")
        hoverCodeBlockChrome.copyButton.target = self
        hoverCodeBlockChrome.copyButton.action = #selector(copyHoveredCodeBlock(_:))
        hoverCodeBlockChrome.isHidden = true
        container.addSubview(hoverCodeBlockChrome)

        configureFindBar(container: container)

        // Track scroll to keep the code-block chrome positioned.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nativeEditorPreferencesDidChange(_:)),
            name: .nativeEditorPreferencesDidChange,
            object: nil
        )

        view = container
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .nativeEditorPreferencesDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncTextContainerSizeToScrollViewWidth()
        adjustDocumentViewHeightToContent(forceFullLayout: false)
        layoutFindBar()
        updateCodeBlockChrome()
    }

    private func syncTextContainerSizeToScrollViewWidth() {
        guard let tc = textView.textContainer else { return }
        let width = max(0, scrollView.contentView.bounds.width)
        // TextKit uses the text container size for layout; allow unlimited height and track width.
        tc.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        tc.widthTracksTextView = true
    }

    /// Make the scroll view feel like a modern editor by ensuring there's always "breathing room" below
    /// the last line. This enables table-of-contents navigation to land headings near the top even when
    /// they are close to end-of-file.
    private func adjustDocumentViewHeightToContent(forceFullLayout: Bool = false) {
        guard
            let lm = textView.layoutManager,
            let tc = textView.textContainer,
            let storage = textView.textStorage
        else { return }

        let canForceFullLayout = forceFullLayout && storage.length <= fullLayoutForceCharThreshold
        // Force layout through the end of the document. TextKit can be lazy about layout when the
        // container has "infinite" height; without this, `usedRect(for:)` can under-report and clamp
        // scrolling (breaking anchor jumps on long docs).
        if canForceFullLayout, storage.length > 0 {
            let lastChar = max(0, storage.length - 1)
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: lastChar, length: 1), actualCharacterRange: nil)
            lm.ensureLayout(forGlyphRange: glyphRange)
        } else if storage.length == 0 {
            lm.ensureLayout(for: tc)
        }

        let used = lm.usedRect(for: tc)
        let viewportH = max(0, scrollView.contentView.bounds.height)

        // Provide at least one viewport of extra scroll space at the bottom (common in editors like Notion).
        let bottomPad = viewportH
        let insets = textView.textContainerInset.height * 2
        // When we don't force full layout (large docs / per-keystroke edits), don't aggressively shrink
        // based on partially-laid-out usedRect values.
        let minimumBaseHeight = canForceFullLayout ? viewportH : max(viewportH, textView.frame.height)
        let desiredH = max(minimumBaseHeight, ceil(used.maxY + insets + bottomPad))

        if abs(textView.frame.height - desiredH) > 1 {
            var f = textView.frame
            f.size.height = desiredH
            textView.frame = f
        }
    }

    private func scheduleLargeDocumentLightLayoutIfNeeded(markdown: String) {
        guard markdown.utf16.count > fullLayoutForceCharThreshold else {
            largeDocumentLightLayoutWorkItem?.cancel()
            largeDocumentLightLayoutWorkItem = nil
            return
        }
        largeDocumentLightLayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.viewIfLoaded != nil else { return }
            self.adjustDocumentViewHeightToContent(forceFullLayout: false)
            self.updateCodeBlockChrome()
        }
        largeDocumentLightLayoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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

    private func applyPreferencesAndRerender() {
        guard viewIfLoaded != nil else { return }
        renderMarkdown(stringValue, preserveSelection: true)
        adjustDocumentViewHeightToContent()
        updateCodeBlockChrome()
        scheduleFindUpdate(resetIndex: false, anchorLocation: nil)
        scheduleExport()
    }

    @objc private func nativeEditorPreferencesDidChange(_ notification: Notification) {
        applyPreferencesAndRerender()
    }

    func attributedTextForTesting() -> NSAttributedString {
        textView.attributedString()
    }

    private func renderMarkdown(_ markdown: String, preserveSelection: Bool) {
        let selection = preserveSelection ? textView.selectedRange() : nil
        let scrollOrigin = preserveSelection ? scrollView.contentView.bounds.origin : nil

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let attr = NativeMarkdownCodec.importMarkdown(markdown, options: opt, baseURL: documentURL)
        textView.textStorage?.setAttributedString(attr)
        let forceFullLayout = markdown.utf16.count <= fullLayoutForceCharThreshold
        adjustDocumentViewHeightToContent(forceFullLayout: forceFullLayout)
        scheduleLargeDocumentLightLayoutIfNeeded(markdown: markdown)

        if let selection {
            let maxLocation = max(0, textView.string.count)
            let safeLoc = min(selection.location, maxLocation)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
        } else {
            // Deterministic initial view state for open/import/snapshot flows:
            // start at top of document with caret at location 0 (Notion/GitHub-like).
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            let top = NSPoint(x: 0, y: 0)
            scrollView.contentView.scroll(to: top)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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

        // Preserve visual attributes (color), but normalize checkbox font metrics so checked/unchecked
        // glyphs don't come from different fallback fonts.
        let existingFont = storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
        let existingColor = storage.attribute(.foregroundColor, at: characterIndex, effectiveRange: nil) as? NSColor

        // Determine the surrounding text font so we can compute an optical baseline offset that
        // aligns the checkbox with the line's x-height center (Notion/GitHub-like).
        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: characterIndex, length: 0))
        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)

        var textFontForAlignment: NSFont = NSFont.systemFont(ofSize: 16)
        if contentRange.length > 0 {
            var i = contentRange.location
            while i < contentRange.location + contentRange.length, i < storage.length {
                let isMarker = (storage.attribute(.kernMarker, at: i, effectiveRange: nil) as? Bool) ?? false
                if !isMarker, let f = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont {
                    textFontForAlignment = f
                    break
                }
                i += 1
            }
        }

        // Choose a point size that matches our import renderer:
        // - body/list tasks: checkbox slightly larger than text
        // - headings: checkbox matches heading size (import does this for heading checkboxes)
        let desiredPointSize: CGFloat
        if let existingFont {
            desiredPointSize = existingFont.pointSize
        } else if textFontForAlignment.pointSize > 16 {
            desiredPointSize = textFontForAlignment.pointSize
        } else {
            desiredPointSize = textFontForAlignment.pointSize + 4
        }

        let checkboxFont = CheckboxStyle.preferredFont(pointSize: desiredPointSize)
        let baselineOffset = CheckboxStyle.baselineOffset(textFont: textFontForAlignment, checkboxFont: checkboxFont)

        let newChar = newChecked ? "\u{2611}" : "\u{2610}" // ☑ / ☐
        storage.replaceCharacters(in: NSRange(location: characterIndex, length: 1), with: newChar)

        storage.addAttribute(.font, value: checkboxFont, range: NSRange(location: characterIndex, length: 1))
        storage.addAttribute(.baselineOffset, value: baselineOffset, range: NSRange(location: characterIndex, length: 1))
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
        adjustDocumentViewHeightToContent(forceFullLayout: false)
        updateCodeBlockChrome()
        scheduleFindUpdate(resetIndex: false, anchorLocation: nil)
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

        // Allow deletion/cut of selected ranges even when they include marker regions.
        // Without this, basic "select all + delete/cut" can fail whenever a task/list marker
        // is present in the document.
        if affectedCharRange.length > 0 {
            let replacement = replacementString ?? ""
            let isDeletionLikeEdit = replacement.isEmpty
            if isDeletionLikeEdit { return true }
        }

        // Disallow non-deletion edits that touch marker regions (bullet + checkbox prefix).
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
        updateCodeBlockChrome()
        maybeReapplyAnchorJumpIfNeeded()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let anchor = internalAnchor(from: link) {
            scheduleAnchorJump(anchor: anchor, linkCharIndex: charIndex)
            return true
        }
        guard let url = externalURL(from: link) else { return false }
        return openExternalURL(url)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            return handleBackspaceAtListStartIfNeeded()
        }
        return false
    }

    private func internalAnchor(from link: Any) -> String? {
        if let url = link as? URL {
            // Common forms:
            // - "#section" (pure fragment)
            // - "file:///path/to/doc.md#section" (fragment resolved against base URL)
            if let frag = url.fragment {
                if url.scheme == nil, url.path.isEmpty {
                    return frag.removingPercentEncoding ?? frag
                }
                if url.scheme == "file", isCurrentDocumentURL(url) {
                    return frag.removingPercentEncoding ?? frag
                }
            }
        }
        if let s = link as? String {
            if s.hasPrefix("#") {
                return String(s.dropFirst()).removingPercentEncoding ?? String(s.dropFirst())
            }
            if let url = URL(string: s), let frag = url.fragment, url.scheme == "file", isCurrentDocumentURL(url) {
                return frag.removingPercentEncoding ?? frag
            }
        }
        return nil
    }

    private func externalURL(from link: Any) -> URL? {
        let url: URL?
        if let u = link as? URL {
            url = u
        } else if let s = link as? String {
            url = URL(string: s)
        } else {
            url = nil
        }
        guard let url else { return nil }
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "mailto", "file":
            return url
        default:
            return nil
        }
    }

    private func openExternalURL(_ url: URL) -> Bool {
        if let openExternalURLHandler {
            return openExternalURLHandler(url)
        }
        return NSWorkspace.shared.open(url)
    }

    private func isCurrentDocumentURL(_ url: URL) -> Bool {
        guard url.scheme == "file" else { return false }
        guard let docURL = documentURL?.standardizedFileURL else { return false }

        // Ignore fragments when comparing file URLs.
        return URL(fileURLWithPath: url.path).standardizedFileURL == docURL
    }

    private func scheduleAnchorJump(anchor: String, linkCharIndex: Int) {
        pendingAnchorJumpWorkItem?.cancel()

        // Guard against NSTextView internal selection/scroll behaviors that can snap the viewport back
        // to the clicked link shortly after we programmatically scroll to the destination.
        anchorJumpGuard = AnchorJumpGuard(
            anchor: anchor,
            linkCharIndex: linkCharIndex,
            targetParagraphLocation: nil,
            lastJumpedAt: .distantPast,
            // Allow a few attempts over a longer window: NSTextView can apply deferred "make selection
            // visible" scroll adjustments well after the click event finishes (seen in TOC nav).
            remainingRejumps: 6,
            expiresAt: Date().addingTimeInterval(8.0)
        )

        // Perform the jump on the next run loop so it wins over NSTextView's default click/selection handling.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.jumpToAnchor(anchor) else { return }
            self.showJumpToast(anchor: anchor)
        }
        pendingAnchorJumpWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func maybeReapplyAnchorJumpIfNeeded() {
        guard var guardState = anchorJumpGuard else { return }

        let now = Date()
        if now >= guardState.expiresAt || guardState.remainingRejumps <= 0 {
            anchorJumpGuard = nil
            return
        }

        guard let storage = textView.textStorage,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              storage.length > 0 else { return }

        let ns = storage.string as NSString
        let visible = textView.visibleRect

        let sel = textView.selectedRange()
        let selLen = max(sel.length, 1) // treat a caret as a 1-char range for containment checks
        let containsLinkIndex = sel.location <= guardState.linkCharIndex && guardState.linkCharIndex < sel.location + selLen

        func paragraphRect(forCharIndex charIndex: Int) -> (para: NSRange, rect: NSRect)? {
            guard ns.length > 0 else { return nil }
            let safe = min(max(0, charIndex), ns.length - 1)
            let para = ns.paragraphRange(for: NSRange(location: safe, length: 0))
            let glyphRange = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return (para, rect)
        }

        func distanceFromTop(targetRect: NSRect, visibleRect: NSRect) -> CGFloat {
            if textView.isFlipped {
                return targetRect.minY - visibleRect.minY
            }
            return visibleRect.maxY - targetRect.maxY
        }

        var shouldRejump = containsLinkIndex

        // Handle a "scroll-only" snap-back where the viewport returns to the TOC, but the selection
        // remains at the destination heading. We only fight this during a short stability window and
        // only when the clicked link paragraph is actually visible again.
        if let targetLoc = guardState.targetParagraphLocation {
            let stabilityWindow: TimeInterval = 3.0
            let withinStabilityWindow = now.timeIntervalSince(guardState.lastJumpedAt) <= stabilityWindow
            if withinStabilityWindow {
                let safeSel = min(max(0, sel.location), max(0, ns.length - 1))
                let selPara = ns.paragraphRange(for: NSRange(location: safeSel, length: 0))
                if selPara.location == targetLoc, let target = paragraphRect(forCharIndex: targetLoc) {
                    let targetVisible = visible.intersects(target.rect)
                    let targetDistanceFromTop = distanceFromTop(targetRect: target.rect, visibleRect: visible)
                    let targetTooLow = targetVisible && targetDistanceFromTop > (visible.height * 0.35)

                    // Even if the target is technically visible, enforce "land near top" behavior.
                    // NSTextView can apply deferred minimal-scroll adjustments that leave the heading
                    // mid-viewport; this re-jump restores deterministic TOC navigation.
                    if !shouldRejump, targetTooLow {
                        shouldRejump = true
                    }

                    if !shouldRejump, let link = paragraphRect(forCharIndex: guardState.linkCharIndex) {
                        let linkVisible = visible.intersects(link.rect)
                        if !targetVisible, linkVisible {
                            shouldRejump = true
                        }
                    }
                }
            }
        }

        guard shouldRejump else { return }

        guardState.remainingRejumps -= 1
        anchorJumpGuard = guardState

        pendingAnchorJumpWorkItem?.cancel()
        let anchor = guardState.anchor
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            _ = self.jumpToAnchor(anchor)
        }
        pendingAnchorJumpWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func jumpToAnchor(_ slug: String) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let index = HeadingAnchorIndex.make(from: storage)
        guard let loc = index[slug] else { return false }

        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: loc, length: 0))

        if var guardState = anchorJumpGuard, guardState.anchor == slug {
            guardState.targetParagraphLocation = paraRange.location
            guardState.lastJumpedAt = Date()
            anchorJumpGuard = guardState
        }

        // Move the caret so the jump is visible (and testable).
        textView.setSelectedRange(NSRange(location: paraRange.location, length: 0))

        scrollParagraphNearTop(paraRange)

        // Re-apply once on the next runloop. NSTextView can perform deferred, minimal visibility
        // adjustments after link clicks and leave the target in mid-viewport.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.textView.selectedRange().location == paraRange.location else { return }
            self.scrollParagraphNearTop(paraRange)
        }
        return true
    }

    private func scrollParagraphNearTop(_ paraRange: NSRange) {
        // Scroll so the destination heading lands near the top of the viewport (web/GitHub-style).
        // `scrollRangeToVisible` is "minimal scroll" and can result in no scroll when the target is already
        // visible, which feels unintuitive for table-of-contents navigation.
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            // TextKit can be lazy about layout for far-down content. Ensure the document view has
            // correct height + layout before we compute a rect to scroll to.
            adjustDocumentViewHeightToContent()

            let glyphRange = lm.glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)
            lm.ensureLayout(forGlyphRange: glyphRange)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            let clip = scrollView.contentView
            let viewportH = clip.bounds.height
            let topOffset: CGFloat = 24

            var origin = clip.bounds.origin
            origin.x = 0
            if textView.isFlipped {
                origin.y = rect.minY - topOffset
            } else {
                origin.y = rect.maxY + topOffset - viewportH
            }

            // Clamp only the minimum; NSClipView will clamp the maximum based on the document view size.
            // This avoids subtle mismatches between text-layout height and view bounds that can prevent
            // anchor jumps from reaching the desired position.
            origin.y = max(0, origin.y)

            // Use the clip view for deterministic, non-minimal scrolling. `NSView.scroll(_:)` is
            // "make point visible" and may result in no movement when the target is already visible,
            // which is unintuitive for table-of-contents navigation.
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        } else {
            textView.scrollRangeToVisible(paraRange)
        }
    }

    // MARK: - Export

    private func scheduleExport() {
        if disablesDebouncedExportsForTesting {
            return
        }

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
        let options = NativeMarkdownCodec.Options.fromUserDefaults()

        // If the user already triggered bullet conversion ("- " -> "• "), allow typing a task marker
        // at the start of the bullet body to convert it into a task list item ("task bullet").
        // Example: type "- " -> bullet, then type "[ ] item" -> task.
        if kind == .bullet {
            var markerLen = 0
            while markerLen < contentRange.length {
                let idx = contentRange.location + markerLen
                let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
                if !isMarker { break }
                markerLen += 1
            }
            let bodyRange = NSRange(location: contentRange.location + markerLen, length: max(0, contentRange.length - markerLen))
            let body = bodyRange.length > 0 ? storage.attributedSubstring(from: bodyRange).string : ""

            if let shortcut = parseTaskShortcutPrefix(body) {
                isApplyingInputRules = true
                defer { isApplyingInputRules = false }

                let indent = (storage.attribute(.kernListIndent, at: contentRange.location, effectiveRange: nil) as? Int) ?? 0
                let box = shortcut.checked ? "x" : " "
                let mdLine = String(repeating: " ", count: max(0, indent)) + "- [\(box)] " + shortcut.text

                let imported = NativeMarkdownCodec.importMarkdown(mdLine, options: options)
                let delta = imported.length - contentRange.length
                storage.replaceCharacters(in: contentRange, with: imported)

                let newCaret = min(max(0, caret + delta), storage.length)
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                return
            }
        }

        // Ordered list: after `1. ` is converted, typing `[ ] text` / `[x] text` at the start of
        // the body should convert this row into an ordered task item.
        if kind == .ordered, options.orderedTasksEnabled {
            var markerLen = 0
            while markerLen < contentRange.length {
                let idx = contentRange.location + markerLen
                let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
                if !isMarker { break }
                markerLen += 1
            }
            let bodyRange = NSRange(location: contentRange.location + markerLen, length: max(0, contentRange.length - markerLen))
            let body = bodyRange.length > 0 ? storage.attributedSubstring(from: bodyRange).string : ""

            if let shortcut = parseTaskShortcutPrefix(body) {
                isApplyingInputRules = true
                defer { isApplyingInputRules = false }

                let indent = (storage.attribute(.kernListIndent, at: contentRange.location, effectiveRange: nil) as? Int) ?? 0
                let rawIndex = (storage.attribute(.kernOrderedIndex, at: contentRange.location, effectiveRange: nil) as? Int) ?? 1
                let index = max(1, rawIndex)
                let box = shortcut.checked ? "x" : " "
                let mdLine = String(repeating: " ", count: max(0, indent)) + "\(index). [\(box)] " + shortcut.text

                let imported = NativeMarkdownCodec.importMarkdown(mdLine, options: options)
                let delta = imported.length - contentRange.length
                storage.replaceCharacters(in: contentRange, with: imported)

                let newCaret = min(max(0, caret + delta), storage.length)
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                return
            }
        }

        // For already-semantic list/heading/code paragraphs, avoid re-importing the whole line on
        // every keystroke. Re-import here should only run for plain paragraph text that still
        // contains literal markdown syntax.
        guard kind == .paragraph else { return }

        guard shouldConvertTypedMarkdown(line) else { return }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }

        // If we're converting a heading marker, keep heading typing attrs so subsequent characters
        // (and export) retain the heading block kind even when conversion happens on an empty marker-only line.
        let headingLevel = typedHeadingLevel(line)

        // Reuse our importer to hide typed syntax and apply attributes deterministically.
        let imported = NativeMarkdownCodec.importMarkdown(line, options: options)
        let delta = imported.length - contentRange.length
        storage.replaceCharacters(in: contentRange, with: imported)

        // Keep the caret reasonably close (best-effort).
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))

        if let headingLevel {
            setHeadingTypingAttributes(level: headingLevel)
        }
    }

    private func handleBackspaceAtListStartIfNeeded() -> Bool {
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let ns = storage.string as NSString
        guard ns.length > 0 else { return false }
        let caret = min(max(0, selection.location), ns.length)
        let probe = min(max(0, caret), max(0, ns.length - 1))
        let paraRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard paraRange.location < storage.length else { return false }

        let kindRaw = storage.attribute(.kernBlockKind, at: paraRange.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        guard kind == .bullet || kind == .task || kind == .ordered else { return false }

        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length >= 0 else { return false }

        let markerLen = markerPrefixLength(in: storage, contentRange: contentRange)
        guard markerLen > 0 else { return false }

        let contentStart = contentRange.location + markerLen
        guard caret == contentStart else { return false }

        let bodyRange = NSRange(
            location: contentStart,
            length: max(0, (contentRange.location + contentRange.length) - contentStart)
        )

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let replacement: NSAttributedString
        if bodyRange.length > 0 {
            let body = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: bodyRange))
            clearBlockSemanticsKeepingInline(in: body)
            let bodyMarkdown = NativeMarkdownCodec.exportMarkdown(body, options: opt)
            replacement = NativeMarkdownCodec.importMarkdown(bodyMarkdown, options: opt)
        } else {
            replacement = NSAttributedString()
        }

        storage.replaceCharacters(in: contentRange, with: replacement)
        textView.setSelectedRange(NSRange(location: min(contentRange.location, storage.length), length: 0))
        textView.didChangeText()
        return true
    }

    private func parseTaskShortcutPrefix(_ body: String) -> (checked: Bool, text: String)? {
        if body.hasPrefix("[] ") {
            return (false, String(body.dropFirst(3)))
        }
        if body.hasPrefix("[ ] ") {
            return (false, String(body.dropFirst(4)))
        }
        if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
            return (true, String(body.dropFirst(4)))
        }
        return nil
    }

    private func isConvertibleBlockquoteLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return false }

        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            guard trimmed[idx] == ">" else { break }
            idx = trimmed.index(after: idx)
            while idx < trimmed.endIndex, trimmed[idx] == " " {
                idx = trimmed.index(after: idx)
            }
        }

        guard idx <= trimmed.endIndex else { return false }
        let rest = String(trimmed[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return !rest.isEmpty
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

        // Blockquote
        if isConvertibleBlockquoteLine(line) { return true }

        // Ordered list: "1. "
        if isOrderedListPrefix(line) { return true }

        // Bullet list: "- "
        if line == "- " { return true }

        return false
    }

    private func typedHeadingLevel(_ line: String) -> Int? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let i = line.index(line.startIndex, offsetBy: level)
        guard i < line.endIndex, line[i] == " " else { return nil }
        return level
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
        let prevAttrLocation = max(0, min(prevPara.location, max(0, storage.length - 1)))
        let prevQuoteDepth = (storage.attribute(.kernQuoteDepth, at: prevAttrLocation, effectiveRange: nil) as? Int) ?? 0

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

        // Blockquotes: continue quote depth on Enter, exit on second Enter from an empty quoted line.
        if prevQuoteDepth > 0, prevKind == .paragraph {
            if prevContentIsEmpty {
                isApplyingAutoNewline = true
                defer { isApplyingAutoNewline = false }
                clearQuoteAttributes(in: prevPara, storage: storage)
                setBaseTypingAttributes()
                return
            }

            if currContentRange.length == 0 {
                isApplyingAutoNewline = true
                defer { isApplyingAutoNewline = false }
                setQuoteTypingAttributes(depth: prevQuoteDepth)
                return
            }
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

                let indent = max(
                    0,
                    (storage.attribute(.kernListIndent, at: prevPara.location, effectiveRange: nil) as? Int) ?? 0
                )
                let indentPrefix = String(repeating: " ", count: indent)
                let markerLine: String
                switch prevKind {
                case .bullet:
                    markerLine = indentPrefix + "- "
                case .task:
                    let styleRaw = storage.attribute(.kernTaskStyle, at: prevPara.location, effectiveRange: nil) as? Int
                    let style = KernTaskStyle(rawValue: styleRaw ?? KernTaskStyle.bulleted.rawValue) ?? .bulleted
                    markerLine = indentPrefix + (style == .standalone ? "[] " : "- [ ] ")
                case .ordered:
                    let prevN = (storage.attribute(.kernOrderedIndex, at: prevPara.location, effectiveRange: nil) as? Int) ?? 1
                    let orderedIsTask = (storage.attribute(.kernOrderedIsTask, at: prevPara.location, effectiveRange: nil) as? Bool) ?? false
                    markerLine = indentPrefix + (orderedIsTask ? "\(max(1, prevN + 1)). [ ] " : "\(max(1, prevN + 1)). ")
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

    private func markerPrefixLength(in storage: NSTextStorage, contentRange: NSRange) -> Int {
        guard contentRange.length > 0 else { return 0 }
        var len = 0
        while len < contentRange.length {
            let idx = contentRange.location + len
            let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            len += 1
        }
        return len
    }

    private func clearBlockSemanticsKeepingInline(in attributed: NSMutableAttributedString) {
        guard attributed.length > 0 else { return }
        let full = NSRange(location: 0, length: attributed.length)

        let blockKeys: [NSAttributedString.Key] = [
            .kernBlockKind,
            .kernHeadingLevel,
            .kernListIndent,
            .kernListDepth,
            .kernTaskStyle,
            .kernOrderedIndex,
            .kernOrderedIsTask,
            .kernMarker,
            .kernCheckbox,
            .kernCheckboxChecked,
            .kernCodeLanguage,
            .kernCodeBlockID,
            .kernQuoteDepth,
        ]
        for key in blockKeys {
            attributed.removeAttribute(key, range: full)
        }

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0
        attributed.addAttribute(.paragraphStyle, value: style, range: full)
    }

    private func setBaseTypingAttributes() {
        let baseFont = NSFont.systemFont(ofSize: 16)
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    private func setQuoteTypingAttributes(depth: Int) {
        let baseFont = NSFont.systemFont(ofSize: 16)
        let safeDepth = max(1, depth)
        let style = NSMutableParagraphStyle()
        let quoteIndent: CGFloat = CGFloat(safeDepth) * 16
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0

        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
            .kernBlockKind: KernBlockKind.paragraph.rawValue,
            .kernQuoteDepth: safeDepth,
        ]
    }

    private func clearQuoteAttributes(in paraRange: NSRange, storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        guard paraRange.location < storage.length else { return }
        let safeLen = min(paraRange.length, storage.length - paraRange.location)
        guard safeLen > 0 else { return }
        let safeRange = NSRange(location: paraRange.location, length: safeLen)

        storage.removeAttribute(.kernQuoteDepth, range: safeRange)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0
        storage.addAttribute(.paragraphStyle, value: style, range: safeRange)
        storage.addAttribute(.kernBlockKind, value: KernBlockKind.paragraph.rawValue, range: safeRange)
    }

    private func setHeadingTypingAttributes(level: Int) {
        let lvl = max(1, min(6, level))
        let size: CGFloat
        switch lvl {
        case 1: size = 28
        case 2: size = 22
        case 3: size = 18
        default: size = 16
        }

        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = lvl == 1 ? 14 : 10
        style.paragraphSpacing = 6

        // Include semantic attrs so export sees this paragraph as a heading.
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
            .kernBlockKind: KernBlockKind.heading.rawValue,
            .kernHeadingLevel: lvl,
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

    // MARK: - Find / Replace

    private func configureFindBar(container: NSView) {
        findBarView.wantsLayer = true
        findBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        findBarView.layer?.cornerRadius = 10
        findBarView.layer?.borderWidth = 1
        findBarView.layer?.borderColor = NSColor.separatorColor.cgColor
        findBarView.isHidden = true
        findBarView.setAccessibilityIdentifier("NativeEditor.FindBar")

        findField.setAccessibilityIdentifier("NativeEditor.FindField")
        findField.placeholderString = "Find"
        findField.font = NSFont.systemFont(ofSize: 13)
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findFieldDidChange(_:))

        replaceField.setAccessibilityIdentifier("NativeEditor.ReplaceField")
        replaceField.placeholderString = "Replace"
        replaceField.font = NSFont.systemFont(ofSize: 13)
        replaceField.bezelStyle = .roundedBezel
        replaceField.isHidden = true

        findMatchLabel.setAccessibilityIdentifier("NativeEditor.FindMatchLabel")
        findMatchLabel.font = .systemFont(ofSize: 12, weight: .medium)
        findMatchLabel.textColor = .secondaryLabelColor
        findMatchLabel.alignment = .right
        findMatchLabel.stringValue = ""

        func configureIconButton(_ button: NSButton, symbol: String, id: String, action: Selector, toolTip: String) {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            button.toolTip = toolTip
        }

        configureIconButton(findPrevButton, symbol: "chevron.up", id: "NativeEditor.FindPrevButton", action: #selector(findPrevious(_:)), toolTip: "Previous match")
        configureIconButton(findNextButton, symbol: "chevron.down", id: "NativeEditor.FindNextButton", action: #selector(findNext(_:)), toolTip: "Next match")
        configureIconButton(findCloseButton, symbol: "xmark", id: "NativeEditor.FindCloseButton", action: #selector(closeFindBar(_:)), toolTip: "Close find")

        replaceButton.target = self
        replaceButton.action = #selector(replaceCurrent(_:))
        replaceButton.setAccessibilityIdentifier("NativeEditor.ReplaceButton")
        replaceButton.bezelStyle = .rounded
        replaceButton.controlSize = .small
        replaceButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        replaceButton.isHidden = true

        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll(_:))
        replaceAllButton.setAccessibilityIdentifier("NativeEditor.ReplaceAllButton")
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.controlSize = .small
        replaceAllButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        replaceAllButton.isHidden = true

        findBarView.addSubview(findField)
        findBarView.addSubview(replaceField)
        findBarView.addSubview(findMatchLabel)
        findBarView.addSubview(findPrevButton)
        findBarView.addSubview(findNextButton)
        findBarView.addSubview(replaceButton)
        findBarView.addSubview(replaceAllButton)
        findBarView.addSubview(findCloseButton)

        container.addSubview(findBarView)
        layoutFindBar()
    }

    private func layoutFindBar() {
        guard isViewLoaded else { return }

        let barHeight: CGFloat = isFindReplaceMode ? 44 : 38
        let margin: CGFloat = 12
        // Keep the bar compact and anchored to the top-right so it doesn't blanket top-of-document content.
        let minWidth: CGFloat = isFindReplaceMode ? 380 : 320
        let maxWidth: CGFloat = isFindReplaceMode ? 560 : 420
        let availableWidth = max(minWidth, view.bounds.width - margin * 2)
        let width = min(maxWidth, availableWidth)
        let x = max(margin, view.bounds.width - width - margin)
        let y = view.bounds.height - barHeight - margin

        findBarView.frame = NSRect(x: x, y: y, width: width, height: barHeight)
        findBarView.autoresizingMask = [.minXMargin, .minYMargin]

        let pad: CGFloat = 10
        let spacing: CGFloat = 6
        let buttonW: CGFloat = 22
        let labelW: CGFloat = 72

        func centerY(_ h: CGFloat) -> CGFloat { (barHeight - h) / 2 }

        var right = width - pad

        // Close
        findCloseButton.frame = NSRect(x: right - buttonW, y: centerY(buttonW), width: buttonW, height: buttonW)
        right -= buttonW + spacing

        // Next / Prev
        findNextButton.frame = NSRect(x: right - buttonW, y: centerY(buttonW), width: buttonW, height: buttonW)
        right -= buttonW + spacing
        findPrevButton.frame = NSRect(x: right - buttonW, y: centerY(buttonW), width: buttonW, height: buttonW)
        right -= buttonW + spacing

        // Replace buttons (optional)
        replaceButton.isHidden = !isFindReplaceMode
        replaceAllButton.isHidden = !isFindReplaceMode
        replaceField.isHidden = !isFindReplaceMode

        if isFindReplaceMode {
            let allW: CGFloat = 44
            let repW: CGFloat = 74
            replaceAllButton.frame = NSRect(x: right - allW, y: centerY(22), width: allW, height: 22)
            right -= allW + spacing
            replaceButton.frame = NSRect(x: right - repW, y: centerY(22), width: repW, height: 22)
            right -= repW + spacing
        }

        // Match label
        findMatchLabel.frame = NSRect(x: right - labelW, y: centerY(18), width: labelW, height: 18)
        right -= labelW + spacing

        let fieldH: CGFloat = 24
        let fieldsWidth = max(160, right - pad)

        if isFindReplaceMode {
            let fieldW = max(120, floor((fieldsWidth - spacing) / 2))
            findField.frame = NSRect(x: pad, y: centerY(fieldH), width: fieldW, height: fieldH)
            replaceField.frame = NSRect(x: pad + fieldW + spacing, y: centerY(fieldH), width: fieldsWidth - fieldW - spacing, height: fieldH)
        } else {
            findField.frame = NSRect(x: pad, y: centerY(fieldH), width: fieldsWidth, height: fieldH)
            replaceField.frame = .zero
        }
    }

    @objc func showFind(_ sender: Any?) {
        presentFindBar(replaceMode: false)
    }

    @objc func showFindReplace(_ sender: Any?) {
        presentFindBar(replaceMode: true)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        presentFindBar(replaceMode: isFindReplaceMode)
        setFindQueryFromSelection()
        findAnchorLocation = textView.selectedRange().location
        updateFindMatches(resetIndex: true, anchorLocation: findAnchorLocation)
    }

    @objc func findNext(_ sender: Any?) {
        if findBarView.isHidden { presentFindBar(replaceMode: false) }
        updateFindMatches(resetIndex: false, anchorLocation: nil)
        guard !findMatches.isEmpty else { return }

        let selection = textView.selectedRange()
        let anchor = selection.location + selection.length
        let idx = findMatches.firstIndex(where: { $0.location >= anchor }) ?? 0
        selectFindMatch(at: idx)
    }

    @objc func findPrevious(_ sender: Any?) {
        if findBarView.isHidden { presentFindBar(replaceMode: false) }
        updateFindMatches(resetIndex: false, anchorLocation: nil)
        guard !findMatches.isEmpty else { return }

        let anchor = textView.selectedRange().location
        let idx = findMatches.lastIndex(where: { $0.location < anchor }) ?? (findMatches.count - 1)
        selectFindMatch(at: idx)
    }

    @objc private func findFieldDidChange(_ sender: Any?) {
        findAnchorLocation = textView.selectedRange().location
        scheduleFindUpdate(resetIndex: true, anchorLocation: findAnchorLocation)
    }

    @objc private func closeFindBar(_ sender: Any?) {
        hideFindBar()
    }

    @objc private func replaceCurrent(_ sender: Any?) {
        guard isFindReplaceMode else { return }
        guard let storage = textView.textStorage else { return }

        updateFindMatches(resetIndex: false, anchorLocation: nil)
        guard !findMatches.isEmpty else { return }

        let match = findMatches[findCurrentIndex]
        let replacement = replaceField.stringValue

        NativeFindEngine.replace(in: storage, range: match, replacement: replacement)
        scheduleExport()

        // Move past the replaced span so we don't get stuck re-matching the replacement text.
        let anchor = match.location + (replacement as NSString).length
        findAnchorLocation = anchor
        updateFindMatches(resetIndex: true, anchorLocation: anchor)
    }

    @objc private func replaceAll(_ sender: Any?) {
        guard isFindReplaceMode else { return }
        guard let storage = textView.textStorage else { return }

        let query = findField.stringValue
        guard !query.isEmpty else { return }

        let matches = NativeFindEngine.allMatches(in: textView.string, query: query)
        guard !matches.isEmpty else {
            updateFindMatches(resetIndex: true, anchorLocation: nil)
            return
        }

        let replacement = replaceField.stringValue
        for r in matches.reversed() {
            NativeFindEngine.replace(in: storage, range: r, replacement: replacement)
        }
        scheduleExport()

        findAnchorLocation = 0
        updateFindMatches(resetIndex: true, anchorLocation: 0)
    }

    private func presentFindBar(replaceMode: Bool) {
        loadViewIfNeeded()

        isFindReplaceMode = replaceMode
        findBarView.isHidden = false
        layoutFindBar()

        // Prefer selection as initial query (macOS standard behavior).
        setFindQueryFromSelection(allowEmpty: true)

        findAnchorLocation = textView.selectedRange().location
        updateFindMatches(resetIndex: true, anchorLocation: findAnchorLocation)

        view.window?.makeFirstResponder(findField)
    }

    private func hideFindBar() {
        findBarView.isHidden = true
        findMatchLabel.stringValue = ""
        view.window?.makeFirstResponder(textView)
    }

    private func scheduleFindUpdate(resetIndex: Bool, anchorLocation: Int?) {
        guard !findBarView.isHidden else { return }

        findUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateFindMatches(resetIndex: resetIndex, anchorLocation: anchorLocation)
        }
        findUpdateWorkItem = workItem

        // Keep typing responsive in-app while making unit/snapshot runs deterministic and fast.
        if isRunningUnderXCTest {
            workItem.perform()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func updateFindMatches(resetIndex: Bool, anchorLocation: Int?) {
        guard !findBarView.isHidden else { return }

        let query = findField.stringValue
        if query.isEmpty {
            findMatches = []
            findCurrentIndex = 0
            updateFindBarUI()
            return
        }

        findMatches = NativeFindEngine.allMatches(in: textView.string, query: query)

        if findMatches.isEmpty {
            findCurrentIndex = 0
            updateFindBarUI()
            return
        }

        if resetIndex {
            let anchor = anchorLocation ?? findAnchorLocation
            if let idx = findMatches.firstIndex(where: { $0.location >= anchor }) {
                findCurrentIndex = idx
            } else {
                findCurrentIndex = 0
            }
        } else {
            findCurrentIndex = min(findCurrentIndex, findMatches.count - 1)
        }

        selectFindMatch(at: findCurrentIndex)
    }

    private func selectFindMatch(at index: Int) {
        guard index >= 0, index < findMatches.count else {
            updateFindBarUI()
            return
        }

        findCurrentIndex = index
        let r = findMatches[index]
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        findAnchorLocation = r.location + r.length
        updateFindBarUI()
    }

    private func updateFindBarUI() {
        let query = findField.stringValue
        if query.isEmpty {
            findMatchLabel.stringValue = ""
            findPrevButton.isEnabled = false
            findNextButton.isEnabled = false
            replaceButton.isEnabled = false
            replaceAllButton.isEnabled = false
            return
        }

        if findMatches.isEmpty {
            findMatchLabel.stringValue = "No matches"
            findPrevButton.isEnabled = false
            findNextButton.isEnabled = false
            replaceButton.isEnabled = false
            replaceAllButton.isEnabled = false
            return
        }

        findMatchLabel.stringValue = "\(findCurrentIndex + 1)/\(findMatches.count)"
        findPrevButton.isEnabled = true
        findNextButton.isEnabled = true
        replaceButton.isEnabled = isFindReplaceMode
        replaceAllButton.isEnabled = isFindReplaceMode
    }

    private func setFindQueryFromSelection(allowEmpty: Bool = false) {
        let range = textView.selectedRange()
        guard range.length > 0 else {
            if allowEmpty { return }
            return
        }
        let ns = textView.string as NSString
        guard range.location + range.length <= ns.length else { return }
        findField.stringValue = ns.substring(with: range)
    }

    // MARK: - Code Block Chrome / Copy

    @objc private func copyCaretCodeBlock(_ sender: Any?) {
        copyCodeBlock(range: caretCodeCopyCharacterRange, chrome: caretCodeBlockChrome, feedbackWorkItem: &caretCodeCopyFeedbackWorkItem)
    }

    @objc private func copyHoveredCodeBlock(_ sender: Any?) {
        copyCodeBlock(range: hoverCodeCopyCharacterRange, chrome: hoverCodeBlockChrome, feedbackWorkItem: &hoverCodeCopyFeedbackWorkItem)
    }

    private func copyCodeBlock(range: NSRange?, chrome: CodeBlockChromeView, feedbackWorkItem: inout DispatchWorkItem?) {
        let resolvedRange: NSRange? = {
            if let range { return range }
            guard let storage = textView.textStorage else { return nil }
            if let caret = caretCodeBlockRange(in: storage, selection: textView.selectedRange()) {
                return caret
            }
            return validatedHoverCodeBlockRange(in: storage)
        }()
        guard let range = resolvedRange else { return }
        let ns = textView.string as NSString
        guard range.location + range.length <= ns.length else { return }
        let code = ns.substring(with: range)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        chrome.copyButton.title = "Copied"
        updateCodeBlockChrome()

        feedbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            chrome.copyButton.title = "Copy"
            self.updateCodeBlockChrome()
        }
        feedbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        updateCodeBlockChrome()
        maybeReapplyAnchorJumpIfNeeded()
    }

    private func updateCodeBlockChrome() {
        guard isViewLoaded else { return }
        if isUpdatingCodeBlockChrome {
            codeBlockChromeNeedsRefresh = true
            return
        }
        isUpdatingCodeBlockChrome = true
        defer {
            isUpdatingCodeBlockChrome = false
            if codeBlockChromeNeedsRefresh {
                codeBlockChromeNeedsRefresh = false
                DispatchQueue.main.async { [weak self] in
                    self?.updateCodeBlockChrome()
                }
            }
        }

        guard let storage = textView.textStorage else {
            caretCodeBlockChrome.isHidden = true
            hoverCodeBlockChrome.isHidden = true
            caretCodeCopyCharacterRange = nil
            hoverCodeCopyCharacterRange = nil
            return
        }

        let selection = textView.selectedRange()
        let hoverRange = validatedHoverCodeBlockRange(in: storage)
        let caretRange = caretCodeBlockRange(in: storage, selection: selection)

        // If hover and caret are the same code block, show only the caret chrome.
        let effectiveHoverRange: NSRange? = rangesEqual(hoverRange, caretRange) ? nil : hoverRange

        updateCodeBlockChromeOverlay(
            chrome: caretCodeBlockChrome,
            for: caretRange,
            storage: storage,
            copyRange: &caretCodeCopyCharacterRange,
            lastBackgroundRect: &caretLastCodeBlockBackgroundRect
        )

        updateCodeBlockChromeOverlay(
            chrome: hoverCodeBlockChrome,
            for: effectiveHoverRange,
            storage: storage,
            copyRange: &hoverCodeCopyCharacterRange,
            lastBackgroundRect: &hoverLastCodeBlockBackgroundRect
        )
    }

    private func validatedHoverCodeBlockRange(in storage: NSTextStorage) -> NSRange? {
        guard let hover = hoveredCodeBlockRange else { return nil }

        // Validate stale hover range after edits.
        if hover.location < storage.length, hover.length > 0, hover.location + hover.length <= storage.length {
            let kindRaw = storage.attribute(.kernBlockKind, at: hover.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .codeBlock {
                return hover
            }
        } else {
            hoveredCodeBlockRange = nil
        }
        return nil
    }

    private func caretCodeBlockRange(in storage: NSTextStorage, selection: NSRange) -> NSRange? {
        guard selection.length == 0 else { return nil }
        let caret = selection.location
        guard caret <= storage.length, storage.length > 0 else { return nil }

        let ns = storage.string as NSString

        // Use a probe location that's always within bounds. When the caret is at EOF, treat it as
        // pointing at the last character so we can still resolve paragraph/block semantics.
        let probe = min(max(0, caret), max(0, storage.length - 1))
        let caretPara = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard caretPara.location < storage.length else { return nil }

        let kindRaw = storage.attribute(.kernBlockKind, at: caretPara.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        guard kind == .codeBlock else { return nil }
        let caretQuoteDepth = (storage.attribute(.kernQuoteDepth, at: caretPara.location, effectiveRange: nil) as? Int) ?? 0
        let caretCodeBlockID = storage.attribute(.kernCodeBlockID, at: caretPara.location, effectiveRange: nil) as? Int

        // Expand to the contiguous code block range around the caret (paragraph-based so it survives
        // partial attribute loss on newline insertion).
        var startLoc = caretPara.location
        while startLoc > 0 {
            let prevProbe = max(0, startLoc - 1)
            let prevPara = ns.paragraphRange(for: NSRange(location: prevProbe, length: 0))
            guard prevPara.length > 0 else { break }
            let prevKindRaw = storage.attribute(.kernBlockKind, at: prevPara.location, effectiveRange: nil) as? Int
            let prevKind = KernBlockKind(rawValue: prevKindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if prevKind != .codeBlock { break }

            let prevQuoteDepth = (storage.attribute(.kernQuoteDepth, at: prevPara.location, effectiveRange: nil) as? Int) ?? 0
            if prevQuoteDepth != caretQuoteDepth { break }

            if let caretCodeBlockID {
                let prevID = storage.attribute(.kernCodeBlockID, at: prevPara.location, effectiveRange: nil) as? Int
                if prevID != caretCodeBlockID { break }
            } else if (storage.attribute(.kernCodeBlockID, at: prevPara.location, effectiveRange: nil) as? Int) != nil {
                break
            }
            startLoc = prevPara.location
        }

        var endLoc = caretPara.location + caretPara.length
        while endLoc < ns.length {
            let nextPara = ns.paragraphRange(for: NSRange(location: endLoc, length: 0))
            guard nextPara.length > 0 else { break }
            guard nextPara.location < storage.length else { break }
            let nextKindRaw = storage.attribute(.kernBlockKind, at: nextPara.location, effectiveRange: nil) as? Int
            let nextKind = KernBlockKind(rawValue: nextKindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if nextKind != .codeBlock { break }

            let nextQuoteDepth = (storage.attribute(.kernQuoteDepth, at: nextPara.location, effectiveRange: nil) as? Int) ?? 0
            if nextQuoteDepth != caretQuoteDepth { break }

            if let caretCodeBlockID {
                let nextID = storage.attribute(.kernCodeBlockID, at: nextPara.location, effectiveRange: nil) as? Int
                if nextID != caretCodeBlockID { break }
            } else if (storage.attribute(.kernCodeBlockID, at: nextPara.location, effectiveRange: nil) as? Int) != nil {
                break
            }
            endLoc = nextPara.location + nextPara.length
        }

        return NSRange(location: startLoc, length: max(0, endLoc - startLoc))
    }

    private func updateCodeBlockChromeOverlay(
        chrome: CodeBlockChromeView,
        for range: NSRange?,
        storage: NSTextStorage,
        copyRange: inout NSRange?,
        lastBackgroundRect: inout NSRect?
    ) {
        guard let range, range.length > 0 else {
            chrome.isHidden = true
            copyRange = nil
            return
        }

        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            chrome.isHidden = true
            copyRange = nil
            return
        }

        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var glyphRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        glyphRect.origin.x += textView.textContainerOrigin.x
        glyphRect.origin.y += textView.textContainerOrigin.y

        var lineSpanRect: NSRect?
        if glyphRange.length > 0 {
            var effective = NSRange(location: 0, length: 0)
            var lf = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
            lf.origin.x += textView.textContainerOrigin.x
            lf.origin.y += textView.textContainerOrigin.y

            // Stretch the background to the full available line width, but preserve the code block's
            // left indent (quotes/lists) by starting at the glyph bounding rect's minX.
            let left = glyphRect.minX
            let right = lf.maxX
            lineSpanRect = NSRect(x: left, y: lf.minY, width: max(0, right - left), height: lf.height)
        }

        let bgRect = CodeBlockChromeGeometry.backgroundRect(
            forGlyphBoundingRect: glyphRect,
            lineFragmentRect: lineSpanRect,
            isFlipped: textView.isFlipped
        )
        let visible = textView.visibleRect

        // Avoid floating chrome when the code block is off-screen.
        guard bgRect.intersects(visible) else {
            chrome.isHidden = true
            copyRange = nil
            return
        }

        // Ensure the rounded background is actually painted where the chrome sits (TextKit can invalidate
        // only glyph regions; our background extends above them).
        if let lastBackgroundRect {
            textView.setNeedsDisplay(lastBackgroundRect.union(bgRect))
        } else {
            textView.setNeedsDisplay(bgRect)
        }
        lastBackgroundRect = bgRect

        // Extract language (first non-empty in range).
        var lang: String?
        storage.enumerateAttribute(.kernCodeLanguage, in: range, options: []) { value, _, stop in
            guard let s = value as? String else { return }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lang = trimmed
            stop.pointee = true
        }
        // Preserve the authored token text to keep language labels compact and avoid unnecessary truncation.
        chrome.setLanguage(lang)

        // Position the chrome in the top-right of the code-block background.
        let paddingX: CGFloat = 10
        let paddingY: CGFloat = 4

        // Never truncate language names in the pill. If space is tight, the chrome can overflow the
        // code block's visual bounds, but the token should remain fully readable.
        chrome.maxLanguageWidth = nil

        let chromeSize = chrome.preferredSize()
        // Compute in the container coordinate space to avoid flipped-origin confusion.
        let bgRectInContainer = view.convert(bgRect, from: textView)
        let x = bgRectInContainer.maxX - paddingX - chromeSize.width
        let y = bgRectInContainer.maxY - paddingY - chromeSize.height

        // Clamp to keep chrome visible even if the code block background is unusually narrow.
        let clampedX = max(0, min(x, view.bounds.width - chromeSize.width))
        let clampedY = max(0, min(y, view.bounds.height - chromeSize.height))
        chrome.frame = NSRect(x: clampedX, y: clampedY, width: chromeSize.width, height: chromeSize.height)
        chrome.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        chrome.isHidden = false

        copyRange = range
    }

    private func rangesEqual(_ lhs: NSRange?, _ rhs: NSRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.location == r.location && l.length == r.length
        default:
            return false
        }
    }

    // MARK: - Toast

    private var toastView: NSView?

    func showReloadToast() {
        showToast(
            message: "File reloaded from disk",
            labelIdentifier: "NativeEditor.ReloadToast",
            containerIdentifier: "NativeEditor.ReloadToast.Container"
        )
    }

    private func showJumpToast(anchor: String) {
        showToast(
            message: "Jumped to #\(anchor)",
            labelIdentifier: "NativeEditor.JumpToast",
            containerIdentifier: "NativeEditor.JumpToast.Container"
        )
    }

    private func showToast(message: String, labelIdentifier: String, containerIdentifier: String) {
        toastView?.removeFromSuperview()

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        container.layer?.cornerRadius = 8
        container.setAccessibilityIdentifier(containerIdentifier)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.setAccessibilityIdentifier(labelIdentifier)
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

        // Keep the toast visible long enough for humans, but allow UI tests to shorten it.
        let duration: TimeInterval = {
            let env = ProcessInfo.processInfo.environment
            if let raw = env["KERN_TEST_TOAST_DURATION_MS"], let ms = Double(raw) {
                return max(0.05, ms / 1000.0)
            }
            return 3.0
        }()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
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

private var isRunningUnderXCTest: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
