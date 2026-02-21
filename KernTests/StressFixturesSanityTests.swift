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
        XCTAssertTrue(md.contains("](#task-permutations-matrix)"))

        // Inline formatting (GFM)
        XCTAssertTrue(md.contains("**bold text**"))
        XCTAssertTrue(md.contains("*italic text*"))
        XCTAssertTrue(md.contains("~~strikethrough text~~"))
        XCTAssertTrue(md.contains("`inline code`"))
        XCTAssertTrue(md.contains("[link to GitHub]("))

        // Images: local + remote.
        XCTAssertTrue(md.contains("![Local sample](screenshots/01-default-sample.png)"))
        XCTAssertTrue(md.contains("https://upload.wikimedia.org/"))

        // Verify referenced local images exist.
        let localImage = fixtureURL(path: "test-fixtures/screenshots/01-default-sample.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localImage.path), "Missing local image: \(localImage.path)")

        // Lists (nested) and tasks.
        XCTAssertTrue(md.contains("- Simple item"))
        XCTAssertTrue(md.contains("  - Nested level 1"))
        XCTAssertTrue(md.contains("    - Nested level 2"))
        XCTAssertTrue(md.contains("- [x] This checked item SHOULD be struck through"))
        XCTAssertTrue(md.contains("- [ ] This unchecked item should NOT be struck through"))

        // Task permutations matrix (markers + ordered + standalone shortcuts).
        XCTAssertTrue(md.contains("## Task Permutations Matrix"))
        XCTAssertTrue(md.contains("- [ ] dash unchecked"))
        XCTAssertTrue(md.contains("star checked"))
        XCTAssertTrue(md.contains("plus unchecked"))
        XCTAssertTrue(md.contains("1. [ ] ordered unchecked"))
        XCTAssertTrue(md.contains("[ ] standalone shortcut unchecked"))
        XCTAssertTrue(md.contains("- [ ] task bullet (bullet + checkbox)"))

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
        XCTAssertTrue(
            containsAny(
                md,
                candidates: [
                    "\\int_{-\\infty}^{\\infty}",
                    "int_{-infty}^{infty}",
                ]
            )
        )

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
        XCTAssertTrue(md.contains("## Table of Contents"))
        XCTAssertTrue(md.contains("## Section 8: Deep Nesting"))
        XCTAssertTrue(md.contains("## Section 9: Links and Images"))
        XCTAssertTrue(md.contains("## Section 10: Edge Cases"))
        XCTAssertTrue(md.contains("## Section 12: Permutation Core (Embedded Ultimate Fixture)"))
        XCTAssertTrue(md.contains("<!-- BEGIN PERMUTATION APPENDIX -->"))
        XCTAssertTrue(md.contains("<!-- END PERMUTATION APPENDIX -->"))
        XCTAssertTrue(md.contains("## Action Permutation Seeds"))
        XCTAssertTrue(md.contains("```mermaid"))
        XCTAssertTrue(md.contains("$$"))
        XCTAssertTrue(md.contains("![Local sample](screenshots/01-default-sample.png)"))
        XCTAssertTrue(md.contains("Visit <https://example.com>"))

        let actionSeedCount = md.components(separatedBy: "ACTION-SEED-").count - 1
        XCTAssertGreaterThanOrEqual(actionSeedCount, 200, "Expected mega fixture to include 200+ ACTION-SEED entries")

        // Mega fixture should also include the language matrix from the embedded permutation core.
        for languageFence in expectedLanguageFences() {
            XCTAssertTrue(md.contains(languageFence), "Missing language fence in mega fixture: \(languageFence)")
        }
    }

    func testUltimateStressFixtureContainsPermutationDenseCoverage() throws {
        let md = try loadFixture(name: "ultimate-stress-test.md")

        let lineCount = md.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThanOrEqual(lineCount, 1200, "ultimate-stress-test.md should stay permutation-dense (>=1200 lines)")

        // Canonical permutation-heavy sections.
        XCTAssertTrue(md.contains("## Heading Matrix"))
        XCTAssertTrue(md.contains("## List And Task Matrix"))
        XCTAssertTrue(md.contains("## Inline Formatting Matrix"))
        XCTAssertTrue(md.contains("## Code Fence Language Matrix"))
        XCTAssertTrue(md.contains("## Table Matrix"))
        XCTAssertTrue(md.contains("## Blockquote And Rule Matrix"))
        XCTAssertTrue(md.contains("## Math Matrix"))
        XCTAssertTrue(md.contains("## Image Matrix"))
        XCTAssertTrue(md.contains("## Mermaid Matrix"))
        XCTAssertTrue(md.contains("## Action Permutation Seeds"))
        XCTAssertTrue(md.contains("## Typing Volume Tail"))

        // Language matrix sanity.
        for languageFence in expectedLanguageFences() {
            XCTAssertTrue(md.contains(languageFence), "Missing language fence in ultimate fixture: \(languageFence)")
        }

        // Action seed density (used by typing/action permutation tests).
        let actionSeedCount = md.components(separatedBy: "ACTION-SEED-").count - 1
        XCTAssertGreaterThanOrEqual(actionSeedCount, 200, "Expected 200+ ACTION-SEED entries")

        // Core rich blocks.
        XCTAssertTrue(md.contains("```mermaid"))
        XCTAssertTrue(md.contains("$$"))
        XCTAssertTrue(md.contains("![Local sample](screenshots/01-default-sample.png)"))
        XCTAssertTrue(md.contains("\n---\n"))
    }

    func testBenchmarkFixtureIsFeatureDenseAndLargeEnough() throws {
        let md = try loadFixture(name: "native-editor-benchmark.md")

        // Size: should be ~3.5MB+, feature-dense (not filler).
        let byteCount = md.utf8.count
        XCTAssertGreaterThanOrEqual(byteCount, 3_000_000, "Benchmark fixture should be >=3MB (got \(byteCount))")

        // Key sections.
        XCTAssertTrue(md.contains("## Table of Contents"))
        XCTAssertTrue(md.contains("## Heading Hierarchy"))
        XCTAssertTrue(md.contains("## Inline Formatting Blocks"))
        XCTAssertTrue(md.contains("## Bullet Lists"))
        XCTAssertTrue(md.contains("## Ordered Lists"))
        XCTAssertTrue(md.contains("## Task Lists"))
        XCTAssertTrue(md.contains("## Mixed Nested Lists"))
        XCTAssertTrue(md.contains("## Code Fence Matrix"))
        XCTAssertTrue(md.contains("## Table Matrix"))
        XCTAssertTrue(md.contains("## Math Blocks"))
        XCTAssertTrue(md.contains("## Blockquote Matrix"))
        XCTAssertTrue(md.contains("## Horizontal Rules"))
        XCTAssertTrue(md.contains("## Image References"))
        XCTAssertTrue(md.contains("## Mermaid Diagrams"))
        XCTAssertTrue(md.contains("## Heading Checkboxes"))
        XCTAssertTrue(md.contains("## Link Variants"))
        XCTAssertTrue(md.contains("## Dense Paragraph Blocks"))

        // Inline formatting presence.
        XCTAssertTrue(md.contains("**bold text**"))
        XCTAssertTrue(md.contains("*italic text*"))
        XCTAssertTrue(md.contains("~~strikethrough text~~"))
        XCTAssertTrue(md.contains("`inline code`"))
        XCTAssertTrue(md.contains("***bold italic"))

        // Lists and tasks.
        XCTAssertTrue(md.contains("- [x]"))
        XCTAssertTrue(md.contains("- [ ]"))
        XCTAssertTrue(md.contains("1. [x]"))
        XCTAssertTrue(md.contains("1. [ ]"))

        // Code fences (all expected languages).
        for languageFence in expectedLanguageFences() {
            XCTAssertTrue(md.contains(languageFence), "Missing language fence in benchmark: \(languageFence)")
        }

        // Tables.
        XCTAssertTrue(md.contains("| --- |"))

        // Math.
        XCTAssertTrue(md.contains("$E = mc^2$"))
        XCTAssertTrue(md.contains("$$"))

        // Blockquotes + rules.
        XCTAssertTrue(md.contains("> Quote"))
        XCTAssertTrue(md.contains("\n---\n"))
        XCTAssertTrue(md.contains("\n***\n"))
        XCTAssertTrue(md.contains("\n___\n"))

        // Images (local only — no remote URLs).
        XCTAssertTrue(md.contains("![Local sample"))
        XCTAssertTrue(md.contains("screenshots/01-default-sample.png"))

        // Mermaid.
        XCTAssertTrue(md.contains("```mermaid"))
        XCTAssertTrue(md.contains("flowchart TD"))
        XCTAssertTrue(md.contains("sequenceDiagram"))

        // Heading checkboxes.
        XCTAssertTrue(md.contains("# [ ] Unchecked"))
        XCTAssertTrue(md.contains("# [x] Checked"))

        // Autolinks.
        XCTAssertTrue(md.contains("<https://example.com/auto/"))

        // No filler: should not contain lorem ipsum.
        XCTAssertFalse(md.lowercased().contains("lorem ipsum"), "Benchmark fixture should not contain filler text")
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

    private func containsAny(_ haystack: String, candidates: [String]) -> Bool {
        candidates.contains(where: { haystack.contains($0) })
    }

    private func expectedLanguageFences() -> [String] {
        [
            "```javascript",
            "```typescript",
            "```python",
            "```rust",
            "```go",
            "```swift",
            "```kotlin",
            "```ruby",
            "```java",
            "```c",
            "```cpp",
            "```bash",
            "```zsh",
            "```powershell",
            "```sql",
            "```json",
            "```yaml",
            "```toml",
            "```html",
            "```css",
            "```xml",
            "```dockerfile",
            "```lua",
            "```php",
        ]
    }
}
