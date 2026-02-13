import AppKit

/// Minimal Markdown <-> attributed string codec for the native editor prototype.
///
/// This is intentionally a prototype:
/// - It round-trips a small Markdown subset deterministically.
/// - It encodes semantics with custom attributes (kern.*) so export is reliable.
/// - It does not aim for full CommonMark/GFM compliance yet.
@MainActor
enum NativeMarkdownCodec {
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
            return opt
        }
    }

    static func importMarkdown(_ markdown: String, options: Options = Options()) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 16)
        let inputEndsWithNewline = markdown.hasSuffix("\n")
        let result = NSMutableAttributedString()

        // Preserve empty lines by splitting with omittingEmptySubsequences=false.
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var prevWasOrdered = false
        var orderedCounter = 1
        var orderedStart = 1
        var tableCounter = 0

        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let quote = parseBlockquotePrefix(rawLine)
            let quoteDepth = quote?.depth ?? 0
            let line = quote?.text ?? rawLine

            // Preserve an explicit empty blockquote line (`>` or `> `) as a blank line that still
            // round-trips with `>` on export.
            if quoteDepth > 0, line.isEmpty {
                if i < lines.count - 1 {
                    var attrs = baseAttributes(baseFont: baseFont)
                    attrs[.kernQuoteDepth] = quoteDepth
                    result.append(NSAttributedString(string: "\n", attributes: attrs))
                }
                i += 1
                prevWasOrdered = false
                continue
            }

            // Code block (```lang ... ```)
            if let fence = parseFenceStart(line) {
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    var nextLine = lines[i]
                    if quoteDepth > 0 {
                        guard let q = parseBlockquotePrefix(nextLine), q.depth >= quoteDepth else { break }
                        nextLine = q.text
                    }
                    if isFenceEnd(nextLine) {
                        break
                    }
                    codeLines.append(nextLine)
                    i += 1
                }
                // Skip closing fence if present
                if i < lines.count {
                    var endLine = lines[i]
                    if quoteDepth > 0, let q = parseBlockquotePrefix(endLine), q.depth >= quoteDepth {
                        endLine = q.text
                    }
                    if isFenceEnd(endLine) {
                        i += 1
                    }
                }

                let codeText = codeLines.joined(separator: "\n")
                let codeAttr = NSMutableAttributedString(attributedString: makeCodeBlockAttributed(codeText, baseFont: baseFont, language: fence.language))
                applyQuoteAttributes(codeAttr, quoteDepth: quoteDepth)
                result.append(codeAttr)
                if i < lines.count {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                continue
            }

            // GFM table
            if let match = parseGfmTable(lines, startIndex: i) {
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
                prevWasOrdered = false
                continue
            }

            // Thematic break (horizontal rule)
            if let marker = parseThematicBreak(line) {
                let para = NSMutableAttributedString(attributedString: makeThematicBreakAttributed(baseFont: baseFont, marker: marker))
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i += 1
                prevWasOrdered = false
                continue
            }

            // Heading
            if let heading = parseHeading(line) {
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
                    prevWasOrdered = false
                    continue
                }

                let content = parseInline(heading.text, baseFont: baseFont)
                let para = NSMutableAttributedString(attributedString: content)
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
                prevWasOrdered = false
                continue
            }

            // Bullet/standalone task: - [ ] text / * [ ] text / + [ ] text / [] text / [ ] text
            if let task = parseTask(line) {
                var (combined, prevHardBreak) = stripHardBreakMarker(task.text)
                let continuationIndent = String(repeating: " ", count: task.indent + 2)

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
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    combined += (prevHardBreak ? "\u{2028}" : " ") + nextText
                    prevHardBreak = nextHardBreak
                    j += 1
                }

                let para = NSMutableAttributedString(attributedString: makeTaskParagraph(
                    (task.style, task.checked, combined),
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
                prevWasOrdered = false
                continue
            }

            // Ordered task (Kern preference): 1. [ ] text
            if options.orderedTasksEnabled, let orderedTask = parseOrderedTask(line) {
                var (combined, prevHardBreak) = stripHardBreakMarker(orderedTask.text)
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
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    combined += (prevHardBreak ? "\u{2028}" : " ") + nextText
                    prevHardBreak = nextHardBreak
                    j += 1
                }

                let normalizedIndex: Int
                switch options.orderedListNumbering {
                case .preserveTyped:
                    normalizedIndex = orderedTask.index
                case .gfmDefault:
                    if prevWasOrdered {
                        orderedCounter += 1
                        normalizedIndex = orderedCounter
                    } else {
                        orderedStart = max(1, orderedTask.index)
                        orderedCounter = orderedStart
                        normalizedIndex = orderedStart
                    }
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
                prevWasOrdered = true
                continue
            }

            // Ordered list: 1. text
            if let ordered = parseOrdered(line) {
                var (combined, prevHardBreak) = stripHardBreakMarker(ordered.text)
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
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    combined += (prevHardBreak ? "\u{2028}" : " ") + nextText
                    prevHardBreak = nextHardBreak
                    j += 1
                }

                let normalizedIndex: Int
                switch options.orderedListNumbering {
                case .preserveTyped:
                    normalizedIndex = ordered.index
                case .gfmDefault:
                    if prevWasOrdered {
                        orderedCounter += 1
                        normalizedIndex = orderedCounter
                    } else {
                        orderedStart = max(1, ordered.index)
                        orderedCounter = orderedStart
                        normalizedIndex = orderedStart
                    }
                }

                let para = NSMutableAttributedString(attributedString: makeOrderedParagraph(
                    (normalizedIndex, combined),
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
                prevWasOrdered = true
                continue
            }

            // Bullet list: - text
            if let bullet = parseBullet(line) {
                var (combined, prevHardBreak) = stripHardBreakMarker(bullet.text)
                let continuationIndent = String(repeating: " ", count: bullet.indent + 2)
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
                    {
                        break
                    }

                    let (nextText, nextHardBreak) = stripHardBreakMarker(stripped)
                    combined += (prevHardBreak ? "\u{2028}" : " ") + nextText
                    prevHardBreak = nextHardBreak
                    j += 1
                }

                let para = NSMutableAttributedString(attributedString: makeBulletParagraph(combined, indent: bullet.indent, depth: bullet.depth, baseFont: baseFont))
                applyQuoteAttributes(para, quoteDepth: quoteDepth)
                result.append(para)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
                }
                i = j
                prevWasOrdered = false
                continue
            }

            // Plain paragraph (including empty line)
            var (combined, prevHardBreak) = stripHardBreakMarker(line)
            var j = i + 1
            while prevHardBreak, j < lines.count {
                let next = lines[j]
                // Hard breaks are only meaningful within the same paragraph; stop at blank lines.
                if next.isEmpty { break }
                let (nextText, nextHardBreak) = stripHardBreakMarker(next)
                combined += "\u{2028}" + nextText
                prevHardBreak = nextHardBreak
                j += 1
            }

            let para = NSMutableAttributedString(attributedString: parseInline(combined, baseFont: baseFont))
            applyBlockAttributes(para, kind: .paragraph, baseFont: baseFont, headingLevel: nil)
            applyQuoteAttributes(para, quoteDepth: quoteDepth)
            result.append(para)
            if j - 1 < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes(baseFont: baseFont)))
            }
            i = j
            prevWasOrdered = false
        }

        return result
    }

    static func exportMarkdown(_ attributed: NSAttributedString, options: Options = Options()) -> String {
        let ns = attributed.string as NSString
        var outBlocks: [String] = []

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

            if kind == .tableCell {
                let tableID = (para.attribute(.kernTableID, at: 0, effectiveRange: nil) as? Int) ?? -1
                let exported = exportGfmTableBlock(attributed, ns: ns, startIndex: idx, tableID: tableID)
                outBlocks.append(exported.block)
                idx = exported.nextIndex
                continue
            }

            if kind == .codeBlock {
                // Group consecutive codeBlock paragraphs into a single fenced block.
                var codeLines: [String] = []
                var j = idx

                // Best-effort language extraction: stored as toolTip on first character.
                var language: String?
                if let tip = para.attribute(.toolTip, at: 0, effectiveRange: nil) as? String,
                   tip.hasPrefix("```") {
                    let lang = tip.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    language = lang.isEmpty ? nil : String(lang)
                }

                let quoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0

                while j < ns.length {
                    let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                    let p = attributed.attributedSubstring(from: r)
                    if p.length == 0 { break }
                    let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    guard k == .codeBlock else { break }

                    let qd = (p.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                    if qd != quoteDepth { break }

                    let lineText = p.string.hasSuffix("\n") ? String(p.string.dropLast()) : p.string
                    codeLines.append(lineText)
                    j = r.location + r.length
                }

                let fence = "```" + (language.map { "\($0)" } ?? "")
                var blockLines = [fence] + codeLines + ["```"]
                if quoteDepth > 0 {
                    let prefix = String(repeating: "> ", count: quoteDepth)
                    blockLines = blockLines.map { prefix + $0 }
                }
                outBlocks.append(blockLines.joined(separator: "\n"))
                idx = j
                continue
            }

            if kind == .thematicBreak {
                let marker = (para.attribute(.kernThematicBreakMarker, at: 0, effectiveRange: nil) as? String) ?? "---"
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
                var currentN: Int?
                let initialQuoteDepth = (para.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                while j < ns.length {
                    let r = ns.paragraphRange(for: NSRange(location: j, length: 0))
                    let p = attributed.attributedSubstring(from: r)
                    if p.length == 0 { break }
                    let kRaw = p.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
                    let k = KernBlockKind(rawValue: kRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
                    guard k == .ordered else { break }

                    let quoteDepth = (p.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
                    if quoteDepth != initialQuoteDepth { break }

                    let storedN = (p.attribute(.kernOrderedIndex, at: 0, effectiveRange: nil) as? Int) ?? 1
                    if currentN == nil { currentN = max(1, storedN) }
                    var line = exportOrderedParagraphGfmNumbering(p, outputIndex: currentN ?? 1, options: options)
                    if quoteDepth > 0 {
                        line = String(repeating: "> ", count: quoteDepth) + line
                    }
                    outBlocks.append(line)
                    currentN = (currentN ?? 1) + 1
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
        if endsWithNewline {
            joined += "\n"
        }
        return joined
    }

    private static func exportOrderedParagraphGfmNumbering(_ paragraphWithNewline: NSAttributedString, outputIndex: Int, options: Options) -> String {
        // Drop trailing newline for analysis.
        let text = paragraphWithNewline.string
        let paraText = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let paraRange = NSRange(location: 0, length: min(paragraphWithNewline.length, (paraText as NSString).length))
        let paragraph = paragraphWithNewline.attributedSubstring(from: paraRange)

        // Find the first non-marker character (skip marker prefix).
        var contentStart = 0
        while contentStart < paragraph.length {
            let isMarker = (paragraph.attribute(.kernMarker, at: contentStart, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            contentStart += 1
        }
        let contentRange = NSRange(location: contentStart, length: max(0, paragraph.length - contentStart))
        let content = paragraph.attributedSubstring(from: contentRange)

        let n = max(1, outputIndex)
        let isTask = (paragraph.attribute(.kernOrderedIsTask, at: 0, effectiveRange: nil) as? Bool) ?? false
        let line: String
        let softBreakKind: KernBlockKind
        if isTask {
            let checked = findFirstCheckboxState(in: paragraph) ?? false
            switch (options.exportDialect, options.gfmExtensionExportStrategy) {
            case (.gfm, .portable):
                let glyph = checked ? "\u{2611}" : "\u{2610}"
                line = "\(n). \(glyph) " + exportInline(content)
                softBreakKind = .ordered
            case (.gfm, .lint):
                let box = checked ? "x" : " "
                line = "- [\(box)] \(n). " + exportInline(content)
                softBreakKind = .task
            default:
                let box = checked ? "x" : " "
                line = "\(n). [\(box)] " + exportInline(content)
                softBreakKind = .ordered
            }
        } else {
            line = "\(n). " + exportInline(content)
            softBreakKind = .ordered
        }
        return serializeSoftLineBreaks(body: line, kind: softBreakKind)
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

        // Tables require at least 2 columns to avoid false positives.
        guard max(headerCells.count, delimiterCells.count) >= 2 else {
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

        let columnCount = max(headerCells.count, alignments.count)
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

    /// Returns the marker that should be used when exporting this thematic break, or nil if the line
    /// isn't a thematic break.
    private static func parseThematicBreak(_ line: String) -> String? {
        // Preserve exact "---", "***", "___" (no leading/trailing whitespace).
        if line == "---" || line == "***" || line == "___" { return line }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // CommonMark allows spaces/tabs between markers. Normalize those variants to "---".
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else { return nil }
        guard compact.allSatisfy({ $0 == first }) else { return nil }
        return "---"
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
    }

    private static func parseFenceStart(_ line: String) -> FenceStart? {
        guard line.hasPrefix("```") else { return nil }
        let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return FenceStart(language: nil) }
        return FenceStart(language: rest)
    }

    private static func isFenceEnd(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "```"
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

    private static func parseTask(_ line: String) -> (indent: Int, depth: Int, style: KernTaskStyle, checked: Bool, text: String)? {
        // Task parsing:
        // - Standard GFM: "- [ ] " / "* [x] " / "+ [ ] " (supports extra whitespace + tabs)
        // - Kern/Notion-style shortcut: "[] " / "[x] " / "[ ] " (optionally indented)
        guard line.count >= 3 else { return nil }

        let (indent, rest) = parseLeadingIndent(line)

        // Standard: "- [ ] "
        if let marker = rest.first, ["-", "*", "+"].contains(marker) {
            let afterMarker = rest.dropFirst()
            guard let ws = afterMarker.first, ws == " " || ws == "\t" else { /* not a list marker */ return nil }
            let afterWS = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
            guard afterWS.hasPrefix("["), afterWS.count >= 4 else { return nil }
            let chars = Array(afterWS)
            guard chars.count >= 4, chars[0] == "[", chars[2] == "]" else { return nil }
            let checkedChar = chars[1]
            let checked = checkedChar == "x" || checkedChar == "X"
            // Require at least one whitespace after closing bracket.
            guard chars.count >= 4, chars[3] == " " || chars[3] == "\t" else { return nil }
            let text = String(afterWS.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let depth = indent / 2
            return (indent, depth, .bulleted, checked, text)
        }

        // Shortcut: "[] " / "[ ] " / "[x] "
        let trimmed = String(rest)
        if trimmed.hasPrefix("[] ") {
            let text = String(trimmed.dropFirst(3))
            return (indent, 0, .standalone, false, text)
        }
        if trimmed.hasPrefix("[ ] ") {
            let text = String(trimmed.dropFirst(4))
            return (indent, 0, .standalone, false, text)
        }
        if trimmed.hasPrefix("[x] ") || trimmed.hasPrefix("[X] ") {
            let text = String(trimmed.dropFirst(4))
            return (indent, 0, .standalone, true, text)
        }

        return nil
    }

    private static func parseBullet(_ line: String) -> (indent: Int, depth: Int, text: String)? {
        let (indent, rest) = parseLeadingIndent(line)
        guard let marker = rest.first, ["-", "*", "+"].contains(marker) else { return nil }
        let afterMarker = rest.dropFirst()
        guard let ws = afterMarker.first, ws == " " || ws == "\t" else { return nil }
        let text = String(afterMarker.drop(while: { $0 == " " || $0 == "\t" }))
        let depth = indent / 2
        return (indent, depth, text)
    }

    private static func parseOrdered(_ line: String) -> (indent: Int, depth: Int, index: Int, text: String, markerLen: Int)? {
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
        guard afterDot < rest.endIndex else { return nil }
        guard rest[afterDot] == " " || rest[afterDot] == "\t" else { return nil }
        let textStart = rest.index(after: afterDot)
        let text = String(rest[textStart...])
        let depth = indent / 3
        let markerLen = digits.count + 2 // ". " (treat tab as 1 char here; indentation uses spaces)
        return (indent, depth, max(1, n), text, markerLen)
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
        return (indent, depth, max(1, n), checked, text, markerLen)
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
        _ task: (style: KernTaskStyle, checked: Bool, text: String),
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
        let checkboxFont = NSFont.systemFont(ofSize: baseFont.pointSize + 4, weight: .regular)
        let checkboxChar = task.checked ? "\u{2611}" : "\u{2610}" // ☑ / ☐
        var checkboxAttrs = markerAttrs
        checkboxAttrs[.font] = checkboxFont
        checkboxAttrs[.baselineOffset] = -1
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

        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )

        let checkboxFont = NSFont.systemFont(ofSize: baseFont.pointSize + 4, weight: .regular)
        let checkboxChar = checked ? "\u{2611}" : "\u{2610}"
        var checkboxAttrs = markerAttrs
        checkboxAttrs[.font] = checkboxFont
        checkboxAttrs[.baselineOffset] = -1
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

    private static func makeBulletParagraph(_ text: String, indent: Int, depth: Int, baseFont: NSFont) -> NSAttributedString {
        let para = NSMutableAttributedString()
        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )
        para.append(NSAttributedString(string: "• ", attributes: markerAttrs))
        para.append(parseInline(text, baseFont: baseFont))
        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .bullet, baseFont: baseFont, headingLevel: nil)
        return para
    }

    private static func makeCodeBlockAttributed(_ code: String, baseFont: NSFont, language: String?) -> NSAttributedString {
        let para = NSMutableAttributedString(string: code, attributes: baseAttributes(baseFont: baseFont))
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        para.addAttribute(.font, value: codeFont, range: NSRange(location: 0, length: para.length))
        para.addAttribute(.kernBlockKind, value: KernBlockKind.codeBlock.rawValue, range: NSRange(location: 0, length: para.length))

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 8
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        para.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: para.length))

        // Language is currently not used in rendering, but we keep it in a tooltip-like attribute for future use.
        if let language, !language.isEmpty {
            para.addAttribute(.toolTip, value: "```\(language)", range: NSRange(location: 0, length: min(1, para.length)))
        }

        return para
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

    private static func makeOrderedParagraph(_ ordered: (index: Int, text: String), indent: Int, depth: Int, baseFont: NSFont) -> NSAttributedString {
        let para = NSMutableAttributedString()

        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )

        let marker = "\(max(1, ordered.index)). "
        para.append(NSAttributedString(string: marker, attributes: markerAttrs))
        let content = parseInline(ordered.text, baseFont: baseFont)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .ordered, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernOrderedIndex, value: max(1, ordered.index), range: NSRange(location: 0, length: min(marker.count, para.length)))

        return para
    }

    private static func makeOrderedTaskParagraph(
        _ orderedTask: (index: Int, checked: Bool, text: String),
        indent: Int,
        depth: Int,
        baseFont: NSFont
    ) -> NSAttributedString {
        let para = NSMutableAttributedString()

        let markerAttrs = baseAttributes(baseFont: baseFont).merging(
            [.kernMarker: true],
            uniquingKeysWith: { $1 }
        )

        let marker = "\(max(1, orderedTask.index)). "
        para.append(NSAttributedString(string: marker, attributes: markerAttrs))

        let checkboxFont = NSFont.systemFont(ofSize: baseFont.pointSize + 4, weight: .regular)
        let checkboxChar = orderedTask.checked ? "\u{2611}" : "\u{2610}"
        var checkboxAttrs = markerAttrs
        checkboxAttrs[.font] = checkboxFont
        checkboxAttrs[.baselineOffset] = -1
        checkboxAttrs[.kernCheckbox] = true
        checkboxAttrs[.kernCheckboxChecked] = orderedTask.checked
        para.append(NSAttributedString(string: checkboxChar, attributes: checkboxAttrs))
        para.append(NSAttributedString(string: " ", attributes: markerAttrs))

        let content = parseInline(orderedTask.text, baseFont: baseFont)
        para.append(content)

        para.addAttribute(.kernListIndent, value: max(0, indent), range: NSRange(location: 0, length: min(1, para.length)))
        para.addAttribute(.kernListDepth, value: max(0, depth), range: NSRange(location: 0, length: min(1, para.length)))
        applyBlockAttributes(para, kind: .ordered, baseFont: baseFont, headingLevel: nil)
        para.addAttribute(.kernOrderedIndex, value: max(1, orderedTask.index), range: NSRange(location: 0, length: min(marker.count, para.length)))
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

    private static func applyBlockAttributes(_ paragraph: NSMutableAttributedString, kind: KernBlockKind, baseFont: NSFont, headingLevel: Int?) {
        guard paragraph.length > 0 else { return }
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.kernBlockKind, value: kind.rawValue, range: full)

        switch kind {
        case .heading:
            let level = headingLevel ?? 1
            paragraph.addAttribute(.kernHeadingLevel, value: level, range: full)

            let size: CGFloat
            switch level {
            case 1: size = 28
            case 2: size = 22
            case 3: size = 18
            default: size = 16
            }
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            paragraph.addAttribute(.font, value: font, range: full)

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
        let style = ((paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()

        style.firstLineHeadIndent += quoteIndent
        style.headIndent += quoteIndent
        paragraph.addAttribute(.paragraphStyle, value: style, range: full)
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
        var autolink: Bool = false
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

    private static func parseInline(_ text: String, baseFont: NSFont, style: InlineStyle) -> NSAttributedString {
        // Extremely small inline parser:
        // - `code`
        // - **strong**
        // - *emphasis*
        // - ~~strikethrough~~
        // - [text](url)
        // - <https://example.com> / <me@example.com>
        let out = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0

        func appendLiteral(_ s: String, style: InlineStyle) {
            out.append(makeInlineAttributed(s, baseFont: baseFont, style: style))
        }

        while i < chars.count {
            let ch = chars[i]

            // Escape
            if ch == "\\", i + 1 < chars.count {
                appendLiteral(String(chars[i + 1]), style: style)
                i += 2
                continue
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

            // Code span
            if ch == "`" {
                if let end = indexOf("`", in: chars, start: i + 1) {
                    let inner = String(chars[(i + 1)..<end])
                    var nextStyle = style
                    nextStyle.code = true
                    nextStyle.strong = false
                    nextStyle.emphasis = false
                    nextStyle.strike = false
                    nextStyle.link = nil
                    nextStyle.autolink = false
                    appendLiteral(inner, style: nextStyle)
                    i = end + 1
                    continue
                }
            }

            // Link: [text](url)
            if ch == "[" {
                if let closeBracket = indexOf("]", in: chars, start: i + 1),
                   closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
                   let closeParen = indexOf(")", in: chars, start: closeBracket + 2) {
                    let innerText = String(chars[(i + 1)..<closeBracket])
                    let urlText = String(chars[(closeBracket + 2)..<closeParen])
                    if let url = URL(string: urlText) {
                        var nextStyle = style
                        nextStyle.link = url
                        appendLiteral(innerText, style: nextStyle)
                        i = closeParen + 1
                        continue
                    }
                }
            }

            // Strong
            if ch == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                if let end = indexOf("**", in: chars, start: i + 2) {
                    let inner = String(chars[(i + 2)..<end])
                    var nextStyle = style
                    nextStyle.strong.toggle()
                    out.append(parseInline(inner, baseFont: baseFont, style: nextStyle))
                    i = end + 2
                    continue
                }
            }

            // Strikethrough
            if ch == "~", i + 1 < chars.count, chars[i + 1] == "~" {
                if let end = indexOf("~~", in: chars, start: i + 2) {
                    let inner = String(chars[(i + 2)..<end])
                    var nextStyle = style
                    nextStyle.strike.toggle()
                    out.append(parseInline(inner, baseFont: baseFont, style: nextStyle))
                    i = end + 2
                    continue
                }
            }

            // Emphasis
            if ch == "*" {
                if let end = indexOf("*", in: chars, start: i + 1) {
                    let inner = String(chars[(i + 1)..<end])
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

    private static func makeInlineAttributed(_ text: String, baseFont: NSFont, style: InlineStyle) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = baseAttributes(baseFont: baseFont)
        var font = baseFont

        if style.code {
            attrs[.kernInlineCode] = true
            attrs[.backgroundColor] = NSColor(white: 0, alpha: 0.06)
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
                if style.autolink {
                    attrs[.kernAutolink] = true
                }
            }
        }

        attrs[.font] = font
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func indexOf(_ needle: String, in chars: [Character], start: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        if needle.count == 1 {
            let n = needle.first!
            for i in start..<chars.count where chars[i] == n {
                return i
            }
            return nil
        }

        // needle is "**" or "~~"
        guard needle == "**" || needle == "~~" else { return nil }
        if start >= chars.count { return nil }
        for i in start..<(chars.count - 1) {
            if needle == "**", chars[i] == "*", chars[i + 1] == "*" {
                return i
            }
            if needle == "~~", chars[i] == "~", chars[i + 1] == "~" {
                return i
            }
        }
        return nil
    }

    // MARK: - Export

    private static func exportParagraph(_ paragraphWithNewline: NSAttributedString, options: Options) -> String {
        // Drop trailing newline for analysis.
        let text = paragraphWithNewline.string
        let paraText = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let quoteDepth = (paragraphWithNewline.attribute(.kernQuoteDepth, at: 0, effectiveRange: nil) as? Int) ?? 0
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

            // If the heading begins with a checkbox glyph, serialize as `## [ ] Heading` (Kern extension).
            if let checked = findFirstCheckboxState(in: paragraph) {
                let headingText = exportInline(content).replacingOccurrences(of: "\u{2028}", with: " ")
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
                let headingText = exportInline(content).replacingOccurrences(of: "\u{2028}", with: " ")
                body = prefix + headingText
                softBreakKind = .heading
            }
        case .task:
            let checked = findFirstCheckboxState(in: paragraph) ?? false
            let box = checked ? "x" : " "
            let styleRaw = paragraph.attribute(.kernTaskStyle, at: 0, effectiveRange: nil) as? Int
            let style = KernTaskStyle(rawValue: styleRaw ?? KernTaskStyle.bulleted.rawValue) ?? .bulleted
            let text = exportInline(content)
            if style == .standalone, options.exportDialect == .kern {
                body = "[\(box)] " + text
            } else {
                body = "- [\(box)] " + text
            }
            softBreakKind = .task
        case .bullet:
            body = "- " + exportInline(content)
            softBreakKind = .bullet
        case .ordered:
            let n = (paragraph.attribute(.kernOrderedIndex, at: 0, effectiveRange: nil) as? Int) ?? 1
            let isTask = (paragraph.attribute(.kernOrderedIsTask, at: 0, effectiveRange: nil) as? Bool) ?? false
            if isTask {
                let checked = findFirstCheckboxState(in: paragraph) ?? false
                switch (options.exportDialect, options.gfmExtensionExportStrategy) {
                case (.gfm, .portable):
                    let glyph = checked ? "\u{2611}" : "\u{2610}"
                    body = "\(max(1, n)). \(glyph) " + exportInline(content)
                    softBreakKind = .ordered
                case (.gfm, .lint):
                    let box = checked ? "x" : " "
                    body = "- [\(box)] \(max(1, n)). " + exportInline(content)
                    softBreakKind = .task
                default:
                    let box = checked ? "x" : " "
                    body = "\(max(1, n)). [\(box)] " + exportInline(content)
                    softBreakKind = .ordered
                }
            } else {
                body = "\(max(1, n)). " + exportInline(content)
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
            body = (paragraph.attribute(.kernThematicBreakMarker, at: 0, effectiveRange: nil) as? String) ?? "---"
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
        // Very small serializer based on our kern.* attributes.
        var out = ""
        var current = InlineStyle()
        current.link = nil

        func open(_ next: InlineStyle) {
            if next.code { out += "`" }
            if next.strong { out += "**" }
            if next.emphasis { out += "*" }
            if next.strike { out += "~~" }
        }

        func close(_ prev: InlineStyle) {
            if prev.strike { out += "~~" }
            if prev.emphasis { out += "*" }
            if prev.strong { out += "**" }
            if prev.code { out += "`" }
        }

        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let text = attributed.attributedSubstring(from: range).string
            let next = InlineStyle(
                strong: (attrs[.kernStrong] as? Bool) ?? false,
                emphasis: (attrs[.kernEmphasis] as? Bool) ?? false,
                strike: (attrs[.kernStrikethrough] as? Bool) ?? false,
                code: (attrs[.kernInlineCode] as? Bool) ?? false,
                link: attrs[.link] as? URL,
                autolink: (attrs[.kernAutolink] as? Bool) ?? false
            )

            // Links: serialize as [text](url) for contiguous runs with same URL.
            if let link = next.link {
                // Close any previous style first.
                close(current)
                current = InlineStyle()
                if next.autolink {
                    out += "<\(text)>"
                } else {
                    out += "[\(escapeInline(text))](\(link.absoluteString))"
                }
                return
            }

            if next != current {
                close(current)
                open(next)
                current = next
            }

            out += escapeInline(text)
        }

        close(current)
        return out
    }

    private static func serializeSoftLineBreaks(body: String, kind: KernBlockKind) -> String {
        // Convert U+2028 line separators (Shift+Enter) into Markdown hard breaks.
        // For list items, indent continuation lines so they stay within the same list item.
        guard body.contains("\u{2028}") else { return body }

        let parts = body.split(separator: "\u{2028}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return body.replacingOccurrences(of: "\u{2028}", with: "\n") }

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

        var out = parts[0]
        for p in parts.dropFirst() {
            out += "\\\n" + continuationIndent + p
        }
        return out
    }

    // MARK: - Soft Break Import Helpers

    /// In Markdown, a trailing `\` at end-of-line is a hard line break. We use this as the on-disk
    /// representation for an in-editor U+2028 (Shift+Enter) soft break.
    private static func stripHardBreakMarker(_ text: String) -> (text: String, hardBreak: Bool) {
        guard text.hasSuffix("\\") else { return (text, false) }
        return (String(text.dropLast()), true)
    }

    private static func escapeInline(_ text: String) -> String {
        // Minimal escaping to avoid accidentally creating markup.
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
