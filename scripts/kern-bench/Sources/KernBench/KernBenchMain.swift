import Darwin
import Foundation

// MARK: - Argument Parsing

struct BenchConfig {
    enum KernOpenMetricSource: String {
        case auto
        case wow
        case probe
    }

    enum ZedBenchHookMode: String {
        case auto
        case off
        case required
    }

    var suiteID: SuiteID = .benchmark
    var editors: [String] = []
    var allEditors = false
    var file = ""
    var runsOverride: Int?
    var warmupRunsOverride: Int?
    var startupProbeRuns: Int = 0
    var cold = false
    var jsonPath: String?
    var markdownPath: String?
    var timeout: TimeInterval = 30
    var runTimeout: TimeInterval = 45
    var suiteTimeout: TimeInterval = 7200
    var interEditorCooldownMs: Int = 0
    var postOpenDelayMs: Int = 0
    var saveDurable = false
    var noScreenCapture = false
    var enableFrameMonitor = false
    var enableWowMetrics = true
    var kernOpenMetricSource: KernOpenMetricSource = .auto
    var zedBenchHookMode: ZedBenchHookMode = .auto
    var zedBenchReadyMode = "first_editable"
    var verbose = false
}

func parseArgs() -> BenchConfig {
    var config = BenchConfig()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--suite":
            guard !args.isEmpty else { exitUsage("--suite requires a value") }
            let raw = args.removeFirst()
            let lowered = raw.lowercased()
            if ["wow", "real_use", "real-use", "realuse"].contains(lowered) {
                exitUsage("Legacy suite alias '\(raw)' is no longer accepted. Use benchmark, benchmark_open_ready, benchmark_full_fidelity, or wow_internal.")
            }
            guard let suite = SuiteID.parse(raw) else {
                exitUsage("Unknown suite: \(raw). Use benchmark, benchmark_open_ready, benchmark_full_fidelity, or wow_internal.")
            }
            if lowered != "benchmark", lowered != "bench" {
                if suite == .benchmark {
                    print("Note: '--suite \(raw)' is a legacy alias; using 'benchmark' single-benchmark mode.")
                }
            }
            config.suiteID = suite
        case "--editor":
            guard !args.isEmpty else { exitUsage("--editor requires a value") }
            config.editors.append(args.removeFirst())
        case "--all":
            config.allEditors = true
        case "--file":
            guard !args.isEmpty else { exitUsage("--file requires a value") }
            config.file = args.removeFirst()
        case "--runs":
            guard !args.isEmpty, let n = Int(args.removeFirst()), n > 0 else { exitUsage("--runs requires a positive integer") }
            config.runsOverride = n
        case "--warmup-runs":
            guard !args.isEmpty, let n = Int(args.removeFirst()), n >= 0 else { exitUsage("--warmup-runs requires a non-negative integer") }
            config.warmupRunsOverride = n
        case "--startup-probes":
            guard !args.isEmpty, let n = Int(args.removeFirst()), n >= 0 else { exitUsage("--startup-probes requires a non-negative integer") }
            config.startupProbeRuns = n
        case "--cold":
            config.cold = true
        case "--warm":
            config.cold = false
        case "--json":
            guard !args.isEmpty else { exitUsage("--json requires a path") }
            config.jsonPath = args.removeFirst()
        case "--markdown":
            guard !args.isEmpty else { exitUsage("--markdown requires a path") }
            config.markdownPath = args.removeFirst()
        case "--timeout":
            guard !args.isEmpty, let t = Double(args.removeFirst()), t > 0 else { exitUsage("--timeout requires a positive number") }
            config.timeout = t
        case "--run-timeout":
            guard !args.isEmpty, let t = Double(args.removeFirst()), t > 0 else { exitUsage("--run-timeout requires a positive number") }
            config.runTimeout = t
        case "--suite-timeout":
            guard !args.isEmpty, let t = Double(args.removeFirst()), t > 0 else { exitUsage("--suite-timeout requires a positive number") }
            config.suiteTimeout = t
        case "--inter-editor-delay-ms":
            guard !args.isEmpty, let ms = Int(args.removeFirst()), ms >= 0 else { exitUsage("--inter-editor-delay-ms requires a non-negative integer") }
            config.interEditorCooldownMs = ms
        case "--post-open-delay-ms":
            guard !args.isEmpty, let ms = Int(args.removeFirst()), ms >= 0 else { exitUsage("--post-open-delay-ms requires a non-negative integer") }
            config.postOpenDelayMs = ms
        case "--save-durable":
            config.saveDurable = true
        case "--no-screencapture":
            config.noScreenCapture = true
        case "--enable-frame-monitor":
            config.enableFrameMonitor = true
        case "--disable-wow-metrics":
            config.enableWowMetrics = false
        case "--kern-open-metric-source":
            guard !args.isEmpty else { exitUsage("--kern-open-metric-source requires auto|wow|probe") }
            let sourceRaw = args.removeFirst().lowercased()
            guard let source = BenchConfig.KernOpenMetricSource(rawValue: sourceRaw) else {
                exitUsage("--kern-open-metric-source must be auto, wow, or probe")
            }
            config.kernOpenMetricSource = source
        case "--zed-bench-hook":
            guard !args.isEmpty else { exitUsage("--zed-bench-hook requires auto|off|required") }
            let modeRaw = args.removeFirst().lowercased()
            guard let mode = BenchConfig.ZedBenchHookMode(rawValue: modeRaw) else {
                exitUsage("--zed-bench-hook must be auto, off, or required")
            }
            config.zedBenchHookMode = mode
        case "--zed-ready-mode":
            guard !args.isEmpty else { exitUsage("--zed-ready-mode requires a value") }
            let mode = args.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mode.isEmpty else { exitUsage("--zed-ready-mode cannot be empty") }
            config.zedBenchReadyMode = mode
        case "--verbose", "-v":
            config.verbose = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            if config.file.isEmpty && !arg.hasPrefix("-") {
                config.file = arg
            } else {
                exitUsage("Unknown argument: \(arg)")
            }
        }
    }

    return config
}

func printUsage() {
    let usage = """
    kern-bench — Cross-editor benchmark tool

    USAGE:
      kern-bench [options] [file]

    OPTIONS:
      --suite <benchmark|benchmark_open_ready|benchmark_full_fidelity|wow_internal>
                               Benchmark mode (default: benchmark)
      --editor <name>          Benchmark a specific editor (can repeat)
      --all                    Benchmark all installed roster editors
      --file <path>            Test file to open in each editor
      --runs <n>               Number of measured runs (suite default if omitted)
      --warmup-runs <n>        Warmup runs (suite default if omitted)
      --startup-probes <n>     Cold+warm startup probe repetitions per editor (default: 0)
      --cold                   Purge filesystem cache between measured runs
      --warm                   Warm mode (default)
      --json <path>            Write JSON results to file
      --markdown <path>        Write markdown table to file
      --timeout <seconds>      Per-stage timeout (default: 30)
      --run-timeout <seconds>  Per editor-run timeout budget (default: 45)
      --suite-timeout <sec>    Overall suite timeout budget (default: 7200)
      --inter-editor-delay-ms  Delay between editors in a round (default: 0)
      --post-open-delay-ms     Debug delay after open-readiness stage (default: 0)
      --save-durable           Collect durable-save metric (disabled by default for speed)
      --no-screencapture       Disable ScreenCaptureKit
      --enable-frame-monitor   Enable optional first-paint/render-stable probes
      --disable-wow-metrics    Disable Kern WOW internal metric env injection
      --kern-open-metric-source <mode>
                               Kern open metric source: auto|wow|probe (default: auto)
      --zed-bench-hook <mode>  Zed bench-hook mode: auto|off|required (default: auto)
      --zed-ready-mode <mode>  Zed bench-ready mode label (default: first_editable)
      --verbose, -v            Print per-stage details
      --help, -h               Show this help

    EXAMPLES:
      kern-bench --suite benchmark --all
      kern-bench --suite wow_internal --editor Kern
      kern-bench --suite benchmark_open_ready --editor Kern --editor Zed --file test-fixtures/native-editor-benchmark.md
      kern-bench --suite benchmark_full_fidelity --editor Kern --editor Zed --file test-fixtures/native-editor-benchmark.md
      sudo kern-bench --suite benchmark --all --cold --runs 30 --json results.json
      kern-bench --suite benchmark_open_ready --editor Zed --runs 1 --post-open-delay-ms 4000
    """
    print(usage)
}

func exitUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    printUsage()
    exit(1)
}

// MARK: - Main

@main
struct KernBench {
    static func main() async {
        var config = parseArgs()
        let suite = SuiteDefinition.forID(config.suiteID)

        if suite.id == .benchmarkFullFidelity {
            if config.zedBenchHookMode == .auto {
                config.zedBenchHookMode = .required
            }
            if config.zedBenchReadyMode.trimmingCharacters(in: .whitespacesAndNewlines) == "first_editable" {
                config.zedBenchReadyMode = "styled_stable"
            }
            if config.kernOpenMetricSource == .auto {
                config.kernOpenMetricSource = .wow
            }
        }

        let runs = config.runsOverride ?? suite.defaultRuns
        let warmupRuns = config.warmupRunsOverride ?? suite.defaultWarmupRuns

        if config.file.isEmpty {
            let candidates: [String]
            if suite.id == .wowInternal {
                candidates = [
                    "test-fixtures/cross-editor-benchmark.md",
                    "../../test-fixtures/cross-editor-benchmark.md",
                    "test-fixtures/native-editor-benchmark.md",
                    "../../test-fixtures/native-editor-benchmark.md",
                ]
            } else if suite.id == .benchmarkOpenReady || suite.id == .benchmarkFullFidelity {
                candidates = [
                    "test-fixtures/native-editor-benchmark.md",
                    "../../test-fixtures/native-editor-benchmark.md",
                    "test-fixtures/cross-editor-benchmark.md",
                    "../../test-fixtures/cross-editor-benchmark.md",
                ]
            } else {
                candidates = [
                    "test-fixtures/cross-editor-benchmark.md",
                    "../../test-fixtures/cross-editor-benchmark.md",
                ]
            }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                config.file = candidate
                break
            }
            if config.file.isEmpty {
                exitUsage("No test file specified and default not found. Use --file <path>.")
            }
        }

        let fileURL = URL(fileURLWithPath: config.file).standardizedFileURL
        config.file = fileURL.path

