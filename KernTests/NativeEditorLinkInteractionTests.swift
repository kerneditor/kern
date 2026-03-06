import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorLinkInteractionTests: XCTestCase {
    @MainActor
    func testExternalHTTPLinkUsesOpenHandler() {
        let vc = NativeEditorViewController()
        _ = vc.view

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let url = URL(string: "https://example.com/docs")!
        let handled = vc.textView(NSTextView(), clickedOnLink: url, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened, url)
    }

    @MainActor
    func testMailtoLinkUsesOpenHandler() {
        let vc = NativeEditorViewController()
        _ = vc.view

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let url = URL(string: "mailto:test@example.com")!
        let handled = vc.textView(NSTextView(), clickedOnLink: url, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened, url)
    }

    @MainActor
    func testFileLinkUsesOpenHandler() {
        let vc = NativeEditorViewController()
        _ = vc.view

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let url = URL(fileURLWithPath: "/tmp/kern-image.png")
        let handled = vc.textView(NSTextView(), clickedOnLink: url, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened, url)
    }

    @MainActor
    func testUnsupportedSchemeLinkReturnsFalse() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.openExternalURLHandler = { _ in
            XCTFail("openExternalURLHandler should not be called for unsupported schemes")
            return false
        }

        let url = URL(string: "ftp://example.com/archive")!
        let handled = vc.textView(NSTextView(), clickedOnLink: url, at: 0)
        XCTAssertFalse(handled)
    }

    @MainActor
    func testRelativePathLinkResolvesAgainstDocumentDirectory() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = URL(fileURLWithPath: "/tmp/kern/docs/current.md")

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let handled = vc.textView(NSTextView(), clickedOnLink: URL(string: "guides/intro.md")!, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened?.standardizedFileURL.path, "/tmp/kern/docs/guides/intro.md")
    }

    @MainActor
    func testRelativePathStringLinkWithFragmentResolvesAgainstDocumentDirectory() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = URL(fileURLWithPath: "/tmp/kern/docs/current.md")

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let handled = vc.textView(NSTextView(), clickedOnLink: "guides/intro.md#overview", at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened?.standardizedFileURL.path, "/tmp/kern/docs/guides/intro.md")
        XCTAssertEqual(opened?.fragment, "overview")
    }

    @MainActor
    func testRootPathLinkResolvesToFileURL() {
        let vc = NativeEditorViewController()
        _ = vc.view

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let handled = vc.textView(NSTextView(), clickedOnLink: URL(string: "/tmp/kern/root.md")!, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened?.standardizedFileURL.path, "/tmp/kern/root.md")
    }

    @MainActor
    func testBareDomainStringLinkNormalizesToHTTPS() {
        let vc = NativeEditorViewController()
        _ = vc.view

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let handled = vc.textView(NSTextView(), clickedOnLink: "example.com", at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened?.scheme?.lowercased(), "https")
        XCTAssertEqual(opened?.host?.lowercased(), "example.com")
    }

    @MainActor
    func testBareDomainURLLinkNormalizesToHTTPS() {
        let vc = NativeEditorViewController()
        _ = vc.view

        var opened: URL?
        vc.openExternalURLHandler = { url in
            opened = url
            return true
        }

        let handled = vc.textView(NSTextView(), clickedOnLink: URL(string: "example.com/docs")!, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(opened?.scheme?.lowercased(), "https")
        XCTAssertEqual(opened?.host?.lowercased(), "example.com")
        XCTAssertEqual(opened?.path, "/docs")
    }

    @MainActor
    func testInternalAnchorDoesNotCallOpenHandler() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        # Doc

        - [Jump](#target)

        ## Target
        """

        var openCalls = 0
        vc.openExternalURLHandler = { _ in
            openCalls += 1
            return true
        }

        let handled = vc.textView(NSTextView(), clickedOnLink: URL(string: "#target")!, at: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(openCalls, 0)
    }
}
