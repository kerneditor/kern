import AppKit
import XCTest
import ApplicationServices
import CoreGraphics

@MainActor
final class NativeEditorE2ETests: XCTestCase {
    // Accessibility trust checks can be surprisingly slow when permission isn't granted.
    // Cache the result so we don't pay the cost once per test.
    private enum UIAutomationPreflightCache {
        nonisolated(unsafe) static var didRun = false
        nonisolated(unsafe) static var skipMessage: String?
    }

    func testScenarioMatrix_SmokeUI() throws {
        let tmp = try makeTempMarkdownFile(name: "kern-ui-smoke")

        let app = makeApp(opening: tmp)
        try launchAndWaitForeground(app)
        defer { app.terminate() }

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 4))
        textView.click()

        try XCTContext.runActivity(named: "Todo shortcut converts + toggles + exports") { _ in
            clearDocument(textView)
            textView.typeText("[] todo")

            let value = waitForTextViewValue(
                textView,
                timeout: 2.0,
                description: "todo shortcut should render as checkbox glyph"
            ) { v in
                v.contains("☐ todo")
            }
            XCTAssertTrue(value.contains("☐ todo"))
            attachScreenshot(name: "smoke-todo-shortcut", element: textView)

            toggleCheckboxAtLineStart(textView)
            let toggled = waitForTextViewValue(
                textView,
                timeout: 2.0,
                description: "toggling checkbox should show checked glyph"
            ) { v in
                v.contains("☑ todo")
            }
            XCTAssertTrue(toggled.contains("☑ todo"))
            attachScreenshot(name: "smoke-todo-toggled", element: textView)

            // Exit list/item context.
            textView.typeText("\n\n")

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "- [x] todo", timeout: 2)
            XCTAssertTrue(saved.contains("- [x] todo"))
            XCTAssertFalse(saved.contains("- [ ] \n"), "Should not persist an empty marker-only task item")
        }

        try XCTContext.runActivity(named: "Heading exits to paragraph on Enter") { _ in
            clearDocument(textView)
            textView.typeText("# Title\nBody\n")

            let value = (textView.value as? String) ?? ""
            XCTAssertFalse(value.contains("# Title"))
            XCTAssertTrue(value.contains("Title"))
            XCTAssertTrue(value.contains("Body"))
            attachScreenshot(name: "smoke-heading-exit", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "# Title", timeout: 2)
            XCTAssertTrue(saved.contains("# Title"))
            XCTAssertTrue(saved.contains("Body"))
        }

        try XCTContext.runActivity(named: "Ordered list continues + exits on blank") { _ in
            clearDocument(textView)
            textView.typeText("1. one\n")
            textView.typeText("two\n\n")
            attachScreenshot(name: "smoke-ordered-exit", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "1. one", timeout: 2)
            XCTAssertTrue(saved.contains("1. one"))
            XCTAssertTrue(saved.contains("2. two"))
            XCTAssertFalse(saved.contains("3. \n"), "Should not persist an empty marker-only ordered item")
        }

        try XCTContext.runActivity(named: "Bullet list continues + exits on blank") { _ in
            clearDocument(textView)
            textView.typeText("- one\n")
            textView.typeText("two\n\n")

            let value = (textView.value as? String) ?? ""
            XCTAssertTrue(value.contains("• one"))
            XCTAssertTrue(value.contains("• two"))
            attachScreenshot(name: "smoke-bullet-exit", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "- one", timeout: 2)
            XCTAssertTrue(saved.contains("- one"))
            XCTAssertTrue(saved.contains("- two"))
            XCTAssertFalse(saved.contains("\n- \n"), "Should not persist an empty marker-only bullet item")
        }

        try XCTContext.runActivity(named: "Shift+Enter in bullet inserts soft break (no new item)") { _ in
            clearDocument(textView)
            textView.typeText("- one")
            textView.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.shift])
            textView.typeText("two\n\n")

            attachScreenshot(name: "smoke-shift-enter-bullet", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "- one", timeout: 2)
            XCTAssertTrue(saved.contains("- one\\\n  two"))
            XCTAssertFalse(saved.contains("- two"))
        }

        try XCTContext.runActivity(named: "Typed table converts to WYSIWYG and exports GFM") { _ in
            clearDocument(textView)

            // Type a minimal GFM table and press Enter after the first body row to trigger conversion.
            textView.typeText("| A | B |\n| --- | --- |\n| c | d |\n")

            let value = waitForTextViewValue(
                textView,
                timeout: 3.0,
                description: "table conversion should hide delimiter row"
            ) { v in
                v.contains("A") && v.contains("B") && v.contains("c") && v.contains("d") && !v.contains("| ---")
            }
            XCTAssertFalse(value.contains("|"), "WYSIWYG should hide table pipe syntax after conversion")
            attachScreenshot(name: "smoke-typed-table", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "| A | B |", timeout: 2)
            XCTAssertTrue(saved.contains("| --- | --- |"))
            XCTAssertTrue(saved.contains("| c | d |"))
        }

        try XCTContext.runActivity(named: "Code block shows copy button and copies content") { _ in
            clearDocument(textView)

            textView.typeText("```js\nconsole.log(\"hi\")\nconsole.log(2)\n```\n")

            // Click near the top-left of the editor; this doc starts with a code block.
            clickAtOffset(textView, x: 40, y: 40)

            let copyButton = app.buttons["NativeEditor.CodeCopyButton"]
            XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
            XCTAssertTrue(copyButton.isHittable)
            attachScreenshot(name: "smoke-code-copy-visible", element: textView)

            NSPasteboard.general.clearContents()
            copyButton.click()

            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            XCTAssertTrue(copied.contains("console.log(\"hi\")"))
            XCTAssertTrue(copied.contains("console.log(2)"))
        }

        try XCTContext.runActivity(named: "External disk write reloads content + shows toast") { _ in
            try "Before.\n".write(to: tmp, atomically: true, encoding: .utf8)

            let toast = app.staticTexts["NativeEditor.ReloadToast"]
            XCTAssertTrue(toast.waitForExistence(timeout: 8))

            let value = waitForTextViewValue(
                textView,
                timeout: 8.0,
                description: "file reload should update editor content"
            ) { v in
                v.contains("Before.")
            }
            XCTAssertTrue(value.contains("Before."))
            attachScreenshot(name: "smoke-reload-toast", element: textView)
        }

        try XCTContext.runActivity(named: "Find and Replace replaces matches in order") { _ in
            clearDocument(textView)
            textView.typeText("alpha beta alpha")

            try openFindReplaceViaShortcut(focused: textView)

            let findField = app.searchFields["NativeEditor.FindField"]
            XCTAssertTrue(findField.waitForExistence(timeout: 3))
            findField.click()
            findField.typeText("alpha")

            let replaceField = app.textFields["NativeEditor.ReplaceField"]
            XCTAssertTrue(replaceField.waitForExistence(timeout: 3))
            replaceField.click()
            replaceField.typeText("ALPHA")

            let replaceButton = app.buttons["NativeEditor.ReplaceButton"]
            XCTAssertTrue(replaceButton.waitForExistence(timeout: 3))
            replaceButton.click()

            attachScreenshot(name: "smoke-find-replace-once", element: textView)
            XCTAssertTrue(((textView.value as? String) ?? "").contains("ALPHA beta alpha"))

            replaceButton.click()
            attachScreenshot(name: "smoke-find-replace-twice", element: textView)
            XCTAssertTrue(((textView.value as? String) ?? "").contains("ALPHA beta ALPHA"))

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "ALPHA beta ALPHA", timeout: 2)
            XCTAssertTrue(saved.contains("ALPHA beta ALPHA"))
        }
    }

    func testScenarioMatrix_ExhaustiveUI() throws {
        guard isExhaustiveUIEnabled() else {
            throw XCTSkip("Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run exhaustive UI scenarios")
        }

        // Hit-target tests must use click interactions (keyboard toggles are covered by smoke).
        let tmp = try makeTempMarkdownFile(name: "kern-ui-hit-target-marker")
        try "- [ ] item\n".write(to: tmp, atomically: true, encoding: .utf8)

        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_TASK_RENDERING": "kern",
            "KERN_NATIVE_CHECKBOX_HIT_TARGET": "marker",
        ])
        try launchAndWaitForeground(app)
        defer { app.terminate() }

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 4))

        let before = waitForTextViewValue(
            textView,
            timeout: 3.0,
            description: "marker-mode task rendering should show bullet+checkbox"
        ) { v in
            v.contains("• ☐ item")
        }
        XCTAssertTrue(before.contains("• ☐ item"))
        attachScreenshot(name: "exhaustive-hit-target-marker-before", element: textView)

        // Click in the marker prefix area (between bullet dot and checkbox).
        clickAtOffset(textView, x: 42, y: 40)

        let after = waitForTextViewValue(
            textView,
            timeout: 3.0,
            description: "clicking marker prefix should toggle checkbox"
        ) { v in
            v.contains("• ☑ item")
        }
        XCTAssertTrue(after.contains("• ☑ item"))
        attachScreenshot(name: "exhaustive-hit-target-marker-after", element: textView)

        try save(app: app, focused: textView)
        let saved = try waitForFileContains(tmp, substring: "- [x] item", timeout: 2)
        XCTAssertTrue(saved.contains("- [x] item"))
    }

    // MARK: - Helpers

    private func clearDocument(_ textView: XCUIElement) {
        textView.click()
        textView.typeKey("a", modifierFlags: [.command])
        textView.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    }

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

    private func launchAndWaitForeground(_ app: XCUIApplication, timeout: TimeInterval = 4) throws {
        try preflightCanRunUIAutomation()
        app.launch()
        try ensureRunningForeground(app, timeout: timeout)
    }

    private func save(app: XCUIApplication, focused: XCUIElement) throws {
        // Ensure the app is in the foreground; key equivalents won't route correctly otherwise.
        try ensureRunningForeground(app, timeout: 2)

        // Cmd+S is significantly faster than menu traversal (which triggers multiple accessibility waits).
        focused.typeKey("s", modifierFlags: [.command])
    }

    private func openFindReplaceViaShortcut(focused: XCUIElement) throws {
        // Cmd+Shift+H (as configured in AppDelegate) is far faster than menu traversal.
        focused.typeKey("h", modifierFlags: [.command, .shift])
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
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
        if UIAutomationPreflightCache.didRun {
            if let msg = UIAutomationPreflightCache.skipMessage {
                throw XCTSkip(msg)
            }
            return
        }
        UIAutomationPreflightCache.didRun = true

        // When the screen is locked or a screen saver is active, launching/activating apps can hang
        // for a long time in XCUITest. Skip early with a clear message instead of burning minutes.
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (dict["CGSessionScreenIsLocked"] as? Bool) == true {
                let msg = "UI tests skipped: screen is locked. Unlock the Mac and rerun."
                UIAutomationPreflightCache.skipMessage = msg
                throw XCTSkip(msg)
            }
        }

        // UI automation requires Accessibility trust. Prompt once, then skip with a clear message
        // if permission isn't granted (tests are not meaningful without it).
        // Avoid referencing `kAXTrustedCheckOptionPrompt` directly: under Swift 6 strict concurrency,
        // importing that global CFString can trigger "not concurrency-safe" compile failures.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            let msg = """
            UI tests skipped: Accessibility permission not granted.
            Enable it in System Settings > Privacy & Security > Accessibility for:
            - Xcode
            - KernTextKitUITests-Runner
            If the runner app doesn't appear in the list, add it manually via the + button:
            - Press Cmd+Shift+G and paste:
              /tmp/kern-derived-data-tests/Build/Products/Debug/KernTextKitUITests-Runner.app
            Then rerun UI tests.
            """
            UIAutomationPreflightCache.skipMessage = msg
            throw XCTSkip(msg)
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
