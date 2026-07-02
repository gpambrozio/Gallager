import Foundation

/// Per-scenario step timing relative to the start of the screen recording.
///
/// Written as `timeline.json` next to the raw take by `RecordingCoordinator`
/// and consumed by `e2e_video_postprocess.py` (step caption windows, the
/// timecode's recording→test-start offset, and seek chapters).
public struct ScenarioTimeline: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public let stepNumber: Int
        public let description: String
        /// Seconds from recording start to when the step began.
        public var start: Double
        /// Seconds from recording start to when the step finished.
        /// `nil` only while the step is still running.
        public var end: Double?
        /// "passed" | "failed"
        public var status: String
    }

    public let scenarioName: String
    /// Wall-clock time the recording started (ISO8601) for log correlation.
    public let recordingStartedAt: Date
    /// Seconds from recording start to the scenario's first step — the
    /// recording→test-start delta the burned-in timecode subtracts.
    public var testStartOffset: Double?
    public var steps: [Step]
    public var failedStep: Int?
    /// Total recorded duration in seconds, set when recording stops.
    public var duration: Double?
}
