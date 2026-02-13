import Foundation
import XCTest

/// Sanity checks for the committed stress/mega fixtures.
///
/// These are intentionally fast and always-on:
/// - Ensure the fixtures include the expected feature sections (so they remain useful as "ultimate" docs)
/// - Ensure any referenced local assets exist in-repo
final class StressFixturesSanityTests: XCTestCase {
    func testStressTestFixtureContainsAllKeySectionsAndLocalAssetsExist() throws {
        let md = try loadFixture(name: "stress-test.md")

        // Table of contents and anchors (used to test in-document links).
        XCTAssertTrue(md.contains("## Table of Contents"))
        XCTAssertTrue(md.contains("](#heading-hierarchy)"))
        XCTAssertTrue(md.contains("](#mermaid-diagrams)"))

        // Inline formatting (GFM)
        XCTAssertTrue(md.contains("**bold text**"))
        XCTAssertTrue(md.contains("*italic text*"))
        XCTAssertTrue(md.contains("~~strikethrough text~~"))
        XCTAssertTrue(md.contains("`inline code`"))
        XCTAssertTrue(md.contains("[link to GitHub]("))

        // Images: local + remote.
        XCTAssertTrue(md.contains("![Local sample](screenshots/01-default-sample.png)"))
        XCTAssertTrue(md.contains("https://placehold.co/"))

        // Verify referenced local images exist.
        let localImage = fixtureURL(path: "test-fixtures/screenshots/01-default-sample.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localImage.path), "Missing local image: \(localImage.path)")

        // Lists (nested) and tasks.
        XCTAssertTrue(md.contains("* Simple item"))
        XCTAssertTrue(md.contains("  * Nested level 1"))
        XCTAssertTrue(md.contains("    * Nested level 2"))
        XCTAssertTrue(md.contains("* [x]"))
        XCTAssertTrue(md.contains("* [ ]"))

        // Kern extensions (heading checkboxes).
        XCTAssertTrue(md.contains("## [x] Checked H2"))
        XCTAssertTrue(md.contains("## [ ] Unchecked H2"))

        // Code fences (multiple languages).
        XCTAssertTrue(md.contains("```javascript"))
        XCTAssertTrue(md.contains("console.log(`Hello, ${name}!`);"))
        XCTAssertTrue(md.contains("```python"))
        XCTAssertTrue(md.contains("```typescript"))

        // Tables (pipe syntax in source).
        XCTAssertTrue(md.contains("| Feature | Status |"))
        XCTAssertTrue(md.contains("| --- | --- |"))

        // Math + block math.
        XCTAssertTrue(md.contains("$E = mc^2$"))
        XCTAssertTrue(md.contains("$$"))
        XCTAssertTrue(md.contains("\\int_{-\\infty}^{\\infty}"))

        // Blockquotes + thematic breaks.
        XCTAssertTrue(md.contains("> \"The best way to predict the future is to invent it.\""))
        XCTAssertTrue(md.contains("\n---\n"))
        XCTAssertTrue(md.contains("\n***\n"))
        XCTAssertTrue(md.contains("\n___\n"))

        // Mermaid.
        XCTAssertTrue(md.contains("```mermaid"))
        XCTAssertTrue(md.contains("flowchart TD"))
    }

    func testMegaStressTestFixtureIsLargeAndContainsKeyEdgeSections() throws {
        let md = try loadFixture(name: "mega-stress-test.md")

        // Size guard: this fixture is expected to be extremely large.
        let lineCount = md.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThanOrEqual(lineCount, 5000, "mega-stress-test.md should be 5000+ lines (got \(lineCount))")

        // Ensure it includes the critical sections we rely on for perf + edge cases.
        XCTAssertTrue(md.contains("## Section 8: Deep Nesting"))
        XCTAssertTrue(md.contains("## Section 9: Links and Images"))
        XCTAssertTrue(md.contains("## Section 10: Edge Cases"))
        XCTAssertTrue(md.contains("```mermaid"))
        XCTAssertTrue(md.contains("$$"))
        XCTAssertTrue(md.contains("Visit <https://example.com>"))
    }

    // MARK: - Helpers

    private func loadFixture(name: String) throws -> String {
        let url = fixtureURL(path: "test-fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureURL(path: String) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        return root.appendingPathComponent(path)
    }
}
