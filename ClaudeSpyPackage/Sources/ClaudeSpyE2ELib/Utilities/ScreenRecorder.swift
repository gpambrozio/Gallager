import CoreGraphics
import CoreMedia
import Foundation
import Logging
@preconcurrency import ScreenCaptureKit

/// Abstraction over screen recording so `RecordingCoordinator` can be unit
/// tested with a fake recorder.
public protocol ScreenRecording: Sendable {
    /// Start recording the main display to the given file URL.
    func start(outputURL: URL) async throws
    /// Stop capturing and finalize the recording file. Safe to call when not
    /// recording (no-op).
    func stop() async
}

/// Records the main display to an H.264 `.mov` via ScreenCaptureKit
/// (`SCStream` + `SCRecordingOutput`, macOS 15+).
///
/// Frame rate is capped at 15 fps and the stream is configured at 1x point
/// resolution (not retina pixels) — the take feeds an ffmpeg post-processing
/// pass, so capture favors small files over fidelity. This mirrors the sips
/// DPI normalization the screenshot path applies.
public actor ScreenRecorder: ScreenRecording {
    public enum RecordingError: Error {
        case noDisplay
        case alreadyRecording
    }

    private let logger = Logger(label: "e2e.screen-recorder")
    private var stream: SCStream?
    /// Retained because SCStream/SCRecordingOutput hold their delegate weakly.
    private var delegateBox: RecorderDelegate?

    public init() { }

    public func start(outputURL: URL) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else {
            throw RecordingError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // SCDisplay width/height are points — capturing at that size records
        // 1x instead of retina pixels.
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = true
        config.queueDepth = 6

        let delegate = RecorderDelegate(logger: logger)
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)

        let recordConfig = SCRecordingOutputConfiguration()
        recordConfig.outputURL = outputURL
        recordConfig.outputFileType = .mov
        recordConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recordConfig, delegate: delegate)

        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        delegateBox = delegate
        logger.info("Recording started → \(outputURL.path)")
    }

    public func stop() async {
        guard let stream else { return }
        do {
            // Stopping capture finalizes the SCRecordingOutput file.
            try await stream.stopCapture()
        } catch {
            logger.warning("stopCapture failed (file may still be finalized): \(error)")
        }

        // SCRecordingOutput finalizes the file (writes the moov atom)
        // asynchronously — stopCapture() returning is not a guarantee the
        // file is readable yet. Poll the delegate's finish signal so
        // callers can safely read the file once stop() returns, bounded so
        // a missed/late delegate callback can't hang the caller forever.
        if let delegateBox {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !delegateBox.isFinished, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !delegateBox.isFinished {
                logger.warning("Timed out waiting for SCRecordingOutput to finalize")
            }
        }

        self.stream = nil
        delegateBox = nil
        logger.info("Recording stopped")
    }
}

final private class RecorderDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate,
    @unchecked Sendable { // Safe: Logger is Sendable, mutable state guarded by lock
    private let logger: Logger
    private let lock = NSLock()
    private var _finished = false

    var isFinished: Bool {
        lock.withLock { _finished }
    }

    init(logger: Logger) {
        self.logger = logger
    }

    private func markFinished() {
        lock.withLock { _finished = true }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("SCStream stopped with error: \(error)")
        markFinished()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        logger.error("SCRecordingOutput failed: \(error)")
        markFinished()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        logger.info("SCRecordingOutput finished finalizing")
        markFinished()
    }
}
