import AppKit
import CoreText

/// Centralized styling helpers for checkbox markers (☐/☑).
///
/// Why this exists:
/// - If we rely on the "System" font for these glyphs, macOS may render ☐ and ☑ from *different*
///   fallback fonts, which makes their visual size/baseline differ (and looks misaligned).
/// - We want consistent, deterministic rendering across the app and tests.
enum CheckboxStyle {
    /// Preferred checkbox glyph font. `AppleSymbols` contains both ☐ and ☑ with matching metrics.
    static func preferredFont(pointSize: CGFloat) -> NSFont {
        if let f = NSFont(name: "AppleSymbols", size: pointSize) {
            return f
        }
        return NSFont.systemFont(ofSize: pointSize, weight: .regular)
    }

    /// Compute a baseline offset (in points) that aligns the checkbox's visual center with an
    /// "optical midline" of the surrounding text.
    ///
    /// Notes:
    /// - For body text, aligning strictly to x-height can look slightly low (the checkbox dips
    ///   below the perceived center), while aligning to cap-height can look slightly high.
    /// - We target the midpoint between x-height and cap-height centers. This tends to match how
    ///   modern editors visually center icon-like glyphs next to text.
    static func baselineOffset(textFont: NSFont, checkboxFont: NSFont) -> CGFloat {
        // Target center in the text font: midpoint between x-height/2 and cap-height/2.
        // Fall back to whichever metric is available.
        let xh = textFont.xHeight
        let cap = textFont.capHeight
        let xMid = (xh > 0 ? xh : cap) / 2.0
        let capMid = (cap > 0 ? cap : xh) / 2.0
        let targetMidY = (xMid + capMid) / 2.0

        guard let scalar = "☐".unicodeScalars.first else { return 0 }
        let ctFont = checkboxFont as CTFont

        var chars: [UniChar] = [UniChar(scalar.value)]
        var glyphs: [CGGlyph] = [0]
        let ok = CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, 1)
        guard ok else { return 0 }

        var g = glyphs[0]
        let bbox = CTFontGetBoundingRectsForGlyphs(ctFont, .default, &g, nil, 1)
        let actualMidY = bbox.midY
        if actualMidY == 0 { return 0 }

        // Positive moves glyph up; negative moves down.
        return targetMidY - actualMidY
    }
}
