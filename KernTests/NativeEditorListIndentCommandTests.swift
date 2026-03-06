import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorListIndentCommandTests: XCTestCase {
    @MainActor
    func testTabAndShiftTabAdjustBulletNestingAndTopLevelOutdentUnlists() {
        let (vc, textView, window) = makeController(markdown: "- one\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("one", in: textView)
        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()

        var exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "  - one\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "- one\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "one\n")
    }

    @MainActor
    func testTabAndShiftTabApplyAcrossMultiParagraphListSelection() {
        let (vc, textView, window) = makeController(markdown: "- one\n- two\n")
        defer { closeHostedEditor(window) }

        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()

        var exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "  - one\n  - two\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "- one\n- two\n")
    }

    @MainActor
    func testTabAndShiftTabAdjustOrderedNestingAndTopLevelOutdentUnlists() {
        let (vc, textView, window) = makeController(markdown: "1. one\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("one", in: textView)
        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()

        var exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "   1. one\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "1. one\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "one\n")
    }

    @MainActor
    func testTabAndShiftTabAdjustTaskNestingAndTopLevelOutdentUnlists() {
        let (vc, textView, window) = makeController(markdown: "- [ ] one\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("one", in: textView)
        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()

        var exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "  - [ ] one\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "- [ ] one\n")

        XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        drainMainRunLoop()
        vc.flushPendingExport()
        exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "one\n")
    }

    @MainActor
    func testTypingAndNewlineRecoverWhenCaretMovesIntoOrderedMarkerAfterManualMarkerDelete() {
        let (vc, textView, window) = makeController(markdown: "1. alpha\n")
        defer { closeHostedEditor(window) }

        guard let storage = textView.textStorage,
              let markerIndex = firstMarkerIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
            XCTFail("Expected ordered list marker")
            return
        }

        textView.insertText("", replacementRange: NSRange(location: markerIndex, length: 1))
        textView.setSelectedRange(NSRange(location: markerIndex, length: 0))
        textView.insertText("z", replacementRange: textView.selectedRange())
        drainMainRunLoop()

        textView.insertNewline(nil)
        textView.insertText("next", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("z"), "Expected typing to recover after marker edit. got=\(exported)")
        XCTAssertTrue(exported.contains("next"), "Expected newline + typing to remain functional. got=\(exported)")
    }

    @MainActor
    func testTypingListShortcutInsideOrderedItemConvertsToBulletItem() {
        let (vc, textView, window) = makeController(markdown: "1. alpha\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("alpha", in: textView)
        textView.insertText("-", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "- alpha\n")
    }

    @MainActor
    func testOrderedMarkerDeleteViaArrowNavigationStillAllowsTypingAndNewline() {
        let (vc, textView, window) = makeController(markdown: "1. alpha\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("alpha", in: textView)
        textView.moveLeft(nil)
        textView.moveLeft(nil)
        textView.deleteBackward(nil)
        drainMainRunLoop()

        textView.insertText("z", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertText("next", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("z"), "Expected typing recovery after marker mutation. got=\(exported)")
        XCTAssertTrue(exported.contains("next"), "Expected newline and typing to keep working. got=\(exported)")
    }

    @MainActor
    func testTypingListShortcutInsideLaterOrderedItemConvertsToBulletItem() {
        let (vc, textView, window) = makeController(markdown: "1. one\n2. alpha\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("alpha", in: textView)
        textView.insertText("-", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(exported, "1. one\n- alpha\n")
    }

    @MainActor
    func testNewlineStillWorksAfterDeletingInsideOrderedMarkerRegion() {
        let (vc, textView, window) = makeController(markdown: "1. alpha\n")
        defer { closeHostedEditor(window) }

        guard let storage = textView.textStorage,
              let markerIndex = firstMarkerIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
            XCTFail("Expected ordered list marker")
            return
        }

        textView.insertText("", replacementRange: NSRange(location: markerIndex, length: 1))
        textView.setSelectedRange(NSRange(location: markerIndex, length: 0))
        textView.insertNewline(nil)
        textView.insertText("next", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("next"), "Expected newline + typing to remain functional. got=\(exported)")
    }

    @MainActor
    func testBackspaceAtNestedBulletContentStartOutdentsBeforeUnlisting() {
        let (vc, textView, window) = makeController(markdown: "1. parent\n   - child\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("child", in: textView)
        _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(
            exported.contains("  - child") || exported.contains("- child"),
            "Expected nested bullet to outdent (not fully unlist) on first backspace. got=\(exported)"
        )
    }

    @MainActor
    func testBackspaceAtNestedOrderedContentStartOutdentsBeforeUnlisting() {
        let (vc, textView, window) = makeController(markdown: "1. parent\n   1. child\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("child", in: textView)
        _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(
            exported.contains("1. child") || exported.contains("2. child"),
            "Expected nested ordered item to remain ordered after first backspace (outdent behavior). got=\(exported)"
        )
    }

    @MainActor
    func testBackspaceAtNestedTaskContentStartOutdentsBeforeUnlisting() {
        let (vc, textView, window) = makeController(markdown: "1. parent\n   - [ ] child\n")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("child", in: textView)
        _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(
            exported.contains("- [ ] child") || exported.contains("- ☐ child"),
            "Expected nested task to outdent and stay task on first backspace. got=\(exported)"
        )
    }

    @MainActor
    func testSecondEnterExitsBulletListContextToParagraph() {
        let (vc, textView, window) = makeController(markdown: "- one")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("one", in: textView)
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location + 3, length: 0))
        textView.insertNewline(nil) // continue bullet
        textView.insertNewline(nil) // exit from empty bullet
        textView.insertText("after", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("- one"))
        XCTAssertTrue(exported.contains("after"))
        XCTAssertFalse(exported.contains("- after"), "Expected second Enter to exit bullet list context. got=\(exported)")
    }

    @MainActor
    func testSecondEnterExitsOrderedTaskListContextToParagraph() {
        let defaults = UserDefaults.standard
        let keys = ["nativeEditor.orderedTasksEnabled", "nativeEditor.taskRendering", "nativeEditor.exportDialect"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: "nativeEditor.orderedTasksEnabled")
        defaults.set("gfm", forKey: "nativeEditor.taskRendering")
        defaults.set("gfm", forKey: "nativeEditor.exportDialect")
        defer {
            for (idx, key) in keys.enumerated() {
                if let prev = previous[idx] {
                    defaults.set(prev, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let (vc, textView, window) = makeController(markdown: "1. [ ] one")
        defer { closeHostedEditor(window) }

        moveCaretToSubstringStart("one", in: textView)
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location + 3, length: 0))
        textView.insertNewline(nil) // continue ordered task
        textView.insertNewline(nil) // exit from empty ordered task
        textView.insertText("after", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        vc.flushPendingExport()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("1. [ ] one") || exported.contains("1. ☐ one"))
        XCTAssertTrue(exported.contains("after"))
        XCTAssertFalse(exported.contains("2. [ ] after"), "Expected second Enter to exit ordered-task context. got=\(exported)")
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
    private func closeHostedEditor(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
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
    private func moveCaretToSubstringStart(_ needle: String, in textView: NativeMarkdownTextView) {
        let ns = textView.string as NSString
        let range = ns.range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(needle)'")
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    private func firstMarkerIndex(in storage: NSTextStorage, range: NSRange) -> Int? {
        var out: Int?
        storage.enumerateAttribute(.kernMarker, in: range, options: []) { value, r, stop in
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
