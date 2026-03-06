import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorTypingReliabilityTests: XCTestCase {
    private var savedSyntaxVisibilityMode: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSyntaxVisibilityMode = defaults.object(forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedSyntaxVisibilityMode {
            defaults.set(savedSyntaxVisibilityMode, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        } else {
            defaults.removeObject(forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        }
        super.tearDown()
    }

    @MainActor
    func testTaskListContinuationAcrossFlushBoundary() {
        let (vc, textView, window) = makeController(markdown: "- [ ] one")
        _ = window
        moveCaretToEnd(textView)

        textView.insertNewline(nil)
        textView.insertText("two", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()
        drainMainRunLoop()

        let afterInsert = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(afterInsert.contains("- [ ] one"))
        XCTAssertTrue(afterInsert.contains("- [ ] two"))
    }

    @MainActor
    func testSpaceCheckboxToggleAcrossFlushBoundary() {
        let (vc, textView, window) = makeController(markdown: "- [ ] task")
        _ = window

        guard let storage = textView.textStorage,
              let checkboxIndex = firstCheckboxIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
            XCTFail("Expected checkbox glyph in task markdown")
            return
        }

        textView.setSelectedRange(NSRange(location: checkboxIndex, length: 0))
        textView.insertText(" ", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()
        drainMainRunLoop()

        let checked = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(checked.contains("- [x] task") || checked.contains("- [X] task"))

        if let storage = textView.textStorage,
           let toggledCheckboxIndex = firstCheckboxIndex(in: storage, range: NSRange(location: 0, length: storage.length)) {
            textView.setSelectedRange(NSRange(location: toggledCheckboxIndex, length: 0))
        }
        textView.insertText(" ", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()
        drainMainRunLoop()
        let uncheckedAgain = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(uncheckedAgain.contains("- [ ] task"))
    }

    @MainActor
    func testShiftEnterPreservesInlineStyleAcrossSoftBreak() {
        let (vc, textView, window) = makeController(markdown: "- [ ] **bold**")
        _ = window
        moveCaretToEnd(textView)

        textView.insertLineBreak(nil) // Shift+Enter path
        textView.insertText("more", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()
        drainMainRunLoop()

        let ns = textView.string as NSString
        let boldRange = ns.range(of: "bold")
        let moreRange = ns.range(of: "more")
        XCTAssertNotEqual(boldRange.location, NSNotFound)
        XCTAssertNotEqual(moreRange.location, NSNotFound)
        guard boldRange.location != NSNotFound, moreRange.location != NSNotFound else { return }

        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }
        let boldStrong = (storage.attribute(.kernStrong, at: boldRange.location, effectiveRange: nil) as? Bool) ?? false
        let moreStrong = (storage.attribute(.kernStrong, at: moreRange.location, effectiveRange: nil) as? Bool) ?? false
        XCTAssertTrue(boldStrong, "Baseline bold span should remain strong")
        XCTAssertTrue(moreStrong, "Typing after Shift+Enter should preserve inline style")
    }

    @MainActor
    func testCodeBlockSelectionSuppressesSpellcheckAndRestoresForParagraphs() {
        let markdown = """
        ```swift
        let value = 1
        ```

        paragraph
        """
        let (vc, textView, window) = makeController(markdown: markdown)
        _ = (vc, window)

        moveCaretToSubstringStart("value", in: textView)
        drainMainRunLoop()
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)

        moveCaretToSubstringStart("paragraph", in: textView)
        drainMainRunLoop()
        XCTAssertTrue(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertTrue(textView.isContinuousSpellCheckingEnabled)
    }

    @MainActor
    func testApplyExternalMarkdownUpdatePreservesUTF16SelectionLocation() {
        let markdown = "😀😀"
        let (vc, textView, window) = makeController(markdown: markdown)
        _ = window

        let utf16Location = markdown.utf16.count
        textView.setSelectedRange(NSRange(location: utf16Location, length: 0))
        vc.applyExternalMarkdownUpdate(markdown)
        drainMainRunLoop()

        XCTAssertEqual(
            textView.selectedRange().location,
            utf16Location,
            "Selection restore should clamp against UTF-16 length, not grapheme count"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(markdown: String) -> (NativeEditorViewController, NativeMarkdownTextView, NSWindow) {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()
        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        _ = window.makeFirstResponder(textView)
        drainMainRunLoop()
        return (vc, textView, window)
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
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView { return tv }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private func moveCaretToEnd(_ textView: NativeMarkdownTextView) {
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    @MainActor
    private func moveCaretToSubstringStart(_ needle: String, in textView: NativeMarkdownTextView) {
        let ns = textView.string as NSString
        let range = ns.range(of: needle)
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    private func firstCheckboxIndex(in storage: NSTextStorage, range: NSRange) -> Int? {
        var out: Int?
        storage.enumerateAttribute(.kernCheckbox, in: range, options: []) { value, r, stop in
            if (value as? Bool) == true {
                out = r.location
                stop.pointee = true
            }
        }
        return out
    }

    @MainActor
    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
