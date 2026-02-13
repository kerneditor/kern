import AppKit
import XCTest
@testable import KernTextKit

final class NativeFindEngineTests: XCTestCase {
    func testAllMatches_EmptyQuery_ReturnsEmpty() {
        XCTAssertEqual(NativeFindEngine.allMatches(in: "abc", query: ""), [])
    }

    func testAllMatches_CaseInsensitive_FindsAll() {
        let matches = NativeFindEngine.allMatches(in: "Alpha alpha ALPHA", query: "alpha")
        XCTAssertEqual(matches.count, 3)
    }

    func testAllMatches_DiacriticInsensitive_MatchesAccents() {
        let matches = NativeFindEngine.allMatches(in: "Cafe Café CAFÉ", query: "cafe")
        XCTAssertEqual(matches.count, 3)
    }

    func testAllMatches_NonOverlappingBehavior_IsDocumented() {
        // Non-overlapping scan: "ana" occurs twice in "banana" if overlaps are allowed,
        // but typical editor find uses non-overlapping matches.
        let matches = NativeFindEngine.allMatches(in: "banana", query: "ana")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.location, 1)
    }

    func testReplace_InheritsAttributesAtMatchStart() {
        let font = NSFont.systemFont(ofSize: 16, weight: .bold)
        let storage = NSMutableAttributedString(string: "hello world", attributes: [
            .font: font,
        ])

        let match = NativeFindEngine.allMatches(in: storage.string, query: "world").first!
        NativeFindEngine.replace(in: storage, range: match, replacement: "Kern")

        XCTAssertEqual(storage.string, "hello Kern")
        let attrs = storage.attributes(at: "hello ".count, effectiveRange: nil)
        XCTAssertEqual(attrs[.font] as? NSFont, font)
    }
}

