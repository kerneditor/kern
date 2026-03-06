import Foundation

enum TypingBehaviorContextClass: String, CaseIterable, Sendable {
    case paragraph
    case bullet
    case ordered
    case task
    case orderedTask
    case nestedBullet
    case nestedOrdered
    case nestedTask
    case nestedOrderedTask
    case headingTask
    case quote
    case codeFence
}

enum TypingBehaviorAction: String, CaseIterable, Sendable {
    case markerShortcut
    case enter
    case secondEnterExit
    case shiftEnter
    case tabIndent
    case shiftTabOutdent
    case backspaceAtBoundary
    case spaceToggle
}

struct TypingBehaviorEdge: Hashable, Sendable {
    let context: TypingBehaviorContextClass
    let action: TypingBehaviorAction
}

struct TypingBehaviorCoverage {
    private(set) var required: Set<TypingBehaviorEdge>
    private(set) var observed: Set<TypingBehaviorEdge> = []
    private(set) var observedCaseIDs: [String] = []

    init(required: Set<TypingBehaviorEdge>) {
        self.required = required
    }

    mutating func record(edge: TypingBehaviorEdge, caseID: String) {
        observed.insert(edge)
        observedCaseIDs.append(caseID)
    }

    var coveredRequiredCount: Int {
        observed.intersection(required).count
    }

    var totalRequiredCount: Int {
        required.count
    }

    var requiredCoverageRatio: Double {
        guard !required.isEmpty else { return 1.0 }
        return Double(coveredRequiredCount) / Double(totalRequiredCount)
    }

    var missingRequired: [TypingBehaviorEdge] {
        required.subtracting(observed).sorted {
            if $0.context.rawValue == $1.context.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.context.rawValue < $1.context.rawValue
        }
    }

    func renderReport() -> String {
        var lines: [String] = []
        lines.append("typing_behavior_matrix_coverage")
        lines.append("required_edges=\(totalRequiredCount)")
        lines.append("covered_required_edges=\(coveredRequiredCount)")
        lines.append(String(format: "required_coverage_ratio=%.4f", requiredCoverageRatio))
        lines.append("observed_cases=\(observedCaseIDs.count)")
        if !missingRequired.isEmpty {
            let missing = missingRequired.map { "\($0.context.rawValue):\($0.action.rawValue)" }.joined(separator: ",")
            lines.append("missing_required_edges=\(missing)")
        } else {
            lines.append("missing_required_edges=none")
        }
        return lines.joined(separator: "\n")
    }
}
