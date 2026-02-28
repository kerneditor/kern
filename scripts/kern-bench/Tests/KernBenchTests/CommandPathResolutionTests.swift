import XCTest
@testable import kern_bench

final class CommandPathResolutionTests: XCTestCase {
    func testResolveCommandPathAcceptsAbsoluteExecutablePath() {
        let resolved = resolveCommandPath("/bin/echo")
        XCTAssertEqual(resolved, "/bin/echo")
    }

    func testResolveCommandPathRejectsMissingAbsolutePath() {
        let resolved = resolveCommandPath("/definitely/not/a/real/executable")
        XCTAssertNil(resolved)
    }

    func testResolveCommandPathFindsCommandsOnPath() {
        let resolved = resolveCommandPath("which")
        XCTAssertNotNil(resolved)
    }

    func testShouldUseProcessNameFallbackIsDisabledWhenCLIAndProcessNameMatch() {
        XCTAssertFalse(
            shouldUseProcessNameFallback(cliLaunchCommand: ["zed"], processName: "zed")
        )
        XCTAssertFalse(
            shouldUseProcessNameFallback(
                cliLaunchCommand: ["/Applications/Zed.app/Contents/MacOS/zed"],
                processName: "zed"
            )
        )
    }

    func testShouldUseProcessNameFallbackWhenCLIAndProcessNameDiffer() {
        XCTAssertTrue(
            shouldUseProcessNameFallback(cliLaunchCommand: ["subl"], processName: "sublime_text")
        )
        XCTAssertTrue(
            shouldUseProcessNameFallback(cliLaunchCommand: nil, processName: "TextEdit")
        )
    }

    func testResolveZedCLICommandUsesEnvOverride() {
        let resolution = resolveZedCLICommand(
            defaultCommand: ["zed"],
            environment: ["KERN_BENCH_ZED_CLI": "~/Projects/zed-fork-bench/target/debug/cli"],
            isExecutable: { _ in true }
        )

        XCTAssertEqual(resolution.source, .envOverride)
        XCTAssertEqual(resolution.command?.first, "\(NSHomeDirectory())/Projects/zed-fork-bench/target/debug/cli")
    }

    func testResolveZedCLICommandUsesAutoForkWhenPresent() {
        let candidate = "\(NSHomeDirectory())/Projects/zed-fork-bench/target/release/cli"
        let resolution = resolveZedCLICommand(
            defaultCommand: ["zed"],
            environment: [:],
            currentDirectoryPath: "/tmp/irrelevant",
            isExecutable: { path in path == candidate }
        )

        XCTAssertEqual(resolution.source, .autoFork)
        XCTAssertEqual(resolution.command?.first, candidate)
    }

    func testResolveZedCLICommandFallsBackToDefault() {
        let resolution = resolveZedCLICommand(
            defaultCommand: ["zed"],
            environment: [:],
            currentDirectoryPath: "/tmp/irrelevant",
            isExecutable: { _ in false }
        )

        XCTAssertEqual(resolution.source, .defaultCLI)
        XCTAssertEqual(resolution.command?.first, "zed")
    }
}
