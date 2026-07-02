import Foundation
import Logging

/// A `TestProgressReporter` that records each scenario as a full-display
/// video and writes a `timeline.json` of per-step offsets, then hands the
/// finished take to an ffmpeg post-processing pass (issue #621).
///
/// Capture starts on `scenarioStarted` and is stopped/finalized on
/// `scenarioCompleted` — which the orchestrator calls on success AND on
/// fatal failure — so the take is finalized reliably either way.
///
/// Recording failures are deliberately non-fatal: a scenario without video
/// still runs and reports normally (best-effort, never perturbs tests).
public actor RecordingCoordinator: TestProgressReporter {
    /// Post-processes a finished take. Injected so tests can stub it; the
    /// production value runs `e2e_video_postprocess.py` — see
    /// `makeFFmpegPostProcessor`. Arguments: (rawTakeURL, timelineURL).
    public typealias PostProcessor = @Sendable (URL, URL) async -> Void

    private let logger = Logger(label: "e2e.recording")
    private let screenshotsDir: String
    private let recorder: any ScreenRecording
    private let postProcessor: PostProcessor?
    private let clock = ContinuousClock()

    private var recordingStart: ContinuousClock.Instant?
    private var timeline: ScenarioTimeline?
    private var currentScenarioDir: String?
    /// Encodes run concurrently with subsequent scenarios (off the hot path,
    /// at low priority); `printSummary` awaits them all before the process exits.
    private var postProcessingTasks: [Task<Void, Never>] = []

    public init(
        screenshotsDir: String,
        recorder: any ScreenRecording,
        postProcessor: PostProcessor?
    ) {
        self.screenshotsDir = screenshotsDir
        self.recorder = recorder
        self.postProcessor = postProcessor
    }

    // MARK: - TestProgressReporter

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        let dir = "\(screenshotsDir)/\(TestOrchestrator.scenarioDirName(for: name))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rawURL = URL(fileURLWithPath: "\(dir)/recording-raw.mov")
        try? FileManager.default.removeItem(at: rawURL)

        do {
            try await recorder.start(outputURL: rawURL)
        } catch {
            logger.error("Could not start recording for '\(name)': \(error) — scenario runs unrecorded")
            return
        }
        recordingStart = clock.now
        currentScenarioDir = dir
        timeline = ScenarioTimeline(
            scenarioName: name,
            recordingStartedAt: Date(),
            testStartOffset: nil,
            steps: [],
            failedStep: nil,
            duration: nil
        )
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async {
        guard timeline != nil, let start = recordingStart else { return }
        let offset = elapsed(since: start)
        if timeline?.testStartOffset == nil {
            timeline?.testStartOffset = offset
        }
        timeline?.steps.append(ScenarioTimeline.Step(
            stepNumber: stepNumber,
            description: description,
            start: offset,
            end: nil,
            status: "passed"
        ))
    }

    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async {
        closeCurrentStep(status: "passed")
    }

    public func stepFailed(
        _ stepNumber: Int,
        error: String,
        screenshot: TestOrchestrator.ScreenshotResult?,
        failureScreenshots: [TestOrchestrator.FailureScreenshot]
    ) async {
        closeCurrentStep(status: "failed")
    }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        guard var timeline, let start = recordingStart, let dir = currentScenarioDir else { return }
        self.timeline = nil
        recordingStart = nil
        currentScenarioDir = nil

        await recorder.stop()
        timeline.duration = elapsed(since: start)
        timeline.failedStep = result.failedStep

        let rawURL = URL(fileURLWithPath: "\(dir)/recording-raw.mov")
        let timelineURL = URL(fileURLWithPath: "\(dir)/timeline.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(timeline).write(to: timelineURL)
        } catch {
            logger.error("Could not write timeline.json for '\(result.scenarioName)': \(error)")
            return
        }

        if let postProcessor {
            let task = Task.detached(priority: .utility) {
                await postProcessor(rawURL, timelineURL)
            }
            postProcessingTasks.append(task)
        }
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        guard !postProcessingTasks.isEmpty else { return }
        logger.info("Waiting for \(postProcessingTasks.count) video encode(s) to finish…")
        // The recorder sits first in the reporter fan-out, so this wait blocks
        // the pass/fail summary — say so on the terminal (the logger writes to
        // the log file) or a long tail encode reads as a hang.
        fputs("Waiting for \(postProcessingTasks.count) video encode(s) to finish…\n", stderr)
        for task in postProcessingTasks {
            await task.value
        }
        postProcessingTasks.removeAll()
    }

    // MARK: - Production post-processor

    /// Builds the production post-processor: runs the bundled
    /// `e2e_video_postprocess.py` under `nice` so encodes never compete with
    /// the scenario that's already running. On any failure the raw take and
    /// timeline are left in place and the error is logged.
    public static func makeFFmpegPostProcessor(mode: String, keepRaw: Bool) -> PostProcessor {
        { rawURL, timelineURL in
            let logger = Logger(label: "e2e.video-postprocess")
            guard
                let script = Bundle.module.url(
                    forResource: "e2e_video_postprocess",
                    withExtension: "py",
                    subdirectory: "Scripts"
                )
            else {
                logger.error("e2e_video_postprocess.py not found in bundle — raw take kept")
                return
            }
            var args = [
                "-n", "10", "python3", script.path,
                "--raw", rawURL.path,
                "--timeline", timelineURL.path,
                "--mode", mode,
            ]
            if keepRaw {
                args.append("--keep-raw")
            }
            do {
                let runner = ProcessRunner()
                // ffmpeg encodes scale with take length (~10–30% of scenario duration);
                // ProcessRunner's default 30s timeout is far too short. 30 minutes
                // bounds even the longest scenarios.
                let result = try await runner.runOrThrow("/usr/bin/nice", arguments: args, timeout: 1_800)
                let summary = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.info("Post-processed \(rawURL.deletingLastPathComponent().lastPathComponent): \(summary)")
            } catch {
                logger.error("Video post-processing failed for \(rawURL.path): \(error) — raw take kept")
            }
        }
    }

    // MARK: - Helpers

    private func closeCurrentStep(status: String) {
        guard timeline != nil, let start = recordingStart, timeline?.steps.isEmpty == false else { return }
        let offset = elapsed(since: start)
        let lastIndex = timeline!.steps.count - 1
        timeline?.steps[lastIndex].end = offset
        timeline?.steps[lastIndex].status = status
    }

    private func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = clock.now - start
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1E18
    }
}
