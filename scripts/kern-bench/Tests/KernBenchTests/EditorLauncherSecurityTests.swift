import XCTest
@testable import kern_bench

final class EditorLauncherSecurityTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() {
        super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-bench-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        super.tearDown()
    }

    func testSanitizedBenchmarkProcessEnvironmentKeepsAllowlistedBaseAndOverrides() {
        let sanitized = sanitizedBenchmarkProcessEnvironment(
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/test",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "SECRET_TOKEN": "nope",
                "AWS_SECRET_ACCESS_KEY": "nope"
            ],
            overrides: [
                "KERN_BENCH_PROFILE_LABEL": "default",
                "KERN_STAGED_PROMOTION_CONTEXT_CHARS": "1000"
            ]
        )

        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["HOME"], "/Users/test")
        XCTAssertEqual(sanitized["LANG"], "en_US.UTF-8")
        XCTAssertEqual(sanitized["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(sanitized["KERN_BENCH_PROFILE_LABEL"], "default")
        XCTAssertEqual(sanitized["KERN_STAGED_PROMOTION_CONTEXT_CHARS"], "1000")
        XCTAssertNil(sanitized["SECRET_TOKEN"])
        XCTAssertNil(sanitized["AWS_SECRET_ACCESS_KEY"])
    }

    func testBenchmarkCleanLaunchArgsUsesUniqueProfileDirsForEditorsThatNeedThem() {
        let vscode = try! XCTUnwrap(findEditor(named: "VS Code"))
        let args = try! benchmarkCleanLaunchArgs(
            for: vscode,
            temporaryRoot: temporaryRoot.path,
            uniqueSuffix: "fixture-a"
        )

        XCTAssertEqual(args.first, "--new-window")
        XCTAssertTrue(args.contains("--user-data-dir"))
        let userDataIndex = try! XCTUnwrap(args.firstIndex(of: "--user-data-dir"))
        XCTAssertEqual(
            args[userDataIndex + 1],
            temporaryRoot
                .appendingPathComponent("kern-bench-profiles", isDirectory: true)
                .appendingPathComponent("code", isDirectory: true)
                .appendingPathComponent("fixture-a", isDirectory: true)
                .path
        )
        XCTAssertTrue(args.contains("--disable-extensions"))
    }

    func testBenchmarkCleanLaunchArgsLeavesEditorsWithoutProfilesUntouched() {
        let kern = try! XCTUnwrap(findEditor(named: "Kern"))
        let args = try! benchmarkCleanLaunchArgs(
            for: kern,
            temporaryRoot: temporaryRoot.path,
            uniqueSuffix: "fixture-b"
        )

        XCTAssertEqual(args, ["-ApplePersistenceIgnoreState", "YES"])
    }

    func testBenchmarkCleanLaunchArgsCreatesPrivateProfileDirectory() throws {
        let vscode = try XCTUnwrap(findEditor(named: "VS Code"))
        let args = try benchmarkCleanLaunchArgs(
            for: vscode,
            temporaryRoot: temporaryRoot.path,
            uniqueSuffix: "fixture-private"
        )

        let userDataIndex = try XCTUnwrap(args.firstIndex(of: "--user-data-dir"))
        let profilePath = args[userDataIndex + 1]
        let attributes = try FileManager.default.attributesOfItem(atPath: profilePath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testBenchmarkCleanLaunchArgsRejectsSymlinkedProfileRootAndFallsBack() throws {
        let symlinkTarget = temporaryRoot.appendingPathComponent("symlink-target", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
        let symlinkRoot = temporaryRoot.appendingPathComponent("kern-bench-profiles", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: symlinkTarget)

        let vscode = try XCTUnwrap(findEditor(named: "VS Code"))
        let args = try benchmarkCleanLaunchArgs(
            for: vscode,
            temporaryRoot: temporaryRoot.path,
            uniqueSuffix: "fixture-symlink"
        )

        let userDataIndex = try XCTUnwrap(args.firstIndex(of: "--user-data-dir"))
        let profilePath = args[userDataIndex + 1]
        XCTAssertFalse(profilePath.hasPrefix(symlinkRoot.path + "/"))

        let attributes = try FileManager.default.attributesOfItem(atPath: profilePath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testBenchmarkCleanLaunchArgsThrowsWhenNoSecureProfileRootCanBeCreated() throws {
        let fileRoot = temporaryRoot.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("x".utf8).write(to: fileRoot)

        let vscode = try XCTUnwrap(findEditor(named: "VS Code"))
        XCTAssertThrowsError(
            try benchmarkCleanLaunchArgs(
                for: vscode,
                temporaryRoot: fileRoot.path,
                fallbackTemporaryRoot: fileRoot.path,
                uniqueSuffix: "fixture-fail-closed"
            )
        ) { error in
            guard case LaunchError.privateProfileDirectoryUnavailable(let processName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(processName, vscode.processName)
        }
    }

    func testBenchmarkCleanLaunchArgsRejectsRequestedRootWithUnexpectedOwnerAndFallsBack() throws {
        let requestedRoot = temporaryRoot.appendingPathComponent("requested-root", isDirectory: true)
        let fallbackRoot = temporaryRoot.appendingPathComponent("fallback-root", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)

        let requestedProfiles = requestedRoot.appendingPathComponent("kern-bench-profiles", isDirectory: true)
        let requestedEditorRoot = requestedProfiles.appendingPathComponent("code", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedProfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: requestedEditorRoot, withIntermediateDirectories: true)

        let vscode = try XCTUnwrap(findEditor(named: "VS Code"))
        let args = try benchmarkCleanLaunchArgs(
            for: vscode,
            temporaryRoot: requestedRoot.path,
            fallbackTemporaryRoot: fallbackRoot.path,
            uniqueSuffix: "fixture-owner-fallback",
            ownerValidator: { _ in false }
        )

        let userDataIndex = try XCTUnwrap(args.firstIndex(of: "--user-data-dir"))
        let profilePath = args[userDataIndex + 1]
        XCTAssertFalse(profilePath.hasPrefix(requestedRoot.path + "/"))
        XCTAssertTrue(profilePath.hasPrefix(fallbackRoot.path + "/"))
    }

    func testBenchmarkCleanLaunchArgsThrowsWhenExistingRootsFailOwnerValidation() throws {
        let requestedRoot = temporaryRoot.appendingPathComponent("requested-root-throw", isDirectory: true)
        let fallbackRoot = temporaryRoot.appendingPathComponent("fallback-root-throw", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: requestedRoot.appendingPathComponent("kern-bench-profiles", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fallbackRoot.appendingPathComponent("kern-bench-profiles", isDirectory: true),
            withIntermediateDirectories: true
        )

        let vscode = try XCTUnwrap(findEditor(named: "VS Code"))
        XCTAssertThrowsError(
            try benchmarkCleanLaunchArgs(
                for: vscode,
                temporaryRoot: requestedRoot.path,
                fallbackTemporaryRoot: fallbackRoot.path,
                uniqueSuffix: "fixture-owner-throw",
                ownerValidator: { _ in false }
            )
        ) { error in
            guard case LaunchError.privateProfileDirectoryUnavailable(let processName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(processName, vscode.processName)
        }
    }
}
