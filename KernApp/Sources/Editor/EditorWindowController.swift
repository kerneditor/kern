import AppKit

/// Programmatic NSWindowController for editor windows.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let isUITesting = ProcessInfo.processInfo.environment["KERN_UI_TESTING"] == "1"
        let testSize = Self.parseTestWindowSize()

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: testSize?.width ?? 800,
                height: testSize?.height ?? 600
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 480)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.acceptsMouseMovedEvents = true

        let editorVC: NSViewController = NativeEditorViewController()
        window.contentViewController = editorVC

        // Ensure the editor view fills the content area.
        if let contentView = window.contentView {
            editorVC.view.frame = contentView.bounds
        }

        self.init(window: window)

        window.delegate = self

        // Deterministic window sizing for UI tests and visual baselines.
        if isUITesting || testSize != nil {
            window.center()
            if let appearance = Self.parseTestAppearance() {
                window.appearance = appearance
            }
        } else {
            window.setFrameAutosaveName("KernEditorWindow")
            // Only center if no saved frame was restored
            if !window.setFrameUsingName("KernEditorWindow") {
                window.center()
            }
        }
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        if let document {
            window?.title = document.displayName
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        // no-op
    }

    func windowWillClose(_ notification: Notification) {
        // no-op
    }

    // MARK: - Test Helpers

    private static func parseTestWindowSize() -> NSSize? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["KERN_TEST_WINDOW_SIZE"] ?? env["KERN_UI_WINDOW_SIZE"] else { return nil }

        // Accept formats like "900x650" or "900,650".
        let cleaned = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let parts: [String]
        if cleaned.contains("x") {
            parts = cleaned.split(separator: "x", maxSplits: 1).map(String.init)
        } else if cleaned.contains(",") {
            parts = cleaned.split(separator: ",", maxSplits: 1).map(String.init)
        } else {
            return nil
        }

        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              w >= 200, h >= 200
        else { return nil }

        return NSSize(width: w, height: h)
    }

    private static func parseTestAppearance() -> NSAppearance? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["KERN_TEST_APPEARANCE"]?.lowercased() else { return nil }
        switch raw {
        case "light":
            return NSAppearance(named: .aqua)
        case "dark":
            return NSAppearance(named: .darkAqua)
        default:
            return nil
        }
    }
}
