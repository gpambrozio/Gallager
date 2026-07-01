import Foundation

/// E2E scenario: `AppAction.sessionEnded` driven by an out-of-process
/// `EchoPluginSidecar` `PluginEvent` (the `appActions` lifecycle path).
///
/// `ClosePaneOnSessionEndScenario` covers session-end via a *Claude hook*; this
/// covers it via a *sidecar's* `translate_event` reply carrying an `appActions`
/// array — the exact seam where `appActions` (non-Optional, no decode default)
/// must survive the stdio transport. With `closePaneEligible: true` the host
/// closes the bound pane; an untouched second session proves the action is scoped
/// to the one pane:
///
///   echo-sidecar event with `appActions: [{ sessionEnded(sessionID: <pane>,
///   closePaneEligible: true) }]` → `SidecarPluginCore` decodes the `PluginEvent`
///   → dispatcher → `onAppAction` → host ends the agent session for that pane and
///   (because the flag is true) closes the pane.
///
/// Note: the `sessionEnded` `sessionID` is the **tmux pane id** (the host keys
/// session-end by pane), not the agent session id.
public enum PluginSidecarSessionEndedScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Session Ended",
        tags: ["plugin", "sidecar", "sessions", "macos-only"]
    ) {
        // 1. Stage the echo-sidecar fixture before the app launches.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        // 2. Two tmux sessions: one we end (and expect closed), one we keep.
        TestStep.tmuxCreateSession(name: "sidecar-end", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "sidecar-keep", width: 80, height: 24)
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        // 3. Store pane ids; confirm both terminals are present in the sidebar.
        TestStep.tmuxStorePaneId(target: "sidecar-end:0.0", storeAs: "endPane")
        TestStep.tmuxStorePaneId(target: "sidecar-keep:0.0", storeAs: "keepPane")
        TestStep.macWaitForElement(titled: "sidecar-end", timeout: 5)
        TestStep.macWaitForElement(titled: "sidecar-keep", timeout: 5)

        // 4. Bind both panes to working sidecar sessions, each with a distinctive
        //    projectPath so the sidebar row shows the project name (a sidecar
        //    session with no projectPath falls back to the raw session id, unlike
        //    Claude which keeps the tmux name). Only a PluginEvent creates a
        //    sidecar session, so this is what makes them agent sessions.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            { "sessionID": "${endPane}", "state": { "working": {} }, "projectPath": "/Users/test/SidecarEnd" }
            """,
            tmuxPane: "${endPane}"
        )
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            { "sessionID": "${keepPane}", "state": { "working": {} }, "projectPath": "/Users/test/SidecarKeep" }
            """,
            tmuxPane: "${keepPane}"
        )
        TestStep.macWaitForElement(titled: "SidecarEnd", timeout: 5)
        TestStep.macWaitForElement(titled: "SidecarKeep", timeout: 5)
        TestStep.macScreenshot(label: "mac-sidecar-sessions-bound", compare: false)

        // 5. End the first session via a sidecar appAction with the close flag.
        //    The appAction's sessionID is the PANE id (the host's session-end key).
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "${endPane}",
                "appActions": [
                    { "sessionEnded": { "sessionID": "${endPane}", "closePaneEligible": true } }
                ]
            }
            """,
            tmuxPane: "${endPane}"
        )

        // 6. The ended session's agent row disappears (the pane closes, or at
        //    minimum reverts to a plain terminal — either way the "SidecarEnd"
        //    agent session is gone); the untouched session stays.
        TestStep.macWaitForElementToDisappear(titled: "SidecarEnd", timeout: 20)
        TestStep.macScreenshot(label: "mac-sidecar-session-ended", compare: false)
        TestStep.macWaitForElement(titled: "SidecarKeep", timeout: 5)
    }
}
