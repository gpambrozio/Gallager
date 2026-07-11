import Foundation

/// E2E scenario: a `Stop` hook that fires while background tasks are still in
/// flight — and whose message reads as "waiting", per the finality classifier —
/// must not flip the session to "Done" (issue #644).
///
/// Claude Code fires `Stop` when it *parks* a turn waiting on background tasks
/// / session crons, not only when it finishes. The payload's `background_tasks`
/// array alone can't distinguish the two (a task pending termination lingers
/// after a genuinely final message), so `handleIngress` asks the
/// `StopFinalityClassifier` for the last word. In `--e2e-test` mode the
/// classifier is deterministic: a message containing `[e2e-still-waiting]`
/// classifies as still-waiting (CI has no Apple Intelligence to run the real
/// on-device model).
///
/// 1. A tmux pane is bound to a Claude session (`SessionStart`) and put to
///    work (`UserPromptSubmit` → "Working").
/// 2. A `Stop` with a running background task and a waiting-sounding message
///    arrives — the session must STAY "Working". Without the fix this phase
///    shows "Done" (and fires a premature done notification).
/// 3. A `Stop` with the same running background task but a final-sounding
///    message arrives — the session goes to "Done", proving lingering
///    background work can't wedge a genuinely finished session on "Working".
public enum PausedStopIgnoredScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Paused Stop Ignored",
        tags: ["hooks", "sessions", "macos-only"]
    ) {
        // 1. Launch the host and open the Panes window.
        Shortcut.macOnlySetup

        // 2. Create a pane and bind it to a Claude session.
        TestStep.tmuxCreateSession(name: "paused-stop", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "paused-stop:0.0", storeAs: "paneId")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-paused-stop-session",
                "timestamp": "2026-02-14T10:00:00.000000Z",
                "source": "startup"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/PausedStopProject"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 10)

        // 3. Put the session to work.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-paused-stop-session",
                "timestamp": "2026-02-14T10:00:05.000000Z",
                "prompt": "build the service"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/PausedStopProject"
        )
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macScreenshot(label: "mac-working")

        // 4. THE PAUSE — a Stop with a running background task and a message the
        //    classifier reads as still-waiting. It must be dropped, leaving the
        //    session "Working".
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-paused-stop-session",
                "timestamp": "2026-02-14T10:00:10.000000Z",
                "last_assistant_message": "[e2e-still-waiting] The build is running; I'll report back when it finishes.",
                "background_tasks": [
                    {
                        "id": "task-001",
                        "name": "Build service",
                        "status": "running",
                        "created_at": "2026-02-14T10:00:06.000000Z",
                        "last_updated_at": "2026-02-14T10:00:09.000000Z"
                    }
                ],
                "session_crons": []
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/PausedStopProject"
        )
        // Deliberate fixed wait: a *dropped* frame produces no observable
        // signal, so give the ingress pipeline time to have applied the state
        // flip if it were (wrongly) going to. Only then assert the row still
        // says "Working" — with one session, "Working" present ⇒ not "Done".
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "Working", timeout: 5)
        TestStep.macScreenshot(label: "mac-still-working-after-paused-stop")

        // 5. THE FINISH — the background task still lingers (pending
        //    termination), but the message reads as final, so the stop lands
        //    and the session goes to "Done".
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-paused-stop-session",
                "timestamp": "2026-02-14T10:00:15.000000Z",
                "last_assistant_message": "The build succeeded and the service is ready.",
                "background_tasks": [
                    {
                        "id": "task-001",
                        "name": "Build service",
                        "status": "running",
                        "created_at": "2026-02-14T10:00:06.000000Z",
                        "last_updated_at": "2026-02-14T10:00:14.000000Z"
                    }
                ],
                "session_crons": []
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/PausedStopProject"
        )
        TestStep.macWaitForElement(titled: "Done", timeout: 10)
        TestStep.macScreenshot(label: "mac-done-after-final-stop")
    }
}
