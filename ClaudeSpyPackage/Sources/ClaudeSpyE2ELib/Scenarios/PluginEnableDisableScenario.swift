import Foundation

/// E2E scenario: plugin enable/disable lifecycle via the CLI.
///
/// Guards the regression where a disabled plugin's projects kept surfacing in
/// the merged project list: disabling `codex` must drop its seeded project from
/// `list-projects` and flip its `plugin list` state; re-enabling flips the state
/// back. (The deterministic e2e project set is injected once, so re-enabling
/// restores the plugin/state but not the one-shot seeded project rows — the
/// disappearance on disable is the behavior under test.)
public enum PluginEnableDisableScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Enable Disable Lifecycle",
        tags: ["plugin", "cli-api", "macos-only"]
    ) {
        // 1. Session + app, select the pane, set up the `gallager` CLI helper.
        TestStep.tmuxCreateSession(name: "plugin-toggle", width: 100, height: 30)
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macWaitForElement(titled: "plugin-toggle", timeout: 5)
        TestStep.macClickButton(titled: "plugin-toggle")
        TestStep.wait(seconds: 1)

        Shortcut.tmuxClearAndSetPrompt(target: "plugin-toggle:0")
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )
        Shortcut.tmuxRunCommand(target: "plugin-toggle:0", command: "clear")

        // 2. Baseline: codex enabled + its seeded project (AaaOpenAIApp) and the
        //    Claude projects all present in the merged list.
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager list-projects --json > /tmp/e2e-toggle-projects-1.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-toggle-projects-1.txt", storeAs: "projects1")
        TestStep.assertStoredContains(key: "projects1", substring: "AaaOpenAIApp")
        TestStep.assertStoredContains(key: "projects1", substring: "AlphaProject")

        // 3. Disable codex.
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager plugin disable codex > /tmp/e2e-toggle-disable.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-toggle-disable.txt", storeAs: "disableOut")
        TestStep.assertStoredContains(key: "disableOut", substring: "Disabled codex")

        // 4. plugin list reflects codex disabled.
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager plugin list > /tmp/e2e-toggle-list-1.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-toggle-list-1.txt", storeAs: "list1")
        TestStep.assertStoredContains(key: "list1", substring: "codex")
        TestStep.assertStoredContains(key: "list1", substring: "disabled")

        // 5. bug guard: codex's project no longer surfaces in the merged set,
        //    while claude-code's projects remain.
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager list-projects --json > /tmp/e2e-toggle-projects-2.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-toggle-projects-2.txt", storeAs: "projects2")
        TestStep.assertStoredNotContains(key: "projects2", substring: "AaaOpenAIApp")
        TestStep.assertStoredContains(key: "projects2", substring: "AlphaProject")

        // 6. Re-enable codex → plugin list flips back to enabled.
        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager plugin enable codex > /tmp/e2e-toggle-enable.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-toggle-enable.txt", storeAs: "enableOut")
        TestStep.assertStoredContains(key: "enableOut", substring: "Enabled codex")

        Shortcut.tmuxRunCommand(
            target: "plugin-toggle:0",
            command: #"gallager plugin list > /tmp/e2e-toggle-list-2.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-toggle-list-2.txt", storeAs: "list2")
        // codex's row now reads enabled again (both plugins enabled).
        TestStep.assertStoredNotContains(key: "list2", substring: "disabled")
    }
}
