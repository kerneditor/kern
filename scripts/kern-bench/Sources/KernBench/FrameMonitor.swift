import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct FrameTimestamps {
    let firstPaintNs: UInt64?
    let renderStableNs: UInt64?
}

struct ScrollFrameCaptureResult {
    let frameIntervalsMs: [Double]
    let captureDurationMs: Double
}

/// Monitor frames from a specific window using ScreenCaptureKit.
/// Detects first paint (SCFrameStatus.complete with actual content) and render stable (sustained .idle).
@available(macOS 14.0, *)
final class FrameMonitor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.kern.bench.capture", qos: .userInteractive)
    private let lock = NSLock()

    private var _firstPaintNs: UInt64?
    private var _lastCompleteNs: UInt64?
    private var _idleStartNs: UInt64?
    private var _renderStableNs: UInt64?
    private var _continuation: CheckedContinuation<FrameTimestamps, Never>?

    private let idleThresholdNs: UInt64 = 500_000_000 // 500ms of idle = stable
    private let timeoutNs: UInt64

    /// After first paint, wait at most this long for render stable before giving up.
    /// Prevents Electron apps (which never go idle) from blocking for the full timeout.
    private let renderStableGraceNs: UInt64 = 5_000_000_000 // 5 seconds

    /// Minimum pixel variance to consider a frame as having actual content (not blank chrome).
    /// This ensures Electron apps' blank shell frames don't count as first paint.
    private let contentVarianceThreshold: Double = 50.0

    init(timeout: TimeInterval = 30) {
        self.timeoutNs = UInt64(timeout * 1_000_000_000)
        super.init()
    }

    /// Start monitoring a window. Returns frame timestamps when render is stable or timeout.
    func monitor(windowID: CGWindowID) async -> FrameTimestamps {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                printErr("ScreenCaptureKit: Window \(windowID) not found")
                return FrameTimestamps(firstPaintNs: nil, renderStableNs: nil)
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Use pixel dimensions (not points) for Retina displays.
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = Int(window.frame.width * scaleFactor)
            config.height = Int(window.frame.height * scaleFactor)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

            let timeoutSec = Double(self.timeoutNs) / 1_000_000_000

            // Set up continuation BEFORE starting capture to avoid race condition:
            // callbacks (including didStopWithError) can fire immediately after startCapture().
            return await withCheckedContinuation { continuation in
                captureQueue.sync {
                    self.stream = stream
                    self._continuation = continuation
                }

                // Start capture. If it fails, finish() will be called by the error handler.
                Task {
                    do {
                        try await stream.startCapture()
                    } catch {
                        printErr("ScreenCaptureKit start error: \(error.localizedDescription)")
                        self.finish()
                    }
                }

                // Timeout watchdog.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
                    self?.finish()
                }
            }
        } catch {
            printErr("ScreenCaptureKit error: \(error.localizedDescription)")
            return FrameTimestamps(firstPaintNs: nil, renderStableNs: nil)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        // Determine state changes under lock, then act outside the lock.
        var shouldFinish = false

        lock.lock()

        switch status {
        case .complete:
            // For first paint, verify the frame has actual content (not a blank Electron shell).
            if _firstPaintNs == nil {
                if hasContent(buffer) {
                    _firstPaintNs = now
                }
            }
            _lastCompleteNs = now
            _idleStartNs = nil

        case .idle:
            if _idleStartNs == nil {
                _idleStartNs = now
            }
            // Render stable = idle for threshold after at least one content paint.
            if let idleStart = _idleStartNs, _firstPaintNs != nil,
               (now - idleStart) >= idleThresholdNs {
                _renderStableNs = now
                shouldFinish = true
            }

        default:
            break
        }

        // Grace period: if first paint was detected but render stable hasn't been
        // reached within the grace window, give up on render stable. This prevents
        // Electron apps (which never go idle due to animations) from blocking.
        if !shouldFinish, let fp = _firstPaintNs, (now - fp) >= renderStableGraceNs {
            shouldFinish = true
        }

        lock.unlock()

        if shouldFinish {
            finish()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        printErr("SCStream stopped with error: \(error.localizedDescription)")
        finish()
    }

    /// Check if a frame buffer has actual rendered content (not a uniform/blank frame).
    /// Samples the center 100x100 region and checks luminance variance across all channels.
    private func hasContent(_ buffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return true }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return true }

        // Sample center 100x100 region (or smaller if frame is small).
        let sampleSize = min(100, min(width, height))
        let startX = (width - sampleSize) / 2
        let startY = (height - sampleSize) / 2

        var sum: Double = 0
        var sumSq: Double = 0
        var count: Double = 0

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in startY..<(startY + sampleSize) {
            for x in startX..<(startX + sampleSize) {
                // BGRA format: compute perceived luminance from all channels.
                let base = y * bytesPerRow + x * 4
                let b = Double(ptr[base])
                let g = Double(ptr[base + 1])
                let r = Double(ptr[base + 2])
                // BT.709 luminance weights.
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sum += lum
                sumSq += lum * lum
                count += 1
            }
        }

        guard count > 0 else { return true }
        let mean = sum / count
        let variance = (sumSq / count) - (mean * mean)
        return variance > contentVarianceThreshold
    }

    private func finish() {
        lock.lock()
        guard let continuation = _continuation else {
            lock.unlock()
            return
        }
        _continuation = nil
        let result = FrameTimestamps(firstPaintNs: _firstPaintNs, renderStableNs: _renderStableNs)
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }

        continuation.resume(returning: result)
    }
}

