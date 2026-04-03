import Foundation
import XCTest
@testable import kern_bench

final class BenchmarkMetadataTests: XCTestCase {
    func testBenchmarkProfileLabelFallsBackToDirect() {
        XCTAssertEqual(benchmarkProfileLabel(environment: [:]), "direct")
        XCTAssertEqual(benchmarkProfileLabel(environment: ["KERN_BENCH_PROFILE_LABEL": "  "]), "direct")
    }

    func testBenchmarkProfileLabelUsesEnvironmentValue() {
        XCTAssertEqual(
            benchmarkProfileLabel(environment: ["KERN_BENCH_PROFILE_LABEL": "full-fidelity-stable"]),
            "full-fidelity-stable"
        )
    }

    func testBenchmarkInjectedOverridesParsesSemicolonDelimitedPairs() {
        let overrides = benchmarkInjectedOverrides(environment: [
            "KERN_BENCH_INJECTED_OVERRIDES": "A=1;B=two words;INVALID;=skip;C=3"
        ])

        XCTAssertEqual(overrides?["A"], "1")
        XCTAssertEqual(overrides?["B"], "two words")
        XCTAssertEqual(overrides?["C"], "3")
        XCTAssertNil(overrides?["INVALID"])
        XCTAssertEqual(overrides?.count, 3)
    }

    func testBenchmarkConfigEncodesArchiveMetadataFields() throws {
        let config = BenchmarkConfig(
            suite: "benchmark_full_fidelity",
            suiteKind: "cross_editor_full_fidelity",
            suiteIntendedUsage: "optional huge-fixture full-document-fidelity completion comparison",
            rosterPolicy: "selected_roster_diagnostic_unless_claim_safe_roster_matches",
            claimPolicy: "publishable head-to-head claims require the exact Kern,Zed roster",
            file: "/tmp/fixture.md",
            fileBytes: 1024,
            fileHash: "abc123",
            mode: "warm",
            runs: 5,
            warmupRuns: 0,
            profile: "full-fidelity-stable",
            claimSafeMinimumRuns: 10,
            claimSafeMinimumWarmupRuns: 1,
            claimSafeMinimumInterEditorCooldownMs: 1500,
            interEditorCooldownMs: 1500,
            postOpenDelayMs: 25,
            editorOrder: "shuffled_per_round",
            roundOrderTrace: [["Kern", "Zed"], ["Zed", "Kern"]],
            injectedOverrides: [
                "KERN_STAGED_PROMOTION_CONTEXT_CHARS": "1000",
                "KERN_STAGED_PROMOTION_VIEWPORT_MICRO_STEP_CHARS": "2000000",
            ],
            requiredRoster: [],
            claimSafeRoster: ["Kern", "Zed"],
            requiredMetrics: ["full_fidelity_end_to_end_latency_ms"]
        )

        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["profile"] as? String, "full-fidelity-stable")
        XCTAssertEqual(json["claim_safe_minimum_runs"] as? Int, 10)
        XCTAssertEqual(json["claim_safe_minimum_warmup_runs"] as? Int, 1)
        XCTAssertEqual(json["claim_safe_minimum_inter_editor_cooldown_ms"] as? Int, 1500)
        XCTAssertEqual(json["inter_editor_cooldown_ms"] as? Int, 1500)
        XCTAssertEqual(json["post_open_delay_ms"] as? Int, 25)
        XCTAssertEqual(json["editor_order"] as? String, "shuffled_per_round")
        XCTAssertEqual((json["round_order_trace"] as? [[String]])?.count, 2)
        let overrides = json["injected_overrides"] as? [String: String]
        XCTAssertEqual(overrides?["KERN_STAGED_PROMOTION_CONTEXT_CHARS"], "1000")
    }

    func testMarkdownSummaryIncludesRunShapeMetadata() {
        let report = BenchmarkReport(
            version: 4,
            tool: "kern-bench",
            timestamp: "2026-03-08T00:00:00Z",
            suite: "benchmark_full_fidelity",
            suiteKind: "cross_editor_full_fidelity",
            runClassification: "official",
            runQuality: "complete",
            partialReasons: [],
            environment: EnvironmentInfo(
                chip: "Apple M4",
                macos: "26.2",
                ramGB: 24,
                power: "AC",
                thermalPct: 100,
                thermalPctEnd: 100,
                screencaptureAvailable: false,
                accessibilityAvailable: true,
                display: nil
            ),
            preflight: PreflightStatus(
                thermalAtStartOK: true,
                thermalThroughoutOK: true,
                rosterComplete: true,
                screenCapturePermissionOK: true,
                accessibilityPermissionOK: true,
                fixtureHashRecorded: true,
                powerSource: "AC",
                thermalPctStart: 100,
                thermalPctEnd: 100
            ),
            config: BenchmarkConfig(
                suite: "benchmark_full_fidelity",
                suiteKind: "cross_editor_full_fidelity",
                suiteIntendedUsage: "optional huge-fixture full-document-fidelity completion comparison",
                rosterPolicy: "selected_roster_diagnostic_unless_claim_safe_roster_matches",
                claimPolicy: "publishable head-to-head claims require the exact Kern,Zed roster",
                file: "/tmp/fixture.md",
                fileBytes: 1024,
                fileHash: "abc123",
                mode: "warm",
                runs: 5,
                warmupRuns: 0,
                profile: "full-fidelity-stable",
                claimSafeMinimumRuns: 10,
                claimSafeMinimumWarmupRuns: 1,
                claimSafeMinimumInterEditorCooldownMs: 1500,
                interEditorCooldownMs: 1500,
                postOpenDelayMs: 25,
                editorOrder: "shuffled_per_round",
                roundOrderTrace: [["Kern", "Zed"], ["Zed", "Kern"]],
                injectedOverrides: ["KERN_STAGED_PROMOTION_CONTEXT_CHARS": "1000"],
                requiredRoster: [],
                claimSafeRoster: ["Kern", "Zed"],
                requiredMetrics: ["full_fidelity_end_to_end_latency_ms"]
            ),
            results: []
        )

        let markdown = markdownSummary(report: report)
        XCTAssertTrue(markdown.contains("Profile: full-fidelity-stable"))
        XCTAssertTrue(markdown.contains("Claim-safe minimums: runs >= 10, warmups >= 1, cooldown >= 1500ms"))
        XCTAssertTrue(markdown.contains("Inter-editor cooldown: 1500ms"))
        XCTAssertTrue(markdown.contains("Order mode: shuffled_per_round"))
        XCTAssertTrue(markdown.contains("Round order trace: R1=Kern,Zed; R2=Zed,Kern"))
        XCTAssertTrue(markdown.contains("Injected overrides: KERN_STAGED_PROMOTION_CONTEXT_CHARS=1000"))
    }
}
