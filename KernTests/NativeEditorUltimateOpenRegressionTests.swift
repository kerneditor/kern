import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorUltimateOpenRegressionTests: XCTestCase {
    @MainActor
    func testOpeningUltimateStressFixtureDoesNotHangOrExplodeLayout() throws {
        let fixtureURL = fixture(path: "test-fixtures/ultimate-stress-test.md")
        let markdown = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertGreaterThan(markdown.utf8.count, 80_000)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = fixtureURL

        let window = hostInWindow(vc: vc, size: NSSize(width: 1100, height: 760), appearance: .init(named: .darkAqua))
        let start = CFAbsoluteTimeGetCurrent()
        vc.stringValue = markdown
        window.displayIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        // Regression guard for "open appears hung".
        XCTAssertLessThan(elapsed, 12.0, "Opening/rendering ultimate fixture took too long (\(elapsed)s)")

        // Regression guard for runaway layout memory/height explosions.
        XCTAssertLessThan(textView.frame.height, 250_000, "Document view height exploded (\(textView.frame.height))")
        XCTAssertGreaterThan(textView.frame.height, 700, "Document view height unexpectedly collapsed (\(textView.frame.height))")
    }

    @MainActor
    func testLargeStagedOpenPaintsInitialViewport() throws {
        let previousForceStaged = getenv("KERN_FORCE_STAGED_OPEN").map { String(cString: $0) }
        let previousPrefixLines = getenv("KERN_STAGED_OPEN_PREFIX_LINES").map { String(cString: $0) }
        let previousPrefixChars = getenv("KERN_STAGED_OPEN_PREFIX_CHARS").map { String(cString: $0) }
        defer {
            restoreEnv("KERN_FORCE_STAGED_OPEN", previousForceStaged)
            restoreEnv("KERN_STAGED_OPEN_PREFIX_LINES", previousPrefixLines)
            restoreEnv("KERN_STAGED_OPEN_PREFIX_CHARS", previousPrefixChars)
        }

        setenv("KERN_FORCE_STAGED_OPEN", "1", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_LINES", "240", 1)
        setenv("KERN_STAGED_OPEN_PREFIX_CHARS", "48000", 1)

        var markdown = "# Large staged render smoke\n\nThe first viewport must paint text immediately.\n\n"
        for index in 0..<4_500 {
            markdown += "Paragraph \(index): staged open viewport paint regression guard with enough text to cross the large-document path.\n\n"
        }
        XCTAssertGreaterThan(markdown.utf16.count, 250_000)

        let vc = NativeEditorViewController()
        _ = vc.view
        let window = hostInWindow(vc: vc, size: NSSize(width: 980, height: 720), appearance: .init(named: .darkAqua))
        defer { window.close() }

        vc.stringValue = markdown
        window.displayIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        XCTAssertTrue(textView.string.contains("Large staged render smoke"))
        XCTAssertGreaterThan(
            textView.textContainer?.containerSize.width ?? 0,
            100,
            "Large staged open should not leave TextKit with a collapsed zero-width text container"
        )
        XCTAssertGreaterThan(
            renderedPixelSampleCount(in: textView, height: 260),
            60,
            "Large staged open populated text storage but failed to paint visible text in the initial viewport"
        )
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
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) { return found }
        }
        return nil
    }

    private func fixture(path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(path)
    }

    private func restoreEnv(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    @MainActor
    private func renderedPixelSampleCount(in textView: NSTextView, height: CGFloat) -> Int {
        let width = max(1, min(900, textView.bounds.width))
        let captureRect = NSRect(x: 0, y: 0, width: width, height: max(1, height))
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: captureRect) else {
            XCTFail("Could not allocate viewport bitmap")
            return 0
        }
        bitmap.size = captureRect.size
        textView.cacheDisplay(in: captureRect, to: bitmap)

        var paintedSamples = 0
        let step = 4
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.05 {
                    paintedSamples += 1
                }
            }
        }
        return paintedSamples
    }
}
