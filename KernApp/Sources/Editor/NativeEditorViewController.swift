import AppKit

private actor StagedPromotionComputeWorker {
    struct ComputedContext {
        let contextStartUTF16: Int
        let contextOldMarkdown: String
        let contextNewMarkdown: String
    }

    func computeContext(
        markdown: String,
        contextStartUTF16: Int,
        oldEndUTF16: Int,
        newEndUTF16: Int
    ) -> ComputedContext {
        let markdownUTF16Count = markdown.utf16.count
        let clampedStart = min(max(0, contextStartUTF16), markdownUTF16Count)
        let clampedOldEnd = min(max(clampedStart, oldEndUTF16), markdownUTF16Count)
        let clampedNewEnd = min(max(clampedOldEnd, newEndUTF16), markdownUTF16Count)

        let start = String.Index(utf16Offset: clampedStart, in: markdown)
        let oldEnd = String.Index(utf16Offset: clampedOldEnd, in: markdown)
        let newEnd = String.Index(utf16Offset: clampedNewEnd, in: markdown)

        return ComputedContext(
            contextStartUTF16: clampedStart,
            contextOldMarkdown: String(markdown[start..<oldEnd]),
            contextNewMarkdown: String(markdown[start..<newEnd])
        )
    }
}

private final class AttributedStringSendableBox: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = value
    }
}

private final class StagedPromotionParseResultBox: @unchecked Sendable {
    let preludeDisplayLength: Int
    let contextNewAttributed: NSAttributedString
    let preludeCacheHit: Bool

    init(preludeDisplayLength: Int, contextNewAttributed: NSAttributedString, preludeCacheHit: Bool) {
        self.preludeDisplayLength = preludeDisplayLength
        self.contextNewAttributed = contextNewAttributed
        self.preludeCacheHit = preludeCacheHit
    }
}

