import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct StageResult {
    let valueMs: Double?
    let failureReason: String?
    let timedOut: Bool
}

enum StageError: Error {
    case timeout(String)
    case failure(String)

    var reason: String {
        switch self {
        case let .timeout(r), let .failure(r):
            return r
        }
    }

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}

struct ScrollMetrics {
    let settleLatencyMs: Double?
    let effectiveFPS: Double?
    let p95FrameTimeMs: Double?
    let p99FrameTimeMs: Double?
    let hitchMsPerS: Double?
    let jank33Count: Double?
    let jank50Count: Double?
    let failureReason: String?
    let timedOut: Bool
    let mode: String
}

struct ActionRunner {
    let editor: EditorDefinition
    let pid: pid_t
    let windowID: CGWindowID?
    let accessibilityAvailable: Bool
    let verbose: Bool

    func runOpenReadiness(
        timeout: TimeInterval,
        expectedFileName: String? = nil,
        expectedFilePath: String? = nil
    ) async -> StageResult {
        await measureStage(timeout: timeout) {
            let started = nowNs()
            guard accessibilityAvailable else {
                throw StageError.failure("accessibility_permission_missing")
            }
            guard let expectedFileName, !expectedFileName.isEmpty else {
                throw StageError.failure("expected_document_missing")
            }
            let deadline = nowNs() + UInt64(timeout * 1_000_000_000)
            var stablePreparedPolls = 0
            let prepareIntervalNs: UInt64 = 30_000_000
            var lastPrepareAttemptNs: UInt64 = 0
            var sawDocumentMatch = false
            var firstDocumentMatchNs: UInt64?
            let softReadyAfterDocumentMatchNs: UInt64 = 120_000_000
            var prepareAttempts = 0

            while nowNs() <= deadline {
                guard isProcessAlive(pid) else {
                    throw StageError.failure("process_exited")
                }
                guard isWindowPresent(pid: pid, windowID: windowID) else {
                    throw StageError.failure("window_missing")
                }

                let expectedPath = expectedFilePath ?? ""
                let documentMatched = documentWindowMatchesExpectedFile(
                    processID: pid,
                    expectedFileName: expectedFileName,
                    expectedFilePath: expectedPath
                ) || cgWindowMatchesExpectedFile(
                    pid: pid,
                    windowID: windowID,
                    expectedFileName: expectedFileName
                )
                if documentMatched {
                    sawDocumentMatch = true
                    if firstDocumentMatchNs == nil {
                        firstDocumentMatchNs = nowNs()
                    }
                }

                // Best-effort focus nudge (non-fatal; some editors won't activate via NSRunningApplication
                // from CLI-launched automation, but can still accept posted keyboard events by PID).
                let now = nowNs()
                if now >= lastPrepareAttemptNs, (now - lastPrepareAttemptNs) >= prepareIntervalNs {
                    prepareAttempts += 1
                    let prepared = quickPrepareEditorForInput(processID: pid, windowID: windowID)
                    if prepared {
                        stablePreparedPolls += 1
                        if stablePreparedPolls >= 2, documentMatched {
                            return elapsedMs(since: started)
                        }
                    } else {
                        stablePreparedPolls = 0
                    }
                    lastPrepareAttemptNs = now
                }

                // Some editors can expose a fully loaded/readable document but intermittently reject
                // synthetic edit probes due focus quirks. Avoid false timeouts once the target document
                // has been stably detected for long enough.
                if let firstDocumentMatchNs, now - firstDocumentMatchNs >= softReadyAfterDocumentMatchNs {
                    return elapsedMs(since: started)
                }

                try await Task.sleep(for: .milliseconds(2))
            }

            if verbose {
                print(
                    "  [\(editor.displayName)] open-ready timeout debug: " +
                        "sawDocumentMatch=\(sawDocumentMatch) " +
                        "prepareAttempts=\(prepareAttempts) " +
                        "stablePreparedPolls=\(stablePreparedPolls)"
                )
            }
            if !sawDocumentMatch && editor.isElectron {
                throw StageError.timeout("document_not_loaded_timeout")
            }
            throw StageError.timeout("open_ready_timeout")
        }
    }

