import Foundation

struct MemorySnapshot {
    let physFootprintMB: Double?
    let rssMB: Double?
    let failureReason: String?
}

private struct TimedProcessResult {
    let status: Int32
    let timedOut: Bool
    let output: String?
}

/// Measure memory for a process (and all descendants for multi-process apps).
func measureMemory(pid: pid_t, editor: EditorDefinition) -> MemorySnapshot {
    let rss = rssMB(pid: pid, editor: editor)
    let rawPhys = physFootprintMB(pid: pid, editor: editor)
    let phys = rawPhys ?? rss
    let failureReason: String?
    if rawPhys == nil && rss == nil {
        failureReason = "memory_probe_failed"
    } else if rawPhys == nil {
        // Fallback path: estimate phys from RSS so required metric remains populated.
        failureReason = nil
    } else if rss == nil {
        failureReason = "memory_rss_unavailable"
    } else {
        failureReason = nil
    }
    return MemorySnapshot(physFootprintMB: phys, rssMB: rss, failureReason: failureReason)
}

/// Collect all PIDs belonging to this editor (main + descendants + helper processes).
private func allEditorPIDs(pid: pid_t, editor: EditorDefinition) -> [pid_t] {
    var pids = [pid]
    // Recursive BFS for all descendant processes.
    pids += findAllDescendantPIDs(of: pid)
    // Additionally match helper processes by prefix (catches re-parented Electron children).
    if let prefix = editor.helperProcessPrefix {
        let helpers = findHelperPIDs(prefix: prefix)
        for h in helpers where !pids.contains(h) {
            pids.append(h)
        }
    }
    return pids
}

/// Get RSS in MB by summing all matching PIDs (main + all descendants).
private func rssMB(pid: pid_t, editor: EditorDefinition) -> Double? {
    let pids = (editor.isElectron ? allEditorPIDs(pid: pid, editor: editor) : [pid])
        .filter { $0 > 0 }
    guard !pids.isEmpty else { return nil }

    // Single ps call to avoid N subprocesses for Electron helpers.
    let pidArg = pids.map(String.init).joined(separator: ",")
    let result = runProcessWithTimeout(
        executable: "/bin/ps",
        args: ["-o", "rss=", "-p", pidArg],
        timeout: 1.0
    )
    guard !result.timedOut, result.status == 0, let output = result.output else { return nil }

    let totalKB = output
        .split(whereSeparator: \.isNewline)
        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .reduce(0, +)

    if totalKB <= 0 {
        return nil
    }
    return Double(totalKB) / 1024.0
}

/// Try to get phys_footprint via the `footprint` command.
/// Uses `-p <pid> --targetChildren` for multi-process editors.
/// Returns nil if `footprint` fails (e.g., needs sudo for other users' processes).
private func physFootprintMB(pid: pid_t, editor: EditorDefinition) -> Double? {
    // If `footprint` consistently fails on this machine/session, skip re-running it
    // and fall back to RSS immediately to keep runtime deterministic.
    if footprintProbeUnavailable {
        return nil
    }

    var args = ["-p", "\(pid)"]
    if editor.isElectron {
        args.append("--targetChildren")
    }

    let result = runProcessWithTimeout(
        executable: "/usr/bin/footprint",
        args: args,
        timeout: 1.2
    )
    guard !result.timedOut, result.status == 0, let output = result.output else {
        footprintProbeUnavailable = true
        return nil
    }

    // Parse footprint output. Look for the "phys_footprint" line or the total summary.
    // Typical output: "phys_footprint:  85123456 bytes (81.2M)"
    // Or total: "total: 85123456 bytes (81.2M)"
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Match lines like "phys_footprint: 85123456" or "total: 85123456"
        if trimmed.hasPrefix("phys_footprint") || (editor.isElectron && trimmed.hasPrefix("total")) {
            // Try to extract bytes
            let parts = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted)
            for part in parts {
                if let bytes = UInt64(part), bytes > 1_000_000 {
                    return Double(bytes) / (1024.0 * 1024.0)
                }
            }

            // Try to extract the parenthesized MB value like "(81.2M)"
            if let range = trimmed.range(of: #"\(([0-9.]+)M\)"#, options: .regularExpression) {
                let match = trimmed[range]
                let numStr = match.dropFirst().dropLast(2) // Remove "(" and "M)"
                if let mb = Double(numStr) {
                    return mb
                }
            }
        }
    }

    return nil
}

private var footprintProbeUnavailable = false

private func runProcessWithTimeout(
    executable: String,
    args: [String],
    timeout: TimeInterval
) -> TimedProcessResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args

    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice

    do {
        try proc.run()
    } catch {
        return TimedProcessResult(status: -1, timedOut: false, output: nil)
    }

    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        usleep(20_000)
    }

    var timedOut = false
    if proc.isRunning {
        timedOut = true
        proc.terminate()
        usleep(100_000)
        if proc.isRunning {
            Foundation.kill(proc.processIdentifier, SIGKILL)
            usleep(100_000)
        }
    }

    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)
    return TimedProcessResult(status: proc.terminationStatus, timedOut: timedOut, output: output)
}
