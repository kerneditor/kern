import XCTest
@testable import kern_bench

final class EditorRegistryTests: XCTestCase {
    func testKernLaunchDisablesStateRestoration() throws {
        let kern = try XCTUnwrap(findEditor(named: "Kern"))
        XCTAssertEqual(kern.cleanLaunchArgs, ["-ApplePersistenceIgnoreState", "YES"])
    }
}
