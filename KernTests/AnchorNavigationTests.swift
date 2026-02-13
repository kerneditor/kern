import AppKit
import XCTest
@testable import KernTextKit

final class AnchorNavigationTests: XCTestCase {
    @MainActor
    func testClickedAnchorLinkJumpsAndShowsToast() {
        let vc = NativeEditorViewController()
        _ = vc.view

        vc.stringValue = """
        # Doc

        ## Table of Contents

        - [Jump](#target)

        ## Target

        Hello
        """

        // Simulate clicking an in-document anchor link. We don't need a real NSTextView here;
        // the view controller jumps within its own editor text view.
        XCTAssertTrue(vc.textView(NSTextView(), clickedOnLink: URL(string: "#target")!, at: 0))

        guard let editorTextView = findFirstTextView(in: vc.view) else {
            XCTFail("Failed to locate editor text view in view hierarchy")
            return
        }

        let text = editorTextView.string as NSString
        let targetLoc = text.range(of: "Target").location
        XCTAssertNotEqual(targetLoc, NSNotFound)

        // Jump should move the caret into the destination heading paragraph.
        XCTAssertEqual(editorTextView.selectedRange().location, targetLoc)

        // A toast makes the jump visible (and testable) without relying on scroll state.
        XCTAssertNotNil(findView(withAccessibilityIdentifier: "NativeEditor.JumpToast", in: vc.view))
    }
}

// MARK: - View tree helpers

@MainActor
private func findFirstTextView(in view: NSView) -> NSTextView? {
    if let tv = view as? NSTextView { return tv }
    for sub in view.subviews {
        if let found = findFirstTextView(in: sub) { return found }
    }
    return nil
}

@MainActor
private func findView(withAccessibilityIdentifier ident: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == ident { return view }
    for sub in view.subviews {
        if let found = findView(withAccessibilityIdentifier: ident, in: sub) { return found }
    }
    return nil
}

