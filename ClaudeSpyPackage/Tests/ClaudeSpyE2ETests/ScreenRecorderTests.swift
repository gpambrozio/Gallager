import AVFoundation
import Foundation
import Testing
@testable import ClaudeSpyE2ELib

@Suite("ScreenRecorder integration")
struct ScreenRecorderTests {
    @Test("stop() without a prior start is a safe no-op")
    func stopWithoutStart() async {
        let recorder = ScreenRecorder()
        // Must return promptly without throwing or hanging.
        await recorder.stop()
    }

    /// Requires a GUI session + Screen Recording permission for the test
    /// runner, so it only runs when explicitly requested:
    ///   E2E_RECORDING_TESTS=1 swift test --package-path ClaudeSpyPackage \
    ///     --filter ScreenRecorderTests
    @Test(
        "Records the main display to a playable movie",
        .enabled(if: ProcessInfo.processInfo.environment["E2E_RECORDING_TESTS"] == "1")
    )
    func recordsMainDisplay() async throws {
        let url = URL(
            fileURLWithPath: NSTemporaryDirectory() + "recorder-test-\(UUID().uuidString).mov"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ScreenRecorder()
        try await recorder.start(outputURL: url)
        try await Task.sleep(for: .seconds(2))
        await recorder.stop()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.size] as? Int ?? 0) > 10_000)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 1)
    }
}
