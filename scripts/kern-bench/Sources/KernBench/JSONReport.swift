import AppKit
import CommonCrypto
import Darwin
import Foundation

// MARK: - Output Models (v4 schema)

struct BenchmarkReport: Codable {
    let version: Int
    let tool: String
    let timestamp: String
    let suite: String
    let suiteKind: String
    var runClassification: String
    var runQuality: String
    var partialReasons: [String]
    let environment: EnvironmentInfo
    let preflight: PreflightStatus
    let config: BenchmarkConfig
    var results: [EditorResult]

    enum CodingKeys: String, CodingKey {
        case version, tool, timestamp, suite, environment, preflight, config, results
        case suiteKind = "suite_kind"
        case runClassification = "run_classification"
        case runQuality = "run_quality"
        case partialReasons = "partial_reasons"
    }
}

struct EnvironmentInfo: Codable {
    let chip: String
    let macos: String
    let ramGB: Int
    let power: String
    let thermalPct: Int
    let thermalPctEnd: Int?
    let screencaptureAvailable: Bool
    let accessibilityAvailable: Bool
    let display: String?

    enum CodingKeys: String, CodingKey {
        case chip, macos, power, display
        case ramGB = "ram_gb"
        case thermalPct = "thermal_pct"
        case thermalPctEnd = "thermal_pct_end"
        case screencaptureAvailable = "screencapture_available"
        case accessibilityAvailable = "accessibility_available"
    }
}

struct BenchmarkConfig: Codable {
    let suite: String
    let suiteKind: String
    let suiteIntendedUsage: String
    let rosterPolicy: String
    let file: String
    let fileBytes: Int
    let fileHash: String
    let mode: String
    let runs: Int
    let warmupRuns: Int
    let editorOrder: String
    let requiredRoster: [String]
    let requiredMetrics: [String]

    enum CodingKeys: String, CodingKey {
        case suite, file, mode, runs
        case suiteKind = "suite_kind"
        case suiteIntendedUsage = "suite_intended_usage"
        case rosterPolicy = "roster_policy"
        case fileBytes = "file_bytes"
        case fileHash = "file_hash"
        case warmupRuns = "warmup_runs"
        case editorOrder = "editor_order"
        case requiredRoster = "required_roster"
        case requiredMetrics = "required_metrics"
    }
}

struct EditorResult: Codable {
    let editor: String
    let architecture: String
    let version: String?
    var runQuality: String
    var runClassification: String
    var partialReasons: [String]
    var runs: [RunResult]
    var stats: RunStats?

    enum CodingKeys: String, CodingKey {
        case editor, architecture, version, runs, stats
        case runQuality = "run_quality"
        case runClassification = "run_classification"
        case partialReasons = "partial_reasons"
    }
}

struct RunResult: Codable {
    let runIndex: Int
    let coldStartLatencyMs: Double?
    let warmStartLatencyMs: Double?
    let openLatencyMs: Double?
    let saveUiAckLatencyMs: Double?
    let saveDurableLatencyMs: Double?
    let quitLatencyMs: Double?
    let typingLatencyMs: Double?
    let findLatencyMs: Double?
    let scrollSettleLatencyMs: Double?
    let scrollEffectiveFPS: Double?
    let scrollP95FrameTimeMs: Double?
    let scrollP99FrameTimeMs: Double?
    let scrollHitchMsPerS: Double?
    let scrollJank33msCount: Double?
    let scrollJank50msCount: Double?

    let windowVisibleMs: Double?
    let firstPaintMs: Double?
    let renderStableMs: Double?
    let memoryPhysMB: Double?
    let memoryRssMB: Double?
    let wowParseLatencyMs: Double?
    let wowLayoutLatencyMs: Double?
    let wowPaintReadyLatencyMs: Double?
    let wowEditApplyLatencyMs: Double?
    let wowSaveSerializeLatencyMs: Double?
    let wowOpenReadyLatencyMs: Double?
    let wowViewportSemanticReadyLatencyMs: Double?
    let wowViewportFidelityReadyLatencyMs: Double?
    let wowFullDocumentFidelityReadyLatencyMs: Double?
    var fullFidelityEndToEndLatencyMs: Double? = nil
    let automationOverheadMs: Double?
    let unattributedOpenBudgetMs: Double?
    let timeToStableLayoutMs: Double?
    let postReadyExportQuiescenceMs: Double?

