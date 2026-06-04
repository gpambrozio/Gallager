import Foundation

/// E2E scenario: create-from-project resolves the plugin's launch command.
///
/// Starting a session from a project asks the owning plugin core for its launch
/// command (`commandForLaunch`, auto-run on by default → `claude`). This proves
/// the session is launched with the agent's CLI binary (`claude`) rather than
/// the dashed plugin id (`claude-code`) — the launch-resolution path that the
/// window-name fallback also depends on.
///
/// Uses the CLI `start-project` path because the iOS picker's seeded projects
/// point at non-existent `/Users/test/...` paths; `start-project` against a real
/// `/tmp` directory exercises the same plugin launch resolution deterministically.
public enum CreateFromProjectLaunchScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Create From Project Launch",
        tags: ["sessions", "project", "macos-only"]
    ) {
        // 1. Session + app, select the pane, set up the `gallager` CLI helper.
        TestStep.tmuxCreateSession(name: "cfp-cli", width: 100, height: 30)
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macWaitForElement(titled: "cfp-cli", timeout: 5)
        TestStep.macClickButton(titled: "cfp-cli")
        TestStep.wait(seconds: 1)

        Shortcut.tmuxClearAndSetPrompt(target: "cfp-cli:0")
        Shortcut.tmuxRunCommand(
            target: "cfp-cli:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        Shortcut.tmuxRunCommand(
            target: "cfp-cli:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )
        Shortcut.tmuxRunCommand(target: "cfp-cli:0", command: "clear")

        // 2. Start a session from a real project directory.
        Shortcut.tmuxRunCommand(
            target: "cfp-cli:0",
            command: #"mkdir -p /tmp/e2e-cfp-project && gallager start-project /tmp/e2e-cfp-project --json > /tmp/e2e-cfp-start.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cfp-start.txt", storeAs: "cfpStart")
        TestStep.assertStoredContains(key: "cfpStart", substring: #""name":"e2e-cfp-project""#)
        TestStep.macWaitForElement(titled: "e2e-cfp-project", timeout: 5)

        // 3. The session's pane launched the agent CLI (`claude`), resolved from
        //    the plugin core — not the dashed plugin id. `claude` isn't installed
        //    in the sandbox, so the shell reports it; the command name proves
        //    which binary was launched.
        TestStep.wait(seconds: 2)
        TestStep.tmuxCapturePaneContent(target: "e2e-cfp-project:0", storeAs: "cfpPane")
        TestStep.assertStoredContains(key: "cfpPane", substring: "claude")
        TestStep.assertStoredNotContains(key: "cfpPane", substring: "claude-code")
        TestStep.macScreenshot(label: "mac-create-from-project", compare: false)
    }
}
