import Foundation

/// E2E: the plugin auto-update UI in Settings → Agents — the per-agent "Updates"
/// section (auto-check toggle + Check Now), the inline "Updated to …" status, and
/// the restart-required banner at the top of the tab.
///
/// The real update pipeline is HTTPS-only by design (manifest re-fetch → bundle
/// download → SHA-256 verify), so a scenario can't serve it. Under `--e2e-test`
/// `AppCoordinator` therefore stubs three `PluginUpdateManager` callbacks — and
/// only for the `update-test-sidecar` id this scenario stages: that registry entry
/// is presented as URL-installed (`source: .url` + a manifest URL, which is what
/// gates the Updates section), `checkUpdate`/`checkUpdates` report a pending
/// `9.9.9`, and `installFromURL` reports success without touching the network.
/// Everything after that is the production path: `applyUpdate` → idle hot-restart
/// (a real disable + enable of the sidecar process) → bridge refresh → restart
/// notice + inline status.
///
/// A staged fixture is used rather than the in-process `echo` core because
/// `agentPluginList()` hides `echo` from the picker, so it has no per-agent form.
/// The dedicated id keeps the stub out of the other fixture-staging scenarios
/// (they stage `echo-sidecar`), whose plugins stay honestly folder-dropped.
public enum AgentsPluginAutoUpdateScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Agents Plugin Auto Update",
        tags: ["plugin", "sidecar", "agents", "settings", "macos-only"]
    ) {
        // 1. Stage the sidecar fixture before launch so it is discovered,
        //    registered, and persisted into registry.json at boot — the entry the
        //    e2e stub then presents as URL-installed.
        TestStep.macStageSidecarFixture(
            id: "update-test-sidecar",
            displayName: "Update Test Sidecar"
        )

        Shortcut.macOnlySetup

        // 2. Open Settings → Agents and select the fixture's segment (its
        //    per-agent form only renders when it is the selected agent).
        TestStep.macOpenSettings()
        TestStep.macSelectSettingsTab("Agents")
        TestStep.macWaitForElement(titled: "Update Test Sidecar", timeout: 10)
        TestStep.macClickButton(titled: "Update Test Sidecar")

        // 3. The Updates section renders for it — the auto-check toggle and the
        //    Check Now button. Both are also matched by accessibility identifier,
        //    which proves the section belongs to this plugin (and SwiftUI toggle
        //    titles alone are unreliable in the AX tree).
        TestStep.macWaitForElementQuery(.identifier("agentAutoUpdate-update-test-sidecar"), timeout: 10)
        TestStep.macWaitForElementQuery(.identifier("agentCheckUpdates-update-test-sidecar"), timeout: 5)
        TestStep.macWaitForElement(titled: "Check for updates automatically", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-agents-updates-section")

        // 4. Check Now finds 9.9.9 and applies it via an idle hot-swap, so the
        //    status carries no restart advice (nothing was running to restart).
        //    Waits are on the FULL status strings — a substring wait gets
        //    shadowed by the sibling banner text, which starts with the same
        //    display name.
        TestStep.macClickButton(titled: "Check Now")
        TestStep.macWaitForElement(
            titled: "Updated to 9.9.9",
            timeout: 20
        )

        // 5. The update banner appears at the top of the tab and stays until
        //    the app restarts (the notice list is in-memory).
        TestStep.macWaitForElementQuery(.identifier("pluginRestartBanner"), timeout: 10)
        TestStep.macWaitForElement(
            titled: "Update Test Sidecar updated to 9.9.9",
            timeout: 10
        )
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-agents-update-applied")

        // 6. The banner pushed the form down far enough that the per-plugin inline
        //    status sits below the fold (the Settings window can't grow taller), so
        //    scroll the form to its bottom stop — a clamped, repeatable resting
        //    position — to also capture the "Updated to 9.9.9 …" row under
        //    Check Now. Anchored on the toggle row so the events land in the form's
        //    scroll view, not the window centre.
        TestStep.macScrollWheelAtElement(
            titled: "Check for updates automatically",
            deltaY: -40,
            count: 12
        )
        TestStep.wait(seconds: 0.7)
        TestStep.macScreenshot(label: "mac-agents-update-status-inline")
    }
}
