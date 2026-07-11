import ClaudeSpyNetworking
import Dependencies
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Covers the issue-#644 false-stop path: a `Stop` hook that arrives with in-flight
/// `background_tasks` / `session_crons` is run through the injected
/// `StopCompletionClassifier`; a `.stillWaiting` verdict suppresses the premature
/// `doneWorking` and keeps the session working. The classifier is stubbed so the
/// tests never touch real Apple Intelligence inference.
struct FalseStopDetectionTests {
    /// Spy classifier: records how many times it was consulted and returns a fixed
    /// verdict, so a test can assert both the outcome AND that the gate ran/skipped.
    private actor ClassifierSpy {
        let verdict: StopCompletion
        private(set) var callCount = 0
        init(verdict: StopCompletion) {
            self.verdict = verdict
        }

        func record() -> StopCompletion {
            callCount += 1
            return verdict
        }
    }

    /// Builds an initialized core. Constructed by the caller *inside* the
    /// `withDependencies` operation so the actor captures the overridden classifier.
    private func makeCore(settings: Data = Data()) async throws -> ClaudeCodePluginCore {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-falsestop-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settings,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: host)
        return core
    }

    private func frame(_ json: String, pane: String = "%1") -> IngressFrame {
        IngressFrame(
            pluginID: ClaudeCodePluginCore.pluginID,
            context: ["TMUX_PANE": pane, "CLAUDE_PROJECT_DIR": "/Users/test/MyProject"],
            payload: Data(json.utf8)
        )
    }

    /// A Stop payload carrying one in-flight background task.
    private let stopWithBackgroundWork = """
    {
        "hook_event_name": "Stop",
        "session_id": "sess-1",
        "last_assistant_message": "Kicking off the build in the background.",
        "background_tasks": [{ "id": "bg-1", "status": "running" }],
        "session_crons": []
    }
    """

    @Test("Stop + background work + stillWaiting verdict → keeps working, no notification")
    func stillWaitingSuppressesDone() async throws {
        let spy = ClassifierSpy(verdict: .stillWaiting)
        try await withDependencies {
            $0[StopCompletionClassifier.self] = StopCompletionClassifier(classify: { _ in await spy.record() })
        } operation: {
            let core = try await makeCore()
            let event = try #require(await core.handleIngress(frame(stopWithBackgroundWork)))
            // Suppressed: a bare working event, no "done" notification / app action.
            #expect(event.state == .working)
            #expect(event.notification == nil)
            #expect(event.appActions.isEmpty)
            #expect(event.tmuxPane == "%1")
            #expect(event.projectPath == "/Users/test/MyProject")
        }
        #expect(await spy.callCount == 1)
    }

    @Test("Stop + background work + finished verdict → normal doneWorking")
    func finishedHonorsStop() async throws {
        let spy = ClassifierSpy(verdict: .finished)
        try await withDependencies {
            $0[StopCompletionClassifier.self] = StopCompletionClassifier(classify: { _ in await spy.record() })
        } operation: {
            let core = try await makeCore()
            let event = try #require(await core.handleIngress(frame(stopWithBackgroundWork)))
            #expect(event.state == .doneWorking(summary: "Kicking off the build in the background."))
        }
        #expect(await spy.callCount == 1)
    }

    @Test("Stop with empty background arrays never consults the classifier")
    func emptyBackgroundArraysSkipClassifier() async throws {
        // Even a classifier that WOULD say stillWaiting must not be consulted when
        // there's no in-flight work — the gate is `hasInFlightBackgroundWork`.
        let spy = ClassifierSpy(verdict: .stillWaiting)
        try await withDependencies {
            $0[StopCompletionClassifier.self] = StopCompletionClassifier(classify: { _ in await spy.record() })
        } operation: {
            let core = try await makeCore()
            let json = """
            {
                "hook_event_name": "Stop",
                "session_id": "sess-1",
                "last_assistant_message": "All done.",
                "background_tasks": [],
                "session_crons": []
            }
            """
            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state == .doneWorking(summary: "All done."))
        }
        #expect(await spy.callCount == 0)
    }

    @Test("Stop with no background arrays at all (older Claude) → doneWorking, classifier untouched")
    func absentBackgroundArraysSkipClassifier() async throws {
        let spy = ClassifierSpy(verdict: .stillWaiting)
        try await withDependencies {
            $0[StopCompletionClassifier.self] = StopCompletionClassifier(classify: { _ in await spy.record() })
        } operation: {
            let core = try await makeCore()
            let json = """
            {
                "hook_event_name": "Stop",
                "session_id": "sess-1",
                "last_assistant_message": "All done."
            }
            """
            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state == .doneWorking(summary: "All done."))
        }
        #expect(await spy.callCount == 0)
    }

    @Test("setting off → Stop honored even with background work, classifier untouched")
    func settingOffHonorsStop() async throws {
        let spy = ClassifierSpy(verdict: .stillWaiting)
        let settings = Data(#"{"detect_false_stops": false}"#.utf8)
        try await withDependencies {
            $0[StopCompletionClassifier.self] = StopCompletionClassifier(classify: { _ in await spy.record() })
        } operation: {
            let core = try await makeCore(settings: settings)
            let event = try #require(await core.handleIngress(frame(stopWithBackgroundWork)))
            #expect(event.state == .doneWorking(summary: "Kicking off the build in the background."))
        }
        #expect(await spy.callCount == 0)
    }

    // MARK: - StopBody decoding

    @Test("StopBody.hasInFlightBackgroundWork reflects the arrays")
    func hasInFlightBackgroundWorkDecoding() throws {
        func stopBody(_ json: String) throws -> StopBody {
            guard case let .stop(body) = try HookAction.from(jsonData: Data(json.utf8)) else {
                Issue.record("expected a .stop action")
                throw CancellationError()
            }
            return body
        }

        // Non-empty background_tasks → true.
        #expect(try stopBody("""
        { "hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "m",
          "background_tasks": [{ "id": "x" }], "session_crons": [] }
        """).hasInFlightBackgroundWork == true)

        // Non-empty session_crons only → true.
        #expect(try stopBody("""
        { "hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "m",
          "background_tasks": [], "session_crons": [{ "id": "c" }] }
        """).hasInFlightBackgroundWork == true)

        // Both empty → false.
        #expect(try stopBody("""
        { "hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "m",
          "background_tasks": [], "session_crons": [] }
        """).hasInFlightBackgroundWork == false)

        // Absent (older Claude) → false, and still decodes.
        #expect(try stopBody("""
        { "hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "m" }
        """).hasInFlightBackgroundWork == false)
    }
}
