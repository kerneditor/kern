@preconcurrency import AppKit

/// NSDocument subclass for markdown files.
/// NOT @MainActor at class level — read/write methods are called on background threads.
/// @preconcurrency suppresses Swift 6 strict MainActor checks on NSDocument bridge thunks,
/// allowing NSDocumentController to call init(contentsOf:ofType:) from background threads.
final class EditorDocument: NSDocument {

    /// Current markdown content — updated by contentChanged callback
    var stringValue: String = ""

    /// Track the last known file modification date to prevent autosave↔file watching loops
    var lastKnownFileModDate: Date?

    // MARK: - Init (must be nonisolated for NSDocumentController background opening)

    nonisolated override init() {
        super.init()
    }

    // MARK: - Document Configuration

    override class var autosavesInPlace: Bool { true }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    // MARK: - Reading

    override func read(from data: Data, ofType typeName: String) throws {
        // Try UTF-8 first (the common case).
        if let content = String(data: data, encoding: .utf8) {
            stringValue = content
            return
        }
        // Check for UTF-16 BOM before trying lossy single-byte encodings.
        if data.count >= 2 {
            let bom = (data[data.startIndex], data[data.startIndex + 1])
            if bom == (0xFF, 0xFE) || bom == (0xFE, 0xFF) {
                if let content = String(data: data, encoding: .utf16) {
                    stringValue = content
                    return
                }
            }
        }
        // Fall back to common single-byte encodings (isoLatin1 covers all 0-255 byte values).
        if let content = String(data: data, encoding: .isoLatin1) {
            stringValue = content
            return
        }
        throw NSError(
            domain: NSOSStatusErrorDomain,
            code: unimpErr,
            userInfo: [NSLocalizedDescriptionKey: "Unable to read file as text (tried UTF-8 and auto-detection)"]
        )
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        guard let data = stringValue.data(using: .utf8) else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: unimpErr,
                userInfo: [NSLocalizedDescriptionKey: "Unable to encode content as UTF-8"]
            )
        }
        return data
    }

    // MARK: - Window Controllers

    @MainActor
    override func makeWindowControllers() {
        let isUITesting = ProcessInfo.processInfo.environment["KERN_UI_TESTING"] == "1"

        // Restore Dock icon and menu bar if app was hidden in background daemon mode
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        let windowController = EditorWindowController()
        addWindowController(windowController)

        // UI tests are only reliable if the app is the foreground app.
        // `xcodebuild test` can launch the app in the background, so force a best-effort activation here.
        if isUITesting {
            windowController.showWindow(self)
            windowController.window?.makeKeyAndOrderFront(self)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Establish a baseline mod date so our file presenter doesn't treat the initial open
        // (or our own autosaves) as "external" writes and trigger a revert loop.
        if let fileURL {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                if let modDate = attrs[.modificationDate] as? Date {
                    lastKnownFileModDate = modDate
                }
            } catch {
                // Ignore; file watching will still work but may be noisier.
            }
        }

        // Connect the editor VC to this document
        if let editorVC = windowController.contentViewController as? NativeEditorViewController {
            editorVC.documentURL = fileURL
            editorVC.stringValue = stringValue
            editorVC.onContentChanged = { [weak self] markdown in
                guard let self else { return }
                self.stringValue = markdown
                self.updateChangeCount(.changeDone)
            }
        }
    }

    // MARK: - Save Hooks

    override func save(_ sender: Any?) {
        flushPendingExportBeforeSave()
        super.save(sender)
    }

    override func saveAs(_ sender: Any?) {
        flushPendingExportBeforeSave()
        super.saveAs(sender)
    }

    private func flushPendingExportBeforeSave() {
        let flush = { [self] in
            MainActor.assumeIsolated {
                let nativeVC = windowControllers
                    .compactMap { $0.contentViewController as? NativeEditorViewController }
                    .first
                nativeVC?.flushPendingExport()
            }
        }

        if Thread.isMainThread {
            flush()
        } else {
            DispatchQueue.main.sync(execute: flush)
        }
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        // Use the actual on-disk mod date to prevent false-positive reloads from filesystem timestamp
        // rounding/resolution differences.
        // writeSafely can be called off-main, but lastKnownFileModDate is read on main.
        // Dispatch the write to main to eliminate the data race.
        let modDate: Date
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            modDate = (attrs[.modificationDate] as? Date) ?? Date()
        } catch {
            modDate = Date()
        }
        DispatchQueue.main.async { [weak self] in
            self?.lastKnownFileModDate = modDate
        }
    }

    // MARK: - File Watching

    private var reloadWorkItem: DispatchWorkItem?

    override func presentedItemDidChange() {
        // Called on NSFilePresenter queue — dispatch to main to avoid deadlock.
        // Never do file coordination inside presentedItemDidChange.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadWorkItem?.cancel()

            guard let fileURL = self.fileURL, let fileType = self.fileType else { return }

            // Debounce: 300ms batches rapid AI agent writes
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let modDate = attrs[.modificationDate] as? Date
                    guard let modDate else { return }

                    // If we don't have a baseline yet, establish it and ignore this change.
                    if self.lastKnownFileModDate == nil {
                        self.lastKnownFileModDate = modDate
                        return
                    }

                    guard modDate > (self.lastKnownFileModDate ?? .distantPast) else { return }
                    self.lastKnownFileModDate = modDate

                    try self.revert(toContentsOf: fileURL, ofType: fileType)

                    // Push reverted content to editor with scroll preservation
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let hostVC = self.hostNativeViewController {
                            hostVC.applyExternalMarkdownUpdate(self.stringValue)
                            hostVC.showReloadToast()
                        }
                    }
                } catch {
                    NSLog("[EditorDocument] File reload failed: %@", error.localizedDescription)
                }
            }
            self.reloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    // MARK: - Helpers

    /// Find the NativeEditorViewController from our window controllers
    @MainActor
    var hostNativeViewController: NativeEditorViewController? {
        windowControllers
            .compactMap { $0.contentViewController as? NativeEditorViewController }
            .first
    }
}
