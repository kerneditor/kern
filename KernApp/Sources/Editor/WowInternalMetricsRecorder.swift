import Foundation

@MainActor
final class WowInternalMetricsRecorder {
    static let shared = WowInternalMetricsRecorder()

    private enum Stage: String, CaseIterable {
        case parse = "wow_parse_latency_ms"
        case layout = "wow_layout_latency_ms"
        case paintReady = "wow_paint_ready_latency_ms"
        case editApply = "wow_edit_apply_latency_ms"
        case saveSerialize = "wow_save_serialize_latency_ms"
        case openReady = "wow_open_ready_latency_ms"
        case viewportSemanticReady = "wow_viewport_semantic_ready_latency_ms"
        case viewportFidelityReady = "wow_viewport_fidelity_ready_latency_ms"
        case fullDocumentFidelityReady = "wow_full_document_fidelity_ready_latency_ms"
    }

    private var starts: [Stage: UInt64] = [:]
    private var metrics: [String: Double] = [:]
    private var failureReasons: [String: String] = [:]
    private var metricSamples: [String: [Double]] = [:]
    private var dirtySampleMetricKeys: Set<String> = []
    private var p99MetricKeyOverrides: [String: String] = [:]
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var lastPersistUptime: TimeInterval = 0
    private let persistCoalesceSeconds: TimeInterval = 0.08

    private init() {}

    private var outputPath: String? {
        let raw = ProcessInfo.processInfo.environment["KERN_WOW_INTERNAL_METRICS_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    var isEnabled: Bool { outputPath != nil }

    func beginRun() {
        guard isEnabled else { return }
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        starts.removeAll(keepingCapacity: true)
        metrics.removeAll(keepingCapacity: true)
        failureReasons.removeAll(keepingCapacity: true)
        metricSamples.removeAll(keepingCapacity: true)
        dirtySampleMetricKeys.removeAll(keepingCapacity: true)
        p99MetricKeyOverrides.removeAll(keepingCapacity: true)
        persist(immediate: true)
    }

    func beginParse() { begin(.parse) }
    func endParse() { end(.parse) }

    func beginLayout() { begin(.layout) }
    func endLayout() { end(.layout) }

    func beginPaintReady() { begin(.paintReady) }
    func endPaintReady() { end(.paintReady) }

    func beginEditApply() { begin(.editApply) }
    func endEditApply() { end(.editApply) }

    func beginSaveSerialize() { begin(.saveSerialize) }
    func endSaveSerialize() { end(.saveSerialize) }

    func beginOpenReady() { begin(.openReady) }
    func endOpenReady() { end(.openReady) }

    func beginViewportSemanticReady() { begin(.viewportSemanticReady) }
    func endViewportSemanticReady() { end(.viewportSemanticReady) }

    func beginViewportFidelityReady() { begin(.viewportFidelityReady) }
    func endViewportFidelityReady() { end(.viewportFidelityReady) }

    func beginFullDocumentFidelityReady() { begin(.fullDocumentFidelityReady) }
    func endFullDocumentFidelityReady() { end(.fullDocumentFidelityReady) }

    func failEditApplyIfMissing() {
        fail(.editApply, reason: "edit_apply_missing")
    }

    func failFullDocumentFidelityIfMissing(reason: String = "full_document_fidelity_missing") {
        fail(.fullDocumentFidelityReady, reason: reason)
    }

    func recordAuxMetric(_ key: String, value: Double) {
        guard isEnabled else { return }
        metrics[key] = round(value * 100) / 100
        persist()
    }

    func recordMaxAuxMetric(_ key: String, candidate: Double) {
        guard isEnabled else { return }
        let rounded = round(candidate * 100) / 100
        if let existing = metrics[key], existing >= rounded {
            return
        }
        metrics[key] = rounded
        persist()
    }

    func incrementAuxCounter(_ key: String, by delta: Double = 1) {
        guard isEnabled else { return }
        metrics[key] = (metrics[key] ?? 0) + delta
        persist()
    }

    func recordAuxSample(
        _ key: String,
        sample: Double,
        p99MetricKey: String? = nil
    ) {
        guard isEnabled else { return }
        let rounded = round(sample * 100) / 100
        metricSamples[key, default: []].append(rounded)
        dirtySampleMetricKeys.insert(key)
        p99MetricKeyOverrides[key] = p99MetricKey ?? "\(key)_p99_ms"
        persist()
    }

    private func begin(_ stage: Stage) {
        guard isEnabled else { return }
        if metrics[stage.rawValue] != nil || failureReasons[stage.rawValue] != nil { return }
        starts[stage] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private func end(_ stage: Stage) {
        guard isEnabled else { return }
        guard metrics[stage.rawValue] == nil, failureReasons[stage.rawValue] == nil else { return }
        guard let start = starts.removeValue(forKey: stage) else { return }
        let elapsedMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
        let rounded = round(elapsedMs * 100) / 100
        metrics[stage.rawValue] = rounded
        if stage == .openReady {
            metrics["time_to_interactive_ms"] = rounded
        } else if stage == .fullDocumentFidelityReady {
            metrics["time_to_full_fidelity_ms"] = rounded
        }
        persist(immediate: true)
    }

    private func fail(_ stage: Stage, reason: String) {
        guard isEnabled else { return }
        guard metrics[stage.rawValue] == nil else { return }
        starts.removeValue(forKey: stage)
        failureReasons[stage.rawValue] = reason
        persist(immediate: true)
    }

    private func persist(immediate: Bool = false) {
        guard outputPath != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if immediate || now - lastPersistUptime >= persistCoalesceSeconds {
            pendingPersistWorkItem?.cancel()
            pendingPersistWorkItem = nil
            flushPersistNow()
            return
        }
        guard pendingPersistWorkItem == nil else { return }
        let delay = max(0.01, persistCoalesceSeconds - (now - lastPersistUptime))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPersistWorkItem = nil
            self.flushPersistNow()
        }
        pendingPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushPersistNow() {
        guard let outputPath else { return }
        materializeDirtySampleMetrics()
        let payload = Payload(version: 1, metrics: metrics, failureReasons: failureReasons)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            lastPersistUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            // Best effort only; benchmark runner will classify missing instrumentation.
        }
    }

    private func materializeDirtySampleMetrics() {
        guard !dirtySampleMetricKeys.isEmpty else { return }
        let keys = dirtySampleMetricKeys
        dirtySampleMetricKeys.removeAll(keepingCapacity: true)

        for key in keys {
            guard let samples = metricSamples[key], !samples.isEmpty else { continue }
            let sorted = samples.sorted()
            let p99 = percentile(sorted, percentile: 0.99)
            let p95 = percentile(sorted, percentile: 0.95)
            let p50 = percentile(sorted, percentile: 0.50)
            let maxSample = sorted.last ?? 0

            let p99Key = p99MetricKeyOverrides[key] ?? "\(key)_p99_ms"
            metrics[p99Key] = round(p99 * 100) / 100
            metrics["\(key)_p95_ms"] = round(p95 * 100) / 100
            metrics["\(key)_p50_ms"] = round(p50 * 100) / 100
            metrics["\(key)_max_ms"] = round(maxSample * 100) / 100
        }
    }

    private func percentile(_ sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let p = max(0, min(1, percentile))
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(0, idx), sorted.count - 1)]
    }
}

private struct Payload: Codable {
    let version: Int
    let metrics: [String: Double]
    let failureReasons: [String: String]

    enum CodingKeys: String, CodingKey {
        case version
        case metrics
        case failureReasons = "failure_reasons"
    }
}