        guard FileManager.default.fileExists(atPath: config.file) else {
            exitUsage("File not found: \(config.file)")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: config.file)[.size] as? Int) ?? 0
        let fileHash = sha256Hash(ofFile: config.file)
        let archiveDirectory = createCanonicalArchiveDirectory(for: suite)
        let archiveJSONPath = URL(fileURLWithPath: archiveDirectory).appendingPathComponent("results.json").path
        let archiveMarkdownPath = URL(fileURLWithPath: archiveDirectory).appendingPathComponent("results.md").path
        let archiveEnvPath = URL(fileURLWithPath: archiveDirectory).appendingPathComponent("env.json").path

        var editors: [EditorDefinition]
        if config.allEditors || config.editors.isEmpty {
            editors = detectInstalledEditors()
        } else {
            editors = config.editors.compactMap { name in
                guard let ed = findEditor(named: name) else {
                    print("Warning: Editor '\(name)' not recognized. Skipping.")
                    return nil
                }
                guard isEditorInstalled(ed) else {
                    print("Warning: \(ed.displayName) not installed. Skipping.")
                    return nil
                }
                return ed
            }
        }

        guard !editors.isEmpty else {
            print("No roster editors found. Install at least one roster target editor.")
            exit(1)
        }

        let requiredRosterSet = Set(suite.requiredRoster)
        if !requiredRosterSet.isEmpty {
            editors = editors.filter { requiredRosterSet.contains($0.displayName) }
        }

        guard !editors.isEmpty else {
            print("No required editors found for suite '\(suite.id.rawValue)'. Required: \(suite.requiredRoster.joined(separator: ", "))")
            exit(1)
        }

        // Keep deterministic order for final reporting; measured rounds still shuffle.
        editors.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        var screencaptureAvailable = false
        if config.enableFrameMonitor && !config.noScreenCapture {
            screencaptureAvailable = await checkScreenCapturePermission()
            if !screencaptureAvailable {
                print("Note: Screen Recording permission not granted. Frame-monitor diagnostics disabled.")
                print("")
            }
        }

        let accessibilityAvailable = hasAccessibilityPermission()
        if !accessibilityAvailable {
            print("Note: Accessibility permission not granted. Save/quit automation may fail.")
            print("")
        }

        let env = detectEnvironment(
            screencaptureAvailable: config.enableFrameMonitor && !config.noScreenCapture ? screencaptureAvailable : false,
            accessibilityAvailable: accessibilityAvailable
        )

        let selectedNames = Set(editors.map(\.displayName))
        let requiredNames = Set(suite.requiredRoster)
        let rosterComplete = requiredNames.isEmpty ? true : (selectedNames == requiredNames)

        // Header
        print("=== kern-bench: Cross-Editor Benchmark ===")
        print("Suite:   \(suite.displayName) [\(suite.id.rawValue)]")
        print("Usage:   \(suite.intendedUsage)")
        let rosterPolicyDescription = suite.requiredRoster.isEmpty
            ? "unlocked roster (selected editors)"
            : "locked roster (\(suite.requiredRoster.joined(separator: ", ")))"
        print("Policy:  \(rosterPolicyDescription)")
        print("Claims:  README/social headline claims require OFFICIAL runs only")
        print("File:    \(config.file) (\(fileSize) bytes)")
        print("SHA256:  \(fileHash)")
        print("Runs:    \(runs) (\(config.cold ? "cold" : "warm"), \(warmupRuns) warmup)")
        print("Timeout: stage=\(Int(config.timeout))s run=\(Int(config.runTimeout))s suite=\(Int(config.suiteTimeout))s")
        if config.postOpenDelayMs > 0 {
            print("Debug:   post-open delay=\(config.postOpenDelayMs)ms")
        }
        print("SaveDur: \(config.saveDurable ? "enabled" : "disabled")")
        print("WOWMet:  \(config.enableWowMetrics ? "enabled" : "disabled")")
        print("KernOpn: \(config.kernOpenMetricSource.rawValue)")
        print("ZedHook: \(config.zedBenchHookMode.rawValue) (\(config.zedBenchReadyMode))")
        if selectedNames.contains("Zed") {
            let zedCLI = resolveZedCLICommand(defaultCommand: ["zed"])
            switch zedCLI.source {
            case .envOverride:
                print("ZedCLI:  env override (\(zedCLI.resolvedPath ?? "unknown"))")
            case .autoFork:
                print("ZedCLI:  auto fork (\(zedCLI.resolvedPath ?? "unknown"))")
            case .defaultCLI:
                print("ZedCLI:  default (\(zedCLI.resolvedPath ?? "zed"))")
            }
        }
        print("Order:   shuffled (interleaved)")
        print("Chip:    \(env.chip)")
        print("macOS:   \(env.macos)")
        print("Power:   \(env.power)")
        print("Thermal: \(env.thermalPct)%")
        if let display = env.display {
            print("Display: \(display)")
        }
        print("Screen:  \(config.enableFrameMonitor ? (screencaptureAvailable ? "available" : "unavailable") : "disabled")")
        print("FrameMon:\(config.enableFrameMonitor ? " enabled" : " disabled")")
        print("AX:      \(accessibilityAvailable ? "available" : "missing")")
        print("Roster:  \(rosterComplete ? "complete" : "incomplete")")
        print("Archive: \(archiveDirectory)")
        print("")

        let editorNames = editors.map { ed in
            let v = editorVersion(ed).map { " v\($0)" } ?? ""
            return "\(ed.displayName)\(v)"
        }
        print("Editors: \(editorNames.joined(separator: ", "))")
        print("")

        var launchers: [String: EditorLauncher] = [:]
        var collectors: [String: MetricCollector] = [:]
        var editorResults: [String: EditorResult] = [:]

        for editor in editors {
            launchers[editor.displayName] = EditorLauncher(editor: editor)
            collectors[editor.displayName] = MetricCollector()
            editorResults[editor.displayName] = EditorResult(
                editor: editor.displayName,
                architecture: editor.architecture,
                version: editorVersion(editor),
                runQuality: RunQuality.complete.rawValue,
                runClassification: RunClassification.official.rawValue,
                partialReasons: [],
                runs: [],
                stats: nil
            )
        }

        // Ensure clean baseline.
        for editor in editors {
            await launchers[editor.displayName]?.kill()
        }

        var editorLaunchability: [String: (runnable: Bool, reason: String?)] = [:]

        // Preflight startup probes for both cold and warm start latency metrics.
        let startupProbeRuns = config.startupProbeRuns
        if startupProbeRuns > 0 {
            print("Preflight startup probes (\(startupProbeRuns)x cold + \(startupProbeRuns)x warm per editor)...")
            for editor in editors {
                guard let launcher = launchers[editor.displayName], var collector = collectors[editor.displayName] else { continue }
                for _ in 0..<startupProbeRuns {
                    let coldProbe = await startupProbe(
                        launcher: launcher,
                        file: config.file,
                        timeout: suite.stageTimeouts["startup"] ?? config.timeout,
                        cold: true,
                        purgeFSCache: config.cold,
                        verbose: config.verbose,
                        editorName: editor.displayName
                    )
                    collector.record(metric: "cold_start_latency_ms", value: coldProbe.valueMs, failureReason: coldProbe.failureReason, timedOut: coldProbe.timedOut)
                }

                for _ in 0..<startupProbeRuns {
                    let warmProbe = await startupProbe(
                        launcher: launcher,
                        file: config.file,
                        timeout: suite.stageTimeouts["startup"] ?? config.timeout,
                        cold: false,
                        purgeFSCache: false,
                        verbose: config.verbose,
                        editorName: editor.displayName
                    )
                    collector.record(metric: "warm_start_latency_ms", value: warmProbe.valueMs, failureReason: warmProbe.failureReason, timedOut: warmProbe.timedOut)
                }
                collectors[editor.displayName] = collector
            }
            print("Preflight startup probes complete.")
            print("")
        } else {
            print("Preflight startup probes skipped (--startup-probes 0).")
            print("")
        }

        print("Preflight launchability check (fast fail for unlaunchable editors)...")
        let launchabilityTimeout = max(
            1.5,
            min(suite.stageTimeouts["open"] ?? config.timeout, config.runTimeout * 0.6)
        )
        var semNamespaceProbe: PosixSemaphoreNamespaceProbe?
        for editor in editors {
            guard let launcher = launchers[editor.displayName] else { continue }
            let check = await launchabilityProbe(
                launcher: launcher,
                file: config.file,
                timeout: launchabilityTimeout,
                editorName: editor.displayName
            )
            if check.valueMs != nil {
                editorLaunchability[editor.displayName] = (true, nil)
                continue
            }

            let reason = check.failureReason ?? "editor_unlaunchable"
            if reason == "process_exited_before_window" || reason == "launch_failed" {
                if semNamespaceProbe == nil {
                    semNamespaceProbe = probePosixSemaphoreNamespace()
                }
                if let probe = semNamespaceProbe, probe.exhausted {
                    print("  [diag] POSIX semaphore namespace exhausted (created \(probe.createdSlots) probe slots before ENOSPC)")
                }
            }
            // Keep preflight informational. Real launchability is determined by measured runs
            // with full retry/timeout handling, which is more robust than a single probe.
            editorLaunchability[editor.displayName] = (true, reason)
            print("  [\(editor.displayName)] preflight warning: \(reason) (continuing)")
        }
        print("")

        if !config.cold && warmupRuns > 0 {
            print("Warmup (\(warmupRuns) runs per editor)...")
            for _ in 0..<warmupRuns {
                for editor in editors {
                    if let availability = editorLaunchability[editor.displayName],
                       !availability.runnable {
                        continue
                    }
                    let launcher = launchers[editor.displayName]!
                    await launcher.kill()
                    let runFile = prepareRunFixtureCopy(sourceFile: config.file, editorName: editor.displayName, runIndex: -1)
                    guard let result = try? await launcher.launch(file: runFile), result.pid > 0 else { continue }
                    _ = await waitForWindow(
                        pid: result.pid,
                        timeout: config.timeout,
                        expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent
                    )
                    await launcher.kill()
                    try? FileManager.default.removeItem(atPath: runFile)
                }
            }
            print("Warmup complete.")
            print("")
        }

        // Measured runs.
        var measuredThermals: [Int] = [env.thermalPct]
        let suiteStartNs = monotonicNowNs()
        let suiteDeadlineNs = suiteStartNs + UInt64(config.suiteTimeout * 1_000_000_000)
        var suiteTimedOut = false

        runLoop: for runIdx in 1...runs {
            if monotonicNowNs() >= suiteDeadlineNs {
                suiteTimedOut = true
                break
            }

            let roundThermal = detectThermalPct()
            let roundPower = detectPowerSource()
            measuredThermals.append(roundThermal)

            let shuffledEditors = editors.shuffled()
            print("Round \(runIdx)/\(runs): \(shuffledEditors.map(\.displayName).joined(separator: ", "))")

            for (editorIdx, editor) in shuffledEditors.enumerated() {
                if monotonicNowNs() >= suiteDeadlineNs {
                    suiteTimedOut = true
                    break runLoop
                }

                guard let launcher = launchers[editor.displayName],
                      var result = editorResults[editor.displayName],
                      var collector = collectors[editor.displayName]
                else { continue }

                await launcher.kill()
                if config.cold {
                    _ = runProcess(path: "/usr/sbin/purge", args: [])
                    try? await Task.sleep(for: .seconds(2))
                }

                let runStartNs = monotonicNowNs()
                let runDeadlineNs = runStartNs + UInt64(config.runTimeout * 1_000_000_000)
                let runFile = prepareRunFixtureCopy(sourceFile: config.file, editorName: editor.displayName, runIndex: runIdx)
                let wowMetricsPath = config.enableWowMetrics && editor.displayName == "Kern"
                    ? URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("kern-wow-metrics-\(runIdx)-\(UUID().uuidString).json")
                        .path
                    : nil
                let zedBenchHookSignalPath = editor.displayName == "Zed" && config.zedBenchHookMode != .off
                    ? URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("zed-bench-ready-\(runIdx)-\(UUID().uuidString).json")
                        .path
                    : nil
                var failureReasons: [String: String] = [:]
                var timeoutCount = 0
                var failureCount = 0
                let runThermal = roundThermal
                let runPower = roundPower
                let cycleMetrics: [String] = {
                    if suite.id == .wowInternal {
                        return [
                            "wow_parse_latency_ms",
                            "wow_layout_latency_ms",
                            "wow_paint_ready_latency_ms",
                            "wow_edit_apply_latency_ms",
                            "wow_save_serialize_latency_ms",
                            "wow_open_ready_latency_ms",
                            "wow_viewport_semantic_ready_latency_ms",
                            "wow_viewport_fidelity_ready_latency_ms",
                            "wow_full_document_fidelity_ready_latency_ms",
                        ]
                    }
                    if suite.id == .benchmarkOpenReady {
                        return ["open_latency_ms"]
                    }
                    if suite.id == .benchmarkFullFidelity {
                        return ["full_fidelity_end_to_end_latency_ms"]
                    }
                    return ["open_latency_ms", "save_ui_ack_latency_ms", "quit_latency_ms"]
                }()

                func stageBudget(stage: String) -> TimeInterval {
                    let defaultTimeout = suite.stageTimeouts[stage] ?? config.timeout
                    let now = monotonicNowNs()
                    if now >= runDeadlineNs || now >= suiteDeadlineNs {
                        return 0
                    }
                    let runRemaining = Double(runDeadlineNs - now) / 1_000_000_000
                    let suiteRemaining = Double(suiteDeadlineNs - now) / 1_000_000_000
                    return max(0, min(defaultTimeout, runRemaining, suiteRemaining))
                }

                func deadlineReason() -> String {
                    if monotonicNowNs() >= suiteDeadlineNs {
                        return "suite_timeout"
                    }
                    if monotonicNowNs() >= runDeadlineNs {
                        return "run_timeout"
                    }
                    return "run_budget_exhausted"
                }

                func appendRun(
                    openLatencyMs: Double?,
                    typingLatencyMs: Double?,
                    saveUiAckMs: Double?,
                    saveDurableMs: Double?,
                    quitLatencyMs: Double?,
                    windowVisibleMs: Double?,
                    firstPaintMs: Double?,
                    renderStableMs: Double?,
                    wowParseLatencyMs: Double?,
                    wowLayoutLatencyMs: Double?,
                    wowPaintReadyLatencyMs: Double?,
                    wowEditApplyLatencyMs: Double?,
                    wowSaveSerializeLatencyMs: Double?,
                    wowOpenReadyLatencyMs: Double?,
                    wowViewportSemanticReadyLatencyMs: Double?,
                    wowViewportFidelityReadyLatencyMs: Double?,
                    wowFullDocumentFidelityReadyLatencyMs: Double?,
                    fullFidelityEndToEndLatencyMs: Double?,
                    automationOverheadMs: Double?,
                    unattributedOpenBudgetMs: Double?,
                    timeToStableLayoutMs: Double?,
                    postReadyExportQuiescenceMs: Double?
                ) {
                    // Single source of truth: suite.requiredMetrics.
                    // Startup metrics are collected via preflight probes rather than each measured run.
                    let runRequiredMetrics = suite.requiredMetrics.filter {
                        $0 != "cold_start_latency_ms" && $0 != "warm_start_latency_ms"
                    }
                    let metricValueMap: [String: Double?] = [
                        "open_latency_ms": openLatencyMs,
                        "typing_latency_ms": typingLatencyMs,
                        "save_ui_ack_latency_ms": saveUiAckMs,
                        "quit_latency_ms": quitLatencyMs,
                        "wow_parse_latency_ms": wowParseLatencyMs,
                        "wow_layout_latency_ms": wowLayoutLatencyMs,
                        "wow_paint_ready_latency_ms": wowPaintReadyLatencyMs,
                        "wow_edit_apply_latency_ms": wowEditApplyLatencyMs,
                        "wow_save_serialize_latency_ms": wowSaveSerializeLatencyMs,
                        "wow_open_ready_latency_ms": wowOpenReadyLatencyMs,
                        "wow_viewport_semantic_ready_latency_ms": wowViewportSemanticReadyLatencyMs,
                        "wow_viewport_fidelity_ready_latency_ms": wowViewportFidelityReadyLatencyMs,
                        "wow_full_document_fidelity_ready_latency_ms": wowFullDocumentFidelityReadyLatencyMs,
                        "full_fidelity_end_to_end_latency_ms": fullFidelityEndToEndLatencyMs,
                    ]
                    let requiredMissing = runRequiredMetrics.contains { metric in
                        (metricValueMap[metric] ?? nil) == nil
                    }
                    let runQuality: RunQuality = requiredMissing ? .degraded : .complete

                    let run = RunResult(
                        runIndex: runIdx,
                        coldStartLatencyMs: nil,
                        warmStartLatencyMs: nil,
                        openLatencyMs: openLatencyMs,
                        saveUiAckLatencyMs: saveUiAckMs,
                        saveDurableLatencyMs: saveDurableMs,
                        quitLatencyMs: quitLatencyMs,
                        typingLatencyMs: typingLatencyMs,
                        findLatencyMs: nil,
                        scrollSettleLatencyMs: nil,
                        scrollEffectiveFPS: nil,
                        scrollP95FrameTimeMs: nil,
                        scrollP99FrameTimeMs: nil,
                        scrollHitchMsPerS: nil,
                        scrollJank33msCount: nil,
                        scrollJank50msCount: nil,
                        windowVisibleMs: windowVisibleMs,
                        firstPaintMs: firstPaintMs,
                        renderStableMs: renderStableMs,
                        memoryPhysMB: nil,
                        memoryRssMB: nil,
                        wowParseLatencyMs: wowParseLatencyMs,
                        wowLayoutLatencyMs: wowLayoutLatencyMs,
                        wowPaintReadyLatencyMs: wowPaintReadyLatencyMs,
                        wowEditApplyLatencyMs: wowEditApplyLatencyMs,
                        wowSaveSerializeLatencyMs: wowSaveSerializeLatencyMs,
                        wowOpenReadyLatencyMs: wowOpenReadyLatencyMs,
                        wowViewportSemanticReadyLatencyMs: wowViewportSemanticReadyLatencyMs,
                        wowViewportFidelityReadyLatencyMs: wowViewportFidelityReadyLatencyMs,
                        wowFullDocumentFidelityReadyLatencyMs: wowFullDocumentFidelityReadyLatencyMs,
                        fullFidelityEndToEndLatencyMs: fullFidelityEndToEndLatencyMs,
                        automationOverheadMs: automationOverheadMs,
                        unattributedOpenBudgetMs: unattributedOpenBudgetMs,
                        timeToStableLayoutMs: timeToStableLayoutMs,
                        postReadyExportQuiescenceMs: postReadyExportQuiescenceMs,
                        runQuality: runQuality.rawValue,
                        stageTimeoutCount: timeoutCount,
                        stageFailureCount: failureCount,
                        metricFailureReasons: failureReasons,
                        scrollMetricMode: nil,
                        thermalPct: runThermal,
                        power: runPower
                    )
                    result.runs.append(run)
                }

                func recordCycleFailure(reason: String, timedOut: Bool, includeWindowMetric: Bool = false) {
                    for metric in cycleMetrics {
                        collector.record(metric: metric, value: nil, failureReason: reason, timedOut: timedOut)
                        failureReasons[metric] = reason
                        failureCount += 1
                        if timedOut {
                            timeoutCount += 1
                        }
                    }
                    if includeWindowMetric {
                        collector.record(metric: "window_visible_ms", value: nil, failureReason: reason, timedOut: timedOut)
                        failureReasons["window_visible_ms"] = reason
                        failureCount += 1
                        if timedOut {
                            timeoutCount += 1
                        }
                    }
                    appendRun(
                        openLatencyMs: nil,
                        typingLatencyMs: nil,
                        saveUiAckMs: nil,
                        saveDurableMs: nil,
                        quitLatencyMs: nil,
                        windowVisibleMs: nil,
                        firstPaintMs: nil,
                        renderStableMs: nil,
                        wowParseLatencyMs: nil,
                        wowLayoutLatencyMs: nil,
                        wowPaintReadyLatencyMs: nil,
                        wowEditApplyLatencyMs: nil,
                        wowSaveSerializeLatencyMs: nil,
                        wowOpenReadyLatencyMs: nil,
                        wowViewportSemanticReadyLatencyMs: nil,
                        wowViewportFidelityReadyLatencyMs: nil,
                        wowFullDocumentFidelityReadyLatencyMs: nil,
                        fullFidelityEndToEndLatencyMs: nil,
                        automationOverheadMs: nil,
                        unattributedOpenBudgetMs: nil,
                        timeToStableLayoutMs: nil,
                        postReadyExportQuiescenceMs: nil
                    )
                }

                func markFailure(_ metric: String, _ stage: StageResult) {
                    if let reason = stage.failureReason {
                        failureReasons[metric] = reason
                        failureCount += 1
                    }
                    if stage.timedOut {
                        timeoutCount += 1
                    }
                }

                func normalizedDeadlineStage(_ stage: StageResult) -> StageResult {
                    normalizeStageTimeoutReason(
                        stage,
                        nowNs: monotonicNowNs(),
                        runDeadlineNs: runDeadlineNs,
                        suiteDeadlineNs: suiteDeadlineNs,
                        replacementReason: deadlineReason()
                    )
                }

                if let availability = editorLaunchability[editor.displayName],
                   !availability.runnable {
                    let reason = availability.reason ?? "editor_unlaunchable"
                    print("  [\(editor.displayName)] run \(runIdx): skipped (\(reason))")
                    recordCycleFailure(reason: reason, timedOut: false)
                    collectors[editor.displayName] = collector
                    editorResults[editor.displayName] = result
                    try? FileManager.default.removeItem(atPath: runFile)
                    if let wowMetricsPath {
                        try? FileManager.default.removeItem(atPath: wowMetricsPath)
                    }
                    if let zedBenchHookSignalPath {
                        try? FileManager.default.removeItem(atPath: zedBenchHookSignalPath)
                    }
                    if editorIdx < shuffledEditors.count - 1, config.interEditorCooldownMs > 0 {
                        try? await Task.sleep(for: .milliseconds(config.interEditorCooldownMs))
                    }
                    continue
                }

                var launchResult: LaunchResult?
                var window: DetectedWindow?
                var launchWindowFailureReason: String?
                var launchWindowTimedOut = false
                var launchedWithZedBenchHook = false

                let zedHookArgs: [String] = {
                    guard let zedBenchHookSignalPath else { return [] }
                    return [
                        "--bench-target-file", runFile,
                        "--bench-ready-signal", zedBenchHookSignalPath,
                        "--bench-ready-mode", config.zedBenchReadyMode,
                    ]
                }()

                func launchArgs(forAttempt attempt: Int) -> [String] {
                    guard editor.displayName == "Zed", !zedHookArgs.isEmpty else { return [] }
                    switch config.zedBenchHookMode {
                    case .required:
                        return zedHookArgs
                    case .auto:
                        // Retry without hook args for compatibility with non-hooked Zed builds.
                        return attempt == 1 ? zedHookArgs : []
                    case .off:
                        return []
                    }
                }

                attemptLoop: for attempt in 1...2 {
                    let retryTag = attempt > 1 ? " (retry \(attempt)/2)" : ""
                    print("  [\(editor.displayName)] run \(runIdx): launch\(retryTag)")
                    let launchEnv: [String: String] = {
                        guard let wowMetricsPath else { return [:] }
                        return ["KERN_WOW_INTERNAL_METRICS_PATH": wowMetricsPath]
                    }()
                    let perAttemptLaunchArgs = launchArgs(forAttempt: attempt)
                    launchedWithZedBenchHook = !perAttemptLaunchArgs.isEmpty
                    guard let candidate = try? await launcher.launch(
                        file: runFile,
                        env: launchEnv,
                        additionalArgs: perAttemptLaunchArgs
                    ), candidate.pid > 0 else {
                        if attempt < 2 {
                            print("  [\(editor.displayName)] run \(runIdx): launch failed, retrying")
                            await launcher.kill()
                            continue attemptLoop
                        }
                        launchWindowFailureReason = "launch_failed"
                        break attemptLoop
                    }

                    if monotonicNowNs() >= runDeadlineNs || monotonicNowNs() >= suiteDeadlineNs {
                        launchWindowFailureReason = deadlineReason()
                        launchWindowTimedOut = true
                        break attemptLoop
                    }

                    print("  [\(editor.displayName)] run \(runIdx): wait window\(retryTag)")
                    let attemptsRemaining = max(1, 2 - attempt + 1)
                    let nowNs = monotonicNowNs()
                    let runRemaining = nowNs < runDeadlineNs ? Double(runDeadlineNs - nowNs) / 1_000_000_000 : 0
                    let suiteRemaining = nowNs < suiteDeadlineNs ? Double(suiteDeadlineNs - nowNs) / 1_000_000_000 : 0
                    let remainingBudget = max(0.05, min(runRemaining, suiteRemaining))
                    let perAttemptBudget = max(0.05, remainingBudget / Double(attemptsRemaining))
                    let windowTimeout = min(stageBudget(stage: "open"), perAttemptBudget)
                    if let detected = await waitForWindow(
                        pid: candidate.pid,
                        timeout: windowTimeout,
                        expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent
                    ) {
                        launchResult = candidate
                        window = detected
                        break attemptLoop
                    }

                    let reason = !processIsAlive(candidate.pid) ? "process_exited_before_window" :
                        (monotonicNowNs() >= suiteDeadlineNs ? "suite_timeout" :
                        (monotonicNowNs() >= runDeadlineNs ? "run_timeout" : "open_timeout")
                        )
                    if attempt < 2, reason != "suite_timeout" {
                        print("  [\(editor.displayName)] run \(runIdx): \(reason) waiting for window, retrying")
                        await launcher.kill()
                        continue attemptLoop
                    }

                    launchWindowFailureReason = reason
                    launchWindowTimedOut = reason.contains("timeout")
                    break attemptLoop
                }

                guard let launchResult, let window else {
                    let reason = launchWindowFailureReason ?? "launch_or_window_failed"
                    if reason == "launch_failed" {
                        print("  [\(editor.displayName)] run \(runIdx): launch failed")
                    } else {
                        print("  [\(editor.displayName)] run \(runIdx): \(reason) waiting for window")
                    }
                    await launcher.kill()
                    recordCycleFailure(
                        reason: reason,
                        timedOut: launchWindowTimedOut,
                        includeWindowMetric: launchWindowTimedOut
                    )
                    collectors[editor.displayName] = collector
                    editorResults[editor.displayName] = result
                    try? FileManager.default.removeItem(atPath: runFile)
                    if let wowMetricsPath {
                        try? FileManager.default.removeItem(atPath: wowMetricsPath)
                    }
                    if let zedBenchHookSignalPath {
                        try? FileManager.default.removeItem(atPath: zedBenchHookSignalPath)
                    }
                    continue
                }

                let t0 = launchResult.launchNs
                let pid = launchResult.pid

                let windowVisibleMs = Double(window.timestampNs - t0) / 1_000_000
                collector.record(metric: "window_visible_ms", value: windowVisibleMs)

                var firstPaintMs: Double?
                var renderStableMs: Double?
                var frameMonitorTask: Task<FrameTimestamps, Never>?
                var wowParseLatencyMs: Double?
                var wowLayoutLatencyMs: Double?
                var wowPaintReadyLatencyMs: Double?
                var wowEditApplyLatencyMs: Double?
                var wowSaveSerializeLatencyMs: Double?
                var wowOpenReadyLatencyMs: Double?
                var wowViewportSemanticReadyLatencyMs: Double?
                var wowViewportFidelityReadyLatencyMs: Double?
                var wowFullDocumentFidelityReadyLatencyMs: Double?
                var fullFidelityEndToEndLatencyMs: Double?
                var preloadedWowMetrics: WowInternalMetricsPayload?

                if config.enableFrameMonitor && screencaptureAvailable && !config.noScreenCapture && !editor.isElectron {
                    print("  [\(editor.displayName)] run \(runIdx): frame monitor")
                    // Run frame monitoring concurrently with open readiness to avoid
                    // inflating open-latency measurements with frame-capture overhead.
                    let frameProbeTimeout = min(1.2, stageBudget(stage: "open"))
                    frameMonitorTask = Task {
                        let monitor = FrameMonitor(timeout: frameProbeTimeout)
                        return await monitor.monitor(windowID: window.windowID)
                    }
                }

                let actionRunner = ActionRunner(
                    editor: editor,
                    pid: pid,
                    windowID: window.windowID,
                    accessibilityAvailable: accessibilityAvailable,
                    verbose: config.verbose
                )

                let openBudget = stageBudget(stage: "open")
                if openBudget <= 0 {
                    print("  [\(editor.displayName)] run \(runIdx): \(deadlineReason()) before open")
                    await launcher.kill()
                    recordCycleFailure(reason: deadlineReason(), timedOut: true, includeWindowMetric: true)
                    collectors[editor.displayName] = collector
                    editorResults[editor.displayName] = result
                    try? FileManager.default.removeItem(atPath: runFile)
                    if let wowMetricsPath {
                        try? FileManager.default.removeItem(atPath: wowMetricsPath)
                    }
                    if let zedBenchHookSignalPath {
                        try? FileManager.default.removeItem(atPath: zedBenchHookSignalPath)
                    }
                    continue
                }

                print("  [\(editor.displayName)] run \(runIdx): open readiness")
                let openStage: StageResult
                let openLatencyMs: Double?
                let shouldUseKernWowOpenSource: Bool = {
                    guard editor.displayName == "Kern" else { return false }
                    switch config.kernOpenMetricSource {
                    case .wow:
                        return true
                    case .probe:
                        return false
                    case .auto:
                        return suite.id == .benchmarkOpenReady || suite.id == .benchmark
                    }
                }()

                if shouldUseKernWowOpenSource,
                   editor.displayName == "Kern",
                   let wowMetricsPath {
                    preloadedWowMetrics = await waitForWowInternalMetrics(
                        path: wowMetricsPath,
                        timeout: max(0.2, openBudget),
                        requireAllMetrics: false,
                        requiredMetricKeys: ["wow_open_ready_latency_ms"]
                    )
                    wowParseLatencyMs = preloadedWowMetrics?.metrics["wow_parse_latency_ms"]
                    wowLayoutLatencyMs = preloadedWowMetrics?.metrics["wow_layout_latency_ms"]
                    wowPaintReadyLatencyMs = preloadedWowMetrics?.metrics["wow_paint_ready_latency_ms"]
                    wowEditApplyLatencyMs = preloadedWowMetrics?.metrics["wow_edit_apply_latency_ms"]
                    wowSaveSerializeLatencyMs = preloadedWowMetrics?.metrics["wow_save_serialize_latency_ms"]
                    wowOpenReadyLatencyMs = preloadedWowMetrics?.metrics["wow_open_ready_latency_ms"]
                    wowViewportSemanticReadyLatencyMs = preloadedWowMetrics?.metrics["wow_viewport_semantic_ready_latency_ms"]
                    wowViewportFidelityReadyLatencyMs = preloadedWowMetrics?.metrics["wow_viewport_fidelity_ready_latency_ms"]
                    wowFullDocumentFidelityReadyLatencyMs = preloadedWowMetrics?.metrics["wow_full_document_fidelity_ready_latency_ms"]

                    if let wowOpenReady = wowOpenReadyLatencyMs {
                        let value = windowVisibleMs + wowOpenReady
                        openLatencyMs = value
                        openStage = StageResult(valueMs: value, failureReason: nil, timedOut: false)
                    } else {
                        let openReadyRaw = await actionRunner.runOpenReadiness(
                            timeout: openBudget,
                            expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent,
                            expectedFilePath: runFile
                        )
                        let openReady = normalizedDeadlineStage(openReadyRaw)
                        openLatencyMs = openReady.valueMs.map { windowVisibleMs + $0 }
                        openStage = StageResult(
                            valueMs: openLatencyMs,
                            failureReason: openReady.failureReason,
                            timedOut: openReady.timedOut
                        )
                    }
                } else if editor.displayName == "Zed",
                          let zedBenchHookSignalPath,
                          launchedWithZedBenchHook {
                    let hookResult = await waitForZedBenchReady(
                        path: zedBenchHookSignalPath,
                        timeout: openBudget,
                        expectedTargetPath: runFile,
                        expectedMode: config.zedBenchReadyMode,
                        expectedPID: pid
                    )
                    if let payload = hookResult.payload {
                        let hookReadyNs = max(payload.timestampMonotonicNs, t0)
                        let value = max(
                            windowVisibleMs,
                            Double(hookReadyNs - t0) / 1_000_000
                        )
                        openLatencyMs = value
                        openStage = StageResult(valueMs: value, failureReason: nil, timedOut: false)
                        if suite.id == .benchmarkFullFidelity {
                            fullFidelityEndToEndLatencyMs = value
                        }
                    } else if config.zedBenchHookMode == .required {
                        let reason = hookResult.failureReason ?? "zed_bench_hook_timeout"
                        openLatencyMs = nil
                        openStage = StageResult(
                            valueMs: nil,
                            failureReason: reason,
                            timedOut: reason.contains("timeout")
                        )
                    } else {
                        let openReadyRaw = await actionRunner.runOpenReadiness(
                            timeout: openBudget,
                            expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent,
                            expectedFilePath: runFile
                        )
                        let openReady = normalizedDeadlineStage(openReadyRaw)
                        openLatencyMs = openReady.valueMs.map { windowVisibleMs + $0 }
                        openStage = StageResult(
                            valueMs: openLatencyMs,
                            failureReason: openReady.failureReason,
                            timedOut: openReady.timedOut
                        )
                    }
                } else {
                    let openReadyRaw = await actionRunner.runOpenReadiness(
                        timeout: openBudget,
                        expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent,
                        expectedFilePath: runFile
                    )
                    let openReady = normalizedDeadlineStage(openReadyRaw)
                    openLatencyMs = openReady.valueMs.map { windowVisibleMs + $0 }
                    openStage = StageResult(
                        valueMs: openLatencyMs,
                        failureReason: openReady.failureReason,
                        timedOut: openReady.timedOut
                    )
                }
                if suite.id != .wowInternal {
                    collector.record(
                        metric: "open_latency_ms",
                        value: openStage.valueMs,
                        failureReason: openStage.failureReason,
                        timedOut: openStage.timedOut
                    )
                    markFailure("open_latency_ms", openStage)
                }

                if config.postOpenDelayMs > 0 {
                    print("  [\(editor.displayName)] run \(runIdx): debug post-open delay \(config.postOpenDelayMs)ms")
                    try? await Task.sleep(for: .milliseconds(config.postOpenDelayMs))
                }

                let typing: StageResult
                if suite.id == .wowInternal || suite.id == .benchmark {
                    let payload = "x"
                    print("  [\(editor.displayName)] run \(runIdx): typing pulse")
                    let typingRaw = await actionRunner.runTyping(timeout: max(0.05, stageBudget(stage: "typing")), payload: payload)
                    typing = normalizedDeadlineStage(typingRaw)
                    collector.record(
                        metric: "typing_latency_ms",
                        value: typing.valueMs,
                        failureReason: typing.failureReason,
                        timedOut: typing.timedOut
                    )
                    markFailure("typing_latency_ms", typing)
                } else {
                    typing = StageResult(valueMs: nil, failureReason: nil, timedOut: false)
                }

                if let frameMonitorTask {
                    let timestamps = await frameMonitorTask.value
                    if let fp = timestamps.firstPaintNs {
                        firstPaintMs = Double(fp - t0) / 1_000_000
                        collector.record(metric: "first_paint_ms", value: firstPaintMs)
                    } else {
                        collector.record(metric: "first_paint_ms", value: nil, failureReason: "first_paint_unavailable")
                    }
                    if let rs = timestamps.renderStableNs {
                        renderStableMs = Double(rs - t0) / 1_000_000
                        collector.record(metric: "render_stable_ms", value: renderStableMs)
                    } else {
                        collector.record(metric: "render_stable_ms", value: nil, failureReason: "render_stable_unavailable")
                    }
                }

                let saveUI: StageResult
                let saveDurable: StageResult
                if suite.id == .benchmark {
                    print("  [\(editor.displayName)] run \(runIdx): save")
                    let saveDurableTimeout = config.saveDurable ? max(0.05, stageBudget(stage: "save_durable")) : 0
                    let saveResults = await actionRunner.runSave(
                        timeoutUI: max(0.05, stageBudget(stage: "save_ui")),
                        timeoutDurable: saveDurableTimeout,
                        filePath: runFile
                    )
                    saveUI = normalizedDeadlineStage(saveResults.0)
                    saveDurable = normalizedDeadlineStage(saveResults.1)
                    collector.record(metric: "save_ui_ack_latency_ms", value: saveUI.valueMs, failureReason: saveUI.failureReason, timedOut: saveUI.timedOut)
                    markFailure("save_ui_ack_latency_ms", saveUI)
                    if config.saveDurable {
                        collector.record(metric: "save_durable_latency_ms", value: saveDurable.valueMs, failureReason: saveDurable.failureReason, timedOut: saveDurable.timedOut)
                        markFailure("save_durable_latency_ms", saveDurable)
                    }
                } else {
                    // wow_internal is fully in-app and benchmark_open_ready is open-only.
                    // Skip external save dispatch to avoid automation latency/noise.
                    saveUI = StageResult(valueMs: nil, failureReason: nil, timedOut: false)
                    saveDurable = StageResult(valueMs: nil, failureReason: nil, timedOut: false)
                }

                if let wowMetricsPath {
                    let requiredWowMetricKeys: [String] = suite.id == .benchmarkFullFidelity
                        ? ["wow_full_document_fidelity_ready_latency_ms"]
                        : []
                    let wowMetrics = await selectFinalWowMetricsPayload(
                        preloaded: preloadedWowMetrics,
                        path: wowMetricsPath,
                        timeout: max(0.2, stageBudget(stage: "wow_metrics")),
                        requireAllMetrics: suite.id == .wowInternal,
                        requiredMetricKeys: requiredWowMetricKeys
                    )
                    wowParseLatencyMs = wowMetrics?.metrics["wow_parse_latency_ms"] ?? wowParseLatencyMs
                    wowLayoutLatencyMs = wowMetrics?.metrics["wow_layout_latency_ms"] ?? wowLayoutLatencyMs
                    wowPaintReadyLatencyMs = wowMetrics?.metrics["wow_paint_ready_latency_ms"] ?? wowPaintReadyLatencyMs
                    wowEditApplyLatencyMs = wowMetrics?.metrics["wow_edit_apply_latency_ms"] ?? wowEditApplyLatencyMs
                    wowSaveSerializeLatencyMs = wowMetrics?.metrics["wow_save_serialize_latency_ms"] ?? wowSaveSerializeLatencyMs
                    wowOpenReadyLatencyMs = wowMetrics?.metrics["wow_open_ready_latency_ms"] ?? wowOpenReadyLatencyMs
                    wowViewportSemanticReadyLatencyMs = wowMetrics?.metrics["wow_viewport_semantic_ready_latency_ms"] ?? wowViewportSemanticReadyLatencyMs
                    wowViewportFidelityReadyLatencyMs = wowMetrics?.metrics["wow_viewport_fidelity_ready_latency_ms"] ?? wowViewportFidelityReadyLatencyMs
                    wowFullDocumentFidelityReadyLatencyMs = wowMetrics?.metrics["wow_full_document_fidelity_ready_latency_ms"] ?? wowFullDocumentFidelityReadyLatencyMs

                    let wowMetricValues: [(String, Double?)] = [
                        ("wow_parse_latency_ms", wowParseLatencyMs),
                        ("wow_layout_latency_ms", wowLayoutLatencyMs),
                        ("wow_paint_ready_latency_ms", wowPaintReadyLatencyMs),
                        ("wow_edit_apply_latency_ms", wowEditApplyLatencyMs),
                        ("wow_save_serialize_latency_ms", wowSaveSerializeLatencyMs),
                        ("wow_open_ready_latency_ms", wowOpenReadyLatencyMs),
                        ("wow_viewport_semantic_ready_latency_ms", wowViewportSemanticReadyLatencyMs),
                        ("wow_viewport_fidelity_ready_latency_ms", wowViewportFidelityReadyLatencyMs),
                        ("wow_full_document_fidelity_ready_latency_ms", wowFullDocumentFidelityReadyLatencyMs),
                    ]
                    for (metric, value) in wowMetricValues {
                        if suite.id == .wowInternal {
                            let reason = wowMetrics?.failureReasons[metric] ??
                                (value == nil ? "instrumentation_missing" : nil)
                            let timedOut = reason?.hasSuffix("_timeout") ?? false
                            collector.record(metric: metric, value: value, failureReason: reason, timedOut: timedOut)
                            if reason != nil || timedOut {
                                markFailure(
                                    metric,
                                    StageResult(valueMs: value, failureReason: reason, timedOut: timedOut)
                                )
                            }
                        } else if let value {
                            collector.record(metric: metric, value: value)
                        }
                    }

                    if let wowMetrics {
                        let knownMetrics = Set(wowMetricValues.map(\.0))
                        for (metric, value) in wowMetrics.metrics where !knownMetrics.contains(metric) {
                            collector.record(metric: metric, value: value)
                        }
                    }
                }

                if suite.id == .benchmarkFullFidelity {
                    let fullFidelityStage: StageResult = {
                        if editor.displayName == "Kern" {
                            if let wowFull = wowFullDocumentFidelityReadyLatencyMs {
                                let value = windowVisibleMs + wowFull
                                fullFidelityEndToEndLatencyMs = value
                                return StageResult(valueMs: value, failureReason: nil, timedOut: false)
                            }
                            let reason = failureReasons["wow_full_document_fidelity_ready_latency_ms"] ?? "full_document_fidelity_missing"
                            return StageResult(
                                valueMs: nil,
                                failureReason: reason,
                                timedOut: reason.contains("timeout")
                            )
                        }
                        if editor.displayName == "Zed" {
                            if let value = fullFidelityEndToEndLatencyMs {
                                return StageResult(valueMs: value, failureReason: nil, timedOut: false)
                            }
                            return StageResult(
                                valueMs: nil,
                                failureReason: openStage.failureReason ?? "zed_full_fidelity_unavailable",
                                timedOut: openStage.timedOut
                            )
                        }
                        if let renderStableMs {
                            fullFidelityEndToEndLatencyMs = renderStableMs
                            return StageResult(valueMs: renderStableMs, failureReason: nil, timedOut: false)
                        }
                        return StageResult(valueMs: nil, failureReason: "full_fidelity_unavailable", timedOut: false)
                    }()

                    collector.record(
                        metric: "full_fidelity_end_to_end_latency_ms",
                        value: fullFidelityStage.valueMs,
                        failureReason: fullFidelityStage.failureReason,
                        timedOut: fullFidelityStage.timedOut
                    )
                    markFailure("full_fidelity_end_to_end_latency_ms", fullFidelityStage)
                }

                let quit: StageResult
                if suite.id == .benchmark {
                    print("  [\(editor.displayName)] run \(runIdx): quit")
                    let quitRaw = await actionRunner.runQuit(timeout: max(0.05, stageBudget(stage: "quit")))
                    quit = normalizedDeadlineStage(quitRaw)
                    collector.record(metric: "quit_latency_ms", value: quit.valueMs, failureReason: quit.failureReason, timedOut: quit.timedOut)
                    markFailure("quit_latency_ms", quit)
                } else {
                    // wow_internal + benchmark_open_ready use launcher.kill() cleanup.
                    // Avoid external quit keystroke noise/beeps.
                    quit = StageResult(valueMs: nil, failureReason: nil, timedOut: false)
                }

                let automationOverheadMs: Double? = {
                    guard let openLatencyMs else { return nil }
                    return max(0, openLatencyMs - windowVisibleMs)
                }()
                if let automationOverheadMs {
                    collector.record(metric: "automation_overhead_ms", value: automationOverheadMs)
                }

                let unattributedOpenBudgetMs: Double? = {
                    guard let automationOverheadMs else { return nil }
                    let attributed: Double?
                    if let wowOpenReadyLatencyMs {
                        attributed = wowOpenReadyLatencyMs
                    } else if wowParseLatencyMs != nil || wowLayoutLatencyMs != nil || wowPaintReadyLatencyMs != nil {
                        attributed = (wowParseLatencyMs ?? 0) + (wowLayoutLatencyMs ?? 0) + (wowPaintReadyLatencyMs ?? 0)
                    } else {
                        attributed = nil
                    }
                    guard let attributed else { return nil }
                    return max(0, automationOverheadMs - attributed)
                }()
                if let unattributedOpenBudgetMs {
                    collector.record(metric: "unattributed_open_budget_ms", value: unattributedOpenBudgetMs)
                }

                let timeToStableLayoutMs: Double? = {
                    guard let renderStableMs, let openLatencyMs else { return nil }
                    return max(0, renderStableMs - openLatencyMs)
                }()
                if let timeToStableLayoutMs {
                    collector.record(metric: "time_to_stable_layout_ms", value: timeToStableLayoutMs)
                }

                let postReadyExportQuiescenceMs = wowSaveSerializeLatencyMs ?? saveDurable.valueMs ?? saveUI.valueMs
                if let postReadyExportQuiescenceMs {
                    collector.record(metric: "post_ready_export_quiescence_ms", value: postReadyExportQuiescenceMs)
                }

                appendRun(
                    openLatencyMs: suite.id == .wowInternal ? nil : openLatencyMs,
                    typingLatencyMs: (suite.id == .wowInternal || suite.id == .benchmark) ? typing.valueMs : nil,
                    saveUiAckMs: suite.id == .benchmark ? saveUI.valueMs : nil,
                    saveDurableMs: suite.id == .benchmark ? saveDurable.valueMs : nil,
                    quitLatencyMs: suite.id == .benchmark ? quit.valueMs : nil,
                    windowVisibleMs: windowVisibleMs,
                    firstPaintMs: firstPaintMs,
                    renderStableMs: renderStableMs,
                    wowParseLatencyMs: wowParseLatencyMs,
                    wowLayoutLatencyMs: wowLayoutLatencyMs,
                    wowPaintReadyLatencyMs: wowPaintReadyLatencyMs,
                    wowEditApplyLatencyMs: wowEditApplyLatencyMs,
                    wowSaveSerializeLatencyMs: wowSaveSerializeLatencyMs,
                    wowOpenReadyLatencyMs: wowOpenReadyLatencyMs,
                    wowViewportSemanticReadyLatencyMs: wowViewportSemanticReadyLatencyMs,
                    wowViewportFidelityReadyLatencyMs: wowViewportFidelityReadyLatencyMs,
                    wowFullDocumentFidelityReadyLatencyMs: wowFullDocumentFidelityReadyLatencyMs,
                    fullFidelityEndToEndLatencyMs: suite.id == .benchmarkFullFidelity ? fullFidelityEndToEndLatencyMs : nil,
                    automationOverheadMs: automationOverheadMs,
                    unattributedOpenBudgetMs: unattributedOpenBudgetMs,
                    timeToStableLayoutMs: timeToStableLayoutMs,
                    postReadyExportQuiescenceMs: postReadyExportQuiescenceMs
                )

                editorResults[editor.displayName] = result
                collectors[editor.displayName] = collector

                await launcher.kill()
                try? FileManager.default.removeItem(atPath: runFile)
                if let wowMetricsPath {
                    try? FileManager.default.removeItem(atPath: wowMetricsPath)
                }
                if let zedBenchHookSignalPath {
                    try? FileManager.default.removeItem(atPath: zedBenchHookSignalPath)
                }

                if editorIdx < shuffledEditors.count - 1, config.interEditorCooldownMs > 0 {
                    try? await Task.sleep(for: .milliseconds(config.interEditorCooldownMs))
                }
            }
            print("")
        }

        // Build stats and editor classifications.
        var orderedResults: [EditorResult] = []

        let thermalEnd = detectThermalPct()
        let thermalThroughoutOK = measuredThermals.allSatisfy { $0 == 100 } && thermalEnd == 100

        let preflight = PreflightStatus(
            thermalAtStartOK: env.thermalPct == 100,
            thermalThroughoutOK: thermalThroughoutOK,
            rosterComplete: rosterComplete,
            screenCapturePermissionOK: config.enableFrameMonitor ? ((!config.noScreenCapture) && screencaptureAvailable) : true,
            accessibilityPermissionOK: accessibilityAvailable,
            fixtureHashRecorded: !fileHash.isEmpty,
            powerSource: env.power,
            thermalPctStart: env.thermalPct,
            thermalPctEnd: thermalEnd
        )

        for editor in editors {
            guard var result = editorResults[editor.displayName], let collector = collectors[editor.displayName] else { continue }

            let knownMetrics: Set<String> = [
                "cold_start_latency_ms",
                "warm_start_latency_ms",
                "open_latency_ms",
                "save_ui_ack_latency_ms",
                "save_durable_latency_ms",
                "quit_latency_ms",
                "typing_latency_ms",
                "find_latency_ms",
                "scroll_settle_latency_ms",
                "scroll_effective_fps",
                "scroll_p95_frame_time_ms",
                "scroll_p99_frame_time_ms",
                "scroll_hitch_ms_per_s",
                "scroll_jank_33ms_count",
                "scroll_jank_50ms_count",
                "window_visible_ms",
                "first_paint_ms",
                "render_stable_ms",
                "memory_phys_mb",
                "memory_rss_mb",
                "wow_parse_latency_ms",
                "wow_layout_latency_ms",
                "wow_paint_ready_latency_ms",
                "wow_edit_apply_latency_ms",
                "wow_save_serialize_latency_ms",
                "wow_open_ready_latency_ms",
                "wow_viewport_semantic_ready_latency_ms",
                "wow_viewport_fidelity_ready_latency_ms",
                "wow_full_document_fidelity_ready_latency_ms",
                "full_fidelity_end_to_end_latency_ms",
                "automation_overhead_ms",
                "unattributed_open_budget_ms",
                "time_to_stable_layout_ms",
                "post_ready_export_quiescence_ms",
            ]

            let extraMetricStats: [String: Stats]? = {
                var extras: [String: Stats] = [:]
                for (metric, series) in collector.series where !knownMetrics.contains(metric) {
                    if let stats = series.toStats() {
                        extras[metric] = stats
                    }
                }
                return extras.isEmpty ? nil : extras
            }()

            var stats = RunStats(
                coldStartLatency: collector.stats(metric: "cold_start_latency_ms"),
                warmStartLatency: collector.stats(metric: "warm_start_latency_ms"),
                openLatency: collector.stats(metric: "open_latency_ms"),
                saveUiAckLatency: collector.stats(metric: "save_ui_ack_latency_ms"),
                saveDurableLatency: collector.stats(metric: "save_durable_latency_ms"),
                quitLatency: collector.stats(metric: "quit_latency_ms"),
                typingLatency: collector.stats(metric: "typing_latency_ms"),
                findLatency: collector.stats(metric: "find_latency_ms"),
                scrollSettleLatency: collector.stats(metric: "scroll_settle_latency_ms"),
                scrollEffectiveFPS: collector.stats(metric: "scroll_effective_fps"),
                scrollP95FrameTime: collector.stats(metric: "scroll_p95_frame_time_ms"),
                scrollP99FrameTime: collector.stats(metric: "scroll_p99_frame_time_ms"),
                scrollHitchMsPerS: collector.stats(metric: "scroll_hitch_ms_per_s"),
                scrollJank33msCount: collector.stats(metric: "scroll_jank_33ms_count"),
                scrollJank50msCount: collector.stats(metric: "scroll_jank_50ms_count"),
                windowVisible: collector.stats(metric: "window_visible_ms"),
                firstPaint: collector.stats(metric: "first_paint_ms"),
                renderStable: collector.stats(metric: "render_stable_ms"),
                memoryPhys: collector.stats(metric: "memory_phys_mb"),
                memoryRss: collector.stats(metric: "memory_rss_mb"),
                wowParseLatency: collector.stats(metric: "wow_parse_latency_ms"),
                wowLayoutLatency: collector.stats(metric: "wow_layout_latency_ms"),
                wowPaintReadyLatency: collector.stats(metric: "wow_paint_ready_latency_ms"),
                wowEditApplyLatency: collector.stats(metric: "wow_edit_apply_latency_ms"),
                wowSaveSerializeLatency: collector.stats(metric: "wow_save_serialize_latency_ms"),
                wowOpenReadyLatency: collector.stats(metric: "wow_open_ready_latency_ms"),
                wowViewportSemanticReadyLatency: collector.stats(metric: "wow_viewport_semantic_ready_latency_ms"),
                wowViewportFidelityReadyLatency: collector.stats(metric: "wow_viewport_fidelity_ready_latency_ms"),
                wowFullDocumentFidelityReadyLatency: collector.stats(metric: "wow_full_document_fidelity_ready_latency_ms"),
                fullFidelityEndToEndLatency: collector.stats(metric: "full_fidelity_end_to_end_latency_ms"),
                automationOverhead: collector.stats(metric: "automation_overhead_ms"),
                unattributedOpenBudget: collector.stats(metric: "unattributed_open_budget_ms"),
                timeToStableLayout: collector.stats(metric: "time_to_stable_layout_ms"),
                postReadyExportQuiescence: collector.stats(metric: "post_ready_export_quiescence_ms")
            )
            stats.extraMetrics = extraMetricStats

            result.stats = stats
            let editorOutcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
            result.runQuality = editorOutcome.runQuality.rawValue
            result.runClassification = editorOutcome.runClassification.rawValue
            result.partialReasons = editorOutcome.partialReasons

            orderedResults.append(result)
        }

        let reportOutcome = classifyReport(
            suite: suite,
            preflight: preflight,
            editorResults: orderedResults,
            selectedEditors: editors
        )

        var report = BenchmarkReport(
            version: 4,
            tool: "kern-bench",
            timestamp: timestampISO8601(),
            suite: suite.id.rawValue,
            suiteKind: suite.suiteKind,
            runClassification: reportOutcome.runClassification.rawValue,
            runQuality: reportOutcome.runQuality.rawValue,
            partialReasons: reportOutcome.partialReasons,
            environment: environmentWithEndThermal(env),
            preflight: preflight,
            config: BenchmarkConfig(
                suite: suite.id.rawValue,
                suiteKind: suite.suiteKind,
                suiteIntendedUsage: suite.intendedUsage,
                rosterPolicy: "locked_roster_v1_official_claims_only",
                file: config.file,
                fileBytes: fileSize,
                fileHash: fileHash,
                mode: config.cold ? "cold" : "warm",
                runs: runs,
                warmupRuns: warmupRuns,
                editorOrder: "shuffled",
                requiredRoster: suite.requiredRoster,
                requiredMetrics: suite.requiredMetrics
            ),
            results: orderedResults
        )

        if suiteTimedOut,
           !report.partialReasons.contains("suite_timeout") {
            report.partialReasons.append("suite_timeout")
            report.runClassification = RunClassification.partial.rawValue
            report.runQuality = RunQuality.degraded.rawValue
        }

        // Ensure classification reflects end-of-run thermal state.
        if report.environment.thermalPctEnd ?? 100 < 100,
           !report.partialReasons.contains("thermal_throttle") {
            report.partialReasons.append("thermal_throttle")
            report.runClassification = RunClassification.partial.rawValue
            report.runQuality = RunQuality.degraded.rawValue
        }

        printMarkdownTable(report)
        printDetailedStats(report)

        do {
            try writeJSONReport(report, to: archiveJSONPath)
            print("JSON results written to: \(archiveJSONPath)")
        } catch {
            print("Error writing JSON: \(error)")
        }

        do {
            try markdownSummary(report: report).write(toFile: archiveMarkdownPath, atomically: true, encoding: .utf8)
            print("Markdown results written to: \(archiveMarkdownPath)")
        } catch {
            print("Error writing markdown: \(error)")
        }

        do {
            let envMetadata = makeArchiveEnvironmentMetadata(
                suite: suite,
                report: report,
                filePath: config.file,
                fileBytes: fileSize,
                fileHash: fileHash
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envMetadata)
            try data.write(to: URL(fileURLWithPath: archiveEnvPath), options: .atomic)
            print("Environment metadata written to: \(archiveEnvPath)")
        } catch {
            print("Error writing environment metadata: \(error)")
        }

        if let jsonPath = config.jsonPath {
            do {
                try writeJSONReport(report, to: jsonPath)
                print("JSON results copied to: \(jsonPath)")
            } catch {
                print("Error writing JSON copy: \(error)")
            }
        }

        if let mdPath = config.markdownPath {
            do {
                try markdownSummary(report: report).write(toFile: mdPath, atomically: true, encoding: .utf8)
                print("Markdown results copied to: \(mdPath)")
            } catch {
                print("Error writing markdown copy: \(error)")
            }
        }

        print("Done.")
    }
}

