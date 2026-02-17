import AppKit
import XCTest
@testable import KernTextKit

final class AnchorNavigationScrollTests: XCTestCase {
    @MainActor
    func testAnchorNavigationScrollsTargetNearTop_WhenTargetIsFar() {
        let vc = NativeEditorViewController()
        _ = vc.view

        vc.stringValue = """
        # Doc

        ## Table of Contents

        - [Jump](#target)

        \(fillerLines(count: 120))

        ## Target

        Hello
        """

        let window = hostInWindow(vc: vc, size: NSSize(width: 700, height: 420), appearance: .init(named: .aqua))
        window.displayIfNeeded()

        guard let editorTextView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        let targetLoc = (editorTextView.string as NSString).range(of: "Target").location
        XCTAssertNotEqual(targetLoc, NSNotFound)

        let linkLoc = (editorTextView.string as NSString).range(of: "Jump").location
        XCTAssertNotEqual(linkLoc, NSNotFound)

        XCTAssertTrue(vc.textView(editorTextView, clickedOnLink: URL(string: "#target")!, at: linkLoc))
        XCTAssertTrue(waitUntil(timeout: 1.0) { editorTextView.selectedRange().location == targetLoc })

        let landedNearTop = waitUntil(timeout: 1.0) {
            guard let (targetRect, _) = rectForParagraph(containing: "Target", in: editorTextView) else {
                return false
            }
            let visible = editorTextView.visibleRect
            guard visible.intersects(targetRect) else { return false }
            let dist = distanceFromTop(targetRect: targetRect, visible: visible, isFlipped: editorTextView.isFlipped)
            return dist < visible.height * 0.35
        }
        XCTAssertTrue(landedNearTop, "Target should land near the top of the viewport")
    }

    @MainActor
    func testAnchorNavigationScrollsEvenWhenTargetAlreadyVisible() {
        let vc = NativeEditorViewController()
        _ = vc.view

        vc.stringValue = """
        # Doc

        ## Table of Contents

        - [Jump](#target)

        \(fillerLines(count: 80))

        ## Target

        Hello
        """

        let window = hostInWindow(vc: vc, size: NSSize(width: 700, height: 420), appearance: .init(named: .aqua))
        window.displayIfNeeded()

        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }
        guard let editorTextView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        guard let (targetRect, _) = rectForParagraph(containing: "Target", in: editorTextView) else {
            XCTFail("Missing target rect")
            return
        }

        // Pre-scroll so the target is already visible, but not near the top.
        let clip = scrollView.contentView
        let viewportH = clip.bounds.height
        var origin = clip.bounds.origin
        origin.x = 0
        if editorTextView.isFlipped {
            origin.y = max(0, targetRect.minY - (viewportH * 0.55))
        } else {
            origin.y = max(0, targetRect.maxY + (viewportH * 0.55) - viewportH)
        }
        let maxY = max(0, editorTextView.bounds.height - viewportH)
        origin.y = min(origin.y, maxY)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)

        let beforeDist = distanceFromTop(targetRect: targetRect, visible: editorTextView.visibleRect, isFlipped: editorTextView.isFlipped)

        let targetLoc = (editorTextView.string as NSString).range(of: "Target").location
        XCTAssertNotEqual(targetLoc, NSNotFound)

        let linkLoc = (editorTextView.string as NSString).range(of: "Jump").location
        XCTAssertNotEqual(linkLoc, NSNotFound)

        XCTAssertTrue(vc.textView(editorTextView, clickedOnLink: URL(string: "#target")!, at: linkLoc))
        XCTAssertTrue(waitUntil(timeout: 1.0) { editorTextView.selectedRange().location == targetLoc })

        let landedNearTop = waitUntil(timeout: 1.0) {
            let afterVisible = editorTextView.visibleRect
            guard afterVisible.intersects(targetRect) else { return false }
            let afterDist = distanceFromTop(targetRect: targetRect, visible: afterVisible, isFlipped: editorTextView.isFlipped)
            return afterDist < afterVisible.height * 0.35
        }

        let afterVisible = editorTextView.visibleRect
        let afterDist = distanceFromTop(targetRect: targetRect, visible: afterVisible, isFlipped: editorTextView.isFlipped)
        XCTAssertTrue(afterVisible.intersects(targetRect))
        XCTAssertTrue(landedNearTop, "Target should land near the top of the viewport")
        XCTAssertGreaterThan(beforeDist, afterDist, "Jump should move the target closer to the top even if it was already visible")
    }

    @MainActor
    func testAnchorJumpGuardRejumpsIfViewportSnapsBackToTOC() {
        let vc = NativeEditorViewController()
        _ = vc.view

        vc.stringValue = """
        # Doc

        ## Table of Contents

        - [Jump](#target)

        \(fillerLines(count: 120))

        ## Target

        Hello
        """

        let window = hostInWindow(vc: vc, size: NSSize(width: 700, height: 420), appearance: .init(named: .aqua))
        window.displayIfNeeded()

        guard let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: vc.view) as? NSScrollView else {
            XCTFail("Missing NativeEditor.ScrollView")
            return
        }
        guard let editorTextView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        let ns = editorTextView.string as NSString
        let linkLoc = ns.range(of: "Jump").location
        XCTAssertNotEqual(linkLoc, NSNotFound)
        let targetLoc = ns.range(of: "Target").location
        XCTAssertNotEqual(targetLoc, NSNotFound)

        XCTAssertTrue(vc.textView(editorTextView, clickedOnLink: URL(string: "#target")!, at: linkLoc))
        XCTAssertTrue(waitUntil(timeout: 1.0) { editorTextView.selectedRange().location == targetLoc })

        guard let (targetRect, _) = rectForParagraph(containing: "Target", in: editorTextView) else {
            XCTFail("Missing target rect")
            return
        }
        XCTAssertTrue(editorTextView.visibleRect.intersects(targetRect), "Target should be visible after initial jump")

        // Simulate a viewport snap-back to the TOC (selection remains at the target).
        let clip = scrollView.contentView
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)

        // Guard should re-apply the jump shortly after the scroll event.
        XCTAssertTrue(waitUntil(timeout: 1.0) { editorTextView.visibleRect.intersects(targetRect) })
    }

    // MARK: - Helpers

    private func fillerLines(count: Int) -> String {
        (0..<count).map { "Paragraph \($0). Lorem ipsum dolor sit amet." }.joined(separator: "\n\n")
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

    @MainActor
    private func rectForParagraph(containing needle: String, in textView: NSTextView) -> (NSRect, NSRange)? {
        guard let storage = textView.textStorage else { return nil }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }

        let ns = storage.string as NSString
        let loc = ns.range(of: needle).location
        guard loc != NSNotFound else { return nil }
        let paraRange = ns.paragraphRange(for: NSRange(location: loc, length: 0))

        let glyphRange = lm.glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return (rect, paraRange)
    }

    private func distanceFromTop(targetRect: NSRect, visible: NSRect, isFlipped: Bool) -> CGFloat {
        if isFlipped {
            return targetRect.minY - visible.minY
        }
        return visible.maxY - targetRect.maxY
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
