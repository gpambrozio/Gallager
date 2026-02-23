#if os(macOS)
    import Foundation
    import Logging

    /// Records raw terminal stream data in `.tmrec` NDJSON format, compatible with `tmux-rec.py`.
    ///
    /// The recorder subscribes to `PaneStreamManager` as a regular subscriber to capture
    /// all raw bytes flowing through the stream. It writes timestamps relative to the
    /// recording start so the output can be replayed at the original pace.
    ///
    /// ## File Format (.tmrec)
    /// Line 1: JSON header `{"version":2,"width":W,"height":H,"timestamp":T,"target":"...","env":{"TERM":"..."}}`
    /// Lines 2+: `[elapsed_seconds, "base64_encoded_data"]`
    ///
    /// ## Memory
    /// Recording data is accumulated in memory. For very long sessions with high
    /// output volume, this may consume significant memory. Consider exporting
    /// periodically for multi-hour recordings.
    @Observable
    @MainActor
    final public class SessionRecorder {
        // MARK: - Types

        public enum State: Equatable {
            case idle
            case recording(paneId: String, target: String)
        }

        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.sessionrecorder")
        private let paneStreamManager: PaneStreamManager

        /// Current recorder state
        public private(set) var state: State = .idle

        /// Whether the recorder has data that can be exported
        public private(set) var hasRecording = false

        // MARK: - Private Recording State

        /// Subscription ID from PaneStreamManager
        private var subscriptionId: UUID?

        /// Start time for elapsed calculations
        private var startTime: ContinuousClock.Instant?

        /// Accumulated recording lines (header + events)
        private var recordingLines: [String] = []

        // MARK: - Initialization

        public init(paneStreamManager: PaneStreamManager) {
            self.paneStreamManager = paneStreamManager
        }

        // MARK: - Public API

        /// Starts recording a pane stream.
        ///
        /// If already recording, stops the current recording first (previous data is lost).
        ///
        /// - Parameters:
        ///   - paneId: The pane ID (e.g., "%1")
        ///   - target: The pane target (e.g., "mysession:0.1")
        public func startRecording(paneId: String, target: String) async throws {
            // Stop existing recording if any
            if case .recording = state {
                await stopRecording()
            }

            // Clear previous recording data
            recordingLines = []
            hasRecording = false

            // Subscribe to stream data
            let result = try await paneStreamManager.subscribe(
                paneId: paneId,
                target: target,
                onData: { [weak self] data in
                    self?.appendData(data)
                }
            )

            subscriptionId = result.subscriptionId

            // Write header (must succeed for a valid .tmrec file)
            let header: [String: Any] = [
                "version": 2,
                "width": result.width,
                "height": result.height,
                "timestamp": Int(Date().timeIntervalSince1970),
                "target": target,
                "env": [
                    "TERM": ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color",
                ],
            ]

            let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                await paneStreamManager.unsubscribe(result.subscriptionId)
                subscriptionId = nil
                throw RecordingError.headerSerializationFailed
            }
            recordingLines.append(headerString)

            // Record initial content at time 0
            startTime = ContinuousClock.now
            if !result.initialContent.isEmpty {
                let encoded = result.initialContent.base64EncodedString()
                recordingLines.append("[\(formatElapsed(0.0)),\"\(encoded)\"]")
            }

            state = .recording(paneId: paneId, target: target)
            hasRecording = true

            logger.info("Started recording", metadata: [
                "paneId": "\(paneId)",
                "target": "\(target)",
                "width": "\(result.width)",
                "height": "\(result.height)",
            ])
        }

        /// Stops recording and keeps the data for export.
        public func stopRecording() async {
            guard case let .recording(paneId, _) = state else { return }

            // Unsubscribe from stream
            if let subId = subscriptionId {
                await paneStreamManager.unsubscribe(subId)
                subscriptionId = nil
            }

            state = .idle
            startTime = nil

            logger.info("Stopped recording", metadata: [
                "paneId": "\(paneId)",
                "events": "\(recordingLines.count)",
            ])
        }

        /// Exports the recording data as a `.tmrec` file.
        ///
        /// Can be called while recording is active to export data accumulated so far.
        ///
        /// - Returns: The recording data as UTF-8 bytes, or nil if no recording exists
        public func exportData() -> Data? {
            guard hasRecording, !recordingLines.isEmpty else { return nil }
            let content = recordingLines.joined(separator: "\n") + "\n"
            return content.data(using: .utf8)
        }

        /// Clears the recorded data.
        public func clearRecording() {
            recordingLines = []
            hasRecording = false
        }

        /// Whether the recorder is currently recording
        public var isRecording: Bool {
            if case .recording = state { return true }
            return false
        }

        /// The pane ID being recorded, if any
        public var recordingPaneId: String? {
            if case let .recording(paneId, _) = state { return paneId }
            return nil
        }

        // MARK: - Private Methods

        private func appendData(_ data: Data) {
            guard let startTime else { return }
            let elapsed = (ContinuousClock.now - startTime).seconds
            let encoded = data.base64EncodedString()
            recordingLines.append("[\(formatElapsed(elapsed)),\"\(encoded)\"]")
        }

        private func formatElapsed(_ seconds: Double) -> String {
            String(format: "%.6f", seconds)
        }
    }

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case headerSerializationFailed

        var errorDescription: String? {
            switch self {
            case .headerSerializationFailed:
                "Failed to serialize recording header"
            }
        }
    }

    // MARK: - Duration Extension

    private extension Duration {
        var seconds: Double {
            let (seconds, attoseconds) = components
            return Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
        }
    }
#endif
