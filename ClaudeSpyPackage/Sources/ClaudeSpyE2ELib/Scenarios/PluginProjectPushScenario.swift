import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Plugin pushes project list updates (Spec §15.3 #6).
///
/// Echo plugin sends `set_projects` callbacks on init and again whenever
/// the scenario sends `{"_test": "set_projects"}`. Verifies:
/// 1. The initial list (configured via the `ECHO_PROJECTS_JSON` env var,
///    passed through `macSpawnSidecar`'s install path) reaches iOS — the
///    project picker shows "alpha" under the Echo plugin badge.
/// 2. A mid-session `set_projects` payload replaces the list; iOS rebinds
///    the picker to show "beta" instead of "alpha".
/// 3. A manual refresh (iOS pull-to-refresh) round-trips through the
///    relay to the Mac and (eventually, once wired) to the sidecar's
///    `refresh_projects` RPC. The current iOS pull-to-refresh path goes
///    to `connectionManager.requestAllSessionStates()` which Tasks
///    pre-25 didn't wire to `PluginManager.refreshProjects()`; this
///    scenario therefore only asserts the picker still shows the most
///    recently pushed list (no regression). When the refresh button gets
///    wired the assertion can swap to verify the sidecar received a
///    `refresh_projects` RPC.
///
/// Note: `ECHO_PROJECTS_JSON` is read in `EchoSidecar.handleInitialize`
/// from the sidecar's environment. The `macSpawnSidecar` step doesn't
/// expose env propagation to the child process yet, so we emulate the
/// "initial push" by sending an explicit `set_projects` payload right
/// after spawn. The on-disk fixture defaults `ECHO_PROJECTS_JSON` to
/// empty.
public enum PluginProjectPushScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Project Push",
        tags: ["plugins", "echo", "projects"]
    ) {
        FreshPairingScenario.scenario

        TestStep.macSpawnSidecar(
            pluginID: "echo",
            fixtureSourcePath: URL(fileURLWithPath: "Fixtures/EchoPlugin"),
            instance: 0
        )

        TestStep.tmuxCreateSession(name: "echo-projects", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "echo-projects:0.0", storeAs: "paneId")

        // Phase 1 — "initial" push: simulate the `ECHO_PROJECTS_JSON`
        // env-driven push by sending the equivalent payload.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_projects"),
                "projects": .array([
                    .object([
                        "name": .string("alpha"),
                        "path": .string("/a"),
                        "plugin_id": .string("echo"),
                    ]),
                ]),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // iOS picker should show "alpha" under the Echo plugin badge.
        TestStep.iosWaitForElement(.labelContains("New Session"), timeout: 15)
        TestStep.iosTap(.labelContains("New Session"))
        TestStep.iosWaitForElement(.labelContains("alpha"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-projects-alpha")

        // Dismiss the sheet between pushes so the next assertion clearly
        // re-renders the list rather than reading stale on-screen text.
        TestStep.iosTap(.labelContains("Cancel"))
        TestStep.wait(seconds: 1)

        // Phase 2 — mid-session swap: replace the list with beta.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_projects"),
                "projects": .array([
                    .object([
                        "name": .string("beta"),
                        "path": .string("/b"),
                        "plugin_id": .string("echo"),
                    ]),
                ]),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )
        TestStep.wait(seconds: 1)
        TestStep.iosWaitForElement(.labelContains("New Session"), timeout: 10)
        TestStep.iosTap(.labelContains("New Session"))
        TestStep.iosWaitForElement(.labelContains("beta"), timeout: 15)
        TestStep.iosWaitForElementToDisappear(.labelContains("alpha"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-projects-beta")

        // Phase 3 — manual refresh via the iOS pull-to-refresh gesture
        // (the `.refreshable` on `SessionListView`). After the gesture
        // the picker should still reflect "beta" because the sidecar
        // re-emits the last pushed list on `refresh_projects`. The
        // assertion is conservative: it only verifies the list didn't
        // get dropped, since the Mac→sidecar `refresh_projects` RPC
        // wiring is a follow-up task.
        TestStep.iosTap(.labelContains("Cancel"))
        TestStep.wait(seconds: 1)
        // Pull down on the session list to trigger `.refreshable`. The
        // gesture coordinates are deliberately conservative — start
        // inside the table content area, drag down a healthy distance.
        TestStep.iosSwipe(fromX: 200, fromY: 250, toX: 200, toY: 650, duration: 0.5)
        TestStep.wait(seconds: 2)
        TestStep.iosWaitForElement(.labelContains("New Session"), timeout: 10)
        TestStep.iosTap(.labelContains("New Session"))
        TestStep.iosWaitForElement(.labelContains("beta"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-projects-refreshed")
    }
}
