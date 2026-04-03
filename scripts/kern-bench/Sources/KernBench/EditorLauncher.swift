import AppKit
import Foundation

enum ZedCLIResolutionSource: String {
    case envOverride = "env_override"
    case autoFork = "auto_fork"
    case defaultCLI = "default_cli"
}

struct ZedCLIResolution {
    let command: [String]?
    let source: ZedCLIResolutionSource
    let resolvedPath: String?
}

private func zedForkCommand(cliPath: String, isExecutable: (String) -> Bool) -> [String] {
    let cliURL = URL(fileURLWithPath: cliPath)
    let zedPath = cliURL.deletingLastPathComponent().appendingPathComponent("zed").path
    if isExecutable(zedPath) {
        return [cliPath, "--zed", zedPath]
    }
    return [cliPath]
}

func defaultZedForkCLICandidates(
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    homeDirectoryPath: String = NSHomeDirectory()
) -> [String] {
    let candidates = [
        "\(homeDirectoryPath)/Projects/zed-fork-bench/target/release/cli",
        "\(homeDirectoryPath)/Projects/zed-fork-bench/target/debug/cli",
        URL(fileURLWithPath: currentDirectoryPath)
            .appendingPathComponent("../zed-fork-bench/target/release/cli")
            .standardizedFileURL.path,
        URL(fileURLWithPath: currentDirectoryPath)
            .appendingPathComponent("../zed-fork-bench/target/debug/cli")
            .standardizedFileURL.path,
    ]

    var seen = Set<String>()
    var unique: [String] = []
    for path in candidates {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if seen.insert(normalized).inserted {
            unique.append(normalized)
        }
    }
    return unique
}

