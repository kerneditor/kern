import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorAppearanceTests: XCTestCase {
    func testBuiltInThemeCatalogIncludesExpandedPresetPack() {
        let choices = NativeEditorAppearance.builtInThemeChoices
        XCTAssertGreaterThanOrEqual(choices.count, 20, "Expected expanded built-in theme catalog")
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.turbodraftIce.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.wonderLight.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.wonderGraphite.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.tokyoNight.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.vscodeDarkPlus.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.githubDark.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.dracula.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.solarizedLight.rawValue })
        XCTAssertTrue(choices.contains { $0.value == NativeEditorThemeMode.custom.rawValue })
    }

    func testCustomThemeJSONImportValidatesAndAppliesFontDefaults() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: NativeEditorAppearance.themeModeKey)
        let previousJSON = defaults.object(forKey: NativeEditorAppearance.customThemeJSONKey)
        let previousFamily = defaults.object(forKey: NativeEditorAppearance.fontFamilyKey)
        let previousCustomFamily = defaults.object(forKey: NativeEditorAppearance.customFontFamilyKey)
        let previousSize = defaults.object(forKey: NativeEditorAppearance.fontSizeKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: NativeEditorAppearance.themeModeKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.themeModeKey)
            }
            if let previousJSON {
                defaults.set(previousJSON, forKey: NativeEditorAppearance.customThemeJSONKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.customThemeJSONKey)
            }
            if let previousFamily {
                defaults.set(previousFamily, forKey: NativeEditorAppearance.fontFamilyKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.fontFamilyKey)
            }
            if let previousCustomFamily {
                defaults.set(previousCustomFamily, forKey: NativeEditorAppearance.customFontFamilyKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
            }
            if let previousSize {
                defaults.set(previousSize, forKey: NativeEditorAppearance.fontSizeKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.fontSizeKey)
            }
        }

        let themeJSON = """
        {
          "name": "Custom Test",
          "appearance": "dark",
          "linkColor": "#7AA2F7",
          "codeBlockBackground": "#1F2335",
          "codeBlockStroke": "#2C3145",
          "inlineCodeBackground": "#24283B",
          "fontFamily": "Menlo",
          "fontSize": 17
        }
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kern-theme-test-\(UUID().uuidString).json")
        try themeJSON.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try NativeEditorAppearance.importCustomTheme(from: url, defaults: defaults)

        XCTAssertEqual(NativeEditorAppearance.themeMode(defaults: defaults), .custom)
        XCTAssertEqual(
            NativeEditorAppearance.fontFamilyPreset(defaults: defaults),
            .custom
        )
        XCTAssertEqual(NativeEditorAppearance.customFontFamily(defaults: defaults), "Menlo")
        XCTAssertEqual(NativeEditorAppearance.fontSize(defaults: defaults), 17, accuracy: 0.01)
        XCTAssertNotNil(NativeEditorAppearance.importedCustomTheme(defaults: defaults))
    }

    func testCustomThemeJSONImportRejectsInvalidSchema() throws {
        let defaults = UserDefaults.standard
        let raw = """
        {
          "name": "Invalid Theme",
          "appearance": "midnight"
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kern-theme-invalid-\(UUID().uuidString).json")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try NativeEditorAppearance.importCustomTheme(from: url, defaults: defaults),
            "Invalid schema should be rejected"
        )
    }

    func testCustomThemeFallbackPreservesExpandedDynamicPaletteTokens() {
        let suiteName = "NativeEditorAppearanceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let dark = NSAppearance(named: .darkAqua)!
        defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)

        let expectedEditorBackground = NativeEditorAppearance.editorBackgroundColor(defaults: defaults, appearance: dark)
        let expectedSidebarBackground = NativeEditorAppearance.sidebarBackgroundColor(defaults: defaults, appearance: dark)
        let expectedTableHeaderBackground = NativeEditorAppearance.tableHeaderBackgroundColor(defaults: defaults, appearance: dark)
        let expectedInlineCodeText = NativeEditorAppearance.inlineCodeTextColor(defaults: defaults, appearance: dark)

        let themeJSON = """
        {
          "name": "Partial Custom",
          "textColor": "#ABCDEF",
          "linkColor": "#123456",
          "codeBlockBackground": "#24283B",
          "codeBlockStroke": "#2C3145",
          "inlineCodeBackground": "#1F2335"
        }
        """
        defaults.set(themeJSON, forKey: NativeEditorAppearance.customThemeJSONKey)
        defaults.set(NativeEditorThemeMode.custom.rawValue, forKey: NativeEditorAppearance.themeModeKey)

        assertColor(NativeEditorAppearance.primaryTextColor(defaults: defaults), equalsHex: "#ABCDEF")
        assertColor(NativeEditorAppearance.linkColor(defaults: defaults), equalsHex: "#123456")
        assertColor(NativeEditorAppearance.codeBlockBackgroundColor(defaults: defaults, appearance: dark), equalsHex: "#24283B")
        assertColor(NativeEditorAppearance.codeBlockStrokeColor(defaults: defaults, appearance: dark), equalsHex: "#2C3145")
        assertColor(NativeEditorAppearance.inlineCodeBackgroundColor(defaults: defaults, appearance: dark), equalsHex: "#1F2335")

        assertColor(
            NativeEditorAppearance.editorBackgroundColor(defaults: defaults, appearance: dark),
            equals: expectedEditorBackground
        )
        assertColor(
            NativeEditorAppearance.sidebarBackgroundColor(defaults: defaults, appearance: dark),
            equals: expectedSidebarBackground
        )
        assertColor(
            NativeEditorAppearance.tableHeaderBackgroundColor(defaults: defaults, appearance: dark),
            equals: expectedTableHeaderBackground
        )
        assertColor(
            NativeEditorAppearance.inlineCodeTextColor(defaults: defaults, appearance: dark),
            equals: expectedInlineCodeText
        )
    }

    func testBaseFontRespectsPersistedDesignAndSize() {
        let defaults = UserDefaults.standard
        let previousSize = defaults.object(forKey: NativeEditorAppearance.fontSizeKey)
        let previousDesign = defaults.object(forKey: NativeEditorAppearance.fontDesignKey)
        let previousFamily = defaults.object(forKey: NativeEditorAppearance.fontFamilyKey)
        defer {
            if let previousSize {
                defaults.set(previousSize, forKey: NativeEditorAppearance.fontSizeKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.fontSizeKey)
            }
            if let previousDesign {
                defaults.set(previousDesign, forKey: NativeEditorAppearance.fontDesignKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.fontDesignKey)
            }
            if let previousFamily {
                defaults.set(previousFamily, forKey: NativeEditorAppearance.fontFamilyKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.fontFamilyKey)
            }
        }

        defaults.set(18, forKey: NativeEditorAppearance.fontSizeKey)
        defaults.set(NativeEditorFontDesign.monospaced.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)

        let font = NativeEditorAppearance.baseFont(defaults: defaults)
        XCTAssertEqual(font.pointSize, 18, accuracy: 0.01)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testBaseFontUsesFontFamilyPresetAndFallsBackToInstalledFamily() {
        let defaults = UserDefaults.standard
        let previousPreset = defaults.object(forKey: NativeEditorAppearance.fontFamilyKey)
        let previousCustom = defaults.object(forKey: NativeEditorAppearance.customFontFamilyKey)
        defer {
            if let previousPreset {
                defaults.set(previousPreset, forKey: NativeEditorAppearance.fontFamilyKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.fontFamilyKey)
            }
            if let previousCustom {
                defaults.set(previousCustom, forKey: NativeEditorAppearance.customFontFamilyKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
            }
        }

        defaults.set(NativeEditorFontFamilyPreset.custom.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
        defaults.set("Menlo", forKey: NativeEditorAppearance.customFontFamilyKey)
        let custom = NativeEditorAppearance.baseFont(defaults: defaults)
        XCTAssertTrue(custom.fontName.localizedCaseInsensitiveContains("Menlo"))

        defaults.set("DefinitelyNotARealFontFamily", forKey: NativeEditorAppearance.customFontFamilyKey)
        let fallback = NativeEditorAppearance.baseFont(defaults: defaults)
        XCTAssertFalse(fallback.fontName.localizedCaseInsensitiveContains("DefinitelyNotARealFontFamily"))
    }

    @MainActor
    func testThemeApplicationSetsExpectedWindowAppearance() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: NativeEditorAppearance.themeModeKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: NativeEditorAppearance.themeModeKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.themeModeKey)
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 140), styleMask: [.titled], backing: .buffered, defer: false)

        defaults.set(NativeEditorThemeMode.kernDark.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        NativeEditorAppearance.applyTheme(to: window, defaults: defaults)
        XCTAssertEqual(window.appearance?.name, .darkAqua)

        defaults.set(NativeEditorThemeMode.kernLight.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        NativeEditorAppearance.applyTheme(to: window, defaults: defaults)
        XCTAssertEqual(window.appearance?.name, .aqua)

        defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        NativeEditorAppearance.applyTheme(to: window, defaults: defaults)
        XCTAssertNil(window.appearance)
    }

    func testTableOverflowModeDefaultsToWrapAndReadsPersistedValue() {
        let defaults = UserDefaults.standard
        let key = NativeEditorAppearance.tableOverflowModeKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertEqual(NativeEditorAppearance.tableOverflowMode(defaults: defaults), .wrap)

        defaults.set(NativeEditorTableOverflowMode.horizontal.rawValue, forKey: key)
        XCTAssertEqual(NativeEditorAppearance.tableOverflowMode(defaults: defaults), .horizontal)
    }

    func testReadableWidthPreferencesDefaultToFullWidthAndClampMaxWidth() {
        let suiteName = "NativeEditorAppearanceWidthTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(NativeEditorAppearance.readableWidthMode(defaults: defaults), .fullWidth)
        XCTAssertEqual(
            NativeEditorAppearance.readableMaxWidth(defaults: defaults),
            NativeEditorAppearance.defaultReadableMaxWidth,
            accuracy: 0.01
        )

        defaults.set(NativeEditorReadableWidthMode.centered.rawValue, forKey: NativeEditorAppearance.readableWidthModeKey)
        defaults.set(10_000, forKey: NativeEditorAppearance.readableMaxWidthKey)

        XCTAssertEqual(NativeEditorAppearance.readableWidthMode(defaults: defaults), .centered)
        XCTAssertEqual(
            NativeEditorAppearance.readableMaxWidth(defaults: defaults),
            NativeEditorAppearance.readableMaxWidthRange.upperBound,
            accuracy: 0.01
        )
    }

    func testCodeBlockColorsAdaptBetweenLightAndDarkAppearances() {
        let defaults = UserDefaults.standard
        let key = NativeEditorAppearance.themeModeKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(NativeEditorThemeMode.system.rawValue, forKey: key)

        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        let lightBg = NativeEditorAppearance.codeBlockBackgroundColor(appearance: light).usingColorSpace(.deviceRGB)
        let darkBg = NativeEditorAppearance.codeBlockBackgroundColor(appearance: dark).usingColorSpace(.deviceRGB)
        let lightStroke = NativeEditorAppearance.codeBlockStrokeColor(appearance: light).usingColorSpace(.deviceRGB)
        let darkStroke = NativeEditorAppearance.codeBlockStrokeColor(appearance: dark).usingColorSpace(.deviceRGB)

        XCTAssertNotNil(lightBg)
        XCTAssertNotNil(darkBg)
        XCTAssertNotNil(lightStroke)
        XCTAssertNotNil(darkStroke)
        guard let lightBg, let darkBg, let lightStroke, let darkStroke else { return }

        XCTAssertNotEqual(lightBg.alphaComponent, darkBg.alphaComponent, "Background alpha should adapt by appearance")
        XCTAssertNotEqual(lightStroke.alphaComponent, darkStroke.alphaComponent, "Stroke alpha should adapt by appearance")
        let lightLuma = (lightBg.redComponent + lightBg.greenComponent + lightBg.blueComponent) / 3.0
        let darkLuma = (darkBg.redComponent + darkBg.greenComponent + darkBg.blueComponent) / 3.0
        XCTAssertGreaterThan(darkLuma, lightLuma, "Dark mode code blocks should use light ink on dark background")
    }

    func testPresetThemeProvidesStableNonDefaultPalette() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: NativeEditorAppearance.themeModeKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: NativeEditorAppearance.themeModeKey)
            } else {
                defaults.removeObject(forKey: NativeEditorAppearance.themeModeKey)
            }
        }

        defaults.set(NativeEditorThemeMode.dracula.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        let link = NativeEditorAppearance.linkColor(defaults: defaults).usingColorSpace(.deviceRGB)
        let codeBg = NativeEditorAppearance.codeBlockBackgroundColor(defaults: defaults).usingColorSpace(.deviceRGB)

        XCTAssertNotNil(link)
        XCTAssertNotNil(codeBg)
        guard let link, let codeBg else { return }

        XCTAssertGreaterThan(link.blueComponent, link.redComponent)
        XCTAssertGreaterThan(codeBg.redComponent, 0.05)
    }

    func testWonderThemeUsesWonderTokenPaletteForLightAndGraphiteModes() {
        let suiteName = "NativeEditorAppearanceWonderThemeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(NativeEditorThemeMode.wonderLight.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        assertColor(NativeEditorAppearance.primaryTextColor(defaults: defaults), equalsHex: "#0A0D11")
        assertColor(NativeEditorAppearance.codeBlockStrokeColor(defaults: defaults), equalsHex: "#E8E8E5")
        assertColor(NativeEditorAppearance.linkColor(defaults: defaults), equalsHex: "#3B5BE2")

        defaults.set(NativeEditorThemeMode.wonderGraphite.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        assertColor(NativeEditorAppearance.editorBackgroundColor(defaults: defaults), equalsHex: "#090B0F")
        assertColor(NativeEditorAppearance.inlineCodeBackgroundColor(defaults: defaults), equalsHex: "#25282F")
        assertColor(NativeEditorAppearance.linkColor(defaults: defaults), equalsHex: "#A5C2FF")
    }

    func testWonderThemeMigratesRetiredThemePreferenceRawValues() {
        let suiteName = "NativeEditorAppearanceWonderThemeMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let retiredCodename = "A" + "xis"

        defaults.set("kern\(retiredCodename)", forKey: NativeEditorAppearance.themeModeKey)
        XCTAssertEqual(NativeEditorAppearance.themeMode(defaults: defaults), .kernWonder)
        XCTAssertEqual(NativeEditorAppearance.themeDisplayName(defaults: defaults), "Kern Wonder")

        defaults.set("\(retiredCodename.lowercased())Light", forKey: NativeEditorAppearance.themeModeKey)
        XCTAssertEqual(NativeEditorAppearance.themeMode(defaults: defaults), .wonderLight)
        XCTAssertEqual(NativeEditorAppearance.themeDisplayName(defaults: defaults), "Wonder Light")

        defaults.set("\(retiredCodename.lowercased())Graphite", forKey: NativeEditorAppearance.themeModeKey)
        XCTAssertEqual(NativeEditorAppearance.themeMode(defaults: defaults), .wonderGraphite)
        XCTAssertEqual(NativeEditorAppearance.themeDisplayName(defaults: defaults), "Wonder Graphite")
    }
}

