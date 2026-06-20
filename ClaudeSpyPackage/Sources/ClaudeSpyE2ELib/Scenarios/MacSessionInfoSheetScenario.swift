import Foundation

/// E2E scenario: the macOS "Session Info" sheet (the desktop counterpart to the
/// iOS detail popover).
///
/// Proves the right-click → "Session Info" → shared ``SessionInfoView`` path on
/// the host, reusing the #597/#598 OTEL channel so the sheet has real token /
/// cost numbers to render:
/// 1. A tmux session is created and bound to a Claude `session.id` via a
///    synthetic `SessionStart` (+ `UserPromptSubmit` carrying the project path),
///    so the pane has an agent session — the gate for the "Session Info" item.
/// 2. A synthetic OTLP/JSON `api_request` is POSTed to the Mac-local receiver
///    from the pane's own shell, giving the pane live `SessionTelemetry`.
/// 3. Right-clicking the sidebar row and choosing "Session Info" opens the sheet,
///    which reads the pane's live state and shows the usage breakdown.
public enum MacSessionInfoSheetScenario {
    /// `api_request` log: 30 000 input + 1 000 output tokens, $1.23, opus-4.8.
    /// Real wire shape (bare `event.name` attribute + fully-qualified body),
    /// matching the render / overview scenarios.
    private static let apiRequestCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"e2e-info-session"}},{"key":"input_tokens","value":{"intValue":"30000"}},{"key":"output_tokens","value":{"intValue":"1000"}},{"key":"cost_usd","value":{"doubleValue":1.23}},{"key":"duration_ms","value":{"intValue":"1500"}},{"key":"model","value":{"stringValue":"claude-opus-4-8"}}]}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mac Session Info Sheet",
        tags: ["telemetry", "otel", "macos-only"]
    ) {
        // 1. Launch the host and open the Panes window.
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)

        // 2. Create a session and bind it to a known Claude session id with a
        //    project path so the pane has an agent session (the menu-item gate)
        //    and a `detectedProjectPath` to show in the sheet.
        TestStep.tmuxCreateSession(name: "info-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "info-session:0.0", storeAs: "infoPane")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-info-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${infoPane}",
            projectPath: "/Users/test/InfoProject"
        )
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-info-session",
                "permission_mode": "default",
                "prompt": "hello",
                "timestamp": "2026-02-14T10:00:03.000000Z"
            }
            """,
            tmuxPane: "${infoPane}",
            projectPath: "/Users/test/InfoProject"
        )
        TestStep.wait(seconds: 2)

        // 3. POST synthetic telemetry so the sheet has token/cost numbers.
        Shortcut.tmuxRunCommand(target: "info-session:0.0", command: apiRequestCurl)
        TestStep.wait(seconds: 2)

        // The sidebar row surfaces the *project* name as its stable AX leaf
        // (`SessionAccessibilityOverlay`) — the session name lives in the row
        // button's AXValue, which a "working" row swallows into its busy
        // indicator. Target the project name, which survives that collapse.
        TestStep.macWaitForElement(titled: "InfoProject", timeout: 30)

        // 4. Right-click the session row → "Session Info" opens the sheet.
        TestStep.macContextMenuClick(elementTitle: "InfoProject", menuItem: "Session Info")

        // 5. The sheet renders the shared usage breakdown — the "Tokens
        //    (input + output)" row proves the live telemetry made it through.
        TestStep.macWaitForElement(titled: "Tokens (input + output)", timeout: 10)
        TestStep.macScreenshot(label: "mac-session-info-sheet")
    }
}