func resolveZedCLICommand(
    defaultCommand: [String]?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    homeDirectoryPath: String = NSHomeDirectory(),
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
) -> ZedCLIResolution {
    if let overrideRaw = environment["KERN_BENCH_ZED_CLI"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !overrideRaw.isEmpty {
        let expanded = (overrideRaw as NSString).expandingTildeInPath
        let command = zedForkCommand(cliPath: expanded, isExecutable: isExecutable)
        return ZedCLIResolution(
            command: command,
            source: .envOverride,
            resolvedPath: expanded
        )
    }

    for candidate in defaultZedForkCLICandidates(
        currentDirectoryPath: currentDirectoryPath,
        homeDirectoryPath: homeDirectoryPath
    ) {
        if isExecutable(candidate) {
            let command = zedForkCommand(cliPath: candidate, isExecutable: isExecutable)
            return ZedCLIResolution(
                command: command,
                source: .autoFork,
                resolvedPath: candidate
            )
        }
    }

    let resolvedPath: String? = {
        guard let first = defaultCommand?.first else { return nil }
        if first.contains("/") {
            return (first as NSString).expandingTildeInPath
        }
        return resolveCommandPath(first)
    }()

    return ZedCLIResolution(
        command: defaultCommand,
        source: .defaultCLI,
        resolvedPath: resolvedPath
    )
}

/// Result of launching an editor: PID and the exact monotonic timestamp of exec.
struct LaunchResult {
    let pid: pid_t
    /// Monotonic nanosecond timestamp captured immediately before exec(2).
    let launchNs: UInt64
}

private let trackedOwnedBenchmarkPIDsLock = NSLock()
private var trackedOwnedBenchmarkPIDsByEditor: [String: Set<pid_t>] = [:]

private func trackedOwnedBenchmarkPIDKey(for editor: EditorDefinition) -> String {
    "\(editor.bundleIdentifier)|\(editor.displayName)"
}

func trackOwnedBenchmarkPIDs(_ pids: [pid_t], for editor: EditorDefinition) {
    let filtered = Set(pids.filter { $0 > 0 })
    guard !filtered.isEmpty else { return }
    let key = trackedOwnedBenchmarkPIDKey(for: editor)
    trackedOwnedBenchmarkPIDsLock.lock()
    defer { trackedOwnedBenchmarkPIDsLock.unlock() }
    trackedOwnedBenchmarkPIDsByEditor[key, default: []].formUnion(filtered)
}

func trackedOwnedBenchmarkPIDs(for editor: EditorDefinition) -> [pid_t] {
    let key = trackedOwnedBenchmarkPIDKey(for: editor)
    trackedOwnedBenchmarkPIDsLock.lock()
    defer { trackedOwnedBenchmarkPIDsLock.unlock() }
    return Array(trackedOwnedBenchmarkPIDsByEditor[key] ?? []).sorted()
}

func clearTrackedOwnedBenchmarkPIDs(for editor: EditorDefinition) {
    let key = trackedOwnedBenchmarkPIDKey(for: editor)
    trackedOwnedBenchmarkPIDsLock.lock()
    defer { trackedOwnedBenchmarkPIDsLock.unlock() }
    trackedOwnedBenchmarkPIDsByEditor.removeValue(forKey: key)
}

func buildCleanupCLIFullPathPatterns(
    effectiveCLILaunchCommand: [String]?,
    defaultCLILaunchCommand: [String]?
) -> [String] {
    var patterns: [String] = []

    func appendPattern(_ value: String?) {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains("/") {
            patterns.append((trimmed as NSString).expandingTildeInPath)
        }
    }

    appendPattern(effectiveCLILaunchCommand?.first)
    appendPattern(defaultCLILaunchCommand?.first)

    if let cli = effectiveCLILaunchCommand,
       let zedIndex = cli.firstIndex(of: "--zed"),
       zedIndex + 1 < cli.count {
        appendPattern(cli[zedIndex + 1])
    }
    if let cli = defaultCLILaunchCommand,
       let zedIndex = cli.firstIndex(of: "--zed"),
       zedIndex + 1 < cli.count {
        appendPattern(cli[zedIndex + 1])
    }

    var seen = Set<String>()
    return patterns.filter { seen.insert($0).inserted }
}

private let benchmarkEnvironmentAllowlistKeys: Set<String> = [
    "HOME",
    "PATH",
    "TMPDIR",
    "SHELL",
    "USER",
    "LOGNAME",
    "LANG",
    "TERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "__CF_USER_TEXT_ENCODING",
    "SYSTEM_VERSION_COMPAT"
]

private let benchmarkEnvironmentAllowlistPrefixes: [String] = [
    "LC_"
]

private func validateExistingPrivateBenchmarkDirectory(
    at url: URL,
    ownerValidator: (NSNumber) -> Bool
) -> Bool {
    let path = url.path
    if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
       values.isDirectory == true || values.isSymbolicLink == true
    {
        guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let ownerID = attributes[.ownerAccountID] as? NSNumber,
              ownerValidator(ownerID) else {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return true
    }
    return false
}

@discardableResult
private func createPrivateBenchmarkDirectory(
    at url: URL,
    ownerValidator: (NSNumber) -> Bool
) -> Bool {
    if FileManager.default.fileExists(atPath: url.path) {
        return validateExistingPrivateBenchmarkDirectory(at: url, ownerValidator: ownerValidator)
    }
    do {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return true
    } catch {
        return false
    }
}

func sanitizedBenchmarkProcessEnvironment(
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    overrides: [String: String]
) -> [String: String] {
    var sanitized: [String: String] = [:]
    for (key, value) in baseEnvironment {
        if benchmarkEnvironmentAllowlistKeys.contains(key)
            || benchmarkEnvironmentAllowlistPrefixes.contains(where: { key.hasPrefix($0) }) {
            sanitized[key] = value
        }
    }
    for (key, value) in overrides {
        sanitized[key] = value
    }
    return sanitized
}

func benchmarkCleanLaunchArgs(
    for editor: EditorDefinition,
    temporaryRoot: String = NSTemporaryDirectory(),
    fallbackTemporaryRoot: String = FileManager.default.temporaryDirectory.path,
    uniqueSuffix: String = UUID().uuidString,
    ownerValidator: ((NSNumber) -> Bool)? = nil
) throws -> [String] {
    let effectiveOwnerValidator = ownerValidator ?? { $0 == NSNumber(value: getuid()) }
    func privateProfileDir(rootBase: URL) -> URL? {
        let root = rootBase.appendingPathComponent("kern-bench-profiles", isDirectory: true)
        let editorRoot = root
            .appendingPathComponent(editor.processName.lowercased(), isDirectory: true)
        let dir = editorRoot.appendingPathComponent(uniqueSuffix, isDirectory: true)
        guard createPrivateBenchmarkDirectory(at: root, ownerValidator: effectiveOwnerValidator),
              createPrivateBenchmarkDirectory(at: editorRoot, ownerValidator: effectiveOwnerValidator),
              createPrivateBenchmarkDirectory(at: dir, ownerValidator: effectiveOwnerValidator) else {
            return nil
        }
        return dir
    }

    let requestedRoot = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
    let fallbackRoot = URL(fileURLWithPath: fallbackTemporaryRoot, isDirectory: true)
    var args: [String] = []
    var index = 0
    while index < editor.cleanLaunchArgs.count {
        let arg = editor.cleanLaunchArgs[index]
        if arg == "--user-data-dir", index + 1 < editor.cleanLaunchArgs.count {
            guard let dir = privateProfileDir(rootBase: requestedRoot)
                ?? privateProfileDir(rootBase: fallbackRoot) else {
                throw LaunchError.privateProfileDirectoryUnavailable(editor.processName)
            }
            args.append(arg)
            args.append(dir.path)
            index += 2
            continue
        }
        args.append(arg)
        index += 1
    }
    return args
}

struct EditorLauncher {
    let editor: EditorDefinition

    /// Maximum time to wait for the app to register with NSRunningApplication after launch.
    private let pidLookupTimeout: TimeInterval = 5.0

    /// Resolve Zed CLI command preference:
    /// 1) KERN_BENCH_ZED_CLI override
    /// 2) auto-detected local fork build (~/Projects/zed-fork-bench)
    /// 3) default `zed` on PATH
    private var zedCLIResolution: ZedCLIResolution? {
        guard editor.displayName == "Zed" else { return nil }
        return resolveZedCLICommand(defaultCommand: editor.cliLaunchCommand)
    }

    /// Allow overriding Zed CLI command for fork/experimental builds.
    /// Usage: KERN_BENCH_ZED_CLI=/abs/path/to/zed-wrapper
    private var effectiveCLILaunchCommand: [String]? {
        if let zedCLIResolution {
            return zedCLIResolution.command
        }
        return editor.cliLaunchCommand
    }

    /// For Zed benchmarking, never fall back to `open -a` after CLI launch failure.
    /// This guarantees the benchmark does not silently switch to a non-forked app path.
    private var forbidOpenFallbackAfterCLIFailure: Bool {
        editor.displayName == "Zed"
    }

    private var cleanupCLIProcessNames: [String] {
        var names: [String] = []

        func appendName(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if trimmed.contains("/") {
                names.append((trimmed as NSString).lastPathComponent)
            } else {
                names.append(trimmed)
            }
        }

        appendName(effectiveCLILaunchCommand?.first)
        appendName(editor.cliLaunchCommand?.first)

        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private var cleanupCLIFullPathPatterns: [String] {
        buildCleanupCLIFullPathPatterns(
            effectiveCLILaunchCommand: effectiveCLILaunchCommand,
            defaultCLILaunchCommand: editor.cliLaunchCommand
        )
    }

    /// Optional app-bundle override for local benchmarking.
    /// Usage: KERN_BENCH_KERN_APP=/abs/path/to/Kern.app
    private var effectiveAppURL: URL? {
        if editor.displayName == "Kern" {
            return resolveKernAppURL()
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier)
    }

    /// Launch the editor with the given file and return the PID + exact launch timestamp.
    /// Tries CLI launch first (if configured), falls back to `open -a`.
    func launch(
        file: String,
        env: [String: String] = [:],
        additionalArgs: [String] = []
    ) async throws -> LaunchResult {
        let cleanLaunchArgs = try benchmarkCleanLaunchArgs(for: editor)
        let sanitizedEnvironment = sanitizedBenchmarkProcessEnvironment(overrides: env)

        // NSWorkspace/open-based launches are convenient for normal cross-editor flows,
        // but environment propagation can be unreliable across LaunchServices boundaries.
        // For Kern internal microbenchmarks we require deterministic env injection.
        if !sanitizedEnvironment.isEmpty,
           editor.bundleIdentifier == "com.gradigit.kern",
           let direct = try? await launchViaDirectBinary(
            file: file,
            env: sanitizedEnvironment,
            cleanLaunchArgs: cleanLaunchArgs,
            additionalArgs: additionalArgs
           ),
           direct.pid > 0 {
            return direct
        }

        if let cli = effectiveCLILaunchCommand, !cli.isEmpty {
            if let result = try? await launchViaCLI(
                cli: cli,
                file: file,
                env: sanitizedEnvironment,
                cleanLaunchArgs: cleanLaunchArgs,
                additionalArgs: additionalArgs
            ), result.pid > 0 {
                return result
            }
            if forbidOpenFallbackAfterCLIFailure {
                throw LaunchError.cliLaunchFailed(cli.first ?? editor.displayName)
            }
            // CLI failed — fall back to open -a with clean args via --args.
            return try await launchViaOpen(
                file: file,
                useCleanArgs: true,
                env: sanitizedEnvironment,
                cleanLaunchArgs: cleanLaunchArgs,
                additionalArgs: additionalArgs
            )
        } else {
            return try await launchViaOpen(
                file: file,
                useCleanArgs: true,
                env: sanitizedEnvironment,
                cleanLaunchArgs: cleanLaunchArgs,
                additionalArgs: additionalArgs
            )
        }
    }

    /// Launch app binary directly (bypasses LaunchServices) to guarantee environment variable delivery.
    private func launchViaDirectBinary(
        file: String,
        env: [String: String],
        cleanLaunchArgs: [String],
        additionalArgs: [String]
    ) async throws -> LaunchResult {
        guard let appURL = effectiveAppURL else {
            throw LaunchError.cliNotFound(editor.bundleIdentifier)
        }

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: plistURL)
        let executable = info?["CFBundleExecutable"] as? String
        guard let executable, !executable.isEmpty else {
            throw LaunchError.cliNotFound("CFBundleExecutable")
        }

        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileManager.default.isReadableFile(atPath: binaryURL.path) else {
            throw LaunchError.cliNotFound(binaryURL.path)
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = cleanLaunchArgs + additionalArgs + [file]
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let launchNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try proc.run()

        // Direct binary launch gives us the real app PID immediately.
        let pid = proc.processIdentifier
        if pid > 0 {
            trackOwnedBenchmarkPIDs([pid], for: editor)
            return LaunchResult(pid: pid, launchNs: launchNs)
        }
        let resolvedPID = try await waitForPID()
        trackOwnedBenchmarkPIDs([resolvedPID], for: editor)
        return LaunchResult(pid: resolvedPID, launchNs: launchNs)
    }

    /// Launch using CLI command (e.g., `code --new-window ...`).
    private func launchViaCLI(
        cli: [String],
        file: String,
        env: [String: String],
        cleanLaunchArgs: [String],
        additionalArgs: [String]
    ) async throws -> LaunchResult {
        guard let cliPath = resolveCommandPath(cli[0]) else {
            throw LaunchError.cliNotFound(cli[0])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = Array(cli.dropFirst()) + cleanLaunchArgs + additionalArgs + [file]
        if !env.isEmpty {
            proc.environment = env
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        // Capture t0 immediately before exec — this is the true launch timestamp.
        let launchNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try proc.run()

        // Poll for PID registration with retry (up to pidLookupTimeout).
        let pid = try await waitForPID()
        var trackedPIDs = Set([proc.processIdentifier, pid].filter { $0 > 0 })
        if editor.displayName == "Zed",
           let zedIndex = cli.firstIndex(of: "--zed"),
           zedIndex + 1 < cli.count {
            trackedPIDs.formUnion(findPIDsByExactCommandPath(cli[zedIndex + 1]))
        }
        trackOwnedBenchmarkPIDs(Array(trackedPIDs), for: editor)
        return LaunchResult(pid: pid, launchNs: launchNs)
    }

    /// Launch using NSWorkspace — targets the exact app matching our bundle ID
    /// and returns the PID directly (no polling needed).
    private func launchViaOpen(
        file: String,
        useCleanArgs: Bool,
        env: [String: String],
        cleanLaunchArgs: [String],
        additionalArgs: [String]
    ) async throws -> LaunchResult {
        guard let appURL = effectiveAppURL else {
            // Bundle not found — fall back to open -a by name.
            return try await launchViaOpenCommand(
                file: file,
                useCleanArgs: useCleanArgs,
                env: env,
                cleanLaunchArgs: cleanLaunchArgs,
                additionalArgs: additionalArgs
            )
        }

        let fileURL = URL(fileURLWithPath: file)
        let config = NSWorkspace.OpenConfiguration()
        var launchArgs: [String] = []
        if useCleanArgs && !cleanLaunchArgs.isEmpty {
            launchArgs += cleanLaunchArgs
        }
        launchArgs += additionalArgs
        if !launchArgs.isEmpty {
            config.arguments = launchArgs
        }
        if !env.isEmpty {
            config.environment = env
        }

        // Capture t0 immediately before launch.
        let launchNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let app = try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
        trackOwnedBenchmarkPIDs([app.processIdentifier], for: editor)
        return LaunchResult(pid: app.processIdentifier, launchNs: launchNs)
    }

    /// Fallback: launch via `open -a` when NSWorkspace bundle lookup fails.
    private func launchViaOpenCommand(
        file: String,
        useCleanArgs: Bool,
        env: [String: String],
        cleanLaunchArgs: [String],
        additionalArgs: [String]
    ) async throws -> LaunchResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-a", editor.appName]
        if useCleanArgs && !cleanLaunchArgs.isEmpty {
            args += ["--args"] + cleanLaunchArgs
            if !additionalArgs.isEmpty {
                args += additionalArgs
            }
        } else if !additionalArgs.isEmpty {
            args += ["--args"] + additionalArgs
        }
        args += [file]
        proc.arguments = args
        if !env.isEmpty {
            proc.environment = env
        }

        let launchNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try proc.run()
        proc.waitUntilExit()

        let pid = try await waitForPID()
        trackOwnedBenchmarkPIDs([pid], for: editor)
        return LaunchResult(pid: pid, launchNs: launchNs)
    }

    /// Poll NSRunningApplication until the editor's bundle ID appears, with exponential backoff.
    private func waitForPID() async throws -> pid_t {
        let startTime = CFAbsoluteTimeGetCurrent()
        var delay: UInt64 = 25 // Start at 25ms
        let shouldUseProcessNameFallback = shouldUseProcessNameFallback(
            cliLaunchCommand: effectiveCLILaunchCommand,
            processName: editor.processName
        )

        while CFAbsoluteTimeGetCurrent() - startTime < pidLookupTimeout {
            if let pid = findPIDByBundleIdentifier(editor.bundleIdentifier) {
                return pid
            }
            if shouldUseProcessNameFallback,
               let pid = findPIDByProcessName(editor.processName) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(Int(delay)))
            delay = min(delay + 25, 200) // Ramp up to 200ms
        }
        return 0
    }

    // MARK: - Kill

    /// Stop editor processes with graceful-first policy, then escalate only if needed.
    func kill() async {
        let explicitlyOwnedPIDs = Set(trackedOwnedBenchmarkPIDs(for: editor).filter { $0 > 0 })
        defer { clearTrackedOwnedBenchmarkPIDs(for: editor) }

        func waitUntilStopped(maxWaitMs: Int) async -> Bool {
            let deadline = CFAbsoluteTimeGetCurrent() + (Double(maxWaitMs) / 1000.0)
            while CFAbsoluteTimeGetCurrent() < deadline {
                if !isRunning() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return !isRunning()
        }

        func terminateOwnedPIDs() {
            for pid in explicitlyOwnedPIDs where pid > 0 {
                Foundation.kill(pid, SIGTERM)
            }
        }

        let initialApps = NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleIdentifier)
            .filter { !$0.isTerminated }

        // 1) Ask politely first; this preserves editor/session cleanup paths.
        terminateOwnedPIDs()
        for app in initialApps {
            _ = app.terminate()
        }
        if await waitUntilStopped(maxWaitMs: 450) {
            return
        }

        // 2) Escalate to forceTerminate for bundle-owned processes.
        let remainingApps = NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleIdentifier)
            .filter { !$0.isTerminated }
        for app in remainingApps {
            _ = app.forceTerminate()
        }
        if await waitUntilStopped(maxWaitMs: 350) {
            return
        }

        // 3) Last resort: SIGKILL only benchmark-owned bundle processes, their descendants,
        // and explicitly-scoped helper processes. Do not use broad process-name/pattern kills.
        let remainingPIDs = Array(Set(remainingApps.map(\.processIdentifier))).filter { $0 > 0 }
        var escalatedPIDs = Set(remainingPIDs)
        escalatedPIDs.formUnion(explicitlyOwnedPIDs)
        for pid in remainingPIDs {
            escalatedPIDs.formUnion(findAllDescendantPIDs(of: pid))
        }
        for pid in explicitlyOwnedPIDs {
            escalatedPIDs.formUnion(findAllDescendantPIDs(of: pid))
        }
        if let prefix = editor.helperProcessPrefix {
            escalatedPIDs.formUnion(findHelperPIDs(prefix: prefix))
        }
        for pid in escalatedPIDs where pid > 0 {
            Foundation.kill(pid, SIGKILL)
        }

        // Short verification for stubborn bundle-owned processes only.
        let verifyDeadline = CFAbsoluteTimeGetCurrent() + 0.7
        while CFAbsoluteTimeGetCurrent() < verifyDeadline {
            if !isRunning() { break }
            let stubbornApps = NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleIdentifier)
                .filter { !$0.isTerminated }
            let stubbornPIDs = Array(Set(stubbornApps.map(\.processIdentifier))).filter { $0 > 0 }
            for pid in stubbornPIDs {
                Foundation.kill(pid, SIGKILL)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Check if the editor process is currently running (non-terminated).
    func isRunning() -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleIdentifier)
            .contains(where: { !$0.isTerminated }) {
            return true
        }
        if processExists(name: editor.processName) || processExists(name: editor.appName) {
            return true
        }
        for cliName in cleanupCLIProcessNames where processExists(name: cliName) {
            return true
        }
        for pattern in cleanupCLIFullPathPatterns where processExists(pattern: pattern) {
            return true
        }
        if let prefix = editor.helperProcessPrefix,
           !findHelperPIDs(prefix: prefix).isEmpty {
            return true
        }
        return false
    }
}

enum LaunchError: Error {
    case cliNotFound(String)
    case cliLaunchFailed(String)
    case privateProfileDirectoryUnavailable(String)
}

func shouldUseProcessNameFallback(
    cliLaunchCommand: [String]?,
    processName: String
) -> Bool {
    guard let cli = cliLaunchCommand?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
          !cli.isEmpty else {
        return true
    }

    let cliBasename = (cli as NSString).lastPathComponent.lowercased()
    return cliBasename != processName.lowercased()
}

/// Resolve a command path:
/// - if the input already contains a slash, treat it as an explicit path
/// - otherwise, search PATH via `which`
func resolveCommandPath(_ command: String) -> String? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains("/") {
        let expanded = (trimmed as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: expanded) {
            return expanded
        }
        return nil
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    proc.arguments = [trimmed]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty else { return nil }
    return path
}

// MARK: - PID Detection

/// Find PID using NSRunningApplication bundle identifier (eliminates Electron ambiguity).
func findPIDByBundleIdentifier(_ bundleID: String) -> pid_t? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    return apps.first?.processIdentifier
}

/// Find PID using process name when an app binary does not register a bundle identifier.
func findPIDByProcessName(_ processName: String) -> pid_t? {
    guard !processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", processName]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return nil
    }

    guard proc.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    return output
        .components(separatedBy: "\n")
        .compactMap { pid_t($0) }
        .first
}

