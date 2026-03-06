import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorBulletTaskInputRuleTests: XCTestCase {
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
    func testTypingTaskMarkerAfterStarBulletConvertsToTask() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = ""

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView,
              let storage = textView.textStorage else {
            XCTFail("Missing NativeEditor.TextView/text storage")
            return
        }

        textView.insertText("* ", replacementRange: textView.selectedRange())
        textView.insertText("[ ] item", replacementRange: textView.selectedRange())
        vc.flushPendingExport()

        let para = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        XCTAssertEqual(kind, .task)
    }

    @MainActor
    func testTypingTaskMarkerAfterPlusBulletConvertsToTask() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = ""

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView,
              let storage = textView.textStorage else {
            XCTFail("Missing NativeEditor.TextView/text storage")
            return
        }

        textView.insertText("+ ", replacementRange: textView.selectedRange())
        textView.insertText("[ ] item", replacementRange: textView.selectedRange())
        vc.flushPendingExport()

        let para = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let kindRaw = storage.attribute(.kernBlockKind, at: para.location, effectiveRange: nil) as? Int
        let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
        XCTAssertEqual(kind, .task)
    }

    @MainActor
    func testOrderedTaskTypingAndEnterContinuationRoundTripsAsOrderedTasks() throws {
        try withTemporaryDefaults([
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.exportDialect": "gfm",
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
            XCTAssertTrue(
                exported.contains("1. [ ] one") || exported.contains("1. ☐ one"),
                "Unexpected ordered-task export:\n\(exported)"
            )
            XCTAssertTrue(
                exported.contains("2. [ ] two") || exported.contains("2. ☐ two"),
                "Unexpected ordered-task export:\n\(exported)"
            )
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

    @MainActor
    func testNestedOrderedItemCanSwitchToNestedBulletTaskByTypingMarkerShortcuts() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "1. parent\n   1. child\n"

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        moveCaretToSubstringStart("child", in: textView)
        textView.insertText("- [ ] ", replacementRange: textView.selectedRange())

        vc.flushPendingExport()
        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(
            exported.contains("1. parent\n   - [ ] child\n") || exported.contains("1. parent\n   - ☐ child\n"),
            "Expected nested ordered -> nested bullet task conversion. got=\(exported)"
        )
    }

    @MainActor
    func testNestedBulletItemCanSwitchToNestedOrderedTaskByTypingMarkerShortcuts() throws {
        try withTemporaryDefaults([
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.exportDialect": "gfm",
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "- parent\n  - child\n"

            let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
            window.displayIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }

            moveCaretToSubstringStart("child", in: textView)
            textView.insertText("1. [ ] ", replacementRange: textView.selectedRange())

            vc.flushPendingExport()
            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(
                exported.contains("- parent\n  1. [ ] child\n") || exported.contains("- parent\n  1. ☐ child\n"),
                "Expected nested bullet -> nested ordered task conversion. got=\(exported)"
            )
        }
    }

    @MainActor
    func testNestedTaskBackspaceAtMarkerBoundaryStillAllowsTypingAndNewline() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "1. parent\n   - [ ] child\n"

        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NativeMarkdownTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        moveCaretToSubstringStart("child", in: textView)
        let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled, "Expected nested task backspace at list body start to be handled by list command path.")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        textView.insertText("z", replacementRange: textView.selectedRange())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        textView.insertNewline(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        textView.insertText("next", replacementRange: textView.selectedRange())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        vc.flushPendingExport()
        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertTrue(exported.contains("z"), "Expected typing recovery after nested task backspace. got=\(exported)")
        XCTAssertTrue(exported.contains("next"), "Expected newline recovery after nested task backspace. got=\(exported)")
    }

    @MainActor
    func testNestedOrderedTaskCanSwitchToNestedBulletTaskViaMarkerShortcut() throws {
        try withTemporaryDefaults([
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.exportDialect": "gfm",
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "1. parent\n   1. [ ] child\n"

            let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
            window.displayIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }

            moveCaretToSubstringStart("child", in: textView)
            textView.insertText("- [ ] ", replacementRange: textView.selectedRange())

            vc.flushPendingExport()
            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(
                exported.contains("1. parent\n   - [ ] child\n") || exported.contains("1. parent\n   - ☐ child\n"),
                "Expected nested ordered-task -> nested bullet-task conversion. got=\(exported)"
            )
        }
    }

    @MainActor
    func testNestedOrderedTaskBackspaceAtMarkerBoundaryStillAllowsTypingAndNewline() throws {
        try withTemporaryDefaults([
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.exportDialect": "gfm",
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "1. parent\n   1. [ ] child\n"

            let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
            window.displayIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NativeMarkdownTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }

            moveCaretToSubstringStart("child", in: textView)
            let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
            XCTAssertTrue(handled, "Expected nested ordered-task backspace at list body start to be handled by list command path.")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            textView.insertText("z", replacementRange: textView.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            textView.insertNewline(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            textView.insertText("next", replacementRange: textView.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

            vc.flushPendingExport()
            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(exported.contains("z"), "Expected typing recovery after nested ordered-task backspace. got=\(exported)")
            XCTAssertTrue(exported.contains("next"), "Expected newline recovery after nested ordered-task backspace. got=\(exported)")
        }
    }

    @MainActor
    func testHeadingTaskEnterThenListAndNestedTaskTypingWorks() throws {
        try withTemporaryDefaults([
            "nativeEditor.headingCheckboxesEnabled": true,
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.exportDialect": "gfm",
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "## [ ] Heading task"

            let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
            window.displayIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }

            moveCaretToEnd(textView)
            textView.insertNewline(nil)
            textView.insertText("1. parent", replacementRange: textView.selectedRange())
            textView.insertNewline(nil)
            textView.insertText("- [ ] child", replacementRange: textView.selectedRange())

            vc.flushPendingExport()
            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(exported.contains("## [ ] Heading task") || exported.contains("## ☐ Heading task"))
            XCTAssertTrue(exported.contains("1. parent"))
            XCTAssertTrue(
                exported.contains("- [ ] child") || exported.contains("- ☐ child"),
                "Expected nested task typing after heading task. got=\(exported)"
            )
        }
    }

    @MainActor
    func testOrderedTaskMarkerDeleteViaArrowNavigationStillAllowsTypingAndNewline() throws {
        try withTemporaryDefaults([
            "nativeEditor.orderedTasksEnabled": true,
            "nativeEditor.taskRendering": "gfm",
            "nativeEditor.exportDialect": "gfm",
        ]) {
            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = "1. [ ] alpha\n"

            let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
            window.displayIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NativeMarkdownTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }

            moveCaretToSubstringStart("alpha", in: textView)
            textView.moveLeft(nil)
            textView.moveLeft(nil)
            textView.moveLeft(nil)
            _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
            textView.insertText("z", replacementRange: textView.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            textView.insertNewline(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            textView.insertText("next", replacementRange: textView.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

            vc.flushPendingExport()
            let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
            XCTAssertTrue(exported.contains("z"), "Expected typing recovery after ordered-task marker mutation. got=\(exported)")
            XCTAssertTrue(exported.contains("next"), "Expected newline recovery after ordered-task marker mutation. got=\(exported)")
        }
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

    @MainActor
    private func moveCaretToSubstringStart(_ needle: String, in textView: NSTextView) {
        let ns = textView.string as NSString
        let range = ns.range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(needle)'")
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    @MainActor
    private func moveCaretToEnd(_ textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        var effectiveOverrides = overrides
        if effectiveOverrides[NativeEditorSyntaxVisibilityMode.userDefaultsKey] == nil {
            effectiveOverrides[NativeEditorSyntaxVisibilityMode.userDefaultsKey] = NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue
        }
        var saved: [String: Any?] = [:]
        for (key, value) in effectiveOverrides {
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
