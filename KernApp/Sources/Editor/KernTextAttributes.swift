import Foundation

// Custom attributes used by the native editor prototype to round-trip Markdown.
// These are intentionally simple and string-keyed so they survive NSAttributedString editing.
extension NSAttributedString.Key {
    static let kernBlockKind = NSAttributedString.Key("kern.blockKind")
    static let kernHeadingLevel = NSAttributedString.Key("kern.headingLevel")
    static let kernMarker = NSAttributedString.Key("kern.marker") // Bool
    static let kernOrderedIndex = NSAttributedString.Key("kern.orderedIndex") // Int
    static let kernOrderedIsTask = NSAttributedString.Key("kern.orderedIsTask") // Bool
    static let kernTaskStyle = NSAttributedString.Key("kern.taskStyle") // Int
    static let kernBulletMarker = NSAttributedString.Key("kern.bulletMarker") // String ("-" | "*" | "+")
    static let kernListMarkerPadding = NSAttributedString.Key("kern.listMarkerPadding") // String (exact whitespace after list marker)
    static let kernListIndent = NSAttributedString.Key("kern.listIndent") // Int (leading spaces to export)
    static let kernListDepth = NSAttributedString.Key("kern.listDepth") // Int (nesting depth for rendering)
    static let kernQuoteDepth = NSAttributedString.Key("kern.quoteDepth") // Int

    static let kernStrong = NSAttributedString.Key("kern.strong") // Bool
    static let kernEmphasis = NSAttributedString.Key("kern.emphasis") // Bool
    static let kernInlineCode = NSAttributedString.Key("kern.inlineCode") // Bool
    static let kernStrikethrough = NSAttributedString.Key("kern.strikethrough") // Bool
    static let kernAutolink = NSAttributedString.Key("kern.autolink") // Bool
    static let kernLinkTitle = NSAttributedString.Key("kern.linkTitle") // String
    static let kernLinkDestination = NSAttributedString.Key("kern.linkDestination") // String (raw markdown destination)
    static let kernLinkReferenceID = NSAttributedString.Key("kern.linkReferenceID") // String
    static let kernLinkReferenceURL = NSAttributedString.Key("kern.linkReferenceURL") // String
    static let kernEscapedLiteral = NSAttributedString.Key("kern.escapedLiteral") // Bool (char came from backslash escape)
    static let kernHybridExpandedInlineLink = NSAttributedString.Key("kern.hybridExpandedInlineLink") // Bool
    static let kernHybridExpandedInlineSyntax = NSAttributedString.Key("kern.hybridExpandedInlineSyntax") // Bool

    static let kernCheckbox = NSAttributedString.Key("kern.checkbox") // Bool
    static let kernCheckboxChecked = NSAttributedString.Key("kern.checkboxChecked") // Bool

    // Code blocks
    static let kernCodeLanguage = NSAttributedString.Key("kern.codeLanguage") // String (ex: "js")
    static let kernCodeFenceInfoString = NSAttributedString.Key("kern.codeFenceInfoString") // String (full authored info string)
    static let kernCodeBlockID = NSAttributedString.Key("kern.codeBlockID") // Int (stable grouping for fenced blocks)
    static let kernCodeFenceMarker = NSAttributedString.Key("kern.codeFenceMarker") // String ("`" | "~")
    static let kernCodeFenceLength = NSAttributedString.Key("kern.codeFenceLength") // Int
    static let kernSyntaxHighlighted = NSAttributedString.Key("kern.syntaxHighlighted") // Bool

    // Tables (GFM)
    static let kernTableID = NSAttributedString.Key("kern.tableID") // Int
    static let kernTableRow = NSAttributedString.Key("kern.tableRow") // Int
    static let kernTableColumn = NSAttributedString.Key("kern.tableColumn") // Int
    static let kernTableIsHeader = NSAttributedString.Key("kern.tableIsHeader") // Bool
    static let kernTableColumnAlignment = NSAttributedString.Key("kern.tableColumnAlignment") // Int
    static let kernTableColumnCount = NSAttributedString.Key("kern.tableColumnCount") // Int

    // Thematic breaks (horizontal rules)
    static let kernThematicBreakMarker = NSAttributedString.Key("kern.thematicBreakMarker") // String (e.g. "---", "***")

    // Generic raw markdown source for non-text semantic runs/attachments.
    static let kernSourceMarkdown = NSAttributedString.Key("kern.sourceMarkdown") // String
    static let kernAttachmentKind = NSAttributedString.Key("kern.attachmentKind") // String ("image" | "mathBlock" | "mermaid")
    static let kernInlineMath = NSAttributedString.Key("kern.inlineMath") // Bool
    static let kernPlaceholder = NSAttributedString.Key("kern.placeholder") // Bool (invisible storage placeholder)

    // Reference-style link/image definition metadata.
    static let kernReferenceDefinitionID = NSAttributedString.Key("kern.referenceDefinitionID") // String
    static let kernReferenceDefinitionURL = NSAttributedString.Key("kern.referenceDefinitionURL") // String
    static let kernReferenceDefinitionTitle = NSAttributedString.Key("kern.referenceDefinitionTitle") // String
}

enum KernBlockKind: Int {
    case paragraph = 0
    case heading = 1
    case bullet = 2
    case task = 3
    case codeBlock = 4
    case ordered = 5
    case tableCell = 6
    case thematicBreak = 7
}

enum KernTaskStyle: Int {
    /// `[ ] text` or `[] text` (Kern/Notion-style shortcut), renders as checkbox-only.
    case standalone = 0
    /// `- [ ] text` (GFM task list item), may render with or without a bullet depending on preferences.
    case bulleted = 1
}
