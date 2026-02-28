import Foundation

struct MetricSeries {
    var values: [Double] = []
    var failures = 0
    var timeouts = 0
    var attempts = 0
    var lastFailureReason: String?

    mutating func record(value: Double?, failureReason: String?, timedOut: Bool) {
        attempts += 1
        if let value {
            values.append(value)
        } else {
            failures += 1
            if timedOut {
                timeouts += 1
            }
            if let failureReason {
                lastFailureReason = failureReason
            }
        }
    }

    func toStats() -> Stats? {
        guard attempts > 0 else { return nil }
        return computeStats(
            values,
            failures: failures,
            timeouts: timeouts,
            totalAttempts: attempts
        )
    }
}

struct MetricCollector {
    private(set) var series: [String: MetricSeries] = [:]

    mutating func record(metric: String, value: Double?, failureReason: String? = nil, timedOut: Bool = false) {
        var current = series[metric] ?? MetricSeries()
        current.record(value: value, failureReason: failureReason, timedOut: timedOut)
        series[metric] = current
    }

    func stats(metric: String) -> Stats? {
        series[metric]?.toStats()
    }

    func failureReasonMap() -> [String: String] {
        var map: [String: String] = [:]
        for (metric, s) in series {
            if let reason = s.lastFailureReason {
                map[metric] = reason
            }
        }
        return map
    }
}
