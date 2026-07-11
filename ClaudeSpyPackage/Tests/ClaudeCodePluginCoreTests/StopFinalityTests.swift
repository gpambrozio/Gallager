import Dependencies
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Issue #644: a `Stop` hook that fires while background tasks / session crons
/// are in flight may be a pause (Claude parked the turn waiting for the work to
/// wake it back up), not a finish. The core asks the `StopFinalityClassifier`
/// (Apple Intelligence live, overridden here) whether the last assistant
/// message reads as final, and drops the frame when it doesn't.
@Suite("Stop finality (issue #644)")
struct StopFinalityTests {
    // MARK: - Helpers

    /// Records classifier invocations so tests can assert it is only consulted
    /// when background work is actually pending.
    private actor ClassifierRecorder {
        private(set) var calls: [(message: String, pendingWork: [String])] = []

        func record(message: String, pendingWork: [String]) {
            calls.append((message, pendingWork))
        }
    }

    private func makeCore() async throws -> ClaudeCodePluginCore {
        let core = ClaudeCodePluginCore()
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-stop-finality-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: Data(),
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: MockPluginHost())
        return core
    }

    private func frame(_ json: String) -> IngressFrame {
        IngressFrame(
            pluginID: ClaudeCodePluginCore.pluginID,
            context: ["TMUX_PANE": "%1", "CLAUDE_PROJECT_DIR": "/Users/test/MyProject"],
            payload: Data(json.utf8)
        )
    }

    /// A realistic Stop payload (hooks docs, "Stop input") with one running
    /// background task and one lingering completed one.
    private let pausedStop = """
    {
        "hook_event_name": "Stop",
        "session_id": "sess-1",
        "last_assistant_message": "The build is running; I'll report back when it finishes.",
        "background_tasks": [
            {
                "id": "task-001",
                "name": "Build service",
                "status": "running",
                "created_at": "2024-01-15T10:30:00Z",
                "last_updated_at": "2024-01-15T10:45:00Z"
            },
            {
                "id": "task-002",
                "name": "Old lint run",
                "status": "completed",
                "created_at": "2024-01-15T10:00:00Z",
                "last_updated_at": "2024-01-15T10:10:00Z"
            }
        ],
        "session_crons": []
    }
    """

    // MARK: - Decoding

    @Test("Stop decodes background_tasks and session_crons")
    func decodesBackgroundArrays() throws {
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "done",
            "background_tasks": [
                {
                    "id": "task-001",
                    "name": "Build service",
                    "status": "running",
                    "created_at": "2024-01-15T10:30:00Z",
                    "last_updated_at": "2024-01-15T10:45:00Z"
                }
            ],
            "session_crons": [
                {
                    "id": "cron-001",
                    "name": "Daily backup",
                    "schedule": "0 2 * * *",
                    "last_run_at": null,
                    "next_run_at": "2024-01-16T02:00:00Z",
                    "status": "active",
                    "created_at": "2024-01-10T14:20:00Z",
                    "last_updated_at": "2024-01-15T02:00:00Z"
                }
            ]
        }
        """
        let action = try HookAction.from(jsonData: Data(json.utf8))
        guard case let .stop(body) = action else {
            Issue.record("expected .stop, got \(action)")
            return
        }
        #expect(body.backgroundTasks == [
            StopBackgroundTask(id: "task-001", name: "Build service", status: "running"),
        ])
        #expect(body.sessionCrons == [
            StopSessionCron(id: "cron-001", name: "Daily backup", status: "active"),
        ])
    }

    @Test("a Stop without the arrays still decodes (older CLIs)")
    func decodesWithoutArrays() throws {
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "done"
        }
        """
        let action = try HookAction.from(jsonData: Data(json.utf8))
        guard case let .stop(body) = action else {
            Issue.record("expected .stop, got \(action)")
            return
        }
        #expect(body.backgroundTasks == nil)
        #expect(body.sessionCrons == nil)
        #expect(body.pendingBackgroundWork.isEmpty)
    }

    // MARK: - pendingBackgroundWork filtering

    @Test("terminal tasks and paused/disabled crons are not pending")
    func pendingFiltering() {
        let body = StopBody(
            sessionId: "s",
            hookEventName: "Stop",
            backgroundTasks: [
                StopBackgroundTask(id: "t1", name: "Build", status: "running"),
                StopBackgroundTask(id: "t2", name: "Paused agent", status: "paused"),
                StopBackgroundTask(id: "t3", name: "Done", status: "completed"),
                StopBackgroundTask(id: "t4", name: "Broken", status: "failed"),
                StopBackgroundTask(id: "t5", name: "Killed", status: "cancelled"),
                // Unknown status counts as pending — the classifier fails open.
                StopBackgroundTask(id: "t6", name: nil, status: "someday-new-status"),
            ],
            sessionCrons: [
                StopSessionCron(id: "c1", name: "Daily backup", status: "active"),
                StopSessionCron(id: "c2", name: "Paused cron", status: "paused"),
                StopSessionCron(id: "c3", name: "Disabled cron", status: "disabled"),
            ]
        )
        // Nameless elements fall back to their id.
        #expect(body.pendingBackgroundWork == ["Build", "Paused agent", "t6", "Daily backup"])
    }

    // MARK: - handleIngress gating

    @Test("a paused Stop (pending work, message not final) is dropped")
    func pausedStopDropped() async {
        let recorder = ClassifierRecorder()
        let event = await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                }
            )
        } operation: {
            let core = try? await makeCore()
            return await core?.handleIngress(frame(pausedStop)) ?? nil
        }

        // Dropped: no state change, no notification — the session stays Working.
        #expect(event == nil)

        // The classifier saw the message and only the still-pending work (the
        // lingering completed task is filtered out).
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.message == "The build is running; I'll report back when it finishes.")
        #expect(calls.first?.pendingWork == ["Build service"])
    }

    @Test("a final-sounding Stop is applied even with pending work")
    func finalStopKept() async {
        let event = await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { _, _ in .final }
            )
        } operation: {
            let core = try? await makeCore()
            return await core?.handleIngress(frame(pausedStop)) ?? nil
        }

        #expect(event?.state == .doneWorking(
            summary: "The build is running; I'll report back when it finishes."
        ))
    }

    @Test("the classifier is not consulted when no work is actually pending")
    func classifierSkippedWithoutPendingWork() async {
        // Only terminal tasks / non-firing crons linger in the arrays — the stop
        // is unambiguous, so no Apple Intelligence round-trip.
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "All done.",
            "background_tasks": [
                {"id": "t1", "name": "Old build", "status": "completed"},
                {"id": "t2", "name": "Aborted", "status": "cancelled"}
            ],
            "session_crons": [
                {"id": "c1", "name": "Disabled cron", "status": "disabled"}
            ]
        }
        """
        let recorder = ClassifierRecorder()
        let event = await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                }
            )
        } operation: {
            let core = try? await makeCore()
            return await core?.handleIngress(frame(json)) ?? nil
        }

        #expect(event?.state == .doneWorking(summary: "All done."))
        #expect(await recorder.calls.isEmpty)
    }

    @Test("an empty-message Stop with pending work is kept without classifying")
    func emptyMessageStopKept() async {
        // An empty message gives the model nothing to judge — fail open (keep the
        // stop) rather than guessing, mirroring the empty-message boundary pinned
        // in ClaudeCodeTranslatorTests.
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "",
            "background_tasks": [
                {"id": "t1", "name": "Build service", "status": "running"}
            ]
        }
        """
        let recorder = ClassifierRecorder()
        let event = await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                }
            )
        } operation: {
            let core = try? await makeCore()
            return await core?.handleIngress(frame(json)) ?? nil
        }

        #expect(event?.state == .doneWorking(summary: ""))
        #expect(await recorder.calls.isEmpty)
    }
}