private func assertColor(
    _ actual: NSColor,
    equals expected: NSColor,
    accuracy: CGFloat = 0.001,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actualRGB = actual.usingColorSpace(.deviceRGB) else {
        XCTFail("Actual color should convert to device RGB", file: file, line: line)
        return
    }
    guard let expectedRGB = expected.usingColorSpace(.deviceRGB) else {
        XCTFail("Expected color should convert to device RGB", file: file, line: line)
        return
    }

    XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actualRGB.alphaComponent, expectedRGB.alphaComponent, accuracy: accuracy, file: file, line: line)
}

private func assertColor(
    _ actual: NSColor,
    equalsHex hex: String,
    accuracy: CGFloat = 0.001,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let expected = testColorFromHex(hex) else {
        XCTFail("Expected valid hex color", file: file, line: line)
        return
    }
    assertColor(actual, equals: expected, accuracy: accuracy, file: file, line: line)
}

private func testColorFromHex(_ raw: String) -> NSColor? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "#", with: "")
    guard trimmed.count == 6 || trimmed.count == 8,
          let value = UInt64(trimmed, radix: 16) else {
        return nil
    }

    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    if trimmed.count == 8 {
        red = CGFloat((value & 0xFF00_0000) >> 24) / 255.0
        green = CGFloat((value & 0x00FF_0000) >> 16) / 255.0
        blue = CGFloat((value & 0x0000_FF00) >> 8) / 255.0
        alpha = CGFloat(value & 0x0000_00FF) / 255.0
    } else {
        red = CGFloat((value & 0xFF00_00) >> 16) / 255.0
        green = CGFloat((value & 0x00FF_00) >> 8) / 255.0
        blue = CGFloat(value & 0x0000_FF) / 255.0
        alpha = 1.0
    }

    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}