// MARK: - Helpers

private func monotonicNowNs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    if pid <= 0 { return false }
    return Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private struct PosixSemaphoreNamespaceProbe {
    let createdSlots: Int
    let failureErrno: Int32?

    var exhausted: Bool {
        failureErrno == ENOSPC
    }
}

private func probePosixSemaphoreNamespace(maxSamples: Int = 8) -> PosixSemaphoreNamespaceProbe {
    var handles: [(name: String, sem: UnsafeMutablePointer<sem_t>)] = []
    defer {
        for (name, sem) in handles {
            _ = sem_close(sem)
            _ = sem_unlink(name)
        }
    }

    let pid = Int(getpid())
    var failureErrno: Int32?
    for idx in 0..<max(1, maxSamples) {
        let name = "/kernbench_probe_\(pid)_\(idx)"
        errno = 0
        let sem = name.withCString { sem_open($0, O_CREAT | O_EXCL, 0o600, 1) }
        if sem == nil || sem == UnsafeMutablePointer<sem_t>(bitPattern: -1) {
            failureErrno = errno
            break
        }
        handles.append((name, sem!))
    }
    return PosixSemaphoreNamespaceProbe(createdSlots: handles.count, failureErrno: failureErrno)
}

private func launchabilityProbe(
    launcher: EditorLauncher,
    file: String,
    timeout: TimeInterval,
    editorName: String
) async -> StageResult {
    await launcher.kill()

    let runFile = prepareRunFixtureCopy(sourceFile: file, editorName: editorName, runIndex: -777)
    defer { try? FileManager.default.removeItem(atPath: runFile) }

    guard let launchResult = try? await launcher.launch(file: runFile), launchResult.pid > 0 else {
        return StageResult(valueMs: nil, failureReason: "launch_failed", timedOut: false)
    }

    let openTimeout = max(0.4, timeout)
    guard let window = await waitForWindow(
        pid: launchResult.pid,
        timeout: openTimeout,
        expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent
    ) else {
        await launcher.kill()
        let reason = processIsAlive(launchResult.pid) ? "window_not_visible" : "process_exited_before_window"
        return StageResult(valueMs: nil, failureReason: reason, timedOut: reason == "window_not_visible")
    }

    await launcher.kill()
    let elapsed = Double(window.timestampNs - launchResult.launchNs) / 1_000_000
    return StageResult(valueMs: elapsed, failureReason: nil, timedOut: false)
}

