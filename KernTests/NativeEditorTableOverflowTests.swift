import XCTest
@testable import KernTextKit

@MainActor
final class NativeEditorTableOverflowTests: XCTestCase {
    func testHorizontalOverflowModeDoesNotEnableDocumentWideScrollForWideTable() {
        let defaults = UserDefaults.standard
        let key = NativeEditorAppearance.tableOverflowModeKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorTableOverflowMode.horizontal.rawValue, forKey: key)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        | Feature | Column 1 | Column 2 | Column 3 | Column 4 | Column 5 | Column 6 |
        | --- | --- | --- | --- | --- | --- | --- |
        | Very long content that should trigger a wider table viewport for horizontal scrolling behavior in the editor. | A | B | C | D | E | F |
        """

        XCTAssertFalse(vc.isHorizontalTableOverflowActiveForTesting())
    }

    func testHorizontalOverflowModeIgnoresPipesInsideFencedCodeBlocks() {
        let defaults = UserDefaults.standard
        let key = NativeEditorAppearance.tableOverflowModeKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorTableOverflowMode.horizontal.rawValue, forKey: key)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        ```bash
        echo "a | b | c | d | e | f | g"
        printf '| not | a | table | row |\n'
        ```
        """

        XCTAssertFalse(vc.isHorizontalTableOverflowActiveForTesting())
    }

    func testWrapModeKeepsViewportWidthEvenForWideTables() {
        let defaults = UserDefaults.standard
        let key = NativeEditorAppearance.tableOverflowModeKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
        }

        defaults.set(NativeEditorTableOverflowMode.wrap.rawValue, forKey: key)

        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        | Feature | Column 1 | Column 2 | Column 3 | Column 4 | Column 5 | Column 6 |
        | --- | --- | --- | --- | --- | --- | --- |
        | Very long content that should stay wrapped when wrap mode is selected. | A | B | C | D | E | F |
        """

        XCTAssertFalse(vc.isHorizontalTableOverflowActiveForTesting())
    }
}
