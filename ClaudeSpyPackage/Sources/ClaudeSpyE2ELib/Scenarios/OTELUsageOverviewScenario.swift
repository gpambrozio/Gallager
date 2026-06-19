import Foundation

/// E2E scenario: the cross-session cost/usage overview renders on the macOS
/// sidebar (issue #598, part B).
///
/// Proves the receive → accumulate → durable-store → overview → render pipeline
/// without a live Claude, building on the #597 OTEL channel:
/// 1. A tmux session is created and bound to a Claude `session.id` via a
///    synthetic `SessionStart` hook, then a `UserPromptSubmit` carrying a
///    `permission_mode` + project path so the pane has a `detectedProjectPath`
///    (the aggregation key the usage store attributes spend to).
/// 2. Synthetic OTLP/JSON `api_request` + `commit.count` are POSTed to the
///    Mac-local receiver from the pane's own shell (addressed by the instance's
///    `${otlpEndpoint}`, like the render scenario).
/// 3. `AppCoordinator` folds the snapshot into `UsageAggregationStore`, recomputes
///    the host `UsageOverview`, and the local sidebar section shows the
///    `UsageOverviewHeader` "Today" total.
public enum OTELUsageOverviewScenario {
    /// `api_request` log: 30 000 input + 1 000 output tokens, $1.23, opus-4.8.
    /// → today total "31k · $1.23 · 1 session". Real wire shape (bare `event.name`
    /// attribute + fully-qualified body), matching the render scenario.
    private static let apiRequestCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"e2e-usage-session"}},{"key":"input_tokens","value":{"intValue":"30000"}},{"key":"output_tokens","value":{"intValue":"1000"}},{"key":"cost_usd","value":{"doubleValue":1.23}},{"key":"duration_ms","value":{"intValue":"1500"}},{"key":"model","value":{"stringValue":"claude-opus-4-8"}}]}]}]}]}'"#

    /// `commit.count` metric (cumulative 2) → carried onto the snapshot and into
    /// the store's per-project commit total (issue #598).
    private static let commitMetricCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/metrics -H 'Content-Type: application/json' -d '{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"e2e-usage-session"}}],"asInt":"2"}]}}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "OTEL Usage Overview",
        tags: ["telemetry", "otel", "macos-only"]
    ) {
        // 1. Launch the host and open the Panes window.
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)

        // 2. Create a session and bind it to a known Claude session id with a
        //    project path (the usage store's aggregation key).
        TestStep.tmuxCreateSession(name: "usage-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "usage-session:0.0", storeAs: "usagePane")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-usage-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${usagePane}",
            projectPath: "/Users/test/OverviewProject"
        )
        // A UserPromptSubmit carrying the project path so the pane's
        // `detectedProjectPath` is set before telemetry arrives — otherwise the
        // store can't attribute the spend and the overview stays empty.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-usage-session",
                "permission_mode": "default",
                "prompt": "hello",
                "timestamp": "2026-02-14T10:00:03.000000Z"
            }
            """,
            tmuxPane: "${usagePane}",
            projectPath: "/Users/test/OverviewProject"
        )
        TestStep.wait(seconds: 2)

        // 3. POST synthetic telemetry to the loopback receiver from the pane.
        Shortcut.tmuxRunCommand(target: "usage-session:0.0", command: apiRequestCurl)
        Shortcut.tmuxRunCommand(target: "usage-session:0.0", command: commitMetricCurl)
        TestStep.wait(seconds: 2)

        // 4. The local sidebar section now shows the "Today" usage overview
        //    header. Match on its accessibility label (SwiftUI identifiers don't
        //    reliably surface as AXIdentifier on macOS, but labels do).
        TestStep.macWaitForElementQuery(.anyTextMatches("Today's usage"), timeout: 10)
        TestStep.macScreenshot(label: "mac-usage-overview")
    }
}