    func runTyping(timeout: TimeInterval, payload: String) async -> StageResult {
        await measureStage(timeout: timeout) {
            guard isProcessAlive(pid), hasUsableWindow(pid: pid, windowID: windowID) else {
                throw StageError.failure("focus_or_text_target_unavailable")
            }
            _ = quickPrepareEditorForInput(processID: pid, windowID: windowID)
            if let windowID {
                _ = clickWindowCenter(windowID: windowID)
            }

            let started = nowNs()

            if !sendTypingPayload(processID: pid, text: payload),
               !pasteText(processID: pid, text: payload) {
                _ = quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true)
                if let windowID {
                    _ = clickWindowCenter(windowID: windowID)
                }
                guard sendTypingPayload(processID: pid, text: payload) ||
                    pasteText(processID: pid, text: payload) else {
                    throw StageError.failure("typing_dispatch_failed")
                }
            }

            return elapsedMs(since: started)
        }
    }

    func runFind(timeout: TimeInterval, queries: [String]) async -> StageResult {
        await measureStage(timeout: timeout) {
            guard accessibilityAvailable else {
                throw StageError.failure("accessibility_permission_missing")
            }
            guard quickPrepareEditorForInput(processID: pid, windowID: windowID) else {
                throw StageError.failure("focus_or_text_target_unavailable")
            }
            let started = nowNs()

            guard !queries.isEmpty else {
                throw StageError.failure("find_query_bank_empty")
            }

            for query in queries {
                let dispatched =
                    sendCommand(processID: pid, key: "f") &&
                    sendCommand(processID: pid, key: "a") &&
                    sendText(processID: pid, text: query) &&
                    sendKeyCode(processID: pid, keyCode: 36) &&
                    sendCommand(processID: pid, key: "g")
                if !dispatched {
                    let recovered =
                        quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true) &&
                        sendCommand(processID: pid, key: "f") &&
                        sendCommand(processID: pid, key: "a") &&
                        sendText(processID: pid, text: query) &&
                        sendKeyCode(processID: pid, keyCode: 36) &&
                        sendCommand(processID: pid, key: "g")
                    if !recovered {
                        throw StageError.failure("find_sequence_failed")
                    }
                }
                try await Task.sleep(for: .milliseconds(3))
            }

            // Close find UI where applicable so subsequent scroll/edit actions target content.
            _ = sendKeyCode(processID: pid, keyCode: 53) // Escape

            let total = elapsedMs(since: started)
            return total / Double(max(queries.count, 1))
        }
    }

    /// Lightweight interaction pulse to ensure keyboard focus is bound to editor content.
    /// Used in the minimal benchmark flow before save, where we otherwise have very few interactions.
    func runFocusPulse(timeout: TimeInterval) async -> StageResult {
        await measureStage(timeout: timeout) {
            guard accessibilityAvailable else {
                throw StageError.failure("accessibility_permission_missing")
            }
            guard quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true) else {
                throw StageError.failure("focus_or_text_target_unavailable")
            }
            let started = nowNs()
            guard sendPageDown(processID: pid), sendPageUp(processID: pid) else {
                throw StageError.failure("focus_pulse_dispatch_failed")
            }
            try await Task.sleep(for: .milliseconds(60))
            return elapsedMs(since: started)
        }
    }

    func runSave(timeoutUI: TimeInterval, timeoutDurable: TimeInterval, filePath: String) async -> (StageResult, StageResult) {
        let beforeMtime = fileMtime(filePath)
        let beforeSize = fileSizeBytes(filePath)

        let uiAck = await measureStage(timeout: timeoutUI) {
            guard isProcessAlive(pid), hasUsableWindow(pid: pid, windowID: windowID) else {
                throw StageError.failure("focus_or_text_target_unavailable")
            }
            _ = quickPrepareEditorForInput(processID: pid, windowID: windowID)
            let started = nowNs()
            if !sendCommand(processID: pid, key: "s") {
                _ = quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true)
                guard sendCommand(processID: pid, key: "s") else {
                    throw StageError.failure("save_command_failed")
                }
            }

            let deadline = nowNs() + UInt64(max(timeoutUI, 0.05) * 1_000_000_000)
            while nowNs() <= deadline {
                let currentMtime = fileMtime(filePath)
                let currentSize = fileSizeBytes(filePath)
                if currentMtime != beforeMtime || currentSize != beforeSize {
                    return elapsedMs(since: started)
                }
                try await Task.sleep(for: .milliseconds(2))
            }

            throw StageError.timeout("save_ui_ack_timeout_no_file_change")
        }

        if timeoutDurable <= 0 {
            return (uiAck, StageResult(valueMs: nil, failureReason: nil, timedOut: false))
        }

        if uiAck.failureReason != nil {
            return (uiAck, StageResult(valueMs: nil, failureReason: nil, timedOut: false))
        }

        let durable = await measureStage(timeout: timeoutDurable) {
            let started = nowNs()
            let deadline = nowNs() + UInt64(timeoutDurable * 1_000_000_000)

            var sawMutation = false
            var stableStreak = 0
            var lastMtime = fileMtime(filePath)
            var lastSize = fileSizeBytes(filePath)

            while nowNs() <= deadline {
                let currentMtime = fileMtime(filePath)
                let currentSize = fileSizeBytes(filePath)
                if currentMtime != beforeMtime || currentSize != beforeSize {
                    sawMutation = true
                }

                if sawMutation, currentMtime == lastMtime, currentSize == lastSize {
                    stableStreak += 1
                    if stableStreak >= 2 {
                        // One-time content check at stability boundary to avoid expensive
                        // full-file hashing on every poll iteration.
                        let hashA = sha256Hash(ofFile: filePath)
                        try await Task.sleep(for: .milliseconds(2))
                        let hashB = sha256Hash(ofFile: filePath)
                        if hashA == hashB {
                            return elapsedMs(since: started)
                        }
                        stableStreak = 0
                    }
                    } else {
                    stableStreak = 0
                }

                lastMtime = currentMtime
                lastSize = currentSize
                try await Task.sleep(for: .milliseconds(12))
            }

            throw StageError.timeout(sawMutation ? "save_durable_timeout" : "save_durable_no_mutation")
        }

        return (uiAck, durable)
    }

    func runSaveUI(timeout: TimeInterval) async -> StageResult {
        await measureStage(timeout: timeout) {
            guard isProcessAlive(pid), hasUsableWindow(pid: pid, windowID: windowID) else {
                throw StageError.failure("focus_or_text_target_unavailable")
            }
            _ = quickPrepareEditorForInput(processID: pid, windowID: windowID)

            let started = nowNs()
            if !sendCommand(processID: pid, key: "s") {
                _ = quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true)
                guard sendCommand(processID: pid, key: "s") else {
                    throw StageError.failure("save_command_failed")
                }
            }
            return elapsedMs(since: started)
        }
    }

    func runQuit(timeout: TimeInterval) async -> StageResult {
        await measureStage(timeout: timeout) {
            guard isProcessAlive(pid) else {
                throw StageError.failure("process_not_running")
            }
            _ = quickPrepareEditorForInput(processID: pid, windowID: windowID)

            let started = nowNs()
            if !sendCommand(processID: pid, key: "q") {
                _ = quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true)
                guard sendCommand(processID: pid, key: "q") else {
                    throw StageError.failure("quit_command_failed")
                }
            }

            let timeoutNs = UInt64(max(timeout, 0.05) * 1_000_000_000)
            let resendQuitNs = min(UInt64(400_000_000), max(UInt64(120_000_000), timeoutNs / 2))
            let deadline = nowNs() + timeoutNs
            var didResend = false
            while nowNs() <= deadline {
                if !isProcessAlive(pid) {
                    return elapsedMs(since: started)
                }
                if !didResend, nowNs() - started >= resendQuitNs {
                    _ = quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true)
                    _ = sendCommand(processID: pid, key: "q")
                    didResend = true
                }
                try await Task.sleep(for: .milliseconds(8))
            }

            throw StageError.timeout("quit_timeout")
        }
    }

    func runScroll(timeout: TimeInterval, preferredFrameMetricsAvailable: Bool) async -> ScrollMetrics {
        let captureDuration = max(0.8, min(timeout - 0.1, 1.5))
        let captureTask: Task<ScrollFrameCaptureResult?, Never>? = {
            guard preferredFrameMetricsAvailable, let windowID, #available(macOS 14.0, *) else {
                return nil
            }
            return Task {
                let capture = ScrollFrameCapture(timeout: timeout)
                return await capture.capture(windowID: windowID, duration: captureDuration)
            }
        }()

        if captureTask != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }

        let settle = await measureStage(timeout: timeout) {
            let started = nowNs()
            guard accessibilityAvailable else {
                throw StageError.failure("accessibility_permission_missing")
            }
            guard quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true) else {
                throw StageError.failure("focus_or_text_target_unavailable")
            }

            for _ in 0..<2 {
                guard sendPageDown(processID: pid) else {
                    guard quickPrepareEditorForInput(processID: pid, windowID: windowID, forceFocus: true),
                          sendPageDown(processID: pid) else {
                        throw StageError.failure("scroll_dispatch_failed")
                    }
                    continue
                }
                try await Task.sleep(for: .milliseconds(45))
            }
            guard sendPageUp(processID: pid) else {
                throw StageError.failure("scroll_dispatch_failed")
            }
            try await Task.sleep(for: .milliseconds(80))
            return elapsedMs(since: started)
        }

        let captured = await captureTask?.value
        if let captured,
           !captured.frameIntervalsMs.isEmpty,
           captured.captureDurationMs > 0 {
            let sorted = captured.frameIntervalsMs.sorted()
            let durationSec = max(0.001, captured.captureDurationMs / 1000.0)
            let frameCount = Double(captured.frameIntervalsMs.count + 1)
            let effectiveFPS = frameCount / durationSec
            let p95 = percentile(sorted, p: 0.95)
            let p99 = percentile(sorted, p: 0.99)
            let hitchBudget = captured.frameIntervalsMs.reduce(0.0) { partial, frame in
                partial + max(0.0, frame - 16.67)
            }
            let hitchPerS = hitchBudget / durationSec
            let jank33 = Double(captured.frameIntervalsMs.filter { $0 > 33.0 }.count)
            let jank50 = Double(captured.frameIntervalsMs.filter { $0 > 50.0 }.count)

            return ScrollMetrics(
                settleLatencyMs: settle.valueMs,
                effectiveFPS: round(effectiveFPS * 100) / 100,
                p95FrameTimeMs: round(p95 * 100) / 100,
                p99FrameTimeMs: round(p99 * 100) / 100,
                hitchMsPerS: round(hitchPerS * 100) / 100,
                jank33Count: jank33,
                jank50Count: jank50,
                failureReason: settle.failureReason,
                timedOut: settle.timedOut,
                mode: "preferred_frame_capture"
            )
        }

        let fallbackReason: String? = {
            if let failure = settle.failureReason {
                return failure
            }
            if preferredFrameMetricsAvailable {
                return "scroll_frame_capture_unavailable"
            }
            return nil
        }()

        return ScrollMetrics(
            settleLatencyMs: settle.valueMs,
            effectiveFPS: nil,
            p95FrameTimeMs: nil,
            p99FrameTimeMs: nil,
            hitchMsPerS: nil,
            jank33Count: nil,
            jank50Count: nil,
            failureReason: fallbackReason,
            timedOut: settle.timedOut,
            mode: "fallback_scroll_to_settle"
        )
    }

    // MARK: - Stage helpers

    private func measureStage(timeout: TimeInterval, operation: @escaping () async throws -> Double?) async -> StageResult {
        do {
            let value = try await withTimeout(seconds: timeout, operation)
            return StageResult(valueMs: value, failureReason: nil, timedOut: false)
        } catch let error as StageError {
            return StageResult(valueMs: nil, failureReason: error.reason, timedOut: error.isTimeout)
        } catch {
            return StageResult(valueMs: nil, failureReason: "stage_error", timedOut: false)
        }
    }

}

