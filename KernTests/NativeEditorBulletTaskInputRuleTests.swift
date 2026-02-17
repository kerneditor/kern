import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorBulletTaskInputRuleTests: XCTestCase {
    @MainActor
    func testTypingTaskMarkerAfterBulletConvertsToTask() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = ""

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        // Type "- " which immediately converts to a bullet, then type a task shortcut at the start
        // of the bullet body ("[ ] item") which should convert the block into a task list item.
        textView.insertText("- ", replacementRange: textView.selectedRange())
        textView.insertText("[ ] item", replacementRange: textView.selectedRange())

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        XCTAssertGreaterThan(para.length, 0)

        let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        XCTAssertEqual(kind, .task)

        XCTAssertFalse(storage.string.contains("[ ]"), "Literal task syntax should be hidden in WYSIWYG")

        XCTAssertNotNil(firstCheckboxIndex(in: storage, range: para), "Expected a checkbox marker in the task item")
    }

    @MainActor
    func testTypingCheckedTaskMarkerAfterBulletConvertsToCheckedTask() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = ""

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let storage = textView.textStorage else {
            XCTFail("Missing text storage")
            return
        }

        textView.insertText("- ", replacementRange: textView.selectedRange())
        textView.insertText("[x] done", replacementRange: textView.selectedRange())

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        XCTAssertGreaterThan(para.length, 0)

        let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        XCTAssertEqual(kind, .task)

        guard let checkboxIndex = firstCheckboxIndex(in: storage, range: para) else {
            XCTFail("Expected a checkbox marker")
            return
        }
        let checked = (storage.attribute(.kernCheckboxChecked, at: checkboxIndex, effectiveRange: nil) as? Bool) ?? false
        XCTAssertTrue(checked, "Expected the task to be checked when typing [x]")
    }

    @MainActor
    func testOrderedTaskTypingAndEnterContinuationRoundTripsAsOrderedTasks() throws {
        try withTemporaryDefaults([
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.taskRendering": "gfm",
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = ""

            let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
            window.displayIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }
            guard let storage = textView.textStorage else {
                XCTFail("Missing text storage")
                return
            }

            textView.insertText("1. ", replacementRange: textView.selectedRange())
            textView.insertText("[ ] one", replacementRange: textView.selectedRange())
            textView.insertNewline(nil)
            textView.insertText("two", replacementRange: textView.selectedRange())
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            textView.insertText("after", replacementRange: textView.selectedRange())

            vc.view.layoutSubtreeIfNeeded()
            vc.viewDidLayout()

            let ns = storage.string as NSString
            let para = ns.paragraphRange(for: NSRange(location: 0, length: 0))
            let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            XCTAssertEqual(kind, .ordered, "Expected first line to remain an ordered block")

            let isTask = (storage.attribute(.kernOrderedIsTask, at: para.location, effectiveRange: nil) as? Bool) ?? false
            XCTAssertTrue(isTask, "Expected first ordered line to be marked as an ordered task")

            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(exported.contains("1. [ ] one"), "Unexpected ordered-task export:\n\(exported)")
            XCTAssertTrue(exported.contains("2. [ ] two"), "Unexpected ordered-task export:\n\(exported)")
            XCTAssertTrue(exported.contains("after"))
            XCTAssertFalse(exported.contains("3. [ ] "), "Second Enter should exit ordered-task continuation")
        }
    }

    @MainActor
    func testBlockquoteEnterContinuesThenSecondEnterExitsQuoteContext() throws {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = ""

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        textView.insertText("> quote", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertText("continued", replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        textView.insertText("after", replacementRange: textView.selectedRange())

        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()

        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("> quote"))
        XCTAssertTrue(exported.contains("> continued"))
        XCTAssertTrue(exported.contains("after"))
        XCTAssertFalse(exported.contains("\n> \n"), "Second Enter should exit the quote instead of leaving an empty quote marker line")
    }

    // MARK: - Helpers

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

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        var saved: [String: Any?] = [:]
        for (key, value) in overrides {
            saved[key] = defaults.object(forKey: key)
            defaults.set(value, forKey: key)
        }
        defer {
            for (key, previous) in saved {
                if let previous {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        return try body()
    }
}