    let runQuality: String
    let stageTimeoutCount: Int
    let stageFailureCount: Int
    let metricFailureReasons: [String: String]
    let scrollMetricMode: String?

    let thermalPct: Int?
    let power: String?

    enum CodingKeys: String, CodingKey {
        case runIndex = "run_index"
        case coldStartLatencyMs = "cold_start_latency_ms"
        case warmStartLatencyMs = "warm_start_latency_ms"
        case openLatencyMs = "open_latency_ms"
        case saveUiAckLatencyMs = "save_ui_ack_latency_ms"
        case saveDurableLatencyMs = "save_durable_latency_ms"
        case quitLatencyMs = "quit_latency_ms"
        case typingLatencyMs = "typing_latency_ms"
        case findLatencyMs = "find_latency_ms"
        case scrollSettleLatencyMs = "scroll_settle_latency_ms"
        case scrollEffectiveFPS = "scroll_effective_fps"
        case scrollP95FrameTimeMs = "scroll_p95_frame_time_ms"
        case scrollP99FrameTimeMs = "scroll_p99_frame_time_ms"
        case scrollHitchMsPerS = "scroll_hitch_ms_per_s"
        case scrollJank33msCount = "scroll_jank_33ms_count"
        case scrollJank50msCount = "scroll_jank_50ms_count"
        case windowVisibleMs = "window_visible_ms"
        case firstPaintMs = "first_paint_ms"
        case renderStableMs = "render_stable_ms"
        case memoryPhysMB = "memory_phys_mb"
        case memoryRssMB = "memory_rss_mb"
        case wowParseLatencyMs = "wow_parse_latency_ms"
        case wowLayoutLatencyMs = "wow_layout_latency_ms"
        case wowPaintReadyLatencyMs = "wow_paint_ready_latency_ms"
        case wowEditApplyLatencyMs = "wow_edit_apply_latency_ms"
        case wowSaveSerializeLatencyMs = "wow_save_serialize_latency_ms"
        case wowOpenReadyLatencyMs = "wow_open_ready_latency_ms"
        case wowViewportSemanticReadyLatencyMs = "wow_viewport_semantic_ready_latency_ms"
        case wowViewportFidelityReadyLatencyMs = "wow_viewport_fidelity_ready_latency_ms"
        case wowFullDocumentFidelityReadyLatencyMs = "wow_full_document_fidelity_ready_latency_ms"
        case fullFidelityEndToEndLatencyMs = "full_fidelity_end_to_end_latency_ms"
        case automationOverheadMs = "automation_overhead_ms"
        case unattributedOpenBudgetMs = "unattributed_open_budget_ms"
        case timeToStableLayoutMs = "time_to_stable_layout_ms"
        case postReadyExportQuiescenceMs = "post_ready_export_quiescence_ms"
        case runQuality = "run_quality"
        case stageTimeoutCount = "stage_timeout_count"
        case stageFailureCount = "stage_failure_count"
        case metricFailureReasons = "metric_failure_reasons"
        case scrollMetricMode = "scroll_metric_mode"
        case thermalPct = "thermal_pct"
        case power
    }
}

struct RunStats: Codable {
    let coldStartLatency: Stats?
    let warmStartLatency: Stats?
    let openLatency: Stats?
    let saveUiAckLatency: Stats?
    let saveDurableLatency: Stats?
    let quitLatency: Stats?
    let typingLatency: Stats?
    let findLatency: Stats?
    let scrollSettleLatency: Stats?
    let scrollEffectiveFPS: Stats?
    let scrollP95FrameTime: Stats?
    let scrollP99FrameTime: Stats?
    let scrollHitchMsPerS: Stats?
    let scrollJank33msCount: Stats?
    let scrollJank50msCount: Stats?

