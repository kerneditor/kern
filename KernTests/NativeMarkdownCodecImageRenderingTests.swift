import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecImageRenderingTests: XCTestCase {
    @MainActor
    func testLocalImagesFromStressFixtureResolveAndRender() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("test-fixtures", isDirectory: true)
            .appendingPathComponent("stress-test.md", isDirectory: false)
        let markdown = try String(contentsOf: fixtureURL, encoding: .utf8)

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults(), baseURL: fixtureURL)
        let images = collectImageAttachments(in: attributed)

        XCTAssertFalse(images.isEmpty, "Expected image attachments in stress fixture")

        guard let local = images.first(where: { $0.destination.contains("screenshots/01-default-sample.png") }) else {
            XCTFail("Missing local stress-fixture image attachment")
            return
        }

        XCTAssertNotNil(local.resolvedURL)
        XCTAssertTrue(local.resolvedURL?.isFileURL == true)

        // Local images load asynchronously off the main thread; spin the run loop
        // briefly to let the background read + main-queue callback complete.
        let ready = expectation(description: "Local image loads asynchronously")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            ready.fulfill()
        }
        waitForExpectations(timeout: 3.0)

        XCTAssertTrue(local.debugHasRenderedImage, "Local file image should have loaded")
        XCTAssertEqual(local.loadState, .ready)
    }

    @MainActor
    func testRemoteImageAttachmentRespectsDisabledRemoteLoading() {
        let markdown = "![Remote](https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/Fronalpstock_big.jpg/640px-Fronalpstock_big.jpg)"
        var options = NativeMarkdownCodec.Options.fromUserDefaults()
        options.remoteImageLoadingEnabled = false

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: nil)
        let images = collectImageAttachments(in: attributed)
        XCTAssertEqual(images.count, 1)

        guard let image = images.first else { return }
        XCTAssertFalse(image.allowsRemoteLoading)
        XCTAssertEqual(image.loadState, .failed)
        XCTAssertFalse(image.debugHasRenderedImage)
    }

    @MainActor
    func testImageAttachmentsCarryClickableLinkAttributes() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("test-fixtures", isDirectory: true)
            .appendingPathComponent("stress-test.md", isDirectory: false)

        let markdown = """
        ![Local sample](screenshots/01-default-sample.png)

        ![Remote sample](https://upload.wikimedia.org/wikipedia/commons/thumb/0/02/Oia%2C_Santorini_HDR_sunset.jpg/640px-Oia%2C_Santorini_HDR_sunset.jpg)
        """

        var options = NativeMarkdownCodec.Options.fromUserDefaults()
        options.remoteImageLoadingEnabled = false

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: options, baseURL: fixtureURL)

        var sawLocal = false
        var sawRemote = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, _, _ in
            guard let attachment = attrs[.attachment] as? MarkdownImageAttachment else { return }
            guard let linkURL = attrs[.link] as? URL else {
                XCTFail("Image attachment missing .link attribute for destination: \(attachment.destination)")
                return
            }

            if attachment.destination.contains("screenshots/01-default-sample.png") {
                sawLocal = true
                XCTAssertTrue(linkURL.isFileURL, "Local image should expose file:// link target")
            } else if attachment.destination.contains("upload.wikimedia.org") {
                sawRemote = true
                XCTAssertEqual(linkURL.scheme?.lowercased(), "https")
            }
        }

        XCTAssertTrue(sawLocal, "Expected local image attachment with link target")
        XCTAssertTrue(sawRemote, "Expected remote image attachment with link target")
    }

    // MARK: - Helpers

    private func collectImageAttachments(in attributed: NSAttributedString) -> [MarkdownImageAttachment] {
        var out: [MarkdownImageAttachment] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.attachment, in: full, options: []) { value, _, _ in
            if let attachment = value as? MarkdownImageAttachment {
                out.append(attachment)
            }
        }
        return out
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests
            .deletingLastPathComponent() // repo root
    }
}
