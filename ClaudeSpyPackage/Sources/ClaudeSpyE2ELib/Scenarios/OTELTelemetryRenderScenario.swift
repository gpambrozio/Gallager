import Foundation

/// E2E scenario: OTEL telemetry renders in the macOS sidebar (issue #597).
///
/// Proves the full receive → join → render pipeline without a live Claude:
/// 1. A tmux session is created and bound to a Claude `session.id` via a
///    synthetic `SessionStart` hook (sets `PaneState.claudeSessionID`).
/// 2. Synthetic OTLP/JSON is POSTed to the Mac-local receiver from the pane's
///    own shell via `curl`, addressed by the `${otlpEndpoint}` context variable
///    (resolved by the orchestrator to the port this instance ACTUALLY bound —
///    queried via `/otlp-port` after launch, since the app falls back to
///    candidate ports when its preferred `--otlp-port` is taken). Using the
///    variable instead of a hardcoded port means the POST follows the
///    instance's own receiver, so concurrent instances — and a developer's
///    real app on 24318 — never cross-talk. (The env-injection half of the
///    contract is covered separately by TerminalEnvVarsScenario.)
/// 3. The receiver joins by `session.id` and stamps the pane, so the sidebar's
///    `SessionTelemetrySummary` shows the meter and the model tag. The
///    permission-mode chip is seeded from the hook channel (a `UserPromptSubmit`
///    carrying `permission_mode: "default"` — the bug-report case) and then
///    overridden by an OTEL `permission_mode_changed` event — proving both sources.
public enum OTELTelemetryRenderScenario {
    /// `api_request` log: 12 000 input + 400 output tokens, $0.42, opus-4.8.
    /// → meter "⚡ 12.4k · $0.42" and model tag "opus-4.8".
    ///
    /// Uses Claude's *real* wire shape (verified against v2.1.178): the log
    /// `body` is the fully-qualified `claude_code.api_request`, while the
    /// `event.name` attribute is the bare `api_request`. This exercises the
    /// exact form production receives (a synthetic full-name `eventName` field
    /// would mask the namespace-stripping the accumulator must do).
    private static let apiRequestCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"e2e-otel-session"}},{"key":"input_tokens","value":{"intValue":"12000"}},{"key":"output_tokens","value":{"intValue":"400"}},{"key":"cost_usd","value":{"doubleValue":0.42}},{"key":"duration_ms","value":{"intValue":"1500"}},{"key":"model","value":{"stringValue":"claude-opus-4-8"}}]}]}]}]}'"#

    /// `permission_mode_changed` log → the "Bypass" permission-mode chip. Same
    /// real wire shape: bare `event.name` attribute + fully-qualified body.
    private static let modeChangeCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.permission_mode_changed"},"attributes":[{"key":"event.name","value":{"stringValue":"permission_mode_changed"}},{"key":"session.id","value":{"stringValue":"e2e-otel-session"}},{"key":"to_mode","value":{"stringValue":"bypassPermissions"}},{"key":"trigger","value":{"stringValue":"shift_tab"}}]}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "OTEL Telemetry Render",
        tags: ["telemetry", "otel", "macos-only"]
    ) {
        // 1. Launch the host and open the Panes window.
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)
        // The OTEL meter is an opt-in sidebar field (issue #597), off by
        // default — enable it so the telemetry summary renders in the row.
        TestStep.macSetSidebarFields(["customDescription", "projectName", "currentPath", "tokenUsage"])

        // 2. Create a session and bind it to a known Claude session id.
        TestStep.tmuxCreateSession(name: "otel-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "otel-session:0.0", storeAs: "otelPane")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-otel-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${otelPane}",
            projectPath: "/Users/test/OtelProject"
        )
        // Let the host pick up the session row.
        TestStep.wait(seconds: 2)

        // 3. The permission-mode chip is seeded from the HOOK channel, not OTEL.
        //    OTEL only emits `permission_mode_changed` on a *change*, never the
        //    starting value — so a brand-new session that simply runs in `default`
        //    (and never toggles) would otherwise show no mode at all. A
        //    `UserPromptSubmit` hook carries the current `permission_mode`; the
        //    chip must appear from it alone, before any OTEL mode event. This is
        //    the exact case from the bug report (issue #597). Runs without the
        //    OTLP receiver, so it's exercised even if the receiver never bound.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-otel-session",
                "permission_mode": "default",
                "prompt": "hello",
                "timestamp": "2026-02-14T10:00:03.000000Z"
            }
            """,
            tmuxPane: "${otelPane}",
            projectPath: "/Users/test/OtelProject"
        )
        TestStep.macWaitForElementQuery(.anyTextMatches("Default"), timeout: 10)
        TestStep.macScreenshot(label: "mac-otel-hook-default-mode")

        // 4. POST a synthetic api_request to the loopback receiver from the pane.
        Shortcut.tmuxRunCommand(target: "otel-session:0.0", command: apiRequestCurl)
        TestStep.wait(seconds: 2)

        // 5. The meter and model tag now render in the sidebar row. Match on the
        //    accessibility labels (SwiftUI identifiers don't reliably surface as
        //    AXIdentifier on macOS, but labels do — same path project names use).
        TestStep.macWaitForElementQuery(.anyTextMatches("$0.42"), timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("opus-4.8"), timeout: 5)
        TestStep.macScreenshot(label: "mac-otel-meter")

        // 6. A later OTEL `permission_mode_changed` overrides the hook-seeded mode
        //    (latest wins across channels), surfacing the (loud) bypass chip.
        Shortcut.tmuxRunCommand(target: "otel-session:0.0", command: modeChangeCurl)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("Bypass"), timeout: 10)
        TestStep.macScreenshot(label: "mac-otel-mode-chip")
    }
}
