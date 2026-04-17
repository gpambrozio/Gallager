import Foundation

/// E2E scenario: Gallager CLI API
///
/// Verifies the gallager CLI can control the app via Unix socket by
/// exercising commands that produce visible UI changes:
/// 1. ping + list-sessions — verify basic connectivity
/// 2. new-session — verify new session appears in sidebar
/// 3. list-panes — find pane ID for explicit targeting
/// 4. split-pane — verify window splits into two panes
/// 5. send text — verify text appears in pane
/// 6. new-window — verify a new tab appears
///
/// Strategy: all CLI commands typed into `cli-test:0` via tmuxSendKeys.
/// Commands that need to target e2e-api use explicit pane IDs from list-panes.
/// Sidebar stays on e2e-api for screenshots.
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
        Shortcut.tmuxClearAndSetPrompt(target: "cli-test:0")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )
        TestStep.wait(seconds: 0.5)

        // 3. Verify basic connectivity
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager ping > /tmp/e2e-cli-ping.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-ping.txt", storeAs: "pingResult")
        TestStep.assertStoredContains(key: "pingResult", substring: "pong")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-sessions --json > /tmp/e2e-cli-sessions.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-sessions.txt", storeAs: "sessionsResult")
        TestStep.assertStoredContains(key: "sessionsResult", substring: "sessions")

        // 4. Screenshot: baseline — single session in sidebar
        TestStep.macScreenshot(label: "mac-baseline")

        // 5. Create a new session via CLI
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager new-session --name e2e-api > /tmp/e2e-cli-newsession.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)

        // Click e2e-api to view it — stay here for all subsequent screenshots
        TestStep.macWaitForElement(titled: "e2e-api", timeout: 5)
        TestStep.macClickButton(titled: "e2e-api")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-new-session-created")

        // 6. Get the pane ID of e2e-api's pane for explicit targeting.
        // Pane IDs are like %0, %1, etc. Extract from list-panes JSON.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"PANE_ID=$(gallager list-panes --window e2e-api:0 --json 2>/dev/null | grep -o '"id":"%[0-9]*"' | head -1 | cut -d'"' -f4)"#
        )
        TestStep.wait(seconds: 2)
        // Verify we got a pane ID
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"echo "PANE=$PANE_ID" > /tmp/e2e-cli-paneid.txt"#
        )
        TestStep.wait(seconds: 0.5)
        TestStep.readFile(path: "/tmp/e2e-cli-paneid.txt", storeAs: "paneIdResult")
        TestStep.assertStoredContains(key: "paneIdResult", substring: "PANE=%")

        // 7. Split the e2e-api pane using explicit pane ID, with an explicit --path.
        // The new pane should open in /tmp (not $HOME), proving --path is wired through.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager split-pane right --pane "$PANE_ID" --path /tmp --json > /tmp/e2e-cli-split.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cli-split.txt", storeAs: "splitResult")
        // tmux resolves symlinks when reporting cwd; on macOS /tmp → /private/tmp.
        TestStep.assertStoredContains(key: "splitResult", substring: #""cwd":"\/private\/tmp""#)
        TestStep.macScreenshot(label: "mac-after-split-pane")

        // 8. Send text to e2e-api's pane using explicit pane ID
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager send 'echo hello-from-gallager-api' --pane "$PANE_ID" && gallager send-key enter --pane "$PANE_ID""#
        )
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-after-send-text")

        // 9. Create a new window in e2e-api — should show a tab bar
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager new-window --session e2e-api > /tmp/e2e-cli-newwin.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cli-newwin.txt", storeAs: "newwinResult")
        TestStep.assertStoredContains(key: "newwinResult", substring: "Created window")
        TestStep.macScreenshot(label: "mac-after-new-window")
    }
}