/// Native TextKit-based editor prototype (no WebView).
///
/// Goal: prove the "true WYSIWYG + .md only" approach by:
/// - importing Markdown into an attributed-string representation that hides syntax
/// - letting the user edit rich text directly
/// - exporting back to deterministic Markdown
@MainActor
final class NativeEditorViewController: NSViewController, NSTextViewDelegate, NativeMarkdownTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let splitView = NSSplitView()
    private let headingOutlineContainer = NSView()
    private let headingOutlineHeaderLabel = NSTextField(labelWithString: "Headings")
    private let headingOutlineScrollView = NSScrollView()
    private let headingOutlineTableView = NSTableView()
    private var headingOutlineEntries: [HeadingOutlineEntry] = []
    private var headingOutlineRefreshWorkItem: DispatchWorkItem?
    private var headingOutlineSelectionIsProgrammatic = false
    private var headingOutlinePreferredWidth: CGFloat = 240
    private let headingOutlineLargeDocumentThresholdChars = 220_000
    private var headingOutlineVisiblePreference: Bool = {
        if UserDefaults.standard.object(forKey: "nativeEditor.headingOutlineVisible") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "nativeEditor.headingOutlineVisible")
    }()

    private let scrollView = NSScrollView()
    private let textView = NativeMarkdownTextView()
    private struct TableOverflowAnalysis {
        var widestLikelyTableRowCharacters: Int = 0
        var widestLikelyTableColumnCount: Int = 0

        static let empty = TableOverflowAnalysis()
    }
    private var tableOverflowAnalysis: TableOverflowAnalysis = .empty
    private var isHorizontalTableOverflowActive = false

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
    private var lastStableHoverCodeBlockRange: NSRange?
    private var caretCodeCopyCharacterRange: NSRange?
    private var hoverCodeCopyCharacterRange: NSRange?
    private var caretLastCodeBlockBackgroundRect: NSRect?
    private var hoverLastCodeBlockBackgroundRect: NSRect?
    private var isUpdatingCodeBlockChrome = false
    private var codeBlockChromeNeedsRefresh = false
    private var hoverChromePointerInside = false
    private var pendingHoverChromeClearWorkItem: DispatchWorkItem?
    private let hoverChromeClearDelayMs = 120

    private struct AnchorJumpGuard {
        let anchor: String
        let linkCharIndex: Int
        var targetParagraphLocation: Int?
        var targetSelectionLocation: Int?
        var lastJumpedAt: Date
        var remainingRejumps: Int
        let expiresAt: Date
    }

    private var pendingAnchorJumpWorkItem: DispatchWorkItem?
    private var pendingAnchorJumpGuardWorkItem: DispatchWorkItem?
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
    private var spellingSuppressedForCodeBlock = false
    private let codecWorkQueue = DispatchQueue(label: "com.gradigit.kern.codec-work", qos: .userInitiated)
    private var exportWorkItem: DispatchWorkItem?
    private var exportWorkToken: UInt64 = 0
    private var hasUnexportedChanges = false
    /// Avoid full-document layout forcing on medium/large files; it can stall first-open latency.
    /// Keep force-layout only for small documents where the accuracy benefit is effectively free.
    private let fullLayoutForceCharThreshold = 12_000
    private var largeDocumentLightLayoutWorkItem: DispatchWorkItem?
    private var deferredFullRenderWorkItem: DispatchWorkItem?
    private var deferredFullRenderParseToken: UInt64 = 0
    private var scrollChromeUpdateWorkItem: DispatchWorkItem?
    private var stagedPromotionWorkItem: DispatchWorkItem?
    private var stagedPromotionLayoutWorkItem: DispatchWorkItem?
    private var stagedPromotionComputeTask: Task<Void, Never>?
    private var deferredFullRenderToken: UInt64 = 0
    private var stagedPromotionToken: UInt64 = 0
    private var stagedPromotionInFlight = false
    private var stagedPromotionInFlightToken: UInt64?
    private var stagedPromotionInFlightStartedAtUptime: TimeInterval?
    private var lastStagedPromotionApplyMs: Double = 0
    private let stagedPromotionComputeWorker = StagedPromotionComputeWorker()
    private var lastUserInteractionUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastUserScrollEventUptime: TimeInterval?
    private var isUserLiveScrolling: Bool = false
    private var renderGeneration: Int = 0
    private let stagedOpenCharThreshold = 250_000
    private let stagedOpenPrefixLineBudget = 900
    private let stagedOpenPrefixCharBudget = 140_000
    private let stagedOpenVeryLargeDocCharThreshold = 1_000_000
    private let stagedOpenVeryLargePrefixLineBudget = 220
    private let stagedOpenVeryLargePrefixCharBudget = 48_000
    private let stagedOpenDeferredFullDelayMs = 120
    private let stagedOpenDeferredQuietPeriodMs = 1_200
    private let stagedOpenVeryLargeDeferredQuietPeriodMs = 4_000
    private let stagedOpenDeferredFullDisableThreshold = 250_000
    private let stagedPromotionDebounceMs = 30
    private let stagedPromotionFollowupDelayMs = 10
    private let stagedPromotionStepChars = 450_000
    private let stagedPromotionMaxCatchupStepChars = 4_000_000
    private let stagedPromotionTurboFollowupDelayMs = 6
    private let stagedPromotionTurboStepChars = 4_000_000
    private let stagedPromotionTurboMaxCatchupStepChars = 8_000_000
    private let stagedPromotionTurboActivateIdleMs = 250
    private let stagedPromotionContextChars = 3_000
    private let stagedPromotionViewportGuardChars = 400
    private let stagedPromotionViewportMicroStepChars = 448_000
    private let stagedPromotionViewportMicroStepMinChars = 128_000
    private let stagedPromotionViewportMicroStepMaxChars = 2_400_000
    private let stagedPromotionTurboViewportMicroStepMaxChars = 640_000
    private let stagedPromotionIdleQuietPeriodMs = 40
    private let stagedPromotionScrollQuietPeriodMs = 90
    private let stagedPromotionLookaheadVisibleChars = 220_000
    private let bulkEditRenderRefreshThresholdUTF16 = 64
    private let stagedPromotionLayoutCoalesceMs = 180
    private let stagedPromotionFrameBudgetMs = 4.0
    private let stagedPromotionMaxViewportCorrectionPx: CGFloat = 56
    private let stagedPromotionJumpMetricThresholdPx: CGFloat = 24
    private let scrollChromeThrottleCharThreshold = 120_000
    private let scrollChromeThrottleDelayMs = 120
    private var stagedRenderedMarkdownUTF16Count: Int?
    private var stagedRenderedDisplayBoundary: Int?
    private var stagedRenderGeneration: Int?
    private var stagedReferenceDefinitions: [String: NativeMarkdownCodec.ReferenceDefinition]?
    private var stagedReferenceDefinitionsGeneration: Int?
    private var stagedPromotionsAllowed: Bool = false
    private var stagedContextBoundaryStartUTF16: Int?
    private var stagedContextBoundaryDisplayStart: Int?
    private var stagedContextBoundaryRenderedUTF16: Int?
    private var stagedDeferredSyntaxHighlightingEnabled = false
    private var deferredSyntaxHighlightWorkItem: DispatchWorkItem?
    private var deferredSyntaxHighlightQueue: [DeferredSyntaxHighlightJob] = []
    private var deferredSyntaxHighlightInFlight = false
    private let stagedDeferredSyntaxHighlightingThresholdChars = 250_000
    private let stagedDeferredSyntaxHighlightBatchLimit = 10
    private let stagedDeferredSyntaxHighlightBatchBudgetMs = 5.5
    private var stagedAdaptiveViewportMicroStepChars: Int = 256_000
    private var pendingEditMutation: PendingEditMutation?
    private var pendingStagedRecoveryAfterExport: Bool = false
    private var pendingRenderRefreshAfterExport: Bool = false
    /// Test seam: disables debounced background export work while keeping explicit flush/save behavior.
    /// This avoids runaway async work during exhaustive non-UI typing matrices.
    var disablesDebouncedExportsForTesting = false
    private var syntaxVisibilityMode: NativeEditorSyntaxVisibilityMode = .fromUserDefaults()
    private struct HybridInlineExpansionState {
        var sourceRange: NSRange
    }
    private struct HybridInlineSpanCandidate {
        var range: NSRange
        var source: String
        var prefixUTF16Count: Int
    }
    private var activeHybridInlineExpansion: HybridInlineExpansionState?
    private var isApplyingHybridInlineTransition = false
    private var suppressHybridExpansionForCurrentRunLoop = false

    private struct PendingEditMutation {
        let range: NSRange
        let replacementUTF16Count: Int
        let replacementContainsLineBreak: Bool
        let replacementLikelyMarkdownSyntax: Bool

        var deltaUTF16: Int {
            replacementUTF16Count - range.length
        }
    }

    private struct DeferredSyntaxHighlightJob {
        let range: NSRange
        let language: String
    }

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

        splitView.frame = container.bounds
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.setAccessibilityIdentifier("NativeEditor.SplitView")
        container.addSubview(splitView)

        headingOutlineContainer.setAccessibilityIdentifier("NativeEditor.HeadingOutline")
        headingOutlineContainer.wantsLayer = true
        headingOutlineContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        headingOutlineHeaderLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        headingOutlineHeaderLabel.textColor = .secondaryLabelColor
        headingOutlineHeaderLabel.frame = NSRect(x: 12, y: 0, width: 200, height: 22)
        headingOutlineHeaderLabel.isEditable = false
        headingOutlineHeaderLabel.isSelectable = false
        headingOutlineHeaderLabel.isBezeled = false
        headingOutlineHeaderLabel.drawsBackground = false
        headingOutlineContainer.addSubview(headingOutlineHeaderLabel)

        headingOutlineScrollView.drawsBackground = false
        headingOutlineScrollView.hasVerticalScroller = true
        headingOutlineScrollView.hasHorizontalScroller = false
        headingOutlineScrollView.autohidesScrollers = true
        headingOutlineScrollView.borderType = .noBorder
        headingOutlineScrollView.setAccessibilityIdentifier("NativeEditor.HeadingOutlineScrollView")

        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HeadingOutlineColumn"))
        outlineColumn.title = "Headings"
        headingOutlineTableView.addTableColumn(outlineColumn)
        headingOutlineTableView.headerView = nil
        headingOutlineTableView.usesAlternatingRowBackgroundColors = false
        headingOutlineTableView.focusRingType = .none
        headingOutlineTableView.backgroundColor = .clear
        headingOutlineTableView.allowsColumnReordering = false
        headingOutlineTableView.allowsColumnResizing = false
        headingOutlineTableView.allowsTypeSelect = true
        headingOutlineTableView.rowSizeStyle = .small
        headingOutlineTableView.intercellSpacing = NSSize(width: 0, height: 4)
        headingOutlineTableView.rowHeight = 20
        headingOutlineTableView.delegate = self
        headingOutlineTableView.dataSource = self
        headingOutlineTableView.setAccessibilityIdentifier("NativeEditor.HeadingOutlineTable")

        headingOutlineScrollView.documentView = headingOutlineTableView
        headingOutlineContainer.addSubview(headingOutlineScrollView)

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
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.onHoverCodeBlockRangeChanged = { [weak self] range in
            self?.handleCodeBlockHoverRangeChanged(range)
        }
        // Ensure the document view grows with content (and provides bottom whitespace so anchor jumps can
        // land headings near the top, even close to EOF).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        setBaseTypingAttributes()
        updateSpellcheckBehaviorForSelection()
        // Critical for huge documents: allows jumping/scrolling to distant regions without forcing
        // contiguous layout from document start to destination.
        textView.layoutManager?.allowsNonContiguousLayout = true

        scrollView.documentView = textView

        splitView.addSubview(headingOutlineContainer)
        splitView.addSubview(scrollView)
        headingOutlineContainer.frame = NSRect(x: 0, y: 0, width: headingOutlinePreferredWidth, height: splitView.bounds.height)
        scrollView.frame = NSRect(
            x: headingOutlinePreferredWidth + splitView.dividerThickness,
            y: 0,
            width: max(0, splitView.bounds.width - headingOutlinePreferredWidth - splitView.dividerThickness),
            height: splitView.bounds.height
        )
        layoutHeadingOutline()
        applyHeadingOutlineVisibility(animated: false)

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
        hoverCodeBlockChrome.onPointerInsideChanged = { [weak self] inside in
            self?.handleHoverChromePointerInsideChanged(inside)
        }
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
            selector: #selector(scrollViewWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
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
        // Selector-based observers are safe to remove wholesale here without touching actor-isolated state.
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyThemeAppearanceFromPreferences()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutHeadingOutline()
        syncTextContainerSizeToScrollViewWidth()
        adjustDocumentViewHeightToContent(forceFullLayout: false)
        layoutFindBar()
        updateCodeBlockChrome()
    }

    private func layoutHeadingOutline() {
        guard isViewLoaded else { return }

        let bounds = headingOutlineContainer.bounds
        let headerHeight: CGFloat = 24
        headingOutlineHeaderLabel.frame = NSRect(x: 12, y: max(0, bounds.height - headerHeight - 6), width: max(0, bounds.width - 24), height: headerHeight)
        headingOutlineScrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight - 8))
        if let col = headingOutlineTableView.tableColumns.first {
            col.width = max(80, headingOutlineScrollView.contentSize.width)
        }
    }

    private func applyHeadingOutlineVisibility(animated: Bool) {
        let hasHeadings = !headingOutlineEntries.isEmpty
        let shouldShow = headingOutlineVisiblePreference && hasHeadings
        let targetWidth: CGFloat = shouldShow ? headingOutlinePreferredWidth : 0

        headingOutlineContainer.isHidden = !shouldShow
        if shouldShow {
            splitView.setPosition(targetWidth, ofDividerAt: 0)
        } else {
            splitView.setPosition(0, ofDividerAt: 0)
        }
        splitView.adjustSubviews()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.view.layoutSubtreeIfNeeded()
            }
        }
        layoutHeadingOutline()
    }

    private func rebuildHeadingOutlineFromStorage() {
        guard let storage = textView.textStorage else {
            headingOutlineEntries = []
            headingOutlineTableView.reloadData()
            applyHeadingOutlineVisibility(animated: false)
            return
        }

        if storage.length >= headingOutlineLargeDocumentThresholdChars,
           (stagedPromotionsAllowed || stagedPromotionInFlight || deferredFullRenderWorkItem != nil) {
            // Avoid expensive whole-document heading scans while staged promotion is actively
            // catching up on very large files. We'll refresh once promotion settles.
            return
        }

        let previousSelectedSlug: String? = {
            let row = headingOutlineTableView.selectedRow
            guard row >= 0, row < headingOutlineEntries.count else { return nil }
            return headingOutlineEntries[row].slug
        }()

        headingOutlineEntries = HeadingOutlineIndex.make(from: storage)
        headingOutlineTableView.reloadData()
        applyHeadingOutlineVisibility(animated: false)

        if let previousSelectedSlug,
           let idx = headingOutlineEntries.firstIndex(where: { $0.slug == previousSelectedSlug }) {
            headingOutlineSelectionIsProgrammatic = true
            headingOutlineTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            headingOutlineSelectionIsProgrammatic = false
        } else {
            headingOutlineSelectionIsProgrammatic = true
            headingOutlineTableView.deselectAll(nil)
            headingOutlineSelectionIsProgrammatic = false
        }
    }

    private func scheduleHeadingOutlineRefresh() {
        headingOutlineRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildHeadingOutlineFromStorage()
        }
        headingOutlineRefreshWorkItem = work
        if isRunningUnderXCTest {
            work.perform()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc func toggleHeadingOutline(_ sender: Any?) {
        headingOutlineVisiblePreference.toggle()
        UserDefaults.standard.set(headingOutlineVisiblePreference, forKey: "nativeEditor.headingOutlineVisible")
        applyHeadingOutlineVisibility(animated: true)
    }

    func isHeadingOutlineVisibleForMenuState() -> Bool {
        headingOutlineVisiblePreference
    }

    func headingOutlineEntriesForTesting() -> [HeadingOutlineEntry] {
        headingOutlineEntries
    }

    func selectHeadingOutlineEntryForTesting(index: Int) {
        guard index >= 0, index < headingOutlineEntries.count else { return }
        headingOutlineSelectionIsProgrammatic = true
        headingOutlineTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        headingOutlineSelectionIsProgrammatic = false
        jumpToHeadingOutlineEntry(at: index)
    }

    private func jumpToHeadingOutlineEntry(at row: Int) {
        guard row >= 0, row < headingOutlineEntries.count else { return }
        let entry = headingOutlineEntries[row]
        if !jumpToAnchor(entry.slug) {
            textView.setSelectedRange(NSRange(location: entry.paragraphLocation, length: 0))
            scrollParagraphNearTop(NSRange(location: entry.paragraphLocation, length: 1))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == headingOutlineTableView {
            return headingOutlineEntries.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView == headingOutlineTableView else { return nil }
        guard row >= 0, row < headingOutlineEntries.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("HeadingOutlineCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = NSFont.systemFont(ofSize: 12)
            text.textColor = .labelColor
            text.isSelectable = false
            text.drawsBackground = false
            text.isBezeled = false
            text.tag = 100
            view.addSubview(text)
            NSLayoutConstraint.activate([
                text.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            ])
            return view
        }()

        guard let label = cell.viewWithTag(100) as? NSTextField else { return cell }
        let entry = headingOutlineEntries[row]
        let indent = CGFloat(max(0, entry.level - 1)) * 12
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = indent
        paragraph.firstLineHeadIndent = indent
        let attr = NSAttributedString(
            string: entry.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: entry.level <= 2 ? .semibold : .regular),
                .foregroundColor: NativeEditorAppearance.primaryTextColor(),
                .paragraphStyle: paragraph,
            ]
        )
        label.attributedStringValue = attr
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView == headingOutlineTableView else { return }
        guard !headingOutlineSelectionIsProgrammatic else { return }
        jumpToHeadingOutlineEntry(at: headingOutlineTableView.selectedRow)
    }

    private func syncTextContainerSizeToScrollViewWidth() {
        guard let tc = textView.textContainer else { return }
        let viewportWidth = max(0, scrollView.contentView.bounds.width)
        // Keep the primary document viewport width-locked.
        // Document-wide horizontal scrolling creates poor UX for mixed-content markdown files:
        // a single wide table should not force the entire editor surface to scroll sideways.
        //
        // Horizontal table mode is now reserved for table-local overflow behavior (future work),
        // so we intentionally keep document-level overflow disabled here.
        tc.widthTracksTextView = true
        tc.containerSize = NSSize(
            width: viewportWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let targetWidth = viewportWidth
        if abs(textView.frame.width - targetWidth) > 1 {
            var frame = textView.frame
            frame.size.width = targetWidth
            textView.frame = frame
        }
        isHorizontalTableOverflowActive = false
    }

    private func desiredHorizontalTableOverflowWidth(viewportWidth: CGFloat) -> CGFloat {
        guard NativeEditorAppearance.tableOverflowMode() == .horizontal else { return viewportWidth }
        guard tableOverflowAnalysis.widestLikelyTableRowCharacters > 0 else { return viewportWidth }

        let baseFont = NativeEditorAppearance.baseFont()
        let averageGlyphWidth = max(6.2, baseFont.pointSize * 0.56)
        let estimatedRowWidth = CGFloat(tableOverflowAnalysis.widestLikelyTableRowCharacters) * averageGlyphWidth
        let columnBonus = CGFloat(tableOverflowAnalysis.widestLikelyTableColumnCount) * 56
        let desired = estimatedRowWidth + columnBonus + 96

        let minWidth = max(viewportWidth, 920)
        let clamped = min(4_800, max(minWidth, desired))
        return clamped
    }

    private func rebuildTableOverflowAnalysis(markdown: String) {
        let newlineSet = CharacterSet.newlines
        var inFence = false
        var analysis = TableOverflowAnalysis.empty

        markdown.enumerateSubstrings(in: markdown.startIndex..<markdown.endIndex, options: .byLines) { line, _, _, _ in
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: newlineSet.union(.whitespaces))

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return
            }
            if inFence || trimmed.isEmpty { return }

            let pipeCount = line.reduce(into: 0) { count, ch in
                if ch == "|" { count += 1 }
            }
            guard pipeCount >= 2 else { return }
            let looksLikeTableRow =
                trimmed.hasPrefix("|")
                || trimmed.hasSuffix("|")
                || trimmed.contains(" | ")
                || trimmed.contains("| ")
                || trimmed.contains(" |")
            guard looksLikeTableRow else { return }

            analysis.widestLikelyTableRowCharacters = max(analysis.widestLikelyTableRowCharacters, line.utf16.count)
            analysis.widestLikelyTableColumnCount = max(analysis.widestLikelyTableColumnCount, max(1, pipeCount - 1))
        }

        tableOverflowAnalysis = analysis
    }

    func isHorizontalTableOverflowActiveForTesting() -> Bool {
        isHorizontalTableOverflowActive
    }

    func scrollOriginYForTesting() -> CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    func setScrollOriginYForTesting(_ y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, y)))
        scrollView.reflectScrolledClipView(clip)
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
        let maxLocation = max(0, textView.string.utf16.count)
        let safeLoc = min(selection.location, maxLocation)
        textView.setSelectedRange(NSRange(location: safeLoc, length: 0))

        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyPreferencesAndRerender() {
        guard viewIfLoaded != nil else { return }
        activeHybridInlineExpansion = nil
        syntaxVisibilityMode = NativeEditorSyntaxVisibilityMode.fromUserDefaults()
        applyThemeAppearanceFromPreferences()
        isApplyingExternalUpdate = true
        renderMarkdown(stringValue, preserveSelection: true)
        isApplyingExternalUpdate = false
        adjustDocumentViewHeightToContent()
        updateCodeBlockChrome()
        scheduleHeadingOutlineRefresh()
        scheduleFindUpdate(resetIndex: false, anchorLocation: nil)
        scheduleExport()
        if !isApplyingHybridInlineTransition {
            maybeApplyHybridInlineExpansionForSelection()
        }
    }

    private func applyThemeAppearanceFromPreferences() {
        NativeEditorAppearance.applyTheme(to: view.window)
    }

    @objc private func nativeEditorPreferencesDidChange(_ notification: Notification) {
        applyPreferencesAndRerender()
    }

    func attributedTextForTesting() -> NSAttributedString {
        textView.attributedString()
    }

    func textViewForTesting() -> NativeMarkdownTextView {
        textView
    }

    private func makeMarkdownSyntaxVisibleAttributed(_ markdown: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = 5
        style.lineHeightMultiple = 1.12
        return NSAttributedString(
            string: markdown,
            attributes: [
                .font: NativeEditorAppearance.baseFont(),
                .foregroundColor: NativeEditorAppearance.primaryTextColor(),
                .paragraphStyle: style,
            ]
        )
    }

    private func renderMarkdown(_ markdown: String, preserveSelection: Bool) {
        noteUserInteraction()
        activeHybridInlineExpansion = nil
        if deferredFullRenderWorkItem != nil
            || stagedPromotionsAllowed
            || stagedPromotionInFlight
            || stagedPromotionWorkItem != nil
        {
            WowInternalMetricsRecorder.shared.failFullDocumentFidelityIfMissing(reason: "superseded_by_new_render")
        }
        renderGeneration &+= 1
        let currentGeneration = renderGeneration
        deferredFullRenderWorkItem?.cancel()
        deferredFullRenderWorkItem = nil
        deferredFullRenderToken &+= 1
        stagedPromotionWorkItem?.cancel()
        stagedPromotionWorkItem = nil
        stagedPromotionLayoutWorkItem?.cancel()
        stagedPromotionLayoutWorkItem = nil
        stagedPromotionComputeTask?.cancel()
        stagedPromotionComputeTask = nil
        stagedPromotionToken &+= 1
        stagedPromotionInFlight = false
        stagedPromotionInFlightToken = nil
        stagedPromotionInFlightStartedAtUptime = nil
        stagedRenderedMarkdownUTF16Count = nil
        stagedRenderedDisplayBoundary = nil
        stagedRenderGeneration = nil
        stagedReferenceDefinitions = nil
        stagedReferenceDefinitionsGeneration = nil
        stagedPromotionsAllowed = false
        resetDeferredSyntaxHighlightState()
        resetStagedContextBoundaryCache()
        pendingEditMutation = nil
        pendingRenderRefreshAfterExport = false
        resetAdaptiveStagedPromotionBudget()

        let wow = WowInternalMetricsRecorder.shared
        wow.beginRun()
        let selection = preserveSelection ? textView.selectedRange() : nil
        let scrollOrigin = preserveSelection ? scrollView.contentView.bounds.origin : nil

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        let useStagedOpen = shouldUseStagedOpen(for: markdown)
        let deferSyntaxHighlightingDuringStagedOpen = useStagedOpen && shouldDeferSyntaxHighlightingDuringStagedOpen(
            markdownUTF16Count: markdown.utf16.count,
            options: opt
        )
        stagedDeferredSyntaxHighlightingEnabled = deferSyntaxHighlightingDuringStagedOpen
        var stagedOpenOptions = opt
        if deferSyntaxHighlightingDuringStagedOpen {
            stagedOpenOptions.syntaxHighlightingEnabled = false
        }
        let referenceDefinitions = useStagedOpen
            ? NativeMarkdownCodec.collectReferenceDefinitions(in: markdown)
            : nil
        rebuildTableOverflowAnalysis(markdown: markdown)

        wow.beginOpenReady()
        wow.beginViewportSemanticReady()
        wow.beginViewportFidelityReady()
        wow.beginFullDocumentFidelityReady()

        wow.beginParse()
        let attr: NSAttributedString
        if syntaxVisibilityMode.isSyntaxVisible {
            attr = makeMarkdownSyntaxVisibleAttributed(markdown)
            stagedRenderedMarkdownUTF16Count = nil
            stagedRenderedDisplayBoundary = nil
            stagedRenderGeneration = nil
            stagedReferenceDefinitions = nil
            stagedReferenceDefinitionsGeneration = nil
            stagedPromotionsAllowed = false
            resetStagedContextBoundaryCache()
        } else if useStagedOpen {
            let staged = makeStagedInitialAttributed(
                markdown: markdown,
                options: stagedOpenOptions,
                precomputedReferenceDefinitions: referenceDefinitions
            )
            attr = staged.attributed
            stagedRenderedMarkdownUTF16Count = staged.renderedMarkdownUTF16Count
            stagedRenderedDisplayBoundary = staged.renderedDisplayBoundary
            stagedRenderGeneration = currentGeneration
            stagedReferenceDefinitions = referenceDefinitions
            stagedReferenceDefinitionsGeneration = currentGeneration
            stagedPromotionsAllowed = staged.renderedMarkdownUTF16Count < markdown.utf16.count
            resetStagedContextBoundaryCache()
        } else {
            attr = NativeMarkdownCodec.importMarkdown(markdown, options: opt, baseURL: documentURL)
            stagedRenderedMarkdownUTF16Count = nil
            stagedRenderedDisplayBoundary = nil
            stagedRenderGeneration = nil
            stagedReferenceDefinitions = nil
            stagedReferenceDefinitionsGeneration = nil
            stagedPromotionsAllowed = false
            resetStagedContextBoundaryCache()
        }
        wow.endParse()

        wow.beginPaintReady()
        textView.textStorage?.setAttributedString(attr)
        syncTextContainerSizeToScrollViewWidth()
        rebuildHeadingOutlineFromStorage()
        DispatchQueue.main.async {
            WowInternalMetricsRecorder.shared.endPaintReady()
        }
        let forceFullLayout = markdown.utf16.count <= fullLayoutForceCharThreshold
        wow.beginLayout()
        adjustDocumentViewHeightToContent(forceFullLayout: forceFullLayout)
        wow.endLayout()
        scheduleLargeDocumentLightLayoutIfNeeded(markdown: markdown)

        wow.endViewportSemanticReady()
        wow.endViewportFidelityReady()
        wow.endOpenReady()

        if let selection {
            let maxLocation = max(0, textView.string.utf16.count)
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

        if syntaxVisibilityMode.isSyntaxVisible {
            wow.endFullDocumentFidelityReady()
        } else if useStagedOpen {
            if markdown.utf16.count >= stagedDeferredFullDisableThreshold() {
                // Very large docs skip single-shot deferred full render to avoid giant one-time stalls.
                // Continue staged promotions in the background while idle.
                scheduleStagedPromotionFollowupIfNeeded()
            } else {
                scheduleDeferredFullRender(
                    markdown: markdown,
                    options: opt,
                    generation: currentGeneration
                )
            }
        } else {
            wow.endFullDocumentFidelityReady()
        }
    }

    private func shouldUseStagedOpen(for markdown: String) -> Bool {
        if ProcessInfo.processInfo.environment["KERN_FORCE_FULL_MARKDOWN_IMPORT"] == "1" {
            return false
        }
        if ProcessInfo.processInfo.environment["KERN_FORCE_STAGED_OPEN"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["KERN_DISABLE_STAGED_OPEN"] == "1" {
            return false
        }
        let threshold: Int = {
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_OPEN_THRESHOLD_CHARS"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                return parsed
            }
            return stagedOpenCharThreshold
        }()
        return markdown.utf16.count >= threshold
    }

    private func stagedDeferredFullDisableThreshold() -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        return stagedOpenDeferredFullDisableThreshold
    }

    private struct StagedAttributedPayload {
        let attributed: NSAttributedString
        let renderedMarkdownUTF16Count: Int
        let renderedDisplayBoundary: Int
    }

    private func stagedPrefixMarkdown(_ markdown: String) -> (prefix: String, utf16Count: Int) {
        guard !markdown.isEmpty else { return ("", 0) }
        let markdownLength = markdown.utf16.count
        let isVeryLargeDocument = markdownLength >= stagedOpenVeryLargeDocCharThreshold

        let lineBudget: Int = {
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_OPEN_PREFIX_LINES"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                return parsed
            }
            return isVeryLargeDocument ? stagedOpenVeryLargePrefixLineBudget : stagedOpenPrefixLineBudget
        }()
        let charBudget: Int = {
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_OPEN_PREFIX_CHARS"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                return parsed
            }
            return isVeryLargeDocument ? stagedOpenVeryLargePrefixCharBudget : stagedOpenPrefixCharBudget
        }()

        let ns = markdown as NSString
        let maxChars = min(ns.length, charBudget)
        var scanLocation = 0
        var newlineCount = 0
        var endLocation = maxChars

        while scanLocation < ns.length, newlineCount < lineBudget, scanLocation < maxChars {
            let searchRange = NSRange(location: scanLocation, length: ns.length - scanLocation)
            let nlRange = ns.range(of: "\n", options: [], range: searchRange)
            if nlRange.location == NSNotFound {
                endLocation = min(ns.length, maxChars)
                break
            }
            let nextScan = nlRange.location + nlRange.length
            if nextScan > maxChars {
                endLocation = maxChars
                break
            }
            newlineCount += 1
            scanLocation = nextScan
            endLocation = nextScan
        }

        if endLocation >= ns.length {
            return (markdown, markdown.utf16.count)
        }

        let prefixEnd = String.Index(utf16Offset: max(0, min(endLocation, markdown.utf16.count)), in: markdown)
        let prefix = String(markdown[..<prefixEnd])
        return (prefix, prefix.utf16.count)
    }

    private func alignedPromotionUTF16Count(
        _ markdown: String,
        targetUTF16Count: Int
    ) -> Int {
        let ns = markdown as NSString
        guard ns.length > 0 else { return 0 }

        var endLocation = min(max(0, targetUTF16Count), ns.length)
        if endLocation < ns.length {
            let searchRange = NSRange(location: endLocation, length: min(ns.length - endLocation, 8_192))
            let nlRange = ns.range(of: "\n", options: [], range: searchRange)
            if nlRange.location != NSNotFound {
                endLocation = nlRange.location + nlRange.length
            }
        }
        return endLocation
    }

    private func makeStagedAttributed(
        markdown: String,
        options: NativeMarkdownCodec.Options,
        prefix: String,
        prefixUTF16Count: Int,
        baseURL: URL?,
        precomputedReferenceDefinitions: [String: NativeMarkdownCodec.ReferenceDefinition]?
    ) -> StagedAttributedPayload {
        if prefixUTF16Count >= markdown.utf16.count {
            let full = NativeMarkdownCodec.importMarkdown(
                markdown,
                options: options,
                baseURL: baseURL,
                precomputedReferenceDefinitions: precomputedReferenceDefinitions
            )
            return StagedAttributedPayload(
                attributed: full,
                renderedMarkdownUTF16Count: markdown.utf16.count,
                renderedDisplayBoundary: full.length
            )
        }

        let prefixAttr = NSMutableAttributedString(
            attributedString: NativeMarkdownCodec.importMarkdown(
                prefix,
                options: options,
                baseURL: baseURL,
                precomputedReferenceDefinitions: precomputedReferenceDefinitions
            )
        )
        let renderedBoundary = prefixAttr.length
        let suffixStart = String.Index(utf16Offset: min(prefixUTF16Count, markdown.utf16.count), in: markdown)
        let suffix = String(markdown[suffixStart...])
        if !suffix.isEmpty {
            let baseFont = NativeEditorAppearance.baseFont()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NativeEditorAppearance.primaryTextColor(),
            ]
            prefixAttr.append(NSAttributedString(string: suffix, attributes: attrs))
        }
        return StagedAttributedPayload(
            attributed: prefixAttr,
            renderedMarkdownUTF16Count: prefixUTF16Count,
            renderedDisplayBoundary: renderedBoundary
        )
    }

    private func makeStagedInitialAttributed(
        markdown: String,
        options: NativeMarkdownCodec.Options,
        precomputedReferenceDefinitions: [String: NativeMarkdownCodec.ReferenceDefinition]?
    ) -> StagedAttributedPayload {
        let initialPrefix = stagedPrefixMarkdown(markdown)
        return makeStagedAttributed(
            markdown: markdown,
            options: options,
            prefix: initialPrefix.prefix,
            prefixUTF16Count: initialPrefix.utf16Count,
            baseURL: documentURL,
            precomputedReferenceDefinitions: precomputedReferenceDefinitions
        )
    }

    private func currentStagedReferenceDefinitions(
        for generation: Int
    ) -> [String: NativeMarkdownCodec.ReferenceDefinition]? {
        guard stagedReferenceDefinitionsGeneration == generation else { return nil }
        return stagedReferenceDefinitions
    }

    private func resetStagedContextBoundaryCache() {
        stagedContextBoundaryStartUTF16 = nil
        stagedContextBoundaryDisplayStart = nil
        stagedContextBoundaryRenderedUTF16 = nil
    }

    private func shouldDeferSyntaxHighlightingDuringStagedOpen(
        markdownUTF16Count: Int,
        options: NativeMarkdownCodec.Options
    ) -> Bool {
        guard options.syntaxHighlightingEnabled else { return false }
        if ProcessInfo.processInfo.environment["KERN_DISABLE_STAGED_DEFERRED_SYNTAX_HIGHLIGHTING"] == "1" {
            return false
        }
        if ProcessInfo.processInfo.environment["KERN_FORCE_STAGED_DEFERRED_SYNTAX_HIGHLIGHTING"] == "1" {
            return true
        }
        let threshold: Int = {
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_DEFERRED_SYNTAX_HIGHLIGHTING_THRESHOLD_CHARS"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed > 0 {
                return parsed
            }
            return stagedDeferredSyntaxHighlightingThresholdChars
        }()
        return markdownUTF16Count >= threshold
    }

    private func resetDeferredSyntaxHighlightState() {
        deferredSyntaxHighlightWorkItem?.cancel()
        deferredSyntaxHighlightWorkItem = nil
        deferredSyntaxHighlightQueue.removeAll(keepingCapacity: true)
        deferredSyntaxHighlightInFlight = false
        stagedDeferredSyntaxHighlightingEnabled = false
    }

    private func enqueueDeferredSyntaxHighlightJobsForWholeDocumentIfNeeded() {
        guard stagedDeferredSyntaxHighlightingEnabled else { return }
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let scanRange = NSRange(location: 0, length: storage.length)
        var existing = Set<String>()
        for job in deferredSyntaxHighlightQueue {
            existing.insert("\(job.range.location):\(job.range.length):\(job.language)")
        }

        storage.enumerateAttribute(.kernBlockKind, in: scanRange, options: []) { value, range, _ in
            guard let rawKind = value as? Int, rawKind == KernBlockKind.codeBlock.rawValue else { return }
            guard range.length > 0 else { return }
            guard range.location + range.length <= storage.length else { return }
            if (storage.attribute(.kernSyntaxHighlighted, at: range.location, effectiveRange: nil) as? Bool) == true {
                return
            }
            guard let language = codeLanguageForCodeBlock(in: storage, range: range) else { return }
            let key = "\(range.location):\(range.length):\(language)"
            if existing.insert(key).inserted {
                deferredSyntaxHighlightQueue.append(DeferredSyntaxHighlightJob(range: range, language: language))
            }
        }
    }

    private func codeLanguageForCodeBlock(in storage: NSTextStorage, range: NSRange) -> String? {
        guard range.length > 0 else { return nil }
        if let language = storage.attribute(.kernCodeLanguage, at: range.location, effectiveRange: nil) as? String,
           !language.isEmpty {
            return language
        }

        var foundLanguage: String?
        storage.enumerateAttribute(.kernCodeLanguage, in: range, options: []) { value, _, stop in
            if let language = value as? String, !language.isEmpty {
                foundLanguage = language
                stop.pointee = true
            }
        }
        if foundLanguage != nil {
            return foundLanguage
        }

        let searchBackLength = min(range.location, 256)
        if searchBackLength > 0 {
            let searchBackRange = NSRange(location: range.location - searchBackLength, length: searchBackLength)
            storage.enumerateAttribute(.kernCodeLanguage, in: searchBackRange, options: [.reverse]) { value, _, stop in
                if let language = value as? String, !language.isEmpty {
                    foundLanguage = language
                    stop.pointee = true
                }
            }
        }
        return foundLanguage
    }

    private func scheduleDeferredSyntaxHighlightPassIfNeeded(delayMs: Int = 120) {
        guard stagedDeferredSyntaxHighlightingEnabled else { return }
        guard !deferredSyntaxHighlightQueue.isEmpty else { return }
        deferredSyntaxHighlightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDeferredSyntaxHighlightBatch()
        }
        deferredSyntaxHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delayMs)), execute: work)
    }

    private func runDeferredSyntaxHighlightBatch() {
        guard stagedDeferredSyntaxHighlightingEnabled else { return }
        guard !deferredSyntaxHighlightInFlight else { return }
        guard !hasUnexportedChanges else {
            scheduleDeferredSyntaxHighlightPassIfNeeded(delayMs: 180)
            return
        }
        guard let storage = textView.textStorage else { return }
        deferredSyntaxHighlightInFlight = true
        defer {
            deferredSyntaxHighlightInFlight = false
        }

        let batchStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var processed = 0

        while processed < stagedDeferredSyntaxHighlightBatchLimit, !deferredSyntaxHighlightQueue.isEmpty {
            let elapsedMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - batchStart) / 1_000_000
            if processed > 0, elapsedMs >= stagedDeferredSyntaxHighlightBatchBudgetMs {
                break
            }

            let job = deferredSyntaxHighlightQueue.removeFirst()
            let range = job.range
            guard range.length > 0 else { continue }
            guard range.location >= 0, range.location + range.length <= storage.length else { continue }
            if (storage.attribute(.kernSyntaxHighlighted, at: range.location, effectiveRange: nil) as? Bool) == true {
                continue
            }

            let highlighted = NSMutableAttributedString(
                attributedString: storage.attributedSubstring(from: range)
            )
            NativeMarkdownCodec.applyDeferredSyntaxHighlightingToCodeBlock(highlighted, language: job.language)
            guard highlighted.length == range.length else { continue }

            isApplyingExternalUpdate = true
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: highlighted)
            storage.addAttribute(.kernSyntaxHighlighted, value: true, range: NSRange(location: range.location, length: range.length))
            storage.endEditing()
            isApplyingExternalUpdate = false

            processed += 1
        }

        if !deferredSyntaxHighlightQueue.isEmpty {
            scheduleDeferredSyntaxHighlightPassIfNeeded(delayMs: 20)
        } else {
            stagedDeferredSyntaxHighlightingEnabled = false
        }
    }

    private func scheduleDeferredFullRender(
        markdown: String,
        options: NativeMarkdownCodec.Options,
        generation: Int,
        delayOverrideMs: Int? = nil
    ) {
        deferredFullRenderWorkItem?.cancel()
        deferredFullRenderToken &+= 1
        let token = deferredFullRenderToken

        let delayMs: Int = {
            if let override = delayOverrideMs, override >= 0 {
                return override
            }
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_OPEN_DELAY_MS"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed >= 0 {
                return parsed
            }
            return stagedOpenDeferredFullDelayMs
        }()
        let quietPeriodMs: Int = {
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_OPEN_IDLE_QUIET_MS"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed >= 0 {
                return parsed
            }
            if markdown.utf16.count >= stagedOpenVeryLargeDocCharThreshold {
                return stagedOpenVeryLargeDeferredQuietPeriodMs
            }
            return stagedOpenDeferredQuietPeriodMs
        }()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard token == self.deferredFullRenderToken else { return }
            guard generation == self.renderGeneration else { return }
            guard self.stringValue == markdown else { return }
            guard !self.hasUnexportedChanges else { return }
            let sinceInteraction = ProcessInfo.processInfo.systemUptime - self.lastUserInteractionUptime
            let quietPeriodSeconds = Double(quietPeriodMs) / 1_000.0
            if sinceInteraction < quietPeriodSeconds {
                let retryDelayMs = Int(ceil(max(0.05, quietPeriodSeconds - sinceInteraction) * 1_000.0))
                self.scheduleDeferredFullRender(
                    markdown: markdown,
                    options: options,
                    generation: generation,
                    delayOverrideMs: retryDelayMs
                )
                return
            }
            if let sinceScroll = self.secondsSinceLastUserScroll() {
                let minScrollIdleSeconds = max(0.15, Double(self.scrollChromeThrottleDelayMs) / 1_000.0)
                if sinceScroll < minScrollIdleSeconds {
                    let retryDelayMs = Int(ceil(max(0.05, minScrollIdleSeconds - sinceScroll) * 1_000.0))
                    self.scheduleDeferredFullRender(
                        markdown: markdown,
                        options: options,
                        generation: generation,
                        delayOverrideMs: retryDelayMs
                    )
                    return
                }
            }

            let selection = self.textView.selectedRange()
            let scrollOrigin = self.scrollView.contentView.bounds.origin
            let baseURL = self.documentURL
            let referenceDefinitions = self.currentStagedReferenceDefinitions(for: generation)
            self.deferredFullRenderParseToken &+= 1
            let parseToken = self.deferredFullRenderParseToken
            let fullBox = AttributedStringSendableBox(
                NativeMarkdownCodec.importMarkdown(
                    markdown,
                    options: options,
                    baseURL: baseURL,
                    precomputedReferenceDefinitions: referenceDefinitions
                )
            )

            guard token == self.deferredFullRenderToken else { return }
            guard parseToken == self.deferredFullRenderParseToken else { return }
            guard generation == self.renderGeneration else { return }
            guard self.stringValue == markdown else { return }
            guard !self.hasUnexportedChanges else { return }

            // Deferred full render is an external visual upgrade, not a user edit.
            // Keep it out of textDidChange side-effects (dirty state, export debounce).
            self.isApplyingExternalUpdate = true
            defer { self.isApplyingExternalUpdate = false }
            self.textView.textStorage?.setAttributedString(fullBox.value)
            self.rebuildHeadingOutlineFromStorage()
            self.adjustDocumentViewHeightToContent(forceFullLayout: false)
            self.scheduleLargeDocumentLightLayoutIfNeeded(markdown: markdown)

            let safeLocation = min(selection.location, max(0, self.textView.string.utf16.count))
            let safeLength = min(selection.length, max(0, self.textView.string.utf16.count - safeLocation))
            self.textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            self.scrollView.contentView.scroll(to: scrollOrigin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)

            self.updateCodeBlockChrome()
            self.scheduleFindUpdate(resetIndex: false, anchorLocation: nil)

            self.finalizeStagedPromotionCompletion()
            self.deferredFullRenderWorkItem = nil
        }

        deferredFullRenderWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
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

        var textFontForAlignment: NSFont = NativeEditorAppearance.baseFont()
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
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        storage.beginEditing()
        defer { storage.endEditing() }

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
        noteUserInteraction()
        guard !isApplyingExternalUpdate else { return }
        guard !isApplyingInputRules else { return }
        guard !isApplyingAutoNewline else { return }
        suppressHybridExpansionForCurrentRunLoop = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressHybridExpansionForCurrentRunLoop = false
        }
        resetDeferredSyntaxHighlightState()

        let hadActiveStagedPipeline =
            stagedPromotionsAllowed ||
            stagedRenderGeneration != nil ||
            stagedRenderedMarkdownUTF16Count != nil ||
            stagedRenderedDisplayBoundary != nil

        let isUndoOrRedoEdit = {
            guard let undoManager = textView.undoManager else { return false }
            return undoManager.isUndoing || undoManager.isRedoing
        }()

        let mutation = pendingEditMutation
        pendingEditMutation = nil
        if !isUndoOrRedoEdit, shouldRefreshRenderAfterEdit(mutation: mutation) {
            pendingRenderRefreshAfterExport = true
        }
        let preservedStagedPipeline = isUndoOrRedoEdit
            ? false
            : preserveStagedPipelineAfterEditIfPossible(mutation: mutation)
        if !isUndoOrRedoEdit, !preservedStagedPipeline, hadActiveStagedPipeline {
            resetStagedPipelineStateForEdit()
            pendingStagedRecoveryAfterExport = true
        } else if isUndoOrRedoEdit {
            pendingRenderRefreshAfterExport = false
            pendingStagedRecoveryAfterExport = false
        }

        if deferredFullRenderWorkItem != nil {
            deferredFullRenderWorkItem?.cancel()
            deferredFullRenderWorkItem = nil
            deferredFullRenderToken &+= 1
        }

        WowInternalMetricsRecorder.shared.endEditApply()

        // Mark the document edited immediately so Save is enabled even if export is debounced.
        // The markdown string itself is still produced by export (debounced or flushed on save).
        if let doc = view.window?.windowController?.document {
            doc.updateChangeCount(.changeDone)
        }

        if syntaxVisibilityMode.isSyntaxVisible {
            adjustDocumentViewHeightToContent(forceFullLayout: false)
            updateCodeBlockChrome()
            scheduleHeadingOutlineRefresh()
            scheduleFindUpdate(resetIndex: false, anchorLocation: nil)
            scheduleExport()
            return
        }

        applyMarkdownInputRulesIfNeeded()
        handleNewlineContinuationIfNeeded()
        sanitizeTypingAttributesAfterLinkBoundaryIfNeeded()
        adjustDocumentViewHeightToContent(forceFullLayout: false)
        updateCodeBlockChrome()
        scheduleHeadingOutlineRefresh()
        scheduleFindUpdate(resetIndex: false, anchorLocation: nil)
        scheduleExport()
    }

    private func preserveStagedPipelineAfterEditIfPossible(mutation: PendingEditMutation?) -> Bool {
        guard let mutation else { return false }
        // Allow large documents to preserve staged-promotion progress across small edits.
        // Resetting to initial staged prefix on every keystroke can dramatically delay
        // full-fidelity completion and trigger repeated viewport churn.
        let markdownUTF16 = stringValue.utf16.count
        if markdownUTF16 >= stagedOpenVeryLargeDocCharThreshold {
            let delta = mutation.deltaUTF16
            if abs(delta) > 8_192 {
                return false
            }
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_pipeline_large_doc_preserve_attempt_count")
        }
        guard stagedPromotionsAllowed else { return false }
        guard stagedRenderGeneration == renderGeneration else { return false }
        guard var renderedBoundary = stagedRenderedDisplayBoundary else { return false }
        guard var renderedMarkdownUTF16 = stagedRenderedMarkdownUTF16Count else { return false }

        let editStart = max(0, mutation.range.location)
        let editEnd = editStart + max(0, mutation.range.length)
        guard editEnd <= renderedBoundary else { return false }

        let delta = mutation.deltaUTF16
        if editStart <= renderedBoundary {
            renderedBoundary = max(0, renderedBoundary + delta)
        }
        if editStart <= renderedMarkdownUTF16 {
            renderedMarkdownUTF16 = max(0, renderedMarkdownUTF16 + delta)
        }

        stagedPromotionWorkItem?.cancel()
        stagedPromotionWorkItem = nil
        stagedPromotionLayoutWorkItem?.cancel()
        stagedPromotionLayoutWorkItem = nil
        stagedPromotionComputeTask?.cancel()
        stagedPromotionComputeTask = nil
        stagedPromotionToken &+= 1
        stagedPromotionInFlight = false
        stagedPromotionInFlightToken = nil
        stagedPromotionInFlightStartedAtUptime = nil

        stagedRenderedDisplayBoundary = renderedBoundary
        stagedRenderedMarkdownUTF16Count = renderedMarkdownUTF16
        resetStagedContextBoundaryCache()
        pendingStagedRecoveryAfterExport = false
        return true
    }

    private func shouldRefreshRenderAfterEdit(mutation: PendingEditMutation?) -> Bool {
        guard let mutation else { return false }
        if let undoManager = textView.undoManager,
           (undoManager.isUndoing || undoManager.isRedoing) {
            return false
        }
        guard mutation.replacementUTF16Count > 0 else { return false }
        let isLikelyBulkInsert = mutation.replacementUTF16Count >= bulkEditRenderRefreshThresholdUTF16
        if isLikelyBulkInsert {
            return true
        }
        if mutation.replacementLikelyMarkdownSyntax {
            // Syntax-heavy inserts (markers, links, fences, etc.) often require an importer pass
            // to immediately restore WYSIWYG semantics.
            return mutation.replacementUTF16Count > 1 || mutation.replacementContainsLineBreak
        }
        if mutation.replacementContainsLineBreak {
            // Plain newline insertion should not force full render refreshes by default.
            // That path is expensive and can interfere with deep undo continuity.
            return mutation.replacementUTF16Count >= 512
        }
        return mutation.range.length >= bulkEditRenderRefreshThresholdUTF16
    }

    private func replacementLikelyContainsMarkdownSyntax(_ replacement: String) -> Bool {
        guard !replacement.isEmpty else { return false }
        if replacement.contains("```") || replacement.contains("~~~") { return true }
        if replacement.contains("- ["), replacement.contains("]") { return true }
        if replacement.contains("[ ]") || replacement.contains("[x]") || replacement.contains("[X]") { return true }
        if replacement.contains("[") && replacement.contains("](") && replacement.contains(")") { return true }
        if replacement.contains("# ") || replacement.hasPrefix("#") { return true }
        return replacement.rangeOfCharacter(from: CharacterSet(charactersIn: "`*_[]()|>~")) != nil
    }

    private func resetStagedPipelineStateForEdit() {
        stagedPromotionsAllowed = false
        stagedPromotionWorkItem?.cancel()
        stagedPromotionWorkItem = nil
        stagedPromotionLayoutWorkItem?.cancel()
        stagedPromotionLayoutWorkItem = nil
        stagedPromotionComputeTask?.cancel()
        stagedPromotionComputeTask = nil
        stagedPromotionToken &+= 1
        stagedPromotionInFlight = false
        stagedPromotionInFlightToken = nil
        stagedPromotionInFlightStartedAtUptime = nil
        stagedRenderedMarkdownUTF16Count = nil
        stagedRenderedDisplayBoundary = nil
        stagedRenderGeneration = nil
        stagedReferenceDefinitions = nil
        stagedReferenceDefinitionsGeneration = nil
        resetStagedContextBoundaryCache()
        resetAdaptiveStagedPromotionBudget()
        headingOutlineRefreshWorkItem?.cancel()
        headingOutlineRefreshWorkItem = nil
    }

    private func finalizeStagedPromotionCompletion(markFullDocumentFidelityReady: Bool = true) {
        let shouldRunDeferredSyntaxHighlightPass = stagedDeferredSyntaxHighlightingEnabled
        if markFullDocumentFidelityReady {
            WowInternalMetricsRecorder.shared.endFullDocumentFidelityReady()
        }
        stagedPromotionWorkItem?.cancel()
        stagedPromotionWorkItem = nil
        stagedPromotionLayoutWorkItem?.cancel()
        stagedPromotionLayoutWorkItem = nil
        stagedPromotionComputeTask?.cancel()
        stagedPromotionComputeTask = nil
        stagedPromotionToken &+= 1
        stagedPromotionInFlight = false
        stagedPromotionInFlightToken = nil
        stagedPromotionInFlightStartedAtUptime = nil
        stagedRenderedMarkdownUTF16Count = nil
        stagedRenderedDisplayBoundary = nil
        stagedRenderGeneration = nil
        stagedReferenceDefinitions = nil
        stagedReferenceDefinitionsGeneration = nil
        stagedPromotionsAllowed = false
        resetStagedContextBoundaryCache()
        resetAdaptiveStagedPromotionBudget()

        if shouldRunDeferredSyntaxHighlightPass {
            enqueueDeferredSyntaxHighlightJobsForWholeDocumentIfNeeded()
            scheduleDeferredSyntaxHighlightPassIfNeeded(delayMs: 80)
        }
        scheduleHeadingOutlineRefresh()
    }

    private func rescheduleStagedPromotionAfterNoProgress() {
        guard stagedPromotionsAllowed else { return }
        scheduleStagedPromotionFollowupIfNeeded()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isApplyingExternalUpdate else {
            pendingEditMutation = nil
            return true
        }
        let replacement = replacementString ?? ""
        pendingEditMutation = PendingEditMutation(
            range: affectedCharRange,
            replacementUTF16Count: replacement.utf16.count,
            replacementContainsLineBreak: replacement.contains(where: \.isNewline),
            replacementLikelyMarkdownSyntax: replacementLikelyContainsMarkdownSyntax(replacement)
        )
        if var active = activeHybridInlineExpansion {
            let delta = replacement.utf16.count - affectedCharRange.length
            let editStart = affectedCharRange.location
            let editEnd = affectedCharRange.location + affectedCharRange.length
            let activeStart = active.sourceRange.location
            let activeEnd = active.sourceRange.location + active.sourceRange.length

            if editEnd <= activeStart {
                active.sourceRange.location = max(0, active.sourceRange.location + delta)
                activeHybridInlineExpansion = active
            } else {
                let overlapsRange = editStart < activeEnd && editEnd > activeStart
                let insertionWithinRange = affectedCharRange.length == 0 && editStart >= activeStart && editStart <= activeEnd
                if overlapsRange || insertionWithinRange {
                    active.sourceRange.length = max(0, active.sourceRange.length + delta)
                    activeHybridInlineExpansion = active
                }
            }
        }

        if !replacement.isEmpty {
            WowInternalMetricsRecorder.shared.beginEditApply()
            if !syntaxVisibilityMode.isSyntaxVisible {
                sanitizeTypingAttributesForInsertion(at: affectedCharRange.location)
            }
        }

        guard let storage = textView.textStorage, storage.length > 0 else { return true }

        if syntaxVisibilityMode.isSyntaxVisible {
            return true
        }

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
            if rangeTouchesProtectedMarkerGlyphs(storage: storage, range: affectedCharRange) {
                pendingEditMutation = nil
                return false
            }
        }

        if affectedCharRange.length == 0,
           !replacement.isEmpty,
           let markerLocation = markerRegionInsertionLocation(in: storage, at: affectedCharRange.location) {
            scheduleMarkerRegionInsertionRecovery(replacement: replacement, markerLocation: markerLocation)
            pendingEditMutation = nil
            return false
        }

        if affectedCharRange.length == 0,
           !replacement.isEmpty,
           handleListBodyShortcutSwitchIfNeeded(
               storage: storage,
               affectedCharRange: affectedCharRange,
               replacement: replacement
           ) {
            pendingEditMutation = nil
            return false
        }

        if affectedCharRange.length == 0,
           !replacement.isEmpty,
           handleOrderedListShortcutSwitchToBulletIfNeeded(
               storage: storage,
               affectedCharRange: affectedCharRange,
               replacement: replacement
           ) {
            pendingEditMutation = nil
            return false
        }

        return true
    }

    private func handleListBodyShortcutSwitchIfNeeded(
        storage: NSTextStorage,
        affectedCharRange: NSRange,
        replacement: String
    ) -> Bool {
        guard let shortcut = typedListBodyShortcutPrefix(from: replacement) else { return false }
        guard storage.length > 0 else { return false }

        let ns = storage.string as NSString
        let probe = min(max(0, affectedCharRange.location), max(0, storage.length - 1))
        let paraRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard paraRange.location < storage.length else { return false }

        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length > 0 else { return false }
        let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)
        guard kind == .ordered || kind == .bullet || kind == .task else { return false }

        let markerLen = markerPrefixLength(in: storage, contentRange: contentRange)
        guard markerLen > 0 else { return false }
        let contentStart = contentRange.location + markerLen
        guard affectedCharRange.location == contentStart else { return false }

        let bodyRange = NSRange(
            location: contentStart,
            length: max(0, (contentRange.location + contentRange.length) - contentStart)
        )
        let body = bodyRange.length > 0 ? storage.attributedSubstring(from: bodyRange).string : ""

        let switchedBody: String?
        switch (kind, shortcut.kind) {
        case (.ordered, .bullet), (.ordered, .task):
            switchedBody = shortcut.prefix + body
        case (.bullet, .ordered), (.task, .ordered):
            switchedBody = shortcut.prefix + body
        default:
            switchedBody = nil
        }
        guard let switchedBody else { return false }

        let indent = max(
            0,
            (storage.attribute(.kernListIndent, at: paraRange.location, effectiveRange: nil) as? Int) ?? 0
        )
        let replacementMarkdown: String
        if paraRange.length > contentRange.length {
            replacementMarkdown = String(repeating: " ", count: indent) + switchedBody + "\n"
        } else {
            replacementMarkdown = String(repeating: " ", count: indent) + switchedBody
        }

        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        let imported = NativeMarkdownCodec.importMarkdown(replacementMarkdown, options: options)

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: paraRange, with: imported)
        let newMarkerLen = markerPrefixLength(in: imported)
        let newCaret = min(storage.length, paraRange.location + max(0, newMarkerLen))
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
        textView.didChangeText()
        return true
    }

    private enum TypedListShortcutKind {
        case bullet
        case ordered
        case task
    }

    private struct TypedListBodyShortcut {
        let kind: TypedListShortcutKind
        let prefix: String
    }

    private func typedListBodyShortcutPrefix(from replacement: String) -> TypedListBodyShortcut? {
        switch replacement {
        case "- ", "* ", "+ ":
            return TypedListBodyShortcut(kind: .bullet, prefix: replacement)
        case "- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ", "+ [ ] ", "+ [x] ", "+ [X] ":
            return TypedListBodyShortcut(kind: .task, prefix: replacement)
        case "1. ", "1. [ ] ", "1. [x] ", "1. [X] ":
            return TypedListBodyShortcut(kind: .ordered, prefix: replacement)
        default:
            return nil
        }
    }

    private func handleOrderedListShortcutSwitchToBulletIfNeeded(
        storage: NSTextStorage,
        affectedCharRange: NSRange,
        replacement: String
    ) -> Bool {
        guard storage.length > 0 else { return false }

        let ns = storage.string as NSString
        let probe = min(max(0, affectedCharRange.location), max(0, storage.length - 1))
        let paraRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard paraRange.location < storage.length else { return false }

        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length > 0 else { return false }
        let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)
        guard kind == .ordered else { return false }

        let markerLen = markerPrefixLength(in: storage, contentRange: contentRange)
        guard markerLen > 0 else { return false }

        let contentStart = contentRange.location + markerLen
        let bodyRange = NSRange(
            location: contentStart,
            length: max(0, (contentRange.location + contentRange.length) - contentStart)
        )
        let body = bodyRange.length > 0 ? storage.attributedSubstring(from: bodyRange).string : ""

        let switchedBody: String?
        if replacement == "- ", affectedCharRange.location == contentStart {
            switchedBody = "- " + body
        } else if replacement == " ", affectedCharRange.location == contentStart + 1, body.hasPrefix("-") {
            switchedBody = "- " + String(body.dropFirst())
        } else {
            switchedBody = nil
        }
        guard let switchedBody else { return false }

        let indent = max(
            0,
            (storage.attribute(.kernListIndent, at: paraRange.location, effectiveRange: nil) as? Int) ?? 0
        )
        let replacementMarkdown: String
        if paraRange.length > contentRange.length {
            replacementMarkdown = String(repeating: " ", count: indent) + switchedBody + "\n"
        } else {
            replacementMarkdown = String(repeating: " ", count: indent) + switchedBody
        }

        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        let imported = NativeMarkdownCodec.importMarkdown(replacementMarkdown, options: options)

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: paraRange, with: imported)
        let newMarkerLen = markerPrefixLength(in: imported)
        let newCaret = min(storage.length, paraRange.location + max(0, newMarkerLen))
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
        textView.didChangeText()
        return true
    }

    private func markerRegionInsertionLocation(in storage: NSTextStorage, at insertionLocation: Int) -> Int? {
        guard storage.length > 0 else { return nil }
        guard insertionLocation >= 0, insertionLocation <= storage.length else { return nil }

        let probe = min(max(0, insertionLocation), max(0, storage.length - 1))
        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard paraRange.location < storage.length else { return nil }

        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)
        guard kind == .bullet || kind == .task || kind == .ordered else { return nil }
        guard contentRange.location <= insertionLocation else { return nil }
        guard contentRange.location < storage.length else { return nil }

        let markerLen = markerPrefixLength(in: storage, contentRange: contentRange)
        guard markerLen > 0 else { return nil }

        let contentStart = min(storage.length, contentRange.location + markerLen)
        guard insertionLocation < contentStart else { return nil }
        return probe
    }

    private func rangeTouchesProtectedMarkerGlyphs(storage: NSTextStorage, range: NSRange) -> Bool {
        guard range.length > 0, storage.length > 0 else { return false }
        let start = max(0, min(range.location, storage.length))
        let end = max(start, min(storage.length, range.location + range.length))
        guard end > start else { return false }

        var idx = start
        while idx < end {
            var effective = NSRange(location: idx, length: 0)
            let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: &effective) as? Bool) ?? false
            let isCheckbox = (storage.attribute(.kernCheckbox, at: idx, effectiveRange: nil) as? Bool) ?? false
            if isMarker || isCheckbox {
                return true
            }
            idx += max(1, effective.length)
        }
        return false
    }

    private func scheduleMarkerRegionInsertionRecovery(replacement: String, markerLocation: Int) {
        recoverInsertionFromListMarkerRegion(
            replacement: replacement,
            markerLocation: markerLocation
        )
    }

    private func recoverInsertionFromListMarkerRegion(replacement: String, markerLocation: Int) {
        guard let storage = textView.textStorage else { return }
        guard storage.length > 0 else { return }
        guard markerLocation < storage.length else { return }

        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: markerLocation, length: 0))
        guard paraRange.location < storage.length else { return }

        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)
        guard kind == .bullet || kind == .task || kind == .ordered else { return }
        let insertionTarget = recoveredListMarkerInsertionTarget(storage: storage, contentRange: contentRange)
        let attributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: insertionTarget)
        let attributed = NSAttributedString(string: replacement, attributes: attributes)

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: NSRange(location: insertionTarget, length: 0), with: attributed)
        let insertedRange = NSRange(location: insertionTarget, length: attributed.length)
        if insertedRange.length > 0, insertedRange.location + insertedRange.length <= storage.length {
            storage.removeAttribute(.kernMarker, range: insertedRange)
            storage.removeAttribute(.kernCheckbox, range: insertedRange)
            storage.removeAttribute(.kernCheckboxChecked, range: insertedRange)
        }
        textView.setSelectedRange(
            NSRange(location: min(max(0, insertionTarget + attributed.length), storage.length), length: 0)
        )
        textView.didChangeText()
    }

    private func recoveredListMarkerInsertionTarget(storage: NSTextStorage, contentRange: NSRange) -> Int {
        let markerLenByAttributes = markerPrefixLength(in: storage, contentRange: contentRange)
        if markerLenByAttributes > 0 {
            return min(storage.length, contentRange.location + markerLenByAttributes)
        }

        let line = contentRange.length > 0 ? storage.attributedSubstring(from: contentRange).string : ""
        if let fallbackPrefix = plainMarkdownListPrefix(in: line) {
            return min(storage.length, contentRange.location + fallbackPrefix.prefixLength)
        }
        return min(storage.length, contentRange.location)
    }

    private func sanitizedMarkerRecoveryAttributes(
        storage: NSTextStorage,
        insertionTarget: Int
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any]
        if insertionTarget < storage.length {
            attrs = storage.attributes(at: insertionTarget, effectiveRange: nil)
        } else if storage.length > 0 {
            attrs = storage.attributes(at: max(0, storage.length - 1), effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }

        let keysToRemove: [NSAttributedString.Key] = [
            .kernMarker,
            .kernCheckbox,
            .kernCheckboxChecked,
            .kernCodeLanguage,
            .kernCodeBlockID,
        ]
        for key in keysToRemove {
            attrs.removeValue(forKey: key)
        }

        if attrs[.paragraphStyle] == nil {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            attrs[.paragraphStyle] = style
        }
        if attrs[.font] == nil {
            attrs[.font] = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }
        if attrs[.foregroundColor] == nil {
            attrs[.foregroundColor] = NativeEditorAppearance.primaryTextColor()
        }
        return attrs
    }

    private func caretCarryLocationAfterSoftBreak(caret: Int, storage: NSTextStorage) -> Int {
        guard storage.length > 0 else { return 0 }
        let priorIndex = min(max(0, caret - 1), storage.length - 1)
        let ns = storage.string as NSString
        if ns.character(at: priorIndex) != 10 {
            return priorIndex
        }
        let fallback = max(0, priorIndex - 1)
        return min(fallback, storage.length - 1)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !isApplyingExternalUpdate {
            noteUserInteraction()
        }
        if isApplyingHybridInlineTransition {
            return
        }
        if !suppressHybridExpansionForCurrentRunLoop {
            maybeApplyHybridInlineExpansionForSelection()
        }
        sanitizeTypingAttributesAfterLinkBoundaryIfNeeded()
        updateSpellcheckBehaviorForSelection()
        updateCodeBlockChrome()
        maybeReapplyAnchorJumpIfNeeded()
    }

    private func maybeApplyHybridInlineExpansionForSelection() {
        if !syntaxVisibilityMode.isHybridCaretSyntaxMode {
            collapseHybridInlineExpansionIfNeeded()
            return
        }
        guard !isApplyingExternalUpdate else { return }
        guard let storage = textView.textStorage else { return }

        let selection = textView.selectedRange()
        guard selection.length == 0 else {
            collapseHybridInlineExpansionIfNeeded()
            return
        }

        let caret = min(max(0, selection.location), storage.length)
        if let active = activeHybridInlineExpansion {
            let end = active.sourceRange.location + active.sourceRange.length
            if caret >= active.sourceRange.location, caret <= end {
                return
            }
            collapseHybridInlineExpansionIfNeeded()
            return
        }

        guard let candidate = hybridInlineSpanCandidate(at: caret, storage: storage) else { return }
        expandHybridInlineSpan(candidate: candidate, storage: storage, caret: caret)
    }

    private func hybridInlineSpanCandidate(
        at caret: Int,
        storage: NSTextStorage
    ) -> HybridInlineSpanCandidate? {
        guard storage.length > 0 else { return nil }
        let probes = hybridProbeIndices(caret: caret, storageLength: storage.length)
        guard !probes.isEmpty else { return nil }

        // Links first: preserve full `[label](destination)` source round-trip while editing.
        if let link = hybridInlineLinkCandidate(probes: probes, storage: storage),
           isEligibleHybridInlineRange(link.range, storage: storage) {
            let label = (storage.string as NSString).substring(with: link.range)
            let source = "[\(label)](\(link.destination))"
            return HybridInlineSpanCandidate(
                range: link.range,
                source: source,
                prefixUTF16Count: 1
            )
        }

        // Inline code before other style spans.
        for probe in probes {
            guard let range = effectiveTrueRange(for: .kernInlineCode, at: probe, storage: storage),
                  isEligibleHybridInlineRange(range, storage: storage) else { continue }
            let body = (storage.string as NSString).substring(with: range)
            let fence = inlineCodeFence(for: body)
            let source = "\(fence)\(body)\(fence)"
            return HybridInlineSpanCandidate(
                range: range,
                source: source,
                prefixUTF16Count: (fence as NSString).length
            )
        }

        // Strikethrough.
        for probe in probes {
            guard let range = effectiveTrueRange(for: .kernStrikethrough, at: probe, storage: storage),
                  isEligibleHybridInlineRange(range, storage: storage) else { continue }
            let body = (storage.string as NSString).substring(with: range)
            return HybridInlineSpanCandidate(
                range: range,
                source: "~~\(body)~~",
                prefixUTF16Count: 2
            )
        }

        // Strong+emphasis combination.
        for probe in probes {
            guard let strong = effectiveTrueRange(for: .kernStrong, at: probe, storage: storage),
                  let emphasis = effectiveTrueRange(for: .kernEmphasis, at: probe, storage: storage) else { continue }
            let intersection = NSIntersectionRange(strong, emphasis)
            guard intersection.length > 0,
                  probe >= intersection.location,
                  probe < intersection.location + intersection.length,
                  isEligibleHybridInlineRange(intersection, storage: storage) else { continue }
            let body = (storage.string as NSString).substring(with: intersection)
            return HybridInlineSpanCandidate(
                range: intersection,
                source: "***\(body)***",
                prefixUTF16Count: 3
            )
        }

        // Strong-only.
        for probe in probes {
            guard let range = effectiveTrueRange(for: .kernStrong, at: probe, storage: storage),
                  isEligibleHybridInlineRange(range, storage: storage) else { continue }
            let body = (storage.string as NSString).substring(with: range)
            return HybridInlineSpanCandidate(
                range: range,
                source: "**\(body)**",
                prefixUTF16Count: 2
            )
        }

        // Emphasis-only.
        for probe in probes {
            guard let range = effectiveTrueRange(for: .kernEmphasis, at: probe, storage: storage),
                  isEligibleHybridInlineRange(range, storage: storage) else { continue }
            let body = (storage.string as NSString).substring(with: range)
            return HybridInlineSpanCandidate(
                range: range,
                source: "*\(body)*",
                prefixUTF16Count: 1
            )
        }

        return nil
    }

    private func hybridInlineLinkCandidate(
        probes: [Int],
        storage: NSTextStorage
    ) -> (range: NSRange, destination: String)? {
        for probe in probes where probe >= 0 && probe < storage.length {
            var range = NSRange(location: 0, length: 0)
            guard storage.attribute(.link, at: probe, effectiveRange: &range) != nil else { continue }
            guard isEligibleHybridInlineRange(range, storage: storage) else { continue }

            let autolink = (storage.attribute(.kernAutolink, at: range.location, effectiveRange: nil) as? Bool) ?? false
            if autolink { continue }

            if let destination = storage.attribute(.kernLinkDestination, at: range.location, effectiveRange: nil) as? String,
               !destination.isEmpty {
                return (range, destination)
            }
            if let url = storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL {
                return (range, url.absoluteString)
            }
            if let urlString = storage.attribute(.link, at: range.location, effectiveRange: nil) as? String,
               !urlString.isEmpty {
                return (range, urlString)
            }
        }
        return nil
    }

    private func effectiveTrueRange(
        for key: NSAttributedString.Key,
        at probe: Int,
        storage: NSTextStorage
    ) -> NSRange? {
        guard probe >= 0, probe < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        let value = (storage.attribute(key, at: probe, effectiveRange: &range) as? Bool) ?? false
        guard value, isEligibleHybridInlineRange(range, storage: storage) else { return nil }
        return range
    }

    private func hybridProbeIndices(caret: Int, storageLength: Int) -> [Int] {
        guard storageLength > 0 else { return [] }
        var probes: [Int] = []
        if caret > 0, caret < storageLength {
            probes.append(caret)
            probes.append(caret - 1)
        } else if caret > 0 {
            probes.append(caret - 1)
        } else {
            probes.append(caret)
        }
        var deduped: [Int] = []
        var seen = Set<Int>()
        for probe in probes where probe >= 0 && probe < storageLength {
            if !seen.contains(probe) {
                deduped.append(probe)
                seen.insert(probe)
            }
        }
        return deduped
    }

    private func isEligibleHybridInlineRange(_ range: NSRange, storage: NSTextStorage) -> Bool {
        guard range.location != NSNotFound else { return false }
        guard range.location >= 0, range.length > 0 else { return false }
        guard range.location < storage.length else { return false }
        guard range.length <= storage.length - range.location else { return false }
        let text = (storage.string as NSString).substring(with: range)
        if text.contains("\n") || text.contains("\r") {
            return false
        }
        return true
    }

    private func inlineCodeFence(for body: String) -> String {
        var maxRun = 0
        var current = 0
        for scalar in body.unicodeScalars {
            if scalar == "`" {
                current += 1
                maxRun = max(maxRun, current)
            } else {
                current = 0
            }
        }
        let count = max(1, maxRun + 1)
        return String(repeating: "`", count: count)
    }

    private func expandHybridInlineSpan(
        candidate: HybridInlineSpanCandidate,
        storage: NSTextStorage,
        caret: Int
    ) {
        let targetRange = candidate.range
        guard isEligibleHybridInlineRange(targetRange, storage: storage) else { return }
        let sourceLength = (candidate.source as NSString).length
        guard sourceLength > 0 else { return }

        let oldCaretOffset = min(max(0, caret - targetRange.location), targetRange.length)
        let isAtTrailingBoundary = caret >= targetRange.location + targetRange.length
        let newCaret: Int
        if isAtTrailingBoundary {
            newCaret = targetRange.location + sourceLength
        } else {
            newCaret = targetRange.location + candidate.prefixUTF16Count + oldCaretOffset
        }

        let baseAttrsRaw = storage.attributes(at: targetRange.location, effectiveRange: nil)
        var baseAttrs = baseAttrsRaw
        let strippedKeys: [NSAttributedString.Key] = [
            .link,
            .kernLinkDestination,
            .kernAutolink,
            .kernLinkTitle,
            .kernLinkReferenceID,
            .kernLinkReferenceURL,
            .kernStrong,
            .kernEmphasis,
            .kernInlineCode,
            .kernStrikethrough,
            .underlineStyle,
            .strikethroughStyle,
            .strikethroughColor,
            .obliqueness,
            .kernHybridExpandedInlineLink,
            .kernHybridExpandedInlineSyntax,
        ]
        for key in strippedKeys {
            baseAttrs.removeValue(forKey: key)
        }
        baseAttrs[.foregroundColor] = NativeEditorAppearance.primaryTextColor()

        let replacement = NSMutableAttributedString(string: candidate.source, attributes: baseAttrs)
        replacement.addAttribute(.kernHybridExpandedInlineLink, value: true, range: NSRange(location: 0, length: sourceLength))
        replacement.addAttribute(.kernHybridExpandedInlineSyntax, value: true, range: NSRange(location: 0, length: sourceLength))

        isApplyingExternalUpdate = true
        isApplyingHybridInlineTransition = true
        storage.beginEditing()
        storage.replaceCharacters(in: targetRange, with: replacement)
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: min(storage.length, newCaret), length: 0))
        isApplyingHybridInlineTransition = false
        isApplyingExternalUpdate = false

        activeHybridInlineExpansion = HybridInlineExpansionState(
            sourceRange: NSRange(location: targetRange.location, length: sourceLength)
        )
    }

    private func collapseHybridInlineExpansionIfNeeded() {
        guard let active = activeHybridInlineExpansion else { return }
        activeHybridInlineExpansion = nil
        guard syntaxVisibilityMode.isHybridCaretSyntaxMode else { return }
        guard let storage = textView.textStorage else {
            collapseHybridInlineExpansionByRerendering()
            return
        }

        let sourceRange = active.sourceRange
        let end = sourceRange.location + sourceRange.length
        guard sourceRange.location >= 0,
              sourceRange.length > 0,
              sourceRange.location <= storage.length,
              end <= storage.length else {
            collapseHybridInlineExpansionByRerendering()
            return
        }

        let selectionBefore = textView.selectedRange()
        let scrollOriginBefore = scrollView.contentView.bounds.origin
        let sourceMarkdown = (storage.string as NSString).substring(with: sourceRange)
        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        var imported = NativeMarkdownCodec.importMarkdown(sourceMarkdown, options: options, baseURL: documentURL)
        while imported.length > 0, imported.string.hasSuffix("\n") {
            imported = NSAttributedString(
                attributedString: imported.attributedSubstring(from: NSRange(location: 0, length: imported.length - 1))
            )
        }

        let replacementLength = imported.length
        let delta = replacementLength - sourceRange.length
        let newCaret: Int = {
            let caret = selectionBefore.location
            if caret <= sourceRange.location {
                return caret
            }
            if caret >= end {
                return max(0, caret + delta)
            }
            let offset = caret - sourceRange.location
            return sourceRange.location + min(offset, replacementLength)
        }()

        isApplyingExternalUpdate = true
        isApplyingHybridInlineTransition = true
        storage.beginEditing()
        storage.replaceCharacters(in: sourceRange, with: imported)
        storage.endEditing()
        let safeLoc = min(max(0, newCaret), storage.length)
        textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
        scrollView.contentView.scroll(to: scrollOriginBefore)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingHybridInlineTransition = false
        isApplyingExternalUpdate = false
    }

    private func collapseHybridInlineExpansionByRerendering() {
        let selectionBefore = textView.selectedRange()
        let scrollOriginBefore = scrollView.contentView.bounds.origin
        let markdown = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())

        isApplyingExternalUpdate = true
        isApplyingHybridInlineTransition = true
        syncStringValueWithoutRender(markdown)
        renderMarkdown(markdown, preserveSelection: true)
        let maxLocation = max(0, textView.string.utf16.count)
        let safeLoc = min(max(0, selectionBefore.location), maxLocation)
        textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
        scrollView.contentView.scroll(to: scrollOriginBefore)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isApplyingHybridInlineTransition = false
        isApplyingExternalUpdate = false
    }

    private func updateSpellcheckBehaviorForSelection() {
        guard let storage = textView.textStorage, storage.length > 0 else {
            if spellingSuppressedForCodeBlock {
                spellingSuppressedForCodeBlock = false
                textView.isAutomaticSpellingCorrectionEnabled = true
                textView.isContinuousSpellCheckingEnabled = true
            }
            return
        }

        let selection = textView.selectedRange()
        let probe = min(max(0, selection.location), max(0, storage.length - 1))
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard para.location < storage.length else { return }
        let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        let shouldSuppress = kind == .codeBlock
        guard shouldSuppress != spellingSuppressedForCodeBlock else { return }

        spellingSuppressedForCodeBlock = shouldSuppress
        textView.isAutomaticSpellingCorrectionEnabled = !shouldSuppress
        textView.isContinuousSpellCheckingEnabled = !shouldSuppress
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
        if syntaxVisibilityMode.isSyntaxVisible {
            return false
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            return handleBackspaceAtListStartIfNeeded()
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) ||
            commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:)) {
            if handleTableCellNavigationCommand(outdent: false) {
                return true
            }
            return handleListIndentCommand(outdent: false)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            if handleTableCellNavigationCommand(outdent: true) {
                return true
            }
            return handleListIndentCommand(outdent: true)
        }
        return false
    }

    private struct TableCellCursor {
        let tableID: Int
        let row: Int
        let col: Int
        let colCount: Int
        let paragraphRange: NSRange
        let contentRange: NSRange
    }

    private func handleTableCellNavigationCommand(outdent: Bool) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return false }

        guard let current = currentTableCellCursor(storage: storage, ns: ns, selection: selection) else {
            return false
        }

        if outdent {
            if current.col > 0 {
                return moveCaretToTableCell(storage: storage, ns: ns, tableID: current.tableID, row: current.row, col: current.col - 1)
            }
            if current.row > 0, current.colCount > 0 {
                return moveCaretToTableCell(
                    storage: storage,
                    ns: ns,
                    tableID: current.tableID,
                    row: current.row - 1,
                    col: current.colCount - 1
                )
            }
            return false
        }

        if current.col + 1 < current.colCount {
            return moveCaretToTableCell(storage: storage, ns: ns, tableID: current.tableID, row: current.row, col: current.col + 1)
        }

        if moveCaretToTableCell(storage: storage, ns: ns, tableID: current.tableID, row: current.row + 1, col: 0) {
            return true
        }

        return appendTableRowAndMoveCaret(storage: storage, ns: ns, current: current)
    }

    private func currentTableCellCursor(storage: NSTextStorage, ns: NSString, selection: NSRange) -> TableCellCursor? {
        let caret = min(max(0, selection.location), ns.length)
        var probes: [Int] = []
        if caret < ns.length { probes.append(caret) }
        if caret > 0 { probes.append(caret - 1) }

        for probe in probes {
            let para = ns.paragraphRange(for: NSRange(location: probe, length: 0))
            guard para.location < storage.length else { continue }
            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            guard kind == .tableCell else { continue }

            let tableID = (storage.attribute(.kernTableID, at: para.location, effectiveRange: nil) as? Int) ?? -1
            let row = (storage.attribute(.kernTableRow, at: para.location, effectiveRange: nil) as? Int) ?? 0
            let col = (storage.attribute(.kernTableColumn, at: para.location, effectiveRange: nil) as? Int) ?? 0
            let colCount = max(1, (storage.attribute(.kernTableColumnCount, at: para.location, effectiveRange: nil) as? Int) ?? 1)
            let contentRange = paragraphContentRange(ns: ns, paraRange: para)
            return TableCellCursor(
                tableID: tableID,
                row: row,
                col: col,
                colCount: colCount,
                paragraphRange: para,
                contentRange: contentRange
            )
        }

        return nil
    }

    private func moveCaretToTableCell(
        storage: NSTextStorage,
        ns: NSString,
        tableID: Int,
        row: Int,
        col: Int
    ) -> Bool {
        guard let targetContent = tableCellContentRange(storage: storage, ns: ns, tableID: tableID, row: row, col: col) else {
            return false
        }
        let destination = min(storage.length, max(targetContent.location, targetContent.location))
        textView.setSelectedRange(NSRange(location: destination, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: destination)
        return true
    }

    private func tableCellContentRange(
        storage: NSTextStorage,
        ns: NSString,
        tableID: Int,
        row: Int,
        col: Int
    ) -> NSRange? {
        var idx = 0
        while idx < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard para.location < storage.length else { break }
            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .tableCell {
                let pid = (storage.attribute(.kernTableID, at: para.location, effectiveRange: nil) as? Int) ?? -1
                let prow = (storage.attribute(.kernTableRow, at: para.location, effectiveRange: nil) as? Int) ?? 0
                let pcol = (storage.attribute(.kernTableColumn, at: para.location, effectiveRange: nil) as? Int) ?? 0
                if pid == tableID, prow == row, pcol == col {
                    return paragraphContentRange(ns: ns, paraRange: para)
                }
            }
            idx = para.location + para.length
        }
        return nil
    }

    private func appendTableRowAndMoveCaret(storage: NSTextStorage, ns: NSString, current: TableCellCursor) -> Bool {
        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        let tableRange = tableBlockRange(ns: ns, storage: storage, seedParagraph: current.paragraphRange, tableID: current.tableID)
        guard tableRange.length > 0 else { return false }

        let tableAttr = storage.attributedSubstring(from: tableRange)
        var exported = NativeMarkdownCodec.exportMarkdown(tableAttr, options: options)
        while exported.hasSuffix("\n") {
            exported.removeLast()
        }

        let emptyCells = Array(repeating: " ", count: max(1, current.colCount)).joined(separator: " | ")
        let appended = exported + "\n| " + emptyCells + " |\n"
        let imported = NativeMarkdownCodec.importMarkdown(appended, options: options)

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: tableRange, with: imported)

        let updatedNS = storage.string as NSString
        let insertedRange = NSRange(location: tableRange.location, length: imported.length)
        if let target = firstTableCellContentRange(in: insertedRange, storage: storage, ns: updatedNS, row: current.row + 1, col: 0) {
            let destination = min(storage.length, max(target.location, 0))
            textView.setSelectedRange(NSRange(location: destination, length: 0))
            textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: destination)
        }
        textView.didChangeText()
        return true
    }

    private func tableBlockRange(ns: NSString, storage: NSTextStorage, seedParagraph: NSRange, tableID: Int) -> NSRange {
        var start = seedParagraph.location
        var end = seedParagraph.location + seedParagraph.length

        var cursor = seedParagraph.location
        while cursor > 0 {
            let prevPara = ns.paragraphRange(for: NSRange(location: max(0, cursor - 1), length: 0))
            guard prevPara.location < storage.length else { break }
            let kindRaw = storage.attribute(.kernBlockKind, at: prevPara.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            let pid = (storage.attribute(.kernTableID, at: prevPara.location, effectiveRange: nil) as? Int) ?? -1
            guard kind == .tableCell, pid == tableID else { break }
            start = prevPara.location
            cursor = prevPara.location
            if cursor == 0 { break }
        }

        cursor = seedParagraph.location + seedParagraph.length
        while cursor < ns.length {
            let nextPara = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard nextPara.location < storage.length else { break }
            let kindRaw = storage.attribute(.kernBlockKind, at: nextPara.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            let pid = (storage.attribute(.kernTableID, at: nextPara.location, effectiveRange: nil) as? Int) ?? -1
            guard kind == .tableCell, pid == tableID else { break }
            end = nextPara.location + nextPara.length
            cursor = nextPara.location + nextPara.length
        }

        return NSRange(location: start, length: max(0, end - start))
    }

    private func firstTableCellContentRange(
        in searchRange: NSRange,
        storage: NSTextStorage,
        ns: NSString,
        row: Int,
        col: Int
    ) -> NSRange? {
        let upperBound = searchRange.location + searchRange.length
        var cursor = searchRange.location
        while cursor < upperBound, cursor < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            if para.location >= upperBound { break }
            guard para.location < storage.length else { break }
            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .tableCell {
                let prow = (storage.attribute(.kernTableRow, at: para.location, effectiveRange: nil) as? Int) ?? 0
                let pcol = (storage.attribute(.kernTableColumn, at: para.location, effectiveRange: nil) as? Int) ?? 0
                if prow == row, pcol == col {
                    return paragraphContentRange(ns: ns, paraRange: para)
                }
            }
            cursor = para.location + para.length
        }
        return nil
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
        let rawString: String?
        if let u = link as? URL {
            url = u
            rawString = u.relativeString
        } else if let s = link as? String {
            url = URL(string: s)
            rawString = s
        } else {
            url = nil
            rawString = nil
        }
        guard let url else { return nil }
        let resolved = resolveExternalNavigableURL(url, rawString: rawString)
        guard let scheme = resolved.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "mailto", "file":
            return resolved
        default:
            return nil
        }
    }

    private func resolveExternalNavigableURL(_ url: URL, rawString: String?) -> URL {
        // Keep already absolute URLs untouched.
        if url.scheme != nil { return url }

        // Let anchor handling path consume pure fragment links.
        if url.path.isEmpty { return url }

        if let rawString,
           let webURL = normalizedBareWebURL(from: rawString) {
            return webURL
        }

        if url.path.hasPrefix("/") {
            var components = URLComponents(url: URL(fileURLWithPath: url.path).standardizedFileURL, resolvingAgainstBaseURL: false)
            components?.query = url.query
            components?.fragment = url.fragment
            return components?.url ?? URL(fileURLWithPath: url.path).standardizedFileURL
        }

        if url.path.hasPrefix("~/") {
            let home = NSHomeDirectory() as NSString
            let expanded = home.appendingPathComponent(String(url.path.dropFirst(2)))
            var components = URLComponents(url: URL(fileURLWithPath: expanded).standardizedFileURL, resolvingAgainstBaseURL: false)
            components?.query = url.query
            components?.fragment = url.fragment
            return components?.url ?? URL(fileURLWithPath: expanded).standardizedFileURL
        }

        if let docURL = documentURL {
            let baseDirectory = docURL.deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: url.path, relativeTo: baseDirectory).standardizedFileURL
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            components?.query = url.query
            components?.fragment = url.fragment
            return components?.url ?? resolved
        }

        // Last fallback when we only have a raw relative string.
        if let rawString,
           let parsed = URL(string: rawString),
           parsed.scheme == nil,
           parsed.path.hasPrefix("/") {
            return URL(fileURLWithPath: parsed.path).standardizedFileURL
        }

        return url
    }

    private func normalizedBareWebURL(from raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeBareWebDestination(value) else { return nil }
        guard !value.lowercased().hasPrefix("http://"), !value.lowercased().hasPrefix("https://") else { return nil }
        return URL(string: "https://\(value)")
    }

    private func looksLikeBareWebDestination(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        guard !raw.hasPrefix("#"),
              !raw.hasPrefix("/"),
              !raw.hasPrefix("./"),
              !raw.hasPrefix("../"),
              !raw.hasPrefix("~/") else {
            return false
        }
        guard !raw.contains(" ") else { return false }
        if raw.lowercased().hasPrefix("localhost") {
            return true
        }

        let hostPort = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let host = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostPort
        guard !host.isEmpty else { return false }

        let octets = host.split(separator: ".")
        if octets.count == 4,
           octets.allSatisfy({ part in
               guard let n = Int(part), !part.isEmpty else { return false }
               return (0...255).contains(n)
           }) {
            return true
        }

        guard host.contains(".") else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return false }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private func sanitizeTypingAttributesForInsertion(at location: Int) {
        guard let storage = textView.textStorage else { return }
        let isInsideLinkBody = caretIsStrictlyInsideLinkBody(location: location, storage: storage)
        if !isInsideLinkBody {
            textView.typingAttributes = sanitizedTypingAttributesWithoutLinkLeak(
                at: location,
                storage: storage,
                fallback: textView.typingAttributes
            )
        }
    }

    private func sanitizeTypingAttributesAfterLinkBoundaryIfNeeded() {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }
        let caret = min(max(0, selection.location), storage.length)
        guard !caretIsStrictlyInsideLinkBody(location: caret, storage: storage) else { return }
        textView.typingAttributes = sanitizedTypingAttributesWithoutLinkLeak(
            at: caret,
            storage: storage,
            fallback: textView.typingAttributes
        )
    }

    private func sanitizedTypingAttributesWithoutLinkLeak(
        at location: Int,
        storage: NSTextStorage,
        fallback: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any]
        if location > 0, location - 1 < storage.length {
            attrs = storage.attributes(at: location - 1, effectiveRange: nil)
        } else if location < storage.length {
            attrs = storage.attributes(at: location, effectiveRange: nil)
        } else {
            attrs = fallback
        }

        let linkKeys: [NSAttributedString.Key] = [
            .link,
            .kernLinkDestination,
            .kernAutolink,
            .kernLinkTitle,
            .kernLinkReferenceID,
            .kernLinkReferenceURL,
        ]
        var removedLinkSemanticKeys = false
        for key in linkKeys where attrs[key] != nil {
            attrs.removeValue(forKey: key)
            removedLinkSemanticKeys = true
        }

        let markerKeys: [NSAttributedString.Key] = [
            .kernMarker,
            .kernCheckbox,
            .kernCheckboxChecked,
        ]
        for key in markerKeys where attrs[key] != nil {
            attrs.removeValue(forKey: key)
        }

        if let underline = attrs[.underlineStyle] as? Int,
           underline == NSUnderlineStyle.single.rawValue {
            attrs.removeValue(forKey: .underlineStyle)
        }
        if removedLinkSemanticKeys {
            attrs[.foregroundColor] = NativeEditorAppearance.primaryTextColor()
        }
        return attrs
    }

    private func caretIsStrictlyInsideLinkBody(location: Int, storage: NSTextStorage) -> Bool {
        guard storage.length > 0 else { return false }
        let safeLocation = min(max(0, location), storage.length)

        if safeLocation < storage.length,
           storage.attribute(.link, at: safeLocation, effectiveRange: nil) != nil {
            var range = NSRange(location: 0, length: 0)
            _ = storage.attribute(.link, at: safeLocation, effectiveRange: &range)
            return range.location < safeLocation && safeLocation < range.location + range.length
        }

        guard safeLocation > 0 else { return false }
        let previous = safeLocation - 1
        guard storage.attribute(.link, at: previous, effectiveRange: nil) != nil else { return false }
        var range = NSRange(location: 0, length: 0)
        _ = storage.attribute(.link, at: previous, effectiveRange: &range)
        return range.location < safeLocation && safeLocation < range.location + range.length
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
        pendingAnchorJumpGuardWorkItem?.cancel()

        // Guard against NSTextView internal selection/scroll behaviors that can snap the viewport back
        // to the clicked link shortly after we programmatically scroll to the destination.
        anchorJumpGuard = AnchorJumpGuard(
            anchor: anchor,
            linkCharIndex: linkCharIndex,
            targetParagraphLocation: nil,
            targetSelectionLocation: nil,
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
        scheduleAnchorJumpGuardHeartbeat(attempt: 0)
    }

    @MainActor
    func debugReapplyAnchorJumpGuardForTests() {
        maybeReapplyAnchorJumpIfNeeded()
    }

    private func maybeReapplyAnchorJumpIfNeeded() {
        guard var guardState = anchorJumpGuard else { return }

        let now = Date()
        if now >= guardState.expiresAt {
            anchorJumpGuard = nil
            pendingAnchorJumpGuardWorkItem?.cancel()
            pendingAnchorJumpGuardWorkItem = nil
            return
        }

        let sel = textView.selectedRange()
        let selLen = max(sel.length, 1) // treat a caret as a 1-char range for containment checks
        let containsByRange = sel.location <= guardState.linkCharIndex && guardState.linkCharIndex < sel.location + selLen
        let containsByTolerance = abs(sel.location - guardState.linkCharIndex) <= 1
        let containsLinkIndex = containsByRange || containsByTolerance
        if guardState.remainingRejumps <= 0 {
            if containsLinkIndex {
                // Keep one emergency retry available for explicit link-selection snap-backs.
                guardState.remainingRejumps = 1
            } else {
                return
            }
        }

        guard let storage = textView.textStorage,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              storage.length > 0 else { return }

        let ns = storage.string as NSString
        let visible = textView.visibleRect

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

    private func scheduleAnchorJumpGuardHeartbeat(attempt: Int) {
        guard attempt < 80 else { return }
        guard anchorJumpGuard != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.maybeReapplyAnchorJumpIfNeeded()
            if self.anchorJumpGuard != nil {
                self.scheduleAnchorJumpGuardHeartbeat(attempt: attempt + 1)
            }
        }
        pendingAnchorJumpGuardWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func jumpToAnchor(_ slug: String) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let loc: Int
        if let guardState = anchorJumpGuard,
           guardState.anchor == slug,
           let stable = guardState.targetSelectionLocation,
           stable >= 0,
           stable <= storage.length {
            loc = stable
        } else {
            let index = HeadingAnchorIndex.make(from: storage)
            if let indexed = index[slug] {
                loc = indexed
            } else if let fallback = fallbackHeadingLocationForAnchor(slug: slug, in: storage.string) {
                loc = fallback
            } else {
                return false
            }
        }

        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: NSRange(location: loc, length: 0))

        if var guardState = anchorJumpGuard, guardState.anchor == slug {
            guardState.targetParagraphLocation = paraRange.location
            if guardState.targetSelectionLocation == nil || (guardState.targetSelectionLocation ?? 0) > storage.length {
                guardState.targetSelectionLocation = loc
            }
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

    private func fallbackHeadingLocationForAnchor(slug: String, in text: String) -> Int? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "^(?: {0,3})(#{1,6})[\\t ]+(.+?)\\s*$", options: []) else {
            return nil
        }

        var slugCounts: [String: Int] = [:]
        var idx = 0
        while idx < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            if paraRange.length == 0 { break }

            var contentLength = paraRange.length
            if contentLength > 0 {
                let last = paraRange.location + contentLength - 1
                if last < ns.length, ns.character(at: last) == 10 {
                    contentLength -= 1
                }
            }
            let contentRange = NSRange(location: paraRange.location, length: max(0, contentLength))
            if contentRange.length > 0 {
                let line = ns.substring(with: contentRange)
                let lineRange = NSRange(location: 0, length: (line as NSString).length)
                if let match = regex.firstMatch(in: line, options: [], range: lineRange),
                   match.numberOfRanges >= 3 {
                    let rawTitle = (line as NSString).substring(with: match.range(at: 2))
                    let title = rawTitle.replacingOccurrences(of: "\\s#+\\s*$", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let base = GFMHeadingSlugger.slug(title)
                    if !base.isEmpty {
                        let n = slugCounts[base] ?? 0
                        let candidate = (n == 0) ? base : "\(base)-\(n)"
                        slugCounts[base] = n + 1
                        if candidate == slug {
                            return contentRange.location + match.range(at: 2).location
                        }
                    }
                }
            }

            idx = paraRange.location + paraRange.length
        }
        return nil
    }

    private func scrollParagraphNearTop(_ paraRange: NSRange) {
        // Scroll so the destination heading lands near the top of the viewport (web/GitHub-style).
        // `scrollRangeToVisible` is "minimal scroll" and can result in no scroll when the target is already
        // visible, which feels unintuitive for table-of-contents navigation.
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            // TextKit can be lazy about layout for far-down content. Ensure the document view has
            // correct height + layout before we compute a rect to scroll to.
            adjustDocumentViewHeightToContent(forceFullLayout: true)

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
        hasUnexportedChanges = true

        if disablesDebouncedExportsForTesting {
            return
        }

        exportWorkItem?.cancel()
        exportWorkToken &+= 1
        let token = exportWorkToken

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard token == self.exportWorkToken else { return }
            let opt = NativeMarkdownCodec.Options.fromUserDefaults()
            if self.syntaxVisibilityMode.isSyntaxVisible {
                WowInternalMetricsRecorder.shared.beginSaveSerialize()
                let markdown = self.textView.string
                WowInternalMetricsRecorder.shared.endSaveSerialize()
                self.finalizeExport(markdown: markdown, options: opt)
                return
            }

            let snapshot = AttributedStringSendableBox(self.textView.attributedString())
            let queue = self.codecWorkQueue
            WowInternalMetricsRecorder.shared.beginSaveSerialize()
            queue.async { [weak self] in
                let markdown = NativeMarkdownCodec.exportMarkdown(snapshot.value, options: opt)
                DispatchQueue.main.async {
                    WowInternalMetricsRecorder.shared.endSaveSerialize()
                    guard let self else { return }
                    guard token == self.exportWorkToken else { return }
                    self.finalizeExport(markdown: markdown, options: opt)
                }
            }
        }

        exportWorkItem = workItem
        let delaySeconds = exportDebounceDelaySeconds()
        WowInternalMetricsRecorder.shared.recordMaxAuxMetric(
            "wow_export_debounce_delay_ms_max",
            candidate: delaySeconds * 1_000.0
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
    }

    private func finalizeExport(markdown: String, options: NativeMarkdownCodec.Options) {
        onContentChanged?(markdown)
        syncStringValueWithoutRender(markdown)
        hasUnexportedChanges = false
        if syntaxVisibilityMode.isSyntaxVisible {
            pendingStagedRecoveryAfterExport = false
            pendingRenderRefreshAfterExport = false
        } else {
            recoverRenderedStateAfterExportIfNeeded(markdown: markdown, options: options)
            resumeStagedPromotionAfterExportIfNeeded()
        }
    }

    private func exportDebounceDelaySeconds() -> TimeInterval {
        let textLength = textView.textStorage?.length ?? textView.string.utf16.count
        if textLength >= stagedOpenVeryLargeDocCharThreshold {
            // For very large files, serialization is expensive. Prioritize scroll/typing
            // smoothness and staged rendering progress; save path still force-flushes.
            if stagedPromotionsAllowed || stagedPromotionInFlight {
                return 1.6
            } else {
                return 0.9
            }
        }
        if textLength >= stagedOpenCharThreshold {
            return 0.35
        }
        return 0.15
    }

    /// Force an immediate export of the current editor state, cancelling any pending debounce.
    /// Used for correctness on explicit Save operations.
    func flushPendingExport() {
        guard hasUnexportedChanges else { return }

        exportWorkItem?.cancel()
        exportWorkItem = nil
        exportWorkToken &+= 1

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        WowInternalMetricsRecorder.shared.beginSaveSerialize()
        let markdown: String
        if syntaxVisibilityMode.isSyntaxVisible {
            markdown = textView.string
        } else {
            markdown = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: opt)
        }
        WowInternalMetricsRecorder.shared.endSaveSerialize()
        finalizeExport(markdown: markdown, options: opt)
    }

    private func syncStringValueWithoutRender(_ markdown: String) {
        isApplyingExternalUpdate = true
        stringValue = markdown
        isApplyingExternalUpdate = false
    }

    private func recoverRenderedStateAfterExportIfNeeded(
        markdown: String,
        options: NativeMarkdownCodec.Options
    ) {
        let shouldRecoverStaged = pendingStagedRecoveryAfterExport
        let shouldRefreshRenderedContent = pendingRenderRefreshAfterExport
        guard shouldRecoverStaged || shouldRefreshRenderedContent else { return }
        pendingStagedRecoveryAfterExport = false
        pendingRenderRefreshAfterExport = false

        guard shouldUseStagedOpen(for: markdown) else {
            let selection = textView.selectedRange()
            let scrollOrigin = scrollView.contentView.bounds.origin
            let previousRenderedUTF16Count = textView.string.utf16.count
            let full = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: documentURL)
            let forceFullLayout = markdown.utf16.count <= fullLayoutForceCharThreshold

            isApplyingExternalUpdate = true
            defer { isApplyingExternalUpdate = false }
            textView.textStorage?.setAttributedString(full)
            rebuildHeadingOutlineFromStorage()
            adjustDocumentViewHeightToContent(forceFullLayout: forceFullLayout)
            scheduleLargeDocumentLightLayoutIfNeeded(markdown: markdown)
            stagedRenderedMarkdownUTF16Count = nil
            stagedRenderedDisplayBoundary = nil
            stagedRenderGeneration = nil
            stagedReferenceDefinitions = nil
            stagedReferenceDefinitionsGeneration = nil
            stagedPromotionsAllowed = false
            resetStagedContextBoundaryCache()
            resetAdaptiveStagedPromotionBudget()
            resetDeferredSyntaxHighlightState()

            let maxLocation = max(0, textView.string.utf16.count)
            let safeLocation = min(selection.location, maxLocation)
            let safeLength = min(selection.length, max(0, maxLocation - safeLocation))
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            stabilizeUndoAfterExternalRenderRefresh(previousRenderedUTF16Count: previousRenderedUTF16Count)
            updateCodeBlockChrome()
            scheduleFindUpdate(resetIndex: false, anchorLocation: nil)
            return
        }

        let referenceDefinitions = NativeMarkdownCodec.collectReferenceDefinitions(in: markdown)
        let staged = makeStagedInitialAttributed(
            markdown: markdown,
            options: options,
            precomputedReferenceDefinitions: referenceDefinitions
        )
        let selection = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin
        let previousRenderedUTF16Count = textView.string.utf16.count

        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }
        textView.textStorage?.setAttributedString(staged.attributed)
        rebuildHeadingOutlineFromStorage()
        adjustDocumentViewHeightToContent(forceFullLayout: false)
        scheduleLargeDocumentLightLayoutIfNeeded(markdown: markdown)

        let maxLocation = max(0, textView.string.utf16.count)
        let safeLocation = min(selection.location, maxLocation)
        let safeLength = min(selection.length, max(0, maxLocation - safeLocation))
        textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        stabilizeUndoAfterExternalRenderRefresh(previousRenderedUTF16Count: previousRenderedUTF16Count)
        updateCodeBlockChrome()
        scheduleFindUpdate(resetIndex: false, anchorLocation: nil)

        stagedRenderedMarkdownUTF16Count = staged.renderedMarkdownUTF16Count
        stagedRenderedDisplayBoundary = staged.renderedDisplayBoundary
        stagedRenderGeneration = renderGeneration
        stagedReferenceDefinitions = referenceDefinitions
        stagedReferenceDefinitionsGeneration = renderGeneration
        stagedPromotionsAllowed = staged.renderedMarkdownUTF16Count < markdown.utf16.count
        guard stagedPromotionsAllowed else {
            finalizeStagedPromotionCompletion()
            return
        }
    }

    private func stabilizeUndoAfterExternalRenderRefresh(previousRenderedUTF16Count: Int) {
        let currentRenderedUTF16Count = textView.string.utf16.count
        guard currentRenderedUTF16Count != previousRenderedUTF16Count else { return }
        // A semantic re-import can shrink/grow visible text (e.g. markdown markers hidden).
        // Existing undo operations may reference pre-import ranges and become invalid.
        // Clearing stale undo entries prevents NSRangeException crashes on subsequent Cmd+Z.
        textView.undoManager?.removeAllActions()
    }

    private func resumeStagedPromotionAfterExportIfNeeded() {
        guard stagedPromotionsAllowed else { return }
        guard stagedRenderGeneration == renderGeneration else { return }
        guard deferredFullRenderWorkItem == nil else { return }
        guard !hasUnexportedChanges else { return }
        scheduleStagedPromotionFollowupIfNeeded()
    }

    /// Closing fast-path: drop non-critical deferred work to avoid shutdown lag on huge documents.
    func cancelDeferredWorkForClose() {
        WowInternalMetricsRecorder.shared.failFullDocumentFidelityIfMissing(
            reason: "cancelled_for_close"
        )
        deferredFullRenderWorkItem?.cancel()
        deferredFullRenderWorkItem = nil
        deferredFullRenderToken &+= 1
        largeDocumentLightLayoutWorkItem?.cancel()
        largeDocumentLightLayoutWorkItem = nil
        scrollChromeUpdateWorkItem?.cancel()
        scrollChromeUpdateWorkItem = nil
        stagedPromotionWorkItem?.cancel()
        stagedPromotionWorkItem = nil
        stagedPromotionLayoutWorkItem?.cancel()
        stagedPromotionLayoutWorkItem = nil
        stagedPromotionComputeTask?.cancel()
        stagedPromotionComputeTask = nil
        stagedPromotionToken &+= 1
        stagedPromotionInFlight = false
        stagedPromotionInFlightToken = nil
        stagedPromotionInFlightStartedAtUptime = nil
        stagedPromotionsAllowed = false
        stagedRenderedMarkdownUTF16Count = nil
        stagedRenderedDisplayBoundary = nil
        stagedRenderGeneration = nil
        stagedReferenceDefinitions = nil
        stagedReferenceDefinitionsGeneration = nil
        resetAdaptiveStagedPromotionBudget()
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
        let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)
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
                textView.undoManager?.beginUndoGrouping()
                defer { textView.undoManager?.endUndoGrouping() }

                let indent = (storage.attribute(.kernListIndent, at: contentRange.location, effectiveRange: nil) as? Int) ?? 0
                let box = shortcut.checked ? "x" : " "
                let mdLine = String(repeating: " ", count: max(0, indent)) + "- [\(box)] " + shortcut.text

                let imported = NativeMarkdownCodec.importMarkdown(mdLine, options: options)
                let delta = imported.length - contentRange.length
                storage.replaceCharacters(in: contentRange, with: imported)

                let newCaret = min(max(0, caret + delta), storage.length)
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
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
                textView.undoManager?.beginUndoGrouping()
                defer { textView.undoManager?.endUndoGrouping() }

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
                textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
                return
            }
        }

        if kind == .ordered,
           applyOrderedListBodyBulletShortcutSwitchIfNeeded(
               storage: storage,
               paragraphRange: paraRange,
               contentRange: contentRange,
               caret: caret,
               options: options
           ) {
            return
        }

        if (kind == .bullet || kind == .task || kind == .ordered),
           applyListMarkerShortcutWithinExistingList(
                storage: storage,
               paragraphRange: paraRange,
               contentRange: contentRange,
                paragraphLocation: paraRange.location,
                kind: kind,
                caret: caret,
                options: options
           ) {
            return
        }

        if applyInlineLinkInputRulesIfNeeded(
            storage: storage,
            contentRange: contentRange,
            visibleLine: line,
            kind: kind,
            caret: caret,
            options: options
        ) {
            return
        }

        // For already-semantic list/heading/code paragraphs, avoid re-importing the whole line on
        // every keystroke. Re-import here should only run for plain paragraph text that still
        // contains literal markdown syntax.
        guard kind == .paragraph else { return }

        guard shouldConvertTypedMarkdown(line) else { return }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

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
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)

        if let headingLevel {
            setHeadingTypingAttributes(level: headingLevel)
        }
    }

    private func applyInlineLinkInputRulesIfNeeded(
        storage: NSTextStorage,
        contentRange: NSRange,
        visibleLine: String,
        kind: KernBlockKind,
        caret: Int,
        options: NativeMarkdownCodec.Options
    ) -> Bool {
        guard shouldConvertTypedInlineLinkSyntax(visibleLine) else { return false }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        let imported: NSAttributedString
        if kind == .paragraph {
            imported = NativeMarkdownCodec.importMarkdown(visibleLine, options: options, baseURL: documentURL)
        } else {
            let paragraphAttr = storage.attributedSubstring(from: contentRange)
            var markdownLine = NativeMarkdownCodec.exportMarkdown(paragraphAttr, options: options)
            while markdownLine.hasSuffix("\n") {
                markdownLine.removeLast()
            }
            imported = NativeMarkdownCodec.importMarkdown(markdownLine, options: options, baseURL: documentURL)
        }

        let delta = imported.length - contentRange.length
        storage.replaceCharacters(in: contentRange, with: imported)
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
        return true
    }

    private func shouldConvertTypedInlineLinkSyntax(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }

        // Inline links: [label](dest) where `[` is not escaped.
        if line.range(
            of: #"(?<!\\)\[[^\]\n]+\]\((?:<[^>\n]+>|[^)\n]+)\)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Autolinks: <https://...> and <me@example.com>
        if line.range(of: #"<https?://[^>\s]+>"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(
            of: #"<[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        return false
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

        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length >= 0 else { return false }
        let line = contentRange.length > 0 ? storage.attributedSubstring(from: contentRange).string : ""

        let markerLenByAttributes = markerPrefixLength(in: storage, contentRange: contentRange)
        let fallbackPrefix = plainMarkdownListPrefix(in: line)
        let markerLen: Int
        if markerLenByAttributes > 0 {
            markerLen = markerLenByAttributes
        } else if let fallbackPrefix {
            markerLen = fallbackPrefix.prefixLength
        } else {
            return false
        }

        guard markerLen > 0 else { return false }

        let contentStart = contentRange.location + markerLen
        let semanticBodyStart = listBodyStartLocation(in: storage, contentRange: contentRange)
        guard caret == contentStart || caret == semanticBodyStart else { return false }

        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)
        let paragraphAttr = storage.attributedSubstring(from: contentRange)
        var markdownLine = NativeMarkdownCodec.exportMarkdown(paragraphAttr, options: options)
        while markdownLine.hasSuffix("\n") {
            markdownLine.removeLast()
        }
        let parsedKind = markdownListKind(in: markdownLine)
        let effectiveKind: KernBlockKind
        if kind == .bullet || kind == .task || kind == .ordered {
            effectiveKind = kind
        } else if let parsedKind {
            effectiveKind = parsedKind
        } else {
            effectiveKind = .paragraph
        }

        let attributedIndent = (storage.attribute(.kernListIndent, at: paraRange.location, effectiveRange: nil) as? Int) ?? 0
        let attributedDepth = (storage.attribute(.kernListDepth, at: paraRange.location, effectiveRange: nil) as? Int) ?? 0
        let indentStep = listIndentStep(for: effectiveKind)
        let syntheticIndent = max(attributedIndent, max(0, attributedDepth) * max(1, indentStep))
        if syntheticIndent > 0 {
            let parsedLeading = markdownLine.prefix { $0 == " " }.count
            if parsedLeading < syntheticIndent {
                markdownLine = String(repeating: " ", count: syntheticIndent - parsedLeading) + markdownLine
            }
        }
        let parsedIndent = markdownLine.prefix { $0 == " " }.count
        let listIndent = max(attributedIndent, parsedIndent)

        // Notion/ProseMirror-like behavior: Backspace at list item start should first lift/outdent
        // nested items before fully unlisting them.
        if listIndent > 0 || attributedDepth > 0,
           (effectiveKind == .bullet || effectiveKind == .task || effectiveKind == .ordered),
           let adjusted = adjustedListMarkdownLine(markdownLine, kind: effectiveKind, outdent: true),
           adjusted != markdownLine {
            let preferredBodyMarkdown = unlistedBodyMarkdown(from: adjusted, kind: effectiveKind)
            let imported = importListMarkdownContentWithContextIfNeeded(
                adjusted,
                kind: effectiveKind,
                options: options
            )

            isApplyingInputRules = true
            defer { isApplyingInputRules = false }
            textView.undoManager?.beginUndoGrouping()
            defer { textView.undoManager?.endUndoGrouping() }

            storage.replaceCharacters(in: contentRange, with: imported)
            let updatedNS = storage.string as NSString
            let updatedPara = updatedNS.paragraphRange(for: NSRange(location: min(contentRange.location, max(0, storage.length - 1)), length: 0))
            let updatedContentRange = paragraphContentRange(ns: updatedNS, paraRange: updatedPara)
            let bodyStart = listBodyStartLocation(
                in: storage,
                contentRange: updatedContentRange,
                preferredBodyMarkdown: preferredBodyMarkdown
            )
            let candidateCaret = min(storage.length, max(updatedContentRange.location, bodyStart))
            let newCaret = adjustedListInsertionCaret(
                storage: storage,
                contentRange: updatedContentRange,
                proposedLocation: candidateCaret
            )
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
            textView.didChangeText()
            return true
        }

        let bodyStart = max(contentRange.location, min(contentRange.location + contentRange.length, semanticBodyStart))
        let bodyRange = NSRange(
            location: bodyStart,
            length: max(0, (contentRange.location + contentRange.length) - bodyStart)
        )

        let replacement: NSAttributedString
        if markerLenByAttributes > 0, bodyRange.length > 0 {
            let body = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: bodyRange))
            clearBlockSemanticsKeepingInline(in: body)
            let bodyMarkdown = NativeMarkdownCodec.exportMarkdown(body, options: options)
            replacement = NativeMarkdownCodec.importMarkdown(bodyMarkdown, options: options)
        } else if bodyRange.length > 0 {
            let bodyMarkdown = storage.attributedSubstring(from: bodyRange).string
            replacement = NativeMarkdownCodec.importMarkdown(bodyMarkdown, options: options)
        } else {
            replacement = NSAttributedString()
        }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: contentRange, with: replacement)
        let updatedNS = storage.string as NSString
        let updatedPara = updatedNS.paragraphRange(for: NSRange(location: min(contentRange.location, max(0, storage.length - 1)), length: 0))
        let updatedContentRange = paragraphContentRange(ns: updatedNS, paraRange: updatedPara)
        let proposed = min(contentRange.location, storage.length)
        let safeCaret = adjustedListInsertionCaret(
            storage: storage,
            contentRange: updatedContentRange,
            proposedLocation: proposed
        )
        textView.setSelectedRange(NSRange(location: safeCaret, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: safeCaret)
        textView.didChangeText()
        return true
    }

    private func listBodyStartLocation(
        in storage: NSTextStorage,
        contentRange: NSRange,
        preferredBodyMarkdown: String? = nil
    ) -> Int {
        guard contentRange.length > 0 else { return contentRange.location }
        if let preferredBodyMarkdown,
           let preferredBodyStart = preferredRenderedBodyStartLocation(
               in: storage,
               contentRange: contentRange,
               preferredBodyMarkdown: preferredBodyMarkdown
           ) {
            return preferredBodyStart
        }
        let end = contentRange.location + contentRange.length
        let ns = storage.string as NSString
        var idx = contentRange.location
        var sawPrefixToken = false
        while idx < end {
            let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
            let isCheckbox = (storage.attribute(.kernCheckbox, at: idx, effectiveRange: nil) as? Bool) ?? false
            if isMarker || isCheckbox {
                sawPrefixToken = true
                idx += 1
                continue
            }
            if sawPrefixToken {
                let ch = ns.substring(with: NSRange(location: idx, length: 1))
                if ch == " " || ch == "\t" {
                    idx += 1
                    continue
                }
            }
            if !isMarker, !isCheckbox {
                break
            }
            idx += 1
        }
        return idx
    }

    private func preferredRenderedBodyStartLocation(
        in storage: NSTextStorage,
        contentRange: NSRange,
        preferredBodyMarkdown: String
    ) -> Int? {
        let preferredBody = preferredBodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredBody.isEmpty else { return nil }

        // Use the leading token as an anchor from markdown body -> rendered line.
        let token = preferredBody.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? preferredBody
        guard !token.isEmpty else { return nil }

        let renderedLine = storage.attributedSubstring(from: contentRange).string as NSString
        let tokenRange = renderedLine.range(of: token)
        guard tokenRange.location != NSNotFound else { return nil }
        return contentRange.location + tokenRange.location
    }

    private func adjustedListInsertionCaret(
        storage: NSTextStorage,
        contentRange: NSRange,
        proposedLocation: Int
    ) -> Int {
        guard contentRange.length > 0 else { return min(max(0, proposedLocation), storage.length) }
        let start = contentRange.location
        let end = contentRange.location + contentRange.length
        var idx = min(max(start, proposedLocation), end)
        let ns = storage.string as NSString

        while idx < end {
            let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
            let isCheckbox = (storage.attribute(.kernCheckbox, at: idx, effectiveRange: nil) as? Bool) ?? false
            if !(isMarker || isCheckbox) { break }
            idx += 1
        }
        while idx < end {
            let ch = ns.substring(with: NSRange(location: idx, length: 1))
            if ch == " " || ch == "\t" {
                idx += 1
                continue
            }
            break
        }

        return min(max(0, idx), storage.length)
    }

    private func applyOrderedListBodyBulletShortcutSwitchIfNeeded(
        storage: NSTextStorage,
        paragraphRange: NSRange,
        contentRange: NSRange,
        caret: Int,
        options: NativeMarkdownCodec.Options
    ) -> Bool {
        guard contentRange.length > 0 else { return false }

        let rawLine = storage.attributedSubstring(from: contentRange).string
        guard !rawLine.isEmpty else { return false }

        guard let converted = switchedMarkdownFromOrderedBodyBulletShortcut(rawLine) else { return false }
        let replacementMarkdown = paragraphRange.length > contentRange.length ? converted + "\n" : converted
        let imported = NativeMarkdownCodec.importMarkdown(replacementMarkdown, options: options)
        let delta = imported.length - paragraphRange.length

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: paragraphRange, with: imported)
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
        return true
    }

    private func applyListMarkerShortcutWithinExistingList(
        storage: NSTextStorage,
        paragraphRange: NSRange,
        contentRange: NSRange,
        paragraphLocation: Int,
        kind: KernBlockKind,
        caret: Int,
        options: NativeMarkdownCodec.Options
    ) -> Bool {
        guard contentRange.length > 0 else { return false }
        guard paragraphLocation < storage.length else { return false }
        guard kind == .bullet || kind == .task || kind == .ordered else { return false }

        let markerLenByAttributes = markerPrefixLength(in: storage, contentRange: contentRange)
        let bodyRange: NSRange
        if markerLenByAttributes > 0 {
            bodyRange = NSRange(
                location: contentRange.location + markerLenByAttributes,
                length: max(0, contentRange.length - markerLenByAttributes)
            )
        } else {
            bodyRange = contentRange
        }
        guard bodyRange.location >= contentRange.location else { return false }
        guard bodyRange.location + bodyRange.length <= contentRange.location + contentRange.length else { return false }

        let body = bodyRange.length > 0 ? storage.attributedSubstring(from: bodyRange).string : ""
        guard hasListMarkerShortcutPrefix(body) else { return false }

        let indent = max(
            0,
            (storage.attribute(.kernListIndent, at: paragraphLocation, effectiveRange: nil) as? Int) ?? 0
        )
        let markdownLine = String(repeating: " ", count: indent) + body
        let replacementMarkdown: String
        if paragraphRange.length > contentRange.length {
            replacementMarkdown = markdownLine + "\n"
        } else {
            replacementMarkdown = markdownLine
        }
        let imported = NativeMarkdownCodec.importMarkdown(replacementMarkdown, options: options)
        let delta = imported.length - paragraphRange.length

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        storage.replaceCharacters(in: paragraphRange, with: imported)
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
        return true
    }

    private struct ListIndentEdit {
        let range: NSRange
        let replacement: NSAttributedString
    }

    private func handleListIndentCommand(outdent: Bool) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        let ns = storage.string as NSString
        guard ns.length > 0 else { return false }

        let paragraphRanges = selectedParagraphRanges(ns: ns, selection: selection)
        guard !paragraphRanges.isEmpty else { return false }

        let options = NativeMarkdownCodec.Options.fromUserDefaults()
        var edits: [ListIndentEdit] = []
        edits.reserveCapacity(paragraphRanges.count)

        for paraRange in paragraphRanges {
            guard paraRange.location < storage.length else { continue }

            let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
            guard contentRange.length > 0 else { continue }
            let kind = effectiveBlockKind(in: storage, paraRange: paraRange, contentRange: contentRange)

            let paragraphAttr = storage.attributedSubstring(from: contentRange)
            var markdownLine = NativeMarkdownCodec.exportMarkdown(paragraphAttr, options: options)
            while markdownLine.hasSuffix("\n") {
                markdownLine.removeLast()
            }
            guard !markdownLine.isEmpty else { continue }
            let effectiveKind: KernBlockKind
            if kind == .bullet || kind == .task || kind == .ordered {
                effectiveKind = kind
            } else if let parsedKind = markdownListKind(in: markdownLine) {
                effectiveKind = parsedKind
            } else {
                continue
            }

            guard let adjusted = adjustedListMarkdownLine(markdownLine, kind: effectiveKind, outdent: outdent),
                  adjusted != markdownLine else { continue }

            let imported = importListMarkdownContentWithContextIfNeeded(
                adjusted,
                kind: effectiveKind,
                options: options
            )
            edits.append(ListIndentEdit(range: contentRange, replacement: imported))
        }

        guard !edits.isEmpty else { return false }

        isApplyingInputRules = true
        defer { isApplyingInputRules = false }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        var mappedSelectionStart = selection.location
        var mappedSelectionEnd = selection.location + selection.length

        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            mappedSelectionStart = mapLocation(
                mappedSelectionStart,
                throughReplacing: edit.range,
                replacementLength: edit.replacement.length
            )
            mappedSelectionEnd = mapLocation(
                mappedSelectionEnd,
                throughReplacing: edit.range,
                replacementLength: edit.replacement.length
            )
        }

        let clampedStart = min(max(0, mappedSelectionStart), storage.length)
        let clampedEnd = min(max(clampedStart, mappedSelectionEnd), storage.length)
        textView.setSelectedRange(NSRange(location: clampedStart, length: max(0, clampedEnd - clampedStart)))
        textView.didChangeText()
        return true
    }

    private func selectedParagraphRanges(ns: NSString, selection: NSRange) -> [NSRange] {
        guard ns.length > 0 else { return [] }

        let selectionStart = min(max(0, selection.location), max(0, ns.length - 1))
        let selectionEndExclusive = min(ns.length, selection.location + selection.length)
        let selectionEndProbe = selection.length == 0
            ? selectionStart
            : min(max(selectionStart, selectionEndExclusive - 1), max(0, ns.length - 1))

        var ranges: [NSRange] = []
        var cursor = ns.paragraphRange(for: NSRange(location: selectionStart, length: 0))

        while true {
            ranges.append(cursor)
            let nextLocation = cursor.location + cursor.length
            if nextLocation > selectionEndProbe || nextLocation >= ns.length {
                break
            }
            cursor = ns.paragraphRange(for: NSRange(location: nextLocation, length: 0))
        }
        return ranges
    }

    private func adjustedListMarkdownLine(_ markdownLine: String, kind: KernBlockKind, outdent: Bool) -> String? {
        let step = listIndentStep(for: kind)
        if outdent {
            let leadingSpaces = markdownLine.prefix { $0 == " " }.count
            if leadingSpaces >= step {
                return String(markdownLine.dropFirst(step))
            }
            if leadingSpaces > 0 {
                return String(markdownLine.dropFirst(leadingSpaces))
            }
            return unlistedBodyMarkdown(from: markdownLine, kind: kind)
        }
        return String(repeating: " ", count: step) + markdownLine
    }

    private func importListMarkdownContentWithContextIfNeeded(
        _ markdownLine: String,
        kind: KernBlockKind,
        options: NativeMarkdownCodec.Options
    ) -> NSAttributedString {
        let leadingSpaces = markdownLine.prefix { $0 == " " }.count
        let importedDirect = NativeMarkdownCodec.importMarkdown(markdownLine, options: options)

        // CommonMark list parsing can require parent-container context once a list marker sits 4+
        // columns from margin. When we re-import a single edited paragraph in isolation (Tab/Shift+Tab),
        // those deeply-indented nested list rows can be interpreted as code-block text.
        //
        // Use a lightweight synthetic parent line so nested semantics stay list-typed, then extract only
        // the adjusted paragraph's content range for replacement.
        guard leadingSpaces >= 4, markdownListKind(in: markdownLine) != nil else {
            return importedDirect
        }

        let parentLine: String
        switch kind {
        case .ordered:
            parentLine = "1. parent"
        case .bullet, .task:
            parentLine = "- parent"
        default:
            return importedDirect
        }

        let wrapped = parentLine + "\n" + markdownLine
        let wrappedImported = NativeMarkdownCodec.importMarkdown(wrapped, options: options)
        let wrappedNS = wrappedImported.string as NSString
        guard wrappedNS.length > 0 else { return importedDirect }

        let firstParagraph = wrappedNS.paragraphRange(for: NSRange(location: 0, length: 0))
        let secondLocation = firstParagraph.location + firstParagraph.length
        guard secondLocation < wrappedNS.length else { return importedDirect }

        let secondParagraph = wrappedNS.paragraphRange(for: NSRange(location: secondLocation, length: 0))
        let secondContent = paragraphContentRange(ns: wrappedNS, paraRange: secondParagraph)
        guard secondContent.length >= 0 else { return importedDirect }
        return wrappedImported.attributedSubstring(from: secondContent)
    }

    private func listIndentStep(for kind: KernBlockKind) -> Int {
        switch kind {
        case .ordered:
            return 3
        case .bullet, .task:
            return 2
        default:
            return 2
        }
    }

    private struct PlainMarkdownListPrefix {
        let kind: KernBlockKind
        let prefixLength: Int
    }

    private func markdownListKind(in markdownLine: String) -> KernBlockKind? {
        plainMarkdownListPrefix(in: markdownLine)?.kind
    }

    private func plainMarkdownListPrefix(in markdownLine: String) -> PlainMarkdownListPrefix? {
        guard !markdownLine.isEmpty else { return nil }
        let start = markdownLine.startIndex
        let trimmed = markdownLine.drop { $0 == " " }
        let leadingSpaces = markdownLine.distance(from: start, to: trimmed.startIndex)

        func consumed(_ original: Substring, _ remainder: Substring) -> Int {
            original.distance(from: original.startIndex, to: remainder.startIndex)
        }

        if let afterTask = consumeTaskPrefix(trimmed) {
            return PlainMarkdownListPrefix(
                kind: .task,
                prefixLength: leadingSpaces + consumed(trimmed, afterTask)
            )
        }

        if let afterBullet = consumeBulletPrefix(trimmed) {
            if let afterTask = consumeTaskPrefix(afterBullet) {
                return PlainMarkdownListPrefix(
                    kind: .task,
                    prefixLength: leadingSpaces + consumed(trimmed, afterTask)
                )
            }
            return PlainMarkdownListPrefix(
                kind: .bullet,
                prefixLength: leadingSpaces + consumed(trimmed, afterBullet)
            )
        }

        if let afterOrdered = consumeOrderedPrefix(trimmed) {
            if let afterTask = consumeTaskPrefix(afterOrdered) {
                return PlainMarkdownListPrefix(
                    kind: .ordered,
                    prefixLength: leadingSpaces + consumed(trimmed, afterTask)
                )
            }
            return PlainMarkdownListPrefix(
                kind: .ordered,
                prefixLength: leadingSpaces + consumed(trimmed, afterOrdered)
            )
        }

        return nil
    }

    private func unlistedBodyMarkdown(from markdownLine: String, kind: KernBlockKind) -> String? {
        var rest = markdownLine[markdownLine.startIndex...]
        while let first = rest.first, first == " " {
            rest = rest.dropFirst()
        }

        switch kind {
        case .bullet:
            guard let afterBullet = consumeBulletPrefix(rest) else { return nil }
            return String(afterBullet)
        case .task:
            if let afterTask = consumeTaskPrefix(rest) {
                return String(afterTask)
            }
            if let afterBullet = consumeBulletPrefix(rest),
               let afterTask = consumeTaskPrefix(afterBullet) {
                return String(afterTask)
            }
            return nil
        case .ordered:
            guard let afterOrdered = consumeOrderedPrefix(rest) else { return nil }
            if let afterTask = consumeTaskPrefix(afterOrdered) {
                return String(afterTask)
            }
            return String(afterOrdered)
        default:
            return nil
        }
    }

    private func consumeBulletPrefix(_ text: Substring) -> Substring? {
        guard let first = text.first, first == "-" || first == "*" || first == "+" else { return nil }
        var idx = text.index(after: text.startIndex)
        guard idx < text.endIndex, text[idx] == " " else { return nil }
        while idx < text.endIndex, text[idx] == " " {
            idx = text.index(after: idx)
        }
        return text[idx...]
    }

    private func consumeOrderedPrefix(_ text: Substring) -> Substring? {
        var idx = text.startIndex
        var sawDigit = false
        while idx < text.endIndex, text[idx].isNumber {
            sawDigit = true
            idx = text.index(after: idx)
        }
        guard sawDigit, idx < text.endIndex, text[idx] == "." else { return nil }
        idx = text.index(after: idx)
        guard idx < text.endIndex, text[idx] == " " else { return nil }
        while idx < text.endIndex, text[idx] == " " {
            idx = text.index(after: idx)
        }
        return text[idx...]
    }

    private func consumeTaskPrefix(_ text: Substring) -> Substring? {
        if text.hasPrefix("[] ") {
            return text.dropFirst(3)
        }
        if text.hasPrefix("[ ] ") {
            return text.dropFirst(4)
        }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            return text.dropFirst(4)
        }
        return nil
    }

    private func mapLocation(_ location: Int, throughReplacing range: NSRange, replacementLength: Int) -> Int {
        let replacementEnd = range.location + range.length
        if location <= range.location {
            return location
        }
        if location >= replacementEnd {
            return location + (replacementLength - range.length)
        }
        let offsetInside = location - range.location
        return range.location + min(offsetInside, replacementLength)
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

    private func hasListMarkerShortcutPrefix(_ body: String) -> Bool {
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return true
        }
        if body.hasPrefix("- ["), body.count >= 6 {
            let chars = Array(body)
            if chars[0] == "-", chars[1] == " ", chars[2] == "[", chars[4] == "]", chars[5] == " " {
                let c = chars[3]
                if c == " " || c == "x" || c == "X" {
                    return true
                }
            }
        }
        if body.hasPrefix("[] ") { return true }
        if body.hasPrefix("[ ] ") { return true }
        if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { return true }
        if isOrderedListPrefix(body) { return true }
        return false
    }

    private func effectiveBlockKind(
        in storage: NSTextStorage,
        paraRange: NSRange,
        contentRange: NSRange
    ) -> KernBlockKind {
        guard storage.length > 0 else { return .paragraph }

        var resolved: KernBlockKind?
        let probeRanges: [NSRange] = [contentRange, paraRange]
        for range in probeRanges where range.length > 0 {
            guard range.location < storage.length else { continue }
            let clampedLength = min(range.length, storage.length - range.location)
            guard clampedLength > 0 else { continue }
            let clamped = NSRange(location: range.location, length: clampedLength)
            storage.enumerateAttribute(.kernBlockKind, in: clamped, options: []) { value, _, stop in
                let raw = (value as? Int) ?? KernBlockKind.paragraph.rawValue
                let kind = KernBlockKind(rawValue: raw) ?? .paragraph
                if kind != .paragraph {
                    resolved = kind
                    stop.pointee = true
                }
            }
            if resolved != nil { break }
        }

        if let resolved { return resolved }

        let fallback = min(max(0, contentRange.location), max(0, storage.length - 1))
        let fallbackRaw = storage.attribute(.kernBlockKind, at: fallback, effectiveRange: nil) as? Int
        return KernBlockKind(rawValue: fallbackRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
    }

    private func switchedMarkdownFromOrderedBodyBulletShortcut(_ markdownLine: String) -> String? {
        guard !markdownLine.isEmpty else { return nil }
        let leadingSpaces = markdownLine.prefix { $0 == " " }.count
        let trimmed = markdownLine.dropFirst(leadingSpaces)
        guard let afterOrdered = consumeOrderedPrefix(trimmed) else { return nil }
        guard let afterBullet = consumeBulletPrefix(afterOrdered) else { return nil }
        return String(repeating: " ", count: leadingSpaces) + "- " + String(afterBullet)
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
            let selection = textView.selectedRange()
            let carryLocation = caretCarryLocationAfterSoftBreak(caret: selection.location, storage: storage)
            textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: carryLocation)
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }

        let caret = selection.location
        let ns = storage.string as NSString
        guard caret > 0, caret <= ns.length else { return }
        guard ns.character(at: caret - 1) == 10 else { return } // '\n'

        let prevPara = ns.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let prevContentRange = paragraphContentRange(ns: ns, paraRange: prevPara)
        let prevKind = effectiveBlockKind(in: storage, paraRange: prevPara, contentRange: prevContentRange)
        let prevAttrLocation = semanticAttributeProbeLocation(in: storage, paraRange: prevPara, contentRange: prevContentRange)
        let prevQuoteDepth = (storage.attribute(.kernQuoteDepth, at: prevAttrLocation, effectiveRange: nil) as? Int) ?? 0

        let currPara = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let currContentRange = paragraphContentRange(ns: ns, paraRange: currPara)

        // Helper: compute content in previous paragraph (excluding marker + trailing newline).
        let prevContent = previousParagraphContent(storage: storage, ns: ns, paraRange: prevPara)
        let prevContentIsEmpty = listBodyIsEffectivelyEmpty(prevContent)

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
                clearListBlockSemanticsAroundCaret(newCaret, storage: storage)

                setBaseTypingAttributes()
                return
            }

            // Continue list markers on Enter.
            // If Enter is pressed in the middle of an item, the new paragraph already contains
            // the trailing split content; insert marker prefix at the start of that paragraph.
            isApplyingAutoNewline = true
            defer { isApplyingAutoNewline = false }

            let indent = max(0, (storage.attribute(.kernListIndent, at: prevAttrLocation, effectiveRange: nil) as? Int) ?? 0)
            let indentPrefix = String(repeating: " ", count: indent)
            let markerLine: String
            switch prevKind {
            case .bullet:
                markerLine = indentPrefix + "- "
            case .task:
                let styleRaw = storage.attribute(.kernTaskStyle, at: prevAttrLocation, effectiveRange: nil) as? Int
                let style = KernTaskStyle(rawValue: styleRaw ?? KernTaskStyle.bulleted.rawValue) ?? .bulleted
                markerLine = indentPrefix + (style == .standalone ? "[] " : "- [ ] ")
            case .ordered:
                let prevN = (storage.attribute(.kernOrderedIndex, at: prevAttrLocation, effectiveRange: nil) as? Int) ?? 1
                let orderedIsTask = (storage.attribute(.kernOrderedIsTask, at: prevAttrLocation, effectiveRange: nil) as? Bool) ?? false
                markerLine = indentPrefix + (orderedIsTask ? "\(max(1, prevN + 1)). [ ] " : "\(max(1, prevN + 1)). ")
            default:
                markerLine = ""
            }

            let opt = NativeMarkdownCodec.Options.fromUserDefaults()
            let imported = NativeMarkdownCodec.importMarkdown(markerLine, options: opt)

            if currContentRange.length == 0 {
                storage.replaceCharacters(in: currContentRange, with: imported)
            } else {
                storage.replaceCharacters(in: NSRange(location: currContentRange.location, length: 0), with: imported)
            }

            let markerLen = markerPrefixLength(in: imported)
            let newCaret = min(storage.length, currContentRange.location + markerLen)
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            textView.typingAttributes = sanitizedMarkerRecoveryAttributes(storage: storage, insertionTarget: newCaret)
            return
        }

        // Tables (GFM): if the user just finished typing a valid table block, convert it to a TextKit table.
        // This is intentionally conservative: it triggers only after a newline and only when we see a
        // header + delimiter + at least one body row.
        if prevKind == .paragraph {
            applyTableInputRulesIfNeeded(caret: caret, prevParagraph: prevPara, storage: storage, ns: ns)
        }
    }

    private func clearListBlockSemanticsAroundCaret(_ caret: Int, storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        let probe = min(max(0, caret), max(0, storage.length - 1))
        let paraRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        let safeLen = min(paraRange.length, storage.length - paraRange.location)
        guard safeLen > 0 else { return }
        let range = NSRange(location: paraRange.location, length: safeLen)

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
            .kernQuoteDepth,
        ]
        for key in blockKeys {
            storage.removeAttribute(key, range: range)
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
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }

        let delta = imported.length - replaceRange.length
        storage.replaceCharacters(in: replaceRange, with: imported)

        // Keep caret location stable relative to the replaced block (best-effort).
        let newCaret = min(max(0, caret + delta), storage.length)
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
    }

    private func semanticAttributeProbeLocation(
        in storage: NSTextStorage,
        paraRange: NSRange,
        contentRange: NSRange
    ) -> Int {
        guard storage.length > 0 else { return 0 }

        var probe: Int?
        if contentRange.length > 0, contentRange.location < storage.length {
            let clampedLength = min(contentRange.length, storage.length - contentRange.location)
            if clampedLength > 0 {
                let clamped = NSRange(location: contentRange.location, length: clampedLength)
                storage.enumerateAttributes(in: clamped, options: []) { attrs, range, stop in
                    if (attrs[.kernMarker] as? Bool) == true
                        || attrs[.kernBlockKind] != nil
                        || attrs[.kernListIndent] != nil
                        || attrs[.kernOrderedIndex] != nil {
                        probe = range.location
                        stop.pointee = true
                    }
                }
            }
        }

        if let probe {
            return min(max(0, probe), max(0, storage.length - 1))
        }

        return min(max(0, paraRange.location), max(0, storage.length - 1))
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
            let isCheckbox = (storage.attribute(.kernCheckbox, at: start, effectiveRange: nil) as? Bool) ?? false
            if !(isMarker || isCheckbox) { break }
            start += 1
        }
        let bodyRange = NSRange(location: start, length: max(0, contentRange.location + contentRange.length - start))
        return storage.attributedSubstring(from: bodyRange).string
    }

    private func listBodyIsEffectivelyEmpty(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "☐" || trimmed == "☑" || trimmed == "☒" { return true }
        if trimmed == "•" || trimmed == "-" || trimmed == "*" || trimmed == "+" { return true }
        if trimmed.range(of: #"^\d+\.$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private func removeMarkerPrefix(in paraRange: NSRange, storage: NSTextStorage, ns: NSString) -> Int {
        let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
        guard contentRange.length > 0 else { return 0 }

        var markerLen = 0
        while markerLen < contentRange.length {
            let idx = contentRange.location + markerLen
            let isMarker = (storage.attribute(.kernMarker, at: idx, effectiveRange: nil) as? Bool) ?? false
            let isCheckbox = (storage.attribute(.kernCheckbox, at: idx, effectiveRange: nil) as? Bool) ?? false
            if !(isMarker || isCheckbox) { break }
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
        let baseFont = NativeEditorAppearance.baseFont()
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = 5
        style.lineHeightMultiple = 1.12
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NativeEditorAppearance.primaryTextColor(),
            .paragraphStyle: style,
        ]
    }

    private func setQuoteTypingAttributes(depth: Int) {
        let baseFont = NativeEditorAppearance.baseFont()
        let safeDepth = max(1, depth)
        let style = NSMutableParagraphStyle()
        let quoteIndent: CGFloat = CGFloat(safeDepth) * 16
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = 5
        style.lineHeightMultiple = 1.12

        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NativeEditorAppearance.primaryTextColor(),
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

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.removeAttribute(.kernQuoteDepth, range: safeRange)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = 5
        style.lineHeightMultiple = 1.12
        storage.addAttribute(.paragraphStyle, value: style, range: safeRange)
        storage.addAttribute(.kernBlockKind, value: KernBlockKind.paragraph.rawValue, range: safeRange)
    }

    private func setHeadingTypingAttributes(level: Int) {
        let lvl = max(1, min(6, level))
        let font = NativeEditorAppearance.headingFont(level: lvl)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = lvl == 1 ? 14 : 10
        style.paragraphSpacing = 6
        style.lineHeightMultiple = 1.12

        // Include semantic attrs so export sees this paragraph as a heading.
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NativeEditorAppearance.primaryTextColor(),
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

    private func inlineFormattingBaseFont(for attrs: [NSAttributedString.Key: Any]) -> NSFont {
        let fallback = NativeEditorAppearance.baseFont()
        let blockRaw = attrs[.kernBlockKind] as? Int
        let blockKind = KernBlockKind(rawValue: blockRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        switch blockKind {
        case .heading:
            let level = max(1, min(6, attrs[.kernHeadingLevel] as? Int ?? 1))
            return NativeEditorAppearance.headingFont(level: level)
        case .codeBlock:
            let size = (attrs[.font] as? NSFont)?.pointSize ?? fallback.pointSize
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            if let existingFont = attrs[.font] as? NSFont {
                let base = NativeEditorAppearance.baseFont()
                if abs(existingFont.pointSize - base.pointSize) > 0.01 {
                    if let resized = NSFont(descriptor: base.fontDescriptor, size: existingFont.pointSize) {
                        return resized
                    }
                }
            }
            return fallback
        }
    }

    private func toggleInlineAttribute(_ key: NSAttributedString.Key) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        // Determine if we're turning on or off based on the first character.
        let existing = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Bool) ?? false
        let newValue = !existing

        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        storage.beginEditing()
        defer { storage.endEditing() }

        storage.addAttribute(key, value: newValue, range: range)

        // Update fonts/background while preserving block-level typography (ex: heading size).
        storage.enumerateAttributes(in: range, options: []) { attrs, subrange, _ in
            let strong = (attrs[.kernStrong] as? Bool) ?? false
            let emphasis = (attrs[.kernEmphasis] as? Bool) ?? false
            let code = (attrs[.kernInlineCode] as? Bool) ?? false

            let baseFont = inlineFormattingBaseFont(for: attrs)
            var font = baseFont
            var background: NSColor? = nil

            if code {
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                background = NativeEditorAppearance.inlineCodeBackgroundColor()
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
        let isUserScrollEvent = isUserLiveScrolling || isUserDrivenScrollEventType(NSApp.currentEvent?.type)
        if isUserScrollEvent, !isApplyingExternalUpdate {
            noteUserScrollEvent()
        }
        scheduleStagedViewportPromotionIfNeeded()
        scheduleCodeBlockChromeUpdateForScrollIfNeeded()
        maybeReapplyAnchorJumpIfNeeded()
    }

    @objc private func scrollViewWillStartLiveScroll(_ notification: Notification) {
        guard !isApplyingExternalUpdate else { return }
        isUserLiveScrolling = true
        noteUserScrollEvent()
    }

    @objc private func scrollViewDidEndLiveScroll(_ notification: Notification) {
        isUserLiveScrolling = false
        guard !isApplyingExternalUpdate else { return }
        noteUserScrollEvent()
        scheduleStagedViewportPromotionIfNeeded()
    }

    private func isUserDrivenScrollEventType(_ type: NSEvent.EventType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    private func noteUserInteraction(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastUserInteractionUptime = now
    }

    private func noteUserScrollEvent(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        noteUserInteraction(at: now)
        lastUserScrollEventUptime = now
    }

    private func secondsSinceLastUserScroll(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard let lastUserScrollEventUptime else { return nil }
        return now - lastUserScrollEventUptime
    }

    private func scheduleStagedViewportPromotionIfNeeded() {
        guard stagedPromotionsAllowed else { return }
        guard stagedRenderGeneration == renderGeneration else { return }
        guard deferredFullRenderWorkItem == nil else { return }
        guard !hasUnexportedChanges else { return }
        guard !isUserLiveScrolling else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_skipped_live_scroll_count")
            return
        }
        guard !stagedPromotionInFlight else { return }
        guard let renderedDisplayBoundary = stagedRenderedDisplayBoundary,
              let renderedMarkdownUTF16Count = stagedRenderedMarkdownUTF16Count else { return }
        let totalMarkdownUTF16Count = stringValue.utf16.count
        guard renderedMarkdownUTF16Count < totalMarkdownUTF16Count else {
            finalizeStagedPromotionCompletion()
            return
        }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let visibleRange = visibleCharacterRangeForChrome(layoutManager: lm, textContainer: tc)
        let visibleEnd = visibleRange.location + visibleRange.length
        if visibleEnd + stagedPromotionLookaheadVisibleChars < renderedDisplayBoundary {
            return
        }

        stagedPromotionWorkItem?.cancel()
        stagedPromotionToken &+= 1
        let token = stagedPromotionToken
        let work = DispatchWorkItem { [weak self] in
            self?.applyNextStagedViewportPromotion(token: token)
        }
        stagedPromotionWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(stagedPromotionDebounceMsValue()),
            execute: work
        )
    }

    private func applyNextStagedViewportPromotion(token: UInt64) {
        WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_cycle_invocation_count")
        guard stagedPromotionsAllowed else { return }
        guard token == stagedPromotionToken else { return }
        guard stagedRenderGeneration == renderGeneration else { return }
        guard deferredFullRenderWorkItem == nil else { return }
        guard !hasUnexportedChanges else { return }
        if isUserLiveScrolling {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_skipped_live_scroll_count")
            scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 30)
            return
        }
        if stagedPromotionInFlight {
            let now = ProcessInfo.processInfo.systemUptime
            if let started = stagedPromotionInFlightStartedAtUptime,
               now - started > 2.0 {
                WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_stuck_recovery_count")
                stagedPromotionComputeTask?.cancel()
                stagedPromotionInFlight = false
                stagedPromotionInFlightToken = nil
                stagedPromotionInFlightStartedAtUptime = nil
                scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 40)
            }
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else {
            scheduleStagedPromotionFollowupIfNeeded()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let sinceScroll = secondsSinceLastUserScroll(at: now)
        let effectiveSinceScroll = sinceScroll ?? .greatestFiniteMagnitude
        let sinceInteraction = now - lastUserInteractionUptime
        let scrollQuietSeconds = Double(stagedPromotionScrollQuietPeriodMsValue()) / 1_000.0
        if effectiveSinceScroll < scrollQuietSeconds {
            scheduleStagedPromotionFollowupIfNeeded()
            return
        }
        let idleQuietSeconds = Double(stagedPromotionIdleQuietPeriodMsValue()) / 1_000.0
        if sinceInteraction < idleQuietSeconds {
            // Keep the full-document catch-up pipeline alive after short interaction bursts
            // (typing pulses, brief clicks) so fidelity can complete without requiring the
            // user to scroll near the staged boundary again.
            scheduleStagedPromotionFollowupIfNeeded()
            return
        }
        let useTurbo = shouldUseTurboStagedPromotion(
            sinceInteraction: sinceInteraction,
            sinceScroll: effectiveSinceScroll
        )

        guard let currentRenderedUTF16 = stagedRenderedMarkdownUTF16Count else { return }
        guard let currentRenderedDisplayBoundary = stagedRenderedDisplayBoundary else { return }
        let markdown = stringValue
        let totalUTF16 = markdown.utf16.count
        guard currentRenderedUTF16 < totalUTF16 else {
            finalizeStagedPromotionCompletion()
            return
        }

        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let visibleRange = visibleCharacterRangeForChrome(layoutManager: lm, textContainer: tc)
        let visibleEnd = visibleRange.location + visibleRange.length

        let viewportAnchor = captureViewportAnchor()
        let minStepTarget = currentRenderedUTF16 + stagedPromotionStepCharsValue(useTurbo: useTurbo)
        let catchupTarget = estimatedMarkdownUTF16CatchupTarget(
            visibleDisplayEnd: visibleEnd,
            renderedDisplayBoundary: currentRenderedDisplayBoundary,
            renderedMarkdownUTF16Count: currentRenderedUTF16,
            totalMarkdownUTF16Count: totalUTF16,
            useTurbo: useTurbo
        )
        let maxCatchupTarget = currentRenderedUTF16 + stagedPromotionMaxCatchupStepCharsValue(useTurbo: useTurbo)
        var targetUTF16 = min(
            totalUTF16,
            max(
                minStepTarget,
                min(catchupTarget, maxCatchupTarget)
            )
        )
        targetUTF16 = alignedPromotionUTF16Count(markdown, targetUTF16Count: targetUTF16)
        guard targetUTF16 > currentRenderedUTF16 else {
            rescheduleStagedPromotionAfterNoProgress()
            return
        }
        var rawDeltaUTF16 = targetUTF16 - currentRenderedUTF16
        guard rawDeltaUTF16 > 0 else {
            rescheduleStagedPromotionAfterNoProgress()
            return
        }

        let parseDeltaCap = stagedPromotionViewportMicroStepCharsValue(
            useTurbo: useTurbo,
            sinceInteraction: sinceInteraction,
            sinceScroll: effectiveSinceScroll
        )
        WowInternalMetricsRecorder.shared.recordAuxMetric(
            "wow_staged_promotion_parse_delta_cap_utf16",
            value: Double(parseDeltaCap)
        )
        if rawDeltaUTF16 > parseDeltaCap {
            targetUTF16 = min(totalUTF16, currentRenderedUTF16 + parseDeltaCap)
            targetUTF16 = alignedPromotionUTF16Count(markdown, targetUTF16Count: targetUTF16)
            rawDeltaUTF16 = targetUTF16 - currentRenderedUTF16
            guard rawDeltaUTF16 > 0 else {
                rescheduleStagedPromotionAfterNoProgress()
                return
            }
        }
        WowInternalMetricsRecorder.shared.recordAuxSample(
            "wow_staged_promotion_target_delta_utf16",
            sample: Double(rawDeltaUTF16)
        )

        if let viewportAnchor {
            let guardChars = stagedPromotionViewportGuardCharsValue()
            let anchorSlack = viewportAnchor.characterLocation - currentRenderedDisplayBoundary - guardChars
            let cappedDelta: Int
            if anchorSlack > 0 {
                cappedDelta = max(1, min(rawDeltaUTF16, anchorSlack))
            } else {
                cappedDelta = max(
                    1,
                    min(
                        rawDeltaUTF16,
                        stagedPromotionViewportMicroStepCharsValue(
                            useTurbo: useTurbo,
                            sinceInteraction: sinceInteraction,
                            sinceScroll: effectiveSinceScroll
                        )
                    )
                )
            }
            if cappedDelta < rawDeltaUTF16 {
                targetUTF16 = min(totalUTF16, currentRenderedUTF16 + cappedDelta)
                targetUTF16 = alignedPromotionUTF16Count(markdown, targetUTF16Count: targetUTF16)
                rawDeltaUTF16 = targetUTF16 - currentRenderedUTF16
                guard rawDeltaUTF16 > 0 else {
                    rescheduleStagedPromotionAfterNoProgress()
                    return
                }
            }
        }

        var options = NativeMarkdownCodec.Options.fromUserDefaults()
        if stagedDeferredSyntaxHighlightingEnabled {
            options.syntaxHighlightingEnabled = false
        }
        let parseOptions = options
        let renderGenerationAtLaunch = renderGeneration
        let baseURLAtLaunch = documentURL
        let referenceDefinitionsAtLaunch = currentStagedReferenceDefinitions(for: renderGenerationAtLaunch)
        let cachedContextBoundaryStartUTF16 = stagedContextBoundaryStartUTF16
        let cachedContextBoundaryDisplayStart = stagedContextBoundaryDisplayStart
        let cachedContextBoundaryRenderedUTF16 = stagedContextBoundaryRenderedUTF16
        let contextStartUTF16 = stagedPromotionContextStartUTF16(
            markdown: markdown,
            renderedUTF16Count: currentRenderedUTF16
        )

        stagedPromotionInFlight = true
        stagedPromotionInFlightToken = token
        stagedPromotionInFlightStartedAtUptime = ProcessInfo.processInfo.systemUptime
        stagedPromotionComputeTask?.cancel()
        WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_compute_launch_count")
        let computeWorker = stagedPromotionComputeWorker
        stagedPromotionComputeTask = Task(priority: .userInitiated) { [weak self] in
            let computeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let computed = await computeWorker.computeContext(
                markdown: markdown,
                contextStartUTF16: contextStartUTF16,
                oldEndUTF16: currentRenderedUTF16,
                newEndUTF16: targetUTF16
            )
            let computeMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - computeStart) / 1_000_000
            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.cancelStagedPromotionInFlightIfMatching(token: token)
                    self?.scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 20)
                }
                return
            }
            let parseStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let parseResult: StagedPromotionParseResultBox = await MainActor.run {
                let prelude: (Int, Bool) = {
                    if let cachedStart = cachedContextBoundaryStartUTF16,
                       let cachedDisplayStart = cachedContextBoundaryDisplayStart,
                       let cachedRenderedUTF16 = cachedContextBoundaryRenderedUTF16,
                       cachedStart == computed.contextStartUTF16,
                       cachedRenderedUTF16 == currentRenderedUTF16 {
                        let candidate = currentRenderedDisplayBoundary - cachedDisplayStart
                        if candidate >= 0 {
                            return (candidate, true)
                        }
                    }

                    var lengthOnlyOptions = parseOptions
                    lengthOnlyOptions.syntaxHighlightingEnabled = false
                    let oldAttributed = NativeMarkdownCodec.importMarkdown(
                        computed.contextOldMarkdown,
                        options: lengthOnlyOptions,
                        baseURL: baseURLAtLaunch,
                        precomputedReferenceDefinitions: referenceDefinitionsAtLaunch
                    )
                    return (oldAttributed.length, false)
                }()

                let newAttributed = NativeMarkdownCodec.importMarkdown(
                    computed.contextNewMarkdown,
                    options: parseOptions,
                    baseURL: baseURLAtLaunch,
                    precomputedReferenceDefinitions: referenceDefinitionsAtLaunch
                )
                return StagedPromotionParseResultBox(
                    preludeDisplayLength: prelude.0,
                    contextNewAttributed: newAttributed,
                    preludeCacheHit: prelude.1
                )
            }
            let parseMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - parseStart) / 1_000_000
            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.cancelStagedPromotionInFlightIfMatching(token: token)
                    self?.scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 20)
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                if parseResult.preludeCacheHit {
                    WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_prelude_cache_hit_count")
                } else {
                    WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_prelude_cache_miss_count")
                }
                self.applyParsedStagedViewportPromotion(
                    token: token,
                    markdown: markdown,
                    totalUTF16: totalUTF16,
                    rawDeltaUTF16: rawDeltaUTF16,
                    currentRenderedDisplayBoundary: currentRenderedDisplayBoundary,
                    promotedPrefixUTF16Count: targetUTF16,
                    viewportAnchor: viewportAnchor,
                    useTurbo: useTurbo,
                    contextStartUTF16: computed.contextStartUTF16,
                    preludeDisplayLength: parseResult.preludeDisplayLength,
                    contextNewAttributed: parseResult.contextNewAttributed,
                    promotionComputeMs: computeMs,
                    promotionParseMs: parseMs
                )
            }
        }
    }

    private func applyParsedStagedViewportPromotion(
        token: UInt64,
        markdown: String,
        totalUTF16: Int,
        rawDeltaUTF16: Int,
        currentRenderedDisplayBoundary: Int,
        promotedPrefixUTF16Count: Int,
        viewportAnchor: ViewportAnchor?,
        useTurbo: Bool,
        contextStartUTF16: Int,
        preludeDisplayLength: Int,
        contextNewAttributed: NSAttributedString,
        promotionComputeMs: Double,
        promotionParseMs: Double
    ) {
        WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_attempt_count")
        defer {
            if stagedPromotionInFlightToken == token {
                stagedPromotionInFlight = false
                stagedPromotionInFlightToken = nil
                stagedPromotionInFlightStartedAtUptime = nil
                stagedPromotionComputeTask = nil
            }
        }
        guard stagedPromotionsAllowed else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_skipped_no_promotions_allowed_count")
            return
        }
        guard token == stagedPromotionToken else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_skipped_token_mismatch_count")
            scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 20)
            return
        }
        guard stagedRenderGeneration == renderGeneration else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_skipped_generation_mismatch_count")
            return
        }
        guard deferredFullRenderWorkItem == nil else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_skipped_deferred_full_render_active_count")
            return
        }
        guard !hasUnexportedChanges else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_skipped_unexported_changes_count")
            return
        }
        if stringValue != markdown {
            // The source snapshot changed while background compute was running
            // (typically because a debounced export normalized markdown without
            // a user-visible edit). Re-enqueue promotion against the latest
            // markdown snapshot instead of stalling the staged pipeline.
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_skipped_markdown_snapshot_mismatch_count")
            scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 20)
            return
        }

        WowInternalMetricsRecorder.shared.recordMaxAuxMetric(
            "wow_staged_promotion_compute_latency_ms_max",
            candidate: promotionComputeMs
        )
        WowInternalMetricsRecorder.shared.recordAuxSample(
            "wow_staged_promotion_compute_latency_ms",
            sample: promotionComputeMs
        )
        WowInternalMetricsRecorder.shared.incrementAuxCounter(
            "wow_staged_promotion_compute_latency_ms_total",
            by: promotionComputeMs
        )

        WowInternalMetricsRecorder.shared.recordMaxAuxMetric(
            "wow_staged_promotion_parse_latency_ms_max",
            candidate: promotionParseMs
        )
        WowInternalMetricsRecorder.shared.recordAuxSample(
            "wow_staged_promotion_parse_latency_ms",
            sample: promotionParseMs
        )
        WowInternalMetricsRecorder.shared.incrementAuxCounter(
            "wow_staged_promotion_parse_latency_ms_total",
            by: promotionParseMs
        )
        WowInternalMetricsRecorder.shared.recordMaxAuxMetric(
            "wow_staged_promotion_delta_utf16_max",
            candidate: Double(rawDeltaUTF16)
        )
        WowInternalMetricsRecorder.shared.recordAuxSample(
            "wow_staged_promotion_delta_utf16",
            sample: Double(rawDeltaUTF16)
        )

        let contextDisplayStart = max(0, currentRenderedDisplayBoundary - preludeDisplayLength)
        let replacementAttributed = contextNewAttributed
        let promotedDisplayBoundary = contextDisplayStart + replacementAttributed.length

        guard let storage = textView.textStorage else { return }

        let replaceLength = preludeDisplayLength + rawDeltaUTF16
        let replaceRange = NSRange(location: contextDisplayStart, length: replaceLength)
        guard replaceRange.location >= 0, replaceRange.location + replaceRange.length <= storage.length else { return }
        let selection = textView.selectedRange()
        let replacementLength = replacementAttributed.length
        let selectionNeedsAdjustment =
            selection.location >= replaceRange.location ||
            NSIntersectionRange(selection, replaceRange).length > 0

        let promotionApplyStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }
        storage.beginEditing()
        storage.replaceCharacters(in: replaceRange, with: replacementAttributed)
        storage.endEditing()
        scheduleStagedPromotionLayoutRefresh(markdown: markdown)

        // Preserve text selection semantics if promotion edits happened before the caret.
        if selectionNeedsAdjustment,
           let adjustedSelection = adjustedRangeAfterReplacement(
            selection,
            replaceRange: replaceRange,
            replacementLength: replacementLength,
            maxLength: textView.string.utf16.count
           ),
           !NSEqualRanges(adjustedSelection, selection) {
            textView.setSelectedRange(adjustedSelection)
        }
        restoreViewportAnchor(
            viewportAnchor,
            replaceRange: replaceRange,
            replacementLength: replacementLength
        )
        let promotionApplyMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - promotionApplyStart) / 1_000_000
        lastStagedPromotionApplyMs = promotionApplyMs
        WowInternalMetricsRecorder.shared.recordMaxAuxMetric(
            "wow_staged_promotion_apply_latency_ms_max",
            candidate: promotionApplyMs
        )
        WowInternalMetricsRecorder.shared.recordAuxSample(
            "wow_staged_promotion_apply_latency_ms",
            sample: promotionApplyMs,
            p99MetricKey: "promotion_apply_slice_p99_ms"
        )
        WowInternalMetricsRecorder.shared.incrementAuxCounter(
            "wow_staged_promotion_apply_latency_ms_total",
            by: promotionApplyMs
        )
        WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_count")
        if promotionApplyMs > 16 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_over_16ms_count")
        }
        if promotionApplyMs > 33 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_over_33ms_count")
        }
        if promotionApplyMs > 50 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_over_50ms_count")
        }
        if promotionApplyMs > 100 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_apply_over_100ms_count")
        }
        tuneAdaptiveStagedPromotionBudget(
            lastApplyMs: promotionApplyMs,
            lastParseMs: promotionParseMs,
            useTurbo: useTurbo
        )

        stagedRenderedMarkdownUTF16Count = promotedPrefixUTF16Count
        stagedRenderedDisplayBoundary = promotedDisplayBoundary
        stagedPromotionsAllowed = promotedPrefixUTF16Count < totalUTF16
        stagedContextBoundaryStartUTF16 = contextStartUTF16
        stagedContextBoundaryDisplayStart = contextDisplayStart
        stagedContextBoundaryRenderedUTF16 = promotedPrefixUTF16Count

        if !stagedPromotionsAllowed {
            scheduleStagedPromotionLayoutRefresh(markdown: markdown, immediate: true)
            finalizeStagedPromotionCompletion()
        }

        updateCodeBlockChrome()
        scheduleStagedPromotionFollowupIfNeeded()
    }

    private func cancelStagedPromotionInFlightIfMatching(token: UInt64) {
        if stagedPromotionInFlightToken == token {
            stagedPromotionInFlight = false
            stagedPromotionInFlightToken = nil
            stagedPromotionInFlightStartedAtUptime = nil
            stagedPromotionComputeTask = nil
        }
    }

    private struct ViewportAnchor {
        let characterLocation: Int
        let verticalOffset: CGFloat
        let clipOriginY: CGFloat
    }

    private func captureViewportAnchor() -> ViewportAnchor? {
        guard
            let lm = textView.layoutManager,
            let tc = textView.textContainer,
            let storage = textView.textStorage,
            storage.length > 0
        else { return nil }

        let visible = textView.visibleRect
        let probe = NSPoint(
            x: max(0, visible.minX + 8 - textView.textContainerOrigin.x),
            y: max(0, visible.minY + 8 - textView.textContainerOrigin.y)
        )

        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: probe, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < lm.numberOfGlyphs else { return nil }
        let characterLocation = min(storage.length - 1, lm.characterIndexForGlyph(at: glyphIndex))

        let glyphRange = lm.glyphRange(
            forCharacterRange: NSRange(location: characterLocation, length: 1),
            actualCharacterRange: nil
        )
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        return ViewportAnchor(
            characterLocation: characterLocation,
            verticalOffset: rect.minY - visible.minY,
            clipOriginY: scrollView.contentView.bounds.origin.y
        )
    }

    private func restoreViewportAnchor(
        _ anchor: ViewportAnchor?,
        replaceRange: NSRange,
        replacementLength: Int
    ) {
        guard
            let anchor,
            let lm = textView.layoutManager,
            let tc = textView.textContainer,
            let storage = textView.textStorage,
            storage.length > 0
        else { return }

        let adjustedLocation = adjustedLocationAfterReplacement(
            anchor.characterLocation,
            replaceRange: replaceRange,
            replacementLength: replacementLength,
            maxLength: storage.length
        )
        guard adjustedLocation >= 0, adjustedLocation < storage.length else {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("anchor_rebase_fail_count")
            return
        }

        let replaceEnd = replaceRange.location + replaceRange.length
        let replacementIsEntirelyBeforeAnchor = replaceEnd <= anchor.characterLocation
        let now = ProcessInfo.processInfo.systemUptime
        if let sinceScroll = secondsSinceLastUserScroll(at: now), sinceScroll < 0.6 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("anchor_rebase_skipped_recent_scroll_count")
            return
        }
        let visibleRange = visibleCharacterRangeForChrome(layoutManager: lm, textContainer: tc)
        let guardChars = stagedPromotionViewportGuardCharsValue()
        let guardedVisibleStart = max(0, visibleRange.location - guardChars)
        let guardedVisibleEnd = min(
            storage.length,
            visibleRange.location + visibleRange.length + guardChars
        )
        let guardedVisibleRange = NSRange(
            location: guardedVisibleStart,
            length: max(0, guardedVisibleEnd - guardedVisibleStart)
        )
        if NSIntersectionRange(replaceRange, guardedVisibleRange).length > 0 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("anchor_rebase_skipped_viewport_overlap_count")
            return
        }

        let glyphRange = lm.glyphRange(
            forCharacterRange: NSRange(location: adjustedLocation, length: 1),
            actualCharacterRange: nil
        )
        lm.ensureLayout(forGlyphRange: glyphRange)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let desiredY = rect.minY - anchor.verticalOffset
        let clip = scrollView.contentView
        let currentY = clip.bounds.origin.y
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
        let clampedY = max(0, min(maxY, desiredY))
        // Always re-anchor to the same visual character during staged promotion. Limiting this to
        // "before-anchor" replacements causes cumulative drift/jumps when style promotions touch
        // the active viewport and line metrics change.
        let deltaY = clampedY - currentY
        let maxCorrection = stagedPromotionMaxViewportCorrectionPxValue()
        let adjustedY: CGFloat
        if abs(deltaY) > maxCorrection {
            adjustedY = currentY + (deltaY.sign == .minus ? -maxCorrection : maxCorrection)
        } else {
            adjustedY = clampedY
        }
        if !replacementIsEntirelyBeforeAnchor, abs(adjustedY - currentY) < 0.5 {
            return
        }
        let finalY = max(0, min(maxY, adjustedY))
        let effectiveDelta = abs(finalY - currentY)
        if effectiveDelta > 0.5 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("anchor_rebase_count")
            WowInternalMetricsRecorder.shared.recordMaxAuxMetric("scroll_jump_max_px", candidate: Double(effectiveDelta))
            if effectiveDelta >= stagedPromotionJumpMetricThresholdPxValue() {
                WowInternalMetricsRecorder.shared.incrementAuxCounter("scroll_jump_count")
            }
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: finalY))
        scrollView.reflectScrolledClipView(clip)
    }

    private func adjustedRangeAfterReplacement(
        _ range: NSRange,
        replaceRange: NSRange,
        replacementLength: Int,
        maxLength: Int
    ) -> NSRange? {
        let location = adjustedLocationAfterReplacement(
            range.location,
            replaceRange: replaceRange,
            replacementLength: replacementLength,
            maxLength: maxLength
        )
        guard location >= 0 else { return nil }
        let safeLocation = min(location, maxLength)
        let safeLength = min(range.length, max(0, maxLength - safeLocation))
        return NSRange(location: safeLocation, length: safeLength)
    }

    private func adjustedLocationAfterReplacement(
        _ location: Int,
        replaceRange: NSRange,
        replacementLength: Int,
        maxLength: Int
    ) -> Int {
        if location < replaceRange.location {
            return min(maxLength, max(0, location))
        }
        let replaceEnd = replaceRange.location + replaceRange.length
        if location >= replaceEnd {
            let replacementDelta = replacementLength - replaceRange.length
            return min(maxLength, max(0, location + replacementDelta))
        }

        guard replaceRange.length > 0, replacementLength > 0 else {
            return min(maxLength, max(0, replaceRange.location))
        }

        // Preserve relative position when anchor/caret lands inside replaced region.
        // This avoids snapping to the start of the promoted chunk, which causes visible
        // viewport jumps during staged catch-up.
        let relative = Double(location - replaceRange.location) / Double(replaceRange.length)
        let mappedOffset = Int((relative * Double(replacementLength)).rounded())
        let mappedLocation = replaceRange.location + mappedOffset
        return min(maxLength, max(0, mappedLocation))
    }

    private func stagedPromotionContextStartUTF16(markdown: String, renderedUTF16Count: Int) -> Int {
        let ns = markdown as NSString
        guard renderedUTF16Count > 0, ns.length > 0 else { return 0 }
        let contextChars = stagedPromotionContextCharsValue()
        let minStart = max(0, renderedUTF16Count - contextChars)
        let searchRange = NSRange(location: minStart, length: renderedUTF16Count - minStart)
        let lineBreak = ns.range(of: "\n", options: [.backwards], range: searchRange)
        if lineBreak.location != NSNotFound {
            return min(renderedUTF16Count, lineBreak.location + lineBreak.length)
        }
        return 0
    }

    private func stagedPromotionContextCharsValue() -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_CONTEXT_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return stagedPromotionContextChars
    }

    private func stagedPromotionDebounceMsValue() -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_DEBOUNCE_MS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return stagedPromotionDebounceMs
    }

    private func stagedPromotionStepCharsValue(useTurbo: Bool) -> Int {
        if useTurbo,
           let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_TURBO_STEP_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_STEP_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        return useTurbo ? stagedPromotionTurboStepChars : stagedPromotionStepChars
    }

    private func stagedPromotionMaxCatchupStepCharsValue(useTurbo: Bool) -> Int {
        if useTurbo,
           let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_TURBO_MAX_CATCHUP_STEP_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        return useTurbo ? stagedPromotionTurboMaxCatchupStepChars : stagedPromotionMaxCatchupStepChars
    }

    private func stagedPromotionViewportGuardCharsValue() -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_VIEWPORT_GUARD_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return stagedPromotionViewportGuardChars
    }

    private func stagedPromotionViewportMicroStepCharsValue(
        useTurbo: Bool,
        sinceInteraction: TimeInterval? = nil,
        sinceScroll: TimeInterval? = nil
    ) -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_VIEWPORT_MICRO_STEP_CHARS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        let maxChars = useTurbo ? stagedPromotionTurboViewportMicroStepMaxChars : stagedPromotionViewportMicroStepMaxChars
        let baseline = max(
            stagedPromotionViewportMicroStepMinChars,
            min(stagedAdaptiveViewportMicroStepChars, maxChars)
        )
        guard
            let sinceInteraction,
            let sinceScroll
        else {
            return baseline
        }

        // Spinner prevention: immediately after scroll/input, keep promotion slices tiny so
        // parse+apply work cannot monopolize the main thread.
        if sinceScroll < 0.35 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_micro_cap_tight_count")
            return min(baseline, 64_000)
        }
        if sinceScroll < 0.9 {
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_micro_cap_medium_count")
            return min(baseline, 128_000)
        }
        if useTurbo, sinceInteraction > 2.5, sinceScroll > 2.5 {
            // Fully idle catch-up mode: allow larger slices only when the user has been
            // inactive for a sustained interval, so full-fidelity completion does not drag.
            let idleBoosted = min(maxChars, max(baseline, Int(Double(baseline) * 1.35)))
            WowInternalMetricsRecorder.shared.incrementAuxCounter("wow_staged_promotion_micro_cap_idle_boost_count")
            return idleBoosted
        }
        return baseline
    }

    private func stagedPromotionFrameBudgetMsValue() -> Double {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_FRAME_BUDGET_MS"],
           let parsed = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        return stagedPromotionFrameBudgetMs
    }

    private func stagedPromotionMaxViewportCorrectionPxValue() -> CGFloat {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_MAX_VIEWPORT_CORRECTION_PX"],
           let parsed = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return CGFloat(parsed)
        }
        return stagedPromotionMaxViewportCorrectionPx
    }

    private func stagedPromotionJumpMetricThresholdPxValue() -> CGFloat {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_JUMP_THRESHOLD_PX"],
           let parsed = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return CGFloat(parsed)
        }
        return stagedPromotionJumpMetricThresholdPx
    }

    private func resetAdaptiveStagedPromotionBudget() {
        stagedAdaptiveViewportMicroStepChars = stagedPromotionViewportMicroStepChars
    }

    private func tuneAdaptiveStagedPromotionBudget(lastApplyMs: Double, lastParseMs: Double, useTurbo: Bool) {
        guard stagedPromotionsAllowed else { return }
        let frameBudgetMs = stagedPromotionFrameBudgetMsValue()
        let overHardApplyBudget: Bool
        let overSoftApplyBudget: Bool
        let overHardParseBudget: Bool
        let overSoftParseBudget: Bool
        let growthApplyThreshold: Double
        let growthParseThreshold: Double
        let growthMultiplier: Double
        if useTurbo {
            // In turbo mode we are intentionally catching up large unseen regions.
            // Allow larger slices before backing off so full-fidelity completion does not stall.
            overHardApplyBudget = lastApplyMs > max(42.0, frameBudgetMs * 10.0)
            overSoftApplyBudget = lastApplyMs > max(24.0, frameBudgetMs * 6.0)
            overHardParseBudget = lastParseMs > 300.0
            overSoftParseBudget = lastParseMs > 180.0
            growthApplyThreshold = max(12.0, frameBudgetMs * 3.0)
            growthParseThreshold = 120.0
            growthMultiplier = 1.08
        } else {
            overHardApplyBudget = lastApplyMs > max(16.0, frameBudgetMs * 4.0)
            overSoftApplyBudget = lastApplyMs > max(8.0, frameBudgetMs * 2.0)
            overHardParseBudget = lastParseMs > 200.0
            overSoftParseBudget = lastParseMs > 120.0
            growthApplyThreshold = max(2.0, frameBudgetMs * 0.65)
            growthParseThreshold = 80.0
            growthMultiplier = 1.12
        }
        let floorChars = stagedPromotionViewportMicroStepMinChars
        var next = stagedAdaptiveViewportMicroStepChars
        if overHardParseBudget {
            next = Int(Double(next) * 0.72)
        } else if overHardApplyBudget || lastApplyMs > 50 {
            next = Int(Double(next) * 0.8)
        } else if overSoftParseBudget {
            next = Int(Double(next) * 0.84)
        } else if overSoftApplyBudget {
            next = Int(Double(next) * 0.9)
        } else if lastApplyMs < growthApplyThreshold, lastParseMs < growthParseThreshold {
            next = Int(Double(next) * growthMultiplier)
        } else {
            return
        }
        let maxChars = useTurbo ? stagedPromotionTurboViewportMicroStepMaxChars : stagedPromotionViewportMicroStepMaxChars
        stagedAdaptiveViewportMicroStepChars = max(
            max(stagedPromotionViewportMicroStepMinChars, floorChars),
            min(next, maxChars)
        )
    }

    private func stagedPromotionIdleQuietPeriodMsValue() -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_IDLE_QUIET_MS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return stagedPromotionIdleQuietPeriodMs
    }

    private func stagedPromotionScrollQuietPeriodMsValue() -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_SCROLL_QUIET_MS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return stagedPromotionScrollQuietPeriodMs
    }

    private func stagedPromotionFollowupDelayMsValue(useTurbo: Bool) -> Int {
        if useTurbo,
           let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_TURBO_FOLLOWUP_DELAY_MS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return useTurbo ? stagedPromotionTurboFollowupDelayMs : stagedPromotionFollowupDelayMs
    }

    private func shouldUseTurboStagedPromotion(sinceInteraction: TimeInterval, sinceScroll: TimeInterval) -> Bool {
        let thresholdMs: Int = {
            if let raw = ProcessInfo.processInfo.environment["KERN_STAGED_PROMOTION_TURBO_IDLE_MS"],
               let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               parsed >= 0 {
                return parsed
            }
            return stagedPromotionTurboActivateIdleMs
        }()
        let thresholdSeconds = Double(thresholdMs) / 1_000.0
        return sinceInteraction >= thresholdSeconds && sinceScroll >= thresholdSeconds
    }

    private func scheduleStagedPromotionLayoutRefresh(markdown: String, immediate: Bool = false) {
        stagedPromotionLayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.adjustDocumentViewHeightToContent(forceFullLayout: false)
            self.scheduleLargeDocumentLightLayoutIfNeeded(markdown: markdown)
        }
        stagedPromotionLayoutWorkItem = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(stagedPromotionLayoutCoalesceMs),
                execute: work
            )
        }
    }

    private func scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: Int? = nil) {
        guard stagedPromotionsAllowed else { return }
        guard stagedRenderGeneration == renderGeneration else { return }
        guard deferredFullRenderWorkItem == nil else { return }
        guard !hasUnexportedChanges else { return }

        stagedPromotionWorkItem?.cancel()
        stagedPromotionToken &+= 1
        let token = stagedPromotionToken
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: 20)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let sinceInteraction = now - self.lastUserInteractionUptime
            let sinceScroll = self.secondsSinceLastUserScroll(at: now)
            let quietSeconds = Double(self.stagedPromotionIdleQuietPeriodMsValue()) / 1_000.0
            let scrollQuietSeconds = Double(self.stagedPromotionScrollQuietPeriodMsValue()) / 1_000.0
            let scrollIsQuiet = (sinceScroll ?? .greatestFiniteMagnitude) >= scrollQuietSeconds
            if sinceInteraction < quietSeconds || !scrollIsQuiet {
                let quietRemainingMs = max(0, Int(ceil((quietSeconds - sinceInteraction) * 1_000.0)))
                let scrollRemainingMs = max(
                    0,
                    Int(ceil((scrollQuietSeconds - (sinceScroll ?? scrollQuietSeconds)) * 1_000.0))
                )
                let retryDelayMs = max(20, max(quietRemainingMs, scrollRemainingMs))
                self.scheduleStagedPromotionFollowupIfNeeded(delayOverrideMs: retryDelayMs)
                return
            }
            self.applyNextStagedViewportPromotion(token: token)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let sinceInteraction = now - lastUserInteractionUptime
        let sinceScroll = secondsSinceLastUserScroll(at: now) ?? .greatestFiniteMagnitude
        let useTurbo = shouldUseTurboStagedPromotion(
            sinceInteraction: sinceInteraction,
            sinceScroll: sinceScroll
        )
        var followupDelayMs = max(4, delayOverrideMs ?? stagedPromotionFollowupDelayMsValue(useTurbo: useTurbo))
        if sinceScroll < 0.35 {
            followupDelayMs = max(followupDelayMs, 60)
        }
        if sinceScroll < 1.2 {
            if lastStagedPromotionApplyMs > 33 {
                followupDelayMs = max(followupDelayMs, 40)
            } else if lastStagedPromotionApplyMs > 16 {
                followupDelayMs = max(followupDelayMs, 25)
            }
        }
        stagedPromotionWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(followupDelayMs),
            execute: work
        )
    }

    private func estimatedMarkdownUTF16CatchupTarget(
        visibleDisplayEnd: Int,
        renderedDisplayBoundary: Int,
        renderedMarkdownUTF16Count: Int,
        totalMarkdownUTF16Count: Int,
        useTurbo: Bool
    ) -> Int {
        guard visibleDisplayEnd > renderedDisplayBoundary else {
            return min(totalMarkdownUTF16Count, renderedMarkdownUTF16Count + stagedPromotionStepCharsValue(useTurbo: useTurbo))
        }
        let overflowDisplayChars = visibleDisplayEnd - renderedDisplayBoundary
        let desired = renderedMarkdownUTF16Count +
            overflowDisplayChars +
            stagedPromotionLookaheadVisibleChars +
            stagedPromotionStepCharsValue(useTurbo: useTurbo)
        return min(totalMarkdownUTF16Count, max(renderedMarkdownUTF16Count, desired))
    }

    private func scheduleCodeBlockChromeUpdateForScrollIfNeeded() {
        let textLength = textView.textStorage?.length ?? 0
        guard textLength > scrollChromeThrottleCharThreshold else {
            updateCodeBlockChrome()
            return
        }
        scrollChromeUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateCodeBlockChrome()
        }
        scrollChromeUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(scrollChromeThrottleDelayMs), execute: work)
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

        let textLength = storage.length
        let optimizeForLargeDocument = textLength > scrollChromeThrottleCharThreshold
        let visibleCharacterRange: NSRange? = {
            guard optimizeForLargeDocument else { return nil }
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
            return visibleCharacterRangeForChrome(layoutManager: lm, textContainer: tc)
        }()

        let selection = textView.selectedRange()
        let caretProbe: Int = {
            guard textLength > 0 else { return 0 }
            return min(max(0, selection.location), textLength - 1)
        }()
        let shouldResolveCaretRange: Bool = {
            guard optimizeForLargeDocument, selection.length == 0 else { return true }
            guard let visibleCharacterRange else { return true }
            return NSLocationInRange(caretProbe, visibleCharacterRange)
        }()

        let hoverRange: NSRange? = {
            guard let hover = validatedHoverCodeBlockRange(in: storage) else { return nil }
            guard let visibleCharacterRange else { return hover }
            return NSIntersectionRange(hover, visibleCharacterRange).length > 0 ? hover : nil
        }()
        let caretRange: NSRange? = shouldResolveCaretRange ? caretCodeBlockRange(in: storage, selection: selection) : nil

        if optimizeForLargeDocument, hoverRange == nil, caretRange == nil {
            caretCodeBlockChrome.isHidden = true
            hoverCodeBlockChrome.isHidden = true
            caretCodeCopyCharacterRange = nil
            hoverCodeCopyCharacterRange = nil
            return
        }

        // If hover and caret are the same code block, show only the caret chrome.
        let effectiveHoverRange: NSRange? = rangesEqual(hoverRange, caretRange) ? nil : hoverRange

        updateCodeBlockChromeOverlay(
            chrome: caretCodeBlockChrome,
            for: caretRange,
            storage: storage,
            visibleCharacterRange: visibleCharacterRange,
            copyRange: &caretCodeCopyCharacterRange,
            lastBackgroundRect: &caretLastCodeBlockBackgroundRect
        )

        updateCodeBlockChromeOverlay(
            chrome: hoverCodeBlockChrome,
            for: effectiveHoverRange,
            storage: storage,
            visibleCharacterRange: visibleCharacterRange,
            copyRange: &hoverCodeCopyCharacterRange,
            lastBackgroundRect: &hoverLastCodeBlockBackgroundRect
        )
    }

    private func visibleCharacterRangeForChrome(layoutManager lm: NSLayoutManager, textContainer tc: NSTextContainer) -> NSRange {
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        return lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    private func handleCodeBlockHoverRangeChanged(_ range: NSRange?) {
        pendingHoverChromeClearWorkItem?.cancel()

        if let range {
            lastStableHoverCodeBlockRange = range
            hoveredCodeBlockRange = range
            updateCodeBlockChrome()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.hoverChromePointerInside else {
                if self.hoveredCodeBlockRange == nil, let stable = self.lastStableHoverCodeBlockRange {
                    self.hoveredCodeBlockRange = stable
                    self.updateCodeBlockChrome()
                }
                return
            }
            self.hoveredCodeBlockRange = nil
            self.updateCodeBlockChrome()
        }
        pendingHoverChromeClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(hoverChromeClearDelayMs), execute: work)
    }

    private func handleHoverChromePointerInsideChanged(_ inside: Bool) {
        hoverChromePointerInside = inside

        if inside {
            pendingHoverChromeClearWorkItem?.cancel()
            if hoveredCodeBlockRange == nil, let stable = lastStableHoverCodeBlockRange {
                hoveredCodeBlockRange = stable
                updateCodeBlockChrome()
            }
            return
        }

        guard textView.currentHoverCodeBlockRange == nil else { return }
        handleCodeBlockHoverRangeChanged(nil)
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
        visibleCharacterRange: NSRange?,
        copyRange: inout NSRange?,
        lastBackgroundRect: inout NSRect?
    ) {
        guard let range, range.length > 0 else {
            chrome.isHidden = true
            copyRange = nil
            return
        }

        if let visibleCharacterRange, NSIntersectionRange(range, visibleCharacterRange).length == 0 {
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

        // Never truncate language names in the pill. If space is tight, the chrome can overflow the
        // code block's visual bounds, but the token should remain fully readable.
        chrome.maxLanguageWidth = nil

        let chromeSize = chrome.preferredSize()
        // Compute in the container coordinate space to avoid flipped-origin confusion.
        let bgRectInContainer = view.convert(bgRect, from: textView)
        let x = bgRectInContainer.maxX - CodeBlockChromeGeometry.chromeOverlayInsetX - chromeSize.width
        let y = bgRectInContainer.maxY + CodeBlockChromeGeometry.chromeOverlayTopOverflow - chromeSize.height

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
