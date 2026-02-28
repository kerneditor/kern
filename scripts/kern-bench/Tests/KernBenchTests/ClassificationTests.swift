import XCTest
@testable import kern_bench

final class ClassificationTests: XCTestCase {
    func testOfficialClassificationWhenRequiredMetricsPresent() {
        let suite = SuiteDefinition.forID(.benchmark)
        let stats = makeStats(requiredMetrics: suite.requiredMetrics)
        let result = EditorResult(
            editor: "Kern",
            architecture: "Native",
            version: "1.0",
            runQuality: "complete",
            runClassification: "official",
            partialReasons: [],
            runs: [],
            stats: stats
        )

        let preflight = PreflightStatus(
            thermalAtStartOK: true,
            thermalThroughoutOK: true,
            rosterComplete: true,
            screenCapturePermissionOK: true,
            accessibilityPermissionOK: true,
            fixtureHashRecorded: true,
            powerSource: "AC",
            thermalPctStart: 100,
            thermalPctEnd: 100
        )

        let outcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
        XCTAssertEqual(outcome.runClassification, .official)
        XCTAssertEqual(outcome.runQuality, .complete)
    }

    func testPartialClassificationWhenRequiredMetricMissing() {
        let suite = SuiteDefinition.forID(.benchmark)
        var stats = makeStats(requiredMetrics: suite.requiredMetrics)
        stats = RunStats(
            coldStartLatency: stats.coldStartLatency,
            warmStartLatency: stats.warmStartLatency,
            openLatency: nil,
            saveUiAckLatency: stats.saveUiAckLatency,
            saveDurableLatency: stats.saveDurableLatency,
            quitLatency: stats.quitLatency,
            typingLatency: stats.typingLatency,
            findLatency: nil,
            scrollSettleLatency: nil,
            scrollEffectiveFPS: nil,
            scrollP95FrameTime: nil,
            scrollP99FrameTime: nil,
            scrollHitchMsPerS: nil,
            scrollJank33msCount: nil,
            scrollJank50msCount: nil,
            windowVisible: nil,
            firstPaint: nil,
            renderStable: nil,
            memoryPhys: stats.memoryPhys,
            memoryRss: stats.memoryRss,
            wowParseLatency: nil,
            wowLayoutLatency: nil,
            wowPaintReadyLatency: nil,
            wowEditApplyLatency: nil,
            wowSaveSerializeLatency: nil,
            wowOpenReadyLatency: nil,
            wowViewportSemanticReadyLatency: nil,
            wowViewportFidelityReadyLatency: nil,
            wowFullDocumentFidelityReadyLatency: nil,
            automationOverhead: nil,
            unattributedOpenBudget: nil,
            timeToStableLayout: nil,
            postReadyExportQuiescence: nil
        )

        let result = EditorResult(
            editor: "Kern",
            architecture: "Native",
            version: "1.0",
            runQuality: "complete",
            runClassification: "official",
            partialReasons: [],
            runs: [],
            stats: stats
        )

        let preflight = PreflightStatus(
            thermalAtStartOK: true,
            thermalThroughoutOK: true,
            rosterComplete: true,
            screenCapturePermissionOK: true,
            accessibilityPermissionOK: true,
            fixtureHashRecorded: true,
            powerSource: "AC",
            thermalPctStart: 100,
            thermalPctEnd: 100
        )

        let outcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
        XCTAssertEqual(outcome.runClassification, .partial)
        XCTAssertEqual(outcome.runQuality, .degraded)
        XCTAssertTrue(outcome.partialReasons.contains(where: { $0.contains("required_metric_missing:open_latency_ms") }))
    }

