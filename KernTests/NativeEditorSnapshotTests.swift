import AppKit
import SnapshotTesting
import XCTest
@testable import KernTextKit

final class NativeEditorSnapshotTests: XCTestCase {
    @MainActor
    func testBasicFixture_GfmDefault_Light() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let fixture = try loadFixture(name: "basic.in.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 900, height: 650),
                    appearance: .init(named: .aqua)
                )
                assertSnapshot(of: view, as: Snapshotting<NSView, NSImage>.image(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testExtensionsFixture_KernProfile_Dark() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .kernExtensions) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let fixture = try loadFixture(name: "extensions.in.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 900, height: 650),
                    appearance: .init(named: .darkAqua)
                )
                assertSnapshot(of: view, as: Snapshotting<NSView, NSImage>.image(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testImagesFixture_GfmDefault_Light() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let fixture = try loadFixture(name: "images.fixture.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 960, height: 760),
                    appearance: .init(named: .aqua)
                )
                assertSnapshot(of: view, as: Snapshotting<NSView, NSImage>.image(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testFullSpecVisualFixture_GfmDefault_Dark() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let fixture = try loadFixture(name: "full-spec-visual.fixture.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 980, height: 980),
                    appearance: .init(named: .darkAqua)
                )
                assertSnapshot(of: view, as: Snapshotting<NSView, NSImage>.image(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testFullSpecVisualFixture_RenderPipelineKeepsAttachments() throws {
        let fixture = try loadFixture(name: "full-spec-visual.fixture.md")
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = fixture.url
        vc.stringValue = fixture.markdown

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView,
              let storage = textView.textStorage else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        let deadline = Date().addingTimeInterval(6.0)
        var attachmentCount = 0
        var attachmentsWithCell = 0
        while Date() < deadline {
            attachmentCount = 0
            attachmentsWithCell = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                attachmentCount += 1
                if attachment.attachmentCell != nil {
                    attachmentsWithCell += 1
                }
            }
            if attachmentCount >= 4 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(attachmentCount, 4, "Expected image + HR + math + mermaid attachments in full-spec fixture render pipeline")
        XCTAssertEqual(attachmentsWithCell, attachmentCount, "All rendered attachments must keep a cell")
    }

    /// Exhaustive visual matrix. This is intentionally gated behind `KERN_ENABLE_EXHAUSTIVE_TESTS=1`
    /// since it produces many snapshots and can be slow.
    @MainActor
    func testSnapshotMatrix_Exhaustive() throws {
        try TestGates.skipUnlessSnapshots()
        try TestGates.skipUnlessExhaustive()

        let fixtures = [
            "basic.in.md",
            "extensions.in.md",
            "code-chrome.fixture.md",
            "full-spec-visual.fixture.md",
            "ordered-numbering.in.md",
            "task-permutations.fixture.md",
            "soft-breaks.in.md",
            "tables.in.md",
        ]

        let profiles: [DefaultsProfile] = [.gfmDefault, .kernExtensions]
        let appearances: [(String, NSAppearance?)] = [
            ("light", .init(named: .aqua)),
            ("dark", .init(named: .darkAqua)),
        ]
        let sizes: [(String, NSSize)] = [
            ("sm", .init(width: 700, height: 520)),
            ("lg", .init(width: 900, height: 650)),
        ]

        for profile in profiles {
            try withNativeEditorDefaults(profile: profile) {
                try withSnapshotTesting(record: snapshotRecordMode) {
                    for fixture in fixtures {
                        let loaded = try loadFixture(name: fixture)

                        for (appearanceName, appearance) in appearances {
                            for (sizeName, size) in sizes {
                                let view = makeSnapshotView(
                                    fixture: loaded,
                                    size: size,
                                    appearance: appearance
                                )
                                assertSnapshot(
                                    of: view,
                                    as: Snapshotting<NSView, NSImage>.image(size: view.bounds.size),
                                    named: "\(profile)_\(fixture)_\(appearanceName)_\(sizeName)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Snapshot gating

    private var snapshotRecordMode: SnapshotTestingConfiguration.Record {
        TestGates.recordSnapshots ? .all : .never
    }

    // MARK: - Defaults profiles

    private enum DefaultsProfile {
        case gfmDefault
        case kernExtensions
    }

    private func withNativeEditorDefaults(profile: DefaultsProfile, _ f: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "nativeEditor.exportDialect",
            "nativeEditor.taskRendering",
            "nativeEditor.orderedTasksEnabled",
            "nativeEditor.headingCheckboxesEnabled",
            "nativeEditor.orderedListNumbering",
            "nativeEditor.mermaidRenderMode",
        ]

        let previous: [String: Any?] = keys.reduce(into: [:]) { acc, k in
            acc[k] = defaults.object(forKey: k)
        }
        defer {
            for k in keys {
                if let v = previous[k] {
                    defaults.set(v, forKey: k)
                } else {
                    defaults.removeObject(forKey: k)
                }
            }
        }

        switch profile {
        case .gfmDefault:
            defaults.set("gfm", forKey: "nativeEditor.exportDialect")
            defaults.set("gfm", forKey: "nativeEditor.taskRendering")
            defaults.set(false, forKey: "nativeEditor.orderedTasksEnabled")
            defaults.set(false, forKey: "nativeEditor.headingCheckboxesEnabled")
            defaults.set("gfmDefault", forKey: "nativeEditor.orderedListNumbering")
            defaults.set("rich", forKey: "nativeEditor.mermaidRenderMode")
        case .kernExtensions:
            defaults.set("kern", forKey: "nativeEditor.exportDialect")
            defaults.set("kern", forKey: "nativeEditor.taskRendering")
            defaults.set(true, forKey: "nativeEditor.orderedTasksEnabled")
            defaults.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
            defaults.set("preserveTyped", forKey: "nativeEditor.orderedListNumbering")
            defaults.set("rich", forKey: "nativeEditor.mermaidRenderMode")
        }

        try f()
    }

    // MARK: - Fixtures

    private func loadFixture(name: String) throws -> (url: URL, markdown: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures/native-editor-golden", isDirectory: true)
            .appendingPathComponent(name)
        return (url: url, markdown: try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Hosting

    @MainActor
    private func hostInWindow(vc: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSView {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.contentViewController = vc

        // Snapshot the window's content view (includes background + padding).
        let content = window.contentView ?? vc.view
        if let appearance {
            applyAppearance(appearance, to: content)
        }

        // SnapshotTesting captures the NSView image directly. Since our editor surface is transparent
        // (real app background comes from the window), enforce a solid backing color here so baselines
        // are deterministic and don't appear as "blank black" transparent PNGs.
        content.wantsLayer = true
        content.layer?.backgroundColor = resolvedWindowBackgroundColor(for: appearance).cgColor

        // Force layout.
        window.setFrame(rect, display: true)
        window.layoutIfNeeded()
        content.setFrameSize(size)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        return content
    }

    @MainActor
    private func makeSnapshotView(
        fixture: (url: URL, markdown: String),
        size: NSSize,
        appearance: NSAppearance?
    ) -> NSView {
        let vc = NativeEditorViewController()
        _ = vc.view
        let view = hostInWindow(vc: vc, size: size, appearance: appearance)

        vc.documentURL = fixture.url
        vc.stringValue = fixture.markdown

        settleSnapshotView(view)
        return view
    }

    @MainActor
    private func settleSnapshotView(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        if let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: view) as? NSTextView {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        if let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: view) as? NSScrollView {
            let clip = scrollView.contentView
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
        }

        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    @MainActor
    private func applyAppearance(_ appearance: NSAppearance, to view: NSView) {
        view.appearance = appearance
        for sub in view.subviews {
            applyAppearance(appearance, to: sub)
        }
    }

    @MainActor
    private func resolvedWindowBackgroundColor(for appearance: NSAppearance?) -> NSColor {
        if let appearance, appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedWhite: 0.11, alpha: 1.0)
        }
        return NSColor(calibratedWhite: 0.97, alpha: 1.0)
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
}
