import AppKit

/// Shared geometry constants for code-block backgrounds + chrome placement.
/// Keep this in one place so hit-testing, drawing, and overlay controls stay aligned.
enum CodeBlockChromeGeometry {
    // Background padding around the glyph bounding rect (matches the visual design of the block).
    static let backgroundInsetX: CGFloat = 10
    static let backgroundInsetY: CGFloat = 6

    // Code-block chrome should not distort the inactive block geometry.
    // Keep the rounded background symmetric; chrome may visually float slightly above the block.
    static let chromeOverlayTopOverflow: CGFloat = 4
    static let chromeOverlayInsetX: CGFloat = 10
    static let chromeOverlayInsetY: CGFloat = 4

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
        return rect
    }
}
