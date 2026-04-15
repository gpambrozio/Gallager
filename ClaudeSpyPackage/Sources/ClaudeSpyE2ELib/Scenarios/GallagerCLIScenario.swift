import Foundation

/// E2E scenario: Gallager CLI API
///
/// Verifies the gallager CLI can control the app via Unix socket by
/// exercising commands that produce visible UI changes:
/// 1. ping + list-sessions — verify basic connectivity
/// 2. send text — verify text appears in terminal
/// 3. split-pane — verify window splits into two panes
/// 4. new-window — verify a new tab appears
/// 5. notify — trigger a desktop notification
public enum GallagerCLIScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Gallager CLI API",
        tags: ["macos-only", "cli-api"]
    ) {
        // 1. Create tmux session and launch app
        TestStep.tmuxCreateSession(name: "cli-test", width: 100, height: 30)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select the pane in the sidebar
        TestStep.macWaitForElement(titled: "cli-test", timeout: 5)
        TestStep.macClickButton(titled: "cli-test")
        TestStep.wait(seconds: 2)

        // 2. Set up CLI access
        // The tmux session was created by the E2E framework, not the app,
        // so $VISUAL and $GALLAGER_SOCKET aren't set. Derive CLI path from
        // the running app process and use the default socket path.
        Shortcut.tmuxClearAndSetPrompt(target: "cli-test:0")

        // Find CLI binary inside the running app bundle
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"APP_DIR="$(dirname "$(ps -o comm= -p $(pgrep -x Gallager | head -1))")""#
        )
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"CLI="$APP_DIR/GallagerCLI --socket $TMPDIR/gallager.sock""#
        )
        TestStep.wait(seconds: 0.5)

        // 3. Verify basic connectivity
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI ping > /tmp/e2e-cli-ping.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-ping.txt", storeAs: "pingResult")
        TestStep.assertStoredContains(key: "pingResult", substring: "pong")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI list-sessions --json > /tmp/e2e-cli-sessions.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-sessions.txt", storeAs: "sessionsResult")
        TestStep.assertStoredContains(key: "sessionsResult", substring: "cli-test")

        // 4. Screenshot: single-pane terminal before any changes
        Shortcut.tmuxRunCommand(target: "cli-test:0", command: "clear")
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"echo "Single pane — before split""#
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-single-pane-before-split")

        // 5. Split pane via CLI — should show two panes side by side
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI split-pane right > /tmp/e2e-cli-split.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "mac-after-split-pane")

        // 6. Send text to the original pane via CLI
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI send 'echo hello-from-gallager-api' && $CLI send-key enter"#
        )
        TestStep.wait(seconds: 2)

        // Verify the text appeared
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"tmux capture-pane -t cli-test:0.0 -p > /tmp/e2e-cli-send.txt"#
        )
        TestStep.wait(seconds: 1)
        TestStep.readFile(path: "/tmp/e2e-cli-send.txt", storeAs: "sendResult")
        TestStep.assertStoredContains(key: "sendResult", substring: "hello-from-gallager-api")

        TestStep.macScreenshot(label: "mac-after-send-text")

        // 7. Create a new window via CLI — should show a new tab
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI new-window --session cli-test > /tmp/e2e-cli-newwin.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "mac-after-new-window")

        // 8. Send a notification via CLI
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI notify --title "Gallager CLI" --body "E2E test notification""#
        )
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-after-notify")
    }
}