func findPIDsByExactCommandPath(_ commandPath: String) -> [pid_t] {
    let target = commandPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return [] }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-axo", "pid=,command="]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard proc.terminationStatus == 0,
          let output = String(data: data, encoding: .utf8) else {
        return []
    }

    return output.split(separator: "\n").compactMap { line -> pid_t? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = pid_t(parts[0]) else { return nil }
        let command = String(parts[1])
        guard command == target || command.hasPrefix(target + " ") else { return nil }
        return pid
    }
}

/// BFS traversal of process tree. Finds all descendant PIDs (children, grandchildren, etc.).
/// Result is ordered parent→child (BFS level order).
func findAllDescendantPIDs(of parentPID: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var frontier: [pid_t] = [parentPID]

    while !frontier.isEmpty {
        var nextFrontier: [pid_t] = []
        for pid in frontier {
            let children = directChildPIDs(of: pid)
            result.append(contentsOf: children)
            nextFrontier.append(contentsOf: children)
        }
        frontier = nextFrontier
    }
    return result
}

/// Find direct child PIDs of a given parent via `pgrep -P`.
private func directChildPIDs(of parentPID: pid_t) -> [pid_t] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-P", "\(parentPID)"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    return output.components(separatedBy: "\n").compactMap { pid_t($0) }
}

private func processExists(name: String) -> Bool {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", name]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        return false
    }
}

private func processExists(pattern: String) -> Bool {
    guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-f", pattern]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        return false
    }
}

/// Find PIDs matching a helper process prefix via `pgrep -f`.
/// Excludes the current process (kern-bench itself) to avoid self-kill.
func findHelperPIDs(prefix: String) -> [pid_t] {
    let ownPID = getpid()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-f", prefix]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    return output.components(separatedBy: "\n")
        .compactMap { pid_t($0) }
        .filter { $0 != ownPID }
}
