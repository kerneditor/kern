import Foundation

private func liveProcessIsAlive(_ pid: pid_t) -> Bool {
    processIsAlive(pid)
}

private func liveWaitForWindow(
    _ pid: pid_t,
    _ timeout: TimeInterval,
    _ expectedFileName: String?
) async -> DetectedWindow? {
    await waitForWindow(pid: pid, timeout: timeout, expectedFileName: expectedFileName)
}

struct LaunchWindowRetryOutcome {
    let launchResult: LaunchResult?
    let window: DetectedWindow?
    let failureReason: String?
    let failureTimedOut: Bool
    let launchedWithZedBenchHook: Bool
}

struct LaunchWindowRetryDependencies {
    var nowNs: () -> UInt64
    var processIsAlive: (pid_t) -> Bool
    var waitForWindow: (_ pid: pid_t, _ timeout: TimeInterval, _ expectedFileName: String?) async -> DetectedWindow?
    var log: (String) -> Void
    var afterRetryCleanup: (() async -> Void)?

    init(
        nowNs: @escaping () -> UInt64 = monotonicNowNs,
        processIsAlive: @escaping (pid_t) -> Bool = liveProcessIsAlive,
        waitForWindow: @escaping (_ pid: pid_t, _ timeout: TimeInterval, _ expectedFileName: String?) async -> DetectedWindow? = liveWaitForWindow,
        log: @escaping (String) -> Void = { print($0) },
        afterRetryCleanup: (() async -> Void)? = nil
    ) {
        self.nowNs = nowNs
        self.processIsAlive = processIsAlive
        self.waitForWindow = waitForWindow
        self.log = log
        self.afterRetryCleanup = afterRetryCleanup
    }
}

func performLaunchWindowAttempts(
    launcher: EditorLauncher,
    editor: EditorDefinition,
    runIdx: Int,
    runFile: String,
    launchEnv: [String: String],
    runDeadlineNs: UInt64,
    suiteDeadlineNs: UInt64,
    openStageBudget: @escaping () -> TimeInterval,
    deadlineReason: @MainActor @escaping () -> String,
    config: BenchConfig,
    zedBenchHookSignalPath: String?,
    dependencies: LaunchWindowRetryDependencies = .init()
) async -> LaunchWindowRetryOutcome {
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
            return attempt == 1 ? zedHookArgs : []
        case .off:
            return []
        }
    }

    attemptLoop: for attempt in 1...2 {
        let retryTag = attempt > 1 ? " (retry \(attempt)/2)" : ""
        dependencies.log("  [\(editor.displayName)] run \(runIdx): launch\(retryTag)")

        let perAttemptLaunchArgs = launchArgs(forAttempt: attempt)
        launchedWithZedBenchHook = !perAttemptLaunchArgs.isEmpty
        guard let candidate = try? await launcher.launch(
            file: runFile,
            env: launchEnv,
            additionalArgs: perAttemptLaunchArgs
        ), candidate.pid > 0 else {
            if attempt < 2 {
                dependencies.log("  [\(editor.displayName)] run \(runIdx): launch failed, retrying")
                await launcher.kill()
                if let afterRetryCleanup = dependencies.afterRetryCleanup {
                    await afterRetryCleanup()
                }
                continue attemptLoop
            }
            launchWindowFailureReason = "launch_failed"
            break attemptLoop
        }

        if dependencies.nowNs() >= runDeadlineNs || dependencies.nowNs() >= suiteDeadlineNs {
            launchWindowFailureReason = await deadlineReason()
            launchWindowTimedOut = true
            break attemptLoop
        }

        dependencies.log("  [\(editor.displayName)] run \(runIdx): wait window\(retryTag)")
        let attemptsRemaining = max(1, 2 - attempt + 1)
        let nowNs = dependencies.nowNs()
        let runRemaining = nowNs < runDeadlineNs ? Double(runDeadlineNs - nowNs) / 1_000_000_000 : 0
        let suiteRemaining = nowNs < suiteDeadlineNs ? Double(suiteDeadlineNs - nowNs) / 1_000_000_000 : 0
        let remainingBudget = max(0.05, min(runRemaining, suiteRemaining))
        let perAttemptBudget = max(0.05, remainingBudget / Double(attemptsRemaining))
        let windowTimeout = min(openStageBudget(), perAttemptBudget)

        if let detected = await dependencies.waitForWindow(
            candidate.pid,
            windowTimeout,
            URL(fileURLWithPath: runFile).lastPathComponent
        ) {
            launchResult = candidate
            window = detected
            break attemptLoop
        }

        let reason = !dependencies.processIsAlive(candidate.pid) ? "process_exited_before_window" :
            (dependencies.nowNs() >= suiteDeadlineNs ? "suite_timeout" :
            (dependencies.nowNs() >= runDeadlineNs ? "run_timeout" : "open_timeout")
            )
        if attempt < 2, reason != "suite_timeout" {
            dependencies.log("  [\(editor.displayName)] run \(runIdx): \(reason) waiting for window, retrying")
            await launcher.kill()
            if let afterRetryCleanup = dependencies.afterRetryCleanup {
                await afterRetryCleanup()
            }
            continue attemptLoop
        }

        launchWindowFailureReason = reason
        launchWindowTimedOut = reason.contains("timeout")
        break attemptLoop
    }

    return LaunchWindowRetryOutcome(
        launchResult: launchResult,
        window: window,
        failureReason: launchWindowFailureReason,
        failureTimedOut: launchWindowTimedOut,
        launchedWithZedBenchHook: launchedWithZedBenchHook
    )
}
