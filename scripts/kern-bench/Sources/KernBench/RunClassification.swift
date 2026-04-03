import Foundation

enum RunQuality: String, Codable {
    case complete
    case degraded
}

enum RunClassification: String, Codable {
    case official
    case partial
}

struct PreflightStatus: Codable {
    let thermalAtStartOK: Bool
    let thermalThroughoutOK: Bool
    let rosterComplete: Bool
    let screenCapturePermissionOK: Bool
    let accessibilityPermissionOK: Bool
    let fixtureHashRecorded: Bool
    let powerSource: String
    let thermalPctStart: Int
    let thermalPctEnd: Int
}

struct ClassificationOutcome {
    let runQuality: RunQuality
    let runClassification: RunClassification
    let partialReasons: [String]
}

func classifyEditorResult(
    suite: SuiteDefinition,
    result: EditorResult,
    preflight: PreflightStatus
) -> ClassificationOutcome {
    var partialReasons: [String] = []
    var degraded = false

    if !preflight.thermalAtStartOK || !preflight.thermalThroughoutOK {
        partialReasons.append("thermal_throttle")
    }
    if !preflight.screenCapturePermissionOK {
        partialReasons.append("permission_screen_recording_missing")
    }
    if !preflight.accessibilityPermissionOK {
        partialReasons.append("permission_accessibility_missing")
    }

    let statsByMetric = result.stats?.metricDictionary() ?? [:]
    var failureSummaryByMetric: [String: MetricFailureSummary] = [:]
    for metric in suite.requiredMetrics {
        let runFailureSummary = metricFailureSummary(metric: metric, runs: result.runs)
        failureSummaryByMetric[metric] = runFailureSummary
        let metricStats = statsByMetric[metric]
        let presentByValue = (metricStats?.n ?? 0) > 0
        let presentByFailure = (metricStats?.failures ?? 0) > 0 || (metricStats?.timeouts ?? 0) > 0
        let presentByRunFailure = runFailureSummary.hasFailures || runFailureSummary.hasTimeouts
        let present = presentByValue || presentByFailure || presentByRunFailure
        if !present {
            degraded = true
            partialReasons.append("required_metric_missing:\(metric)")
            if let cause = runFailureSummary.mostCommonReason {
                partialReasons.append("required_metric_missing_cause:\(metric):\(cause)")
            }
        }
    }

    if let stats = result.stats {
        for key in suite.requiredMetrics {
            let summary = failureSummaryByMetric[key] ?? metricFailureSummary(metric: key, runs: result.runs)
            if let m = statsByMetric[key] {
                let hasFailures = (m.failures ?? 0) > 0 || summary.hasFailures
                let hasTimeouts = (m.timeouts ?? 0) > 0 || summary.hasTimeouts
                guard hasFailures || hasTimeouts else { continue }
                degraded = true
                if hasFailures {
                    partialReasons.append("metric_failure:\(key)")
                }
                if hasTimeouts {
                    partialReasons.append("metric_timeout:\(key)")
                }
            } else if summary.hasFailures || summary.hasTimeouts {
                degraded = true
                if summary.hasFailures {
                    partialReasons.append("metric_failure:\(key)")
                }
                if summary.hasTimeouts {
                    partialReasons.append("metric_timeout:\(key)")
                }
            }
        }
        _ = stats // keep explicit access for compiler mode consistency
    }

    let uniqueReasons = Array(Set(partialReasons)).sorted()
    let classification: RunClassification = uniqueReasons.isEmpty ? .official : .partial
    let quality: RunQuality = degraded || classification == .partial ? .degraded : .complete

    return ClassificationOutcome(
        runQuality: quality,
        runClassification: classification,
        partialReasons: uniqueReasons
    )
}

private struct MetricFailureSummary {
    let hasFailures: Bool
    let hasTimeouts: Bool
    let mostCommonReason: String?
}