private func startupProbe(
    launcher: EditorLauncher,
    file: String,
    timeout: TimeInterval,
    cold: Bool,
    purgeFSCache: Bool,
    verbose: Bool,
    editorName: String
) async -> StageResult {
    await launcher.kill()
    if cold && purgeFSCache {
        _ = runProcess(path: "/usr/sbin/purge", args: [])
        try? await Task.sleep(for: .seconds(2))
    }

    let runFile = prepareRunFixtureCopy(sourceFile: file, editorName: editorName, runIndex: cold ? -100 : -101)
    defer { try? FileManager.default.removeItem(atPath: runFile) }

    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    guard let launchResult = try? await launcher.launch(file: runFile), launchResult.pid > 0 else {
        return StageResult(valueMs: nil, failureReason: cold ? "cold_launch_failed" : "warm_launch_failed", timedOut: false)
    }

    guard let window = await waitForWindow(
        pid: launchResult.pid,
        timeout: timeout,
        expectedFileName: URL(fileURLWithPath: runFile).lastPathComponent
    ) else {
        await launcher.kill()
        return StageResult(valueMs: nil, failureReason: cold ? "cold_start_timeout" : "warm_start_timeout", timedOut: true)
    }

    await launcher.kill()

    let elapsed = Double(window.timestampNs - launchResult.launchNs) / 1_000_000
    if verbose {
        let mode = cold ? "cold" : "warm"
        print("  [\(editorName)] preflight \(mode) startup: \(String(format: "%.0f", elapsed))ms")
    }
    // Use t0 to avoid unused variable warning in case launch timestamp is unavailable in future changes.
    _ = t0
    return StageResult(valueMs: elapsed, failureReason: nil, timedOut: false)
}

