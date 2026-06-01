import Foundation

/// E2E scenario: `gallager plugin` CLI introspection (spec §14).
///
/// Verifies the plugin CLI surface reflects the in-process plugin runtime:
/// - `plugin list` shows both bundled plugins (claude-code, codex), enabled.
/// - `plugin info <id>` returns each plugin's manifest (id + enabled state).
/// - `plugin info <unknown>` exits non-zero.
///
/// All CLI commands are typed into the `plugin-cli` pane via the same
/// socket-backed `gallager` helper used by the Gallager CLI API scenario.
public enum PluginCLIScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin CLI Introspection",
        tags: ["plugin", "cli-api", "macos-only"]
    ) {
        // 1. Session + app, select the pane.
        TestStep.tmuxCreateSession(name: "plugin-cli", width: 100, height: 30)
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macWaitForElement(titled: "plugin-cli", timeout: 5)
        TestStep.macClickButton(titled: "plugin-cli")
        TestStep.wait(seconds: 1)

        // 2. CLI access: point at the app's socket + define a `gallager` helper.
        Shortcut.tmuxClearAndSetPrompt(target: "plugin-cli:0")
        Shortcut.tmuxRunCommand(
            target: "plugin-cli:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        Shortcut.tmuxRunCommand(
            target: "plugin-cli:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )
        Shortcut.tmuxRunCommand(target: "plugin-cli:0", command: "clear")

        // 3. plugin list — both bundled plugins, enabled.
        Shortcut.tmuxRunCommand(
            target: "plugin-cli:0",
            command: #"gallager plugin list > /tmp/e2e-plugin-list.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-plugin-list.txt", storeAs: "pluginList")
        TestStep.assertStoredContains(key: "pluginList", substring: "claude-code")
        TestStep.assertStoredContains(key: "pluginList", substring: "codex")
        TestStep.assertStoredContains(key: "pluginList", substring: "enabled")

        // 4. plugin info claude-code.
        Shortcut.tmuxRunCommand(
            target: "plugin-cli:0",
            command: #"gallager plugin info claude-code > /tmp/e2e-plugin-info-claude.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-plugin-info-claude.txt", storeAs: "claudeInfo")
        TestStep.assertStoredContains(key: "claudeInfo", substring: "claude-code")
        TestStep.assertStoredContains(key: "claudeInfo", substring: "enabled")

        // 5. plugin info codex.
        Shortcut.tmuxRunCommand(
            target: "plugin-cli:0",
            command: #"gallager plugin info codex > /tmp/e2e-plugin-info-codex.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-plugin-info-codex.txt", storeAs: "codexInfo")
        TestStep.assertStoredContains(key: "codexInfo", substring: "codex")
        TestStep.assertStoredContains(key: "codexInfo", substring: "enabled")

        // 6. plugin info <unknown> — non-zero exit (the CLI prints `Error:` to
        //    stderr and exits 1 for an unregistered id).
        Shortcut.tmuxRunCommand(
            target: "plugin-cli:0",
            command: #"gallager plugin info nope-not-a-plugin > /tmp/e2e-plugin-info-bad.txt 2>&1; echo "exit=$?" >> /tmp/e2e-plugin-info-bad.txt"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-plugin-info-bad.txt", storeAs: "badInfo")
        TestStep.assertStoredNotContains(key: "badInfo", substring: "exit=0")
    }
}
