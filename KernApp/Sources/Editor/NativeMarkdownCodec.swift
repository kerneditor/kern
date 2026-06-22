@preconcurrency import AppKit

/// Minimal Markdown <-> attributed string codec for the native editor prototype.
///
/// This is intentionally a prototype:
/// - It round-trips a small Markdown subset deterministically.
/// - It encodes semantics with custom attributes (kern.*) so export is reliable.
/// - It does not aim for full CommonMark/GFM compliance yet.
enum NativeMarkdownCodec {
    struct ReferenceDefinition: Sendable {
        let id: String
        let destination: String
        let title: String?
    }

    /// Import-time context passed through the call chain instead of static mutable state.
    private struct ImportContext {
        let referenceDefinitions: [String: ReferenceDefinition]
        let referenceDefinitionsSignature: Int
        let baseURL: URL?
        let baseURLSignature: String
        let options: Options
        let strictConformanceRoundTripMode: Bool
        let syntaxHighlightingEnabled: Bool
        let inlineParseCache: InlineParseCache?
        let themeSignature: String
        let profiler: ImportProfiler?
    }

    enum ImportProfilePhase: String, CaseIterable, Codable, Sendable {
        case normalizeLineEndings
        case lineSplit
        case referenceDefinitionScan
        case importLoop
        case paragraphFastPathBlock
        case paragraphFallbackBlock
        case referenceDefinitionBlock
        case mathBlock
        case fencedCodeBlock
        case mermaidBlock
        case indentedCodeBlock
        case gfmTableBlock
        case thematicBreakBlock
        case atxHeadingBlock
        case setextHeadingBlock
        case taskListBlock
        case orderedTaskBlock
        case orderedListBlock
        case bulletListBlock
        case inlineParse
        case parseGfmTable
        case makeCodeBlockAttributed
        case makeMermaidAttachmentAttributed
        case makeBlockMathAttributed
        case makeGfmTableAttributed
        case makeImageAttachmentAttributed
        case applySyntaxHighlighting
    }

    struct ImportProfileSnapshot: Codable, Sendable {
        let markdownUTF16Count: Int
        let lineCount: Int
        let phaseDurationsMs: [String: Double]
        let phaseCounts: [String: Int]
        let totalInlineUTF16: Int
        let maxInlineUTF16: Int
    }

    struct ProfiledImportResult {
        let attributed: NSAttributedString
        let profile: ImportProfileSnapshot
    }

    final class ImportProfiler {
        private var markdownUTF16Count: Int = 0
        private var lineCount: Int = 0
        private var phaseDurationsNs: [ImportProfilePhase: UInt64] = [:]
        private var phaseCounts: [ImportProfilePhase: Int] = [:]
        private var totalInlineUTF16: Int = 0
        private var maxInlineUTF16: Int = 0
        private var inlineParseDepth: Int = 0

        func setMarkdownUTF16Count(_ count: Int) {
            markdownUTF16Count = max(0, count)
        }

        func setLineCount(_ count: Int) {
            lineCount = max(0, count)
        }

        @discardableResult
        func measure<T>(_ phase: ImportProfilePhase, _ body: () -> T) -> T {
            phaseCounts[phase, default: 0] += 1
            let start = DispatchTime.now().uptimeNanoseconds
            let result = body()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            phaseDurationsNs[phase, default: 0] += elapsed
            return result
        }

        func recordInlineUTF16(_ count: Int) {
            let clamped = max(0, count)
            totalInlineUTF16 += clamped
            maxInlineUTF16 = max(maxInlineUTF16, clamped)
        }

        @discardableResult
        func measureInlineParse<T>(utf16Count: Int, _ body: () -> T) -> T {
            let isOutermost = inlineParseDepth == 0
            if isOutermost {
                recordInlineUTF16(utf16Count)
                phaseCounts[.inlineParse, default: 0] += 1
            }
            inlineParseDepth += 1
            let start = isOutermost ? DispatchTime.now().uptimeNanoseconds : 0
            let result = body()
            inlineParseDepth -= 1
            if isOutermost {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                phaseDurationsNs[.inlineParse, default: 0] += elapsed
            }
            return result
        }

        func snapshot() -> ImportProfileSnapshot {
            let durationsMs = phaseDurationsNs.reduce(into: [String: Double]()) { partial, entry in
                partial[entry.key.rawValue] = Double(entry.value) / 1_000_000
            }
            let counts = phaseCounts.reduce(into: [String: Int]()) { partial, entry in
                partial[entry.key.rawValue] = entry.value
            }
            return ImportProfileSnapshot(
                markdownUTF16Count: markdownUTF16Count,
                lineCount: lineCount,
                phaseDurationsMs: durationsMs,
                phaseCounts: counts,
                totalInlineUTF16: totalInlineUTF16,
                maxInlineUTF16: maxInlineUTF16
            )
        }
    }

    private final class InlineParseCache: @unchecked Sendable {
        private let maxEntries: Int
        private let maxApproximateUTF16Cost: Int
        private let lock = NSLock()
        private var storage: [InlineParseCacheKey: NSAttributedString] = [:]
        private var storageCosts: [InlineParseCacheKey: Int] = [:]
        private var totalApproximateUTF16Cost: Int = 0

        init(maxEntries: Int, maxApproximateUTF16Cost: Int) {
            self.maxEntries = max(128, maxEntries)
            self.maxApproximateUTF16Cost = max(262_144, maxApproximateUTF16Cost)
        }

        func value(for key: InlineParseCacheKey) -> NSAttributedString? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func insert(_ value: NSAttributedString, for key: InlineParseCacheKey) {
            lock.lock()
            defer { lock.unlock() }
            let approximateCost = key.text.utf16.count + value.length
            if let existingCost = storageCosts[key] {
                totalApproximateUTF16Cost = max(0, totalApproximateUTF16Cost - existingCost)
            } else if storage.count >= maxEntries
                        || totalApproximateUTF16Cost + approximateCost > maxApproximateUTF16Cost {
                storage.removeAll(keepingCapacity: true)
                storageCosts.removeAll(keepingCapacity: true)
                totalApproximateUTF16Cost = 0
            }
            storage[key] = value
            storageCosts[key] = approximateCost
            totalApproximateUTF16Cost += approximateCost
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll(keepingCapacity: true)
            storageCosts.removeAll(keepingCapacity: true)
            totalApproximateUTF16Cost = 0
        }
    }

    private final class CodeBlockAttributedCache: @unchecked Sendable {
        private let maxEntries: Int
        private let lock = NSLock()
        private var storage: [CodeBlockAttributedCacheKey: NSAttributedString] = [:]

        init(maxEntries: Int) {
            self.maxEntries = max(64, maxEntries)
        }

        func value(for key: CodeBlockAttributedCacheKey) -> NSAttributedString? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func insert(_ value: NSAttributedString, for key: CodeBlockAttributedCacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if storage[key] == nil, storage.count >= maxEntries {
                storage.removeAll(keepingCapacity: true)
            }
            storage[key] = value
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll(keepingCapacity: true)
        }
    }

    private final class TableAttributedCache: @unchecked Sendable {
        private let maxEntries: Int
        private let lock = NSLock()
        private var storage: [TableAttributedCacheKey: NSAttributedString] = [:]

        init(maxEntries: Int) {
            self.maxEntries = max(32, maxEntries)
        }

        func value(for key: TableAttributedCacheKey) -> NSAttributedString? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func insert(_ value: NSAttributedString, for key: TableAttributedCacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if storage[key] == nil, storage.count >= maxEntries {
                storage.removeAll(keepingCapacity: true)
            }
            storage[key] = value
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll(keepingCapacity: true)
        }
    }

    /// Shared inline parse cache reused across import passes (including staged promotions).
    /// This preserves hot repeated fragments (e.g. emphasis/link patterns in benchmark fixtures)
    /// across successive slice imports instead of rewarming from empty each pass.
    private static let sharedInlineParseCache = InlineParseCache(
        maxEntries: 18_000,
        maxApproximateUTF16Cost: 8_000_000
    )
    /// Shared code-block attributed cache reused across import passes.
    /// This is most valuable for large fixtures with repeated fenced blocks or repeated staged-promotion imports.
    private static let sharedCodeBlockAttributedCache = CodeBlockAttributedCache(maxEntries: 512)
    /// Shared table attributed cache reused across import passes.
    /// This is most valuable when large fixtures contain repeated identical table blocks.
    private static let sharedTableAttributedCache = TableAttributedCache(maxEntries: 256)

    @inline(__always)
    private static func measureImportPhase<T>(
        _ phase: ImportProfilePhase,
        profiler: ImportProfiler?,
        _ body: () -> T
    ) -> T {
        guard let profiler else { return body() }
        return profiler.measure(phase, body)
    }

