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
    private let checkboxHitTargetPopup = NSPopUpButton()
    private let themeModePopup = NSPopUpButton()
    private let fontFamilyPopup = NSPopUpButton()
    private let fontDesignPopup = NSPopUpButton()
    private let fontSizePopup = NSPopUpButton()
    private let tableOverflowModePopup = NSPopUpButton()
    private let customFontFamilyField = NSTextField()
    private let importThemeButton = NSButton(title: "Import JSON…", target: nil, action: nil)
    private let clearCustomThemeButton = NSButton(title: "Clear Custom", target: nil, action: nil)

    private let orderedTasksCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let headingCheckboxesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let remoteImageLoadingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
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
            defaults.string(forKey: NativeEditorAppearance.themeModeKey) ?? NativeEditorThemeMode.system.rawValue,
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
        customFontFamilyField.stringValue = defaults.string(forKey: NativeEditorAppearance.customFontFamilyKey) ?? ""

        orderedTasksCheckbox.state = boolPreference(
            key: "nativeEditor.orderedTasksEnabled",
            fallback: true
        ) ? .on : .off
        headingCheckboxesCheckbox.state = boolPreference(
            key: "nativeEditor.headingCheckboxesEnabled",
            fallback: true
        ) ? .on : .off

        if defaults.object(forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey) != nil {
            remoteImageLoadingCheckbox.state =
                defaults.bool(forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey) ? .on : .off
        } else {
            remoteImageLoadingCheckbox.state = .on
        }
    }

    @objc private func settingDidChange(_ sender: Any?) {
        guard !isSyncingControls else { return }
        persistSettings()
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
        defaults.set("glyph", forKey: "nativeEditor.checkboxHitTarget")
        defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
        defaults.set(NativeEditorFontDesign.system.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
        defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
        defaults.removeObject(forKey: NativeEditorAppearance.customThemeJSONKey)
        defaults.set(16, forKey: NativeEditorAppearance.fontSizeKey)
        defaults.set(NativeEditorTableOverflowMode.wrap.rawValue, forKey: NativeEditorAppearance.tableOverflowModeKey)
        defaults.set(true, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)

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
        if let value = selectedValue(from: fontSizePopup),
           let size = Double(value) {
            defaults.set(size, forKey: NativeEditorAppearance.fontSizeKey)
        }
        if let value = selectedValue(from: tableOverflowModePopup) {
            defaults.set(value, forKey: NativeEditorAppearance.tableOverflowModeKey)
        }

        defaults.set(orderedTasksCheckbox.state == .on, forKey: "nativeEditor.orderedTasksEnabled")
        defaults.set(headingCheckboxesCheckbox.state == .on, forKey: "nativeEditor.headingCheckboxesEnabled")
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
            "Mermaid render mode: Rich draws full native diagrams, ASCII is a lightweight text diagram, Auto switches by complexity."
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

        orderedTasksCheckbox.title = ""
        headingCheckboxesCheckbox.title = ""
        remoteImageLoadingCheckbox.title = ""

        exportDialectPopup.toolTip = exportDialectHelp
        gfmExtensionStrategyPopup.toolTip = gfmExtensionStrategyHelp
        taskRenderingPopup.toolTip = taskRenderingHelp
        orderedNumberingPopup.toolTip = orderedNumberingHelp
        syntaxVisibilityPopup.toolTip = syntaxVisibilityHelp
        mermaidRenderModePopup.toolTip = mermaidRenderModeHelp
        checkboxHitTargetPopup.toolTip = checkboxHitTargetHelp
        themeModePopup.toolTip = themeModeHelp
        fontFamilyPopup.toolTip = fontFamilyHelp
        fontDesignPopup.toolTip = fontDesignHelp
        fontSizePopup.toolTip = fontSizeHelp
        tableOverflowModePopup.toolTip = tableOverflowModeHelp
        orderedTasksCheckbox.toolTip = orderedTasksHelp
        headingCheckboxesCheckbox.toolTip = headingCheckboxesHelp
        remoteImageLoadingCheckbox.toolTip = remoteImageLoadingHelp

        customFontFamilyField.placeholderString = "Custom font family (e.g. IBM Plex Sans)"
        customFontFamilyField.toolTip = customFontFamilyHelp
        customFontFamilyField.target = self
        customFontFamilyField.action = #selector(settingDidChange(_:))
        customFontFamilyField.delegate = self
        customFontFamilyField.setAccessibilityIdentifier("NativeEditor.Settings.CustomFontFamily")

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

        let exportDialectLabel = makeRowLabel("Export dialect", tooltip: exportDialectHelp)
        let gfmExtensionStrategyLabel = makeRowLabel("GFM extension strategy", tooltip: gfmExtensionStrategyHelp)
        let taskRenderingLabel = makeRowLabel("Task rendering", tooltip: taskRenderingHelp)
        let orderedNumberingLabel = makeRowLabel("Ordered list numbering", tooltip: orderedNumberingHelp)
        let syntaxVisibilityLabel = makeRowLabel("Syntax visibility", tooltip: syntaxVisibilityHelp)
        let mermaidRenderModeLabel = makeRowLabel("Mermaid render mode", tooltip: mermaidRenderModeHelp)
        let checkboxHitTargetLabel = makeRowLabel("Checkbox hit target", tooltip: checkboxHitTargetHelp)
        let themeModeLabel = makeRowLabel("Theme", tooltip: themeModeHelp)
        let importThemeLabel = makeRowLabel("Theme import", tooltip: importThemeHelp)
        let fontFamilyLabel = makeRowLabel("Font family", tooltip: fontFamilyHelp)
        let customFontFamilyLabel = makeRowLabel("Custom font family", tooltip: customFontFamilyHelp)
        let fontDesignLabel = makeRowLabel("Font design", tooltip: fontDesignHelp)
        let fontSizeLabel = makeRowLabel("Font size", tooltip: fontSizeHelp)
        let tableOverflowModeLabel = makeRowLabel("Table overflow", tooltip: tableOverflowModeHelp)
        let orderedTasksLabel = makeRowLabel("Enable ordered tasks", tooltip: orderedTasksHelp)
        let headingCheckboxesLabel = makeRowLabel("Enable heading checkboxes", tooltip: headingCheckboxesHelp)
        let remoteImageLoadingLabel = makeRowLabel("Enable remote image loading", tooltip: remoteImageLoadingHelp)

        let grid = NSGridView(views: [
            [exportDialectLabel, exportDialectPopup],
            [gfmExtensionStrategyLabel, gfmExtensionStrategyPopup],
            [taskRenderingLabel, taskRenderingPopup],
            [orderedNumberingLabel, orderedNumberingPopup],
            [syntaxVisibilityLabel, syntaxVisibilityPopup],
            [mermaidRenderModeLabel, mermaidRenderModePopup],
            [checkboxHitTargetLabel, checkboxHitTargetPopup],
            [themeModeLabel, themeModePopup],
            [importThemeLabel, themeButtonsStack],
            [fontFamilyLabel, fontFamilyPopup],
            [customFontFamilyLabel, customFontFamilyField],
            [fontDesignLabel, fontDesignPopup],
            [fontSizeLabel, fontSizePopup],
            [tableOverflowModeLabel, tableOverflowModePopup],
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

        content.addSubview(grid)
        content.addSubview(noteLabel)
        content.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
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
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root

        // Apply minimum control widths for a stable layout.
        [exportDialectPopup, gfmExtensionStrategyPopup, taskRenderingPopup, orderedNumberingPopup, syntaxVisibilityPopup, mermaidRenderModePopup, checkboxHitTargetPopup, themeModePopup, fontFamilyPopup, fontDesignPopup, fontSizePopup, tableOverflowModePopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        }
        customFontFamilyField.translatesAutoresizingMaskIntoConstraints = false
        customFontFamilyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
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

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isSyncingControls else { return }
        settingDidChange(obj.object)
    }
}