    func testRequiredMetricFailureMarksRunPartial() throws {
        let suite = SuiteDefinition.forID(.benchmark)
        let ok = try XCTUnwrap(computeStats([10, 11, 12], failures: 0, timeouts: 0, totalAttempts: 3))
        let failedOpen = try XCTUnwrap(computeStats([10, 11], failures: 1, timeouts: 0, totalAttempts: 3))

        let stats = RunStats(
            coldStartLatency: nil,
            warmStartLatency: nil,
            openLatency: failedOpen,
            saveUiAckLatency: ok,
            saveDurableLatency: nil,
            quitLatency: ok,
            typingLatency: nil,
            findLatency: nil,
            scrollSettleLatency: nil,
            scrollEffectiveFPS: nil,
            scrollP95FrameTime: nil,
            scrollP99FrameTime: nil,
            scrollHitchMsPerS: nil,
            scrollJank33msCount: nil,
            scrollJank50msCount: nil,
            windowVisible: nil,
            firstPaint: nil,
            renderStable: nil,
            memoryPhys: nil,
            memoryRss: nil,
            wowParseLatency: nil,
            wowLayoutLatency: nil,
            wowPaintReadyLatency: nil,
            wowEditApplyLatency: nil,
            wowSaveSerializeLatency: nil,
            wowOpenReadyLatency: nil,
            wowViewportSemanticReadyLatency: nil,
            wowViewportFidelityReadyLatency: nil,
            wowFullDocumentFidelityReadyLatency: nil,
            automationOverhead: nil,
            unattributedOpenBudget: nil,
            timeToStableLayout: nil,
            postReadyExportQuiescence: nil
        )

        let result = EditorResult(
            editor: "Kern",
            architecture: "Native",
            version: "1.0",
            runQuality: "degraded",
            runClassification: "partial",
            partialReasons: [],
            runs: [],
            stats: stats
        )
        let preflight = PreflightStatus(
            thermalAtStartOK: true,
            thermalThroughoutOK: true,
            rosterComplete: true,
            screenCapturePermissionOK: true,
            accessibilityPermissionOK: true,
            fixtureHashRecorded: true,
            powerSource: "AC",
            thermalPctStart: 100,
            thermalPctEnd: 100
        )

        let outcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
        XCTAssertEqual(outcome.runClassification, .partial)
        XCTAssertTrue(outcome.partialReasons.contains("metric_failure:open_latency_ms"))
    }

    func testRequiredMetricFailureDoesNotAlsoReportMissing() throws {
        let suite = SuiteDefinition.forID(.benchmark)
        let failedOnly = try XCTUnwrap(computeStats([], failures: 1, timeouts: 1, totalAttempts: 1))
        let ok = try XCTUnwrap(computeStats([10, 11, 12], failures: 0, timeouts: 0, totalAttempts: 3))

        let stats = RunStats(
            coldStartLatency: nil,
            warmStartLatency: nil,
            openLatency: failedOnly,
            saveUiAckLatency: ok,
            saveDurableLatency: nil,
            quitLatency: ok,
            typingLatency: nil,
            findLatency: nil,
            scrollSettleLatency: nil,
            scrollEffectiveFPS: nil,
            scrollP95FrameTime: nil,
            scrollP99FrameTime: nil,
            scrollHitchMsPerS: nil,
            scrollJank33msCount: nil,
            scrollJank50msCount: nil,
            windowVisible: nil,
            firstPaint: nil,
            renderStable: nil,
            memoryPhys: nil,
            memoryRss: nil,
            wowParseLatency: nil,
            wowLayoutLatency: nil,
            wowPaintReadyLatency: nil,
            wowEditApplyLatency: nil,
            wowSaveSerializeLatency: nil,
            wowOpenReadyLatency: nil,
            wowViewportSemanticReadyLatency: nil,
            wowViewportFidelityReadyLatency: nil,
            wowFullDocumentFidelityReadyLatency: nil,
            automationOverhead: nil,
            unattributedOpenBudget: nil,
            timeToStableLayout: nil,
            postReadyExportQuiescence: nil
        )

        let result = EditorResult(
            editor: "Kern",
            architecture: "Native",
            version: "1.0",
            runQuality: "degraded",
            runClassification: "partial",
            partialReasons: [],
            runs: [],
            stats: stats
        )
        let preflight = PreflightStatus(
            thermalAtStartOK: true,
            thermalThroughoutOK: true,
            rosterComplete: true,
            screenCapturePermissionOK: true,
            accessibilityPermissionOK: true,
            fixtureHashRecorded: true,
            powerSource: "AC",
            thermalPctStart: 100,
            thermalPctEnd: 100
        )

        let outcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
        XCTAssertEqual(outcome.runClassification, .partial)
        XCTAssertTrue(outcome.partialReasons.contains("metric_failure:open_latency_ms"))
        XCTAssertTrue(outcome.partialReasons.contains("metric_timeout:open_latency_ms"))
        XCTAssertFalse(outcome.partialReasons.contains("required_metric_missing:open_latency_ms"))
    }

