import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorInitialViewportTests: XCTestCase {
    private struct WowMetricsPayload: Decodable {
        let metrics: [String: Double]
    }

    private static let managedEnvironmentKeys: [String] = [
        "KERN_FORCE_STAGED_OPEN",
        "KERN_STAGED_OPEN_PREFIX_LINES",
        "KERN_STAGED_OPEN_PREFIX_CHARS",
        "KERN_STAGED_OPEN_DELAY_MS",
        "KERN_STAGED_OPEN_IDLE_QUIET_MS",
        "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS",
        "KERN_STAGED_PROMOTION_CONTEXT_CHARS",
        "KERN_STAGED_PROMOTION_DEBOUNCE_MS",
        "KERN_STAGED_PROMOTION_STEP_CHARS",
        "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS",
        "KERN_STAGED_PROMOTION_VIEWPORT_GUARD_CHARS",
        "KERN_STAGED_PROMOTION_VIEWPORT_MICRO_STEP_CHARS",
        "KERN_STAGED_PROMOTION_FRAME_BUDGET_MS",
        "KERN_STAGED_PROMOTION_MAX_VIEWPORT_CORRECTION_PX",
        "KERN_STAGED_PROMOTION_JUMP_THRESHOLD_PX",
        "KERN_STAGED_PROMOTION_IDLE_QUIET_MS",
        "KERN_STAGED_PROMOTION_SCROLL_QUIET_MS",
        "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS",
        "KERN_STAGED_PROMOTION_TURBO_STEP_CHARS",
        "KERN_STAGED_PROMOTION_TURBO_MAX_CATCHUP_STEP_CHARS",
        "KERN_STAGED_PROMOTION_TURBO_FOLLOWUP_DELAY_MS",
        "KERN_STAGED_PROMOTION_TURBO_IDLE_MS",
        "KERN_FORCE_FULL_MARKDOWN_IMPORT",
        "KERN_FORCE_PLAIN_MARKDOWN_IMPORT",
        "KERN_ALLOW_PLAIN_IMPORT_OVERRIDE",
        "KERN_WOW_INTERNAL_METRICS_PATH",
    ]

    nonisolated(unsafe) private static var baselineEnvironment: [String: String?]?

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.baselineEnvironment == nil {
            var snapshot: [String: String?] = [:]
            for key in Self.managedEnvironmentKeys {
                snapshot[key] = getenv(key).map { String(cString: $0) }
            }
            Self.baselineEnvironment = snapshot
        }
    }

    override func tearDownWithError() throws {
        restoreManagedEnvironmentToBaseline()
        try super.tearDownWithError()
    }

    @MainActor
    func testInitialRenderStartsAtDocumentTopWithCaretAtZero() {
        let markdown = """
        # Title

        Intro paragraph.

        ## Section

        Paragraph 1.

        Paragraph 2.

        Paragraph 3.

        ```typescript
        const x: number = 42
        console.log(x)
        ```

        Final paragraph.
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }
        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        XCTAssertEqual(textView.selectedRange().location, 0, "Initial caret should be at document start")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5, "Initial viewport should start at top")

        // Ensure the first paragraph is visible on initial render.
        guard let lm = textView.layoutManager, let tc = textView.textContainer, textView.string.utf16.count > 0 else {
            XCTFail("Missing layout components")
            return
        }
        let firstGlyph = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
        var firstRect = lm.boundingRect(forGlyphRange: firstGlyph, in: tc)
        firstRect.origin.x += textView.textContainerOrigin.x
        firstRect.origin.y += textView.textContainerOrigin.y
        XCTAssertTrue(textView.visibleRect.intersects(firstRect), "First paragraph should be visible at initial render")
    }

    @MainActor
    func testLayoutManagerUsesNonContiguousLayoutForLargeDocumentScrolling() {
        let vc = NativeEditorViewController()
        _ = vc.view
        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        XCTAssertEqual(textView.layoutManager?.allowsNonContiguousLayout, true)
    }

    @MainActor
    func testStagedOpenEventuallyAppliesDeferredFullRendering() {
        let previousForceStaged = getenv("KERN_FORCE_STAGED_OPEN").map { String(cString: $0) }
        let previousPrefixLines = getenv("KERN_STAGED_OPEN_PREFIX_LINES").map { String(cString: $0) }
        let previousPrefixChars = getenv("KERN_STAGED_OPEN_PREFIX_CHARS").map { String(cString: $0) }
        let previousDelayMs = getenv("KERN_STAGED_OPEN_DELAY_MS").map { String(cString: $0) }
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }

        setenv("KERN_FORCE_STAGED_OPEN", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_LINES", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_CHARS", "8", 1)
        setenv("KERN_STAGED_OPEN_DELAY_MS", "150", 1)
        unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")

        defer {
            if let previousForceStaged {
                setenv("KERN_FORCE_STAGED_OPEN", previousForceStaged, 1)
            } else {
                unsetenv("KERN_FORCE_STAGED_OPEN")
            }
            if let previousPrefixLines {
                setenv("KERN_STAGED_OPEN_PREFIX_LINES", previousPrefixLines, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_PREFIX_LINES")
            }
            if let previousPrefixChars {
                setenv("KERN_STAGED_OPEN_PREFIX_CHARS", previousPrefixChars, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_PREFIX_CHARS")
            }
            if let previousDelayMs {
                setenv("KERN_STAGED_OPEN_DELAY_MS", previousDelayMs, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_DELAY_MS")
            }
            if let previousForceFull {
                setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", previousForceFull, 1)
            } else {
                unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
            }
        }

        let markdown = """
        Intro

        **tailbold**
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        XCTAssertTrue(textView.string.contains("**tailbold**"), "Staged render should leave deferred tail markdown untouched initially")

        let expectation = expectation(description: "Deferred full render")
        let deadline = Date().addingTimeInterval(2.0)
        func pollUntilRendered() {
            if textView.string.contains("**tailbold**") == false,
               textView.string.contains("tailbold") {
                expectation.fulfill()
                return
            }
            if Date() >= deadline {
                expectation.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollUntilRendered()
            }
        }
        pollUntilRendered()
        wait(for: [expectation], timeout: 3.0)

        XCTAssertFalse(textView.string.contains("**tailbold**"), "Deferred full render should replace raw markdown tail")
        XCTAssertTrue(textView.string.contains("tailbold"))
    }

    @MainActor
    func testDeferredFullRenderDoesNotTriggerContentChangedCallbacks() {
        let previousForceStaged = getenv("KERN_FORCE_STAGED_OPEN").map { String(cString: $0) }
        let previousPrefixLines = getenv("KERN_STAGED_OPEN_PREFIX_LINES").map { String(cString: $0) }
        let previousPrefixChars = getenv("KERN_STAGED_OPEN_PREFIX_CHARS").map { String(cString: $0) }
        let previousDelayMs = getenv("KERN_STAGED_OPEN_DELAY_MS").map { String(cString: $0) }
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }

        setenv("KERN_FORCE_STAGED_OPEN", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_LINES", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_CHARS", "8", 1)
        setenv("KERN_STAGED_OPEN_DELAY_MS", "80", 1)
        unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")

        defer {
            if let previousForceStaged {
                setenv("KERN_FORCE_STAGED_OPEN", previousForceStaged, 1)
            } else {
                unsetenv("KERN_FORCE_STAGED_OPEN")
            }
            if let previousPrefixLines {
                setenv("KERN_STAGED_OPEN_PREFIX_LINES", previousPrefixLines, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_PREFIX_LINES")
            }
            if let previousPrefixChars {
                setenv("KERN_STAGED_OPEN_PREFIX_CHARS", previousPrefixChars, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_PREFIX_CHARS")
            }
            if let previousDelayMs {
                setenv("KERN_STAGED_OPEN_DELAY_MS", previousDelayMs, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_DELAY_MS")
            }
            if let previousForceFull {
                setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", previousForceFull, 1)
            } else {
                unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
            }
        }

        let markdown = """
        Intro

        **tailbold**
        """

        let vc = NativeEditorViewController()
        _ = vc.view

        var callbackCount = 0
        vc.onContentChanged = { _ in
            callbackCount += 1
        }

        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()
        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        XCTAssertTrue(textView.string.contains("**tailbold**"), "Staged render should initially leave deferred tail raw")

        let settled = expectation(description: "Deferred full render settles")
        let deadline = Date().addingTimeInterval(2.0)
        func pollUntilRendered() {
            if textView.string.contains("**tailbold**") == false,
               textView.string.contains("tailbold") {
                settled.fulfill()
                return
            }
            if Date() >= deadline {
                settled.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pollUntilRendered()
            }
        }
        pollUntilRendered()
        wait(for: [settled], timeout: 3.0)

        XCTAssertFalse(textView.string.contains("**tailbold**"), "Deferred full render should replace raw tail markdown")
        XCTAssertTrue(textView.string.contains("tailbold"), "Deferred full render should keep semantic content")
        XCTAssertEqual(callbackCount, 0, "Deferred full render should not mark content dirty or trigger export callback")
    }

    @MainActor
    func testLargeBenchmarkFixtureOpensWysiwyg() throws {
        let previousForceStaged = getenv("KERN_FORCE_STAGED_OPEN").map { String(cString: $0) }
        let previousPrefixLines = getenv("KERN_STAGED_OPEN_PREFIX_LINES").map { String(cString: $0) }
        let previousPrefixChars = getenv("KERN_STAGED_OPEN_PREFIX_CHARS").map { String(cString: $0) }
        let previousDelayMs = getenv("KERN_STAGED_OPEN_DELAY_MS").map { String(cString: $0) }
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousForcePlain = getenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousAllowPlain = getenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE").map { String(cString: $0) }

        setenv("KERN_FORCE_STAGED_OPEN", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_LINES", "900", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_CHARS", "140000", 1)
        setenv("KERN_STAGED_OPEN_DELAY_MS", "200", 1)
        unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
        unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
        unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")

        defer {
            if let previousForceStaged {
                setenv("KERN_FORCE_STAGED_OPEN", previousForceStaged, 1)
            } else {
                unsetenv("KERN_FORCE_STAGED_OPEN")
            }
            if let previousPrefixLines {
                setenv("KERN_STAGED_OPEN_PREFIX_LINES", previousPrefixLines, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_PREFIX_LINES")
            }
            if let previousPrefixChars {
                setenv("KERN_STAGED_OPEN_PREFIX_CHARS", previousPrefixChars, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_PREFIX_CHARS")
            }
            if let previousDelayMs {
                setenv("KERN_STAGED_OPEN_DELAY_MS", previousDelayMs, 1)
            } else {
                unsetenv("KERN_STAGED_OPEN_DELAY_MS")
            }
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

        let markdown = try loadPerfFixture(name: "native-editor-benchmark.md")
        let vc = NativeEditorViewController()
        _ = vc.view

        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        let firstLine = textView.string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(firstLine, "Native Editor Benchmark (Feature-Dense)")
        XCTAssertFalse(textView.string.hasPrefix("# Native Editor Benchmark"), "Top line should be WYSIWYG-rendered, not raw Markdown syntax")
    }

    @MainActor
    func testLargeDocumentScrollHidesOffscreenCodeBlockChrome() {
        let markdown = """
        ```swift
        let x = 1
        ```

        \(String(repeating: "lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 3_400))
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }
        guard let caretChrome = findSubview(withAXIdentifier: "NativeEditor.CodeBlockChrome.Caret", in: vc.view) else {
            XCTFail("Missing caret chrome")
            return
        }

        let ns = textView.string as NSString
        let codeLoc = ns.range(of: "let x = 1").location
        XCTAssertNotEqual(codeLoc, NSNotFound)
        textView.setSelectedRange(NSRange(location: codeLoc, length: 0))

        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
        let targetY = max(0, maxY - min(2_000, maxY * 0.1))
        clip.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clip)
        vc.view.layoutSubtreeIfNeeded()

        let settled = expectation(description: "scroll chrome update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertTrue(caretChrome.isHidden, "Caret code-block chrome should hide when caret block is off-screen in large documents")
    }

    @MainActor
    func testFarScrollPromotionCatchesUpViewportWithoutWaitingForDeferredFullRender() {
        let envKeys = [
            "KERN_FORCE_STAGED_OPEN",
            "KERN_STAGED_OPEN_PREFIX_LINES",
            "KERN_STAGED_OPEN_PREFIX_CHARS",
            "KERN_STAGED_OPEN_DELAY_MS",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS",
            "KERN_STAGED_PROMOTION_STEP_CHARS",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT",
        ]
        var previous: [String: String?] = [:]
        for key in envKeys {
            previous[key] = getenv(key).map { String(cString: $0) }
        }

        setenv("KERN_FORCE_STAGED_OPEN", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_LINES", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_CHARS", "12", 1)
        setenv("KERN_STAGED_OPEN_DELAY_MS", "0", 1)
        setenv("KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS", "1", 1)
        setenv("KERN_STAGED_PROMOTION_DEBOUNCE_MS", "0", 1)
        setenv("KERN_STAGED_PROMOTION_STEP_CHARS", "120000", 1)
        setenv("KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS", "1200000", 1)
        setenv("KERN_STAGED_PROMOTION_IDLE_QUIET_MS", "0", 1)
        unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")

        defer {
            for key in envKeys {
                if let value = previous[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 14_000)
        let markdown = """
        # Top Heading

        \(filler)
        # Tail Heading

        **tailbold**
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }

        XCTAssertTrue(textView.string.contains("**tailbold**"), "Initial staged render should leave far tail raw")
        XCTAssertTrue(textView.string.contains("# Tail Heading"), "Initial staged render should leave far heading raw")

        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
        let targetY = max(0, maxY - min(2_000, maxY * 0.1))
        clip.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clip)
        vc.view.layoutSubtreeIfNeeded()

        let promoted = expectation(description: "staged viewport catch-up")
        let deadline = Date().addingTimeInterval(6.0)
        func poll() {
            let done = !textView.string.contains("**tailbold**")
                && textView.string.contains("tailbold")
                && !textView.string.contains("# Tail Heading")
                && textView.string.contains("Tail Heading")
            if done || Date() >= deadline {
                promoted.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                poll()
            }
        }
        poll()
        wait(for: [promoted], timeout: 7.0)

        XCTAssertFalse(textView.string.contains("**tailbold**"), "Viewport promotion should style far tail without deferred full render")
        XCTAssertFalse(textView.string.contains("# Tail Heading"), "Viewport promotion should style far heading")
    }

    @MainActor
    func testFarScrollPromotionKeepsViewportStableWhileFormattingCatchesUp() {
        let envKeys = [
            "KERN_FORCE_STAGED_OPEN",
            "KERN_STAGED_OPEN_PREFIX_LINES",
            "KERN_STAGED_OPEN_PREFIX_CHARS",
            "KERN_STAGED_OPEN_DELAY_MS",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS",
            "KERN_STAGED_PROMOTION_STEP_CHARS",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS",
            "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT",
        ]
        var previous: [String: String?] = [:]
        for key in envKeys {
            previous[key] = getenv(key).map { String(cString: $0) }
        }

        setenv("KERN_FORCE_STAGED_OPEN", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_LINES", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_CHARS", "12", 1)
        setenv("KERN_STAGED_OPEN_DELAY_MS", "0", 1)
        setenv("KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS", "1", 1)
        setenv("KERN_STAGED_PROMOTION_DEBOUNCE_MS", "0", 1)
        setenv("KERN_STAGED_PROMOTION_STEP_CHARS", "90000", 1)
        setenv("KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS", "220000", 1)
        setenv("KERN_STAGED_PROMOTION_IDLE_QUIET_MS", "0", 1)
        setenv("KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS", "35", 1)
        unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")

        defer {
            for key in envKeys {
                if let value = previous[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 16_000)
        let markdown = """
        # Top Heading

        \(filler)
        # Tail Heading

        **tailbold**
        """

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }
        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }

        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(clip)
        vc.view.layoutSubtreeIfNeeded()

        let baselineY = clip.bounds.origin.y
        let baselineTopChar = visibleTopCharacterLocation(in: textView)
        var lastY = baselineY
        var maxStepDrift: CGFloat = 0
        var maxCumulativeDrift: CGFloat = 0

        let settled = expectation(description: "promotion settles without viewport jumps")
        let deadline = Date().addingTimeInterval(4.5)

        func poll() {
            vc.view.layoutSubtreeIfNeeded()
            let currentY = clip.bounds.origin.y
            let stepDrift = abs(currentY - lastY)
            lastY = currentY
            maxStepDrift = max(maxStepDrift, stepDrift)
            maxCumulativeDrift = max(maxCumulativeDrift, abs(currentY - baselineY))

            let done = !textView.string.contains("**tailbold**")
                && !textView.string.contains("# Tail Heading")
            if done || Date() >= deadline {
                settled.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                poll()
            }
        }
        poll()
        wait(for: [settled], timeout: 5.0)

        let finalTopChar = visibleTopCharacterLocation(in: textView)
        XCTAssertLessThanOrEqual(maxStepDrift, 900, "Viewport should avoid severe jumps while staged formatting catches up")
        XCTAssertLessThanOrEqual(maxCumulativeDrift, 2_000, "Viewport should avoid excessive cumulative drift while staged formatting catches up")
        XCTAssertLessThan(abs(finalTopChar - baselineTopChar), 6_000, "Top visible content should remain broadly stable while promotions apply")
        XCTAssertFalse(textView.string.contains("**tailbold**"), "Promotion should finish styling far tail")
        XCTAssertFalse(textView.string.contains("# Tail Heading"), "Promotion should finish styling far heading")
    }

    @MainActor
    func testDeferredFullRenderDefersDuringRapidScrollThenCompletesWithoutSnapback() {
        let env: [String: String?] = [
            "KERN_FORCE_STAGED_OPEN": "1",
            "KERN_STAGED_OPEN_PREFIX_LINES": "1",
            "KERN_STAGED_OPEN_PREFIX_CHARS": "12",
            "KERN_STAGED_OPEN_DELAY_MS": "20",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS": "99999999",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS": "0",
            "KERN_STAGED_PROMOTION_STEP_CHARS": "120000",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS": "1200000",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS": "40",
            "KERN_STAGED_PROMOTION_SCROLL_QUIET_MS": "90",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT": nil,
        ]

        withTemporaryEnvironment(env) {
            let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 15_000)
            let markdown = """
            # Top Heading

            \(filler)
            # Tail Heading

            **tailbold**
            """

            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = markdown
            vc.view.layoutSubtreeIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }
            guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
                XCTFail("Missing NativeEditor.ScrollView")
                return
            }

            XCTAssertTrue(textView.string.contains("**tailbold**"), "Initial staged render should keep tail raw before deferred full render")

            let clip = scrollView.contentView
            let burstDeadline = Date().addingTimeInterval(1.2)
            var tick = 0
            var lastTickAt = Date()
            var maxHeartbeatGap: TimeInterval = 0
            while Date() < burstDeadline {
                let now = Date()
                maxHeartbeatGap = max(maxHeartbeatGap, now.timeIntervalSince(lastTickAt))
                lastTickAt = now

                tick += 1
                let currentMaxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
                let targetY: CGFloat
                if tick % 2 == 0 {
                    targetY = currentMaxY
                } else {
                    targetY = max(0, currentMaxY - 2200)
                }
                clip.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
                vc.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }

            let yAtScrollStop = clip.bounds.origin.y
            let topCharAtScrollStop = visibleTopCharacterLocation(in: textView)

            let settled = expectation(description: "deferred full render converges after rapid scroll burst")
            let deadline = Date().addingTimeInterval(6.0)
            func poll() {
                let done = !textView.string.contains("**tailbold**")
                    && !textView.string.contains("# Tail Heading")
                if done || Date() >= deadline {
                    settled.fulfill()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    poll()
                }
            }
            poll()
            wait(for: [settled], timeout: 7.0)

            XCTAssertFalse(textView.string.contains("**tailbold**"), "Deferred full render should eventually style tail emphasis")
            XCTAssertFalse(textView.string.contains("# Tail Heading"), "Deferred full render should eventually style tail heading")
            XCTAssertLessThanOrEqual(maxHeartbeatGap, 0.8, "Main loop heartbeat gap should stay bounded during rapid scroll burst")

            let finalY = clip.bounds.origin.y
            let finalTopChar = visibleTopCharacterLocation(in: textView)
            XCTAssertLessThanOrEqual(abs(finalY - yAtScrollStop), 2_500, "Viewport should not snap back drastically after deferred full render")
            XCTAssertLessThan(abs(finalTopChar - topCharAtScrollStop), 8_000, "Top visible content should remain broadly stable after deferred convergence")
        }
    }

    @MainActor
    func testStagedPromotionMetricsStayWithinJankBudget() {
        let metricsPath = uniqueTempWowMetricsPath()
        defer { try? FileManager.default.removeItem(atPath: metricsPath) }

        let env: [String: String?] = [
            "KERN_FORCE_STAGED_OPEN": "1",
            "KERN_STAGED_OPEN_PREFIX_LINES": "1",
            "KERN_STAGED_OPEN_PREFIX_CHARS": "12",
            "KERN_STAGED_OPEN_DELAY_MS": "0",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS": "1",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS": "0",
            "KERN_STAGED_PROMOTION_STEP_CHARS": "140000",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS": "1200000",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_SCROLL_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS": "10",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT": nil,
            "KERN_WOW_INTERNAL_METRICS_PATH": metricsPath,
        ]

        withTemporaryEnvironment(env) {
            let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 14_000)
            let markdown = """
            # Top Heading

            \(filler)
            # Tail Heading

            **tailbold**
            """

            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = markdown
            vc.view.layoutSubtreeIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }
            guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
                XCTFail("Missing NativeEditor.ScrollView")
                return
            }

            let clip = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clip)
            vc.view.layoutSubtreeIfNeeded()

            let deadline = Date().addingTimeInterval(8.0)
            var contentDone = false
            var hasFullReady = false
            while Date() < deadline {
                contentDone = !textView.string.contains("**tailbold**")
                    && !textView.string.contains("# Tail Heading")
                let metrics = Self.loadWowMetrics(at: metricsPath)
                hasFullReady = metrics?["wow_full_document_fidelity_ready_latency_ms"] != nil
                if contentDone && hasFullReady {
                    break
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }

            XCTAssertTrue(contentDone, "Promotion should finish styling tail content")
            XCTAssertTrue(hasFullReady, "Full fidelity metric should be emitted before deadline")

            guard let metrics = Self.loadWowMetrics(at: metricsPath) else {
                XCTFail("Missing WOW metrics payload")
                return
            }

            let applyCount = metrics["wow_staged_promotion_apply_count"] ?? 0
            let over16 = metrics["wow_staged_promotion_apply_over_16ms_count"] ?? 0
            let over33 = metrics["wow_staged_promotion_apply_over_33ms_count"] ?? 0
            let over50 = metrics["wow_staged_promotion_apply_over_50ms_count"] ?? 0
            let over100 = metrics["wow_staged_promotion_apply_over_100ms_count"] ?? 0
            let fullReady = metrics["wow_full_document_fidelity_ready_latency_ms"] ?? 0
            let interactive = metrics["time_to_interactive_ms"] ?? 0
            let fullFidelity = metrics["time_to_full_fidelity_ms"] ?? 0
            let promotionP99 = metrics["promotion_apply_slice_p99_ms"] ?? 0
            let jumpCount = metrics["scroll_jump_count"] ?? 0
            let jumpMax = metrics["scroll_jump_max_px"] ?? 0
            let anchorRebaseCount = metrics["anchor_rebase_count"] ?? 0
            let anchorRebaseFailCount = metrics["anchor_rebase_fail_count"] ?? 0

            XCTAssertGreaterThan(applyCount, 0, "Expected at least one staged promotion apply")
            XCTAssertEqual(over100, 0, "No staged promotion apply should exceed 100ms")
            XCTAssertLessThanOrEqual(over50, 1, "50ms+ applies should be exceptional")
            XCTAssertLessThanOrEqual(over33, 4, "33ms+ applies should remain tightly bounded")
            XCTAssertLessThanOrEqual(over16, 20, "16ms+ applies should stay under the guardrail budget")
            XCTAssertGreaterThan(fullReady, 0, "Full-document fidelity metric should be emitted")
            XCTAssertLessThanOrEqual(fullReady, 8_000, "Full-document fidelity should complete within guardrail budget")
            XCTAssertGreaterThan(interactive, 0, "Interactive alias metric should be emitted")
            XCTAssertGreaterThan(fullFidelity, 0, "Full-fidelity alias metric should be emitted")
            XCTAssertLessThanOrEqual(promotionP99, 80, "Promotion p99 apply slice should stay below hard jank guardrail")
            XCTAssertLessThanOrEqual(jumpCount, 2, "Scroll jump count should remain near-zero under promotion")
            XCTAssertLessThanOrEqual(jumpMax, 120, "Scroll jump max should stay bounded")
            XCTAssertGreaterThanOrEqual(anchorRebaseCount, 0)
            XCTAssertEqual(anchorRebaseFailCount, 0, "Anchor remap should not fail")
        }
    }

    @MainActor
    func testStagedPromotionStylesTailBlockMathWithoutCrashing() {
        let env: [String: String?] = [
            "KERN_FORCE_STAGED_OPEN": "1",
            "KERN_STAGED_OPEN_PREFIX_LINES": "1",
            "KERN_STAGED_OPEN_PREFIX_CHARS": "12",
            "KERN_STAGED_OPEN_DELAY_MS": "0",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS": "1",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS": "0",
            "KERN_STAGED_PROMOTION_STEP_CHARS": "140000",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS": "1400000",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_SCROLL_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS": "8",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT": nil,
        ]

        withTemporaryEnvironment(env) {
            let filler = String(repeating: "Line filler for staged promotion coverage.\n", count: 18_000)
            let markdown = """
            # Top Heading

            \(filler)
            ## Tail Math

            $$
            E = mc^2
            $$

            Tail paragraph
            """

            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = markdown
            vc.view.layoutSubtreeIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }

            XCTAssertTrue(textView.string.contains("$$"), "Initial staged render should keep far-tail block math raw")

            let settled = expectation(description: "staged promotion styles tail math")
            let deadline = Date().addingTimeInterval(7.0)
            func poll() {
                let done = !textView.string.contains("$$")
                    && textView.string.contains("Tail Math")
                    && textView.string.contains("Tail paragraph")
                if done || Date() >= deadline {
                    settled.fulfill()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    poll()
                }
            }
            poll()
            wait(for: [settled], timeout: 8.0)

            XCTAssertFalse(textView.string.contains("$$"), "Tail block math should be promoted into rendered attachment form")
            XCTAssertTrue(textView.string.contains("Tail paragraph"))
        }
    }

    @MainActor
    func testStagedPromotionRapidScrollMaintainsViewportStabilityBudget() {
        let env: [String: String?] = [
            "KERN_FORCE_STAGED_OPEN": "1",
            "KERN_STAGED_OPEN_PREFIX_LINES": "1",
            "KERN_STAGED_OPEN_PREFIX_CHARS": "12",
            "KERN_STAGED_OPEN_DELAY_MS": "0",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS": "1",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS": "0",
            "KERN_STAGED_PROMOTION_STEP_CHARS": "120000",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS": "1200000",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_SCROLL_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS": "10",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT": nil,
        ]

        withTemporaryEnvironment(env) {
            let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 15_000)
            let markdown = """
            # Top Heading

            \(filler)
            # Tail Heading

            **tailbold**
            """

            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = markdown
            vc.view.layoutSubtreeIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }
            guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
                XCTFail("Missing NativeEditor.ScrollView")
                return
            }

            let clip = scrollView.contentView
            var maxTargetError: CGFloat = 0
            var lastTickAt = Date()
            var maxHeartbeatGap: TimeInterval = 0

            let deadline = Date().addingTimeInterval(5.0)
            var tick = 0
            var done = false
            while Date() < deadline {
                let now = Date()
                maxHeartbeatGap = max(maxHeartbeatGap, now.timeIntervalSince(lastTickAt))
                lastTickAt = now
                tick += 1
                let currentMaxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
                let targetY: CGFloat
                if tick % 2 == 0 {
                    targetY = currentMaxY
                } else {
                    targetY = max(0, currentMaxY - 1800)
                }
                clip.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
                vc.view.layoutSubtreeIfNeeded()

                let currentY = clip.bounds.origin.y
                maxTargetError = max(maxTargetError, abs(currentY - targetY))

                done = !textView.string.contains("**tailbold**")
                    && !textView.string.contains("# Tail Heading")
                if done {
                    break
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(done, "Rapid scroll promotion should style tail content before deadline")

            XCTAssertLessThanOrEqual(maxTargetError, 2_500, "Rapid scroll path should stay reasonably close to commanded viewport targets")
            XCTAssertLessThanOrEqual(maxHeartbeatGap, 0.8, "Main loop heartbeat gap should stay bounded during rapid scroll stress")
        }
    }

    @MainActor
    func testStagedPromotionDefersWhileLiveScrollAndResumesAfterEnd() {
        let metricsPath = uniqueTempWowMetricsPath()
        defer { try? FileManager.default.removeItem(atPath: metricsPath) }

        let env: [String: String?] = [
            "KERN_FORCE_STAGED_OPEN": "1",
            "KERN_STAGED_OPEN_PREFIX_LINES": "1",
            "KERN_STAGED_OPEN_PREFIX_CHARS": "12",
            "KERN_STAGED_OPEN_DELAY_MS": "0",
            "KERN_STAGED_OPEN_DEFERRED_FULL_DISABLE_THRESHOLD_CHARS": "1",
            "KERN_STAGED_PROMOTION_DEBOUNCE_MS": "0",
            "KERN_STAGED_PROMOTION_STEP_CHARS": "180000",
            "KERN_STAGED_PROMOTION_MAX_CATCHUP_STEP_CHARS": "1800000",
            "KERN_STAGED_PROMOTION_IDLE_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_SCROLL_QUIET_MS": "0",
            "KERN_STAGED_PROMOTION_FOLLOWUP_DELAY_MS": "8",
            "KERN_FORCE_FULL_MARKDOWN_IMPORT": nil,
            "KERN_WOW_INTERNAL_METRICS_PATH": metricsPath,
        ]

        withTemporaryEnvironment(env) {
            let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n", count: 16_000)
            let markdown = """
            # Top Heading

            \(filler)
            # Tail Heading

            **tailbold**
            """

            let vc = NativeEditorViewController()
            _ = vc.view
            vc.stringValue = markdown
            vc.view.layoutSubtreeIfNeeded()

            guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
                XCTFail("Missing NativeEditor.TextView")
                return
            }
            guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
                XCTFail("Missing NativeEditor.ScrollView")
                return
            }

            let clip = scrollView.contentView
            NotificationCenter.default.post(
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )

            let liveScrollDeadline = Date().addingTimeInterval(1.1)
            var tick = 0
            while Date() < liveScrollDeadline {
                tick += 1
                let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
                let targetY: CGFloat = (tick % 2 == 0) ? maxY : max(0, maxY - 2200)
                clip.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
                vc.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }

            let metricsDuringLiveScroll = Self.loadWowMetrics(at: metricsPath) ?? [:]
            let skippedDuringLiveScroll = metricsDuringLiveScroll["wow_staged_promotion_skipped_live_scroll_count"] ?? 0
            XCTAssertGreaterThan(
                skippedDuringLiveScroll,
                0,
                "Expected staged promotion scheduling/apply to defer during live scroll"
            )

            NotificationCenter.default.post(
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )

            let settled = expectation(description: "staged promotion resumes after live scroll ends")
            let deadline = Date().addingTimeInterval(8.0)
            func poll() {
                let done = !textView.string.contains("**tailbold**")
                    && !textView.string.contains("# Tail Heading")
                let fullReady = (Self.loadWowMetrics(at: metricsPath)?["wow_full_document_fidelity_ready_latency_ms"]) != nil
                if (done && fullReady) || Date() >= deadline {
                    settled.fulfill()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    poll()
                }
            }
            poll()
            wait(for: [settled], timeout: 9.0)

            XCTAssertFalse(textView.string.contains("**tailbold**"), "Tail emphasis should eventually style after live scroll ends")
            XCTAssertFalse(textView.string.contains("# Tail Heading"), "Tail heading should eventually style after live scroll ends")
            XCTAssertNotNil(
                Self.loadWowMetrics(at: metricsPath)?["wow_full_document_fidelity_ready_latency_ms"],
                "Full-document fidelity metric should eventually emit after live scroll ends"
            )
        }
    }

    @MainActor
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private func visibleTopCharacterLocation(in textView: NSTextView) -> Int {
        guard
            let lm = textView.layoutManager,
            let tc = textView.textContainer,
            let storage = textView.textStorage,
            storage.length > 0
        else { return 0 }

        let visible = textView.visibleRect
        let probe = NSPoint(
            x: max(0, visible.minX + 8 - textView.textContainerOrigin.x),
            y: max(0, visible.minY + 8 - textView.textContainerOrigin.y)
        )
        let glyphIndex = lm.glyphIndex(for: probe, in: tc)
        if glyphIndex >= lm.numberOfGlyphs { return max(0, storage.length - 1) }
        return min(max(0, storage.length - 1), lm.characterIndexForGlyph(at: glyphIndex))
    }

    private func uniqueTempWowMetricsPath() -> String {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return tempDir
            .appendingPathComponent("kern-wow-\(UUID().uuidString).json")
            .path
    }

    private static func loadWowMetrics(at path: String) -> [String: Double]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let payload = try? JSONDecoder().decode(WowMetricsPayload.self, from: data) else { return nil }
        return payload.metrics
    }

    private func withTemporaryEnvironment(_ values: [String: String?], body: () -> Void) {
        var previous: [String: String?] = [:]
        for key in values.keys {
            previous[key] = getenv(key).map { String(cString: $0) }
        }

        for (key, value) in values {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, value) in previous {
                if let restored = value {
                    setenv(key, restored, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        body()
    }

    private func restoreManagedEnvironmentToBaseline() {
        guard let baseline = Self.baselineEnvironment else { return }
        for key in Self.managedEnvironmentKeys {
            if let value = baseline[key] ?? nil {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }
}
