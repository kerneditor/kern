import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorUndoAutosaveTests: XCTestCase {
    @MainActor
    func testUndoAcrossFlushBoundariesReturnsOriginalContent() {
        let (vc, textView, window) = makeController(markdown: "Alpha")
        _ = window
        moveCaretToEnd(textView)

        insertAndFlush(" beta", in: textView, controller: vc)
        insertAndFlush("\nGamma", in: textView, controller: vc)
        insertAndFlush("\nDelta", in: textView, controller: vc)

        XCTAssertEqual(textView.string, "Alpha beta\nGamma\nDelta")

        undoAll(in: textView, maxSteps: 12)
        vc.flushPendingExport()
        drainMainRunLoop()

        XCTAssertEqual(textView.string, "Alpha")
        XCTAssertEqual(vc.stringValue, "Alpha")
    }

    @MainActor
    func testRedoAcrossFlushBoundariesReappliesLatestContent() {
        let (vc, textView, window) = makeController(markdown: "Alpha")
        _ = window
        moveCaretToEnd(textView)

        insertAndFlush(" beta", in: textView, controller: vc)
        insertAndFlush("\nGamma", in: textView, controller: vc)
        insertAndFlush("\nDelta", in: textView, controller: vc)

        undoAll(in: textView, maxSteps: 12)
        redoAll(in: textView, maxSteps: 12)
        vc.flushPendingExport()
        drainMainRunLoop()

        XCTAssertEqual(textView.string, "Alpha beta\nGamma\nDelta")
        XCTAssertEqual(vc.stringValue, "Alpha beta\n\nGamma\n\nDelta")
    }

    @MainActor
    func testBulkPasteRehydrateKeepsUndoBackToBaseline() {
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousForcePlain = getenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousAllowPlain = getenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE").map { String(cString: $0) }
        setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", "1", 1)
        unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
        unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")
        defer {
            if let previousForceFull {
                setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", previousForceFull, 1)
            } else {
                unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
            }
            if let previousForcePlain {
                setenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT", previousForcePlain, 1)
            } else {
                unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
            }
            if let previousAllowPlain {
                setenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE", previousAllowPlain, 1)
            } else {
                unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")
            }
        }

        let (vc, textView, window) = makeController(markdown: "Start")
        _ = window
        moveCaretToEnd(textView)

        let pasted = """
        \n### Paste Heading

        Paragraph with **bold** text.
        """
        textView._debugPastePlainStringForTests(pasted)
        vc.flushPendingExport()
        drainMainRunLoop()

        XCTAssertTrue(textView.string.contains("Paste Heading"))
        XCTAssertFalse(textView.string.contains("### Paste Heading"))
        XCTAssertFalse(textView.string.contains("**bold**"))

        guard let undoManager = textView.undoManager else {
            XCTFail("Missing undo manager")
            return
        }
        XCTAssertFalse(
            undoManager.canUndo,
            "Semantic rehydrate can invalidate stale pre-import ranges; undo stack should reset safely."
        )

        textView.insertText("!", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        XCTAssertTrue(undoManager.canUndo, "Undo should work for edits after rehydrate reset")
        undoManager.undo()
        drainMainRunLoop()

        XCTAssertFalse(textView.string.hasSuffix("!"))
        vc.flushPendingExport()
        drainMainRunLoop()
        XCTAssertTrue(vc.stringValue.contains("Paste Heading"))
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
        if let tv = view as? NativeMarkdownTextView {
            return tv
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private func moveCaretToEnd(_ textView: NativeMarkdownTextView) {
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    @MainActor
    private func insertAndFlush(_ text: String, in textView: NativeMarkdownTextView, controller: NativeEditorViewController) {
        textView.insertText(text, replacementRange: textView.selectedRange())
        drainMainRunLoop()
        controller.flushPendingExport()
        drainMainRunLoop()
    }

    @MainActor
    private func undoAll(in textView: NativeMarkdownTextView, maxSteps: Int) {
        guard let undoManager = textView.undoManager else { return }
        for _ in 0..<maxSteps where undoManager.canUndo {
            undoManager.undo()
            drainMainRunLoop()
        }
    }

    @MainActor
    private func redoAll(in textView: NativeMarkdownTextView, maxSteps: Int) {
        guard let undoManager = textView.undoManager else { return }
        for _ in 0..<maxSteps where undoManager.canRedo {
            undoManager.redo()
            drainMainRunLoop()
        }
    }

    @MainActor
    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
