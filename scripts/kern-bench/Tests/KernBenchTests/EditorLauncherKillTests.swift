import XCTest
@testable import kern_bench

final class EditorLauncherKillTests: XCTestCase {
    override func tearDown() {
        if let zed = findEditor(named: "Zed") {
            clearTrackedOwnedBenchmarkPIDs(for: zed)
        }
        super.tearDown()
    }

    func testCleanupCLIFullPathPatternsIncludeForkedRawZedBinary() {
        let patterns = buildCleanupCLIFullPathPatterns(
            effectiveCLILaunchCommand: ["/tmp/cli", "--zed", "/tmp/zed"],
            defaultCLILaunchCommand: ["zed"]
        )

        XCTAssertEqual(patterns, ["/tmp/cli", "/tmp/zed"])
    }

    func testTrackOwnedBenchmarkPIDsDeduplicatesAndClears() throws {
        let zed = try XCTUnwrap(findEditor(named: "Zed"))

        trackOwnedBenchmarkPIDs([42, 42, 77], for: zed)
        XCTAssertEqual(trackedOwnedBenchmarkPIDs(for: zed), [42, 77])

        clearTrackedOwnedBenchmarkPIDs(for: zed)
        XCTAssertTrue(trackedOwnedBenchmarkPIDs(for: zed).isEmpty)
    }

    func testKillClearsTrackedOwnedPIDsWhenOnlyExplicitTrackingExists() async throws {
        let zed = try XCTUnwrap(findEditor(named: "Zed"))
        trackOwnedBenchmarkPIDs([99999], for: zed)

        let launcher = EditorLauncher(editor: zed)
        await launcher.kill()

        XCTAssertTrue(trackedOwnedBenchmarkPIDs(for: zed).isEmpty)
    }

    func testKillReapsOwnedCLIProcessBeforeRetryRelaunch() async throws {
        let tempRoot = try makeTemporaryDirectory()
        let binaryURL = try compileSleepBinary(in: tempRoot)
        defer {
            try? FileManager.default.removeItem(at: binaryURL)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let editor = makeFakeCLIEditor(binaryPath: binaryURL.path)
        clearTrackedOwnedBenchmarkPIDs(for: editor)
        let launcher = EditorLauncher(editor: editor)
        let baseline = Set(findPIDsByExactCommandPath(binaryURL.path))

        do {
            _ = try await launcher.launch(file: "30")
            let firstOwned = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 1
            )
            XCTAssertEqual(firstOwned.count, 1)

            await launcher.kill()
            let afterFirstKill = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 0
            )
            XCTAssertTrue(afterFirstKill.isEmpty)

            _ = try await launcher.launch(file: "30")
            let secondOwned = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 1
            )
            XCTAssertEqual(secondOwned.count, 1)

