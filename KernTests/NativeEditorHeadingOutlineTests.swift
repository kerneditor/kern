import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorHeadingOutlineTests: XCTestCase {
    @MainActor
    func testHeadingOutlineBuildsEntriesAndSelectionJumpsToHeading() {
        let vc = NativeEditorViewController()
        _ = vc.view

        vc.stringValue = """
        # Doc

        ## Intro

        Lorem ipsum dolor sit amet.

        ### Deep Dive

        More content.
        """

        let entries = vc.headingOutlineEntriesForTesting()
        XCTAssertEqual(entries.map(\.title), ["Doc", "Intro", "Deep Dive"])

        vc.selectHeadingOutlineEntryForTesting(index: 2)

        guard let textView = firstTextView(in: vc.view) else {
            XCTFail("Missing editor text view")
            return
        }

        let ns = textView.string as NSString
        let target = ns.range(of: "Deep Dive").location
        XCTAssertNotEqual(target, NSNotFound)
        XCTAssertTrue(waitUntil(timeout: 1.0) { textView.selectedRange().location == target })
    }

    @MainActor
    func testHeadingOutlineVisibilityPreferenceCanBeToggled() {
        let key = "nativeEditor.headingOutlineVisible"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(true, forKey: key)
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "# One\n\n## Two\n"

        XCTAssertTrue(vc.isHeadingOutlineVisibleForMenuState())
        vc.toggleHeadingOutline(nil)
        XCTAssertFalse(vc.isHeadingOutlineVisibleForMenuState())
        vc.toggleHeadingOutline(nil)
        XCTAssertTrue(vc.isHeadingOutlineVisibleForMenuState())
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

@MainActor
private func firstTextView(in view: NSView) -> NSTextView? {
    if let tv = view as? NSTextView { return tv }
    for sub in view.subviews {
        if let found = firstTextView(in: sub) {
            return found
        }
    }
    return nil
}
