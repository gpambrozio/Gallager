import Foundation
import Testing
@testable import ClaudeSpyE2ELib

/// Fake recorder that tracks calls and creates the output file.
actor FakeRecorder: ScreenRecording {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private var failOnStart = false

    func setFailOnStart() { failOnStart = true }

    func start(outputURL: URL) async throws {
        if failOnStart { throw ScreenRecorder.RecordingError.noDisplay }
        startedURLs.append(outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("fake".utf8))
    }

    func stop() async { stopCount += 1 }
}

/// Collects post-processor invocations across concurrency boundaries.
actor PostProcessCalls {
    private(set) var calls: [(raw: URL, timeline: URL)] = []
    func record(raw: URL, timeline: URL) { calls.append((raw, timeline)) }
}

@Suite("RecordingCoordinator")
struct RecordingCoordinatorTests {
    private func result(name: String, failedStep: Int? = nil) -> TestOrchestrator.ScenarioResult {
        TestOrchestrator.ScenarioResult(
            scenarioName: name,
            success: failedStep == nil,
            failedStep: failedStep,
            error: nil,
            duration: 1,
            steps: []
        )
    }

    @Test("Scenario dir name matches the orchestrator's sanitizer")
    func scenarioDirName() {
        #expect(TestOrchestrator.scenarioDirName(for: "Two Mac Pairing") == "two-mac-pairing")
        #expect(TestOrchestrator.scenarioDirName(for: "OTEL: Usage (Overview)!") == "otel-usage-overview")
    }

    @Test("Writes timeline.json with per-step offsets, stops recorder, invokes post-processor")
    func fullLifecycle() async throws {
        let dir = NSTemporaryDirectory() + "rc-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let recorder = FakeRecorder()
        let calls = PostProcessCalls()

        let coordinator = RecordingCoordinator(
            screenshotsDir: dir,
            recorder: recorder,
            postProcessor: { raw, timeline in await calls.record(raw: raw, timeline: timeline) }
        )

        await coordinator.scenarioStarted("Video Demo", totalSteps: 2)
        await coordinator.stepStarted(1, totalSteps: 2, description: "first step")
        await coordinator.stepCompleted(1, screenshot: nil)
        await coordinator.stepStarted(2, totalSteps: 2, description: "second step")
        await coordinator.stepFailed(2, error: "boom", screenshot: nil, failureScreenshots: [])
        await coordinator.scenarioCompleted(result(name: "Video Demo", failedStep: 2))
        await coordinator.printSummary([])

        let timelineURL = URL(fileURLWithPath: "\(dir)/video-demo/timeline.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let timeline = try decoder.decode(
            ScenarioTimeline.self,
            from: Data(contentsOf: timelineURL)
        )

        #expect(timeline.scenarioName == "Video Demo")
        #expect(timeline.testStartOffset != nil)
        #expect(timeline.duration != nil)
        #expect(timeline.failedStep == 2)
        #expect(timeline.steps.count == 2)
        #expect(timeline.steps[0].status == "passed")
        #expect(timeline.steps[1].status == "failed")
        #expect(timeline.steps.allSatisfy { $0.end != nil && $0.end! >= $0.start })

        #expect(await recorder.stopCount == 1)
        let recorded = await calls.calls
        #expect(recorded.count == 1)
        #expect(recorded[0].raw.lastPathComponent == "recording-raw.mov")
        #expect(recorded[0].timeline.lastPathComponent == "timeline.json")
    }

    @Test("Recorder start failure degrades gracefully — no timeline, no post-processing, no crash")
    func startFailure() async throws {
        let dir = NSTemporaryDirectory() + "rc-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let recorder = FakeRecorder()
        await recorder.setFailOnStart()
        let calls = PostProcessCalls()

        let coordinator = RecordingCoordinator(
            screenshotsDir: dir,
            recorder: recorder,
            postProcessor: { raw, timeline in await calls.record(raw: raw, timeline: timeline) }
        )

        await coordinator.scenarioStarted("Video Demo", totalSteps: 1)
        await coordinator.stepStarted(1, totalSteps: 1, description: "only step")
        await coordinator.stepCompleted(1, screenshot: nil)
        await coordinator.scenarioCompleted(result(name: "Video Demo"))
        await coordinator.printSummary([])

        let timelinePath = "\(dir)/video-demo/timeline.json"
        #expect(!FileManager.default.fileExists(atPath: timelinePath))
        #expect(await recorder.stopCount == 0)
        #expect(await calls.calls.isEmpty)
    }
}