    let windowVisible: Stats?
    let firstPaint: Stats?
    let renderStable: Stats?
    let memoryPhys: Stats?
    let memoryRss: Stats?
    let wowParseLatency: Stats?
    let wowLayoutLatency: Stats?
    let wowPaintReadyLatency: Stats?
    let wowEditApplyLatency: Stats?
    let wowSaveSerializeLatency: Stats?
    let wowOpenReadyLatency: Stats?
    let wowViewportSemanticReadyLatency: Stats?
    let wowViewportFidelityReadyLatency: Stats?
    let wowFullDocumentFidelityReadyLatency: Stats?
    var fullFidelityEndToEndLatency: Stats? = nil
    let automationOverhead: Stats?
    let unattributedOpenBudget: Stats?
    let timeToStableLayout: Stats?
    let postReadyExportQuiescence: Stats?
    var extraMetrics: [String: Stats]?

    enum CodingKeys: String, CodingKey {
        case coldStartLatency = "cold_start_latency"
        case warmStartLatency = "warm_start_latency"
        case openLatency = "open_latency"
        case saveUiAckLatency = "save_ui_ack_latency"
        case saveDurableLatency = "save_durable_latency"
        case quitLatency = "quit_latency"
        case typingLatency = "typing_latency"
        case findLatency = "find_latency"
        case scrollSettleLatency = "scroll_settle_latency"
        case scrollEffectiveFPS = "scroll_effective_fps"
        case scrollP95FrameTime = "scroll_p95_frame_time"
        case scrollP99FrameTime = "scroll_p99_frame_time"
        case scrollHitchMsPerS = "scroll_hitch_ms_per_s"
        case scrollJank33msCount = "scroll_jank_33ms_count"
        case scrollJank50msCount = "scroll_jank_50ms_count"
        case windowVisible = "window_visible"
        case firstPaint = "first_paint"
        case renderStable = "render_stable"
        case memoryPhys = "memory_phys"
        case memoryRss = "memory_rss"
        case wowParseLatency = "wow_parse_latency"
        case wowLayoutLatency = "wow_layout_latency"
        case wowPaintReadyLatency = "wow_paint_ready_latency"
        case wowEditApplyLatency = "wow_edit_apply_latency"
        case wowSaveSerializeLatency = "wow_save_serialize_latency"
        case wowOpenReadyLatency = "wow_open_ready_latency"
        case wowViewportSemanticReadyLatency = "wow_viewport_semantic_ready_latency"
        case wowViewportFidelityReadyLatency = "wow_viewport_fidelity_ready_latency"
        case wowFullDocumentFidelityReadyLatency = "wow_full_document_fidelity_ready_latency"
        case fullFidelityEndToEndLatency = "full_fidelity_end_to_end_latency"
        case automationOverhead = "automation_overhead"
        case unattributedOpenBudget = "unattributed_open_budget"
        case timeToStableLayout = "time_to_stable_layout"
        case postReadyExportQuiescence = "post_ready_export_quiescence"
        case extraMetrics = "extra_metrics"
    }

