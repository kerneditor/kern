import Foundation

enum SuiteID: String, Codable, CaseIterable {
    case benchmark = "benchmark"
    case benchmarkOpenReady = "benchmark_open_ready"
    case benchmarkFullFidelity = "benchmark_full_fidelity"
    case wowInternal = "wow_internal"

    var cliValue: String { rawValue }

    static func parse(_ value: String) -> SuiteID? {
        switch value.lowercased() {
        case "benchmark", "bench":
            return .benchmark
        case "benchmark_open_ready", "benchmark-open-ready", "benchmarkopenready", "open_ready", "open-ready", "openonly", "open_only":
            return .benchmarkOpenReady
        case "benchmark_full_fidelity", "benchmark-full-fidelity", "benchmarkfullfidelity", "full_fidelity", "full-fidelity", "fidelity":
            return .benchmarkFullFidelity
        case "wow_internal", "wow-internal", "wowinternal", "internal":
            return .wowInternal
        default:
            return nil
        }
    }
}

struct SuiteDefinition {
    let id: SuiteID
    let displayName: String
    let intendedUsage: String
    let defaultRuns: Int
    let defaultWarmupRuns: Int
    let claimSafeMinimumRuns: Int?
    let claimSafeMinimumWarmupRuns: Int?
    let claimSafeMinimumInterEditorCooldownMs: Int?
    let requiredRoster: [String]
    let claimSafeRoster: [String]
    let claimPolicyDescription: String
    let requiredMetrics: [String]
    let optionalMetrics: [String]
    let stageTimeouts: [String: TimeInterval]
    let suiteKind: String

