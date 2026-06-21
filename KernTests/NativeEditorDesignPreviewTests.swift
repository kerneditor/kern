import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorDesignPreviewTests: XCTestCase {
    @MainActor
    func testCaptureThemeAndWidthComparisonPreviews() throws {
        guard Self.captureDesignPreviewsEnabled(repositoryRoot: repositoryRoot()) else {
            throw XCTSkip("Set KERN_CAPTURE_DESIGN_PREVIEWS=1 or create tmp/kern-brand-exploration/capture-design-previews.enabled to write design comparison screenshots.")
        }

        let root = repositoryRoot()
        let outputDirectory = root
            .appendingPathComponent("test-results", isDirectory: true)
            .appendingPathComponent("design-previews", isDirectory: true)
            .appendingPathComponent(Self.timestamp(), isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let fixtureURL = root
            .appendingPathComponent("test-fixtures", isDirectory: true)
            .appendingPathComponent("design-system-preview.fixture.md")
        let markdown = Self.designSystemPreviewMarkdown

        let scenarios: [PreviewScenario] = [
            .init(name: "kern-paper-centered-860", theme: .kernPaper, appearance: .aqua, widthMode: .centered, maxWidth: 860),
            .init(name: "kern-graphite-centered-860", theme: .kernGraphite, appearance: .darkAqua, widthMode: .centered, maxWidth: 860),
            .init(name: "kern-ice-centered-860", theme: .kernIce, appearance: .darkAqua, widthMode: .centered, maxWidth: 860),
            .init(name: "kern-ink-centered-860", theme: .kernInk, appearance: .aqua, widthMode: .centered, maxWidth: 860),
            .init(name: "kern-wonder-centered-860", theme: .kernWonder, appearance: .aqua, widthMode: .centered, maxWidth: 860),
        ]
        let slices: [PreviewSlice] = [
            .init(name: "top", scrollOffset: 0),
            .init(name: "blocks", scrollOffset: 680),
        ]

        var manifestLines: [String] = [
            "# Kern design previews",
            "",
            "Fixture base URL: \(fixtureURL.path)",
            "Editor viewport: 1280x1080",
            "Settings viewport: 720x980",
            "",
        ]

        for scenario in scenarios {
            for slice in slices {
                let name = "\(scenario.name)-\(slice.name)"
                let url = outputDirectory.appendingPathComponent("\(name).png")
                try capturePreview(
                    scenario: scenario,
                    slice: slice,
                    markdown: markdown,
                    fixtureURL: fixtureURL,
                    size: NSSize(width: 1280, height: 1080),
                    destination: url
                )
                manifestLines.append("- \(name): \(url.path)")
            }

            let settingsName = "\(scenario.name)-settings"
            let settingsURL = outputDirectory.appendingPathComponent("\(settingsName).png")
            try captureSettingsPreview(
                scenario: scenario,
                destination: settingsURL
            )
            manifestLines.append("- \(settingsName): \(settingsURL.path)")
        }

        try manifestLines.joined(separator: "\n").write(
            to: outputDirectory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    @MainActor
    private func capturePreview(
        scenario: PreviewScenario,
        slice: PreviewSlice,
        markdown: String,
        fixtureURL: URL,
        size: NSSize,
        destination: URL
    ) throws {
        let defaults = UserDefaults.standard
        let keys = [
            NativeEditorAppearance.themeModeKey,
            NativeEditorAppearance.readableWidthModeKey,
            NativeEditorAppearance.readableMaxWidthKey,
            NativeEditorAppearance.fontFamilyKey,
            NativeEditorAppearance.fontDesignKey,
            NativeEditorAppearance.fontSizeKey,
            "nativeEditor.exportDialect",
            "nativeEditor.gfmExtensionExportStrategy",
            "nativeEditor.taskRendering",
            "nativeEditor.orderedTasksEnabled",
            "nativeEditor.headingCheckboxesEnabled",
            "nativeEditor.orderedListNumbering",
            NativeEditorSyntaxVisibilityMode.userDefaultsKey,
            "nativeEditor.mermaidRenderMode",
            "nativeEditor.checkboxHitTarget",
            "nativeEditor.headingOutlineVisible",
            MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey,
        ]
        let previous = keys.reduce(into: [String: Any?]()) { partial, key in
            partial[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(scenario.theme.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        defaults.set(scenario.widthMode.rawValue, forKey: NativeEditorAppearance.readableWidthModeKey)
        defaults.set(scenario.maxWidth, forKey: NativeEditorAppearance.readableMaxWidthKey)
        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
        defaults.set(NativeEditorFontDesign.system.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
        defaults.set(16, forKey: NativeEditorAppearance.fontSizeKey)
        defaults.set("gfm", forKey: "nativeEditor.exportDialect")
        defaults.set("preserve", forKey: "nativeEditor.gfmExtensionExportStrategy")
        defaults.set("gfm", forKey: "nativeEditor.taskRendering")
        defaults.set(true, forKey: "nativeEditor.orderedTasksEnabled")
        defaults.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
        defaults.set("gfmDefault", forKey: "nativeEditor.orderedListNumbering")
        defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        defaults.set("rich", forKey: "nativeEditor.mermaidRenderMode")
        defaults.set("glyph", forKey: "nativeEditor.checkboxHitTarget")
        defaults.set(false, forKey: "nativeEditor.headingOutlineVisible")
        defaults.set(false, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let viewController = NativeEditorViewController()
        _ = viewController.view
        viewController.documentURL = fixtureURL

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = viewController
        window.appearance = NSAppearance(named: scenario.appearance)
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        window.layoutIfNeeded()
        defer { window.close() }

        viewController.stringValue = markdown
        settle(viewController.view)
        scrollPreview(viewController.view, to: slice.scrollOffset)
        settle(viewController.view)

        try writePNG(of: viewController.view, to: destination)
    }

    @MainActor
    private func captureSettingsPreview(
        scenario: PreviewScenario,
        destination: URL
    ) throws {
        let defaults = UserDefaults.standard
        let keys = [
            NativeEditorAppearance.themeModeKey,
            NativeEditorAppearance.readableWidthModeKey,
            NativeEditorAppearance.readableMaxWidthKey,
            NativeEditorAppearance.fontFamilyKey,
            NativeEditorAppearance.fontDesignKey,
            NativeEditorAppearance.fontSizeKey,
            "nativeEditor.exportDialect",
            "nativeEditor.gfmExtensionExportStrategy",
            "nativeEditor.taskRendering",
            "nativeEditor.orderedTasksEnabled",
            "nativeEditor.headingCheckboxesEnabled",
            "nativeEditor.orderedListNumbering",
            NativeEditorSyntaxVisibilityMode.userDefaultsKey,
            "nativeEditor.mermaidRenderMode",
            "nativeEditor.checkboxHitTarget",
            MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey,
        ]
        let previous = keys.reduce(into: [String: Any?]()) { partial, key in
            partial[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(scenario.theme.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        defaults.set(scenario.widthMode.rawValue, forKey: NativeEditorAppearance.readableWidthModeKey)
        defaults.set(scenario.maxWidth, forKey: NativeEditorAppearance.readableMaxWidthKey)
        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
        defaults.set(NativeEditorFontDesign.system.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
        defaults.set(16, forKey: NativeEditorAppearance.fontSizeKey)
        defaults.set("gfm", forKey: "nativeEditor.exportDialect")
        defaults.set("preserve", forKey: "nativeEditor.gfmExtensionExportStrategy")
        defaults.set("gfm", forKey: "nativeEditor.taskRendering")
        defaults.set(true, forKey: "nativeEditor.orderedTasksEnabled")
        defaults.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
        defaults.set("gfmDefault", forKey: "nativeEditor.orderedListNumbering")
        defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        defaults.set("rich", forKey: "nativeEditor.mermaidRenderMode")
        defaults.set("marker", forKey: "nativeEditor.checkboxHitTarget")
        defaults.set(false, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)

        let controller = NativeEditorPreferencesWindowController(defaults: defaults)
        defer { controller.close() }

        guard let window = controller.window,
              let contentView = window.contentView else {
            XCTFail("Expected settings window content view")
            return
        }

        window.appearance = NSAppearance(named: scenario.appearance)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NativeEditorAppearance.editorBackgroundColor(
            defaults: defaults,
            appearance: window.effectiveAppearance
        ).cgColor
        controller.refreshFromDefaults()
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        settle(contentView)

        try writePNG(of: contentView, to: destination)
    }

    @MainActor
    private func scrollPreview(_ view: NSView, to offset: CGFloat) {
        guard offset > 0,
              let scrollView = descendant(withAccessibilityIdentifier: "NativeEditor.ScrollView", in: view) as? NSScrollView else {
            return
        }
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maxOffset = max(0, documentHeight - scrollView.contentView.bounds.height)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(offset, maxOffset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    private func descendant(withAccessibilityIdentifier identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for child in root.subviews {
            if let match = descendant(withAccessibilityIdentifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func settle(_ view: NSView) {
        for _ in 0..<8 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    private func writePNG(of view: NSView, to destination: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create bitmap representation")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode preview PNG")
            return
        }
        try png.write(to: destination)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        return formatter.string(from: Date())
    }

    private static func captureDesignPreviewsEnabled(repositoryRoot: URL) -> Bool {
        if ProcessInfo.processInfo.environment["KERN_CAPTURE_DESIGN_PREVIEWS"] == "1" {
            return true
        }
        return FileManager.default.fileExists(
            atPath: repositoryRoot
                .appendingPathComponent("tmp", isDirectory: true)
                .appendingPathComponent("kern-brand-exploration", isDirectory: true)
                .appendingPathComponent("capture-design-previews.enabled")
                .path
        )
    }

    private static let designSystemPreviewMarkdown = """
    # Kern Design QA Fixture

    A native TextKit WYSIWYG document with **bold**, *italic*, ~~strike~~, `inline code`, [links](https://example.com), footnote-like text, and enough density to catch baseline issues.

    - [ ] Unchecked task with a longer label and inline `token.value`
    - [x] Completed task with strikethrough semantics
    1. Ordered item with `monospace`
    2. Ordered item with **strong** text

    > [!NOTE] Callout card
    > Editorial note using inline `CIDR` text, a **bold** term, and a second line for radius and baseline checks.

    > [!WARNING] Risk callout
    > Warning content should be distinct without becoming noisy.

    | Element | Light theme | Dark theme | QA concern |
    | --- | --- | --- | --- |
    | Inline code | `brand.600` | `brand.300` | background alignment |
    | Checkbox | unchecked | checked | vertical centering |
    | Callout | note/warning | status accents | readable contrast |

    ```swift
    struct ThemeToken {
        let name: String
        let light: NSColor
        let dark: NSColor
    }
    ```

    Block math:

    $$
    E = mc^2 + \\int_0^1 x^2 dx
    $$

    Mermaid:

    ```mermaid
    flowchart TD
      A[Open markdown] --> B[Native TextKit render]
      B --> C{WYSIWYG?}
      C -->|yes| D[Edit directly]
      C -->|no| E[Show source fallback]
    ```

    Local image:

    ![Local sample](screenshots/01-default-sample.png)
    """
}

private struct PreviewScenario {
    let name: String
    let theme: NativeEditorThemeMode
    let appearance: NSAppearance.Name
    let widthMode: NativeEditorReadableWidthMode
    let maxWidth: Double
}

private struct PreviewSlice {
    let name: String
    let scrollOffset: CGFloat
}
