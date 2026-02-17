import AppKit
import XCTest
@testable import KernTextKit

/// Integration-level tests for the NativeEditorViewController find/replace UI + behavior.
/// These run as normal unit tests (fast, no Accessibility permissions needed).
final class NativeFindReplaceIntegrationTests: XCTestCase {
    @MainActor
    func testShowFindReplace_InitialState_EmptyQueryDisablesActions() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha"

        vc.showFindReplace(nil)

        let findBar = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindBar", in: vc.view))
        XCTAssertFalse(findBar.isHidden)

        let replaceField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceField", in: vc.view) as? NSTextField)
        XCTAssertFalse(replaceField.isHidden)

        let replaceButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceButton", in: vc.view) as? NSButton)
        let replaceAllButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceAllButton", in: vc.view) as? NSButton)
        XCTAssertFalse(replaceButton.isHidden)
        XCTAssertFalse(replaceAllButton.isHidden)

        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)
        XCTAssertEqual(label.stringValue, "")

        let prev = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindPrevButton", in: vc.view) as? NSButton)
        let next = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindNextButton", in: vc.view) as? NSButton)
        XCTAssertFalse(prev.isEnabled)
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(replaceButton.isEnabled)
        XCTAssertFalse(replaceAllButton.isEnabled)
    }

    @MainActor
    func testShowFindReplace_AnchorsBarTopRight_WithCompactWidth() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        vc.view.layoutSubtreeIfNeeded()

        vc.showFindReplace(nil)
        vc.view.layoutSubtreeIfNeeded()

        let findBar = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindBar", in: vc.view))
        let margin: CGFloat = 12

        XCTAssertEqual(findBar.frame.maxX, vc.view.bounds.maxX - margin, accuracy: 1.0)
        XCTAssertEqual(findBar.frame.maxY, vc.view.bounds.maxY - margin, accuracy: 1.0)
        XCTAssertGreaterThan(findBar.frame.midX, vc.view.bounds.midX, "Find bar should sit on the right side, not centered")
        XCTAssertLessThanOrEqual(findBar.frame.width, 560.5, "Find/replace bar should remain compact")
    }

    @MainActor
    func testFindNextPrevious_Wraps_AndUpdatesLabelAndSelection() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha gamma alpha"

        vc.showFindReplace(nil)
        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("alpha", in: findField)

        // Typing a query should select the first match.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(label.stringValue, "1/3")

        // Second match.
        vc.findNext(nil)
        XCTAssertEqual(textView.selectedRange().length, 5)
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "alpha")
        XCTAssertEqual(label.stringValue, "2/3")

        // Third match.
        vc.findNext(nil)
        XCTAssertEqual(label.stringValue, "3/3")

        // Wraps to first.
        vc.findNext(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(label.stringValue, "1/3")

        // Previous from first wraps to last.
        vc.findPrevious(nil)
        XCTAssertEqual(label.stringValue, "3/3")
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "alpha")
    }

    @MainActor
    func testNoMatches_ShowsNoMatchesAndDisablesActions() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha"

        vc.showFindReplace(nil)

        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)
        let prev = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindPrevButton", in: vc.view) as? NSButton)
        let next = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindNextButton", in: vc.view) as? NSButton)
        let replaceButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceButton", in: vc.view) as? NSButton)
        let replaceAllButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceAllButton", in: vc.view) as? NSButton)

        try setFindQuery("zzz", in: findField)

        XCTAssertEqual(label.stringValue, "No matches")
        XCTAssertFalse(prev.isEnabled)
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(replaceButton.isEnabled)
        XCTAssertFalse(replaceAllButton.isEnabled)
    }

    @MainActor
    func testReplaceCurrent_ReplacesSelectedMatch_ThenAdvancesToNext() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha gamma alpha"

        vc.showFindReplace(nil)

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let replaceField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceField", in: vc.view) as? NSTextField)
        let replaceButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceButton", in: vc.view) as? NSButton)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("alpha", in: findField)
        replaceField.stringValue = "X"

        // Should start on first match, then replace it.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))

        replaceButton.performClick(nil)

        XCTAssertTrue(textView.string.hasPrefix("X beta "))
        XCTAssertFalse(textView.string.contains("alpha beta alpha gamma alpha"))

        // After replacement, remaining matches are 2; selection should move to the first remaining match.
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "alpha")
        XCTAssertEqual(label.stringValue, "1/2")
    }

    @MainActor
    func testReplaceAll_ReplacesAllMatches_ThenShowsNoMatches() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha gamma alpha"

        vc.showFindReplace(nil)

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let replaceField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceField", in: vc.view) as? NSTextField)
        let replaceAllButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceAllButton", in: vc.view) as? NSButton)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("alpha", in: findField)
        replaceField.stringValue = "X"

        replaceAllButton.performClick(nil)

        XCTAssertFalse(textView.string.contains("alpha"))
        XCTAssertTrue(textView.string.contains("X beta X gamma X"))
        XCTAssertEqual(label.stringValue, "No matches")
    }

    @MainActor
    func testReplaceAll_UsesNonOverlappingMatches() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "aaaa"

        vc.showFindReplace(nil)

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let replaceField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceField", in: vc.view) as? NSTextField)
        let replaceAllButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceAllButton", in: vc.view) as? NSButton)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("aa", in: findField)
        replaceField.stringValue = "b"

        // Non-overlapping matches in "aaaa" are: [0..2], [2..4] => 2 matches.
        XCTAssertEqual(label.stringValue, "1/2")

        replaceAllButton.performClick(nil)

        XCTAssertEqual(textView.string, "bb")
        XCTAssertEqual(label.stringValue, "No matches")
    }

    @MainActor
    func testReplaceAll_AllowsEmptyReplacement_DeletesMatches() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha"

        vc.showFindReplace(nil)

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let replaceField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceField", in: vc.view) as? NSTextField)
        let replaceAllButton = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.ReplaceAllButton", in: vc.view) as? NSButton)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("alpha", in: findField)
        replaceField.stringValue = ""

        replaceAllButton.performClick(nil)

        XCTAssertFalse(textView.string.contains("alpha"))
        XCTAssertEqual(label.stringValue, "No matches")
    }

    @MainActor
    func testCaseAndDiacriticInsensitiveDefaults_WorkViaFindBar() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "Cafe Café CAFÉ"

        vc.showFindReplace(nil)

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("cafe", in: findField)

        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "Cafe")
        XCTAssertEqual(label.stringValue, "1/3")
    }

    @MainActor
    func testEmojiQuery_UsesUtf16Ranges() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "a😀b😀a"

        vc.showFindReplace(nil)

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        try setFindQuery("😀", in: findField)

        // In UTF-16 indexing: "a" (0), first emoji starts at 1 and is length 2.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertEqual(label.stringValue, "1/2")

        vc.findNext(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 2))
        XCTAssertEqual(label.stringValue, "2/2")
    }

    @MainActor
    func testUseSelectionForFind_SeedsQueryAndSelectsMatch() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "alpha beta alpha"

        let textView = try XCTUnwrap(findTextView(in: vc.view))
        // Select "beta"
        textView.setSelectedRange(NSRange(location: 6, length: 4))

        vc.showFindReplace(nil)
        vc.useSelectionForFind(nil)

        let findField = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindField", in: vc.view) as? NSSearchField)
        let label = try XCTUnwrap(findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: vc.view) as? NSTextField)

        XCTAssertEqual(findField.stringValue, "beta")
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "beta")
        XCTAssertEqual(label.stringValue, "1/1")
    }

    // MARK: - View tree helpers

    @MainActor
    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
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

    @MainActor
    private func setFindQuery(_ query: String, in field: NSSearchField) throws {
        field.stringValue = query

        // Mirror real flow: user typing triggers the field action. In tests the controller applies
        // updates synchronously, but keep a short poll loop for robustness.
        _ = field.sendAction(field.action, to: field.target)
        let root = rootView(of: field)
        let settled = waitUntil(timeout: 0.05) {
            guard let label = self.findView(withAccessibilityIdentifier: "NativeEditor.FindMatchLabel", in: root) as? NSTextField else { return false }
            // "Empty query" is not used by this helper; once a non-empty query is set we should
            // either show match counts or "No matches".
            return !label.stringValue.isEmpty
        }
        if !settled {
            // Keep old behavior as a fallback if the field is not in a window-backed hierarchy yet.
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
    }

    @MainActor
    private func rootView(of view: NSView) -> NSView {
        var current = view
        while let parent = current.superview {
            current = parent
        }
        return current
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, pollEvery: TimeInterval = 0.01, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollEvery))
        }
        return condition()
    }
}