private func prepareRunFixtureCopy(sourceFile: String, editorName: String, runIndex: Int) -> String {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kern-bench-runs", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let sourceName = URL(fileURLWithPath: sourceFile).lastPathComponent
    let runFolder = tmpDir.appendingPathComponent(
        "\(editorName.replacingOccurrences(of: " ", with: "-").lowercased())-run\(runIndex)-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    try? FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
    let dst = runFolder.appendingPathComponent(sourceName)
    try? FileManager.default.removeItem(at: dst)
    do {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourceFile), to: dst)
        return dst.path
    } catch {
        // Never mutate the source fixture. Fallback: manual write copy.
        if let data = FileManager.default.contents(atPath: sourceFile) {
            do {
                try data.write(to: dst)
                return dst.path
            } catch {
                // Last resort: unique in-memory dump path.
                let fallback = tmpDir.appendingPathComponent(UUID().uuidString + ".md")
                do {
                    try data.write(to: fallback)
                    return fallback.path
                } catch {
                    let emptyFallback = tmpDir.appendingPathComponent(UUID().uuidString + "-empty.md")
                    try? Data().write(to: emptyFallback)
                    return emptyFallback.path
                }
            }
        }
        let emptyFallback = tmpDir.appendingPathComponent(UUID().uuidString + "-empty.md")
        try? Data().write(to: emptyFallback)
        return emptyFallback.path
    }
}

