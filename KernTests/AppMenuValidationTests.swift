import AppKit
import XCTest
@testable import KernTextKit

@MainActor
final class AppMenuValidationTests: XCTestCase {
    func testFileDependentActionsDisabledWhenNoSavedDocumentExists() {
        closeAllDocuments()

        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let copyPathItem = NSMenuItem(title: "Copy Full Path", action: #selector(AppDelegate.copyFullPath(_:)), keyEquivalent: "")
        let openContainingFolderItem = NSMenuItem(title: "Open Containing Folder", action: #selector(AppDelegate.openContainingFolder(_:)), keyEquivalent: "")
        let revealInFinderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(AppDelegate.revealInFinder(_:)), keyEquivalent: "")

        XCTAssertFalse(appDelegate.validateMenuItem(copyPathItem))
        XCTAssertFalse(appDelegate.validateMenuItem(openContainingFolderItem))
        XCTAssertFalse(appDelegate.validateMenuItem(revealInFinderItem))
    }

    func testHeadingOutlineMenuItemReflectsVisibilityState() throws {
        closeAllDocuments()
        let defaults = UserDefaults.standard
        let key = "nativeEditor.headingOutlineVisible"
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let doc = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        defer { doc.close() }

        let item = NSMenuItem(title: "Show Heading Outline", action: #selector(AppDelegate.toggleHeadingOutline(_:)), keyEquivalent: "")
        let valid = appDelegate.validateMenuItem(item)
        XCTAssertTrue(valid)
        XCTAssertEqual(item.state, .on)
    }

    func testTabManagementActionsDisabledWithoutTabbedWindow() {
        closeAllDocuments()

        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let moveTab = NSMenuItem(title: "Move Tab to New Window", action: #selector(AppDelegate.moveCurrentTabToNewWindow(_:)), keyEquivalent: "")
        let closeOtherTabs = NSMenuItem(title: "Close Other Tabs", action: #selector(AppDelegate.closeOtherTabs(_:)), keyEquivalent: "")

        XCTAssertFalse(appDelegate.validateMenuItem(moveTab))
        XCTAssertFalse(appDelegate.validateMenuItem(closeOtherTabs))
    }

    private func closeAllDocuments() {
        for doc in NSDocumentController.shared.documents {
            doc.close()
        }
    }
}