            await launcher.kill()
            let afterSecondKill = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 0
            )
            XCTAssertTrue(afterSecondKill.isEmpty)
            XCTAssertTrue(trackedOwnedBenchmarkPIDs(for: editor).isEmpty)
        } catch {
            await launcher.kill()
            throw error
        }
    }

    func testRetryAfterWindowFailureReapsForkedRawZedChildBeforeRelaunch() async throws {
        let tempRoot = try makeTemporaryDirectory()
        let binaryURL = try compileSleepBinary(in: tempRoot, basename: "zed")
        let cliURL = try writeForkingCLI(in: tempRoot, childPath: binaryURL.path)
        defer {
            unsetenv("KERN_BENCH_ZED_CLI")
            try? FileManager.default.removeItem(at: cliURL)
            try? FileManager.default.removeItem(at: binaryURL)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        setenv("KERN_BENCH_ZED_CLI", cliURL.path, 1)

        let editor = makeFakeForkedZedEditor()
        clearTrackedOwnedBenchmarkPIDs(for: editor)
        let launcher = EditorLauncher(editor: editor)
        let baseline = Set(findPIDsByExactCommandPath(binaryURL.path))

        do {
            let firstLaunch = try await launcher.launch(file: "30")
            let firstOwned = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 1
            )
            XCTAssertEqual(firstOwned.count, 1)
            XCTAssertTrue(firstOwned.contains(firstLaunch.pid))
            XCTAssertFalse(trackedOwnedBenchmarkPIDs(for: editor).isEmpty)

            let firstWindow = await waitForWindow(pid: firstLaunch.pid, timeout: 0.05, expectedFileName: "30")
            XCTAssertNil(firstWindow)

            await launcher.kill()
            let afterRetryCleanup = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 0
            )
            XCTAssertTrue(afterRetryCleanup.isEmpty)

            let secondLaunch = try await launcher.launch(file: "30")
            let secondOwned = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 1
            )
            XCTAssertEqual(secondOwned.count, 1)
            XCTAssertTrue(secondOwned.contains(secondLaunch.pid))
            XCTAssertNotEqual(secondOwned, firstOwned)

            await launcher.kill()
            let finalOwned = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 0
            )
            XCTAssertTrue(finalOwned.isEmpty)
            XCTAssertTrue(trackedOwnedBenchmarkPIDs(for: editor).isEmpty)
        } catch {
            await launcher.kill()
            throw error
        }
    }

    func testLaunchWindowRetryHelperReapsForkedRawZedChildBeforeAttemptTwo() async throws {
        let tempRoot = try makeTemporaryDirectory()
        let binaryURL = try compileSleepBinary(in: tempRoot, basename: "zed")
        let argumentLogURL = tempRoot.appendingPathComponent("launch-args.log")
        let hookSignalPath = tempRoot.appendingPathComponent("zed-bench-ready.signal").path
        let cliURL = try writeForkingCLI(in: tempRoot, childPath: binaryURL.path, argumentLogURL: argumentLogURL)
        defer {
            unsetenv("KERN_BENCH_ZED_CLI")
            try? FileManager.default.removeItem(at: cliURL)
            try? FileManager.default.removeItem(at: binaryURL)
            try? FileManager.default.removeItem(at: argumentLogURL)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        setenv("KERN_BENCH_ZED_CLI", cliURL.path, 1)

        let editor = makeFakeForkedZedEditor()
        clearTrackedOwnedBenchmarkPIDs(for: editor)
        let launcher = EditorLauncher(editor: editor)
        let baseline = Set(findPIDsByExactCommandPath(binaryURL.path))

        let now = monotonicNowNs()
        let runDeadlineNs = now + 5_000_000_000
        let suiteDeadlineNs = now + 10_000_000_000
        var config = BenchConfig()
        config.zedBenchHookMode = .auto

        var waitCallCount = 0
        var sawZeroBeforeRetry = false
        var waitedPIDs: [pid_t] = []
        var waitedFileNames: [String?] = []
        let dependencies = LaunchWindowRetryDependencies(
            nowNs: monotonicNowNs,
            processIsAlive: processIsAlive,
            waitForWindow: { pid, _, expectedFileName in
                waitCallCount += 1
                waitedPIDs.append(pid)
                waitedFileNames.append(expectedFileName)
                if waitCallCount == 1 {
                    return nil
                }
                return DetectedWindow(
                    windowID: 1,
                    timestampNs: monotonicNowNs(),
                    bounds: CGRect(x: 0, y: 0, width: 640, height: 480)
                )
            },
            log: { _ in },
            afterRetryCleanup: {
                let current = Set(findPIDsByExactCommandPath(binaryURL.path)).subtracting(baseline)
                XCTAssertTrue(current.isEmpty)
                sawZeroBeforeRetry = true
            }
        )

        do {
            let outcome = await performLaunchWindowAttempts(
                launcher: launcher,
                editor: editor,
                runIdx: 1,
                runFile: "30",
                launchEnv: [:],
                runDeadlineNs: runDeadlineNs,
                suiteDeadlineNs: suiteDeadlineNs,
                openStageBudget: { 0.05 },
                deadlineReason: { "run_timeout" },
                config: config,
                zedBenchHookSignalPath: hookSignalPath,
                dependencies: dependencies
            )

            XCTAssertEqual(waitCallCount, 2)
            XCTAssertTrue(sawZeroBeforeRetry)
            XCTAssertEqual(waitedFileNames, ["30", "30"])
            XCTAssertNil(outcome.failureReason)
            XCTAssertFalse(outcome.failureTimedOut)
            XCTAssertNotNil(outcome.window)
            XCTAssertFalse(outcome.launchedWithZedBenchHook)
            let liveOwned = Set(findPIDsByExactCommandPath(binaryURL.path)).subtracting(baseline)
            XCTAssertEqual(liveOwned.count, 1)
            XCTAssertEqual(trackedOwnedBenchmarkPIDs(for: editor).filter { $0 > 0 }.count, 2)
            if let launchResult = outcome.launchResult {
                XCTAssertTrue(liveOwned.contains(launchResult.pid))
                XCTAssertEqual(waitedPIDs.last, launchResult.pid)
                XCTAssertNotEqual(waitedPIDs.first, launchResult.pid)
            } else {
                XCTFail("Expected retry helper to return a launch result")
            }

            let launchLog = try String(contentsOf: argumentLogURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(launchLog.count, 2)
            XCTAssertTrue(launchLog[0].contains("--bench-target-file"))
            XCTAssertTrue(launchLog[0].contains("--bench-ready-signal"))
            XCTAssertTrue(launchLog[0].contains(hookSignalPath))
            XCTAssertFalse(launchLog[1].contains("--bench-ready-signal"))

            await launcher.kill()
            let finalOwned = try await waitForExactPathDelta(
                binaryURL.path,
                baseline: baseline,
                expectedCount: 0
            )
            XCTAssertTrue(finalOwned.isEmpty)
            XCTAssertTrue(trackedOwnedBenchmarkPIDs(for: editor).isEmpty)
        } catch {
            await launcher.kill()
            throw error
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-bench-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func compileSleepBinary(in root: URL, basename: String = "kbt-\(UUID().uuidString)") throws -> URL {
        let sourceURL = root.appendingPathComponent("\(basename).c")
        let source = """
        #include <stdlib.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
            unsigned int seconds = 30;
            if (argc > 1) {
                seconds = (unsigned int)strtoul(argv[1], NULL, 10);
                if (seconds == 0) seconds = 30;
            }
            sleep(seconds);
            return 0;
        }
        """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let binaryURL = root.appendingPathComponent(basename)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        proc.arguments = [sourceURL.path, "-o", binaryURL.path]
        proc.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8) ?? "unknown"
            throw XCTSkip("Local C compiler unavailable for benchmark-owned PID regression coverage: \(message)")
        }
        return binaryURL
    }

    private func writeForkingCLI(in root: URL, childPath: String, argumentLogURL: URL? = nil) throws -> URL {
        let cliURL = root.appendingPathComponent("cli")
        let logSnippet: String
        if let argumentLogURL {
            logSnippet = """
            printf '%s\\n' \"$*\" >> '\(argumentLogURL.path)'
            """
        } else {
            logSnippet = ""
        }
        let script = """
        #!/bin/sh
        child=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --zed)
              child="$2"
              shift 2
              ;;
            *)
              break
              ;;
          esac
        done
        if [ -z "$child" ]; then
          exit 64
        fi
        \(logSnippet)
        "$child" "${1:-30}" >/dev/null 2>&1 &
        exit 0
        """
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: childPath))
        return cliURL
    }

    private func makeFakeCLIEditor(binaryPath: String) -> EditorDefinition {
        .init(
            displayName: "BenchSleep-\(UUID().uuidString)",
            appName: "BenchSleep",
            bundleIdentifier: "dev.kern.benchsleep.\(UUID().uuidString)",
            processName: URL(fileURLWithPath: binaryPath).lastPathComponent,
            architecture: "Test",
            isElectron: false,
            cliLaunchCommand: ["/usr/bin/env", binaryPath],
            cleanLaunchArgs: [],
            helperProcessPrefix: nil,
            requiredForOfficial: false
        )
    }

    private func makeFakeForkedZedEditor() -> EditorDefinition {
        .init(
            displayName: "Zed",
            appName: "Zed",
            bundleIdentifier: "dev.kern.bench.zed.\(UUID().uuidString)",
            processName: "zed",
            architecture: "Test",
            isElectron: false,
            cliLaunchCommand: ["zed"],
            cleanLaunchArgs: [],
            helperProcessPrefix: nil,
            requiredForOfficial: false
        )
    }

    private func waitForExactPathDelta(
        _ path: String,
        baseline: Set<pid_t>,
        expectedCount: Int,
        timeout: TimeInterval = 3.0
    ) async throws -> Set<pid_t> {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = Set(findPIDsByExactCommandPath(path)).subtracting(baseline)
            if current.count == expectedCount {
                return current
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let current = Set(findPIDsByExactCommandPath(path)).subtracting(baseline)
        XCTAssertEqual(current.count, expectedCount, "Unexpected exact-path PID delta for \(path)")
        return current
    }
}