    func testRunLevelMetricFailurePreventsFalseMissingClassification() {
        let suite = SuiteDefinition.forID(.benchmark)
        let result = EditorResult(
            editor: "Sublime Text",
            architecture: "Native",
            version: "4200",
            runQuality: "degraded",
            runClassification: "partial",
            partialReasons: [],
            runs: [
                RunResult(
                    runIndex: 1,
                    coldStartLatencyMs: nil,
                    warmStartLatencyMs: nil,
                    openLatencyMs: nil,
                    saveUiAckLatencyMs: nil,
                    saveDurableLatencyMs: nil,
                    quitLatencyMs: nil,
                    typingLatencyMs: nil,
                    findLatencyMs: nil,
                    scrollSettleLatencyMs: nil,
                    scrollEffectiveFPS: nil,
                    scrollP95FrameTimeMs: nil,
                    scrollP99FrameTimeMs: nil,
                    scrollHitchMsPerS: nil,
                    scrollJank33msCount: nil,
                    scrollJank50msCount: nil,
                    windowVisibleMs: nil,
                    firstPaintMs: nil,
                    renderStableMs: nil,
                    memoryPhysMB: nil,
                    memoryRssMB: nil,
                    wowParseLatencyMs: nil,
                    wowLayoutLatencyMs: nil,
                    wowPaintReadyLatencyMs: nil,
                    wowEditApplyLatencyMs: nil,
                    wowSaveSerializeLatencyMs: nil,
                    wowOpenReadyLatencyMs: nil,
                    wowViewportSemanticReadyLatencyMs: nil,
                    wowViewportFidelityReadyLatencyMs: nil,
                    wowFullDocumentFidelityReadyLatencyMs: nil,
                    automationOverheadMs: nil,
                    unattributedOpenBudgetMs: nil,
                    timeToStableLayoutMs: nil,
                    postReadyExportQuiescenceMs: nil,
                    extraMetrics: nil,
                    runQuality: "degraded",
                    stageTimeoutCount: 0,
                    stageFailureCount: 3,
                    metricFailureReasons: [
                        "open_latency_ms": "posix_semaphore_namespace_exhausted",
                        "save_ui_ack_latency_ms": "posix_semaphore_namespace_exhausted",
                        "quit_latency_ms": "posix_semaphore_namespace_exhausted",
                    ],
                    scrollMetricMode: nil,
                    thermalPct: 100,
                    power: "AC"
                ),
            ],
            stats: RunStats(
                coldStartLatency: nil,
                warmStartLatency: nil,
                openLatency: nil,
                saveUiAckLatency: nil,
                saveDurableLatency: nil,
                quitLatency: nil,
                typingLatency: nil,
                findLatency: nil,
                scrollSettleLatency: nil,
                scrollEffectiveFPS: nil,
                scrollP95FrameTime: nil,
                scrollP99FrameTime: nil,
                scrollHitchMsPerS: nil,
                scrollJank33msCount: nil,
                scrollJank50msCount: nil,
                windowVisible: nil,
                firstPaint: nil,
                renderStable: nil,
                memoryPhys: nil,
                memoryRss: nil,
                wowParseLatency: nil,
                wowLayoutLatency: nil,
                wowPaintReadyLatency: nil,
                wowEditApplyLatency: nil,
                wowSaveSerializeLatency: nil,
                wowOpenReadyLatency: nil,
                wowViewportSemanticReadyLatency: nil,
                wowViewportFidelityReadyLatency: nil,
                wowFullDocumentFidelityReadyLatency: nil,
                automationOverhead: nil,
                unattributedOpenBudget: nil,
                timeToStableLayout: nil,
                postReadyExportQuiescence: nil
            )
        )

        let preflight = PreflightStatus(
            thermalAtStartOK: true,
            thermalThroughoutOK: true,
            rosterComplete: true,
            screenCapturePermissionOK: true,
            accessibilityPermissionOK: true,
            fixtureHashRecorded: true,
            powerSource: "AC",
            thermalPctStart: 100,
            thermalPctEnd: 100
        )

        let outcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
        XCTAssertEqual(outcome.runClassification, .partial)
        XCTAssertTrue(outcome.partialReasons.contains("metric_failure:open_latency_ms"))
        XCTAssertFalse(outcome.partialReasons.contains("required_metric_missing:open_latency_ms"))
        XCTAssertFalse(
            outcome.partialReasons.contains(
                "required_metric_missing_cause:open_latency_ms:posix_semaphore_namespace_exhausted"
            )
        )
    }