func hasAccessibilityPermission() -> Bool {
    AXIsProcessTrusted()
}

func withTimeout<T>(
    seconds: TimeInterval,
    _ operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw StageError.timeout("stage_timeout")
        }

        guard let first = try await group.next() else {
            throw StageError.failure("no_stage_result")
        }
        group.cancelAll()
        return first
    }
}

private var focusCachePID: pid_t = 0
private var focusCacheNs: UInt64 = 0
private let focusCacheTTLNs: UInt64 = 8_000_000_000
private let keyDispatchGapUs: useconds_t = 1_500
private let sharedEventSource: CGEventSource? = {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    return source
}()

private func focusEditorWindow(processID: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: processID) else {
        return false
    }
    return app.activate(options: [.activateAllWindows])
}

private func frontmostProcessID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

private func quickPrepareEditorForInput(processID: pid_t, windowID: CGWindowID?) -> Bool {
    quickPrepareEditorForInput(processID: processID, windowID: windowID, forceFocus: false)
}

private func quickPrepareEditorForInput(processID: pid_t, windowID: CGWindowID?, forceFocus: Bool) -> Bool {
    guard isProcessAlive(processID), hasUsableWindow(pid: processID, windowID: windowID) else {
        return false
    }

    let now = nowNs()
    let frontmostPID = frontmostProcessID()
    if !forceFocus {
        if frontmostPID == processID {
            focusCachePID = processID
            focusCacheNs = now
            return true
        }
        if focusCachePID == processID, now >= focusCacheNs, (now - focusCacheNs) <= focusCacheTTLNs {
            return true
        }
    }

    guard focusEditorWindow(processID: processID) else {
        return false
    }

    // Some apps report activation success before becoming frontmost.
    // Bound this wait tightly to avoid throughput impact.
    let focusDeadline = nowNs() + 120_000_000
    while nowNs() <= focusDeadline {
        if frontmostProcessID() == processID {
            focusCachePID = processID
            focusCacheNs = nowNs()
            return true
        }
        usleep(2_000)
    }

    return false
}

