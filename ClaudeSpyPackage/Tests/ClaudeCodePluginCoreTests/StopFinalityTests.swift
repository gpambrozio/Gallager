import ClaudeSpyNetworking
import Dependencies
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Issue #644: a `Stop` hook that fires while background tasks / session crons
/// are in flight may be a pause (Claude parked the turn waiting for the work to
/// wake it back up), not a finish. The core asks the `StopFinalityClassifier`
/// (Apple Intelligence live, overridden here) whether the last assistant
/// message reads as final, and downgrades the stop to a still-working event
/// (spinner kept, summary notification flavored "Still Working") when it
/// doesn't.
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

    private func makeCore(settings: Data = Data()) async throws -> ClaudeCodePluginCore {
        let core = ClaudeCodePluginCore()
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-stop-finality-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settings,
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

    private func stopBody(_ json: String) throws -> StopBody {
        let action = try HookAction.from(jsonData: Data(json.utf8))
        guard case let .stop(body) = action else {
            Issue.record("expected .stop, got \(action)")
            throw CancellationError()
        }
        return body
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
                "type": "workflow",
                "name": "Build service",
                "status": "running",
                "description": "Build the service and run smoke tests"
            },
            {
                "id": "task-002",
                "type": "shell",
                "status": "completed",
                "description": "swiftlint lint",
                "command": "swiftlint lint"
            }
        ],
        "session_crons": []
    }
    """

    // MARK: - Decoding

    @Test("Stop decodes background_tasks and session_crons")
    func decodesBackgroundArrays() throws {
        let body = try stopBody("""
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "done",
            "background_tasks": [
                {
                    "id": "task-001",
                    "type": "shell",
                    "status": "running",
                    "description": "tail logs",
                    "command": "tail -f /var/log/syslog"
                }
            ],
            "session_crons": [
                {
                    "id": "cron-001",
                    "schedule": "0 2 * * *",
                    "recurring": true,
                    "prompt": "check the build"
                }
            ]
        }
        """)
        #expect(body.backgroundTasks == [
            StopBackgroundTask(id: "task-001", type: "shell", status: "running", description: "tail logs"),
        ])
        #expect(body.sessionCrons == [
            StopSessionCron(id: "cron-001", schedule: "0 2 * * *", recurring: true, prompt: "check the build"),
        ])
    }

    @Test("a Stop without the arrays still decodes (older CLIs)")
    func decodesWithoutArrays() throws {
        let body = try stopBody("""
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "done"
        }
        """)
        #expect(body.backgroundTasks == nil)
        #expect(body.sessionCrons == nil)
        #expect(body.pendingBackgroundWork.isEmpty)
    }

    // MARK: - Lenient decoding (no payload shape may drop the Stop)

    @Test("type-mismatched element fields degrade to nil, not a decode failure")
    func lenientElementFields() throws {
        let body = try stopBody("""
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "waiting",
            "background_tasks": [
                {"id": 123, "type": "shell", "status": "running", "description": false}
            ],
            "session_crons": [
                {"id": "c1", "schedule": 5, "recurring": "yes", "prompt": ["x"]}
            ]
        }
        """)
        // The malformed fields are nil; the well-formed ones survive.
        #expect(body.backgroundTasks == [StopBackgroundTask(type: "shell", status: "running")])
        #expect(body.sessionCrons == [StopSessionCron(id: "c1")])
        #expect(body.pendingBackgroundWork == ["shell", "c1"])
    }

    @Test("a non-object element decodes as all-nil and counts as pending")
    func lenientNonObjectElement() throws {
        let body = try stopBody("""
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "waiting",
            "background_tasks": ["bare-string", 42]
        }
        """)
        #expect(body.backgroundTasks == [StopBackgroundTask(), StopBackgroundTask()])
        // Unknown shape → unknown status → pending; the classifier fails open.
        #expect(body.pendingBackgroundWork == ["background task", "background task"])
    }

    @Test("non-array background fields degrade to nil, not a decode failure")
    func lenientNonArrayFields() throws {
        let body = try stopBody("""
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "done",
            "background_tasks": "unexpected",
            "session_crons": 42
        }
        """)
        #expect(body.backgroundTasks == nil)
        #expect(body.sessionCrons == nil)
        #expect(body.pendingBackgroundWork.isEmpty)
    }

    @Test("a Stop with malformed background arrays still lands (no wedged session)")
    func malformedArraysStopStillApplies() async throws {
        let recorder = ClassifierRecorder()
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame("""
            {
                "hook_event_name": "Stop",
                "session_id": "sess-1",
                "last_assistant_message": "All done.",
                "background_tasks": {"not": "an array"}
            }
            """))
        }

        #expect(event?.state == .doneWorking(summary: "All done."))
        #expect(await recorder.calls.isEmpty)
    }

    // MARK: - pendingBackgroundWork filtering

    @Test("terminal tasks are not pending; every listed cron is")
    func pendingFiltering() {
        let body = StopBody(
            sessionId: "s",
            hookEventName: "Stop",
            backgroundTasks: [
                StopBackgroundTask(id: "t1", type: "workflow", status: "running", name: "Build"),
                StopBackgroundTask(id: "t2", type: "shell", status: "running", description: "tail -f logs"),
                StopBackgroundTask(id: "t3", type: "subagent", status: "running"),
                StopBackgroundTask(id: "t4", status: "completed"),
                StopBackgroundTask(id: "t5", status: "failed"),
                StopBackgroundTask(id: "t6", status: "cancelled"),
                StopBackgroundTask(id: "t7", status: "killed"),
                // Unknown status counts as pending — the classifier fails open.
                StopBackgroundTask(id: "t8", status: "someday-new-status"),
            ],
            sessionCrons: [
                // Cron entries carry no status — any listed cron can fire.
                StopSessionCron(id: "c1", schedule: "0 9 * * *", recurring: true, prompt: "check the build"),
                StopSessionCron(id: "c2"),
            ]
        )
        // Labels prefer name, then description, then type, then id.
        #expect(body.pendingBackgroundWork == [
            "Build", "tail -f logs", "subagent", "t8", "check the build", "c2",
        ])
    }

    @Test("labels clip 1000-char upstream descriptions")
    func labelsClipLongDescriptions() throws {
        let body = StopBody(
            sessionId: "s",
            hookEventName: "Stop",
            backgroundTasks: [
                StopBackgroundTask(id: "t1", status: "running", description: String(repeating: "x", count: 500)),
            ]
        )
        let label = try #require(body.pendingBackgroundWork.first)
        #expect(label.count == 80)
        #expect(label.hasSuffix("…"))
    }

    // MARK: - handleIngress gating

    @Test("a paused Stop (pending work, message not final) is downgraded to still-working")
    func pausedStopDowngraded() async throws {
        let recorder = ClassifierRecorder()
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame(pausedStop))
        }

        // Downgraded: the session keeps its Working spinner, the summary still
        // rides a notification — flavored still-working, not done — and no app
        // actions fire (a pause must not close panes or suggest opens).
        let downgraded = try #require(event)
        #expect(downgraded.state == .working)
        #expect(downgraded.notification == NotificationSpec(
            title: "Still Working",
            body: "MyProject: The build is running; I'll report back when it finishes."
        ))
        #expect(downgraded.appActions.isEmpty)
        #expect(downgraded.tmuxPane == "%1")
        #expect(downgraded.projectPath == "/Users/test/MyProject")

        // The classifier saw the message and only the still-pending work (the
        // lingering completed task is filtered out).
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.message == "The build is running; I'll report back when it finishes.")
        #expect(calls.first?.pendingWork == ["Build service"])
    }

    @Test("the still-working notification truncates long summaries")
    func stillWorkingNotificationTruncates() async throws {
        let longSummary = "Waiting on the build. " + String(repeating: "x", count: 300)
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "\(longSummary)",
            "background_tasks": [
                {"id": "t1", "type": "shell", "status": "running", "description": "build"}
            ]
        }
        """
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { _, _ in .stillWaiting },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame(json))
        }

        // Mirrors the translator's done-notification copy: 256 chars + ellipsis.
        let body = try #require(event?.notification?.body)
        #expect(body == "MyProject: " + longSummary.prefix(256) + "...")
    }

    @Test("a final-sounding Stop is applied even with pending work")
    func finalStopKept() async throws {
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { _, _ in .final },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame(pausedStop))
        }

        #expect(event?.state == .doneWorking(
            summary: "The build is running; I'll report back when it finishes."
        ))
    }

    @Test("an active cron alone (no background tasks) triggers classification")
    func cronOnlyTriggersClassification() async throws {
        let recorder = ClassifierRecorder()
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame("""
            {
                "hook_event_name": "Stop",
                "session_id": "sess-1",
                "last_assistant_message": "I'll check the build on the next wakeup.",
                "background_tasks": [],
                "session_crons": [
                    {"id": "cron-001", "schedule": "0 9 * * *", "recurring": true, "prompt": "check the build"}
                ]
            }
            """))
        }

        let downgraded = try #require(event)
        #expect(downgraded.state == .working)
        #expect(downgraded.notification?.title == "Still Working")
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.pendingWork == ["check the build"])
    }

    @Test("the classifier is not consulted when no work is actually pending")
    func classifierSkippedWithoutPendingWork() async throws {
        // Only terminal tasks linger in the arrays — the stop is unambiguous,
        // so no Apple Intelligence round-trip.
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "All done.",
            "background_tasks": [
                {"id": "t1", "type": "shell", "status": "completed"},
                {"id": "t2", "type": "shell", "status": "cancelled"}
            ],
            "session_crons": []
        }
        """
        let recorder = ClassifierRecorder()
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame(json))
        }

        #expect(event?.state == .doneWorking(summary: "All done."))
        #expect(await recorder.calls.isEmpty)
    }

    @Test("an empty-message Stop with pending work is kept without classifying")
    func emptyMessageStopKept() async throws {
        // An empty message gives the model nothing to judge — fail open (keep the
        // stop) rather than guessing, mirroring the empty-message boundary pinned
        // in ClaudeCodeTranslatorTests.
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1",
            "last_assistant_message": "",
            "background_tasks": [
                {"id": "t1", "type": "shell", "status": "running", "description": "build"}
            ]
        }
        """
        let recorder = ClassifierRecorder()
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore()
            return await core.handleIngress(frame(json))
        }

        #expect(event?.state == .doneWorking(summary: ""))
        #expect(await recorder.calls.isEmpty)
    }

    @Test("detect_false_stops off → Stop honored, classifier untouched")
    func settingOffSkipsClassifier() async throws {
        let recorder = ClassifierRecorder()
        let event = try await withDependencies {
            $0[StopFinalityClassifier.self] = StopFinalityClassifier(
                classify: { message, pendingWork in
                    await recorder.record(message: message, pendingWork: pendingWork)
                    return .stillWaiting
                },
                availability: { .available }
            )
        } operation: {
            let core = try await makeCore(settings: Data(#"{"detect_false_stops": false}"#.utf8))
            return await core.handleIngress(frame(pausedStop))
        }

        #expect(event?.state == .doneWorking(
            summary: "The build is running; I'll report back when it finishes."
        ))
        #expect(await recorder.calls.isEmpty)
    }

    // MARK: - Availability presentation

    @Test("only permanent unavailability disables the settings toggle")
    func availabilityDisablesToggle() {
        #expect(StopFinalityAvailability.available.disablesToggle == false)
        // Transient: the stored setting stays editable while the model arrives.
        #expect(StopFinalityAvailability.modelDownloading.disablesToggle == false)
        #expect(StopFinalityAvailability.unsupported.disablesToggle == true)
        #expect(StopFinalityAvailability.appleIntelligenceDisabled.disablesToggle == true)
    }

    @Test("every unavailable state explains itself in the settings caption")
    func availabilityCaptions() {
        #expect(StopFinalityAvailability.available.settingsCaption == nil)
        #expect(StopFinalityAvailability.unsupported.settingsCaption?.contains("macOS 26+") == true)
        #expect(
            StopFinalityAvailability.appleIntelligenceDisabled.settingsCaption?
                .contains("System Settings") == true
        )
        #expect(StopFinalityAvailability.modelDownloading.settingsCaption?.contains("downloading") == true)
    }

    // MARK: - Deadline race

    @Test("the deadline race fails open when inference outlasts the deadline")
    func deadlineFailsOpen() async {
        let verdict = await StopFinalityClassifier.raceAgainstDeadline(.milliseconds(50)) {
            // Simulates a wedged model daemon: nowhere near answering within the
            // deadline. Cancellation (via the race losing) unblocks the sleep, so
            // the test doesn't linger.
            try? await Task.sleep(for: .seconds(30))
            return .stillWaiting
        }
        #expect(verdict == .final)
    }

    @Test("the deadline race returns the verdict when inference wins")
    func deadlineReturnsInferenceVerdict() async {
        let verdict = await StopFinalityClassifier.raceAgainstDeadline(.seconds(30)) {
            .stillWaiting
        }
        #expect(verdict == .stillWaiting)
    }
}
