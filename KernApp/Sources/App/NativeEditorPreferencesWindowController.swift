import AppKit

extension Notification.Name {
    static let nativeEditorPreferencesDidChange = Notification.Name("NativeEditorPreferencesDidChange")
}

@MainActor
final class NativeEditorPreferencesWindowController: NSWindowController {
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
    private let mermaidRenderModePopup = NSPopUpButton()
    private let checkboxHitTargetPopup = NSPopUpButton()

    private let orderedTasksCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let headingCheckboxesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let remoteImageLoadingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
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
            defaults.string(forKey: "nativeEditor.mermaidRenderMode")
                ?? NativeMarkdownCodec.Options.MermaidRenderMode.rich.rawValue,
            in: mermaidRenderModePopup
        )
        selectValue(
            defaults.string(forKey: "nativeEditor.checkboxHitTarget") ?? "glyph",
            in: checkboxHitTargetPopup
        )

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
        defaults.set(
            NativeMarkdownCodec.Options.MermaidRenderMode.rich.rawValue,
            forKey: "nativeEditor.mermaidRenderMode"
        )
        defaults.set("glyph", forKey: "nativeEditor.checkboxHitTarget")
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
        if let value = selectedValue(from: mermaidRenderModePopup) {
            defaults.set(value, forKey: "nativeEditor.mermaidRenderMode")
        }
        if let value = selectedValue(from: checkboxHitTargetPopup) {
            defaults.set(value, forKey: "nativeEditor.checkboxHitTarget")
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
        let mermaidRenderModeHelp =
            "Mermaid render mode: Rich draws full native diagrams, ASCII is a lightweight text diagram, Auto switches by complexity."
        let checkboxHitTargetHelp =
            "Click behavior for toggling tasks. Glyph-only toggles only on the checkbox; marker-region toggles from anywhere in the list marker area."
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

        orderedTasksCheckbox.title = ""
        headingCheckboxesCheckbox.title = ""
        remoteImageLoadingCheckbox.title = ""

        exportDialectPopup.toolTip = exportDialectHelp
        gfmExtensionStrategyPopup.toolTip = gfmExtensionStrategyHelp
        taskRenderingPopup.toolTip = taskRenderingHelp
        orderedNumberingPopup.toolTip = orderedNumberingHelp
        mermaidRenderModePopup.toolTip = mermaidRenderModeHelp
        checkboxHitTargetPopup.toolTip = checkboxHitTargetHelp
        orderedTasksCheckbox.toolTip = orderedTasksHelp
        headingCheckboxesCheckbox.toolTip = headingCheckboxesHelp
        remoteImageLoadingCheckbox.toolTip = remoteImageLoadingHelp

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let exportDialectLabel = makeRowLabel("Export dialect", tooltip: exportDialectHelp)
        let gfmExtensionStrategyLabel = makeRowLabel("GFM extension strategy", tooltip: gfmExtensionStrategyHelp)
        let taskRenderingLabel = makeRowLabel("Task rendering", tooltip: taskRenderingHelp)
        let orderedNumberingLabel = makeRowLabel("Ordered list numbering", tooltip: orderedNumberingHelp)
        let mermaidRenderModeLabel = makeRowLabel("Mermaid render mode", tooltip: mermaidRenderModeHelp)
        let checkboxHitTargetLabel = makeRowLabel("Checkbox hit target", tooltip: checkboxHitTargetHelp)
        let orderedTasksLabel = makeRowLabel("Enable ordered tasks", tooltip: orderedTasksHelp)
        let headingCheckboxesLabel = makeRowLabel("Enable heading checkboxes", tooltip: headingCheckboxesHelp)
        let remoteImageLoadingLabel = makeRowLabel("Enable remote image loading", tooltip: remoteImageLoadingHelp)

        let grid = NSGridView(views: [
            [exportDialectLabel, exportDialectPopup],
            [gfmExtensionStrategyLabel, gfmExtensionStrategyPopup],
            [taskRenderingLabel, taskRenderingPopup],
            [orderedNumberingLabel, orderedNumberingPopup],
            [mermaidRenderModeLabel, mermaidRenderModePopup],
            [checkboxHitTargetLabel, checkboxHitTargetPopup],
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
        [exportDialectPopup, gfmExtensionStrategyPopup, taskRenderingPopup, orderedNumberingPopup, mermaidRenderModePopup, checkboxHitTargetPopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
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
}