/// Check if Screen Recording permission is available.
@available(macOS 14.0, *)
func checkScreenCapturePermission() async -> Bool {
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return true
    } catch {
        return false
    }
}

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Captures frame cadence for a fixed interval and returns inter-frame deltas.
/// Used for real-use scroll smoothness preferred metrics.
@available(macOS 14.0, *)
final class ScrollFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.kern.bench.scroll.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ScrollFrameCaptureResult?, Never>?
    private var frameTimesNs: [UInt64] = []
    private var startedAtNs: UInt64?
    private var endedAtNs: UInt64?
    private let timeoutNs: UInt64

    init(timeout: TimeInterval) {
        self.timeoutNs = UInt64(timeout * 1_000_000_000)
        super.init()
    }

    func capture(windowID: CGWindowID, duration: TimeInterval) async -> ScrollFrameCaptureResult? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

            return await withCheckedContinuation { continuation in
                captureQueue.sync {
                    self.stream = stream
                    self.continuation = continuation
                    self.frameTimesNs = []
                    self.startedAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    self.endedAtNs = nil
                }

                Task {
                    do {
                        try await stream.startCapture()
                    } catch {
                        self.finish()
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + duration) { [weak self] in
                    self?.finish()
                }
                let timeoutSec = Double(self.timeoutNs) / 1_000_000_000
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
                    self?.finish()
                }
            }
        } catch {
            return nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let ptsNs = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000_000.0))
        guard ptsNs > 0 else { return }

        lock.lock()
        if let last = frameTimesNs.last {
            if ptsNs > last {
                frameTimesNs.append(ptsNs)
            }
        } else {
            frameTimesNs.append(ptsNs)
        }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finish()
    }

    private func finish() {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        self.endedAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let frameTimes = self.frameTimesNs
        let captureStarted = self.startedAtNs
        let captureEnded = self.endedAtNs
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        if let stream {
            Task { try? await stream.stopCapture() }
        }

        guard frameTimes.count >= 2 else {
            continuation.resume(returning: nil)
            return
        }

        var intervals: [Double] = []
        intervals.reserveCapacity(max(0, frameTimes.count - 1))
        for idx in 1..<frameTimes.count {
            let deltaNs = frameTimes[idx] - frameTimes[idx - 1]
            if deltaNs > 0 {
                let deltaMs = Double(deltaNs) / 1_000_000.0
                if deltaMs < 500 {
                    intervals.append(deltaMs)
                }
            }
        }

        guard !intervals.isEmpty else {
            continuation.resume(returning: nil)
            return
        }

        let captureDurationMs: Double
        if let captureStarted, let captureEnded, captureEnded > captureStarted {
            captureDurationMs = Double(captureEnded - captureStarted) / 1_000_000.0
        } else {
            captureDurationMs = Double(frameTimes.last! - frameTimes.first!) / 1_000_000.0
        }

        continuation.resume(returning: ScrollFrameCaptureResult(
            frameIntervalsMs: intervals,
            captureDurationMs: captureDurationMs
        ))
    }
}
