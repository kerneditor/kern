import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let nativeEditorPreferencesDidChange = Notification.Name("NativeEditorPreferencesDidChange")
}

@MainActor
final class NativeEditorPreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private struct Choice {
        let title: String
        let value: String
    }

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    private var isSyncingControls = false

    private let exportDialectPopup = NSPopUpButton()
    private let gfmExtensionStrategyPopup = NSPopUpButton()
    private let taskRenderingPopup = NSPopUpButton()
    private let orderedNumberingPopup = NSPopUpButton()
    private let syntaxVisibilityPopup = NSPopUpButton()
    private let mermaidRenderModePopup = NSPopUpButton()
    private let officialMermaidRendererCommandField = NSTextField()
    private let officialMermaidPuppeteerConfigField = NSTextField()
    private let officialMermaidUseNPXCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let clearOfficialMermaidCacheButton = NSButton(title: "Clear Cache", target: nil, action: nil)
    private let officialMermaidCacheStatusLabel = NSTextField(labelWithString: "")
    private let checkboxHitTargetPopup = NSPopUpButton()
    private let themeModePopup = NSPopUpButton()
    private let fontFamilyPopup = NSPopUpButton()
    private let fontDesignPopup = NSPopUpButton()
    private let fontSizePopup = NSPopUpButton()
    private let tableOverflowModePopup = NSPopUpButton()
    private let readableWidthModePopup = NSPopUpButton()
    private let customFontFamilyField = NSTextField()
    private let importThemeButton = NSButton(title: "Import JSON…", target: nil, action: nil)
    private let clearCustomThemeButton = NSButton(title: "Clear Custom", target: nil, action: nil)
    private let readableMaxWidthSlider = NSSlider(
        value: Double(NativeEditorAppearance.defaultReadableMaxWidth),
        minValue: Double(NativeEditorAppearance.readableMaxWidthRange.lowerBound),
        maxValue: Double(NativeEditorAppearance.readableMaxWidthRange.upperBound),
        target: nil,
        action: nil
    )
    private let readableMaxWidthValueLabel = NSTextField(labelWithString: "")
    private let brandPreviewView = KernBrandPreviewView()

    private let orderedTasksCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let headingCheckboxesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let remoteImageLoadingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 1135),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        brandPreviewView.defaults = defaults
        setupUI()
        refreshFromDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshFromDefaults() {
        isSyncingControls = true
        defer { isSyncingControls = false }

        selectValue(
            defaults.string(forKey: "nativeEditor.exportDialect") ?? NativeMarkdownCodec.Options.ExportDialect.gfm.rawValue,
            in: exportDialectPopup
        )
        selectValue(
            defaults.string(forKey: "nativeEditor.gfmExtensionExportStrategy")
                ?? NativeMarkdownCodec.Options.GfmExtensionExportStrategy.preserve.rawValue,
            in: gfmExtensionStrategyPopup
        )
        selectValue(
            defaults.string(forKey: "nativeEditor.taskRendering") ?? NativeMarkdownCodec.Options.TaskRendering.gfm.rawValue,
            in: taskRenderingPopup
        )
        selectValue(
            defaults.string(forKey: "nativeEditor.orderedListNumbering")
                ?? NativeMarkdownCodec.Options.OrderedListNumbering.gfmDefault.rawValue,
            in: orderedNumberingPopup
        )
        selectValue(
            defaults.string(forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
                ?? NativeEditorSyntaxVisibilityMode.defaultMode.rawValue,
            in: syntaxVisibilityPopup
        )
        selectValue(
            defaults.string(forKey: "nativeEditor.mermaidRenderMode")
                ?? NativeMarkdownCodec.Options.MermaidRenderMode.rich.rawValue,
            in: mermaidRenderModePopup
        )
        selectValue(
            defaults.string(forKey: "nativeEditor.checkboxHitTarget") ?? "glyph",
            in: checkboxHitTargetPopup
        )
        selectValue(
            NativeEditorAppearance.themeMode(defaults: defaults).rawValue,
            in: themeModePopup
        )
        selectValue(
            defaults.string(forKey: NativeEditorAppearance.fontFamilyKey) ?? NativeEditorFontFamilyPreset.system.rawValue,
            in: fontFamilyPopup
        )
        selectValue(
            defaults.string(forKey: NativeEditorAppearance.fontDesignKey) ?? NativeEditorFontDesign.system.rawValue,
            in: fontDesignPopup
        )
        let fontSizeValue = NativeEditorAppearance.fontSize(defaults: defaults)
        selectValue(
            String(format: "%.0f", fontSizeValue),
            in: fontSizePopup
        )
        selectValue(
            defaults.string(forKey: NativeEditorAppearance.tableOverflowModeKey) ?? NativeEditorTableOverflowMode.wrap.rawValue,
            in: tableOverflowModePopup
        )
        selectValue(
            defaults.string(forKey: NativeEditorAppearance.readableWidthModeKey)
                ?? NativeEditorReadableWidthMode.fullWidth.rawValue,
            in: readableWidthModePopup
        )
        readableMaxWidthSlider.doubleValue = roundedReadableMaxWidthValue(
            Double(NativeEditorAppearance.readableMaxWidth(defaults: defaults))
        )
        updateReadableMaxWidthControls()
        brandPreviewView.needsDisplay = true
        customFontFamilyField.stringValue = defaults.string(forKey: NativeEditorAppearance.customFontFamilyKey) ?? ""
        officialMermaidRendererCommandField.stringValue =
            defaults.string(forKey: MermaidOfficialExternalRenderer.commandUserDefaultsKey) ?? ""
        officialMermaidPuppeteerConfigField.stringValue =
            defaults.string(forKey: MermaidOfficialExternalRenderer.puppeteerConfigFileUserDefaultsKey) ?? ""

        orderedTasksCheckbox.state = boolPreference(
            key: "nativeEditor.orderedTasksEnabled",
            fallback: true
        ) ? .on : .off
        headingCheckboxesCheckbox.state = boolPreference(
            key: "nativeEditor.headingCheckboxesEnabled",
            fallback: true
        ) ? .on : .off
        officialMermaidUseNPXCheckbox.state = boolPreference(
            key: MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey,
            fallback: false
        ) ? .on : .off

        if defaults.object(forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey) != nil {
            remoteImageLoadingCheckbox.state =
                defaults.bool(forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey) ? .on : .off
        } else {
            remoteImageLoadingCheckbox.state = .off
        }
        updateOfficialMermaidCacheStatusLabel()
    }

    @objc private func settingDidChange(_ sender: Any?) {
        guard !isSyncingControls else { return }
        if let slider = sender as? NSSlider, slider === readableMaxWidthSlider {
            readableMaxWidthSlider.doubleValue = roundedReadableMaxWidthValue(slider.doubleValue)
        }
        persistSettings()
        updateReadableMaxWidthControls()
        updateOfficialMermaidCacheStatusLabel()
        brandPreviewView.needsDisplay = true
        postPreferencesDidChange()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        defaults.set(NativeMarkdownCodec.Options.ExportDialect.gfm.rawValue, forKey: "nativeEditor.exportDialect")
        defaults.set(
            NativeMarkdownCodec.Options.GfmExtensionExportStrategy.preserve.rawValue,
            forKey: "nativeEditor.gfmExtensionExportStrategy"
        )
        defaults.set(NativeMarkdownCodec.Options.TaskRendering.gfm.rawValue, forKey: "nativeEditor.taskRendering")
        defaults.set(true, forKey: "nativeEditor.orderedTasksEnabled")
        defaults.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
        defaults.set(
            NativeMarkdownCodec.Options.OrderedListNumbering.gfmDefault.rawValue,
            forKey: "nativeEditor.orderedListNumbering"
        )
        defaults.set(NativeEditorSyntaxVisibilityMode.defaultMode.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        defaults.set(
            NativeMarkdownCodec.Options.MermaidRenderMode.rich.rawValue,
            forKey: "nativeEditor.mermaidRenderMode"
        )
        defaults.removeObject(forKey: MermaidOfficialExternalRenderer.commandUserDefaultsKey)
        defaults.removeObject(forKey: MermaidOfficialExternalRenderer.cacheDirectoryUserDefaultsKey)
        defaults.removeObject(forKey: MermaidOfficialExternalRenderer.puppeteerConfigFileUserDefaultsKey)
        defaults.set(false, forKey: MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey)
        defaults.set("glyph", forKey: "nativeEditor.checkboxHitTarget")
        defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
        defaults.set(NativeEditorFontDesign.system.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
        defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
        defaults.removeObject(forKey: NativeEditorAppearance.customThemeJSONKey)
        defaults.set(16, forKey: NativeEditorAppearance.fontSizeKey)
        defaults.set(NativeEditorTableOverflowMode.wrap.rawValue, forKey: NativeEditorAppearance.tableOverflowModeKey)
        defaults.set(NativeEditorReadableWidthMode.fullWidth.rawValue, forKey: NativeEditorAppearance.readableWidthModeKey)
        defaults.set(NativeEditorAppearance.defaultReadableMaxWidth, forKey: NativeEditorAppearance.readableMaxWidthKey)
        defaults.set(false, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)

        refreshFromDefaults()
        postPreferencesDidChange()
    }

    private func persistSettings() {
        if let value = selectedValue(from: exportDialectPopup) {
            defaults.set(value, forKey: "nativeEditor.exportDialect")
        }
        if let value = selectedValue(from: gfmExtensionStrategyPopup) {
            defaults.set(value, forKey: "nativeEditor.gfmExtensionExportStrategy")
        }
        if let value = selectedValue(from: taskRenderingPopup) {
            defaults.set(value, forKey: "nativeEditor.taskRendering")
        }
        if let value = selectedValue(from: orderedNumberingPopup) {
            defaults.set(value, forKey: "nativeEditor.orderedListNumbering")
        }
        if let value = selectedValue(from: syntaxVisibilityPopup) {
            defaults.set(value, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        }
        if let value = selectedValue(from: mermaidRenderModePopup) {
            defaults.set(value, forKey: "nativeEditor.mermaidRenderMode")
        }
        if let value = selectedValue(from: checkboxHitTargetPopup) {
            defaults.set(value, forKey: "nativeEditor.checkboxHitTarget")
        }
        if let value = selectedValue(from: themeModePopup) {
            defaults.set(value, forKey: NativeEditorAppearance.themeModeKey)
        }
        if let value = selectedValue(from: fontFamilyPopup) {
            defaults.set(value, forKey: NativeEditorAppearance.fontFamilyKey)
        }
        if let value = selectedValue(from: fontDesignPopup) {
            defaults.set(value, forKey: NativeEditorAppearance.fontDesignKey)
        }
        let customFontFamily = customFontFamilyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if customFontFamily.isEmpty {
            defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
        } else {
            defaults.set(customFontFamily, forKey: NativeEditorAppearance.customFontFamilyKey)
        }
        let officialMermaidCommand = officialMermaidRendererCommandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if officialMermaidCommand.isEmpty {
            defaults.removeObject(forKey: MermaidOfficialExternalRenderer.commandUserDefaultsKey)
        } else {
            defaults.set(officialMermaidCommand, forKey: MermaidOfficialExternalRenderer.commandUserDefaultsKey)
        }
        let officialMermaidPuppeteerConfig = officialMermaidPuppeteerConfigField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if officialMermaidPuppeteerConfig.isEmpty {
            defaults.removeObject(forKey: MermaidOfficialExternalRenderer.puppeteerConfigFileUserDefaultsKey)
        } else {
            defaults.set(officialMermaidPuppeteerConfig, forKey: MermaidOfficialExternalRenderer.puppeteerConfigFileUserDefaultsKey)
        }
        if let value = selectedValue(from: fontSizePopup),
           let size = Double(value) {
            defaults.set(size, forKey: NativeEditorAppearance.fontSizeKey)
        }
        if let value = selectedValue(from: tableOverflowModePopup) {
            defaults.set(value, forKey: NativeEditorAppearance.tableOverflowModeKey)
        }
        if let value = selectedValue(from: readableWidthModePopup) {
            defaults.set(value, forKey: NativeEditorAppearance.readableWidthModeKey)
        }
        defaults.set(
            roundedReadableMaxWidthValue(readableMaxWidthSlider.doubleValue),
            forKey: NativeEditorAppearance.readableMaxWidthKey
        )

        defaults.set(orderedTasksCheckbox.state == .on, forKey: "nativeEditor.orderedTasksEnabled")
        defaults.set(headingCheckboxesCheckbox.state == .on, forKey: "nativeEditor.headingCheckboxesEnabled")
        defaults.set(
            officialMermaidUseNPXCheckbox.state == .on,
            forKey: MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey
        )
        defaults.set(remoteImageLoadingCheckbox.state == .on, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)
    }

    private func boolPreference(key: String, fallback: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return fallback
        }
        return defaults.bool(forKey: key)
    }

    private func postPreferencesDidChange() {
        notificationCenter.post(name: .nativeEditorPreferencesDidChange, object: nil)
    }

    private func setupUI() {
        guard let window else { return }

        let exportDialectHelp =
            "Controls saved Markdown format. GFM maximizes compatibility; Kern keeps Kern-specific extension syntax."
        let gfmExtensionStrategyHelp =
            "When Export dialect is GFM, choose how Kern-only syntax is exported: Preserve keeps syntax, Portable softens it, Lint rewrites to stricter patterns."
        let taskRenderingHelp =
            "Editor rendering only. GFM shows checkbox-only tasks; Kern shows bullet plus checkbox for bulleted tasks."
        let orderedNumberingHelp =
            "Controls ordered-list numbering export. GFM default may normalize numbering; Preserve typed keeps your exact numbers."
        let syntaxVisibilityHelp =
            "WYSIWYG hides Markdown markers. Hybrid expands inline markdown syntax near the caret for precise edits. Markdown syntax shows full raw source."
        let mermaidRenderModeHelp =
            "Mermaid render mode: Rich draws native diagrams, ASCII is a lightweight text diagram, Auto switches by complexity, Official External uses cached mmdc output when available and otherwise falls back to native rich."
        let officialMermaidRendererCommandHelp =
            "Optional command for the official Mermaid CLI renderer. Examples: mmdc, /path/to/mmdc, or npx -y @mermaid-js/mermaid-cli@11.15.0. Leave blank to disable unless npx is allowed."
        let officialMermaidPuppeteerConfigHelp =
            "Optional Puppeteer config JSON passed to Mermaid CLI with -p. Use this for advanced browser executable or sandbox configuration."
        let officialMermaidUseNPXHelp =
            "Allow Kern to use npx for the official external renderer when no explicit command is set. This is opt-in because it can download/run Node tooling."
        let officialMermaidCacheHelp =
            "Cached official Mermaid PNG output. Clear Cache removes rendered Mermaid images and forces the next official render to regenerate."
        let checkboxHitTargetHelp =
            "Click behavior for toggling tasks. Glyph-only toggles only on the checkbox; marker-region toggles from anywhere in the list marker area."
        let themeModeHelp =
            "Visual theme for editor windows. Includes built-in presets and a Custom mode loaded from JSON."
        let importThemeHelp =
            "Import a custom theme JSON (colors, optional appearance override, optional font defaults)."
        let fontFamilyHelp =
            "Select a popular font family preset. Use Custom to type any installed font family name."
        let customFontFamilyHelp =
            "Typed custom font family name (used when Font family is set to Custom)."
        let fontDesignHelp =
            "Editor font design. System is default; rounded/serif/monospaced optimize readability or code-heavy browsing."
        let fontSizeHelp =
            "Base editor font size used for body text and proportional heading scaling."
        let tableOverflowModeHelp =
            "Wide markdown tables: Wrap keeps columns within the main viewport. Horizontal reserves table-local overflow behavior without enabling document-wide side scrolling."
        let readableWidthModeHelp =
            "Controls the editor text column. Full width uses the available window; Centered readable caps the column like Notion."
        let readableMaxWidthHelp =
            "Maximum document column width when Centered readable is selected."
        let orderedTasksHelp =
            "If enabled, lines like \"1. [ ] task\" are parsed as ordered tasks. If disabled, that syntax remains literal text."
        let headingCheckboxesHelp =
            "If enabled, headings like \"## [ ] heading\" are parsed as heading tasks. If disabled, the checkbox syntax stays literal."
        let remoteImageLoadingHelp =
            "If enabled, HTTP/HTTPS images load in the editor. Local file images always load. Disable for privacy/offline workflows."

        configurePopup(
            exportDialectPopup,
            choices: [
                Choice(title: "GFM (default)", value: NativeMarkdownCodec.Options.ExportDialect.gfm.rawValue),
                Choice(title: "Kern extensions", value: NativeMarkdownCodec.Options.ExportDialect.kern.rawValue),
            ]
        )
        configurePopup(
            gfmExtensionStrategyPopup,
            choices: [
                Choice(title: "Preserve", value: NativeMarkdownCodec.Options.GfmExtensionExportStrategy.preserve.rawValue),
                Choice(title: "Portable", value: NativeMarkdownCodec.Options.GfmExtensionExportStrategy.portable.rawValue),
                Choice(title: "Lint", value: NativeMarkdownCodec.Options.GfmExtensionExportStrategy.lint.rawValue),
            ]
        )
        configurePopup(
            taskRenderingPopup,
            choices: [
                Choice(title: "GFM (checkbox only)", value: NativeMarkdownCodec.Options.TaskRendering.gfm.rawValue),
                Choice(title: "Kern (bullet + checkbox)", value: NativeMarkdownCodec.Options.TaskRendering.kern.rawValue),
            ]
        )
        configurePopup(
            orderedNumberingPopup,
            choices: [
                Choice(title: "GFM default (normalize)", value: NativeMarkdownCodec.Options.OrderedListNumbering.gfmDefault.rawValue),
                Choice(title: "Preserve typed", value: NativeMarkdownCodec.Options.OrderedListNumbering.preserveTyped.rawValue),
            ]
        )
        configurePopup(
            syntaxVisibilityPopup,
            choices: [
                Choice(title: "WYSIWYG", value: NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue),
                Choice(title: "Hybrid (near caret)", value: NativeEditorSyntaxVisibilityMode.hybrid.rawValue),
                Choice(title: "Markdown syntax", value: NativeEditorSyntaxVisibilityMode.markdown.rawValue),
            ]
        )
        configurePopup(
            mermaidRenderModePopup,
            choices: [
                Choice(title: "Rich (native diagram)", value: NativeMarkdownCodec.Options.MermaidRenderMode.rich.rawValue),
                Choice(title: "ASCII (lightweight)", value: NativeMarkdownCodec.Options.MermaidRenderMode.ascii.rawValue),
                Choice(title: "Auto (complexity-based)", value: NativeMarkdownCodec.Options.MermaidRenderMode.auto.rawValue),
                Choice(title: "Official External (cached)", value: NativeMarkdownCodec.Options.MermaidRenderMode.officialExternal.rawValue),
            ]
        )
        configurePopup(
            checkboxHitTargetPopup,
            choices: [
                Choice(title: "Checkbox glyph only", value: "glyph"),
                Choice(title: "Whole marker region", value: "marker"),
            ]
        )
        configurePopup(
            themeModePopup,
            choices: NativeEditorAppearance.builtInThemeChoices.map { Choice(title: $0.title, value: $0.value) }
        )
        configurePopup(
            fontFamilyPopup,
            choices: NativeEditorAppearance.fontFamilyChoices.map { Choice(title: $0.title, value: $0.value) }
        )
        configurePopup(
            fontDesignPopup,
            choices: [
                Choice(title: "System", value: NativeEditorFontDesign.system.rawValue),
                Choice(title: "Rounded", value: NativeEditorFontDesign.rounded.rawValue),
                Choice(title: "Serif", value: NativeEditorFontDesign.serif.rawValue),
                Choice(title: "Monospaced", value: NativeEditorFontDesign.monospaced.rawValue),
            ]
        )
        configurePopup(
            fontSizePopup,
            choices: [
                Choice(title: "14", value: "14"),
                Choice(title: "15", value: "15"),
                Choice(title: "16", value: "16"),
                Choice(title: "17", value: "17"),
                Choice(title: "18", value: "18"),
                Choice(title: "20", value: "20"),
            ]
        )
        configurePopup(
            tableOverflowModePopup,
            choices: [
                Choice(title: "Wrap in viewport", value: NativeEditorTableOverflowMode.wrap.rawValue),
                Choice(title: "Horizontal scroll", value: NativeEditorTableOverflowMode.horizontal.rawValue),
            ]
        )
        configurePopup(
            readableWidthModePopup,
            choices: [
                Choice(title: "Full width (default)", value: NativeEditorReadableWidthMode.fullWidth.rawValue),
                Choice(title: "Centered readable", value: NativeEditorReadableWidthMode.centered.rawValue),
            ]
        )

        orderedTasksCheckbox.title = ""
        headingCheckboxesCheckbox.title = ""
        officialMermaidUseNPXCheckbox.title = ""
        remoteImageLoadingCheckbox.title = ""

        exportDialectPopup.toolTip = exportDialectHelp
        gfmExtensionStrategyPopup.toolTip = gfmExtensionStrategyHelp
        taskRenderingPopup.toolTip = taskRenderingHelp
        orderedNumberingPopup.toolTip = orderedNumberingHelp
        syntaxVisibilityPopup.toolTip = syntaxVisibilityHelp
        mermaidRenderModePopup.toolTip = mermaidRenderModeHelp
        officialMermaidRendererCommandField.toolTip = officialMermaidRendererCommandHelp
        officialMermaidPuppeteerConfigField.toolTip = officialMermaidPuppeteerConfigHelp
        officialMermaidUseNPXCheckbox.toolTip = officialMermaidUseNPXHelp
        clearOfficialMermaidCacheButton.toolTip = officialMermaidCacheHelp
        officialMermaidCacheStatusLabel.toolTip = officialMermaidCacheHelp
        checkboxHitTargetPopup.toolTip = checkboxHitTargetHelp
        themeModePopup.toolTip = themeModeHelp
        fontFamilyPopup.toolTip = fontFamilyHelp
        fontDesignPopup.toolTip = fontDesignHelp
        fontSizePopup.toolTip = fontSizeHelp
        tableOverflowModePopup.toolTip = tableOverflowModeHelp
        readableWidthModePopup.toolTip = readableWidthModeHelp
        readableMaxWidthSlider.toolTip = readableMaxWidthHelp
        readableMaxWidthValueLabel.toolTip = readableMaxWidthHelp
        orderedTasksCheckbox.toolTip = orderedTasksHelp
        headingCheckboxesCheckbox.toolTip = headingCheckboxesHelp
        remoteImageLoadingCheckbox.toolTip = remoteImageLoadingHelp

        readableWidthModePopup.setAccessibilityIdentifier("NativeEditor.Settings.ReadableWidthMode")
        readableMaxWidthSlider.target = self
        readableMaxWidthSlider.action = #selector(settingDidChange(_:))
        readableMaxWidthSlider.isContinuous = false
        readableMaxWidthSlider.numberOfTickMarks = 0
        readableMaxWidthSlider.allowsTickMarkValuesOnly = false
        readableMaxWidthSlider.setAccessibilityIdentifier("NativeEditor.Settings.ReadableMaxWidth")
        readableMaxWidthValueLabel.alignment = .right
        readableMaxWidthValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        readableMaxWidthValueLabel.textColor = .secondaryLabelColor
        readableMaxWidthValueLabel.setAccessibilityIdentifier("NativeEditor.Settings.ReadableMaxWidthValue")

        customFontFamilyField.placeholderString = "Custom font family (e.g. IBM Plex Sans)"
        customFontFamilyField.toolTip = customFontFamilyHelp
        customFontFamilyField.target = self
        customFontFamilyField.action = #selector(settingDidChange(_:))
        customFontFamilyField.delegate = self
        customFontFamilyField.setAccessibilityIdentifier("NativeEditor.Settings.CustomFontFamily")

        officialMermaidRendererCommandField.placeholderString = "Optional Mermaid CLI command"
        officialMermaidRendererCommandField.target = self
        officialMermaidRendererCommandField.action = #selector(settingDidChange(_:))
        officialMermaidRendererCommandField.delegate = self
        officialMermaidRendererCommandField.setAccessibilityIdentifier("NativeEditor.Settings.OfficialMermaidRendererCommand")

        officialMermaidPuppeteerConfigField.placeholderString = "Optional Puppeteer config JSON path"
        officialMermaidPuppeteerConfigField.target = self
        officialMermaidPuppeteerConfigField.action = #selector(settingDidChange(_:))
        officialMermaidPuppeteerConfigField.delegate = self
        officialMermaidPuppeteerConfigField.setAccessibilityIdentifier("NativeEditor.Settings.OfficialMermaidPuppeteerConfig")

        officialMermaidUseNPXCheckbox.target = self
        officialMermaidUseNPXCheckbox.action = #selector(settingDidChange(_:))
        officialMermaidUseNPXCheckbox.setAccessibilityIdentifier("NativeEditor.Settings.OfficialMermaidUseNPX")

        clearOfficialMermaidCacheButton.target = self
        clearOfficialMermaidCacheButton.action = #selector(clearOfficialMermaidCache(_:))
        clearOfficialMermaidCacheButton.setAccessibilityIdentifier("NativeEditor.Settings.ClearOfficialMermaidCache")

        officialMermaidCacheStatusLabel.textColor = .secondaryLabelColor
        officialMermaidCacheStatusLabel.font = NSFont.systemFont(ofSize: 11)
        officialMermaidCacheStatusLabel.lineBreakMode = .byTruncatingMiddle
        officialMermaidCacheStatusLabel.setAccessibilityIdentifier("NativeEditor.Settings.OfficialMermaidCacheStatus")

        importThemeButton.target = self
        importThemeButton.action = #selector(importCustomThemeJSON(_:))
        importThemeButton.toolTip = importThemeHelp
        importThemeButton.setAccessibilityIdentifier("NativeEditor.Settings.ImportCustomTheme")

        clearCustomThemeButton.target = self
        clearCustomThemeButton.action = #selector(clearCustomThemeJSON(_:))
        clearCustomThemeButton.toolTip = "Remove loaded custom theme JSON and return to built-in presets."
        clearCustomThemeButton.setAccessibilityIdentifier("NativeEditor.Settings.ClearCustomTheme")

        let themeButtonsStack = NSStackView(views: [importThemeButton, clearCustomThemeButton])
        themeButtonsStack.orientation = .horizontal
        themeButtonsStack.spacing = 8
        themeButtonsStack.alignment = .firstBaseline

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        brandPreviewView.translatesAutoresizingMaskIntoConstraints = false

        let exportDialectLabel = makeRowLabel("Export dialect", tooltip: exportDialectHelp)
        let gfmExtensionStrategyLabel = makeRowLabel("GFM extension strategy", tooltip: gfmExtensionStrategyHelp)
        let taskRenderingLabel = makeRowLabel("Task rendering", tooltip: taskRenderingHelp)
        let orderedNumberingLabel = makeRowLabel("Ordered list numbering", tooltip: orderedNumberingHelp)
        let syntaxVisibilityLabel = makeRowLabel("Syntax visibility", tooltip: syntaxVisibilityHelp)
        let mermaidRenderModeLabel = makeRowLabel("Mermaid render mode", tooltip: mermaidRenderModeHelp)
        let officialMermaidRendererCommandLabel = makeRowLabel("Official Mermaid command", tooltip: officialMermaidRendererCommandHelp)
        let officialMermaidPuppeteerConfigLabel = makeRowLabel("Puppeteer config", tooltip: officialMermaidPuppeteerConfigHelp)
        let officialMermaidUseNPXLabel = makeRowLabel("Allow npx renderer", tooltip: officialMermaidUseNPXHelp)
        let officialMermaidCacheLabel = makeRowLabel("Official Mermaid cache", tooltip: officialMermaidCacheHelp)
        let checkboxHitTargetLabel = makeRowLabel("Checkbox hit target", tooltip: checkboxHitTargetHelp)
        let themeModeLabel = makeRowLabel("Theme", tooltip: themeModeHelp)
        let importThemeLabel = makeRowLabel("Theme import", tooltip: importThemeHelp)
        let fontFamilyLabel = makeRowLabel("Font family", tooltip: fontFamilyHelp)
        let customFontFamilyLabel = makeRowLabel("Custom font family", tooltip: customFontFamilyHelp)
        let fontDesignLabel = makeRowLabel("Font design", tooltip: fontDesignHelp)
        let fontSizeLabel = makeRowLabel("Font size", tooltip: fontSizeHelp)
        let tableOverflowModeLabel = makeRowLabel("Table overflow", tooltip: tableOverflowModeHelp)
        let readableWidthModeLabel = makeRowLabel("Editor width", tooltip: readableWidthModeHelp)
        let readableMaxWidthLabel = makeRowLabel("Max readable width", tooltip: readableMaxWidthHelp)
        let orderedTasksLabel = makeRowLabel("Enable ordered tasks", tooltip: orderedTasksHelp)
        let headingCheckboxesLabel = makeRowLabel("Enable heading checkboxes", tooltip: headingCheckboxesHelp)
        let remoteImageLoadingLabel = makeRowLabel("Enable remote image loading", tooltip: remoteImageLoadingHelp)

        let readableWidthControls = NSStackView(views: [readableMaxWidthSlider, readableMaxWidthValueLabel])
        readableWidthControls.orientation = .horizontal
        readableWidthControls.spacing = 8
        readableWidthControls.alignment = .centerY

        let officialMermaidCacheControls = NSStackView(views: [clearOfficialMermaidCacheButton, officialMermaidCacheStatusLabel])
        officialMermaidCacheControls.orientation = .horizontal
        officialMermaidCacheControls.spacing = 8
        officialMermaidCacheControls.alignment = .firstBaseline

        let grid = NSGridView(views: [
            [exportDialectLabel, exportDialectPopup],
            [gfmExtensionStrategyLabel, gfmExtensionStrategyPopup],
            [taskRenderingLabel, taskRenderingPopup],
            [orderedNumberingLabel, orderedNumberingPopup],
            [syntaxVisibilityLabel, syntaxVisibilityPopup],
            [mermaidRenderModeLabel, mermaidRenderModePopup],
            [officialMermaidRendererCommandLabel, officialMermaidRendererCommandField],
            [officialMermaidPuppeteerConfigLabel, officialMermaidPuppeteerConfigField],
            [officialMermaidUseNPXLabel, officialMermaidUseNPXCheckbox],
            [officialMermaidCacheLabel, officialMermaidCacheControls],
            [checkboxHitTargetLabel, checkboxHitTargetPopup],
            [themeModeLabel, themeModePopup],
            [importThemeLabel, themeButtonsStack],
            [fontFamilyLabel, fontFamilyPopup],
            [customFontFamilyLabel, customFontFamilyField],
            [fontDesignLabel, fontDesignPopup],
            [fontSizeLabel, fontSizePopup],
            [tableOverflowModeLabel, tableOverflowModePopup],
            [readableWidthModeLabel, readableWidthModePopup],
            [readableMaxWidthLabel, readableWidthControls],
            [orderedTasksLabel, orderedTasksCheckbox],
            [headingCheckboxesLabel, headingCheckboxesCheckbox],
            [remoteImageLoadingLabel, remoteImageLoadingCheckbox],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 14
        grid.rowSpacing = 10
        grid.yPlacement = .center
        grid.xPlacement = .leading

        let noteLabel = NSTextField(labelWithString: "Changes apply immediately to open editors.")
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 12)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        restoreButton.setAccessibilityIdentifier("NativeEditor.Settings.RestoreDefaults")
        restoreButton.toolTip = "Resets native editor settings to the default profile."
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(brandPreviewView)
        content.addSubview(grid)
        content.addSubview(noteLabel)
        content.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            brandPreviewView.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            brandPreviewView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            brandPreviewView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            brandPreviewView.heightAnchor.constraint(equalToConstant: 150),

            grid.topAnchor.constraint(equalTo: brandPreviewView.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),

            noteLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            noteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            restoreButton.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 10),
            restoreButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            restoreButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])

        window.contentView = root

        // Apply minimum control widths for a stable layout.
        [exportDialectPopup, gfmExtensionStrategyPopup, taskRenderingPopup, orderedNumberingPopup, syntaxVisibilityPopup, mermaidRenderModePopup, checkboxHitTargetPopup, themeModePopup, fontFamilyPopup, fontDesignPopup, fontSizePopup, tableOverflowModePopup, readableWidthModePopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        }
        customFontFamilyField.translatesAutoresizingMaskIntoConstraints = false
        customFontFamilyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        officialMermaidRendererCommandField.translatesAutoresizingMaskIntoConstraints = false
        officialMermaidRendererCommandField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        officialMermaidPuppeteerConfigField.translatesAutoresizingMaskIntoConstraints = false
        officialMermaidPuppeteerConfigField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        officialMermaidCacheStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        officialMermaidCacheStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        readableMaxWidthSlider.translatesAutoresizingMaskIntoConstraints = false
        readableMaxWidthSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        readableMaxWidthValueLabel.translatesAutoresizingMaskIntoConstraints = false
        readableMaxWidthValueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }

    private func roundedReadableMaxWidthValue(_ raw: Double) -> Double {
        let lower = Double(NativeEditorAppearance.readableMaxWidthRange.lowerBound)
        let upper = Double(NativeEditorAppearance.readableMaxWidthRange.upperBound)
        let clamped = min(upper, max(lower, raw))
        return (clamped / 20).rounded() * 20
    }

    private func updateReadableMaxWidthControls() {
        let centered = selectedValue(from: readableWidthModePopup) == NativeEditorReadableWidthMode.centered.rawValue
        readableMaxWidthSlider.isEnabled = centered
        readableMaxWidthValueLabel.textColor = centered ? .labelColor : .disabledControlTextColor
        readableMaxWidthValueLabel.stringValue = String(
            format: "%.0f px",
            roundedReadableMaxWidthValue(readableMaxWidthSlider.doubleValue)
        )
    }

    private func updateOfficialMermaidCacheStatusLabel(_ statusPrefix: String? = nil) {
        let cacheURL = MermaidOfficialExternalRenderer.configuredCacheDirectoryForDisplay(defaults: defaults)
        if let statusPrefix {
            officialMermaidCacheStatusLabel.stringValue = "\(statusPrefix): \(cacheURL.path)"
        } else {
            officialMermaidCacheStatusLabel.stringValue = cacheURL.path
        }
    }

    private func configurePopup(_ popup: NSPopUpButton, choices: [Choice]) {
        popup.removeAllItems()
        for choice in choices {
            popup.addItem(withTitle: choice.title)
            popup.lastItem?.representedObject = choice.value
        }
        popup.target = self
        popup.action = #selector(settingDidChange(_:))
        popup.setAccessibilityIdentifier("NativeEditor.Settings.\(choices.first?.value ?? "Popup")")
    }

    private func selectValue(_ value: String, in popup: NSPopUpButton) {
        guard let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) else {
            popup.selectItem(at: 0)
            return
        }
        popup.select(item)
    }

    private func selectedValue(from popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    private func makeRowLabel(_ text: String, tooltip: String? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .left
        label.toolTip = tooltip
        return label
    }

    @objc
    private func importCustomThemeJSON(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.title = "Import Custom Theme JSON"
        panel.prompt = "Import Theme"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NativeEditorAppearance.importCustomTheme(from: url, defaults: defaults)
            refreshFromDefaults()
            postPreferencesDidChange()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to import theme"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc
    private func clearCustomThemeJSON(_ sender: Any?) {
        defaults.removeObject(forKey: NativeEditorAppearance.customThemeJSONKey)
        if (defaults.string(forKey: NativeEditorAppearance.themeModeKey) ?? "") == NativeEditorThemeMode.custom.rawValue {
            defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        }
        refreshFromDefaults()
        postPreferencesDidChange()
    }

    @objc
    private func clearOfficialMermaidCache(_ sender: Any?) {
        do {
            try MermaidOfficialExternalRenderer.clearCache(defaults: defaults)
            updateOfficialMermaidCacheStatusLabel("Cleared")
            postPreferencesDidChange()
        } catch {
            officialMermaidCacheStatusLabel.stringValue = "Clear failed: \(error.localizedDescription)"
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isSyncingControls else { return }
        settingDidChange(obj.object)
    }
}

private final class KernBrandPreviewView: NSView {
    var defaults: UserDefaults = .standard {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let appearance = effectiveAppearance
        let background = NativeEditorAppearance.sidebarBackgroundColor(defaults: defaults, appearance: appearance)
        let text = NativeEditorAppearance.primaryTextColor(defaults: defaults)
        let secondary = NativeEditorAppearance.secondaryTextColor(defaults: defaults)
        let accent = NativeEditorAppearance.linkColor(defaults: defaults)
        let editorBackground = NativeEditorAppearance.editorBackgroundColor(defaults: defaults, appearance: appearance)
        let codeBackground = NativeEditorAppearance.codeBlockBackgroundColor(defaults: defaults, appearance: appearance)
        let inlineBackground = NativeEditorAppearance.inlineCodeBackgroundColor(defaults: defaults, appearance: appearance)
        let border = NativeEditorAppearance.codeBlockStrokeColor(defaults: defaults, appearance: appearance)
        let inlineText = NativeEditorAppearance.inlineCodeTextColor(defaults: defaults, appearance: appearance)

        drawRoundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), radius: 14, fill: background, stroke: border, lineWidth: 1)

        let markTile = NSRect(x: 18, y: 20, width: 108, height: 108)
        drawRoundedRect(markTile, radius: 22, fill: editorBackground, stroke: border, lineWidth: 1)
        drawKernAppIcon(in: markTile.insetBy(dx: 8, dy: 8), text: text)

        drawText(
            NativeEditorAppearance.themeDisplayName(defaults: defaults),
            in: NSRect(x: 148, y: 24, width: bounds.width - 356, height: 28),
            font: .systemFont(ofSize: 18, weight: .semibold),
            color: text
        )
        drawText(
            NativeEditorAppearance.themeDesignNote(defaults: defaults),
            in: NSRect(x: 148, y: 54, width: bounds.width - 176, height: 40),
            font: .systemFont(ofSize: 12, weight: .regular),
            color: secondary
        )

        drawComponentPreview(
            origin: NSPoint(x: 148, y: 104),
            inlineBackground: inlineBackground,
            inlineText: inlineText,
            codeBackground: codeBackground,
            border: border,
            accent: accent,
            text: text,
            secondary: secondary
        )

        drawSwatches(
            origin: NSPoint(x: bounds.width - 188, y: 25),
            colors: [text, secondary, accent, inlineBackground, codeBackground]
        )
    }

    private func drawComponentPreview(
        origin: NSPoint,
        inlineBackground: NSColor,
        inlineText: NSColor,
        codeBackground: NSColor,
        border: NSColor,
        accent: NSColor,
        text: NSColor,
        secondary: NSColor
    ) {
        let checkbox = NSRect(x: origin.x, y: origin.y + 1, width: 18, height: 18)
        drawRoundedRect(checkbox, radius: 4, fill: accent, stroke: accent, lineWidth: 1)

        let check = NSBezierPath()
        check.lineWidth = 2
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: checkbox.minX + 4, y: checkbox.midY))
        check.line(to: NSPoint(x: checkbox.minX + 8, y: checkbox.maxY - 5))
        check.line(to: NSPoint(x: checkbox.maxX - 4, y: checkbox.minY + 5))
        NSColor.white.setStroke()
        check.stroke()

        drawText(
            "Kern logo + native TextKit",
            in: NSRect(x: origin.x + 28, y: origin.y - 1, width: 170, height: 22),
            font: .systemFont(ofSize: 12, weight: .medium),
            color: text
        )

        let inline = NSRect(x: origin.x + 205, y: origin.y - 2, width: 108, height: 24)
        drawRoundedRect(inline, radius: 6, fill: inlineBackground, stroke: nil, lineWidth: 0)
        drawText(
            "inline code",
            in: inline.insetBy(dx: 9, dy: 4),
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: inlineText
        )

        let code = NSRect(x: origin.x + 326, y: origin.y - 2, width: 170, height: 24)
        drawRoundedRect(code, radius: 6, fill: codeBackground, stroke: border, lineWidth: 1)
        drawText(
            "precise spacing",
            in: code.insetBy(dx: 10, dy: 4),
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: secondary
        )
    }

    private func drawKernAppIcon(in rect: NSRect, text: NSColor) {
        if let icon = NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon") {
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }

        // Fallback mirrors the bundled macOS icon so the preview remains stable in
        // unit-hosted render contexts that do not load the asset catalog.
        let iconPath = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.19, green: 0.58, blue: 1.00, alpha: 1.0),
            NSColor(calibratedRed: 0.04, green: 0.24, blue: 0.70, alpha: 1.0),
        ])
        gradient?.draw(in: iconPath, angle: 315)

        let inset = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.20)
        let stroke = max(7, rect.width * 0.12)
        let stemX = inset.minX + inset.width * 0.08
        let joinX = inset.minX + inset.width * 0.48
        let outX = inset.maxX
        let topY = inset.minY
        let bottomY = inset.maxY

        let mark = NSBezierPath()
        mark.lineWidth = stroke
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: stemX, y: topY))
        mark.line(to: NSPoint(x: stemX, y: bottomY))
        mark.move(to: NSPoint(x: joinX, y: rect.midY))
        mark.line(to: NSPoint(x: outX, y: topY))
        mark.move(to: NSPoint(x: joinX, y: rect.midY))
        mark.line(to: NSPoint(x: outX, y: bottomY))
        NSColor.white.withAlphaComponent(0.96).setStroke()
        mark.stroke()

        let highlight = NSBezierPath()
        highlight.lineWidth = max(2, stroke * 0.20)
        highlight.lineCapStyle = .round
        highlight.move(to: NSPoint(x: stemX, y: topY + stroke * 0.20))
        highlight.line(to: NSPoint(x: stemX, y: rect.midY - stroke * 0.85))
        text.withAlphaComponent(0.12).setStroke()
        highlight.stroke()
    }

    private func drawSwatches(origin: NSPoint, colors: [NSColor]) {
        for (index, color) in colors.enumerated() {
            let rect = NSRect(x: origin.x + CGFloat(index * 30), y: origin.y, width: 22, height: 22)
            drawRoundedRect(rect, radius: 6, fill: color, stroke: color.withAlphaComponent(0.35), lineWidth: 1)
        }
    }

    private func drawText(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawRoundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor?, lineWidth: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke, lineWidth > 0 {
            path.lineWidth = lineWidth
            stroke.setStroke()
            path.stroke()
        }
    }
}
