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

    @MainActor
    func testAsyncLocalImageLoadInvalidatesLayoutAndExpandsRenderedBlock() throws {
        let sourceImage = repoRoot()
            .appendingPathComponent("test-fixtures", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
            .appendingPathComponent("01-default-sample.png", isDirectory: false)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-image-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let copiedImage = tempDir.appendingPathComponent("sample.png", isDirectory: false)
        try FileManager.default.copyItem(at: sourceImage, to: copiedImage)

        let markdownURL = tempDir.appendingPathComponent("fixture.md", isDirectory: false)
        let markdown = "![Local sample](sample.png)\n\nTail\n"
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = markdownURL
        vc.stringValue = markdown
        let window = hostInWindow(vc: vc, size: NSSize(width: 960, height: 640), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()

        let textView = vc.textViewForTesting()
        guard let textStorage = textView.textStorage,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager,
              let attachment = collectImageAttachments(in: textStorage).first else {
            XCTFail("Missing local image attachment in rendered editor")
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        XCTAssertEqual(attachment.loadState, .loading, "Fresh local image should begin in loading state before async decode finishes")
        let initialBounds = attachmentBounds(
            for: attachment,
            at: 0,
            in: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, !attachment.debugHasRenderedImage {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.displayIfNeeded()
            layoutManager.ensureLayout(for: textContainer)
        }

        XCTAssertTrue(attachment.debugHasRenderedImage, "Local image should eventually decode")
        XCTAssertEqual(attachment.loadState, .ready)

        let settleDeadline = Date().addingTimeInterval(0.4)
        var finalBounds = initialBounds
        while Date() < settleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.displayIfNeeded()
            layoutManager.ensureLayout(for: textContainer)
            finalBounds = attachmentBounds(
                for: attachment,
                at: 0,
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
        }

        XCTAssertGreaterThan(
            finalBounds.height,
            initialBounds.height + 80,
            "Attachment bounds should expand after the async local image load invalidates placeholder bounds"
        )
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

    @MainActor
    private func hostInWindow(vc: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.contentViewController = vc
        window.setFrame(rect, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func attachmentBounds(
        for attachment: MarkdownImageAttachment,
        at location: Int,
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        let lineFragment = glyphRange.length > 0
            ? layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            : NSRect(origin: .zero, size: textContainer.containerSize)
        return attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFragment,
            glyphPosition: .zero,
            characterIndex: location
        )
    }
}
