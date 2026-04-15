import Foundation

/// E2E scenario: Gallager CLI API
///
/// Verifies the gallager CLI can control the app via Unix socket:
/// 1. Creates a tmux session and selects the pane
/// 2. Derives CLI binary path from running app and sets socket path
/// 3. Runs ping, list-sessions, and identify commands
/// 4. Uses send command to type text into the terminal
/// 5. Takes screenshots showing CLI commands executed successfully
public enum GallagerCLIScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Gallager CLI API",
        tags: ["macos-only", "cli-api"]
    ) {
        // 1. Create tmux session and launch app
        TestStep.tmuxCreateSession(name: "cli-test", width: 100, height: 30)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)
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
        // The app binary is at .app/Contents/MacOS/Gallager, CLI is at .app/Contents/MacOS/GallagerCLI
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

        // 3. Test ping command
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI ping > /tmp/e2e-cli-ping.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-ping.txt", storeAs: "pingResult")
        TestStep.assertStoredContains(key: "pingResult", substring: "pong")

        // 4. Test list-sessions command
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI list-sessions --json > /tmp/e2e-cli-sessions.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-sessions.txt", storeAs: "sessionsResult")
        TestStep.assertStoredContains(key: "sessionsResult", substring: "cli-test")

        // 5. Test identify command
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI identify --json > /tmp/e2e-cli-identify.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-identify.txt", storeAs: "identifyResult")
        TestStep.assertStoredContains(key: "identifyResult", substring: "cli-test")

        // 6. Screenshot showing CLI commands ran
        Shortcut.tmuxRunCommand(target: "cli-test:0", command: "clear")
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"echo "=== Gallager CLI API Test ===" && $CLI ping && echo "---" && $CLI list-sessions"#
        )
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-cli-commands-output")

        // 7. Test send command — use API to type text into the terminal
        Shortcut.tmuxRunCommand(target: "cli-test:0", command: "clear")
        TestStep.wait(seconds: 0.5)

        // Use the CLI to send text and enter key to the pane
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"$CLI send 'echo hello-from-gallager-api' && $CLI send-key enter"#
        )
        TestStep.wait(seconds: 2)

        // Verify the text appeared by capturing pane content
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"tmux capture-pane -t cli-test:0 -p > /tmp/e2e-cli-send.txt"#
        )
        TestStep.wait(seconds: 1)
        TestStep.readFile(path: "/tmp/e2e-cli-send.txt", storeAs: "sendResult")
        TestStep.assertStoredContains(key: "sendResult", substring: "hello-from-gallager-api")

        TestStep.macScreenshot(label: "mac-cli-send-output")
    }
}