    static func forID(_ id: SuiteID) -> SuiteDefinition {
        switch id {
        case .benchmark:
            return SuiteDefinition(
                id: .benchmark,
                displayName: "Core Benchmark",
                intendedUsage: "single benchmark comparison",
                defaultRuns: 30,
                defaultWarmupRuns: 3,
                claimSafeMinimumRuns: nil,
                claimSafeMinimumWarmupRuns: nil,
                claimSafeMinimumInterEditorCooldownMs: nil,
                requiredRoster: requiredRosterNames(),
                claimSafeRoster: requiredRosterNames(),
                claimPolicyDescription: "publishable claims require the locked roster v1",
                requiredMetrics: [
                    "open_latency_ms",
                    "save_ui_ack_latency_ms",
                    "quit_latency_ms",
                ],
                optionalMetrics: [
                    "typing_latency_ms",
                    "cold_start_latency_ms",
                    "warm_start_latency_ms",
                    "window_visible_ms",
                    "first_paint_ms",
                    "render_stable_ms",
                    "wow_open_ready_latency_ms",
                    "wow_viewport_semantic_ready_latency_ms",
                    "wow_viewport_fidelity_ready_latency_ms",
                    "wow_full_document_fidelity_ready_latency_ms",
                    "automation_overhead_ms",
                    "unattributed_open_budget_ms",
                    "time_to_stable_layout_ms",
                    "post_ready_export_quiescence_ms",
                    "time_to_interactive_ms",
                    "time_to_full_fidelity_ms",
                    "promotion_apply_slice_p99_ms",
                    "scroll_jump_count",
                    "scroll_jump_max_px",
                    "anchor_rebase_count",
                    "anchor_rebase_fail_count",
                ],
                stageTimeouts: [
                    "startup": 8,
                    "open": 8,
                    "typing": 2,
                    "save_ui": 1.2,
                    "save_durable": 2,
                    "quit": 3.5,
                ],
                suiteKind: "cross_editor"
            )
        case .benchmarkOpenReady:
            return SuiteDefinition(
                id: .benchmarkOpenReady,
                displayName: "Open-Ready Aside",
                intendedUsage: "optional huge-fixture open-readiness comparison (e.g., Kern vs Zed)",
                defaultRuns: 10,
                defaultWarmupRuns: 1,
                claimSafeMinimumRuns: 10,
                claimSafeMinimumWarmupRuns: 1,
                claimSafeMinimumInterEditorCooldownMs: 1500,
                requiredRoster: [],
                claimSafeRoster: ["Kern", "Zed"],
                claimPolicyDescription: "publishable head-to-head claims require the exact Kern,Zed roster, >=10 measured runs, >=1 warmup run, and >=1500ms inter-editor cooldown",
                requiredMetrics: [
                    "open_latency_ms",
                ],
                optionalMetrics: [
                    "window_visible_ms",
                    "cold_start_latency_ms",
                    "warm_start_latency_ms",
                    "first_paint_ms",
                    "render_stable_ms",
                    "wow_open_ready_latency_ms",
                    "wow_viewport_semantic_ready_latency_ms",
                    "wow_viewport_fidelity_ready_latency_ms",
                    "wow_full_document_fidelity_ready_latency_ms",
                    "automation_overhead_ms",
                    "unattributed_open_budget_ms",
                    "time_to_stable_layout_ms",
                    "post_ready_export_quiescence_ms",
                    "time_to_interactive_ms",
                    "time_to_full_fidelity_ms",
                    "promotion_apply_slice_p99_ms",
                    "scroll_jump_count",
                    "scroll_jump_max_px",
                    "anchor_rebase_count",
                    "anchor_rebase_fail_count",
                ],
                stageTimeouts: [
                    "startup": 8,
                    "open": 12,
                ],
                suiteKind: "cross_editor_open_only"
            )
        case .benchmarkFullFidelity:
            return SuiteDefinition(
                id: .benchmarkFullFidelity,
                displayName: "Full-Fidelity Aside",
                intendedUsage: "optional huge-fixture full-document-fidelity completion comparison (e.g., Kern vs Zed)",
                defaultRuns: 10,
                defaultWarmupRuns: 1,
                claimSafeMinimumRuns: 10,
                claimSafeMinimumWarmupRuns: 1,
                claimSafeMinimumInterEditorCooldownMs: 1500,
                requiredRoster: [],
                claimSafeRoster: ["Kern", "Zed"],
                claimPolicyDescription: "publishable head-to-head claims require the exact Kern,Zed roster, >=10 measured runs, >=1 warmup run, and >=1500ms inter-editor cooldown",
                requiredMetrics: [
                    "full_fidelity_end_to_end_latency_ms",
                ],
                optionalMetrics: [
                    "open_latency_ms",
                    "window_visible_ms",
                    "cold_start_latency_ms",
                    "warm_start_latency_ms",
                    "first_paint_ms",
                    "render_stable_ms",
                    "wow_open_ready_latency_ms",
                    "wow_viewport_semantic_ready_latency_ms",
                    "wow_viewport_fidelity_ready_latency_ms",
                    "wow_full_document_fidelity_ready_latency_ms",
                    "automation_overhead_ms",
                    "unattributed_open_budget_ms",
                    "time_to_stable_layout_ms",
                    "post_ready_export_quiescence_ms",
                    "time_to_interactive_ms",
                    "time_to_full_fidelity_ms",
                    "promotion_apply_slice_p99_ms",
                    "scroll_jump_count",
                    "scroll_jump_max_px",
                    "anchor_rebase_count",
                    "anchor_rebase_fail_count",
                ],
                stageTimeouts: [
                    "startup": 8,
                    "open": 20,
                    "wow_metrics": 20,
                ],
                suiteKind: "cross_editor_full_fidelity"
            )
        case .wowInternal:
            return SuiteDefinition(
                id: .wowInternal,
                displayName: "Wow Internal",
                intendedUsage: "kern-only minimum-latency internal microbenchmark",
                defaultRuns: 10,
                defaultWarmupRuns: 0,
                claimSafeMinimumRuns: nil,
                claimSafeMinimumWarmupRuns: nil,
                claimSafeMinimumInterEditorCooldownMs: nil,
                requiredRoster: ["Kern"],
                claimSafeRoster: ["Kern"],
                claimPolicyDescription: "internal diagnostic lane; not a cross-editor public claim surface",
                requiredMetrics: [
                    "wow_parse_latency_ms",
                    "wow_layout_latency_ms",
                    "wow_paint_ready_latency_ms",
                    "wow_open_ready_latency_ms",
                    "wow_viewport_semantic_ready_latency_ms",
                    "wow_viewport_fidelity_ready_latency_ms",
                    "wow_full_document_fidelity_ready_latency_ms",
                ],
                optionalMetrics: [
                    "wow_edit_apply_latency_ms",
                    "wow_save_serialize_latency_ms",
                    "open_latency_ms",
                    "save_ui_ack_latency_ms",
                    "quit_latency_ms",
                    "window_visible_ms",
                    "automation_overhead_ms",
                    "unattributed_open_budget_ms",
                    "time_to_stable_layout_ms",
                    "post_ready_export_quiescence_ms",
                    "time_to_interactive_ms",
                    "time_to_full_fidelity_ms",
                    "promotion_apply_slice_p99_ms",
                    "scroll_jump_count",
                    "scroll_jump_max_px",
                    "anchor_rebase_count",
                    "anchor_rebase_fail_count",
                ],
                stageTimeouts: [
                    "startup": 8,
                    "open": 8,
                    "typing": 2,
                    "save_ui": 1.2,
                    "save_durable": 2,
                    "quit": 3.5,
                    "wow_metrics": 18,
                ],
                suiteKind: "internal_microbenchmark"
            )
        }
    }
}