    private static func inlineParseCacheMaxUTF16(for style: InlineStyle) -> Int {
        if let raw = ProcessInfo.processInfo.environment["KERN_INLINE_PARSE_CACHE_MAX_UTF16"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0
        {
            return parsed
        }
        _ = style
        return 384
    }

    static func inlineParseCacheMaxUTF16ForTesting() -> Int {
        inlineParseCacheMaxUTF16(for: InlineStyle())
    }

    struct Options: Equatable, Sendable {
        enum ExportDialect: String, Sendable {
            case gfm
            case kern
        }

        enum GfmExtensionExportStrategy: String, Sendable {
            /// Preserve Kern extension syntaxes even when exporting in GFM mode (default).
            /// This maximizes Kern round-trip fidelity.
            case preserve
            /// Avoid exporting Kern extension syntaxes when in GFM mode, preferring plain text
            /// representations that are more portable across non-Kern renderers.
            case portable
            /// Rewrite extension syntaxes into more widely-supported Markdown patterns, even if it changes
            /// block structure (ex: checkbox headings become task list items). Useful as a "lint" mode
            /// before uploading to other tools.
            case lint
        }

        enum TaskRendering: String, Sendable {
            /// Checkbox-only task rendering (GitHub-like).
            case gfm
            /// Bulleted task items render as bullet dot + checkbox (`• ☐ ...`).
            case kern
        }

        enum OrderedListNumbering: String, Sendable {
            /// Preserve the typed numeric markers on import and export.
            case preserveTyped
            /// Follow GFM semantics: only the first marker matters; subsequent items may be normalized.
            case gfmDefault
        }

        enum MermaidRenderMode: String, Sendable {
            /// Always render Mermaid using the rich native diagram renderer.
            case rich
            /// Always render Mermaid using the lightweight ASCII renderer.
            case ascii
            /// Automatically choose a mode based on diagram complexity.
            case auto
            /// Prefer the optional official Mermaid external renderer when an async cached result exists.
            /// Falls back to the native rich renderer until that renderer/cache path is available.
            case officialExternal
        }

        /// Export `.md` as pure GFM (default) or preserve Kern extensions where possible.
        var exportDialect: ExportDialect = .gfm
        /// When exporting in GFM mode, choose whether Kern extension syntaxes are preserved, made more portable,
        /// or rewritten ("lint") into widely-supported Markdown patterns.
        var gfmExtensionExportStrategy: GfmExtensionExportStrategy = .preserve
        /// How tasks render in the editor (does not affect exported syntax).
        var taskRendering: TaskRendering = .gfm
        /// Treat `1. [ ] text` as an ordered task (Kern preference) instead of literal text.
        var orderedTasksEnabled: Bool = false
        /// Treat `## [ ] Heading` as a checkbox heading (Kern preference) instead of literal text.
        var headingCheckboxesEnabled: Bool = false
        /// Ordered list numbering behavior for import/export.
        var orderedListNumbering: OrderedListNumbering = .gfmDefault
        /// Enable remote image loading for image attachments (local file images always load).
        var remoteImageLoadingEnabled: Bool = false
        /// Enable syntax highlighting for fenced code blocks.
        var syntaxHighlightingEnabled: Bool = true
        /// Mermaid render mode for fenced mermaid blocks.
        var mermaidRenderMode: MermaidRenderMode = .rich
        /// For very large files, prefer a plain-text fast path during import to keep first-open latency low.
        /// This can defer rich Markdown styling fidelity in exchange for responsiveness.
        var largeDocumentPlainImportEnabled: Bool = false
        /// Strict round-trip mode for spec conformance harnesses.
        /// This keeps inline source literals intact and disables marker rewrites that can
        /// otherwise alter semantics in edge-case CommonMark examples.
        var strictConformanceRoundTripMode: Bool = false
        /// Export paragraph/heading/thematic blocks with blank-line separators (`\n\n`) while keeping
        /// tight list runs joined by single newlines. This aligns Enter behavior with WYSIWYG paragraph
        /// expectations in modern markdown editors.
        var paragraphBlockSeparationEnabled: Bool = true

        static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> Options {
            var opt = Options()
            if let raw = defaults.string(forKey: "nativeEditor.exportDialect"),
               let v = ExportDialect(rawValue: raw) {
                opt.exportDialect = v
            }
            if let raw = defaults.string(forKey: "nativeEditor.gfmExtensionExportStrategy"),
               let v = GfmExtensionExportStrategy(rawValue: raw) {
                opt.gfmExtensionExportStrategy = v
            } else if let raw = defaults.string(forKey: "nativeEditor.gfmExtensionExportStrategy"),
                      raw == "degrade" {
                // Back-compat: the previous name for `.portable`.
                opt.gfmExtensionExportStrategy = .portable
            }
            if let raw = defaults.string(forKey: "nativeEditor.taskRendering"),
               let v = TaskRendering(rawValue: raw) {
                opt.taskRendering = v
            }
            if defaults.object(forKey: "nativeEditor.orderedTasksEnabled") != nil {
                opt.orderedTasksEnabled = defaults.bool(forKey: "nativeEditor.orderedTasksEnabled")
            }
            if defaults.object(forKey: "nativeEditor.headingCheckboxesEnabled") != nil {
                opt.headingCheckboxesEnabled = defaults.bool(forKey: "nativeEditor.headingCheckboxesEnabled")
            }
            if let raw = defaults.string(forKey: "nativeEditor.orderedListNumbering"),
               let v = OrderedListNumbering(rawValue: raw) {
                opt.orderedListNumbering = v
            }
            if defaults.object(forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey) != nil {
                opt.remoteImageLoadingEnabled = defaults.bool(forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)
            }
            if defaults.object(forKey: "nativeEditor.syntaxHighlightingEnabled") != nil {
                opt.syntaxHighlightingEnabled = defaults.bool(forKey: "nativeEditor.syntaxHighlightingEnabled")
            }
            if let raw = defaults.string(forKey: "nativeEditor.mermaidRenderMode"),
               let v = MermaidRenderMode(rawValue: raw) {
                opt.mermaidRenderMode = v
            }
            if defaults.object(forKey: "nativeEditor.paragraphBlockSeparationEnabled") != nil {
                opt.paragraphBlockSeparationEnabled = defaults.bool(forKey: "nativeEditor.paragraphBlockSeparationEnabled")
            }
            // Intentionally ignore persisted large-document plain-import preference.
            // Legacy sessions could leave this enabled and force degraded non-WYSIWYG opens.
            // Plain import remains available only via explicit benchmark/test env override:
            //   KERN_FORCE_PLAIN_MARKDOWN_IMPORT=1
            //   KERN_ALLOW_PLAIN_IMPORT_OVERRIDE=1
            return opt
        }
    }

    static func importMarkdown(
        _ markdown: String,
        options: Options = Options(),
        baseURL: URL? = nil,
        precomputedReferenceDefinitions: [String: ReferenceDefinition]? = nil,
        profiler: ImportProfiler? = nil
    ) -> NSAttributedString {
        @inline(__always)
        func profile<T>(_ phase: ImportProfilePhase, _ body: () -> T) -> T {
            measureImportPhase(phase, profiler: profiler, body)
        }

        let markdown = profile(.normalizeLineEndings) {
            normalizeLineEndings(markdown)
        }
        let baseFont = NativeEditorAppearance.baseFont()
        let defaultBaseAttributes = baseAttributes(baseFont: baseFont)
        let plainNewline = NSAttributedString(string: "\n", attributes: defaultBaseAttributes)
        let markdownLength = markdown.utf16.count
        profiler?.setMarkdownUTF16Count(markdownLength)
        if shouldUseLargeDocumentPlainImport(options: options, markdownLength: markdownLength) {
            return makeLargeDocumentPlainAttributed(markdown: markdown, baseFont: baseFont)
        }
        let inputEndsWithNewline = markdown.hasSuffix("\n")
        let result = NSMutableAttributedString()

        // Preserve empty lines by splitting with omittingEmptySubsequences=false.
        let lines = profile(.lineSplit) {
            markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        profiler?.setLineCount(lines.count)
        let referenceDefinitions = precomputedReferenceDefinitions ?? profile(.referenceDefinitionScan) {
            collectReferenceDefinitions(lines: lines)
        }
        let syntaxHighlightingEnabled = shouldEnableSyntaxHighlighting(
            options: options,
            markdownLength: markdownLength
        )
        let inlineParseCache: InlineParseCache? = {
            // Large fixtures contain repeated inline-dense fragments. Reusing one cache across
            // staged imports avoids rewarming the same entries for every promotion slice.
            guard markdownLength >= 100_000 else { return nil }
            if ProcessInfo.processInfo.environment["KERN_DISABLE_INLINE_PARSE_CACHE"] == "1" {
                return nil
            }
            return sharedInlineParseCache
        }()
        let ctx = ImportContext(
            referenceDefinitions: referenceDefinitions,
            referenceDefinitionsSignature: inlineCacheReferenceDefinitionsSignature(referenceDefinitions),
            baseURL: baseURL,
            baseURLSignature: inlineCacheBaseURLSignature(baseURL),
            options: options,
            strictConformanceRoundTripMode: options.strictConformanceRoundTripMode,
            syntaxHighlightingEnabled: syntaxHighlightingEnabled,
            inlineParseCache: inlineParseCache,
            themeSignature: NativeEditorAppearance.appearanceCacheSignature(),
            profiler: profiler
        )

        // For GFM-style ordered list semantics, only the first marker matters and the rest are
        // normalized sequentially. Track per-depth counters so nested ordered lists restart.
        var orderedCountersByDepth: [Int] = []

        func resetOrderedCounters() {
            orderedCountersByDepth.removeAll(keepingCapacity: true)
        }

        func nextOrderedIndexGfmDefault(parsedIndex: Int, depth: Int) -> Int {
            let d = max(0, depth)
            if d < orderedCountersByDepth.count {
                orderedCountersByDepth = Array(orderedCountersByDepth.prefix(d + 1))
            } else if d >= orderedCountersByDepth.count {
                while orderedCountersByDepth.count < d { orderedCountersByDepth.append(1) }
                orderedCountersByDepth.append(parsedIndex)
            }
            let out = orderedCountersByDepth[d]
            orderedCountersByDepth[d] = out + 1
            return out
        }

        struct CollectedContinuationBody {
            let combined: String
            let nextIndex: Int
            let containsInlineSyntax: Bool
        }

        func makeInlineContent(_ body: CollectedContinuationBody, baseFont: NSFont) -> NSAttributedString {
            if !ctx.strictConformanceRoundTripMode, !body.containsInlineSyntax {
                return makeInlineAttributed(body.combined, baseFont: baseFont, style: InlineStyle())
            }
            return parseInline(body.combined, baseFont: baseFont, ctx: ctx)
        }

        func collectParagraphBody(startIndex: Int, firstLine line: String, quoteDepth: Int) -> CollectedContinuationBody {
            let nextIndex = startIndex + 1
            let (firstLine, initialHardBreak) = stripHardBreakMarker(line, ctx: ctx)
            var pendingHardBreak = initialHardBreak
            var continuationBuilder = ContinuationTextBuilder(initial: firstLine, kind: .paragraph)
            var j = nextIndex
            while j < lines.count {
                guard let nextLine = paragraphContinuationText(at: j, quoteDepth: quoteDepth) else { break }

                let (nextText, nextHardBreak) = stripHardBreakMarker(nextLine, ctx: ctx)
                continuationBuilder.append(nextText, pendingHardBreak: pendingHardBreak)
                pendingHardBreak = nextHardBreak
                j += 1
            }

            let built = continuationBuilder.build(finalHardBreak: pendingHardBreak)
            return CollectedContinuationBody(combined: built.text, nextIndex: j, containsInlineSyntax: built.containsInlineSyntax)
        }

        func collectListBody(startIndex: Int, firstLine line: String, continuationIndent: Int) -> CollectedContinuationBody {
            let (firstLine, initialHardBreak) = stripHardBreakMarker(line, ctx: ctx)
            var pendingHardBreak = initialHardBreak
            let continuationIndentPrefix = String(repeating: " ", count: max(0, continuationIndent))
            var continuationBuilder = ContinuationTextBuilder(initial: firstLine, kind: .list)
            var j = startIndex + 1
            while j < lines.count {
                let next = lines[j]
                guard next.hasPrefix(continuationIndentPrefix) else { break }
                let stripped = String(next.dropFirst(continuationIndentPrefix.count))

                if startsNestedBlockWithinListContinuation(stripped, options: options) {
                    break
                }

                let (nextText, nextHardBreak) = stripHardBreakMarker(stripped, ctx: ctx)
                continuationBuilder.append(nextText, pendingHardBreak: pendingHardBreak)
                pendingHardBreak = nextHardBreak
                j += 1
            }

            let built = continuationBuilder.build(finalHardBreak: pendingHardBreak)
            return CollectedContinuationBody(combined: built.text, nextIndex: j, containsInlineSyntax: built.containsInlineSyntax)
        }

        var tableCounter = 0
        var codeBlockCounter = 0
        var paragraphBoundaryCache: [ParagraphContinuationBoundaryCacheKey: Bool] = [:]
        var paragraphBoundaryCacheDefaultQuote = Array(repeating: UInt8(0), count: lines.count)

        @inline(__always)
        func paragraphContinuationLine(at index: Int, quoteDepth: Int) -> String? {
            guard index >= 0, index < lines.count else { return nil }
            var nextLine = lines[index]
            if quoteDepth > 0 {
                guard let q = parseBlockquotePrefix(nextLine), q.depth == quoteDepth else { return nil }
                nextLine = q.text
            }
            return nextLine
        }

        @inline(__always)
        func paragraphContinuationText(at index: Int, quoteDepth: Int) -> String? {
            if quoteDepth == 0, index >= 0, index < paragraphBoundaryCacheDefaultQuote.count {
                switch paragraphBoundaryCacheDefaultQuote[index] {
                case 1:
                    return nil
                case 2:
                    return lines[index]
                default:
                    break
                }
            }
            let cacheKey = ParagraphContinuationBoundaryCacheKey(lineIndex: index, quoteDepth: quoteDepth)
            if quoteDepth != 0, let cached = paragraphBoundaryCache[cacheKey], cached {
                return nil
            }

            guard let nextLine = paragraphContinuationLine(at: index, quoteDepth: quoteDepth) else {
                if quoteDepth == 0, index >= 0, index < paragraphBoundaryCacheDefaultQuote.count {
                    paragraphBoundaryCacheDefaultQuote[index] = 1
                } else {
                    paragraphBoundaryCache[cacheKey] = true
                }
                return nil
            }

            let isBoundary: Bool
            if isBlankMarkdownLine(nextLine) {
                isBoundary = true
            } else if mayStartStructuralBlockLine(nextLine) {
                var matched = false
                let first = nextLine.first
                switch first {
                case "[":
                    matched = parseReferenceDefinition(nextLine) != nil
                case "$":
                    matched = isMathBlockDelimiter(nextLine)
                case "`", "~":
                    matched = parseFenceStart(nextLine) != nil
                case "#":
                    matched = parseHeading(nextLine) != nil
                case "-", "*", "+":
                    matched = parseTask(nextLine) != nil
                        || parseBullet(nextLine) != nil
                        || parseThematicBreak(nextLine) != nil
                    if !matched, first == "-" {
                        matched = mayBeSetextUnderlineLine(nextLine) && parseSetextUnderline(nextLine) != nil
                    }
                case "_", "=":
                    matched = parseThematicBreak(nextLine) != nil
                        || (mayBeSetextUnderlineLine(nextLine) && parseSetextUnderline(nextLine) != nil)
                default:
                    if let first, first.isNumber {
                        matched = (options.orderedTasksEnabled && parseOrderedTask(nextLine) != nil)
                            || parseOrdered(nextLine) != nil
                    }
                }

                if !matched, nextLine.contains("|") {
                    matched = canStartGfmTable(lines, startIndex: index)
                        && parseGfmTable(lines, startIndex: index, profiler: nil) != nil
                }

                if !matched, canStartIndentedCode(lines, at: index, quoteDepth: quoteDepth) {
                    matched = parseIndentedCodeBlock(lines, startIndex: index, quoteDepth: quoteDepth) != nil
                }

                isBoundary = matched
            } else {
                isBoundary = false
            }

            if quoteDepth == 0, index >= 0, index < paragraphBoundaryCacheDefaultQuote.count {
                paragraphBoundaryCacheDefaultQuote[index] = isBoundary ? 1 : 2
            } else {
                paragraphBoundaryCache[cacheKey] = isBoundary
            }
            return isBoundary ? nil : nextLine
        }

        func isParagraphBoundary(at index: Int, quoteDepth: Int) -> Bool {
            paragraphContinuationText(at: index, quoteDepth: quoteDepth) == nil
        }

        var i = 0
        profile(.importLoop) {
            while i < lines.count {
                let rawLine = lines[i]
                let quote = parseBlockquotePrefix(rawLine)
                let quoteDepth = quote?.depth ?? 0
                let line = quote?.text ?? rawLine
                let isBlankLine = isBlankMarkdownLine(line)

            // Preserve an explicit empty blockquote line (`>` or `> `) as a blank line that still
            // round-trips with `>` on export.
            if quoteDepth > 0, isBlankLine {
                resetOrderedCounters()
                if i < lines.count - 1 {
                    var attrs = baseAttributes(baseFont: baseFont)
                    attrs[.kernQuoteDepth] = quoteDepth
                    result.append(NSAttributedString(string: "\n", attributes: attrs))
                }
                i += 1
                continue
            }

            // In Markdown, whitespace-only lines are blank lines.
            if isBlankLine {
                resetOrderedCounters()
                if i < lines.count - 1 {
                    result.append(plainNewline)
                }
                i += 1
                continue
            }

            // Kern extension: callout blockquotes, authored with the widely used admonition form:
            // > [!NOTE] Title
            // > Body
            if !options.strictConformanceRoundTripMode,
               quoteDepth > 0,
               let callout = parseCalloutMarker(line) {
                profile(.paragraphFallbackBlock) {
                    resetOrderedCounters()
                    let paragraphBody = collectParagraphBody(
                        startIndex: i,
                        firstLine: callout.text,
                        quoteDepth: quoteDepth
                    )
                    let j = paragraphBody.nextIndex
                    let para = NSMutableAttributedString(attributedString: makeCalloutParagraph(
                        kind: callout.kind,
                        text: paragraphBody.combined,
                        containsInlineSyntax: paragraphBody.containsInlineSyntax,
                        baseFont: baseFont,
                        ctx: ctx
                    ))
                    if let foldSuffix = callout.foldSuffix, para.length > 0 {
                        let firstParagraph = (para.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                        para.addAttribute(
                            .kernCalloutFoldSuffix,
                            value: foldSuffix,
                            range: NSRange(location: 0, length: min(para.length, firstParagraph.length))
                        )
                    }
                    applyQuoteAttributes(para, quoteDepth: quoteDepth)
                    result.append(para)
                    if j - 1 < lines.count - 1 {
                        result.append(plainNewline)
                    }
                    i = j
                }
                continue
            }

            // Fast path: overwhelmingly common paragraph lines in large documents.
            // Skip expensive block-detector chain when the current line cannot start
            // a non-paragraph block by marker shape.
            let shouldFastPathParagraph: Bool = {
                guard !mayStartStructuralBlockLine(line) else { return false }
                if i + 1 < lines.count {
                    var nextLine = lines[i + 1]
                    if quoteDepth > 0 {
                        // Setext detection requires same quote depth.
                        guard let q = parseBlockquotePrefix(nextLine), q.depth == quoteDepth else {
                            return true
                        }
                        nextLine = q.text
                    }
                    if mayBeSetextUnderlineLine(nextLine), parseSetextUnderline(nextLine) != nil {
                        return false
                    }
                }
                return true
                }()
                if shouldFastPathParagraph {
                    profile(.paragraphFastPathBlock) {
                        resetOrderedCounters()
                        let paragraphBody = collectParagraphBody(startIndex: i, firstLine: line, quoteDepth: quoteDepth)
                        let j = paragraphBody.nextIndex

                        let para = NSMutableAttributedString(attributedString: makeInlineContent(paragraphBody, baseFont: baseFont))
                        applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if j - 1 < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i = j
                    }
                    continue
                }

                // Reference definition: [id]: url "title"
                if let definition = parseReferenceDefinition(line) {
                    profile(.referenceDefinitionBlock) {
                        resetOrderedCounters()
                        let visible = definition.destination
                        let para = NSMutableAttributedString(attributedString: parseInline(visible, baseFont: baseFont, ctx: ctx))
                        applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
                        if para.length > 0 {
                            let full = NSRange(location: 0, length: para.length)
                            para.addAttribute(.kernReferenceDefinitionID, value: definition.id, range: full)
                            para.addAttribute(.kernReferenceDefinitionURL, value: definition.destination, range: full)
                            if let title = definition.title {
                                para.addAttribute(.kernReferenceDefinitionTitle, value: title, range: full)
                            }
                        }
                        if let ctx = previousListContinuationContext(lines, before: i, quoteDepth: quoteDepth), para.length > 0 {
                            para.addAttribute(.kernListIndent, value: max(0, ctx.indent), range: NSRange(location: 0, length: 1))
                            para.addAttribute(.kernListDepth, value: max(0, ctx.depth), range: NSRange(location: 0, length: 1))
                        }
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i += 1
                    }
                    continue
                }

                // Math block: $$ ... $$
                if isMathBlockDelimiter(line) {
                    profile(.mathBlock) {
                        resetOrderedCounters()

                        var mathLines: [String] = []
                        i += 1
                        while i < lines.count {
                            var nextLine = lines[i]
                            if quoteDepth > 0 {
                                guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                                nextLine = q.text
                            }
                            if isMathBlockDelimiter(nextLine) {
                                break
                            }
                            mathLines.append(nextLine)
                            i += 1
                        }

                        if i < lines.count {
                            var endLine = lines[i]
                            if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                                endLine = q.text
                            }
                            if isMathBlockDelimiter(endLine) {
                                i += 1
                            }
                        }

                        let mathBody = mathLines.joined(separator: "\n")
                        let sourceMarkdown = "$$\n\(mathBody)\n$$"
                        let para = NSMutableAttributedString(
                            attributedString: profile(.makeBlockMathAttributed) {
                                makeBlockMathAttributed(sourceMarkdown: sourceMarkdown, baseFont: baseFont)
                            }
                        )
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count {
                            result.append(plainNewline)
                        }
                    }
                    continue
                }

                // Code block (```lang ... ``` / ~~~lang ... ~~~)
                if let fenceContext = parseFenceStartInContext(line: line, lines: lines, index: i, quoteDepth: quoteDepth) {
                    let blockPhase: ImportProfilePhase = fenceContext.fence.language?.lowercased() == "mermaid" ? .mermaidBlock : .fencedCodeBlock
                    profile(blockPhase) {
                        resetOrderedCounters()
                        let blockStartIndex = i
                        let fence = fenceContext.fence
                        let listIndent = fenceContext.listIndent
                        let listIndentPrefix = listIndent > 0 ? String(repeating: " ", count: listIndent) : ""
                        var codeText = ""
                        var appendedCodeLine = false
                        i += 1
                        while i < lines.count {
                            var nextLine = lines[i]
                            if quoteDepth > 0 {
                                guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                                nextLine = q.text
                            }
                            if listIndent > 0 {
                                if nextLine.hasPrefix(listIndentPrefix) {
                                    nextLine = String(nextLine.dropFirst(listIndentPrefix.count))
                                } else if !isBlankMarkdownLine(nextLine) {
                                    break
                                }
                            }
                            if isFenceEnd(nextLine, fence: fence) {
                                break
                            }
                            if appendedCodeLine {
                                codeText.append("\n")
                            }
                            codeText.append(stripFenceIndent(nextLine, indent: fence.indent))
                            appendedCodeLine = true
                            i += 1
                        }
                        // Skip closing fence if present
                        if i < lines.count {
                            var endLine = lines[i]
                            if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                                endLine = q.text
                            }
                            if listIndent > 0 {
                                if endLine.hasPrefix(listIndentPrefix) {
                                    endLine = String(endLine.dropFirst(listIndentPrefix.count))
                                }
                            }
                            if isFenceEnd(endLine, fence: fence) {
                                i += 1
                            }
                        }
                        let strictBlockSourceMarkdown: String? = {
                            guard options.strictConformanceRoundTripMode,
                                  blockStartIndex >= 0,
                                  i > blockStartIndex,
                                  i <= lines.count else { return nil }
                            return lines[blockStartIndex..<i].joined(separator: "\n")
                        }()
                        var appendedBlockEndsWithNewline = false
                        if fence.language?.lowercased() == "mermaid" {
                            let mermaidSourceMarkdown = "```mermaid\n\(codeText)\n```"
                            let mermaidAttr = NSMutableAttributedString(
                                attributedString: profile(.makeMermaidAttachmentAttributed) {
                                    makeMermaidAttachmentAttributed(
                                        sourceMarkdown: mermaidSourceMarkdown,
                                        baseFont: baseFont,
                                        renderMode: options.mermaidRenderMode
                                    )
                                }
                            )
                            if let strictBlockSourceMarkdown, mermaidAttr.length > 0 {
                                mermaidAttr.addAttribute(.kernSourceMarkdown, value: strictBlockSourceMarkdown, range: NSRange(location: 0, length: mermaidAttr.length))
                            }
                            applyQuoteAttributes(mermaidAttr, quoteDepth: quoteDepth)
                            result.append(mermaidAttr)
                            appendedBlockEndsWithNewline = mermaidAttr.string.hasSuffix("\n")
                        } else {
                            let codeAttr = NSMutableAttributedString(
                                attributedString: profile(.makeCodeBlockAttributed) {
                                    makeCodeBlockAttributed(
                                        codeText,
                                        baseFont: baseFont,
                                        infoString: fence.infoString,
                                        language: fence.language,
                                        syntaxHighlightingEnabled: ctx.syntaxHighlightingEnabled,
                                        themeSignature: ctx.themeSignature,
                                        profiler: ctx.profiler
                                    )
                                }
                            )
                            codeBlockCounter += 1
                            if codeAttr.length > 0 {
                                let full = NSRange(location: 0, length: codeAttr.length)
                                codeAttr.addAttribute(.kernCodeBlockID, value: codeBlockCounter, range: full)
                                codeAttr.addAttribute(.kernCodeFenceMarker, value: String(fence.marker), range: full)
                                codeAttr.addAttribute(.kernCodeFenceLength, value: fence.length, range: full)
                                if listIndent > 0 {
                                    codeAttr.addAttribute(.kernListIndent, value: listIndent, range: NSRange(location: 0, length: 1))
                                }
                                if let strictBlockSourceMarkdown {
                                    codeAttr.addAttribute(.kernSourceMarkdown, value: strictBlockSourceMarkdown, range: full)
                                }
                            }
                            applyQuoteAttributes(codeAttr, quoteDepth: quoteDepth)
                            result.append(codeAttr)
                            appendedBlockEndsWithNewline = codeAttr.string.hasSuffix("\n")
                        }
                        if i < lines.count, !appendedBlockEndsWithNewline {
                            result.append(plainNewline)
                        }
                    }
                    continue
                }

                // Indented code block (CommonMark): 4-space/tab-indented lines.
                // It must not interrupt an open paragraph (e.g. `Foo` + `    bar`).
                if canStartIndentedCode(lines, at: i, quoteDepth: quoteDepth),
                   let indented = parseIndentedCodeBlock(lines, startIndex: i, quoteDepth: quoteDepth) {
                    profile(.indentedCodeBlock) {
                        resetOrderedCounters()
                        let blockStartIndex = i
                        let codeText = indented.codeLines.joined(separator: "\n")
                        let codeAttr = NSMutableAttributedString(
                            attributedString: profile(.makeCodeBlockAttributed) {
                                makeCodeBlockAttributed(
                                    codeText,
                                    baseFont: baseFont,
                                    infoString: nil,
                                    language: nil,
                                    syntaxHighlightingEnabled: ctx.syntaxHighlightingEnabled,
                                    themeSignature: ctx.themeSignature,
                                    profiler: ctx.profiler
                                )
                            }
                        )
                        codeBlockCounter += 1
                        if codeAttr.length > 0 {
                            let full = NSRange(location: 0, length: codeAttr.length)
                            codeAttr.addAttribute(.kernCodeBlockID, value: codeBlockCounter, range: full)
                            codeAttr.addAttribute(.kernCodeFenceMarker, value: " ", range: full)
                            codeAttr.addAttribute(.kernCodeFenceLength, value: 0, range: full)

                            if let ctx = previousListContinuationContext(lines, before: i, quoteDepth: quoteDepth) {
                                let (currentIndent, _) = parseLeadingIndent(line)
                                if currentIndent >= ctx.indent + 4 {
                                    codeAttr.addAttribute(.kernListIndent, value: max(0, ctx.indent), range: NSRange(location: 0, length: 1))
                                    codeAttr.addAttribute(.kernListDepth, value: max(0, ctx.depth), range: NSRange(location: 0, length: 1))
                                }
                            }
                            if options.strictConformanceRoundTripMode,
                               blockStartIndex >= 0,
                               indented.nextIndex > blockStartIndex,
                               indented.nextIndex <= lines.count {
                                let sourceMarkdown = lines[blockStartIndex..<indented.nextIndex].joined(separator: "\n")
                                codeAttr.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: full)
                            }
                        }
                        applyQuoteAttributes(codeAttr, quoteDepth: quoteDepth)
                        result.append(codeAttr)
                        i = indented.nextIndex
                        if i < lines.count, !codeAttr.string.hasSuffix("\n") {
                            result.append(plainNewline)
                        }
                    }
                    continue
                }

                // GFM table
                if canStartGfmTable(lines, startIndex: i),
                   let match = parseGfmTable(lines, startIndex: i, profiler: profiler) {
                    profile(.gfmTableBlock) {
                        resetOrderedCounters()
                        tableCounter += 1
                        let tableID = tableCounter

                        // Preserve trailing newline behavior at end-of-file.
                        let terminateLastParagraph = !(match.endIndex == lines.count && !inputEndsWithNewline)

                        let tableAttr = profile(.makeGfmTableAttributed) {
                            makeGfmTableAttributed(
                                match.table,
                                tableID: tableID,
                                baseFont: baseFont,
                                terminateLastParagraph: terminateLastParagraph,
                                ctx: ctx
                            )
                        }
                        result.append(tableAttr)
                        i = match.endIndex
                    }
                    continue
                }

                // Thematic break (horizontal rule)
                if let marker = parseThematicBreak(line) {
                    profile(.thematicBreakBlock) {
                        resetOrderedCounters()
                        let para = NSMutableAttributedString(attributedString: makeThematicBreakAttributed(baseFont: baseFont, marker: marker))
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i += 1
                    }
                    continue
                }

                // Heading
                if let heading = parseHeading(line) {
                    profile(.atxHeadingBlock) {
                        resetOrderedCounters()
                        // Kern extension: checkbox headings like `## [ ] Heading`.
                        if options.headingCheckboxesEnabled, let headingTask = parseHeadingCheckbox(heading.text) {
                            let containsInlineSyntax = containsInlineSyntax(in: headingTask.text)
                            let para = NSMutableAttributedString(attributedString: makeHeadingWithCheckbox(
                                level: heading.level,
                                checked: headingTask.checked,
                                text: headingTask.text,
                                containsInlineSyntax: containsInlineSyntax,
                                baseFont: baseFont,
                                ctx: ctx
                            ))
                            applyQuoteAttributes(para, quoteDepth: quoteDepth)
                            result.append(para)
                            if i < lines.count - 1 {
                                result.append(plainNewline)
                            }
                            i += 1
                            return
                        }

                        let headingBaseFont = headingFont(level: heading.level)
                        let containsInlineSyntax = containsInlineSyntax(in: heading.text)
                        let content = NativeMarkdownCodec.makeInlineContent(
                            heading.text,
                            baseFont: headingBaseFont,
                            containsInlineSyntax: containsInlineSyntax,
                            ctx: ctx
                        )
                        let para = NSMutableAttributedString(attributedString: content)
                        if para.length == 0 {
                            let placeholder = NSAttributedString(
                                string: String(storagePlaceholderCharacter),
                                attributes: baseAttributes(baseFont: headingBaseFont)
                            )
                            para.append(placeholder)
                            para.addAttribute(.kernPlaceholder, value: true, range: NSRange(location: 0, length: para.length))
                        }
                        applyBlockAttributes(
                            para,
                            kind: .heading,
                            baseFont: baseFont,
                            headingLevel: heading.level
                        )
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i += 1
                    }
                    continue
                }

                // Setext heading:
                //   Heading text
                //   ========   /   --------
                if let setext = parseSetextHeading(lines, startIndex: i, quoteDepth: quoteDepth, options: options) {
                    profile(.setextHeadingBlock) {
                        resetOrderedCounters()
                        let headingBaseFont = headingFont(level: setext.level)
                        let containsInlineSyntax = containsInlineSyntax(in: setext.text)
                        let content = NativeMarkdownCodec.makeInlineContent(
                            setext.text,
                            baseFont: headingBaseFont,
                            containsInlineSyntax: containsInlineSyntax,
                            ctx: ctx
                        )
                        let para = NSMutableAttributedString(attributedString: content)
                        if para.length == 0 {
                            let placeholder = NSAttributedString(
                                string: String(storagePlaceholderCharacter),
                                attributes: baseAttributes(baseFont: headingBaseFont)
                            )
                            para.append(placeholder)
                            para.addAttribute(.kernPlaceholder, value: true, range: NSRange(location: 0, length: para.length))
                        }
                        applyBlockAttributes(
                            para,
                            kind: .heading,
                            baseFont: baseFont,
                            headingLevel: setext.level
                        )
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        i = setext.nextIndex
                        if i < lines.count {
                            result.append(plainNewline)
                        }
                    }
                    continue
                }

                // Bullet/standalone task: - [ ] text / * [ ] text / + [ ] text / [] text / [ ] text
                if let task = parseTask(line) {
                    profile(.taskListBlock) {
                        resetOrderedCounters()
                        let markerWidth: Int
                        switch task.style {
                        case .bulleted:
                            markerWidth = 1 + max(1, task.markerPadding.count)
                        case .standalone:
                            // `[ ] ` marker width for continuation alignment.
                            markerWidth = 4
                        }
                        let listBody = collectListBody(startIndex: i, firstLine: task.text, continuationIndent: task.indent + markerWidth)
                        let combined = listBody.combined
                        let j = listBody.nextIndex

                        let para = NSMutableAttributedString(attributedString: makeTaskParagraph(
                            (task.style, task.marker, task.markerPadding, task.checked, combined),
                            indent: task.indent,
                            depth: task.depth,
                            baseFont: baseFont,
                            containsInlineSyntax: listBody.containsInlineSyntax,
                            options: options,
                            ctx: ctx
                        ))
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i = j
                    }
                    continue
                }

                // Ordered task (Kern preference): 1. [ ] text
                if options.orderedTasksEnabled, let orderedTask = parseOrderedTask(line) {
                    profile(.orderedTaskBlock) {
                        // Ordered tasks are a Kern option; keep them from affecting GFM ordered-list numbering.
                        if options.orderedListNumbering == .gfmDefault {
                            resetOrderedCounters()
                        }

                        let listBody = collectListBody(startIndex: i, firstLine: orderedTask.text, continuationIndent: orderedTask.indent + orderedTask.markerLen)
                        let combined = listBody.combined
                        let j = listBody.nextIndex

                        let normalizedIndex: Int
                        switch options.orderedListNumbering {
                        case .preserveTyped:
                            normalizedIndex = orderedTask.index
                        case .gfmDefault:
                            normalizedIndex = orderedTask.index
                        }

                        let para = NSMutableAttributedString(attributedString: makeOrderedTaskParagraph(
                            (normalizedIndex, orderedTask.checked, combined),
                            indent: orderedTask.indent,
                            depth: orderedTask.depth,
                            baseFont: baseFont,
                            containsInlineSyntax: listBody.containsInlineSyntax,
                            ctx: ctx
                        ))
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i = j
                        if options.orderedListNumbering == .gfmDefault {
                            resetOrderedCounters()
                        }
                    }
                    continue
                }

                // When the ordered-task option is disabled, keep the ordered-task syntax as literal text.
                // This avoids implicitly opting into non-standard Markdown behavior in the default GFM profile.
                if !options.orderedTasksEnabled, parseOrderedTask(line) != nil {
                    profile(.paragraphFallbackBlock) {
                        resetOrderedCounters()
                        let para = NSMutableAttributedString(attributedString: parseInline(line, baseFont: baseFont, ctx: ctx))
                        applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i += 1
                    }
                    continue
                }

                // Ordered list item whose content starts with a fenced code block (`1. ````).
                if let ordered = parseOrdered(line), let inlineFence = parseFenceStart(ordered.text) {
                    profile(.orderedListBlock) {
                        let normalizedIndex: Int
                        switch options.orderedListNumbering {
                        case .preserveTyped:
                            normalizedIndex = ordered.index
                        case .gfmDefault:
                            normalizedIndex = nextOrderedIndexGfmDefault(parsedIndex: ordered.index, depth: ordered.depth)
                        }

                        let markerPara = NSMutableAttributedString(attributedString: makeOrderedParagraph(
                            (normalizedIndex, ordered.markerPadding, ""),
                            indent: ordered.indent,
                            depth: ordered.depth,
                            baseFont: baseFont,
                            containsInlineSyntax: false,
                            ctx: ctx
                        ))
                        applyQuoteAttributes(markerPara, quoteDepth: quoteDepth)
                        result.append(markerPara)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }

                        let listIndent = ordered.indent + ordered.markerLen
                        let listIndentPrefix = listIndent > 0 ? String(repeating: " ", count: listIndent) : ""
                        var codeText = ""
                        var appendedCodeLine = false
                        var j = i + 1
                        while j < lines.count {
                            var nextLine = lines[j]
                            if quoteDepth > 0 {
                                guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                                nextLine = q.text
                            }
                            if listIndent > 0 {
                                if nextLine.hasPrefix(listIndentPrefix) {
                                    nextLine = String(nextLine.dropFirst(listIndentPrefix.count))
                                } else if !isBlankMarkdownLine(nextLine) {
                                    break
                                }
                            }
                            if isFenceEnd(nextLine, fence: inlineFence) {
                                break
                            }
                            if appendedCodeLine {
                                codeText.append("\n")
                            }
                            codeText.append(stripFenceIndent(nextLine, indent: inlineFence.indent))
                            appendedCodeLine = true
                            j += 1
                        }
                        if j < lines.count {
                            var endLine = lines[j]
                            if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                                endLine = q.text
                            }
                            if listIndent > 0 {
                                if endLine.hasPrefix(listIndentPrefix) {
                                    endLine = String(endLine.dropFirst(listIndentPrefix.count))
                                }
                            }
                            if isFenceEnd(endLine, fence: inlineFence) {
                                j += 1
                            }
                        }
                        let codeAttr = NSMutableAttributedString(
                            attributedString: profile(.makeCodeBlockAttributed) {
                                makeCodeBlockAttributed(
                                    codeText,
                                    baseFont: baseFont,
                                    infoString: inlineFence.infoString,
                                    language: inlineFence.language,
                                    syntaxHighlightingEnabled: ctx.syntaxHighlightingEnabled,
                                    themeSignature: ctx.themeSignature,
                                    profiler: ctx.profiler
                                )
                            }
                        )
                        codeBlockCounter += 1
                        if codeAttr.length > 0 {
                            let full = NSRange(location: 0, length: codeAttr.length)
                            codeAttr.addAttribute(.kernCodeBlockID, value: codeBlockCounter, range: full)
                            codeAttr.addAttribute(.kernCodeFenceMarker, value: String(inlineFence.marker), range: full)
                            codeAttr.addAttribute(.kernCodeFenceLength, value: inlineFence.length, range: full)
                            codeAttr.addAttribute(.kernListIndent, value: listIndent, range: NSRange(location: 0, length: 1))
                            codeAttr.addAttribute(.kernListDepth, value: max(0, ordered.depth), range: NSRange(location: 0, length: 1))
                        }
                        applyQuoteAttributes(codeAttr, quoteDepth: quoteDepth)
                        result.append(codeAttr)
                        if j < lines.count, !codeAttr.string.hasSuffix("\n") {
                            result.append(plainNewline)
                        }
                        i = j
                    }
                    continue
                }

                // Ordered list: 1. text
                if let ordered = parseOrdered(line) {
                    profile(.orderedListBlock) {
                        let listBody = collectListBody(startIndex: i, firstLine: ordered.text, continuationIndent: ordered.indent + ordered.markerLen)
                        let combined = listBody.combined
                        let j = listBody.nextIndex

                        let normalizedIndex: Int
                        switch options.orderedListNumbering {
                        case .preserveTyped:
                            normalizedIndex = ordered.index
                        case .gfmDefault:
                            normalizedIndex = nextOrderedIndexGfmDefault(parsedIndex: ordered.index, depth: ordered.depth)
                        }

                        let para = NSMutableAttributedString(attributedString: makeOrderedParagraph(
                            (normalizedIndex, ordered.markerPadding, combined),
                            indent: ordered.indent,
                            depth: ordered.depth,
                            baseFont: baseFont,
                            containsInlineSyntax: listBody.containsInlineSyntax,
                            ctx: ctx
                        ))
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i = j
                    }
                    continue
                }

                // Bullet list item whose content starts with a fenced code block (`- ````).
                if let bullet = parseBullet(line), let inlineFence = parseFenceStart(bullet.text) {
                    profile(.bulletListBlock) {
                        resetOrderedCounters()

                        let markerPara = NSMutableAttributedString(
                            attributedString: makeBulletParagraph("", marker: bullet.marker, markerPadding: bullet.markerPadding, indent: bullet.indent, depth: bullet.depth, baseFont: baseFont, containsInlineSyntax: false, ctx: ctx)
                        )
                        applyQuoteAttributes(markerPara, quoteDepth: quoteDepth)
                        result.append(markerPara)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }

                        let listIndent = bullet.indent + 1 + max(1, bullet.markerPadding.count)
                        let listIndentPrefix = listIndent > 0 ? String(repeating: " ", count: listIndent) : ""
                        var codeText = ""
                        var appendedCodeLine = false
                        var j = i + 1
                        while j < lines.count {
                            var nextLine = lines[j]
                            if quoteDepth > 0 {
                                guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                                nextLine = q.text
                            }
                            if listIndent > 0 {
                                if nextLine.hasPrefix(listIndentPrefix) {
                                    nextLine = String(nextLine.dropFirst(listIndentPrefix.count))
                                } else if !isBlankMarkdownLine(nextLine) {
                                    break
                                }
                            }
                            if isFenceEnd(nextLine, fence: inlineFence) {
                                break
                            }
                            if appendedCodeLine {
                                codeText.append("\n")
                            }
                            codeText.append(stripFenceIndent(nextLine, indent: inlineFence.indent))
                            appendedCodeLine = true
                            j += 1
                        }
                        if j < lines.count {
                            var endLine = lines[j]
                            if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                                endLine = q.text
                            }
                            if listIndent > 0 {
                                if endLine.hasPrefix(listIndentPrefix) {
                                    endLine = String(endLine.dropFirst(listIndentPrefix.count))
                                }
                            }
                            if isFenceEnd(endLine, fence: inlineFence) {
                                j += 1
                            }
                        }
                        let codeAttr = NSMutableAttributedString(
                            attributedString: profile(.makeCodeBlockAttributed) {
                                makeCodeBlockAttributed(
                                    codeText,
                                    baseFont: baseFont,
                                    infoString: inlineFence.infoString,
                                    language: inlineFence.language,
                                    syntaxHighlightingEnabled: ctx.syntaxHighlightingEnabled,
                                    themeSignature: ctx.themeSignature,
                                    profiler: ctx.profiler
                                )
                            }
                        )
                        codeBlockCounter += 1
                        if codeAttr.length > 0 {
                            let full = NSRange(location: 0, length: codeAttr.length)
                            codeAttr.addAttribute(.kernCodeBlockID, value: codeBlockCounter, range: full)
                            codeAttr.addAttribute(.kernCodeFenceMarker, value: String(inlineFence.marker), range: full)
                            codeAttr.addAttribute(.kernCodeFenceLength, value: inlineFence.length, range: full)
                            codeAttr.addAttribute(.kernListIndent, value: listIndent, range: NSRange(location: 0, length: 1))
                            codeAttr.addAttribute(.kernListDepth, value: max(0, bullet.depth), range: NSRange(location: 0, length: 1))
                        }
                        applyQuoteAttributes(codeAttr, quoteDepth: quoteDepth)
                        result.append(codeAttr)
                        if j < lines.count, !codeAttr.string.hasSuffix("\n") {
                            result.append(plainNewline)
                        }
                        i = j
                    }
                    continue
                }

                // Bullet list: - text
                if let bullet = parseBullet(line) {
                    profile(.bulletListBlock) {
                        resetOrderedCounters()
                        let listBody = collectListBody(startIndex: i, firstLine: bullet.text, continuationIndent: bullet.indent + 1 + max(1, bullet.markerPadding.count))
                        let combined = listBody.combined
                        let j = listBody.nextIndex

                        let para = NSMutableAttributedString(
                            attributedString: makeBulletParagraph(combined, marker: bullet.marker, markerPadding: bullet.markerPadding, indent: bullet.indent, depth: bullet.depth, baseFont: baseFont, containsInlineSyntax: listBody.containsInlineSyntax, ctx: ctx)
                        )
                        applyQuoteAttributes(para, quoteDepth: quoteDepth)
                        result.append(para)
                        if i < lines.count - 1 {
                            result.append(plainNewline)
                        }
                        i = j
                    }
                    continue
                }

                // Plain paragraph (including empty line)
                profile(.paragraphFallbackBlock) {
                    resetOrderedCounters()
                    let paragraphBody = collectParagraphBody(startIndex: i, firstLine: line, quoteDepth: quoteDepth)
                    let j = paragraphBody.nextIndex

                    let para = NSMutableAttributedString(attributedString: makeInlineContent(paragraphBody, baseFont: baseFont))
                    applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
                    applyQuoteAttributes(para, quoteDepth: quoteDepth)
                    result.append(para)
                    if j - 1 < lines.count - 1 {
                        result.append(plainNewline)
                    }
                    i = j
                }
                continue
            }
        }

        return result
    }

    static func importMarkdownProfiled(
        _ markdown: String,
        options: Options = Options(),
        baseURL: URL? = nil,
        precomputedReferenceDefinitions: [String: ReferenceDefinition]? = nil
    ) -> ProfiledImportResult {
        let profiler = ImportProfiler()
        let attributed = importMarkdown(
            markdown,
            options: options,
            baseURL: baseURL,
            precomputedReferenceDefinitions: precomputedReferenceDefinitions,
            profiler: profiler
        )
        return ProfiledImportResult(attributed: attributed, profile: profiler.snapshot())
    }

    static func collectReferenceDefinitions(in markdown: String) -> [String: ReferenceDefinition] {
        let markdown = normalizeLineEndings(markdown)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return collectReferenceDefinitions(lines: lines)
    }

    static func normalizeLineEndings(_ markdown: String) -> String {
        if !markdown.contains("\r") { return markdown }
        var normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        return normalized
    }

    private static func collectReferenceDefinitions(lines: [String]) -> [String: ReferenceDefinition] {
        var referenceDefinitions: [String: ReferenceDefinition] = [:]
        for raw in lines {
            if let def = parseReferenceDefinition(raw) {
                referenceDefinitions[def.id.lowercased()] = def
                continue
            }
            // Strip blockquote prefixes and retry — reference definitions inside
            // blockquotes are still valid link targets per CommonMark spec.
            var stripped = raw
            while let q = parseBlockquotePrefix(stripped) {
                stripped = q.text
            }
            if stripped != raw, let def = parseReferenceDefinition(stripped) {
                referenceDefinitions[def.id.lowercased()] = def
            }
        }
        return referenceDefinitions
    }

    static func exportMarkdown(_ attributed: NSAttributedString, options: Options = Options()) -> String {
        let ns = attributed.string as NSString
        struct ExportedBlock {
            var text: String
            let kind: KernBlockKind
            let quoteDepth: Int
            let listIndent: Int
        }

        var outBlocks: [ExportedBlock] = []

        func appendBlock(
            _ text: String,
            kind: KernBlockKind,
            quoteDepth: Int = 0,
            listIndent: Int = 0
        ) {
            outBlocks.append(
                ExportedBlock(
                    text: text,
                    kind: kind,
                    quoteDepth: max(0, quoteDepth),
                    listIndent: max(0, listIndent)
                )
            )
        }

        func isListContext(_ block: ExportedBlock) -> Bool {
            switch block.kind {
            case .bullet, .ordered, .task:
                return true
            default:
                return block.listIndent > 0
            }
        }

        func isExplicitBlankParagraph(_ block: ExportedBlock) -> Bool {
            guard block.kind == .paragraph else { return false }
            return block.text.isEmpty
        }

        func separatorBetween(_ previous: ExportedBlock, _ next: ExportedBlock) -> String {
            if options.strictConformanceRoundTripMode {
                return "\n"
            }
            // Explicit blank paragraph blocks already encode vertical spacing.
            // Joining transitions around them with single newlines preserves authored
            // blank-line counts and prevents accidental `\n\n\n\n` expansion when
            // a heading/paragraph is followed by a list separated by one blank line.
            if isExplicitBlankParagraph(previous) || isExplicitBlankParagraph(next) {
                return "\n"
            }
            // Adjacent headings are commonly authored without an intervening blank line.
            // Keep that shape stable on round-trip instead of forcing an extra spacer.
            if previous.kind == .heading,
               next.kind == .heading,
               previous.quoteDepth == next.quoteDepth,
               previous.listIndent == next.listIndent {
                return "\n"
            }
            guard options.paragraphBlockSeparationEnabled else { return "\n" }
            if isListContext(previous),
               isListContext(next),
               previous.quoteDepth == next.quoteDepth {
                return "\n"
            }
            return "\n\n"
        }

        func paragraphContentWithoutMarkers(_ paragraphWithNewline: NSAttributedString) -> NSAttributedString {
            let text = paragraphWithNewline.string
            let paraText = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let paraRange = NSRange(location: 0, length: min(paragraphWithNewline.length, (paraText as NSString).length))
            guard paraRange.length > 0 else { return NSAttributedString(string: "") }
            let paragraph = paragraphWithNewline.attributedSubstring(from: paraRange)

            var contentStart = 0
            while contentStart < paragraph.length {
                let isMarker = (paragraph.attribute(.kernMarker, at: contentStart, effectiveRange: nil) as? Bool) ?? false
                if !isMarker { break }
                contentStart += 1
            }
            let contentRange = NSRange(location: contentStart, length: max(0, paragraph.length - contentStart))
            return paragraph.attributedSubstring(from: contentRange)
        }

        func isMarkerOnlyListLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-" || trimmed == "*" || trimmed == "+" {
                return true
            }
            guard trimmed.hasSuffix(".") else { return false }
            let number = String(trimmed.dropLast())
            return Int(number) != nil
        }

        var idx = 0
        while idx < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            let para = attributed.attributedSubstring(from: paraRange)
            if para.length == 0 {
                appendBlock("", kind: .paragraph)
                idx = paraRange.location + paraRange.length
                continue
            }
            let kindRaw = para.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph

            if options.strictConformanceRoundTripMode,
               kind == .paragraph,
               let source = para.attribute(.kernSourceMarkdown, at: 0, effectiveRange: nil) as? String,
               !source.isEmpty {
                // Reference definitions have dedicated block attributes and must serialize via
                // exportParagraph() so they keep `[id]: url "title"` form.
                let hasReferenceDefinition = para.attribute(.kernReferenceDefinitionID, at: 0, effectiveRange: nil) != nil
                if !hasReferenceDefinition {
                    // Multiline strict paragraphs may be represented as multiple NSText paragraphs
                    // carrying the same source literal. Collapse them into one export.
                    var j = idx
                    while j < ns.length {
                        let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                        let p = attributed.attributedSubstring(from: r)
                        guard p.length > 0 else { break }
                        let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                        let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                        guard k == .paragraph else { break }
                        let blockSource = p.attribute(.kernSourceMarkdown, at: 0, effectiveRange: nil) as? String
                        guard blockSource == source else { break }
                        j = r.location + r.length
                    }

                    var out = source
                    let quoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                    if quoteDepth > 0 {
                        let prefix = String(repeating: "> ", count: quoteDepth)
                        let parts = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        out = parts.map { prefix + $0 }.joined(separator: "\n")
                    }

                    appendBlock(out, kind: .paragraph, quoteDepth: quoteDepth)
                    idx = j
                    continue
                }
            }

            if kind == .paragraph,
               para.attribute(.kernCalloutKind, at: 0, effectiveRange: nil) as? String != nil {
                let initialQuoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                var lines = [exportParagraph(para, options: options)]
                var j = paraRange.location + paraRange.length
                while j < ns.length {
                    let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                    let p = attributed.attributedSubstring(from: r)
                    guard p.length > 0 else { break }
                    let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    guard k == .paragraph else { break }
                    let quoteDepth = (p.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                    guard quoteDepth == initialQuoteDepth else { break }
                    if p.attribute(.kernCalloutKind, at: 0, effectiveRange: nil) as? String != nil { break }
                    lines.append(exportParagraph(p, options: options))
                    j = r.location + r.length
                }
                appendBlock(lines.joined(separator: "\n"), kind: .paragraph, quoteDepth: initialQuoteDepth)
                idx = j
                continue
            }

            if kind == .tableCell {
                let tableID = (para.attribute(.kernTableID, at: 0, effectiveRange: nil) as? Int) ?? -1
                let exported = exportGfmTableBlock(attributed, ns: ns, startIndex: idx, tableID: tableID)
                appendBlock(exported.block, kind: .tableCell)
                idx = exported.nextIndex
                continue
            }

            if kind == .codeBlock {
                if options.strictConformanceRoundTripMode,
                   let source = para.attribute(.kernSourceMarkdown, at: 0, effectiveRange: nil) as? String,
                   !source.isEmpty {
                    var j = idx
                    while j < ns.length {
                        let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                        let p = attributed.attributedSubstring(from: r)
                        guard p.length > 0 else { break }
                        let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                        let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                        guard k == .codeBlock else { break }
                        let blockSource = p.attribute(.kernSourceMarkdown, at: 0, effectiveRange: nil) as? String
                        guard blockSource == source else { break }
                        j = r.location + r.length
                    }
                    appendBlock(source, kind: .codeBlock)
                    idx = j
                    continue
                }

                // Group consecutive codeBlock paragraphs into a single fenced block.
                var rawCodeText = ""
                var j = idx

                // Language extraction.
                // Prefer the full info string attribute for export fidelity, but keep the
                // language token for UI/highlighting fallbacks.
                var fenceInfoString: String?
                var language: String?
                if let info = para.attribute(.kernCodeFenceInfoString, at: 0, effectiveRange: nil) as? String,
                   !info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fenceInfoString = info.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let lang = para.attribute(.kernCodeLanguage, at: 0, effectiveRange: nil) as? String,
                   !lang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    language = lang.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if fenceInfoString == nil,
                   let tip = para.attribute(.toolTip, at: 0, effectiveRange: nil) as? String,
                   tip.hasPrefix("```") {
                    let info = tip.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    fenceInfoString = info.isEmpty ? nil : String(info)
                }
                if language == nil, let fenceInfoString {
                    let firstToken = fenceInfoString.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
                    let lang = firstToken.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    language = lang.isEmpty ? nil : lang
                }

                let quoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                let listIndent = (para.attribute(.kernListIndent, at: 0, effectiveRange: nil) as? Int) ?? 0
                let codeBlockID = para.attribute(.kernCodeBlockID, at: 0, effectiveRange: nil) as? Int
                let fenceMarkerRaw = (para.attribute(.kernCodeFenceMarker, at: 0, effectiveRange: nil) as? String) ?? "`"
                let fenceLenRaw = (para.attribute(.kernCodeFenceLength, at: 0, effectiveRange: nil) as? Int) ?? 3
                let isPlaceholderOnlyCodeBlock = ((para.attribute(.kernPlaceholder, at: 0, effectiveRange: nil) as? Bool) ?? false)

                while j < ns.length {
                    let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                    let p = attributed.attributedSubstring(from: r)
                    if p.length == 0 { break }
                    let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    guard k == .codeBlock else { break }

                    let qd = (p.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                    if qd != quoteDepth { break }

                    // Preserve boundaries between back-to-back fenced blocks.
                    if let codeBlockID {
                        let nextID = p.attribute(.kernCodeBlockID, at: 0, effectiveRange: nil) as? Int
                        if nextID != codeBlockID { break }
                    } else if (p.attribute(.kernCodeBlockID, at: 0, effectiveRange: nil) as? Int) != nil {
                        break
                    }

                    var codeSpan = r
                    if codeSpan.length > 0 {
                        let lastLocation = codeSpan.location + codeSpan.length - 1
                        let lastKindRaw = attributed.attribute(.kernBlockKind, at: lastLocation, effectiveRange: nil) as? Int
                        let lastKind = KernBlockKind(rawValue: lastKindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                        if lastKind != .codeBlock {
                            codeSpan.length -= 1
                        }
                    }
                    if codeSpan.length > 0 {
                        rawCodeText += attributed.attributedSubstring(from: codeSpan).string
                    }
                    j = r.location + r.length
                }

                let sanitizedCodeText = stripStoragePlaceholders(rawCodeText)
                var codeLines: [String]
                if sanitizedCodeText.isEmpty {
                    codeLines = []
                } else {
                    codeLines = sanitizedCodeText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                }

                if isPlaceholderOnlyCodeBlock, codeLines.isEmpty || (codeLines.count == 1 && codeLines[0].isEmpty) {
                    codeLines.removeAll(keepingCapacity: true)
                }

                let isIndentedOrigin = fenceMarkerRaw == " " || fenceLenRaw == 0
                // Strict mode preserves author-typed indented code blocks exactly.
                if isIndentedOrigin, language == nil, options.strictConformanceRoundTripMode {
                    let codeIndentPrefix = codeLines.contains(where: { $0.hasPrefix("\t") }) ? "\t" : "    "
                    let indentPrefix = String(repeating: " ", count: max(0, listIndent)) + codeIndentPrefix
                    var blockLines = codeLines.map { indentPrefix + $0 }
                    if blockLines.isEmpty {
                        blockLines = [indentPrefix]
                    }
                    if quoteDepth > 0 {
                        let prefix = String(repeating: "> ", count: quoteDepth)
                        blockLines = blockLines.map { prefix + $0 }
                    }
                    appendBlock(
                        blockLines.joined(separator: "\n"),
                        kind: .codeBlock,
                        quoteDepth: quoteDepth,
                        listIndent: listIndent
                    )
                    idx = j
                    continue
                }

                let canonicalizeGfmFence = options.exportDialect == .gfm && !options.strictConformanceRoundTripMode
                let preferredMarker: Character
                if canonicalizeGfmFence {
                    preferredMarker = "`"
                } else {
                    preferredMarker = (fenceMarkerRaw == "~") ? "~" : "`"
                }
                let markerRun = maxFenceRun(of: preferredMarker, in: codeLines)
                let fenceLength = max(3, fenceLenRaw, markerRun + 1)
                let markerString = String(repeating: String(preferredMarker), count: fenceLength)
                let openFence = markerString + (fenceInfoString ?? language ?? "")
                var blockLines = [openFence] + codeLines + [markerString]
                var collapsedListMarker: String?
                if quoteDepth == 0,
                   listIndent > 0,
                   let last = outBlocks.last,
                   isMarkerOnlyListLine(last.text) {
                    collapsedListMarker = outBlocks.removeLast().text
                }
                if listIndent > 0 {
                    let prefix = String(repeating: " ", count: max(0, listIndent))
                    blockLines = blockLines.map { prefix + $0 }
                }
                if quoteDepth > 0 {
                    let prefix = String(repeating: "> ", count: quoteDepth)
                    blockLines = blockLines.map { prefix + $0 }
                }
                if let markerLine = collapsedListMarker, !blockLines.isEmpty {
                    let first = blockLines.removeFirst()
                    let listPrefix = String(repeating: " ", count: max(0, listIndent))
                    let firstWithoutIndent = first.hasPrefix(listPrefix) ? String(first.dropFirst(listPrefix.count)) : first
                    let needsJoinSpace = !(markerLine.last == " " || markerLine.last == "\t")
                    let markerJoin = needsJoinSpace ? " " : ""
                    blockLines.insert(markerLine + markerJoin + firstWithoutIndent, at: 0)
                }
                appendBlock(
                    blockLines.joined(separator: "\n"),
                    kind: .codeBlock,
                    quoteDepth: quoteDepth,
                    listIndent: listIndent
                )
                idx = j
                continue
            }

            if kind == .thematicBreak {
                let storedMarker = (para.attribute(.kernThematicBreakMarker, at: 0, effectiveRange: nil) as? String) ?? "---"
                let marker: String
                if options.exportDialect == .gfm && !options.strictConformanceRoundTripMode {
                    // Canonicalize non-canonical thematic breaks (`- - -`, spaced/indented variants)
                    // while preserving already-canonical marker families (`---`, `***`, `___`).
                    if storedMarker == "---" || storedMarker == "***" || storedMarker == "___" {
                        marker = storedMarker
                    } else {
                        marker = "---"
                    }
                } else {
                    marker = storedMarker
                }
                let quoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                if quoteDepth > 0 {
                    appendBlock(
                        String(repeating: "> ", count: quoteDepth) + marker,
                        kind: .thematicBreak,
                        quoteDepth: quoteDepth
                    )
                } else {
                    appendBlock(marker, kind: .thematicBreak)
                }
                idx = paraRange.location + paraRange.length
                continue
            }

            if kind == .ordered, options.orderedListNumbering == .gfmDefault {
                // Export ordered list runs in a stable GFM-compatible style:
                // - Normalize to sequential numbering starting at the first marker
                var j = idx
                var counters: [Int] = []
                let initialQuoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                var lastOrderedBlockIndex: Int?
                var lastContinuationIndent = ""
                while j < ns.length {
                    let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                    let p = attributed.attributedSubstring(from: r)
                    if p.length == 0 { break }
                    let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    guard k == .ordered else { break }

                    let quoteDepth = (p.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                    if quoteDepth != initialQuoteDepth { break }

                    let hasExplicitMarker = p.attribute(.kernOrderedIndex, at: 0, effectiveRange: nil) != nil
                    if !hasExplicitMarker, let blockIndex = lastOrderedBlockIndex {
                        let continuationContent = exportInline(paragraphContentWithoutMarkers(p))
                        if !continuationContent.isEmpty {
                            var continuationLine = lastContinuationIndent + continuationContent
                            if quoteDepth > 0 {
                                continuationLine = String(repeating: "> ", count: quoteDepth) + continuationLine
                            }
                            outBlocks[blockIndex].text += "\n" + continuationLine
                        }
                        j = r.location + r.length
                        continue
                    }

                    let storedN = (p.attribute(.kernOrderedIndex, at: 0, effectiveRange: nil) as? Int) ?? 1
                    let isTask = (p.attribute(.kernOrderedIsTask, at: 0, effectiveRange: nil) as? Bool) ?? false
                    let markerPadding = (p.attribute(.kernListMarkerPadding, at: 0, effectiveRange: nil) as? String) ?? " "
                    let listIndent = (p.attribute(.kernListIndent, at: 0, effectiveRange: nil) as? Int) ?? 0

                    // Kern ordered-tasks should not participate in GFM ordered-list numbering runs.
                    // They keep their typed marker and do not affect subsequent numbering.
                    if isTask {
                        var line = exportOrderedParagraphGfmNumbering(p, outputIndex: storedN, options: options)
                        if quoteDepth > 0 {
                            line = String(repeating: "> ", count: quoteDepth) + line
                        }
                        lastContinuationIndent = String(repeating: " ", count: max(0, listIndent) + String(max(0, storedN)).count + 1 + max(1, markerPadding.count))
                        lastOrderedBlockIndex = outBlocks.count
                        appendBlock(line, kind: .ordered, quoteDepth: quoteDepth, listIndent: listIndent)
                        counters.removeAll(keepingCapacity: true)
                        j = r.location + r.length
                        continue
                    }

                    let depth = max(0, (p.attribute(.kernListDepth, at: 0, effectiveRange: nil) as? Int) ?? 0)

                    if depth < counters.count {
                        counters = Array(counters.prefix(depth + 1))
                    } else if depth >= counters.count {
                        // If the markdown jumps depth levels (unusual), initialize intermediate levels to 1.
                        while counters.count < depth { counters.append(1) }
                        counters.append(storedN)
                    }

                    let n = counters[depth]
                    counters[depth] = n + 1

                    var line = exportOrderedParagraphGfmNumbering(p, outputIndex: n, options: options)
                    if quoteDepth > 0 {
                        line = String(repeating: "> ", count: quoteDepth) + line
                    }
                    lastContinuationIndent = String(repeating: " ", count: max(0, listIndent) + String(max(0, n)).count + 1 + max(1, markerPadding.count))
                    lastOrderedBlockIndex = outBlocks.count
                    appendBlock(line, kind: .ordered, quoteDepth: quoteDepth, listIndent: listIndent)
                    j = r.location + r.length
                }

                idx = j
                continue
            }

            let line = exportParagraph(para, options: options)
            let quoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
            let listIndent = (para.attribute(.kernListIndent, at: 0, effectiveRange: nil) as? Int) ?? 0
            appendBlock(line, kind: kind, quoteDepth: quoteDepth, listIndent: listIndent)
            idx = paraRange.location + paraRange.length
        }

        // Preserve trailing newline if the attributed string ends with one.
        let endsWithNewline = attributed.string.hasSuffix("\n")
        let joinedCore: String = {
            guard let first = outBlocks.first else { return "" }
            var output = first.text
            if outBlocks.count == 1 {
                return output
            }
            for i in 1..<outBlocks.count {
                output += separatorBetween(outBlocks[i - 1], outBlocks[i])
                output += outBlocks[i].text
            }
            return output
        }()
        var joined = joinedCore
        if endsWithNewline, !joined.hasSuffix("\n") {
            joined += "\n"
        }
        return joined
    }

    private static func exportOrderedParagraphGfmNumbering(_ paragraphWithNewline: NSAttributedString, outputIndex: Int, options: Options) -> String {
        // Drop trailing newline for analysis.
        let text = paragraphWithNewline.string
        let paraText = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let paraRange = NSRange(location: 0, length: min(paragraphWithNewline.length, (paraText as NSString).length))
        guard paraRange.length > 0 else {
            let n = max(0, outputIndex)
            return "\(n). "
        }
        let paragraph = paragraphWithNewline.attributedSubstring(from: paraRange)

        let listIndent = (paragraph.attribute(.kernListIndent, at: 0, effectiveRange: nil) as? Int) ?? 0
        let indentPrefix = String(repeating: " ", count: max(0, listIndent))

        // Find the first non-marker character (skip marker prefix).
        var contentStart = 0
        while contentStart < paragraph.length {
            let isMarker = (paragraph.attribute(.kernMarker, at: contentStart, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            contentStart += 1
        }
        let contentRange = NSRange(location: contentStart, length: max(0, paragraph.length - contentStart))
        let content = paragraph.attributedSubstring(from: contentRange)

        let n = max(0, outputIndex)
        let isTask = (paragraph.attribute(.kernOrderedIsTask, at: 0, effectiveRange: nil) as? Bool) ?? false
        let storedPadding = (paragraph.attribute(.kernListMarkerPadding, at: 0, effectiveRange: nil) as? String) ?? " "
        let normalizeMarkerPadding = options.exportDialect == .gfm && !options.strictConformanceRoundTripMode
        let markerPadding = normalizeMarkerPadding ? " " : storedPadding
        let line: String
        let softBreakKind: KernBlockKind
        if isTask {
            let checked = findFirstCheckboxState(in: paragraph) ?? false
            switch (options.exportDialect, options.gfmExtensionExportStrategy) {
            case (.gfm, .portable):
                let glyph = checked ? "\u{2611}" : "\u{2610}"
                line = "\(n).\(markerPadding)\(glyph) " + exportInline(content)
                softBreakKind = .ordered
            case (.gfm, .lint):
                // Lint mode rewrites Kern extension syntaxes into more portable patterns. Some renderers
                // don't support ordered task list items, so emit them as bulleted tasks with the
                // typed number preserved in the text.
                let box = checked ? "x" : " "
                line = "- [\(box)] \(n). " + exportInline(content)
                softBreakKind = .task
            default:
                let box = checked ? "x" : " "
                line = "\(n).\(markerPadding)[\(box)] " + exportInline(content)
                softBreakKind = .ordered
            }
        } else {
            line = "\(n).\(markerPadding)" + exportInline(content)
            softBreakKind = .ordered
        }
        return serializeSoftLineBreaks(body: indentPrefix + line, kind: softBreakKind)
    }

    // MARK: - Tables (GFM)

    private enum TableColumnAlignment: Int, Hashable {
        case none = 0
        case left = 1
        case center = 2
        case right = 3

        var textAlignment: NSTextAlignment {
            switch self {
            case .right:
                return .right
            case .center:
                return .center
            case .left, .none:
                return .left
            }
        }

        var delimiterCell: String {
            // Canonical: at least 3 dashes.
            switch self {
            case .none:
                return "---"
            case .left:
                return ":---"
            case .center:
                return ":---:"
            case .right:
                return "---:"
            }
        }
    }

    private struct GfmTable {
        /// Includes header row at index 0.
        var rows: [[String]]
        var alignments: [TableColumnAlignment]
        var columnCount: Int
    }

    private struct GfmTableMatch {
        var table: GfmTable
        /// Line index after the table (does not consume the trailing blank line, if any).
        var endIndex: Int
    }

    /// Optional debug logging for table parsing. Evaluate once to avoid per-line env lookups.
    private static let debugTableParseEnabled: Bool = {
        ProcessInfo.processInfo.environment["KERN_DEBUG_TABLE_PARSE"] == "1"
    }()

    /// Pre-compiled regex for reference definition parsing (avoids recompilation per line).
    private static let referenceDefinitionRegex: NSRegularExpression =
        try! NSRegularExpression(pattern: #"^\[([^\]]+)\]:\s*(\S+)(?:\s+["']([^"']+)["'])?\s*$"#)

    /// Cache for syntax highlighting regexes (bounded by language × pattern count, ~150 entries max).
    nonisolated(unsafe) private static var syntaxHighlightingRegexCache: [String: NSRegularExpression] = [:]

    /// Cache for list marker width measurements (avoids repeated CoreText layout calls).
    nonisolated(unsafe) private static var markerWidthCache: [String: CGFloat] = [:]

    /// Cache for reusable paragraph styles keyed by list depth + marker geometry.
    nonisolated(unsafe) private static var listParagraphStyleCache: [ListParagraphStyleCacheKey: NSParagraphStyle] = [:]
    /// Cache for reusable rendered list/task marker prefixes.
    nonisolated(unsafe) private static var listMarkerPrefixCache: [ListMarkerPrefixCacheKey: ListMarkerPrefixTemplate] = [:]

    private struct InlineFontCacheKey: Hashable {
        let fontName: String
        let pointSize: CGFloat
        let code: Bool
        let strong: Bool
        let emphasis: Bool
    }

    private struct InlineAttributeCacheKey: Hashable {
        let fontName: String
        let pointSizeTimes100: Int
        let code: Bool
        let strong: Bool
        let emphasis: Bool
        let strike: Bool
        let themeSignature: String
    }

    private struct ListParagraphStyleCacheKey: Hashable {
        let listDepth: Int
        let markerAdvanceTimes100: Int
    }

    private enum ListMarkerPrefixKind: Hashable {
        case bullet
        case taskStandalone(checked: Bool)
        case taskBulleted(checked: Bool)
        case ordered(marker: String, depth: Int)
    }

    private struct ListMarkerPrefixCacheKey: Hashable {
        let kind: ListMarkerPrefixKind
        let fontName: String
        let pointSizeTimes100: Int
        let themeSignature: String
    }

    private struct ListMarkerPrefixTemplate {
        let attributed: NSAttributedString
        let markerLength: Int
        let markerAdvance: CGFloat
    }

    private struct CodeBlockFontCacheKey: Hashable {
        let fontName: String
        let pointSizeTimes100: Int
    }

    private struct HeadingParagraphStyleCacheKey: Hashable {
        let level: Int
    }

    private struct CodeBlockParagraphStyleSet {
        let first: NSParagraphStyle
        let middle: NSParagraphStyle
        let last: NSParagraphStyle
        let single: NSParagraphStyle
    }

    /// Cache for inline font trait combinations (avoids repeated NSFontManager trait conversions).
    nonisolated(unsafe) private static var inlineFontCache: [InlineFontCacheKey: NSFont] = [:]
    /// Cache for inline attribute dictionaries when no link metadata is present.
    nonisolated(unsafe) private static var inlineAttributeCache: [InlineAttributeCacheKey: [NSAttributedString.Key: Any]] = [:]
    /// Cache for monospaced code-block fonts keyed by the source font geometry.
    nonisolated(unsafe) private static var codeBlockFontCache: [CodeBlockFontCacheKey: NSFont] = [:]
    /// Cache for heading paragraph styles keyed by heading level.
    nonisolated(unsafe) private static var headingParagraphStyleCache: [HeadingParagraphStyleCacheKey: NSParagraphStyle] = [:]
    /// Shared code-block paragraph styles; these are content-independent and safe to reuse.
    private static let codeBlockParagraphStyles: CodeBlockParagraphStyleSet = {
        let topSpacing = CodeBlockChromeGeometry.paragraphSpacingBefore
        let bottomSpacing = CodeBlockChromeGeometry.paragraphSpacingAfter

        func makeStyle(paragraphSpacingBefore: CGFloat, paragraphSpacing: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.paragraphSpacingBefore = paragraphSpacingBefore
            style.paragraphSpacing = paragraphSpacing
            return style.copy() as! NSParagraphStyle
        }

        return CodeBlockParagraphStyleSet(
            first: makeStyle(paragraphSpacingBefore: topSpacing, paragraphSpacing: 0),
            middle: makeStyle(paragraphSpacingBefore: 0, paragraphSpacing: 0),
            last: makeStyle(paragraphSpacingBefore: 0, paragraphSpacing: bottomSpacing),
            single: makeStyle(paragraphSpacingBefore: topSpacing, paragraphSpacing: bottomSpacing)
        )
    }()
    private static let cacheLock = NSLock()

    @inline(__always)
    private static func withCacheLock<T>(_ body: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body()
    }

    static func resetCachesForTesting() {
        withCacheLock {
            syntaxHighlightingRegexCache.removeAll()
            markerWidthCache.removeAll()
            listParagraphStyleCache.removeAll()
            listMarkerPrefixCache.removeAll()
            inlineFontCache.removeAll()
            inlineAttributeCache.removeAll()
            codeBlockFontCache.removeAll()
            headingParagraphStyleCache.removeAll()
        }
        sharedInlineParseCache.removeAll()
        sharedCodeBlockAttributedCache.removeAll()
        sharedTableAttributedCache.removeAll()
    }

    private static let largeDocumentPlainImportThreshold = 1_000_000

    private static func shouldUseLargeDocumentPlainImport(options: Options, markdownLength: Int) -> Bool {
        if ProcessInfo.processInfo.environment["KERN_FORCE_FULL_MARKDOWN_IMPORT"] == "1" {
            return false
        }
        if ProcessInfo.processInfo.environment["KERN_FORCE_PLAIN_MARKDOWN_IMPORT"] == "1" {
            let env = ProcessInfo.processInfo.environment
            // Guard against shell-level leakage of KERN_FORCE_PLAIN_MARKDOWN_IMPORT into normal
            // interactive app launches (which would degrade to raw Markdown rendering).
            // Require explicit opt-in for forced plain mode, unless running under XCTest.
            if env["KERN_ALLOW_PLAIN_IMPORT_OVERRIDE"] == "1" || NSClassFromString("XCTestCase") != nil {
                return true
            }
            return false
        }
        guard options.largeDocumentPlainImportEnabled else { return false }
        return markdownLength >= largeDocumentPlainImportThreshold
    }

    private static func makeLargeDocumentPlainAttributed(markdown: String, baseFont: NSFont) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }
        let attrs = baseAttributes(baseFont: baseFont)
        let result = NSMutableAttributedString(string: markdown, attributes: attrs)
        result.addAttribute(
            .kernBlockKind,
            value: KernBlockKind.paragraph.rawValue,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func shouldEnableSyntaxHighlighting(options: Options, markdownLength: Int) -> Bool {
        if ProcessInfo.processInfo.environment["KERN_FORCE_SYNTAX_HIGHLIGHTING"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["KERN_DISABLE_SYNTAX_HIGHLIGHTING"] == "1" {
            return false
        }
        guard options.syntaxHighlightingEnabled else { return false }
        // Keep syntax highlighting enabled for large documents.
        // Performance should be managed by staged rendering / scheduling, not by silently
        // dropping visual fidelity features.
        _ = markdownLength
        return true
    }

    /// Fast blank-line test used in the importer hot path.
    /// Avoids `trimmingCharacters` allocations while preserving whitespace semantics.
    private static func isBlankMarkdownLine(_ line: String) -> Bool {
        for scalar in line.unicodeScalars where !scalar.properties.isWhitespace {
            return false
        }
        return true
    }

    /// Quick boundary pre-check used to skip the expensive block parser cascade
    /// for the dominant plain-paragraph path.
    private static func mayStartStructuralBlockLine(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        if first == " " || first == "\t" { return true }
        if first == "[" || first == "#" || first == "-" || first == "*" ||
            first == "+" || first == "`" || first == "~" || first == "$" ||
            first == "!" || first == ">" || first == "_" || first == "="
        {
            return true
        }
        if first.isNumber { return true }
        if line.contains("|") { return true } // table candidate
        return false
    }

    /// Fast boundary check for list/task continuation folding. This mirrors the
    /// existing break conditions, but avoids paying the cost of the full block
    /// parser cascade on every candidate continuation line.
    private static func startsNestedBlockWithinListContinuation(_ line: String, options: Options) -> Bool {
        guard !line.isEmpty, mayStartStructuralBlockLine(line) else { return false }
        let (_, rest) = parseLeadingIndent(line)
        guard let first = rest.first else { return false }

        switch first {
        case "#":
            return parseHeading(line) != nil
        case "`", "~":
            return parseFenceStart(line) != nil
        case "[", "-", "*", "+":
            if parseTask(line) != nil {
                return true
            }
            return parseBullet(line) != nil
        default:
            if first.isNumber {
                if options.orderedTasksEnabled, parseOrderedTask(line) != nil {
                    return true
                }
                return parseOrdered(line) != nil
            }
            return false
        }
    }

    /// Setext underline candidates must start (after optional leading whitespace)
    /// with `=` or `-`. Fast-path this check before calling the full parser.
    private static func mayBeSetextUnderlineLine(_ line: String) -> Bool {
        for scalar in line.unicodeScalars {
            if scalar.properties.isWhitespace {
                continue
            }
            return scalar == "=" || scalar == "-"
        }
        return false
    }

    private static func canStartGfmTable(_ lines: [String], startIndex: Int) -> Bool {
        guard startIndex >= 0, startIndex + 1 < lines.count else { return false }
        let header = lines[startIndex]
        let delimiter = lines[startIndex + 1]
        return header.contains("|") && delimiter.contains("|")
    }

    private static func parseGfmTable(
        _ lines: [String],
        startIndex: Int,
        profiler: ImportProfiler? = nil
    ) -> GfmTableMatch? {
        measureImportPhase(.parseGfmTable, profiler: profiler) {
            guard startIndex + 1 < lines.count else { return nil }

            let headerLine = lines[startIndex]
            let delimiterLine = lines[startIndex + 1]

            let debug = debugTableParseEnabled
            func dbg(_ message: String) {
                guard debug else { return }
                NSLog("[NativeMarkdownCodec.TableParse] %@", message)
            }

            // Quick heuristic: both rows must contain at least one pipe.
            guard headerLine.contains("|"), delimiterLine.contains("|") else { return nil }

            let headerCells = splitGfmTableRow(headerLine)
            let delimiterCells = splitGfmTableRow(delimiterLine)

            if debug {
                dbg("startIndex=\(startIndex) header=\(headerLine.debugDescription) delimiter=\(delimiterLine.debugDescription)")
                dbg("headerCells=\(headerCells.map { $0.debugDescription }) delimiterCells=\(delimiterCells.map { $0.debugDescription })")
            }

            // Tables require at least 2 columns and a delimiter count that matches header columns.
            // This avoids false positives like:
            // | a | b |
            // | --- |
            guard headerCells.count >= 2, delimiterCells.count == headerCells.count else {
                dbg("reject: <2 columns header=\(headerCells.count) delimiter=\(delimiterCells.count)")
                return nil
            }

            var alignments: [TableColumnAlignment] = []
            for c in delimiterCells {
                guard let a = parseGfmTableDelimiterCell(c) else {
                    dbg("reject: delimiter cell parse failed: \(c.debugDescription)")
                    return nil
                }
                alignments.append(a)
            }

            let columnCount = headerCells.count
            let normalizedHeader = normalizeTableRow(headerCells, to: columnCount)

            var rows: [[String]] = [normalizedHeader]

            var j = startIndex + 2
            while j < lines.count {
                let line = lines[j]
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                // Stop once we hit a line that doesn't look like a table row.
                if !line.contains("|") { break }

                let cells = splitGfmTableRow(line)
                if cells.count < 2 { break }
                rows.append(normalizeTableRow(cells, to: columnCount))
                j += 1
            }

            let paddedAlignments: [TableColumnAlignment] = {
                if alignments.count >= columnCount { return Array(alignments.prefix(columnCount)) }
                return alignments + Array(repeating: .none, count: columnCount - alignments.count)
            }()

            return GfmTableMatch(
                table: GfmTable(rows: rows, alignments: paddedAlignments, columnCount: columnCount),
                endIndex: j
            )
        }
    }

    private static func splitGfmTableRow(_ line: String) -> [String] {
        // Be tolerant of different line endings (ex: CRLF sources can leave trailing `\r` after
        // splitting on `\n`). Tables are line-oriented, so trimming newlines here is safe and
        // prevents false negatives in delimiter parsing.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let startsWithPipe = trimmed.first == "|"
        let endsWithPipe = trimmed.last == "|"

        var cells: [String] = []
        var current = ""
        var escapeNext = false
        var inCodeSpan = false

        for ch in trimmed {
            if escapeNext {
                current.append(ch)
                escapeNext = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escapeNext = true
                continue
            }
            if ch == "`" {
                current.append(ch)
                inCodeSpan.toggle()
                continue
            }
            if ch == "|", !inCodeSpan {
                cells.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        cells.append(current)

        // Ignore optional leading/trailing pipes.
        if startsWithPipe, !cells.isEmpty { cells.removeFirst() }
        if endsWithPipe, !cells.isEmpty { cells.removeLast() }

        return cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func parseGfmTableDelimiterCell(_ cell: String) -> TableColumnAlignment? {
        // Example: ":---", ":---:", "---:", "---"
        let stripped = String(cell.filter { !$0.isWhitespace })
        guard !stripped.isEmpty else { return nil }

        let leadingColon = stripped.first == ":"
        let trailingColon = stripped.last == ":"

        // Validate allowed characters and require at least one dash.
        var dashCount = 0
        for ch in stripped {
            if ch == "-" { dashCount += 1; continue }
            if ch == ":" { continue }
            return nil
        }
        guard dashCount >= 1 else { return nil }

        switch (leadingColon, trailingColon) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return TableColumnAlignment.none
        }
    }

    private static func normalizeTableRow(_ cells: [String], to columnCount: Int) -> [String] {
        var out = cells
        if out.count < columnCount {
            out.append(contentsOf: Array(repeating: "", count: columnCount - out.count))
        } else if out.count > columnCount {
            out = Array(out.prefix(columnCount))
        }
        return out
    }

    private static func makeGfmTableAttributed(_ table: GfmTable, tableID: Int, baseFont: NSFont, terminateLastParagraph: Bool, ctx: ImportContext) -> NSAttributedString {
        let cacheKey = TableAttributedCacheKey(
            rows: table.rows,
            alignments: table.alignments,
            fontName: baseFont.fontName,
            pointSize: baseFont.pointSize,
            terminateLastParagraph: terminateLastParagraph,
            themeSignature: ctx.themeSignature,
            baseURLSignature: ctx.baseURLSignature,
            referenceDefinitionsSignature: ctx.referenceDefinitionsSignature,
            remoteImageLoadingEnabled: ctx.options.remoteImageLoadingEnabled
        )
        if let cached = sharedTableAttributedCache.value(for: cacheKey) {
            return rebindCachedTableAttributed(cached, tableID: tableID)
        }

        let out = NSMutableAttributedString()

        let textTable = NSTextTable()
        textTable.numberOfColumns = max(1, table.columnCount)
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setContentWidth(100, type: .percentageValueType)

        let headerFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        let bodyParagraphTerminator = NSAttributedString(
            string: "\n",
            attributes: baseAttributes(baseFont: baseFont)
        )
        let headerParagraphTerminator = NSAttributedString(
            string: "\n",
            attributes: baseAttributes(baseFont: headerFont)
        )

        let lastRowIndex = max(0, table.rows.count - 1)
        let lastColIndex = max(0, table.columnCount - 1)

        for (r, row) in table.rows.enumerated() {
            let isHeader = (r == 0)
            for c in 0..<table.columnCount {
                let isLastCell = (r == lastRowIndex && c == lastColIndex)
                let terminates = !isLastCell || terminateLastParagraph

                let cellText = c < row.count ? row[c] : ""
                let alignment = c < table.alignments.count ? table.alignments[c] : .none
                let font = isHeader ? headerFont : baseFont
                let paragraphTerminator = terminates
                    ? (isHeader ? headerParagraphTerminator : bodyParagraphTerminator)
                    : nil

                let cellPara = makeGfmTableCellParagraph(
                    text: cellText,
                    baseFont: font,
                    table: textTable,
                    tableID: tableID,
                    row: r,
                    column: c,
                    isHeader: isHeader,
                    alignment: alignment,
                    columnCount: table.columnCount,
                    paragraphTerminator: paragraphTerminator,
                    ctx: ctx
                )
                out.append(cellPara)
            }
        }

        let frozen = NSAttributedString(attributedString: out)
        sharedTableAttributedCache.insert(frozen, for: cacheKey)
        return out
    }

    private static func rebindCachedTableAttributed(_ cached: NSAttributedString, tableID: Int) -> NSAttributedString {
        let rebound = NSMutableAttributedString(attributedString: cached)
        let ns = rebound.string as NSString
        var index = 0
        while index < ns.length {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: index, length: 0))
            guard paragraphRange.length > 0 else { break }
            if let kindRaw = rebound.attribute(.kernBlockKind, at: paragraphRange.location, effectiveRange: nil) as? Int,
               let kind = KernBlockKind(rawValue: kindRaw),
               kind == .tableCell {
                rebound.addAttribute(.kernTableID, value: tableID, range: paragraphRange)
            }
            index = paragraphRange.location + paragraphRange.length
        }
        return rebound
    }

    private static func makeGfmTableCellParagraph(
        text: String,
        baseFont: NSFont,
        table: NSTextTable,
        tableID: Int,
        row: Int,
        column: Int,
        isHeader: Bool,
        alignment: TableColumnAlignment,
        columnCount: Int,
        paragraphTerminator: NSAttributedString?,
        ctx: ImportContext
    ) -> NSAttributedString {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.verticalAlignment = .topAlignment
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        if isHeader {
            block.backgroundColor = NativeEditorAppearance.tableHeaderBackgroundColor()
        }

        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0
        style.alignment = alignment.textAlignment

        let para = NSMutableAttributedString()
        if text.isEmpty {
            // Empty cells are common in benchmark fixtures; skip parseInline and materialize only
            // the paragraph terminator/bounds chrome when the cell has no content.
        } else if !containsInlineSyntax(in: text) {
            para.append(makeInlineAttributed(text, baseFont: baseFont, style: InlineStyle()))
        } else {
            para.append(parseInline(text, baseFont: baseFont, ctx: ctx))
        }

        if let paragraphTerminator {
            para.append(paragraphTerminator)
        }

        let full = NSRange(location: 0, length: para.length)
        para.addAttributes([
            .paragraphStyle: style,
            .kernBlockKind: KernBlockKind.tableCell.rawValue,
            .kernTableID: tableID,
            .kernTableRow: row,
            .kernTableColumn: column,
            .kernTableIsHeader: isHeader,
            .kernTableColumnAlignment: alignment.rawValue,
            .kernTableColumnCount: columnCount
        ], range: full)

        return para
    }

    private static func exportGfmTableBlock(_ attributed: NSAttributedString, ns: NSString, startIndex: Int, tableID: Int) -> (block: String, nextIndex: Int) {
        var j = startIndex
        var cells: [(row: Int, col: Int, isHeader: Bool, alignment: TableColumnAlignment, content: NSAttributedString)] = []

        var inferredColumnCount: Int?
        var maxRow = 0
        var maxCol = 0
        var alignmentsByCol: [Int: TableColumnAlignment] = [:]

        while j < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
            let p = attributed.attributedSubstring(from: r)
            if p.length == 0 { break }

            let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
            let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            guard k == .tableCell else { break }

            let id = (p.attribute(.kernTableID, at: 0, effectiveRange: nil) as? Int) ?? -1
            guard id == tableID else { break }

            let row = (p.attribute(.kernTableRow, at: 0, effectiveRange: nil) as? Int) ?? 0
            let col = (p.attribute(.kernTableColumn, at: 0, effectiveRange: nil) as? Int) ?? 0
            let isHeader = (p.attribute(.kernTableIsHeader, at: 0, effectiveRange: nil) as? Bool) ?? false
            let alignRaw = (p.attribute(.kernTableColumnAlignment, at: 0, effectiveRange: nil) as? Int) ?? TableColumnAlignment.none.rawValue
            let alignment = TableColumnAlignment(rawValue: alignRaw) ?? .none
            let colCount = (p.attribute(.kernTableColumnCount, at: 0, effectiveRange: nil) as? Int) ?? 0
            if inferredColumnCount == nil, colCount > 0 {
                inferredColumnCount = colCount
            }

            alignmentsByCol[col] = alignmentsByCol[col] ?? alignment

            maxRow = max(maxRow, row)
            maxCol = max(maxCol, col)

            // Drop trailing newline from the cell paragraph.
            let cellText = p.string.hasSuffix("\n") ? String(p.string.dropLast()) : p.string
            let cellLen = (cellText as NSString).length
            let content = p.attributedSubstring(from: NSRange(location: 0, length: min(p.length, cellLen)))

            cells.append((row: row, col: col, isHeader: isHeader, alignment: alignment, content: content))

            j = r.location + r.length
        }

        let columnCount = max(2, inferredColumnCount ?? (maxCol + 1))
        let rowCount = max(1, maxRow + 1)

        var matrix: [[String]] = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for c in cells {
            guard c.row >= 0, c.row < rowCount, c.col >= 0, c.col < columnCount else { continue }
            let raw = exportInline(c.content)
            matrix[c.row][c.col] = escapeGfmTableCell(raw)
        }

        var columnAlignments: [TableColumnAlignment] = (0..<columnCount).map { alignmentsByCol[$0] ?? .none }

        // If the delimiter row wasn't fully specified, keep it stable by defaulting missing cols to `.none`.
        if columnAlignments.count < columnCount {
            columnAlignments.append(contentsOf: Array(repeating: .none, count: columnCount - columnAlignments.count))
        } else if columnAlignments.count > columnCount {
            columnAlignments = Array(columnAlignments.prefix(columnCount))
        }

        let headerRow = matrix[0]
        let headerLine = serializeGfmTableRow(headerRow)
        let delimiterLine = serializeGfmTableDelimiterRow(columnAlignments)

        var lines: [String] = [headerLine, delimiterLine]
        if rowCount > 1 {
            for r in 1..<rowCount {
                lines.append(serializeGfmTableRow(matrix[r]))
            }
        }

        return (block: lines.joined(separator: "\n"), nextIndex: j)
    }

    private static func escapeGfmTableCell(_ raw: String) -> String {
        // Tables can't safely contain newlines. Represent soft breaks as HTML <br>.
        let s = raw
            .replacingOccurrences(of: "\u{2028}", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")

        // Escape pipes so we don't break the table structure.
        // Pipes inside inline code spans don't need escaping (they are not treated as column delimiters).
        var out = ""
        out.reserveCapacity(s.count)
        var escapeNext = false
        var inCodeSpan = false
        for ch in s {
            if escapeNext {
                out.append(ch)
                escapeNext = false
                continue
            }
            if ch == "\\" {
                out.append(ch)
                escapeNext = true
                continue
            }
            if ch == "`" {
                out.append(ch)
                inCodeSpan.toggle()
                continue
            }
            if ch == "|", !inCodeSpan {
                out.append("\\|")
                continue
            }
            out.append(ch)
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func serializeGfmTableRow(_ cells: [String]) -> String {
        let normalized = cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "| " + normalized.joined(separator: " | ") + " |"
    }

    private static func serializeGfmTableDelimiterRow(_ alignments: [TableColumnAlignment]) -> String {
        "| " + alignments.map { $0.delimiterCell }.joined(separator: " | ") + " |"
    }

    // MARK: - Block parsing

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let idx = line.index(line.startIndex, offsetBy: level)
        guard idx < line.endIndex else { return nil }
        guard line[idx] == " " else { return nil }
        let textStart = line.index(after: idx)
        let text = String(line[textStart...])
        return (level, text)
    }

    private static func parseSetextUnderline(_ line: String) -> Int? {
        let (indent, rest) = parseLeadingIndent(line)
        guard indent <= 3 else { return nil }

        let trimmed = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        guard let marker = trimmed.first else { return nil }
        guard marker == "=" || marker == "-" else { return nil }
        guard trimmed.allSatisfy({ $0 == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private struct SetextHeadingMatch {
        let level: Int
        let text: String
        let nextIndex: Int
    }

    private static func parseSetextHeading(
        _ lines: [String],
        startIndex: Int,
        quoteDepth: Int,
        options: Options
    ) -> SetextHeadingMatch? {
        guard startIndex + 1 < lines.count else { return nil }

        // Without full lazy blockquote support, avoid incorrectly promoting the line immediately
        // after a blockquote marker to a standalone setext heading.
        if quoteDepth == 0, startIndex > 0, parseBlockquotePrefix(lines[startIndex - 1]) != nil {
            return nil
        }

        func unquoted(_ index: Int) -> String? {
            guard index < lines.count else { return nil }
            let raw = lines[index]
            guard quoteDepth > 0 else { return raw }
            guard let q = parseBlockquotePrefix(raw), q.depth >= quoteDepth else { return nil }
            return q.text
        }

        guard let first = unquoted(startIndex) else { return nil }
        let firstText = first.trimmingCharacters(in: .whitespaces)
        let (firstIndent, _) = parseLeadingIndent(first)
        guard firstIndent <= 3, !firstText.isEmpty else { return nil }
        if parseHeading(first) != nil
            || parseFenceStart(first) != nil
            || parseTask(first) != nil
            || parseOrdered(first) != nil
            || parseBullet(first) != nil
            || parseThematicBreak(first) != nil
            || (options.orderedTasksEnabled && parseOrderedTask(first) != nil)
        {
            return nil
        }

        var contentLines: [String] = []
        var i = startIndex
        while i < lines.count {
            guard let line = unquoted(i) else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }

            if !contentLines.isEmpty {
                if let level = parseSetextUnderline(line) {
                    return SetextHeadingMatch(level: level, text: contentLines.joined(separator: "\u{2028}"), nextIndex: i + 1)
                }

                if parseHeading(line) != nil
                    || parseFenceStart(line) != nil
                    || parseTask(line) != nil
                    || parseOrdered(line) != nil
                    || parseBullet(line) != nil
                    || parseThematicBreak(line) != nil
                    || isMathBlockDelimiter(line)
                    || (options.orderedTasksEnabled && parseOrderedTask(line) != nil)
                {
                    return nil
                }
            }

            contentLines.append(line)
            i += 1
        }

        return nil
    }

    /// Returns the marker that should be used when exporting this thematic break, or nil if the line
    /// isn't a thematic break.
    private static func parseThematicBreak(_ line: String) -> String? {
        // CommonMark allows up to 3 leading spaces before a thematic break.
        let (indent, rest) = parseLeadingIndent(line)
        guard indent <= 3 else { return nil }

        // Keep spacing so export can distinguish canonical (`---`, `***`, `___`) from
        // non-canonical variants (`- - -`, trailing-space, indented forms).
        let candidate = String(rest).trimmingCharacters(in: .newlines)
        if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }

        // CommonMark allows spaces/tabs between markers.
        // Preserve the author's chosen marker pattern to avoid introducing setext-heading ambiguity
        // when exporting paragraph-following thematic breaks.
        let compact = candidate.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else { return nil }
        guard compact.allSatisfy({ $0 == first }) else { return nil }

        // Preserve exact canonical forms only when truly canonical and unindented.
        if indent == 0, (candidate == "---" || candidate == "***" || candidate == "___") {
            return candidate
        }

        // For non-canonical variants, keep leading indent for downstream canonicalization checks.
        if indent > 0 {
            return String(repeating: " ", count: indent) + candidate
        }
        return candidate
    }

    private static func parseBlockquotePrefix(_ line: String) -> (depth: Int, text: String)? {
        // CommonMark: up to 3 leading spaces are allowed before the '>' marker.
        var idx = line.startIndex
        var leading = 0
        while idx < line.endIndex, leading < 3, line[idx] == " " {
            leading += 1
            idx = line.index(after: idx)
        }

        var depth = 0
        while idx < line.endIndex, line[idx] == ">" {
            depth += 1
            idx = line.index(after: idx)
            if idx < line.endIndex, line[idx] == " " {
                idx = line.index(after: idx)
            }
        }

        guard depth > 0 else { return nil }
        return (depth: depth, text: String(line[idx...]))
    }

    private static func parseCalloutMarker(_ line: String) -> (kind: KernCalloutKind, foldSuffix: String?, text: String)? {
        let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLeading.hasPrefix("[!") else { return nil }
        guard let close = trimmedLeading.firstIndex(of: "]") else { return nil }

        let rawKindStart = trimmedLeading.index(trimmedLeading.startIndex, offsetBy: 2)
        let rawKind = String(trimmedLeading[rawKindStart..<close])
        guard let kind = KernCalloutKind.normalized(from: rawKind) else { return nil }

        var restStart = trimmedLeading.index(after: close)
        var foldSuffix: String?
        if restStart < trimmedLeading.endIndex,
           trimmedLeading[restStart] == "+" || trimmedLeading[restStart] == "-" {
            foldSuffix = String(trimmedLeading[restStart])
            restStart = trimmedLeading.index(after: restStart)
        }
        let rest = String(trimmedLeading[restStart...]).trimmingCharacters(in: .whitespaces)
        return (kind, foldSuffix, rest)
    }

    private struct FenceStart {
        let infoString: String?
        let language: String?
        let marker: Character
        let length: Int
        let indent: Int
    }

    private struct FenceContext {
        let fence: FenceStart
        let listIndent: Int
    }

    private static func parseFenceStartInContext(
        line: String,
        lines: [String],
        index: Int,
        quoteDepth: Int
    ) -> FenceContext? {
        // Fast path: most fences are not list-indented and can be parsed directly
        // without scanning previous lines for list continuation context.
        if let fence = parseFenceStart(line) {
            return FenceContext(fence: fence, listIndent: 0)
        }

        // If the line has no leading indentation, list-context fence recovery is impossible.
        if let first = line.first, first != " ", first != "\t" {
            return nil
        }
        // Skip expensive list-context lookup when the line clearly cannot be a fence.
        if !line.contains("`"), !line.contains("~") {
            return nil
        }

        if let ctx = previousListContinuationContext(lines, before: index, quoteDepth: quoteDepth) {
            let prefix = String(repeating: " ", count: max(0, ctx.indent))
            if line.hasPrefix(prefix) {
                let stripped = String(line.dropFirst(prefix.count))
                if let fence = parseFenceStart(stripped) {
                    return FenceContext(fence: fence, listIndent: ctx.indent)
                }
            }
        }
        return nil
    }

    private static func parseFenceStart(_ line: String) -> FenceStart? {
        let (indent, restLine) = parseLeadingIndent(line)
        guard indent <= 3 else { return nil }
        guard let marker = restLine.first, marker == "`" || marker == "~" else { return nil }

        var count = 0
        var idx = restLine.startIndex
        while idx < restLine.endIndex, restLine[idx] == marker {
            count += 1
            idx = restLine.index(after: idx)
        }
        guard count >= 3 else { return nil }

        let rest = restLine[idx...].trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return FenceStart(infoString: nil, language: nil, marker: marker, length: count, indent: indent) }
        if marker == "`", rest.contains("`") {
            // CommonMark: backtick-fenced info strings cannot contain backticks.
            return nil
        }
        // CommonMark info string can include metadata after the language token.
        // Use only the first token for UI language pills and syntax highlighting.
        let firstToken = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        let language = firstToken.map(String.init) ?? rest
        return FenceStart(infoString: rest, language: language, marker: marker, length: count, indent: indent)
    }

    private static func isFenceEnd(_ line: String, fence: FenceStart) -> Bool {
        let (indent, rest) = parseLeadingIndent(line)
        guard indent <= 3 else { return false }
        let trimmed = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.allSatisfy({ $0 == fence.marker }) else { return false }
        return trimmed.count >= fence.length
    }

    private static func isMathBlockDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "$$"
    }

    private static func parseReferenceDefinition(_ line: String) -> ReferenceDefinition? {
        let (indent, rest) = parseLeadingIndent(line)
        guard indent <= 3 else { return nil }
        let candidate = String(rest)
        // Fast guards before regex.
        guard candidate.first == "[" else { return nil }
        guard candidate.contains("]:") else { return nil }

        let re = referenceDefinitionRegex
        let ns = candidate as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: candidate, options: [], range: full) else { return nil }
        guard m.numberOfRanges >= 3 else { return nil }

        let id = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !destination.isEmpty else { return nil }

        var title: String?
        if m.numberOfRanges >= 4, m.range(at: 3).location != NSNotFound {
            title = ns.substring(with: m.range(at: 3))
        }
        return ReferenceDefinition(id: id, destination: destination, title: title)
    }

    private struct IndentedCodeBlock {
        let codeLines: [String]
        let nextIndex: Int
    }

    private static func parseIndentedCodeBlock(_ lines: [String], startIndex: Int, quoteDepth: Int) -> IndentedCodeBlock? {
        guard startIndex < lines.count else { return nil }

        func unquotedLine(_ index: Int) -> String? {
            guard index < lines.count else { return nil }
            let raw = lines[index]
            guard quoteDepth > 0 else { return raw }
            guard let q = parseBlockquotePrefix(raw), q.depth >= quoteDepth else { return nil }
            return q.text
        }

        guard let firstRaw = unquotedLine(startIndex) else { return nil }
        if firstRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if let first = firstRaw.first, first != " ", first != "\t" {
            return nil
        }

        let listContext = previousListContinuationContext(lines, before: startIndex, quoteDepth: quoteDepth)
        let firstLine = listContext.map { stripFenceIndent(firstRaw, indent: $0.indent) } ?? firstRaw
        guard firstLine.hasPrefix("    ") || firstLine.hasPrefix("\t") else { return nil }

        if let ctx = listContext {
            let (currentIndent, _) = parseLeadingIndent(firstRaw)
            // Inside list items, indentation less than (content indent + 4) is paragraph continuation,
            // not an indented code block.
            if currentIndent < ctx.indent + 4 {
                return nil
            }
        }

        var out: [String] = []
        var i = startIndex
        while i < lines.count {
            guard let currentRaw = unquotedLine(i) else { break }
            let current = listContext.map { stripFenceIndent(currentRaw, indent: $0.indent) } ?? currentRaw
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if current.hasPrefix("\t") {
                    out.append(String(current.dropFirst()))
                } else if current.hasPrefix("    ") {
                    out.append(String(current.dropFirst(4)))
                } else {
                    out.append("")
                }
                i += 1
                continue
            }
            if current.hasPrefix("\t") {
                out.append(String(current.dropFirst()))
                i += 1
                continue
            }
            if current.hasPrefix("    ") {
                out.append(String(current.dropFirst(4)))
                i += 1
                continue
            }
            break
        }

        while let last = out.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.removeLast()
        }

        guard !out.isEmpty else { return nil }
        return IndentedCodeBlock(codeLines: out, nextIndex: i)
    }

    private struct ListContinuationContext {
        let indent: Int
        let depth: Int
    }

    private static func previousListContinuationContext(_ lines: [String], before index: Int, quoteDepth: Int) -> ListContinuationContext? {
        guard index > 0 else { return nil }
        var j = index - 1
        while j >= 0 {
            var line = lines[j]
            if quoteDepth > 0 {
                guard let q = parseBlockquotePrefix(line), q.depth >= quoteDepth else { return nil }
                line = q.text
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if j == 0 { break }
                j -= 1
                continue
            }

            if let ordered = parseOrdered(line) {
                return ListContinuationContext(indent: ordered.indent + ordered.markerLen, depth: ordered.depth)
            }
            if let orderedTask = parseOrderedTask(line) {
                return ListContinuationContext(indent: orderedTask.indent + orderedTask.markerLen, depth: orderedTask.depth)
            }
            if let bullet = parseBullet(line) {
                return ListContinuationContext(indent: bullet.indent + 1 + max(1, bullet.markerPadding.count), depth: bullet.depth)
            }
            if let task = parseTask(line), task.style == .bulleted {
                return ListContinuationContext(indent: task.indent + 1 + max(1, task.markerPadding.count), depth: task.depth)
            }
            let (indent, _) = parseLeadingIndent(line)
            if indent > 0 || parseBlockquotePrefix(line) != nil {
                if j == 0 { return nil }
                j -= 1
                continue
            }
            return nil
        }
        return nil
    }

    private static func canStartIndentedCode(_ lines: [String], at startIndex: Int, quoteDepth: Int) -> Bool {
        // Indented code cannot interrupt a paragraph; require either BOF or a blank previous line
        // within the current quote nesting.
        guard startIndex > 0 else { return true }
        var previous = lines[startIndex - 1]
        if quoteDepth > 0 {
            guard let q = parseBlockquotePrefix(previous), q.depth >= quoteDepth else {
                return false
            }
            previous = q.text
        }
        return previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func parseLeadingIndent(_ line: String) -> (indent: Int, rest: Substring) {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == " " {
                indent += 1
            } else if ch == "\t" {
                // Treat tabs as 4 spaces for indentation semantics.
                indent += 4
            } else {
                break
            }
            idx = line.index(after: idx)
        }
        return (indent, line[idx...])
    }

    private static func stripFenceIndent(_ line: String, indent: Int) -> String {
        guard indent > 0 else { return line }
        var idx = line.startIndex
        var consumed = 0
        while idx < line.endIndex, consumed < indent {
            let ch = line[idx]
            if ch == " " {
                consumed += 1
                idx = line.index(after: idx)
                continue
            }
            if ch == "\t" {
                consumed += 4
                idx = line.index(after: idx)
                continue
            }
            break
        }
        return String(line[idx...])
    }

    private static func parseTask(_ line: String) -> (indent: Int, depth: Int, style: KernTaskStyle, marker: Character?, markerPadding: String, checked: Bool, text: String)? {
        // Task parsing:
        // - Standard GFM: "- [ ] " / "* [x] " / "+ [ ] " (supports extra whitespace + tabs)
        // - Kern/Notion-style shortcut: "[] " / "[x] " / "[ ] " (optionally indented)
        guard line.count >= 3 else { return nil }

        let (indent, rest) = parseLeadingIndent(line)

        // Standard: "- [ ] "
        if let marker = rest.first, marker == "-" || marker == "*" || marker == "+" {
            let afterMarker = rest.dropFirst()
            guard let ws = afterMarker.first, ws == " " || ws == "\t" else { /* not a list marker */ return nil }
            let padding = String(afterMarker.prefix(while: { $0 == " " || $0 == "\t" }))
            let afterWS = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
            guard let open = afterWS.first, open == "[" else { return nil }
            let checkedIndex = afterWS.index(after: afterWS.startIndex)
            guard checkedIndex < afterWS.endIndex else { return nil }
            let closeIndex = afterWS.index(after: checkedIndex)
            guard closeIndex < afterWS.endIndex, afterWS[closeIndex] == "]" else { return nil }
            let checkedChar = afterWS[checkedIndex]
            let checked = checkedChar == "x" || checkedChar == "X"
            // Allow empty task text (`- [ ]`), otherwise require whitespace after closing bracket.
            let spacingIndex = afterWS.index(after: closeIndex)
            if spacingIndex < afterWS.endIndex, afterWS[spacingIndex] != " ", afterWS[spacingIndex] != "\t" {
                return nil
            }
            let text = spacingIndex < afterWS.endIndex
                ? String(afterWS[afterWS.index(after: spacingIndex)...]).trimmingCharacters(in: .whitespaces)
                : ""
            let depth = indent / 2
            return (indent, depth, .bulleted, marker, padding, checked, text)
        }

        // Shortcut: "[] " / "[ ] " / "[x] "
        if rest.hasPrefix("[] ") {
            let text = String(rest.dropFirst(3))
            return (indent, 0, .standalone, nil, "", false, text)
        }
        if rest.hasPrefix("[ ] ") {
            let text = String(rest.dropFirst(4))
            return (indent, 0, .standalone, nil, "", false, text)
        }
        if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            let text = String(rest.dropFirst(4))
            return (indent, 0, .standalone, nil, "", true, text)
        }

        return nil
    }

    private static func parseBullet(_ line: String) -> (indent: Int, depth: Int, marker: Character, markerPadding: String, text: String)? {
        let (indent, rest) = parseLeadingIndent(line)
        guard let marker = rest.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        let afterMarker = rest.dropFirst()
        if afterMarker.isEmpty {
            let depth = indent / 2
            return (indent, depth, marker, "", "")
        }
        guard let ws = afterMarker.first, ws == " " || ws == "\t" else { return nil }
        let padding = String(afterMarker.prefix(while: { $0 == " " || $0 == "\t" }))
        let text = String(afterMarker.drop(while: { $0 == " " || $0 == "\t" }))
        let depth = indent / 2
        return (indent, depth, marker, padding, text)
    }

    private static func parseOrdered(_ line: String) -> (indent: Int, depth: Int, index: Int, markerPadding: String, text: String, markerLen: Int)? {
        // Minimal: "1. text" (digits + '.' + whitespace)
        let (indent, rest) = parseLeadingIndent(line)
        var digitCount = 0
        var n = 0
        var idx = rest.startIndex
        while idx < rest.endIndex, let value = rest[idx].wholeNumberValue {
            n = (n * 10) + value
            digitCount += 1
            idx = rest.index(after: idx)
        }
        guard digitCount > 0 else { return nil }
        let dotIndex = idx
        guard dotIndex < rest.endIndex, rest[dotIndex] == "." else { return nil }
        let afterDot = rest.index(after: dotIndex)
        guard afterDot <= rest.endIndex else { return nil }
        let markerPadding: String
        let text: String
        let markerLen: Int
        if afterDot == rest.endIndex {
            markerPadding = ""
            text = ""
            markerLen = digitCount + 2 // "." + implied single-space continuation
        } else {
            guard rest[afterDot] == " " || rest[afterDot] == "\t" else { return nil }
            let paddingSlice = rest[afterDot...].prefix(while: { $0 == " " || $0 == "\t" })
            markerPadding = String(paddingSlice)
            let textStart = rest.index(afterDot, offsetBy: paddingSlice.count)
            text = String(rest[textStart...])
            markerLen = digitCount + 1 + paddingSlice.count // "." + marker padding
        }
        let depth = indent / 3
        return (indent, depth, n, markerPadding, text, markerLen)
    }

    private static func parseOrderedTask(_ line: String) -> (indent: Int, depth: Int, index: Int, checked: Bool, text: String, markerLen: Int)? {
        // Minimal: "1. [ ] text" (digits + '.' + whitespace + '[' + (' '|'x') + ']' + whitespace)
        let (indent, rest) = parseLeadingIndent(line)
        var digitCount = 0
        var n = 0
        var idx = rest.startIndex
        while idx < rest.endIndex, let value = rest[idx].wholeNumberValue {
            n = (n * 10) + value
            digitCount += 1
            idx = rest.index(after: idx)
        }
        guard digitCount > 0 else { return nil }
        guard idx < rest.endIndex, rest[idx] == "." else { return nil }
        idx = rest.index(after: idx)
        guard idx < rest.endIndex, rest[idx] == " " || rest[idx] == "\t" else { return nil }
        idx = rest.index(after: idx)
        guard idx < rest.endIndex, rest[idx] == "[" else { return nil }
        let checkedIndex = rest.index(after: idx)
        guard checkedIndex < rest.endIndex else { return nil }
        let closeIndex = rest.index(after: checkedIndex)
        guard closeIndex < rest.endIndex, rest[closeIndex] == "]" else { return nil }
        let checkedChar = rest[checkedIndex]
        let checked = checkedChar == "x" || checkedChar == "X"
        let spacingIndex = rest.index(after: closeIndex)
        guard spacingIndex < rest.endIndex, rest[spacingIndex] == " " || rest[spacingIndex] == "\t" else { return nil }
        let text = String(rest[rest.index(after: spacingIndex)...])
        let depth = indent / 3
        let markerLen = digitCount + 2
        return (indent, depth, n, checked, text, markerLen)
    }

    private static func parseHeadingCheckbox(_ text: String) -> (checked: Bool, text: String)? {
        if text.hasPrefix("[] "), text.count >= 3 {
            return (false, String(text.dropFirst(3)))
        }
        if text.hasPrefix("[ ] "), text.count >= 4 {
            return (false, String(text.dropFirst(4)))
        }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] "), text.count >= 4 {
            return (true, String(text.dropFirst(4)))
        }
        return nil
    }

    // MARK: - Block rendering

    private static func makeCalloutParagraph(
        kind: KernCalloutKind,
        text: String,
        containsInlineSyntax: Bool,
        baseFont: NSFont,
        ctx: ImportContext
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()

        var markerAttrs = baseAttributes(baseFont: baseFont)
        markerAttrs[.kernMarker] = true
        markerAttrs[.foregroundColor] = NativeEditorAppearance.calloutStyle(kind: kind).accent
        markerAttrs[.font] = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        para.append(NSAttributedString(string: "\(kind.icon) ", attributes: markerAttrs))

        let body = makeInlineContent(
            text,
            baseFont: baseFont,
            containsInlineSyntax: containsInlineSyntax,
            ctx: ctx
        )
        para.append(body)

        applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
        if para.length > 0 {
            let firstParagraph = (para.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            para.addAttribute(
                .kernCalloutKind,
                value: kind.rawValue,
                range: NSRange(location: 0, length: min(para.length, firstParagraph.length))
            )
        }
        return para
    }

    private static func makeTaskParagraph(
        _ task: (style: KernTaskStyle, marker: Character?, markerPadding: String, checked: Bool, text: String),
        indent: Int,
        depth: Int,
        baseFont: NSFont,
        containsInlineSyntax: Bool,
        options: Options,
        ctx: ImportContext
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()
        let markerTemplate = listMarkerPrefixTemplate(
            kind: task.style == .bulleted && options.taskRendering == .kern
                ? .taskBulleted(checked: task.checked)
                : .taskStandalone(checked: task.checked),
            baseFont: baseFont
        )
        para.append(markerTemplate.attributed)
        let markerLength = markerTemplate.markerLength
        attachMarkerAdvance(markerTemplate.markerAdvance, to: para)

        let content = makeInlineContent(task.text, baseFont: baseFont, containsInlineSyntax: containsInlineSyntax, ctx: ctx)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .task, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernTaskStyle, value: task.style.rawValue, range: NSRange(location: 0, length: min(1, para.length)))
        if let marker = task.marker {
            para.addAttribute(.kernBulletMarker, value: String(marker), range: NSRange(location: 0, length: min(1, para.length)))
            para.addAttribute(.kernListMarkerPadding, value: task.markerPadding, range: NSRange(location: 0, length: min(1, para.length)))
        }

        if task.checked {
            let range = NSRange(location: markerLength, length: max(0, para.length - markerLength))
            if range.length > 0 {
                para.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return para
    }

    private static func makeHeadingWithCheckbox(
        level: Int,
        checked: Bool,
        text: String,
        containsInlineSyntax: Bool,
        baseFont: NSFont,
        ctx: ImportContext
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()

        let heading = headingFont(level: level)

        // Use the heading font for marker spacing so the checkbox doesn't feel "cramped" next to
        // large headings.
        let markerAttrs = baseAttributes(baseFont: heading).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )

        // Match the heading size (Notion-like).
        let checkboxFont = CheckboxStyle.preferredFont(pointSize: heading.pointSize)
        let checkboxChar = checked ? "\u{2611}" : "\u{2610}"
        var checkboxAttrs = markerAttrs
        checkboxAttrs[.font] = checkboxFont
        checkboxAttrs[.foregroundColor] = NSColor.clear
        checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: heading, checkboxFont: checkboxFont)
        checkboxAttrs[.kernCheckbox] = true
        checkboxAttrs[.kernCheckboxChecked] = checked
        para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
        para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        para.append(makeInlineContent(text, baseFont: heading, containsInlineSyntax: containsInlineSyntax, ctx: ctx))

        applyBlockAttributes(para, kind: .heading, baseFont: baseFont, headingLevel: max(1, min(6, level)))

        if checked {
            let markerLen = markerPrefixLength(in: para)
            let range = NSRange(location: markerLen, length: max(0, para.length - markerLen))
            if range.length > 0 {
                para.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        return para
    }

    private static func makeBulletParagraph(_ text: String, marker: Character, markerPadding: String, indent: Int, depth: Int, baseFont: NSFont, containsInlineSyntax: Bool, ctx: ImportContext) -> NSAttributedString {
        let para = NSMutableAttributedString()
        let markerTemplate = listMarkerPrefixTemplate(kind: .bullet, baseFont: baseFont)
        para.append(markerTemplate.attributed)
        attachMarkerAdvance(markerTemplate.markerAdvance, to: para)
        para.append(makeInlineContent(text, baseFont: baseFont, containsInlineSyntax: containsInlineSyntax, ctx: ctx))
        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernBulletMarker, value: String(marker), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListMarkerPadding, value: markerPadding, range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .bullet, baseFont: baseFont, headingLevel: nil)
        return para
    }

    private static func makeCodeBlockAttributed(
        _ code: String,
        baseFont: NSFont,
        infoString: String?,
        language: String?,
        syntaxHighlightingEnabled: Bool,
        themeSignature: String,
        profiler: ImportProfiler? = nil
    ) -> NSAttributedString {
        let normalizedInfoString = infoString ?? ""
        let normalizedLanguage = language ?? ""
        let cacheKey = CodeBlockAttributedCacheKey(
            code: code,
            infoString: normalizedInfoString,
            language: normalizedLanguage,
            fontName: baseFont.fontName,
            pointSize: baseFont.pointSize,
            syntaxHighlightingEnabled: syntaxHighlightingEnabled,
            themeSignature: NativeEditorAppearance.appearanceCacheSignature()
        )
        if let cached = sharedCodeBlockAttributedCache.value(for: cacheKey) {
            return cached
        }

        let storedCode = code.isEmpty ? String(storagePlaceholderCharacter) : code
        let para = NSMutableAttributedString(string: storedCode, attributes: baseAttributes(baseFont: baseFont))
        if code.isEmpty, para.length > 0 {
            para.addAttribute(.kernPlaceholder, value: true, range: NSRange(location: 0, length: para.length))
        }
        let codeFont = cachedCodeBlockFont(baseFont: baseFont)
        para.addAttribute(.font, value: codeFont, range: NSRange(location: 0, length: para.length))
        para.addAttribute(.kernBlockKind, value: KernBlockKind.codeBlock.rawValue, range: NSRange(location: 0, length: para.length))

        // Apply per-line paragraph styles so:
        // - the code block has a single top/bottom margin (Notion-like)
        // - internal lines don't accidentally inherit paragraphSpacingBefore/paragraphSpacing
        //   (which would create large gaps between every line).
        if para.length > 0 {
            let ns = para.string as NSString
            var idx = 0
            var firstRange: NSRange?
            var pendingRange: NSRange?

            while idx < ns.length {
                let paragraphRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
                guard paragraphRange.length > 0 else { break }

                if let pendingRange {
                    let style = (firstRange?.location == pendingRange.location)
                        ? codeBlockParagraphStyles.first
                        : codeBlockParagraphStyles.middle
                    para.addAttribute(.paragraphStyle, value: style, range: pendingRange)
                } else {
                    firstRange = paragraphRange
                }

                pendingRange = paragraphRange
                idx = paragraphRange.location + paragraphRange.length
            }

            if let pendingRange {
                let style: NSParagraphStyle
                if firstRange?.location == pendingRange.location {
                    style = codeBlockParagraphStyles.single
                } else {
                    style = codeBlockParagraphStyles.last
                }
                para.addAttribute(.paragraphStyle, value: style, range: pendingRange)
            }
        }

        if !normalizedInfoString.isEmpty, para.length > 0 {
            para.addAttribute(.kernCodeFenceInfoString, value: normalizedInfoString, range: NSRange(location: 0, length: 1))
        }

        // Language is used for chrome and best-effort syntax highlighting.
        if !normalizedLanguage.isEmpty {
            // Store on a kern.* attribute so export and UI can access it reliably.
            if para.length > 0 {
                para.addAttribute(.kernCodeLanguage, value: normalizedLanguage, range: NSRange(location: 0, length: 1))
            }

            // Back-compat: we used to stash the info string in a tooltip-like attribute.
            let toolTipInfo = (!normalizedInfoString.isEmpty ? normalizedInfoString : normalizedLanguage)
            para.addAttribute(.toolTip, value: "```\(toolTipInfo)", range: NSRange(location: 0, length: min(1, para.length)))

            if syntaxHighlightingEnabled {
                measureImportPhase(.applySyntaxHighlighting, profiler: profiler) {
                    applySyntaxHighlighting(para, language: normalizedLanguage)
                }
            }
        } else if !normalizedInfoString.isEmpty {
            para.addAttribute(.toolTip, value: "```\(normalizedInfoString)", range: NSRange(location: 0, length: min(1, para.length)))
        }

        let frozen = NSAttributedString(attributedString: para)
        sharedCodeBlockAttributedCache.insert(frozen, for: cacheKey)
        return frozen
    }

    private static func cachedCodeBlockFont(baseFont: NSFont) -> NSFont {
        let key = CodeBlockFontCacheKey(
            fontName: baseFont.fontName,
            pointSizeTimes100: Int((baseFont.pointSize * 100).rounded())
        )
        if let cached = withCacheLock({ codeBlockFontCache[key] }) {
            return cached
        }
        let created = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        return withCacheLock {
            if let cached = codeBlockFontCache[key] {
                return cached
            }
            codeBlockFontCache[key] = created
            return created
        }
    }

    private static func makeBlockMathAttributed(sourceMarkdown: String, baseFont: NSFont) -> NSAttributedString {
        let attachment = MarkdownMathBlockAttachment(sourceMarkdown: sourceMarkdown)
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        if out.length > 0 {
            let full = NSRange(location: 0, length: out.length)
            out.addAttribute(.font, value: baseFont, range: full)
            out.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: full)
            out.addAttribute(.kernAttachmentKind, value: "mathBlock", range: full)
        }
        applyBlockAttributes(out, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
        return out
    }

    private static func makeMermaidAttachmentAttributed(
        sourceMarkdown: String,
        baseFont: NSFont,
        renderMode: Options.MermaidRenderMode
    ) -> NSAttributedString {
        let attachment = MarkdownMermaidAttachment(sourceMarkdown: sourceMarkdown, requestedRenderMode: renderMode)
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        if out.length > 0 {
            let full = NSRange(location: 0, length: out.length)
            out.addAttribute(.font, value: baseFont, range: full)
            out.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: full)
            out.addAttribute(.kernAttachmentKind, value: "mermaid", range: full)
        }
        applyBlockAttributes(out, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
        return out
    }

    private static func makeImageAttachmentAttributed(alt: String, destination: String, sourceMarkdown: String, baseFont: NSFont, ctx: ImportContext) -> NSAttributedString {
        let attachment = MarkdownImageAttachment(
            altText: alt,
            destination: destination,
            sourceMarkdown: sourceMarkdown,
            baseURL: ctx.baseURL,
            allowsRemoteLoading: ctx.options.remoteImageLoadingEnabled
        )
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        if out.length > 0 {
            let full = NSRange(location: 0, length: out.length)
            out.addAttribute(.font, value: baseFont, range: full)
            out.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: full)
            out.addAttribute(.kernAttachmentKind, value: "image", range: full)
            if let resolvedURL = attachment.resolvedURL,
               !(!ctx.options.remoteImageLoadingEnabled && isRemoteHTTPURL(resolvedURL))
            {
                out.addAttribute(.link, value: resolvedURL, range: full)
            } else if let absoluteURL = URL(string: destination),
                      let scheme = absoluteURL.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"),
                      ctx.options.remoteImageLoadingEnabled {
                out.addAttribute(.link, value: absoluteURL, range: full)
            }
        }
        return out
    }

    private static func isRemoteHTTPURL(_ url: URL) -> Bool {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func makeInlineMathAttributed(expression: String, sourceMarkdown: String, baseFont: NSFont) -> NSAttributedString {
        let rendered = MathTextRenderer.renderInlineMath(expression)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .medium),
            .foregroundColor: NSColor.systemOrange,
            .kernSourceMarkdown: sourceMarkdown,
            .kernInlineMath: true,
        ]
        return NSAttributedString(string: rendered, attributes: attrs)
    }

    static func applyDeferredSyntaxHighlightingToCodeBlock(
        _ attributed: NSMutableAttributedString,
        language: String
    ) {
        applySyntaxHighlighting(attributed, language: language)
    }

    private static func applySyntaxHighlighting(_ attributed: NSMutableAttributedString, language: String) {
        guard attributed.length > 0 else { return }
        let token = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        let lang = normalizeCodeLanguage(token.lowercased())
        guard !lang.isEmpty else { return }

        let ns = attributed.string as NSString
        let syntax = NativeEditorAppearance.syntaxPalette()
        let keywordColor = syntax.keyword
        let builtinColor = syntax.builtin
        let stringColor = syntax.string
        let numberColor = syntax.number
        let commentColor = syntax.comment
        let variableColor = syntax.variable

        func apply(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            let cacheKey = pattern + "\0" + String(options.rawValue)
            guard let re = cachedSyntaxHighlightingRegex(
                cacheKey: cacheKey,
                pattern: pattern,
                options: options
            ) else {
                return
            }
            let full = NSRange(location: 0, length: ns.length)
            re.enumerateMatches(in: attributed.string, options: [], range: full) { m, _, _ in
                guard let m else { return }
                guard m.range.location != NSNotFound, m.range.length > 0 else { return }
                guard m.range.location + m.range.length <= attributed.length else { return }
                attributed.addAttribute(.foregroundColor, value: color, range: m.range)
            }
        }

        func applyStrings(includeBackticks: Bool = false) {
            apply(#"\"(?:\\.|[^\"\\])*\""#, color: stringColor)
            apply(#"'(?:\\.|[^'\\])*'"#, color: stringColor)
            if includeBackticks {
                apply(#"`(?:\\.|[^`\\])*`"#, color: stringColor)
            }
        }

        func applyNumbers() {
            apply(#"\b\d+(?:\.\d+)?\b"#, color: numberColor)
        }

        switch lang {
        case "javascript", "typescript":
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            applyStrings(includeBackticks: true)
            applyNumbers()
            apply(#"\b(async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|interface|let|new|return|super|switch|this|throw|try|type|typeof|var|void|while|with|yield)\b"#, color: keywordColor)
            apply(#"\b(console|Math|Number|String|Boolean|Array|Object|Promise|Date|JSON|Map|Set)\b"#, color: builtinColor)

        case "python":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"(?s)\"\"\".*?\"\"\""#, color: stringColor)
            apply(#"(?s)'''.*?'''"#, color: stringColor)
            applyStrings()
            applyNumbers()
            apply(#"\b(and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|match|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield)\b"#, color: keywordColor)
            apply(#"\b(print|len|range|list|dict|set|tuple|int|float|str|bool|bytes|enumerate|zip)\b"#, color: builtinColor)

        case "bash":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            apply(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, color: variableColor)
            apply(#"\b(for|in|do|done|if|then|elif|else|fi|case|esac|while|until|function|select|time|coproc)\b"#, color: keywordColor)
            apply(#"\b(echo|cd|ls|cat|grep|rg|sed|awk|find|open|pwd|mkdir|rm|cp|mv|export|set)\b"#, color: builtinColor)

        case "swift":
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            applyStrings()
            applyNumbers()
            apply(#"\b(import|func|let|var|if|else|for|while|return|class|struct|enum|protocol|extension|guard|switch|case|default|break|continue|throw|try|catch|public|private|internal|fileprivate|open|static|async|await)\b"#, color: keywordColor)
            apply(#"\b(String|Int|Double|Bool|Array|Dictionary|Set|Result|Error)\b"#, color: builtinColor)

        case "go", "rust", "c", "cpp", "java", "kotlin", "dart", "scala", "zig", "php":
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            if lang == "php" {
                apply(#"<\?php"#, color: keywordColor)
            }
            applyStrings()
            applyNumbers()
            apply(#"\b(break|case|catch|class|const|continue|default|do|else|enum|extends|for|func|fn|function|if|impl|import|in|interface|let|match|module|new|package|private|protected|public|return|static|struct|switch|throw|trait|try|type|var|void|while)\b"#, color: keywordColor)
            apply(#"\b(String|Vec|Option|Result|Map|HashMap|List|Array|println|printf|fmt|std)\b"#, color: builtinColor)

        case "ruby":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(alias|begin|break|case|class|def|do|else|elsif|end|ensure|for|if|in|module|next|redo|rescue|retry|return|self|super|then|unless|until|when|while|yield)\b"#, color: keywordColor)
            apply(#"\b(puts|print|require|include|extend|attr_reader|attr_accessor)\b"#, color: builtinColor)

        case "sql":
            apply(#"--.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            apply(#"'(?:''|[^'])*'"#, color: stringColor)
            applyNumbers()
            apply(#"\b(SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|WITH|INSERT|INTO|VALUES|UPDATE|DELETE|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|CASE|WHEN|THEN|ELSE|END)\b"#, color: keywordColor, options: [.caseInsensitive])
            apply(#"\b(COUNT|SUM|AVG|MIN|MAX|DATE_TRUNC|COALESCE|ROW_NUMBER)\b"#, color: builtinColor, options: [.caseInsensitive])

        case "html", "xml":
            apply(#"<!--.*?-->"#, color: commentColor, options: [.dotMatchesLineSeparators])
            apply(#"</?[A-Za-z_:][A-Za-z0-9:._-]*"#, color: keywordColor)
            apply(#"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\=)"#, color: builtinColor)
            applyStrings()

        case "css", "scss":
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"@[A-Za-z_-]+"#, color: keywordColor)
            apply(#"(?<![A-Za-z0-9_-])[A-Za-z-]+(?=\s*:)"#, color: builtinColor)
            apply(#"\$[A-Za-z_][A-Za-z0-9_-]*"#, color: variableColor)
            apply(#"#[0-9A-Fa-f]{3,8}\b"#, color: numberColor)
            apply(#"\b(?:rgb|rgba|hsl|hsla|url|var|calc|clamp|min|max)\b(?=\()"#, color: keywordColor)
            applyStrings()
            applyNumbers()

        case "json":
            apply(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: builtinColor)
            apply(#"\"(?:\\.|[^\"\\])*\""#, color: stringColor)
            applyNumbers()
            apply(#"\b(true|false|null)\b"#, color: keywordColor)

        case "yaml":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"(?m)^\s*[-?]?\s*[A-Za-z0-9_.-]+\s*:"#, color: builtinColor)
            applyStrings()
            applyNumbers()
            apply(#"\b(true|false|null|yes|no|on|off)\b"#, color: keywordColor, options: [.caseInsensitive])

        case "toml":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"(?m)^\s*\[[^\]]+\]"#, color: keywordColor)
            apply(#"(?m)^\s*[A-Za-z0-9_.-]+\s*="#, color: builtinColor)
            applyStrings()
            applyNumbers()
            apply(#"\b(true|false)\b"#, color: keywordColor)

        case "powershell":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\$[A-Za-z_][A-Za-z0-9_]*"#, color: variableColor)
            apply(#"\b(function|param|if|elseif|else|foreach|for|while|switch|try|catch|throw|return|begin|process|end)\b"#, color: keywordColor, options: [.caseInsensitive])
            apply(#"\b(Write-Host|Write-Output|Get-Item|Set-Item|Select-Object|Where-Object)\b"#, color: builtinColor, options: [.caseInsensitive])

        case "lua":
            apply(#"--.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(and|break|do|else|elseif|end|for|function|if|in|local|nil|not|or|repeat|return|then|until|while)\b"#, color: keywordColor)

        case "haskell":
            apply(#"--.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"\{-.*?-\}"#, color: commentColor, options: [.dotMatchesLineSeparators])
            applyStrings()
            applyNumbers()
            apply(#"\b(data|type|newtype|class|instance|where|let|in|if|then|else|case|of|module|import|deriving|do)\b"#, color: keywordColor)

        case "elixir":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(def|defp|defmodule|defprotocol|defimpl|defstruct|do|end|fn|if|else|case|when|with|receive|after|try|catch|rescue)\b"#, color: keywordColor)

        case "clojure":
            apply(#";.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(def|defn|let|if|when|cond|fn|loop|recur|ns|require|use|doseq|map|filter|reduce)\b"#, color: keywordColor)

        case "ocaml":
            apply(#"\(\*.*?\*\)"#, color: commentColor, options: [.dotMatchesLineSeparators])
            applyStrings()
            applyNumbers()
            apply(#"\b(let|rec|in|match|with|type|module|functor|sig|struct|open|include|if|then|else|begin|end)\b"#, color: keywordColor)

        case "perl":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(sub|my|our|local|if|elsif|else|while|for|foreach|package|use|require|return)\b"#, color: keywordColor)
            apply(#"[$@%][A-Za-z_][A-Za-z0-9_]*"#, color: variableColor)

        case "r":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(function|if|else|for|while|repeat|in|next|break|TRUE|FALSE|NULL|NA)\b"#, color: keywordColor)
            apply(#"\b(library|require|data.frame|tibble|ggplot|mutate|summarise|filter)\b"#, color: builtinColor)

        case "graphql":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            apply(#"\b(type|interface|union|input|enum|scalar|query|mutation|subscription|fragment|on|schema)\b"#, color: keywordColor)

        case "protobuf":
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            applyNumbers()
            apply(#"\b(syntax|package|import|option|message|enum|service|rpc|returns|repeated|optional|oneof|map|reserved)\b"#, color: keywordColor)

        case "dockerfile":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            applyStrings()
            apply(#"(?m)^\s*(FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#, color: keywordColor, options: [.caseInsensitive])
            apply(#"\$[A-Za-z_][A-Za-z0-9_]*"#, color: variableColor)

        case "makefile":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"\$\([^)]+\)|\$\{[^}]+\}"#, color: variableColor)
            apply(#"(?m)^\s*(include|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|override|export|unexport)\b"#, color: keywordColor)
            apply(#"(?m)^[A-Za-z0-9_.-]+(?=\s*:)"#, color: builtinColor)

        case "terraform":
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            applyStrings()
            applyNumbers()
            apply(#"\b(terraform|required_providers|provider|resource|data|module|variable|output|locals)\b"#, color: keywordColor)
            apply(#"\b(true|false|null)\b"#, color: builtinColor)

        default:
            // Fallback keeps unknown languages readable with lightweight tokenization.
            apply(#"#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"//.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"/\*.*?\*/"#, color: commentColor, options: [.dotMatchesLineSeparators])
            applyStrings(includeBackticks: true)
            applyNumbers()
        }
    }

    private static func normalizeCodeLanguage(_ language: String) -> String {
        switch language {
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "py":
            return "python"
        case "sh", "shell", "zsh":
            return "bash"
        case "rb":
            return "ruby"
        case "ps1":
            return "powershell"
        case "yml":
            return "yaml"
        case "htm":
            return "html"
        case "c++", "hpp", "cc", "cxx":
            return "cpp"
        case "proto":
            return "protobuf"
        case "tf", "hcl":
            return "terraform"
        default:
            return language
        }
    }

    private static func makeThematicBreakAttributed(baseFont: NSFont, marker: String) -> NSAttributedString {
        let attachment = ThematicBreakAttachment()
        let para = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        if para.length > 0 {
            let full = NSRange(location: 0, length: para.length)
            para.addAttribute(.font, value: baseFont, range: full)
            para.addAttribute(.kernThematicBreakMarker, value: marker, range: full)
        }
        applyBlockAttributes(para, kind: .thematicBreak, baseFont: baseFont, headingLevel: nil)
        return para
    }

    private static func makeOrderedParagraph(_ ordered: (index: Int, markerPadding: String, text: String), indent: Int, depth: Int, baseFont: NSFont, containsInlineSyntax: Bool, ctx: ImportContext) -> NSAttributedString {
        let para = NSMutableAttributedString()
        let marker = orderedDisplayMarker(index: max(0, ordered.index), depth: depth)
        let markerTemplate = listMarkerPrefixTemplate(kind: .ordered(marker: marker, depth: depth), baseFont: baseFont)
        para.append(markerTemplate.attributed)
        attachMarkerAdvance(markerTemplate.markerAdvance, to: para)
        let content = makeInlineContent(ordered.text, baseFont: baseFont, containsInlineSyntax: containsInlineSyntax, ctx: ctx)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListMarkerPadding, value: ordered.markerPadding, range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .ordered, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernOrderedIndex, value: max(0, ordered.index), range: NSRange(location: 0, length: min(markerTemplate.markerLength, para.length)))

        return para
    }

    private static func orderedDisplayMarker(index: Int, depth: Int) -> String {
        // Full-spec: depth-aware ordered list markers for readability (Notion-like):
        // 0 -> 0., 1 -> a., 2 -> i., 3 -> 1., ...
        let style = max(0, depth) % 3
        switch style {
        case 1:
            return "\(alphabeticMarker(index)). "
        case 2:
            return "\(romanNumeral(index)). "
        default:
            return "\(max(0, index)). "
        }
    }

    private static func orderedMarkerFont(baseFont: NSFont, depth: Int) -> NSFont {
        // Decimal list markers should use tabular digits so checkbox/text columns do not shift
        // between "1." and "2." rows (or any same-digit-width rows).
        let style = max(0, depth) % 3
        if style == 0 {
            return NSFont.monospacedDigitSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        }
        return baseFont
    }

    private static func alphabeticMarker(_ index: Int) -> String {
        // 1 -> a, 26 -> z, 27 -> aa
        var n = max(1, index)
        var chars: [Character] = []
        while n > 0 {
            n -= 1
            let c = Character(UnicodeScalar(97 + (n % 26))!)
            chars.append(c)
            n /= 26
        }
        return String(chars.reversed())
    }

    private static func romanNumeral(_ index: Int) -> String {
        // Minimal roman numerals (lowercase). Falls back to decimal for very large values.
        let n = max(1, index)
        if n > 3999 { return "\(n)" }
        let map: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var out = ""
        var value = n
        for (v, s) in map {
            while value >= v {
                out += s
                value -= v
            }
        }
        return out
    }

    private static func makeOrderedTaskParagraph(
        _ orderedTask: (index: Int, checked: Bool, text: String),
        indent: Int,
        depth: Int,
        baseFont: NSFont,
        containsInlineSyntax: Bool,
        ctx: ImportContext
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()

        var markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )
        markerAttrs[.font] = orderedMarkerFont(baseFont: baseFont, depth: depth)

        let marker = orderedDisplayMarker(index: max(0, orderedTask.index), depth: depth)
        para.append(NSAttributedString(string: marker, attributes: markerAttrs))

        let checkboxFont = CheckboxStyle.preferredFont(pointSize: baseFont.pointSize + 4)
        let checkboxChar = orderedTask.checked ? "\u{2611}" : "\u{2610}"
        var checkboxAttrs = markerAttrs
        checkboxAttrs[.font] = checkboxFont
        checkboxAttrs[.foregroundColor] = NSColor.clear
        checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: baseFont, checkboxFont: checkboxFont)
        checkboxAttrs[.kernCheckbox] = true
        checkboxAttrs[.kernCheckboxChecked] = orderedTask.checked
        para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
        para.append(NSAttributedString(string: " ", attributes: markerAttrs))
        let markerLength = para.length
        attachMarkerAdvance(measuredMarkerAdvance(in: para, markerLength: markerLength), to: para)

        let content = makeInlineContent(orderedTask.text, baseFont: baseFont, containsInlineSyntax: containsInlineSyntax, ctx: ctx)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .ordered, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernOrderedIndex, value: max(0, orderedTask.index), range: NSRange(location: 0, length: min(marker.count, para.length)))
        para.addAttribute(.kernOrderedIsTask, value: true, range: NSRange(location: 0, length: min(1, para.length)))

        if orderedTask.checked {
            let range = NSRange(location: markerLength, length: max(0, para.length - markerLength))
            if range.length > 0 {
                para.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        return para
    }

    private static func headingFont(level: Int) -> NSFont {
        NativeEditorAppearance.headingFont(level: level)
    }

    private static func applyBlockAttributes(_ paragraph: NSMutableAttributedString, kind: KernBlockKind, baseFont: NSFont, headingLevel: Int?) {
        guard paragraph.length > 0 else { return }
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.kernBlockKind, value: kind.rawValue, range: full)

        switch kind {
        case .heading:
            let level = headingLevel ?? 1
            paragraph.addAttribute(.kernHeadingLevel, value: level, range: full)
            paragraph.addAttribute(.paragraphStyle, value: headingParagraphStyle(level: level), range: full)

        case .codeBlock:
            break
        case .tableCell:
            // Table cells already have a paragraph style with NSTextTableBlock + alignment.
            // Avoid overriding it; only normalize spacing.
            let style = ((paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            style.lineHeightMultiple = 1.0
            paragraph.addAttribute(.paragraphStyle, value: style, range: full)

        case .thematicBreak:
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 10
            paragraph.addAttribute(.paragraphStyle, value: style, range: full)

        case .bullet, .task, .ordered, .paragraph:
            let listDepth = (paragraph.attribute(.kernListDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
            let markerAdvance = (paragraph.attribute(.kernMarkerAdvance, at: 0, effectiveRange: nil) as? NSNumber).map {
                CGFloat(truncating: $0)
            }
            paragraph.addAttribute(
                .paragraphStyle,
                value: listParagraphStyle(listDepth: listDepth, markerAdvance: markerAdvance),
                range: full
            )
        }
    }

    private static func applyQuoteAttributes(_ paragraph: NSMutableAttributedString, quoteDepth: Int) {
        guard quoteDepth > 0, paragraph.length > 0 else { return }
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.kernQuoteDepth, value: quoteDepth, range: full)

        let quoteIndent: CGFloat = CGFloat(quoteDepth) * 16
        // Preserve per-paragraph styles (important for multi-paragraph blocks like code blocks).
        let ns = paragraph.string as NSString
        var idx = 0
        while idx < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            guard r.length > 0 else { break }

            let existing = paragraph.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += quoteIndent
            style.headIndent += quoteIndent
            paragraph.addAttribute(.paragraphStyle, value: style, range: r)

            idx = r.location + r.length
        }
    }

    private static func markerPrefixLength(in paragraph: NSAttributedString) -> Int {
        var len = 0
        while len < paragraph.length {
            let isMarker = (paragraph.attribute(.kernMarker, at: len, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            len += 1
        }
        return len
    }

    private static func baseAttributes(baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NativeEditorAppearance.primaryTextColor(),
        ]
    }

    // MARK: - Inline parsing / rendering

    private enum InlineLinkValue: Equatable, Hashable {
        case url(URL)
        case raw(String)

        var attributeValue: Any {
            switch self {
            case .url(let url):
                return url
            case .raw(let string):
                return string
            }
        }
    }

    private struct InlineStyle: Equatable, Hashable {
        var strong: Bool = false
        var emphasis: Bool = false
        var strike: Bool = false
        var code: Bool = false
        var link: InlineLinkValue? = nil
        var linkDestination: String? = nil
        var autolink: Bool = false
        var linkTitle: String? = nil
        var linkReferenceID: String? = nil
        var linkReferenceURL: String? = nil
    }

    private struct InlineParseCacheKey: Hashable {
        let text: String
        let style: InlineStyle
        let fontName: String
        let pointSize: CGFloat
        let themeSignature: String
        let baseURLSignature: String
        let referenceDefinitionsSignature: Int
        let remoteImageLoadingEnabled: Bool
    }

    private struct CodeBlockAttributedCacheKey: Hashable {
        let code: String
        let infoString: String
        let language: String
        let fontName: String
        let pointSize: CGFloat
        let syntaxHighlightingEnabled: Bool
        let themeSignature: String
    }

    private struct TableAttributedCacheKey: Hashable {
        let rows: [[String]]
        let alignments: [TableColumnAlignment]
        let fontName: String
        let pointSize: CGFloat
        let terminateLastParagraph: Bool
        let themeSignature: String
        let baseURLSignature: String
        let referenceDefinitionsSignature: Int
        let remoteImageLoadingEnabled: Bool
    }

    private struct ParagraphContinuationBoundaryCacheKey: Hashable {
        let lineIndex: Int
        let quoteDepth: Int
    }

    private static func containsInlineSyntax(in text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 33, 36, 42, 60, 91, 92, 95, 96, 126: // ! $ * < [ \ _ ` ~
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func cachedSyntaxHighlightingRegex(
        cacheKey: String,
        pattern: String,
        options: NSRegularExpression.Options
    ) -> NSRegularExpression? {
        if let cached = withCacheLock({ syntaxHighlightingRegexCache[cacheKey] }) {
            return cached
        }

        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        return withCacheLock {
            if let cached = syntaxHighlightingRegexCache[cacheKey] {
                return cached
            }
            syntaxHighlightingRegexCache[cacheKey] = compiled
            return compiled
        }
    }

    private static func cachedMarkerWidth(for cacheKey: String) -> CGFloat? {
        withCacheLock { markerWidthCache[cacheKey] }
    }

    private static func setCachedMarkerWidth(_ width: CGFloat, for cacheKey: String) {
        withCacheLock { markerWidthCache[cacheKey] = width }
    }

    private static func cachedListParagraphStyle(for cacheKey: ListParagraphStyleCacheKey) -> NSParagraphStyle? {
        withCacheLock { listParagraphStyleCache[cacheKey] }
    }

    private static func setCachedListParagraphStyle(_ style: NSParagraphStyle, for cacheKey: ListParagraphStyleCacheKey) {
        withCacheLock { listParagraphStyleCache[cacheKey] = style }
    }

    private static func cachedHeadingParagraphStyle(for cacheKey: HeadingParagraphStyleCacheKey) -> NSParagraphStyle? {
        withCacheLock { headingParagraphStyleCache[cacheKey] }
    }

    private static func setCachedHeadingParagraphStyle(_ style: NSParagraphStyle, for cacheKey: HeadingParagraphStyleCacheKey) {
        withCacheLock { headingParagraphStyleCache[cacheKey] = style }
    }

    private static func cachedListMarkerPrefix(for cacheKey: ListMarkerPrefixCacheKey) -> ListMarkerPrefixTemplate? {
        withCacheLock { listMarkerPrefixCache[cacheKey] }
    }

    private static func setCachedListMarkerPrefix(_ template: ListMarkerPrefixTemplate, for cacheKey: ListMarkerPrefixCacheKey) {
        withCacheLock { listMarkerPrefixCache[cacheKey] = template }
    }

    private static func listMarkerPrefixTemplate(
        kind: ListMarkerPrefixKind,
        baseFont: NSFont
    ) -> ListMarkerPrefixTemplate {
        let cacheKey = ListMarkerPrefixCacheKey(
            kind: kind,
            fontName: baseFont.fontName,
            pointSizeTimes100: Int((baseFont.pointSize * 100).rounded()),
            themeSignature: NativeEditorAppearance.appearanceCacheSignature()
        )
        if let cached = cachedListMarkerPrefix(for: cacheKey) {
            return cached
        }

        let para = NSMutableAttributedString()
        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )

        switch kind {
        case .bullet:
            para.append(NSAttributedString(string: "• ", attributes: markerAttrs))

        case let .taskStandalone(checked):
            let checkboxFont = CheckboxStyle.preferredFont(pointSize: baseFont.pointSize + 4)
            let checkboxChar = checked ? "\u{2611}" : "\u{2610}"
            var checkboxAttrs = markerAttrs
            checkboxAttrs[.font] = checkboxFont
            checkboxAttrs[.foregroundColor] = NSColor.clear
            checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: baseFont, checkboxFont: checkboxFont)
            checkboxAttrs[.kernCheckbox] = true
            checkboxAttrs[.kernCheckboxChecked] = checked
            para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
            para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        case let .taskBulleted(checked):
            para.append(NSAttributedString(string: "• ", attributes: markerAttrs))
            let checkboxFont = CheckboxStyle.preferredFont(pointSize: baseFont.pointSize + 4)
            let checkboxChar = checked ? "\u{2611}" : "\u{2610}"
            var checkboxAttrs = markerAttrs
            checkboxAttrs[.font] = checkboxFont
            checkboxAttrs[.foregroundColor] = NSColor.clear
            checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: baseFont, checkboxFont: checkboxFont)
            checkboxAttrs[.kernCheckbox] = true
            checkboxAttrs[.kernCheckboxChecked] = checked
            para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
            para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        case let .ordered(marker, depth):
            var orderedMarkerAttrs = markerAttrs
            orderedMarkerAttrs[.font] = orderedMarkerFont(baseFont: baseFont, depth: depth)
            para.append(NSAttributedString(string: marker, attributes: orderedMarkerAttrs))
        }

        let template = ListMarkerPrefixTemplate(
            attributed: para.copy() as! NSAttributedString,
            markerLength: para.length,
            markerAdvance: measuredMarkerAdvance(in: para, markerLength: para.length)
        )
        setCachedListMarkerPrefix(template, for: cacheKey)
        return template
    }

    private static func measuredMarkerAdvance(in paragraph: NSAttributedString, markerLength: Int) -> CGFloat {
        let clampedLength = min(markerLength, paragraph.length)
        guard clampedLength > 0 else { return 0 }
        let markerAttr = paragraph.attributedSubstring(from: NSRange(location: 0, length: clampedLength))
        let markerText = markerAttr.string
        let markerFont = (markerAttr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 16)
        let cacheKey = markerText + "\0" + markerFont.fontName + "\0" + String(Double(markerFont.pointSize))
        if let cached = cachedMarkerWidth(for: cacheKey) {
            return cached
        }

        let rect = markerAttr.boundingRect(
            with: NSSize(width: 1000, height: 1000),
            options: [.usesFontLeading, .usesLineFragmentOrigin]
        )
        let markerWidth = ceil(rect.width)
        setCachedMarkerWidth(markerWidth, for: cacheKey)
        return markerWidth
    }

    private static func attachMarkerAdvance(_ markerAdvance: CGFloat, to paragraph: NSMutableAttributedString) {
        guard paragraph.length > 0, markerAdvance > 0 else { return }
        paragraph.addAttribute(.kernMarkerAdvance, value: NSNumber(value: Double(markerAdvance)), range: NSRange(location: 0, length: 1))
    }

    private static func listParagraphStyle(listDepth: Int, markerAdvance: CGFloat?) -> NSParagraphStyle {
        let resolvedMarkerAdvance = max(0, markerAdvance ?? 0)
        let cacheKey = ListParagraphStyleCacheKey(
            listDepth: max(0, listDepth),
            markerAdvanceTimes100: Int((resolvedMarkerAdvance * 100).rounded())
        )
        if let cached = cachedListParagraphStyle(for: cacheKey) {
            return cached
        }

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = 5
        style.lineHeightMultiple = 1.12

        let baseIndent = CGFloat(max(0, listDepth)) * 24
        style.firstLineHeadIndent = baseIndent
        style.headIndent = baseIndent
        if resolvedMarkerAdvance > 0 {
            style.headIndent = baseIndent + max(24, resolvedMarkerAdvance + 8)
        }

        let frozen = style.copy() as! NSParagraphStyle
        setCachedListParagraphStyle(frozen, for: cacheKey)
        return frozen
    }

    private static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let cacheKey = HeadingParagraphStyleCacheKey(level: max(1, min(6, level)))
        if let cached = cachedHeadingParagraphStyle(for: cacheKey) {
            return cached
        }

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = cacheKey.level == 1 ? 14 : 10
        style.paragraphSpacing = 6
        style.lineHeightMultiple = 1.12

        let frozen = style.copy() as! NSParagraphStyle
        setCachedHeadingParagraphStyle(frozen, for: cacheKey)
        return frozen
    }

    private static func cachedInlineFont(baseFont: NSFont, style: InlineStyle) -> NSFont {
        let key = InlineFontCacheKey(
            fontName: baseFont.fontName,
            pointSize: baseFont.pointSize,
            code: style.code,
            strong: style.strong,
            emphasis: style.emphasis
        )

        if let cached = withCacheLock({ inlineFontCache[key] }) {
            return cached
        }

        var font = baseFont
        if style.code {
            font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        } else {
            if style.strong {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if style.emphasis {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
        }

        return withCacheLock {
            if let cached = inlineFontCache[key] {
                return cached
            }
            inlineFontCache[key] = font
            return font
        }
    }

    private static func cachedInlineAttributesWithoutLink(
        baseFont: NSFont,
        style: InlineStyle,
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let key = InlineAttributeCacheKey(
            fontName: baseFont.fontName,
            pointSizeTimes100: Int((baseFont.pointSize * 100).rounded()),
            code: style.code,
            strong: style.strong,
            emphasis: style.emphasis,
            strike: style.strike,
            themeSignature: NativeEditorAppearance.appearanceCacheSignature()
        )

        if let cached = withCacheLock({ inlineAttributeCache[key] }) {
            return cached
        }

        var attrs: [NSAttributedString.Key: Any] = baseAttributes(baseFont: baseFont)
        if style.code {
            attrs[.kernInlineCode] = true
            attrs[.foregroundColor] = NativeEditorAppearance.inlineCodeTextColor()
        } else {
            if style.strong {
                attrs[.kernStrong] = true
            }
            if style.emphasis {
                attrs[.kernEmphasis] = true
            }
            if style.strike {
                attrs[.kernStrikethrough] = true
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        attrs[.font] = font

        return withCacheLock {
            if let cached = inlineAttributeCache[key] {
                return cached
            }
            inlineAttributeCache[key] = attrs
            return attrs
        }
    }

    /// Internal entry point for micro-benchmarking via `@testable import`.
    static func parseInline(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let ctx = ImportContext(
            referenceDefinitions: [:],
            referenceDefinitionsSignature: 0,
            baseURL: nil,
            baseURLSignature: "",
            options: .fromUserDefaults(),
            strictConformanceRoundTripMode: false,
            syntaxHighlightingEnabled: true,
            inlineParseCache: nil,
            themeSignature: NativeEditorAppearance.appearanceCacheSignature(),
            profiler: nil
        )
        return parseInline(text, baseFont: baseFont, style: InlineStyle(), ctx: ctx)
    }

    private static func parseInline(_ text: String, baseFont: NSFont, ctx: ImportContext) -> NSAttributedString {
        parseInline(text, baseFont: baseFont, style: InlineStyle(), ctx: ctx)
    }

    private static func makeInlineContent(_ text: String, baseFont: NSFont, containsInlineSyntax: Bool, ctx: ImportContext) -> NSAttributedString {
        if !ctx.strictConformanceRoundTripMode, !containsInlineSyntax {
            return makeInlineAttributed(text, baseFont: baseFont, style: InlineStyle())
        }
        return parseInline(text, baseFont: baseFont, ctx: ctx)
    }

    private static func parseAutolinkURL<S: StringProtocol>(_ inner: S) -> URL? {
        // CommonMark autolinks disallow whitespace.
        if inner.contains(where: { $0.isWhitespace }) { return nil }

        let innerString = String(inner)

        if innerString.hasPrefix("http://") || innerString.hasPrefix("https://") {
            return URL(string: innerString)
        }

        // Email autolink: <me@example.com>
        if innerString.contains("@"), !innerString.contains(":") {
            return URL(string: "mailto:\(innerString)")
        }

        return nil
    }

    private struct InlineParseResult {
        let attributed: NSAttributedString
        let nextIndex: Int
    }

    private struct BracketContent {
        let contentRange: Range<Int>
        let closeIndex: Int
        let nextIndex: Int
    }

    private struct InlineLinkTarget {
        let destinationRange: Range<Int>
        let titleRange: Range<Int>?
        let nextIndex: Int
    }

    private static func parseInline(_ text: String, baseFont: NSFont, style: InlineStyle, ctx: ImportContext) -> NSAttributedString {
        if let profiler = ctx.profiler {
            return profiler.measureInlineParse(utf16Count: text.utf16.count) {
                parseInlineMeasured(text, baseFont: baseFont, style: style, ctx: ctx)
            }
        }
        return parseInlineMeasured(text, baseFont: baseFont, style: style, ctx: ctx)
    }

    private static func inlineCacheBaseURLSignature(_ baseURL: URL?) -> String {
        guard let baseURL else { return "" }
        if baseURL.isFileURL {
            return baseURL.standardizedFileURL.absoluteString
        }
        return baseURL.absoluteString
    }

    private static func inlineCacheReferenceDefinitionsSignature(
        _ referenceDefinitions: [String: ReferenceDefinition]
    ) -> Int {
        guard !referenceDefinitions.isEmpty else { return 0 }
        var hasher = Hasher()
        for key in referenceDefinitions.keys.sorted() {
            hasher.combine(key)
            if let definition = referenceDefinitions[key] {
                hasher.combine(definition.id)
                hasher.combine(definition.destination)
                hasher.combine(definition.title)
            }
        }
        return hasher.finalize()
    }

    private static func parseInlineMeasured(_ text: String, baseFont: NSFont, style: InlineStyle, ctx: ImportContext) -> NSAttributedString {
        if ctx.strictConformanceRoundTripMode {
            let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(text, baseFont: baseFont, style: style))
            if attr.length > 0 {
                attr.addAttribute(.kernSourceMarkdown, value: text, range: NSRange(location: 0, length: attr.length))
            }
            return attr
        }

        // Fast path for lines with no inline syntax delimiters.
        // This avoids materializing `[Character]` for the common plain-text case.
        if !containsInlineSyntax(in: text) {
            return makeInlineAttributed(text, baseFont: baseFont, style: style)
        }

        let cacheEligible = text.utf16.count <= inlineParseCacheMaxUTF16(for: style)
        let inlineCache = cacheEligible ? ctx.inlineParseCache : nil
        var cacheKey: InlineParseCacheKey?
        if let inlineCache {
            let key = InlineParseCacheKey(
                text: text,
                style: style,
                fontName: baseFont.fontName,
                pointSize: baseFont.pointSize,
                themeSignature: ctx.themeSignature,
                baseURLSignature: ctx.baseURLSignature,
                referenceDefinitionsSignature: ctx.referenceDefinitionsSignature,
                remoteImageLoadingEnabled: ctx.options.remoteImageLoadingEnabled
            )
            if let cached = inlineCache.value(for: key) {
                return cached
            }
            cacheKey = key
        }

        if let rangeFirst = parseInlineRangeFirstPhase1(text, baseFont: baseFont, style: style, ctx: ctx) {
            if let inlineCache, let cacheKey {
                inlineCache.insert(rangeFirst, for: cacheKey)
                return rangeFirst
            }
            return rangeFirst
        }

        let chars = Array(text)
        let out = parseInlineCharacters(chars, range: 0..<chars.count, baseFont: baseFont, style: style, ctx: ctx)
        if let inlineCache, let cacheKey {
            // The parser never mutates returned attributed strings after construction.
            // Reusing the same instance avoids an extra defensive copy on hot paths.
            inlineCache.insert(out, for: cacheKey)
            return out
        }
        return out
    }

    private struct RangeCodeSpanMatch {
        let innerRange: Range<String.Index>
        let sourceRange: Range<String.Index>
        let fenceLength: Int
        let nextIndex: String.Index
    }

    private struct RangeBracketContent {
        let contentRange: Range<String.Index>
        let closeIndex: String.Index
        let nextIndex: String.Index
    }

    private struct RangeInlineLinkTarget {
        let destinationRange: Range<String.Index>
        let titleRange: Range<String.Index>?
        let nextIndex: String.Index
    }

    private struct RangeInlineParseResult {
        let attributed: NSAttributedString
        let nextIndex: String.Index
    }

    private static func parseInlineRangeFirstPhase1(
        _ text: String,
        baseFont: NSFont,
        style: InlineStyle,
        ctx: ImportContext
    ) -> NSAttributedString? {
        var index = text.startIndex
        var literalStart = index
        let out = NSMutableAttributedString()
        out.beginEditing()
        defer { out.endEditing() }

        func flushLiteral(upTo end: String.Index) {
            guard literalStart < end else {
                literalStart = end
                return
            }
            out.append(
                makeInlineAttributed(
                    String(text[literalStart..<end]),
                    baseFont: baseFont,
                    style: style
                )
            )
            literalStart = end
        }

        func appendEscapedLiteral(_ character: Character) {
            let attr = NSMutableAttributedString(
                attributedString: makeInlineAttributed(
                    String(character),
                    baseFont: baseFont,
                    style: style
                )
            )
            if attr.length > 0 {
                attr.addAttribute(.kernEscapedLiteral, value: true, range: NSRange(location: 0, length: attr.length))
            }
            out.append(attr)
        }

        func appendHtmlLineBreak(sourceMarkdown: String) {
            out.append(makeHtmlLineBreakAttributed(sourceMarkdown: sourceMarkdown, baseFont: baseFont, style: style))
        }

        while index < text.endIndex {
            let ch = text[index]

            if ch != "\\" && ch != "<" && ch != "`" && ch != "[" {
                if ch == "!" || ch == "$" || ch == "*" || ch == "_" || ch == "~" {
                    return nil
                }
                index = text.index(after: index)
                continue
            }

            flushLiteral(upTo: index)

            if ch == "[" {
                guard let parsed = parseLinkRangeFirst(
                    text,
                    startIndex: index,
                    parentStyle: style,
                    baseFont: baseFont,
                    ctx: ctx
                ) else {
                    return nil
                }
                out.append(parsed.attributed)
                index = parsed.nextIndex
                literalStart = index
                continue
            }

            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, isMarkdownEscapable(text[next]) {
                    appendEscapedLiteral(text[next])
                    index = text.index(after: next)
                    literalStart = index
                    continue
                }
                index = next
                continue
            }

            if ch == "<" {
                if let parsed = parseHtmlLineBreakRangeFirst(text, startIndex: index) {
                    appendHtmlLineBreak(sourceMarkdown: String(text[index..<parsed.nextIndex]))
                    index = parsed.nextIndex
                    literalStart = index
                    continue
                }

                if let parsed = parseAutolinkRangeFirst(text, startIndex: index) {
                    var nextStyle = style
                    nextStyle.link = .url(parsed.url)
                    nextStyle.autolink = true
                    out.append(
                        makeInlineAttributed(
                            String(text[parsed.innerRange]),
                            baseFont: baseFont,
                            style: nextStyle
                        )
                    )
                    index = parsed.nextIndex
                    literalStart = index
                    continue
                }
                index = text.index(after: index)
                continue
            }

            if ch == "`" {
                if let parsed = parseCodeSpanRangeFirst(text, startIndex: index) {
                    let normalizedText = normalizeCodeSpanText(text, range: parsed.innerRange)
                    var nextStyle = style
                    nextStyle.code = true
                    nextStyle.strong = false
                    nextStyle.emphasis = false
                    nextStyle.strike = false
                    let attr = NSMutableAttributedString(
                        attributedString: makeInlineAttributed(normalizedText, baseFont: baseFont, style: nextStyle)
                    )
                    if parsed.fenceLength > 1
                        || normalizedText.contains("`")
                        || normalizedText.hasPrefix(" ")
                        || normalizedText.hasSuffix(" ")
                    {
                        attr.addAttribute(
                            .kernSourceMarkdown,
                            value: String(text[parsed.sourceRange]),
                            range: NSRange(location: 0, length: attr.length)
                        )
                    }
                    out.append(attr)
                    index = parsed.nextIndex
                    literalStart = index
                    continue
                }

                var runEnd = index
                while runEnd < text.endIndex, text[runEnd] == "`" {
                    runEnd = text.index(after: runEnd)
                }
                index = runEnd
                continue
            }
        }

        flushLiteral(upTo: text.endIndex)
        return out
    }

    private struct RangeHtmlLineBreakMatch {
        let nextIndex: String.Index
    }

    private struct HtmlLineBreakMatch {
        let nextIndex: Int
    }

    private static func parseHtmlLineBreakRangeFirst(
        _ text: String,
        startIndex: String.Index
    ) -> RangeHtmlLineBreakMatch? {
        guard startIndex < text.endIndex, text[startIndex] == "<" else { return nil }
        var index = text.index(after: startIndex)
        guard index < text.endIndex, text[index].lowercased() == "b" else { return nil }
        index = text.index(after: index)
        guard index < text.endIndex, text[index].lowercased() == "r" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        if index < text.endIndex, text[index] == "/" {
            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
        }
        guard index < text.endIndex, text[index] == ">" else { return nil }
        return RangeHtmlLineBreakMatch(nextIndex: text.index(after: index))
    }

    private static func parseHtmlLineBreak(
        _ chars: [Character],
        startIndex: Int,
        limit: Int
    ) -> HtmlLineBreakMatch? {
        guard startIndex < limit, chars[startIndex] == "<" else { return nil }
        var index = startIndex + 1
        guard index < limit, chars[index].lowercased() == "b" else { return nil }
        index += 1
        guard index < limit, chars[index].lowercased() == "r" else { return nil }
        index += 1

        while index < limit, chars[index].isWhitespace {
            index += 1
        }
        if index < limit, chars[index] == "/" {
            index += 1
            while index < limit, chars[index].isWhitespace {
                index += 1
            }
        }
        guard index < limit, chars[index] == ">" else { return nil }
        return HtmlLineBreakMatch(nextIndex: index + 1)
    }

    private struct RangeAutolinkMatch {
        let innerRange: Range<String.Index>
        let url: URL
        let nextIndex: String.Index
    }

    private static func parseAutolinkRangeFirst(
        _ text: String,
        startIndex: String.Index
    ) -> RangeAutolinkMatch? {
        guard startIndex < text.endIndex, text[startIndex] == "<" else { return nil }
        var index = text.index(after: startIndex)
        while index < text.endIndex {
            if text[index] == ">" {
                let innerRange = text.index(after: startIndex)..<index
                guard let url = parseAutolinkURL(text[innerRange]) else { return nil }
                return RangeAutolinkMatch(
                    innerRange: innerRange,
                    url: url,
                    nextIndex: text.index(after: index)
                )
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseBracketContentRangeFirst(
        _ text: String,
        openIndex: String.Index,
        limit: String.Index
    ) -> RangeBracketContent? {
        guard openIndex < limit, text[openIndex] == "[" else { return nil }
        var index = text.index(after: openIndex)
        var depth = 1
        var escaped = false
        while index < limit {
            let ch = text[index]
            if escaped {
                escaped = false
                index = text.index(after: index)
                continue
            }
            if ch == "\\" {
                escaped = true
                index = text.index(after: index)
                continue
            }
            if ch == "[" {
                depth += 1
                index = text.index(after: index)
                continue
            }
            if ch == "]" {
                depth -= 1
                if depth > 0 {
                    index = text.index(after: index)
                    continue
                }
                return RangeBracketContent(
                    contentRange: text.index(after: openIndex)..<index,
                    closeIndex: index,
                    nextIndex: text.index(after: index)
                )
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseInlineLinkDestinationRangeFirst(
        _ text: String,
        openParenIndex: String.Index,
        limit: String.Index
    ) -> RangeInlineLinkTarget? {
        guard openParenIndex < limit, text[openParenIndex] == "(" else { return nil }

        var index = text.index(after: openParenIndex)
        while index < limit, isASCIISpace(text[index]) {
            index = text.index(after: index)
        }
        guard index < limit else { return nil }

        let destinationRange: Range<String.Index>

        if text[index] == "<" {
            let destinationStart = text.index(after: index)
            index = destinationStart
            var escaped = false
            var sawClosingAngle = false
            while index < limit {
                let ch = text[index]
                if escaped {
                    escaped = false
                    index = text.index(after: index)
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    index = text.index(after: index)
                    continue
                }
                if ch == ">" {
                    sawClosingAngle = true
                    index = text.index(after: index)
                    break
                }
                if ch == "<" || ch == "\n" || ch == "\r" {
                    return nil
                }
                index = text.index(after: index)
            }
            guard sawClosingAngle, destinationStart < text.index(before: index) else { return nil }
            destinationRange = destinationStart..<text.index(before: index)
        } else {
            let destinationStart = index
            var escaped = false
            var parenDepth = 0
            while index < limit {
                let ch = text[index]
                if escaped {
                    escaped = false
                    index = text.index(after: index)
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    index = text.index(after: index)
                    continue
                }
                if ch == "(" {
                    parenDepth += 1
                    index = text.index(after: index)
                    continue
                }
                if ch == ")" {
                    if parenDepth == 0 {
                        break
                    }
                    parenDepth -= 1
                    index = text.index(after: index)
                    continue
                }
                if isASCIISpace(ch) {
                    break
                }
                if ch == "<" || ch == ">" {
                    return nil
                }
                index = text.index(after: index)
            }
            guard destinationStart < index else { return nil }
            destinationRange = destinationStart..<index
        }

        while index < limit, isASCIISpace(text[index]) {
            index = text.index(after: index)
        }

        var titleRange: Range<String.Index>?
        if index < limit, text[index] != ")" {
            guard let parsedTitle = parseInlineLinkTitleRangeFirst(text, startIndex: index, limit: limit) else { return nil }
            titleRange = parsedTitle.titleRange
            index = parsedTitle.nextIndex
            while index < limit, isASCIISpace(text[index]) {
                index = text.index(after: index)
            }
        }

        guard index < limit, text[index] == ")" else { return nil }
        return RangeInlineLinkTarget(
            destinationRange: destinationRange,
            titleRange: titleRange,
            nextIndex: text.index(after: index)
        )
    }

    private static func parseInlineLinkTitleRangeFirst(
        _ text: String,
        startIndex: String.Index,
        limit: String.Index
    ) -> (titleRange: Range<String.Index>, nextIndex: String.Index)? {
        guard startIndex < limit else { return nil }
        let opener = text[startIndex]

        if opener == "\"" || opener == "'" {
            let titleStart = text.index(after: startIndex)
            var index = titleStart
            var escaped = false
            while index < limit {
                let ch = text[index]
                if escaped {
                    escaped = false
                    index = text.index(after: index)
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    index = text.index(after: index)
                    continue
                }
                if ch == opener {
                    return (titleStart..<index, text.index(after: index))
                }
                index = text.index(after: index)
            }
            return nil
        }

        if opener == "(" {
            let titleStart = text.index(after: startIndex)
            var index = titleStart
            var escaped = false
            var depth = 1
            while index < limit {
                let ch = text[index]
                if escaped {
                    escaped = false
                    index = text.index(after: index)
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    index = text.index(after: index)
                    continue
                }
                if ch == "(" {
                    depth += 1
                    index = text.index(after: index)
                    continue
                }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (titleStart..<index, text.index(after: index))
                    }
                    index = text.index(after: index)
                    continue
                }
                index = text.index(after: index)
            }
        }

        return nil
    }

    private static func parseLinkRangeFirst(
        _ text: String,
        startIndex: String.Index,
        parentStyle: InlineStyle,
        baseFont: NSFont,
        ctx: ImportContext
    ) -> RangeInlineParseResult? {
        guard let linkText = parseBracketContentRangeFirst(text, openIndex: startIndex, limit: text.endIndex) else { return nil }
        guard !linkText.contentRange.isEmpty else { return nil }

        let linkLabel = String(text[linkText.contentRange])
        let allowRichLabelParsing = shouldParseSimpleLinkLabel(linkLabel)

        if linkText.nextIndex < text.endIndex, text[linkText.nextIndex] == "(",
           let target = parseInlineLinkDestinationRangeFirst(text, openParenIndex: linkText.nextIndex, limit: text.endIndex)
        {
            if !allowRichLabelParsing {
                let literalEnd = extendedLiteralLinkEndIndexRangeFirst(
                    text: text,
                    initialEnd: target.nextIndex,
                    linkLabelRange: linkText.contentRange
                )
                return makeSourceLiteralResultRangeFirst(
                    text: text,
                    startIndex: startIndex,
                    nextIndex: literalEnd,
                    baseFont: baseFont,
                    style: parentStyle
                )
            }

            let rawDestination = String(text[target.destinationRange])
            let resolvedDestination = unescapeMarkdownBackslashes(rawDestination)
            guard let linkValue = inlineLinkValue(from: resolvedDestination, baseURL: ctx.baseURL) else { return nil }

            var linkStyle = parentStyle
            linkStyle.link = linkValue
            linkStyle.linkDestination = rawDestination
            linkStyle.autolink = false
            let rawTitle = target.titleRange.map { String(text[$0]) }
            linkStyle.linkTitle = rawTitle
            linkStyle.linkReferenceID = nil
            linkStyle.linkReferenceURL = nil

            let inner = NSMutableAttributedString(
                attributedString: parseInline(linkLabel, baseFont: baseFont, style: linkStyle, ctx: ctx)
            )
            if inner.length > 0 {
                inner.addAttribute(.kernLinkDestination, value: rawDestination, range: NSRange(location: 0, length: inner.length))
                if let title = rawTitle {
                    inner.addAttribute(.kernLinkTitle, value: title, range: NSRange(location: 0, length: inner.length))
                }
            }
            return RangeInlineParseResult(attributed: inner, nextIndex: target.nextIndex)
        }

        if linkText.nextIndex < text.endIndex, text[linkText.nextIndex] == "[",
           let ref = parseBracketContentRangeFirst(text, openIndex: linkText.nextIndex, limit: text.endIndex)
        {
            if !allowRichLabelParsing {
                let literalEnd = extendedLiteralLinkEndIndexRangeFirst(
                    text: text,
                    initialEnd: ref.nextIndex,
                    linkLabelRange: linkText.contentRange
                )
                return makeSourceLiteralResultRangeFirst(
                    text: text,
                    startIndex: startIndex,
                    nextIndex: literalEnd,
                    baseFont: baseFont,
                    style: parentStyle
                )
            }

            let refID = ref.contentRange.isEmpty ? linkLabel : String(text[ref.contentRange])
            if let definition = ctx.referenceDefinitions[refID.lowercased()] {
                let resolvedDestination = unescapeMarkdownBackslashes(definition.destination)
                guard let linkValue = inlineLinkValue(from: resolvedDestination, baseURL: ctx.baseURL) else { return nil }

                var linkStyle = parentStyle
                linkStyle.link = linkValue
                linkStyle.linkDestination = nil
                linkStyle.autolink = false
                linkStyle.linkTitle = definition.title
                linkStyle.linkReferenceID = definition.id
                linkStyle.linkReferenceURL = definition.destination

                let inner = NSMutableAttributedString(
                    attributedString: parseInline(linkLabel, baseFont: baseFont, style: linkStyle, ctx: ctx)
                )
                if inner.length > 0 {
                    inner.addAttribute(.kernLinkReferenceID, value: definition.id, range: NSRange(location: 0, length: inner.length))
                    inner.addAttribute(.kernLinkReferenceURL, value: definition.destination, range: NSRange(location: 0, length: inner.length))
                    if let title = definition.title {
                        inner.addAttribute(.kernLinkTitle, value: title, range: NSRange(location: 0, length: inner.length))
                    }
                }
                return RangeInlineParseResult(attributed: inner, nextIndex: ref.nextIndex)
            }
        }

        return nil
    }

    private static func makeSourceLiteralResultRangeFirst(
        text: String,
        startIndex: String.Index,
        nextIndex: String.Index,
        baseFont: NSFont,
        style: InlineStyle
    ) -> RangeInlineParseResult? {
        guard startIndex < nextIndex else { return nil }
        let sourceMarkdown = String(text[startIndex..<nextIndex])
        let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(sourceMarkdown, baseFont: baseFont, style: style))
        if attr.length > 0 {
            attr.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: NSRange(location: 0, length: attr.length))
        }
        return RangeInlineParseResult(attributed: attr, nextIndex: nextIndex)
    }

    private static func extendedLiteralLinkEndIndexRangeFirst(
        text: String,
        initialEnd: String.Index,
        linkLabelRange: Range<String.Index>
    ) -> String.Index {
        let backtickCount = text[linkLabelRange].reduce(into: 0) { partialResult, ch in
            if ch == "`" {
                partialResult += 1
            }
        }
        if backtickCount % 2 != 0,
           initialEnd < text.endIndex,
           text[initialEnd] == "`" {
            return text.index(after: initialEnd)
        }
        return initialEnd
    }

    private static func parseInlineCharacters(
        _ chars: [Character],
        range: Range<Int>,
        baseFont: NSFont,
        style: InlineStyle,
        ctx: ImportContext
    ) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        out.beginEditing()
        defer { out.endEditing() }
        appendInlineCharacters(chars, range: range, baseFont: baseFont, style: style, ctx: ctx, into: out)
        return out
    }

    private static func appendInlineCharacters(
        _ chars: [Character],
        range: Range<Int>,
        baseFont: NSFont,
        style: InlineStyle,
        ctx: ImportContext,
        into out: NSMutableAttributedString
    ) {
        var i = range.lowerBound
        var literalStart = range.lowerBound

        func flushLiteral(upTo end: Int) {
            guard literalStart < end else {
                literalStart = end
                return
            }
            out.append(
                makeInlineAttributed(
                    materializeCharacters(chars, range: literalStart..<end),
                    baseFont: baseFont,
                    style: style
                )
            )
            literalStart = end
        }

        func appendLiteral(_ text: String, style: InlineStyle) {
            out.append(makeInlineAttributed(text, baseFont: baseFont, style: style))
        }

        func appendEscapedLiteral(_ s: String, style: InlineStyle) {
            let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(s, baseFont: baseFont, style: style))
            if attr.length > 0 {
                attr.addAttribute(.kernEscapedLiteral, value: true, range: NSRange(location: 0, length: attr.length))
            }
            out.append(attr)
        }

        func appendHtmlLineBreak(sourceMarkdown: String, style: InlineStyle) {
            out.append(makeHtmlLineBreakAttributed(sourceMarkdown: sourceMarkdown, baseFont: baseFont, style: style))
        }

        func appendImageAttachment(alt: String, destination: String, sourceMarkdown: String) {
            out.append(
                measureImportPhase(.makeImageAttachmentAttributed, profiler: ctx.profiler) {
                    makeImageAttachmentAttributed(
                        alt: alt,
                        destination: destination,
                        sourceMarkdown: sourceMarkdown,
                        baseFont: baseFont,
                        ctx: ctx
                    )
                }
            )
        }

        while i < range.upperBound {
            let ch = chars[i]

            // Fast path: advance over plain characters and flush them as one contiguous span.
            if ch != "\\" && ch != "!" && ch != "<" && ch != "[" && ch != "$" && ch != "`" && ch != "*" && ch != "_" && ch != "~" {
                i += 1
                continue
            }

            flushLiteral(upTo: i)

            // Escape: only strip the backslash for escapable punctuation.
            if ch == "\\" {
                if i + 1 < range.upperBound, isMarkdownEscapable(chars[i + 1]) {
                    appendEscapedLiteral(String(chars[i + 1]), style: style)
                    i += 2
                    literalStart = i
                    continue
                }
                i += 1
                continue
            }

            // Images: ![alt](url "title") / ![alt][id]
            if ch == "!", i + 1 < range.upperBound, chars[i + 1] == "[" {
                if let image = parseImage(chars, startIndex: i, limit: range.upperBound, ctx: ctx) {
                    appendImageAttachment(alt: image.alt, destination: image.destination, sourceMarkdown: image.sourceMarkdown)
                    i = image.nextIndex
                    literalStart = i
                    continue
                }
            }

            // Inline HTML line break: render bare <br>, <br/>, and <br /> as a visual line break.
            if ch == "<", let parsed = parseHtmlLineBreak(chars, startIndex: i, limit: range.upperBound) {
                appendHtmlLineBreak(sourceMarkdown: materializeCharacters(chars, range: i..<parsed.nextIndex), style: style)
                i = parsed.nextIndex
                literalStart = i
                continue
            }

            // Autolink: <https://...> or <me@example.com>
            if ch == "<" {
                if let end = indexOf(">", in: chars, start: i + 1, limit: range.upperBound) {
                    let inner = materializeCharacters(chars, range: (i + 1)..<end)
                    if let url = parseAutolinkURL(inner) {
                        var nextStyle = style
                        nextStyle.link = .url(url)
                        nextStyle.autolink = true
                        appendLiteral(inner, style: nextStyle)
                        i = end + 1
                        literalStart = i
                        continue
                    }
                }
            }

            // Link: [text](url "title") / [text][id]
            if ch == "[" {
                if let link = parseLink(chars, startIndex: i, limit: range.upperBound, parentStyle: style, baseFont: baseFont, ctx: ctx) {
                    out.append(link.attributed)
                    i = link.nextIndex
                    literalStart = i
                    continue
                }
            }

            // Inline math: $...$ (avoid currency, keep escaped dollars as literal text).
            if ch == "$" {
                if let parsed = parseInlineMath(chars, startIndex: i, limit: range.upperBound, baseFont: baseFont) {
                    out.append(parsed.attributed)
                    i = parsed.nextIndex
                    literalStart = i
                    continue
                }
            }

            // Code span
            if ch == "`" {
                if let parsed = parseCodeSpan(chars, startIndex: i, limit: range.upperBound) {
                    let normalizedText = normalizeCodeSpanText(chars, range: parsed.innerRange)
                    var nextStyle = style
                    nextStyle.code = true
                    nextStyle.strong = false
                    nextStyle.emphasis = false
                    nextStyle.strike = false
                    let attr = NSMutableAttributedString(
                        attributedString: makeInlineAttributed(normalizedText, baseFont: baseFont, style: nextStyle)
                    )
                    if parsed.fenceLength > 1
                        || normalizedText.contains("`")
                        || normalizedText.hasPrefix(" ")
                        || normalizedText.hasSuffix(" ")
                    {
                        attr.addAttribute(
                            .kernSourceMarkdown,
                            value: materializeCharacters(chars, range: parsed.sourceRange),
                            range: NSRange(location: 0, length: attr.length)
                        )
                    }
                    out.append(attr)
                    i = parsed.nextIndex
                    literalStart = i
                    continue
                }
                // No valid closing fence for this backtick run; emit the whole run literally
                // so we don't re-enter on the same run and produce incorrect nested parses.
                var runEnd = i
                while runEnd < range.upperBound, chars[runEnd] == "`" {
                    runEnd += 1
                }
                i = runEnd
                continue
            }

            // Strong + emphasis (***text*** / ___text___)
            if (ch == "*" || ch == "_"), i + 2 < range.upperBound, chars[i + 1] == ch, chars[i + 2] == ch {
                if canOpenDelimiter(ch, count: 3, in: chars, at: i, lowerBound: range.lowerBound, upperBound: range.upperBound),
                   let end = findClosingDelimiter(ch, count: 3, in: chars, start: i + 3, lowerBound: range.lowerBound, limit: range.upperBound)
                {
                    let innerRange = (i + 3)..<end
                    if !isValidInlineDelimitedContent(chars, range: innerRange) {
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.strong.toggle()
                    nextStyle.emphasis.toggle()
                    appendInlineCharacters(chars, range: innerRange, baseFont: baseFont, style: nextStyle, ctx: ctx, into: out)
                    i = end + 3
                    literalStart = i
                    continue
                }
            }

            // Strikethrough
            if ch == "~", i + 1 < range.upperBound, chars[i + 1] == "~" {
                if let end = findClosingDelimiter("~", count: 2, in: chars, start: i + 2, lowerBound: range.lowerBound, limit: range.upperBound) {
                    let innerRange = (i + 2)..<end
                    if innerRange.isEmpty {
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.strike.toggle()
                    appendInlineCharacters(chars, range: innerRange, baseFont: baseFont, style: nextStyle, ctx: ctx, into: out)
                    i = end + 2
                    literalStart = i
                    continue
                }
            }

            // Strong (**text** / __text__)
            if (ch == "*" || ch == "_"), i + 1 < range.upperBound, chars[i + 1] == ch {
                if canOpenDelimiter(ch, count: 2, in: chars, at: i, lowerBound: range.lowerBound, upperBound: range.upperBound),
                   let end = findClosingDelimiter(ch, count: 2, in: chars, start: i + 2, lowerBound: range.lowerBound, limit: range.upperBound)
                {
                    let innerRange = (i + 2)..<end
                    if !isValidInlineDelimitedContent(chars, range: innerRange) {
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.strong.toggle()
                    appendInlineCharacters(chars, range: innerRange, baseFont: baseFont, style: nextStyle, ctx: ctx, into: out)
                    i = end + 2
                    literalStart = i
                    continue
                }
            }

            // Emphasis (*text* / _text_)
            if ch == "*" || ch == "_" {
                if canOpenDelimiter(ch, count: 1, in: chars, at: i, lowerBound: range.lowerBound, upperBound: range.upperBound),
                   let end = findClosingDelimiter(ch, count: 1, in: chars, start: i + 1, lowerBound: range.lowerBound, limit: range.upperBound)
                {
                    let innerRange = (i + 1)..<end
                    if !isValidInlineDelimitedContent(chars, range: innerRange) {
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.emphasis.toggle()
                    appendInlineCharacters(chars, range: innerRange, baseFont: baseFont, style: nextStyle, ctx: ctx, into: out)
                    i = end + 1
                    literalStart = i
                    continue
                }
            }

            i += 1
        }

        flushLiteral(upTo: range.upperBound)
    }

    private static func materializeCharacters(_ chars: [Character], range: Range<Int>) -> String {
        String(chars[range])
    }

    private static func parseBracketContent(_ chars: [Character], openIndex: Int, limit: Int) -> BracketContent? {
        guard openIndex < limit, chars[openIndex] == "[" else { return nil }
        var i = openIndex + 1
        var depth = 1
        var escaped = false
        while i < limit {
            let ch = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if ch == "\\" {
                escaped = true
                i += 1
                continue
            }
            if ch == "[" {
                depth += 1
                i += 1
                continue
            }
            if ch == "]" {
                depth -= 1
                if depth > 0 {
                    i += 1
                    continue
                }
                let contentRange = (openIndex + 1)..<i
                return BracketContent(
                    contentRange: contentRange,
                    closeIndex: i,
                    nextIndex: i + 1
                )
            }
            i += 1
        }
        return nil
    }

    private static func isValidInlineDelimitedContent(_ chars: [Character], range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        let first = chars[range.lowerBound]
        let last = chars[range.upperBound - 1]
        if first.isWhitespace || last.isWhitespace { return false }
        return true
    }

    private static func parseInlineLinkDestination(_ chars: [Character], openParenIndex: Int, limit: Int) -> InlineLinkTarget? {
        guard openParenIndex < limit, chars[openParenIndex] == "(" else { return nil }

        var i = openParenIndex + 1
        while i < limit, isASCIISpace(chars[i]) { i += 1 }
        guard i < limit else { return nil }

        let destinationRange: Range<Int>

        if chars[i] == "<" {
            // Angle-bracket destination form: [label](<dest> "title")
            let destinationStart = i + 1
            i = destinationStart
            var escaped = false
            var sawClosingAngle = false
            while i < limit {
                let ch = chars[i]
                if escaped {
                    escaped = false
                    i += 1
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    i += 1
                    continue
                }
                if ch == ">" {
                    sawClosingAngle = true
                    i += 1
                    break
                }
                // CommonMark does not allow unescaped "<" or line breaks inside angle destinations.
                if ch == "<" || ch == "\n" || ch == "\r" {
                    return nil
                }
                i += 1
            }
            guard sawClosingAngle, destinationStart < (i - 1) else { return nil }
            destinationRange = destinationStart..<(i - 1)
        } else {
            // Bare destination form: [label](dest "title")
            // Destination cannot contain ASCII whitespace. Balanced parentheses are allowed.
            let destinationStart = i
            var escaped = false
            var parenDepth = 0
            while i < limit {
                let ch = chars[i]
                if escaped {
                    escaped = false
                    i += 1
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    i += 1
                    continue
                }
                if ch == "(" {
                    parenDepth += 1
                    i += 1
                    continue
                }
                if ch == ")" {
                    if parenDepth == 0 {
                        break
                    }
                    parenDepth -= 1
                    i += 1
                    continue
                }
                if isASCIISpace(ch) {
                    break
                }
                if ch == "<" || ch == ">" {
                    return nil
                }
                i += 1
            }
            guard destinationStart < i else { return nil }
            destinationRange = destinationStart..<i
        }

        while i < limit, isASCIISpace(chars[i]) { i += 1 }

        var titleRange: Range<Int>?
        if i < limit, chars[i] != ")" {
            guard let parsedTitle = parseInlineLinkTitle(chars, startIndex: i, limit: limit) else { return nil }
            titleRange = parsedTitle.titleRange
            i = parsedTitle.nextIndex
            while i < limit, isASCIISpace(chars[i]) { i += 1 }
        }

        guard i < limit, chars[i] == ")" else { return nil }
        return InlineLinkTarget(destinationRange: destinationRange, titleRange: titleRange, nextIndex: i + 1)
    }


    private static func parseInlineLinkTitle(_ chars: [Character], startIndex: Int, limit: Int) -> (titleRange: Range<Int>, nextIndex: Int)? {
        guard startIndex < limit else { return nil }
        let opener = chars[startIndex]

        if opener == "\"" || opener == "'" {
            let titleStart = startIndex + 1
            var i = titleStart
            var escaped = false
            while i < limit {
                let ch = chars[i]
                if escaped {
                    escaped = false
                    i += 1
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    i += 1
                    continue
                }
                if ch == opener {
                    return (titleStart..<i, i + 1)
                }
                i += 1
            }
            return nil
        }

        if opener == "(" {
            let titleStart = startIndex + 1
            var i = titleStart
            var escaped = false
            var depth = 1
            while i < limit {
                let ch = chars[i]
                if escaped {
                    escaped = false
                    i += 1
                    continue
                }
                if ch == "\\" {
                    escaped = true
                    i += 1
                    continue
                }
                if ch == "(" {
                    depth += 1
                    i += 1
                    continue
                }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (titleStart..<i, i + 1)
                    }
                    i += 1
                    continue
                }
                i += 1
            }
        }

        return nil
    }

    private static func isASCIISpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{000C}"
    }

    private struct CodeSpanMatch {
        let innerRange: Range<Int>
        let sourceRange: Range<Int>
        let fenceLength: Int
        let nextIndex: Int
    }

    private static func parseCodeSpan(_ chars: [Character], startIndex: Int, limit: Int) -> CodeSpanMatch? {
        guard startIndex < limit, chars[startIndex] == "`" else { return nil }

        var fenceLen = 0
        var i = startIndex
        while i < limit, chars[i] == "`" {
            fenceLen += 1
            i += 1
        }
        guard fenceLen > 0 else { return nil }

        var scan = i
        while scan < limit {
            if chars[scan] == "`" {
                var run = 0
                var j = scan
                while j < limit, chars[j] == "`" {
                    run += 1
                    j += 1
                }
                if run == fenceLen {
                    return CodeSpanMatch(
                        innerRange: i..<scan,
                        sourceRange: startIndex..<j,
                        fenceLength: fenceLen,
                        nextIndex: j
                    )
                }
                scan = j
                continue
            }
            scan += 1
        }
        return nil
    }

    private static func parseCodeSpanRangeFirst(
        _ text: String,
        startIndex: String.Index
    ) -> RangeCodeSpanMatch? {
        guard startIndex < text.endIndex, text[startIndex] == "`" else { return nil }

        var fenceLength = 0
        var index = startIndex
        while index < text.endIndex, text[index] == "`" {
            fenceLength += 1
            index = text.index(after: index)
        }
        guard fenceLength > 0 else { return nil }

        let innerStart = index
        var scan = innerStart
        while scan < text.endIndex {
            if text[scan] == "`" {
                var runLength = 0
                var runEnd = scan
                while runEnd < text.endIndex, text[runEnd] == "`" {
                    runLength += 1
                    runEnd = text.index(after: runEnd)
                }
                if runLength == fenceLength {
                    return RangeCodeSpanMatch(
                        innerRange: innerStart..<scan,
                        sourceRange: startIndex..<runEnd,
                        fenceLength: fenceLength,
                        nextIndex: runEnd
                    )
                }
                scan = runEnd
                continue
            }
            scan = text.index(after: scan)
        }
        return nil
    }

    private static func normalizeCodeSpanText(_ inner: String) -> String {
        guard inner.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            var normalized = inner
            if normalized.hasPrefix(" "),
               normalized.hasSuffix(" "),
               normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                normalized.removeFirst()
                normalized.removeLast()
            }
            return normalized
        }

        var normalized = String()
        normalized.reserveCapacity(inner.utf16.count)
        var index = inner.startIndex
        while index < inner.endIndex {
            let ch = inner[index]
            if ch == "\r" {
                let next = inner.index(after: index)
                if next < inner.endIndex, inner[next] == "\n" {
                    index = next
                }
                normalized.append(" ")
            } else if ch == "\n" {
                normalized.append(" ")
            } else {
                normalized.append(ch)
            }
            index = inner.index(after: index)
        }

        if normalized.hasPrefix(" "),
           normalized.hasSuffix(" "),
           normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
    }

    private static func normalizeCodeSpanText(_ chars: [Character], range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }

        var containsLineBreak = false
        for index in range {
            let ch = chars[index]
            if ch == "\r" || ch == "\n" {
                containsLineBreak = true
                break
            }
        }

        guard containsLineBreak else {
            var normalized = materializeCharacters(chars, range: range)
            if normalized.hasPrefix(" "),
               normalized.hasSuffix(" "),
               normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                normalized.removeFirst()
                normalized.removeLast()
            }
            return normalized
        }

        var normalized = String()
        normalized.reserveCapacity(range.count)
        var index = range.lowerBound
        while index < range.upperBound {
            let ch = chars[index]
            if ch == "\r" {
                let next = index + 1
                if next < range.upperBound, chars[next] == "\n" {
                    index = next
                }
                normalized.append(" ")
            } else if ch == "\n" {
                normalized.append(" ")
            } else {
                normalized.append(ch)
            }
            index += 1
        }

        if normalized.hasPrefix(" "),
           normalized.hasSuffix(" "),
           normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
    }

    private static func normalizeCodeSpanText(_ text: String, range: Range<String.Index>) -> String {
        guard !range.isEmpty else { return "" }

        let inner = text[range]
        guard inner.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            var normalized = String(inner)
            if normalized.hasPrefix(" "),
               normalized.hasSuffix(" "),
               normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                normalized.removeFirst()
                normalized.removeLast()
            }
            return normalized
        }

        var normalized = String()
        normalized.reserveCapacity(inner.utf16.count)
        var index = inner.startIndex
        while index < inner.endIndex {
            let ch = inner[index]
            if ch == "\r" {
                let next = inner.index(after: index)
                if next < inner.endIndex, inner[next] == "\n" {
                    index = next
                }
                normalized.append(" ")
            } else if ch == "\n" {
                normalized.append(" ")
            } else {
                normalized.append(ch)
            }
            index = inner.index(after: index)
        }

        if normalized.hasPrefix(" "),
           normalized.hasSuffix(" "),
           normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
    }

    private static func findClosingDelimiter(
        _ ch: Character,
        count: Int,
        in chars: [Character],
        start: Int,
        lowerBound: Int,
        limit: Int
    ) -> Int? {
        guard count > 0, start < limit else { return nil }
        let lastCandidate = limit - count + 1
        var index = start
        while index < lastCandidate {
            if chars[index] == ch {
                var matchesRun = true
                if count > 1 {
                    for offset in 1..<count where chars[index + offset] != ch {
                        matchesRun = false
                        break
                    }
                }
                if matchesRun,
                   canCloseDelimiter(ch, count: count, in: chars, at: index, lowerBound: lowerBound, upperBound: limit) {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func canOpenDelimiter(
        _ marker: Character,
        count: Int,
        in chars: [Character],
        at index: Int,
        lowerBound: Int,
        upperBound: Int
    ) -> Bool {
        guard index >= 0, index + count <= chars.count else { return false }
        let prev = index > lowerBound ? chars[index - 1] : nil
        let next = (index + count) < upperBound ? chars[index + count] : nil
        let leftFlanking = isLeftFlankingDelimiterRun(prev: prev, next: next)
        guard leftFlanking else { return false }
        if marker != "_" { return true }

        let rightFlanking = isRightFlankingDelimiterRun(prev: prev, next: next)
        return !rightFlanking || isPunctuation(prev)
    }

    private static func canCloseDelimiter(
        _ marker: Character,
        count: Int,
        in chars: [Character],
        at index: Int,
        lowerBound: Int,
        upperBound: Int
    ) -> Bool {
        guard index >= 0, index + count <= chars.count else { return false }
        let prev = index > lowerBound ? chars[index - 1] : nil
        let next = (index + count) < upperBound ? chars[index + count] : nil
        let rightFlanking = isRightFlankingDelimiterRun(prev: prev, next: next)
        guard rightFlanking else { return false }
        if marker != "_" { return true }

        let leftFlanking = isLeftFlankingDelimiterRun(prev: prev, next: next)
        return !leftFlanking || isPunctuation(next)
    }

    private static func isLeftFlankingDelimiterRun(prev: Character?, next: Character?) -> Bool {
        let nextIsWhitespace = isWhitespace(next)
        let nextIsPunctuation = isPunctuation(next)
        let prevIsWhitespace = isWhitespace(prev)
        let prevIsPunctuation = isPunctuation(prev)
        return !nextIsWhitespace && (!nextIsPunctuation || prevIsWhitespace || prevIsPunctuation)
    }

    private static func isRightFlankingDelimiterRun(prev: Character?, next: Character?) -> Bool {
        let prevIsWhitespace = isWhitespace(prev)
        let prevIsPunctuation = isPunctuation(prev)
        let nextIsWhitespace = isWhitespace(next)
        let nextIsPunctuation = isPunctuation(next)
        return !prevIsWhitespace && (!prevIsPunctuation || nextIsWhitespace || nextIsPunctuation)
    }

    private static func isWhitespace(_ ch: Character?) -> Bool {
        guard let ch else { return true }
        return ch.isWhitespace || ch.isNewline
    }

    private static func isPunctuation(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        if ch.isASCII {
            return !ch.isLetter && !ch.isNumber && !ch.isWhitespace && !ch.isNewline
        }
        return ch.isPunctuation || ch.isSymbol
    }

    private static func parseInlineMath(_ chars: [Character], startIndex: Int, limit: Int, baseFont: NSFont) -> InlineParseResult? {
        guard startIndex < limit, chars[startIndex] == "$" else { return nil }
        guard startIndex + 1 < limit else { return nil }

        let next = chars[startIndex + 1]
        // Avoid interpreting currency as math (`$5`).
        if next.isNumber || next.isWhitespace || next == "$" {
            return nil
        }

        var i = startIndex + 1
        var escaped = false
        while i < limit {
            let ch = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if ch == "\\" {
                escaped = true
                i += 1
                continue
            }
            if ch == "$" {
                let expr = materializeCharacters(chars, range: (startIndex + 1)..<i)
                guard !expr.isEmpty else { return nil }
                guard !expr.contains("\n") else { return nil }
                guard !expr.hasPrefix(" "), !expr.hasSuffix(" ") else { return nil }
                let source = materializeCharacters(chars, range: startIndex..<(i + 1))
                let attr = makeInlineMathAttributed(expression: expr, sourceMarkdown: source, baseFont: baseFont)
                return InlineParseResult(attributed: attr, nextIndex: i + 1)
            }
            i += 1
        }
        return nil
    }

    private static func parseImage(_ chars: [Character], startIndex: Int, limit: Int, ctx: ImportContext) -> (alt: String, destination: String, sourceMarkdown: String, nextIndex: Int)? {
        guard startIndex + 1 < limit, chars[startIndex] == "!", chars[startIndex + 1] == "[" else { return nil }
        guard let alt = parseBracketContent(chars, openIndex: startIndex + 1, limit: limit) else { return nil }
        let altText = materializeCharacters(chars, range: alt.contentRange)

        // Inline destination: ![alt](url "title")
        if alt.nextIndex < limit, chars[alt.nextIndex] == "(",
           let target = parseInlineLinkDestination(chars, openParenIndex: alt.nextIndex, limit: limit)
        {
            let destination = materializeCharacters(chars, range: target.destinationRange)
            let source = materializeCharacters(chars, range: startIndex..<target.nextIndex)
            return (altText, destination, source, target.nextIndex)
        }

        // Reference destination: ![alt][id]
        if alt.nextIndex < limit, chars[alt.nextIndex] == "[",
           let ref = parseBracketContent(chars, openIndex: alt.nextIndex, limit: limit)
        {
            let refID = ref.contentRange.isEmpty ? altText : materializeCharacters(chars, range: ref.contentRange)
            if let def = ctx.referenceDefinitions[refID.lowercased()] {
                let source = materializeCharacters(chars, range: startIndex..<ref.nextIndex)
                return (altText, def.destination, source, ref.nextIndex)
            }
        }

        return nil
    }

    private static func parseLink(_ chars: [Character], startIndex: Int, limit: Int, parentStyle: InlineStyle, baseFont: NSFont, ctx: ImportContext) -> InlineParseResult? {
        guard let linkText = parseBracketContent(chars, openIndex: startIndex, limit: limit) else { return nil }
        // Keep empty link labels literal to avoid dropping syntax during round-trip (`[](...)`).
        guard !linkText.contentRange.isEmpty else { return nil }
        // Defer complex labels we don't serialize correctly yet (nested links/images, mixed inline-code + emphasis).
        // Keeping them literal preserves strict markdown round-trip semantics until the full inline parser lands.
        let linkLabel = materializeCharacters(chars, range: linkText.contentRange)
        let allowRichLabelParsing = shouldParseSimpleLinkLabel(linkLabel)

        // Inline destination: [text](url "title")
        if linkText.nextIndex < limit, chars[linkText.nextIndex] == "(",
           let target = parseInlineLinkDestination(chars, openParenIndex: linkText.nextIndex, limit: limit)
        {
            if !allowRichLabelParsing {
                let literalEnd = extendedLiteralLinkEndIndex(chars: chars, initialEnd: target.nextIndex, linkLabelRange: linkText.contentRange)
                return makeSourceLiteralResult(chars: chars, startIndex: startIndex, nextIndex: literalEnd, baseFont: baseFont, style: parentStyle)
            }
            let rawDestination = materializeCharacters(chars, range: target.destinationRange)
            let resolvedDestination = unescapeMarkdownBackslashes(rawDestination)
            guard let linkValue = inlineLinkValue(from: resolvedDestination, baseURL: ctx.baseURL) else { return nil }
            var linkStyle = parentStyle
            linkStyle.link = linkValue
            linkStyle.linkDestination = rawDestination
            linkStyle.autolink = false
            let rawTitle = target.titleRange.map { materializeCharacters(chars, range: $0) }
            linkStyle.linkTitle = rawTitle
            linkStyle.linkReferenceID = nil
            linkStyle.linkReferenceURL = nil
            let inner = NSMutableAttributedString(
                attributedString: parseInline(linkLabel, baseFont: baseFont, style: linkStyle, ctx: ctx)
            )
            if inner.length > 0 {
                inner.addAttribute(.kernLinkDestination, value: rawDestination, range: NSRange(location: 0, length: inner.length))
                if let title = rawTitle {
                    inner.addAttribute(.kernLinkTitle, value: title, range: NSRange(location: 0, length: inner.length))
                }
            }
            return InlineParseResult(attributed: inner, nextIndex: target.nextIndex)
        }

        // Reference destination: [text][id]
        if linkText.nextIndex < limit, chars[linkText.nextIndex] == "[",
           let ref = parseBracketContent(chars, openIndex: linkText.nextIndex, limit: limit)
        {
            if !allowRichLabelParsing {
                let literalEnd = extendedLiteralLinkEndIndex(chars: chars, initialEnd: ref.nextIndex, linkLabelRange: linkText.contentRange)
                return makeSourceLiteralResult(chars: chars, startIndex: startIndex, nextIndex: literalEnd, baseFont: baseFont, style: parentStyle)
            }
            let refID = ref.contentRange.isEmpty ? linkLabel : materializeCharacters(chars, range: ref.contentRange)
            if let definition = ctx.referenceDefinitions[refID.lowercased()] {
                let resolvedDestination = unescapeMarkdownBackslashes(definition.destination)
                guard let linkValue = inlineLinkValue(from: resolvedDestination, baseURL: ctx.baseURL) else { return nil }
                var linkStyle = parentStyle
                linkStyle.link = linkValue
                linkStyle.linkDestination = nil
                linkStyle.autolink = false
                linkStyle.linkTitle = definition.title
                linkStyle.linkReferenceID = definition.id
                linkStyle.linkReferenceURL = definition.destination

                let inner = NSMutableAttributedString(
                    attributedString: parseInline(linkLabel, baseFont: baseFont, style: linkStyle, ctx: ctx)
                )
                if inner.length > 0 {
                    inner.addAttribute(.kernLinkReferenceID, value: definition.id, range: NSRange(location: 0, length: inner.length))
                    inner.addAttribute(.kernLinkReferenceURL, value: definition.destination, range: NSRange(location: 0, length: inner.length))
                    if let title = definition.title {
                        inner.addAttribute(.kernLinkTitle, value: title, range: NSRange(location: 0, length: inner.length))
                    }
                }
                return InlineParseResult(attributed: inner, nextIndex: ref.nextIndex)
            }
        }

        return nil
    }

    private static func makeSourceLiteralResult(
        chars: [Character],
        startIndex: Int,
        nextIndex: Int,
        baseFont: NSFont,
        style: InlineStyle
    ) -> InlineParseResult? {
        guard nextIndex > startIndex, nextIndex <= chars.count else { return nil }
        let sourceMarkdown = String(chars[startIndex..<nextIndex])
        let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(sourceMarkdown, baseFont: baseFont, style: style))
        if attr.length > 0 {
            attr.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: NSRange(location: 0, length: attr.length))
        }
        return InlineParseResult(attributed: attr, nextIndex: nextIndex)
    }

    private static func extendedLiteralLinkEndIndex(chars: [Character], initialEnd: Int, linkLabelRange: Range<Int>) -> Int {
        var end = initialEnd
        var backtickCount = 0
        for index in linkLabelRange where chars[index] == "`" {
            backtickCount += 1
        }
        // CommonMark edge case: `[foo`](/uri)` and `[foo`][ref]` should remain literal.
        if backtickCount % 2 != 0, end < chars.count, chars[end] == "`" {
            end += 1
        }
        return end
    }

    private static func shouldParseSimpleLinkLabel(_ text: String) -> Bool {
        if text.contains("[") || text.contains("]") {
            return false
        }
        let backticks = text.filter { $0 == "`" }.count
        if backticks % 2 != 0 {
            return false
        }
        if backticks > 0 && (text.contains("*") || text.contains("_")) {
            return false
        }
        return true
    }

    private static func makeHtmlLineBreakAttributed(
        sourceMarkdown: String,
        baseFont: NSFont,
        style: InlineStyle
    ) -> NSAttributedString {
        let attr = NSMutableAttributedString(
            attributedString: makeInlineAttributed("\u{2028}", baseFont: baseFont, style: style)
        )
        let full = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.kernHtmlLineBreak, value: true, range: full)
        attr.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: full)
        return attr
    }

    private static func makeInlineAttributed(
        _ text: String,
        baseFont: NSFont,
        style: InlineStyle
    ) -> NSAttributedString {
        let font = cachedInlineFont(baseFont: baseFont, style: style)
        var attrs = cachedInlineAttributesWithoutLink(
            baseFont: baseFont,
            style: style,
            font: font
        )

        if !style.code, let link = style.link {
            attrs[.link] = link.attributeValue
            attrs[.foregroundColor] = NativeEditorAppearance.linkColor()
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let destination = style.linkDestination {
                attrs[.kernLinkDestination] = destination
            }
            if style.autolink {
                attrs[.kernAutolink] = true
            }
            if let title = style.linkTitle {
                attrs[.kernLinkTitle] = title
            }
            if let refID = style.linkReferenceID {
                attrs[.kernLinkReferenceID] = refID
            }
            if let refURL = style.linkReferenceURL {
                attrs[.kernLinkReferenceURL] = refURL
            }
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Export

    private static func exportParagraph(_ paragraphWithNewline: NSAttributedString, options: Options) -> String {
        // Drop trailing newline for analysis.
        let text = paragraphWithNewline.string
        let paraText = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let quoteDepth: Int = {
            guard paragraphWithNewline.length > 0 else { return 0 }
            return (paragraphWithNewline.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
        }()
        let paraRange = NSRange(location: 0, length: min(paragraphWithNewline.length, (paraText as NSString).length))
        let paragraph = paragraphWithNewline.attributedSubstring(from: paraRange)

        // Empty line
        if paraText.isEmpty {
            if quoteDepth > 0 {
                // Represent an empty blockquote line as `>` / `> >` etc.
                return String(repeating: "> ", count: quoteDepth).trimmingCharacters(in: .whitespaces)
            }
            return ""
        }

        let kindRaw = paragraph.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph

        // Code block is grouped by exportMarkdown().
        if kind == .codeBlock { return paraText }

        // Reference definition paragraph: `[id]: url "title"`.
        if kind == .paragraph,
           let defID = paragraph.attribute(.kernReferenceDefinitionID, at: 0, effectiveRange: nil) as? String,
           let defURL = paragraph.attribute(.kernReferenceDefinitionURL, at: 0, effectiveRange: nil) as? String
        {
            let listIndent = (paragraph.attribute(.kernListIndent, at: 0, effectiveRange: nil) as? Int) ?? 0
            let indentPrefix = String(repeating: " ", count: max(0, listIndent))
            var line = "[\(defID)]: \(defURL)"
            if let title = paragraph.attribute(.kernReferenceDefinitionTitle, at: 0, effectiveRange: nil) as? String, !title.isEmpty {
                line += " \"\(title)\""
            }
            line = indentPrefix + line
            if quoteDepth > 0 {
                let prefix = String(repeating: "> ", count: quoteDepth)
                return prefix + line
            }
            return line
        }

        // Find the first non-marker character (skip bullet/checkbox markers).
        var contentStart = 0
        while contentStart < paragraph.length {
            let isMarker = (paragraph.attribute(.kernMarker, at: contentStart, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            contentStart += 1
        }

        let contentRange = NSRange(location: contentStart, length: max(0, paragraph.length - contentStart))
        let content = paragraph.attributedSubstring(from: contentRange)

        let body: String
        let softBreakKind: KernBlockKind
        switch kind {
        case .heading:
            let level = (paragraph.attribute(.kernHeadingLevel, at: 0, effectiveRange: nil) as? Int) ?? 1
            let prefix = String(repeating: "#", count: max(1, min(6, level))) + " "
            let headingText = exportInline(content)
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")

            // If the heading begins with a checkbox glyph, serialize as `## [ ] Heading` (Kern extension).
            if let checked = findFirstCheckboxState(in: paragraph) {
                switch (options.exportDialect, options.gfmExtensionExportStrategy) {
                case (.gfm, .portable):
                    let glyph = checked ? "\u{2611}" : "\u{2610}"
                    body = prefix + "\(glyph) " + headingText
                    softBreakKind = .heading
                case (.gfm, .lint):
                    let box = checked ? "x" : " "
                    body = "- [\(box)] " + headingText
                    softBreakKind = .task
                default:
                    let box = checked ? "x" : " "
                    body = prefix + "[\(box)] " + headingText
                    softBreakKind = .heading
                }
            } else {
                // Preserve multiline heading semantics with setext syntax when possible.
                // ATX headings cannot span lines, but setext headings can.
                if headingText.contains(where: \.isNewline), level <= 2 {
                    let underline = level == 1 ? "===" : "---"
                    body = headingText + "\n" + underline
                    softBreakKind = .paragraph
                } else {
                    body = prefix + headingText
                    softBreakKind = .heading
                }
            }
        case .task:
            let checked = findFirstCheckboxState(in: paragraph) ?? false
            let box = checked ? "x" : " "
            let styleRaw = paragraph.attribute(.kernTaskStyle, at: 0, effectiveRange: nil) as? Int
            let style = KernTaskStyle(rawValue: styleRaw ?? KernTaskStyle.bulleted.rawValue) ?? .bulleted
            let storedMarker = (paragraph.attribute(.kernBulletMarker, at: 0, effectiveRange: nil) as? String)
                .flatMap { $0.first }
                .map(String.init) ?? "-"
            let normalizeBulletMarker = options.exportDialect == .gfm
                && !options.strictConformanceRoundTripMode
            let bulletMarker = normalizeBulletMarker ? "-" : storedMarker
            let storedPadding = (paragraph.attribute(.kernListMarkerPadding, at: 0, effectiveRange: nil) as? String) ?? " "
            let markerPadding = normalizeBulletMarker ? " " : storedPadding
            let text = exportInline(content)
            if style == .standalone, options.exportDialect == .kern {
                body = "[\(box)] " + text
            } else {
                body = "\(bulletMarker)\(markerPadding)[\(box)] " + text
            }
            softBreakKind = .task
        case .bullet:
            let storedMarker = (paragraph.attribute(.kernBulletMarker, at: 0, effectiveRange: nil) as? String)
                .flatMap { $0.first }
                .map(String.init) ?? "-"
            let normalizeBulletMarker = options.exportDialect == .gfm
                && !options.strictConformanceRoundTripMode
            let bulletMarker = normalizeBulletMarker ? "-" : storedMarker
            let storedPadding = (paragraph.attribute(.kernListMarkerPadding, at: 0, effectiveRange: nil) as? String) ?? " "
            let markerPadding = normalizeBulletMarker ? " " : storedPadding
            body = "\(bulletMarker)\(markerPadding)" + exportInline(content)
            softBreakKind = .bullet
        case .ordered:
            let n = (paragraph.attribute(.kernOrderedIndex, at: 0, effectiveRange: nil) as? Int) ?? 1
            let isTask = (paragraph.attribute(.kernOrderedIsTask, at: 0, effectiveRange: nil) as? Bool) ?? false
            let storedPadding = (paragraph.attribute(.kernListMarkerPadding, at: 0, effectiveRange: nil) as? String) ?? " "
            let normalizeMarkerPadding = options.exportDialect == .gfm && !options.strictConformanceRoundTripMode
            let markerPadding = normalizeMarkerPadding ? " " : storedPadding
            if isTask {
                let checked = findFirstCheckboxState(in: paragraph) ?? false
                switch (options.exportDialect, options.gfmExtensionExportStrategy) {
                case (.gfm, .portable):
                    let glyph = checked ? "\u{2611}" : "\u{2610}"
                    body = "\(max(0, n)).\(markerPadding)\(glyph) " + exportInline(content)
                    softBreakKind = .ordered
                case (.gfm, .lint):
                    let box = checked ? "x" : " "
                    body = "- [\(box)] \(max(0, n)). " + exportInline(content)
                    softBreakKind = .task
                default:
                    let box = checked ? "x" : " "
                    body = "\(max(0, n)).\(markerPadding)[\(box)] " + exportInline(content)
                    softBreakKind = .ordered
                }
            } else {
                body = "\(max(0, n)).\(markerPadding)" + exportInline(content)
                softBreakKind = .ordered
            }
        case .tableCell:
            // Tables are grouped by exportMarkdown(), but keep a best-effort fallback.
            body = exportInline(content)
            softBreakKind = .paragraph

        case .paragraph:
            if let rawKind = paragraph.attribute(.kernCalloutKind, at: 0, effectiveRange: nil) as? String,
               let calloutKind = KernCalloutKind(rawValue: rawKind) {
                let exported = exportInline(content)
                switch (options.exportDialect, options.gfmExtensionExportStrategy) {
                case (.gfm, .portable), (.gfm, .lint):
                    body = exported
                default:
                    let foldSuffix = paragraph.attribute(.kernCalloutFoldSuffix, at: 0, effectiveRange: nil) as? String
                    let marker = "[!\(calloutKind.markdownName)]\(foldSuffix ?? "")"
                    if exported.isEmpty {
                        body = marker
                    } else {
                        body = marker + " " + exported
                    }
                }
            } else {
                body = exportInline(content)
            }
            softBreakKind = .paragraph
        case .codeBlock:
            body = paraText
            softBreakKind = .codeBlock
        case .thematicBreak:
            let stored = (paragraph.attribute(.kernThematicBreakMarker, at: 0, effectiveRange: nil) as? String) ?? "---"
            if options.exportDialect == .gfm && !options.strictConformanceRoundTripMode {
                if stored == "---" || stored == "***" || stored == "___" {
                    body = stored
                } else {
                    body = "---"
                }
            } else {
                body = stored
            }
            softBreakKind = .paragraph
        }

        let listIndent = (paragraph.attribute(.kernListIndent, at: 0, effectiveRange: nil) as? Int) ?? 0
        let indentPrefix: String
        switch kind {
        case .bullet, .task, .ordered:
            indentPrefix = String(repeating: " ", count: max(0, listIndent))
        default:
            indentPrefix = ""
        }

        var out = serializeSoftLineBreaks(body: indentPrefix + body, kind: softBreakKind)
        if quoteDepth > 0 {
            let prefix = String(repeating: "> ", count: quoteDepth)
            let parts = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            out = parts.map { prefix + $0 }.joined(separator: "\n")
        }
        return out
    }

    private static func findFirstCheckboxState(in paragraph: NSAttributedString) -> Bool? {
        var found: Bool?
        paragraph.enumerateAttribute(.kernCheckbox, in: NSRange(location: 0, length: paragraph.length), options: []) { value, range, stop in
            guard (value as? Bool) == true else { return }
            let checked = (paragraph.attribute(.kernCheckboxChecked, at: range.location, effectiveRange: nil) as? Bool) ?? false
            found = checked
            stop.pointee = true
        }
        return found
    }

    private static func exportInline(_ attributed: NSAttributedString) -> String {
        // Serializer based on kern.* attributes with deterministic canonical markers.
        // Link runs are emitted as a single markdown link so styled labels don't fragment into
        // multiple adjacent links.
        var out = ""
        var current = InlineStyle()

        func closeStyle(_ prev: InlineStyle) {
            if prev.strike { out += "~~" }
            if prev.emphasis { out += "*" }
            if prev.strong { out += "**" }
        }

        let full = NSRange(location: 0, length: attributed.length)
        var index = 0
        while index < attributed.length {
            var range = NSRange(location: 0, length: 0)
            let attrs = attributed.attributes(at: index, longestEffectiveRange: &range, in: full)
            let text = stripStoragePlaceholders(attributed.attributedSubstring(from: range).string)

            if (attrs[.kernPlaceholder] as? Bool) == true, text.isEmpty {
                index = range.location + range.length
                continue
            }

            if (attrs[.kernHtmlLineBreak] as? Bool) == true {
                closeStyle(current)
                current = InlineStyle()

                let source = (attrs[.kernSourceMarkdown] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "<br />"
                let breakCount = max(1, text.unicodeScalars.filter { $0.value == 0x2028 || $0.value == 0x2029 || $0.value == 0x0A }.count)
                out += String(repeating: source, count: breakCount)
                index = range.location + range.length
                continue
            }

            if let source = attrs[.kernSourceMarkdown] as? String, !source.isEmpty {
                closeStyle(current)
                current = InlineStyle()

                var upperBound = range.location + range.length
                while upperBound < attributed.length {
                    var nextRange = NSRange(location: 0, length: 0)
                    let nextAttrs = attributed.attributes(at: upperBound, longestEffectiveRange: &nextRange, in: full)
                    let nextSource = nextAttrs[.kernSourceMarkdown] as? String
                    guard nextSource == source else { break }
                    upperBound = nextRange.location + nextRange.length
                }

                out += source
                index = upperBound
                continue
            }

            if attrs[.attachment] != nil {
                closeStyle(current)
                current = InlineStyle()
                out += text
                index = range.location + range.length
                continue
            }

            if let linkSignature = linkRunSignature(from: attrs) {
                closeStyle(current)
                current = InlineStyle()

                var upperBound = range.location + range.length
                while upperBound < attributed.length {
                    var nextRange = NSRange(location: 0, length: 0)
                    let nextAttrs = attributed.attributes(at: upperBound, longestEffectiveRange: &nextRange, in: full)
                    if let source = nextAttrs[.kernSourceMarkdown] as? String, !source.isEmpty { break }
                    if nextAttrs[.attachment] != nil { break }
                    guard let nextSignature = linkRunSignature(from: nextAttrs), nextSignature == linkSignature else {
                        break
                    }
                    upperBound = nextRange.location + nextRange.length
                }

                let linkRange = NSRange(location: range.location, length: upperBound - range.location)
                let linkAttributed = NSMutableAttributedString(attributedString: attributed.attributedSubstring(from: linkRange))
                let fullLinkRange = NSRange(location: 0, length: linkAttributed.length)
                linkAttributed.removeAttribute(.link, range: fullLinkRange)
                linkAttributed.removeAttribute(.kernLinkDestination, range: fullLinkRange)
                linkAttributed.removeAttribute(.kernLinkTitle, range: fullLinkRange)
                linkAttributed.removeAttribute(.kernLinkReferenceID, range: fullLinkRange)
                linkAttributed.removeAttribute(.kernLinkReferenceURL, range: fullLinkRange)
                linkAttributed.removeAttribute(.kernAutolink, range: fullLinkRange)

                if linkSignature.autolink {
                    out += "<\(attributed.attributedSubstring(from: linkRange).string)>"
                    index = upperBound
                    continue
                }

                let linkLabel = exportInline(linkAttributed)
                if let refID = linkSignature.referenceID, !refID.isEmpty {
                    out += "[\(linkLabel)][\(refID)]"
                    index = upperBound
                    continue
                }

                let destination = linkSignature.destination
                    .flatMap { $0.isEmpty ? nil : $0 } ?? (linkSignature.href ?? "")
                let titleSuffix = serializeLinkTitle(linkSignature.title)
                out += "[\(linkLabel)](\(serializeLinkDestination(destination))\(titleSuffix))"
                index = upperBound
                continue
            }

            if (attrs[.kernInlineCode] as? Bool) == true {
                closeStyle(current)
                current = InlineStyle()
                out += codeSpanMarkdown(for: text, precedingCharacter: out.last)
                index = range.location + range.length
                continue
            }

            let next = InlineStyle(
                strong: (attrs[.kernStrong] as? Bool) ?? false,
                emphasis: (attrs[.kernEmphasis] as? Bool) ?? false,
                strike: (attrs[.kernStrikethrough] as? Bool) ?? false
            )
            let isEscapedLiteral = (attrs[.kernEscapedLiteral] as? Bool) ?? false

            if current.strike && !next.strike { out += "~~" }
            if current.emphasis && !next.emphasis { out += "*" }
            if current.strong && !next.strong { out += "**" }

            if !current.strong && next.strong { out += "**" }
            if !current.emphasis && next.emphasis { out += "*" }
            if !current.strike && next.strike { out += "~~" }

            current = next
            if isEscapedLiteral {
                out += escapedLiteralMarkdown(text)
            } else {
                out += escapeInline(text)
            }
            index = range.location + range.length
        }

        closeStyle(current)
        return out
    }

    private struct LinkRunSignature: Equatable {
        let href: String?
        let destination: String?
        let title: String?
        let referenceID: String?
        let autolink: Bool
    }

    private static func linkRunSignature(from attrs: [NSAttributedString.Key: Any]) -> LinkRunSignature? {
        guard let rawLink = attrs[.link] else { return nil }

        let href: String?
        if let url = rawLink as? URL {
            href = url.absoluteString
        } else if let string = rawLink as? String {
            href = string
        } else {
            href = nil
        }

        return LinkRunSignature(
            href: href,
            destination: attrs[.kernLinkDestination] as? String,
            title: attrs[.kernLinkTitle] as? String,
            referenceID: attrs[.kernLinkReferenceID] as? String,
            autolink: (attrs[.kernAutolink] as? Bool) ?? false
        )
    }

    private static func serializeLinkDestination(_ destination: String) -> String {
        guard !destination.isEmpty else { return destination }
        let needsAngles =
            destination.contains(where: { isASCIISpace($0) })
            || destination.contains("<")
            || destination.contains(">")
            || hasUnescapedUnbalancedParens(destination)
        guard needsAngles else { return destination }
        let escaped = destination
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
        return "<\(escaped)>"
    }

    private static func hasUnescapedUnbalancedParens(_ destination: String) -> Bool {
        var depth = 0
        var escaped = false
        for ch in destination {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "(" {
                depth += 1
                continue
            }
            if ch == ")" {
                if depth == 0 {
                    return true
                }
                depth -= 1
            }
        }
        return depth != 0
    }

    private static func serializeLinkTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        if !title.contains("\"") {
            return " \"\(title)\""
        }
        if !title.contains("'") {
            return " '\(title)'"
        }
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        return " \"\(escaped)\""
    }

    private static func codeSpanMarkdown(for text: String, precedingCharacter: Character?) -> String {
        let chars = Array(text)
        var maxRun = 0
        var current = 0
        for ch in chars {
            if ch == "`" {
                current += 1
                maxRun = max(maxRun, current)
            } else {
                current = 0
            }
        }
        var fenceLength = max(1, maxRun + 1)
        if precedingCharacter == "`" {
            fenceLength = max(fenceLength, 2)
        }
        let fence = String(repeating: "`", count: fenceLength)

        var payload = text
        if let first = payload.first, let last = payload.last {
            let allSpaces = payload.allSatisfy { $0 == " " }
            if first == "`" || last == "`" || ((first == " " || last == " ") && !allSpaces) {
                payload = " " + payload + " "
            }
        }
        return "\(fence)\(payload)\(fence)"
    }

    private static func maxFenceRun(of marker: Character, in lines: [String]) -> Int {
        var longest = 0
        for line in lines {
            var current = 0
            for ch in line {
                if ch == marker {
                    current += 1
                    longest = max(longest, current)
                } else {
                    current = 0
                }
            }
        }
        return longest
    }

    private static func indexOf(_ needle: String, in chars: [Character], start: Int, limit: Int) -> Int? {
        guard !needle.isEmpty, start < limit else { return nil }
        let nChars = Array(needle)
        guard nChars.count <= limit - start else { return nil }

        var i = start
        while i <= limit - nChars.count {
            var matched = true
            for j in 0..<nChars.count where chars[i + j] != nChars[j] {
                matched = false
                break
            }
            if matched {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func serializeSoftLineBreaks(body: String, kind: KernBlockKind) -> String {
        // Convert U+2028 line separators (Shift+Enter) into Markdown hard breaks.
        // For list items, indent continuation lines so they stay within the same list item.
        let leadingSpaces = body.prefix { $0 == " " }.count
        let trimmed = body.dropFirst(leadingSpaces)

        let continuationIndent: String
        switch kind {
        case .bullet, .task:
            continuationIndent = String(repeating: " ", count: leadingSpaces + 2)
        case .ordered:
            let digitsCount = trimmed.prefix { $0.isNumber }.count
            let n = max(1, digitsCount)
            continuationIndent = String(repeating: " ", count: leadingSpaces + n + 2) // ". "
        case .heading, .paragraph, .tableCell, .codeBlock:
            continuationIndent = ""
        case .thematicBreak:
            continuationIndent = ""
        }

        func indentContinuationLines(_ text: String, indent: String) -> String {
            guard !indent.isEmpty, text.contains("\n") else { return text }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { return text }
            var out = lines[0]
            for line in lines.dropFirst() {
                out += "\n" + indent + line
            }
            return out
        }

        let out: String
        if body.contains("\u{2028}") || body.contains("\u{2029}") {
            let softListBreaksAsNewline: Bool
            switch kind {
            case .bullet, .task, .ordered:
                softListBreaksAsNewline = true
            default:
                softListBreaksAsNewline = false
            }

            var value = ""
            value.reserveCapacity(body.count + 16)
            for scalar in body.unicodeScalars {
                switch scalar.value {
                case 0x2028:
                    value += softListBreaksAsNewline ? "\n" : "\\\n"
                case 0x2029:
                    value += "\\\n"
                default:
                    value.unicodeScalars.append(scalar)
                }
            }
            out = value
        } else {
            out = body
        }
        return indentContinuationLines(out, indent: continuationIndent)
    }

    // MARK: - Soft Break Import Helpers

    /// In Markdown, a trailing `\` at end-of-line is a hard line break. We use this as the on-disk
    /// representation for an in-editor U+2028 (Shift+Enter) soft break.
    private enum HardBreakMarker {
        case backslash
        case spaces(Int)
        case tab
    }

    private enum ContinuationJoinKind {
        case paragraph
        case list
    }

    private struct ContinuationTextBuilder {
        private let kind: ContinuationJoinKind
        private var buffer: String
        private var containsInlineSyntax: Bool

        init(initial: String, kind: ContinuationJoinKind) {
            self.kind = kind
            buffer = initial
            buffer.reserveCapacity(max(initial.utf16.count + 32, initial.utf16.count))
            containsInlineSyntax = NativeMarkdownCodec.containsInlineSyntax(in: initial)
        }

        mutating func append(_ nextText: String, pendingHardBreak: HardBreakMarker?) {
            switch kind {
            case .paragraph:
                buffer.append(pendingHardBreak != nil ? "\u{2028}" : "\n")
            case .list:
                if let pendingHardBreak {
                    let hardBreakLiteral = NativeMarkdownCodec.hardBreakLiteral(pendingHardBreak)
                    if !containsInlineSyntax, NativeMarkdownCodec.containsInlineSyntax(in: hardBreakLiteral) {
                        containsInlineSyntax = true
                    }
                    buffer.append(hardBreakLiteral)
                }
                buffer.append("\u{2028}")
            }
            buffer.append(nextText)
            if !containsInlineSyntax, NativeMarkdownCodec.containsInlineSyntax(in: nextText) {
                containsInlineSyntax = true
            }
        }

        mutating func build(finalHardBreak: HardBreakMarker?) -> (text: String, containsInlineSyntax: Bool) {
            if let finalHardBreak {
                let hardBreakLiteral = NativeMarkdownCodec.hardBreakLiteral(finalHardBreak)
                if !containsInlineSyntax, NativeMarkdownCodec.containsInlineSyntax(in: hardBreakLiteral) {
                    containsInlineSyntax = true
                }
                buffer.append(hardBreakLiteral)
            }
            return (buffer, containsInlineSyntax)
        }
    }

    private static func hasOddBacktickParity(_ text: String) -> Bool {
        var odd = false
        for ch in text where ch == "`" {
            odd.toggle()
        }
        return odd
    }

    private static func stripHardBreakMarker(_ text: String, ctx: ImportContext) -> (text: String, hardBreak: HardBreakMarker?) {
        if ctx.strictConformanceRoundTripMode {
            return (text, nil)
        }
        if text.hasSuffix("\\") {
            if hasOddBacktickParity(text) {
                return (text, nil)
            }
            return (String(text.dropLast()), .backslash)
        }
        if text.hasSuffix("\t") {
            if hasOddBacktickParity(text) {
                return (text, nil)
            }
            return (String(text.dropLast()), .tab)
        }
        var trailingSpaces = 0
        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            guard text[prev] == " " else { break }
            trailingSpaces += 1
            idx = prev
        }
        if trailingSpaces >= 2 {
            if hasOddBacktickParity(text) {
                return (text, nil)
            }
            return (String(text[..<idx]), .spaces(trailingSpaces))
        }
        return (text, nil)
    }

    private static func hardBreakLiteral(_ marker: HardBreakMarker) -> String {
        switch marker {
        case .backslash:
            return "\\"
        case .spaces(let count):
            return String(repeating: " ", count: max(2, count))
        case .tab:
            return "\t"
        }
    }

    private static func escapeInline(_ text: String) -> String {
        // Preserve literal punctuation as typed; aggressively escaping `*`, `_`, and backticks
        // causes strict Markdown conformance regressions and semantic drift.
        // Deliberately escaped punctuation is emitted via `escapedLiteralMarkdown`.
        //
        // Keep a single trailing backslash before U+2028 so list hard-break markers imported from
        // Markdown (`line\\` + continuation) don't inflate to `\\` on export.
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count * 2)
        for i in chars.indices {
            let ch = chars[i]
            if ch == "\\" {
                let next = (i + 1 < chars.count) ? chars[i + 1] : nil
                if next == "\u{2028}" {
                    out.append("\\")
                } else {
                    out.append("\\\\")
                }
                continue
            }
            out.append(ch)
        }
        return out
    }

    private static func stripStoragePlaceholders(_ text: String) -> String {
        text.replacingOccurrences(of: String(storagePlaceholderCharacter), with: "")
    }

    private static let storagePlaceholderCharacter: Character = "\u{200B}"

    private static func escapedLiteralMarkdown(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count * 2)
        for ch in text {
            if isMarkdownEscapable(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    private static func normalizedLinkURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed) {
            return url
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }

    private static func inlineLinkValue(from raw: String, baseURL: URL?) -> InlineLinkValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let resolved = resolvedLinkURL(from: trimmed, baseURL: baseURL) {
            return .url(resolved)
        }
        guard normalizedLinkURL(from: trimmed) != nil else { return nil }
        return .raw(trimmed)
    }

    private static func resolvedLinkURL(from raw: String, baseURL: URL?) -> URL? {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = normalizedLinkURL(from: trimmedRaw) else { return nil }
        if let scheme = parsed.scheme {
            let lowercasedScheme = scheme.lowercased()
            switch lowercasedScheme {
            case "http", "https", "mailto":
                return parsed
            case "file":
                return nil
            default:
                return nil
            }
        }

        // Preserve pure fragment links for in-document anchor handling.
        if parsed.path.isEmpty {
            return parsed
        }

        if let normalizedWebURL = normalizedBareWebURL(from: trimmedRaw) {
            return normalizedWebURL
        }

        guard !parsed.path.hasPrefix("/"), !parsed.path.hasPrefix("~/") else { return nil }
        guard let baseURL else { return nil }

        if baseURL.isFileURL {
            guard let baseDirectory = trustedLinkBaseDirectory(baseURL: baseURL) else { return nil }
            let resolved = URL(fileURLWithPath: parsed.path, relativeTo: baseDirectory).standardizedFileURL
            guard isContainedWithinTrustedLinkBase(resolved, baseDirectory: baseDirectory) else { return nil }
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            components?.query = parsed.query
            components?.fragment = parsed.fragment
            return components?.url
        }

        guard let resolved = URL(string: trimmedRaw, relativeTo: baseURL)?.absoluteURL else { return nil }
        return resolved
    }

    private static func trustedLinkBaseDirectory(baseURL: URL?) -> URL? {
        guard let baseURL, baseURL.isFileURL else { return nil }
        return baseURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func isContainedWithinTrustedLinkBase(_ url: URL, baseDirectory: URL) -> Bool {
        let urlPath = resolvedTrustedLocalPath(url)
        let basePath = resolvedTrustedLocalPath(baseDirectory)
        return urlPath == basePath || urlPath.hasPrefix(basePath + "/")
    }

    private static func resolvedTrustedLocalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedBareWebURL(from raw: String) -> URL? {
        guard looksLikeBareWebDestination(raw) else { return nil }
        guard !raw.lowercased().hasPrefix("http://"), !raw.lowercased().hasPrefix("https://") else { return nil }
        return URL(string: "https://\(raw)")
    }

    private static func looksLikeBareWebDestination(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard !value.hasPrefix("#"),
              !value.hasPrefix("/"),
              !value.hasPrefix("./"),
              !value.hasPrefix("../"),
              !value.hasPrefix("~/") else {
            return false
        }
        guard !value.contains(" ") else { return false }

        if value.lowercased().hasPrefix("localhost") {
            return true
        }

        let hostPort = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let host = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostPort
        guard !host.isEmpty else { return false }

        // IPv4 host.
        let octets = host.split(separator: ".")
        if octets.count == 4,
           octets.allSatisfy({ part in
               guard let n = Int(part), !part.isEmpty else { return false }
               return (0...255).contains(n)
           }) {
            return true
        }

        // Basic domain host.
        guard host.contains(".") else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return false }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static let markdownEscapablePunctuation: CharacterSet = CharacterSet(
        charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
    )

    private static func isMarkdownEscapable(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first, scalar.isASCII else {
            return false
        }
        return markdownEscapablePunctuation.contains(scalar)
    }

    private static func unescapeMarkdownBackslashes(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0

        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, isMarkdownEscapable(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
