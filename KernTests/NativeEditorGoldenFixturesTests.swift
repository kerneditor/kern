import Foundation
import XCTest
@testable import KernTextKit

final class NativeEditorGoldenFixturesTests: XCTestCase {
    private struct FixtureCaseFile: Codable {
        struct OptionsDTO: Codable {
            var exportDialect: String?
            var gfmExtensionExportStrategy: String?
            var taskRendering: String?
            var orderedTasksEnabled: Bool?
            var headingCheckboxesEnabled: Bool?
            var orderedListNumbering: String?

            func toOptions() -> NativeMarkdownCodec.Options {
                var opt = NativeMarkdownCodec.Options()
                if let exportDialect, let v = NativeMarkdownCodec.Options.ExportDialect(rawValue: exportDialect) {
                    opt.exportDialect = v
                }
                if let gfmExtensionExportStrategy,
                   let v = NativeMarkdownCodec.Options.GfmExtensionExportStrategy(rawValue: gfmExtensionExportStrategy) {
                    opt.gfmExtensionExportStrategy = v
                } else if gfmExtensionExportStrategy == "degrade" {
                    // Back-compat: the previous name for `.portable`.
                    opt.gfmExtensionExportStrategy = .portable
                }
                if let taskRendering, let v = NativeMarkdownCodec.Options.TaskRendering(rawValue: taskRendering) {
                    opt.taskRendering = v
                }
                if let orderedTasksEnabled { opt.orderedTasksEnabled = orderedTasksEnabled }
                if let headingCheckboxesEnabled { opt.headingCheckboxesEnabled = headingCheckboxesEnabled }
                if let orderedListNumbering,
                   let v = NativeMarkdownCodec.Options.OrderedListNumbering(rawValue: orderedListNumbering) {
                    opt.orderedListNumbering = v
                }
                return opt
            }
        }

        var name: String
        var expected: String
        var options: OptionsDTO
    }

    private struct ResolvedCase {
        var name: String
        var expectedURL: URL
        var options: NativeMarkdownCodec.Options
    }

    @MainActor
    func testGoldenFixturesRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root

        let fixturesDir = root.appendingPathComponent("test-fixtures/native-editor-golden", isDirectory: true)
        let all = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".in.md") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(all.isEmpty, "No golden fixtures found in \(fixturesDir.path)")

        for inputURL in all {
            let name = inputURL.lastPathComponent
            let base = inputURL.deletingPathExtension().deletingPathExtension() // strip .in.md
            let resolvedCases = try loadCases(baseURL: base)

            try XCTContext.runActivity(named: "Golden: \(name)") { _ in
                let input = try String(contentsOf: inputURL, encoding: .utf8)
                XCTAssertFalse(resolvedCases.isEmpty, "No cases found for fixture: \(name)")

                for c in resolvedCases {
                    try XCTContext.runActivity(named: "Case: \(c.name)") { _ in
                        let attr = NativeMarkdownCodec.importMarkdown(input, options: c.options)
                        let out = NativeMarkdownCodec.exportMarkdown(attr, options: c.options)
                        let expected = try String(contentsOf: c.expectedURL, encoding: .utf8)
                        assertNormalizedEqual(
                            actual: out,
                            expected: expected,
                            message: "Mismatch for fixture: \(name)\nCase: \(c.name)\nExpected: \(c.expectedURL.path)"
                        )
                    }
                }
            }
        }
    }

    private func normalize(_ s: String) -> String {
        // Keep internal blank lines, but normalize line endings and trailing whitespace so golden tests
        // aren't brittle across editors.
        let lf = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = lf.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.map { $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression) }
        return trimmed.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private func loadCases(baseURL: URL) throws -> [ResolvedCase] {
        // Back-compat: if legacy `*.gfm.out.md` and/or `*.kern.out.md` exist, treat them as cases.
        var cases: [ResolvedCase] = []

        let legacyGfm = baseURL.appendingPathExtension("gfm.out.md")
        if FileManager.default.fileExists(atPath: legacyGfm.path) {
            var opt = NativeMarkdownCodec.Options()
            opt.exportDialect = .gfm
            cases.append(.init(name: "legacy.gfm", expectedURL: legacyGfm, options: opt))
        }

        let legacyKern = baseURL.appendingPathExtension("kern.out.md")
        if FileManager.default.fileExists(atPath: legacyKern.path) {
            var opt = NativeMarkdownCodec.Options()
            opt.exportDialect = .kern
            cases.append(.init(name: "legacy.kern", expectedURL: legacyKern, options: opt))
        }

        // Extended cases: `*.case.json` files with explicit options + expected output.
        let dir = baseURL.deletingLastPathComponent()
        let baseName = baseURL.lastPathComponent
        let all = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let caseFiles = all
            .filter { $0.lastPathComponent.hasPrefix(baseName + ".") && $0.lastPathComponent.hasSuffix(".case.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        for url in caseFiles {
            let data = try Data(contentsOf: url)
            let parsed = try decoder.decode(FixtureCaseFile.self, from: data)
            let expectedURL = dir.appendingPathComponent(parsed.expected)
            cases.append(.init(name: parsed.name, expectedURL: expectedURL, options: parsed.options.toOptions()))
        }

        return cases
    }

    private func assertNormalizedEqual(actual: String, expected: String, message: String) {
        let nActual = normalize(actual)
        let nExpected = normalize(expected)
        guard nActual != nExpected else { return }
        let diffSummary = firstDiffSummary(actual: nActual, expected: nExpected)

        // Attach actual output for debugging.
        let actualAttachment = XCTAttachment(string: nActual)
        actualAttachment.name = "actual.md"
        actualAttachment.lifetime = .keepAlways
        add(actualAttachment)

        let expectedAttachment = XCTAttachment(string: nExpected)
        expectedAttachment.name = "expected.md"
        expectedAttachment.lifetime = .keepAlways
        add(expectedAttachment)

        let diffAttachment = XCTAttachment(string: diffSummary)
        diffAttachment.name = "diff.txt"
        diffAttachment.lifetime = .keepAlways
        add(diffAttachment)

        XCTFail("\(message)\n\(diffSummary)")
    }

    private func firstDiffSummary(actual: String, expected: String) -> String {
        let aLines = actual.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let eLines = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let maxN = max(aLines.count, eLines.count)
        for i in 0..<maxN {
            let a = i < aLines.count ? aLines[i] : "<EOF>"
            let e = i < eLines.count ? eLines[i] : "<EOF>"
            if a != e {
                return """
                First differing line: \(i + 1)
                expected: \(e)
                actual:   \(a)
                """
            }
        }
        return "No line diff found (content differs but lines are identical?)"
    }
}
