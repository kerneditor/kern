import Foundation
import XCTest

enum TestRuntimeConfig {
    private static let suiteDomain = "com.gradigit.kern.tests"
    private static var suite: UserDefaults? { UserDefaults(suiteName: suiteDomain) }

    static func string(_ key: String) -> String? {
        if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
            return envValue
        }
        if let suiteValue = suite?.string(forKey: key), !suiteValue.isEmpty {
            return suiteValue
        }
        if let raw = suite?.object(forKey: key) {
            let value = String(describing: raw)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = string(key) else { return defaultValue }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return defaultValue
        }
    }

    static func int(_ key: String, default defaultValue: Int? = nil) -> Int? {
        guard let raw = string(key) else { return defaultValue }
        return Int(raw) ?? defaultValue
    }
}

enum TestGates {
    static var exhaustive: Bool {
        TestRuntimeConfig.bool("KERN_ENABLE_EXHAUSTIVE_TESTS")
    }

    static var snapshots: Bool {
        TestRuntimeConfig.bool("KERN_ENABLE_SNAPSHOT_TESTS")
    }

    static var specConformance: Bool {
        TestRuntimeConfig.bool("KERN_ENABLE_SPEC_CONFORMANCE_TESTS")
            || exhaustive
    }

    static var recordSnapshots: Bool {
        TestRuntimeConfig.bool("KERN_RECORD_SNAPSHOTS")
    }

    static func skipUnlessExhaustive(_ message: String = "Set KERN_ENABLE_EXHAUSTIVE_TESTS=1 to run exhaustive tests") throws {
        try XCTSkipUnless(exhaustive, message)
    }

    static func skipUnlessSnapshots(_ message: String = "Set KERN_ENABLE_SNAPSHOT_TESTS=1 to run snapshot tests") throws {
        try XCTSkipUnless(snapshots, message)
    }

    static func skipUnlessSpecConformance(_ message: String = "Set KERN_ENABLE_SPEC_CONFORMANCE_TESTS=1 to run strict Markdown spec conformance tests") throws {
        try XCTSkipUnless(specConformance, message)
    }
}
