import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Presentation bundle re-push on plugin update (Spec §15.3 #5).
///
/// Verifies that when a plugin's `plugin.json` changes mid-session (e.g.
/// the user upgrades the plugin in place), the Mac re-pushes the
/// `plugin_presentations` message and iOS picks up the new icon / name
/// without a reconnect.
///
/// Strategy:
/// 1. Spawn EchoPlugin (display_name "Echo", short_name "Echo", v1.0.0).
///    Push a project list so the iOS project picker can surface the
///    PluginBadge — that's where Echo's `shortName` renders in the UI.
/// 2. Open the picker and confirm the badge reads "Echo".
/// 3. Rewrite `plugin.json` on disk with bumped version (1.0.1) and a
///    different `short_name` ("EchoV2"). Crash the sidecar — the
///    supervisor's restart re-runs `loadPresentation`, which re-reads
///    the manifest and re-pushes a fresh `plugin_presentations` message.
/// 4. Re-open the picker; the badge should now read "EchoV2".
public enum PluginPresentationUpdateScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Presentation Update",
        tags: ["plugins", "echo", "presentation"]
    ) {
        FreshPairingScenario.scenario

        // Phase 1: spawn at v1 and verify the original presentation.
        TestStep.macSpawnSidecar(
            pluginID: "echo",
            fixtureSourcePath: URL(fileURLWithPath: "Fixtures/EchoPlugin"),
            instance: 0
        )

        TestStep.tmuxCreateSession(name: "echo-presentation", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "echo-presentation:0.0", storeAs: "paneId")

        // Pin a project to the echo plugin so the picker shows the badge.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_projects"),
                "projects": .array([
                    .object([
                        "name": .string("Presentation Demo"),
                        "path": .string("/tmp/echo-pres-demo"),
                        "plugin_id": .string("echo"),
                    ]),
                ]),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // Let the push settle through the relay before opening the picker.
        TestStep.wait(seconds: 1)
        // Open the project picker on iOS to surface the plugin badge.
        // The PluginBadge label reads `presentation.shortName` — Echo's
        // initial fixture pins shortName == "Echo".
        TestStep.iosWaitForElement(.labelContains("New Session"), timeout: 15)
        TestStep.iosTap(.labelContains("New Session"))
        TestStep.iosWaitForElement(.labelContains("Presentation Demo"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("Echo"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-presentation-v1")

        // Dismiss so we can re-open after the upgrade.
        TestStep.iosTap(.labelContains("Cancel"))
        TestStep.wait(seconds: 1)

        // Phase 2: rewrite the manifest in place. We can't use a raw
        // shell heredoc through `tmuxSendKeys` cleanly because the JSON
        // has braces tmux interprets as format strings. Use `printf` so
        // the literal goes through unmolested.
        Shortcut.tmuxRunCommand(
            target: "echo-presentation:0",
            command: #"printf '%s\n' '{"schema_version":1,"id":"echo","display_name":"Echo Updated","short_name":"EchoV2","version":"1.0.1","publisher":"Gallager Test Fixtures","manifest_url":"bundle://echo/plugin.json","bundle_sha256":null,"runtime":"sidecar","sidecar":{"executable":"bin/sidecar","args":[]},"capabilities":{"pushes_projects":true,"translate_event":true,"install":true,"detect_pane":false,"settings_schema":"ui/settings.json","requires_rich_detection":false},"process_names":["echo"],"ui":{"icon":"assets/icon.png","icon_ios":"assets/icon.png"}}' > "${gallagerStateRoot}/plugins/echo/plugin.json""#
        )
        TestStep.wait(seconds: 1)

        // Force the supervisor to restart. `_test: "crash"` invokes
        // `abort()`; the supervisor handles termination with a 1 s backoff
        // for crash #1 (Spec §12) and re-runs `spawnAndInitialize`, which
        // re-reads the (now-bumped) manifest and pushes a fresh
        // `plugin_presentations` message.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object(["_test": .string("crash")]),
            env: ["TMUX_PANE": "${paneId}"]
        )
        TestStep.wait(seconds: 4)

        // Re-seed projects so the SessionStore mirror is non-empty after
        // the restart.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_projects"),
                "projects": .array([
                    .object([
                        "name": .string("Presentation Demo"),
                        "path": .string("/tmp/echo-pres-demo"),
                        "plugin_id": .string("echo"),
                    ]),
                ]),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // Re-open the picker; the badge should now read "EchoV2".
        TestStep.wait(seconds: 2)
        TestStep.iosWaitForElement(.labelContains("New Session"), timeout: 10)
        TestStep.iosTap(.labelContains("New Session"))
        TestStep.iosWaitForElement(.labelContains("Presentation Demo"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("EchoV2"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-presentation-v2")
    }
}
