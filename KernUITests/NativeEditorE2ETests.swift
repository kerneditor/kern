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
            try loadMarkdown("# Title\nBody\n", into: tmp, showingIn: textView)

            let value = waitForTextViewValue(
                textView,
                timeout: 2.0,
                description: "heading conversion should show rendered text"
            ) { v in
                v.contains("Title") && v.contains("Body")
            }
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
            try loadMarkdown("1. one\n2. two\n", into: tmp, showingIn: textView)
            attachScreenshot(name: "smoke-ordered-exit", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "1. one", timeout: 2)
            XCTAssertTrue(saved.contains("1. one"))
            XCTAssertTrue(saved.contains("2. two"))
            XCTAssertFalse(saved.contains("3. \n"), "Should not persist an empty marker-only ordered item")
        }

        try XCTContext.runActivity(named: "Bullet list continues + exits on blank") { _ in
            try loadMarkdown("- one\n- two\n", into: tmp, showingIn: textView)

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
            try loadMarkdown("- one\\\n  two\n", into: tmp, showingIn: textView)

            attachScreenshot(name: "smoke-shift-enter-bullet", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "- one", timeout: 2)
            XCTAssertTrue(saved.contains("- one\\\n  two"))
            XCTAssertFalse(saved.contains("- two"))
        }

        try XCTContext.runActivity(named: "Typed table converts to WYSIWYG and exports GFM") { _ in
            try loadMarkdown(
                """
                | A | B |
                | --- | --- |
                | c | d |
                """,
                into: tmp,
                showingIn: textView
            )

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

        try XCTContext.runActivity(named: "Full-spec fixture captures visual top + bottom render sections") { _ in
            let fullSpec = try loadFixture(name: "native-editor-golden/full-spec-visual.fixture.md")
            try loadMarkdown(fullSpec, into: tmp, showingIn: textView)

            let topValue = (textView.value as? String) ?? ""
            XCTAssertTrue(topValue.contains("Full Spec Visual Fixture"))
            XCTAssertTrue(topValue.contains("Horizontal rule"))
            XCTAssertTrue(topValue.contains("Block math"))
            XCTAssertTrue(topValue.contains("Mermaid"))
            attachScreenshot(name: "smoke-fullspec-top", element: textView)

            textView.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command])
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            attachScreenshot(name: "smoke-fullspec-bottom", element: textView)
        }

        try XCTContext.runActivity(named: "Images fixture captures local, remote, and fallback visuals") { _ in
            let imagesFixture = try loadFixture(name: "native-editor-golden/images.fixture.md")
            try loadMarkdown(imagesFixture, into: tmp, showingIn: textView)

            let value = (textView.value as? String) ?? ""
            XCTAssertTrue(value.contains("Images Fixture"))
            XCTAssertTrue(value.contains("Before image paragraph."))
            XCTAssertTrue(value.contains("After image paragraph."))
            attachScreenshot(name: "smoke-images-fixture", element: textView)

            try save(app: app, focused: textView)
            let saved = try waitForFileContains(tmp, substring: "![Local sample]", timeout: 2)
            XCTAssertTrue(saved.contains("![Local sample]"))
            XCTAssertTrue(saved.contains("![Broken local image]"))
            XCTAssertTrue(saved.contains("![Remote sample 1]"))
            XCTAssertTrue(saved.contains("![Remote sample 2]"))
        }

        try XCTContext.runActivity(named: "Code block shows copy button and copies content") { _ in
            try loadMarkdown(
                """
                ```js
                console.log("hi")
                console.log(2)
                ```
                """,
                into: tmp,
                showingIn: textView
            )

            guard let copyButton = revealCodeBlockCopyButton(in: app, textView: textView) else {
                attachScreenshot(name: "smoke-code-copy-missing", element: textView)
                XCTFail("Expected a visible code copy button")
                return
            }

            XCTAssertTrue(copyButton.exists)
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

        let markerProbeOffsets: [(CGFloat, CGFloat)] = [
            // Probe a small cluster around the marker prefix so this remains stable across
            // subtle font/layout shifts while still validating marker-region hit behavior.
            (30, 34),
            (42, 34),
            (54, 34),
            (30, 42),
            (42, 42),
            (54, 42),
        ]

        var after: String?
        for (x, y) in markerProbeOffsets {
            clickAtOffset(textView, x: x, y: y)
            if let matched = firstTextViewValue(
                textView,
                timeout: 0.35,
                predicate: { $0.contains("• ☑ item") }
            ) {
                after = matched
                break
            }
        }

        guard let after else {
            attachScreenshot(name: "exhaustive-hit-target-marker-failed", element: textView)
            XCTFail("clicking marker prefix should toggle checkbox")
            return
        }

        XCTAssertTrue(after.contains("• ☑ item"))
        attachScreenshot(name: "exhaustive-hit-target-marker-after", element: textView)

        try save(app: app, focused: textView)
        let saved = try waitForFileContains(tmp, substring: "- [x] item", timeout: 2)
        XCTAssertTrue(saved.contains("- [x] item"))
    }

    func testScenarioMatrix_ExhaustiveUI_FullFixtureLiveTypingAndActionPermutations() throws {
        guard isExhaustiveUIEnabled() else {
            throw XCTSkip("Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run exhaustive UI scenarios")
        }
        // Exhaustive UI should be truly exhaustive by default. Allow an explicit opt-out
        // for debugging/fast local loops with KERN_UI_ENABLE_LIVE_TYPING=0.
        let liveTypingRaw = configString("KERN_UI_ENABLE_LIVE_TYPING") ?? "<unset>"
        guard configBool("KERN_UI_ENABLE_LIVE_TYPING", default: true) else {
            attachTextReport(
                """
                KERN_UI_ENABLE_LIVE_TYPING=\(liveTypingRaw)
                KERN_ENABLE_EXHAUSTIVE_TESTS=\(configString("KERN_ENABLE_EXHAUSTIVE_TESTS") ?? "<unset>")
                """,
                name: "exhaustive-live-typing-skip-config"
            )
            throw XCTSkip("Set KERN_UI_ENABLE_LIVE_TYPING=1 to run the long UI live-typing matrix")
        }

        let fixtureName = configString("KERN_UI_TYPING_FIXTURE") ?? "ultimate-stress-test.md"
        let source = try loadFixture(name: fixtureName)
        XCTAssertFalse(source.isEmpty, "Fixture \(fixtureName) should not be empty")

        let chunkSize = max(64, configInt("KERN_UI_TYPING_CHUNK_SIZE", default: 16_384) ?? 16_384)
        let typingMode = uiTypingMode()
        let chunkInsertion = uiChunkInsertionMode()
        let actionDepth = max(1, min(3, configInt("KERN_UI_ACTION_DEPTH", default: 2) ?? 2))
        let actionLimit = configInt("KERN_UI_ACTION_LIMIT")

        let tmp = try makeTempMarkdownFile(name: "kern-ui-full-fixture")
        let app = makeApp(opening: tmp, env: [
            "KERN_NATIVE_TASK_RENDERING": "gfm",
        ])
        try launchAndWaitForeground(app, timeout: 8)
        defer { app.terminate() }

        let textView = app.textViews["NativeEditor.TextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 6))
        textView.click()
        clearDocument(textView)

        attachTextReport(
            """
            fixture=\(fixtureName)
            fixture_bytes=\(source.utf8.count)
            typing_mode=\(typingMode.rawValue)
            typing_chunk_size=\(chunkSize)
            chunk_insertion=\(chunkInsertion.rawValue)
            action_depth=\(actionDepth)
            action_limit=\(actionLimit.map { String($0) } ?? "none")
            """,
            name: "exhaustive-live-typing-config"
        )

        attachScreenshot(name: "exhaustive-live-typing-before", element: textView)
        typeFixtureLive(
            source,
            mode: typingMode,
            chunkSize: chunkSize,
            chunkInsertion: chunkInsertion,
            into: textView
        )
        attachScreenshot(name: "exhaustive-live-typing-after", element: textView)

        let tokenCandidates = [
            "Table of Contents",
            "```",
            "```mermaid",
            "$$",
            "|",
            "- [ ]",
            "> Project tasks:",
            "![Local sample]",
            "---",
        ]
        let requiredFixtureTokens = tokenCandidates.filter { source.contains($0) }

        // Validate fixture integrity immediately after live typing, before action fuzzing.
        // Action programs below intentionally include destructive edits (undo/backspace/newline),
        // so token-preservation invariants belong to this pre-action checkpoint.
        try save(app: app, focused: textView)
        let savedBeforeActions = try String(contentsOf: tmp, encoding: .utf8)
        attachTextReport(
            """
            source_bytes=\(source.utf8.count)
            saved_before_actions_bytes=\(savedBeforeActions.utf8.count)
            """,
            name: "exhaustive-live-typing-size-before-actions"
        )
        attachTextReport(String(savedBeforeActions.prefix(3000)), name: "exhaustive-live-typing-saved-before-actions-preview")

        XCTAssertGreaterThan(
            savedBeforeActions.utf8.count,
            source.utf8.count / 2,
            "Live typing lost too much content before actions"
        )
        for token in requiredFixtureTokens {
            XCTAssertTrue(savedBeforeActions.contains(token), "Live typing should retain token before actions: \(token)")
        }

        let programs = boundedActionPrograms(depth: actionDepth, limit: actionLimit)
        attachTextReport("action_programs_effective=\(programs.count)", name: "exhaustive-live-action-program-count")
        for (i, program) in programs.enumerated() {
            applyActionProgram(program, to: textView)
            if i % 15 == 0 {
                attachScreenshot(name: "exhaustive-live-actions-\(i)", element: textView)
            }
        }

        try save(app: app, focused: textView)
        let savedAfterActions = try String(contentsOf: tmp, encoding: .utf8)
        attachTextReport(
            """
            source_bytes=\(source.utf8.count)
            saved_before_actions_bytes=\(savedBeforeActions.utf8.count)
            saved_after_actions_bytes=\(savedAfterActions.utf8.count)
            """,
            name: "exhaustive-live-typing-size-after-actions"
        )
        attachTextReport(String(savedAfterActions.prefix(3000)), name: "exhaustive-live-typing-saved-after-actions-preview")

        // Post-action invariants: content remains non-empty and serializable after exhaustive
        // navigation/edit key permutations. Exact token preservation is intentionally not required
        // here because action programs include destructive edits by design.
        XCTAssertGreaterThan(savedAfterActions.utf8.count, 2_000, "Saved content collapsed too much after live typing/actions")
        XCTAssertTrue(savedAfterActions.contains("\n"), "Post-action export should remain multiline")
    }

    func testScenarioMatrix_ExhaustiveUI_TypingBehaviorMatrix() throws {
        guard isExhaustiveUIEnabled() else {
            throw XCTSkip("Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run exhaustive UI scenarios")
        }

        struct TypingCase {
            let id: String
            let seedMarkdown: String?
            let perform: (XCUIElement) -> Void
            let mustContain: [String]
            let mustNotContain: [String]

            init(
                id: String,
                seedMarkdown: String? = nil,
                perform: @escaping (XCUIElement) -> Void,
                mustContain: [String],
                mustNotContain: [String]
            ) {
                self.id = id
                self.seedMarkdown = seedMarkdown
                self.perform = perform
                self.mustContain = mustContain
                self.mustNotContain = mustNotContain
            }
        }

        let cases: [TypingCase] = [
            TypingCase(
                id: "heading-task-syntax",
                perform: { textView in
                    textView.typeText("# [ ] heading task")
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["# [ ] heading task", "after"],
                mustNotContain: []
            ),
            TypingCase(
                id: "heading-enter-exit",
                perform: { textView in
                    textView.typeText("# Heading")
                    self.pressReturn(textView)
                    textView.typeText("Body")
                },
                mustContain: ["# Heading", "Body"],
                mustNotContain: ["\n# Body"]
            ),
            TypingCase(
                id: "bullet-continue-exit",
                perform: { textView in
                    textView.typeText("- one")
                    self.pressReturn(textView)
                    textView.typeText("two")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["- one", "- two", "after"],
                mustNotContain: ["\n- \n"]
            ),
            TypingCase(
                id: "ordered-continue-exit",
                perform: { textView in
                    textView.typeText("1. one")
                    self.pressReturn(textView)
                    textView.typeText("two")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["1. one", "2. two", "after"],
                mustNotContain: ["\n3. \n"]
            ),
            TypingCase(
                id: "task-continue-exit",
                perform: { textView in
                    textView.typeText("- [ ] todo")
                    self.pressReturn(textView)
                    textView.typeText("next")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["- [ ] todo", "- [ ] next", "after"],
                mustNotContain: ["\n- [ ] \n"]
            ),
            TypingCase(
                id: "shift-enter-soft-break-bullet",
                perform: { textView in
                    textView.typeText("- one")
                    self.pressReturn(textView, shift: true)
                    textView.typeText("two")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["- one", "two", "after"],
                mustNotContain: ["\n- two"]
            ),
            TypingCase(
                id: "nested-bullet-continue-exit",
                seedMarkdown: """
                - parent
                  - child
                """,
                perform: { textView in
                    textView.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command])
                    self.pressReturn(textView)
                    textView.typeText("nested child two")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["- parent", "  - child", "  - nested child two", "after"],
                mustNotContain: ["-   - child", "\n  - \n"]
            ),
            TypingCase(
                id: "ordered-task-continue-exit",
                perform: { textView in
                    textView.typeText("1. [ ] one")
                    self.pressReturn(textView)
                    textView.typeText("two")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["1. [ ] one", "2. [ ] two", "after"],
                mustNotContain: ["\n3. [ ] \n"]
            ),
            TypingCase(
                id: "blockquote-continue-exit",
                perform: { textView in
                    textView.typeText("> quote")
                    self.pressReturn(textView)
                    textView.typeText("continued")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["> quote", "> continued", "after"],
                mustNotContain: ["\n> \n"]
            ),
            TypingCase(
                id: "fenced-code-enter-exit",
                perform: { textView in
                    textView.typeText("```ts")
                    self.pressReturn(textView)
                    textView.typeText("const x = 1")
                    self.pressReturn(textView)
                    textView.typeText("```")
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["```ts", "const x = 1", "```", "after"],
                mustNotContain: []
            ),
            TypingCase(
                id: "inline-code-roundtrip",
                perform: { textView in
                    textView.typeText("before `code` after")
                    self.pressReturn(textView)
                    textView.typeText("line2")
                },
                mustContain: ["before `code` after", "line2"],
                mustNotContain: []
            ),
            TypingCase(
                id: "nested-task-continue-exit",
                seedMarkdown: """
                - parent
                  - [ ] child task
                """,
                perform: { textView in
                    textView.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command])
                    self.pressReturn(textView)
                    textView.typeText("nested followup")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["- parent", "  - [ ] child task", "  - [ ] nested followup", "after"],
                mustNotContain: ["-   - [ ]", "\n  - [ ] \n"]
            ),
            TypingCase(
                id: "ordered-nesting-with-bullet-child",
                seedMarkdown: """
                1. parent
                   - child
                """,
                perform: { textView in
                    textView.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command])
                    self.pressReturn(textView)
                    textView.typeText("child2")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("2. second")
                },
                mustContain: ["1. parent", "   - child", "   - child2", "2. second"],
                mustNotContain: ["2.   - child"]
            ),
            TypingCase(
                id: "blockquote-soft-break-then-exit",
                perform: { textView in
                    textView.typeText("> quote")
                    self.pressReturn(textView, shift: true)
                    textView.typeText("wrapped")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["> quote", "wrapped", "after"],
                mustNotContain: ["\n> \n"]
            ),
            TypingCase(
                id: "code-fence-inside-list-does-not-break-list-context",
                perform: { textView in
                    textView.typeText("- item")
                    self.pressReturn(textView)
                    textView.typeText("  ```bash")
                    self.pressReturn(textView)
                    textView.typeText("  echo hi")
                    self.pressReturn(textView)
                    textView.typeText("  ```")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("after")
                },
                mustContain: ["- item", "```bash", "echo hi", "```", "after"],
                mustNotContain: []
            ),
            TypingCase(
                id: "ordered-task-double-enter-exits-cleanly",
                perform: { textView in
                    textView.typeText("1. [ ] alpha")
                    self.pressReturn(textView)
                    textView.typeText("beta")
                    self.pressReturn(textView)
                    self.pressReturn(textView)
                    textView.typeText("paragraph")
                },
                mustContain: ["1. [ ] alpha", "2. [ ] beta", "paragraph"],
                mustNotContain: ["\n3. [ ] \n"]
            ),
        ]

        let profiles: [(id: String, env: [String: String])] = [
            (
                id: "gfm-default",
                env: [
                    "KERN_NATIVE_TASK_RENDERING": "gfm",
                    "KERN_NATIVE_ORDERED_TASKS": "1",
                    "KERN_NATIVE_HEADING_CHECKBOXES": "0",
                ]
            ),
            (
                id: "kern-extensions",
                env: [
                    "KERN_NATIVE_TASK_RENDERING": "kern",
                    "KERN_NATIVE_ORDERED_TASKS": "1",
                    "KERN_NATIVE_HEADING_CHECKBOXES": "1",
                ]
            ),
        ]

        for profile in profiles {
            for scenario in cases {
                try XCTContext.runActivity(named: "Profile \(profile.id) — \(scenario.id)") { _ in
                    let tmp = try makeTempMarkdownFile(name: "kern-ui-typing-\(profile.id)-\(scenario.id)")
                    let app = makeApp(opening: tmp, env: profile.env)
                    try launchAndWaitForeground(app, timeout: 8)
                    defer { app.terminate() }

                    let textView = app.textViews["NativeEditor.TextView"]
                    XCTAssertTrue(textView.waitForExistence(timeout: 6))
                    textView.click()

                    if let seed = scenario.seedMarkdown {
                        try loadMarkdown(seed, into: tmp, showingIn: textView)
                        textView.click()
                    }

                    scenario.perform(textView)

                    try save(app: app, focused: textView)
                    let anchor = scenario.mustContain.first ?? " "
                    let saved = try waitForFileContains(tmp, substring: anchor, timeout: 3.0)

                    for token in scenario.mustContain {
                        XCTAssertTrue(saved.contains(token), "Expected token not found for \(scenario.id): \(token)")
                    }
                    for token in scenario.mustNotContain {
                        XCTAssertFalse(saved.contains(token), "Unexpected token found for \(scenario.id): \(token)")
                    }

                    let preview = String(saved.prefix(3000))
                    attachTextReport(preview, name: "exhaustive-typing-\(profile.id)-\(scenario.id)-saved-preview")
                    attachScreenshot(name: "exhaustive-typing-\(profile.id)-\(scenario.id)", element: textView)
                }
            }
        }
    }

    // MARK: - Helpers

    private func clearDocument(_ textView: XCUIElement) {
        textView.click()
        let deadline = Date().addingTimeInterval(4.0)
        var last = ""

        while Date() < deadline {
            textView.typeKey("a", modifierFlags: [.command])
            textView.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            textView.typeKey("x", modifierFlags: [.command])

            last = (textView.value as? String) ?? ""
            let normalized = last
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { return }

            // Fallback: replace current selection with a plain newline, then clear once more.
            // This avoids sticky marker-only states in some NSTextView edit paths.
            textView.typeKey("a", modifierFlags: [.command])
            textView.typeText("\n")
            textView.typeKey("a", modifierFlags: [.command])
            textView.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

            last = (textView.value as? String) ?? ""
            let normalizedAfterFallback = last
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedAfterFallback.isEmpty { return }

            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTFail("Failed to clear text view before scenario. Last=\(last)")
    }

    private func makeTempMarkdownFile(name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).md")
        try Data().write(to: url, options: .atomic)
        return url
    }

    private enum UIAction: String, CaseIterable {
        case left
        case right
        case lineStart
        case lineEnd
        case docStart
        case docEnd
        case insertASCII
        case newline
        case backspace
        case space
        case undo
        case redo
    }

    private enum UITypingMode: String {
        case character
        case chunked
    }

    private enum UIChunkInsertionMode: String {
        case paste
        case type
    }

    private func makeApp(opening url: URL, env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KERN_UI_TESTING"] = "1"
        app.launchEnvironment["KERN_TEST_WINDOW_SIZE"] = "900x650"
        app.launchEnvironment["KERN_TEST_APPEARANCE"] =
            configString("KERN_UI_TEST_APPEARANCE")
            ?? configString("KERN_TEST_APPEARANCE")
            ?? "dark"
        // Ensure transient UI is visible long enough for deterministic UI assertions.
        app.launchEnvironment["KERN_TEST_TOAST_DURATION_MS"] = "2000"
        // UI exhaustive typing can be very large; disabling undo prevents runaway memory growth.
        app.launchEnvironment["KERN_TEST_DISABLE_UNDO"] = "1"

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

    private func loadMarkdown(_ markdown: String, into url: URL, showingIn textView: XCUIElement) throws {
        let before = (textView.value as? String) ?? ""
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            let current = (textView.value as? String) ?? ""
            if current != before { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for editor to reflect externally written markdown")
    }

    private func loadFixture(name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernUITests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func typeLine(_ line: String, into textView: XCUIElement) {
        typeCharacters(line, into: textView)
        pressReturn(textView)
    }

    private func typeCharacters(_ text: String, into textView: XCUIElement) {
        for ch in text {
            textView.typeText(String(ch))
        }
    }

    private func pressReturn(_ textView: XCUIElement, shift: Bool = false) {
        if shift {
            textView.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.shift])
        } else {
            textView.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }
    }

    private func typeFixtureLive(
        _ source: String,
        mode: UITypingMode,
        chunkSize: Int,
        chunkInsertion: UIChunkInsertionMode,
        into textView: XCUIElement
    ) {
        switch mode {
        case .character:
            typeFixtureCharacterByCharacter(source, into: textView)
        case .chunked:
            typeFixtureInChunks(
                source,
                chunkSize: chunkSize,
                insertionMode: chunkInsertion,
                into: textView
            )
        }
    }

    private func typeFixtureCharacterByCharacter(_ source: String, into textView: XCUIElement) {
        var index = 0
        for ch in source {
            textView.typeText(String(ch))
            index += 1
            if index % 2500 == 0 {
                attachScreenshot(name: "exhaustive-live-typing-char-\(index)", element: textView)
            }
        }
    }

    private func typeFixtureInChunks(
        _ source: String,
        chunkSize: Int,
        insertionMode: UIChunkInsertionMode,
        into textView: XCUIElement
    ) {
        var current = ""
        current.reserveCapacity(chunkSize)
        var chunkIndex = 0

        for ch in source {
            current.append(ch)
            if current.utf16.count >= chunkSize {
                insertChunk(current, mode: insertionMode, into: textView)
                current.removeAll(keepingCapacity: true)
                chunkIndex += 1
                if chunkIndex % 8 == 0 {
                    attachScreenshot(name: "exhaustive-live-typing-chunk-\(chunkIndex)", element: textView)
                }
            }
        }
        if !current.isEmpty {
            insertChunk(current, mode: insertionMode, into: textView)
        }
    }

    private func insertChunk(_ chunk: String, mode: UIChunkInsertionMode, into textView: XCUIElement) {
        switch mode {
        case .type:
            textView.typeText(chunk)
        case .paste:
            let baseline = ((textView.value as? String) ?? "").utf16.count
            let expectedDelta = max(16, chunk.utf16.count / 5)
            let pasteboard = NSPasteboard.general

            for _ in 0..<2 {
                // Keep insertion anchored at the end during long runs.
                textView.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command])
                pasteboard.clearContents()
                pasteboard.setString(chunk, forType: .string)
                textView.typeKey("v", modifierFlags: [.command])

                if waitForTextGrowth(textView, baseline: baseline, minDelta: expectedDelta, timeout: 1.2) {
                    return
                }
            }

            // Deterministic fallback when pasteboard insertion is flaky on long UI runs.
            textView.typeText(chunk)
        }
    }

    private func waitForTextGrowth(
        _ textView: XCUIElement,
        baseline: Int,
        minDelta: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (textView.value as? String) ?? ""
            if value.utf16.count >= baseline + minDelta {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    private func boundedActionPrograms(depth: Int, limit: Int?) -> [[UIAction]] {
        let alphabet: [UIAction] = UIAction.allCases
        var programs: [[UIAction]] = []
        let shouldCap = (limit ?? 0) > 0
        let hardLimit = limit ?? .max
        for d in 1...depth {
            var buffer = Array(repeating: alphabet[0], count: d)
            func dfs(_ idx: Int) {
                if shouldCap && programs.count >= hardLimit { return }
                if idx == d {
                    programs.append(buffer)
                    return
                }
                for action in alphabet {
                    buffer[idx] = action
                    dfs(idx + 1)
                    if shouldCap && programs.count >= hardLimit { return }
                }
            }
            dfs(0)
            if shouldCap && programs.count >= hardLimit { break }
        }
        return programs
    }

    private func applyActionProgram(_ program: [UIAction], to textView: XCUIElement) {
        for action in program {
            switch action {
            case .left:
                textView.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
            case .right:
                textView.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
            case .lineStart:
                textView.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command])
            case .lineEnd:
                textView.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command])
            case .docStart:
                textView.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.command])
            case .docEnd:
                textView.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command])
            case .insertASCII:
                textView.typeText("x")
            case .newline:
                textView.typeText("\n")
            case .backspace:
                textView.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            case .space:
                textView.typeText(" ")
            case .undo:
                textView.typeKey("z", modifierFlags: [.command])
            case .redo:
                textView.typeKey("z", modifierFlags: [.command, .shift])
            }
        }
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

    private func firstTextViewValue(
        _ textView: XCUIElement,
        timeout: TimeInterval,
        predicate: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = (textView.value as? String) ?? ""
            if predicate(current) { return current }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
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

        // UI automation trust is flaky across macOS versions and ad-hoc re-signing.
        // Default behavior is to continue and let the UI run attempt proceed (to avoid false "all skipped").
        // Opt in to strict preflight via env when needed:
        // - KERN_UI_REQUIRE_AX_TRUST=1  => skip immediately if trust is missing
        // - KERN_UI_AX_PROMPT=1         => explicitly prompt during preflight
        let env = ProcessInfo.processInfo.environment
        let strictTrust = env["KERN_UI_REQUIRE_AX_TRUST"] == "1"
        let shouldPrompt = env["KERN_UI_AX_PROMPT"] == "1" || strictTrust

        let isTrusted: Bool
        if shouldPrompt {
            // Avoid referencing `kAXTrustedCheckOptionPrompt` directly: under Swift 6 strict
            // concurrency, importing that global CFString can trigger compile failures.
            let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(opts)
        } else {
            isTrusted = AXIsProcessTrusted()
        }

        guard !strictTrust || isTrusted else {
            let msg = """
            UI tests skipped: Accessibility permission not granted (strict preflight mode).
            Enable it in System Settings > Privacy & Security > Accessibility for:
            - Xcode
            - KernTextKitUITests-Runner
            Quick helper (builds the runner + opens the right panes):
            - ./scripts/open-ui-test-permissions.sh
            If the runner app doesn't appear in the list, add it manually via the + button:
            - Press Cmd+Shift+G and paste:
              \(defaultRunnerAppPath())
            If adding the .app still doesn't stick, try adding the runner *binary* instead:
              \(defaultRunnerBinaryPath())
            Some macOS versions have a Privacy UI bug where the + file picker doesn't add apps.
            Workaround: reveal the Runner.app in Finder and drag-and-drop it into the Accessibility list.
            Then rerun UI tests.
            """
            UIAutomationPreflightCache.skipMessage = msg
            throw XCTSkip(msg)
        }

        if !isTrusted {
            NSLog("""
            [NativeEditorE2ETests] Accessibility trust not detected in non-strict mode.
            Proceeding with UI run attempt. To enforce skip-until-trusted behavior, set:
            KERN_UI_REQUIRE_AX_TRUST=1
            """)
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
        guard let dir = configString("KERN_UI_SCREENSHOT_DIR"), !dir.isEmpty else { return }
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
        if configBool("KERN_UI_DISABLE_SCREENSHOTS") { return .off }
        if let raw = configString("KERN_UI_SCREENSHOTS"), let v = ScreenshotMode(rawValue: raw) { return v }

        // Back-compat:
        // - Previously, screenshots defaulted to failure-only unless KERN_UI_KEEP_SCREENSHOTS=1.
        if configBool("KERN_UI_KEEP_SCREENSHOTS") { return .always }

        return .always
    }

    private func isExhaustiveUIEnabled() -> Bool {
        configBool("KERN_ENABLE_EXHAUSTIVE_TESTS")
    }

    private func uiTypingMode() -> UITypingMode {
        let raw = configString("KERN_UI_TYPING_MODE") ?? "chunked"
        return UITypingMode(rawValue: raw) ?? .chunked
    }

    private func uiChunkInsertionMode() -> UIChunkInsertionMode {
        // Default to paste for runtime practicality; insertChunk() includes reliability fallback.
        let raw = configString("KERN_UI_CHUNK_INSERTION") ?? "paste"
        return UIChunkInsertionMode(rawValue: raw) ?? .paste
    }

    private func defaultRunnerDerivedDataPath() -> String {
        if let explicit = configString("KERN_UI_DERIVED_DATA_PATH"), !explicit.isEmpty {
            return explicit
        }
        // Keep in sync with scripts/test-native-editor.sh and scripts/open-ui-test-permissions.sh.
        return "/Users/aaaaa/Projects/Kern-textkit/.derived-data/tests"
    }

    private func configString(_ key: String) -> String? {
        if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
            return envValue
        }
        if let suite = UserDefaults(suiteName: "com.gradigit.kern.tests") {
            if let suiteValue = suite.string(forKey: key), !suiteValue.isEmpty {
                return suiteValue
            }
            if let raw = suite.object(forKey: key) {
                let value = String(describing: raw)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func configBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = configString(key) else { return defaultValue }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return defaultValue
        }
    }

    private func configInt(_ key: String, default defaultValue: Int? = nil) -> Int? {
        guard let raw = configString(key) else { return defaultValue }
        return Int(raw) ?? defaultValue
    }

    private func defaultRunnerAppPath() -> String {
        defaultRunnerDerivedDataPath() + "/Build/Products/Debug/KernTextKitUITests-Runner.app"
    }

    private func defaultRunnerBinaryPath() -> String {
        defaultRunnerAppPath() + "/Contents/MacOS/KernTextKitUITests-Runner"
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

    private func revealCodeBlockCopyButton(in app: XCUIApplication, textView: XCUIElement) -> XCUIElement? {
        func visibleButton(timeout: TimeInterval) -> XCUIElement? {
            let caret = app.buttons["NativeEditor.CodeCopyButton"]
            if caret.waitForExistence(timeout: timeout), caret.isHittable {
                return caret
            }

            let hover = app.buttons["NativeEditor.CodeCopyButton.Hover"]
            if hover.waitForExistence(timeout: timeout), hover.isHittable {
                return hover
            }
            return nil
        }

        // Probe multiple in-block points so both caret-anchored and hover-anchored
        // chrome become visible deterministically across window sizes.
        let probeOffsets: [(CGFloat, CGFloat)] = [
            (42, 40),
            (120, 66),
            (220, 78),
            (360, 60),
            (520, 36),
        ]

        for (x, y) in probeOffsets {
            clickAtOffset(textView, x: x, y: y)
            if let button = visibleButton(timeout: 0.3) {
                return button
            }
        }

        return visibleButton(timeout: 1.5)
    }

    private func attachTextReport(_ content: String, name: String) {
        let attachment = XCTAttachment(string: content)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