private func metricFailureSummary(metric: String, runs: [RunResult]) -> MetricFailureSummary {
    var counts: [String: Int] = [:]
    var hasFailures = false
    var hasTimeouts = false
    for run in runs {
        guard let reason = run.metricFailureReasons[metric],
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }
        hasFailures = true
        if reason.lowercased().contains("timeout") {
            hasTimeouts = true
        }
        counts[reason, default: 0] += 1
    }
    let mostCommonReason = counts.max { lhs, rhs in
        if lhs.value == rhs.value {
            return lhs.key > rhs.key
        }
        return lhs.value < rhs.value
    }?.key
    return MetricFailureSummary(
        hasFailures: hasFailures,
        hasTimeouts: hasTimeouts,
        mostCommonReason: mostCommonReason
    )
}

func classifyReport(
    suite: SuiteDefinition,
    preflight: PreflightStatus,
    editorResults: [EditorResult],
    selectedEditors: [EditorDefinition],
    runs: Int = 1,
    warmupRuns: Int = 0,
    interEditorCooldownMs: Int = 0,
    profile: String = "direct",
    injectedOverrides: [String: String]? = nil
) -> ClassificationOutcome {
    var reasons: [String] = []

    let selectedNames = Set(selectedEditors.map(\.displayName))
    let requiredNames = Set(suite.requiredRoster)
    if selectedNames != requiredNames {
        let missing = requiredNames.subtracting(selectedNames).sorted()
        if !missing.isEmpty {
            reasons.append("missing_roster_editors:\(missing.joined(separator: ","))")
        }
    }

    let claimSafeNames = Set(suite.claimSafeRoster)
    if !claimSafeNames.isEmpty, selectedNames != claimSafeNames {
        let expected = suite.claimSafeRoster.sorted().joined(separator: ",")
        let selected = selectedNames.sorted().joined(separator: ",")
        reasons.append("claim_safe_roster_mismatch:expected=\(expected):selected=\(selected)")
    } else if !claimSafeNames.isEmpty {
        if let minimumRuns = suite.claimSafeMinimumRuns, runs < minimumRuns {
            reasons.append("claim_safe_min_runs_unmet:required=\(minimumRuns):actual=\(runs)")
        }
        if let minimumWarmupRuns = suite.claimSafeMinimumWarmupRuns, warmupRuns < minimumWarmupRuns {
            reasons.append("claim_safe_min_warmups_unmet:required=\(minimumWarmupRuns):actual=\(warmupRuns)")
        }
        if selectedEditors.count > 1,
           let minimumCooldown = suite.claimSafeMinimumInterEditorCooldownMs,
           interEditorCooldownMs < minimumCooldown {
            reasons.append("claim_safe_inter_editor_cooldown_unmet:required=\(minimumCooldown):actual=\(interEditorCooldownMs)")
        }
    }
    if !claimSafeNames.isEmpty {
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProfile != "default", normalizedProfile != "direct" {
            reasons.append("claim_safe_profile_mismatch:expected=default|direct:selected=\(profile)")
        }
        if let injectedOverrides, !injectedOverrides.isEmpty {
            let overrideKeys = injectedOverrides.keys.sorted().joined(separator: ",")
            reasons.append("claim_safe_override_mismatch:keys=\(overrideKeys)")
        }
    }

    if !preflight.thermalAtStartOK || !preflight.thermalThroughoutOK {
        reasons.append("thermal_throttle")
    }
    if !preflight.screenCapturePermissionOK {
        reasons.append("permission_screen_recording_missing")
    }
    if !preflight.accessibilityPermissionOK {
        reasons.append("permission_accessibility_missing")
    }
    if !preflight.fixtureHashRecorded {
        reasons.append("fixture_hash_missing")
    }

    var degraded = false
    for result in editorResults {
        let editorOutcome = classifyEditorResult(suite: suite, result: result, preflight: preflight)
        if editorOutcome.runQuality == .degraded {
            degraded = true
        }
        reasons.append(contentsOf: editorOutcome.partialReasons.map { "\(result.editor):\($0)" })
    }

    let uniqueReasons = Array(Set(reasons)).sorted()
    let classification: RunClassification = uniqueReasons.isEmpty ? .official : .partial
    let quality: RunQuality = degraded || classification == .partial ? .degraded : .complete

    return ClassificationOutcome(
        runQuality: quality,
        runClassification: classification,
        partialReasons: uniqueReasons
    )
}
