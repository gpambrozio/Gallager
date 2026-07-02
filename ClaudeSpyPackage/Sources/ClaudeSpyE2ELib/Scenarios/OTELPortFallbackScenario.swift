import Foundation

/// E2E scenario: OTLP receiver port-collision fallback (PR #620 bug fix).
///
/// Reproduces the silent-hijack bug: a foreign process holding the receiver's
/// IPv4 loopback port (observed live as an OTLP collector container on
/// `127.0.0.1:4318`) swallowed every telemetry export. The old port-only bind
/// created a dual-stack IPv6 wildcard socket that COEXISTED with the squatter —
/// the app believed it was listening while the kernel routed all IPv4 traffic
/// to the other process, so the meter silently stayed empty.
///
/// 1. BEFORE launch, the orchestrator occupies instance 0's preferred
///    `--otlp-port` (`MacOSDriver.defaultOTLPPort`) with a plain IPv4 listener
///    that accepts connections but never speaks HTTP — the exact shape of the
///    real-world squatter.
/// 2. The fixed app binds `127.0.0.1` explicitly, gets `EADDRINUSE`, falls back
///    to the next candidate port (+100), and publishes it as `advertisedPort`;
///    the orchestrator re-reads it via `/otlp-port` after launch and repoints
///    `${otlpEndpoint}`.
/// 3. A session is bound via hooks and a synthetic `api_request` is POSTed to
///    `${otlpEndpoint}` — the meter renders, proving the fallback receiver is
///    live end-to-end.
///
/// WITHOUT the fix this scenario fails at the meter wait: the app "binds" the
/// occupied port without error, `${otlpEndpoint}` stays pointed at the squatter
/// (`/otlp-port` doesn't exist pre-fix, so the pre-seeded preferred port is
/// used), the POST lands on a socket that never answers, and no meter appears.
public enum OTELPortFallbackScenario {
    /// `api_request` log: 20 000 input + 500 output tokens, $0.77.
    /// → meter "⚡ 20.5k · $0.77". Same real wire shape as
    /// `OTELTelemetryRenderScenario` (fully-qualified `body`, bare `event.name`),
    /// but framed with `Transfer-Encoding: chunked` (curl streams the body
    /// chunked when told to, dropping Content-Length) — the framing Claude
    /// Code's real exporter uses, so the suite covers both framings:
    /// Content-Length in the render scenario, chunked here.
    private static let apiRequestCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"e2e-fallback-session"}},{"key":"input_tokens","value":{"intValue":"20000"}},{"key":"output_tokens","value":{"intValue":"500"}},{"key":"cost_usd","value":{"doubleValue":0.77}},{"key":"duration_ms","value":{"intValue":"1200"}},{"key":"model","value":{"stringValue":"claude-opus-4-8"}}]}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "OTEL Port Fallback",
        tags: ["telemetry", "otel", "macos-only"]
    ) {
        // 1. Squat on the app's preferred OTLP port BEFORE it launches. The
        //    occupying socket is orchestrator-owned and auto-released in the
        //    between-scenario cleanup.
        TestStep.occupyTCPPort(port: MacOSDriver.defaultOTLPPort)

        // 2. Launch the host — its OTLP receiver must detect the collision and
        //    bind a fallback candidate (the post-launch `/otlp-port` query
        //    repoints `${otlpEndpoint}` there).
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)
        // The OTEL meter is an opt-in sidebar field, off by default.
        TestStep.macSetSidebarFields(["customDescription", "projectName", "currentPath", "tokenUsage"])

        // 3. Create a session and bind it to a known Claude session id.
        TestStep.tmuxCreateSession(name: "fallback-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "fallback-session:0.0", storeAs: "fallbackPane")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-fallback-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${fallbackPane}",
            projectPath: "/Users/test/FallbackProject"
        )
        TestStep.wait(seconds: 2)

        // 4. POST a synthetic api_request to the receiver's REAL endpoint.
        //    With the preferred port squatted, this only renders a meter if the
        //    fallback bind + advertised-port plumbing worked end-to-end.
        Shortcut.tmuxRunCommand(target: "fallback-session:0.0", command: apiRequestCurl)
        TestStep.wait(seconds: 2)

        // 5. The meter renders in the sidebar row despite the squatter.
        TestStep.macWaitForElementQuery(.anyTextMatches("$0.77"), timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("20.5k"), timeout: 5)
        TestStep.macScreenshot(label: "mac-otel-port-fallback-meter")
    }
}
