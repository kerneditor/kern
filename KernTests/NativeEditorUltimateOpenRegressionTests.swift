import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorUltimateOpenRegressionTests: XCTestCase {
    @MainActor
    func testOpeningUltimateStressFixtureDoesNotHangOrExplodeLayout() throws {
        let fixtureURL = fixture(path: "test-fixtures/ultimate-stress-test.md")
        let markdown = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertGreaterThan(markdown.utf8.count, 80_000)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = fixtureURL

        let window = hostInWindow(vc: vc, size: NSSize(width: 1100, height: 760), appearance: .init(named: .darkAqua))
        let start = CFAbsoluteTimeGetCurrent()
        vc.stringValue = markdown
        window.displayIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        // Regression guard for "open appears hung".
        XCTAssertLessThan(elapsed, 12.0, "Opening/rendering ultimate fixture took too long (\(elapsed)s)")

        // Regression guard for runaway layout memory/height explosions.
        XCTAssertLessThan(textView.frame.height, 250_000, "Document view height exploded (\(textView.frame.height))")
        XCTAssertGreaterThan(textView.frame.height, 700, "Document view height unexpectedly collapsed (\(textView.frame.height))")
    }

    @MainActor
    private func hostInWindow(vc: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.contentViewController = vc
        window.setFrame(rect, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) { return found }
        }
        return nil
    }

    private func fixture(path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(path)
    }
}
