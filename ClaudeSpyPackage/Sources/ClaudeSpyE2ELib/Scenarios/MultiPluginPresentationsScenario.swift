import Foundation

/// E2E scenario: multiple plugins present distinct projects/badges in the iOS
/// picker, and disabling one removes only its projects (iOS-side guard for the
/// merged project list / per-plugin presentation isolation).
public enum MultiPluginPresentationsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Plugin Presentations",
        tags: ["plugin", "presentations", "ios"]
    ) {
        // 1. Pair, then add a tmux pane with the `gallager` CLI helper so we can
        //    disable a plugin mid-scenario.
        FreshPairingScenario.scenario
        TestStep.tmuxCreateSession(name: "mp-cli", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "mp-cli:0")
        Shortcut.tmuxRunCommand(
            target: "mp-cli:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        Shortcut.tmuxRunCommand(
            target: "mp-cli:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )

        // 2. Open the project picker — both plugins' projects coexist, with the
        //    Codex project carrying a "Codex" badge and Claude projects none.
        TestStep.iosTap(.label("New Session"))
        TestStep.iosWaitForElement(.labelContains("AaaOpenAIApp"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Codex"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-both-plugins-projects")

        // 3. Disable codex via the CLI. The host pushes fresh session state, so
        //    the open picker drops the Codex project live.
        Shortcut.tmuxRunCommand(
            target: "mp-cli:0",
            command: #"gallager plugin disable codex > /tmp/e2e-mp-disable.txt 2>&1"#
        )

        // 4. The Codex project disappears; the Claude project stays.
        TestStep.iosWaitForElementToDisappear(.labelContains("AaaOpenAIApp"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-codex-disabled-projects")
    }
}
