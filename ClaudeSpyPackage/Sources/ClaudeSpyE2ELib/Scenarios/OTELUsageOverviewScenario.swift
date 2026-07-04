import Foundation

/// E2E scenario: the cross-session cost/usage overview renders as a collapsed
/// "Today" line on the macOS sidebar AND the iOS session list, and expands /
/// contracts in place via the disclosure chevron (issue #598, part B +
/// collapsible cell).
///
/// Proves the receive → accumulate → durable-store → overview → render pipeline
/// without a live Claude, building on the #597 OTEL channel — plus the
/// cross-device path: the overview rides `SessionStateMessage` to the paired
/// iOS viewer.
/// 1. Mac host + iOS viewer pair via `FreshPairingScenario`.
/// 2. A tmux session is created and bound to a Claude `session.id` via a
///    synthetic `SessionStart` hook, then a `UserPromptSubmit` carrying a
///    `permission_mode` + project path so the pane has a `detectedProjectPath`
///    (the aggregation key the usage store attributes spend to).
/// 3. Synthetic OTLP/JSON `api_request` + `commit.count` are POSTed to the
///    Mac-local receiver from the pane's own shell (addressed by the instance's
///    `${otlpEndpoint}`, like the render scenario).
/// 4. The mac sidebar shows the collapsed "Today" total; clicking it expands
///    to Projects + Recent days; clicking again contracts it.
/// 5. The iOS session list shows the same collapsed line (the overview rode
///    the session-state push); tapping expands and contracts it.
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
        tags: ["telemetry", "otel"]
    ) {
        // 1. Pair the mac host with the iOS simulator (starts the relay and
        //    launches both apps), then open the Panes window on the host.
        FreshPairingScenario.scenario
        Shortcut.openPanesWindow()
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

        // 4. macOS: the local sidebar section shows the collapsed "Today"
        //    overview cell. Match on its accessibility label (SwiftUI
        //    identifiers don't reliably surface as AXIdentifier on macOS, but
        //    labels do — the header's label is the button's AXDescription).
        TestStep.macWaitForElementQuery(.anyTextMatches("Today's usage"), timeout: 10)
        TestStep.macScreenshot(label: "mac-usage-overview")

        //    Expand: click the header row, the Projects section appears.
        TestStep.macClickButton(titled: "Today's usage")
        TestStep.macWaitForElement(titled: "Projects", timeout: 10)
        TestStep.macScreenshot(label: "mac-usage-overview-expanded")

        //    Contract: click again, the details disappear.
        TestStep.macClickButton(titled: "Today's usage")
        TestStep.macWaitForElementToDisappear(titled: "Projects", timeout: 10)

        // 5. iOS: the overview rode the session-state push to the viewer.
        //    The host throttles telemetry pushes to ~1/s, so allow a little
        //    slack for the collapsed line to appear.
        TestStep.iosWaitForElement(.labelContains("Today's usage"), timeout: 20)
        TestStep.iosScreenshot(label: "ios-usage-overview")

        //    Expand: tap the header row, the Projects section appears.
        TestStep.iosTap(.labelContains("Today's usage"))
        TestStep.iosWaitForElement(.labelContains("Projects"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-usage-overview-expanded")

        //    Contract: tap again, the details disappear.
        TestStep.iosTap(.labelContains("Today's usage"))
        TestStep.iosWaitForElementToDisappear(.labelContains("Projects"), timeout: 10)
    }
}