    func metricDictionary() -> [String: Stats] {
        var out: [String: Stats] = [:]
        func set(_ key: String, _ value: Stats?) {
            if let value {
                out[key] = value
            }
        }

        set("cold_start_latency_ms", coldStartLatency)
        set("warm_start_latency_ms", warmStartLatency)
        set("open_latency_ms", openLatency)
        set("typing_latency_ms", typingLatency)
        set("save_ui_ack_latency_ms", saveUiAckLatency)
        set("save_durable_latency_ms", saveDurableLatency)
        set("quit_latency_ms", quitLatency)
        set("find_latency_ms", findLatency)
        set("scroll_settle_latency_ms", scrollSettleLatency)
        set("scroll_effective_fps", scrollEffectiveFPS)
        set("scroll_p95_frame_time_ms", scrollP95FrameTime)
        set("scroll_p99_frame_time_ms", scrollP99FrameTime)
        set("scroll_hitch_ms_per_s", scrollHitchMsPerS)
        set("scroll_jank_33ms_count", scrollJank33msCount)
        set("scroll_jank_50ms_count", scrollJank50msCount)
        set("window_visible_ms", windowVisible)
        set("first_paint_ms", firstPaint)
        set("render_stable_ms", renderStable)
        set("memory_phys_mb", memoryPhys)
        set("memory_rss_mb", memoryRss)
        set("wow_parse_latency_ms", wowParseLatency)
        set("wow_layout_latency_ms", wowLayoutLatency)
        set("wow_paint_ready_latency_ms", wowPaintReadyLatency)
        set("wow_edit_apply_latency_ms", wowEditApplyLatency)
        set("wow_save_serialize_latency_ms", wowSaveSerializeLatency)
        set("wow_open_ready_latency_ms", wowOpenReadyLatency)
        set("wow_viewport_semantic_ready_latency_ms", wowViewportSemanticReadyLatency)
        set("wow_viewport_fidelity_ready_latency_ms", wowViewportFidelityReadyLatency)
        set("wow_full_document_fidelity_ready_latency_ms", wowFullDocumentFidelityReadyLatency)
        set("full_fidelity_end_to_end_latency_ms", fullFidelityEndToEndLatency)
        set("automation_overhead_ms", automationOverhead)
        set("unattributed_open_budget_ms", unattributedOpenBudget)
        set("time_to_stable_layout_ms", timeToStableLayout)
        set("post_ready_export_quiescence_ms", postReadyExportQuiescence)
        if let extraMetrics {
            for (key, value) in extraMetrics {
                out[key] = value
            }
        }
        return out
    }
}

// MARK: - Environment Detection

func detectEnvironment(screencaptureAvailable: Bool, accessibilityAvailable: Bool) -> EnvironmentInfo {
    EnvironmentInfo(
        chip: shellOutput("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"]) ?? "Unknown",
        macos: shellOutput("/usr/bin/sw_vers", args: ["-productVersion"]) ?? "Unknown",
        ramGB: detectRAMGB(),
        power: detectPowerSource(),
        thermalPct: detectThermalPct(),
        thermalPctEnd: nil,
        screencaptureAvailable: screencaptureAvailable,
        accessibilityAvailable: accessibilityAvailable,
        display: detectDisplay()
    )
}

func environmentWithEndThermal(_ env: EnvironmentInfo) -> EnvironmentInfo {
    EnvironmentInfo(
        chip: env.chip,
        macos: env.macos,
        ramGB: env.ramGB,
        power: env.power,
        thermalPct: env.thermalPct,
        thermalPctEnd: detectThermalPct(),
        screencaptureAvailable: env.screencaptureAvailable,
        accessibilityAvailable: env.accessibilityAvailable,
        display: env.display
    )
}

private func detectDisplay() -> String? {
    guard let screen = NSScreen.main else { return nil }
    let w = Int(screen.frame.width * screen.backingScaleFactor)
    let h = Int(screen.frame.height * screen.backingScaleFactor)
    let scale = Int(screen.backingScaleFactor)
    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    let refreshHz: Int
    if let mode = CGDisplayCopyDisplayMode(displayID) {
        refreshHz = Int(mode.refreshRate)
    } else {
        refreshHz = 0
    }
    if refreshHz > 0 {
        return "\(w)x\(h)@\(scale)x \(refreshHz)Hz"
    }
    return "\(w)x\(h)@\(scale)x"
}

private func detectRAMGB() -> Int {
    if let str = shellOutput("/usr/sbin/sysctl", args: ["-n", "hw.memsize"]),
       let bytes = UInt64(str) {
        return Int(bytes / (1024 * 1024 * 1024))
    }
    return 0
}

