import AppKit
import XCTest
@testable import KernTextKit

final class CodeBlockChromeGeometryTests: XCTestCase {
    func testBackgroundRectKeepsVisibleBottomInset() {
        let glyphRect = NSRect(x: 40, y: 120, width: 420, height: 24)
        let lineRect = NSRect(x: 40, y: 120, width: 700, height: 24)
        let bg = CodeBlockChromeGeometry.backgroundRect(
            forGlyphBoundingRect: glyphRect,
            lineFragmentRect: lineRect,
            isFlipped: true
        )

        let bottomInset = bg.maxY - glyphRect.maxY
        XCTAssertGreaterThanOrEqual(bottomInset, 6, "Code block should keep visible bottom breathing room")
    }

    func testBackgroundRectUsesNearSymmetricVerticalInsetsWhenChromeIsHidden() {
        let glyphRect = NSRect(x: 40, y: 120, width: 420, height: 24)
        let lineRect = NSRect(x: 40, y: 120, width: 700, height: 24)
        let bg = CodeBlockChromeGeometry.backgroundRect(
            forGlyphBoundingRect: glyphRect,
            lineFragmentRect: lineRect,
            isFlipped: true
        )

        let topInset = glyphRect.minY - bg.minY
        let bottomInset = bg.maxY - glyphRect.maxY

        XCTAssertLessThanOrEqual(abs(topInset - bottomInset), 2, "Hidden chrome should not make the background visibly top-heavy")
    }
}
