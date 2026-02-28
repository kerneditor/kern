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