private func runProcess(path: String, args: [String]) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    } catch {
        return -1
    }
}

func normalizeStageTimeoutReason(
    _ stage: StageResult,
    nowNs: UInt64,
    runDeadlineNs: UInt64,
    suiteDeadlineNs: UInt64,
    replacementReason: String
) -> StageResult {
    guard stage.timedOut else { return stage }
    guard nowNs >= runDeadlineNs || nowNs >= suiteDeadlineNs else { return stage }
    return StageResult(
        valueMs: stage.valueMs,
        failureReason: replacementReason,
        timedOut: true
    )
}

func selectFinalWowMetricsPayload(
    preloaded: WowInternalMetricsPayload?,
    path: String,
    timeout: TimeInterval,
    requireAllMetrics: Bool,
    requiredMetricKeys: [String] = []
) async -> WowInternalMetricsPayload? {
    await waitForWowInternalMetrics(
        path: path,
        timeout: timeout,
        requireAllMetrics: requireAllMetrics,
        requiredMetricKeys: requiredMetricKeys
    ) ?? preloaded
}

private func waitForWowInternalMetrics(
    path: String,
    timeout: TimeInterval,
    requireAllMetrics: Bool = true,
    requiredMetricKeys: [String] = []
) async -> WowInternalMetricsPayload? {
    let required: [String] = [
        "wow_parse_latency_ms",
        "wow_layout_latency_ms",
        "wow_paint_ready_latency_ms",
        "wow_edit_apply_latency_ms",
        "wow_save_serialize_latency_ms",
        "wow_open_ready_latency_ms",
        "wow_viewport_semantic_ready_latency_ms",
        "wow_viewport_fidelity_ready_latency_ms",
        "wow_full_document_fidelity_ready_latency_ms",
    ]
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.05, timeout) * 1_000_000_000)
    let settleMs: Int = {
        if let raw = ProcessInfo.processInfo.environment["KERN_WOW_METRICS_SETTLE_MS"],
           let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed >= 0 {
            return parsed
        }
        return 250
    }()
    let settleNs = UInt64(settleMs) * 1_000_000
    var lastPayload: WowInternalMetricsPayload?
    var completionFirstSeenNs: UInt64?
    var completionMetricCount: Int = 0

    while DispatchTime.now().uptimeNanoseconds < deadline {
        if let payload = loadWowInternalMetrics(from: path) {
            lastPayload = payload
            if !requireAllMetrics && requiredMetricKeys.isEmpty {
                return payload
            }
            let completionKeys = requireAllMetrics ? required : requiredMetricKeys
            let complete = completionKeys.allSatisfy { key in
                payload.metrics[key] != nil || payload.failureReasons[key] != nil
            }
            if complete {
                if settleNs == 0 {
                    return payload
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if completionFirstSeenNs == nil {
                    completionFirstSeenNs = now
                    completionMetricCount = payload.metrics.count
                } else if payload.metrics.count > completionMetricCount {
                    completionFirstSeenNs = now
                    completionMetricCount = payload.metrics.count
                }
                if let completionFirstSeenNs, now >= completionFirstSeenNs + settleNs {
                    return payload
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return lastPayload
}

private struct ArchiveEnvironmentMetadata: Codable {
    struct Fixture: Codable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    struct ToolVersions: Codable {
        let kernBench: String
        let swift: String?
        let python3: String?
        let xcodebuild: String?
    }

    let schemaVersion: Int
    let timestamp: String
    let suite: String
    let suiteKind: String
    let fixture: Fixture
    let environment: EnvironmentInfo
    let toolVersions: ToolVersions

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp, suite, fixture, environment
        case suiteKind = "suite_kind"
        case toolVersions = "tool_versions"
    }
}

private func createCanonicalArchiveDirectory(for suite: SuiteDefinition) -> String {
    let slug: String
    switch suite.id {
    case .benchmark:
        slug = "benchmark"
    case .benchmarkOpenReady:
        slug = "benchmark-open-ready"
    case .benchmarkFullFidelity:
        slug = "benchmark-full-fidelity"
    case .wowInternal:
        slug = "wow-internal"
    }
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("benchmark-archive")
        .appendingPathComponent("runs")
        .appendingPathComponent("\(archiveTimestampTag())-\(slug)")
        .path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
    return path
}

private func archiveTimestampTag() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

private func makeArchiveEnvironmentMetadata(
    suite: SuiteDefinition,
    report: BenchmarkReport,
    filePath: String,
    fileBytes: Int,
    fileHash: String
) -> ArchiveEnvironmentMetadata {
    let swiftVersion = shellOutput("/usr/bin/swift", args: ["--version"], timeoutSeconds: 1.0)?
        .components(separatedBy: .newlines).first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pythonVersion = shellOutput("/usr/bin/python3", args: ["--version"], timeoutSeconds: 1.0)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let xcodebuildVersion = shellOutput("/usr/bin/xcodebuild", args: ["-version"], timeoutSeconds: 1.0)?
        .components(separatedBy: .newlines).first?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return ArchiveEnvironmentMetadata(
        schemaVersion: 1,
        timestamp: report.timestamp,
        suite: suite.id.rawValue,
        suiteKind: suite.suiteKind,
        fixture: .init(path: filePath, bytes: fileBytes, sha256: fileHash),
        environment: report.environment,
        toolVersions: .init(
            kernBench: "v\(report.version)",
            swift: swiftVersion,
            python3: pythonVersion,
            xcodebuild: xcodebuildVersion
        )
    )
}

private func markdownSummary(report: BenchmarkReport) -> String {
    var out = report.suiteKind == "internal_microbenchmark"
        ? "# Kern Internal Microbenchmark Results\n\n"
        : "# Cross-Editor Benchmark Results\n\n"
    out += "Suite: \(report.suite)\n"
    out += "Intended usage: \(report.config.suiteIntendedUsage)\n"
    out += "Suite kind: \(report.suiteKind)\n"
    out += "Classification: \(report.runClassification)\n"
    out += "Run quality: \(report.runQuality)\n"
    if !report.partialReasons.isEmpty {
        out += "Partial reasons: \(report.partialReasons.joined(separator: "; "))\n"
    }
    out += "\n"
    if report.suiteKind == "internal_microbenchmark" {
        out += "| Editor | Class | Parse min | Layout min | Paint-ready min | Open-ready min | Full-fidelity min |\n"
        out += "| --- | --- | ---: | ---: | ---: | ---: | ---: |\n"
        for result in report.results {
            let parse = result.stats?.wowParseLatency.map { String(format: "%.2f", $0.min) } ?? "—"
            let layout = result.stats?.wowLayoutLatency.map { String(format: "%.2f", $0.min) } ?? "—"
            let paint = result.stats?.wowPaintReadyLatency.map { String(format: "%.2f", $0.min) } ?? "—"
            let openReady = result.stats?.wowOpenReadyLatency.map { String(format: "%.2f", $0.min) } ?? "—"
            let full = result.stats?.wowFullDocumentFidelityReadyLatency.map { String(format: "%.2f", $0.min) } ?? "—"
            out += "| \(result.editor) | \(result.runClassification) | \(parse) | \(layout) | \(paint) | \(openReady) | \(full) |\n"
        }
    } else if report.suiteKind == "cross_editor_open_only" {
        out += "| Editor | Class | Open min | Open p50 |\n"
        out += "| --- | --- | ---: | ---: |\n"
        for result in report.results {
            let openMin = result.stats?.openLatency.map { String(format: "%.2f", $0.min) } ?? "—"
            let openP50 = result.stats?.openLatency.map { String(format: "%.2f", $0.median) } ?? "—"
            out += "| \(result.editor) | \(result.runClassification) | \(openMin) | \(openP50) |\n"
        }
    } else if report.suiteKind == "cross_editor_full_fidelity" {
        out += "| Editor | Class | Open p50 | Full-fidelity end-to-end p50 | Full-fidelity end-to-end p95 |\n"
        out += "| --- | --- | ---: | ---: | ---: |\n"
        for result in report.results {
            let openP50 = result.stats?.openLatency.map { String(format: "%.2f", $0.median) } ?? "—"
            let fullP50 = result.stats?.fullFidelityEndToEndLatency.map { String(format: "%.2f", $0.median) } ?? "—"
            let fullP95 = result.stats?.fullFidelityEndToEndLatency.map { String(format: "%.2f", $0.p95) } ?? "—"
            out += "| \(result.editor) | \(result.runClassification) | \(openP50) | \(fullP50) | \(fullP95) |\n"
        }
    } else {
        out += "| Editor | Class | Open p50 | Save UI p50 | Quit p50 |\n"
        out += "| --- | --- | ---: | ---: | ---: |\n"
        for result in report.results {
            let open = result.stats?.openLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let saveUI = result.stats?.saveUiAckLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            let quit = result.stats?.quitLatency.map { String(format: "%.0f", $0.median) } ?? "—"
            out += "| \(result.editor) | \(result.runClassification) | \(open) | \(saveUI) | \(quit) |\n"
        }
    }
    out += "\n"
    out += "Policy: README/social headline claims require OFFICIAL runs only.\n"
    return out
}
