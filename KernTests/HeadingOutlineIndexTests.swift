import XCTest
@testable import KernTextKit

final class HeadingOutlineIndexTests: XCTestCase {
    @MainActor
    func testHeadingOutlineIndexIncludesLevelsAndDeduplicatedSlugs() {
        let markdown = """
        # Intro
        ## Same
        ### Same
        ## Same
        """

        let attr = NativeMarkdownCodec.importMarkdown(markdown)
        let entries = HeadingOutlineIndex.make(from: attr)

        XCTAssertEqual(entries.map(\.title), ["Intro", "Same", "Same", "Same"])
        XCTAssertEqual(entries.map(\.level), [1, 2, 3, 2])
        XCTAssertEqual(entries.map(\.slug), ["intro", "same", "same-1", "same-2"])
        XCTAssertEqual(Set(entries.map(\.slug)).count, entries.count)
    }

    @MainActor
    func testHeadingAnchorIndexMatchesOutlineLocations() {
        let markdown = """
        # Alpha

        ## Beta

        ## Beta
        """

        let attr = NativeMarkdownCodec.importMarkdown(markdown)
        let outline = HeadingOutlineIndex.make(from: attr)
        let anchors = HeadingAnchorIndex.make(from: attr)

        XCTAssertEqual(anchors["alpha"], outline.first(where: { $0.slug == "alpha" })?.paragraphLocation)
        XCTAssertEqual(anchors["beta"], outline.first(where: { $0.slug == "beta" })?.paragraphLocation)
        XCTAssertEqual(anchors["beta-1"], outline.first(where: { $0.slug == "beta-1" })?.paragraphLocation)
    }
}
