import AppKit

/// Shared geometry constants for code-block backgrounds + chrome placement.
/// Keep this in one place so hit-testing, drawing, and overlay controls stay aligned.
enum CodeBlockChromeGeometry {
    // Background padding around the glyph bounding rect (matches the visual design of the block).
    static let backgroundInsetX: CGFloat = 10
    static let backgroundInsetY: CGFloat = 2

    // Extra space at the top of the rounded background reserved for chrome (language pill + copy button).
    // The first code line already sits below this region because we expand the background upward from
    // the glyph rect; keep this compact so stacked code blocks don't look overly spaced.
    static let chromeTopExtra: CGFloat = 18

    static let cornerRadius: CGFloat = 8

    static func backgroundRect(
        forGlyphBoundingRect glyphRect: NSRect,
        lineFragmentRect: NSRect? = nil,
        isFlipped: Bool
    ) -> NSRect {
        var rect = glyphRect.insetBy(dx: -backgroundInsetX, dy: -backgroundInsetY)
        if let lineFragmentRect {
            // Stretch the block background to the full available line width (Notion-like).
            // This avoids "shrink-to-content" blocks that clip chrome (language + copy).
            rect.origin.x = lineFragmentRect.minX - backgroundInsetX
            rect.size.width = lineFragmentRect.width + backgroundInsetX * 2
        }
        if isFlipped {
            // Flipped coordinates grow downward; extending "top" means moving origin up.
            rect.origin.y -= chromeTopExtra
            rect.size.height += chromeTopExtra
        } else {
            // Non-flipped: origin is the bottom; increasing height extends upward (top).
            rect.size.height += chromeTopExtra
        }
        return rect
    }
}