private func sendCommand(processID: pid_t, key: String, modifiers: [String] = ["command down"]) -> Bool {
    guard let keyCode = keyCodeForCharacter(key) else { return false }
    return sendKeyCode(processID: processID, keyCode: keyCode, modifiers: modifiers)
}

private func sendKeyCode(processID: pid_t, keyCode: Int, modifiers: [String] = []) -> Bool {
    guard let source = sharedEventSource ?? CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
    else {
        return false
    }

    let flags = eventFlags(from: modifiers)
    down.flags = flags
    up.flags = flags
    if frontmostProcessID() == processID {
        down.post(tap: .cghidEventTap)
        usleep(keyDispatchGapUs)
        up.post(tap: .cghidEventTap)
    } else {
        down.postToPid(processID)
        usleep(keyDispatchGapUs)
        up.postToPid(processID)
    }
    return true
}

private func sendText(processID: pid_t, text: String) -> Bool {
    guard !text.isEmpty else { return true }
    guard let source = sharedEventSource ?? CGEventSource(stateID: .hidSystemState) else {
        return false
    }

    let utf16 = Array(text.utf16)
    let chunkSize = 96
    var start = 0
    while start < utf16.count {
        let end = min(start + chunkSize, utf16.count)
        let chunk = Array(utf16[start..<end])
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return false
        }

        down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        if frontmostProcessID() == processID {
            down.post(tap: .cghidEventTap)
            usleep(keyDispatchGapUs)
            up.post(tap: .cghidEventTap)
        } else {
            down.postToPid(processID)
            usleep(keyDispatchGapUs)
            up.postToPid(processID)
        }
        start = end
    }

    return true
}