func detectPowerSource() -> String {
    guard let output = shellOutput("/usr/bin/pmset", args: ["-g", "batt"]) else { return "Unknown" }
    if output.contains("AC Power") { return "AC" }
    if output.contains("Battery Power") { return "Battery" }
    return "Unknown"
}

func detectThermalPct() -> Int {
    guard let output = shellOutput("/usr/bin/pmset", args: ["-g", "therm"]) else { return 100 }
    for line in output.components(separatedBy: "\n") {
        if line.contains("CPU_Speed_Limit") {
            let parts = line.components(separatedBy: "=")
            if parts.count >= 2, let val = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return val
            }
        }
    }
    return 100
}

func shellOutput(_ executable: String, args: [String], timeoutSeconds: TimeInterval = 0.35) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return nil
    }

    let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
    while proc.isRunning, DispatchTime.now().uptimeNanoseconds < deadlineNs {
        usleep(2_000)
    }

    if proc.isRunning {
        proc.terminate()
        let terminateDeadlineNs = DispatchTime.now().uptimeNanoseconds + 50_000_000
        while proc.isRunning, DispatchTime.now().uptimeNanoseconds < terminateDeadlineNs {
            usleep(1_000)
        }
    }

    if proc.isRunning {
        Darwin.kill(proc.processIdentifier, SIGKILL)
        let killDeadlineNs = DispatchTime.now().uptimeNanoseconds + 50_000_000
        while proc.isRunning, DispatchTime.now().uptimeNanoseconds < killDeadlineNs {
            usleep(1_000)
        }
    }

    guard !proc.isRunning else { return nil }
    guard proc.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - File Hashing

func sha256Hash(ofFile path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "unknown" }
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
        _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Formatting

func writeJSONReport(_ report: BenchmarkReport, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: URL(fileURLWithPath: path))
}

func printMarkdownTable(_ report: BenchmarkReport) {
    print("")
    print("## \(report.config.suite.capitalized) Results")
    print("")
    print("Classification: **\(report.runClassification.uppercased())**")
    print("Intended usage: \(report.config.suiteIntendedUsage)")
    if !report.partialReasons.isEmpty {
        print("Partial reasons: \(report.partialReasons.joined(separator: "; "))")
    }
    print("")

    if report.suiteKind == "internal_microbenchmark" {
        print("| Editor | Class | Parse ms (min) | Layout ms (min) | Paint ms (min) | Open-ready ms (min) | Full-fidelity ms (min) |")
        print("| --- | --- | ---: | ---: | ---: | ---: | ---: |")

        for result in report.results {
            let parse = result.stats?.wowParseLatency.map { String(format: "%.0f", $0.min) } ?? "—"
            let layout = result.stats?.wowLayoutLatency.map { String(format: "%.0f", $0.min) } ?? "—"
            let paint = result.stats?.wowPaintReadyLatency.map { String(format: "%.0f", $0.min) } ?? "—"
            let openReady = result.stats?.wowOpenReadyLatency.map { String(format: "%.0f", $0.min) } ?? "—"
            let fullFidelity = result.stats?.wowFullDocumentFidelityReadyLatency.map { String(format: "%.0f", $0.min) } ?? "—"
            print("| \(result.editor) | \(result.runClassification) | \(parse) | \(layout) | \(paint) | \(openReady) | \(fullFidelity) |")
        }
    } else if report.suiteKind == "cross_editor_open_only" {
        print("| Editor | Class | Open ms (min) | Open ms (p50) | Automation overhead ms (p50) |")
        print("| --- | --- | ---: | ---: | ---: |")

        for result in report.results {
            let openMin = result.stats?.openLatency.map { String(format: "%.0f", $0.min) } ?? "—"
            let openP50 = result.stats?.openLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let automation = result.stats?.automationOverhead.map { String(format: "%.0f", $0.median) } ?? "—"
            print("| \(result.editor) | \(result.runClassification) | \(openMin) | \(openP50) | \(automation) |")
        }
    } else if report.suiteKind == "cross_editor_full_fidelity" {
        print("| Editor | Class | Open ms (p50) | Full-fidelity end-to-end ms (p50) | Full-fidelity end-to-end ms (p95) |")
        print("| --- | --- | ---: | ---: | ---: |")

        for result in report.results {
            let openP50 = result.stats?.openLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let fullP50 = result.stats?.fullFidelityEndToEndLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let fullP95 = result.stats?.fullFidelityEndToEndLatency.map { String(format: "%.0f", $0.p95) } ?? "—"
            print("| \(result.editor) | \(result.runClassification) | \(openP50) | \(fullP50) | \(fullP95) |")
        }
    } else {
        print("| Editor | Class | Open ms (p50) | Save UI ms (p50) | Quit ms (p50) |")
        print("| --- | --- | ---: | ---: | ---: |")

        for result in report.results {
            let open = result.stats?.openLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let saveUI = result.stats?.saveUiAckLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let quit = result.stats?.quitLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            print("| \(result.editor) | \(result.runClassification) | \(open) | \(saveUI) | \(quit) |")
        }
    }
    print("")
}

