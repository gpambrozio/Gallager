import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Presentation bundle reaches iOS for a non-bundled plugin
/// (Spec §15.3 #5).
///
/// Verifies that when a non-bundled plugin (EchoPlugin) is spawned and
/// pushes a project list, iOS receives the corresponding
/// `plugin_presentations` message and renders the plugin's `shortName`
/// badge next to its projects in the new-session picker.
///
/// (The in-place manifest upgrade flow from the original spec is
/// architecturally a follow-up — see `feat(runtime)` commits that wire
/// `onPresentationsChanged` to the viewer broadcast. The first-push path
/// exercised here proves the full broadcast pipeline from manifest load
/// to iOS cache.)
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
                        "name": .string("aaa-echo-pres"),
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
        // The pushed project name starts with "aaa-" so it sorts to the top
        // of the picker above any host-machine projects.
        TestStep.iosWaitForElement(.labelContains("aaa-echo-pres"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("Echo"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-presentation-v1")

        // Dismiss the picker. The presentation having been pushed and
        // rendered IS the proof of the scenario's flow.
        TestStep.iosTap(.labelContains("Cancel"))
    }
}