private func sendTypingPayload(processID: pid_t, text: String) -> Bool {
    guard !text.isEmpty else { return true }

    // Prefer keycode-based dispatch for determinism across editors.
    for char in text.lowercased() {
        if char == "-" {
            guard sendKeyCode(processID: processID, keyCode: 27) else { return false }
            continue
        }
        let key = String(char)
        if let keyCode = keyCodeForCharacter(key) {
            guard sendKeyCode(processID: processID, keyCode: keyCode) else { return false }
            continue
        }
        // Fallback for characters outside the keycode map.
        guard sendText(processID: processID, text: String(char)) else { return false }
    }
    return true
}

private func pasteText(processID: pid_t, text: String) -> Bool {
    guard !text.isEmpty else { return true }

    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
        if let previous {
            pasteboard.clearContents()
            _ = pasteboard.setString(previous, forType: .string)
        }
        return false
    }

    let didPaste = sendCommand(processID: processID, key: "v")

    pasteboard.clearContents()
    if let previous {
        _ = pasteboard.setString(previous, forType: .string)
    }
    return didPaste
}

private func sendPageDown(processID: pid_t) -> Bool {
    sendKeyCode(processID: processID, keyCode: 121)
}

private func sendPageUp(processID: pid_t) -> Bool {
    sendKeyCode(processID: processID, keyCode: 116)
}