func printDetailedStats(_ report: BenchmarkReport) {
    print("Policy: \(report.config.rosterPolicy)")
    print("README/social headline claims require OFFICIAL runs only.")
    print("")

    for result in report.results {
        let versionStr = result.version.map { " v\($0)" } ?? ""
        print("--- \(result.editor)\(versionStr) ---")
        print("  Classification: \(result.runClassification), quality=\(result.runQuality)")
        if !result.partialReasons.isEmpty {
            print("  Reasons: \(result.partialReasons.joined(separator: "; "))")
        }

        func printMetric(_ label: String, _ stats: Stats?) {
            guard let stats else { return }
            let failureRate = stats.failureRatePct.map { String(format: "%.1f", $0) } ?? "0.0"
            print("  \(label): p50=\(stats.median) p95=\(stats.p95) p99=\(stats.p99) n=\(stats.n) fail%=\(failureRate)")
        }

        let s = result.stats
        printMetric("cold_start_latency_ms", s?.coldStartLatency)
        printMetric("warm_start_latency_ms", s?.warmStartLatency)
        printMetric("open_latency_ms", s?.openLatency)
        printMetric("typing_latency_ms", s?.typingLatency)
        printMetric("save_ui_ack_latency_ms", s?.saveUiAckLatency)
        printMetric("quit_latency_ms", s?.quitLatency)
        printMetric("wow_parse_latency_ms", s?.wowParseLatency)
        printMetric("wow_layout_latency_ms", s?.wowLayoutLatency)
        printMetric("wow_paint_ready_latency_ms", s?.wowPaintReadyLatency)
        printMetric("wow_edit_apply_latency_ms", s?.wowEditApplyLatency)
        printMetric("wow_save_serialize_latency_ms", s?.wowSaveSerializeLatency)
        printMetric("wow_open_ready_latency_ms", s?.wowOpenReadyLatency)
        printMetric("wow_viewport_semantic_ready_latency_ms", s?.wowViewportSemanticReadyLatency)
        printMetric("wow_viewport_fidelity_ready_latency_ms", s?.wowViewportFidelityReadyLatency)
        printMetric("wow_full_document_fidelity_ready_latency_ms", s?.wowFullDocumentFidelityReadyLatency)
        printMetric("full_fidelity_end_to_end_latency_ms", s?.fullFidelityEndToEndLatency)
        printMetric("automation_overhead_ms", s?.automationOverhead)
        printMetric("unattributed_open_budget_ms", s?.unattributedOpenBudget)
        printMetric("time_to_stable_layout_ms", s?.timeToStableLayout)
        printMetric("post_ready_export_quiescence_ms", s?.postReadyExportQuiescence)
        print("")
    }
}

func timestampISO8601() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}
