import Foundation

/// E2E: the **Agents** settings tab (renamed from "Plugin") — a segmented
/// per-agent settings form (command / auto-run / log level / per-agent
/// close-pane), a per-folder install list with an Install/Uninstall button, and
/// proof that the General tab no longer carries the old per-agent sections.
///
/// Install status is **deterministic** in e2e: under `--e2e-test`,
/// `AppCoordinator` short-circuits `pluginInstallStatus`/`installPlugin`/
/// `uninstallPlugin` to an in-memory map, so the tab never shells out to a real
/// `claude`/`codex plugin` against the tester's own config. A fresh root starts
/// `.notInstalled` (Install button); after Install it reads `.installed` (Uninstall).
public enum AgentsSettingsTabScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Agents Settings Tab",
        tags: ["agents", "settings", "plugin"]
    ) {
        Shortcut.macOnlySetup

        // 1. Open Settings → Agents tab (the tab formerly named "Plugin").
        TestStep.macOpenSettings()
        TestStep.macSelectSettingsTab("Agents")
        // The default config-folder row offers Install when not yet installed.
        TestStep.macWaitForElement(titled: "Install", timeout: 5)
        TestStep.wait(seconds: 0.5)

        // 2. Claude Code form + default folder row offering Install (notInstalled).
        TestStep.macScreenshot(label: "mac-agents-claude-notinstalled")

        // 3. Install the default folder → the row flips to the Installed state.
        TestStep.macClickButton(titled: "Install")
        TestStep.macWaitForElement(titled: "Uninstall", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-agents-claude-installed")

        // 4. Switch the segmented picker to Codex — its own settings + folder row.
        TestStep.macClickButton(titled: "Codex")
        TestStep.macWaitForElement(titled: "Install", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-agents-codex")

        // 5. General tab: the Claude Code / Codex CLI / Project Folders sections
        //    are gone (their settings now live only in the Agents tab).
        TestStep.macSelectSettingsTab("General")
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-general-no-agent-sections")
    }
}
