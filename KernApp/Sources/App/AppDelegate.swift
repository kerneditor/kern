import AppKit
import os
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var keepRunning: Bool {
        get { UserDefaults.standard.bool(forKey: "keepRunningInBackground") }
        set { UserDefaults.standard.set(newValue, forKey: "keepRunningInBackground") }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSLog("[Perf] applicationWillFinishLaunching at %@ms", msSinceStart())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Perf] applicationDidFinishLaunching start at %@ms", msSinceStart())

        buildMenuBar()

        NSLog("[Perf] applicationDidFinishLaunching end at %@ms", msSinceStart())

        // Defer untitled document creation to the next run loop iteration.
        // By then, any Apple Event from `open -a KernTextKit file.md` will have triggered
        // KernDocumentController.openDocument(withContentsOf:), setting hasOpenedDocument.
        DispatchQueue.main.async { [weak self] in
            self?.openUntitledIfNeeded()
        }
    }

    private func openUntitledIfNeeded() {
        let dc = NSDocumentController.shared
        // Skip if files are already being opened via Apple Events or other means
        if let kernDC = dc as? KernDocumentController, kernDC.hasOpenedDocument { return }
        guard dc.documents.isEmpty else { return }
        do {
            try dc.openUntitledDocumentAndDisplay(true)
        } catch {
            NSLog("[AppDelegate] Failed to open untitled document: %@", error.localizedDescription)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Save (Flush Native Editor First)

    @objc func saveDocument(_ sender: Any?) {
        flushNativeEditorExportIfNeeded()
        currentDocument()?.save(sender)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        flushNativeEditorExportIfNeeded()
        currentDocument()?.saveAs(sender)
    }

    private func currentDocument() -> NSDocument? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let doc = window?.windowController?.document as? NSDocument {
            return doc
        }
        return NSDocumentController.shared.currentDocument
    }

    private func flushNativeEditorExportIfNeeded() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let nativeVC = window?.contentViewController as? NativeEditorViewController else { return }
        nativeVC.flushPendingExport()
    }

    // MARK: - New Window / New Tab

    @objc func newWindow(_ sender: Any?) {
        let dc = NSDocumentController.shared
        do {
            let doc = try dc.openUntitledDocumentAndDisplay(false)
            doc.makeWindowControllers()
            if let newWindow = doc.windowControllers.first?.window {
                // Temporarily prevent merging into existing tab group
                newWindow.tabbingMode = .disallowed
                newWindow.makeKeyAndOrderFront(sender)
                // Restore so tabs can be added to this window later
                newWindow.tabbingMode = .automatic
            }
        } catch {
            NSLog("[AppDelegate] Failed to create new window: %@", error.localizedDescription)
        }
    }

    @objc func newTab(_ sender: Any?) {
        let dc = NSDocumentController.shared
        do {
            let doc = try dc.openUntitledDocumentAndDisplay(false)
            doc.makeWindowControllers()
            if let newWindow = doc.windowControllers.first?.window {
                if let currentWindow = NSApp.mainWindow {
                    currentWindow.addTabbedWindow(newWindow, ordered: .above)
                    newWindow.makeKeyAndOrderFront(sender)
                } else {
                    // No window exists, show as standalone
                    newWindow.makeKeyAndOrderFront(sender)
                }
            }
        } catch {
            NSLog("[AppDelegate] Failed to create new tab: %@", error.localizedDescription)
        }
    }

    // MARK: - Background Daemon

    @objc func toggleKeepRunning(_ sender: NSMenuItem) {
        keepRunning.toggle()
        if keepRunning {
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("[AppDelegate] Failed to register login item: %@", error.localizedDescription)
            }
        } else {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                NSLog("[AppDelegate] Failed to unregister login item: %@", error.localizedDescription)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if keepRunning {
            for window in NSApp.windows where window.isVisible {
                window.close()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.setActivationPolicy(.accessory)
            }
            NSApp.hide(nil)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !flag {
            openUntitledIfNeeded()
        }
        return true
    }

    // MARK: - Menu Bar

    private func buildMenuBar() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let keepRunningItem = NSMenuItem(
            title: "Keep Running in Background",
            action: #selector(toggleKeepRunning(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(keepRunningItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Save As…", action: #selector(saveDocumentAs(_:)), keyEquivalent: "S")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())

        // Find submenu
        let findMenuItem = NSMenuItem()
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(withTitle: "Find\u{2026}", action: #selector(NativeEditorViewController.showFind(_:)), keyEquivalent: "f")
        let findReplaceItem = NSMenuItem(title: "Find and Replace\u{2026}", action: #selector(NativeEditorViewController.showFindReplace(_:)), keyEquivalent: "h")
        findReplaceItem.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findReplaceItem)
        findMenu.addItem(NSMenuItem.separator())
        findMenu.addItem(withTitle: "Find Next", action: #selector(NativeEditorViewController.findNext(_:)), keyEquivalent: "g")
        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(NativeEditorViewController.findPrevious(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findPrevItem)
        findMenu.addItem(NSMenuItem.separator())
        let useSelectionItem = NSMenuItem(title: "Use Selection for Find", action: #selector(NativeEditorViewController.useSelectionForFind(_:)), keyEquivalent: "e")
        findMenu.addItem(useSelectionItem)
        findMenuItem.submenu = findMenu
        findMenuItem.title = "Find"
        editMenu.addItem(findMenuItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Format menu
        let formatMenuItem = NSMenuItem()
        let formatMenu = NSMenu(title: "Format")
        formatMenu.addItem(withTitle: "Bold", action: #selector(NativeEditorViewController.toggleBold(_:)), keyEquivalent: "b")
        formatMenu.addItem(withTitle: "Italic", action: #selector(NativeEditorViewController.toggleItalic(_:)), keyEquivalent: "i")
        let codeItem = NSMenuItem(title: "Code", action: #selector(NativeEditorViewController.toggleCode(_:)), keyEquivalent: "`")
        formatMenu.addItem(codeItem)
        formatMenuItem.submenu = formatMenu
        mainMenu.addItem(formatMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

// MARK: - NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            // Enable whenever there is an active document window.
            return currentDocument() != nil
        case #selector(toggleKeepRunning(_:)):
            menuItem.state = keepRunning ? .on : .off
            return true
        default:
            return true
        }
    }
}
