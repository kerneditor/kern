import AppKit
import Foundation
import XCTest
@testable import KernTextKit

final class NativeMarkdownSpecConformanceTests: XCTestCase {
    private struct FixtureEnvelope: Decodable {
        let source: String
        let spec: String
        let version: String
        let exampleCount: Int
        let examples: [SpecExample]

        enum CodingKeys: String, CodingKey {
            case source
            case spec
            case version
            case exampleCount = "example_count"
            case examples
        }
    }

    private struct SpecExample: Decodable {
        let example: Int
        let section: String
        let markdown: String
        let html: String
    }

    private struct OracleBatchRequest: Encodable {
        let mode: String
        let items: [OracleRequestItem]
    }

    private struct OracleRequestItem: Encodable {
        let id: Int
        let inputMarkdown: String
        let outputMarkdown: String

        enum CodingKeys: String, CodingKey {
            case id
            case inputMarkdown = "input_markdown"
            case outputMarkdown = "output_markdown"
        }
    }

    private struct OracleBatchResponse: Decodable {
        let mode: String
        let results: [OracleResultItem]
    }

    private struct OracleResultItem: Decodable {
        let id: Int
        let inputHTML: String
        let outputHTML: String
        let semanticMatch: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case inputHTML = "input_html"
            case outputHTML = "output_html"
            case semanticMatch = "semantic_match"
        }
    }

    private struct FailureRow {
        let example: Int
        let section: String
        let markdown: String
        let exported: String
        let inputHTML: String
        let outputHTML: String
    }

    @MainActor
    func testCommonMarkStrictProfileConformance_NoKernExtensions() throws {
        try TestGates.skipUnlessSpecConformance()
        try runConformance(
            mode: "commonmark",
            fixtureName: "commonmark-0.31.2.json"
        )
    }

    @MainActor
    func testGfmStrictProfileConformance_NoKernExtensions() throws {
        try TestGates.skipUnlessSpecConformance()
        try runConformance(
            mode: "gfm",
            fixtureName: "gfm-0.29.0.gfm.13.json"
        )
    }

    @MainActor
    func testKernExtensionsRemainExplicitlySeparateFromStrictProfile() {
        var strict = strictOptions(for: "gfm")
        strict.exportDialect = .gfm
        strict.gfmExtensionExportStrategy = .portable
        strict.orderedTasksEnabled = false
        strict.headingCheckboxesEnabled = false

        let source = """
        # [ ] heading task
        1. [x] ordered task
        """

        let imported = NativeMarkdownCodec.importMarkdown(source, options: strict, baseURL: nil)
        let rendered = imported.string
        XCTAssertTrue(rendered.contains("[ ] heading task"), "Strict profile should keep heading task syntax literal")
        XCTAssertTrue(rendered.contains("[x] ordered task"), "Strict profile should keep ordered task syntax literal")

        var kern = strict
        kern.orderedTasksEnabled = true
        kern.headingCheckboxesEnabled = true
        let importedKern = NativeMarkdownCodec.importMarkdown(source, options: kern, baseURL: nil)
        let renderedKern = importedKern.string
        XCTAssertTrue(renderedKern.contains("☐ heading task"), "Kern extension profile should render heading checkbox")
        XCTAssertTrue(renderedKern.contains("☑ ordered task"), "Kern extension profile should render ordered task checkbox")
    }

    @MainActor
    private func runConformance(mode: String, fixtureName: String) throws {
        let fixture = try loadFixture(named: fixtureName)
        XCTAssertEqual(
            fixture.spec.lowercased(),
            mode,
            "Fixture spec mismatch: expected \(mode), got \(fixture.spec)"
        )
        var examples = fixture.examples

        if let sectionRegex = runtimeString("KERN_SPEC_SECTION_REGEX"), !sectionRegex.isEmpty {
            let regex = try NSRegularExpression(pattern: sectionRegex, options: [.caseInsensitive])
            examples = examples.filter { example in
                let range = NSRange(example.section.startIndex..., in: example.section)
                return regex.firstMatch(in: example.section, options: [], range: range) != nil
            }
        }

        if let limitRaw = runtimeString("KERN_SPEC_CASE_LIMIT"),
           let limit = Int(limitRaw),
           limit > 0,
           examples.count > limit {
            examples = Array(examples.prefix(limit))
        }

        XCTAssertFalse(examples.isEmpty, "Conformance fixture has no examples after filters")

        let options = strictOptions(for: mode)
        var requestItems: [OracleRequestItem] = []
        requestItems.reserveCapacity(examples.count)

        var exportedByID: [Int: String] = [:]
        exportedByID.reserveCapacity(examples.count)

        for example in examples {
            let imported = NativeMarkdownCodec.importMarkdown(example.markdown, options: options, baseURL: nil)
            let exported = NativeMarkdownCodec.exportMarkdown(imported, options: options)
            exportedByID[example.example] = exported
            requestItems.append(
                OracleRequestItem(
                    id: example.example,
                    inputMarkdown: example.markdown,
                    outputMarkdown: exported
                )
            )
        }

        let oracleResults = try runOracle(mode: mode, items: requestItems)
        XCTAssertEqual(
            oracleResults.count,
            requestItems.count,
            "Oracle returned mismatched result count"
        )

        let resultByID = Dictionary(uniqueKeysWithValues: oracleResults.map { ($0.id, $0) })
        var failures: [FailureRow] = []
        var sectionTotals: [String: Int] = [:]
        var sectionPasses: [String: Int] = [:]

        for example in examples {
            sectionTotals[example.section, default: 0] += 1
            guard let result = resultByID[example.example],
                  let exported = exportedByID[example.example] else {
                XCTFail("Missing oracle/exported result for example \(example.example)")
                continue
            }
            if result.semanticMatch {
                sectionPasses[example.section, default: 0] += 1
            } else {
                failures.append(
                    FailureRow(
                        example: example.example,
                        section: example.section,
                        markdown: example.markdown,
                        exported: exported,
                        inputHTML: result.inputHTML,
                        outputHTML: result.outputHTML
                    )
                )
            }
        }

        let total = examples.count
        let passed = total - failures.count
        let percent = total == 0 ? 0.0 : (Double(passed) / Double(total)) * 100

        var sectionSummaryLines: [String] = []
        for section in sectionTotals.keys.sorted() {
            let pass = sectionPasses[section, default: 0]
            let count = sectionTotals[section, default: 0]
            let sectionPct = count == 0 ? 0.0 : (Double(pass) / Double(count)) * 100
            sectionSummaryLines.append("\(section): \(pass)/\(count) (\(String(format: "%.1f", sectionPct))%)")
        }

        let reportHeader = """
        spec_mode=\(mode)
        fixture=\(fixtureName)
        source=\(fixture.source)
        version=\(fixture.version)
        cases=\(total)
        passed=\(passed)
        failed=\(failures.count)
        pass_rate=\(String(format: "%.2f", percent))%
        """

        let sectionSummary = sectionSummaryLines.joined(separator: "\n")
        attachText(
            """
            \(reportHeader)

            section_summary:
            \(sectionSummary)
            """,
            named: "spec-conformance-\(mode)-summary"
        )

        if !failures.isEmpty {
            let fullIndex = failures
                .map { "example=\($0.example)\tsection=\($0.section)" }
                .joined(separator: "\n")
            attachText(fullIndex, named: "spec-conformance-\(mode)-failure-index")
            print("[spec-conformance:\(mode)] failure-index:")
            for line in fullIndex.split(separator: "\n", omittingEmptySubsequences: true) {
                print(String(line))
            }

            let maxDetails = min(30, failures.count)
            let detailText = failures.prefix(maxDetails).enumerated().map { idx, failure in
                """
                [\(idx + 1)] example=\(failure.example) section=\(failure.section)
                --- markdown ---
                \(failure.markdown)
                --- exported ---
                \(failure.exported)
                --- oracle_input_html ---
                \(failure.inputHTML)
                --- oracle_output_html ---
                \(failure.outputHTML)
                """
            }.joined(separator: "\n\n")
            attachText(detailText, named: "spec-conformance-\(mode)-failures")
            if runtimeString("KERN_SPEC_PRINT_FAILURE_DETAILS") == "1" {
                print("[spec-conformance:\(mode)] failure-details:")
                print(detailText)
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            """
            \(mode.uppercased()) strict conformance failed: \(failures.count)/\(total) examples mismatched.
            Check attachments: spec-conformance-\(mode)-summary / spec-conformance-\(mode)-failures.
            """
        )
    }

    @MainActor
    private func strictOptions(for mode: String) -> NativeMarkdownCodec.Options {
        var opt = NativeMarkdownCodec.Options()
        opt.exportDialect = .gfm
        opt.gfmExtensionExportStrategy = .preserve
        opt.taskRendering = .gfm
        opt.orderedTasksEnabled = false
        opt.headingCheckboxesEnabled = false
        opt.orderedListNumbering = .gfmDefault
        opt.strictConformanceRoundTripMode = true
        return opt
    }

    private func runOracle(mode: String, items: [OracleRequestItem]) throws -> [OracleResultItem] {
        let scriptURL = repoRoot()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("spec_oracle_render.py", isDirectory: false)

        let encoder = JSONEncoder()
        let payload = OracleBatchRequest(mode: mode, items: items)
        let inputData = try encoder.encode(payload)
        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-spec-oracle-\(UUID().uuidString).json", isDirectory: false)
        try inputData.write(to: payloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let process = Process()
        if let python = resolvedOraclePythonPath() {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [scriptURL.path, "--mode", mode, "--input-file", payloadURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path, "--mode", mode, "--input-file", payloadURL.path]
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errorData, encoding: .utf8) ?? "<unable to decode stderr>"
            XCTFail("Oracle process failed (\(process.terminationStatus)): \(stderrText)")
            return []
        }

        if outputData.isEmpty {
            let stderrText = String(data: errorData, encoding: .utf8) ?? "<unable to decode stderr>"
            XCTFail("Oracle produced no output. stderr=\(stderrText)")
            return []
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OracleBatchResponse.self, from: outputData)
        guard decoded.mode == mode else {
            XCTFail("Oracle mode mismatch: expected \(mode), got \(decoded.mode)")
            return []
        }
        return decoded.results
    }

    private func resolvedOraclePythonPath() -> String? {
        if let configured = runtimeString("KERN_SPEC_ORACLE_PYTHON"), !configured.isEmpty {
            return configured
        }

        // Reliable local fallback used by repository scripts.
        let fallback = repoRoot()
            .appendingPathComponent(".venv-spec", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3", isDirectory: false)
            .path

        if FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }

        return nil
    }

    private func loadFixture(named name: String) throws -> FixtureEnvelope {
        let fixtureRoot: URL
        if let override = runtimeString("KERN_SPEC_FIXTURE_DIR"), !override.isEmpty {
            fixtureRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            fixtureRoot = repoRoot()
                .appendingPathComponent("test-fixtures", isDirectory: true)
                .appendingPathComponent("spec", isDirectory: true)
        }

        let url = fixtureRoot.appendingPathComponent(name, isDirectory: false)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureEnvelope.self, from: data)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func attachText(_ text: String, named: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func runtimeString(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        if let suite = UserDefaults(suiteName: "com.gradigit.kern.tests"),
           let value = suite.string(forKey: key),
           !value.isEmpty {
            return value
        }
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            return value
        }
        return nil
    }
}
