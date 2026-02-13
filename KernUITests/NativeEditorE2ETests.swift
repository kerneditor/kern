import AppKit
import XCTest
import ApplicationServices
import CoreGraphics

final class NativeEditorE2ETests: XCTestCase {

    func testTodoShortcutConvertsAndExportsMarkdown() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-todo")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        textView.typeText("[] todo")

        // UI should show a checkbox glyph (WYSIWYG) rather than the literal "[] ".
        let value = (textView.value as? String) ?? ""
        XCTAssertTrue(value.contains("☐ todo"))
        attachScreenshot(name: "todo-shortcut", element: textView)

        // Toggle via keyboard (space on checkbox) to avoid flaky click hit testing.
        toggleCheckboxAtLineStart(textView)
        let toggledValue = (textView.value as? String) ?? ""
        XCTAssertTrue(toggledValue.contains("☑ todo"))
        attachScreenshot(name: "todo-toggled", element: textView)

        // Exit list/item context.
        textView.typeText("\n\n")

        try save(app: app)

        // Disk should contain standard GFM tasks for interoperability.
        let saved = try waitForFileContains(tmp, substring: "- [x] todo", timeout: 5)
        XCTAssertTrue(saved.contains("- [x] todo"))
        XCTAssertFalse(saved.contains("- [ ] \n"), "Should not persist an empty marker-only task item")
    }

    func testKernDialectExportsStandaloneTasksAsBracketOnly() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-kern-dialect-task")

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_EXPORT_DIALECT": "kern",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        textView.typeText("[] todo")

        // Toggle via keyboard (space on checkbox) to avoid flaky click hit testing.
        toggleCheckboxAtLineStart(textView)

        // Exit list to avoid persisting an empty marker-only item.
        textView.typeText("\n\n")

        attachScreenshot(name: "kern-dialect-standalone-task", element: textView)
        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "[x] todo", timeout: 5)
        XCTAssertTrue(saved.contains("[x] todo"))
        XCTAssertFalse(saved.contains("- [x] todo"))
    }

    func testOrderedListAutoContinues() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-ordered")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        textView.typeText("1. one\n")

        // Pressing Enter on a non-empty ordered item should create the next item.
        textView.typeText("two\n\n") // second Enter exits list (empty item)
        attachScreenshot(name: "ordered-list", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "1. one", timeout: 5)
        XCTAssertTrue(saved.contains("1. one"))
        XCTAssertTrue(saved.contains("2. two"))
        XCTAssertFalse(saved.contains("3. \n"), "Should not persist an empty marker-only ordered item")
    }

    func testTaskRenderingKernShowsBulletDotForBulletedTasks() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-task-rendering")
        try "- [ ] item\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_TASK_RENDERING": "kern",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "kern task rendering should show bullet+checkbox"
        ) { v in
            v.contains("• ☐ item")
        }
        XCTAssertTrue(value.contains("• ☐ item"))
        attachScreenshot(name: "task-rendering-kern", element: textView)

        try save(app: app)
        let saved = try waitForFileContains(tmp, substring: "- [ ] item", timeout: 5)
        XCTAssertTrue(saved.contains("- [ ] item"))
    }

    func testTaskRenderingGfmDoesNotShowBulletDotByDefault() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-task-rendering-gfm")
        try "- [ ] item\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_TASK_RENDERING": "gfm",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "gfm task rendering should show checkbox"
        ) { v in
            v.contains("☐ item")
        }
        XCTAssertTrue(value.contains("☐ item"))
        XCTAssertFalse(value.contains("•"), "GFM-style task rendering should not show a bullet dot")
        attachScreenshot(name: "task-rendering-gfm", element: textView)

        try save(app: app)
        let saved = try waitForFileContains(tmp, substring: "- [ ] item", timeout: 5)
        XCTAssertTrue(saved.contains("- [ ] item"))
    }

    func testHeadingExitsToParagraphOnEnter() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-heading")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        textView.typeText("# Title\nBody\n")

        // WYSIWYG should hide the "# " prefix in the editor.
        let value = (textView.value as? String) ?? ""
        XCTAssertFalse(value.contains("# Title"))
        XCTAssertTrue(value.contains("Title"))
        XCTAssertTrue(value.contains("Body"))
        attachScreenshot(name: "heading-exit", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "# Title", timeout: 5)
        XCTAssertTrue(saved.contains("# Title"))
        XCTAssertTrue(saved.contains("Body"))
    }

    func testOrderedTasksEnabledRendersAndExportsOrderedTasks() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-ordered-task")
        try """
        1. [ ] one
        2. [x] two
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_ORDERED_TASKS": "1",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "ordered tasks should render as WYSIWYG checkboxes"
        ) { v in
            v.contains("1. ☐ one") && v.contains("2. ☑ two")
        }
        XCTAssertTrue(value.contains("1. ☐ one"))
        XCTAssertTrue(value.contains("2. ☑ two"))
        attachScreenshot(name: "ordered-tasks-enabled", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "1. [ ] one", timeout: 5)
        XCTAssertTrue(saved.contains("2. [x] two"))
    }

    func testHeadingCheckboxesEnabledRendersAndExportsHeadingTasks() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-heading-task")
        try "## [ ] Heading todo\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_HEADING_CHECKBOXES": "1",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "checkbox heading should render as WYSIWYG checkbox"
        ) { v in
            v.contains("☐ Heading todo")
        }
        XCTAssertTrue(value.contains("☐ Heading todo"))
        XCTAssertFalse(value.contains("[ ] Heading todo"))
        attachScreenshot(name: "heading-checkbox-enabled", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "## [ ] Heading todo", timeout: 5)
        XCTAssertTrue(saved.contains("## [ ] Heading todo"))
    }

    func testBulletListContinuesAndExitsOnBlankItem() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-bullets")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        textView.typeText("- one\n")
        textView.typeText("two\n\n") // second Enter exits list

        let value = (textView.value as? String) ?? ""
        XCTAssertTrue(value.contains("• one"))
        XCTAssertTrue(value.contains("• two"))
        attachScreenshot(name: "bullet-exit", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "- one", timeout: 5)
        XCTAssertTrue(saved.contains("- one"))
        XCTAssertTrue(saved.contains("- two"))
        XCTAssertFalse(saved.contains("\n- \n"), "Should not persist an empty marker-only bullet item")
    }

    func testShiftEnterInBulletDoesNotContinueList() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-shift-enter")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        textView.typeText("- one")
        // GitHub-style: Shift+Enter escapes list continuation and inserts a line break.
        textView.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.shift])
        textView.typeText("two\n\n") // Enter creates a new list item, second Enter exits list.

        attachScreenshot(name: "shift-enter-bullet", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "- one", timeout: 5)
        XCTAssertTrue(saved.contains("- one\\\n  two"))
        XCTAssertFalse(saved.contains("- two"))
    }

    func testCodeBlockCopyButtonCopiesWholeBlock() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-code")
        try """
        ```js
        console.log("hi")
        console.log(2)
        ```
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        // Click near the top-left of the editor; this file starts with a code block.
        // This should put the caret in the code block and reveal the copy button.
        clickAtOffset(textView, x: 40, y: 40)

        let copyButton = app.buttons["NativeEditor.CodeCopyButton"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(copyButton.isHittable)
        attachScreenshot(name: "code-copy-visible", element: textView)

        NSPasteboard.general.clearContents()
        copyButton.click()

        // Copy should include the contiguous code block text (no fences).
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("console.log(\"hi\")"))
        XCTAssertTrue(copied.contains("console.log(2)"))
    }

    func testTypedTableConvertsAndExportsGfmTable() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-table-typed")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        // Type a minimal GFM table and press Enter after the first body row to trigger conversion.
        textView.typeText("| A | B |\n| --- | --- |\n| c | d |\n")

        let value = waitForTextViewValue(
            textView,
            timeout: 2.0,
            description: "table conversion hides delimiter row"
        ) { v in
            v.contains("A") && v.contains("B") && v.contains("c") && v.contains("d") && !v.contains("| ---")
        }
        XCTAssertFalse(value.contains("|"), "WYSIWYG should hide table pipe syntax after conversion")
        attachScreenshot(name: "typed-table-converted", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "| A | B |", timeout: 5)
        XCTAssertTrue(saved.contains("| --- | --- |"))
        XCTAssertTrue(saved.contains("| c | d |"))
    }

    func testOpenFileWithGfmTableRendersWysiwygAndExportsStable() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-table-open")
        try """
        Before paragraph.

        | H1 | H2 |
        | --- | --- |
        | r1c1 | r1c2 |

        After paragraph.
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "table import renders as WYSIWYG (no pipe syntax)"
        ) { v in
            v.contains("Before paragraph.") && v.contains("H1") && v.contains("H2") && v.contains("r1c1") && v.contains("r1c2") && !v.contains("| ---")
        }
        XCTAssertFalse(value.contains("|"), "WYSIWYG should not show table pipe syntax")
        attachScreenshot(name: "open-table-render", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "| H1 | H2 |", timeout: 5)
        XCTAssertTrue(saved.contains("| --- | --- |"))
        XCTAssertTrue(saved.contains("| r1c1 | r1c2 |"))
        XCTAssertTrue(saved.contains("Before paragraph."))
        XCTAssertTrue(saved.contains("After paragraph."))
    }

    func testGfmLintRewritesHeadingCheckboxesOnSave() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-gfm-lint-heading-task")
        try "## [x] Heading todo\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_EXPORT_DIALECT": "gfm",
            "KERN_NATIVE_GFM_EXTENSION_EXPORT": "lint",
            "KERN_NATIVE_HEADING_CHECKBOXES": "1",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "lint mode heading checkbox should render as WYSIWYG checkbox"
        ) { v in
            v.contains("☑ Heading todo")
        }
        XCTAssertTrue(value.contains("☑ Heading todo"))
        attachScreenshot(name: "gfm-lint-heading-open", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "- [x] Heading todo", timeout: 5)
        XCTAssertTrue(saved.contains("- [x] Heading todo"))
        XCTAssertFalse(saved.contains("## [x] Heading todo"))
    }

    func testGfmPortableSerializesHeadingCheckboxesAsGlyph() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-gfm-portable-heading-task")
        try "## [x] Heading todo\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_EXPORT_DIALECT": "gfm",
            "KERN_NATIVE_GFM_EXTENSION_EXPORT": "portable",
            "KERN_NATIVE_HEADING_CHECKBOXES": "1",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "portable mode heading checkbox should render as WYSIWYG checkbox"
        ) { v in
            v.contains("☑ Heading todo")
        }
        XCTAssertTrue(value.contains("☑ Heading todo"))
        attachScreenshot(name: "gfm-portable-heading-open", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "## ☑ Heading todo", timeout: 5)
        XCTAssertTrue(saved.contains("## ☑ Heading todo"))
        XCTAssertFalse(saved.contains("## [x] Heading todo"))
    }

    func testOrderedTasksGfmPortableExportsGlyph() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-gfm-portable-ordered-tasks")
        try """
        1. [ ] one
        2. [x] two
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_EXPORT_DIALECT": "gfm",
            "KERN_NATIVE_GFM_EXTENSION_EXPORT": "portable",
            "KERN_NATIVE_ORDERED_TASKS": "1",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "portable mode ordered tasks should render as WYSIWYG checkboxes"
        ) { v in
            v.contains("1. ☐ one") && v.contains("2. ☑ two")
        }
        XCTAssertTrue(value.contains("1. ☐ one"))
        XCTAssertTrue(value.contains("2. ☑ two"))
        attachScreenshot(name: "gfm-portable-ordered-tasks-open", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "1. ☐ one", timeout: 5)
        XCTAssertTrue(saved.contains("1. ☐ one"))
        XCTAssertTrue(saved.contains("2. ☑ two"))
        XCTAssertFalse(saved.contains("1. [ ] one"))
    }

    func testOrderedTasksGfmLintRewritesToBulletedTasks() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-gfm-lint-ordered-tasks")
        try """
        1. [ ] one
        2. [x] two
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_EXPORT_DIALECT": "gfm",
            "KERN_NATIVE_GFM_EXTENSION_EXPORT": "lint",
            "KERN_NATIVE_ORDERED_TASKS": "1",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "lint mode ordered tasks should render as WYSIWYG checkboxes"
        ) { v in
            v.contains("1. ☐ one") && v.contains("2. ☑ two")
        }
        XCTAssertTrue(value.contains("1. ☐ one"))
        XCTAssertTrue(value.contains("2. ☑ two"))
        attachScreenshot(name: "gfm-lint-ordered-tasks-open", element: textView)

        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "- [ ] 1. one", timeout: 5)
        XCTAssertTrue(saved.contains("- [ ] 1. one"))
        XCTAssertTrue(saved.contains("- [x] 2. two"))
        XCTAssertFalse(saved.contains("1. [ ] one"))
    }

    func testOrderedListNumberingPreserveTypedOnSave() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-ordered-numbering-preserve")
        try """
        1. one
        5. five
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_ORDERED_NUMBERING": "preserveTyped",
        ])
        try launchAndWaitForeground(app)

        attachScreenshot(name: "ordered-numbering-preserve-open", element: app.windows.firstMatch)
        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "5. five", timeout: 5)
        XCTAssertTrue(saved.contains("1. one"))
        XCTAssertTrue(saved.contains("5. five"))
        XCTAssertFalse(saved.contains("2. five"))
    }

    func testOrderedListNumberingGfmDefaultNormalizesOnSave() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-ordered-numbering-gfm-default")
        try """
        1. one
        5. five
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_ORDERED_NUMBERING": "gfmDefault",
        ])
        try launchAndWaitForeground(app)

        attachScreenshot(name: "ordered-numbering-gfm-default-open", element: app.windows.firstMatch)
        try save(app: app)

        let saved = try waitForFileContains(tmp, substring: "2. five", timeout: 5)
        XCTAssertTrue(saved.contains("1. one"))
        XCTAssertTrue(saved.contains("2. five"))
        XCTAssertFalse(saved.contains("5. five"))
    }

    func testCheckboxHitTargetMarkerTogglesWhenEnabled() throws {
        guard isExhaustiveUIEnabled() else {
            throw XCTSkip("Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run hit-target UI tests")
        }

        let tmp = try makeTempMarkdownFile(name: "kern-ui-checkbox-hit-target-marker")
        try "- [ ] item\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_TASK_RENDERING": "kern",
            "KERN_NATIVE_CHECKBOX_HIT_TARGET": "marker",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 2.0,
            description: "marker-mode task rendering should show bullet+checkbox"
        ) { v in
            v.contains("• ☐ item")
        }
        XCTAssertTrue(value.contains("• ☐ item"))
        attachScreenshot(name: "hit-target-marker-before", element: textView)

        // Click in the marker prefix area (between bullet dot and checkbox).
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 5)
        clickAtOffset(textView, x: 42, y: 40)

        let toggled = waitForTextViewValue(
            textView,
            timeout: 2.0,
            description: "clicking marker prefix should toggle checkbox"
        ) { v in
            v.contains("• ☑ item")
        }
        XCTAssertTrue(toggled.contains("• ☑ item"))
        attachScreenshot(name: "hit-target-marker-after", element: textView)
    }

    func testReloadOnDiskChangeShowsToastAndUpdatesContent() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-reload-on-disk-change")
        try "Before.\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let beforeValue = (textView.value as? String) ?? ""
        XCTAssertTrue(beforeValue.contains("Before."))
        attachScreenshot(name: "reload-before", element: textView)

        // External write: should trigger NSFilePresenter -> revert -> applyExternalMarkdownUpdate.
        try "After.\n".write(to: tmp, atomically: true, encoding: .utf8)

        let toast = app.staticTexts["NativeEditor.ReloadToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))

        let afterValue = waitForTextViewValue(
            textView,
            timeout: 8.0,
            description: "file reload should update editor content"
        ) { v in
            v.contains("After.")
        }
        XCTAssertTrue(afterValue.contains("After."))
        attachScreenshot(name: "reload-after", element: textView)
    }

    func testFindReplaceReplacesMatchesInOrder() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-find-replace")
        try "alpha beta alpha\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()

        // Cmd+Shift+H: Find and Replace...
        textView.typeKey("h", modifierFlags: [.command, .shift])

        let findSearch = app.searchFields["NativeEditor.FindField"]
        let findText = app.textFields["NativeEditor.FindField"]
        if !(findSearch.waitForExistence(timeout: 2) || findText.waitForExistence(timeout: 2)) {
            // Fallback: use the menu in case key equivalents are swallowed by the focused control.
            try openFindReplaceViaMenu(app: app)
        }
        XCTAssertTrue(findSearch.waitForExistence(timeout: 5) || findText.waitForExistence(timeout: 5))
        let findField = findSearch.exists ? findSearch : findText
        findField.click()
        findField.typeText("alpha")

        let replaceText = app.textFields["NativeEditor.ReplaceField"]
        let replaceSearch = app.searchFields["NativeEditor.ReplaceField"]
        XCTAssertTrue(replaceText.waitForExistence(timeout: 5) || replaceSearch.waitForExistence(timeout: 5))
        let replaceField = replaceText.exists ? replaceText : replaceSearch
        replaceField.click()
        replaceField.typeText("ALPHA")

        let replaceButton = app.buttons["NativeEditor.ReplaceButton"]
        XCTAssertTrue(replaceButton.waitForExistence(timeout: 5))
        replaceButton.click()

        let once = waitForTextViewValue(textView, timeout: 2.0, description: "replace first match") { v in
            v.contains("ALPHA beta alpha")
        }
        XCTAssertTrue(once.contains("ALPHA beta alpha"))
        attachScreenshot(name: "find-replace-once", element: textView)

        replaceButton.click()
        let twice = waitForTextViewValue(textView, timeout: 2.0, description: "replace second match") { v in
            v.contains("ALPHA beta ALPHA")
        }
        XCTAssertTrue(twice.contains("ALPHA beta ALPHA"))
        attachScreenshot(name: "find-replace-twice", element: textView)

        try save(app: app)
        let saved = try waitForFileContains(tmp, substring: "ALPHA beta ALPHA", timeout: 5)
        XCTAssertTrue(saved.contains("ALPHA beta ALPHA"))
    }

    func testCheckboxHitTargetGlyphTogglesByClick() throws {
        guard isExhaustiveUIEnabled() else {
            throw XCTSkip("Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run hit-target UI tests")
        }

        let tmp = try makeTempMarkdownFile(name: "kern-ui-checkbox-hit-target-glyph")
        try "- [ ] item\n".write(to: tmp, atomically: true, encoding: .utf8)

        // Default hit target is `glyph`. Use GFM rendering (default) to avoid a leading bullet dot.
        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_TASK_RENDERING": "gfm",
            "KERN_NATIVE_CHECKBOX_HIT_TARGET": "glyph",
        ])
        try launchAndWaitForeground(app)

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        let value = waitForTextViewValue(
            textView,
            timeout: 5.0,
            description: "glyph hit target should render as WYSIWYG checkbox"
        ) { v in
            v.contains("☐ item")
        }
        XCTAssertTrue(value.contains("☐ item"))
        attachScreenshot(name: "hit-target-glyph-before", element: textView)

        // Click directly on the checkbox glyph at the start of the first line.
        clickAtOffset(textView, x: 26, y: 40)

        let toggled = waitForTextViewValue(
            textView,
            timeout: 2.0,
            description: "clicking checkbox glyph should toggle"
        ) { v in
            v.contains("☑ item")
        }
        XCTAssertTrue(toggled.contains("☑ item"))
        attachScreenshot(name: "hit-target-glyph-after", element: textView)
    }

    func testScenarioMatrix_ExhaustiveUI() throws {
        guard isExhaustiveUIEnabled() else {
            throw XCTSkip("Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run exhaustive UI matrix")
        }

        struct Scenario {
            var name: String
            var env: [String: String]
            var input: String
            var expectUIContains: [String]
            var waitSubstring: String
            var expectDiskContains: [String]
            var expectDiskNotContains: [String]
        }

        let input = """
        ## [x] Heading todo
        - [ ] todo
        1. [ ] ordered task

        | TblLeft | TblRight |
        | --- | --- |
        | cellL | cellR |

        1. one
        5. five
        """

        let scenarios: [Scenario] = [
            .init(
                name: "gfm-preserve",
                env: [
                    "KERN_NATIVE_EXPORT_DIALECT": "gfm",
                    "KERN_NATIVE_GFM_EXTENSION_EXPORT": "preserve",
                    "KERN_NATIVE_HEADING_CHECKBOXES": "1",
                    "KERN_NATIVE_ORDERED_TASKS": "1",
                    "KERN_NATIVE_ORDERED_NUMBERING": "gfmDefault",
                ],
                input: input,
                expectUIContains: ["☑ Heading todo", "☐ todo", "1. ☐ ordered task", "TblLeft", "TblRight", "cellL", "cellR"],
                // This scenario relies on Save normalizing the ordered list numbering (5. -> 2.),
                // so we must wait for a post-save substring that is not present in the initial input.
                waitSubstring: "2. five",
                expectDiskContains: ["## [x] Heading todo", "- [ ] todo", "1. [ ] ordered task", "| TblLeft | TblRight |", "| --- | --- |", "| cellL | cellR |", "1. one", "2. five"],
                expectDiskNotContains: ["## ☑ Heading todo", "- [x] Heading todo"]
            ),
            .init(
                name: "gfm-portable",
                env: [
                    "KERN_NATIVE_EXPORT_DIALECT": "gfm",
                    "KERN_NATIVE_GFM_EXTENSION_EXPORT": "portable",
                    "KERN_NATIVE_HEADING_CHECKBOXES": "1",
                    "KERN_NATIVE_ORDERED_TASKS": "1",
                    "KERN_NATIVE_ORDERED_NUMBERING": "gfmDefault",
                ],
                input: input,
                expectUIContains: ["☑ Heading todo", "☐ todo", "1. ☐ ordered task", "TblLeft", "TblRight", "cellL", "cellR"],
                waitSubstring: "## ☑ Heading todo",
                expectDiskContains: ["## ☑ Heading todo", "- [ ] todo", "1. ☐ ordered task", "| TblLeft | TblRight |", "| --- | --- |", "| cellL | cellR |", "1. one", "2. five"],
                expectDiskNotContains: ["## [x] Heading todo", "- [x] Heading todo"]
            ),
            .init(
                name: "gfm-lint",
                env: [
                    "KERN_NATIVE_EXPORT_DIALECT": "gfm",
                    "KERN_NATIVE_GFM_EXTENSION_EXPORT": "lint",
                    "KERN_NATIVE_HEADING_CHECKBOXES": "1",
                    "KERN_NATIVE_ORDERED_TASKS": "1",
                    "KERN_NATIVE_ORDERED_NUMBERING": "gfmDefault",
                ],
                input: input,
                expectUIContains: ["☑ Heading todo", "☐ todo", "1. ☐ ordered task", "TblLeft", "TblRight", "cellL", "cellR"],
                waitSubstring: "- [x] Heading todo",
                expectDiskContains: ["- [x] Heading todo", "- [ ] todo", "- [ ] 1. ordered task", "| TblLeft | TblRight |", "| --- | --- |", "| cellL | cellR |", "1. one", "2. five"],
                expectDiskNotContains: ["## [x] Heading todo", "1. [ ] ordered task"]
            ),
            .init(
                name: "kern-standalone-task",
                env: [
                    "KERN_NATIVE_EXPORT_DIALECT": "kern",
                    "KERN_NATIVE_GFM_EXTENSION_EXPORT": "preserve",
                ],
                input: "[] todo\n",
                expectUIContains: ["☐ todo"],
                waitSubstring: "[ ] todo",
                expectDiskContains: ["[ ] todo"],
                expectDiskNotContains: ["- [ ] todo"]
            ),
        ]

        for scenario in scenarios {
            let tmp = try makeTempMarkdownFile(name: "kern-ui-matrix-\(scenario.name)")
            try scenario.input.write(to: tmp, atomically: true, encoding: .utf8)

            let app = makeApp(opening: tmp, env: scenario.env)
            try launchAndWaitForeground(app)
            defer { app.terminate() }

            let textView = app.textViews["NativeEditor.TextView"]
            XCTAssertTrue(textView.waitForExistence(timeout: 10))

            let value = waitForTextViewValue(
                textView,
                timeout: 5.0,
                description: "scenario \(scenario.name) should render expected WYSIWYG text"
            ) { v in
                scenario.expectUIContains.allSatisfy { v.contains($0) }
            }
            for s in scenario.expectUIContains {
                XCTAssertTrue(value.contains(s), "Scenario \(scenario.name) expected UI to contain: \(s)")
            }
            attachScreenshot(name: "matrix-\(scenario.name)-open", element: textView)

            try save(app: app)
            let saved = try waitForFileContains(tmp, substring: scenario.waitSubstring, timeout: 5)

            for s in scenario.expectDiskContains {
                XCTAssertTrue(saved.contains(s), "Scenario \(scenario.name) expected disk to contain: \(s)")
            }
            for s in scenario.expectDiskNotContains {
                XCTAssertFalse(saved.contains(s), "Scenario \(scenario.name) expected disk NOT to contain: \(s)")
            }
            attachScreenshot(name: "matrix-\(scenario.name)-saved", element: textView)
        }
    }

    // MARK: - Helpers

    private func makeTempMarkdownFile(name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).md")
        try Data().write(to: url, options: .atomic)
        return url
    }

    private func makeApp(opening url: URL, env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KERN_UI_TESTING"] = "1"
        app.launchEnvironment["KERN_TEST_WINDOW_SIZE"] = "900x650"
        app.launchEnvironment["KERN_TEST_APPEARANCE"] = "light"
        // Ensure transient UI is visible long enough for deterministic UI assertions.
        app.launchEnvironment["KERN_TEST_TOAST_DURATION_MS"] = "2000"

        for (k, v) in env {
            app.launchEnvironment[k] = v
        }

        app.launchArguments = [url.path]
        return app
    }

    private func launchAndWaitForeground(_ app: XCUIApplication, timeout: TimeInterval = 8) throws {
        try preflightCanRunUIAutomation()
        app.launch()
        try ensureRunningForeground(app, timeout: timeout)
    }

    private func save(app: XCUIApplication) throws {
        // Ensure the app is in the foreground; menu bar interactions are not reliable otherwise.
        try ensureRunningForeground(app, timeout: 5)

        // Prefer the menu item to avoid key event flakiness.
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))

        fileMenu.click()

        let saveItem = fileMenu.menus.menuItems["Save"]
        XCTAssertTrue(saveItem.waitForExistence(timeout: 5))
        XCTAssertTrue(saveItem.isEnabled, "Save menu item should be enabled")
        saveItem.click()
    }

    private func openFindReplaceViaMenu(app: XCUIApplication) throws {
        try ensureRunningForeground(app, timeout: 5)

        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()

        let findSubmenu = editMenu.menus.menuItems["Find"]
        XCTAssertTrue(findSubmenu.waitForExistence(timeout: 5))
        findSubmenu.hover()

        let findReplace = findSubmenu.menus.menuItems["Find and Replace\u{2026}"]
        XCTAssertTrue(findReplace.waitForExistence(timeout: 5))
        findReplace.click()
    }

    private func waitForFileContains(_ url: URL, substring: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            do {
                last = try String(contentsOf: url, encoding: .utf8)
                if last.contains(substring) { return last }
            } catch {
                // Ignore transient read errors while the file is being written.
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return last
    }

    private func waitForTextViewValue(
        _ textView: XCUIElement,
        timeout: TimeInterval,
        description: String,
        predicate: (String) -> Bool
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (textView.value as? String) ?? ""
            if predicate(last) { return last }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for text view value: \(description). Last=\(last)")
        return last
    }

    private func ensureRunningForeground(_ app: XCUIApplication, timeout: TimeInterval) throws {
        if app.state == .runningForeground { return }
        _ = app.wait(for: .runningForeground, timeout: timeout)
        if app.state == .runningForeground { return }

        // Avoid `app.activate()` here: on some macOS setups it can hang for a long time when the
        // system is locked or focus cannot be stolen, which makes the whole UI suite unusably slow.
        throw XCTSkip("UI tests require KernTextKit to become the foreground app. Unlock the Mac, stop using the mouse/keyboard during the run, and ensure Xcode has Automation permissions.")
    }

    private func preflightCanRunUIAutomation() throws {
        // When the screen is locked or a screen saver is active, launching/activating apps can hang
        // for a long time in XCUITest. Skip early with a clear message instead of burning minutes.
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (dict["CGSessionScreenIsLocked"] as? Bool) == true {
                throw XCTSkip("UI tests skipped: screen is locked. Unlock the Mac and rerun.")
            }
        }

        // UI automation requires Accessibility trust. If this isn't granted, tests can hang waiting
        // for system prompts. Skipping is better than producing false failures.
        if !AXIsProcessTrusted() {
            throw XCTSkip("UI tests skipped: Accessibility permission not granted. Enable Accessibility/Automation for Xcode and rerun.")
        }
    }

    private func attachScreenshot(name: String, element: XCUIElement? = nil) {
        if screenshotMode() == .off { return }

        let shot = element?.screenshot() ?? XCUIScreen.main.screenshot()
        writeScreenshotToDiskIfNeeded(name: name, shot: shot)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name

        // Default to keeping screenshots even on success so visual regressions (misalignment, spacing)
        // are reviewable. You can trade speed/size for coverage via env vars.
        switch screenshotMode() {
        case .always:
            attachment.lifetime = .keepAlways
        case .failure:
            attachment.lifetime = .deleteOnSuccess
        case .off:
            return
        }
        add(attachment)
    }

    private func writeScreenshotToDiskIfNeeded(name: String, shot: XCUIScreenshot) {
        guard let dir = ProcessInfo.processInfo.environment["KERN_UI_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let safeName = sanitizeFilename(name)
        let url = base.appendingPathComponent("\(safeName).png")

        do {
            try shot.pngRepresentation.write(to: url, options: .atomic)
        } catch {
            // Avoid failing tests for filesystem issues; screenshots are diagnostic.
            NSLog("[NativeEditorE2ETests] Failed to write screenshot to disk: \(url.path) error=\(error.localizedDescription)")
        }
    }

    private func sanitizeFilename(_ s: String) -> String {
        // Keep this simple and filesystem-safe.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }

    private enum ScreenshotMode: String {
        case always
        case failure
        case off
    }

    private func screenshotMode() -> ScreenshotMode {
        let env = ProcessInfo.processInfo.environment
        if env["KERN_UI_DISABLE_SCREENSHOTS"] == "1" { return .off }
        if let raw = env["KERN_UI_SCREENSHOTS"], let v = ScreenshotMode(rawValue: raw) { return v }

        // Back-compat:
        // - Previously, screenshots defaulted to failure-only unless KERN_UI_KEEP_SCREENSHOTS=1.
        if env["KERN_UI_KEEP_SCREENSHOTS"] == "1" { return .always }

        return .always
    }

    private func isExhaustiveUIEnabled() -> Bool {
        ProcessInfo.processInfo.environment["KERN_ENABLE_EXHAUSTIVE_TESTS"] == "1"
    }

    private func toggleCheckboxAtLineStart(_ textView: XCUIElement) {
        // Move caret to the beginning of the line (macOS standard).
        textView.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command])
        // Space toggles the checkbox when the caret is on (or immediately after) the checkbox marker.
        textView.typeText(" ")
    }

    private func clickAtOffset(_ element: XCUIElement, x: CGFloat, y: CGFloat) {
        element
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x, dy: y))
            .click()
    }
}
