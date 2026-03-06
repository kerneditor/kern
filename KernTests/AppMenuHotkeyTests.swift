import AppKit
import XCTest
@testable import KernTextKit

@MainActor
final class AppMenuHotkeyTests: XCTestCase {
    func testFileMenuProvidesExpectedSaveAsAndFileActionsShortcuts() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = submenu(named: "File", in: mainMenu) else {
            XCTFail("Missing main File menu")
            return
        }

        guard let saveAs = fileMenu.item(withTitle: "Save As…"),
              let quickOpen = fileMenu.item(withTitle: "Quick Open…"),
              let copyPath = fileMenu.item(withTitle: "Copy Full Path"),
              let openContainingFolder = fileMenu.item(withTitle: "Open Containing Folder"),
              let reveal = fileMenu.item(withTitle: "Reveal in Finder") else {
            XCTFail("Missing one or more expected File menu items")
            return
        }

        XCTAssertEqual(saveAs.keyEquivalent, "s")
        XCTAssertEqual(saveAs.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertEqual(quickOpen.keyEquivalent, "p")
        XCTAssertEqual(quickOpen.keyEquivalentModifierMask, [.command])

        XCTAssertEqual(copyPath.keyEquivalent, "c")
        XCTAssertEqual(copyPath.keyEquivalentModifierMask, [.command, .option])

        XCTAssertEqual(openContainingFolder.keyEquivalent, "r")
        XCTAssertEqual(openContainingFolder.keyEquivalentModifierMask, [.command, .shift, .option])

        XCTAssertEqual(reveal.keyEquivalent, "r")
        XCTAssertEqual(reveal.keyEquivalentModifierMask, [.command, .shift])
    }

    func testWindowMenuProvidesControlTabNavigationShortcuts() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApp.mainMenu,
              let windowMenu = submenu(named: "Window", in: mainMenu) else {
            XCTFail("Missing main Window menu")
            return
        }

        guard let nextTab = windowMenu.item(withTitle: "Select Next Tab"),
              let previousTab = windowMenu.item(withTitle: "Select Previous Tab"),
              let moveToNewWindow = windowMenu.item(withTitle: "Move Tab to New Window"),
              let closeOtherTabs = windowMenu.item(withTitle: "Close Other Tabs"),
              let firstTab = windowMenu.item(withTitle: "Select Tab 1"),
              let ninthTab = windowMenu.item(withTitle: "Select Tab 9") else {
            XCTFail("Missing tab navigation menu items")
            return
        }

        XCTAssertEqual(nextTab.keyEquivalent, "\t")
        XCTAssertEqual(nextTab.keyEquivalentModifierMask, [.control])

        XCTAssertEqual(previousTab.keyEquivalent, "\t")
        XCTAssertEqual(previousTab.keyEquivalentModifierMask, [.control, .shift])

        XCTAssertEqual(moveToNewWindow.keyEquivalent, "")

        XCTAssertEqual(closeOtherTabs.keyEquivalent, "w")
        XCTAssertEqual(closeOtherTabs.keyEquivalentModifierMask, [.command, .option])

        XCTAssertEqual(firstTab.keyEquivalent, "1")
        XCTAssertEqual(firstTab.keyEquivalentModifierMask, [.command])

        XCTAssertEqual(ninthTab.keyEquivalent, "9")
        XCTAssertEqual(ninthTab.keyEquivalentModifierMask, [.command])
    }

    func testViewMenuProvidesHeadingOutlineToggleShortcut() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApp.mainMenu,
              let viewMenu = submenu(named: "View", in: mainMenu),
              let outline = viewMenu.item(withTitle: "Show Heading Outline") else {
            XCTFail("Missing heading outline view menu item")
            return
        }

        XCTAssertEqual(outline.keyEquivalent, "0")
        XCTAssertEqual(outline.keyEquivalentModifierMask, [.command, .option])
    }

    private func submenu(named title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first(where: { $0.submenu?.title == title })?.submenu
    }
}
