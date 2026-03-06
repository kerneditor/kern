import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorBackspaceUnlistTests: XCTestCase {
    private var savedSyntaxVisibilityMode: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSyntaxVisibilityMode = defaults.object(forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedSyntaxVisibilityMode {
            defaults.set(savedSyntaxVisibilityMode, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        } else {
            defaults.removeObject(forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
        }
        super.tearDown()
    }

    @MainActor
    func testBackspaceAtBulletContentStartUnlistsParagraph() {
        let (vc, textView) = makeController(markdown: "- alpha\n")
        let ns = textView.string as NSString
        let body = ns.range(of: "alpha")
        XCTAssertNotEqual(body.location, NSNotFound)

        textView.setSelectedRange(NSRange(location: body.location, length: 0))
        let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled)

        XCTAssertEqual(textView.string, "alpha\n")
        let out = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(out, "alpha\n")
    }

    @MainActor
    func testBackspaceAtTaskContentStartUnlistsAndPreservesInlineStyle() {
        let (vc, textView) = makeController(markdown: "- [ ] **alpha**\n")
        let ns = textView.string as NSString
        let body = ns.range(of: "alpha")
        XCTAssertNotEqual(body.location, NSNotFound)

        textView.setSelectedRange(NSRange(location: body.location, length: 0))
        let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled)

        let out = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(out, "**alpha**\n")
    }

    @MainActor
    func testBackspaceAtOrderedContentStartUnlistsParagraph() {
        let (vc, textView) = makeController(markdown: "1. alpha\n")
        let ns = textView.string as NSString
        let body = ns.range(of: "alpha")
        XCTAssertNotEqual(body.location, NSNotFound)

        textView.setSelectedRange(NSRange(location: body.location, length: 0))
        let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(handled)

        XCTAssertEqual(textView.string, "alpha\n")
        let out = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
        XCTAssertEqual(out, "alpha\n")
    }

    @MainActor
    func testBackspaceInsideListBodyDoesNotInterceptDeleteCommand() {
        let (vc, textView) = makeController(markdown: "- alpha\n")
        let ns = textView.string as NSString
        let body = ns.range(of: "alpha")
        XCTAssertNotEqual(body.location, NSNotFound)

        // Place caret in the middle of the body, not at marker boundary.
        textView.setSelectedRange(NSRange(location: body.location + 2, length: 0))
        let handled = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertFalse(handled)
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(markdown: String) -> (NativeEditorViewController, NativeMarkdownTextView) {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown

        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        return (vc, textView)
    }

    @MainActor
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView {
            return tv
        }
        for sub in view.subviews {
            if let found = findTextView(in: sub) {
                return found
            }
        }
        return nil
    }
}
