import AppKit

/// Minimal Markdown <-> attributed string codec for the native editor prototype.
///
/// This is intentionally a prototype:
/// - It round-trips a small Markdown subset deterministically.
/// - It encodes semantics with custom attributes (kern.*) so export is reliable.
/// - It does not aim for full CommonMark/GFM compliance yet.
@MainActor
enum NativeMarkdownCodec {
    private struct ReferenceDefinition {
        let id: String
        let destination: String
        let title: String?
    }

    /// Import-time reference definitions used by inline parsing (`[text][id]`, `![alt][id]`).
    private static var activeReferenceDefinitions: [String: ReferenceDefinition] = [:]
    private static var activeImportBaseURL: URL?
    private static var activeImportOptions: Options = .init()
    private static var activeStrictConformanceRoundTripMode: Bool = false

    struct Options: Equatable {
        enum ExportDialect: String {
            case gfm
            case kern
        }

        enum GfmExtensionExportStrategy: String {
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

        enum TaskRendering: String {
            /// Checkbox-only task rendering (GitHub-like).
            case gfm
            /// Bulleted task items render as bullet dot + checkbox (`• ☐ ...`).
            case kern
        }

        enum OrderedListNumbering: String {
            /// Preserve the typed numeric markers on import and export.
            case preserveTyped
            /// Follow GFM semantics: only the first marker matters; subsequent items may be normalized.
            case gfmDefault
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
        var remoteImageLoadingEnabled: Bool = true
        /// Strict round-trip mode for spec conformance harnesses.
        /// This keeps inline source literals intact and disables marker rewrites that can
        /// otherwise alter semantics in edge-case CommonMark examples.
        var strictConformanceRoundTripMode: Bool = false

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
            return opt
        }
    }

    static func importMarkdown(_ markdown: String, options: Options = Options(), baseURL: URL? = nil) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 16)
        let inputEndsWithNewline = markdown.hasSuffix("\n")
        let result = NSMutableAttributedString()

        // Preserve empty lines by splitting with omittingEmptySubsequences=false.
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var referenceDefinitions: [String: ReferenceDefinition] = [:]
        for raw in lines {
            if let def = parseReferenceDefinition(raw) {
                referenceDefinitions[def.id.lowercased()] = def
            } else {
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
        }
        activeReferenceDefinitions = referenceDefinitions
        activeImportBaseURL = baseURL
        activeImportOptions = options
        activeStrictConformanceRoundTripMode = options.strictConformanceRoundTripMode
        defer {
            activeReferenceDefinitions.removeAll(keepingCapacity: false)
            activeImportBaseURL = nil
            activeImportOptions = .init()
            activeStrictConformanceRoundTripMode = false
        }

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
        var tableCounter = 0
        var codeBlockCounter = 0

        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let quote = parseBlockquotePrefix(rawLine)
            let quoteDepth = quote?.depth ?? 0
            let line = quote?.text ?? rawLine
            let isBlankLine = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i += 1
                continue
            }

            // Reference definition: [id]: url "title"
            if let definition = parseReferenceDefinition(line) {
                resetOrderedCounters()
                let visible = definition.destination
                let para = NSMutableAttributedString(attributedString: parseInline(visible, baseFont: baseFont))
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i += 1
                continue
            }

