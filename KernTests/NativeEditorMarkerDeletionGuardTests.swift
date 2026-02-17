import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorMarkerDeletionGuardTests: XCTestCase {
    @MainActor
    func testDeletionAcrossMarkerRangeIsAllowed() {
        let (vc, textView) = makeController(markdown: "- [x] todo\n")
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        let full = NSRange(location: 0, length: storage.length)
        let allowed = vc.textView(textView, shouldChangeTextIn: full, replacementString: "")
        XCTAssertTrue(allowed, "Select-all delete/cut should be allowed even when marker glyphs are selected")
    }

    @MainActor
    func testNonDeletionEditTouchingMarkerRemainsBlocked() {
        let (vc, textView) = makeController(markdown: "- [ ] todo\n")
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        let markerRange = firstMarkerRange(in: storage) ?? NSRange(location: 0, length: 1)
        let allowed = vc.textView(textView, shouldChangeTextIn: markerRange, replacementString: "x")
        XCTAssertFalse(allowed, "Typing over marker glyphs should remain blocked")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(markdown: String) -> (NativeEditorViewController, NativeMarkdownTextView) {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown

        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        return (vc, textView)
    }

    @MainActor
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView {
            return tv
        }
        for sub in view.subviews {
            if let found = findTextView(in: sub) {
                return found
            }
        }
        return nil
    }

    private func firstMarkerRange(in storage: NSTextStorage) -> NSRange? {
        var out: NSRange?
        storage.enumerateAttribute(.kernMarker, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            if (value as? Bool) == true {
                out = range
                stop.pointee = true
            }
        }
        return out
    }
}