private func eventFlags(from modifiers: [String]) -> CGEventFlags {
    var flags: CGEventFlags = []
    for raw in modifiers {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command down", "command":
            flags.insert(.maskCommand)
        case "shift down", "shift":
            flags.insert(.maskShift)
        case "option down", "option", "alt down", "alt":
            flags.insert(.maskAlternate)
        case "control down", "control", "ctrl down", "ctrl":
            flags.insert(.maskControl)
        default:
            continue
        }
    }
    return flags
}

private func keyCodeForCharacter(_ key: String) -> Int? {
    switch key.lowercased() {
    case "a": return 0
    case "s": return 1
    case "d": return 2
    case "f": return 3
    case "g": return 5
    case "h": return 4
    case "j": return 38
    case "k": return 40
    case "l": return 37
    case "m": return 46
    case "n": return 45
    case "o": return 31
    case "p": return 35
    case "q": return 12
    case "r": return 15
    case "t": return 17
    case "u": return 32
    case "v": return 9
    case "w": return 13
    case "x": return 7
    case "y": return 16
    case "z": return 6
    default: return nil
    }
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
    if pid <= 0 { return false }
    return Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func isWindowPresent(pid: pid_t, windowID: CGWindowID?) -> Bool {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return false
    }

    for info in windowList {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
              ownerPID == pid,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat,
              width > 50,
              height > 50 else {
            continue
        }

        if let windowID {
            if id == windowID { return true }
        } else {
            return true
        }
    }

    return false
}

private func hasUsableWindow(pid: pid_t, windowID: CGWindowID?) -> Bool {
    if isWindowPresent(pid: pid, windowID: windowID) {
        return true
    }
    return isWindowPresent(pid: pid, windowID: nil)
}

private func cgWindowMatchesExpectedFile(
    pid: pid_t,
    windowID: CGWindowID?,
    expectedFileName: String
) -> Bool {
    let expectedLower = expectedFileName.lowercased()
    guard !expectedLower.isEmpty else { return false }
    let expectedStem = (expectedFileName as NSString).deletingPathExtension.lowercased()

    let listOptions: CGWindowListOption = windowID == nil
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionIncludingWindow, .excludeDesktopElements]
    let targetWindowID = windowID ?? kCGNullWindowID

    guard let infos = CGWindowListCopyWindowInfo(listOptions, targetWindowID) as? [[String: Any]] else {
        return false
    }

    for info in infos {
        if let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != pid {
            continue
        }
        if let windowID, let wid = info[kCGWindowNumber as String] as? CGWindowID, wid != windowID {
            continue
        }
        let title = ((info[kCGWindowName as String] as? String) ?? "").lowercased()
        if title.contains(expectedLower) {
            return true
        }
        if !expectedStem.isEmpty, title.contains(expectedStem) {
            return true
        }
    }
    return false
}

