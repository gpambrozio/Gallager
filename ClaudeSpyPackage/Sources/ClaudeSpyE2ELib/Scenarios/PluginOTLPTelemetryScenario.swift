import Foundation

/// E2E scenario: a sidecar plugin's DECLARED OTLP namespace renders the token
/// meter (issue #617).
///
/// The plugin-driven counterpart to `OTELTelemetryRenderScenario` (Claude) and
/// `CodexOTELTelemetryRenderScenario` (Codex): proves that a sidecar plugin
/// whose manifest declares an `otlp` namespace gets the same per-session
/// receive → classify → join → render pipeline with NO accumulator code change:
/// 1. The `echo-sidecar` fixture is staged with `"otlp": {"namespace":
///    "echo-sidecar"}` in its manifest — the whole integration surface.
/// 2. A tmux pane is bound to a sidecar session via the real ingress socket
///    (the echoed `sessionID` becomes the pane's `claudeSessionID`, the shared
///    OTEL join key).
/// 3. An OTLP/JSON record named `echo-sidecar.api_request` — Claude's exact
///    attribute vocabulary, the shape the opencode bridge emits — is POSTed to
///    the instance's receiver via `${otlpEndpoint}` (the port it actually
///    bound, queried via `/otlp-port`).
/// 4. The declared namespace classifies, joins on `session.id`, and the
///    sidebar row shows the meter (cost) and model tag.
public enum PluginOTLPTelemetryScenario {
    /// `echo-sidecar.api_request`: 12 000 input + 400 output tokens, $0.42,
    /// `claude-sonnet-5`. → meter "⚡ 12.4k · $0.42" and model tag "sonnet-5".
    /// Fully-qualified name in both the `event.name` attribute and the
    /// top-level `eventName` field — exactly how the opencode bridge emits
    /// (a declared namespace is never bare, unlike Claude's `api_request`).
    private static let apiRequestCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"eventName":"echo-sidecar.api_request","attributes":[{"key":"event.name","value":{"stringValue":"echo-sidecar.api_request"}},{"key":"session.id","value":{"stringValue":"e2e-plugin-otlp-session"}},{"key":"input_tokens","value":{"intValue":12000}},{"key":"output_tokens","value":{"intValue":400}},{"key":"cost_usd","value":{"doubleValue":0.42}},{"key":"duration_ms","value":{"intValue":1500}},{"key":"model","value":{"stringValue":"claude-sonnet-5"}}]}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin OTLP Telemetry Render",
        tags: ["telemetry", "otel", "plugin", "sidecar", "macos-only"]
    ) {
        // 1. Stage the echo-sidecar fixture WITH the manifest otlp declaration,
        //    before the app launches (folder-drop discovery runs at startup and
        //    pushes the declared namespaces to the OTLP receiver).
        TestStep.macStageSidecarFixture(id: "echo-sidecar", otlpNamespace: "echo-sidecar")

        // 2. Launch the host and open the Panes window; the OTEL meter is an
        //    opt-in sidebar field (issue #597), off by default.
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)
        TestStep.macSetSidebarFields(["customDescription", "projectName", "currentPath", "tokenUsage"])

        // 3. Create a pane and bind it to a sidecar session through the real
        //    ingress socket → echo sidecar → dispatcher path. The reported
        //    `sessionID` is stamped as the pane's `claudeSessionID` — the same
        //    join key the opencode sidecar reports (its pane id).
        TestStep.tmuxCreateSession(name: "plugin-otlp-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "plugin-otlp-session:0.0", storeAs: "pluginOtlpPane")
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "e2e-plugin-otlp-session",
                "state": { "working": {} },
                "projectPath": "/Users/test/PluginOtlpProject"
            }
            """,
            tmuxPane: "${pluginOtlpPane}"
        )
        // Let the host pick up the session row.
        TestStep.wait(seconds: 2)

        // 4. POST the declared-namespace api_request to the loopback receiver
        //    from the pane's own shell.
        Shortcut.tmuxRunCommand(target: "plugin-otlp-session:0.0", command: apiRequestCurl)

        // 5. The meter and model tag render in the sidebar row — proving the
        //    manifest-declared namespace classified (an undeclared namespace is
        //    silently dropped, the pre-#617 behavior).
        TestStep.macWaitForElementQuery(.anyTextMatches("$0.42"), timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("sonnet-5"), timeout: 5)

        // 6. Select the session row so its pane is mirrored in the main area.
        //    The scenario has no other selection step, so without this the
        //    screenshot races on whatever window happens to be selected — the
        //    empty "Select a Window" placeholder vs. the mirrored terminal.
        //    Clicking the row (labelled by the project name) deterministically
        //    shows the pane; the sidebar meter is unaffected. Same
        //    select-then-mirror-then-settle pattern as MultiPaneWindowScenario.
        TestStep.macWaitForElement(titled: "PluginOtlpProject", timeout: 10)
        TestStep.macClickButton(titled: "PluginOtlpProject")
        TestStep.wait(seconds: 3)
        // The mirrored terminal in the main pane exhibits ~2.68% sub-pixel
        // glyph-rendering jitter run-to-run (font hinting/anti-aliasing between two
        // stable render states — verified as an in-place difference, not a row
        // shift, so neither a fresh baseline nor a prompt-ready wait removes it).
        // The meter's correctness is asserted functionally above (`$0.42` +
        // `sonnet-5` via AXValue), so this shot only needs to guard against gross
        // visual regressions; widen the tolerance to 4% to clear the sub-pixel
        // jitter while still failing on a missing meter or wrong content (which
        // diff far more than 4%).
        TestStep.macScreenshot(label: "mac-plugin-otlp-meter", tolerance: 4)
    }
}
