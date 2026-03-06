import XCTest
@testable import KernTextKit

final class NativeEditorPreferencesTests: XCTestCase {
    @MainActor
    func testTaskRenderingPreferenceChangeRerendersOpenEditorImmediately() {
        let defaults = UserDefaults.standard
        let key = "nativeEditor.taskRendering"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeMarkdownCodec.Options.TaskRendering.gfm.rawValue, forKey: key)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "- [ ] task bullet\n"

        let gfmRendered = vc.attributedTextForTesting().string
        XCTAssertFalse(gfmRendered.contains("•"), "GFM task rendering should not include bullet marker")
        XCTAssertTrue(gfmRendered.contains("☐"))

        defaults.set(NativeMarkdownCodec.Options.TaskRendering.kern.rawValue, forKey: key)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let kernRendered = vc.attributedTextForTesting().string
        XCTAssertTrue(kernRendered.contains("•"), "Kern task rendering should include bullet marker")
        XCTAssertTrue(kernRendered.contains("☐"))
    }

    @MainActor
    func testMermaidRenderModePreferenceChangeRerendersOpenEditorImmediately() {
        let defaults = UserDefaults.standard
        let key = "nativeEditor.mermaidRenderMode"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set("rich", forKey: key)
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        ```mermaid
        graph TD
          A[Start] --> B[Done]
        ```
        """

        let richMode = firstMermaidAttachment(in: vc.attributedTextForTesting())
        XCTAssertEqual(richMode?.debugEffectiveRenderModeForTesting, .rich)

        defaults.set("ascii", forKey: key)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let asciiMode = firstMermaidAttachment(in: vc.attributedTextForTesting())
        XCTAssertEqual(asciiMode?.debugEffectiveRenderModeForTesting, .ascii)
    }

    @MainActor
    func testSyntaxVisibilityPreferenceChangeRerendersOpenEditorImmediately() {
        let defaults = UserDefaults.standard
        let key = NativeEditorSyntaxVisibilityMode.userDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: key)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        - [ ] task
        [docs](https://example.com/docs)
        """

        let wysiwyg = vc.attributedTextForTesting().string
        XCTAssertTrue(wysiwyg.contains("☐"), "WYSIWYG mode should render task checkbox glyphs")
        XCTAssertFalse(wysiwyg.contains("[docs]("), "WYSIWYG mode should hide inline link source syntax")

        defaults.set(NativeEditorSyntaxVisibilityMode.markdown.rawValue, forKey: key)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let markdownVisible = vc.attributedTextForTesting().string
        XCTAssertTrue(markdownVisible.contains("- [ ] task"), "Markdown mode should keep raw task syntax visible")
        XCTAssertTrue(
            markdownVisible.contains("[docs](https://example.com/docs)"),
            "Markdown mode should keep raw inline link syntax visible"
        )

        defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: key)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let roundTrippedWysiwyg = vc.attributedTextForTesting().string
        XCTAssertTrue(roundTrippedWysiwyg.contains("☐"), "Switching back to WYSIWYG should restore rendered checkbox glyphs")
        XCTAssertFalse(roundTrippedWysiwyg.contains("[docs]("), "Switching back to WYSIWYG should hide source syntax again")
    }

    @MainActor
    func testFontSizePreferenceChangeRerendersOpenEditorImmediately() {
        let defaults = UserDefaults.standard
        let sizeKey = NativeEditorAppearance.fontSizeKey
        let designKey = NativeEditorAppearance.fontDesignKey
        let familyKey = NativeEditorAppearance.fontFamilyKey
        let previousSize = defaults.object(forKey: sizeKey)
        let previousDesign = defaults.object(forKey: designKey)
        let previousFamily = defaults.object(forKey: familyKey)
        defer {
            if let previousSize {
                defaults.set(previousSize, forKey: sizeKey)
            } else {
                defaults.removeObject(forKey: sizeKey)
            }
            if let previousDesign {
                defaults.set(previousDesign, forKey: designKey)
            } else {
                defaults.removeObject(forKey: designKey)
            }
            if let previousFamily {
                defaults.set(previousFamily, forKey: familyKey)
            } else {
                defaults.removeObject(forKey: familyKey)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: familyKey)
        defaults.set(NativeEditorFontDesign.system.rawValue, forKey: designKey)
        defaults.set(16, forKey: sizeKey)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "Hello world"
        let before = (vc.attributedTextForTesting().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize

        defaults.set(18, forKey: sizeKey)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let after = (vc.attributedTextForTesting().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        guard let before, let after else {
            XCTFail("Missing font attributes for preference rerender check")
            return
        }
        XCTAssertEqual(Double(before), 16, accuracy: 0.5)
        XCTAssertEqual(Double(after), 18, accuracy: 0.5)
    }

    @MainActor
    func testCustomFontFamilyPreferenceChangeRerendersOpenEditorImmediately() {
        let defaults = UserDefaults.standard
        let familyKey = NativeEditorAppearance.fontFamilyKey
        let customFamilyKey = NativeEditorAppearance.customFontFamilyKey
        let sizeKey = NativeEditorAppearance.fontSizeKey
        let previousFamily = defaults.object(forKey: familyKey)
        let previousCustom = defaults.object(forKey: customFamilyKey)
        let previousSize = defaults.object(forKey: sizeKey)
        defer {
            if let previousFamily {
                defaults.set(previousFamily, forKey: familyKey)
            } else {
                defaults.removeObject(forKey: familyKey)
            }
            if let previousCustom {
                defaults.set(previousCustom, forKey: customFamilyKey)
            } else {
                defaults.removeObject(forKey: customFamilyKey)
            }
            if let previousSize {
                defaults.set(previousSize, forKey: sizeKey)
            } else {
                defaults.removeObject(forKey: sizeKey)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(16, forKey: sizeKey)
        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: familyKey)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "font family check"
        let systemFontName = (vc.attributedTextForTesting().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName

        defaults.set(NativeEditorFontFamilyPreset.custom.rawValue, forKey: familyKey)
        defaults.set("Menlo", forKey: customFamilyKey)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let customFontName = (vc.attributedTextForTesting().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName
        XCTAssertNotNil(systemFontName)
        XCTAssertNotNil(customFontName)
        XCTAssertNotEqual(systemFontName, customFontName)
        XCTAssertTrue(customFontName?.localizedCaseInsensitiveContains("Menlo") ?? false)
    }

    @MainActor
    func testCustomThemePreferenceUpdatesInlineLinkColorOnRerender() {
        let defaults = UserDefaults.standard
        let modeKey = NativeEditorAppearance.themeModeKey
        let customThemeKey = NativeEditorAppearance.customThemeJSONKey
        let previousMode = defaults.object(forKey: modeKey)
        let previousCustom = defaults.object(forKey: customThemeKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: modeKey)
            } else {
                defaults.removeObject(forKey: modeKey)
            }
            if let previousCustom {
                defaults.set(previousCustom, forKey: customThemeKey)
            } else {
                defaults.removeObject(forKey: customThemeKey)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorThemeMode.kernDark.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: customThemeKey)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = "[docs](https://example.com/docs)"

        let beforeColor = vc.attributedTextForTesting().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        defaults.set(
            """
            {
              "name": "Test",
              "appearance": "dark",
              "linkColor": "#FF00FF"
            }
            """,
            forKey: customThemeKey
        )
        defaults.set(NativeEditorThemeMode.custom.rawValue, forKey: modeKey)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        let afterColor = vc.attributedTextForTesting().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(beforeColor)
        XCTAssertNotNil(afterColor)
        guard
            let before = beforeColor?.usingColorSpace(.deviceRGB),
            let after = afterColor?.usingColorSpace(.deviceRGB)
        else { return }
        XCTAssertNotEqual(before.redComponent, after.redComponent, accuracy: 0.01)
    }

    @MainActor
    func testTableOverflowPreferenceChangeKeepsDocumentViewportWidthLocked() {
        let defaults = UserDefaults.standard
        let key = NativeEditorAppearance.tableOverflowModeKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorTableOverflowMode.wrap.rawValue, forKey: key)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        | Column 1 | Column 2 | Column 3 | Column 4 | Column 5 | Column 6 |
        | --- | --- | --- | --- | --- | --- |
        | This is a long cell value to force horizontal overflow mode width estimation in the editor viewport. | A | B | C | D | E |
        """
        XCTAssertFalse(vc.isHorizontalTableOverflowActiveForTesting())

        defaults.set(NativeEditorTableOverflowMode.horizontal.rawValue, forKey: key)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        XCTAssertFalse(vc.isHorizontalTableOverflowActiveForTesting())
    }

    private func firstMermaidAttachment(in attr: NSAttributedString) -> MarkdownMermaidAttachment? {
        let full = NSRange(location: 0, length: attr.length)
        var found: MarkdownMermaidAttachment?
        attr.enumerateAttribute(.attachment, in: full, options: []) { value, _, stop in
            if let attachment = value as? MarkdownMermaidAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
    }
}