private func windowBounds(for windowID: CGWindowID) -> CGRect? {
    guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
          let first = info.first,
          let bounds = first[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? CGFloat,
          let y = bounds["Y"] as? CGFloat,
          let width = bounds["Width"] as? CGFloat,
          let height = bounds["Height"] as? CGFloat
    else {
        return nil
    }
    return CGRect(x: x, y: y, width: width, height: height)
}

private func clickWindowCenter(windowID: CGWindowID) -> Bool {
    guard let bounds = windowBounds(for: windowID), bounds.width > 10, bounds.height > 10 else {
        return false
    }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    guard let source = sharedEventSource ?? CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
    else {
        return false
    }
    down.post(tap: .cghidEventTap)
    usleep(1_500)
    up.post(tap: .cghidEventTap)
    usleep(8_000)
    return true
}

private func deterministicEditProbe(processID: pid_t, windowID: CGWindowID?) -> Bool {
    guard quickPrepareEditorForInput(processID: processID, windowID: windowID, forceFocus: true) else {
        return false
    }
    if let windowID {
        _ = clickWindowCenter(windowID: windowID)
    }

    // Minimal mutation + revert probe. This avoids false-ready signals where the
    // window exists but the text surface is not yet truly editable.
    let token = "kb"
    guard sendTypingPayload(processID: processID, text: token) || sendText(processID: processID, text: token) else {
        return false
    }
    usleep(4_000)
    guard sendCommand(processID: processID, key: "z") else {
        return false
    }
    usleep(3_000)
    return true
}

private func documentWindowMatchesExpectedFile(
    processID: pid_t,
    expectedFileName: String,
    expectedFilePath: String
) -> Bool {
    let normalizedExpectedName = expectedFileName.lowercased()
    guard !normalizedExpectedName.isEmpty else { return false }
    let normalizedExpectedPath = URL(fileURLWithPath: expectedFilePath)
        .standardizedFileURL
        .path
        .lowercased()
    let expectedStem = (expectedFileName as NSString).deletingPathExtension.lowercased()

    let appElement = AXUIElementCreateApplication(processID)

    var windowsObj: CFTypeRef?
    let windowsStatus = AXUIElementCopyAttributeValue(
        appElement,
        kAXWindowsAttribute as CFString,
        &windowsObj
    )
    guard windowsStatus == .success else {
        return false
    }

    guard let windows = windowsObj as? [AXUIElement], !windows.isEmpty else {
        return false
    }

    for window in windows {
        // Strong signal: AXDocument path/URL matches expected file.
        var documentObj: CFTypeRef?
        let documentStatus = AXUIElementCopyAttributeValue(
            window,
            kAXDocumentAttribute as CFString,
            &documentObj
        )
        if documentStatus == .success, let document = documentObj as? String {
            let docLower = document.lowercased()
            if docLower.contains(normalizedExpectedName) {
                return true
            }

            if let docURL = URL(string: document), docURL.isFileURL {
                let docPath = docURL.standardizedFileURL.path.lowercased()
                if !normalizedExpectedPath.isEmpty, docPath == normalizedExpectedPath {
                    return true
                }
                if docPath.hasSuffix("/\(normalizedExpectedName)") {
                    return true
                }
            } else if !normalizedExpectedPath.isEmpty, docLower.contains(normalizedExpectedPath) {
                return true
            }
        }

        // Fallback signal: window title contains filename (most editors).
        var titleObj: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleObj
        )
        if titleStatus == .success, let title = titleObj as? String {
            let normalizedTitle = title.lowercased()
            if normalizedTitle.contains(normalizedExpectedName) {
                return true
            }
            // Some editors drop extension in title.
            if !expectedStem.isEmpty, normalizedTitle.contains(expectedStem) {
                return true
            }
        }
    }

    return false
}

private func fileMtime(_ path: String) -> TimeInterval {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let mod = attrs[.modificationDate] as? Date else {
        return 0
    }
    return mod.timeIntervalSince1970
}

private func fileSizeBytes(_ path: String) -> UInt64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? NSNumber else {
        return 0
    }
    return size.uint64Value
}

private func nowNs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

private func elapsedMs(since startNs: UInt64) -> Double {
    Double(nowNs() - startNs) / 1_000_000
}
