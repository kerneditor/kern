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
              let copyPath = fileMenu.item(withTitle: "Copy Full Path"),
              let reveal = fileMenu.item(withTitle: "Reveal in Finder") else {
            XCTFail("Missing one or more expected File menu items")
            return
        }

        XCTAssertEqual(saveAs.keyEquivalent, "s")
        XCTAssertEqual(saveAs.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertEqual(copyPath.keyEquivalent, "c")
        XCTAssertEqual(copyPath.keyEquivalentModifierMask, [.command, .option])

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
              let previousTab = windowMenu.item(withTitle: "Select Previous Tab") else {
            XCTFail("Missing tab navigation menu items")
            return
        }

        XCTAssertEqual(nextTab.keyEquivalent, "\t")
        XCTAssertEqual(nextTab.keyEquivalentModifierMask, [.control])

        XCTAssertEqual(previousTab.keyEquivalent, "\t")
        XCTAssertEqual(previousTab.keyEquivalentModifierMask, [.control, .shift])
    }

    private func submenu(named title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first(where: { $0.submenu?.title == title })?.submenu
    }
}