    func testSchemaEncodeDecodeIncludesClassificationFields() throws {
        let suite = SuiteDefinition.forID(.benchmark)
        let report = BenchmarkReport(
            version: 4,
            tool: "kern-bench",
            timestamp: "2026-02-22T00:00:00Z",
            suite: suite.id.rawValue,
            suiteKind: suite.suiteKind,
            runClassification: "partial",
            runQuality: "degraded",
            partialReasons: ["missing_roster_editors:TextEdit"],
            environment: EnvironmentInfo(
                chip: "Apple M4",
                macos: "26.2",
                ramGB: 24,
                power: "AC",
                thermalPct: 100,
                thermalPctEnd: 100,
                screencaptureAvailable: true,
                accessibilityAvailable: true,
                display: "3008x1692@2x 120Hz"
            ),
            preflight: PreflightStatus(
                thermalAtStartOK: true,
                thermalThroughoutOK: true,
                rosterComplete: false,
                screenCapturePermissionOK: true,
                accessibilityPermissionOK: true,
                fixtureHashRecorded: true,
                powerSource: "AC",
                thermalPctStart: 100,
                thermalPctEnd: 100
            ),
            config: BenchmarkConfig(
                suite: suite.id.rawValue,
                suiteKind: suite.suiteKind,
                suiteIntendedUsage: suite.intendedUsage,
                rosterPolicy: "locked_roster_v1_official_claims_only",
                file: "/tmp/file.md",
                fileBytes: 100,
                fileHash: "abc",
                mode: "warm",
                runs: 1,
                warmupRuns: 0,
                editorOrder: "shuffled",
                requiredRoster: suite.requiredRoster,
                requiredMetrics: suite.requiredMetrics
            ),
            results: []
        )

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: encoded)
        XCTAssertEqual(decoded.runClassification, "partial")
        XCTAssertEqual(decoded.runQuality, "degraded")
        XCTAssertEqual(decoded.partialReasons.first, "missing_roster_editors:TextEdit")
    }

    func testThermalThroughoutFailureForcesPartialReport() {
        let suite = SuiteDefinition.forID(.benchmark)
        let stats = makeStats(requiredMetrics: suite.requiredMetrics)
        let result = EditorResult(
            editor: "Kern",
            architecture: "Native",
            version: "1.0",
            runQuality: "complete",
            runClassification: "official",
            partialReasons: [],
            runs: [],
            stats: stats
        )

        let preflight = PreflightStatus(
            thermalAtStartOK: true,
            thermalThroughoutOK: false,
            rosterComplete: true,
            screenCapturePermissionOK: true,
            accessibilityPermissionOK: true,
            fixtureHashRecorded: true,
            powerSource: "AC",
            thermalPctStart: 100,
            thermalPctEnd: 95
        )

        let outcome = classifyReport(
            suite: suite,
            preflight: preflight,
            editorResults: [result],
            selectedEditors: requiredRosterV1
        )
        XCTAssertEqual(outcome.runClassification, .partial)
        XCTAssertEqual(outcome.runQuality, .degraded)
        XCTAssertTrue(outcome.partialReasons.contains("thermal_throttle"))
    }

    private func makeStats(requiredMetrics: [String]) -> RunStats {
        let ok = computeStats([10, 11, 12], failures: 0, timeouts: 0, totalAttempts: 3)
        return RunStats(
            coldStartLatency: requiredMetrics.contains("cold_start_latency_ms") ? ok : nil,
            warmStartLatency: requiredMetrics.contains("warm_start_latency_ms") ? ok : nil,
            openLatency: requiredMetrics.contains("open_latency_ms") ? ok : nil,
            saveUiAckLatency: requiredMetrics.contains("save_ui_ack_latency_ms") ? ok : nil,
            saveDurableLatency: requiredMetrics.contains("save_durable_latency_ms") ? ok : nil,
            quitLatency: requiredMetrics.contains("quit_latency_ms") ? ok : nil,
            typingLatency: requiredMetrics.contains("typing_latency_ms") ? ok : nil,
            findLatency: requiredMetrics.contains("find_latency_ms") ? ok : nil,
            scrollSettleLatency: requiredMetrics.contains("scroll_settle_latency_ms") ? ok : nil,
            scrollEffectiveFPS: nil,
            scrollP95FrameTime: nil,
            scrollP99FrameTime: nil,
            scrollHitchMsPerS: nil,
            scrollJank33msCount: nil,
            scrollJank50msCount: nil,
            windowVisible: ok,
            firstPaint: nil,
            renderStable: nil,
            memoryPhys: requiredMetrics.contains("memory_phys_mb") ? ok : nil,
            memoryRss: requiredMetrics.contains("memory_rss_mb") ? ok : nil,
            wowParseLatency: requiredMetrics.contains("wow_parse_latency_ms") ? ok : nil,
            wowLayoutLatency: requiredMetrics.contains("wow_layout_latency_ms") ? ok : nil,
            wowPaintReadyLatency: requiredMetrics.contains("wow_paint_ready_latency_ms") ? ok : nil,
            wowEditApplyLatency: requiredMetrics.contains("wow_edit_apply_latency_ms") ? ok : nil,
            wowSaveSerializeLatency: requiredMetrics.contains("wow_save_serialize_latency_ms") ? ok : nil,
            wowOpenReadyLatency: requiredMetrics.contains("wow_open_ready_latency_ms") ? ok : nil,
            wowViewportSemanticReadyLatency: requiredMetrics.contains("wow_viewport_semantic_ready_latency_ms") ? ok : nil,
            wowViewportFidelityReadyLatency: requiredMetrics.contains("wow_viewport_fidelity_ready_latency_ms") ? ok : nil,
            wowFullDocumentFidelityReadyLatency: requiredMetrics.contains("wow_full_document_fidelity_ready_latency_ms") ? ok : nil,
            automationOverhead: nil,
            unattributedOpenBudget: nil,
            timeToStableLayout: nil,
            postReadyExportQuiescence: nil
        )
    }
}
