import Foundation

/// E2E scenario: Codex OTEL telemetry renders in the macOS sidebar (issue #602).
///
/// The Codex counterpart to `OTELTelemetryRenderScenario`, proving the full
/// receive → join → render pipeline for a Codex-backed session without a live
/// Codex:
/// 1. A tmux session is created and bound to a Codex `conversation.id` via a
///    synthetic `SessionStart` hook routed through the **codex** plugin (sets
///    `PaneState.claudeSessionID`, the shared OTEL join key).
/// 2. Synthetic Codex OTLP/JSON is POSTed to the Mac-local receiver from the
///    pane's own shell via `curl`, addressed by the `${otlpEndpoint}` context
///    variable (this instance's `--otlp-port`). Tokens ride `codex.sse_event`
///    (`response.completed`) and per-turn latency rides `codex.turn_ttft`. Both
///    Codex log events carry `conversation.id` (`codex.api_request` does not).
/// 3. The receiver joins by `conversation.id` and stamps the pane, so the
///    sidebar's `SessionTelemetrySummary` shows the token meter (no `$`, since
///    Codex emits no cost) and the model tag. The approval/permission-mode chip
///    is seeded from the Codex **hook** channel (Codex has no OTEL mode signal).
public enum CodexOTELTelemetryRenderScenario {
    /// `codex.sse_event` / `response.completed`: 12 000 input + 400 output tokens,
    /// `gpt-5-codex`. → meter "⚡ 12.4k" (no cost) and model tag "gpt-5-codex".
    /// Faithful to real Codex 0.140: the top-level `eventName` field is a Rust
    /// source location (NOT the event name), so the receiver must read the name
    /// from the `event.name` attribute — trusting `eventName` dropped every Codex
    /// record (the #602 "no meter" bug). Real attribute names + join key
    /// (`conversation.id`) verified against codex-rs `sse_event_completed`.
    private static let sseEventCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"eventName":"event otel/src/events/session_telemetry.rs:925","attributes":[{"key":"event.name","value":{"stringValue":"codex.sse_event"}},{"key":"event.kind","value":{"stringValue":"response.completed"}},{"key":"conversation.id","value":{"stringValue":"e2e-codex-otel-session"}},{"key":"model","value":{"stringValue":"gpt-5-codex"}},{"key":"input_token_count","value":{"stringValue":"12000"}},{"key":"output_token_count","value":{"stringValue":"400"}},{"key":"cached_token_count","value":{"intValue":"0"}}]}]}]}]}'"#

    /// `codex.turn_ttft`: the turn's time-to-first-token `duration_ms` (per-turn
    /// latency rides a separate event from tokens; `turn_ttft` carries the
    /// `conversation.id` join key, while `codex.api_request` does not).
    private static let turnTtftCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"eventName":"event otel/src/events/session_telemetry.rs:640","attributes":[{"key":"event.name","value":{"stringValue":"codex.turn_ttft"}},{"key":"conversation.id","value":{"stringValue":"e2e-codex-otel-session"}},{"key":"duration_ms","value":{"intValue":"1500"}},{"key":"model","value":{"stringValue":"gpt-5-codex"}}]}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Codex OTEL Telemetry Render",
        tags: ["telemetry", "otel", "codex", "macos-only"]
    ) {
        // 1. Launch the host and open the Panes window.
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)
        // The OTEL meter is an opt-in sidebar field (issue #597), off by default.
        TestStep.macSetSidebarFields(["customDescription", "projectName", "currentPath", "tokenUsage"])

        // 2. Create a session and bind it to a known Codex conversation id via a
        //    SessionStart hook routed through the codex plugin.
        TestStep.tmuxCreateSession(name: "codex-otel-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "codex-otel-session:0.0", storeAs: "codexOtelPane")
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-codex-otel-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${codexOtelPane}",
            projectPath: "/Users/test/CodexOtelProject"
        )
        TestStep.wait(seconds: 2)

        // 3. The approval/permission-mode chip is seeded from the Codex HOOK
        //    channel (Codex has no OTEL mode-change signal). A UserPromptSubmit
        //    carries the current `permission_mode`; the chip must appear from it.
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-codex-otel-session",
                "permission_mode": "default",
                "prompt": "hello",
                "timestamp": "2026-02-14T10:00:03.000000Z"
            }
            """,
            tmuxPane: "${codexOtelPane}",
            projectPath: "/Users/test/CodexOtelProject"
        )
        TestStep.macWaitForElementQuery(.anyTextMatches("Default"), timeout: 10)
        TestStep.macScreenshot(label: "mac-codex-otel-hook-default-mode")

        // 4. POST a synthetic Codex sse_event (tokens) then turn_ttft (latency)
        //    to the loopback receiver from the pane. Posting turn_ttft here also
        //    smoke-tests that the live receiver accepts its real OTLP wire shape
        //    (eventName-as-source-location + `event.name` attribute + the
        //    `conversation.id` join key) end-to-end, not just in unit tests.
        Shortcut.tmuxRunCommand(target: "codex-otel-session:0.0", command: sseEventCurl)
        TestStep.wait(seconds: 1)
        Shortcut.tmuxRunCommand(target: "codex-otel-session:0.0", command: turnTtftCurl)
        TestStep.wait(seconds: 2)

        // 5. The meter + model tag render in the sidebar row. Codex emits no cost,
        //    so the meter is tokens-only (visible "12.4k", no "$…"); the model tag
        //    proves the codex.sse_event was parsed and joined by conversation.id.
        //
        //    Assert on "12400", not the visible "12.4k": `SessionMeterView` ignores
        //    its children for accessibility and exposes the raw count as its label
        //    ("12400 tokens"), so the abbreviated glyph never reaches the AX tree.
        //    The Claude sibling asserts the cost ("$0.42") for the same reason —
        //    that string IS in the label — but Codex has no cost, so the headline
        //    token total is what this surface can match.
        //
        //    The turn_ttft latency ("1.5s") is deliberately NOT asserted here:
        //    latency is a status-bar-only field (`SessionTelemetryStatusBar`),
        //    intentionally omitted from the compact sidebar `SessionTelemetrySummary`
        //    this scenario screenshots — so it can't surface on this surface (the
        //    sibling `OTELTelemetryRenderScenario` posts `duration_ms` and skips the
        //    same assertion for the same reason). The full receive → join → stamp →
        //    back-fill path for turn_ttft is covered by the
        //    `codexTurnTtftRecordsLatency` accumulator unit test.
        TestStep.macWaitForElementQuery(.anyTextMatches("12400"), timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("gpt-5-codex"), timeout: 5)
        TestStep.macScreenshot(label: "mac-codex-otel-meter")
    }
}
