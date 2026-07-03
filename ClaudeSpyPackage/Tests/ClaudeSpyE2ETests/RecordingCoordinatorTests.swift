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

    @Test("Scenario dir name matches the shared parity fixture (mirrored by e2e_report_build.py)")
    func scenarioDirName() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                let name: String
                let expected: String
            }

            let cases: [Case]
        }
        // scripts/tests/scenario_dir_name_fixture.json, reached from the repo
        // root — the Python mirror (e2e_report_build.scenario_dir_name) asserts
        // the same cases in scripts/tests/test_e2e_report_build.py.
        let fixtureURL = URL(fileURLWithPath: #filePath) // .../ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/RecordingCoordinatorTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/tests/scenario_dir_name_fixture.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        #expect(!fixture.cases.isEmpty)
        for testCase in fixture.cases {
            #expect(TestOrchestrator.scenarioDirName(for: testCase.name) == testCase.expected, "\(testCase.name)")
        }
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

    @Test("Scenario start clears stale outputs from a previous run into the same dir")
    func staleOutputsCleared() async throws {
        let dir = NSTemporaryDirectory() + "rc-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let scenarioDir = "\(dir)/video-demo"
        try FileManager.default.createDirectory(atPath: scenarioDir, withIntermediateDirectories: true)
        let staleFiles = ["recording-raw.mov", "video.mp4", "video.json", "timeline.json"]
        for file in staleFiles {
            FileManager.default.createFile(atPath: "\(scenarioDir)/\(file)", contents: Data("stale".utf8))
        }

        let coordinator = RecordingCoordinator(
            screenshotsDir: dir,
            recorder: FakeRecorder(),
            postProcessor: nil
        )
        await coordinator.scenarioStarted("Video Demo", totalSteps: 1)

        // The fake recorder recreates recording-raw.mov; the processed outputs
        // from the earlier run must be gone so a failed re-run can't surface
        // a stale video.mp4 in the report.
        for file in ["video.mp4", "video.json", "timeline.json"] {
            #expect(!FileManager.default.fileExists(atPath: "\(scenarioDir)/\(file)"), "\(file)")
        }
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
