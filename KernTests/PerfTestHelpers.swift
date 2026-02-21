import AppKit
import Foundation
import XCTest
@testable import KernTextKit

// MARK: - Shared performance-test utilities

/// Load a test fixture from `test-fixtures/` and strip remote images.
func loadPerfFixture(name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // KernTests/
        .deletingLastPathComponent() // repo root
    let url = root.appendingPathComponent("test-fixtures").appendingPathComponent(name)
    let raw = try String(contentsOf: url, encoding: .utf8)
    return stripRemoteImages(raw)
}

/// Replace remote image URLs with local placeholders to avoid network
/// latency (and firewall popups) skewing benchmark results.
func stripRemoteImages(_ md: String) -> String {
    guard let re = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(https?://[^)]+\)"#) else { return md }
    let ns = md as NSString
    return re.stringByReplacingMatches(in: md, range: NSRange(location: 0, length: ns.length),
                                       withTemplate: #"![$1](screenshots/01-default-sample.png)"#)
}

/// Truncate fixture at `limit` characters, breaking at the last newline.
func boundedFixture(_ source: String, envLimitKey: String, defaultLimit: Int) -> String {
    let limit = max(1, TestRuntimeConfig.int(envLimitKey, default: defaultLimit) ?? defaultLimit)
    guard source.count > limit else { return source }
    let end = source.index(source.startIndex, offsetBy: limit)
    var bounded = String(source[..<end])
    if let lastNewline = bounded.lastIndex(of: "\n") {
        bounded = String(bounded[...lastNewline])
    }
    return bounded
}

/// Like `boundedFixture` but respects `KERN_PERF_RENDER_FULL` to bypass truncation.
func boundedRenderFixture(_ source: String, envLimitKey: String, defaultLimit: Int) -> String {
    if TestRuntimeConfig.bool("KERN_PERF_RENDER_FULL") {
        return source
    }
    return boundedFixture(source, envLimitKey: envLimitKey, defaultLimit: defaultLimit)
}

/// Build `XCTMeasureOptions` with env-overridable iteration count (default: 5).
func defaultPerformanceOptions(defaultIterations: Int = 5) -> XCTMeasureOptions {
    let options = XCTMeasureOptions.default
    let iterations = max(1, TestRuntimeConfig.int("KERN_PERF_ITERATIONS", default: defaultIterations) ?? defaultIterations)
    options.iterationCount = iterations
    return options
}

/// Recursively find a subview by its accessibility identifier.
@MainActor
func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == id { return view }
    for sub in view.subviews {
        if let found = findSubview(withAXIdentifier: id, in: sub) { return found }
    }
    return nil
}
