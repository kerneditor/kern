import Foundation
import XCTest
@testable import KernTextKit

/// Property-style tests: for a given option set, exported Markdown should be stable under
/// repeated import/export (idempotent). This catches subtle state loss bugs without requiring
/// hand-authored golden outputs for every option permutation.
final class NativeMarkdownCodecIdempotencyTests: XCTestCase {
    @MainActor
    func testExportIsIdempotentAcrossOptionPermutations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root

        let fixturesDir = root.appendingPathComponent("test-fixtures/native-editor-golden", isDirectory: true)
        let inputs = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".in.md") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(inputs.isEmpty, "No fixtures found in \(fixturesDir.path)")

        let optionsList = TestGates.exhaustive ? allOptionPermutations() : baselineOptionPermutations()

        for inputURL in inputs {
            let inputName = inputURL.lastPathComponent
            let input = try String(contentsOf: inputURL, encoding: .utf8)

            try XCTContext.runActivity(named: "Idempotent: \(inputName)") { _ in
                for opt in optionsList {
                    let optName = describe(opt)
                    try XCTContext.runActivity(named: "Options: \(optName)") { _ in
                        let out1 = roundTrip(input: input, options: opt)
                        let out2 = roundTrip(input: out1, options: opt)

                        let n1 = normalize(out1)
                        let n2 = normalize(out2)

                        if n1 != n2 {
                            let a1 = XCTAttachment(string: n1)
                            a1.name = "export-1.md"
                            a1.lifetime = .keepAlways
                            add(a1)

                            let a2 = XCTAttachment(string: n2)
                            a2.name = "export-2.md"
                            a2.lifetime = .keepAlways
                            add(a2)

                            let diff = XCTAttachment(string: firstDiffSummary(actual: n2, expected: n1))
                            diff.name = "diff.txt"
                            diff.lifetime = .keepAlways
                            add(diff)

                            XCTFail(
                                """
                                Export is not idempotent for fixture=\(inputName) options=\(optName)
                                \(firstDiffSummary(actual: n2, expected: n1))
                                --- export-1 ---
                                \(n1)
                                --- export-2 ---
                                \(n2)
                                """
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Round-trip

    @MainActor
    private func roundTrip(input: String, options: NativeMarkdownCodec.Options) -> String {
        let attr = NativeMarkdownCodec.importMarkdown(input, options: options)
        return NativeMarkdownCodec.exportMarkdown(attr, options: options)
    }

    // MARK: - Options

    private func baselineOptionPermutations() -> [NativeMarkdownCodec.Options] {
        // Fast default set: covers the "main" behavioral branches without exploding runtime.
        var list: [NativeMarkdownCodec.Options] = []

        // Default: GFM, preserve extensions, GitHub-like task rendering, no extensions enabled.
        list.append(.init())

        // Kern dialect (preserve standalone task syntax).
        var kern = NativeMarkdownCodec.Options()
        kern.exportDialect = .kern
        kern.taskRendering = .kern
        kern.orderedTasksEnabled = true
        kern.headingCheckboxesEnabled = true
        kern.orderedListNumbering = .preserveTyped
        list.append(kern)

        // GFM portable + extensions enabled (degrade).
        var portable = NativeMarkdownCodec.Options()
        portable.exportDialect = .gfm
        portable.gfmExtensionExportStrategy = .portable
        portable.orderedTasksEnabled = true
        portable.headingCheckboxesEnabled = true
        list.append(portable)

        // GFM lint + heading checkboxes enabled (rewrite).
        var lint = NativeMarkdownCodec.Options()
        lint.exportDialect = .gfm
        lint.gfmExtensionExportStrategy = .lint
        lint.headingCheckboxesEnabled = true
        list.append(lint)

        // Ordered numbering preserve typed.
        var preserveNum = NativeMarkdownCodec.Options()
        preserveNum.orderedListNumbering = .preserveTyped
        list.append(preserveNum)

        return list
    }

    private func allOptionPermutations() -> [NativeMarkdownCodec.Options] {
        var list: [NativeMarkdownCodec.Options] = []

        for exportDialect in [NativeMarkdownCodec.Options.ExportDialect.gfm, .kern] {
            let strategies: [NativeMarkdownCodec.Options.GfmExtensionExportStrategy] =
                exportDialect == .gfm ? [.preserve, .portable, .lint] : [.preserve]

            for gfmStrategy in strategies {
                for taskRendering in [NativeMarkdownCodec.Options.TaskRendering.gfm, .kern] {
                    for orderedTasksEnabled in [false, true] {
                        for headingCheckboxesEnabled in [false, true] {
                            for orderedListNumbering in [NativeMarkdownCodec.Options.OrderedListNumbering.gfmDefault, .preserveTyped] {
                                var opt = NativeMarkdownCodec.Options()
                                opt.exportDialect = exportDialect
                                opt.gfmExtensionExportStrategy = gfmStrategy
                                opt.taskRendering = taskRendering
                                opt.orderedTasksEnabled = orderedTasksEnabled
                                opt.headingCheckboxesEnabled = headingCheckboxesEnabled
                                opt.orderedListNumbering = orderedListNumbering
                                list.append(opt)
                            }
                        }
                    }
                }
            }
        }

        return list
    }

    private func describe(_ opt: NativeMarkdownCodec.Options) -> String {
        let pairs: [(String, String)] = [
            ("dialect", opt.exportDialect.rawValue),
            ("gfmExt", opt.gfmExtensionExportStrategy.rawValue),
            ("taskRender", opt.taskRendering.rawValue),
            ("orderedTasks", opt.orderedTasksEnabled ? "1" : "0"),
            ("headingTasks", opt.headingCheckboxesEnabled ? "1" : "0"),
            ("orderedNum", opt.orderedListNumbering.rawValue),
        ]
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    // MARK: - Normalization / Diff

    private func normalize(_ s: String) -> String {
        let lf = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = lf.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.map { $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression) }
        return trimmed.joined(separator: "\n").trimmingCharacters(in: .newlines)
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