            // Math block: $$ ... $$
            if isMathBlockDelimiter(line) {
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
                    attributedString: makeBlockMathAttributed(sourceMarkdown: sourceMarkdown, baseFont: baseFont)
                )
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                continue
            }

            // Code block (```lang ... ``` / ~~~lang ... ~~~)
            if let fenceContext = parseFenceStartInContext(line: line, lines: lines, index: i, quoteDepth: quoteDepth) {
                resetOrderedCounters()
                let blockStartIndex = i
                let fence = fenceContext.fence
                let listIndent = fenceContext.listIndent
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    var nextLine = lines[i]
                    if quoteDepth > 0 {
                        guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                        nextLine = q.text
                    }
                    if listIndent > 0 {
                        let prefix = String(repeating: " ", count: listIndent)
                        if nextLine.hasPrefix(prefix) {
                            nextLine = String(nextLine.dropFirst(prefix.count))
                        } else if !nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            break
                        }
                    }
                    if isFenceEnd(nextLine, fence: fence) {
                        break
                    }
                    codeLines.append(stripFenceIndent(nextLine, indent: fence.indent))
                    i += 1
                }
                // Skip closing fence if present
                if i < lines.count {
                    var endLine = lines[i]
                    if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                        endLine = q.text
                    }
                    if listIndent > 0 {
                        let prefix = String(repeating: " ", count: listIndent)
                        if endLine.hasPrefix(prefix) {
                            endLine = String(endLine.dropFirst(prefix.count))
                        }
                    }
                    if isFenceEnd(endLine, fence: fence) {
                        i += 1
                    }
                }

                let codeText = codeLines.joined(separator: "\n")
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
                        attributedString: makeMermaidAttachmentAttributed(sourceMarkdown: mermaidSourceMarkdown, baseFont: baseFont)
                    )
                    if let strictBlockSourceMarkdown, mermaidAttr.length > 0 {
                        mermaidAttr.addAttribute(.kernSourceMarkdown, value: strictBlockSourceMarkdown, range: NSRange(location: 0, length: mermaidAttr.length))
                    }
                    applyQuoteAttributes(mermaidAttr, quoteDepth: quoteDepth)
                    result.append(mermaidAttr)
                    appendedBlockEndsWithNewline = mermaidAttr.string.hasSuffix("\n")
                } else {
                    let codeAttr = NSMutableAttributedString(attributedString: makeCodeBlockAttributed(codeText, baseFont: baseFont, language: fence.language))
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                continue
            }

            // Indented code block (CommonMark): 4-space/tab-indented lines.
            // It must not interrupt an open paragraph (e.g. `Foo` + `    bar`).
            if canStartIndentedCode(lines, at: i, quoteDepth: quoteDepth),
               let indented = parseIndentedCodeBlock(lines, startIndex: i, quoteDepth: quoteDepth) {
                resetOrderedCounters()
                let blockStartIndex = i
                let codeText = indented.codeLines.joined(separator: "\n")
                let codeAttr = NSMutableAttributedString(attributedString: makeCodeBlockAttributed(codeText, baseFont: baseFont, language: nil))
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                continue
            }

            // GFM table
            if let match = parseGfmTable(lines, startIndex: i) {
                resetOrderedCounters()
                tableCounter += 1
                let tableID = tableCounter

                // Preserve trailing newline behavior at end-of-file.
                let terminateLastParagraph = !(match.endIndex == lines.count && !inputEndsWithNewline)

                let tableAttr = makeGfmTableAttributed(
                    match.table,
                    tableID: tableID,
                    baseFont: baseFont,
                    terminateLastParagraph: terminateLastParagraph
                )
                result.append(tableAttr)
                i = match.endIndex
                continue
            }

            // Thematic break (horizontal rule)
            if let marker = parseThematicBreak(line) {
                resetOrderedCounters()
                let para = NSMutableAttributedString(attributedString: makeThematicBreakAttributed(baseFont: baseFont, marker: marker))
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i += 1
                continue
            }

            // Heading
            if let heading = parseHeading(line) {
                resetOrderedCounters()
                // Kern extension: checkbox headings like `## [ ] Heading`.
                if options.headingCheckboxesEnabled, let headingTask = parseHeadingCheckbox(heading.text) {
                    let para = NSMutableAttributedString(attributedString: makeHeadingWithCheckbox(
                        level: heading.level,
                        checked: headingTask.checked,
                        text: headingTask.text,
                        baseFont: baseFont
                    ))
                    applyQuoteAttributes(para, quoteDepth: quoteDepth)
                    result.append(para)
                    if i < lines.count - 1 {
                        result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                    }
                    i += 1
                    continue
                }

                let content = parseInline(heading.text, baseFont: baseFont)
                let para = NSMutableAttributedString(attributedString: content)
                if para.length == 0 {
                    let placeholder = NSAttributedString(
                        string: String(storagePlaceholderCharacter),
                        attributes: baseAttributes(baseFont: baseFont)
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i += 1
                continue
            }

            // Setext heading:
            //   Heading text
            //   ========   /   --------
            if let setext = parseSetextHeading(lines, startIndex: i, quoteDepth: quoteDepth, options: options) {
                resetOrderedCounters()
                let content = parseInline(setext.text, baseFont: baseFont)
                let para = NSMutableAttributedString(attributedString: content)
                if para.length == 0 {
                    let placeholder = NSAttributedString(
                        string: String(storagePlaceholderCharacter),
                        attributes: baseAttributes(baseFont: baseFont)
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                continue
            }

            // Bullet/standalone task: - [ ] text / * [ ] text / + [ ] text / [] text / [ ] text
            if let task = parseTask(line) {
                resetOrderedCounters()
                var (combined, pendingHardBreak) = stripHardBreakMarker(task.text)
                let markerWidth: Int
                switch task.style {
                case .bulleted:
                    markerWidth = 1 + max(1, task.markerPadding.count)
                case .standalone:
                    // `[ ] ` marker width for continuation alignment.
                    markerWidth = 4
                }
                let continuationIndent = String(repeating: " ", count: task.indent + markerWidth)

                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    guard next.hasPrefix(continuationIndent) else { break }
                    let stripped = String(next.dropFirst(continuationIndent.count))

                    // If the next line starts a nested list item (or another block), don't treat it
                    // as a continuation of this item's text.
                    if parseTask(stripped) != nil
                        || (options.orderedTasksEnabled && parseOrderedTask(stripped) != nil)
                        || parseOrdered(stripped) != nil
                        || parseBullet(stripped) != nil
                        || parseHeading(stripped) != nil
                        || parseFenceStart(stripped) != nil
                        || stripped.hasPrefix("    ")
                        || stripped.hasPrefix("\t")
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    if let marker = pendingHardBreak {
                        combined += hardBreakLiteral(marker)
                    }
                    combined += "\u{2028}" + nextText
                    pendingHardBreak = nextHardBreak
                    j += 1
                }
                if let marker = pendingHardBreak {
                    combined += hardBreakLiteral(marker)
                }

                let para = NSMutableAttributedString(attributedString: makeTaskParagraph(
                    (task.style, task.marker, task.markerPadding, task.checked, combined),
                    indent: task.indent,
                    depth: task.depth,
                    baseFont: baseFont,
                    options: options
                ))
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                continue
            }

            // Ordered task (Kern preference): 1. [ ] text
            if options.orderedTasksEnabled, let orderedTask = parseOrderedTask(line) {
                // Ordered tasks are a Kern option; keep them from affecting GFM ordered-list numbering.
                if options.orderedListNumbering == .gfmDefault {
                    resetOrderedCounters()
                }

                var (combined, pendingHardBreak) = stripHardBreakMarker(orderedTask.text)
                let continuationIndent = String(repeating: " ", count: orderedTask.indent + orderedTask.markerLen)
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    guard next.hasPrefix(continuationIndent) else { break }
                    let stripped = String(next.dropFirst(continuationIndent.count))

                    if parseTask(stripped) != nil
                        || (options.orderedTasksEnabled && parseOrderedTask(stripped) != nil)
                        || parseOrdered(stripped) != nil
                        || parseBullet(stripped) != nil
                        || parseHeading(stripped) != nil
                        || parseFenceStart(stripped) != nil
                        || stripped.hasPrefix("    ")
                        || stripped.hasPrefix("\t")
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    if let marker = pendingHardBreak {
                        combined += hardBreakLiteral(marker)
                    }
                    combined += "\u{2028}" + nextText
                    pendingHardBreak = nextHardBreak
                    j += 1
                }
                if let marker = pendingHardBreak {
                    combined += hardBreakLiteral(marker)
                }

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
                    baseFont: baseFont
                ))
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                if options.orderedListNumbering == .gfmDefault {
                    resetOrderedCounters()
                }
                continue
            }

            // When the ordered-task option is disabled, keep the ordered-task syntax as literal text.
            // This avoids implicitly opting into non-standard Markdown behavior in the default GFM profile.
            if !options.orderedTasksEnabled, parseOrderedTask(line) != nil {
                resetOrderedCounters()
                let para = NSMutableAttributedString(attributedString: parseInline(line, baseFont: baseFont))
                applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i += 1
                continue
            }

            // Ordered list item whose content starts with a fenced code block (`1. ````).
            if let ordered = parseOrdered(line), let inlineFence = parseFenceStart(ordered.text) {
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
                    baseFont: baseFont
                ))
                applyQuoteAttributes(markerPara, quoteDepth: quoteDepth)
                result.append(markerPara)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }

                let listIndent = ordered.indent + ordered.markerLen
                var codeLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    var nextLine = lines[j]
                    if quoteDepth > 0 {
                        guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                        nextLine = q.text
                    }
                    if listIndent > 0 {
                        let prefix = String(repeating: " ", count: listIndent)
                        if nextLine.hasPrefix(prefix) {
                            nextLine = String(nextLine.dropFirst(prefix.count))
                        } else if !nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            break
                        }
                    }
                    if isFenceEnd(nextLine, fence: inlineFence) {
                        break
                    }
                    codeLines.append(stripFenceIndent(nextLine, indent: inlineFence.indent))
                    j += 1
                }
                if j < lines.count {
                    var endLine = lines[j]
                    if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                        endLine = q.text
                    }
                    if listIndent > 0 {
                        let prefix = String(repeating: " ", count: listIndent)
                        if endLine.hasPrefix(prefix) {
                            endLine = String(endLine.dropFirst(prefix.count))
                        }
                    }
                    if isFenceEnd(endLine, fence: inlineFence) {
                        j += 1
                    }
                }

                let codeText = codeLines.joined(separator: "\n")
                let codeAttr = NSMutableAttributedString(attributedString: makeCodeBlockAttributed(codeText, baseFont: baseFont, language: inlineFence.language))
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                continue
            }

            // Ordered list: 1. text
            if let ordered = parseOrdered(line) {
                var (combined, pendingHardBreak) = stripHardBreakMarker(ordered.text)
                let continuationIndent = String(repeating: " ", count: ordered.indent + ordered.markerLen)
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    guard next.hasPrefix(continuationIndent) else { break }
                    let stripped = String(next.dropFirst(continuationIndent.count))

                    if parseTask(stripped) != nil
                        || (options.orderedTasksEnabled && parseOrderedTask(stripped) != nil)
                        || parseOrdered(stripped) != nil
                        || parseBullet(stripped) != nil
                        || parseHeading(stripped) != nil
                        || parseFenceStart(stripped) != nil
                        || stripped.hasPrefix("    ")
                        || stripped.hasPrefix("\t")
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    if let marker = pendingHardBreak {
                        combined += hardBreakLiteral(marker)
                    }
                    combined += "\u{2028}" + nextText
                    pendingHardBreak = nextHardBreak
                    j += 1
                }
                if let marker = pendingHardBreak {
                    combined += hardBreakLiteral(marker)
                }

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
                    baseFont: baseFont
                ))
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                continue
            }

            // Bullet list item whose content starts with a fenced code block (`- ````).
            if let bullet = parseBullet(line), let inlineFence = parseFenceStart(bullet.text) {
                resetOrderedCounters()

                let markerPara = NSMutableAttributedString(
                    attributedString: makeBulletParagraph("", marker: bullet.marker, markerPadding: bullet.markerPadding, indent: bullet.indent, depth: bullet.depth, baseFont: baseFont)
                )
                applyQuoteAttributes(markerPara, quoteDepth: quoteDepth)
                result.append(markerPara)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }

                let listIndent = bullet.indent + 1 + max(1, bullet.markerPadding.count)
                var codeLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    var nextLine = lines[j]
                    if quoteDepth > 0 {
                        guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                        nextLine = q.text
                    }
                    if listIndent > 0 {
                        let prefix = String(repeating: " ", count: listIndent)
                        if nextLine.hasPrefix(prefix) {
                            nextLine = String(nextLine.dropFirst(prefix.count))
                        } else if !nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            break
                        }
                    }
                    if isFenceEnd(nextLine, fence: inlineFence) {
                        break
                    }
                    codeLines.append(stripFenceIndent(nextLine, indent: inlineFence.indent))
                    j += 1
                }
                if j < lines.count {
                    var endLine = lines[j]
                    if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                        endLine = q.text
                    }
                    if listIndent > 0 {
                        let prefix = String(repeating: " ", count: listIndent)
                        if endLine.hasPrefix(prefix) {
                            endLine = String(endLine.dropFirst(prefix.count))
                        }
                    }
                    if isFenceEnd(endLine, fence: inlineFence) {
                        j += 1
                    }
                }

                let codeText = codeLines.joined(separator: "\n")
                let codeAttr = NSMutableAttributedString(attributedString: makeCodeBlockAttributed(codeText, baseFont: baseFont, language: inlineFence.language))
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
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                continue
            }

            // Bullet list: - text
            if let bullet = parseBullet(line) {
                resetOrderedCounters()
                var (combined, pendingHardBreak) = stripHardBreakMarker(bullet.text)
                let continuationIndent = String(repeating: " ", count: bullet.indent + 1 + max(1, bullet.markerPadding.count))
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    guard next.hasPrefix(continuationIndent) else { break }
                    let stripped = String(next.dropFirst(continuationIndent.count))

                    if parseTask(stripped) != nil
                        || (options.orderedTasksEnabled && parseOrderedTask(stripped) != nil)
                        || parseOrdered(stripped) != nil
                        || parseBullet(stripped) != nil
                        || parseHeading(stripped) != nil
                        || parseFenceStart(stripped) != nil
                        || stripped.hasPrefix("    ")
                        || stripped.hasPrefix("\t")
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    if let marker = pendingHardBreak {
                        combined += hardBreakLiteral(marker)
                    }
                    combined += "\u{2028}" + nextText
                    pendingHardBreak = nextHardBreak
                    j += 1
                }
                if let marker = pendingHardBreak {
                    combined += hardBreakLiteral(marker)
                }

                let para = NSMutableAttributedString(
                    attributedString: makeBulletParagraph(combined, marker: bullet.marker, markerPadding: bullet.markerPadding, indent: bullet.indent, depth: bullet.depth, baseFont: baseFont)
                )
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                continue
            }

            // Plain paragraph (including empty line)
            resetOrderedCounters()
            var (combined, pendingHardBreak) = stripHardBreakMarker(line)
            var j = i + 1
            while j < lines.count {
                var nextLine = lines[j]
                if quoteDepth > 0 {
                    // Keep nested blockquote levels structurally separate. Collapsing deeper quote
                    // levels into the current paragraph flattens `> >`/`> > >` runs on export.
                    guard let q = parseBlockquotePrefix(nextLine), q.depth == quoteDepth else { break }
                    nextLine = q.text
                }

                if nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }

                // Stop at the next block boundary.
                if parseReferenceDefinition(nextLine) != nil
                    || isMathBlockDelimiter(nextLine)
                    || parseFenceStart(nextLine) != nil
                    || parseHeading(nextLine) != nil
                    || parseTask(nextLine) != nil
                    || (options.orderedTasksEnabled && parseOrderedTask(nextLine) != nil)
                    || parseOrdered(nextLine) != nil
                    || parseBullet(nextLine) != nil
                    || parseThematicBreak(nextLine) != nil
                    || parseSetextUnderline(nextLine) != nil
                    || parseGfmTable(lines, startIndex: j) != nil
                    || (canStartIndentedCode(lines, at: j, quoteDepth: quoteDepth)
                        && parseIndentedCodeBlock(lines, startIndex: j, quoteDepth: quoteDepth) != nil)
                {
                    break
                }

                let (nextText, nextHardBreak) = stripHardBreakMarker(nextLine)
                combined += (pendingHardBreak != nil ? "\u{2028}" : " ") + nextText
                pendingHardBreak = nextHardBreak
                j += 1
            }
            if let marker = pendingHardBreak {
                combined += hardBreakLiteral(marker)
            }

            let para = NSMutableAttributedString(attributedString: parseInline(combined, baseFont: baseFont))
            applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
            applyQuoteAttributes(para, quoteDepth: quoteDepth)
            result.append(para)
            if j - 1 < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
            }
            i = j
        }

        return result
    }

    static func exportMarkdown(_ attributed: NSAttributedString, options: Options = Options()) -> String {
        let ns = attributed.string as NSString
        var outBlocks: [String] = []

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
                outBlocks.append("")
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

                    outBlocks.append(out)
                    idx = j
                    continue
                }
            }

            if kind == .tableCell {
                let tableID = (para.attribute(.kernTableID, at: 0, effectiveRange: nil) as? Int) ?? -1
                let exported = exportGfmTableBlock(attributed, ns: ns, startIndex: idx, tableID: tableID)
                outBlocks.append(exported.block)
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
                    outBlocks.append(source)
                    idx = j
                    continue
                }

                // Group consecutive codeBlock paragraphs into a single fenced block.
                var rawCodeText = ""
                var j = idx

                // Language extraction.
                // Prefer kern.* attribute (reliable), fall back to the historical tooltip stash.
                var language: String?
                if let lang = para.attribute(.kernCodeLanguage, at: 0, effectiveRange: nil) as? String,
                   !lang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    language = lang.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let tip = para.attribute(.toolTip, at: 0, effectiveRange: nil) as? String,
                          tip.hasPrefix("```") {
                    let lang = tip.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    language = lang.isEmpty ? nil : String(lang)
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
                    outBlocks.append(blockLines.joined(separator: "\n"))
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
                let openFence = markerString + (language.map { "\($0)" } ?? "")
                var blockLines = [openFence] + codeLines + [markerString]
                var collapsedListMarker: String?
                if quoteDepth == 0, listIndent > 0, let last = outBlocks.last, isMarkerOnlyListLine(last) {
                    collapsedListMarker = outBlocks.removeLast()
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
                outBlocks.append(blockLines.joined(separator: "\n"))
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
                    outBlocks.append(String(repeating: "> ", count: quoteDepth) + marker)
                } else {
                    outBlocks.append(marker)
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
                            outBlocks[blockIndex] += "\n" + continuationLine
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
                        outBlocks.append(line)
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
                    outBlocks.append(line)
                    j = r.location + r.length
                }

                idx = j
                continue
            }

            let line = exportParagraph(para, options: options)
            outBlocks.append(line)
            idx = paraRange.location + paraRange.length
        }

        // Preserve trailing newline if the attributed string ends with one.
        let endsWithNewline = attributed.string.hasSuffix("\n")
        var joined = outBlocks.joined(separator: "\n")
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

    private enum TableColumnAlignment: Int {
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

    private static let tableHeaderBackgroundColor: NSColor = {
        NSColor(name: NSColor.Name("kern.tableHeaderBackground")) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            if match == .darkAqua {
                return NSColor(white: 1, alpha: 0.07)
            }
            return NSColor(white: 0, alpha: 0.04)
        }
    }()

    /// Optional debug logging for table parsing. Evaluate once to avoid per-line env lookups.
    private static let debugTableParseEnabled: Bool = {
        ProcessInfo.processInfo.environment["KERN_DEBUG_TABLE_PARSE"] == "1"
    }()

    private static func parseGfmTable(_ lines: [String], startIndex: Int) -> GfmTableMatch? {
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

    private static func makeGfmTableAttributed(_ table: GfmTable, tableID: Int, baseFont: NSFont, terminateLastParagraph: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let textTable = NSTextTable()
        textTable.numberOfColumns = max(1, table.columnCount)
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setContentWidth(100, type: .percentageValueType)

        let headerFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)

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
                    terminatesParagraph: terminates
                )
                out.append(cellPara)
            }
        }

        return out
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
        terminatesParagraph: Bool
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()

        para.append(parseInline(text, baseFont: baseFont))

        if terminatesParagraph {
            para.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
        }

        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.verticalAlignment = .topAlignment
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        if isHeader {
            block.backgroundColor = tableHeaderBackgroundColor
        }

        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 0
        style.alignment = alignment.textAlignment

        let full = NSRange(location: 0, length: para.length)
        para.addAttribute(.paragraphStyle, value: style, range: full)
        para.addAttribute(.kernBlockKind, value: KernBlockKind.tableCell.rawValue, range: full)
        para.addAttribute(.kernTableID, value: tableID, range: full)
        para.addAttribute(.kernTableRow, value: row, range: full)
        para.addAttribute(.kernTableColumn, value: column, range: full)
        para.addAttribute(.kernTableIsHeader, value: isHeader, range: full)
        para.addAttribute(.kernTableColumnAlignment, value: alignment.rawValue, range: full)
        para.addAttribute(.kernTableColumnCount, value: columnCount, range: full)

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

    private struct FenceStart {
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
        if let ctx = previousListContinuationContext(lines, before: index, quoteDepth: quoteDepth) {
            let prefix = String(repeating: " ", count: max(0, ctx.indent))
            if line.hasPrefix(prefix) {
                let stripped = String(line.dropFirst(prefix.count))
                if let fence = parseFenceStart(stripped) {
                    return FenceContext(fence: fence, listIndent: ctx.indent)
                }
            }
        }
        if let fence = parseFenceStart(line) {
            return FenceContext(fence: fence, listIndent: 0)
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
        if rest.isEmpty { return FenceStart(language: nil, marker: marker, length: count, indent: indent) }
        if marker == "`", rest.contains("`") {
            // CommonMark: backtick-fenced info strings cannot contain backticks.
            return nil
        }
        // CommonMark info string can include metadata after the language token.
        // Use only the first token for UI language pills and syntax highlighting.
        let firstToken = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        let language = firstToken.map(String.init) ?? rest
        return FenceStart(language: language, marker: marker, length: count, indent: indent)
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

        let pattern = #"^\[([^\]]+)\]:\s*(\S+)(?:\s+["']([^"']+)["'])?\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
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
        if let marker = rest.first, ["-", "*", "+"].contains(marker) {
            let afterMarker = rest.dropFirst()
            guard let ws = afterMarker.first, ws == " " || ws == "\t" else { /* not a list marker */ return nil }
            let padding = String(afterMarker.prefix(while: { $0 == " " || $0 == "\t" }))
            let afterWS = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
            guard afterWS.hasPrefix("["), afterWS.count >= 3 else { return nil }
            let chars = Array(afterWS)
            guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
            let checkedChar = chars[1]
            let checked = checkedChar == "x" || checkedChar == "X"
            // Allow empty task text (`- [ ]`), otherwise require whitespace after closing bracket.
            if chars.count > 3, chars[3] != " ", chars[3] != "\t" {
                return nil
            }
            let text = chars.count > 3
                ? String(afterWS.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                : ""
            let depth = indent / 2
            return (indent, depth, .bulleted, marker, padding, checked, text)
        }

        // Shortcut: "[] " / "[ ] " / "[x] "
        let trimmed = String(rest)
        if trimmed.hasPrefix("[] ") {
            let text = String(trimmed.dropFirst(3))
            return (indent, 0, .standalone, nil, "", false, text)
        }
        if trimmed.hasPrefix("[ ] ") {
            let text = String(trimmed.dropFirst(4))
            return (indent, 0, .standalone, nil, "", false, text)
        }
        if trimmed.hasPrefix("[x] ") || trimmed.hasPrefix("[X] ") {
            let text = String(trimmed.dropFirst(4))
            return (indent, 0, .standalone, nil, "", true, text)
        }

        return nil
    }

    private static func parseBullet(_ line: String) -> (indent: Int, depth: Int, marker: Character, markerPadding: String, text: String)? {
        let (indent, rest) = parseLeadingIndent(line)
        guard let marker = rest.first, ["-", "*", "+"].contains(marker) else { return nil }
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
        var digits = ""
        for ch in rest {
            if ch.isNumber {
                digits.append(ch)
            } else {
                break
            }
        }
        guard !digits.isEmpty else { return nil }
        guard let n = Int(digits) else { return nil }
        let dotIndex = rest.index(rest.startIndex, offsetBy: digits.count)
        guard dotIndex < rest.endIndex, rest[dotIndex] == "." else { return nil }
        let afterDot = rest.index(after: dotIndex)
        guard afterDot <= rest.endIndex else { return nil }
        let markerPadding: String
        let text: String
        let markerLen: Int
        if afterDot == rest.endIndex {
            markerPadding = ""
            text = ""
            markerLen = digits.count + 2 // "." + implied single-space continuation
        } else {
            guard rest[afterDot] == " " || rest[afterDot] == "\t" else { return nil }
            let paddingSlice = rest[afterDot...].prefix(while: { $0 == " " || $0 == "\t" })
            markerPadding = String(paddingSlice)
            let textStart = rest.index(afterDot, offsetBy: paddingSlice.count)
            text = String(rest[textStart...])
            markerLen = digits.count + 1 + paddingSlice.count // "." + marker padding
        }
        let depth = indent / 3
        return (indent, depth, n, markerPadding, text, markerLen)
    }

    private static func parseOrderedTask(_ line: String) -> (indent: Int, depth: Int, index: Int, checked: Bool, text: String, markerLen: Int)? {
        // Minimal: "1. [ ] text" (digits + '.' + whitespace + '[' + (' '|'x') + ']' + whitespace)
        let (indent, rest) = parseLeadingIndent(line)
        var digits = ""
        for ch in rest {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard !digits.isEmpty else { return nil }
        guard let n = Int(digits) else { return nil }
        let chars = Array(rest)
        let prefixLen = digits.count
        guard chars.count >= prefixLen + 6 else { return nil }
        guard chars[prefixLen] == "." else { return nil }
        guard chars[prefixLen + 1] == " " || chars[prefixLen + 1] == "\t" else { return nil }
        guard chars[prefixLen + 2] == "[", chars[prefixLen + 4] == "]" else { return nil }
        let checkedChar = chars[prefixLen + 3]
        let checked = checkedChar == "x" || checkedChar == "X"
        guard chars[prefixLen + 5] == " " || chars[prefixLen + 5] == "\t" else { return nil }
        let text = String(chars.dropFirst(prefixLen + 6))
        let depth = indent / 3
        let markerLen = prefixLen + 2
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

    private static func makeTaskParagraph(
        _ task: (style: KernTaskStyle, marker: Character?, markerPadding: String, checked: Bool, text: String),
        indent: Int,
        depth: Int,
        baseFont: NSFont,
        options: Options
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()

        // Marker prefix: checkbox + " " (and optional bullet dot for bulleted task items).
        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )

        if task.style == .bulleted, options.taskRendering == .kern {
            para.append(NSAttributedString(string: "• ", attributes: markerAttrs))
        }

        // Slightly larger checkbox for Notion-like visual balance at 16pt base font.
        let checkboxFont = CheckboxStyle.preferredFont(pointSize: baseFont.pointSize + 4)
        let checkboxChar = task.checked ? "\u{2611}" : "\u{2610}" // ☑ / ☐
        var checkboxAttrs = markerAttrs
        checkboxAttrs[.font] = checkboxFont
        checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: baseFont, checkboxFont: checkboxFont)
        checkboxAttrs[.kernCheckbox] = true
        checkboxAttrs[.kernCheckboxChecked] = task.checked
        para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
        para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        let content = parseInline(task.text, baseFont: baseFont)
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
            let markerLen = markerPrefixLength(in: para)
            let range = NSRange(location: markerLen, length: max(0, para.length - markerLen))
            if range.length > 0 {
                para.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return para
    }

    private static func makeHeadingWithCheckbox(level: Int, checked: Bool, text: String, baseFont: NSFont) -> NSAttributedString {
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
        checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: heading, checkboxFont: checkboxFont)
        checkboxAttrs[.kernCheckbox] = true
        checkboxAttrs[.kernCheckboxChecked] = checked
        para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
        para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        para.append(parseInline(text, baseFont: baseFont))

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

    private static func makeBulletParagraph(_ text: String, marker: Character, markerPadding: String, indent: Int, depth: Int, baseFont: NSFont) -> NSAttributedString {
        let para = NSMutableAttributedString()
        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )
        para.append(NSAttributedString(string: "• ", attributes: markerAttrs))
        para.append(parseInline(text, baseFont: baseFont))
        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernBulletMarker, value: String(marker), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListMarkerPadding, value: markerPadding, range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .bullet, baseFont: baseFont, headingLevel: nil)
        return para
    }

    private static func makeCodeBlockAttributed(_ code: String, baseFont: NSFont, language: String?) -> NSAttributedString {
        let storedCode = code.isEmpty ? String(storagePlaceholderCharacter) : code
        let para = NSMutableAttributedString(string: storedCode, attributes: baseAttributes(baseFont: baseFont))
        if code.isEmpty, para.length > 0 {
            para.addAttribute(.kernPlaceholder, value: true, range: NSRange(location: 0, length: para.length))
        }
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        para.addAttribute(.font, value: codeFont, range: NSRange(location: 0, length: para.length))
        para.addAttribute(.kernBlockKind, value: KernBlockKind.codeBlock.rawValue, range: NSRange(location: 0, length: para.length))

        // Apply per-line paragraph styles so:
        // - the code block has a single top/bottom margin (Notion-like)
        // - internal lines don't accidentally inherit paragraphSpacingBefore/paragraphSpacing
        //   (which would create large gaps between every line).
        if para.length > 0 {
            let ns = para.string as NSString
            var ranges: [NSRange] = []
            var idx = 0
            while idx < ns.length {
                let r = ns.paragraphRange(for: NSRange(location: idx, length: 0))
                guard r.length > 0 else { break }
                ranges.append(r)
                idx = r.location + r.length
            }

            // Keep code blocks compact, but leave enough external spacing so neighboring rounded
            // backgrounds do not overlap with each other or headings.
            let topSpacing: CGFloat = 10
            let bottomSpacing: CGFloat = 12

            for (i, r) in ranges.enumerated() {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = 12
                style.headIndent = 12
                style.paragraphSpacingBefore = (i == 0) ? topSpacing : 0
                style.paragraphSpacing = (i == ranges.count - 1) ? bottomSpacing : 0
                para.addAttribute(.paragraphStyle, value: style, range: r)
            }
        }

        // Language is used for chrome (label), export, and best-effort syntax highlighting.
        if let language, !language.isEmpty {
            // Store on a kern.* attribute so export and UI can access it reliably.
            if para.length > 0 {
                para.addAttribute(.kernCodeLanguage, value: language, range: NSRange(location: 0, length: 1))
            }

            // Back-compat: we used to stash the language in a tooltip-like attribute.
            para.addAttribute(.toolTip, value: "```\(language)", range: NSRange(location: 0, length: min(1, para.length)))

            applySyntaxHighlighting(para, language: language)
        }

        return para
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

    private static func makeMermaidAttachmentAttributed(sourceMarkdown: String, baseFont: NSFont) -> NSAttributedString {
        let attachment = MarkdownMermaidAttachment(sourceMarkdown: sourceMarkdown)
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

    private static func makeImageAttachmentAttributed(alt: String, destination: String, sourceMarkdown: String, baseFont: NSFont) -> NSAttributedString {
        let attachment = MarkdownImageAttachment(
            altText: alt,
            destination: destination,
            sourceMarkdown: sourceMarkdown,
            baseURL: activeImportBaseURL,
            allowsRemoteLoading: activeImportOptions.remoteImageLoadingEnabled
        )
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        if out.length > 0 {
            let full = NSRange(location: 0, length: out.length)
            out.addAttribute(.font, value: baseFont, range: full)
            out.addAttribute(.kernSourceMarkdown, value: sourceMarkdown, range: full)
            out.addAttribute(.kernAttachmentKind, value: "image", range: full)
            if let resolvedURL = attachment.resolvedURL {
                out.addAttribute(.link, value: resolvedURL, range: full)
            } else if let absoluteURL = URL(string: destination), absoluteURL.scheme != nil {
                out.addAttribute(.link, value: absoluteURL, range: full)
            }
        }
        return out
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
        let keywordColor = NSColor.systemBlue
        let builtinColor = NSColor.systemTeal
        let stringColor = NSColor.systemRed
        let numberColor = NSColor.systemPurple
        let commentColor = NSColor.secondaryLabelColor
        let variableColor = NSColor.systemOrange

        func apply(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
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

    private static func makeOrderedParagraph(_ ordered: (index: Int, markerPadding: String, text: String), indent: Int, depth: Int, baseFont: NSFont) -> NSAttributedString {
        let para = NSMutableAttributedString()

        var markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )
        markerAttrs[.font] = orderedMarkerFont(baseFont: baseFont, depth: depth)

        let marker = orderedDisplayMarker(index: max(0, ordered.index), depth: depth)
        para.append(NSAttributedString(string: marker, attributes: markerAttrs))
        let content = parseInline(ordered.text, baseFont: baseFont)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListMarkerPadding, value: ordered.markerPadding, range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .ordered, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernOrderedIndex, value: max(0, ordered.index), range: NSRange(location: 0, length: min(marker.count, para.length)))

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
        baseFont: NSFont
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
        checkboxAttrs[.baselineOffset] = CheckboxStyle.baselineOffset(textFont: baseFont, checkboxFont: checkboxFont)
        checkboxAttrs[.kernCheckbox] = true
        checkboxAttrs[.kernCheckboxChecked] = orderedTask.checked
        para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
        para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        let content = parseInline(orderedTask.text, baseFont: baseFont)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .ordered, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernOrderedIndex, value: max(0, orderedTask.index), range: NSRange(location: 0, length: min(marker.count, para.length)))
        para.addAttribute(.kernOrderedIsTask, value: true, range: NSRange(location: 0, length: min(1, para.length)))

        if orderedTask.checked {
            let markerLen = markerPrefixLength(in: para)
            let range = NSRange(location: markerLen, length: max(0, para.length - markerLen))
            if range.length > 0 {
                para.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        return para
    }

    private static func headingFont(level: Int) -> NSFont {
        let lvl = max(1, min(6, level))
        let size: CGFloat
        switch lvl {
        case 1: size = 28
        case 2: size = 22
        case 3: size = 18
        default: size = 16
        }
        return NSFont.systemFont(ofSize: size, weight: .bold)
    }

    private static func applyBlockAttributes(_ paragraph: NSMutableAttributedString, kind: KernBlockKind, baseFont: NSFont, headingLevel: Int?) {
        guard paragraph.length > 0 else { return }
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.kernBlockKind, value: kind.rawValue, range: full)

        switch kind {
        case .heading:
            let level = headingLevel ?? 1
            paragraph.addAttribute(.kernHeadingLevel, value: level, range: full)

            // Apply heading font to the content only (skip marker prefix so checkbox glyphs keep
            // their own font metrics for consistent alignment).
            let font = headingFont(level: level)
            let markerLen = markerPrefixLength(in: paragraph)
            let contentRange = NSRange(location: markerLen, length: max(0, paragraph.length - markerLen))
            if contentRange.length > 0 {
                paragraph.addAttribute(.font, value: font, range: contentRange)
            }

            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = level == 1 ? 14 : 10
            style.paragraphSpacing = 6
            paragraph.addAttribute(.paragraphStyle, value: style, range: full)

        case .codeBlock:
            break
        case .tableCell:
            // Table cells already have a paragraph style with NSTextTableBlock + alignment.
            // Avoid overriding it; only normalize spacing.
            let style = ((paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            paragraph.addAttribute(.paragraphStyle, value: style, range: full)

        case .thematicBreak:
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 10
            paragraph.addAttribute(.paragraphStyle, value: style, range: full)

        case .bullet, .task, .ordered, .paragraph:
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 2
            style.paragraphSpacing = 2

            let listDepth = (paragraph.attribute(.kernListDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
            let baseIndent = CGFloat(max(0, listDepth)) * 24
            style.firstLineHeadIndent = baseIndent
            style.headIndent = baseIndent

            // Align wrapped lines after the visible marker.
            let markerLen = markerPrefixLength(in: paragraph)
            if markerLen > 0 {
                let markerAttr = paragraph.attributedSubstring(from: NSRange(location: 0, length: min(markerLen, paragraph.length)))
                // Measure the attributed prefix using its actual fonts (checkbox glyph is larger).
                let rect = markerAttr.boundingRect(
                    with: NSSize(width: 1000, height: 1000),
                    options: [.usesFontLeading, .usesLineFragmentOrigin]
                )
                style.headIndent = baseIndent + max(24, ceil(rect.width) + 8)
            }

            paragraph.addAttribute(.paragraphStyle, value: style, range: full)
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
            .foregroundColor: NSColor.labelColor,
        ]
    }

    // MARK: - Inline parsing / rendering

    private struct InlineStyle: Equatable {
        var strong: Bool = false
        var emphasis: Bool = false
        var strike: Bool = false
        var code: Bool = false
        var link: URL? = nil
        var linkDestination: String? = nil
        var autolink: Bool = false
        var linkTitle: String? = nil
        var linkReferenceID: String? = nil
        var linkReferenceURL: String? = nil
    }

    private static func parseInline(_ text: String, baseFont: NSFont) -> NSAttributedString {
        parseInline(text, baseFont: baseFont, style: InlineStyle())
    }

    private static func parseAutolinkURL(_ inner: String) -> URL? {
        // CommonMark autolinks disallow whitespace.
        if inner.contains(where: { $0.isWhitespace }) { return nil }

        if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
            return URL(string: inner)
        }

        // Email autolink: <me@example.com>
        if inner.contains("@"), !inner.contains(":") {
            return URL(string: "mailto:\(inner)")
        }

        return nil
    }

    private struct InlineParseResult {
        let attributed: NSAttributedString
        let nextIndex: Int
    }

    private struct BracketContent {
        let text: String
        let closeIndex: Int
        let nextIndex: Int
    }

    private static func parseInline(_ text: String, baseFont: NSFont, style: InlineStyle) -> NSAttributedString {
        if activeStrictConformanceRoundTripMode {
            let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(text, baseFont: baseFont, style: style))
            if attr.length > 0 {
                attr.addAttribute(.kernSourceMarkdown, value: text, range: NSRange(location: 0, length: attr.length))
            }
            return attr
        }

        // Lightweight inline parser for the native editor subset:
        // - code spans (variable backtick fence length)
        // - emphasis/strong/strikethrough with `*` and `_`
        // - links (inline + reference + title)
        // - images (inline + reference) as attachments
        // - inline math (`$...$`) rendered without delimiters
        // - autolinks
        let out = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0

        func appendLiteral(_ s: String, style: InlineStyle) {
            out.append(makeInlineAttributed(s, baseFont: baseFont, style: style))
        }

        func appendEscapedLiteral(_ s: String, style: InlineStyle) {
            let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(s, baseFont: baseFont, style: style))
            if attr.length > 0 {
                attr.addAttribute(.kernEscapedLiteral, value: true, range: NSRange(location: 0, length: attr.length))
            }
            out.append(attr)
        }

        func appendImageAttachment(alt: String, destination: String, sourceMarkdown: String) {
            out.append(makeImageAttachmentAttributed(alt: alt, destination: destination, sourceMarkdown: sourceMarkdown, baseFont: baseFont))
        }

        while i < chars.count {
            let ch = chars[i]

            // Escape: only strip the backslash for escapable punctuation.
            if ch == "\\" {
                if i + 1 < chars.count, isMarkdownEscapable(chars[i + 1]) {
                    appendEscapedLiteral(String(chars[i + 1]), style: style)
                    i += 2
                    continue
                }
                appendLiteral("\\", style: style)
                i += 1
                continue
            }

            // Images: ![alt](url "title") / ![alt][id]
            if ch == "!", i + 1 < chars.count, chars[i + 1] == "[" {
                if let image = parseImage(chars, startIndex: i) {
                    appendImageAttachment(alt: image.alt, destination: image.destination, sourceMarkdown: image.sourceMarkdown)
                    i = image.nextIndex
                    continue
                }
            }

            // Autolink: <https://...> or <me@example.com>
            if ch == "<" {
                if let end = indexOf(">", in: chars, start: i + 1) {
                    let inner = String(chars[(i + 1)..<end])
                    if let url = parseAutolinkURL(inner) {
                        var nextStyle = style
                        nextStyle.link = url
                        nextStyle.autolink = true
                        appendLiteral(inner, style: nextStyle)
                        i = end + 1
                        continue
                    }
                }
            }

            // Link: [text](url "title") / [text][id]
            if ch == "[" {
                if let link = parseLink(chars, startIndex: i, parentStyle: style, baseFont: baseFont) {
                    out.append(link.attributed)
                    i = link.nextIndex
                    continue
                }
            }

            // Inline math: $...$ (avoid currency, keep escaped dollars as literal text).
            if ch == "$" {
                if let parsed = parseInlineMath(chars, startIndex: i, baseFont: baseFont) {
                    out.append(parsed.attributed)
                    i = parsed.nextIndex
                    continue
                }
            }

            // Code span
            if ch == "`" {
                if let parsed = parseCodeSpan(chars, startIndex: i) {
                    var nextStyle = style
                    nextStyle.code = true
                    nextStyle.strong = false
                    nextStyle.emphasis = false
                    nextStyle.strike = false
                    let attr = NSMutableAttributedString(
                        attributedString: makeInlineAttributed(parsed.text, baseFont: baseFont, style: nextStyle)
                    )
                    if parsed.fenceLength > 1
                        || parsed.text.contains("`")
                        || parsed.text.hasPrefix(" ")
                        || parsed.text.hasSuffix(" ")
                    {
                        attr.addAttribute(.kernSourceMarkdown, value: parsed.sourceMarkdown, range: NSRange(location: 0, length: attr.length))
                    }
                    out.append(attr)
                    i = parsed.nextIndex
                    continue
                }
                // No valid closing fence for this backtick run; emit the whole run literally
                // so we don't re-enter on the same run and produce incorrect nested parses.
                var runEnd = i
                while runEnd < chars.count, chars[runEnd] == "`" {
                    runEnd += 1
                }
                appendLiteral(String(chars[i..<runEnd]), style: style)
                i = runEnd
                continue
            }

            // Strong + emphasis (***text*** / ___text___)
            if (ch == "*" || ch == "_"), i + 2 < chars.count, chars[i + 1] == ch, chars[i + 2] == ch {
                if canOpenDelimiter(ch, count: 3, in: chars, at: i),
                   let end = findClosingDelimiter(ch, count: 3, in: chars, start: i + 3)
                {
                    let inner = String(chars[(i + 3)..<end])
                    if !isValidInlineDelimitedContent(inner) {
                        appendLiteral(String(ch), style: style)
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.strong.toggle()
                    nextStyle.emphasis.toggle()
                    out.append(parseInline(inner, baseFont: baseFont, style: nextStyle))
                    i = end + 3
                    continue
                }
            }

            // Strikethrough
            if ch == "~", i + 1 < chars.count, chars[i + 1] == "~" {
                if let end = indexOf("~~", in: chars, start: i + 2) {
                    let inner = String(chars[(i + 2)..<end])
                    if inner.isEmpty {
                        appendLiteral("~", style: style)
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.strike.toggle()
                    out.append(parseInline(inner, baseFont: baseFont, style: nextStyle))
                    i = end + 2
                    continue
                }
            }

            // Strong (**text** / __text__)
            if (ch == "*" || ch == "_"), i + 1 < chars.count, chars[i + 1] == ch {
                if canOpenDelimiter(ch, count: 2, in: chars, at: i),
                   let end = findClosingDelimiter(ch, count: 2, in: chars, start: i + 2)
                {
                    let inner = String(chars[(i + 2)..<end])
                    if !isValidInlineDelimitedContent(inner) {
                        appendLiteral(String(ch), style: style)
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.strong.toggle()
                    out.append(parseInline(inner, baseFont: baseFont, style: nextStyle))
                    i = end + 2
                    continue
                }
            }

            // Emphasis (*text* / _text_)
            if ch == "*" || ch == "_" {
                if canOpenDelimiter(ch, count: 1, in: chars, at: i),
                   let end = findClosingDelimiter(ch, count: 1, in: chars, start: i + 1)
                {
                    let inner = String(chars[(i + 1)..<end])
                    if !isValidInlineDelimitedContent(inner) {
                        appendLiteral(String(ch), style: style)
                        i += 1
                        continue
                    }
                    var nextStyle = style
                    nextStyle.emphasis.toggle()
                    out.append(parseInline(inner, baseFont: baseFont, style: nextStyle))
                    i = end + 1
                    continue
                }
            }

            appendLiteral(String(ch), style: style)
            i += 1
        }

        return out
    }

    private static func parseBracketContent(_ chars: [Character], openIndex: Int) -> BracketContent? {
        guard openIndex < chars.count, chars[openIndex] == "[" else { return nil }
        var i = openIndex + 1
        var depth = 1
        var escaped = false
        while i < chars.count {
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
                let text = String(chars[(openIndex + 1)..<i])
                return BracketContent(text: text, closeIndex: i, nextIndex: i + 1)
            }
            i += 1
        }
        return nil
    }

    private static func isValidInlineDelimitedContent(_ inner: String) -> Bool {
        if inner.isEmpty { return false }
        if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        guard let first = inner.first, let last = inner.last else { return false }
        if first.isWhitespace || last.isWhitespace { return false }
        return true
    }

    private static func parseInlineLinkDestination(_ chars: [Character], openParenIndex: Int) -> (destination: String, title: String?, nextIndex: Int)? {
        guard openParenIndex < chars.count, chars[openParenIndex] == "(" else { return nil }

        let destination: String
        var title: String? = nil

        var i = openParenIndex + 1
        while i < chars.count, isASCIISpace(chars[i]) { i += 1 }
        guard i < chars.count else { return nil }

        if chars[i] == "<" {
            // Angle-bracket destination form: [label](<dest> "title")
            i += 1
            var parsed = ""
            var escaped = false
            var sawClosingAngle = false
            while i < chars.count {
                let ch = chars[i]
                if escaped {
                    parsed.append("\\")
                    parsed.append(ch)
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
                parsed.append(ch)
                i += 1
            }
            guard sawClosingAngle, !parsed.isEmpty else { return nil }
            destination = parsed
        } else {
            // Bare destination form: [label](dest "title")
            // Destination cannot contain ASCII whitespace. Balanced parentheses are allowed.
            var parsed = ""
            var escaped = false
            var parenDepth = 0
            while i < chars.count {
                let ch = chars[i]
                if escaped {
                    parsed.append("\\")
                    parsed.append(ch)
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
                    parsed.append(ch)
                    i += 1
                    continue
                }
                if ch == ")" {
                    if parenDepth == 0 {
                        break
                    }
                    parenDepth -= 1
                    parsed.append(ch)
                    i += 1
                    continue
                }
                if isASCIISpace(ch) {
                    break
                }
                if ch == "<" || ch == ">" {
                    return nil
                }
                parsed.append(ch)
                i += 1
            }
            guard !parsed.isEmpty else { return nil }
            destination = parsed
        }

        while i < chars.count, isASCIISpace(chars[i]) { i += 1 }

        if i < chars.count, chars[i] != ")" {
            guard let parsedTitle = parseInlineLinkTitle(chars, startIndex: i) else { return nil }
            title = parsedTitle.title
            i = parsedTitle.nextIndex
            while i < chars.count, isASCIISpace(chars[i]) { i += 1 }
        }

        guard i < chars.count, chars[i] == ")" else { return nil }
        return (destination, title, i + 1)
    }

    private static func parseInlineLinkTitle(_ chars: [Character], startIndex: Int) -> (title: String, nextIndex: Int)? {
        guard startIndex < chars.count else { return nil }
        let opener = chars[startIndex]

        if opener == "\"" || opener == "'" {
            var i = startIndex + 1
            var escaped = false
            var value = ""
            while i < chars.count {
                let ch = chars[i]
                if escaped {
                    value.append("\\")
                    value.append(ch)
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
                    return (value, i + 1)
                }
                value.append(ch)
                i += 1
            }
            return nil
        }

        if opener == "(" {
            var i = startIndex + 1
            var escaped = false
            var depth = 1
            var value = ""
            while i < chars.count {
                let ch = chars[i]
                if escaped {
                    value.append("\\")
                    value.append(ch)
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
                    value.append(ch)
                    i += 1
                    continue
                }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (value, i + 1)
                    }
                    value.append(ch)
                    i += 1
                    continue
                }
                value.append(ch)
                i += 1
            }
        }

        return nil
    }

    private static func isASCIISpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{000C}"
    }

    private struct CodeSpanMatch {
        let text: String
        let sourceMarkdown: String
        let fenceLength: Int
        let nextIndex: Int
    }

    private static func parseCodeSpan(_ chars: [Character], startIndex: Int) -> CodeSpanMatch? {
        guard startIndex < chars.count, chars[startIndex] == "`" else { return nil }

        var fenceLen = 0
        var i = startIndex
        while i < chars.count, chars[i] == "`" {
            fenceLen += 1
            i += 1
        }
        guard fenceLen > 0 else { return nil }

        var scan = i
        while scan < chars.count {
            if chars[scan] == "`" {
                var run = 0
                var j = scan
                while j < chars.count, chars[j] == "`" {
                    run += 1
                    j += 1
                }
                if run == fenceLen {
                    let inner = String(chars[i..<scan])
                    return CodeSpanMatch(
                        text: normalizeCodeSpanText(inner),
                        sourceMarkdown: String(chars[startIndex..<j]),
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

    private static func normalizeCodeSpanText(_ inner: String) -> String {
        var normalized = inner
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        if normalized.hasPrefix(" "),
           normalized.hasSuffix(" "),
           normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
    }

    private static func indexOfRepeated(_ ch: Character, count: Int, in chars: [Character], start: Int) -> Int? {
        guard count > 0, start < chars.count else { return nil }
        var i = start
        while i <= chars.count - count {
            var ok = true
            for j in 0..<count where chars[i + j] != ch {
                ok = false
                break
            }
            if ok { return i }
            i += 1
        }
        return nil
    }

    private static func findClosingDelimiter(_ ch: Character, count: Int, in chars: [Character], start: Int) -> Int? {
        guard count > 0, start < chars.count else { return nil }
        var cursor = start
        while let candidate = indexOfRepeated(ch, count: count, in: chars, start: cursor) {
            if canCloseDelimiter(ch, count: count, in: chars, at: candidate) {
                return candidate
            }
            cursor = candidate + 1
        }
        return nil
    }

    private static func canOpenDelimiter(_ marker: Character, count: Int, in chars: [Character], at index: Int) -> Bool {
        guard index >= 0, index + count <= chars.count else { return false }
        let prev = index > 0 ? chars[index - 1] : nil
        let next = (index + count) < chars.count ? chars[index + count] : nil

        let leftFlanking = isLeftFlankingDelimiterRun(prev: prev, next: next)
        guard leftFlanking else { return false }
        if marker != "_" { return true }

        let rightFlanking = isRightFlankingDelimiterRun(prev: prev, next: next)
        return !rightFlanking || isPunctuation(prev)
    }

    private static func canCloseDelimiter(_ marker: Character, count: Int, in chars: [Character], at index: Int) -> Bool {
        guard index >= 0, index + count <= chars.count else { return false }
        let prev = index > 0 ? chars[index - 1] : nil
        let next = (index + count) < chars.count ? chars[index + count] : nil

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
        return ch.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isPunctuation(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        return ch.unicodeScalars.allSatisfy { scalar in
            if scalar.isASCII {
                return !CharacterSet.alphanumerics.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            return CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
        }
    }

    private static func parseInlineMath(_ chars: [Character], startIndex: Int, baseFont: NSFont) -> InlineParseResult? {
        guard startIndex < chars.count, chars[startIndex] == "$" else { return nil }
        guard startIndex + 1 < chars.count else { return nil }

        let next = chars[startIndex + 1]
        // Avoid interpreting currency as math (`$5`).
        if next.isNumber || next.isWhitespace || next == "$" {
            return nil
        }

        var i = startIndex + 1
        var escaped = false
        while i < chars.count {
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
                let expr = String(chars[(startIndex + 1)..<i])
                guard !expr.isEmpty else { return nil }
                guard !expr.contains("\n") else { return nil }
                guard !expr.hasPrefix(" "), !expr.hasSuffix(" ") else { return nil }
                let source = "$\(expr)$"
                let attr = makeInlineMathAttributed(expression: expr, sourceMarkdown: source, baseFont: baseFont)
                return InlineParseResult(attributed: attr, nextIndex: i + 1)
            }
            i += 1
        }
        return nil
    }

    private static func parseImage(_ chars: [Character], startIndex: Int) -> (alt: String, destination: String, sourceMarkdown: String, nextIndex: Int)? {
        guard startIndex + 1 < chars.count, chars[startIndex] == "!", chars[startIndex + 1] == "[" else { return nil }
        guard let alt = parseBracketContent(chars, openIndex: startIndex + 1) else { return nil }

        // Inline destination: ![alt](url "title")
        if alt.nextIndex < chars.count, chars[alt.nextIndex] == "(",
           let target = parseInlineLinkDestination(chars, openParenIndex: alt.nextIndex)
        {
            let titleSuffix = target.title.map { " \"\($0)\"" } ?? ""
            let source = "![\(alt.text)](\(target.destination)\(titleSuffix))"
            return (alt.text, target.destination, source, target.nextIndex)
        }

        // Reference destination: ![alt][id]
        if alt.nextIndex < chars.count, chars[alt.nextIndex] == "[",
           let ref = parseBracketContent(chars, openIndex: alt.nextIndex)
        {
            let refID = ref.text.isEmpty ? alt.text : ref.text
            if let def = activeReferenceDefinitions[refID.lowercased()] {
                let source = "![\(alt.text)][\(refID)]"
                return (alt.text, def.destination, source, ref.nextIndex)
            }
        }

        return nil
    }

    private static func parseLink(_ chars: [Character], startIndex: Int, parentStyle: InlineStyle, baseFont: NSFont) -> InlineParseResult? {
        guard let linkText = parseBracketContent(chars, openIndex: startIndex) else { return nil }
        // Keep empty link labels literal to avoid dropping syntax during round-trip (`[](...)`).
        guard !linkText.text.isEmpty else { return nil }
        // Defer complex labels we don't serialize correctly yet (nested links/images, mixed inline-code + emphasis).
        // Keeping them literal preserves strict markdown round-trip semantics until the full inline parser lands.
        let allowRichLabelParsing = shouldParseSimpleLinkLabel(linkText.text)

        // Inline destination: [text](url "title")
        if linkText.nextIndex < chars.count, chars[linkText.nextIndex] == "(",
           let target = parseInlineLinkDestination(chars, openParenIndex: linkText.nextIndex)
        {
            if !allowRichLabelParsing {
                let literalEnd = extendedLiteralLinkEndIndex(chars: chars, initialEnd: target.nextIndex, linkLabel: linkText.text)
                return makeSourceLiteralResult(chars: chars, startIndex: startIndex, nextIndex: literalEnd, baseFont: baseFont, style: parentStyle)
            }
            let resolvedDestination = unescapeMarkdownBackslashes(target.destination)
            guard let url = normalizedLinkURL(from: resolvedDestination) else { return nil }
            var linkStyle = parentStyle
            linkStyle.link = url
            linkStyle.linkDestination = target.destination
            linkStyle.autolink = false
            linkStyle.linkTitle = target.title
            linkStyle.linkReferenceID = nil
            linkStyle.linkReferenceURL = nil
            let inner = NSMutableAttributedString(attributedString: parseInline(linkText.text, baseFont: baseFont, style: linkStyle))
            if inner.length > 0 {
                inner.addAttribute(.kernLinkDestination, value: target.destination, range: NSRange(location: 0, length: inner.length))
                if let title = target.title {
                    inner.addAttribute(.kernLinkTitle, value: title, range: NSRange(location: 0, length: inner.length))
                }
            }
            return InlineParseResult(attributed: inner, nextIndex: target.nextIndex)
        }

        // Reference destination: [text][id]
        if linkText.nextIndex < chars.count, chars[linkText.nextIndex] == "[",
           let ref = parseBracketContent(chars, openIndex: linkText.nextIndex)
        {
            if !allowRichLabelParsing {
                let literalEnd = extendedLiteralLinkEndIndex(chars: chars, initialEnd: ref.nextIndex, linkLabel: linkText.text)
                return makeSourceLiteralResult(chars: chars, startIndex: startIndex, nextIndex: literalEnd, baseFont: baseFont, style: parentStyle)
            }
            let refID = ref.text.isEmpty ? linkText.text : ref.text
            if let definition = activeReferenceDefinitions[refID.lowercased()] {
                let resolvedDestination = unescapeMarkdownBackslashes(definition.destination)
                guard let url = normalizedLinkURL(from: resolvedDestination) else { return nil }
                var linkStyle = parentStyle
                linkStyle.link = url
                linkStyle.linkDestination = nil
                linkStyle.autolink = false
                linkStyle.linkTitle = definition.title
                linkStyle.linkReferenceID = definition.id
                linkStyle.linkReferenceURL = definition.destination

                let inner = NSMutableAttributedString(attributedString: parseInline(linkText.text, baseFont: baseFont, style: linkStyle))
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
        let source = String(chars[startIndex..<nextIndex])
        let attr = NSMutableAttributedString(attributedString: makeInlineAttributed(source, baseFont: baseFont, style: style))
        if attr.length > 0 {
            attr.addAttribute(.kernSourceMarkdown, value: source, range: NSRange(location: 0, length: attr.length))
        }
        return InlineParseResult(attributed: attr, nextIndex: nextIndex)
    }

    private static func extendedLiteralLinkEndIndex(chars: [Character], initialEnd: Int, linkLabel: String) -> Int {
        var end = initialEnd
        let backtickCount = linkLabel.filter { $0 == "`" }.count
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

    private static func makeInlineAttributed(_ text: String, baseFont: NSFont, style: InlineStyle) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = baseAttributes(baseFont: baseFont)
        var font = baseFont

        if style.code {
            attrs[.kernInlineCode] = true
            attrs[.backgroundColor] = inlineCodeBackgroundColor
            font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        } else {
            if style.strong {
                attrs[.kernStrong] = true
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if style.emphasis {
                attrs[.kernEmphasis] = true
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if style.strike {
                attrs[.kernStrikethrough] = true
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = style.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.linkColor
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
        }

        attrs[.font] = font
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static var inlineCodeBackgroundColor: NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
            case .darkAqua, .vibrantDark:
                return NSColor(white: 1.0, alpha: 0.16)
            default:
                return NSColor(white: 0.0, alpha: 0.08)
            }
        }
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
            body = exportInline(content)
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

    private static func indexOf(_ needle: String, in chars: [Character], start: Int) -> Int? {
        guard !needle.isEmpty, start < chars.count else { return nil }
        let nChars = Array(needle)
        guard nChars.count <= chars.count - start else { return nil }

        var i = start
        while i <= chars.count - nChars.count {
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

    private static func stripHardBreakMarker(_ text: String) -> (text: String, hardBreak: HardBreakMarker?) {
        if activeStrictConformanceRoundTripMode {
            return (text, nil)
        }
        let backtickCount = text.filter { $0 == "`" }.count
        if backtickCount % 2 != 0 {
            // Avoid converting trailing spaces/backslashes inside multiline code spans.
            return (text, nil)
        }
        if text.hasSuffix("\\") {
            return (String(text.dropLast()), .backslash)
        }
        if text.hasSuffix("\t") {
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
