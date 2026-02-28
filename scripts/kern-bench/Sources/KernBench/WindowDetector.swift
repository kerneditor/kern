import CoreGraphics
import Darwin
import Foundation

struct DetectedWindow {
    let windowID: CGWindowID
    let timestampNs: UInt64
    let bounds: CGRect
}

struct WindowCandidate {
    let windowID: CGWindowID
    let bounds: CGRect
    let name: String
}

/// Polls CGWindowListCopyWindowInfo until the target PID has an on-screen window.
/// Uses async Task.sleep for safe cooperative scheduling.
func waitForWindow(pid: pid_t, timeout: TimeInterval = 30, expectedFileName: String? = nil) async -> DetectedWindow? {
    let startNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let timeoutNs = UInt64(timeout * 1_000_000_000)
    let expectedName = expectedFileName?.lowercased()

    while true {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if now - startNs > timeoutNs { return nil }
        if !isPidAlive(pid) { return nil }

        if let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            var candidates: [WindowCandidate] = []
            for info in windowList {
                guard let candidate = windowCandidate(from: info, ownerPID: pid) else { continue }
                candidates.append(candidate)
            }

            if let selected = selectWindowCandidate(candidates, expectedName: expectedName) {
                let detectNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                return DetectedWindow(
                    windowID: selected.windowID,
                    timestampNs: detectNs,
                    bounds: selected.bounds
                )
            }
        }

        try? await Task.sleep(for: .milliseconds(5))
    }
}

func windowCandidate(from info: [String: Any], ownerPID: pid_t) -> WindowCandidate? {
    guard let infoOwnerPID = info[kCGWindowOwnerPID as String] as? Int32,
          infoOwnerPID == ownerPID,
          let windowID = info[kCGWindowNumber as String] as? CGWindowID,
          let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
          let x = boundsDict["X"] as? CGFloat,
          let y = boundsDict["Y"] as? CGFloat,
          let width = boundsDict["Width"] as? CGFloat,
          let height = boundsDict["Height"] as? CGFloat,
          width > 100, height > 80
    else { return nil }

    let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
    if layer != 0 {
        return nil
    }

    let name = (info[kCGWindowName as String] as? String) ?? ""
    return WindowCandidate(
        windowID: windowID,
        bounds: CGRect(x: x, y: y, width: width, height: height),
        name: name
    )
}

func selectWindowCandidate(_ candidates: [WindowCandidate], expectedName: String?) -> WindowCandidate? {
    guard !candidates.isEmpty else { return nil }

    if let expectedName, !expectedName.isEmpty {
        if let byName = candidates.first(where: { $0.name.lowercased().contains(expectedName) }) {
            return byName
        }
        let expectedStem = (expectedName as NSString).deletingPathExtension
        if !expectedStem.isEmpty,
           let byStem = candidates.first(where: { $0.name.lowercased().contains(expectedStem) }) {
            return byStem
        }
    }

    return candidates.max { lhs, rhs in
        lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
    }
}

private func isPidAlive(_ pid: pid_t) -> Bool {
    if pid <= 0 { return false }
    return Darwin.kill(pid, 0) == 0 || errno == EPERM
}
