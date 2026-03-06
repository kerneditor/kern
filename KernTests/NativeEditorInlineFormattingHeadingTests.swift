import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorInlineFormattingHeadingTests: XCTestCase {
    @MainActor
    func testToggleCodeInHeadingPreservesHeadingFontSize() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "# Heading text\n"

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        defer { closeHostedEditor(window) }
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView,
              let storage = textView.textStorage else {
            XCTFail("Missing NativeEditor.TextView/text storage")
            return
        }

        let ns = storage.string as NSString
        let range = ns.range(of: "Heading")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(range)

        let before = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        vc.toggleCode(nil)

        let after = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        guard let before, let after else { return }
        XCTAssertEqual(after.pointSize, before.pointSize, accuracy: 0.01)
        XCTAssertTrue(after.fontDescriptor.symbolicTraits.contains(.monoSpace), "Inline code toggle should be monospaced")
    }

    @MainActor
    func testToggleItalicInHeadingPreservesHeadingFontSize() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "## Heading text\n"

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        defer { closeHostedEditor(window) }
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView,
              let storage = textView.textStorage else {
            XCTFail("Missing NativeEditor.TextView/text storage")
            return
        }

        let ns = storage.string as NSString
        let range = ns.range(of: "Heading")
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(range)

        let before = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        vc.toggleItalic(nil)

        let after = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        guard let before, let after else { return }
        XCTAssertEqual(after.pointSize, before.pointSize, accuracy: 0.01)
        XCTAssertTrue(after.fontDescriptor.symbolicTraits.contains(.italic), "Inline italic toggle should apply italic trait")
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
    private func closeHostedEditor(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
    }
}

