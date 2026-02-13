import AppKit

@MainActor
final class ThematicBreakAttachment: NSTextAttachment {
    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        self.attachmentCell = ThematicBreakAttachmentCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.attachmentCell = ThematicBreakAttachmentCell()
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        // Occupy a predictable height; width is controlled by the line fragment.
        NSRect(x: 0, y: 0, width: max(1, lineFrag.width), height: 18)
    }
}

@MainActor
private final class ThematicBreakAttachmentCell: NSTextAttachmentCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let inset: CGFloat = 2
        let y = cellFrame.midY.rounded(.down) + 0.5

        let path = NSBezierPath()
        path.move(to: NSPoint(x: cellFrame.minX + inset, y: y))
        path.line(to: NSPoint(x: cellFrame.maxX - inset, y: y))
        path.lineWidth = 1

        NSColor(white: 0, alpha: 0.18).setStroke()
        path.stroke()
    }
}

